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

    /// V3's six fitted strengths stay in `2026-11-11-1` and `2026-11-23-1` (validate/colour/report.md, section 3.1); `2026-11-23-1`
    /// adds the eight newer stocks' rule-derived strengths (test-baselines-20261123.noindex/vibrance/current-bake-chroma-ratios.json),
    /// while `2026-11-11-1` leaves them at the default 1 and 1 so recipes saved on it render the same.
    @Test func vibrancesStrengthIsMeasuredPerStockAndSign() throws {
        let current = try #require(PresenceConstants.named(Presence.currentVersion)).vibrance
        let expected: [String: PresenceConstants.Vibrance.Strength] = [
            "cinestill-800t": .init(positive: 1.16, negative: 1.40),
            "fujifilm-c200": .init(positive: 1.29, negative: 1.53),
            "fujifilm-pro-400h": .init(positive: 1.28, negative: 1.52),
            "fujifilm-superia-400": .init(positive: 1.32, negative: 1.55),
            "kodak-colorplus-200": .init(positive: 1.65, negative: 1.89),
            "kodak-ektar-100": .init(positive: 1.77, negative: 2),
            "kodak-gold-200": .init(positive: 1.74, negative: 1.96),
            "kodak-portra-160": .init(positive: 1.41, negative: 1.61),
            "kodak-portra-160-natural": .init(positive: 1.30, negative: 1.54),
            "kodak-portra-400": .init(positive: 1.45, negative: 1.72),
            "kodak-portra-800": .init(positive: 1.46, negative: 1.74),
            "kodak-ultramax-400": .init(positive: 1.64, negative: 1.92),
            "kodak-vision3-500t": .init(positive: 1.10, negative: 1.33),
            "kodak-vision3-500t-cinema": .init(positive: 0.99, negative: 1.22),
        ]
        #expect(current.strengths.count == 14)
        for (stockID, strength) in expected {
            #expect(current.strength(for: stockID) == strength, "\(stockID)")
        }
        #expect(current.strength(for: LightCompilerBaselineTests.toyStock().id) == .init(positive: 1, negative: 1))
        for url in LightCompilerBaselineTests.bakedStocks {
            let stock = try Stock.load(from: url)
            #expect(current.strengths[stock.id] != nil, "\(stock.id) needs a strength: method.json's rule gives one from its chroma ratio")
        }

        let legacy = try #require(PresenceConstants.named("2026-11-11-1")).vibrance
        #expect(legacy.strengths.count == 6)
        for stockID in expected.keys where legacy.strengths[stockID] == nil {
            #expect(legacy.strength(for: stockID) == .init(positive: 1, negative: 1), "2026-11-11-1 keeps default strength for \(stockID)")
        }
    }

    @Test func theStrengthRuleGivesEachListedStrength() throws {
        let legacyStocks = Set(try #require(PresenceConstants.named("2026-11-11-1")).vibrance.strengths.keys)
        let twoDecimals = 0.005
        for constants in PresenceConstants.all {
            let method = Self.root.appendingPathComponent("scripts/presence/\(constants.version)/method.json")
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: method)) as? [String: Any])
            let strength = try #require((json["vibrance"] as? [String: Any])?["strength"] as? [String: Any])
            let rule = try #require(strength["rule"] as? [String: Any]), ratios = try #require(rule["chromaRatio"] as? [String: Double])
            let vibrance = constants.vibrance
            #expect(Set(ratios.keys) == Set(vibrance.strengths.keys), "\(constants.version)")
            for (sign, read) in [("positive", \PresenceConstants.Vibrance.Strength.positive), ("negative", \.negative)] {
                let fit = try #require(rule[sign] as? [String: Double])
                let slope = try #require(fit["slope"]), intercept = try #require(fit["intercept"]), worst = try #require(fit["leaveOneOutMax"])
                for (stock, c) in ratios {
                    let listed = Double(try #require(vibrance.strengths[stock])[keyPath: read])
                    let limit = legacyStocks.contains(stock) ? worst + twoDecimals : twoDecimals
                    #expect(abs(slope * c + intercept - listed) <= limit, "\(constants.version) \(stock) \(sign)")
                }
            }
        }
    }

    /// A frame saved under `2026-11-11-1` renders Vibrance on a newer stock with default strength 1 and 1, while a frame under
    /// `2026-11-23-1` renders it with that stock's measured strength.
    @Test func printParametersKeepLegacyDefaultStrengthOnNewerStocks() throws {
        let legacy = try #require(PresenceConstants.named("2026-11-11-1"))
        let current = try #require(PresenceConstants.named("2026-11-23-1"))
        let toy = LightCompilerBaselineTests.toyStock().id
        for stockID in ["kodak-colorplus-200", "fujifilm-pro-400h", "kodak-vision3-500t-cinema"] {
            let legacyPos = try PresencePrint.parameters(try Presence([.vibrance: 50], version: legacy.version), constants: legacy, stockID: stockID)
            let toyPos = try PresencePrint.parameters(try Presence([.vibrance: 50], version: legacy.version), constants: legacy, stockID: toy)
            let currentPos = try PresencePrint.parameters(try Presence([.vibrance: 50], version: current.version), constants: current, stockID: stockID)
            #expect(legacyPos.gainAmplitude == toyPos.gainAmplitude, "\(stockID) +50 under 2026-11-11-1")
            let expectedPos = toyPos.gainAmplitude * current.vibrance.strength(for: stockID).positive
            #expect(abs(currentPos.gainAmplitude - expectedPos) <= 1e-6, "\(stockID) +50 under 2026-11-23-1")

            let legacyNeg = try PresencePrint.parameters(try Presence([.vibrance: -50], version: legacy.version), constants: legacy, stockID: stockID)
            let toyNeg = try PresencePrint.parameters(try Presence([.vibrance: -50], version: legacy.version), constants: legacy, stockID: toy)
            let currentNeg = try PresencePrint.parameters(try Presence([.vibrance: -50], version: current.version), constants: current, stockID: stockID)
            #expect(legacyNeg.keep == toyNeg.keep, "\(stockID) -50 under 2026-11-11-1")
            let expectedNeg = toyNeg.keep / current.vibrance.strength(for: stockID).negative
            #expect(abs(currentNeg.keep - expectedNeg) <= 1e-6, "\(stockID) -50 under 2026-11-23-1")
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
