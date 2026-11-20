import Foundation

/// What a pixel's masks add up to, for each of the six Light controls: the sum over the masks of
/// coverage × Amount × value (`sX = Σ c·A·V`, docs/masking-plan.md section 4). Lightroom's law, measured
/// bit-exact: partial coverage and Amount scale the slider, overlapping masks add sliders, and the
/// tone function is evaluated once on the sum. So the sum is all the evaluation ever sees.
///
/// Values are in the panel's units, Exposure in stops, and may exceed the panel's range: Amount runs
/// to 2 and masks overlap. `LocalScene` clamps each to its own axis.
public struct LocalSliders: Sendable, Equatable, Hashable {
    public var exposureEV: Float
    public var contrast: Float
    public var highlights: Float
    public var shadows: Float
    public var whites: Float
    public var blacks: Float

    public static let zero = LocalSliders()
    public var isZero: Bool { self == .zero }

    public init(exposureEV: Float = 0, contrast: Float = 0, highlights: Float = 0, shadows: Float = 0,
                whites: Float = 0, blacks: Float = 0) {
        self.exposureEV = exposureEV
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
    }

    /// Adds one mask at this pixel: `coverage * (amount * value)`, the kernel's arithmetic, whose
    /// parameter block holds `amount * value` and whose slices hold the coverage.
    public mutating func add(_ mask: LocalSliders, coverage: Float, amount: Float) {
        exposureEV += coverage * (amount * mask.exposureEV)
        contrast += coverage * (amount * mask.contrast)
        highlights += coverage * (amount * mask.highlights)
        shadows += coverage * (amount * mask.shadows)
        whites += coverage * (amount * mask.whites)
        blacks += coverage * (amount * mask.blacks)
    }

    /// The sum over `masks`. Two masks in either order give the same bits, since addition commutes;
    /// three or more can differ by an ulp of the sum between orders, here and in the kernel, since it
    /// does not associate (measured: at most 1e-4 stops over sixteen masks, far under what a print shows).
    public init(summing masks: [(mask: LocalSliders, coverage: Float, amount: Float)]) {
        self.init()
        for entry in masks { add(entry.mask, coverage: entry.coverage, amount: entry.amount) }
    }
}

