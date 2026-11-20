import Foundation
import Metal

// A smart mask's edge, made on the picture it is applied to (plan section 4, "Edges and the two tiers"). A seed is a model's coarse,
// pinned answer (8 bits at the model's size); a guided filter on the untouched decode turns it into coefficients (a, b) at the seed's
// pitch, and a pixel's coverage is `clamp(a · g + b)`, g its guide: log luminance and chroma of its own light before any edit. Tier 1
// evaluates that at each texel of the 2048 slice into a refined field, which the bake composes as any raster (`MaskFieldCache`); tier 2
// per pixel in the Negative pass and the halation source (`LocalMaskShaders`). Nothing here reads a slider, a stock, grain or sharpening, so a mask never moves under its own adjustment
// (rule 3), and coefficients are kept per seed and decode, so a slider never rebuilds them (rule 2).

/// Why a smart mask cannot be refined. Its frame refuses rather than print without the mask's adjustment (plan section 7).
public enum MaskRefinerError: Error, Sendable, LocalizedError, Equatable, CustomStringConvertible {
    /// No seed store has been given to this GPU's refiner (`MaskRefiner.seeds`).
    case noSeedStore
    /// The store does not hold the seed an edit names: a lost seed refuses, never falls back to coverage 0 (plan section 7).
    case seedUnavailable(RasterID)
    /// The store's pixels for a seed are not the size the edit records.
    case seedMismatch(RasterID)
    /// A smart selection never made: a develop never runs a model (plan section 4, rule 5).
    case selectionPending(SmartKind)

    public var errorDescription: String? {
        switch self {
        case .noSeedStore: return "This frame has a smart mask, and no mask seeds are available to this render."
        case .seedUnavailable(let id): return "The seed of a smart mask (\(id.hex.prefix(12))) is missing, so the frame cannot be rendered."
        case .seedMismatch(let id): return "The seed of a smart mask (\(id.hex.prefix(12))) is not the size its edit records."
        case .selectionPending(let kind): return "The \(kind.rawValue) mask has not been made yet."
        }
    }
    public var description: String { errorDescription ?? "A smart mask cannot be refined." }
}

/// Where a smart mask's seed comes from: the pinned raster an edit names by the hash of its pixels (plan section 7). A develop gives
/// the seeds its lane loaded and checked (`MaskSeeds`); the previews give the library's store (`StoredMaskSeeds`); tests a dictionary.
/// Called from any thread, under `MaskRefiner`'s lock.
public protocol MaskSeedProvider: Sendable {
    /// The pixels `ref` names, top row first. Throw when they are not kept; the refiner reports that as `seedUnavailable`.
    func seed(for ref: RasterRef) throws -> MaskRaster
}

/// What a develop's lane holds of a frame's seeds, read by its render: exactly the pixels it checked against their names.
extension MaskSeeds: MaskSeedProvider {
    public func seed(for ref: RasterRef) throws -> MaskRaster {
        guard let raster = self[ref] else { throw MaskRefinerError.seedUnavailable(ref.id) }
        return raster
    }
}

/// The refinement's constants for one kind of seed (plan section 4's table; R9 for Sky, S3 for Person and Subject). A change to any of
/// them changes prints, so it goes with a new masks compiler (rule 6).
public struct MaskRefineParameters: Sendable, Hashable {
    /// The box radius as a share of the seed's long side, so a seed stored at another size smooths over the same part of the picture.
    public let radiusShare: Float
    /// The regularization, as a standard deviation of the guide (log2 luminance over 8, and its chroma over 8): a window whose guide
    /// varies much less than this keeps the seed's mean, one that varies much more follows the picture's edge.
    public let epsilon: Float
    /// Seed pixels a coefficient texel averages on each axis: 1, the seed's own grid, or 2.
    public let grid: Int
    /// A contrast about 0.5 on the finished coefficients: a ← g·a, b ← g·b + (1 − g)/2. 1 is none, and runs no pass.
    public let contrast: Float

    public init(radiusShare: Float, epsilon: Float, grid: Int = 1, contrast: Float = 1) {
        precondition(radiusShare > 0 && epsilon > 0 && (grid == 1 || grid == 2) && contrast > 0, "invalid refinement parameters")
        self.radiusShare = radiusShare
        self.epsilon = epsilon
        self.grid = grid
        self.contrast = contrast
    }

    /// DA3's sky head, 756 × 504 for 3:2: r 6, ε 0.01 (R9, measured on eight frames through the film).
    public static let sky = MaskRefineParameters(radiusShare: 0.008, epsilon: 0.01)
    /// Vision's `.accurate` person matte, 2016 × 1512: r 8, ε 0.02 (S3; R8's 0.001 removed 8 % of the seed's error, this 20 %), its
    /// coefficients on a grid twice as coarse: 5.8 MiB, not 23.3. S3 measured the render move p99 0.2 L*; on the plan's surface table
    /// the worst rows moved 0.01 L* and the hair crops of DSC04059 2 codes at most (this task's evidence).
    public static let person = MaskRefineParameters(radiusShare: 0.004, epsilon: 0.02, grid: 2)
    /// Vision's foreground labels, 512 × 512: r 4, ε 0.02 (S3). Background is the same seed, inverted.
    public static let subject = MaskRefineParameters(radiusShare: 0.008, epsilon: 0.02)
    /// S3OD-sod's Subject seed, 1024 on its long side: r 8, ε 0.02, then a contrast of 2 (V7's `FROZEN.md`, decision 23). Also on a dark
    /// frame's Vision seed, 512 × 512 (X3's `FROZEN.md`).
    public static let crisp = MaskRefineParameters(radiusShare: 0.008, epsilon: 0.02, grid: 1, contrast: 2)

