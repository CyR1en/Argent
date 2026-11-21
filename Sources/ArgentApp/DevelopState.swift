import ArgentCore
import ArgentRoll
import Foundation

/// The chosen parent and the editable name stay separate so changing either never nests a folder twice.
struct DevelopFolder: Equatable {
    var base: URL
    var usesSubfolder: Bool
    var rollName: String
    var customSubfolderName: String?

    var subfolderName: String {
        get { customSubfolderName ?? rollName }
        set { customSubfolderName = newValue }
    }

    var destination: URL? {
        guard usesSubfolder else { return base }
        let name = subfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.unicodeScalars.contains("/"), !name.unicodeScalars.contains("\0") else { return nil }
        return base.appendingPathComponent(name, isDirectory: true)
    }
}

/// The one next action the button at the foot of the Develop page's panel offers, from the develop's
/// phase and the last develop's report: Develop the frames shown, Stop while one runs, Resume a stopped
/// one, Develop again after frames failed, and Reveal in Finder once every frame has a file. The status
/// over it says the rest of a develop's state, with secondary actions only, so the button is never a
/// second copy of a choice beside it.
enum DevelopPrimary: Equatable {
    /// Develop the frames a develop now covers: the frames shown (`RollModel.framesToDevelop()`).
    case develop(count: Int)
    /// A develop is running: the button is its progress and stops it.
    case stop(DevelopProgress)
    /// Go on with a stopped develop's own frames, not started or failed.
    case resume(DevelopReport)
    /// Frames failed and none were left unstarted: develop the frames shown again; the frames
    /// already developed with these settings are skipped, so it is the failed ones that develop.
    case developAgain(failed: Int)
    /// Every frame of the last develop has a file, and nothing that changes them has changed since.
    case reveal

    /// What the button shows after `report`, in `phase`, with `count` frames to develop now.
    ///
    /// A stopped or failed develop's action stands while its status does (`issuesDismissed`
    /// false), until the next develop finishes or another roll opens. Closing it hands the button
    /// back to Develop with the count of the frames shown, so the filter and the count stay one; the
    /// frames not developed are still among them, and a develop skips those already done.
    static func resolve(phase: DevelopPhase, report: DevelopReport?, count: Int,
                        issuesDismissed: Bool = false) -> DevelopPrimary {
        if case .developing(let progress) = phase { return .stop(progress) }
        if let report, report.wasStopped, !issuesDismissed { return .resume(report) }
        if let report, !report.failures.isEmpty, !issuesDismissed { return .developAgain(failed: report.failures.count) }
        if phase == .done { return .reveal }
        return .develop(count: count)
    }

    /// The button's label: "Develop 24", "7 of 24", "Resume", "Develop again", "Reveal in Finder".
    var title: String {
        switch self {
        case .develop(let count): return count > 0 ? "Develop \(count)" : "Develop"
        case .stop(let progress): return "\(progress.processed) of \(progress.total)"
        case .resume: return "Resume"
        case .developAgain: return "Develop again"
        case .reveal: return "Reveal in Finder"
        }
    }

    /// The widest label this action takes, so a count running up does not move the button: the
    /// digits are tabular, so the total stands in for every count.
    var template: String {
        if case .stop(let progress) = self { return "\(progress.total) of \(progress.total)" }
        return title
    }

    /// What VoiceOver calls the button; while a develop runs it is the Stop button, its count the value.
    var accessibilityLabel: String {
        switch self {
        case .develop(let count): return count == 1 ? "Develop 1 frame" : count > 0 ? "Develop \(count) frames" : "Develop"
        case .stop: return "Stop Developing"
        default: return title
        }
    }

    var accessibilityValue: String {
        if case .stop(let progress) = self { return progress.label }
        return ""
    }

    var accessibilityHint: String {
        switch self {
        case .develop: return ""
        case .stop: return "Stops after the frames in progress."
        case .resume(let report): return "Develops the \(DevelopStatusText.frames(report.total - report.developed)) the stopped develop did not finish."
        case .developAgain: return "Develops the frames shown; frames already developed with these settings are skipped."
        case .reveal: return "Shows the developed files in Finder."
        }
    }

