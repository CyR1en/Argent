import ArgentCore
import Foundation

/// One raw file of a roll, with what its header says.
public struct Frame: Sendable, Identifiable, Equatable {
    /// Position in capture order, from 0.
    public let id: Int
    public let url: URL
    public let info: ARWFrameInfo

    public init(id: Int, url: URL, info: ARWFrameInfo) {
        self.id = id
        self.url = url
        self.info = info
    }

    /// The file name without its extension, as the camera wrote it.
    public var name: String { url.deletingPathExtension().lastPathComponent }

    /// The frame's own grain, the same on every render of it.
    public var grainSeed: UInt32 { GrainModel.seed(name: url.lastPathComponent, captureDate: info.captureDate) }
}

/// A folder or card of ARW files, in capture order.
public struct Roll: Sendable {
    public let folder: URL
    public let frames: [Frame]
    /// ARW files whose headers could not be read; they are left out of `frames`.
    public let unreadable: [URL]

    public init(folder: URL, frames: [Frame], unreadable: [URL] = []) {
        self.folder = folder
        self.frames = frames
        self.unreadable = unreadable
    }

    /// The folder's name, or the volume's for a card.
    public var name: String { folder.lastPathComponent }
}

public enum RollScanner {
    /// Deep enough for a card, whose raws sit in DCIM/100MSDCF.
    public static let maximumDepth = 4

    /// The ARW files under `folder`, any case of the extension, skipping hidden files and
    /// AppleDouble companions, no deeper than `maximumDepth`. A roll folder that is itself a
    /// symbolic link is followed (the enumerator would list nothing under it); links inside
    /// the roll are not.
    public static func rawFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "arw", !url.lastPathComponent.hasPrefix("._"),
                  (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true
            else { continue }
            files.append(url)
        }
        return files
    }

    /// Reads every raw file's header under `folder` and orders the frames by capture time,
    /// to the millisecond the a7 IV writes in SubSecTimeOriginal, then by path within the roll
    /// for frames taken in the same millisecond or with no time: the DCF folder before the file
    /// name, since a camera that numbers past DSC09999 starts again at DSC00001 in the next folder.
    /// Cancelling the task stops the reading between files; the roll then has only the frames read before.
    public static func scan(_ folder: URL) async -> Roll {
        let files = rawFiles(in: folder)
        // Headers are a few small reads each; read them in parallel in a handful of chunks.
        let chunkSize = max(1, (files.count + 2 * ProcessInfo.processInfo.activeProcessorCount - 1)
                                / (2 * ProcessInfo.processInfo.activeProcessorCount))
        let chunks = stride(from: 0, to: files.count, by: chunkSize).map { Array(files[$0..<min(files.count, $0 + chunkSize)]) }
        let results = await withTaskGroup(of: [(URL, ARWFrameInfo?)].self) { group in
            for chunk in chunks {
                group.addTask {
                    var read: [(URL, ARWFrameInfo?)] = []
                    for url in chunk where !Task.isCancelled { read.append((url, try? ARWFrameInfo.read(from: url))) }
                    return read
                }
            }
            var all: [(URL, ARWFrameInfo?)] = []
            for await part in group { all += part }
            return all
        }
        let readable = results.compactMap { url, info in info.map { (url, $0) } }
        let ordered = readable.sorted { capturedBefore($0.0, at: $0.1.captureDate, $1.0, at: $1.1.captureDate) }
        return Roll(folder: folder,
                    frames: ordered.enumerated().map { Frame(id: $0.offset, url: $0.element.0, info: $0.element.1) },
                    unreadable: results.filter { $0.1 == nil }.map(\.0).sorted { $0.path < $1.path })
    }

    /// Whether the raw at `a`, taken at `aDate`, comes before the one at `b`, taken at `bDate`, in a roll's order:
    /// the earlier capture first, frames with no time after those with one, then by path, as `scan` describes.
    static func capturedBefore(_ a: URL, at aDate: Date?, _ b: URL, at bDate: Date?) -> Bool {
        switch (aDate, bDate) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }
}

extension URL {
    /// The path with symbolic links resolved, so two spellings of one folder compare equal:
    /// a folder reached through a bookmark comes back as /private/tmp/x where the recipe that
    /// named it says /tmp/x. Components that do not exist are kept as they are.
    public var canonicalPath: String { standardizedFileURL.resolvingSymlinksInPath().path }
}

extension String {
    /// `canonicalPath` of the file path this string is.
    public var canonicalPath: String { URL(fileURLWithPath: self).canonicalPath }
}
