import ArgentCore
import Foundation

/// Which nearby frames of a roll show the same subject in the same light, and the regions that
/// show it (docs/research/auto/sequence-consistency.md, section 3, "Shared evidence").
///
/// Each frame is compared with the next `neighbours` frames in capture order taken within
/// `maximumGap` seconds of it, when both are measured and described; a frame without a capture
/// time has no links. A flash that fired in one frame and not the other is a boundary before
/// anything is matched.
///
/// **Alignment.** The two frames' `SequenceDescriptor`s are lined up by structure, not brightness:
/// each cell's log2 luminance (Rec. 2020), compared by correlation, which takes each side's mean
/// out and so any exposure shift. A cell counts when its light is finite, not masked (all zero, as
/// Cube++'s cube is, nor beside such a cell, which holds part of the mask), at least 90 % unclipped
/// and above the analysis floor (`ExposureAnalyzer.floorStops`). The search covers a similarity:
/// scales 2^(k/8) for k from -8 to 8, every translation that keeps `minimumOverlap` of the smaller
/// frame shared, and quarter turns when one frame is portrait and the other landscape. It runs on
/// cells four wide, each alignment scored by the correlation's Fisher z times the square root of
/// the cells compared, so a large shared region beats a lucky small one; the best
/// `Tuning.candidates` are refined on finer cells to a quarter of a cell and a 64th of an octave.
/// The frame that shows more of the scene is walked cell by cell, and the other is read bilinearly
/// on the pyramid level whose cells match its cells in size.
///
/// **Verification.** The texture inside the cells, which the search never reads, must line up as well:
/// the two frames' log `detail` over the shared cells must correlate by `Tuning.detailCorrelation`,
/// which two unrelated textures lined up by chance do not (none of 60 synthetic pairs,
/// `SequenceScenes.unrelated`, against 44 of them linked without it). Then the shared region is cut
/// into blocks about `Tuning.blockSide` cells wide. A block carries structure when at least
/// `Tuning.structuredShare` of its cells have `detail` of `minimumDetail` or more and its light varies
/// by `Tuning.blockSpread` in both frames; it agrees when its own correlation reaches
/// `minimumCorrelation` and its own shift (the median of its cells' differences) lies within
/// `Tuning.blockShift` of the region's, the median of the structured blocks'. A link needs
/// `Tuning.agreeingBlocks` agreeing blocks and `Tuning.agreeingShare` of the structured ones: a scene
/// photographed again by hand moves in depth, people walk through it and its edges are cropped, so
/// on the development split a quarter to a half of a true pair's blocks agree. Flat blocks (sky, walls
/// without detail) whose shift agrees give matched points but no vote, so they never make a link by
/// themselves.
///
/// **Shift and light.** `shift` is the weighted median, over the matched cells, of the later
/// frame's log2 luminance less the earlier's: cells of agreeing blocks weigh 1 and those of
/// agreeing flat blocks ½, and a cell more than `Tuning.cellShift` from its region's shift (a
/// moved subject) is left out. Less the camera's exposure change, EV100 earlier less EV100 later
/// (`ARWFrameInfo.sceneEV100`; more exposure gives brighter decode values), it is how much brighter
/// the scene became, `lightChange`; beyond `lightTolerance` either way the frames are not in the
/// same light. The light's colour, the median change of the matched cells' red against blue and
/// green against magenta in the decode (which keeps one fixed neutral), may move by at most
/// `Tuning.redBlue` and `Tuning.greenMagenta` stops.
///
/// **Matched points.** Up to `maximumSamples` matched cells, spread evenly over the shared region in
/// the walked frame's order, each with its light in both frames (the other frame's read
/// bilinearly) and weight 1. A face of the earlier frame whose box lands on a face of the later
/// frame (intersection over union at least `Tuning.faceOverlap`) and whose level changed by the
/// region's shift within `Tuning.faceShift` adds its inset's cells (`FaceMeter`'s inset) with
/// weight 2 times its reliability, the smaller of the two faces' detection confidences or 1 when
/// unknown, up to half the points. A face that maps onto no face of the other frame is a different
/// person, or one who came or went: its cells give no point.
///
/// **Confidence**, from 0 to 1: a · (3 + m) / 4 · (3 + o) / 4 · g · λ · f, where a is the share of
/// structured blocks that agree; m is the correlation margin, (ρ − `minimumCorrelation`) / (1 −
/// `minimumCorrelation`) for the matched cells' correlation ρ, clamped to 0…1; o the overlap
/// margin, (overlap − `minimumOverlap`) / (1 − `minimumOverlap`), clamped; g = 1 − gap / (2 ·
/// `maximumGap`) for the time between the captures; λ ramps the light change down, 1 while
/// |`lightChange`| is at most half `lightTolerance` and falling linearly to 0 at it; and f halves when
/// either frame's flash is unknown and again when either frame's exposure is (then `lightChange` is
/// `nil` and λ is 1). A link of no confidence is not kept.
public enum SequenceEvidence {
    /// Every link between `input`'s frames, earlier frame first, in capture order of the earlier
    /// frame and then of the later.
    public static func links(_ input: SequenceAims.Input, parameters: SequenceAims.Parameters) -> [SequenceAims.Link] {
        links(input, parameters: parameters, tuning: .standard)
    }

