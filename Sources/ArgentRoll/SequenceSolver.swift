import ArgentCore
import Foundation

/// The candidates' rules (docs/research/auto/sequence-consistency.md, section 3), on a roll's own
/// levels and the links between its frames. Frames are indices into `Input.frames`, in capture
/// order; a frame's own level is `nil` before it is measured. The rules take links as
/// `usableLinks` gives them, so a link to a frame not measured never reaches them. Every function
/// here is deterministic: links are put in one order first, and each frame is visited in capture
/// order.
extension SequenceAims {
    /// The level a candidate starts a frame from: `AutoPrint.levelStops`, or with
    /// `Parameters.faceReliability` the level of the frame with each face counted by its
    /// reliability (`reliablyWeighted`).
    static func ownLevel(_ analysis: ExposureAnalysis, parameters: Parameters) -> Float {
        AutoPrint.levelStops(parameters.faceReliability ? reliablyWeighted(analysis) : analysis)
    }

    /// The links that count, in one order whatever order they came in: both frames measured, the
    /// earlier before the later, a finite shift, and a confidence above zero and at least
    /// `Parameters.minimumConfidence`.
    static func usableLinks(_ links: [Link], own: [Float?], parameters: Parameters) -> [Link] {
        links.filter { link in
            own.indices.contains(link.earlier) && own.indices.contains(link.later) && link.earlier < link.later
                && own[link.earlier] != nil && own[link.later] != nil && link.shift.isFinite
                && link.confidence.isFinite && link.confidence > 0 && link.confidence >= parameters.minimumConfidence
        }.sorted(by: precedes)
    }

    /// A total order on links: by frames, then by every value they carry.
    static func precedes(_ a: Link, _ b: Link) -> Bool {
        if a.earlier != b.earlier { return a.earlier < b.earlier }
        if a.later != b.later { return a.later < b.later }
        func order(_ x: [Float], _ y: [Float]) -> Bool? {
            if x.count != y.count { return x.count < y.count }
            for (u, v) in zip(x, y) where u.bitPattern != v.bitPattern {
                return u.isTotallyOrdered(belowOrEqualTo: v)
            }
            return nil
        }
        func flat(_ v: [SIMD3<Float>]) -> [Float] { v.flatMap { [$0.x, $0.y, $0.z] } }
        let scalars = { (l: Link) in [l.shift, l.confidence, l.overlap, l.correlation, l.lightChange == nil ? 0 : 1, l.lightChange ?? 0] }
        return order(scalars(a), scalars(b)) ?? order(a.weights, b.weights)
            ?? order(flat(a.earlierSamples), flat(b.earlierSamples)) ?? order(flat(a.laterSamples), flat(b.laterSamples)) ?? false
    }

