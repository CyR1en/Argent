import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Measurements behind docs/research/noise-and-hardware.md: whether the a7 IV noise model that the
/// synthetic frames are made with (`SyntheticRaw`, `BodyNoise`) gives the noise of real frames, and
/// how Apple's noise reduction responds to a frame's noise against its Exif ISO. Everything here
/// runs on the CC0 samples and synthetic copies of them. Gated like the other measurement suites:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --skip-build --filter NoiseModelMeasureTests/<test>
@Suite(.serialized, .syntheticRaws) struct NoiseModelMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }
    typealias M = InHouseDecoderMeasureTests
    typealias N = InHouseNoiseMeasureTests

    /// The model as it stood before 2026-10-07's research: the shot term `SensorNoise` read from the
    /// CC0 sample at ISO 250, 0.355 at ISO 100, with the same published read noise.
    static var before: BodyNoise {
        var model = SyntheticRaw.noise
        model.shotAtISO100 = 0.355
        return model
    }

    /// The conversion gain of PhotonsToPhotos' unity-gain ISO, 411.3, at ISO 100: 0.2431.
    static var published: BodyNoise {
        var model = SyntheticRaw.noise
        model.shotAtISO100 = 100 / model.unityGainISO
        return model
    }

    static func models() -> [(name: String, model: BodyNoise)] {
        let wanted = Set((ProcessInfo.processInfo.environment["ARGENT_MODELS"] ?? "before,published").split(separator: ",").map(String.init))
        return [("before", before), ("published", published)].filter { wanted.contains($0.name) }
    }

    /// The luminance and colour strengths at which the in-house decode's flat-patch L* and chroma
    /// noise equal `target`, by bisection in the strength's logarithm, as `ProvenanceMeasureTests
    /// /noiseStrengths` matches them.
    static func match(_ source: MeasureMosaic, patches: [N.Patch], target: (lightness: Double, chroma: Double),
                      decoder: InHouseDecoder, ladder: N.Ladder = N.Ladder(name: "model", frames: [], reference: SyntheticRaw.base, stillLife: false))
        throws -> (luminance: Float, colour: Float) {
        let iso = source.iso.map(Float.init)
        let amount = NoiseReduction.luminanceAmount(iso: iso)
        let impulse = amount == NoiseReduction.extremeISOLuminance ? InHouseNoiseReduction.extremeImpulse : 0
        func measure(_ luminance: Float, _ colour: Float) throws -> (lightness: Double, chroma: Double) {
            var t = InHouseNoiseReduction.Tuning(luminanceAmount: -1, colourAmount: -1, luminance: luminance, colour: colour)
            t.impulse = impulse
            return N.noise(Pixels(try N.render(source, ladder: ladder, decoder: decoder, tuning: t).texture), patches)
        }
        func bisect(_ keyPath: KeyPath<(lightness: Double, chroma: Double), Double>, fixed: Float, luminance: Bool) throws -> Float {
            var lo: Float = 0.01, hi: Float = 8
            let goal = target[keyPath: keyPath]
            if try (luminance ? measure(lo, fixed) : measure(fixed, lo))[keyPath: keyPath] <= goal { return 0 }
            for _ in 0..<12 {
                let mid = (lo * hi).squareRoot()
                if try (luminance ? measure(mid, fixed) : measure(fixed, mid))[keyPath: keyPath] > goal { lo = mid } else { hi = mid }
            }
            return (lo * hi).squareRoot()
        }
        let committed = InHouseNoiseReduction.tuning(luminance: amount, colour: 0.5, iso: iso)
        var l = try bisect(\.lightness, fixed: committed.colour, luminance: true)
        let colour = try bisect(\.chroma, fixed: max(l, 0.01), luminance: false)
        l = try bisect(\.lightness, fixed: max(colour, 0.01), luminance: true)
        return (l, colour)
    }

    /// The real CC0 APS-C frame at ISO 640 against the full-frame CC0 sample (ISO 250) simulated at
    /// 640 under each model: the noise `SensorNoise` reads from each mosaic, bin by bin; Apple's decode
    /// with its noise reduction off and in production, flat-patch L* and chroma, and the share its
    /// production noise reduction removes; and the strengths at which the in-house decode matches
    /// Apple's production decode. A model that gives real noise should land where the real frame does.
    /// ARGENT_MODELS picks `before`, `published` (empty for neither); ARGENT_FILES adds real frames;
    /// ARGENT_MATCH=0 skips the strengths.
    @Test(.enabled(if: NoiseModelMeasureTests.enabled))
    func modelAgainstCC0() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let matching = ProcessInfo.processInfo.environment["ARGENT_MATCH"] != "0"
        var cases: [(name: String, url: URL, reference: URL)] = [("CC0 DSC06678 (APS-C), real ISO 640", ProvenanceMeasureTests.apsC, ProvenanceMeasureTests.apsC)]
        // Other real frames, each its own reference: ARGENT_FILES, comma-separated paths (the CC0 a7C II
        // frames at ISO 100 on raw.pixls.us, for instance, whose sensor is reported to be the a7 IV's).
        for path in (ProcessInfo.processInfo.environment["ARGENT_FILES"] ?? "").split(separator: ",") {
            let url = URL(fileURLWithPath: String(path))
            cases.append((url.lastPathComponent, url, url))
        }
        for (name, model) in Self.models() {
            for seed: UInt64 in [1, 2] {
                cases.append(("DSC06673 simulated at 640, model \(name), seed \(seed)",
                              try SyntheticRaw.simulated(iso: 640, seed: seed, model: model, name: "-\(name)"), SyntheticRaw.base))
            }
        }
        for c in cases {
            let source = try MeasureMosaic.load(c.url, device: gpu.device)
            let samples = source.buffer.contents().bindMemory(to: UInt16.self, capacity: source.buffer.length / 2)
            let bins = SensorNoise.levels(samples, layout: source.layout)
            let fit = SensorNoise.fit(bins)
            let reference = Pixels(try apple.decode(c.reference, options: M.appleOptions(lens: false, noiseReduction: false)).texture)
            let patches = N.flatPatches(reference)
            let off = N.noise(Pixels(try apple.decode(c.url, options: M.appleOptions(lens: false, noiseReduction: false)).texture), patches)
            let production = N.noise(Pixels(try apple.decode(c.url, options: DecodeOptions()).texture), patches)
            var line = String(format: "MEASURE %@: SensorNoise shot %.4f (%.4f at ISO 100), read %.2f; Apple NR off L* %.3f chroma %.3f, production L* %.3f chroma %.3f, removes %.0f%% of L*, %.0f%% of chroma",
                              c.name, fit.shot, fit.shot * 100 / 640, fit.read, off.lightness, off.chroma, production.lightness, production.chroma,
                              (1 - production.lightness / off.lightness) * 100, (1 - production.chroma / off.chroma) * 100)
            if matching {
                let m = try Self.match(source, patches: patches, target: production, decoder: decoder)
                line += String(format: "; matched luminance %.3f, colour %.3f", m.luminance, m.colour)
            }
            print(line)
            print("MEASURE   bins " + bins.filter { $0.level < 2000 }.map { String(format: "%.0f:%.1f", $0.level, $0.variance) }.joined(separator: " "))
        }
    }

    /// How Apple's production noise reduction responds to the noise in a frame against the ISO in its
    /// Exif: the CC0 sample simulated at each ISO under each model, and under the published model with
    /// the noise of one ISO written as another (half and twice). Printed: Apple's flat-patch L* and
    /// chroma with its noise reduction off and in production, the share removed, and the in-house
    /// decode under the committed strengths over Apple's production. If Apple's reduction followed the
    /// noise, the share removed would not depend on the model; if it follows the tag, it does.
    /// ARGENT_ISOS picks the ISOs (1600, 6400, 12800, 25600).
    @Test(.enabled(if: NoiseModelMeasureTests.enabled))
    func appleResponse() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let ladder = N.Ladder(name: "model", frames: [], reference: SyntheticRaw.base, stillLife: false)
        let patches = N.flatPatches(Pixels(try apple.decode(SyntheticRaw.base, options: M.appleOptions(lens: false, noiseReduction: false)).texture))
        for iso in ProvenanceMeasureTests.isos([1600, 6400, 12800, 25600]) {
            var cases: [(name: String, url: URL)] = []
            for (name, model) in Self.models() {
                cases.append(("noise of \(iso), model \(name), tag \(iso)", try SyntheticRaw.simulated(iso: iso, model: model, name: "-\(name)")))
            }
            for tag in [iso / 2, iso * 2] {
                cases.append(("noise of \(iso), model published, tag \(tag)", try SyntheticRaw.simulated(iso: iso, model: Self.published, tag: tag, name: "-published")))
            }
            for c in cases {
                let source = try MeasureMosaic.load(c.url, device: gpu.device)
                let off = N.noise(Pixels(try apple.decode(c.url, options: M.appleOptions(lens: false, noiseReduction: false)).texture), patches)
                let production = N.noise(Pixels(try apple.decode(c.url, options: DecodeOptions()).texture), patches)
                let ours = N.noise(Pixels(try N.render(source, ladder: ladder, decoder: decoder, tuning: nil).texture), patches)
                print(String(format: "MEASURE %@: Apple NR off L* %.3f chroma %.3f; production L* %.3f chroma %.3f, removes %.0f%% of L*, %.0f%% of chroma; in-house committed L* %.2f, chroma %.2f of Apple's",
                             c.name, off.lightness, off.chroma, production.lightness, production.chroma, (1 - production.lightness / off.lightness) * 100,
                             (1 - production.chroma / off.chroma) * 100, ours.lightness / production.lightness, ours.chroma / production.chroma))
            }
        }
    }

    // MARK: Real noise against the model, on a ladder of real frames

    /// The a7C's sensor noise as PhotonsToPhotos publishes it ("Sony ILCE-7C_14" in
    /// https://photonstophotos.net/Charts/RN_e.htm, read 2026-10-07; reported): unity gain at its
    /// `unityEv` of 7.56, ISO 589.9; input-referred read noise in log2 electrons, the high conversion
    /// gain from ISO 640. For simulating RawNIND's a7C ladder; not shipped.
    static let a7C = BodyNoise(shotAtISO100: 100 / 589.9, readLog2Electrons: [
        (100, 2.61), (125, 2.52), (160, 2.43), (200, 2.37), (250, 2.37), (320, 2.28), (400, 2.30), (500, 2.26), (640, 0.44),
        (800, 0.37), (1000, 0.38), (1250, 0.35), (1600, 0.32), (2000, 0.28), (2500, 0.29), (3200, 0.24), (4000, 0.24),
        (5000, 0.28), (6400, 0.12), (8000, 0.11), (10000, 0.16), (12800, 0.09), (16000, 0.06), (20000, 0.08), (25600, 0.04),
        (32000, 0.01), (40000, -0.05), (51200, -0.03),
    ], highGainISO: 640, unityGainISO: 589.9, decodedUnitsPerDN: .zero)

    /// RawNIND's a7C scene at the ISO of `real` with `model`'s noise: the mean of the two ground-truth
    /// frames at ISO 50, scaled to `real`'s exposure by a gain per Bayer site (the median ratio of
    /// mid-level 32-pixel block means), given the whole noise of `iso` at its level, written into a
    /// copy of `real` so the decoders read its Exif and makernote. The clean frames' own noise, an ISO
    /// 100 frame's at twice the level, scaled by the gain and halved by the mean, stays in: under 2
    /// percent of the variance from ISO 1000 up (computed from the model).
    static func simulatedA7C(real: URL, clean: [URL], iso: Int, model: BodyNoise, seed: UInt64) throws -> URL {
        let realData = try Data(contentsOf: real)
        let l = try SyntheticRaw.layout(realData)
        let count = l.width * l.height
        var signal = [Double](repeating: 0, count: count)
        for url in clean {
            let data = try Data(contentsOf: url)
            let c = try SyntheticRaw.layout(data)
            precondition(c.width == l.width && c.height == l.height, "clean and real frames differ in size")
            data.withUnsafeBytes { bytes in
                let s = (bytes.baseAddress! + c.strip).assumingMemoryBound(to: UInt16.self)
                for i in 0..<count { signal[i] += (Double(s[i]) - Double(c.black)) / Double(clean.count) }
            }
        }
        var gain = [Double](repeating: 1, count: 4)
        realData.withUnsafeBytes { bytes in
            let s = (bytes.baseAddress! + l.strip).assumingMemoryBound(to: UInt16.self)
            let range = Double(l.white - l.black), side = 32
            for site in 0..<4 {
                let dy = site / 2, dx = site % 2
                var ratios: [Double] = []
                for y0 in stride(from: l.cropY & ~1, through: l.cropY + l.cropHeight - side, by: side) {
                    for x0 in stride(from: l.cropX & ~1, through: l.cropX + l.cropWidth - side, by: side) {
                        var a = 0.0, b = 0.0
                        for y in stride(from: y0 + dy, to: y0 + side, by: 2) {
                            for x in stride(from: x0 + dx, to: x0 + side, by: 2) {
                                a += signal[y * l.width + x]
                                b += Double(s[y * l.width + x]) - Double(l.black)
                            }
                        }
                        a /= Double(side * side / 4); b /= Double(side * side / 4)
                        if a > 200, a < 0.6 * range, b < 0.8 * range { ratios.append(b / a) }
                    }
                }
                gain[site] = GateMeasureTests.median(ratios)
            }
        }
        let shot = SyntheticRaw.shot(iso: Double(iso), model: model), read = SyntheticRaw.read(iso: Double(iso), model: model)
        return try SyntheticRaw.write("a7c-simulated-iso\(iso)-seed\(seed).ARW", from: real, iso: nil) { samples, l in
            var g = SyntheticRaw.Gaussian(seed: seed &* 7919 &+ UInt64(iso))
            let black = Double(l.black), white = Double(l.white)
            for y in 0..<l.height {
                for x in 0..<l.width {
                    let i = y * l.width + x
                    let level = signal[i] * gain[(y % 2) * 2 + x % 2]
                    let v = level + black + g.next() * (shot * max(level, 0) + read).squareRoot()
                    samples[i] = UInt16(min(max(v.rounded(), 0), white))
                }
            }
        }
    }

    /// RawNIND's a7C ladder (CC BY-SA 4.0; it may choose constants since 2026-10-07, docs/research/
    /// legal.md, Q7), each real frame against the same scene simulated at its ISO with the a7C's
    /// published noise (`simulatedA7C`): what `SensorNoise` reads; Apple's decode with its noise
    /// reduction off and in production on the same flat patches; and the strengths at which the
    /// in-house decode, through the a7C's fitted matrix, matches Apple's production decode. If white
    /// Poisson-Gaussian noise with the published parameters is what the sensor gives, the two rows of
    /// each ISO agree. ARGENT_ISOS picks the ISOs; ARGENT_MATCH=0 skips the strengths.
    @Test(.enabled(if: NoiseModelMeasureTests.enabled))
    func a7cRealAgainstSimulated() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let matching = ProcessInfo.processInfo.environment["ARGENT_MATCH"] != "0"
        let ladder = try N.a7c(gpu: gpu, decoder: decoder, apple: apple)
        let clean = try FileManager.default.contentsOfDirectory(at: M.corpus("rawnind-a7c"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("_GT_ISO50") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let patches = N.flatPatches(Pixels(try apple.decode(ladder.reference, options: M.appleOptions(lens: false, noiseReduction: false)).texture))
        print("MEASURE a7C: \(patches.count) flat patches, clean frames \(clean.count)")
        let isos = Set(ProvenanceMeasureTests.isos([640, 1000, 5000, 8000, 12800, 16000, 20000, 40000, 51200, 64000]))
        var seen = Set<Int>()
        for frame in ladder.frames where isos.contains(frame.iso) && !seen.contains(frame.iso) {
            seen.insert(frame.iso)
            let simulated = try Self.simulatedA7C(real: frame.url, clean: clean, iso: frame.iso, model: Self.a7C, seed: 1)
            for (kind, url) in [("real", frame.url), ("simulated", simulated)] {
                let source = try MeasureMosaic.load(url, device: gpu.device)
                let samples = source.buffer.contents().bindMemory(to: UInt16.self, capacity: source.buffer.length / 2)
                let fit = SensorNoise.fit(SensorNoise.levels(samples, layout: source.layout))
                let off = N.noise(Pixels(try apple.decode(url, options: M.appleOptions(lens: false, noiseReduction: false)).texture), patches)
                let production = N.noise(Pixels(try apple.decode(url, options: DecodeOptions()).texture), patches)
                var line = String(format: "MEASURE a7C ISO %d %@: SensorNoise shot %.3f read %.1f; Apple NR off L* %.3f chroma %.3f, production L* %.3f chroma %.3f (removes %.0f%%, %.0f%%)",
                                  frame.iso, kind, fit.shot, fit.read, off.lightness, off.chroma, production.lightness, production.chroma,
                                  (1 - production.lightness / off.lightness) * 100, (1 - production.chroma / off.chroma) * 100)
                if matching {
                    let m = try Self.match(source, patches: patches, target: production, decoder: decoder, ladder: ladder)
                    line += String(format: "; matched luminance %.3f, colour %.3f", m.luminance, m.colour)
                }
                print(line)
            }
        }
    }

    // MARK: Prints across the cutoff

    /// What a user sees around the decoder's ISO cutoff, on frames the project may choose on: the CC0
    /// scene at its own ISO 250, the CC0 APS-C frame at its own 640, and the full-frame scene simulated
    /// at ISO 640 to 3200 with the published model; the in-house print against Apple's production
    /// print, Portra 400 at box speed with grain, halation and sharpening and one grain seed, Delta E
    /// 2000 per pixel and on 8-pixel blocks, against Apple's production decode and against it with
    /// its lens correction off, which leaves the noise reduction as the difference
    /// (`InHouseNoiseMeasureTests/printsAgainstApple`, which runs M1's scenes and the still life).
    /// ARGENT_ISOS picks the simulated ISOs; ARGENT_COLOUR sets another colour strength.
    @Test(.enabled(if: NoiseModelMeasureTests.enabled))
    func printsAcrossTheCutoff() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let settings = DevelopSettings(grain: 1, grainSeed: 7, halation: true, sharpen: true)
        var cases: [(name: String, url: URL)] = [("CC0 DSC06673, real ISO 250", SyntheticRaw.base), ("CC0 DSC06678 (APS-C), real ISO 640", ProvenanceMeasureTests.apsC)]
        for iso in ProvenanceMeasureTests.isos([640, 800, 1000, 1250, 1600, 3200]) {
            cases.append(("DSC06673 simulated at ISO \(iso)", try SyntheticRaw.simulated(iso: iso)))
        }
        // ARGENT_COLOUR replaces the committed colour strength, for seeing what it changes in a print.
        let colour = ProcessInfo.processInfo.environment["ARGENT_COLOUR"].flatMap(Float.init)
        for c in cases {
            var tuning: InHouseNoiseReduction.Tuning?
            if let colour {
                let iso = try ARWFrameInfo.read(from: c.url).iso.map(Float.init)
                tuning = InHouseNoiseReduction.tuning(luminance: NoiseReduction.luminanceAmount(iso: iso), colour: 0.5, iso: iso)
                tuning!.colour = colour
            }
            let ours = Pixels(try renderer.render(try M.inHouse(c.url, decoder: decoder, gpu: gpu, tuning: tuning), settings: settings).image.texture)
            var line = "MEASURE print \(c.name)\(colour.map { String(format: ", colour %.2f", $0) } ?? ""), in-house against Apple production:"
            for lens in [true, false] {
                let theirs = Pixels(try renderer.render(try apple.decode(c.url, options: M.appleOptions(lens: lens, noiseReduction: true)),
                                                        settings: settings).image.texture)
                let pixel = Stats.deltaE(ours, theirs, block: 1), block = Stats.deltaE(ours, theirs, block: 8)
                line += String(format: " %@ per pixel mean %.2f, p95 %.2f; 8-px blocks mean %.2f, p95 %.2f;", lens ? "" : "lens off,",
                               pixel.mean, pixel.p95, block.mean, block.p95)
            }
            print(line)
        }
    }

    /// The level auto development reads from a dark frame through the in-house decoder, which the
    /// analysis measures as it comes (`DecodedNoise.appleDecode` takes the lift out for Apple's
    /// decodes only): the CC0 scene darkened in the raw and simulated at each ISO, decoded at the
    /// sheet's 960 pixels, against Apple's decode as the analysis reads it. ARGENT_ISOS and
    /// ARGENT_STOPS (comma-separated) pick the cases.
    @Test(.enabled(if: NoiseModelMeasureTests.enabled))
    func inHouseDarkLevel() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu)
        let stops = (ProcessInfo.processInfo.environment["ARGENT_STOPS"] ?? "0,-2,-3.5,-5").split(separator: ",").compactMap { Double($0) }
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        for s in stops {
            var line = String(format: "MEASURE dark level, scene %.1f stops:", s)
            for iso in ProvenanceMeasureTests.isos([250, 640, 1000, 1250, 1600, 6400]) {
                let url = try SyntheticRaw.simulated(iso: iso, stops: s)
                let info = try ARWFrameInfo.read(from: url)
                let ours = ExposureAnalyzer.analyze(try M.inHouse(url, decoder: decoder, gpu: gpu, options: options), info: info)
                let theirs = ExposureAnalyzer.analyze(try apple.decode(url, options: options), info: info)
                line += String(format: " ISO %d in-house %+.3f, Apple %+.3f;", iso, ours.meanStops, theirs.meanStops)
            }
            print(line)
        }
    }
}
