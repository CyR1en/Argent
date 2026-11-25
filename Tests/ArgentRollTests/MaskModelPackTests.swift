import AppleArchive
import ArgentCore
import CryptoKit
import Foundation
import System
import Testing
@testable import ArgentRoll

/// The mask models' download (`MaskModelPack`): a file that is not the pinned one changes nothing, the real pack installs and `MaskModels` finds it
/// after the app's own folder, and removing it takes it all away.
@Suite(.serialized)
struct MaskModelPackTests {
    static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-pack-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The archive `scripts/build-mask-models.zsh` made, if this checkout has one: `ARGENT_MASK_PACK`, or `build/argent-mask-models-<version>.aar`.
    static var archive: URL {
        ProcessInfo.processInfo.environment["ARGENT_MASK_PACK"].map { URL(fileURLWithPath: $0) }
            ?? MaskCanary.root.appendingPathComponent("build/argent-mask-models-\(MaskModelPack.current.version).aar")
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
        let wrongDigest = MaskModelPack(version: 1, url: fake, bytes: 4096, sha256: String(repeating: "0", count: 64), installedBytes: 0)
        await #expect(throws: MaskModelPack.Failure.self) { try await wrongDigest.install(into: installed) }
        let digest = try MaskModelPack.sha256(of: fake)
        let wrongSize = MaskModelPack(version: 1, url: fake, bytes: 4095, sha256: digest, installedBytes: 0)
        await #expect(throws: MaskModelPack.Failure.self) { try await wrongSize.install(into: installed) }
        // The right digest and not an archive.
        let notAnArchive = MaskModelPack(version: 1, url: fake, bytes: 4096, sha256: digest, installedBytes: 0)
        await #expect(throws: MaskModelPack.Failure.self) { try await notAnArchive.install(into: installed) }

        let left = try FileManager.default.contentsOfDirectory(atPath: installed.path)
        #expect(left == ["marker"], "nothing installed, and no work folder left behind: \(left)")
    }

