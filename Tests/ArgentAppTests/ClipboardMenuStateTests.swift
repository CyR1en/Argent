import AppKit
import ArgentCore
@testable import ArgentRoll
import Foundation
import Observation
import SwiftUI
import Testing
@testable import ArgentApp

/// What the menu bar shows of Copy and Paste Adjustments and of a frame's files (`MenuState`, docs/context-menus-plan.md,
/// section 4), read from the model: they follow the frame open in the frame view or selected on the sheet, the clipboard and
/// the filter; and an arrow press on the sheet between two frames alike in them leaves the menus as they are, since they come
/// from `SelectionFlag` and not from the selection.
@MainActor @Suite(.serialized) struct ClipboardMenuStateTests {
    typealias Fixture = AutoDecisionStateTests.Fixture

    /// Counts the changes to what `read` reads, once each time `observe` is called, as the App's body would see them. The
    /// change is told on the main actor, where the model is written.
    final class Changes: @unchecked Sendable {
        var count = 0

        @MainActor func observe(_ read: @escaping @MainActor () -> Void) {
            withObservationTracking { read() } onChange: { [weak self] in self?.count += 1 }
        }
    }

    /// The model's followers have run: the selection's facts (`followSelectionFlag`) and then the menus (`followMenuState`),
    /// each a turn after what it reads changes.
    static func settle(_ model: RollModel) async {
        for _ in 0..<40 { await Task.yield() }
        for _ in 0..<200 where model.menus != model.menuState { await Task.yield() }
    }

    /// The Auto suite's roll of eight frames, open in a model of its own; `edited` frames have their own Lab balance, which is
    /// what Copy Adjustments takes from a frame with no Light, Curve or mask.
    static func withRoll(edited: [Int] = [], _ body: (RollModel, [Frame]) async throws -> Void) async throws {
        try await FlagStateTests.withRoll { fixture in
            let model = FlagStateTests.model(fixture), gate = MeasurementGate()
            let frames = try await FlagStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            for index in edited { model.setLabBalance(.warm, for: frames[index]) }
            await settle(model)
            try await body(model, frames)
        }
    }

    /// Copy Adjustments follows the sheet's selected frame, and an arrow press between two frames alike in what the menus need
    /// of them changes neither `menuState` nor `menus`; between a frame with an edit and one without, it changes once.
    @Test func copyFollowsTheSelectedFrameAndAnArrowPressBetweenFramesAlikeLeavesTheMenusAlone() async throws {
        try await Self.withRoll(edited: [2, 3]) { model, frames in
            #expect(model.selection == 0 && !model.menus.canCopyAdjustments && model.menus.canShowRAW)
            let state = Changes(), menus = Changes()
            state.observe { _ = model.menuState }
            menus.observe { _ = model.menus }
            // 0 to 1: neither has an edit.
            model.moveSelection(by: 1)
            await Self.settle(model)
            #expect(state.count == 0 && menus.count == 0)
            #expect(!model.menus.canCopyAdjustments)
            // 1 to 2: into a frame with an edit.
            model.moveSelection(by: 1)
            await Self.settle(model)
            #expect(state.count == 1 && menus.count == 1)
            #expect(model.menus.canCopyAdjustments && model.canCopyAdjustments(from: frames[2]))
            state.observe { _ = model.menuState }
            menus.observe { _ = model.menus }
            // 2 to 3: both have one.
            model.moveSelection(by: 1)
            await Self.settle(model)
            #expect(state.count == 1 && menus.count == 1)
            #expect(model.menus.canCopyAdjustments)
            // 3 to 4: out of them again.
            model.moveSelection(by: 1)
            await Self.settle(model)
            #expect(state.count == 2 && menus.count == 2)
            #expect(!model.menus.canCopyAdjustments)
            state.observe { _ = model.menuState }
            menus.observe { _ = model.menus }
            // End, Home and back: 7 and 0 have none, as 4 has none.
            model.moveSelection(toLast: true)
            model.moveSelection(toLast: false)
            await Self.settle(model)
            #expect(state.count == 2 && menus.count == 2)
            #expect(model.menus == model.menuState)
        }
    }

