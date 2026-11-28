import Foundation
import Testing
@testable import ArgentCore

@Suite struct CustomStockCompilerTests {
    private func compile(_ spec: CustomStockSpec, base: Stock? = nil, size: Int = 17) throws -> Stock {
        try CustomStockCompiler.compile(spec, id: "user-test", name: "Test", base: base, size: size)
    }

    @Test func analyticalBasesAnchorDaylightGrayAndRiseMonotonically() throws {
        for base in [CustomStockSpec.Base.neutral, .monochrome] {
            var spec = CustomStockSpec(base: base)
            spec.contrast = 1.4
            spec.shadowToe = 0.35
            spec.highlightShoulder = 0.25
            let stock = try compile(spec, size: CustomStockCompiler.saveSize)
            var prior: Float = 0
            for i in 0...128 {
                let input = SIMD3<Float>(repeating: Float(i) / 128)
                let print = stock.print.sample(encoded: stock.negative.sample(encoded: input))
                #expect(print.x + 1e-6 >= prior)
                #expect(abs(print.x - print.y) < 1e-5)
                #expect(abs(print.y - print.z) < 1e-5)
                prior = print.x
            }
            let gray = stock.negativeAmounts(exposed: SIMD3(repeating: 0.18), filter: .none)
            #expect(abs(stock.print.sample(encoded: gray).x - 0.18) < 0.01)
        }
    }

