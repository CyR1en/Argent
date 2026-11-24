import ArgentCore
import Foundation

/// A roll's two controls besides the stock, in the spec's positions, and what they mean to the
/// render graph for a given stock.
public struct RollControls: Sendable, Equatable, Hashable, Codable {
    /// Stops of exposure the negative gets relative to box speed. Rated at half the box speed
    /// is one stop over: the photographer metered as if the film were slower.
    public enum RatedAt: Int, Sendable, CaseIterable, Codable {
        case boxSpeed = 0
        case oneStopOver = 1
        case oneStopUnder = -1
        case twoStopsUnder = -2

        public var stops: Int { rawValue }

        /// The speed this position rates a stock of `boxSpeed` at.
        public func iso(boxSpeed: Float) -> Int { Int((boxSpeed * exp2(-Float(rawValue))).rounded()) }

        public var title: String {
            switch self {
            case .boxSpeed: return "Box speed"
            case .oneStopOver: return "One stop over"
            case .oneStopUnder: return "One stop under"
            case .twoStopsUnder: return "Two stops under"
            }
        }
    }

    public enum LabBalance: String, Sendable, CaseIterable, Codable {
        /// Auto lab balance: each cluster of the roll is filtered to take out a share of its
        /// cast (`AutoBalance`).
        case auto
        /// The daylight reference: a daylight gray prints gray, and other light keeps its cast.
        case neutral
        case warm
        case cool

        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        /// Print exposure per channel in stops of paper exposure, red, green, blue.
        ///
        /// Warm and Cool move the print as a light 20 mired warmer or cooler would, one Wratten
        /// 81A or 82A (spec): the M1 white-balance spike measured 1.24 stops of red against blue
        /// for 130 mired through the D55 pin, and a negative's gamma of about 0.65 carries a scene
        /// stop into 0.65 of a paper stop, so 20 mired is about 0.124 paper stops of red against
        /// blue, split evenly (inference), to be judged on real rolls.
        public static let stepPaperStops: Float = 0.062

        public var printBalance: SIMD3<Float> {
            let step = Self.stepPaperStops
            switch self {
            case .auto, .neutral: return .zero
            case .warm: return SIMD3(step, 0, -step)
            case .cool: return SIMD3(-step, 0, step)
            }
        }
    }

    public var ratedAt: RatedAt
    public var labBalance: LabBalance

    public init(ratedAt: RatedAt = .boxSpeed, labBalance: LabBalance = .auto) {
        self.ratedAt = ratedAt
        self.labBalance = labBalance
    }

    /// The render settings for `stock`, for a frame whose light auto development measured as
    /// `analysis` (`nil` before it is measured).
    ///
    /// Rated at moves the exposure the negative gets. A lab printing a roll rated off box
    /// speed prints it back to a normal density, so the print exposure is set per channel to
    /// put a metered mid-gray where it lands at box speed: the frame keeps its brightness and
    /// colour, and what changes is the film's response around it, highlights compressing on
    /// the shoulder when over and, when under, shadows flattening in the toe on a floor the print
    /// lifts with them: L* 14 or so at two under against 5 at box speed
    /// (docs/research/auto/balance-research.md, section 4). Auto print exposure
    /// does the same for the frame's own level: the level it measured is printed as a metered
    /// gray would be, within `AutoPrint`'s bounds, on top of the rating.
    public func settings(for stock: Stock, analysis: ExposureAnalysis?) -> DevelopSettings {
        settings(for: stock, aim: AutoPrint.aim(analysis))
    }

    /// The render settings for `stock` with the print following `aim`: a frame's bounded
    /// level and its cast, or both after roll smoothing.
    ///
    /// With Lab balance on Auto the print brings a gray carrying a corrected share of the
    /// frame's cast (`AutoBalance.correction`) back to neutral density, as a lab's filtration
    /// does; Neutral prints the daylight reference, and Warm and Cool are a fixed step from it.
    public func settings(for stock: Stock, aim: PrintAim = PrintAim()) -> DevelopSettings {
        let ratedISO = stock.boxSpeed * exp2(-Float(ratedAt.stops))
        let filtration = labBalance == .auto ? AutoBalance.correction(for: aim.cast) : .zero
        let exposure = SIMD3<Float>(repeating: Float(ratedAt.stops) + aim.level) + filtration
        return DevelopSettings(ratedAt: ratedAt == .boxSpeed ? nil : ratedISO,
                               labBalance: labBalance.printBalance + Self.grayCompensation(stock, exposureStops: exposure),
                               tone: aim.tone)
    }

