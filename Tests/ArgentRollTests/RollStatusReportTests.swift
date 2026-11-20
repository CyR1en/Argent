import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// The counts and words the window gives a develop and a roll's unreadable raws.
struct RollStatusReportTests {
    private let destination = URL(fileURLWithPath: "/tmp/out", isDirectory: true)

    private func frames(_ count: Int) -> [Frame] {
        (0..<count).map { Frame(id: $0, url: URL(fileURLWithPath: "/tmp/roll/DSC0060\($0).ARW"), info: ARWFrameInfo()) }
    }

    private func file(_ index: Int) -> URL { destination.appendingPathComponent("DSC0060\(index).jpg") }

    @Test func oneFailureAmongDevelopedFrames() {
        let roll = frames(4)
        let report = DevelopReport(frames: roll, outcomes: [
            .developed(file(0)), .alreadyDeveloped(file(1)), .failed("DSC00602: the raw data is truncated"), .developed(file(3)),
        ], destination: destination)
        #expect(report.total == 4)
        #expect(report.files == [file(0), file(1), file(3)])
        #expect(report.developed == 3 && report.written == 2 && report.alreadyDeveloped == 1)
        #expect(report.processed == 4 && !report.wasStopped)
        #expect(report.failures.map(\.fileName) == ["DSC00602.ARW"])
        // The name the developer puts in front goes; the list shows the file beside the reason.
        #expect(report.failures.first?.reason == "the raw data is truncated")
        #expect(report.failure(for: roll[2].url) != nil && report.failure(for: roll[0].url) == nil)
        #expect(report.sharedReason == nil)
        #expect(report.countsLine == "3 of 4 developed (2 written, 1 from before), 1 failed")
        #expect(RollIssues.line(unreadable: 0, report: report) == "1 frame not developed")
    }

    @Test func everyFrameFailingAtTheDestinationIsSaidOnce() {
        let reason = "Cannot write to /Volumes/Locked/out"
        let report = DevelopReport(frames: frames(3), outcomes: Array(repeating: .failed(reason), count: 3), destination: destination)
        #expect(report.files.isEmpty)
        #expect(report.sharedReason == reason)
        #expect(report.countsLine == "0 of 3 developed, 3 failed")
        #expect(RollIssues.line(unreadable: 0, report: report) == "3 frames not developed")
    }

    @Test func aStoppedDevelopCountsWhatItFinished() {
        let report = DevelopReport(frames: frames(5), outcomes: [
            .developed(file(0)), .failed("DSC00601: decode failed"), .stopped, .stopped, .stopped,
        ], destination: destination)
        #expect(report.wasStopped && report.stopped == 3 && report.processed == 2)
        #expect(report.countsLine == "1 of 5 developed, 1 failed, 3 not started")
        // Resuming finds the developed frame and tries the failed one again; one still fails.
        let resumed = DevelopReport(frames: frames(5), outcomes: [
            .alreadyDeveloped(file(0)), .failed("DSC00601: decode failed"), .developed(file(2)), .developed(file(3)), .developed(file(4)),
        ], destination: destination)
        #expect(!resumed.wasStopped && resumed.written == 3 && resumed.alreadyDeveloped == 1)
        #expect(resumed.countsLine == "4 of 5 developed (3 written, 1 from before), 1 failed")
        #expect(resumed.failures.map(\.frame.id) == [1])
    }

    /// A develop failed one frame; Develop Again was stopped before reaching it. The new report
    /// has no failure, but the frames it never reached stay on the bar as not started, not as
    /// failed, and the details and Resume stay offered.
    @Test func aRetryStoppedBeforeTheFailedFrameStillSaysWhatIsLeft() {
        let roll = frames(6)
        let first = DevelopReport(frames: roll, outcomes: [
            .developed(file(0)), .developed(file(1)), .developed(file(2)), .developed(file(3)),
            .failed("DSC00604: decode failed"), .developed(file(5)),
        ], destination: destination)
        #expect(RollIssues.line(unreadable: 0, report: first) == "1 frame not developed")

        let retry = DevelopReport(frames: roll, outcomes: [
            .alreadyDeveloped(file(0)), .alreadyDeveloped(file(1)), .stopped, .stopped, .stopped, .stopped,
        ], destination: destination)
        #expect(retry.failures.isEmpty && retry.wasStopped && retry.stopped == 4)
        #expect(retry.isUnfinished)
        #expect(RollIssues.line(unreadable: 0, report: retry) == "4 frames not started")
        #expect(retry.countsLine == "2 of 6 developed (all from before), 4 not started")
        // The earlier failure is not carried over as this develop's: frame 4 is only not started.
        #expect(retry.failure(for: roll[4].url) == nil)
        #expect(RollIssues.line(unreadable: 2, report: retry) == "4 frames not started, 2 raw files could not be read")
    }

