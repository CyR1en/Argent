import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The in-house decoder against Apple's, behind docs/decoder.md. Like the other measurement
/// suites these read the CC0 samples, the git-ignored corpus and build/stocks, and run only with
/// ARGENT_MEASURE=1, one test at a time, in a release build so the CPU statistics are quick:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter InHouseDecoderMeasureTests/speed
///
/// The corpus has one lossless L file, the CC0 sample. The colour fit and the per-scene
/// comparisons also run the decoder's GPU half on uncompressed frames, whose mosaics are the same
/// sensor's samples at the same black and white levels (`MeasureMosaic`); everything that touches
/// the lossless tiles runs on the sample.
@Suite(.serialized, .syntheticRaws) struct InHouseDecoderMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }
    static let root = FrameViewMeasureTests.root
    static let lossless = root.appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    static func corpus(_ path: String) -> URL { root.appendingPathComponent("references/corpus/" + path) }

    /// The frames `InHouseColor` is fitted on, all of them data whose licence allows choosing
    /// constants on it (docs/provenance.md): the CC0 lossless L sample, the uncompressed CC0 sample
    /// of the same scene, the CC0 APS-C uncompressed sample at ISO 640, and synthetic colour patches
    /// written into a copy of the uncompressed sample (`SyntheticRaw.patches`).
    static let cc0Frames: [URL] = [
        lossless,
        root.appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW"),
        root.appendingPathComponent("references/exposure/pixls-ilce-7m4-samples/ILCE-7M4_DSC06678_APS-C-Raw-Uncompressed.ARW"),
    ]

    /// The frames the colour was first fitted on (milestone 1): two CC0 samples, six photographyblog
    /// frames (two of them in portrait) and four still lifes from Imaging Resource's ISO ladder. Their
    /// terms allow evaluation only, so they are now the held-out check and choose nothing.
    static let evaluationFrames: [URL] = [
        lossless,
        root.appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW"),
        corpus("photographyblog-a7iv/sony_a7_iv_05.arw"), corpus("photographyblog-a7iv/sony_a7_iv_13.arw"),
        corpus("photographyblog-a7iv/sony_a7_iv_22.arw"), corpus("photographyblog-a7iv/sony_a7_iv_34.arw"),
        corpus("photographyblog-a7iv/sony_a7_iv_38.arw"), corpus("photographyblog-a7iv/sony_a7_iv_71.arw"),
        corpus("imaging-resource-a7iv-wayback/A7M4hSLI000050NR0.ARW"), corpus("imaging-resource-a7iv-wayback/A7M4hSLI000100NR0.ARW"),
        corpus("imaging-resource-a7iv-wayback/A7M4hSLI001600NR0.ARW"), corpus("imaging-resource-a7iv-wayback/A7M4hSLI102400NR0.ARW"),
    ]

    // MARK: Colour

    /// One frame's 16-pixel block means: this decoder's camera RGB (black-subtracted,
    /// white-normalized, no gains) and Apple's linear Rec. 2020 with its exposure gain divided out,
    /// lens correction and noise reduction off on both, blocks with a channel past 0.9 of its clip or
    /// under 0.003 left out. With `flatOnly`, only blocks whose four neighbours agree with them within
    /// half a percent: the inside of a synthetic frame's patches.
    struct ColourBlocks {
        var name: String
        var camera: [SIMD3<Double>]
        var apple: [SIMD3<Double>]
    }

    static func colourBlocks(_ url: URL, name: String? = nil, flatOnly: Bool = false, decoder: InHouseDecoder, apple: AppleRawDecoder,
                             gpu: GPU) throws -> ColourBlocks {
        let gains = InHouseColor.daylightGains
        // White-balanced camera RGB back to plain camera RGB: the output is black-subtracted,
        // white-normalized camera RGB with no gain.
        let unbalance = (0..<3).map { r in (0..<3).map { c in r == c ? 1 / gains[r] : 0 } }
        let source = try MeasureMosaic.load(url, device: gpu.device)
        let (ours, _) = try decoder.render(source.buffer, layout: source.layout, orientation: source.orientation,
                                           gainStops: 0, iso: nil, options: Self.inHouseOff, matrix: unbalance)
        let reference = try apple.decode(url, options: Self.appleOptions(lens: false, noiseReduction: false))
        let gain = exp2(Double(ExposureAnchor.gainStops(iso: source.iso.map(Float.init))))
        let a = Pixels(ours.texture), b = Pixels(reference.texture)
        #expect(a.width == b.width && a.height == b.height)
        let block = 16, across = a.width / block
        let ca = a.blockMeans(block, clipAbove: 0.9), cb = b.blockMeans(block, clipAbove: .infinity)
        var camera: [SIMD3<Double>] = [], target: [SIMD3<Double>] = []
        for i in ca.indices {
            guard let c = ca[i], let t = cb[i] else { continue }
            let lowest = min(c.x, c.y, c.z), appleLowest = min(t.x, t.y, t.z) / gain
            guard lowest > 0.003, appleLowest > 0.003 else { continue }
            if flatOnly {
                let neighbours = [i - 1, i + 1, i - across, i + across]
                guard i % across > 0, i % across < across - 1, neighbours.allSatisfy({ $0 >= 0 && $0 < ca.count }) else { continue }
                let flat = neighbours.allSatisfy { j in
                    guard let n = ca[j] else { return false }
                    return abs(n.x / c.x - 1) < 0.005 && abs(n.y / c.y - 1) < 0.005 && abs(n.z / c.z - 1) < 0.005
                }
                guard flat else { continue }
            }
            camera.append(c)
            target.append(t / gain)
        }
        return ColourBlocks(name: name ?? url.lastPathComponent, camera: camera, apple: target)
    }

    /// The gains and matrix fitted to `frames` by weighted least squares, equal weight per frame and
    /// each block by its relative error: the neutral is the camera RGB the fit maps to equal channels,
    /// normalized to green, and the matrix is the fit after it.
    static func fitColour(_ frames: [ColourBlocks]) -> (gains: [Double], matrix: [[Double]]) {
        var xtx = [[Double]](repeating: [0, 0, 0], count: 3), xty = [[Double]](repeating: [0, 0, 0], count: 3)
        for frame in frames {
            let frameWeight = 1 / Double(frame.camera.count)
            for (x, y) in zip(frame.camera, frame.apple) {
                let luminance = max(0.2627 * y.x + 0.678 * y.y + 0.0593 * y.z, 1e-3)
                let w = frameWeight / (luminance * luminance)
                let xs = [x.x, x.y, x.z], ys = [y.x, y.y, y.z]
                for i in 0..<3 { for j in 0..<3 { xtx[i][j] += w * xs[i] * xs[j]; xty[i][j] += w * xs[i] * ys[j] } }
            }
        }
        let fit = Matrix3.transpose(Matrix3.multiply(Matrix3.invert(xtx), xty))
        let neutral = Matrix3.apply(Matrix3.invert(fit), SIMD3(1, 1, 1))
        let gains = [neutral.y / neutral.x, 1, neutral.y / neutral.z]
        return (gains, (0..<3).map { r in (0..<3).map { c in fit[r][c] / gains[c] } })
    }

    /// How a set of constants lands on each frame: block luminance against Apple's, median in stops,
    /// and the 95th percentile of each channel's error.
    static func colourReport(_ label: String, gains: [Double], matrix: [[Double]], frames: [ColourBlocks]) {
        let m = (0..<3).map { r in (0..<3).map { c in matrix[r][c] * gains[c] } }
        for frame in frames {
            var lum: [Double] = [], channels: [[Double]] = [[], [], []]
            for (x, y) in zip(frame.camera, frame.apple) {
                let p = Matrix3.apply(m, x)
                lum.append(log2(max(Self.luminance(p), 1e-6) / max(Self.luminance(y), 1e-6)))
                for c in 0..<3 { channels[c].append(abs(log2(max(p[c], 1e-6) / max(y[c], 1e-6)))) }
            }
            print(String(format: "MEASURE   %@ on %@: %d blocks, luminance median %+.4f stops, |error| p95 R %.3f G %.3f B %.3f stops",
                         label, frame.name, frame.camera.count, Stats.median(lum), Stats.percentile(channels[0], 0.95),
                         Stats.percentile(channels[1], 0.95), Stats.percentile(channels[2], 0.95)))
        }
    }

    static func printColour(_ label: String, _ fit: (gains: [Double], matrix: [[Double]])) {
        print(String(format: "MEASURE %@: D55 gains R %.6f G 1 B %.6f", label, fit.gains[0], fit.gains[2]))
        for (r, row) in fit.matrix.enumerated() {
            print(String(format: "MEASURE   matrix row %d: %.6f %.6f %.6f, sum %.6f", r, row[0], row[1], row[2], row.reduce(0, +)))
        }
    }

    /// Re-derives `InHouseColor` from the decoder's own camera-space output and Apple's decode with
    /// lens correction and noise reduction off, on the CC0 samples and synthetic colour patches, each
    /// set alone and together (the committed constants are the two together), and prints how the
    /// committed constants and each fit land on every frame, the restricted evaluation frames among
    /// them (evaluation only). ARGENT_FIT=milestone1 also fits the milestone-1 frames, to compare.
    @Test(.enabled(if: InHouseDecoderMeasureTests.enabled))
    func colourFit() throws {
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let cc0 = try Self.cc0Frames.map { try Self.colourBlocks($0, decoder: decoder, apple: apple, gpu: gpu) }
        var synthetic: [ColourBlocks] = []
        for seed: UInt64 in [3, 5] {
            let (url, _, _) = try SyntheticRaw.patches("colours", iso: 250, noise: false, seed: seed, patternSeed: seed)
            synthetic.append(try Self.colourBlocks(url, name: "synthetic colours, seed \(seed)", flatOnly: true, decoder: decoder, apple: apple, gpu: gpu))
        }
        let evaluation = try Self.evaluationFrames.dropFirst(2).map { try Self.colourBlocks($0, decoder: decoder, apple: apple, gpu: gpu) }
        print("MEASURE colour fit: CC0 \(cc0.map(\.camera.count)) blocks, synthetic \(synthetic.map(\.camera.count)) blocks")
        let fits: [(String, (gains: [Double], matrix: [[Double]]))] = [
            ("fit on CC0 and synthetic (committed)", Self.fitColour(cc0 + synthetic)),
            ("fit on CC0 alone", Self.fitColour(cc0)),
            ("fit on synthetic alone", Self.fitColour(synthetic)),
        ] + (ProcessInfo.processInfo.environment["ARGENT_FIT"] == "milestone1"
            ? [("fit on the milestone-1 frames (restricted, comparison only)", Self.fitColour(Array(cc0.prefix(2)) + evaluation))] : [])
        for (label, fit) in fits { Self.printColour(label, fit) }
        let committed = (InHouseColor.daylightGains, InHouseColor.cameraToWorking)
        Self.printColour("committed", committed)
        for (label, gains, matrix) in [("committed", committed.0, committed.1), ("fit on CC0 and synthetic", fits[0].1.gains, fits[0].1.matrix)] {
            Self.colourReport(label, gains: gains, matrix: matrix, frames: cc0 + synthetic)
            Self.colourReport(label + ", evaluation only", gains: gains, matrix: matrix, frames: evaluation)
        }
    }

    // MARK: Against Apple

    /// The decoder against Apple's on the lossless L sample and four uncompressed scenes: per-pixel
    /// and per-block luminance in stops, against Apple with lens correction and noise reduction
    /// off (the demosaic and the colour alone) and with the production pins (what a develop gets
    /// today), and Delta E 2000 between the two through Portra 400.
    @Test(.enabled(if: InHouseDecoderMeasureTests.enabled))
    func againstApple() throws {
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let stock = try Stock.load(from: Self.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let only = ProcessInfo.processInfo.environment["ARGENT_SCENE"]
        let scenes = [Self.lossless, Self.corpus("photographyblog-a7iv/sony_a7_iv_22.arw"),
                      Self.corpus("photographyblog-a7iv/sony_a7_iv_05.arw"), Self.corpus("photographyblog-a7iv/sony_a7_iv_13.arw"),
                      Self.corpus("imaging-resource-a7iv-wayback/A7M4hSLI000100NR0.ARW")].filter { only == nil || $0.path.contains(only!) }
        for url in scenes {
            let ours = try Self.inHouse(url, decoder: decoder, gpu: gpu)
            let a = Pixels(ours.texture)
            let oursPrint = Pixels(try renderer.render(ours, settings: DevelopSettings()).image.texture)
            for production in [false, true] {
                let reference = try apple.decode(url, options: Self.appleOptions(lens: production, noiseReduction: production))
                let b = Pixels(reference.texture)
                let pixel = Stats.luminanceStops(a, b, block: 1)
                let block = Stats.luminanceStops(a, b, block: 8)
                let theirPrint = Pixels(try renderer.render(reference, settings: DevelopSettings()).image.texture)
                let dePixel = Stats.deltaE(oursPrint, theirPrint, block: 1)
                let deBlock = Stats.deltaE(oursPrint, theirPrint, block: 8)
                print(String(format: "MEASURE %@ vs Apple %@: luminance per pixel mean %+.4f, |d| mean %.4f, p95 %.4f stops; 8-px blocks mean %+.4f, |d| p95 %.4f; print dE2000 per pixel mean %.2f, median %.2f, p95 %.2f; 8-px blocks mean %.2f, p95 %.2f",
                             url.lastPathComponent, production ? "production" : "lens and NR off", pixel.mean, pixel.absMean, pixel.p95,
                             block.mean, block.p95, dePixel.mean, dePixel.median, dePixel.p95, deBlock.mean, deBlock.p95))
                if !production { print("MEASURE   highlights: " + Stats.highlights(a, b, oursPrint, theirPrint)) }
            }
        }
    }

    // MARK: The tiles

    /// The tile decoder against the spike's C++ decoder (spikes/lossless-decode/tiledec.cpp,
    /// itself bit-exact with LibRaw on this file): ARGENT_SPIKE_MOSAIC names the mosaic it wrote
    /// with `--out`, 7168 by 5120 little-endian samples.
    @Test(.enabled(if: InHouseDecoderMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_SPIKE_MOSAIC"] != nil))
    func tilesMatchTheSpike() throws {
        let spike = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARGENT_SPIKE_MOSAIC"]!))
        let source = try MeasureMosaic.load(Self.lossless, device: MTLCreateSystemDefaultDevice()!)
        let count = source.layout.pitch * source.buffer.length / 2 / source.layout.pitch
        #expect(spike.count == count * 2)
        let ours = source.buffer.contents().bindMemory(to: UInt16.self, capacity: count)
        var mismatches = 0
        spike.withUnsafeBytes { theirs in
            let t = theirs.bindMemory(to: UInt16.self)
            for i in 0..<min(count, t.count) where ours[i] != UInt16(littleEndian: t[i]) { mismatches += 1 }
        }
        print("MEASURE tiles against the spike's decoder: \(count) samples, \(mismatches) differ")
        #expect(mismatches == 0)
    }

    // MARK: Speed and memory

    /// Decode-only wall time on the lossless L sample: the in-house decoder by stage, its tiles on
    /// one thread, and Apple's decoder as a develop uses it (a context per decode, 1024-pixel
    /// tiles) and whole through one shared context; one decode at a time, then two at once on two
    /// threads. ARGENT_REPEAT sets the decodes a configuration (default 10). Other agents may be
    /// using the machine, so read the medians and say so.
    @Test(.enabled(if: InHouseDecoderMeasureTests.enabled))
    func speed() throws {
        let repeats = Int(ProcessInfo.processInfo.environment["ARGENT_REPEAT"] ?? "") ?? 10
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let shared = AppleRawDecoder(gpu: gpu)
        let develop = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        var developOptions = DecodeOptions()
        developOptions.tileSize = RollDeveloper.decodeTile
        let url = Self.lossless
        _ = try decoder.decode(url, options: DecodeOptions())
        _ = try shared.decode(url, options: DecodeOptions())
        _ = try develop.decode(url, options: developOptions)
        print("MEASURE load average at start: \(Self.loadAverage())")

        _ = try decoder.decode(url, options: Self.inHouseOff)
        var lensOff = DecodeOptions()
        lensOff.lensCorrection = false
        for (name, options) in [("in-house decode", DecodeOptions()), ("in-house decode, lens correction off", lensOff),
                                ("in-house decode, noise reduction off", Self.inHouseOff)] {
            var total: [Double] = [], read: [Double] = [], tiles: [Double] = [], noise: [Double] = [], gpuTimes: [Double] = []
            for _ in 0..<repeats {
                let t = try decoder.decodeTimed(url, options: options).timings
                total.append(t.total * 1000); read.append(t.read * 1000); tiles.append(t.tiles * 1000)
                noise.append(t.noise * 1000); gpuTimes.append(t.gpu * 1000)
            }
            print("MEASURE \(name), one at a time: \(FrameViewMeasureTests.summary(total))")
            print("MEASURE   read and map: \(FrameViewMeasureTests.summary(read))")
            print("MEASURE   tiles on \(ProcessInfo.processInfo.activeProcessorCount) cores: \(FrameViewMeasureTests.summary(tiles))")
            print("MEASURE   noise estimate: \(FrameViewMeasureTests.summary(noise))")
            print("MEASURE   GPU demosaic\(options.colorNoiseReduction > 0 ? " and noise reduction" : "")\(options.lensCorrection ? " and lens correction" : ""): \(FrameViewMeasureTests.summary(gpuTimes))")
        }

        print("MEASURE   tiles on one thread: \(FrameViewMeasureTests.summary(try Self.tilesOnOneThread(repeats: max(3, repeats / 3))))")

        // The GPU half in the extreme tier, where impulses are pulled in: Imaging Resource's ISO
        // 102400 still life, an uncompressed full-frame mosaic.
        let extreme = try MeasureMosaic.load(Self.corpus("imaging-resource-a7iv-wayback/A7M4hSLI102400NR0.ARW"), device: gpu.device)
        let iso = extreme.iso.map(Float.init)
        for (name, options) in [("with noise reduction", DecodeOptions()), ("without", Self.inHouseOff)] {
            var times: [Double] = []
            for _ in 0...repeats {
                let (_, stages) = try decoder.render(extreme.buffer, layout: extreme.layout, orientation: extreme.orientation,
                                                     gainStops: ExposureAnchor.gainStops(iso: iso), iso: iso, options: options,
                                                     lens: extreme.lens)
                times.append(stages.gpu * 1000)
            }
            print("MEASURE GPU half at ISO \(extreme.iso ?? 0), \(name): \(FrameViewMeasureTests.summary(Array(times.dropFirst())))")
        }

        for (name, apple, options) in [("Apple, develop setup", develop, developOptions), ("Apple, shared context, whole", shared, DecodeOptions())] {
            var times: [Double] = []
            for _ in 0..<repeats {
                let clock = ContinuousClock(), start = clock.now
                _ = try apple.decode(url, options: options)
                times.append(FrameViewMeasureTests.ms(clock.now - start))
            }
            print("MEASURE \(name), one at a time: \(FrameViewMeasureTests.summary(times))")
        }

        // Two at once, each on its own thread, as the develop's two lanes run.
        func twoAtOnce(_ name: String, _ decode: @escaping @Sendable () throws -> Void) {
            let times = LockedTimes()
            let clock = ContinuousClock(), start = clock.now
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                for _ in 0..<repeats {
                    let begin = clock.now
                    try? decode()
                    times.append(FrameViewMeasureTests.ms(clock.now - begin))
                }
            }
            let seconds = FrameViewMeasureTests.ms(clock.now - start) / 1000
            print(String(format: "MEASURE %@, two at once: %.2f frames a second, each %@", name,
                         Double(2 * repeats) / seconds, FrameViewMeasureTests.summary(times.values)))
        }
        let box = UncheckedBox((decoder, develop, developOptions, url))
        twoAtOnce("in-house") { _ = try box.value.0.decode(box.value.3, options: DecodeOptions()) }
        twoAtOnce("Apple, develop setup") { _ = try box.value.1.decode(box.value.3, options: box.value.2) }
        print("MEASURE load average at end: \(Self.loadAverage())")
    }

    /// The tiles one after another on one thread, the single-core cost, for comparing with the
    /// spike's C++ decoder (`tiledec --threads 1`) under the same load.
    @Test(.enabled(if: InHouseDecoderMeasureTests.enabled))
    func tilesOneThread() throws {
        print("MEASURE load average: \(Self.loadAverage())")
        print("MEASURE tiles on one thread: \(FrameViewMeasureTests.summary(try Self.tilesOnOneThread(repeats: 5)))")
    }

    static func tilesOnOneThread(repeats: Int) throws -> [Double] {
        let raw = try SonyLosslessRaw.read(from: lossless)
        let file = try Data(contentsOf: lossless, options: .alwaysMapped)
        var mosaic = [UInt16](repeating: 0, count: raw.width * raw.height)
        var serial: [Double] = []
        for _ in 0..<repeats {
            let clock = ContinuousClock(), start = clock.now
            try file.withUnsafeBytes { bytes in
                try mosaic.withUnsafeMutableBufferPointer { out in
                    for index in raw.tileOffsets.indices { try raw.decodeTile(index, bytes, into: out.baseAddress!) }
                }
            }
            serial.append(FrameViewMeasureTests.ms(clock.now - start))
        }
        return serial
    }

    /// The process's peak footprint while it decodes the lossless L sample three times, one
    /// decoder a process, chosen by ARGENT_DECODE_MEMORY: inhouse, inhouse-off (noise reduction
    /// off), inhouse-lens-off (lens correction off), apple-develop (a context per decode and the develop's tiles, as a develop runs it),
    /// raw9-develop (RAW 9 the same way), raw9 (RAW 9 whole, shared context) or apple (whole, shared context). Run
    /// each in its own `swift test` so the kernel's lifetime peak is this decoder's.
    @Test(.enabled(if: InHouseDecoderMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_DECODE_MEMORY"] != nil))
    func peakMemory() throws {
        let which = ProcessInfo.processInfo.environment["ARGENT_DECODE_MEMORY"]!
        let gpu = try GPU(maxIdlePoolBytes: 300 << 20)
        var options = DecodeOptions()
        let decoder: RawDecoder
        switch which {
        case "inhouse": decoder = try InHouseDecoder(gpu: gpu)
        case "inhouse-off":
            decoder = try InHouseDecoder(gpu: gpu)
            options = Self.inHouseOff
        case "inhouse-lens-off":
            decoder = try InHouseDecoder(gpu: gpu)
            options.lensCorrection = false
        case "apple-develop":
            decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
            options.tileSize = RollDeveloper.decodeTile
        case "raw9-develop":
            decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
            options.tileSize = RollDeveloper.learnedDecodeTile
            options.appleDecoder = .learned
        case "raw9":
            decoder = AppleRawDecoder(gpu: gpu)
            options.appleDecoder = .learned
        default: decoder = AppleRawDecoder(gpu: gpu)
        }
        let start = Self.footprint()
        let sampler = FootprintSampler()
        sampler.start()
        var after: [Int] = []
        for _ in 0..<3 {
            autoreleasepool {
                let frame = try? decoder.decode(Self.lossless, options: options)
                #expect(frame != nil)
            }
            after.append(Self.footprint().current)
        }
        let sampled = sampler.stop()
        let end = Self.footprint()
        func mb(_ bytes: Int) -> String { String(format: "%.0f MB", Double(bytes) / 1e6) }
        print("MEASURE \(which): footprint at start \(mb(start.current)) (lifetime peak \(mb(start.peak))); sampled peak \(mb(sampled)), "
              + "\(mb(sampled - start.current)) above the start; kernel's lifetime peak \(mb(end.peak)), \(mb(end.peak - start.current)) above; "
              + "after each decode \(after.map(mb).joined(separator: ", ")) (pools hold the last frame and mosaic)")
    }

    // MARK: Noise, sharpness and the lens

    /// What the missing noise reduction and the different demosaic do: noise in Imaging
    /// Resource's flat gray card up the ISO ladder and the 10 to 90 percent rise of two
    /// ColorChecker edges at ISO 100 (the patches `AutoMeasureTests/captureSharpening` uses), in
    /// scene-linear luminance, against Apple's production decode and Apple's with noise reduction
    /// and lens correction off. The still lifes are uncompressed, so the decoder's GPU half runs
    /// on their mosaics.
    @Test(.enabled(if: InHouseDecoderMeasureTests.enabled))
    func noiseAndSharpness() throws {
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let whiteEdge = 3270..<3330, grayEdge = 3595..<3650, edgeRows = 3985..<4040
        let cardColumns = 4600..<4900, cardRows = 60..<280
        func up(_ r: Range<Int>, _ height: Int) -> Range<Int> { (height - r.upperBound)..<(height - r.lowerBound) }
        for iso in ["000100", "000400", "001600", "006400", "025600", "102400"] {
            let url = Self.corpus("imaging-resource-a7iv-wayback/A7M4hSLI\(iso)NR0.ARW")
            var line = "MEASURE ISO \(Int(iso)!) card noise, luminance sd over mean:"
            var edges: [String] = []
            let ours = try Self.inHouse(url, decoder: decoder, gpu: gpu)
            let oursOff = try Self.inHouse(url, decoder: decoder, gpu: gpu, options: Self.inHouseOff)
            let off = try apple.decode(url, options: Self.appleOptions(lens: false, noiseReduction: false))
            let production = try apple.decode(url, options: DecodeOptions())
            for (name, frame) in [("in-house NR off", oursOff), ("in-house", ours), ("Apple NR and lens off", off), ("Apple production", production)] {
                let l = AutoMeasureTests.lightness(ExposureAnalyzer.pixels(of: frame.texture), linear: true)
                let rows = up(cardRows, frame.height)
                var sum: Float = 0
                for y in rows { for x in cardColumns { sum += l[y * frame.width + x] } }
                let mean = sum / Float(rows.count * cardColumns.count)
                let noise = AutoMeasureTests.flatNoise(l, width: frame.width, columns: cardColumns, rows: rows)
                line += String(format: " %@ %.2f%% (mean %.4f);", name, noise / mean * 100, mean)
                if iso == "000100" {
                    let er = up(edgeRows, frame.height)
                    let white = AutoMeasureTests.edge(l, width: frame.width, columns: whiteEdge, rows: er, reach: 8)
                    let gray = AutoMeasureTests.edge(l, width: frame.width, columns: grayEdge, rows: er, reach: 8)
                    edges.append(String(format: "%@ white %.2f px (overshoot %.1f%%, sigma %.2f), gray %.2f px (overshoot %.1f%%)", name,
                                        white.rise, white.overshoot * 100, white.sigma, gray.rise, gray.overshoot * 100))
                }
            }
            print(line)
            if !edges.isEmpty { print("MEASURE ISO 100 edge rise 10-90%: " + edges.joined(separator: "; ")) }
        }

        // The lossless L sample's flattest 128-pixel patch, chosen on Apple's decode with noise
        // reduction and lens correction off among patches between 0.05 and 1 in luminance.
        let ours = try decoder.decode(Self.lossless, options: DecodeOptions())
        let oursOff = try decoder.decode(Self.lossless, options: Self.inHouseOff)
        let off = try apple.decode(Self.lossless, options: Self.appleOptions(lens: false, noiseReduction: false))
        let production = try apple.decode(Self.lossless, options: DecodeOptions())
        let side = 128
        let reference = AutoMeasureTests.lightness(ExposureAnalyzer.pixels(of: off.texture), linear: true)
        var flattest = (noise: Float.infinity, x: 0, y: 0)
        for y in stride(from: side, to: off.height - 2 * side, by: side / 2) {
            for x in stride(from: side, to: off.width - 2 * side, by: side / 2) {
                var sum: Float = 0
                for yy in y..<(y + side) { for xx in x..<(x + side) { sum += reference[yy * off.width + xx] } }
                let mean = sum / Float(side * side)
                guard mean > 0.05, mean < 1 else { continue }
                let noise = AutoMeasureTests.flatNoise(reference, width: off.width, columns: x..<(x + side), rows: y..<(y + side)) / mean
                if noise < flattest.noise { flattest = (noise, x, y) }
            }
        }
        var line = String(format: "MEASURE lossless L sample, flattest patch at (%d, %d) from the bottom left, luminance sd over mean:",
                          flattest.x, flattest.y)
        for (name, frame) in [("in-house NR off", oursOff), ("in-house", ours), ("Apple NR and lens off", off), ("Apple production", production)] {
            let l = AutoMeasureTests.lightness(ExposureAnalyzer.pixels(of: frame.texture), linear: true)
            let columns = flattest.x..<(flattest.x + side), rows = flattest.y..<(flattest.y + side)
            var sum: Float = 0
            for y in rows { for x in columns { sum += l[y * frame.width + x] } }
            let mean = sum / Float(side * side)
            line += String(format: " %@ %.2f%% (mean %.4f);", name, AutoMeasureTests.flatNoise(l, width: frame.width, columns: columns, rows: rows) / mean * 100, mean)
        }
        print(line)
    }

    /// Apple's production decode against the in-house one, with the in-house decoder's own lens
    /// correction since argent-4 (milestone 1 measured it without): the brightness ratio by distance
    /// from the centre (vignetting), and where patches near the corners and edges moved (distortion
    /// and lateral chromatic aberration), on the lossless L sample, the still life and a Tamron frame,
    /// or the files in ARGENT_FILES. `LensMeasureTests/againstApple` measures the whole frame on a grid.
    @Test(.enabled(if: InHouseDecoderMeasureTests.enabled))
    func lens() throws {
        let gpu = try GPU()
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let files = ProvenanceMeasureTests.files()
        for url in files.isEmpty ? [Self.lossless, Self.corpus("imaging-resource-a7iv-wayback/A7M4hSLI000100NR0.ARW"),
                                    Self.corpus("photographyblog-a7iv/sony_a7_iv_13.arw")] : files {
            let ours = Pixels(try Self.inHouse(url, decoder: decoder, gpu: gpu).texture)
            let production = Pixels(try apple.decode(url, options: DecodeOptions()).texture)
            let lensOff = Pixels(try apple.decode(url, options: Self.appleOptions(lens: false, noiseReduction: true)).texture)
            // Vignetting: median block ratio in rings of the normalized radius, half the diagonal at 1.
            let block = 32
            let mo = ours.blockMeans(block, clipAbove: 3), mp = production.blockMeans(block, clipAbove: 3), ml = lensOff.blockMeans(block, clipAbove: 3)
            let across = ours.width / block, down = ours.height / block
            var rings = [[Double]](repeating: [], count: 10), ringsOff = [[Double]](repeating: [], count: 10)
            for by in 0..<down {
                for bx in 0..<across {
                    let i = by * across + bx
                    guard let o = mo[i], let p = mp[i], let l = ml[i] else { continue }
                    let lo = Self.luminance(o), lp = Self.luminance(p), ll = Self.luminance(l)
                    guard lo > 0.02, lp > 0.02 else { continue }
                    let dx = (Double(bx) + 0.5) * Double(block) - Double(ours.width) / 2
                    let dy = (Double(by) + 0.5) * Double(block) - Double(ours.height) / 2
                    let r = (dx * dx + dy * dy).squareRoot() / (Double(ours.width * ours.width + ours.height * ours.height).squareRoot() / 2)
                    let ring = min(9, Int(r * 10))
                    rings[ring].append(log2(lp / lo))
                    if ll > 0.02 { ringsOff[ring].append(log2(ll / lo)) }
                }
            }
            let ringText = (0..<10).map { String(format: "%.1f %+.3f", Double($0) / 10, Stats.median(rings[$0])) }.joined(separator: ", ")
            let offText = (0..<10).map { String(format: "%+.3f", Stats.median(ringsOff[$0])) }.joined(separator: ", ")
            print("MEASURE \(url.lastPathComponent) Apple production over in-house, stops by radius: \(ringText)")
            print("MEASURE \(url.lastPathComponent) Apple lens off over in-house, same rings: \(offText)")
            // Distortion and lateral chromatic aberration: where Apple's production decode put each
            // patch, per channel, against the in-house decode, in pixels down and across the picture.
            // A patch whose best correlation is under 0.3 has too little detail to register.
            let side = 256
            let spots: [(String, Double, Double)] = [
                ("top left", 0.12, 0.12), ("top", 0.5, 0.12), ("top right", 0.88, 0.12), ("left", 0.08, 0.5),
                ("centre", 0.5, 0.5), ("right", 0.92, 0.5), ("bottom left", 0.12, 0.88), ("bottom", 0.5, 0.88),
                ("bottom right", 0.88, 0.88),
            ]
            var shifts: [String] = []
            for (name, fx, fy) in spots {
                let cx = Int(fx * Double(ours.width)), cy = ours.height - 1 - Int(fy * Double(ours.height))
                let g = Registration.shift(production, ours, centreX: cx, centreY: cy, side: side, channel: 1, reach: 64)
                guard g.correlation >= 0.3 else {
                    shifts.append(String(format: "%@ too flat (r %.2f)", name, g.correlation))
                    continue
                }
                let r = Registration.shift(production, ours, centreX: cx, centreY: cy, side: side, channel: 0, reach: 64)
                let b = Registration.shift(production, ours, centreX: cx, centreY: cy, side: side, channel: 2, reach: 64)
                // Rows run bottom up; y is reported down the picture.
                shifts.append(String(format: "%@ G (%+.2f, %+.2f) r %.2f, R-G (%+.2f, %+.2f) r %.2f, B-G (%+.2f, %+.2f) r %.2f", name,
                                     g.x, -g.y, g.correlation, r.x - g.x, -(r.y - g.y), r.correlation, b.x - g.x, -(b.y - g.y), b.correlation))
            }
            print("MEASURE \(url.lastPathComponent) Apple production patch moved by, px: " + shifts.joined(separator: "; "))
        }
    }

    // MARK: Helpers

    static func appleOptions(lens: Bool, noiseReduction: Bool) -> DecodeOptions {
        var options = DecodeOptions()
        options.lensCorrection = lens
        if !noiseReduction {
            options.luminanceNoiseReduction = 0
            options.colorNoiseReduction = 0
        }
        return options
    }

    /// The in-house decode of `url` with `options`: the decoder itself for the lossless file, its
    /// GPU half on the mosaic for an uncompressed one.
    static func inHouse(_ url: URL, decoder: InHouseDecoder, gpu: GPU, options: DecodeOptions = DecodeOptions(),
                        tuning: InHouseNoiseReduction.Tuning? = nil) throws -> LinearFrame {
        if InHouseDecoder.supports(url), tuning == nil { return try decoder.decode(url, options: options) }
        let source = try MeasureMosaic.load(url, device: gpu.device)
        let iso = source.iso.map(Float.init)
        return try decoder.render(source.buffer, layout: source.layout, orientation: source.orientation,
                                  gainStops: ExposureAnchor.gainStops(iso: iso), iso: iso, options: options, lens: source.lens,
                                  tuning: tuning).0
    }

    /// In-house decode options with noise reduction off.
    static var inHouseOff: DecodeOptions {
        var options = DecodeOptions()
        options.luminanceNoiseReduction = 0
        options.colorNoiseReduction = 0
        return options
    }

    static func luminance(_ v: SIMD3<Double>) -> Double { 0.2627 * v.x + 0.678 * v.y + 0.0593 * v.z }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? String(format: "%.2f %.2f %.2f", loads[0], loads[1], loads[2]) : "unknown"
    }

    /// The process's physical footprint now and the kernel's record of its lifetime peak.
    static func footprint() -> (current: Int, peak: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? (Int(info.phys_footprint), Int(info.ledger_phys_footprint_peak)) : (0, 0)
    }
}

/// Samples the footprint every 2 ms on a thread of its own.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    private var running = true
    private var thread: Thread?

    func start() {
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let now = InHouseDecoderMeasureTests.footprint().current
                lock.withLock { peak = max(peak, now) }
                usleep(2000)
            }
        }
        self.thread = thread
        thread.start()
    }

    func stop() -> Int {
        lock.withLock { running = false }
        usleep(5000)
        return lock.withLock { peak }
    }
}

