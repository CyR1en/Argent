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
            digestsFile: nil,
            presetStore: PresetStore(folder: fixture.folder.appendingPathComponent("Presets", isDirectory: true))
        )
        fixture.made.models.append(model)
        return model
    }

    @Test func builderBakesFrameAndReopensSavedSpec() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("argent-neutral", in: fixture.stocks)
            let userStocks = fixture.folder.appendingPathComponent("UserStocks", isDirectory: true)
            let model = Self.makeModel(fixture: fixture, userStocks: userStocks)
            await model.open(fixture.roll)
            let frame = try #require(model.roll?.frames.first)
            model.manualLoaded.insert(frame.url)
            let base = try #require(model.stock(for: frame))

            model.showStockBuilder()
            #expect(model.stockBuilder?.spec.base == .neutral)
            #expect(!model.canBakeFrameAsStock(frame))
            model.stockBuilder = nil
            model.bakeFrameAsStock(frame)
            let request = try #require(model.stockBuilder)
            #expect(request.frame == frame)
            #expect(request.spec.base == .derived(stockID: base.id))
            #expect(request.spec.frameLook != nil)
            #expect(model.isSheetShown)
            model.stockBuilder = nil

            let stock = try CustomStockCompiler.compile(request.spec, id: "user-builder", name: "Builder", base: base, size: 17)
            try UserStockStore(folder: userStocks).install(stock, specData: JSONEncoder().encode(request.spec))
            model.reloadUserStocks()
            let saved = try #require(model.films?.stocks.first { $0.id == stock.id })
            model.editCustomStock(saved)
            #expect(model.stockBuilder?.stockID == saved.id)
            #expect(model.stockBuilder?.name == "Builder")
            #expect(model.stockBuilder?.spec == request.spec)
        }
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
            model.developPhase = .done
            model.reloadUserStocks()

            #expect(model.developPhase == .done)
            #expect(model.stockNames.count == initialCount + 1)
            #expect(model.stockVersion == initialVersion + 1)
            let amberIndex = try #require(model.films?.stocks.firstIndex(where: { $0.id == "user-amber" }))
            model.selectStock(amberIndex)
            #expect(model.currentStock?.id == "user-amber")
            #expect(StockCharacter.line(for: model.currentStock) == "warm amber tones")
            let digestV1 = model.stockDigests[amberIndex]

            // An unrelated stock sorting before the active stock changes its index, not the develop.
            let unrelated = Self.makeCustomStock(id: "user-agate", displayName: "Agate 400")
            try store.save(unrelated)
            model.developPhase = .done
            model.reloadUserStocks()
            #expect(model.stockIndex == amberIndex + 1)
            #expect(model.currentStock?.id == "user-amber")
            #expect(model.developPhase == .done)

            // Edit the user stock in place: digest changes, selection stays on user-amber.
            let v2 = Self.makeCustomStock(id: "user-amber", displayName: "Amber 800", boxSpeed: 800)
            try store.save(v2, specData: Data("{}".utf8))
            model.reloadUserStocks()

            let updatedIndex = try #require(model.films?.stocks.firstIndex(where: { $0.id == "user-amber" }))
            #expect(model.developPhase == .idle)
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

    @Test func customImportsDoNotTakeAnUnusedBuiltInDigit() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let userStocks = fixture.folder.appendingPathComponent("UserStocks", isDirectory: true)
            let model = Self.makeModel(fixture: fixture, userStocks: userStocks)
            await model.open(fixture.roll)
            let builtIn = try #require(model.films?.stocks.first)
            let unusedDigit = model.builtInStockIndices.count + 1
            try #require(unusedDigit <= 9)
            let custom = Self.makeCustomStock(id: "user-amber", displayName: "Amber")
            try #require(model.userStockStore).install(custom)
            model.reloadUserStocks()
            let customIndex = try #require(model.films?.stocks.firstIndex { $0.id == custom.id })
            #expect(model.stockDigit(for: customIndex) == nil)
            model.digitPressed(unusedDigit)
            #expect(model.currentStock?.id == builtIn.id)
            model.selectStock(customIndex)
            model.digitPressed(1)
            #expect(model.currentStock?.id == builtIn.id)
        }
    }

    @Test func openingPresetImportsItAndBakingDoesNotSaveAnotherPreset() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = Self.makeModel(fixture: fixture, userStocks: fixture.folder.appendingPathComponent("UserStocks"))
            let sourceStore = PresetStore(folder: fixture.folder.appendingPathComponent("Shared Presets"))
            let source = UserPreset(name: "Soft", canisterColor: [0.2, 0.3, 0.4], includedParts: .light)
            let url = try sourceStore.save(source)
            #expect(model.open([url]))
            #expect(model.lookPresets.map(\.id) == [source.id])
            #expect(model.lookPresets.first?.tagTint?.components == source.canisterColor)
            guard case .library(_, let selection, false) = model.presetPresentation else {
                Issue.record("Opening a preset should show it in the library.")
                return
            }
            #expect(selection == source.id)
            #expect(model.isSheetShown && model.menuState.isSheetShown)
            model.presetPresentation = nil

            await model.open(fixture.roll)
            let frame = try #require(model.roll?.frames.first)
            model.manualLoaded.insert(frame.url)
            model.showSavePreset(from: frame)
            #expect(!model.canBakeFrameAsStock(frame) && model.canMakeBakedStock(from: frame))
            try model.bakePresetAsStock(from: frame, name: "Soft Stock", canisterColor: source.canisterColor)
            guard case .builder(let builder) = model.presetPresentation else {
                Issue.record("Baking from the save sheet should open the builder.")
                return
            }
            #expect(builder.name == "Soft Stock")
            #expect(builder.spec.canisterColor == source.canisterColor)
            #expect(builder.spec.frameLook != nil)
            #expect(try model.presetStore.loadAll().presets.map(\.id) == [source.id])
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

            // Frames following the missing roll stock cannot develop through the preview fallback.
            let reopenedFirst = try #require(reopened.roll?.frames.first)
            #expect(reopened.unavailableStockReason(for: reopenedFirst) != nil)

            // Unrelated edits while previewing through fallback preserve the missing stock id in recipes.
            reopened.setRatedAt(.oneStopUnder, for: reopenedFirst)
            try await reopened.flushManualSaves()
            let savedRecipe = RecipeStore.read(for: reopenedFirst, library: fixture.library)
            #expect(savedRecipe?.stock.id == "user-velvet")

            // Choosing a stock explicitly clears the missing-stock state.
            let neutralIndex = try #require(reopened.films?.stocks.firstIndex(where: { $0.id == "argent-neutral" }))
            reopened.selectStock(neutralIndex)
            #expect(reopened.missingRollStockID == nil)
            #expect(reopened.missingStockNotice == nil)
            #expect(reopened.unavailableStockReason(for: reopenedFirst) == nil)
        }
    }
}
