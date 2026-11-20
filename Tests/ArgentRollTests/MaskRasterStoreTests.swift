import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ArgentRoll

/// A roll folder with one raw, a library of its own and recipes whose smart masks name seeds, for the store, the writer and the
/// develop. Every test has a temporary root of its own and never reaches Application Support or Caches.
private struct SeedScene {
    let root: URL
    let library: URL
    let roll: URL
    let frame: Frame
    let stock: Stock
    let sha: String
    let digests: SourceDigests
    let writer: RecipeWriter
    let controls = RollControls()

    init(rawBytes: UInt8 = 71) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentSeeds-\(UUID().uuidString)")
        library = root.appendingPathComponent("library", isDirectory: true)
        roll = root.appendingPathComponent("roll", isDirectory: true)
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        let raw = roll.appendingPathComponent("frame.ARW")
        try Data(repeating: rawBytes, count: 4096).write(to: raw)
        frame = Self.frame(raw)
        stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                      exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        digests = SourceDigests(settle: 0)
        sha = try digests.digest(of: raw).sha256
        writer = RecipeWriter(digests: digests)
    }

    static func frame(_ url: URL, id: Int = 0) -> Frame { Frame(id: id, url: url, info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1000))) }

    var store: MaskRasterStore { MaskRasterStore(library: library) }
    var sidecar: URL { RecipeStore.besideRaw(frame.url) }
    var pack: URL { RecipeStore.masksBesideRaw(frame.url) }

    func baseline(sha override: String? = nil) -> AutomaticBaseline {
        AutomaticBaseline(sourceSHA256: override ?? sha, stockID: stock.id, stockDigest: stock.digest, controls: controls, aim: PrintAim(),
                          analysisVersion: ExposureAnalysis.currentVersion,
                          baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
    }

    /// A recipe whose edit holds `masks` (none for `nil`), and `held` as its held edit, at `revision`.
    func recipe(_ masks: MaskSet?, held: MaskSet? = nil, revision: UInt64, for frame: Frame? = nil, sha override: String? = nil) throws -> Recipe {
        let frame = frame ?? self.frame
        let manual = try masks.map { ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.2, masks: $0), baseline: baseline(sha: override)) }
        let heldEdit = try held.map { ManualEdit(adjustments: try ManualAdjustments(masks: $0), baseline: baseline(sha: String(repeating: "0", count: 64))) }
        var recipe = try Recipe.make(frame: frame, byteCount: 4096, stock: stock, stockDigest: stock.digest, roll: controls, own: FrameControls(),
                                     analysis: ExposureAnalysis(meanStops: -0.3, validWeight: 1), aim: PrintAim(), grain: .off,
                                     manual: manual, editRevision: revision, editLineage: "seed-lineage", heldManual: heldEdit)
        recipe.raw.sha256 = override ?? sha
        return recipe
    }

    func temporaries() -> [String] {
        let walker = FileManager.default.enumerator(at: store.folder, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).map(\.lastPathComponent).filter { $0.hasPrefix(".tmp-") }
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roll.path)
        MaskWriteFaults.shared.clear(library: library)
        try? FileManager.default.removeItem(at: root)
    }
}

/// A seed of `width` by `height`, its pixels set by `n`, so two seeds of different `n` have different names.
private func seed(_ n: Int, width: Int = 64, height: Int = 48) throws -> MaskRaster {
    try MaskRaster(width: width, height: height, plane: (0..<(width * height)).map { UInt8(truncatingIfNeeded: ($0 % width) * 3 + ($0 / width) + n * 37) })
}

/// One Sky mask on `ref`, with an Exposure that changes pixels, so a render reads it.
private func sky(_ ref: RasterRef?, enabled: Bool = true, exposure: Float = -0.7) throws -> MaskSet {
    let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
    let selection = SmartSelection(kind: .sky, raster: ref, frame: ref == nil ? nil : frame)
    return try MaskSet(masks: [Mask(isEnabled: enabled, components: [MaskComponent(shape: .smart(selection))],
                                    adjustments: try ManualAdjustments(exposureEV: exposure))])
}

/// One mask of a Follow edges stroke whose measured shape is `shape`, as a Paint Mask leaves it.
private func stroked(_ shape: RasterRef) throws -> MaskSet {
    let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
    let stroke = BrushStroke(followEdges: true, radius: 0.02, points: try PackedPoints.pack([MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.25, y: 0.21)]),
                             measured: try MeasuredStroke(raster: shape, x: 100, y: 200, pictureWidth: 7008, pictureHeight: 4672))
    return try MaskSet(masks: [Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: frame, strokes: [stroke])))],
                                    adjustments: try ManualAdjustments(exposureEV: 0.5))])
}

