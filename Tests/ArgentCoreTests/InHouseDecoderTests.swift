import CoreImage
import Foundation
import Metal
import Testing
@testable import ArgentCore

// MARK: The demosaic

/// Runs the GPU half on a hand-made mosaic. Throws without a Metal device or when the shaders
/// do not build.
struct DemosaicHarness {
    let gpu: GPU
    let decoder: InHouseDecoder

    init() throws {
        gpu = try GPU()
        decoder = try InHouseDecoder(gpu: gpu)
    }

    /// `samples` is `width` by `height`, RGGB from (0, 0); the crop is everything but a margin.
    /// Noise reduction is off unless `tuning` is given.
    func run(_ samples: [UInt16], width: Int, height: Int, margin: Int = 4, orientation: Int = 1,
             black: [Int] = [512, 512, 512, 512], matrix: [[Double]]? = nil, gainStops: Float = 0,
             tuning: InHouseNoiseReduction.Tuning? = nil, lens: SonyLensCorrection? = nil,
             options: DecodeOptions = Self.off) throws -> Pixels {
        Pixels(try frame(samples, width: width, height: height, margin: margin, orientation: orientation, black: black,
                         matrix: matrix, gainStops: gainStops, tuning: tuning, lens: lens, options: options).texture)
    }

    func frame(_ samples: [UInt16], width: Int, height: Int, margin: Int = 4, orientation: Int = 1,
               black: [Int] = [512, 512, 512, 512], matrix: [[Double]]? = nil, gainStops: Float = 0,
               tuning: InHouseNoiseReduction.Tuning? = nil, lens: SonyLensCorrection? = nil,
               options: DecodeOptions = Self.off) throws -> LinearFrame {
        let buffer = gpu.device.makeBuffer(length: samples.count * 2, options: .storageModeShared)!
        samples.withUnsafeBytes { _ = memcpy(buffer.contents(), $0.baseAddress!, samples.count * 2) }
        let layout = BayerMosaicLayout(pitch: width, cropOrigin: .init(x: margin, y: margin),
                                       cropSize: .init(width: width - 2 * margin, height: height - 2 * margin),
                                       validSize: .init(width: width, height: height), cfa: [0, 1, 1, 2],
                                       blackLevels: black, whiteLevel: 16383)
        let (frame, _) = try decoder.render(buffer, layout: layout, orientation: orientation, gainStops: gainStops, iso: nil,
                                           options: options, lens: lens, matrix: matrix, tuning: tuning)
        return frame
    }

    /// Decode options with noise reduction off.
    static var off: DecodeOptions {
        var options = DecodeOptions()
        options.luminanceNoiseReduction = 0
        options.colorNoiseReduction = 0
        return options
    }

    /// Plain camera RGB out: undoes the white balance and applies no matrix.
    static var cameraRGB: [[Double]] {
        let g = InHouseColor.daylightGains
        return [[1 / g[0], 0, 0], [0, 1, 0], [0, 0, 1 / g[2]]]
    }
}

/// Texture pixels, rows bottom up as Core Image lays them out, read top down.
struct Pixels {
    let width: Int
    let height: Int
    let values: [Float16]

    init(_ texture: MTLTexture) {
        let w = texture.width, h = texture.height
        var v = [Float16](repeating: 0, count: w * h * 4)
        v.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        width = w
        height = h
        values = v
    }

    /// The pixel at column `x` and row `y` counted from the top of the picture.
    func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let i = ((height - 1 - y) * width + x) * 4
        return SIMD3(Float(values[i]), Float(values[i + 1]), Float(values[i + 2]))
    }
}

/// The largest magnitude of the three.
func largest(_ v: SIMD3<Float>) -> Float { max(abs(v.x), abs(v.y), abs(v.z)) }

/// A mosaic whose camera RGB (black-subtracted, white-normalized) at each position is `colour(x, y)`.
func mosaic(width: Int, height: Int, black: Int = 512, _ colour: (Int, Int) -> SIMD3<Float>) -> [UInt16] {
    var out = [UInt16](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let c = colour(x, y)
            let v = (y & 1) == 0 ? ((x & 1) == 0 ? c.x : c.y) : ((x & 1) == 0 ? c.y : c.z)
            out[y * width + x] = UInt16(max(0, min(16383, (Float(black) + v * Float(16383 - black)).rounded())))
        }
    }
    return out
}

