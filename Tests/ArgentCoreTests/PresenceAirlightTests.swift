import Testing
@testable import ArgentCore

/// Dehaze's airlight, selected in place, against `fit_dehaze.py`'s `Field` written plainly: the colours of the pixels at or above the
/// quantile in an array, sorted, and their middle.
struct PresenceAirlightTests {
    static func numpyQuantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted(), h = q * Double(values.count - 1), below = Int(h.rounded(.down)), t = h - Double(below)
        let low = sorted[below], high = below + 1 < sorted.count ? sorted[below + 1] : low, span = high - low
        return t >= 0.5 ? high - span * (1 - t) : low + span * t
    }

    static func sortedAirlight(dark: [Double], colours: [SIMD3<Double>], constants: PresenceConstants.Dehaze) -> SIMD3<Double> {
        let threshold = numpyQuantile(dark, Double(constants.airlightQuantile))
        var chosen = colours.indices.filter { dark[$0] >= threshold }.map { colours[$0] }
        if constants.airlightBrightShare > 0 {
            let lightness = chosen.map { ($0 * SIMD3<Double>(Rec2020.luma)).sum() }
            let bright = numpyQuantile(lightness, Double(constants.airlightBrightShare))
            chosen = zip(chosen, lightness).filter { $0.1 >= bright }.map(\.0)
        }
        func median(_ channel: Int) -> Double {
            let sorted = chosen.map { $0[channel] }.sorted(), middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }
        return pointwiseMax(SIMD3(median(0), median(1), median(2)), SIMD3(repeating: PresenceAnalysisBuilder.airlightFloor))
    }

    /// Every kind of tie the airlight meets, to the bit: the eroded least channel at one level, so the quantile takes every pixel, at
    /// three, or continuous; colours at one level, at four, so a median falls inside a run, or continuous and some below 0; odd and even
    /// counts; the version's quantile and others, with and without a bright share.
    @Test func theSelectionIsTheSortToTheBit() {
        var cases = 0
        for count in [1, 2, 7, 1000, 4096, 4097] {
            for darkLevels in [1, 3, 0] {
                for colourLevels in [1, 4, 0] {
                    for quantile: Float in [0.999, 0.99, 0.5, 0] {
                        for brightShare: Float in [0, 0.5] {
                            var generator = SplitMix64(state: UInt64(cases))
                            func value(_ levels: Int) -> Double {
                                levels == 0 ? Double.random(in: -0.2...2, using: &generator)
                                    : 0.3 + Double(Int.random(in: 0..<levels, using: &generator)) * 0.25
                            }
                            let dark = (0..<count).map { _ in value(darkLevels) }
                            let colours = (0..<count).map { _ in SIMD3(value(colourLevels), value(colourLevels), value(colourLevels)) }
                            let constants = PresenceAnalysisBuilderTests.constants(dehaze: .init(
                                longSide: 64, omega: 0.95, airlightRadius: 0.05, airlightQuantile: quantile, airlightBrightShare: brightShare,
                                darkRadius: 0.03, guideRadius: 0.1, epsilon: 0.5)).dehaze
                            var room = [UInt32](repeating: 0, count: count)
                            let selected = room.withUnsafeMutableBufferPointer {
                                PresenceAnalysisBuilder.airlight(count: count, dark: { dark[$0] }, colour: { colours[$0] }, chosen: $0,
                                                                 constants: constants)
                            }
                            let sorted = Self.sortedAirlight(dark: dark, colours: colours, constants: constants)
                            let field = "\(count) pixels, \(darkLevels) dark levels, \(colourLevels) colour levels"
                            #expect((0..<3).allSatisfy { selected[$0].bitPattern == sorted[$0].bitPattern },
                                    "\(field), quantile \(quantile), bright \(brightShare): \(selected) against \(sorted)")
                            cases += 1
                        }
                    }
                }
            }
        }
    }
}
