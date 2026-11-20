@testable import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

/// Section 4.1's guards in the app, on removals the model made (docs/remove-plan.md): a copy holds none, a paste never moves or
/// drops one, each reset keeps or deletes them as the plan says, and with several frames selected Remove acts on the lead alone.
/// A paste of everything pins anew, which needs a stock: `RemoveRollTests` has it.
@MainActor @Suite(.serialized) struct RemoveGuardStateTests {
    /// A step of the test's own, grouped by hand as `ManualStateTests` groups them.
    private func step(_ model: RollModel, _ change: () -> Void) {
        model.manualUndoManager?.beginUndoGrouping()
        change()
        model.manualUndoManager?.endUndoGrouping()
    }

    @Test func aCopyHoldsNoRemovalAndAPasteOfLensKeepsTheFramesOwn() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame
        model.removeObject(on: frame)
        await model.removalsSettled()
        let made = fixture.removals
        try #require(made.count == 1)

        let copy = model.clipboard(of: frame)
        #expect(copy.adjustments.removals.isEmpty && copy.adjustments.exposureEV == 0.5)
        #expect(copy.parts.contains(.light) && !copy.parts.contains(.lens), "a removal is not a lens value to paste")
        model.copyAdjustments(from: frame)
        #expect(model.adjustmentsClipboard?.adjustments.removals.isEmpty == true)
        model.dismissClipboardNotice()

        // Paste Only > Lens, from a frame with its own lens values: the values come, the removals stay this frame's.
        let other = try #require(model.roll?.frames.last)
        let lens = try LensSettings.default.setting(.vignette, to: 25)
        let copied = AdjustmentsClipboard(source: other.url, sourceName: other.name, origin: .auto,
                                          adjustments: try ManualAdjustments(exposureEV: -1).settingLens(lens), maskNotes: .none,
                                          frameControls: FrameControls())
        let report = try #require(await model.paste(copied, parts: .lens, to: [frame], batch: false)?.value)
        model.dismissClipboardNotice()
        #expect(report.pasted == [frame.url] && report.isUndoable)
        var values = model.manualAdjustments(for: frame)
        #expect(values.lens.vignetting.amount == 25 && values.removals == made && values.exposureEV == 0.5)
        fixture.undo.undo()
        values = model.manualAdjustments(for: frame)
        #expect(values.lens.hasDefaultValues && values.removals == made)
        #expect(fixture.steps.runs.count == 1, "a paste runs no model")
    }

    @Test func theResetsKeepOrDeleteTheRemovalsAsThePlanSays() async throws {
        let lens = try LensSettings.default.setting(.vignette, to: 25)
        let fixture = try await RemoveFixture(try ManualAdjustments(exposureEV: 0.5).settingLens(lens))
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame
        model.removeObject(at: 0.2, on: frame)
        model.removeObject(at: 0.6, on: frame)
        await model.removalsSettled()
        let made = fixture.removals
        try #require(made.count == 2)

        // Reset Lens and Reset Light are about their values alone.
        step(model) { model.resetLens(for: frame) }
        #expect(fixture.removals == made && model.manualAdjustments(for: frame).lens.hasDefaultValues)
        step(model) { model.resetLight(for: frame) }
        #expect(fixture.removals == made && model.manualAdjustments(for: frame).exposureEV == 0)
        #expect(model.hasManualAdjustments(frame), "a frame whose only edit is a removal is edited")

        // Reset to Current Auto clears the whole edit, its removals with it, as one step.
        step(model) { model.resetManualAdjustments(for: frame) }
        #expect(model.manualEdits[frame.url] == nil && fixture.removals.isEmpty && fixture.rows.isEmpty)
        fixture.undo.undo()
        #expect(fixture.removals == made)
        fixture.undo.redo()
        #expect(fixture.removals.isEmpty)
        fixture.undo.undo()

        // Reset to Original likewise, the Original staying the starting point.
        let verified = try SourceDigests.shared.digest(of: frame.url)
        let original = AutomaticBaseline.original(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest", controls: .init(),
                                                  baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        model.manualEdits[frame.url] = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5).settingRemovals(made), baseline: original)
        step(model) { model.startFromOriginal(for: frame, actionName: "Reset to Original") }
        #expect(fixture.removals.isEmpty && model.startingPoint(for: frame) == .original && model.manualAdjustments(for: frame).isIdentity)
        #expect(fixture.undo.undoActionName == "Reset to Original")
        fixture.undo.undo()
        #expect(fixture.removals == made && model.manualAdjustments(for: frame).exposureEV == 0.5)

        // Reset on the Remove tab deletes them alone.
        model.resetRemovals(for: frame)
        #expect(fixture.removals.isEmpty && model.manualAdjustments(for: frame).exposureEV == 0.5 && model.startingPoint(for: frame) == .original)
        #expect(fixture.steps.runs.count == 2, "no reset runs the model")
    }

    @Test func withSeveralFramesSelectedRemoveActsOnTheLeadAlone() async throws {
        let fixture = try await RemoveFixture()
        defer { fixture.close() }
        let model = fixture.model, frame = fixture.frame, steps = fixture.steps
        let other = try #require(model.roll?.frames.last)
        let theirs = Removal(patch: try PatchRef(id: PatchID(hex: String(repeating: "ab", count: 32))!, width: 512, height: 1328))
        try RemoveFixture.pin(other, in: model, adjustments: try ManualAdjustments(exposureEV: -0.3).settingRemovals([theirs]))
        model.changeSelection { $0.selectAll(in: [frame.id, other.id]) }
        try #require(model.selected.count == 2 && model.selection == frame.id && model.canAdjust(other))

        // Nothing of Remove reaches a frame that is selected and not the lead.
        model.removeTabShown(for: other)
        model.paintRemoval([CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.4, y: 0.4)], on: other)
        #expect(model.remove.frame == nil && model.remove.selection.coverage == nil && model.remove.selection.stroke.isEmpty)
        model.commitRemoval(on: other)
        model.remakeRemoval(theirs.id, better: false, on: other)
        model.setRemoval(theirs.id, isOn: false, on: other)
        model.setRemoval(theirs.id, includesEffects: false, on: other)
        model.deleteRemoval(theirs.id, on: other)
        model.resetRemovals(for: other)
        await model.removalsSettled()
        #expect(model.manualAdjustments(for: other).removals == [theirs] && steps.runs.isEmpty && !fixture.undo.canUndo)

        // A selection painted on the lead is the lead's, and Return on another frame removes nothing.
        model.removeTabShown(for: frame)
        model.paintRemoval([CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.4, y: 0.4)], on: frame)
        model.commitRemoval(on: other)
        #expect(steps.runs.isEmpty && model.remove.selection.canRemove)
        model.commitRemoval(on: frame)
        await model.removalsSettled()
        #expect(fixture.removals.count == 1 && steps.crops.map(\.frame) == [frame.url])
        #expect(model.manualAdjustments(for: other).removals == [theirs] && model.selected.count == 2)

        // The lead moves: the selection made on the frame before is dropped, never carried.
        model.paintRemoval([CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.7, y: 0.4)], on: frame)
        #expect(model.remove.selection.canRemove)
        model.selection = other.id
        #expect(model.remove.frame == nil && model.remove.selection.coverage == nil)
        model.commitRemoval(on: other)
        #expect(steps.runs.count == 1)
    }
}