    /// The matcher's own constants, chosen with the evidence's parameters by the matcher rule of
    /// docs/research/auto/sequence-consistency.md section 3 on the benchmark's development split
    /// (`SequenceEvidenceMeasureTests`, 2026-10-22): the most dev P pairs linked, 56 of 63, with 6 of 767
    /// changed-light pairs and 22 of 762 pairs of different subjects within 120 s linked, against a
    /// ceiling of 5 % each. Recall holds at 56 over minimum correlations of 0.3 to 0.5, two or three
    /// agreeing blocks and detail correlations of 0.1 to 0.2; these values link the fewest of the
    /// negatives there.
    struct Tuning: Sendable, Equatable {
        /// The alignments kept from the coarse search and refined.
        var candidates = 4
        /// A verification block's side, in cells of the frame walked.
        var blockSide = 10
        /// The fewest matched cells for a block to count, the share of them that must carry detail
        /// and the spread of log2 luminance, in stops, its light must have in each frame.
        var blockCells = 16
        var structuredShare: Float = 0.5
        var blockSpread: Float = 0.1
        /// How far, in stops, a block's shift may lie from the region's, and a cell's from its region's.
        var blockShift: Float = 0.25
        var cellShift: Float = 0.5
        /// The fewest agreeing blocks for a link, and their least share of the structured blocks.
        var agreeingBlocks = 3
        var agreeingShare: Float = 0.25
        /// The least correlation of the two frames' log detail over the shared cells.
        var detailCorrelation: Float = 0.2
        /// The most the light's colour may change, red against blue and green against magenta, stops:
        /// SeriesMeasureTests' changed light begins past 20 mired (0.19 stop) and 0.2 green.
        var redBlue: Float = 0.2
        var greenMagenta: Float = 0.15
        /// Two faces are one when their boxes overlap this much once aligned, and their levels moved
        /// with the region within this many stops.
        var faceOverlap: Float = 0.3
        var faceShift: Float = 0.5

        static let standard = Tuning()
    }

    /// `links` with the matcher's own constants given, for tuning them.
    static func links(_ input: SequenceAims.Input, parameters: SequenceAims.Parameters, tuning: Tuning) -> [SequenceAims.Link] {
        let frames = input.frames
        let reach = min(max(parameters.neighbours, 0), frames.count)
        guard reach > 0 else { return [] }
        let pyramids: [Pyramid?] = frames.map { frame in
            guard input.analyses[frame.url] != nil, let descriptor = input.descriptors[frame.url] else { return nil }
            return Pyramid(descriptor, minimumDetail: parameters.minimumDetail)
        }
        var links: [SequenceAims.Link] = []
        for i in frames.indices {
            guard let earlier = pyramids[i], let start = frames[i].info.captureDate else { continue }
            for j in (i + 1)..<min(frames.count, i + 1 + reach) {
                guard let later = pyramids[j], let end = frames[j].info.captureDate else { continue }
                let gap = abs(end.timeIntervalSince(start))
                guard gap <= parameters.maximumGap,
                      let link = link(earlier: (i, frames[i].info, input.analyses[frames[i].url]!, earlier),
                                      later: (j, frames[j].info, input.analyses[frames[j].url]!, later),
                                      gap: gap, parameters: parameters, tuning: tuning)
                else { continue }
                links.append(link)
            }
        }
        return links
    }

    /// One frame as a pair sees it: its index, header, analysis and pyramid.
    typealias Side = (index: Int, info: ARWFrameInfo, analysis: ExposureAnalysis, pyramid: Pyramid)

    /// The link between two frames `gap` seconds apart, if they show one subject in one light.
    static func link(earlier: Side, later: Side, gap: Double, parameters: SequenceAims.Parameters,
                     tuning: Tuning) -> SequenceAims.Link? {
        if let a = earlier.info.flashFired, let b = later.info.flashFired, a != b { return nil }
        guard let match = match(earlier.pyramid, later.pyramid, parameters: parameters, tuning: tuning) else { return nil }
        var lightChange: Float?
        if let a = earlier.info.sceneEV100, let b = later.info.sceneEV100 {
            let light = match.shift - Float(a - b)
            guard abs(light) <= parameters.lightTolerance else { return nil }
            lightChange = light
        }
        guard abs(match.colour.x) <= tuning.redBlue, abs(match.colour.y) <= tuning.greenMagenta else { return nil }

        let correlationMargin = clamp((match.correlation - parameters.minimumCorrelation) / max(1 - parameters.minimumCorrelation, 1e-6))
        let overlapMargin = clamp((match.overlap - parameters.minimumOverlap) / max(1 - parameters.minimumOverlap, 1e-6))
        let agreement = Float(match.agreeingBlocks) / Float(match.structuredBlocks)
        let time = Float(1 - gap / max(2 * parameters.maximumGap, 1e-9))
        let ramp = lightChange.map { clamp(2 * (1 - abs($0) / parameters.lightTolerance)) } ?? 1
        let flags: Float = (earlier.info.flashFired == nil || later.info.flashFired == nil ? 0.5 : 1)
            * (lightChange == nil ? 0.5 : 1)
        let confidence = clamp(agreement * (3 + correlationMargin) / 4 * (3 + overlapMargin) / 4 * time * ramp * flags)
        guard confidence > 0 else { return nil }

        let points = samples(match, earlier: earlier, later: later, limit: parameters.maximumSamples, tuning: tuning)
        return SequenceAims.Link(earlier: earlier.index, later: later.index, shift: match.shift, lightChange: lightChange,
                                 confidence: confidence, overlap: match.overlap, correlation: match.correlation,
                                 earlierSamples: points.earlier, laterSamples: points.later, weights: points.weights)
    }

