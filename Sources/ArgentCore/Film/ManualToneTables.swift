import Foundation

/// The gain-table compilers' Contrast, Highlights, Shadows, Whites and Blacks for one render: two
/// tables of scene gain in stops, one read at the pixel's own light and one at its local base. They
/// are the same for 2026-10-29-1 and 2026-11-06-1, which differ only in where the local one is read:
/// `ManualCurveParameters.baseOffset`.
///
/// Each control is Lightroom's change of output lightness (`LightroomToneTargets`). The render's
/// neutral transfer T, the print's CIE L* for a neutral scene `x` stops from the manual reference
/// (through the Negative LUT at the rating, the print offset and the Print LUT), turns a lightness
/// change into a scene change: `g(x) = T⁻¹(target(T(x))) − x`. So the controls act on light before
/// the film, as Lightroom's act before its profile's curve, and land where their targets say on every
/// stock, rating and print exposure. The targets were fitted with Exposure at 0, where every read
/// agrees. With Exposure set, the global table reads `x` after it, and on 2026-11-06-1 the local table
/// reads the base before it, as Lightroom's Highlights and Shadows do.
///
/// Choices, each for its reason:
/// - Lightness is the print's own: its black (T at the bottom of the Negative LUT's range) is 0
///   and its white (T at the top) is 100. Lightroom's L* runs from its output's black to its
///   white; a print's runs from about 4 to 99, and a target taken literally below the paper's
///   black could only be met by crushing the toe to it.
/// - Targets are linear in the control's value between measured rows (0 changes nothing) and a
///   shape-preserving cubic in lightness (the tangents `ToneCurves` uses), so the gains have no
///   corners at the targets' 5 L* columns and no overshoot between them.
/// - Whites, then Blacks, then Contrast compose into one global map, Highlights then Shadows into
///   the local one; each is forced to rise by at least `minimumTargetSlope` so the pixel map
///   keeps luminance order even where the measured targets dip or controls oppose.
/// - T̃ is T with a slope of at least `minimumSlope` per stop, built out from T's steepest point:
///   it equals T wherever the film separates tones and only differs in the flat toe and shoulder,
///   where an exact inverse does not exist. A change of Δ there costs about Δ stops.
/// - Gains pass through a soft limit: exact up to `gainKnee`, then easing toward `gainLimit`.
///   Its slope stays within 0...1, so the map stays monotone; the limit is the deepest a pixel
///   outside the film's range can be brought into it.
/// - `sampleCount` samples span the Negative LUT's range plus `gainLimit` either side (21 stops
///   on the baked stocks, 0.041 stops apart), so T's LUT cells (0.2 stops at size 65) are resolved
///   and both tables fit 4 KB. Interpolation is linear and constant beyond the ends, on the CPU
///   and in Metal alike, so the two agree by construction.
public struct ManualToneTables: Sendable, Equatable {
    public static let sampleCount = 512
    static let minimumSlope: Float = 1
    static let minimumTargetSlope: Float = 0.05
    static let gainKnee: Float = 2
    static let gainLimit: Float = 4

    /// Stops from the manual reference at the first sample, and between neighbouring samples.
    public let start: Float
    public let step: Float
    /// Gain in stops at each sample: Whites, Blacks and Contrast at the pixel's own light, after
    /// Exposure and the local gain; Highlights and Shadows at the pixel's local base, before Exposure
    /// on 2026-11-06-1 and after it on 2026-10-29-1. Zero where unset.
    public let global: [Float]
    public let local: [Float]
    public let globalActive: Bool
    public let localActive: Bool
    /// T at each sample in CIE L*, and T̃ in the print's own lightness: what the gains came from.
    let transfer: [Float]
    let regularized: [Float]

    /// `table` at `x` stops: linear between samples, constant beyond the ends. Metal's
    /// `manual_table` is the same arithmetic.
    public func value(_ table: [Float], at x: Float) -> Float {
        let last = Float(table.count - 1)
        let scaled = (x - start) * (1 / step)
        let position = scaled.isNaN ? 0 : min(max(scaled, 0), last)
        let low = min(Int(position), table.count - 2)
        let a = table[low], b = table[low + 1]
        return a + (b - a) * (position - Float(low))
    }

    /// The largest gain the two tables can add together, for the halation source's storage scale.
    var maximumGain: Float { max(0, global.max() ?? 0) + max(0, local.max() ?? 0) }

