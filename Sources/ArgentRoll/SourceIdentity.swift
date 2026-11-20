import ArgentCore
import CryptoKit
import Darwin
import Foundation

/// A raw file's version as the file system records it, read without opening the file: which file
/// it is (its device and inode), its size, and when its contents and its status last changed, to
/// the nanosecond. A raw written over in place, replaced or touched has another stamp; the same
/// stamp is the same file, unwritten, as far as the file system can say. What is kept in memory of a
/// raw for this session (its decodes, renders and measurement) is kept by its stamp.
///
/// On a network share the status time is the contents' time (`ChangeTimes`): there a file mapped into
/// memory, as Apple's decoder and Quick Look map one, can have its status time moved without a byte of
/// it changing, so a raw changed only in status, or written over with its time put back, is not seen.
public struct SourceStamp: Sendable, Hashable, Codable {
    public var device: Int32
    public var inode: UInt64
    public var size: Int64
    /// The last change to the file's contents and to its status, in nanoseconds since 1970.
    public var modified: Int64
    public var changed: Int64

    init(_ info: stat, keepsChangeTime: Bool) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        changed = keepsChangeTime ? Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec) : modified
    }

    /// The stamp of the regular file at `url` now; `nil` when there is none.
    public static func of(_ url: URL) -> SourceStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return SourceStamp(info, keepsChangeTime: ChangeTimes.shared.kept(on: info.st_dev) { statfs(url.path, &$0) })
    }

    static func of(descriptor: Int32) -> SourceStamp? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return SourceStamp(info, keepsChangeTime: ChangeTimes.shared.kept(on: info.st_dev) { fstatfs(descriptor, &$0) })
    }

    /// The stamp as text, for cache keys.
    public var key: String { "\(device):\(inode):\(size):\(modified):\(changed)" }

    /// Whether `other`, a stamp of the file at the same path, is this version of it, the volume
    /// perhaps mounted again between them: a network share's device number is given again at each
    /// mount, and at one path the inode, size and times say the rest.
    public func isSameVersion(atSamePathAs other: SourceStamp) -> Bool {
        isSameFile(atSamePathAs: other) && changed == other.changed
    }

    /// Whether `other`, a stamp of the file at the same path, is this file with these contents,
    /// whatever of its status has changed since: its permissions, its extended attributes, a tag.
    public func isSameFile(atSamePathAs other: SourceStamp) -> Bool {
        inode == other.inode && size == other.size && modified == other.modified
    }
}

/// Which volumes' status times say a file changed, by device: a local volume's do; a network share's
/// need not. On an SMB share (Samba on ZimaOS, measured 2026-10-09) mapping a file into memory moves
/// its status time, even with no page of it read, while reading it moves only its access time; so a
/// develop's own decode, through Apple's decoder, made every raw there one that changed while it was
/// developed (docs/M2-shell.md section 6). Read once per device, since `statfs` costs 59 us on that
/// share against 5 us for `stat`; a device is a new number at each mount.
final class ChangeTimes: @unchecked Sendable {
    static let shared = ChangeTimes()
    private let lock = NSLock()
    private var local: [Int32: Bool] = [:]

    /// Whether files on `device` keep their status time, from `read` filling in its volume's `statfs`
    /// the first time; a volume that cannot be read is taken as keeping it, this time only.
    func kept(on device: Int32, read: (inout statfs) -> Int32) -> Bool {
        if let known = lock.withLock({ local[device] }) { return known }
        var volume = statfs()
        guard read(&volume) == 0 else { return true }
        let isLocal = volume.f_flags & UInt32(MNT_LOCAL) != 0
        lock.withLock { local[device] = isLocal }
        return isLocal
    }
}

/// A frame's auto-development measurement and the version of its raw it was made from, so a
/// measurement is never applied to a raw since written over or replaced.
public struct FrameMeasurement: Sendable, Equatable {
    public var analysis: ExposureAnalysis
    public var source: SourceStamp

    public init(analysis: ExposureAnalysis, source: SourceStamp) {
        self.analysis = analysis
        self.source = source
    }
}

