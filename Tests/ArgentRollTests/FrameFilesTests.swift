import Foundation
import Testing
@testable import ArgentRoll

/// A frame's files moved together (`FrameFiles`): the raw with its recipe and its masks' seeds, into another folder or
/// to the Trash; nothing written over, and a frame that cannot move left whole where it was.
@Suite struct FrameFilesTests {
    private struct Scene {
        let root: URL
        let roll: URL
        let other: URL
        let trash: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("argent-frame-files-\(UUID().uuidString)")
            roll = root.appendingPathComponent("Roll")
            other = root.appendingPathComponent("Other")
            trash = root.appendingPathComponent("Trash")
            for folder in [roll, other, trash] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        }

        /// A raw in `folder`, with a recipe and a masks pack beside it when asked.
        func raw(_ name: String, in folder: URL? = nil, recipe: Bool = false, masks: Bool = false) throws -> URL {
            let url = (folder ?? roll).appendingPathComponent(name)
            try Data("raw \(name) \(UUID().uuidString)".utf8).write(to: url)
            if recipe { try Data("recipe of \(name)".utf8).write(to: RecipeStore.besideRaw(url)) }
            if masks { try Data("masks of \(name)".utf8).write(to: RecipeStore.masksBesideRaw(url)) }
            return url
        }

        func names(in folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

        /// A Trash of the test's own: the file under its name in `trash`.
        func trashing(_ file: URL) throws -> URL {
            let target = trash.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: target)
            return target
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aFrameMovesWithItsRecipeAndItsMasks() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let edited = try scene.raw("DSC1.ARW", recipe: true, masks: true), plain = try scene.raw("DSC2.ARW")
        let bytes = try Data(contentsOf: edited)
        _ = try scene.raw("DSC3.ARW", recipe: true)

        let outcomes = FrameFiles.move([edited, plain], into: scene.other)
        #expect(outcomes == [.moved(scene.other.appendingPathComponent("DSC1.ARW")), .moved(scene.other.appendingPathComponent("DSC2.ARW"))])
        #expect(scene.names(in: scene.other) == ["DSC1.ARW", "DSC1.argent", "DSC1.argentmasks", "DSC2.ARW"])
        // The frame left behind keeps its own recipe.
        #expect(scene.names(in: scene.roll) == ["DSC3.ARW", "DSC3.argent"])
        #expect(try Data(contentsOf: scene.other.appendingPathComponent("DSC1.ARW")) == bytes)
        #expect(try String(contentsOf: scene.other.appendingPathComponent("DSC1.argent"), encoding: .utf8) == "recipe of DSC1.ARW")
    }

    @Test func aNameAlreadyThereKeepsTheFrameWhereItWas() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let raw = try scene.raw("DSC1.ARW", recipe: true), taken = try scene.raw("DSC1.ARW", in: scene.other)
        let theirs = try Data(contentsOf: taken)
        #expect(FrameFiles.move([raw], into: scene.other) == [.nameTaken])
        #expect(scene.names(in: scene.roll) == ["DSC1.ARW", "DSC1.argent"])
        #expect(try Data(contentsOf: taken) == theirs)

