import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI

/// A key and its modifiers, in one form for the menu, the help tags and the tests.
struct KeyChord: Hashable, Sendable {
    enum Modifier: Hashable, Sendable { case shift, option, command, control }

    var key: Character
    var modifiers: Set<Modifier> = []

    init(_ key: Character, _ modifiers: Set<Modifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    var isPlain: Bool { modifiers.isDisjoint(with: [.command, .control]) }

    var shortcut: KeyboardShortcut {
        var flags: EventModifiers = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: flags)
    }

    /// In a help tag's words: "Shift-M", as the rail says "Shift-Command-A".
    var words: String {
        let names: [(Modifier, String)] = [(.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
        return (names.filter { modifiers.contains($0.0) }.map(\.1) + [String(key).uppercased()]).joined(separator: "-")
    }

    /// In the inspector tabs' words: "⇧W", "⌥⌘3".
    var symbols: String {
        let names: [(Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return names.filter { modifiers.contains($0.0) }.map(\.1).joined() + String(key).uppercased()
    }
}

/// What the Mask menu's items do. What is not built yet does nothing and stays disabled.
enum MaskCommand: Hashable, Sendable {
    case showMasks
    case newMask(MaskEditor.Tool)
    /// A smart mask, as its tile makes one: no key, so a keyboard reaches it through the menu (plan section 5).
    case newSmart(SmartKind)
    /// What Return does on the photograph with a gradient tool in hand.
    case placeGradient
    /// A tool for the selected mask's next component.
    case addShape(MaskEditor.Tool, MaskOperation)
    case addBrush, subtractBrush, newLikeSelected
    case showOverlay, nextOverlayColour
    case invert, showPins
    case nextMask, previousMask, renameMask, duplicateMask, switchMask
    /// A component of the selected mask, for Invert, Delete and its numbers: a click on its row, for a keyboard.
    case nextComponent, previousComponent
    /// A later component's Add, Subtract or Intersect, as its row's menu changes it.
    case componentOperation(MaskOperation)
    /// What a smart mask's row offers under its name, whose buttons Tab does not reach.
    case smart(SmartRowStatus.Action)
    case largerBrush, smallerBrush, moreFeather, lessFeather
    case followEdges
    /// Lightroom's digits: 1 is Flow 10 and so on, 0 is Flow 100.
    case flow(digit: Int)
    case deleteMask, resetMasks
    /// Remove's (`RemoveKeys`): its tab, Return on a selection, and Escape on a run.
    case showRemove, removeObject, cancelRemoval
}

/// One item of the masks' key table.
struct MaskKey: Sendable {
    let command: MaskCommand
    let title: String
    /// None for Delete, which is the photograph's and the mask list's own (`MaskKeys.delete`).
    let chord: KeyChord?
    let isEnabled: @Sendable (MenuState) -> Bool

    init(_ command: MaskCommand, _ title: String, _ chord: KeyChord?, isEnabled: @escaping @Sendable (MenuState) -> Bool = MaskKeys.notBuiltYet) {
        self.command = command
        self.title = title
        self.chord = chord
        self.isEnabled = isEnabled
    }
}

/// The masks' keys, docs/masking-plan.md's table, in one place: the Mask menu is drawn from it and
/// `MaskKeyTests` checks it. Plain keys follow F and the digits: menu equivalents, so they work from
/// any focus and show in the menu bar, and a focused text field takes the key first.
///
/// Items with no key are there for a keyboard that Tab cannot take to the panel's buttons, as View's tab items
/// are: gradients stay keyboard-complete (plan section 5), and painting alone is pointer-only. With the brush in
/// hand the digits are Flow's and Stock's digit items are disabled; otherwise the reverse. A disabled item never
/// swallows a key (measured, P0-S2), and both sets act on the live tool rather than the menu's last state, since a
/// key can beat the menu's refresh (P0-S2): Stock's item sets Flow with the brush in hand, Flow's selects the stock
/// without. For that reason each command here asks the live state again (`RollModel.perform`), and whether a frame
/// is ready is asked there too (`MenuState.canMask`). Follow edges (A) is the brush's, enabled while it is in hand.
enum MaskKeys {
    @Sendable static func notBuiltYet(_ state: MenuState) -> Bool { false }

    @Sendable private static func frameIsOpen(_ state: MenuState) -> Bool {
        state.canMask && state.page == .roll
    }

    /// A mask is selected, on a frame that is open.
    @Sendable private static func maskIsSelected(_ state: MenuState) -> Bool {
        frameIsOpen(state) && state.hasSelectedMask
    }

    /// A component after the first is selected: the first of a mask is always added.
    @Sendable private static func laterComponentIsSelected(_ state: MenuState) -> Bool {
        maskIsSelected(state) && (state.selectedComponent ?? 0) > 0
    }

    /// The selected smart mask's row offers `action`.
    private static func smartOffers(_ action: SmartRowStatus.Action) -> @Sendable (MenuState) -> Bool {
        { state in maskIsSelected(state) && state.selectedSmartActions.contains(action) }
    }

    /// The frame has a mask to go to.
    @Sendable private static func frameHasMasks(_ state: MenuState) -> Bool {
        frameIsOpen(state) && state.hasMasks
    }

    /// The frame's masks have pins to show or hide: the Masks tab is open on a frame with masks.
    @Sendable private static func pinsCanShow(_ state: MenuState) -> Bool {
        frameHasMasks(state) && state.isMasksTabShown
    }

    /// A gradient tool is in hand.
    @Sendable private static func gradientIsArmed(_ state: MenuState) -> Bool {
        frameIsOpen(state) && (state.armedMaskTool == .linear || state.armedMaskTool == .radial)
    }

    /// The brush is in hand.
    @Sendable static func brushIsArmed(_ state: MenuState) -> Bool {
        frameIsOpen(state) && state.armedMaskTool == .brush
    }

    /// A brush whose size can be stepped is in hand: the masks', or the Remove tab's (`RollModel.stepBrush`).
    @Sendable static func brushSizeIsArmed(_ state: MenuState) -> Bool {
        brushIsArmed(state) || (frameIsOpen(state) && state.isRemoveTabShown)
    }

    private static func addingShape(_ tool: MaskEditor.Tool, _ operation: MaskOperation) -> MaskKey {
        MaskKey(.addShape(tool, operation), "\(operation.title) \(tool.title)", nil, isEnabled: maskIsSelected)
    }

    /// Mask > Mask Adjustments: Lightroom's key for its Masking panel.
    static let masksTab = MaskKey(.showMasks, "Mask Adjustments", KeyChord("w", [.shift]), isEnabled: frameIsOpen)
    /// View > Mask Adjustments, beside the Light and Curve tabs' chords.
    static let masksTabView = MaskKey(.showMasks, "Mask Adjustments", KeyChord("3", [.option, .command]), isEnabled: frameIsOpen)

    static let newBrush = MaskKey(.newMask(.brush), "New Brush Mask", KeyChord("k"), isEnabled: frameIsOpen)
    static let newLinear = MaskKey(.newMask(.linear), "New Linear Gradient", KeyChord("m"), isEnabled: frameIsOpen)
    static let newRadial = MaskKey(.newMask(.radial), "New Radial Gradient", KeyChord("m", [.shift]), isEnabled: frameIsOpen)

    /// The Mask menu, section by section between dividers. Flow's digits are `flowDigits`, a submenu.
    static let sections: [[MaskKey]] = [
        [masksTab],
        [newBrush, newLinear, newRadial,
         MaskKey(.placeGradient, "Place Gradient", nil, isEnabled: gradientIsArmed),
         MaskKey(.addBrush, "Add a Brush", KeyChord("k", [.shift]), isEnabled: maskIsSelected),
         MaskKey(.subtractBrush, "Subtract a Brush", KeyChord("k", [.option]), isEnabled: maskIsSelected),
         MaskKey(.newLikeSelected, "New Mask Like Selected", KeyChord("n"), isEnabled: maskIsSelected)],
        // The smart tiles, for a keyboard; each shows the Masks tab, whose tile says why when it cannot be made.
        [SmartKind.subject, .sky, .person, .background].map { MaskKey(.newSmart($0), "New \($0.rawValue.capitalized) Mask", nil, isEnabled: frameIsOpen) },
        [addingShape(.linear, .add), addingShape(.radial, .add),
         addingShape(.linear, .subtract), addingShape(.radial, .subtract),
         addingShape(.linear, .intersect), addingShape(.radial, .intersect)],
        [MaskKey(.showOverlay, "Show Overlay", KeyChord("o"), isEnabled: maskIsSelected),
         MaskKey(.nextOverlayColour, "Next Overlay Colour", KeyChord("o", [.shift]), isEnabled: maskIsSelected),
         MaskKey(.invert, "Invert Mask", KeyChord("'"), isEnabled: maskIsSelected),
         MaskKey(.showPins, "Show Pins", KeyChord("h"), isEnabled: pinsCanShow)],
        // Lightroom's way through its list, Option with the arrows. The photograph keeps the plain ones.
        [MaskKey(.nextMask, "Next Mask", KeyChord(KeyEquivalent.downArrow.character, [.option]), isEnabled: frameHasMasks),
         MaskKey(.previousMask, "Previous Mask", KeyChord(KeyEquivalent.upArrow.character, [.option]), isEnabled: frameHasMasks),
         MaskKey(.renameMask, "Rename Mask", nil, isEnabled: maskIsSelected),
         MaskKey(.duplicateMask, "Duplicate Mask", nil, isEnabled: maskIsSelected),
         MaskKey(.switchMask, "Turn Mask On or Off", nil, isEnabled: maskIsSelected)],
        // A component, and what its row's menu does: a keyboard cannot click its row (plan section 5).
        [MaskKey(.nextComponent, "Next Component", nil, isEnabled: maskIsSelected),
         MaskKey(.previousComponent, "Previous Component", nil, isEnabled: maskIsSelected),
         MaskKey(.componentOperation(.add), "Set Component to Add", nil, isEnabled: laterComponentIsSelected),
         MaskKey(.componentOperation(.subtract), "Set Component to Subtract", nil, isEnabled: laterComponentIsSelected),
         MaskKey(.componentOperation(.intersect), "Set Component to Intersect", nil, isEnabled: laterComponentIsSelected)],
        // The smart row's own buttons. Remove is Delete Mask's.
        [MaskKey(.smart(.cancel), "Cancel Finding", nil, isEnabled: smartOffers(.cancel)),
         MaskKey(.smart(.retry), "Find Again", nil, isEnabled: smartOffers(.retry)),
         MaskKey(.smart(.paintInstead), "Paint Mask Instead", nil, isEnabled: smartOffers(.paintInstead)),
         MaskKey(.smart(.update), "Update Smart Mask", nil, isEnabled: smartOffers(.update)),
         MaskKey(.smart(.keep), "Keep Smart Mask", nil, isEnabled: smartOffers(.keep))],
        [MaskKey(.largerBrush, "Larger Brush", KeyChord("]"), isEnabled: brushSizeIsArmed),
         MaskKey(.smallerBrush, "Smaller Brush", KeyChord("["), isEnabled: brushSizeIsArmed),
         MaskKey(.moreFeather, "More Feather", KeyChord("]", [.shift]), isEnabled: brushIsArmed),
         MaskKey(.lessFeather, "Less Feather", KeyChord("[", [.shift]), isEnabled: brushIsArmed),
         MaskKey(.followEdges, "Follow Edges", KeyChord("a"), isEnabled: brushIsArmed)],
        [MaskKey(.deleteMask, "Delete Mask", nil, isEnabled: maskIsSelected),
         MaskKey(.resetMasks, "Reset Masks", nil, isEnabled: frameHasMasks)],
    ]

    /// 1 to 9 and 0: Flow 10 to 100, while a brush is armed; otherwise disabled, and 1 to 9 are the stocks'.
    static let flowDigits: [MaskKey] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0].map { digit in
        MaskKey(.flow(digit: digit), "Flow \(digit == 0 ? 100 : digit * 10)", KeyChord(Character(String(digit))), isEnabled: brushIsArmed)
    }

    /// Every item that has a key in some menu, Remove's among them, so no two are ever bound at once.
    static let all: [MaskKey] = sections.flatMap { $0 } + flowDigits + [masksTabView] + RemoveKeys.items + [RemoveKeys.tabView]

    /// What Delete binds on the photograph and the mask list. Never a menu equivalent: a focused slider
    /// passes the key on to the menu, and would delete a mask. SwiftUI's `.delete` is U+0008, which the
    /// Mac's Delete key does not send (it sends U+007F), so a handler on `.delete` never fires (P0-S2).
    static let delete: Set<KeyEquivalent> = [KeyEquivalent("\u{7F}"), .deleteForward]

    /// A plain key whose menu item has fired while a text field has the keyboard: AppKit gives the field
    /// the key first (measured, P0-S2), and this holds the line if that ever fails to be so. A pointer
    /// choosing the item from the menu, and a chord with Command or Control, are never stopped.
    static func isTypedIntoField(_ event: NSEvent?, firstResponder: NSResponder?) -> Bool {
        guard let event, event.type == .keyDown, firstResponder is NSText else { return false }
        return event.modifierFlags.isDisjoint(with: [.command, .control])
    }
}

/// Remove's keys (docs/remove-plan.md, section 4.8), in the masks' table's form and drawn into the menu bar from it, so they work from
/// any focus and a text field takes the key first. Q opens the tab; Return removes what is selected; Escape stops the frame's newest
/// run. Return and Escape are bound only while they have something to do: a disabled item never swallows a key (measured, P0-S2),
/// so Return still places a gradient and Escape still puts a tool down or closes the frame. Each asks the live state again when it
/// fires (`RollModel.perform`). None is there while the Adjust inspector has no Remove tab (`MenuState.showsRemoveTab`).
enum RemoveKeys {
    /// The tab can open: this build has it, and a frame is open on the roll.
    @Sendable private static func tabCanOpen(_ state: MenuState) -> Bool {
        state.showsRemoveTab && state.canMask && state.page == .roll
    }

    /// The tab is open on the frame.
    @Sendable private static func tabIsOpen(_ state: MenuState) -> Bool {
        tabCanOpen(state) && state.isRemoveTabShown
    }

    /// Frame > Remove Tool.
    static let tab = MaskKey(.showRemove, "Remove Tool", KeyChord("q"), isEnabled: tabCanOpen)
    /// View > Remove Tool, after the Lens tab's chord.
    static let tabView = MaskKey(.showRemove, "Remove Tool", KeyChord("5", [.option, .command]), isEnabled: tabCanOpen)
    static let removeObject = MaskKey(.removeObject, "Remove Object", KeyChord(KeyEquivalent.return.character)) { tabIsOpen($0) && $0.canRemoveObject }
    static let cancel = MaskKey(.cancelRemoval, "Cancel Removal", KeyChord(KeyEquivalent.escape.character)) { tabIsOpen($0) && $0.canCancelRemoval }

    /// The Frame menu's section.
    static let items = [tab, removeObject, cancel]

    /// Held at a stroke's press, it takes the stroke from the selection.
    static let subtracts = NSEvent.ModifierFlags.option
    /// How far the pointer may stray, in points, between a press and its release and still be a click.
    static let clickTravel: CGFloat = 3
    /// How many places of an Option-stroke are said not to be the object.
    static let excludedPoints = 8
}

/// Remove's section of the Frame menu. A build whose inspector has no Remove tab shows none of it.
struct RemoveMenuItems: View {
    let model: RollModel
    let state: MenuState

    var body: some View {
        if state.showsRemoveTab {
            ForEach(RemoveKeys.items.indices, id: \.self) { item in
                RemoveKeys.items[item].menuItem(model: model, state: state)
            }
            Divider()
        }
    }
}

extension MaskKey {
    /// This item in a menu: disabled under the quick develop dialog, which the frame under it waits for. Its key can
    /// beat the menu's refresh, so the live model stops it there too.
    @MainActor func menuItem(model: RollModel, state: MenuState) -> some View {
        Button(title) {
            guard !model.isAskingToDevelop else { return }
            guard !MaskKeys.isTypedIntoField(NSApp.currentEvent, firstResponder: NSApp.keyWindow?.firstResponder) else { return }
            model.perform(command)
        }
        .keyboardShortcut(chord?.shortcut)
        .disabled(!isEnabled(state) || state.isAskingToDevelop)
    }
}

/// The Mask menu: always the same items, since the menu bar does not follow items that come and go.
struct MaskMenuItems: View {
    let model: RollModel
    let state: MenuState

    var body: some View {
        ForEach(MaskKeys.sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(MaskKeys.sections[index].indices, id: \.self) { item in
                MaskKeys.sections[index][item].menuItem(model: model, state: state)
            }
        }
        Menu("Flow") {
            ForEach(MaskKeys.flowDigits.indices, id: \.self) { item in
                MaskKeys.flowDigits[item].menuItem(model: model, state: state)
            }
        }
    }
}

extension RollModel {
    /// A Mask menu item chosen. A key can beat the menu's refresh, so each asks the live state again.
    func perform(_ command: MaskCommand) {
        let editor = maskEditor
        switch command {
        case .showMasks: showInspector(tab: .masks)
        case .showPins:
            editor.togglePins()
            announce(editor.arePinsHidden ? "Pins hidden" : "Pins shown")
        case .followEdges:
            toggleFollowEdges()
            announce(editor.brush.settings.followEdges ? "Follow edges on" : "Follow edges off")
        case .newMask(.brush):
            armBrush()
            announce("Brush in hand")
        case .addBrush: armBrush(adding: .add)
        case .subtractBrush: armBrush(adding: .subtract)
        case .largerBrush: stepBrush { $0.larger() }
        case .smallerBrush: stepBrush { $0.smaller() }
        case .moreFeather: stepBrush { $0.feathered(by: 1) }
        case .lessFeather: stepBrush { $0.feathered(by: -1) }
        case .flow(let digit): digitPressed(digit)
        case .newMask(let tool):
            armMaskTool(tool)
            announce("\(tool.title) gradient in hand. Return places it.")
        case .newSmart(let kind):
            showInspector(tab: .masks)
            shownFrame.map { addSmartMask(kind, for: $0) }
        case .placeGradient: placeArmedGradient()
        case .addShape(let tool, let operation): armMaskTool(tool, adding: operation)
        case .newLikeSelected: armToolLikeSelected()
        case .showOverlay:
            if editor.selection != nil {
                editor.toggleOverlay()
                announce(editor.isOverlayOn ? "Overlay on" : "Overlay off")
            }
        case .nextOverlayColour:
            editor.nextOverlayColour()
            announce("Overlay \(editor.overlayColour.title)")
        case .invert:
            if let frame = shownFrame {
                invertSelectedComponent(for: frame)
                let component = selectedMask(for: frame)?.components[safe: editor.selection?.component ?? 0]
                if let component { announce(component.invert ? "Inverted" : "Not inverted") }
            }
        case .nextMask: shownFrame.map { stepMask(by: 1, for: $0) }
        case .previousMask: shownFrame.map { stepMask(by: -1, for: $0) }
        case .nextComponent: shownFrame.map { selectComponent(by: 1, for: $0) }
        case .previousComponent: shownFrame.map { selectComponent(by: -1, for: $0) }
        case .componentOperation(let operation):
            if let frame = shownFrame, let selection = editor.selection, let component = selection.component {
                setComponentOperation(operation, component: component, of: selection.mask, for: frame)
            }
        case .smart(let action):
            if let frame = shownFrame, let id = editor.selection?.mask, action == .cancel || canAdjust(frame) {
                perform(action, on: id, for: frame)
            }
        case .renameMask:
            showInspector(tab: .masks)
            editor.renaming = editor.selection?.mask
        case .duplicateMask:
            if let frame = shownFrame, let selection = editor.selection { duplicateMask(selection.mask, for: frame) }
        case .switchMask:
            if let frame = shownFrame, let mask = selectedMask(for: frame) { setMaskEnabled(!mask.isEnabled, mask: mask.id, for: frame) }
        case .deleteMask: _ = editor.deleteSelection()
        case .resetMasks: shownFrame.map(resetMasks)
        case .showRemove: showRemoveTab()
        case .removeObject:
            if isRemoveTabShown, let frame = shownFrame { commitRemoval(on: frame) }
        case .cancelRemoval:
            if isRemoveTabShown, let frame = shownFrame { cancelNewestRemoval(on: frame) }
        }
    }
}

extension RollModel {
    /// Q, and View > Remove Tool: the Remove tab on the open frame, the keyboard on the photograph and the model wanted soon. Nothing
    /// while the inspector has no such tab.
    func showRemoveTab() {
        guard removalRuns.showsTab, let frame = shownFrame else { return }
        showInspector(tab: .remove)
        maskEditor.requestPhotographFocus()
        removeTabShown(for: frame)
    }
}

extension RollModel {
    /// Next or Previous Mask: selects it, and says which, since nothing the keyboard is on changes.
    private func stepMask(by offset: Int, for frame: Frame) {
        selectMask(by: offset, for: frame)
        if let id = maskEditor.selection?.mask { announce("\(maskName(id, for: frame)) selected") }
    }

    /// Next or Previous Component of the selected mask, round its ends: from the mask as a whole, the first or the last.
    func selectComponent(by offset: Int, for frame: Frame) {
        guard let mask = selectedMask(for: frame), !mask.components.isEmpty else { return }
        let count = mask.components.count
        let next = maskEditor.selection?.component.map { ($0 + offset + count) % count } ?? (offset < 0 ? count - 1 : 0)
        maskEditor.selection = MaskEditor.Selection(mask: mask.id, component: next)
        announce("\(MaskSummary.title(of: mask.components[next].shape)) selected")
    }
}

extension RollModel {
    /// A digit, from Flow's item or Stock's: Flow with the brush in hand, else the stock, asked of the live tool whichever item the
    /// menu's last state let fire (P0-S2 item 7). 0 has no stock.
    func digitPressed(_ digit: Int) {
        if maskEditor.tool == .brush {
            stepBrush { $0.flow(digit: digit) }
        } else if (1...9).contains(digit), stockNames.indices.contains(digit - 1), workspacePage == .roll {
            selectStock(digit - 1)
        }
    }
}
