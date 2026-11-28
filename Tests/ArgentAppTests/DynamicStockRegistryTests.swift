import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct DynamicStockRegistryTests {
    private static func makeCustomStock(id: String, displayName: String, boxSpeed: Float = 400,
                                        characterLine: String? = nil) -> Stock {
        Stock(
            id: id,
            displayName: displayName,
            status: "custom",
            boxSpeed: boxSpeed,
            densityRange: 3.0,
            exposurePerUnit: SIMD3<Float>(repeating: 1),
            negative: LUT3D.identity(size: 5),
            print: LUT3D.identity(size: 5),
            origin: .userBuilt,
            characterLine: characterLine
        )
    }

    private static func makeModel(fixture: AutoDecisionStateTests.Fixture, userStocks: URL) -> RollModel {
        let model = RollModel(
            bookmarks: BookmarkStore(file: fixture.folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
            stocksDirectory: fixture.stocks,
            userStocksDirectory: userStocks,
            decisions: AutoDecisionStore(library: fixture.library),
            flagStore: FlagStore(library: fixture.library),
            recipeLibrary: fixture.library,
            previewCache: fixture.folder.appendingPathComponent("Linear Previews"),
            digestsFile: nil
        )
        fixture.made.models.append(model)
        return model
    }

    @Test func reloadUserStocksPicksUpAddedUpdatedAndDeletedStocks() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("argent-neutral", in: fixture.stocks)
            let userStocks = fixture.folder.appendingPathComponent("UserStocks", isDirectory: true)
            let store = UserStockStore(folder: userStocks)
            let model = Self.makeModel(fixture: fixture, userStocks: userStocks)
            await model.open(fixture.roll)
            let initialCount = model.stockNames.count
            let initialVersion = model.stockVersion

            // Save a new user stock and reload.
            let v1 = Self.makeCustomStock(id: "user-amber", displayName: "Amber 400", boxSpeed: 400,
                                          characterLine: "warm amber tones")
            try store.save(v1, specData: Data("{}".utf8))
            model.reloadUserStocks()

            #expect(model.stockNames.count == initialCount + 1)
            #expect(model.stockVersion == initialVersion + 1)
            let amberIndex = try #require(model.films?.stocks.firstIndex(where: { $0.id == "user-amber" }))
            model.selectStock(amberIndex)
            #expect(model.currentStock?.id == "user-amber")
            #expect(StockCharacter.line(for: model.currentStock) == "warm amber tones")
            let digestV1 = model.stockDigests[amberIndex]

            // Edit the user stock in place: digest changes, selection stays on user-amber.
            let v2 = Self.makeCustomStock(id: "user-amber", displayName: "Amber 800", boxSpeed: 800)
            try store.save(v2, specData: Data("{}".utf8))
            model.reloadUserStocks()

            let updatedIndex = try #require(model.films?.stocks.firstIndex(where: { $0.id == "user-amber" }))
            #expect(model.stockIndex == updatedIndex)
            #expect(model.currentStock?.displayName == "Amber 800")
            #expect(model.stockDigests[updatedIndex] != digestV1)
            #expect(model.missingRollStockID == nil)

            // Delete the selected user stock: falls back cleanly to argent-neutral and records missingRollStockID.
            try store.delete(id: "user-amber")
            model.reloadUserStocks()

            #expect(model.currentStock?.id == "argent-neutral")
            #expect(model.missingRollStockID == "user-amber")
            #expect(model.missingRollStockName == "Amber 800")
            #expect(model.missingRollStockReason != nil)
            #expect(model.missingStockNotice != nil)

            // Reinstalling the deleted stock restores it automatically and clears the warning.
            try store.save(v2, specData: Data("{}".utf8))
            model.reloadUserStocks()

            #expect(model.currentStock?.id == "user-amber")
            #expect(model.missingRollStockID == nil)
            #expect(model.missingStockNotice == nil)
        }
    }

    @Test func missingRollStockFallsBackNonDestructivelyAndClearsOnManualSelection() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("argent-neutral", in: fixture.stocks)
            let userStocks = fixture.folder.appendingPathComponent("UserStocks", isDirectory: true)
            let store = UserStockStore(folder: userStocks)
            let custom = Self.makeCustomStock(id: "user-velvet", displayName: "Velvet 200")
            try store.save(custom)

            // Open roll, select custom stock, and save a recipe referencing user-velvet.
            let model = Self.makeModel(fixture: fixture, userStocks: userStocks)
            let gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            let velvetIndex = try #require(model.films?.stocks.firstIndex(where: { $0.id == "user-velvet" }))
            model.selectStock(velvetIndex)
            let firstFrame = try #require(model.roll?.frames.first)
            model.setRatedAt(.oneStopOver, for: firstFrame)
            try await model.flushManualSaves()
            AutoDecisionStateTests.close(model, gate)

            // Remove the custom stock before reopening the roll.
            try store.delete(id: "user-velvet")
            let reopened = Self.makeModel(fixture: fixture, userStocks: userStocks)
            let again = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: reopened, through: again)
            defer { AutoDecisionStateTests.close(reopened, again) }

            #expect(reopened.missingRollStockID == "user-velvet")
            #expect(reopened.missingRollStockName == "Velvet 200")
            #expect(reopened.currentStock?.id == "argent-neutral")
            #expect(reopened.missingStockReasons.count == 1)
            #expect(reopened.missingStockNotice?.contains("Velvet 200") == true)

            // Choosing a stock explicitly clears the missing-stock state.
            let neutralIndex = try #require(reopened.films?.stocks.firstIndex(where: { $0.id == "argent-neutral" }))
            reopened.selectStock(neutralIndex)
            #expect(reopened.missingRollStockID == nil)
            #expect(reopened.missingStockNotice == nil)
        }
    }
}
