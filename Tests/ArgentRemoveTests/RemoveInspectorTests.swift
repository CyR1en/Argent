import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import SwiftUI
import Testing
@testable import ArgentApp

/// The Remove tab (docs/remove-plan.md, section 4.8): its place on the strip and where it is kept; for each kind of row which
/// controls it shows and enables and which of the model's commands each is; the row's menu, the same table; what VoiceOver
/// reads; which row is open; the tab's Reset; and that everything it draws fits the inspector's column.
@MainActor @Suite(.serialized) struct RemoveInspectorTests {
    typealias Row = RemovalRowState

    // MARK: The strip

    @Test func theStripHasFiveTabsInTheirOrderAndRemoveSaysItsKey() {
        #expect(AdjustInspectorTab.showsRemove)
        #expect(AdjustInspectorTab.allCases == [.light, .curve, .masks, .lens, .remove])
        #expect(AdjustInspectorTab.allCases.map(\.title) == ["Light", "Curve", "Masks", "Lens", "Remove"])
        #expect(AdjustInspectorTab.remove.accessibilityLabel == "Remove objects")
        #expect(AdjustInspectorTab.remove.help == "Remove an object from this frame (Q)")
        // The others say what they said.
        #expect(AdjustInspectorTab.light.help.hasSuffix("(⌥⌘1)") && AdjustInspectorTab.lens.help == "Lens corrections (⌥⌘4)")
        #expect(AdjustInspectorTab.masks.help == "Change one part of this frame (⇧W, ⌥⌘3)")
    }

    @Test func aStoredRemoveOpensOnRemove() {
        let defaults = ScratchDefaults()
        defaults.set("remove", forKey: AdjustInspectorTab.storageKey)
        #expect(AdjustInspectorTab.stored(in: defaults) == .remove)
        #expect(AdjustInspectorTab(rawValue: "remove") == .remove)
    }

    // MARK: A row's controls

    private static let id = UUID()

    /// Every kind of row the tab shows.
    private static let made = Row(id: id, number: 1)
    private static let hidden = Row(id: id, number: 1, isOn: false)
    private static let pending = Row(id: id, number: 2, isPending: true, caption: .removing(step: 1, of: 8))
    private static let again = Row(id: id, number: 1, caption: .removing(step: 2, of: 8))
    private static let failed = Row(id: id, number: 1, caption: .failed("The model stopped answering."))
    private static let missing = Row(id: id, number: 1, caption: .missing)
    private static let face = Row(id: id, number: 1, caption: .redrewFace)
    private static let soft = Row(id: id, number: 1, caption: .soft)

    private static func enabled(_ row: Row, canAdjust: Bool = true) -> [RemoveRowAction] {
        RemoveRowAction.shown(for: row).filter { $0.isEnabled(for: row, canAdjust: canAdjust) }
    }

    @Test func eachKindOfRowShowsAndEnablesItsOwnControls() {
        typealias Action = RemoveRowAction
        let whole: [Action] = [.toggle, .effects, .tryAgain, .better, .delete]
        let table: [(String, Row, shown: [Action], enabled: [Action])] = [
            ("made", Self.made, whole, whole),
            ("hidden", Self.hidden, whole, whole),
            ("soft", Self.soft, whole, whole),
            ("failed", Self.failed, whole, whole),
            // A run with no patch yet: its caption and Cancel, and nothing else.
            ("pending", Self.pending, [.cancel], [.cancel]),
            // Made again, it keeps its controls and can be cancelled, and is not made a third time meanwhile.
            ("being made again", Self.again, [.toggle, .effects, .tryAgain, .better, .cancel, .delete], [.toggle, .effects, .cancel, .delete]),
            // A patch that is missing shows nothing to turn on or off.
            ("missing", Self.missing, whole, [.tryAgain, .better, .delete]),
            ("a face", Self.face, [.toggle, .effects, .tryAgain, .better, .face, .delete], [.toggle, .effects, .tryAgain, .better, .face, .delete]),
        ]
        for (name, row, shown, enabled) in table {
            #expect(Action.shown(for: row) == shown, "\(name)")
            #expect(Self.enabled(row) == enabled, "\(name)")
        }
        // Each by the row's own rule, and nothing of the model's.
        for row in [Self.made, Self.hidden, Self.pending, Self.again, Self.failed, Self.missing, Self.face, Self.soft] {
            #expect(Action.toggle.isEnabled(for: row) == row.canToggle && Action.effects.isEnabled(for: row) == row.canToggle)
            #expect(Action.tryAgain.isEnabled(for: row) == row.canRemake && Action.better.isEnabled(for: row) == row.canRemake)
            #expect(Action.delete.isEnabled(for: row) == row.canDelete && Action.cancel.isEnabled(for: row) == row.canCancel)
            #expect(Action.face.isEnabled(for: row) == (row.caption?.opensFace == true))
        }
        // On a frame that cannot be adjusted nothing changes the edit; a run can still be stopped and a face looked at.
        #expect(Self.enabled(Self.made, canAdjust: false).isEmpty)
        #expect(Self.enabled(Self.again, canAdjust: false) == [.cancel])
        #expect(Self.enabled(Self.pending, canAdjust: false) == [.cancel])
        #expect(Self.enabled(Self.face, canAdjust: false) == [.face])
    }

