import ArgentCore
import CoreGraphics
import CryptoKit
import Foundation
import Testing
import Vision
import simd
@testable import ArgentRoll

/// How far the sequence evidence reaches with a finer picture of each frame, or with Vision's
/// registration, on the development split of the 2026-10-22 benchmark only
/// (docs/research/auto/sequence-reach.md, section 2). Runs only with ARGENT_MEASURE=1 and the protocol:
///
///     ARGENT_MEASURE=1 ARGENT_CUBEPP_GRID=cells \
///       ARGENT_CUBEPP_COHORT=$PWD/docs/research/auto/gate-protocol/cubepp-cohort-2234.txt \
///       ARGENT_SEQUENCE_PROTOCOL=<evidence root>/benchmark/protocol.json ARGENT_SEQUENCE_OUT=<folder> \
///       swift test -c release -Xswiftc -enable-testing --skip-build --filter SequenceReachMeasureTests
///
/// The development split is `SequenceEvidenceMeasureTests`' (its loaders, its pairs, its matcher rule:
/// recall of dev P with false links at most 5 % of dev changed-light pairs and of dev pairs labelled
/// different within 120 s). No frame of a test session is decoded, described or matched: the 2026-10-22
/// test split is spent. The loaders read development sessions only; before they run, the run refuses
/// ARGENT_SEQUENCE_SPLIT (the benchmark's variable) set to anything but `dev`, and after them it checks that
/// every session they returned is a development one, which guards against a change to them
/// (`SequenceReachGuardTests` runs the refusal through `measureReach`).
///
/// Every setting keeps candidate B's frozen evidence parameters (`Parameters.frozenRender`) and the
/// matcher's own constants (`SequenceEvidence.Tuning.standard`) except where it names one:
///
/// - **today**: `SequenceEvidence.links` as built. This file's copy of the search at 64 cells and one
///   octave must give the same links bit for bit, and its mapped verification the same match, or the run fails.
/// - **wider zoom** (ablation): today's 64 cells, scales searched to 2^`octaves`.
/// - **finer**: `SequenceDescriptor` made the same way from the same analysis grid (240 cells on the long
///   side), with `longSide` 96 or 120 cells instead of 64; the search's coarse level the deepest whose
///   frames stay 12 cells long, up to the third; blocks `blockSide` cells of the finer picture.
/// - **vision**: `VNHomographicImageRegistrationRequest` between the two frames' analysis grids as 8-bit
///   thumbnails (log2 luminance less the frame's median, 32 levels a stop), the earlier frame the
///   reference; the homography replaces the search and is verified as the search's alignment is.
/// - **vision refines**: when none of the search's alignments verifies, its best-scoring one handed to
///   Vision as a starting point (the later thumbnail warped onto the earlier by it) and the refined
///   homography verified instead.
///
/// **Reach probes** (a7 IV development frames only, synthetic): each frame's sheet decode against a crop
/// of its own 3840-pixel decode at zoom `z`, resampled to the sheet's size, its light moved by a set
/// shift of −1 to +1 stop that the camera's exposure is taken to account for; and, for dim light, both
/// darkened by `d` stops with a 1.25× crop. A probe counts when the pair matches, its colour holds and its
/// light change is within `lightTolerance`. Crops come from one decode of one instant: no parallax, no
/// motion, the same noise; they bound reach from above.
///
/// ARGENT_REACH_ONLY lists the options to run (comma separated); ARGENT_REACH_PROBES=none skips the
/// probes. Writes runs.csv, summary.md, pairs.csv and probes.csv under ARGENT_SEQUENCE_OUT, which must lie
/// outside the repository and the photographs.
@Suite(.serialized) struct SequenceReachMeasureTests {
    typealias E = SequenceEvidenceMeasureTests
    typealias L = LabBalanceMeasureTests
    typealias M = FrameViewMeasureTests
    typealias S = SeriesMeasureTests
    typealias Pyramid = SequenceEvidence.Pyramid

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    struct Refusal: Error, CustomStringConvertible {
        var description: String
    }

    /// Refuses any split but the development one: the 2026-10-22 test split is spent.
    static func requireDevelopment(_ environment: [String: String]) throws {
        if let split = environment["ARGENT_SEQUENCE_SPLIT"], split != "dev" {
            throw Refusal(description: "this harness reads the development split only; ARGENT_SEQUENCE_SPLIT is \"\(split)\"")
        }
    }

    /// Refuses `sessions` unless the protocol's `units` puts every one in the development split.
    static func requireDevelopment(sessions: [String], units: [String: String]) throws {
        let others = sessions.filter { units[$0] != "dev" }
        if !others.isEmpty { throw Refusal(description: "not development sessions: \(others.sorted().joined(separator: ", "))") }
    }

    /// The finer pictures measured besides today's 64 cells.
    static let longSides = [64, 96, 120]

    // MARK: Pictures

    /// `SequenceDescriptor(grid:)` with `longSide` cells on its long side: the same light, share and
    /// detail over coarser or finer blocks of the grid. At 64 it is the shipped descriptor bit for bit.
    static func descriptor(_ grid: ExposureAnalyzer.Grid, longSide: Int) -> SequenceDescriptor {
        var d = SequenceDescriptor(grid: ExposureAnalyzer.grid(pixels: [], width: 0, height: 0))
        let gridWidth = grid.width, gridHeight = grid.height
        if gridWidth < 1 || gridHeight < 1 {
            (d.width, d.height) = (0, 0)
        } else if max(gridWidth, gridHeight) <= longSide {
            (d.width, d.height) = (gridWidth, gridHeight)
        } else {
            let long = max(gridWidth, gridHeight), short = min(gridWidth, gridHeight)
            let side = max(1, (2 * longSide * short + long) / (2 * long))
            (d.width, d.height) = gridWidth >= gridHeight ? (longSide, side) : (side, longSide)
        }
        let width = d.width, height = d.height, count = width * height
        d.rgb = []; d.unclipped = []; d.detail = []
        d.rgb.reserveCapacity(count * 3); d.unclipped.reserveCapacity(count); d.detail.reserveCapacity(count)
        let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
        let stops = grid.all.map { log2(max(($0 * Rec2020.luma).sum(), floor)) }
        for v in 0..<height {
            let rows = SequenceDescriptor.gridSpan(v, of: height, over: gridHeight)
            for u in 0..<width {
                let columns = SequenceDescriptor.gridSpan(u, of: width, over: gridWidth)
                let n = Float(rows.count * columns.count)
                var light = SIMD3<Float>(repeating: 0), share: Float = 0, offset: Float = 0
                let first = stops[rows.lowerBound * gridWidth + columns.lowerBound]
                for row in rows {
                    for column in columns {
                        let index = row * gridWidth + column
                        light += grid.all[index]
                        share += grid.unclipped[index]
                        offset += stops[index] - first
                    }
                }
                let mean = offset / n
                var spread: Float = 0
                for row in rows {
                    for column in columns {
                        let e = stops[row * gridWidth + column] - first - mean
                        spread += e * e
                    }
                }
                light /= n
                d.rgb.append(light.x); d.rgb.append(light.y); d.rgb.append(light.z)
                d.unclipped.append(share / n)
                d.detail.append((spread / n).squareRoot())
            }
        }
        return d
    }

    /// A frame's analysis grid as Vision reads it: each cell's log2 luminance less the frame's median,
    /// 32 levels a stop about 128, clamped; masked cells (all zero, Cube++'s cube) at 128. Rows from the
    /// bottom, as the grid's, so a pixel's coordinates are the grid's.
    struct Thumbnail: Sendable {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int, bytes: [UInt8]) {
            (self.width, self.height, self.bytes) = (width, height, bytes)
        }

        init(_ grid: ExposureAnalyzer.Grid) {
            let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
            let masked = grid.all.map { $0 == .zero }
            let logs = grid.all.map { log2(max(($0 * Rec2020.luma).sum(), floor)) }
            let kept = zip(logs, masked).filter { !$0.1 }.map(\.0).sorted()
            let median = kept.isEmpty ? 0 : kept[kept.count / 2]
            width = grid.width
            height = grid.height
            bytes = zip(logs, masked).map { log, masked in
                masked || !log.isFinite ? 128 : UInt8(min(max((128 + 32 * (log - median)).rounded(), 0), 255))
            }
        }

