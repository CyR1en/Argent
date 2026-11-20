import AppKit
import ArgentRoll
import SwiftUI

/// The menus of the photograph in the frame view (docs/context-menus-plan.md, section 3): the frame's own, with the frame view's rows
/// round it, and a mask's, on its pin. They are tables (`MenuEntry`), made when a right-click or a Control-click asks for one
/// (`MaskCanvasView.menu(for:)`) and never as a view is drawn, so a stroke, a gradient's drag or a slider's drag reads nothing more
/// for them. Each row does what its menu bar item does, and is enabled as that item's action asks when it is chosen.
@MainActor enum PhotographMenu {
    /// What a right-click or a Control-click at `point`, in the frame view's area, opens: on a pin, its mask's menu, the mask selected
    /// first as a click on the pin selects it, so the ring and the list show what the menu is for (as Finder selects what it is asked
    /// about); anywhere else, the photograph's. Nil where the rule gives no menu (`MaskEditor.canvasTakesMenu`).
    static func entries(at point: CGPoint, model: RollModel) -> [MenuEntry]? {
        let editor = model.maskEditor
        guard let frame = model.shownFrame, editor.canvasTakesMenu(at: point) else { return nil }
        // The pin on top, whose mask's overlay the pointer resting there shows: the one the heading will name.
        if let id = editor.pin(at: point, pressing: false), model.mask(id, for: frame) != nil {
            editor.selection = MaskEditor.Selection(mask: id, component: nil)
            return mask(id, for: frame, model: model)
        }
        return photograph(frame, at: point, model: model)
    }

    // MARK: The photograph

    /// The frame's menu on the photograph, in the plan's order: with a tool in hand Put Tool Away first, then the flag; Copy
    /// Adjustments, Paste Adjustments and Paste Only; the comparison and the zoom; New Mask; Reset; Develop This Frame and the frame's
    /// files in Finder. `anchor` is where it was opened, which Actual Size zooms about.
    ///
    /// Composed from `FrameMenu`'s sections rather than `FrameMenu.entries(for:on:model:)`, which has no place between Paste Only and
    /// Reset for the rows only the frame view has.
    static func photograph(_ frame: Frame, at anchor: CGPoint, model: RollModel) -> [MenuEntry] {
        MenuEntry.sections([
            tool(model: model),
            FrameMenu.lead(for: frame, on: .photograph, model: model),
            FrameMenu.adjustments(for: frame, on: .photograph, model: model),
            view(at: anchor, model: model),
            [newMask(for: frame, model: model)],
            [FrameMenu.reset(for: frame, model: model)],
            FrameMenu.files(for: frame, model: model),
        ])
    }

    /// Put Tool Away while a tool is in hand: what Escape does to it. Every press on the picture is the tool's then, so here the pointer
    /// puts it down where it is, as Escape does from the keyboard.
    static func tool(model: RollModel) -> [MenuEntry] {
        let editor = model.maskEditor
        guard editor.isArmed else { return [] }
        return [.action("photograph.putToolAway", "Put Tool Away", chord: Keys.escape) { editor.putToolAway() }]
    }

    /// The View menu's Split Compare, Zoom to Fit and Actual Size, which are enabled whenever a frame is open, as here it is. Actual
    /// Size zooms about `anchor`, as smart zoom zooms about the pointer, so what was clicked stays under it.
    static func view(at anchor: CGPoint, model: RollModel) -> [MenuEntry] {
        [
            .action("photograph.split", "Split Compare", chord: Keys.splitCompare, isOn: model.isSplitComparing) {
                model.isSplitComparing.toggle()
            },
            .action("photograph.fit", "Zoom to Fit", chord: Keys.zoomToFit) { model.zoomFrame(.fit) },
            .action("photograph.actualSize", "Actual Size", chord: Keys.actualSize) { model.zoomFrame(toActualSizeAt: anchor) },
        ]
    }