final class LockedTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    func append(_ value: Double) { lock.withLock { times.append(value) } }
    var values: [Double] { lock.withLock { times } }
}

/// Carries non-Sendable decoders into the measurement's worker threads; each is safe to share.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Where a patch of one frame sits in another: the integer shift with the best normalized
/// correlation of their high-passed channel, refined to a fraction of a pixel by a parabola.
enum Registration {
    static func shift(_ moved: Pixels, _ reference: Pixels, centreX: Int, centreY: Int, side: Int, channel: Int,
                      reach: Int) -> (x: Double, y: Double, correlation: Double) {
        func patch(_ p: Pixels, _ x0: Int, _ y0: Int) -> [Double] {
            var v = [Double](repeating: 0, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    let px = min(max(x0 + x, 1), p.width - 2), py = min(max(y0 + y, 1), p.height - 2)
                    let i = (py * p.width + px) * 4 + channel
                    let c = Double(p.values[i])
                    let n = Double(p.values[i - 4]) + Double(p.values[i + 4]) + Double(p.values[i - p.width * 4]) + Double(p.values[i + p.width * 4])
                    v[y * side + x] = c - n / 4
                }
            }
            let mean = v.reduce(0, +) / Double(v.count)
            let norm = v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +).squareRoot()
            return v.map { ($0 - mean) / max(norm, 1e-12) }
        }
        let x0 = centreX - side / 2, y0 = centreY - side / 2
        let ref = patch(reference, x0, y0)
        var scores = [[Double]](repeating: [Double](repeating: -2, count: 2 * reach + 1), count: 2 * reach + 1)
        func score(_ dx: Int, _ dy: Int) -> Double {
            if scores[dy + reach][dx + reach] > -2 { return scores[dy + reach][dx + reach] }
            let m = patch(moved, x0 + dx, y0 + dy)
            var s = 0.0
            for i in 0..<ref.count { s += ref[i] * m[i] }
            scores[dy + reach][dx + reach] = s
            return s
        }
        // Coarse on a grid of 4, then every pixel near the best.
        var best = (dx: 0, dy: 0, s: -2.0)
        for dy in stride(from: -reach, through: reach, by: 4) {
            for dx in stride(from: -reach, through: reach, by: 4) {
                let s = score(dx, dy)
                if s > best.s { best = (dx, dy, s) }
            }
        }
        let coarse = best
        for dy in max(-reach, coarse.dy - 4)...min(reach, coarse.dy + 4) {
            for dx in max(-reach, coarse.dx - 4)...min(reach, coarse.dx + 4) {
                let s = score(dx, dy)
                if s > best.s { best = (dx, dy, s) }
            }
        }
        func vertex(_ a: Double, _ b: Double, _ c: Double) -> Double {
            let d = a - 2 * b + c
            return abs(d) < 1e-12 ? 0 : 0.5 * (a - c) / d
        }
        var fx = Double(best.dx), fy = Double(best.dy)
        if abs(best.dx) < reach { fx += vertex(score(best.dx - 1, best.dy), best.s, score(best.dx + 1, best.dy)) }
        if abs(best.dy) < reach { fy += vertex(score(best.dx, best.dy - 1), best.s, score(best.dx, best.dy + 1)) }
        return (fx, fy, best.s)
    }
}

