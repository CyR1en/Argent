import Foundation

/// A develop as it runs: frames finished, how many of them have a file and how many failed.
public struct DevelopProgress: Sendable, Equatable {
    public private(set) var processed = 0
    /// Frames with a file, written now or found already developed.
    public private(set) var developed = 0
    public private(set) var failed = 0
    public let total: Int

    public init(total: Int) {
        self.total = total
    }

    /// Counts one finished frame; a frame stopped before it began is not one.
    public mutating func record(_ outcome: RollDeveloper.Outcome) {
        guard outcome != .stopped, processed < total else { return }
        processed += 1
        if outcome.file != nil { developed += 1 }
        if case .failed = outcome { failed += 1 }
    }

    /// The Develop button's label: frames with a file, and the failed ones once there are any.
    public var label: String { Self.label(developed: developed, failed: failed, total: total) }

    /// The widest label the button takes at this point, so the count does not move it: the
    /// digits are monospaced, so the total stands in for every count.
    public var template: String { Self.label(developed: total, failed: failed > 0 ? total : 0, total: total) }

    /// How far through the roll the develop is, failed frames included.
    public var fraction: Double { total > 0 ? Double(processed) / Double(total) : 0 }

    private static func label(developed: Int, failed: Int, total: Int) -> String {
        let line = "\(developed) of \(total) developed"
        return failed > 0 ? "\(line), \(failed) failed" : line
    }
}

extension DevelopProgress {
    /// Where `report`'s develop ended.
    public init(_ report: DevelopReport) {
        total = report.total
        processed = report.processed
        developed = report.developed
        failed = report.failures.count
    }
}

/// What a develop of a roll came to, frame by frame.
public struct DevelopReport: Sendable, Equatable {
    /// A frame the develop could not write, and why.
    public struct Failure: Sendable, Equatable {
        public let frame: Frame
        /// The developer's reason without the frame's name in front.
        public let reason: String

        /// The raw's file name, as the Finder shows it.
        public var fileName: String { frame.url.lastPathComponent }
    }

    public let destination: URL
    /// The raws of the frames the develop was given, in roll order: what Resume goes on with.
    public let raws: [URL]
    public let total: Int
    /// Every file the roll has in `destination` from this develop, in roll order.
    public let files: [URL]
    /// Of `files`, those written by this develop rather than found from the same recipe.
    public let written: Int
    public let failures: [Failure]
    /// Frames not started before the develop was stopped.
    public let stopped: Int

    /// `outcomes` in the order of `frames`, one each, as `RollDeveloper.develop` returns them.
    public init(frames: [Frame], outcomes: [RollDeveloper.Outcome], destination: URL) {
        var files: [URL] = [], failures: [Failure] = []
        var written = 0, stopped = 0
        for (frame, outcome) in zip(frames, outcomes) {
            switch outcome {
            case .developed(let url):
                files.append(url)
                written += 1
            case .alreadyDeveloped(let url): files.append(url)
            case .failed(let reason): failures.append(Failure(frame: frame, reason: Self.reason(reason, of: frame)))
            case .stopped: stopped += 1
            }
        }
        self.destination = destination
        raws = frames.map(\.url)
        total = min(frames.count, outcomes.count)
        self.files = files
        self.written = written
        self.failures = failures
        self.stopped = stopped
    }

    /// Frames with a file.
    public var developed: Int { files.count }
    /// Frames found developed from the same recipe and settings, and so not written again.
    public var alreadyDeveloped: Int { files.count - written }
    /// Frames the develop finished, with a file or failed.
    public var processed: Int { total - stopped }
    public var wasStopped: Bool { stopped > 0 }
    /// Frames left for Develop to go on with: some failed, or the develop was stopped before them.
    public var isUnfinished: Bool { !failures.isEmpty || wasStopped }

    /// The one reason every failed frame shares, when more than one failed: the destination
    /// that could not be made or written, rather than anything about a frame.
    public var sharedReason: String? {
        guard failures.count > 1, let first = failures.first?.reason,
              failures.allSatisfy({ $0.reason == first }) else { return nil }
        return first
    }

    /// The frame's failure in this develop, if it failed.
    public func failure(for url: URL) -> Failure? { failures.first { $0.frame.url == url } }

    /// The counts, as the details say them: "34 of 36 developed (30 written, 4 from before),
    /// 1 failed, 1 not started".
    public var countsLine: String {
        var line = "\(developed) of \(total) developed"
        if developed > 0, alreadyDeveloped > 0 {
            line += written > 0 ? " (\(written) written, \(alreadyDeveloped) from before)" : " (all from before)"
        }
        if !failures.isEmpty { line += ", \(failures.count) failed" }
        if stopped > 0 { line += ", \(stopped) not started" }
        return line
    }

    /// The developer prefixes a frame's failure with its name; the details list the file beside it.
    static func reason(_ reason: String, of frame: Frame) -> String {
        let prefix = "\(frame.name): "
        return reason.hasPrefix(prefix) ? String(reason.dropFirst(prefix.count)) : reason
    }
}

/// The window's words for a roll's trouble: raws left out because their headers could not be
/// read, and frames the last develop could not write or did not reach before it was stopped.
public enum RollIssues {
    /// The bar's one line, or `nil` when there is nothing to say. Frames not started are counted
    /// as such, not as failed: the stopped develop says nothing about them, whatever an earlier
    /// one did.
    public static func line(unreadable: Int, report: DevelopReport?) -> String? {
        var parts: [String] = []
        if let report, !report.failures.isEmpty {
            let count = report.failures.count
            parts.append(count == 1 ? "1 frame not developed" : "\(count) frames not developed")
        }
        if let report, report.wasStopped {
            parts.append(report.stopped == 1 ? "1 frame not started" : "\(report.stopped) frames not started")
        }
        if unreadable > 0 {
            parts.append(unreadable == 1 ? "1 raw file could not be read" : "\(unreadable) raw files could not be read")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The line when a folder gives no roll, telling a folder with no ARW files from one whose
    /// ARW files all failed to read, and naming up to three of them.
    public static func noFramesLine(folderName: String, unreadable: [URL]) -> String {
        guard !unreadable.isEmpty else { return "No ARW files in \(folderName)" }
        let count = unreadable.count
        let head = count == 1 ? "The ARW file in \(folderName) could not be read"
            : "None of the \(count) ARW files in \(folderName) could be read"
        return "\(head): \(names(unreadable))"
    }

    /// Up to `limit` file names, and how many more.
    public static func names(_ urls: [URL], limit: Int = 3) -> String {
        let shown = urls.prefix(limit).map(\.lastPathComponent).joined(separator: ", ")
        return urls.count > limit ? "\(shown) and \(urls.count - limit) more" : shown
    }
}
