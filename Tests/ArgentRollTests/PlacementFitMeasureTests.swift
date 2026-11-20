import ArgentCore
import CoreImage
import Foundation
import Testing
@testable import ArgentRoll

/// What a per-frame placement fit reads from FiveK frames outside the gate cohort (M2, docs/M3-auto.md
/// section 42). Each frame is decoded, measured and rendered exactly as `GateMeasureTests` does, and
/// for each one this records Auto's measurement, the five experts' mean L* over the whole frame and
/// over the largest detected face's inset, and the frame's own whole and face L* at a sweep of print
/// aims. A fit then needs no raw or TIFF. Runs only with ARGENT_MEASURE=1 and ARGENT_FIT_LIST:
///
///     ARGENT_MEASURE=1 ARGENT_FIT_LIST=<names.txt> ARGENT_FIT_DATA=<folder> ARGENT_FIT_OUT=<frames.jsonl> \
///       ARGENT_FIT_COHORT=<fivek-subset/_meta/selection.tsv> swift test -c release --filter PlacementFitMeasureTests
///
/// `ARGENT_FIT_DATA` holds `dng/` and `tiff16_a` … `tiff16_e/` as the FiveK site names them. A name
/// in the gate cohort's selection fails the run, so the cohort stays held out. Frames already in the
/// output are skipped, so a run resumes. With ARGENT_FIT_DELETE_TIFF=1 each expert TIFF is deleted once
/// its frame is recorded, and a 240-pixel half-float derivative of its aligned rendition is kept
/// under `ARGENT_FIT_DATA/derived/`. Each frame drains its own autorelease pool, which this thread
/// otherwise empties only when the test ends: without one a run grew about 285 MB a frame (824 MB to
/// 11.9 GB over 40 frames, and past 90 GB on the long runs of 2026-10-18); with it the footprint stays
/// between 0.4 and 0.8 GB over 99 (2026-10-19, M5 Pro). ARGENT_FIT_MAX still caps the frames one run
/// records, and a loop of capped runs resumes where the last stopped. Everything written is restricted
/// derived data: keep it outside Git.
@Suite(.serialized) struct PlacementFitMeasureTests {
    typealias G = GateMeasureTests
    typealias M = FrameViewMeasureTests

    /// The print aims swept, absolute levels in scene stops (`PrintAim.level`).
    static let aims: [Float] = stride(from: -3.0, through: 3.0, by: 0.125).map { Float($0) }