private func age(_ url: URL, days: Double) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Suite struct MaskRasterStoreTests {
    /// A seed is an 8-bit gray PNG at its own size, in the library's `Masks/v1`, named by its pixels: a file encoded another way that
    /// holds the same pixels is the same seed, and storing it again writes nothing new.
    @Test func aSeedIsAnEightBitGrayPNGInTheLibraryNamedByItsPixels() throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let raster = try seed(1, width: 300, height: 200)
        let ref = try scene.store.store(raster)
        #expect(ref == raster.ref && ref.width == 300 && ref.height == 200)
        let file = scene.store.url(for: ref.id)
        #expect(file.path.hasPrefix(scene.library.appendingPathComponent("Masks/v1/\(ref.id.hex.prefix(2))").path))
        let png = try Data(contentsOf: file)
        // IHDR: bit depth at byte 24, colour type at 25 (0, gray).
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) && png[24] == 8 && png[25] == 0)
        #expect(try scene.store.load(ref) == raster)
        #expect(try scene.store.store(raster) == ref)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [file.lastPathComponent])
        // Interlaced: other bytes, the same pixels, the same seed.
        let provider = try #require(CGDataProvider(data: Data(raster.plane) as CFData))
        let image = try #require(CGImage(width: 300, height: 200, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 300,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let other = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(other, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 1]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(other as Data != png)
        try (other as Data).write(to: file)
        #expect(try scene.store.load(ref) == raster)
        // At the cap.
        let large = try MaskRaster(width: 4096, height: 16, plane: [UInt8](repeating: 200, count: 4096 * 16))
        #expect(try scene.store.load(try scene.store.store(large)) == large)
    }

    /// A seed whose file is gone, empty, cut short or holding other pixels is refused, never rendered as something else; storing
    /// the seed again mends the file.
    @Test func aDamagedOrMissingSeedIsRefusedAndStoringItAgainMendsIt() throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let raster = try seed(2), other = try seed(3)
        let ref = try scene.store.store(raster), file = scene.store.url(for: ref.id)
        let png = try Data(contentsOf: file)
        try png.prefix(png.count / 2).write(to: file)
        #expect(throws: MaskRasterStore.Failure.damaged(ref.id)) { try scene.store.load(ref) }
        try Data(contentsOf: scene.store.url(for: try scene.store.store(other).id)).write(to: file)
        #expect(throws: MaskRasterStore.Failure.damaged(ref.id)) { try scene.store.load(ref) }
        #expect(throws: MaskRasterStore.Failure.damaged(ref.id)) { try scene.store.load(try RasterRef(id: ref.id, width: 48, height: 64)) }
        try scene.store.store(raster)
        #expect(try scene.store.load(ref) == raster)
        try Data().write(to: file)
        #expect(!scene.store.contains(ref.id) && scene.store.missing([ref, ref]) == [ref])
        #expect(throws: MaskRasterStore.Failure.missing(ref.id)) { try scene.store.load(ref) }
        try FileManager.default.removeItem(at: file)
        #expect(throws: MaskRasterStore.Failure.missing(ref.id)) { try scene.store.load(ref) }
        #expect(throws: MaskRasterStore.Failure.missing(ref.id)) { try scene.store.seeds([ref]) }
        #expect(MaskRasterStore.Failure.missing(ref.id).description == "A mask’s selection (\(ref.id.hex.prefix(12))) is missing from the library")
    }

    /// The sweep keeps every seed a record names, current or held, every seed an undo step names, and every file younger than its
    /// age; a receipt keeps only a digest, so the seed of a develop's old revision goes once nothing else names it.
    @Test func theSweepKeepsLiveHeldUndoneAndYoungSeedsAndRemovesOldOrphans() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let live = try scene.store.store(try seed(10)), held = try scene.store.store(try seed(11)), undone = try scene.store.store(try seed(12))
        let young = try scene.store.store(try seed(13)), old = try scene.store.store(try seed(14)), developed = try scene.store.store(try seed(15))
        var first = try scene.recipe(try sky(developed), revision: 1)
        first = try await scene.writer.commit(recipe: first, for: scene.frame, library: scene.library)
        // Developed at revision 1, then edited to name another seed: the receipt keeps the old render as a digest.
        first.develops.append(.init(date: Date(timeIntervalSince1970: 2000), software: "Argent test", output: OutputSettings(),
            file: scene.root.appendingPathComponent("out.jpg").path, width: 40, height: 20, render: first.render, decode: nil, readback: nil,
            stockDigest: scene.stock.digest, renderVersion: RenderGraph.version(for: first.render.settings)))
        var second = try scene.recipe(try sky(live), held: try sky(held), revision: 2)
        second.develops = first.develops
        _ = try await scene.writer.commit(recipe: second, for: scene.frame, library: scene.library)
        for ref in [live, held, undone, old, developed] { try age(scene.store.url(for: ref.id), days: 8) }
        let stray = scene.store.folder.appendingPathComponent(".tmp-0000-stray.png"), fresh = scene.store.folder.appendingPathComponent(".tmp-1111-fresh.png")
        try Data([1]).write(to: stray); try Data([1]).write(to: fresh)
        try age(stray, days: 2)
        #expect(try MaskRasterStore.namedRasters(in: scene.library) == [live.id, held.id])
        let sweep = MaskRasterStore.sweep(library: scene.library, keeping: [undone.id])
        #expect(sweep.skipped == nil)
        #expect(Set(sweep.removed) == [old.id.hex + ".png", developed.id.hex + ".png", stray.lastPathComponent])
        for ref in [live, held, undone, young] { #expect(scene.store.contains(ref.id)) }
        #expect(!scene.store.contains(old.id) && !scene.store.contains(developed.id) && exists(fresh))
        // Without the undo step, the seed it named goes too.
        #expect(MaskRasterStore.sweep(library: scene.library).removed == [undone.id.hex + ".png"])
    }

    /// A Follow edges stroke's measured shape is a seed to the sweep: kept while a record names it (a current edit or a held one), an undo step
    /// or its youth keep it, and it goes once nothing does.
    @Test func theSweepKeepsAStrokesShapeWhileARecordNamesItAndDropsItAfter() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let live = try scene.store.store(try seed(20, width: 80, height: 40)), held = try scene.store.store(try seed(21, width: 80, height: 40))
        let undone = try scene.store.store(try seed(22, width: 80, height: 40)), old = try scene.store.store(try seed(23, width: 80, height: 40))
        _ = try await scene.writer.commit(recipe: try scene.recipe(try stroked(live), held: try stroked(held), revision: 1), for: scene.frame, library: scene.library)
        #expect(try MaskRasterStore.namedRasters(in: scene.library) == [live.id, held.id])
        #expect(RecipeWriter.rasterRefs(of: try scene.recipe(try stroked(live), held: try stroked(held), revision: 2)) == [live, held])
        for ref in [live, held, undone, old] { try age(scene.store.url(for: ref.id), days: 8) }
        #expect(Set(MaskRasterStore.sweep(library: scene.library, keeping: [undone.id]).removed) == [old.id.hex + ".png"])
        for ref in [live, held, undone] { #expect(scene.store.contains(ref.id)) }
        #expect(!scene.store.contains(old.id))
        // The stroke deleted and the session's history gone: nothing names its shape, and it goes.
        _ = try await scene.writer.commit(recipe: try scene.recipe(.empty, revision: 2), for: scene.frame, library: scene.library)
        for ref in [live, held, undone] { try age(scene.store.url(for: ref.id), days: 8) }
        #expect(Set(MaskRasterStore.sweep(library: scene.library).removed) == Set([live, held, undone].map { $0.id.hex + ".png" }))
    }

    /// A record this build cannot read may name any seed, so the sweep removes nothing.
    @Test func aRecordThisBuildCannotReadStopsTheSweep() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let orphan = try scene.store.store(try seed(20))
        try age(scene.store.url(for: orphan.id), days: 30)
        let saved = try await scene.writer.commit(recipe: try scene.recipe(nil, revision: 1), for: scene.frame, library: scene.library)
        let journal = RecipeWriter.journalURL(sha256: scene.sha, lineage: try #require(saved.editLineage), library: scene.library)
        let text = String(decoding: try Data(contentsOf: journal), as: UTF8.self)
        try Data(text.replacingOccurrences(of: "\"version\" : \(saved.version)", with: "\"version\" : 99").utf8).write(to: journal)
        let sweep = MaskRasterStore.sweep(library: scene.library)
        #expect(sweep.skipped != nil && sweep.removed.isEmpty && scene.store.contains(orphan.id))
    }

    @Test func aDamagedPackIsRewrittenFromTheLibrary() throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let made = try seed(30)
        let ref = try scene.store.store(made)
        let pack = scene.root.appendingPathComponent("repair.argentmasks")
        try scene.store.writePack([ref], to: pack)
        var bytes = try Data(contentsOf: pack)
        bytes[bytes.count - 30] ^= 0xFF
        try bytes.write(to: pack)

        try scene.store.writePack([ref], to: pack)
        let fresh = MaskRasterStore(library: scene.root.appendingPathComponent("fresh"))
        let result = try fresh.importPack(from: pack)
        #expect(result.damaged.isEmpty)
        #expect(result.added == [ref.id])
        #expect(try fresh.load(ref) == made)
    }

    @Test(arguments: [false, true]) func anUnchangedPackKeepsItsModificationDate(empty: Bool) throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let refs = empty ? [] : [try scene.store.store(try seed(31))]
        let pack = scene.root.appendingPathComponent("unchanged.argentmasks")
        try scene.store.writePack(refs, to: pack)
        try age(pack, days: 1)
        let written = try #require(try URL(fileURLWithPath: pack.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try scene.store.writePack(refs, to: pack)
        #expect(try #require(try URL(fileURLWithPath: pack.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) == written)
    }

    /// A pack is the library's files, in one file: read back by its header, refused when it is not one, and an entry that does not hold
    /// the pixels its id names is left out of an import, never kept.
    @Test func aPackHoldsItsSeedsAndADamagedEntryIsLeftOut() throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let a = try seed(30), b = try seed(31, width: 120, height: 80)
        let refs = [try scene.store.store(a), try scene.store.store(b)]
        let pack = scene.root.appendingPathComponent("p.argentmasks")
        try scene.store.writePack(refs + [refs[0]], to: pack)
        let entries = try #require(try MaskRasterStore.packEntries(at: pack))
        #expect(entries.map(\.id) == refs.map(\.id))
        let other = MaskRasterStore(library: scene.root.appendingPathComponent("other"))
        #expect(try other.importPack(from: pack, wanted: [refs[1].id]).added == [refs[1].id])
        #expect(try other.importPack(from: pack).added == [refs[0].id])
        #expect(try other.load(refs[0]) == a && other.load(refs[1]) == b)
        // Written again with the same seeds, it is left as it is.
        let written = try #require(try pack.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try age(pack, days: 1)
        try scene.store.writePack(refs, to: pack)
        #expect(try #require(try URL(fileURLWithPath: pack.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) < written)
        // A byte of the second PNG changed: that entry is damaged, and the first still comes in.
        var bytes = try Data(contentsOf: pack)
        bytes[bytes.count - 30] ^= 0xFF
        try bytes.write(to: pack)
        let third = MaskRasterStore(library: scene.root.appendingPathComponent("third"))
        let result = try third.importPack(from: pack)
        #expect(result.added == [refs[0].id] && result.damaged == [refs[1].id] && !third.contains(refs[1].id))
        try Data("not a pack".utf8).write(to: pack)
        #expect(throws: MaskRasterStore.Failure.notAPack("p.argentmasks")) { try third.importPack(from: pack) }
        #expect(try MaskRasterStore.packEntries(at: scene.root.appendingPathComponent("none.argentmasks")) == nil)
    }

    @Test func aDevelopHoldsTheSeedsOfMasksThatAreOnAndCountsThem() throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let a = try scene.store.store(try seed(40, width: 200, height: 100)), b = try scene.store.store(try seed(41))
        let on = try sky(a), off = try sky(b, enabled: false)
        var masks = try on.appending(off.masks[0])
        masks = try masks.appending(on.masks[0].withID(UUID()))
        let settings = try scene.recipe(masks, revision: 1).render.settings
        let needs = MaskSeeds.needs(settings.manual)
        #expect(needs.rasters == [a] && needs.pending.isEmpty)
        let seeds = try scene.store.seeds(needs.rasters)
        #expect(seeds[a] != nil && seeds[b] == nil && seeds.byteCount == 200 * 100)
        #expect(DevelopBudget.maskCost(settings: settings, width: 7008, height: 4672) >= 200 * 100)
        // A selection not made yet on a mask that is on; a mask set whose sliders change nothing needs nothing.
        #expect(MaskSeeds.needs(try scene.recipe(try sky(nil), revision: 1).render.settings.manual).pending == [.sky])
        #expect(MaskSeeds.needs(try scene.recipe(try sky(a, exposure: 0), revision: 1).render.settings.manual).isEmpty)
    }
}