    /// The help tag, with the action's key.
    func help(filtered: Bool) -> String {
        switch self {
        case .develop(let count):
            if count == 0 { return "No frames are shown to develop" }
            return filtered ? "Develop the \(DevelopStatusText.frames(count)) shown. Command-D." : "Develop the roll. Command-D."
        case .stop: return "Stop after the frames in progress; Resume goes on with the rest. Command-Period."
        case .resume(let report):
            return "Go on with the stopped develop's \(DevelopStatusText.frames(report.total - report.developed)); frames already developed with these settings are skipped."
        case .developAgain(let failed):
            return "Develop the frames shown again: those already developed with these settings are skipped, so the \(failed == 1 ? "frame" : "\(failed) frames") that failed develop again. Command-D."
        case .reveal: return "Show the developed files in Finder. Shift-Command-R."
        }
    }
}

/// What the Develop page's status says over its button, or `nil` before a develop and once one's
/// status is closed: a develop under way; one that finished with every frame written; one that was
/// stopped; one whose frames failed.
enum DevelopStatus: Equatable {
    /// `balancing` while the develop waits for the roll's settled Auto decision.
    case developing(DevelopProgress, balancing: Bool)
    case complete(DevelopReport)
    case stopped(DevelopReport)
    case failed(DevelopReport)

    /// The status for `phase` and the last develop's `report`. A develop that finished with every frame
    /// written shows until a setting turns Reveal back into Develop; one that stopped or left frames
    /// behind shows until it is closed (`issuesDismissed`), whatever the phase: a develop with some files
    /// and some failures is `.done` and still has frames to go.
    static func resolve(phase: DevelopPhase, report: DevelopReport?, balancing: Bool,
                        issuesDismissed: Bool) -> DevelopStatus? {
        if case .developing(let progress) = phase { return .developing(progress, balancing: balancing) }
        guard let report else { return nil }
        if report.wasStopped { return issuesDismissed ? nil : .stopped(report) }
        if !report.failures.isEmpty { return issuesDismissed ? nil : .failed(report) }
        return phase == .done ? .complete(report) : nil
    }

    /// The finished develop's report; `nil` while one runs.
    var report: DevelopReport? {
        switch self {
        case .developing: return nil
        case .complete(let report), .stopped(let report), .failed(let report): return report
        }
    }

    /// A stopped or failed develop, whose status can be closed.
    var isUnfinished: Bool {
        switch self {
        case .stopped, .failed: return true
        default: return false
        }
    }
}

/// The Develop page's words for a develop, from its progress or report.
enum DevelopStatusText {
    /// "1 frame", "24 frames".
    static func frames(_ count: Int) -> String { count == 1 ? "1 frame" : "\(count) frames" }

    /// The heading of a finished, stopped or failed develop.
    static func title(_ state: DevelopStatus) -> String {
        switch state {
        case .developing(_, let balancing): return balancing ? "Balancing roll…" : "Developing roll"
        case .complete: return "Roll developed"
        case .stopped: return "Develop stopped"
        case .failed(let report):
            return report.developed == 0 ? "Develop failed"
                : report.failures.count == 1 ? "1 frame not developed" : "\(report.failures.count) frames not developed"
        }
    }

    /// The counts under the heading: "7 of 24 frames" while developing, "24 of 24 frames saved",
    /// "8 frames saved · 16 remaining" after a stop (with "· 1 failed" when frames failed before it),
    /// "21 of 24 frames saved · 3 failed". Saved frames are those with a file, written now or found
    /// from the same recipe; remaining are the frames Resume goes on with that were not started.
    static func counts(_ state: DevelopStatus) -> String {
        switch state {
        case .developing(let progress, _):
            let line = "\(progress.processed) of \(frames(progress.total))"
            return progress.failed > 0 ? "\(line) · \(progress.failed) failed" : line
        case .complete(let report):
            return "\(report.developed) of \(frames(report.total)) saved"
        case .stopped(let report):
            var parts = ["\(frames(report.developed)) saved"]
            if !report.failures.isEmpty { parts.append("\(report.failures.count) failed") }
            parts.append("\(report.stopped) remaining")
            return parts.joined(separator: " · ")
        case .failed(let report):
            return "\(report.developed) of \(frames(report.total)) saved · \(report.failures.count) failed"
        }
    }