    /// The render settings for `stock` with the print following `level` alone.
    public func settings(for stock: Stock, level: Float) -> DevelopSettings {
        settings(for: stock, aim: PrintAim(level: level))
    }

    /// Print exposure per channel, in paper stops, that brings a gray whose red, green and blue
    /// were each exposed `exposureStops` off a metered mid-gray back to a neutral mid-gray's dye
    /// amounts at box speed.
    public static func grayCompensation(_ stock: Stock, exposureStops: SIMD3<Float>) -> SIMD3<Float> {
        guard exposureStops != .zero else { return .zero }
        let encoding = stock.negative.encoding
        let atBox = stock.negative.sample(encoded: SIMD3(repeating: encoding.encode(encoding.midGray)))
        let channels = GamutCompression.compress(encoding.midGray * SIMD3(exp2(exposureStops.x), exp2(exposureStops.y), exp2(exposureStops.z)))
        let shifted = stock.negative.sample(encoded: SIMD3(encoding.encode(channels.x), encoding.encode(channels.y),
                                                           encoding.encode(channels.z)))
        // The Print LUT reads dye amounts plus an offset of stops * log10(2) / (perUnit * range)
        // (DevelopSettings.printOffset); more dye means a lighter print, so cancelling the extra
        // dye takes the negative of it in those units.
        return -(shifted - atBox) * stock.exposurePerUnit * stock.densityRange / Float(log10(2.0))
    }
}

/// Auto print exposure: where the print aims a frame, in scene stops against mid-gray.
///
/// Since analysis `2026-10-18-1` the aim is `FittedPlacement`'s, fitted on FiveK's five experts
/// (docs/M3-auto.md sections 42 and 43), within `bound` either way: the research's bound of one and
/// a half scene stops at the Negative LUT's input, past which the negative is the problem and the
/// look should show it. The metered rule it replaced (docs/M3-auto.md, "Exposure placement") is
/// removed from the tree; the code is in `2a6e696`.
public enum AutoPrint {
    /// The fitted aim's bound either way, the spec's one and a half scene stops, for every frame.
    public static let bound: Float = 1.5
    /// A bright frame is printed down by at most this many scene stops.
    public static let darkenLimit: Float = 1.5
    /// The faces' skin share of the frame below which `SkinBalance` ignores it: the research's 1 to
    /// 1.7 percent of skin.
    public static let minimumFaceArea: Float = 0.015

    /// The level, in scene stops against mid-gray, that the print treats as the frame's
    /// metered gray: `FittedPlacement`'s aim within `bound`; 0 before the frame is measured.
    public static func levelStops(_ analysis: ExposureAnalysis?) -> Float {
        guard let analysis else { return 0 }
        return FittedPlacement.aim(analysis)
    }

    /// A frame's whole print aim, from its measurement alone: its level, its cast and its tone step;
    /// the neutral aim before the frame is measured.
    public static func aim(_ analysis: ExposureAnalysis?) -> PrintAim {
        guard let analysis else { return PrintAim() }
        let tone = FittedTone.strengths(analysis)
        return PrintAim(level: FittedPlacement.aim(analysis), cast: AutoBalance.cast(analysis), burn: tone.burn, dodge: tone.dodge)
    }
}

