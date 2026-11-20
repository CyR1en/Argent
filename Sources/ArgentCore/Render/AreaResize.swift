import Metal

/// Resizes a picture down by area: the source mapped exactly onto the output, each output
/// pixel the mean of the source area it covers, with the pixels its edges cut through
/// weighted by the share of them inside. In linear light that is what a smaller sensor would
/// have collected, so it never rings beside an edge, keeps a flat field and the picture's mean,
/// and keeps grain's statistics: a long-edge develop and a full-size one match at the same
/// print size (docs/SPEC.md). Core Image's Lanczos, which it replaces, dipped the chart's dark
/// frame from L* 20 to 1 beside a white patch at 2048 pixels (docs/M3-auto.md, section 9).
public final class AreaResize {
    private let gpu: GPU
    private let pipeline: MTLComputePipelineState
    private let addPipeline: MTLComputePipelineState
    private let finishPipeline: MTLComputePipelineState

    /// Builds the pipelines; call it on one thread, as the shader library is not thread-safe.
    public init(gpu: GPU) throws {
        self.gpu = gpu
        let library = try gpu.shaderLibrary()
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
            return try gpu.device.makeComputePipelineState(function: function)
        }
        self.pipeline = try pipeline("area_resize")
        addPipeline = try pipeline("area_resize_add")
        finishPipeline = try pipeline("area_resize_finish")
    }

    /// The size a `width` by `height` picture comes to at `scale`: each side rounded, at least
    /// a pixel, so a long edge scaled to `n` pixels is exactly `n`.
    public static func size(width: Int, height: Int, scale: Double) -> (width: Int, height: Int) {
        (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Resizes `input` onto all of `output`, which should be no larger on either side.
    public func encode(_ input: MTLTexture, to output: MTLTexture, into commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.dispatchPixels(pipeline, width: output.width, height: output.height)
        encoder.endEncoding()
    }

    /// `texture` resized by `scale` (below 1) into a texture from the pool, `size(...)` pixels,
    /// run now. Keep `texture` alive until this returns.
    public func resized(_ texture: MTLTexture, scale: Double) throws -> PooledTexture {
        let size = Self.size(width: texture.width, height: texture.height, scale: scale)
        let output = try gpu.texturePool.acquire(width: size.width, height: size.height)
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        try encode(texture, to: output.texture, into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return output
    }

    /// A resize of a `sourceWidth` by `sourceHeight` source onto all of `output`, which should be
    /// no larger on either side, fed a piece of the source at a time (`Pieces`).
    public func pieces(sourceWidth: Int, sourceHeight: Int, onto output: MTLTexture) throws -> Pieces {
        try Pieces(gpu: gpu, add: addPipeline, finish: finishPipeline,
                   source: SIMD2(UInt32(sourceWidth), UInt32(sourceHeight)), output: output)
    }

    /// An area resize of a source that is never held whole: `add` each piece of it once, where it
    /// sits in the source, then `finish` writes the output. It holds 16 bytes an output pixel, where
    /// the source would take 8 bytes a source pixel. An output pixel inside one piece comes out as
    /// `encode` makes it; one that pieces share is summed in parts, so it can differ by a step of a
    /// half float (tested). Each call runs now; use it from one thread.
    public final class Pieces {
        private let gpu: GPU
        private let addPipeline: MTLComputePipelineState
        private let finishPipeline: MTLComputePipelineState
        private let source: SIMD2<UInt32>
        private let output: MTLTexture
        /// A float4 an output pixel, in rows.
        private let sums: MTLBuffer

        private struct Piece {
            var origin: SIMD2<UInt32>
            var source: SIMD2<UInt32>
            var output: SIMD2<UInt32>
            var first: SIMD2<UInt32>
        }

        fileprivate init(gpu: GPU, add: MTLComputePipelineState, finish: MTLComputePipelineState,
                         source: SIMD2<UInt32>, output: MTLTexture) throws {
            self.gpu = gpu
            addPipeline = add
            finishPipeline = finish
            self.source = source
            self.output = output
            guard let sums = gpu.device.makeBuffer(length: output.width * output.height * 16, options: .storageModePrivate) else {
                throw GPUError.textureAllocation
            }
            self.sums = sums
            guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw GPUError.noEncoder }
            blit.fill(buffer: sums, range: 0..<sums.length, value: 0)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw error }
        }

        /// Adds `piece`, whose first pixel is the source's (`x`, `y`).
        public func add(_ piece: MTLTexture, x: Int, y: Int) throws {
            let (sw, sh, ow, oh) = (Int(source.x), Int(source.y), output.width, output.height)
            // The output pixels whose footprints the piece reaches, first to last.
            let first = (x: x * ow / sw, y: y * oh / sh)
            let end = (x: min(ow, ((x + piece.width) * ow + sw - 1) / sw), y: min(oh, ((y + piece.height) * oh + sh - 1) / sh))
            guard end.x > first.x, end.y > first.y else { return }
            var parameters = Piece(origin: SIMD2(UInt32(x), UInt32(y)), source: source, output: SIMD2(UInt32(ow), UInt32(oh)),
                                   first: SIMD2(UInt32(first.x), UInt32(first.y)))
            try run { encoder in
                encoder.setComputePipelineState(addPipeline)
                encoder.setTexture(piece, index: 0)
                encoder.setBuffer(sums, offset: 0, index: 0)
                encoder.setBytes(&parameters, length: MemoryLayout<Piece>.stride, index: 1)
                encoder.dispatchPixels(addPipeline, width: end.x - first.x, height: end.y - first.y)
            }
        }

        /// Writes the output from the pieces added.
        public func finish() throws {
            var source = source
            try run { encoder in
                encoder.setComputePipelineState(finishPipeline)
                encoder.setBuffer(sums, offset: 0, index: 0)
                encoder.setBytes(&source, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                encoder.setTexture(output, index: 0)
                encoder.dispatchPixels(finishPipeline, width: output.width, height: output.height)
            }
        }

        private func run(_ encode: (MTLComputeCommandEncoder) -> Void) throws {
            guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
            encode(encoder)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw error }
        }
    }
}
