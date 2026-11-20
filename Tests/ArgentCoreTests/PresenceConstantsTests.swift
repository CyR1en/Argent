import Foundation
import Testing
@testable import ArgentCore

/// The constants are data with a version: written by `scripts/presence/emit_constants.py` from the inputs in Git, read as the fit
/// scripts read them.
@Suite struct PresenceConstantsTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The generator's output for `version`, from the repository's `.venv` where there is one and the system's python3 otherwise: it
    /// needs no package, and both give the same bytes.
    private static func generated(_ version: String) throws -> String {
        let venv = root.appendingPathComponent(".venv/bin/python")
        let process = Process()
        process.executableURL = FileManager.default.isExecutableFile(atPath: venv.path) ? venv : URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", root.appendingPathComponent("scripts/presence/emit_constants.py").path, version]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: failure, as: UTF8.self))")
        return String(decoding: data, as: UTF8.self)
    }

    @Test func rerunningTheGeneratorReproducesEveryCommittedVersion() throws {
        for constants in PresenceConstants.all {
            let file = Self.root.appendingPathComponent("Sources/ArgentCore/Film/PresenceConstants+\(constants.version).swift")
            let committed = try String(contentsOf: file, encoding: .utf8)
            #expect(try Self.generated(constants.version) == committed, "\(constants.version): run emit_constants.py again")
        }
    }

    private static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return max(abs(d.x), abs(d.y), abs(d.z))
    }

    @Test func everyVersionIsWellFormed() {
        #expect(PresenceConstants.named(Presence.currentVersion) != nil)
        #expect(Set(PresenceConstants.all.map(\.version)).count == PresenceConstants.all.count)
        for c in PresenceConstants.all {
            let laws = [c.clarity.positive.strength, c.clarity.negative.strength, c.texture.positive.strength, c.texture.negative.strength,
                        c.dehaze.kappa, c.dehaze.hazeShare, c.dehaze.hazePower]
            for law in laws {
                #expect(law.magnitudes.first == 0 && law.magnitudes.last == 100 && law.magnitudes.count == law.values.count)
                #expect(zip(law.magnitudes, law.magnitudes.dropFirst()).allSatisfy { $0 < $1 })
            }
            for side in [c.clarity.positive, c.clarity.negative, c.texture.positive, c.texture.negative] {
                #expect(side.weight.values.count == PresenceConstants.ToneWeight.lightness.count && side.strength.at(0) == 0)
            }
            #expect(c.clarity.positive.strength.at(100) > 0 && c.clarity.negative.strength.at(-100) < 0)
            #expect(c.dehaze.kappa.at(0) == 0 && c.dehaze.hazeShare.at(0) == 0)
            #expect((0.0001...1).contains(c.dehaze.minimumTransmission) && c.detailLimitStops > 0)
            let v = c.vibrance
            for x in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0.2, 0.5, 0.9)] {
                let back = v.fromProPhoto.applied(to: v.toProPhoto.applied(to: x))
                #expect(Self.distance(back, x) < 1e-6)
            }
            // Oklab's M1 is scaled so a grey has no hue: ProPhoto's white reaches LMS (1, 1, 1).
            #expect(Self.distance(v.proPhotoToLMS.applied(to: SIMD3(1, 1, 1)), SIMD3(1, 1, 1)) < 1e-6)
            #expect(v.strength(for: "kodak-portra-400") == v.strengths["kodak-portra-400"] ?? v.defaultStrength)
        }
    }

    /// `np.interp` on `|v|`: the knots themselves, a straight line between, the ends held.
    @Test func lawsReadAsTheFitScriptsInterpolate() throws {
        let c = try #require(PresenceConstants.named("2026-11-11-1"))
        let positive = c.clarity.positive.strength, negative = c.clarity.negative.strength
        #expect(positive.at(25) == 0.1744 && positive.at(100) == 0.7077 && positive.at(0) == 0)
        #expect(abs(positive.at(37.5) - (0.1744 + 0.3739) / 2) < 1e-6)
        #expect(abs(positive.at(10) - 0.1744 * 0.4) < 1e-6)
        #expect(negative.at(-50) == -0.3987 && negative.at(50) == -0.3987)
        #expect(c.dehaze.hazePower.at(0) == c.dehaze.hazePower.values[0] && c.dehaze.hazePower.at(5) == c.dehaze.hazePower.values[0])
        #expect(c.dehaze.kappa.at(150) == c.dehaze.kappa.values.last)
        let weight = c.clarity.positive.weight
        #expect(weight.at(lightness: 50) == weight.values[5] && weight.at(lightness: -5) == weight.values[0])
        #expect(weight.at(lightness: 120) == weight.values[10])
        #expect(abs(weight.at(lightness: 45) - (weight.values[4] + weight.values[5]) / 2) < 1e-6)
    }

    /// V3's strengths (validate/colour/report.md, section 3.1).
    @Test func vibrancesStrengthIsMeasuredPerStockAndSign() throws {
        let vibrance = try #require(PresenceConstants.named("2026-11-11-1")).vibrance
        #expect(vibrance.strength(for: "kodak-portra-400") == .init(positive: 1.45, negative: 1.72))
        #expect(vibrance.strength(for: "kodak-ektar-100") == .init(positive: 1.77, negative: 2))
        #expect(vibrance.strength(for: LightCompilerBaselineTests.toyStock().id) == .init(positive: 1, negative: 1))
        #expect(vibrance.strengths.count == 6)
        for url in LightCompilerBaselineTests.bakedStocks {
            let stock = try Stock.load(from: url)
            #expect(vibrance.strengths[stock.id] != nil, "\(stock.id) needs a strength: method.json's rule gives one from its chroma ratio")
        }
    }

    @Test func theStrengthRuleGivesEachListedStrength() throws {
        let method = Self.root.appendingPathComponent("scripts/presence/2026-11-11-1/method.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: method)) as? [String: Any])
        let strength = try #require((json["vibrance"] as? [String: Any])?["strength"] as? [String: Any])
        let rule = try #require(strength["rule"] as? [String: Any]), ratios = try #require(rule["chromaRatio"] as? [String: Double])
        let vibrance = try #require(PresenceConstants.named("2026-11-11-1")).vibrance, twoDecimals = 0.005
        #expect(Set(ratios.keys) == Set(vibrance.strengths.keys))
        for (sign, read) in [("positive", \PresenceConstants.Vibrance.Strength.positive), ("negative", \.negative)] {
            let fit = try #require(rule[sign] as? [String: Double])
            let slope = try #require(fit["slope"]), intercept = try #require(fit["intercept"]), worst = try #require(fit["leaveOneOutMax"])
            for (stock, c) in ratios {
                let listed = Double(try #require(vibrance.strengths[stock])[keyPath: read])
                #expect(abs(slope * c + intercept - listed) <= worst + twoDecimals, "\(stock) \(sign)")
            }
        }
    }

    /// The band's field follows the fit's `texture_band`: half the full-size frame, capped at the decode, the radius in full-size
    /// pixels.
    @Test func texturesFieldFollowsTheDecode() throws {
        let texture = try #require(PresenceConstants.named("2026-11-11-1")).texture
        let cases: [(decode: Int, field: Int, radius: Int)] = [(7008, 3504, 10), (4912, 3504, 10), (2190, 2190, 6), (960, 960, 3)]
        for item in cases {
            let field = texture.field(decodeLongSide: item.decode, fullLongSide: 7008)
            #expect(field.fieldLongSide == item.field && field.radius(fieldLong: field.fieldLongSide) == item.radius, "\(item.decode)")
            #expect(field.epsilon == 0.25 && field.coefficientRadiusShare == 0.5)
        }
        #expect(texture.field(decodeLongSide: 20, fullLongSide: 24).fieldLongSide == 16)
    }
}
