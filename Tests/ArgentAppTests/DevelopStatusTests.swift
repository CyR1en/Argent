import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The develop's one primary action, its dock's state and the dock's words, from the develop's
/// phase and its report, as `DevelopStateTests` builds them.
@MainActor @Suite struct DevelopStatusTests {
    private static let destination = URL(fileURLWithPath: "/tmp/develop-status/Roll/Developed")

    private static func frames(_ count: Int) -> [Frame] {
        (0..<count).map { Frame(id: $0, url: URL(fileURLWithPath: "/tmp/develop-status/DSC\($0).ARW"), info: ARWFrameInfo()) }
    }

    /// A report of `saved` frames with a file (`reused` of them found from before), `failed` that
    /// failed for `reason`, and `stopped` not started, in that order.
    private static func report(saved: Int, reused: Int = 0, failed: Int = 0, stopped: Int = 0,
                               reason: (Int) -> String = { _ in "Could not write" }) -> DevelopReport {
        let all = frames(saved + failed + stopped)
        var outcomes: [RollDeveloper.Outcome] = []
        for index in 0..<saved {
            let file = destination.appendingPathComponent("DSC\(index).jpg")
            outcomes.append(index < reused ? .alreadyDeveloped(file) : .developed(file))
        }
        outcomes += (0..<failed).map { .failed(reason($0)) }
        outcomes += Array(repeating: .stopped, count: stopped)
        return DevelopReport(frames: all, outcomes: outcomes, destination: destination)
    }

    private static func progress(total: Int, finished: Int, failed: Int = 0) -> DevelopProgress {
        var progress = DevelopProgress(total: total)
        for index in 0..<finished {
            progress.record(index < failed ? .failed("x") : .developed(destination.appendingPathComponent("\(index).jpg")))
        }
        return progress
    }

    // MARK: The primary action

    @Test func idleDevelopsTheFramesADevelopNowCovers() {
        let primary = DevelopPrimary.resolve(phase: .idle, report: nil, count: 3)
        #expect(primary == .develop(count: 3))
        #expect(primary.title == "Develop 3")
        #expect(primary.accessibilityLabel == "Develop 3 frames")
        #expect(primary.help(filtered: true) == "Develop the 3 frames shown. Command-D.")
        #expect(primary.help(filtered: false) == "Develop the roll. Command-D.")
        #expect(DevelopPrimary.develop(count: 1).accessibilityLabel == "Develop 1 frame")
    }

    @Test func noFramesShownReadsDevelopAlone() {
        let primary = DevelopPrimary.resolve(phase: .idle, report: nil, count: 0)
        #expect(primary.title == "Develop")
        #expect(primary.accessibilityLabel == "Develop")
    }

    @Test func developingIsTheProgressThatStops() {
        let running = Self.progress(total: 84, finished: 32)
        let primary = DevelopPrimary.resolve(phase: .developing(running), report: Self.report(saved: 2), count: 84)
        #expect(primary == .stop(running))
        #expect(primary.title == "32 of 84")
        // The total stands in for every count, so the label keeps its width as the count runs up.
        #expect(primary.template == "84 of 84")
        #expect(primary.accessibilityLabel == "Stop Developing")
        #expect(primary.accessibilityValue == running.label)
        #expect(primary.help(filtered: false).hasSuffix("Command-Period."))
    }

    @Test func aStoppedDevelopResumesUntilItsDockIsClosed() {
        let stopped = Self.report(saved: 32, stopped: 52)
        for phase in [DevelopPhase.idle, .done] {
            let primary = DevelopPrimary.resolve(phase: phase, report: stopped, count: 3)
            #expect(primary == .resume(stopped))
            #expect(primary.title == "Resume")
        }
        // Closed, the button develops the frames shown again, with their count.
        #expect(DevelopPrimary.resolve(phase: .idle, report: stopped, count: 3, issuesDismissed: true) == .develop(count: 3))
        #expect(DevelopPrimary.resume(stopped).accessibilityHint == "Develops the 52 frames the stopped develop did not finish.")
    }

