import Foundation
import Testing
@testable import ArgentCore

@Suite struct GamutCompressionTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func constantsMatchThePythonPins() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("bake/argent_bake/gamut.py"), encoding: .utf8)
        #expect(source.contains("THRESHOLD = (0.90, 0.90, 0.90)"))
        #expect(source.contains("POWER = 1.2"))
        #expect(source.contains("LIMITS = (1.3964, 1.1686, 1.0246)"))
        #expect(GamutCompression.threshold == 0.90)
        #expect(GamutCompression.power == 1.2)
        #expect(GamutCompression.limits == SIMD3<Float>(1.3964, 1.1686, 1.0246))
        #expect(RenderGraph.version == "2026-11-19-1")
    }

    @Test func inThresholdAndNonpositiveColorsAreIdentical() {
        for rgb in [SIMD3<Float>(1, 0.1, 0.4), SIMD3(0.2, 0.3, 0.4), SIMD3(-1, -2, -3), SIMD3(0, -1, -2)] {
            let mapped = GamutCompression.compress(rgb)
            for channel in 0..<3 { #expect(mapped[channel].bitPattern == rgb[channel].bitPattern) }
        }
    }

    @Test func neutralsAreUnchanged() {
        for value: Float in [-10, -0.0, 0, 0.18, 1, 100] {
            let rgb = SIMD3<Float>(repeating: value)
            #expect(GamutCompression.compress(rgb) == rgb)
        }
    }

    @Test func limitsLandOnTheEdgeAndTheMaximumIsPreserved() {
        for channel in 0..<3 {
            var rgb = SIMD3<Float>(repeating: 1)
            rgb[channel] -= GamutCompression.limits[channel]
            let mapped = GamutCompression.compress(rgb)
            #expect(abs(mapped[channel]) < 1e-6)
            #expect(mapped.max() == rgb.max())
        }
    }

    @Test func increasingDistancesStayDistinctAndMonotonic() {
        for channel in 0..<3 {
            var previous: Float = 2
            for step in 0...1000 {
                var rgb = SIMD3<Float>(repeating: 1)
                rgb[channel] -= Float(step) / 1000 * GamutCompression.limits[channel] * 3
                let mapped = GamutCompression.compress(rgb)
                #expect(mapped[channel] < previous)
                #expect(mapped.max() == rgb.max())
                previous = mapped[channel]
            }
        }
    }

    @Test func theSpectralLocusAndLineOfPurplesMapInsideRec2020() throws {
        let url = Self.root.appendingPathComponent("bake/argent_bake/data/cie_1931_2deg_cmf_380-780_5nm.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        let xyz: [SIMD3<Float>] = try text.split(separator: "\n").dropFirst(2).map { line in
            let values = try line.split(separator: ",").dropFirst().map { try #require(Float($0)) }
            #expect(values.count == 3)
            let sum = values.reduce(0, +)
            return SIMD3(values[0], values[1], values[2]) / sum
        }
        #expect(xyz.count == 81)
        let r = SIMD3<Float>(1.7166511880, -0.3556707838, -0.2533662814)
        let g = SIMD3<Float>(-0.6666843518, 1.6164812366, 0.0157685458)
        let b = SIMD3<Float>(0.0176398574, -0.0427706133, 0.9421031212)
        for index in xyz.indices {
            for step in 0...100 {
                let point = xyz[index] + Float(step) / 100 * (xyz[(index + 1) % xyz.count] - xyz[index])
                let rgb = SIMD3((r * point).sum(), (g * point).sum(), (b * point).sum())
                let mapped = GamutCompression.compress(rgb)
                #expect(mapped.min() >= -1e-6)
                #expect(mapped.max() == rgb.max())
            }
        }
    }
}