    @Test func noRoomIsSaidBeforeAnythingDownloads() async throws {
        let work = try Self.folder("room")
        defer { try? FileManager.default.removeItem(at: work) }
        let huge = MaskModelPack(version: 1, url: work.appendingPathComponent("absent.aar"), bytes: 1 << 60, sha256: "", installedBytes: 1 << 60)
        await #expect {
            try await huge.install(into: work)
        } throws: { error in
            if case .noRoom = error as? MaskModelPack.Failure { true } else { false }
        }
    }

    /// The real pack, pinned in this build: installed from its file, every model Subject and Sky need is found there, after an empty app folder, and is the one
    /// the pins name; the licences come with it, DA3's among them; installing again replaces it; removing it leaves nothing.
    @Test(.enabled(if: MaskModelPackTests.hasArchive)) func thePinnedPackInstallsAndMaskModelsFindsIt() async throws {
        let work = try Self.folder("real")
        defer { try? FileManager.default.removeItem(at: work) }
        var pack = MaskModelPack.current
        pack.url = Self.archive
        let installed = work.appendingPathComponent("Models", isDirectory: true)
        let steps = StepLog()
        try await pack.install(into: installed) { steps.add($0) }
        #expect(steps.all.first == .downloading(0) && steps.all.last == .done && steps.all.contains(.checking) && steps.all.contains(.unpacking))

        let models = MaskModels(directories: [work.appendingPathComponent("app-has-none"), installed], ledgerFile: work.appendingPathComponent("ledger.json"))
        #expect(models.isSubjectAvailable, "\(models.unavailable)")
        #expect(models.isSkyAvailable && models.unavailable.isEmpty, "DA3 is in the pack since version 2: \(models.unavailable)")
        #expect(Set(MaskModelPack.models) == Set(BundledMaskModel.allCases))
        for model in MaskModelPack.models {
            #expect(models.folder(of: model) == installed)
            #expect(try models.identity(of: model).canarySHA256 == model.canarySHA256)
        }
        let licences = installed.appendingPathComponent(MaskModelPack.licencesFolder)
        #expect(FileManager.default.fileExists(atPath: licences.appendingPathComponent("NOTICE.txt").path))
        #expect(FileManager.default.fileExists(atPath: licences.appendingPathComponent("DINOv3-LICENSE.md").path))
        #expect(FileManager.default.fileExists(atPath: licences.appendingPathComponent("ViTMatte-LICENSE-MIT.txt").path))
        #expect(FileManager.default.fileExists(atPath: licences.appendingPathComponent("DA3-LICENSE").path))
        #expect(!FileManager.default.fileExists(atPath: licences.appendingPathComponent("README.md").path))
        #expect(!FileManager.default.fileExists(atPath: licences.appendingPathComponent("ObjectClear-LICENSE-S-Lab-1.0.txt").path))

        try await pack.install(into: installed)
        #expect(models.isSubjectAvailable && models.isSkyAvailable)
        let entries = try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted()
        #expect(entries == (MaskModelPack.models.flatMap { [$0.fileName, $0.manifestName] } + [MaskModelPack.licencesFolder]).sorted(), "\(entries)")

        try MaskModelPack.remove(from: installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.path).isEmpty)
        #expect(!models.isSubjectAvailable && !models.isSkyAvailable)
    }

    /// The archive on disk is the one this build pins: what the owner uploads.
    @Test(.enabled(if: MaskModelPackTests.hasArchive)) func theArchiveIsTheOneThisBuildPins() throws {
        let size = try FileManager.default.attributesOfItem(atPath: Self.archive.path)[.size] as? Int64
        #expect(size == MaskModelPack.current.bytes)
        #expect(try MaskModelPack.sha256(of: Self.archive) == MaskModelPack.current.sha256)
    }

    // MARK: Synthetic archive helpers and tests

    /// Writes a synthetic pack directory, of `holding`, and archives it as an LZFSE `.aar` with Apple Archive.
    private static func makeSyntheticPack(in work: URL, name: String, tamper: BundledMaskModel? = nil, includeLicences: Bool = true,
                                          noticeText: String = "Built with DINOv3.\n",
                                          holding: [BundledMaskModel] = MaskModelPack.models) throws -> MaskModelPack {
        let stage = work.appendingPathComponent("stage-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for model in holding {
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
            let licences = stage.appendingPathComponent(MaskModelPack.licencesFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: licences, withIntermediateDirectories: true)
            try Data(noticeText.utf8).write(to: licences.appendingPathComponent("NOTICE.txt"))
        }
        let archive = work.appendingPathComponent("\(name).aar")
        try archiveDirectory(stage, to: archive)
        let size = try #require(FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64)
        let digest = try MaskModelPack.sha256(of: archive)
        return MaskModelPack(version: 1, url: archive, bytes: size, sha256: digest, installedBytes: 1024)
    }

    private static func archiveDirectory(_ directory: URL, to archive: URL) throws {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .writeOnly, options: [.create, .truncate],
                                                      permissions: FilePermissions(rawValue: 0o644)),
              let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file),
              let encoded = ArchiveStream.encodeStream(writingTo: compressed),
              let keys = ArchiveHeader.FieldKeySet("TYP,PAT,MOD,DAT") else {
            throw MaskModelPack.Failure.unpack("could not open synthetic archive streams")
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
            throw MaskModelPack.Failure.unpack("could not open custom archive streams")
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
        #expect(models.isSubjectAvailable && models.isSkyAvailable)
        let noticeURL = installed.appendingPathComponent(MaskModelPack.licencesFolder).appendingPathComponent("NOTICE.txt")
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v1")

        // Reinstalling replaces both Licences and models in place via replaceItemAt.
        let pack2 = try Self.makeSyntheticPack(in: work, name: "v2", noticeText: "notice v2")
        try await pack2.install(into: installed)
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v2")
        #expect(models.isSubjectAvailable)

        // A move that fails part way, the last old item locked in place: what went in comes out and every old item goes back.
        let manager = FileManager.default
        let last = try #require(MaskModelPack.models.last).manifestName
        let locked = installed.appendingPathComponent(last)
        try manager.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        let pack3 = try Self.makeSyntheticPack(in: work, name: "v3", noticeText: "notice v3")
        await #expect {
            try await pack3.install(into: installed)
        } throws: { error in
            if case .install = error as? MaskModelPack.Failure { true } else { false }
        }
        try manager.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v2", "the old licences are back")
        #expect(models.isSubjectAvailable)
        #expect(try manager.contentsOfDirectory(atPath: installed.path).filter { $0.hasPrefix(".install-") }.isEmpty)

        // A broken link where an item goes does not stop the install: it is set aside as any old copy is.
        let first = try #require(MaskModelPack.models.first).fileName
        try manager.removeItem(at: installed.appendingPathComponent(first))
        try manager.createSymbolicLink(atPath: installed.appendingPathComponent(first).path, withDestinationPath: "/nonexistent/argent-model")
        try await pack3.install(into: installed)
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v3")
        #expect(models.isSubjectAvailable)

        // Remove clears installed models, Licences, and any orphaned staging folders, while keeping unrelated files.
        let orphan2 = installed.appendingPathComponent(".install-after", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan2, withIntermediateDirectories: true)
        try MaskModelPack.remove(from: installed)
        #expect(!models.isSubjectAvailable && !models.isSkyAvailable)
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.path) == ["keep-me"])
    }

    /// Over version 1's three models, as a Mac that downloaded them before DA3 joined the pack holds them: Subject worked and Sky did not; the pack puts all
    /// four in place, and Sky works. A pack without DA3 is refused by this build, and what was installed stays.
    @Test func overVersionOnesThreeModelsThePackAddsSky() async throws {
        let work = try Self.folder("upgrade")
        defer { try? FileManager.default.removeItem(at: work) }
        let installed = work.appendingPathComponent("Models", isDirectory: true)
        let models = MaskModels(directories: [work.appendingPathComponent("empty-app"), installed], ledgerFile: work.appendingPathComponent("ledger.json"))

        // Version 1's content, put in place as version 1 put it: its three models and its licences.
        let old = try Self.makeSyntheticPack(in: work, name: "v1", noticeText: "notice v1", holding: MaskModels.subjectModels)
        let unpacked = work.appendingPathComponent("v1-unpacked", isDirectory: true)
        try MaskModelPack.extract(old.url, into: unpacked)
        try FileManager.default.moveItem(at: unpacked, to: installed)
        #expect(models.isSubjectAvailable && !models.isSkyAvailable)
        #expect(models.skyMissing?.description.contains(BundledMaskModel.sky.rawValue) == true, "Sky lacks DA3 alone: \(String(describing: models.skyMissing))")

        // This build takes no pack without DA3, and leaves what is installed alone.
        await #expect {
            try await old.install(into: installed)
        } throws: { error in
            if case .notThePinnedModel(let why) = error as? MaskModelPack.Failure { why.contains(BundledMaskModel.sky.rawValue) } else { false }
        }
        #expect(models.isSubjectAvailable && !models.isSkyAvailable)

        let new = try Self.makeSyntheticPack(in: work, name: "v2", noticeText: "notice v2")
        try await new.install(into: installed)
        #expect(models.isSubjectAvailable && models.isSkyAvailable && models.skyMissing == nil)
        #expect(models.folder(of: .sky) == installed)
        let notice = installed.appendingPathComponent(MaskModelPack.licencesFolder).appendingPathComponent("NOTICE.txt")
        #expect(try String(contentsOf: notice, encoding: .utf8) == "notice v2")
        let entries = try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted()
        #expect(entries == (MaskModelPack.models.flatMap { [$0.fileName, $0.manifestName] } + [MaskModelPack.licencesFolder]).sorted(), "\(entries)")
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
            if case .notThePinnedModel(let why) = error as? MaskModelPack.Failure {
                return why.contains("main.mlirb is not its main.hash")
            }
            return false
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.path) == ["marker"])

        let noLicences = try Self.makeSyntheticPack(in: work, name: "nolicences", includeLicences: false)
        await #expect {
            try await noLicences.install(into: installed)
        } throws: { error in
            if case .notThePinnedModel(let why) = error as? MaskModelPack.Failure {
                return why.contains(MaskModelPack.licencesFolder)
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
            try MaskModelPack.extract(symlinkArchive, into: work.appendingPathComponent("out-symlink", isDirectory: true))
        } throws: { error in
            if case .unpack = error as? MaskModelPack.Failure { true } else { false }
        }

        let traversalArchive = work.appendingPathComponent("traversal.aar")
        try Self.writeArchiveWithSingleEntry(to: traversalArchive, type: .regularFile, path: "../escaped.txt")
        let outTraversal = work.appendingPathComponent("out-traversal", isDirectory: true)
        #expect {
            try MaskModelPack.extract(traversalArchive, into: outTraversal)
        } throws: { error in
            if case .unpack = error as? MaskModelPack.Failure { true } else { false }
        }
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("escaped.txt").path))

        let absoluteArchive = work.appendingPathComponent("absolute.aar")
        try Self.writeArchiveWithSingleEntry(to: absoluteArchive, type: .regularFile, path: "/tmp/argent-should-not-write.txt")
        #expect {
            try MaskModelPack.extract(absoluteArchive, into: work.appendingPathComponent("out-absolute", isDirectory: true))
        } throws: { error in
            if case .unpack = error as? MaskModelPack.Failure { true } else { false }
        }
    }

    /// BundledSmartMasks reports `.unavailable` (not `.needsModels`) when a bundled model fails validation — even when another
    /// dependency is missing or a valid copy is in the downloadable folder — avoiding an unrecoverable download loop.
    @Test func invalidBundledModelDoesNotOfferDownloadLoop() throws {
        let work = try Self.folder("availability")
        defer { try? FileManager.default.removeItem(at: work) }
        let bundled = work.appendingPathComponent("Bundled", isDirectory: true)
        let downloaded = work.appendingPathComponent("Downloaded", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        try writeToyStock(id: "kodak-portra-400", in: work)
        let films = try FilmPreviews(stocks: StockLibrary.load(from: work).stocks, decoderChoices: DecoderChoices(route: .raw9))

        func write(_ model: BundledMaskModel, in folder: URL, canary: String? = nil) throws {
            let dir = folder.appendingPathComponent(model.fileName, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0xaa, count: 32).write(to: dir.appendingPathComponent("main.hash"))
            let manifest = ["recipe id": model.recipeID, "weights sha256": model.weightsSHA256, "canary output sha256": canary ?? model.canarySHA256]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent(model.manifestName))
        }

        // Valid downloaded models shadowed by an invalid bundled DA3: Sky is unavailable with rebuild guidance, never needsModels.
        for model in BundledMaskModel.allCases { try write(model, in: downloaded) }
        try write(.sky, in: bundled, canary: String(repeating: "0", count: 64))
        let models = MaskModels(directories: [bundled, downloaded], downloadableDirectory: downloaded, ledgerFile: work.appendingPathComponent("ledger.json"))
        let engine = BundledSmartMasks(films: films, models: models, app: "tests")
        if case .unavailable(let why) = engine.availability(of: .sky) {
            #expect(why.contains(BundledMaskModel.sky.rawValue) && why.contains(BundledMaskModel.sky.script), "\(why)")
        } else {
            Issue.record("expected .unavailable for bad bundled DA3, got \(engine.availability(of: .sky))")
        }
        #expect(engine.availability(of: .subject) == .available)

        // Missing DA3 + invalid bundled EoMT: Sky, Subject and Background all report .unavailable naming EoMT.
        try FileManager.default.removeItem(at: bundled.appendingPathComponent(BundledMaskModel.sky.fileName))
        try FileManager.default.removeItem(at: downloaded.appendingPathComponent(BundledMaskModel.sky.fileName))
        try write(.water, in: bundled, canary: String(repeating: "0", count: 64))
        for kind in [SmartKind.sky, .subject, .background] {
            if case .unavailable(let why) = engine.availability(of: kind) {
                #expect(why.contains(BundledMaskModel.water.rawValue), "\(kind): \(why)")
            } else {
                Issue.record("expected .unavailable for \(kind), got \(engine.availability(of: kind))")
            }
        }
    }

    /// Pack installation coordinated through `MaskInference.serialized` waits for an active Subject run to finish before moving
    /// v1 files aside, and holds back new inference until placement finishes; cancelling while waiting leaves v1 untouched.
    @Test func packPlacementCoordinatesWithActiveInference() async throws {
        let work = try Self.folder("coord")
        defer { try? FileManager.default.removeItem(at: work) }
        let installed = work.appendingPathComponent("Models", isDirectory: true)
        let old = try Self.makeSyntheticPack(in: work, name: "v1", noticeText: "notice v1", holding: MaskModels.subjectModels)
        let unpacked = work.appendingPathComponent("v1-unpacked", isDirectory: true)
        try MaskModelPack.extract(old.url, into: unpacked)
        try FileManager.default.moveItem(at: unpacked, to: installed)
        let new = try Self.makeSyntheticPack(in: work, name: "v2", noticeText: "notice v2")

        let dummyRaw = work.appendingPathComponent("DSC1.ARW")
        try Data("raw".utf8).write(to: dummyRaw)
        let frame = Frame(id: 0, url: dummyRaw, info: .init())
        let engine = BlockingMaskEngine()
        let inference = MaskInference(engine: engine, turns: DecodeTurns())

        // Start a Subject inference that holds the inference queue open.
        let asked = inference.ask(.subject, on: frame, sourceSHA256: String(repeating: "0", count: 64), lens: .default)
        await engine.waitUntilFinding()

        let installTask = Task {
            try await new.install(into: installed, coordinatePlacement: { place in
                try await inference.serialized(place)
            })
        }
        // Give install time to unpack, verify, and block on inference.serialized.
        try await Task.sleep(for: .milliseconds(150))
        let noticeURL = installed.appendingPathComponent(MaskModelPack.licencesFolder).appendingPathComponent("NOTICE.txt")
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v1", "v1 files must stay untouched while Subject inference runs")
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent(BundledMaskModel.subject.fileName).path))

        // Release Subject inference: placement runs next and installs v2.
        engine.releaseFind()
        _ = await asked.outcome.value
        try await installTask.value
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v2")
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent(BundledMaskModel.sky.fileName).path))
        #expect(engine.unloadedSkyCount >= 1)

        // While placement holds the inference queue, a new Subject click waits until placement finishes.
        let engine3 = BlockingMaskEngine()
        let inference3 = MaskInference(engine: engine3, turns: DecodeTurns())
        let enteredPlace = AsyncSignal()
        let finishPlace = DispatchSemaphore(value: 0)
        let holdingPlace = Task {
            try await inference3.serialized {
                enteredPlace.signal()
                finishPlace.wait()
            }
        }
        await enteredPlace.wait()
        let queuedAsk = inference3.ask(.subject, on: frame, sourceSHA256: String(repeating: "0", count: 64), lens: .default)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!engine3.hasEnteredFind, "inference must not start while placement holds the queue")
        finishPlace.signal()
        try await holdingPlace.value
        await engine3.waitUntilFinding()
        engine3.releaseFind()
        _ = await queuedAsk.outcome.value

        // Cancelling a second install while an inference holds the queue cancels immediately without touching installed models.
        let engine2 = BlockingMaskEngine()
        let inference2 = MaskInference(engine: engine2, turns: DecodeTurns())
        let asked2 = inference2.ask(.subject, on: frame, sourceSHA256: String(repeating: "0", count: 64), lens: .default)
        await engine2.waitUntilFinding()
        let pack3 = try Self.makeSyntheticPack(in: work, name: "v3", noticeText: "notice v3")
        let cancelledTask = Task {
            try await pack3.install(into: installed, coordinatePlacement: { place in
                try await inference2.serialized(place)
            })
        }
        try await Task.sleep(for: .milliseconds(150))
        cancelledTask.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledTask.value }
        #expect(try String(contentsOf: noticeURL, encoding: .utf8) == "notice v2", "cancelled install leaves v2 untouched")
        engine2.releaseFind()
        _ = await asked2.outcome.value
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var cont: CheckedContinuation<Void, Never>?

    func signal() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            signalled = true
            defer { cont = nil }
            return cont
        }
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { cont in
            let done: Bool = lock.withLock {
                if signalled { return true }
                self.cont = cont
                return false
            }
            if done { cont.resume() }
        }
    }
}

