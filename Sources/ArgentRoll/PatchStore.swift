import ArgentCore
import Foundation

/// Removals' patches: the pixels a removal names (`Removal.patch`), kept in the recipe library beside the masks' seeds, in
/// `Patches/v1` (docs/remove-plan.md, section 4.7). A patch is a result stored with the edit, so a saved edit never runs the model
/// again: it lives in Application Support's library, never in Caches, which the system may purge.
///
/// One file a patch, named by `RemovalPatch.identity`, the hash of its box, sizes and planes and not of its file, so a patch is kept
/// once however often it is saved, undone or redone. The file mechanics are `ContentStore`'s, shared with `MaskRasterStore`: a file
/// is written beside its name, flushed and renamed, so a crash leaves the whole file or a `.tmp-*`; `store` returns only once that
/// is done, and only then does the model put the removal in the edit, so no record names nothing.
///
/// Nothing deletes a patch but `collectGarbage`, and it keeps every patch a record in the library names, current or held, every
/// patch the caller says an undo step names, and every file younger than a week. `load` recomputes a file's identity from its
/// planes, so a damaged file is refused, never composited as something else.
///
/// A store is a value: its folder comes from the call's library, so a test's library has its own patches.
public struct PatchStore: Sendable {
    /// Below the library, beside `Masks/v1`. A new layout is `v2` beside it, never a change to this one.
    public static let folderName = "Patches/v1"
    public static let fileExtension = "argentpatch"
    /// A pack's extension, beside a sidecar's `argent` and the masks' `argentmasks`.
    public static let packExtension = "argentpatches"
    /// How long a patch no record names is kept, and a temporary file: the seeds' ages, for the seeds' reasons. Try Again leaves
    /// the patch it replaced for an undo to return to, and a week outlasts a session's history.
    public static let orphanAge = MaskRasterStore.orphanAge
    public static let temporaryAge = MaskRasterStore.temporaryAge
    /// What a source holds unpacked: eight patches of the model's largest size, 14.5 MB each at 1344 by 1344, or forty of 640
    /// by 640, which is the frame being edited and its neighbours on the sheet.
    public static let cacheBytes = 128 << 20
    static let packMagic = Data("ARGENT-PATCHES-1\n".utf8)

    public let library: URL
    public let folder: URL
    private static let kind = ContentStore.Kind(folderName: folderName, fileExtension: fileExtension, packMagic: packMagic)
    var content: ContentStore { ContentStore(library: library, kind: Self.kind) }

