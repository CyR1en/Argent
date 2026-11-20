import AppKit
import ArgentRoll
import Foundation
import Observation
import os

/// Which of the roll's frames the contact sheet shows and Develop develops: View > Show, and the
/// filter above the contact sheet. The window's, never kept: every roll opens on All Frames, so a roll opened
/// again never develops part of itself unseen. A flag never changes a print: Auto, its settled
/// decision and every develop's recipes read the whole roll, flagged or not.
enum FlagFilter: String, CaseIterable, Identifiable, Sendable {
    case all, flagged, unflagged

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Frames"
        case .flagged: "Flagged"
        case .unflagged: "Unflagged"
        }
    }

    /// The filter's symbol: the filter's own while every frame shows, else the flag's.
    var symbol: String {
        switch self {
        case .all: "line.3.horizontal.decrease.circle"
        case .flagged: "flag.fill"
        case .unflagged: "flag.slash"
        }
    }

    /// Whether a frame flagged or not is shown.
    func shows(flagged: Bool) -> Bool {
        switch self {
        case .all: true
        case .flagged: flagged
        case .unflagged: !flagged
        }
    }
}

/// What the menu bar needs of the selected frame, the one open in the frame view or selected on the sheet: Frame > Flag, Edit's
/// Copy and Paste Adjustments, and the Frame menu's Develop This Frame and Finder items. Kept by the model apart from the
/// selection so that an arrow press on the sheet leaves the menu bar as it is unless one of these differs for the next frame
/// (`RollModel.menuState`).
struct SelectionFlag: Equatable {
    var isSelected = false
    /// More than one frame is selected on the sheet (`RollModel.selected`): the facts below are then of them all, and the
    /// menu bar's items say so. Not how many, so extending the selection by a frame leaves the menu bar as it is.
    var isSeveral = false
    /// The frames selected can leave the roll, to the Trash or to another roll (`RollModel.canChangeFrames`).
    var canChangeFrames = false
    /// Its raw is known, so a flag can name it (`RollModel.flagIdentity`).
    var isKnown = false
    var isFlagged = false
    /// Copy Adjustments can take its values: it has an edit, or its own Rated at or Lab balance (`RollModel.canCopyAdjustments`).
    var canCopy = false
    /// Paste Adjustments can be asked for on it, and the parts Paste Only can paste (`RollModel.canPasteAdjustments`).
    var canPaste = false
    var pasteOnly: AdjustmentParts = []
    /// Develop This Frame can start (`RollModel.canDevelopFrame`), and a develop of it recorded a file (`hasDevelopedRecord`).
    var canDevelopFrame = false
    var hasDevelopedFile = false
}

extension RollModel {
    nonisolated private static let flagLog = Logger(subsystem: "camera.argent.Argent", category: "flags")

    /// The line for a roll whose flags file is one this build cannot read or a later build wrote:
    /// it is left as it is, and flags change for the session only.
    nonisolated static let unsavedFlagsLine = "This roll’s flags cannot be saved: its flags file is not one this version of Argent can read. Flags change until the roll closes."

    func isFlagged(_ frame: Frame) -> Bool { flagged[frame.url] != nil }

    /// Whether the sheet shows `frame` under the filter.
    func isShown(_ frame: Frame) -> Bool { flagFilter.shows(flagged: isFlagged(frame)) }

    /// The frames the sheet shows, in capture order: every frame, or the flagged or unflagged ones.
    var shownFrames: [Frame] {
        guard let roll else { return [] }
        return flagFilter == .all ? roll.frames : roll.frames.filter(isShown)
    }

    /// The roll's frames flagged now.
    var flaggedCount: Int { roll?.frames.count(where: isFlagged) ?? 0 }

    /// The raw `frame`'s file is now, as a flag names it: its name and capture time from the header
    /// on screen, its size from the version that header was read from. `nil` while that version is
    /// not known, as for a raw gone with its card: a flag of it would never match it again.
    func flagIdentity(_ frame: Frame) -> FlagRecord.Entry? {
        sourceStamp(for: frame).map { FlagRecord.Entry(frame, byteCount: Int($0.size)) }
    }

