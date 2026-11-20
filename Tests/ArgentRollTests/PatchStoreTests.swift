import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// A roll folder with one raw, a library of its own and recipes whose removals name patches, for the store, the writer and the
/// develop (docs/remove-plan.md, section 4.7). Every test has a temporary root of its own and never reaches Application Support or
/// Caches, and no test runs a model: a patch is built by hand.
private struct PatchScene {
    let root: URL
    let library: URL
    let roll: URL
    let frame: Frame
    let stock: Stock
    let sha: String
    let digests: SourceDigests
    let writer: RecipeWriter
    let controls = RollControls()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentRemove-\(UUID().uuidString)")
        library = root.appendingPathComponent("library", isDirectory: true)
        roll = root.appendingPathComponent("roll", isDirectory: true)
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        let raw = roll.appendingPathComponent("frame.ARW")
        try Data(repeating: 71, count: 4096).write(to: raw)
        frame = Self.frame(raw)
        stock = toyStock()
        digests = SourceDigests(settle: 0)
        sha = try digests.digest(of: raw).sha256
        writer = RecipeWriter(digests: digests)
    }

    static func frame(_ url: URL, id: Int = 0) -> Frame { Frame(id: id, url: url, info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1000))) }

    var store: PatchStore { PatchStore(library: library) }
    var sidecar: URL { RecipeStore.besideRaw(frame.url) }
    var pack: URL { RecipeStore.patchesBesideRaw(frame.url) }

    func baseline(sha override: String? = nil) -> AutomaticBaseline {
        AutomaticBaseline(sourceSHA256: override ?? sha, stockID: stock.id, stockDigest: stock.digest, controls: controls, aim: PrintAim(),
                          analysisVersion: ExposureAnalysis.currentVersion,
                          baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
    }

    /// A recipe whose edit holds `removals` (no edit for `nil`), and `held` as its held edit's, at `revision`.
    func recipe(_ removals: [Removal]?, held: [Removal]? = nil, revision: UInt64, for frame: Frame? = nil) throws -> Recipe {
        try recipe(adjustments: try removals.map { try ManualAdjustments(exposureEV: 0.2).settingRemovals($0) },
                   held: try held.map { try ManualAdjustments().settingRemovals($0) }, revision: revision, for: frame)
    }

    /// A recipe whose edit is `adjustments` (no edit for `nil`), and `held` as its held edit, at `revision`.
    func recipe(adjustments: ManualAdjustments?, held: ManualAdjustments? = nil, revision: UInt64, for frame: Frame? = nil) throws -> Recipe {
        let frame = frame ?? self.frame
        let manual = adjustments.map { ManualEdit(adjustments: $0, baseline: baseline()) }
        let heldEdit = held.map { ManualEdit(adjustments: $0, baseline: baseline(sha: String(repeating: "0", count: 64))) }
        var recipe = try Recipe.make(frame: frame, byteCount: 4096, stock: stock, stockDigest: stock.digest, roll: controls, own: FrameControls(),
                                     analysis: ExposureAnalysis(meanStops: -0.3, validWeight: 1), aim: PrintAim(), grain: .off,
                                     manual: manual, editRevision: revision, editLineage: "frame-lineage", heldManual: heldEdit)
        recipe.raw.sha256 = sha
        return recipe
    }

    /// `recipe` as a develop that wrote `output` leaves it: with that develop's receipt.
    func developed(_ recipe: Recipe, to output: URL) -> Recipe {
        var exported = recipe
        exported.develops.append(.init(date: Date(timeIntervalSince1970: 5000), software: "Argent test", output: OutputSettings(), file: output.path,
            width: 40, height: 20, render: exported.render, decode: nil, readback: nil, stockDigest: stock.digest,
            renderVersion: RenderGraph.version(for: exported.render.settings), outputSource: SourceStamp.of(output)))
        return exported
    }

    func journal(_ saved: Recipe) throws -> URL {
        RecipeWriter.journalURL(sha256: sha, lineage: try #require(saved.editLineage), library: library)
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

private func toyStock() -> Stock {
    Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
}

/// A patch of `width` by `height` over a box that lies inside the smallest sample, its pixels set by `n`, so two patches of
/// different `n` have different names.
private func patch(_ n: UInt64, width: Int = 32, height: Int = 16, notes: RemovalPatch.Notes = .none) throws -> RemovalPatch {
    var state = n &* 0x9E37_79B9_7F4A_7C15 &+ 1
    func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    let rgb = (0..<(width * height * 3)).map { _ in Float16(Float(next() % 4096) / 1024) }
    let object = (0..<(width * height)).map { _ in UInt8(next() % 256) }
    let effects = object.map { max($0, UInt8(next() % 256)) }
    return try RemovalPatch(box: try .init(x: 100, y: 200, width: 640, height: 320), width: width, height: height, rgb: rgb,
                            objectAlpha: object, effectsAlpha: effects, notes: notes)
}

private func removal(_ ref: PatchRef, isOn: Bool = true) -> Removal { Removal(patch: ref, isOn: isOn) }

private func age(_ url: URL, days: Double) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
}

private func modified(_ url: URL) throws -> Date {
    try #require(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// What several threads, or a develop's lanes, saw.
private final class Recorded<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func add(_ value: Value) { lock.withLock { values.append(value) } }
    var all: [Value] { lock.withLock { values } }
}

// MARK: the store

@Suite struct PatchStoreTests {
    /// A patch is one `.argentpatch` file in the library's `Patches/v1`, named by its box and pixels: read back whole, notes
    /// included, and stored again it writes nothing new, whatever its notes say.
    @Test func aPatchIsOneFileInTheLibraryNamedByItsPixelsAndStoredOnce() throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let notes = RemovalPatch.Notes(engine: "fake", steps: 8, seed: 42, decoder: "argent-5", frameWidth: 7008, frameHeight: 4672,
                                       made: Date(timeIntervalSince1970: 1_800_000_000))
        let made = try patch(1, notes: notes)
        let ref = try scene.store.store(made)
        #expect(ref == made.ref && ref.width == 32 && ref.height == 16)
        let file = scene.store.url(for: ref.id)
        #expect(file.path.hasPrefix(scene.library.appendingPathComponent("Patches/v1/\(ref.id.hex.prefix(2))").path))
        #expect(file.lastPathComponent == ref.id.hex + ".argentpatch")
        let bytes = try Data(contentsOf: file)
        #expect(bytes.prefix(RemovalPatch.magic.count) == RemovalPatch.magic)
        let read = try scene.store.load(ref)
        #expect(read == made && read.notes == notes)
        #expect(scene.store.contains(ref.id) && scene.store.missing([ref]).isEmpty)

        // Stored twice, it is one file, left as it was: the second store reads it, finds it sound and writes nothing.
        try age(file, days: 1)
        #expect(try scene.store.store(made) == ref)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [file.lastPathComponent])
        #expect(try Data(contentsOf: file) == bytes && scene.temporaries().isEmpty)
        // The same pixels with other notes are the same patch, so the file and its first notes stay.
        var noted = made
        noted.notes.face = [0.1, 0.2, 0.05, 0.08]
        #expect(try scene.store.store(noted) == ref)
        #expect(try Data(contentsOf: file) == bytes && scene.store.load(ref).notes == notes)
        // Found again, it counts as young.
        #expect(try modified(file).timeIntervalSinceNow > -3600)
    }

    /// A patch whose file is gone, empty, cut short or holding another patch is refused, never composited as something else;
    /// storing the patch again replaces the damaged file.
    @Test func aDamagedOrMissingPatchIsRefusedAndTheNextStoreReplacesIt() throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let made = try patch(2), other = try patch(3)
        let ref = try scene.store.store(made), file = scene.store.url(for: ref.id)
        let bytes = try Data(contentsOf: file)
        try bytes.prefix(bytes.count / 2).write(to: file)
        #expect(throws: PatchStore.Failure.damaged(ref.id)) { try scene.store.load(ref) }
        // Another patch's file under this name unpacks, to pixels this name is not the hash of.
        try Data(contentsOf: scene.store.url(for: try scene.store.store(other).id)).write(to: file)
        #expect(throws: PatchStore.Failure.damaged(ref.id)) { try scene.store.load(ref) }
        try Data("not a patch".utf8).write(to: file)
        #expect(throws: PatchStore.Failure.damaged(ref.id)) { try scene.store.load(ref) }
        #expect(scene.store.contains(ref.id), "a damaged file is there until it is read")
        try scene.store.store(made)
        #expect(try scene.store.load(ref) == made && Data(contentsOf: file) == bytes)
        // The right pixels asked for at another size are not what the record names.
        #expect(throws: PatchStore.Failure.damaged(ref.id)) { try scene.store.load(try PatchRef(id: ref.id, width: 16, height: 32)) }

        try Data().write(to: file)
        #expect(!scene.store.contains(ref.id) && scene.store.missing([ref, ref]) == [ref])
        #expect(throws: PatchStore.Failure.missing(ref.id)) { try scene.store.load(ref) }
        try FileManager.default.removeItem(at: file)
        #expect(throws: PatchStore.Failure.missing(ref.id)) { try scene.store.load(ref) }
        #expect(PatchStore.Failure.missing(ref.id).description == "A removal’s pixels (\(ref.id.hex.prefix(12))) are missing from the library")
        #expect(PatchStore.Failure.damaged(ref.id).localizedDescription == "A removal’s pixels (\(ref.id.hex.prefix(12))) are damaged")
    }

    /// A crash after the patch's bytes are flushed and before its rename, stood in for by a failure there: a `.tmp-*` and no
    /// file under the patch's name, so the record that would name it is refused, and the sweep takes the temporary file a day on.
    @Test func aCrashBeforeTheRenameLeavesATemporaryFileAndNoNamedPatch() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let made = try patch(4)
        MaskWriteFaults.shared.inject(.rasterBeforeRename, library: scene.library)
        #expect(throws: MaskWriteFaults.Crash.self) { try scene.store.store(made) }
        MaskWriteFaults.shared.clear(library: scene.library)
        #expect(scene.temporaries().count == 1 && !scene.store.contains(made.identity) && !exists(scene.store.url(for: made.identity)))
        #expect(throws: PatchStore.Failure.missing(made.identity)) { try scene.store.load(made.ref) }
        do {
            _ = try await scene.writer.commit(recipe: try scene.recipe([removal(made.ref)], revision: 1), for: scene.frame, library: scene.library)
            Issue.record("A record naming a patch cut short was written")
        } catch RecipeWriter.Failure.missingPatch(let id) {
            #expect(id == made.identity)
        }
        #expect(!exists(scene.library.appendingPathComponent("ManualDevelopment")) && !exists(scene.sidecar) && !exists(scene.pack))
        #expect(PatchStore.sweep(library: scene.library).removed.isEmpty)
        #expect(PatchStore.sweep(library: scene.library, now: Date().addingTimeInterval(2 * 86_400)).removed.count == 1)
        #expect(scene.temporaries().isEmpty)
        // The next store writes it whole.
        #expect(try scene.store.load(try scene.store.store(made)) == made)
    }

    @Test func aDamagedPackIsRewrittenFromTheLibrary() throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let made = try patch(30)
        let ref = try scene.store.store(made)
        let pack = scene.root.appendingPathComponent("repair.argentpatches")
        try scene.store.writePack([ref], to: pack)
        var bytes = try Data(contentsOf: pack)
        bytes[bytes.count - 30] ^= 0xFF
        try bytes.write(to: pack)

        try scene.store.writePack([ref], to: pack)
        let fresh = PatchStore(library: scene.root.appendingPathComponent("fresh"))
        let result = try fresh.importPack(from: pack)
        #expect(result.damaged.isEmpty)
        #expect(result.added == [ref.id])
        #expect(try fresh.load(ref) == made)
    }

    @Test(arguments: [false, true]) func anUnchangedPackKeepsItsModificationDate(empty: Bool) throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let refs = empty ? [] : [try scene.store.store(try patch(31))]
        let pack = scene.root.appendingPathComponent("unchanged.argentpatches")
        try scene.store.writePack(refs, to: pack)
        try age(pack, days: 1)
        let written = try #require(try URL(fileURLWithPath: pack.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try scene.store.writePack(refs, to: pack)
        #expect(try #require(try URL(fileURLWithPath: pack.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) == written)
    }

    /// A pack is the library's files in one file: read back by its header, each patch checked on its way into another library,
    /// left as it is when it already holds these files, and refused when it is not a patch pack. An entry that does not hold the
    /// pixels its id names is left out of an import, never kept.
    @Test func aPackHoldsItsPatchesAndADamagedEntryIsLeftOut() throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let a = try patch(10), b = try patch(11, width: 48, height: 32)
        let refs = [try scene.store.store(a), try scene.store.store(b)]
        let pack = scene.root.appendingPathComponent("p.argentpatches")
        try scene.store.writePack(refs + [refs[0]], to: pack)
        let entries = try #require(try PatchStore.packEntries(at: pack))
        #expect(entries.map(\.id) == refs.map(\.id))
        #expect(try entries.map(\.length) == refs.map { try Data(contentsOf: scene.store.url(for: $0.id)).count })
        let other = PatchStore(library: scene.root.appendingPathComponent("other"))
        #expect(try other.importPack(from: pack, wanted: [refs[1].id]).added == [refs[1].id])
        #expect(try other.importPack(from: pack) == PatchStore.PackImport(added: [refs[0].id], damaged: []))
        #expect(try other.load(refs[0]) == a && other.load(refs[1]) == b)
        #expect(try other.importPack(from: pack).added.isEmpty, "what the library has is left as it is")

        // Written again with the same patches, it is left as it is.
        let written = try modified(pack)
        try age(pack, days: 1)
        try scene.store.writePack(refs, to: pack)
        #expect(try modified(pack) < written)
        // With another patch it is written again, and one the library lacks stops the write and leaves the pack.
        let c = try scene.store.store(try patch(12))
        try scene.store.writePack([refs[0], c], to: pack)
        #expect(try PatchStore.packEntries(at: pack)?.map(\.id) == [refs[0].id, c.id])
        let absent = try patch(13).ref
        #expect(throws: PatchStore.Failure.missing(absent.id)) { try scene.store.writePack([refs[0], absent], to: pack) }
        #expect(try PatchStore.packEntries(at: pack)?.map(\.id) == [refs[0].id, c.id])

        // A byte of the second patch changed: that entry is damaged, and the first still comes in.
        try scene.store.writePack(refs, to: pack)
        var bytes = try Data(contentsOf: pack)
        bytes[bytes.count - 30] ^= 0xFF
        try bytes.write(to: pack)
        let third = PatchStore(library: scene.root.appendingPathComponent("third"))
        let result = try third.importPack(from: pack)
        #expect(result.added == [refs[0].id] && result.damaged == [refs[1].id] && !third.contains(refs[1].id))

        // A stranger under the pack's name, the masks' pack among them, is not a pack of patches.
        try Data("not a pack".utf8).write(to: pack)
        #expect(throws: PatchStore.Failure.notAPack("p.argentpatches")) { try third.importPack(from: pack) }
        #expect(throws: PatchStore.Failure.notAPack("p.argentpatches")) { try PatchStore.packEntries(at: pack) }
        try (MaskRasterStore.packMagic + Data([0, 0, 0, 0])).write(to: pack)
        #expect(throws: PatchStore.Failure.notAPack("p.argentpatches")) { try third.importPack(from: pack) }
        #expect(PatchStore.Failure.notAPack("p.argentpatches").description == "p.argentpatches is not a patch pack this build reads")
        #expect(try PatchStore.packEntries(at: scene.root.appendingPathComponent("none.argentpatches")) == nil)
        #expect(try third.importPack(from: scene.root.appendingPathComponent("none.argentpatches")) == PatchStore.PackImport())
    }

    /// The source the lens stage reads is `load` behind a cache by `PatchRef`: a patch read once is given again without its file
    /// being read, the patch read longest ago goes first when the bytes run out, and a patch that is missing or damaged is `nil`
    /// and is found once it arrives.
    @Test func theSourceIsLoadBehindACacheBoundedInBytes() throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let a = try patch(20), b = try patch(21)
        let size = PatchStore.byteCount(of: a.ref)
        #expect(size == 32 * 16 * 8)
        let absent = try patch(22)
        let source: any RemovalPatchSource = scene.store.source()
        #expect(source.patch(absent.ref) == nil)
        try scene.store.store(a); try scene.store.store(b)
        #expect(source.patch(a.ref) == a && source.patch(b.ref) == b)
        #expect(source.patch(try PatchRef(id: a.identity, width: 16, height: 32)) == nil, "another size is another patch")
        // One that arrives later is found: nothing is remembered of a patch that was missing.
        try scene.store.store(absent)
        #expect(source.patch(absent.ref) == absent)

        // Room for one patch and a little.
        let cache = PatchStore.Cache(scene.store, maximumBytes: size + 100)
        #expect(cache.patch(a.ref) == a && cache.residentBytes == size)
        // The file now holds something else, and the cache still gives the pixels it checked, where a new source refuses them.
        let fileA = scene.store.url(for: a.identity), bytesA = try Data(contentsOf: fileA)
        try Data("not a patch".utf8).write(to: fileA)
        #expect(cache.patch(a.ref) == a)
        #expect(scene.store.source().patch(a.ref) == nil)
        // The second patch takes the first one's room, so the first is read again, and is damaged.
        #expect(cache.patch(b.ref) == b && cache.residentBytes == size)
        #expect(cache.patch(a.ref) == nil && cache.residentBytes == size)
        // Mended, it is found, and takes the second one's room in turn.
        try bytesA.write(to: fileA)
        #expect(cache.patch(a.ref) == a && cache.residentBytes == size)
        // A patch whose file has gone is missing here too, though the cache held it.
        try FileManager.default.removeItem(at: fileA)
        #expect(cache.patch(a.ref) == nil && cache.residentBytes == 0)

        // A patch larger than the whole cache is given and not kept, and a cache let go holds nothing.
        let small = PatchStore.Cache(scene.store, maximumBytes: size - 1)
        #expect(small.patch(b.ref) == b && small.residentBytes == 0)
        #expect(cache.patch(b.ref) == b && cache.residentBytes == size)
        cache.trim()
        #expect(cache.residentBytes == 0 && cache.patch(b.ref) == b)
    }

    /// From any thread: many readers of three patches through a cache with room for two each get the patch they asked for, and
    /// the cache never holds more than its bytes.
    @Test func theSourceGivesTheRightPatchToEveryThread() throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let patches = try (30..<33).map { try patch($0) }
        for made in patches { try scene.store.store(made) }
        let size = PatchStore.byteCount(of: patches[0].ref)
        let cache = PatchStore.Cache(scene.store, maximumBytes: 2 * size)
        let wrong = Recorded<Int>(), over = Recorded<Int>()
        DispatchQueue.concurrentPerform(iterations: 240) { turn in
            let wanted = patches[turn % 3]
            if cache.patch(wanted.ref) != wanted { wrong.add(turn) }
            let resident = cache.residentBytes
            if resident > 2 * size || resident % size != 0 { over.add(resident) }
        }
        #expect(wrong.all.isEmpty && over.all.isEmpty, "\(wrong.all) \(over.all)")
        #expect(cache.residentBytes == 2 * size)
    }

    /// The sweep's three keeps: every patch a record names, in its current edit or its held one, shown or not; every patch in
    /// `keeping`, which is what an undo step names; and every file younger than a week. A receipt's removal is not the edit's, so
    /// the patch of a develop's old revision goes once nothing else names it, with a temporary file a day old.
    @Test func theSweepKeepsWhatARecordNamesWhatAnUndoStepNamesAndWhatIsYoung() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let live = try scene.store.store(try patch(40)), hidden = try scene.store.store(try patch(41)), held = try scene.store.store(try patch(42))
        let undone = try scene.store.store(try patch(43)), young = try scene.store.store(try patch(44))
        let old = try scene.store.store(try patch(45)), developed = try scene.store.store(try patch(46))
        var first = try await scene.writer.commit(recipe: try scene.recipe([removal(developed)], revision: 1), for: scene.frame, library: scene.library)
        // Developed at revision 1, then Try Again: the receipt still names the old patch, and the edit another.
        first = scene.developed(first, to: scene.root.appendingPathComponent("out.jpg"))
        var second = try scene.recipe([removal(live), removal(hidden, isOn: false)], held: [removal(held)], revision: 2)
        second.develops = first.develops
        let saved = try await scene.writer.commit(recipe: second, for: scene.frame, library: scene.library)
        #expect(saved.develops.first?.render.settings.lens.removals.map(\.patch) == [developed])
        #expect(RecipeWriter.patchRefs(of: saved) == [live, hidden, held])
        #expect(try PatchStore.namedPatches(in: scene.library) == [live.id, hidden.id, held.id])

        for ref in [live, hidden, held, undone, old, developed] { try age(scene.store.url(for: ref.id), days: 8) }
        let stray = scene.store.folder.appendingPathComponent(".tmp-0000-stray.argentpatch")
        let fresh = scene.store.folder.appendingPathComponent(".tmp-1111-fresh.argentpatch")
        try Data([1]).write(to: stray); try Data([1]).write(to: fresh)
        try age(stray, days: 2)
        let sweep = PatchStore.sweep(library: scene.library, keeping: [undone.id])
        #expect(sweep.skipped == nil)
        #expect(Set(sweep.removed) == [old.id.hex + ".argentpatch", developed.id.hex + ".argentpatch", stray.lastPathComponent])
        for ref in [live, hidden, held, undone, young] { #expect(scene.store.contains(ref.id)) }
        #expect(!scene.store.contains(old.id) && !scene.store.contains(developed.id) && exists(fresh))
        // Without the undo step, the patch it named goes too; and a week on, so does the one that was young.
        #expect(PatchStore.sweep(library: scene.library).removed == [undone.id.hex + ".argentpatch"])
        #expect(PatchStore.sweep(library: scene.library, now: Date().addingTimeInterval(8 * 86_400)).removed.contains(young.id.hex + ".argentpatch"))
        for ref in [live, hidden, held] { #expect(scene.store.contains(ref.id)) }

        // The removals deleted and the session's history gone: nothing names their patches, and they go.
        _ = try await scene.writer.commit(recipe: try scene.recipe([], revision: 3), for: scene.frame, library: scene.library)
        for ref in [live, hidden, held] { try age(scene.store.url(for: ref.id), days: 8) }
        #expect(Set(PatchStore.sweep(library: scene.library).removed) == Set([live, hidden, held].map { $0.id.hex + ".argentpatch" }))
    }

    /// A record this build cannot read may name any patch, so the sweep removes nothing and says why.
    @Test func aRecordThisBuildCannotReadStopsTheSweep() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let orphan = try scene.store.store(try patch(50))
        try age(scene.store.url(for: orphan.id), days: 30)
        let saved = try await scene.writer.commit(recipe: try scene.recipe(nil, revision: 1), for: scene.frame, library: scene.library)
        let journal = try scene.journal(saved)
        let text = String(decoding: try Data(contentsOf: journal), as: UTF8.self)
        let unreadable = text.replacingOccurrences(of: "\"version\" : \(saved.version)", with: "\"version\" : 99")
        #expect(unreadable != text)
        try Data(unreadable.utf8).write(to: journal)
        #expect(throws: (any Error).self) { try PatchStore.namedPatches(in: scene.library) }
        let sweep = PatchStore.sweep(library: scene.library)
        #expect(sweep.skipped != nil && sweep.removed.isEmpty && scene.store.contains(orphan.id))
        // Readable again, the orphan goes.
        try Data(text.utf8).write(to: journal)
        #expect(PatchStore.sweep(library: scene.library) == PatchStore.Sweep(removed: [orphan.id.hex + ".argentpatch"], skipped: nil))
    }
}