        // A recipe there under the frame's name, with no raw, would be read as the frame's: it stays too.
        let lone = try scene.raw("DSC2.ARW", recipe: true)
        try Data("another frame's".utf8).write(to: scene.other.appendingPathComponent("DSC2.argent"))
        #expect(FrameFiles.move([lone], into: scene.other) == [.nameTaken])
        #expect(FileManager.default.fileExists(atPath: lone.path))
        #expect(try String(contentsOf: scene.other.appendingPathComponent("DSC2.argent"), encoding: .utf8) == "another frame's")
    }

    @Test func aRawThatHasGoneFailsAndTheOthersStillMove() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let gone = scene.roll.appendingPathComponent("DSC9.ARW"), there = try scene.raw("DSC1.ARW")
        let outcomes = FrameFiles.move([gone, there], into: scene.other)
        #expect(!outcomes[0].isMoved && outcomes[1].isMoved)
        #expect(scene.names(in: scene.other) == ["DSC1.ARW"])
        // A folder that is not there takes nothing, and the frame stays.
        let stays = try scene.raw("DSC2.ARW", recipe: true)
        #expect(!FrameFiles.move([stays], into: scene.root.appendingPathComponent("Nowhere"))[0].isMoved)
        #expect(scene.names(in: scene.roll) == ["DSC2.ARW", "DSC2.argent"])
    }

    @Test func aCompanionRefusedByTheTrashReportsPartialFailure() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let raw = try scene.raw("DSC1.ARW", recipe: true, masks: true)
        let recipe = RecipeStore.besideRaw(raw)
        let outcomes = FrameFiles.trash([raw]) { file in
            if file == recipe { throw CocoaError(.fileWriteNoPermission) }
            return try scene.trashing(file)
        }
        #expect(outcomes[0] != .moved(scene.trash.appendingPathComponent(raw.lastPathComponent)))
        #expect(outcomes[0].isMoved)
        guard case .partiallyMoved(let destination, let failures) = outcomes[0] else {
            Issue.record("Expected a partial move")
            return
        }
        #expect(destination == scene.trash.appendingPathComponent(raw.lastPathComponent))
        let message = try #require((CocoaError(.fileWriteNoPermission) as NSError).localizedFailureReason)
        #expect(failures == [.init(file: recipe, message: message)])
        #expect(scene.names(in: scene.roll) == ["DSC1.argent"])
        #expect(scene.names(in: scene.trash) == ["DSC1.ARW", "DSC1.argentmasks"])
    }

    @Test func anImmovableCompanionReportsPartialFailure() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let raw = try scene.raw("DSC1.ARW", recipe: true, masks: true)
        let recipe = RecipeStore.besideRaw(raw)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: recipe.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: recipe.path) }
        let outcomes = FrameFiles.move([raw], into: scene.other)
        #expect(outcomes[0] != .moved(scene.other.appendingPathComponent(raw.lastPathComponent)))
        #expect(outcomes[0].isMoved)
        guard case .partiallyMoved(let destination, let failures) = outcomes[0] else {
            Issue.record("Expected a partial move")
            return
        }
        #expect(destination == scene.other.appendingPathComponent(raw.lastPathComponent))
        #expect(failures.map(\.file) == [recipe])
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        #expect(failures.map(\.message) == [error.localizedFailureReason ?? error.localizedDescription])
        #expect(scene.names(in: scene.roll) == ["DSC1.argent"])
        #expect(scene.names(in: scene.other) == ["DSC1.ARW", "DSC1.argentmasks"])
    }

    @Test func companionErrorsPreferTheUnderlyingPOSIXReasonThenTheFailureReason() throws {
        let errors: [(NSError, String)] = [
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                     userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM),
                                                              userInfo: [NSLocalizedFailureReasonErrorKey: "Underlying reason",
                                                                         NSLocalizedDescriptionKey: "Underlying description"]),
                                NSLocalizedFailureReasonErrorKey: "Outer reason"]), "Underlying reason"),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                     userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -5000),
                                NSLocalizedFailureReasonErrorKey: "You don’t have permission."]), "You don’t have permission."),
            (NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fallback reason"]), "Fallback reason"),
        ]
        for (error, message) in errors {
            let scene = try Scene()
            defer { scene.remove() }
            let raw = try scene.raw("DSC1.ARW", recipe: true)
            let recipe = RecipeStore.besideRaw(raw)
            let outcomes = FrameFiles.trash([raw]) { file in
                if file == recipe { throw error }
                return try scene.trashing(file)
            }
            #expect(outcomes == [.partiallyMoved(scene.trash.appendingPathComponent(raw.lastPathComponent),
                                                failures: [.init(file: recipe, message: message)])])
        }
    }

    @Test func everyRefusedCompanionIsReportedAndTheNextRawStillMoves() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let raw = try scene.raw("DSC1.ARW", recipe: true, masks: true)
        let next = try scene.raw("DSC2.ARW")
        let outcomes = FrameFiles.trash([raw, next]) { file in
            if FrameFiles.companions(of: raw).contains(file) { throw CocoaError(.fileWriteNoPermission) }
            return try scene.trashing(file)
        }
        guard case .partiallyMoved(_, let failures) = outcomes[0] else {
            Issue.record("Expected a partial move")
            return
        }
        #expect(failures.map(\.file) == Array(FrameFiles.companions(of: raw).prefix(2)))
        #expect(outcomes[1] == .moved(scene.trash.appendingPathComponent(next.lastPathComponent)))
    }

    @Test func noFramesMoveWithoutAnOutcome() {
        #expect(FrameFiles.move([], into: URL(fileURLWithPath: "/unused")).isEmpty)
        #expect(FrameFiles.trash([]) { _ in
            Issue.record("An empty request must not trash a file")
            throw CocoaError(.fileWriteUnknown)
        }.isEmpty)
    }

    @Test func theTrashTakesTheFrameWithItsRecipeAndItsMasks() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let edited = try scene.raw("DSC1.ARW", recipe: true, masks: true), kept = try scene.raw("DSC2.ARW", recipe: true)
        let outcomes = FrameFiles.trash([edited], trashing: scene.trashing)
        #expect(outcomes == [.moved(scene.trash.appendingPathComponent("DSC1.ARW"))])
        #expect(scene.names(in: scene.trash) == ["DSC1.ARW", "DSC1.argent", "DSC1.argentmasks"])
        #expect(scene.names(in: scene.roll) == ["DSC2.ARW", "DSC2.argent"])
        #expect(FileManager.default.fileExists(atPath: kept.path))

        // A Trash that refuses the raw leaves the frame whole.
        struct Refused: Error {}
        let refused = FrameFiles.trash([kept]) { _ in throw Refused() }
        #expect(!refused[0].isMoved)
        #expect(scene.names(in: scene.roll) == ["DSC2.ARW", "DSC2.argent"])
    }
}