    public static func of(_ kind: SmartKind) -> MaskRefineParameters {
        switch kind {
        case .sky: return sky
        case .person: return person
        case .subject, .background: return subject
        }
    }

    /// The filter `selection` takes. A `matte` takes none (`MaskRefinementSession.coefficients(for:)` reads its alpha); asked anyway, its
    /// kind's, which no render reads.
    public static func of(_ selection: SmartSelection) -> MaskRefineParameters {
        selection.edge == .crisp ? crisp : of(selection.kind)
    }

    /// The box radius in seed pixels.
    public func radius(seedWidth: Int, seedHeight: Int) -> Int {
        max(1, Int((radiusShare * Float(max(seedWidth, seedHeight))).rounded()))
    }

    /// The coefficient texture's size for a seed of that size.
    public func coefficientSize(seedWidth: Int, seedHeight: Int) -> (width: Int, height: Int) {
        ((seedWidth + grid - 1) / grid, (seedHeight + grid - 1) / grid)
    }
}

extension SmartKind {
    /// Whether this kind's coverage is its seed's refined coverage inverted: Background is Subject, inverted (plan section 1).
    public var invertsSeed: Bool { self == .background }
}

/// Which decode a refinement was made from: the frame's pixels, named by its image's serial, which no other loan of a texture shares,
/// for as long as it lives. A decode's pixels never change while it is rendered (the develop's in-place print writes over a frame that
/// is not rendered again), so this names its light.
public struct MaskGuideID: Sendable, Hashable {
    public let serial: UInt64
    public let width: Int
    public let height: Int
}

extension LinearFrame {
    /// The decode a smart mask's refinement on this frame reads.
    public var maskGuide: MaskGuideID { MaskGuideID(serial: image.serial, width: width, height: height) }
}

/// What a refinement is: one seed, on one decode, under one set of constants; with `field`, its refined coverage at the texels of a
/// slice of that size rather than its coefficients. A slider is none of these.
///
/// A `matte` reads no decode and takes no filter: its `guide` and `parameters` are `nil`, so every render of the picture shares its alpha.
struct MaskRefinementKey: Hashable {
    let guide: MaskGuideID?
    let raster: RasterRef
    let parameters: MaskRefineParameters?
    var field: MaskFieldSize?
    var remap: LensRemap?
}

/// How one set of coefficients was built, for the memory gate and the tests.
public struct MaskRefineBuild: Sendable, Equatable {
    public var seedWidth = 0
    public var seedHeight = 0
    public var radius = 0
    public var bands = 0
    public var bandRows = 0
    /// The working textures' bytes, as Metal allocated them (`allocatedSize`): five textures of a band's rows with their margins.
    public var workingBytes = 0
    /// The coefficient texture's bytes.
    public var outputBytes = 0
    public var gpuSeconds = 0.0
}

/// Builds and keeps smart masks' refinement coefficients. One per `GPU` (`GPU.maskRefiner`), shared by every renderer; nothing of it is
/// made until a frame has a smart mask that changes a pixel.
///
/// The build is S3's: R8's guided filter in horizontal bands, one mask at a time, all bands in one command buffer, five working textures
/// (four `rgba32Float`, one `r32Float`, 68 bytes a seed pixel) made once at the tallest band's height and reused, so the working set is
/// at most `workingSetBudget` whatever the seed, and the result equals the unbanded build's value for value. The coefficients are
/// `rgba16Float` (max coverage error 0.002, R9). The guide frame, the decode area-averaged to the 2048 slice, is made at most once a
/// render and let go with it.
///
/// Safe to call from any thread: one lock, held through a build's GPU wait (about 10 ms, at most a few tens under load), so two lanes
/// asking for one refinement build it once.
public final class MaskRefiner: @unchecked Sendable {
    /// What the refiner has done since it was made, to prove what it did not.
    public struct Statistics: Sendable, Equatable {
        public var builds = 0
        public var hits = 0
        public var guideFrames = 0
        /// Refined fields blurred by a Feather (`MaskFeather`), and the GPU time of the last blur.
        public var feathers = 0
        public var lastFeatherSeconds = 0.0
        public var lastBuild: MaskRefineBuild?
    }

    /// The working textures' budget, under the 32 MiB the gate allows (plan section 8): Metal rounds each texture up a little, so the
    /// bands are chosen against this and the measured working set is held to 32 MiB.
    public static let workingSetBudget = 28 << 20
    /// Bytes a seed pixel of a band takes in the working textures: A, B, C and the scratch in `rgba32Float`, D in `r32Float`.
    static let workingBytesPerPixel = 4 * 16 + 4
    /// Frames whose long side is shorter than this take tier 1 for every mask: the sheet and the strip at 960 px, where S3 measured the
    /// two tiers alike (plan section 4's rule). Their coefficients are not kept: the slice is, and a slider needs nothing else.
    public static let perPixelMinimumLongSide = 1024
    /// Refined masks a render evaluates per pixel: T7's four slots (textures 6 to 9). Further masks that would qualify take tier 1, in
    /// list order, rather than an argument buffer: four smart masks carrying Exposure on one frame is already past the plan's three.
    public static let perPixelLimit = 4
    /// Two decodes' coefficients for three smart masks (Sky, Person and Subject: 11 MiB each), the frame view's scaled decode and its
    /// refined one, with room for more seeds.
    public static let defaultMaximumBytes = 32 << 20

