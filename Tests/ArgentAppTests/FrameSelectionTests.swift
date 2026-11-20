import AppKit
import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// Several frames selected on the sheet, and what acts on them (docs/M2-shell.md, section 25): a Command-click, a
/// Shift-click, a Shift-arrow and Select All build the selection round its lead; anything else that moves the lead leaves
/// it alone selected; Flag, their menu and the menu bar act on them all; Remove from Roll moves their raws to the Trash
/// and Move to Roll into another roll's folder, with their recipes and flags, and the roll on screen lets them go without
/// being read again.
@MainActor @Suite(.serialized) struct FrameSelectionTests {
    typealias Fixture = AutoDecisionStateTests.Fixture

    static func withModel(_ body: (RollModel, [Frame], Fixture) async throws -> Void) async throws {
        try await FrameMenuTests.withModel { model, frames, fixture in
            // No alert and no Trash of the user's: a test that asks for either gives its own first.
            model.askAboutRemovingFrames = { _ in
                Issue.record("asked about removing frames")
                return false
            }
            model.askForNewRollName = { _ in
                Issue.record("asked for a new roll's name")
                return nil
            }
            let trash = fixture.folder.appendingPathComponent("Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            model.trashFrames = { urls in
                FrameFiles.trash(urls) { file in
                    let target = trash.appendingPathComponent(file.lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: target)
                    return target
                }
            }
            try await body(model, frames, fixture)
            await model.frameMoveTask?.value
        }
    }

    static func selected(_ model: RollModel) -> [Int] { model.selected.sorted() }