/// Masks' render arithmetic, one evaluation of the summed sliders (L1c's "E1", plan section 4), as
/// the CPU reference the kernels are tested against, with the tables they read.
///
/// ```text
/// u   = x + o + E0 + sE                  the pixel's level after all Exposure (o = referenceStops − log2 0.18)
/// ub  = xb + o                           its base's level before any Exposure, the panel's and the masks'
/// t   = L0(ub)                           the panel's local table
/// t  += GH(ub, H0 + sH) − GH(ub, H0)·(1 − w + w/k(H0)),  w = clamp(|sH|/|H0|, 0, 1)     the masks' Highlights, on from
///                                        the panel's H0; at H0 = 0 the row at sH and no second read
/// t  += the same for Shadows, from S0
/// t  += G0(u + t)                        the panel's global table
/// t  += GC(u + t, sC)                    the masks' Contrast
/// q   = GW(u + t, sW) then GB at the level so far: the two tables in sequence
/// t  += q + (stretch(u + t, sW, sB) − q) · smoothstep(0, 25, min(|sW|, |sB|))     when sW ≠ 0 and sB < 0
/// t  += q                                otherwise (Blacks above 0 is Whites, then a lift)
/// rgb′ = rgb · 2^E0 · 2^sE · 2^clamp(t, ±8)
/// ```
///
/// Everything here depends on the stock, the rating, the print offset (print exposure and lab
/// balance) and the reference, as `ManualToneTables`' transfer does, and on no slider: a slider or
/// Amount move changes `LocalSliders` and never a table. Choices, each for its reason:
/// - Contrast, Whites and Blacks are `LightroomLocalToneTargets`' rows, not the panel's: a mask's are
///   fixed curves of lightness and the panel's adapt to the frame (3 to 10 rms L* apart).
/// - Highlights and Shadows are the panel's own gain times k(|s|), by control and sign: Lightroom's
///   are the panel's at ±100 and stronger between. They read the unexposed base, whatever the panel's
///   compiler does, and clamp at ±100, where they saturate.
/// - Each table is built one control at a time. Sums act through the one evaluation, not through a
///   composed target as the panel's tables compose theirs.
/// - A panel and a mask on Highlights or Shadows move along one row, from the panel's value to the
///   sum, as Lightroom adds their sliders. Two tables added would fall: where the base follows the
///   pixel, panel −50 and mask −50 reverse smooth highlights by 3.8 L* on Portra 160.
/// - `G(ub, P)` carries k(P) and `L0` does not, so a plain difference of rows would leave
///   `(1 − k(P)) · L0` behind and miss Lightroom's sum (0.45 rms against 0.13 on a picture). That share
///   fades out over the mask's first |P| of slider: s → 0 is `L0`, P = 0 is `G(s)`, s = P is the row at
///   the sum, s = −P is no gain.
/// - Whites with Blacks below 0 is one levels stretch in lightness, black point from Blacks and white
///   point from Whites: Lightroom's own form, 0.63 rms against 2.88 for the two tables in sequence.
///   Otherwise the two tables in sequence are what was measured: a single control keeps its measured
///   curve (a stretch is only within ±1 L* of it), and Blacks above 0 is Whites, then a lift.
/// - The stretch and the tables differ by up to 2.5 L*, so a change of path where one slider reaches
///   zero would be a line across the frame. They are mixed over the last `stretchBlendWidth` of the
///   smaller slider. Every measured pair of Whites and Blacks is at or past it.
/// - The two table axes differ: 17 knots 12.5 apart over ±100 for Highlights and Shadows, 25 apart
///   over ±200 for Contrast, Whites and Blacks. The summed slider is clamped to its axis, so the
///   flattest a stack can be is the flattest table, however many masks it has.
public struct LocalScene: Sendable, Equatable {
    /// The buffer's layout, in floats. Every offset is a constant: nothing here varies by stock.
    /// `GX` holds `knots` rows of `samples` gains, the level fastest, so the sample at `knot`, `level`
    /// is `offset + knot * samples + level`.
    public enum Layout {
        public static let samples = ManualToneTables.sampleCount
        public static let knots = 17
        public static let tableFloats = knots * samples
        public static let highlights = 0
        public static let shadows = highlights + tableFloats
        public static let contrast = shadows + tableFloats
        public static let whites = contrast + tableFloats
        public static let blacks = whites + tableFloats
        /// T̃ at the tables' samples, `samples` floats.
        public static let regularized = blacks + tableFloats
        /// T̃'s inverse, in stops from the reference, at lightness `inverseStart + i / inverseScale`.
        public static let inverse = regularized + samples
        public static let inverseCount = 1401
        public static let inverseStart: Float = -20
        public static let inverseScale: Float = 10
        /// The stretch's rows, `knots` floats each, on the Contrast, Whites and Blacks axis. The
        /// evaluation reads `blackPoint` and `whitePoint`; `outputFloor` is what the Blacks table
        /// above 0 lifts to, kept with them as the plan's table has it and read by no kernel.
        public static let blackPoint = inverse + inverseCount
        public static let outputFloor = blackPoint + knots
        public static let whitePoint = outputFloor + knots
        public static let count = whitePoint + knots
    }

    /// One table's value axis. `(value − start) / spacing` is exact at a knot, as a product with
    /// 1 / spacing would not be, so a slider on a knot reads that row alone.
    public struct Axis: Sendable, Equatable {
        public let start: Float
        public let spacing: Float
        public var last: Float { start + spacing * Float(Layout.knots - 1) }
        public func value(atKnot knot: Int) -> Float { start + spacing * Float(knot) }

        @inline(__always) func position(_ value: Float) -> (low: Int, high: Int, fraction: Float) {
            let scaled = (value - start) / spacing
            let position = scaled.isNaN ? 0 : min(max(scaled, 0), Float(Layout.knots - 1))
            let low = Int(position)
            return (low, min(low + 1, Layout.knots - 1), position - Float(low))
        }
    }

    public static let saturatingAxis = Axis(start: -100, spacing: 12.5)
    public static let extendingAxis = Axis(start: -200, spacing: 25)

    public enum Table: CaseIterable, Sendable {
        case highlights, shadows, contrast, whites, blacks

        public var offset: Int {
            switch self {
            case .highlights: Layout.highlights
            case .shadows: Layout.shadows
            case .contrast: Layout.contrast
            case .whites: Layout.whites
            case .blacks: Layout.blacks
            }
        }
        public var axis: Axis {
            switch self {
            case .highlights, .shadows: LocalScene.saturatingAxis
            case .contrast, .whites, .blacks: LocalScene.extendingAxis
            }
        }
    }

    /// The summed Exposure's limit in stops. Sixteen masks at ±5 EV and Amount 2 sum to ±160, past
    /// `Float`'s range as a gain, and a zero channel times an infinite gain is NaN. The film's whole
    /// range is under 21 stops, so a limit this far out changes nothing a print can show.
    public static let exposureLimit: Float = 32
    /// The evaluation's limit on `t` in stops, the plan's.
    public static let gainLimit: Float = 8
    /// The size of the smaller of Whites and Blacks at which the stretch has fully taken over from
    /// the two tables, in slider units.
    public static let stretchBlendWidth: Float = 25
    private static let logMidGray = log2(Float(0.18))

