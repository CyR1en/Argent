import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ArgentRoll

@Suite struct KeeperCopyTests {
    private static let moreThanThreeChunks = 3 << 20 | 4321

    private struct Scene {
        let root: URL
        let card: URL
        let folder: URL

        init() throws {
            root = URL(fileURLWithPath: try #require(realpath(try temporaryFolder().path, nil).map { String(cString: $0) }))
            card = root.appendingPathComponent("DCIM/100MSDCF")
            folder = root.appendingPathComponent("keepers")
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        }

        func raw(_ name: String, size: Int = KeeperCopyTests.moreThanThreeChunks, in place: URL? = nil) throws -> URL {
            let url = (place ?? card).appendingPathComponent(name)
            try KeeperCopyTests.randomBytes(size).write(to: url)
            return url
        }

        func copy(_ raws: [URL],
                  progress: @Sendable (URL, KeeperCopy.Outcome) async -> Void = { _, _ in }) async throws -> [KeeperCopy.Outcome] {
            try await KeeperCopy.run(raws, to: folder, refusing: [], progress: progress)
        }

        func copied(_ raw: URL) -> URL { folder.appendingPathComponent(raw.lastPathComponent) }

        var contents: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
        var partials: [String] { contents.filter { $0.contains(".partial-") } }
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func aCopyHasItsRawsBytesAndDate() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raws = [try scene.raw("DSC00001.ARW"), try scene.raw("DSC00002.ARW", size: 17), try scene.raw("DSC00003.ARW", size: 0)]

        let outcomes = try await scene.copy(raws)

        #expect(outcomes == (try raws.map { .copied(sha256: try Self.sha256($0)) }))
        for raw in raws {
            #expect(try Data(contentsOf: scene.copied(raw)) == Data(contentsOf: raw))
            #expect(SourceStamp.of(scene.copied(raw))?.modified == SourceStamp.of(raw)?.modified)
        }
        #expect(scene.partials.isEmpty)
    }

    @Test func aRerunFindsEveryRawAlreadyThereAndLeavesItAlone() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raws = [try scene.raw("DSC00001.ARW"), try scene.raw("DSC00002.ARW")]
        _ = try await scene.copy(raws)
        let stamps = raws.map { SourceStamp.of(scene.copied($0)) }

        let again = try await scene.copy(raws)

        #expect(again == (try raws.map { .alreadyThere(sha256: try Self.sha256($0)) }))
        #expect(raws.map { SourceStamp.of(scene.copied($0)) } == stamps)
    }

    @Test(arguments: [0, 1000])
    func anotherFileOfTheNameIsAConflictAndKeepsItsBytes(sizeDifference: Int) async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raw = try scene.raw("DSC00001.ARW", size: 2 << 20)
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        let theirs = Self.randomBytes((2 << 20) + sizeDifference)
        try theirs.write(to: scene.copied(raw))

        let stopped = await #expect(throws: KeeperCopy.Stopped.self) { try await scene.copy([raw]) }

