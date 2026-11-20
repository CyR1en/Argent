import AppKit
import ArgentCore
@testable import ArgentRoll
import Foundation
import Observation
import Testing
@testable import ArgentApp

/// Flags and the filter in the app: F flags the selected or open frame and the roll keeps it in its
/// library; the sheet shows all, the flagged or the unflagged frames, the arrows skip the rest and a
/// selection left out moves on while an open frame stays; a roll opens on every frame with its flags
/// back; Develop develops the frames shown, each printed as a develop of the whole roll prints it,
/// after the whole roll's settled decision, and Resume goes on with the frames it had.
@MainActor @Suite(.serialized) struct FlagStateTests {
    typealias Fixture = AutoDecisionStateTests.Fixture

    /// Each develop's jobs, as it made them; the develop is stopped there, before any frame.
    @MainActor final class Jobs {
        var runs: [[RollDeveloper.Job]] = []
        var totals: [Int] = []
        var last: [URL] { runs.last?.map(\.frame.url) ?? [] }
    }

    /// The Auto suite's roll of eight frames, its models' flag writes done before it goes.
    static func withRoll(_ body: (Fixture) async throws -> Void) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            var failure: (any Error)?
            do { try await body(fixture) } catch { failure = error }
            for model in fixture.made.models { await model.flagSave?.value }
            if let failure { throw failure }
        }
    }

    /// A model keeping its decisions, recipes and flags in the fixture's library, or its flags in `flags`.
    static func model(_ fixture: Fixture, flags: URL? = nil) -> RollModel {
        let model = RollModel(bookmarks: BookmarkStore(file: fixture.folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: fixture.stocks, decisions: AutoDecisionStore(library: fixture.library),
                              flagStore: FlagStore(library: flags ?? fixture.library), recipeLibrary: fixture.library,
                              previewCache: fixture.folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        fixture.made.models.append(model)
        return model
    }

    /// Opens the fixture's roll in `model`, each frame measured as soon as it is asked for.
    static func open(_ fixture: Fixture, in model: RollModel, through gate: MeasurementGate) async throws -> [Frame] {
        try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
        let frames = try #require(model.roll?.frames)
        gate.openAll(frames)
        return frames
    }

    static func flag(_ model: RollModel, _ indices: [Int]) {
        for index in indices { model.setFlag(true, for: model.roll!.frames[index]) }
    }

    static func ids(_ frames: [Frame]) -> [Int] { frames.map(\.id) }

    /// Records each develop's jobs and stops it as they are made: a develop run to its end needs the
    /// app's bundle.
    static func capture(_ model: RollModel) -> Jobs {
        let jobs = Jobs()
        model.observeDevelopJobs = { [weak model] made in
            jobs.runs.append(made)
            if case .developing(let progress) = model?.developPhase { jobs.totals.append(progress.total) }
            model?.stopDevelop()
        }
        return jobs
    }

    /// Waits for the develop `start` began, if it began one.
    static func develop(_ model: RollModel, _ start: () -> Void) async {
        start()
        await model.developTask?.value
    }

    @Test func fFlagsTheSelectedFrameAndTheRollKeepsItWithoutChangingAPrint() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let decision = try #require(await model.settledDecision())
            let stock = model.stockIndex
            let before = frames.map { model.settings(for: $0, stock: stock) }
            #expect(model.flaggedCount == 0 && model.menuState.canFlag && !model.menuState.isFlagged)
            #expect(model.flagStore.stored(for: fixture.roll) == FlagStore.Stored.none)

            // Frame > Flag acts on the selected frame, and its title follows it.
            model.flagSelection(nil)
            #expect(model.isFlagged(frames[0]) && model.menuState.isFlagged && model.flaggedCount == 1)
            model.selection = 3
            #expect(!model.menuState.isFlagged && model.menuState.canFlag)
            model.flagSelection(nil)
            model.toggleFlag(frames[0])
            #expect(!model.isFlagged(frames[0]) && model.isFlagged(frames[3]) && model.menuState.isFlagged)
            await model.flagSave?.value
            let kept = try #require(model.flagStore.record(for: fixture.roll))
            #expect(kept.frames == [FlagRecord.Entry(frames[3], byteCount: RecipeStore.byteCount(of: frames[3].url))])

            // A flag changes no print, no settled decision and writes no recipe.
            #expect(frames.map { model.settings(for: $0, stock: stock) } == before)
            #expect(model.isBalanced && model.autoDecision?.revision == decision.revision)
            #expect(frames.allSatisfy { !FileManager.default.fileExists(atPath: RecipeStore.besideRaw($0.url).path) })
        }
    }

    @Test func eachFilterShowsItsFramesAndTheHeadingSaysHowMany() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            Self.flag(model, [1, 3, 6])
            #expect(Self.ids(model.shownFrames) == Array(0..<8) && !RollHeading.subtitle(model).contains(" of "))
            #expect(RollHeading.subtitle(model).contains("8 frames"))

            model.flagFilter = .flagged
            #expect(Self.ids(model.shownFrames) == [1, 3, 6] && model.menuState.flagFilter == .flagged)
            #expect(RollHeading.subtitle(model).contains("Flagged · 3 of 8 frames"), "\(RollHeading.subtitle(model))")
            model.flagFilter = .unflagged
            #expect(Self.ids(model.shownFrames) == [0, 2, 4, 5, 7])
            #expect(RollHeading.subtitle(model).contains("Unflagged · 5 of 8 frames"), "\(RollHeading.subtitle(model))")
            model.flagFilter = .all
            #expect(model.shownFrames == frames && RollHeading.subtitle(model).contains("8 frames"))

            // The frame view counts the frames shown, and the roll with All Frames.
            model.selection = 3
            model.openFrame()
            #expect(RollHeading.subtitle(model).hasPrefix("4 of 8"))
            model.flagFilter = .flagged
            #expect(RollHeading.subtitle(model).hasPrefix("2 of 3"), "\(RollHeading.subtitle(model))")
        }
    }

    @Test func theArrowsHomeAndEndSkipFramesNotShown() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            _ = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            Self.flag(model, [1, 3, 6])
            model.flagFilter = .flagged
            // The selection left out moved to the next frame shown.
            #expect(model.selection == 1)
            var visited: [Int?] = []
            for offset in [1, 1, 1, -1, -5] {
                model.moveSelection(by: offset)
                visited.append(model.selection)
            }
            #expect(visited == [3, 6, 6, 3, 1])
            model.moveSelection(toLast: true)
            #expect(model.selection == 6)
            model.moveSelection(toLast: false)
            #expect(model.selection == 1 && !model.canStep(by: -1) && model.canStep(by: 1))

            // So in the frame view.
            model.openFrame()
            model.moveSelection(by: 1)
            #expect(model.shownFrame?.id == 3)
            model.moveSelection(toLast: true)
            #expect(model.shownFrame?.id == 6 && !model.canStep(by: 1))
        }
    }

    @Test func aSelectionTheFilterLeavesOutMovesToTheNextFrameShownElseTheOneBefore() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            Self.flag(model, [2, 5])
            model.selection = 0
            model.flagFilter = .flagged
            #expect(model.selection == 2)
            model.selection = 5
            model.flagFilter = .unflagged
            #expect(model.selection == 6)

            model.flagFilter = .flagged
            Self.flag(model, [1])
            #expect(Self.ids(model.shownFrames) == [1, 2, 5])
            model.selection = 2
            // Unflagged from the sheet, it leaves: the next shown after it, else the one before, else none.
            model.toggleFlag(frames[2])
            #expect(model.selection == 5)
            model.toggleFlag(frames[5])
            #expect(model.selection == 1)
            model.toggleFlag(frames[1])
            #expect(model.selection == nil && model.shownFrames.isEmpty)
            #expect(!model.menuState.canFlag && !model.menuState.canOpenFrame)
            // Shown again, it comes back near where it was: the next shown after it.
            Self.flag(model, [4, 0])
            #expect(model.selection == 4)
        }
    }

    @Test func theFrameViewKeepsItsFrameAndEscapeGoesToTheNearestShown() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            Self.flag(model, [1, 3, 6])
            model.flagFilter = .flagged
            model.selection = 3
            model.openFrame()
            model.toggleFlag(frames[3])
            #expect(model.isFrameOpen && model.shownFrame?.id == 3 && !model.isShown(frames[3]))
            // Why it is left out: not flagged, under Flagged; and flagged, under Unflagged.
            #expect(RollHeading.subtitle(model).hasPrefix("Not flagged ·"), "\(RollHeading.subtitle(model))")
            model.flagFilter = .unflagged
            model.selection = 1
            #expect(RollHeading.subtitle(model).hasPrefix("Flagged ·"), "\(RollHeading.subtitle(model))")
            model.flagFilter = .flagged
            // The arrows go on from its place in the roll.
            model.moveSelection(by: 1)
            #expect(model.shownFrame?.id == 6 && RollHeading.subtitle(model).hasPrefix("2 of 2"))
            model.selection = 3
            model.moveSelection(by: -1)
            #expect(model.shownFrame?.id == 1)

            // Escape: the open frame when shown, else the nearest shown, the later of two as near.
            model.selection = 3
            model.closeFrame()
            #expect(!model.isFrameOpen && model.selection == 1)
            Self.flag(model, [5])
            model.selection = 3
            model.openFrame()
            model.closeFrame()
            #expect(model.selection == 5)
            model.openFrame()
            model.closeFrame()
            #expect(model.selection == 5)
        }
    }

    @Test func aRollOpensOnEveryFrameWithItsFlagsBack() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            Self.flag(model, [2, 4])
            model.flagFilter = .flagged
            await model.flagSave?.value
            // Opened again in the same window, it shows every frame, its flags back from the library.
            _ = try await Self.open(fixture, in: model, through: gate)
            #expect(model.flagFilter == .all && model.shownFrames.count == frames.count && model.selection == 0)
            #expect(Self.ids(frames.filter(model.isFlagged)) == [2, 4])
            AutoDecisionStateTests.close(model, gate)

            let again = Self.model(fixture), waiting = MeasurementGate()
            _ = try await Self.open(fixture, in: again, through: waiting)
            #expect(Self.ids(frames.filter(again.isFlagged)) == [2, 4] && again.flagFilter == .all)
            AutoDecisionStateTests.close(again, waiting)

            // Another library keeps another roll's flags.
            let elsewhere = Self.model(fixture, flags: fixture.folder.appendingPathComponent("Other library"))
            let other = MeasurementGate()
            _ = try await Self.open(fixture, in: elsewhere, through: other)
            defer { AutoDecisionStateTests.close(elsewhere, other) }
            #expect(elsewhere.flaggedCount == 0)
        }
    }

    /// A raw replaced while the roll is open is another raw: it loses the flag, which is kept for the
    /// raw it was given to and comes back with it.
    @Test func aRawReplacedWhileOpenLosesItsFlagUntilItComesBack() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            Self.flag(model, [2])
            await model.flagSave?.value
            let original = try Data(contentsOf: frames[2].url)
            try writeSequenceHeader(frames[2].url, captured: AutoDecisionStateTests.captured(2), tail: Data(repeating: 7, count: 99))
            #expect(model.forgetChangedSources())
            #expect(!model.isFlagged(frames[2]) && model.otherFlags.count == 1)

            try original.write(to: frames[2].url)
            #expect(model.forgetChangedSources())
            #expect(model.isFlagged(frames[2]) && model.otherFlags.isEmpty)
        }
    }

    /// A develop with a filter on develops the frames shown, each with the job a develop of the whole
    /// roll gives it, after the whole roll's settled decision.
    @Test func aFilteredDevelopsJobsAreTheShownFramesAsTheWholeRollPrintsThem() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let jobs = Self.capture(model), destination = fixture.folder.appendingPathComponent("Export")
            Self.flag(model, [1, 3, 6])
            await Self.develop(model) { model.startDevelop(to: destination) }
            let whole = try #require(jobs.runs.last)
            #expect(whole.map(\.frame.url) == frames.map(\.url) && jobs.totals.last == frames.count)

            model.flagFilter = .flagged
            await Self.develop(model) { model.startDevelop(to: destination) }
            let filtered = try #require(jobs.runs.last)
            #expect(jobs.runs.count == 2 && filtered.map(\.frame.url) == model.shownFrames.map(\.url))
            #expect(Self.ids(filtered.map(\.frame)) == [1, 3, 6] && jobs.totals.last == 3)
            let byFrame = Dictionary(uniqueKeysWithValues: whole.map { ($0.frame.url, $0) })
            for job in filtered {
                let same = try #require(byFrame[job.frame.url])
                #expect(job.recipe == same.recipe, "\(job.frame.name)")
                #expect(job.autoRevision == same.autoRevision && job.measuredFrom == same.measuredFrom && job.frameSource == same.frameSource)
            }
            // The decision it printed is the whole roll's.
            let decision = try #require(model.autoDecision)
            #expect(model.isBalanced && decision.aims.count == frames.count && decision.record.frames.count == frames.count)
            #expect(filtered.allSatisfy { $0.autoRevision == decision.revision })
            let report = try #require(model.lastDevelop)
            #expect(report.raws == filtered.map(\.frame.url) && report.total == 3)
        }
    }

    @Test func developIsDisabledWhileTheFilterShowsNoFrame() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            _ = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let jobs = Self.capture(model)
            #expect(model.canDevelop && model.menuState.canDevelop)
            model.flagFilter = .flagged
            #expect(model.shownFrames.isEmpty && !model.canDevelop && !model.menuState.canDevelop)
            model.develop()
            #expect(model.developTask == nil)
            model.startDevelop(to: fixture.folder.appendingPathComponent("Export"))
            #expect(model.developTask == nil && model.developPhase == .idle && jobs.runs.isEmpty)
        }
    }

    /// Resume goes on with the stopped develop's frames whatever the sheet shows now; Develop, and
    /// Develop Again, the frames shown then.
    @Test func resumeKeepsTheStoppedDevelopsFrames() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            _ = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let jobs = Self.capture(model)
            Self.flag(model, [1, 3, 6])
            model.flagFilter = .flagged
            await Self.develop(model) { model.startDevelop(to: fixture.folder.appendingPathComponent("Export")) }
            let stopped = try #require(model.lastDevelop)
            #expect(stopped.wasStopped && Self.ids(jobs.runs.last?.map(\.frame) ?? []) == [1, 3, 6])

            model.flagFilter = .unflagged
            #expect(model.canStartDevelop)
            await Self.develop(model) { model.develop(resuming: stopped) }
            #expect(jobs.runs.count == 2 && Self.ids(jobs.runs[1].map(\.frame)) == [1, 3, 6] && jobs.totals.last == 3)
            // Even with nothing shown.
            model.flagFilter = .flagged
            for frame in model.shownFrames { model.setFlag(false, for: frame) }
            #expect(model.shownFrames.isEmpty && !model.canDevelop && model.canStartDevelop)
            await Self.develop(model) { model.develop(resuming: stopped) }
            #expect(jobs.runs.count == 3 && Self.ids(jobs.runs[2].map(\.frame)) == [1, 3, 6])

            model.flagFilter = .unflagged
            await Self.develop(model) { model.develop() }
            #expect(jobs.runs.count == 4 && Self.ids(jobs.runs[3].map(\.frame)) == Array(0..<8))
        }
    }

    /// Only the frames developed can hold a develop up: an adjustment issue or an unread recipe
    /// outside it is left for its own develop.
    @Test func aFrameOutsideTheDevelopDoesNotBlockIt() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let jobs = Self.capture(model), destination = fixture.folder.appendingPathComponent("Export")
            Self.flag(model, [1, 3])
            model.flagFilter = .flagged
            model.manualErrors[frames[0].url] = "fixture issue"
            model.manualLoaded.remove(frames[5].url)
            await Self.develop(model) { model.startDevelop(to: destination) }
            #expect(Self.ids(jobs.runs.last?.map(\.frame) ?? []) == [1, 3] && model.message == nil)
            #expect(!model.manualLoaded.contains(frames[5].url))

            // One inside it still does.
            model.manualErrors[frames[3].url] = "fixture issue"
            await Self.develop(model) { model.startDevelop(to: destination) }
            #expect(jobs.runs.count == 1)
            #expect(model.message?.hasPrefix("Resolve \(frames[3].name)’s adjustment issue") == true, "\(model.message ?? "none")")
        }
    }

    /// A flags file this build cannot read is left as it is; flags still change for the session, and
    /// the roll says they will not be saved.
    @Test func aFlagsFileThisBuildCannotReadIsLeftAndFlagsLastTheSession() async throws {
        try await Self.withRoll { fixture in
            let store = FlagStore(library: fixture.library), file = store.file(for: fixture.roll)
            try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
            for kept in [Data("not flags".utf8), Data(#"{"format":"camera.argent.flags","version":2,"frames":[]}"#.utf8)] {
                try kept.write(to: file)
                let model = Self.model(fixture), gate = MeasurementGate()
                let frames = try await Self.open(fixture, in: model, through: gate)
                defer { AutoDecisionStateTests.close(model, gate) }
                #expect(model.areFlagsUnsaved && model.message == RollModel.unsavedFlagsLine)
                model.message = nil
                Self.flag(model, [2])
                model.flagFilter = .flagged
                #expect(model.isFlagged(frames[2]) && Self.ids(model.shownFrames) == [2])
                #expect(model.message == RollModel.unsavedFlagsLine)
                await model.flagSave?.value
                #expect(try Data(contentsOf: file) == kept)
            }
        }
    }

    /// A file there that cannot be read, such as one at mode 000, may hold the roll's flags: it is not
    /// read as none, and never written over.
    @Test func aFlagsFileThatCannotBeReadIsNeverWrittenOver() async throws {
        try await Self.withRoll { fixture in
            let store = FlagStore(library: fixture.library), file = store.file(for: fixture.roll)
            let flagged = FlagRecord(frames: [FlagRecord.Entry(fileName: AutoDecisionStateTests.names[5], byteCount: 1, captureDate: nil)])
            #expect(try store.save(flagged, for: fixture.roll))
            let kept = try Data(contentsOf: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            #expect(model.areFlagsUnsaved && model.message == RollModel.unsavedFlagsLine)
            Self.flag(model, [2])
            await model.flagSave?.value
            #expect(model.isFlagged(frames[2]))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect(try Data(contentsOf: file) == kept)
        }
    }

    /// A flags file another build writes, or that becomes unreadable, while the roll is open: the next
    /// write leaves it, the roll says its flags cannot be saved, and no later change writes.
    @Test func aWriteRefusedMidSessionLeavesTheFileAndSaysSo() async throws {
        try await Self.withRoll { fixture in
            let file = FlagStore(library: fixture.library).file(for: fixture.roll)
            let future = Data(#"{"format":"camera.argent.flags","version":2,"frames":[]}"#.utf8)
            for becomesUnreadable in [false, true] {
                try? FileManager.default.removeItem(at: file)
                let model = Self.model(fixture), gate = MeasurementGate()
                let frames = try await Self.open(fixture, in: model, through: gate)
                defer { AutoDecisionStateTests.close(model, gate) }
                Self.flag(model, [2])
                await model.flagSave?.value
                #expect(model.flagStore.record(for: fixture.roll)?.frames.count == 1 && !model.areFlagsUnsaved)

                let kept: Data
                if becomesUnreadable {
                    kept = try Data(contentsOf: file)
                    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
                } else {
                    kept = future
                    try future.write(to: file)
                }
                Self.flag(model, [3])
                await model.flagSave?.value
                #expect(model.areFlagsUnsaved && model.message == RollModel.unsavedFlagsLine, "\(becomesUnreadable)")
                model.message = nil
                Self.flag(model, [4])
                #expect(model.message == RollModel.unsavedFlagsLine)
                await model.flagSave?.value
                #expect(Self.ids(frames.filter(model.isFlagged)) == [2, 3, 4])
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
                #expect(try Data(contentsOf: file) == kept, "\(becomesUnreadable)")
            }
        }
    }

    /// Holds what waits on it until it is opened.
    @MainActor final class Latch {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiting { waiter.resume() }
            waiting = []
        }
    }

    @MainActor final class Done {
        var isDone = false
    }

    /// F, as the keyboard sends it: the press, or a repeat of the key held down.
    static func f(repeating: Bool) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                             characters: "f", charactersIgnoringModifiers: "f", isARepeat: repeating, keyCode: 3))
    }

    /// Frame > Flag is disabled while a roll opens, and F changes nothing then: the open reads the
    /// roll's flags file once the writes before it are done, and a flag set meanwhile would be lost.
    @Test func fIsRefusedWhileARollOpens() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            #expect(model.menuState.canFlag)
            // The open waits on a write of the flags until it is let go.
            let latch = Latch()
            defer { latch.open() }
            model.flagSave = Task { await latch.wait() }
            let reopening = Task { try await AutoDecisionStateTests.open(fixture, in: model, through: gate) }
            let deadline = ContinuousClock.now + .seconds(10)
            while !model.isScanning, ContinuousClock.now < deadline { await Task.yield() }
            try #require(model.isScanning)
            #expect(!model.menuState.canFlag && !model.canFlag(frames[0]))
            model.flagSelection(try Self.f(repeating: false))
            model.setFlag(true, for: frames[1])
            #expect(model.flaggedCount == 0)
            latch.open()
            try await reopening.value
            #expect(!model.isScanning && model.menuState.canFlag && model.flaggedCount == 0)
            await model.flagSave?.value
            #expect(model.flagStore.stored(for: fixture.roll) == FlagStore.Stored.none)
        }
    }

    /// An open reads the roll's flags after the last write of them is done, whenever that finishes.
    @Test func anOpenReadsTheFlagsAfterTheLastWrite() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let store = model.flagStore, roll = fixture.roll, entry = try #require(model.flagIdentity(frames[2]))
            // A write still under way, done once the open is, or after half a second: an open that did not
            // wait for it would read the roll's flags first.
            let reopened = Done()
            model.flagSave = Task {
                var waited = 0
                while !reopened.isDone, waited < 50 {
                    try? await Task.sleep(for: .milliseconds(10))
                    waited += 1
                }
                _ = try? store.save(FlagRecord(frames: [entry]), for: roll)
            }
            _ = try await Self.open(fixture, in: model, through: gate)
            reopened.isDone = true
            #expect(Self.ids(frames.filter(model.isFlagged)) == [2])
        }
    }

    /// Quitting waits for the last write of the flags, as for the roll's settled decision.
    @Test func quittingWaitsForTheFlagsToBeWritten() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            _ = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            await model.decisionSave?.value
            let latch = Latch(), finished = Done()
            defer { latch.open() }
            model.flagSave = Task { await latch.wait() }
            let quitting = Task {
                await model.finishWritesForQuit()
                finished.isDone = true
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!finished.isDone)
            latch.open()
            await quitting.value
            #expect(finished.isDone)
        }
    }

    /// A frame whose raw is gone, with its card or moved, has no size a flag could name it by: Frame >
    /// Flag is disabled, F changes nothing and no entry is kept. A flag given before the raw went
    /// comes back with it.
    @Test func aFrameWhoseRawIsGoneCannotBeFlagged() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            Self.flag(model, [3])
            await model.flagSave?.value
            let away = fixture.folder.appendingPathComponent("Away", isDirectory: true)
            try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
            for index in [2, 3] { try FileManager.default.moveItem(at: frames[index].url, to: away.appendingPathComponent(frames[index].name)) }
            #expect(model.forgetChangedSources())
            #expect(model.flagIdentity(frames[2]) == nil && !model.canFlag(frames[2]) && !model.isFlagged(frames[3]))

            model.selection = 2
            #expect(!model.menuState.canFlag)
            model.flagSelection(nil)
            model.setFlag(true, for: frames[3])
            #expect(model.flaggedCount == 0)
            await model.flagSave?.value
            #expect(model.flagStore.record(for: fixture.roll)?.frames.map(\.fileName) == [frames[3].url.lastPathComponent])

            for index in [2, 3] { try FileManager.default.moveItem(at: away.appendingPathComponent(frames[index].name), to: frames[index].url) }
            #expect(model.forgetChangedSources())
            #expect(model.menuState.canFlag && model.isFlagged(frames[3]))
            model.flagSelection(nil)
            await model.flagSave?.value
            let kept = try #require(model.flagStore.record(for: fixture.roll))
            #expect(kept.frames == [frames[2], frames[3]].map { FlagRecord.Entry($0, byteCount: RecipeStore.byteCount(of: $0.url)) })
        }
    }

    /// A key held down repeats Frame > Flag; only the press counts. Under a filter the selection moves
    /// on as the frame leaves, and each repeat would unflag the next.
    @Test func aRepeatOfFChangesNothing() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            Self.flag(model, [1, 3, 6])
            model.flagFilter = .flagged
            #expect(model.selection == 1)
            model.flagSelection(try Self.f(repeating: false))
            #expect(!model.isFlagged(frames[1]) && model.selection == 3)
            for _ in 0..<3 { model.flagSelection(try Self.f(repeating: true)) }
            #expect(Self.ids(model.shownFrames) == [3, 6] && model.selection == 3)
            // Chosen with the pointer, the menu's event is not a key's.
            let click = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            model.flagSelection(click)
            #expect(Self.ids(model.shownFrames) == [6] && model.selection == 6)
        }
    }

    /// Edit > Undo Flag and Undo Unflag, and Redo: the frame's flag as it was, saved as any change is;
    /// on the sheet the frame is selected where it shows. A roll opened clears them, as it clears
    /// the manual edits' undo.
    @Test func undoAndRedoPutAFlagBackAndSaveIt() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let undo = UndoManager()
            undo.groupsByEvent = false
            model.manualUndoManager = undo
            @MainActor func press(_ body: () -> Void) {
                undo.beginUndoGrouping()
                body()
                undo.endUndoGrouping()
            }
            @MainActor func saved() async -> [Int] {
                await model.flagSave?.value
                let kept = model.flagStore.record(for: fixture.roll)?.frames ?? []
                return Self.ids(frames.filter { frame in kept.contains { $0.fileName == frame.url.lastPathComponent } })
            }

            press { model.flagSelection(nil) }
            #expect(model.isFlagged(frames[0]) && undo.undoActionName == "Flag")
            undo.undo()
            #expect(!model.isFlagged(frames[0]) && undo.redoActionName == "Flag" && !undo.canUndo)
            #expect(await saved() == [])
            undo.redo()
            #expect(model.isFlagged(frames[0]) && undo.undoActionName == "Flag")
            #expect(await saved() == [0])

            // Under a filter: undone, an unflagged frame comes back to the sheet, selected.
            for index in [1, 3, 6] {
                model.selection = index
                press { model.flagSelection(nil) }
            }
            model.flagFilter = .flagged
            model.selection = 3
            press { model.flagSelection(nil) }
            #expect(undo.undoActionName == "Unflag" && Self.ids(model.shownFrames) == [0, 1, 6] && model.selection == 6)
            model.selection = 0
            undo.undo()
            #expect(Self.ids(model.shownFrames) == [0, 1, 3, 6] && model.selection == 3 && undo.redoActionName == "Unflag")
            #expect(await saved() == [0, 1, 3, 6])
            undo.redo()
            #expect(Self.ids(model.shownFrames) == [0, 1, 6] && model.selection == 6)
            #expect(await saved() == [0, 1, 6])
            // In the frame view the open frame stays.
            model.openFrame()
            undo.undo()
            #expect(model.isFlagged(frames[3]) && model.shownFrame?.id == 6)
            undo.undo()
            #expect(!model.isFlagged(frames[6]) && model.shownFrame?.id == 6)

            // Another roll, or this one again, starts with nothing to undo.
            #expect(undo.canUndo && undo.canRedo)
            _ = try await Self.open(fixture, in: model, through: gate)
            #expect(!undo.canUndo && !undo.canRedo)
            #expect(Self.ids(frames.filter(model.isFlagged)) == [0, 1, 3])
        }
    }

    /// On the Develop page the filter is which frames develop, and a flag changes them: both act there as on the
    /// sheet, and the page's button counts the frames they leave. Away from the roll's frames neither does.
    @Test func flagAndShowActOnTheDevelopPage() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            #expect(model.menuState.canFlag && model.menuState.canShow && model.menuState.showsFrames)
            model.showDevelopPage()
            #expect(model.workspacePage == .develop && model.menuState.page == .develop)
            #expect(model.menuState.canFlag && model.menuState.canShow && model.menuState.showsFrames && model.canFlag(frames[0]))
            #expect(model.developPrimary == .develop(count: frames.count))
            model.flagSelection(nil)
            model.toggleFlag(frames[2])
            model.showFrames(.flagged)
            #expect(model.flaggedCount == 2 && model.flagFilter == .flagged && model.developPrimary == .develop(count: 2))
            model.showFrames(.unflagged)
            #expect(model.developPrimary == .develop(count: frames.count - 2))

            model.showWorkspacePage(.settings)
            #expect(!model.menuState.showsFrames)
        }
    }

    /// Under a filter the frame view decodes ahead the frames the arrows go to among those shown.
    @Test func theFrameViewDecodesAheadTheNextFrameShown() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            @MainActor func around(_ index: Int) -> [Int?] {
                let (ahead, behind) = model.framesAround(frames[index])
                return [ahead?.id, behind?.id]
            }
            model.selection = 3
            model.openFrame()
            #expect(around(3) == [4, 2])
            Self.flag(model, [1, 3, 6])
            model.flagFilter = .flagged
            #expect(around(3) == [6, 1])
            model.moveSelection(by: -1)
            #expect(model.shownFrame?.id == 1 && around(1) == [nil, 3])
            model.moveSelection(toLast: true)
            #expect(around(6) == [nil, 3])
        }
    }

    /// Roll > Develop from the roll opens the Develop page and starts nothing; on the page it is the page's button,
    /// which develops the frames the page shows into the folder chosen. Once that develop has stopped the button is
    /// Resume, and the same command goes on with that develop's frames, whatever the page shows by then.
    @Test func developOpensThePageAndOnItDevelopsTheFramesShown() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            _ = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let jobs = Self.capture(model), destination = fixture.folder.appendingPathComponent("Export")
            Self.flag(model, [1, 3, 6])
            model.flagFilter = .unflagged
            model.developFolder.usesSubfolder = false
            model.chooseDestination(destination)

            model.developCommand()
            #expect(model.workspacePage == .develop && model.developTask == nil && jobs.runs.isEmpty)
            await Self.develop(model) { model.developCommand() }
            #expect(Self.ids(jobs.runs.last?.map(\.frame) ?? []) == [0, 2, 4, 5, 7] && jobs.totals.last == 5)
            #expect(model.workspacePage == .develop && model.developDestination == destination)

            let stopped = try #require(model.lastDevelop)
            #expect(stopped.wasStopped && model.developPrimary == .resume(stopped) && model.developStatus == .stopped(stopped))
            model.flagFilter = .flagged
            await Self.develop(model) { model.developCommand() }
            #expect(jobs.runs.count == 2 && Self.ids(jobs.runs.last?.map(\.frame) ?? []) == [0, 2, 4, 5, 7])

            // Its status closed, the button is Develop again, with the frames the page shows.
            model.areIssuesDismissed = true
            #expect(model.developPrimary == .develop(count: 3) && model.developStatus == nil)
            await Self.develop(model) { model.developCommand() }
            #expect(Self.ids(jobs.runs.last?.map(\.frame) ?? []) == [1, 3, 6])

            // While a develop runs the command neither stops it nor starts another.
            model.developPhase = .developing(DevelopProgress(total: 3))
            model.developCommand()
            #expect(model.isDeveloping && jobs.runs.count == 3)
            model.developPhase = .idle
        }
    }

    /// A develop that finishes cleanly shows its done note whatever the sheet shows by then: a Resume
    /// of other frames than those shown, or a develop whose filter changed while it ran. A change to
    /// one of its own frames still takes the note away.
    @Test func aCleanDevelopIsDoneWhateverTheSheetShowsNow() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            _ = try #require(await model.settledDecision())
            Self.flag(model, [1, 3, 6])
            let developed = [1, 3, 6].map { frames[$0] }, destination = fixture.folder.appendingPathComponent("Export")
            let report = DevelopReport(frames: developed, outcomes: developed.map { .developed(destination.appendingPathComponent($0.name)) },
                                       destination: destination)
            let inputs = DevelopInputs(model, frames: developed.map(\.url))
            model.flagFilter = .unflagged
            model.developPhase = .developing(DevelopProgress(total: 3))
            model.recordDevelop(report, inputs: inputs)
            #expect(model.developPhase == .done)

            // A frame the develop left out changes nothing; one of its own does.
            model.developPhase = .developing(DevelopProgress(total: 3))
            model.setRatedAt(.oneStopUnder, for: frames[0])
            model.recordDevelop(report, inputs: inputs)
            #expect(model.developPhase == .done)
            model.developPhase = .developing(DevelopProgress(total: 3))
            model.setRatedAt(.oneStopUnder, for: frames[3])
            model.recordDevelop(report, inputs: inputs)
            #expect(model.developPhase == .idle)
        }
    }

    /// A filtered develop as the roll's first, started before Auto has settled the roll: it waits for
    /// the whole roll's decision, and its jobs are those a first develop of the whole roll gives the
    /// same frames, in a library of its own.
    @Test func aFilteredFirstDevelopBeforeTheRollSettlesPrintsAsTheWholeRoll() async throws {
        try await Self.withRoll { fixture in
            @MainActor func firstDevelop(_ model: RollModel, flags: [Int]) async throws -> [RollDeveloper.Job] {
                let gate = MeasurementGate()
                try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
                defer { AutoDecisionStateTests.close(model, gate) }
                let frames = try #require(model.roll?.frames), jobs = Self.capture(model)
                if !flags.isEmpty {
                    Self.flag(model, flags)
                    model.flagFilter = .flagged
                }
                #expect(!model.isBalanced && model.lastDevelop == nil && model.chosenDevelopFolder == nil)
                model.chooseDestination(fixture.folder.appendingPathComponent("Export"))
                model.develop()
                try await gate.waitUntilWaiting(for: frames.count)
                #expect(!model.isBalanced)
                gate.openAll(frames)
                await model.developTask?.value
                let decision = try #require(model.autoDecision)
                #expect(decision.aims.count == frames.count)
                return try #require(jobs.runs.last)
            }
            let filtered = try await firstDevelop(Self.model(fixture), flags: [1, 3, 6])
            #expect(Self.ids(filtered.map(\.frame)) == [1, 3, 6])

            let library = fixture.folder.appendingPathComponent("Whole roll library")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let whole = RollModel(bookmarks: BookmarkStore(file: library.appendingPathComponent("bookmarks.json"), securityScoped: false),
                                  stocksDirectory: fixture.stocks, decisions: AutoDecisionStore(library: library),
                                  flagStore: FlagStore(library: library), recipeLibrary: library,
                                  previewCache: library.appendingPathComponent("Linear Previews"), digestsFile: nil)
            fixture.made.models.append(whole)
            let byFrame = Dictionary(uniqueKeysWithValues: try await firstDevelop(whole, flags: []).map { ($0.frame.url, $0) })
            #expect(byFrame.count == 8)
            /// The recipe apart from the session that made it.
            func print(_ recipe: Recipe) -> Recipe {
                var recipe = recipe
                recipe.editRevision = nil
                recipe.editLineage = nil
                recipe.editDate = nil
                return recipe
            }
            for job in filtered {
                let same = try #require(byFrame[job.frame.url])
                #expect(print(job.recipe) == print(same.recipe), "\(job.frame.name)")
                #expect(job.autoRevision == same.autoRevision && job.measuredFrom == same.measuredFrom && job.frameSource == same.frameSource)
            }
        }
    }

    /// The menu bar is rebuilt when Frame > Flag changes, not at each arrow press on the sheet.
    @Test func anArrowPressOnTheSheetLeavesTheMenuBarAlone() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            _ = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            final class Changed: @unchecked Sendable { var count = 0 }
            let changed = Changed()
            @MainActor func observe() { withObservationTracking { _ = model.menuState } onChange: { changed.count += 1 } }
            observe()
            model.moveSelection(by: 1)
            model.moveSelection(by: 1)
            #expect(changed.count == 0)
            model.flagSelection(nil)
            #expect(changed.count == 1 && model.menuState.isFlagged)
            observe()
            model.moveSelection(by: 1)
            #expect(changed.count == 2 && !model.menuState.isFlagged)
        }
    }

    /// While the filter shows no frame, the stock palette shows the frame the selection comes back to.
    @Test func thePaletteKeepsAFrameWhileTheFilterShowsNone() async throws {
        try await Self.withRoll { fixture in
            let model = Self.model(fixture), gate = MeasurementGate()
            let frames = try await Self.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            model.selection = 4
            model.flagFilter = .flagged
            #expect(model.selection == nil && model.paletteFrame == frames[4])
            model.showFrames(.all)
            #expect(model.selection == 4 && model.paletteFrame == frames[4])
        }
    }
}
