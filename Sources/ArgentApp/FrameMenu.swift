import AppKit
import ArgentRoll
import SwiftUI

/// A frame's context menu, the same table wherever the frame is: its cell on the contact sheet, its
/// thumbnail on the filmstrip and the photograph in the frame view (docs/context-menus-plan.md, section 3).
/// Each surface adds its own rows round these.
@MainActor enum FrameMenu {
    enum Surface: Sendable {
        case sheet, filmstrip, photograph
    }

    #if DEBUG
    /// How many menus have been made for each frame, for the tests that hold that none is made as a view is drawn.
    static var made: [URL: Int] = [:]
    #endif

    /// The whole menu for `frame` on `surface`.
    static func entries(for frame: Frame, on surface: Surface, model: RollModel) -> [MenuEntry] {
        #if DEBUG
        made[frame.url, default: 0] += 1
        #endif
        return MenuEntry.sections([
            lead(for: frame, on: surface, model: model),
            adjustments(for: frame, on: surface, model: model),
            [reset(for: frame, model: model)],
            files(for: frame, model: model),
            surface == .sheet ? roll(for: [frame], model: model) : [],
        ])
    }

    /// The menu for the frames a right-click on the sheet is for (`RollModel.framesActedOn`): one frame's as it always
    /// was, or the several selected's, each row for them all.
    static func entries(for frames: [Frame], on surface: Surface, model: RollModel) -> [MenuEntry] {
        guard frames.count > 1 else { return frames.first.map { entries(for: $0, on: surface, model: model) } ?? [] }
        #if DEBUG
        for frame in frames { made[frame.url, default: 0] += 1 }
        #endif
        return MenuEntry.sections([
            [flag(for: frames, model: model)],
            adjustments(for: frames, model: model),
            files(for: frames, model: model),
            roll(for: frames, model: model),
        ])
    }

    // MARK: Several frames

    /// "Flag 3 Frames", or "Unflag 3 Frames" once every one of them is flagged.
    static func flag(for frames: [Frame], model: RollModel) -> MenuEntry {
        let unflags = model.areAllFlagged(frames)
        return .action("frames.flag", "\(unflags ? "Unflag" : "Flag") \(RollModel.framesTitle(frames.count))", chord: KeyChord("f"),
                       isEnabled: frames.contains(where: model.canFlag)) { model.setFlag(!unflags, for: frames) }
    }

    /// The paste on the frames selected, whole or one part, as one undo step. Copy Adjustments is one frame's, and is
    /// left to a menu opened on one; so are the resets, which the menu bar has for the open frame alone, since a
    /// context menu holds no action that exists nowhere else (docs/M2-shell.md, section 18).
    static func adjustments(for frames: [Frame], model: RollModel) -> [MenuEntry] {
        let parts = AdjustmentParts.each.map { part in
            MenuEntry.action("frames.pasteOnly.\(part.name)", part.title, isEnabled: model.canPasteAdjustments(to: frames, parts: part)) {
                model.pasteAdjustments(to: frames, parts: part)
            }
        }
        return [
            .action("frames.paste", "Paste Adjustments to \(RollModel.framesTitle(frames.count))", chord: ClipboardKeys.paste,
                    isEnabled: model.canPasteAdjustments(to: frames)) { model.pasteAdjustments(to: frames) },
            .submenu("frames.pasteOnly", "Paste Only", isEnabled: model.canPasteAdjustments(to: frames), parts),
        ]
    }

    /// The develop of the frames selected, which on the roll asks its settings first (`RollModel.askToDevelop`), and
    /// their files in Finder.
    static func files(for frames: [Frame], model: RollModel) -> [MenuEntry] {
        [
            .action("frames.develop", model.developTitle("Develop \(RollModel.framesTitle(frames.count))"),
                    isEnabled: model.canDevelop(frames)) { model.askToDevelop(frames) },
            .action("frames.showRAW", "Show RAWs in Finder") { model.showInFinder(frames) },
            // By the develops' records, as the menu bar's item is: the disk is asked when the row is chosen, not for
            // every frame selected before the menu opens (`hasDevelopedRecord`).
            .action("frames.showDeveloped", "Show Developed Files in Finder",
                    isEnabled: frames.contains(where: model.hasDevelopedRecord)) { model.showDevelopedInFinder(frames) },
        ]
    }

    // MARK: Leaving the roll