    /// One flat buffer, `Layout.count` floats (181 KB), for a `device const float *` binding.
    public let tables: [Float]
    public let referenceStops: Float
    /// Stops from the reference at the first level sample and between neighbours: the panel's
    /// tables' own geometry for the same stock, settings and reference.
    public let start: Float
    public let step: Float

    public var byteCount: Int { tables.count * MemoryLayout<Float>.stride }
    /// `o`: from the guide's units, log2 luminance before Exposure, to stops from the reference.
    public var referenceOffset: Float { referenceStops - Self.logMidGray }

    public init(referenceStops: Float, stock: Stock, settings: DevelopSettings) {
        let neutral = ManualToneTables.Transfer(referenceStops: referenceStops, stock: stock, settings: settings)
        self.referenceStops = referenceStops
        start = neutral.start
        step = neutral.step

        var floats: [Float] = []
        floats.reserveCapacity(Layout.count)
        func gains(_ targets: [ManualToneTables.Target?]) -> [Float] {
            ManualToneTables.gains(composing: targets.compactMap { $0 }, regularized: neutral.regularized, xs: neutral.xs, step: neutral.step)
        }
        let local: [(rows: [[Float]], negative: [Float], positive: [Float])] = [
            (LightroomToneTargets.highlights, LightroomLocalToneTargets.highlightsScaleNegative, LightroomLocalToneTargets.highlightsScalePositive),
            (LightroomToneTargets.shadows, LightroomLocalToneTargets.shadowsScaleNegative, LightroomLocalToneTargets.shadowsScalePositive),
        ]
        for control in local {
            for knot in 0..<Layout.knots {
                let value = Self.saturatingAxis.value(atKnot: knot)
                let k = Self.scale(at: value, negative: control.negative, positive: control.positive)
                floats += gains([ManualToneTables.Target(control.rows, value: value)]).map { $0 * k }
            }
        }
        for rows in [LightroomLocalToneTargets.contrast, LightroomLocalToneTargets.whites, LightroomLocalToneTargets.blacks] {
            for knot in 0..<Layout.knots {
                floats += gains([ManualToneTables.Target(rows, value: Self.extendingAxis.value(atKnot: knot),
                                                         values: LightroomLocalToneTargets.values,
                                                         lightness: LightroomLocalToneTargets.lightness)])
            }
        }
        floats += neutral.regularized
        for i in 0..<Layout.inverseCount {
            let lightness = Layout.inverseStart + Float(i) / Layout.inverseScale
            floats.append(ManualToneTables.inverse(lightness, regularized: neutral.regularized, start: neutral.start, step: neutral.step))
        }
        floats += LightroomLocalToneTargets.blackPoint + LightroomLocalToneTargets.outputFloor + LightroomLocalToneTargets.whitePoint
        tables = floats
    }

    /// `scene` with other floats, for a test to find out what an evaluation reads.
    init(_ scene: LocalScene, tables: [Float]) {
        self.tables = tables
        referenceStops = scene.referenceStops
        start = scene.start
        step = scene.step
    }

    /// k(|s|): linear between the fitted sizes; below the first, the first's, where nothing was
    /// measured and the gain itself is going to zero.
    static func scale(at value: Float, negative: [Float], positive: [Float]) -> Float {
        let scales = value < 0 ? negative : positive, sizes = LightroomLocalToneTargets.scaleMagnitudes
        let size = abs(value)
        if size <= sizes[0] { return scales[0] }
        let upper = sizes.firstIndex { $0 >= size } ?? sizes.count - 1
        let t = (size - sizes[upper - 1]) / (sizes[upper] - sizes[upper - 1])
        return scales[upper - 1] + (scales[upper] - scales[upper - 1]) * t
    }

    // MARK: Reading

    /// `GX(level, value)`: linear in both, constant beyond both axes' ends. The level's arithmetic
    /// is `ManualToneTables.value(_:at:)`'s, so a row equal to a panel table reads the same bits.
    public func gain(_ table: Table, at level: Float, value: Float) -> Float {
        let row = table.axis.position(value)
        let (low, fraction) = levelPosition(level)
        let first = table.offset + row.low * Layout.samples + low
        let second = table.offset + row.high * Layout.samples + low
        let a = tables[first] + (tables[first + 1] - tables[first]) * fraction
        let b = tables[second] + (tables[second + 1] - tables[second]) * fraction
        return a + (b - a) * row.fraction
    }

