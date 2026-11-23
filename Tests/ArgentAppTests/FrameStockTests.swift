import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// In the frame view the dock's stock picker, the stock panel, the Stock menu and the film settings set the open frame's own
/// stock and grain; on the sheet they set the whole roll's.
@MainActor @Suite(.serialized) struct FrameStockTests {
    @Test func theFrameViewsStockAndGrainAreTheOpenFramesAlone() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("alternate", in: fixture.stocks)
            let model = fixture.model()
            await model.open(fixture.roll)
            let frames = try #require(model.roll?.frames)
            try #require(model.stockNames.count == 2)
            let roll = model.stockIndex, other = 1 - roll

            // Open frame 2: the stock chosen is its own, and the roll and the other frames keep theirs.
            model.selection = frames[1].id
            model.openFrame()
            let open = try #require(model.shownFrame)
            model.selectStock(other)
            #expect(model.stockIndex == roll)
            #expect(model.stockIndex(for: open) == other && model.shownStockIndex == other)
            #expect(model.hasOwnStock(open) && model.isOverridden(open))
            #expect(model.stockIndex(for: frames[0]) == roll && model.stockIndex(for: frames[2]) == roll)
            #expect(model.stockName(for: open) == model.stockNames[other])

            // Choosing the roll's stock again makes the frame follow the roll.
            model.selectStock(roll)
            #expect(!model.hasOwnStock(open) && !model.isOverridden(open))

            // Grain, from the film settings, is the frame's alone too.
            model.output.grain = .natural
            model.setGrain(.off, for: open)
            #expect(model.grain(for: open) == .off && model.grain(for: frames[0]) == .natural)
            #expect(model.settings(for: open, stock: model.stockIndex(for: open)).grain == 0)
            #expect(model.settings(for: frames[0], stock: model.stockIndex(for: frames[0])).grain == 1)
            model.setGrain(.natural, for: open)
            #expect(model.frameControls(open).grain == nil)

            // Same as roll clears the frame's stock with the rest.
            model.selectStock(other)
            model.setRatedAt(.oneStopUnder, for: open)
            model.clearOverrides(for: open)
            #expect(model.stockIndex(for: open) == roll && model.frameControls(open).isEmpty)

