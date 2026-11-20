import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI

/// The Adjust inspector's context menus (docs/context-menus-plan.md, section 3), each a table of `MenuEntry` made when its menu is
/// asked for, never as its view is drawn. Every row does what a control of the inspector already does, by the same call, so a
/// keyboard and VoiceOver reach all of it there: a row's ⋯ menu and its accessibility actions, a slider's reset, the tabs' Reset
/// buttons and the Edit menu's Copy and Paste Adjustments, the curve graph's Delete key and its Curve shape menu.
@MainActor enum InspectorMenus {
    /// How many tables have been made: none while the inspector is drawn or its sliders move, one as each menu opens (tested). In
    /// every build, so the tests compile in a release build too, as the measuring suites are run.
    private(set) static var tablesMade = 0

    private static func noteMade() { tablesMade &+= 1 }

    // MARK: The Masks tab

    /// A mask's row: what its ⋯ holds, the one table the ⋯ and a right-click on the row both draw. Nothing can be done to a frame
    /// that cannot be adjusted, so then every row is disabled, as the ⋯ is; Duplicate also waits for room for another mask.
    static func maskRow(_ mask: Mask, frame: Frame, canAdjust: Bool, canDuplicate: Bool, model: RollModel) -> [MenuEntry] {
        noteMade()
        let editor = model.maskEditor, id = mask.id, isEnabled = mask.isEnabled
        // Rename and Invert act on the selection, as a click on the row makes it.
        func select() { editor.selection = MaskEditor.Selection(mask: id, component: nil) }
        return MenuEntry.sections([
            [
                .action("mask.rename", "Rename", isEnabled: canAdjust) { select(); editor.renaming = id },
                .action("mask.invert", "Invert", isEnabled: canAdjust) { select(); model.invertSelectedComponent(for: frame) },
                .action("mask.duplicate", "Duplicate", isEnabled: canAdjust && canDuplicate) { model.duplicateMask(id, for: frame) },
                .action("mask.turn", isEnabled ? "Turn Off" : "Turn On", isEnabled: canAdjust) {
                    model.setMaskEnabled(!isEnabled, mask: id, for: frame)
                },
            ],
            [.action("mask.delete", "Delete", isEnabled: canAdjust) { model.deleteMask(id, for: frame) }],
        ])
    }

    /// A component's row: Invert; on a component after the first, Add, Subtract and Intersect, the one it is disabled; and Remove.
    /// The first of a mask is always added, there being nothing before it to subtract from, so it has no operations.
    static func componentRow(_ component: MaskComponent, index: Int, of maskID: UUID, frame: Frame, canAdjust: Bool,
                             model: RollModel) -> [MenuEntry] {
        noteMade()
        let editor = model.maskEditor
        var sections: [[MenuEntry]] = [[
            .action("component.invert", "Invert", isEnabled: canAdjust) {
                editor.selection = MaskEditor.Selection(mask: maskID, component: index)
                model.invertSelectedComponent(for: frame)
            },
        ]]
        if index > 0 {
            sections.append(MaskOperation.allCases.map { operation in
                .action("component.\(operation.rawValue)", operation.title, isEnabled: canAdjust && operation != component.operation) {
                    model.setComponentOperation(operation, component: index, of: maskID, for: frame)
                }
            })
        }
        sections.append([.action("component.remove", "Remove", isEnabled: canAdjust) { model.removeComponent(index, of: maskID, for: frame) }])
        return MenuEntry.sections(sections)
    }

    // MARK: The Remove tab

