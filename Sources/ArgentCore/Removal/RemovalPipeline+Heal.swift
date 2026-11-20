import Foundation

/// A removal with no model, where what is round the selection is smooth (docs/remove-plan.md, section 18).
///
/// A model redraws the hole in its own colour. `match` takes its correction from outside the hole's edge and carries it
/// across the hole, so the fill meets the original at the edge; it knows nothing of how the fill's middle stands against the
/// fill's own edge, and a fill that is lighter in its middle than at its rim stays lighter there. On a blue sky that is two
/// levels of red in 255 over a disc 300 pixels across, with the decoder's blotches in place of the sky's grain: the "patchy
/// whitish smudge" the owner saw where a speck of sensor dust had been, from ObjectClear and from FLUX with OSOR alike.
///
/// Where the ring round the hole is nothing but a smooth trend and grain, nothing has to be imagined, and the ring says all
/// there is to say: the fill is the ring's trend carried across the hole, with the ring's own grain laid over it. It is made
/// in scene light from the crop's own pixels, in a fraction of a second, and no model is asked. Nothing outside the ring is
/// read: what lies beyond it is neither judged nor drawn from.
extension RemovalPipeline {
    /// What a patch notes as its engine when no model drew it.
    public static let healEngine = "heal"

    /// The ring that is judged and drawn from is half the hole's radius wide, within these (inference: wide enough to hold a
    /// tile of grain and to say which way the level runs, narrow enough to be the hole's own neighbourhood).
    static let healRingRange = 32...96
    /// The ring's departure from its trend is judged after a box blur of this radius, which averages 81 pixels of grain away
    /// and leaves what is not grain.
    static let healJudgeBlur = 4
    /// The ring is smooth when that departure's root mean square, as a share of the ring's level, is no more than the ring's
    /// grain, held within these; when its largest is no more than `healLargest` times that; and when all the ring keeps
    /// beyond its fit, unsmoothed, is no more than `healGrainLimit`. Measured on the owner's sky at ISO 100 (a 640 by 640
    /// crop, the hole a disc 300 across): departure 0.4 %, largest 2.8 %, grain 1.1 %. On grass, leaves and brick:
    /// departures of 30 to 58 %. Nothing between was measured, so the limits sit near the sky: a wall with stains or a sky
    /// with cloud in it goes to the model.
    static let healDepartureRange: ClosedRange<Float> = 0.008...0.025
    static let healLargest: Float = 6
    static let healGrainLimit: Float = 0.04
    /// And when all the ring keeps beyond its fit is no more than this many times its grain, the part of it finer than three
    /// pixels: what is not fine is not grain, and tiles would cut it. The owner's sky stands at 1.2, white grain at 1.06,
    /// grain spread over two pixels at 1.5. Stripes nine pixels apart, which a box of nine averages away and a mean of
    /// three hardly sees, stand at 3.4 where they are a twentieth of the level and 5.9 where a fifth (found in review:
    /// before this they passed, and the tiles broke their phase). Stripes four pixels apart or less pass as grain where they
    /// are under `healGrainLimit` in all.
    static let healTextureRatio: Float = 2
    /// The fit is read inside the hole only as far as the ring bears it out: in no channel may it leave the range it has
    /// over the ring by more than this many times that range (and a hundredth of the level, so a flat ring is not held to
    /// nothing). A hole the ring surrounds stays within it: at the top of a bowl it is 0.8 of the range past it. A hole
    /// against the frame's edge has a ring on one side, and the fit is then carried several ring widths past its last
    /// sample (found in review: a ring falling from 0.25 to 0.225 gave -0.13 at the edge).
    static let healOverreach: Float = 1
    static let healOverreachSlack: Float = 0.01
    /// What the trend misses along the hole's edge is smoothed by this before it is carried in as a membrane.
    static let healCarryBlur = 6
    /// The grain is laid in tiles this size, each from somewhere in the ring that holds a whole tile. Grain has no shape a
    /// tile's edge could cut.
    static let healTile = 16

