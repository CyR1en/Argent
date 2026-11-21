import AppleArchive
import ArgentCore
import CryptoKit
import Foundation
import System
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
        #expect(FileManager.default.fileExists(atPath: licences.appendingPathComponent("NOTICE.txt").path))
        #expect(FileManager.default.fileExists(atPath: licences.appendingPathComponent("DINOv3-LICENSE.md").path))
        #expect(FileManager.default.fileExists(atPath: licences.appendingPathComponent("ViTMatte-LICENSE-MIT.txt").path))
        #expect(!FileManager.default.fileExists(atPath: licences.appendingPathComponent("README.md").path))
        #expect(!FileManager.default.fileExists(atPath: licences.appendingPathComponent("ObjectClear-LICENSE-S-Lab-1.0.txt").path))

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

    // MARK: Synthetic archive helpers and tests

    /// Writes a synthetic Subject pack directory and archives it as an LZFSE `.aar` with Apple Archive.
    private static func makeSyntheticPack(in work: URL, name: String, tamper: BundledMaskModel? = nil, includeLicences: Bool = true,
                                          noticeText: String = "Built with DINOv3.\n") throws -> SubjectModelPack {
        let stage = work.appendingPathComponent("stage-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for model in SubjectModelPack.models {
            let modelDir = stage.appendingPathComponent(model.fileName, isDirectory: true)
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            let weights = Data("synthetic-\(model.rawValue)-\(noticeText)".utf8)
            let hash = Data(SHA256.hash(data: weights))
            try hash.write(to: modelDir.appendingPathComponent("main.hash"))
            let written = tamper == model ? weights + Data([0xff]) : weights
            try written.write(to: modelDir.appendingPathComponent("main.mlirb"))
            let manifest: [String: String] = [
                "recipe id": model.recipeID,
                "weights sha256": model.weightsSHA256,
                "canary output sha256": model.canarySHA256,
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: stage.appendingPathComponent(model.manifestName))
        }
        if includeLicences {
            let licences = stage.appendingPathComponent(SubjectModelPack.licencesFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: licences, withIntermediateDirectories: true)
            try Data(noticeText.utf8).write(to: licences.appendingPathComponent("NOTICE.txt"))
        }
        let archive = work.appendingPathComponent("\(name).aar")
        try archiveDirectory(stage, to: archive)
        let size = try #require(FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64)
        let digest = try SubjectModelPack.sha256(of: archive)
        return SubjectModelPack(version: 1, url: archive, bytes: size, sha256: digest, installedBytes: 1024)
    }

    private static func archiveDirectory(_ directory: URL, to archive: URL) throws {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .writeOnly, options: [.create, .truncate],
                                                      permissions: FilePermissions(rawValue: 0o644)),
              let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file),
              let encoded = ArchiveStream.encodeStream(writingTo: compressed),
              let keys = ArchiveHeader.FieldKeySet("TYP,PAT,MOD,DAT") else {
            throw SubjectModelPack.Failure.unpack("could not open synthetic archive streams")
        }
        try encoded.writeDirectoryContents(archiveFrom: FilePath(directory.path), keySet: keys)
        try encoded.close()
        try compressed.close()
        try file.close()
    }

    /// Builds a tiny archive containing a single custom header (e.g. a symlink or a `..` traversal path).
    private static func writeArchiveWithSingleEntry(to archive: URL, type: ArchiveHeader.EntryType, path: String, linkTarget: String? = nil) throws {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .writeOnly, options: [.create, .truncate],
                                                      permissions: FilePermissions(rawValue: 0o644)),
              let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file),
              let encoded = ArchiveStream.encodeStream(writingTo: compressed) else {
            throw SubjectModelPack.Failure.unpack("could not open custom archive streams")
        }
        let header = ArchiveHeader()
        header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: UInt64(type.rawValue)))
        header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: path))
        if let linkTarget {
            header.append(.string(key: ArchiveHeader.FieldKey("LNK"), value: linkTarget))
        }
        if type == .regularFile {
            let payload = Data("payload".utf8)
            header.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(payload.count)))
            try encoded.writeHeader(header)
            try payload.withUnsafeBytes { try encoded.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: $0) }
        } else {
            try encoded.writeHeader(header)
        }
        try encoded.close()
        try compressed.close()
        try file.close()
    }

    @Test func syntheticPackInstallsReplacesAndSweepsStaging() async throws {
        let work = try Self.folder("synthetic")
        defer { try? FileManager.default.removeItem(at: work) }
        let installed = work.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        // An orphaned staging folder beside an unrelated marker: sweeping removes only `.install-*`.
        let orphan = installed.appendingPathComponent(".install-leftover", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: orphan.appendingPathComponent("pack.aar"))
        let marker = installed.appendingPathComponent("keep-me")
        try Data("keep".utf8).write(to: marker)

        let pack1 = try Self.makeSyntheticPack(in: work, name: "v1", noticeText: "notice v1")
        let steps = StepLog()
        try await pack1.install(into: installed) { steps.add($0) }
        #expect(steps.all.first == .downloading(0) && steps.all.last == .done)
        #expect(steps.all.contains(.checking) && steps.all.contains(.unpacking))
        #expect(!FileManager.default.fileExists(atPath: orphan.path), "install sweeps orphaned .install-* folders")
        #expect(FileManager.default.fileExists(atPath: marker.path), "unrelated files stay untouched")

        let models = MaskModels(directories: [work.appendingPathComponent("empty-app"), installed], ledgerFile: work.appendingPathComponent("ledger.json"))
        #expect(models.isSubjectAvailable)
        let noticeURL = installed.appendingPathComponent(SubjectModelPack.licencesFolder).appendingPathComponent("NOTICE.txt")
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v1")

        // Reinstalling replaces both Licences and models in place via replaceItemAt.
        let pack2 = try Self.makeSyntheticPack(in: work, name: "v2", noticeText: "notice v2")
        try await pack2.install(into: installed)
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v2")
        #expect(models.isSubjectAvailable)

        // A move that fails part way, the last old item locked in place: what went in comes out and every old item goes back.
        let manager = FileManager.default
        let last = try #require(SubjectModelPack.models.last).manifestName
        let locked = installed.appendingPathComponent(last)
        try manager.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        let pack3 = try Self.makeSyntheticPack(in: work, name: "v3", noticeText: "notice v3")
        await #expect {
            try await pack3.install(into: installed)
        } throws: { error in
            if case .install = error as? SubjectModelPack.Failure { true } else { false }
        }
        try manager.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v2", "the old licences are back")
        #expect(models.isSubjectAvailable)
        #expect(try manager.contentsOfDirectory(atPath: installed.path).filter { $0.hasPrefix(".install-") }.isEmpty)

        // A broken link where an item goes does not stop the install: it is set aside as any old copy is.
        let first = try #require(SubjectModelPack.models.first).fileName
        try manager.removeItem(at: installed.appendingPathComponent(first))
        try manager.createSymbolicLink(atPath: installed.appendingPathComponent(first).path, withDestinationPath: "/nonexistent/argent-model")
        try await pack3.install(into: installed)
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v3")
        #expect(models.isSubjectAvailable)

        // Remove clears installed models, Licences, and any orphaned staging folders, while keeping unrelated files.
        let orphan2 = installed.appendingPathComponent(".install-after", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan2, withIntermediateDirectories: true)
        try SubjectModelPack.remove(from: installed)
        #expect(!models.isSubjectAvailable)
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.path) == ["keep-me"])
    }

    @Test func tamperedModelAndMissingLicencesFailAndLeaveNothingInstalled() async throws {
        let work = try Self.folder("tampered")
        defer { try? FileManager.default.removeItem(at: work) }
        let installed = work.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: installed.appendingPathComponent("marker"))

        let tampered = try Self.makeSyntheticPack(in: work, name: "tampered", tamper: .subject)
        await #expect {
            try await tampered.install(into: installed)
        } throws: { error in
            if case .notThePinnedModel(let why) = error as? SubjectModelPack.Failure {
                return why.contains("main.mlirb is not its main.hash")
            }
            return false
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.path) == ["marker"])

        let noLicences = try Self.makeSyntheticPack(in: work, name: "nolicences", includeLicences: false)
        await #expect {
            try await noLicences.install(into: installed)
        } throws: { error in
            if case .notThePinnedModel(let why) = error as? SubjectModelPack.Failure {
                return why.contains(SubjectModelPack.licencesFolder)
            }
            return false
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.path) == ["marker"])
    }

    @Test func disallowedArchiveEntriesFailUnpack() throws {
        let work = try Self.folder("disallowed")
        defer { try? FileManager.default.removeItem(at: work) }

        let symlinkArchive = work.appendingPathComponent("symlink.aar")
        try Self.writeArchiveWithSingleEntry(to: symlinkArchive, type: .link, path: "Licences", linkTarget: "/tmp")
        #expect {
            try SubjectModelPack.extract(symlinkArchive, into: work.appendingPathComponent("out-symlink", isDirectory: true))
        } throws: { error in
            if case .unpack = error as? SubjectModelPack.Failure { true } else { false }
        }

        let traversalArchive = work.appendingPathComponent("traversal.aar")
        try Self.writeArchiveWithSingleEntry(to: traversalArchive, type: .regularFile, path: "../escaped.txt")
        let outTraversal = work.appendingPathComponent("out-traversal", isDirectory: true)
        #expect {
            try SubjectModelPack.extract(traversalArchive, into: outTraversal)
        } throws: { error in
            if case .unpack = error as? SubjectModelPack.Failure { true } else { false }
        }
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("escaped.txt").path))

        let absoluteArchive = work.appendingPathComponent("absolute.aar")
        try Self.writeArchiveWithSingleEntry(to: absoluteArchive, type: .regularFile, path: "/tmp/argent-should-not-write.txt")
        #expect {
            try SubjectModelPack.extract(absoluteArchive, into: work.appendingPathComponent("out-absolute", isDirectory: true))
        } throws: { error in
            if case .unpack = error as? SubjectModelPack.Failure { true } else { false }
        }
    }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [SubjectModelPack.Step] = []
    func add(_ step: SubjectModelPack.Step) { lock.withLock { steps.append(step) } }
    var all: [SubjectModelPack.Step] { lock.withLock { steps } }
}