    /// A removal's row: what its ⋯ holds, the one table the ⋯ and a right-click on the row both draw, and each row what a control
    /// of the row does by the same call (`RemoveRowAction`). Its eye and its shadow switch, Try Again and Better, the way to a
    /// redrawn face, Cancel while it is made again, and Delete; a run with no patch yet has Cancel alone.
    static func removalRow(_ row: RemovalRowState, frame: Frame, canAdjust: Bool, commands: any RemoveCommands) -> [MenuEntry] {
        noteMade()
        let shown = RemoveRowAction.shown(for: row)
        func section(_ actions: [RemoveRowAction]) -> [MenuEntry] {
            actions.filter(shown.contains).map { action in
                .action("removal.\(action.rawValue)", action.title(for: row), isEnabled: action.isEnabled(for: row, canAdjust: canAdjust),
                        isOn: action == .effects ? row.includesEffects : nil) {
                    action.perform(on: row, frame: frame, canAdjust: canAdjust, with: commands)
                }
            }
        }
        return MenuEntry.sections([section([.toggle, .effects]), section([.tryAgain, .better]), section([.face]), section([.cancel]),
                                   section([.delete])])
    }

    // MARK: A slider's row

    /// A slider's row: its reset, by the row's own name ("Reset Exposure"), which a double-click on the name or the knob does too,
    /// then its group's reset when it has one (`group`, Reset Presence on a Presence row). Each disabled while the row is disabled
    /// and while the row's own gesture is under way, the row's own also at its reset value.
    static func sliderRow(title: String, isChanged: Bool, isEnabled: Bool, reset: @escaping () -> Void, group: MenuEntry? = nil) -> [MenuEntry] {
        noteMade()
        let own = MenuEntry.action("slider.reset", "Reset \(title)", isEnabled: isEnabled && isChanged, reset)
        guard var group else { return [own] }
        group.isEnabled = group.isEnabled && isEnabled
        return MenuEntry.sections([[own], [group]])
    }

    // MARK: The tabs' ground

    /// A right-click where a tab has no control: the frame's Copy Adjustments, Paste Adjustments and Paste Only, as the photograph
    /// has them (no batch paste: the frames it would paste on are not in view), then the tab's own resets.
    static func ground(of tab: AdjustInspectorTab?, frame: Frame, model: RollModel) -> [MenuEntry] {
        noteMade()
        return MenuEntry.sections([FrameMenu.adjustments(for: frame, on: .photograph, model: model),
                                   tab == .lens ? [lensDistortion(frame, model: model)] : [], resets(of: tab, frame: frame, model: model)])
    }

    /// Each tab's resets of its own parts, by its button's rule: Reset Light (the Light tab's Reset with Option) and Reset Presence,
    /// Reset Curves, Reset Masks, and Reset Removals.
    static func resets(of tab: AdjustInspectorTab?, frame: Frame, model: RollModel) -> [MenuEntry] {
        switch tab {
        case nil: []
        case .light:
            [.action("adjust.resetLight", "Reset Light", isEnabled: canReset(.light, frame, model: model)) { model.resetLight(for: frame) },
             resetPresence(frame, model: model)]
        case .curve:
            [.action("adjust.resetCurves", "Reset Curves", isEnabled: canReset(.curves, frame, model: model)) { model.resetToneCurves(for: frame) }]
        case .lens:
            [resetLens(frame, model: model)]
        case .masks:
            [.action("adjust.resetMasks", "Reset Masks", isEnabled: canResetMasks(frame, model: model)) { model.resetMasks(for: frame) }]
        case .remove:
            [.action("adjust.resetRemovals", "Reset Removals", isEnabled: canResetRemovals(frame, model: model)) { model.resetRemovals(for: frame) }]
        }
    }

    /// The foot's Reset: the tab's own resets, as its ground has them, then the return to the starting point, by the name the
    /// Frame menu gives it (`FrameMenu.reset`). One menu on every tab, in place of a button that returned to the starting point
    /// on Light and Lens, cleared the tab alone on the others, and on Light and Lens cleared the tab alone with Option held.
    static func resetMenu(of tab: AdjustInspectorTab?, frame: Frame, model: RollModel) -> [MenuEntry] {
        noteMade()
        let whole: MenuEntry = model.startingPoint(for: frame) == .original
            ? .action("frame.reset.original", "Reset to Original", isEnabled: model.canStartFromOriginal(frame)) {
                model.startFromOriginal(for: frame, actionName: "Reset to Original")
            }
            : .action("frame.reset.auto", "Reset to Current Auto", isEnabled: model.canResetManual(frame)) {
                model.resetManualAdjustments(for: frame)
            }
        let undo = model.manualUndoManager.map { manager in
            MenuEntry.action("edit.undo", manager.canUndo ? manager.undoMenuItemTitle : "Undo Last Edit", isEnabled: manager.canUndo) {
                manager.undo()
            }
        }
        return MenuEntry.sections([resets(of: tab, frame: frame, model: model), [whole], [undo].compactMap { $0 }])
    }