/// The SHA-256 of raw files read whole: what says a raw is, byte for byte, the one a recipe, a
/// measurement or a cached decode was made from. A raw is read whole once per version: its digest is
/// kept by its stamp and the volume it is on, and given again while the file's stamp is the same.
/// A digest is kept only when the read is whole and the file did not change during it or in the
/// two seconds before it, so a file still being written, or on a volume that keeps times to the
/// second, is read again rather than trusted. A file whose contents change while its size, inode and
/// both times stay the same, which only a deliberate rewrite of the times can do, is not seen;
/// nothing short of reading it whole again would see it.
///
/// Kept in memory, at most `limit` digests, least recently used going first, and once `persist(to:)`
/// is called, in a file too, so an unchanged roll opened again after a relaunch is not read whole.
public final class SourceDigests: @unchecked Sendable {
    /// The app's: in memory until the app calls `persist(to:)`.
    public static let shared = SourceDigests()

    public enum Failure: Error, Equatable, CustomStringConvertible, LocalizedError {
        case unreadable(String)
        /// Not the file's size in bytes: it shrank or grew, or the volume went, while it was read.
        case incomplete(expected: Int64, read: Int64)
        case changedWhileRead
        case stopped

        public var description: String {
            switch self {
            case .unreadable(let reason): return "the raw could not be read: \(reason)"
            case .incomplete(let expected, let read): return "\(read) bytes of the raw read where it had \(expected)"
            case .changedWhileRead: return "the raw changed while it was read"
            case .stopped: return "stopped"
            }
        }

        /// The same, for messages that take an error's `localizedDescription`.
        public var errorDescription: String? { description }
    }

    /// A file's SHA-256, and the stamp the file had through the whole read.
    public struct Verified: Sendable, Equatable {
        public var sha256: String
        public var source: SourceStamp
    }

    private struct Entry: Codable {
        var sha256: String
        var used: Double
    }

    private struct Saved: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    public let limit: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var file: URL?
    private var isDirty = false
    private var isSaveDue = false
    private var reads = 0
    private let saveQueue = DispatchQueue(label: "Argent source digests: disk", qos: .utility)
    /// How recent a change to a file, in nanoseconds before its read, keeps the read from being kept.
    let settleNanoseconds: Int64

    /// At most `limit` digests; a file changed less than `settle` seconds before it is read is
    /// read again next time.
    public init(limit: Int = 20_000, settle: Double = 2) {
        self.limit = max(1, limit)
        settleNanoseconds = Int64(settle * 1e9)
    }

    /// Caches/Argent/Source Digests.json, inside the app's container when sandboxed; a test process may
    /// not use it (`Caches`).
    public static var defaultFile: URL {
        Caches.folder.appendingPathComponent("Source Digests.json")
    }

    /// Reads the digests kept in `file`, and keeps them there from now on.
    public func persist(to file: URL) {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        lock.withLock {
            self.file = file
            if let saved, saved.version == 1 { entries.merge(saved.entries) { mine, _ in mine } }
        }
    }

    /// Raws read whole so far, for tests.
    public var readCount: Int { lock.withLock { reads } }

    /// The file's SHA-256 if it is known for the file's version now, without reading the file.
    public func known(_ url: URL) -> Verified? {
        guard let source = SourceStamp.of(url) else { return nil }
        let key = Self.key(source, url)
        return lock.withLock {
            guard var entry = entries[key] else { return nil }
            entry.used = Date().timeIntervalSince1970
            entries[key] = entry
            return Verified(sha256: entry.sha256, source: source)
        }
    }

    /// The file's SHA-256: kept, while the file's version is the one it was read at, or read whole
    /// now, stopping between megabytes once `stopped` says so. Throws `Failure`.
    public func digest(of url: URL, stopped: () -> Bool = { false }) throws -> Verified {
        if let known = known(url) { return known }
        let started = Int64(Date().timeIntervalSince1970 * 1e9)
        let verified = try Self.read(url, stopped: stopped)
        lock.withLock { reads += 1 }
        // Changed just before the read: it may be written still, or its times may be too coarse to show
        // a write after the read.
        let settled = started - settleNanoseconds
        if verified.source.modified < settled, verified.source.changed < settled {
            keep(verified.sha256, under: Self.key(verified.source, url))
        }
        return verified
    }

