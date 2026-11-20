import ArgentCore
import CoreGraphics
import Foundation
import Testing
@testable import ArgentRoll

@Suite struct ManualPreviewCacheTests {
    private func image(width: Int = 4, height: Int = 4, bytesPerRow: Int = 32) throws -> CGImage {
        let data = Data(repeating: 100, count: bytesPerRow * height)
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func key(_ name: String, exposure: Float = 0, frameSized: Bool = false,
                     reference: Float = 0) throws -> RenderedImageKey {
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: exposure),
                                              referenceStops: reference)
        return .film("\(name)|source|apple", stock: 0, stockID: "test-stock",
                     settings: DevelopSettings(manual: manual), pixels: 100, frameSized: frameSized)
    }

    @Test func chargesRowPaddingAndEvictsTheLeastRecentlyUsed() throws {
        let cache = RenderedImageCache(byteLimit: 256)
        let picture = try image()
        let a = try key("a"), b = try key("b"), c = try key("c")
        #expect(cache.store(picture, for: a))
        #expect(cache.store(picture, for: b))
        #expect(cache.storedBytes == 256 && cache.count == 2)
        #expect(cache.image(for: a) != nil) // b becomes the oldest.
        #expect(cache.store(picture, for: c))
        #expect(cache.image(for: b) == nil)
        #expect(cache.image(for: a) != nil && cache.image(for: c) != nil)
        #expect(cache.storedBytes == 256 && cache.count == 2)
    }

    @Test func rejectsAnOversizedImageWithoutViolatingTheBudget() throws {
        let cache = RenderedImageCache(byteLimit: 128)
        #expect(cache.store(try image(), for: try key("a")))
        #expect(!cache.store(try image(height: 5), for: try key("b")))
        #expect(cache.storedBytes == 128 && cache.count == 1)
        cache.removeAll()
        #expect(cache.storedBytes == 0 && cache.count == 0 && cache.metadataCount == 0)
    }

    @Test func retainsAutoAndOnlyTheLatestManualVariant() throws {
        let cache = RenderedImageCache(byteLimit: 1024)
        let picture = try image()
        let auto = try key("frame"), first = try key("frame", exposure: 1)
        let latest = try key("frame", exposure: 2)
        #expect(cache.store(picture, for: auto))
        let oldRequest = cache.beginRequest(for: first)
        #expect(cache.store(picture, for: first, ticket: oldRequest))
        let newRequest = cache.beginRequest(for: latest)
        #expect(!cache.isCurrent(oldRequest) && cache.isCurrent(newRequest))
        #expect(cache.store(picture, for: latest, ticket: newRequest))
        #expect(!cache.store(picture, for: first, ticket: oldRequest))
        #expect(cache.image(for: first) == nil)
        #expect(cache.image(for: auto) != nil && cache.image(for: latest) != nil)
        #expect(cache.count == 2 && cache.storedBytes == 256)
    }

    @Test func lensAutoAndManualRequestsKeepSeparateSlots() throws {
        let lens = try LensSettings(arguments: "distortion=off")
        let automatic = try ManualAdjustments(lens: lens)
        let edited = try ManualAdjustments(exposureEV: 0.5, lens: lens)
        func key(_ adjustments: ManualAdjustments) throws -> RenderedImageKey {
            .film("frame|source|apple", stock: 0, stockID: "test-stock",
                  settings: DevelopSettings(manual: try ManualRenderSettings(adjustments: adjustments, referenceStops: 0)),
                  pixels: 100, frameSized: true)
        }
        let auto = try key(automatic), film = try key(edited)
        #expect(auto != film && auto.slot != film.slot)
        let cache = RenderedImageCache()
        let filmTicket = cache.beginRequest(for: film), filmOperation = BlockOperation()
        cache.attach(filmOperation, to: filmTicket)
        let autoTicket = cache.beginRequest(for: auto), autoOperation = BlockOperation()
        cache.attach(autoOperation, to: autoTicket)
        #expect(!filmOperation.isCancelled && cache.isCurrent(filmTicket))
        _ = cache.beginRequest(for: film)
        #expect(!autoOperation.isCancelled && cache.isCurrent(autoTicket))
        let picture = try image()
        #expect(cache.store(picture, for: film, ticket: filmTicket))
        #expect(cache.store(picture, for: auto, ticket: autoTicket))
        #expect(cache.image(for: film) != nil && cache.image(for: auto) != nil)
        let defaultAuto = try key(.identity)
        #expect(defaultAuto != auto && defaultAuto.slot == auto.slot)
    }

    @Test func aLensOnlyFilmServesAsItsOwnAutoPicture() throws {
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(lens: LensSettings(arguments: "distortion-amount=150")),
                                              referenceStops: 0)
        let film = RenderedImageKey.film("frame|source|apple", stock: 0, stockID: "test-stock",
                                         settings: DevelopSettings(manual: manual), pixels: 100, frameSized: true)
        let auto = RenderedImageKey.film(film.decode, stock: 0, stockID: "test-stock",
                                         settings: DevelopSettings(manual: manual), pixels: 100, frameSized: true)
        #expect(film == auto && !film.isManual)
        let cache = RenderedImageCache(), operation = BlockOperation()
        let ticket = cache.beginRequest(for: film)
        cache.attach(operation, to: ticket)
        #expect(cache.store(try image(), for: film, ticket: ticket))
        let automatic = cache.beginRequest(for: auto)
        #expect(automatic.generation == ticket.generation && !operation.isCancelled)
        #expect(cache.image(for: auto, ticket: automatic) != nil && cache.count == 1)
    }

    @Test func supersededPendingRenderIsCancelledButDuplicateSettingsShareGeneration() throws {
        let cache = RenderedImageCache()
        let first = try key("frame", exposure: 1)
        let ticket = cache.beginRequest(for: first)
        let operation = BlockOperation()
        cache.attach(operation, to: ticket)
        let duplicate = cache.beginRequest(for: first)
        #expect(duplicate.generation == ticket.generation && !operation.isCancelled)
        _ = cache.beginRequest(for: try key("frame", exposure: 2))
        #expect(operation.isCancelled && !cache.isCurrent(ticket))
        cache.removeAll()
        #expect(!cache.isCurrent(duplicate))
    }

    @Test func returningToCachedAutoCancelsAnInFlightDifferentAutoAim() throws {
        let cache = RenderedImageCache()
        let picture = try image()
        let selected = try key("frame", frameSized: true)
        var changedSettings = selected.settings!
        changedSettings.printExposure = 0.5
        let competing = RenderedImageKey.film(selected.decode, stock: 0, stockID: "test-stock",
                                              settings: changedSettings, pixels: 100, frameSized: true)
        let initial = cache.beginRequest(for: selected)
        cache.store(picture, for: selected, ticket: initial)
        let pending = cache.beginRequest(for: competing)
        let operation = BlockOperation()
        cache.attach(operation, to: pending)
        // Selecting the cached aim must still create demand before taking the cached image.
        let selectedAgain = cache.beginRequest(for: selected)
        #expect(cache.image(for: selected, ticket: selectedAgain) != nil)
        #expect(operation.isCancelled && !cache.isCurrent(pending))
        #expect(!cache.store(picture, for: competing, ticket: pending))
        #expect(cache.image(for: selected) != nil && cache.image(for: competing) == nil)
        #expect(cache.image(for: selected, ticket: initial) == nil)
    }

    @Test func identicalQueuedRequestsReuseOneFinishedRender() throws {
        let cache = RenderedImageCache()
        let picture = try image()
        let item = try key("frame", frameSized: true)
        let ticket = cache.beginRequest(for: item)
        let renders = ManualPreviewRenderCount()
        let first = BlockOperation {
            guard cache.image(for: item, ticket: ticket) == nil else { return }
            renders.increment()
            cache.store(picture, for: item, ticket: ticket)
        }
        let duplicate = BlockOperation {
            guard cache.image(for: item, ticket: ticket) == nil else { return }
            renders.increment()
            cache.store(picture, for: item, ticket: ticket)
        }
        cache.attach(first, to: ticket)
        cache.attach(duplicate, to: ticket)
        #expect(duplicate.dependencies.contains { $0 === first })
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        // The second operation is enqueued first to exercise dependency ordering.
        queue.addOperations([duplicate, first], waitUntilFinished: true)
        #expect(renders.value == 1 && cache.count == 1)
    }

    @Test func aFallbackRenderCannotReplaceANewerRequestForItsActualDecoder() throws {
        let cache = RenderedImageCache()
        let picture = try image()
        let settings = DevelopSettings()
        let requested = RenderedImageKey.film("frame|source|in-house", stock: 0, stockID: "test-stock",
                                              settings: settings, pixels: 100, frameSized: true)
        let fallback = RenderedImageKey.film("frame|source|apple", stock: 0, stockID: "test-stock",
                                             settings: settings, pixels: 100, frameSized: true)
        let original = cache.beginRequest(for: requested)
        // Fallback remains cacheable when the actual decoder has no newer demand.
        #expect(cache.store(picture, for: fallback, ticket: original))
        var latestSettings = settings
        latestSettings.printExposure = 0.5
        let latest = RenderedImageKey.film(fallback.decode, stock: 0, stockID: "test-stock",
                                           settings: latestSettings, pixels: 100, frameSized: true)
        let newer = cache.beginRequest(for: latest)
        #expect(cache.store(picture, for: latest, ticket: newer))
        #expect(cache.isCurrent(original)) // The originating decoder alone cannot detect this race.
        #expect(!cache.store(picture, for: fallback, ticket: original))
        #expect(cache.image(for: latest) != nil && cache.image(for: fallback) == nil)
        #expect(cache.count == 1 && cache.storedBytes == picture.bytesPerRow * picture.height)
    }

    @Test func keepsImageAndRequestMetadataBounded() throws {
        let cache = RenderedImageCache(byteLimit: 1 << 20)
        let picture = try image(width: 1, height: 1, bytesPerRow: 4)
        let first = cache.beginRequest(for: try key("frame-0"))
        for index in 0..<700 {
            let item = try key("frame-\(index)")
            let ticket = cache.beginRequest(for: item)
            cache.store(picture, for: item, ticket: ticket)
        }
        #expect(cache.metadataCount == 512 && cache.count == 512)
        #expect(!cache.isCurrent(first))
        #expect(cache.storedBytes == 512 * 4)
    }

    @Test func navigationEvictsOldFullSizeManualImagesAndPrefersTheFocusedBaseline() throws {
        let cache = RenderedImageCache(byteLimit: 256)
        let picture = try image()
        let baseline = try key("focused", frameSized: true)
        let manual = try key("focused", exposure: 1, frameSized: true)
        cache.focus(on: "focused")
        cache.store(picture, for: baseline)
        cache.store(picture, for: manual)
        #expect(!cache.store(picture, for: try key("other")))
        #expect(cache.image(for: baseline) != nil && cache.image(for: manual) != nil)
        cache.focus(on: "other")
        #expect(cache.image(for: manual) == nil && cache.image(for: baseline) != nil)
        #expect(!cache.store(picture, for: manual)) // A late prefetch must not retain it again.
        #expect(cache.storedBytes == 128)
    }

    @Test func completeFingerprintSeparatesManualReferenceDecoderAndDecodeSize() throws {
        let auto = try key("frame")
        let adjusted = try key("frame", exposure: 1)
        let otherReference = try key("frame", exposure: 1, reference: 0.5)
        let frameSized = try key("frame", frameSized: true)
        let neutral = RenderedImageKey.neutral("frame|source|apple", pixels: 100)
        #expect(Set([auto, adjusted, otherReference, frameSized, neutral]).count == 5)
        #expect(auto.renderVersion == RenderGraph.version)
        #expect(adjusted.renderVersion == RenderGraph.version(for: adjusted.settings!))
        var settings = adjusted.settings!
        settings.grainSeed += 1
        let otherSeed = RenderedImageKey.film(adjusted.decode, stock: 0, stockID: "test-stock",
                                             settings: settings, pixels: 100)
        #expect(otherSeed != adjusted)
        let otherDecode = RenderedImageKey.film("frame|source|inhouse", stock: 0, stockID: "test-stock",
                                               settings: adjusted.settings!, pixels: 100)
        #expect(otherDecode != adjusted)
        #expect(neutral.settings == nil && neutral.renderVersion == nil)
    }

    @Test func budgetsHonorTheGlobalCapAndSmallerCallerLimits() {
        #expect(RenderedImageCache.budget(filmBytes: 192 << 20, frameBytes: 128 << 20) == 256 << 20)
        #expect(RenderedImageCache.budget(filmBytes: 20, frameBytes: 30) == 50)
        #expect(RenderedImageCache.budget(filmBytes: -5, frameBytes: 10) == 10)
        #expect(RenderedImageCache.budget(filmBytes: Int.max, frameBytes: Int.max) == 256 << 20)
        #expect(RenderedImageCache(byteLimit: Int.max).byteLimit == 256 << 20)
    }

    /// A develop lowers the budget so the previews keep what is on screen: the pictures not focused go
    /// at once, the focused frame's last, and the budget comes back after.
    @Test func aLoweredBudgetLetsTheUnfocusedPicturesGoAtOnce() throws {
        let cache = RenderedImageCache(byteLimit: 512)
        let picture = try image()
        let focused = try key("focused", frameSized: true), other = try key("other", frameSized: true)
        let thumbnail = try key("thumbnail")
        cache.focus(on: "focused")
        #expect(cache.store(picture, for: focused))
        #expect(cache.store(picture, for: other))
        #expect(cache.store(picture, for: thumbnail))
        cache.byteLimit = 128
        #expect(cache.byteLimit == 128 && cache.storedBytes == 128)
        #expect(cache.image(for: focused) != nil && cache.image(for: other) == nil && cache.image(for: thumbnail) == nil)
        cache.byteLimit = 512
        #expect(cache.store(picture, for: other))
        #expect(cache.storedBytes == 256)
    }
}

private final class ManualPreviewRenderCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
