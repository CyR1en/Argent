import Foundation
import Metal
import MetalPerformanceShaders

/// Halation: light that crossed the emulsion, reflected from the base and came back as a red
/// and orange glow around the brightest things in the frame (docs/M3-research.md, section 4).
///
/// It is computed once per frame as a global field at low resolution, since a halo reaches
/// across the frame, and added to the light before the Negative LUT, so the film's own response
/// shapes it. The source is each pixel's light after the Rated at gain past a soft knee at
/// +2.5 stops over mid-gray (half a stop wide), area-averaged into the field. The spread is a
/// sum of Gaussians with sigmas from 0.5a to 16a, `a` the stock's radius on a 36 mm film plane,
/// weighted to the halo a 0.10 mm base returns: light reflected at the base's back surface, past
/// the critical angle from 152 micrometres out, through an antihalation undercoat that leaves
/// almost nothing past 400 (`bake/tools/halation_geometry.py`, docs/research/film.md section
/// 4.4). Until 2026-10-07 the weights followed the research's heavy-tailed kernel
/// (1 + r^2/a^2)^-1.5, which put half the halo beyond 300 micrometres and a tenth beyond 1.5 mm;
/// now half lies inside 170 and nine tenths inside 360. Red takes the halo whole, green the
/// stock's share, blue none; the total is the stock's strength times the source's energy.
public final class HalationField {
    /// The field's long side; smaller frames use their own size.
    public static let fieldLongSide = 1024
    public static let thresholdStops: Float = 2.5
    public static let kneeStops: Float = 0.5
    /// Gaussian sigmas as multiples of `a`, and their weights: the geometry's fit at an undercoat
    /// of 0.4 per pass, rounded. The wider four stay at zero, so the field's passes and the mix
    /// keep their shape if a stock ever needs a tail.
    public static let mixture: [(scale: Float, weight: Float)] = [
        (0.5, 0.30), (1, 0.70), (2, 0), (4, 0), (8, 0), (16, 0),
    ]

    struct SourceParams {
        var threshold: Float
        var knee: Float
        var gain: Float
        var storageScale: Float
    }

    private struct MixParams {
        var w0: Float, w1: Float, w2: Float, w3: Float, w4: Float, w5: Float
        var red: Float, green: Float
    }

    private let gpu: GPU
    let source: MTLComputePipelineState
    let mix: MTLComputePipelineState
    private let placeholders: ManualSceneInputs.Placeholders

    public init(gpu: GPU) throws {
        let pipelines = try gpu.filmPipelines()
        self.gpu = gpu
        source = pipelines.halationSource
        mix = pipelines.halationMix
        placeholders = try ManualSceneInputs.Placeholders(gpu: gpu)
    }

    /// The field for `frame` exposed `exposureStops` off box speed, through `halation`, in the
    /// frame's linear light before the rating's gain; its size is the field's. `manual` must not
    /// need tone tables; `FilmRenderer` makes those for a gain-table compiler's tone controls.
    public func field(for frame: LinearFrame, exposureStops: Float, halation: Stock.Halation,
                      manual: ManualRenderSettings = .identity) throws -> PooledTexture {
        try field(for: frame, exposureStops: exposureStops, halation: halation, scene: try ManualSceneInputs(manual))
    }

