import ArgentCore
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import ArgentRoll

/// The frame view's costs on this machine, behind docs/M2-shell.md section 4. They read the
/// CC0 samples, the git-ignored corpus under references/corpus and the stocks that
/// scripts/build-app.sh bakes into build/stocks, and run only with ARGENT_MEASURE=1, one test
/// at a time so their timings do not overlap:
///
///     ARGENT_MEASURE=1 swift test --filter FrameViewMeasureTests
@Suite(.serialized) struct FrameViewMeasureTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var enabled: Bool { ProcessInfo.processInfo.environment["ARGENT_MEASURE"] != nil }

    /// The M2 gate's 19 files, or the raws in the folder ARGENT_ROLL names, such as the decoder
    /// switch's measurement roll (`DecoderSwitchMeasureTests.makeRolls`).
    static func files() -> [URL] {
        if let roll = ProcessInfo.processInfo.environment["ARGENT_ROLL"] {
            return RollScanner.rawFiles(in: URL(fileURLWithPath: roll)).sorted { $0.path < $1.path }
        }
        return gateFiles()
    }

    /// The five CC0 samples and the 14 photographyblog frames.
    static func gateFiles() -> [URL] {
        let folders = ["samples", "references/corpus/photographyblog-a7iv"]
        return folders.flatMap { RollScanner.rawFiles(in: root.appendingPathComponent($0)) }.sorted { $0.path < $1.path }
    }

    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    /// The median, of the two middle values for an even count, with the extremes.
    static func summary(_ values: [Double]) -> String {
        let s = values.sorted()
        let median = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        return String(format: "median %.1f ms, min %.1f, max %.1f (n=%d)", median, s.first!, s.last!, s.count)
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func embeddedFullSizeJPEG() throws {
        let clock = ContinuousClock()
        let files = Self.files()
        let infos = try files.map { try ARWFrameInfo.read(from: $0) }
        // Warm the file cache.
        for (url, info) in zip(files, infos) { _ = try? Data(contentsOf: url, options: .mappedIfSafe).count; _ = info }
        for size in [1280, 1920, 2560, 3072, 4096] {
            var times: [Double] = []
            for (url, info) in zip(files, infos) {
                guard let range = info.fullSizePreview else { continue }
                let start = clock.now
                let image = try EmbeddedJPEG.image(at: range, in: url, maxPixelSize: size, orientation: info.orientation)
                times.append(Self.ms(clock.now - start))
                #expect(max(image.width, image.height) <= size)
            }
            print("MEASURE IFD2 JPEG at \(size) px: \(Self.summary(times))")
        }
        let sizes = Set(infos.compactMap { $0.fullSizePreview?.length }).sorted()
        print("MEASURE IFD2 lengths: \(sizes)")
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func rawDecodeAndRenders() throws {
        let clock = ContinuousClock()
        let gpu = try GPU(maxIdlePoolBytes: 512 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: Self.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let files = Self.files()
        // Warm up the decoder and the shaders.
        _ = try decoder.decode(files[0], options: { var o = DecodeOptions(); o.maxLongSide = 960; return o }())
        for size in [960, 1920, 2560, 3072, 4096] {
            var decodes: [Double] = [], films: [Double] = [], neutrals: [Double] = [], filmGPU: [Double] = []
            for url in files {
                var options = DecodeOptions()
                options.maxLongSide = size
                var start = clock.now
                guard let linear = try? decoder.decode(url, options: options) else { continue }
                decodes.append(Self.ms(clock.now - start))
                start = clock.now
                let rendered = try renderer.render(linear, settings: DevelopSettings())
                filmGPU.append(rendered.gpuSeconds * 1000)
                let ci = CIImage(mtlTexture: rendered.image.texture, options: [.colorSpace: gpu.workingColorSpace])!
                let film = gpu.ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: p3)
                films.append(Self.ms(clock.now - start))
                start = clock.now
                let ciLinear = CIImage(mtlTexture: linear.texture, options: [.colorSpace: gpu.workingColorSpace])!
                let neutral = gpu.ciContext.createCGImage(ciLinear, from: ciLinear.extent, format: .RGBA8, colorSpace: p3)
                neutrals.append(Self.ms(clock.now - start))
                #expect(film != nil && neutral != nil)
            }
            print("MEASURE decode at \(size): \(Self.summary(decodes))")
            print("MEASURE   film render + CGImage at \(size): \(Self.summary(films)); GPU passes \(Self.summary(filmGPU))")
            print("MEASURE   neutral CGImage at \(size): \(Self.summary(neutrals))")
        }
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func largeDecodeBesideASmallOne() throws {
        let clock = ContinuousClock()
        let files = Self.files()
        let gpu = try GPU(maxIdlePoolBytes: 512 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        _ = try decoder.decode(files[0], options: { var o = DecodeOptions(); o.maxLongSide = 960; return o }())
        for size in [2560, 3072] {
            var alone: [Double] = [], beside: [Double] = []
            for (i, url) in files.enumerated() {
                var options = DecodeOptions()
                options.maxLongSide = size
                var start = clock.now
                _ = try? decoder.decode(url, options: options)
                alone.append(Self.ms(clock.now - start))
                let other = files[(i + 1) % files.count]
                let group = DispatchGroup()
                // Apple's decoder is safe to share across threads, as `ChosenDecoder` shares it.
                let shared = UncheckedBox(decoder)
                DispatchQueue.global().async(group: group) {
                    var small = DecodeOptions()
                    small.maxLongSide = 960
                    _ = try? shared.value.decode(other, options: small)
                }
                start = clock.now
                _ = try? decoder.decode(url, options: options)
                beside.append(Self.ms(clock.now - start))
                group.wait()
            }
            print("MEASURE decode at \(size) alone: \(Self.summary(alone)); beside a 960 decode: \(Self.summary(beside))")
        }
    }

    /// Opening a frame as the app does, through FilmPreviews with the six baked stocks and the
    /// sheet's 64 MB pool: the frame view's film, its neutral raw and the strip's six chips at
    /// once; then a stock switch, and a frame decoded ahead.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func openingAFrameThroughFilmPreviews() async throws {
        let stocks = StockLibrary.load(from: Self.root.appendingPathComponent("build/stocks")).stocks
        #expect(stocks.count == 6)
        let films = try FilmPreviews(stocks: stocks)
        let clock = ContinuousClock()
        var frames: [Frame] = []
        for folder in ["samples", "references/corpus/photographyblog-a7iv"] {
            frames += await RollScanner.scan(Self.root.appendingPathComponent(folder)).frames
        }
        // Warm the decoder.
        _ = await films.film(frames[0], stock: 0, settings: DevelopSettings(), maxPixelSize: 64)
        let pixels = 2190
        var firstFilm: [Double] = [], allChips: [Double] = [], switches: [Double] = [], ahead: [Double] = []
        for (i, frame) in frames.enumerated() where i > 0 {
            let before = films.decodeCount
            let start = clock.now
            async let large = films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: pixels)
            async let neutral = films.frameNeutral(frame, lens: .default, pixels: pixels)
            let chips = Task {
                await withTaskGroup(of: Void.self) { group in
                    for stock in 0..<6 {
                        group.addTask {
                            _ = await films.film(frame, stock: stock, settings: DevelopSettings(), maxPixelSize: 208, priority: .high,
                                                 frameViewSide: FilmPreviews.frameDecodeSide(forPixels: pixels))
                        }
                    }
                }
                return clock.now
            }
            _ = await large
            firstFilm.append(Self.ms(clock.now - start))
            _ = await neutral
            allChips.append(Self.ms(await chips.value - start))
            #expect(films.decodeCount - before == 1, "\(frame.name)")
            for stock in 1..<6 {
                let s = clock.now
                _ = await films.frameFilm(frame, stock: stock, settings: DevelopSettings(), pixels: pixels)
                switches.append(Self.ms(clock.now - s))
            }
        }
        // A frame decoded ahead, as the frame view does for the next one, then shown with
        // settings it was not rendered with.
        films.removeAll()
        for frame in frames.dropFirst() {
            _ = await films.frameFilm(frame, stock: 0, settings: DevelopSettings(), pixels: pixels, priority: .low)
            let s = clock.now
            _ = await films.frameFilm(frame, stock: 0, settings: DevelopSettings(labBalance: SIMD3(0.01, 0, 0)), pixels: pixels)
            ahead.append(Self.ms(clock.now - s))
        }
        print("MEASURE frame view at \(pixels) px, first film: \(Self.summary(firstFilm))")
        print("MEASURE   strip's six chips done: \(Self.summary(allChips))")
        print("MEASURE   stock switch: \(Self.summary(switches))")
        print("MEASURE   film of a frame decoded ahead: \(Self.summary(ahead))")
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func midGrayOnThePrint() throws {
        for id in StockLibrary.order {
            let stock = try Stock.load(from: Self.root.appendingPathComponent("build/stocks/\(id)"))
            let encoding = stock.negative.encoding
            let dyes = stock.negative.sample(encoded: SIMD3(repeating: encoding.encode(0.18)))
            let printed = stock.print.sample(encoded: dyes)
            let white = stock.print.sample(encoded: stock.negative.sample(encoded: SIMD3(repeating: encoding.encode(0.18 * exp2(5)))))
            let black = stock.print.sample(encoded: stock.negative.sample(encoded: SIMD3(repeating: encoding.encode(0.18 * exp2(-8)))))
            print(String(format: "MEASURE %@ prints 0.18 at %.4f %.4f %.4f (%.2f stops from 0.18); +5 at %.3f; -8 at %.4f",
                         id, printed.x, printed.y, printed.z, log2(printed.y / 0.18), white.y, black.y))
        }
    }
}
