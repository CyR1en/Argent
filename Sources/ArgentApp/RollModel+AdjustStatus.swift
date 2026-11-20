import ArgentRoll
import Foundation

/// What the Adjust inspector's save line says (docs/manual-development.md, "Autosave"). Edits save
/// themselves; the line says where the frame stands rather than offering a Save.
enum AdjustSaveStatus: Equatable {
    /// The frame has no refinement of its own: it shows Auto as it is, so there is nothing of its
    /// own to save.
    case unadjusted
    /// A save is under way. The writer saves edits one after another across the roll, so this is
    /// the roll's state, as the save failure is.
    case saving
    /// The frame's refinement, and every save since, has been written.
    case saved
    /// A save failed, with the writer's message; Retry saves again only the frames whose saves failed.
    case failed(String)
}

/// The inspector's word for its starting point's comparison, so the five tabs name it the
/// same way: **Compare to Auto**, or **Compare to Original** for a frame that starts there, on all of
/// them. Neutral RAW (Space) is a separate comparison with its own label. The resets beside it are a menu's rows
/// (`InspectorMenus.resetMenu`).
enum AdjustActionText {
    /// The hold-to-compare button, on any tab.
    static func compare(from origin: AutomaticBaseline.Origin) -> String {
        origin == .original ? "Compare to Original" : "Compare to Auto"
    }
}

extension RollModel {
    /// The save line for `frame`: a failure first, since it needs the photographer, then a save under
    /// way, then whether the frame has anything of its own saved. `manualSaveMessage` is set while any
    /// save runs and cleared when the latest has been written (`saveManualFrame`).
    func adjustSaveStatus(for frame: Frame) -> AdjustSaveStatus {
        if manualSaveFailed { return .failed(manualSaveMessage ?? "Could not save adjustments.") }
        // This frame's alone: a seed that is nowhere keeps its edit from being saved.
        if maskSeedUnsaved.contains(frame.url) {
            return .failed(maskSeedIssue(for: frame) ?? missingPatchIssue(for: frame)
                           ?? "This frame’s adjustments are not saved: a mask’s selection is missing.")
        }
        if manualSaveMessage != nil { return .saving }
        return hasManualAdjustments(frame) || heldManualEdits[frame.url] != nil ? .saved : .unadjusted
    }

    /// What the frame waits for before it can be refined, while it has no issue: its Original's
    /// guards, Auto's on screen, or the roll's settled decision, which a first edit from Auto pins
    /// (docs/manual-development.md, "Automatic baseline"). Nil once it can be refined.
    func adjustPreparation(for frame: Frame) -> String? {
        guard manualIssue(for: frame) == nil, !canAdjust(frame) else { return nil }
        if startingPoint(for: frame) == .original { return "Preparing Original…" }
        return isBalanced || hasManualAdjustments(frame) ? "Preparing Auto…" : "Balancing roll…"
    }
}
