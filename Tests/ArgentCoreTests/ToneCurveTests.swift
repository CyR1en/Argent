import Foundation
import Testing
@testable import ArgentCore

@Suite struct ToneCurveTests {
    @Test func validatesPointIntentAtTheBoundary() throws {
        #expect(throws: ToneCurveError.self) { try CurvePoint(input: -1, output: 20) }
        #expect(throws: ToneCurveError.self) { try CurvePoint(input: 1, output: 256) }
        #expect(throws: ToneCurveError.self) { try ChannelCurve(points: [CurvePoint(input: 1, output: 0), CurvePoint(input: 255, output: 255)]) }
        #expect(throws: ToneCurveError.self) {
            try ChannelCurve(points: [CurvePoint(input: 0, output: 0), CurvePoint(input: 128, output: 128),
                                      CurvePoint(input: 128, output: 150), CurvePoint(input: 255, output: 255)])
        }
        #expect(throws: ToneCurveError.self) { try CurveRegions(darks: .nan) }
        #expect(throws: ToneCurveError.self) { try CurveRegions(lights: 101) }
        #expect(try CurveRegions(shadows: -0.0) == .identity)
        let incomplete = Data(#"{"points":[{"input":0,"output":0},{"input":255,"output":255}]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ChannelCurve.self, from: incomplete) }
    }

    @Test func interpolationStaysInsideEachIntervalAndRespectsTheHandles() throws {
        let curves: [ChannelCurve] = [ToneCurves.Preset.softContrast.curve, ToneCurves.Preset.liftedBlacks.curve, ToneCurves.Preset.strongContrast.curve,
            try ChannelCurve(points: [CurvePoint(input: 0, output: 255), CurvePoint(input: 64, output: 90),
                                      CurvePoint(input: 128, output: 170), CurvePoint(input: 255, output: 0)])]
        for curve in curves {
            let compiled = curve.compiled()
            for point in curve.points {
                #expect(abs(compiled.value(at: Float(point.input) / 255) - Float(point.output) / 255) < 0.0002)
            }
            for (a, b) in zip(curve.points, curve.points.dropFirst()) {
                let range = Float(min(a.output, b.output)) / 255 ... Float(max(a.output, b.output)) / 255
                for i in a.input...b.input {
                    let value = compiled.value(at: Float(i) / 255)
                    #expect(value >= range.lowerBound - 0.0002 && value <= range.upperBound + 0.0002)
                }
            }
        }
    }

    @Test func tightlySpacedHandlesRemainOnTheCurrentCompiledCurve() throws {
        for input in [2, 32, 63, 127, 192, 253] {
            for inverted in [false, true] {
                let outside = inverted ? 255 : 0, center = inverted ? 0 : 255
                let curve = try ChannelCurve(points: [CurvePoint(input: 0, output: outside),
                    CurvePoint(input: input - 1, output: outside), CurvePoint(input: input, output: center),
                    CurvePoint(input: input + 1, output: outside), CurvePoint(input: 255, output: outside)])
                let compiled = curve.compiled()
                for point in curve.points {
                    #expect(abs(compiled.value(at: Float(point.input) / 255) - Float(point.output) / 255) < 0.0002)
                }
            }
        }
    }

    @Test func recordedCompilerKeepsItsGridUntilExplicitlyUpdated() throws {
        let curve = try ChannelCurve(points: [CurvePoint(input: 0, output: 0), CurvePoint(input: 31, output: 0),
            CurvePoint(input: 32, output: 255), CurvePoint(input: 33, output: 0), CurvePoint(input: 255, output: 255)])
        let original = try ToneCurves(tone: curve, version: "2026-10-09-curves-1")
        let recorded = try JSONDecoder().decode(ToneCurves.self, from: JSONEncoder().encode(original))
        #expect(recorded == original)
        let legacy = try recorded.compiled().channels[0]
        #expect(legacy.samples.count == 1025)
        #expect(abs(legacy.value(at: Float(32) / 255) * 255 - 244.1247) < 0.001)
        // Continuation uses the recorded table's length, too.
        let overWhite: Float = 1.1
        let recordedEndSlope = (legacy.samples[1024] - legacy.samples[1023]) * 1024
        #expect(legacy.value(at: overWhite) == legacy.samples.last! + (overWhite - 1) * recordedEndSlope)
        #expect(try recorded.setting(.red, to: ToneCurves.Preset.softContrast.curve).version == recorded.version)

        let updated = try recorded.updatingVersion()
        #expect(updated.version == ToneCurves.currentVersion && updated.tone == recorded.tone)
        let current = try updated.compiled().channels[0]
        #expect(current.samples.count == 1021)
        #expect(abs(current.value(at: Float(32) / 255) - 1) < 0.0002)
        #expect(try recorded.setting(.tone, to: .identity) == .identity)
    }

