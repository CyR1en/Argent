import ArgentCore
import CoreImage
import Foundation
import Metal
import Testing
@testable import ArgentRoll

/// Auto lab balance against measured light, behind docs/M3-auto.md section 12. Runs only with
/// ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter LabBalanceMeasureTests
///
/// The data is Cube++ (Ershov et al., IEEE Access 2020; Zenodo record 4153431; CC BY 4.0),
/// git-ignored under references/corpus/cubepp: the raw CR2 files of the 2,234 single-light
/// SimpleCube++ scenes, fetched member by member out of the source_CR2_*.zip archives, and the
/// archives' markup (the SpyderCube's faces) and SimpleCube++'s train and test split
/// (references/corpus/scripts/fetch_cubepp_cr2.sh; 1,597 of the 2,234 were fetched).
/// `prepare` decodes each CR2 exactly as the contact sheet does and keeps two things: the light
/// measured on the cube's two gray faces in that decode, which is the truth in Argent's own
/// working space with no camera matrix, and the samples the analysis reads, with the cube
/// masked out. `measure` then needs no raw file.
@Suite(.serialized) struct LabBalanceMeasureTests {
    typealias M = FrameViewMeasureTests

    static let corpus = M.root.appendingPathComponent("references/corpus/cubepp")
    /// Where `prepare` writes and `measure` reads, ARGENT_CUBEPP_CACHE when set; the raw files
    /// `prepare` reads, ARGENT_CUBEPP_CR2 when set.
    static var cache: URL {
        ProcessInfo.processInfo.environment["ARGENT_CUBEPP_CACHE"].map { URL(fileURLWithPath: $0) } ?? corpus.appendingPathComponent("cache")
    }
    static var rawFolder: URL {
        ProcessInfo.processInfo.environment["ARGENT_CUBEPP_CR2"].map { URL(fileURLWithPath: $0) } ?? corpus.appendingPathComponent("cr2")
    }
    /// Whether `loadFrames` reads each frame's grid as the shipped analysis reads it, each sample
    /// its cell's mean light (ARGENT_CUBEPP_GRID=cells, written by `prepare` since 2026-10-07), or
    /// one pixel a sample as before.
    static var cellGrids: Bool { ProcessInfo.processInfo.environment["ARGENT_CUBEPP_GRID"] == "cells" }

    /// The retained point cohort and the separately prepared cell cohort in the dated protocol.
    /// Changing the evaluation cohort requires a new documented baseline, not silent omissions.
    /// With ARGENT_CUBEPP_COHORT, a file of frame ids one per line, the cohort is that list
    /// (docs/M3-auto.md section 42: all 2,234 since 2026-10-18), and every listed frame must load.
    static var expectedFrameCount: Int { cohort?.count ?? (cellGrids ? 473 : 1_597) }