    init(adjustments a: ManualAdjustments, referenceStops: Float, stock: Stock, settings: DevelopSettings) {
        let neutral = Transfer(referenceStops: referenceStops, stock: stock, settings: settings)
        start = neutral.start
        step = neutral.step
        transfer = neutral.lightness
        regularized = neutral.regularized

        let globalTargets = [Target(LightroomToneTargets.whites, value: a.whites),
                             Target(LightroomToneTargets.blacks, value: a.blacks),
                             Target(LightroomToneTargets.contrast, value: a.contrast)].compactMap { $0 }
        let localTargets = [Target(LightroomToneTargets.highlights, value: a.highlights),
                            Target(LightroomToneTargets.shadows, value: a.shadows)].compactMap { $0 }
        globalActive = !globalTargets.isEmpty
        localActive = !localTargets.isEmpty
        global = Self.gains(composing: globalTargets, regularized: regularized, xs: neutral.xs, step: step)
        local = Self.gains(composing: localTargets, regularized: regularized, xs: neutral.xs, step: step)
    }

    /// The render's neutral transfer over the tables' samples: what any table of gains for this
    /// stock, rating, print offset and reference is built from (the panel's here, a mask's in
    /// `LocalScene`). It depends on no control.
    struct Transfer: Sendable, Equatable {
        let start: Float
        let step: Float
        /// Stops from the manual reference at each sample.
        let xs: [Float]
        /// T at each sample in CIE L*, and T̃ in the print's own lightness.
        let lightness: [Float]
        let regularized: [Float]

        init(referenceStops: Float, stock: Stock, settings: DevelopSettings) {
            let count = ManualToneTables.sampleCount
            let encoding = stock.negative.encoding
            let rated = settings.exposureStops(boxSpeed: stock.boxSpeed)
            let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
            // The Negative LUT's range in stops from the reference 0.18 * 2^-referenceStops.
            let shift = referenceStops - rated - log2(0.18 / encoding.midGray)
            let start = -encoding.stopsBelowMidGray + shift - ManualToneTables.gainLimit
            let step = (encoding.range + 2 * ManualToneTables.gainLimit) / Float(count - 1)
            let xs = (0..<count).map { start + Float($0) * step }
            self.start = start
            self.step = step
            self.xs = xs

            let transfer = xs.map { x in
                let encoded = min(max((x - shift + encoding.stopsBelowMidGray) / encoding.range, 0), 1)
                let negative = stock.negative.sample(encoded: SIMD3(repeating: encoded))
                let density = stock.paperAmounts(negative + offset, grade: settings.paperGrade)
                    .clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
                return ManualToneTables.lightness(ManualRenderSettings.luminance(stock.print.sample(encoded: density)))
            }
            lightness = transfer
            let black = transfer[0], span = max(transfer[count - 1] - black, 1)
            let own = transfer.map { 100 * ($0 - black) / span }
            let rises = zip(own, own.dropFirst()).map { $1 - $0 }
            let anchor = rises.indices.max { rises[$0] < rises[$1] } ?? 0
            var regularized = own
            let least = ManualToneTables.minimumSlope * step
            for i in stride(from: anchor + 1, to: count, by: 1) { regularized[i] = regularized[i - 1] + max(rises[i - 1], least) }
            for i in stride(from: anchor - 1, through: 0, by: -1) { regularized[i] = regularized[i + 1] - max(rises[i], least) }
            self.regularized = regularized
        }
    }

    /// `x' − x` at every sample, `x'` where T̃ reaches the composed targets of T̃(x), softly limited.
    static func gains(composing targets: [Target], regularized: [Float], xs: [Float], step: Float) -> [Float] {
        guard !targets.isEmpty else { return [Float](repeating: 0, count: xs.count) }
        var previous = -Float.infinity
        return xs.indices.map { i in
            var aim = regularized[i]
            for target in targets { aim += target.change(at: aim) }
            if i > 0 { aim = max(aim, previous + minimumTargetSlope * (regularized[i] - regularized[i - 1])) }
            previous = aim
            return limited(inverse(aim, regularized: regularized, start: xs[0], step: step) - xs[i])
        }
    }

