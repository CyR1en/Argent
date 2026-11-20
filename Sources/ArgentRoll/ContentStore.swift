import Darwin
import Foundation

/// The file mechanics of a store whose files are named by the hash of what they hold: the masks' seeds (`MaskRasterStore`) and the
/// removals' patches (`PatchStore`). What a file holds, how it is checked and what its failures are called stay each store's own;
/// what is here is what the two would otherwise each write: the write that a crash cannot leave half done, the pack that travels
/// beside a raw, and the sweep (docs/remove-plan.md, section 4.7).
///
/// A file is `<folder>/<first two hex digits>/<64 hex digits>.<extension>`, so no folder holds thousands. A pack is one file: the
/// kind's magic line, a little-endian count, then for each entry its 32-byte id and the offset and length of its file (8 bytes
/// each), then the files as the library holds them.
struct ContentStore: Sendable {
    /// What tells one store's files from another's.
    struct Kind: Sendable {
        /// Below the library. A new layout is a new folder beside it, never a change to this one.
        let folderName: String
        let fileExtension: String
        /// A pack's first line.
        let packMagic: Data
    }

    enum Failure: Error, Equatable {
        case unwritable(String)
        /// A file with the pack's extension that is not a pack this build reads, by its name.
        case notAPack(String)
    }

    /// More entries than any record can name, so a damaged count is refused.
    static let packMaximumEntries = 1024
    static let packEntryBytes = 48

    /// One file at a time between a sweep, which deletes, and a store or an import, which keep a file they find by refreshing its
    /// date: a file found present is then never deleted under them. Every library's and both stores', since one lock costs nothing
    /// here.
    static let files = NSLock()

    let library: URL
    let folder: URL
    let kind: Kind

    init(library: URL, kind: Kind) {
        self.library = library
        self.kind = kind
        folder = library.appendingPathComponent(kind.folderName, isDirectory: true)
    }

    func url(for hex: String) -> URL {
        folder.appendingPathComponent(String(hex.prefix(2)), isDirectory: true).appendingPathComponent(hex).appendingPathExtension(kind.fileExtension)
    }

    /// Whether the library has a non-empty file for `hex`. It does not read it.
    func contains(_ hex: String) -> Bool {
        ((try? url(for: hex).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }

    /// Refreshes the date of each file `hexes` names that the library has, so the sweep counts it young.
    func keepAlive(_ hexes: [String]) {
        Self.files.withLock {
            for hex in hexes where contains(hex) { touch(hex) }
        }
    }

    /// Whether the library already holds a sound file for `hex`, as `isSound` judges it; if so its date is refreshed, under the
    /// lock the sweep takes.
    func keepIfSound(_ hex: String, isSound: () -> Bool) -> Bool {
        Self.files.withLock {
            guard contains(hex), isSound() else { return false }
            touch(hex)
            return true
        }
    }

    private func touch(_ hex: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(for: hex).path)
    }

    // MARK: packs

    /// Writes the files `hexes` names, each once, into one pack at `url`, flushed and renamed into place. `check` is called for
    /// each before it is read, and throws for a file that is not sound. Leaves a pack that already holds exactly these files as it
    /// is, so a slider's save does not rewrite megabytes.
    func writePack(_ hexes: [String], to url: URL, fault: MaskWriteFault?, check: (String) throws -> Void) throws {
        if packHolds(hexes, at: url) { return }
        var lengths: [Int] = []
        for hex in hexes {
            try check(hex)
            lengths.append(try self.url(for: hex).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        var out = kind.packMagic
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        u32(UInt32(hexes.count))
        var offset = UInt64(kind.packMagic.count + 4 + hexes.count * Self.packEntryBytes)
        for (hex, length) in zip(hexes, lengths) {
            out.append(Self.bytes(of: hex))
            u64(offset); u64(UInt64(length))
            offset += UInt64(length)
        }
        try Self.durableWrite(to: url, library: library, fault: fault) { write in
            try write(out)
            for (hex, length) in zip(hexes, lengths) {
                let handle = try FileHandle(forReadingFrom: self.url(for: hex))
                defer { try? handle.close() }
                var remaining = length
                while remaining > 0 {
                    remaining -= try autoreleasepool {
                        let data = try handle.read(upToCount: min(remaining, 1024 * 1024)) ?? Data()
                        guard !data.isEmpty else { throw Failure.unwritable("file changed while packing") }
                        try write(data)
                        return data.count
                    }
                }
                guard try handle.read(upToCount: 1)?.isEmpty != false else { throw Failure.unwritable("file changed while packing") }
            }
        }
    }

    /// The ids a pack at `url` lists and each one's length, read from its header alone; `nil` when there is no such file, and
    /// `notAPack` when there is one this build cannot read.
    static func packEntries(at url: URL, magic: Data) throws -> [(hex: String, length: Int)]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: magic.count + 4) ?? Data()
        guard head.count == magic.count + 4, head.prefix(magic.count) == magic else { throw Failure.notAPack(url.lastPathComponent) }
        let count = Int(integer(head, at: magic.count, width: 4))
        guard count <= packMaximumEntries else { throw Failure.notAPack(url.lastPathComponent) }
        let table = try handle.read(upToCount: count * packEntryBytes) ?? Data()
        guard table.count == count * packEntryBytes else { throw Failure.notAPack(url.lastPathComponent) }
        let start = magic.count + 4 + count * packEntryBytes
        var entries: [(String, Int)] = [], end = start
        for i in 0..<count {
            let at = i * packEntryBytes
            let hex = table[table.startIndex + at..<table.startIndex + at + 32].map { String(format: "%02x", $0) }.joined()
            let offset = integer(table, at: at + 32, width: 8), length = integer(table, at: at + 40, width: 8)
            guard offset == UInt64(end), length <= UInt64(size), offset + length <= UInt64(size) else { throw Failure.notAPack(url.lastPathComponent) }
            end = Int(offset + length)
            entries.append((hex, Int(length)))
        }
        guard end == size else { throw Failure.notAPack(url.lastPathComponent) }
        return entries
    }

    /// Whether the pack at `url` holds exactly `hexes`' files, with the same bytes as the library's files.
    private func packHolds(_ hexes: [String], at url: URL) -> Bool {
        guard let entries = (try? Self.packEntries(at: url, magic: kind.packMagic)) ?? nil, entries.count == hexes.count,
              Set(entries.map(\.hex)) == Set(hexes),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        var offset = kind.packMagic.count + 4 + entries.count * Self.packEntryBytes
        return entries.allSatisfy { entry in
            defer { offset += entry.length }
            guard offset + entry.length <= data.count,
                  let blob = try? Data(contentsOf: self.url(for: entry.hex), options: .mappedIfSafe),
                  blob.count == entry.length else { return false }
            return data.subdata(in: offset..<offset + entry.length) == blob
        }
    }

    /// Calls `take` with the id and the bytes of each entry of the pack at `url`, `wanted` ones only when given, in the pack's
    /// order. An entry past the file's end is left out: the file may have changed since its header was read. `false` when there is
    /// no such file.
    @discardableResult
    func readPack(at url: URL, wanted: Set<String>?, take: (String, Data) throws -> Void) throws -> Bool {
        guard let entries = try Self.packEntries(at: url, magic: kind.packMagic) else { return false }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var offset = kind.packMagic.count + 4 + entries.count * Self.packEntryBytes
        for (hex, length) in entries {
            defer { offset += length }
            guard wanted?.contains(hex) ?? true, offset + length <= data.count else { continue }
            try take(hex, data.subdata(in: data.startIndex + offset..<data.startIndex + offset + length))
        }
        return true
    }

    // MARK: garbage

    /// Removes this store's files that `live` does not name once they are `orphanAge` old, and temporary files once they are
    /// `temporaryAge` old, and returns their names. Files that are not this store's are left alone.
    func collectGarbage(keeping live: Set<String>, orphanAge: TimeInterval, temporaryAge: TimeInterval, now: Date) -> [String] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
        else { return [] }
        var removed: [String] = []
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let name = file.lastPathComponent
            let isTemporary = name.hasPrefix(".tmp-")
            let hex = file.pathExtension == kind.fileExtension ? Self.contentName(file.deletingPathExtension().lastPathComponent) : nil
            guard isTemporary || hex != nil else { continue }
            if let hex, live.contains(hex) { continue }
            Self.files.withLock {
                // Read again under the lock: a store or an import may have just found it and refreshed it.
                guard let written = (try? URL(fileURLWithPath: file.path).resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { return }
                let age = now.timeIntervalSince(written)
                guard age > (isTemporary ? temporaryAge : orphanAge) else { return }
                if (try? FileManager.default.removeItem(at: file)) != nil { removed.append(name) }
            }
        }
        return removed
    }