    /// New Mask: the tiles, as the Mask menu's items (`MaskCommand.newMask`, `.newSmart`). A row is enabled by its tile's own rule
    /// (`MaskTileAvailability`): the frame can take a mask, and a smart one's kind is in this build and on this Mac. The Mask menu's
    /// items, drawn from `MenuState`, cannot ask that without rebuilding the menu bar, so they stay enabled and show the tab that
    /// says why; a menu made when it is asked can, and a row that cannot act is disabled.
    static func newMask(for frame: Frame, model: RollModel) -> MenuEntry {
        let canAdd = model.canAddMask(frame)
        func row(_ tile: MaskTile, _ title: String, _ chord: KeyChord? = nil) -> MenuEntry {
            // Why it cannot is the tile's to say, on the tab; here only whether.
            let availability = MaskTileAvailability.of(tile, frame: canAdd ? nil : "", smart: tile.smartKind.map(model.smartAvailability))
            return .action("photograph.newMask.\(tile.rawValue)", title, chord: chord, isEnabled: availability.isLive) {
                if let tool = tile.tool { model.perform(.newMask(tool)) }
                if let kind = tile.smartKind { model.perform(.newSmart(kind)) }
            }
        }
        return .submenu("photograph.newMask", "New Mask", isEnabled: canAdd, MenuEntry.sections([
            [row(.brush, "Brush", MaskKeys.newBrush.chord), row(.linear, "Linear Gradient", MaskKeys.newLinear.chord),
             row(.radial, "Radial Gradient", MaskKeys.newRadial.chord)],
            [row(.subject, "Subject"), row(.sky, "Sky"), row(.person, "Person"), row(.background, "Background")],
        ]))
    }

    // MARK: A mask

    /// A mask's menu on its pin: its name, then what the Mask menu's items and its row's menu do to it. Every row but Show Overlay is
    /// the row's menu's, and is disabled as that menu is while the frame cannot be adjusted; Show Overlay changes no edit, as O does not.
    /// The rows act on the selected mask, as the Mask menu's items do: the right-click selected this one, and each row selects it
    /// again, as the row's own menu does, in case anything moved the selection while the menu was open.
    static func mask(_ id: UUID, for frame: Frame, model: RollModel) -> [MenuEntry] {
        guard let mask = model.mask(id, for: frame) else { return [] }
        let editor = model.maskEditor, canAdjust = model.canAdjust(frame)
        func selecting(_ command: MaskCommand) -> () -> Void {
            {
                editor.selection = MaskEditor.Selection(mask: id, component: nil)
                model.perform(command)
            }
        }
        return MenuEntry.sections([
            [.heading("mask.name", model.maskName(id, for: frame)),
             .action("mask.overlay", "Show Overlay", chord: Keys.mask(.showOverlay), isOn: editor.isOverlayOn, selecting(.showOverlay)),
             .action("mask.invert", "Invert", chord: Keys.mask(.invert), isEnabled: canAdjust, selecting(.invert)),
             .action("mask.duplicate", "Duplicate", isEnabled: canAdjust && model.canAddMask(frame), selecting(.duplicateMask)),
             .action("mask.switch", mask.isEnabled ? "Turn Off" : "Turn On", isEnabled: canAdjust, selecting(.switchMask)),
             .action("mask.rename", "Rename", isEnabled: canAdjust, selecting(.renameMask))],
            [.action("mask.delete", "Delete Mask", isEnabled: canAdjust, isDestructive: true, selecting(.deleteMask))],
        ])
    }

    // MARK: VoiceOver

    /// The photograph's Copy Adjustments for VoiceOver, which offers it whether or not it can act: the menu's row, or why not, since
    /// the action cannot be disabled as the row is.
    static func copyForVoiceOver(_ frame: Frame, model: RollModel) {
        guard model.canCopyAdjustments(from: frame) else { return model.announce("No adjustments to copy") }
        model.copyAdjustments(from: frame)
    }

    /// The photograph's Paste Adjustments for VoiceOver, as `copyForVoiceOver`.
    static func pasteForVoiceOver(_ frame: Frame, model: RollModel) {
        guard model.canPasteAdjustments(to: frame) else {
            return model.announce(model.pasteableParts().isEmpty ? "No adjustments copied" : "Adjustments cannot be pasted now")
        }
        model.pasteAdjustments(to: frame)
    }

    // MARK: Keys

    /// The keys these menus show beside their rows, each the menu bar's or the photograph's own. Shown, never bound: an AppKit menu made
    /// for one click is not searched for key equivalents (`NSMenu(entries:)`), and the canvas keeps none as its `menu`. Escape, pressed
    /// while the menu is open, closes it and leaves the tool in hand (seen in the app), so Put Tool Away's hint does not act twice.
    enum Keys {
        /// View > Split Compare, Zoom to Fit and Actual Size (`ArgentCommands`).
        static let splitCompare = KeyChord("c", [.shift, .command])
        static let zoomToFit = KeyChord("9", [.command])
        static let actualSize = KeyChord("0", [.command])
        /// The photograph's own Escape (`FrameView`), whose step for a tool in hand Put Tool Away is.
        static let escape = KeyChord(KeyEquivalent.escape.character)

        /// The Mask menu's key for `command`, from its own table.
        static func mask(_ command: MaskCommand) -> KeyChord? {
            MaskKeys.all.first { $0.command == command }?.chord
        }
    }
}
