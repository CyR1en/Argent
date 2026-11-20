import ArgentCore
import Foundation
import ImageIO
import Metal
import CoreImage
import Testing
@testable import ArgentRoll

/// Auto development's measurements on the a7 IV corpus and two ISO ladders, behind
/// docs/M3-auto.md. Runs only with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 swift test --filter AutoMeasureTests
@Suite(.serialized) struct AutoMeasureTests {
    typealias M = FrameViewMeasureTests

    static func folder(_ name: String) -> [URL] {
        RollScanner.rawFiles(in: M.root.appendingPathComponent(name)).sorted { $0.path < $1.path }
    }

    static func decodePreview(_ url: URL, decoder: AppleRawDecoder) throws -> (pixels: [Float16], width: Int, height: Int) {
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        let frame = try decoder.decode(url, options: options)
        return (ExposureAnalyzer.pixels(of: frame.texture), frame.width, frame.height)
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func exposureLevels() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let clock = ContinuousClock()
        let floors: [Float] = [-8, -6, -5, -4]
        let sets = [("field", Self.folder("samples") + Self.folder("references/corpus/photographyblog-a7iv")),
                    ("ladder a7 IV", Self.folder("references/corpus/imaging-resource-a7iv-wayback")),
                    ("ladder a7C", Self.folder("references/corpus/rawnind-a7c"))]
        var times: [Double] = [], invariance: [Float] = [], inBounds: [Float] = []
        for (name, files) in sets {
            var means: [[Float]] = Array(repeating: [], count: floors.count)
            var valid: [[Float]] = Array(repeating: [], count: floors.count)
            for url in files {
                let (pixels, width, height) = try Self.decodePreview(url, decoder: decoder)
                let start = clock.now
                _ = ExposureAnalyzer.analyze(pixels: pixels, width: width, height: height)
                times.append(M.ms(clock.now - start))
                var line = url.deletingPathExtension().lastPathComponent.prefix(28).padding(toLength: 28, withPad: " ", startingAt: 0)
                for (index, floor) in floors.enumerated() {
                    let a = ExposureAnalyzer.analyze(pixels: pixels, width: width, height: height, floorStops: floor)
                    means[index].append(a.meanStops)
                    valid[index].append(a.validWeight)
                    line += String(format: "  %+.2f (%3.0f%%)", a.meanStops, a.validWeight * 100)
                }
                // A frame given a stop more or less light measures a stop more or less.
                for factor: Float in [2, 0.5] {
                    let scaled = pixels.enumerated().map { $0.offset % 4 == 3 ? $0.element : Float16(Float($0.element) * factor) }
                    let base = ExposureAnalyzer.analyze(pixels: pixels, width: width, height: height)
                    let moved = ExposureAnalyzer.analyze(pixels: scaled, width: width, height: height)
                    let error = abs(moved.meanStops - base.meanStops - log2(factor))
                    invariance.append(error)
                    // Where the print follows the level, before and after the change of light: the
                    // metered rule's bounds, a lift of at most a stop (the rule is in `2a6e696`).
                    let bounds: ClosedRange<Float> = -1...AutoPrint.darkenLimit
                    if bounds.contains(base.meanStops), bounds.contains(base.meanStops + log2(factor)) { inBounds.append(error) }
                }
                print("MEASURE \(name) \(line)")
            }
            for (index, threshold) in floors.enumerated() {
                let m = means[index].sorted(), v = valid[index].sorted()
                print(String(format: "MEASURE %@ floor %.0f: mean stops %+.2f to %+.2f, spread %.2f; usable weight median %.0f%%, min %.0f%%",
                             name, threshold, m.first!, m.last!, m.last! - m.first!, v[v.count / 2] * 100, v.first! * 100))
            }
        }
        print("MEASURE analysis time: \(M.summary(times))")
        let worst = invariance.max() ?? 0
        print(String(format: "MEASURE a stop of light moves the measure by a stop within %.3f stops (worst of %d)", worst, invariance.count))
        print(String(format: "MEASURE within the print's bounds, within %.3f stops (worst of %d)", inBounds.max() ?? 0, inBounds.count))
    }

