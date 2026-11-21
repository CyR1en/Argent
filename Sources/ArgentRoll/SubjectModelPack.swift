import AppleArchive
import ArgentCore
import CryptoKit
import Foundation
import System

/// The Subject models as one optional download: S3OD-sod (the region), EoMT (the "no subject" gate, and Sky's water veto) and ViTMatte-S (the edge in the
/// low-light rule), with their licence texts. The public app carries none of them; Subject and Background offer this pack until it is installed, after the user
/// has read its licence screen (`SubjectModelsSheet`). The pack is an Apple Archive that `scripts/build-subject-models.zsh` makes from `build/models` and the
/// owner uploads to a GitHub release; it is pinned here by URL, size and SHA-256, and each model in it is checked against `BundledMaskModel`'s pins again
/// before it is put in place. Installed in Application Support's `Models` folder, which `MaskModels` looks in after the app's own.
public struct SubjectModelPack: Sendable, Equatable {
    public var version: Int
    public var url: URL
    /// The archive's size in bytes, and its SHA-256.
    public var bytes: Int64
    public var sha256: String
    /// What it takes on disk once unpacked, for the free-space check and the screen.
    public var installedBytes: Int64

    /// The models it holds: what Subject needs (`MaskModels.subjectModels`).
    public static let models = MaskModels.subjectModels
    /// The licence texts' folder inside the pack and the installed folder.
    public static let licencesFolder = "Licences"
    /// Prefix for staging folders created beside the installed models while an install runs.
    static let stagingPrefix = ".install-"

    /// The pack this build of Argent installs. Made by `scripts/build-subject-models.zsh` from the models these pins name (2026-11-20).
    public static let current = SubjectModelPack(
        version: 1,
        url: URL(string: "https://github.com/CyR1en/Argent/releases/download/subject-models-1/argent-subject-models-1.aar")!,
        bytes: SubjectModelPackPins.bytes, sha256: SubjectModelPackPins.sha256, installedBytes: SubjectModelPackPins.installedBytes)

    /// Where downloaded models go: `Models` in the app's Application Support.
    public static var installedFolder: URL { ApplicationSupport.folder.appendingPathComponent("Models", isDirectory: true) }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case download(String)
        case notThePinnedFile(String)
        case unpack(String)
        case notThePinnedModel(String)
        case install(String)
        case noRoom(needed: Int64, free: Int64)