    /// The frame's edit is written in many places the selection's `didSet` never sees, a cell's Reset or a paste among them:
    /// the menus follow it a turn later all the same, and whatever else Copy asks, such as a quit under way.
    @Test func copyFollowsAnEditWrittenUnderTheSelection() async throws {
        try await Self.withRoll { model, frames in
            #expect(model.selection == 0 && !model.menus.canCopyAdjustments)
            model.setLabBalance(.warm, for: frames[0])
            await Self.settle(model)
            #expect(model.menus.canCopyAdjustments)
            model.isQuitting = true
            await Self.settle(model)
            #expect(!model.menus.canCopyAdjustments)
            model.isQuitting = false
            await Self.settle(model)
            #expect(model.menus.canCopyAdjustments)
            model.clearOverrides(for: frames[0])
            await Self.settle(model)
            #expect(!model.menus.canCopyAdjustments)
            // An edit of another frame changes nothing the menus show of this one.
            let menus = Changes()
            menus.observe { _ = model.menus }
            model.setLabBalance(.cool, for: frames[5])
            await Self.settle(model)
            #expect(menus.count == 0 && !model.menus.canCopyAdjustments)
        }
    }

    /// In the frame view the items act on the open frame, and follow it as the arrows move it.
    @Test func inTheFrameViewTheyFollowTheOpenFrame() async throws {
        try await Self.withRoll(edited: [1]) { model, frames in
            model.selection = 1
            model.openFrame()
            await Self.settle(model)
            #expect(model.menus.openFrame == frames[1] && model.menus.canCopyAdjustments && model.menus.canShowRAW)
            model.moveSelection(by: 1)
            await Self.settle(model)
            #expect(model.menus.openFrame == frames[2] && !model.menus.canCopyAdjustments)
            model.moveSelection(by: -1)
            model.closeFrame()
            await Self.settle(model)
            #expect(model.menus.openFrame == nil && model.selection == 1 && model.menus.canCopyAdjustments)
        }
    }

    /// Paste Adjustments and Paste Only follow what was copied; the batch paste follows the frames shown, and its title the filter.
    @Test func pasteFollowsTheClipboardAndTheBatchItsTitleAndTheFramesShown() async throws {
        try await Self.withRoll(edited: [1]) { model, frames in
            #expect(!model.menus.canPasteAdjustments && model.menus.pasteOnlyParts.isEmpty && !model.menus.canPasteToShown)
            #expect(model.menus.pasteToShownTitle == "Paste to All Frames")
            model.copyAdjustments(from: frames[1])
            await Self.settle(model)
            // The source held only its own Lab balance, so Paste Only offers that part alone.
            #expect(model.menus.canPasteAdjustments == model.canPasteAdjustments(to: frames[0]))
            #expect(model.menus.canPasteAdjustments)
            #expect(model.menus.pasteOnlyParts == [.frameControls])
            let copied = model.adjustmentsClipboard
            model.adjustmentsClipboard?.adjustments = .identity.settingLens(try LensSettings(arguments: "distortion-amount=150"))
            await Self.settle(model)
            #expect(model.menus.pasteOnlyParts == [.lens, .frameControls])
            model.adjustmentsClipboard = copied
            await Self.settle(model)
            #expect(model.menus.pasteOnlyParts == AdjustmentParts(AdjustmentParts.each.filter { model.canPasteAdjustments(to: frames[0], parts: $0) }))
            #expect(model.menus.canPasteToShown && model.pasteTargets.count == 7)
            // Under Flagged with nothing flagged the sheet shows no frame: no selection to paste on, and no frame to paste to.
            model.showFrames(.flagged)
            await Self.settle(model)
            #expect(model.menus.pasteToShownTitle == "Paste to Flagged Frames")
            #expect(!model.menus.canPasteToShown && !model.menus.canPasteAdjustments && !model.menus.canShowRAW)
            // The source alone flagged is still no frame to paste to.
            model.setFlag(true, for: frames[1])
            await Self.settle(model)
            #expect(!model.menus.canPasteToShown && model.menus.canPasteAdjustments)
            model.setFlag(true, for: frames[4])
            await Self.settle(model)
            #expect(model.menus.canPasteToShown && model.pasteTargets == [frames[4]])
            model.showFrames(.unflagged)
            await Self.settle(model)
            #expect(model.menus.pasteToShownTitle == "Paste to Unflagged Frames" && model.menus.canPasteToShown)
        }
    }

