import CoreAI
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// Follow edges on real frames, through production code (task L's gate): the full-size decode as a develop makes it, a stroke painted
/// by `BrushStrokeSession` on it as the frame view's session paints (Follow edges each dab, the guided refinement at its end), the
/// measured shape kept and read back by the bake, and the print through the film. The frames are private: read where they lie,
/// nothing of them in Git. It runs only when asked:
///
///     ARGENT_MEASURE=1 ARGENT_FOLLOW_FRAMES=<manifest.json> ARGENT_FOLLOW_OUT=<folder> \
///       swift test -c release -Xswiftc -enable-testing --filter FollowEdgesGateTests
///
/// The manifest lists strokes: `{"stem", "raw", "label", "radius", "points": [[x, y], …], "exposure", "lowContrast"}`, points in the
/// upright full-size picture's pixels from its top left, radius in long sides.
///
/// **The band.** What crosses an edge is measured against an independent answer for where the far side is: Phase 2's Sky mask, DA3's
/// seed refined on the same decode (`SkyModelRunner`, the app's square), at each pixel of the full-size print. The stroke's footprint is
/// where the same stroke painted plain covers at least 0.5. In it, the **far side** is where Sky is at least 0.95, the **near side**
/// where it is at most 0.05, and the **edge** between. Crossing is the stroke's mean coverage (and p95) over far-side pixels of the
/// footprint; holding is its mean over near-side ones.
///
/// Also: the same stroke measured with the first dab's colour for every dab (R8's other variant) and on Apple's scaled decode of the
/// frame view before it refines (how much the kept shape depends on the decode it was painted on); each tick's and the release's
/// costs; and preview against develop on the frame view's refined decode and the sheet's, against the plan's refined-mask table.
///
/// **Placement** (task N). An entry with no `points` and a `place` stroke's radius is placed by rule, in a first pass with
/// `ARGENT_FOLLOW_PLACE=<output.json>`, before any stroke is run: on Phase 2's Sky mask, the near side's cells whose distance to the far side
/// is 0.6 of the brush's radius (`placed`), the longest such run, its middle. The rule was set, and the manifest it wrote frozen, before a
/// stroke was run; nothing is moved afterwards. `app` names a stroke the running app painted (`mask dump` of the drive hook): the same points
/// are painted on the full-size decode and the two kept shapes compared over the edge band, as `scaledAgainstFull` compares a scaled decode's.
@Suite(.serialized, .rawDecodes, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"
                                           && ProcessInfo.processInfo.environment["ARGENT_FOLLOW_FRAMES"] != nil
                                           && FileManager.default.fileExists(atPath: MaskCanary.models
                                               .appendingPathComponent("\(BundledMaskModel.sky.fileName)/main.hash").path)))
struct FollowEdgesGateTests {
    struct Entry: Codable {
        var stem: String
        var raw: String
        var label: String
        var radius: Float
        var points: [[Float]]
        var exposure: Float
        var lowContrast: Bool?
        /// Task N: a stroke to place by rule (`placed`), when `points` is empty.
        var place: Bool?
        /// The picture's size, written by the placement pass, so the app can be given the same points in long sides.
        var width: Int?, height: Int?
        /// Task N: a stroke the app painted, as `mask dump` writes it, compared with the same points painted on this full-size decode.
        var app: String?
        /// The sheet's 100 % windows (top left, 600 × 450), where given; else the two holding the most of the edge.
        var windows: [[Int]]?
    }

    struct Band: Codable {
        var farPixels = 0, nearPixels = 0, edgePixels = 0
        var farMean: Float = 0, farP95: Float = 0, nearMean: Float = 0, edgeMean: Float = 0
    }

    struct Stroke: Codable {
        var mode: String
        var band: Band
        var dabs = 0
        var tickGPUMedianMs: Double = 0, tickGPUMaxMs: Double = 0, tickWallMedianMs: Double = 0
        var measureMs: Double = 0, refineGPUMs: Double = 0, workingBytes = 0, coefficientBytes = 0
        var crop = "", pngBytes = 0
        /// Dab centres on the far side (Sky at least 0.5 there), of all its dabs: where the brush's centre left what it painted.
        var farCentres = 0
        var storeMs: Double = 0
    }

    struct Surface: Codable {
        var surface: String
        var size: Int
        var filmP99: Float, maskP99: Float, excess: Float, coverageP99: Float, bandPixels: Int
    }

    struct Result: Codable {
        var stem: String, label: String, lowContrast: Bool, width: Int, height: Int
        var strokes: [Stroke] = []
        var scaledAgainstFull: Float = 0, scaledAgainstFullMean: Float = 0
        /// The app's stroke (the frame view's decode) against the same points on the full-size decode, edge-band coverage p99 and mean.
        var appAgainstFull: Float?, appAgainstFullMean: Float?, appDabs: Int?
        /// The Oklab distance between the mean light of the near side and of the far side inside the footprint, and of the near side and
        /// the edge, on the guide frame: what the colour test sees across the edge (it lets a dab through below 0.05, not above 0.15).
        var nearFarDistance: Float = 0, nearEdgeDistance: Float = 0
        var surfaces: [Surface] = []
        var windows: [[Int]] = []
    }

