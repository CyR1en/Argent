import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentRoll

private func writePreviewRaw(_ url: URL, width: Int = 48, height: Int = 32, orientation: UInt16 = 1,
                             padding: Int = 0, blue: Bool = false, iso: UInt16 = 100) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: blue ? 0 : 1, green: 0, blue: blue ? 1 : 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let jpeg = NSMutableData()
    let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    func u16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8 & 255)] }
    func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 255) } }
    func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
        u16(tag) + u16(type) + u32(count) + value + [UInt8](repeating: 0, count: 4 - value.count)
    }
    let exif = 8 + 2 + 5 * 12 + 4, text = exif + 2 + 2 * 12 + 4
    let date = Array("2026:10:09 10:00:00\0".utf8), model = Array("ILCE-7M4\0".utf8)
    let start = text + date.count + model.count + padding
    var bytes = [UInt8]([0x49, 0x49]) + u16(42) + u32(8)
    bytes += u16(5)
    bytes += entry(0x0110, 2, model.count, u32(text + date.count))
    bytes += entry(0x0112, 3, 1, u16(Int(orientation)))
    bytes += entry(0x0201, 4, 1, u32(start))
    bytes += entry(0x0202, 4, 1, u32(jpeg.length))
    bytes += entry(0x8769, 4, 1, u32(exif)) + u32(0)
    bytes += u16(2) + entry(0x8827, 3, 1, u16(Int(iso)))
    bytes += entry(0x9003, 2, date.count, u32(text)) + u32(0)
    bytes += date + model + [UInt8](repeating: 0, count: padding) + [UInt8](jpeg as Data)
    try Data(bytes).write(to: url, options: .atomic)
}

private func previewPixel(_ image: CGImage) -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return pixel
}

@Suite struct PreviewSourceRefreshTests {
    @Test func replacingARawRefreshesBothPicturesAndUsesItsNewRangeAndOrientation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("same.ARW")
        try writePreviewRaw(url)
        let opened = Frame(id: 0, url: url, info: try ARWFrameInfo.read(from: url))
        let loader = ThumbnailLoader()
        let first = try #require(await loader.thumbnail(for: opened, maxPixelSize: 96))
        _ = try #require(await loader.fullSize(for: opened, maxPixelSize: 256))
        #expect(first.width == 48 && first.height == 32)
        #expect(previewPixel(first)[0] > 240)

        try writePreviewRaw(url, width: 80, height: 20, orientation: 6, padding: 211, blue: true, iso: 6400)
        #expect(loader.cached(opened, maxPixelSize: 96) == nil)
        #expect(loader.cachedFullSize(opened, maxPixelSize: 256) == nil)
        // Keep passing the original immutable Frame: the loader must obtain the new header.
        for image in [try #require(await loader.thumbnail(for: opened, maxPixelSize: 96)),
                      try #require(await loader.fullSize(for: opened, maxPixelSize: 256))] {
            #expect(image.width == 20 && image.height == 80)
            let pixel = previewPixel(image)
            #expect(pixel[0] < 10 && pixel[2] > 240)
        }
    }

    @Test func aCachedHeaderIsReturnedOnlyForItsOwnSourceVersion() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("same.ARW")
        try writePreviewRaw(url)
        let frame = Frame(id: 7, url: url, info: try ARWFrameInfo.read(from: url))
        let headers = FrameHeaders()
        let before = try #require(headers.current(frame))
        try writePreviewRaw(url, orientation: 8, padding: 128, iso: 3200)
        #expect(headers.current(frame, matching: before.source) == nil)
        let after = try #require(headers.current(frame))
        #expect(after.source != before.source)
        #expect(after.frame.id == 7 && after.frame.info.iso == 3200 && after.frame.info.orientation == .left)
        #expect(after.frame.info == (try ARWFrameInfo.read(from: url)))
    }

    @Test func workQueuedBeforeInvalidationCannotRepopulateEitherCache() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("same.ARW")
        try writePreviewRaw(url)
        let frame = Frame(id: 0, url: url, info: try ARWFrameInfo.read(from: url))
        let loader = ThumbnailLoader()
        loader.queue.isSuspended = true
        defer { loader.queue.isSuspended = false }
        let small = Task { await loader.thumbnail(for: frame, maxPixelSize: 96) }
        let large = Task { await loader.fullSize(for: frame, maxPixelSize: 256) }
        let deadline = ContinuousClock.now + .seconds(2)
        while loader.queue.operationCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(loader.queue.operationCount == 2)
        loader.removeAll()
        loader.queue.isSuspended = false
        let smallImage = await small.value, largeImage = await large.value
        #expect(smallImage != nil && largeImage != nil)
        #expect(loader.cached(frame, maxPixelSize: 96) == nil)
        #expect(loader.cachedFullSize(frame, maxPixelSize: 256) == nil)
    }

    @Test func trimmingFullSizeRejectsPendingPicturesAndKeepsSheetThumbnails() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("same.ARW")
        try writePreviewRaw(url)
        let frame = Frame(id: 0, url: url, info: try ARWFrameInfo.read(from: url))
        let loader = ThumbnailLoader()
        _ = try #require(await loader.thumbnail(for: frame, maxPixelSize: 96))
        loader.queue.isSuspended = true
        defer { loader.queue.isSuspended = false }
        let large = Task { await loader.fullSize(for: frame, maxPixelSize: 256) }
        let deadline = ContinuousClock.now + .seconds(2)
        while loader.queue.operationCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(loader.queue.operationCount == 1)
        loader.removeFullSize()
        loader.queue.isSuspended = false
        #expect(await large.value != nil)
        #expect(loader.cachedFullSize(frame, maxPixelSize: 256) == nil)
        #expect(loader.cached(frame, maxPixelSize: 96) != nil)
    }
}