        /// The thumbnail as an image, its first row the picture's top.
        var image: CGImage {
            var rows = [UInt8](repeating: 0, count: width * height)
            for r in 0..<height { rows[(height - 1 - r) * width..<(height - r) * width] = bytes[r * width..<(r + 1) * width] }
            let provider = CGDataProvider(data: Data(rows) as CFData)!
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }

        /// The value at `p` (pixels from the bottom-left corner), bilinear between pixel centres; 128 outside.
        func sample(_ p: SIMD2<Float>) -> Float {
            let fx = p.x - 0.5, fy = p.y - 0.5
            guard fx.isFinite, fy.isFinite, fx >= -0.5, fy >= -0.5, fx <= Float(width) - 0.5, fy <= Float(height) - 0.5 else { return 128 }
            let cx = min(max(fx, 0), Float(width - 1)), cy = min(max(fy, 0), Float(height - 1))
            let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let wx = cx - Float(x0), wy = cy - Float(y0)
            func at(_ x: Int, _ y: Int) -> Float { Float(bytes[y * width + x]) }
            return (at(x0, y0) * (1 - wx) + at(x1, y0) * wx) * (1 - wy) + (at(x0, y1) * (1 - wx) + at(x1, y1) * wx) * wy
        }
    }

    /// One frame as the options read it: its header, its descriptors by long side and its thumbnail.
    struct Picture: Sendable {
        var info: ARWFrameInfo
        var descriptors: [Int: SequenceDescriptor]
        var thumbnail: Thumbnail

        init(info: ARWFrameInfo, grid: ExposureAnalyzer.Grid) {
            self.info = info
            descriptors = Dictionary(uniqueKeysWithValues: SequenceReachMeasureTests.longSides.map {
                ($0, SequenceReachMeasureTests.descriptor(grid, longSide: $0))
            })
            thumbnail = Thumbnail(grid)
        }

        /// Level-0 cells of the `longSide` descriptor per thumbnail pixel, on each axis.
        func cellsPerPixel(_ longSide: Int) -> SIMD2<Float> {
            let d = descriptors[longSide]!
            return SIMD2(Float(d.width) / Float(thumbnail.width), Float(d.height) / Float(thumbnail.height))
        }
    }

    /// A grid with its light moved `stops` stops; shares of clipped pixels are left as they were.
    static func shifted(_ grid: ExposureAnalyzer.Grid, stops: Float) -> ExposureAnalyzer.Grid {
        var g = grid
        let k = exp2(stops)
        g.all = g.all.map { $0 * k }
        g.light = g.light.map { $0 * k }
        return g
    }

    // MARK: Settings

    enum Align: String, Sendable { case shipped, search, vision, refined }

    struct Variant: Sendable {
        var name: String
        var option: String
        var longSide = 64
        var octaves = 1
        var align: Align = .search
        var parameters = SequenceAims.Parameters.frozenRender
        var tuning = SequenceEvidence.Tuning.standard

        var maximumScale: Float { exp2(Float(octaves)) * 1.05 }
    }

    /// Every setting measured, in the summary's order: today, the wider-zoom ablation, the finer
    /// descriptor, Vision alone and Vision refining the search.
    static func variants() -> [Variant] {
        var list = [Variant(name: "today", option: "today", align: .shipped)]
        list.append(Variant(name: "wider-64x2", option: "wider zoom", octaves: 2))
        for side in [96, 120] {
            for octaves in [1, 2] {
                for block in [10, 16] {
                    for agreeing in [3, 4, 6] {
                        var v = Variant(name: "finer-\(side)x\(octaves)-b\(block)-a\(agreeing)", option: "finer", longSide: side, octaves: octaves)
                        v.tuning.blockSide = block
                        v.tuning.agreeingBlocks = agreeing
                        list.append(v)
                    }
                }
            }
        }
        for (align, option) in [(Align.vision, "vision"), (.refined, "vision refines")] {
            for (side, block) in [(64, 10), (120, 10), (120, 16)] {
                for agreeing in [3, 4] {
                    var v = Variant(name: "\(align.rawValue)-\(side)-b\(block)-a\(agreeing)", option: option, longSide: side, octaves: 2,
                                    align: align)
                    v.tuning.blockSide = block
                    v.tuning.agreeingBlocks = agreeing
                    list.append(v)
                }
            }
        }
        guard let only = environment["ARGENT_REACH_ONLY"] else { return list }
        let options = Set(only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return list.filter { options.contains($0.option) || $0.option == "today" }
    }

    // MARK: Search

    /// `SequenceEvidence.evaluate` with scales up to `maximumScale`.
    static func evaluate(_ alignment: SequenceEvidence.Alignment, source: Pyramid, target: Pyramid, level: Int,
                         minimumOverlap: Float, maximumScale: Float) -> Double? {
        guard alignment.scale >= 0.99, alignment.scale <= maximumScale,
              alignment.overlap(source: (source.width, source.height), target: (target.width, target.height)) >= minimumOverlap
        else { return nil }
        let l = SequenceEvidence.level(for: alignment.scale, in: target, above: level)
        let map = target.levels[l]
        var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        for cell in source.levels[level].cells {
            guard let b = SequenceEvidence.sampledLog(map, level: l, at: alignment.map(cell.point, width: source.width, height: source.height))
            else { continue }
            let a = Double(cell.log), bb = Double(b)
            n += 1; sa += a; sb += bb; saa += a * a; sbb += bb * bb; sab += a * bb
        }
        return SequenceEvidence.score(n: n, sa: sa, sb: sb, saa: saa, sbb: sbb, sab: sab, minimum: 24)?.z
    }

    /// `SequenceEvidence.refine` with scales up to `maximumScale`.
    static func refine(_ alignment: SequenceEvidence.Alignment, source: Pyramid, target: Pyramid, from level: Int,
                       minimumOverlap: Float, maximumScale: Float) -> SequenceEvidence.Alignment? {
        var best = alignment, bestScore = -Double.infinity
        for l in stride(from: max(level - 1, 0), through: 0, by: -1) {
            bestScore = evaluate(best, source: source, target: target, level: l, minimumOverlap: minimumOverlap,
                                 maximumScale: maximumScale) ?? -.infinity
            let steps: [(Float, Float)] = l == 0 ? [(0.5, 1.0 / 32), (0.25, 1.0 / 64)] : [(0.5, 1.0 / 16)]
            for (fraction, octave) in steps {
                let move = fraction * Float(1 << l) * best.scale
                for _ in 0..<8 {
                    var next = best, nextScore = bestScore
                    for trial in [SIMD3<Float>(move, 0, 0), SIMD3(-move, 0, 0), SIMD3(0, move, 0), SIMD3(0, -move, 0),
                                  SIMD3(0, 0, octave), SIMD3(0, 0, -octave)] {
                        var a = best
                        a.centre += SIMD2(trial.x, trial.y)
                        a.scale *= exp2(trial.z)
                        if let s = evaluate(a, source: source, target: target, level: l, minimumOverlap: minimumOverlap,
                                            maximumScale: maximumScale), s > nextScore {
                            next = a
                            nextScore = s
                        }
                    }
                    guard nextScore > bestScore else { break }
                    best = next
                    bestScore = nextScore
                }
            }
        }
        return bestScore.isFinite ? best : nil
    }

    /// `SequenceEvidence.match`'s search, its coarse level the deepest whose frames stay 12 cells long
    /// up to the third (the second for 64 cells, as built) and its scales up to 2^`octaves`: the refined
    /// alignments, best first, and which way each runs.
    static func search(_ earlier: Pyramid, _ later: Pyramid, _ v: Variant) -> [(alignment: SequenceEvidence.Alignment, earlierIsSource: Bool)] {
        var level = 0
        while level < 3, level + 1 < min(earlier.levels.count, later.levels.count),
              max(earlier.levels[level + 1].width, earlier.levels[level + 1].height) >= 12,
              max(later.levels[level + 1].width, later.levels[level + 1].height) >= 12 { level += 1 }
        let turns = earlier.isPortrait == later.isPortrait ? [0] : [0, 1, 3]
        var candidates: [SequenceEvidence.Candidate] = []
        SequenceEvidence.coarse(earlier, onto: later, level: level, turns: turns, ks: 0...(8 * v.octaves),
                                minimumOverlap: v.parameters.minimumOverlap, earlierIsSource: true, into: &candidates)
        SequenceEvidence.coarse(later, onto: earlier, level: level, turns: turns, ks: 1...(8 * v.octaves),
                                minimumOverlap: v.parameters.minimumOverlap, earlierIsSource: false, into: &candidates)
        candidates.sort { $0.score > $1.score || ($0.score == $1.score && ($0.k, $0.alignment.centre.x, $0.alignment.centre.y)
            < ($1.k, $1.alignment.centre.x, $1.alignment.centre.y)) }
        var kept: [SequenceEvidence.Candidate] = []
        for candidate in candidates where kept.count < v.tuning.candidates {
            let near = kept.contains { other in
                other.earlierIsSource == candidate.earlierIsSource && other.alignment.turns == candidate.alignment.turns
                    && abs(other.k - candidate.k) <= 1
                    && max(abs(other.alignment.centre.x - candidate.alignment.centre.x),
                           abs(other.alignment.centre.y - candidate.alignment.centre.y)) <= 1.5 * Float(1 << level) * candidate.alignment.scale
            }
            if !near { kept.append(candidate) }
        }
        return kept.compactMap { candidate in
            let (source, target) = candidate.earlierIsSource ? (earlier, later) : (later, earlier)
            return refine(candidate.alignment, source: source, target: target, from: level, minimumOverlap: v.parameters.minimumOverlap,
                          maximumScale: v.maximumScale).map { ($0, candidate.earlierIsSource) }
        }
    }

    // MARK: Mapped verification

    /// `SequenceEvidence.verify` for any mapping of the source's level-0 cells onto the target's, at local
    /// scale `scale` (one at least) and with the given overlap; the match's alignment holds only the scale.
    static func verify(map: (SIMD2<Float>) -> SIMD2<Float>, scale: Float, overlap: Float, source: Pyramid, target: Pyramid,
                       earlierIsSource: Bool, parameters: SequenceAims.Parameters, tuning: SequenceEvidence.Tuning) -> SequenceEvidence.Match? {
        guard overlap >= parameters.minimumOverlap else { return nil }
        let l = SequenceEvidence.level(for: scale, in: target, above: 0)
        let targetMap = target.levels[l], base = source.levels[0]
        var cells: [Int] = [], points: [SIMD2<Float>] = [], a: [Float] = [], b: [Float] = []
        var uRange = (Int.max, Int.min), vRange = (Int.max, Int.min)
        for cell in base.cells {
            let q = map(cell.point)
            guard let value = SequenceEvidence.sampledLog(targetMap, level: l, at: q) else { continue }
            cells.append(cell.index); points.append(q); a.append(cell.log); b.append(value)
            let u = cell.index % base.width, v = cell.index / base.width
            uRange = (min(uRange.0, u), max(uRange.1, u))
            vRange = (min(vRange.0, v), max(vRange.1, v))
        }
        guard cells.count >= tuning.blockCells * tuning.agreeingBlocks else { return nil }
        func logDetail(_ d: Float) -> Double { log2(Double(d.isFinite ? max(d, 0.005) : 0.005)) }
        var detail = (n: 0.0, x: 0.0, y: 0.0, xx: 0.0, yy: 0.0, xy: 0.0)
        for (k, cell) in cells.enumerated() {
            let u = min(max(Int(points[k].x), 0), target.width - 1), v = min(max(Int(points[k].y), 0), target.height - 1)
            SequenceEvidence.add(logDetail(source.detail[cell]), logDetail(target.detail[v * target.width + u]), to: &detail)
        }
        let detailCorrelation = SequenceEvidence.correlation(detail)
        guard detailCorrelation >= tuning.detailCorrelation else { return nil }
        let uSpan = uRange.1 - uRange.0 + 1, vSpan = vRange.1 - vRange.0 + 1
        let columns = max(1, Int((Float(uSpan) / Float(tuning.blockSide)).rounded()))
        let rows = max(1, Int((Float(vSpan) / Float(tuning.blockSide)).rounded()))
        var members = [[Int]](repeating: [], count: columns * rows)
        for (k, cell) in cells.enumerated() {
            let column = (cell % base.width - uRange.0) * columns / uSpan, row = (cell / base.width - vRange.0) * rows / vSpan
            members[row * columns + column].append(k)
        }
        struct Block { var structured: Bool; var shift: Float; var correlation: Float }
        let blocks: [Block?] = members.map { block in
            guard block.count >= tuning.blockCells else { return nil }
            var sums = (n: 0.0, x: 0.0, y: 0.0, xx: 0.0, yy: 0.0, xy: 0.0)
            for k in block { SequenceEvidence.add(Double(a[k]), Double(b[k]), to: &sums) }
            let detailed = block.filter { source.structured[cells[$0]] }.count
            let spread = Float(max(min(sums.xx - sums.x * sums.x / sums.n, sums.yy - sums.y * sums.y / sums.n), 0) / sums.n).squareRoot()
            return Block(structured: Float(detailed) >= tuning.structuredShare * Float(block.count) && spread >= tuning.blockSpread,
                         shift: SequenceEvidence.median(block.map { b[$0] - a[$0] }), correlation: SequenceEvidence.correlation(sums))
        }
        let structured = blocks.compactMap { $0 }.filter(\.structured)
        guard structured.count >= tuning.agreeingBlocks else { return nil }
        var region = SequenceEvidence.median(structured.map(\.shift))
        var agreeing = 0
        var matched: [(k: Int, weight: Float)] = []
        for pass in 0..<2 {
            agreeing = 0
            matched = []
            for (index, block) in blocks.enumerated() {
                guard let block, abs(block.shift - region) <= tuning.blockShift else { continue }
                let agrees = block.structured && block.correlation >= parameters.minimumCorrelation
                if agrees { agreeing += 1 } else if block.structured { continue }
                for k in members[index] where abs(b[k] - a[k] - region) <= tuning.cellShift {
                    matched.append((k, agrees ? 1 : 0.5))
                }
            }
            guard agreeing >= tuning.agreeingBlocks, Float(agreeing) >= tuning.agreeingShare * Float(structured.count) else { return nil }
            if pass == 0 { region = SequenceEvidence.weightedMedian(matched.map { b[$0.k] - a[$0.k] }, matched.map(\.weight)) }
        }
        var sums = (n: 0.0, x: 0.0, y: 0.0, xx: 0.0, yy: 0.0, xy: 0.0)
        var redBlue: [Float] = [], greenMagenta: [Float] = [], weights: [Float] = []
        for (k, weight) in matched {
            SequenceEvidence.add(Double(a[k]), Double(b[k]), to: &sums)
            let p = base.rgb[cells[k]], q = SequenceEvidence.sampledLight(targetMap, level: l, at: points[k])
            guard p.min() > 0, q.min() > 0 else { continue }
            let d = SIMD3(log2(q.x), log2(q.y), log2(q.z)) - SIMD3(log2(p.x), log2(p.y), log2(p.z))
            redBlue.append(d.x - d.z)
            greenMagenta.append(d.y - (d.x + d.z) / 2)
            weights.append(weight)
        }
        let sign: Float = earlierIsSource ? 1 : -1
        let colour = redBlue.isEmpty ? SIMD2<Float>(0, 0)
            : SIMD2(SequenceEvidence.weightedMedian(redBlue, weights), SequenceEvidence.weightedMedian(greenMagenta, weights)) * sign
        return SequenceEvidence.Match(alignment: SequenceEvidence.Alignment(turns: 0, scale: scale, centre: .zero), earlierIsSource: earlierIsSource,
                                      overlap: min(overlap, 1), shift: region * sign, correlation: SequenceEvidence.correlation(sums),
                                      structuredBlocks: structured.count, agreeingBlocks: agreeing, detailCorrelation: detailCorrelation,
                                      colour: colour, cells: matched.map { (cells[$0.k], points[$0.k], $0.weight) }, targetLevel: l)
    }

    // MARK: Vision

    /// Vision's own queue: one registration at a time, never on the cooperative threads. Called from
    /// them, Vision's work waits for a cooperative thread that the waiting tasks hold, and every
    /// thread stops (run-01 and run-03, 2026-10-22).
    static let visionQueue = DispatchQueue(label: "argent.sequence-reach.vision")
    /// Vision's own time and calls, on `visionQueue` only: the settings' times a pair include waiting for it.
    nonisolated(unsafe) static var visionTime = (milliseconds: 0.0, calls: 0)

    /// Vision's homography from `floating`'s pixels to `reference`'s, both with the origin at the
    /// bottom-left corner (checked on crops of a photograph, 2026-10-22).
    static func register(reference: Thumbnail, floating: Thumbnail) async -> simd_float3x3? {
        await withCheckedContinuation { continuation in
            visionQueue.async {
                let clock = ContinuousClock(), start = clock.now
                let h = registered(reference: reference, floating: floating)
                visionTime.milliseconds += M.ms(clock.now - start)
                visionTime.calls += 1
                continuation.resume(returning: h)
            }
        }
    }

    /// `register`'s work, on `visionQueue` only.
    private static func registered(reference: Thumbnail, floating: Thumbnail) -> simd_float3x3? {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: floating.image, options: [:])
        do { try VNImageRequestHandler(cgImage: reference.image, options: [:]).perform([request]) } catch { return nil }
        guard let warp = (request.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform else { return nil }
        let values = [warp.columns.0, warp.columns.1, warp.columns.2].flatMap { [$0.x, $0.y, $0.z] }
        return values.allSatisfy(\.isFinite) && abs(warp.determinant) > 1e-9 ? warp : nil
    }

    static func apply(_ h: simd_float3x3, _ p: SIMD2<Float>) -> SIMD2<Float> {
        let q = h * SIMD3(p.x, p.y, 1)
        return q.z > 1e-6 ? SIMD2(q.x / q.z, q.y / q.z) : SIMD2(.nan, .nan)
    }

    /// `later`'s thumbnail drawn in `earlier`'s pixels by `f`, earlier pixel to later pixel.
    static func warped(_ later: Thumbnail, onto earlier: Thumbnail, by f: (SIMD2<Float>) -> SIMD2<Float>) -> Thumbnail {
        var bytes = [UInt8](repeating: 128, count: earlier.width * earlier.height)
        for y in 0..<earlier.height {
            for x in 0..<earlier.width {
                bytes[y * earlier.width + x] = UInt8(min(max(later.sample(f(SIMD2(Float(x) + 0.5, Float(y) + 0.5))).rounded(), 0), 255))
            }
        }
        return Thumbnail(width: earlier.width, height: earlier.height, bytes: bytes)
    }

    /// A mapping between two frames in thumbnail pixels, each way, verified as the search's alignments are:
    /// the frame that shows more of the scene (its cells landing on more than one of the other's at the
    /// earlier frame's middle) walked cell by cell.
    static func verifyHomography(earlierToLater: @escaping (SIMD2<Float>) -> SIMD2<Float>, laterToEarlier: @escaping (SIMD2<Float>) -> SIMD2<Float>,
                                 earlier: Picture, later: Picture, pyramids: (Pyramid, Pyramid), v: Variant) -> SequenceEvidence.Match? {
        let ke = earlier.cellsPerPixel(v.longSide), kl = later.cellsPerPixel(v.longSide)
        let toLater: (SIMD2<Float>) -> SIMD2<Float> = { earlierToLater($0 / ke) * kl }
        let toEarlier: (SIMD2<Float>) -> SIMD2<Float> = { laterToEarlier($0 / kl) * ke }
        let (pe, pl) = pyramids
        // The local scale of the earlier-to-later map at the earlier frame's middle.
        let middle = SIMD2(Float(pe.width), Float(pe.height)) / 2
        let o = toLater(middle), dx = toLater(middle + SIMD2(1, 0)) - o, dy = toLater(middle + SIMD2(0, 1)) - o
        let det = dx.x * dy.y - dx.y * dy.x
        guard det.isFinite, det > 0 else { return nil }
        let s = det.squareRoot()
        guard s >= 1 / v.maximumScale, s <= v.maximumScale else { return nil }
        // The share of each frame that lands in the other; the overlap is the larger, the smaller frame's.
        func coverage(_ from: Pyramid, _ to: Pyramid, _ f: (SIMD2<Float>) -> SIMD2<Float>) -> Float {
            var inside = 0
            for row in 0..<from.height {
                for column in 0..<from.width {
                    let q = f(SIMD2(Float(column) + 0.5, Float(row) + 0.5))
                    if q.x >= 0, q.y >= 0, q.x <= Float(to.width), q.y <= Float(to.height) { inside += 1 }
                }
            }
            return Float(inside) / Float(max(from.width * from.height, 1))
        }
        let overlap = max(coverage(pe, pl, toLater), coverage(pl, pe, toEarlier))
        return s >= 1
            ? verify(map: toLater, scale: s, overlap: overlap, source: pe, target: pl, earlierIsSource: true,
                     parameters: v.parameters, tuning: v.tuning)
            : verify(map: toEarlier, scale: 1 / s, overlap: overlap, source: pl, target: pe, earlierIsSource: false,
                     parameters: v.parameters, tuning: v.tuning)
    }

    /// The earlier-to-later map of a search alignment, in thumbnail pixels, and its inverse.
    static func pixelMaps(_ alignment: SequenceEvidence.Alignment, earlierIsSource: Bool, earlier: Picture, later: Picture,
                          pyramids: (Pyramid, Pyramid), longSide: Int) -> (toLater: (SIMD2<Float>) -> SIMD2<Float>, toEarlier: (SIMD2<Float>) -> SIMD2<Float>) {
        let ke = earlier.cellsPerPixel(longSide), kl = later.cellsPerPixel(longSide)
        let (pe, pl) = pyramids
        if earlierIsSource {
            return ({ alignment.map($0 * ke, width: pe.width, height: pe.height) / kl },
                    { alignment.inverse($0 * kl, width: pe.width, height: pe.height) / ke })
        }
        return ({ alignment.inverse($0 * ke, width: pl.width, height: pl.height) / kl },
                { alignment.map($0 * kl, width: pl.width, height: pl.height) / ke })
    }

    // MARK: Matching

    /// What a setting found for a pair. `SequenceEvidence.Match` holds only values.
    struct Found: @unchecked Sendable {
        var match: SequenceEvidence.Match
        /// Which alignment won: the search's, Vision's alone, or Vision's refinement of the search's.
        var how: String
    }

    static func better(_ a: SequenceEvidence.Match, than b: SequenceEvidence.Match?) -> Bool {
        b.map { (a.agreeingBlocks, a.correlation) > ($0.agreeingBlocks, $0.correlation) } ?? true
    }

    /// The best verified match of two pictures under `v`; `homography`, Vision's later-to-earlier
    /// homography of the pair, for `.vision`.
    static func match(_ earlier: Picture, _ later: Picture, pyramids: (Pyramid, Pyramid), v: Variant,
                      homography: simd_float3x3?) -> Found? {
        let (pe, pl) = pyramids
        switch v.align {
        case .shipped:
            return SequenceEvidence.match(pe, pl, parameters: v.parameters, tuning: v.tuning).map { Found(match: $0, how: "search") }
        case .vision:
            guard let h = homography else { return nil }
            let inverse = h.inverse
            return verifyHomography(earlierToLater: { apply(inverse, $0) }, laterToEarlier: { apply(h, $0) }, earlier: earlier, later: later,
                                    pyramids: pyramids, v: v).map { Found(match: $0, how: "vision") }
        case .search, .refined:
            return searched(pyramids, v).best
        }
    }

    /// The search's alignments, best-scoring first, and the best of them that verifies.
    static func searched(_ pyramids: (Pyramid, Pyramid), _ v: Variant)
        -> (best: Found?, alignments: [(alignment: SequenceEvidence.Alignment, earlierIsSource: Bool)]) {
        let (pe, pl) = pyramids
        var best: Found?
        let alignments = search(pe, pl, v)
        for (alignment, earlierIsSource) in alignments {
            let (source, target) = earlierIsSource ? (pe, pl) : (pl, pe)
            if let m = SequenceEvidence.verify(alignment, source: source, target: target, earlierIsSource: earlierIsSource,
                                               parameters: v.parameters, tuning: v.tuning), better(m, than: best?.match) {
                best = Found(match: m, how: "search")
            }
        }
        return (best, alignments)
    }

    /// `match`, with Vision's part of `.vision` and `.refined` done here: for `.refined`, Vision refines
    /// the search's best-scoring alignment when none of the search's verified, one registration a pair
    /// at most since Vision takes one request at a time.
    static func matched(_ earlier: Picture, _ later: Picture, pyramids: (Pyramid, Pyramid), v: Variant,
                        homography: simd_float3x3?) async -> Found? {
        guard v.align == .refined else { return match(earlier, later, pyramids: pyramids, v: v, homography: homography) }
        let (best, alignments) = searched(pyramids, v)
        guard best == nil, let (alignment, earlierIsSource) = alignments.first else { return best }
        let maps = pixelMaps(alignment, earlierIsSource: earlierIsSource, earlier: earlier, later: later, pyramids: pyramids,
                             longSide: v.longSide)
        let start = warped(later.thumbnail, onto: earlier.thumbnail, by: maps.toLater)
        guard let h = await register(reference: earlier.thumbnail, floating: start) else { return nil }
        // h maps the warped later frame onto the earlier: earlier e ↦ later toLater(h⁻¹ e), later l ↦ earlier h(toEarlier l).
        let inverse = h.inverse
        return verifyHomography(earlierToLater: { maps.toLater(apply(inverse, $0)) }, laterToEarlier: { apply(h, maps.toEarlier($0)) },
                                earlier: earlier, later: later, pyramids: pyramids, v: v).map { Found(match: $0, how: "refined") }
    }

    /// `SequenceEvidence.link`'s tests after the match: no flash change, the light change within
    /// `lightTolerance`, the colour within the matcher's limits and a confidence above zero. `exposure`,
    /// when given, is the camera's exposure change in stops (later less earlier, more exposure positive)
    /// in place of the headers'.
    static func linked(_ earlier: Picture, _ later: Picture, found: Found, gap: Double, v: Variant, exposure: Float? = nil) -> Bool {
        if let a = earlier.info.flashFired, let b = later.info.flashFired, a != b { return false }
        let m = found.match
        var lightChange: Float?
        if let exposure {
            lightChange = m.shift - exposure
        } else if let a = earlier.info.sceneEV100, let b = later.info.sceneEV100 {
            lightChange = m.shift - Float(a - b)
        }
        if let lightChange, abs(lightChange) > v.parameters.lightTolerance { return false }
        guard abs(m.colour.x) <= v.tuning.redBlue, abs(m.colour.y) <= v.tuning.greenMagenta else { return false }
        let p = v.parameters
        let correlationMargin = SequenceEvidence.clamp((m.correlation - p.minimumCorrelation) / max(1 - p.minimumCorrelation, 1e-6))
        let overlapMargin = SequenceEvidence.clamp((m.overlap - p.minimumOverlap) / max(1 - p.minimumOverlap, 1e-6))
        let agreement = Float(m.agreeingBlocks) / Float(m.structuredBlocks)
        let time = Float(1 - gap / max(2 * p.maximumGap, 1e-9))
        let ramp = lightChange.map { SequenceEvidence.clamp(2 * (1 - abs($0) / p.lightTolerance)) } ?? 1
        let flags: Float = (earlier.info.flashFired == nil || later.info.flashFired == nil ? 0.5 : 1) * (lightChange == nil ? 0.5 : 1)
        return SequenceEvidence.clamp(agreement * (3 + correlationMargin) / 4 * (3 + overlapMargin) / 4 * time * ramp * flags) > 0
    }

    // MARK: The development split

    struct Session: Sendable {
        var name: String
        var keys: [String]
        var pictures: [Picture]
    }

    /// The pairs `links` compares in a session: each frame against the next `neighbours` within `maximumGap`.
    static func compared(_ session: Session, _ p: SequenceAims.Parameters) -> [(Int, Int, Double)] {
        var pairs: [(Int, Int, Double)] = []
        for i in session.pictures.indices {
            guard let start = session.pictures[i].info.captureDate else { continue }
            for j in (i + 1)..<min(session.pictures.count, i + 1 + max(p.neighbours, 0)) {
                guard let end = session.pictures[j].info.captureDate else { continue }
                let gap = abs(end.timeIntervalSince(start))
                if gap <= p.maximumGap { pairs.append((i, j, gap)) }
            }
        }
        return pairs
    }

    /// The development sessions as pictures: Cube++'s from the cache's grids, the a7 IV's from their sheet
    /// decodes, each checked to give the descriptor the evidence's harness measured.
    static func pictures(cube: E.Split, a7: E.Split) throws -> (sessions: [Session], a7Grids: [String: (ExposureAnalyzer.Grid, URL)]) {
        var byKey: [String: Picture] = [:]
        // Cube++: the grids `SeriesMeasureTests` reads, development frames only.
        let devKeys = Set(cube.sessions.flatMap(\.shots).map(\.key))
        let infos = Dictionary(uniqueKeysWithValues: cube.sessions.flatMap(\.shots).map { ($0.key, $0) })
        var mismatched = 0
        for shots in try S.loadShots() {
            for shot in shots where devKeys.contains(shot.id) {
                let grid = shot.frame.analysisGrid
                let picture = Picture(info: infos[shot.id]!.frame.info, grid: grid)
                if picture.descriptors[64]! != infos[shot.id]!.descriptor { mismatched += 1 }
                byKey[shot.id] = picture
            }
        }
        try #require(mismatched == 0, "\(mismatched) Cube++ descriptors differ from the evidence harness's")
        // a7 IV: the sheet decode, as `SequenceEvidenceMeasureTests.a7Split` measured it.
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(), contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        var a7Grids: [String: (ExposureAnalyzer.Grid, URL)] = [:]
        var drift = 0
        for shot in a7.sessions.flatMap(\.shots) {
            try autoreleasepool {
                var options = DecodeOptions()
                options.maxLongSide = FilmPreviews.previewLongSide
                let sheet = try decoder.decode(shot.frame.url, options: options)
                let noise = DecodedNoise.appleDecode(model: shot.frame.info.model, iso: shot.frame.info.iso, pins: sheet.pins)
                let grid = ExposureAnalyzer.grid(pixels: ExposureAnalyzer.pixels(of: sheet.texture), width: sheet.width, height: sheet.height, noise: noise)
                let picture = Picture(info: shot.frame.info, grid: grid)
                if picture.descriptors[64]! != shot.descriptor { drift += 1 }
                byKey[shot.key] = picture
                a7Grids[shot.key] = (grid, shot.frame.url)
            }
        }
        print("REACH a7 IV sheet decodes whose descriptor differs from the evidence harness's cache: \(drift) of \(a7Grids.count)")
        // Where the decode drifted since the cache, every setting reads today's decode, today's matcher included.
        let sessions = (cube.sessions + a7.sessions).map { s in
            Session(name: s.name, keys: s.shots.map(\.key), pictures: s.shots.map { byKey[$0.key]! })
        }
        return (sessions, a7Grids)
    }

    // MARK: Probes

    struct Probe: Sendable {
        var key: String
        var kind: String
        /// Zoom, and the dim probes' darkening in stops.
        var zoom: Float
        var dim: Float
        var exposure: Float
        var earlier: Picture
        var later: Picture
    }

    /// Numbers in 0..<1 for `label`, the same on every run.
    static func hashed(_ label: String) -> [Double] {
        SHA256.hash(data: Data(("20261022-reach|" + label).utf8)).map { Double($0) / 256 }
    }

    /// `pixels` (RGBA half floats, `width` by `height`) cropped to the `cw` by `ch` window at (`x0`, `y0`)
    /// and averaged down (or repeated up) to `ow` by `oh`.
    static func resampled(_ pixels: [Float16], width: Int, height: Int, x0: Double, y0: Double, cw: Double, ch: Double,
                          ow: Int, oh: Int) -> [Float16] {
        var out = [Float16](repeating: 0, count: ow * oh * 4)
        for j in 0..<oh {
            let ya = min(max(Int((y0 + Double(j) * ch / Double(oh)).rounded(.down)), 0), height - 1)
            let yb = min(max(Int((y0 + Double(j + 1) * ch / Double(oh)).rounded(.down)), ya + 1), height)
            for i in 0..<ow {
                let xa = min(max(Int((x0 + Double(i) * cw / Double(ow)).rounded(.down)), 0), width - 1)
                let xb = min(max(Int((x0 + Double(i + 1) * cw / Double(ow)).rounded(.down)), xa + 1), width)
                var sum = SIMD4<Float>(repeating: 0)
                for y in ya..<yb {
                    for x in xa..<xb {
                        let k = (y * width + x) * 4
                        sum += SIMD4(Float(pixels[k]), Float(pixels[k + 1]), Float(pixels[k + 2]), Float(pixels[k + 3]))
                    }
                }
                sum /= Float((yb - ya) * (xb - xa))
                let k = (j * ow + i) * 4
                (out[k], out[k + 1], out[k + 2], out[k + 3]) = (Float16(sum.x), Float16(sum.y), Float16(sum.z), Float16(sum.w))
            }
        }
        return out
    }

    static let zooms: [Float] = [1.25, 1.6, 2.0, 2.6, 3.2, 4.0]
    static let dims: [Float] = [3, 5, 7]

    /// The reach probes of every a7 IV development frame.
    static func probes(_ a7Grids: [String: (ExposureAnalyzer.Grid, URL)], infos: [String: ARWFrameInfo]) throws -> [Probe] {
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(), contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        var probes: [Probe] = []
        for key in a7Grids.keys.sorted() {
            let (sheetGrid, url) = a7Grids[key]!
            let info = infos[key]!
            try autoreleasepool {
                var options = DecodeOptions()
                options.maxLongSide = 3840
                let large = try decoder.decode(url, options: options)
                let noise = DecodedNoise.appleDecode(model: info.model, iso: info.iso, pins: large.pins)
                let pixels = ExposureAnalyzer.pixels(of: large.texture)
                let (w, h) = (Double(large.width), Double(large.height))
                let (ow, oh) = (sheetGrid.frameWidth, sheetGrid.frameHeight)
                func crop(_ zoom: Float, _ label: String) -> ExposureAnalyzer.Grid {
                    let r = hashed(key + "|" + label)
                    let cw = w / Double(zoom), ch = h / Double(zoom)
                    let x0 = (w - cw) / 2 + (2 * r[0] - 1) * (w - cw) / 2, y0 = (h - ch) / 2 + (2 * r[1] - 1) * (h - ch) / 2
                    return ExposureAnalyzer.grid(pixels: resampled(pixels, width: large.width, height: large.height, x0: x0, y0: y0, cw: cw, ch: ch,
                                                                   ow: ow, oh: oh), width: ow, height: oh, noise: noise)
                }
                func exposure(_ label: String) -> Float { Float(Int(hashed(key + "|" + label + "|s")[0] * 5)) * 0.5 - 1 }
                for zoom in zooms {
                    let label = "zoom \(zoom)", s = exposure(label)
                    probes.append(Probe(key: key, kind: "zoom", zoom: zoom, dim: 0, exposure: s, earlier: Picture(info: info, grid: sheetGrid),
                                        later: Picture(info: info, grid: shifted(crop(zoom, label), stops: s))))
                }
                for dim in dims {
                    let label = "dim \(dim)", s = exposure(label)
                    probes.append(Probe(key: key, kind: "dim", zoom: 1.25, dim: dim, exposure: s,
                                        earlier: Picture(info: info, grid: shifted(sheetGrid, stops: -dim)),
                                        later: Picture(info: info, grid: shifted(crop(1.25, label), stops: s - dim))))
                }
            }
        }
        return probes
    }

    // MARK: Runs

    struct Row: Sendable {
        var variant: Variant
        var links: [String: Found]
        var primary: (Int, Int)
        var primaryCube: (Int, Int)
        var primaryA7: (Int, Int)
        var overlap: (Int, Int)
        var changed: (Int, Int)
        var different: (Int, Int)
        var boundaries: (Int, Int)
        var chance: (Int, Int)?
        /// Probes linked, by kind and zoom or darkening.
        var probes: [String: (Int, Int)]
        var probeLinks: [String: Bool]
        var milliseconds: Double
        var compared: Int

        var feasible: Bool {
            Double(changed.0) <= E.falseLinkLimit * Double(changed.1) && Double(different.0) <= E.falseLinkLimit * Double(different.1)
        }
        var reach: Int { probes.filter { $0.key.hasPrefix("zoom") && (Float($0.key.dropFirst(5)) ?? 0) >= 2.6 }.map(\.value.0).reduce(0, +) }
    }

    static func probeLabel(_ probe: Probe) -> String { probe.kind == "zoom" ? "zoom \(probe.zoom)" : "dim \(probe.dim)" }

    static func run(_ v: Variant, sessions: [Session], splits: [E.Split], probes: [Probe],
                    homographies: [String: simd_float3x3]) async -> Row {
        let results = await withTaskGroup(of: ([(String, Found)], Double, Int).self) { group in
            for session in sessions {
                group.addTask {
                    let pyramids = session.pictures.map { Pyramid($0.descriptors[v.longSide]!, minimumDetail: v.parameters.minimumDetail) }
                    var found: [(String, Found)] = []
                    let clock = ContinuousClock()
                    var elapsed = Duration.zero
                    let pairs = compared(session, v.parameters)
                    for (i, j, gap) in pairs {
                        guard let pi = pyramids[i], let pj = pyramids[j] else { continue }
                        let key = session.keys[i] + "|" + session.keys[j]
                        let start = clock.now
                        let f = await matched(session.pictures[i], session.pictures[j], pyramids: (pi, pj), v: v, homography: homographies[key])
                        let ok = f.map { linked(session.pictures[i], session.pictures[j], found: $0, gap: gap, v: v) } ?? false
                        elapsed += clock.now - start
                        if ok, let f { found.append((key, f)) }
                    }
                    return (found, M.ms(elapsed), pairs.count)
                }
            }
            var all: [(String, Found)] = [], ms = 0.0, n = 0
            for await (found, t, c) in group { all += found; ms += t; n += c }
            return (all, ms, n)
        }
        let links = Dictionary(results.0, uniquingKeysWith: { a, _ in a })
        let probeLinks = await withTaskGroup(of: (String, Bool).self) { group in
            for probe in probes {
                group.addTask {
                    guard let pe = Pyramid(probe.earlier.descriptors[v.longSide]!, minimumDetail: v.parameters.minimumDetail),
                          let pl = Pyramid(probe.later.descriptors[v.longSide]!, minimumDetail: v.parameters.minimumDetail) else {
                        return (probe.key + "|" + probeLabel(probe), false)
                    }
                    let h = v.align == .vision ? await register(reference: probe.earlier.thumbnail, floating: probe.later.thumbnail) : nil
                    let f = await matched(probe.earlier, probe.later, pyramids: (pe, pl), v: v, homography: h)
                    return (probe.key + "|" + probeLabel(probe),
                            f.map { linked(probe.earlier, probe.later, found: $0, gap: 0, v: v, exposure: probe.exposure) } ?? false)
                }
            }
            var all: [String: Bool] = [:]
            for await (key, ok) in group { all[key] = ok }
            return all
        }
        var byLabel: [String: (Int, Int)] = [:]
        for probe in probes {
            let label = probeLabel(probe), ok = probeLinks[probe.key + "|" + label] ?? false
            byLabel[label, default: (0, 0)].0 += ok ? 1 : 0
            byLabel[label, default: (0, 0)].1 += 1
        }
        // Chance links between unrelated synthetic textures, for the search at the setting's picture.
        var chance: (Int, Int)?
        if v.align == .search || v.align == .shipped {
            let height = Int((Float(v.longSide) * 43 / 64).rounded())
            let scale = 64 / Float(v.longSide)
            var hits = 0
            for k in 0..<60 {
                let a = SequenceScenes.descriptor(width: v.longSide, height: height, view: { $0 * scale }, stops: SequenceScenes.texture(1000 + 2 * UInt64(k)))
                let b = SequenceScenes.descriptor(width: v.longSide, height: height, view: { $0 * scale }, stops: SequenceScenes.texture(1001 + 2 * UInt64(k)))
                guard let pa = Pyramid(a, minimumDetail: v.parameters.minimumDetail), let pb = Pyramid(b, minimumDetail: v.parameters.minimumDetail) else { continue }
                if v.align == .shipped {
                    if SequenceEvidence.match(pa, pb, parameters: v.parameters, tuning: v.tuning) != nil { hits += 1 }
                } else {
                    let found = search(pa, pb, v).contains { alignment, earlierIsSource in
                        let (s, t) = earlierIsSource ? (pa, pb) : (pb, pa)
                        return SequenceEvidence.verify(alignment, source: s, target: t, earlierIsSource: earlierIsSource,
                                                       parameters: v.parameters, tuning: v.tuning) != nil
                    }
                    if found { hits += 1 }
                }
            }
            chance = (hits, 60)
        }
        func count(_ pairs: [E.Pair]) -> (Int, Int) { (pairs.filter { links[$0.key] != nil }.count, pairs.count) }
        let primary = splits.flatMap(\.primary)
        return Row(variant: v, links: links, primary: count(primary), primaryCube: count(primary.filter { $0.source == "cubepp" }),
                   primaryA7: count(primary.filter { $0.source == "a7iv" }), overlap: count(splits.flatMap(\.overlap)),
                   changed: count(splits.flatMap(\.changed)), different: count(splits.flatMap(\.different)),
                   boundaries: count(splits.flatMap(\.boundaries)), chance: chance, probes: byLabel, probeLinks: probeLinks,
                   milliseconds: results.1 / Double(max(results.2, 1)), compared: results.2)
    }

    /// Vision's homography for every pair compared, later frame floating on the earlier.
    static func homographies(_ sessions: [Session], _ p: SequenceAims.Parameters) async -> ([String: simd_float3x3], Double) {
        await withTaskGroup(of: ([(String, simd_float3x3)], Double).self) { group in
            for session in sessions {
                group.addTask {
                    let clock = ContinuousClock()
                    var elapsed = Duration.zero
                    var found: [(String, simd_float3x3)] = []
                    for (i, j, _) in compared(session, p) {
                        let start = clock.now
                        let h = await register(reference: session.pictures[i].thumbnail, floating: session.pictures[j].thumbnail)
                        elapsed += clock.now - start
                        if let h { found.append((session.keys[i] + "|" + session.keys[j], h)) }
                    }
                    return (found, M.ms(elapsed))
                }
            }
            var all: [(String, simd_float3x3)] = [], ms = 0.0
            for await (found, t) in group { all += found; ms += t }
            return (Dictionary(all, uniquingKeysWith: { a, _ in a }), ms)
        }
    }

    // MARK: The checks against the matcher as built

    /// This file's search at 64 cells and one octave against `SequenceEvidence.links`, and its mapped
    /// verification against `SequenceEvidence.verify` on every alignment the search keeps: the number of
    /// pairs where they differ.
    static func reproduction(_ sessions: [Session]) async -> (links: Int, verify: Int, pairs: Int) {
        let v = Variant(name: "copy-64x1", option: "check")
        return await withTaskGroup(of: (Int, Int, Int).self) { group in
            for session in sessions {
                group.addTask {
                    let pyramids = session.pictures.map { Pyramid($0.descriptors[64]!, minimumDetail: v.parameters.minimumDetail) }
                    var linkDiffs = 0, verifyDiffs = 0, n = 0
                    for (i, j, _) in compared(session, v.parameters) {
                        guard let pe = pyramids[i], let pl = pyramids[j] else { continue }
                        n += 1
                        let built = SequenceEvidence.match(pe, pl, parameters: v.parameters, tuning: v.tuning)
                        let copy = match(session.pictures[i], session.pictures[j], pyramids: (pe, pl), v: v, homography: nil)
                        if built?.shift != copy?.match.shift || built?.agreeingBlocks != copy?.match.agreeingBlocks
                            || built?.correlation != copy?.match.correlation || built?.overlap != copy?.match.overlap { linkDiffs += 1 }
                        for (alignment, earlierIsSource) in search(pe, pl, v) {
                            let (s, t) = earlierIsSource ? (pe, pl) : (pl, pe)
                            let a = SequenceEvidence.verify(alignment, source: s, target: t, earlierIsSource: earlierIsSource,
                                                            parameters: v.parameters, tuning: v.tuning)
                            let b = verify(map: { alignment.map($0, width: s.width, height: s.height) }, scale: alignment.scale,
                                           overlap: alignment.overlap(source: (s.width, s.height), target: (t.width, t.height)),
                                           source: s, target: t, earlierIsSource: earlierIsSource, parameters: v.parameters, tuning: v.tuning)
                            if a?.shift != b?.shift || a?.agreeingBlocks != b?.agreeingBlocks || a?.correlation != b?.correlation
                                || a?.colour != b?.colour || a?.cells.count != b?.cells.count { verifyDiffs += 1 }
                        }
                    }
                    return (linkDiffs, verifyDiffs, n)
                }
            }
            var total = (0, 0, 0)
            for await (a, b, c) in group { total = (total.0 + a, total.1 + b, total.2 + c) }
            return (links: total.0, verify: total.1, pairs: total.2)
        }
    }

    // MARK: Reporting

    static func fraction(_ x: (Int, Int)) -> String { "\(x.0)/\(x.1)" }

    static let header = "setting,option,longSide,octaves,align,blockSide,agreeingBlocks,feasible,P,P cube,P a7,overlap,changed,different120,"
        + "boundaries,chance," + zooms.map { "zoom \($0)" }.joined(separator: ",") + "," + dims.map { "dim \($0)" }.joined(separator: ",")
        + ",ms a pair,pairs compared"

    static func line(_ row: Row) -> String {
        let v = row.variant
        var fields = [v.name, v.option, "\(v.longSide)", "\(v.octaves)", v.align.rawValue, "\(v.tuning.blockSide)", "\(v.tuning.agreeingBlocks)",
                      row.feasible ? "yes" : "no", fraction(row.primary), fraction(row.primaryCube), fraction(row.primaryA7), fraction(row.overlap),
                      fraction(row.changed), fraction(row.different), fraction(row.boundaries), row.chance.map(fraction) ?? ""]
        fields += zooms.map { row.probes["zoom \($0)"].map(fraction) ?? "" } + dims.map { row.probes["dim \($0)"].map(fraction) ?? "" }
        fields += [String(format: "%.2f", row.milliseconds), "\(row.compared)"]
        return fields.joined(separator: ",")
    }

    /// Each option's setting by the matcher rule: the most dev P pairs linked with false links within 5 %
    /// of the changed-light and the different pairs; ties to the most zoom probes linked at 2.6× or more,
    /// then the fewest false links, then the order listed.
    static func chosen(_ rows: [Row], option: String) -> Row? {
        rows.filter { $0.variant.option == option && $0.feasible }.enumerated().max { a, b in
            let ka = (a.element.primary.0, a.element.reach, -(a.element.changed.0 + a.element.different.0), -a.offset)
            let kb = (b.element.primary.0, b.element.reach, -(b.element.changed.0 + b.element.different.0), -b.offset)
            return ka < kb
        }?.element
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_SEQUENCE_PROTOCOL"] != nil))
    func developmentReach() async throws {
        try await Self.measureReach(environment: Self.environment)
    }

    /// The run: refuses any split but dev before it reads anything, then measures every setting.
    static func measureReach(environment: [String: String]) async throws {
        try Self.requireDevelopment(environment)
        let (benchmark, protocolURL) = try E.loadProtocol()
        let owner = benchmark.a7iv.folders.values.map(\.path).filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        let out = try E.outputFolder(refusing: [L.corpus.resolvingSymlinksInPath()] + owner)
        let cube = try E.cubeSplit(benchmark, protocolURL: protocolURL)
        let a7 = try E.a7Split(benchmark, out: out)
        let splits = [cube, a7]
        try Self.requireDevelopment(sessions: splits.flatMap(\.sessions).map(\.name), units: benchmark.units)
        let (sessions, a7Grids) = try Self.pictures(cube: cube, a7: a7)
        print("REACH dev: \(sessions.count) sessions, \(sessions.reduce(0) { $0 + $1.pictures.count }) frames; P \(splits.flatMap(\.primary).count), "
              + "changed \(cube.changed.count), different within 120 s \(cube.different.count), boundaries \(a7.boundaries.count)")
        // The structured share of each picture, to see what a finer picture does to `minimumDetail`.
        for side in Self.longSides {
            let shares = sessions.flatMap(\.pictures).compactMap { Pyramid($0.descriptors[side]!, minimumDetail: 0.03) }
                .map { p in Double(p.structured.filter { $0 }.count) / Double(max(p.levels[0].cells.count, 1)) }.sorted()
            print(String(format: "REACH structured share of valid cells at %d: median %.3f, p10 %.3f, p90 %.3f", side,
                         shares[shares.count / 2], shares[shares.count / 10], shares[shares.count * 9 / 10]))
        }

        let check = await Self.reproduction(sessions)
        print("REACH copy against the matcher as built: \(check.links) pairs differ in their match, \(check.verify) alignments in their "
              + "verification, of \(check.pairs) pairs")
        try #require(check.links == 0 && check.verify == 0, "the copied search or verification differs from SequenceEvidence's")

        let infos = Dictionary(uniqueKeysWithValues: a7.sessions.flatMap(\.shots).map { ($0.key, $0.frame.info) })
        let probes = environment["ARGENT_REACH_PROBES"] == "none" ? [] : try Self.probes(a7Grids, infos: infos)
        print("REACH probes: \(probes.count) from \(a7Grids.count) a7 IV development frames")

        let variants = Self.variants()
        var homographies: [String: simd_float3x3] = [:], visionMs = 0.0
        if variants.contains(where: { $0.align == .vision }) {
            (homographies, visionMs) = await Self.homographies(sessions, SequenceAims.Parameters.frozenRender)
            print(String(format: "REACH Vision homographies: %d pairs, %.2f ms a pair", homographies.count,
                         visionMs / Double(max(homographies.count, 1))))
        }

        var rows: [Row] = []
        let log = out.appendingPathComponent("runs.csv")
        if !FileManager.default.fileExists(atPath: log.path) { try (Self.header + "\n").write(to: log, atomically: true, encoding: .utf8) }
        for v in variants {
            let row = await Self.run(v, sessions: sessions, splits: splits, probes: probes, homographies: homographies)
            print("REACH " + Self.line(row))
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((Self.line(row) + "\n").utf8))
            try handle.close()
            rows.append(row)
        }

        // Each P pair and each false link under every setting; each probe under every setting.
        let primary = splits.flatMap(\.primary)
        var pairs = ["kind,id,a,b,seconds," + rows.map(\.variant.name).joined(separator: ",")]
        func describe(_ kind: String, _ list: [E.Pair], onlyLinked: Bool) {
            for pair in list {
                let marks = rows.map { $0.links[pair.key].map { $0.how } ?? "" }
                guard !onlyLinked || marks.contains(where: { !$0.isEmpty }) else { continue }
                pairs.append([kind, pair.id, pair.a, pair.b, String(format: "%.1f", pair.seconds)].joined(separator: ",") + "," + marks.joined(separator: ","))
            }
        }
        describe("P", primary, onlyLinked: false)
        describe("changed", cube.changed, onlyLinked: true)
        describe("different", cube.different, onlyLinked: true)
        describe("boundary", a7.boundaries, onlyLinked: true)
        try (pairs.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("pairs.csv"), atomically: true, encoding: .utf8)
        var probeLines = ["key,kind,zoom,dim,exposure," + rows.map(\.variant.name).joined(separator: ",")]
        for probe in probes {
            let label = Self.probeLabel(probe)
            probeLines.append("\(probe.key),\(probe.kind),\(probe.zoom),\(probe.dim),\(probe.exposure),"
                              + rows.map { ($0.probeLinks[probe.key + "|" + label] ?? false) ? "1" : "0" }.joined(separator: ","))
        }
        try (probeLines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("probes.csv"), atomically: true, encoding: .utf8)

        var md = "# Sequence evidence's reach on the development split\n\n"
        md += "Protocol \(E.protocolDigest.prefix(8))…; \(sessions.count) development sessions; every setting at `Parameters.frozenRender`. "
        md += "Copy of the matcher: \(check.links) of \(check.pairs) pairs differ. Probes: \(probes.count) from \(a7Grids.count) a7 IV frames. "
        let vision = Self.visionQueue.sync { Self.visionTime }
        md += String(format: "Vision: %d registrations, %.2f ms each on its own queue; the Vision settings' times a pair include waiting for it. ",
                     vision.calls, vision.milliseconds / Double(max(vision.calls, 1)))
        md += "Times on AC, machine not reserved: indicative, not G7.\n\n"
        md += "| setting | feasible | P | P Cube++ | P a7 IV | overlap | changed | different ≤ 120 s | boundaries | chance | "
        md += Self.zooms.map { "zoom \($0)" }.joined(separator: " | ") + " | " + Self.dims.map { "dim \($0)" }.joined(separator: " | ") + " | ms a pair |\n"
        md += "|" + String(repeating: "---|", count: 12 + Self.zooms.count + Self.dims.count) + "\n"
        for row in rows {
            md += "| \(row.variant.name) | \(row.feasible ? "yes" : "no") | \(Self.fraction(row.primary)) | \(Self.fraction(row.primaryCube)) | "
            md += "\(Self.fraction(row.primaryA7)) | \(Self.fraction(row.overlap)) | \(Self.fraction(row.changed)) | \(Self.fraction(row.different)) | "
            md += "\(Self.fraction(row.boundaries)) | \(row.chance.map(Self.fraction) ?? "–") | "
            md += Self.zooms.map { row.probes["zoom \($0)"].map(Self.fraction) ?? "–" }.joined(separator: " | ") + " | "
            md += Self.dims.map { row.probes["dim \($0)"].map(Self.fraction) ?? "–" }.joined(separator: " | ")
            md += String(format: " | %.2f |\n", row.milliseconds)
        }
        md += "\nChosen by the matcher rule (most dev P, then zoom probes at 2.6× or more, then fewest false links):\n\n"
        for option in ["today", "wider zoom", "finer", "vision", "vision refines"] {
            guard let row = Self.chosen(rows, option: option) else { md += "- \(option): no feasible setting\n"; continue }
            md += "- \(option): \(row.variant.name), P \(Self.fraction(row.primary)), changed \(Self.fraction(row.changed)), "
            md += "different \(Self.fraction(row.different)), zoom probes at 2.6× or more \(row.reach)\n"
            // What it adds and drops against today, by pair.
            if option != "today", let today = rows.first(where: { $0.variant.option == "today" }) {
                let gained = primary.filter { row.links[$0.key] != nil && today.links[$0.key] == nil }.map(\.id)
                let lost = primary.filter { row.links[$0.key] == nil && today.links[$0.key] != nil }.map(\.id)
                md += "  - P gained: \(gained.isEmpty ? "none" : gained.joined(separator: ", ")); lost: \(lost.isEmpty ? "none" : lost.joined(separator: ", "))\n"
            }
        }
        try md.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(md)
    }
}

