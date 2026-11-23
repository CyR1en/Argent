import ArgentCore
import CoreGraphics
import Foundation

/// Complete pixel provenance, independent of edit/storage revisions. DevelopSettings' derived
/// Hashable conformance includes every resolved setting, including the manual curve version and
/// its pinned reference, so adding a render control cannot silently omit it from a cache key.
struct RenderedImageKey: Hashable, Sendable {
    let decode: String
    let stock: Int?
    let stockID: String?
    let settings: DevelopSettings?
    /// The colour space the picture is encoded in. Not part of the slot, as settings are not, so a
    /// picture in a newly chosen space cancels and takes the place of the last one's.
    let space: OutputSpace
    let pixels: Int
    let frameSized: Bool
    let renderVersion: String?
    /// Rendered from the frame view's refined decode, the develop's own decode area-resized
    /// (`FilmPreviews.refineFrame`), rather than the scaled one it replaced. Not part of the slot,
    /// so the refined picture takes the place of the scaled decode's.
    var refined = false
    /// The decode identity before the settings-dependent scene suffix.
    var familyDecode: String? = nil

    static func film(_ decode: String, stock: Int, stockID: String, settings: DevelopSettings, space: OutputSpace,
                     pixels: Int, frameSized: Bool = false, refined: Bool = false, familyDecode: String? = nil) -> Self {
        var settings = settings
        settings.manual = settings.manual.ignoringInactiveLensHue()
        return Self(decode: decode, stock: stock, stockID: stockID, settings: settings, space: space, pixels: pixels,
             frameSized: frameSized, renderVersion: RenderGraph.version(for: settings), refined: refined, familyDecode: familyDecode)
    }

    static func neutral(_ decode: String, space: OutputSpace, pixels: Int, refined: Bool = false, familyDecode: String? = nil) -> Self {
        Self(decode: decode, stock: nil, stockID: nil, settings: nil, space: space, pixels: pixels,
             frameSized: true, renderVersion: nil, refined: refined, familyDecode: familyDecode)
    }

    var isManual: Bool { settings?.manual.adjustments.clearing(.lens).isIdentity == false }
    var family: Family {
        Family(decode: familyDecode ?? decode, stock: stock, stockID: stockID, pixels: pixels, frameSized: frameSized)
    }
    var slot: Slot { Slot(family: family, manual: isManual) }

    struct Family: Hashable, Sendable {
        let decode: String
        let stock: Int?
        let stockID: String?
        let pixels: Int
        let frameSized: Bool
    }

    /// Auto and its latest manual render have separate slots; comparisons must survive a drag.
    struct Slot: Hashable, Sendable {
        let family: Family
        let manual: Bool
    }
}

/// One strict byte budget for every settings-dependent picture and the neutral comparison.
/// The lock protects cost accounting, deterministic LRU order, and request generations together.
final class RenderedImageCache: @unchecked Sendable {
    static let maximumBytes = 256 << 20
    static let maximumMetadataEntries = 512
    let entryLimit: Int
    private let lock = NSLock()
    /// Under `lock`.
    private var limit: Int
    private var images: [RenderedImageKey: Entry] = [:]
    private var requests: [RenderedImageKey.Slot: Request] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private var focusedPrefix: String?

    private struct Entry {
        let image: CGImage
        let bytes: Int
        var used: UInt64
    }

    private final class Request {
        let key: RenderedImageKey
        let generation: UInt64
        var used: UInt64
        weak var operation: Operation?
        init(key: RenderedImageKey, generation: UInt64, used: UInt64) {
            self.key = key
            self.generation = generation
            self.used = used
        }
    }

    struct Ticket: Sendable {
        let slot: RenderedImageKey.Slot
        let generation: UInt64
    }

    init(byteLimit: Int = maximumBytes, entryLimit: Int = maximumMetadataEntries) {
        limit = min(Self.maximumBytes, max(0, byteLimit))
        self.entryLimit = min(Self.maximumMetadataEntries, max(0, entryLimit))
    }

    /// The pictures' byte budget; lowering it lets the least wanted go at once.
    var byteLimit: Int {
        get { lock.withLock { limit } }
        set {
            lock.withLock {
                limit = min(Self.maximumBytes, max(0, newValue))
                trimImages()
            }
        }
    }

    static func budget(filmBytes: Int, frameBytes: Int) -> Int {
        let sum = max(0, filmBytes).addingReportingOverflow(max(0, frameBytes))
        return sum.overflow ? maximumBytes : min(maximumBytes, sum.partialValue)
    }

    var storedBytes: Int { lock.withLock { bytes } }
    var count: Int { lock.withLock { images.count } }
    var metadataCount: Int { lock.withLock { requests.count } }

    func image(for key: RenderedImageKey, ticket: Ticket? = nil) -> CGImage? {
        lock.withLock {
            if let ticket, requests[ticket.slot]?.generation != ticket.generation { return nil }
            guard var entry = images[key] else { return nil }
            entry.used = tick()
            images[key] = entry
            if let request = requests[key.slot] {
                request.used = entry.used
                requests[key.slot] = request
            }
            return entry.image
        }
    }