    public init(library: URL) {
        self.library = library
        folder = library.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    public enum Failure: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
        /// No file of that name in the library, or an empty one.
        case missing(PatchID)
        /// A file that does not unpack to the pixels its name is the hash of.
        case damaged(PatchID)
        case unwritable(String)
        /// A `.argentpatches` file that is not a pack this build reads.
        case notAPack(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let id): return "A removal’s pixels (\(id.hex.prefix(12))) are missing from the library"
            case .damaged(let id): return "A removal’s pixels (\(id.hex.prefix(12))) are damaged"
            case .unwritable(let why): return "A removal’s pixels could not be saved: \(why)"
            case .notAPack(let name): return "\(name) is not a patch pack this build reads"
            }
        }
        public var description: String { errorDescription ?? "A removal’s pixels cannot be used" }
    }

    /// `ContentStore`'s failures in this store's words.
    private static func inOwnWords<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as ContentStore.Failure {
            switch failure {
            case .unwritable(let why): throw Failure.unwritable(why)
            case .notAPack(let name): throw Failure.notAPack(name)
            }
        }
    }

    /// `Patches/v1/ab/abcdef….argentpatch`.
    public func url(for id: PatchID) -> URL { content.url(for: id.hex) }

    /// Whether the library has a non-empty file for `id`. It does not unpack it: `load` does.
    public func contains(_ id: PatchID) -> Bool { content.contains(id.hex) }

    /// The patches in `refs` the library cannot load and validate, each once, in order.
    public func missing(_ refs: [PatchRef]) -> [PatchRef] {
        var seen = Set<PatchID>()
        return refs.filter { seen.insert($0.id).inserted && (try? load($0)) == nil }
    }

    /// Refreshes the date of each file `ids` names that the library has, so the sweep counts it young.
    public func keepAlive(_ ids: [PatchID]) { content.keepAlive(ids.map(\.hex)) }

    // MARK: store and load

    /// Keeps `patch`, once, and returns its ref only after its file is on the disk and flushed. A file already there is kept if it
    /// holds these pixels, and replaced if it is damaged.
    @discardableResult
    public func store(_ patch: RemovalPatch) throws -> PatchRef {
        let ref = patch.ref
        if keepIfSound(ref) { return ref }
        let file: Data
        do { file = try patch.encoded() } catch { throw Failure.unwritable("its pixels could not be packed") }
        try durableWrite(file, for: ref.id)
        return ref
    }

    /// The patch `ref` names, checked: unpacked, at `ref`'s size, and its identity recomputed from its planes.
    public func load(_ ref: PatchRef) throws -> RemovalPatch {
        let file = url(for: ref.id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.missing(ref.id) }
        guard let data = try? Data(contentsOf: file) else { throw Failure.damaged(ref.id) }
        guard !data.isEmpty else { throw Failure.missing(ref.id) }
        guard let patch = try? RemovalPatch(decoding: data), patch.ref == ref else { throw Failure.damaged(ref.id) }
        return patch
    }

    /// Whether the library already holds `ref`'s pixels; if so its date is refreshed, under the lock the sweep takes.
    private func keepIfSound(_ ref: PatchRef) -> Bool {
        content.keepIfSound(ref.id.hex) { (try? load(ref)) != nil }
    }

    /// A patch's file, written so that a crash leaves the whole file or a `.tmp-*` (`ContentStore.durableWrite`). The fault a test
    /// sets before the rename is the seeds': one library has one of each, and a test's library is its own.
    private func durableWrite(_ file: Data, for id: PatchID) throws {
        try Self.inOwnWords { try ContentStore.durableWrite(file, to: url(for: id), library: library, fault: .rasterBeforeRename) }
    }

    // MARK: the source the lens stage reads

    /// What the lens stage reads patches through: `load` behind a cache of the patches a roll's frames name, so a preview does not
    /// unpack megabytes each time its stage runs. A patch that is missing or damaged is `nil` there.
    public func source() -> any RemovalPatchSource { Cache(self) }

    /// The bytes a patch of `ref`'s size holds unpacked: three half floats and two alphas a pixel.
    public static func byteCount(of ref: PatchRef) -> Int {
        ref.width * ref.height * (3 * MemoryLayout<Float16>.size + 2)
    }

    /// `load` behind a cache by `PatchRef`, bounded in bytes: the patches read last stay, and the one read longest ago goes first.
    /// A patch is checked when it is read from the disk, so what the cache gives was sound then; nothing is kept of a patch that
    /// is missing or damaged, so one that arrives later, from a pack or from Try Again, is found the next time it is asked for.
    /// Safe to call from any thread.
    public final class Cache: RemovalPatchSource, @unchecked Sendable {
        public let store: PatchStore
        public let maximumBytes: Int
        private let lock = NSLock()
        private var held: [PatchRef: (patch: RemovalPatch, used: UInt64)] = [:]
        private var bytes = 0
        private var uses: UInt64 = 0

        public init(_ store: PatchStore, maximumBytes: Int = PatchStore.cacheBytes) {
            self.store = store
            self.maximumBytes = maximumBytes
        }

        /// The unpacked bytes it holds now.
        public var residentBytes: Int { lock.withLock { bytes } }

        public func patch(_ ref: PatchRef) -> RemovalPatch? {
            let kept: RemovalPatch? = lock.withLock {
                guard let entry = held[ref] else { return nil }
                uses += 1
                held[ref] = (entry.patch, uses)
                return entry.patch
            }
            if let kept {
                // A patch whose file has gone is missing here as it is to a develop and to its row, though its pixels are still
                // in hand: a preview then never shows what a develop would refuse.
                if store.contains(ref.id) { return kept }
                lock.withLock { drop(ref) }
                return nil
            }
            // Unpacked outside the lock, so one patch's read does not hold up another's. Two threads asking for one patch at once
            // may both read it, and the second replaces the first.
            guard let loaded = try? store.load(ref) else { return nil }
            let size = PatchStore.byteCount(of: ref)
            guard size <= maximumBytes else { return loaded }
            lock.withLock {
                drop(ref)
                uses += 1
                held[ref] = (loaded, uses)
                bytes += size
                while bytes > maximumBytes, let oldest = held.min(by: { $0.value.used < $1.value.used })?.key { drop(oldest) }
            }
            return loaded
        }

        /// Lets go of every patch it holds: a develop's, once it is over.
        public func trim() {
            lock.withLock {
                held.removeAll()
                bytes = 0
            }
        }

        /// Called under the lock.
        private func drop(_ ref: PatchRef) {
            guard held.removeValue(forKey: ref) != nil else { return }
            bytes -= PatchStore.byteCount(of: ref)
        }
    }

    // MARK: packs: the patches that travel beside a raw

    /// Writes the patches `refs` names into one pack at `url`, each checked as `load` checks it, flushed and renamed into place: the
    /// pack beside a raw before the sidecar that names its removals. Leaves a pack that already
    /// holds exactly these files as it is.
    public func writePack(_ refs: [PatchRef], to url: URL) throws { try writePack(refs, to: url, fault: nil) }

    func writePack(_ refs: [PatchRef], to url: URL, fault: MaskWriteFault?) throws {
        var unique: [PatchRef] = [], seen = Set<PatchID>()
        for ref in refs where seen.insert(ref.id).inserted { unique.append(ref) }
        let byName = Dictionary(uniqueKeysWithValues: unique.map { ($0.id.hex, $0) })
        try Self.inOwnWords {
            try content.writePack(unique.map(\.id.hex), to: url, fault: fault) { hex in _ = try load(byName[hex]!) }
        }
    }

    /// The ids a pack at `url` lists and each one's length, read from its header alone; `nil` when there is no such file, and
    /// `notAPack` when there is one this build cannot read.
    public static func packEntries(at url: URL) throws -> [(id: PatchID, length: Int)]? {
        try inOwnWords { try ContentStore.packEntries(at: url, magic: packMagic) }?.map { (PatchID(hex: $0.hex)!, $0.length) }
    }

    /// What `importPack` did.
    public struct PackImport: Sendable, Equatable {
        /// Taken into the library, each checked.
        public var added: [PatchID] = []
        /// Entries that did not unpack to the pixels their id names: left out, never kept.
        public var damaged: [PatchID] = []
    }

    /// Takes into the library the patches of the pack at `url` that it lacks, `wanted` ones only when given, each checked as `load`
    /// checks it: a raw and its pack that reach another Mac, or a library lost, give their removals back. A patch the library has
    /// is left as it is, its date refreshed; a damaged entry is left out.
    @discardableResult
    public func importPack(from url: URL, wanted: Set<PatchID>? = nil) throws -> PackImport {
        var result = PackImport()
        _ = try Self.inOwnWords {
            try content.readPack(at: url, wanted: wanted.map { Set($0.map(\.hex)) }) { hex, blob in
                let id = PatchID(hex: hex)!
                guard let patch = try? RemovalPatch(decoding: blob), patch.identity == id else { result.damaged.append(id); return }
                if keepIfSound(patch.ref) { return }
                try durableWrite(blob, for: id)
                result.added.append(id)
            }
        }
        return result
    }

    // MARK: garbage

    /// What a sweep did: the files it removed, or why it removed none.
    public struct Sweep: Sendable, Equatable {
        public var removed: [String] = []
        /// Set when a record could not be read, so the patches it may name are unknown and nothing was removed.
        public var skipped: String?
    }

    /// Removes the patches no record in `library` names and nothing in `keeping` names, once they are `orphanAge` old, and
    /// temporary files once they are `temporaryAge` old. `keeping` is what the caller holds beyond the library's records: the
    /// patches of its open edits and of any undo step, which is where the result Try Again replaced waits to come back. A record
    /// it cannot read (a newer build's, say) may name any patch, so then it removes nothing.
    public static func sweep(library: URL, keeping: Set<PatchID> = [], now: Date = Date()) -> Sweep {
        let named: Set<PatchID>
        do { named = try namedPatches(in: library) } catch {
            return Sweep(skipped: "a recipe in the library could not be read: \(error.localizedDescription)")
        }
        return Sweep(removed: PatchStore(library: library).collectGarbage(keeping: named.union(keeping), now: now))
    }

    /// Every patch a record in `library` names, in its current edit or its held one, shown or not.
    /// Throws when any record cannot be read.
    public static func namedPatches(in library: URL) throws -> Set<PatchID> {
        try RecipeWriter.namedAssetIDs(in: library) { recipe in
            RecipeWriter.patchRefs(of: recipe).map(\.id)
        }
    }

    /// Removes what `sweep` would, given the patches to keep: every patch a record names, current or held, and every patch an
    /// undo step names. Files that are not this store's are left alone.
    public func collectGarbage(keeping live: Set<PatchID>, now: Date = Date()) -> [String] {
        content.collectGarbage(keeping: Set(live.map(\.hex)), orphanAge: Self.orphanAge, temporaryAge: Self.temporaryAge, now: now)
    }
}