@Suite struct MaskSeedWriterTests {
    @Test(arguments: ["absent", "sound", "damaged"], ["absent", "sound", "damaged"])
    func loadingRestoresOnlyMissingOrDamagedLocalBlobsFromSoundPacks(packState: String, localState: String) async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let made = try seed(73)
        let ref = try scene.store.store(made)
        _ = try await scene.writer.commit(recipe: try scene.recipe(try sky(ref), revision: 1), for: scene.frame, library: scene.library)
        let file = scene.store.url(for: ref.id)
        let original = try Data(contentsOf: file)
        let garbage = Data(repeating: 0xA5, count: original.count)
        if localState == "absent" {
            try FileManager.default.removeItem(at: file)
        } else if localState == "damaged" {
            try garbage.write(to: file)
        }
        if packState == "absent" {
            try FileManager.default.removeItem(at: scene.pack)
        } else if packState == "damaged" {
            var bytes = try Data(contentsOf: scene.pack)
            bytes.replaceSubrange((bytes.count - original.count)..<bytes.count, with: garbage)
            try bytes.write(to: scene.pack)
        }
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(loaded != nil)
        if localState == "sound" || packState == "sound" {
            #expect(try scene.store.load(ref) == made)
            #expect(try Data(contentsOf: file) == original)
        } else {
            #expect(throws: (any Error).self) { try scene.store.load(ref) }
            if localState == "damaged" {
                #expect(try Data(contentsOf: file) == garbage)
            } else {
                #expect(!FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    @Test(arguments: ["absent", "sound", "damaged"])
    func loadingWithAReadOnlyLibraryIsBestEffort(localState: String) async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let made = try seed(74)
        let ref = try scene.store.store(made)
        _ = try await scene.writer.commit(recipe: try scene.recipe(try sky(ref), revision: 1), for: scene.frame, library: scene.library)
        let file = scene.store.url(for: ref.id)
        let directory = file.deletingLastPathComponent()
        if localState == "absent" {
            try FileManager.default.removeItem(at: file)
        } else if localState == "damaged" {
            try Data([0xA5]).write(to: file)
        }
        let before = try? Data(contentsOf: file)
        if before != nil {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        #expect(!FileManager.default.isWritableFile(atPath: directory.path))
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(loaded != nil)
        #expect((try? Data(contentsOf: file)) == before)
        if localState == "sound" {
            #expect(try scene.store.load(ref) == made)
        } else {
            #expect(throws: (any Error).self) { try scene.store.load(ref) }
        }
    }

    /// The writer refuses a record naming a seed that is nowhere, before it writes anything: no journal, binding, sidecar or pack.
    @Test func aRecordNamingAMissingSeedIsRefusedAndNothingIsWritten() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let absent = try seed(50).ref
        do {
            _ = try await scene.writer.commit(recipe: try scene.recipe(try sky(absent), revision: 1), for: scene.frame, library: scene.library)
            Issue.record("A record naming a missing seed was written")
        } catch RecipeWriter.Failure.missingRaster(let id) {
            #expect(id == absent.id)
        }
        #expect(!exists(scene.library.appendingPathComponent("ManualDevelopment")) && !exists(scene.sidecar) && !exists(scene.pack))
        // A held edit's seed counts as much.
        do {
            _ = try await scene.writer.commit(recipe: try scene.recipe(nil, held: try sky(absent), revision: 1), for: scene.frame, library: scene.library)
            Issue.record("A record whose held edit names a missing seed was written")
        } catch RecipeWriter.Failure.missingRaster {}
        #expect(!exists(scene.library.appendingPathComponent("ManualDevelopment")) && !exists(scene.sidecar))
        #expect(RecipeWriter.Failure.missingRaster(absent.id).localizedDescription.contains("not in the library"))
    }

    /// A commit writes the journal, then the pack beside the raw, then the sidecar; a pack no sidecar names any more goes.
    @Test func aCommitWritesThePackBeforeTheSidecarAndRemovesAPackNoLongerNamed() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let ref = try scene.store.store(try seed(51))
        let saved = try await scene.writer.commit(recipe: try scene.recipe(try sky(ref), revision: 1), for: scene.frame, library: scene.library)
        #expect(saved.version == 6 && exists(scene.sidecar))
        #expect(try MaskRasterStore.packEntries(at: scene.pack)?.map(\.id) == [ref.id])
        let journal = RecipeWriter.journalURL(sha256: scene.sha, lineage: try #require(saved.editLineage), library: scene.library)
        #expect(try Recipe.decodeStrict(Data(contentsOf: journal)).manual?.adjustments.masks.rasters == [ref])
        _ = try await scene.writer.commit(recipe: try scene.recipe(nil, revision: 2), for: scene.frame, library: scene.library)
        #expect(!exists(scene.pack) && exists(scene.sidecar))
    }

    /// Each point of R6 section 4.3 at which a crash can stop a save, stood in for by a failure there: what is left is either the old
    /// state or the new, never a record naming a seed that is nowhere, and the next load or sweep tidies the rest.
    @Test func everyCrashPointLeavesNoRecordNamingNothing() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let faults = MaskWriteFaults.shared
        // 1. During the seed's write: a `.tmp-*` and no seed, so the record that would name it is refused. The sweep removes it a day on.
        let first = try seed(60)
        faults.inject(.rasterBeforeRename, library: scene.library)
        #expect(throws: MaskWriteFaults.Crash.self) { try scene.store.store(first) }
        faults.clear(library: scene.library)
        #expect(scene.temporaries().count == 1 && !scene.store.contains(first.identity))
        do {
            _ = try await scene.writer.commit(recipe: try scene.recipe(try sky(first.ref), revision: 1), for: scene.frame, library: scene.library)
            Issue.record("A record naming a seed cut short was written")
        } catch RecipeWriter.Failure.missingRaster {}
        #expect(!exists(scene.library.appendingPathComponent("ManualDevelopment")))
        #expect(MaskRasterStore.sweep(library: scene.library).removed.isEmpty)
        #expect(MaskRasterStore.sweep(library: scene.library, now: Date().addingTimeInterval(2 * 86_400)).removed.count == 1)
        #expect(scene.temporaries().isEmpty)

        // 2. After the seed, before the save that would name it: an orphan, kept while young, gone when old.
        let orphan = try scene.store.store(try seed(61))
        #expect(MaskRasterStore.sweep(library: scene.library).removed.isEmpty)
        try age(scene.store.url(for: orphan.id), days: 8)
        #expect(MaskRasterStore.sweep(library: scene.library).removed == [orphan.id.hex + ".png"])

        // 3. After the journal, before the pack: the old sidecar stays, and the next load publishes both from the journal.
        _ = try await scene.writer.commit(recipe: try scene.recipe(nil, revision: 1), for: scene.frame, library: scene.library)
        let ref = try scene.store.store(try seed(62))
        faults.inject(.packBesideRaw, library: scene.library)
        let saved = try await scene.writer.commit(recipe: try scene.recipe(try sky(ref), revision: 2), for: scene.frame, library: scene.library)
        faults.clear(library: scene.library)
        #expect(saved.editRevision == 2 && !exists(scene.pack))
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).editRevision == 1)
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(loaded?.editRevision == 2 && loaded?.manual?.adjustments.masks.rasters == [ref])
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).editRevision == 2)
        #expect(try MaskRasterStore.packEntries(at: scene.pack)?.map(\.id) == [ref.id])

        // 4. After the pack, before the sidecar: the pack holds the new seed beside the old sidecar, and the next load publishes it.
        let next = try scene.store.store(try seed(63))
        faults.inject(.sidecarBesideRaw, library: scene.library)
        _ = try await scene.writer.commit(recipe: try scene.recipe(try sky(next), revision: 3), for: scene.frame, library: scene.library)
        faults.clear(library: scene.library)
        #expect(try MaskRasterStore.packEntries(at: scene.pack)?.map(\.id) == [next.id])
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).editRevision == 2)
        _ = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).manual?.adjustments.masks.rasters == [next])

        // 5. Merging a develop receipt updates the library and RAW sidecar without writing files beside the output image.
        let out = scene.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let output = out.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: output)
        var exported = try scene.recipe(try sky(next), revision: 3)
        exported.develops.append(.init(date: Date(timeIntervalSince1970: 5000), software: "Argent test", output: OutputSettings(), file: output.path,
            width: 40, height: 20, render: exported.render, decode: nil, readback: nil, stockDigest: scene.stock.digest,
            renderVersion: RenderGraph.version(for: exported.render.settings), outputSource: SourceStamp.of(output)))
        let merged = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
        #expect(merged.develops.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["frame.jpg"])
        #expect(try MaskRasterStore.packEntries(at: scene.pack)?.map(\.id) == [next.id])

        // 6. A seed damaged or deleted later: the record still reads, and the seed is refused.
        let file = scene.store.url(for: next.id), png = try Data(contentsOf: file)
        try png.prefix(100).write(to: file)
        #expect(throws: MaskRasterStore.Failure.damaged(next.id)) { try scene.store.load(next) }
        try FileManager.default.removeItem(at: file)
        #expect(try await scene.writer.load(for: scene.frame, library: scene.library)?.manual?.adjustments.masks.rasters == [next])
        // The load took it back from the pack beside the raw.
        #expect(try scene.store.load(next).identity == next.id)
    }

    /// A library lost, or a roll moved to another Mac: the raw's pack gives the seeds back, each checked.
    @Test func aPackTakesTheSeedsToAnotherLibraryAndAMovedRoll() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let ref = try scene.store.store(try seed(70, width: 256, height: 171))
        let masks = try sky(ref)
        _ = try await scene.writer.commit(recipe: try scene.recipe(masks, revision: 1), for: scene.frame, library: scene.library)
        // Another library, the same roll.
        let lost = scene.root.appendingPathComponent("library-2")
        let restored = try await RecipeWriter(digests: scene.digests).load(for: scene.frame, library: lost)
        #expect(restored?.manual?.adjustments.masks == masks && MaskRasterStore(library: lost).contains(ref.id))
        #expect(try MaskRasterStore(library: lost).load(ref).identity == ref.id)
        // The roll moved with its sidecar and pack, opened with a third library.
        let moved = scene.root.appendingPathComponent("moved")
        try FileManager.default.copyItem(at: scene.roll, to: moved)
        let movedFrame = SeedScene.frame(moved.appendingPathComponent("frame.ARW"))
        let third = scene.root.appendingPathComponent("library-3")
        let reopened = try await RecipeWriter(digests: scene.digests).load(for: movedFrame, library: third)
        #expect(reopened?.manual?.adjustments.masks == masks && MaskRasterStore(library: third).contains(ref.id))
        // A commit on a library that lacks the seed takes it from the pack too, rather than refuse.
        let fourth = scene.root.appendingPathComponent("library-4")
        _ = try await RecipeWriter(digests: scene.digests).commit(recipe: try scene.recipe(masks, revision: 2, for: movedFrame), for: movedFrame, library: fourth)
        #expect(MaskRasterStore(library: fourth).contains(ref.id))
    }

    /// A roll moved with its sidecar and its `.argentmasks` pack: the pack carries a Follow edges stroke's measured shape as it carries a smart
    /// seed, and the record reads back into a library that never held it, the stroke's shape loading checked.
    @Test func aPackCarriesAStrokesShapeToAMovedRollAndAnotherLibrary() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let raster = try seed(90, width: 120, height: 80)
        let shape = try scene.store.store(raster), masks = try stroked(shape)
        _ = try await scene.writer.commit(recipe: try scene.recipe(masks, revision: 1), for: scene.frame, library: scene.library)
        #expect(exists(scene.pack))
        let moved = scene.root.appendingPathComponent("moved")
        try FileManager.default.copyItem(at: scene.roll, to: moved)
        let movedFrame = SeedScene.frame(moved.appendingPathComponent("frame.ARW"))
        let other = scene.root.appendingPathComponent("library-2")
        let reopened = try await RecipeWriter(digests: scene.digests).load(for: movedFrame, library: other)
        let stored = try #require(reopened?.manual?.adjustments.masks)
        #expect(stored == masks && stored.rasters == [shape])
        #expect(try MaskRasterStore(library: other).load(shape) == raster)
    }

    /// Revision 12 develops while the edit moves to 13 with another seed: the library and the raw's pack hold 13's with 12's receipt,
    /// and the output folder holds only the developed image.
    @Test func anExportOfRevision12KeepsRevision13AndWritesNoOutputFiles() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let twelve = try scene.store.store(try seed(80)), thirteen = try scene.store.store(try seed(81))
        var exported = try await scene.writer.commit(recipe: try scene.recipe(try sky(twelve), revision: 12), for: scene.frame, library: scene.library)
        _ = try await scene.writer.commit(recipe: try scene.recipe(try sky(thirteen), revision: 13), for: scene.frame, library: scene.library)
        let out = scene.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let output = out.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: output)
        exported.develops.append(.init(date: Date(timeIntervalSince1970: 5000), software: "Argent test", output: OutputSettings(), file: output.path,
            width: 40, height: 20, render: exported.render, decode: nil, readback: nil, stockDigest: scene.stock.digest,
            renderVersion: RenderGraph.version(for: exported.render.settings), outputSource: SourceStamp.of(output)))
        let merged = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
        #expect(merged.editRevision == 13 && merged.manual?.adjustments.masks.rasters == [thirteen])
        #expect(merged.develops.count == 1 && merged.develops[0].render == exported.render)
        #expect(try MaskRasterStore.packEntries(at: scene.pack)?.map(\.id) == [thirteen.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["frame.jpg"])
    }

    /// A read-only card: the record and its seeds stay in the library, and neither sidecar nor pack is written; the card's own pack
    /// still reads; once the card can be written, the next load publishes both.
    @Test func aReadOnlyCardKeepsSeedsInTheLibraryAndPublishesThemOnceWritable() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let ref = try scene.store.store(try seed(90))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scene.roll.path)
        let saved = try await scene.writer.commit(recipe: try scene.recipe(try sky(ref), revision: 1), for: scene.frame, library: scene.library)
        #expect(saved.version == 6 && !exists(scene.sidecar) && !exists(scene.pack))
        let out = scene.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let output = out.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: output)
        var exported = saved
        exported.develops.append(.init(date: Date(timeIntervalSince1970: 5000), software: "Argent test", output: OutputSettings(), file: output.path,
            width: 40, height: 20, render: exported.render, decode: nil, readback: nil, stockDigest: scene.stock.digest,
            renderVersion: RenderGraph.version(for: exported.render.settings), outputSource: SourceStamp.of(output)))
        _ = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["frame.jpg"])
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(loaded?.manual?.adjustments.masks.rasters == [ref] && loaded?.develops.map(\.file) == [output.path])
        #expect(!exists(scene.sidecar) && scene.temporaries().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scene.roll.path)
        _ = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(try exists(scene.sidecar) && MaskRasterStore.packEntries(at: scene.pack)?.map(\.id) == [ref.id])
        // Locked again, the card's pack gives its seeds to another library.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scene.roll.path)
        let other = scene.root.appendingPathComponent("library-2")
        _ = try await RecipeWriter(digests: scene.digests).load(for: scene.frame, library: other)
        #expect(MaskRasterStore(library: other).contains(ref.id))
    }

    /// Twin raws, the same bytes under two names: one record each and one seed file between them, which the sweep keeps while either
    /// names it.
    @Test func twinRawsShareOneSeedFileAndTheSweepKeepsItWhileEitherNamesIt() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let twin = SeedScene.frame(scene.roll.appendingPathComponent("frame copy.ARW"), id: 1)
        try FileManager.default.copyItem(at: scene.frame.url, to: twin.url)
        let shared = try seed(100)
        let ref = try scene.store.store(shared)
        _ = try await scene.writer.commit(recipe: try scene.recipe(try sky(ref), revision: 1), for: scene.frame, library: scene.library)
        #expect(try scene.store.store(shared) == ref)
        _ = try await scene.writer.commit(recipe: try scene.recipe(try sky(ref), revision: 1, for: twin), for: twin, library: scene.library)
        let files = (FileManager.default.enumerator(at: scene.store.folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "png" }
        #expect(files.map(\.lastPathComponent) == [ref.id.hex + ".png"])
        #expect(exists(RecipeStore.masksBesideRaw(twin.url)) && exists(scene.pack))
        try age(scene.store.url(for: ref.id), days: 8)
        _ = try await scene.writer.commit(recipe: try scene.recipe(nil, revision: 2), for: scene.frame, library: scene.library)
        #expect(MaskRasterStore.sweep(library: scene.library).removed.isEmpty && scene.store.contains(ref.id))
        _ = try await scene.writer.commit(recipe: try scene.recipe(nil, revision: 2, for: twin), for: twin, library: scene.library)
        try age(scene.store.url(for: ref.id), days: 8)
        #expect(MaskRasterStore.sweep(library: scene.library).removed == [ref.id.hex + ".png"])
    }
}

