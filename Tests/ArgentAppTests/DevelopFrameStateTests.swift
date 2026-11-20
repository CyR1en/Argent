import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// A frame's own develop and files: Develop This Frame goes the way Resume goes with a stopped develop's frames, into
/// the roll's folder without leaving the roll for the Develop page, and leaves Develop for other
/// frames shown; Show Developed File in Finder finds the file the frame's last
/// develop wrote while it is there. Each develop is stopped as its jobs are made (`FlagStateTests.capture`).
@MainActor @Suite(.serialized) struct DevelopFrameStateTests {
    typealias Fixture = AutoDecisionStateTests.Fixture

    static func withModel(_ body: (RollModel, [Frame], Fixture) async throws -> Void) async throws {
        try await FlagStateTests.withRoll { fixture in
            let model = FlagStateTests.model(fixture), gate = MeasurementGate()
            let frames = try await FlagStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            try await body(model, frames, fixture)
        }
    }

    @Test func developThisFrameDevelopsItAloneAsAFilteredSheetShowingItWould() async throws {
        try await Self.withModel { model, frames, fixture in
            let jobs = FlagStateTests.capture(model), destination = fixture.folder.appendingPathComponent("Export")
            model.developFolder.usesSubfolder = false
            model.chooseDestination(destination)
            await FlagStateTests.develop(model) { model.developFrame(frames[4]) }
            let alone = try #require(jobs.runs.last)
            #expect(alone.map(\.frame.url) == [frames[4].url] && jobs.totals.last == 1 && model.workspacePage == .roll)
            let report = try #require(model.lastDevelop)
            #expect(report.raws == [frames[4].url] && report.total == 1 && report.destination == destination)

            // Stopped, it is Resume's to go on with, and Resume develops that frame again.
            #expect(model.developPrimary == .resume(report))
            await FlagStateTests.develop(model) { model.performDevelopPrimary() }
            #expect(jobs.runs.count == 2 && jobs.runs.last?.map(\.frame.url) == [frames[4].url])

            // The same as a develop of the sheet filtered to show that frame alone: its job and its report.
            model.setFlag(true, for: frames[4])
            model.showFrames(.flagged)
            await FlagStateTests.develop(model) { model.develop() }
            let filtered = try #require(jobs.runs.last)
            #expect(filtered.map(\.frame.url) == [frames[4].url] && filtered.first?.recipe == alone.first?.recipe)
            #expect(model.lastDevelop == report)
            // And the job a develop of the whole roll gives it: flags and filters never change a print.
            model.showFrames(.all)
            await FlagStateTests.develop(model) { model.develop() }
            let whole = try #require(jobs.runs.last?.first { $0.frame.url == frames[4].url })
            #expect(whole.recipe == alone.first?.recipe && whole.autoRevision == alone.first?.autoRevision)
        }
    }

    /// Without a folder chosen a develop goes to ~/Argent/Developed/<roll>, which the Develop page shows; a folder chosen
    /// there is the roll's from then on, and a develop of one frame goes into it without the Develop page.
    @Test func developThisFrameGoesToTheRollsFolderWithoutTheDevelopPage() async throws {
        try await Self.withModel { model, frames, fixture in
            let jobs = FlagStateTests.capture(model), destination = fixture.folder.appendingPathComponent("Export")
            let unchosen = try #require(model.developDestination)
            #expect(model.chosenDevelopFolder == nil && model.developFolder.usesSubfolder)
            #expect(unchosen == RollModel.argentDeveloped.appendingPathComponent(fixture.roll.lastPathComponent, isDirectory: true))
            #expect(RollModel.argentDeveloped.path == RollModel.userHome.path + "/Argent/Developed")

            model.developFolder.usesSubfolder = false
            model.chooseDestination(destination)
            #expect(model.developDestination == destination)
            await FlagStateTests.develop(model) { model.developFrame(frames[2]) }
            #expect(jobs.runs.last?.map(\.frame.url) == [frames[2].url] && jobs.totals.last == 1)
            #expect(model.lastDevelop?.destination == destination && model.workspacePage == .roll)
            #expect(DevelopStatusText.summary(model, frames: model.framesToDevelop([frames[2].url])).hasPrefix("1 of 8 frames"))

            // A Resume of a stopped develop of several frames goes on with those frames, into the folder chosen.
            await FlagStateTests.develop(model) {
                model.develop(resuming: DevelopReport(frames: [frames[1], frames[3]], outcomes: [.stopped, .stopped], destination: destination))
            }
            #expect(jobs.runs.last?.map(\.frame.url) == [frames[1].url, frames[3].url] && model.developDestination == destination)
        }
    }

