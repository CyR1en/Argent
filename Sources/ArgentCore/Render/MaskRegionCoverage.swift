import Metal

/// A part of a decode to read a mask's coverage over, in the decode's texels from its top left: which texels, and how many pixels they make.
/// Whole texels, so at a step of 1 a pixel of the result is one of the print's. A larger region is thinned to `MaskRegion.maximumLongSide`,
/// which bounds what one result holds in memory (`GPU.regionCoverage`).
public struct MaskRegion: Sendable, Equatable, Hashable {
    /// The most pixels a result has on its longer side, and so 7.1 MB at 3264 × 2176 (provenance section 17).
    public static let maximumLongSide = 3264

    public let x: Int
    public let y: Int
    /// The texels across and down it covers.
    public let texelWidth: Int
    public let texelHeight: Int
    /// The result's pixels.
    public let width: Int
    public let height: Int

    /// The whole texels of a decode `frameWidth` by `frameHeight` that cover `left...right` and `top...bottom` as fractions of it, kept
    /// inside it; `nil` for a region that covers nothing.
    public init?(frameWidth: Int, frameHeight: Int, left: Double, top: Double, right: Double, bottom: Double) {
        func low(_ v: Double, _ side: Int) -> Int { min(max(Int((v * Double(side)).rounded(.down)), 0), side) }
        func high(_ v: Double, _ side: Int) -> Int { min(max(Int((v * Double(side)).rounded(.up)), 0), side) }
        let x0 = low(left, frameWidth), x1 = high(right, frameWidth), y0 = low(top, frameHeight), y1 = high(bottom, frameHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        x = x0
        y = y0
        texelWidth = x1 - x0
        texelHeight = y1 - y0
        let long = max(texelWidth, texelHeight)
        let shrink = long > Self.maximumLongSide ? Double(Self.maximumLongSide) / Double(long) : 1
        width = max(1, Int((Double(texelWidth) * shrink).rounded()))
        height = max(1, Int((Double(texelHeight) * shrink).rounded()))
    }

    /// The fractions of the decode this region covers, as the texels make them.
    public func fractions(frameWidth: Int, frameHeight: Int) -> (left: Double, top: Double, width: Double, height: Double) {
        (Double(x) / Double(frameWidth), Double(y) / Double(frameHeight),
         Double(texelWidth) / Double(frameWidth), Double(texelHeight) / Double(frameHeight))
    }
}

/// Mirrors `LocalMaskCoverageRegion`.
private struct CoverageRegion {
    var origin: SIMD2<UInt32>
    var step: SIMD2<Float>
}

extension GPU {
    /// `mask`'s coverage on `frame` over `region`, 0 to 255, top row first, as the masked kernels read it (`local_coverage_at`): its slice
    /// where it takes tier 1 and its refined value per pixel where it takes tier 2, so the overlay can never disagree with the print about
    /// what is selected. For the overlay's sharp raster (`MaskOverlaySharp`): one mask's slot on its own set, baked once like any field and
    /// kept by the field cache; a slider changes nothing here, and a gesture never asks. Any thread.
    public func regionCoverage(of mask: Mask, version: String = MaskSet.currentVersion, on frame: LinearFrame, region: MaskRegion,
                               seeds: (any MaskSeedProvider)? = nil) throws -> [UInt8] {
        let masks = try MaskSet(masks: [mask], version: version), picture = try frame.maskPicture
        let refinement = mask.readsSmartSelection || mask.readsMeasuredStroke ? maskRefiner.session(for: frame, picture: picture, seeds: seeds) : nil
        guard let coverage = try maskFields.coverage(for: masks, picture: picture, lens: frame.maskLens, refinement: refinement) else {
            return [UInt8](repeating: 0, count: region.width * region.height)
        }
        let pipelines = try localMaskPipelines()
        guard let tables = device.makeBuffer(length: 4, options: .storageModeShared) else { throw GPUError.textureAllocation }
        var inputs = LocalMaskInputs(pipelines: pipelines, coverage: coverage, tables: tables,
                                     parameters: LocalMaskParameters(coverageOnly: coverage.sliceCount), maximumExposure: 0, maximumGain: 0)
        if let refinement { try inputs.refinePerPixel(masks, session: refinement) }

        let output = try GPU.makeTexture(device: device, width: region.width, height: region.height, usage: [.shaderWrite],
                                         pixelFormat: .r8Unorm)
        output.label = "Mask overlay region"
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(pipelines.coverageRegion)
        inputs.bind(to: encoder)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setTexture(output, index: 1)
        var bound = CoverageRegion(origin: SIMD2(UInt32(region.x), UInt32(region.y)),
                                   step: SIMD2(Float(region.texelWidth) / Float(region.width), Float(region.texelHeight) / Float(region.height)))
        encoder.setBytes(&bound, length: MemoryLayout<CoverageRegion>.stride, index: 0)
        encoder.dispatchPixels(pipelines.coverageRegion, width: region.width, height: region.height)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((frame, inputs, refinement)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }

        var values = [UInt8](repeating: 0, count: region.width * region.height)
        values.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: region.width, from: MTLRegionMake2D(0, 0, region.width, region.height), mipmapLevel: 0)
        }
        return values
    }
}