    /// `name` if it is a content name, 64 lowercase hex digits.
    private static func contentName(_ name: String) -> String? {
        name.count == 64 && name.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) ? name : nil
    }

    // MARK: files

    /// Written beside `url` under a hidden temporary name, flushed to the disk, then renamed over it: a crash leaves the whole file or
    /// a `.tmp-*`, never a part. `F_FULLFSYNC` asks the drive to empty its own cache too, which plain `fsync` does not on macOS; a
    /// volume that does not take it (a card's FAT, say) gets `fsync`. The folder is flushed after the rename where it can be.
    static func durableWrite(_ data: Data, to url: URL, library: URL, fault: MaskWriteFault?) throws {
        try durableWrite(to: url, library: library, fault: fault) { write in try write(data) }
    }

    private static func durableWrite(to url: URL, library: URL, fault: MaskWriteFault?, body: ((Data) throws -> Void) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw Failure.unwritable(error.localizedDescription) }
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw Failure.unwritable(String(cString: strerror(errno))) }
        do {
            try body { data in try write(data, to: descriptor) }
        } catch {
            close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        var failed: String?
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 { failed = String(cString: strerror(errno)) }
        close(descriptor)
        if let failed {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.unwritable(failed)
        }
        // A test's crash here leaves the temporary file, as a crash would.
        if let fault { try MaskWriteFaults.shared.check(fault, library: library) }
        guard rename(temporary.path, url.path) == 0 else {
            let why = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.unwritable(why)
        }
        let folder = open(directory.path, O_RDONLY)
        if folder >= 0 {
            if fcntl(folder, F_FULLFSYNC) != 0 { _ = fsync(folder) }
            close(folder)
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(descriptor, buffer.baseAddress! + written, buffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.unwritable(String(cString: strerror(errno)))
                }
                guard n > 0 else { throw Failure.unwritable("write made no progress") }
                written += n
            }
        }
    }

    private static func bytes(of hex: String) -> Data {
        let digits = Array(hex.utf8)
        func value(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
        return Data(stride(from: 0, to: 64, by: 2).map { value(digits[$0]) << 4 | value(digits[$0 + 1]) })
    }

    private static func integer(_ data: Data, at offset: Int, width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | UInt64(data[data.startIndex + offset + $1]) << (8 * UInt64($1)) }
    }
}