    /// Develop This Frame can start when Develop could, for a frame of the roll, whatever the sheet shows: as Resume,
    /// its frame need not be shown.
    #if DEBUG
    @Test func developThisFrameFollowsDevelopsOwnRule() async throws {
        try await Self.withModel { model, frames, fixture in
            #expect(model.canDevelopFrame(frames[0]))
            model.developPhase = .developing(DevelopProgress(total: 1))
            #expect(!model.canDevelopFrame(frames[0]))
            model.developFrame(frames[0])
            #expect(model.developTask == nil && model.workspacePage == .roll)
            model.developPhase = .idle
            model.isRestoringManual = true
            #expect(!model.canDevelopFrame(frames[0]))
            model.isRestoringManual = false
            model.isQuitting = true
            #expect(!model.canDevelopFrame(frames[0]))
            model.isQuitting = false

            let stranger = Frame(id: 99, url: fixture.folder.appendingPathComponent("Elsewhere/DSC9.ARW"), info: ARWFrameInfo())
            #expect(!model.canDevelopFrame(stranger))
            model.developFrame(stranger)
            #expect(model.developTask == nil)

            // Left out by the filter, or with no frame shown at all, where Develop cannot.
            model.setFlag(true, for: frames[1])
            model.showFrames(.flagged)
            #expect(model.canDevelopFrame(frames[0]))
            model.setFlag(false, for: frames[1])
            #expect(model.shownFrames.isEmpty && !model.canDevelop && model.canDevelopFrame(frames[0]))

            model.holdReadingForDebug()
            #expect(!model.canDevelopFrame(frames[0]))
        }
    }
    #endif

    /// A develop of one frame leaves Develop for the other frames shown and keeps its file available in Reveal
    /// Developed Files. When the sheet shows only that frame, the same report leaves the completed status and Reveal
    /// in Finder; showing all frames afterwards gives Develop back.
    @Test func aOneFrameDevelopKeepsDevelopUnlessOnlyThatFrameIsShown() async throws {
        try await Self.withModel { model, frames, fixture in
            _ = try #require(await model.settledDecision())
            let destination = fixture.folder.appendingPathComponent("Export")
            let report = DevelopReport(frames: [frames[4]], outcomes: [.developed(destination.appendingPathComponent("DSC05.jpg"))],
                                       destination: destination)
            model.showFrames(.all)
            #expect(model.shownFrames.count == frames.count && model.shownFrames.count > 1)
            model.developPhase = .developing(DevelopProgress(total: 1))
            model.recordDevelop(report, inputs: DevelopInputs(model, frames: [frames[4].url]))
            #expect(model.developPhase == .idle)
            #expect(model.developStatus == nil)
            #expect(model.developPrimary == .develop(count: model.shownFrames.count))
            #expect(model.menuState.canReveal && model.lastDevelop?.files == report.files)

            model.setFlag(true, for: frames[4])
            model.showFrames(.flagged)
            #expect(model.shownFrames.map(\.url) == [frames[4].url])
            model.developPhase = .developing(DevelopProgress(total: 1))
            model.recordDevelop(report, inputs: DevelopInputs(model))
            #expect(model.developPhase == .done && model.developStatus == .complete(report) && model.developPrimary == .reveal)
            #expect(model.menuState.canReveal && model.lastDevelop?.files == report.files)
            #expect(DevelopStatusText.title(.complete(report)) == "Roll developed")
            #expect(DevelopStatusText.counts(.complete(report)) == "1 of 1 frame saved")

            model.showFrames(.all)
            #expect(model.developPhase == .idle && model.developPrimary == .develop(count: frames.count))
        }
    }

