@testable import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

/// What a test saw of a row while its run was under way.
@MainActor final class SeenCaptions {
    var values: [RemovalRowState.Caption?] = []
}

/// Remove in the model (docs/remove-plan.md, sections 4.1 and 4.8) on fake steps: a run is not in the edit, its removal enters the
/// edit when its patch is stored as one undo step, Undo and Redo never run the model, and every row action is one step.
@MainActor @Suite(.serialized) struct RemoveModelTests {
    @Test func returnStoresAPatchThenTheRemovalEntersTheEditAsOneUndoStep() async throws {
        let gate = RunGate()
        let fixture = try await RemoveFixture(gate: gate)
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps, seen = SeenCaptions()
        steps.said = [.waiting(.loading, forDevelop: false), .queued, .step(3, of: RemovalJob.defaultSteps)]
        steps.heard = { await MainActor.run { seen.values.append(fixture.rows.last?.caption) } }

        model.removeObject(on: frame)
        // Return clears the selection for the next object, and the run is a row, not an edit.
        #expect(model.remove.selection.coverage == nil && !model.remove.selection.canRemove)
        var rows = fixture.rows
        #expect(rows.count == 1 && rows[0].isPending && rows[0].number == 1 && rows[0].caption == .removing(step: 0, of: RemovalJob.defaultSteps))
        #expect(rows[0].canCancel && !rows[0].canToggle && !rows[0].canRemake && !rows[0].canDelete)
        #expect(fixture.removals.isEmpty && !fixture.undo.canUndo)
        #expect(model.removalOutline(rows[0].id, on: frame)?.isEmpty == false, "a run is outlined by what was selected")

        await gate.arrived(1)
        #expect(seen.values == [.loading, .queued, .removing(step: 3, of: RemovalJob.defaultSteps)])
        #expect(fixture.removals.isEmpty && steps.stored.isEmpty, "nothing of a run in flight is in the edit")
        #expect(model.manualEdits[frame.url]?.adjustments.removals.isEmpty == true)

        gate.release()
        await model.removalsSettled()
        #expect(seen.values.last == .removing(step: RemovalJob.defaultSteps, of: RemovalJob.defaultSteps))
        let removal = try #require(fixture.removals.first)
        rows = fixture.rows
        #expect(fixture.removals.count == 1 && removal.id == rows[0].id && removal.isOn && removal.includesEffects)
        #expect(rows == [RemovalRowState(id: removal.id, number: 1)] && model.remove.pending.isEmpty)
        #expect(steps.stored == [removal.patch.id], "the patch was in the store before the edit named it")
        #expect(fixture.undo.undoActionName == "Remove Object")

        // One step, and neither way runs the model.
        fixture.undo.undo()
        #expect(fixture.removals.isEmpty && fixture.rows.isEmpty && !fixture.undo.canUndo)
        #expect(model.manualAdjustments(for: frame).exposureEV == 0.5)
        #expect(fixture.undo.redoActionName == "Remove Object")
        fixture.undo.redo()
        #expect(fixture.removals == [removal] && fixture.rows == [RemovalRowState(id: removal.id, number: 1)])
        #expect(steps.runs.count == 1 && steps.stored.count == 1 && steps.crops.count == 1)
        #expect(model.undoPatches.contains(removal.patch.id), "a step that brings a removal back keeps its patch from the sweep")
        #expect(model.patchesInUse.contains(removal.patch.id))
    }

    /// A new removal in smooth surroundings is made with no model, and its row says so; Try Again and Better on it ask
    /// the model, and the row then says nothing.
    @Test func aRemovalInSmoothSurroundingsRunsNoModelUntilItIsMadeAgain() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        steps.heals = true
        model.removeObject(on: frame)
        await model.removalsSettled()
        let made = try #require(fixture.removals.first)
        #expect(steps.runs.isEmpty && steps.stored == [made.patch.id] && steps.crops.count == 1)
        #expect(steps.patch(made.patch.id)?.notes.engine == RemovalPipeline.healEngine)
        #expect(fixture.rows == [RemovalRowState(id: made.id, number: 1, caption: .healed)])
        #expect(fixture.undo.undoActionName == "Remove Object")