    /// Each folder as a roll: its clusters, how far smoothing moves each frame, and how far
    /// dropping any one frame moves the others (the research's truth-free check, under 0.1).
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func rollSmoothing() async throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        for name in ["samples", "references/corpus/photographyblog-a7iv", "references/corpus/imaging-resource-a7iv-wayback",
                     "references/corpus/rawnind-a7c"] {
            let roll = await RollScanner.scan(M.root.appendingPathComponent(name))
            var analyses: [URL: ExposureAnalysis] = [:]
            for frame in roll.frames {
                var options = DecodeOptions()
                options.maxLongSide = FilmPreviews.previewLongSide
                analyses[frame.url] = ExposureAnalyzer.analyze(try decoder.decode(frame.url, options: options))
            }
            let clusters = RollSmoothing.clusters(roll.frames, analyses: analyses)
            let levels = RollSmoothing.levels(roll.frames, analyses: analyses)
            var moved: [Float] = []
            for frame in roll.frames {
                let own = AutoPrint.levelStops(analyses[frame.url])
                moved.append(abs((levels[frame.url] ?? own) - own))
            }
            var worstDrop: Float = 0
            for dropped in roll.frames {
                let rest = roll.frames.filter { $0.url != dropped.url }
                let after = RollSmoothing.levels(rest, analyses: analyses)
                for frame in rest { worstDrop = max(worstDrop, abs((after[frame.url] ?? 0) - (levels[frame.url] ?? 0))) }
            }
            let gaps = zip(roll.frames, roll.frames.dropFirst()).map { a, b in
                b.info.captureDate.flatMap { y in a.info.captureDate.map { y.timeIntervalSince($0) } } ?? -1 }
            print("MEASURE smoothing \(name.split(separator: "/").last!): \(roll.frames.count) frames in clusters of \(clusters.map(\.count)); gaps \(gaps.map { Int($0) })")
            print(String(format: "MEASURE   frames moved by up to %.2f stops (median %.2f); dropping one frame moves another by up to %.3f",
                         moved.max() ?? 0, moved.sorted()[moved.count / 2], worstDrop))
            // Why each pair of neighbours in capture order splits or not.
            for (a, b) in zip(roll.frames, roll.frames.dropFirst()) {
                let p = analyses[a.url]!, q = analyses[b.url]!
                let ev = (a.info.sceneEV100 ?? 0) - (b.info.sceneEV100 ?? 0)
                let mired = 1e6 / (p.asShotTemperature ?? 1) - 1e6 / (q.asShotTemperature ?? 1)
                print(String(format: "MEASURE   %@ | EV %+.2f, flash %@/%@, white balance %.0f K → %.0f K (%+.0f mired), histogram %.2f stops%@",
                             String(b.name.suffix(14)), ev, "\(a.info.flashFired.map(String.init) ?? "-")", "\(b.info.flashFired.map(String.init) ?? "-")",
                             p.asShotTemperature ?? 0, q.asShotTemperature ?? 0, mired, p.histogramDistance(to: q) ?? -1,
                             RollSmoothing.splits(a, b, analyses: analyses) ? "  SPLIT" : ""))
            }
            for (index, cluster) in clusters.enumerated() where cluster.count > 1 {
                let line = cluster.map { f in String(f.name.suffix(6)) + String(format: " %+.2f→%+.2f",
                                                      AutoPrint.levelStops(analyses[f.url]), levels[f.url] ?? 0) }
                print("MEASURE   cluster \(index): \(line.joined(separator: ", "))")
            }
        }
    }

    /// The shades-of-gray cast against the camera's own auto white balance, both in mired
    /// against the decode's D55 neutral. The camera's choice is a stand-in for the light, not
    /// the truth.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func labBalanceAgainstTheCamera() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let d55 = 1e6 / Float(5500)
        var errors: [Float] = [], pairs: [(Float, Float)] = [], allPixels: [Float] = []
        for url in Self.folder("samples") + Self.folder("references/corpus/photographyblog-a7iv")
            + Self.folder("references/corpus/imaging-resource-a7iv-wayback").prefix(1) + Self.folder("references/corpus/rawnind-a7c").prefix(1) {
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            let decoded = try decoder.decode(url, options: options)
            let pixels = ExposureAnalyzer.pixels(of: decoded.texture)
            let everything = ExposureAnalyzer.analyze(pixels: pixels, width: decoded.width, height: decoded.height, grayGamut: nil)
            var analysis = ExposureAnalyzer.analyze(pixels: pixels, width: decoded.width, height: decoded.height)
            analysis.asShotTemperature = decoded.readback?.asShotTemperature
            let cast = AutoBalance.cast(analysis)
            let estimate = AutoBalance.mired(cast)
            allPixels.append(AutoBalance.mired(AutoBalance.cast(everything)))
            let camera = analysis.asShotTemperature.map { 1e6 / $0 - d55 } ?? .nan
            let corrected = AutoBalance.mired(AutoBalance.correction(for: cast))
            errors.append(abs(estimate - camera))
            pairs.append((estimate, camera))
            print(String(format: "MEASURE balance %@: estimate %+4.0f mired (all pixels %+4.0f), camera %+4.0f (%4.0f K), green %+.2f stops; print corrects %+4.0f",
                         String(url.deletingPathExtension().lastPathComponent.prefix(22)), estimate, allPixels.last!, camera,
                         analysis.asShotTemperature ?? 0, AutoBalance.axes(cast).greenMagenta, corrected))
        }
        let sorted = errors.sorted()
        let n = Float(pairs.count)
        let mx = pairs.map(\.0).reduce(0, +) / n, my = pairs.map(\.1).reduce(0, +) / n
        let cov = pairs.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +)
        let vx = pairs.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +), vy = pairs.map { ($0.1 - my) * ($0.1 - my) }.reduce(0, +)
        print(String(format: "MEASURE balance: |estimate - camera| median %.0f mired, worst %.0f; correlation %.2f (n=%d)",
                     sorted[sorted.count / 2], sorted.last!, cov / (vx * vy).squareRoot(), pairs.count))
    }

    /// What grain costs: making the noise tiles for a new pitch, and the print pass with and
    /// without grain at full size; then halation and capture sharpening on top.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func grainCost() throws {
        let clock = ContinuousClock()
        let gpu = try GPU()
        try gpu.grainField.prepare(library: try gpu.shaderLibrary())
        for longSide in [960, 2560, 4096, 7008] {
            let start = clock.now
            _ = try gpu.grainField.tiles(longSide: longSide)
            print("MEASURE grain tiles for \(longSide) px: \(M.ms(clock.now - start)) ms")
        }
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let texture = try gpu.texturePool.acquire(width: 7008, height: 4672)
        let frame = LinearFrame(image: texture, decoderVersion: "test", scale: 1)
        for grain: Float in [0, 1, 0, 1] {
            var times: [Double] = []
            for _ in 0..<5 { times.append(try renderer.render(frame, settings: DevelopSettings(grain: grain, grainSeed: 5)).gpuSeconds * 1000) }
            print("MEASURE film passes at 7008 px, grain \(grain): \(M.summary(times))")
        }
        // Halation's field is its own command buffer, so this times the whole render call.
        for halation in [false, true, false, true] {
            var times: [Double] = []
            for _ in 0..<5 {
                let start = clock.now
                _ = try renderer.render(frame, settings: DevelopSettings(grain: 1, grainSeed: 5, halation: halation))
                times.append(M.ms(clock.now - start))
            }
            print("MEASURE film render at 7008 px with grain, halation \(halation): \(M.summary(times))")
        }
        // Capture sharpening on top of both, in the print pass (docs/M3-auto.md, section 7).
        for sharpen in [false, true, false, true] {
            var times: [Double] = [], gpuTimes: [Double] = []
            for _ in 0..<7 {
                let start = clock.now
                let out = try renderer.render(frame, settings: DevelopSettings(grain: 1, grainSeed: 5, halation: true, sharpen: sharpen))
                times.append(M.ms(clock.now - start))
                gpuTimes.append(out.gpuSeconds * 1000)
            }
            print("MEASURE film render at 7008 px with grain and halation, sharpen \(sharpen): \(M.summary(times)); film passes \(M.summary(gpuTimes))")
        }
    }

    /// Faces on the FiveK people subset (research-only, local evaluation; references/corpus):
    /// each DNG rendered through Portra 400 at its faceless level and with the face rule, and
    /// the face's L* in each against its L* in expert C's rendition, in the same box. The
    /// pipelines differ in tone, so the offset means nothing; the spread is what face weighting
    /// should shrink.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func faceWeightingOnFiveK() throws {
        let folder = M.root.appendingPathComponent("references/corpus/fivek-subset")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("tiff16_c").path)) ?? [])
            .filter { $0.hasSuffix(".tif") }.map { String($0.dropLast(4)) }.sorted()
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let clock = ContinuousClock()
        func lightness(_ y: Double) -> Double { y > 0.008856 ? 116 * pow(y, 1.0 / 3) - 16 : 903.3 * y }
        func faceY(_ pixels: [Float16], _ width: Int, _ height: Int, _ box: [Float]) -> Double {
            let x0 = Int(Float(width) * (box[0] + box[2] * (1 - FaceMeter.insetWidth) / 2))
            let x1 = Int(Float(width) * (box[0] + box[2] * (1 + FaceMeter.insetWidth) / 2))
            // Rows run from the picture's bottom; the box is from its top.
            let y0 = Int(Float(height) * (1 - box[1] - box[3] * (1 + FaceMeter.insetHeight) / 2))
            let y1 = Int(Float(height) * (1 - box[1] - box[3] * (1 - FaceMeter.insetHeight) / 2))
            var sum = 0.0, n = 0.0
            for y in max(0, y0)..<min(height, y1) { for x in max(0, x0)..<min(width, x1) {
                let i = (y * width + x) * 4
                sum += 0.2627 * Double(pixels[i]) + 0.6780 * Double(pixels[i + 1]) + 0.0593 * Double(pixels[i + 2]); n += 1 } }
            return n > 0 ? sum / n : 0
        }
        var without: [Double] = [], with: [Double] = [], detectTimes: [Double] = [], withFaces = 0, counted = 0
        for name in names {
            let dng = folder.appendingPathComponent("dng/\(name).dng"), tiff = folder.appendingPathComponent("tiff16_c/\(name).tif")
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            guard let frame = try? decoder.decode(dng, options: options) else { print("MEASURE fivek \(name): no decode"); continue }
            let start = clock.now
            let analysis = ExposureAnalyzer.analyze(frame, workingSpace: gpu.workingColorSpace)
            detectTimes.append(M.ms(clock.now - start))
            guard let face = analysis.faces.max(by: { $0.area < $1.area }) else { print("MEASURE fivek \(name): no face"); continue }
            withFaces += 1
            // The expert's rendition at the same size, as linear Rec. 2020 light.
            // Upright as the file's orientation says, as the decode is.
            guard let expert = CIImage(contentsOf: tiff, options: [.applyOrientationProperty: true]) else { continue }
            let scale = Double(frame.width) / Double(expert.extent.width)
            guard abs(Double(frame.height) / Double(expert.extent.height) - scale) < 0.02 else {
                print("MEASURE fivek \(name): framing differs, skipped"); continue }
            // Core Image's origin differs between textures and images; take whichever way up
            // correlates with the decode, and say which.
            let scaled = expert.lanczosScaled(by: scale)
            let flipped = scaled.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -scaled.extent.height))
            let ours = ExposureAnalyzer.pixels(of: frame.texture)
            func luminance(_ p: [Float16]) -> [Double] {
                stride(from: 0, to: p.count, by: 4).map { log2(max(0.2627 * Double(p[$0]) + 0.6780 * Double(p[$0 + 1]) + 0.0593 * Double(p[$0 + 2]), 1e-4)) }
            }
            func correlation(_ a: [Double], _ b: [Double]) -> Double {
                let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
                var ab = 0.0, aa = 0.0, bb = 0.0
                for i in a.indices { ab += (a[i] - ma) * (b[i] - mb); aa += (a[i] - ma) * (a[i] - ma); bb += (b[i] - mb) * (b[i] - mb) }
                return ab / (aa * bb).squareRoot()
            }
            var best: (pixels: [Float16], r: Double, flipped: Bool)?
            for (candidate, isFlipped) in [(scaled, false), (flipped, true)] {
                let texture = try gpu.texturePool.acquire(width: frame.width, height: frame.height)
                let buffer = try #require(gpu.queue.makeCommandBuffer())
                gpu.ciContext.render(candidate, to: texture.texture, commandBuffer: buffer, bounds: candidate.extent, colorSpace: gpu.workingColorSpace)
                buffer.commit()
                buffer.waitUntilCompleted()
                let pixels = ExposureAnalyzer.pixels(of: texture.texture)
                let r = correlation(luminance(ours), luminance(pixels))
                if best == nil || r > best!.r { best = (pixels, r, isFlipped) }
            }
            guard let match = best, match.r > 0.5 else { print("MEASURE fivek \(name): expert does not line up, skipped"); continue }
            let expertY = faceY(match.pixels, frame.width, frame.height, face.box)
            var faceless = analysis
            faceless.faces = []
            var results: [Double] = []
            for a in [faceless, analysis] {
                let settings = RollControls(labBalance: .neutral).settings(for: stock, aim: PrintAim(level: AutoPrint.levelStops(a)))
                let out = try renderer.render(frame, settings: settings)
                results.append(lightness(faceY(ExposureAnalyzer.pixels(of: out.image.texture), frame.width, frame.height, face.box))
                               - lightness(expertY))
            }
            counted += 1
            without.append(results[0]); with.append(results[1])
            print(String(format: "MEASURE fivek %@ (r %.2f%@): face %.1f%% of frame at %+.2f, frame %+.2f; level %+.2f -> %+.2f; face L* minus expert %+.1f -> %+.1f",
                         name, match.r, match.flipped ? ", flipped" : "", face.area * 100, face.levelStops, analysis.meanStops, AutoPrint.levelStops(faceless),
                         AutoPrint.levelStops(analysis), results[0], results[1]))
        }
        func spread(_ v: [Double]) -> String {
            let mean = v.reduce(0, +) / Double(max(v.count, 1))
            let sd = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(v.count - 1, 1))).squareRoot()
            let worst = v.map { abs($0 - mean) }.max() ?? 0
            return String(format: "offset %+.1f, spread %.1f L*, worst %.1f from the offset", mean, sd, worst)
        }
        print("MEASURE fivek: \(names.count) photos, faces found in \(withFaces), compared \(counted); detection and analysis \(M.summary(detectTimes))")
        print("MEASURE fivek faceless: \(spread(without))")
        print("MEASURE fivek with faces: \(spread(with))")
    }

    // MARK: Capture sharpening

    /// L* of each pixel of a render in display-linear light, or the plain luminance when `linear`.
    static func lightness(_ pixels: [Float16], linear: Bool = false) -> [Float] {
        var out = [Float](repeating: 0, count: pixels.count / 4)
        for i in out.indices {
            let y = 0.2627 * Float(pixels[4 * i]) + 0.6780 * Float(pixels[4 * i + 1]) + 0.0593 * Float(pixels[4 * i + 2])
            out[i] = linear ? y : (y > 0.008856 ? 116 * cbrt(y) - 16 : 903.3 * y)
        }
        return out
    }

    /// A near-vertical edge in `columns` and `rows` of `v`: each row's profile normalized to its
    /// two ends, aligned on its half-way crossing, and averaged at a twentieth of a pixel.
    /// Returns the 10 to 90 percent rise in pixels, the overshoot past either plateau (the
    /// medians of the outer sixths) as a share of the step, and the sigma of the Gaussian whose
    /// blurred step fits the profile best within 3 pixels of the edge.
    static func edge(_ v: [Float], width: Int, columns: Range<Int>, rows: Range<Int>, reach: Float)
        -> (rise: Float, overshoot: Float, sigma: Float) {
        let step: Float = 0.05, n = columns.count
        let count = Int(2 * reach / step) + 1
        var sum = [Float](repeating: 0, count: count), used = 0
        for y in rows {
            let p = columns.map { v[y * width + $0] }
            let lo = (p[0] + p[1]) / 2, hi = (p[n - 2] + p[n - 1]) / 2
            guard abs(hi - lo) > 1e-3 else { continue }
            let q = p.map { ($0 - lo) / (hi - lo) }
            guard let i = (0..<(n - 1)).first(where: { q[$0] < 0.5 && q[$0 + 1] >= 0.5 }) else { continue }
            let c = Float(i) + (0.5 - q[i]) / (q[i + 1] - q[i])
            guard c - reach >= 0, c + reach <= Float(n - 1) else { continue }
            for k in 0..<count {
                let x = c - reach + Float(k) * step
                let j = min(Int(x), n - 2), f = x - Float(j)
                sum[k] += q[j] * (1 - f) + q[j + 1] * f
            }
            used += 1
        }
        let esf = sum.map { $0 / Float(max(used, 1)) }
        let outer = max(3, count / 6)
        func median(_ values: ArraySlice<Float>) -> Float { values.sorted()[values.count / 2] }
        let lo = median(esf.prefix(outer)), hi = median(esf.suffix(outer))
        let e = esf.map { ($0 - lo) / (hi - lo) }
        var a = count / 2, b = count / 2
        while a > 0, e[a] > 0.1 { a -= 1 }
        while b < count - 1, e[b] < 0.9 { b += 1 }
        let xa = Float(a) + (0.1 - e[a]) / (e[a + 1] - e[a])
        let xb = Float(b - 1) + (0.9 - e[b - 1]) / (e[b] - e[b - 1])
        var best: (error: Float, sigma: Float) = (.infinity, 0)
        for sigma in stride(from: Float(0.3), through: 3, by: 0.01) {
            var error: Float = 0
            for k in 0..<count {
                let x = -reach + Float(k) * step
                guard abs(x) <= 3 else { continue }
                let d = e[k] - 0.5 * (1 + erf(x / (sigma * Float(2).squareRoot())))
                error += d * d
            }
            if error < best.error { best = (error, sigma) }
        }
        return ((xb - xa) * step, max(e.max()! - 1, -e.min()!), best.sigma)
    }

    /// The standard deviation of `v` over a flat patch, a fitted plane taken out.
    static func flatNoise(_ v: [Float], width: Int, columns: Range<Int>, rows: Range<Int>) -> Float {
        var values: [(x: Float, y: Float, v: Float)] = []
        for y in rows { for x in columns { values.append((Float(x), Float(y), v[y * width + x])) } }
        let n = Float(values.count)
        let mx = values.map(\.x).reduce(0, +) / n, my = values.map(\.y).reduce(0, +) / n
        let mv = values.map(\.v).reduce(0, +) / n
        var sxx: Float = 0, syy: Float = 0, sxv: Float = 0, syv: Float = 0
        for p in values {
            sxx += (p.x - mx) * (p.x - mx); syy += (p.y - my) * (p.y - my)
            sxv += (p.x - mx) * (p.v - mv); syv += (p.y - my) * (p.v - mv)
        }
        let bx = sxv / sxx, by = syv / syy
        var squares: Float = 0
        for p in values {
            let r = p.v - mv - bx * (p.x - mx) - by * (p.y - my)
            squares += r * r
        }
        return (squares / n).squareRoot()
    }

    /// The central square of `v`, up to 1024 pixels a side.
    static func centre(_ v: [Float], width: Int) -> (values: [Float], side: Int) {
        let height = v.count / width, side = min(width, height, 1024)
        let x0 = (width - side) / 2, y0 = (height - side) / 2
        var out: [Float] = []
        out.reserveCapacity(side * side)
        for y in y0..<(y0 + side) { out += v[(y * width + x0)..<(y * width + x0 + side)] }
        return (out, side)
    }

    /// `v`, a `side`-pixel square, blurred by a sampled Gaussian of `sigma`, edges repeated.
    static func blurred(_ v: [Float], side: Int, sigma: Float) -> [Float] {
        let radius = Int((3 * sigma).rounded(.up))
        var weights = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +)
        weights = weights.map { $0 / total }
        var across = [Float](repeating: 0, count: v.count), out = across
        for y in 0..<side { for x in 0..<side {
            var sum: Float = 0
            for k in -radius...radius { sum += weights[k + radius] * v[y * side + min(max(x + k, 0), side - 1)] }
            across[y * side + x] = sum } }
        for y in 0..<side { for x in 0..<side {
            var sum: Float = 0
            for k in -radius...radius { sum += weights[k + radius] * across[min(max(y + k, 0), side - 1) * side + x] }
            out[y * side + x] = sum } }
        return out
    }

    /// The RMS of the central square in three bands, differences of Gaussians of sigma 0.5 and
    /// 1, 1 and 2, 2 and 4 pixels, which peak near 0.31, 0.15 and 0.08 cycles per pixel.
    static func bands(_ v: [Float], width: Int) -> [Float] {
        let (square, side) = centre(v, width: width)
        let blurs = [0.5, 1, 2, 4].map { blurred(square, side: side, sigma: $0) }
        return (0..<3).map { band in
            var squares: Float = 0
            for i in square.indices { let d = blurs[band][i] - blurs[band + 1][i]; squares += d * d }
            return (squares / Float(square.count)).squareRoot()
        }
    }

    /// `texture` area-resized so its longer side is `longSide`, as a develop resizes.
    static func area(_ texture: MTLTexture, longSide: Int, resize: AreaResize) throws -> (pixels: [Float16], width: Int) {
        let out = try resize.resized(texture, scale: Double(longSide) / Double(max(texture.width, texture.height)))
        return (ExposureAnalyzer.pixels(of: out.texture), out.width)
    }

    /// `texture` resized by Core Image's Lanczos so its longer side is `longSide`, as a develop
    /// resized before the area resize (docs/M3-auto.md, section 9).
    static func lanczos(_ texture: MTLTexture, longSide: Int, gpu: GPU) throws -> (pixels: [Float16], width: Int) {
        let scale = Double(longSide) / Double(max(texture.width, texture.height))
        let source = CIImage(mtlTexture: texture, options: [.colorSpace: gpu.workingColorSpace])!
        let image = source.lanczosScaled(by: scale)
        let extent = image.extent.integral
        let out = try gpu.texturePool.acquire(width: Int(extent.width), height: Int(extent.height))
        let commandBuffer = gpu.queue.makeCommandBuffer()!
        gpu.ciContext.render(image, to: out.texture, commandBuffer: commandBuffer, bounds: extent, colorSpace: gpu.workingColorSpace)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return (ExposureAnalyzer.pixels(of: out.texture), out.width)
    }

    /// Capture sharpening on Imaging Resource's a7 IV still life through Portra 400 (docs/M3-auto.md,
    /// section 7): the decode's own blur on a sharp edge; at full size, two edges of the
    /// ColorChecker and the flat gray card before and after; the same frame developed at full
    /// size and resized against rendered from a smaller decode, as the sheet renders it; and
    /// noise in the card up the ISO ladder. Its cost is in `grainCost`. The frame view, which
    /// renders a decode at the window's own pixels, is `FrameViewSharpnessMeasureTests`.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func captureSharpening() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let resize = try AreaResize(gpu: gpu)
        let ladder = M.root.appendingPathComponent("references/corpus/imaging-resource-a7iv-wayback")
        let url = ladder.appendingPathComponent("A7M4hSLI000100NR0.ARW")
        // Full-size picture coordinates: the right edges of the chart's white and middle-gray
        // patches against its dark frame, and the gray card at the top.
        let whiteEdge = 3270..<3330, grayEdge = 3595..<3650, edgeRows = 3985..<4040
        let cardColumns = 4600..<4900, cardRows = 60..<280
        func scaled(_ r: Range<Int>, _ s: Float) -> Range<Int> { Int(Float(r.lowerBound) * s)..<Int(Float(r.upperBound) * s) }
        // Textures hold their rows bottom up.
        func up(_ r: Range<Int>, _ height: Int) -> Range<Int> { (height - r.upperBound)..<(height - r.lowerBound) }
        func percent(_ v: Float) -> String { String(format: "%.1f%%", v * 100) }

        let full = try decoder.decode(url, options: DecodeOptions())
        let linear = Self.lightness(ExposureAnalyzer.pixels(of: full.texture), linear: true)
        let own = Self.edge(linear, width: full.width, columns: whiteEdge, rows: up(edgeRows, full.height), reach: 8)
        print(String(format: "MEASURE sharpen: the decode's white edge in scene-linear light rises in %.2f px; a blurred step fits it at sigma %.2f px",
                     own.rise, own.sigma))
        var fullBands: [Bool: [Float]] = [:]
        for sharpen in [false, true] {
            let out = try renderer.render(full, settings: DevelopSettings(sharpen: sharpen))
            let l = Self.lightness(ExposureAnalyzer.pixels(of: out.image.texture))
            let rows = up(edgeRows, full.height)
            let white = Self.edge(l, width: full.width, columns: whiteEdge, rows: rows, reach: 8)
            let gray = Self.edge(l, width: full.width, columns: grayEdge, rows: rows, reach: 8)
            let noise = Self.flatNoise(l, width: full.width, columns: cardColumns, rows: up(cardRows, full.height))
            fullBands[sharpen] = Self.bands(l, width: full.width)
            print(String(format: "MEASURE sharpen %@ at 7008 px: white edge rise %.2f px (sigma %.2f), overshoot %@; gray edge rise %.2f px (sigma %.2f), overshoot %@; card L* sd %.3f",
                         sharpen ? "on " : "off", white.rise, white.sigma, percent(white.overshoot), gray.rise, gray.sigma,
                         percent(gray.overshoot), noise))
        }
        let gain = zip(fullBands[true]!, fullBands[false]!).map { String(format: "%.2f", $0 / $1) }
        print("MEASURE sharpen at 7008 px: band amplitude on over off near 0.31, 0.15, 0.08 cycles/px: \(gain)")

        // The same print size two ways: the full-size develop resized, and a smaller decode
        // rendered, as the contact sheet's (960) and the frame view's (the window's own pixels)
        // are. The develop is area-resized, as a long-edge develop is; Lanczos, which resized it
        // before, is kept for comparison.
        func ratio(_ a: [Float], _ aw: Int, _ b: [Float], _ bw: Int) -> String {
            zip(Self.bands(a, width: aw), Self.bands(b, width: bw)).map { String(format: "%.2f", $0 / $1) }.joined(separator: ", ")
        }
        func measures(_ l: [Float], _ width: Int, _ s: Float) -> String {
            let rows = up(scaled(edgeRows, s), l.count / width)
            let e = Self.edge(l, width: width, columns: scaled(whiteEdge, s), rows: rows, reach: max(2, 8 * s))
            let noise = Self.flatNoise(l, width: width, columns: scaled(cardColumns, s), rows: up(scaled(cardRows, s), l.count / width))
            return String(format: "edge rise %.2f px, overshoot %@, card sd %.3f", e.rise, percent(e.overshoot), noise)
        }
        var fullRenders: [Bool: PooledTexture] = [:]
        for sharpen in [false, true] { fullRenders[sharpen] = try renderer.render(full, settings: DevelopSettings(sharpen: sharpen)).image }
        for longSide in [960, 2048, 3072, 4096, 6144] {
            var options = DecodeOptions()
            options.maxLongSide = longSide
            let small = try decoder.decode(url, options: options)
            let s = Float(small.width) / Float(full.width)
            for sharpen in [false, true] {
                let settings = DevelopSettings(sharpen: sharpen)
                let area = try Self.area(fullRenders[sharpen]!.texture, longSide: longSide, resize: resize)
                let lanczos = try Self.lanczos(fullRenders[sharpen]!.texture, longSide: longSide, gpu: gpu)
                let direct = ExposureAnalyzer.pixels(of: try renderer.render(small, settings: settings).image.texture)
                let a = Self.lightness(area.pixels), z = Self.lightness(lanczos.pixels), d = Self.lightness(direct)
                var line = "MEASURE sharpen \(sharpen ? "on " : "off") at \(longSide) px (decode scale \(String(format: "%.3f", small.scale))"
                line += "\(small.pins?.draftMode == true ? ", draft" : ""): decoded over area-resized, bands \(ratio(d, small.width, a, area.width));"
                line += " over Lanczos \(ratio(d, small.width, z, lanczos.width)); area over Lanczos \(ratio(a, area.width, z, lanczos.width));"
                line += " area \(measures(a, area.width, s)); Lanczos \(measures(z, lanczos.width, s)); decoded \(measures(d, small.width, s))"
                print(line)
            }
        }
        // The sheet's picture made from the frame view's decode, area-resized to 960 before the
        // film, against the develop area-resized to 960.
        for frameSide in [2048, 3072, 4096] {
            var options = DecodeOptions()
            options.maxLongSide = frameSide
            let large = try decoder.decode(url, options: options)
            let scale = Double(960) / Double(max(large.width, large.height))
            let sheet = LinearFrame(image: try resize.resized(large.texture, scale: scale), decoderVersion: large.decoderVersion,
                                    scale: large.scale * Float(scale), pins: large.pins, readback: large.readback)
            let s = Float(sheet.width) / Float(full.width)
            for sharpen in [false, true] {
                let area = try Self.area(fullRenders[sharpen]!.texture, longSide: 960, resize: resize)
                let d = Self.lightness(ExposureAnalyzer.pixels(of: try renderer.render(sheet, settings: DevelopSettings(sharpen: sharpen)).image.texture))
                let a = Self.lightness(area.pixels)
                print("MEASURE sharpen \(sharpen ? "on " : "off") at 960 px from the frame view's \(frameSide) px decode: over area-resized, bands \(ratio(d, sheet.width, a, area.width)); sheet \(measures(d, sheet.width, s)); area \(measures(a, area.width, s))")
            }
        }
        fullRenders = [:]

        // Noise in the flat card up the ladder, without grain and with it.
        for iso in [100, 800, 3200, 12800, 51200] {
            let name = "A7M4hSLI" + String(format: "%06d", iso) + "NR0.ARW"
            let frame = try decoder.decode(ladder.appendingPathComponent(name), options: DecodeOptions())
            var line = "MEASURE sharpen: gray card L* sd at ISO \(iso):"
            for grain: Float in [0, 1] {
                for sharpen in [false, true] {
                    let out = try renderer.render(frame, settings: DevelopSettings(grain: grain, grainSeed: 5, sharpen: sharpen))
                    let l = Self.lightness(ExposureAnalyzer.pixels(of: out.image.texture))
                    let noise = Self.flatNoise(l, width: frame.width, columns: cardColumns, rows: up(cardRows, frame.height))
                    line += String(format: " grain %.0f sharpen %@ %.3f;", grain, sharpen ? "on" : "off", noise)
                }
            }
            print(line)
        }
    }

    /// The area resize against Core Image's Lanczos on Imaging Resource's still life through
    /// Portra 400 at 2048 and 4096 px (docs/M3-auto.md, section 9): the chart's dark frame beside
    /// its white patch, where Lanczos rang, and the edge's rise; then what each costs from 7008
    /// px, on the GPU and as the whole picture.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func areaResize() throws {
        let gpu = try GPU(maxIdlePoolBytes: 2 << 30)
        let decoder = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let resize = try AreaResize(gpu: gpu)
        let url = M.root.appendingPathComponent("references/corpus/imaging-resource-a7iv-wayback/A7M4hSLI000100NR0.ARW")
        // The white patch's right edge against the dark frame, in full-size picture coordinates,
        // white to the left; textures hold their rows bottom up.
        let whiteEdge = 3270..<3330, edgeRows = 3985..<4040
        func scaled(_ r: Range<Int>, _ s: Float) -> Range<Int> { Int(Float(r.lowerBound) * s)..<Int(Float(r.upperBound) * s) }
        func up(_ r: Range<Int>, _ height: Int) -> Range<Int> { (height - r.upperBound)..<(height - r.lowerBound) }

        let full = try decoder.decode(url, options: DecodeOptions())
        let settingsList = [("plain", DevelopSettings()), ("sharpened", DevelopSettings(sharpen: true)),
                            ("as the app develops", DevelopSettings(grain: 1, grainSeed: 5, halation: true, sharpen: true))]
        for (name, settings) in settingsList {
            let rendered = try renderer.render(full, settings: settings).image
            for longSide in [7008, 2048, 4096] {
                let s = Float(longSide) / Float(full.width)
                let pictures: [(String, (pixels: [Float16], width: Int))] = longSide == full.width
                    ? [("full size", (ExposureAnalyzer.pixels(of: rendered.texture), full.width))]
                    : [("Lanczos", try Self.lanczos(rendered.texture, longSide: longSide, gpu: gpu)),
                       ("area", try Self.area(rendered.texture, longSide: longSide, resize: resize))]
                for (method, picture) in pictures {
                    let l = Self.lightness(picture.pixels), width = picture.width, height = l.count / width
                    let columns = scaled(whiteEdge, s), rows = up(scaled(edgeRows, s), height)
                    // The mean L* of each column over the rows: the edge's profile. The dark frame
                    // runs from the edge to the next patch, which the range ends in.
                    let profile = columns.map { x in rows.map { l[$0 * width + x] }.reduce(0, +) / Float(rows.count) }
                    let white = profile.prefix(max(2, profile.count / 4)).sorted()[max(2, profile.count / 4) / 2]
                    let crossing = profile.firstIndex { $0 < (white + 20) / 2 } ?? 0
                    var pixels: [Float] = []
                    for y in rows { for x in columns.lowerBound + crossing..<columns.upperBound { pixels.append(l[y * width + x]) } }
                    let e = Self.edge(l, width: width, columns: columns, rows: rows, reach: max(2, 8 * s))
                    let shown = profile[max(0, crossing - 3)...].map { String(format: "%.1f", $0) }.joined(separator: " ")
                    print(String(format: "MEASURE resize %@ at %d px, %@: white L* %.1f; in the dark frame the lowest column %.1f, the lowest pixel %.1f; rise %.2f px, overshoot %.1f%%; profile from the edge %@",
                                 name, longSide, method, white, profile[crossing...].min()!, pixels.min()!, e.rise, e.overshoot * 100, shown))
                }
            }
        }

        // The previews' resizes, as the app makes them: a render scaled to the frame view's pixels
        // or a sheet cell's, and the sheet's scene-linear decode scaled from the frame view's.
        let appSettings = DevelopSettings(grain: 1, grainSeed: 5, halation: true, sharpen: true)
        func darkFrame(_ picture: (pixels: [Float16], width: Int)) -> String {
            let l = Self.lightness(picture.pixels), width = picture.width, height = l.count / width
            let s = Float(width) / Float(full.width)
            let columns = scaled(whiteEdge, s), rows = up(scaled(edgeRows, s), height)
            let profile = columns.map { x in rows.map { l[$0 * width + x] }.reduce(0, +) / Float(rows.count) }
            let crossing = profile.firstIndex { $0 < 58 } ?? 0
            var pixels: [Float] = []
            for y in rows { for x in columns.lowerBound + crossing..<columns.upperBound { pixels.append(l[y * width + x]) } }
            return String(format: "lowest column %.1f, lowest pixel %.1f", profile[crossing...].min()!, pixels.min()!)
        }
        for (decodeSide, displaySide) in [(2560, 2190), (3072, 2600), (960, 672), (960, 320)] {
            var options = DecodeOptions()
            options.maxLongSide = decodeSide
            let decoded = try decoder.decode(url, options: options)
            let rendered = try renderer.render(decoded, settings: appSettings).image
            let lanczos = try Self.lanczos(rendered.texture, longSide: displaySide, gpu: gpu)
            let area = try Self.area(rendered.texture, longSide: displaySide, resize: resize)
            print("MEASURE resize preview rendered at \(decodeSide) px shown at \(displaySide): dark frame by Lanczos \(darkFrame(lanczos)); by area \(darkFrame(area))")
        }
        for frameSide in [2048, 3072, 4096] {
            var options = DecodeOptions()
            options.maxLongSide = frameSide
            let large = try decoder.decode(url, options: options)
            let scale = 960 / Double(max(large.width, large.height))
            var line = "MEASURE resize sheet picture from the frame view's \(frameSide) px decode, scaled to 960 before the film:"
            for method in ["Lanczos", "area"] {
                let texture: PooledTexture
                if method == "area" {
                    texture = try resize.resized(large.texture, scale: scale)
                } else {
                    let image = CIImage(mtlTexture: large.texture, options: [.colorSpace: gpu.workingColorSpace])!.lanczosScaled(by: scale)
                    texture = try gpu.texturePool.acquire(width: Int(image.extent.width), height: Int(image.extent.height))
                    let commandBuffer = gpu.queue.makeCommandBuffer()!
                    gpu.ciContext.render(image, to: texture.texture, commandBuffer: commandBuffer, bounds: image.extent, colorSpace: gpu.workingColorSpace)
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                }
                let sheet = LinearFrame(image: texture, decoderVersion: large.decoderVersion, scale: large.scale * Float(scale),
                                        pins: large.pins, readback: large.readback)
                let out = try renderer.render(sheet, settings: appSettings).image
                line += " \(method) \(darkFrame((ExposureAnalyzer.pixels(of: out.texture), out.width)));"
            }
            print(line)
        }

        // Cost from 7008 px: the area resize in one pass and in two (across, then down), and
        // Lanczos, on the GPU; then the whole 8-bit picture each way.
        let source = try gpu.texturePool.acquire(width: 7008, height: 4672)
        let lanczosEncoder = { (texture: MTLTexture, longSide: Int, output: MTLTexture, commandBuffer: MTLCommandBuffer) in
            let image = CIImage(mtlTexture: texture, options: [.colorSpace: gpu.workingColorSpace])!
                .lanczosScaled(by: Double(longSide) / Double(max(texture.width, texture.height)))
            gpu.ciContext.render(image, to: output, commandBuffer: commandBuffer, bounds: image.extent, colorSpace: gpu.workingColorSpace)
        }
        for longSide in [2048, 4096] {
            let size = AreaResize.size(width: 7008, height: 4672, scale: Double(longSide) / 7008)
            let output = try gpu.texturePool.acquire(width: size.width, height: size.height)
            let between = try gpu.texturePool.acquire(width: size.width, height: 4672)
            var times: [String: [Double]] = [:]
            for _ in 0..<9 {
                for method in ["one pass", "two passes", "Lanczos"] {
                    let commandBuffer = gpu.queue.makeCommandBuffer()!
                    switch method {
                    case "one pass": try resize.encode(source.texture, to: output.texture, into: commandBuffer)
                    case "two passes":
                        try resize.encode(source.texture, to: between.texture, into: commandBuffer)
                        try resize.encode(between.texture, to: output.texture, into: commandBuffer)
                    default: lanczosEncoder(source.texture, longSide, output.texture, commandBuffer)
                    }
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                    times[method, default: []].append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
                }
            }
            for method in ["one pass", "two passes", "Lanczos"] {
                print("MEASURE resize cost on \(gpu.device.name), 7008 to \(longSide) px, \(method), GPU: \(M.summary(Array(times[method]!.dropFirst())))")
            }
            let encoder = try ImageEncoder(gpu: gpu)
            let clock = ContinuousClock()
            var pictureTimes: [String: [Double]] = [:]
            for _ in 0..<7 {
                var start = clock.now
                _ = try encoder.picture(source.texture, colorSpace: gpu.workingColorSpace, format: .jpeg(quality: 0.92), longEdge: longSide)
                pictureTimes["area", default: []].append(M.ms(clock.now - start))
                start = clock.now
                let image = CIImage(mtlTexture: source.texture, options: [.colorSpace: gpu.workingColorSpace])!
                    .lanczosScaled(by: Double(longSide) / 7008)
                _ = gpu.ciContext.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                colorSpace: OutputSpace.sRGB.colorSpace, deferred: false)
                pictureTimes["Lanczos", default: []].append(M.ms(clock.now - start))
            }
            for method in ["area", "Lanczos"] {
                print("MEASURE resize cost 7008 to \(longSide) px, the whole 8-bit picture by \(method): \(M.summary(Array(pictureTimes[method]!.dropFirst())))")
            }
        }
    }
}

/// Moved from ArgentCore's ImageEncoder.swift, where nothing in production has used it since 4a84dea.
fileprivate extension CIImage {
    /// The image scaled by `scale` with Lanczos, cropped to whole pixels: `round(width *
    /// scale)` by `round(height * scale)` from the origin. The edges are clamped first, so the
    /// filter does not pull in the transparent pixels beyond the image, which darkened the
    /// outer rows and columns, and a fractional extent is not rounded up into a half-covered
    /// row (measured: 55 and 112 against 118 on a flat gray before). Lanczos rings beside a
    /// high-contrast edge, so pictures are resized by area (`AreaResize`); the measurements
    /// keep this to compare against.
    func lanczosScaled(by scale: CGFloat) -> CIImage {
        let width = (extent.width * scale).rounded(), height = (extent.height * scale).rounded()
        let origin = CGPoint(x: (extent.minX * scale).rounded(), y: (extent.minY * scale).rounded())
        return clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            .cropped(to: CGRect(origin: origin, size: CGSize(width: max(1, width), height: max(1, height))))
    }
}