/// A frame's mosaic in a buffer: the lossless L tiles decoded, or an uncompressed ARW's strip, read as
/// the decoder reads them (`SonyLosslessRaw`, `SonyUncompressedRaw`), whatever the camera or crop.
struct MeasureMosaic {
    var buffer: MTLBuffer
    var layout: BayerMosaicLayout
    var orientation: Int
    var iso: Int?
    /// The file's lens corrections, as the decoder reads them.
    var lens: SonyLensCorrection? = nil
    var encoding: ARWLayout.Encoding = .losslessBayer

    static func load(_ url: URL, device: MTLDevice) throws -> MeasureMosaic {
        let info = try ARWFrameInfo.read(from: url)
        let orientation = Int(info.orientation.rawValue)
        let file = try Data(contentsOf: url, options: .alwaysMapped)
        if let raw = try? SonyLosslessRaw.read(from: url) {
            let buffer = device.makeBuffer(length: raw.width * raw.height * 2, options: .storageModeShared)!
            try file.withUnsafeBytes { try raw.decodeTiles($0, into: buffer.contents().bindMemory(to: UInt16.self, capacity: raw.width * raw.height)) }
            return MeasureMosaic(buffer: buffer, layout: raw.mosaicLayout, orientation: orientation, iso: info.iso, lens: raw.lens)
        }
        let raw = try SonyUncompressedRaw.read(from: url)
        let buffer = device.makeBuffer(length: raw.byteCount, options: .storageModeShared)!
        try file.withUnsafeBytes { try raw.unpack($0, into: buffer.contents()) }
        return MeasureMosaic(buffer: buffer, layout: raw.mosaicLayout, orientation: orientation, iso: info.iso, lens: raw.lens,
                             encoding: .uncompressed)
    }
}

