import Foundation
import Metal

/// The grain noise the print pass reads: two tiles of unit-variance noise, one per layer in red,
/// green and blue, shaped to the dye clouds' power spectrum at an output's pixel pitch.
///
/// Each layer is white Gaussian noise blurred by the two cloud Gaussians (`GrainModel
/// .cloudSigmasMicrometres`) integrated over the pixel, wrapped at the tile's edge so it tiles
/// without a seam, made on the GPU (on the CPU it took 0.1 to 0.3 s a pitch in a release
/// build and up to 27 s in a debug one, measured). The print pass adds the two tiles at offsets from the frame's seed; their
/// sides, 1024 and 1021, share no factor, so the sum repeats only every 1,045,504 pixels. A
/// develop's tiles are made once per pitch, within 5 percent; below a quarter-pixel cloud the noise
/// is white, which all those pitches share. A picture smaller than its develop gets tiles of its
/// own, shaped like the develop's grain area-resized to it (`tiles(longSide:developLongSide:)`).
/// The last few tile pairs made are kept.
public final class GrainField: @unchecked Sendable {
    public static let sides = (1024, 1021)
    private static let kept = 4
    private static let pitchStep: Float = 1.05

    private struct Pipelines {
        let noise: MTLComputePipelineState
        let blur: MTLComputePipelineState
        let combine: MTLComputePipelineState
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lock = NSLock()
    private var pipelines: Pipelines?
    private var tiles: [(key: Key, a: MTLTexture, b: MTLTexture, scale: Float)] = []

    /// What a tile pair holds.
    private enum Key: Hashable {
        /// A develop's: its pitch in 5 percent steps, 0 for white noise.
        case pitch(Int)
        /// A smaller picture's: its develop's long side and its own.
        case resized(from: Int, to: Int)
    }

    public init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    /// Builds the tile kernels from `library`. Called where renderers are built, on one thread,
    /// since the shader library compiles lazily and is not thread-safe.
    public func prepare(library: MTLLibrary) throws {
        try lock.withLock {
            guard pipelines == nil else { return }
            func pipeline(_ name: String) throws -> MTLComputePipelineState {
                guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
                return try device.makeComputePipelineState(function: function)
            }
            pipelines = Pipelines(noise: try pipeline("grain_noise"), blur: try pipeline("grain_blur"),
                                  combine: try pipeline("grain_combine"))
        }
    }

    /// The two tiles for an output whose long side is `longSide` pixels, drawn at its own pitch: a
    /// develop's.
    public func tiles(longSide: Int) throws -> (MTLTexture, MTLTexture) {
        let key = Self.bucket(longSide: longSide)
        let found = try tiles(for: .pitch(key)) { (Self.developKernels(bucket: key), 1) }
        return (found.a, found.b)
    }

    /// The tiles, and the grain's scale on the stock's sigma, for a picture `longSide` pixels long that
    /// stands for a develop `developLongSide` long. At the develop's size, or within a pixel of it, they are
    /// the develop's own at r(p). A smaller picture's noise has the statistics of the develop's grain
    /// area-resized to it (`GrainModel.resized`), so the picture and the develop resized to it carry the
    /// same grain (docs/manual-development-validation.md, "Grain tolerance, 2026-10-16").
    public func tiles(longSide: Int, developLongSide: Int) throws -> (a: MTLTexture, b: MTLTexture, scale: Float) {
        guard developLongSide > longSide + 1 else {
            let (a, b) = try tiles(longSide: longSide)
            return (a, b, GrainModel.pixelRatio(longSide: longSide))
        }
        return try tiles(for: .resized(from: developLongSide, to: longSide)) {
            let develop = Self.developKernels(bucket: Self.bucket(longSide: developLongSide))
            let resized = GrainModel.resized(kernels: develop, from: developLongSide, to: longSide)
            return (resized.kernels, GrainModel.pixelRatio(longSide: developLongSide) * resized.sigma)
        }
    }

    /// The pitch of an output `longSide` pixels long in 5 percent steps; 0, white noise, below a
    /// quarter-pixel cloud.
    static func bucket(longSide: Int) -> Int {
        let pitch = GrainModel.pitchMicrometres(longSide: longSide)
        let sigmas = GrainModel.cloudSigmasMicrometres.map { $0 / pitch }
        return sigmas.max()! < 0.25 ? 0 : Int((log(pitch) / log(Self.pitchStep)).rounded())
    }