@Suite struct RecipeAssetSweepTests {
    @Test func bothSweepsKeepAssetsNamedInBackupsAndTopLevelRecipes() throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let masks = MaskRasterStore(library: scene.library)
        let patches = scene.store
        #expect(MaskRasterStore.sweep(library: scene.library) == MaskRasterStore.Sweep())
        #expect(PatchStore.sweep(library: scene.library) == PatchStore.Sweep())

        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let paths = [
            "ManualDevelopment/v2/Backups/\(scene.sha)/archive.json",
            "locked-card.argent",
            "ManualDevelopment/v2/Bindings/nested/ignored.json",
            "ManualDevelopment/v2/Backups/ignored.txt",
            "ignored.json",
            "other/ignored.argent"
        ]
        var keptRasters = Set<RasterID>(), keptPatches = Set<PatchID>()
        var removedRasters = Set<String>(), removedPatches = Set<String>()
        let now = Date().addingTimeInterval(8 * 86_400)
        for (index, path) in paths.enumerated() {
            let raster = try masks.store(seed(index))
            let patchRef = try patches.store(patch(UInt64(index)))
            let selection = SmartSelection(kind: .sky, raster: raster, frame: frame)
            let maskSet = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(selection))],
                                                   adjustments: try ManualAdjustments(exposureEV: -0.7))])
            let edit = try ManualAdjustments(masks: maskSet).settingRemovals([removal(patchRef)])
            let recipe = try scene.recipe(adjustments: edit, revision: 1)
            let file = scene.library.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try recipe.encoded().write(to: file)
            if index < 2 {
                keptRasters.insert(raster.id)
                keptPatches.insert(patchRef.id)
            } else {
                removedRasters.insert(masks.url(for: raster.id).lastPathComponent)
                removedPatches.insert(patches.url(for: patchRef.id).lastPathComponent)
            }
        }

        #expect(try MaskRasterStore.namedRasters(in: scene.library) == keptRasters)
        #expect(try PatchStore.namedPatches(in: scene.library) == keptPatches)
        let rasterSweep = MaskRasterStore.sweep(library: scene.library, now: now)
        let patchSweep = PatchStore.sweep(library: scene.library, now: now)
        #expect(rasterSweep.skipped == nil && Set(rasterSweep.removed) == removedRasters)
        #expect(patchSweep.skipped == nil && Set(patchSweep.removed) == removedPatches)
        for id in keptRasters { #expect(masks.contains(id)) }
        for id in keptPatches { #expect(patches.contains(id)) }
    }

    @Test(arguments: ["ManualDevelopment/v2/Backups/unreadable.json", "locked-card.argent"])
    func neitherSweepDeletesWhenARecipeIsUnreadable(path: String) throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let masks = MaskRasterStore(library: scene.library)
        let raster = try masks.store(seed(0))
        let patchRef = try scene.store.store(patch(0))
        let file = scene.library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a recipe".utf8).write(to: file)
        let now = Date().addingTimeInterval(8 * 86_400)

        let rasterSweep = MaskRasterStore.sweep(library: scene.library, now: now)
        let patchSweep = PatchStore.sweep(library: scene.library, now: now)
        #expect(rasterSweep.skipped != nil && rasterSweep.removed.isEmpty && masks.contains(raster.id))
        #expect(patchSweep.skipped != nil && patchSweep.removed.isEmpty && scene.store.contains(patchRef.id))

        try FileManager.default.removeItem(at: file)
        #expect(MaskRasterStore.sweep(library: scene.library, now: now).removed == [masks.url(for: raster.id).lastPathComponent])
        #expect(PatchStore.sweep(library: scene.library, now: now).removed == [scene.store.url(for: patchRef.id).lastPathComponent])
    }

    private func seed(_ value: Int) throws -> MaskRaster {
        try MaskRaster(width: 16, height: 16, plane: Array(repeating: UInt8(value), count: 16 * 16))
    }
}

