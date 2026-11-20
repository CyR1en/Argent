import CoreGraphics
import Foundation
import Metal

/// Wall-clock and GPU timings for one developed frame, in seconds, with what the decoder
/// reported about the frame.
///
/// `lut` and `lutGPU` cover every LUT pass: one in the M0 single-LUT path, two (Negative
/// and Print) with a stock.
public struct StageTimings: Sendable {
    public var decode: Double
    public var lut: Double
    public var lutGPU: Double
    public var encode: Double
    public var total: Double
    public var width: Int
    public var height: Int
    public var decoderVersion: String
    /// The decoder settings the frame was made with, when the decoder records them.
    public var pins: DecodePins?
    public var readback: DecodeReadback?
    public var lens: ResolvedLensCorrection?
}

/// Decode, the film model, encode.
///
/// With a `Stock` the film model is `FilmRenderer`'s render graph: the Negative LUT, lab
/// balance, the Print LUT, and halation, grain and sharpening as the settings ask. The M0
/// spike's single display LUT stays available for timing comparisons and for placing the
/// pipeline before any stock exists. The spike (`argent-spike`) uses this; the app develops
/// through ArgentRoll's `RollDeveloper`.
public final class DevelopPipeline {
    public let gpu: GPU
    public let decoder: RawDecoder
    public let encoder: ImageEncoder
    private let lensStage: LensStage
    private let look: Look

    private enum Look {
        /// One LUT from log-encoded scene-linear light straight to sRGB-encoded display RGB.
        case singleLUT(LUTPass, lut: MTLTexture, params: LUTParams)
        /// A baked stock, ending in display-linear light.
        case stock(FilmRenderer, DevelopSettings)
    }

    public init(gpu: GPU, decoder: RawDecoder, lut: LUT3D) throws {
        self.gpu = gpu
        self.decoder = decoder
        self.encoder = try ImageEncoder(gpu: gpu)
        self.lensStage = try LensStage(gpu: gpu)
        self.look = .singleLUT(try LUTPass(gpu: gpu), lut: try lut.makeTexture(device: gpu.device), params: lut.params)
    }

    public init(gpu: GPU, decoder: RawDecoder, stock: Stock, settings: DevelopSettings = DevelopSettings()) throws {
        self.gpu = gpu
        self.decoder = decoder
        self.encoder = try ImageEncoder(gpu: gpu)
        self.lensStage = try LensStage(gpu: gpu)
        self.look = .stock(try FilmRenderer(gpu: gpu, stock: stock), settings)
    }

    /// Develops `url` to `output`. With a stock, `settings` replaces the pipeline's own for this
    /// frame, as the spike's `--auto` and Light flags need per frame; the single-LUT look ignores it.
    /// `beforeRender` gets the decoded frame's texture and may write over it, and the render reads
    /// what it leaves; `afterRender` gets the render's result before the encode. The spike's array
    /// flags use them, and their time is left out of the timings.
    @discardableResult
    public func develop(_ url: URL, to output: URL, options: DecodeOptions = DecodeOptions(),
                        format: OutputFormat = .jpeg(quality: 0.92), longEdge: Int? = nil,
                        settings: DevelopSettings? = nil, beforeRender: ((MTLTexture) throws -> Void)? = nil,
                        afterRender: ((MTLTexture) throws -> Void)? = nil) throws -> StageTimings {
        let clock = ContinuousClock()
        let start = clock.now

        // The linear frame goes back to the pool as soon as the LUT passes are done with
        // it, not after the encode.
        let afterDecode: ContinuousClock.Instant, beforeLUT: ContinuousClock.Instant
        let rendered: PooledTexture
        let gpuSeconds: Double
        let encodedSpace: CGColorSpace
        let width: Int, height: Int, decoderVersion: String
        let pins: DecodePins?, readback: DecodeReadback?
        let lens: ResolvedLensCorrection?
        do {
            let lensSettings: LensSettings
            switch look {
            case .stock(_, let stored): lensSettings = (settings ?? stored).lens
            case .singleLUT: lensSettings = .default
            }
            let correction = options.lensCorrection ? LensResolver.correction(for: url, settings: lensSettings) : .identity
            var decodeOptions = options
            decodeOptions.lensCorrection = false
            let decoded = try decoder.decode(url, options: decodeOptions)
            let (frame, spare) = try lensStage.correct(decoded, with: correction, reusingDecode: true)
            afterDecode = clock.now
            width = frame.width
            height = frame.height
            decoderVersion = frame.decoderVersion
            pins = frame.pins
            readback = frame.readback
            lens = frame.lens
            try beforeRender?(frame.texture)
            beforeLUT = clock.now

            switch look {
            case .singleLUT(let pass, let lut, let params):
                (rendered, gpuSeconds) = try pass.run(input: frame.texture, lut: lut, params: params)
                encodedSpace = gpu.outputColorSpace
            case .stock(let renderer, let stored):
                let result = try renderer.render(frame, settings: settings ?? stored, densities: spare)
                rendered = result.image
                gpuSeconds = result.gpuSeconds
                encodedSpace = gpu.workingColorSpace
            }
        }
        let afterLUT = clock.now
        try afterRender?(rendered.texture)
        let beforeEncode = clock.now

        try encoder.write(rendered.texture, to: output, format: format, metadataFrom: url, colorSpace: encodedSpace,
                          longEdge: longEdge)
        let end = clock.now

        return StageTimings(
            decode: (afterDecode - start).seconds,
            lut: (afterLUT - beforeLUT).seconds,
            lutGPU: gpuSeconds,
            encode: (end - beforeEncode).seconds,
            total: (end - start - (beforeLUT - afterDecode) - (beforeEncode - afterLUT)).seconds,
            width: width,
            height: height,
            decoderVersion: decoderVersion,
            pins: pins,
            readback: readback,
            lens: lens)
    }
}