    /// The stops where T̃ reaches `lightness`, continuing at the minimum slope beyond the samples.
    static func inverse(_ lightness: Float, regularized t: [Float], start: Float, step: Float) -> Float {
        let last = t.count - 1
        if lightness <= t[0] { return start + (lightness - t[0]) / minimumSlope }
        if lightness >= t[last] { return start + Float(last) * step + (lightness - t[last]) / minimumSlope }
        var low = 0, high = last
        while high - low > 1 {
            let middle = (low + high) / 2
            if t[middle] <= lightness { low = middle } else { high = middle }
        }
        return start + (Float(low) + (lightness - t[low]) / (t[low + 1] - t[low])) * step
    }

    /// Identity up to the knee, then a tanh easing toward the limit with the same slope at the join.
    static func limited(_ gain: Float) -> Float {
        let size = abs(gain)
        guard size > gainKnee else { return gain }
        let room = gainLimit - gainKnee
        return (gain < 0 ? -1 : 1) * (gainKnee + room * tanh((size - gainKnee) / room))
    }

    /// CIE L* of a relative luminance, white 1 at 100; continued linearly below zero.
    static func lightness(_ y: Float) -> Float {
        y <= 216 / 24389 ? y * 24389 / 27 : 116 * cbrt(y) - 16
    }

    /// One control's lightness change at its value: rows interpolated linearly in the value, with
    /// an implicit zero row, then a shape-preserving cubic across lightness, constant beyond it.
    /// The rows are the panel's unless `values` and `lightness` say otherwise (`LocalScene`'s).
    struct Target {
        let lightness: [Float]
        let change: [Float]
        let tangents: [Float]

        init?(_ rows: [[Float]], value: Float, values rowValues: [Float] = LightroomToneTargets.values,
              lightness grid: [Float] = LightroomToneTargets.lightness) {
            guard value != 0 else { return nil }
            var values = rowValues, table = rows
            let zero = values.firstIndex { $0 > 0 } ?? values.count
            values.insert(0, at: zero)
            table.insert([Float](repeating: 0, count: grid.count), at: zero)
            let clamped = min(max(value, values[0]), values[values.count - 1])
            let upper = max(1, min(values.count - 1, values.firstIndex { $0 >= clamped } ?? values.count - 1))
            let t = (clamped - values[upper - 1]) / (values[upper] - values[upper - 1])
            lightness = grid
            change = zip(table[upper - 1], table[upper]).map { $0 + ($1 - $0) * t }
            tangents = Self.tangents(x: lightness, y: change)
        }

        func change(at l: Float) -> Float {
            let last = lightness.count - 1
            if l <= lightness[0] { return change[0] }
            if l >= lightness[last] { return change[last] }
            var i = 0
            while i < last - 1 && l > lightness[i + 1] { i += 1 }
            let h = lightness[i + 1] - lightness[i], u = (l - lightness[i]) / h
            let u2 = u * u, u3 = u2 * u
            return (2 * u3 - 3 * u2 + 1) * change[i] + (u3 - 2 * u2 + u) * h * tangents[i]
                + (-2 * u3 + 3 * u2) * change[i + 1] + (u3 - u2) * h * tangents[i + 1]
        }

        /// `ToneCurves`' tangents: weighted harmonic means of the neighbouring slopes, zero at a
        /// local extremum, scaled into the monotone region.
        private static func tangents(x: [Float], y: [Float]) -> [Float] {
            let slopes = (0..<(x.count - 1)).map { (y[$0 + 1] - y[$0]) / (x[$0 + 1] - x[$0]) }
            var tangents = [Float](repeating: 0, count: x.count)
            tangents[0] = slopes[0]; tangents[x.count - 1] = slopes[slopes.count - 1]
            for i in 1..<(x.count - 1) where slopes[i - 1] * slopes[i] > 0 {
                let h0 = x[i] - x[i - 1], h1 = x[i + 1] - x[i]
                let w0 = 2 * h1 + h0, w1 = h1 + 2 * h0
                tangents[i] = (w0 + w1) / (w0 / slopes[i - 1] + w1 / slopes[i])
            }
            for i in slopes.indices {
                if slopes[i] == 0 { tangents[i] = 0; tangents[i + 1] = 0; continue }
                let a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i], length = a * a + b * b
                if length > 9 {
                    let scale = 3 / sqrt(length)
                    tangents[i] = scale * a * slopes[i]; tangents[i + 1] = scale * b * slopes[i]
                }
            }
            return tangents
        }
    }
}