    /// Whether a flag can change now: not while a roll opens, which reads the roll's flags file under
    /// the change, nor while frames are leaving the roll, whose flags are on their way with them.
    var canChangeFlags: Bool { !isScanning && !isQuitting && frameMove == nil }

    /// Whether Flag on `frames` would unflag them: every one of them that can be flagged is. A frame whose raw is not
    /// known can never be flagged (`flagIdentity`), and does not keep the others from being unflagged together.
    func areAllFlagged(_ frames: [Frame]) -> Bool {
        let flaggable = frames.filter { flagIdentity($0) != nil }
        return !flaggable.isEmpty && flaggable.allSatisfy(isFlagged)
    }

    /// Whether `frame`'s flag can change now, its raw known (`flagIdentity`).
    func canFlag(_ frame: Frame) -> Bool { canChangeFlags && flagIdentity(frame) != nil }

    /// Frame > Flag or Unflag, and F: the frame selected on the sheet or open in the frame view. Only
    /// a press counts, not the repeats of a key held down (`event`): under a filter the selection
    /// moves on as the frame leaves the sheet, and each repeat would change the next frame.
    func flagSelection(_ event: NSEvent?) {
        if let event, event.type == .keyDown, event.isARepeat { return }
        let frames = selectedFrames
        guard frames.count > 1 else {
            frames.first.map(toggleFlag)
            return
        }
        setFlag(!areAllFlagged(frames), for: frames)
    }

    /// Frame > Flag and Unflag, F, and a sheet cell's context menu.
    func toggleFlag(_ frame: Frame) { setFlag(!isFlagged(frame), for: frame) }

    /// Flags `frame` or not, and keeps the roll's flags; Edit > Undo puts it back. A frame flagged or
    /// unflagged out of the filter leaves the sheet, and the selection there moves on; an open frame
    /// stays open.
    func setFlag(_ isOn: Bool, for frame: Frame) {
        guard let current = roll?.frames.first(where: { $0.url == frame.url }), canFlag(current), isOn != isFlagged(current),
              let identity = flagIdentity(current) else { return }
        registerFlagUndo(!isOn, for: current)
        flagged[current.url] = isOn ? identity : nil
        // A kept entry of the same raw would flag it again on the next open.
        otherFlags.removeAll { $0.matches(identity) }
        if flagFilter != .all { shownFramesChanged() }
        saveFlags()
    }

    /// Flags or unflags several frames at once, as one step: Frame > Flag and F with several selected, and their menu.
    /// The frames already as asked, and those whose raw is not known, are left; Edit > Undo puts the others back together.
    func setFlag(_ isOn: Bool, for frames: [Frame]) {
        guard frames.count != 1 else { return setFlag(isOn, for: frames[0]) }
        guard let roll, canChangeFlags else { return }
        let wanted = Set(frames.map(\.url))
        let changing = roll.frames.filter { wanted.contains($0.url) && isOn != isFlagged($0) }
            .compactMap { frame in flagIdentity(frame).map { (frame, $0) } }
        guard !changing.isEmpty else { return }
        registerFlagsUndo(!isOn, for: changing.map(\.0.url))
        var flags = flagged
        for (frame, identity) in changing {
            flags[frame.url] = isOn ? identity : nil
            otherFlags.removeAll { $0.matches(identity) }
        }
        flagged = flags
        if flagFilter != .all { shownFramesChanged() }
        saveFlags()
    }