    /// The line under the destination: what Resume does after a stop, and why frames failed.
    static func detail(_ state: DevelopStatus) -> String? {
        switch state {
        case .stopped: return "Resume continues with the remaining frames"
        case .failed(let report):
            if let shared = report.sharedReason { return shared }
            if report.failures.count == 1, let reason = report.failures.first?.reason { return reason }
            return "Each frame's reason is in Details"
        default: return nil
        }
    }

    /// The captured stocks' shared name, or "Mixed stocks" where they differ.
    static func stockName(_ stocks: [Stock]) -> String? {
        Set(stocks.map(\.id)).count > 1 ? "Mixed stocks" : stocks.first?.displayName
    }

    /// The output a develop writes and through what: "JPEG · Display P3 · Portra 400".
    static func outputSummary(_ output: OutputSettings, stock: String?) -> String {
        ([output.format.title, output.space.title] + (stock.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// A folder as its parent and its own name, "Argent / Sample roll", the way the Develop page
    /// names a destination; the full path is the help tag.
    static func folder(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty || parent == "/" ? url.lastPathComponent : "\(parent) / \(url.lastPathComponent)"
    }

    /// "24 frames · Portra 400", or "3 of 24 frames" for part of the roll, and the Rated at and Lab
    /// balance where they are not the defaults, and how many of the frames have their own: what a
    /// develop of `frames` covers and through what, under the Develop page's heading and in the quick
    /// develop dialog. The stock and controls are those the frames develop through where they all share
    /// them, a frame's own included, as one frame does; the roll's where they differ.
    @MainActor static func summary(_ model: RollModel, frames: [Frame]) -> String {
        let count = frames.count, total = model.roll?.frames.count ?? 0
        var parts = [count < total ? "\(count) of \(Self.frames(total))" : Self.frames(count)]
        let stock = model.sharedStockIndex(of: frames), shared = Set(frames.map(model.controls(for:)))
        let controls = shared.count == 1 ? shared.first ?? model.controls : model.controls
        if let name = model.stockNames[safe: stock] { parts.append(name) }
        if controls.ratedAt != .boxSpeed, let box = model.films?.stocks[safe: stock]?.boxSpeed {
            parts.append("rated at \(controls.ratedAt.iso(boxSpeed: box))")
        }
        if controls.labBalance != .auto { parts.append("\(controls.labBalance.title.lowercased()) lab balance") }
        let own = frames.filter(model.hasFrameEdits).count
        if own > 0 { parts.append(own == 1 ? "1 frame with its own settings" : "\(own) frames with their own settings") }
        return parts.joined(separator: " · ")
    }

    /// The path with the home folder as ~.
    static func abbreviated(_ url: URL) -> String {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

extension RollModel {
    /// The Develop page's button's action now.
    var developPrimary: DevelopPrimary {
        DevelopPrimary.resolve(phase: developPhase, report: lastDevelop, count: framesToDevelop().count,
                               issuesDismissed: areIssuesDismissed)
    }

    /// The Develop page's status now, or `nil` with none to say.
    var developStatus: DevelopStatus? {
        DevelopStatus.resolve(phase: developPhase, report: lastDevelop, balancing: isDevelopBalancing,
                              issuesDismissed: areIssuesDismissed)
    }

    /// Whether the Develop page's button can act now: Develop and Develop Again need frames shown and a roll
    /// that is not opening or restoring its adjustments; Resume needs only the latter.
    var canPerformDevelopPrimary: Bool {
        switch developPrimary {
        case .develop, .developAgain: return canDevelop
        case .resume: return canStartDevelop && developDestination != nil
        case .stop, .reveal: return true
        }
    }

    /// The Develop page's button's action.
    func performDevelopPrimary() {
        switch developPrimary {
        case .develop, .developAgain:
            isIssueDetailsShown = false
            develop()
        case .stop: stopDevelop()
        case .resume(let report):
            isIssueDetailsShown = false
            develop(resuming: report)
        case .reveal: revealDeveloped()
        }
    }
}
