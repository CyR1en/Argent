import ArgentCore
import ArgentRoll
import Foundation

/// The quick develop dialog's choices (`QuickDevelopSheet`): the frames a menu's Develop was asked for, and where their
/// files go and as what, as the dialog has them. They start as the roll's folder (`RollModel.developDestination`) and
/// the output choices kept for every roll (`RollModel.output`), and become those when Develop is pressed
/// (`RollModel.confirmQuickDevelop`); Cancel leaves both as they were.
struct QuickDevelop: Equatable {
    /// The frames to develop, by file, in capture order.
    let frames: [URL]
    /// Format, quality, colour space and grain.
    var output: OutputSettings
    /// The folder the files go to.
    var folder: DevelopFolder
}

/// What the quick develop dialog's Grain row says of its frames' own grain (`RollModel.quickDevelopGrain`). Its Grain is the
/// Develop page's, the roll's, and a frame's own, from its film settings, stands over it.
struct QuickDevelopGrain: Equatable {
    /// One frame with its own grain: that grain, which the row shows in place of the roll's and does not change.
    var own: OutputSettings.Grain?
    /// The line under the row.
    var note: String
}

/// Develop This Frame and Develop N Frames, from a frame's menu or the Frame menu (docs/M2-shell.md, section 26). On
/// the roll, its sheet or one frame, where nothing says where a develop goes or as what, they ask first: the quick
/// develop dialog, with the folder and the output choices of the Develop page's panel, and the develop starts from its
/// button. On the Develop page the panel beside the grid has them in sight, and the frames develop at once.
extension RollModel {
    /// Whether a develop of frames asked for from a menu asks its settings first: on the roll, where the dialog shows.
    var developAsksSettings: Bool { workspacePage == .roll }

    /// A menu row's title for such a develop: with an ellipsis where it asks before it acts.
    func developTitle(_ title: String) -> String { developAsksSettings ? title + "…" : title }

    /// A menu's Develop This Frame or Develop N Frames: the dialog for `frames` on the roll, their develop on the
    /// Develop page, and nothing on any other page, where neither is in sight. While a dialog is up it is that
    /// dialog's, and asking again would start its choices over: nothing happens.
    func askToDevelop(_ frames: [Frame]) {
        guard quickDevelop == nil, workspacePage == .roll || workspacePage == .develop, canDevelop(frames) else { return }
        guard developAsksSettings else {
            developNow(frames)
            return
        }
        quickDevelop = QuickDevelop(frames: frames.map(\.url), output: output, folder: developFolder)
    }

    /// The frames the dialog develops, as the roll has them now, in capture order.
    var quickDevelopFrames: [Frame] { quickDevelop.map { framesToDevelop($0.frames) } ?? [] }

    /// What the dialog's Grain row says of `frames`' own grain: for one frame with its own, that grain, shown and not changed
    /// there, since the row sets the roll's, which that frame does not follow; for several, some with their own, that the row
    /// sets the roll's and how many keep theirs. `nil` while every frame follows the roll's.
    func quickDevelopGrain(for frames: [Frame]) -> QuickDevelopGrain? {
        let own = frames.compactMap { frameControls($0).grain }
        guard let first = own.first else { return nil }
        if frames.count == 1 { return QuickDevelopGrain(own: first, note: "This frame's own grain, from its film settings.") }
        let keep = own.count == frames.count ? "each of these frames keeps its own"
            : own.count == 1 ? "1 of these frames keeps its own" : "\(own.count) of these frames keep their own"
        return QuickDevelopGrain(own: nil, note: "Sets the roll's grain; \(keep).")
    }

    /// Whether the dialog's Develop can start its develop now: Develop's own rule, which may have changed under the
    /// dialog, as when another roll starts to open.
    var canConfirmQuickDevelop: Bool { quickDevelop?.folder.destination != nil && canDevelop(quickDevelopFrames) }

    /// The dialog's Develop: its choices become the roll's folder and the output choices kept for every roll, as if
    /// made on the Develop page, and its frames develop with them.
    func confirmQuickDevelop() {
        guard let asked = quickDevelop else { return }
        let frames = quickDevelopFrames
        guard asked.folder.destination != nil, canDevelop(frames) else { return }
        quickDevelop = nil
        if asked.output != output { output = asked.output }
        developFolder = asked.folder
        developNow(frames)
    }

    /// The dialog's Cancel, Escape and a click beside it: nothing develops and nothing changes.
    func cancelQuickDevelop() {
        if quickDevelop != nil { quickDevelop = nil }
    }

    /// One frame as Develop This Frame develops it, several as the frames selected.
    private func developNow(_ frames: [Frame]) {
        if frames.count > 1 { developFrames(frames) } else { frames.first.map(developFrame) }
    }
}