    /// The Frame menu's Develop This Frame and Finder items say what the model says of the selected frame, and follow a develop.
    @Test func theFramesFilesFollowTheSelectedFrame() async throws {
        try await Self.withRoll { model, frames in
            #expect(model.menus.canShowRAW)
            #expect(model.menus.canDevelopFrame == model.canDevelopFrame(frames[0]))
            #expect(model.menus.canShowDevelopedFile == model.hasDevelopedRecord(for: frames[0]))
            model.developPhase = .developing(DevelopProgress(total: 8))
            await Self.settle(model)
            #expect(!model.canDevelopFrame(frames[0]) && !model.menus.canDevelopFrame)
            model.developPhase = .idle
            await Self.settle(model)
            #expect(model.menus.canDevelopFrame == model.canDevelopFrame(frames[0]))
        }
    }

    /// Away from the roll's page the items are disabled by the page (`MenuState.page`), as the Frame menu's are; what the menus
    /// know of the frame stays, so they come back as they were.
    @Test func awayFromTheRollThePageDisablesThem() async throws {
        try await Self.withRoll(edited: [0]) { model, _ in
            #expect(model.menus.page == .roll && model.menus.canCopyAdjustments)
            model.showWorkspacePage(.rolls)
            await Self.settle(model)
            #expect(model.menus.page == .rolls && model.menus.canCopyAdjustments)
            model.showRoll()
            await Self.settle(model)
            #expect(model.menus.page == .roll)
        }
    }

    /// Without a roll there is no frame: everything is off, and the batch keeps its title.
    @Test func withoutARollNothingIsOn() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-clipboard-menus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        let state = model.menuState
        #expect(!state.canCopyAdjustments && !state.canPasteAdjustments && state.pasteOnlyParts.isEmpty && !state.canPasteToShown)
        #expect(!state.canDevelopFrame && !state.canShowRAW && !state.canShowDevelopedFile)
        #expect(state.pasteToShownTitle == "Paste to All Frames")
    }
}

/// Copy Adjustments' three chords (`ClipboardKeys`) against the plan's and against every key the app binds: the menu bar's own
/// (ArgentApp.swift), the masks' table (`MaskKeys`) and the system's menus, so each is bound once. Command chords, so a focused
/// text field does not keep them: the menu's item takes them, and the field's own Copy and Paste stay Command-C and Command-V.
@MainActor @Suite struct ClipboardKeyTests {
    private static let clipboard = [ClipboardKeys.copy, ClipboardKeys.paste, ClipboardKeys.pasteToShown]

    /// What ArgentApp.swift binds, in every state, the strictest reading: MaskKeyTests' list, which the masks' items are checked
    /// against, with the Stock menu's digits.
    private static let app: [KeyChord] = [KeyChord("f")] + (1...9).map { KeyChord(Character(String($0))) } + [
        KeyChord("k", [.command, .shift]), KeyChord("o", [.command]), KeyChord("o", [.command, .shift]), KeyChord(",", [.command]),
        KeyChord("d", [.command]), KeyChord("d", [.command, .shift]), KeyChord(".", [.command]), KeyChord("r", [.command, .shift]),
        KeyChord("+", [.command]), KeyChord("-", [.command]), KeyChord("0", [.command]), KeyChord("9", [.command]),
        KeyChord("c", [.command, .shift]), KeyChord("a", [.command, .shift]), KeyChord("1", [.command, .option]),
        KeyChord("2", [.command, .option]), KeyChord("g", [.command, .shift]), KeyChord("0", [.command, .control]),
        KeyChord("1", [.command, .control]), KeyChord("2", [.command, .control]),
        KeyChord(KeyEquivalent.downArrow.character, [.command]), KeyChord(KeyEquivalent.upArrow.character, [.command]),
    ]