        #expect(stopped?.raw == raw)
        guard case .conflict(let existing) = stopped?.outcome else {
            Issue.record("not a conflict: \(String(describing: stopped))")
            return
        }
        #expect(existing.path == scene.copied(raw).path)
        #expect(try Data(contentsOf: scene.copied(raw)) == theirs)
        #expect(scene.partials.isEmpty)
    }

    @Test func cancellingLeavesNoPartialFileAndOnlyWholeCopies() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raws = try (1...12).map { try scene.raw(String(format: "DSC%05d.ARW", $0), size: 4 << 20) }

        let copy = Task { try await scene.copy(raws) { _, _ in withUnsafeCurrentTask { $0?.cancel() } } }

        await #expect(throws: CancellationError.self) { try await copy.value }
        #expect(scene.partials.isEmpty)
        #expect((1..<raws.count).contains(scene.contents.count))
        for name in scene.contents {
            #expect(try Data(contentsOf: scene.folder.appendingPathComponent(name)) == Data(contentsOf: scene.card.appendingPathComponent(name)))
        }
    }

    @Test func aPartialFileACrashLeftIsDeletedAndTheRawCopies() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raw = try scene.raw("DSC00001.ARW")
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: scene.folder.appendingPathComponent(".DSC00001.ARW.partial-DEADBEEF"))
        try Data(repeating: 7, count: 1000).write(to: scene.folder.appendingPathComponent(".DSC00002.ARW.partial-DEADBEEF"))

        let outcomes = try await scene.copy([raw])

        #expect(outcomes == [.copied(sha256: try Self.sha256(raw))])
        #expect(scene.partials == [".DSC00002.ARW.partial-DEADBEEF"])
    }

    @Test func aFileThatOnlyLooksLikeAPartialFileIsKept() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raw = try scene.raw("DSC00001.ARW")
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        let theirs = [".DSC00001.ARW.partial-personal-notes", ".DSC00001.ARW.partial-deadbeef", ".DSC00001.ARW.partial-DEADBEEF.txt"]
        for name in theirs { try Data(repeating: 7, count: 1000).write(to: scene.folder.appendingPathComponent(name)) }

        let outcomes = try await scene.copy([raw])

        #expect(outcomes == [.copied(sha256: try Self.sha256(raw))])
        #expect(scene.partials == theirs.sorted())
    }

    @Test func aPartialFileARunningCopyHoldsIsLeftToIt() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raw = try scene.raw("DSC00001.ARW")
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        let live = scene.folder.appendingPathComponent(".DSC00001.ARW.partial-0FF1CE00")
        let held = open(live.path, O_WRONLY | O_CREAT | O_EXLOCK, 0o644)
        defer { close(held) }
        #expect(held >= 0)

        let outcomes = try await scene.copy([raw])

        #expect(outcomes == [.copied(sha256: try Self.sha256(raw))])
        #expect(scene.partials == [live.lastPathComponent])
    }

    @Test func aRawThatShrinksWhileCopiedFailsAndLeavesNoFile() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raw = try scene.raw("DSC00001.ARW", size: 3 << 20)
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        var chunks = 0

        let outcome = KeeperCopy.copy(raw, into: scene.folder) {
            chunks += 1
            if chunks == 2 { truncate(raw.path, 2 << 20) }
            return false
        }

        #expect(outcome == .failed(.changedWhileRead))
        #expect(scene.contents.isEmpty)
    }

    @Test func stoppingMidFileLeavesNoFile() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raw = try scene.raw("DSC00001.ARW")
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        var sawPartial = false
        var chunks = 0

        let outcome = KeeperCopy.copy(raw, into: scene.folder) {
            chunks += 1
            sawPartial = sawPartial || !scene.partials.isEmpty
            return chunks == 2
        }

        #expect(outcome == nil)
        #expect(sawPartial)
        #expect(scene.contents.isEmpty)
    }

    @Test func stoppingWhileTheCopyIsReadBackLeavesNoFile() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raw = try scene.raw("DSC00001.ARW")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: 0)], ofItemAtPath: raw.path)
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        let rawDate = try #require(SourceStamp.of(raw)?.modified)
        var readBackChunks = 0

        let outcome = KeeperCopy.copy(raw, into: scene.folder) {
            guard let partial = scene.partials.first,
                  SourceStamp.of(scene.folder.appendingPathComponent(partial))?.modified == rawDate else { return false }
            readBackChunks += 1
            return readBackChunks == 2
        }

        #expect(outcome == nil)
        #expect(readBackChunks == 2)
        #expect(scene.contents.isEmpty)
    }

    @Test func theFirstProblemStopsTheRunBeforeTheRawsBehindIt() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let window = KeeperCopy.concurrentRaws
        let raws = try (1...(window + 4)).map { try scene.raw(String(format: "DSC%05d.ARW", $0), size: 1000) }
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        for raw in raws.prefix(window) { try Self.randomBytes(10).write(to: scene.copied(raw)) }
        let heard = Heard()

        let stopped = await #expect(throws: KeeperCopy.Stopped.self) {
            try await scene.copy(raws) { raw, outcome in await heard.add(raw, outcome) }
        }

        #expect(stopped?.raw == raws[0])
        #expect(stopped?.outcome == .conflict(existing: scene.copied(raws[0])))
        #expect(Set(await heard.raws) == Set(raws.prefix(window)))
        #expect(await heard.raws.count == window)
        #expect(scene.contents == raws.prefix(window).map(\.lastPathComponent).sorted())
    }

    @Test func aSecondImportCopiesOnlyTheNewRawsAndCountsEveryRaw() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raws = try (1...7).map { try scene.raw(String(format: "DSC%05d.ARW", $0), size: 1 << 20) }
        _ = try await scene.copy([raws[1], raws[4], raws[5]])
        let heard = Heard()

        let outcomes = try await scene.copy(raws) { raw, outcome in await heard.add(raw, outcome) }

        let expected: [KeeperCopy.Outcome] = try raws.enumerated().map { index, raw in
            [1, 4, 5].contains(index) ? .alreadyThere(sha256: try Self.sha256(raw)) : .copied(sha256: try Self.sha256(raw))
        }
        #expect(outcomes == expected)
        #expect(await heard.raws.count == raws.count)
        #expect(await heard.outcomes == Dictionary(uniqueKeysWithValues: zip(raws, expected)))
        for raw in raws { #expect(try Data(contentsOf: scene.copied(raw)) == Data(contentsOf: raw)) }
        #expect(scene.partials.isEmpty)
    }

    @Test func aMissingRawIsRefusedBeforeAnyWrite() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let missing = scene.card.appendingPathComponent("DSC00001.ARW")

        let failure = await #expect(throws: KeeperCopy.Failure.self) { try await KeeperCopy.run([missing], to: scene.folder) }

        guard case .unreadable = failure else {
            Issue.record("not unreadable: \(String(describing: failure))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: scene.folder.path))
    }

    @Test func aRawThatCannotBeReadStopsTheRunAndNamesIt() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let gone = scene.card.appendingPathComponent("DSC00001.ARW")
        let raws = [gone] + (try (2...6).map { try scene.raw(String(format: "DSC%05d.ARW", $0)) })

        let stopped = await #expect(throws: KeeperCopy.Stopped.self) { try await scene.copy(raws) }

        #expect(stopped?.raw == gone)
        guard case .failed(.unreadable) = stopped?.outcome else {
            Issue.record("not unreadable: \(String(describing: stopped))")
            return
        }
        #expect(scene.partials.isEmpty)
        for name in scene.contents {
            #expect(try Data(contentsOf: scene.folder.appendingPathComponent(name)) == Data(contentsOf: scene.card.appendingPathComponent(name)))
        }
    }

    @Test func aFolderOnTheRawsVolumeIsRefusedBeforeAnyWrite() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raw = try scene.raw("DSC00001.ARW")

        await #expect(throws: KeeperCopy.Failure.folderOnCard(scene.folder.path)) {
            try await KeeperCopy.run([raw], to: scene.folder)
        }
        #expect(!FileManager.default.fileExists(atPath: scene.folder.path))
        #expect(KeeperCopy.Failure.folderOnCard(scene.folder.path).description
            == "\(scene.folder.path) is on the same volume as the raws, which is never written")
    }

    /// Raws in a folder rather than on a card may be copied to their own disk when the caller says so.
    @Test func aFolderOnTheRawsVolumeIsAllowedForRawsInAFolder() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let raw = try scene.raw("DSC00001.ARW")
        let outcomes = try await KeeperCopy.run([raw], to: scene.folder, allowsRawsVolume: true)
        #expect(outcomes.count == 1)
        #expect(try Data(contentsOf: scene.folder.appendingPathComponent("DSC00001.ARW")) == Data(contentsOf: raw))
    }

    @Test func aFolderIsJudgedWhereTheKernelWouldMakeIt() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let elsewhere = scene.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = elsewhere.appendingPathComponent("cardlink").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: scene.card.path)
        let dcim = scene.root.appendingPathComponent("DCIM").path
        var info = stat()
        #expect(stat(dcim, &info) == 0)

        let throughLink = try KeeperCopy.realFolder(URL(fileURLWithPath: link + "/../keepers"))
        #expect(throughLink.path == dcim + "/keepers")
        #expect(throughLink.volume == info.st_dev)
        #expect(try KeeperCopy.realFolder(URL(fileURLWithPath: link + "/new/../../keepers")).path == dcim + "/keepers")
        #expect(try KeeperCopy.realFolder(URL(fileURLWithPath: scene.root.path + "/missing/../keepers")).path
            == scene.root.path + "/keepers")
    }

    @Test func twoRawsOfOneNameAreRefusedBeforeAnyWrite() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let next = scene.root.appendingPathComponent("DCIM/101MSDCF")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        let raws = [try scene.raw("DSC00001.ARW"), try scene.raw("DSC00001.ARW", in: next)]

        await #expect(throws: KeeperCopy.Failure.sameName("DSC00001.ARW")) { try await scene.copy(raws) }
        #expect(!FileManager.default.fileExists(atPath: scene.folder.path))
    }

    @Test func twoRawsWhoseNamesDifferOnlyInCaseAreRefusedBeforeAnyWrite() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let next = scene.root.appendingPathComponent("DCIM/101MSDCF")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        let raws = [try scene.raw("DSC00001.ARW"), try scene.raw("dsc00001.arw", in: next)]

        await #expect(throws: KeeperCopy.Failure.sameName("dsc00001.arw")) { try await scene.copy(raws) }
        #expect(!FileManager.default.fileExists(atPath: scene.folder.path))
    }
}

private actor Heard {
    private(set) var raws: [URL] = []
    private(set) var outcomes: [URL: KeeperCopy.Outcome] = [:]

    func add(_ raw: URL, _ outcome: KeeperCopy.Outcome) {
        raws.append(raw)
        outcomes[raw] = outcome
    }
}