/// A frame's RGBA half floats on the CPU, rows bottom up as the textures hold them.
struct Pixels {
    let width: Int
    let height: Int
    let values: [Float16]

    init(_ texture: MTLTexture) {
        width = texture.width
        height = texture.height
        values = ExposureAnalyzer.pixels(of: texture)
    }

    @inline(__always) func rgb(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let i = (y * width + x) * 4
        return SIMD3(Double(values[i]), Double(values[i + 1]), Double(values[i + 2]))
    }

    /// Mean RGB of each `size`-pixel block, row by row; `nil` for a block with any channel above
    /// `clipAbove`.
    func blockMeans(_ size: Int, clipAbove: Double) -> [SIMD3<Double>?] {
        let across = width / size, down = height / size
        var out = [SIMD3<Double>?](repeating: nil, count: across * down)
        values.withUnsafeBufferPointer { v in
            for by in 0..<down {
                for bx in 0..<across {
                    var sum = SIMD3<Double>(0, 0, 0)
                    var clipped = false
                    for y in (by * size)..<(by * size + size) {
                        var i = (y * width + bx * size) * 4
                        for _ in 0..<size {
                            let p = SIMD3(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]))
                            if p.max() > clipAbove { clipped = true }
                            sum += p
                            i += 4
                        }
                    }
                    if !clipped { out[by * across + bx] = sum / Double(size * size) }
                }
            }
        }
        return out
    }
}