    /// The system's menus as they stand in the built app (read with the drive hook's `menus` on 2026-11-10): Edit's Undo, Redo,
    /// Cut, Copy, Paste and Select All; the app menu's Hide, Hide Others and Quit; File's Close and Close All; the window's
    /// Minimize and full screen; Emoji & Symbols. SwiftUI's Edit menu has no Paste and Match Style, which AppKit's own binds to
    /// Option-Shift-Command-V: were it to gain one, the batch paste would share its chord, and this list must say so.
    private static let system: [KeyChord] = [
        KeyChord("z", [.command]), KeyChord("z", [.command, .shift]), KeyChord("x", [.command]), KeyChord("c", [.command]),
        KeyChord("v", [.command]), KeyChord("a", [.command]), KeyChord("h", [.command]), KeyChord("h", [.command, .option]),
        KeyChord("q", [.command]), KeyChord("w", [.command]), KeyChord("w", [.command, .option]), KeyChord("m", [.command]),
        KeyChord("f", [.command, .control]), KeyChord(" ", [.command, .control]),
    ]

    @Test func theChordsAreThePlans() {
        #expect(ClipboardKeys.copy == KeyChord("c", [.option, .command]))
        #expect(ClipboardKeys.paste == KeyChord("v", [.option, .command]))
        #expect(ClipboardKeys.pasteToShown == KeyChord("v", [.option, .shift, .command]))
        #expect(Self.clipboard.map(\.symbols) == ["⌥⌘C", "⌥⌘V", "⌥⇧⌘V"])
        #expect(Self.clipboard.map(\.words) == ["Option-Command-C", "Option-Command-V", "Option-Shift-Command-V"])
        // Lightroom's and Photos' Shift-Command-C is Split Compare's here.
        #expect(!Self.clipboard.contains(KeyChord("c", [.command, .shift])))
        let view = ClipboardKeys.pasteToShown.shortcut
        #expect(view.key == KeyEquivalent("v") && view.modifiers == [.option, .shift, .command])
    }

    @Test func eachIsBoundOnce() {
        #expect(Set(Self.clipboard).count == Self.clipboard.count)
        let masks = MaskKeys.all.compactMap(\.chord) + [MaskKeys.masksTab, MaskKeys.masksTabView].compactMap(\.chord) + MaskKeys.flowDigits.compactMap(\.chord)
        for chord in Self.clipboard {
            #expect(!Self.app.contains(chord), "\(chord.words) in ArgentApp.swift")
            #expect(!masks.contains(chord), "\(chord.words) in MaskKeys")
            #expect(!Self.system.contains(chord), "\(chord.words) in the system's menus")
        }
    }

    /// Plain keys give way to a text field (`MaskKeys.isTypedIntoField`); these do not, as no Command chord does: a field's
    /// editor does not take them as its own, so they reach the menu bar, which copies or pastes the frame's adjustments and
    /// leaves the field's text alone.
    @Test func aFocusedTextFieldLeavesThemToTheMenu() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = content
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 24))
        field.stringValue = "DSC00412"
        content.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        for chord in Self.clipboard {
            #expect(!chord.isPlain)
            let key = String(chord.key)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: chord.modifierFlags, timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: key,
                                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: chord.key == "c" ? 8 : 9))
            #expect(!MaskKeys.isTypedIntoField(event, firstResponder: editor), "\(chord.words)")
            #expect(!editor.performKeyEquivalent(with: event), "\(chord.words)")
        }
        #expect(field.stringValue == "DSC00412")
    }
}