    private struct Pipelines {
        let field: MTLComputePipelineState
        let guideFrame: MTLComputePipelineState
        let down: MTLComputePipelineState
        let terms: MTLComputePipelineState
        let boxH: MTLComputePipelineState
        let boxV: MTLComputePipelineState
        let solve: MTLComputePipelineState
        let out: MTLComputePipelineState
        let feather: MTLComputePipelineState
        let contrast: MTLComputePipelineState
        let alphaField: MTLComputePipelineState
    }

    /// Mirrors `MaskFeatherPass` in `ShaderSource.maskRefiner`.
    struct FeatherPass {
        var radius: UInt32 = 0
        var vertical: UInt32 = 0
    }

    /// Mirrors `MaskRefineBand` in `ShaderSource.maskRefiner`.
    struct Band {
        var w: UInt32 = 0, h: UInt32 = 0
        var epsilon: Float = 0
        var r: Int32 = 0
        var s: UInt32 = 0, rows: UInt32 = 0, outRow0: UInt32 = 0, outRows: UInt32 = 0
        var grid: UInt32 = 1, outWidth: UInt32 = 0, outHeight: UInt32 = 0, unused: UInt32 = 0
    }

    private struct Entry {
        let key: MaskRefinementKey
        let texture: MTLTexture
        /// A `matte`'s entry is a view (`alphaViewLocked`): its bytes are the texture it reads.
        var bytes: Int { (texture.parent ?? texture).allocatedSize }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lock = NSLock()
    private var pipelines: Pipelines?
    private var resample: MTLComputePipelineState?
    /// Oldest first.
    private var entries: [Entry] = []
    private var limit: Int
    private var counts = Statistics()
    private var store: MaskSeedProvider?

    public init(device: MTLDevice, queue: MTLCommandQueue, maximumBytes: Int = MaskRefiner.defaultMaximumBytes) {
        self.device = device
        self.queue = queue
        self.limit = maximumBytes
    }

    /// Where seeds come from. The owner of the GPU sets it once; a frame with a smart mask and no store refuses (`noSeedStore`).
    public var seeds: MaskSeedProvider? {
        get { lock.withLock { store } }
        set { lock.withLock { store = newValue } }
    }

    public var statistics: Statistics { lock.withLock { counts } }
    /// Whether anything has been asked of Metal yet. A frame with no smart mask leaves this false.
    var hasPipelines: Bool { lock.withLock { pipelines != nil } }
    /// The bytes of the coefficients kept. Those a render still holds after they were let go are not among them.
    public var residentBytes: Int { lock.withLock { entries.reduce(0) { $0 + $1.bytes } } }
    /// Changing it evicts at once if it must. A develop keeps none between frames (0).
    public var maximumBytes: Int {
        get { lock.withLock { limit } }
        set { lock.withLock { limit = newValue; evict(to: newValue) } }
    }

    /// Frees every kept refinement, for `FilmPreviews.trimForDevelop`. They are quick to make again.
    public func removeAll() { lock.withLock { evict(to: 0) } }

    /// What refining `masks` adds to a render of the full-size `picture` at its peak, for the develop's memory gate: the guide frame,
    /// every smart selection's coefficients and refined field (all held while the render's slice is baked and its passes run), the
    /// largest working set (one build at a time) and its seed. Nothing for a set without a smart selection that is on. Three masks, Sky,
    /// Person and Subject at their stored sizes on a 3:2 frame: 82.8 MB (S3 measured 78.5 MiB at 8 bands with the person matte on its
    /// full grid and no fields). A selection with a Feather adds its blurred field, held until the slice is baked, and the blur's
    /// `r32Float` pass: 16.8 MB on a 3:2 frame, counted for each so a bake's worst is covered. A `matte` adds its alpha texture and its field and
    /// no working set; a set of nothing but mattes reads no decode, so it adds no guide frame either.
    public static func developBytes(masks: MaskSet, picture: MaskSpace) -> Int {
        let selections = masks.masks.filter(\.readsSmartSelection).flatMap(\.components).compactMap { component -> SmartSelection? in
            guard case .smart(let selection) = component.shape, selection.raster != nil else { return nil }
            return selection
        }
        guard !selections.isEmpty else { return 0 }
        let field = MaskFieldSize(picture: picture)
        let feathered = Set(selections.filter { $0.feather > 0 }).count * field.width * field.height * (2 + 4)
        var coefficients = feathered, working = 0, seen = Set<String>()
        for selection in selections {
            // A seed takes its coefficients once for each edge, as `MaskRefinementKey` keys them: Subject and Background share one.
            guard let raster = selection.raster, seen.insert(raster.id.hex + selection.edge.rawValue).inserted else { continue }
            guard selection.edge != .matte else {
                coefficients += raster.width * raster.height + field.width * field.height * 2
                continue
            }
            let parameters = MaskRefineParameters.of(selection)
            let size = parameters.coefficientSize(seedWidth: raster.width, seedHeight: raster.height)
            coefficients += size.width * size.height * 8 + field.width * field.height * 2
            let r = parameters.radius(seedWidth: raster.width, seedHeight: raster.height)
            let rows = min(raster.height, bandRows(seedWidth: raster.width, seedHeight: raster.height, radius: r, grid: parameters.grid) + 4 * r)
            working = max(working, workingBytesPerPixel * raster.width * rows + raster.width * raster.height)
        }
        let guideFrame = selections.contains { $0.edge != .matte } ? field.width * field.height * 8 : 0
        return guideFrame + coefficients + working
    }

    private func evict(to bytes: Int) {
        var held = entries.reduce(0) { $0 + $1.bytes }
        while held > bytes, !entries.isEmpty { held -= entries.removeFirst().bytes }
    }

