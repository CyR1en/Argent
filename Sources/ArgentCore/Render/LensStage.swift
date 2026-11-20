import Foundation
import Metal

/// Distortion, lateral colour and vignetting in one resample of a scene-linear frame, after the frame's removals are laid into it.
public final class LensStage {
    // At or below 41/9, the negative Catmull-Rom weights cannot make positive taps negative.
    static let limiterRatio: Float = 1.05
    var bandRows = 512

    private struct Parameters {
        var centreX: Float, centreY: Float, inverseRMax: Float, inverseScale: Float, limit: Float
        var maps: UInt32, firstRow: UInt32
    }

    private let gpu: GPU
    private let pipeline: MTLComputePipelineState
    private let defringe: Defringe
    /// Where a removal's pixels come from; `nil` for a stage that is given no frame with one (docs/remove-plan.md, section 4.3).
    let patches: (any RemovalPatchSource)?
    /// What lays the removals into a decode, made with the first frame that has one: a stage whose frames have none compiles and
    /// keeps nothing of it. Under `compositeLock`, since previews stage two decodes at once.
    private var compositeMade: RemovalComposite?
    private var patchLimit = LensStage.defaultKeptPatchBytes
    private let compositeLock = NSLock()
    /// The patches' textures a stage keeps between composites unless told otherwise (`maximumKeptPatchBytes`): five of the
    /// model's largest with their chains.
    public static let defaultKeptPatchBytes = RemovalComposite.defaultMaximumBytes

    public init(gpu: GPU, patches: (any RemovalPatchSource)? = nil) throws {
        let library = try gpu.device.makeLibrary(source: ShaderSource.lensStage, options: nil)
        guard let function = library.makeFunction(name: "lens_stage") else { throw GPUError.shaderFunctionMissing("lens_stage") }
        pipeline = try gpu.device.makeComputePipelineState(function: function)
        self.gpu = gpu
        self.patches = patches
        defringe = try Defringe(gpu: gpu)
    }

    public func correct(_ frame: LinearFrame, with correction: ResolvedLensCorrection) throws -> LinearFrame {
        guard frame.lens == nil, frame.pins?.lensCorrection != true else {
            throw LensCorrectionError.decoderCorrected
        }
        return try correctValidated(frame, with: correction, reusingDecode: false).scene
    }

    /// The caller releases the decode after this call; its texture may hold the repaired scene.
    public func correct(_ frame: LinearFrame, with correction: ResolvedLensCorrection, reusingDecode: Bool) throws
        -> (scene: LinearFrame, spare: PooledTexture?) {
        guard frame.lens == nil, frame.pins?.lensCorrection != true else { throw LensCorrectionError.decoderCorrected }
        return try correctValidated(frame, with: correction, reusingDecode: reusingDecode)
    }

    /// The full-size decode `frame` over `box`, with those of `removals` that are on laid in and nothing warped: what the model is
    /// given to take another object out (docs/remove-plan.md, section 4.3). Red, green and blue, the picture's top row first,
    /// `box.width * box.height * 3` values. The decode is left as it was.
    public func removalInput(_ frame: LinearFrame, removals: [Removal], box: RemovalPatch.Box) throws -> [Float16] {
        guard frame.lens == nil, frame.pins?.lensCorrection != true else { throw LensCorrectionError.decoderCorrected }
        guard frame.texture.pixelFormat == .rgba16Float else {
            throw NSError(domain: "LensStage", code: 1, userInfo: [NSLocalizedDescriptionKey: "LensStage requires rgba16Float."])
        }
        guard Self.isFullSize(frame) else { throw RemovalError.invalid("a removal's input is cut from the full-size decode") }
        guard box.x + box.width <= frame.width, box.y + box.height <= frame.height else {
            throw RemovalError.invalid("a removal's input lies inside the frame")
        }
        return try composite().pixels(of: frame, over: box, compositing: shown(removals), bandRows: bandRows)
    }

    /// Whether `frame` is the full-size decode of its picture, whose pixels a patch's box counts.
    public static func isFullSize(_ frame: LinearFrame) -> Bool {
        frame.scale >= 1 && frame.picture.map { $0.width == frame.width && $0.height == frame.height } != false
    }

    /// Patches uploaded and patches laid into a decode so far, for tests.
    public var removalStatistics: (uploads: Int, composites: Int) { compositeLock.withLock { compositeMade }?.statistics ?? (0, 0) }

    /// The bytes of the patches' textures this stage keeps for its next composite; a develop's stage keeps none.
    public var keptPatchBytes: Int { compositeLock.withLock { compositeMade }?.residentBytes ?? 0 }