/// Auto's aim since analysis `2026-11-05-1`: a linear function of what the analysis already
/// measures, fitted with `FittedTone` to Lightroom's Auto on 154 a7 IV frames and 200 FiveK photos, with
/// FiveK's own intercept, so its cameras stop setting the a7 IV's level (docs/research/auto/balance-research.md,
/// section 7d). It reads the frame's level and how far its light reaches: Lightroom prints a frame with a very bright
/// top a little down, and the burn holds the rest of the range. The face terms stay those fitted on FiveK's experts in
/// `2026-10-19-1` (docs/research/auto/fivek-face-fit.md, candidate C). It has no branch, threshold or
/// fallback, so the aim moves continuously with every input; only `AutoPrint.bound` clamps it.
public enum FittedPlacement {
    /// The faces' share of the frame at which their weight is full: 0.25 %.
    public static let fullFaceArea: Float = 0.0025
    /// The reach of a measurement with no histogram: about the middle of the fit's frames.
    public static let noReach: Float = 2.75

    /// What the aim reads of a frame's measurement.
    public struct Features: Sendable, Equatable {
        /// `meanStops`.
        public var level: Float
        /// How far the frame's light reaches: the histogram's 99th percentile, `noReach` without a histogram.
        public var reach: Float
        /// The histogram's median less its 10th percentile, and its 90th percentile less its median.
        public var shadowSpread: Float
        public var highlightSpread: Float
        /// The histogram's share at or above +2.5 stops, and at or below -3.
        public var bright: Float
        public var dark: Float
        /// min(1, sqrt(face area / `fullFaceArea`)), 0 without faces; that weight times the faces'
        /// area-weighted level less the frame's; and that weight times the frame's level, so a frame
        /// with faces follows its own level by its own slope.
        public var faceWeight: Float
        public var faceOffset: Float
        public var faceFrameLevel: Float

        public init(_ analysis: ExposureAnalysis) {
            level = analysis.meanStops
            let histogram = analysis.histogram.count == ExposureAnalysis.histogramBins ? analysis.histogram : []
            let total = histogram.reduce(0, +)
            // Linear within the half-stop bins of the cumulative share.
            func quantile(_ p: Float) -> Float {
                var below: Float = 0
                for (index, share) in histogram.enumerated() where share > 0 {
                    if below + share >= p * total {
                        return ExposureAnalysis.histogramLowStops
                            + ExposureAnalysis.histogramBinStops * (Float(index) + (p * total - below) / share)
                    }
                    below += share
                }
                return -ExposureAnalysis.histogramLowStops
            }
            let q10 = quantile(0.1), q50 = quantile(0.5), q90 = quantile(0.9)
            shadowSpread = q50 - q10
            highlightSpread = q90 - q50
            reach = histogram.isEmpty ? FittedPlacement.noReach : quantile(0.99)
            let share = total > 0 ? total : 1
            bright = histogram.isEmpty ? 0 : histogram[15...].reduce(0, +) / share
            dark = histogram.isEmpty ? 0 : histogram[..<4].reduce(0, +) / share
            let area = analysis.faceArea
            faceWeight = area > 0 ? min(1, (area / FittedPlacement.fullFaceArea).squareRoot()) : 0
            faceOffset = faceWeight * ((analysis.faceLevelStops ?? analysis.meanStops) - analysis.meanStops)
            faceFrameLevel = faceWeight * analysis.meanStops
        }

        var vector: [Float] {
            [1, level, reach, faceWeight, faceOffset, faceFrameLevel]
        }
    }

    /// The frozen coefficients, in `Features.vector`'s order (docs/research/auto/balance-research.md,
    /// section 7d; the last three from docs/research/auto/fivek-face-fit.md, candidate C).
    public static let coefficients: [Float] = [-0.398, 0.356, 0.181, -0.089, 0.362, 0.148]

    /// The frame's print aim in scene stops against mid-gray, within `AutoPrint.bound`.
    public static func aim(_ analysis: ExposureAnalysis) -> Float {
        let raw = zip(coefficients, Features(analysis).vector).reduce(0) { $0 + $1.0 * $1.1 }
        guard raw.isFinite else { return 0 }
        return min(max(raw, -AutoPrint.bound), AutoPrint.bound)
    }
}