            // On the sheet the picker sets the whole roll's stock, and a frame with its own keeps it.
            model.selectStock(other)
            model.showRoll()
            #expect(model.shownFrame == nil && model.shownStockIndex == roll)
            model.selectStock(other)
            #expect(model.stockIndex == other)
            #expect(model.stockIndex(for: frames[0]) == other)
            #expect(model.frameControls(open).stock == model.films?.stocks[other].id)
        }
    }

    /// A frame given only its own stock or grain, with no recipe or edit yet, has them saved, and reopens with them; one given its
    /// own stock and made to follow the roll again before that save lands reopens following it.
    @Test func aFreshFramesOwnStockAndGrainAreSavedAndReopen() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("alternate", in: fixture.stocks)
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            let frames = try #require(model.roll?.frames)
            try #require(model.stockNames.count == 2)
            let roll = model.stockIndex, other = 1 - roll, otherID = try #require(model.films?.stocks[other].id)
            let grain: OutputSettings.Grain = model.output.grain == .natural ? .off : .natural
            #expect(frames.allSatisfy { model.manualRecipes[$0.url] == nil && model.manualEdits[$0.url] == nil })
            model.setStock(other, for: frames[1])
            model.setGrain(grain, for: frames[2])
            model.setStock(other, for: frames[3])
            model.setStock(nil, for: frames[3])
            try await model.flushManualSaves()
            AutoDecisionStateTests.close(model, gate)

            let reopened = fixture.model(), again = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: reopened, through: again)
            defer { AutoDecisionStateTests.close(reopened, again) }
            #expect(reopened.stockIndex == roll)
            #expect(reopened.frameControls(frames[1]) == FrameControls(stock: otherID))
            #expect(reopened.frameControls(frames[2]) == FrameControls(grain: grain))
            #expect(reopened.frameControls(frames[3]).isEmpty && reopened.frameControls(frames[0]).isEmpty)
        }
    }

    /// Gives the fixture's stock `id` halation, which `writeToyStock` leaves out.
    private static func giveHalation(_ id: String, in stocks: URL) throws {
        let url = stocks.appendingPathComponent(id).appendingPathComponent(Stock.manifestName)
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        manifest["halation"] = ["strength": 0.015, "greenShare": 0.25, "radiusMicrometres": 180]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    }

    /// Halation, from the film settings, is the roll's or a frame's own, and the render takes it as a multiple of the stock's;
    /// a stock without halation takes none of it. Its row's gesture goes to the frame view's print alone until it ends, when
    /// the frame or the roll takes the value in one write.
    @Test func halationIsTheRollsOrAFramesOwnAndItsGestureIsWrittenOnce() async throws {
        // The roll's is kept for every roll, in the process's defaults: put back as it was stored.
        let stored = UserDefaults.standard.data(forKey: "outputSettings")
        defer { UserDefaults.standard.set(stored, forKey: "outputSettings") }
        try await AutoDecisionStateTests.withRoll { fixture in
            try Self.giveHalation("toy", in: fixture.stocks)
            try AutoDecisionStateTests.writeToyStock("alternate", in: fixture.stocks)
            let model = fixture.model()
            await model.open(fixture.roll)
            let frames = try #require(model.roll?.frames)
            let stock = try #require(model.films?.stocks.firstIndex { $0.halation != nil }), without = 1 - stock
            model.selectStock(stock)
            try #require(model.stockIndex == stock)
            model.output.halation = 100

            // A frame's own is its alone.
            model.setHalation(150, for: frames[1])
            #expect(model.halation(for: frames[1]) == 150 && model.halation(for: frames[0]) == 100)
            #expect(model.frameControls(frames[1]) == FrameControls(halation: 150) && model.isOverridden(frames[1]))
            #expect(model.settings(for: frames[1], stock: stock).halationAmount == 1.5)
            #expect(model.settings(for: frames[0], stock: stock).halationAmount == 1)
            // The roll's reaches the frames that follow it, and given to a frame makes it follow the roll again.
            model.output.halation = 60
            #expect(model.settings(for: frames[0], stock: stock).halationAmount == 0.6)
            #expect(model.settings(for: frames[1], stock: stock).halationAmount == 1.5)
            model.setHalation(60, for: frames[1])
            #expect(model.frameControls(frames[1]).isEmpty)
            // A stock without halation takes none of the control.
            let plain = model.settings(for: frames[0], stock: without)
            #expect(!plain.halation && plain.halationAmount == 1)

            // A frame's gesture: its steps to the frame view's print, and the last to the frame as it ends.
            model.moveHalation(120, for: frames[2])
            model.moveHalation(180, for: frames[2])
            #expect(model.printSettings(for: frames[2], stock: stock).halationAmount == 1.8)
            #expect(model.printSettings(for: frames[0], stock: stock).halationAmount == 0.6)
            #expect(model.settings(for: frames[2], stock: stock).halationAmount == 0.6 && model.frameControls(frames[2]).isEmpty)
            model.endHalationAdjusting()
            #expect(model.printedHalation == nil && model.frameControls(frames[2]) == FrameControls(halation: 180))
            // The roll's gesture: nothing takes it until it ends, and a frame with its own keeps it.
            model.moveHalation(90, for: nil)
            #expect(model.output.halation == 60 && model.printSettings(for: frames[0], stock: stock).halationAmount == 0.6)
            model.endHalationAdjusting()
            #expect(model.output.halation == 90 && model.halation(for: frames[0]) == 90 && model.halation(for: frames[2]) == 180)
            // Past the range, the range's end; and a gesture back to the roll's value follows the roll.
            model.moveHalation(900, for: frames[2])
            #expect(model.printedHalation?.value == 200)
            model.moveHalation(90, for: frames[2])
            model.endHalationAdjusting()
            #expect(model.frameControls(frames[2]).isEmpty)
        }
    }

    /// A frame given only its own Halation, with no recipe or edit yet, has it saved at the version an amount requires, and
    /// reopens with it.
    @Test func aFreshFramesOwnHalationIsSavedAndReopens() async throws {
        let stored = UserDefaults.standard.data(forKey: "outputSettings")
        defer { UserDefaults.standard.set(stored, forKey: "outputSettings") }
        try await AutoDecisionStateTests.withRoll { fixture in
            try Self.giveHalation("toy", in: fixture.stocks)
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            let frames = try #require(model.roll?.frames)
            model.output.halation = 100
            #expect(frames.allSatisfy { model.manualRecipes[$0.url] == nil && model.manualEdits[$0.url] == nil })
            model.setHalation(150, for: frames[1])
            try await model.flushManualSaves()
            AutoDecisionStateTests.close(model, gate)

            let reopened = fixture.model(), again = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: reopened, through: again)
            defer { AutoDecisionStateTests.close(reopened, again) }
            #expect(reopened.frameControls(frames[1]) == FrameControls(halation: 150) && reopened.frameControls(frames[0]).isEmpty)
            let recipe = try #require(reopened.manualRecipes[frames[1].url])
            #expect(recipe.version == 14 && recipe.render.halationAmount == 1.5)
            #expect(reopened.settings(for: frames[1], stock: reopened.stockIndex).halationAmount == 1.5)
        }
    }

    /// A frame whose own stock the library does not have shows through the roll's, but a develop fails it with that reason and
    /// never develops it through the roll's; the other frames develop.
    @Test func aFrameWhoseOwnStockIsNotInstalledFailsItsDevelop() async throws {
        try await DevelopFrameStateTests.withModel { model, frames, fixture in
            let jobs = FlagStateTests.capture(model)
            model.developFolder.usesSubfolder = false
            model.chooseDestination(fixture.folder.appendingPathComponent("Export"))
            model.setRestoredFrameControls(FrameControls(stock: "kodak-ektar-100"), url: frames[2].url)
            #expect(model.stockIndex(for: frames[2]) == model.stockIndex && model.unavailableStockReason(for: frames[3]) == nil)
            await FlagStateTests.develop(model) { model.developFrames([frames[2], frames[3]]) }
            #expect(jobs.last == [frames[3].url] && jobs.totals.last == 2)
            let report = try #require(model.lastDevelop)
            #expect(report.raws == [frames[2].url, frames[3].url] && report.failures.map(\.frame.url) == [frames[2].url])
            #expect(report.failures.first?.reason
                    == "its own stock, kodak-ektar-100, is not installed; choose another stock for it, or make it follow the roll")
            #expect(model.developMarks[frames[2].url] == .failed)
        }
    }

    /// With no stock installed, Reset to Original has nothing to pin a frame from Auto through: it is off, and does nothing.
    @Test func resetToOriginalNeedsAStock() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try FileManager.default.removeItem(at: fixture.stocks)
            let model = fixture.model()
            await model.open(fixture.roll)
            if let restoration = model.manualRestoreTask { await restoration.value }
            #expect(model.films == nil && model.stockDigests.isEmpty)
            let frame = try #require(model.roll?.frames.first)
            // Its recipe read, its raw verified and a measurement from a recipe: ready for a first edit.
            let source = try #require(SourceStamp.of(frame.url))
            model.recordRestored(FrameMeasurement(analysis: AutoDecisionStateTests.analysis(0), source: source), for: frame)
            model.manualReadySources[frame.url] = try SourceDigests.shared.digest(of: frame.url)
            try #require(model.manualLoaded.contains(frame.url) && model.canChangeStartingPoint(frame))
            #expect(!model.canStartFromOriginal(frame))
            model.startFromOriginal(for: frame, actionName: "Reset to Original")
            #expect(model.manualEdits[frame.url] == nil)
        }
    }

    /// The quick develop dialog shows one frame's stock and controls, and its own grain in place of the roll's, which its Grain
    /// row sets; several frames, the roll's, and how many keep their own grain.
    @Test func quickDevelopShowsTheStockAndGrainAFrameDevelopsWith() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("alternate", in: fixture.stocks)
            let model = fixture.model()
            await model.open(fixture.roll)
            let frames = try #require(model.roll?.frames)
            try #require(model.stockNames.count == 2)
            let roll = model.stockIndex, other = 1 - roll
            let grain: OutputSettings.Grain = model.output.grain == .natural ? .off : .natural
            model.setStock(other, for: frames[2])
            model.setGrain(grain, for: frames[2])
            model.setRatedAt(.oneStopUnder, for: frames[2])

            let one = DevelopStatusText.summary(model, frames: [frames[2]])
            #expect(one == "1 of 8 frames · \(model.stockNames[other]) · rated at 800 · 1 frame with its own settings")
            #expect(model.quickDevelopGrain(for: [frames[2]]) == QuickDevelopGrain(own: grain, note: "This frame's own grain, from its film settings."))
            #expect(DevelopStatusText.summary(model, frames: [frames[1], frames[2]])
                    == "2 of 8 frames · \(model.stockNames[roll]) · 1 frame with its own settings")
            #expect(model.quickDevelopGrain(for: [frames[1], frames[2]])
                    == QuickDevelopGrain(own: nil, note: "Sets the roll's grain; 1 of these frames keeps its own."))
            #expect(model.quickDevelopGrain(for: [frames[1]]) == nil)
            #expect(DevelopStatusText.summary(model, frames: [frames[1]]) == "1 of 8 frames · \(model.stockNames[roll])")
        }
    }

    /// A frame's own grain is what its develop's check on the Develop page is made from: the roll's grain moving to it keeps the
    /// frame's check, and takes that of a frame following the roll.
    @Test func theRollsGrainLeavesTheCheckOfAFrameWithItsOwn() async throws {
        try await QuickDevelopStateTests.withModel { model, frames, _ in
            let folder = try #require(model.developDestination)
            let grain: OutputSettings.Grain = model.output.grain == .natural ? .off : .natural
            model.setGrain(grain, for: frames[0])
            let developed = [frames[0], frames[1]]
            model.noteDeveloped(developed, developed.map { .developed(folder.appendingPathComponent($0.name + ".jpg")) },
                                destination: folder, inputs: DevelopInputs(model, frames: developed.map(\.url)))
            #expect(model.developMarks[frames[0].url] == .developed && model.developMarks[frames[1].url] == .developed)
            model.output.grain = grain
            #expect(model.developMarks[frames[0].url] == .developed && model.developMarks[frames[1].url] == nil)
        }
    }

    /// So too a frame's own Halation: the roll's moving to it keeps the frame's check, and takes that of a frame following the roll.
    @Test func theRollsHalationLeavesTheCheckOfAFrameWithItsOwn() async throws {
        try await QuickDevelopStateTests.withModel { model, frames, _ in
            let folder = try #require(model.developDestination)
            model.output.halation = 100
            model.setHalation(150, for: frames[0])
            let developed = [frames[0], frames[1]]
            model.noteDeveloped(developed, developed.map { .developed(folder.appendingPathComponent($0.name + ".jpg")) },
                                destination: folder, inputs: DevelopInputs(model, frames: developed.map(\.url)))
            #expect(model.developMarks[frames[0].url] == .developed && model.developMarks[frames[1].url] == .developed)
            model.output.halation = 150
            #expect(model.developMarks[frames[0].url] == .developed && model.developMarks[frames[1].url] == nil)
        }
    }
}