@Suite struct MaskSeedDevelopTests {
    /// A lost seed, and a selection never made, fail the frame before it is let in to decode: a develop never prints a mask as
    /// covering nothing, and never runs a model. With its seed there, the frame goes on to its decode, which this stand-in fails.
    @Test func aLostSeedOrASelectionNeverMadeFailsTheFrameBeforeItsDecode() async throws {
        let scene = try SeedScene()
        defer { scene.remove() }
        let developer = try RollDeveloper(stocks: [scene.stock], software: "Argent test", library: scene.library,
                                          digests: SourceDigests(settle: 0), decoderChoices: DecoderChoices(route: .apple))
        let stages = Recorded<RollDeveloper.Stage>()
        developer.observeStage = { _, stage, _ in stages.add(stage) }
        let lost = try seed(110).ref
        func develop(_ masks: MaskSet) async throws -> RollDeveloper.Outcome {
            let job = RollDeveloper.Job(frame: scene.frame, recipe: try scene.recipe(masks, revision: 1))
            return await developer.develop([job], to: scene.root.appendingPathComponent("out"), output: OutputSettings())[0]
        }
        guard case .failed(let missing) = try await develop(try sky(lost)) else { Issue.record("A lost seed must fail its frame"); return }
        #expect(missing.contains("missing from the library") && missing.hasPrefix("frame: "))
        guard case .failed(let pending) = try await develop(try sky(nil)) else { Issue.record("A selection never made must fail its frame"); return }
        #expect(pending.contains("Sky mask’s selection has not been made"))
        #expect(stages.all.isEmpty, "\(stages.all)")
        // A mask that is off needs no seed, and its seed is not looked for.
        let off = try await develop(try sky(lost, enabled: false))
        guard case .failed(let reason) = off, !reason.contains("selection") else { Issue.record("\(off)"); return }
        // With its seed in the library, the frame is let in and decoded.
        let ref = try scene.store.store(try seed(110))
        guard case .failed(let decode) = try await develop(try sky(ref)), !decode.contains("selection") else { Issue.record("decode"); return }
        #expect(stages.all.contains(.decode))
    }
}