    @Test func eachControlIsOneOfTheModelsCommands() async throws {
        let bench = try await RemoveBench()
        defer { bench.finish() }
        func call(_ action: RemoveRowAction, on row: Row) -> [String] {
            let recorder = RemoveRecorder()
            action.perform(on: row, frame: bench.frame, with: recorder)
            #expect(recorder.ids.allSatisfy { $0 == row.id } && recorder.frames.allSatisfy { $0 == bench.frame.url })
            return recorder.calls
        }
        // The eye turns the row the other way, and the switch likewise.
        #expect(call(.toggle, on: Self.made) == ["setRemoval isOn false"])
        #expect(call(.toggle, on: Self.hidden) == ["setRemoval isOn true"])
        #expect(call(.effects, on: Self.made) == ["setRemoval includesEffects false"])
        #expect(call(.effects, on: Row(id: Self.id, number: 1, includesEffects: false)) == ["setRemoval includesEffects true"])
        #expect(call(.tryAgain, on: Self.made) == ["remakeRemoval better false"])
        #expect(call(.better, on: Self.made) == ["remakeRemoval better true"])
        #expect(call(.delete, on: Self.made) == ["deleteRemoval"])
        #expect(call(.cancel, on: Self.pending) == ["cancelRemoval"])
        #expect(call(.cancel, on: Self.again) == ["cancelRemoval"])
        #expect(call(.face, on: Self.face) == ["showRemovalFace"])
        // What a row does not let be used asks for nothing.
        #expect(call(.delete, on: Self.pending).isEmpty && call(.tryAgain, on: Self.again).isEmpty)
        #expect(call(.toggle, on: Self.missing).isEmpty && call(.cancel, on: Self.made).isEmpty && call(.face, on: Self.soft).isEmpty)
        // The model is what the row asks in the app.
        let model: any RemoveCommands = bench.model
        #expect(model === bench.model)
    }