    /// Move to Roll, with the library's other rolls and New Roll…, and Remove from Roll…, for one frame or several
    /// (RollModel+Frames). On the sheet and the Develop page's grid, where the frames are in sight as they go.
    static func roll(for frames: [Frame], model: RollModel) -> [MenuEntry] {
        let can = model.canChangeFrames(frames)
        var targets = model.moveTargets.map { target in
            MenuEntry.action("frames.move.\(target.id.uuidString)", target.name) { model.moveFrames(frames, toRoll: target.id) }
        }
        if !targets.isEmpty { targets.append(MenuEntry(id: "frames.move.divider", title: "", kind: .divider)) }
        targets.append(.action("frames.move.new", "New Roll…") { model.moveFramesToNewRoll(frames) })
        return [
            .submenu("frames.move", "Move to Roll", isEnabled: can, targets),
            .action("frames.remove", "Remove from Roll…", chord: FrameKeys.remove, isEnabled: can, isDestructive: true) {
                model.removeFromRoll(frames)
            },
        ]
    }

    /// Open Frame on the sheet, and the flag everywhere.
    static func lead(for frame: Frame, on surface: Surface, model: RollModel) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if surface == .sheet {
            entries.append(.action("frame.open", "Open Frame", chord: KeyChord(KeyEquivalent.downArrow.character, [.command])) {
                model.selection = frame.id
                model.openFrame()
            })
        }
        entries.append(.action("frame.flag", model.isFlagged(frame) ? "Unflag" : "Flag", chord: KeyChord("f"),
                               isEnabled: model.canFlag(frame)) { model.toggleFlag(frame) })
        return entries
    }

    /// Copy Adjustments, Paste Adjustments and Paste Only; and where the frames shown are in view, on the
    /// sheet and the filmstrip, the paste on all of them.
    static func adjustments(for frame: Frame, on surface: Surface, model: RollModel) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .action("frame.copy", "Copy Adjustments", chord: ClipboardKeys.copy, isEnabled: model.canCopyAdjustments(from: frame)) {
                model.copyAdjustments(from: frame)
            },
            .action("frame.paste", "Paste Adjustments", chord: ClipboardKeys.paste, isEnabled: model.canPasteAdjustments(to: frame)) {
                model.pasteAdjustments(to: frame)
            },
            pasteOnly(for: frame, model: model),
            .action("frame.savePreset", "Save Look as Preset…", isEnabled: model.canSavePreset(from: frame)) {
                model.showSavePreset(from: frame)
            },
            .action("frame.lookPresets", "Look Presets…", isEnabled: !model.isScanning && !model.isQuitting) {
                model.showPresetLibrary(for: [frame])
            },
        ]
        if surface != .photograph {
            entries.append(.action("frame.pasteToShown", model.pasteToShownTitle, chord: ClipboardKeys.pasteToShown,
                                   isEnabled: model.canPasteToShownFrames) { model.pasteAdjustmentsToShownFrames() })
        }
        return entries
    }

    /// Paste Only: one part of what was copied, the frame's other parts kept.
    static func pasteOnly(for frame: Frame, model: RollModel) -> MenuEntry {
        let parts = AdjustmentParts.each.map { part in
            MenuEntry.action("frame.pasteOnly.\(part.name)", part.title, isEnabled: model.canPasteAdjustments(to: frame, parts: part)) {
                model.pasteAdjustments(to: frame, parts: part)
            }
        }
        return .submenu("frame.pasteOnly", "Paste Only", isEnabled: model.canPasteAdjustments(to: frame), parts)
    }

    /// Reset: the Frame menu's three, for this frame.
    static func reset(for frame: Frame, model: RollModel) -> MenuEntry {
        .submenu("frame.reset", "Reset", [
            .action("frame.reset.auto", "Reset to Current Auto", isEnabled: model.canResetManual(frame)) {
                model.resetManualAdjustments(for: frame)
            },
            .action("frame.reset.original", "Reset to Original", isEnabled: model.canStartFromOriginal(frame)) {
                model.startFromOriginal(for: frame, actionName: "Reset to Original")
            },
            .action("frame.reset.roll", "Same as Roll", isEnabled: model.isOverridden(frame)) {
                model.clearOverrides(for: frame)
            },
        ])
    }

    /// Develop This Frame, which on the roll asks its settings first (`RollModel.askToDevelop`), and the frame's
    /// files in Finder.
    static func files(for frame: Frame, model: RollModel) -> [MenuEntry] {
        [
            .action("frame.develop", model.developTitle("Develop This Frame"), isEnabled: model.canDevelopFrame(frame)) {
                model.askToDevelop([frame])
            },
            .action("frame.showRAW", "Show RAW in Finder") { model.showInFinder(frame) },
            .action("frame.showDeveloped", "Show Developed File in Finder", isEnabled: model.developedFile(for: frame) != nil) {
                model.showDevelopedInFinder(frame)
            },
        ]
    }
}