    /// Called before decoding, so an older request cannot become latest merely by decoding last.
    func beginRequest(for key: RenderedImageKey) -> Ticket {
        lock.withLock {
            if let current = requests[key.slot], current.key == key {
                current.used = tick()
                return Ticket(slot: key.slot, generation: current.generation)
            }
            requests[key.slot]?.operation?.cancel()
            if key.isManual {
                for old in images.keys.filter({ $0.slot == key.slot && $0 != key }) { remove(old) }
            }
            let sequence = tick()
            requests[key.slot] = Request(key: key, generation: sequence, used: sequence)
            trimMetadata()
            return Ticket(slot: key.slot, generation: sequence)
        }
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.withLock { requests[ticket.slot]?.generation == ticket.generation }
    }

    /// Keep at most one queued render per source/stock/size and Auto/manual slot. A superseded
    /// running operation receives cancellation too and drops its result after the GPU finishes.
    func attach(_ operation: Operation, to ticket: Ticket) {
        lock.withLock {
            guard let request = requests[ticket.slot], request.generation == ticket.generation else {
                operation.cancel()
                return
            }
            // Identical callers wait for the existing render and then reuse its cached image.
            // A cancelled first caller leaves no image, so the second can still render normally.
            if let previous = request.operation, previous !== operation, !previous.isFinished {
                if !previous.isExecuting, previous.queuePriority.rawValue < operation.queuePriority.rawValue {
                    previous.queuePriority = operation.queuePriority
                }
                operation.addDependency(previous)
            }
            request.operation = operation
            requests[ticket.slot] = request
        }
    }

    @discardableResult
    func store(_ image: CGImage, for key: RenderedImageKey, ticket: Ticket? = nil) -> Bool {
        lock.withLock {
            if let ticket {
                guard requests[ticket.slot]?.generation == ticket.generation else { return false }
                // A decode can fall back to another decoder after reserving its ticket. The
                // actual decoder's newer demand must still win over the original request.
                if key.slot != ticket.slot, let destination = requests[key.slot], destination.generation > ticket.generation {
                    return false
                }
            }
            let cost = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
            guard !cost.overflow, cost.partialValue <= limit, entryLimit > 0 else { return false }
            if key.frameSized, key.isManual, focusedPrefix != nil, !isFocused(key) { return false }
            // Slider positions and successive live Auto aims replace their own family slot.
            // The other slot remains available for instantaneous Auto comparison.
            for old in images.keys.filter({ $0.slot == key.slot }) { remove(old) }
            images[key] = Entry(image: image, bytes: cost.partialValue,
                                used: tick())
            bytes += cost.partialValue
            trimImages()
            return images[key] != nil
        }
    }

    /// Navigation releases old full-size adjusted pictures, while small sheet/stock-strip
    /// pictures remain ordinary LRU entries. The focused picture and Auto are evicted last.
    func focus(on framePath: String?) {
        lock.withLock {
            focusedPrefix = framePath.map { $0 + "|" }
            for key in images.keys.filter({ key in
                key.isManual && key.frameSized && !isFocused(key)
            }) { remove(key) }
        }
    }

    func removeAll() {
        lock.withLock {
            for request in requests.values { request.operation?.cancel() }
            images.removeAll()
            requests.removeAll()
            bytes = 0
        }
    }

    /// Drops every cached picture whose key matches `predicate` and cancels matching in-flight requests.
    func remove(where predicate: (RenderedImageKey) -> Bool) {
        lock.withLock {
            for key in images.keys.filter(predicate) { remove(key) }
            for (slot, request) in requests where predicate(request.key) {
                request.operation?.cancel()
                requests.removeValue(forKey: slot)
            }
        }
    }

    private func tick() -> UInt64 { clock &+= 1; return clock }
    private func isFocused(_ key: RenderedImageKey) -> Bool {
        focusedPrefix.map { key.decode.hasPrefix($0) } ?? false
    }
    private func remove(_ key: RenderedImageKey) {
        if let old = images.removeValue(forKey: key) { bytes -= old.bytes }
    }
    private func trimImages() {
        while bytes > limit || images.count > entryLimit {
            guard let victim = images.keys.min(by: { lhs, rhs in
                let leftPriority = retentionPriority(lhs), rightPriority = retentionPriority(rhs)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                return images[lhs]!.used < images[rhs]!.used
            }) else { break }
            remove(victim)
        }
    }
    private func retentionPriority(_ key: RenderedImageKey) -> Int {
        guard isFocused(key) else { return 0 }
        return key.frameSized && key.stock != nil ? 2 : 1
    }
    private func trimMetadata() {
        while requests.count > entryLimit {
            guard let victim = requests.min(by: { $0.value.used < $1.value.used })?.key else { break }
            requests.removeValue(forKey: victim)?.operation?.cancel()
        }
    }
}
