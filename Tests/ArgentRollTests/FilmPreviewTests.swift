import ArgentCore
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ArgentRoll

/// Writes a stock folder with identity LUTs, enough for the loader and the render graph.
func writeToyStock(id: String, in directory: URL, size: Int = 2) throws {
    let folder = directory.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try LUT3D.identity(size: size).binaryData().write(to: folder.appendingPathComponent("negative.lut3d"))
    try LUT3D.identity(size: size).binaryData().write(to: folder.appendingPathComponent("print.lut3d"))
    let manifest: [String: Any] = [
        "schema": 2, "id": id, "displayName": id, "status": "synthetic", "boxSpeed": 400, "densityRange": 2.5,
        "negative": ["file": "negative.cube", "binary": "negative.lut3d", "size": size,
                     "logEncoding": ["stopsBelowMidGray": 8, "stopsAboveMidGray": 5, "midGray": 0.18]],
        "print": ["file": "print.cube", "binary": "print.lut3d", "size": size, "exposurePerUnit": [0.8, 0.8, 0.8]],
    ]
    try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent(Stock.manifestName))
}

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-stocks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct StockLibraryTests {
    @Test func loadsInLibraryOrderThenByIdAndReportsBrokenFolders() throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in ["kodak-ektar-100", "zz-test", "kodak-portra-400", "kodak-gold-200"] {
            try writeToyStock(id: id, in: directory)
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("broken"), withIntermediateDirectories: true)
        let result = StockLibrary.load(from: directory)
        #expect(result.stocks.map(\.id) == ["kodak-portra-400", "kodak-ektar-100", "kodak-gold-200", "zz-test"])
        #expect(result.failures.map(\.folder) == ["broken"])
        #expect(StockLibrary.load(from: directory.appendingPathComponent("missing")).stocks.isEmpty)
    }
}

@Suite struct FrameDecodeSideTests {
    /// The frame view decodes at its picture's own pixels, so the film needs no resize after it.
    @Test func isThePicturesOwnSize() {
        #expect(FilmPreviews.frameDecodeSide(forPixels: 0) == 1)
        for pixels in [1, 513, 900, 2190, 2600, 3500, 5120] {
            #expect(FilmPreviews.frameDecodeSide(forPixels: pixels) == pixels)
        }
    }
}

@Suite struct QueuedWorkTests {
    @Test func cancellingBeforeTheWorkStartsSkipsItAndStillAnswers() async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let gate = DispatchSemaphore(value: 0)
        let ran = Counter()
        // The first job holds the only slot until the gate opens.
        let first = Task { await QueuedWork.run(on: queue) { () -> Int? in gate.wait(); ran.add(); return 1 } }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { await QueuedWork.run(on: queue) { () -> Int? in ran.add(); return 2 } }
        try await Task.sleep(for: .milliseconds(50))
        second.cancel()
        gate.signal()
        #expect(await first.value == 1)
        #expect(await second.value == nil)
        #expect(ran.value == 1)
    }

    /// Work given up on once it has begun is told so, and stops part way.
    @Test func cancellingWhileTheWorkRunsTellsItToStop() async throws {
        let queue = OperationQueue()
        let began = Counter()
        let task = Task {
            await QueuedWork.runStoppable(on: queue) { stopped -> Int? in
                began.add()
                for step in 0..<10_000 {
                    if stopped() { return step }
                    usleep(1000)
                }
                return nil
            }
        }
        while began.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let stoppedAt = try #require(await task.value)
        #expect(stoppedAt < 5_000)
    }
}

/// The sheet's decode of a frame no longer wanted stops reading its raw for the disk cache's key
/// between megabytes, and decodes nothing.
@Suite struct FilmPreviewStopTests {
    @Test func aSheetDecodeGivenUpOnStopsReadingItsRaw() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "kodak-portra-400", in: directory)
        // A raw too long to read whole in the time the test waits: 4 GB, sparse, so it costs no disk.
        let raw = directory.appendingPathComponent("DSC00001.ARW")
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let handle = try FileHandle(forWritingTo: raw)
        try handle.truncate(atOffset: 4 << 30)
        try handle.close()
        let digests = SourceDigests(settle: 0)
        let films = try FilmPreviews(stocks: StockLibrary.load(from: directory).stocks,
                                     diskCache: LinearDiskCache(folder: directory.appendingPathComponent("cache")), digests: digests)
        let frame = Frame(id: 0, url: raw, info: ARWFrameInfo())
        let clock = ContinuousClock()
        let task = Task { await films.measurement(frame) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = clock.now
        task.cancel()
        #expect(await task.value == nil)
        let stopping = clock.now - cancelled
        print("MEASURE sheet decode stopped \(stopping.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))) after it was given up on")
        #expect(stopping < .milliseconds(500))
        #expect(digests.readCount == 0 && digests.known(raw) == nil && films.decodeCount == 0)
    }

    @Test(arguments: [false, true])
    func invalidatingASheetDecodeStopsItsPendingContentRead(trimming: Bool) async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("DSC00001.ARW")
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let handle = try FileHandle(forWritingTo: raw)
        try handle.truncate(atOffset: 4 << 30)
        try handle.close()
        let digests = SourceDigests(settle: 0)
        let films = try FilmPreviews(stocks: [], diskCache: LinearDiskCache(folder: directory.appendingPathComponent("cache")),
                                     decoderChoices: DecoderChoices(route: .apple), digests: digests)
        let frame = Frame(id: 0, url: raw, info: ARWFrameInfo())
        let task = Task { await films.measurement(frame) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !films.decodeQueue.operations.contains(where: { $0.isExecuting }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(films.decodeQueue.operations.contains(where: { $0.isExecuting }))
        let invalidated = ContinuousClock.now
        if trimming { films.trimForDevelop() } else { films.removeAll() }
        #expect(await task.value == nil)
        #expect(ContinuousClock.now - invalidated < .milliseconds(500))
        #expect(digests.readCount == 0 && digests.known(raw) == nil && films.decodeCount == 0)
        #expect(films.cachedMeasurement(frame) == nil && !films.hasLinearPreview(frame, lens: .default))
    }
}

