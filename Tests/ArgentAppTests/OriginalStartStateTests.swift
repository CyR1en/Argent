import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// A frame can start from its Original instead of Auto (docs/manual-development.md, "Starting from
/// Original"): the neutral aim, chosen in the inspector's Start from, recorded with the pin and kept
/// with identity values through Undo, saves, reopening and Develop; Auto never moves it.
@MainActor @Suite(.serialized) struct OriginalStartStateTests {
    /// Opens the fixture's roll in a model with an undo manager, its frames measured through a gate
    /// failing `failing`, and settled unless `settles` is false; then `body` with the first frame, its
    /// source verified.
    private func withFrame(failing: Set<String> = [], settles: Bool = true,
                           _ body: (AutoDecisionStateTests.Fixture, RollModel, MeasurementGate, [Frame], Frame) async throws -> Void) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            gate.failing = failing
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames), frame = frames[0]
            try await gate.waitUntilWaiting(for: frames.count)
            gate.release(frame.url)
            if settles {
                gate.openAll(frames)
                _ = try #require(await model.settledDecision())
            }
            while !model.isMeasured(frame) { await Task.yield() }
            model.manualReadySources[frame.url] = try SourceDigests.shared.digest(of: frame.url)
            model.manualUndoManager = UndoManager()
            model.manualUndoManager?.groupsByEvent = false
            try await body(fixture, model, gate, frames, frame)
            try await model.flushManualSaves()
        }
    }

    /// One undo group, as one event of the app makes.
    private func step(_ model: RollModel, _ action: () -> Void) {
        model.manualUndoManager?.beginUndoGrouping()
        action()
        model.manualUndoManager?.endUndoGrouping()
    }

    /// What the frame prints at its Original through the model's stock and its controls.
    private func originalSettings(_ model: RollModel, _ frame: Frame) throws -> DevelopSettings {
        try DevelopmentResolver.resolve(stock: try #require(model.currentStock), stockDigest: model.stockDigests[model.stockIndex],
            controls: model.controls(for: frame), aim: PrintAim(), manual: nil, grain: model.output.grain.amount,
            grainSeed: frame.grainSeed, sharpen: true)
    }

    @Test func startingFromOriginalClearsTheValuesInOneUndoStepAndAutoReleasesIt() async throws {
        try await withFrame { _, model, _, _, frame in
            let stock = model.stockIndex
            #expect(model.printAim(for: frame) != PrintAim())
            model.recordVisibleAutomatic(for: frame, stock: stock, aim: model.printAim(for: frame),
                                         settings: model.settings(for: frame, stock: stock))
            let automatic = model.settings(for: frame, stock: stock)
            step(model) { model.setManualAdjustments(try! ManualAdjustments(exposureEV: 0.5, shadows: 30), for: frame) }
            let before = try #require(model.manualEdits[frame.url])
            #expect(before.baseline.origin == .auto && model.startingPoint(for: frame) == .auto)
            #expect(model.canChangeStartingPoint(frame))

            step(model) { model.startFrom(.original, for: frame) }
            let original = try #require(model.manualEdits[frame.url])
            #expect(model.startingPoint(for: frame) == .original)
            #expect(original.adjustments == .identity && original.baseline.aim == PrintAim())
            #expect(model.manualUndoManager?.undoActionName == "Start from Original")
            #expect(model.settings(for: frame, stock: stock) == (try originalSettings(model, frame)))
            #expect(model.settings(for: frame, stock: stock) != automatic)
            // Compare to Original shows the Original without the edits; with none, the frame itself.
            #expect(model.automaticSettings(for: frame, stock: stock) == model.settings(for: frame, stock: stock))
            #expect(!model.hasUpdatedAuto(frame) && model.hasManualAdjustments(frame))

            model.manualUndoManager?.undo()
            #expect(model.manualEdits[frame.url] == before)
            #expect(model.manualUndoManager?.redoActionName == "Start from Original")
            model.manualUndoManager?.redo()
            #expect(model.manualEdits[frame.url] == original)

            step(model) { model.startFrom(.auto, for: frame) }
            #expect(model.manualEdits[frame.url] == nil && model.startingPoint(for: frame) == .auto)
            #expect(model.manualUndoManager?.undoActionName == "Start from Auto")
            #expect(model.settings(for: frame, stock: stock) == automatic)
            model.manualUndoManager?.undo()
            #expect(model.manualEdits[frame.url] == original)
        }
    }

    /// Before the roll settles an Original can be chosen, as it reads no decision; Reset on it, Reset
    /// Light and a curve reset keep it, an identity Original stays pinned at the end of a gesture, and
    /// neither the settled decision nor Rebalance Roll moves it.
    @Test func anOriginalNeedsNoSettledDecisionKeepsItsPinThroughResetsAndAutoNeverMovesIt() async throws {
        try await withFrame(failing: [AutoDecisionStateTests.names[3]], settles: false) { _, model, gate, frames, frame in
            let stock = model.stockIndex
            model.openFrame()
            #expect(!model.canAdjust(frame) && model.canStartFromOriginal(frame) && model.menuState.canResetToOriginal)
            step(model) { model.startFromOriginal(for: frame) }
            let pin = try #require(model.manualEdits[frame.url]?.baseline)
            #expect(pin.origin == .original && model.canAdjust(frame))
            #expect(!model.menuState.canResetToOriginal && model.menuState.canResetManual)

            // An identity Original survives a gesture's end.
            model.beginManualGesture(for: frame)
            model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.3), for: frame)
            model.setManualAdjustments(.identity, for: frame)
            model.endManualGesture(for: frame)
            #expect(model.manualEdits[frame.url] == ManualEdit(adjustments: .identity, baseline: pin))

            let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
            step(model) { model.setManualAdjustments(try! ManualAdjustments(exposureEV: 0.4, whites: 20, curves: curves), for: frame) }
            step(model) { model.resetLight(for: frame) }
            #expect(model.manualEdits[frame.url] == ManualEdit(adjustments: try ManualAdjustments(curves: curves), baseline: pin))
            step(model) { model.resetToneCurves(for: frame) }
            #expect(model.manualEdits[frame.url] == ManualEdit(adjustments: .identity, baseline: pin))

            step(model) { model.setManualAdjustments(try! ManualAdjustments(exposureEV: -0.5, curves: curves), for: frame) }
            #expect(model.menuState.canResetToOriginal)
            step(model) { model.startFromOriginal(for: frame, actionName: "Reset to Original") }
            #expect(model.manualEdits[frame.url] == ManualEdit(adjustments: .identity, baseline: pin))
            #expect(model.manualUndoManager?.undoActionName == "Reset to Original")
            step(model) { model.setManualAdjustments(try! ManualAdjustments(exposureEV: -0.5), for: frame) }
            let edited = try #require(model.manualEdits[frame.url])
            let shown = model.settings(for: frame, stock: stock)

            gate.openAll(frames)
            let decision = try #require(await model.settledDecision())
            #expect(decision.aims[frame.url] != PrintAim())
            #expect(model.manualEdits[frame.url] == edited && model.settings(for: frame, stock: stock) == shown)
            #expect(!model.hasUpdatedAuto(frame))
            gate.failing = []
            model.rebalanceRoll()
            let moved = try #require(await model.settledDecision())
            #expect(moved.revision != decision.revision)
            #expect(model.manualEdits[frame.url] == edited && model.settings(for: frame, stock: stock) == shown)
            #expect(!model.hasUpdatedAuto(frame))
        }
    }

    /// An identity Original is saved, read back on reopening and resolved as it was; its recipe is v4.
    @Test func anIdentityOriginalPersistsThroughSavesAndReopening() async throws {
        try await withFrame { fixture, model, _, _, frame in
            step(model) { model.startFrom(.original, for: frame) }
            let edit = try #require(model.manualEdits[frame.url])
            let settings = model.settings(for: frame, stock: model.stockIndex)
            try await model.flushManualSaves()
            let saved = try #require(try await RecipeWriter.shared.load(for: frame, library: model.recipeLibrary))
            #expect(saved.manual == edit && saved.version == 4)

            await model.open(fixture.roll)
            if let restoration = model.manualRestoreTask { await restoration.value }
            #expect(model.manualEdits[frame.url] == edit && model.startingPoint(for: frame) == .original)
            #expect(model.settings(for: frame, stock: model.stockIndex) == settings)
        }
    }

    /// An edit recorded on an older Light compiler stays on it through saves, reopening and further
    /// slider moves, and renders with it, as Start from Original or Update Automatic Baseline move it
    /// to the current one.
    @Test(arguments: [ManualRenderSettings.exposedBaseVersion, ManualRenderSettings.regionsVersion])
    func anEditKeepsItsRecordedCompilerUntilAnOriginalIsTakenAgain(recorded: String) async throws {
        try await withFrame { fixture, model, _, _, frame in
            let current = ManualRenderSettings.currentVersion
            step(model) { model.startFrom(.original, for: frame) }
            #expect(model.manualEdits[frame.url]?.curveVersion == current)
            model.manualEdits[frame.url]?.curveVersion = recorded
            step(model) { model.setManualAdjustments(try! ManualAdjustments(exposureEV: 0.5, highlights: -40), for: frame) }
            let edit = try #require(model.manualEdits[frame.url])
            #expect(edit.curveVersion == recorded)
            try await model.flushManualSaves()
            let saved = try #require(try await RecipeWriter.shared.load(for: frame, library: model.recipeLibrary))
            #expect(saved.manual == edit && saved.render.manual?.version == recorded)

            await model.open(fixture.roll)
            if let restoration = model.manualRestoreTask { await restoration.value }
            #expect(model.manualEdits[frame.url] == edit)
            #expect(model.settings(for: frame, stock: model.stockIndex).manual.version == recorded)
            // Ready to edit again, as the frame's first refinement is after opening.
            let reopened = ContinuousClock.now + .seconds(20)
            while !model.isMeasured(frame), ContinuousClock.now < reopened { try await Task.sleep(for: .milliseconds(10)) }
            model.manualReadySources[frame.url] = try SourceDigests.shared.digest(of: frame.url)
            try #require(model.canAdjust(frame))
            step(model) { model.setManualAdjustments(try! ManualAdjustments(exposureEV: -0.5, shadows: 30), for: frame) }
            #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(exposureEV: -0.5, shadows: 30)))
            #expect(model.manualEdits[frame.url]?.curveVersion == recorded)
            let settings = model.settings(for: frame, stock: model.stockIndex)
            #expect(settings.manual.version == recorded)
            #expect(RenderGraph.version(for: settings).contains("+manual-\(recorded)"))

            step(model) { model.startFromOriginal(for: frame, actionName: "Reset to Original") }
            #expect(model.manualEdits[frame.url]?.curveVersion == current && model.manualEdits[frame.url]?.adjustments == .identity)
            step(model) { model.setManualAdjustments(try! ManualAdjustments(exposureEV: 0.5, highlights: -40), for: frame) }
            #expect(RenderGraph.version(for: model.settings(for: frame, stock: model.stockIndex)).contains("+manual-\(current)"))

            // Update Automatic Baseline keeps the values, at the current compiler.
            model.manualEdits[frame.url]?.curveVersion = recorded
            model.manualUndoManager?.beginUndoGrouping()
            model.updateAutomaticBaseline(for: frame)
            let deadline = ContinuousClock.now + .seconds(20)
            while model.manualEdits[frame.url]?.curveVersion == recorded, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            model.manualUndoManager?.endUndoGrouping()
            #expect(model.manualEdits[frame.url]?.curveVersion == current)
            #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(exposureEV: 0.5, highlights: -40)))
            #expect(model.manualEdits[frame.url]?.baseline.origin == .original)
            try await model.flushManualSaves()
        }
    }

    /// Update Automatic Baseline takes an Original again at the current versions, never Auto, values
    /// identity included.
    @Test func updateAutomaticBaselineRepinsAnOriginal() async throws {
        try await withFrame { _, model, _, _, frame in
            step(model) { model.startFrom(.original, for: frame) }
            var stale = try #require(model.manualEdits[frame.url])
            stale.baseline.stockDigest = "an earlier bake"
            model.manualEdits[frame.url] = stale
            // With the issue, Original cannot be taken again by Reset, but Auto can still be chosen.
            #expect(model.manualIssue(for: frame) != nil && !model.canStartFromOriginal(frame))
            #expect(model.canChangeStartingPoint(frame))
            // The update registers its undo once it has run, within the group an event of the app opens.
            model.manualUndoManager?.beginUndoGrouping()
            model.updateAutomaticBaseline(for: frame)
            let deadline = ContinuousClock.now + .seconds(20)
            while model.manualEdits[frame.url]?.baseline.stockDigest == "an earlier bake", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            model.manualUndoManager?.endUndoGrouping()
            let updated = try #require(model.manualEdits[frame.url])
            #expect(updated.baseline.origin == .original && updated.baseline.aim == PrintAim())
            #expect(updated.baseline.stockDigest == model.stockDigests[model.stockIndex] && updated.adjustments == .identity)
            #expect(model.manualIssue(for: frame) == nil)
        }
    }

    /// Develop's job for an Original carries it, and prints the Original, apart from Auto's print.
    @Test func developsJobForAnOriginalCarriesIt() async throws {
        try await withFrame { fixture, model, _, _, frame in
            var captured: [RollDeveloper.Job] = []
            model.observeDevelopJobs = { jobs in
                captured = jobs
                // Stopped before any frame: a develop run to its end needs the app's bundle.
                model.stopDevelop()
            }
            let automatic = Recipe.Render(settings: model.settings(for: frame, stock: model.stockIndex), grain: model.output.grain)
            step(model) { model.startFrom(.original, for: frame) }
            model.startDevelop(to: fixture.folder.appendingPathComponent("Export"))
            await model.developTask?.value
            let job = try #require(captured.first { $0.frame.url == frame.url })
            #expect(job.recipe.manual?.baseline.origin == .original && job.recipe.version == 4)
            #expect(job.recipe.render == Recipe.Render(settings: try originalSettings(model, frame), grain: model.output.grain))
            #expect(job.recipe.render != automatic)
        }
    }
}