    /// Lets those textures go: each is made again from its patch when next laid.
    public func removeKeptPatches() { compositeLock.withLock { compositeMade }?.removeAll() }

    /// The most of them that is kept, the least recently used going first.
    public var maximumKeptPatchBytes: Int {
        get { compositeLock.withLock { patchLimit } }
        set {
            compositeLock.withLock {
                patchLimit = max(0, newValue)
                compositeMade?.maximumBytes = patchLimit
            }
        }
    }

    private func composite() throws -> RemovalComposite {
        try compositeLock.withLock {
            if let compositeMade { return compositeMade }
            let made = try RemovalComposite(gpu: gpu)
            made.maximumBytes = patchLimit
            compositeMade = made
            return made
        }
    }

    /// Those of `removals` that are on and whose patch is found, in order. A removal whose patch is missing is skipped: its row
    /// says so, and a develop has refused its frame before the decode.
    private func shown(_ removals: [Removal]) -> [RemovalComposite.Shown] {
        removals.compactMap { removal in
            guard removal.isOn, let patch = patches?.patch(removal.patch) else { return nil }
            return (patch, removal.includesEffects)
        }
    }

    private func correctValidated(_ frame: LinearFrame, with correction: ResolvedLensCorrection, reusingDecode: Bool) throws
        -> (scene: LinearFrame, spare: PooledTexture?) {
        func scene(_ image: PooledTexture) -> LinearFrame {
            LinearFrame(image: image, decoderVersion: frame.decoderVersion, scale: frame.scale,
                        pins: frame.pins, readback: frame.readback, picture: frame.picture, lens: correction)
        }
        let parameters = correction.defringe
        let repairs = parameters.map { p in [p.purple, p.green].compactMap { $0 }.contains { Defringe.runs(amount: $0.amount, scale: frame.scale) } } ?? false
        let removed = shown(correction.removals)
        if correction.isIdentity && !repairs && removed.isEmpty { return (scene(frame.image), nil) }
        guard frame.texture.pixelFormat == .rgba16Float else {
            throw NSError(domain: "LensStage", code: 1, userInfo: [NSLocalizedDescriptionKey: "LensStage requires rgba16Float."])
        }
        // The removals go in before the warp, so the warp, Defringe and the vignette act on a patch as on the rest of the decode.
        // A caller that keeps its decode gets them in a copy: a preview measures that decode for Auto and stages it again for the
        // next lens move.
        let decode = removed.isEmpty ? frame.image
            : try composite().composited(removed, onto: frame, inPlace: reusingDecode, bandRows: bandRows)
        if correction.isIdentity && !repairs { return (scene(decode), nil) }
        let warped = correction.isIdentity ? decode : try warp(decode, with: correction)
        guard repairs, let parameters else { return (scene(warped), reusingDecode ? frame.image : nil) }
        let output = reusingDecode && !correction.isIdentity ? frame.image : try gpu.texturePool.acquire(width: frame.width, height: frame.height)
        try defringe.repair(warped.texture, into: output.texture, with: parameters, scale: frame.scale)
        return (scene(output), reusingDecode ? warped : nil)
    }

    private func warp(_ frame: PooledTexture, with correction: ResolvedLensCorrection) throws -> PooledTexture {
        guard frame.texture.pixelFormat == .rgba16Float else {
            throw NSError(domain: "LensStage", code: 1, userInfo: [NSLocalizedDescriptionKey: "LensStage requires rgba16Float."])
        }
        let output = try gpu.texturePool.acquire(width: frame.width, height: frame.height)
        let samples = correction.red.samples + correction.green.samples + correction.blue.samples + correction.gain.samples
        guard let tables = samples.withUnsafeBytes({
            gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw GPUError.textureAllocation }
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setTexture(output.texture, index: 1)
        encoder.setBuffer(tables, offset: 0, index: 1)
        var parameters = Parameters(centreX: Float(frame.width - 1) / 2, centreY: Float(frame.height - 1) / 2,
                                    inverseRMax: Float(2 / hypot(Double(frame.width), Double(frame.height))),
                                    inverseScale: Float(1 / correction.scale),
                                    limit: (Self.limiterRatio - 1) / (Self.limiterRatio + 1),
                                    maps: correction.red == correction.green && correction.green == correction.blue ? 1 : 3,
                                    firstRow: 0)
        for first in stride(from: 0, to: frame.height, by: bandRows) {
            parameters.firstRow = UInt32(first)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
            encoder.dispatchPixels(pipeline, width: frame.width, height: min(bandRows, frame.height - first))
        }
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((frame, tables)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        return output
    }
}