    static func names(in folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    /// Another roll of the library, beside the fixture's, holding `names`.
    static func otherRoll(_ name: String, holding names: [String] = [], in fixture: Fixture, model: RollModel) throws -> (UUID, URL) {
        let folder = fixture.folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in names.enumerated() {
            try writeSequenceHeader(folder.appendingPathComponent(name), captured: AutoDecisionStateTests.captured(index), tail: Data(UUID().uuidString.utf8))
        }
        let entry = try #require(model.bookmarks.addRoll(folder, origin: .inPlace))
        model.library = model.bookmarks.rolls
        return (entry.id, folder)
    }

    // MARK: The selection

    @Test func clicksSelectAFrameAloneJoinItOrTakeARange() async throws {
        try await Self.withModel { model, frames, _ in
            #expect(Self.selected(model) == [0] && !model.hasSeveralSelected)
            model.select(frames[2])
            #expect(model.selection == 2 && Self.selected(model) == [2])

            // Shift: every frame shown from the frame last clicked without it.
            model.select(frames[5], .range)
            #expect(model.selection == 5 && Self.selected(model) == [2, 3, 4, 5])
            model.select(frames[1], .range)
            #expect(model.selection == 1 && Self.selected(model) == [1, 2], "the range starts where it did")
            #expect(model.selectedFrames.map(\.id) == [1, 2] && model.hasSeveralSelected)

            // Command: one more, and one fewer; the range then starts from the frame added.
            model.select(frames[6], .toggle)
            #expect(model.selection == 6 && Self.selected(model) == [1, 2, 6])
            model.select(frames[2], .toggle)
            #expect(model.selection == 6 && Self.selected(model) == [1, 6])
            // The lead taken away: the nearest frame still selected leads.
            model.select(frames[6], .toggle)
            #expect(model.selection == 1 && Self.selected(model) == [1])
            // One frame always stays selected.
            model.select(frames[1], .toggle)
            #expect(model.selection == 1 && Self.selected(model) == [1])

            // A plain click on one of several leaves it alone selected.
            model.select(frames[4], .range)
            model.select(frames[3])
            #expect(model.selection == 3 && Self.selected(model) == [3])
        }
    }

    @Test func shiftArrowsExtendFromWhereTheSelectionStartedAndSelectAllTakesEveryFrameShown() async throws {
        try await Self.withModel { model, frames, _ in
            model.select(frames[3])
            model.extendSelection(by: 2)
            #expect(model.selection == 5 && Self.selected(model) == [3, 4, 5])
            // Back past the start: the range turns round it.
            model.extendSelection(by: -4)
            #expect(model.selection == 1 && Self.selected(model) == [1, 2, 3])
            model.extendSelection(toLast: true)
            #expect(model.selection == 7 && Self.selected(model) == [3, 4, 5, 6, 7])
            model.extendSelection(toLast: false)
            #expect(model.selection == 0 && Self.selected(model) == [0, 1, 2, 3])

            // An arrow without Shift, Home and End: the frame reached, alone.
            model.moveSelection(by: 1)
            #expect(model.selection == 1 && Self.selected(model) == [1])
            model.selectAllShown()
            #expect(model.selection == 1 && Self.selected(model) == Array(0..<8) && model.canSelectAll)
            #expect(model.shownCountText == "8 frames · 8 selected")
            model.collapseSelection()
            #expect(model.selection == 1 && Self.selected(model) == [1] && model.shownCountText == "8 frames")

            // The frame view shows one frame: it opens with that frame alone, and selects no more.
            model.selectAllShown()
            model.openFrame()
            #expect(model.isFrameOpen && Self.selected(model) == [1] && !model.canSelectAll)
            model.select(frames[4], .toggle)
            #expect(model.selection == 4 && Self.selected(model) == [4], "a click in the frame view is a plain one")
            model.selectAllShown()
            #expect(Self.selected(model) == [4])
        }
    }

    @Test func onlyFramesTheSheetShowsStaySelected() async throws {
        try await Self.withModel { model, frames, _ in
            FlagStateTests.flag(model, [1, 3, 6])
            model.select(frames[3])
            model.selectAllShown()
            // The filter leaves five out: the lead and the flagged frames beside it stay.
            model.showFrames(.flagged)
            #expect(model.selection == 3 && Self.selected(model) == [1, 3, 6])
            // A range runs over the frames shown only.
            model.select(frames[1])
            model.select(frames[6], .range)
            #expect(Self.selected(model) == [1, 3, 6])
            // The lead left out: the selection moves to a frame shown, alone.
            model.showFrames(.unflagged)
            #expect(model.selection == 7 && Self.selected(model) == [7])
            model.selectAllShown()
            #expect(Self.selected(model) == [0, 2, 4, 5, 7] && model.shownCountText == "Unflagged · 5 of 8 frames · 5 selected")
        }
    }

    // MARK: What acts on them

    @Test func flagActsOnEveryFrameSelectedAsOneStep() async throws {
        try await Self.withModel { model, frames, fixture in
            FlagStateTests.flag(model, [2])
            let undo = UndoManager()
            undo.groupsByEvent = false
            model.manualUndoManager = undo
            @MainActor func press(_ body: () -> Void) {
                undo.beginUndoGrouping()
                body()
                undo.endUndoGrouping()
            }
            model.select(frames[1])
            model.select(frames[3], .range)
            // Not every one is flagged: Flag flags the rest.
            #expect(model.menuState.isSeveralSelected && model.menuState.canFlag && !model.menuState.isFlagged)
            press { model.flagSelection(nil) }
            #expect([1, 2, 3].allSatisfy { model.isFlagged(frames[$0]) } && model.flaggedCount == 3)
            #expect(undo.undoActionName == "Flag 2 Frames" && model.menuState.isFlagged)
            #expect(Self.selected(model) == [1, 2, 3], "the frames stay selected")
            // Undo: the two it flagged, together.
            undo.undo()
            #expect(model.isFlagged(frames[2]) && model.flaggedCount == 1 && undo.redoActionName == "Flag 2 Frames")
            undo.redo()
            #expect(model.flaggedCount == 3)
            // Every one flagged: Unflag takes them all.
            press { model.flagSelection(nil) }
            #expect(model.flaggedCount == 0 && undo.undoActionName == "Unflag 3 Frames")
            await model.flagSave?.value
            #expect(model.flagStore.record(for: fixture.roll)?.frames.isEmpty == true)

            // A frame whose raw has gone cannot be flagged, and does not keep the others from being unflagged together.
            try FileManager.default.removeItem(at: frames[2].url)
            model.forgetChangedSources()
            #expect(!model.canFlag(frames[2]) && !model.areAllFlagged([frames[2]]))
            press { model.flagSelection(nil) }
            #expect(model.flaggedCount == 2 && model.areAllFlagged(model.selectedFrames) && model.menuState.isFlagged)
            #expect(FrameMenu.flag(for: model.selectedFrames, model: model).title == "Unflag 3 Frames")
            press { model.flagSelection(nil) }
            #expect(model.flaggedCount == 0, "the second press unflags them")

            // Under a filter the frames leave the sheet together, and the selection moves on alone.
            press { model.flagSelection(nil) }
            model.showFrames(.flagged)
            model.selectAllShown()
            #expect(Self.selected(model) == [1, 3])
            press { model.flagSelection(nil) }
            #expect(model.flaggedCount == 0 && model.shownFrames.isEmpty && model.selection == nil && model.selected.isEmpty)
        }
    }

    @Test func theMenuOfSeveralFramesIsForThemAll() async throws {
        try await Self.withModel { model, frames, _ in
            model.select(frames[1])
            model.select(frames[3], .range)
            // A menu opened on one of them is theirs; on another frame, that frame's.
            #expect(model.framesActedOn(from: frames[2]).map(\.id) == [1, 2, 3])
            #expect(model.framesActedOn(from: frames[5]).map(\.id) == [5])
            let menu = FrameMenu.entries(for: model.framesActedOn(from: frames[2]), on: .sheet, model: model)
            #expect(menu.titles == ["Flag 3 Frames", "—", "Paste Adjustments to 3 Frames", "Paste Only", "—",
                                    "Develop 3 Frames…", "Show RAWs in Finder", "Show Developed Files in Finder", "—",
                                    "Move to Roll", "Remove from Roll…"])
            #expect(menu.entry("frames.move")?.children.titles == ["New Roll…"])
            #expect(FrameMenu.entries(for: [frames[5]], on: .sheet, model: model).titles == FrameMenuTests.sheetRows + FrameMenuTests.rollRows)
            let states = FrameMenuTests.enabled(menu)
            #expect(states["frames.flag"] == true && states["frames.paste"] == false && states["frames.develop"] == true)
            #expect(states["frames.showDeveloped"] == false && states["frames.move"] == true && states["frames.remove"] == true)

            // Flag: all three, and the row then unflags them.
            menu.entry("frames.flag")?.choose()
            #expect([1, 2, 3].allSatisfy { model.isFlagged(frames[$0]) })
            #expect(FrameMenu.entries(for: model.selectedFrames, on: .sheet, model: model).entry("frames.flag")?.title == "Unflag 3 Frames")

            // Paste: on the frames selected but the one copied from, as one step.
            model.manualEdits[frames[2].url] = FrameMenuTests.edit(try ManualAdjustments(exposureEV: 0.5))
            model.copyAdjustments(from: frames[2])
            model.noteSelectionFlag()
            #expect(model.canPasteAdjustments(to: model.selectedFrames) && model.menuState.canPasteAdjustments)
            let shown = [frames[1], frames[2], frames[3]]
            FrameMenu.entries(for: shown, on: .sheet, model: model).entry("frames.paste")?.choose()
            let report = await model.pasteTask?.value
            #expect(report?.asked == 2, "the frame copied from is left out")

            // The files: the raws of them all in Finder.
            var revealed: [[URL]] = []
            let reveal = FinderReveal.show
            FinderReveal.show = { revealed.append($0) }
            defer { FinderReveal.show = reveal }
            FrameMenu.entries(for: shown, on: .sheet, model: model).entry("frames.showRAW")?.choose()
            model.showSelectionInFinder()
            #expect(revealed == [shown.map(\.url), shown.map(\.url)])
        }
    }

    @Test func aRightClickOnOneOfSeveralKeepsThemAndOnAnotherFrameSelectsIt() async throws {
        try await Self.withModel { model, frames, _ in
            let (window, host, collection) = try FrameMenuTests.sheet(model, size: NSSize(width: 700, height: 900))
            defer { window.close() }
            let shown = ContextMenuTests.ShownMenus()
            defer { shown.stop() }
            model.select(frames[1])
            model.select(frames[3], .range)
            ContextMenuTests.settle(host)

            try ContextMenuTests.click(.rightMouseDown, at: FrameMenuTests.point(ofCell: 2, in: collection), in: window)
            #expect(Self.selected(model) == [1, 2, 3] && shown.rows.last?.first == "Flag 3 Frames F")
            // Another frame: it alone, and its own menu.
            try ContextMenuTests.click(.rightMouseDown, at: FrameMenuTests.point(ofCell: 5, in: collection), in: window)
            #expect(Self.selected(model) == [5] && shown.rows.last?.first == "Open Frame ⌘\u{F701}")

            // A Control-click on one of several is their menu too.
            model.select(frames[6], .range)
            try ContextMenuTests.click(.leftMouseDown, at: FrameMenuTests.point(ofCell: 6, in: collection), flags: .control, in: window)
            #expect(Self.selected(model) == [5, 6] && shown.rows.last?.first == "Flag 2 Frames F")
        }
    }

    @Test func developOfTheFramesSelectedDevelopsThemAlone() async throws {
        try await Self.withModel { model, frames, fixture in
            model.chooseDestination(fixture.folder.appendingPathComponent("Developed"))
            let jobs = FlagStateTests.capture(model)
            model.select(frames[2])
            model.select(frames[4], .range)
            #expect(model.menuState.canDevelopFrame && model.menuState.isSeveralSelected)
            // On the roll it asks where and as what first; the dialog's Develop then develops them.
            model.developSelection()
            #expect(model.quickDevelop?.frames == [frames[2].url, frames[3].url, frames[4].url] && model.developTask == nil)
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }
            #expect(jobs.last == [frames[2].url, frames[3].url, frames[4].url] && jobs.totals == [3])
            // The other frames shown are not developed: the button stays Develop.
            #expect(model.developPhase == .idle)
        }
    }

    // MARK: Remove from Roll

    @Test func removeFromRollAsksThenMovesTheFramesToTheTrashAndTheRollLetsThemGo() async throws {
        try await Self.withModel { model, frames, fixture in
            let decision = try #require(await model.settledDecision())
            let aims = AutoDecisionStateTests.bits(model.printAims, frames)
            FlagStateTests.flag(model, [1, 3])
            try Data("recipe".utf8).write(to: RecipeStore.besideRaw(frames[3].url))
            model.setRatedAt(.oneStopUnder, for: frames[4])
            model.select(frames[2])
            model.select(frames[4], .range)
            #expect(model.menuState.canChangeFrames && model.canChangeFrames(model.selectedFrames))

            // Cancel: nothing moves.
            var asked: [FrameRemoval] = []
            model.askAboutRemovingFrames = { asked.append($0); return false }
            model.removeFromRoll(model.selectedFrames)
            #expect(asked == [FrameRemoval(count: 3, name: nil, roll: "Roll")] && model.frameMoveTask == nil)
            #expect(asked[0].title == "Move 3 frames to the Trash?" && model.roll?.frames.count == 8)

            // Move to Trash: the raws go with their recipes, and the roll keeps the rest in order, numbered again.
            model.askAboutRemovingFrames = { asked.append($0); return true }
            model.removeFromRoll(model.selectedFrames)
            #expect(model.frameMove != nil && !model.canChangeFrames([frames[0]]) && !model.canStartDevelop)
            // While they go nothing else changes a frame: none opens, and no flag or paste is taken.
            #expect(!model.canOpenFrame && !model.canChangeFlags && !model.canFlag(frames[0]))
            model.openFrame()
            model.setFlag(true, for: frames[0])
            model.setFlag(true, for: [frames[5], frames[6]])
            #expect(!model.isFrameOpen && model.flaggedCount == 2)
            model.manualEdits[frames[0].url] = FrameMenuTests.edit(try ManualAdjustments(exposureEV: 0.5))
            #expect(!model.canResetManual(frames[0]))
            model.adjustmentsClipboard = model.clipboard(of: frames[0])
            #expect(!model.canPasteAdjustments(to: frames[1]) && !model.canPasteToShownFrames)
            #expect(model.paste(model.clipboard(of: frames[0]), parts: .all, to: [frames[1]], batch: false) == nil)
            model.manualEdits[frames[0].url] = nil
            model.adjustmentsClipboard = nil
            await model.frameMoveTask?.value
            #expect(model.canChangeFlags && model.canOpenFrame && model.movingFrames.isEmpty)
            let left = try #require(model.roll?.frames)
            #expect(left.map(\.name) == ["DSC01", "DSC02", "DSC06", "DSC07", "DSC08"] && left.map(\.id) == Array(0..<5))
            // DSC05's own Rated at was saved in its recipe beside it, which goes with it.
            #expect(Self.names(in: fixture.folder.appendingPathComponent("Trash"))
                    == ["DSC03.ARW", "DSC04.ARW", "DSC04.argent", "DSC05.ARW", "DSC05.argent"])
            #expect(!Self.names(in: fixture.roll).contains { $0.hasPrefix("DSC03") || $0.hasPrefix("DSC04") || $0.hasPrefix("DSC05") })
            // The frame after them is selected, alone.
            #expect(model.selectedFrame?.name == "DSC06" && Self.selected(model) == [2] && model.frameMove == nil)
            #expect(model.clipboardNotice?.text == "3 frames moved to the Trash" && model.clipboardNotice?.kind == .done(symbol: "trash"))
            // Their flag and their own settings went with them; the others' stay, and are saved.
            #expect(model.flaggedCount == 1 && model.isFlagged(left[1]) && model.overrides.isEmpty)
            await model.flagSave?.value
            #expect(model.flagStore.record(for: fixture.roll)?.frames.map(\.fileName) == ["DSC02.ARW"])
            // The roll's decision stands for the frames left: the same revision, the same prints.
            #expect(model.isBalanced && model.autoDecision?.revision == decision.revision)
            #expect(AutoDecisionStateTests.bits(model.printAims, left) == [aims[0], aims[1], aims[5], aims[6], aims[7]])
            #expect(model.printAims.count == 5)
            // The library counts the roll again.
            #expect(model.openLibraryRoll?.frameCount == 5)

            // One frame, by its name; the last frame shown gives the selection to the one before.
            model.select(left[4])
            model.removeFromRoll(model.selectedFrames)
            await model.frameMoveTask?.value
            #expect(asked.last?.title == "Move DSC08 to the Trash?" && model.clipboardNotice?.text == "DSC08 moved to the Trash")
            #expect(model.roll?.frames.count == 4 && model.selectedFrame?.name == "DSC07")
        }
    }

    @Test func aFrameTheTrashRefusesStaysInTheRoll() async throws {
        try await Self.withModel { model, frames, fixture in
            struct Refused: LocalizedError { var errorDescription: String? { "The volume has no Trash" } }
            let stays = frames[2].url
            model.trashFrames = { urls in
                FrameFiles.trash(urls) { file in
                    if file == stays { throw Refused() }
                    let target = fixture.folder.appendingPathComponent("Trash").appendingPathComponent(file.lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: target)
                    return target
                }
            }
            model.askAboutRemovingFrames = { _ in true }
            // The frame that stays leads the three.
            model.select(frames[1])
            model.select(frames[3], .range)
            model.select(frames[2], .toggle)
            model.select(frames[2], .toggle)
            #expect(model.selection == 2 && Self.selected(model) == [1, 2, 3])
            model.removeFromRoll(model.selectedFrames)
            await model.frameMoveTask?.value
            #expect(model.roll?.frames.map(\.name) == ["DSC01", "DSC03", "DSC05", "DSC06", "DSC07", "DSC08"])
            // It is still the lead, alone: the selection does not go on to the frame after it.
            #expect(model.selectedFrame?.name == "DSC03" && Self.selected(model) == [1])
            #expect(model.clipboardNotice?.text == "2 frames moved to the Trash · 1 stayed")
            #expect(model.clipboardNotice?.details == ["DSC03: The volume has no Trash"])
            #expect(model.clipboardNotice?.detailsTitle == "1 frame left as it was")
            #expect(model.clipboardNotice?.detailsHelp == "The frames left out, and why")
            #expect(FileManager.default.fileExists(atPath: stays.path))
        }
    }

    @Test(arguments: [(1, 1, false), (2, 1, false), (2, 2, false), (8, 1, false), (2, 1, true)])
    func aPartialTrashDropsTheRawAndShowsTheCompanionFailure(count: Int, stranded: Int, masks: Bool) async throws {
        try await Self.withModel { model, frames, fixture in
            struct Refused: LocalizedError { var errorDescription: String? { "Companion is locked" } }
            let recipes = frames.prefix(stranded).flatMap {
                [RecipeStore.besideRaw($0.url)] + (masks ? [RecipeStore.masksBesideRaw($0.url)] : [])
            }
            for recipe in recipes { try Data("recipe".utf8).write(to: recipe) }
            model.trashFrames = { urls in
                FrameFiles.trash(urls) { file in
                    if recipes.contains(file) { throw Refused() }
                    let target = fixture.folder.appendingPathComponent("Trash").appendingPathComponent(file.lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: target)
                    return target
                }
            }
            model.askAboutRemovingFrames = { _ in true }
            model.showWorkspacePage(.roll)
            model.removeFromRoll(Array(frames.prefix(count)))
            await model.frameMoveTask?.value
            #expect(model.roll?.frames.map(\.name) == Array(frames.dropFirst(count)).map(\.name))
            let line = count == 1 ? "DSC01" : "\(count) frames"
            let warning = count == 1 ? "companions stayed behind" : "\(stranded) with companions left behind"
            #expect(model.clipboardNotice?.text == "\(line) moved to the Trash · \(warning)")
            #expect(model.clipboardNotice?.detailsTitle == "Companions left behind")
            #expect(model.clipboardNotice?.detailsHelp == "The files left behind, and why")
            #expect(model.clipboardNotice?.kind == .done(symbol: "exclamationmark.triangle"))
            let notice = try #require(model.clipboardNotice)
            let folder = DevelopStatusText.abbreviated(frames[0].url.deletingLastPathComponent())
            #expect(notice.details.isEmpty)
            #expect(notice.detailEntries == recipes.map {
                ClipboardNotice.Detail(title: $0.lastPathComponent,
                                       secondaryLines: ["Still in \(folder)", "Companion is locked"])
            })
            #expect(notice.actions == [.details, .close])
            #expect(notice.plainDetails == recipes.map {
                "\($0.lastPathComponent) — Still in \(folder) — Companion is locked"
            })
            #expect(recipes.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            #expect(model.workspacePage == .roll)
        }
    }

    @Test func aRollThatMayNotChangeAndADevelopKeepEveryFrame() async throws {
        try await Self.withModel { model, frames, fixture in
            model.askAboutRemovingFrames = { _ in true }
            // A card opened where it is: Argent never changes it.
            let folder = try #require(model.roll?.folder)
            model.changeableRoll = (folder, false, folder.canonicalPath)
            model.noteSelectionFlag()
            #expect(!model.canChangeFrames([frames[0]]) && !model.menuState.canChangeFrames)
            #expect(model.changeFramesHelp == "Argent never changes a card: import its frames into a roll first")
            let menu = FrameMenuTests.enabled(FrameMenu.entries(for: frames[0], on: .sheet, model: model))
            #expect(menu["frames.move"] == false && menu["frames.remove"] == false)
            model.removeFromRoll([frames[0]])
            #expect(model.frameMoveTask == nil && model.roll?.frames.count == 8)
            model.changeableRoll = nil
            #expect(model.canChangeFrames([frames[0]]) && model.rollAllowsChangingFrames)

            // The frame view shows one frame, which stays; so does every frame while the roll opens.
            model.openFrame()
            #expect(!model.canChangeFrames([frames[0]]))
            model.closeFrame()
            #expect(model.canChangeFrames([frames[0]]))
            #expect(!model.canChangeFrames([]))
            _ = fixture
        }
    }

    @Test func theLastFramesLeaveAnEmptyRollOnTheRollsPage() async throws {
        try await Self.withModel { model, _, fixture in
            model.askAboutRemovingFrames = { _ in true }
            model.selectAllShown()
            model.removeFromRoll(model.selectedFrames)
            await model.frameMoveTask?.value
            #expect(model.roll?.frames.isEmpty == true && model.selection == nil && model.selected.isEmpty)
            #expect(model.workspacePage == .rolls && model.openLibraryRoll?.frameCount == 0)
            #expect(Self.names(in: fixture.roll).filter { $0.hasSuffix(".ARW") }.isEmpty)
            // Nothing is left to act on.
            #expect(!model.canSelectAll && !model.canDevelop && !model.menuState.canChangeFrames && !model.canOpenFrame)
            model.openFrame()
            #expect(!model.isFrameOpen)
        }
    }

    /// Command-Delete is a text field's own key. The menu bar takes it first, so Remove from Roll… gives it to a field
    /// that has the keys, and no frame is asked about.
    @Test func commandDeleteInATextFieldIsTheFieldsAndRemovesNoFrame() async throws {
        try await Self.withModel { model, frames, _ in
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            text.string = "2026-10-21"
            text.setSelectedRange(NSRange(location: 10, length: 0))
            #expect(FrameKeys.givesRemoveToText(text) && text.string.isEmpty)
            #expect(!FrameKeys.givesRemoveToText(nil) && !FrameKeys.givesRemoveToText(NSView()))
            text.isEditable = false
            #expect(!FrameKeys.givesRemoveToText(text))

            // Chosen from the menu, or by its key with no field in the way, it asks about the frames selected.
            var asked = 0
            model.askAboutRemovingFrames = { _ in asked += 1; return false }
            model.select(frames[1])
            model.removeSelection(nil)
            #expect(asked == 1 && model.roll?.frames.count == 8)
        }
    }

    // MARK: Move to Roll

    @Test func moveToRollTakesTheFramesWithTheirRecipesAndFlags() async throws {
        try await Self.withModel { model, frames, fixture in
            // Another roll, which already holds a frame under DSC04's name and a flag of its own.
            let (id, other) = try Self.otherRoll("Other", holding: ["DSC04.ARW", "DSC09.ARW"], in: fixture, model: model)
            let theirs = FlagRecord.Entry(fileName: "DSC09.ARW", byteCount: 1, captureDate: nil)
            #expect(try model.flagStore.save(FlagRecord(frames: [theirs]), for: other))
            #expect(model.moveTargets == [MoveTarget(id: id, name: "Other")])
            #expect(model.menuState.moveTargets == [MoveTarget(id: id, name: "Other")])

            FlagStateTests.flag(model, [1, 2])
            try Data("recipe".utf8).write(to: RecipeStore.besideRaw(frames[2].url))
            try Data("masks".utf8).write(to: RecipeStore.masksBesideRaw(frames[2].url))
            model.select(frames[2])
            model.select(frames[4], .range)
            let menu = FrameMenu.entries(for: model.selectedFrames, on: .sheet, model: model)
            #expect(menu.entry("frames.move")?.children.titles == ["Other", "—", "New Roll…"])
            menu.entry("frames.move.\(id.uuidString)")?.choose()
            #expect(model.clipboardNotice?.kind == .working && model.clipboardNotice?.text == "Moving 3 frames to Other…")
            await model.frameMoveTask?.value

            // DSC03 and DSC05 went, DSC03 with its recipe and masks; DSC04 stays, as Other holds one of its name.
            #expect(Self.names(in: other) == ["DSC03.ARW", "DSC03.argent", "DSC03.argentmasks", "DSC04.ARW", "DSC05.ARW", "DSC09.ARW"])
            #expect(model.roll?.frames.map(\.name) == ["DSC01", "DSC02", "DSC04", "DSC06", "DSC07", "DSC08"])
            #expect(model.clipboardNotice?.text == "2 frames moved to Other · 1 stayed")
            #expect(model.clipboardNotice?.details == ["DSC04: Other already holds a file of its name"])
            #expect(model.selectedFrame?.name == "DSC06")
            // DSC03's flag is Other's now, beside the one it had; this roll keeps DSC02's.
            #expect(model.flagStore.record(for: other)?.frames.map(\.fileName) == ["DSC03.ARW", "DSC09.ARW"])
            await model.flagSave?.value
            #expect(model.flagStore.record(for: fixture.roll)?.frames.map(\.fileName) == ["DSC02.ARW"])
            #expect(model.openLibraryRoll?.frameCount == 6)

            // The frame arrives as a frame of that roll, flagged there.
            await model.open(other)
            if let restoration = model.manualRestoreTask { await restoration.value }
            let arrived = try #require(model.roll?.frames)
            #expect(arrived.map(\.name).sorted() == ["DSC03", "DSC04", "DSC05", "DSC09"])
            #expect(arrived.filter(model.isFlagged).map(\.name) == ["DSC03"])
        }
    }

    static let flagsLeft = "Other’s flags file is not one this version of Argent can read, and was left as it is"

    enum DestinationFlags: CaseIterable { case future, unreadable, unwritable }

    /// The raws move all the same when the roll they go to cannot take their flags: a flags file this build cannot
    /// read is left as it is, and the notice says which frames arrived unflagged, and why.
    @Test(arguments: DestinationFlags.allCases)
    func moveToRollSaysWhenTheFlagsCouldNotGoWithTheFrames(destination: DestinationFlags) async throws {
        try await Self.withModel { model, frames, fixture in
            let (id, other) = try Self.otherRoll("Other", holding: ["DSC05.ARW", "DSC09.ARW"], in: fixture, model: model)
            let file = model.flagStore.file(for: other), library = model.flagStore.folder
            FlagStateTests.flag(model, [2, 3, 4])
            await model.flagSave?.value
            var kept: Data?
            switch destination {
            case .future:
                kept = Data(#"{"format":"camera.argent.flags","version":2,"frames":[]}"#.utf8)
                try kept?.write(to: file)
            case .unreadable:
                #expect(try model.flagStore.save(FlagRecord(frames: [.init(fileName: "DSC09.ARW", byteCount: 1, captureDate: nil)]), for: other))
                kept = try Data(contentsOf: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            case .unwritable:
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: library.path)
            }
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }

            // An unflagged frame has no flag to carry: its move is as any other.
            model.moveFrames([frames[1]], toRoll: id)
            await model.frameMoveTask?.value
            #expect(model.clipboardNotice?.text == "DSC02 moved to Other")
            #expect(model.clipboardNotice?.kind == .done(symbol: "folder"))

            // DSC03 and DSC04 go, unflagged there; DSC05 stays, as Other holds one of its name, and keeps its flag here.
            model.moveFrames([frames[2], frames[3], frames[4]], toRoll: id)
            await model.frameMoveTask?.value
            #expect(Self.names(in: other).filter { $0.hasSuffix(".ARW") } == ["DSC02.ARW", "DSC03.ARW", "DSC04.ARW", "DSC05.ARW", "DSC09.ARW"])
            #expect(model.roll?.frames.map(\.name) == ["DSC01", "DSC05", "DSC06", "DSC07", "DSC08"])
            let notice = try #require(model.clipboardNotice)
            #expect(notice.text == "2 frames moved to Other · 1 stayed · 2 flags not carried")
            #expect(notice.kind == .done(symbol: "exclamationmark.triangle"))
            #expect(notice.details == ["DSC05: Other already holds a file of its name"])
            #expect(notice.detailEntries.map(\.title) == ["DSC03", "DSC04"])
            #expect(notice.detailEntries.allSatisfy { $0.secondaryLines.count == 2 && $0.secondaryLines[0] == "Arrived unflagged in Other" })
            let why = notice.detailEntries.first?.secondaryLines.last
            if destination == .unwritable {
                #expect(why?.isEmpty == false && why != Self.flagsLeft)
            } else {
                #expect(why == Self.flagsLeft)
            }
            #expect(notice.detailsTitle == "Frames left behind, flags not carried")
            #expect(notice.detailsHelp == "What was left behind or not carried, and why")
            #expect(notice.actions == [.details, .close])

            // The flags file Other has is as it was.
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect((try? Data(contentsOf: file)) == kept)
        }
    }

    @Test func aSingleFrameWhoseFlagCouldNotGoSaysSo() async throws {
        try await Self.withModel { model, frames, fixture in
            let (id, other) = try Self.otherRoll("Other", in: fixture, model: model)
            FlagStateTests.flag(model, [2])
            await model.flagSave?.value
            try Data(#"{"format":"camera.argent.flags","version":2,"frames":[]}"#.utf8).write(to: model.flagStore.file(for: other))
            model.moveFrames([frames[2]], toRoll: id)
            await model.frameMoveTask?.value
            let notice = try #require(model.clipboardNotice)
            #expect(notice.text == "DSC03 moved to Other · flag not carried")
            #expect(notice.detailEntries == [ClipboardNotice.Detail(title: "DSC03", secondaryLines: ["Arrived unflagged in Other", Self.flagsLeft])])
            #expect(notice.detailsTitle == "Flags not carried")
            #expect(notice.detailsHelp == "The flags not carried, and why")
            #expect(notice.dismissalDelay == .seconds(6))
        }
    }

    @Test func moveToANewRollMakesItsFolderWhereImportMakesRolls() async throws {
        try await Self.withModel { model, frames, fixture in
            let saved = model.importSettings
            defer { model.importSettings = saved }
            let parent = fixture.folder.appendingPathComponent("Rolls")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            model.importSettings.destination = .folder(parent)

            // The name asked for, the frames' first day in its field; Cancel moves nothing.
            var suggested: [String] = []
            model.askForNewRollName = { suggested.append($0); return nil }
            model.select(frames[5])
            model.select(frames[6], .toggle)
            model.moveFramesToNewRoll(model.selectedFrames)
            #expect(suggested == ["2026-10-21"] && model.frameMoveTask == nil && model.roll?.frames.count == 8)

            model.askForNewRollName = { _ in " Tokyo: night/2 " }
            model.moveFramesToNewRoll(model.selectedFrames)
            await model.frameMoveTask?.value
            let folder = parent.appendingPathComponent("Tokyo- night-2")
            #expect(Self.names(in: folder) == ["DSC06.ARW", "DSC07.ARW"])
            #expect(model.roll?.frames.count == 6 && model.clipboardNotice?.text == "2 frames moved to Tokyo- night-2")
            // It is a roll of the library, to move more into.
            let entry = try #require(model.bookmarks.roll(atPath: folder.path))
            #expect(entry.name == "Tokyo- night-2" && entry.origin == .imported && entry.source == "Roll")
            #expect(model.moveTargets.map(\.name) == ["Tokyo- night-2"])

            // A folder already there is never joined by its name alone.
            model.askForNewRollName = { _ in "Tokyo- night-2" }
            model.moveFramesToNewRoll([model.roll!.frames[0]])
            #expect(model.frameMoveTask == nil && model.roll?.frames.count == 6)
            #expect(model.message?.contains("is already there") == true)

            // Nor one that the first look could not see, as a chosen folder's is before its access is held: the folder
            // is made only if it is not there, so one that is there is neither joined nor removed with what it holds.
            let first = try #require(model.roll?.frames[0])
            let unseen = parent.appendingPathComponent("Osaka")
            model.moveFrames([first], toNewRollNamed: "Osaka")
            try FileManager.default.createDirectory(at: unseen, withIntermediateDirectories: true)
            try Data("theirs".utf8).write(to: unseen.appendingPathComponent("DSC09.ARW"))
            await model.frameMoveTask?.value
            #expect(Self.names(in: unseen) == ["DSC09.ARW"] && model.roll?.frames.count == 6)
            #expect(FileManager.default.fileExists(atPath: first.url.path) && model.bookmarks.roll(atPath: unseen.path) == nil)
            #expect(model.clipboardNotice?.kind == .failed && model.clipboardNotice?.text.contains("is already there") == true)
            // The same with every name taken there: nothing moves, and the folder stays.
            try Data("theirs".utf8).write(to: unseen.appendingPathComponent(first.url.lastPathComponent))
            model.moveFrames([first], toNewRollNamed: "Kobe")
            try FileManager.default.moveItem(at: unseen, to: parent.appendingPathComponent("Kobe"))
            await model.frameMoveTask?.value
            #expect(Self.names(in: parent.appendingPathComponent("Kobe")) == ["DSC01.ARW", "DSC09.ARW"])
            #expect(try String(contentsOf: parent.appendingPathComponent("Kobe/DSC01.ARW"), encoding: .utf8) == "theirs")
            #expect(model.roll?.frames.count == 6)
        }
    }
}