// MARK: the writer

@Suite struct PatchWriterTests {
    @Test(arguments: ["absent", "sound", "damaged"], ["absent", "sound", "damaged"])
    func loadingRestoresOnlyMissingOrDamagedLocalBlobsFromSoundPacks(packState: String, localState: String) async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let made = try patch(73)
        let ref = try scene.store.store(made)
        _ = try await scene.writer.commit(recipe: try scene.recipe([removal(ref)], revision: 1), for: scene.frame, library: scene.library)
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
        let scene = try PatchScene()
        defer { scene.remove() }
        let made = try patch(74)
        let ref = try scene.store.store(made)
        _ = try await scene.writer.commit(recipe: try scene.recipe([removal(ref)], revision: 1), for: scene.frame, library: scene.library)
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

    /// The writer refuses a record naming a patch that is nowhere, before it writes anything: no journal, binding, sidecar or
    /// pack. A held edit's removal and one that is off count as much, since the record names them.
    @Test func aRecordNamingAMissingPatchIsRefusedAndNothingIsWritten() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let absent = try patch(60).ref
        let recipes = [try scene.recipe([removal(absent)], revision: 1), try scene.recipe(nil, held: [removal(absent)], revision: 1),
                       try scene.recipe([removal(absent, isOn: false)], revision: 1)]
        for recipe in recipes {
            do {
                _ = try await scene.writer.commit(recipe: recipe, for: scene.frame, library: scene.library)
                Issue.record("A record naming a missing patch was written")
            } catch RecipeWriter.Failure.missingPatch(let id) {
                #expect(id == absent.id)
            }
            #expect(!exists(scene.library.appendingPathComponent("ManualDevelopment")) && !exists(scene.sidecar) && !exists(scene.pack))
        }
        let words = RecipeWriter.Failure.missingPatch(absent.id).localizedDescription
        #expect(words.contains("(\(absent.id.hex.prefix(12))) are not in the library") && words.contains("were not saved"))
    }

    /// A commit writes the journal, then the pack beside the raw, then the sidecar, so the sidecar never names a removal its
    /// folder has no pixels for; a pack no sidecar names any more goes.
    @Test func aCommitWritesThePackBeforeTheSidecarAndRemovesAPackNoLongerNamed() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let made = try patch(61)
        let ref = try scene.store.store(made)
        let saved = try await scene.writer.commit(recipe: try scene.recipe([removal(ref)], revision: 1), for: scene.frame, library: scene.library)
        #expect(saved.version == 12 && exists(scene.sidecar))
        #expect(scene.pack.lastPathComponent == "frame.argentpatches")
        #expect(try PatchStore.packEntries(at: scene.pack)?.map(\.id) == [ref.id])
        #expect(try Recipe.decodeStrict(Data(contentsOf: try scene.journal(saved))).manual?.adjustments.removals.map(\.patch) == [ref])
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).manual?.adjustments.removals.map(\.patch) == [ref])
        #expect(!exists(RecipeStore.masksBesideRaw(scene.frame.url)), "a removal is no mask")

        // After the journal, before the pack: the old sidecar stays, and the next load publishes both from the journal.
        let next = try scene.store.store(try patch(62))
        MaskWriteFaults.shared.inject(.packBesideRaw, library: scene.library)
        let second = try await scene.writer.commit(recipe: try scene.recipe([removal(next)], revision: 2), for: scene.frame, library: scene.library)
        MaskWriteFaults.shared.clear(library: scene.library)
        #expect(second.editRevision == 2)
        #expect(try PatchStore.packEntries(at: scene.pack)?.map(\.id) == [ref.id])
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).editRevision == 1)
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(loaded?.editRevision == 2 && loaded?.manual?.adjustments.removals.map(\.patch) == [next])
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).editRevision == 2)
        #expect(try PatchStore.packEntries(at: scene.pack)?.map(\.id) == [next.id])

        // After the pack, before the sidecar: the pack holds the new patch beside the old sidecar, and the next load publishes it.
        let third = try scene.store.store(try patch(63))
        MaskWriteFaults.shared.inject(.sidecarBesideRaw, library: scene.library)
        _ = try await scene.writer.commit(recipe: try scene.recipe([removal(third)], revision: 3), for: scene.frame, library: scene.library)
        MaskWriteFaults.shared.clear(library: scene.library)
        #expect(try PatchStore.packEntries(at: scene.pack)?.map(\.id) == [third.id])
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).editRevision == 2)
        _ = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).manual?.adjustments.removals.map(\.patch) == [third])

        // Its last removal deleted, the frame has nothing for a pack to carry.
        _ = try await scene.writer.commit(recipe: try scene.recipe([], revision: 4), for: scene.frame, library: scene.library)
        #expect(!exists(scene.pack) && exists(scene.sidecar))
    }

    /// The library's patch gone, reading the recipe takes it back from the pack beside the raw, checked. With the pack gone too
    /// the record still reads, and the next write fails naming the patch and leaves what was saved.
    @Test func aPatchTheLibraryLostComesBackFromThePackAndWithBothGoneTheWriteFails() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let made = try patch(70, width: 64, height: 48)
        let ref = try scene.store.store(made), removals = [removal(ref)]
        _ = try await scene.writer.commit(recipe: try scene.recipe(removals, revision: 1), for: scene.frame, library: scene.library)
        let file = scene.store.url(for: ref.id)
        try FileManager.default.removeItem(at: file)
        #expect(!scene.store.contains(ref.id))
        let read = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(read?.manual?.adjustments.removals == removals)
        #expect(try scene.store.load(ref) == made)
        // One the library has is kept alive by the read, so the sweep keeps what a roll in use names.
        try age(file, days: 30)
        _ = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(try modified(file).timeIntervalSinceNow > -3600)
        #expect(scene.store.collectGarbage(keeping: []).isEmpty)

        // The library's patch gone again, a write takes it back from the pack too, rather than refuse.
        try FileManager.default.removeItem(at: file)
        let second = try await scene.writer.commit(recipe: try scene.recipe(removals, revision: 2), for: scene.frame, library: scene.library)
        #expect(second.editRevision == 2 && scene.store.contains(ref.id))

        // Both gone.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: scene.pack)
        let kept = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(kept?.manual?.adjustments.removals == removals && !scene.store.contains(ref.id) && !exists(scene.pack))
        do {
            _ = try await scene.writer.commit(recipe: try scene.recipe(removals, revision: 3), for: scene.frame, library: scene.library)
            Issue.record("A record naming a patch that is nowhere was written")
        } catch RecipeWriter.Failure.missingPatch(let id) {
            #expect(id == ref.id)
        }
        #expect(try Recipe.decodeStrict(Data(contentsOf: try scene.journal(second))).editRevision == 2)
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).editRevision == 2)
        // The removal deleted, the frame saves again.
        #expect(try await scene.writer.commit(recipe: try scene.recipe([], revision: 3), for: scene.frame, library: scene.library).editRevision == 3)
    }

    /// A library lost, or a roll moved to another Mac: the raw's pack gives the patches back to a library that never held them,
    /// each checked, and a damaged entry is left missing rather than taken.
    @Test func aPackTakesThePatchesToAnotherLibraryAndAMovedRoll() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let made = try patch(71), hidden = try patch(72)
        let removals = [removal(try scene.store.store(made)), removal(try scene.store.store(hidden), isOn: false)]
        _ = try await scene.writer.commit(recipe: try scene.recipe(removals, revision: 1), for: scene.frame, library: scene.library)
        #expect(try PatchStore.packEntries(at: scene.pack)?.map(\.id) == [made.identity, hidden.identity], "a removal that is off travels too")
        // Another library, the same roll.
        let lost = scene.root.appendingPathComponent("library-2")
        let restored = try await RecipeWriter(digests: scene.digests).load(for: scene.frame, library: lost)
        #expect(restored?.manual?.adjustments.removals == removals)
        #expect(try PatchStore(library: lost).load(made.ref) == made && PatchStore(library: lost).load(hidden.ref) == hidden)
        // The roll moved with its sidecar and pack, opened with a third library; a commit there takes them from the pack too.
        let moved = scene.root.appendingPathComponent("moved")
        try FileManager.default.copyItem(at: scene.roll, to: moved)
        let movedFrame = PatchScene.frame(moved.appendingPathComponent("frame.ARW"))
        let third = scene.root.appendingPathComponent("library-3")
        let reopened = try await RecipeWriter(digests: scene.digests).load(for: movedFrame, library: third)
        #expect(reopened?.manual?.adjustments.removals == removals && PatchStore(library: third).missing(removals.map(\.patch)).isEmpty)
        let fourth = scene.root.appendingPathComponent("library-4")
        _ = try await RecipeWriter(digests: scene.digests).commit(recipe: try scene.recipe(removals, revision: 2, for: movedFrame), for: movedFrame, library: fourth)
        #expect(PatchStore(library: fourth).missing(removals.map(\.patch)).isEmpty)

        // A pack whose last entry was damaged on the way: the record reads, the sound patch comes in and the other stays missing.
        var bytes = try Data(contentsOf: RecipeStore.patchesBesideRaw(movedFrame.url))
        bytes[bytes.count - 30] ^= 0xFF
        try bytes.write(to: RecipeStore.patchesBesideRaw(movedFrame.url))
        let fifth = PatchStore(library: scene.root.appendingPathComponent("library-5"))
        let damaged = try await RecipeWriter(digests: scene.digests).load(for: movedFrame, library: fifth.library)
        #expect(damaged?.manual?.adjustments.removals == removals)
        #expect(fifth.contains(made.identity) && fifth.missing(removals.map(\.patch)) == [hidden.ref])
    }

    /// Revision 12 develops while Try Again moves the edit to 13: the library and the raw's pack hold 13's patch with 12's
    /// receipt, and the output folder holds only the developed image.
    @Test func anExportRecordsItsReceiptWithoutWritingFilesBesideTheImage() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let before = try patch(80), after = try patch(81)
        let twelve = try scene.store.store(before), thirteen = try scene.store.store(after)
        let first = try await scene.writer.commit(recipe: try scene.recipe([removal(twelve)], revision: 12), for: scene.frame, library: scene.library)
        _ = try await scene.writer.commit(recipe: try scene.recipe([removal(thirteen)], revision: 13), for: scene.frame, library: scene.library)
        let out = scene.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let output = out.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: output)
        let exported = scene.developed(first, to: output)

        let merged = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
        #expect(merged.editRevision == 13 && merged.manual?.adjustments.removals.map(\.patch) == [thirteen] && merged.develops.count == 1)
        #expect(merged.develops[0].render == first.render)
        #expect(try PatchStore.packEntries(at: scene.pack)?.map(\.id) == [thirteen.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["frame.jpg"])

        // Developed again with nothing removed, the pack beside the raw goes and the output folder still holds only the image.
        let plain = try await scene.writer.commit(recipe: try scene.recipe([], revision: 14), for: scene.frame, library: scene.library)
        _ = try await scene.writer.mergeExport(recipe: scene.developed(plain, to: output), for: scene.frame, library: scene.library)
        #expect(!exists(scene.pack))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["frame.jpg"])
        // A snapshot naming a patch that is nowhere is still refused when it would become the persisted record.
        let absent = try patch(82).ref
        var orphaned = try scene.recipe([removal(absent)], revision: 15)
        orphaned = scene.developed(orphaned, to: output)
        await #expect(throws: RecipeWriter.Failure.self) {
            try await scene.writer.mergeExport(recipe: orphaned, for: scene.frame, library: scene.library)
        }
        #expect(try await scene.writer.load(for: scene.frame, library: scene.library)?.editRevision == 14)

        // An older snapshot whose removed patch is no longer in the library still merges its receipt into a newer plain edit.
        try FileManager.default.removeItem(at: scene.store.url(for: twelve.id))
        var staleExport = scene.developed(first, to: output)
        staleExport.develops[0].date = Date(timeIntervalSince1970: 5500)
        let keptPlain = try await scene.writer.mergeExport(recipe: staleExport, for: scene.frame, library: scene.library)
        #expect(keptPlain.editRevision == 14 && keptPlain.manual?.adjustments.removals.isEmpty == true)
        #expect(keptPlain.develops.contains(where: { $0.date == Date(timeIntervalSince1970: 5500) }))

        // Conversely, if the winning RAW sidecar names a patch missing from a fresh library (and no pack beside the RAW),
        // merging a plain receipt refuses rather than persisting a journal naming a missing patch.
        var sidecarWithMissing = try scene.recipe([removal(absent)], revision: 16)
        sidecarWithMissing.editLineage = keptPlain.editLineage
        try sidecarWithMissing.encoded().write(to: scene.sidecar, options: .atomic)
        let freshLibrary = scene.root.appendingPathComponent("library-fresh")
        let freshWriter = RecipeWriter(digests: scene.digests)
        do {
            _ = try await freshWriter.mergeExport(recipe: scene.developed(plain, to: output), for: scene.frame, library: freshLibrary)
            Issue.record("A winning sidecar naming a missing patch must not be persisted")
        } catch RecipeWriter.Failure.missingPatch(let id) {
            #expect(id == absent.id)
        }
        #expect(!exists(freshLibrary.appendingPathComponent("ManualDevelopment")))
    }

    /// A recipe with nothing removed is written as it was before Remove: no pack beside the raw or the output, no patch folder in
    /// the library, no word of a removal in the file, and the version it needed. Masks alone still write only their own pack.
    @Test func aRecipeWithNoRemovalWritesNoPackAndTheBytesItAlwaysDid() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let plain = try scene.recipe([], revision: 1)
        #expect(try RecipeWriter.patchRefs(of: plain).isEmpty && RecipeWriter.patchRefs(of: scene.recipe(nil, revision: 1)).isEmpty)
        let saved = try await scene.writer.commit(recipe: plain, for: scene.frame, library: scene.library)
        #expect(saved.version == 2)
        let bytes = try Data(contentsOf: scene.sidecar)
        #expect(try bytes == saved.encoded() && bytes == Data(contentsOf: scene.journal(saved)))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("removals") && !text.contains("patch") && text.contains("\"version\" : 2"))
        let out = scene.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let output = out.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: output)
        _ = try await scene.writer.mergeExport(recipe: scene.developed(saved, to: output), for: scene.frame, library: scene.library)
        _ = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(!exists(scene.pack) && !exists(scene.store.folder))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["frame.jpg"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scene.roll.path).sorted() == ["frame.ARW", "frame.argent"])

        // A mask's seed and no removal: the masks' pack, and no patches' pack.
        let seeds = MaskRasterStore(library: scene.library)
        let seed = try seeds.store(try MaskRaster(width: 64, height: 48, plane: (0..<(64 * 48)).map { UInt8(truncatingIfNeeded: $0) }))
        let space = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let sky = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: seed, frame: space)))],
                                           adjustments: try ManualAdjustments(exposureEV: -0.7))])
        let masked = try scene.recipe(adjustments: try ManualAdjustments(masks: sky), revision: 2)
        #expect(try await scene.writer.commit(recipe: masked, for: scene.frame, library: scene.library).version == 6)
        #expect(exists(RecipeStore.masksBesideRaw(scene.frame.url)) && !exists(scene.pack) && !exists(scene.store.folder))
    }

    /// A frame with a mask's seed and a removal writes both packs before its sidecar, and with either pack's write stopped the
    /// old sidecar stays: the two share one rule.
    @Test func aFrameWithAMaskAndARemovalWritesBothPacksBeforeItsSidecar() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let seeds = MaskRasterStore(library: scene.library), masksPack = RecipeStore.masksBesideRaw(scene.frame.url)
        let seed = try seeds.store(try MaskRaster(width: 64, height: 48, plane: (0..<(64 * 48)).map { UInt8(truncatingIfNeeded: $0) }))
        let space = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let sky = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: seed, frame: space)))],
                                           adjustments: try ManualAdjustments(exposureEV: -0.7))])
        let ref = try scene.store.store(try patch(95))
        let both = try ManualAdjustments(masks: sky).settingRemovals([removal(ref)])
        _ = try await scene.writer.commit(recipe: try scene.recipe([], revision: 1), for: scene.frame, library: scene.library)
        MaskWriteFaults.shared.inject(.packBesideRaw, library: scene.library)
        _ = try await scene.writer.commit(recipe: try scene.recipe(adjustments: both, revision: 2), for: scene.frame, library: scene.library)
        MaskWriteFaults.shared.clear(library: scene.library)
        #expect(!exists(masksPack) && !exists(scene.pack))
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).editRevision == 1)
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(loaded?.version == 12 && loaded?.manual?.adjustments == both)
        #expect(try MaskRasterStore.packEntries(at: masksPack)?.map(\.id) == [seed.id])
        #expect(try PatchStore.packEntries(at: scene.pack)?.map(\.id) == [ref.id])
        #expect(try Recipe.decodeStrict(Data(contentsOf: scene.sidecar)).editRevision == 2)
        // The removal deleted and the mask kept: the patches' pack goes and the masks' stays.
        _ = try await scene.writer.commit(recipe: try scene.recipe(adjustments: try ManualAdjustments(masks: sky), revision: 3), for: scene.frame, library: scene.library)
        #expect(exists(masksPack) && !exists(scene.pack))
    }

    /// A read-only card: the record and its patches stay in the library, and neither sidecar nor pack is written; once the card
    /// can be written, the next load publishes both.
    @Test func aReadOnlyCardKeepsPatchesInTheLibraryAndPublishesThemOnceWritable() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let ref = try scene.store.store(try patch(90))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scene.roll.path)
        let saved = try await scene.writer.commit(recipe: try scene.recipe([removal(ref)], revision: 1), for: scene.frame, library: scene.library)
        #expect(saved.version == 12 && !exists(scene.sidecar) && !exists(scene.pack))
        #expect(try await scene.writer.load(for: scene.frame, library: scene.library)?.manual?.adjustments.removals.map(\.patch) == [ref])
        #expect(!exists(scene.sidecar) && scene.temporaries().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scene.roll.path)
        _ = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(try exists(scene.sidecar) && PatchStore.packEntries(at: scene.pack)?.map(\.id) == [ref.id])
    }
}