    /// The file's SHA-256 read whole, not kept: throws when the file cannot be read to its end, or
    /// its stamp changed while it was read, or it was replaced under its name.
    public static func read(_ url: URL, stopped: () -> Bool = { false }) throws -> Verified {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }
        guard let before = SourceStamp.of(descriptor: handle.fileDescriptor) else { throw Failure.unreadable("not a file") }
        var hash = SHA256()
        var count: Int64 = 0
        do {
            while true {
                if stopped() { throw Failure.stopped }
                // FileHandle hands each chunk back autoreleased, and a worker thread drains its pool
                // only when the whole check ends: 10 raws held about 480 MB that way, which raised the
                // develop's memory floor until every frame ran alone (measured, 2026-10-18).
                let read = try autoreleasepool { () throws -> Int in
                    guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return 0 }
                    hash.update(data: chunk)
                    return chunk.count
                }
                if read == 0 { break }
                count += Int64(read)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard count == before.size else { throw Failure.incomplete(expected: before.size, read: count) }
        guard SourceStamp.of(descriptor: handle.fileDescriptor) == before, SourceStamp.of(url) == before else {
            throw Failure.changedWhileRead
        }
        return Verified(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), source: before)
    }

    /// Writes what is kept to the file now, if anything changed, for tests and for quitting.
    public func flush() {
        saveQueue.sync { save() }
    }

    /// Forgets every digest, in memory and in the file.
    public func removeAll() {
        lock.withLock {
            entries.removeAll()
            isDirty = true
        }
        flush()
    }

    /// The key a digest is kept under: the file's stamp, with the volume named by `volumeName(of:)`
    /// where it can be, since a volume's device number is given again at each mount.
    private static func key(_ source: SourceStamp, _ url: URL) -> String {
        "\(volumeName(of: url) ?? "device-\(source.device)")|\(source.inode)|\(source.size)|\(source.modified)|\(source.changed)"
    }

    /// What names `url`'s volume from one mount to the next: its UUID, or for a network share, which
    /// has none, the address it is mounted from without the user, as smb://ZimaOS._smb._tcp.local/Shared.
    /// Mounted again, a share's files keep their numbers, sizes and times (measured on an SMB share,
    /// docs/M2-shell.md section 6), so an unchanged roll on it is not read whole again. `nil` for a
    /// volume with neither.
    static func volumeName(of url: URL) -> String? {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeURLForRemountingKey]
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys)
        if let uuid = values?.volumeUUIDString { return uuid }
        guard let remote = values?.volumeURLForRemounting,
              var address = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return nil }
        address.user = nil
        address.password = nil
        return address.string
    }

    private func keep(_ sha256: String, under key: String) {
        let due = lock.withLock { () -> Bool in
            entries[key] = Entry(sha256: sha256, used: Date().timeIntervalSince1970)
            if entries.count > limit {
                // The least recently used tenth goes, so a long roll does not trim at every read.
                let drop = max(1, entries.count - limit + limit / 10)
                for old in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(drop) { entries[old.key] = nil }
            }
            isDirty = true
            guard file != nil, !isSaveDue else { return false }
            isSaveDue = true
            return true
        }
        // Many reads at once, as a roll opening, make one write.
        if due { saveQueue.asyncAfter(deadline: .now() + 2) { [self] in save() } }
    }

    /// Call it on `saveQueue`.
    private func save() {
        let snapshot = lock.withLock { () -> (URL, [String: Entry])? in
            isSaveDue = false
            guard isDirty, let file else { return nil }
            isDirty = false
            return (file, entries)
        }
        guard let (file, entries) = snapshot,
              let data = try? JSONEncoder().encode(Saved(version: 1, entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
