import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The in-house decoder's noise reduction against Apple's production decode, behind
/// docs/decoder.md, section 10. Gated like the other measurement suites (ARGENT_MEASURE=1, a
/// release build, one test at a time); they read the CC0 samples, the git-ignored corpus and
/// build/stocks.
///
/// Two ISO ladders: RawNIND's a7C ladder of one museum scene (CC BY-SA 4.0, the set the strengths
/// were chosen on, with the CC0 samples) and Imaging Resource's a7 IV still life (evaluation only,
/// by its terms, so it is the held-out check). Both are uncompressed, so the decoder's GPU half runs
/// on their mosaics. The a7C has its own sensor: its frames go through a colour matrix fitted here
/// to Apple's decode, for measuring only, with the level-noise tables simulated for that matrix.
@Suite(.serialized) struct InHouseNoiseMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }
    typealias M = InHouseDecoderMeasureTests

    // MARK: The ladders

    struct Frame {
        var iso: Int
        var url: URL
    }

    struct Ladder {
        var name: String
        /// The frames to measure, by ISO.
        var frames: [Frame]
        /// The cleanest frame, whose Apple decode with noise reduction off chooses the flat patches.
        var reference: URL
        /// The ColorChecker edges and the gray card (Imaging Resource's still life only).
        var stillLife: Bool
        /// Replaces the camera matrix and the gain, for another camera.
        var matrix: [[Double]]?
        /// Each frame chooses its own patches, for frames of one ISO that are not one framing.
        var ownPatches = false
        var shotNoise: [SIMD3<Float>] = InHouseNoiseReduction.shotNoise
        var readNoise: [SIMD3<Float>] = InHouseNoiseReduction.readNoise
    }

    static let stillLife: Ladder = {
        let isos = [100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200, 102400, 204800]
        func url(_ iso: Int) -> URL { M.corpus(String(format: "imaging-resource-a7iv-wayback/A7M4hSLI%06dNR0.ARW", iso)) }
        return Ladder(name: "still life (a7 IV)", frames: isos.map { Frame(iso: $0, url: url($0)) }, reference: url(50), stillLife: true)
    }()

    /// The CC0 samples, the only a7 IV raws whose licence allows choosing constants on them: one
    /// scene at ISO 250, lossless L and uncompressed.
    static let samples = Ladder(name: "CC0 samples (a7 IV)", frames: [
        Frame(iso: 250, url: M.lossless), Frame(iso: 250, url: M.root.appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")),
    ], reference: M.root.appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW"), stillLife: false, ownPatches: true)

    /// The a7C's ladder, its matrix fitted to Apple's decode of the ISO 100 frame with noise
    /// reduction off, and its level-noise tables simulated for that matrix (`InHouseNoiseReductionTests`
    /// with ARGENT_SIM_MATRIX; printed by `a7cMatrix`).
    static func a7c(gpu: GPU, decoder: InHouseDecoder, apple: AppleRawDecoder) throws -> Ladder {
        let folder = M.corpus("rawnind-a7c")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "arw" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        func iso(_ url: URL) -> Int? {
            let name = url.lastPathComponent
            guard let range = name.range(of: "_ISO"), let end = name[range.upperBound...].firstIndex(of: "_") else { return nil }
            return Int(name[range.upperBound..<end])
        }
        let reference = try #require(files.first { $0.lastPathComponent.contains("_GT_ISO50") })
        let frames = files.filter { !$0.lastPathComponent.contains("_GT_") }.compactMap { url in iso(url).map { Frame(iso: $0, url: url) } }
            .sorted { $0.iso < $1.iso }
        let base = try #require(frames.first { $0.iso == 100 })
        var ladder = Ladder(name: "museum (a7C)", frames: frames, reference: reference, stillLife: false)
        ladder.matrix = try fitMatrix(base.url, gpu: gpu, decoder: decoder, apple: apple)
        ladder.shotNoise = a7cShotNoise
        ladder.readNoise = a7cReadNoise
        return ladder
    }

    /// The a7C's level noise through its fitted matrix, simulated with the matrix `a7cMatrix` prints.
    static let a7cShotNoise: [SIMD3<Float>] = [
        SIMD3(0.7456, 0.6978, 0.9576), SIMD3(0.3372, 0.5288, 0.6311), SIMD3(0.1698, 0.2891, 0.3615),
        SIMD3(0.0853, 0.1496, 0.1867), SIMD3(0.0426, 0.0748, 0.0937), SIMD3(0.0214, 0.0374, 0.0467),
        SIMD3(0.0108, 0.0192, 0.0228),
    ]
    static let a7cReadNoise: [SIMD3<Float>] = [
        SIMD3(0.8277, 1.0440, 1.1933), SIMD3(0.3979, 0.7842, 0.7898), SIMD3(0.2019, 0.4260, 0.4506),
        SIMD3(0.1019, 0.2203, 0.2323), SIMD3(0.0516, 0.1115, 0.1169), SIMD3(0.0265, 0.0554, 0.0584),
        SIMD3(0.0150, 0.0275, 0.0296),
    ]

    /// White-balanced camera RGB (the a7 IV's gains) to Apple's output for `url`, gain included,
    /// by weighted least squares on 16-pixel block means, as `InHouseDecoderMeasureTests/colourFit`.
    static func fitMatrix(_ url: URL, gpu: GPU, decoder: InHouseDecoder, apple: AppleRawDecoder) throws -> [[Double]] {
        let source = try MeasureMosaic.load(url, device: gpu.device)
        let identity: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        let (ours, _) = try decoder.render(source.buffer, layout: source.layout, orientation: source.orientation, gainStops: 0,
                                           iso: nil, options: M.inHouseOff, matrix: identity)
        let reference = try apple.decode(url, options: M.appleOptions(lens: false, noiseReduction: false))
        let a = Pixels(ours.texture), b = Pixels(reference.texture)
        let ca = a.blockMeans(16, clipAbove: 0.9), cb = b.blockMeans(16, clipAbove: .infinity)
        var xtx = [[Double]](repeating: [0, 0, 0], count: 3), xty = xtx
        for i in ca.indices {
            guard let x = ca[i], let y = cb[i], min(x.x, x.y, x.z) > 0.003, min(y.x, y.y, y.z) > 0.003 else { continue }
            let l = max(M.luminance(y), 1e-3), w = 1 / (l * l)
            let xs = [x.x, x.y, x.z], ys = [y.x, y.y, y.z]
            for i in 0..<3 { for j in 0..<3 { xtx[i][j] += w * xs[i] * xs[j]; xty[i][j] += w * xs[i] * ys[j] } }
        }
        return Matrix3.transpose(Matrix3.multiply(Matrix3.invert(xtx), xty))
    }

    /// Prints the a7C's fitted matrix, for simulating its level-noise tables.
    @Test(.enabled(if: InHouseNoiseMeasureTests.enabled))
    func a7cMatrix() throws {
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let ladder = try Self.a7c(gpu: gpu, decoder: decoder, apple: apple)
        let m = ladder.matrix!
        print("MEASURE a7C matrix: " + m.map { $0.map { String(format: "%.6f", $0) }.joined(separator: ",") }.joined(separator: ";"))
        print("MEASURE a7C frames: " + ladder.frames.map { "\($0.iso)" }.joined(separator: ", "))
    }

    // MARK: Patches, noise and detail

    /// A 64-pixel square of a frame, in texture coordinates (rows bottom up).
    struct Patch {
        var x: Int
        var y: Int
        static let side = 64
    }

    /// Up to three of the flattest non-overlapping patches in each of four luminance bands, on
    /// `frame` (Apple's decode of the cleanest frame with noise reduction off): flattest by the
    /// standard deviation of luminance over its mean, a plane taken out.
    static func flatPatches(_ frame: Pixels) -> [Patch] {
        let side = Patch.side, step = side / 2
        let l = AutoMeasureTests.lightness(frame.values, linear: true)
        var candidates: [(patch: Patch, mean: Float, flatness: Float)] = []
        for y in stride(from: side, to: frame.height - 2 * side, by: step) {
            for x in stride(from: side, to: frame.width - 2 * side, by: step) {
                var sum: Float = 0, top: Float = 0
                for yy in y..<(y + side) { for xx in x..<(x + side) { sum += l[yy * frame.width + xx]; top = max(top, l[yy * frame.width + xx]) } }
                let mean = sum / Float(side * side)
                guard mean > 0.02, top < 2 else { continue }
                let noise = AutoMeasureTests.flatNoise(l, width: frame.width, columns: x..<(x + side), rows: y..<(y + side))
                candidates.append((Patch(x: x, y: y), mean, noise / mean))
            }
        }
        var chosen: [Patch] = []
        for (low, high) in [(Float(0.02), Float(0.06)), (0.06, 0.18), (0.18, 0.5), (0.5, 2)] {
            var picked = 0
            for c in candidates.filter({ $0.mean >= low && $0.mean < high }).sorted(by: { $0.flatness < $1.flatness }) {
                guard picked < 3 else { break }
                if chosen.contains(where: { abs($0.x - c.patch.x) < side && abs($0.y - c.patch.y) < side }) { continue }
                chosen.append(c.patch)
                picked += 1
            }
        }
        return chosen
    }

    /// Noise in a patch at mid-gray: the patch scaled so its mean luminance is 0.18, then the
    /// standard deviation of L* and of a* and b* together, each with a plane taken out.
    static func patchNoise(_ frame: Pixels, _ patch: Patch) -> (lightness: Double, chroma: Double) {
        let side = Patch.side
        var y: [Double] = [], rgb: [SIMD3<Double>] = []
        for yy in patch.y..<(patch.y + side) {
            for xx in patch.x..<(patch.x + side) {
                let c = frame.rgb(xx, yy)
                rgb.append(c)
                y.append(M.luminance(c))
            }
        }
        let scale = 0.18 / max(y.reduce(0, +) / Double(y.count), 1e-6)
        let lab = rgb.map { Colour.lab($0 * scale) }
        func deviation(_ v: [Float]) -> Double { Double(AutoMeasureTests.flatNoise(v, width: side, columns: 0..<side, rows: 0..<side)) }
        let sa = deviation(lab.map { Float($0.y) }), sb = deviation(lab.map { Float($0.z) })
        return (deviation(lab.map { Float($0.x) }), (sa * sa + sb * sb).squareRoot())
    }

    /// The medians over the patches.
    static func noise(_ frame: Pixels, _ patches: [Patch]) -> (lightness: Double, chroma: Double) {
        let n = patches.map { patchNoise(frame, $0) }
        return (Stats.median(n.map(\.lightness)), Stats.median(n.map(\.chroma)))
    }

    /// The noise's spectrum: the RMS of L*, and of a* and b* together, in the three bands of
    /// `AutoMeasureTests.bands` (near 0.31, 0.15 and 0.08 cycles a pixel) over each patch's middle,
    /// at mid-gray as in `patchNoise`, the median over the patches.
    static func noiseBands(_ frame: Pixels, _ patches: [Patch]) -> (lightness: [Double], chroma: [Double]) {
        let side = Patch.side
        var lBands: [[Double]] = [[], [], []], cBands: [[Double]] = [[], [], []]
        for patch in patches {
            var rgb: [SIMD3<Double>] = []
            for yy in patch.y..<(patch.y + side) { for xx in patch.x..<(patch.x + side) { rgb.append(frame.rgb(xx, yy)) } }
            let scale = 0.18 / max(rgb.map(M.luminance).reduce(0, +) / Double(rgb.count), 1e-6)
            let lab = rgb.map { Colour.lab($0 * scale) }
            func bands(_ v: [Float]) -> [Double] {
                let blurs = [0.5, 1, 2, 4].map { AutoMeasureTests.blurred(v, side: side, sigma: Float($0)) }
                return (0..<3).map { b in
                    var squares = 0.0, n = 0.0
                    for y in 16..<(side - 16) { for x in 16..<(side - 16) {
                        let d = Double(blurs[b][y * side + x] - blurs[b + 1][y * side + x]); squares += d * d; n += 1 } }
                    return (squares / n).squareRoot()
                }
            }
            let l = bands(lab.map { Float($0.x) }), a = bands(lab.map { Float($0.y) }), b = bands(lab.map { Float($0.z) })
            for i in 0..<3 {
                lBands[i].append(l[i])
                cBands[i].append((a[i] * a[i] + b[i] * b[i]).squareRoot())
            }
        }
        return (lBands.map(Stats.median), cBands.map(Stats.median))
    }

    static func bandRatio(_ a: [Double], _ b: [Double]) -> String {
        zip(a, b).map { String(format: "%.2f", $0 / $1) }.joined(separator: ", ")
    }

    /// Detail: the three bands of `AutoMeasureTests.bands` over the central square, in L* of the
    /// decode, and on the still life the 10 to 90 percent rise of the white and middle-gray edges
    /// in scene-linear luminance.
    struct Detail {
        var bands: [Float]
        var white: Float?
        var gray: Float?
    }

    static func detail(_ frame: Pixels, stillLife: Bool) -> Detail {
        let lightness = AutoMeasureTests.lightness(frame.values)
        var d = Detail(bands: AutoMeasureTests.bands(lightness, width: frame.width))
        if stillLife {
            let l = AutoMeasureTests.lightness(frame.values, linear: true)
            let rows = (frame.height - 4040)..<(frame.height - 3985)
            d.white = AutoMeasureTests.edge(l, width: frame.width, columns: 3270..<3330, rows: rows, reach: 8).rise
            d.gray = AutoMeasureTests.edge(l, width: frame.width, columns: 3595..<3650, rows: rows, reach: 8).rise
        }
        return d
    }

    /// The three bands of `AutoMeasureTests.bands` as images of the central square, in L*.
    static func bandImages(_ frame: Pixels) -> [[Float]] {
        let (square, side) = AutoMeasureTests.centre(AutoMeasureTests.lightness(frame.values), width: frame.width)
        let blurs = [0.5, 1, 2, 4].map { AutoMeasureTests.blurred(square, side: side, sigma: Float($0)) }
        return (0..<3).map { b in zip(blurs[b], blurs[b + 1]).map { $0 - $1 } }
    }

    /// Detail retained against a clean frame of the same scene, per band: the share of the clean
    /// frame's band that the noisy one holds, `<noisy, clean> / <clean, clean>`.
    static func retained(_ noisy: [[Float]], _ clean: [[Float]]) -> [Double] {
        zip(noisy, clean).map { n, c in
            var nc = 0.0, cc = 0.0
            for i in c.indices { nc += Double(n[i]) * Double(c[i]); cc += Double(c[i]) * Double(c[i]) }
            return nc / cc
        }
    }

    static func ratio(_ a: Detail, _ b: Detail) -> String {
        var text = "bands " + zip(a.bands, b.bands).map { String(format: "%.2f", $0 / $1) }.joined(separator: ", ")
        if let aw = a.white, let bw = b.white, let ag = a.gray, let bg = b.gray {
            text += String(format: "; white edge %.2f px (Apple %.2f), gray %.2f (Apple %.2f)", aw, bw, ag, bg)
        }
        return text
    }

    /// The in-house decode of a loaded mosaic with `tuning`, or with the options' noise reduction
    /// when `tuning` is nil.
    static func render(_ source: MeasureMosaic, ladder: Ladder, decoder: InHouseDecoder, options: DecodeOptions = DecodeOptions(),
                       tuning: InHouseNoiseReduction.Tuning?) throws -> LinearFrame {
        let iso = source.iso.map(Float.init)
        var chosen = tuning
        if chosen == nil, ladder.matrix != nil {
            chosen = InHouseNoiseReduction.tuning(luminance: options.luminanceNoiseReduction ?? NoiseReduction.luminanceAmount(iso: iso),
                                                  colour: options.colorNoiseReduction, iso: iso)
        }
        chosen?.shotNoise = ladder.shotNoise
        chosen?.readNoise = ladder.readNoise
        // The fitted matrix holds the gain at ISO 100; below it the anchor adds more.
        let extra = Double(exp2(ExposureAnchor.gainStops(iso: iso) - ExposureAnchor.gainStops(iso: 100)))
        return try decoder.render(source.buffer, layout: source.layout, orientation: source.orientation,
                                  gainStops: ExposureAnchor.gainStops(iso: iso), iso: iso, options: options,
                                  matrix: ladder.matrix?.map { $0.map { $0 * extra } }, tuning: chosen).0
    }

    /// The first four patches side by side, each 128 pixels around it, at mid-gray, as an sRGB PNG.
    static func dump(_ frame: Pixels, _ patches: [Patch], to url: URL) throws {
        let side = 128, count = min(4, patches.count)
        var bytes = [UInt8](repeating: 0, count: side * count * side * 4)
        for (k, patch) in patches.prefix(count).enumerated() {
            let x0 = max(0, patch.x - 32), y0 = max(0, patch.y - 32)
            var sum = 0.0
            for y in 0..<Patch.side { for x in 0..<Patch.side { sum += M.luminance(frame.rgb(patch.x + x, patch.y + y)) } }
            let scale = 0.18 / max(sum / Double(Patch.side * Patch.side), 1e-6)
            for y in 0..<side {
                for x in 0..<side {
                    let c = frame.rgb(min(x0 + x, frame.width - 1), min(y0 + y, frame.height - 1)) * scale
                    // Rec. 2020 to Rec. 709, roughly, then the sRGB curve.
                    let r709 = 1.6605 * c.x - 0.5876 * c.y - 0.0728 * c.z
                    let g709 = -0.1246 * c.x + 1.1329 * c.y - 0.0083 * c.z
                    let b709 = -0.0182 * c.x - 0.1006 * c.y + 1.1187 * c.z
                    let i = ((side - 1 - y) * side * count + k * side + x) * 4
                    for (j, v) in [r709, g709, b709].enumerated() {
                        let e = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(max(v, 0), 1 / 2.4) - 0.055
                        bytes[i + j] = UInt8(max(0, min(255, (e * 255).rounded())))
                    }
                    bytes[i + 3] = 255
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: side * count, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * count * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The strengths as fitted on the a7C ladder alone, before the a7 IV's anchor raised the low
    /// tier and the high tier with it (`ARGENT_TUNINGS=a7c`).
    static func a7cTuning(iso: Float?) -> InHouseNoiseReduction.Tuning {
        let low: [(iso: Float, strength: Float)] = [(100, 0.05), (250, 0.30), (640, 0.43), (1600, 0.45)]
        let high: [(iso: Float, strength: Float)] = [(1600, 0.55), (6400, 0.65)]
        let amount = NoiseReduction.luminanceAmount(iso: iso)
        let extreme = amount == NoiseReduction.extremeISOLuminance
        let table = extreme ? InHouseNoiseReduction.extremeTier : amount == NoiseReduction.highISOLuminance ? high : low
        return InHouseNoiseReduction.Tuning(luminanceAmount: amount, colourAmount: 0.5,
                                            luminance: InHouseNoiseReduction.strength(at: iso ?? 100, table), colour: 4,
                                            impulse: extreme ? InHouseNoiseReduction.extremeImpulse : 0)
    }

    // MARK: Prints

    /// What a user sees: the in-house decode against Apple's production decode, both through
    /// Portra 400 at box speed with grain, halation and capture sharpening as a develop has them, the
    /// same grain seed, Delta E 2000 per pixel and on 8-pixel blocks; and the in-house decode with
    /// its noise reduction off, against the same; and both against Apple's production decode with
    /// its lens correction off. M1's five scenes and the still life up the ladder.
    @Test(.enabled(if: InHouseNoiseMeasureTests.enabled))
    func printsAgainstApple() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let settings = DevelopSettings(grain: 1, grainSeed: 7, halation: true, sharpen: true)
        let only = ProcessInfo.processInfo.environment["ARGENT_SCENE"]
        let scenes = [M.lossless, M.corpus("photographyblog-a7iv/sony_a7_iv_22.arw"), M.corpus("photographyblog-a7iv/sony_a7_iv_05.arw"),
                      M.corpus("photographyblog-a7iv/sony_a7_iv_13.arw")]
            + [100, 400, 1600, 6400, 25600, 102400].map { M.corpus(String(format: "imaging-resource-a7iv-wayback/A7M4hSLI%06dNR0.ARW", $0)) }
        for url in scenes where only == nil || url.path.contains(only!) {
            let ours = try [DecodeOptions(), M.inHouseOff].map {
                Pixels(try renderer.render(try M.inHouse(url, decoder: decoder, gpu: gpu, options: $0), settings: settings).image.texture)
            }
            // Apple's production decode, and the same with its lens correction off, which isolates
            // the noise reduction where Apple corrects distortion.
            for lens in [true, false] {
                let theirs = Pixels(try renderer.render(try apple.decode(url, options: M.appleOptions(lens: lens, noiseReduction: true)),
                                                        settings: settings).image.texture)
                var line = "MEASURE \(url.lastPathComponent) print against Apple production\(lens ? "" : ", lens off"):"
                for (name, print) in zip(["in-house", "in-house NR off"], ours) {
                    let pixel = Stats.deltaE(print, theirs, block: 1), block = Stats.deltaE(print, theirs, block: 8)
                    line += String(format: " %@ per pixel mean %.2f, p95 %.2f; 8-px blocks mean %.2f, p95 %.2f;", name, pixel.mean, pixel.p95, block.mean, block.p95)
                }
                print(line)
            }
        }
    }

    // MARK: Choosing the strengths

    /// Noise and detail against Apple's production decode across a ladder for a set of tunings.
    /// ARGENT_LADDER picks `a7c` (the default) or `stilllife`; ARGENT_TUNINGS lists tunings as
    /// `luminance,colour[,impulse[,flatLow,flatHigh]]` separated by `;`, and `tier` stands for the
    /// committed strengths at the frame's ISO tier; ARGENT_LPROFILE and ARGENT_CPROFILE set the
    /// level profiles.
    @Test(.enabled(if: InHouseNoiseMeasureTests.enabled))
    func tuningSweep() throws {
        let env = ProcessInfo.processInfo.environment
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let ladder = env["ARGENT_LADDER"] == "stilllife" ? Self.stillLife
            : env["ARGENT_LADDER"] == "samples" ? Self.samples : try Self.a7c(gpu: gpu, decoder: decoder, apple: apple)
        let only = env["ARGENT_ISOS"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let specs = (env["ARGENT_TUNINGS"] ?? "tier").split(separator: ";").map(String.init)
        let patches = Self.flatPatches(Pixels(try apple.decode(ladder.reference, options: M.appleOptions(lens: false, noiseReduction: false)).texture))
        print("MEASURE \(ladder.name): \(patches.count) flat patches")
        // A clean frame of the scene, each decoder's own: detail retained is measured against it.
        var clean: (apple: [[Float]], ours: [[Float]])?
        if ladder.matrix != nil {
            let source = try MeasureMosaic.load(ladder.reference, device: gpu.device)
            clean = (Self.bandImages(Pixels(try apple.decode(ladder.reference, options: DecodeOptions()).texture)),
                     Self.bandImages(Pixels(try Self.render(source, ladder: ladder, decoder: decoder, tuning: nil).texture)))
        }
        for frame in ladder.frames where only == nil || only!.contains(frame.iso) {
            let source = try MeasureMosaic.load(frame.url, device: gpu.device)
            let production = Pixels(try apple.decode(frame.url, options: DecodeOptions()).texture)
            let off = Pixels(try apple.decode(frame.url, options: M.appleOptions(lens: false, noiseReduction: false)).texture)
            let patches = ladder.ownPatches ? Self.flatPatches(off) : patches
            let target = Self.noise(production, patches), offNoise = Self.noise(off, patches)
            let targetBands = Self.noiseBands(production, patches)
            let appleRetained = clean.map { Self.retained(Self.bandImages(production), $0.apple) }
            if let appleRetained { print("MEASURE ISO \(frame.iso) Apple production retains " + appleRetained.map { String(format: "%.2f", $0) }.joined(separator: ", ")) }
            let targetDetail = Self.detail(production, stillLife: ladder.stillLife)
            let sensor = SensorNoise.estimate(source.buffer.contents().bindMemory(to: UInt16.self, capacity: source.buffer.length / 2), layout: source.layout)
            var p = InHouseDecoder.parameters(for: source.layout, orientation: source.orientation,
                                              gainStops: ExposureAnchor.gainStops(iso: source.iso.map(Float.init)))
            if let m = ladder.matrix?.map({ $0.map(Float.init) }) { p.matrix = (m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2]) }
            let (a, b) = InHouseNoiseReduction.reference(noise: sensor, parameters: p)
            print(String(format: "MEASURE ISO %d sensor noise: shot %.3f, read %.2f DN squared; reference noise at 0.18 is %.2f%%",
                         frame.iso, sensor.shot, sensor.read, (a * 0.18 + b).squareRoot() / 0.18 * 100))
            print(String(format: "MEASURE ISO %d Apple production L* %.3f, chroma %.3f; NR off L* %.3f, chroma %.3f; NR off over production: %@",
                         frame.iso, target.lightness, target.chroma, offNoise.lightness, offNoise.chroma,
                         Self.ratio(Self.detail(off, stillLife: ladder.stillLife), targetDetail)))
            for spec in specs {
                let tuning: InHouseNoiseReduction.Tuning?
                if spec == "tier" {
                    tuning = nil
                } else if spec == "a7c" {
                    tuning = Self.a7cTuning(iso: source.iso.map(Float.init))
                } else {
                    let v = spec.split(separator: ",").compactMap { Float($0) }
                    var t = InHouseNoiseReduction.Tuning(luminanceAmount: -1, colourAmount: -1, luminance: v[0], colour: v[1])
                    if v.count >= 3 { t.impulse = v[2] }
                    if v.count >= 5 { t.flatLow = v[3]; t.flatHigh = v[4] }
                    if let inherit = env["ARGENT_INHERIT"]?.split(separator: ",").compactMap({ Float($0) }), inherit.count == 2 {
                        t.inherit = inherit[0]
                        t.inheritColour = inherit[1]
                    }
                    if let profile = env["ARGENT_LPROFILE"] { t.luminanceProfile = profile.split(separator: ",").compactMap { Float($0) } }
                    if let profile = env["ARGENT_CPROFILE"] { t.colourProfile = profile.split(separator: ",").compactMap { Float($0) } }
                    tuning = t
                }
                let ours = Pixels(try Self.render(source, ladder: ladder, decoder: decoder, tuning: tuning).texture)
                if let dump = env["ARGENT_DUMP"] {
                    // The flat patches, or on the still life the ColorChecker's edges, 512 by 256 from (3150, 3880) down the picture.
                    let shown = ladder.stillLife ? [Patch(x: 3150 + 32, y: ours.height - 3880 - 256 + 32), Patch(x: 3150 + 128 + 32, y: ours.height - 3880 - 256 + 32),
                                                    Patch(x: 3150 + 256 + 32, y: ours.height - 3880 - 256 + 32), Patch(x: 3150 + 384 + 32, y: ours.height - 3880 - 256 + 32)] : patches
                    try Self.dump(ours, shown, to: URL(fileURLWithPath: dump).appendingPathComponent("\(frame.iso)-\(spec).png"))
                    try Self.dump(production, shown, to: URL(fileURLWithPath: dump).appendingPathComponent("\(frame.iso)-apple.png"))
                }
                let n = Self.noise(ours, patches), nb = Self.noiseBands(ours, patches)
                var kept = ""
                if let clean, let appleRetained {
                    kept = "; retains " + zip(Self.retained(Self.bandImages(ours), clean.ours), appleRetained)
                        .map { String(format: "%.2f (%.2f of Apple's)", $0, $0 / $1) }.joined(separator: ", ")
                }
                print(String(format: "MEASURE   %@: L* %.3f (%.2f of Apple's), chroma %.3f (%.2f); noise bands L* %@, chroma %@; %@%@", spec, n.lightness,
                             n.lightness / target.lightness, n.chroma, n.chroma / target.chroma,
                             Self.bandRatio(nb.lightness, targetBands.lightness), Self.bandRatio(nb.chroma, targetBands.chroma),
                             Self.ratio(Self.detail(ours, stillLife: ladder.stillLife), targetDetail), kept))
            }
        }
    }
}
