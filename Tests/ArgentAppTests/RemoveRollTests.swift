@testable import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

/// Remove on a roll with a stock, every frame measured and the roll settled, where a first edit pins Auto, edits are saved and a
/// develop can start: a removal as a frame's first edit, a paste of everything, and a develop started during a run.
@MainActor @Suite(.serialized) struct RemoveRollTests {
    struct Opened {
        let model: RollModel
        let measurements: MeasurementGate
        let frames: [Frame]
        let steps: FakeRemovalSteps
    }

    private func open(_ fixture: AutoDecisionStateTests.Fixture, gate: RunGate? = nil) async throws -> Opened {
        let model = fixture.model(), measurements = MeasurementGate()
        try await AutoDecisionStateTests.open(fixture, in: model, through: measurements)
        let frames = try #require(model.roll?.frames)
        measurements.openAll(frames)
        _ = try #require(await model.settledDecision())
        model.askAboutUnsavableAdjustments = { _ in .proceed }
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        let steps = FakeRemovalSteps(gate: gate, library: fixture.library)
        model.removalRuns.steps = steps
        model.removalRuns.showsTab = true
        return Opened(model: model, measurements: measurements, frames: frames, steps: steps)
    }

    /// `frame` as a photographer has it before a first edit: prepared, with Auto on screen.
    private func show(_ model: RollModel, _ frame: Frame) async {
        await model.prepareManualAdjustments(for: frame)
        let stock = model.stockIndex
        model.recordVisibleAutomatic(for: frame, stock: stock, aim: model.printAim(for: frame), settings: model.settings(for: frame, stock: stock))
    }

    private func step(_ model: RollModel, _ change: () -> Void) {
        model.manualUndoManager?.beginUndoGrouping()
        change()
        model.manualUndoManager?.endUndoGrouping()
    }

    @Test func aRemovalIsAFramesFirstEditPinnedOnAutoAndSavedWithIt() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let opened = try await open(fixture), model = opened.model, frame = opened.frames[0]
            defer { AutoDecisionStateTests.close(model, opened.measurements) }
            #expect(model.films != nil, "the previews were made with the library's patches")
            await show(model, frame)
            try #require(model.canAdjust(frame) && !model.hasManualAdjustments(frame))

            model.removeObject(on: frame)
            await model.removalsSettled()
            let edit = try #require(model.manualEdits[frame.url])
            let made = edit.adjustments.removals
            #expect(made.count == 1 && edit.baseline.origin == .auto && edit.baseline.aim == model.printAim(for: frame))
            #expect(edit.adjustments.withoutRemovals.isIdentity && model.manualUndoManager?.undoActionName == "Remove Object")
            #expect(model.lensSettings(for: frame).removals == made, "the previews are given the removal with the lens settings")

            // Saved as any edit is, and read back with the roll.
            try await model.flushManualSaves()
            #expect(model.manualRecipes[frame.url]?.manual?.adjustments.removals == made)

            // Undone, the frame is on Auto again with its pin released; redone, pinned as it was.
            model.manualUndoManager?.undo()
            #expect(model.manualEdits[frame.url] == nil && model.removalRows(for: frame).isEmpty)
            model.manualUndoManager?.redo()
            #expect(model.manualEdits[frame.url] == edit && opened.steps.runs.count == 1)