        public var description: String {
            switch self {
            case .download(let why): return "The download failed: \(why)"
            case .notThePinnedFile(let why): return "The downloaded file is not the one this version of Argent expects (\(why)). Nothing was installed."
            case .unpack(let why): return "The download could not be unpacked: \(why). Nothing was installed."
            case .notThePinnedModel(let why): return "A model in the download is not the one this version of Argent expects: \(why). Nothing was installed."
            case .install(let why): return "The models could not be installed: \(why)."
            case .noRoom(let needed, let free):
                let f = ByteCountFormatter()
                return "The models need \(f.string(fromByteCount: needed)) of free space, and the disk has \(f.string(fromByteCount: free))."
            }
        }
    }

    /// Where an install is.
    public enum Step: Sendable, Equatable {
        /// 0...1 of the archive.
        case downloading(Double)
        case checking
        case unpacking
        case done
    }

    public init(version: Int, url: URL, bytes: Int64, sha256: String, installedBytes: Int64) {
        self.version = version
        self.url = url
        self.bytes = bytes
        self.sha256 = sha256
        self.installedBytes = installedBytes
    }

    /// Downloads the pack, checks its size and SHA-256, unpacks it beside `folder`, checks every model against the pins, then puts the licences and models
    /// into `folder`, replacing what was there. Nothing in `folder` changes unless every check passes. Cancelling the calling task stops the download.
    public func install(into folder: URL, step: @escaping @Sendable (Step) -> Void = { _ in }) async throws {
        let manager = FileManager.default
        do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            throw Failure.install("the Models folder could not be created: \(error.localizedDescription)")
        }
        Self.sweepStaging(in: folder)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        if free < bytes + installedBytes { throw Failure.noRoom(needed: bytes + installedBytes, free: free) }

        let work = folder.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        do { try manager.createDirectory(at: work, withIntermediateDirectories: true) } catch {
            throw Failure.install("a temporary folder could not be created: \(error.localizedDescription)")
        }
        defer { try? manager.removeItem(at: work) }
        let archive = work.appendingPathComponent("pack.aar")

        step(.downloading(0))
        try await Self.fetch(url, to: archive) { step(.downloading($0)) }
        try Task.checkCancellation()

        step(.checking)
        let size = (try? manager.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? -1
        guard size == bytes else { throw Failure.notThePinnedFile("\(size) bytes, not \(bytes)") }
        let digest: String
        do { digest = try Self.sha256(of: archive) } catch {
            throw Failure.notThePinnedFile("the archive could not be read: \(error.localizedDescription)")
        }
        guard digest == sha256 else { throw Failure.notThePinnedFile("SHA-256 \(digest.prefix(12))…, not \(sha256.prefix(12))…") }
        try Task.checkCancellation()

        step(.unpacking)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try Self.extract(archive, into: unpacked, isCancelled: { Task.isCancelled })
        try? manager.removeItem(at: archive)
        try Task.checkCancellation()

        let staged = MaskModels(directories: [unpacked], ledgerFile: work.appendingPathComponent("unused.json"))
        for model in Self.models {
            let identity: MaskModelIdentity
            do { identity = try staged.identity(of: model) } catch { throw Failure.notThePinnedModel(String(describing: error)) }
            let mlirb = unpacked.appendingPathComponent(model.fileName, isDirectory: true).appendingPathComponent("main.mlirb")
            let fileDigest: String
            do { fileDigest = try Self.sha256(of: mlirb) } catch {
                throw Failure.notThePinnedModel("\(model.fileName)'s main.mlirb could not be read: \(error.localizedDescription)")
            }
            guard fileDigest == identity.fileSHA256 else { throw Failure.notThePinnedModel("\(model.fileName)'s main.mlirb is not its main.hash") }
            try Task.checkCancellation()
        }
        var isLicencesDirectory: ObjCBool = false
        let stagedLicences = unpacked.appendingPathComponent(Self.licencesFolder)
        guard manager.fileExists(atPath: stagedLicences.path, isDirectory: &isLicencesDirectory), isLicencesDirectory.boolValue else {
            throw Failure.notThePinnedModel("the licence texts (\(Self.licencesFolder)) are missing")
        }
        try Task.checkCancellation()

        // Every check passed: the licences go in first, then the models. Each old copy moves aside into the work folder (the same volume, so
        // every move is a rename) before its new one goes in; if any move fails, the new ones come out and the old ones go back.
        let names = [Self.licencesFolder] + Self.models.flatMap { [$0.fileName, $0.manifestName] }
        let previous = work.appendingPathComponent("previous", isDirectory: true)
        var placed: [String] = [], setAside: [String] = []
        do {
            try manager.createDirectory(at: previous, withIntermediateDirectories: true)
            for name in names {
                let target = folder.appendingPathComponent(name)
                // Not `fileExists`, which follows a symbolic link and misses a broken one.
                if (try? manager.attributesOfItem(atPath: target.path)) != nil {
                    try manager.moveItem(at: target, to: previous.appendingPathComponent(name))
                    setAside.append(name)
                }
                try manager.moveItem(at: unpacked.appendingPathComponent(name), to: target)
                placed.append(name)
            }
        } catch {
            for name in placed { try? manager.removeItem(at: folder.appendingPathComponent(name)) }
            for name in setAside { try? manager.moveItem(at: previous.appendingPathComponent(name), to: folder.appendingPathComponent(name)) }
            throw Failure.install("could not put the models in place: \(error.localizedDescription)")
        }
        step(.done)
    }

    /// Removes orphaned `.install-*` staging folders left behind by a quit or crash during download or install.
    public static func sweepStaging(in folder: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in entries where name.hasPrefix(stagingPrefix) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Deletes the downloaded models, their licences, and any orphaned staging folders from `folder`.
    public static func remove(from folder: URL) throws {
        let manager = FileManager.default
        for name in models.flatMap({ [$0.fileName, $0.manifestName] }) + [licencesFolder] {
            let target = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        }
        sweepStaging(in: folder)
    }

    // MARK: Parts

    /// `url` to `destination`, telling `progress` 0...1. A file URL is copied (tests, and a pack the user already has).
    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if url.isFileURL {
            do { try FileManager.default.copyItem(at: url, to: destination) } catch { throw Failure.download(error.localizedDescription) }
            progress(1)
            return
        }
        let box = DownloadBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                let task = URLSession.shared.downloadTask(with: request) { temporary, response, error in
                    box.finish()
                    if let error {
                        let cancelled = (error as? URLError)?.code == .cancelled
                        continuation.resume(throwing: cancelled ? CancellationError() : Failure.download(error.localizedDescription))
                        return
                    }
                    guard let temporary, let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: Failure.download("no file came back"))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        continuation.resume(throwing: Failure.download("the server answered \(http.statusCode)"))
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: Failure.download(error.localizedDescription))
                    }
                }
                box.start(task, progress: progress)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// The file's SHA-256, read 8 MB at a time.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            // 841 MB takes seconds: Stop and Quit are heard between chunks.
            try Task.checkCancellation()
            let done: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return true }
                hash.update(data: chunk)
                return false
            }
            if done { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Allows only directories and regular files with clean relative paths (no `..`, no leading `/`, no symlinks or hard links).
    static func isAllowedEntry(header: ArchiveHeader, path: String) -> Bool {
        guard let type = header.entryType, type == .directory || type == .regularFile else { return false }
        if header.field(forKey: ArchiveHeader.FieldKey("LNK")) != nil || header.field(forKey: ArchiveHeader.FieldKey("HLC")) != nil { return false }
        let headerPath = header.entryPath?.string ?? path
        return isCleanRelativePath(path, isDirectory: type == .directory)
            && isCleanRelativePath(headerPath, isDirectory: type == .directory)
    }

    private static func isCleanRelativePath(_ path: String, isDirectory: Bool) -> Bool {
        if path.isEmpty { return isDirectory }
        if path.hasPrefix("/") || path.hasSuffix("/") { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Unpacks an Apple Archive (any compression `aa` writes) into `folder`, allowing only directories and regular files with clean relative paths.
    static func extract(_ archive: URL, into folder: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            throw Failure.unpack(error.localizedDescription)
        }
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)) else {
            throw Failure.unpack("the archive could not be opened")
        }
        var fileClosed = false
        defer { if !fileClosed { try? file.close() } }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw Failure.unpack("not a compressed archive") }
        var decompressedClosed = false
        defer { if !decompressedClosed { try? decompressed.close() } }
        // Cancelling is heard inside an entry too, not only between them: EoMT's one file is 630 MB.
        guard let decoded = ArchiveStream.decodeStream(readingFrom: decompressed, selectUsing: { _, _, _ in isCancelled() ? .cancel : .ok }) else {
            throw Failure.unpack("not an archive")
        }
        var decodedClosed = false
        defer { if !decodedClosed { try? decoded.close() } }
        let rejected = RejectionBox()
        let filter: ArchiveHeader.EntryFilter = { message, path, data in
            if isCancelled() { return .cancel }
            switch message {
            case .processExclude, .extractBegin:
                guard case .header(let header)? = data, Self.isAllowedEntry(header: header, path: path.string) else {
                    rejected.note("disallowed archive entry '\(path.string)'")
                    return .cancel
                }
                return .ok
            case .extractFail:
                rejected.note("could not extract '\(path.string)'")
                return .cancel
            default:
                return .ok
            }
        }
        guard let extracted = ArchiveStream.extractStream(extractingTo: FilePath(folder.path), selectUsing: filter, flags: [.ignoreOperationNotPermitted]) else {
            throw Failure.unpack("the folder could not be written")
        }
        var extractedClosed = false
        defer { if !extractedClosed { try? extracted.close() } }
        do {
            _ = try ArchiveStream.process(readingFrom: decoded, writingTo: extracted, selectUsing: filter)
            extractedClosed = true
            try extracted.close()
            decodedClosed = true
            try decoded.close()
            decompressedClosed = true
            try decompressed.close()
            fileClosed = true
            try file.close()
            if isCancelled() { throw CancellationError() }
            if let why = rejected.reason { throw Failure.unpack(why) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            if isCancelled() { throw CancellationError() }
            if let why = rejected.reason { throw Failure.unpack(why) }
            throw Failure.unpack(String(describing: error))
        }
    }
}