    /// Edit > Undo Flag 3 Frames: every frame of the step back as it was, the selection left where it is.
    private func registerFlagsUndo(_ wasOn: Bool, for urls: [URL]) {
        guard let undo = manualUndoManager, let folder = roll?.folder else { return }
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard target.roll?.folder == folder, let frames = target.roll?.frames.filter({ urls.contains($0.url) }) else { return }
                target.setFlag(wasOn, for: frames)
            }
        }
        if !undo.isUndoing, !undo.isRedoing { undo.setActionName("\(wasOn ? "Unflag" : "Flag") \(Self.framesTitle(urls.count))") }
    }

    /// Edit > Undo Flag or Undo Unflag, on the window's undo manager with the manual edits'
    /// (`manualUndoManager`), so ⌘Z goes back through both in the order they were made. Its actions
    /// name the roll's folder, and go with the manual edits' when a roll opens (`clearManualSession`).
    private func registerFlagUndo(_ wasOn: Bool, for frame: Frame) {
        guard let undo = manualUndoManager, let folder = roll?.folder else { return }
        let url = frame.url
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreFlag(wasOn, url: url, folder: folder) }
        }
        // Undo and Redo keep the name of the change they go back over.
        if !undo.isUndoing, !undo.isRedoing { undo.setActionName(wasOn ? "Unflag" : "Flag") }
    }

    /// Undo or Redo of a flag: saved as any flag change is, and on the sheet that frame selected where
    /// it shows. A change that cannot be made now, such as while a roll opens, is dropped.
    private func restoreFlag(_ isOn: Bool, url: URL, folder: URL) {
        guard roll?.folder == folder, let frame = roll?.frames.first(where: { $0.url == url }) else { return }
        setFlag(isOn, for: frame)
        guard !isFrameOpen, isFlagged(frame) == isOn, isShown(frame) else { return }
        selection = frame.id
        selectionAnchor = nil
    }

    /// View > Show and the filter above the sheet and above the Develop page's grid.
    var canChangeFilter: Bool { roll != nil }

    func showFrames(_ filter: FlagFilter) {
        guard canChangeFilter else { return }
        flagFilter = filter
    }

    /// The stock panel's frame: the one selected, else, while the filter shows none, the one the
    /// selection comes back to, else the roll's first.
    var paletteFrame: Frame? {
        if let selectedFrame { return selectedFrame }
        guard let roll else { return nil }
        if let anchor = selectionAnchor, roll.frames.indices.contains(anchor) { return roll.frames[anchor] }
        return roll.frames.first
    }

    /// The frames the frame view decodes ahead from `frame`: the next one the arrows go to in the
    /// direction of travel, and the one behind, among those the sheet shows.
    func framesAround(_ frame: Frame) -> (ahead: Frame?, behind: Frame?) {
        guard let roll else { return (nil, nil) }
        func neighbour(_ offset: Int) -> Frame? {
            guard let id = shownFrame(from: frame.id, by: offset), id != frame.id, roll.frames.indices.contains(id) else { return nil }
            return roll.frames[id]
        }
        return (neighbour(travel), neighbour(-travel))
    }

    /// What the menu bar needs of the selection (`selectionFlag`), set only when it changes. At once when the roll, the selection,
    /// a flag or a raw's version changes, each of which notes it as it is set, so a test or a key that follows reads it current;
    /// `followSelectionFlag` brings it up to date a turn after anything else it reads changes.
    func noteSelectionFlag() {
        let now = selectionFacts()
        if now != selectionFlag { selectionFlag = now }
    }

    /// Notes the selection's facts, and again a turn after anything they read changes, as `followMenuState` does for the menus:
    /// the frame's edit, written in many places (a paste, a reset from a cell's menu, an undo, a restore after the roll opens),
    /// the clipboard, a develop. It observes the selection too, but sets `selectionFlag` only when a fact differs, so the
    /// menus, which read that and not the selection, are not asked again. Started once, as the model is made.
    func followSelectionFlag() {
        let now = withObservationTracking { selectionFacts() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followSelectionFlag() }
        }
        if now != selectionFlag { selectionFlag = now }
    }

    private func selectionFacts() -> SelectionFlag {
        guard let frame = selectedFrame else { return SelectionFlag() }
        let frames = selectedFrames
        guard frames.count > 1 else {
            return SelectionFlag(isSelected: true, canChangeFrames: canChangeFrames([frame]),
                                 isKnown: flagIdentity(frame) != nil, isFlagged: isFlagged(frame),
                                 canCopy: canCopyAdjustments(from: frame), canPaste: canPasteAdjustments(to: frame),
                                 pasteOnly: AdjustmentParts(AdjustmentParts.each.filter { canPasteAdjustments(to: frame, parts: $0) }),
                                 canDevelopFrame: canDevelopFrame(frame), hasDevelopedFile: hasDevelopedRecord(for: frame))
        }
        // Several: Flag flags them unless every one is flagged, Copy takes the lead's, and the rest are for them all.
        return SelectionFlag(isSelected: true, isSeveral: true, canChangeFrames: canChangeFrames(frames),
                             isKnown: frames.contains { flagIdentity($0) != nil }, isFlagged: areAllFlagged(frames),
                             canCopy: canCopyAdjustments(from: frame), canPaste: canPasteAdjustments(to: frames),
                             pasteOnly: AdjustmentParts(AdjustmentParts.each.filter { canPasteAdjustments(to: frames, parts: $0) }),
                             canDevelopFrame: canDevelop(frames), hasDevelopedFile: frames.contains(where: hasDevelopedRecord))
    }

    /// The roll's flags as `stored`, matched to its raws as `identities` say they are now; entries
    /// matching none are kept for its next save. One this build cannot read is left alone, and the
    /// roll says its flags will not be saved.
    func restoreFlags(_ stored: FlagStore.Stored, identities: [URL: FlagRecord.Entry]) {
        switch stored {
        case .record(let record):
            (flagged, otherFlags) = record.matched(to: identities)
            areFlagsUnsaved = false
        case .none:
            (flagged, otherFlags) = ([:], [])
            areFlagsUnsaved = false
        case .unreadable, .future:
            (flagged, otherFlags) = ([:], [])
            areFlagsUnsaved = true
            message = Self.unsavedFlagsLine
        }
    }

    /// The frames at `urls` whose raws changed while the roll is open: a flag stays with the raw it
    /// was given to, so a raw replaced by another loses it, kept for its next save, and one that
    /// comes back has it again.
    func refreshFlags(_ urls: some Collection<URL>) {
        guard let roll, !(flagged.isEmpty && otherFlags.isEmpty) else { return }
        var changed = false
        for url in urls {
            guard let frame = roll.frames.first(where: { $0.url == url }) else { continue }
            // A raw gone, or one whose header cannot be read, is not the flagged raw until it is back.
            let identity = flagIdentity(frame)
            if let entry = flagged[url], identity.map(entry.matches) != true {
                flagged[url] = nil
                otherFlags.append(entry)
                changed = true
            }
            if flagged[url] == nil, let identity, let kept = otherFlags.firstIndex(where: { $0.matches(identity) }) {
                flagged[url] = otherFlags.remove(at: kept)
                changed = true
            }
        }
        if changed, flagFilter != .all { shownFramesChanged() }
    }

    /// Writes the roll's flags, its own and those kept for other raws, after any write before it.
    func saveFlags() {
        guard let roll else { return }
        guard !areFlagsUnsaved else {
            message = Self.unsavedFlagsLine
            return
        }
        let record = FlagRecord(frames: otherFlags + roll.frames.compactMap { flagged[$0.url] })
        let store = flagStore, folder = roll.folder, previous = flagSave
        flagSave = Task.detached(priority: .utility) {
            await previous?.value
            do {
                guard try store.save(record, for: folder) else {
                    Self.flagLog.notice("left a flags file this build cannot read for \(folder.lastPathComponent, privacy: .public)")
                    await self.flagsNotSaved(Self.unsavedFlagsLine, folder: folder, refused: true)
                    return
                }
            } catch {
                Self.flagLog.error("flags not kept: \(error.localizedDescription, privacy: .public)")
                await self.flagsNotSaved("Could not save this roll’s flags: \(error.localizedDescription)", folder: folder, refused: false)
            }
        }
    }

    /// A write of the flags of the roll at `folder` failed, or found a file it must leave: said on
    /// that roll, if it is still open.
    private func flagsNotSaved(_ line: String, folder: URL, refused: Bool) {
        guard roll?.folder == folder else { return }
        if refused { areFlagsUnsaved = true }
        message = line
    }

    /// The frames shown have changed: a selection the filter leaves out moves to a frame it shows,
    /// and a finished develop's Reveal in Finder gives way, since Develop would develop other frames.
    func shownFramesChanged() {
        keepSelectionShown()
        if developPhase == .done { developPhase = .idle }
    }

    /// On the sheet, a selection the filter leaves out moves to a frame it shows: the next after it in
    /// capture order, else the one before; with `nearest`, the nearer of the two, the later when
    /// they are as near. To none when the sheet shows nothing, and back near there when it shows
    /// frames again. In the frame view the open frame stays.
    func keepSelectionShown(nearest: Bool = false) {
        guard !isFrameOpen, let roll else { return }
        let shown = shownFrames
        guard let anchor = selection ?? selectionAnchor else {
            selection = shown.first?.id
            return
        }
        if roll.frames.indices.contains(anchor), isShown(roll.frames[anchor]) {
            // The lead stays, with the frames selected beside it that still show.
            if selection != anchor { selection = anchor }
            selectionAnchor = nil
            keepSelectedShown()
            return
        }
        let after = shown.first { $0.id > anchor }, before = shown.last { $0.id < anchor }
        var target = after ?? before
        if nearest, let after, let before, anchor - before.id < after.id - anchor { target = before }
        selection = target?.id
        selectionAnchor = target == nil ? anchor : nil
    }

    /// The frame `offset` frames on from `id` among those the sheet shows, clamped to them; from a
    /// frame the filter leaves out, the shown frames after it or before it in capture order count
    /// from it. `nil` when the sheet shows none that way; from no frame, the steps count from the first.
    func shownFrame(from id: Frame.ID?, by offset: Int) -> Frame.ID? {
        let shown = shownFrames
        guard !shown.isEmpty else { return nil }
        let current = id ?? shown[0].id
        let index: Int
        if let position = shown.firstIndex(where: { $0.id == current }) {
            index = position + offset
        } else if offset > 0, let after = shown.firstIndex(where: { $0.id > current }) {
            index = after + offset - 1
        } else if offset < 0, let before = shown.lastIndex(where: { $0.id < current }) {
            index = before + offset + 1
        } else {
            return nil
        }
        return shown[min(max(index, 0), shown.count - 1)].id
    }

    /// Whether the arrows have a frame to move to that way.
    func canStep(by offset: Int) -> Bool {
        guard let target = shownFrame(from: selection, by: offset) else { return false }
        return target != selection
    }

    /// Where the open frame is among those shown, "3 of 12", or why the filter leaves it out, "Not
    /// flagged" or "Flagged"; with All Frames, its place in the roll.
    func shownPosition(of frame: Frame) -> String {
        guard let roll else { return "" }
        guard flagFilter != .all else { return "\(frame.id + 1) of \(roll.frames.count)" }
        let shown = shownFrames
        guard let position = shown.firstIndex(where: { $0.id == frame.id }) else { return isFlagged(frame) ? "Flagged" : "Not flagged" }
        return "\(position + 1) of \(shown.count)"
    }

    /// "Flagged · 12 of 340 frames" with a filter on, "340 frames" with All Frames; then "· 3 selected" while several are.
    var shownCountText: String {
        let total = roll?.frames.count ?? 0
        let frames = total == 1 ? "1 frame" : "\(total) frames"
        let selected = selectedCountText.map { " · \($0)" } ?? ""
        guard flagFilter != .all else { return frames + selected }
        return "\(flagFilter.title) · \(shownFrames.count) of \(frames)" + selected
    }
}