/// What measuring a frame comes to: a raw that cannot be decoded, or is gone, is a failure of that
/// version, told apart from a request given up on.
@Suite struct MeasurementOutcomeTests {
    private static func header(_ url: URL) throws {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8 & 255)] }
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 255) } }
        var bytes = [UInt8]([0x49, 0x49]) + u16(42) + u32(8)
        bytes += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        bytes += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(400) + u16(0) + u32(0)
        try Data(bytes).write(to: url)
    }

    @Test func anUndecodableOrMissingRawIsAFailureAndAGivenUpRequestIsNot() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let films = try FilmPreviews(stocks: [], decoderChoices: DecoderChoices(route: .apple))
        // A header and nothing to decode.
        let headerOnly = folder.appendingPathComponent("DSC1.ARW")
        try Self.header(headerOnly)
        let decodable = Frame(id: 0, url: headerOnly, info: try ARWFrameInfo.read(from: headerOnly))
        #expect(await films.measure(decodable) == .failed(SourceStamp.of(headerOnly)))
        #expect(await films.measurement(decodable) == nil && films.cachedMeasurement(decodable) == nil)
        // Bytes with no header at all.
        let garbage = folder.appendingPathComponent("DSC2.ARW")
        try Data("not a raw".utf8).write(to: garbage)
        #expect(await films.measure(Frame(id: 1, url: garbage, info: ARWFrameInfo())) == .failed(SourceStamp.of(garbage)))
        // No file.
        let gone = Frame(id: 2, url: folder.appendingPathComponent("DSC3.ARW"), info: ARWFrameInfo())
        #expect(await films.measure(gone) == .failed(nil))
        // Given up on before it began, and let go by a roll reset while queued.
        let cancelled = Task { () -> FilmPreviews.MeasurementOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await films.measure(decodable)
        }
        #expect(await cancelled.value == .stopped)
        films.decodeQueue.isSuspended = true
        let queued = Task { await films.measure(decodable) }
        let deadline = ContinuousClock.now + .seconds(2)
        while films.decodeQueue.operationCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        films.removeAll()
        films.decodeQueue.isSuspended = false
        #expect(await queued.value == .stopped)
    }
}

@Suite struct LinearDiskCacheCorruptionTests {
    @Test func overflowingPixelDimensionsAreACacheMiss() throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gpu = try GPU()
        let cache = LinearDiskCache(folder: directory)
        for (width, height) in [(Int.max, 1), (Int.max / 8, 2), (Int.min, 1)] {
            let header = try JSONSerialization.data(withJSONObject: ["width": width, "height": height,
                                                                      "scale": 0.125, "decoderVersion": "test"])
            var data = Data("ARGENT-LINEAR-1\n".utf8)
            withUnsafeBytes(of: UInt32(header.count).littleEndian) { data.append(contentsOf: $0) }
            data.append(header)
            data.append(Data(count: 8))
            try data.write(to: directory.appendingPathComponent("damaged.linear"), options: .atomic)
            #expect(cache.load("damaged", pool: gpu.texturePool) == nil)
        }
    }

    /// An entry written under a key from before version 2, when RAW 9 decodes made at once could keep a
    /// black or garbled tile, is never read for the same raw, decoder and size.
    @Test func anEntryFromBeforeVersion2IsNeverRead() throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gpu = try GPU()
        let cache = LinearDiskCache(folder: directory)
        let sha256 = String(repeating: "ab", count: 32)
        var hash = SHA256()
        hash.update(data: Data("\(sha256)|\(DecodePins.currentVersion)|9|960|\(ProcessInfo.processInfo.operatingSystemVersionString)".utf8))
        let before = hash.finalize().map { String(format: "%02x", $0) }.joined()
        cache.store(LinearFrame(image: try gpu.texturePool.acquire(width: 4, height: 4), decoderVersion: "9", scale: 0.137), key: before)
        cache.flush()
        #expect(cache.load(before, pool: gpu.texturePool) != nil)
        let now = LinearDiskCache.key(sha256: sha256, longSide: 960, decoderVersion: "9")
        #expect(now != before && cache.load(now, pool: gpu.texturePool) == nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Runs only where the CC0 samples are present. One test at a time: the frame view's stock switch
/// is held to the spec's 100 ms by the wall clock, which the suite's other decodes would share.
@Suite(.rawDecodes, .serialized) struct FilmPreviewSampleTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    private static var hasSamples: Bool {
        FileManager.default.fileExists(atPath: samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW").path)
    }

