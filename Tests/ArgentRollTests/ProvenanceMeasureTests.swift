import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Measurements behind docs/provenance.md: shipped constants re-derived on data whose licence allows
/// choosing constants on it (the CC0 a7 IV samples from raw.pixls.us, Cube++ under CC BY 4.0, and
/// synthetic frames written into a copy of a CC0 file), with the restricted sets measured only as
/// evaluation. Gated like the other measurement suites:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --skip-build --filter ProvenanceMeasureTests/sensorNoise
///
/// File lists come from ARGENT_FILES, comma separated, absolute or relative to the package root.
@Suite(.serialized, .syntheticRaws) struct ProvenanceMeasureTests {
    static var enabled: Bool { FrameViewMeasureTests.enabled }
    typealias M = InHouseDecoderMeasureTests

    static func files(_ key: String = "ARGENT_FILES") -> [URL] {
        (ProcessInfo.processInfo.environment[key] ?? "").split(separator: ",").map { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: String(path)) : M.root.appendingPathComponent(String(path))
        }
    }

    /// The sensor noise `SensorNoise` reads from each file's own mosaic, with its ISO, and the
    /// conversion gain that implies at ISO 100 (shot scales with the ISO, since raw counts are
    /// proportional to ISO times exposure).
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func sensorNoise() throws {
        let gpu = try GPU()
        for url in Self.files() {
            let source = try MeasureMosaic.load(url, device: gpu.device)
            let samples = source.buffer.contents().bindMemory(to: UInt16.self, capacity: source.buffer.length / 2)
            let bins = SensorNoise.levels(samples, layout: source.layout)
            let fit = SensorNoise.fit(bins)
            let iso = Double(source.iso ?? 0)
            print(String(format: "MEASURE %@ ISO %.0f: shot %.4f DN per DN, read %.2f DN squared (fit, before the floor), shot at ISO 100 %.4f; %d bins",
                         url.lastPathComponent, iso, fit.shot, fit.read, iso > 0 ? fit.shot * 100 / iso : .nan, bins.count))
            for bin in bins {
                print(String(format: "MEASURE   level %8.1f DN: variance %8.2f (%d blocks), shot-only %.2f", bin.level, bin.variance, bin.blocks,
                             fit.shot * bin.level))
            }
        }
    }

    static let apsC = M.root.appendingPathComponent("references/exposure/pixls-ilce-7m4-samples/ILCE-7M4_DSC06678_APS-C-Raw-Uncompressed.ARW")

    static func isos(_ fallback: [Int]) -> [Int] {
        ProcessInfo.processInfo.environment["ARGENT_ISOS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? fallback
    }

    /// The standard deviation of the 3 by 3 high pass of scene-linear luminance (the luminance less
    /// its 3 by 3 box mean) over a patch's middle.
    static func highPass(_ frame: Pixels, _ patch: InHouseNoiseMeasureTests.Patch) -> Double {
        let side = InHouseNoiseMeasureTests.Patch.side
        var y = [Double](repeating: 0, count: side * side)
        for j in 0..<side { for i in 0..<side { y[j * side + i] = M.luminance(frame.rgb(patch.x + i, patch.y + j)) } }
        var sum = 0.0, squares = 0.0, n = 0.0
        for j in 1..<(side - 1) {
            for i in 1..<(side - 1) {
                var box = 0.0
                for dj in -1...1 { for di in -1...1 { box += y[(j + dj) * side + i + di] } }
                let d = y[j * side + i] - box / 9
                sum += d; squares += d * d; n += 1
            }
        }
        return (squares / n - (sum / n) * (sum / n)).squareRoot()
    }

    /// What Apple's luminance noise reduction removes at each amount: the share of the 3 by 3 high
    /// pass of luminance it takes out of flat patches, against the same decode with the amount at 0
    /// (colour 0.5 throughout, lens correction off), median over the patches. On the CC0 samples
    /// at their own ISOs (250, and 640 on the APS-C frame) and on the full-frame sample simulated at
    /// higher ISOs. The tiers in `NoiseReduction` describe 0.4, 0.6 and 0.9 by what they remove.
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func appleNoiseReduction() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        var cases: [(name: String, url: URL, reference: URL)] = [
            ("CC0 ISO 250, DSC06673", SyntheticRaw.base, SyntheticRaw.base),
            ("CC0 ISO 640, DSC06678 (APS-C)", Self.apsC, Self.apsC),
        ]
        for iso in Self.isos([640, 1600, 3200, 6400, 12800, 51200]) {
            cases.append(("simulated ISO \(iso) from DSC06673", try SyntheticRaw.simulated(iso: iso), SyntheticRaw.base))
        }
        let amounts: [Float] = [0, 0.4, 0.6, 0.75, 0.8, 0.9, 1.0]
        for c in cases {
            let reference = Pixels(try apple.decode(c.reference, options: M.appleOptions(lens: false, noiseReduction: false)).texture)
            let patches = InHouseNoiseMeasureTests.flatPatches(reference)
            var deviations: [Float: [Double]] = [:]
            var defaultAmount: Float = .nan
            for amount in amounts {
                var options = M.appleOptions(lens: false, noiseReduction: true)
                options.luminanceNoiseReduction = amount
                let frame = try apple.decode(c.url, options: options)
                let pixels = Pixels(frame.texture)
                deviations[amount] = patches.map { Self.highPass(pixels, $0) }
                if let iso = frame.pins?.luminanceNoiseReduction, amount == 0 { _ = iso }
            }
            if let filter = CIRAWFilterLookup.defaultLuminance(c.url) { defaultAmount = filter }
            var line = String(format: "MEASURE Apple NR %@ (%d patches, Apple's own default amount %.4f): removed", c.name, patches.count, defaultAmount)
            for amount in amounts.dropFirst() {
                let removed = zip(deviations[amount]!, deviations[0]!).map { 1 - $0 / max($1, 1e-12) }
                line += String(format: " %.2f: %.0f%%;", amount, Stats.median(removed) * 100)
            }
            print(line)
        }
    }
}