@Suite(.serialized) struct BayerDemosaicTests {
    @Test func theParametersMatchTheShader() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let demosaic = try BayerDemosaic(device: device)
        let pipeline = try device.makeComputePipelineState(function: demosaic.library.makeFunction(name: "demosaic_params_size")!)
        let buffer = device.makeBuffer(length: 16, options: .storageModeShared)!
        let queue = device.makeCommandQueue()!, commandBuffer = queue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(Int(buffer.contents().load(as: UInt32.self)) == MemoryLayout<BayerDemosaic.Parameters>.size)
        #expect(Int(buffer.contents().load(fromByteOffset: 4, as: UInt32.self)) == MemoryLayout<BayerDemosaic.NoiseLevel>.size)
        #expect(Int(buffer.contents().load(fromByteOffset: 8, as: UInt32.self)) == MemoryLayout<BayerDemosaic.WarpParameters>.size)
        #expect(Int(buffer.contents().load(fromByteOffset: 12, as: UInt32.self)) == MemoryLayout<BayerDemosaic.ColourGain>.size)
    }

    /// Black maps to 0 and each position subtracts its own black; white is 1 before the
    /// highlights are rebuilt; the gain multiplies.
    @Test func blackAndWhiteLevels() throws {
        let harness = try DemosaicHarness()
        let black = [500, 520, 540, 560]
        var samples = [UInt16](repeating: 0, count: 48 * 40)
        for y in 0..<40 { for x in 0..<48 { samples[y * 48 + x] = UInt16(black[(y & 1) * 2 + (x & 1)]) } }
        let dark = try harness.run(samples, width: 48, height: 40, black: black, matrix: DemosaicHarness.cameraRGB)
        for y in 0..<dark.height { for x in 0..<dark.width { #expect(dark.rgb(x, y) == .zero) } }

        // Half way from each position's black to white is 0.5 in camera RGB, then the gain.
        for y in 0..<40 { for x in 0..<48 { let b = black[(y & 1) * 2 + (x & 1)]; samples[y * 48 + x] = UInt16(b + (16383 - b) / 2) } }
        let mid = try harness.run(samples, width: 48, height: 40, black: black, matrix: DemosaicHarness.cameraRGB.map { $0.map { $0 * 2 } })
        for y in 0..<mid.height { for x in 0..<mid.width { #expect(largest(mid.rgb(x, y) - SIMD3(repeating: 1)) < 2e-3) } }
    }

    /// A flat field of any colour stays flat to half-float precision, to the frame's edges.
    @Test func aFlatFieldStaysFlat() throws {
        let harness = try DemosaicHarness()
        for colour in [SIMD3<Float>(0.2, 0.3, 0.1), SIMD3<Float>(0.02, 0.5, 0.31), SIMD3<Float>(0.001, 0.002, 0.004)] {
            let samples = mosaic(width: 52, height: 44) { _, _ in colour }
            let out = try harness.run(samples, width: 52, height: 44, matrix: DemosaicHarness.cameraRGB)
            // What the 14-bit samples hold.
            let stored = SIMD3(Float(samples[0]), Float(samples[1]), Float(samples[53])) - 512
            let expected = stored / Float(16383 - 512)
            for y in 0..<out.height {
                for x in 0..<out.width {
                    let d = largest((out.rgb(x, y) - expected) / expected)
                    #expect(d < 3e-3, "\(colour) at \(x), \(y): \(out.rgb(x, y))")
                }
            }
        }
    }

    /// A neutral step stays a step: flat on both sides, the change within two pixels, no
    /// overshoot, across and down.
    @Test func anEdgeStaysAnEdge() throws {
        let harness = try DemosaicHarness()
        let gains = InHouseColor.daylightGains.map(Float.init)
        func neutral(_ level: Float) -> SIMD3<Float> { SIMD3(level / gains[0], level, level / gains[2]) }
        for vertical in [true, false] {
            let samples = mosaic(width: 64, height: 64) { x, y in neutral((vertical ? x : y) < 32 ? 0.1 : 0.4) }
            let out = try harness.run(samples, width: 64, height: 64, margin: 0, matrix: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
            for t in 4..<60 {
                for along in [3, 30, 60] {
                    let p = vertical ? out.rgb(t, along) : out.rgb(along, t)
                    let expected: Float = t < 31 ? 0.1 : (t > 32 ? 0.4 : -1)
                    if expected > 0 {
                        #expect(largest(p - SIMD3(repeating: expected)) < 2e-3, "\(vertical ? "vertical" : "horizontal") at \(t): \(p)")
                    } else {
                        #expect(p.min() >= 0.1 - 2e-3 && p.max() <= 0.4 + 2e-3, "overshoot at \(t): \(p)")
                    }
                }
            }
        }
    }

    /// Each Exif orientation puts the crop's top-left pixel where that orientation says, and the
    /// rows run bottom up as Core Image's do.
    @Test(arguments: 1...8)
    func turnsTheFrameUpright(orientation: Int) throws {
        let harness = try DemosaicHarness()
        // A frame of 40 by 24 after an 8-pixel margin; the crop's top-left 4 by 4 is bright.
        let samples = mosaic(width: 56, height: 40) { x, y in (8..<12).contains(x) && (8..<12).contains(y) ? SIMD3(repeating: 0.5) : SIMD3(repeating: 0.05) }
        let out = try harness.run(samples, width: 56, height: 40, margin: 8, orientation: orientation, matrix: DemosaicHarness.cameraRGB)
        let swapped = orientation >= 5
        #expect(out.width == (swapped ? 24 : 40) && out.height == (swapped ? 40 : 24))
        // Where the crop's (1, 1), inside the bright square, lands, counted from the picture's top left.
        let w = 40, h = 24
        let corner: (Int, Int)
        switch orientation {
        case 2: corner = (w - 2, 1)
        case 3: corner = (w - 2, h - 2)
        case 4: corner = (1, h - 2)
        case 5: corner = (1, 1)
        case 6: corner = (h - 2, 1)
        case 7: corner = (h - 2, w - 2)
        case 8: corner = (1, w - 2)
        default: corner = (1, 1)
        }
        #expect(out.rgb(corner.0, corner.1).y > 0.4, "orientation \(orientation)")
        #expect(out.rgb(out.width / 2, out.height / 2).y < 0.06)
    }

    /// A highlight with green clipped goes neutral, raised toward its brightest channel; a fully
    /// clipped one becomes neutral at red's clip, the highest any channel can show; colours below
    /// 0.9 of their clip are untouched.
    @Test func rebuildsClippedHighlights() throws {
        let harness = try DemosaicHarness()
        let gains = InHouseColor.daylightGains.map(Float.init)
        let identity: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        // Green clipped, red and blue at 1.3 white-balanced.
        let clipped = try harness.run(mosaic(width: 40, height: 40) { _, _ in SIMD3(1.3 / gains[0], 1, 1.3 / gains[2]) },
                                      width: 40, height: 40, matrix: identity)
        #expect(largest(clipped.rgb(16, 16) - SIMD3(repeating: 1.3)) < 4e-3)
        let all = try harness.run(mosaic(width: 40, height: 40) { _, _ in SIMD3(repeating: 1) }, width: 40, height: 40, matrix: identity)
        #expect(largest(all.rgb(16, 16) - SIMD3(repeating: gains[0])) < 5e-3)
        let colour = SIMD3<Float>(0.8 / gains[0], 0.85, 0.2 / gains[2])
        let below = try harness.run(mosaic(width: 40, height: 40) { _, _ in colour }, width: 40, height: 40, matrix: identity)
        #expect(largest(below.rgb(16, 16) - SIMD3(0.8, 0.85, 0.2)) < 2e-3)
    }

    /// The colour matrix and the exposure gain: a white-balanced neutral comes out neutral at the
    /// matrix's row sum times the gain.
    @Test func neutralStaysNeutralThroughTheMatrix() throws {
        let harness = try DemosaicHarness()
        let gains = InHouseColor.daylightGains.map(Float.init)
        let level: Float = 0.2
        let out = try harness.run(mosaic(width: 40, height: 40) { _, _ in SIMD3(level / gains[0], level, level / gains[2]) },
                                  width: 40, height: 40, gainStops: 1.5)
        let rowSum = Float(InHouseColor.cameraToWorking[0].reduce(0, +))
        let expected = level * rowSum * exp2(1.5)
        #expect(largest(out.rgb(10, 10) - SIMD3(repeating: expected)) < 2e-3 * expected)
        for row in InHouseColor.cameraToWorking { #expect(abs(row.reduce(0, +) - Double(rowSum)) < 1e-5) }
    }
}

// MARK: Reading the file

@Suite struct InHouseDecoderFileTests {
    /// A raw on the Mac's own disk is mapped; one anywhere else, a network share's (NetworkShareTests)
    /// or a card's, is read whole, so its volume going away is a read error and not a crash.
    @Test func mapsOnlyOnTheFixedDisk() throws {
        let url = try temporaryRaw(Data("not a raw".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InHouseDecoder.mapsFile(at: url))
        #expect(try InHouseDecoder.contents(of: url) == Data("not a raw".utf8))
        let missing = url.deletingLastPathComponent().appendingPathComponent("missing-\(UUID().uuidString).arw")
        #expect(!InHouseDecoder.mapsFile(at: missing))
    }
}

// MARK: The decoder on real files

/// Runs where the CC0 samples from `scripts/fetch-samples.sh` are present, including in `scripts/regression.sh`.
@Suite(.serialized) struct InHouseDecoderSampleTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    private static let lossless = samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    private static let uncompressed = samples.appendingPathComponent("ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
    private static var hasSamples: Bool { FileManager.default.fileExists(atPath: lossless.path) }

    /// The decoder takes the full-frame lossless L and uncompressed samples and nothing else.
    @Test(.enabled(if: InHouseDecoderSampleTests.hasSamples))
    func refusesEveryOtherFile() throws {
        #expect(InHouseDecoder.supports(Self.lossless) && InHouseDecoder.supports(Self.uncompressed))
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let others = ["ILCE-7M4_DSC06675_FullFrame-LossLess-Compressed-Medium.ARW", "ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW",
                      "ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW"]
        for name in others {
            let url = Self.samples.appendingPathComponent(name)
            #expect(!InHouseDecoder.supports(url), "\(name)")
            do {
                _ = try decoder.decode(url, options: DecodeOptions())
                Issue.record("decoded \(name)")
            } catch InHouseDecodeError.unsupported {
            } catch {
                Issue.record("\(name): \(error)")
            }
        }
        let text = try temporaryRaw(Data("not a raw".utf8))
        defer { try? FileManager.default.removeItem(at: text) }
        #expect(!InHouseDecoder.supports(text))
    }

    /// An a7 IV uncompressed raw of the full-frame or the APS-C crop is taken and decodes to the crop's
    /// size; another camera's, or another crop, is refused.
    @Test func takesFullFrameAndAPSCUncompressed() throws {
        let fullFrame = try temporaryRaw(syntheticUncompressedFile(width: 7040, height: 4688, origin: (12, 8), crop: (7008, 4672), fill: 2000))
        let apsC = try temporaryRaw(syntheticUncompressedFile(width: 4736, height: 3132, origin: (44, 30), crop: (4608, 3072), fill: 2000))
        let other = try temporaryRaw(syntheticUncompressedFile(width: 4736, height: 3132, origin: (44, 30), crop: (4608, 3072),
                                                              model: "ILCE-7RM5", fill: 2000))
        let odd = try temporaryRaw(syntheticUncompressedFile(width: 4736, height: 3132, origin: (44, 30), crop: (4600, 3072), fill: 2000))
        defer { for url in [fullFrame, apsC, other, odd] { try? FileManager.default.removeItem(at: url) } }
        #expect(InHouseDecoder.supports(fullFrame) && InHouseDecoder.supports(apsC))
        #expect(!InHouseDecoder.supports(other) && !InHouseDecoder.supports(odd))
        // No ISO in these files, so the in-house route leaves them to Apple's decoder all the same;
        // RAW 9's route takes a Bayer mode of the a7 IV whatever its ISO.
        #expect(DecoderChoice.of(apsC, route: .inHouse) == .apple)
        #expect(DecoderChoice.of(apsC) == .raw9 && DecoderChoice.of(other) == .apple)
        let gpu = try GPU()
        var options = DecodeOptions()
        options.maxLongSide = 1152
        let frame = try InHouseDecoder(gpu: gpu).decode(apsC, options: options)
        #expect(frame.width == 1152 && frame.height == 768 && frame.pins?.rawMode == "uncompressed")
    }

    /// A lossless L raw from another camera, or of another crop, is refused before any decode.
    @Test func refusesOtherCamerasAndCrops() throws {
        let tiles = (0..<6).map { syntheticTile($0 % 3, $0 / 3) }
        let other = try temporaryRaw(syntheticLosslessFile(across: 3, down: 2, tiles: tiles, model: "ILCE-7RM5"))
        let crop = try temporaryRaw(syntheticLosslessFile(across: 3, down: 2, tiles: tiles))
        defer {
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: crop)
        }
        #expect(!InHouseDecoder.supports(other))
        #expect(!InHouseDecoder.supports(crop))
    }

    /// The sample decoded lands where Apple's decode of it lands: the same size and window (the
    /// detail lines up at no offset), the same brightness within 0.03 stops and the same colour
    /// within 0.02 in chromaticity, against Apple's decode with the production pins but noise
    /// reduction off. Both correct this frame's distortion from the file's curve, which moves the
    /// centre's detail by under a pixel (docs/decoder.md, section 13).
    @Test(.enabled(if: InHouseDecoderSampleTests.hasSamples))
    func landsWhereAppleDoes() throws {
        try Self.landsWhereAppleDoes(Self.lossless, mode: "lossless L", label: "sample")
    }

    /// The uncompressed sample, the same scene a moment earlier, lands where Apple's decode of it
    /// lands by the same measures (docs/decoder.md, section 17).
    @Test(.enabled(if: InHouseDecoderSampleTests.hasSamples))
    func uncompressedLandsWhereAppleDoes() throws {
        try Self.landsWhereAppleDoes(Self.uncompressed, mode: "uncompressed", label: "uncompressed sample")
    }

    static func landsWhereAppleDoes(_ url: URL, mode: String, label: String) throws {
        let gpu = try GPU()
        let ours = try InHouseDecoder(gpu: gpu).decode(url, options: DecodeOptions())
        var options = DecodeOptions()
        options.luminanceNoiseReduction = 0
        options.colorNoiseReduction = 0
        let apple = try AppleRawDecoder(gpu: gpu).decode(url, options: options)
        #expect(ours.width == 7008 && ours.height == 4672)
        #expect(ours.width == apple.width && ours.height == apple.height)
        let pins = try #require(ours.pins)
        #expect(ours.decoderVersion == InHouseDecoder.version && pins.decoderVersion == InHouseDecoder.version)
        #expect(pins.neutralChromaticity == AppleRawDecoder.daylightNeutral && pins.baselineExposure == 0)
        #expect(pins.exposureGainStops == ExposureAnchor.gainStops(iso: 250) && pins.rawMode == mode)
        #expect(pins.lensCorrection && pins.scale == 1)
        #expect(pins.luminanceNoiseReduction == NoiseReduction.luminanceAmount(iso: 250) && pins.colorNoiseReduction == 0.5)

        let a = Pixels(ours.texture), b = Pixels(apple.texture)
        // Brightness and colour: the geometric mean of luminance and the mean chromaticity over
        // the frame, every 7th pixel.
        func stats(_ p: Pixels) -> (log: Double, r: Double, g: Double) {
            var logSum = 0.0, r = 0.0, g = 0.0, n = 0.0
            for y in stride(from: 0, to: p.height, by: 7) {
                for x in stride(from: 0, to: p.width, by: 7) {
                    let c = p.rgb(x, y)
                    let l = Double(0.2627 * c.x + 0.678 * c.y + 0.0593 * c.z)
                    let s = Double(c.x + c.y + c.z)
                    guard l > 0.005, s > 0 else { continue }
                    logSum += log2(l); r += Double(c.x) / s; g += Double(c.y) / s; n += 1
                }
            }
            return (logSum / n, r / n, g / n)
        }
        let sa = stats(a), sb = stats(b)
        print(String(format: "MEASURE %@ against Apple: %+.4f stops, chromaticity r %+.4f g %+.4f", label, sa.log - sb.log, sa.r - sb.r, sa.g - sb.g))
        #expect(abs(sa.log - sb.log) < 0.03)
        #expect(abs(sa.r - sb.r) < 0.02 && abs(sa.g - sb.g) < 0.02)

        // Window: the luminance detail of a central patch correlates best at no offset.
        func luma(_ p: Pixels, _ x: Int, _ y: Int) -> Float { let c = p.rgb(x, y); return 0.2627 * c.x + 0.678 * c.y + 0.0593 * c.z }
        var best = (score: -Float.infinity, dx: 99, dy: 99)
        for dy in -2...2 {
            for dx in -2...2 {
                var sab: Float = 0, saa: Float = 0, sbb: Float = 0
                for y in 2100..<2356 {
                    for x in 3400..<3656 {
                        let p = luma(a, x + dx, y + dy) - 0.25 * (luma(a, x + dx - 1, y + dy) + luma(a, x + dx + 1, y + dy) + luma(a, x + dx, y + dy - 1) + luma(a, x + dx, y + dy + 1))
                        let q = luma(b, x, y) - 0.25 * (luma(b, x - 1, y) + luma(b, x + 1, y) + luma(b, x, y - 1) + luma(b, x, y + 1))
                        sab += p * q; saa += p * p; sbb += q * q
                    }
                }
                let score = sab / (saa * sbb).squareRoot()
                if score > best.score { best = (score, dx, dy) }
            }
        }
        print(String(format: "MEASURE %@ window against Apple: best at (%d, %d), correlation %.3f", label, best.dx, best.dy, best.score))
        #expect(best.dx == 0 && best.dy == 0)
    }

    /// Uncompressed and lossless L hold the same samples, so the same mosaic in either decodes to
    /// the same frame: the lossless L sample's decoded tiles written into a copy of the uncompressed
    /// sample, whose tags (levels, crop, lens curves, ISO, orientation) are the lossless sample's, give
    /// the lossless decode exactly, at full size and scaled, noise reduction and lens correction on.
    @Test(.enabled(if: InHouseDecoderSampleTests.hasSamples))
    func uncompressedAndLosslessLDecodeTheSameMosaicAlike() throws {
        let lossless = try SonyLosslessRaw.read(from: Self.lossless), raw = try SonyUncompressedRaw.read(from: Self.uncompressed)
        #expect(lossless.lens == raw.lens && lossless.blackLevels == raw.blackLevels && lossless.whiteLevel == raw.whiteLevel)
        #expect(lossless.cropOrigin == raw.cropOrigin && lossless.cropSize == raw.cropSize && lossless.validSize == raw.validSize)
        var mosaic = [UInt16](repeating: 0, count: lossless.width * lossless.height)
        let file = try Data(contentsOf: Self.lossless, options: .alwaysMapped)
        try file.withUnsafeBytes { bytes in try mosaic.withUnsafeMutableBufferPointer { try lossless.decodeTiles(bytes, into: $0.baseAddress!) } }
        var copy = try Data(contentsOf: Self.uncompressed)
        let offset = try #require(raw.stripOffsets.first)
        copy.withUnsafeMutableBytes { bytes in
            let strip = (bytes.baseAddress! + offset).assumingMemoryBound(to: UInt16.self)
            for y in 0..<raw.height {
                for x in 0..<raw.width { strip[y * raw.width + x] = mosaic[y * lossless.width + x].littleEndian }
            }
        }
        let url = try temporaryRaw(copy)
        defer { try? FileManager.default.removeItem(at: url) }
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        for side in [nil, 960] as [Int?] {
            var options = DecodeOptions()
            options.maxLongSide = side
            let a = Pixels(try decoder.decode(Self.lossless, options: options).texture)
            let frame = try decoder.decode(url, options: options)
            #expect(frame.pins?.rawMode == "uncompressed")
            let b = Pixels(frame.texture)
            #expect(a.width == b.width && a.height == b.height)
            #expect(a.values == b.values, "at \(side.map(String.init) ?? "full size")")
        }
    }

    /// A scaled decode is the full one area-resized, and says so in its pins.
    @Test(.enabled(if: InHouseDecoderSampleTests.hasSamples))
    func scalesByAreaResize() throws {
        let gpu = try GPU()
        var options = DecodeOptions()
        options.maxLongSide = 1752
        let frame = try InHouseDecoder(gpu: gpu).decode(Self.lossless, options: options)
        #expect(frame.width == 1752 && frame.height == 1168)
        #expect(frame.scale == 0.25 && frame.pins?.scale == 0.25 && frame.pins?.draftMode == false)
    }
}