    @Test func numericalCalibrationRetainsNeutralLogExposureSlope() throws {
        let stock = try compile(.init(), size: CustomStockCompiler.saveSize)
        let gray = stock.negativeAmounts(exposed: SIMD3(repeating: 0.18), filter: .none)
        let units = DevelopSettings.printUnits(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        let step: Float = 0.016
        let delta = (stock.print.sample(encoded: gray + units * step).x
                     - stock.print.sample(encoded: gray - units * step).x) / (2 * step)
        let direct = (CubeImporter.neutralDisplay(SIMD3(repeating: 0.18 * exp2(step))).x
                      - CubeImporter.neutralDisplay(SIMD3(repeating: 0.18 * exp2(-step))).x) / (2 * step)
        #expect(abs(delta - direct) < 0.015)
        #expect(stock.exposurePerUnit.indices.allSatisfy { stock.exposurePerUnit[$0] > 0 && stock.exposurePerUnit[$0].isFinite })
    }

    @Test func derivedStockPreservesFoundationAndSixHueKeepsGrayClean() throws {
        let base = Stock(id: "fixture", displayName: "Fixture", status: "test", boxSpeed: 200, densityRange: 2,
                         exposurePerUnit: SIMD3(0.7, 0.9, 1.1), negative: .identity(size: 17), print: .identity(size: 17))
        var spec = CustomStockSpec(derivedFrom: base)
        let original = try compile(spec, base: base)
        #expect(original.negative.values == base.negative.values)
        #expect(original.print.values == base.print.values)
        #expect(original.exposurePerUnit == base.exposurePerUnit)
        spec.colorShift[.red] = .init(hue: 40, saturation: -0.3)
        let shifted = try compile(spec, base: base)
        let gray = SIMD3<Float>(repeating: 0.5)
        let red = SIMD3<Float>(0.7, 0.15, 0.12)
        #expect((shifted.print.sample(encoded: gray) - gray).indices.allSatisfy {
            abs(shifted.print.sample(encoded: gray)[$0] - gray[$0]) < 0.0001
        })
        #expect(abs(shifted.print.sample(encoded: red).y - original.print.sample(encoded: red).y) > 0.01)
        #expect(throws: StockError.self) { try compile(spec) }
    }

    @Test func recipeRoundTripAndPhysicalProfilesValidate() throws {
        var spec = CustomStockSpec(base: .monochrome)
        spec.splitTone.shadows.hue = 215
        spec.splitTone.shadows.strength = 0.4
        spec.monochromeMixer = SIMD3(0.3, 0.5, 0.2)
        spec.paperTone = SIMD3(1.04, 1, 0.96)
        spec.grain = .init(preset: .monochrome, strength: 1.4, shadowBias: 0.3)
        spec.halation.enabled = true
        spec.halation.strength = 0.06
        let decoded = try JSONDecoder().decode(CustomStockSpec.self, from: JSONEncoder().encode(spec))
        #expect(decoded == spec)
        let stock = try compile(decoded)
        let grain = try #require(stock.grain)
        #expect(grain.amounts.count == grain.sigma48.count)
        #expect(grain.sigma48.allSatisfy { $0.count == 3 && $0.allSatisfy { $0 > 0 && $0.isFinite } })
        #expect(stock.monochromeGrain)
        #expect(stock.halation?.strength == 0.06)
        spec.halation.radiusMicrometres = 351
        #expect(throws: StockError.self) { try compile(spec) }
        spec.halation.radiusMicrometres = 150
        spec.grain.strength = -.infinity
        #expect(throws: StockError.self) { try compile(spec) }
    }

    @Test func derivedAndBakedHalationPreserveStrongSourceProfiles() throws {
        let profile = Stock.Halation(strength: 0.14, greenShare: 0.06, radiusMicrometres: 270)
        let base = Stock(id: "cinestill800t", displayName: "CineStill 800T", status: "test", boxSpeed: 800,
                         densityRange: 2, exposurePerUnit: SIMD3(repeating: 1), negative: .identity(size: 2),
                         print: .identity(size: 2), halation: profile)
        let derived = try compile(.init(derivedFrom: base), base: base)
        #expect(derived.halation == profile)
        for amount: Float in [1, 2] {
            let spec = try CustomStockSpec(baking: base, settings: .init(halation: true, halationAmount: amount))
            let baked = try compile(spec, base: base)
            #expect(baked.halation?.strength == profile.strength * amount)
            #expect(baked.halation?.greenShare == profile.greenShare)
            #expect(baked.halation?.radiusMicrometres == profile.radiusMicrometres)
        }
    }

    @Test func bakedExposureMovesTheInputDomainInBothDirections() throws {
        let foundation = try compile(.init())
        let encoding = foundation.negative.encoding
        for (ev, input) in [(Float(2), encoding.decode(0) * 0.5), (-2, encoding.decode(1) * 2)] {
            let edit = try ManualAdjustments(exposureEV: ev)
            let manual = try ManualRenderSettings(adjustments: edit, referenceStops: 0)
            let spec = try CustomStockSpec(baking: foundation, settings: .init(manual: manual))
            let baked = try compile(spec, base: foundation)
            let expected = foundation.negativeAmounts(exposed: SIMD3(repeating: input * exp2(ev)), filter: .none)
            let actual = baked.negativeAmounts(exposed: SIMD3(repeating: input), filter: .none)
            #expect(abs(actual.x - expected.x) < 1e-5)
        }
    }

    @Test func bakedSilverExposureDoesNotClipBrightChannelsBeforeMixing() throws {
        let base = try #require(MonochromeFilm.stocks.first)
        let edit = try ManualRenderSettings(adjustments: .init(exposureEV: 2), referenceStops: 0)
        let spec = try CustomStockSpec(baking: base, settings: .init(manual: edit, monochromeFilter: .yellow))
        let oldCeiling = base.negative.encoding.decode(1) / 4
        let brightBlue = SIMD3<Float>(0, 0, 20)
        let expected = base.negativeAmounts(exposed: brightBlue * 4, filter: .yellow).x
        let prematurelyClipped = base.negativeAmounts(exposed: SIMD3(0, 0, oldCeiling * 4), filter: .yellow).x
        #expect(expected > prematurelyClipped + 0.05)

        let baked = try compile(spec, base: base, size: CustomStockCompiler.saveSize)
        #expect(abs(baked.negativeAmounts(exposed: brightBlue, filter: .none).x - expected) < 0.005)
    }

    @Test func mixerDefaultsMatchTheDerivedFilmAndBakedFilter() throws {
        let base = try #require(MonochromeFilm.stocks.first)
        let film = try #require(base.monochrome)
        let derived = CustomStockSpec(derivedFrom: base)
        #expect(derived.defaultMonochromeMixer(inheriting: base) == film.weights(for: .none))

        let spec = try CustomStockSpec(baking: base, settings: .init(monochromeFilter: .red))
        var mix = try #require(spec.defaultMonochromeMixer(inheriting: base))
        #expect(mix == SIMD3(1, 0, 0))
        mix.x = 0.8
        var edited = spec
        edited.monochromeMixer = mix
        let input = SIMD3<Float>(0.3, 0.1, 0.7)
        let before = try compile(spec, base: base).negativeAmounts(exposed: input, filter: .none)
        let after = try compile(edited, base: base).negativeAmounts(exposed: input, filter: .none)
        #expect(before == after)
    }

    @Test func bakedSilverCurvesChangeLuminanceWithoutTintingThePaper() throws {
        let base = try #require(MonochromeFilm.stocks.first)
        let red = try ChannelCurve(points: [
            CurvePoint(input: 0, output: 0), CurvePoint(input: 128, output: 192), CurvePoint(input: 255, output: 255),
        ])
        let manual = try ManualRenderSettings(adjustments: .init(curves: ToneCurves(red: red)), referenceStops: 0)
        var spec = try CustomStockSpec(baking: base, settings: .init(manual: manual))
        let gray = SIMD3<Float>(repeating: 0.5)
        let unedited = base.print.sample(encoded: gray)
        let curved = try manual.applyingPrint(to: unedited)
        let expected = (curved * SIMD3<Float>(0.2627, 0.6780, 0.0593)).sum()
        let baked = try compile(spec, base: base).print.sample(encoded: gray)
        #expect(baked == SIMD3(repeating: expected))
        #expect(baked.x > unedited.x)

        spec.paperTone = SIMD3(1.1, 1, 0.9)
        let toned = try compile(spec, base: base).print.sample(encoded: gray)
        #expect(toned.x > toned.y && toned.y > toned.z)
    }

    @Test func bakedNeutralCarriesTheCombinedAutoAndManualPresence() throws {
        let base = Stock(id: "neutral", displayName: "Neutral", status: "test", boxSpeed: 400,
                         densityRange: 2, exposurePerUnit: SIMD3(repeating: 1), negative: .identity(size: 2),
                         print: .identity(size: 2))
        let polish = try Presence([.clarity: 8, .vibrance: 12])
        let color = SIMD3<Float>(0.625, 0.3125, 0.1875)
        for edit: Float in [0, 5] {
            let presence = try Presence([.clarity: edit, .vibrance: edit])
            let manual = try ManualRenderSettings(adjustments: .init(presence: presence), referenceStops: 0.5)
            let settings = DevelopSettings(manual: manual, autoPresence: .init(presence: polish, referenceStops: 0.25))
            let recipe = try CustomStockSpec(baking: base, settings: settings)
            let spec = try JSONDecoder().decode(CustomStockSpec.self, from: JSONEncoder().encode(recipe))
            let baked = try compile(spec, base: base)
            #expect(baked.scenePresence?.clarity == 8 + edit)
            #expect(baked.scenePresenceReference == (edit == 0 ? 0.25 : 0.5))
            #expect(baked.scenePresence?.vibrance == 0)
            let parameters = try PresencePrint.parameters(settings.effectivePresence,
                                                          constants: PresenceConstants.required(presence.version), stockID: base.id)
            let expected = PresencePrint.applying(to: color, parameters: parameters)
            #expect(expected != color)
            #expect(baked.print.sample(encoded: color) == expected)
        }
    }

    @Test func bakeCarriesLightCurvesPresenceAndFilmSettings() throws {
        let foundation = try compile(.init())
        let curves = try ToneCurves(tone: ChannelCurve(points: [
            CurvePoint(input: 0, output: 0), CurvePoint(input: 128, output: 146), CurvePoint(input: 255, output: 255),
        ]))
        let presence = try Presence([.clarity: 16, .saturation: -20])
        let edits = try ManualAdjustments(exposureEV: 0.5, curves: curves, presence: presence)
        let settings = DevelopSettings(grain: 0, halation: false, manual: try .init(adjustments: edits, referenceStops: 0.25))
        let spec = try CustomStockSpec(baking: foundation, settings: settings)
        let baked = try compile(spec, base: foundation)
        #expect(spec.toneCurve == curves)
        let gray = SIMD3<Float>(repeating: 0.18)
        #expect(baked.negativeAmounts(exposed: gray, filter: .none) != foundation.negativeAmounts(exposed: gray, filter: .none))
        #expect(baked.print.values != foundation.print.values)
        #expect(baked.scenePresence?.clarity == 16)
        #expect(baked.scenePresence?.saturation == 0)
        #expect(baked.scenePresenceReference == 0.25)
        #expect(baked.halation == nil)
        #expect(baked.grain == nil)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try baked.write(to: folder)
        let loaded = try Stock.load(from: folder, origin: .userBuilt)
        #expect(loaded.scenePresence == baked.scenePresence)
        #expect(loaded.scenePresenceReference == baked.scenePresenceReference)
    }
}
