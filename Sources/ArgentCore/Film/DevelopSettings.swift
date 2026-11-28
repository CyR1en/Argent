import Foundation

/// The controls a roll carries into the render graph, in the spec's vocabulary.
public struct DevelopSettings: Sendable, Equatable, Hashable {
    /// The film speed the roll is rated at. `nil` means the stock's box speed.
    public var ratedAt: Float?
    /// Print exposure per channel in stops, as (red, green, blue). Positive adds that
    /// channel to the print, so +1 red is a stop more red.
    public var labBalance: SIMD3<Float>
    /// Overall print exposure in stops. Positive lightens the print. Auto development
    /// decides this per frame in M3; until then it is a manual control.
    public var printExposure: Float
    /// Grain, as a multiple of the stock's own (`GrainModel.amount` calibrates it): 1 is
    /// Natural, 0 is Off.
    public var grain: Float
    /// Which grain the frame gets; the same seed gives the same grain.
    public var grainSeed: UInt32
    /// The stock's halation; off where the stock has none, and where a render leaves it out on
    /// purpose.
    public var halation: Bool
    /// Halation, as a multiple of the stock's own strength: 1 is the stock's, 0 none, 2 twice as
    /// much. The Halation control's value over 100; read only while `halation` is on.
    public var halationAmount: Float
    /// Capture sharpening (`CaptureSharpening`); it is part of every render in the app, not a
    /// control, and off only where a render leaves it out on purpose.
    public var sharpen: Bool
    /// Scene/print refinements around a frame's fixed automatic reference. Identity takes
    /// the original render path, including the original grain and halation behavior.
    public var manual: ManualRenderSettings
    /// Auto's local burn and dodge in print exposure. Identity takes the original render path.
    public var tone: PrintTone
    public var monochromeFilter: MonochromeFilter
    public var paperGrade: PaperGrade

    public init(ratedAt: Float? = nil, labBalance: SIMD3<Float> = .zero, printExposure: Float = 0,
                grain: Float = 0, grainSeed: UInt32 = 0, halation: Bool = false, halationAmount: Float = 1,
                sharpen: Bool = false, manual: ManualRenderSettings = .identity, tone: PrintTone = .identity,
                monochromeFilter: MonochromeFilter = .none, paperGrade: PaperGrade = .normal) {
        self.halation = halation
        self.halationAmount = halationAmount
        self.sharpen = sharpen
        self.ratedAt = ratedAt
        self.labBalance = labBalance
        self.printExposure = printExposure
        self.grain = grain
        self.grainSeed = grainSeed
        self.manual = manual
        self.tone = tone
        self.monochromeFilter = monochromeFilter
        self.paperGrade = paperGrade
    }

    public var lens: LensSettings { manual.adjustments.lens }

    /// Stops of extra exposure the negative receives. Rated at 200 on a 400 stock is one
    /// stop over, because the photographer metered as if the film were slower.
    public func exposureStops(boxSpeed: Float) -> Float {
        guard let ratedAt, ratedAt > 0, boxSpeed > 0 else { return 0 }
        return log2(boxSpeed / ratedAt)
    }

    /// The shift added to the Print LUT's input, in its normalized dye units.
    ///
    /// A stop of print exposure is log10(2) of log paper exposure. The Print LUT's input is
    /// the amount of each negative dye divided by the stock's density range, and one unit of
    /// dye moves the paper layer behind it by `exposurePerUnit` in log10 exposure (the bake
    /// measures this at the daylight-reference mid-gray and writes it to the manifest). So
    /// offset_c = stops_c * log10(2) / (exposurePerUnit_c * densityRange). A lighter print
    /// means less light through the negative, which is more dye.
    public func printOffset(densityRange: Float, exposurePerUnit: SIMD3<Float>) -> SIMD3<Float> {
        (SIMD3<Float>(repeating: printExposure) + labBalance) * Float(log10(2.0))
            / (exposurePerUnit * densityRange)
    }

    /// One paper stop in the Print LUT's normalized dye units, per channel.
    public static func printUnits(densityRange: Float, exposurePerUnit: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(repeating: Float(log10(2.0))) / (exposurePerUnit * densityRange)
    }
}
