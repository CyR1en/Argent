import CryptoKit
import Darwin
import Foundation

/// Copies raws off a card into a folder on another volume, each checked by SHA-256, and never writes the card.
///
/// A raw is streamed to a hidden partial file beside its final name while it is hashed, synced, hashed again from the
/// partial file, and moved into place only when the two digests match and the name is still free. A file already
/// there is never written over, except as the first limit below says. A run converges: run again, a raw already
/// copied is `alreadyThere`.
///
/// The caller holds security-scoped access to the card and the folder for the whole run.
///
/// Limits:
/// - exFAT and FAT have no exclusive rename and no file lock. There the name is checked and then taken, so a file
///   another program puts under it in that instant is replaced, and a second run in the same folder can delete this
///   run's partial file as stale.
/// - Another program that changes the folder mid-copy, such as swapping it for a symbolic link or deleting a copied
///   file between its check and its hash, is not defended against.
/// - A copy is synced with `fsync`, not `F_FULLFSYNC`, so a power loss just after it can leave a short file. The next
///   run reports it as a `conflict` that names it, and the raw is still on the card.
public enum KeeperCopy {
    /// What became of one raw.
    public enum Outcome: Sendable, Equatable {
        case copied(sha256: String)
        /// The folder held a file of the raw's name and bytes, and it was left as it was.
        case alreadyThere(sha256: String)
        /// The folder holds something else under the raw's name, which is left as it is.
        case conflict(existing: URL)
        case failed(Failure)
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
        /// The raw could not be opened or read, as when the card is gone.
        case unreadable(String)
        /// The raw shrank, grew or was written while it was read.
        case changedWhileRead
        /// The partial file read back with other bytes than the raw's.
        case readBackMismatch
        /// The folder could not be made, or could not take the raw: a write, sync, read back or move in it failed.
        case unwritable(String)
        /// Thrown before any write: the folder is on the volume of one of the raws.
        case folderOnCard(String)
        /// Thrown before any write: two raws have this name, ignoring case.
        case sameName(String)

        public var description: String {
            switch self {
            case .unreadable(let reason): "the raw could not be read: \(reason)"
            case .changedWhileRead: "the raw changed while it was read"
            case .readBackMismatch: "the copy read back with other bytes than the raw"
            case .unwritable(let reason): "the folder could not take the raw: \(reason)"
            case .folderOnCard(let path): "\(path) is on the same volume as the raws, which is never written"
            case .sameName(let name): "two raws would take the name \(name)"
            }
        }

        public var errorDescription: String? { description }
    }

    /// Thrown by `run` when a raw ends in `conflict` or `failed`: the first such raw in the order given.
    public struct Stopped: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
        public let raw: URL
        public let outcome: Outcome

        public var description: String {
            switch outcome {
            case .conflict(let existing): "\(raw.lastPathComponent): \(existing.path) holds another file of that name"
            case .failed(let failure): "\(raw.lastPathComponent): \(failure)"
            case .copied, .alreadyThere: "\(raw.lastPathComponent): copied"
            }
        }