    /// A render's refinement of `frame`, whose full-size picture is `picture`: what the bake and tier 2 ask of it, made as they ask.
    /// Holding it holds the guide frame once made, so let it go when the render has its inputs. Its seeds come from `seeds` where given,
    /// as a develop gives what its lane holds, and from `MaskRefiner.seeds` otherwise.
    public func session(for frame: LinearFrame, picture: MaskSpace, seeds: (any MaskSeedProvider)? = nil) -> MaskRefinementSession {
        MaskRefinementSession(refiner: self, frame: frame, fieldSize: MaskFieldSize(picture: picture), seeds: seeds)
    }

    // MARK: kept coefficients

    /// The coefficients `key` names, kept or made by `make` (under the lock, so two lanes make them once). `keep` false hands them over
    /// without keeping them, for a render that needs them only to bake its slice.
    func coefficients(_ key: MaskRefinementKey, keep: Bool, make: () throws -> MTLTexture) throws -> MTLTexture {
        try lock.withLock {
            if let index = entries.lastIndex(where: { $0.key == key }) {
                let entry = entries.remove(at: index)
                entries.append(entry)
                counts.hits += 1
                return entry.texture
            }
            let texture = try make()
            if keep {
                entries.append(Entry(key: key, texture: texture))
                evict(to: limit)
            }
            return texture
        }
    }

    /// The seed `ref` names, from `given` or the store, as an `r8Unorm` texture with the picture's bottom in row 0 (the flip at upload).
    /// Under the lock.
    func seedTextureLocked(_ ref: RasterRef, from given: (any MaskSeedProvider)?, remap: LensRemap? = nil) throws -> MTLTexture {
        guard let store = given ?? store else { throw MaskRefinerError.noSeedStore }
        let raster: MaskRaster
        do { raster = try store.seed(for: ref) } catch { throw MaskRefinerError.seedUnavailable(ref.id) }
        guard raster.width == ref.width, raster.height == ref.height else { throw MaskRefinerError.seedMismatch(ref.id) }
        let seed = try upload(raster)
        return try remap.map { try resampledLocked(seed, by: $0) } ?? seed
    }