    static let environment = ProcessInfo.processInfo.environment
    static var out: URL { URL(fileURLWithPath: environment["ARGENT_FOLLOW_OUT"] ?? NSTemporaryDirectory() + "argent-follow") }

    /// The stroke's points as the pointer gives them, every 6 px along the polyline, in `MaskSpace`.
    static func pointer(_ points: [[Float]], long: Float) -> [MaskPoint] {
        var out: [MaskPoint] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b[0] - a[0], dy = b[1] - a[1], steps = max(1, Int((dx * dx + dy * dy).squareRoot() / 6))
            for i in 0..<steps {
                let t = Float(i) / Float(steps)
                out.append(MaskPoint(x: (a[0] + dx * t) / long, y: (a[1] + dy * t) / long))
            }
        }
        if let last = points.last { out.append(MaskPoint(x: last[0] / long, y: last[1] / long)) }
        return out
    }

    /// Paints one stroke on `frame` (whose full-size picture is `picture`) through a session on the GPU's own field cache, and returns
    /// the brush component, the session's costs and its measured raster.
    static func paint(_ c: MaskRefinerSurfaceTests.Context, frame: LinearFrame, picture: MaskSpace, entry: Entry, follow: Bool,
                      perDab: Bool = true) throws -> (component: MaskComponent, stroke: Stroke, raster: MaskRaster?) {
        let mframe = try MaskFrame(orientation: 1, width: picture.width, height: picture.height, decoder: .raw9, lensCorrection: true)
        let mask = Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: mframe)))])
        let session = try BrushStrokeSession(gpu: c.gpu, picture: picture, mask: mask, component: 0,
                                             settings: BrushSettings(radius: entry.radius, feather: 0.5, flow: 1, followEdges: follow),
                                             refinement: c.gpu.maskRefiner.session(for: frame, picture: picture), perDab: perDab)
        var gpuTicks: [Double] = [], wallTicks: [Double] = []
        for point in pointer(entry.points, long: Float(picture.longSide)) {
            if try session.add(point) != nil { gpuTicks.append(session.lastTickGPUSeconds * 1000); wallTicks.append(session.lastTickSeconds * 1000) }
        }
        let painted = try #require(try session.end())
        var stroke = Stroke(mode: follow ? (perDab ? "follow" : "follow-first-dab") : "plain", band: Band())
        stroke.dabs = BrushDabPath.dabs(of: painted).count
        gpuTicks.sort(); wallTicks.sort()
        stroke.tickGPUMedianMs = gpuTicks.isEmpty ? 0 : gpuTicks[gpuTicks.count / 2]
        stroke.tickGPUMaxMs = gpuTicks.last ?? 0
        stroke.tickWallMedianMs = wallTicks.isEmpty ? 0 : wallTicks[wallTicks.count / 2]
        var raster: MaskRaster?
        if let measured = session.measurement {
            raster = measured.raster
            c.seeds.add(measured.raster)
            stroke.measureMs = session.measureSeconds * 1000
            stroke.refineGPUMs = measured.build.gpuSeconds * 1000
            stroke.workingBytes = measured.build.workingBytes
            stroke.coefficientBytes = measured.build.outputBytes
            stroke.crop = "\(measured.raster.width)x\(measured.raster.height) at \(measured.measured.x),\(measured.measured.y)"
            stroke.pngBytes = (try? MaskRasterStore.png(measured.raster).count) ?? 0
            // Kept as the brush's lane keeps it at the release: encoded, flushed and renamed into a library.
            let library = FileManager.default.temporaryDirectory.appendingPathComponent("argent-follow-store-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: library) }
            let started = Date()
            try MaskRasterStore(library: library).store(measured.raster)
            stroke.storeMs = Date().timeIntervalSince(started) * 1000
        }
        return (MaskComponent(shape: .brush(BrushPaint(frame: mframe, strokes: [painted]))), stroke, raster)
    }

    /// The brush component's strokes.
    static func strokes(_ component: MaskComponent) -> [BrushStroke] {
        if case .brush(let paint) = component.shape { return paint.strokes } else { return [] }
    }

    /// At most two 600 × 450 windows, not overlapping, each holding at least 2 % of its samples on the edge (coverage 0.1 to 0.9 inside
    /// the footprint), the most first. Coverage is the picture's bottom row first.
    static func windows(_ coverage: [Float], footprint: [Float], width: Int, height: Int) -> [(Int, Int)] {
        var scored: [(Int, Int, Int)] = []
        for y in stride(from: 0, through: height - 450, by: 40) {
            for x in stride(from: 0, through: width - 600, by: 40) {
                var n = 0
                for yy in stride(from: y, to: y + 450, by: 4) {
                    let row = (height - 1 - yy) * width
                    for xx in stride(from: x, to: x + 600, by: 4) where footprint[row + xx] >= 0.05 && coverage[row + xx] > 0.1 && coverage[row + xx] < 0.9 { n += 1 }
                }
                if n >= 150 * 113 / 50 { scored.append((n, x, y)) }
            }
        }
        var chosen: [(Int, Int)] = []
        for (_, x, y) in scored.sorted(by: { $0.0 > $1.0 }) where chosen.count < 2 {
            if chosen.allSatisfy({ abs($0.0 - x) >= 600 || abs($0.1 - y) >= 450 }) { chosen.append((x, y)) }
        }
        return chosen
    }

    /// A stroke the app painted, as the drive hook's `mask dump` writes it: its points and settings, and where its PNG of the kept shape is.
    struct AppStroke: Codable {
        var points: [[Float]]
        var radius: Float, feather: Float, flow: Float
        var x: Int, y: Int, width: Int, height: Int
        var pictureWidth: Int, pictureHeight: Int
        var png: String
    }

    /// The rule that places a stroke before any is run (task N), on the Sky mask's full-size coverage (row 0 the picture's bottom) over the picture
    /// `width` by `height`. In cells of about 8 pixels: the far side is Sky's mean at least 0.95, the near side at most 0.05. The stroke's centres
    /// are the near-side cells whose distance to the far side is within 0.75 cell of 0.6 of the brush's radius, at least 1.2 radii inside the picture,
    /// the largest connected run of them, the longest path through it, at most 25 radii of its middle, a point every half radius. Returns the
    /// points in the upright picture's pixels, or `nil` when no run is long enough to paint (at least 6 radii).
    static func placed(sky: [Float], width w: Int, height h: Int, radius: Float) -> [[Float]]? {
        let step = max(1, max(w, h) / 875)
        let cols = w / step, rows = h / step, rc = radius * Float(max(w, h)) / Float(step)
        var mean = [Float](repeating: 0, count: cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                var sum: Float = 0
                for y in stride(from: row * step, to: min(h, (row + 1) * step), by: 2) {
                    for x in stride(from: col * step, to: min(w, (col + 1) * step), by: 2) { sum += sky[(h - 1 - y) * w + x] }
                }
                mean[row * cols + col] = sum / Float(((step + 1) / 2) * ((step + 1) / 2))
            }
        }
        // Chamfer distance, in cells, to the far side.
        let inf: Float = 1e9, diag = Float(2.0).squareRoot()
        var d = mean.map { $0 >= 0.95 ? Float(0) : inf }
        for row in 0..<rows {
            for col in 0..<cols {
                let i = row * cols + col
                var best = d[i]
                if col > 0 { best = min(best, d[i - 1] + 1) }
                if row > 0 {
                    best = min(best, d[i - cols] + 1)
                    if col > 0 { best = min(best, d[i - cols - 1] + diag) }
                    if col + 1 < cols { best = min(best, d[i - cols + 1] + diag) }
                }
                d[i] = best
            }
        }
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for col in stride(from: cols - 1, through: 0, by: -1) {
                let i = row * cols + col
                var best = d[i]
                if col + 1 < cols { best = min(best, d[i + 1] + 1) }
                if row + 1 < rows {
                    best = min(best, d[i + cols] + 1)
                    if col + 1 < cols { best = min(best, d[i + cols + 1] + diag) }
                    if col > 0 { best = min(best, d[i + cols - 1] + diag) }
                }
                d[i] = best
            }
        }
        let inset = Int((1.2 * rc).rounded(.up)), target = 0.6 * rc
        var inBand = [Bool](repeating: false, count: cols * rows)
        if rows > 2 * inset, cols > 2 * inset {
            for row in inset..<(rows - inset) {
                for col in inset..<(cols - inset) {
                    let i = row * cols + col
                    inBand[i] = mean[i] <= 0.05 && abs(d[i] - target) <= 0.75
                }
            }
        }
        func neighbours(_ i: Int) -> [Int] {
            let row = i / cols, col = i % cols
            var out: [Int] = []
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let r = row + dy, c = col + dx
                    guard r >= 0, r < rows, c >= 0, c < cols else { continue }
                    let j = r * cols + c
                    if inBand[j] { out.append(j) }
                }
            }
            return out
        }
        // The largest connected run.
        var seen = [Bool](repeating: false, count: cols * rows), largest: [Int] = []
        for start in inBand.indices where inBand[start] && !seen[start] {
            var queue = [start], at = 0
            seen[start] = true
            while at < queue.count {
                for j in neighbours(queue[at]) where !seen[j] { seen[j] = true; queue.append(j) }
                at += 1
            }
            if queue.count > largest.count { largest = queue }
        }
        guard Float(largest.count) >= 6 * rc else { return nil }
        // The longest path through it: two sweeps, breadth first.
        func sweep(from start: Int) -> (far: Int, parent: [Int: Int]) {
            var parent = [start: start], queue = [start], at = 0, last = start
            while at < queue.count {
                let here = queue[at]
                last = here
                for j in neighbours(here) where parent[j] == nil { parent[j] = here; queue.append(j) }
                at += 1
            }
            return (last, parent)
        }
        let first = sweep(from: largest[0]), second = sweep(from: first.far)
        var path = [second.far]
        while let next = second.parent[path[path.count - 1]], next != path[path.count - 1] { path.append(next) }
        path.reverse()
        // Its middle, at most 25 radii, a point every half radius, each averaged with its neighbours along the path (the staircase of cells).
        let keep = min(path.count, Int(25 * rc)), from = (path.count - keep) / 2
        let run = Array(path[from..<(from + keep)])
        let every = max(1, Int((0.5 * rc).rounded()))
        func xy(_ i: Int) -> SIMD2<Float> { SIMD2(Float(i % cols) + 0.5, Float(i / cols) + 0.5) }
        var points: [[Float]] = []
        for k in stride(from: 0, to: run.count, by: every) {
            let a = max(0, k - every), b = min(run.count - 1, k + every)
            let m = (xy(run[a]) + xy(run[k]) * 2 + xy(run[b])) / 4 * Float(step)
            points.append([m.x, m.y])
        }
        return points.count >= 2 ? points : nil
    }

    /// A PNG of 8-bit gray values, as a raster, the file's bytes as they are.
    static func grayRaster(at url: URL) throws -> MaskRaster {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.bitsPerPixel == 8)
        let data = try #require(image.dataProvider?.data), bytes = try #require(CFDataGetBytePtr(data))
        var plane = [UInt8](repeating: 0, count: image.width * image.height)
        for row in 0..<image.height {
            for column in 0..<image.width { plane[row * image.width + column] = bytes[row * image.bytesPerRow + column] }
        }
        return try MaskRaster(width: image.width, height: image.height, plane: plane)
    }

    /// Paints `stroke`'s own points on `frame` through a session and returns its component, as `paint` does for a manifest's points.
    static func paintKept(_ c: MaskRefinerSurfaceTests.Context, frame: LinearFrame, picture: MaskSpace, app: AppStroke) throws -> MaskComponent {
        let mframe = try MaskFrame(orientation: 1, width: picture.width, height: picture.height, decoder: .raw9, lensCorrection: true)
        let mask = Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: mframe)))])
        let session = try BrushStrokeSession(gpu: c.gpu, picture: picture, mask: mask, component: 0,
                                             settings: BrushSettings(radius: app.radius, feather: app.feather, flow: app.flow, followEdges: true),
                                             refinement: c.gpu.maskRefiner.session(for: frame, picture: picture))
        for point in app.points { try session.add(MaskPoint(x: point[0], y: point[1])) }
        let painted = try #require(try session.end())
        c.seeds.add(try #require(session.measurement).raster)
        return MaskComponent(shape: .brush(BrushPaint(frame: mframe, strokes: [painted])))
    }

    static func band(_ coverage: [Float], footprint: [Float], sky: [Float]) -> Band {
        var b = Band(), far: [Float] = []
        var near: Double = 0, edge: Double = 0
        for i in coverage.indices where footprint[i] >= 0.5 {
            if sky[i] >= 0.95 { far.append(coverage[i]) } else if sky[i] <= 0.05 { near += Double(coverage[i]); b.nearPixels += 1 } else {
                edge += Double(coverage[i]); b.edgePixels += 1
            }
        }
        b.farPixels = far.count
        b.farMean = far.isEmpty ? 0 : Float(far.reduce(0.0) { $0 + Double($1) } / Double(far.count))
        far.sort()
        b.farP95 = far.isEmpty ? 0 : far[min(far.count - 1, Int(Float(far.count) * 0.95))]
        b.nearMean = b.nearPixels == 0 ? 0 : Float(near / Double(b.nearPixels))
        b.edgeMean = b.edgePixels == 0 ? 0 : Float(edge / Double(b.edgePixels))
        return b
    }

    @Test func followEdgesOnRealFrames() async throws {
        let c = try MaskRefinerSurfaceTests.context()
        let out = Self.out, pieces = out.appendingPathComponent("pieces")
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("argent-follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: MaskCanary.models, ledgerFile: support.appendingPathComponent("ledger.json"))
        defer { try? AIModelCache.default.deleteEntries(for: try models.url(of: .sky)) }
        try await models.skyRunner.load(from: try models.url(of: .sky))
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: try #require(Self.environment["ARGENT_FOLLOW_FRAMES"]))))
        var results: [Result] = [], placedEntries: [Entry] = []
        for entry in entries {
            let url = URL(fileURLWithPath: entry.raw)
            var options = DecodeOptions()
            options.tileSize = RollDeveloper.decodeTile
            options.learnedTileSize = RollDeveloper.learnedDecodeTile
            let develop = try c.decoder.decode(url, options: options)
            let picture = try develop.maskPicture
            let (w, h) = (develop.width, develop.height)
            var result = Result(stem: entry.stem, label: entry.label, lowContrast: entry.lowContrast ?? false, width: w, height: h)
            let base = try MaskRefinerSurfaceTests.settings(c, url, grain: false)

            // The band's answer: Phase 2's Sky mask on this decode.
            let input = try MaskInputPictureMaker(gpu: c.gpu).make(from: develop)
            let outputs = try await models.skyRunner.run(ModelSquare(input, side: SkyModelRunner.side, padding: SkyModelRunner.padding))
            let seed = WaterVeto.quantize(outputs.seed.values, width: outputs.seed.width, height: outputs.seed.height)
            c.seeds.add(seed)
            let skyComponent = try MaskRefinerSurfaceTests.component("sky", seed, background: false, width: w, height: h)
            let sky = try #require(try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop,
                                                                     try MaskRefinerSurfaceTests.masked(base, skyComponent, exposure: -1.5), coverage: true).coverage)

            // Plain, Follow edges, Follow edges with the first dab's colour.
            // Task N's placement pass: the rule's points, written and frozen before any stroke is run.
            if let placing = Self.environment["ARGENT_FOLLOW_PLACE"], entry.points.isEmpty {
                var placed = entry
                placed.width = w
                placed.height = h
                placed.points = Self.placed(sky: sky, width: w, height: h, radius: entry.radius) ?? []
                print("[follow] \(entry.stem) placed \(placed.points.count) points")
                placedEntries.append(placed)
                c.gpu.maskRefiner.removeAll()
                c.gpu.maskFields.removeAll()
                if entry.stem == entries.last?.stem {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(placedEntries).write(to: URL(fileURLWithPath: placing))
                }
                continue
            }
            let plain = try Self.paint(c, frame: develop, picture: picture, entry: entry, follow: false)
            let follow = try Self.paint(c, frame: develop, picture: picture, entry: entry, follow: true)
            let first = try Self.paint(c, frame: develop, picture: picture, entry: entry, follow: true, perDab: false)
            let plainRender = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop,
                                                                 try MaskRefinerSurfaceTests.masked(base, plain.component, exposure: entry.exposure), coverage: true)
            let footprint = try #require(plainRender.coverage)
            var coverages: [String: [Float]] = ["plain": footprint]
            for (name, painted) in [("follow", follow), ("follow-first-dab", first)] {
                coverages[name] = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop,
                    try MaskRefinerSurfaceTests.masked(base, painted.component, exposure: entry.exposure), coverage: true).coverage
            }
            let long = Float(picture.longSide)
            let centres = BrushDabPath.dabs(of: try #require(Self.strokes(follow.component).first)).filter { dab in
                let x = min(max(Int(dab.x * long), 0), w - 1), y = min(max(Int(dab.y * long), 0), h - 1)
                return sky[(h - 1 - y) * w + x] >= 0.5
            }.count
            for (name, painted) in [("plain", plain), ("follow", follow), ("follow-first-dab", first)] {
                var stroke = painted.stroke
                stroke.farCentres = centres
                stroke.band = Self.band(try #require(coverages[name]), footprint: footprint, sky: sky)
                result.strokes.append(stroke)
                print("[follow] \(entry.stem) \(name): \(stroke)")
            }

            // What the colour test sees across the edge: the sides' mean light on the guide frame, in Oklab.
            do {
                let size = MaskFieldSize(picture: picture)
                let light = MaskRefinerSurfaceTests.pixels(try c.gpu.maskRefiner.guideFrame(for: develop, size: size))
                var sums = [SIMD3<Double>](repeating: .zero, count: 3), counts = [Double](repeating: 0, count: 3)
                for row in 0..<size.height {
                    let y = min(h - 1, Int((Double(row) + 0.5) * Double(h) / Double(size.height)))
                    for column in 0..<size.width {
                        let x = min(w - 1, Int((Double(column) + 0.5) * Double(w) / Double(size.width))), i = y * w + x
                        guard footprint[i] >= 0.5 else { continue }
                        let side = sky[i] >= 0.95 ? 1 : sky[i] <= 0.05 ? 0 : 2
                        let p = light[row * size.width + column]
                        sums[side] += SIMD3(Double(p.x), Double(p.y), Double(p.z)); counts[side] += 1
                    }
                }
                func lab(_ side: Int) -> SIMD3<Float> {
                    let m = sums[side] / max(counts[side], 1)
                    return FollowEdges.oklab(SIMD3(Float(m.x), Float(m.y), Float(m.z)))
                }
                func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { ((a - b) * (a - b)).sum().squareRoot() }
                result.nearFarDistance = distance(lab(0), lab(1))
                result.nearEdgeDistance = distance(lab(0), lab(2))
                print("[follow] \(entry.stem) Oklab distance near to far \(result.nearFarDistance), near to edge \(result.nearEdgeDistance)")
            }

            // The same stroke painted on the frame view's scaled decode, before it refines: the kept shape against the full decode's.
            let scaledDecode = try c.decoder.decode(url, options: FilmPreviews.frameDecodeOptions(longSide: 2190))
            let scaled = try Self.paint(c, frame: scaledDecode, picture: picture, entry: entry, follow: true)
            let scaledCoverage = try #require(try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop,
                try MaskRefinerSurfaceTests.masked(base, scaled.component, exposure: entry.exposure), coverage: true).coverage)
            let followCoverage = try #require(coverages["follow"])
            let edge = MaskRefinerSurfaceTests.band(followCoverage, width: w, height: h)
            result.scaledAgainstFull = MaskRefinerSurfaceTests.p99(scaledCoverage, followCoverage, in: edge)
            var sum: Double = 0, n = 0
            for i in edge.indices where edge[i] { sum += Double(abs(scaledCoverage[i] - followCoverage[i])); n += 1 }
            result.scaledAgainstFullMean = n == 0 ? 0 : Float(sum / Double(n))

            // The app's stroke, where given: the shape the running app kept (on the frame view's decode) against the same points on this one.
            if let path = entry.app {
                let app = try JSONDecoder().decode(AppStroke.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                let raster = try Self.grayRaster(at: URL(fileURLWithPath: app.png))
                c.seeds.add(raster)
                let measured = try MeasuredStroke(raster: raster.ref, x: app.x, y: app.y, pictureWidth: app.pictureWidth, pictureHeight: app.pictureHeight)
                let mframe = try MaskFrame(orientation: 1, width: picture.width, height: picture.height, decoder: .raw9, lensCorrection: true)
                let kept = MaskComponent(shape: .brush(BrushPaint(frame: mframe, strokes: [
                    BrushStroke(followEdges: true, radius: app.radius, feather: app.feather, flow: app.flow,
                                points: try PackedPoints.pack(app.points.map { MaskPoint(x: $0[0], y: $0[1]) }), measured: measured)])))
                let again = try Self.paintKept(c, frame: develop, picture: picture, app: app)
                func coverage(_ component: MaskComponent) throws -> [Float] {
                    try #require(try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop,
                        try MaskRefinerSurfaceTests.masked(base, component, exposure: entry.exposure), coverage: true).coverage)
                }
                let inApp = try coverage(kept), full = try coverage(again)
                let appBand = MaskRefinerSurfaceTests.band(full, width: w, height: h)
                result.appAgainstFull = MaskRefinerSurfaceTests.p99(inApp, full, in: appBand)
                var sum: Double = 0, n = 0
                for i in appBand.indices where appBand[i] { sum += Double(abs(inApp[i] - full[i])); n += 1 }
                result.appAgainstFullMean = n == 0 ? 0 : Float(sum / Double(n))
                result.appDabs = app.points.count
                print("[follow] \(entry.stem) app against full: p99 \(result.appAgainstFull ?? -1) mean \(result.appAgainstFullMean ?? -1), points \(app.points.count)")
            }

            // Preview against develop: the frame view's refined decode at 2190, and the sheet's 960, each reading the kept shape.
            let followSettings = try MaskRefinerSurfaceTests.masked(base, follow.component, exposure: entry.exposure)
            let developed = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop, followSettings, coverage: true)
            let developPlain = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop, base, coverage: false).image
            var sheetOptions = DecodeOptions()
            sheetOptions.maxLongSide = FilmPreviews.previewLongSide
            let sheet = try c.decoder.decode(url, options: sheetOptions)
            let refinedTexture = try MaskRefinerSurfaceTests.resizedTexture(c.gpu, c.resize, develop.texture, width: scaledDecode.width, height: scaledDecode.height)
            let refined = LinearFrame(image: PooledTexture(unpooled: refinedTexture), decoderVersion: develop.decoderVersion,
                                      scale: Float(scaledDecode.width) / Float(w), picture: develop.picture)
            for (surface, preview) in [("refined", refined), ("sheet", sheet)] {
                let (pw, ph) = (preview.width, preview.height)
                let developL = MaskRefinerSurfaceTests.lightness(MaskRefinerSurfaceTests.pixels(
                    try MaskRefinerSurfaceTests.resizedTexture(c.gpu, c.resize, developed.image.texture, width: pw, height: ph)))
                let developPlainL = MaskRefinerSurfaceTests.lightness(MaskRefinerSurfaceTests.pixels(
                    try MaskRefinerSurfaceTests.resizedTexture(c.gpu, c.resize, developPlain.texture, width: pw, height: ph)))
                let developC = MaskRefinerSurfaceTests.resized(try #require(developed.coverage), width: w, height: h, toWidth: pw, toHeight: ph)
                let band = MaskRefinerSurfaceTests.band(developC, width: pw, height: ph)
                let shown = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, preview, followSettings, coverage: true)
                let previewPlain = MaskRefinerSurfaceTests.lightness(MaskRefinerSurfaceTests.pixels(
                    try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, preview, base, coverage: false).image.texture))
                let film = MaskRefinerSurfaceTests.p99(previewPlain, developPlainL, in: band)
                let mask = MaskRefinerSurfaceTests.p99(MaskRefinerSurfaceTests.lightness(MaskRefinerSurfaceTests.pixels(shown.image.texture)), developL, in: band)
                let coverage = MaskRefinerSurfaceTests.p99(try #require(shown.coverage), developC, in: band)
                let row = Surface(surface: surface, size: max(pw, ph), filmP99: film, maskP99: mask, excess: mask - film, coverageP99: coverage,
                                  bandPixels: band.reduce(0) { $0 + ($1 ? 1 : 0) })
                result.surfaces.append(row)
                print("[follow] \(entry.stem) surface \(row)")
            }

            // The sheet's pieces: plain | Follow edges | its coverage, at fit and at 100 % on the edge.
            let followRender = developed.image
            let fitLong = 1000, scale = Float(fitLong) / Float(max(w, h))
            let (fw, fh) = (Int((Float(w) * scale).rounded()), Int((Float(h) * scale).rounded()))
            for (name, image) in [("plain", plainRender.image), ("follow", followRender)] {
                let small = try MaskRefinerSurfaceTests.resizedTexture(c.gpu, c.resize, image.texture, width: fw, height: fh)
                try MaskRefinerSurfaceTests.crop(c.gpu, small, x: 0, y: 0, width: fw, height: fh, to: pieces.appendingPathComponent("\(entry.stem)_fit_\(name).png"))
            }
            for (name, values) in [("coverage", followCoverage), ("plaincoverage", footprint), ("sky", sky)] {
                try MaskRefinerSurfaceTests.crop(coverage: MaskRefinerSurfaceTests.resized(values, width: w, height: h, toWidth: fw, toHeight: fh),
                                                 width: fw, height: fh, x: 0, y: 0, w: fw, h: fh, to: pieces.appendingPathComponent("\(entry.stem)_fit_\(name).png"))
            }
            // Windows on the edge the stroke followed: the most Follow edges coverage between 0.1 and 0.9 inside the stroke's footprint,
            // or the manifest's.
            let windows = entry.windows.map { $0.map { ($0[0], $0[1]) } } ?? Self.windows(followCoverage, footprint: footprint, width: w, height: h)
            result.windows = windows.map { [$0.0, $0.1] }
            let unmasked = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop, base, coverage: false).image
            for (index, (x, y)) in windows.enumerated() {
                // The same window with no mask at all: what the print's colour is there with nothing ending at the edge (task N's fringe check).
                try MaskRefinerSurfaceTests.crop(c.gpu, unmasked.texture, x: x, y: y, width: 600, height: 450,
                                                 to: pieces.appendingPathComponent("\(entry.stem)_w\(index)_none.png"))
                try MaskRefinerSurfaceTests.crop(c.gpu, plainRender.image.texture, x: x, y: y, width: 600, height: 450,
                                                 to: pieces.appendingPathComponent("\(entry.stem)_w\(index)_plain.png"))
                try MaskRefinerSurfaceTests.crop(c.gpu, followRender.texture, x: x, y: y, width: 600, height: 450,
                                                 to: pieces.appendingPathComponent("\(entry.stem)_w\(index)_follow.png"))
                try MaskRefinerSurfaceTests.crop(coverage: followCoverage, width: w, height: h, x: x, y: y, w: 600, h: 450,
                                                 to: pieces.appendingPathComponent("\(entry.stem)_w\(index)_coverage.png"))
                try MaskRefinerSurfaceTests.crop(coverage: sky, width: w, height: h, x: x, y: y, w: 600, h: 450,
                                                 to: pieces.appendingPathComponent("\(entry.stem)_w\(index)_sky.png"))
            }
            results.append(result)
            c.gpu.maskRefiner.removeAll()
            c.gpu.maskFields.removeAll()
        }
        await models.skyRunner.unload()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: out.appendingPathComponent("follow-edges.json"))
    }
}