extension ProvenanceMeasureTests {
    /// The in-house noise reduction's strengths matched to Apple's production decode, on data whose
    /// licence allows choosing them (docs/provenance.md): for each frame, the luminance strength at
    /// which the decode's L* noise in flat patches equals Apple's production decode's, and the colour
    /// strength at which its chroma noise does, by bisection, each at the other's matched value. The
    /// frames: the CC0 full-frame sample at its own ISO 250 and simulated at higher ISOs
    /// (`SyntheticRaw.simulated`, patches chosen on the sample); the CC0 APS-C sample at its own ISO
    /// 640 (its own patches); and synthetic flat patches with the noise of ISO 100 and 250, since the
    /// sample cannot be made less noisy than it is. ARGENT_SETS picks among `real`, `simulated`,
    /// `flat`; ARGENT_ISOS the simulated ISOs, ARGENT_FLAT_ISOS the flat patches' (100 and 250),
    /// ARGENT_FLAT_KIND their kind (`flat`, four tints; `neutral`, neutral only).
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func noiseStrengths() throws {
        let env = ProcessInfo.processInfo.environment
        let sets = Set((env["ARGENT_SETS"] ?? "real,simulated,flat").split(separator: ",").map(String.init))
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        typealias N = InHouseNoiseMeasureTests
        let ladder = N.Ladder(name: "provenance", frames: [], reference: SyntheticRaw.base, stillLife: false)
        var cases: [(name: String, url: URL, reference: URL)] = []
        if sets.contains("real") {
            cases.append(("CC0 DSC06673 at its own ISO 250", SyntheticRaw.base, SyntheticRaw.base))
            cases.append(("CC0 DSC06678 (APS-C) at its own ISO 640", Self.apsC, Self.apsC))
        }
        if sets.contains("flat") {
            let kind = env["ARGENT_FLAT_KIND"] ?? "flat"
            let clean = try SyntheticRaw.patches(kind, iso: 250, noise: false).url
            let flatISOs = env["ARGENT_FLAT_ISOS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [100, 250]
            for iso in flatISOs { cases.append(("synthetic \(kind) patches, ISO \(iso) noise", try SyntheticRaw.patches(kind, iso: iso, noise: true).url, clean)) }
        }
        if sets.contains("simulated") {
            for iso in Self.isos([640, 1000, 1250, 1600, 3200, 6400, 8000, 12800, 25600, 51200, 102400]) {
                cases.append(("DSC06673 simulated at ISO \(iso)", try SyntheticRaw.simulated(iso: iso), SyntheticRaw.base))
            }
        }
        for c in cases {
            let reference = Pixels(try apple.decode(c.reference, options: M.appleOptions(lens: false, noiseReduction: false)).texture)
            let patches = N.flatPatches(reference)
            let source = try MeasureMosaic.load(c.url, device: gpu.device)
            let iso = source.iso.map(Float.init)
            let target = N.noise(Pixels(try apple.decode(c.url, options: DecodeOptions()).texture), patches)
            let appleOff = N.noise(Pixels(try apple.decode(c.url, options: M.appleOptions(lens: false, noiseReduction: false)).texture), patches)
            let amount = NoiseReduction.luminanceAmount(iso: iso)
            let impulse = amount == NoiseReduction.extremeISOLuminance ? InHouseNoiseReduction.extremeImpulse : 0
            func measure(_ luminance: Float, _ colour: Float) throws -> (lightness: Double, chroma: Double) {
                var t = InHouseNoiseReduction.Tuning(luminanceAmount: -1, colourAmount: -1, luminance: luminance, colour: colour)
                t.impulse = impulse
                return N.noise(Pixels(try N.render(source, ladder: ladder, decoder: decoder, tuning: t).texture), patches)
            }
            // Noise falls as either strength rises; bisect in the strength's logarithm.
            func match(_ keyPath: KeyPath<(lightness: Double, chroma: Double), Double>, fixed: Float, luminance: Bool) throws -> Float {
                var lo: Float = 0.01, hi: Float = 8
                let goal = target[keyPath: keyPath]
                if try (luminance ? measure(lo, fixed) : measure(fixed, lo))[keyPath: keyPath] <= goal { return 0 }
                for _ in 0..<12 {
                    let mid = (lo * hi).squareRoot()
                    let n = try (luminance ? measure(mid, fixed) : measure(fixed, mid))[keyPath: keyPath]
                    if n > goal { lo = mid } else { hi = mid }
                }
                return (lo * hi).squareRoot()
            }
            let committed = InHouseNoiseReduction.tuning(luminance: amount, colour: 0.5, iso: iso)
            var l = try match(\.lightness, fixed: committed.colour, luminance: true)
            let colour = try match(\.chroma, fixed: max(l, 0.01), luminance: false)
            l = try match(\.lightness, fixed: max(colour, 0.01), luminance: true)
            let ours = try measure(l, colour), off = try measure(0, 0), now = try measure(committed.luminance, committed.colour)
            print(String(format: "MEASURE strengths %@ (ISO %.0f, Apple's amount %.1f, %d patches): luminance %.3f, colour %.3f; Apple production L* %.3f chroma %.3f, Apple NR off L* %.3f chroma %.3f; ours NR off L* %.3f chroma %.3f; ours matched L* %.3f chroma %.3f; committed (%.2f, %.2f) L* %.3f (%.2f of Apple's) chroma %.3f (%.2f)",
                         c.name, Double(iso ?? 0), amount, patches.count, l, colour, target.lightness, target.chroma, appleOff.lightness, appleOff.chroma,
                         off.lightness, off.chroma, ours.lightness, ours.chroma, committed.luminance, committed.colour, now.lightness,
                         now.lightness / target.lightness, now.chroma, now.chroma / target.chroma))
        }
    }
}

extension ProvenanceMeasureTests {
    /// The noise reduction's other constants against their alternatives on the CC0 sample simulated
    /// at higher ISOs, with the sample itself at ISO 250 as the clean frame of the same scene: flat-patch
    /// L* and chroma noise over Apple's production decode's, and the share of the clean frame's detail
    /// each decode keeps in three bands, over the share Apple's keeps (as decoder.md section 10 measured
    /// on RawNIND's a7C ladder). Variants: the committed tuning; luminance not inheriting; colour
    /// inheriting; the flat-area fade at 2 to 4 and off; five pyramid levels instead of seven; impulses
    /// at 6 deviations and off; the colour lift at 1 and 4.
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func noiseDesign() throws {
        let gpu = try GPU(maxIdlePoolBytes: 600 << 20)
        let decoder = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        typealias N = InHouseNoiseMeasureTests
        let ladder = N.Ladder(name: "provenance", frames: [], reference: SyntheticRaw.base, stillLife: false)
        let reference = Pixels(try apple.decode(SyntheticRaw.base, options: M.appleOptions(lens: false, noiseReduction: false)).texture)
        let patches = N.flatPatches(reference)
        let cleanSource = try MeasureMosaic.load(SyntheticRaw.base, device: gpu.device)
        let clean = (apple: N.bandImages(Pixels(try apple.decode(SyntheticRaw.base, options: DecodeOptions()).texture)),
                     ours: N.bandImages(Pixels(try N.render(cleanSource, ladder: ladder, decoder: decoder, tuning: nil).texture)))
        for iso in Self.isos([1600, 6400, 25600, 51200]) {
            let url = try SyntheticRaw.simulated(iso: iso)
            let source = try MeasureMosaic.load(url, device: gpu.device)
            let production = Pixels(try apple.decode(url, options: DecodeOptions()).texture)
            let target = N.noise(production, patches)
            let appleKept = N.retained(N.bandImages(production), clean.apple)
            print(String(format: "MEASURE design ISO %d: Apple production L* %.3f chroma %.3f, keeps %@ of the clean frame's bands", iso, target.lightness,
                         target.chroma, appleKept.map { String(format: "%.2f", $0) }.joined(separator: ", ")))
            let committed = InHouseNoiseReduction.tuning(luminance: NoiseReduction.luminanceAmount(iso: Float(iso)), colour: 0.5, iso: Float(iso))
            var variants: [(String, InHouseNoiseReduction.Tuning)] = [("committed", committed)]
            func variant(_ name: String, _ change: (inout InHouseNoiseReduction.Tuning) -> Void) {
                var t = committed
                change(&t)
                variants.append((name, t))
            }
            variant("luminance does not inherit") { $0.inherit = 0 }
            variant("colour inherits") { $0.inheritColour = 1 }
            variant("flat fade 2 to 4") { $0.flatLow = 2; $0.flatHigh = 4 }
            variant("flat fade off") { $0.flatLow = 0.0001; $0.flatHigh = 0.0002 }
            variant("five levels") { $0.luminanceProfile = [1, 1, 1, 1, 1]; $0.colourProfile = [1, 1, 1, 1, 1] }
            variant("lift 1") { $0.lift = 1 }
            variant("lift 4") { $0.lift = 4 }
            if committed.impulse > 0 {
                variant("impulses at 6") { $0.impulse = 6 }
                variant("impulses off") { $0.impulse = 0 }
            }
            for (name, tuning) in variants {
                let ours = Pixels(try N.render(source, ladder: ladder, decoder: decoder, tuning: tuning).texture)
                let n = N.noise(ours, patches)
                let kept = zip(N.retained(N.bandImages(ours), clean.ours), appleKept).map { String(format: "%.2f", $0 / $1) }.joined(separator: ", ")
                print(String(format: "MEASURE   %@: L* %.2f of Apple's, chroma %.2f; detail kept over Apple's %@", name, n.lightness / target.lightness,
                             n.chroma / target.chroma, kept))
            }
        }
    }
}

extension ProvenanceMeasureTests {
    typealias A = AutoMeasureTests