    @Test func failuresWithoutAStopDevelopAgain() {
        // All failed (nothing written: the phase is idle) or some (files written: the phase is done).
        for (phase, report) in [(DevelopPhase.idle, Self.report(saved: 0, failed: 24)), (.done, Self.report(saved: 21, failed: 3))] {
            let primary = DevelopPrimary.resolve(phase: phase, report: report, count: 24)
            #expect(primary == .developAgain(failed: report.failures.count))
            #expect(primary.title == "Develop again")
        }
        // Closed: Develop with the count shown, or Reveal for the files a part failure wrote.
        #expect(DevelopPrimary.resolve(phase: .idle, report: Self.report(saved: 0, failed: 24), count: 5, issuesDismissed: true)
                == .develop(count: 5))
        #expect(DevelopPrimary.resolve(phase: .done, report: Self.report(saved: 21, failed: 3), count: 24, issuesDismissed: true)
                == .reveal)
        #expect(DevelopPrimary.developAgain(failed: 1).help(filtered: false).contains("the frame that failed"))
    }

    @Test func aCleanDevelopRevealsUntilASettingTurnsItBackIntoDevelop() {
        let clean = Self.report(saved: 24)
        #expect(DevelopPrimary.resolve(phase: .done, report: clean, count: 24) == .reveal)
        #expect(DevelopPrimary.reveal.title == "Reveal in Finder")
        #expect(DevelopPrimary.resolve(phase: .idle, report: clean, count: 24) == .develop(count: 24))
    }

    // MARK: The status

    @Test func theStatusFollowsThePhaseTheReportAndWhatWasClosed() {
        func dock(_ phase: DevelopPhase, _ report: DevelopReport?, balancing: Bool = false, issues: Bool = false) -> DevelopStatus? {
            DevelopStatus.resolve(phase: phase, report: report, balancing: balancing, issuesDismissed: issues)
        }
        let running = Self.progress(total: 24, finished: 0)
        let clean = Self.report(saved: 24), stopped = Self.report(saved: 8, stopped: 16)
        let failed = Self.report(saved: 0, failed: 24), partial = Self.report(saved: 21, failed: 3)

        #expect(dock(.idle, nil) == nil)
        // A develop under way shows whatever was closed before it.
        #expect(dock(.developing(running), stopped, balancing: true, issues: true) == .developing(running, balancing: true))
        #expect(dock(.done, clean) == .complete(clean))
        // A setting changed since: nothing to say, and the button is Develop again.
        #expect(dock(.idle, clean) == nil)
        #expect(dock(.idle, stopped) == .stopped(stopped))
        #expect(dock(.idle, stopped, issues: true) == nil)
        #expect(dock(.idle, failed) == .failed(failed))
        // Some files and some failures finish done, and the failures still show.
        #expect(dock(.done, partial) == .failed(partial))
        #expect(dock(.done, partial, issues: true) == nil)
    }

    @Test func theModelsStatusAndTheRailFollowADevelop() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-develop-status-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let savedOutput = UserDefaults.standard.data(forKey: "outputSettings")
        defer {
            UserDefaults.standard.set(savedOutput, forKey: "outputSettings")
            try? FileManager.default.removeItem(at: folder)
        }
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        #expect(model.developStatus == nil && model.developFraction == nil && !model.developWantsAttention)
        #expect(model.developPrimary == .develop(count: 0))
        #expect(!model.canPerformDevelopPrimary)

        // The rail's ring fills as the develop goes.
        let inputs = DevelopInputs(model)
        var progress = DevelopProgress(total: 4)
        model.developPhase = .developing(progress)
        #expect(model.developStatus == .developing(progress, balancing: false) && model.developFraction == 0)
        #expect(model.canPerformDevelopPrimary && !model.developWantsAttention)
        progress.record(.developed(URL(fileURLWithPath: "/tmp/one.jpg")))
        model.developPhase = .developing(progress)
        #expect(model.developFraction == 0.25)

        // Stopped: the rail's dot, until the status is closed on the page.
        let stopped = Self.report(saved: 0, stopped: 1)
        model.recordDevelop(stopped, inputs: inputs)
        #expect(model.developStatus == .stopped(stopped) && model.developFraction == nil && model.developWantsAttention)
        #expect(model.developPrimary == .resume(stopped))
        model.areIssuesDismissed = true
        #expect(model.developStatus == nil && !model.developWantsAttention)
        #expect(model.developPrimary == .develop(count: 0))

        // The next develop's report shows again, whatever was closed; a clean one asks for nothing.
        model.developPhase = .developing(DevelopProgress(total: 1))
        let clean = Self.report(saved: 1)
        model.recordDevelop(clean, inputs: inputs)
        #expect(model.developStatus == .complete(clean) && !model.developWantsAttention)
        #expect(model.developPrimary == .reveal)
    }

    // MARK: The words

    @Test func runningDevelopSummaryUsesCapturedStocks() async throws {
        try await FlagStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("other", in: fixture.stocks)
            let model = FlagStateTests.model(fixture), gate = MeasurementGate()
            let frames = try await FlagStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            model.developFolder.usesSubfolder = false
            model.chooseDestination(fixture.folder.appendingPathComponent("Export"))
            let rollStock = try #require(model.films?.stocks.firstIndex { $0.id == "toy" })
            let ownStock = try #require(model.films?.stocks.firstIndex { $0.id == "other" })
            model.stockIndex = rollStock
            model.setStock(ownStock, for: frames[0])

            var summaries: [String] = []
            model.observeDevelopJobs = { jobs in
                let names = Set(jobs.map(\.recipe.stock.displayName))
                let expected = names.count == 1 ? names.first : "Mixed stocks"
                #expect(model.runningDevelopSummary == DevelopStatusText.outputSummary(model.output, stock: expected))
                let captured = model.runningDevelopSummary
                model.stockIndex = ownStock
                model.setStock(nil, for: frames[0])
                #expect(model.runningDevelopSummary == captured)
                summaries.append(captured)
                model.stopDevelop()
            }
            await FlagStateTests.develop(model) { model.developFrame(frames[0]) }
            model.stockIndex = rollStock
            await FlagStateTests.develop(model) { model.develop() }
            model.stockIndex = rollStock
            model.setStock(ownStock, for: frames[0])
            await FlagStateTests.develop(model) { model.develop() }
            #expect(summaries.count == 3)
        }
    }

    @Test func countsAreTheReportsOwn() {
        #expect(DevelopStatusText.counts(.stopped(Self.report(saved: 32, stopped: 52))) == "32 frames saved · 52 remaining")
        #expect(DevelopStatusText.counts(.stopped(Self.report(saved: 1, stopped: 1))) == "1 frame saved · 1 remaining")
        // Frames found from before have a file too: they count as saved.
        #expect(DevelopStatusText.counts(.stopped(Self.report(saved: 10, reused: 4, failed: 2, stopped: 12)))
                == "10 frames saved · 2 failed · 12 remaining")
        #expect(DevelopStatusText.counts(.complete(Self.report(saved: 84, reused: 30))) == "84 of 84 frames saved")
        #expect(DevelopStatusText.counts(.failed(Self.report(saved: 21, failed: 3))) == "21 of 24 frames saved · 3 failed")
        #expect(DevelopStatusText.counts(.developing(Self.progress(total: 84, finished: 32), balancing: false)) == "32 of 84 frames")
        #expect(DevelopStatusText.counts(.developing(Self.progress(total: 84, finished: 32, failed: 2), balancing: false))
                == "32 of 84 frames · 2 failed")
    }

    @Test func titlesSayWhereTheDevelopStands() {
        let running = Self.progress(total: 4, finished: 0)
        #expect(DevelopStatusText.title(.developing(running, balancing: false)) == "Developing roll")
        #expect(DevelopStatusText.title(.developing(running, balancing: true)) == "Balancing roll…")
        #expect(DevelopStatusText.title(.complete(Self.report(saved: 4))) == "Roll developed")
        #expect(DevelopStatusText.title(.stopped(Self.report(saved: 1, stopped: 3))) == "Develop stopped")
        #expect(DevelopStatusText.title(.failed(Self.report(saved: 0, failed: 4))) == "Develop failed")
        #expect(DevelopStatusText.title(.failed(Self.report(saved: 3, failed: 1))) == "1 frame not developed")
        #expect(DevelopStatusText.title(.failed(Self.report(saved: 1, failed: 3))) == "3 frames not developed")
    }

    @Test func aFailuresDetailIsItsReason() {
        #expect(DevelopStatusText.detail(.stopped(Self.report(saved: 1, stopped: 1))) == "Resume continues with the remaining frames")
        // One reason for every frame: the destination, said once.
        #expect(DevelopStatusText.detail(.failed(Self.report(saved: 0, failed: 3))) == "Could not write")
        #expect(DevelopStatusText.detail(.failed(Self.report(saved: 2, failed: 1, reason: { _ in "The raw changed" }))) == "The raw changed")
        #expect(DevelopStatusText.detail(.failed(Self.report(saved: 0, failed: 2, reason: { "Reason \($0)" }))) == "Each frame's reason is in Details")
        #expect(DevelopStatusText.detail(.complete(Self.report(saved: 1))) == nil)
    }

    @Test func destinationAndSummary() {
        #expect(DevelopStatusText.folder(Self.destination) == "Roll / Developed")
        #expect(DevelopStatusText.folder(URL(fileURLWithPath: "/Developed")) == "Developed")
        var output = OutputSettings()
        output.format = .jpeg
        output.space = .displayP3
        #expect(DevelopStatusText.outputSummary(output, stock: "Portra 400") == "JPEG · Display P3 · Portra 400")
        output.format = .tiff16
        output.space = .sRGB
        #expect(DevelopStatusText.outputSummary(output, stock: nil) == "TIFF, 16-bit · sRGB")
    }
}