@Suite struct SequenceReachGuardTests {
    typealias R = SequenceReachMeasureTests

    @Test func onlyTheDevelopmentSplitIsRead() throws {
        try R.requireDevelopment([:])
        try R.requireDevelopment(["ARGENT_SEQUENCE_SPLIT": "dev"])
        for requested in ["test", "Test", "TEST", "", "all", "test ", "dev "] {
            #expect(throws: R.Refusal.self) { try R.requireDevelopment(["ARGENT_SEQUENCE_SPLIT": requested]) }
        }
    }

    @Test func theRunRefusesTheTestSplitBeforeReadingAnything() async {
        // The protocol does not exist: a refusal, not a missing file, shows that nothing was read first.
        await #expect(throws: R.Refusal.self) {
            try await R.measureReach(environment: ["ARGENT_SEQUENCE_SPLIT": "test", "ARGENT_SEQUENCE_PROTOCOL": "/nonexistent/protocol.json"])
        }
    }

    @Test func aSessionOutsideTheDevelopmentSplitStopsTheRun() throws {
        let units = ["S003": "dev", "S001": "test", "owner-misc-s01": "dev", "owner-misc-s02": "test"]
        try R.requireDevelopment(sessions: ["S003", "owner-misc-s01"], units: units)
        #expect(throws: R.Refusal.self) { try R.requireDevelopment(sessions: ["S003", "S001"], units: units) }
        #expect(throws: R.Refusal.self) { try R.requireDevelopment(sessions: ["owner-misc-s02"], units: units) }
        // A session the protocol does not name, such as one of an event's folders, is not development.
        #expect(throws: R.Refusal.self) { try R.requireDevelopment(sessions: ["pixls-samples-s01"], units: units) }
    }
}
