import ArgentCore
import CryptoKit
import Foundation
import Testing
@testable import ArgentRoll

/// The Subject models' download (`SubjectModelPack`): a file that is not the pinned one changes nothing, the real pack installs and `MaskModels` finds it
/// after the app's own folder, and removing it takes it all away.
@Suite(.serialized)
struct SubjectModelPackTests {
    static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-pack-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The archive `scripts/build-subject-models.zsh` made, if this checkout has one: `ARGENT_SUBJECT_PACK`, or `build/argent-subject-models-<version>.aar`.
    static var archive: URL {
        ProcessInfo.processInfo.environment["ARGENT_SUBJECT_PACK"].map { URL(fileURLWithPath: $0) }
            ?? MaskCanary.root.appendingPathComponent("build/argent-subject-models-\(SubjectModelPack.current.version).aar")
    }
    static var hasArchive: Bool { FileManager.default.fileExists(atPath: archive.path) }

    @Test func aFileThatIsNotThePinnedOneChangesNothing() async throws {
        let work = try Self.folder("wrong")
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = work.appendingPathComponent("fake.aar")
        try Data(repeating: 7, count: 4096).write(to: fake)
        let installed = work.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: installed.appendingPathComponent("marker"))

        // The right size and the wrong digest, then the wrong size.
        let wrongDigest = SubjectModelPack(version: 1, url: fake, bytes: 4096, sha256: String(repeating: "0", count: 64), installedBytes: 0)
        await #expect(throws: SubjectModelPack.Failure.self) { try await wrongDigest.install(into: installed) }
        let digest = try SubjectModelPack.sha256(of: fake)
        let wrongSize = SubjectModelPack(version: 1, url: fake, bytes: 4095, sha256: digest, installedBytes: 0)
        await #expect(throws: SubjectModelPack.Failure.self) { try await wrongSize.install(into: installed) }
        // The right digest and not an archive.
        let notAnArchive = SubjectModelPack(version: 1, url: fake, bytes: 4096, sha256: digest, installedBytes: 0)
        await #expect(throws: SubjectModelPack.Failure.self) { try await notAnArchive.install(into: installed) }

        let left = try FileManager.default.contentsOfDirectory(atPath: installed.path)
        #expect(left == ["marker"], "nothing installed, and no work folder left behind: \(left)")
    }

    @Test func noRoomIsSaidBeforeAnythingDownloads() async throws {
        let work = try Self.folder("room")
        defer { try? FileManager.default.removeItem(at: work) }
        let huge = SubjectModelPack(version: 1, url: work.appendingPathComponent("absent.aar"), bytes: 1 << 60, sha256: "", installedBytes: 1 << 60)
        await #expect {
            try await huge.install(into: work)
        } throws: { error in
            if case .noRoom = error as? SubjectModelPack.Failure { true } else { false }
        }
    }

    /// The real pack, pinned in this build: installed from its file, every Subject model is found there, after an empty app folder, and is the one the pins name;
    /// the licences come with it; installing again replaces it; removing it leaves nothing.
    @Test(.enabled(if: SubjectModelPackTests.hasArchive)) func thePinnedPackInstallsAndMaskModelsFindsIt() async throws {
        let work = try Self.folder("real")
        defer { try? FileManager.default.removeItem(at: work) }
        var pack = SubjectModelPack.current
        pack.url = Self.archive
        let installed = work.appendingPathComponent("Models", isDirectory: true)
        let steps = StepLog()
        try await pack.install(into: installed) { steps.add($0) }
        #expect(steps.all.first == .downloading(0) && steps.all.last == .done && steps.all.contains(.checking) && steps.all.contains(.unpacking))

        let models = MaskModels(directories: [work.appendingPathComponent("app-has-none"), installed], ledgerFile: work.appendingPathComponent("ledger.json"))
        #expect(models.isSubjectAvailable, "\(models.unavailable)")
        #expect(!models.isSkyAvailable, "DA3 is not in the pack")
        for model in SubjectModelPack.models {
            #expect(models.folder(of: model) == installed)
            #expect(try models.identity(of: model).canarySHA256 == model.canarySHA256)
        }
        let licences = installed.appendingPathComponent(SubjectModelPack.licencesFolder)
        #expect(FileManager.default.fileExists(atPath: licences.appendingPathComponent("DINOv3-LICENSE.md").path))
        #expect(FileManager.default.fileExists(atPath: licences.appendingPathComponent("ViTMatte-LICENSE-MIT.txt").path))

        try await pack.install(into: installed)
        #expect(models.isSubjectAvailable)
        let entries = try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted()
        #expect(entries == (SubjectModelPack.models.flatMap { [$0.fileName, $0.manifestName] } + [SubjectModelPack.licencesFolder]).sorted(), "\(entries)")

        try SubjectModelPack.remove(from: installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.path).isEmpty)
        #expect(!models.isSubjectAvailable)
    }

    /// The archive on disk is the one this build pins: what the owner uploads.
    @Test(.enabled(if: SubjectModelPackTests.hasArchive)) func theArchiveIsTheOneThisBuildPins() throws {
        let size = try FileManager.default.attributesOfItem(atPath: Self.archive.path)[.size] as? Int64
        #expect(size == SubjectModelPack.current.bytes)
        #expect(try SubjectModelPack.sha256(of: Self.archive) == SubjectModelPack.current.sha256)
    }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [SubjectModelPack.Step] = []
    func add(_ step: SubjectModelPack.Step) { lock.withLock { steps.append(step) } }
    var all: [SubjectModelPack.Step] { lock.withLock { steps } }
}