    static func clamp(_ x: Float) -> Float { x.isNaN ? 0 : min(max(x, 0), 1) }

    // MARK: Frames

    /// A frame's light as the matcher reads it: its descriptor's cells and the descriptor halved up
    /// to three times, rows from the bottom.
    struct Pyramid: Sendable {
        struct Level: Sendable {
            var width: Int
            var height: Int
            /// Log2 luminance, NaN where the cell is not valid.
            var log: [Float]
            /// Mean light, linear working-space RGB.
            var rgb: [SIMD3<Float>]
            /// The valid cells: their middles in level-0 cells from the frame's bottom-left corner,
            /// their log2 luminance and their index on this level.
            var cells: [(point: SIMD2<Float>, log: Float, index: Int)]
        }

        var levels: [Level]
        /// Level 0's cells whose detail is at least the minimum, where valid, and every cell's detail.
        var structured: [Bool]
        var detail: [Float]

        var width: Int { levels[0].width }
        var height: Int { levels[0].height }

        /// `nil` for a descriptor whose arrays do not match its size, or with no cells.
        init?(_ descriptor: SequenceDescriptor, minimumDetail: Float) {
            let width = descriptor.width, height = descriptor.height, count = width * height
            guard width > 0, height > 0, descriptor.rgb.count == 3 * count, descriptor.unclipped.count == count,
                  descriptor.detail.count == count else { return nil }
            let floor = 0.18 * exp2(ExposureAnalyzer.floorStops)
            let rgb = (0..<count).map { SIMD3(descriptor.rgb[3 * $0], descriptor.rgb[3 * $0 + 1], descriptor.rgb[3 * $0 + 2]) }
            let masked = rgb.map { $0 == .zero }
            var log = [Float](repeating: .nan, count: count), structured = [Bool](repeating: false, count: count)
            for v in 0..<height {
                for u in 0..<width {
                    let cell = v * width + u, light = rgb[cell], luma = (light * Rec2020.luma).sum()
                    // A cell beside a masked one holds part of the mask.
                    let besideMask = (u > 0 && masked[cell - 1]) || (u + 1 < width && masked[cell + 1])
                        || (v > 0 && masked[cell - width]) || (v + 1 < height && masked[cell + width])
                    guard light.x.isFinite, light.y.isFinite, light.z.isFinite, !masked[cell], !besideMask,
                          descriptor.unclipped[cell] >= 0.9, luma > floor, luma.isFinite else { continue }
                    log[cell] = log2(luma)
                    structured[cell] = descriptor.detail[cell] >= minimumDetail
                }
            }
            self.structured = structured
            detail = descriptor.detail
            levels = [Self.level(width: width, height: height, log: log, rgb: rgb, scale: 1)]
            // Each coarser level's cell holds the four below it, valid when three are.
            while levels.count < 4, levels[levels.count - 1].width >= 4, levels[levels.count - 1].height >= 4 {
                let fine = levels[levels.count - 1]
                let w = fine.width / 2, h = fine.height / 2
                var coarseLog = [Float](repeating: .nan, count: w * h), coarseRGB = [SIMD3<Float>](repeating: .zero, count: w * h)
                for v in 0..<h {
                    for u in 0..<w {
                        var n: Float = 0, sum: Float = 0, light = SIMD3<Float>(repeating: 0)
                        for (du, dv) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                            let child = (2 * v + dv) * fine.width + 2 * u + du
                            guard !fine.log[child].isNaN else { continue }
                            n += 1
                            sum += fine.log[child]
                            light += fine.rgb[child]
                        }
                        guard n >= 3 else { continue }
                        coarseLog[v * w + u] = sum / n
                        coarseRGB[v * w + u] = light / n
                    }
                }
                levels.append(Self.level(width: w, height: h, log: coarseLog, rgb: coarseRGB, scale: Float(1 << levels.count)))
            }
        }

        /// A level of `width` by `height` cells, each `scale` level-0 cells wide.
        static func level(width: Int, height: Int, log: [Float], rgb: [SIMD3<Float>], scale: Float) -> Level {
            var cells: [(point: SIMD2<Float>, log: Float, index: Int)] = []
            for index in log.indices where !log[index].isNaN {
                cells.append((SIMD2(Float(index % width) + 0.5, Float(index / width) + 0.5) * scale, log[index], index))
            }
            return Level(width: width, height: height, log: log, rgb: rgb, cells: cells)
        }

