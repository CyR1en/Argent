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
        #expect(baked.negative.values != foundation.negative.values)
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
