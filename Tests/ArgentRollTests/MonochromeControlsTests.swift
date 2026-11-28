import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

@Suite struct MonochromeControlsTests {
    @Test func persistedSilverControlsRequireVersion15() throws {
        let stock = try #require(MonochromeFilm.stocks.first)
        let frame = Frame(id: 0, url: URL(fileURLWithPath: "/tmp/frame.ARW"), info: ARWFrameInfo())
        func recipe(roll: RollControls = RollControls(), own: FrameControls = FrameControls()) -> Recipe {
            Recipe(frame: frame, byteCount: 1, stock: stock, stockDigest: stock.digest, roll: roll, own: own)
        }
        let plain = recipe()
        #expect(try Recipe.decodeStrict(plain.encoded(), readerVersion: 14) == plain)
        for var record in [recipe(roll: RollControls(monochromeFilter: .red)),
                           recipe(own: FrameControls(paperGrade: .hard)),
                           recipe(own: FrameControls(monochromeFilter: MonochromeFilter.none, paperGrade: .normal))] {
            #expect(record.version == 15)
            #expect(try Recipe.decodeStrict(record.encoded()) == record)
            #expect(throws: Recipe.ReadFailure.unsupportedVersion(15)) {
                try Recipe.decodeStrict(record.encoded(), readerVersion: 14)
            }
            record.version = 14
            #expect(throws: Recipe.ReadFailure.invalid("monochrome controls require recipe version 15")) {
                try record.validate()
            }
        }
    }

    @Test func controlsInheritIndividuallyAndRecipesKeepEffectiveSettings() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(RollControls.self, from: Data(#"{"ratedAt":0,"labBalance":"auto"}"#.utf8))
        #expect(legacy.monochromeFilter == nil && legacy.paperGrade == nil)
        let stock = try #require(MonochromeFilm.stocks.first)
        let roll = RollControls(monochromeFilter: .orange, paperGrade: .hard)
        let own = FrameControls(monochromeFilter: MonochromeFilter.none)
        let roundTripped = try decoder.decode(FrameControls.self, from: JSONEncoder().encode(own))
        #expect(!roundTripped.isEmpty)
        let settings = roundTripped.applied(to: roll).settings(for: stock)
        #expect(settings.monochromeFilter == .none)
        #expect(settings.paperGrade == .hard)

        let render = Recipe.Render(settings: roll.settings(for: stock), grain: .off)
        let restored = try decoder.decode(Recipe.Render.self, from: JSONEncoder().encode(render))
        #expect(restored.settings.monochromeFilter == .orange)
        #expect(restored.settings.paperGrade == .hard)
        #expect(restored != Recipe.Render(settings: settings, grain: .off))
        let legacyRender = try decoder.decode(Recipe.Render.self,
            from: Data(#"{"labBalance":[0,0,0],"printExposure":0,"grain":"off","halation":"off"}"#.utf8))
        #expect(legacyRender.settings.monochromeFilter == .none)
        #expect(legacyRender.settings.paperGrade == .normal)
    }

    @Test func monochromeStocksAppendWithoutChangingExistingStock() throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "kodak-portra-400", in: directory)
        let baked = try #require(StockLibrary.load(from: directory).stocks.first)
        let app = StockLibrary.load(from: directory, includeMonochrome: true).stocks
        #expect(app.map(\.id) == ["kodak-portra-400", "kodak-tri-x-400", "ilford-hp5-plus"])
        #expect(app.first?.digest == baked.digest)
        #expect(app.first?.monochrome == nil)
        let roll = RollControls(monochromeFilter: .red, paperGrade: .hard)
        #expect(roll.settings(for: baked) == RollControls().settings(for: baked))
    }
}
