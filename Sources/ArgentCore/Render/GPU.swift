import CoreImage
import Metal

public enum GPUError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case noColorSpace
    case textureAllocation
    case shaderFunctionMissing(String)
    /// A command buffer gave no compute encoder; the pass would leave its output as the pool
    /// handed it over, another frame's pixels, so it fails instead.
    case noEncoder

    public var description: String {
        switch self {
        case .noDevice: return "No Metal device is available."
        case .noCommandQueue: return "Could not create a Metal command queue."
        case .noColorSpace: return "Could not create the working color space."
        case .textureAllocation: return "Could not allocate a Metal texture."
        case .shaderFunctionMissing(let name): return "Shader function \(name) is missing."
        case .noEncoder: return "Could not create a Metal compute encoder."
        }
    }
}

/// The working space's Rec. 2020 luminance weights, red, green and blue: the one copy in Swift. The
/// Metal sources (`Shaders.swift`, `BayerDemosaic.swift`) carry the same literals, and `GrayCard`
/// the same in double precision.
public enum Rec2020 {
    public static let luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)
}

/// The shared Metal device, command queue, and Core Image context for one pipeline.
///
/// One `GPU` per pipeline. It is not thread-safe, apart from the texture pool; its owners
/// (`RollDeveloper`, `FilmPreviews`, the spike) queue the work on it.
public final class GPU {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    /// The Core Image context work on this GPU shares, unless it asks for its own (`makeContext`).
    public var ciContext: CIContext { contextLock.withLock { context } }
    private var context: CIContext
    /// The context Apple's RAW 9 decodes share (`learnedContext`), made on first use.
    private var learned: CIContext?
    private let contextLock = NSLock()
    /// Scene-linear working space with Rec. 2020 primaries, as the spec requires.
    public let workingColorSpace: CGColorSpace
    /// The working space Apple's RAW 9 decodes run in: extended linear sRGB. RAW 9 renders wrong colour
    /// in a wide working space (linear Rec. 2020 collapses red and turns a frame cyan; linear Display P3
    /// is wrong too) and right in Core Image's default, extended linear sRGB, where RAW 8 is right in
    /// every space (measured, docs/decoder.md section 18). So a RAW 9 decode works in extended linear
    /// sRGB in half floats and is converted to `workingColorSpace` as it is written: colours outside
    /// sRGB are negative there and come through the conversion.
    public let learnedWorkingColorSpace: CGColorSpace
    /// Display-referred output space for exports.
    public let outputColorSpace: CGColorSpace
    /// Frame-sized textures shared by the decoder and the render graph.
    public let texturePool: TexturePool
    /// Grain noise tiles by output pitch, shared by every renderer on this device.
    public let grainField: GrainField
    /// Masks' coverage fields, shared by every renderer on this device. Nothing of it is made until a frame has masks.
    public let maskFields: MaskFieldCache
    /// Smart masks' refinement, shared by every renderer on this device: the guided filter's coefficients per seed and decode, and
    /// where seeds come from (`MaskRefiner.seeds`). Nothing of it is made until a frame has a smart mask.
    public let maskRefiner: MaskRefiner
    /// Presence's analyses of decodes, shared by every renderer on this device, so a stock switch or a drag keeps them: one a decode,
    /// made the first time a render of it has Texture, Clarity or Dehaze set. Nothing of it is made until then.
    public let presenceAnalyses: PresenceAnalyses
    private var compiledLibrary: MTLLibrary?
    private let localMaskLock = NSLock()
    private var localMask: LocalMaskPipelines?

    /// `maxIdlePoolBytes` caps what the texture pool keeps between uses; see `TexturePool`.
    public init(maxIdlePoolBytes: Int = 800_000_000) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw GPUError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw GPUError.noCommandQueue }
        guard let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
              let learned = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let output = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw GPUError.noColorSpace }

        self.device = device
        self.queue = queue
        self.workingColorSpace = working
        self.learnedWorkingColorSpace = learned
        self.outputColorSpace = output
        self.texturePool = TexturePool(device: device, maxIdleBytes: maxIdlePoolBytes)
        self.grainField = GrainField(device: device, queue: queue)
        self.maskFields = MaskFieldCache(device: device, queue: queue)
        self.maskRefiner = MaskRefiner(device: device, queue: queue)
        self.presenceAnalyses = PresenceAnalyses(builder: PresenceAnalysisBuilder(device: device, queue: queue))
        self.context = Self.makeContext(device: device, workingColorSpace: working)
    }

    /// Replaces `ciContext` with a new one. Core Image keeps working surfaces in a context for the
    /// sizes it has rendered, and neither `clearCaches` nor `reclaimResources` gives them back; they go
    /// with the context, once work under way with it has let it go.
    public func renewContext() {
        let made = Self.makeContext(device: device, workingColorSpace: workingColorSpace)
        contextLock.withLock {
            context = made
            // RAW 9's is made again when next wanted.
            learned = nil
        }
    }

    /// A Core Image context like `ciContext`, for work whose memory should go when it is done.
    public func makeContext() -> CIContext {
        Self.makeContext(device: device, workingColorSpace: workingColorSpace)
    }

    /// The Core Image context Apple's RAW 9 decodes share, working in `learnedWorkingColorSpace`;
    /// `renewContext` replaces it with the shared one.
    public var learnedContext: CIContext {
        contextLock.withLock {
            if let learned { return learned }
            let made = Self.makeContext(device: device, workingColorSpace: learnedWorkingColorSpace)
            learned = made
            return made
        }
    }

    /// A context like `learnedContext`, for a RAW 9 decode whose memory should go when it is done.
    public func makeLearnedContext() -> CIContext {
        Self.makeContext(device: device, workingColorSpace: learnedWorkingColorSpace)
    }

    private static func makeContext(device: MTLDevice, workingColorSpace: CGColorSpace) -> CIContext {
        CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingColorSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: false,
            .name: "Argent",
        ])
    }

    /// The shader library, compiled from source on first use and shared by every pass.
    public func shaderLibrary() throws -> MTLLibrary {
        if let compiledLibrary { return compiledLibrary }
        // The local base field's functions first, so the Negative LUT's kernels can call them.
        let library = try device.makeLibrary(source: [ShaderSource.toneBase, ShaderSource.lut3D, ShaderSource.printTone].joined(separator: "\n"),
                                             options: nil)
        compiledLibrary = library
        return library
    }

    /// The masked kernels' pipelines, compiled in a library of their own the first time a frame has masks (plan section 4, rule 4), so
    /// `shaderLibrary()`'s source does not change and a frame without masks compiles and binds nothing of them. Lanes may ask at once.
    func localMaskPipelines() throws -> LocalMaskPipelines {
        try localMaskLock.withLock {
            if let localMask { return localMask }
            let made = try LocalMaskPipelines(device: device)
            localMask = made
            return made
        }
    }

    /// Whether a frame with masks has been rendered on this GPU yet.
    var hasLocalMaskPipelines: Bool { localMaskLock.withLock { localMask != nil } }

    /// A 2D `rgba16Float` texture in shared memory (Apple silicon only, so shared is free).
    /// Frame-sized work should come from `texturePool` instead.
    public func makeTexture(width: Int, height: Int,
                            usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) throws -> MTLTexture {
        try Self.makeTexture(device: device, width: width, height: height, usage: usage)
    }

    static func makeTexture(device: MTLDevice, width: Int, height: Int, usage: MTLTextureUsage,
                            pixelFormat: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
        return texture
    }
}

extension MTLComputeCommandEncoder {
    /// Dispatches one thread per pixel of a `width` by `height` image.
    func dispatchPixels(_ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }
}