/// Auto's tone step for a frame (`PrintTone`): how much its print's highlights are burned and its
/// shadows dodged, in paper stops, as linear functions of what the analysis already measures, fitted with
/// `FittedPlacement` to Lightroom's Auto (docs/research/auto/balance-research.md, section 7d). Like the
/// aim they have no branch, and a frame whose light reaches further gets more burn. Lightroom's Highlights and Shadows act on
/// every one of the frames it was run on, so every frame gets a little.
public enum FittedTone {
    /// The most a frame's burn or dodge can be, where the fit's frames stop reaching. At the burn's limit, the curve's
    /// steepest point keeps a fifth of the print's own contrast: it falls 0.4 paper stop for each scene stop, and a paper stop is two.
    public static let burnLimit: Float = 1.25
    public static let dodgeLimit: Float = 0.5
    /// Constant, reach, bright share, level.
    public static let burnCoefficients: [Float] = [-0.080, 0.176, 0.787, -0.212]
    /// Constant, highlight spread, level, shadow spread, dark share.
    public static let dodgeCoefficients: [Float] = [-0.046, 0.043, -0.023, 0.043, -0.115]

    public static func strengths(_ analysis: ExposureAnalysis) -> (burn: Float, dodge: Float) {
        let f = FittedPlacement.Features(analysis)
        let burn = zip(burnCoefficients, [1, f.reach, f.bright, f.level]).reduce(0) { $0 + $1.0 * $1.1 }
        let dodge = zip(dodgeCoefficients, [1, f.highlightSpread, f.level, f.shadowSpread, f.dark]).reduce(0) { $0 + $1.0 * $1.1 }
        return (burn.isFinite ? min(max(burn, 0), burnLimit) : 0, dodge.isFinite ? min(max(dodge, 0), dodgeLimit) : 0)
    }
}

/// Where auto development aims a frame's print: its level in scene stops against mid-gray, its
/// cast as red, green and blue stops summing to zero, and its tone step's burn and dodge in paper stops.
public struct PrintAim: Sendable, Equatable, Hashable {
    public var level: Float
    public var cast: SIMD3<Float>
    public var burn: Float
    public var dodge: Float

    public init(level: Float = 0, cast: SIMD3<Float> = .zero, burn: Float = 0, dodge: Float = 0) {
        self.level = level
        self.cast = cast
        self.burn = burn
        self.dodge = dodge
    }

    /// The tone step this aim prints with, counted from its own level; identity without a burn or a dodge.
    public var tone: PrintTone {
        burn == 0 && dodge == 0 ? .identity : PrintTone(burn: burn, dodge: dodge, referenceStops: level)
    }
}

/// Auto lab balance: the print filtration a careful lab would choose, which trims a cast and
/// never removes it (spec, Auto development; docs/M3-research.md, section 2).
///
/// The cast is the colour of the frame's shades-of-gray estimate (`ExposureAnalysis
/// .grayEstimate`), in scene stops at the Negative LUT's input. Through the D55 pin, 130 mired
/// is 1.24 stops of red against blue (M1 white-balance spike), so the spec's bound of 60 mired
/// either way is 0.57 stops of red against blue, and green against magenta gets half that.
/// The lab corrects 0.7 of the cast within those bounds: a 3200 K scene on daylight film keeps
/// about half its warmth.
public enum AutoBalance {
    public static let correctionShare: Float = 0.7
    public static let stopsPerMired: Float = 1.24 / 130
    public static let boundMired: Float = 60
    public static var redBlueLimit: Float { boundMired * stopsPerMired }
    public static var greenMagentaLimit: Float { redBlueLimit / 2 }

    /// The frame's cast, red, green and blue stops summing to zero; zero when unmeasured. The
    /// shades-of-gray estimate, its green against magenta moved by the faces' skin at `skinWeight`
    /// where it would leave them greener or more magenta than skin (`SkinBalance`).
    public static func cast(_ analysis: ExposureAnalysis?, skinWeight: Float = SkinBalance.weight) -> SIMD3<Float> {
        guard let analysis, analysis.grayEstimate.count == 3, analysis.grayEstimate.allSatisfy(\.isFinite) else { return .zero }
        let gray = analysis.grayEstimate
        let v = SIMD3(gray[0], gray[1], gray[2])
        let estimate = v - SIMD3(repeating: v.sum() / 3)
        guard skinWeight > 0, let pull = SkinBalance.pull(analysis, cast: estimate) else { return estimate }
        let (redBlue, greenMagenta) = axes(estimate)
        return Self.cast(redBlue: redBlue, greenMagenta: greenMagenta + skinWeight * pull)
    }