    /// The frame ids ARGENT_CUBEPP_COHORT lists; `nil` without it.
    static var cohort: Set<String>? {
        guard let path = ProcessInfo.processInfo.environment["ARGENT_CUBEPP_COHORT"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// What `prepare` keeps of a frame besides its samples.
    struct Prepared: Codable {
        var id: String
        var width: Int
        var height: Int
        /// Each gray face's mean RGB in the decode, left and right.
        var grayFaces: [[Double]]
        var grayPixels: [Int]
        /// The faces' brightest channel against the frame's brightest value.
        var grayPeak: Double
        var whiteFaces: [[Double]]
        var asShotTemperature: Float?
        var asShotTint: Float?
        /// The shipped analysis of the masked preview: with the gray gamut, and without.
        var meanStops: Float
        var validWeight: Float
        var grayEstimate: [Float]
        var grayEstimateAllPixels: [Float]
        /// The brightest channel value of the masked preview, which sets the clip.
        var brightest: Float
        var step: Int
        var gridWidth: Int
        var gridHeight: Int
        /// Since 2026-10-07: the shipped analysis's gray estimate on cells, and the face boxes
        /// Vision found in the decode before the cube was masked (x, y, width, height from the
        /// top left, fractions of the frame).
        var grayEstimateCells: [Float]?
        var faces: [[Float]]?
    }

    /// Decodes every CR2 under cr2/ that has no cache yet, as the sheet does (960 pixels on the
    /// long side), and writes `cache/<id>.json` and `cache/<id>.samples` (half floats, RGB, the
    /// analysis grid row by row from the bottom, the cube zeroed).
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func prepare() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        try FileManager.default.createDirectory(at: Self.cache, withIntermediateDirectories: true)
        let folder = Self.rawFolder
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".CR2") }.sorted()
        var done = 0
        for name in names {
            let id = String(name.dropLast(4))
            let jsonURL = Self.cache.appendingPathComponent("\(id).json")
            if FileManager.default.fileExists(atPath: jsonURL.path) { continue }
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            guard let frame = try? decoder.decode(folder.appendingPathComponent(name), options: options) else {
                print("PREPARE \(id): decode failed")
                continue
            }
            var pixels = ExposureAnalyzer.pixels(of: frame.texture)
            let width = frame.width, height = frame.height
            guard width > height else {
                print("PREPARE \(id): portrait \(width) x \(height), skipped")
                continue
            }
            let faces = try Self.faces(id, width: width, height: height)
            let people = FaceMeter.detect(frame.texture, workingSpace: gpu.workingColorSpace)
            var brightestAll: Float = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                brightestAll = max(brightestAll, Float(pixels[index]), Float(pixels[index + 1]), Float(pixels[index + 2]))
            }
            // The truth: each face's mean over its middle, where the markup's corners cannot reach
            // past the face's edges.
            var means: [String: [Double]] = [:], counts: [String: Int] = [:]
            var peak: Float = 0
            for (tag, triangle) in faces {
                var sum = SIMD3<Double>(repeating: 0), count = 0
                let box = Self.bounds(triangle, width: width, height: height)
                for y in box.y {
                    for x in box.x where Self.inside(SIMD2(Double(x) + 0.5, Double(y) + 0.5), triangle, shrink: 0.6) {
                        let i = (y * width + x) * 4
                        let rgb = SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                        sum += SIMD3<Double>(rgb)
                        count += 1
                        if tag == "left" || tag == "right" { peak = max(peak, rgb.max()) }
                    }
                }
                means[tag] = count > 0 ? [sum.x / Double(count), sum.y / Double(count), sum.z / Double(count)] : []
                counts[tag] = count
            }
            // The cube, its mount and everything below it, masked as SimpleCube++ crops its corner.
            let corners = faces.values.flatMap { $0 }
            let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
            let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
            let w = maxX - minX, h = maxY - minY
            let x0 = max(0, Int(minX - 0.35 * w)), x1 = min(width, Int(maxX + 0.35 * w) + 1)
            // Rows run from the bottom, so the mount and the stand are the rows under the cube.
            let y1 = min(height, Int(maxY + 0.9 * h) + 1)
            for y in 0..<y1 {
                for x in x0..<x1 {
                    let i = (y * width + x) * 4
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
                }
            }
            var brightest: Float = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                brightest = max(brightest, Float(pixels[index]), Float(pixels[index + 1]), Float(pixels[index + 2]))
            }
            // As the analysis read the preview before 2026-10-07, one pixel a sample, which the
            // grid below keeps; the cells' estimate is kept beside it.
            let analysis = ExposureAnalyzer.analyze(pixels: pixels, width: width, height: height, sampling: .points)
            let all = ExposureAnalyzer.analyze(pixels: pixels, width: width, height: height, grayGamut: nil, sampling: .points)
            let step = max(1, max(width, height) / ExposureAnalyzer.samplesOnLongSide)
            var samples: [Float16] = []
            var gridWidth = 0, gridHeight = 0
            for y in stride(from: step / 2, to: height, by: step) {
                gridHeight += 1
                gridWidth = 0
                for x in stride(from: step / 2, to: width, by: step) {
                    gridWidth += 1
                    let i = (y * width + x) * 4
                    samples.append(contentsOf: [pixels[i], pixels[i + 1], pixels[i + 2]])
                }
            }
            // The grid as the shipped analysis reads it: each cell's mean light over its pixels
            // that are not clipped, with that share as a fourth value.
            let cells = ExposureAnalyzer.grid(pixels: pixels, width: width, height: height)
            var cellSamples: [Float16] = []
            for index in cells.light.indices {
                let v = cells.light[index]
                cellSamples += [Float16(v.x), Float16(v.y), Float16(v.z), Float16(cells.unclipped[index])]
            }
            let cellAnalysis = ExposureAnalyzer.analyze(grid: cells)
            var prepared = Prepared(
                id: id, width: width, height: height,
                grayFaces: [means["left"] ?? [], means["right"] ?? []],
                grayPixels: [counts["left"] ?? 0, counts["right"] ?? 0],
                grayPeak: brightestAll > 0 ? Double(peak / brightestAll) : 0,
                whiteFaces: [means["left_b"] ?? [], means["right_b"] ?? []],
                asShotTemperature: frame.readback?.asShotTemperature, asShotTint: frame.readback?.asShotTint,
                meanStops: analysis.meanStops, validWeight: analysis.validWeight,
                grayEstimate: analysis.grayEstimate, grayEstimateAllPixels: all.grayEstimate,
                brightest: brightest, step: step, gridWidth: gridWidth, gridHeight: gridHeight)
            prepared.grayEstimateCells = cellAnalysis.grayEstimate
            prepared.faces = people.map { [Float($0.minX), Float($0.minY), Float($0.width), Float($0.height)] }
            try cellSamples.withUnsafeBytes { try Data($0).write(to: Self.cache.appendingPathComponent("\(id).cells")) }
            if let png = ProcessInfo.processInfo.environment["CUBEPP_PNG"] {
                try GateMeasureTests.writePNG(pixels, width: width, height: height, gpu: gpu,
                                              to: URL(fileURLWithPath: png).appendingPathComponent("\(id).png"))
            }
            try samples.withUnsafeBytes { try Data($0).write(to: Self.cache.appendingPathComponent("\(id).samples")) }
            try JSONEncoder().encode(prepared).write(to: jsonURL)
            done += 1
        }
        print("PREPARE \(done) frames cached, \(names.count) raw files present")
    }

    /// The gray gamut before Cube++ (docs/M3-auto.md section 3): -0.76 to +2.1 stops of red
    /// against blue, 0.35 of green against magenta, and no estimate when nothing is inside.
    static let previousGamut = GrayGamut(redBlue: -0.76...2.1, greenMagenta: 0.35)

    /// One way to estimate a frame's light, log2 red, green and blue; zero (no cast) when it
    /// finds nothing, which is what `AutoBalance` makes of a missing estimate.
    struct Estimator {
        var name: String
        var estimate: (Frame) -> SIMD3<Double>
    }

    /// The shipped estimator and the one before it, through `ExposureAnalyzer` itself, then
    /// variants of it tried on the train split (`shadesOfGray` below, which reproduces
    /// `ExposureAnalyzer` exactly on the grid for the first two), and the literature's two over
    /// the whole frame with the cube masked, clipped pixels out and no centre weighting.
    static var estimators: [Estimator] {
        let before = previousGamut
        return [
            Estimator(name: "before (gamut -0.76 to 2.1, none when empty)") { analyzed($0, grayGamut: before, fallback: false) },
            Estimator(name: "shipped (gamut -1.3 to 2.1, all when empty)") { analyzed($0, grayGamut: .plausibleLight, fallback: true) },
            Estimator(name: "gamut off") { analyzed($0, grayGamut: nil, fallback: false) },
            Estimator(name: "floor -1.3 only, none when empty") { analyzed($0, grayGamut: .plausibleLight, fallback: false) },
            Estimator(name: "shipped, all when under 10% inside") { shadesOfGray($0, gamut: .plausibleLight, locus: 0, minimumShare: 0.1) },
            Estimator(name: "shipped, gamut on the locus (0.2)") { shadesOfGray($0, gamut: .plausibleLight, locus: 0.2, minimumShare: 0) },
            Estimator(name: "gamut -1.3 to 5.5 on the locus (0.2)") {
                shadesOfGray($0, gamut: GrayGamut(redBlue: -1.3...5.5, greenMagenta: 0.35), locus: 0.2, minimumShare: 0)
            },
            Estimator(name: "shipped, p = 8") { shadesOfGray($0, gamut: .plausibleLight, locus: 0, minimumShare: 0, p: 8) },
            Estimator(name: "shipped, mid-tones to +4 stops") { shadesOfGray($0, gamut: .plausibleLight, locus: 0, minimumShare: 0, highStops: 4) },
            Estimator(name: "gray world, whole frame") { minkowski($0, p: 1) },
            Estimator(name: "shades of gray p = 6, whole frame") { minkowski($0, p: 6) },
        ]
    }

    /// `ExposureAnalyzer`'s estimate on the frame's grid.
    static func analyzed(_ frame: Frame, grayGamut: GrayGamut?, fallback: Bool) -> SIMD3<Double> {
        let analysis = ExposureAnalyzer.analyze(grid: frame.analysisGrid, grayGamut: grayGamut, grayGamutFallback: fallback)
        return SIMD3<Double>(AutoBalance.cast(analysis))
    }

    /// `ExposureAnalyzer`'s shades of gray with its constants opened up: the gamut's green band
    /// centred `locus` stops of green per stop of red against blue, every mid-tone counted when
    /// the gamut keeps no more than `minimumShare` of their weight, the power `p`, and the
    /// mid-tones' upper end.
    static func shadesOfGray(_ frame: Frame, gamut: GrayGamut, locus: Double, minimumShare: Double,
                             p: Double = 6, highStops: Double = 3) -> SIMD3<Double> {
        let width = frame.prepared.gridWidth, height = frame.prepared.gridHeight
        var brightest = 0.0
        for index in stride(from: 0, to: frame.grid.count, by: 4) {
            brightest = max(brightest, Double(frame.grid[index]), Double(frame.grid[index + 1]), Double(frame.grid[index + 2]))
        }
        let clip = brightest >= 0.18 * exp2(Double(ExposureAnalyzer.clipFloorStops)) ? brightest * 0.97 : .infinity
        let luma = SIMD3<Double>(0.2627, 0.6780, 0.0593)
        let low = 0.18 * exp2(-4.0), high = 0.18 * exp2(highStops)
        var inside = SIMD3<Double>(repeating: 0), insideWeight = 0.0, all = SIMD3<Double>(repeating: 0), allWeight = 0.0
        let cx = Double(width - 1) / 2, cy = Double(height - 1) / 2
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let rgb = SIMD3(Double(frame.grid[i]), Double(frame.grid[i + 1]), Double(frame.grid[i + 2]))
                let luminance = (rgb * luma).sum()
                guard rgb.max() < clip, luminance > low, luminance < high, rgb.min() > 0 else { continue }
                let dx = (Double(x) - cx) / max(cx, 1), dy = (Double(y) - cy) / max(cy, 1)
                let radius = (dx * dx + dy * dy).squareRoot()
                let weight = radius < 1.0 / 3 ? 1.0 : radius < 2.0 / 3 ? 0.5 : 0.25
                let unit = rgb / 0.18
                let powered = SIMD3(pow(unit.x, p), pow(unit.y, p), pow(unit.z, p)) * weight
                all += powered
                allWeight += weight
                let redBlue = log2(rgb.x / rgb.z), green = log2(rgb.y) - (log2(rgb.x) + log2(rgb.z)) / 2
                if gamut.redBlue.contains(Float(redBlue)), abs(green - locus * redBlue) <= Double(gamut.greenMagenta) {
                    inside += powered
                    insideWeight += weight
                }
            }
        }
        let useAll = insideWeight <= minimumShare * allWeight
        let (power, weight) = useAll ? (all, allWeight) : (inside, insideWeight)
        guard weight > 0 else { return .zero }
        let mean = power / weight
        let estimate = SIMD3(log2(mean.x), log2(mean.y), log2(mean.z)) / p
        return estimate - SIMD3(repeating: estimate.sum() / 3)
    }

    /// The Minkowski mean of every unclipped sample with no zero channel, log2.
    static func minkowski(_ frame: Frame, p: Double) -> SIMD3<Double> {
        let brightest = Double(frame.prepared.brightest)
        let clip = brightest >= 0.18 * exp2(Double(ExposureAnalyzer.clipFloorStops)) ? brightest * 0.97 : .infinity
        var sum = SIMD3<Double>(repeating: 0), count = 0.0
        for index in stride(from: 0, to: frame.grid.count, by: 4) {
            let rgb = SIMD3(Double(frame.grid[index]), Double(frame.grid[index + 1]), Double(frame.grid[index + 2]))
            guard rgb.min() > 0, rgb.max() < clip else { continue }
            let unit = rgb / 0.18
            sum += SIMD3(pow(unit.x, p), pow(unit.y, p), pow(unit.z, p))
            count += 1
        }
        guard count > 0 else { return .zero }
        let mean = sum / count
        return SIMD3(log2(mean.x), log2(mean.y), log2(mean.z)) / p
    }

    /// The angle in degrees between two lights given as log2 red, green and blue.
    static func degrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        GateMeasureTests.angle(SIMD3(exp2(a.x), exp2(a.y), exp2(a.z)), SIMD3(exp2(b.x), exp2(b.y), exp2(b.z)))
    }

    static func degrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double { degrees(SIMD3<Double>(a), SIMD3<Double>(b)) }

    /// Mean, median, mean of the worst quarter, and worst.
    static func summary(_ values: [Double]) -> String {
        let s = values.sorted()
        guard !s.isEmpty else { return "n 0" }
        let worst = s.suffix(max(1, s.count / 4))
        return String(format: "n %4d  mean %5.2f  median %5.2f  worst 25%% %5.2f  max %5.2f", s.count,
                      GateMeasureTests.mean(s), GateMeasureTests.median(s), GateMeasureTests.mean(Array(worst)), s.last!)
    }

    static func percentWithin(_ values: [Double], _ limit: Double) -> Double {
        Double(values.filter { $0 <= limit }.count) / Double(max(values.count, 1)) * 100
    }

    /// Angles between corrections are a historical proxy. The documented gate compares the
    /// gray left by the estimated correction with the gray left by the measured-light correction.
    /// Angular distance is not invariant under the channel-wise scaling by the measured light.
    static func correctionAndResidualErrors(estimate: SIMD3<Float>, truth: SIMD3<Float>)
        -> (correctionDirection: Double, residualGray: Double) {
        let estimated = AutoBalance.correction(for: estimate)
        let perfect = AutoBalance.correction(for: truth)
        return (degrees(estimated, perfect), degrees(truth - estimated, truth - perfect))
    }

    static func withinCount(_ values: [Double], _ limit: Double) -> String {
        "\(values.filter { $0 <= limit }.count)/\(values.count)"
    }

    static func zeroSum(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(v - SIMD3(repeating: v.sum() / 3)) }

    /// The share of a cast `AutoBalance` takes out, within bounds in mired, for trying other
    /// shares and bounds than the shipped ones.
    static func correction(_ cast: SIMD3<Float>, share: Float, boundMired: Float) -> SIMD3<Float> {
        let (redBlue, greenMagenta) = AutoBalance.axes(cast)
        let limit = boundMired * AutoBalance.stopsPerMired
        return AutoBalance.cast(redBlue: min(max(share * redBlue, -limit), limit),
                                greenMagenta: min(max(share * greenMagenta, -limit / 2), limit / 2))
    }

    /// The class of a frame's measured light by its red against blue through the D55 pin, in
    /// stops (a Planckian 6,400 K, 4,500 K and 3,500 K sit at about -0.3, +0.45 and +1.15, CIE
    /// 1931, computed); above +3 is sodium, which no Planckian light reaches.
    static func lightClass(_ frame: Frame) -> String {
        let (redBlue, _) = AutoBalance.axes(zeroSum(frame.truth))
        if redBlue < -0.3 { return "1 shade, overcast, sky (cooler than 6400 K)" }
        if redBlue < 0.45 { return "2 daylight (6400 to 4500 K)" }
        if redBlue < 1.15 { return "3 warm (4500 to 3500 K)" }
        if redBlue < 3 { return "4 tungsten (warmer than 3500 K)" }
        return "5 sodium (above +3 stops)"
    }

    static func labelClass(_ frame: Frame) -> String {
        if frame.place == "outdoor" && frame.daytime == "day" { return "label outdoor, day" }
        if frame.place == "indoor" { return "label indoor" }
        if frame.daytime == "night" { return "label night" }
        return "label other or unknown"
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func measure() throws {
        let frames = try Self.loadFrames()
        let test = frames.filter { $0.split == "test" }, train = frames.filter { $0.split == "train" }
        try #require(frames.count == Self.expectedFrameCount && test.count == 462,
                     "Cube++ must retain its complete documented cohort, including all 462 held-out frames")
        print("MEASURE \(frames.count) frames: \(test.count) test, \(train.count) train")
        // The truth: how well the decode's two gray faces agree.
        let faceAngles = frames.map { frame -> Double in
            let f = frame.prepared.grayFaces
            return GateMeasureTests.angle(SIMD3(f[0][0], f[0][1], f[0][2]), SIMD3(f[1][0], f[1][1], f[1][2]))
        }
        print("MEASURE left against right gray face, degrees: \(Self.summary(faceAngles))")
        let lights = frames.map { AutoBalance.axes(Self.zeroSum($0.truth)) }
        let redBlues = lights.map { Double($0.redBlue) }.sorted(), greens = lights.map { Double($0.greenMagenta) }.sorted()
        print(String(format: "MEASURE the lights: red against blue %+.2f to %+.2f stops (1st and 99th percentile %+.2f, %+.2f), green %+.2f to %+.2f",
                     redBlues.first!, redBlues.last!, redBlues[redBlues.count / 100], redBlues[redBlues.count * 99 / 100],
                     greens.first!, greens.last!))
        print("MEASURE decoded level (meanStops): \(Self.summary(frames.map { Double($0.prepared.meanStops) }))")
        // The grid stands in for the preview, and shadesOfGray for ExposureAnalyzer.
        var gridError = 0.0, copyError = 0.0
        for frame in frames {
            if Self.cellGrids {
                // The cell grid against the shipped analysis of the full preview.
                let e = frame.prepared.grayEstimateCells ?? []
                let shipped = Self.analyzed(frame, grayGamut: .plausibleLight, fallback: true)
                if e.count == 3 { gridError = max(gridError, Self.degrees(shipped, SIMD3(Double(e[0]), Double(e[1]), Double(e[2])))) }
                continue
            }
            let e = frame.prepared.grayEstimate
            let before = Self.analyzed(frame, grayGamut: Self.previousGamut, fallback: false)
            if e.count == 3 { gridError = max(gridError, Self.degrees(before, SIMD3(Double(e[0]), Double(e[1]), Double(e[2])))) }
            let copy = Self.shadesOfGray(frame, gamut: Self.previousGamut, locus: 0, minimumShare: -1)
            copyError = max(copyError, Self.degrees(before, copy))
            let shipped = Self.analyzed(frame, grayGamut: .plausibleLight, fallback: true)
            copyError = max(copyError, Self.degrees(shipped, Self.shadesOfGray(frame, gamut: .plausibleLight, locus: 0, minimumShare: 0)))
        }
        print(String(format: "MEASURE grid against preview, worst %.3f degrees; shadesOfGray against ExposureAnalyzer, worst %.4f", gridError, copyError))

        // 1. Each estimate against the measured light, and what reaches the print: the gray after
        // AutoBalance takes its share of the estimated cast, against the gray after it takes the
        // same share of the measured one ("off design": what a perfect estimate would change).
        let estimators = Self.estimators
        for (split, set) in [("train", train), ("test", test)] {
            for estimator in estimators {
                var errors: [Double] = [], offDesign: [Double] = [], none = 0
                for frame in set {
                    let estimate = estimator.estimate(frame)
                    if estimate == .zero { none += 1 }
                    errors.append(Self.degrees(estimate, frame.truth))
                    let truth = Self.zeroSum(frame.truth)
                    offDesign.append(Self.correctionAndResidualErrors(estimate: Self.zeroSum(estimate), truth: truth).correctionDirection)
                }
                let name = estimator.name.padding(toLength: 46, withPad: " ", startingAt: 0)
                print(String(format: "MEASURE %@ %@ error %@ | correction-direction proxy mean %.2f, median %.2f, worst 25%% %.2f, within 3 degrees %.1f%%; no estimate %d",
                             split, name, Self.summary(errors), GateMeasureTests.mean(offDesign), GateMeasureTests.median(offDesign),
                             GateMeasureTests.mean(Array(offDesign.sorted().suffix(max(1, offDesign.count / 4)))),
                             Self.percentWithin(offDesign, 3), none))
                print("MEASURE \(split) \(estimator.name) correction-direction proxy within 3 degrees: \(Self.withinCount(offDesign, 3))")
            }
        }

        // Where the estimate before found nothing, so Auto filtered nothing, by the class of light.
        for (split, set) in [("train", train), ("test", test)] {
            let line = Dictionary(grouping: set, by: Self.lightClass).sorted { $0.key < $1.key }.map { name, frames -> String in
                let none = frames.filter { estimators[0].estimate($0) == .zero }.count
                return "\(name.prefix(12)) \(none) of \(frames.count)"
            }.joined(separator: "; ")
            print("MEASURE no estimate before, \(split): \(line)")
        }

        // 2. The cube's gray after the print's filtration, held out: Neutral keeps the whole cast;
        // Auto, before and shipped, takes out AutoBalance's share of the estimated one; "as
        // designed" takes out that share of the measured one. In the scene (the Negative LUT's
        // input) and printed through Portra 400 at a metered level against its print of a gray
        // with no cast.
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let neutralSettings = RollControls(labBalance: .neutral).settings(for: stock)
        let reference = Self.printed(.zero, neutralSettings, stock: stock)
        print(String(format: "MEASURE Portra 400 prints a gray with no cast %.2f degrees from (1, 1, 1)",
                     GateMeasureTests.angle(SIMD3<Double>(reference), SIMD3(repeating: 1))))
        var groups: [(key: String, value: [Frame])] = Dictionary(grouping: test, by: Self.lightClass).sorted { $0.key < $1.key }
        groups += Dictionary(grouping: test, by: Self.labelClass).sorted { $0.key < $1.key }
        groups.append((key: "all held-out frames", value: test))
        let before = estimators[0], shipped = estimators[1]
        for (name, set) in groups {
            var scene = [[Double]](repeating: [], count: 4), printed = [[Double]](repeating: [], count: 4)
            var mired = [[Double]](repeating: [], count: 4), offDesign = [[Double]](repeating: [], count: 2)
            for frame in set {
                let truth = Self.zeroSum(frame.truth)
                let casts = [Self.zeroSum(before.estimate(frame)), Self.zeroSum(shipped.estimate(frame))]
                let lefts = [truth, truth - AutoBalance.correction(for: casts[0]), truth - AutoBalance.correction(for: casts[1]),
                             truth - AutoBalance.correction(for: truth)]
                let aims: [SIMD3<Float>?] = [nil, casts[0], casts[1], truth]
                for index in 0..<4 {
                    scene[index].append(Self.degrees(lefts[index], .zero))
                    mired[index].append(Double(AutoBalance.mired(lefts[index])))
                    let settings = aims[index].map { RollControls(labBalance: .auto).settings(for: stock, aim: PrintAim(cast: $0)) } ?? neutralSettings
                    printed[index].append(GateMeasureTests.angle(SIMD3<Double>(Self.printed(truth, settings, stock: stock)), SIMD3<Double>(reference)))
                }
                offDesign[0].append(Self.correctionAndResidualErrors(estimate: casts[0], truth: truth).residualGray)
                offDesign[1].append(Self.correctionAndResidualErrors(estimate: casts[1], truth: truth).residualGray)
            }
            let columns = ["Neutral", "Auto before", "Auto shipped", "as designed"]
            var line = "MEASURE residual \(name) (n=\(set.count)):"
            for index in 0..<4 {
                line += String(format: " %@ %.2f deg, %+.0f mired, print %.2f deg, %.0f%% within 3;", columns[index],
                               GateMeasureTests.median(scene[index]), GateMeasureTests.median(mired[index]),
                               GateMeasureTests.median(printed[index]), Self.percentWithin(printed[index], 3))
            }
            let ninetieth = offDesign.map { $0.sorted()[min($0.count - 1, $0.count * 9 / 10)] }
            line += String(format: " residual-gray off design before %.2f (%.0f%% within 3, 90th percentile %.2f), shipped %.2f (%.0f%% within 3, 90th percentile %.2f)",
                           GateMeasureTests.median(offDesign[0]), Self.percentWithin(offDesign[0], 3), ninetieth[0],
                           GateMeasureTests.median(offDesign[1]), Self.percentWithin(offDesign[1], 3), ninetieth[1])
            print(line)
            print("MEASURE residual-gray off design \(name), within 3 degrees: before \(Self.withinCount(offDesign[0], 3)), shipped \(Self.withinCount(offDesign[1], 3))")
        }

        // The camera's own white balance against the measured light, on the frames whose camera
        // temperature varies (a temperature on five or more frames is a preset), in mired of red
        // against blue through AutoBalance's conversion; and the shipped estimate on the same frames.
        let temperatures = Dictionary(grouping: frames.compactMap { $0.prepared.asShotTemperature.map { Int($0.rounded()) } }, by: { $0 })
        let varying = frames.filter { frame in frame.prepared.asShotTemperature.map { (temperatures[Int($0.rounded())]?.count ?? 0) < 5 } ?? false }
        let measuredMired = varying.map { Double(AutoBalance.mired(Self.zeroSum($0.truth))) }
        let cameraMired = varying.map { Double(1e6 / $0.prepared.asShotTemperature! - 1e6 / 5500) }
        let estimateMired = varying.map { Double(AutoBalance.mired(Self.zeroSum(shipped.estimate($0)))) }
        print(String(format: "MEASURE camera against the measured light (n=%d of %d): median %.0f mired; shipped estimate median %.0f mired",
                     varying.count, frames.count, GateMeasureTests.median(zip(cameraMired, measuredMired).map { abs($0 - $1) }),
                     GateMeasureTests.median(zip(estimateMired, measuredMired).map { abs($0 - $1) })))

        // 3. Other shares and bounds with the shipped estimate, held out: the gray left in the
        // scene against no cast, by class.
        for (share, bound) in [(Float(0.5), Float(60)), (0.7, 60), (0.9, 60), (1.0, 60), (0.7, 90), (0.7, 120)] {
            var line = String(format: "MEASURE share %.1f, bound %.0f mired:", share, bound)
            for (name, set) in groups.prefix(5) {
                let left = set.map { frame -> Double in
                    let truth = Self.zeroSum(frame.truth)
                    return Self.degrees(truth - Self.correction(Self.zeroSum(shipped.estimate(frame)), share: share, boundMired: bound), .zero)
                }
                line += String(format: " %@ median %.2f, %.0f%% within 3;", String(name.prefix(12)), GateMeasureTests.median(left), Self.percentWithin(left, 3))
            }
            print(line)
        }
    }

    /// Skin as the second estimate (docs/M3-auto.md section 16) on the Cube++ frames where Vision
    /// found a face (ARGENT_CUBEPP_GRID=cells and a cache `prepare` wrote since 2026-10-07): the
    /// estimate's error against the measured light with the skin's weight at 0 and as shipped, and
    /// where each face's skin sits under the measured light, which checks `SkinBalance`'s range.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func skinOnCube() throws {
        let frames = try Self.loadFrames().filter { !($0.prepared.faces ?? []).isEmpty }
        print("MEASURE skin: \(frames.count) frames with a face (\(frames.filter { $0.split == "test" }.count) test)")
        var errors: [[Double]] = [[], []], offDesign: [[Double]] = [[], []], counted = 0, moved = 0
        for frame in frames {
            let grid = frame.analysisGrid
            var analysis = ExposureAnalyzer.analyze(grid: grid)
            let boxes = (frame.prepared.faces ?? []).map { CGRect(x: CGFloat($0[0]), y: CGFloat($0[1]), width: CGFloat($0[2]), height: CGFloat($0[3])) }
            analysis.faces = FaceMeter.meter(boxes, grid: grid)
            let truth = Self.zeroSum(frame.truth)
            let casts = [AutoBalance.cast(analysis, skinWeight: 0), AutoBalance.cast(analysis)]
            for k in 0..<2 {
                errors[k].append(Self.degrees(casts[k], truth))
                offDesign[k].append(Self.degrees(AutoBalance.correction(for: casts[k]), AutoBalance.correction(for: truth)))
            }
            var line = String(format: "MEASURE skin %@ %@: faces %d, area %.1f%%", frame.prepared.id, frame.split, boxes.count,
                              analysis.faceArea * 100)
            for face in analysis.faces {
                guard let skin = face.skin else { line += String(format: "; a face of %.2f%%, no skin", face.area * 100); continue }
                let a = AutoBalance.axes(SIMD3(log2(skin[0]), log2(skin[1]), log2(skin[2]))), t = AutoBalance.axes(truth)
                line += String(format: "; a face of %.2f%%, skin under the measured light %+.2f, %+.2f", face.area * 100,
                               a.redBlue - t.redBlue, a.greenMagenta - t.greenMagenta)
            }
            if let skin = SkinBalance.skin(analysis) {
                counted += 1
                let t = AutoBalance.axes(truth), g = AutoBalance.axes(casts[0])
                line += String(format: ", skin %.1f%% at %+.2f, %+.2f; under the measured light %+.2f, %+.2f; under the estimate %+.2f, %+.2f",
                               skin.area * 100, skin.redBlue, skin.greenMagenta, skin.redBlue - t.redBlue, skin.greenMagenta - t.greenMagenta,
                               skin.redBlue - g.redBlue, skin.greenMagenta - g.greenMagenta)
                if casts[0] != casts[1] { moved += 1 }
            } else {
                line += ", skin does not count"
            }
            line += String(format: "; error %.2f -> %.2f degrees, off design %.2f -> %.2f", errors[0].last!, errors[1].last!,
                           offDesign[0].last!, offDesign[1].last!)
            print(line)
        }
        print("MEASURE skin: \(counted) frames whose skin counts, \(moved) moved")
        for (k, name) in ["gray estimate alone", "with skin (shipped)"].enumerated() {
            print(String(format: "MEASURE skin %@: error %@; off design mean %.2f, median %.2f, within 3 degrees %.0f%%", name,
                         Self.summary(errors[k]), GateMeasureTests.mean(offDesign[k]), GateMeasureTests.median(offDesign[k]),
                         Self.percentWithin(offDesign[k], 3)))
        }
    }

    /// Skin on every held-out Cube++ frame, semi-synthetic (docs/M3-auto.md section 16): a face of 3
    /// percent of the frame painted into the cell grid under the frame's measured light, in one of
    /// several skin colours (NIST's palest and median forearm, the ColorChecker's light and dark
    /// skin, a green-leaning face as Cube++'s faces measured, and a gray statue); then the estimate's
    /// error against the measured light with the skin's weight at 0 and as shipped, by how far the
    /// gray estimate alone missed on green against magenta.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func skinInsertedOnCube() throws {
        let frames = try Self.loadFrames().filter { $0.split == "test" && $0.shares != nil }
        let skins: [(String, Float, Float)] = [("NIST palest", 0.58, 0.0), ("NIST median", 0.76, 0.01), ("ColorChecker light", 1.00, -0.07),
                                               ("ColorChecker dark", 1.18, -0.06), ("green-leaning", 0.9, 0.18), ("gray statue", 0, 0)]
        print("MEASURE skin inserted: \(frames.count) held-out frames")
        for (name, redBlue, greenMagenta) in skins {
            var errors: [[Double]] = [[], []], offDesign: [[Double]] = [[], []], byMiss: [String: [[Double]]] = [:], moved = 0
            var greenErrors: [[Double]] = [[], []]
            for frame in frames {
                var grid = frame.analysisGrid
                let truth = Self.zeroSum(frame.truth)
                let light = SIMD3<Float>(exp2(truth.x), exp2(truth.y), exp2(truth.z))
                let skin = AutoBalance.cast(redBlue: redBlue, greenMagenta: greenMagenta)
                // The face's light at the frame's level plus half a stop, as a face is lit.
                let plain = ExposureAnalyzer.analyze(grid: grid)
                let colour = 0.18 * exp2(plain.meanStops + 0.5) * SIMD3(exp2(skin.x), exp2(skin.y), exp2(skin.z)) * light
                // A box on the left third, clear of the cube in the lower right: 0.2 by 0.15 of the
                // frame, so its inset is 3 percent of it.
                let box = CGRect(x: 0.15, y: 0.3, width: 0.2 / CGFloat(FaceMeter.insetWidth) * 0.66,
                                 height: 0.15 / CGFloat(FaceMeter.insetHeight) * 1.5)
                for row in 0..<grid.height {
                    for column in 0..<grid.width {
                        let fx = (Float(column) + 0.5) / Float(grid.width), fy = 1 - (Float(row) + 0.5) / Float(grid.height)
                        guard fx >= Float(box.minX), fx < Float(box.maxX), fy >= Float(box.minY), fy < Float(box.maxY) else { continue }
                        let index = row * grid.width + column
                        grid.light[index] = colour; grid.all[index] = colour; grid.unclipped[index] = 1
                    }
                }
                var analysis = ExposureAnalyzer.analyze(grid: grid)
                analysis.faces = FaceMeter.meter([box], grid: grid)
                let casts = [AutoBalance.cast(analysis, skinWeight: 0), AutoBalance.cast(analysis)]
                if (SkinBalance.pull(analysis, cast: casts[0]) ?? 0) != 0 { moved += 1 }
                let miss = abs(AutoBalance.axes(casts[0]).greenMagenta - AutoBalance.axes(truth).greenMagenta)
                for k in 0..<2 { greenErrors[k].append(Double(abs(AutoBalance.axes(casts[k]).greenMagenta - AutoBalance.axes(truth).greenMagenta))) }
                let bucket = miss < 0.1 ? "a under 0.1" : miss < 0.2 ? "b 0.1 to 0.2" : miss < 0.3 ? "c 0.2 to 0.3" : "d over 0.3"
                if ProcessInfo.processInfo.environment["ARGENT_SKIN_CASES"] != nil, abs(Self.degrees(casts[1], truth) - Self.degrees(casts[0], truth)) > 0.5 {
                    let t = AutoBalance.axes(truth), a = AutoBalance.axes(casts[0]), b = AutoBalance.axes(casts[1])
                    print(String(format: "MEASURE skin inserted %@ case %@ [%@]: truth %+.2f, %+.2f; estimate error %+.2f, %+.2f -> %+.2f, %+.2f; degrees %.2f -> %.2f",
                                 name, frame.prepared.id, String(Self.lightClass(frame).prefix(10)), t.redBlue, t.greenMagenta,
                                 a.redBlue - t.redBlue, a.greenMagenta - t.greenMagenta, b.redBlue - t.redBlue, b.greenMagenta - t.greenMagenta,
                                 Self.degrees(casts[0], truth), Self.degrees(casts[1], truth)))
                }
                for k in 0..<2 {
                    let e = Self.degrees(casts[k], truth)
                    errors[k].append(e)
                    offDesign[k].append(Self.degrees(AutoBalance.correction(for: casts[k]), AutoBalance.correction(for: truth)))
                    byMiss[bucket, default: [[], []]][k].append(e)
                }
            }
            let greenChanges = zip(greenErrors[0], greenErrors[1]).map { $1 - $0 }
            print(String(format: "MEASURE skin inserted %@: green against magenta |error| mean %.3f -> %.3f stops, larger on %d frames, smaller on %d (by up to %.2f)", name,
                         GateMeasureTests.mean(greenErrors[0]), GateMeasureTests.mean(greenErrors[1]), greenChanges.filter { $0 > 1e-4 }.count,
                         greenChanges.filter { $0 < -1e-4 }.count, -(greenChanges.min() ?? 0)))
            let changes = zip(errors[0], errors[1]).map { $1 - $0 }
            print(String(format: "MEASURE skin inserted %@: worse on %d frames (by up to %.2f degrees), better on %d (by up to %.2f)", name,
                         changes.filter { $0 > 0.005 }.count, changes.max() ?? 0, changes.filter { $0 < -0.005 }.count, -(changes.min() ?? 0)))
            print(String(format: "MEASURE skin inserted %@ (%+.2f, %+.2f): moved %d of %d; error mean %.2f -> %.2f, median %.2f -> %.2f, worst 25%% %.2f -> %.2f; off design mean %.2f -> %.2f, within 3 degrees %.1f%% -> %.1f%%",
                         name, redBlue, greenMagenta, moved, frames.count, GateMeasureTests.mean(errors[0]), GateMeasureTests.mean(errors[1]),
                         GateMeasureTests.median(errors[0]), GateMeasureTests.median(errors[1]),
                         GateMeasureTests.mean(Array(errors[0].sorted().suffix(errors[0].count / 4))), GateMeasureTests.mean(Array(errors[1].sorted().suffix(errors[1].count / 4))),
                         GateMeasureTests.mean(offDesign[0]), GateMeasureTests.mean(offDesign[1]), Self.percentWithin(offDesign[0], 3), Self.percentWithin(offDesign[1], 3)))
            for (bucket, e) in byMiss.sorted(by: { $0.key < $1.key }) {
                print(String(format: "MEASURE skin inserted %@, gray estimate's green miss %@ (n=%d): error mean %.2f -> %.2f", name, String(bucket.dropFirst(2)),
                             e[0].count, GateMeasureTests.mean(e[0]), GateMeasureTests.mean(e[1])))
            }
        }
    }

    /// Looks for faces with Vision in the point grids of a Cube++ cache (the 240 by 160 samples
    /// `prepare` kept before 2026-10-07), to find frames worth decoding again for `skinOnCube`.
    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_FACE_SCAN"] != nil))
    func faceScan() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        var found = 0
        for frame in try Self.loadFrames() {
            let w = frame.prepared.gridWidth, h = frame.prepared.gridHeight
            let texture = try gpu.texturePool.acquire(width: w, height: h)
            frame.grid.withUnsafeBytes { texture.texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
            let boxes = FaceMeter.detect(texture.texture, workingSpace: gpu.workingColorSpace)
            guard !boxes.isEmpty else { continue }
            found += 1
            let largest = boxes.map { $0.width * $0.height * CGFloat(FaceMeter.insetWidth * FaceMeter.insetHeight) }.max() ?? 0
            print(String(format: "MEASURE face scan %@ %@: %d faces, largest inset %.2f%%", frame.prepared.id, frame.split, boxes.count, largest * 100))
        }
        print("MEASURE face scan: \(found) frames with a face")
    }

    /// The a7 IV and a7C frames of `AutoMeasureTests/labBalanceAgainstTheCamera` under each gamut:
    /// the cases the gamut was made for (sunflowers, a magenta light show) must not come back.
    /// The camera's own white balance stands in for the light; it is not the truth.
    @Test(.enabled(if: FrameViewMeasureTests.enabled))
    func gamutsOnTheA7IV() throws {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let d55 = 1e6 / Float(5500)
        let gamuts: [(String, GrayGamut?, Bool)] = [("before", Self.previousGamut, false), ("shipped", .plausibleLight, true),
                                                    ("off", nil, false)]
        var errors = [[Float]](repeating: [], count: gamuts.count)
        let files = AutoMeasureTests.folder("samples") + AutoMeasureTests.folder("references/corpus/photographyblog-a7iv")
            + AutoMeasureTests.folder("references/corpus/imaging-resource-a7iv-wayback").prefix(1)
            + AutoMeasureTests.folder("references/corpus/rawnind-a7c").prefix(1)
        for url in files {
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            let frame = try decoder.decode(url, options: options)
            let pixels = ExposureAnalyzer.pixels(of: frame.texture)
            let camera = frame.readback.map { 1e6 / $0.asShotTemperature - d55 } ?? .nan
            var line = String(url.deletingPathExtension().lastPathComponent.prefix(22)).padding(toLength: 22, withPad: " ", startingAt: 0)
            line += String(format: " camera %+4.0f mired;", camera)
            for (index, (name, gamut, fallback)) in gamuts.enumerated() {
                let analysis = ExposureAnalyzer.analyze(pixels: pixels, width: frame.width, height: frame.height, grayGamut: gamut,
                                                        grayGamutFallback: fallback)
                let cast = AutoBalance.cast(analysis)
                errors[index].append(abs(AutoBalance.mired(cast) - camera))
                line += String(format: " %@ %+4.0f (green %+.2f)", name, AutoBalance.mired(cast), AutoBalance.axes(cast).greenMagenta)
            }
            print("MEASURE a7 IV \(line)")
        }
        for (index, (name, _, _)) in gamuts.enumerated() {
            let sorted = errors[index].sorted()
            print(String(format: "MEASURE a7 IV gamut %@: |estimate - camera| median %.0f mired, worst %.0f (n=%d)",
                         name, sorted[sorted.count / 2], sorted.last!, sorted.count))
        }
    }

    /// A metered gray whose channels carry `cast` (stops, summing to zero), printed through
    /// `stock` with `settings`, display-linear; as `AutoBalanceTests` prints one.
    static func printed(_ cast: SIMD3<Float>, _ settings: DevelopSettings, stock: Stock) -> SIMD3<Float> {
        let encoding = stock.negative.encoding
        let exposed = GamutCompression.compress(SIMD3<Float>(repeating: 0.18) * SIMD3(exp2(cast.x), exp2(cast.y), exp2(cast.z)))
        let encoded = SIMD3(encoding.encode(exposed.x), encoding.encode(exposed.y), encoding.encode(exposed.z))
        let dyes = stock.negative.sample(encoded: encoded)
        let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        return stock.print.sample(encoded: (dyes + offset).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
    }

    /// A prepared frame with its split, its labels and the light on its gray faces.
    struct Frame {
        var prepared: Prepared
        var split: String
        var place: String
        var daytime: String
        var illumination: String
        /// The analysis grid as an RGBA image, `prepared.gridWidth` by `prepared.gridHeight`.
        var grid: [Float16]
        /// The light, as log2 red, green and blue: the bisector of the two gray faces' colours.
        var truth: SIMD3<Double>
        /// With cell grids, each cell's share of pixels that are not clipped.
        var shares: [Float]? = nil

        /// The grid as `ExposureAnalyzer` reads it: with cell grids, each cell's light and its
        /// share as the shipped analysis had them on the full preview.
        var analysisGrid: ExposureAnalyzer.Grid {
            var g = ExposureAnalyzer.grid(pixels: grid, width: prepared.gridWidth, height: prepared.gridHeight, sampling: .points)
            if let shares {
                g.light = stride(from: 0, to: grid.count, by: 4).map { SIMD3(Float(grid[$0]), Float(grid[$0 + 1]), Float(grid[$0 + 2])) }
                g.all = g.light
                g.unclipped = shares
            }
            return g
        }
    }

    /// Every prepared frame of SimpleCube++ whose two gray faces were measured.
    static func loadFrames() throws -> [Frame] {
        var labels: [String: (String, [String: String])] = [:]
        for split in ["train", "test"] {
            let text = try String(contentsOf: corpus.appendingPathComponent("simple/auxiliary_\(split)_properties.csv"), encoding: .utf8)
            let lines = text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            guard let header = lines.first else { continue }
            for line in lines.dropFirst() where line.count == header.count {
                labels[line[0]] = (split, Dictionary(uniqueKeysWithValues: zip(header, line)))
            }
        }
        var frames: [Frame] = []
        let cohort = Self.cohort
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).filter { $0.hasSuffix(".json") }
            .filter { cohort?.contains(String($0.dropLast(5))) ?? true }.sorted()
        for name in names {
            let prepared = try JSONDecoder().decode(Prepared.self, from: Data(contentsOf: cache.appendingPathComponent(name)))
            guard let (split, row) = labels[prepared.id] else { continue }
            let faces = prepared.grayFaces.filter { $0.count == 3 && $0.allSatisfy { $0 > 0 } }
            guard faces.count == 2 else { continue }
            let units = faces.map { face -> SIMD3<Double> in
                let v = SIMD3(face[0], face[1], face[2])
                return v / (v * v).sum().squareRoot()
            }
            let bisector = units[0] + units[1]
            var grid = [Float16](repeating: 1, count: prepared.gridWidth * prepared.gridHeight * 4)
            var shares: [Float]?
            if cellGrids {
                let url = cache.appendingPathComponent("\(prepared.id).cells")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let data = try Data(contentsOf: url)
                let rgba = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
                guard rgba.count == grid.count else { continue }
                grid = rgba
                shares = stride(from: 3, to: rgba.count, by: 4).map { Float(rgba[$0]) }
                for index in stride(from: 3, to: grid.count, by: 4) { grid[index] = 1 }
            } else {
                let data = try Data(contentsOf: cache.appendingPathComponent("\(prepared.id).samples"))
                let rgb = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
                for index in 0..<(prepared.gridWidth * prepared.gridHeight) {
                    grid[index * 4] = rgb[index * 3]
                    grid[index * 4 + 1] = rgb[index * 3 + 1]
                    grid[index * 4 + 2] = rgb[index * 3 + 2]
                }
            }
            frames.append(Frame(prepared: prepared, split: split, place: row["place"] ?? "unknown",
                                daytime: row["daytime"] ?? "unknown", illumination: row["illumination"] ?? "unknown",
                                grid: grid, truth: SIMD3(log2(bisector.x), log2(bisector.y), log2(bisector.z)), shares: shares))
        }
        return frames
    }

    /// The SpyderCube's four faces from the archive's markup, in decode pixels with rows from
    /// the bottom: the gray faces are tagged left and right, the white ones left_b and right_b.
    /// The markup is in the 2592 by 1728 camera JPEG's pixels, the decode's frame at half size.
    static func faces(_ id: String, width: Int, height: Int) throws -> [String: [SIMD2<Double>]] {
        let url = corpus.appendingPathComponent("source_markup/Cube++/auxiliary/source/JPG.JSON/\(id).jpg.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let sx = Double(width) / 2592, sy = Double(height) / 1728
        var faces: [String: [SIMD2<Double>]] = [:]
        for object in json["objects"] as? [[String: Any]] ?? [] {
            guard let tag = (object["tags"] as? [String])?.first, let data = object["data"] as? [[Double]], data.count == 3
            else { continue }
            faces[tag] = data.map { SIMD2($0[0] * sx, (1728 - $0[1]) * sy) }
        }
        return faces
    }

    static func bounds(_ t: [SIMD2<Double>], width: Int, height: Int) -> (x: Range<Int>, y: Range<Int>) {
        let x0 = max(0, Int(t.map(\.x).min()!)), x1 = min(width, Int(t.map(\.x).max()!) + 1)
        let y0 = max(0, Int(t.map(\.y).min()!)), y1 = min(height, Int(t.map(\.y).max()!) + 1)
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }

    /// Whether `p` lies in the triangle `t` shrunk toward its centroid to `shrink` of its size.
    static func inside(_ p: SIMD2<Double>, _ t: [SIMD2<Double>], shrink: Double) -> Bool {
        let c = (t[0] + t[1] + t[2]) / 3
        let a = c + (t[0] - c) * shrink, b = c + (t[1] - c) * shrink, d = c + (t[2] - c) * shrink
        func side(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { (v.x - u.x) * (p.y - u.y) - (v.y - u.y) * (p.x - u.x) }
        let s1 = side(a, b), s2 = side(b, d), s3 = side(d, a)
        return (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0)
    }
}