// MARK: a frame's files

@Suite struct PatchFrameFilesTests {
    private struct Scene {
        let root: URL, roll: URL, other: URL, trash: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("argent-patch-files-\(UUID().uuidString)")
            roll = root.appendingPathComponent("Roll")
            other = root.appendingPathComponent("Other")
            trash = root.appendingPathComponent("Trash")
            for folder in [roll, other, trash] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        }

        /// A raw in the roll with a recipe beside it, and the masks' and the patches' packs when asked.
        func raw(_ name: String, masks: Bool = false, patches: Bool = false) throws -> URL {
            let url = roll.appendingPathComponent(name)
            try Data("raw \(name) \(UUID().uuidString)".utf8).write(to: url)
            try Data("recipe of \(name)".utf8).write(to: RecipeStore.besideRaw(url))
            if masks { try Data("masks of \(name)".utf8).write(to: RecipeStore.masksBesideRaw(url)) }
            if patches { try Data("patches of \(name)".utf8).write(to: RecipeStore.patchesBesideRaw(url)) }
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

    @Test func aFramesCompanionsAreItsRecipeItsMasksAndItsPatches() {
        let raw = URL(fileURLWithPath: "/rolls/day/DSC00601.ARW")
        #expect(FrameFiles.companions(of: raw).map(\.lastPathComponent) == ["DSC00601.argent", "DSC00601.argentmasks", "DSC00601.argentpatches"])
    }

    @Test func aFrameMovesWithItsPatches() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let removed = try scene.raw("DSC1.ARW", masks: true, patches: true), onlyPatches = try scene.raw("DSC2.ARW", patches: true)
        _ = try scene.raw("DSC3.ARW", patches: true)
        let outcomes = FrameFiles.move([removed, onlyPatches], into: scene.other)
        #expect(outcomes == [.moved(scene.other.appendingPathComponent("DSC1.ARW")), .moved(scene.other.appendingPathComponent("DSC2.ARW"))])
        #expect(scene.names(in: scene.other) == ["DSC1.ARW", "DSC1.argent", "DSC1.argentmasks", "DSC1.argentpatches",
                                                 "DSC2.ARW", "DSC2.argent", "DSC2.argentpatches"])
        // The frame left behind keeps its own.
        #expect(scene.names(in: scene.roll) == ["DSC3.ARW", "DSC3.argent", "DSC3.argentpatches"])
        #expect(try String(contentsOf: scene.other.appendingPathComponent("DSC1.argentpatches"), encoding: .utf8) == "patches of DSC1.ARW")
    }

    /// A pack there under the frame's name, with no raw, would be read as the frame's and written over: the frame stays whole.
    @Test func aPatchesPackAlreadyThereKeepsTheFrameWhereItWas() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let raw = try scene.raw("DSC1.ARW", patches: true)
        let theirs = scene.other.appendingPathComponent("DSC1.argentpatches")
        try Data("another frame's".utf8).write(to: theirs)
        #expect(FrameFiles.move([raw], into: scene.other) == [.nameTaken])
        #expect(scene.names(in: scene.roll) == ["DSC1.ARW", "DSC1.argent", "DSC1.argentpatches"])
        #expect(scene.names(in: scene.other) == ["DSC1.argentpatches"])
        #expect(try String(contentsOf: theirs, encoding: .utf8) == "another frame's")
        // Taken even for a frame that has no pack of its own to bring.
        let plain = try scene.raw("DSC2.ARW")
        try Data("another frame's".utf8).write(to: scene.other.appendingPathComponent("DSC2.argentpatches"))
        #expect(FrameFiles.move([plain], into: scene.other) == [.nameTaken])
        #expect(FileManager.default.fileExists(atPath: plain.path))
    }

    @Test func theTrashTakesTheFrameWithItsPatches() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let removed = try scene.raw("DSC1.ARW", masks: true, patches: true), kept = try scene.raw("DSC2.ARW", patches: true)
        let outcomes = FrameFiles.trash([removed], trashing: scene.trashing)
        #expect(outcomes == [.moved(scene.trash.appendingPathComponent("DSC1.ARW"))])
        #expect(scene.names(in: scene.trash) == ["DSC1.ARW", "DSC1.argent", "DSC1.argentmasks", "DSC1.argentpatches"])
        #expect(scene.names(in: scene.roll) == ["DSC2.ARW", "DSC2.argent", "DSC2.argentpatches"])
        // A Trash that refuses the raw leaves the frame whole, its pack with it.
        struct Refused: Error {}
        #expect(!FrameFiles.trash([kept]) { _ in throw Refused() }[0].isMoved)
        #expect(scene.names(in: scene.roll) == ["DSC2.ARW", "DSC2.argent", "DSC2.argentpatches"])
    }
}