    /// The full-frame CC0 samples Apple's decoder reads at full size, one scene shot hand-held at ISO
    /// 250 in three raw modes, each with where its sign pole stands against the white wall at the right
    /// of the scene: about which column, and the picture rows (from the top) where wall is behind it.
    /// The three are framed hundreds of pixels apart (read off each frame's preview).
    static let fullFrameCC0: [(url: URL, pole: Int, rows: Range<Int>)] = [
        (M.lossless, 6480, 3600..<4200),
        (SyntheticRaw.base, 5860, 3340..<3940),
        (M.root.appendingPathComponent("samples/ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW"), 6520, 3820..<4460),
    ]

    /// The sign pole's two edges in a full-size picture: its left edge (wall to pole, light to dark),
    /// the column near `pole` where luminance falls most from three pixels left to three right,
    /// averaged over `rows`; and its right edge (pole to wall), the strongest rise within 60 pixels
    /// right of it. Each as a window of columns around it.
    static func poleEdges(_ linear: [Float], width: Int, height: Int, pole: Int, rows: Range<Int>) -> (left: Range<Int>, right: Range<Int>) {
        func at(_ x: Int, _ y: Int) -> Float { linear[(height - 1 - y) * width + x] }
        var best = (x: pole, fall: -Float.infinity)
        for x in (pole - 40)..<(pole + 20) {
            var fall: Float = 0
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 4) { fall += at(x - 3, y) - at(x + 3, y) }
            if fall > best.fall { best = (x, fall) }
        }
        var rise = (x: best.x + 8, gain: -Float.infinity)
        for x in (best.x + 8)..<(best.x + 60) {
            var gain: Float = 0
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 4) { gain += at(x + 3, y) - at(x - 3, y) }
            if gain > rise.gain { rise = (x, gain) }
        }
        let half = min(12, (rise.x - best.x) / 2)
        return ((best.x - 24)..<(best.x + half), (rise.x - half)..<(rise.x + 24))
    }

    /// Picture rows (from the top) to texture rows (from the bottom).
    static func up(_ r: Range<Int>, _ height: Int) -> Range<Int> { (height - r.upperBound)..<(height - r.lowerBound) }

    /// The median over `patches` of the L* standard deviation of a print, a plane taken out.
    static func patchLightnessNoise(_ pixels: [Float16], width: Int, patches: [InHouseNoiseMeasureTests.Patch]) -> Float {
        let side = InHouseNoiseMeasureTests.Patch.side
        let values: [Float] = patches.map { p in
            var l = [Float](repeating: 0, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    let i = ((p.y + y) * width + p.x + x) * 4
                    let v = 0.2627 * Float(pixels[i]) + 0.6780 * Float(pixels[i + 1]) + 0.0593 * Float(pixels[i + 2])
                    l[y * side + x] = v > 0.008856 ? 116 * cbrt(v) - 16 : 903.3 * v
                }
            }
            return A.flatNoise(l, width: side, columns: 0..<side, rows: 0..<side)
        }
        return values.sorted()[values.count / 2]
    }

    /// Capture sharpening's sensor mask chosen on the CC0 scene (docs/provenance.md), by rules fixed
    /// before measuring: its sigma is the blur a Gaussian step fits on the sign pole's light-to-dark
    /// edge in the full-size scene-linear decode, the median over the three full-frame CC0 samples,
    /// rounded down to a tenth of a pixel (a little narrower than the blur, as section 7 of
    /// docs/M3-auto.md had it); its amount is 1; its threshold is the smallest of 0.002, 0.004, 0.006
    /// and 0.009 at which sharpening raises the L* noise of flat patches without grain by under 10
    /// percent on the sample simulated at ISO 3200, the middle of the spec's moderate tier. Also
    /// printed: every combination of sigma 0.7 to 1.3, amount 0.5 to 1.3 and those thresholds, and
    /// the noise with and without grain from ISO 250 to 51200, as section 7 measured them.
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func sharpening() throws {
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let apple = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        // The decode's own blur on the pole's light-to-dark edge, and where the edges are.
        var sigmas: [Float] = []
        var edges: [(url: URL, left: Range<Int>, right: Range<Int>, rows: Range<Int>)] = []
        for (url, pole, rows) in Self.fullFrameCC0 {
            let frame = try apple.decode(url, options: DecodeOptions())
            let linear = A.lightness(ExposureAnalyzer.pixels(of: frame.texture), linear: true)
            let (left, right) = Self.poleEdges(linear, width: frame.width, height: frame.height, pole: pole, rows: rows)
            let e = A.edge(linear, width: frame.width, columns: left, rows: Self.up(rows, frame.height), reach: 8)
            let r = A.edge(linear, width: frame.width, columns: right, rows: Self.up(rows, frame.height), reach: 8)
            sigmas.append(e.sigma)
            edges.append((url, left, right, rows))
            print(String(format: "MEASURE sharpen %@: pole edges at columns %d and %d; light-to-dark edge rises in %.2f px, a blurred step fits at sigma %.2f px; the far edge %.2f px, sigma %.2f",
                         url.lastPathComponent, left.lowerBound + 24, right.upperBound - 24, e.rise, e.sigma, r.rise, r.sigma))
        }
        let blur = sigmas.sorted()[sigmas.count / 2]
        let sigma = (blur * 10).rounded(.down) / 10
        print(String(format: "MEASURE sharpen: median blur sigma %.2f px, so the mask's sigma is %.1f", blur, sigma))

        // Noise: flat patches chosen on the sample's own decode without noise reduction, measured
        // on prints of the sample at its own ISO and simulated higher.
        let reference = Pixels(try apple.decode(SyntheticRaw.base, options: M.appleOptions(lens: false, noiseReduction: false)).texture)
        let patches = InHouseNoiseMeasureTests.flatPatches(reference)
        let noiseISOs = Self.isos([250, 800, 3200, 12800, 51200])
        var frames: [Int: LinearFrame] = [:]
        for iso in noiseISOs {
            frames[iso] = try apple.decode(iso == 250 ? SyntheticRaw.base : try SyntheticRaw.simulated(iso: iso), options: DecodeOptions())
        }
        let edgeFrame = try apple.decode(edges[0].url, options: DecodeOptions())
        func printed(_ constants: (sensor: CaptureSharpening.Mask, draftScaling: CaptureSharpening.Mask, threshold: Float)?,
                   _ frame: LinearFrame, grain: Float = 0) throws -> [Float16] {
            renderer.sharpeningConstants = constants ?? (CaptureSharpening.sensor, CaptureSharpening.draftScaling, 0)
            let out = try renderer.render(frame, settings: DevelopSettings(grain: grain, grainSeed: 5, sharpen: constants != nil))
            return ExposureAnalyzer.pixels(of: out.image.texture)
        }
        func edgeLine(_ pixels: [Float16]) -> String {
            let l = A.lightness(pixels)
            let e = A.edge(l, width: edgeFrame.width, columns: edges[0].left, rows: Self.up(edges[0].rows, edgeFrame.height), reach: 8)
            let r = A.edge(l, width: edgeFrame.width, columns: edges[0].right, rows: Self.up(edges[0].rows, edgeFrame.height), reach: 8)
            let bands = A.bands(l, width: edgeFrame.width)
            return String(format: "light-to-dark edge %.2f px (overshoot %.1f%%), far edge %.2f px (%.1f%%), bands %.3f %.3f %.3f",
                          e.rise, e.overshoot * 100, r.rise, r.overshoot * 100, bands[0], bands[1], bands[2])
        }
        print("MEASURE sharpen off at ISO 250: \(edgeLine(try printed(nil, edgeFrame)))")
        let offNoise = try Dictionary(uniqueKeysWithValues: noiseISOs.map { iso in
            (iso, Self.patchLightnessNoise(try printed(nil, frames[iso]!), width: frames[iso]!.width, patches: patches)) })
        // The sweep.
        let thresholds: [Float] = [0.002, 0.004, 0.006, 0.009]
        var chosen: Float?
        for s: Float in [0.7, 0.85, 1.0, 1.15, 1.3] {
            for amount: Float in [0.5, 0.8, 1.0, 1.3] {
                for t in thresholds {
                    let constants = (CaptureSharpening.Mask(sigma: s, amount: amount), CaptureSharpening.draftScaling, t)
                    let n3200 = noiseISOs.contains(3200)
                        ? Self.patchLightnessNoise(try printed(constants, frames[3200]!), width: frames[3200]!.width, patches: patches) / offNoise[3200]! : .nan
                    print(String(format: "MEASURE sharpen sigma %.2f amount %.1f threshold %.3f: noise at ISO 3200 %+.1f%%; %@", s, amount, t,
                                       (n3200 - 1) * 100, edgeLine(try printed(constants, edgeFrame))))
                    if abs(s - sigma) < 0.01, amount == 1, chosen == nil, n3200 < 1.1 { chosen = t }
                }
            }
        }
        // The rule's own sigma, if the sweep's grid missed it.
        if ![Float(0.7), 0.85, 1.0, 1.15, 1.3].contains(where: { abs($0 - sigma) < 0.01 }) {
            for t in thresholds where chosen == nil {
                let constants = (CaptureSharpening.Mask(sigma: sigma, amount: 1), CaptureSharpening.draftScaling, t)
                let n3200 = Self.patchLightnessNoise(try printed(constants, frames[3200]!), width: frames[3200]!.width, patches: patches) / offNoise[3200]!
                print(String(format: "MEASURE sharpen sigma %.2f amount 1.0 threshold %.3f: noise at ISO 3200 %+.1f%%", sigma, t, (n3200 - 1) * 100))
                if n3200 < 1.1 { chosen = t }
            }
        }
        print(String(format: "MEASURE sharpen chosen by the rules: sigma %.1f, amount 1, threshold %.3f (committed %.2f, %.1f, %.3f)", sigma, chosen ?? .nan,
                           CaptureSharpening.sensor.sigma, CaptureSharpening.sensor.amount, CaptureSharpening.threshold))
        // The committed constants on the edges at ISO 250.
        let committed = (CaptureSharpening.sensor, CaptureSharpening.draftScaling, CaptureSharpening.threshold)
        print(String(format: "MEASURE sharpen committed (sigma %.2f, amount %.1f, threshold %.3f) at ISO 250: %@", committed.0.sigma, committed.0.amount,
                     committed.2, edgeLine(try printed(committed, edgeFrame))))
        // Noise up the ladder with the committed constants, without grain and with it.
        for iso in noiseISOs {
            var line = "MEASURE sharpen noise at ISO \(iso), flat patches' L* sd:"
            for grain: Float in [0, 1] {
                let off = Self.patchLightnessNoise(try printed(nil, frames[iso]!, grain: grain), width: frames[iso]!.width, patches: patches)
                let on = Self.patchLightnessNoise(try printed(committed, frames[iso]!, grain: grain), width: frames[iso]!.width, patches: patches)
                line += String(format: " grain %.0f off %.3f on %.3f (%+.1f%%);", grain, off, on, (on / off - 1) * 100)
            }
            print(line)
        }
    }
}