        public var errorDescription: String? { description }
    }

    static let concurrentRaws = 4
    private static let chunk = 1 << 20
    private static let partialMarker = ".partial-"
    private static let partialTagLength = 8
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Argent keeper copy"
        queue.maxConcurrentOperationCount = concurrentRaws
        return queue
    }()

    /// Copies each raw to `folder/<its name>`, making the folder if it is missing, and returns the outcomes in the
    /// order of `raws`, every one `copied` or `alreadyThere`.
    ///
    /// `progress` hears every raw that finishes once, `alreadyThere` and the raw that stops the run included, one call
    /// at a time, in the order they finish and off the main actor. It carries no index or total: the caller counts.
    ///
    /// Throws `Failure` before any write when a raw cannot be read, when the folder is on a raw's volume (unless
    /// `allowsRawsVolume`, for raws in a folder rather than on a card), when two raws share a name, or when the folder
    /// cannot be made. Throws `Stopped` at a raw that conflicts or fails once copying
    /// has begun: no raw starts after it, the raws under way finish, and the raws copied stay. Throws
    /// `CancellationError` when cancelled, even after the last raw has finished: the raws under way stop and delete
    /// their partial files, and the raws copied stay.
    public static func run(_ raws: [URL], to folder: URL, allowsRawsVolume: Bool = false,
                           progress: @Sendable (URL, Outcome) async -> Void = { _, _ in }) async throws -> [Outcome] {
        var cardVolumes = Set<dev_t>()
        for raw in raws {
            let source = open(raw.path, O_RDONLY)
            guard source >= 0 else { throw Failure.unreadable("\(raw.lastPathComponent): \(lastError())") }
            defer { close(source) }
            var info = stat()
            guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw Failure.unreadable("\(raw.lastPathComponent): not a file")
            }
            cardVolumes.insert(info.st_dev)
        }
        return try await run(raws, to: folder, refusing: allowsRawsVolume ? [] : cardVolumes, progress: progress)
    }

    static func run(_ raws: [URL], to folder: URL, refusing cardVolumes: Set<dev_t>,
                    progress: @Sendable (URL, Outcome) async -> Void) async throws -> [Outcome] {
        var names = Set<String>()
        for raw in raws where !names.insert(raw.lastPathComponent.lowercased()).inserted {
            throw Failure.sameName(raw.lastPathComponent)
        }
        let target = try realFolder(folder)
        if cardVolumes.contains(target.volume) { throw Failure.folderOnCard(target.path) }
        do {
            try FileManager.default.createDirectory(atPath: target.path, withIntermediateDirectories: true)
        } catch {
            throw Failure.unwritable(error.localizedDescription)
        }
        let folder = URL(fileURLWithPath: target.path, isDirectory: true)
        removeStalePartials(in: folder, of: Set(raws.map(\.lastPathComponent)))

        var outcomes = [Outcome?](repeating: nil, count: raws.count)
        await withTaskGroup(of: (Int, Outcome?).self) { group in
            var next = 0
            func copyNext(_ group: inout TaskGroup<(Int, Outcome?)>) {
                let index = next
                next += 1
                group.addTask {
                    (index, await QueuedWork.runStoppable(on: queue) { stopped in copy(raws[index], into: folder, stopped: stopped) })
                }
            }
            var stopping = false
            while next < min(concurrentRaws, raws.count) { copyNext(&group) }
            while let (index, outcome) = await group.next() {
                guard let outcome else { continue }
                outcomes[index] = outcome
                await progress(raws[index], outcome)
                stopping = stopping || outcome.isProblem
                if !stopping, !Task.isCancelled, next < raws.count { copyNext(&group) }
            }
        }
        try Task.checkCancellation()
        if let index = outcomes.firstIndex(where: { $0?.isProblem == true }), let outcome = outcomes[index] {
            throw Stopped(raw: raws[index], outcome: outcome)
        }
        return outcomes.compactMap { $0 }
    }

    static func copy(_ raw: URL, into folder: URL, stopped: () -> Bool) -> Outcome? {
        let source = open(raw.path, O_RDONLY)
        guard source >= 0 else { return .failed(.unreadable(lastError())) }
        defer { close(source) }
        guard let stamp = SourceStamp.of(descriptor: source) else { return .failed(.unreadable("not a file")) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        let final = folder.appendingPathComponent(raw.lastPathComponent)

        var there = stat()
        if lstat(final.path, &there) == 0 {
            guard there.st_mode & S_IFMT == S_IFREG, there.st_size == stamp.size else { return .conflict(existing: final) }
            switch stream(source, buffer: buffer, stopped: stopped) {
            case .stopped: return nil
            case .readFailed(let reason), .writeFailed(let reason): return .failed(.unreadable(reason))
            case .done(let sha256, let count):
                guard count == stamp.size, SourceStamp.of(descriptor: source) == stamp, SourceStamp.of(raw) == stamp else {
                    return .failed(.changedWhileRead)
                }
                return alreadyThereOrConflict(final, sha256: sha256, buffer: buffer, stopped: stopped)
            }
        }

        guard let (partial, output) = lockedPartialFile(for: raw.lastPathComponent, in: folder) else {
            return .failed(.unwritable(lastError()))
        }
        var placed = false
        defer {
            if !placed { unlink(partial.path) }
            close(output)
        }

        let sha256: String
        switch stream(source, to: output, buffer: buffer, stopped: stopped) {
        case .stopped: return nil
        case .readFailed(let reason): return .failed(.unreadable(reason))
        case .writeFailed(let reason): return .failed(.unwritable(reason))
        case .done(let digest, let count):
            guard count == stamp.size, SourceStamp.of(descriptor: source) == stamp, SourceStamp.of(raw) == stamp else {
                return .failed(.changedWhileRead)
            }
            sha256 = digest
        }
        let modified = timespec(tv_sec: Int(stamp.modified / 1_000_000_000), tv_nsec: Int(stamp.modified % 1_000_000_000))
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), modified]
        futimens(output, &times)
        guard fsync(output) == 0 else { return .failed(.unwritable(lastError())) }

        let readBack = open(partial.path, O_RDONLY)
        guard readBack >= 0 else { return .failed(.unwritable(lastError())) }
        defer { close(readBack) }
        switch stream(readBack, buffer: buffer, stopped: stopped) {
        case .stopped: return nil
        case .readFailed(let reason), .writeFailed(let reason): return .failed(.unwritable(reason))
        case .done(let digest, _): guard digest == sha256 else { return .failed(.readBackMismatch) }
        }

        if renamex_np(partial.path, final.path, UInt32(RENAME_EXCL)) == 0 {
            placed = true
            return .copied(sha256: sha256)
        }
        switch errno {
        case EEXIST:
            return alreadyThereOrConflict(final, sha256: sha256, buffer: buffer, stopped: stopped)
        case ENOTSUP:
            guard lstat(final.path, &there) != 0 else { return alreadyThereOrConflict(final, sha256: sha256, buffer: buffer, stopped: stopped) }
            guard rename(partial.path, final.path) == 0 else { return .failed(.unwritable(lastError())) }
            placed = true
            return .copied(sha256: sha256)
        default:
            return .failed(.unwritable(lastError()))
        }
    }

    private static func alreadyThereOrConflict(_ final: URL, sha256: String, buffer: UnsafeMutableRawBufferPointer,
                                               stopped: () -> Bool) -> Outcome? {
        let file = open(final.path, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { return .conflict(existing: final) }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .conflict(existing: final) }
        switch stream(file, buffer: buffer, stopped: stopped) {
        case .stopped: return nil
        case .readFailed(let reason), .writeFailed(let reason): return .failed(.unwritable(reason))
        case .done(let digest, _): return digest == sha256 ? .alreadyThere(sha256: sha256) : .conflict(existing: final)
        }
    }

    private enum Streamed {
        case done(sha256: String, count: Int64)
        case stopped
        case readFailed(String)
        case writeFailed(String)
    }

    private static func stream(_ input: Int32, to output: Int32? = nil, buffer: UnsafeMutableRawBufferPointer,
                               stopped: () -> Bool) -> Streamed {
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            if stopped() { return .stopped }
            let got = read(input, buffer.baseAddress, buffer.count)
            if got < 0 {
                if errno == EINTR { continue }
                return .readFailed(lastError())
            }
            if got == 0 { break }
            let bytes = UnsafeRawBufferPointer(rebasing: buffer[..<got])
            hash.update(bufferPointer: bytes)
            if let output {
                var written = 0
                while written < got {
                    let wrote = write(output, bytes.baseAddress! + written, got - written)
                    if wrote < 0, errno == EINTR { continue }
                    guard wrote > 0 else { return .writeFailed(lastError()) }
                    written += wrote
                }
            }
            count += Int64(got)
        }
        return .done(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), count: count)
    }

    private static func lockedPartialFile(for name: String, in folder: URL) -> (URL, Int32)? {
        let partial = folder.appendingPathComponent(".\(name)\(partialMarker)\(UUID().uuidString.prefix(partialTagLength))")
        var output = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_EXLOCK, 0o644)
        if output < 0, errno == ENOTSUP { output = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o644) }
        return output >= 0 ? (partial, output) : nil
    }

    private static func removeStalePartials(in folder: URL, of names: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for entry in entries where entry.hasPrefix(".") {
            guard let marker = entry.range(of: partialMarker, options: .backwards),
                  names.contains(String(entry[entry.index(after: entry.startIndex)..<marker.lowerBound])),
                  entry[marker.upperBound...].count == partialTagLength,
                  entry[marker.upperBound...].allSatisfy("0123456789ABCDEF".contains) else { continue }
            let path = folder.appendingPathComponent(entry).path
            var held = open(path, O_RDONLY | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK)
            if held < 0, errno == ENOTSUP { held = open(path, O_RDONLY | O_NOFOLLOW) }
            guard held >= 0 else { continue }
            unlink(path)
            close(held)
        }
    }

    static func realFolder(_ folder: URL) throws -> (path: String, volume: dev_t) {
        var components = folder.path.split(separator: "/").map(String.init)
        while true {
            var existing = components.count
            var real = realPath("/" + components.joined(separator: "/"))
            while real == nil {
                existing -= 1
                real = realPath("/" + components.prefix(existing).joined(separator: "/"))
            }
            let missing = Array(components[existing...])
            let base = real!.split(separator: "/").map(String.init)
            if missing.contains(".") || missing.contains("..") {
                components = withoutDots(base + missing)
                continue
            }
            var info = stat()
            guard stat(real!, &info) == 0 else { throw Failure.unwritable(lastError()) }
            return ("/" + (base + missing).joined(separator: "/"), info.st_dev)
        }
    }

    private static func withoutDots(_ components: [String]) -> [String] {
        components.reduce(into: []) { path, name in
            if name == ".." { _ = path.popLast() } else if name != "." { path.append(name) }
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private static func lastError() -> String { String(cString: strerror(errno)) }
}

private extension KeeperCopy.Outcome {
    var isProblem: Bool {
        switch self {
        case .conflict, .failed: true
        case .copied, .alreadyThere: false
        }
    }
}