    /// Red against blue and green against magenta, in stops; positive is warm and green.
    public static func axes(_ cast: SIMD3<Float>) -> (redBlue: Float, greenMagenta: Float) {
        (cast.x - cast.z, cast.y - (cast.x + cast.z) / 2)
    }

    /// The zero-sum cast with these two axes.
    public static func cast(redBlue: Float, greenMagenta: Float) -> SIMD3<Float> {
        SIMD3(redBlue / 2 - greenMagenta / 3, 2 * greenMagenta / 3, -redBlue / 2 - greenMagenta / 3)
    }

    /// The share of `cast` the print takes out, bounded on each axis.
    public static func correction(for cast: SIMD3<Float>) -> SIMD3<Float> {
        let (redBlue, greenMagenta) = axes(cast)
        return Self.cast(redBlue: min(max(correctionShare * redBlue, -redBlueLimit), redBlueLimit),
                         greenMagenta: min(max(correctionShare * greenMagenta, -greenMagentaLimit), greenMagentaLimit))
    }

    /// A red-against-blue cast in mired against the daylight reference.
    public static func mired(_ cast: SIMD3<Float>) -> Float { axes(cast).redBlue / stopsPerMired }
}

/// Skin as auto lab balance's second estimate of the light (spec, Auto development: "a skin
/// estimate at half weight when faces exist"; docs/M3-research.md section 2: weight 0.5 or less),
/// on green against magenta only (docs/M3-auto.md section 16).
///
/// Skin varies from person to person along red against blue and hardly at all along green against
/// magenta. Under the reference light, through the D55 pin, NIST's 100 forearm reflectances sit
/// from +0.58 to +1.35 stops of red against blue, red rising about half a stop for each stop darker,
/// but within -0.12 to +0.11 of green against magenta; the ColorChecker's light and dark skin sit at
/// +1.00 and +1.18, and -0.07 and -0.06 (computed, `bake/tools/skin_locus.py`). So a face's red
/// against blue cannot tell a warmer light from a darker person, and a single skin aim would mis-cast
/// someone; its green against magenta can, for every tone. Nor is every face skin: Cube++'s faces
/// over 1 percent of the frame are a poster, a mural, a bronze bust and a silver statue, and on red
/// against blue the poster moved the estimate 2.2 degrees from the measured light (measured).
///
/// The estimate's green against magenta is moved by `weight` of the way toward the nearest light
/// under which the faces' skin, metered over their insets, would sit inside `greenMagenta`, and not
/// at all while it already does: a bound, not an aim.
public enum SkinBalance {
    /// Where skin sits on green against magenta under the reference light, in stops: NIST's
    /// forearms (-0.12 to +0.11) and the faces of Cube++ under their measured light (-0.09 to +0.24,
    /// 22 faces, some of them artworks; measured), with about 0.08 to spare either way.
    public static let greenMagenta: ClosedRange<Float> = -0.2...0.3
    /// The spec's half weight, the research's upper bound.
    public static let weight: Float = 0.5

    /// The faces' skin colour, red against blue and green against magenta in stops, over the faces
    /// whose skin was metered, weighted by its area; `nil` when that skin covers less than
    /// `AutoPrint.minimumFaceArea` of the frame.
    public static func skin(_ analysis: ExposureAnalysis) -> (redBlue: Float, greenMagenta: Float, area: Float)? {
        var sum = SIMD3<Float>(repeating: 0), area: Float = 0
        for face in analysis.faces {
            guard let skin = face.skin, skin.count == 3, skin.allSatisfy({ $0 > 0 && $0.isFinite }), let a = face.skinArea, a > 0 else { continue }
            sum += SIMD3(skin[0], skin[1], skin[2]) * a
            area += a
        }
        guard area >= AutoPrint.minimumFaceArea else { return nil }
        let rgb = sum / area
        let (redBlue, greenMagenta) = AutoBalance.axes(SIMD3(log2(rgb.x), log2(rgb.y), log2(rgb.z)))
        return (redBlue, greenMagenta, area)
    }