extension ProvenanceMeasureTests {
    /// Capture sharpening's mask for Apple's draft-mode scaling chosen on the three full-frame CC0
    /// samples (docs/provenance.md), by the rule section 9 of docs/M3-auto.md applied on Imaging
    /// Resource's still life, fixed before measuring: render from a decode Apple scaled to 960, 2048
    /// and 3072 pixels (draft mode) with the sensor's mask and a draft mask, and compare the finest of
    /// the three bands (near 0.31 cycles a pixel) with the full-size develop area-resized to the same
    /// size, averaged over the frames; the mask whose worst size is nearest 1 wins, and among masks
    /// within 0.01 of it the smallest amount. Above draft mode (4096 and 6144) no mask is needed if
    /// the sensor's mask alone keeps the finest band within 0.05 of the develop's. ARGENT_SENSOR sets
    /// the sensor mask and threshold as `sigma,amount,threshold` (the committed ones by default).
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func draftMask() throws {
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let apple = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let resize = try AreaResize(gpu: gpu)
        let given = ProcessInfo.processInfo.environment["ARGENT_SENSOR"]?.split(separator: ",").compactMap { Float($0) }
        let sensor = given.map { CaptureSharpening.Mask(sigma: $0[0], amount: $0[1]) } ?? CaptureSharpening.sensor
        let threshold = given.map { $0[2] } ?? CaptureSharpening.threshold
        let sigmas: [Float] = [0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6], amounts: [Float] = [0.5, 1, 1.5, 2, 2.5, 3]
        let draftSides = [960, 2048, 3072], fullSides = [4096, 6144]
        // ratios[mask][side] summed over frames; masks keyed by "sigma,amount", "none" for no draft mask.
        var sums: [String: [Int: [Float]]] = [:]
        for (url, _, _) in Self.fullFrameCC0 {
            renderer.sharpeningConstants = (sensor, CaptureSharpening.draftScaling, threshold)
            let full = try apple.decode(url, options: DecodeOptions())
            let develop = try renderer.render(full, settings: DevelopSettings(sharpen: true)).image
            for side in draftSides + fullSides {
                let area = try A.area(develop.texture, longSide: side, resize: resize)
                let target = A.bands(A.lightness(area.pixels), width: area.width)
                var options = DecodeOptions()
                options.maxLongSide = side
                let small = try apple.decode(url, options: options)
                func ratio(_ mask: CaptureSharpening.Mask?) throws -> [Float] {
                    renderer.sharpeningConstants = (sensor, mask ?? CaptureSharpening.Mask(sigma: 0, amount: 0), threshold)
                    let out = try renderer.render(small, settings: DevelopSettings(sharpen: true)).image
                    let bands = A.bands(A.lightness(ExposureAnalyzer.pixels(of: out.texture)), width: small.width)
                    return zip(bands, target).map { $0 / $1 }
                }
                func add(_ key: String, _ r: [Float]) {
                    sums[key, default: [:]][side] = zip(sums[key]?[side] ?? [0, 0, 0], r).map { $0 + $1 / Float(Self.fullFrameCC0.count) }
                }
                add("none", try ratio(nil))
                if draftSides.contains(side), small.pins?.draftMode == true {
                    for s in sigmas { for a in amounts { add(String(format: "%.2f,%.1f", s, a), try ratio(CaptureSharpening.Mask(sigma: s, amount: a))) } }
                }
            }
        }
        func line(_ key: String, _ sides: [Int]) -> String {
            sides.map { side in "\(side): " + (sums[key]?[side] ?? []).map { String(format: "%.2f", $0) }.joined(separator: ", ") }.joined(separator: "; ")
        }
        print(String(format: "MEASURE draft mask with the sensor mask sigma %.2f amount %.2f threshold %.3f", sensor.sigma, sensor.amount, threshold))
        print("MEASURE draft mask none: bands over the area-resized develop, \(line("none", draftSides + fullSides))")
        var scored: [(key: String, worst: Float, amount: Float)] = []
        for s in sigmas {
            for a in amounts {
                let key = String(format: "%.2f,%.1f", s, a)
                let worst = draftSides.map { abs((sums[key]?[$0]?[0] ?? .nan) - 1) }.max() ?? .nan
                scored.append((key, worst, a))
                print(String(format: "MEASURE draft mask %@: worst finest band off by %.3f; %@", key, worst, line(key, draftSides)))
            }
        }
        let best = scored.map(\.worst).min()!
        let chosen = scored.filter { $0.worst <= best + 0.01 }.min { $0.amount < $1.amount || ($0.amount == $1.amount && $0.worst < $1.worst) }!
        let above = fullSides.map { abs((sums["none"]?[$0]?[0] ?? .nan) - 1) }.max()!
        print(String(format: "MEASURE draft mask chosen by the rule: %@ (best worst %.3f); above draft mode the sensor mask alone is off by at most %.3f, so %@ (committed %.2f, %.1f)",
                     chosen.key, best, above, above <= 0.05 ? "no mask there" : "a mask is needed there", CaptureSharpening.draftScaling.sigma,
                     CaptureSharpening.draftScaling.amount))
    }
}