private final class BlockingMaskEngine: SmartMaskEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var findingCont: CheckedContinuation<Void, Never>?
    private var isFinding = false
    private var releaseCont: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var _unloadedSkyCount = 0

    var unloadedSkyCount: Int { lock.withLock { _unloadedSkyCount } }
    var hasEnteredFind: Bool { lock.withLock { isFinding } }

    func availability(of kind: SmartKind) -> SmartAvailability { .available }
    var pins: SmartModelPins { SmartModelPins() }
    func picture(of frame: Frame, lens: LensSettings, stopped: @escaping @Sendable () -> Bool) async -> SmartPictureHandle? {
        SmartPictureHandle(frame: frame.url, content: ())
    }
    func find(_ kind: SmartKind, on picture: SmartPictureHandle, frame: Frame, sourceSHA256: String,
              stage: @escaping @Sendable (SmartStage) -> Void) async throws -> (SmartResult, MaskFrame) {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            isFinding = true
            defer { findingCont = nil }
            return findingCont
        }
        waiter?.resume()
        await withCheckedContinuation { cont in
            let done: Bool = lock.withLock {
                if isReleased { return true }
                releaseCont = cont
                return false
            }
            if done { cont.resume() }
        }
        let provenance = RasterProvenance(engine: "test", engineRevision: "1", parameters: [:],
                                          operatingSystem: "test", app: "tests",
                                          input: .init(kind: "test", decoderVersion: "1", width: 4, height: 4, colorSpace: "sRGB", sourceSHA256: sourceSHA256),
                                          created: Date())
        return (.nothingFound(kind, provenance), try MaskFrame(orientation: 1, width: 4, height: 4, decoder: .raw9, lensCorrection: false))
    }
    func waitUntilFinding() async {
        await withCheckedContinuation { cont in
            let already: Bool = lock.withLock {
                if isFinding { return true }
                findingCont = cont
                return false
            }
            if already { cont.resume() }
        }
    }
    func releaseFind() {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            isReleased = true
            defer { releaseCont = nil }
            return releaseCont
        }
        cont?.resume()
    }
    func unloadSky() async -> Bool {
        lock.withLock { _unloadedSkyCount += 1 }
        return false
    }
    func releasePictures() {}
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [MaskModelPack.Step] = []
    func add(_ step: MaskModelPack.Step) { lock.withLock { steps.append(step) } }
    var all: [MaskModelPack.Step] { lock.withLock { steps } }
}