    @inline(__always) private func levelPosition(_ level: Float) -> (low: Int, fraction: Float) {
        let last = Float(Layout.samples - 1)
        let scaled = (level - start) * (1 / step)
        let position = scaled.isNaN ? 0 : min(max(scaled, 0), last)
        let low = min(Int(position), Layout.samples - 2)
        return (low, position - Float(low))
    }

    /// T̃ at `level`, continuing at its minimum slope beyond the samples as `ManualToneTables.inverse`
    /// does, so the stretch keeps rising where earlier gains have carried a level past the tables.
    func lightness(at level: Float) -> Float {
        let (low, fraction) = levelPosition(level)
        let a = tables[Layout.regularized + low], b = tables[Layout.regularized + low + 1]
        let inside = min(max(level, start), start + Float(Layout.samples - 1) * step)
        return a + (b - a) * fraction + (level - inside) * ManualToneTables.minimumSlope
    }

    /// T̃'s inverse at `lightness`, constant beyond the row's ends.
    func stops(atLightness lightness: Float) -> Float {
        let scaled = (lightness - Layout.inverseStart) * Layout.inverseScale
        let position = scaled.isNaN ? 0 : min(max(scaled, 0), Float(Layout.inverseCount - 1))
        let low = min(Int(position), Layout.inverseCount - 2)
        let a = tables[Layout.inverse + low], b = tables[Layout.inverse + low + 1]
        return a + (b - a) * (position - Float(low))
    }

    private func row(_ offset: Int, at value: Float) -> Float {
        let p = Self.extendingAxis.position(value)
        let a = tables[offset + p.low], b = tables[offset + p.high]
        return a + (b - a) * p.fraction
    }

    /// Whites and Blacks below 0 as one levels stretch, in T̃'s lightness and back, softly limited as
    /// the tables' gains are. Beyond black and white the output continues at the targets' slope floor,
    /// so the map keeps rising where the film has no tone left to separate.
    public func stretchGain(at level: Float, whites: Float, blacks: Float) -> Float {
        let black = row(Layout.blackPoint, at: blacks), white = row(Layout.whitePoint, at: whites)
        let v = (lightness(at: level) - black) / (white - black)
        let c = min(max(v, 0), 1)
        let aim = 100 * c + 100 * ManualToneTables.minimumTargetSlope * (v - c)
        return ManualToneTables.limited(stops(atLightness: aim) - level)
    }

    /// Whites and Blacks below 0, both set: the stretch, mixed into the two tables in sequence while
    /// the smaller slider is under `stretchBlendWidth`, so the path never changes on a line. Past that
    /// the tables are not read. At fixed sliders this is a convex mix of two rising maps, so it rises.
    public func jointGain(at level: Float, whites: Float, blacks: Float) -> Float {
        let stretch = stretchGain(at: level, whites: whites, blacks: blacks)
        let size = min(abs(whites), abs(blacks))
        guard size < Self.stretchBlendWidth else { return stretch }
        let first = gain(.whites, at: level, value: whites)
        let sequence = first + gain(.blacks, at: level + first, value: blacks)
        let u = size / Self.stretchBlendWidth
        return sequence + (stretch - sequence) * (u * u * (3 - 2 * u))
    }

    /// A mask's Highlights or Shadows over the panel's: `G(level, P + s) − G(level, P) · (1 − w + w / k(P))`,
    /// `w = clamp(|s| / |P|, 0, 1)`, written with `fade = 1 / k(P) − 1`. The axis clamps the sum, so past
    /// ±100 it saturates, as Lightroom's does. With no panel value it is the row at the mask's value
    /// and reads nothing more.
    private func move(_ table: Table, at level: Float, panel: Float, fade: Float, mask: Float) -> Float {
        let moved = gain(table, at: level, value: panel + mask)
        guard panel != 0 else { return moved }
        return moved - gain(table, at: level, value: panel) * (1 + min(abs(mask) / abs(panel), 1) * fade)
    }

    // MARK: The evaluation

    /// What the panel contributes to one evaluation. Masks render only under the current Light compiler
    /// or a later one (plan section 7, enforced where an edit takes a mask), so its local table reads the
    /// unexposed base as a mask's do, and one offset serves both.
    public struct Panel: Sendable, Equatable {
        public let exposureEV: Float
        public let exposureGain: Float
        /// The panel's Highlights and Shadows, H0 and S0: where a mask's move along those rows starts.
        public let highlights: Float
        public let shadows: Float
        /// `1 / k(H0) − 1` and `1 / k(S0) − 1`: the share of a row at the panel's value that is k and
        /// not the panel. Constants of the edit. Zero at ±100 and where there is no panel value.
        public let highlightsFade: Float
        public let shadowsFade: Float
        public let tables: ManualToneTables?
        let localActive: Bool
        let globalActive: Bool

