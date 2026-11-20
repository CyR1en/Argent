import ArgentCore
import CryptoKit
import Foundation

/// One ordered authority for working recipes and export receipts. A completed export only
/// contributes history; it never replaces settings from a newer acknowledged edit.
public actor RecipeWriter {
    public static let shared = RecipeWriter()

    public enum Failure: Error, LocalizedError {
        case sourceChanged(Recipe)
        case sourceIdentity
        case conflict(String)
        case unsafeLineage
        /// A record names a smart mask's seed the library does not hold, and the pack beside the raw does not either: nothing is
        /// written, so no record names nothing (`MaskRasterStore`).
        case missingRaster(RasterID)
        /// A record names a removal's patch the library does not hold, and the pack beside the raw does not either: nothing is
        /// written, so no record names nothing (`PatchStore`).
        case missingPatch(PatchID)

        public var errorDescription: String? {
            switch self {
            case .sourceChanged:
                return "The RAW changed since these adjustments were saved. Reapply Adjustments to attach them to this image."
            case .sourceIdentity: return "The RAW could not be verified for saving. Try again when it is available."
            case .conflict(let reason): return "The saved recipe conflicts with another edit: \(reason). Both records have been preserved."
            case .unsafeLineage: return "The recipe has an invalid edit lineage. It has been preserved."
            case .missingRaster(let id):
                return "A mask’s selection (\(id.hex.prefix(12))) is not in the library, so these adjustments were not saved. Remove the mask or make its selection again."
            case .missingPatch(let id):
                return "A removal’s pixels (\(id.hex.prefix(12))) are not in the library, so these adjustments were not saved. Delete the removal and remove the object again."
            }
        }
    }

    private struct Binding: Codable {
        var sha256: String
        var lineage: String
    }
    private struct Pending: Sendable {
        var recipe: Recipe
        var frame: Frame
        var library: URL
        /// An export's receipt rather than an edit, which the app saves again itself.
        var isReceipt = false
    }
    private let digests: SourceDigests
    private var pending: [String: Pending] = [:]

    public init(digests: SourceDigests = .shared) { self.digests = digests }

    /// Every smart mask's seed a record names, in its current edit and its held one. Receipts keep a digest of their masks and name none.
    public static func rasterRefs(of recipe: Recipe) -> [RasterRef] {
        (recipe.manual?.adjustments.masks.rasters ?? []) + (recipe.heldManual?.adjustments.masks.rasters ?? [])
    }

    /// Every removal's patch a record names, in its current edit and its held one, shown or not, each once. Receipts keep the
    /// removals of the render they were made with and are not read here: a patch only a receipt names is no longer the edit's.
    public static func patchRefs(of recipe: Recipe) -> [PatchRef] {
        ((recipe.manual?.adjustments.removals ?? []) + (recipe.heldManual?.adjustments.removals ?? [])).patches
    }

    /// The working records, their backups, and the library's copies of locked-card recipes.
    /// A record that cannot be read stops the sweep before it removes anything.
    static func namedAssetIDs<ID: Hashable>(in library: URL, extracting ids: (Recipe) -> [ID]) throws -> Set<ID> {
        var files: [URL] = []
        let manual = library.appendingPathComponent("ManualDevelopment/v2", isDirectory: true)
        if let walker = FileManager.default.enumerator(at: manual, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) {
            for case let url as URL in walker {
                if url.lastPathComponent == "Bindings" { walker.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, url.pathExtension == "json" else { continue }
                files.append(url)
            }
        }
        let top = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        files += top.filter { $0.pathExtension == Recipe.fileExtension }
        var named = Set<ID>()
        for file in files {
            let recipe = try Recipe.decodeStrict(Data(contentsOf: file))
            named.formUnion(ids(recipe))
        }
        return named
    }

    /// Every seed `recipe` names is in `library`'s store before anything is written, taken from the pack beside the raw where the
    /// library lacks it, so a record is never written naming a seed that is nowhere.
    private func requireRasters(_ recipe: Recipe, frame: Frame, library: URL) throws {
        let refs = Self.rasterRefs(of: recipe)
        guard !refs.isEmpty else { return }
        let store = MaskRasterStore(library: library)
        var lacking = store.missing(refs)
        if !lacking.isEmpty {
            _ = try? store.importPack(from: RecipeStore.masksBesideRaw(frame.url), wanted: Set(lacking.map(\.id)))
            lacking = store.missing(lacking)
        }
        if let lost = lacking.first { throw Failure.missingRaster(lost.id) }
    }

    /// Every patch `recipe` names is in `library`'s store before anything is written, as every seed is (`requireRasters`), so a
    /// record is never written naming a removal whose pixels are nowhere.
    private func requirePatches(_ recipe: Recipe, frame: Frame, library: URL) throws {
        let refs = Self.patchRefs(of: recipe)
        guard !refs.isEmpty else { return }
        let store = PatchStore(library: library)
        var lacking = store.missing(refs)
        if !lacking.isEmpty {
            _ = try? store.importPack(from: RecipeStore.patchesBesideRaw(frame.url), wanted: Set(lacking.map(\.id)))
            lacking = store.missing(lacking)
        }
        if let lost = lacking.first { throw Failure.missingPatch(lost.id) }
    }

    /// The seeds `recipe` names that the library lacks, from the pack beside the raw, each checked: a roll moved, or brought from
    /// another Mac, keeps its masks. Those it has are counted young, so the sweep keeps what a record outside the journal names while
    /// its roll is in use. A seed in neither stays missing: the frame shows it, and a develop refuses it.
    private func restoreRasters(for recipe: Recipe, frame: Frame, library: URL) {
        let store = MaskRasterStore(library: library)
        restore(Self.rasterRefs(of: recipe), id: \.id, missing: store.missing,
                importPack: { _ = try store.importPack(from: RecipeStore.masksBesideRaw(frame.url), wanted: $0) },
                keepAlive: store.keepAlive)
    }

    /// The patches `recipe` names that the library lacks, from the pack beside the raw, and those it has counted young, as the
    /// seeds are (`restoreRasters`): a roll moved, or brought from another Mac, keeps what was removed. A patch in neither stays
    /// missing: its row says so, and a develop refuses the frame.
    private func restorePatches(for recipe: Recipe, frame: Frame, library: URL) {
        let store = PatchStore(library: library)
        restore(Self.patchRefs(of: recipe), id: \.id, missing: store.missing,
                importPack: { _ = try store.importPack(from: RecipeStore.patchesBesideRaw(frame.url), wanted: $0) },
                keepAlive: store.keepAlive)
    }

    private func restore<Ref, ID: Hashable>(_ refs: [Ref], id: KeyPath<Ref, ID>,
                                           missing: ([Ref]) -> [Ref], importPack: (Set<ID>) throws -> Void,
                                           keepAlive: ([ID]) -> Void) {
        guard !refs.isEmpty else { return }
        let lacking = missing(refs)
        if !lacking.isEmpty {
            try? importPack(Set(lacking.map { $0[keyPath: id] }))
        }
        keepAlive(refs.map { $0[keyPath: id] })
    }

    /// The packs of the seeds and of the patches `recipe` names, beside the raw: `true` once each holds them, or when none is
    /// needed. A read-only card, or a seed or a patch the library has lost, leaves a pack as it was and returns `false`, and the
    /// sidecar is then left as it was too.
    private func publishPacks(_ recipe: Recipe, for frame: Frame, library: URL) -> Bool {
        let seeds = Self.rasterRefs(of: recipe), patches = Self.patchRefs(of: recipe)
        do {
            if !seeds.isEmpty {
                try MaskRasterStore(library: library).writePack(seeds, to: RecipeStore.masksBesideRaw(frame.url), fault: .packBesideRaw)
            }
            if !patches.isEmpty {
                try PatchStore(library: library).writePack(patches, to: RecipeStore.patchesBesideRaw(frame.url), fault: .packBesideRaw)
            }
            return true
        } catch { return false }
    }

    public static func journalURL(sha256: String, lineage: String, library: URL = RecipeStore.defaultLibrary) -> URL {
        library.appendingPathComponent("ManualDevelopment/v2", isDirectory: true)
            .appendingPathComponent(sha256, isDirectory: true).appendingPathComponent(lineage).appendingPathExtension("json")
    }

    private func key(_ frame: Frame, _ library: URL) -> String { library.canonicalPath + "|" + frame.url.canonicalPath }
    private func bindingURL(_ frame: Frame, _ library: URL) -> URL {
        let pathHash = SHA256.hash(data: Data(frame.url.canonicalPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return library.appendingPathComponent("ManualDevelopment/v2/Bindings", isDirectory: true)
            .appendingPathComponent(pathHash).appendingPathExtension("json")
    }

    /// Restores only records bound to the verified bytes. A v1 binary's overwritten sidecar
    /// cannot outrank its protected working record. Separately edited lineages require review.
    public func load(for frame: Frame, library: URL? = nil) throws -> Recipe? {
        let library = library ?? RecipeStore.defaultLibrary
        let verified = try digests.digest(of: frame.url)
        let recipe: Recipe?
        do { recipe = try read(frame, verified: verified, library: library) }
        catch Failure.sourceChanged(let old) {
            // Held by the model for a Reapply, its seeds and its patches as they were.
            restoreRasters(for: old, frame: frame, library: library)
            restorePatches(for: old, frame: frame, library: library)
            throw Failure.sourceChanged(old)
        }
        if let recipe {
            restoreRasters(for: recipe, frame: frame, library: library)
            restorePatches(for: recipe, frame: frame, library: library)
        }
        if let recipe, recipe.raw.sha256 == verified.sha256, recipe.editLineage != nil {
            if try readFile(RecipeStore.besideRaw(frame.url)) != recipe {
                try persist(recipe, for: frame, library: library)
            } else {
                // The sidecar is current and its packs may not be: deleted since, or never written by a save a crash cut short.
                _ = publishPacks(recipe, for: frame, library: library)
            }
        }
        return recipe
    }

    private func readFile(_ url: URL) throws -> Recipe? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Recipe.decodeStrict(Data(contentsOf: url))
    }

    /// Whether `recipe` is the record of `frame`'s raw: it names the raw, or a file no longer beside
    /// it, as a raw renamed since leaves it, or one beside it with other bytes, as raws renumbered
    /// leave it. One naming another raw beside it that has the record's bytes is that raw's, as a
    /// frame copied over another of its roll has its own; so is one whose neighbour cannot be read.
    private func isRecord(_ recipe: Recipe, of frame: Frame) -> Bool {
        guard recipe.raw.fileName != frame.url.lastPathComponent, let sha = recipe.raw.sha256 else { return true }
        let named = frame.url.deletingLastPathComponent().appendingPathComponent(recipe.raw.fileName)
        guard let other = SourceStamp.of(named), let own = SourceStamp.of(frame.url),
              other.device != own.device || other.inode != own.inode else { return true }
        return (try? digests.digest(of: named).sha256).map { $0 != sha } ?? false
    }

    private func record(_ url: URL, of frame: Frame) throws -> Recipe? {
        guard let record = try readFile(url), isRecord(record, of: frame) else { return nil }
        return record
    }

    /// What a twin adds to the lineage it keeps its record under, beside the other raw's of the same
    /// bytes: derived from its name, so every save of the twin under that lineage reaches the same record.
    private static func twinSuffix(of frame: Frame) -> String {
        "-" + SHA256.hash(data: Data(frame.url.lastPathComponent.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func twinLineage(_ lineage: String, of frame: Frame) -> String { lineage + twinSuffix(of: frame) }

    /// `lineage` without what `frame`'s twin records add to it: the lineage of the frame's roll.
    public static func rollLineage(_ lineage: String, of frame: Frame) -> String {
        let suffix = twinSuffix(of: frame)
        var lineage = lineage
        while lineage.count > suffix.count, lineage.hasSuffix(suffix) { lineage.removeLast(suffix.count) }
        return lineage
    }

    /// Whether lineages `a` and `b` are one line of `frame`'s edits, its twin records' included.
    private static func sameLine(_ a: String?, _ b: String?, of frame: Frame) -> Bool {
        a.map { rollLineage($0, of: frame) } == b.map { rollLineage($0, of: frame) }
    }

    /// Where `frame`'s record of `sha256` under `lineage` goes: there, unless that record is
    /// another raw's, and then the twin's lineage.
    private func ownLineage(_ lineage: String, of frame: Frame, sha256: String, library: URL) throws -> String {
        guard let kept = try readFile(Self.journalURL(sha256: sha256, lineage: lineage, library: library)),
              !isRecord(kept, of: frame) else { return lineage }
        return Self.twinLineage(lineage, of: frame)
    }

    /// A record found by the verified bytes alone must be the only one of them naming the raw, and of
    /// the line of `continuing`, the lineage a commit or an export saves under, or else of the lineage
    /// the frame's place had before its raw was replaced.
    private func read(_ frame: Frame, verified: SourceDigests.Verified, library: URL,
                      allowReplacement: Bool = false, continuing: String? = nil) throws -> Recipe? {
        // A sidecar holding another raw's record, as a build before 2026-10-22 left twins', is not this raw's.
        let sidecar = try readFile(RecipeStore.besideRaw(frame.url)).flatMap { isRecord($0, of: frame) ? $0 : nil }
        let legacy = sidecar == nil ? try readFile(RecipeStore.inLibrary(frame, byteCount: Int(verified.source.size), library: library)) : nil
        let published = sidecar ?? legacy
        let bindingFile = bindingURL(frame, library)
        let binding: Binding?
        if FileManager.default.fileExists(atPath: bindingFile.path) {
            binding = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: bindingFile))
        } else { binding = nil }
        var protected: Recipe?
        if let binding, binding.sha256 == verified.sha256 {
            try validateLineage(binding.lineage)
            protected = try record(Self.journalURL(sha256: verified.sha256, lineage: binding.lineage, library: library), of: frame)
        }
        if protected == nil, let lineage = published?.editLineage, published?.raw.sha256 == verified.sha256 {
            try validateLineage(lineage)
            protected = try record(Self.journalURL(sha256: verified.sha256, lineage: lineage, library: library), of: frame)
        }
        if protected == nil {
            // Found by its bytes alone, as a moved roll's raw is. A raw put in place of another keeps the
            // lineage that place had, as its sidecar tells, so another roll's record of the same bytes is
            // not taken for its. A binding tells only what was last at the path, as another card mounted
            // at one path is.
            var lineages = continuing.map { [$0] } ?? []
            if continuing == nil, let published, let sha = published.raw.sha256, sha != verified.sha256,
               let lineage = published.editLineage { lineages = [lineage] }
            let directory = library.appendingPathComponent("ManualDevelopment/v2", isDirectory: true)
                .appendingPathComponent(verified.sha256, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                let records = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .compactMap { try record($0, of: frame) }
                if records.count > 1 { throw Failure.conflict("more than one lineage belongs to this RAW") }
                protected = records.first.flatMap { kept in
                    lineages.isEmpty || lineages.contains { Self.sameLine($0, kept.editLineage, of: frame) } ? kept : nil
                }
            }
        }
        if let protected, protected.raw.sha256 != verified.sha256 { throw Failure.conflict("working record has another RAW identity") }
        if let published, let manual = published.manual, manual.baseline.sourceSHA256 != verified.sha256 {
            if protected == nil && !allowReplacement { throw Failure.sourceChanged(published) }
        }
        var chosen = protected
        if let published, published.raw.sha256 == verified.sha256 {
            if let local = protected, published.version >= 2 {
                if let externalLineage = published.editLineage, externalLineage != local.editLineage {
                    throw Failure.conflict("the sidecar and working record have different lineages")
                }
                let localRevision = local.editRevision ?? 0, publishedRevision = published.editRevision ?? 0
                if localRevision == publishedRevision && !sameIntent(local, published) {
                    throw Failure.conflict("the same revision contains different settings")
                }
                chosen = publishedRevision > localRevision ? mergingHistory(published, local) : mergingHistory(local, published)
            } else if let local = protected {
                chosen = mergingHistory(local, published)
            } else { chosen = published }
        }
        if chosen == nil, let published {
            switch RecipeStore.match(published.raw, to: frame.url, byteCount: Int(verified.source.size), digests: digests) {
            case .same: chosen = published
            case .different: chosen = published.forgettingSource()
            case .unknown: chosen = published.forgettingMeasurement()
            }
        }
        if let waiting = pending[key(frame, library)], waiting.recipe.raw.sha256 == verified.sha256 {
            if let current = chosen {
                if let a = current.editLineage, let b = waiting.recipe.editLineage, a != b {
                    throw Failure.conflict("pending and saved edits have different lineages")
                }
                let savedRevision = current.editRevision ?? 0, waitingRevision = waiting.recipe.editRevision ?? 0
                if waitingRevision > savedRevision {
                    chosen = mergingHistory(waiting.recipe, current)
                } else {
                    if waitingRevision == savedRevision && !sameIntent(current, waiting.recipe) {
                        throw Failure.conflict("a pending revision contains different settings")
                    }
                    chosen = mergingHistory(current, waiting.recipe)
                }
            } else { chosen = waiting.recipe }
        }
        return chosen
    }

    private func sameIntent(_ a: Recipe, _ b: Recipe) -> Bool {
        a.stock == b.stock && a.roll == b.roll && a.frame == b.frame && a.rollStock == b.rollStock && a.manual == b.manual
            && a.heldManual == b.heldManual && a.render == b.render
    }

    private func mergingHistory(_ current: Recipe, _ other: Recipe) -> Recipe {
        var merged = current
        merged.develops = Self.mergedDevelops(current.develops, other.develops)
        merged.version = max(2, merged.version, merged.requiredVersion)
        return merged
    }

    /// Both records' receipts, each once, oldest first, the newest `Recipe.keptDevelops` of them.
    static func mergedDevelops(_ current: [Recipe.Develop], _ other: [Recipe.Develop]) -> [Recipe.Develop] {
        var history = current
        for receipt in other where !history.contains(where: { Recipe.sameDevelopReceipt($0, receipt) }) {
            history.append(receipt)
        }
        history.sort { $0.date < $1.date }
        return Array(history.suffix(Recipe.keptDevelops))
    }

    /// Durably saves a completed edit before publishing its sidecar. Older commits acknowledge
    /// the newer record instead of rolling it back. A failed write remains available to flush.
    @discardableResult
    public func commit(recipe: Recipe, for frame: Frame, library: URL? = nil) throws -> Recipe {
        let library = library ?? RecipeStore.defaultLibrary
        try recipe.validate()
        // First, so a record naming a seed or a patch that is nowhere writes nothing at all.
        try requireRasters(recipe, frame: frame, library: library)
        try requirePatches(recipe, frame: frame, library: library)
        let verified = try digests.digest(of: frame.url)
        if let sha = recipe.raw.sha256, sha != verified.sha256 { throw Failure.sourceIdentity }
        if let manual = recipe.manual, manual.baseline.sourceSHA256 != verified.sha256 { throw Failure.sourceIdentity }
        let canReplace = recipe.manual?.baseline.sourceSHA256 == verified.sha256
            || recipe.heldManual.map { $0.baseline.sourceSHA256 != verified.sha256 } == true
        let previous = try read(frame, verified: verified, library: library, allowReplacement: canReplace,
                                continuing: recipe.editLineage)
        var saved = recipe
        saved.version = max(2, saved.version, saved.requiredVersion)
        saved.raw.sha256 = verified.sha256
        saved.raw.byteCount = Int(verified.source.size)
        let lineage = saved.editLineage ?? previous?.editLineage ?? UUID().uuidString.lowercased()
        try validateLineage(lineage)
        saved.editLineage = lineage
        if let previous, let kept = previous.editLineage, !Self.sameLine(kept, lineage, of: frame),
           previous.raw.sha256 == verified.sha256 { throw Failure.conflict("a new commit has another lineage") }
        if let previous, (previous.editRevision ?? 0) > (saved.editRevision ?? 0), saved.editRevision != nil {
            saved = mergingHistory(previous, saved)
        } else {
            if saved.editRevision == nil { saved.editRevision = (previous?.editRevision ?? 0) + 1 }
            if let previous, saved.editRevision == previous.editRevision, !sameIntent(saved, previous) {
                throw Failure.conflict("a committed revision was reused for different settings")
            }
            saved = previous.map { mergingHistory(saved, $0) } ?? saved
            if previous?.editRevision != saved.editRevision { saved.editDate = Date() }
            else { saved.editDate = saved.editDate ?? Date() }
        }
        try validateLineage(saved.editLineage!)
        saved.editLineage = try ownLineage(saved.editLineage!, of: frame, sha256: verified.sha256, library: library)
        let id = key(frame, library)
        pending[id] = Pending(recipe: saved, frame: frame, library: library)
        do {
            try persist(saved, for: frame, library: library)
            pending.removeValue(forKey: id)
            return saved
        } catch { throw error }
    }

    /// Merges an exported image's develop receipt into the most recent editing revision in the
    /// library and beside the RAW (when writable), leaving the output folder with only the image.
    @discardableResult
    public func mergeExport(recipe snapshot: Recipe, for frame: Frame,
                            library: URL? = nil) throws -> Recipe {
        let library = library ?? RecipeStore.defaultLibrary
        try snapshot.validate()
        let verified = try digests.digest(of: frame.url)
        guard snapshot.raw.sha256 == verified.sha256 else { throw Failure.sourceIdentity }
        let latest = try read(frame, verified: verified, library: library, continuing: snapshot.editLineage)
        var current: Recipe
        if let latest, latest.raw.sha256 == verified.sha256 {
            if let a = latest.editLineage, let b = snapshot.editLineage, !Self.sameLine(a, b, of: frame) {
                throw Failure.conflict("export and current edits have different lineages")
            }
            current = (latest.editRevision ?? 0) >= (snapshot.editRevision ?? 0)
                ? mergingHistory(latest, snapshot) : mergingHistory(snapshot, latest)
        } else { current = snapshot }
        current.version = max(2, current.version, current.requiredVersion)
        current.editLineage = current.editLineage ?? UUID().uuidString.lowercased()
        current.editRevision = current.editRevision ?? 1
        current.editDate = current.editDate ?? Date()
        try validateLineage(current.editLineage!)
        current.editLineage = try ownLineage(current.editLineage!, of: frame, sha256: verified.sha256, library: library)
        // Verify every seed and patch the persisted record actually names before queuing or writing it.
        try requireRasters(current, frame: frame, library: library)
        try requirePatches(current, frame: frame, library: library)
        let id = key(frame, library)
        pending[id] = Pending(recipe: current, frame: frame, library: library, isReceipt: true)
        try persist(current, for: frame, library: library)
        pending.removeValue(forKey: id)
        return current
    }

    /// All calls for `library` before this actor barrier have either persisted or remain here for
    /// retry. Another library's writes are left as they are: they are another model's to flush, and a
    /// failure of theirs is not this one's. Returns the recipes it persisted, by their raws, so a
    /// failure they leave behind can be cleared.
    @discardableResult
    public func flush(library: URL? = nil) throws -> [URL: Recipe] {
        let library = (library ?? RecipeStore.defaultLibrary).canonicalPath
        // Chosen before any is persisted: the first may create a library reached through a symlink, which
        // then resolves to another path, and the rest would be left pending as another library's.
        let writes = pending.filter { $0.value.library.canonicalPath == library }
        var persisted: [URL: Recipe] = [:]
        for (id, write) in writes {
            let verified = try digests.digest(of: write.frame.url)
            guard verified.sha256 == write.recipe.raw.sha256 else {
                // A receipt of bytes the raw no longer has goes with them, as a save of the frame would replace it.
                if write.isReceipt { pending.removeValue(forKey: id); continue }
                throw Failure.sourceIdentity
            }
            try persist(write.recipe, for: write.frame, library: write.library)
            pending.removeValue(forKey: id)
            persisted[write.frame.url] = write.recipe
        }
        return persisted
    }

    /// An explicit Open Without Saving discards only retry state for these frames.
    /// Acknowledged journals, RAW sidecars, and backups remain intact.
    public func discardPending(for frames: [Frame], library: URL? = nil) {
        let library = library ?? RecipeStore.defaultLibrary
        for frame in frames { pending.removeValue(forKey: key(frame, library)) }
    }

    private func validateLineage(_ lineage: String) throws {
        guard !lineage.isEmpty, lineage.count <= 128,
              lineage.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw Failure.unsafeLineage
        }
    }

    private func archive(_ bytes: Data, preferred: URL, sha256: String, lineage: String, library: URL) throws {
        if FileManager.default.fileExists(atPath: preferred.path) { return }
        do { try bytes.write(to: preferred, options: .atomic) }
        catch {
            // A locked card cannot receive either the new sidecar or its migration backup.
            // Preserve its old bytes in the protected library before acknowledging the edit.
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let directory = library.appendingPathComponent("ManualDevelopment/v2/Backups", isDirectory: true)
                .appendingPathComponent(sha256, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(lineage)-\(digest)").appendingPathExtension("json")
            if !FileManager.default.fileExists(atPath: file.path) { try bytes.write(to: file, options: .atomic) }
        }
    }

    private func persist(_ recipe: Recipe, for frame: Frame, library: URL) throws {
        guard let sha = recipe.raw.sha256, let lineage = recipe.editLineage else { throw Failure.sourceIdentity }
        let data = try recipe.encoded()
        let journal = Self.journalURL(sha256: sha, lineage: lineage, library: library)
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: journal, options: .atomic)
        let binding = bindingURL(frame, library)
        try FileManager.default.createDirectory(at: binding.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Binding(sha256: sha, lineage: lineage)).write(to: binding, options: .atomic)
        let sidecar = RecipeStore.besideRaw(frame.url)
        if let old = try readFile(sidecar), old.version == 1 {
            let backup = sidecar.appendingPathExtension("v1-backup")
            try archive(Data(contentsOf: sidecar), preferred: backup, sha256: sha, lineage: lineage, library: library)
        } else if let old = try readFile(sidecar), old.manual != nil, old.raw.sha256 != sha {
            let backup = sidecar.appendingPathExtension("source-\(old.raw.sha256 ?? "unknown")-backup")
            try archive(Data(contentsOf: sidecar), preferred: backup, sha256: sha, lineage: lineage, library: library)
        }
        // A read-only card is a successful library save. Other publication failures are likewise
        // recoverable from the protected working record, which is always written first. The seeds
        // and the patches go before the sidecar that names them; if they cannot, the old sidecar
        // stays, and the next load publishes them all from the library's record.
        guard publishPacks(recipe, for: frame, library: library),
              !MaskWriteFaults.shared.isSet(.sidecarBesideRaw, library: library) else { return }
        guard (try? data.write(to: sidecar, options: .atomic)) != nil else { return }
        // A pack beside the raw whose sidecar no longer names a seed has nothing left to carry.
        let pack = RecipeStore.masksBesideRaw(frame.url)
        if Self.rasterRefs(of: recipe).isEmpty, FileManager.default.fileExists(atPath: pack.path) {
            try? FileManager.default.removeItem(at: pack)
        }
        // Nor has the patches' pack, once the sidecar names no removal.
        let patches = RecipeStore.patchesBesideRaw(frame.url)
        if Self.patchRefs(of: recipe).isEmpty, FileManager.default.fileExists(atPath: patches.path) {
            try? FileManager.default.removeItem(at: patches)
        }
    }
}
