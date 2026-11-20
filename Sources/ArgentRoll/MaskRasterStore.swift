import ArgentCore
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Smart masks' seeds: the pinned rasters a smart selection names (`SmartSelection.raster`), kept in the recipe library beside the
/// journal, in `Masks/v1`. A seed is a measurement stored with the edit, so a saved edit never runs a model again (masking-plan
/// section 3): it lives in Application Support's library, never in Caches, which the system may purge.
///
/// One 8-bit gray PNG a seed, at the model's own size, named by `RasterID`, the hash of its pixels and not of its file, so a seed is
/// kept once however often it is saved, undone, redone or shared by twin raws, and an OS that encodes a PNG differently makes no second
/// copy. A file is written beside its name, flushed to the disk, then renamed over it, so a crash leaves the whole file or a `.tmp-*`
/// that the sweep removes. `store` returns only once that is done, and only then does the model put the seed's `RasterRef` in the edit:
/// the journal record that names a seed is always written after the seed, so no record names nothing (R6 section 4.3).
///
/// Nothing deletes a seed but `collectGarbage`, and it keeps every seed a record in the library names, current or held, every seed the
/// caller says an undo step names, and every file younger than a week. `load` recomputes a file's identity from its pixels, so a damaged
/// file is refused, never rendered as something else.
///
/// A store is a value: its folder comes from the call's library, so a test's library has its own seeds and no test reaches
/// Application Support's (docs/ci-regression.md, "Test libraries").
public struct MaskRasterStore: Sendable {
    /// Below the library, beside `ManualDevelopment`. A new layout is `v2` beside it, never a change to this one.
    public static let folderName = "Masks/v1"
    /// A pack's extension, beside a sidecar's `argent`.
    public static let packExtension = "argentmasks"
    /// How long a seed no record names is kept: a crash between `store` and the save that would have named it, an undo past a mask's
    /// creation, or a session's undo history, all of which a week outlasts (R6 section 4.3).
    public static let orphanAge: TimeInterval = 7 * 86_400
    /// How long a temporary file is kept: one a crash left mid-write, never one being written now.
    public static let temporaryAge: TimeInterval = 86_400

    public let library: URL
    public let folder: URL