    /// Stopped while the frames were still being analysed: nothing started, all of it left.
    @Test func aDevelopStoppedDuringAnalysisLeavesEveryFrame() {
        let report = DevelopReport(frames: frames(3), outcomes: Array(repeating: .stopped, count: 3), destination: destination)
        #expect(report.processed == 0 && report.files.isEmpty)
        #expect(report.isUnfinished)
        #expect(RollIssues.line(unreadable: 0, report: report) == "3 frames not started")
        #expect(report.countsLine == "0 of 3 developed, 3 not started")
        let one = DevelopReport(frames: frames(1), outcomes: [.stopped], destination: destination)
        #expect(RollIssues.line(unreadable: 0, report: one) == "1 frame not started")
    }

    @Test func failedAndNotStartedAreBothSaid() {
        let report = DevelopReport(frames: frames(5), outcomes: [
            .developed(file(0)), .failed("DSC00601: decode failed"), .stopped, .stopped, .stopped,
        ], destination: destination)
        #expect(report.isUnfinished)
        #expect(RollIssues.line(unreadable: 0, report: report) == "1 frame not developed, 3 frames not started")
        #expect(RollIssues.line(unreadable: 1, report: report)
                == "1 frame not developed, 3 frames not started, 1 raw file could not be read")
    }

    @Test func aRetryThatFindsEverythingDevelopedHasNothingToSay() {
        let report = DevelopReport(frames: frames(2), outcomes: [.alreadyDeveloped(file(0)), .alreadyDeveloped(file(1))],
                                   destination: destination)
        #expect(report.failures.isEmpty && report.written == 0)
        #expect(report.countsLine == "2 of 2 developed (all from before)")
        #expect(RollIssues.line(unreadable: 0, report: report) == nil)
        #expect(!report.isUnfinished)
        #expect(RollIssues.line(unreadable: 0, report: nil) == nil)
    }

    /// The button counts frames with a file, not every frame finished, and grows once, at the first failure.
    @Test func progressCountsFilesAndFailuresApart() {
        var progress = DevelopProgress(total: 12)
        #expect(progress.label == "0 of 12 developed" && progress.template == "12 of 12 developed")
        progress.record(.developed(file(0)))
        progress.record(.alreadyDeveloped(file(1)))
        progress.record(.stopped)
        #expect(progress.label == "2 of 12 developed" && progress.processed == 2)
        progress.record(.failed("DSC00602: decode failed"))
        #expect(progress.label == "2 of 12 developed, 1 failed")
        #expect(progress.template == "12 of 12 developed, 12 failed")
        #expect(progress.fraction == 3.0 / 12.0)
        // Never past the total, whatever arrives.
        for _ in 0..<20 { progress.record(.developed(file(3))) }
        #expect(progress.processed == 12 && progress.fraction == 1)
        #expect(DevelopProgress(total: 0).fraction == 0)
    }

    @Test func progressAtTheEndOfAReportMatchesIt() {
        let report = DevelopReport(frames: frames(3), outcomes: [.developed(file(0)), .failed("x"), .alreadyDeveloped(file(2))],
                                   destination: destination)
        #expect(DevelopProgress(report).label == "2 of 3 developed, 1 failed")
    }

    @Test func unreadableRawsAreCountedBesideFailures() {
        let report = DevelopReport(frames: frames(2), outcomes: [.failed("a"), .failed("b")], destination: destination)
        #expect(RollIssues.line(unreadable: 1, report: nil) == "1 raw file could not be read")
        #expect(RollIssues.line(unreadable: 3, report: report) == "2 frames not developed, 3 raw files could not be read")
    }

    @Test func aFolderWithNoFramesSaysWhy() {
        #expect(RollIssues.noFramesLine(folderName: "Empty", unreadable: []) == "No ARW files in Empty")
        let one = [URL(fileURLWithPath: "/tmp/Bad/DSC00001.ARW")]
        #expect(RollIssues.noFramesLine(folderName: "Bad", unreadable: one) == "The ARW file in Bad could not be read: DSC00001.ARW")
        let five = (1...5).map { URL(fileURLWithPath: "/tmp/Bad/DSC0000\($0).ARW") }
        #expect(RollIssues.noFramesLine(folderName: "Bad", unreadable: five)
                == "None of the 5 ARW files in Bad could be read: DSC00001.ARW, DSC00002.ARW, DSC00003.ARW and 2 more")
    }

    /// What the app is given for a folder of corrupt raws only, and for an empty one.
    @Test func corruptOnlyAndEmptyFoldersScanApart() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("argent-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let corrupt = base.appendingPathComponent("Corrupt"), empty = base.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4096).write(to: corrupt.appendingPathComponent("DSC00002.ARW"))
        try Data().write(to: corrupt.appendingPathComponent("DSC00001.arw"))

        let bad = await RollScanner.scan(corrupt)
        #expect(bad.frames.isEmpty)
        #expect(bad.unreadable.map(\.lastPathComponent) == ["DSC00001.arw", "DSC00002.ARW"])
        #expect(RollIssues.noFramesLine(folderName: "Corrupt", unreadable: bad.unreadable)
                == "None of the 2 ARW files in Corrupt could be read: DSC00001.arw, DSC00002.ARW")

        let none = await RollScanner.scan(empty)
        #expect(none.frames.isEmpty && none.unreadable.isEmpty)
        #expect(RollIssues.noFramesLine(folderName: "Empty", unreadable: none.unreadable) == "No ARW files in Empty")
    }
}