extension ProvenanceMeasureTests {
    /// The frame view's decode at the window's own pixels against the way it was before section 11 of
    /// docs/M3-auto.md (a decode at the next multiple of 512 rendered and area-resized to the window),
    /// on the three full-frame CC0 samples, sharpened as the app renders: the three bands over the
    /// full-size develop area-resized to the same pixels, averaged over the frames.
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func frameViewSizes() throws {
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let apple = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let resize = try AreaResize(gpu: gpu)
        let sides = Self.isos([900, 1408, 2190, 2600, 2944, 3500, 3700])
        var now: [Int: [Float]] = [:], before: [Int: [Float]] = [:]
        let n = Float(Self.fullFrameCC0.count)
        for (url, _, _) in Self.fullFrameCC0 {
            let develop = try renderer.render(try apple.decode(url, options: DecodeOptions()), settings: DevelopSettings(sharpen: true)).image
            for side in sides {
                let area = try A.area(develop.texture, longSide: side, resize: resize)
                let target = A.bands(A.lightness(area.pixels), width: area.width)
                var options = DecodeOptions()
                options.maxLongSide = side
                let direct = try apple.decode(url, options: options)
                let d = A.bands(A.lightness(ExposureAnalyzer.pixels(of: try renderer.render(direct, settings: DevelopSettings(sharpen: true)).image.texture)),
                                width: direct.width)
                options.maxLongSide = (side + 511) / 512 * 512
                let large = try apple.decode(url, options: options)
                let rendered = try renderer.render(large, settings: DevelopSettings(sharpen: true)).image
                let shrunk = try A.area(rendered.texture, longSide: side, resize: resize)
                let b = A.bands(A.lightness(shrunk.pixels), width: shrunk.width)
                now[side] = zip(now[side] ?? [0, 0, 0], zip(d, target).map { $0 / $1 }).map { $0 + $1 / n }
                before[side] = zip(before[side] ?? [0, 0, 0], zip(b, target).map { $0 / $1 }).map { $0 + $1 / n }
            }
        }
        for side in sides {
            print("MEASURE frame view at \(side) px over the develop: now (decoded at the window's pixels) "
                  + now[side]!.map { String(format: "%.2f", $0) }.joined(separator: ", ") + "; before (512-step decode, resized) "
                  + before[side]!.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        }
    }
}

import CoreImage

/// Apple's own per-file default for the luminance noise reduction amount.
enum CIRAWFilterLookup {
    static func defaultLuminance(_ url: URL) -> Float? {
        CIRAWFilter(imageURL: url).map { $0.luminanceNoiseReductionAmount }
    }
}

// MARK: Auto development's rules

extension ProvenanceMeasureTests {
    /// `ExposureAnalyzer`'s level with its rules opened up, for comparing them: light under `floor`
    /// stops counted as `floor`, and with `saturation` the research's saturation rule, which leaves
    /// out samples whose channels sit more than that many stops from their own mean in log2 (0.77
    /// stops is the research's 0.15-density radius at a negative gamma of 0.65), every sample
    /// counting again when the rule would keep under `fallbackShare` of the weight. Returns the
    /// level in stops against mid-gray and the share of the weight the rule set aside.
    static func level(_ pixels: [Float16], width: Int, height: Int, floor: Float, saturation: Float? = nil,
                      fallbackShare: Float = 0.5, skipMasked: Bool = false) -> (stops: Float, setAside: Float) {
        let floorValue = 0.18 * exp2(floor)
        let step = max(1, max(width, height) / ExposureAnalyzer.samplesOnLongSide)
        var brightest: Float = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            brightest = max(brightest, Float(pixels[index]), Float(pixels[index + 1]), Float(pixels[index + 2]))
        }
        let clip = brightest >= 0.18 * exp2(ExposureAnalyzer.clipFloorStops) ? brightest * 0.97 : .infinity
        let luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)
        var all: [(value: Float, weight: Float)] = [], kept: [(value: Float, weight: Float)] = []
        let cx = Float(width - 1) / 2, cy = Float(height - 1) / 2
        for y in stride(from: step / 2, to: height, by: step) {
            for x in stride(from: step / 2, to: width, by: step) {
                let dx = (Float(x) - cx) / max(cx, 1), dy = (Float(y) - cy) / max(cy, 1)
                let radius = (dx * dx + dy * dy).squareRoot()
                let weight: Float = radius < 1.0 / 3 ? 1 : radius < 2.0 / 3 ? 0.5 : 0.25
                let i = (y * width + x) * 4
                let rgb = SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                guard rgb.max() < clip, !(skipMasked && rgb == .zero) else { continue }
                let sample = (log2(max((rgb * luma).sum(), floorValue)), weight)
                all.append(sample)
                if let saturation {
                    let l = SIMD3(log2(max(rgb.x, floorValue)), log2(max(rgb.y, floorValue)), log2(max(rgb.z, floorValue)))
                    let spread = (l - SIMD3(repeating: l.sum() / 3)).max() > -(l - SIMD3(repeating: l.sum() / 3)).min()
                        ? (l - SIMD3(repeating: l.sum() / 3)).max() : -(l - SIMD3(repeating: l.sum() / 3)).min()
                    if spread <= saturation { kept.append(sample) }
                }
            }
        }
        let total = all.reduce(0) { $0 + $1.weight }, keptWeight = kept.reduce(0) { $0 + $1.weight }
        let used = saturation == nil || keptWeight < fallbackShare * total ? all : kept
        func trimmed(_ samples: [(value: Float, weight: Float)]) -> Float {
            let sorted = samples.sorted { $0.value < $1.value }
            let w = sorted.reduce(0) { $0 + $1.weight }
            let lower = w * ExposureAnalyzer.darkTrim, upper = w * (1 - ExposureAnalyzer.brightTrim)
            var cumulative: Float = 0, sum: Float = 0, n: Float = 0
            for s in sorted {
                let a = max(cumulative, lower), b = min(cumulative + s.weight, upper)
                if b > a { sum += s.value * (b - a); n += b - a }
                cumulative += s.weight
            }
            return n > 0 ? sum / n : sorted[sorted.count / 2].value
        }
        return (used.isEmpty ? 0 : trimmed(used) - log2(0.18), saturation == nil ? 0 : 1 - keptWeight / max(total, 1e-9))
    }

    /// The centre-weighted log2-luminance histogram in half-stop bins from `floor` to +5 stops, light
    /// under the floor in the first bin, summing to 1; and the earth mover's distance between two.
    static func histogram(_ pixels: [Float16], width: Int, height: Int, floor: Float) -> [Float] {
        let bins = Int((5 - floor) / 0.5)
        var h = [Float](repeating: 0, count: bins)
        let step = max(1, max(width, height) / ExposureAnalyzer.samplesOnLongSide)
        let cx = Float(width - 1) / 2, cy = Float(height - 1) / 2
        for y in stride(from: step / 2, to: height, by: step) {
            for x in stride(from: step / 2, to: width, by: step) {
                let dx = (Float(x) - cx) / max(cx, 1), dy = (Float(y) - cy) / max(cy, 1)
                let radius = (dx * dx + dy * dy).squareRoot()
                let weight: Float = radius < 1.0 / 3 ? 1 : radius < 2.0 / 3 ? 0.5 : 0.25
                let i = (y * width + x) * 4
                let l = 0.2627 * Float(pixels[i]) + 0.6780 * Float(pixels[i + 1]) + 0.0593 * Float(pixels[i + 2])
                let stops = log2(max(l, 0.18 * exp2(floor))) - log2(0.18)
                h[min(max(Int((stops - floor) / 0.5), 0), bins - 1)] += weight
            }
        }
        let total = h.reduce(0, +)
        return h.map { $0 / total }
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var cumulative: Float = 0, d: Float = 0
        for (x, y) in zip(a, b) { cumulative += x - y; d += abs(cumulative) }
        return d * 0.5
    }

    /// The level's floor and the histogram's, decided on RawNIND's a7C ladder and the photographyblog
    /// frames (docs/M3-auto.md, sections 1 and 2), measured again on permitted data: the CC0 scene
    /// darkened by 3.5 stops in the raw, with the a7 IV's noise at ISO 250 to 102400
    /// (`SyntheticRaw.simulated`), decoded as the sheet decodes it at 960 pixels. A frame's level
    /// should not move with the ISO, nor its histogram: a roll smoothing splits frames whose
    /// histograms differ by more than half a stop. Also the research's saturation rule on the same
    /// frames, and since 2026-10-07 the level and cast as the analysis read them before (one pixel a
    /// sample), from cells without the decoder's noise taken out, and as shipped (docs/M3-auto.md
    /// section 16). ARGENT_STOPS sets the darkening.
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func darkLadder() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let apple = AppleRawDecoder(gpu: gpu)
        let stops = Double(ProcessInfo.processInfo.environment["ARGENT_STOPS"] ?? "") ?? -3.5
        let floors: [Float] = [-8, -6, -5, -4]
        var previous: (points: [Float], shipped: ExposureAnalysis)?
        func cast(_ a: ExposureAnalysis) -> String {
            let c = AutoBalance.cast(a)
            return String(format: "%+.0f mired, green %+.3f", AutoBalance.mired(c), AutoBalance.axes(c).greenMagenta)
        }
        for iso in Self.isos([250, 1600, 6400, 25600, 51200, 102400]) {
            let url = try SyntheticRaw.simulated(iso: iso, stops: stops)
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            let frame = try apple.decode(url, options: options)
            let pixels = ExposureAnalyzer.pixels(of: frame.texture)
            let info = try ARWFrameInfo.read(from: url)
            let shipped = ExposureAnalyzer.analyze(frame, info: info)
            let points = ExposureAnalyzer.analyze(pixels: pixels, width: frame.width, height: frame.height, sampling: .points)
            let cells = ExposureAnalyzer.analyze(pixels: pixels, width: frame.width, height: frame.height)
            var line = String(format: "MEASURE dark ladder (%.1f stops) ISO %d: shipped level %+.2f (%@); points %+.2f (%@); cells, noise left in %+.2f (%@);",
                              stops, iso, shipped.meanStops, cast(shipped), points.meanStops, cast(points), cells.meanStops, cast(cells))
            for f in floors { line += String(format: " points, floor %.0f %+.2f;", f, Self.level(pixels, width: frame.width, height: frame.height, floor: f).stops) }
            for share: Float in [0.5, 0.1] {
                let r = Self.level(pixels, width: frame.width, height: frame.height, floor: -5, saturation: 0.77, fallbackShare: share)
                line += String(format: " saturation rule (fallback under %.0f%%) %+.2f, %.0f%% set aside;", share * 100, r.stops, r.setAside * 100)
            }
            let histogram = Self.histogram(pixels, width: frame.width, height: frame.height, floor: -5)
            if let previous {
                line += String(format: " histogram from the previous ISO: points %.2f, shipped %.2f stops;",
                               Self.distance(histogram, previous.points), shipped.histogramDistance(to: previous.shipped) ?? -1)
            }
            print(line)
            previous = (histogram, shipped)
        }
    }

    /// The research's saturation rule on Cube++'s analysis grids (CC BY 4.0, 1,597 scenes decoded as
    /// the sheet decodes; docs/M3-auto.md section 12): how much of each frame's weight it sets aside,
    /// and whether a stop more or less light still moves the level by a stop, with the rule and
    /// without, for frames whose level stays inside the print's bounds; the shipped analyzer is the
    /// rule off (checked to match). The grids hold the gray cube and its stand as zeros, which would
    /// sit at the floor whatever the light, so those samples are left out of the measures.
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func saturationRuleOnCube() throws {
        let frames = try LabBalanceMeasureTests.loadFrames()
        // The metered rule's: half a dark frame's level, lifted at most a stop (it is in `2a6e696`).
        let bounds: ClosedRange<Float> = -2...AutoPrint.darkenLimit
        var setAside: [Float] = [], moves: [Float] = [], fallbacks = 0, mismatch: Float = 0
        var errors: [String: [Float]] = [:]
        for frame in frames {
            let w = frame.prepared.gridWidth, h = frame.prepared.gridHeight
            let shipped = ExposureAnalyzer.analyze(pixels: frame.grid, width: w, height: h).meanStops
            mismatch = max(mismatch, abs(Self.level(frame.grid, width: w, height: h, floor: -5).stops - shipped))
            let off = Self.level(frame.grid, width: w, height: h, floor: -5, skipMasked: true)
            let on = Self.level(frame.grid, width: w, height: h, floor: -5, saturation: 0.77, skipMasked: true)
            setAside.append(on.setAside)
            moves.append(abs(on.stops - off.stops))
            if on.setAside > 0.5 { fallbacks += 1 }
            for k: Float in [2, 0.5] {
                let scaled = frame.grid.enumerated().map { $0.offset % 4 == 3 ? $0.element : Float16(Float($0.element) * k) }
                for (name, rule) in [("off", Float?.none), ("on, fallback under 50%", 0.77)] {
                    let a = Self.level(frame.grid, width: w, height: h, floor: -5, saturation: rule, skipMasked: true)
                    let b = Self.level(scaled, width: w, height: h, floor: -5, saturation: rule, skipMasked: true)
                    guard bounds.contains(a.stops), bounds.contains(b.stops) else { continue }
                    errors[name, default: []].append(abs(b.stops - a.stops - log2(k)))
                }
            }
        }
        let sorted = setAside.sorted()
        print(String(format: "MEASURE saturation rule on Cube++ (%d frames; the analyzer reproduced within %.4f stops): weight set aside median %.0f%%, 90th percentile %.0f%%, most %.0f%%; %d frames past half, where it falls back",
                     frames.count, mismatch, sorted[sorted.count / 2] * 100, sorted[sorted.count * 9 / 10] * 100, sorted.last! * 100, fallbacks))
        let m = moves.sorted()
        print(String(format: "MEASURE   the rule moves a frame's level by %.2f stops (median), %.2f (95th percentile), %.2f (most)",
                     m[m.count / 2], m[m.count * 95 / 100], m.last!))
        for (name, e) in errors.sorted(by: { $0.key < $1.key }) {
            let s = e.sorted()
            print(String(format: "MEASURE   rule %@: a stop of light moves the level by a stop within %.3f (median), %.3f (99th percentile), %.3f (worst) over %d cases",
                         name, s[s.count / 2], s[s.count * 99 / 100], s.last!, s.count))
        }
    }
}

