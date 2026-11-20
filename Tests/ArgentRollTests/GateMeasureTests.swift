import ArgentCore
import Foundation
import ImageIO
import CoreImage
import Testing
@testable import ArgentRoll

/// The M3 gate's exposure proxy on the FiveK people subset (research-only, local evaluation
/// only; references/corpus/fivek-subset, never committed, never used to fit shipped
/// constants). Each DNG is rendered through Portra 400 at its own auto aim and with no
/// adjustment, and its mean L* is set against all five experts' renditions: a frame passes
/// when it lies inside the experts' envelope widened by one just-noticeable difference
/// (docs/M3-research.md, section 5). Runs only with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 ARGENT_GATE_PROTOCOL=/tmp/protocol.json swift test -c release --filter GateMeasureTests
///
/// Capture a baseline once with ARGENT_GATE_CAPTURE=/tmp/protocol.json. Audited comparisons
/// read that protocol: missing inputs fail, exclusions stay fixed, and face detection cannot
/// change the evaluated regions. The protocol contains restricted derived data; keep it outside Git.
@Suite(.serialized) struct GateMeasureTests {
    typealias M = FrameViewMeasureTests

    static let experts = ["a", "b", "c", "d", "e"]
    /// One just-noticeable difference in L*.
    static let jnd = 2.3
    /// Print brightening, in scene stops against the auto aim, swept to find where a frame
    /// would meet the experts' median.
    static let sweep: [Float] = stride(from: -3, through: 3, by: 0.5).map { Float($0) }

    /// Mean L* and mean linear RGB over a region of a frame.
    struct Region {
        var lightness: Double
        var rgb: SIMD3<Double>
    }

    /// One photo's numbers: whole frame and face, for our auto render, the no-adjustment
    /// baseline and each expert.
    struct Photo {
        var name: String
        var camera: String
        var light: String
        /// The frame's measured level and the bounded level auto printed, in scene stops.
        var meanStops: Double
        var level: Double
        var faceArea: Double
        /// Whether the flash fired, from the DNG's Exif; `nil` when it does not say.
        var flash: Bool?
        var ours: Region
        var base: Region
        /// Our render at the same aim with Lab balance on Neutral, for colour.
        var neutral: Region
        var experts: [Region]
        var oursFace: Region?
        var baseFace: Region?
        var expertFaces: [Region]
        /// Whole-frame and face L* of our render at each brightening in `sweep`.
        var sweepWhole: [Double]
        var sweepFace: [Double]
    }

    static func lightness(_ y: Double) -> Double {
        let v = min(max(y, 0), 1)
        return v > 0.008856 ? 116 * pow(v, 1.0 / 3) - 16 : 903.3 * v
    }

    /// The face's metered inset, as `FaceMeter` meters it, in pixels, rows from the bottom.
    static func inset(_ box: [Float], width: Int, height: Int) -> (xs: Range<Int>, ys: Range<Int>) {
        let w = box[2] * FaceMeter.insetWidth, h = box[3] * FaceMeter.insetHeight
        let cx = box[0] + box[2] / 2, cy = 1 - (box[1] + box[3] / 2)
        let x0 = Int(((cx - w / 2) * Float(width)).rounded()), x1 = Int(((cx + w / 2) * Float(width)).rounded())
        let y0 = Int(((cy - h / 2) * Float(height)).rounded()), y1 = Int(((cy + h / 2) * Float(height)).rounded())
        return (max(0, x0)..<max(max(0, x0), min(width, x1)), max(0, y0)..<max(max(0, y0), min(height, y1)))
    }

    /// Mean per-pixel L* (CIE L* of Rec. 2020 luminance, display-linear) and mean RGB over the
    /// whole frame, or over a face's metered inset.
    static func measure(_ pixels: [Float16], width: Int, height: Int, box: [Float]? = nil,
                        region: GateEvaluationProtocol.Region? = nil) -> Region {
        var xs = 0..<width, ys = 0..<height
        if let region { xs = region.x0..<region.x1; ys = region.y0..<region.y1 }
        else if let box { (xs, ys) = inset(box, width: width, height: height) }
        var sumL = 0.0, sum = SIMD3<Double>(repeating: 0), n = 0.0
        for y in ys {
            for x in xs {
                let i = (y * width + x) * 4
                let rgb = SIMD3<Double>(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                let luminance = 0.2627 * rgb.x + 0.6780 * rgb.y + 0.0593 * rgb.z
                sumL += lightness(luminance)
                sum += rgb
                n += 1
            }
        }
        return n > 0 ? Region(lightness: sumL / n, rgb: sum / n) : Region(lightness: .nan, rgb: .zero)
    }

    /// Red against blue and green against magenta of a mean RGB, in stops.
    static func axes(_ rgb: SIMD3<Double>) -> (redBlue: Double, greenMagenta: Double) {
        let r = log2(max(rgb.x, 1e-6)), g = log2(max(rgb.y, 1e-6)), b = log2(max(rgb.z, 1e-6))
        return (r - b, g - (r + b) / 2)
    }

    /// Exif Flash bit 0, read from the file's header.
    static func flashFired(_ url: URL) -> Bool? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let flash = exif[kCGImagePropertyExifFlash] as? Int else { return nil }
        return flash & 1 == 1
    }