    /// How far the estimated `cast` would have to move on green against magenta for the faces'
    /// skin to sit inside `greenMagenta` under the light it leaves; `nil` without faces whose skin
    /// counts.
    public static func pull(_ analysis: ExposureAnalysis, cast: SIMD3<Float>) -> Float? {
        guard let skin = skin(analysis) else { return nil }
        // The skin's green against magenta with the estimated light taken out.
        let u = skin.greenMagenta - AutoBalance.axes(cast).greenMagenta
        return u - min(max(u, greenMagenta.lowerBound), greenMagenta.upperBound)
    }
}

/// A frame's own stock, Rated at, Lab balance, grain and halation, set from the frame view.
///
/// Each control is overridden on its own: `nil` means the frame follows the roll, so a frame
/// given its own Lab balance still moves with the roll's Rated at. Choosing the roll's value
/// for a control clears that control's override. An override stays when the roll is later
/// set to the same value, because it records a decision about the frame.
public struct FrameControls: Sendable, Equatable, Hashable, Codable {
    public var ratedAt: RollControls.RatedAt?
    public var labBalance: RollControls.LabBalance?
    /// The frame's own stock, by id; `nil` develops it through the roll's. Absent from recipes
    /// written before a frame could have one.
    public var stock: String?
    /// The frame's own grain; `nil` takes the roll's, the Develop page's choice.
    public var grain: OutputSettings.Grain?
    /// The frame's own Halation, 0 to 200 (`OutputSettings.halation`); `nil` takes the roll's. Absent from recipes
    /// written before a frame could have one.
    public var halation: Int?

    public init(ratedAt: RollControls.RatedAt? = nil, labBalance: RollControls.LabBalance? = nil,
                stock: String? = nil, grain: OutputSettings.Grain? = nil, halation: Int? = nil) {
        self.ratedAt = ratedAt
        self.labBalance = labBalance
        self.stock = stock
        self.grain = grain
        self.halation = halation
    }

    /// True when the frame follows the roll in every control.
    public var isEmpty: Bool { ratedAt == nil && labBalance == nil && stock == nil && grain == nil && halation == nil }

    /// Gives the frame its own stock, by id, or follows the roll for `nil` or the roll's stock.
    public mutating func setStock(_ id: String?, roll: String?) {
        stock = id == roll ? nil : id
    }

    /// Gives the frame its own grain, or follows the roll for `nil` or the roll's grain.
    public mutating func setGrain(_ value: OutputSettings.Grain?, roll: OutputSettings.Grain) {
        grain = value == roll ? nil : value
    }

    /// Gives the frame its own Halation, held to `OutputSettings.halationRange`, or follows the roll for `nil` or the roll's value.
    public mutating func setHalation(_ value: Int?, roll: Int) {
        let range = OutputSettings.halationRange
        let held = value.map { min(max($0, range.lowerBound), range.upperBound) }
        halation = held == roll ? nil : held
    }

    /// What the frame develops with on a roll set to `roll`.
    public func applied(to roll: RollControls) -> RollControls {
        RollControls(ratedAt: ratedAt ?? roll.ratedAt, labBalance: labBalance ?? roll.labBalance)
    }

    /// Gives the frame its own Rated at, or follows the roll for `nil` or the roll's value.
    public mutating func setRatedAt(_ value: RollControls.RatedAt?, roll: RollControls) {
        ratedAt = value == roll.ratedAt ? nil : value
    }

    /// Gives the frame its own Lab balance, or follows the roll for `nil` or the roll's value.
    public mutating func setLabBalance(_ value: RollControls.LabBalance?, roll: RollControls) {
        labBalance = value == roll.labBalance ? nil : value
    }
}
