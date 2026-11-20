import Foundation

/// A frame's files, moved together: its raw, and beside it its recipe (`DSC00601.argent`), the seeds of the masks that
/// recipe names (`DSC00601.argentmasks`) and the patches of its removals (`DSC00601.argentpatches`). A roll is a folder, so a frame leaves a roll when its raw leaves the folder, and
/// joins another when its raw arrives there; its recipe goes with it, so the frame arrives as it was left
/// (`RecipeWriter.read` finds a moved raw's record by its bytes). Nothing is ever written over: a folder that already
/// holds a file under one of the frame's names keeps it, and the frame stays where it was.
public enum FrameFiles {
    public struct CompanionFailure: Sendable, Equatable {
        public let file: URL
        public let message: String

        public init(file: URL, message: String) {
            self.file = file
            self.message = message
        }
    }

    /// What came of moving one frame.
    public enum Outcome: Sendable, Equatable {
        /// The raw is here now, its recipe, masks and patches beside it.
        case moved(URL)
        /// The raw moved here, but these companions stayed behind, with the reason each could not move.
        case partiallyMoved(URL, failures: [CompanionFailure])
        /// The folder already holds a file under the raw's name, or its recipe's, masks' or patches': nothing of the frame moved.
        case nameTaken
        /// The raw could not be moved, and why: nothing of the frame moved.
        case failed(String)

        /// Whether the raw left its source roll, even if a companion stayed behind.
        public var isMoved: Bool {
            switch self {
            case .moved, .partiallyMoved: true
            case .nameTaken, .failed: false
            }
        }
    }

    /// The recipe, the masks' seeds and the removals' patches beside `raw`, whether or not they are there.
    public static func companions(of raw: URL) -> [URL] {
        [RecipeStore.besideRaw(raw), RecipeStore.masksBesideRaw(raw), RecipeStore.patchesBesideRaw(raw)]
    }

    /// Moves each of `raws` into `folder` with its companions, one frame after another, and says what came of each, in
    /// their order. A frame is moved whole or not at all as far as its raw goes: the raw first, and only then its
    /// recipe, masks and patches, which a raw that stayed keeps. Across volumes the raw is copied under a hidden name, checked
    /// for its length, given its name, and only then removed from where it was.
    public static func move(_ raws: [URL], into folder: URL) -> [Outcome] {
        raws.map { move($0, into: folder) }
    }

    static func move(_ raw: URL, into folder: URL) -> Outcome {
        let manager = FileManager.default
        guard manager.fileExists(atPath: raw.path) else { return .failed("The file is no longer there") }
        let files = [raw] + companions(of: raw)
        let targets = files.map { folder.appendingPathComponent($0.lastPathComponent) }
        guard targets.allSatisfy({ !manager.fileExists(atPath: $0.path) }) else { return .nameTaken }
        do {
            try relocate(raw, to: targets[0])
        } catch {
            return .failed(error.localizedDescription)
        }
        var failures: [CompanionFailure] = []
        for (companion, target) in zip(files, targets).dropFirst() where manager.fileExists(atPath: companion.path) {
            do {
                try relocate(companion, to: target)
            } catch {
                failures.append(CompanionFailure(file: companion, message: companionMessage(error)))
            }
        }
        return failures.isEmpty ? .moved(targets[0]) : .partiallyMoved(targets[0], failures: failures)
    }

    /// Moves each of `raws` to the Trash with its companions, where Finder's Put Back returns them, and says what came
    /// of each, in their order; `.moved` carries where the raw is in the Trash. `trashing` moves one file and returns
    /// where it went: the system's Trash, or a test's own folder.
    public static func trash(_ raws: [URL], trashing: (URL) throws -> URL = systemTrash) -> [Outcome] {
        raws.map { raw in
            let manager = FileManager.default
            guard manager.fileExists(atPath: raw.path) else { return .failed("The file is no longer there") }
            let trashed: URL
            do {
                trashed = try trashing(raw)
            } catch {
                return .failed(error.localizedDescription)
            }
            var failures: [CompanionFailure] = []
            for companion in companions(of: raw) where manager.fileExists(atPath: companion.path) {
                do {
                    _ = try trashing(companion)
                } catch {
                    failures.append(CompanionFailure(file: companion, message: companionMessage(error)))
                }
            }
            return failures.isEmpty ? .moved(trashed) : .partiallyMoved(trashed, failures: failures)
        }
    }

    private static func companionMessage(_ error: any Error) -> String {
        let error = error as NSError
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return underlying.localizedFailureReason ?? underlying.localizedDescription
        }
        return error.localizedFailureReason ?? error.localizedDescription
    }

    /// The user's Trash. A test may not use it, as it may not use Application Support: it gives its own.
    public static func systemTrash(_ file: URL) throws -> URL {
        if ProcessInfo.isRunningTests { fatalError("A test moved \(file.lastPathComponent) to the Trash: give FrameFiles.trash a folder of its own") }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        return (trashed as URL?) ?? file
    }

    /// Moves `file` to `target`, which must not be there: a rename on one volume; across volumes a copy under a hidden
    /// name, never read as a raw (`RollScanner.rawFiles`), that takes the file's name once it is whole, after which the
    /// file is removed from where it was. A copy that cannot be finished is removed, and the file stays.
    private static func relocate(_ file: URL, to target: URL) throws {
        let manager = FileManager.default
        let folder = target.deletingLastPathComponent()
        if let from = device(file), let to = device(folder), from == to {
            try manager.moveItem(at: file, to: target)
            return
        }
        let partial = folder.appendingPathComponent(".argent-moving-\(UUID().uuidString)-\(target.lastPathComponent)")
        do {
            try manager.copyItem(at: file, to: partial)
            guard byteCount(partial) == byteCount(file) else { throw CocoaError(.fileWriteUnknown) }
            try manager.moveItem(at: partial, to: target)
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
        do {
            try manager.removeItem(at: file)
        } catch {
            // The frame would be in both folders: it stays in the one it was in.
            try? manager.removeItem(at: target)
            throw error
        }
    }

    private static func device(_ url: URL) -> dev_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_dev : nil
    }

    private static func byteCount(_ url: URL) -> Int64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int64(info.st_size) : nil
    }
}
