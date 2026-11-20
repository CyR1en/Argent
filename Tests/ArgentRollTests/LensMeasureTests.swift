import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The in-house decoder's lens corrections against the camera's own JPEG and Apple's decoder,
/// behind docs/decoder.md, section 13. Gated like the other measurement suites (ARGENT_MEASURE=1),
/// in a release build with testing on.
@Suite(.serialized) struct LensMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }
    static let root = FrameViewMeasureTests.root
    static func corpus(_ path: String) -> URL { root.appendingPathComponent("references/corpus/" + path) }

    typealias M = InHouseDecoderMeasureTests

    /// Frames with each kind of lens data: two whose camera was set to correct distortion (0x7036
    /// 17), which Apple's decoder corrects, and three of two lenses set not to (0), which it leaves.
    /// Only the CC0 frames may choose anything; the rest are evaluation (docs/provenance.md).
    static let frames: [(name: String, url: URL)] = [
        ("CC0 lossless L, FE 50mm F2.5 G at f/5.6, setting 17", M.lossless),
        ("CC0 uncompressed, the same", root.appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")),
        ("still life ISO 100, FE 55mm F1.8 ZA at f/8, setting 17", corpus("imaging-resource-a7iv-wayback/A7M4hSLI000100NR0.ARW")),
        ("sony_a7_iv_13, Tamron 28-75mm at 28mm, setting 0", corpus("photographyblog-a7iv/sony_a7_iv_13.arw")),
        ("sony_a7_iv_22, Tamron 28-75mm at 75mm, setting 0", corpus("photographyblog-a7iv/sony_a7_iv_22.arw")),
        ("sony_a7_iv_71, FE 50mm F1.2 GM at f/1.2, setting 0", corpus("photographyblog-a7iv/sony_a7_iv_71.arw")),
    ]

    static var lensOff: DecodeOptions {
        var options = DecodeOptions()
        options.lensCorrection = false
        return options
    }

    /// Where the in-house decode puts the picture against Apple's production decode, with its
    /// distortion correction and without: on a 15 by 10 grid, the shift of each channel's detail
    /// (`Registration`, 96-px patches, correlation at least 0.5), by ring of the half diagonal, the
    /// green's size (median, 95th percentile, largest) and its radial part, and how far red and blue
    /// sit from green in ours against Apple's (the colour fringes); then the brightness of ours
    /// over Apple's by ring (vignetting). ARGENT_SCENE filters by file name.
    @Test(.enabled(if: LensMeasureTests.enabled))
    func againstApple() throws {
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let only = ProcessInfo.processInfo.environment["ARGENT_SCENE"]
        for (name, url) in Self.frames where only == nil || url.path.contains(only!) {
            let theirs = Pixels(try apple.decode(url, options: DecodeOptions()).texture)
            for (label, options) in [("in-house", DecodeOptions()), ("in-house, lens correction off", Self.lensOff)] {
                let ours = Pixels(try M.inHouse(url, decoder: decoder, gpu: gpu, options: options).texture)
                let cx = Double(ours.width - 1) / 2, cy = Double(ours.height - 1) / 2
                let rMax = Double(ours.width * ours.width + ours.height * ours.height).squareRoot() / 2
                var rings = [[(size: Double, radial: Double, red: Double, blue: Double)]](repeating: [], count: 5)
                let side = 96, reach = 16
                for j in 0..<10 {
                    for i in 0..<15 {
                        let x = side / 2 + reach + i * (ours.width - side - 2 * reach) / 14
                        let y = side / 2 + reach + j * (ours.height - side - 2 * reach) / 9
                        let g = Registration.shift(theirs, ours, centreX: x, centreY: y, side: side, channel: 1, reach: reach)
                        guard g.correlation >= 0.5 else { continue }
                        let r = Registration.shift(theirs, ours, centreX: x, centreY: y, side: side, channel: 0, reach: reach)
                        let b = Registration.shift(theirs, ours, centreX: x, centreY: y, side: side, channel: 2, reach: reach)
                        let vx = Double(x) - cx, vy = Double(y) - cy, radius = (vx * vx + vy * vy).squareRoot()
                        let ring = min(4, Int(radius / rMax * 5))
                        rings[ring].append(((g.x * g.x + g.y * g.y).squareRoot(), (g.x * vx + g.y * vy) / max(radius, 1),
                                            ((r.x - g.x) * (r.x - g.x) + (r.y - g.y) * (r.y - g.y)).squareRoot(),
                                            ((b.x - g.x) * (b.x - g.x) + (b.y - g.y) * (b.y - g.y)).squareRoot()))
                    }
                }
                let text = rings.enumerated().map { k, v in
                    v.isEmpty ? String(format: "%.1f-%.1f none", Double(k) / 5, Double(k + 1) / 5)
                        : String(format: "%.1f-%.1f (n %d) green %.2f / %.2f / %.2f px, radial %+.2f, red-green %.2f, blue-green %.2f (p95)",
                                 Double(k) / 5, Double(k + 1) / 5, v.count, Stats.median(v.map(\.size)), Stats.percentile(v.map(\.size), 0.95),
                                 v.map(\.size).max()!, Stats.median(v.map(\.radial)), Stats.percentile(v.map(\.red), 0.95),
                                 Stats.percentile(v.map(\.blue), 0.95))
                }
                print("MEASURE \(name), \(label) against Apple production, where the detail sits: " + text.joined(separator: "; "))
                // Brightness by ring, 32-px block means.
                let block = 32, mo = ours.blockMeans(block, clipAbove: 3), mt = theirs.blockMeans(block, clipAbove: 3)
                let across = ours.width / block
                var stops = [[Double]](repeating: [], count: 10)
                for k in mo.indices {
                    guard let o = mo[k], let t = mt[k] else { continue }
                    let lo = M.luminance(o), lt = M.luminance(t)
                    guard lo > 0.02, lt > 0.02 else { continue }
                    let vx = (Double(k % across) + 0.5) * Double(block) - Double(ours.width) / 2
                    let vy = (Double(k / across) + 0.5) * Double(block) - Double(ours.height) / 2
                    stops[min(9, Int((vx * vx + vy * vy).squareRoot() / rMax * 10))].append(log2(lo / lt))
                }
                print("MEASURE \(name), \(label) over Apple production, stops by ring: "
                      + stops.enumerated().map { String(format: "%.1f %+.3f", Double($0.offset) / 10, Stats.median($0.element)) }.joined(separator: ", "))
            }
        }
    }

    /// LC2's decode routes. All measurements stay in the log; a failed route verdict is data.
    @Test(.enabled(if: LensMeasureTests.enabled))
    func routes() throws {
        let gpu = try GPU(maxIdlePoolBytes: 0)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        var frames = [M.lossless,
                      Self.root.appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW"),
                      Self.root.appendingPathComponent("samples/ILCE-7M4_DSC06675_FullFrame-LossLess-Compressed-Medium.ARW")]
        if let folder = ProcessInfo.processInfo.environment["ARGENT_LENS_FRAMES"] {
            frames += try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.uppercased() == "ARW" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            print("ROUTE_SKIP\tprivate frames\tARGENT_LENS_FRAMES is not set")
        }
        func row(_ kind: String, _ fields: Any...) {
            print(([kind] + fields.map { String(describing: $0) }).joined(separator: "\t"))
        }
        for url in frames {
            let name = url.deletingPathExtension().lastPathComponent
            let lens = SonyLensCorrection.read(from: url), curve = lens?.distortion
            row("ROUTE_META", name, lens?.distortionSetting ?? -1, curve?.knots.map(String.init).joined(separator: ",") ?? "")
            var decoded: [String: Pixels] = [:]
            for label in ["raw9-on", "raw9-off", "raw8-on", "raw8-off", "inhouse-off", "inhouse-on"] {
                if label.hasPrefix("inhouse"), !InHouseDecoder.supports(url) || (label == "inhouse-on" && curve == nil) {
                    row("ROUTE_SKIP", name, label + " unsupported")
                    continue
                }
                var options = DecodeOptions()
                options.lensCorrection = label.hasSuffix("-on")
                options.appleDecoder = label.hasPrefix("raw9") ? .learned : .classic
                options.tileSize = RollDeveloper.decodeTile
                options.learnedTileSize = RollDeveloper.learnedDecodeTile
                let start = CFAbsoluteTimeGetCurrent()
                let frame: LinearFrame
                do {
                    frame = try label.hasPrefix("inhouse") ? decoder.decode(url, options: options) : apple.decode(url, options: options)
                } catch DecodeError.versionUnsupported(_, _) {
                    row("ROUTE_SKIP", name, label + " unsupported")
                    continue
                }
                let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
                decoded[label] = Pixels(frame.texture)
                row("ROUTE_DECODE", name, label, frame.width, frame.height, milliseconds)
            }
            for (a, b) in [("raw9-on", "raw9-off"), ("raw8-on", "raw8-off"),
                           ("raw9-off", "inhouse-off"), ("raw8-off", "inhouse-off"), ("inhouse-on", "raw9-on")] {
                guard let moved = decoded[a], let reference = decoded[b] else { continue }
                let pair = a + "/" + b
                guard moved.width == reference.width, moved.height == reference.height else {
                    row("ROUTE_SKIP", name, pair + " extent mismatch")
                    continue
                }
                let cx = Double(reference.width - 1) / 2, cy = Double(reference.height - 1) / 2
                let rMax = Double(reference.width * reference.width + reference.height * reference.height).squareRoot() / 2
                var rings = [[(size: Double, radial: Double, red: Double, blue: Double)]](repeating: [], count: 5)
                var energies = [[Double]](repeating: [], count: 5), stationary = energies, noises = energies
                var fit: [(x: Double, y: Double, px: Double, py: Double)] = []
                let side = 96, reach = 16
                for j in 0..<10 {
                    for i in 0..<15 {
                        let x = side / 2 + reach + i * (reference.width - side - 2 * reach) / 14
                        let y = side / 2 + reach + j * (reference.height - side - 2 * reach) / 9
                        let vx = Double(x) - cx, vy = Double(y) - cy, radius = hypot(vx, vy)
                        let predicted = curve.map { radius * abs((1 + $0.value(at: radius / rMax) / 16384)
                            / (1 + $0.value(at: 1) / 16384) - 1) } ?? 0
                        // Keep the same grid, but search far enough for the file's curve, with
                        // room for the inverse map and rounding. Multiples of four include zero.
                        let search = a.hasSuffix("-on") && b.hasSuffix("-off") ? max(reach, 4 * Int(ceil((1.25 * predicted + 8) / 4))) : reach
                        let g = Registration.shift(moved, reference, centreX: x, centreY: y, side: side, channel: 1, reach: search)
                        guard g.correlation >= 0.5, abs(g.x) < Double(search), abs(g.y) < Double(search) else { continue }
                        let r = Registration.shift(moved, reference, centreX: x, centreY: y, side: side, channel: 0, reach: search)
                        let b = Registration.shift(moved, reference, centreX: x, centreY: y, side: side, channel: 2, reach: search)
                        let ring = min(4, Int(radius / rMax * 5)), size = hypot(g.x, g.y)
                        rings[ring].append((size, (g.x * vx + g.y * vy) / max(radius, 1),
                                            r.correlation >= 0.5 ? hypot(r.x - g.x, r.y - g.y) : .nan,
                                            b.correlation >= 0.5 ? hypot(b.x - g.x, b.y - g.y) : .nan))
                        if a.hasSuffix("-on"), pair.hasSuffix("-off"), let curve {
                            // Registration finds on's q for off's x. Predict q - x from the file's
                            // source map at q, including the corner divisor, without a small-shift approximation.
                            let qx = vx + g.x, qy = vy + g.y
                            let factor = (1 + curve.value(at: hypot(qx, qy) / rMax) / 16384)
                                / (1 + curve.value(at: 1) / 16384) - 1
                            fit.append((g.x, g.y, -qx * factor, -qy * factor))
                        }
                        if a.hasSuffix("-on") {
                            var patches: [[Float]] = [[], []]
                            for (k, pixels) in [moved, reference].enumerated() {
                                for yy in (y - side / 2)..<(y + side / 2) {
                                    for xx in (x - side / 2)..<(x + side / 2) {
                                        patches[k].append(Float(M.luminance(pixels.rgb(xx, yy))))
                                    }
                                }
                            }
                            let bands = patches.map { Double(AutoMeasureTests.bands($0, width: side)[0]) }
                            let ratio = bands[0] * bands[0] / (bands[1] * bands[1])
                            if ratio.isFinite { energies[ring].append(ratio) }
                            if size <= 0.10 {
                                if ratio.isFinite { stationary[ring].append(ratio) }
                                let noise = patches.map { Double(AutoMeasureTests.flatNoise($0, width: side, columns: 0..<side, rows: 0..<side)) }
                                let mean = Double(patches[1].reduce(0, +)) / Double(side * side)
                                if mean > 0.02, noise[1] / mean < 0.02, noise[1] > 0 {
                                    noises[ring].append(noise[0] / noise[1])
                                }
                            }
                        }
                    }
                }
                for (k, v) in rings.enumerated() {
                    row("ROUTE", name, pair, k, v.count, Stats.median(v.map(\.size)), Stats.percentile(v.map(\.size), 0.95),
                        Stats.median(v.map(\.radial)), Stats.percentile(v.map(\.red).filter(\.isFinite), 0.95),
                        Stats.percentile(v.map(\.blue).filter(\.isFinite), 0.95))
                    if pair == "inhouse-on/raw9-on" { row("ROUTE_MAX", name, pair, k, v.map(\.size).max() ?? .nan) }
                    if a.hasSuffix("-on") {
                        row("ROUTE_DETAIL", name, pair, k, energies[k].count, Stats.median(energies[k]), stationary[k].count,
                            Stats.median(stationary[k]), noises[k].count, Stats.median(noises[k]))
                    }
                }
                let shifts = rings.flatMap { $0.map(\.size) }
                row("ROUTE_SUMMARY", name, pair, shifts.count, Stats.median(shifts), Stats.percentile(shifts, 0.95))
                if !fit.isEmpty {
                    let power = fit.reduce(0) { $0 + $1.px * $1.px + $1.py * $1.py }
                    let gain = fit.reduce(0) { $0 + $1.x * $1.px + $1.y * $1.py } / power
                    let rms = (fit.reduce(0) { $0 + pow($1.x - $1.px, 2) + pow($1.y - $1.py, 2) } / Double(fit.count)).squareRoot()
                    let fitted = (fit.reduce(0) { $0 + pow($1.x - gain * $1.px, 2) + pow($1.y - gain * $1.py, 2) } / Double(fit.count)).squareRoot()
                    row("ROUTE_FIT", name, pair, fit.count, gain, rms, fitted,
                        Stats.median(fit.map { hypot($0.px, $0.py) }))
                }
                if b == "inhouse-off" {
                    // Pearson correlation on each outermost two-row or two-column strip, green.
                    for edge in ["top", "bottom", "left", "right"] {
                        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
                        let horizontal = edge == "top" || edge == "bottom"
                        for t in 0..<(horizontal ? reference.width : reference.height) {
                            for d in 0..<2 {
                                let x = horizontal ? t : (edge == "left" ? d : reference.width - 1 - d)
                                let y = horizontal ? (edge == "bottom" ? d : reference.height - 1 - d) : t
                                let p = moved.rgb(x, y).y, q = reference.rgb(x, y).y
                                n += 1; sx += p; sy += q; sxx += p * p; syy += q * q; sxy += p * q
                            }
                        }
                        row("ROUTE_EDGE", name, pair, edge, (n * sxy - sx * sy) / sqrt((n * sxx - sx * sx) * (n * syy - sy * sy)))
                    }
                } else {
                    let block = 32, on = moved.blockMeans(block, clipAbove: 3), off = reference.blockMeans(block, clipAbove: 3)
                    let across = reference.width / block
                    var brightness = [[Double]](repeating: [], count: 5)
                    for k in off.indices {
                        guard let p = on[k], let q = off[k], M.luminance(p) > 0.02, M.luminance(q) > 0.02 else { continue }
                        let vx = (Double(k % across) + 0.5) * Double(block) - cx
                        let vy = (Double(k / across) + 0.5) * Double(block) - cy
                        brightness[min(4, Int(hypot(vx, vy) / rMax * 5))].append(M.luminance(p) / M.luminance(q))
                    }
                    for (k, v) in brightness.enumerated() { row("ROUTE_TONE", name, pair, k, v.count, Stats.median(v)) }
                }
            }
        }
    }

    /// The prints, as milestone 2a measured them: the in-house decode against Apple's production
    /// decode through Portra 400 at box speed with grain, halation and capture sharpening, the same
    /// grain seed, Delta E 2000 per pixel and on 8-pixel blocks, with the in-house distortion
    /// correction and without; and Apple's own production print against its print with lens
    /// correction off, the size of what the correction does. The frames above and the still life
    /// up the ladder. ARGENT_SCENE filters by file name.
    @Test(.enabled(if: LensMeasureTests.enabled))
    func printsAgainstApple() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let stock = try Stock.load(from: Self.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let settings = DevelopSettings(grain: 1, grainSeed: 7, halation: true, sharpen: true)
        let only = ProcessInfo.processInfo.environment["ARGENT_SCENE"]
        let ladder = [400, 1600, 6400].map { ("still life ISO \($0)", Self.corpus(String(format: "imaging-resource-a7iv-wayback/A7M4hSLI%06dNR0.ARW", $0))) }
        for (name, url) in Self.frames + ladder where only == nil || url.path.contains(only!) {
            func print(_ frame: LinearFrame) throws -> Pixels { Pixels(try renderer.render(frame, settings: settings).image.texture) }
            let theirs = try print(try apple.decode(url, options: DecodeOptions()))
            let theirsOff = try print(try apple.decode(url, options: Self.lensOff))
            var line = "MEASURE \(name), prints against Apple production:"
            for (label, other) in [("in-house", try print(try M.inHouse(url, decoder: decoder, gpu: gpu))),
                                   ("in-house, lens correction off", try print(try M.inHouse(url, decoder: decoder, gpu: gpu, options: Self.lensOff))),
                                   ("Apple, lens correction off", theirsOff)] {
                let pixel = Stats.deltaE(other, theirs, block: 1), block = Stats.deltaE(other, theirs, block: 8)
                line += String(format: " %@ per pixel mean %.2f, p95 %.2f; 8-px blocks mean %.2f, p95 %.2f;", label, pixel.mean, pixel.p95, block.mean, block.p95)
            }
            Swift.print(line)
        }
    }

    /// Writes decodes as NumPy files of half-float RGB, rows top down, for the scripts that fit the
    /// file's correction model: ARGENT_DUMP_FILES lists the raws, ARGENT_DUMP_DIR the folder, and
    /// ARGENT_DUMP_KINDS any of `apple` (production pins), `apple-lens-off` (production but lens
    /// correction off), `inhouse` and `inhouse-lens-off`.
    @Test(.enabled(if: LensMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_DUMP_FILES"] != nil))
    func dump() throws {
        let environment = ProcessInfo.processInfo.environment
        let files = environment["ARGENT_DUMP_FILES"]!.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let folder = URL(fileURLWithPath: environment["ARGENT_DUMP_DIR"] ?? NSTemporaryDirectory())
        let kinds = (environment["ARGENT_DUMP_KINDS"] ?? "apple,apple-lens-off").split(separator: ",").map(String.init)
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        for url in files {
            for kind in kinds {
                var options = DecodeOptions()
                options.lensCorrection = !kind.hasSuffix("lens-off")
                let frame = kind.hasPrefix("apple")
                    ? try apple.decode(url, options: options)
                    : try InHouseDecoderMeasureTests.inHouse(url, decoder: decoder, gpu: gpu, options: options)
                let name = url.deletingPathExtension().lastPathComponent + "-" + kind + ".npy"
                try Self.writeNumPy(Pixels(frame.texture), to: folder.appendingPathComponent(name))
                print("MEASURE wrote \(name), \(frame.width) by \(frame.height)")
            }
        }
    }

    /// Half-float RGB, rows top down, as a version 1 NumPy file.
    static func writeNumPy(_ pixels: Pixels, to url: URL) throws {
        var header = "{'descr': '<f2', 'fortran_order': False, 'shape': (\(pixels.height), \(pixels.width), 3), }"
        while (10 + header.count + 1) % 64 != 0 { header += " " }
        header += "\n"
        var data = Data([0x93] + Array("NUMPY".utf8) + [1, 0])
        data.append(contentsOf: [UInt8(header.count & 0xFF), UInt8(header.count >> 8)])
        data.append(contentsOf: Array(header.utf8))
        var out = [Float16](repeating: 0, count: pixels.width * pixels.height * 3)
        for y in 0..<pixels.height {
            let source = (pixels.height - 1 - y) * pixels.width * 4, target = y * pixels.width * 3
            for x in 0..<pixels.width {
                for c in 0..<3 { out[target + x * 3 + c] = pixels.values[source + x * 4 + c] }
            }
        }
        out.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}

extension LensMeasureTests {
    /// Registration of the stage against each Apple decoder's own warp. This is descriptive, not a claim that Apple's reading is
    /// ground truth: 150 green patches, 96 pixels square, correlation >= 0.5, with search-boundary matches excluded.
    @Test(.enabled(if: LensMeasureTests.enabled))
    func stageAgainstDecoder() throws {
        let samples = Self.root.appendingPathComponent("samples")
        var urls = try FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "arw" }
        if let folder = ProcessInfo.processInfo.environment["ARGENT_LENS_FRAMES"] {
            urls += try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "arw" }
        }
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for version in [AppleDecoderVersion.classic, .learned] {
                try autoreleasepool {
                    let gpu = try GPU(maxIdlePoolBytes: 0), stage = try LensStage(gpu: gpu)
                    let decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
                    var options = DecodeOptions()
                    options.appleDecoder = version
                    options.tileSize = version == .learned ? RollDeveloper.learnedDecodeTile : RollDeveloper.decodeTile
                    let reference: Pixels
                    do { reference = Pixels(try decoder.decode(url, options: options).texture) }
                    catch DecodeError.versionUnsupported {
                        print("LC5_STAGE \(url.lastPathComponent) RAW\(version.rawValue) unavailable")
                        return
                    }
                    options.lensCorrection = false
                    let decoded = try decoder.decode(url, options: options)
                    let layout = try ARWLayout.read(from: url)
                    let header = try AppleRawDecoder.fullSizePicture(native: CGSize(width: layout.cropSize.width, height: layout.cropSize.height),
                                                                    orientation: .up, layout: layout)
                    let picture = try #require(decoded.picture)
                    #expect([header.width, header.height].sorted() == [picture.width, picture.height].sorted())
                    let lens = LensResolver.correction(for: url, settings: .default)
                    let scene = try stage.correct(decoded, with: lens)
                    #expect(scene.lens == lens && scene.pins?.lensCorrection == false)
                    let ours = Pixels(scene.texture)
                    #expect(ours.width == reference.width && ours.height == reference.height)
                    let side = 96, reach = 16
                    var shifts: [Double] = []
                    for j in 0..<10 {
                        for i in 0..<15 {
                            let x = side / 2 + reach + i * (ours.width - side - 2 * reach) / 14
                            let y = side / 2 + reach + j * (ours.height - side - 2 * reach) / 9
                            let g = Registration.shift(ours, reference, centreX: x, centreY: y, side: side, channel: 1, reach: reach)
                            if g.correlation >= 0.5, abs(g.x) < Double(reach - 1), abs(g.y) < Double(reach - 1) {
                                if shifts.isEmpty {
                                    let control = Registration.shift(reference, reference, centreX: x, centreY: y,
                                                                     side: side, channel: 1, reach: reach)
                                    #expect(control.correlation > 0.999 && hypot(control.x, control.y) < 0.1)
                                }
                                shifts.append(hypot(g.x, g.y))
                            }
                        }
                    }
                    #expect(!shifts.isEmpty)
                    print(String(format: "LC5_STAGE %@ RAW%@ %@ n=%d median=%.3f p95=%.3f max=%.3f px",
                                 url.lastPathComponent, version.rawValue, lens.status.distortion.description, shifts.count,
                                 Stats.median(shifts), Stats.percentile(shifts, 0.95), shifts.max() ?? 0))
                }
            }
        }
    }
}

