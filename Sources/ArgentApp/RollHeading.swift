import ArgentRoll
import SwiftUI

/// What the title strip says about the roll or the frame (WorkspaceTopBar): the roll's or the
/// frame's name, and the whole line about it, which the strip shortens and gives in full to its help
/// tag and VoiceOver.
@MainActor enum RollHeading {
    /// The roll's name on the sheet, the frame's in the frame view.
    static func title(_ model: RollModel) -> String? {
        if model.isFrameOpen, let frame = model.selectedFrame { return frame.name }
        return model.roll?.name
    }

    /// On the sheet when the roll was shot, its size, or with a filter on how many of its frames show
    /// ("Flagged · 12 of 340 frames"), and the camera; in the frame view where the frame is in the
    /// roll, or among the frames shown ("3 of 12"), what is showing (the stock or the neutral raw),
    /// whether the last develop could not write it, and its exposure. Either ends in "Balancing
    /// roll…" while the roll's aims are its frames' own, before it settles; a develop's row says so
    /// while it runs.
    static func subtitle(_ model: RollModel) -> String {
        guard let roll = model.roll else { return "" }
        let balancing = model.isBalancing && !model.isDeveloping ? ["Balancing roll…"] : []
        if model.isFrameOpen, let frame = model.selectedFrame {
            var parts = [model.shownPosition(of: frame)]
            if model.isNeutralShown {
                parts.append("Neutral raw")
            } else if let stock = model.stockName(for: frame) {
                parts.append(stock)
            }
            if !model.isDeveloping, model.lastDevelop?.failure(for: frame.url) != nil { parts.append("not developed") }
            if model.isOverridden(frame) { parts.append("own settings") }
            if model.hasManualAdjustments(frame) { parts.append("edited") }
            parts += exposure(frame)
            return (parts + balancing).joined(separator: " · ")
        }
        var parts: [String] = []
        if let days = days(roll.frames) { parts.append(days) }
        parts.append(model.shownCountText)
        if let camera = camera(roll.frames) { parts.append(camera) }
        return (parts + balancing).joined(separator: " · ")
    }

    /// "1/250 s", "ƒ/4", "ISO 100", as far as the Exif gives them.
    static func exposure(_ frame: Frame) -> [String] {
        var parts: [String] = []
        if let seconds = frame.info.exposureTime, seconds.isFinite, seconds > 0 {
            if seconds >= 1 {
                let whole = seconds.rounded()
                parts.append(abs(seconds - whole) < 0.05 ? "\(Int(whole)) s" : String(format: "%.1f s", seconds))
            } else {
                let reciprocal = 1 / seconds
                parts.append(abs(reciprocal - reciprocal.rounded()) < 0.05 * reciprocal
                             ? "1/\(Int(reciprocal.rounded())) s" : String(format: "%.1f s", seconds))
            }
        }
        if let f = frame.info.fNumber, f > 0 {
            parts.append(f.rounded() == f ? "ƒ/\(Int(f))" : String(format: "ƒ/%.1f", f))
        }
        if let iso = frame.info.iso { parts.append("ISO \(iso)") }
        return parts
    }

    /// The day the roll was shot, or the days from its first frame to its last. Capture times
    /// are the camera's wall clock, read as UTC, so they are shown in UTC.
    static func days(_ frames: [Frame]) -> String? {
        let dates = frames.compactMap(\.info.captureDate)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return dayFormat.string(from: first, to: last)
    }

    /// The camera, when the whole roll is from one Argent knows: "Sony α7 IV" for the a7 IV.
    /// A model string it does not know, which a file's header may hold in place of the body's,
    /// is left out rather than shown.
    static func camera(_ frames: [Frame]) -> String? {
        let models = Set(frames.map(\.info.model).filter { !$0.isEmpty })
        guard models.count == 1, let model = models.first else { return nil }
        return cameraNames[model]
    }

    private static let cameraNames = ["ILCE-7M4": "Sony α7 IV", "ILCE-7C": "Sony α7C"]

    private static let dayFormat: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}