    @Test func theControlsSayWhatTheyAre() {
        #expect(RemoveRowAction.allCases.map { $0.title(for: Self.made) }
                == ["Turn Off", "Include Shadow and Reflections", "Try Again", "Better", "Delete", "Cancel", "Show Face at Full Size"])
        #expect(RemoveRowAction.toggle.title(for: Self.hidden) == "Turn On")
        for action in RemoveRowAction.allCases where action != .face {
            #expect(action.help(for: Self.made).hasSuffix("."), "\(action)")
        }
        // The face note's help is the seam's own sentence.
        #expect(RemoveRowAction.face.help(for: Self.face) == Row.Caption.redrewFace.help)
    }

    // MARK: The row's menu

    @Test func theRowsMenuIsTheSameTable() async throws {
        let bench = try await RemoveBench()
        defer { bench.finish() }
        let recorder = RemoveRecorder()
        let made = InspectorMenus.tablesMade
        func menu(_ row: Row, canAdjust: Bool = true) -> [MenuEntry] {
            InspectorMenus.removalRow(row, frame: bench.frame, canAdjust: canAdjust, commands: recorder)
        }
        #expect(menu(Self.made).titles == ["Turn Off", "Include Shadow and Reflections", "—", "Try Again", "Better", "—", "Delete"])
        #expect(InspectorMenus.tablesMade == made + 1)
        #expect(menu(Self.hidden).titles.first == "Turn On")
        #expect(menu(Self.face).titles == ["Turn Off", "Include Shadow and Reflections", "—", "Try Again", "Better", "—", "Show Face at Full Size", "—", "Delete"])
        #expect(menu(Self.again).titles == ["Turn Off", "Include Shadow and Reflections", "—", "Try Again", "Better", "—", "Cancel", "—", "Delete"])
        #expect(menu(Self.pending).titles == ["Cancel"])
        // The switch is a check, and nothing else is.
        #expect(menu(Self.made).entry("removal.effects")?.isOn == true)
        #expect(menu(Row(id: Self.id, number: 1, includesEffects: false)).entry("removal.effects")?.isOn == false)
        #expect(menu(Self.made).filter { $0.id != "removal.effects" }.allSatisfy { $0.isOn == nil })
        // Enabled as the row's controls are.
        let again = menu(Self.again)
        #expect(again.entry("removal.tryAgain")?.isEnabled == false && again.entry("removal.better")?.isEnabled == false)
        #expect(again.entry("removal.cancel")?.isEnabled == true && again.entry("removal.delete")?.isEnabled == true)
        #expect(menu(Self.missing).entry("removal.toggle")?.isEnabled == false && menu(Self.missing).entry("removal.delete")?.isEnabled == true)
        #expect(menu(Self.made, canAdjust: false).filter { !$0.isDivider }.allSatisfy { !$0.isEnabled })
        // Chosen, each row is its control's call.
        for id in ["removal.toggle", "removal.effects", "removal.tryAgain", "removal.better", "removal.face", "removal.delete"] {
            menu(Self.face).entry(id)?.choose()
        }
        menu(Self.pending).entry("removal.cancel")?.choose()
        menu(Self.again).entry("removal.tryAgain")?.choose()
        #expect(recorder.calls == ["setRemoval isOn false", "setRemoval includesEffects false", "remakeRemoval better false",
                                   "remakeRemoval better true", "showRemovalFace", "deleteRemoval", "cancelRemoval"])
    }

    // MARK: What VoiceOver reads

    @Test func voiceOverReadsTheCaptionWithTheRow() {
        #expect(RemoveRowSpeech.value(Self.made) == "on")
        #expect(RemoveRowSpeech.value(Self.hidden) == "off")
        #expect(RemoveRowSpeech.value(Row(id: Self.id, number: 1, includesEffects: false)) == "on, object only")
        // The face note, whole: its words and its sentence, with no dialog and nothing else to find.
        #expect(RemoveRowSpeech.value(Self.face)
                == "on, Redrew part of a face. This removal drew new pixels inside a face. Look at it at full size before you develop.")
        #expect(RemoveRowSpeech.value(Self.soft) == "on, Soft at full size. The model works at a small size, so a large removal is soft at 100 %.")
        #expect(RemoveRowSpeech.value(Self.again) == "on, Removing… 2 of 8")
        #expect(RemoveRowSpeech.value(Self.pending) == "Removing… 1 of 8")
    }

    // MARK: Which row is open

    @Test func aRemovalThatArrivesOpensAndTheOpenRowStaysWhileItIsThere() {
        let a = Row(id: UUID(), number: 1), b = Row(id: UUID(), number: 2)
        let run = Row(id: UUID(), number: 3, isPending: true, caption: .queued)
        // The tab's first rows: the newest removal is open, never a run.
        #expect(RemoveList.opened(nil, from: [], to: [a, b, run]) == b.id)
        #expect(RemoveList.opened(nil, from: [], to: [run]) == nil)
        #expect(RemoveList.opened(nil, from: [], to: []) == nil)
        // Nothing arrived: what was open stays, and a row closed by hand stays closed.
        #expect(RemoveList.opened(a.id, from: [a, b], to: [a, b]) == a.id)
        #expect(RemoveList.opened(nil, from: [a, b], to: [a, b]) == nil)
        // A caption coming or going is no arrival.
        var soft = a
        soft.caption = .soft
        #expect(RemoveList.opened(b.id, from: [a, b], to: [soft, b]) == b.id)
        // A run's patch is stored, under its own id or a new one: its removal opens.
        let landed = Row(id: run.id, number: 3)
        #expect(RemoveList.opened(a.id, from: [a, b, run], to: [a, b, landed]) == run.id)
        let renamed = Row(id: UUID(), number: 3)
        #expect(RemoveList.opened(a.id, from: [a, b, run], to: [a, b, renamed]) == renamed.id)
        // The open row deleted: none is.
        #expect(RemoveList.opened(a.id, from: [a, b], to: [b]) == nil)
    }

    // MARK: The pane's words and rules

    @Test func snapToObjectSaysWhatItDoesOrWhyItCannot() {
        #expect(RemoveCopy.snapHelp(.ready).hasPrefix("A stroke or a click selects the whole object"))
        #expect(RemoveCopy.snapHelp(.downloading).contains("downloading"))
        #expect(RemoveCopy.snapHelp(.unavailable("Snap to Object is not built yet")) == "Snap to Object is not built yet. The selection is what you paint.")
        #expect(RemoveCopy.snapHelp(.unavailable("This Mac has no segmenter.")) == "This Mac has no segmenter. The selection is what you paint.")
        #expect(RemoveCopy.hint == "Paint over an object, or click it.")
    }

    @Test func removeWaitsForSomethingSelectedOnAFrameThatCanTakeIt() async throws {
        let bench = try await RemoveBench()
        defer { bench.finish() }
        let model = bench.model, frame = bench.frame
        #expect(RemovePhotograph.frame(model)?.url == frame.url)
        #expect(!RemovePhotograph.canRemove(on: frame, model: model))
        model.remove.selection.coverage = RemoveCoverage(width: 2, height: 2, values: [255, 255, 0, 0])
        #expect(RemovePhotograph.canRemove(on: frame, model: model))
        model.remove.selection.isSnapping = true
        #expect(!RemovePhotograph.canRemove(on: frame, model: model))
        model.remove.selection.isSnapping = false
        bench.block(true)
        #expect(!RemovePhotograph.canRemove(on: frame, model: model))
        bench.block(false)
        // Escape takes what is in hand before the frame closes; with nothing selected and no run it goes on.
        #expect(RemovePhotograph.escape(model))
        model.remove.selection.coverage = nil
        #expect(!RemovePhotograph.escape(model))
        // On another tab the brush is in nobody's hand.
        model.adjustTab = .light
        #expect(RemovePhotograph.frame(model) == nil && !RemovePhotograph.escape(model))
        model.adjustTab = .remove
        model.isAdjustmentsShown = false
        #expect(RemovePhotograph.frame(model) == nil)
    }

    /// ] and [ are the masks' brush's keys, and the Remove brush's while its tab shows: the same steps on the session's size.
    @Test func theBrushesKeysStepTheRemoveBrushOnItsTab() async throws {
        let bench = try await RemoveBench()
        defer { bench.finish() }
        let model = bench.model
        #expect(model.remove.brushSize == 4)
        model.stepBrush { $0.larger() }
        #expect(model.remove.brushSize == 5)
        model.stepBrush { $0.smaller() }
        #expect(model.remove.brushSize == 4)
        model.remove.brushSize = 0.2
        model.stepBrush { $0.smaller() }
        #expect(model.remove.brushSize == 0.2)
        model.stepBrush { $0.larger() }
        #expect(model.remove.brushSize == 0.3)
        // Feather and Flow are the masks' brush's alone.
        model.stepBrush { $0.feathered(by: 1) }
        model.stepBrush { $0.flow(digit: 3) }
        #expect(model.remove.brushSize == 0.3)
        // On another tab they are the masks' brush's, which is not in hand.
        model.adjustTab = .masks
        let masks = model.maskEditor.brush.settings
        model.stepBrush { $0.larger() }
        #expect(model.remove.brushSize == 0.3 && model.maskEditor.brush.settings == masks)
        #expect(AdjustmentSliderSpec.removeBrushSize.defaultValue == 4 && AdjustmentSliderSpec.removeBrushSize.group == .brush)
        #expect(AdjustmentSliderSpec.removeBrushSize.range == MaskBrushSettings.sizeRange)
    }

    // MARK: Reset and the ground

    @Test func theTabsGroundAndItsResetAreTheOthersManner() async throws {
        let bench = try await RemoveBench()
        defer { bench.finish() }
        let ground = InspectorMenus.ground(of: .remove, frame: bench.frame, model: bench.model)
        #expect(ground.titles == ["Copy Adjustments", "Paste Adjustments", "Paste Only", "—", "Reset Removals"])
        let resets = InspectorMenus.resets(of: .remove, frame: bench.frame, model: bench.model)
        #expect(resets.map(\.id) == ["adjust.resetRemovals"] && resets.map(\.title) == ["Reset Removals"])
        // By the button's rule: something to delete, as the model says, on a frame that can be adjusted. The model has nothing
        // until package E builds it.
        #expect(resets[0].isEnabled == (bench.model.canAdjust(bench.frame) && bench.model.canResetRemovals(bench.frame)))
        #expect(InspectorMenus.canResetRemovals(bench.frame, model: bench.model) == bench.model.canResetRemovals(bench.frame))
        bench.block(true)
        #expect(!InspectorMenus.canResetRemovals(bench.frame, model: bench.model))
        // The foot's Reset on this tab: the removals' own, then the return to the starting point.
        #expect(InspectorMenus.resetMenu(of: .remove, frame: bench.frame, model: bench.model).titles == ["Reset Removals", "—", "Reset to Current Auto"])
        #expect(RemoveCopy.count(1) == "1 removal" && RemoveCopy.count(3) == "3 removals")
    }

    // MARK: As it is drawn

    private func size(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// A row keeps its height whether or not it has a caption, and its options add their own.
    @Test func aRowKeepsItsHeightWhateverItsCaption() async throws {
        let bench = try await RemoveBench()
        defer { bench.finish() }
        _ = NSApplication.shared
        func height(_ row: Row, open: Bool = false) -> CGFloat {
            size(RemoveRow(frame: bench.frame, row: row, isOpen: open, canAdjust: true) {}.environment(bench.model).frame(width: 240)).height
        }
        for row in [Self.made, Self.hidden, Self.soft, Self.face, Self.missing, Self.failed, Self.again, Self.pending] {
            #expect(height(row) == RemoveRow.height, "\(String(describing: row.caption))")
        }
        #expect(height(Self.made, open: true) == RemoveRow.height + RemoveRow.optionsHeight)
        #expect(height(Self.again, open: true) == height(Self.made, open: true))
        // A run has no options to open.
        #expect(height(Self.pending, open: true) == RemoveRow.height)
        #expect(RemoveRow.height(of: Self.made, isOpen: true) == height(Self.made, open: true))
    }

    /// Every row at its own width fits the inspector's 240 points: the longest caption, a wait with its bar and Cancel, and an
    /// open row's switch and buttons.
    @Test func everyRowOfTheRemoveTabFitsItsColumn() async throws {
        let bench = try await RemoveBench()
        defer { bench.finish() }
        _ = NSApplication.shared
        func width(_ row: Row, open: Bool) -> CGFloat {
            size(RemoveRow(frame: bench.frame, row: row, isOpen: open, canAdjust: true) {}.environment(bench.model).fixedSize()).width
        }
        let captions: [Row.Caption] = [.preparing(1), .preparing(nil), .loading, .waitingForDevelop, .queued, .removing(step: 20, of: 20),
                                       .failed("why"), .missing, .redrewFace, .olderDecode, .soft]
        for caption in captions {
            let removal = Row(id: Self.id, number: 64, caption: caption), run = Row(id: Self.id, number: 64, isPending: true, caption: caption)
            #expect(width(removal, open: false) <= 240, "\(caption.text) takes \(width(removal, open: false))")
            #expect(width(removal, open: true) <= 240, "\(caption.text), open, takes \(width(removal, open: true))")
            #expect(width(run, open: false) <= 240, "\(caption.text), a run, takes \(width(run, open: false))")
        }
    }

    /// The tab as the inspector draws it: the brush's one row, the session's size on it, and none of another tab's.
    @Test func theTabDrawsTheBrushAtTheSessionsSize() async throws {
        let bench = try await RemoveBench()
        defer { bench.finish() }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ManualAdjustmentsView(frame: bench.frame).environment(bench.model))
        let root = try #require(window.contentView)
        func sliders(_ group: AdjustmentSliderGroup) -> [AdjustmentSliderControl] {
            root.layoutSubtreeIfNeeded()
            return AdjustmentSliderControl.sliders(in: group, under: root)
        }
        await RemoveBench.turns { !sliders(.brush).isEmpty }
        #expect(sliders(.brush).map(\.spec) == [.removeBrushSize])
        #expect(sliders(.brush).first?.doubleValue == 4 && sliders(.brush).first?.isEnabled == true)
        #expect(sliders(.light).isEmpty && sliders(.mask).isEmpty && sliders(.lens).isEmpty)
        // The slider writes the session, in its own tenths.
        let size = try #require(sliders(.brush).first)
        #expect(size.accessibilityPerformIncrement())
        #expect(bench.model.remove.brushSize == 4.1)
        // A frame that cannot be adjusted has nothing to paint with.
        bench.block(true)
        await RemoveBench.turns { sliders(.brush).first?.isEnabled == false }
        #expect(sliders(.brush).first?.isEnabled == false)
    }
}
