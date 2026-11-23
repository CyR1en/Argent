import CoreImage
import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Measurements behind docs/decoder.md section 18: Apple's RAW 9, the learned demosaic and denoise,
/// for every a7 IV frame in a Bayer mode, against RAW 8 (the pinned classic decoder) and the in-house
/// decoder. Gated like the other measurement suites, one test a process for timings and memory:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --skip-build --filter Raw9MeasureTests/<test>
///
/// They read the CC0 samples, the APS-C pair in references/exposure, the corpus in references/corpus
/// (Imaging Resource's still-life ladder and gallery, photographyblog's frames) and build/stocks.
/// ARGENT_SETS picks the frames: `samples`, `stilllife`, `photographyblog`, `gallery`.
@Suite(.serialized, .syntheticRaws) struct Raw9MeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }
    typealias M = InHouseDecoderMeasureTests
    typealias A = AutoMeasureTests
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static let samples = M.root.appendingPathComponent("samples")
    static let apsC = M.root.appendingPathComponent("references/exposure/pixls-ilce-7m4-samples")

    /// The a7 IV raws here by set, ARGENT_SETS (default all), each set sorted by ISO then name.
    static func frames(_ fallback: String = "samples,stilllife,photographyblog,gallery") -> [(set: String, iso: Int, url: URL)] {
        let sets = (Self.environment["ARGENT_SETS"] ?? fallback).split(separator: ",").map(String.init)
        var out: [(set: String, iso: Int, url: URL)] = []
        for set in sets {
            let urls: [URL]
            switch set {
            case "samples": urls = RollScanner.rawFiles(in: samples) + RollScanner.rawFiles(in: apsC)
            case "stilllife": urls = RollScanner.rawFiles(in: M.corpus("imaging-resource-a7iv-wayback"))
            case "photographyblog": urls = RollScanner.rawFiles(in: M.corpus("photographyblog-a7iv"))
            case "gallery": urls = RollScanner.rawFiles(in: M.corpus("imaging-resource-a7iv-gallery"))
            default: urls = []
            }
            let dated = urls.map { url -> (set: String, iso: Int, url: URL) in (set, (try? ARWFrameInfo.read(from: url).iso ?? 0) ?? 0, url) }
            out += dated.sorted { ($0.iso, $0.url.lastPathComponent) < ($1.iso, $1.url.lastPathComponent) }
        }
        return out
    }

    /// The decoder RAW 9's route gives a file of the a7 IV by its mode, whatever its Exif model (the
    /// still life's and photographyblog's read MODEL-NAME).
    static func route(_ url: URL) -> DecoderChoice {
        guard let layout = try? ARWLayout.read(from: url) else { return .apple }
        return BodyProfile.a7IV.mode(for: layout)?.learned == true ? .raw9 : .apple
    }

    /// The develop's tile for a decoder version: RAW 9's 1024, RAW 8's 768.
    static func developTile(_ version: AppleDecoderVersion) -> Int? {
        version == .learned ? RollDeveloper.learnedDecodeTile : RollDeveloper.decodeTile
    }

    static func options(_ version: AppleDecoderVersion, longSide: Int? = nil, tile: Int? = nil) -> DecodeOptions {
        var options = DecodeOptions()
        options.appleDecoder = version
        options.maxLongSide = longSide
        options.tileSize = tile
        return options
    }

    static func hash(_ texture: MTLTexture) -> String {
        let pixels = ExposureAnalyzer.pixels(of: texture)
        return pixels.withUnsafeBytes { SHA256.hash(data: Data($0)) }.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Defaults and routing

    /// Every a7 IV file: the versions Apple's decoder offers it and whether RAW 9's route gives it RAW 9,
    /// RAW 9's and RAW 8's default luminance amounts against Argent's table, and which controls RAW 9
    /// offers; then copies of the lossless L sample with the Exif ISO rewritten at every third stop from
    /// 50 to 204800, which show the default follows the Exif ISO alone. And what opening a file in Core
    /// Image costs against reading its header, which is why the route reads the header.
    @Test(.enabled(if: enabled))
    func defaults() throws {
        var mismatches = 0, largest: Float = 0
        func line(_ label: String, _ url: URL) throws {
            let filter = try #require(CIRAWFilter(imageURL: url))
            let iso = AppleRawDecoder.isoSpeed(of: filter)
            let versions = filter.supportedDecoderVersions.map(\.rawValue)
            let offers = AppleRawDecoder.offers(.learned, filter), routed = Self.route(url) == .raw9
            if offers != routed { mismatches += 1 }
            let classic = filter.luminanceNoiseReductionAmount
            var text = String(format: "MEASURE defaults %@ %@ ISO %.0f: versions %@, default %@, RAW 9 %@ by its mode (%@); RAW 8 default %.4f",
                              label, url.lastPathComponent, iso ?? 0, versions.joined(separator: " "), filter.decoderVersion.rawValue,
                              routed ? "yes" : "no", offers == routed ? "agrees" : "DISAGREES", classic)
            if offers {
                filter.decoderVersion = AppleDecoderVersion.learned.coreImage
                let apple = filter.luminanceNoiseReductionAmount, table = NoiseReduction.learnedLuminanceAmount(iso: iso)
                largest = max(largest, abs(apple - table))
                text += String(format: "; RAW 9 default %.6f, table %.6f (%+.6f); offers luminance %@ colour %@ sharpness %@ contrast %@ detail %@ moire %@ lens %@ highlights %@",
                               apple, table, table - apple, "\(filter.isLuminanceNoiseReductionSupported)", "\(filter.isColorNoiseReductionSupported)",
                               "\(filter.isSharpnessSupported)", "\(filter.isContrastSupported)", "\(filter.isDetailSupported)",
                               "\(filter.isMoireReductionSupported)", "\(filter.isLensCorrectionSupported)", "\(filter.isHighlightRecoverySupported)")
            }
            print(text)
        }
        for (set, _, url) in Self.frames() { try line(set, url) }
        let folder = SyntheticRaw.folder.appendingPathComponent("raw9-iso-copies")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let thirds = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000,
                      6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000, 51200, 64000, 80000, 102400, 128000, 160000, 204800]
        for iso in thirds + [1100, 1800, 2900, 4500, 7200, 14400] {
            let copy = folder.appendingPathComponent("DSC06674-ISO\(iso).ARW")
            try DecoderSwitchMeasureTests.copyRaw(M.lossless, to: copy, iso: iso)
            try line("iso-copy", copy)
            try? FileManager.default.removeItem(at: copy)
        }
        // What the route's header read costs against opening the file in Core Image.
        let clock = ContinuousClock()
        var header: [Double] = [], opened: [Double] = []
        for (_, _, url) in Self.frames("samples,photographyblog") {
            var start = clock.now
            _ = try ARWLayout.read(from: url)
            header.append(FrameViewMeasureTests.ms(clock.now - start))
            start = clock.now
            _ = autoreleasepool { CIRAWFilter(imageURL: url)?.supportedDecoderVersions.count }
            opened.append(FrameViewMeasureTests.ms(clock.now - start))
        }
        print("MEASURE defaults: \(mismatches) files whose versions disagree with the route; largest |table - Apple's RAW 9 default| \(largest)")
        print("MEASURE defaults: header read \(FrameViewMeasureTests.summary(header)); Core Image open and versions \(FrameViewMeasureTests.summary(opened))")
    }

    /// The M2 gate's inputs, which must stay on RAW 8 so the frozen protocols hold: the FiveK cohort's
    /// DNGs and Cube++'s CR2s (ARGENT_GATE_ROOT, default the 2026-10-18 fetch), by the decoder RAW 9's
    /// route gives each and the version the harness's decode (Apple's decoder with its defaults) pins.
    @Test(.enabled(if: enabled))
    func gateInputs() throws {
        let root = URL(fileURLWithPath: Self.environment["ARGENT_GATE_ROOT"]
                       ?? NSHomeDirectory() + "/Documents/ArgentResearch/m2-fivek-20261018.noindex/downloads")
        for (name, folder, ext) in [("FiveK cohort", "fivek-cohort100/dng", "dng"), ("FiveK fit", "fivek-fit/dng", "dng"), ("Cube++", "cubepp/cr2", "cr2")] {
            let files = ((try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == ext }.sorted { $0.path < $1.path }
            var routes: [String: Int] = [:], pinned: [String: Int] = [:], offersNine = 0
            for url in files {
                autoreleasepool {
                    routes[DecoderChoice.of(url).rawValue, default: 0] += 1
                    guard let filter = CIRAWFilter(imageURL: url) else { pinned["unopened", default: 0] += 1; return }
                    if AppleRawDecoder.offers(.learned, filter) { offersNine += 1 }
                    let (pins, _) = AppleRawDecoder.configure(filter, options: DecodeOptions(), iso: AppleRawDecoder.isoSpeed(of: filter))
                    pinned[pins.decoderVersion, default: 0] += 1
                }
            }
            print("MEASURE gate inputs \(name): \(files.count) files; RAW 9's route gives \(routes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")); the harness pins version \(pinned.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")); \(offersNine) offer RAW 9")
        }
    }

    // MARK: Colour, exposure and saturated colours

    /// Statistics of one decode against another of the same frame and size, on 16-pixel blocks.
    struct Comparison {
        var level = 0.0, levelP95 = 0.0, wholeLevel = 0.0
        var redGreen = 0.0, redGreenP5 = 0.0, redGreenP95 = 0.0, blueGreen = 0.0, blueGreenP5 = 0.0, blueGreenP95 = 0.0
        var blocks = 0
        /// CIEDE2000 between the two on the mid-tone blocks, scene-linear light with mid-gray at 0.18
        /// read with white at 1: the median and the 95th percentile.
        var deltaE = 0.0, deltaEP95 = 0.0
        /// The brightest 16-pixel block's luminance in each, the highlights' ceiling.
        var ceiling = 0.0, otherCeiling = 0.0
        /// Blocks of the reference outside sRGB, the other's outside sRGB, and the other's chroma over
        /// the reference's on the reference's outside blocks (median), with their median hue difference.
        var outside = 0, otherOutside = 0, outsideChroma = 0.0, outsideHue = 0.0
    }

    /// `b` against `a`: level in stops on mid-tone blocks (both channels over 0.005, luminance under
    /// 0.9), red and blue against green, and the colours outside sRGB, Rec. 2020 linear blocks whose
    /// sRGB has a channel under -2 % of its largest.
    static func compare(_ a: MTLTexture, _ b: MTLTexture) -> Comparison {
        let pa = Pixels(a), pb = Pixels(b)
        let ma = pa.blockMeans(16, clipAbove: .infinity), mb = pb.blockMeans(16, clipAbove: .infinity)
        let luma = SIMD3<Double>(0.2627, 0.6780, 0.0593)
        func srgb(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(1.660491 * v.x - 0.587641 * v.y - 0.072850 * v.z, -0.124550 * v.x + 1.132900 * v.y - 0.008349 * v.z,
                  -0.018151 * v.x - 0.100579 * v.y + 1.118730 * v.z)
        }
        func outside(_ v: SIMD3<Double>) -> Bool { let s = srgb(v); return s.min() < -0.02 * s.max() && s.max() > 0.01 }
        var level: [Double] = [], rg: [Double] = [], bg: [Double] = [], chroma: [Double] = [], hue: [Double] = [], de: [Double] = []
        var sa = SIMD3<Double>(repeating: 0), sb = SIMD3<Double>(repeating: 0)
        var c = Comparison()
        for i in ma.indices {
            guard let p = ma[i], let q = mb[i] else { continue }
            sa += p; sb += q
            if outside(p) {
                c.outside += 1
                let la = Colour.lab(p), lb = Colour.lab(q)
                let ca = (la.y * la.y + la.z * la.z).squareRoot(), cb = (lb.y * lb.y + lb.z * lb.z).squareRoot()
                if ca > 1 {
                    chroma.append(cb / ca)
                    var dh = (atan2(lb.z, lb.y) - atan2(la.z, la.y)) * 180 / .pi
                    if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
                    hue.append(dh)
                }
            }
            if outside(q) { c.otherOutside += 1 }
            let ya = (p * luma).sum(), yb = (q * luma).sum()
            c.ceiling = max(c.ceiling, ya)
            c.otherCeiling = max(c.otherCeiling, yb)
            guard p.min() > 0.005, q.min() > 0.005, ya < 0.9 else { continue }
            level.append(log2(yb / ya))
            rg.append(log2((q.x / q.y) / (p.x / p.y)))
            bg.append(log2((q.z / q.y) / (p.z / p.y)))
            if ya > 0.18 / 8, ya < 0.18 * 4 { de.append(Colour.deltaE2000(Colour.lab(p), Colour.lab(q))) }
        }
        func q(_ v: [Double], _ p: Double) -> Double { Stats.percentile(v, p) }
        c.blocks = level.count
        c.level = q(level, 0.5); c.levelP95 = q(level.map(abs), 0.95)
        c.wholeLevel = log2((sb * luma).sum() / (sa * luma).sum())
        c.redGreen = q(rg, 0.5); c.redGreenP5 = q(rg, 0.05); c.redGreenP95 = q(rg, 0.95)
        c.blueGreen = q(bg, 0.5); c.blueGreenP5 = q(bg, 0.05); c.blueGreenP95 = q(bg, 0.95)
        c.deltaE = de.isEmpty ? .nan : q(de, 0.5); c.deltaEP95 = de.isEmpty ? .nan : q(de, 0.95)
        c.outsideChroma = chroma.isEmpty ? .nan : q(chroma, 0.5)
        c.outsideHue = hue.isEmpty ? .nan : q(hue, 0.5)
        return c
    }

    static func describe(_ c: Comparison) -> String {
        String(format: "level %+.4f (|p95| %.3f, whole %+.4f) stops; red/green %+.4f (p5 %+.3f, p95 %+.3f), blue/green %+.4f (p5 %+.3f, p95 %+.3f) over %d blocks; mid-tone dE2000 median %.2f, p95 %.2f; outside sRGB %d blocks (RAW 9 %d), chroma %.3f of RAW 8's, hue %+.1f degrees; brightest block %.2f (RAW 9 %.2f)",
               c.level, c.levelP95, c.wholeLevel, c.redGreen, c.redGreenP5, c.redGreenP95, c.blueGreen, c.blueGreenP5, c.blueGreenP95,
               c.blocks, c.deltaE, c.deltaEP95, c.outside, c.otherOutside, c.outsideChroma, c.outsideHue, c.ceiling, c.otherCeiling)
    }

    /// RAW 9 against RAW 8, both with Argent's production pins, at full size (the develop's decode, in
    /// its 768-pixel tiles) and at the sheet's 960 pixels (Auto's measurement), on every a7 IV frame:
    /// exposure, colour and saturated colours (docs/decoder.md section 18), each full-size decode in its
    /// decoder's develop tiles. The level is the exposure anchor's check: RAW 9 at 0.18 where RAW 8 is.
    /// ARGENT_SIZES (default full,960) picks the sizes.
    @Test(.enabled(if: enabled))
    func colour() throws {
        let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
        let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let sizes = (Self.environment["ARGENT_SIZES"] ?? "full,960").split(separator: ",").map { Int($0) }
        var bySet: [String: [Comparison]] = [:]
        var levels: [Int: [Double]] = [:]
        for (set, iso, url) in Self.frames() where Self.route(url) == .raw9 {
            for side in sizes {
                try autoreleasepool {
                    let full = side == nil
                    let classic = try decoder.decode(url, options: Self.options(.classic, longSide: side, tile: full ? Self.developTile(.classic) : nil))
                    let learned = try decoder.decode(url, options: Self.options(.learned, longSide: side, tile: full ? Self.developTile(.learned) : nil))
                    let c = Self.compare(classic.texture, learned.texture)
                    let label = side.map(String.init) ?? "full"
                    bySet["\(set) \(label)", default: []].append(c)
                    if side == nil { levels[iso, default: []].append(c.level) }
                    print("MEASURE colour \(set) \(url.lastPathComponent) ISO \(iso) at \(label) (\(learned.width)x\(learned.height)), RAW 9 against RAW 8: \(Self.describe(c))")
                }
            }
        }
        for (key, list) in bySet.sorted(by: { $0.key < $1.key }) {
            func range(_ v: [Double]) -> String { String(format: "%+.4f to %+.4f (median %+.4f)", v.min() ?? .nan, v.max() ?? .nan, Stats.percentile(v, 0.5)) }
            print("MEASURE colour summary \(key), \(list.count) frames: level \(range(list.map(\.level))); red/green \(range(list.map(\.redGreen))); blue/green \(range(list.map(\.blueGreen))); mid-tone dE2000 \(range(list.map(\.deltaE).filter { !$0.isNaN })); outside-sRGB chroma \(range(list.map(\.outsideChroma).filter { !$0.isNaN })); outside-sRGB blocks RAW 8 \(list.map(\.outside).reduce(0, +)), RAW 9 \(list.map(\.otherOutside).reduce(0, +))")
        }
        for (iso, list) in levels.sorted(by: { $0.key < $1.key }) {
            print(String(format: "MEASURE anchor ISO %d: RAW 9's level against RAW 8's at full size, median %+.4f stops over %d frames", iso, Stats.percentile(list, 0.5), list.count))
        }
    }

    // MARK: Tiles, speed and memory

    /// A full-size RAW 9 decode whole and in square tiles of ARGENT_TILES (default 0, whole, then 512 to
    /// 3072) as a develop runs it, a Core Image context a decode: the warm median time, the footprint's
    /// peak above the start and the tiles' pixels against the whole decode's (the first in the list).
    /// RAW 8's in the develop's tiles and whole beside.
    @Test(.enabled(if: enabled))
    func tiles() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let files = ProvenanceMeasureTests.files().isEmpty ? [M.lossless, SyntheticRaw.base] : ProvenanceMeasureTests.files()
        let tiles = (Self.environment["ARGENT_TILES"] ?? "0,512,768,1024,1536,2048,3072").split(separator: ",").compactMap { Int($0) }
        let clock = ContinuousClock()
        for url in files {
            var whole: [Float16]?
            let configurations: [(AppleDecoderVersion, Int)] = tiles.map { (AppleDecoderVersion.learned, $0) } + [(.classic, 768), (.classic, 0)]
            for (version, tile) in configurations {
                let options = Self.options(version, tile: tile > 0 ? tile : nil)
                // Once to warm the decoder at this size, then three timed.
                try autoreleasepool { _ = try decoder.decode(url, options: options) }
                var times: [Double] = [], peaks: [Int] = []
                var pixels: [Float16] = []
                for _ in 0..<3 {
                    try autoreleasepool {
                        let base = physicalFootprint()
                        resetFootprintPeak()
                        let start = clock.now
                        let frame = try decoder.decode(url, options: options)
                        times.append(FrameViewMeasureTests.ms(clock.now - start))
                        peaks.append(max(footprintPeakSinceReset(), physicalFootprint()) - base)
                        if pixels.isEmpty { pixels = ExposureAnalyzer.pixels(of: frame.texture) }
                    }
                }
                var difference = "the reference"
                if version == .learned {
                    if tile == 0 { whole = pixels } else if let whole, whole.count == pixels.count {
                        var differing = 0, largest = 0.0, largestStops = 0.0
                        for i in pixels.indices where i % 4 != 3 && pixels[i] != whole[i] {
                            differing += 1
                            let a = Double(whole[i]), b = Double(pixels[i])
                            largest = max(largest, abs(a - b))
                            if a > 0.01, b > 0.01 { largestStops = max(largestStops, abs(log2(b / a))) }
                        }
                        difference = String(format: "%d of %d samples differ from the whole decode, largest %.5f (%.4f stops above 0.01)",
                                            differing, pixels.count / 4 * 3, largest, largestStops)
                    }
                } else { difference = "RAW 8" }
                print(String(format: "MEASURE tiles %@ RAW %@ %@: %@; peak above the start %@ MB; %@", url.lastPathComponent, version.rawValue,
                             tile > 0 ? "\(tile)-pixel tiles" : "whole", FrameViewMeasureTests.summary(times),
                             peaks.map { String($0 >> 20) }.joined(separator: ", "), difference))
            }
        }
    }

    /// Direct pixel comparison of full-size RAW 9 decodes at 1024-pixel tiles against 2048-pixel
    /// tiles on the CC0 lossless L and uncompressed samples, and the removal patch seam check in
    /// both directions (patch cut at 1024 laid into 2048 and the reverse, straddling tile seams).
    @Test(.enabled(if: enabled))
    func tiles1024Against2048AndRemovalSeam() async throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let stock = try Stock.load(from: DecoderSwitchMeasureTests.stocks.appendingPathComponent("kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let encoder = try ImageEncoder(gpu: gpu)
        let files = ProvenanceMeasureTests.files().isEmpty ? [M.lossless, SyntheticRaw.base] : ProvenanceMeasureTests.files()
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        func halfSteps(_ a: Float16, _ b: Float16) -> Double {
            guard a != b else { return 0 }
            let step = Double(a.nextUp - a)
            return step > 0 ? abs(Double(b) - Double(a)) / step : .infinity
        }

        for url in files {
            var opt1024 = Self.options(.learned, tile: 1024)
            opt1024.lensCorrection = false
            var opt2048 = Self.options(.learned, tile: 2048)
            opt2048.lensCorrection = false
            let d1024 = try decoder.decode(url, options: opt1024)
            let d2048 = try decoder.decode(url, options: opt2048)
            let p1024 = ExposureAnalyzer.pixels(of: d1024.texture)
            let p2048 = ExposureAnalyzer.pixels(of: d2048.texture)
            try #require(p1024.count == p2048.count && d1024.width == d2048.width && d1024.height == d2048.height)

            let w = d1024.width, h = d1024.height
            var differing = 0, largest = 0.0, largestStops = 0.0, largestSteps = 0.0, near1024Seam = 0, elsewhere = 0
            var worstPoint = (x: w / 2, y: h / 2)
            for idx in stride(from: 0, to: p1024.count, by: 4) {
                let pixel = idx / 4
                let px = pixel % w, py = h - 1 - pixel / w
                let dx = min(px % 1024, 1024 - 1 - px % 1024), dy = min(py % 1024, 1024 - 1 - py % 1024)
                let near = min(dx, dy) < 8
                for c in 0..<3 {
                    let a = p1024[idx + c], b = p2048[idx + c]
                    guard a != b else { continue }
                    differing += 1
                    if near { near1024Seam += 1 } else { elsewhere += 1 }
                    let da = Double(a), db = Double(b)
                    largest = max(largest, abs(da - db))
                    if da > 0.01, db > 0.01 {
                        let stops = abs(log2(db / da))
                        if stops > largestStops {
                            largestStops = stops
                            worstPoint = (px, py)
                        }
                    }
                    largestSteps = max(largestSteps, halfSteps(a, b))
                }
            }
            let totalSamples = w * h * 3
            print(String(format: "MEASURE tiles-1024-vs-2048 %@ (%dx%d): %d of %d samples differ (%.4f%%), largest %.5f (%.4f stops above 0.01 at %d,%d, %.2f half-float steps); near 1024 seam (<8px) %d, elsewhere %d",
                         url.lastPathComponent, w, h, differing, totalSamples, 100 * Double(differing) / Double(totalSamples),
                         largest, largestStops, worstPoint.x, worstPoint.y, largestSteps, near1024Seam, elsewhere))

            // Removal seam check: two 640x640 crops straddling tile boundaries plus one centered so the
            // feather edge passes through the pixel with the largest 1024-vs-2048 stop difference.
            let worstX = min(max(worstPoint.x - 320 + 100, 0), w - 640)
            let worstY = min(max(worstPoint.y - 320, 0), h - 640)
            let boxes = [
                ("seam-1024x1024", try RemovalPatch.Box(x: 704, y: 704, width: 640, height: 640)),
                ("seam-3072x2048", try RemovalPatch.Box(x: 2752, y: 1728, width: 640, height: 640)),
                ("worst-edge-\(worstPoint.x)x\(worstPoint.y)", try RemovalPatch.Box(x: worstX, y: worstY, width: 640, height: 640)),
            ]
            let decodes: [Int: LinearFrame] = [1024: d1024, 2048: d2048]
            let lensBase = LensResolver.correction(for: url, settings: .default)
            let renderSettings = DevelopSettings(grain: 0, grainSeed: 0, halation: true, sharpen: true)

            for (boxLabel, box) in boxes {
                // Centered disc object mask of radius 100 px inside the 640x640 box so the object and its
                // feather straddle the tile boundary.
                var object = [UInt8](repeating: 0, count: box.width * box.height)
                for y in 0..<box.height {
                    for x in 0..<box.width {
                        let d = hypot(Double(x) + 0.5 - Double(box.width) / 2, Double(y) + 0.5 - Double(box.height) / 2)
                        if d <= 100 { object[y * box.width + x] = 255 }
                    }
                }
                let plan = try RemovalPipeline.Plan(box: box, object: object, frameWidth: w, frameHeight: h)

                let baseStage = try LensStage(gpu: gpu)
                var crops: [Int: RemovalPipeline.Crop] = [:]
                var preparedByTile: [Int: RemovalPipeline.Prepared] = [:]
                var patchesByTile: [Int: RemovalPatch] = [:]
                var identityPatches: [Int: RemovalPatch] = [:]
                for tile in [1024, 2048] {
                    let frame = decodes[tile]!
                    let rgb = try baseStage.removalInput(frame, removals: [], box: box)
                    let crop = try RemovalPipeline.Crop(box: box, rgb: rgb, decoder: frame.decoderVersion)
                    crops[tile] = crop
                    let prepared = try RemovalPipeline.prepare(crop, plan: plan, seed: 42)
                    preparedByTile[tile] = prepared
                    let output = try await FakeRemovalEngine().run(prepared.job) { _, _ in }
                    let patch = try RemovalPipeline.finish(output, prepared: prepared, faces: [])
                    patchesByTile[tile] = patch
                    // Identity-filled patch holding tile's own surround pixels with the real feather alphas,
                    // isolating cross-tile mismatch across the feather seam with no model variance.
                    identityPatches[tile] = try RemovalPatch(box: box, width: box.width, height: box.height, rgb: rgb,
                                                             objectAlpha: patch.objectAlpha, effectsAlpha: patch.effectsAlpha)
                }

                for (cutTile, targetTile) in [(1024, 2048), (2048, 1024)] {
                    let targetDecode = decodes[targetTile]!

                    // 1. Identity-fill cross-tile composite vs unmodified target decode over the box & feather.
                    let idPatch = identityPatches[cutTile]!
                    let idStage = try LensStage(gpu: gpu, patches: FixedPatchSource([idPatch]))
                    let idLaid = try idStage.correct(targetDecode, with: ResolvedLensCorrection.identity.removing([Removal(patch: idPatch.ref)]))
                    let idPixels = ExposureAnalyzer.pixels(of: idLaid.texture)
                    let targetPixels = targetTile == 1024 ? p1024 : p2048
                    var idDiff = 0, idStops = 0.0, idMaxAbs = 0.0, idMaxSteps = 0.0
                    var featherDiff = 0, featherTotal = 0, featherStops = 0.0, featherSteps = 0.0
                    for y in 0..<box.height {
                        for x in 0..<box.width {
                            let alpha = idPatch.effectsAlpha[y * box.width + x]
                            let isFeather = alpha > 0 && alpha < 255
                            if isFeather { featherTotal += 3 }
                            let fy = box.y + y, fx = box.x + x
                            let idx = ((h - 1 - fy) * w + fx) * 4
                            for c in 0..<3 {
                                let a = targetPixels[idx + c], b = idPixels[idx + c]
                                guard a != b else { continue }
                                idDiff += 1
                                let da = Double(a), db = Double(b)
                                idMaxAbs = max(idMaxAbs, abs(da - db))
                                let stops = (da > 0.01 && db > 0.01) ? abs(log2(db / da)) : 0
                                let steps = halfSteps(a, b)
                                idStops = max(idStops, stops)
                                idMaxSteps = max(idMaxSteps, steps)
                                if isFeather {
                                    featherDiff += 1
                                    featherStops = max(featherStops, stops)
                                    featherSteps = max(featherSteps, steps)
                                }
                            }
                        }
                    }

                    // 2. Real pipeline patch cut at cutTile laid into targetTile, vs patch cut at targetTile laid into targetTile.
                    // Compare both linear scene and film-rendered 16-bit sRGB (dE2000).
                    let cutPatch = patchesByTile[cutTile]!
                    let targetPatch = patchesByTile[targetTile]!
                    let crossStage = try LensStage(gpu: gpu, patches: FixedPatchSource([cutPatch]))
                    let ownStage = try LensStage(gpu: gpu, patches: FixedPatchSource([targetPatch]))
                    let crossScene = try crossStage.correct(targetDecode, with: lensBase.removing([Removal(patch: cutPatch.ref)]))
                    let ownScene = try ownStage.correct(targetDecode, with: lensBase.removing([Removal(patch: targetPatch.ref)]))
                    let crossLinear = ExposureAnalyzer.pixels(of: crossScene.texture)
                    let ownLinear = ExposureAnalyzer.pixels(of: ownScene.texture)
                    var sceneDiff = 0, sceneMaxStops = 0.0, sceneMaxSteps = 0.0, sceneMaxRel = 0.0
                    for y in 0..<box.height {
                        for x in 0..<box.width {
                            let fy = box.y + y, fx = box.x + x
                            let idx = ((h - 1 - fy) * w + fx) * 4
                            for c in 0..<3 {
                                let a = ownLinear[idx + c], b = crossLinear[idx + c]
                                guard a != b else { continue }
                                sceneDiff += 1
                                let da = Double(a), db = Double(b)
                                if da > 0.01, db > 0.01 { sceneMaxStops = max(sceneMaxStops, abs(log2(db / da))) }
                                sceneMaxSteps = max(sceneMaxSteps, halfSteps(a, b))
                                sceneMaxRel = max(sceneMaxRel, abs(db - da) / (abs(da) + 0.01))
                            }
                        }
                    }
                    // Render both through Portra 400 to 16-bit sRGB and compute dE2000 over the crop region.
                    let crossFilm = try renderer.render(crossScene, settings: renderSettings)
                    let ownFilm = try renderer.render(ownScene, settings: renderSettings)
                    let crossPic = try encoder.picture(crossFilm.image.texture, colorSpace: gpu.workingColorSpace, format: .tiff16, space: .sRGB)
                    let ownPic = try encoder.picture(ownFilm.image.texture, colorSpace: gpu.workingColorSpace, format: .tiff16, space: .sRGB)
                    let crossFile = root.appendingPathComponent("cross-\(boxLabel)-\(cutTile)-\(targetTile).tif")
                    let ownFile = root.appendingPathComponent("own-\(boxLabel)-\(cutTile)-\(targetTile).tif")
                    try encoder.write(crossPic, to: crossFile, format: .tiff16, metadataFrom: url, software: "measure")
                    try encoder.write(ownPic, to: ownFile, format: .tiff16, metadataFrom: url, software: "measure")
                    let crossRGB = try #require(PerformanceTargetMeasureTests.pixels(crossFile))
                    let ownRGB = try #require(PerformanceTargetMeasureTests.pixels(ownFile))
                    try? FileManager.default.removeItem(at: crossFile)
                    try? FileManager.default.removeItem(at: ownFile)
                    var boxCross: [UInt16] = [], boxOwn: [UInt16] = []
                    boxCross.reserveCapacity(box.width * box.height * 4)
                    boxOwn.reserveCapacity(box.width * box.height * 4)
                    for y in box.y..<(box.y + box.height) {
                        for x in box.x..<(box.x + box.width) {
                            let i = (y * crossRGB.width + x) * 4
                            boxCross += crossRGB.values[i..<(i + 4)]
                            boxOwn += ownRGB.values[i..<(i + 4)]
                        }
                    }
                    let de = PerformanceTargetMeasureTests.deltaE(boxCross, boxOwn)
                    let boxSamples = box.width * box.height * 3
                    print(String(format: "MEASURE removal-seam %@ %@ cut %d -> laid %d: identity-patch %d/%d diff (max %.5f, %.4f stops, %.2f half-steps; feather %d/%d diff, %.4f stops, %.2f half-steps); pipeline-patch vs own %d/%d diff (max %.4f stops, %.2f half-steps, rel %.5f); film dE2000 over box mean %.4f p95 %.2f p99 %.2f max %.2f (%.4f%% identical)",
                                 url.lastPathComponent, boxLabel, cutTile, targetTile,
                                 idDiff, boxSamples, idMaxAbs, idStops, idMaxSteps,
                                 featherDiff, featherTotal, featherStops, featherSteps,
                                 sceneDiff, boxSamples, sceneMaxStops, sceneMaxSteps, sceneMaxRel,
                                 de.mean, de.p95, de.p99, de.max, 100 * de.same))
                }
            }
        }
    }

    /// RAW 9's speed in the app's paths, beside RAW 8's and the in-house decoder's, on the lossless L
    /// sample (or ARGENT_FILES), each decode in a Core Image context of its own as the app decodes: the
    /// sheet's 960 pixels, the frame view's 2190 filled, a full-size decode in the develop's tiles and the
    /// frame view's refinement (the same, area-resized to 2190), warm medians of ARGENT_REPEAT (5) after
    /// the process's first, which is the cold one; then two at once on two threads, frames a second, at
    /// 960 and in the develop's tiles. ARGENT_PARTS picks the parts, comma separated (default `sheet`,
    /// `view`, `tiles`, `whole`, `refine`, `inhouse`, `two`); `sheetshared` decodes the sheet through one
    /// shared context, after which a context of its own renders a tiled decode 1.6 to 3.2 times as slowly;
    /// `renew` renews the shared contexts, `display` makes pictures through the shared context, and
    /// `footprint` prints it, for that measurement.
    @Test(.enabled(if: enabled))
    func speed() throws {
        let parts = Set((Self.environment["ARGENT_PARTS"] ?? "sheet,view,tiles,whole,refine,inhouse,two").split(separator: ",").map(String.init))
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let shared = AppleRawDecoder(gpu: gpu)
        let inHouse = try InHouseDecoder(gpu: gpu)
        let resize = try AreaResize(gpu: gpu)
        let repeats = Self.environment["ARGENT_REPEAT"].flatMap(Int.init) ?? 5
        let files = ProvenanceMeasureTests.files().isEmpty ? [M.lossless] : ProvenanceMeasureTests.files()
        let clock = ContinuousClock()
        for url in files {
            var cold: Double?
            func time(_ label: String, _ work: () throws -> Void) rethrows {
                var times: [Double] = []
                for pass in 0...repeats {
                    try autoreleasepool {
                        let start = clock.now
                        try work()
                        let ms = FrameViewMeasureTests.ms(clock.now - start)
                        if pass == 0 { if cold == nil { cold = ms } } else { times.append(ms) }
                    }
                }
                print("MEASURE speed \(url.lastPathComponent) \(label): \(FrameViewMeasureTests.summary(times))")
            }
            var frameView = DecodeOptions()
            frameView.maxLongSide = 2190
            frameView.fillsMaxLongSide = true
            for version in [AppleDecoderVersion.learned, .classic] {
                let name = "RAW \(version.rawValue)"
                if parts.contains("sheet") {
                    try time("\(name) sheet 960") { _ = try apple.decode(url, options: Self.options(version, longSide: 960)) }
                }
                if parts.contains("sheetshared") {
                    try time("\(name) sheet 960, one shared context") { _ = try shared.decode(url, options: Self.options(version, longSide: 960)) }
                }
                if parts.contains("display") {
                    // Pictures for the screen through the shared context, as the previews make them, from a decode of its own.
                    let frame = try apple.decode(url, options: Self.options(version, longSide: 2190))
                    let image = try #require(CIImage(mtlTexture: frame.texture, options: [.colorSpace: gpu.workingColorSpace]))
                    for _ in 0..<5 {
                        _ = gpu.ciContext.createCGImage(image, from: image.extent, format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, deferred: false)
                    }
                    print("MEASURE speed made five pictures through the shared context")
                }
                if parts.contains("renew") {
                    gpu.renewContext()
                    print("MEASURE speed renewed the shared contexts, footprint \(physicalFootprint() >> 20) MB")
                }
                if parts.contains("footprint") { print("MEASURE speed footprint \(physicalFootprint() >> 20) MB, Metal \(gpu.device.currentAllocatedSize >> 20) MB") }
                if version == .learned, let cold { print(String(format: "MEASURE speed %@ RAW 9 cold, the process's first decode: %.1f ms", url.lastPathComponent, cold)) }
                var view = frameView
                view.appleDecoder = version
                if parts.contains("view") { try time("\(name) frame view 2190") { _ = try apple.decode(url, options: view) } }
                if parts.contains("tiles") {
                    try time("\(name) full size, develop's tiles") { _ = try apple.decode(url, options: Self.options(version, tile: Self.developTile(version))) }
                }
                if parts.contains("whole") { try time("\(name) full size whole") { _ = try apple.decode(url, options: Self.options(version)) } }
                if parts.contains("refine") {
                    try time("\(name) refinement to 2190") {
                        _ = try apple.decode(url, options: Self.options(version, tile: Self.developTile(version)), areaResizedTo: (2190, 1460),
                                             using: resize, stopped: { false })
                    }
                }
            }
            if parts.contains("inhouse"), InHouseDecoder.supports(url) {
                try time("in-house sheet 960") { _ = try inHouse.decode(url, options: Self.options(.classic, longSide: 960)) }
                try time("in-house frame view 2190") { _ = try inHouse.decode(url, options: frameView) }
                try time("in-house full size") { _ = try inHouse.decode(url, options: DecodeOptions()) }
            }
            // Two at once, each thread its own decodes, as the sheet's two decode lanes and the develop's two run;
            // with `twotiles`, RAW 9 full size in each of ARGENT_TILES (0 whole), one and two at once.
            var cases: [(String, DecodeOptions, AppleRawDecoder)] = []
            if parts.contains("twotiles") {
                for tile in (Self.environment["ARGENT_TILES"] ?? "0,768,1024,1536,2048").split(separator: ",").compactMap({ Int($0) }) {
                    cases.append(("RAW 9 full size \(tile > 0 ? "in \(tile)-pixel tiles" : "whole")", Self.options(.learned, tile: tile > 0 ? tile : nil), apple))
                }
            }
            for (label, options, decoder) in cases + (!parts.contains("two") ? [] : [("RAW 9 sheet 960", Self.options(.learned, longSide: 960), apple),
                                              ("RAW 9 full size, develop's tiles", Self.options(.learned, tile: RollDeveloper.learnedDecodeTile), apple),
                                              ("RAW 8 sheet 960", Self.options(.classic, longSide: 960), apple),
                                              ("RAW 8 full size, develop's tiles", Self.options(.classic, tile: RollDeveloper.decodeTile), apple)]) {
                let each = 4
                let box = UncheckedBox(decoder)
                let base = physicalFootprint()
                resetFootprintPeak()
                let start = clock.now
                DispatchQueue.concurrentPerform(iterations: 2) { _ in
                    for _ in 0..<each { autoreleasepool { _ = try? box.value.decode(url, options: options) } }
                }
                let seconds = FrameViewMeasureTests.ms(clock.now - start) / 1000
                print(String(format: "MEASURE speed %@ %@, two at once: %.2f frames a second (%d in %.1f s), peak %d MB above the start",
                             url.lastPathComponent, label, Double(2 * each) / seconds, 2 * each, seconds,
                             (max(footprintPeakSinceReset(), physicalFootprint()) - base) >> 20))
            }
        }
    }

    // MARK: Auto

    /// How much light a dark frame's RAW 9 decode makes of its noise (docs/M3-auto.md section 16): the CC0
    /// scene darkened ARGENT_STOPS (-3.5) in the raw with the a7 IV's noise at ISO 250 to 102400
    /// (`SyntheticRaw.simulated`), at the sheet's 960 pixels, the level and cast as the analysis reads
    /// them with no noise taken out, beside RAW 8's with and without its `DecodedNoise`. A decode that
    /// lifts no noise reads the same level at every ISO.
    @Test(.enabled(if: enabled))
    func darkLevel() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        func cast(_ a: ExposureAnalysis) -> String {
            let c = AutoBalance.cast(a)
            return String(format: "%+.1f mired, green %+.3f", AutoBalance.mired(c), AutoBalance.axes(c).greenMagenta)
        }
        for stops in (Self.environment["ARGENT_STOPS"] ?? "-3.5").split(separator: ",").compactMap({ Double($0) }) {
            var first: (raw9: Float, raw8: Float, shipped: Float)?
            for iso in ProvenanceMeasureTests.isos([250, 1600, 6400, 12800, 25600, 51200, 102400]) {
                let url = try SyntheticRaw.simulated(iso: iso, stops: stops)
                defer { try? FileManager.default.removeItem(at: url) }
                let info = try ARWFrameInfo.read(from: url)
                let learned = try decoder.decode(url, options: Self.options(.learned, longSide: FilmPreviews.previewLongSide))
                let classic = try decoder.decode(url, options: Self.options(.classic, longSide: FilmPreviews.previewLongSide))
                let a = ExposureAnalyzer.analyze(learned, info: info)
                let raw8 = ExposureAnalyzer.analyze(pixels: ExposureAnalyzer.pixels(of: classic.texture), width: classic.width, height: classic.height)
                let shipped = ExposureAnalyzer.analyze(classic, info: info)
                let noise = DecodedNoise.appleDecode(model: info.model, iso: info.iso, pins: learned.pins)
                if first == nil { first = (a.meanStops, raw8.meanStops, shipped.meanStops) }
                let f = first!
                print(String(format: "MEASURE dark level (%.1f stops) ISO %6d: RAW 9 %+.3f (from ISO 250 %+.3f; %@; noise model %@); RAW 8 noise left in %+.3f (%+.3f; %@), noise taken out %+.3f (%+.3f; %@)",
                             stops, iso, a.meanStops, a.meanStops - f.raw9, cast(a), noise == nil ? "none" : "applied",
                             raw8.meanStops, raw8.meanStops - f.raw8, cast(raw8), shipped.meanStops, shipped.meanStops - f.shipped, cast(shipped)))
            }
        }
    }

    /// Auto's aims on every a7 IV frame here, measured as the app measures them, from the sheet's
    /// 960-pixel decode of each, on the three routes: RAW 9's (the app's now), M8's (in-house to ISO 3200,
    /// RAW 8 above) and RAW 8 alone. Each folder is a roll, its frames' aims smoothed as the app smooths
    /// them (`RollSmoothing`); the print level in stops and the lab balance's two axes, and RAW 9's
    /// against each of the others. The still life's and photographyblog's frames are copies with the
    /// model written back, so they route and measure as the owner's files.
    @Test(.enabled(if: enabled))
    func autoAims() async throws {
        let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
        let routes: [DecoderRoute] = [.raw9, .inHouse, .apple]
        let decoders = routes.map { ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: $0), inHouseAtOnce: 1) }
        var bySet: [String: [(name: String, iso: Int, url: URL)]] = [:]
        for (set, iso, url) in Self.frames() {
            let copy = try DecoderCoverageMeasureTests.asA7IV(url)
            bySet[set, default: []].append((url.lastPathComponent, iso, copy))
        }
        defer { for list in bySet.values { for f in list where f.url.path.hasPrefix(SyntheticRaw.root.path) { try? FileManager.default.removeItem(at: f.url) } } }
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        var deltas: [String: [(level: Float, mired: Float, green: Float)]] = [:]
        for (set, list) in bySet.sorted(by: { $0.key < $1.key }) {
            // The set as one roll, in its order by ISO.
            let frames = try list.enumerated().map { index, entry -> Frame in
                Frame(id: index, url: entry.url, info: try ARWFrameInfo.read(from: entry.url))
            }
            var analyses: [[URL: ExposureAnalysis]] = Array(repeating: [:], count: routes.count)
            var used: [[URL: DecoderChoice]] = Array(repeating: [:], count: routes.count)
            for frame in frames {
                for (r, decoder) in decoders.enumerated() {
                    try autoreleasepool {
                        let decoded = try decoder.decode(frame.url, options: options)
                        analyses[r][frame.url] = ExposureAnalyzer.analyze(decoded, workingSpace: gpu.workingColorSpace, info: frame.info)
                        used[r][frame.url] = DecoderChoice.of(decoded)
                    }
                }
            }
            let aims = analyses.map { RollSmoothing.aims(frames, analyses: $0) }
            for (index, frame) in frames.enumerated() {
                func axes(_ r: Int) -> (level: Float, mired: Float, green: Float) {
                    let aim = aims[r][frame.url] ?? PrintAim()
                    let correction = AutoBalance.axes(AutoBalance.correction(for: aim.cast))
                    return (aim.level, correction.redBlue / AutoBalance.stopsPerMired, correction.greenMagenta)
                }
                let a = axes(0), b = axes(1), c = axes(2)
                let own = analyses.map { AutoPrint.levelStops($0[frame.url]) }
                deltas["\(set) against M8's route", default: []].append((a.level - b.level, a.mired - b.mired, a.green - b.green))
                deltas["\(set) against RAW 8", default: []].append((a.level - c.level, a.mired - c.mired, a.green - c.green))
                if used[1][frame.url] == .inHouse {
                    deltas["\(set) against M8's route, its in-house frames", default: []].append((a.level - b.level, a.mired - b.mired, a.green - b.green))
                }
                print(String(format: "MEASURE auto %@ %@ ISO %d (%@ / %@ / %@): print level %+.3f, %+.3f, %+.3f stops (own %+.3f, %+.3f, %+.3f); lab balance %+.1f, %+.1f, %+.1f mired, green-magenta %+.3f, %+.3f, %+.3f stops",
                             set, list[index].name, list[index].iso, used[0][frame.url]?.rawValue ?? "?", used[1][frame.url]?.rawValue ?? "?",
                             used[2][frame.url]?.rawValue ?? "?", a.level, b.level, c.level, own[0], own[1], own[2],
                             a.mired, b.mired, c.mired, a.green, b.green, c.green))
            }
        }
        for (key, list) in deltas.sorted(by: { $0.key < $1.key }) {
            func spread(_ v: [Float]) -> String {
                let s = v.map(abs).sorted()
                return String(format: "median %.3f, largest %.3f", s[s.count / 2], s.last!)
            }
            print("MEASURE auto RAW 9 \(key), \(list.count) frames: print level \(spread(list.map(\.level))) stops; red-blue \(spread(list.map(\.mired))) mired; green-magenta \(spread(list.map(\.green))) stops")
        }
    }

    // MARK: Previews

    /// RAW 9's scaled decodes against its full-size develop area-resized to the same pixels, rendered as
    /// the sheet and the frame view render them (Portra 400, capture sharpening): the three detail bands'
    /// amplitude, in draft mode with its scaling mask, as RAW 8's previews run, and without draft mode, with
    /// no mask (docs/M3-auto.md sections 9 and 11); the neutral raw's too. On the lossless L sample and the
    /// still life at ISO 100 (or ARGENT_FILES), at FRAME_VIEW_SIZES.
    @Test(.enabled(if: enabled))
    func sharpness() throws {
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let resize = try AreaResize(gpu: gpu)
        let sharpened = DevelopSettings(sharpen: true)
        let sides = Self.environment["FRAME_VIEW_SIZES"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [960, 1408, 2190, 3072, 4096]
        let files = ProvenanceMeasureTests.files().isEmpty ? [M.lossless, FrameViewSharpnessMeasureTests.stillLife] : ProvenanceMeasureTests.files()
        func bands(_ texture: MTLTexture) -> [Float] { A.bands(A.lightness(ExposureAnalyzer.pixels(of: texture)), width: texture.width) }
        func ratio(_ a: [Float], _ b: [Float]) -> String { zip(a, b).map { String(format: "%.2f", $0 / $1) }.joined(separator: ", ") }
        for url in files {
            let full = try apple.decode(url, options: Self.options(.learned, tile: RollDeveloper.learnedDecodeTile))
            let develop = try renderer.render(full, settings: sharpened).image
            print("MEASURE RAW 9 sharpness, \(url.lastPathComponent), the scaled decode rendered over the develop area-resized, bands near 0.31, 0.15, 0.08 cycles a pixel")
            for side in sides {
                let target = try A.area(develop.texture, longSide: side, resize: resize)
                let t = A.bands(A.lightness(target.pixels), width: target.width)
                let rawTarget = try A.area(full.texture, longSide: side, resize: resize)
                let r = A.bands(A.lightness(rawTarget.pixels), width: rawTarget.width)
                var line = "MEASURE   \(side) px:"
                for draft in [true, false] {
                    let scaled = try Self.learnedScaled(url, longSide: side, draft: draft, gpu: gpu)
                    let rendered = try renderer.render(scaled, settings: sharpened).image
                    line += " draft \(draft ? "on, mask" : "off, no mask") \(ratio(bands(rendered.texture), t)) (neutral raw \(ratio(bands(scaled.texture), r)));"
                }
                print(line)
            }
        }
    }

    /// RAW 9's decode of `url` with its long side `longSide`, as `AppleRawDecoder` makes it, with draft mode
    /// set to `draft` and recorded so in the pins, for the measurement of which previews need which mask.
    /// The frame is upright and untrimmed: only for the Bayer modes, whose trim is none.
    static func learnedScaled(_ url: URL, longSide: Int, draft: Bool, gpu: GPU) throws -> LinearFrame {
        let filter = try #require(CIRAWFilter(imageURL: url))
        var options = Self.options(.learned, longSide: longSide)
        options.fillsMaxLongSide = true
        let configured = AppleRawDecoder.configure(filter, options: options, iso: AppleRawDecoder.isoSpeed(of: filter),
                                                   layout: try? ARWLayout.read(from: url))
        var pins = configured.pins
        let readback = configured.readback
        filter.isDraftModeEnabled = draft
        pins.draftMode = draft
        let image = try #require(filter.outputImage)
        let extent = image.extent.integral
        let texture = try gpu.texturePool.acquire(width: Int(extent.width), height: Int(extent.height))
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        gpu.makeLearnedContext().render(image, to: texture.texture, commandBuffer: commandBuffer, bounds: extent, colorSpace: gpu.workingColorSpace)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return LinearFrame(image: texture, decoderVersion: pins.decoderVersion, scale: pins.scale, pins: pins, readback: readback)
    }

    /// RAW 9 repeats bit for bit at full size in the develop's tiles, the sheet's 960 pixels and the frame
    /// view's 2190: the SHA-256 of the decode's pixels, ARGENT_REPEAT (3) times in one process; run it
    /// in two processes to compare across them.
    @Test(.enabled(if: enabled))
    func repeats() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let repeats = Self.environment["ARGENT_REPEAT"].flatMap(Int.init) ?? 3
        for url in [M.lossless, SyntheticRaw.base, Self.samples.appendingPathComponent("ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW")] {
            for (label, options) in [("full, develop's tiles", Self.options(.learned, tile: RollDeveloper.learnedDecodeTile)),
                                     ("960", Self.options(.learned, longSide: 960)), ("2190", Self.options(.learned, longSide: 2190))] {
                var hashes: [String] = []
                for _ in 0..<repeats { try autoreleasepool { hashes.append(Self.hash(try decoder.decode(url, options: options).texture)) } }
                print("MEASURE repeats \(url.lastPathComponent) \(label): \(hashes.joined(separator: " ")) (\(Set(hashes).count == 1 ? "identical" : "DIFFER"))")
            }
        }
    }
}