    private func resampledLocked(_ seed: MTLTexture, by remap: LensRemap) throws -> MTLTexture {
        let state: MTLComputePipelineState
        if let resample { state = resample }
        else {
            let source = "#include <metal_stdlib>\nusing namespace metal;\n" + ShaderSource.maskRemapPoint + "\n" + ShaderSource.maskResample
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: "mask_resample") else { throw GPUError.shaderFunctionMissing("mask_resample") }
            state = try device.makeComputePipelineState(function: function)
            resample = state
        }
        let texture = try GPU.makeTexture(device: device, width: seed.width, height: seed.height,
                                          usage: [.shaderRead, .shaderWrite], pixelFormat: .r8Unorm)
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(state)
        encoder.setTexture(seed, index: 0)
        encoder.setTexture(texture, index: 1)
        var extent = SIMD2(remap.extent.x, remap.extent.y)
        encoder.setBytes(&extent, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        try BrushReplay.bind(remap.ratio, index: 1, encoder: encoder, device: device)
        encoder.dispatchPixels(state, width: seed.width, height: seed.height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return texture
    }

    /// `raster` as an `r8Unorm` texture, rows flipped so row 0 is the picture's bottom, as a frame's.
    func upload(_ raster: MaskRaster) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: raster.width, height: raster.height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
        texture.label = "Mask seed"
        var flipped = [UInt8](repeating: 0, count: raster.plane.count)
        for row in 0..<raster.height {
            let from = row * raster.width, to = (raster.height - 1 - row) * raster.width
            flipped[to..<(to + raster.width)] = raster.plane[from..<(from + raster.width)]
        }
        flipped.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, raster.width, raster.height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: raster.width)
        }
        return texture
    }

    // MARK: building

    /// Compiles the refiner's kernels, for a first use that should not wait for them: a Follow edges stroke's release, which is otherwise the
    /// first thing on a frame with no smart mask to ask for them.
    public func prepare() throws { _ = try lock.withLock { try pipeline() } }

    private func pipeline() throws -> Pipelines {
        if let pipelines { return pipelines }
        let library = try device.makeLibrary(source: ShaderSource.maskRefiner, options: nil)
        func state(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
            return try device.makeComputePipelineState(function: function)
        }
        let made = Pipelines(field: try state("mask_refine_field"), guideFrame: try state("mask_refine_guide_frame"), down: try state("mask_refine_down"),
                             terms: try state("mask_refine_terms"), boxH: try state("mask_refine_box_h"),
                             boxV: try state("mask_refine_box_v"), solve: try state("mask_refine_solve"), out: try state("mask_refine_out"),
                             feather: try state("mask_feather_pass"), contrast: try state("mask_refine_contrast"),
                             alphaField: try state("mask_refine_alpha_field"))
        pipelines = made
        return made
    }

    /// The guide frame for `frame`: its light area-averaged to `size`, the slice's, or the frame itself where it is no larger (the sheet's
    /// 960 px decode is its own guide frame, as S3 measured it). `rgba16Float`, 22 MiB on a 3:2 frame; nothing keeps it.
    func guideFrame(for frame: LinearFrame, size: MaskFieldSize) throws -> MTLTexture {
        try lock.withLock { try guideFrameLocked(for: frame, size: size) }
    }

    func guideFrameLocked(for frame: LinearFrame, size: MaskFieldSize) throws -> MTLTexture {
        guard frame.width > size.width || frame.height > size.height else { return frame.texture }
        let made = try pipeline()
        let texture = try GPU.makeTexture(device: device, width: size.width, height: size.height, usage: [.shaderRead, .shaderWrite])
        texture.label = "Mask guide frame"
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(made.guideFrame)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.dispatchPixels(made.guideFrame, width: size.width, height: size.height)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime(frame) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        counts.guideFrames += 1
        return texture
    }

    /// A `matte`'s stored alpha, ready to be read as coefficients: the `r8Unorm` texture every surface samples bilinearly, in a view that reads
    /// `(0, 0, 0, α)`, so `mask_refined` gives α with no term in the guide (Y2 section 10). 4.2 MiB on a 3:2 frame's 2560 px print. No filter,
    /// no working set and no guide frame are made for it. Under the lock.
    func alphaViewLocked(_ ref: RasterRef, from given: (any MaskSeedProvider)?, remap: LensRemap? = nil) throws -> MTLTexture {
        let alpha = try seedTextureLocked(ref, from: given, remap: remap)
        guard let view = alpha.makeTextureView(pixelFormat: .r8Unorm, textureType: .type2D, levels: 0..<1, slices: 0..<1,
                                               swizzle: MTLTextureSwizzleChannels(red: .zero, green: .zero, blue: .zero, alpha: .red)) else {
            throw GPUError.textureAllocation
        }
        view.label = "Mask alpha"
        return view
    }

    /// A `matte`'s alpha at each texel of a slice of `size`, sampled bilinearly at the texel's uv as tier 2 samples it at a pixel's: `r16Float`,
    /// so the bake reads it as any raster. It reads no decode. Under the lock.
    func alphaFieldLocked(alpha: MTLTexture, size: MaskFieldSize) throws -> MTLTexture {
        let made = try pipeline()
        let texture = try GPU.makeTexture(device: device, width: size.width, height: size.height, usage: [.shaderRead, .shaderWrite],
                                          pixelFormat: .r16Float)
        texture.label = "Mask alpha field"
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(made.alphaField)
        encoder.setTexture(alpha, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.dispatchPixels(made.alphaField, width: size.width, height: size.height)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime(alpha) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        return texture
    }

    /// A selection's refined coverage at each texel of a slice of `size`: `coefficients` read at the texel's uv and dotted with the guide
    /// of `guideFrame`'s light there, in `r16Float` as a brush canvas, so the bake reads it as any raster. Under the lock.
    func fieldLocked(coefficients: MTLTexture, guideFrame: MTLTexture, size: MaskFieldSize) throws -> MTLTexture {
        let made = try pipeline()
        let texture = try GPU.makeTexture(device: device, width: size.width, height: size.height, usage: [.shaderRead, .shaderWrite],
                                          pixelFormat: .r16Float)
        texture.label = "Mask refined field"
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(made.field)
        encoder.setTexture(guideFrame, index: 0)
        encoder.setTexture(coefficients, index: 1)
        encoder.setTexture(texture, index: 2)
        encoder.dispatchPixels(made.field, width: size.width, height: size.height)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((guideFrame, coefficients)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        return texture
    }

    /// `fieldLocked`, taking the lock: a Follow edges stroke's refined shape (`FollowEdgesMeasurement`).
    func field(coefficients: MTLTexture, guideFrame: MTLTexture, size: MaskFieldSize) throws -> MTLTexture {
        try lock.withLock { try fieldLocked(coefficients: coefficients, guideFrame: guideFrame, size: size) }
    }

    /// `field`, a refined field of `size`, blurred by a selection's Feather (`MaskFeather`) into a new `r16Float` field: along rows into
    /// an `r32Float` texture, then along columns. Nothing keeps it: the slice it is baked into is kept, and a Feather drag would otherwise
    /// push the coefficients out. Under the lock.
    func featheredLocked(_ field: MTLTexture, feather: Float, size: MaskFieldSize) throws -> MTLTexture {
        let made = try pipeline()
        let sigma = MaskFeather.texelSigma(feather, size: size)
        let across = try GPU.makeTexture(device: device, width: size.width, height: size.height, usage: [.shaderRead, .shaderWrite],
                                         pixelFormat: .r32Float)
        across.label = "Mask feather pass"
        let texture = try GPU.makeTexture(device: device, width: size.width, height: size.height, usage: [.shaderRead, .shaderWrite],
                                          pixelFormat: .r16Float)
        texture.label = "Mask feathered field"
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(made.feather)
        for (vertical, from, to, s) in [(false, field, across, sigma.x), (true, across, texture, sigma.y)] {
            let weights = MaskFeather.weights(sigma: s)
            var pass = FeatherPass(radius: UInt32(weights.count - 1), vertical: vertical ? 1 : 0)
            encoder.setTexture(from, index: 0)
            encoder.setTexture(to, index: 1)
            encoder.setBytes(&pass, length: MemoryLayout<FeatherPass>.stride, index: 0)
            weights.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            encoder.dispatchPixels(made.feather, width: size.width, height: size.height)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((field, across)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        counts.feathers += 1
        counts.lastFeatherSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        return texture
    }

    /// `featheredLocked`, taking the lock.
    func feathered(_ field: MTLTexture, feather: Float, size: MaskFieldSize) throws -> MTLTexture {
        try lock.withLock { try featheredLocked(field, feather: feather, size: size) }
    }

    /// The seed rows a band holds for a seed `width` pixels wide at `radius`: as many as `workingSetBudget` allows with their 2 r margin
    /// on each side, even on a grid of 2 so a band holds whole coefficient rows, at least the grid.
    static func bandRows(seedWidth: Int, seedHeight: Int, radius: Int, grid: Int) -> Int {
        let fit = workingSetBudget / (workingBytesPerPixel * max(seedWidth, 1)) - 4 * radius
        let rows = min(max(fit, grid), seedHeight)
        return grid == 2 && rows < seedHeight ? max(2, rows & ~1) : rows
    }

    /// The coefficients of `seed` (an `r8Unorm` texture, row 0 the picture's bottom) against `guideFrame`, in bands of `bandRows` seed
    /// rows, or as many as the budget allows. One band is the unbanded build. Not kept: `coefficients(_:keep:make:)` keeps.
    func build(seed: MTLTexture, guideFrame: MTLTexture, parameters: MaskRefineParameters,
               bandRows requested: Int? = nil) throws -> (texture: MTLTexture, build: MaskRefineBuild) {
        try lock.withLock { try buildLocked(seed: seed, guideFrame: guideFrame, parameters: parameters, bandRows: requested) }
    }

    func buildLocked(seed: MTLTexture, guideFrame: MTLTexture, parameters: MaskRefineParameters,
                     bandRows requested: Int?) throws -> (texture: MTLTexture, build: MaskRefineBuild) {
        let made = try pipeline()
        let w = seed.width, h = seed.height, grid = parameters.grid
        let r = parameters.radius(seedWidth: w, seedHeight: h)
        let margin = 2 * r
        var rows = min(max(requested ?? Self.bandRows(seedWidth: w, seedHeight: h, radius: r, grid: grid), 1), h)
        if grid == 2, rows < h { rows = max(2, rows & ~1) }
        let textureRows = min(h, rows + 2 * margin)
        func working(_ format: MTLPixelFormat, _ label: String) throws -> MTLTexture {
            let texture = try GPU.makeTexture(device: device, width: w, height: textureRows, usage: [.shaderRead, .shaderWrite],
                                              pixelFormat: format)
            texture.label = label
            return texture
        }
        let a = try working(.rgba32Float, "Refine A"), b = try working(.rgba32Float, "Refine B"), c = try working(.rgba32Float, "Refine C")
        let d = try working(.r32Float, "Refine D"), scratch = try working(.rgba32Float, "Refine scratch")
        let size = parameters.coefficientSize(seedWidth: w, seedHeight: h)
        let output = try GPU.makeTexture(device: device, width: size.width, height: size.height, usage: [.shaderRead, .shaderWrite])
        output.label = "Mask coefficients"
        var report = MaskRefineBuild(seedWidth: w, seedHeight: h, radius: r, bands: (h + rows - 1) / rows, bandRows: rows,
                                     workingBytes: [a, b, c, d, scratch].reduce(0) { $0 + $1.allocatedSize },
                                     outputBytes: output.allocatedSize)

        var band = Band(w: UInt32(w), h: UInt32(h), epsilon: parameters.epsilon, r: Int32(r), grid: UInt32(grid),
                        outWidth: UInt32(size.width), outHeight: UInt32(size.height))
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        // Every band in one command buffer and one serial encoder: the working textures are reused band after band, and Metal orders
        // the reads after the writes.
        var y0 = 0
        while y0 < h {
            let y1 = min(h, y0 + rows)
            let s = max(0, y0 - margin), e = min(h, y1 + margin)
            band.s = UInt32(s)
            band.rows = UInt32(e - s)
            band.outRow0 = UInt32(y0 / grid)
            band.outRows = UInt32((y1 + grid - 1) / grid - y0 / grid)
            let bandHeight = e - s
            func dispatch(_ state: MTLComputePipelineState, _ textures: [MTLTexture], width: Int = w, height: Int) {
                encoder.setComputePipelineState(state)
                for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
                encoder.setBytes(&band, length: MemoryLayout<Band>.stride, index: 0)
                encoder.dispatchPixels(state, width: width, height: height)
            }
            dispatch(made.down, [guideFrame, seed, a], height: bandHeight)
            dispatch(made.terms, [a, b, c, d], height: bandHeight)
            for term in [a, b, c, d] {
                dispatch(made.boxH, [term, scratch], height: bandHeight)
                dispatch(made.boxV, [scratch, term], height: bandHeight)
            }
            dispatch(made.solve, [a, b, c, d, scratch], height: bandHeight)
            dispatch(made.boxH, [scratch, a], height: bandHeight)
            dispatch(made.out, [a, output], width: size.width, height: Int(band.outRows))
            y0 = y1
        }
        if parameters.contrast != 1 {
            // On the finished coefficients, after the last band, as V5 measured it: in place on what the bands wrote.
            var gain = parameters.contrast
            encoder.setComputePipelineState(made.contrast)
            encoder.setTexture(output, index: 0)
            encoder.setBytes(&gain, length: MemoryLayout<Float>.stride, index: 0)
            encoder.dispatchPixels(made.contrast, width: size.width, height: size.height)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((seed, guideFrame, a, b, c, d, scratch)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        report.gpuSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        counts.builds += 1
        counts.lastBuild = report
        return (output, report)
    }

    // MARK: the CPU reference

    /// A pixel's guide, as `mask_refined_guide` makes it: log2 of its Rec. 2020 luminance, of blue and of red over it, each over 8,
    /// with a floor of 1e-4.
    public static func guide(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let c = SIMD3<Float>(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0))
        let y = (c * Rec2020.luma).sum(), d: Float = 1e-4
        return SIMD3(log2(y + d), log2((c.z + d) / (y + d)), log2((c.x + d) / (y + d))) / 8
    }

    /// The coefficients on the CPU, in double precision: `seed` (top row first, as stored) against `guide` (linear light, `guideWidth`
    /// by `guideHeight`, row 0 the picture's bottom, as a texture), the kernels' arithmetic unbanded. The result is the coefficient
    /// grid's texels, row 0 the picture's bottom.
    static func reference(seed: MaskRaster, guide pixels: [SIMD3<Float>], guideWidth fw: Int, guideHeight fh: Int,
                          parameters: MaskRefineParameters) -> [SIMD4<Double>] {
        let w = seed.width, h = seed.height, r = parameters.radius(seedWidth: w, seedHeight: h)
        // A: each seed pixel's guide and value, its rows as a texture's.
        var guides = [SIMD3<Double>](repeating: .zero, count: w * h), values = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            let fy0 = Double(y) * Double(fh) / Double(h), fy1 = Double(y + 1) * Double(fh) / Double(h)
            for x in 0..<w {
                let fx0 = Double(x) * Double(fw) / Double(w), fx1 = Double(x + 1) * Double(fw) / Double(w)
                var sum = SIMD3<Double>.zero, weights = 0.0
                for yy in Int(fy0.rounded(.down))..<min(Int(fy1.rounded(.up)), fh) {
                    let wy = min(Double(yy + 1), fy1) - max(Double(yy), fy0)
                    for xx in Int(fx0.rounded(.down))..<min(Int(fx1.rounded(.up)), fw) {
                        let wx = min(Double(xx + 1), fx1) - max(Double(xx), fx0)
                        let p = pixels[yy * fw + xx]
                        sum += wx * wy * SIMD3(Double(p.x), Double(p.y), Double(p.z))
                        weights += wx * wy
                    }
                }
                let mean = sum / max(weights, 1e-6)
                let g = guide(SIMD3(Float(mean.x), Float(mean.y), Float(mean.z)))
                guides[y * w + x] = SIMD3(Double(g.x), Double(g.y), Double(g.z))
                values[y * w + x] = Double(seed.plane[(h - 1 - y) * w + x]) / 255
            }
        }
        func box<T: SIMD>(_ v: [T]) -> [T] where T.Scalar == Double {
            var across = v
            for y in 0..<h {
                for x in 0..<w {
                    var s = T()
                    for i in -r...r { s += v[y * w + min(max(x + i, 0), w - 1)] }
                    across[y * w + x] = s / Double(2 * r + 1)
                }
            }
            var out = across
            for y in 0..<h {
                for x in 0..<w {
                    var s = T()
                    for i in -r...r { s += across[min(max(y + i, 0), h - 1) * w + x] }
                    out[y * w + x] = s / Double(2 * r + 1)
                }
            }
            return out
        }
        let a = box(zip(guides, values).map { SIMD4($0.x, $0.y, $0.z, $1) })
        let gg = box(guides.map { SIMD8($0.x * $0.x, $0.x * $0.y, $0.x * $0.z, $0.y * $0.y, $0.y * $0.z, $0.z * $0.z, 0, 0) })
        let gp = box(zip(guides, values).map { SIMD4($0.x * $1, $0.y * $1, $0.z * $1, 0) })
        let e2 = Double(parameters.epsilon) * Double(parameters.epsilon)
        let solved: [SIMD4<Double>] = (0..<(w * h)).map { i in
            let mu = SIMD3(a[i].x, a[i].y, a[i].z), mp = a[i].w, s = gg[i], q = gp[i]
            let m = [[s[0] - mu.x * mu.x + e2, s[1] - mu.x * mu.y, s[2] - mu.x * mu.z],
                     [s[1] - mu.x * mu.y, s[3] - mu.y * mu.y + e2, s[4] - mu.y * mu.z],
                     [s[2] - mu.x * mu.z, s[4] - mu.y * mu.z, s[5] - mu.z * mu.z + e2]]
            let k = solve3(m, [q.x - mu.x * mp, q.y - mu.y * mp, q.z - mu.z * mp])
            return SIMD4(k[0], k[1], k[2], mp - (k[0] * mu.x + k[1] * mu.y + k[2] * mu.z))
        }
        let final = box(solved)
        guard parameters.grid == 2 else { return final }
        let size = parameters.coefficientSize(seedWidth: w, seedHeight: h)
        return (0..<(size.width * size.height)).map { i in
            let x0 = 2 * (i % size.width), y0 = 2 * (i / size.width), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
            return (final[y0 * w + x0] + final[y0 * w + x1] + final[y1 * w + x0] + final[y1 * w + x1]) / 4
        }
    }

    /// Gaussian elimination with partial pivots, in double precision: the reference's solve, independent of the kernel's LDL.
    private static func solve3(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
        var m = matrix, v = vector
        for column in 0..<3 {
            let pivot = (column..<3).max { abs(m[$0][column]) < abs(m[$1][column]) }!
            m.swapAt(column, pivot); v.swapAt(column, pivot)
            for row in (column + 1)..<3 {
                let f = m[row][column] / m[column][column]
                for k in column..<3 { m[row][k] -= f * m[column][k] }
                v[row] -= f * v[column]
            }
        }
        var x = [0.0, 0.0, 0.0]
        for row in stride(from: 2, through: 0, by: -1) {
            var s = v[row]
            for k in (row + 1)..<3 { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x
    }

    /// A pixel's refined coverage on the CPU: `coefficients` (`width` by `height`, row 0 the picture's bottom) sampled bilinearly with
    /// clamped edges at `uv`, as the sampler reads them, dotted with the guide of `rgb`.
    public static func refined(_ coefficients: [SIMD4<Float>], width: Int, height: Int, uv: SIMD2<Float>, rgb: SIMD3<Float>) -> Float {
        let s = uv * SIMD2(Float(width), Float(height)) - 0.5
        let cell = s.rounded(.down), t = s - cell
        let x0 = min(max(Int(cell.x), 0), width - 1), x1 = min(max(Int(cell.x) + 1, 0), width - 1)
        let y0 = min(max(Int(cell.y), 0), height - 1), y1 = min(max(Int(cell.y) + 1, 0), height - 1)
        func at(_ x: Int, _ y: Int) -> SIMD4<Float> { coefficients[y * width + x] }
        let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * t.x
        let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * t.x
        let k = top + (bottom - top) * t.y
        let g = guide(rgb)
        return min(max(k.x * g.x + k.y * g.y + k.z * g.z + k.w, 0), 1)
    }
}

/// One render's refinement of one decode: the guide frame, made the first time the bake or tier 2 needs it and let go with this, and
/// each smart selection's coefficients, kept by the refiner where this render evaluates them per pixel. Used by one render on one thread.
public final class MaskRefinementSession {
    public let guide: MaskGuideID
    public let fieldSize: MaskFieldSize
    /// Whether this frame takes tier 2 at all: false for frames under `MaskRefiner.perPixelMinimumLongSide`.
    public let perPixel: Bool
    let refiner: MaskRefiner
    private let frame: LinearFrame
    private let seeds: (any MaskSeedProvider)?
    private var frameTexture: MTLTexture?

    init(refiner: MaskRefiner, frame: LinearFrame, fieldSize: MaskFieldSize, seeds: (any MaskSeedProvider)?) {
        self.refiner = refiner
        self.frame = frame
        self.fieldSize = fieldSize
        self.seeds = seeds
        guide = frame.maskGuide
        perPixel = max(frame.width, frame.height) >= MaskRefiner.perPixelMinimumLongSide
    }

    /// Where this render reads a Follow edges stroke's measured shape (`MeasuredStroke`): the seeds it was given, as a develop gives what
    /// its lane loaded and checked, or the refiner's store, as the previews have it.
    public var shapes: any MaskSeedProvider { MaskRefinerShapes(refiner: refiner, given: seeds) }

    /// The guide frame, made once.
    func guideFrame() throws -> MTLTexture {
        if let frameTexture { return frameTexture }
        let made = try refiner.guideFrame(for: frame, size: fieldSize)
        frameTexture = made
        return made
    }

    /// `selection`'s coefficients on this decode: kept, or built from its seed. Refuses a selection with no seed yet, and a seed the
    /// store does not hold.
    func remap(for s: SmartSelection) -> LensRemap? { frame.maskLens?.toMask(.smart(s)) }

    func coefficients(for selection: SmartSelection) throws -> MTLTexture {
        guard let raster = selection.raster else { throw MaskRefinerError.selectionPending(selection.kind) }
        if selection.edge == .matte {
            return try refiner.coefficients(MaskRefinementKey(guide: nil, raster: raster, parameters: nil, remap: remap(for: selection)), keep: perPixel) {
                try refiner.alphaViewLocked(raster, from: seeds, remap: remap(for: selection))
            }
        }
        let parameters = MaskRefineParameters.of(selection)
        let key = MaskRefinementKey(guide: guide, raster: raster, parameters: parameters, remap: remap(for: selection))
        return try refiner.coefficients(key, keep: perPixel) {
            let seed = try refiner.seedTextureLocked(raster, from: seeds, remap: remap(for: selection))
            return try refiner.buildLocked(seed: seed, guideFrame: try guideFrameLocked(), parameters: parameters, bandRows: nil).texture
        }
    }

    /// `selection`'s refined coverage at each texel of this render's slice, for the bake (tier 1) and a brush's overlay: kept beside its
    /// coefficients, and built from them. With a Feather, that field blurred (`MaskFeather`), made each time it is asked for and not
    /// kept: the slice keeps it, and the refined field it is made from is kept as before.
    public func field(for selection: SmartSelection) throws -> MTLTexture {
        guard let raster = selection.raster else { throw MaskRefinerError.selectionPending(selection.kind) }
        let coefficients = try self.coefficients(for: selection)
        let refined: MTLTexture
        if selection.edge == .matte {
            let key = MaskRefinementKey(guide: nil, raster: raster, parameters: nil, field: fieldSize, remap: remap(for: selection))
            refined = try refiner.coefficients(key, keep: perPixel) { try refiner.alphaFieldLocked(alpha: coefficients, size: fieldSize) }
        } else {
            let key = MaskRefinementKey(guide: guide, raster: raster, parameters: MaskRefineParameters.of(selection), field: fieldSize, remap: remap(for: selection))
            refined = try refiner.coefficients(key, keep: perPixel) {
                try refiner.fieldLocked(coefficients: coefficients, guideFrame: try guideFrameLocked(), size: fieldSize)
            }
        }
        guard selection.feather > 0 else { return refined }
        return try refiner.feathered(refined, feather: selection.feather, size: fieldSize)
    }

    /// The guide frame from inside the refiner's lock, which `guideFrame(for:size:)` would take again.
    private func guideFrameLocked() throws -> MTLTexture {
        if let frameTexture { return frameTexture }
        let made = try refiner.guideFrameLocked(for: frame, size: fieldSize)
        frameTexture = made
        return made
    }
}

/// A render's measured shapes: from the seeds it was given, else the refiner's store (`MaskRefinementSession.shapes`).
struct MaskRefinerShapes: MaskSeedProvider {
    let refiner: MaskRefiner
    let given: (any MaskSeedProvider)?
    func seed(for ref: RasterRef) throws -> MaskRaster {
        guard let store = given ?? refiner.seeds else { throw MaskRefinerError.noSeedStore }
        return try store.seed(for: ref)
    }
}
