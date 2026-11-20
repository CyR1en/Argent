import ArgentCore
import CoreGraphics
import Foundation

/// Small raw headers shared by the embedded previews, film measurements and the open roll.
/// A header is read once per file version, and never paired with another version's decode.
public final class FrameHeaders: @unchecked Sendable {
    public static let shared = FrameHeaders()

    public struct Snapshot: Sendable {
        public let frame: Frame
        public let source: SourceStamp
    }

    private final class Entry {
        let info: ARWFrameInfo
        init(_ info: ARWFrameInfo) { self.info = info }
    }
    private let cache = NSCache<NSString, Entry>()

    public init() { cache.countLimit = 4096 }

    /// The header of the raw there now, optionally only if it is still `expected`.
    public func current(_ frame: Frame, matching expected: SourceStamp? = nil) -> Snapshot? {
        guard let source = SourceStamp.of(frame.url), expected == nil || expected == source else { return nil }
        let key = "\(frame.url.path)|\(source.key)" as NSString
        let info: ARWFrameInfo
        if let kept = cache.object(forKey: key) {
            info = kept.info
        } else {
            guard let read = try? ARWFrameInfo.read(from: frame.url), SourceStamp.of(frame.url) == source else { return nil }
            info = read
            cache.setObject(Entry(info), forKey: key)
        }
        guard SourceStamp.of(frame.url) == source else { return nil }
        return Snapshot(frame: Frame(id: frame.id, url: frame.url, info: info), source: source)
    }
}

/// Contact-sheet thumbnails from each frame's embedded preview, decoded on a bounded queue and
/// kept in a cache with a memory limit, and the frame view's first picture from the full-size
/// embedded JPEG.
///
/// The preview is 1616 by 1080 on the a7 IV and decodes at thumbnail size in about 5 ms on one
/// core, under 1 ms per frame across all of them (measured on the M4), so a whole roll's sheet
/// costs well under a second and nothing waits on the raw decoder. The full-size JPEG takes
/// 55 to 67 ms at 1920 to 3072 pixels (measured), so the frame view loads the frames beside
/// the one it shows ahead of time.
public final class ThumbnailLoader: @unchecked Sendable {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Entry>()
    private let large = NSCache<NSString, Entry>()
    let queue = OperationQueue()
    private let lock = NSLock()
    private var thumbnailGeneration = 0
    private var fullSizeGeneration = 0

    /// `costLimit` is in bytes of decoded pixels; 256 MB holds about 370 thumbnails at 512 px.
    /// `largeCostLimit` holds the frame view's pictures, 17 MB each at 2560 by 1707.
    public init(costLimit: Int = 256 << 20, largeCostLimit: Int = 96 << 20) {
        cache.totalCostLimit = costLimit
        large.totalCostLimit = largeCostLimit
        queue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
        queue.qualityOfService = .userInitiated
        queue.name = "Argent thumbnails"
    }

    private func key(_ frame: Frame, source: SourceStamp, _ maxPixelSize: Int) -> String {
        "\(frame.url.path)|\(source.key)|\(maxPixelSize)"
    }

    /// The thumbnail if it is already decoded at this size.
    public func cached(_ frame: Frame, maxPixelSize: Int) -> CGImage? {
        guard let source = SourceStamp.of(frame.url) else { return nil }
        return cache.object(forKey: key(frame, source: source, maxPixelSize) as NSString)?.image
    }

    /// The frame's preview, upright, with its longer side at most `maxPixelSize`; `nil` when
    /// the file has no readable preview.
    public func thumbnail(for frame: Frame, maxPixelSize: Int) async -> CGImage? {
        if let image = cached(frame, maxPixelSize: maxPixelSize) { return image }
        let generation = lock.withLock { thumbnailGeneration }
        // Cancelled with the cell's task, so a fast scroll does not queue every cell it passes.
        return await QueuedWork.run(on: queue) { [self] in
            guard let snapshot = FrameHeaders.shared.current(frame),
                  let range = snapshot.frame.info.preview ?? snapshot.frame.info.fullSizePreview,
                  let image = try? EmbeddedJPEG.image(at: range, in: frame.url, maxPixelSize: maxPixelSize,
                                                      orientation: snapshot.frame.info.orientation),
                  SourceStamp.of(frame.url) == snapshot.source
            else { return nil }
            lock.withLock {
                guard thumbnailGeneration == generation else { return }
                cache.setObject(Entry(image), forKey: key(frame, source: snapshot.source, maxPixelSize) as NSString,
                                cost: image.bytesPerRow * image.height)
            }
            return image
        }
    }

    /// The full-size embedded JPEG if it is already decoded at this size.
    public func cachedFullSize(_ frame: Frame, maxPixelSize: Int) -> CGImage? {
        guard let source = SourceStamp.of(frame.url) else { return nil }
        return large.object(forKey: key(frame, source: source, maxPixelSize) as NSString)?.image
    }

    /// The frame's largest embedded JPEG, the full crop size on the a7 IV, upright, with its
    /// longer side at most `maxPixelSize`; `nil` when the file has none or the task was
    /// cancelled before the decode started.
    public func fullSize(for frame: Frame, maxPixelSize: Int,
                         priority: Operation.QueuePriority = .veryHigh) async -> CGImage? {
        if let image = cachedFullSize(frame, maxPixelSize: maxPixelSize) { return image }
        let generation = lock.withLock { fullSizeGeneration }
        return await QueuedWork.run(on: queue, priority: priority) { [self] in
            if let image = cachedFullSize(frame, maxPixelSize: maxPixelSize) { return image }
            guard let snapshot = FrameHeaders.shared.current(frame),
                  let range = snapshot.frame.info.fullSizePreview ?? snapshot.frame.info.preview,
                  let image = try? EmbeddedJPEG.image(at: range, in: frame.url, maxPixelSize: maxPixelSize,
                                                      orientation: snapshot.frame.info.orientation),
                  SourceStamp.of(frame.url) == snapshot.source
            else { return nil }
            lock.withLock {
                guard fullSizeGeneration == generation else { return }
                large.setObject(Entry(image), forKey: key(frame, source: snapshot.source, maxPixelSize) as NSString,
                                cost: image.bytesPerRow * image.height)
            }
            return image
        }
    }

    /// Frees the frame view's full-size pictures, for a develop.
    public func removeFullSize() {
        lock.withLock {
            fullSizeGeneration += 1
            large.removeAllObjects()
        }
    }

    /// Empties the caches. Queued decodes still finish, so every caller gets an answer.
    public func removeAll() {
        lock.withLock {
            thumbnailGeneration += 1
            fullSizeGeneration += 1
            cache.removeAllObjects()
            large.removeAllObjects()
        }
    }
}