    /// What is round a hole: the ring, the quadratic that fits each channel of it, and how far the ring stands from that fit.
    struct Surround {
        /// 255 in the ring, 0 elsewhere.
        var ring: [UInt8]
        /// The fit, over the whole raster: `width * height * 3`.
        var trend: [Float]
        /// The smoothed departure of the ring from the fit, as shares of the ring's level: its root mean square and its largest.
        var departure: Float
        var largest: Float
        /// The root mean square of what a 3 by 3 mean leaves of the ring, as a share of its level.
        var grain: Float
        /// The root mean square of all the ring keeps beyond the fit, unsmoothed, as a share of its level.
        var total: Float
        /// How far the fit inside the hole leaves the range it has over the ring, beyond what `healOverreach` allows, as a
        /// share of the ring's level: 0 where the hole is filled from within what the ring shows.
        var beyond: Float

        var isSmooth: Bool {
            let limit = min(max(grain, healDepartureRange.lowerBound), healDepartureRange.upperBound)
            let fine = total <= max(healTextureRatio * grain, healDepartureRange.lowerBound)
            return total <= healGrainLimit && fine && departure <= limit && largest <= healLargest * limit && beyond <= 0
        }
    }

    /// The patch for a job whose hole lies in smooth surroundings, or `nil` where they are not smooth and a model must draw it.
    /// The hole is the mask the model would have been given, grown as the changed area is. There is no attention map: a
    /// shadow that touches the object is in the ring, and a ring with a shadow in it is not smooth, but a shadow that lies
    /// wholly beyond the ring is not seen and stays (Try Again gives it to the model). Throws `CancellationError` between
    /// its passes when its task is cancelled.
    public static func healed(_ prepared: Prepared, faces: [FaceMeasure], made: Date = Date()) throws -> RemovalPatch? {
        let job = prepared.job, plan = prepared.plan, width = job.width, height = job.height
        let hole = changedArea(object: job.mask, attention: [UInt8](repeating: 0, count: width * height), width: width,
                               height: height, growth: changedGrowth(shortSide: min(width, height)))
        try Task.checkCancellation()
        guard let surround = surround(of: hole, in: prepared.original, width: width, height: height), surround.isSmooth else { return nil }
        try Task.checkCancellation()
        guard let fill = healFill(prepared.original, hole: hole, surround: surround, width: width, height: height, seed: job.seed) else {
            return nil
        }
        try Task.checkCancellation()
        let objectAlpha = feathered(job.mask, width: width, height: height, by: feather)
        var effectsAlpha = feathered(hole, width: width, height: height, by: feather)
        for i in effectsAlpha.indices where effectsAlpha[i] < objectAlpha[i] { effectsAlpha[i] = objectAlpha[i] }
        let notes = RemovalPatch.Notes(engine: healEngine, seed: job.seed, decoder: prepared.crop.decoder,
                                       frameWidth: plan.frameWidth, frameHeight: plan.frameHeight,
                                       face: redrawnFace(faces, changed: hole, object: job.mask, width: width, height: height, plan: plan),
                                       made: made, growth: maskGrowth)
        let limit = Float(Float16.greatestFiniteMagnitude)
        return try RemovalPatch(box: plan.box, width: width, height: height, rgb: fill.map { Float16(min(max($0, -limit), limit)) },
                                objectAlpha: objectAlpha, effectsAlpha: effectsAlpha, notes: notes)
    }