    /// The heading's Start from: Auto and Original, the one the frame starts from checked, then what choosing the other
    /// costs. Only the choice not made can be made, and only where it can (`RollModel.canChangeStartingPoint`).
    static func startingPoint(_ frame: Frame, model: RollModel) -> [MenuEntry] {
        noteMade()
        let origin = model.startingPoint(for: frame), canChange = model.canChangeStartingPoint(frame)
        return MenuEntry.sections([
            [
                .action("adjust.start.auto", "Auto", isEnabled: canChange || origin == .auto, isOn: origin == .auto) {
                    model.startFrom(.auto, for: frame)
                },
                .action("adjust.start.original", "Original", isEnabled: canChange || origin == .original, isOn: origin == .original) {
                    model.startFrom(.original, for: frame)
                },
            ],
            [.heading("adjust.start.note", startingPointNote)],
        ])
    }

    /// Under the two starting points: what the other one clears.
    static let startingPointNote = "Changing it clears Light, Curve and Lens adjustments and masks"

    /// Reset Presence, the five cleared and Light, the curves and the masks kept: on the Light tab's ground after Reset Light, and on
    /// a Presence row's menu after the row's own reset.
    static func resetPresence(_ frame: Frame, model: RollModel) -> MenuEntry {
        .action("adjust.resetPresence", "Reset Presence", isEnabled: canReset(.presence, frame, model: model)) { model.resetPresence(for: frame) }
    }

    static func resetLens(_ frame: Frame, model: RollModel) -> MenuEntry {
        .action("adjust.resetLens", "Reset Lens", isEnabled: canReset(.lens, frame, model: model)) { model.resetLens(for: frame) }
    }

    static func lensDistortion(_ frame: Frame, model: RollModel) -> MenuEntry {
        let isOn = model.lensSettings(for: frame).distortion.isOn
        return .action("lens.distortion", "Distortion", isEnabled: model.canSetDistortion(frame), isOn: isOn) {
            model.setDistortion(!isOn, for: frame)
        }
    }

    /// Reset Light, Reset Presence or Reset Curves: something of `part` to clear, on a frame that can be adjusted.
    static func canReset(_ part: ManualAdjustments.Parts, _ frame: Frame, model: RollModel) -> Bool {
        model.canAdjust(frame) && model.manualAdjustments(for: frame).heldParts.contains(part)
    }

    /// Reset Masks: a mask to remove, on a frame that can be adjusted.
    static func canResetMasks(_ frame: Frame, model: RollModel) -> Bool {
        model.canAdjust(frame) && !model.masks(for: frame).isEmpty
    }

    /// Reset Removals: a removal to delete (`RollModel.canResetRemovals`), on a frame that can be adjusted.
    static func canResetRemovals(_ frame: Frame, model: RollModel) -> Bool {
        model.canAdjust(frame) && model.canResetRemovals(frame)
    }

    // MARK: The curve graph

    /// The four starting shapes, the one table the Curve shape menu and the graph's menu both draw. No Reset Curve beside them:
    /// Linear is that channel's reset, exactly (`ToneCurves.Preset.linear` is `ChannelCurve.identity`, points and regions).
    static func curvePresets(isEnabled: Bool, choose: @escaping (ToneCurves.Preset) -> Void) -> [MenuEntry] {
        noteMade()
        return ToneCurves.Preset.allCases.map { preset in
            .action("curve.preset.\(preset.rawValue)", preset.title, isEnabled: isEnabled) { choose(preset) }
        }
    }

