import AppKit
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The Rolls page and the roll's notices, read from the model: the library's rolls and the roll open
/// now among them, their menu, what the page answers, why an open gave no roll, a card's offer, and
/// raws the roll could not read, closed for those files only.
@MainActor @Suite(.serialized) struct OpenRollStateTests {
    /// A model without stocks whose bookmarks, recipes and flags live in a folder of the run's own,
    /// and beside it `Roll`, holding `raws` header-only raws and `junk` ARW files that are not raws,
    /// and `Other`, a roll of one raw.
    private static func withModel(raws: Int = 2, junk: Int = 0,
                                  _ body: (RollModel, _ roll: URL, _ other: URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-open-roll-\(UUID().uuidString)")
        let roll = folder.appendingPathComponent("Roll"), other = folder.appendingPathComponent("Other")
        let library = folder.appendingPathComponent("Library")
        for directory in [roll, other, library] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<raws { try writeHeader(roll.appendingPathComponent("DSC\(index + 1).ARW")) }
        for index in 0..<junk { try Data("not a raw \(index)".utf8).write(to: roll.appendingPathComponent("BAD\(index + 1).ARW")) }
        try writeHeader(other.appendingPathComponent("DSC1.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: library, decisions: AutoDecisionStore(library: library), flagStore: FlagStore(library: library),
                              recipeLibrary: library, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        try await body(model, roll, other)
        await model.flagSave?.value
    }

    /// A raw's header alone, of a unique size so no two runs share a digest: enough for the scan.
    private static func writeHeader(_ url: URL) throws {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8 & 255)] }
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 255) } }
        let exif = 8 + 2 + 12 + 4
        var bytes = [UInt8]([0x49, 0x49]) + u16(42) + u32(8)
        bytes += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(exif) + u32(0)
        bytes += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try (Data(bytes) + Data(UUID().uuidString.utf8)).write(to: url, options: .atomic)
    }

    @Test func openedRollsJoinTheLibraryAndTheOneOpenNowIsMarked() async throws {
        try await Self.withModel { model, roll, other in
            #expect(model.library.isEmpty && model.openLibraryRoll == nil)
            await model.open(other)
            await model.open(roll)
            #expect(model.recents.map(\.name) == ["Roll", "Other"])
            // Both joined the library where they are, with their frames counted; the roll open now is marked.
            #expect(Set(model.library.map(\.name)) == ["Roll", "Other"])
            #expect(model.library.allSatisfy { $0.origin == .inPlace && $0.opened != nil })
            #expect(model.library.first { $0.name == "Roll" }?.frameCount == 2)
            #expect(model.libraryFrameCount == 3)
            #expect(model.openLibraryRoll?.name == "Roll")
            // Opened again, a roll keeps its place and its id.
            let id = try #require(model.openLibraryRoll?.id)
            await model.open(roll)
            #expect(model.library.count == 2 && model.openLibraryRoll?.id == id)
            // Kept across launches.
            #expect(Set(BookmarkStore(file: model.bookmarks.file, securityScoped: false).rolls.map(\.name)) == ["Roll", "Other"])

            // Rolls in the rail, then back: the roll stays as it was. A click on the roll open now goes back to it.
            model.showWorkspacePage(.rolls)
            #expect(model.workspacePage == .rolls)
            model.openLibraryRoll(id: id)
            #expect(model.workspacePage == .roll)
            #expect(model.roll?.folder.canonicalPath == roll.canonicalPath)
        }
    }

    @Test func theFilterFindsRollsByNameAndTheOrderIsByDate() async throws {
        try await Self.withModel { model, roll, other in
            await model.open(other)
            await model.open(roll)
            let rollID = try #require(model.library.first { $0.name == "Roll" }?.id)
            let otherID = try #require(model.library.first { $0.name == "Other" }?.id)
            model.bookmarks.updateRoll(id: rollID) { $0.firstCapture = Date(timeIntervalSince1970: 2_000_000_000) }
            model.bookmarks.updateRoll(id: otherID) { $0.firstCapture = Date(timeIntervalSince1970: 1_000_000_000) }
            model.library = model.bookmarks.rolls
            #expect(model.libraryRolls().map(\.name) == ["Roll", "Other"])
            #expect(model.libraryRolls(oldestFirst: true).map(\.name) == ["Other", "Roll"])
            #expect(model.libraryRolls(matching: "oth").map(\.name) == ["Other"])
            #expect(model.libraryRolls(matching: "  ").count == 2)
            #expect(model.libraryRolls(matching: "nothing").isEmpty)
            #expect(RollMonth.grouping(model.libraryRolls()).map(\.title) == ["May 2033", "September 2001"])
        }
    }

    /// A roll's menu (`LibraryRollMenu`) as a table: Open, Show in Finder, Rename…, then Remove from Rolls, Show in Finder
    /// off while the roll cannot be reached. Remove forgets the roll, here and in File > Open Recent, and leaves its folder.
    @Test func aRollsMenuOpensShowsRenamesAndRemoves() async throws {
        try await Self.withModel { model, roll, other in
            await model.open(other)
            await model.open(roll)
            let entry = try #require(model.library.first { $0.name == "Other" })
            var entries = LibraryRollMenu.entries(for: entry, model: model)
            #expect(entries.titles == ["Open", "Show in Finder", "Rename…", "—", "Remove from Rolls"])
            #expect(entries.map(\.id) == ["roll.open", "roll.showInFinder", "roll.rename", "divider.3", "roll.remove"])
            #expect(entries.allSatisfy { $0.isDivider || $0.isEnabled })
            // The roll open now goes back rather than opening again.
            let open = try #require(model.openLibraryRoll)
            #expect(LibraryRollMenu.entries(for: open, model: model).entry("roll.open")?.title == "Back to Roll")

            // Open is the row's click.
            entries.entry("roll.open")?.choose()
            for _ in 0..<500 where model.roll?.folder.canonicalPath != other.canonicalPath || model.isScanning {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.roll?.folder.canonicalPath == other.canonicalPath)

            // Rename… changes the name shown, never the folder's; an empty name changes nothing.
            entries.entry("roll.rename")?.choose()
            #expect(model.renamingRoll == entry.id)
            model.renameLibraryRoll(id: entry.id, to: "  Saturday market ")
            #expect(model.renamingRoll == nil && model.library.first { $0.id == entry.id }?.name == "Saturday market")
            model.renameLibraryRoll(id: entry.id, to: " ")
            #expect(model.library.first { $0.id == entry.id }?.name == "Saturday market")
            #expect(FileManager.default.fileExists(atPath: other.path))

            // A roll that has gone cannot be shown: the model says so, and its Show in Finder goes off.
            let gone = try #require(model.library.first { $0.name == "Roll" })
            try FileManager.default.removeItem(at: roll)
            model.showLibraryRollInFinder(id: gone.id)
            #expect(model.unavailableRolls == [gone.id] && model.message == "Roll is not available")
            entries = LibraryRollMenu.entries(for: gone, model: model)
            #expect(entries.entry("roll.showInFinder")?.isEnabled == false)

            // Remove from Rolls: forgotten here, in the store and in Open Recent; the other roll's folder is untouched.
            entries.entry("roll.remove")?.choose()
            #expect(model.library.map(\.name) == ["Saturday market"] && model.unavailableRolls.isEmpty)
            #expect(model.recents.map(\.name) == ["Other"])
            #expect(BookmarkStore(file: model.bookmarks.file, securityScoped: false).rolls.map(\.name) == ["Saturday market"])
        }
    }

    /// Show in Finder reveals a roll that is there.
    @Test func showInFinderShowsALibraryRollThatIsThere() async throws {
        try await Self.withModel { model, roll, other in
            await model.open(other)
            await model.open(roll)
            let entry = try #require(model.library.first { $0.name == "Other" })
            let kept = FinderReveal.show
            defer { FinderReveal.show = kept }
            var shown: [URL] = []
            FinderReveal.show = { shown += $0 }
            model.showLibraryRollInFinder(id: entry.id)
            #expect(shown.map(\.canonicalPath) == [other.canonicalPath])
            #expect(!model.unavailableRolls.contains(entry.id) && model.message == nil)
        }
    }

    @Test func cachedLibraryRollFollowsVolumeAvailabilityWithoutOpening() async throws {
        try await Self.withModel { model, roll, _ in
            let entry = try #require(model.bookmarks.addRoll(roll, origin: .inPlace))
            model.library = model.bookmarks.rolls
            let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let cover = try #require(context.makeImage())
            model.rollCovers[entry.id] = [cover]

            try FileManager.default.removeItem(at: roll)
            let changes = NSWorkspace.shared.notificationCenter
            model.watchCards()
            defer { model.volumeObservers.forEach { changes.removeObserver($0) } }

            for _ in 0..<100 where !model.unavailableRolls.contains(entry.id) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.unavailableRolls == [entry.id])
            #expect(model.message == nil)

            model.openLibraryRoll(id: entry.id)
            #expect(model.message == RollModel.unavailableText(entry))
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            changes.post(name: NSWorkspace.didMountNotification, object: nil,
                         userInfo: [NSWorkspace.volumeURLUserInfoKey: roll.deletingLastPathComponent()])

            for _ in 0..<100 where model.unavailableRolls.contains(entry.id) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.unavailableRolls.isEmpty)
            #expect(model.message == nil)
            #expect(model.roll == nil)
            #expect(model.rollCovers[entry.id]?.first === cover)

            try FileManager.default.removeItem(at: roll)
            changes.post(name: NSWorkspace.didUnmountNotification, object: nil,
                         userInfo: [NSWorkspace.volumeURLUserInfoKey: roll.deletingLastPathComponent()])
            for _ in 0..<100 where !model.unavailableRolls.contains(entry.id) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.unavailableRolls == [entry.id])
            #expect(model.rollCovers[entry.id]?.first === cover)
        }
    }

    /// Removing the roll open now leaves it open; it joins the library again the next time it opens.
    @Test func removingTheOpenRollLeavesItOpenUntilItOpensAgain() async throws {
        try await Self.withModel { model, roll, other in
            await model.open(other)
            await model.open(roll)
            let id = try #require(model.openLibraryRoll?.id)
            model.removeLibraryRoll(id: id)
            #expect(model.library.map(\.name) == ["Other"] && model.roll?.name == "Roll" && model.openLibraryRoll == nil)
            await model.open(roll)
            #expect(Set(model.library.map(\.name)) == ["Roll", "Other"])
        }
    }

    @Test func aRollOutOfReachSaysWhichDriveItIsOn() {
        let roll = BookmarkStore.LibraryRoll(id: UUID(), path: "/Volumes/T7 Shield/Titos", name: "Titos", bookmark: Data(), origin: .inPlace,
                                             source: nil, volume: "T7 Shield", added: Date(), opened: nil, firstCapture: nil, frameCount: nil)
        #expect(RollModel.unavailableText(roll) == "Titos is on \u{201C}T7 Shield\u{201D}, which is not connected")
        var local = roll
        local.volume = nil
        #expect(RollModel.unavailableText(local) == "Titos is not available")
    }

    @Test func theCentreAnswersADropFirstThenARead() async throws {
        try await Self.withModel { model, _, _ in
            #expect(model.openRollHero == .ready)
            model.isDropTargeted = true
            #expect(model.openRollHero == .dropTargeted)
            model.isDropTargeted = false
            #expect(model.openRollHero == .ready)
        }
    }

    @Test func anOpenThatGivesNoRollSaysWhyWithTheWayOn() async throws {
        try await Self.withModel(raws: 0) { model, roll, other in
            await model.open(roll)
            #expect(model.roll == nil)
            #expect(model.message == "No ARW files in Roll")
            #expect(model.openRollMessageHint == "Choose another folder, or drop one here.")
            // Over a roll the message is the notice's, without the page's hint.
            #expect(model.rollNoticeMessage == nil)
            await model.open(other)
            #expect(model.message == nil)
            #expect(!model.open([other.appendingPathComponent("DSC1.ARW")]))
            #expect(model.rollNoticeMessage == "Drop a folder or a card, not single files")
            #expect(model.openRollMessageHint == nil)
        }
    }

    @Test func unreadableRawsAreANoticeClosedForThoseFilesOnly() async throws {
        try await Self.withModel(raws: 2, junk: 2) { model, roll, other in
            await model.open(roll)
            #expect(model.roll?.frames.count == 2)
            #expect(model.unreadableNotice == "2 raw files could not be read")
            model.dismissUnreadableNotice()
            #expect(model.unreadableNotice == nil)
            // Read again unchanged, the roll keeps it closed.
            await model.open(roll)
            #expect(model.unreadableNotice == nil)
            // A roll with every raw read has none.
            await model.open(other)
            #expect(model.unreadableNotice == nil)
            // Another raw left out shows it again.
            try Data("not a raw either".utf8).write(to: roll.appendingPathComponent("BAD3.ARW"))
            await model.open(roll)
            #expect(model.unreadableNotice == "3 raw files could not be read")
        }
    }

    @Test func oneUnreadableRawIsSaidInTheSingular() async throws {
        try await Self.withModel(raws: 1, junk: 1) { model, roll, _ in
            await model.open(roll)
            #expect(model.unreadableNotice == "1 raw file could not be read")
        }
    }

    @Test func aCardOfferWaitsForADevelopToOpen() async throws {
        try await Self.withModel { model, _, _ in
            #expect(!model.canOpenOfferedCard)
            let card = Card(volume: URL(fileURLWithPath: "/Volumes/OPEN-ROLL-TEST", isDirectory: true), name: "Untitled", rawCount: 214)
            model.cards.append(card)
            #expect(model.offeredCard == card)
            #expect(RollModel.offerText(card) == "Card Untitled, 214 frames")
            #expect(model.canOpenOfferedCard)
            model.developPhase = .developing(DevelopProgress(total: 4))
            #expect(!model.canOpenOfferedCard)
            model.developPhase = .idle
            model.dismissCard(card)
            #expect(model.offeredCard == nil)
        }
    }

    /// A roll opening closes the Import roll sheet, so it is not left over the roll.
    @Test func opensCloseTheImportRollSheet() async throws {
        try await Self.withModel { model, roll, other in
            model.showImportSource()
            #expect(model.isImportSourceShown)
            await model.open(other)
            #expect(!model.isImportSourceShown)
        }
    }

    /// The notice's Open roll, for the roll open now, reads it again with the frames just copied into it.
    @Test func aNoticeAboutTheRollOpenNowReadsItAgain() async throws {
        try await Self.withModel { model, roll, other in
            await model.open(roll)
            let id = try #require(model.openLibraryRoll?.id)
            model.importNotice = ImportNotice(roll: id, folder: roll, copied: 1, left: 0, source: "Roll", isFolder: true, ejectable: nil)
            #expect(model.importNoticeIsOpenRoll)
            #expect(model.importNotice?.ejectName == nil)
            try Self.writeHeader(roll.appendingPathComponent("DSC3.ARW"))
            model.openImportedRoll()
            for _ in 0..<500 where !(model.roll?.frames.count == 3 && !model.isScanning) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.roll?.frames.count == 3)
            #expect(model.importNotice == nil)
        }
    }

    /// The notice's Open roll, for another roll, opens that one.
    @Test func aNoticeAboutAnotherRollOpensIt() async throws {
        try await Self.withModel { model, roll, other in
            await model.open(other)
            let otherID = try #require(model.openLibraryRoll?.id)
            await model.open(roll)
            model.importNotice = ImportNotice(roll: otherID, folder: other, copied: 1, left: 0, source: "Other", isFolder: true, ejectable: nil)
            #expect(!model.importNoticeIsOpenRoll)
            model.openImportedRoll()
            for _ in 0..<500 where !(model.roll?.folder.canonicalPath == other.canonicalPath && !model.isScanning) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.roll?.folder.canonicalPath == other.canonicalPath)
            #expect(model.importNotice == nil)
        }
    }

    @Test func frameCounts() {
        #expect(RollModel.framesText(1) == "1 frame")
        #expect(RollModel.framesText(24) == "24 frames")
    }
}
