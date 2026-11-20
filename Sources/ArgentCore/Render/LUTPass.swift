import Metal

/// One Metal compute pass: log-encode, then tetrahedral 3D LUT lookup.
///
/// The render graph runs this as the Negative LUT pass, with `exposureStops` carrying
/// Rated at. The M0 spike runs it alone with a display LUT.
public final class LUTPass {
    private let gpu: GPU
    private let pipeline: MTLComputePipelineState
    /// The same with a halation field added to the light first.
    private let halationPipeline: MTLComputePipelineState
    /// The same two writing each pixel's local base to the output's alpha, for the tone step (`PrintTone`).
    private let tonedPipeline: MTLComputePipelineState
    private let tonedHalationPipeline: MTLComputePipelineState
    /// Bound for the scene mapping's base field and tables when it reads neither.
    private let placeholders: ManualSceneInputs.Placeholders

    public init(gpu: GPU) throws {
        let library = try gpu.shaderLibrary()
        guard let function = library.makeFunction(name: "apply_lut3d") else {
            throw GPUError.shaderFunctionMissing("apply_lut3d")
        }
        guard let withHalation = library.makeFunction(name: "apply_lut3d_halation") else {
            throw GPUError.shaderFunctionMissing("apply_lut3d_halation")
        }
        self.pipeline = try gpu.device.makeComputePipelineState(function: function)
        self.halationPipeline = try gpu.device.makeComputePipelineState(function: withHalation)
        guard let toned = library.makeFunction(name: "apply_lut3d_toned"),
              let tonedWithHalation = library.makeFunction(name: "apply_lut3d_halation_toned") else {
            throw GPUError.shaderFunctionMissing("apply_lut3d_toned")
        }
        self.tonedPipeline = try gpu.device.makeComputePipelineState(function: toned)
        self.tonedHalationPipeline = try gpu.device.makeComputePipelineState(function: tonedWithHalation)
        self.gpu = gpu
        placeholders = try ManualSceneInputs.Placeholders(gpu: gpu)
    }

    /// `halation`, when given, is a low-resolution field of light added to every pixel before
    /// the encoding, sampled bilinearly. `manual` must not need tone tables; `FilmRenderer` makes
    /// those for a gain-table compiler's tone controls.
    public func encode(input: MTLTexture, output: MTLTexture, lut: MTLTexture, params: LUTParams,
                       halation: MTLTexture? = nil, manual: ManualRenderSettings = .identity,
                       into commandBuffer: MTLCommandBuffer) throws {
        try encode(input: input, output: output, lut: lut, params: params, halation: halation,
                   scene: try ManualSceneInputs(manual), into: commandBuffer)
    }

    func encode(input: MTLTexture, output: MTLTexture, lut: MTLTexture, params: LUTParams,
                halation: MTLTexture? = nil, scene: ManualSceneInputs, toneTable: [SIMD4<Float>]? = nil,
                into commandBuffer: MTLCommandBuffer) throws {
        var refinements = scene.parameters
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        let pipeline = scene.masks?.pipelines.negative(halation: halation != nil, toned: toneTable != nil)
            ?? (toneTable == nil ? (halation == nil ? self.pipeline : halationPipeline)
                : (halation == nil ? tonedPipeline : tonedHalationPipeline))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(lut, index: 2)
        if let halation { encoder.setTexture(halation, index: 3) }
        encoder.setTexture(scene.base ?? placeholders.base, index: halation == nil ? 3 : 4)
        var p = params
        encoder.setBytes(&p, length: MemoryLayout<LUTParams>.stride, index: 0)
        encoder.setBytes(&refinements, length: MemoryLayout<ManualCurveParameters>.stride, index: 1)
        encoder.setBuffer(scene.tables ?? placeholders.tables, offset: 0, index: 2)
        scene.masks?.bind(to: encoder)
        scene.presence.bind(to: encoder, placeholders: placeholders)
        if let toneTable {
            toneTable.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
            var info = PrintToneTableInfo()
            encoder.setBytes(&info, length: MemoryLayout<PrintToneTableInfo>.stride, index: 4)
        }
        encoder.dispatchPixels(pipeline, width: input.width, height: input.height)
        encoder.endEncoding()
    }

    /// Runs the pass synchronously. Returns the output texture and the GPU time in seconds.
    public func run(input: MTLTexture, lut: MTLTexture, params: LUTParams,
                    manual: ManualRenderSettings = .identity) throws -> (output: PooledTexture, gpuSeconds: Double) {
        let output = try gpu.texturePool.acquire(width: input.width, height: input.height)
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        try encode(input: input, output: output.texture, lut: lut, params: params, manual: manual, into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return (output, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
    }
}