extension LensMeasureTests {
    /// Isolates the stage from decode and film work at the two frame-view sizes. Run with ARGENT_MEASURE=1.
    @Test(.enabled(if: LensMeasureTests.enabled))
    func stageAtFrameViewSizes() throws {
        let gpu = try GPU(), stage = try LensStage(gpu: gpu)
        let file = SonyLensCorrection(distortionSetting: 17, distortion: .init(knots: (0..<16).map { -2 * $0 * $0 }))
        let lens = LensResolver.resolve(file, picture: try MaskSpace(width: 7008, height: 4672), settings: .default)
        try #require(!lens.isIdentity && lens.status.distortion == .file)
        for side in [2190, 3800] {
            let height = side * 2 / 3
            let image = try gpu.texturePool.acquire(width: side, height: height)
            let values = [Float16](repeating: 0.18, count: side * height * 4)
            values.withUnsafeBytes {
                image.texture.replace(region: MTLRegionMake2D(0, 0, side, height), mipmapLevel: 0,
                                      withBytes: $0.baseAddress!, bytesPerRow: side * 8)
            }
            let frame = LinearFrame(image: image, decoderVersion: "stage-measure", scale: Float(side) / 7008,
                                    picture: try MaskSpace(width: 7008, height: 4672))
            for _ in 0..<2 { _ = try stage.correct(frame, with: lens) }
            var milliseconds: [Double] = []
            for _ in 0..<40 {
                let start = ContinuousClock.now
                let scene = try stage.correct(frame, with: lens)
                milliseconds.append(start.duration(to: .now).seconds * 1000)
                try #require(scene.image !== frame.image && scene.lens?.digest == lens.digest)
            }
            print(String(format: "LC7_STAGE %dx%d n=%d p50=%.3fms p95=%.3fms", side, height, milliseconds.count,
                         Stats.median(milliseconds), Stats.percentile(milliseconds, 0.95)))
        }
    }
}
