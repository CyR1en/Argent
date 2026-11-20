import CoreImage
import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Why a dark frame's level rises with noise (docs/provenance.md section 8), on permitted data: the
/// CC0 scene darkened in the raw and given the a7 IV's noise at ISO 250 to 102400
/// (`SyntheticRaw.simulated`), decoded as the sheet decodes it. Gated like the other measurement
/// suites:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --skip-build --filter DarkLevelMeasureTests
@Suite(.serialized, .syntheticRaws) struct DarkLevelMeasureTests {
    static let luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)

    /// The frame's analysis grid with each sample the mean light of a `side` by `side` block centred
    /// on it (1 is the point itself), as RGBA half floats; the grid is `ExposureAnalyzer`'s, so the
    /// analyzer reads it one sample per pixel.
    static func blockGrid(_ pixels: [Float16], width: Int, height: Int, side: Int) -> (pixels: [Float16], width: Int, height: Int) {
        let step = max(1, max(width, height) / ExposureAnalyzer.samplesOnLongSide)
        var out: [Float16] = []
        var gw = 0, gh = 0
        for y in stride(from: step / 2, to: height, by: step) {
            gh += 1
            gw = 0
            for x in stride(from: step / 2, to: width, by: step) {
                gw += 1
                let x0 = max(0, x - side / 2), x1 = min(width, x0 + side)
                let y0 = max(0, y - side / 2), y1 = min(height, y0 + side)
                var sum = SIMD3<Float>(repeating: 0)
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        let i = (yy * width + xx) * 4
                        sum += SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                    }
                }
                let mean = sum / Float((x1 - x0) * (y1 - y0))
                out += [Float16(mean.x), Float16(mean.y), Float16(mean.z), 1]
            }
        }
        return (out, gw, gh)
    }

    /// The analysis grid of a full-size decode, each sample the mean of every pixel in its cell: the
    /// least noisy reading of the same light.
    static func cellGrid(_ pixels: [Float16], width: Int, height: Int, gridWidth: Int, gridHeight: Int) -> [Float16] {
        var out = [Float16](repeating: 0, count: gridWidth * gridHeight * 4)
        for gy in 0..<gridHeight {
            let y0 = gy * height / gridHeight, y1 = (gy + 1) * height / gridHeight
            for gx in 0..<gridWidth {
                let x0 = gx * width / gridWidth, x1 = (gx + 1) * width / gridWidth
                var sum = SIMD3<Double>(repeating: 0)
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = (y * width + x) * 4
                        sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                    }
                }
                let mean = sum / Double((x1 - x0) * (y1 - y0))
                let o = (gy * gridWidth + gx) * 4
                out[o] = Float16(Float(mean.x)); out[o + 1] = Float16(Float(mean.y)); out[o + 2] = Float16(Float(mean.z)); out[o + 3] = 1
            }
        }
        return out
    }

    /// The centre-weighted mean of luminance over every pixel, in stops against mid-gray, and the
    /// share of pixels at or under zero and under the level's floor.
    static func linear(_ pixels: [Float16], width: Int, height: Int) -> (stops: Float, nonPositive: Float, underFloor: Float) {
        var sum: Double = 0, weight: Double = 0, nonPositive = 0, under = 0
        let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
        let cx = Float(width - 1) / 2, cy = Float(height - 1) / 2
        for y in 0..<height {
            for x in 0..<width {
                let dx = (Float(x) - cx) / max(cx, 1), dy = (Float(y) - cy) / max(cy, 1)
                let radius = (dx * dx + dy * dy).squareRoot()
                let w: Float = radius < 1.0 / 3 ? 1 : radius < 2.0 / 3 ? 0.5 : 0.25
                let i = (y * width + x) * 4
                let l = (SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) * luma).sum()
                sum += Double(l * w); weight += Double(w)
                if l <= 0 { nonPositive += 1 }
                if l < floor { under += 1 }
            }
        }
        let n = Float(width * height)
        return (Float(log2(sum / weight)) - log2(0.18), Float(nonPositive) / n, Float(under) / n)
    }

    static func describe(_ a: ExposureAnalysis) -> String {
        let cast = AutoBalance.cast(a)
        return String(format: "%+.2f (rb %+.0f mired, gm %+.3f)", a.meanStops, AutoBalance.mired(cast), AutoBalance.axes(cast).greenMagenta)
    }

    /// The level and the cast on the darkened ladder, by how the samples read the decode: the point
    /// the analyzer reads now, blocks of 2 to 16 pixels around it, the same with Apple's luminance
    /// noise reduction off, and cells of a full-size decode. ARGENT_STOPS sets the darkening,
    /// ARGENT_FULL=1 adds the full-size decode.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func causes() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let apple = AppleRawDecoder(gpu: gpu)
        let env = ProcessInfo.processInfo.environment
        let stops = Double(env["ARGENT_STOPS"] ?? "") ?? -3.5
        let full = env["ARGENT_FULL"] == "1"
        for iso in ProvenanceMeasureTests.isos([250, 1600, 6400, 25600, 51200, 102400]) {
            let url = try SyntheticRaw.simulated(iso: iso, stops: stops)
            var line = String(format: "MEASURE dark causes (%.1f stops) ISO %6d:", stops, iso)
            for nr in [nil, Float(0)] as [Float?] {
                var options = DecodeOptions()
                options.maxLongSide = FilmPreviews.previewLongSide
                options.luminanceNoiseReduction = nr
                let frame = try apple.decode(url, options: options)
                let pixels = ExposureAnalyzer.pixels(of: frame.texture)
                let lin = Self.linear(pixels, width: frame.width, height: frame.height)
                line += nr == nil ? " [shipped NR]" : " [NR 0]"
                line += String(format: " linear mean %+.2f, <=0 %.1f%%, under floor %.1f%%;", lin.stops, lin.nonPositive * 100, lin.underFloor * 100)
                for side in [1, 2, 4, 8, 16] {
                    let grid = Self.blockGrid(pixels, width: frame.width, height: frame.height, side: side)
                    let a = ExposureAnalyzer.analyze(pixels: grid.pixels, width: grid.width, height: grid.height)
                    line += " block \(side): " + Self.describe(a) + ";"
                }
            }
            if full {
                var options = DecodeOptions()
                options.scale = 1
                let frame = try apple.decode(url, options: options)
                let pixels = ExposureAnalyzer.pixels(of: frame.texture)
                let step = max(frame.width, frame.height) / ExposureAnalyzer.samplesOnLongSide
                let gw = frame.width / step, gh = frame.height / step
                let grid = Self.cellGrid(pixels, width: frame.width, height: frame.height, gridWidth: gw, gridHeight: gh)
                let a = ExposureAnalyzer.analyze(pixels: grid, width: gw, height: gh)
                line += " [full size \(frame.width)] cells: " + Self.describe(a) + ";"
            }
            print(line)
        }
    }

    /// The green samples of a raw written by `SyntheticRaw`, inside the crop: their mean above
    /// black, the mean with every sample under black raised to it, and the share under black.
    static func rawGreen(_ url: URL) throws -> (mean: Double, rectifiedMean: Double, underBlack: Double) {
        let data = try Data(contentsOf: url)
        let l = try SyntheticRaw.layout(data)
        var sum = 0.0, rectified = 0.0, under = 0.0, n = 0.0
        data.withUnsafeBytes { bytes in
            let samples = (bytes.baseAddress! + l.strip).assumingMemoryBound(to: UInt16.self)
            for y in stride(from: l.cropY, to: l.cropY + l.cropHeight, by: 1) {
                for x in stride(from: l.cropX, to: l.cropX + l.cropWidth, by: 1) where l.cfa[(y & 1) * 2 + (x & 1)] == 1 {
                    let v = Double(samples[y * l.width + x]) - Double(l.black)
                    sum += v; rectified += max(v, 0); n += 1
                    if v < 0 { under += 1 }
                }
            }
        }
        return (sum / n, rectified / n, under / n)
    }

    /// Whether Apple's decoder clips its input at black: the darkened ladder decoded as written and
    /// with every sample under black raised to black first. If the two decode alike, the decoder
    /// clips, and noise at black becomes light. Also the same frames at their metered exposure.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func rectification() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let apple = AppleRawDecoder(gpu: gpu)
        for stops in [-3.5, 0] {
            for iso in ProvenanceMeasureTests.isos([250, 6400, 25600, 51200, 102400]) {
                var line = String(format: "MEASURE dark rectification (%.1f stops) ISO %6d:", stops, iso)
                for rectified in [false, true] {
                    let url = try SyntheticRaw.simulated(iso: iso, stops: stops, rectified: rectified)
                    let raw = try Self.rawGreen(url)
                    var options = DecodeOptions()
                    options.maxLongSide = FilmPreviews.previewLongSide
                    let frame = try apple.decode(url, options: options)
                    let pixels = ExposureAnalyzer.pixels(of: frame.texture)
                    let lin = Self.linear(pixels, width: frame.width, height: frame.height)
                    let a = ExposureAnalyzer.analyze(pixels: pixels, width: frame.width, height: frame.height)
                    line += rectified ? " [clipped at black in the raw]" : " [as written]"
                    line += String(format: " raw green mean %.1f DN (clipped at black %.1f, %.1f%% under); decoded linear mean %+.3f, level %+.2f;",
                                   raw.mean, raw.rectifiedMean, raw.underBlack * 100, lin.stops, a.meanStops)
                }
                print(line)
            }
        }
    }

    /// Which stage of Apple's decode turns noise into light: the darkened frame at ISO 250 and
    /// 102400 decoded with one setting changed at a time from the pins, its linear mean, the share
    /// of pixels with a channel at or under zero and the lowest channel value.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func decoderStages() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let variants: [(String, (CIRAWFilter) -> Void)] = [
            ("pins", { _ in }),
            ("colour NR 0", { $0.colorNoiseReductionAmount = 0 }),
            ("luminance and colour NR 0", { $0.colorNoiseReductionAmount = 0; $0.luminanceNoiseReductionAmount = 0 }),
            ("moire 0", { if $0.isMoireReductionSupported { $0.moireReductionAmount = 0 } }),
            ("lens correction off", { $0.isLensCorrectionEnabled = false }),
            ("highlight recovery off", { $0.isHighlightRecoveryEnabled = false }),
            ("draft mode off", { $0.isDraftModeEnabled = false }),
            ("decoder 7", { $0.decoderVersion = .version7 }),
            ("decoder 9", { $0.decoderVersion = .version9 }),
            ("shadow bias 3", { $0.shadowBias = 3 }),
            ("full size", { $0.scaleFactor = 1; $0.isDraftModeEnabled = false }),
        ]
        for iso in [250, 25600, 102400] {
            let url = try SyntheticRaw.simulated(iso: iso, stops: -3.5)
            for (name, change) in variants {
                let filter = try #require(CIRAWFilter(imageURL: url))
                var options = DecodeOptions()
                options.maxLongSide = FilmPreviews.previewLongSide
                AppleRawDecoder.configure(filter, options: options, iso: AppleRawDecoder.isoSpeed(of: filter))
                change(filter)
                let image = try #require(filter.outputImage)
                let extent = image.extent.integral
                let texture = try gpu.texturePool.acquire(width: Int(extent.width), height: Int(extent.height))
                let buffer = try #require(gpu.queue.makeCommandBuffer())
                gpu.ciContext.render(image, to: texture.texture, commandBuffer: buffer, bounds: extent, colorSpace: gpu.workingColorSpace)
                buffer.commit()
                buffer.waitUntilCompleted()
                let pixels = ExposureAnalyzer.pixels(of: texture.texture)
                let w = Int(extent.width), h = Int(extent.height)
                let lin = Self.linear(pixels, width: w, height: h)
                var anyNonPositive = 0, lowest = Float.infinity
                var channels = SIMD3<Double>(repeating: 0)
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    let rgb = SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                    if rgb.min() <= 0 { anyNonPositive += 1 }
                    lowest = min(lowest, rgb.min())
                    channels += SIMD3<Double>(rgb)
                }
                channels /= Double(w * h)
                print(String(format: "MEASURE dark stage ISO %6d %@ (%dx%d): linear mean %+.3f; mean R G B %.5f %.5f %.5f; a channel <= 0 in %.2f%% of pixels, lowest %.5f",
                             iso, name.padding(toLength: 26, withPad: " ", startingAt: 0), w, h, lin.stops, channels.x, channels.y, channels.z,
                             100 * Double(anyNonPositive) / Double(w * h), lowest))
            }
        }
    }

    /// Writes the darkened ladder's 4 by 4 block means at the analysis grid, RGB float32, to
    /// ARGENT_DUMP/cells-<stops>-<iso>.f32, for fitting the decoder's lift offline.
    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_DUMP"] != nil))
    func cellDump() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let apple = AppleRawDecoder(gpu: gpu)
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARGENT_DUMP"]!)
        let stopsList = (ProcessInfo.processInfo.environment["ARGENT_STOPS"] ?? "-3.5").split(separator: ",").compactMap { Double($0) }
        for stops in stopsList {
            for iso in ProvenanceMeasureTests.isos([250, 6400, 12800, 25600, 51200, 102400]) {
                let url = try SyntheticRaw.simulated(iso: iso, stops: stops)
                var options = DecodeOptions()
                options.maxLongSide = FilmPreviews.previewLongSide
                let frame = try apple.decode(url, options: options)
                let grid = Self.blockGrid(ExposureAnalyzer.pixels(of: frame.texture), width: frame.width, height: frame.height, side: 4)
                var values: [Float] = []
                for i in stride(from: 0, to: grid.pixels.count, by: 4) {
                    values += [Float(grid.pixels[i]), Float(grid.pixels[i + 1]), Float(grid.pixels[i + 2])]
                }
                try values.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(String(format: "cells-%.1f-%d.f32", stops, iso))) }
                print("MEASURE dump \(stops) \(iso) \(grid.width)x\(grid.height)")
            }
        }
    }

    /// Decoded units per raw digital number, per channel, for a neutral: flat neutral patches written
    /// into the CC0 sample with no noise, decoded as the sheet decodes. With two greens a quad and the
    /// clip after white balance, this predicts the decoder's lift (`DecodedNoise`).
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func decodedGain() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let apple = AppleRawDecoder(gpu: gpu)
        let (url, patches, l) = try SyntheticRaw.patches("flat", iso: 250, noise: false)
        for scale in [FilmPreviews.previewLongSide, 0] {
            var options = DecodeOptions()
            if scale > 0 { options.maxLongSide = scale } else { options.scale = 1 }
            options.lensCorrection = false
            let frame = try apple.decode(url, options: options)
            let pixels = ExposureAnalyzer.pixels(of: frame.texture)
            let sx = Double(frame.width) / Double(l.cropWidth), sy = Double(frame.height) / Double(l.cropHeight)
            let range = Double(l.white - l.black)
            var gains: [SIMD3<Double>] = []
            for (index, p) in patches.enumerated() where (index / (l.cropWidth / 384)) % 4 == 0 {
                // The middle half of the patch, rows from the bottom of the texture.
                let x0 = Int((Double(p.x - l.cropX) + Double(p.side) * 0.25) * sx), x1 = Int((Double(p.x - l.cropX) + Double(p.side) * 0.75) * sx)
                let y0 = Int((Double(p.y - l.cropY) + Double(p.side) * 0.25) * sy), y1 = Int((Double(p.y - l.cropY) + Double(p.side) * 0.75) * sy)
                var sum = SIMD3<Double>(repeating: 0), n = 0.0
                for y in y0..<y1 {
                    let row = frame.height - 1 - y
                    for x in x0..<x1 {
                        let i = (row * frame.width + x) * 4
                        sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])); n += 1
                    }
                }
                let decoded = sum / n
                let dn = p.rgb * range
                let gain = decoded / dn
                gains.append(gain)
                print(String(format: "MEASURE decoded gain %@ patch %d: raw DN %.1f %.1f %.1f -> decoded %.5f %.5f %.5f; units per DN %.4e %.4e %.4e",
                             scale > 0 ? "960" : "full", index, dn.x, dn.y, dn.z, decoded.x, decoded.y, decoded.z, gain.x, gain.y, gain.z))
            }
            let mid = gains.sorted { $0.y < $1.y }[gains.count / 2]
            print(String(format: "MEASURE decoded gain %@ median: %.4e %.4e %.4e (log2 %.2f %.2f %.2f)", scale > 0 ? "960" : "full",
                         mid.x, mid.y, mid.z, log2(mid.x), log2(mid.y), log2(mid.z)))
        }
    }

    /// The a7 IV corpus as the analysis read it before 2026-10-07 (one pixel a sample, no noise
    /// taken out) and as shipped: each frame's level, print level and cast, then each folder as a
    /// roll, its clusters, smoothed levels and the drop-one check. Faces as the app finds them.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func corpusBeforeAndAfter() async throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        for name in ["samples", "references/corpus/photographyblog-a7iv", "references/corpus/imaging-resource-a7iv-wayback",
                     "references/corpus/rawnind-a7c"] {
            let roll = await RollScanner.scan(FrameViewMeasureTests.root.appendingPathComponent(name))
            var before: [URL: ExposureAnalysis] = [:], after: [URL: ExposureAnalysis] = [:]
            for frame in roll.frames {
                var options = DecodeOptions()
                options.maxLongSide = FilmPreviews.previewLongSide
                let decoded = try decoder.decode(frame.url, options: options)
                let pixels = ExposureAnalyzer.pixels(of: decoded.texture)
                var old = ExposureAnalyzer.analyze(pixels: pixels, width: decoded.width, height: decoded.height, sampling: .points)
                old.asShotTemperature = decoded.readback?.asShotTemperature
                let new = ExposureAnalyzer.analyze(decoded, workingSpace: gpu.workingColorSpace, info: frame.info)
                old.faces = FaceMeter.meter(FaceMeter.detect(decoded.texture, workingSpace: gpu.workingColorSpace),
                                            grid: ExposureAnalyzer.grid(pixels: pixels, width: decoded.width, height: decoded.height, sampling: .points))
                before[frame.url] = old
                after[frame.url] = new
                let noise = DecodedNoise.appleDecode(model: frame.info.model, iso: frame.info.iso, pins: decoded.pins)
                let c0 = AutoBalance.cast(old), c1 = AutoBalance.cast(new)
                // Evaluation only: files whose Exif model was blanked ("MODEL-NAME") but are a7 IV
                // Bayer frames, measured as if their body were known.
                if noise == nil, ProcessInfo.processInfo.environment["ARGENT_FORCE_A7IV"] == "1", var pins = decoded.pins,
                   let layout = try? ARWLayout.read(from: frame.url), layout.encoding != .losslessYCbCr {
                    pins.rawMode = layout.encoding == .uncompressed ? "uncompressed" : layout.encoding == .compressed ? "compressed" : "lossless L"
                    let forcedNoise = DecodedNoise.appleDecode(model: "ILCE-7M4", iso: frame.info.iso, pins: pins)
                    let forced = ExposureAnalyzer.analyze(pixels: pixels, width: decoded.width, height: decoded.height, noise: forcedNoise)
                    let c2 = AutoBalance.cast(forced)
                    print(String(format: "MEASURE corpus %@ ISO %6d as an a7 IV [evaluation only]: level %+.2f, print %+.2f, cast %+.0f mired, green %+.3f",
                                 frame.name.padding(toLength: 30, withPad: " ", startingAt: 0), frame.info.iso ?? 0, forced.meanStops,
                                 AutoPrint.levelStops(forced), AutoBalance.mired(c2), AutoBalance.axes(c2).greenMagenta))
                }
                print(String(format: "MEASURE corpus %@ ISO %6d%@: level %+.2f -> %+.2f, print %+.2f -> %+.2f; cast %+.0f -> %+.0f mired, green %+.3f -> %+.3f; faces %d",
                             frame.name.padding(toLength: 30, withPad: " ", startingAt: 0), frame.info.iso ?? 0, noise == nil ? "" : " (noise)",
                             old.meanStops, new.meanStops, AutoPrint.levelStops(old), AutoPrint.levelStops(new),
                             AutoBalance.mired(c0), AutoBalance.mired(c1), AutoBalance.axes(c0).greenMagenta, AutoBalance.axes(c1).greenMagenta,
                             new.faces.count))
            }
            for (label, analyses) in [("before", before), ("after", after)] {
                let clusters = RollSmoothing.clusters(roll.frames, analyses: analyses)
                let levels = RollSmoothing.levels(roll.frames, analyses: analyses)
                var moved: [Float] = [], worstDrop: Float = 0
                for frame in roll.frames {
                    let own = AutoPrint.levelStops(analyses[frame.url])
                    moved.append(abs((levels[frame.url] ?? own) - own))
                }
                for dropped in roll.frames {
                    let rest = roll.frames.filter { $0.url != dropped.url }
                    let others = RollSmoothing.levels(rest, analyses: analyses)
                    for frame in rest { worstDrop = max(worstDrop, abs((others[frame.url] ?? 0) - (levels[frame.url] ?? 0))) }
                }
                let distances = zip(roll.frames, roll.frames.dropFirst()).map { a, b in analyses[a.url]!.histogramDistance(to: analyses[b.url]!) ?? -1 }
                print(String(format: "MEASURE corpus %@ %@: clusters %@; smoothing moves frames by up to %.3f; dropping one moves another by up to %.3f; neighbours' histograms %@",
                             String(name.split(separator: "/").last!), label, "\(clusters.map(\.count))", moved.max() ?? 0, worstDrop,
                             distances.map { String(format: "%.2f", $0) }.joined(separator: " ")))
            }
        }
    }

    /// The app measures a frame from whichever decode comes first: Apple's own 960-pixel decode, or
    /// the frame view's larger decode area-resized to 960 (`FilmPreviews`). The two should measure
    /// alike. Each CC0 frame both ways, one pixel a sample and cells.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func pathsAgree() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let resize = try AreaResize(gpu: gpu)
        for url in AutoMeasureTests.folder("samples") {
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            let sheet = try decoder.decode(url, options: options)
            for side in [2048, 3072] {
                var large = DecodeOptions()
                large.maxLongSide = side
                large.fillsMaxLongSide = true
                let big = try decoder.decode(url, options: large)
                let scale = Double(FilmPreviews.previewLongSide) / Double(max(big.width, big.height))
                let scaled = try resize.resized(big.texture, scale: scale)
                let a = ExposureAnalyzer.pixels(of: sheet.texture), b = ExposureAnalyzer.pixels(of: scaled.texture)
                var line = "MEASURE paths \(url.deletingPathExtension().lastPathComponent.suffix(34)) sheet against \(side) resized (\(scaled.texture.width)x\(scaled.texture.height)):"
                for sampling in [ExposureAnalyzer.Sampling.points, .cells] {
                    let x = ExposureAnalyzer.analyze(pixels: a, width: sheet.width, height: sheet.height, sampling: sampling)
                    let y = ExposureAnalyzer.analyze(pixels: b, width: scaled.texture.width, height: scaled.texture.height, sampling: sampling)
                    let cx = AutoBalance.cast(x), cy = AutoBalance.cast(y)
                    line += String(format: " %@ level %+.3f vs %+.3f, cast %+.1f vs %+.1f mired, green %+.3f vs %+.3f, histogram %.2f stops;",
                                   sampling == .points ? "points" : "cells", x.meanStops, y.meanStops, AutoBalance.mired(cx), AutoBalance.mired(cy),
                                   AutoBalance.axes(cx).greenMagenta, AutoBalance.axes(cy).greenMagenta, x.histogramDistance(to: y) ?? -1)
                }
                print(line)
            }
        }
    }
    /// What the analysis costs as the app makes it, faces and the decoder's noise included, on the
    /// CC0 frames and on the darkened scene at ISO 102400, where the most cells need their lift
    /// taken out: the median of five runs a frame.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func analysisCost() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let clock = ContinuousClock()
        var urls = AutoMeasureTests.folder("samples")
        urls.append(try SyntheticRaw.simulated(iso: 102400, stops: -3.5))
        for url in urls {
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            let frame = try decoder.decode(url, options: options)
            let info = try ARWFrameInfo.read(from: url)
            var times: [Double] = [], plain: [Double] = []
            for _ in 0..<5 {
                var start = clock.now
                _ = ExposureAnalyzer.analyze(frame, workingSpace: gpu.workingColorSpace, info: info)
                times.append(FrameViewMeasureTests.ms(clock.now - start))
                start = clock.now
                _ = ExposureAnalyzer.analyze(frame)
                plain.append(FrameViewMeasureTests.ms(clock.now - start))
            }
            print(String(format: "MEASURE analysis cost %@: %.1f ms with faces and noise, %.1f ms without (median of 5)",
                         url.deletingPathExtension().lastPathComponent, times.sorted()[2], plain.sorted()[2]))
        }
    }
}