    /// The Develop page's marks: while a develop runs, what has come of each of its frames so far; after it, a check
    /// on each frame it has a file for and a mark on each it could not write. A check goes when a develop would write
    /// the frame again: an edit to that frame takes its own, another quality or folder takes them all, and undoing the
    /// change gives them back. A later develop of other frames leaves the checks of the frames it left out.
    @Test func theDevelopPagesMarksFollowTheSessionsDevelopsAndWhatHasChangedSince() async throws {
        try await Self.withModel { model, frames, fixture in
            _ = try #require(await model.settledDecision())
            let destination = fixture.folder.appendingPathComponent("Export")
            model.developFolder.usesSubfolder = false
            model.chooseDestination(destination)
            #expect(model.developMarks.isEmpty)
            @MainActor func file(_ index: Int) -> URL { destination.appendingPathComponent("\(frames[index].name).jpg") }
            let developed = [frames[0], frames[1], frames[2], frames[3]]
            let outcomes: [RollDeveloper.Outcome] = [.developed(file(0)), .failed("no"), .alreadyDeveloped(file(2)), .stopped]

            // Under way: the frames finished so far.
            let inputs = DevelopInputs(model, frames: developed.map(\.url))
            model.developPhase = .developing(DevelopProgress(total: 4))
            model.developOutcomes = [frames[0].url: outcomes[0], frames[1].url: outcomes[1]]
            #expect(model.developMarks == [frames[0].url: .developed, frames[1].url: .failed])

            // Ended: every frame with a file, written now or found from before, and the one that failed; not the one
            // it was stopped before.
            let report = DevelopReport(frames: developed, outcomes: outcomes, destination: destination)
            model.noteDeveloped(developed, outcomes, destination: destination, inputs: inputs)
            model.recordDevelop(report, inputs: inputs)
            let first: [URL: DevelopMark] = [frames[0].url: .developed, frames[1].url: .failed, frames[2].url: .developed]
            #expect(model.developMarks == first)

            // A change to one of its frames takes that frame's check, and gives it back when undone; a frame it left
            // out changes nothing.
            model.setRatedAt(.oneStopUnder, for: frames[2])
            #expect(model.developMarks == [frames[0].url: .developed, frames[1].url: .failed])
            model.clearOverrides(for: frames[2])
            #expect(model.developMarks == first)
            model.setRatedAt(.oneStopUnder, for: frames[6])
            #expect(model.developMarks == first)

            // Another quality, or another folder, makes Develop write every frame again.
            let quality = model.output.quality
            model.output.quality = quality == 60 ? 92 : 60
            #expect(model.developMarks == [frames[1].url: .failed])
            model.output.quality = quality
            #expect(model.developMarks == first)
            model.chooseDestination(fixture.folder.appendingPathComponent("Elsewhere"))
            #expect(model.developMarks == [frames[1].url: .failed])
            model.chooseDestination(destination)
            #expect(model.developMarks == first)

            // A later develop of other frames keeps the checks of the frames it left out; the frame that failed before
            // and develops now is checked; one it is stopped before keeps the check it had.
            let later = [frames[1], frames[2], frames[5]], laterInputs = DevelopInputs(model, frames: later.map(\.url))
            let laterOutcomes: [RollDeveloper.Outcome] = [.developed(file(1)), .stopped, .developed(file(5))]
            let before = model.developedFrames
            model.developPhase = .developing(DevelopProgress(total: 3))
            model.noteDeveloped(later, laterOutcomes, destination: destination, inputs: laterInputs, before: before)
            model.recordDevelop(DevelopReport(frames: later, outcomes: laterOutcomes, destination: destination), inputs: laterInputs)
            #expect(model.developMarks == [frames[0].url: .developed, frames[1].url: .developed, frames[2].url: .developed,
                                           frames[5].url: .developed])
        }
    }

    /// Choosing the roll's folder turns a finished develop's Reveal in Finder back into Develop: its files are not there.
    @Test func anotherFolderTurnsRevealBackIntoDevelop() async throws {
        try await Self.withModel { model, frames, fixture in
            _ = try #require(await model.settledDecision())
            let destination = fixture.folder.appendingPathComponent("Export")
            model.developFolder.usesSubfolder = false
            model.chooseDestination(destination)
            let report = DevelopReport(frames: frames, outcomes: frames.map { .developed(destination.appendingPathComponent($0.name)) },
                                       destination: destination)
            model.developPhase = .developing(DevelopProgress(total: frames.count))
            model.recordDevelop(report, inputs: DevelopInputs(model))
            #expect(model.developPhase == .done && model.developPrimary == .reveal)
            // The same folder again changes nothing.
            model.chooseDestination(destination)
            #expect(model.developPrimary == .reveal)
            model.chooseDestination(fixture.folder.appendingPathComponent("Elsewhere"))
            #expect(model.developPhase == .idle && model.developPrimary == .develop(count: frames.count))
        }
    }

    /// A recipe of `frame` whose develops wrote `files`, oldest first.
    static func recipe(_ frame: Frame, developed files: [URL]) -> Recipe {
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.8, 0.8), negative: LUT3D.identity(size: 2), print: LUT3D.identity(size: 2))
        var recipe = Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls(), editRevision: 1)
        recipe.develops = files.map { file in
            Recipe.Develop(date: Date(), software: "Argent test", output: OutputSettings(), file: file.path, width: 1, height: 1,
                           render: recipe.render, decode: nil, readback: nil, stockDigest: stock.digest, renderVersion: nil,
                           fallbackFrom: nil, outputSource: nil)
        }
        return recipe
    }

    @Test func theDevelopedFileIsTheOneTheFramesLastDevelopWroteWhileItIsThere() async throws {
        try await Self.withModel { model, frames, fixture in
            let destination = fixture.folder.appendingPathComponent("Export")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            @MainActor func write(_ name: String) throws -> URL {
                let file = destination.appendingPathComponent(name)
                try Data(name.utf8).write(to: file)
                return file
            }
            @MainActor func row(_ frame: Frame) -> Bool? {
                FrameMenu.entries(for: frame, on: .filmstrip, model: model).entry("frame.showDeveloped")?.isEnabled
            }
            #expect(model.developedFile(for: frames[3]) == nil && row(frames[3]) == false)
            #expect(!model.hasDevelopedRecord(for: frames[3]))

            // The last develop's file for the frame, by its place among the frames that have one.
            let third = try write("DSC03.jpg"), fourth = try write("DSC04.jpg"), fifth = try write("DSC05.jpg")
            model.lastDevelop = DevelopReport(frames: [frames[1], frames[2], frames[3], frames[4]],
                                              outcomes: [.failed("no"), .developed(third), .developed(fourth), .alreadyDeveloped(fifth)],
                                              destination: destination)
            #expect(model.developedFile(for: frames[3]) == fourth && row(frames[3]) == true)
            #expect(model.developedFile(for: frames[4]) == fifth && model.developedFile(for: frames[2]) == third)
            // Gone: none. The record the menu bar reads at each selection change stays, since it does not ask the disk; the
            // menu bar's item then says the file has gone when it is chosen.
            try FileManager.default.removeItem(at: fourth)
            #expect(model.developedFile(for: frames[3]) == nil && row(frames[3]) == false)
            #expect(model.hasDevelopedRecord(for: frames[3]) && !model.hasDevelopedRecord(for: frames[1]) && !model.hasDevelopedRecord(for: frames[6]))

            // Its recipe's newest receipt, when the last develop's file has gone, or it failed, or it left the frame out.
            let earlier = try write("DSC04 earlier.jpg")
            model.manualRecipes[frames[3].url] = Self.recipe(frames[3], developed: [destination.appendingPathComponent("gone.jpg"), earlier])
            #expect(model.developedFile(for: frames[3]) == earlier)
            let failedBefore = try write("DSC02 before.jpg")
            model.manualRecipes[frames[1].url] = Self.recipe(frames[1], developed: [failedBefore])
            #expect(model.developedFile(for: frames[1]) == failedBefore)
            #expect(model.developedFile(for: frames[6]) == nil)
            // The newest receipt is the one; one whose file has gone gives none, rather than an older file.
            model.manualRecipes[frames[6].url] = Self.recipe(frames[6], developed: [earlier, destination.appendingPathComponent("gone.jpg")])
            #expect(model.developedFile(for: frames[6]) == nil)

            // A stopped develop does not say which frames it reached: never a neighbour's file.
            let seventh = try write("DSC07.jpg")
            model.lastDevelop = DevelopReport(frames: [frames[5], frames[7]], outcomes: [.stopped, .developed(seventh)], destination: destination)
            #expect(model.developedFile(for: frames[5]) == nil && model.developedFile(for: frames[7]) == nil)
        }
    }

    @Test func aReportFindsAFramesFileOnlyWhereItCanSay() {
        let folder = URL(fileURLWithPath: "/tmp/develop-frame-state")
        let frames = (0..<4).map { Frame(id: $0, url: folder.appendingPathComponent("DSC\($0).ARW"), info: ARWFrameInfo()) }
        let files = (0..<4).map { folder.appendingPathComponent("DSC\($0).jpg") }
        let mixed = DevelopReport(frames: frames, outcomes: [.developed(files[0]), .failed("no"), .alreadyDeveloped(files[2]), .developed(files[3])],
                                  destination: folder)
        #expect(frames.map { mixed.file(for: $0.url) } == [files[0], nil, files[2], files[3]])
        #expect(mixed.file(for: folder.appendingPathComponent("DSC9.ARW")) == nil)
        let stopped = DevelopReport(frames: frames, outcomes: [.developed(files[0]), .stopped, .developed(files[2]), .stopped], destination: folder)
        #expect(frames.allSatisfy { stopped.file(for: $0.url) == nil })
    }
}