    struct Record: Codable {
        var name: String
        var width: Int
        var height: Int
        var analysis: ExposureAnalysis
        var autoLevel: Float
        var cast: [Float]
        var flash: Bool?
        var orientations: [Int]
        var correlations: [Double]
        var expertsWhole: [Double]
        /// The largest detected face's box and its inset in pixels (rows from the bottom), the gate's
        /// evaluation region; nil without a face.
        var faceBox: [Float]?
        var faceRegion: [Int]?
        var expertsFace: [Double]?
        var aims: [Float]
        var sweepWhole: [Double]
        var sweepFace: [Double]?
        var autoWhole: Double
        var autoFace: Double?
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_FIT_LIST"] != nil))
    func recordFrames() throws {
        let environment = ProcessInfo.processInfo.environment
        let list = try String(contentsOfFile: try #require(environment["ARGENT_FIT_LIST"]), encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let data = URL(fileURLWithPath: try #require(environment["ARGENT_FIT_DATA"]))
        let out = URL(fileURLWithPath: try #require(environment["ARGENT_FIT_OUT"]))
        try #require(!out.resolvingSymlinksInPath().path.hasPrefix(M.root.path + "/"), "keep restricted derived data outside the repository")
        let cohortText = try String(contentsOfFile: try #require(environment["ARGENT_FIT_COHORT"]), encoding: .utf8)
        let cohort = Set(cohortText.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count >= 7 ? String(fields[1]) : nil
        })
        try #require(cohort.count >= 40, "the gate cohort's selection must list its photos")
        try #require(cohort.isDisjoint(with: list), "the gate cohort is held out of every fit")
        let deleteTIFF = environment["ARGENT_FIT_DELETE_TIFF"] == "1"
        let derived = data.appendingPathComponent("derived")
        if deleteTIFF { try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true) }

        var done = Set<String>()
        if let existing = try? String(contentsOf: out, encoding: .utf8) {
            for line in existing.split(separator: "\n") {
                if let record = try? JSONDecoder().decode(Record.self, from: Data(line.utf8)) { done.insert(record.name) }
            }
        } else {
            FileManager.default.createFile(atPath: out.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        func logLuminance(_ p: [Float16]) -> [Double] {
            stride(from: 0, to: p.count, by: 4).map { i in
                log2(max(0.2627 * Double(p[i]) + 0.6780 * Double(p[i + 1]) + 0.0593 * Double(p[i + 2]), 1e-4))
            }
        }
        func correlation(_ a: [Double], _ b: [Double]) -> Double {
            let ma = G.mean(a), mb = G.mean(b)
            var ab = 0.0, aa = 0.0, bb = 0.0
            for i in a.indices {
                ab += (a[i] - ma) * (b[i] - mb)
                aa += (a[i] - ma) * (a[i] - ma)
                bb += (b[i] - mb) * (b[i] - mb)
            }
            return ab / (aa * bb).squareRoot()
        }
        // As GateMeasureTests.exposureGateOnFiveK aligns an expert's rendition.
        func aligned(_ url: URL, ours: [Double], width: Int, height: Int) throws -> (pixels: [Float16], r: Double, orientation: Int)? {
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
            for (index, candidate) in [scaled, flipped].enumerated() {
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
        /// A 240-pixel box-filtered half-float RGB copy, rows from the bottom.
        func derivative(_ pixels: [Float16], width: Int, height: Int) -> Data {
            let step = max(1, max(width, height) / 240)
            let w = width / step, h = height / step
            var out = [Float16](repeating: 0, count: w * h * 3 + 2)
            out[0] = Float16(Float(w)); out[1] = Float16(Float(h))
            for y in 0..<h {
                for x in 0..<w {
                    var s = SIMD3<Float>(repeating: 0)
                    for yy in 0..<step { for xx in 0..<step {
                        let i = ((y * step + yy) * width + x * step + xx) * 4
                        s += SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                    } }
                    s /= Float(step * step)
                    let o = 2 + (y * w + x) * 3
                    out[o] = Float16(s.x); out[o + 1] = Float16(s.y); out[o + 2] = Float16(s.z)
                }
            }
            return out.withUnsafeBytes { Data($0) }
        }

        let cap = environment["ARGENT_FIT_MAX"].flatMap(Int.init) ?? .max
        var recorded = 0, skipped: [String] = []
        /// Records one frame; the reason it was skipped, or nil once written.
        func measureFrame(_ name: String) throws -> String? {
            let dng = data.appendingPathComponent("dng/\(name).dng")
            let tiffs = G.experts.map { data.appendingPathComponent("tiff16_\($0)/\(name).tif") }
            guard FileManager.default.fileExists(atPath: dng.path), tiffs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                return "\(name): missing input"
            }
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            guard let frame = try? decoder.decode(dng, options: options) else { return "\(name): no decode" }
            let width = frame.width, height = frame.height
            let header = try? ARWFrameInfo.read(from: dng)
            let analysis = ExposureAnalyzer.analyze(frame, workingSpace: gpu.workingColorSpace, info: header)
            let decoded = logLuminance(ExposureAnalyzer.pixels(of: frame.texture))
            var expertPixels: [[Float16]] = [], rs: [Double] = [], orientations: [Int] = []
            for tiff in tiffs {
                guard let match = try aligned(tiff, ours: decoded, width: width, height: height), match.r > 0.5 else { break }
                expertPixels.append(match.pixels); rs.append(match.r); orientations.append(match.orientation)
            }
            guard expertPixels.count == G.experts.count else { return "\(name): an expert does not line up" }
            let face = analysis.faces.max(by: { $0.area < $1.area }).map { GateEvaluationProtocol.Face($0, width: width, height: height) }
            let level = AutoPrint.levelStops(analysis)
            let cast = AutoBalance.cast(analysis)
            let auto = RollControls(labBalance: .auto)
            func render(_ aim: Float) throws -> [Float16] {
                ExposureAnalyzer.pixels(of: try renderer.render(frame, settings: auto.settings(for: stock, aim: PrintAim(level: aim, cast: cast))).image.texture)
            }
            var sweepWhole: [Double] = [], sweepFace: [Double] = []
            for aim in Self.aims {
                let pixels = try render(aim)
                sweepWhole.append(G.measure(pixels, width: width, height: height).lightness)
                if let face { sweepFace.append(G.measure(pixels, width: width, height: height, region: face.region).lightness) }
            }
            let ours = try render(level)
            let region = face.map { [$0.region.x0, $0.region.x1, $0.region.y0, $0.region.y1] }
            let record = Record(
                name: name, width: width, height: height, analysis: analysis, autoLevel: level,
                cast: [cast.x, cast.y, cast.z], flash: G.flashFired(dng), orientations: orientations, correlations: rs,
                expertsWhole: expertPixels.map { G.measure($0, width: width, height: height).lightness },
                faceBox: face?.box, faceRegion: region,
                expertsFace: face.map { f in expertPixels.map { G.measure($0, width: width, height: height, region: f.region).lightness } },
                aims: Self.aims, sweepWhole: sweepWhole, sweepFace: face == nil ? nil : sweepFace,
                autoWhole: G.measure(ours, width: width, height: height).lightness,
                autoFace: face.map { G.measure(ours, width: width, height: height, region: $0.region).lightness })
            try handle.write(contentsOf: encoder.encode(record) + Data("\n".utf8))
            if deleteTIFF {
                for (expert, (tiff, pixels)) in zip(G.experts, zip(tiffs, expertPixels)) {
                    try derivative(pixels, width: width, height: height)
                        .write(to: derived.appendingPathComponent("\(name)-\(expert).f16"))
                    try FileManager.default.removeItem(at: tiff)
                }
            }
            return nil
        }
        for name in list where !done.contains(name) && recorded < cap {
            // Each frame drains its own pool, so what Core Image and Metal autoreleased for it goes
            // before the next frame starts; this thread's pool otherwise empties only when the test ends.
            if let reason = try autoreleasepool(invoking: { try measureFrame(name) }) {
                skipped.append(reason); continue
            }
            recorded += 1
            print("FIT recorded \(name) (\(recorded)), footprint \(physicalFootprint() >> 20) MB")
        }
        for s in skipped { print("FIT skipped \(s)") }
        print("FIT \(recorded) recorded, \(done.count) already, \(skipped.count) skipped of \(list.count)")
    }
}
