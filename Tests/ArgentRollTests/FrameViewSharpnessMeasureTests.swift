import ArgentCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentRoll

/// The frame view's picture against the develop area-resized to the same pixels
/// (docs/M3-auto.md, section 11), on Imaging Resource's ISO 100 still life through Portra 400,
/// and what a window resize costs. Runs only with ARGENT_MEASURE=1, one test at a time:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter FrameViewSharpnessMeasureTests
@Suite(.serialized) struct FrameViewSharpnessMeasureTests {
    typealias M = FrameViewMeasureTests
    typealias A = AutoMeasureTests

    static let stillLife = M.root.appendingPathComponent("references/corpus/imaging-resource-a7iv-wayback/A7M4hSLI000100NR0.ARW")
    /// Full-size picture coordinates of the right edges of the chart's white and middle-gray
    /// patches against its dark frame; textures hold their rows bottom up.
    static let whiteEdge = 3270..<3330, grayEdge = 3595..<3650, edgeRows = 3985..<4040

    static func scaled(_ r: Range<Int>, _ s: Float) -> Range<Int> { Int(Float(r.lowerBound) * s)..<Int(Float(r.upperBound) * s) }
    static func up(_ r: Range<Int>, _ height: Int) -> Range<Int> { (height - r.upperBound)..<(height - r.lowerBound) }

    /// The two edges' 10 to 90 percent rise and overshoot, at `s` of the full size.
    static func edges(_ l: [Float], width: Int, s: Float) -> String {
        let rows = up(scaled(edgeRows, s), l.count / width), reach = max(2, 8 * s)
        let white = A.edge(l, width: width, columns: scaled(whiteEdge, s), rows: rows, reach: reach)
        let gray = A.edge(l, width: width, columns: scaled(grayEdge, s), rows: rows, reach: reach)
        return String(format: "white edge rise %.2f px, overshoot %.1f%%; gray edge rise %.2f px, overshoot %.1f%%",
                      white.rise, white.overshoot * 100, gray.rise, gray.overshoot * 100)
    }

    /// The chart's dark frame beside the white patch, where a resize that rings dips: the
    /// lowest column's mean L* and the lowest pixel.
    static func darkFrame(_ l: [Float], width: Int, s: Float) -> String {
        let columns = scaled(whiteEdge, s), rows = up(scaled(edgeRows, s), l.count / width)
        let profile = columns.map { x in rows.map { l[$0 * width + x] }.reduce(0, +) / Float(rows.count) }
        let crossing = profile.firstIndex { $0 < 58 } ?? 0
        var pixels: [Float] = []
        for y in rows { for x in columns.lowerBound + crossing..<columns.upperBound { pixels.append(l[y * width + x]) } }
        return String(format: "dark frame lowest column L* %.1f, lowest pixel %.1f", profile[crossing...].min()!, pixels.min()!)
    }

    static func ratio(_ a: [Float], _ aw: Int, _ b: [Float], _ bw: Int) -> String {
        zip(A.bands(a, width: aw), A.bands(b, width: bw)).map { String(format: "%.2f", $0 / $1) }.joined(separator: ", ")
    }