    /// The ring round `hole`, its fit and its measures, or `nil` where there is too little ring to judge: a hole that fills
    /// its raster, or one in a corner of it.
    static func surround(of hole: [UInt8], in original: [Float], width w: Int, height h: Int) -> Surround? {
        let count = w * h
        let holeCount = hole.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        guard holeCount > 0, holeCount < count else { return nil }
        let reach = min(healRingRange.upperBound, max(healRingRange.lowerBound, Int((Float(holeCount) / .pi).squareRoot() / 2)))
        var ring = grown(hole, width: w, height: h, by: reach)
        var ringCount = 0
        for i in 0..<count {
            if hole[i] != 0 { ring[i] = 0 } else if ring[i] != 0 { ring[i] = 255; ringCount += 1 }
        }
        guard ringCount >= max(2000, holeCount / 4) else { return nil }

        // Each channel as a quadratic of the place, by least squares over the ring: one matrix, three right sides.
        var t = [Double](repeating: 1, count: 6)
        func terms(_ p: Int) {
            let x = (Double(p % w) + 0.5) / Double(w) - 0.5, y = (Double(p / w) + 0.5) / Double(h) - 0.5
            t[1] = x; t[2] = y; t[3] = x * x; t[4] = x * y; t[5] = y * y
        }
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        var sides = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 3)
        for p in 0..<count where ring[p] != 0 {
            terms(p)
            for i in 0..<6 {
                for j in i..<6 { matrix[i][j] += t[i] * t[j] }
                for k in 0..<3 { sides[k][i] += t[i] * Double(original[p * 3 + k]) }
            }
        }
        for i in 0..<6 { for j in 0..<i { matrix[i][j] = matrix[j][i] } }
        guard let fits = solved(matrix, sides) else { return nil }
        var trend = [Float](repeating: 0, count: count * 3)
        var level = [Float](repeating: 0, count: count), ringLevel = 0.0
        // The fit's range over the ring and over the hole, a channel.
        var ringLow = [Float](repeating: .infinity, count: 3), ringHigh = [Float](repeating: -.infinity, count: 3)
        var holeLow = ringLow, holeHigh = ringHigh
        for p in 0..<count {
            terms(p)
            var sum: Float = 0
            for k in 0..<3 {
                var value = 0.0
                for i in 0..<6 { value += fits[k][i] * t[i] }
                let fitted = Float(value)
                trend[p * 3 + k] = fitted; sum += fitted
                if ring[p] != 0 {
                    ringLow[k] = min(ringLow[k], fitted); ringHigh[k] = max(ringHigh[k], fitted)
                } else if hole[p] != 0 {
                    holeLow[k] = min(holeLow[k], fitted); holeHigh[k] = max(holeHigh[k], fitted)
                }
            }
            level[p] = sum / 3
            if ring[p] != 0 { ringLevel += Double(sum / 3) }
        }
        let mean = Float(ringLevel / Double(ringCount))
        guard mean.isFinite, mean > 0 else { return nil }
        var beyond: Float = 0
        for k in 0..<3 {
            let allowed = healOverreach * (ringHigh[k] - ringLow[k]) + healOverreachSlack * mean
            beyond = max(beyond, (ringLow[k] - holeLow[k] - allowed) / mean, (holeHigh[k] - ringHigh[k] - allowed) / mean)
        }

