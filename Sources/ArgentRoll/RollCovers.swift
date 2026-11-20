import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Rolls page's pictures of a roll: up to `count` of its frames, spread from its first to its last, from their
/// embedded previews, kept as small JPEGs in a folder of the roll's id so the page shows them without reaching the
/// roll's folder, even with its drive away.
public final class RollCoverStore: @unchecked Sendable {
    /// What reading a roll's folder found: its raws, the first frame's capture time, and the covers.
    public struct Read: @unchecked Sendable {
        public var frameCount: Int
        public var firstCapture: Date?
        public var covers: [CGImage]
    }

    /// Frames on a roll's strip: more than the widest window shows.
    public static let count = 10
    /// A cover's longer side, in pixels: twice the strip's frame, for a Retina display.
    public static let pixelSize = 320

    public let folder: URL
    private let lock = NSLock()
    private var reads: [UUID: UUID] = [:]

    /// `folder` holds a folder of covers for each roll; tests give a temporary one.
    public init(folder: URL) {
        self.folder = folder
    }

    /// Starts a read, superseding any earlier read for this roll.
    public func beginRead(for id: UUID) -> UUID {
        lock.withLock {
            let generation = UUID()
            reads[id] = generation
            return generation
        }
    }

    public func isCurrent(_ generation: UUID, for id: UUID) -> Bool {
        lock.withLock { reads[id] == generation }
    }

    /// The covers kept for the roll `id`, in roll order; none when none are kept.
    public func covers(for id: UUID) -> [CGImage] {
        let directory = folder.appendingPathComponent(id.uuidString, isDirectory: true)
        let names = lock.withLock { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] }
        return names.filter { $0.hasSuffix(".jpg") }.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    /// Keeps `covers` as the roll `id`'s, in place of any kept before.
    public func keep(_ covers: [CGImage], for id: UUID, generation: UUID? = nil) {
        let directory = folder.appendingPathComponent(id.uuidString, isDirectory: true)
        lock.withLock {
            if let generation, reads[id] != generation { return }
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, image) in covers.enumerated() {
                let url = directory.appendingPathComponent(String(format: "%02d.jpg", index))
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    /// Lets go of the roll `id`'s covers, as when it leaves the library.
    public func remove(_ id: UUID) {
        lock.withLock {
            reads[id] = nil
            _ = try? FileManager.default.removeItem(at: folder.appendingPathComponent(id.uuidString, isDirectory: true))
        }
    }

    /// Reads the roll in `rollFolder`, whose access the caller holds: how many raws it has, when its first frame was
    /// taken, and `count` covers spread across it. Reads every raw's header, a few small reads each, so the covers
    /// follow capture order, as the roll's frames do, and the first capture is the earliest of them all; it reads the
    /// small embedded previews of the frames it shows only, never a raw whole. `nil` when the folder holds no raws.
    public static func read(_ rollFolder: URL, count: Int = RollCoverStore.count) -> Read? {
        let files = RollScanner.rawFiles(in: rollFolder)
        guard !files.isEmpty else { return nil }
        let headers = files.map { ($0, try? ARWFrameInfo.read(from: $0)) }
        let ordered = headers.sorted {
            RollScanner.capturedBefore($0.0, at: $0.1?.captureDate, $1.0, at: $1.1?.captureDate)
        }
        let firstCapture = headers.compactMap { $0.1?.captureDate }.min()
        var covers: [CGImage] = []
        for index in spread(ordered.count, count) {
            let (file, header) = ordered[index]
            guard let info = header else { continue }
            if let preview = info.preview,
               let image = try? EmbeddedJPEG.image(at: preview, in: file, maxPixelSize: pixelSize, orientation: info.orientation) {
                covers.append(image)
            }
        }
        return Read(frameCount: files.count, firstCapture: firstCapture, covers: covers)
    }

    /// `count` indices from 0 to `total - 1`, spread evenly and in order, the first and the last among them; all of
    /// them when there are no more than `count`.
    public static func spread(_ total: Int, _ count: Int) -> [Int] {
        guard total > count else { return Array(0..<total) }
        guard count > 1 else { return count == 1 ? [0] : [] }
        return (0..<count).map { Int((Double($0) * Double(total - 1) / Double(count - 1)).rounded()) }
    }
}
