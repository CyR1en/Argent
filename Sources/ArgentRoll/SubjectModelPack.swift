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
        case noRoom(needed: Int64, free: Int64)

        public var description: String {
            switch self {
            case .download(let why): return "The download failed: \(why)"
            case .notThePinnedFile(let why): return "The downloaded file is not the one this version of Argent expects (\(why)). Nothing was installed."
            case .unpack(let why): return "The download could not be unpacked: \(why). Nothing was installed."
            case .notThePinnedModel(let why): return "A model in the download is not the one this version of Argent expects: \(why). Nothing was installed."
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

    /// Downloads the pack, checks its size and SHA-256, unpacks it beside `folder`, checks every model against the pins, then moves the models and the
    /// licences into `folder`, replacing what was there. Nothing in `folder` changes unless every check passes. Cancelling the calling task stops the download.
    public func install(into folder: URL, step: @escaping @Sendable (Step) -> Void = { _ in }) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        if free < bytes + installedBytes { throw Failure.noRoom(needed: bytes + installedBytes, free: free) }

        let work = folder.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let archive = work.appendingPathComponent("pack.aar")

        step(.downloading(0))
        try await Self.fetch(url, to: archive) { step(.downloading($0)) }
        try Task.checkCancellation()

        step(.checking)
        let size = (try? manager.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? -1
        guard size == bytes else { throw Failure.notThePinnedFile("\(size) bytes, not \(bytes)") }
        let digest = try Self.sha256(of: archive)
        guard digest == sha256 else { throw Failure.notThePinnedFile("SHA-256 \(digest.prefix(12))…, not \(sha256.prefix(12))…") }
        try Task.checkCancellation()

        step(.unpacking)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try Self.extract(archive, into: unpacked)
        try? manager.removeItem(at: archive)
        let staged = MaskModels(directories: [unpacked], ledgerFile: work.appendingPathComponent("unused.json"))
        for model in Self.models {
            do { _ = try staged.identity(of: model) } catch { throw Failure.notThePinnedModel(String(describing: error)) }
            let hash = try Data(contentsOf: unpacked.appendingPathComponent(model.fileName).appendingPathComponent("main.hash"))
            let file = try Data(contentsOf: unpacked.appendingPathComponent(model.fileName).appendingPathComponent("main.mlirb"), options: .mappedIfSafe)
            guard Data(SHA256.hash(data: file)) == hash else { throw Failure.notThePinnedModel("\(model.fileName)'s main.mlirb is not its main.hash") }
        }
        try Task.checkCancellation()

        // Every check passed: the models go in, each replacing its old copy.
        var names = Self.models.flatMap { [$0.fileName, $0.manifestName] }
        if manager.fileExists(atPath: unpacked.appendingPathComponent(Self.licencesFolder).path) { names.append(Self.licencesFolder) }
        for name in names {
            let target = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.moveItem(at: unpacked.appendingPathComponent(name), to: target)
        }
        step(.done)
    }

    /// Deletes the downloaded models and their licences from `folder`.
    public static func remove(from folder: URL) throws {
        let manager = FileManager.default
        for name in models.flatMap({ [$0.fileName, $0.manifestName] }) + [licencesFolder] {
            let target = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        }
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
                let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
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
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unpacks an Apple Archive (any compression `aa` writes) into `folder`.
    static func extract(_ archive: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)) else {
            throw Failure.unpack("the archive could not be opened")
        }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw Failure.unpack("not a compressed archive") }
        defer { try? decompressed.close() }
        guard let decoded = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw Failure.unpack("not an archive") }
        defer { try? decoded.close() }
        guard let extracted = ArchiveStream.extractStream(extractingTo: FilePath(folder.path), flags: [.ignoreOperationNotPermitted]) else {
            throw Failure.unpack("the folder could not be written")
        }
        defer { try? extracted.close() }
        do { _ = try ArchiveStream.process(readingFrom: decoded, writingTo: extracted) } catch { throw Failure.unpack(String(describing: error)) }
    }
}

/// The task a download runs on, held so cancelling the caller cancels it, and its progress observed.
private final class DownloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
        let go: Bool = lock.withLock {
            self.task = task
            observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            return !cancelled
        }
        if go { task.resume() } else { task.cancel() }
    }

    func cancel() {
        let task: URLSessionDownloadTask? = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

extension MaskModels {
    /// The app's: its own folder, then the downloaded Subject models.
    public convenience init(appLedgerFile: URL) {
        self.init(directories: [MaskModels.bundledDirectory, SubjectModelPack.installedFolder].compactMap(\.self), ledgerFile: appLedgerFile)
    }
}