/// The kept shape's 8-bit steps on a soft-sided stroke, printed at ±5 EV through Portra 400 on a flat grey picture (task N; plan section 4, "0.5 L* a step" at ±5 EV): a Follow edges
/// stroke's kept shape against the same stroke's half-float canvas, along the row through its centre, full-size, grain off (the steps alone) and on. A dab of
/// radius 0.2, Feather 100 is the slowest ramp a brush can paint, so its steps are the widest it can have: 1.6 slice texels, 5.6 full-size pixels a step.
///
///     ARGENT_MEASURE=1 ARGENT_FOLLOW_BANDING=<folder> swift test -c release -Xswiftc -enable-testing --filter FollowEdgesBandingTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"
                              && ProcessInfo.processInfo.environment["ARGENT_FOLLOW_BANDING"] != nil))
struct FollowEdgesBandingTests {
    struct Row: Codable {
        var ev: Float, grain: Bool, shape: String
        var rampPixels: Int
        var deviationMaxL: Float, deviationMeanL: Float
        /// The largest change of the shape's L* minus the half-float stroke's over a window of 8 pixels: how far a step lifts off the smooth ramp.
        var localContrastL: Float
        /// The largest change between neighbouring pixels of the 8-bit sRGB code, of the shape and of the half-float stroke.
        var largestCodeStep: Int, plainLargestCodeStep: Int
        var meanL: Float, flatGrainStdL: Float
    }

