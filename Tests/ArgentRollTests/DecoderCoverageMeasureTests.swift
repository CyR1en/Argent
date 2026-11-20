import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Measurements behind docs/decoder.md section 17: the in-house decoder on the owner's raw modes,
/// uncompressed beside lossless L, and above ISO 1250. Gated like the other measurement suites:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --skip-build --filter DecoderCoverageMeasureTests/<test>
///
/// They read the CC0 samples, the photographyblog frames in `references/corpus/photographyblog-a7iv`
/// (its SOURCE.txt) and `build/stocks`.
@Suite(.serialized, .syntheticRaws) struct DecoderCoverageMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }
    typealias M = InHouseDecoderMeasureTests

    // MARK: Byte identity

    /// SHA-256 of the in-house decode's pixels for the lossless L sample and copies of it with the
    /// Exif ISO rewritten across the old range, at full size, the sheet's 960 pixels and the frame
    /// view's 2190, with the production options: the frames the in-house decoder took before this
    /// work, whose output must not change without a new `InHouseDecoder.version`.
    @Test(.enabled(if: DecoderCoverageMeasureTests.enabled))
    func losslessHashes() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let folder = SyntheticRaw.folder
        print("MEASURE decoder \(InHouseDecoder.version)")
        for iso in [100, 250, 640, 800, 1000, 1250] {
            let url = folder.appendingPathComponent("DSC06674-ISO\(iso).ARW")
            try DecoderSwitchMeasureTests.copyRaw(M.lossless, to: url, iso: iso)
            var line = "MEASURE lossless L hash ISO \(iso):"
            for side in [nil, 960, 2190] as [Int?] {
                var options = DecodeOptions()
                options.maxLongSide = side
                let frame = try decoder.decode(url, options: options)
                line += " \(side.map(String.init) ?? "full") \(Self.hash(frame.texture));"
            }
            print(line)
        }
    }

    // MARK: The frames

    static let photographyblog = M.root.appendingPathComponent("references/corpus/photographyblog-a7iv")

    static let gallery = M.root.appendingPathComponent("references/corpus/imaging-resource-a7iv-gallery")

    /// The real a7 IV frames here by ARGENT_FRAMES, comma separated (default `uncompressed`):
    /// `uncompressed`, the CC0 uncompressed sample and the 14 photographyblog frames
    /// (references/corpus/photographyblog-a7iv/SOURCE.txt); `stilllife`, Imaging Resource's 13;
    /// `lossless`, the CC0 lossless L sample and Imaging Resource's gallery lossless L frames
    /// (references/corpus/imaging-resource-a7iv-gallery/SOURCE.txt). By ISO; ARGENT_ISOS keeps those
    /// ISOs, ARGENT_MIN_ISO and ARGENT_MAX_ISO bound them, ARGENT_FILES adds files.
    static func realFrames() throws -> [(iso: Int, url: URL)] {
        let env = ProcessInfo.processInfo.environment
        let sets = Set((env["ARGENT_FRAMES"] ?? "uncompressed").split(separator: ",").map(String.init))
        var urls = ProvenanceMeasureTests.files()
        if sets.contains("uncompressed") { urls += [SyntheticRaw.base] + RollScanner.rawFiles(in: photographyblog) }
        if sets.contains("stilllife") { urls += InHouseNoiseMeasureTests.stillLife.frames.map(\.url) + [InHouseNoiseMeasureTests.stillLife.reference] }
        if sets.contains("lossless") { urls += [M.lossless] + RollScanner.rawFiles(in: gallery) }
        urls = Array(Set(urls)).filter { FileManager.default.fileExists(atPath: $0.path) }
        let only = env["ARGENT_ISOS"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let low = env["ARGENT_MIN_ISO"].flatMap(Int.init) ?? 0, high = env["ARGENT_MAX_ISO"].flatMap(Int.init) ?? .max
        return try urls.map { (try ARWFrameInfo.read(from: $0).iso ?? 0, $0) }
            .filter { (only == nil || only!.contains($0.0)) && $0.0 >= low && $0.0 <= high }
            .sorted { ($0.0, $0.1.lastPathComponent) < ($1.0, $1.1.lastPathComponent) }
    }

    /// `url` as the owner's camera writes it: photographyblog's frames read "MODEL-NAME" where the
    /// camera wrote ILCE-7M4 (docs/provenance.md section 8), so a copy with the model written back,
    /// which the decoder choice, both decoders and auto development then take as an a7 IV's.
    static func asA7IV(_ url: URL) throws -> URL {
        guard try ARWLayout.read(from: url).model != InHouseColor.model else { return url }
        var data = try Data(contentsOf: url)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let ifd0 = u32(4)
        guard let entry = (0..<u16(ifd0)).map({ ifd0 + 2 + 12 * $0 }).first(where: { u16($0) == 0x0110 }), u16(entry + 2) == 2 else {
            throw ARWLayout.ReadError.noRawIFD
        }
        let count = u32(entry + 4), at = count <= 4 ? entry + 8 : u32(entry + 8)
        let name = Array(InHouseColor.model.utf8)
        guard name.count < count else { throw ARWLayout.ReadError.noRawIFD }
        data.replaceSubrange(at..<(at + count), with: name + [UInt8](repeating: 0, count: count - name.count))
        let copy = SyntheticRaw.folder.appendingPathComponent("a7iv-" + url.lastPathComponent)
        try data.write(to: copy)
        return copy
    }

    // MARK: Against Apple

    /// One frame, in-house against Apple, with the measures that admitted lossless L (docs/decoder.md
    /// sections 4, 14 and 16).
    struct Comparison {
        var name: String
        var iso: Int
        /// Lens correction and noise reduction off on both: luminance in stops per pixel (signed mean)
        /// and on 8-pixel blocks (|d| p95), mean chromaticity, and the plain print's dE2000 on 8-pixel
        /// blocks.
        var offLuminance: Double
        var offBlockP95: Double
        var offChromaticity: Double
        var offPrintBlocks: Double
        /// The production pins: the print with grain, halation and sharpening, dE2000 per pixel mean
        /// and p95 and on 8-pixel blocks; and against Apple's with its lens correction off.
        var print: Stats.Summary
        var printBlocks: Double
        var printLensOff: Double
        /// Flat-area noise at mid-gray, ours over Apple's production: L* and a*b*, and Apple's own.
        var lightness: Double
        var chroma: Double
        var appleLightness: Double
        var appleChroma: Double
        var patches: Int
        /// Detail in the three bands of the decode's central square, ours over Apple's.
        var detail: [Float]
        /// Where the central detail lines up best.
        var window: (dx: Int, dy: Int)
        /// Auto development from each decoder's 960-pixel decode: level and lab balance, ours less Apple's.
        var level: Double
        /// The analyses' own levels, ours less Apple's, before the print's bounds.
        var meanStops: Double
        var redBlueMired: Double
        var greenMagenta: Double
    }

    static func compare(_ source: URL, iso: Int, decoder: InHouseDecoder, apple: AppleRawDecoder, renderer: FilmRenderer,
                        gpu: GPU, options: DecodeOptions = DecodeOptions(), tuning: InHouseNoiseReduction.Tuning? = nil) throws -> Comparison {
        let url = try asA7IV(source)
        let info = try ARWFrameInfo.read(from: url)
        let settings = DevelopSettings(grain: 1, grainSeed: 7, halation: true, sharpen: true)
        // Lens and noise reduction off.
        var off = M.inHouseOff
        off.lensCorrection = false
        let oursOff = try M.inHouse(url, decoder: decoder, gpu: gpu, options: off)
        let theirsOff = try apple.decode(url, options: M.appleOptions(lens: false, noiseReduction: false))
        let a0 = Pixels(oursOff.texture), b0 = Pixels(theirsOff.texture)
        let offLuminance = Stats.luminanceStops(a0, b0, block: 1), offBlocks = Stats.luminanceStops(a0, b0, block: 8)
        let chroma = Self.chromaticity(a0, b0)
        let offPrint = Stats.deltaE(Pixels(try renderer.render(oursOff, settings: DevelopSettings()).image.texture),
                                    Pixels(try renderer.render(theirsOff, settings: DevelopSettings()).image.texture), block: 8)
        let patches = InHouseNoiseMeasureTests.flatPatches(b0)
        // Production.
        let ours = tuning == nil && InHouseDecoder.supports(url) ? try decoder.decode(url, options: options)
            : try M.inHouse(url, decoder: decoder, gpu: gpu, options: options, tuning: tuning)
        let theirs = try apple.decode(url, options: DecodeOptions())
        let a = Pixels(ours.texture), b = Pixels(theirs.texture)
        let oursPrint = Pixels(try renderer.render(ours, settings: settings).image.texture)
        let theirPrint = Pixels(try renderer.render(theirs, settings: settings).image.texture)
        let print = Stats.deltaE(oursPrint, theirPrint, block: 1), printBlocks = Stats.deltaE(oursPrint, theirPrint, block: 8)
        let lensOff = Stats.deltaE(oursPrint, Pixels(try renderer.render(try apple.decode(url, options: M.appleOptions(lens: false, noiseReduction: true)),
                                                                         settings: settings).image.texture), block: 1)
        let n = InHouseNoiseMeasureTests.noise(a, patches), m = InHouseNoiseMeasureTests.noise(b, patches)
        let da = AutoMeasureTests.bands(AutoMeasureTests.lightness(a.values), width: a.width)
        let db = AutoMeasureTests.bands(AutoMeasureTests.lightness(b.values), width: b.width)
        // Auto development, from the sheet's decodes, as the app measures a frame.
        var small = DecodeOptions()
        small.maxLongSide = FilmPreviews.previewLongSide
        let x = ExposureAnalyzer.analyze(try M.inHouse(url, decoder: decoder, gpu: gpu, options: small), workingSpace: gpu.workingColorSpace, info: info)
        let y = ExposureAnalyzer.analyze(try apple.decode(url, options: small), workingSpace: gpu.workingColorSpace, info: info)
        // The lab balance each prints: the corrected share of its cast, bounded (`AutoBalance.correction`).
        let cx = AutoBalance.axes(AutoBalance.correction(for: AutoBalance.cast(x)))
        let cy = AutoBalance.axes(AutoBalance.correction(for: AutoBalance.cast(y)))
        return Comparison(name: source.lastPathComponent, iso: iso, offLuminance: offLuminance.mean, offBlockP95: offBlocks.p95,
                          offChromaticity: chroma, offPrintBlocks: offPrint.mean, print: print, printBlocks: printBlocks.mean,
                          printLensOff: lensOff.mean, lightness: n.lightness / m.lightness, chroma: n.chroma / m.chroma,
                          appleLightness: m.lightness, appleChroma: m.chroma, patches: patches.count,
                          detail: zip(da, db).map { $0 / $1 }, window: Self.window(a, b),
                          level: Double(AutoPrint.levelStops(x) - AutoPrint.levelStops(y)), meanStops: Double(x.meanStops - y.meanStops),
                          redBlueMired: Double((cx.redBlue - cy.redBlue) / AutoBalance.stopsPerMired), greenMagenta: Double(cx.greenMagenta - cy.greenMagenta))
    }

    static func line(_ c: Comparison) -> String {
        String(format: "MEASURE %@ ISO %d: lens and NR off luminance %+.4f stops, 8-px |d| p95 %.4f, chromaticity %.4f, print 8-px dE %.2f; production print dE per pixel %.2f (p95 %.2f), 8-px %.2f, against Apple lens off %.2f; flat L* %.2f, a*b* %.2f of Apple's (Apple %.3f, %.3f; %d patches); detail %@; window (%d, %d); auto level %+.3f stops (measured %+.3f), printed lab balance %+.1f mired, green-magenta %+.3f stops",
               c.name, c.iso, c.offLuminance, c.offBlockP95, c.offChromaticity, c.offPrintBlocks, c.print.mean, c.print.p95, c.printBlocks,
               c.printLensOff, c.lightness, c.chroma, c.appleLightness, c.appleChroma, c.patches,
               c.detail.map { String(format: "%.2f", $0) }.joined(separator: ", "), c.window.dx, c.window.dy, c.level, c.meanStops,
               c.redBlueMired, c.greenMagenta)
    }

    /// The largest gap in mean Rec. 2020 chromaticity, r or g, every 7th pixel above a dim floor, as
    /// `InHouseDecoderSampleTests/landsWhereAppleDoes` reads it.
    static func chromaticity(_ a: Pixels, _ b: Pixels) -> Double {
        func stats(_ p: Pixels) -> (r: Double, g: Double) {
            var r = 0.0, g = 0.0, n = 0.0
            for y in stride(from: 0, to: p.height, by: 7) {
                for x in stride(from: 0, to: p.width, by: 7) {
                    let c = p.rgb(x, y), s = c.x + c.y + c.z
                    guard M.luminance(c) > 0.005, s > 0 else { continue }
                    r += c.x / s; g += c.y / s; n += 1
                }
            }
            return (r / n, g / n)
        }
        let sa = stats(a), sb = stats(b)
        return max(abs(sa.r - sb.r), abs(sa.g - sb.g))
    }

    /// The offset of `a` against `b` at which a central 256-pixel patch's luminance detail correlates best.
    static func window(_ a: Pixels, _ b: Pixels) -> (dx: Int, dy: Int) {
        func detail(_ p: Pixels, _ x: Int, _ y: Int) -> Double {
            M.luminance(p.rgb(x, y)) - 0.25 * (M.luminance(p.rgb(x - 1, y)) + M.luminance(p.rgb(x + 1, y))
                                               + M.luminance(p.rgb(x, y - 1)) + M.luminance(p.rgb(x, y + 1)))
        }
        var best = (score: -Double.infinity, dx: 99, dy: 99)
        let x0 = a.width / 2 - 128, y0 = a.height / 2 - 128
        for dy in -2...2 {
            for dx in -2...2 {
                var sab = 0.0, saa = 0.0, sbb = 0.0
                for y in y0..<(y0 + 256) {
                    for x in x0..<(x0 + 256) {
                        let p = detail(a, x + dx, y + dy), q = detail(b, x, y)
                        sab += p * q; saa += p * p; sbb += q * q
                    }
                }
                let score = sab / (saa * sbb).squareRoot()
                if score > best.score { best = (score, dx, dy) }
            }
        }
        return (best.dx, best.dy)
    }

    /// Every real uncompressed frame through the in-house decoder against Apple's, with the
    /// measures that admitted lossless L, and a summary by ISO.
    @Test(.enabled(if: DecoderCoverageMeasureTests.enabled))
    func uncompressedAgainstApple() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let renderer = try FilmRenderer(gpu: gpu, stock: try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400")))
        var all: [Comparison] = []
        for (iso, url) in try Self.realFrames() {
            let c = try autoreleasepool { try Self.compare(url, iso: iso, decoder: decoder, apple: apple, renderer: renderer, gpu: gpu) }
            print(Self.line(c))
            all.append(c)
        }
        Self.summarize(all)
    }

    static func summarize(_ all: [Comparison]) {
        func range(_ v: [Double], _ format: String = "%.2f") -> String {
            guard let lo = v.min(), let hi = v.max() else { return "-" }
            return String(format: format, lo) + " to " + String(format: format, hi)
        }
        for (label, group) in [("ISO 100 to 1250", all.filter { $0.iso <= 1250 }), ("ISO 1600 and up", all.filter { $0.iso > 1250 }), ("all", all)] where !group.isEmpty {
            print("MEASURE summary \(label), \(group.count) frames: lens and NR off luminance \(range(group.map(\.offLuminance), "%+.4f")) stops, 8-px |d| p95 \(range(group.map(\.offBlockP95), "%.4f")), chromaticity up to \(String(format: "%.4f", group.map(\.offChromaticity).max()!)), print 8-px \(range(group.map(\.offPrintBlocks))); production print per pixel \(range(group.map(\.print.mean))), 8-px \(range(group.map(\.printBlocks))); flat L* \(range(group.map(\.lightness))), a*b* \(range(group.map(\.chroma))) of Apple's; windows \(Set(group.map { "(\($0.window.dx), \($0.window.dy))" }).sorted().joined(separator: " ")); auto level \(range(group.map(\.level), "%+.3f")) stops (measured \(range(group.map(\.meanStops), "%+.3f"))), printed lab balance \(range(group.map(\.redBlueMired), "%+.1f")) mired, green-magenta \(range(group.map(\.greenMagenta), "%+.3f"))")
        }
    }

    // MARK: Strengths above ISO 1250

    /// The frames the strengths above ISO 1250 are matched on, by ARGENT_SETS: `real`, the real
    /// frames (`realFrames`, model written back) from ISO 800; `stilllife`, Imaging Resource's ladder
    /// from 800 to 12800; `neutral` and `flat`, synthetic neutral and four-tint flat patches with the
    /// noise of ARGENT_FLAT_ISOS (1600, 3200, 6400); `simulated`, the CC0 scene at those ISOs. Each with
    /// its reference for the flat patches: the frame itself for real frames, the clean frame otherwise.
    static func strengthCases() throws -> [(name: String, iso: Int, url: URL, reference: URL)] {
        let env = ProcessInfo.processInfo.environment
        let sets = Set((env["ARGENT_SETS"] ?? "real,stilllife,neutral,flat").split(separator: ",").map(String.init))
        let isos = env["ARGENT_FLAT_ISOS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [1600, 3200, 6400]
        var cases: [(String, Int, URL, URL)] = []
        if sets.contains("real") {
            for (iso, url) in try realFrames() where iso >= 800 {
                let copy = try asA7IV(url)
                cases.append((url.lastPathComponent, iso, copy, copy))
            }
        }
        if sets.contains("stilllife") {
            let reference = InHouseNoiseMeasureTests.stillLife.reference
            for frame in InHouseNoiseMeasureTests.stillLife.frames where (800...12800).contains(frame.iso) {
                cases.append(("still life", frame.iso, try asA7IV(frame.url), try asA7IV(reference)))
            }
        }
        for kind in ["neutral", "flat"] where sets.contains(kind) {
            let clean = try SyntheticRaw.patches(kind, iso: 250, noise: false).url
            for iso in isos { cases.append(("synthetic \(kind) patches", iso, try SyntheticRaw.patches(kind, iso: iso, noise: true).url, clean)) }
        }
        if sets.contains("simulated") {
            for iso in isos { cases.append(("DSC06673 simulated", iso, try SyntheticRaw.simulated(iso: iso), SyntheticRaw.base)) }
        }
        if sets.contains("stilllife-simulated") {
            // The still life's real ISO 3200 frame with the noise of ARGENT_SIM_ISOS (4000, 5000, 6400)
            // added, as `SyntheticRaw.simulated` raises the CC0 scene; at 6400 it checks itself against
            // the real frame.
            let reference = try asA7IV(InHouseNoiseMeasureTests.stillLife.reference)
            let source = try asA7IV(InHouseNoiseMeasureTests.stillLife.frames.first { $0.iso == 3200 }!.url)
            let simISOs = env["ARGENT_SIM_ISOS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [4000, 5000, 6400]
            for iso in simISOs { cases.append(("still life simulated", iso, try simulated(source, from: 3200, to: iso), reference)) }
        }
        return cases
    }

    /// A copy of the uncompressed frame `url`, shot at ISO `from`, with the noise ISO `to` adds under
    /// the a7 IV's noise model (`SyntheticRaw.simulated`) and its Exif ISO set to `to`.
    static func simulated(_ url: URL, from: Int, to: Int, seed: UInt64 = 1) throws -> URL {
        let addShot = max(0, SyntheticRaw.shot(iso: Double(to)) - SyntheticRaw.shot(iso: Double(from)))
        let addRead = max(0, SyntheticRaw.read(iso: Double(to)) - SyntheticRaw.read(iso: Double(from)))
        return try SyntheticRaw.write("\(url.deletingPathExtension().lastPathComponent)-to\(to).ARW", from: url, iso: to) { samples, l in
            var g = SyntheticRaw.Gaussian(seed: seed &* 7919 &+ UInt64(to))
            let black = Double(l.black), white = Double(l.white)
            for i in samples.indices {
                let v = Double(samples[i]), s = max(v - black, 0)
                samples[i] = UInt16(min(max((v + g.next() * (addShot * s + addRead).squareRoot()).rounded(), 0), white))
            }
        }
    }

    /// The luminance and colour strengths at which each case's flat-patch L* and a*b* noise equal
    /// Apple's production decode's, by bisection as `ProvenanceMeasureTests/noiseStrengths`, and how the
    /// committed tuning lands.
    @Test(.enabled(if: DecoderCoverageMeasureTests.enabled))
    func strengthsAboveTheCutoff() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        typealias N = InHouseNoiseMeasureTests
        let ladder = N.Ladder(name: "coverage", frames: [], reference: SyntheticRaw.base, stillLife: false)
        for c in try Self.strengthCases() {
            try autoreleasepool {
                let patches = N.flatPatches(Pixels(try apple.decode(c.reference, options: M.appleOptions(lens: false, noiseReduction: false)).texture))
                let source = try MeasureMosaic.load(c.url, device: gpu.device)
                let iso = source.iso.map(Float.init)
                let target = N.noise(Pixels(try apple.decode(c.url, options: DecodeOptions()).texture), patches)
                let amount = NoiseReduction.luminanceAmount(iso: iso)
                let committed = InHouseNoiseReduction.tuning(luminance: amount, colour: 0.5, iso: iso)
                func measure(_ luminance: Float, _ colour: Float) throws -> (lightness: Double, chroma: Double) {
                    var t = committed
                    t.luminance = luminance
                    t.colour = colour
                    return N.noise(Pixels(try N.render(source, ladder: ladder, decoder: decoder, tuning: t).texture), patches)
                }
                func match(_ keyPath: KeyPath<(lightness: Double, chroma: Double), Double>, fixed: Float, luminance: Bool) throws -> Float {
                    var lo: Float = 0.01, hi: Float = 8
                    let goal = target[keyPath: keyPath]
                    if try (luminance ? measure(lo, fixed) : measure(fixed, lo))[keyPath: keyPath] <= goal { return 0 }
                    for _ in 0..<12 {
                        let mid = (lo * hi).squareRoot()
                        if try (luminance ? measure(mid, fixed) : measure(fixed, mid))[keyPath: keyPath] > goal { lo = mid } else { hi = mid }
                    }
                    return (lo * hi).squareRoot()
                }
                var l = try match(\.lightness, fixed: committed.colour, luminance: true)
                let colour = try match(\.chroma, fixed: max(l, 0.01), luminance: false)
                l = try match(\.lightness, fixed: max(colour, 0.01), luminance: true)
                let now = N.noise(Pixels(try N.render(source, ladder: ladder, decoder: decoder, tuning: committed).texture), patches)
                print(String(format: "MEASURE strengths %@ ISO %d (%d patches): luminance %.3f, colour %.3f; Apple L* %.3f a*b* %.3f; committed (%.2f, %.2f) L* %.2f, a*b* %.2f of Apple's (%.3f)",
                             c.name, c.iso, patches.count, l, colour, target.lightness, target.chroma, committed.luminance, committed.colour,
                             now.lightness / target.lightness, now.chroma / target.chroma, now.chroma))
            }
        }
    }

    /// Variants of the noise reduction for the sweeps, from ARGENT_VARIANTS: `name=key:value,...`
    /// separated by `;`, keys `l` and `c` (strengths, or the committed tier's when absent), `neutral`
    /// and `width` (`InHouseNoiseReduction.Tuning.colourNeutral`, `colourWidth`); `tier` alone is the
    /// committed tuning.
    static func variants(iso: Float?) -> [(name: String, tuning: InHouseNoiseReduction.Tuning)] {
        let spec = ProcessInfo.processInfo.environment["ARGENT_VARIANTS"] ?? "tier"
        let committed = InHouseNoiseReduction.tuning(luminance: NoiseReduction.luminanceAmount(iso: iso), colour: 0.5, iso: iso)
        return spec.split(separator: ";").map { item in
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            var t = committed
            for pair in (parts.count > 1 ? parts[1] : "").split(separator: ",") {
                let kv = pair.split(separator: ":").map(String.init)
                guard kv.count == 2, let v = Float(kv[1]) else { continue }
                switch kv[0] {
                case "l": t.luminance = v
                case "c": t.colour = v
                case "neutral": t.colourNeutral = v
                case "width": t.colourWidth = v
                case "fl": t.flatLow = v
                case "fh": t.flatHigh = v
                default: break
                }
            }
            return (parts[0], t)
        }
    }

    /// Flat-patch noise and the print against Apple's production decode for each variant
    /// (`variants`) on the cases of `strengthCases`: L* and a*b* over Apple's, a*b* itself, and the
    /// Portra 400 print's dE2000 per pixel with grain, halation and sharpening (ARGENT_PRINT=0 skips it).
    @Test(.enabled(if: DecoderCoverageMeasureTests.enabled))
    func colourDesign() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let renderer = try FilmRenderer(gpu: gpu, stock: try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400")))
        let settings = DevelopSettings(grain: 1, grainSeed: 7, halation: true, sharpen: true)
        let prints = ProcessInfo.processInfo.environment["ARGENT_PRINT"] != "0"
        typealias N = InHouseNoiseMeasureTests
        for c in try Self.strengthCases() {
            try autoreleasepool {
                let patches = N.flatPatches(Pixels(try apple.decode(c.reference, options: M.appleOptions(lens: false, noiseReduction: false)).texture))
                let source = try MeasureMosaic.load(c.url, device: gpu.device)
                let theirs = try apple.decode(c.url, options: DecodeOptions())
                let target = N.noise(Pixels(theirs.texture), patches)
                let theirPrint = prints ? Pixels(try renderer.render(theirs, settings: settings).image.texture) : nil
                var line = String(format: "MEASURE design %@ ISO %d: Apple L* %.3f a*b* %.3f;", c.name, c.iso, target.lightness, target.chroma)
                for (name, tuning) in Self.variants(iso: source.iso.map(Float.init)) {
                    let iso = source.iso.map(Float.init)
                    let ours = try decoder.render(source.buffer, layout: source.layout, orientation: source.orientation,
                                                  gainStops: ExposureAnchor.gainStops(iso: iso), iso: iso, options: DecodeOptions(),
                                                  lens: source.lens, tuning: tuning).0
                    let n = N.noise(Pixels(ours.texture), patches)
                    line += String(format: " %@ L* %.2f a*b* %.2f (%.3f)", name, n.lightness / target.lightness, n.chroma / target.chroma, n.chroma)
                    if c.name.hasPrefix("still life") {
                        let d = N.detail(Pixels(ours.texture), stillLife: true), t = N.detail(Pixels(theirs.texture), stillLife: true)
                        line += String(format: " gray edge %.2f (Apple %.2f) white %.2f (%.2f) bands %.2f %.2f", d.gray ?? .nan, t.gray ?? .nan,
                                       d.white ?? .nan, t.white ?? .nan, d.bands[0] / t.bands[0], d.bands[1] / t.bands[1])
                    }
                    if let theirPrint {
                        let de = Stats.deltaE(Pixels(try renderer.render(ours, settings: settings).image.texture), theirPrint, block: 1)
                        line += String(format: " print %.2f", de.mean)
                    }
                    line += ";"
                }
                print(line)
            }
        }
    }

    // MARK: Consistency across the cutoff

    /// Where a frame goes under a routing rule: lossless L up to `lossless`, uncompressed up to
    /// `uncompressed` (0 for never), Apple's for the rest.
    struct Route {
        var name: String
        var lossless: Int
        var uncompressed: Int

        func inHouse(_ encoding: ARWLayout.Encoding, iso: Int) -> Bool {
            switch encoding {
            case .losslessBayer: return iso > 0 && iso <= lossless
            case .uncompressed: return iso > 0 && iso <= uncompressed
            default: return false
            }
        }
    }

    /// Auto development and the print across the old and new cutoffs, on a roll of the frames in
    /// ARGENT_ROLL (default the still life's ladder from ISO 800 to 12800, as one roll in capture
    /// order), each frame decoded by the decoder each route gives it: measured from the sheet's
    /// 960-pixel decode with its file's information, as the app measures it; aimed by roll smoothing
    /// over the roll; printed through Portra 400 with the app's settings at 2048 pixels. For each
    /// route the frames' level, lab balance and print (mean L*a*b*, and on the still life its gray
    /// card's), and the step in the print from each frame to the next. ARGENT_ROUTES lists routes as
    /// `name:lossless:uncompressed` separated by `;` (default before 1250 and none, after both at the
    /// committed cutoff); ARGENT_PRINTS names a folder for the prints as JPEG.
    @Test(.enabled(if: DecoderCoverageMeasureTests.enabled))
    func consistencyAcrossTheCutoff() async throws {
        let env = ProcessInfo.processInfo.environment
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let resize = try AreaResize(gpu: gpu)
        let encoder = try ImageEncoder(gpu: gpu)
        let limit = DecoderChoice.inHouseISOLimit
        let routes = (env["ARGENT_ROUTES"] ?? "before:1250:0;after:\(limit):\(limit)").split(separator: ";").map { item -> Route in
            let f = item.split(separator: ":").map(String.init)
            return Route(name: f[0], lossless: Int(f[1]) ?? 0, uncompressed: Int(f[2]) ?? 0)
        }
        // The roll: copies with the model written back, in one folder, scanned as the app scans one.
        let folder = SyntheticRaw.folder.appendingPathComponent("consistency-roll")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sources: [URL] = env["ARGENT_ROLL"].map { path in
            RollScanner.rawFiles(in: URL(fileURLWithPath: path)).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } ?? InHouseNoiseMeasureTests.stillLife.frames.filter { (800...12800).contains($0.iso) }.map(\.url)
        for url in sources {
            let copy = try Self.asA7IV(url)
            let target = folder.appendingPathComponent(url.lastPathComponent)
            if copy == url { try FileManager.default.linkItem(at: url, to: target) } else { try FileManager.default.moveItem(at: copy, to: target) }
        }
        let roll = await RollScanner.scan(folder)
        let stillLife = env["ARGENT_ROLL"] == nil
        var small = DecodeOptions()
        small.maxLongSide = FilmPreviews.previewLongSide
        // Each decoder's measurement of each frame, made once.
        var measured: [URL: (inHouse: ExposureAnalysis, apple: ExposureAnalysis)] = [:]
        for frame in roll.frames {
            let a = ExposureAnalyzer.analyze(try decoder.decode(frame.url, options: small), workingSpace: gpu.workingColorSpace, info: frame.info)
            let b = ExposureAnalyzer.analyze(try apple.decode(frame.url, options: small), workingSpace: gpu.workingColorSpace, info: frame.info)
            measured[frame.url] = (a, b)
        }
        var printed: [String: [(l: Double, a: Double, b: Double, card: SIMD3<Double>?)]] = [:]
        for route in routes {
            func ours(_ frame: Frame) -> Bool {
                let layout = try? ARWLayout.read(from: frame.url)
                return layout.map { route.inHouse($0.encoding, iso: frame.info.iso ?? 0) } ?? false
            }
            let analyses = Dictionary(uniqueKeysWithValues: roll.frames.map { ($0.url, ours($0) ? measured[$0.url]!.inHouse : measured[$0.url]!.apple) })
            let aims = RollSmoothing.aims(roll.frames, analyses: analyses)
            var rows: [(l: Double, a: Double, b: Double, card: SIMD3<Double>?)] = []
            for frame in roll.frames {
                let aim = aims[frame.url] ?? PrintAim()
                var settings = RollControls().settings(for: stock, aim: aim)
                settings.grain = 1
                settings.grainSeed = 7
                settings.halation = true
                settings.sharpen = true
                let full = ours(frame) ? try decoder.decode(frame.url, options: DecodeOptions()) : try apple.decode(frame.url, options: DecodeOptions())
                let rendered = try renderer.render(full, settings: settings).image
                let out = try resize.resized(rendered.texture, scale: 2048 / Double(max(rendered.width, rendered.height)))
                let pixels = Pixels(out.texture)
                var sum = SIMD3<Double>(0, 0, 0), n = 0.0
                for y in stride(from: 0, to: pixels.height, by: 2) {
                    for x in stride(from: 0, to: pixels.width, by: 2) { sum += Colour.lab(pixels.rgb(x, y)); n += 1 }
                }
                let mean = sum / n
                var card: SIMD3<Double>?
                if stillLife {
                    // The gray card, columns 4600 to 4900 and rows 60 to 280 from the top at full size.
                    let k = Double(pixels.width) / 7008
                    var c = SIMD3<Double>(0, 0, 0), m = 0.0
                    for row in Int(60 * k)..<Int(280 * k) {
                        for x in Int(4600 * k)..<Int(4900 * k) { c += pixels.rgb(x, pixels.height - 1 - row); m += 1 }
                    }
                    card = Colour.lab(c / m)
                }
                rows.append((mean.x, mean.y, mean.z, card))
                if let dir = env["ARGENT_PRINTS"] {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(route.name)-\(frame.url.deletingPathExtension().lastPathComponent).jpg")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try encoder.write(out.texture, to: url, format: .jpeg(quality: 0.92), metadataFrom: nil, colorSpace: gpu.workingColorSpace)
                }
                let analysis = analyses[frame.url]!
                let correction = AutoBalance.axes(AutoBalance.correction(for: aim.cast))
                print(String(format: "MEASURE route %@ %@ ISO %d %@: level %+.3f stops (own %+.3f), lab balance %+.1f mired, green-magenta %+.3f stops; print L* %.2f a* %+.2f b* %+.2f%@",
                             route.name, frame.url.lastPathComponent, frame.info.iso ?? 0, ours(frame) ? "in-house" : "Apple", aim.level,
                             AutoPrint.levelStops(analysis), correction.redBlue / AutoBalance.stopsPerMired, correction.greenMagenta,
                             mean.x, mean.y, mean.z, card.map { String(format: "; card L* %.2f a* %+.2f b* %+.2f", $0.x, $0.y, $0.z) } ?? ""))
            }
            printed[route.name] = rows
        }
        // Each frame from one decoder to the other (what a route change moves), and each route's steps
        // from frame to frame.
        func de(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> Double { Colour.deltaE2000(p, q) }
        for (i, frame) in roll.frames.enumerated() {
            let a = measured[frame.url]!.inHouse, b = measured[frame.url]!.apple
            let ca = AutoBalance.axes(AutoBalance.correction(for: AutoBalance.cast(a))), cb = AutoBalance.axes(AutoBalance.correction(for: AutoBalance.cast(b)))
            var line = String(format: "MEASURE decoders %@ ISO %d: own level in-house less Apple %+.3f stops, lab balance %+.1f mired, green-magenta %+.3f;",
                              frame.url.lastPathComponent, frame.info.iso ?? 0, AutoPrint.levelStops(a) - AutoPrint.levelStops(b),
                              (ca.redBlue - cb.redBlue) / AutoBalance.stopsPerMired, ca.greenMagenta - cb.greenMagenta)
            for route in routes where i > 0 {
                let rows = printed[route.name]!
                let p = rows[i], q = rows[i - 1]
                line += String(format: " %@ step from the frame before, mean print dE %.2f", route.name, de(SIMD3(p.l, p.a, p.b), SIMD3(q.l, q.a, q.b)))
                if let pc = p.card, let qc = q.card { line += String(format: ", card dE %.2f", de(pc, qc)) }
                line += ";"
            }
            print(line)
        }
    }

    /// The SHA-256 of a texture's RGBA half floats, first 16 hex digits.
    static func hash(_ texture: MTLTexture) -> String {
        let values = Pixels(texture).values
        let digest = values.withUnsafeBytes { SHA256.hash(data: $0) }
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