    /// Previews on `route`, the app's own unless a test names another.
    private func previews(route: DecoderRoute = .raw9) throws -> (FilmPreviews, URL) {
        let directory = try temporaryFolder()
        try writeToyStock(id: "kodak-portra-400", in: directory)
        try writeToyStock(id: "kodak-portra-160", in: directory)
        return (try FilmPreviews(stocks: StockLibrary.load(from: directory).stocks, decoderChoices: DecoderChoices(route: route)), directory)
    }

    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func rendersAFrameAndSwitchesStocksWithoutDecodingAgain() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let roll = await RollScanner.scan(Self.samples)
        let frame = try #require(roll.frames.first { $0.name.contains("Large") })

        let first = try #require(await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
        #expect(max(first.width, first.height) == 336)
        #expect(films.decodeCount == 1 && films.hasLinearPreview(frame, lens: .default))

        let clock = ContinuousClock()
        let start = clock.now
        let switched = try #require(await films.film(frame, stock: 1, settings: DevelopSettings(), maxPixelSize: 336))
        let switchTime = clock.now - start
        #expect(switched.width == first.width)
        #expect(films.decodeCount == 1)
        print("MEASURE stock switch on a decoded frame: \(switchTime.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        #expect(switchTime < .milliseconds(100))
        #expect(films.cachedFilm(frame, stock: 1, settings: DevelopSettings(), maxPixelSize: 336) != nil)
        #expect(await films.film(frame, stock: 7, settings: DevelopSettings(), maxPixelSize: 336) == nil)
    }

    /// A roll opened again renders from the disk cache: the same pixels, no decode.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func aRollOpenedAgainRendersFromTheDiskCache() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "kodak-portra-400", in: directory)
        let stocks = StockLibrary.load(from: directory).stocks
        let disk = LinearDiskCache(folder: directory.appendingPathComponent("linear"))
        let roll = await RollScanner.scan(Self.samples)
        try #require(roll.frames.count == 5)
        let clock = ContinuousClock()

        func renderAll(_ films: FilmPreviews) async throws -> ([Data], Duration) {
            let start = clock.now
            var pictures: [Data] = []
            for frame in roll.frames {
                let image = try #require(await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
                pictures.append(try #require(image.dataProvider?.data) as Data)
            }
            return (pictures, clock.now - start)
        }
        let first = try FilmPreviews(stocks: stocks, diskCache: disk)
        let (decoded, decodeTime) = try await renderAll(first)
        #expect(first.decodeCount == roll.frames.count && first.diskHitCount == 0)
        disk.flush()

        let again = try FilmPreviews(stocks: stocks, diskCache: disk)
        let (kept, keptTime) = try await renderAll(again)
        #expect(again.decodeCount == 0 && again.diskHitCount == roll.frames.count)
        #expect(kept == decoded)
        print("MEASURE \(roll.frames.count) sheet renders one at a time: decoding \(decodeTime), from the disk cache \(keptTime)")
    }