            // Deleting the only thing the edit held releases the pin, as Reset Light does.
            model.deleteRemoval(made[0].id, on: frame)
            #expect(model.manualEdits[frame.url] == nil && model.manualUndoManager?.undoActionName == "Delete Removal")
            try await model.flushManualSaves()
        }
    }

    @Test func aPasteOfEverythingKeepsTheFramesOwnRemovalsAndBringsNone() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let opened = try await open(fixture), model = opened.model
            defer { AutoDecisionStateTests.close(model, opened.measurements) }
            let removed = opened.frames[0], source = opened.frames[1], plain = opened.frames[2]
            for frame in [removed, source, plain] { await show(model, frame) }
            step(model) { model.setManualAdjustments(try! ManualAdjustments(exposureEV: 0.4), for: removed) }
            model.removeObject(on: removed)
            await model.removalsSettled()
            let made = model.manualAdjustments(for: removed).removals
            try #require(made.count == 1)
            let values = try ManualAdjustments(exposureEV: -0.7, contrast: 15).settingLens(try LensSettings.default.setting(.vignette, to: 30))
            step(model) { model.setManualAdjustments(values, for: source) }

            // Everything from a frame with no removal: the frame takes its values and keeps what was removed from it.
            model.copyAdjustments(from: source)
            model.pasteAdjustments(to: removed)
            var report = try #require(await model.pasteTask?.value)
            #expect(report.pasted == [removed.url])
            let pasted = model.manualAdjustments(for: removed)
            #expect(pasted.removals == made && pasted.withoutRemovals == values)
            #expect(model.manualAdjustments(for: source).removals.isEmpty)
            #expect(model.manualUndoManager?.undoActionName == "Paste Adjustments")
            model.manualUndoManager?.undo()
            #expect(model.manualAdjustments(for: removed).removals == made && model.manualAdjustments(for: removed).exposureEV == 0.4)
            model.manualUndoManager?.redo()

            // Everything from a frame with a removal: its values go, its pixels do not.
            model.copyAdjustments(from: removed)
            #expect(model.adjustmentsClipboard?.adjustments.removals.isEmpty == true)
            model.pasteAdjustments(to: plain)
            report = try #require(await model.pasteTask?.value)
            #expect(report.pasted == [plain.url])
            #expect(model.manualAdjustments(for: plain) == values && model.removalRows(for: plain).isEmpty)

            // Nothing from Auto pasted over a frame whose only edit is a removal leaves the removal, and the frame edited.
            step(model) { model.resetLight(for: removed) }
            step(model) { model.resetLens(for: removed) }
            let untouched = opened.frames[3]
            await show(model, untouched)
            let nothing = AdjustmentsClipboard(source: untouched.url, sourceName: untouched.name, origin: .auto, adjustments: .identity,
                                               maskNotes: .none, frameControls: FrameControls())
            report = try #require(await model.paste(nothing, parts: .all, to: [removed], batch: false)?.value)
            #expect(report.pasted == [removed.url] && model.manualAdjustments(for: removed).removals == made)
            #expect(opened.steps.runs.count == 1, "no paste runs the model")
            model.dismissClipboardNotice()
            try await model.flushManualSaves()
        }
    }

    @Test func aDevelopStartedDuringARunTellsTheQueueBeforeAndAfter() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let gate = RunGate()
            let opened = try await open(fixture, gate: gate), model = opened.model, frame = opened.frames[0], steps = opened.steps
            defer { AutoDecisionStateTests.close(model, opened.measurements) }
            await show(model, frame)
            model.removeObject(on: frame)
            await gate.arrived(1)

            var atTheJobs: [FakeRemovalSteps.Event] = []
            model.observeDevelopJobs = { _ in
                atTheJobs = steps.events.filter { $0 != .noteUse }
                // Stopped before any frame: a develop run to its end needs the app's bundle.
                model.stopDevelop()
            }
            model.startDevelop(to: fixture.folder.appendingPathComponent("Export"))
            await model.developTask?.value
            #expect(atTheJobs == [.developWillStart], "the model is sent away before the develop makes its frames")
            #expect(steps.events.filter { $0 != .noteUse } == [.developWillStart, .developDidEnd])
            #expect(model.lastDevelop?.wasStopped == true)

            // The run waited through the develop, and nothing of it was in the develop's edit.
            let rows = model.removalRows(for: frame)
            #expect(gate.holding == 1 && rows.count == 1 && rows[0].isPending && !model.hasManualAdjustments(frame))
            gate.release()
            await model.removalsSettled()
            #expect(model.manualAdjustments(for: frame).removals.count == 1)
            try await model.flushManualSaves()
        }
    }

    @Test func aDevelopOfASessionThatRemovedNothingMakesNoModel() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), measurements = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: measurements)
            defer { AutoDecisionStateTests.close(model, measurements) }
            measurements.openAll(try #require(model.roll?.frames))
            _ = try #require(await model.settledDecision())
            var made = 0
            model.removalRuns.makeSteps = {
                made += 1
                return nil
            }
            model.observeDevelopJobs = { _ in model.stopDevelop() }
            model.startDevelop(to: fixture.folder.appendingPathComponent("Export"))
            await model.developTask?.value
            #expect(made == 0 && model.removalRuns.steps == nil && model.lastDevelop?.wasStopped == true)
        }
    }
}