    static func flat(_ gpu: GPU, value: Float, picture: MaskSpace) throws -> LinearFrame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: picture.width, height: picture.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(gpu.device.makeTexture(descriptor: descriptor))
        var row = [Float16](repeating: 1, count: picture.width * 4)
        for x in 0..<picture.width { row[x * 4] = Float16(value); row[x * 4 + 1] = Float16(value); row[x * 4 + 2] = Float16(value) }
        for y in 0..<picture.height { row.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, y, picture.width, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: picture.width * 8) } }
        return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "banding", scale: 1, picture: picture)
    }

    static func row(_ texture: MTLTexture, y: Int) -> [SIMD3<Float>] {
        var halves = [Float16](repeating: 0, count: texture.width * 4)
        halves.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, y, texture.width, 1), mipmapLevel: 0) }
        return (0..<texture.width).map { SIMD3(Float(halves[$0 * 4]), Float(halves[$0 * 4 + 1]), Float(halves[$0 * 4 + 2])) }
    }

    static func code(_ rgb: SIMD3<Float>) -> Int {
        let y = max((rgb * Rec2020.luma).sum(), 0)
        let e = y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
        return Int((min(max(e, 0), 1) * 255).rounded())
    }

    @Test func theKeptShapesSteps() throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARGENT_FOLLOW_BANDING"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let c = try MaskRefinerSurfaceTests.context()
        let picture = try MaskSpace(width: 7008, height: 4672)
        let frame = try Self.flat(c.gpu, value: 0.18, picture: picture)
        let mframe = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let centre = MaskPoint(x: 0.5, y: 1 / 3)
        func stroke(follow: Bool) throws -> MaskComponent {
            let mask = Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: mframe)))])
            let session = try BrushStrokeSession(gpu: c.gpu, picture: picture, mask: mask, component: 0,
                                                 settings: BrushSettings(radius: 0.2, feather: 1, flow: 1, followEdges: follow),
                                                 refinement: c.gpu.maskRefiner.session(for: frame, picture: picture))
            try session.add(centre)
            let painted = try #require(try session.end())
            if let m = session.measurement { c.seeds.add(m.raster); print("[banding] kept shape \(m.raster.width) x \(m.raster.height) at \(m.measured.x),\(m.measured.y)") }
            return MaskComponent(shape: .brush(BrushPaint(frame: mframe, strokes: [painted])))
        }
        let kept = try stroke(follow: true), plain = try stroke(follow: false)
        var settings = RollControls().settings(for: c.renderer.stock, aim: PrintAim())
        settings.halation = false
        settings.sharpen = false
        settings.manual = try ManualRenderSettings(adjustments: .identity, referenceStops: PrintAim().level)
        let y = picture.height / 2
        var rows: [Row] = []
        for ev in [Float(5), -5] {
            for grain in [false, true] {
                var s = settings
                if grain { s.grain = 1; s.grainSeed = 1 }
                func line(_ component: MaskComponent) throws -> [SIMD3<Float>] {
                    let rendered = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, frame, try MaskRefinerSurfaceTests.masked(s, component, exposure: ev), coverage: false)
                    return Self.row(rendered.image.texture, y: y)
                }
                let a = try line(kept), b = try line(plain)
                let la = MaskRefinerSurfaceTests.lightness(a), lb = MaskRefinerSurfaceTests.lightness(b)
                let mid = 3504, reach = Int(0.2 * 7008)
                let ramp = (mid - reach)..<(mid + reach)
                let difference = ramp.map { la[$0] - lb[$0] }
                let deviation = difference.map(abs)
                var local: Float = 0
                for i in 0..<(difference.count - 8) {
                    let window = difference[i..<(i + 8)]
                    local = max(local, (window.max() ?? 0) - (window.min() ?? 0))
                }
                var keptStep = 0, plainStep = 0
                for i in ramp.lowerBound..<(ramp.upperBound - 1) {
                    keptStep = max(keptStep, abs(Self.code(a[i]) - Self.code(a[i + 1])))
                    plainStep = max(plainStep, abs(Self.code(b[i]) - Self.code(b[i + 1])))
                }
                // The film's grain alone, on the flat picture outside the stroke: what a step has to show through.
                let flat = la[0..<(mid - reach - 200)]
                let mean = flat.reduce(0, +) / Float(flat.count)
                let std = (flat.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(flat.count)).squareRoot()
                let row = Row(ev: ev, grain: grain, shape: "kept vs half-float canvas", rampPixels: ramp.count,
                              deviationMaxL: deviation.max() ?? 0, deviationMeanL: deviation.reduce(0, +) / Float(deviation.count), localContrastL: local,
                              largestCodeStep: keptStep, plainLargestCodeStep: plainStep, meanL: la[ramp].reduce(0, +) / Float(ramp.count), flatGrainStdL: std)
                print("[banding] \(row)")
                rows.append(row)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: out.appendingPathComponent("banding.json"))
    }
}