    /// What the Curve tab gives the graph's menu: the presets, then Reset Curves.
    static func curveShape(presets: [MenuEntry], frame: Frame, model: RollModel) -> [MenuEntry] {
        MenuEntry.sections([presets, resets(of: .curve, frame: frame, model: model)])
    }

    /// The graph's menu: on a point, Delete Point first (an endpoint's disabled, since the endpoints stay); anywhere, `shape`.
    static func curveGraph(deletePoint: MenuEntry?, shape: [MenuEntry]) -> [MenuEntry] {
        MenuEntry.sections([deletePoint.map { [$0] } ?? [], shape])
    }

    /// Delete Point, which does what Delete does on the point.
    static func deletePoint(isEnabled: Bool, _ run: @escaping () -> Void) -> MenuEntry {
        .action("curve.deletePoint", "Delete Point", isEnabled: isEnabled, run)
    }
}

// MARK: - A right-click on a row

extension View {
    /// A right-click or a Control-click on this view opens `entries`' menu, after `onOpen`: a row selects itself first, as a click on
    /// it does, so the menu is for what the ring shows. SwiftUI's `contextMenu` has no moment before its menu opens, so this is an
    /// AppKit view over the row that takes those two presses alone; every other press, the pointer's hover and a scroll pass through
    /// to the row under it. The table is made as the menu opens.
    func rowMenu(isActive: Bool = true, onOpen: @escaping () -> Void, entries: @escaping @MainActor () -> [MenuEntry]) -> some View {
        overlay { RowMenuArea(isActive: isActive, onOpen: onOpen, entries: entries).accessibilityHidden(true) }
    }
}

private struct RowMenuArea: NSViewRepresentable {
    let isActive: Bool
    let onOpen: () -> Void
    let entries: @MainActor () -> [MenuEntry]

    func makeNSView(context: Context) -> RowMenuView { RowMenuView() }

    func updateNSView(_ view: RowMenuView, context: Context) {
        view.isActive = isActive
        view.onOpen = onOpen
        view.entries = entries
    }

    static func dismantleNSView(_ view: RowMenuView, coordinator: ()) {
        view.onOpen = nil
        view.entries = nil
    }
}

/// The view `rowMenu` lays over a row.
final class RowMenuView: NSView {
    /// Off while the row's own field is being typed in, whose text menu is the field's.
    var isActive = true
    var onOpen: (() -> Void)?
    var entries: (@MainActor () -> [MenuEntry])?
    /// The press being handled, which says whether it asks for a menu. A test gives its view a press of its own, as a slider takes
    /// its own answer to `isPointerOverArmedCanvas`: one posted to the application would leave the test process's run loop stopped.
    var currentEvent: @MainActor () -> NSEvent? = { NSApp.currentEvent }

    /// A press that asks for a context menu: the right button, or the left with Control (`NSEvent.asksForContextMenu`).
    static func asksForMenu(_ event: NSEvent?) -> Bool { event?.asksForContextMenu == true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, Self.asksForMenu(currentEvent()) else { return nil }
        return super.hitTest(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isActive, let entries else { return nil }
        onOpen?()
        let table = entries()
        return table.isEmpty ? nil : NSMenu(entries: table)
    }

    override func rightMouseDown(with event: NSEvent) { popUpMenu(for: event) }

    /// Only a Control-click reaches here (`hitTest`).
    override func mouseDown(with event: NSEvent) { popUpMenu(for: event) }

    private func popUpMenu(for event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        // Through the one pop-up every menu takes, which the tests replace: a menu shown under the test runner can end its run.
        ContextMenuPresentation.popUp(menu, event, self)
    }
}

extension NSView {
    /// A Control-click on a view whose `mouseDown` is its own gesture: its context menu, as a right-click opens it, in place of the
    /// gesture. Whether it opened one; a view with no menu takes the press as it always did.
    func popUpContextMenuForControlClick(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.control), let menu = menu(for: event) else { return false }
        ContextMenuPresentation.popUp(menu, event, self)
        return true
    }
}