/// Runs only where the CC0 samples are present: a real decode, about a second.
@Suite(.serialized, .rawDecodes) struct MaskSeedDevelopSampleTests {
    private static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path) }

    /// A seed found whole before the decode and damaged during it: the lane's load checks it again, fails the frame, and writes nothing.
    @Test(.enabled(if: MaskSeedDevelopSampleTests.hasSample))
    func aSeedDamagedDuringTheDecodeFailsTheFrameAndWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentSeedSample-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("roll"), library = root.appendingPathComponent("library"), out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = folder.appendingPathComponent(Self.sample.lastPathComponent)
        do { try FileManager.default.linkItem(at: Self.sample, to: raw) } catch { try FileManager.default.copyItem(at: Self.sample, to: raw) }
        let frame = try #require(await RollScanner.scan(folder).frames.first)
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let store = MaskRasterStore(library: library), ref = try store.store(try seed(120, width: 512, height: 341))
        let controls = RollControls()
        let baseline = AutomaticBaseline(sourceSHA256: try RecipeStore.sha256(of: frame.url), stockID: stock.id, stockDigest: stock.digest,
                                         controls: controls, aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
                                         baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
        let recipe = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                                     roll: controls, own: FrameControls(),
                                     manual: ManualEdit(adjustments: try ManualAdjustments(masks: try sky(ref)), baseline: baseline))
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library)
        let file = store.url(for: ref.id)
        developer.observeStage = { _, stage, begins in
            if stage == .decode, begins { try? Data("not a picture".utf8).write(to: file) }
        }
        let outcomes = await developer.develop([RollDeveloper.Job(frame: frame, recipe: recipe)], to: out, output: OutputSettings(size: .longEdge2048))
        guard case .failed(let reason) = outcomes[0] else { Issue.record("\(outcomes)"); return }
        #expect(reason.contains("is damaged") && reason.contains("remove the mask"), "\(reason)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        developer.trim()
    }

    /// A roll where one frame lost its seed still develops every other frame, and the lost one fails alone, before its decode,
    /// saying why: a develop never prints a mask as covering nothing, and never holds up the roll for one frame.
    @Test(.enabled(if: MaskSeedDevelopSampleTests.hasSample))
    func aLostSeedFailsItsFrameAloneAndTheRollDevelops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentSeedRoll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("roll"), library = root.appendingPathComponent("library"), out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples = Self.sample.deletingLastPathComponent()
        for name in ["ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW", "ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW"] {
            let source = samples.appendingPathComponent(name), link = folder.appendingPathComponent(name)
            do { try FileManager.default.linkItem(at: source, to: link) } catch { try FileManager.default.copyItem(at: source, to: link) }
        }
        let frames = await RollScanner.scan(folder).frames
        #expect(frames.count == 2)
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let controls = RollControls(), lostSeed = try seed(130).ref
        let gradient = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: 0.5))))],
                                                adjustments: try ManualAdjustments(exposureEV: -1))])
        let jobs = try frames.enumerated().map { index, frame in
            let baseline = AutomaticBaseline(sourceSHA256: try RecipeStore.sha256(of: frame.url), stockID: stock.id, stockDigest: stock.digest,
                                             controls: controls, aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
                                             baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
            let masks = index == 0 ? try sky(lostSeed) : gradient
            let recipe = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                                         roll: controls, own: FrameControls(),
                                         manual: ManualEdit(adjustments: try ManualAdjustments(masks: masks), baseline: baseline),
                                         editRevision: 7, editLineage: "seed-roll")
            return RollDeveloper.Job(frame: frame, recipe: recipe)
        }
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library)
        let decoded = Recorded<Int>()
        developer.observeStage = { index, stage, begins in if stage == .decode, begins { decoded.add(index) } }
        let outcomes = await developer.develop(jobs, to: out, output: OutputSettings(size: .longEdge2048))
        guard case .failed(let reason) = outcomes[0] else { Issue.record("\(outcomes)"); return }
        #expect(reason.hasPrefix("\(frames[0].name): "), "\(reason)")
        #expect(reason.contains("missing from the library") && reason.contains("remove the mask"), "\(reason)")
        guard case .developed(let file) = outcomes[1] else { Issue.record("\(outcomes)"); return }
        #expect(FileManager.default.fileExists(atPath: file.path) && file.lastPathComponent.hasPrefix(frames[1].name))
        // Only the other frame was decoded; the lost one wrote nothing.
        #expect(decoded.all == [1], "\(decoded.all)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).allSatisfy { $0.hasPrefix(frames[1].name) })
        developer.trim()
    }
}

/// What a develop's lanes saw, in order, from any lane: its stages, or the frames it decoded.
private final class Recorded<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func add(_ value: Value) { lock.withLock { values.append(value) } }
    var all: [Value] { lock.withLock { values } }
}

private extension Mask {
    func withID(_ id: UUID) -> Mask { Mask(id: id, isEnabled: isEnabled, components: components, amount: amount, adjustments: adjustments) }
}