        var isPortrait: Bool { height > width }
    }

    // MARK: Alignment

    /// Where a point of one frame, the source, lands in another, the target: the point, in level-0
    /// cells from the source's bottom-left corner, is turned `turns` quarter turns anticlockwise,
    /// and the turned frame's middle lands on `centre` of the target, scaled by `scale` about it.
    struct Alignment: Sendable, Equatable {
        var turns: Int
        var scale: Float
        var centre: SIMD2<Float>

        /// The source's size once turned.
        func turnedSize(_ width: Int, _ height: Int) -> SIMD2<Float> {
            turns % 2 == 0 ? SIMD2(Float(width), Float(height)) : SIMD2(Float(height), Float(width))
        }

        static func turned(_ p: SIMD2<Float>, turns: Int, size: SIMD2<Float>) -> SIMD2<Float> {
            switch turns & 3 {
            case 1: SIMD2(size.y - p.y, p.x)
            case 2: SIMD2(size.x - p.x, size.y - p.y)
            case 3: SIMD2(p.y, size.x - p.x)
            default: p
            }
        }

        func map(_ p: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
            let size = turnedSize(width, height)
            return centre + scale * (Self.turned(p, turns: turns, size: SIMD2(Float(width), Float(height))) - size / 2)
        }

        /// The point of the source that lands on `q`.
        func inverse(_ q: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
            let size = turnedSize(width, height)
            return Self.turned((q - centre) / scale + size / 2, turns: (4 - turns & 3) & 3, size: size)
        }

        /// The share of the smaller frame, in the scene, that the other covers.
        func overlap(source: (Int, Int), target: (Int, Int)) -> Float {
            let size = turnedSize(source.0, source.1) * scale
            let low = centre - size / 2, high = centre + size / 2
            let w = min(high.x, Float(target.0)) - max(low.x, 0), h = min(high.y, Float(target.1)) - max(low.y, 0)
            guard w > 0, h > 0 else { return 0 }
            return w * h / min(Float(target.0 * target.1), size.x * size.y)
        }
    }

    /// An alignment found by the search, with its score and which way it runs.
    struct Candidate {
        var alignment: Alignment
        var score: Double
        /// Whether the earlier frame is the source.
        var earlierIsSource: Bool
        var k: Int
    }

    /// The pyramid level of the target whose cells match a source cell scaled by `scale`.
    static func level(for scale: Float, in pyramid: Pyramid, above base: Int) -> Int {
        min(base + max(0, Int(log2(scale).rounded())), pyramid.levels.count - 1)
    }

    /// The correlation's Fisher z times the square root of the cells compared, the score alignments
    /// are ranked by; `nil` under `minimum` cells or on a flat side.
    static func score(n: Double, sa: Double, sb: Double, saa: Double, sbb: Double, sab: Double, minimum: Int) -> (z: Double, r: Double)? {
        guard n >= Double(max(minimum, 4)) else { return nil }
        let va = saa - sa * sa / n, vb = sbb - sb * sb / n
        guard va > 1e-4 * n, vb > 1e-4 * n else { return nil }
        let r = (sab - sa * sb / n) / (va * vb).squareRoot()
        return (atanh(min(r, 1 - 1e-6)) * (n - 3).squareRoot(), r)
    }

    /// The level-`level` light of `l`, read bilinearly at `q` (level-0 cells), when every cell read
    /// is valid: the four cell indices and weights.
    @inline(__always)
    static func taps(_ l: Pyramid.Level, level: Int, at q: SIMD2<Float>) -> (SIMD4<Int32>, SIMD4<Float>)? {
        let unit = Float(1 << level)
        let fx = q.x / unit - 0.5, fy = q.y / unit - 0.5
        guard fx >= -0.5, fy >= -0.5, fx <= Float(l.width) - 0.5, fy <= Float(l.height) - 0.5 else { return nil }
        let cx = min(max(fx, 0), Float(l.width - 1)), cy = min(max(fy, 0), Float(l.height - 1))
        let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, l.width - 1), y1 = min(y0 + 1, l.height - 1)
        let wx = cx - Float(x0), wy = cy - Float(y0)
        let indices = SIMD4<Int32>(Int32(y0 * l.width + x0), Int32(y0 * l.width + x1), Int32(y1 * l.width + x0), Int32(y1 * l.width + x1))
        let weights = SIMD4<Float>((1 - wx) * (1 - wy), wx * (1 - wy), (1 - wx) * wy, wx * wy)
        return (indices, weights)
    }

    /// `taps`' log2 luminance, `nil` when a cell it reads is not valid.
    @inline(__always)
    static func sampledLog(_ l: Pyramid.Level, level: Int, at q: SIMD2<Float>) -> Float? {
        guard let (i, w) = taps(l, level: level, at: q) else { return nil }
        var value: Float = 0
        for k in 0..<4 where w[k] > 0 {
            let v = l.log[Int(i[k])]
            if v.isNaN { return nil }
            value += w[k] * v
        }
        return value
    }

    static func sampledLight(_ l: Pyramid.Level, level: Int, at q: SIMD2<Float>) -> SIMD3<Float> {
        guard let (i, w) = taps(l, level: level, at: q) else { return .zero }
        var value = SIMD3<Float>(repeating: 0)
        for k in 0..<4 where w[k] > 0 { value += w[k] * l.rgb[Int(i[k])] }
        return value
    }

    /// Every alignment of `source` onto `target` on the coarse `level`, with scales 2^(k/8) for `ks`,
    /// translations a target cell apart and the source's cells read at the nearest target cell.
    static func coarse(_ source: Pyramid, onto target: Pyramid, level: Int, turns: [Int], ks: ClosedRange<Int>,
                       minimumOverlap: Float, earlierIsSource: Bool, into candidates: inout [Candidate]) {
        let cells = source.levels[level].cells
        guard cells.count >= 12 else { return }
        let sourceSize = SIMD2(Float(source.width), Float(source.height))
        var bx = [Int](repeating: 0, count: cells.count), by = bx
        for turn in turns {
            for k in ks {
                let scale = exp2(Float(k) / 8)
                let l = Self.level(for: scale, in: target, above: level)
                let map = target.levels[l], unit = Float(1 << l)
                let turned = turn % 2 == 0 ? sourceSize : SIMD2(sourceSize.y, sourceSize.x)
                // The source cell's target cell with its turned frame's corner on the target's.
                for (n, cell) in cells.enumerated() {
                    let q = scale * Alignment.turned(cell.point, turns: turn, size: sourceSize) / unit
                    bx[n] = Int(q.x.rounded(.down))
                    by[n] = Int(q.y.rounded(.down))
                }
                let lowX = Int((-scale * turned.x / unit).rounded(.down)), highX = Int((Float(target.width) / unit).rounded(.up))
                let lowY = Int((-scale * turned.y / unit).rounded(.down)), highY = Int((Float(target.height) / unit).rounded(.up))
                map.log.withUnsafeBufferPointer { log in
                    for ty in lowY...highY {
                        for tx in lowX...highX {
                            let corner = SIMD2(Float(tx), Float(ty)) * unit
                            let alignment = Alignment(turns: turn, scale: scale, centre: corner + scale * turned / 2)
                            guard alignment.overlap(source: (source.width, source.height), target: (target.width, target.height))
                                    >= minimumOverlap else { continue }
                            var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                            for c in 0..<cells.count {
                                let x = bx[c] + tx, y = by[c] + ty
                                guard x >= 0, y >= 0, x < map.width, y < map.height else { continue }
                                let b = log[y * map.width + x]
                                guard !b.isNaN else { continue }
                                let a = Double(cells[c].log), bb = Double(b)
                                n += 1; sa += a; sb += bb; saa += a * a; sbb += bb * bb; sab += a * bb
                            }
                            guard let s = score(n: n, sa: sa, sb: sb, saa: saa, sbb: sbb, sab: sab, minimum: 12), s.r > 0 else { continue }
                            candidates.append(Candidate(alignment: alignment, score: s.z, earlierIsSource: earlierIsSource, k: k))
                        }
                    }
                }
            }
        }
    }

    /// The score of `alignment` on `level`: the source's cells there against the target read
    /// bilinearly at the matching level; `nil` when too little is shared.
    static func evaluate(_ alignment: Alignment, source: Pyramid, target: Pyramid, level: Int, minimumOverlap: Float) -> Double? {
        guard alignment.scale >= 0.99, alignment.scale <= 2.1,
              alignment.overlap(source: (source.width, source.height), target: (target.width, target.height)) >= minimumOverlap
        else { return nil }
        let l = Self.level(for: alignment.scale, in: target, above: level)
        let map = target.levels[l]
        var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        for cell in source.levels[level].cells {
            guard let b = sampledLog(map, level: l, at: alignment.map(cell.point, width: source.width, height: source.height)) else { continue }
            let a = Double(cell.log), bb = Double(b)
            n += 1; sa += a; sb += bb; saa += a * a; sbb += bb * bb; sab += a * bb
        }
        return score(n: n, sa: sa, sb: sb, saa: saa, sbb: sbb, sab: sab, minimum: 24)?.z
    }

    /// `alignment` refined from the coarse `level` down to level 0 by moving its centre half a cell
    /// and its scale a 16th of an octave while the score rises; on level 0 half a cell and a 32nd,
    /// then a quarter of a cell and a 64th.
    static func refine(_ alignment: Alignment, source: Pyramid, target: Pyramid, from level: Int,
                       minimumOverlap: Float) -> (Alignment, Double)? {
        var best = alignment, bestScore = -Double.infinity
        for l in stride(from: max(level - 1, 0), through: 0, by: -1) {
            bestScore = evaluate(best, source: source, target: target, level: l, minimumOverlap: minimumOverlap) ?? -.infinity
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
                        if let s = evaluate(a, source: source, target: target, level: l, minimumOverlap: minimumOverlap), s > nextScore {
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
        return bestScore.isFinite ? (best, bestScore) : nil
    }

    // MARK: Matching

    /// Two frames aligned and verified.
    struct Match {
        var alignment: Alignment
        var earlierIsSource: Bool
        var overlap: Float
        /// The later frame's log2 luminance less the earlier's over the matched cells.
        var shift: Float
        var correlation: Float
        var structuredBlocks: Int
        var agreeingBlocks: Int
        /// The correlation of the two frames' log detail over the shared cells.
        var detailCorrelation: Float
        /// The change of the light's colour, later less earlier: red against blue, green against magenta.
        var colour: SIMD2<Float>
        /// The source's matched cells (level 0), where each lands in the target, and its weight.
        var cells: [(cell: Int, at: SIMD2<Float>, weight: Float)]
        /// The target's pyramid level read for each cell.
        var targetLevel: Int
    }

    /// The earlier and later frames aligned and verified, or `nil` when they do not show one subject.
    static func match(_ earlier: Pyramid, _ later: Pyramid, parameters: SequenceAims.Parameters, tuning: Tuning) -> Match? {
        // The coarse level: cells four wide while the frames stay twelve cells long.
        var level = 0
        while level < 2, level + 1 < min(earlier.levels.count, later.levels.count),
              max(earlier.levels[level + 1].width, earlier.levels[level + 1].height) >= 12,
              max(later.levels[level + 1].width, later.levels[level + 1].height) >= 12 { level += 1 }
        let turns = earlier.isPortrait == later.isPortrait ? [0] : [0, 1, 3]
        var candidates: [Candidate] = []
        // The frame that shows more of the scene is the source, so each scale is searched once.
        coarse(earlier, onto: later, level: level, turns: turns, ks: 0...8, minimumOverlap: parameters.minimumOverlap,
               earlierIsSource: true, into: &candidates)
        coarse(later, onto: earlier, level: level, turns: turns, ks: 1...8, minimumOverlap: parameters.minimumOverlap,
               earlierIsSource: false, into: &candidates)
        candidates.sort { $0.score > $1.score || ($0.score == $1.score && ($0.k, $0.alignment.centre.x, $0.alignment.centre.y)
            < ($1.k, $1.alignment.centre.x, $1.alignment.centre.y)) }
        // The best alignments some distance apart.
        var kept: [Candidate] = []
        for candidate in candidates where kept.count < tuning.candidates {
            let near = kept.contains { other in
                other.earlierIsSource == candidate.earlierIsSource && other.alignment.turns == candidate.alignment.turns
                    && abs(other.k - candidate.k) <= 1
                    && max(abs(other.alignment.centre.x - candidate.alignment.centre.x),
                           abs(other.alignment.centre.y - candidate.alignment.centre.y)) <= 1.5 * Float(1 << level) * candidate.alignment.scale
            }
            if !near { kept.append(candidate) }
        }
        var best: Match?
        for candidate in kept {
            let (source, target) = candidate.earlierIsSource ? (earlier, later) : (later, earlier)
            guard let (alignment, _) = refine(candidate.alignment, source: source, target: target, from: level,
                                              minimumOverlap: parameters.minimumOverlap),
                  let match = verify(alignment, source: source, target: target, earlierIsSource: candidate.earlierIsSource,
                                     parameters: parameters, tuning: tuning) else { continue }
            if best.map({ (match.agreeingBlocks, match.correlation) > ($0.agreeingBlocks, $0.correlation) }) ?? true { best = match }
        }
        return best
    }

    static func median(_ values: [Float]) -> Float {
        let s = values.sorted()
        return s.isEmpty ? .nan : s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The value at which `weights` reach half their sum, in the order of `values`; NaN when empty.
    static func weightedMedian(_ values: [Float], _ weights: [Float]) -> Float {
        let order = values.indices.sorted { values[$0] < values[$1] || (values[$0] == values[$1] && $0 < $1) }
        let total = weights.reduce(0, +)
        var sum: Float = 0
        for index in order {
            sum += weights[index]
            if sum >= total / 2 { return values[index] }
        }
        return .nan
    }

    /// The correlation of paired values from their sums: n, Σx, Σy, Σx², Σy², Σxy; 0 when either is flat.
    static func correlation(_ s: (n: Double, x: Double, y: Double, xx: Double, yy: Double, xy: Double)) -> Float {
        let vx = s.xx - s.x * s.x / s.n, vy = s.yy - s.y * s.y / s.n
        return vx > 0 && vy > 0 ? Float((s.xy - s.x * s.y / s.n) / (vx * vy).squareRoot()) : 0
    }

    static func add(_ x: Double, _ y: Double, to s: inout (n: Double, x: Double, y: Double, xx: Double, yy: Double, xy: Double)) {
        s.n += 1; s.x += x; s.y += y; s.xx += x * x; s.yy += y * y; s.xy += x * y
    }

    /// `alignment` verified block by block (see the type's documentation).
    static func verify(_ alignment: Alignment, source: Pyramid, target: Pyramid, earlierIsSource: Bool,
                       parameters: SequenceAims.Parameters, tuning: Tuning) -> Match? {
        let overlap = alignment.overlap(source: (source.width, source.height), target: (target.width, target.height))
        guard overlap >= parameters.minimumOverlap else { return nil }
        let l = level(for: alignment.scale, in: target, above: 0)
        let map = target.levels[l], base = source.levels[0]
        var cells: [Int] = [], points: [SIMD2<Float>] = [], a: [Float] = [], b: [Float] = []
        var uRange = (Int.max, Int.min), vRange = (Int.max, Int.min)
        for cell in base.cells {
            let q = alignment.map(cell.point, width: source.width, height: source.height)
            guard let value = sampledLog(map, level: l, at: q) else { continue }
            cells.append(cell.index); points.append(q); a.append(cell.log); b.append(value)
            let u = cell.index % base.width, v = cell.index / base.width
            uRange = (min(uRange.0, u), max(uRange.1, u))
            vRange = (min(vRange.0, v), max(vRange.1, v))
        }
        guard cells.count >= tuning.blockCells * tuning.agreeingBlocks else { return nil }

        // The texture inside the cells, which the search never read, must line up too: the two frames'
        // log detail correlated over the shared cells, the target's at the nearest cell. Two unrelated
        // textures the search lined up by chance agree in their means, not in this.
        // Detail under 0.005 stop, or not a number, is flat.
        func logDetail(_ d: Float) -> Double { log2(Double(d.isFinite ? max(d, 0.005) : 0.005)) }
        var detail = (n: 0.0, x: 0.0, y: 0.0, xx: 0.0, yy: 0.0, xy: 0.0)
        for (k, cell) in cells.enumerated() {
            let u = min(max(Int(points[k].x), 0), target.width - 1), v = min(max(Int(points[k].y), 0), target.height - 1)
            add(logDetail(source.detail[cell]), logDetail(target.detail[v * target.width + u]), to: &detail)
        }
        let detailCorrelation = correlation(detail)
        guard detailCorrelation >= tuning.detailCorrelation else { return nil }

        // Blocks over the shared cells' bounds.
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
            for k in block { add(Double(a[k]), Double(b[k]), to: &sums) }
            let detailed = block.filter { source.structured[cells[$0]] }.count
            let spread = Float(max(min(sums.xx - sums.x * sums.x / sums.n, sums.yy - sums.y * sums.y / sums.n), 0) / sums.n).squareRoot()
            return Block(structured: Float(detailed) >= tuning.structuredShare * Float(block.count) && spread >= tuning.blockSpread,
                         shift: median(block.map { b[$0] - a[$0] }), correlation: correlation(sums))
        }
        let structured = blocks.compactMap { $0 }.filter(\.structured)
        guard structured.count >= tuning.agreeingBlocks else { return nil }

        // Agreement with the structured blocks' median shift, then with the matched cells' own.
        var region = median(structured.map(\.shift))
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
            if pass == 0 { region = weightedMedian(matched.map { b[$0.k] - a[$0.k] }, matched.map(\.weight)) }
        }

        // The matched cells' correlation, and the light's colour.
        var sums = (n: 0.0, x: 0.0, y: 0.0, xx: 0.0, yy: 0.0, xy: 0.0)
        var redBlue: [Float] = [], greenMagenta: [Float] = [], weights: [Float] = []
        for (k, weight) in matched {
            add(Double(a[k]), Double(b[k]), to: &sums)
            let p = base.rgb[cells[k]], q = sampledLight(map, level: l, at: points[k])
            guard p.min() > 0, q.min() > 0 else { continue }
            let d = SIMD3(log2(q.x), log2(q.y), log2(q.z)) - SIMD3(log2(p.x), log2(p.y), log2(p.z))
            redBlue.append(d.x - d.z)
            greenMagenta.append(d.y - (d.x + d.z) / 2)
            weights.append(weight)
        }
        let sign: Float = earlierIsSource ? 1 : -1
        let colour = redBlue.isEmpty ? SIMD2<Float>(0, 0)
            : SIMD2(weightedMedian(redBlue, weights), weightedMedian(greenMagenta, weights)) * sign
        return Match(alignment: alignment, earlierIsSource: earlierIsSource, overlap: min(overlap, 1), shift: region * sign,
                     correlation: correlation(sums), structuredBlocks: structured.count, agreeingBlocks: agreeing,
                     detailCorrelation: detailCorrelation, colour: colour,
                     cells: matched.map { (cells[$0.k], points[$0.k], $0.weight) }, targetLevel: l)
    }

    // MARK: Matched points

    /// A face's box in level-0 cells of a frame `width` by `height`, rows from the bottom; `nil`
    /// for a box that is not four finite numbers.
    static func cells(of box: [Float], width: Int, height: Int, inset: Bool = false) -> (low: SIMD2<Float>, high: SIMD2<Float>)? {
        guard box.count == 4, box.allSatisfy(\.isFinite), box[2] > 0, box[3] > 0 else { return nil }
        let w = Float(width), h = Float(height)
        var low = SIMD2(box[0] * w, (1 - box[1] - box[3]) * h), high = SIMD2((box[0] + box[2]) * w, (1 - box[1]) * h)
        if inset {
            let middle = (low + high) / 2, half = (high - low) / 2 * SIMD2(FaceMeter.insetWidth, FaceMeter.insetHeight)
            low = middle - half
            high = middle + half
        }
        return (low, high)
    }

    static func intersectionOverUnion(_ a: (low: SIMD2<Float>, high: SIMD2<Float>), _ b: (low: SIMD2<Float>, high: SIMD2<Float>)) -> Float {
        let w = min(a.high.x, b.high.x) - max(a.low.x, b.low.x), h = min(a.high.y, b.high.y) - max(a.low.y, b.low.y)
        guard w > 0, h > 0 else { return 0 }
        let area = { (r: (low: SIMD2<Float>, high: SIMD2<Float>)) in (r.high.x - r.low.x) * (r.high.y - r.low.y) }
        return w * h / (area(a) + area(b) - w * h)
    }

    /// The matched points: faces that land on each other first, then the region's cells spread over it.
    static func samples(_ match: Match, earlier: Side, later: Side, limit: Int,
                        tuning: Tuning) -> (earlier: [SIMD3<Float>], later: [SIMD3<Float>], weights: [Float]) {
        let (source, target) = match.earlierIsSource ? (earlier, later) : (later, earlier)
        let sp = source.pyramid, tp = target.pyramid
        let alignment = match.alignment
        // Faces in the source's cells and the target's, and the target's mapped back onto the source.
        let sourceFaces = source.analysis.faces.map { cells(of: $0.box, width: sp.width, height: sp.height) }
        let targetFaces = target.analysis.faces.map { face -> (low: SIMD2<Float>, high: SIMD2<Float>)? in
            guard let box = cells(of: face.box, width: tp.width, height: tp.height) else { return nil }
            let corners = [box.low, box.high, SIMD2(box.low.x, box.high.y), SIMD2(box.high.x, box.low.y)]
                .map { alignment.inverse($0, width: sp.width, height: sp.height) }
            return (SIMD2(corners.map(\.x).min()!, corners.map(\.y).min()!), SIMD2(corners.map(\.x).max()!, corners.map(\.y).max()!))
        }
        // Each source face paired with the target face it lands on best, one to one.
        var pairs: [(Int, Int, Float)] = []
        for (i, s) in sourceFaces.enumerated() {
            guard let s else { continue }
            for (j, t) in targetFaces.enumerated() {
                guard let t else { continue }
                let iou = intersectionOverUnion(s, t)
                if iou >= tuning.faceOverlap { pairs.append((i, j, iou)) }
            }
        }
        pairs.sort { $0.2 > $1.2 || ($0.2 == $1.2 && ($0.0, $0.1) < ($1.0, $1.1)) }
        var pairedSource = Set<Int>(), pairedTarget = Set<Int>()
        var faceCells: [(cell: Int, weight: Float)] = []
        let sign: Float = match.earlierIsSource ? 1 : -1
        for (i, j, _) in pairs where !pairedSource.contains(i) && !pairedTarget.contains(j) {
            pairedSource.insert(i)
            pairedTarget.insert(j)
            let s = source.analysis.faces[i], t = target.analysis.faces[j]
            guard abs((t.levelStops - s.levelStops) * sign - match.shift) <= tuning.faceShift,
                  let inset = cells(of: s.box, width: sp.width, height: sp.height, inset: true) else { continue }
            let reliability = min(s.confidence ?? 1, t.confidence ?? 1)
            var inside = sp.levels[0].cells.filter { cell in
                cell.point.x >= inset.low.x && cell.point.x < inset.high.x && cell.point.y >= inset.low.y && cell.point.y < inset.high.y
            }.map(\.index)
            // Clamped in floating point before converting: a finite box far off the frame lies past Int.
            let middle = (inset.low + inset.high) / 2
            if inside.isEmpty, !middle.x.isNaN, !middle.y.isNaN {
                let u = Int(min(max(middle.x, 0), Float(sp.width - 1))), v = Int(min(max(middle.y, 0), Float(sp.height - 1)))
                if !sp.levels[0].log[v * sp.width + u].isNaN { inside = [v * sp.width + u] }
            }
            faceCells += inside.map { ($0, 2 * min(max(reliability, 0), 1)) }
        }
        // A face paired with none is someone the other frame does not show: its cells give no point.
        let unpairedSource = sourceFaces.indices.filter { !pairedSource.contains($0) }.compactMap { sourceFaces[$0] }
        let unpairedTarget = targetFaces.indices.filter { !pairedTarget.contains($0) }.compactMap { targetFaces[$0] }
        func onStranger(_ p: SIMD2<Float>) -> Bool {
            (unpairedSource + unpairedTarget).contains { p.x >= $0.low.x && p.x < $0.high.x && p.y >= $0.low.y && p.y < $0.high.y }
        }

        var earlierSamples: [SIMD3<Float>] = [], laterSamples: [SIMD3<Float>] = [], weights: [Float] = []
        func add(_ cell: Int, _ weight: Float) {
            let point = SIMD2(Float(cell % sp.width) + 0.5, Float(cell / sp.width) + 0.5)
            let q = alignment.map(point, width: sp.width, height: sp.height)
            guard sampledLog(tp.levels[match.targetLevel], level: match.targetLevel, at: q) != nil, !sp.levels[0].log[cell].isNaN else { return }
            let s = sp.levels[0].rgb[cell], t = sampledLight(tp.levels[match.targetLevel], level: match.targetLevel, at: q)
            earlierSamples.append(match.earlierIsSource ? s : t)
            laterSamples.append(match.earlierIsSource ? t : s)
            weights.append(weight)
        }
        let faceLimit = min(faceCells.count, max(0, limit) / 2)
        for k in spread(faceCells.count, faceLimit) { add(faceCells[k].cell, faceCells[k].weight) }
        let taken = Set(faceCells.map(\.cell))
        let region = match.cells.filter { !taken.contains($0.cell) && !onStranger(SIMD2(Float($0.cell % sp.width) + 0.5,
                                                                                       Float($0.cell / sp.width) + 0.5)) }
            .sorted { $0.cell < $1.cell }
        for k in spread(region.count, max(0, limit - weights.count)) { add(region[k].cell, 1) }
        return (earlierSamples, laterSamples, weights)
    }

    /// `limit` of `count` indices spread evenly, each the middle of its share; all when they fit.
    static func spread(_ count: Int, _ limit: Int) -> [Int] {
        guard limit > 0, count > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }
        return (0..<limit).map { (2 * $0 + 1) * count / (2 * limit) }
    }
}