    func field(for frame: LinearFrame, exposureStops: Float, halation: Stock.Halation,
               scene: ManualSceneInputs) throws -> PooledTexture {
        var refinements = scene.parameters
        let longSide = max(frame.width, frame.height)
        let fieldLong = min(Self.fieldLongSide, longSide)
        let width = max(1, Int((Float(frame.width) * Float(fieldLong) / Float(longSide)).rounded()))
        let height = max(1, Int((Float(frame.height) * Float(fieldLong) / Float(longSide)).rounded()))
        let sourceTexture = try gpu.texturePool.acquire(width: width, height: height)
        let output = try gpu.texturePool.acquire(width: width, height: height)
        var blurred: [PooledTexture] = []
        for _ in Self.mixture { blurred.append(try gpu.texturePool.acquire(width: width, height: height)) }

        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        let gain = exp2(exposureStops)
        let threshold = 0.18 * exp2(Self.thresholdStops)
        let storageScale = exp2(-Self.storageStops(exposureStops: exposureStops, scene: scene))
        var sourceParams = SourceParams(threshold: threshold,
                                        knee: threshold * (exp2(Self.kneeStops / 2) - exp2(-Self.kneeStops / 2)),
                                        gain: gain, storageScale: storageScale)
        guard let sourceEncoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        let source = scene.masks?.pipelines.halationSource ?? self.source
        sourceEncoder.setComputePipelineState(source)
        sourceEncoder.setTexture(frame.texture, index: 0)
        sourceEncoder.setTexture(sourceTexture.texture, index: 1)
        sourceEncoder.setTexture(scene.base ?? placeholders.base, index: 2)
        sourceEncoder.setBytes(&sourceParams, length: MemoryLayout<SourceParams>.stride, index: 0)
        sourceEncoder.setBytes(&refinements, length: MemoryLayout<ManualCurveParameters>.stride, index: 1)
        sourceEncoder.setBuffer(scene.tables ?? placeholders.tables, offset: 0, index: 2)
        scene.masks?.bind(to: sourceEncoder)
        scene.presence.bind(to: sourceEncoder, placeholders: placeholders)
        sourceEncoder.dispatchPixels(source, width: width, height: height)
        sourceEncoder.endEncoding()
        // `a` in field pixels: the stock's radius against the field's pitch on a 36 mm frame.
        let radius = halation.radiusMicrometres / (GrainModel.filmLongEdgeMicrometres / Float(fieldLong))
        for (index, part) in Self.mixture.enumerated() {
            let blur = MPSImageGaussianBlur(device: gpu.device, sigma: radius * part.scale)
            blur.edgeMode = .zero
            blur.encode(commandBuffer: commandBuffer, sourceTexture: sourceTexture.texture,
                        destinationTexture: blurred[index].texture)
        }
        let w = Self.mixture.map { $0.weight * halation.strength / gain / storageScale }
        var mixParams = MixParams(w0: w[0], w1: w[1], w2: w[2], w3: w[3], w4: w[4], w5: w[5], red: 1, green: halation.greenShare)
        guard let mixEncoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        let mix = scene.masks?.pipelines.halationMix ?? self.mix
        mixEncoder.setComputePipelineState(mix)
        for (index, texture) in blurred.enumerated() { mixEncoder.setTexture(texture.texture, index: index) }
        mixEncoder.setTexture(output.texture, index: 6)
        mixEncoder.setBytes(&mixParams, length: MemoryLayout<MixParams>.stride, index: 0)
        mixEncoder.dispatchPixels(mix, width: width, height: height)
        mixEncoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((frame, sourceTexture, blurred)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        return output
    }

    /// The stops the source is stored under. Scene EV can move a finite half-float sample past the source texture's range. Store the
    /// halo source in power-of-two scaled units and undo that scale in the mix. This preserves its energy without extra textures; identity
    /// keeps the old units and rounding. The two logistic region weights sum to less than one; the gain-table compilers' tables carry
    /// their own largest gain, and masks bring a bound of their own, from their sliders, since their law's limits are +32 and +8.
    /// Presence's scene stages add the most they can raise light; without them every storage scale is today's.
    static func storageStops(exposureStops: Float, scene: ManualSceneInputs) -> Float {
        let a = scene.adjustments
        let presence = scene.presence.maximumGainStops
        if let masks = scene.masks {
            return min(ceil(max(0, exposureStops + max(0, a.exposureEV) + masks.maximumExposure + masks.maximumGain + presence)),
                       LocalMaskInputs.storageStopsLimit)
        }
        let sceneStops = scene.parameters.sceneTables != 0 ? scene.maximumGain : max(0, max(a.highlights, a.shadows)) * 0.015
        guard presence > 0 else {
            return scene.parameters.sceneActive == 0 ? 0 : ceil(max(0, exposureStops + max(0, a.exposureEV) + sceneStops))
        }
        let light = scene.parameters.sceneActive == 0 ? 0 : sceneStops
        return ceil(max(0, exposureStops + max(0, a.exposureEV) + light + presence))
    }
}