extension ProvenanceMeasureTests {
    /// Auto lab balance's gray gamut against the two variants that measured better on Cube++ in
    /// section 12 of docs/M3-auto.md and were set aside there on two photographyblog frames (a magenta
    /// light show, a field of sunflowers), measured instead on Cube++'s held-out daylight frames (CC BY
    /// 4.0) made into those two cases synthetically:
    /// - a coloured light: the whole frame under an extra magenta (or green) cast, a light no gray-world
    ///   estimator should take for daylight; the spec keeps such light's colour (the lab trims casts, it
    ///   never removes them), so what matters is how much of the added cast the print takes out;
    /// - a yellow surface: the middle of the frame (a quarter, half, three quarters of its area) replaced
    ///   by a flat yellow under the frame's own measured light, at mid-gray's level; what matters is how
    ///   far the estimate moves from the light, in mired of red against blue and stops of green.
    /// Variants: shipped (gamut -1.3 to +2.1, every mid-tone when none is inside), every mid-tone when
    /// under a tenth of the weight is inside, and the gamut -1.3 to +5.5 centred on the lights' locus.
    @Test(.enabled(if: ProvenanceMeasureTests.enabled))
    func labBalanceVariants() throws {
        typealias L = LabBalanceMeasureTests
        let frames = try L.loadFrames().filter { frame in
            let rb = frame.truth.x - frame.truth.z
            return frame.split == "test" && rb > -0.3 && rb < 0.6
        }
        let variants: [(String, (L.Frame) -> SIMD3<Double>)] = [
            ("shipped", { L.shadesOfGray($0, gamut: .plausibleLight, locus: 0, minimumShare: 0) }),
            ("every mid-tone under a tenth inside", { L.shadesOfGray($0, gamut: .plausibleLight, locus: 0, minimumShare: 0.1) }),
            ("gamut -1.3 to 5.5 on the locus", { L.shadesOfGray($0, gamut: GrayGamut(redBlue: -1.3...5.5, greenMagenta: 0.35), locus: 0.2, minimumShare: 0) }),
        ]
        func recoloured(_ frame: L.Frame, _ transform: (Int, Int, SIMD3<Float>) -> SIMD3<Float>) -> L.Frame {
            var f = frame
            let w = frame.prepared.gridWidth, h = frame.prepared.gridHeight
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let rgb = transform(x, y, SIMD3(Float(frame.grid[i]), Float(frame.grid[i + 1]), Float(frame.grid[i + 2])))
                    f.grid[i] = Float16(rgb.x); f.grid[i + 1] = Float16(rgb.y); f.grid[i + 2] = Float16(rgb.z)
                }
            }
            return f
        }
        print("MEASURE lab balance variants on \(frames.count) held-out Cube++ frames lit near daylight")
        // A coloured light: green against magenta moved by `g` stops over the whole frame.
        for g: Float in [-1, -2, 1] {
            let cast = SIMD3<Float>(-g / 3, 2 * g / 3, -g / 3)
            let factor = SIMD3(exp2(cast.x), exp2(cast.y), exp2(cast.z))
            for (name, estimate) in variants {
                var removed: [Double] = []
                for frame in frames {
                    let before = AutoBalance.correction(for: SIMD3<Float>(estimate(frame)))
                    let after = AutoBalance.correction(for: SIMD3<Float>(estimate(recoloured(frame) { _, _, c in c * factor })))
                    removed.append(Double(AutoBalance.axes(after).greenMagenta - AutoBalance.axes(before).greenMagenta) / Double(g))
                }
                print(String(format: "MEASURE   light %+.0f stops of green: %@ takes out %.0f%% of the added cast (median; 90th percentile %.0f%%)",
                             g, name, Stats.median(removed) * 100, Stats.percentile(removed, 0.9) * 100))
            }
        }
        // A yellow surface under the frame's light, over the middle `share` of the frame: its colour
        // against a gray's under the same light as stops of red against blue and of green, one inside
        // the shipped gamut and two past its +2.1 but inside the locus gamut, as a sunflower was.
        for (rb, gm) in [(1.5, 0.3), (3.0, 0.6), (4.0, 0.8)] {
            let yellow = SIMD3<Double>(exp2(rb / 2 - gm / 3), exp2(2 * gm / 3), exp2(-rb / 2 - gm / 3))
            for share in [0.25, 0.5, 0.75] {
                for (name, estimate) in variants {
                    var mired: [Double] = [], green: [Double] = []
                    for frame in frames {
                        let light = SIMD3(exp2(frame.truth.x), exp2(frame.truth.y), exp2(frame.truth.z))
                        var surface = light * yellow
                        surface *= 0.18 / (0.2627 * surface.x + 0.678 * surface.y + 0.0593 * surface.z)
                        let w = frame.prepared.gridWidth, h = frame.prepared.gridHeight
                        let radius = (share / Double.pi * 4).squareRoot() / 2
                        let painted = recoloured(frame) { x, y, c in
                            let dx = (Double(x) + 0.5) / Double(w) - 0.5, dy = (Double(y) + 0.5) / Double(h) - 0.5
                            return (dx * dx + dy * dy).squareRoot() < radius ? SIMD3<Float>(surface) : c
                        }
                        let truth = SIMD3<Float>(frame.truth - SIMD3(repeating: frame.truth.sum() / 3))
                        let e = SIMD3<Float>(estimate(painted))
                        mired.append(Double(AutoBalance.mired(e) - AutoBalance.mired(truth)))
                        green.append(Double(AutoBalance.axes(e).greenMagenta - AutoBalance.axes(truth).greenMagenta))
                    }
                    print(String(format: "MEASURE   yellow (%.1f, %+.1f) over %.0f%% of the frame: %@ estimate off the light by %+.0f mired median (90th percentile %+.0f), green %+.2f stops (90th %+.2f)",
                                 rb, gm, share * 100, name, Stats.median(mired), Stats.percentile(mired, 0.9), Stats.median(green), Stats.percentile(green, 0.9)))
                }
            }
        }
    }
}