enum Stats {
    static func median(_ v: [Double]) -> Double { percentile(v, 0.5) }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        return s[min(s.count - 1, Int(p * Double(s.count - 1) + 0.5))]
    }

    struct Summary {
        var mean: Double
        var absMean: Double
        var median: Double
        var p95: Double
    }

    static func summary(_ v: [Double]) -> Summary {
        let absolute = v.map(abs)
        return Summary(mean: v.reduce(0, +) / Double(max(v.count, 1)), absMean: absolute.reduce(0, +) / Double(max(absolute.count, 1)),
                       median: median(v), p95: percentile(absolute, 0.95))
    }

    /// log2 of `a`'s luminance over `b`'s, per `block`-pixel block, where both are above 0.01
    /// (a stop and a half under the floor of the Negative LUT's useful range is noise either way).
    static func luminanceStops(_ a: Pixels, _ b: Pixels, block: Int) -> Summary {
        var out: [Double] = []
        let ma = a.blockMeans(block, clipAbove: .infinity), mb = b.blockMeans(block, clipAbove: .infinity)
        out.reserveCapacity(ma.count)
        for i in ma.indices {
            guard let p = ma[i], let q = mb[i] else { continue }
            let la = InHouseDecoderMeasureTests.luminance(p), lb = InHouseDecoderMeasureTests.luminance(q)
            if la > 0.01, lb > 0.01 { out.append(log2(la / lb)) }
        }
        return summary(out)
    }

    /// The decoders in the highlights, on 8-pixel blocks by Apple's luminance: from green's clip
    /// in the decode (2.24 at the anchor's gain) to Apple's ceiling (5.6), and the two stops under
    /// green's clip; luminance in stops, chroma as the gap in Rec. 2020 chromaticity, and the prints.
    static func highlights(_ a: Pixels, _ b: Pixels, _ printA: Pixels, _ printB: Pixels) -> String {
        let ma = a.blockMeans(8, clipAbove: .infinity), mb = b.blockMeans(8, clipAbove: .infinity)
        let pa = printA.blockMeans(8, clipAbove: .infinity), pb = printB.blockMeans(8, clipAbove: .infinity)
        var text: [String] = []
        for (name, low, high) in [("0.56 to 2.24", 0.56, 2.24), ("2.24 to 6", 2.24, 6.0)] {
            var stops: [Double] = [], chroma: [Double] = [], de: [Double] = []
            for i in ma.indices {
                guard let p = ma[i], let q = mb[i], let r = pa[i], let t = pb[i] else { continue }
                let lp = InHouseDecoderMeasureTests.luminance(p), lq = InHouseDecoderMeasureTests.luminance(q)
                guard lq >= low, lq < high, lp > 0 else { continue }
                stops.append(log2(lp / lq))
                let sp = p.x + p.y + p.z, sq = q.x + q.y + q.z
                chroma.append(((p.x / sp - q.x / sq) * (p.x / sp - q.x / sq) + (p.y / sp - q.y / sq) * (p.y / sp - q.y / sq)).squareRoot())
                de.append(Colour.deltaE2000(Colour.lab(r), Colour.lab(t)))
            }
            let l = summary(stops), c = summary(chroma), d = summary(de)
            text.append(String(format: "Apple luminance %@: %d blocks, luminance mean %+.3f p95 %.3f stops, chromaticity gap median %.4f p95 %.4f, print dE2000 mean %.2f p95 %.2f",
                               name, stops.count, l.mean, l.p95, c.median, c.p95, d.mean, d.p95))
        }
        return text.joined(separator: "; ")
    }

    /// CIEDE2000 between two prints in display-linear Rec. 2020 with white at 1, per `block`.
    static func deltaE(_ a: Pixels, _ b: Pixels, block: Int) -> Summary {
        let ma = a.blockMeans(block, clipAbove: .infinity), mb = b.blockMeans(block, clipAbove: .infinity)
        var out: [Double] = []
        out.reserveCapacity(ma.count)
        for i in ma.indices {
            guard let p = ma[i], let q = mb[i] else { continue }
            out.append(Colour.deltaE2000(Colour.lab(p), Colour.lab(q)))
        }
        return summary(out)
    }
}

