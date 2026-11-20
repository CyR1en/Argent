import Foundation
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The base of docs/remove-plan.md in the roll's layer: recipe version 12, the pack's place beside a raw, the patch store's files
/// through the mechanics it shares with the masks' seeds, and the queue as far as a run that reaches the engine.
@Suite struct RemovalBaseTests {
    private func recipe(in folder: URL, manual: Bool = false) throws -> Recipe {
        let raw = folder.appendingPathComponent("frame.ARW")
        let frame = Frame(id: 0, url: raw, info: ARWFrameInfo())
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let baseline = AutomaticBaseline(sourceSHA256: String(repeating: "a", count: 64), stockID: stock.id,
            stockDigest: stock.digest, controls: RollControls(), aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        return try Recipe.make(frame: frame, byteCount: 3, stock: stock, stockDigest: stock.digest, roll: RollControls(),
                               own: FrameControls(), previous: nil,
                               manual: manual ? ManualEdit(adjustments: .identity, baseline: baseline) : nil)
    }

    private static func removal(_ byte: String = "ab") throws -> Removal {
        Removal(patch: try PatchRef(id: PatchID(hex: String(repeating: byte, count: 32))!, width: 512, height: 1328))
    }

    private func library() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-removal-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: the recipe

    @Test func aRemovalAnywhereRequiresVersion12AndNothingElseDoes() throws {
        let folder = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Recipe.currentVersion == 13)
        let original = try recipe(in: folder, manual: true)
        #expect(original.requiredVersion == 2, "a frame with nothing removed keeps the version it needed")
        let before = try original.encoded()
        #expect(!String(decoding: before, as: UTF8.self).contains("removals"))

        let baseline = try #require(original.manual?.baseline)
        let values = try ManualAdjustments.identity.settingRemovals([try Self.removal()])
        let edit = ManualEdit(adjustments: values, baseline: baseline)
        let render = try ManualRenderSettings(adjustments: values, referenceStops: 0)
        var current = original; current.manual = edit; current.render.manual = render
        var held = original; held.heldManual = edit
        var rendered = original; rendered.render.manual = render; rendered.manual = nil
        for var record in [current, held, rendered] {
            #expect(record.requiredVersion == 12)
            record.version = 12
            let read = try Recipe.decodeStrict(record.encoded())
            #expect(read == record)
            #expect(throws: Recipe.ReadFailure.unsupportedVersion(12)) { try Recipe.decodeStrict(record.encoded(), readerVersion: 11) }
            record.version = 11
            #expect(throws: Recipe.ReadFailure.invalid("a removal requires recipe version 12")) { try record.validate() }
        }
        current.version = 12
        #expect(try Recipe.decodeStrict(current.encoded()).manual?.adjustments.removals == values.removals)

        // A removal that is off is still in the record, and a vignette alone still needs only 11.
        var hidden = original
        hidden.heldManual = ManualEdit(adjustments: try .identity.settingRemovals([try Self.removal().setting(isOn: false)]), baseline: baseline)
        #expect(hidden.requiredVersion == 12)
        var vignette = original
        vignette.heldManual = ManualEdit(adjustments: .identity.settingLens(try LensSettings(arguments: "vignette=20")), baseline: baseline)
        #expect(vignette.requiredVersion == 11)
    }

    @Test func thePatchesTravelBesideTheRawUnderItsName() {
        let raw = URL(fileURLWithPath: "/rolls/day/DSC00601.ARW")
        #expect(RecipeStore.patchesBesideRaw(raw).lastPathComponent == "DSC00601.argentpatches")
        #expect(RecipeStore.patchesBesideRaw(raw).deletingLastPathComponent() == raw.deletingLastPathComponent())
        #expect(RecipeStore.masksBesideRaw(raw).lastPathComponent == "DSC00601.argentmasks")
    }

    // MARK: the store

    @Test func aPatchHasItsOwnFolderBesideTheSeedsAndTheStoreKnowsWhatItLacks() throws {
        let folder = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PatchStore(library: folder)
        let ref = try Self.removal("cd").patch, other = try Self.removal("ef").patch
        let file = store.url(for: ref.id)
        #expect(file.path.hasSuffix("Patches/v1/cd/" + ref.id.hex + ".argentpatch"))
        #expect(store.folder.deletingLastPathComponent().lastPathComponent == "Patches")
        #expect(!store.contains(ref.id) && store.missing([ref, other, ref]) == [ref, other])

        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        #expect(store.contains(ref.id) && store.missing([ref, other, ref]) == [ref, other])
    }

    @Test func theSweepTakesAnOldPatchNoRecordNamesAndLeavesTheRest() throws {
        let folder = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PatchStore(library: folder)
        let named = try Self.removal("11").patch.id, orphan = try Self.removal("22").patch.id, young = try Self.removal("33").patch.id
        let old = Date(timeIntervalSinceNow: -PatchStore.orphanAge - 60)
        for (id, date) in [(named, old), (orphan, old), (young, Date())] {
            let file = store.url(for: id)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        // A seed of the same name in the masks' store, and a stranger in the patches' folder, are not this store's to remove.
        let seeds = MaskRasterStore(library: folder)
        let seed = seeds.url(for: RasterID(hex: orphan.hex)!)
        try FileManager.default.createDirectory(at: seed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: seed)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: seed.path)
        let stranger = store.folder.appendingPathComponent("notes.txt")
        try Data([1]).write(to: stranger)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stranger.path)

        let removed = store.collectGarbage(keeping: [named])
        #expect(removed == [orphan.hex + ".argentpatch"])
        #expect(store.contains(named) && !store.contains(orphan) && store.contains(young))
        #expect(FileManager.default.fileExists(atPath: seed.path) && FileManager.default.fileExists(atPath: stranger.path))

        // Kept alive, an old patch counts as young.
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: store.url(for: young).path)
        store.keepAlive([young])
        #expect(store.collectGarbage(keeping: [named]).isEmpty)
    }

    // MARK: the queue and the previews

    @Test func aRunAskedOfTheQueueReachesTheEngine() async throws {
        let queue = RemovalQueue(engine: FakeRemovalEngine())
        #expect(queue.state == .idle)
        let job = try RemovalJob(width: 16, height: 16, image: [UInt8](repeating: 0, count: 16 * 16 * 3),
                                 mask: [UInt8](repeating: 255, count: 16 * 16), seed: 1)
        #expect(try await queue.run(job) { _ in }.engine == FakeRemovalEngine.engineID, "the queue is built: a run reaches the engine")
    }

    @Test func thePrintLimitsProbeKeysOnNoRemoval() throws {
        var settings = DevelopSettings()
        let removed = try ManualAdjustments(exposureEV: 0.5).settingRemovals([try Self.removal()])
        settings.manual = try ManualRenderSettings(adjustments: removed, referenceStops: 0)
        let probe = try #require(FilmPreviews.printLimitsProbe(settings))
        #expect(probe.manual.adjustments.removals.isEmpty && probe.manual.adjustments.exposureEV == 0.5)
        var plain = DevelopSettings()
        plain.manual = try ManualRenderSettings(adjustments: try ManualAdjustments(exposureEV: 0.5), referenceStops: 0)
        #expect(FilmPreviews.printLimitsProbe(plain) == probe, "one probe for a frame, whatever was removed from it")
    }
}