    public init(library: URL) {
        self.library = library
        folder = library.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    public enum Failure: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
        /// No file of that name in the library, or an empty one.
        case missing(RasterID)
        /// A file that does not decode to the pixels its name is the hash of.
        case damaged(RasterID)
        case unwritable(String)
        /// A `.argentmasks` file that is not a pack this build reads.
        case notAPack(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let id): return "A mask’s selection (\(id.hex.prefix(12))) is missing from the library"
            case .damaged(let id): return "A mask’s selection (\(id.hex.prefix(12))) is damaged"
            case .unwritable(let why): return "A mask’s selection could not be saved: \(why)"
            case .notAPack(let name): return "\(name) is not a mask pack this build reads"
            }
        }
        public var description: String { errorDescription ?? "A mask’s selection cannot be used" }
    }

    /// The file mechanics this store shares with the patches' (`ContentStore`): the durable write, the pack and the sweep, and the one
    /// lock both take between a sweep, which deletes, and `store` and the imports, which keep a file they find by refreshing its date.
    private static let kind = ContentStore.Kind(folderName: folderName, fileExtension: "png", packMagic: packMagic)
    private var content: ContentStore { ContentStore(library: library, kind: Self.kind) }

    /// `ContentStore`'s failures in this store's words.
    private static func inOwnWords<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as ContentStore.Failure {
            switch failure {
            case .unwritable(let why): throw Failure.unwritable(why)
            case .notAPack(let name): throw Failure.notAPack(name)
            }
        }
    }

    /// `Masks/v1/ab/abcdef….png`: the first two hex digits as a folder, so no folder holds thousands of files.
    public func url(for id: RasterID) -> URL {
        folder.appendingPathComponent(String(id.hex.prefix(2)), isDirectory: true).appendingPathComponent(id.hex).appendingPathExtension("png")
    }

    /// Whether the library has a non-empty file for `id`. It does not decode it: `load` does.
    public func contains(_ id: RasterID) -> Bool {
        ((try? url(for: id).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }

    /// The seeds in `refs` the library cannot load and validate, each once, in order.
    public func missing(_ refs: [RasterRef]) -> [RasterRef] {
        var seen = Set<RasterID>()
        return refs.filter { seen.insert($0.id).inserted && (try? load($0)) == nil }
    }

    // MARK: store and load

    /// Keeps `raster`, once, and returns its ref only after its file is on the disk and flushed, so a record written next never names
    /// nothing. A file already there is kept if it holds these pixels, and replaced if it is damaged.
    @discardableResult
    public func store(_ raster: MaskRaster) throws -> RasterRef {
        let ref = raster.ref
        if keepIfSound(ref) { return ref }
        let png: Data
        do { png = try Self.png(raster) } catch { throw Failure.unwritable("its picture could not be encoded") }
        try Self.durableWrite(png, to: url(for: ref.id), library: library, fault: .rasterBeforeRename)
        return ref
    }

    /// The seed `ref` names, checked: decoded, at `ref`'s size, and its identity recomputed from its pixels.
    public func load(_ ref: RasterRef) throws -> MaskRaster {
        let file = url(for: ref.id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.missing(ref.id) }
        guard let data = try? Data(contentsOf: file) else { throw Failure.damaged(ref.id) }
        guard !data.isEmpty else { throw Failure.missing(ref.id) }
        guard let raster = Self.decode(data), raster.width == ref.width, raster.height == ref.height, raster.identity == ref.id else {
            throw Failure.damaged(ref.id)
        }
        return raster
    }

    /// Every seed in `refs`, loaded and checked, for one render to hold: what a develop holds of a frame's masks (`MaskSeeds.needs`).
    public func seeds(_ refs: [RasterRef]) throws -> MaskSeeds {
        var seen = Set<RasterID>(), loaded: [MaskRaster] = []
        for ref in refs where seen.insert(ref.id).inserted { loaded.append(try load(ref)) }
        return MaskSeeds(loaded)
    }

    /// Refreshes the date of each file `ids` names that the library has, so the sweep counts it young: what a record outside the
    /// journal (a sidecar from another Mac, read but not yet edited here) names stays while its roll is in use.
    public func keepAlive(_ ids: [RasterID]) { content.keepAlive(ids.map(\.hex)) }

    /// Whether the library already holds `ref`'s pixels; if so its date is refreshed, under the lock the sweep takes.
    private func keepIfSound(_ ref: RasterRef) -> Bool {
        content.keepIfSound(ref.id.hex) { (try? load(ref)) != nil }
    }

    // MARK: packs: the seeds that travel beside a raw

    /// A pack is one file: this line, a little-endian count, then for each seed its 32-byte id, the offset and length of its PNG
    /// (8 bytes each), then the PNGs. It holds the library's files as they are, so a pack is as large as the seeds.
    static let packMagic = Data("ARGENT-MASKS-1\n".utf8)
    /// More seeds than any record can name (16 masks of 16 components, current and held), so a damaged count is refused.
    static let packMaximumEntries = ContentStore.packMaximumEntries
    static let packEntryBytes = ContentStore.packEntryBytes

    /// Writes the seeds `refs` names into one pack at `url`, each checked as `load` checks it, flushed and renamed into place: the pack
    /// beside a raw before the sidecar that names its seeds. Leaves a pack that already holds
    /// exactly these files as it is, so a slider's save does not rewrite megabytes.
    public func writePack(_ refs: [RasterRef], to url: URL) throws { try writePack(refs, to: url, fault: nil) }

    func writePack(_ refs: [RasterRef], to url: URL, fault: MaskWriteFault?) throws {
        var unique: [RasterRef] = [], seen = Set<RasterID>()
        for ref in refs where seen.insert(ref.id).inserted { unique.append(ref) }
        let byName = Dictionary(uniqueKeysWithValues: unique.map { ($0.id.hex, $0) })
        try Self.inOwnWords {
            try content.writePack(unique.map(\.id.hex), to: url, fault: fault) { hex in _ = try load(byName[hex]!) }
        }
    }

    /// The ids a pack at `url` lists and each one's length, read from its header alone; `nil` when there is no such file, and
    /// `notAPack` when there is one this build cannot read.
    public static func packEntries(at url: URL) throws -> [(id: RasterID, length: Int)]? {
        try inOwnWords { try ContentStore.packEntries(at: url, magic: packMagic) }?.map { (RasterID(hex: $0.hex)!, $0.length) }
    }

    /// What `importPack` did.
    public struct PackImport: Sendable, Equatable {
        /// Taken into the library, each checked.
        public var added: [RasterID] = []
        /// Entries that did not decode to the pixels their id names: left out, never kept.
        public var damaged: [RasterID] = []
    }

    /// Takes into the library the seeds of the pack at `url` that it lacks, `wanted` ones only when given, each checked as `load`
    /// checks it: a raw and its pack that reach another Mac, or a library lost, give their masks back. A seed the library has is
    /// left as it is, its date refreshed; a damaged entry is left out.
    @discardableResult
    public func importPack(from url: URL, wanted: Set<RasterID>? = nil) throws -> PackImport {
        var result = PackImport()
        _ = try Self.inOwnWords {
            try content.readPack(at: url, wanted: wanted.map { Set($0.map(\.hex)) }) { hex, blob in
                let id = RasterID(hex: hex)!
                guard let raster = Self.decode(blob), raster.identity == id else { result.damaged.append(id); return }
                if keepIfSound(raster.ref) { return }
                try Self.durableWrite(blob, to: self.url(for: id), library: library, fault: .rasterBeforeRename)
                result.added.append(id)
            }
        }
        return result
    }

    // MARK: garbage

    /// What a sweep did: the files it removed, or why it removed none.
    public struct Sweep: Sendable, Equatable {
        public var removed: [String] = []
        /// Set when a record could not be read, so the seeds it may name are unknown and nothing was removed.
        public var skipped: String?
    }

    /// Removes the seeds no record in `library` names and nothing in `keeping` names, once they are `orphanAge` old, and temporary
    /// files once they are `temporaryAge` old. `keeping` is what the caller holds beyond the library's records: the seeds any undo
    /// step names. The app runs it at launch, off the main queue, when no undo history exists yet; a record it cannot read (a newer
    /// build's, say) may name any seed, so then it removes nothing.
    public static func sweep(library: URL, keeping: Set<RasterID> = [], now: Date = Date()) -> Sweep {
        let named: Set<RasterID>
        do { named = try namedRasters(in: library) } catch {
            return Sweep(skipped: "a recipe in the library could not be read: \(error.localizedDescription)")
        }
        return Sweep(removed: MaskRasterStore(library: library).collectGarbage(keeping: named.union(keeping), now: now))
    }

    /// Every seed a record in `library` names, in its current edit or its held one: the working records and their backups under
    /// `ManualDevelopment/v2`, and the copies a locked card's recipes left at the library's top. Receipts keep a digest of their masks
    /// and name no seed (masking-plan section 7). Throws when any record cannot be read.
    public static func namedRasters(in library: URL) throws -> Set<RasterID> {
        try RecipeWriter.namedAssetIDs(in: library) { recipe in
            RecipeWriter.rasterRefs(of: recipe).map(\.id)
        }
    }

    /// Removes what `sweep` would, given the seeds to keep. Files that are not this store's are left alone.
    public func collectGarbage(keeping live: Set<RasterID>, now: Date = Date()) -> [String] {
        content.collectGarbage(keeping: Set(live.map(\.hex)), orphanAge: Self.orphanAge, temporaryAge: Self.temporaryAge, now: now)
    }

    // MARK: files

    /// Written beside `url` under a hidden temporary name, flushed to the disk, then renamed over it (`ContentStore.durableWrite`):
    /// a crash leaves the whole file or a `.tmp-*`, never a part.
    static func durableWrite(_ data: Data, to url: URL, library: URL, fault: MaskWriteFault?) throws {
        try inOwnWords { try ContentStore.durableWrite(data, to: url, library: library, fault: fault) }
    }

    /// An 8-bit gray PNG of the plane, row 0 the picture's top.
    static func png(_ raster: MaskRaster) throws -> Data {
        guard let provider = CGDataProvider(data: Data(raster.plane) as CFData),
              let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: raster.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.unwritable("its picture could not be made")
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.unwritable("no PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable("the PNG could not be written") }
        return out as Data
    }

    /// The plane of a one-picture 8-bit gray PNG, its bytes as stored: read from the decoded image's own buffer and never drawn, so no
    /// colour conversion can touch a value. Anything else is `nil`, and so damaged to `load`.
    static func decode(_ data: Data) -> MaskRaster? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        let width = image.width, height = image.height, rowBytes = image.bytesPerRow
        // Sides first, before any pixel is decoded, so a pack's entry cannot ask for a huge picture.
        guard RasterRef.sideRange.contains(width), RasterRef.sideRange.contains(height), image.bitsPerComponent == 8,
              image.bitsPerPixel == 8, image.colorSpace?.model == .monochrome, image.alphaInfo == .none, rowBytes >= width,
              let pixels = image.dataProvider?.data, CFDataGetLength(pixels) >= rowBytes * (height - 1) + width,
              let base = CFDataGetBytePtr(pixels) else { return nil }
        var plane = [UInt8](repeating: 0, count: width * height)
        plane.withUnsafeMutableBytes { out in
            for row in 0..<height { memcpy(out.baseAddress! + row * width, base + row * rowBytes, width) }
        }
        return try? MaskRaster(width: width, height: height, plane: plane)
    }

}

/// Where a test stands in for a crash or a failed write, in one library at a time, at each point of R6 section 4.3. The app sets none,
/// so each check is a lookup in an empty table.
enum MaskWriteFault: Hashable, Sendable {
    /// A seed written to its temporary file and flushed, not yet renamed: a crash leaves the `.tmp-*`.
    case rasterBeforeRename
    /// The journal and binding written, the pack beside the raw not.
    case packBesideRaw
    /// The pack beside the raw written, the sidecar not.
    case sidecarBesideRaw
}

final class MaskWriteFaults: @unchecked Sendable {
    static let shared = MaskWriteFaults()
    struct Crash: Error, LocalizedError {
        let fault: MaskWriteFault
        var errorDescription: String? { "a test stopped the write at \(fault)" }
    }
    private let lock = NSLock()
    private var faults: [String: Set<MaskWriteFault>] = [:]

    private static func key(_ library: URL) -> String { library.standardizedFileURL.path }

    func inject(_ fault: MaskWriteFault, library: URL) { _ = lock.withLock { faults[Self.key(library), default: []].insert(fault) } }
    func clear(library: URL) { lock.withLock { faults[Self.key(library)] = nil } }
    func isSet(_ fault: MaskWriteFault, library: URL) -> Bool {
        lock.withLock { faults.isEmpty ? false : faults[Self.key(library)]?.contains(fault) == true }
    }
    func check(_ fault: MaskWriteFault, library: URL) throws {
        if isSet(fault, library: library) { throw Crash(fault: fault) }
    }
}