/// First reason an entry filter rejected an archive entry, shared across Apple Archive's worker threads.
private final class RejectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    func note(_ text: String) {
        lock.withLock { if message == nil { message = text } }
    }

    var reason: String? { lock.withLock { message } }
}

/// The task a download runs on, held so cancelling the caller cancels it, and its progress observed.
private final class DownloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false
    /// The fraction last passed on: the progress fires for every chunk, thousands over the pack, and only a half-percent step is passed on.
    private var reported = 0.0

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
        let go: Bool = lock.withLock {
            guard !cancelled else { return false }
            self.task = task
            observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                guard let self, let fraction = self.step(to: p.fractionCompleted) else { return }
                progress(fraction)
            }
            return true
        }
        if go { task.resume() } else { task.cancel() }
    }

    /// `fraction`, clamped, when it is half a percent past the last one passed on or the end; `nil` otherwise.
    private func step(to fraction: Double) -> Double? {
        guard fraction.isFinite else { return nil }
        let clamped = min(max(fraction, 0), 1)
        return lock.withLock {
            guard clamped - reported >= 0.005 || (clamped >= 1 && reported < 1) else { return nil }
            reported = clamped
            return clamped
        }
    }

    func finish() {
        let observation: NSKeyValueObservation? = lock.withLock {
            defer {
                self.observation = nil
                self.task = nil
            }
            return self.observation
        }
        observation?.invalidate()
    }

    func cancel() {
        let (task, observation): (URLSessionDownloadTask?, NSKeyValueObservation?) = lock.withLock {
            cancelled = true
            defer {
                self.observation = nil
                self.task = nil
            }
            return (self.task, self.observation)
        }
        observation?.invalidate()
        task?.cancel()
    }
}