// MARK: the develop

@Suite struct PatchDevelopTests {
    /// Why a frame cannot print what was removed from it: the first removal that is on whose patch is missing or does not hash,
    /// named by its row. One that is off is not looked for, and a patch two removals share is read once.
    @Test func aFramesFirstUnusablePatchIsNamedByItsRow() throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let sound = try scene.store.store(try patch(100)), lost = try patch(101).ref, damaged = try scene.store.store(try patch(102))
        try Data("not a patch".utf8).write(to: scene.store.url(for: damaged.id))
        #expect(RollDeveloper.patchFailure([], store: scene.store) == nil)
        #expect(RollDeveloper.patchFailure([removal(sound), removal(sound), removal(lost, isOn: false), removal(damaged, isOn: false)], store: scene.store) == nil)
        #expect(RollDeveloper.patchFailure([removal(sound), removal(lost), removal(damaged)], store: scene.store)
            == "A removal’s pixels (\(lost.id.hex.prefix(12))) are missing from the library (Removal 2); delete it and remove the object again")
        #expect(RollDeveloper.patchFailure([removal(lost, isOn: false), removal(sound), removal(damaged)], store: scene.store)
            == "A removal’s pixels (\(damaged.id.hex.prefix(12))) are damaged (Removal 3); delete it and remove the object again")
    }

    /// A lost patch, and one that does not hash, fail the frame before it is let in to decode, with the reason: a develop never
    /// prints the object back. With its patch there, or its removal off, the frame goes on to its decode, which this stand-in
    /// raw fails.
    @Test func aLostOrDamagedPatchFailsTheFrameBeforeItsDecode() async throws {
        let scene = try PatchScene()
        defer { scene.remove() }
        let developer = try RollDeveloper(stocks: [scene.stock], software: "Argent test", library: scene.library,
                                          digests: SourceDigests(settle: 0), decoderChoices: DecoderChoices(route: .apple))
        let stages = Recorded<RollDeveloper.Stage>()
        developer.observeStage = { _, stage, _ in stages.add(stage) }
        func develop(_ removals: [Removal]) async throws -> RollDeveloper.Outcome {
            let job = RollDeveloper.Job(frame: scene.frame, recipe: try scene.recipe(removals, revision: 1))
            return await developer.develop([job], to: scene.root.appendingPathComponent("out"), output: OutputSettings())[0]
        }
        let lost = try patch(110)
        guard case .failed(let missing) = try await develop([removal(lost.ref)]) else { Issue.record("A lost patch must fail its frame"); return }
        #expect(missing == "frame: A removal’s pixels (\(lost.identity.hex.prefix(12))) are missing from the library (Removal 1); "
            + "delete it and remove the object again")
        let file = scene.store.url(for: try scene.store.store(lost).id)
        try Data(contentsOf: file).dropLast(9).write(to: file)
        guard case .failed(let damaged) = try await develop([removal(lost.ref)]) else { Issue.record("A damaged patch must fail its frame"); return }
        #expect(damaged.hasPrefix("frame: A removal’s pixels") && damaged.contains("are damaged (Removal 1)"))
        #expect(stages.all.isEmpty, "\(stages.all)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scene.root.appendingPathComponent("out").path).isEmpty)

        // A removal that is off composites nothing, so its patch is not looked for.
        let off = try await develop([removal(lost.ref, isOn: false)])
        guard case .failed(let reason) = off, !reason.contains("removal") else { Issue.record("\(off)"); return }
        #expect(stages.all.contains(.decode))
        // With its patch whole in the library, the frame is let in and decoded.
        try scene.store.store(lost)
        let before = stages.all.filter { $0 == .decode }.count
        guard case .failed(let decode) = try await develop([removal(lost.ref)]), !decode.contains("removal") else { Issue.record("decode"); return }
        #expect(stages.all.filter { $0 == .decode }.count > before)
        developer.trim()
    }
}