    @Test func knownLegacyIdentityNormalizesWithoutLosingNeutralHandleIntent() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ToneCurves.identity)) as? [String: Any])
        object["version"] = "2026-10-09-curves-1"
        let restored = try JSONDecoder().decode(ToneCurves.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored == .identity)
        #expect(try ManualRenderSettings(adjustments: ManualAdjustments(curves: restored), referenceStops: 2) == .identity)

        let handles = try ChannelCurve(points: [CurvePoint(input: 0, output: 0), CurvePoint(input: 32, output: 32),
            CurvePoint(input: 255, output: 255)])
        let neutralIntent = try ToneCurves(tone: handles, version: "2026-10-09-curves-1")
        #expect(!neutralIntent.isIdentity && !neutralIntent.hasEffect)
        #expect(neutralIntent.version == "2026-10-09-curves-1")
        let rgb = SIMD3<Float>(-0.3, 0.18, 2)
        #expect(try neutralIntent.compiled().applying(to: rgb) == rgb)

        object["version"] = "future-curves"
        let unavailable = try JSONDecoder().decode(ToneCurves.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(unavailable.version == "future-curves")
        #expect(throws: ToneCurveError.self) { try unavailable.compiled() }
        #expect(throws: ToneCurveError.self) { try handles.compiled(version: "future-curves") }
    }

    @Test func regionAdjustmentsComposeWithoutMovingThePointHandles() throws {
        let points = ToneCurves.Preset.softContrast.curve
        let shifted = try points.setting(.shadows, to: 80).setting(.highlights, to: -75)
        #expect(shifted.points == points.points)
        #expect(shifted.compiled().value(at: 0.125) > points.compiled().value(at: 0.125))
        #expect(shifted.compiled().value(at: 0.875) < points.compiled().value(at: 0.875))
        #expect(shifted.compiled().samples.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(shifted.compiled().samples.first == points.compiled().samples.first)
        #expect(shifted.compiled().samples.last == points.compiled().samples.last)
        // Opposing region extrema must not invert a neutral ramp.
        for mask in 0..<16 {
            var curve = ChannelCurve.identity
            for (i, region) in CurveRegion.allCases.enumerated() {
                curve = try curve.setting(region, to: mask & (1 << i) == 0 ? -100 : 100)
            }
            let samples = curve.compiled().samples
            #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    @Test func exactIdentityAndChannelIsolationSurviveSignedAndOverWhiteInputs() throws {
        let identity = try ToneCurves.identity.compiled()
        let red = try ToneCurves(red: ToneCurves.Preset.liftedBlacks.curve).compiled()
        let tone = try ToneCurves(tone: ToneCurves.Preset.liftedBlacks.curve).compiled()
        let pixels: [SIMD3<Float>] = [.zero, SIMD3(-0.1, 0.3, 1.4), SIMD3(1e-9, -1e-9, 0), SIMD3(repeating: 65504)]
        for rgb in pixels {
            #expect(identity.applying(to: rgb) == rgb)
            let changed = red.applying(to: rgb)
            #expect(changed.y == rgb.y && changed.z == rgb.z)
            #expect([changed.x,changed.y,changed.z].allSatisfy { $0.isFinite })
            let mapped = tone.applying(to: rgb)
            #expect([mapped.x,mapped.y,mapped.z].allSatisfy { $0.isFinite })
        }
        let black = tone.applying(to: .zero)
        #expect(black.x > 0 && black.x == black.y && black.y == black.z)
        let extraHandle = try ChannelCurve(points: [CurvePoint(input: 0, output: 0), CurvePoint(input: 128, output: 128), CurvePoint(input: 255, output: 255)])
        #expect(!extraHandle.isIdentity && !extraHandle.hasEffect)
        #expect(extraHandle.compiled().value(at: -0.7) == -0.7)
    }

    @Test func legacySlidersDecodeWithIdentityCurvesAndFutureCurvesKeepTheirIntent() throws {
        let original = try ManualAdjustments(exposureEV: 0.85, highlights: -35)
        let json = try JSONEncoder().encode(original)
        #expect(!String(decoding: json, as: UTF8.self).contains("curves"))
        #expect(try JSONDecoder().decode(ManualAdjustments.self, from: json).curves == .identity)
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(curves)) as? [String: Any])
        object["version"] = "future-curves"
        let restored = try JSONDecoder().decode(ToneCurves.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.tone == curves.tone)
        #expect(throws: ToneCurveError.self) { try restored.compiled() }
        #expect(try restored.updatingVersion() == curves)
    }
}