    /// Writes display-linear working-space pixels as an sRGB PNG, for looking at a case.
    static func writePNG(_ pixels: [Float16], width: Int, height: Int, gpu: GPU, to url: URL) throws {
        let data = pixels.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 8, size: CGSize(width: width, height: height),
                            format: .RGBAh, colorSpace: gpu.workingColorSpace)
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height)))
        try gpu.ciContext.writePNGRepresentation(of: image, to: url, format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return .nan }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }

    /// The angle between two RGB directions, in degrees.
    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let dot = (a * b).sum()
        let norms = ((a * a).sum() * (b * b).sum()).squareRoot()
        guard norms > 0 else { return .nan }
        return acos(min(max(dot / norms, -1), 1)) * 180 / .pi
    }

    /// The experts' median colour direction: each expert's mean RGB made unit length, then
    /// the median of each channel.
    static func medianDirection(_ regions: [Region]) -> SIMD3<Double> {
        let units = regions.map { r -> SIMD3<Double> in
            let length = (r.rgb * r.rgb).sum().squareRoot()
            return length > 0 ? r.rgb / length : r.rgb
        }
        return SIMD3(median(units.map(\.x)), median(units.map(\.y)), median(units.map(\.z)))
    }

    /// The camera model from the selection's description: everything before the focal length
    /// or the aperture.
    static func cameraModel(_ description: String) -> String {
        var words: [Substring] = []
        for word in description.split(separator: " ") {
            if word.hasPrefix("F/") { break }
            if word.hasSuffix("mm"), word.dropLast(2).allSatisfy(\.isNumber) { break }
            words.append(word)
        }
        return words.joined(separator: " ")
    }

    /// Where a curve of L* against brightening reaches `target`, by linear interpolation;
    /// clamped to the ends of the sweep.
    static func crossing(_ curve: [Double], target: Double) -> Double {
        let xs = sweep.map(Double.init)
        if target <= curve[0] { return xs[0] }
        for i in 1..<curve.count where curve[i] >= target {
            let t = (target - curve[i - 1]) / max(curve[i] - curve[i - 1], 1e-9)
            return xs[i - 1] + t * (xs[i] - xs[i - 1])
        }
        return xs[xs.count - 1]
    }

    /// L* of a sweep curve at `stops` of brightening, by linear interpolation.
    static func value(_ curve: [Double], at stops: Double) -> Double {
        let xs = sweep.map(Double.init)
        let clamped = min(max(stops, xs[0]), xs[xs.count - 1])
        var i = 1
        while i < xs.count - 1, xs[i] < clamped { i += 1 }
        let t = (clamped - xs[i - 1]) / (xs[i] - xs[i - 1])
        return curve[i - 1] + t * (curve[i] - curve[i - 1])
    }

    static func passes(_ value: Double, _ experts: [Double]) -> Bool {
        guard let low = experts.min(), let high = experts.max(), value.isFinite else { return false }
        return value >= low - jnd && value <= high + jnd
    }

    static func rate(_ flags: [Bool]) -> String {
        let n = flags.filter { $0 }.count
        return String(format: "%d/%d (%.0f%%)", n, flags.count, 100 * Double(n) / Double(max(flags.count, 1)))
    }

    static func stats(_ values: [Double], digits: Int = 1) -> String {
        let s = values.sorted()
        guard !s.isEmpty else { return "n=0" }
        let f = "%+.\(digits)f"
        return String(format: "median \(f), mean \(f), min \(f), max \(f) (n=%d)", median(s), mean(s), s.first!, s.last!, s.count)
    }

    /// Skin as the second light estimate on one photo (docs/M3-auto.md section 16), evaluation
    /// only: the colour Auto leaves on the face and on the pixels every expert printed neutral,
    /// with the skin estimate and without, against the experts' median.
    struct SkinCase {
        var name: String
        var moved: Bool
        /// Display stops, red against blue and green against magenta, of our face minus the
        /// experts' median face, with skin and without.
        var face: [(redBlue: Double, greenMagenta: Double)]
        /// The same for the experts' neutrals, our colour there against neutral and the experts'
        /// own median there; nil when too few pixels are neutral in every rendition.
        var neutral: [(redBlue: Double, greenMagenta: Double)]?
        var neutralPixels: Int
    }

    /// The mean colour of the pixels every expert rendered within `limit` stops of neutral on both
    /// axes, between L* 20 and 90, for ours and the experts: display-linear RGB.
    static func expertNeutrals(_ ours: [Float16], experts: [[Float16]], limit: Double = 0.1) -> (ours: SIMD3<Double>, experts: SIMD3<Double>, count: Int) {
        var sumOurs = SIMD3<Double>(repeating: 0), sumExperts = SIMD3<Double>(repeating: 0), count = 0
        for i in stride(from: 0, to: ours.count, by: 4) {
            var neutral = true, mean = SIMD3<Double>(repeating: 0)
            for e in experts {
                let rgb = SIMD3(Double(e[i]), Double(e[i + 1]), Double(e[i + 2]))
                let l = lightness(0.2627 * rgb.x + 0.6780 * rgb.y + 0.0593 * rgb.z)
                let a = axes(rgb)
                if rgb.min() <= 0 || l < 20 || l > 90 || abs(a.redBlue) > limit || abs(a.greenMagenta) > limit { neutral = false; break }
                mean += rgb
            }
            guard neutral else { continue }
            sumOurs += SIMD3(Double(ours[i]), Double(ours[i + 1]), Double(ours[i + 2]))
            sumExperts += mean / Double(experts.count)
            count += 1
        }
        return (sumOurs / Double(max(count, 1)), sumExperts / Double(max(count, 1)), count)
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func exposureGateOnFiveK() throws {
        var skinCases: [SkinCase] = []
        let clock = ContinuousClock()
        let runStart = clock.now
        let folder = M.root.appendingPathComponent("references/corpus/fivek-subset")
        let environment = ProcessInfo.processInfo.environment
        let protocolURL = environment["ARGENT_GATE_PROTOCOL"].map { URL(fileURLWithPath: $0) }
        let captureURL = environment["ARGENT_GATE_CAPTURE"].map { URL(fileURLWithPath: $0) }
        try #require(protocolURL == nil || captureURL == nil, "choose protocol replay or capture, not both")
        if let captureURL {
            try #require(!captureURL.resolvingSymlinksInPath().path.hasPrefix(M.root.path + "/"), "keep restricted protocol data outside the repository")
            try #require(!FileManager.default.fileExists(atPath: captureURL.path), "a captured protocol cannot be overwritten")
        }
        let locked = try protocolURL.map(GateEvaluationProtocol.read)
        let selection = try String(contentsOf: folder.appendingPathComponent("_meta/selection.tsv"), encoding: .utf8)
        var info: [String: (camera: String, light: String)] = [:]
        for line in selection.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }
            try #require(info[fields[1]] == nil, "duplicate selection entry")
            info[fields[1]] = (Self.cameraModel(fields[6]), fields[3])
        }
        let names = info.keys.sorted()
        try #require(!names.isEmpty, "FiveK selection is empty")
        var captured = GateEvaluationProtocol(inputs: names)
        if let locked {
            try locked.validateInventory(names, label: "selection")
            for (directory, suffix) in [("dng", ".dng")] + Self.experts.map({ ("tiff16_\($0)", ".tif") }) {
                let inventory = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(directory).path)
                    .filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }
                try locked.validateInventory(inventory, label: directory)
            }
            print("MEASURE gate protocol locked: \(locked.frames.count) included, \(locked.frames.filter { $0.face != nil }.count) faces, \(locked.exclusions.count) exclusions, JND \(locked.jnd)")
        } else {
            print("MEASURE gate protocol \(captureURL == nil ? "UNLOCKED diagnostic" : "baseline capture")")
        }
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let flip = CGAffineTransform(scaleX: 1, y: -1)

        func logLuminance(_ p: [Float16]) -> [Double] {
            stride(from: 0, to: p.count, by: 4).map { i in
                log2(max(0.2627 * Double(p[i]) + 0.6780 * Double(p[i + 1]) + 0.0593 * Double(p[i + 2]), 1e-4))
            }
        }
        func correlation(_ a: [Double], _ b: [Double]) -> Double {
            let ma = Self.mean(a), mb = Self.mean(b)
            var ab = 0.0, aa = 0.0, bb = 0.0
            for i in a.indices {
                ab += (a[i] - ma) * (b[i] - mb)
                aa += (a[i] - ma) * (a[i] - ma)
                bb += (b[i] - mb) * (b[i] - mb)
            }
            return ab / (aa * bb).squareRoot()
        }
        /// An expert's rendition at the decode's size as linear working-space light, upright
        /// and whichever way up correlates best with the decode. Each side is scaled to the
        /// decode's exactly, so no row of the pooled texture is left from an earlier render.
        func aligned(_ url: URL, ours: [Double], width: Int, height: Int, orientation: Int?) throws -> (pixels: [Float16], r: Double, orientation: Int)? {
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
            let scaleX = Double(width) / Double(image.extent.width)
            let scaleY = Double(height) / Double(image.extent.height)
            guard abs(scaleY - scaleX) < 0.02 else { return nil }
            let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scaleY,
                                                                        kCIInputAspectRatioKey: scaleX / scaleY])
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let flipped = scaled.transformed(by: flip.translatedBy(x: 0, y: -scaled.extent.height))
            var best: (pixels: [Float16], r: Double, orientation: Int)?
            for (index, candidate) in [scaled, flipped].enumerated() where orientation == nil || orientation == index {
                let texture = try gpu.texturePool.acquire(width: width, height: height)
                let buffer = try #require(gpu.queue.makeCommandBuffer())
                gpu.ciContext.render(candidate, to: texture.texture, commandBuffer: buffer, bounds: candidate.extent,
                                     colorSpace: gpu.workingColorSpace)
                buffer.commit()
                buffer.waitUntilCompleted()
                let pixels = ExposureAnalyzer.pixels(of: texture.texture)
                let r = correlation(ours, logLuminance(pixels))
                if best == nil || r > best!.r { best = (pixels, r, index) }
            }
            return best
        }

        var photos: [Photo] = []
        var skipped: [String] = []
        var photoTimes: [Double] = []
        func exclude(_ name: String, _ reason: String) throws {
            try #require(locked == nil, "locked included frame \(name) cannot be excluded: \(reason)")
            captured.exclusions[name] = reason
            skipped.append("\(name): \(reason)")
        }
        /// Evaluates one photo, appending what it measured; a photo it cannot evaluate is excluded.
        func evaluate(_ name: String) throws {
            if let reason = locked?.exclusions[name] {
                skipped.append("\(name): \(reason) [locked exclusion]")
                return
            }
            let lockedFrame = locked?.frames.first { $0.name == name }
            let photoStart = clock.now
            let tiffs = Self.experts.map { folder.appendingPathComponent("tiff16_\($0)/\(name).tif") }
            guard tiffs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                try exclude(name, "missing an expert"); return }
            let dng = folder.appendingPathComponent("dng/\(name).dng")
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            guard let frame = try? decoder.decode(dng, options: options) else { try exclude(name, "no decode"); return }
            let width = frame.width, height = frame.height
            try lockedFrame?.validateDimensions(width: width, height: height)
            // ARGENT_ANALYSIS=before measures as the analysis did before 2026-10-07 (docs/M3-auto.md
            // section 16); the frame's header gives the body and ISO for the decoder's noise.
            let header = try? ARWFrameInfo.read(from: dng)
            let analysis = ProcessInfo.processInfo.environment["ARGENT_ANALYSIS"] == "before"
                ? ExposureAnalyzer.analyzeAsBefore(frame, workingSpace: gpu.workingColorSpace)
                : ExposureAnalyzer.analyze(frame, workingSpace: gpu.workingColorSpace, info: header)
            let decoded = logLuminance(ExposureAnalyzer.pixels(of: frame.texture))

            var expertPixels: [[Float16]] = []
            var rs: [Double] = []
            var orientations: [Int] = []
            for (index, tiff) in tiffs.enumerated() {
                guard let match = try aligned(tiff, ours: decoded, width: width, height: height,
                                              orientation: lockedFrame?.orientations[index]), match.r > 0.5 else { break }
                expertPixels.append(match.pixels)
                rs.append(match.r)
                orientations.append(match.orientation)
            }
            guard expertPixels.count == Self.experts.count else {
                try exclude(name, "expert \(Self.experts[expertPixels.count]) does not line up"); return }

            let face = analysis.faces.max(by: { $0.area < $1.area })
            let evaluationFace = GateEvaluationProtocol.evaluationFace(locked: lockedFrame, detected: face,
                                                                       width: width, height: height)
            captured.frames.append(.init(name: name, width: width, height: height, orientations: orientations, face: evaluationFace))
            // The aim's level is the a7 IV's; ARGENT_GATE_AIM_OFFSET gives FiveK's cameras their own
            // intercept, as the fit did (docs/research/auto/balance-research.md, section 7c).
            let aimOffset = ProcessInfo.processInfo.environment["ARGENT_GATE_AIM_OFFSET"].flatMap(Float.init) ?? 0
            let level = min(max(AutoPrint.levelStops(analysis) + aimOffset, -AutoPrint.bound), AutoPrint.bound)
            let cast = AutoBalance.cast(analysis)
            let toneStrengths = FittedTone.strengths(analysis)
            let burn = toneStrengths.burn, dodge = toneStrengths.dodge
            let auto = RollControls(labBalance: .auto)
            func render(_ settings: DevelopSettings) throws -> [Float16] {
                ExposureAnalyzer.pixels(of: try renderer.render(frame, settings: settings).image.texture)
            }
            let oursPixels = try render(auto.settings(for: stock, aim: PrintAim(level: level, cast: cast, burn: burn, dodge: dodge)))
            let neutralPixels = try render(RollControls(labBalance: .neutral).settings(for: stock, aim: PrintAim(level: level, cast: cast, burn: burn, dodge: dodge)))
            let basePixels = try render(RollControls(labBalance: .neutral).settings(for: stock, aim: PrintAim()))
            var sweepWhole: [Double] = [], sweepFace: [Double] = []
            for stops in Self.sweep {
                let pixels = try render(auto.settings(for: stock, aim: PrintAim(level: level - stops, cast: cast)))
                sweepWhole.append(Self.measure(pixels, width: width, height: height).lightness)
                if let evaluationFace { sweepFace.append(Self.measure(pixels, width: width, height: height, region: evaluationFace.region).lightness) }
            }

            let meta = info[name] ?? ("?", "?")
            var photo = Photo(name: name, camera: meta.camera, light: meta.light, meanStops: Double(analysis.meanStops),
                              level: Double(level), faceArea: evaluationFace?.region.area(width: width, height: height) ?? 0, flash: Self.flashFired(dng),
                              ours: Self.measure(oursPixels, width: width, height: height),
                              base: Self.measure(basePixels, width: width, height: height),
                              neutral: Self.measure(neutralPixels, width: width, height: height),
                              experts: expertPixels.map { Self.measure($0, width: width, height: height) },
                              oursFace: nil, baseFace: nil, expertFaces: [], sweepWhole: sweepWhole, sweepFace: sweepFace)
            if let evaluationFace {
                photo.oursFace = Self.measure(oursPixels, width: width, height: height, region: evaluationFace.region)
                photo.baseFace = Self.measure(basePixels, width: width, height: height, region: evaluationFace.region)
                photo.expertFaces = expertPixels.map { Self.measure($0, width: width, height: height, region: evaluationFace.region) }
            }
            photos.append(photo)
            // Skin, evaluation only: the same aim with the skin estimate's weight at 0.
            if let evaluationFace, SkinBalance.skin(analysis) != nil {
                let plain = AutoBalance.cast(analysis, skinWeight: 0)
                let plainPixels = try render(auto.settings(for: stock, aim: PrintAim(level: level, cast: plain, burn: burn, dodge: dodge)))
                let expertFace = Self.medianDirection(photo.expertFaces)
                func faceOffset(_ pixels: [Float16]) -> (redBlue: Double, greenMagenta: Double) {
                    let ours = Self.axes(Self.measure(pixels, width: width, height: height, region: evaluationFace.region).rgb), them = Self.axes(expertFace)
                    return (ours.redBlue - them.redBlue, ours.greenMagenta - them.greenMagenta)
                }
                let withSkin = Self.expertNeutrals(oursPixels, experts: expertPixels)
                let withoutSkin = Self.expertNeutrals(plainPixels, experts: expertPixels)
                var neutral: [(redBlue: Double, greenMagenta: Double)]?
                if withSkin.count >= 200 {
                    neutral = [Self.axes(withSkin.ours), Self.axes(withoutSkin.ours), Self.axes(withSkin.experts)]
                }
                let pull = SkinBalance.pull(analysis, cast: plain) ?? 0
                skinCases.append(SkinCase(name: name, moved: pull != 0, face: [faceOffset(oursPixels), faceOffset(plainPixels)],
                                          neutral: neutral, neutralPixels: withSkin.count))
            }
            if let directory = ProcessInfo.processInfo.environment["ARGENT_GATE_PNG"] {
                let images = [("ours", oursPixels), ("base", basePixels)] + zip(Self.experts, expertPixels).map { ("expert-\($0)", $1) }
                for (label, pixels) in images {
                    try Self.writePNG(pixels, width: width, height: height, gpu: gpu,
                                      to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(label).png"))
                }
            }
            let neutral = photo.neutral
            photoTimes.append(M.ms(clock.now - photoStart))

            let el = photo.experts.map(\.lightness)
            let direction = Self.medianDirection(photo.experts)
            var line = String(format: "MEASURE gate %@ [%@, %@, flash %@] r %.2f-%.2f, %.1f s; level %+.2f (frame %+.2f, face %@), cast %+.0f mired",
                              name, photo.camera, photo.light, photo.flash.map { $0 ? "yes" : "no" } ?? "-", rs.min()!, rs.max()!,
                              photoTimes.last! / 1000, level, analysis.meanStops,
                              face.map { String(format: "%+.2f", $0.levelStops) } ?? "-", AutoBalance.mired(cast))
            line += String(format: "; whole L* ours %.1f base %.1f experts %.1f..%.1f (median %.1f) %@",
                           photo.ours.lightness, photo.base.lightness, el.min()!, el.max()!, Self.median(el),
                           Self.passes(photo.ours.lightness, el) ? "PASS" : "fail")
            line += String(format: "; needs %+.2f stops", Self.crossing(sweepWhole, target: Self.median(el)))
            if evaluationFace != nil, let oursFace = photo.oursFace {
                let fl = photo.expertFaces.map(\.lightness)
                line += String(format: "; face %.1f%% L* ours %.1f base %.1f experts %.1f..%.1f (median %.1f) %@",
                               photo.faceArea * 100, oursFace.lightness, photo.baseFace!.lightness, fl.min()!, fl.max()!, Self.median(fl),
                               Self.passes(oursFace.lightness, fl) ? "PASS" : "fail")
            } else {
                line += "; no face"
            }
            let expertRB = Self.median(photo.experts.map { Self.axes($0.rgb).redBlue })
            line += String(format: "; red-blue against experts' median: auto %+.2f, neutral %+.2f stops",
                           Self.axes(photo.ours.rgb).redBlue - expertRB, Self.axes(neutral.rgb).redBlue - expertRB)
            line += String(format: "; colour angle to experts' median: auto %.1f°, neutral %.1f°, experts %.1f..%.1f°",
                           Self.angle(photo.ours.rgb, direction), Self.angle(neutral.rgb, direction),
                           photo.experts.map { Self.angle($0.rgb, direction) }.min()!,
                           photo.experts.map { Self.angle($0.rgb, direction) }.max()!)
            print(line)
        }
        for name in names {
            // Each photo drains its own autorelease pool, so Core Image's and Metal's objects go before the
            // next one; this thread's pool otherwise empties only when the test ends (about 290 MB a photo).
            try autoreleasepool(invoking: { try evaluate(name) })
        }
        try #require(!photos.isEmpty, "no FiveK frames evaluated")
        try #require(photos.contains { $0.oursFace != nil }, "no FiveK faces evaluated")
        if let locked {
            try #require(photos.count == locked.frames.count)
            try #require(photos.filter { $0.oursFace != nil }.count == locked.frames.filter { $0.face != nil }.count)
        }
        if let captureURL { try captured.write(captureURL) }
        Self.summarize(photos)
        Self.summarizeSkin(skinCases)
        for s in skipped { print("MEASURE gate skipped \(s)") }
        print("MEASURE gate per photo: \(M.summary(photoTimes))")
        print(String(format: "MEASURE gate run: %.1f s for %d photos", M.ms(clock.now - runStart) / 1000, names.count))
    }

    /// The gate's numbers over every photo that lined up with all five experts.
    static func summarize(_ photos: [Photo]) {
        let faced = photos.filter { $0.oursFace != nil }
        print("MEASURE gate: \(photos.count) photos with all five experts lined up, \(faced.count) with a face")

        // The experts' own spread, to set against the research's 3.3 L* mean and 23.5 at most.
        let wholeSpread = photos.map { p in p.experts.map(\.lightness).max()! - p.experts.map(\.lightness).min()! }
        let faceSpread = faced.map { p in p.expertFaces.map(\.lightness).max()! - p.expertFaces.map(\.lightness).min()! }
        let pairwise = photos.flatMap { p -> [Double] in
            let l = p.experts.map(\.lightness)
            return l.indices.flatMap { i in (i + 1..<l.count).map { abs(l[i] - l[$0]) } }
        }
        print(String(format: "MEASURE gate experts' spread (max - min), whole frame: mean %.1f, median %.1f, max %.1f L*; pairwise |difference| mean %.1f, max %.1f",
                     mean(wholeSpread), median(wholeSpread), wholeSpread.max() ?? 0, mean(pairwise), pairwise.max() ?? 0))
        print(String(format: "MEASURE gate experts' spread (max - min), face: mean %.1f, median %.1f, max %.1f L*",
                     mean(faceSpread), median(faceSpread), faceSpread.max() ?? 0))

        func wholeL(_ p: Photo) -> [Double] { p.experts.map(\.lightness) }
        func faceL(_ p: Photo) -> [Double] { p.expertFaces.map(\.lightness) }
        let oursOffset = photos.map { $0.ours.lightness - median(wholeL($0)) }
        let baseOffset = photos.map { $0.base.lightness - median(wholeL($0)) }
        let oursFaceOffset = faced.map { $0.oursFace!.lightness - median(faceL($0)) }
        let baseFaceOffset = faced.map { $0.baseFace!.lightness - median(faceL($0)) }
        let expertOffset = photos.flatMap { p in wholeL(p).map { $0 - median(wholeL(p)) } }

        print("MEASURE gate pass, whole frame: auto \(rate(photos.map { passes($0.ours.lightness, wholeL($0)) })), no adjustment \(rate(photos.map { passes($0.base.lightness, wholeL($0)) }))")
        print("MEASURE gate pass, face: auto \(rate(faced.map { passes($0.oursFace!.lightness, faceL($0)) })), no adjustment \(rate(faced.map { passes($0.baseFace!.lightness, faceL($0)) }))")
        // A human baseline for the 90 percent (docs/research/rolls.md): each expert against the
        // envelope of the other four, and auto and no adjustment against the same four-expert
        // envelopes, every photo once per left-out expert.
        func leaveOneOut(_ group: [Photo], _ experts: (Photo) -> [Double], _ ours: (Photo) -> Double, _ base: (Photo) -> Double) -> String {
            var expert: [Bool] = [], auto: [Bool] = [], none: [Bool] = []
            for p in group {
                let l = experts(p)
                for k in l.indices {
                    let others = l.enumerated().filter { $0.offset != k }.map(\.element)
                    expert.append(passes(l[k], others))
                    auto.append(passes(ours(p), others))
                    none.append(passes(base(p), others))
                }
            }
            return "an expert \(rate(expert)), auto \(rate(auto)), no adjustment \(rate(none))"
        }
        print("MEASURE gate [evaluation only] leave one expert out, inside the other four's envelope plus one JND, whole frame: "
              + leaveOneOut(photos, wholeL, { $0.ours.lightness }, { $0.base.lightness }))
        print("MEASURE gate [evaluation only] leave one expert out, face: "
              + leaveOneOut(faced, faceL, { $0.oursFace!.lightness }, { $0.baseFace!.lightness }))
        print("MEASURE gate offset from the experts' median, whole frame, auto: \(stats(oursOffset))")
        print("MEASURE gate offset from the experts' median, whole frame, no adjustment: \(stats(baseOffset))")
        print("MEASURE gate offset from the experts' median, face, auto: \(stats(oursFaceOffset))")
        print("MEASURE gate offset from the experts' median, face, no adjustment: \(stats(baseFaceOffset))")
        print(String(format: "MEASURE gate mean |offset|, whole frame: auto %.1f, no adjustment %.1f, an expert %.1f L*",
                     mean(oursOffset.map(abs)), mean(baseOffset.map(abs)), mean(expertOffset.map(abs))))
        let counted = faced.filter { Float($0.faceArea) >= AutoPrint.minimumFaceArea }
        print("MEASURE gate pass, faces of at least 1.5% of the frame (those auto weighs): auto \(rate(counted.map { passes($0.oursFace!.lightness, faceL($0)) })), no adjustment \(rate(counted.map { passes($0.baseFace!.lightness, faceL($0)) }))")
        print("MEASURE gate experts' mean |expert - their median|, whole frame: \(String(format: "%.1f", mean(expertOffset.map(abs)))) L*")
        for (index, expert) in experts.enumerated() {
            let whole = photos.map { $0.ours.lightness - $0.experts[index].lightness }
            let face = faced.map { $0.oursFace!.lightness - $0.expertFaces[index].lightness }
            print(String(format: "MEASURE gate auto minus expert %@: whole median %+.1f, face median %+.1f L*", expert, median(whole), median(face)))
        }

        // Evaluation only, not a shipped constant: the same test after removing one global
        // offset, so relative placement is judged apart from the a7 IV anchor.
        let wholeShift = median(oursOffset), faceShift = median(oursFaceOffset)
        let baseShift = median(baseOffset)
        func spreadAfter(_ offsets: [Double]) -> Double {
            let m = mean(offsets)
            return (offsets.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(max(offsets.count - 1, 1))).squareRoot()
        }
        print(String(format: "MEASURE gate [evaluation only, not a shipped constant] global L* offset removed (whole %+.1f, face %+.1f, baseline %+.1f): whole %@, face %@, no adjustment whole %@",
                     wholeShift, faceShift, baseShift,
                     rate(photos.map { passes($0.ours.lightness - wholeShift, wholeL($0)) }),
                     rate(faced.map { passes($0.oursFace!.lightness - faceShift, faceL($0)) }),
                     rate(photos.map { passes($0.base.lightness - baseShift, wholeL($0)) })))
        print(String(format: "MEASURE gate standard deviation of the offset (relative placement): auto whole %.1f, face %.1f; no adjustment whole %.1f, face %.1f L*",
                     spreadAfter(oursOffset), spreadAfter(oursFaceOffset), spreadAfter(baseOffset), spreadAfter(baseFaceOffset)))
        let needed = photos.map { crossing($0.sweepWhole, target: median(wholeL($0))) }
        let neededFace = faced.map { crossing($0.sweepFace, target: median(faceL($0))) }
        let stops = median(needed)
        print("MEASURE gate print brightening to meet the experts' median, whole frame, in scene stops: \(stats(needed, digits: 2))")
        print("MEASURE gate the same for the face: \(stats(neededFace, digits: 2))")
        print(String(format: "MEASURE gate [evaluation only, not a shipped constant] every frame printed %+.2f stops brighter: whole %@, face %@",
                     stops, rate(photos.map { passes(value($0.sweepWhole, at: stops), wholeL($0)) }),
                     rate(faced.map { passes(value($0.sweepFace, at: stops), faceL($0)) })))

        // Evaluation only: how much of its level a frame's print should follow. Printing at
        // k times the bounded level is (1 - k) * level stops brighter than auto.
        for k in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let whole = photos.map { passes(value($0.sweepWhole, at: (1 - k) * $0.level), wholeL($0)) }
            let face = faced.map { passes(value($0.sweepFace, at: (1 - k) * $0.level), faceL($0)) }
            let lifts = photos.filter { $0.level < 0 }.map { passes(value($0.sweepWhole, at: (1 - k) * $0.level), wholeL($0)) }
            let darkens = photos.filter { $0.level > 0 }.map { passes(value($0.sweepWhole, at: (1 - k) * $0.level), wholeL($0)) }
            print(String(format: "MEASURE gate [evaluation only] print follows %.2f of the bounded level: whole %@, face %@; lifted frames %@, darkened %@",
                         k, rate(whole), rate(face), rate(lifts), rate(darkens)))
        }
        // Evaluation only: lifts and darkenings followed by different shares, and no lift on a
        // frame whose flash fired (its subject was lit; the dark is the background).
        func follow(_ p: Photo, lift: Double, darken: Double, flashHolds: Bool) -> Double {
            if p.level < 0, flashHolds, p.flash == true { return p.level }
            return (1 - (p.level < 0 ? lift : darken)) * p.level
        }
        for (lift, flashHolds) in [(1.0, true), (0.5, false), (0.25, false), (0.5, true), (0.25, true)] {
            print(String(format: "MEASURE gate [evaluation only] lifts follow %.2f, darkenings 1.00%@: whole %@, face %@", lift,
                         flashHolds ? ", no lift with flash" : "",
                         rate(photos.map { passes(value($0.sweepWhole, at: follow($0, lift: lift, darken: 1, flashHolds: flashHolds)), wholeL($0)) }),
                         rate(faced.map { passes(value($0.sweepFace, at: follow($0, lift: lift, darken: 1, flashHolds: flashHolds)), faceL($0)) })))
        }
        let flashLifted = photos.filter { $0.level < 0 && $0.flash == true }
        print("MEASURE gate lifted frames with flash: \(flashLifted.count), auto passes \(rate(flashLifted.map { passes($0.ours.lightness, wholeL($0)) })), no adjustment \(rate(flashLifted.map { passes($0.base.lightness, wholeL($0)) }))")

        // The aim that would meet the experts' median against what the frame measured.
        let pairs = photos.map { ($0.meanStops, $0.level - crossing($0.sweepWhole, target: median(wholeL($0)))) }
        let mx = mean(pairs.map(\.0)), my = mean(pairs.map(\.1))
        let sxy = pairs.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +), sxx = pairs.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        let syy = pairs.map { ($0.1 - my) * ($0.1 - my) }.reduce(0, +)
        print(String(format: "MEASURE gate [evaluation only] aim meeting the experts' median = %+.2f + %.2f * measured level (r %.2f, n=%d)",
                     my - sxy / sxx * mx, sxy / sxx, sxy / (sxx * syy).squareRoot(), pairs.count))

        // Per camera model with three or more photos, each with its own offset.
        let cameras = Dictionary(grouping: photos, by: \.camera).filter { $0.value.count >= 3 }
        for (camera, group) in cameras.sorted(by: { $0.key < $1.key }) {
            let offsets = group.map { $0.ours.lightness - median(wholeL($0)) }
            let shift = median(offsets)
            let cameraStops = median(group.map { crossing($0.sweepWhole, target: median(wholeL($0))) })
            let gFaced = group.filter { $0.oursFace != nil }
            let faceShiftHere = median(gFaced.map { $0.oursFace!.lightness - median(faceL($0)) })
            print(String(format: "MEASURE gate camera %@ (%d, %d faces): offset %+.1f L*, needs %+.2f stops; pass whole %@ -> %@ [own L* offset removed, evaluation only] -> %@ [own stops], face %@ -> %@",
                         camera, group.count, gFaced.count, shift, cameraStops,
                         rate(group.map { passes($0.ours.lightness, wholeL($0)) }),
                         rate(group.map { passes($0.ours.lightness - shift, wholeL($0)) }),
                         rate(group.map { passes(value($0.sweepWhole, at: cameraStops), wholeL($0)) }),
                         rate(gFaced.map { passes($0.oursFace!.lightness, faceL($0)) }),
                         rate(gFaced.map { passes($0.oursFace!.lightness - faceShiftHere, faceL($0)) })))
        }
        // Every photo with its camera's own offset removed where the camera has three or
        // more photos, and the global one elsewhere.
        func cameraShift(_ p: Photo) -> Double {
            guard let group = cameras[p.camera] else { return wholeShift }
            return median(group.map { $0.ours.lightness - median(wholeL($0)) })
        }
        print("MEASURE gate [evaluation only] per-camera L* offset removed (global for cameras under 3): whole \(rate(photos.map { passes($0.ours.lightness - cameraShift($0), wholeL($0)) }))")

        // Per lighting class, as the research asks the gate to be reported.
        for (light, group) in Dictionary(grouping: photos, by: \.light).sorted(by: { $0.key < $1.key }) {
            print("MEASURE gate light \(light) (\(group.count)): pass whole \(rate(group.map { passes($0.ours.lightness, wholeL($0)) })), with the global offset removed \(rate(group.map { passes($0.ours.lightness - wholeShift, wholeL($0)) })), no adjustment \(rate(group.map { passes($0.base.lightness, wholeL($0)) }))")
        }

        // Colour, a proxy only: FiveK has no measured light, so this is the angle between
        // the whole frame's mean RGB and the experts' median direction, film look included.
        let autoAngles = photos.map { angle($0.ours.rgb, medianDirection($0.experts)) }
        let neutralAngles = photos.map { angle($0.neutral.rgb, medianDirection($0.experts)) }
        let expertAngles = photos.flatMap { p in p.experts.map { angle($0.rgb, medianDirection(p.experts)) } }
        func within(_ v: [Double]) -> String { rate(v.map { $0 <= 3 }) }
        print(String(format: "MEASURE gate colour proxy, angle of the mean RGB to the experts' median: auto median %.1f°, mean %.1f°, max %.1f°, within 3° %@",
                     median(autoAngles), mean(autoAngles), autoAngles.max() ?? 0, within(autoAngles)))
        print(String(format: "MEASURE gate colour proxy: neutral median %.1f°, mean %.1f°, max %.1f°, within 3° %@; an expert median %.1f°, mean %.1f°, max %.1f°, within 3° %@",
                     median(neutralAngles), mean(neutralAngles), neutralAngles.max() ?? 0, within(neutralAngles),
                     median(expertAngles), mean(expertAngles), expertAngles.max() ?? 0, within(expertAngles)))
        let autoRB = photos.map { p in axes(p.ours.rgb).redBlue - median(p.experts.map { axes($0.rgb).redBlue }) }
        let neutralRB = photos.map { p in axes(p.neutral.rgb).redBlue - median(p.experts.map { axes($0.rgb).redBlue }) }
        let autoGM = photos.map { p in axes(p.ours.rgb).greenMagenta - median(p.experts.map { axes($0.rgb).greenMagenta }) }
        let neutralGM = photos.map { p in axes(p.neutral.rgb).greenMagenta - median(p.experts.map { axes($0.rgb).greenMagenta }) }
        print("MEASURE gate colour proxy, red against blue minus the experts' median, display stops: auto \(stats(autoRB, digits: 2)); neutral \(stats(neutralRB, digits: 2))")
        print("MEASURE gate colour proxy, green against magenta minus the experts' median: auto \(stats(autoGM, digits: 2)); neutral \(stats(neutralGM, digits: 2))")
        let better = zip(autoAngles, neutralAngles).filter { $0.0 < $0.1 }.count
        print("MEASURE gate colour proxy: auto closer than neutral on \(better) of \(photos.count)")
    }
    static func summarizeSkin(_ cases: [SkinCase]) {
        print("MEASURE gate skin [evaluation only]: \(cases.count) photos whose faces' skin counts, \(cases.filter(\.moved).count) moved by it")
        for c in cases {
            var line = String(format: "MEASURE gate skin %@%@: face minus the experts' median face, red-blue %+.3f -> %+.3f, green-magenta %+.3f -> %+.3f (without -> with skin)",
                              c.name, c.moved ? "" : " (not moved)", c.face[1].redBlue, c.face[0].redBlue, c.face[1].greenMagenta, c.face[0].greenMagenta)
            if let n = c.neutral {
                line += String(format: "; experts' neutrals (%d px): ours %+.3f, %+.3f -> %+.3f, %+.3f; experts there %+.3f, %+.3f",
                               c.neutralPixels, n[1].redBlue, n[1].greenMagenta, n[0].redBlue, n[0].greenMagenta, n[2].redBlue, n[2].greenMagenta)
            }
            print(line)
        }
        let moved = cases.filter(\.moved)
        func meanAbs(_ v: [Double]) -> Double { mean(v.map(abs)) }
        if !moved.isEmpty {
            print(String(format: "MEASURE gate skin, moved photos: face mean |red-blue| %.3f -> %.3f, |green-magenta| %.3f -> %.3f display stops",
                         meanAbs(moved.map { $0.face[1].redBlue }), meanAbs(moved.map { $0.face[0].redBlue }),
                         meanAbs(moved.map { $0.face[1].greenMagenta }), meanAbs(moved.map { $0.face[0].greenMagenta })))
            let n = moved.compactMap(\.neutral)
            print(String(format: "MEASURE gate skin, moved photos with experts' neutrals (%d): ours minus the experts there, mean |red-blue| %.3f -> %.3f, |green-magenta| %.3f -> %.3f",
                         n.count, meanAbs(n.map { $0[1].redBlue - $0[2].redBlue }), meanAbs(n.map { $0[0].redBlue - $0[2].redBlue }),
                         meanAbs(n.map { $0[1].greenMagenta - $0[2].greenMagenta }), meanAbs(n.map { $0[0].greenMagenta - $0[2].greenMagenta })))
        }
    }
}