        /// No panel: no Exposure and no tone tables.
        public static let none = Panel(exposureEV: 0, exposureGain: 1, highlights: 0, shadows: 0, tables: nil, localActive: false, globalActive: false)

        private init(exposureEV: Float, exposureGain: Float, highlights: Float, shadows: Float,
                     tables: ManualToneTables?, localActive: Bool, globalActive: Bool) {
            self.exposureEV = exposureEV
            self.exposureGain = exposureGain
            self.highlights = highlights
            self.shadows = shadows
            highlightsFade = highlights == 0 ? 0 : 1 / LocalScene.scale(at: highlights, negative: LightroomLocalToneTargets.highlightsScaleNegative,
                                                                        positive: LightroomLocalToneTargets.highlightsScalePositive) - 1
            shadowsFade = shadows == 0 ? 0 : 1 / LocalScene.scale(at: shadows, negative: LightroomLocalToneTargets.shadowsScaleNegative,
                                                                  positive: LightroomLocalToneTargets.shadowsScalePositive) - 1
            self.tables = tables
            self.localActive = localActive
            self.globalActive = globalActive
        }

        /// `tables` are `manual.toneTables(stock:settings:)`, built with the scene's stock, settings
        /// and reference. Light compiler `2026-10-09-1` takes no mask (plan decision 7).
        public init(_ manual: ManualRenderSettings, tables: ManualToneTables?) throws {
            let p = try manual.parameters(tables: tables)
            guard manual.isIdentity || p.sceneTables != 0 else { throw ManualDevelopmentError.unsupportedVersion(manual.version) }
            precondition(tables != nil || !manual.needsToneTables, "\(manual.version)'s tone controls need their tables")
            self.init(exposureEV: manual.adjustments.exposureEV, exposureGain: p.exposureGain,
                      highlights: manual.adjustments.highlights, shadows: manual.adjustments.shadows, tables: tables,
                      localActive: p.localActive != 0, globalActive: p.globalActive != 0)
        }
    }

    /// `t`, the one evaluation's gain in stops, clamped: `x` is the pixel's `guideLog2` before any
    /// Exposure and `xb` its base in the same units.
    public func gain(x: Float, xb: Float, sliders s: LocalSliders, panel: Panel) -> Float {
        precondition(panel.tables.map { $0.start == start && $0.step == step } ?? true, "the panel's tables are for another transfer")
        let levelOffset = panel.exposureEV + referenceStops - Self.logMidGray
        let u = x + levelOffset + Self.exposure(s)
        let ub = xb + referenceOffset
        var t: Float = 0
        if panel.localActive, let tables = panel.tables { t = tables.value(tables.local, at: ub) }
        if s.highlights != 0 { t += move(.highlights, at: ub, panel: panel.highlights, fade: panel.highlightsFade, mask: s.highlights) }
        if s.shadows != 0 { t += move(.shadows, at: ub, panel: panel.shadows, fade: panel.shadowsFade, mask: s.shadows) }
        if panel.globalActive, let tables = panel.tables { t += tables.value(tables.global, at: u + t) }
        if s.contrast != 0 { t += gain(.contrast, at: u + t, value: s.contrast) }
        if s.whites != 0 && s.blacks < 0 {
            t += jointGain(at: u + t, whites: s.whites, blacks: s.blacks)
        } else {
            if s.whites != 0 { t += gain(.whites, at: u + t, value: s.whites) }
            if s.blacks != 0 { t += gain(.blacks, at: u + t, value: s.blacks) }
        }
        return min(max(t, -Self.gainLimit), Self.gainLimit)
    }

    /// CPU reference for one pixel: `rgb` before any Exposure, `baseLog2` its local base in
    /// `ToneBaseField`'s units. All three channels take one gain, as the panel's do.
    public func applying(to rgb: SIMD3<Float>, baseLog2: Float, sliders: LocalSliders, panel: Panel) -> SIMD3<Float> {
        let t = gain(x: ManualRenderSettings.guideLog2(rgb), xb: baseLog2, sliders: sliders, panel: panel)
        return rgb * panel.exposureGain * exp2(Self.exposure(sliders)) * exp2(t)
    }

    @inline(__always) private static func exposure(_ s: LocalSliders) -> Float {
        min(max(s.exposureEV, -exposureLimit), exposureLimit)
    }
}