    /// The frame view and the stock strip ask for the same frame at once, as they do when a
    /// frame opens: one decode serves both, the strip's picture scaled down from the frame
    /// view's, and the neutral raw comes from it too.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func theFrameViewAndTheStripShareOneDecode() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let roll = await RollScanner.scan(Self.samples)
        let frame = try #require(roll.frames.first { $0.name.contains("Large") })
        let clock = ContinuousClock()
        let start = clock.now
        // The strip asks first here; the order must not matter.
        async let strip = films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 208, priority: .high,
                                     frameViewSide: FilmPreviews.frameDecodeSide(forPixels: 2190))
        async let large = films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 2190)
        async let neutral = films.frameNeutral(frame, lens: .default, pixels: 2190)
        let (frameFilm, stripFilm, neutralRaw) = await (large, strip, neutral)
        let firstFilm = clock.now - start
        #expect(films.decodeCount == 1)
        #expect(try max(#require(frameFilm).width, #require(frameFilm).height) == 2190)
        #expect(try max(#require(stripFilm).width, #require(stripFilm).height) == 208)
        #expect(try #require(neutralRaw).width == frameFilm?.width)
        #expect(films.hasLinearPreview(frame, lens: .default) && films.hasFrameDecode(frame, lens: .default, pixels: 2190))
        // Any other window size, smaller or larger, needs a decode of its own size.
        #expect(!films.hasFrameDecode(frame, lens: .default, pixels: 2180) && !films.hasFrameDecode(frame, lens: .default, pixels: 2200))

        let switchStart = clock.now
        let switched = await films.frameFilm(frame, stock: 1, settings: DevelopSettings(labBalance: SIMD3(0.1, 0, -0.1)),
                                             pixels: 2190)
        let switchTime = clock.now - switchStart
        #expect(switched != nil && films.decodeCount == 1)
        print("MEASURE frame view at 2190 px: first film \(firstFilm.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))), stock switch \(switchTime.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        // The spec's target for the frame view at display resolution after a change.
        #expect(switchTime < .milliseconds(100))

        // A window resize decodes again at the new size, and the film and the neutral raw come
        // out at exactly its pixels, from that one decode.
        async let resizedFilm = films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 1801)
        async let resizedNeutral = films.frameNeutral(frame, lens: .default, pixels: 1801)
        let (smaller, smallerNeutral) = await (resizedFilm, resizedNeutral)
        #expect(films.decodeCount == 2 && films.hasFrameDecode(frame, lens: .default, pixels: 1801) && !films.hasFrameDecode(frame, lens: .default, pixels: 2190))
        #expect(try #require(smaller).width == 1801 && smaller?.height == 1201)
        #expect(try #require(smallerNeutral).width == 1801 && smallerNeutral?.height == 1201)
    }

    /// Lossless S drops a few pixels at the right and bottom (`RawMode.trim`); the frame view's
    /// decode makes them up, so its picture is still exactly the window's pixels.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func aLosslessSmallFrameFillsTheFrameView() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let roll = await RollScanner.scan(Self.samples)
        let frame = try #require(roll.frames.first { $0.name.contains("Small") })
        for pixels in [900, 2190] {
            let film = try #require(await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: pixels))
            let neutral = try #require(await films.frameNeutral(frame, lens: .default, pixels: pixels))
            #expect(film.width == pixels && abs(film.height - pixels * 2 / 3) <= 1, "\(pixels): \(film.width) by \(film.height)")
            #expect(neutral.width == film.width && neutral.height == film.height)
        }
        #expect(films.decodeCount == 2)
    }

    /// Each output colour space's pictures come from the decode the frame already has, are in that
    /// space, and are never served for another.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func everyOutputSpaceRendersFromTheOneDecode() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let roll = await RollScanner.scan(Self.samples)
        let frame = try #require(roll.frames.first { $0.name.contains("Small") })
        let settings = DevelopSettings()
        for space in OutputSpace.allCases {
            let film = try #require(await films.frameFilm(frame, stock: 0, settings: settings, space: space, pixels: 900))
            let neutral = try #require(await films.frameNeutral(frame, lens: .default, space: space, pixels: 900))
            #expect(film.colorSpace?.name == space.colorSpace.name)
            #expect(neutral.colorSpace?.name == space.colorSpace.name)
            #expect(films.cachedFrameFilm(frame, stock: 0, settings: settings, space: space, pixels: 900) === film)
            #expect(films.cachedFrameNeutral(frame, lens: .default, space: space, pixels: 900) === neutral)
            for other in OutputSpace.allCases where other != space {
                #expect(films.cachedFrameFilm(frame, stock: 0, settings: settings, space: other, pixels: 900) == nil)
                #expect(films.cachedFrameNeutral(frame, lens: .default, space: other, pixels: 900) == nil)
            }
        }
        #expect(films.decodeCount == 1)
        let sheet = try #require(await films.film(frame, stock: 0, settings: settings, space: .sRGB, maxPixelSize: 300))
        #expect(sheet.colorSpace?.name == OutputSpace.sRGB.colorSpace.name)
    }

    /// A frame view smaller than the sheet's 960-pixel decode does not hand the sheet its
    /// decode, which would make the sheet's picture and its measurement smaller.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func aFrameViewSmallerThanTheSheetKeepsItsDecodeToItself() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let roll = await RollScanner.scan(Self.samples)
        let frame = try #require(roll.frames.first { $0.name.contains("Large") })
        let pixels = 900
        async let strip = films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 208, priority: .high,
                                     frameViewSide: FilmPreviews.frameDecodeSide(forPixels: pixels))
        async let large = films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: pixels)
        let (stripFilm, frameFilm) = await (strip, large)
        #expect(stripFilm != nil && frameFilm?.width == pixels)
        #expect(films.decodeCount == 2 && films.cachedMeasurement(frame) != nil)
        let sheet = try #require(await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 960))
        #expect(sheet.width == FilmPreviews.previewLongSide && films.decodeCount == 2)
    }

    /// A frame is measured from the sheet's own decode whichever view asks first: with the frame
    /// view's decode up and the strip's picture scaled from it, its measurement and descriptor are
    /// a fresh sheet decode's, bit for bit (docs/research/auto/sequence-consistency.md, stage 4). A
    /// measurement a recipe gave stays, and its descriptor is described from the sheet's decode.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func aMeasurementIsTheSheetsWhicheverViewAsksFirst() async throws {
        let roll = await RollScanner.scan(Self.samples)
        let frame = try #require(roll.frames.first { $0.name.contains("Large") })
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 2190)
        _ = await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 208,
                             frameViewSide: FilmPreviews.frameDecodeSide(forPixels: 2190))
        #expect(films.decodeCount == 1 && films.hasLinearPreview(frame, lens: .default) && films.cachedMeasurement(frame) == nil)
        guard case .measured(let measured, let descriptor) = await films.measure(frame) else {
            Issue.record("the sample measures")
            return
        }
        #expect(films.decodeCount == 2 && descriptor != nil)

        let (sheet, sheetDirectory) = try previews()
        defer { try? FileManager.default.removeItem(at: sheetDirectory) }
        let direct = await sheet.measure(frame)
        #expect(direct == .measured(measured, descriptor))

        let (seeded, seededDirectory) = try previews()
        defer { try? FileManager.default.removeItem(at: seededDirectory) }
        let recipe = ExposureAnalysis(meanStops: 0.5, validWeight: 1)
        seeded.seedAnalysis(recipe, for: frame, source: measured.source)
        #expect(await seeded.measure(frame) == .measured(FrameMeasurement(analysis: recipe, source: measured.source), nil))
        #expect(await seeded.descriptor(frame) == descriptor)
        #expect(seeded.cachedMeasurement(frame)?.analysis == recipe && seeded.decodeCount == 1)
    }

    /// The frame view keeps the frame on screen, the one ahead and the one just left, and
    /// drops the one used longest ago.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func theFrameViewKeepsItsLastThreeDecodes() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = Array(await RollScanner.scan(Self.samples).frames.prefix(4))
        try #require(frames.count == 4)
        for frame in frames { #expect(await films.frameNeutral(frame, lens: .default, pixels: 600) != nil) }
        #expect(!films.hasFrameDecode(frames[0], lens: .default, pixels: 600))
        // Looking at frames[1] makes it the most recently used, so frames[2] goes next.
        #expect(films.hasFrameDecode(frames[1], lens: .default, pixels: 600))
        // frames[0] again, at a new size.
        #expect(await films.frameNeutral(frames[0], lens: .default, pixels: 610) != nil)
        #expect(!films.hasFrameDecode(frames[2], lens: .default, pixels: 600))
        #expect(films.hasFrameDecode(frames[1], lens: .default, pixels: 600) && films.hasFrameDecode(frames[3], lens: .default, pixels: 600))
        #expect(films.decodeCount == 5)
    }

    /// Once its film is up, an Apple frame's scaled decode gives way to the develop's own decode,
    /// full size in the develop's tiles, area-resized onto the same pixels, and the film, the
    /// neutral raw and the cache follow it (docs/manual-development-validation.md, "Apple-decoded
    /// previews, 2026-10-16"). The compressed frame is RAW 9's, refined by RAW 9; lossless S is RAW 8's
    /// and comes from its full decode with the develop's trim. The tiles are resized as they come, so
    /// a pixel two tiles share can be a step of a half float off.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples), arguments: [("Raw-Compressed", 1201, "9"), ("Small", 1690, "8")])
    func refiningAnAppleFrameShowsTheDevelopsDecodeResized(_ mode: String, pixels: Int, decoder: String) async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains(mode) })
        let fast = try #require(await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: pixels))
        let fastNeutral = try #require(await films.frameNeutral(frame, lens: .default, pixels: pixels))
        let scaled = try #require(films.frameDecode(of: frame, lens: .default, pixels: pixels))
        #expect(!films.isFrameDecodeRefined(frame, lens: .default, pixels: pixels) && scaled.decoderVersion == decoder)
        #expect(scaled.pins?.draftMode == AppleRawDecoder.draftMode(scale: scaled.pins?.scale ?? 1, version: AppleDecoderVersion(rawValue: decoder)!))

        #expect(await films.refineFrame(frame, lens: .default, pixels: pixels))
        #expect(films.isFrameDecodeRefined(frame, lens: .default, pixels: pixels) && films.hasFrameDecode(frame, lens: .default, pixels: pixels))
        #expect(films.refinementCounts == (started: 1, installed: 1, dropped: 0))
        let refined = try #require(films.frameDecode(of: frame, lens: .default, pixels: pixels))
        #expect(refined.width == scaled.width && refined.height == scaled.height && refined.decoderVersion == decoder)
        let version = try #require(AppleDecoderVersion(rawValue: decoder))
        let tile = version == .learned ? RollDeveloper.learnedDecodeTile : RollDeveloper.decodeTile
        #expect(refined.pins?.scale == 1 && refined.pins?.draftMode == false && refined.pins?.tileSize == tile)

        // What a develop decodes, area-resized onto the same pixels.
        let gpu = try GPU(maxIdlePoolBytes: 0)
        var options = DecodeOptions()
        options.tileSize = tile
        options.appleDecoder = version
        options.lensCorrection = false
        let full = try AppleRawDecoder(gpu: gpu, contextPerDecode: true).decode(frame.url, options: options)
        let expected = try gpu.texturePool.acquire(width: scaled.width, height: scaled.height)
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        try AreaResize(gpu: gpu).encode(full.texture, to: expected.texture, into: commandBuffer)
        commandBuffer.commit()
        await commandBuffer.completed()
        #expect(abs(refined.scale - Float(max(scaled.width, scaled.height)) / Float(max(full.width, full.height))) < 1e-6)
        let scene = try LensStage(gpu: gpu).correct(LinearFrame(image: expected, decoderVersion: decoder, scale: refined.scale),
                                                   with: LensResolver.correction(for: frame.url, settings: .default))
        let shown = ExposureAnalyzer.pixels(of: refined.texture), developed = ExposureAnalyzer.pixels(of: scene.texture)
        let differing = zip(shown, developed).filter { $0 != $1 }
        print("MEASURE refined \(mode) \(scaled.width)x\(scaled.height) from \(full.width)x\(full.height): \(differing.count) of \(shown.count) samples differ")
        #expect(shown.count == developed.count && differing.allSatisfy { $0.nextUp == $1 || $0.nextDown == $1 })
        #expect(differing.count * 100 < shown.count)

        // The pictures are made again from it at the same size, and the cache serves them.
        let film = try #require(await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: pixels))
        let neutral = try #require(await films.frameNeutral(frame, lens: .default, pixels: pixels))
        #expect(film !== fast && neutral !== fastNeutral)
        #expect(film.width == fast.width && film.height == fast.height)
        #expect(neutral.width == fastNeutral.width && neutral.height == fastNeutral.height)
        #expect(films.cachedFrameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: pixels) === film)
        #expect(films.cachedFrameNeutral(frame, lens: .default, pixels: pixels) === neutral)
        #expect(films.decodeCount == 1)

        // Asking again changes nothing; another window size decodes again, scaled.
        #expect(await films.refineFrame(frame, lens: .default, pixels: pixels))
        #expect(films.refinementCounts.started == 1)
        #expect(await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: pixels - 100) != nil)
        #expect(!films.isFrameDecodeRefined(frame, lens: .default, pixels: pixels - 100) && !films.hasFrameDecode(frame, lens: .default, pixels: pixels))
    }

    /// A refined picture outlives its decode: once three other frames have taken the frame view's
    /// decodes, the frame opened again shows its refined film and neutral raw at once, decoding
    /// nothing, rather than the scaled decode's (found measuring, 2026-10-16).
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func aRefinedPictureServesAfterItsDecodeIsLetGo() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await RollScanner.scan(Self.samples).frames
        let frame = try #require(frames.first { $0.name.contains("Raw-Compressed") })
        let settings = DevelopSettings()
        #expect(await films.frameFilm(frame, stock: 0, settings: settings, pixels: 600) != nil)
        #expect(await films.frameNeutral(frame, lens: .default, pixels: 600) != nil)
        #expect(await films.refineFrame(frame, lens: .default, pixels: 600))
        let film = try #require(await films.frameFilm(frame, stock: 0, settings: settings, pixels: 600))
        let neutral = try #require(await films.frameNeutral(frame, lens: .default, pixels: 600))
        #expect(films.isRefinedFrameFilm(film, frame: frame, stock: 0, settings: settings, pixels: 600))
        for other in frames where other.url != frame.url { _ = await films.frameNeutral(other, lens: .default, pixels: 600) }
        #expect(!films.keepsFrameDecode(frame, lens: .default, pixels: 600))

        let decodes = films.decodeCount
        #expect(films.cachedFrameFilm(frame, stock: 0, settings: settings, pixels: 600) === film)
        #expect(films.cachedFrameNeutral(frame, lens: .default, pixels: 600) === neutral)
        #expect(await films.frameFilm(frame, stock: 0, settings: settings, pixels: 600) === film)
        #expect(await films.frameNeutral(frame, lens: .default, pixels: 600) === neutral)
        #expect(films.decodeCount == decodes && !films.keepsFrameDecode(frame, lens: .default, pixels: 600))
    }

    /// The in-house decoder's scaled decodes are its full decode area-resized already, and a decode
    /// of the whole raw is what a develop decodes: neither is refined, nor a frame not yet decoded.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func inHouseAndWholeDecodesAreNotRefined() async throws {
        let (films, directory) = try previews(route: .inHouse)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await RollScanner.scan(Self.samples).frames
        let large = try #require(frames.first { $0.name.contains("Large") })
        let small = try #require(frames.first { $0.name.contains("Small") })
        let medium = try #require(frames.first { $0.name.contains("Medium") })
        #expect(await !films.refineFrame(medium, lens: .default, pixels: 1201))
        #expect(await films.frameFilm(large, stock: 0, settings: DevelopSettings(), pixels: 1201) != nil)
        #expect(await !films.refineFrame(large, lens: .default, pixels: 1201))
        // Lossless S is 3504 by 2336 before its trim, so a 3600-pixel frame view has it whole.
        #expect(await films.frameFilm(small, stock: 0, settings: DevelopSettings(), pixels: 3600) != nil)
        #expect(films.frameDecode(of: small, lens: .default, pixels: 3600)?.scale == 1)
        #expect(await !films.refineFrame(small, lens: .default, pixels: 3600))
        #expect(films.refinementCounts.started == 0)
    }

    /// While a develop runs, a frame view decode waits for the develop's frames under way, and no
    /// frame starts while it waits; then it decodes and the frame view gets its film.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func whileADevelopRunsADecodeWaitsForItsFrames() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains("Uncompressed") })
        let gate = MemoryGate(ceiling: Int.max, maxInFlight: 2, turns: films.decodeTurns, footprint: { 0 })
        films.isDevelopRunning = true
        defer { films.isDevelopRunning = false }
        #expect(gate.admit(decode: 0, stopped: { false }))
        let film = Task { await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 1201) }
        while films.decodeTurns.counts.previewsWaiting == 0 { try await Task.sleep(for: .milliseconds(1)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(films.decodeCount == 0)
        #expect(!gate.admit(decode: 0, stopped: { true }))
        gate.leave()
        #expect(await film.value != nil)
        #expect(films.decodeCount == 1)
        #expect(films.decodeTurns.counts == (frames: 0, previewsWaiting: 0, previewsRunning: 0))
    }

    /// The decode turns' lock comes before the previews' own (`DecodeTurns`): a develop's frames let in
    /// and out as fast as they go, each weighing what the previews hold under the turns' lock, beside
    /// frame view decodes each at a size of its own, kept under the previews' lock as it ends, never
    /// wait on each other. On RAW 8's route, whose small decodes are quick; the two once deadlocked at
    /// the first decode. The develop flag is not reset after: where they deadlock, that would hang too.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func aDevelopsFramesAndFrameViewDecodesNeverWaitOnEachOther() async throws {
        let (films, directory) = try previews(route: .apple)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains("Uncompressed") })
        let gate = MemoryGate(ceiling: Int.max, maxInFlight: 2, turns: films.decodeTurns, floorQuiet: 0, floorWaitLimit: 0,
                              footprint: { 0 })
        films.isDevelopRunning = true
        let stop = Counter(), admitted = Counter(), decoded = Counter(), developDone = Counter()
        Thread {
            while stop.value == 0 {
                if gate.admit(decode: 1, stopped: { false }) {
                    admitted.add()
                    gate.leave()
                }
            }
            developDone.add()
        }.start()
        let decodes = 8
        Task.detached {
            for index in 0..<decodes {
                if await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 160 + 8 * index) != nil { decoded.add() }
            }
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while decoded.value < decodes, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        stop.add()
        while developDone.value == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(decoded.value == decodes, "deadlocked after \(decoded.value) of \(decodes) decodes")
        #expect(developDone.value == 1, "the develop deadlocked")
        #expect(admitted.value > decodes)
        print("MEASURE \(admitted.value) frames let in beside \(decoded.value) frame view decodes")
    }

    /// While a develop runs the previews keep what is on screen: the frame view the decode of its frame
    /// only, and the rendered pictures within `developRenderedBytes`; after it, as before.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func whileADevelopRunsTheFrameViewKeepsOnlyItsFrame() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await RollScanner.scan(Self.samples).frames
        try #require(frames.count >= 2)
        films.isDevelopRunning = true
        #expect(films.renderedCacheLimit == FilmPreviews.developRenderedBytes)
        for frame in frames.prefix(2) {
            #expect(await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 1201) != nil)
        }
        #expect(films.frameDecode(of: frames[0], lens: .default, pixels: 1201) == nil)
        #expect(films.frameDecode(of: frames[1], lens: .default, pixels: 1201) != nil)
        films.isDevelopRunning = false
        #expect(films.renderedCacheLimit > FilmPreviews.developRenderedBytes)
        // At another size, so it is decoded again rather than taken from the rendered pictures.
        #expect(await films.frameFilm(frames[0], stock: 0, settings: DevelopSettings(), pixels: 1100) != nil)
        #expect(films.frameDecode(of: frames[0], lens: .default, pixels: 1100) != nil && films.frameDecode(of: frames[1], lens: .default, pixels: 1201) != nil)
    }

    /// A refinement does not start while a develop runs and stops between tiles when its caller
    /// goes or a develop trims the previews; nothing it made is kept.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func aRefinementStopsForADevelopAndWhenItsCallerGoes() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frame = try #require(await RollScanner.scan(Self.samples).frames.first { $0.name.contains("Raw-Compressed") })
        #expect(await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: 1201) != nil)
        films.pausesRefinement = true
        #expect(await !films.refineFrame(frame, lens: .default, pixels: 1201))
        #expect(films.refinementCounts.started == 0)
        films.pausesRefinement = false

        func started(_ count: Int) async throws {
            while films.refinementCounts.started < count { try await Task.sleep(for: .milliseconds(1)) }
        }
        let clock = ContinuousClock()
        let abandoned = Task { await films.refineFrame(frame, lens: .default, pixels: 1201) }
        try await started(1)
        let cancelled = clock.now
        abandoned.cancel()
        #expect(await abandoned.value == false)
        let stopTime = clock.now - cancelled
        let trimmed = Task { await films.refineFrame(frame, lens: .default, pixels: 1201) }
        try await started(2)
        films.trimForDevelop()
        #expect(await trimmed.value == false)
        print("MEASURE a refinement stopped \(stopTime.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))) after its caller went")
        #expect(films.refinementCounts == (started: 2, installed: 0, dropped: 2))
        #expect(!films.isFrameDecodeRefined(frame, lens: .default, pixels: 1201))
    }

    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func cancelledRequestsDoNotDecode() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let roll = await RollScanner.scan(Self.samples)
        try #require(roll.frames.count == 5)
        let tasks = roll.frames.map { frame in
            Task { await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 128) }
        }
        try await Task.sleep(for: .milliseconds(20))
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.value }
        // Only the decodes already running when the cancel came may finish.
        #expect(films.decodeCount <= FilmPreviews.concurrentDecodes)
        print("MEASURE decodes after cancelling \(tasks.count) requests: \(films.decodeCount)")
    }

    /// Changing `learnedDecodeTile` makes RAW 9 refinements and removal inputs decode at the new
    /// tile and drops kept RAW 9 refinements (both held decodes and refined renders that outlived
    /// their decode), while leaving RAW 8 refinements untouched and preserving refinements when the
    /// tile stays the same.
    @Test(.enabled(if: FilmPreviewSampleTests.hasSamples))
    func refinementAndRemovalInputFollowLearnedDecodeTileAndDropStaleRefinements() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await RollScanner.scan(Self.samples).frames
        let raw9 = try #require(frames.first { $0.name.contains("Large") })
        let raw8 = try #require(frames.first { $0.name.contains("Small") })
        let settings = DevelopSettings()
        let pixels = 600

        // Refine both a RAW 9 frame and a RAW 8 frame at 1024 (RAW 8 uses 768).
        #expect(films.learnedDecodeTile == 1024)
        #expect(await films.frameFilm(raw9, stock: 0, settings: settings, pixels: pixels) != nil)
        #expect(await films.refineFrame(raw9, lens: .default, pixels: pixels))
        #expect(films.frameDecode(of: raw9, lens: .default, pixels: pixels)?.pins?.tileSize == 1024)
        let film1024 = try #require(await films.frameFilm(raw9, stock: 0, settings: settings, pixels: pixels))
        let neutral1024 = try #require(await films.frameNeutral(raw9, lens: .default, pixels: pixels))
        #expect(films.isRefinedFrameFilm(film1024, frame: raw9, stock: 0, settings: settings, pixels: pixels))

        #expect(await films.frameFilm(raw8, stock: 0, settings: settings, pixels: pixels) != nil)
        #expect(await films.refineFrame(raw8, lens: .default, pixels: pixels))
        #expect(films.frameDecode(of: raw8, lens: .default, pixels: pixels)?.pins?.tileSize == RollDeveloper.decodeTile)
        let raw8Film = try #require(await films.frameFilm(raw8, stock: 0, settings: settings, pixels: pixels))

        // Switching RAW 9's tile to 2048 drops the RAW 9 refined decode and refined pictures, and keeps RAW 8's.
        films.learnedDecodeTile = 2048
        #expect(!films.isFrameDecodeRefined(raw9, lens: .default, pixels: pixels))
        #expect(films.cachedFrameFilm(raw9, stock: 0, settings: settings, pixels: pixels) == nil)
        #expect(films.cachedFrameNeutral(raw9, lens: .default, pixels: pixels) == nil)
        #expect(!films.isRefinedFrameFilm(film1024, frame: raw9, stock: 0, settings: settings, pixels: pixels))
        #expect(films.isFrameDecodeRefined(raw8, lens: .default, pixels: pixels))
        #expect(films.cachedFrameFilm(raw8, stock: 0, settings: settings, pixels: pixels) === raw8Film)

        // Refining RAW 9 now decodes at 2048; setting the same tile again (e.g. 3 GB -> 4 GB) keeps it.
        #expect(await films.frameFilm(raw9, stock: 0, settings: settings, pixels: pixels) != nil)
        #expect(await films.refineFrame(raw9, lens: .default, pixels: pixels))
        #expect(films.frameDecode(of: raw9, lens: .default, pixels: pixels)?.pins?.tileSize == 2048)
        let film2048 = try #require(await films.frameFilm(raw9, stock: 0, settings: settings, pixels: pixels))
        #expect(film2048 !== film1024 && films.isRefinedFrameFilm(film2048, frame: raw9, stock: 0, settings: settings, pixels: pixels))
        films.learnedDecodeTile = 2048
        #expect(films.isFrameDecodeRefined(raw9, lens: .default, pixels: pixels))
        #expect(films.cachedFrameFilm(raw9, stock: 0, settings: settings, pixels: pixels) === film2048)

        // Even after the refined decode is evicted from `frameLinear`, a tile change still drops its cached picture.
        for other in frames where other.url != raw9.url { _ = await films.frameNeutral(other, lens: .default, pixels: pixels) }
        #expect(!films.keepsFrameDecode(raw9, lens: .default, pixels: pixels))
        #expect(films.cachedFrameFilm(raw9, stock: 0, settings: settings, pixels: pixels) === film2048)
        films.learnedDecodeTile = 1024
        #expect(films.cachedFrameFilm(raw9, stock: 0, settings: settings, pixels: pixels) == nil)
        #expect(neutral1024.width > 0)

        // Removal input uses the current RAW 9 tile: match direct full-size decodes at 1024 and at 2048.
        let box = try RemovalPatch.Box(x: 704, y: 704, width: 640, height: 640)
        let gpu = try GPU(maxIdlePoolBytes: 0), stage = try LensStage(gpu: gpu)
        let rawDecoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        func directCrop(tile: Int) throws -> [Float16] {
            var options = DecodeOptions()
            options.appleDecoder = .learned
            options.tileSize = RollDeveloper.decodeTile
            options.learnedTileSize = tile
            options.lensCorrection = false
            return try stage.removalInput(try rawDecoder.decode(raw9.url, options: options), removals: [], box: box)
        }
        let expected1024 = try directCrop(tile: 1024)
        let expected2048 = try directCrop(tile: 2048)
        films.learnedDecodeTile = 1024
        let crop1024 = try await films.removalInput(raw9, lens: .default, box: box)
        #expect(crop1024.rgb == expected1024 && films.lastRemovalInputTile == 1024)
        films.learnedDecodeTile = 2048
        let crop2048 = try await films.removalInput(raw9, lens: .default, box: box)
        #expect(crop2048.rgb == expected2048 && films.lastRemovalInputTile == 2048)

        // Changing the tile while a RAW 9 refinement is in flight drops that refinement.
        films.removeAll()
        films.learnedDecodeTile = 1024
        #expect(await films.frameFilm(raw9, stock: 0, settings: settings, pixels: pixels) != nil)
        let startedBefore = films.refinementCounts.started
        let inFlight = Task { await films.refineFrame(raw9, lens: .default, pixels: pixels) }
        while films.refinementCounts.started <= startedBefore { try await Task.sleep(for: .milliseconds(1)) }
        films.learnedDecodeTile = 2048
        #expect(await inFlight.value == false)
        #expect(!films.isFrameDecodeRefined(raw9, lens: .default, pixels: pixels))
    }
}