@Suite struct FilmPreviewInvalidationTests {
    @Test(arguments: [false, true])
    func invalidatedQueuedMeasurementsDoNotRepopulateTheDecodedCache(trimming: Bool) async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("same.ARW")
        try writePreviewRaw(url)
        let frame = Frame(id: 0, url: url, info: try ARWFrameInfo.read(from: url))
        let disk = LinearDiskCache(folder: folder.appendingPathComponent("cache"))
        let digests = SourceDigests(settle: 0)
        let gpu = try GPU()
        let texture = try gpu.texturePool.acquire(width: 12, height: 8)
        let pixels = [Float16](repeating: 0.18, count: 12 * 8 * 4)
        pixels.withUnsafeBytes {
            texture.texture.replace(region: MTLRegionMake2D(0, 0, 12, 8), mipmapLevel: 0,
                                    withBytes: $0.baseAddress!, bytesPerRow: 12 * 8)
        }
        let key = try #require(LinearDiskCache.key(for: url, longSide: FilmPreviews.previewLongSide,
                                                  decoderVersion: DecoderChoice.apple.decoderVersion, lensCorrection: false, digests: digests))
        disk.store(LinearFrame(image: texture, decoderVersion: DecoderChoice.apple.decoderVersion, scale: 0.125), key: key)
        disk.flush()
        let films = try FilmPreviews(stocks: [], diskCache: disk, decoderChoices: DecoderChoices(route: .apple), digests: digests)
        films.decodeQueue.isSuspended = true
        defer { films.decodeQueue.isSuspended = false }
        let task = Task { await films.measurement(frame) }
        let deadline = ContinuousClock.now + .seconds(2)
        while films.decodeQueue.operationCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(films.decodeQueue.operationCount == 1)
        if trimming { films.trimForDevelop() } else { films.removeAll() }
        films.decodeQueue.isSuspended = false
        #expect(await task.value == nil)
        #expect(films.cachedMeasurement(frame) == nil && !films.hasLinearPreview(frame, lens: .default))
        // A request made after invalidation can still reuse the persisted decode.
        #expect(await films.measurement(frame) != nil)
        #expect(films.hasLinearPreview(frame, lens: .default) && films.cachedMeasurement(frame) != nil)
        #expect(films.decodeCount == 0 && films.diskHitCount == 1)
    }
}

@Suite(.rawDecodes, .serialized, .syntheticRaws) struct FilmPreviewSourceRefreshTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: SyntheticRaw.base.path)))
    func measurementOfAReplacementUsesItsCurrentISOEvenWhenTheCallerHasAnOldFrame() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("same.ARW")
        try FileManager.default.copyItem(at: SyntheticRaw.base, to: url)
        let opened = Frame(id: 0, url: url, info: try ARWFrameInfo.read(from: url))
        let oldStamp = try #require(SourceStamp.of(url))
        let replacement = try SyntheticRaw.simulated(iso: 25_600, stops: -3.5)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: replacement, to: url)
        let current = Frame(id: 0, url: url, info: try ARWFrameInfo.read(from: url))
        #expect(current.info.iso != opened.info.iso)
        let reused = try FilmPreviews(stocks: [], decoderChoices: DecoderChoices(route: .apple))
        let measured = try #require(await reused.measurement(opened))
        let fresh = try FilmPreviews(stocks: [], decoderChoices: DecoderChoices(route: .apple))
        let expected = try #require(await fresh.measurement(current))
        #expect(measured.source != oldStamp && measured.source == SourceStamp.of(url))
        #expect(abs(measured.analysis.meanStops - expected.analysis.meanStops) < 0.0001)
        #expect(measured.analysis.grayEstimate == expected.analysis.grayEstimate)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: SyntheticRaw.base.path)), arguments: [false, true])
    func invalidationRejectsTheFrameViewAndItsQueuedMeasurement(trimming: Bool) async throws {
        let frame = Frame(id: 0, url: SyntheticRaw.base, info: try ARWFrameInfo.read(from: SyntheticRaw.base))
        let films = try FilmPreviews(stocks: [], decoderChoices: DecoderChoices(route: .apple))
        films.decodeQueue.isSuspended = true
        defer { films.decodeQueue.isSuspended = false }
        let picture = Task { await films.frameNeutral(frame, lens: .default, pixels: 1200) }
        // A measurement no longer waits for the frame view's decode to scale it: it is the sheet's own
        // decode, queued beside the frame view's (docs/research/auto/sequence-consistency.md, stage 4).
        let measurement = Task { await films.measurement(frame) }
        let deadline = ContinuousClock.now + .seconds(2)
        while films.decodeQueue.operationCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(films.decodeQueue.operationCount == 2)
        if trimming { films.trimForDevelop() } else { films.removeAll() }
        films.decodeQueue.isSuspended = false
        let pictureResult = await picture.value, measurementResult = await measurement.value
        #expect(pictureResult == nil && measurementResult == nil)
        #expect(!films.hasFrameDecode(frame, lens: .default, pixels: 1200) && !films.hasLinearPreview(frame, lens: .default))
        #expect(films.cachedMeasurement(frame) == nil && films.renderedCacheCount == 0 && films.decodeCount == 0)
    }
}