/// The keys of the frames' own commands, in one place for the menu bar and the context menus' hints.
enum FrameKeys {
    /// Finder's Move to Trash.
    static let remove = KeyChord(KeyEquivalent.delete.character, [.command])

    /// Gives Command-Delete to the text being edited, as the key it is there: delete back to the start of the line.
    /// Whether `responder` was such a text and took it.
    @MainActor static func givesRemoveToText(_ responder: NSResponder?) -> Bool {
        guard let text = responder as? NSText, text.isEditable else { return false }
        text.doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:)))
        return true
    }
}

// MARK: - A frame's own actions

extension RollModel {
    /// Whether Develop This Frame can start: Develop's own rule (`canStartDevelop`), for a frame of the roll.
    /// This is asked at each change of the selection, so it does not walk the roll.
    func canDevelopFrame(_ frame: Frame) -> Bool {
        guard canStartDevelop, developAsksSettings || developDestination != nil, let frames = roll?.frames else { return false }
        return frames.indices.contains(frame.id) && frames[frame.id].url == frame.url
    }

    /// Develop This Frame, once the quick develop dialog's Develop is pressed or at once on the Develop page
    /// (`askToDevelop`): this frame alone, by the path Resume takes with a stopped develop's frames
    /// (`develop(frames:)`), into the roll's folder (`developDestination`), with the output
    /// choices as they stand. It leaves its report as the last develop, so Reveal
    /// Developed Files finds its file; while the sheet shows other frames too the button stays Develop, since they
    /// are not developed (`recordDevelop`), and on a sheet filtered to that one frame it is done, as any develop is.
    func developFrame(_ frame: Frame) {
        guard canDevelopFrame(frame) else { return }
        develop(frames: [frame.url])
    }

    /// The frame's raw, selected in Finder.
    func showInFinder(_ frame: Frame) {
        NSWorkspace.shared.activateFileViewerSelecting([frame.url])
    }

    /// The file the frame's last develop wrote, while it is still there: the last develop's own, when it reached
    /// the frame, else the newest develop its recipe's receipts record, which a develop adds to and the session
    /// takes up (`adoptDevelopedRecipes`). `nil` for a frame never developed or whose file has gone.
    func developedFile(for frame: Frame) -> URL? {
        let files = [lastDevelop?.file(for: frame.url), manualRecipes[frame.url]?.develops.last.map { URL(fileURLWithPath: $0.file) }]
        return files.lazy.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether a develop of the frame recorded a file, without asking the disk: what the menu bar reads at each change of the
    /// selection (`RollModel.noteSelectionFlag`), where a destination on a slow or absent volume must not hold an arrow press.
    /// A frame's own menu, made when it is asked for, asks the disk (`developedFile`), and so does the row once chosen.
    func hasDevelopedRecord(for frame: Frame) -> Bool {
        lastDevelop?.file(for: frame.url) != nil || manualRecipes[frame.url]?.develops.last != nil
    }

    func showDevelopedInFinder(_ frame: Frame) {
        guard let file = developedFile(for: frame) else {
            // The menu bar's item is enabled by the record alone, so the file may have gone since.
            NSSound.beep()
            announce("\(frame.name)'s developed file is no longer where it was written")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// The roll's folder, selected in Finder: the sheet's ground's Show Roll in Finder.
    func showRollInFinder() {
        guard let folder = roll?.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Copy Adjustments as a sheet cell's or a filmstrip thumbnail's VoiceOver action. It is offered whether or not
    /// it can act, since that is asked when it is chosen and never as the cell is drawn; one that cannot says why.
    func copyAdjustmentsByAction(from frame: Frame) {
        guard canCopyAdjustments(from: frame) else {
            announce(hasFrameEdits(frame) ? "Adjustments cannot be copied now" : "\(frame.name) has no adjustments to copy")
            return
        }
        copyAdjustments(from: frame)
    }

    /// Paste Adjustments as a sheet cell's or a filmstrip thumbnail's VoiceOver action, as Copy Adjustments is.
    func pasteAdjustmentsByAction(to frame: Frame) {
        guard canPasteAdjustments(to: frame) else {
            announce(adjustmentsClipboard == nil ? "No adjustments have been copied" : "Adjustments cannot be pasted now")
            return
        }
        pasteAdjustments(to: frame)
    }
}
