import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The quick develop dialog: on the roll, Develop This Frame and Develop N Frames ask where the files go and as what
/// before they develop, and on the Develop page, whose panel has that in sight, they develop at once. The dialog's
/// choices are its own until its Develop is pressed, which makes them the roll's folder and the output choices kept for
/// every roll; Cancel changes nothing. Each develop is stopped as its jobs are made (`FlagStateTests.capture`).
@MainActor @Suite(.serialized) struct QuickDevelopStateTests {
    typealias Fixture = AutoDecisionStateTests.Fixture

    /// A roll open with a folder of its own to develop to, and the output choices put back as they were stored after
    /// `body`, absent if they were: they are kept for every roll, in the process's defaults.
    static func withModel(_ body: (RollModel, [Frame], Fixture) async throws -> Void) async throws {
        let stored = UserDefaults.standard.data(forKey: "outputSettings")
        defer { UserDefaults.standard.set(stored, forKey: "outputSettings") }
        try await DevelopFrameStateTests.withModel { model, frames, fixture in
            model.developFolder.usesSubfolder = false
            model.chooseDestination(fixture.folder.appendingPathComponent("Export"))
            try await body(model, frames, fixture)
        }
    }

    @Test func aMenusDevelopAsksOnTheRollAndDevelopsAtOnceOnTheDevelopPage() async throws {
        try await Self.withModel { model, frames, fixture in
            let jobs = FlagStateTests.capture(model), destination = try #require(model.developDestination)

            // On the sheet: the row ends in an ellipsis, and choosing it puts the dialog up for that frame, with the
            // roll's folder and the output choices as they stand. Nothing develops yet.
            let row = try #require(FrameMenu.entries(for: frames[4], on: .sheet, model: model).entry("frame.develop"))
            #expect(row.title == "Develop This Frame…" && model.developAsksSettings)
            row.choose()
            #expect(model.quickDevelop == QuickDevelop(frames: [frames[4].url], output: model.output, folder: model.developFolder))
            #expect(model.quickDevelopFrames == [frames[4]] && model.canConfirmQuickDevelop)
            #expect(QuickDevelopSheet.title(model.quickDevelopFrames) == "Develop \(frames[4].name)")
            #expect(model.developTask == nil && jobs.runs.isEmpty && model.workspacePage == .roll)
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }
            #expect(jobs.last == [frames[4].url] && jobs.totals == [1] && model.quickDevelop == nil)
            #expect(model.workspacePage == .roll && model.lastDevelop?.destination == destination)

            // Several selected: their row, in capture order whatever order they were picked in; and the Frame menu's
            // item, which asks the same way.
            model.select(frames[5])
            model.select(frames[1], .toggle)
            model.select(frames[3], .toggle)
            let several = try #require(FrameMenu.entries(for: model.framesActedOn(from: frames[3]), on: .sheet, model: model).entry("frames.develop"))
            #expect(several.title == "Develop 3 Frames…")
            several.choose()
            #expect(model.quickDevelop?.frames == [frames[1].url, frames[3].url, frames[5].url])
            #expect(QuickDevelopSheet.title(model.quickDevelopFrames) == "Develop 3 frames")
            model.cancelQuickDevelop()
            #expect(model.quickDevelop == nil && jobs.runs.count == 1)
            model.developSelection()
            #expect(model.quickDevelop?.frames == [frames[1].url, frames[3].url, frames[5].url])
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }
            #expect(jobs.last == [frames[1].url, frames[3].url, frames[5].url] && jobs.totals.last == 3)
            // The other frames shown are not developed: the Develop page's button stays Develop.
            #expect(model.developPhase == .idle)

            // In the frame view: the photograph's and the strip's row ask too.
            model.selection = frames[2].id
            model.openFrame()
            #expect(model.isFrameOpen && model.workspacePage == .roll)
            let strip = try #require(FrameMenu.entries(for: frames[2], on: .filmstrip, model: model).entry("frame.develop"))
            #expect(strip.title == "Develop This Frame…")
            strip.choose()
            #expect(model.quickDevelop?.frames == [frames[2].url])
            model.cancelQuickDevelop()
            model.closeFrame()