/// Runs only where the CC0 samples are present: real decodes, about a second each.
@Suite(.serialized, .rawDecodes) struct PatchDevelopSampleTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    private static let small = "ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW"
    private static let medium = "ILCE-7M4_DSC06675_FullFrame-LossLess-Compressed-Medium.ARW"
    static var hasSamples: Bool {
        [small, medium].allSatisfy { FileManager.default.fileExists(atPath: samples.appendingPathComponent($0).path) }
    }

    /// A roll of `names` from the samples in a folder of the test's own, each raw a link, never a file written to.
    private static func roll(_ names: [String], in root: URL) async throws -> [Frame] {
        let folder = root.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            let source = samples.appendingPathComponent(name), link = folder.appendingPathComponent(name)
            do { try FileManager.default.linkItem(at: source, to: link) } catch { try FileManager.default.copyItem(at: source, to: link) }
        }
        return await RollScanner.scan(folder).frames
    }

    private static func job(_ frame: Frame, removals: [Removal], stock: Stock) throws -> RollDeveloper.Job {
        let controls = RollControls()
        let baseline = AutomaticBaseline(sourceSHA256: try RecipeStore.sha256(of: frame.url), stockID: stock.id, stockDigest: stock.digest,
                                         controls: controls, aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
                                         baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
        let recipe = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                                     roll: controls, own: FrameControls(),
                                     manual: ManualEdit(adjustments: try ManualAdjustments().settingRemovals(removals), baseline: baseline),
                                     editRevision: 7, editLineage: "patch-roll")
        return RollDeveloper.Job(frame: frame, recipe: recipe)
    }

    /// A roll where one frame lost its patch still develops every other frame, one with a removal of its own among them, and the
    /// lost one fails alone, before its decode, saying why. The developed frame's patch travels beside its raw, not in the output folder.
    @Test(.enabled(if: PatchDevelopSampleTests.hasSamples))
    func aLostPatchFailsItsFrameAloneAndTheRollDevelops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentPatchRoll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library"), out = root.appendingPathComponent("out")
        let frames = try await Self.roll([Self.medium, Self.small], in: root)
        #expect(frames.count == 2)
        let stock = toyStock(), store = PatchStore(library: library)
        let lost = try patch(120).ref, kept = try store.store(try patch(121))
        let jobs = [try Self.job(frames[0], removals: [removal(lost)], stock: stock), try Self.job(frames[1], removals: [removal(kept)], stock: stock)]
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library)
        let decoded = Recorded<Int>()
        developer.observeStage = { index, stage, begins in if stage == .decode, begins { decoded.add(index) } }
        let outcomes = await developer.develop(jobs, to: out, output: OutputSettings(size: .longEdge2048))
        guard case .failed(let reason) = outcomes[0] else { Issue.record("\(outcomes)"); return }
        #expect(reason == "\(frames[0].name): A removal’s pixels (\(lost.id.hex.prefix(12))) are missing from the library (Removal 1); "
            + "delete it and remove the object again", "\(reason)")
        guard case .developed(let file) = outcomes[1] else { Issue.record("\(outcomes)"); return }
        #expect(FileManager.default.fileExists(atPath: file.path) && file.lastPathComponent.hasPrefix(frames[1].name))
        // Only the other frame was decoded; the output folder holds only its developed image.
        #expect(decoded.all == [1], "\(decoded.all)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [file.lastPathComponent])
        // The raw's own pack holds the patch its recipe names.
        #expect(try PatchStore.packEntries(at: RecipeStore.patchesBesideRaw(frames[1].url))?.map(\.id) == [kept.id])
        #expect(!exists(RecipeStore.besideRaw(frames[0].url)) && !exists(RecipeStore.patchesBesideRaw(frames[0].url)))
        developer.trim()
    }

    /// A patch found whole before the decode and damaged during it: the lane reads it again for the stage, fails the frame, and
    /// writes nothing, rather than print the object back.
    @Test(.enabled(if: PatchDevelopSampleTests.hasSamples))
    func aPatchDamagedDuringTheDecodeFailsTheFrameAndWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentPatchSample-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library"), out = root.appendingPathComponent("out")
        let frame = try #require(try await Self.roll([Self.small], in: root).first)
        let stock = toyStock(), store = PatchStore(library: library)
        let ref = try store.store(try patch(130)), file = store.url(for: ref.id)
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library)
        developer.observeStage = { _, stage, begins in
            if stage == .decode, begins { try? Data("not a patch".utf8).write(to: file) }
        }
        let outcomes = await developer.develop([try Self.job(frame, removals: [removal(ref)], stock: stock)], to: out,
                                               output: OutputSettings(size: .longEdge2048))
        guard case .failed(let reason) = outcomes[0] else { Issue.record("\(outcomes)"); return }
        #expect(reason.contains("are damaged (Removal 1)") && reason.contains("remove the object again"), "\(reason)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        #expect(!exists(RecipeStore.besideRaw(frame.url)))
        developer.trim()
    }

    /// A read-only RAW folder with a removal and a smart mask: developing writes only the image into the output folder, leaves the
    /// RAW folder untouched, keeps the recipe, seeds, patches, and receipt in the library, and skips cleanly when developed again.
    @Test(.enabled(if: PatchDevelopSampleTests.hasSamples))
    func aReadOnlyRollWithMasksAndRemovalsWritesOnlyTheImageToOutputAndResumesFromLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentReadOnlyRoll-\(UUID().uuidString)")
        let rollDir = root.appendingPathComponent("roll")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rollDir.path)
            try? FileManager.default.removeItem(at: root)
        }
        let library = root.appendingPathComponent("library"), out = root.appendingPathComponent("out")
        let frame = try #require(try await Self.roll([Self.small], in: root).first)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rollDir.path)
        let stock = toyStock()
        let patchRef = try PatchStore(library: library).store(try patch(140))
        let seedRef = try MaskRasterStore(library: library).store(try MaskRaster(width: 64, height: 48, plane: (0..<(64 * 48)).map { UInt8(truncatingIfNeeded: $0) }))
        let seedFrame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let masks = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(.init(kind: .sky, raster: seedRef, frame: seedFrame)))],
                                             adjustments: try ManualAdjustments(exposureEV: -0.5))])
        let controls = RollControls()
        let baseline = AutomaticBaseline(sourceSHA256: try RecipeStore.sha256(of: frame.url), stockID: stock.id, stockDigest: stock.digest,
                                         controls: controls, aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
                                         baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
        let adjustments = try ManualAdjustments(masks: masks).settingRemovals([removal(patchRef)])
        let recipe = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                                     roll: controls, own: FrameControls(),
                                     manual: ManualEdit(adjustments: adjustments, baseline: baseline),
                                     editRevision: 4, editLineage: "locked-card")
        let digests = SourceDigests(settle: 0), writer = RecipeWriter(digests: digests)
        let saved = try await writer.commit(recipe: recipe, for: frame, library: library)
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library, digests: digests, recipeWriter: writer)
        let output = OutputSettings(size: .longEdge2048)

        let first = await developer.develop([RollDeveloper.Job(frame: frame, recipe: saved)], to: out, output: output)
        guard case .developed(let file) = first.first else { Issue.record("\(first)"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [file.lastPathComponent])
        #expect(try FileManager.default.contentsOfDirectory(atPath: rollDir.path) == [frame.url.lastPathComponent])

        // Reopen via a fresh writer using only the library: edits, masks, removals, and receipt come back and develop skips.
        let reloaded = try #require(try await RecipeWriter(digests: digests).load(for: frame, library: library))
        #expect(reloaded.manual?.adjustments.masks.rasters == [seedRef])
        #expect(reloaded.manual?.adjustments.removals.map(\.patch) == [patchRef])
        #expect(reloaded.develops.map(\.file) == [file.path])
        let second = await developer.develop([RollDeveloper.Job(frame: frame, recipe: reloaded)], to: out, output: output)
        #expect(second == [.alreadyDeveloped(file)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [file.lastPathComponent])
        #expect(try FileManager.default.contentsOfDirectory(atPath: rollDir.path) == [frame.url.lastPathComponent])
        developer.trim()
    }
}