/// The notice a copy or a paste leaves (`NoticeStack`'s line for `RollModel.clipboardNotice`), for each kind, as far as it is
/// read without drawing: its symbol or the spinner, its buttons, and what the stack animates on.
@MainActor @Suite struct ClipboardNoticeTests {
    @Test func eachKindHasItsSymbolAndItsButtons() {
        let copied = ClipboardNotice(kind: .copied, text: "Copied adjustments from DSC00412")
        #expect(copied.symbol == "doc.on.doc" && copied.actions == [.close])
        // A paste waiting for its frames shows the spinner, which `Notice` draws for no symbol.
        let pasting = ClipboardNotice(kind: .pasting(done: 3, of: 12), text: "Pasting adjustments… 3 of 12")
        #expect(pasting.symbol == nil && pasting.actions == [.close])
        let pasted = ClipboardNotice(kind: .pasted(frames: 12, skipped: 0), text: "Pasted adjustments to 12 frames", offersUndo: true)
        #expect(pasted.symbol == "doc.on.clipboard" && pasted.actions == [.undo, .close])
        let partly = ClipboardNotice(kind: .pasted(frames: 10, skipped: 2), text: "Pasted to 10 of 12 frames",
                                     details: ["DSC00413: its raw has changed", "DSC00420: an issue"], offersUndo: true)
        #expect(partly.symbol == "exclamationmark.triangle" && partly.actions == [.undo, .details, .close])
        #expect(partly.detailsTitle == "2 frames left as they were")
        #expect(partly.detailsHelp == "The frames left out, and why")
        #expect(partly.detailEntries.isEmpty && partly.plainDetails == partly.details)
        // Once another step is the next to undo, the notice no longer offers it.
        var later = partly
        later.offersUndo = false
        #expect(later.actions == [.details, .close])
        let failed = ClipboardNotice(kind: .failed, text: "Could not paste adjustments", details: ["DSC00413: its recipe is unread"])
        #expect(failed.symbol == "exclamationmark.triangle" && failed.actions == [.details, .close])
        #expect(failed.detailsTitle == "1 frame left as it was")
        #expect(failed.detailsHelp == "The frames left out, and why")
        #expect(failed.detailEntries.isEmpty && failed.plainDetails == failed.details)
    }

    @Test func undoOrDetailsGiveTheNoticeLongerToBeReached() {
        let plain = ClipboardNotice(kind: .copied, text: "Copied")
        #expect(plain.dismissalDelay == .seconds(3))
        let undo = ClipboardNotice(kind: .pasted(frames: 1, skipped: 0), text: "Pasted", offersUndo: true)
        #expect(undo.dismissalDelay == .seconds(6))
        let details = ClipboardNotice(kind: .failed, text: "Stayed", details: ["DSC01: refused"])
        #expect(details.dismissalDelay == .seconds(6))
        let files = ClipboardNotice(kind: .done(symbol: "exclamationmark.triangle"), text: "Moved",
                                    detailEntries: [.init(title: "DSC01.argent")])
        #expect(files.actions.contains(.details))
        #expect(files.dismissalDelay == .seconds(6))
    }

    @Test func fileDetailsNameFilesAndMixedDetailsNameBoth() {
        var notice = ClipboardNotice(kind: .done(symbol: "exclamationmark.triangle"), text: "Moved",
                                     detailEntries: [.init(title: "DSC01.argent")])
        #expect(notice.detailsHelp == "The files left behind, and why")
        notice.details = ["DSC02: its raw could not move"]
        #expect(notice.detailsHelp == "The frames and files left behind, and why")
        let headingOnly = ClipboardNotice(kind: .done(symbol: "exclamationmark.triangle"), text: "Moved",
                                          detailsHeading: "Companions left behind")
        #expect(headingOnly.detailsHelp == "The files left behind, and why")
    }

    /// The stack fades the notice in and out and from the spinner to what the paste came to, but not at each count.
    @Test func theStackAnimatesOnThePhaseNotTheCount() {
        let three = ClipboardNotice(kind: .pasting(done: 3, of: 12), text: "Pasting adjustments… 3 of 12")
        let four = ClipboardNotice(kind: .pasting(done: 4, of: 12), text: "Pasting adjustments… 4 of 12")
        let done = ClipboardNotice(kind: .pasted(frames: 12, skipped: 0), text: "Pasted adjustments to 12 frames")
        #expect(three != four && three.phase == four.phase)
        #expect(four.phase != done.phase && done.phase == done.kind)
    }

    /// A copy leaves its notice; the close takes it away; the notice's Undo does nothing while the notice does not offer it.
    @Test func aCopyLeavesItsNoticeAndTheCloseTakesItAway() async throws {
        try await ClipboardMenuStateTests.withRoll(edited: [2]) { model, frames in
            #expect(model.clipboardNotice == nil)
            model.copyAdjustments(from: frames[2])
            let notice = try #require(model.clipboardNotice)
            #expect(notice.kind == .copied && notice.text == "Copied adjustments from \(frames[2].name)")
            #expect(notice.symbol == "doc.on.doc" && notice.actions == [.close])
            model.undoPasteFromNotice()
            #expect(model.clipboardNotice == notice)
            model.dismissClipboardNotice()
            #expect(model.clipboardNotice == nil)
        }
    }
}