        model.remakeRemoval(made.id, better: false, on: frame)
        await model.removalsSettled()
        let again = try #require(fixture.removals.first)
        #expect(steps.runs.count == 1 && steps.runs[0].steps == RemovalJob.defaultSteps && again.patch.id != made.patch.id)
        #expect(steps.patch(again.patch.id)?.notes.engine == FakeRemovalEngine.engineID)
        #expect(fixture.rows == [RemovalRowState(id: made.id, number: 1)], "the model drew this one")

        model.remakeRemoval(made.id, better: true, on: frame)
        await model.removalsSettled()
        #expect(steps.runs.count == 2 && steps.runs[1].steps == RemovalJob.betterSteps)
    }

    /// A removal cancelled while it is being filled with no model leaves no patch in the store.
    @Test func aRemovalCancelledWhileItIsFilledLeavesNoPatch() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        steps.heals = true
        steps.cancelsInHeal = true
        model.removeObject(on: frame)
        await model.removalsSettled()
        #expect(steps.stored.isEmpty && steps.runs.isEmpty && steps.crops.count == 1)
        #expect(fixture.removals.isEmpty && !fixture.undo.canUndo)
    }

    @Test func tryAgainAndBetterKeepTheRemovalAndTakeTheNewPatchAsOneStepEach() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        model.removeObject(on: frame)
        await model.removalsSettled()
        let made = try #require(fixture.removals.first)
        model.setRemoval(made.id, isOn: false, on: frame)
        model.setRemoval(made.id, includesEffects: false, on: frame)

        model.remakeRemoval(made.id, better: false, on: frame)
        await model.removalsSettled()
        let again = try #require(fixture.removals.first)
        #expect(fixture.removals.count == 1 && again.id == made.id && !again.isOn && !again.includesEffects)
        #expect(again.patch.id != made.patch.id && steps.retried == [made.patch.id])
        #expect(steps.runs.count == 2 && steps.runs[1].steps == RemovalJob.defaultSteps && steps.runs[1].guidance == RemovalJob.defaultGuidance)
        #expect(steps.runs[1].seed != steps.runs[0].seed, "Try Again is another seed")
        #expect(fixture.undo.undoActionName == "Remove Object Again" && fixture.rows[0].caption == nil)
        fixture.undo.undo()
        #expect(fixture.removals.first?.patch == made.patch && fixture.removals.first?.isOn == false)
        fixture.undo.redo()
        #expect(fixture.removals == [again] && steps.runs.count == 2)

        model.remakeRemoval(made.id, better: true, on: frame)
        await model.removalsSettled()
        let better = try #require(fixture.removals.first)
        #expect(better.id == made.id && !better.isOn && !better.includesEffects && better.patch.id != again.patch.id)
        #expect(steps.retried == [made.patch.id, again.patch.id], "made again from the patch it has now")
        #expect(steps.runs.count == 3 && steps.runs[2].steps == RemovalJob.betterSteps && steps.runs[2].guidance == RemovalJob.betterGuidance)
        #expect(fixture.undo.undoActionName == "Remove Object Better")
        fixture.undo.undo()
        #expect(fixture.removals == [again])
        // Every patch a step can return to is kept.
        #expect(model.patchesInUse.isSuperset(of: [made.patch.id, again.patch.id, better.patch.id]))
    }

    @Test func aCancelOfEachStopsItsRunAndTheOldPixelsStay() async throws {
        let gate = RunGate()
        let fixture = try await RemoveFixture(gate: gate)
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps

        // A run with no patch yet: its row goes, and nothing reaches the edit.
        model.removeObject(on: frame)
        await gate.arrived(1)
        let pending = try #require(fixture.rows.first)
        model.cancelRemoval(pending.id, on: frame)
        #expect(fixture.rows.isEmpty && model.remove.pending.isEmpty)
        await model.removalsSettled()
        #expect(fixture.removals.isEmpty && steps.stored.isEmpty && !fixture.undo.canUndo && gate.holding == 0)

        model.removeObject(on: frame)
        await gate.arrived(2)
        gate.release()
        await model.removalsSettled()
        let made = try #require(fixture.removals.first)

        // A removal being made again: it keeps its row, its controls and its pixels while it runs, and after the cancel.
        model.remakeRemoval(made.id, better: false, on: frame)
        await gate.arrived(3)
        var row = try #require(fixture.rows.first)
        #expect(fixture.rows.count == 1 && !row.isPending && row.caption?.isBusy == true && row.canCancel && row.canToggle && !row.canRemake)
        #expect(fixture.removals == [made])
        model.remakeRemoval(made.id, better: true, on: frame)
        #expect(steps.runs.count == 3, "one run of a removal at a time")
        model.cancelRemoval(made.id, on: frame)
        row = try #require(fixture.rows.first)
        #expect(row.caption == nil && row.canRemake)
        await model.removalsSettled()
        #expect(fixture.removals == [made] && steps.stored == [made.patch.id] && fixture.undo.undoActionName == "Remove Object")

        // Escape takes the newest run first, and says when there is none.
        #expect(!model.cancelNewestRemoval(on: frame))
        model.removeObject(at: 0.2, on: frame)
        model.removeObject(at: 0.6, on: frame)
        await gate.arrived(4)
        let two = fixture.rows.filter(\.isPending)
        #expect(two.count == 2 && two[1].caption == .queued)
        #expect(model.cancelNewestRemoval(on: frame))
        #expect(fixture.rows.filter(\.isPending).map(\.id) == [two[0].id])
        #expect(model.cancelNewestRemoval(on: frame))
        #expect(fixture.rows.filter(\.isPending).isEmpty && !model.cancelNewestRemoval(on: frame))
        await model.removalsSettled()
        #expect(fixture.removals == [made] && steps.runs.count == 4, "the run behind the cancelled one never started")
    }

    @Test func aFailedRunSaysWhyAndKeepsWhatWasThere() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps

        // A new removal: its row goes, the selection comes back for another Return, and the notice says why.
        steps.failNext(RemovalRunFailure.failed("out of memory"))
        model.removeObject(on: frame)
        await model.removalsSettled()
        #expect(fixture.removals.isEmpty && fixture.rows.isEmpty && !fixture.undo.canUndo)
        #expect(model.remove.selection.canRemove, "what was selected is selected again")
        #expect(model.clipboardNotice?.kind == .failed && model.clipboardNotice?.text == "Could not remove the object")
        #expect(model.clipboardNotice?.details == ["The removal failed: out of memory"])
        model.dismissClipboardNotice()
        model.commitRemoval(on: frame)
        await model.removalsSettled()
        let made = try #require(fixture.removals.first)
        #expect(steps.runs.count == 2 && model.clipboardNotice == nil)

        // A removal made again: its old pixels stay, and its row says why and offers Try Again.
        steps.failNext(RemovalRunFailure.unresponsive)
        model.remakeRemoval(made.id, better: false, on: frame)
        await model.removalsSettled()
        var row = try #require(fixture.rows.first)
        #expect(row.caption == .failed("The model stopped answering") && row.caption?.text == "Could not remove it")
        #expect(row.canRemake && row.canToggle && row.canDelete && !row.canCancel && !row.isPending)
        #expect(fixture.removals == [made] && fixture.undo.undoActionName == "Remove Object")
        model.remakeRemoval(made.id, better: false, on: frame)
        await model.removalsSettled()
        row = try #require(fixture.rows.first)
        #expect(row.caption == nil && fixture.removals.first?.patch.id != made.patch.id)

        // No engine: nothing is tried, the selection stays, and the tab knows why.
        steps.engine = .absent("No model in this build")
        let before = steps.runs.count
        model.paintRemoval([CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.55, y: 0.5)], on: frame)
        model.commitRemoval(on: frame)
        #expect(steps.runs.count == before && fixture.rows.count == 1 && model.remove.selection.canRemove)
        #expect(model.clipboardNotice?.details == ["No model in this build"] && model.remove.engine == .absent("No model in this build"))
        model.dismissClipboardNotice()
        model.remakeRemoval(made.id, better: true, on: frame)
        #expect(steps.runs.count == before && fixture.rows.first?.caption == .failed("No model in this build"))
    }

    @Test func theEyeTheSwitchDeleteAndResetAreEachOneStep() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        model.removeObject(at: 0.2, on: frame)
        model.removeObject(at: 0.6, on: frame)
        await model.removalsSettled()
        let made = fixture.removals
        try #require(made.count == 2 && fixture.rows.map(\.number) == [1, 2])

        model.setRemoval(made[0].id, isOn: false, on: frame)
        #expect(fixture.rows[0].isOn == false && fixture.rows[1].isOn && fixture.undo.undoActionName == "Turn Removal Off")
        #expect(fixture.removals[0].patch == made[0].patch)
        fixture.undo.undo()
        #expect(fixture.removals == made && fixture.undo.undoActionName == "Remove Object")
        fixture.undo.redo()
        model.setRemoval(made[0].id, isOn: true, on: frame)
        #expect(fixture.removals == made && fixture.undo.undoActionName == "Turn Removal On")

        model.setRemoval(made[1].id, includesEffects: false, on: frame)
        #expect(fixture.rows[1].includesEffects == false && fixture.rows[0].includesEffects)
        #expect(fixture.undo.undoActionName == "Exclude Shadow and Reflections")
        model.setRemoval(made[1].id, includesEffects: true, on: frame)
        #expect(fixture.removals == made && fixture.undo.undoActionName == "Include Shadow and Reflections")
        // What is already so is no step.
        model.setRemoval(made[1].id, includesEffects: true, on: frame)
        model.setRemoval(made[0].id, isOn: true, on: frame)
        fixture.undo.undo()
        #expect(fixture.rows[1].includesEffects == false)
        fixture.undo.redo()

        model.deleteRemoval(made[0].id, on: frame)
        #expect(fixture.removals == [made[1]] && fixture.rows == [RemovalRowState(id: made[1].id, number: 1)])
        #expect(fixture.undo.undoActionName == "Delete Removal")
        fixture.undo.undo()
        #expect(fixture.removals == made)

        #expect(model.canResetRemovals(frame))
        model.resetRemovals(for: frame)
        #expect(fixture.removals.isEmpty && fixture.rows.isEmpty && !model.canResetRemovals(frame))
        #expect(model.manualAdjustments(for: frame).exposureEV == 0.5, "Reset on the Remove tab takes the removals alone")
        #expect(fixture.undo.undoActionName == "Reset Removals")
        fixture.undo.undo()
        #expect(fixture.removals == made)
        #expect(steps.runs.count == 2 && steps.stored.count == 2, "none of these runs the model")
    }

    @Test func resetOnTheTabStopsTheFramesRunsToo() async throws {
        let gate = RunGate()
        let fixture = try await RemoveFixture(gate: gate)
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame
        model.removeObject(on: frame)
        await gate.arrived(1)
        #expect(model.canResetRemovals(frame), "a run under way is something of Remove's to take away")
        model.resetRemovals(for: frame)
        #expect(fixture.rows.isEmpty)
        await model.removalsSettled()
        #expect(fixture.removals.isEmpty && !fixture.undo.canUndo && !model.canResetRemovals(frame))
    }

    @Test func aRemovalsCropHoldsTheRemovalsBeforeItAndNoOther() async throws {
        let gate = RunGate()
        let fixture = try await RemoveFixture(gate: gate)
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps

        model.removeObject(at: 0.2, on: frame)
        model.removeObject(at: 0.6, on: frame)
        let asked = fixture.rows
        #expect(asked.map(\.number) == [1, 2] && asked[0].caption == .removing(step: 0, of: RemovalJob.defaultSteps) && asked[1].caption == .queued)
        await gate.arrived(1)
        #expect(steps.crops.count == 1 && steps.crops[0].removals.isEmpty, "the second is planned in its turn, not at Return")

        gate.release()
        await gate.arrived(2)
        let first = try #require(fixture.removals.first)
        #expect(fixture.removals.count == 1 && first.id == asked[0].id)
        #expect(steps.crops.count == 2 && steps.crops[1].removals == [first.id], "the second sees the first, and not itself")
        #expect(steps.crops[1].box != steps.crops[0].box)
        let rows = fixture.rows
        #expect(rows.map(\.number) == [1, 2] && !rows[0].isPending && rows[1].isPending && rows[1].id == asked[1].id)
        gate.release()
        await model.removalsSettled()
        let second = try #require(fixture.removals.last)
        #expect(fixture.removals.map(\.id) == [first.id, second.id] && second.id == asked[1].id)

        // Made again, the first sees neither itself nor the second; the second sees the first as it is now.
        model.remakeRemoval(first.id, better: false, on: frame)
        await gate.arrived(3)
        #expect(steps.crops.count == 3 && steps.crops[2].removals.isEmpty && steps.crops[2].box == steps.crops[0].box)
        gate.release()
        await model.removalsSettled()
        model.remakeRemoval(second.id, better: false, on: frame)
        await gate.arrived(4)
        #expect(steps.crops.count == 4 && steps.crops[3].removals == [first.id] && steps.crops[3].box == steps.crops[1].box)
        gate.release()
        await model.removalsSettled()
        #expect(fixture.removals.map(\.id) == [first.id, second.id])
        #expect(fixture.removals[0].patch != first.patch && fixture.removals[1].patch != second.patch)
    }

    @Test func aPatchThatArrivesDuringADragWaitsForItsEndAndIsItsOwnStep() async throws {
        let gate = RunGate()
        let fixture = try await RemoveFixture(gate: gate)
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame
        model.removeObject(on: frame)
        await gate.arrived(1)
        // A Light row's drag is open when the patch arrives.
        model.beginLightAdjusting(for: frame)
        model.moveLight(.light(.exposure), to: 1.25, for: frame)
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            model.removalRuns.observeGestureWait = { _ in
                model.removalRuns.observeGestureWait = nil
                waiting.resume()
            }
            gate.release()
        }
        #expect(fixture.removals.isEmpty && fixture.rows.count == 1 && fixture.rows[0].isPending, "the drag is not cut in two")
        fixture.undo.beginUndoGrouping()
        model.endLightAdjusting(for: frame)
        fixture.undo.endUndoGrouping()
        await model.removalsSettled()
        #expect(fixture.removals.count == 1 && model.manualAdjustments(for: frame).exposureEV == 1.25)
        #expect(fixture.undo.undoActionName == "Remove Object")
        fixture.undo.undo()
        #expect(fixture.removals.isEmpty && model.manualAdjustments(for: frame).exposureEV == 1.25 && fixture.undo.undoActionName == "Adjust Frame")
        fixture.undo.undo()
        #expect(model.manualAdjustments(for: frame).exposureEV == 0.5 && !fixture.undo.canUndo)
    }

    @Test func aRowsCaptionIsReadFromItsPatch() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        // A face redrawn, a large box and another decoder: one caption, the first that applies.
        steps.face = [0.6, 0.2, 0.1, 0.2]
        steps.soft = true
        model.removeObject(on: frame)
        await model.removalsSettled()
        let made = try #require(fixture.removals.first)
        #expect(fixture.rows[0].caption == .redrewFace)
        steps.face = nil
        model.remakeRemoval(made.id, better: false, on: frame)
        await model.removalsSettled()
        #expect(fixture.rows[0].caption == .soft)
        steps.frameDecoder = "decoder-2"
        model.removeTabShown(for: frame)
        #expect(fixture.rows[0].caption == .olderDecode, "the frame goes to another decoder than the patch was cut from")
        steps.decoder = "decoder-2"
        model.remakeRemoval(made.id, better: false, on: frame)
        await model.removalsSettled()
        #expect(fixture.rows[0].caption == .soft, "made again on the decode as it is now")
        model.resetRemovals(for: frame)
        steps.soft = false
        model.removeObject(on: frame)
        await model.removalsSettled()
        #expect(fixture.rows.count == 1 && fixture.rows[0].caption == nil)

        // An edit that names a patch the library does not hold, as a recipe read on another Mac would.
        let held = try #require(steps.patch(fixture.removals[0].patch.id))
        steps.lose(held.identity)
        model.clearRemoveSession()
        _ = fixture.rows
        await model.removalsSettled()
        var row = try #require(fixture.rows.first)
        #expect(row.caption == .missing && !row.canToggle && row.canDelete)
        let runs = steps.runs.count
        model.remakeRemoval(row.id, better: false, on: frame)
        #expect(steps.runs.count == runs && fixture.rows[0].caption == .missing, "a patch that is not there cannot be made again from itself")
        // Its pack put back beside the raw: the tab reads it again when it next shows the frame.
        _ = try steps.store(held)
        model.removeTabShown(for: frame)
        await model.removalsSettled()
        row = try #require(fixture.rows.first)
        #expect(row.caption == nil && row.canToggle)
    }

    @Test func aRemovalIsOutlinedOverItsBoxAndItsFaceIsShownAtFullSize() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        steps.face = [0.7, 0.1, 0.1, 0.2]
        model.removeObject(on: frame)
        await model.removalsSettled()
        let made = try #require(fixture.removals.first), box = try #require(steps.crops.first?.box)
        let outline = try #require(model.removalOutline(made.id, on: frame))
        #expect(outline.width == FakeRemovalSteps.side && outline.height == FakeRemovalSteps.side && outline.values.allSatisfy { $0 == 255 })
        let expected = CGRect(x: Double(box.x) / 6000, y: Double(box.y) / 4000, width: Double(box.width) / 6000, height: Double(box.height) / 4000)
        #expect(abs(outline.frame.minX - expected.minX) < 1e-9 && abs(outline.frame.minY - expected.minY) < 1e-9)
        #expect(abs(outline.frame.width - expected.width) < 1e-9 && abs(outline.frame.height - expected.height) < 1e-9)
        #expect(model.removalOutline(UUID(), on: frame) == nil)

        // The face link: Actual Size, the face's middle in the area's.
        model.openFrame()
        let room = FrameZoom.Room(area: CGSize(width: 900, height: 600), fitted: CGSize(width: 900, height: 600), fitPixels: 1800, fullPixels: 6000,
                                  displayScale: 2)
        model.frameZoomRoom = room
        model.showRemovalFace(made.id, on: frame)
        let zoom = model.frameZoom
        #expect(!zoom.isFitted && abs(zoom.scale - room.actualScale) < 1e-6)
        #expect(abs(zoom.offset.width + 0.25 * 900 * zoom.scale) < 1 && abs(zoom.offset.height - 0.3 * 600 * zoom.scale) < 1)
        // A removal that redrew no face has no face to go to.
        model.frameZoom = FrameZoom()
        steps.face = nil
        model.remakeRemoval(made.id, better: false, on: frame)
        await model.removalsSettled()
        model.showRemovalFace(made.id, on: frame)
        #expect(model.frameZoom.isFitted)
    }
}