            // On the Develop page the panel beside the grid says where and as what: no ellipsis, no dialog.
            model.showDevelopPage()
            let onPage = try #require(FrameMenu.entries(for: frames[6], on: .sheet, model: model).entry("frame.develop"))
            #expect(onPage.title == "Develop This Frame" && !model.developAsksSettings)
            await FlagStateTests.develop(model) { onPage.choose() }
            #expect(model.quickDevelop == nil && jobs.last == [frames[6].url] && model.workspacePage == .develop)
            model.select(frames[0])
            model.select(frames[1], .range)
            #expect(FrameMenu.entries(for: model.selectedFrames, on: .sheet, model: model).entry("frames.develop")?.title == "Develop 2 Frames")
            await FlagStateTests.develop(model) { model.developSelection() }
            #expect(model.quickDevelop == nil && jobs.last == [frames[0].url, frames[1].url])
        }
    }

    @Test func theDialogsChoicesBecomeTheRollsOnlyWhenItDevelops() async throws {
        try await Self.withModel { model, frames, fixture in
            let jobs = FlagStateTests.capture(model), destination = try #require(model.developDestination)
            let before = model.output, elsewhere = fixture.folder.appendingPathComponent("Elsewhere")
            var chosen = before
            chosen.format = before.format == .tiff16 ? .jpeg : .tiff16
            chosen.quality = before.quality == 60 ? 61 : 60
            chosen.grain = before.grain == .off ? .natural : .off

            // Cancel: the choices made in the dialog go with it.
            model.askToDevelop([frames[1], frames[2]])
            model.quickDevelop?.output = chosen
            model.quickDevelop?.folder.base = elsewhere
            #expect(model.output == before && model.developDestination == destination)
            model.cancelQuickDevelop()
            #expect(model.quickDevelop == nil && model.output == before && model.developDestination == destination)
            #expect(model.developTask == nil && jobs.runs.isEmpty)

            // The next dialog starts from the roll's own again; its Develop makes its choices the roll's folder and the
            // choices kept for every roll, and develops its frames with them.
            model.askToDevelop([frames[1], frames[2]])
            #expect(model.quickDevelop == QuickDevelop(frames: [frames[1].url, frames[2].url], output: before, folder: model.developFolder))
            model.quickDevelop?.output = chosen
            model.quickDevelop?.folder.base = elsewhere
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }
            #expect(model.output == chosen && RollModel.savedOutput() == chosen)
            #expect(model.developDestination == elsewhere)
            #expect(jobs.last == [frames[1].url, frames[2].url] && model.lastDevelop?.destination == elsewhere)
            #expect(jobs.runs.last?.allSatisfy { $0.recipe.render.settings.grain == chosen.grain.amount } == true)

            // And the dialog after it starts from them.
            model.askToDevelop([frames[0]])
            #expect(model.quickDevelop == QuickDevelop(frames: [frames[0].url], output: chosen, folder: model.developFolder))
        }
    }

    /// Without a folder chosen for the roll the dialog shows ~/Argent/Developed/<roll>, and asking leaves the roll without
    /// one of its own. A develop makes the folder it went to the roll's, as every develop does (`startDevelop`); this one
    /// goes to a folder chosen in the dialog, since a test never develops into ~/Argent.
    @Test func theDialogShowsTheDefaultFolderUntilOneIsChosen() async throws {
        try await Self.withModel { model, frames, fixture in
            model.chosenDevelopFolder = nil
            let unchosen = RollModel.argentDeveloped.appendingPathComponent(fixture.roll.lastPathComponent, isDirectory: true)
            model.askToDevelop([frames[0]])
            #expect(model.quickDevelop?.folder.destination == unchosen && model.chosenDevelopFolder == nil)
            // A folder chosen in the dialog is the roll's once it develops.
            let jobs = FlagStateTests.capture(model), chosen = fixture.folder.appendingPathComponent("Chosen")
            model.quickDevelop?.folder.base = chosen
            model.quickDevelop?.folder.usesSubfolder = false
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }
            #expect(model.developDestination == chosen && jobs.last == [frames[0].url])
        }
    }

    @Test func subfolderEditsStayInTheDialogUntilConfirmed() async throws {
        try await Self.withModel { model, frames, fixture in
            let base = model.developFolder.base
            model.askToDevelop([frames[0]])
            model.quickDevelop?.folder.usesSubfolder = true
            #expect(model.quickDevelop?.folder.subfolderName == fixture.roll.lastPathComponent)
            for invalid in ["", "  ", ".", "..", "../elsewhere", "nested/path", "/\u{301}", "a\0b"] {
                model.quickDevelop?.folder.subfolderName = invalid
                #expect(!model.canConfirmQuickDevelop)
                model.confirmQuickDevelop()
                #expect(model.quickDevelop != nil && model.developTask == nil)
            }
            model.quickDevelop?.folder.subfolderName = "Family 👨‍👩‍👧"
            #expect(model.canConfirmQuickDevelop)
            model.cancelQuickDevelop()
            #expect(model.developDestination == base && !model.developFolder.usesSubfolder)

            model.showDevelopPage()
            model.developFolder.usesSubfolder = true
            model.developFolder.subfolderName = ".."
            #expect(!model.canPerformDevelopPrimary && !model.canDevelopFrame(frames[0]))
            model.developFolder.usesSubfolder = false
            #expect(model.canPerformDevelopPrimary && model.developDestination == base)
        }
    }

    /// The dialog asks only where it is shown, on the roll; on the Develop page the frames develop at once; on any other
    /// page nothing happens, and nothing waits to show on the way back to the roll. While a dialog is up, asking again
    /// leaves it as it is.
    @Test func aDevelopAsksOnlyWhereTheDialogShows() async throws {
        try await Self.withModel { model, frames, fixture in
            let jobs = FlagStateTests.capture(model)
            model.select(frames[2])
            for page in [WorkspacePage.settings, .rolls] {
                model.showWorkspacePage(page)
                #expect(model.workspacePage == page && !model.developAsksSettings)
                model.developSelection()
                model.askToDevelop([frames[3]])
                #expect(model.quickDevelop == nil && model.developTask == nil)
            }
            let card = Card(volume: URL(fileURLWithPath: "/Volumes/Untitled"), name: "Untitled", rawCount: 0)
            model.showWorkspacePage(.roll)
            model.importSession = .reviewing(ImportReview(card: card, frames: [], headers: [], settings: CullSettings()))
            defer { model.importSession = .idle }
            #expect(model.workspacePage == .importReview && !model.developAsksSettings)
            model.developSelection()
            #expect(model.quickDevelop == nil && model.developTask == nil)
            model.importSession = .idle
            #expect(model.workspacePage == .roll && model.quickDevelop == nil && jobs.runs.isEmpty)

            // Asked again with a dialog up: the dialog, its frames and the choices made in it stay.
            model.askToDevelop([frames[0], frames[1]])
            model.quickDevelop?.output.quality = model.output.quality == 60 ? 61 : 60
            let asked = model.quickDevelop
            model.askToDevelop([frames[2]])
            model.developSelection()
            #expect(model.quickDevelop == asked && asked != nil)
            #expect(model.developTask == nil && jobs.runs.isEmpty)
        }
    }

    /// An import's copy goes on behind the roll when the roll is asked for, and sets its session at each frame copied:
    /// the dialog stays over the roll. An import's review takes the workspace, and the dialog with it.
    @Test func theDialogStaysThroughACopyBehindTheRollAndGoesWithAReview() async throws {
        try await Self.withModel { model, frames, fixture in
            let card = Card(volume: URL(fileURLWithPath: "/Volumes/Untitled"), name: "Untitled", rawCount: 2)
            let review = ImportReview(card: card, frames: [], headers: [], settings: CullSettings())
            let folder = fixture.folder.appendingPathComponent("Imported")
            defer { model.importSession = .idle }
            model.askToDevelop([frames[0]])
            let asked = try #require(model.quickDevelop)
            model.importSession = .copying(review, folder: folder, done: 0, of: 2)
            #expect(model.workspacePage == .roll && model.quickDevelop == asked)
            model.importSession = .copying(review, folder: folder, done: 1, of: 2)
            model.importSession = .copying(review, folder: folder, done: 2, of: 2)
            #expect(model.workspacePage == .roll && model.quickDevelop == asked)
            model.importSession = .idle
            #expect(model.quickDevelop == asked)

            model.importSession = .reviewing(review)
            #expect(model.workspacePage == .importReview && model.quickDevelop == nil)
        }
    }

    /// The dialog was asked from the sheet or the frame view: the rail's Roll and Frame, which swap one for the other under
    /// it, take it with them, as Open Frame and Back to Contact Sheet would.
    @Test func theDialogGoesWhenTheViewUnderItChanges() async throws {
        try await Self.withModel { model, frames, fixture in
            model.select(frames[3])
            model.askToDevelop([frames[3]])
            model.openFrame()
            #expect(model.isFrameOpen && model.quickDevelop == nil)
            model.askToDevelop([frames[3]])
            model.showRoll()
            #expect(!model.isFrameOpen && model.quickDevelop == nil)
            model.askToDevelop([frames[3]])
            model.showFrame()
            #expect(model.isFrameOpen && model.quickDevelop == nil)
            model.askToDevelop([frames[3]])
            model.closeFrame()
            #expect(!model.isFrameOpen && model.quickDevelop == nil && model.developTask == nil)
        }
    }

    /// Under the dialog the menu bar's commands for the roll, its frames and the selection are disabled, by one fact that
    /// changes as the dialog comes and goes and not at a choice made in it, so a drag of Quality does not rebuild the menu
    /// bar (docs/M2-shell.md, section 18).
    @Test func theMenuBarLeavesTheRollAloneUnderTheDialog() async throws {
        try await Self.withModel { model, frames, fixture in
            model.select(frames[2])
            let before = model.menuState
            #expect(!before.isAskingToDevelop && before.actsOnRoll && before.actsOnFrames)
            #expect(before.canFlag && before.canOpenFrame && before.canDevelopFrame)
            let changes = ClipboardMenuStateTests.Changes()
            changes.observe { _ = model.menuState }
            model.askToDevelop([frames[2]])
            #expect(changes.count == 1 && model.isAskingToDevelop)
            let up = model.menuState
            #expect(up.isAskingToDevelop && !up.actsOnRoll && !up.actsOnFrames && up.page == .roll)

            // A choice made in the dialog: the menu bar's state is not asked again.
            changes.observe { _ = model.menuState }
            model.quickDevelop?.output.quality = model.output.quality == 60 ? 61 : 60
            model.quickDevelop?.output.grain = model.output.grain == .off ? .natural : .off
            model.quickDevelop?.folder.base = fixture.folder.appendingPathComponent("Elsewhere")
            #expect(changes.count == 1 && model.menuState == up)

            model.cancelQuickDevelop()
            #expect(changes.count == 2 && !model.isAskingToDevelop && model.menuState == before)
        }
    }

    /// Another roll opening takes the dialog with it: its frames were the roll's that went.
    @Test func theDialogGoesWhenAnotherRollOpens() async throws {
        try await Self.withModel { model, frames, fixture in
            let other = fixture.folder.appendingPathComponent("Roll B")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            for index in AutoDecisionStateTests.names.indices {
                try writeSequenceHeader(other.appendingPathComponent(AutoDecisionStateTests.names[index]),
                                        captured: AutoDecisionStateTests.captured(index), tail: Data(UUID().uuidString.utf8))
            }
            model.askToDevelop([frames[0], frames[1]])
            #expect(model.quickDevelop != nil)
            await model.open(other)
            if let restoration = model.manualRestoreTask { await restoration.value }
            #expect(model.roll?.folder.lastPathComponent == "Roll B" && model.quickDevelop == nil && !model.isAskingToDevelop)
        }
    }

    #if DEBUG
    /// The dialog is the roll's: it goes when the workspace shows another page and when frames leave the roll; and it
    /// develops only while Develop could.
    @Test func theDialogGoesWithTheRollAndFollowsDevelopsOwnRule() async throws {
        try await Self.withModel { model, frames, fixture in
            let jobs = FlagStateTests.capture(model)
            model.askToDevelop([frames[0], frames[1]])
            #expect(model.quickDevelop != nil)
            model.showDevelopPage()
            #expect(model.quickDevelop == nil && model.workspacePage == .develop)
            model.closeDevelopPage()
            model.askToDevelop([frames[0], frames[1]])
            model.showWorkspacePage(.settings)
            #expect(model.quickDevelop == nil)
            model.showWorkspacePage(.roll)

            // A develop under way, or a frame that is not the roll's: no dialog to ask with.
            model.developPhase = .developing(DevelopProgress(total: 1))
            model.askToDevelop([frames[0]])
            #expect(model.quickDevelop == nil)
            model.developPhase = .idle
            let stranger = Frame(id: 99, url: fixture.folder.appendingPathComponent("Elsewhere/DSC9.ARW"), info: ARWFrameInfo())
            model.askToDevelop([stranger])
            model.askToDevelop([])
            #expect(model.quickDevelop == nil)

            // Develop's rule changed under the dialog: its button waits, and pressed does nothing.
            model.askToDevelop([frames[0], frames[1]])
            model.developPhase = .developing(DevelopProgress(total: 1))
            #expect(!model.canConfirmQuickDevelop)
            model.confirmQuickDevelop()
            #expect(model.quickDevelop != nil && model.developTask == nil && jobs.runs.isEmpty)
            model.developPhase = .idle
            #expect(model.canConfirmQuickDevelop)

            // Frames leaving the roll take the dialog with them: it may have been for them.
            model.dropFrames([frames[7].url])
            #expect(model.quickDevelop == nil && model.roll?.frames.count == frames.count - 1)
        }
    }
    #endif
}
