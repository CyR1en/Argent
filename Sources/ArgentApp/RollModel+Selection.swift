import AppKit
import ArgentRoll
import Foundation

/// Several frames selected at once, on the roll's contact sheet and the Develop page's grid (docs/M2-shell.md, section 25).
///
/// One frame is always the lead (`selection`): the one the arrows move from, Return opens and the stock panel shows.
/// The frames selected (`selected`) hold it, by the rules the import's review shares (`MultiSelection`). A plain click,
/// an arrow, and everything else that sets the lead leaves it alone selected. Only frames the sheet shows are ever
/// selected, so a filter that leaves some out drops them (`keepSelectionShown`), and the frame view, which shows one
/// frame, opens with its frame alone selected.
extension RollModel {
    /// The frames selected, in capture order: the lead alone, or the several selected.
    var selectedFrames: [Frame] {
        guard selected.count > 1, let roll else { return selectedFrame.map { [$0] } ?? [] }
        return roll.frames.filter { selected.contains($0.id) }
    }

    /// Whether more than one frame is selected.
    var hasSeveralSelected: Bool { selected.count > 1 }

    func isSelected(_ frame: Frame) -> Bool { selected.contains(frame.id) }

    /// The frames a menu opened on `frame` acts on: the frames selected when it is one of several, as in Finder, else
    /// the frame alone.
    func framesActedOn(from frame: Frame) -> [Frame] {
        selected.count > 1 && selected.contains(frame.id) ? selectedFrames : [frame]
    }

    /// The frames the sheet shows, by number, in its order: what a range runs over.
    private var shownIDs: [Frame.ID] { shownFrames.map(\.id) }

    /// A click on `frame`'s cell on the sheet.
    func select(_ frame: Frame, _ click: SelectionClick = .alone) {
        guard !isFrameOpen, click != .alone, isShown(frame), selection != nil else {
            selection = frame.id
            return
        }
        let shown = shownIDs
        changeSelection { click == .toggle ? $0.toggle(frame.id, in: shown) : $0.selectRange(to: frame.id, in: shown) }
    }

    /// Shift with an arrow: the lead moves by `offset` of the frames shown, and every frame from the pivot to it is selected.
    func extendSelection(by offset: Int) {
        guard !isFrameOpen, let target = shownFrame(from: selection, by: offset) else { return }
        let shown = shownIDs
        changeSelection { $0.selectRange(to: target, in: shown) }
    }

    /// Shift with Home or End: from the pivot to the first or the last frame shown.
    func extendSelection(toLast last: Bool) {
        let shown = shownIDs
        guard !isFrameOpen, let target = last ? shown.last : shown.first else { return }
        changeSelection { $0.selectRange(to: target, in: shown) }
    }

    /// Whether Select All has frames to select: the sheet or the Develop page's grid is up with frames on it.
    var canSelectAll: Bool {
        !isFrameOpen && (workspacePage == .roll || workspacePage == .develop) && !shownFrames.isEmpty
    }

    /// Edit > Select All: every frame the sheet shows. The lead stays where it is, or is the first frame shown.
    func selectAllShown() {
        guard canSelectAll else { return }
        let shown = shownIDs
        changeSelection { $0.selectAll(in: shown) }
    }

    /// The lead alone again.
    func collapseSelection() {
        changeSelection { $0.collapse() }
    }

    /// The frames selected that the sheet no longer shows leave the selection; the lead stays (`keepSelectionShown`).
    func keepSelectedShown() {
        guard selected.count > 1 else { return }
        let shown = shownIDs
        changeSelection { $0.keep(in: shown) }
    }

    // MARK: What acts on the frames selected

    /// "3 frames selected" for the title strip, while more than one is.
    var selectedCountText: String? {
        selected.count > 1 ? "\(selected.count) selected" : nil
    }

    /// Edit > Paste Adjustments and a frame's menu, on the frames selected: one frame as a paste on it, several as one
    /// step on all of them but the frame the adjustments were copied from.
    func pasteAdjustments(to frames: [Frame], parts: AdjustmentParts = .all) {
        guard frames.count > 1 else {
            frames.first.map { pasteAdjustments(to: $0, parts: parts) }
            return
        }
        guard canPasteAdjustments(to: frames, parts: parts), let clipboard = adjustmentsClipboard else { return }
        let targets = frames.filter { $0.url != clipboard.source }
        guard !targets.isEmpty else { return }
        paste(clipboard, parts: parts, to: targets, batch: true)
    }

    /// Whether a paste of `parts` can be asked for on `frames`: on one as `canPasteAdjustments(to:parts:)` says, on
    /// several when one of them is not the frame the adjustments came from.
    func canPasteAdjustments(to frames: [Frame], parts: AdjustmentParts = .all) -> Bool {
        guard let first = frames.first, canPasteAdjustments(to: first, parts: parts) else { return false }
        return frames.count == 1 || frames.contains { $0.url != adjustmentsClipboard?.source }
    }

    /// Whether a develop of `frames` can start: Develop's own rule, for frames of the roll.
    func canDevelop(_ frames: [Frame]) -> Bool {
        guard canStartDevelop, developAsksSettings || developDestination != nil, !frames.isEmpty, let all = roll?.frames else { return false }
        return frames.allSatisfy { all.indices.contains($0.id) && all[$0.id].url == $0.url }
    }

    /// Develop This Frame for several: these frames alone, as Develop This Frame develops one (`developFrame`). While the
    /// sheet shows other frames too the Develop page's button stays Develop, since they are not developed.
    func developFrames(_ frames: [Frame]) {
        guard canDevelop(frames) else { return }
        chosenDevelop = Set(frames.map(\.url))
        develop(frames: frames.map(\.url))
    }

    /// Frame > Develop This Frame, or Develop Selected Frames with several selected: on the roll through the quick
    /// develop dialog, on the Develop page at once (`askToDevelop`).
    func developSelection() {
        askToDevelop(selectedFrames)
    }

    /// Frame > Show RAW in Finder, for the frame or the frames selected.
    func showSelectionInFinder() {
        let frames = selectedFrames
        if frames.count > 1 { showInFinder(frames) } else { frames.first.map { showInFinder($0) } }
    }

    /// Frame > Show Developed File in Finder, for the frame or the frames selected.
    func showSelectionDevelopedInFinder() {
        let frames = selectedFrames
        if frames.count > 1 { showDevelopedInFinder(frames) } else { frames.first.map { showDevelopedInFinder($0) } }
    }

    /// The frames' raws, selected in Finder.
    func showInFinder(_ frames: [Frame]) {
        guard !frames.isEmpty else { return }
        FinderReveal.show(frames.map(\.url))
    }

    /// The files the frames' last develops wrote, those still there, selected in Finder.
    func showDevelopedInFinder(_ frames: [Frame]) {
        let files = frames.compactMap { developedFile(for: $0) }
        guard !files.isEmpty else {
            NSSound.beep()
            announce(frames.count == 1 ? "\(frames[0].name)'s developed file is no longer where it was written"
                     : "The frames' developed files are no longer where they were written")
            return
        }
        FinderReveal.show(files)
    }
}