extension ExposureAnalyzer {
    /// The analysis as it was made before 2026-10-07, for measuring the change: one pixel a sample,
    /// no noise taken out, and each face metered over every pixel of its inset.
    static func analyzeAsBefore(_ frame: LinearFrame, workingSpace: CGColorSpace?) -> ExposureAnalysis {
        let pixels = pixels(of: frame.texture)
        var analysis = analyze(pixels: pixels, width: frame.width, height: frame.height, sampling: .points)
        analysis.asShotTemperature = frame.readback?.asShotTemperature
        if let workingSpace {
            let boxes = FaceMeter.detect(frame.texture, workingSpace: workingSpace)
            analysis.faces = boxes.compactMap { box in
                let width = frame.width, height = frame.height
                let insetW = Float(box.width) * FaceMeter.insetWidth, insetH = Float(box.height) * FaceMeter.insetHeight
                let midRow = 1 - Float(box.midY)
                let x0 = Int(((Float(box.midX) - insetW / 2) * Float(width)).rounded()), x1 = Int(((Float(box.midX) + insetW / 2) * Float(width)).rounded())
                let y0 = Int(((midRow - insetH / 2) * Float(height)).rounded()), y1 = Int(((midRow + insetH / 2) * Float(height)).rounded())
                let xs = max(0, x0)..<min(width, x1), ys = max(0, y0)..<min(height, y1)
                guard !xs.isEmpty, !ys.isEmpty else { return nil }
                var sum: Float = 0, count: Float = 0
                for y in ys {
                    for x in xs {
                        let i = (y * width + x) * 4
                        let l = 0.2627 * Float(pixels[i]) + 0.6780 * Float(pixels[i + 1]) + 0.0593 * Float(pixels[i + 2])
                        sum += log2(max(l, 0.18 * exp2(floorStops)))
                        count += 1
                    }
                }
                return FaceMeasure(box: [Float(box.minX), Float(box.minY), Float(box.width), Float(box.height)],
                                   levelStops: sum / count - log2(0.18), area: Float(xs.count * ys.count) / Float(width * height))
            }
        }
        return analysis
    }
}