    /// A develop's kernels for a bucket: each cloud integrated over a pixel at the bucket's canonical pitch,
    /// so every request in a bucket gets the same grain, whatever frame came first.
    static func developKernels(bucket: Int) -> [[Float]] {
        let bucketPitch = pow(Self.pitchStep, Float(bucket))
        return GrainModel.cloudSigmasMicrometres.map { bucket == 0 ? kernel(sigma: 0) : kernel(sigma: $0 / bucketPitch) }
    }

    /// The pair kept for `key`, or one made from `spec`'s kernels and kept with its scale.
    private func tiles(for key: Key, spec: () -> (kernels: [[Float]], scale: Float)) throws -> (a: MTLTexture, b: MTLTexture, scale: Float) {
        try lock.withLock {
            if let index = tiles.firstIndex(where: { $0.key == key }) {
                let found = tiles.remove(at: index)
                tiles.append(found)
                return (found.a, found.b, found.scale)
            }
            guard let pipelines else { throw GPUError.shaderFunctionMissing("grain_noise (GrainField.prepare was not called)") }
            let made = spec()
            let a = try texture(side: Self.sides.0, kernels: made.kernels, seed: 0x5eed_0001, pipelines: pipelines)
            let b = try texture(side: Self.sides.1, kernels: made.kernels, seed: 0x5eed_0002, pipelines: pipelines)
            tiles.append((key, a, b, made.scale))
            if tiles.count > Self.kept { tiles.removeFirst() }
            return (a, b, made.scale)
        }
    }

    /// How many tile pairs are kept now.
    var keptCount: Int { lock.withLock { tiles.count } }

    private func makeTexture(side: Int, format: MTLPixelFormat, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: side, height: side, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
        return texture
    }

    /// One tile: per cloud size, a field of white noise blurred across and down by that cloud's kernel;
    /// the fields summed and scaled to unit variance from the kernels' weights.
    private func texture(side: Int, kernels: [[Float]], seed: UInt32, pipelines: Pipelines) throws -> MTLTexture {
        let work: MTLTextureUsage = [.shaderRead, .shaderWrite]
        let output = try makeTexture(side: side, format: .rgba16Float, usage: [.shaderRead, .shaderWrite])
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        var fields: [MTLTexture] = []
        var variance: Float = 0
        for (index, weights) in kernels.enumerated() {
            let noise = try makeTexture(side: side, format: .rgba32Float, usage: work)
            let scratch = try makeTexture(side: side, format: .rgba32Float, usage: work)
            var fieldSeed = seed &+ UInt32(index) &* 0x9e37_79b9
            try encode(pipelines.noise, textures: [noise], into: commandBuffer, side: side) { encoder in
                encoder.setBytes(&fieldSeed, length: 4, index: 0)
            }
            // A separable kernel's 2D sum of squares is the square of its 1D sum of squares.
            let squares = weights.reduce(0) { $0 + $1 * $1 }
            variance += squares * squares
            if weights.count > 1 {
                for horizontal in [true, false] {
                    let (from, to) = horizontal ? (noise, scratch) : (scratch, noise)
                    var params = (UInt32(weights.count / 2), UInt32(horizontal ? 1 : 0))
                    try encode(pipelines.blur, textures: [from, to], into: commandBuffer, side: side) { encoder in
                        encoder.setBytes(weights, length: weights.count * 4, index: 0)
                        encoder.setBytes(&params, length: 8, index: 1)
                    }
                }
            }
            fields.append(noise)
        }
        var scale = 1 / variance.squareRoot()
        try encode(pipelines.combine, textures: [fields[0], fields[fields.count - 1], output], into: commandBuffer, side: side) { encoder in
            encoder.setBytes(&scale, length: 4, index: 0)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return output
    }

    private func encode(_ pipeline: MTLComputePipelineState, textures: [MTLTexture], into commandBuffer: MTLCommandBuffer,
                        side: Int, arguments: (MTLComputeCommandEncoder) -> Void) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        arguments(encoder)
        encoder.dispatchPixels(pipeline, width: side, height: side)
        encoder.endEncoding()
    }

    /// The pixel-integrated Gaussian's weights: each tap is the Gaussian's mass over that pixel.
    static func kernel(sigma: Float) -> [Float] {
        guard sigma > 0.05 else { return [1] }
        let radius = max(1, Int((3 * sigma + 0.5).rounded(.up)))
        let weights = (-radius...radius).map { i -> Float in
            let scale = 1 / (sigma * Float(2).squareRoot())
            return 0.5 * (erf((Float(i) + 0.5) * scale) - erf((Float(i) - 0.5) * scale))
        }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }
}