enum Colour {
    /// Linear Rec. 2020 to CIELAB against D65, the primaries' white.
    static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let x = 0.636958 * rgb.x + 0.144617 * rgb.y + 0.168881 * rgb.z
        let y = 0.262700 * rgb.x + 0.677998 * rgb.y + 0.059302 * rgb.z
        let z = 0.028073 * rgb.y + 1.060985 * rgb.z
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000 (Sharma, Wu and Dalal 2005).
    static func deltaE2000(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> Double {
        let (l1, a1, b1, l2, a2, b2) = (p.x, p.y, p.z, q.x, q.y, q.z)
        let c1 = (a1 * a1 + b1 * b1).squareRoot(), c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cMean = (c1 + c2) / 2
        let c7 = pow(cMean, 7)
        let g = 0.5 * (1 - (c7 / (c7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hue(_ a: Double, _ b: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let h = atan2(b, a) * 180 / .pi
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(a1p, b1), h2 = hue(a2p, b2)
        let dL = l2 - l1, dC = c2p - c1p
        var dh = 0.0
        if c1p * c2p != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * (c1p * c2p).squareRoot() * sin(dh * .pi / 360)
        let lMean = (l1 + l2) / 2, cpMean = (c1p + c2p) / 2
        var hMean = h1 + h2
        if c1p * c2p != 0 {
            if abs(h1 - h2) <= 180 { hMean = (h1 + h2) / 2 } else if h1 + h2 < 360 { hMean = (h1 + h2 + 360) / 2 } else { hMean = (h1 + h2 - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hMean - 30) * .pi / 180) + 0.24 * cos(2 * hMean * .pi / 180)
            + 0.32 * cos((3 * hMean + 6) * .pi / 180) - 0.20 * cos((4 * hMean - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hMean - 275) / 25, 2))
        let cp7 = pow(cpMean, 7)
        let rc = 2 * (cp7 / (cp7 + pow(25, 7))).squareRoot()
        let l50 = (lMean - 50) * (lMean - 50)
        let sl = 1 + 0.015 * l50 / (20 + l50).squareRoot()
        let sc = 1 + 0.045 * cpMean, sh = 1 + 0.015 * cpMean * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        let x = dL / sl, y = dC / sc, z = dH / sh
        return (x * x + y * y + z * z + rt * y * z).squareRoot()
    }
}

enum Matrix3 {
    static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    static func transpose(_ m: [[Double]]) -> [[Double]] { (0..<3).map { i in (0..<3).map { j in m[j][i] } } }

    static func apply(_ m: [[Double]], _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z, m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
              m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z)
    }

    static func invert(_ m: [[Double]]) -> [[Double]] {
        let (a, b, c) = (m[0][0], m[0][1], m[0][2]), (d, e, f) = (m[1][0], m[1][1], m[1][2]), (g, h, i) = (m[2][0], m[2][1], m[2][2])
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
                [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
                [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
    }
}