    /// Writes the `width` by `height` crop at (`x`, `y`) of a linear half-float picture, top-down
    /// picture coordinates, as an 8-bit PNG in Display P3, for looking at by eye.
    static func writeCrop(_ texture: MTLTexture, gpu: GPU, x: Int, y: Int, width: Int, height: Int, to url: URL) {
        let image = CIImage(mtlTexture: texture, options: [.colorSpace: gpu.workingColorSpace])!
        // The texture's rows are bottom up, as Core Image's are, so picture row y is texture row h - y - height.
        let rect = CGRect(x: x, y: texture.height - y - height, width: width, height: height)
        guard let cg = gpu.ciContext.createCGImage(image, from: rect, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cg, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Each window size three ways against the develop rendered at full size and area-resized
    /// to it: the frame view as it was (a decode at the window's size rounded up to a multiple of
    /// 512, rendered and area-resized), the frame view now (a decode at the window's own size,
    /// rendered), and the neutral raw both ways against the full-size decode area-resized. With
    /// FRAME_VIEW_CROPS set, writes 100 percent crops of the bottle labels to /tmp.
    @Test(.enabled(if: M.enabled))
    func againstTheDevelop() throws {
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let decoder = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let resize = try AreaResize(gpu: gpu)
        let crops = ProcessInfo.processInfo.environment["FRAME_VIEW_CROPS"] != nil
        let full = try decoder.decode(Self.stillLife, options: DecodeOptions())
        let sharpened = DevelopSettings(sharpen: true)
        let asTheAppDevelops = DevelopSettings(grain: 1, grainSeed: 5, halation: true, sharpen: true)
        let develop = try renderer.render(full, settings: sharpened).image
        let developed = try renderer.render(full, settings: asTheAppDevelops).image
        let sizes = ProcessInfo.processInfo.environment["FRAME_VIEW_SIZES"].map { $0.split(separator: ",").compactMap { Int($0) } }
            ?? [900, 1408, 2190, 2600, 2944, 3500, 3700]
        for shown in sizes {
            let s = Float(shown) / Float(full.width)
            var stepped = DecodeOptions()
            stepped.maxLongSide = (shown + 511) / 512 * 512
            let before = try decoder.decode(Self.stillLife, options: stepped)
            var exact = DecodeOptions()
            exact.maxLongSide = shown
            exact.fillsMaxLongSide = true
            let now = try decoder.decode(Self.stillLife, options: exact)
            #expect(max(now.width, now.height) == shown)
            let side = { (frame: LinearFrame) in "\(frame.width) px\(frame.pins?.draftMode == true ? ", draft" : "")" }

            let target = try A.area(develop.texture, longSide: shown, resize: resize)
            let wasShown = try A.area(renderer.render(before, settings: sharpened).image.texture, longSide: shown, resize: resize)
            let nowShown = try renderer.render(now, settings: sharpened).image
            let t = A.lightness(target.pixels), w = A.lightness(wasShown.pixels), n = A.lightness(ExposureAnalyzer.pixels(of: nowShown.texture))
            print("MEASURE frame view sharpness at \(shown) px: develop area-resized \(Self.edges(t, width: target.width, s: s))")
            print("MEASURE   as it was, from a \(side(before)) decode: bands \(Self.ratio(w, wasShown.width, t, target.width)); \(Self.edges(w, width: wasShown.width, s: s))")
            print("MEASURE   now, from a \(side(now)) decode: bands \(Self.ratio(n, nowShown.width, t, target.width)); \(Self.edges(n, width: nowShown.width, s: s))")

            // As the app renders: grain, halation and sharpening, where a resize that rang would dip.
            let scale = Double(shown) / Double(full.width)
            let appTarget = try resize.resized(developed.texture, scale: scale)
            let appRender = try renderer.render(before, settings: asTheAppDevelops).image
            let appWas = try resize.resized(appRender.texture, scale: Double(shown) / Double(max(before.width, before.height)))
            let appNow = try renderer.render(now, settings: asTheAppDevelops).image
            func dark(_ picture: PooledTexture) -> String {
                Self.darkFrame(A.lightness(ExposureAnalyzer.pixels(of: picture.texture)), width: picture.width, s: s)
            }
            print("MEASURE   as the app renders: develop \(dark(appTarget)); as it was \(dark(appWas)); now \(dark(appNow))")

            // The neutral raw: the decode itself, shown as display-linear light.
            let rawTarget = try A.area(full.texture, longSide: shown, resize: resize)
            let rawWas = try A.area(before.texture, longSide: shown, resize: resize)
            let rt = A.lightness(rawTarget.pixels), rw = A.lightness(rawWas.pixels), rn = A.lightness(ExposureAnalyzer.pixels(of: now.texture))
            print("MEASURE   neutral raw against the full-size decode area-resized: as it was \(Self.ratio(rw, rawWas.width, rt, rawTarget.width)); now \(Self.ratio(rn, now.width, rt, rawTarget.width))")

            if crops {
                // The bottle labels, left of the chart, at 100 percent.
                let x = Int(Float(1150) * s), y = Int(Float(2500) * s), cw = min(480, shown / 3), ch = min(320, shown / 4)
                for (name, texture) in [("develop", appTarget.texture), ("was", appWas.texture), ("now", appNow.texture)] {
                    Self.writeCrop(texture, gpu: gpu, x: x, y: y, width: cw, height: ch,
                                   to: URL(fileURLWithPath: "/tmp/argent-fvsharp-\(shown)-\(name).png"))
                }
            }
        }
    }

    /// Opening frames at 2190 px through `FilmPreviews` as the app does, film and neutral raw
    /// together, then a window resize to a size just below (2100 px) and one just above
    /// (2600 px): how long each takes to film on screen once the window settles, and how many
    /// decodes it took.
    @Test(.enabled(if: M.enabled))
    func aWindowResize() async throws {
        let stocks = StockLibrary.load(from: M.root.appendingPathComponent("build/stocks")).stocks
        let films = try FilmPreviews(stocks: stocks)
        let clock = ContinuousClock()
        var frames: [Frame] = []
        for folder in ["samples", "references/corpus/photographyblog-a7iv"] {
            frames += await RollScanner.scan(M.root.appendingPathComponent(folder)).frames
        }
        _ = await films.film(frames[0], stock: 0, settings: DevelopSettings(), maxPixelSize: 64)
        let settings = DevelopSettings(grain: 1, grainSeed: 5, halation: true, sharpen: true)
        var opened: [Double] = [], smaller: [Double] = [], larger: [Double] = []
        var decodes: [Int] = [0, 0, 0]
        for frame in frames.dropFirst() {
            for (index, pixels) in [2190, 2100, 2600].enumerated() {
                let before = films.decodeCount
                let start = clock.now
                async let film = films.frameFilm(frame, stock: 0, settings: settings, pixels: pixels)
                async let neutral = films.frameNeutral(frame, lens: .default, pixels: pixels)
                let picture = await film
                let elapsed = M.ms(clock.now - start)
                _ = await neutral
                #expect(picture.map { max($0.width, $0.height) } == pixels)
                decodes[index] += films.decodeCount - before
                switch index {
                case 0: opened.append(elapsed)
                case 1: smaller.append(elapsed)
                default: larger.append(elapsed)
                }
            }
        }
        print("MEASURE window resize: opened at 2190 px \(M.summary(opened)), \(decodes[0]) decodes")
        print("MEASURE   resized to 2100 px: \(M.summary(smaller)), \(decodes[1]) decodes")
        print("MEASURE   resized to 2600 px: \(M.summary(larger)), \(decodes[2]) decodes")
    }
}
