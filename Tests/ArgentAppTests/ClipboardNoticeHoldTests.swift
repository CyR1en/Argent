import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The clipboard's line as it is reached for and as a waiting paste is stopped (docs/context-menus-plan.md, section 5).
@MainActor @Suite(.serialized) struct ClipboardNoticeHoldTests {
    private func model() throws -> (RollModel, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-clipboard-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        return (model, folder)
    }

    /// Whether the line goes, waited for rather than looked for at a fixed moment: every app suite runs on the main actor, and one
    /// that holds it past that moment made these fail though the line went as it should. The bound is for a line that never goes.
    private func goes(_ model: RollModel, within limit: Duration = .seconds(10)) async -> Bool {
        let end = ContinuousClock.now + limit
        while model.clipboardNotice != nil, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        return model.clipboardNotice == nil
    }

    @Test func theLineStaysWhileItIsReachedForAndGoesAMomentAfter() async throws {
        let (model, folder) = try model()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notice = ClipboardNotice(kind: .pasted(frames: 2, skipped: 1), text: "Pasted to 2 of 3 frames", details: ["DSC3: why"])
        model.showClipboardNotice(notice, for: .milliseconds(40))
        model.holdClipboardNotice(true)
        try await Task.sleep(for: .milliseconds(160))
        #expect(model.clipboardNotice == notice)
        model.holdClipboardNotice(false, lettingGoAfter: .milliseconds(40))
        #expect(model.clipboardNotice == notice)
        #expect(await goes(model))
    }

    @Test func aWaitingPasteIsStoppedByItsCloseAndAPasteMadeIsNot() async throws {
        let (model, folder) = try model()
        defer { try? FileManager.default.removeItem(at: folder) }
        let waiting = Task<PasteReport?, Never> {
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        model.pasteTask = waiting
        model.showClipboardNotice(ClipboardNotice(kind: .pasting(done: 1, of: 3), text: "Pasting adjustments… 1 of 3"))
        // A waiting paste keeps its line whether or not it is reached for.
        model.holdClipboardNotice(false, lettingGoAfter: .milliseconds(1))
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.clipboardNotice?.isWaiting == true)
        model.stopPaste()
        #expect(waiting.isCancelled)
        #expect(model.clipboardNotice == nil)

        let made = Task<PasteReport?, Never> { nil }
        model.pasteTask = made
        let pasted = ClipboardNotice(kind: .pasted(frames: 3, skipped: 0), text: "Pasted adjustments to 3 frames", offersUndo: true)
        model.showClipboardNotice(pasted)
        model.stopPaste()
        #expect(model.clipboardNotice == pasted)
        model.dismissClipboardNotice()
    }

    /// Stopping the newest paste also stops every paste it is waiting behind and closes the line.
    @Test func stoppingAPasteStopsTheOnesItWaitsBehind() async throws {
        let (model, folder) = try model()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Task<PasteReport?, Never> {
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        let second = Task<PasteReport?, Never> { await RollModel.wait(behind: first); return nil }
        model.pasteTask = second
        model.showClipboardNotice(ClipboardNotice(kind: .pasting(done: 0, of: 2), text: "Pasting adjustments… 0 of 2"))
        model.stopPaste()
        _ = await second.value
        #expect(first.isCancelled)
        #expect(second.isCancelled)
        #expect(model.clipboardNotice == nil)
    }

    /// A line that takes a waiting paste's place while held stays until it is let go.
    @Test func aLineThatTakesAnothersPlaceWhileHeldStays() async throws {
        let (model, folder) = try model()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.showClipboardNotice(ClipboardNotice(kind: .pasting(done: 1, of: 3), text: "Pasting adjustments… 1 of 3"))
        model.holdClipboardNotice(true)
        let pasted = ClipboardNotice(kind: .pasted(frames: 3, skipped: 0), text: "Pasted adjustments to 3 frames", offersUndo: true)
        model.showClipboardNotice(pasted, for: .milliseconds(40))
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.clipboardNotice == pasted)
        model.holdClipboardNotice(false, lettingGoAfter: .milliseconds(40))
        #expect(await goes(model))
    }

    /// Closing a held line lets the next line go after its usual moment.
    @Test func closingTheLineForgetsTheHold() async throws {
        let (model, folder) = try model()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.showClipboardNotice(ClipboardNotice(kind: .copied, text: "Copied adjustments from First"))
        model.holdClipboardNotice(true)
        model.dismissClipboardNotice()
        model.showClipboardNotice(ClipboardNotice(kind: .copied, text: "Copied adjustments from Second"), for: .milliseconds(40))
        #expect(await goes(model))
    }
}