        // The ring less its fit, as a share of the level, and nothing elsewhere; `cover` says how much of a window is ring.
        var share = [Float](repeating: 0, count: count * 3), inRing = [Float](repeating: 0, count: count)
        for p in 0..<count where ring[p] != 0 {
            inRing[p] = 1
            let under = max(level[p], mean / 4)
            for k in 0..<3 { share[p * 3 + k] = (original[p * 3 + k] - trend[p * 3 + k]) / under }
        }
        let smooth = blurred(share, width: w, height: h, channels: 3, radius: healJudgeBlur)
        let cover = blurred(inRing, width: w, height: h, channels: 1, radius: healJudgeBlur)
        let near = blurred(share, width: w, height: h, channels: 3, radius: 1)
        let nearCover = blurred(inRing, width: w, height: h, channels: 1, radius: 1)
        var squares = 0.0, fineSquares = 0.0, allSquares = 0.0, largest: Float = 0, judged = 0
        for p in 0..<count where ring[p] != 0 && cover[p] > 0.6 {
            judged += 1
            for k in 0..<3 {
                let s = smooth[p * 3 + k] / cover[p]
                squares += Double(s * s); largest = max(largest, abs(s))
                let fine = share[p * 3 + k] - near[p * 3 + k] / max(nearCover[p], 1e-3)
                fineSquares += Double(fine * fine)
                allSquares += Double(share[p * 3 + k] * share[p * 3 + k])
            }
        }
        guard judged >= 400 else { return nil }
        let values = Double(judged * 3)
        let departure = Float((squares / values).squareRoot()), grain = Float((fineSquares / values).squareRoot())
        let total = Float((allSquares / values).squareRoot())
        guard departure.isFinite, grain.isFinite, total.isFinite, largest.isFinite, beyond.isFinite else { return nil }
        return Surround(ring: ring, trend: trend, departure: departure, largest: largest, grain: grain, total: total,
                        beyond: max(beyond, 0))
    }

    /// The crop with its hole filled from the ring: the trend, what the trend misses at the hole's edge carried in as a
    /// membrane so the fill meets the edge, and the ring's grain in tiles. `nil` where no part of the ring holds a tile.
    ///
    /// Only the ring is read. What the trend misses is smoothed over the ring's pixels alone, each window's sum over the ring
    /// in it: a window that took in what lies beyond the ring would carry it into the membrane and, taken from a tile as
    /// its smooth part, into the grain (found in review: a bright field one pixel past the ring put a dark mark of a third of
    /// the level into a flat fill). Beyond the ring the membrane is given nothing, and the fit stands alone there.
    static func healFill(_ original: [Float], hole: [UInt8], surround: Surround, width w: Int, height h: Int, seed: UInt64) -> [Float]? {
        let count = w * h, trend = surround.trend, ring = surround.ring, tile = healTile
        var left = [Float](repeating: 0, count: count * 3), known = [Float](repeating: 0, count: count)
        for p in 0..<count where ring[p] != 0 {
            known[p] = 1
            for k in 0..<3 { left[p * 3 + k] = original[p * 3 + k] - trend[p * 3 + k] }
        }
        let smoothed = blurred(left, width: w, height: h, channels: 3, radius: healCarryBlur)
        let weight = blurred(known, width: w, height: h, channels: 1, radius: healCarryBlur)
        var carried = [Float](repeating: 0, count: count * 3)
        for p in 0..<count where ring[p] != 0 {
            for k in 0..<3 { carried[p * 3 + k] = smoothed[p * 3 + k] / max(weight[p], 1e-3) }
        }
        carried = membrane(carried, hole: hole, width: w, height: h, channels: 3)

        // Where a whole tile is ring: a summed table of the ring, and every corner whose tile's sum is the tile.
        guard w >= tile, h >= tile else { return nil }
        var table = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Int32 = 0
            for x in 0..<w {
                row += ring[y * w + x] != 0 ? 1 : 0
                table[(y + 1) * (w + 1) + x + 1] = table[y * (w + 1) + x + 1] + row
            }
        }
        var corners: [Int32] = []
        let whole = Int32(tile * tile)
        for y in 0...(h - tile) { for x in 0...(w - tile) {
            let sum = table[(y + tile) * (w + 1) + x + tile] - table[y * (w + 1) + x + tile]
                - table[(y + tile) * (w + 1) + x] + table[y * (w + 1) + x]
            if sum == whole { corners.append(Int32(y * w + x)) }
        } }
        guard !corners.isEmpty else { return nil }

        var fill = original
        var minX = w, maxX = -1, minY = h, maxY = -1
        for p in 0..<count where hole[p] != 0 {
            minX = min(minX, p % w); maxX = max(maxX, p % w); minY = min(minY, p / w); maxY = max(maxY, p / w)
        }
        // SplitMix64 from the job's seed: another selection has another, and its tiles lie otherwise.
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        for top in stride(from: minY, through: maxY, by: tile) { for start in stride(from: minX, through: maxX, by: tile) {
            let corner = Int(corners[Int(next() % UInt64(corners.count))])
            for dy in 0..<min(tile, h - top) { for dx in 0..<min(tile, w - start) {
                let p = (top + dy) * w + start + dx
                guard hole[p] != 0 else { continue }
                let q = corner + dy * w + dx
                for k in 0..<3 {
                    let grain = original[q * 3 + k] - trend[q * 3 + k] - carried[q * 3 + k]
                    fill[p * 3 + k] = trend[p * 3 + k] + carried[p * 3 + k] + grain
                }
            } }
        } }
        return fill
    }

    /// `matrix` x = each of `sides`, by elimination with the largest pivot, or `nil` where the matrix has none: a ring that
    /// lies along one line.
    private static func solved(_ matrix: [[Double]], _ sides: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        var a = matrix, b = sides
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) { pivot = row }
            guard abs(a[pivot][column]) > 1e-12 else { return nil }
            if pivot != column {
                a.swapAt(pivot, column)
                for k in b.indices { b[k].swapAt(pivot, column) }
            }
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                guard factor != 0 else { continue }
                for j in column..<n { a[row][j] -= factor * a[column][j] }
                for k in b.indices { b[k][row] -= factor * b[k][column] }
            }
        }
        var out = b
        for k in b.indices {
            for row in stride(from: n - 1, through: 0, by: -1) {
                var value = b[k][row]
                for j in (row + 1)..<n { value -= a[row][j] * out[k][j] }
                out[k][row] = value / a[row][row]
            }
        }
        return out
    }
}
