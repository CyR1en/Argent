import ArgentCore
import Foundation

/// The library's seeds for the previews' renders (the frame view, the sheet and the strip): each loaded from `MaskRasterStore` and
/// checked against its name as a develop's lane loads it (`MaskRasterStore.load`), and the latest kept in memory, since the refiner asks
/// again for each decode a frame is shown from and a PNG takes 4 to 23 ms to read (R6). A seed is named by its pixels, so a kept one
/// never goes stale. One that is missing or damaged throws, and the frame shows no film, as `RollModel.maskSeedIssue` says why.
public final class StoredMaskSeeds: MaskSeedProvider, @unchecked Sendable {
    /// Four person mattes' worth: a frame's three seeds and a neighbour's, about 3 MB a matte.
    public static let defaultMaximumBytes = 12 << 20

    public let store: MaskRasterStore
    private let lock = NSLock()
    private let limit: Int
    /// Least recently used first, by the name each was checked against.
    private var kept: [(id: RasterID, raster: MaskRaster)] = []

    public init(store: MaskRasterStore, maximumBytes: Int = StoredMaskSeeds.defaultMaximumBytes) {
        self.store = store
        self.limit = maximumBytes
    }

    public func seed(for ref: RasterRef) throws -> MaskRaster {
        if let raster = lock.withLock({ () -> MaskRaster? in
            guard let index = kept.lastIndex(where: { $0.id == ref.id && $0.raster.width == ref.width && $0.raster.height == ref.height })
            else { return nil }
            let entry = kept.remove(at: index)
            kept.append(entry)
            return entry.raster
        }) { return raster }
        let raster = try store.load(ref)
        lock.withLock {
            kept.append((ref.id, raster))
            var held = kept.reduce(0) { $0 + $1.raster.plane.count }
            while held > limit, kept.count > 1 { held -= kept.removeFirst().raster.plane.count }
        }
        return raster
    }

    /// The seeds kept in memory, for tests.
    var keptCount: Int { lock.withLock { kept.count } }
}