    /// The frames `links` join, each group in capture order and the groups by their earliest frame;
    /// frames no link touches are in none.
    static func groups(_ links: [Link], count: Int) -> [[Int]] {
        var parent = Array(0..<count)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        var linked = [Bool](repeating: false, count: count)
        for link in links {
            linked[link.earlier] = true
            linked[link.later] = true
            let a = root(link.earlier), b = root(link.later)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        var members: [Int: [Int]] = [:]
        for i in 0..<count where linked[i] { members[root(i), default: []].append(i) }
        return members.keys.sorted().map { members[$0]! }
    }

    // MARK: Candidate A

    /// Candidate A's levels. In each group the frames' own levels are expressed at the exposure of
    /// the group's earliest frame (`exposureOffsets`), roll smoothing's pull and cap act there
    /// about their median, as `RollSmoothing.aims` does in a cluster, and the offsets are put back
    /// within `AutoPrint`'s bounds. A frame in no group keeps its own level.
    static func smoothedLevels(_ own: [Float?], links: [Link]) -> [Float?] {
        var levels = own
        for group in groups(links, count: own.count) {
            let offsets = exposureOffsets(group, links: links)
            let expressed = zip(group, offsets).map { own[$0]! - $1 }
            let median = RollSmoothing.median(expressed)
            for (k, i) in group.enumerated() {
                let pulled = median + min(max(RollSmoothing.pull * (expressed[k] - median), -RollSmoothing.maximumDeviation),
                                          RollSmoothing.maximumDeviation)
                levels[i] = min(max(pulled + offsets[k], -AutoPrint.bound), AutoPrint.darkenLimit)
            }
        }
        return levels
    }

    /// How many stops each frame of `group` (in capture order) was given more light than its
    /// earliest, 0, by the confidence-weighted least squares fit of every link inside it, each
    /// saying the later's offset less the earlier's is its shift. A chain or tree of links is
    /// followed exactly; a loop whose shifts disagree is shared out by confidence.
    ///
    /// The normal equations are a weighted graph Laplacian with the first frame held, positive
    /// definite for a group, and banded since links join nearby frames: solved by a banded Cholesky
    /// factorisation in double precision.
    static func exposureOffsets(_ group: [Int], links: [Link]) -> [Float] {
        let n = group.count
        guard n > 1 else { return [Float](repeating: 0, count: n) }
        let position = Dictionary(uniqueKeysWithValues: group.enumerated().map { ($1, $0) })
        let inside = links.compactMap { link -> (p: Int, q: Int, c: Double, s: Double)? in
            guard let p = position[link.earlier], let q = position[link.later] else { return nil }
            return (p, q, Double(link.confidence), Double(link.shift))
        }
        // Unknowns are the offsets of positions 1..<n; row i of the band holds columns i - width...i.
        let m = n - 1, width = max(1, inside.map { $0.q - $0.p }.max() ?? 1), row = width + 1
        var band = [Double](repeating: 0, count: m * row)
        var rhs = [Double](repeating: 0, count: m)
        for (p, q, c, s) in inside {
            if q > 0 {
                band[(q - 1) * row] += c
                rhs[q - 1] += c * s
            }
            if p > 0 {
                band[(p - 1) * row] += c
                rhs[p - 1] -= c * s
                band[(q - 1) * row + (q - p)] -= c
            }
        }
        for i in 0..<m {
            for j in max(0, i - width)...i {
                var sum = band[i * row + (i - j)]
                for k in max(0, i - width)..<j { sum -= band[i * row + (i - k)] * band[j * row + (j - k)] }
                band[i * row + (i - j)] = i == j ? sum.squareRoot() : sum / band[j * row]
            }
        }
        var x = rhs
        for i in 0..<m {
            for k in max(0, i - width)..<i { x[i] -= band[i * row + (i - k)] * x[k] }
            x[i] /= band[i * row]
        }
        for i in stride(from: m - 1, through: 0, by: -1) {
            for k in (i + 1)..<min(m, i + width + 1) { x[i] -= band[k * row + (k - i)] * x[k] }
            x[i] /= band[i * row]
        }
        return [0] + x.map { Float($0) }
    }

    // MARK: Candidate B

    /// The finest step of candidate B's search, in stops, and the coarse grid's in those steps (1/64).
    static let searchStep: Float = 1.0 / 1024
    static let coarseSteps = 16
    /// The solve stops after a sweep in which no level moved further than this, in stops, or after
    /// `maximumSweeps`.
    static let settled: Float = 1e-4
    static let maximumSweeps = 100

    /// Candidate B's levels and each linked frame's residual, the mean |ΔL*| over its links at the
    /// solution. Over each group's levels `a` it minimises
    ///
    ///     Σ_i (a_i - a0_i)² + matchWeight · Σ_links c · ρ(ΔL* / lightnessScale)
    ///                      + clipWeight · Σ_links c · (newly clipped share in either frame)
    ///
    /// with `a0` the frames' own levels, `c` a link's confidence, ΔL* the later frame's response at its
    /// level less the earlier's (`Response`, interpolated), ρ(x) = log(1 + x²), a Cauchy loss whose
    /// pull fades for a link that disagrees by far more than `lightnessScale`, and a frame's newly
    /// clipped share its response's clipped share (its matched points whose Print LUT input leaves
    /// 0...1 in any channel, `Response`) at its level less at its own level, where more, never
    /// less than none. Each level stays within `maximumMove` of its own and within
    /// `-AutoPrint.bound...AutoPrint.darkenLimit`. The objective is read straight off the responses,
    /// so a stretch of them that is flat or turns back offers nothing to gain by moving there.
    ///
    /// The solve is coordinate descent in capture order: each level in turn takes the lowest cost
    /// of every 1/64 stop from its own level within its bounds, then of every 1/1024 stop within a
    /// 64th of the best, and of where it stands; a tie keeps the level nearer its own, then where it
    /// stands. Sweeps repeat until no level moves more than `settled` or `maximumSweeps` have run.
    /// Every candidate is its own level plus a whole number of 1/1024 stops, so a level that has no
    /// reason to move keeps its own value exactly. Groups are solved apart, so a frame's removal
    /// cannot change how long another group is solved.
    static func renderedLevels(_ own: [Float?], links: [RenderedLink], parameters: Parameters) -> (levels: [Float?], residual: [Float?]) {
        var levels = own
        // The responses as flat tables, two rows a link (its earlier frame's, then its later's), so
        // the search reads numbers and nothing it has to retain.
        let lightness = links.flatMap { $0.earlier.lightness + $0.later.lightness }
        let clipped = links.flatMap { $0.earlier.clipped + $0.later.clipped }
        let earlier = links.map(\.link.earlier), later = links.map(\.link.later)
        let confidence = links.map { Double($0.link.confidence) }
        func value(_ table: [Float], _ row: Int, at level: Float) -> Float { Response.interpolate(table, row: row, at: level) }
        var touching = [[Int]](repeating: [], count: own.count)
        for k in links.indices {
            touching[earlier[k]].append(k)
            touching[later[k]].append(k)
        }
        // Each link's clipped share in each of its frames at their own levels.
        let startingClip = links.indices.flatMap { k in [value(clipped, 2 * k, at: own[earlier[k]]!), value(clipped, 2 * k + 1, at: own[later[k]]!)] }
        let match = Double(parameters.matchWeight), clip = Double(parameters.clipWeight)
        let scale = Double(parameters.lightnessScale), move = max(parameters.maximumMove, 0)

        /// The objective's terms that hold frame `i`'s level, with it at `x`.
        func cost(_ i: Int, _ x: Float) -> Double {
            let departure = Double(x - own[i]!)
            var total = departure * departure
            for k in touching[i] {
                let side = earlier[k] == i ? 0 : 1
                let e = side == 0 ? x : levels[earlier[k]]!, l = side == 0 ? levels[later[k]]! : x
                let delta = Double(value(lightness, 2 * k + 1, at: l) - value(lightness, 2 * k, at: e)) / scale
                let newly = value(clipped, 2 * k + side, at: x) - startingClip[2 * k + side]
                total += confidence[k] * (match * log1p(delta * delta) + clip * Double(max(newly, 0)))
            }
            return total
        }

        var steps = [Int](repeating: 0, count: own.count)
        for group in groups(links.map(\.link), count: own.count) {
            for _ in 0..<maximumSweeps {
                var largest: Float = 0
                for i in group {
                    let a0 = own[i]!
                    let lo = max(a0 - move, -AutoPrint.bound), hi = min(a0 + move, AutoPrint.darkenLimit)
                    guard lo <= a0, a0 <= hi else { continue }
                    let lowest = Int(((lo - a0) / searchStep).rounded(.up)), highest = Int(((hi - a0) / searchStep).rounded(.down))
                    func level(_ j: Int) -> Float { j == 0 ? a0 : min(max(a0 + Float(j) * searchStep, lo), hi) }
                    var best = steps[i], bestCost = cost(i, level(best))
                    func consider(_ j: Int) {
                        guard j >= lowest, j <= highest, j != best else { return }
                        let c = cost(i, level(j))
                        if c < bestCost || (c == bestCost && abs(j) < abs(best)) { (best, bestCost) = (j, c) }
                    }
                    for k in (lowest / coarseSteps)...(highest / coarseSteps) { consider(k * coarseSteps) }
                    let centre = best
                    for j in (centre - coarseSteps)...(centre + coarseSteps) { consider(j) }
                    largest = max(largest, abs(level(best) - levels[i]!))
                    steps[i] = best
                    levels[i] = level(best)
                }
                if largest <= settled { break }
            }
        }
        var residual = [Float?](repeating: nil, count: own.count)
        for i in own.indices where !touching[i].isEmpty {
            let differences = touching[i].map { k in
                abs(value(lightness, 2 * k + 1, at: levels[later[k]]!) - value(lightness, 2 * k, at: levels[earlier[k]]!))
            }
            residual[i] = differences.reduce(0, +) / Float(differences.count)
        }
        return (levels, residual)
    }

    // MARK: The ablation

    /// How far a face's own measurement is trusted, 0 to 1: Vision's confidence from 0.5 (none) to
    /// 0.9 (full), full without one; its skin share against half the inset, half without skin (the
    /// level then came from the whole inset); and the share of its inset not clipped.
    static func reliability(_ face: FaceMeasure) -> Float {
        let confidence = face.confidence.flatMap { $0.isFinite ? min(max(($0 - 0.5) / 0.4, 0), 1) : nil } ?? 1
        let skin: Float
        if face.skin == nil {
            skin = 0.5
        } else if let skinArea = face.skinArea, face.area > 0, skinArea.isFinite {
            skin = min(max(skinArea / face.area / 0.5, 0), 1)
        } else {
            skin = 1
        }
        let clipped = face.clipped.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil } ?? 0
        return confidence * skin * (1 - clipped)
    }

    /// `analysis` with each face's area scaled by its `reliability`, so `FittedPlacement`'s own
    /// face weight and area-weighted face level count a doubtful face less. The ablation R of the
    /// pre-registration, `Parameters.faceReliability`: it changes the FiveK-fitted placement, so it
    /// is reported and never ships from it.
    static func reliablyWeighted(_ analysis: ExposureAnalysis) -> ExposureAnalysis {
        var weighted = analysis
        for k in weighted.faces.indices { weighted.faces[k].area *= reliability(weighted.faces[k]) }
        return weighted
    }
}
