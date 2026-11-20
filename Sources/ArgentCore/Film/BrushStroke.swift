import Foundation

// How a brush stroke's stored points become dabs, and dabs become coverage: pure arithmetic, no picture and no GPU.
//
// A stroke is stored as its points (`BrushStroke.points`, quantized to `MaskSpace.brushPointsPerLongSide`), never as dabs, so the dabs are
// made again from the points on every replay and must come out the same each time: `BrushDabPath` is that rule, and part of the masks
// compiler (`MaskSet.currentVersion`), as R8 7.2 has it. `StrokeSampler` is what a stroke in progress goes through first: it decides
// which of the pointer's points to keep (the Shift constraints, thinning, the per-mask point cap), and feeds the kept ones to the path,
// so a stroke painted live and the same stroke replayed from the recipe lay down the same dabs in the same order.

/// The brush's constants. A change of any of them is a change of what a stored stroke prints, so a new masks compiler.
public enum BrushModel {
    /// Dabs fall every tenth of the diameter along a stroke (plan section 6). R8 7.1: a hard dab's edge scallops by `r(1 − √(1 − (s/2r)²))`,
    /// 0.005 r at 10 % against 0.032 r at R7's 25 %, 3 px at r = 100 px. Coverage does not depend on it beyond that scallop, since a
    /// stroke lays down the largest of its dabs (`BrushDabProfile`), so the closer spacing costs only dabs.
    public static let spacingShare: Double = 0.1
    /// Never closer than half a canvas texel, which for the smallest brush (r 0.001, two texels) is 0.12 of its diameter.
    public static let minimumSpacing: Double = 0.5 / Double(MaskFieldSize.longSide)
    /// A smoothed segment's tangents are as long as its chord and turn at most 60° from it, so the curve never strays more than a quarter
    /// of the chord's length from the chord (the chord bound): a fast hairpin on the trackpad becomes a corner, never a loop.
    public static let chordBound: Double = 0.25
    /// The most dabs one segment between two kept points lays down: past 6.4 diameters of arc a segment spaces its dabs more widely,
    /// which a stroke made here never meets (`reachShare`), only a stroke read from elsewhere. So any stored stroke has at most 1 + 65
    /// dabs a point, and a mask at its point cap about 1.07 million.
    public static let maximumDabsPerSegment = 64
    /// A dab's edge is at least one canvas texel wide, so even a hard brush is antialiased on the canvas: about 3.4 px at 7008 (plan
    /// section 6, "a hard brush edge softens about 3 px").
    public static let minimumEdge: Float = 1 / Float(MaskFieldSize.longSide)
    /// A kept point lies at least half a dab spacing from the one before it; nearer ones are dropped (the last is kept at the end), so
    /// a slow hand does not spend the mask's point cap.
    public static let thinningShare: Double = 0.5
    /// And at most half the arc a segment's dab cap spans, 32 spacings or 3.2 diameters: a point farther away is reached through
    /// evenly spaced points on the chord, so a long Shift-click line keeps its spacing rather than meeting the cap.
    public static let reachShare: Double = 0.5
    /// Shift-drag constrains to horizontal or vertical (R7 4.4), chosen by the first point this far from the press, in long sides
    /// (about 35 px at 7008, 5 pt at fit); points before it are not kept.
    public static let axisDecisionDistance: Float = 0.005
}

/// One dab: where its centre falls, in `MaskSpace`. Its radius, edge, flow and erase are its stroke's.
public struct BrushDab: Sendable, Hashable {
    public var x: Float
    public var y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}

/// A dab's shape: 1 inside `inner`, falling by a smoothstep to 0 at `outer`, the radius. Feather is Lightroom's: the share of the radius
/// the edge falls over, the distance between its brush's inner and outer circles; never less than `BrushModel.minimumEdge`.
public struct BrushDabProfile: Sendable, Hashable {
    public let outer: Float
    public let inner: Float

    public init(radius: Float, feather: Float) {
        let edge = min(radius, max(feather * radius, BrushModel.minimumEdge))
        outer = radius
        inner = radius - edge
    }

    /// The dab's value at a distance from its centre, as `brush_dab` computes it.
    public func value(distance: Float) -> Float {
        if distance >= outer { return 0 }
        if distance <= inner { return 1 }
        let x = (distance - inner) / (outer - inner)
        return 1 - x * x * (3 - 2 * x)
    }
}

/// How a stroke lays its dabs on a component's canvas. Within a stroke the dabs make one shape, the largest of their values at a point,
/// so a stroke's cross-section is its dab's profile and its ends are round, whatever the spacing. A stroke then lays that shape down at
/// its Flow: paint `c + φ·s·(1 − c)`, erase `c·(1 − φ·s)`, so one pass of Flow 50 reaches 0.5 in the core and passes build up (R7's
/// "overlapping passes build up and a slip is light"), and erasing takes paint off only this component. The canvas is half float, and
/// each stroke's result is rounded to it, the same on the GPU, live and replayed, and here.
public enum BrushCompositing {
    public static func compose(_ c: Float, stroke s: Float, flow: Float, erase: Bool) -> Float {
        half(composeUnrounded(c, stroke: s, flow: flow, erase: erase))
    }

    /// The same in `Float` throughout: what an `r32Float` canvas would hold, to measure the half float's error against.
    public static func composeUnrounded(_ c: Float, stroke s: Float, flow: Float, erase: Bool) -> Float {
        let a = flow * s
        return erase ? c * (1 - a) : c + a * (1 - c)
    }

    /// The canvas's own rounding: to the nearest half float.
    public static func half(_ v: Float) -> Float { Float(Float16(v)) }
}

/// The deterministic rule from kept points to dabs: a dab at the first point, then along a smoothed curve through every point, one every
/// `spacing` of arc length, and one at the last point when the stroke ends. The curve between two points is a cubic Hermite segment whose
/// tangents follow Catmull-Rom's directions (the chord from the point before to the point after), are as long as the chord, and turn at
/// most 60° from it (`BrushModel.chordBound`). A segment is laid down once the point after its end is known, so a stroke in progress
/// lags one point; `end` lays the last with the end's own tangent. Feeding the same points always gives the same dabs, bit for bit: the
/// arithmetic is `Double`, with no function a platform may round differently.
public struct BrushDabPath: Sendable {
    public let radius: Float
    /// Arc length between dabs, in long sides.
    public let spacing: Double
    public private(set) var points: [SIMD2<Double>] = []
    /// Segments laid down: segment i runs from `points[i]` to `points[i + 1]`.
    private var laid = 0
    /// Arc length travelled since the last dab.
    private var travelled: Double = 0
    public private(set) var dabCount = 0
    public private(set) var hasEnded = false

    public init(radius: Float) {
        self.radius = radius
        spacing = max(BrushModel.spacingShare * 2 * Double(radius), BrushModel.minimumSpacing)
    }

    /// Takes the next point and returns the dabs it makes certain. A point equal to the last is ignored.
    public mutating func add(_ point: MaskPoint) -> [BrushDab] {
        precondition(!hasEnded, "a path that ended takes no point")
        let p = SIMD2<Double>(Double(point.x), Double(point.y))
        if let last = points.last, last == p { return [] }
        points.append(p)
        if points.count == 1 {
            dabCount += 1
            return [Self.dab(p)]
        }
        // The segment before the one this point ends is now certain: its end tangent can see this point.
        guard points.count >= 3 else { return [] }
        return lay(segment: points.count - 3)
    }

    /// Lays the last segment with the end's tangent, and a dab at the last point unless one fell on it.
    public mutating func end() -> [BrushDab] {
        guard !hasEnded else { return [] }
        hasEnded = true
        var out: [BrushDab] = []
        if points.count >= 2 { out = lay(segment: points.count - 2) }
        if travelled > 0, let last = points.last {
            out.append(Self.dab(last))
            dabCount += 1
            travelled = 0
        }
        return out
    }

    /// Every dab of a stored stroke, in order: its points through the path, then the end.
    public static func dabs(of stroke: BrushStroke) -> [BrushDab] {
        var path = BrushDabPath(radius: stroke.radius)
        var out: [BrushDab] = []
        for point in stroke.points.points { out += path.add(point) }
        return out + path.end()
    }

    private static func dab(_ p: SIMD2<Double>) -> BrushDab { BrushDab(x: Float(p.x), y: Float(p.y)) }

    /// The tangent's direction at point `i` for a segment whose chord is `chord`: Catmull-Rom's, from the point before to the point after,
    /// or the chord's own at an end or where those two coincide; then turned toward the chord until it is within 60° of it.
    private func tangent(at i: Int, chord: SIMD2<Double>) -> SIMD2<Double> {
        let length = (chord * chord).sum().squareRoot()
        let along = chord / length
        var direction = along
        if i > 0, i + 1 < points.count {
            let span = points[i + 1] - points[i - 1]
            let spanLength = (span * span).sum().squareRoot()
            if spanLength > 0 { direction = span / spanLength }
        }
        // cos 60° = 0.5. Past it, the tangent is the chord turned 60° toward the side the direction lies on.
        let cosine = (direction * along).sum()
        if cosine < 0.5 {
            let side: Double = along.x * direction.y - along.y * direction.x >= 0 ? 1 : -1
            let sine = 0.8660254037844386 * side
            direction = SIMD2(along.x * 0.5 - along.y * sine, along.x * sine + along.y * 0.5)
        }
        return direction * length
    }

    /// Lays segment `index`'s dabs, continuing the arc length from the last dab.
    private mutating func lay(segment index: Int) -> [BrushDab] {
        precondition(index == laid, "segments are laid in order")
        laid += 1
        let a = points[index], b = points[index + 1], chord = b - a
        let chordLength = (chord * chord).sum().squareRoot()
        let ma = tangent(at: index, chord: chord), mb = tangent(at: index + 1, chord: chord)
        // The curve as a polyline of at least 4 and at most 256 pieces, about a quarter spacing each.
        let pieces = min(256, max(4, Int((4 * chordLength / spacing).rounded(.up))))
        var vertices = [SIMD2<Double>](repeating: a, count: pieces + 1)
        var arc: Double = 0
        for j in 1...pieces {
            let t = Double(j) / Double(pieces), t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
            vertices[j] = j == pieces ? b : a * h00 + ma * h10 + b * h01 + mb * h11
            let step = vertices[j] - vertices[j - 1]
            arc += (step * step).sum().squareRoot()
        }
        let local = max(spacing, arc / Double(BrushModel.maximumDabsPerSegment))
        var out: [BrushDab] = []
        var need = max(local - travelled, 0)
        for j in 1...pieces {
            let from = vertices[j - 1], step = vertices[j] - from
            let length = (step * step).sum().squareRoot()
            var at: Double = 0
            while need <= length - at {
                at += need
                out.append(Self.dab(length > 0 ? from + step * (at / length) : from))
                need = local
            }
            need -= length - at
        }
        travelled = local - need
        dabCount += out.count
        return out
    }
}

/// A brush's settings for one stroke, as the panel holds them.
public struct BrushSettings: Sendable, Hashable {
    public var radius: Float
    public var feather: Float
    public var flow: Float
    public var erase: Bool
    /// Follow edges: the stroke keeps to the colours under its dabs' centres and is refined to the picture's edges as it ends.
    public var followEdges: Bool
    public init(radius: Float, feather: Float = 0.5, flow: Float = 1, erase: Bool = false, followEdges: Bool = false) {
        self.radius = radius; self.feather = feather; self.flow = flow; self.erase = erase; self.followEdges = followEdges
    }

    var isValid: Bool {
        radius.isFinite && feather.isFinite && flow.isFinite && MaskSpace.brushRadiusRange.contains(radius)
            && (0...1).contains(feather) && (0...1).contains(flow)
    }
}

/// A stroke in progress, from the pointer's points to the stroke the recipe keeps and its dabs. Pure: the UI feeds it `MaskSpace` points
/// (`FrameGeometry.maskPoint`), and the canvas lays down what it returns. It decides which points are kept:
/// - each is quantized to the stored grid and clamped to `MaskSpace.brushCoordinateRange` first, so the dabs laid live are the dabs the
///   stored stroke replays;
/// - Shift-drag (`.axis`) keeps nothing until the pointer is `axisDecisionDistance` from the press, then holds the stroke to the
///   horizontal or vertical through the press, whichever the pointer went further along;
/// - Shift-click (`.line(from:)`) is a straight stroke from a point, usually the last stroke's end, to the pointer, whose end follows the
///   pointer until the stroke ends;
/// - a point nearer the last kept one than half a dab spacing is held back as pending, and kept at the end if it is still the last;
/// - a point farther from the last kept one than `BrushModel.reachShare` of a segment's dab cap is reached through points spaced evenly
///   on the chord, so a Shift-click line across the frame or a fling keeps the tenth-of-a-diameter spacing, and the stored stroke alone
///   bounds its dabs;
/// - the mask's point cap (`MaskSet.maximumBrushPoints`, less what its other strokes hold) stops it: past it no point is kept, and the
///   stroke ends at the last one that was (`isFull`).
public struct StrokeSampler: Sendable {
    public enum Constraint: Sendable, Hashable {
        case none
        /// Shift-drag: horizontal or vertical through the press.
        case axis
        /// Shift-click: a straight line from this point.
        case line(from: MaskPoint)
    }

    public let settings: BrushSettings
    public let constraint: Constraint
    /// Points this stroke may keep.
    public let pointBudget: Int
    private var path: BrushDabPath
    public private(set) var kept: [MaskPoint] = []
    /// What ending now would keep after `kept`: the pointer's latest point when it was not kept, and on a Shift-click line the points
    /// that reach it.
    public private(set) var pending: [MaskPoint] = []
    private var axis: Axis?
    private let thinning: Double
    private let reach: Double
    public private(set) var isFull = false
    /// Dabs laid so far, the certain ones: what the canvas has received.
    public private(set) var laidDabs = 0

    private enum Axis { case horizontal, vertical }

    /// Refuses settings out of range, and a budget of no point, which a full mask has: past `MaskSet.maximumBrushPoints` a mask's brush is
    /// flattened before it takes another stroke.
    public init(settings: BrushSettings, constraint: Constraint = .none, pointBudget: Int = MaskSet.maximumBrushPoints) throws {
        guard settings.isValid else { throw MaskError.invalid("a brush stroke has a radius, feather, flow and points") }
        let needed = { if case .line = constraint { return 2 } else { return 1 } }()
        guard pointBudget >= needed else {
            throw MaskError.invalid("a brush mask is \(MaskSet.maximumBrushPoints) points at most; flatten it to a raster")
        }
        self.settings = settings
        self.constraint = constraint
        self.pointBudget = min(pointBudget, MaskSet.maximumBrushPoints)
        path = BrushDabPath(radius: settings.radius)
        thinning = max(BrushModel.thinningShare * path.spacing, 1 / Double(MaskSpace.brushPointsPerLongSide))
        reach = BrushModel.reachShare * Double(BrushModel.maximumDabsPerSegment) * path.spacing
    }

    /// A point on the stored grid, as `PackedPoints` keeps it.
    public static func quantized(_ point: MaskPoint) -> MaskPoint {
        let range = MaskSpace.brushCoordinateRange, scale = Float(MaskSpace.brushPointsPerLongSide)
        func q(_ v: Float) -> Float { (min(max(v.isFinite ? v : 0, range.lowerBound), range.upperBound) * scale).rounded() / scale }
        return MaskPoint(x: q(point.x), y: q(point.y))
    }

    /// The next point from the pointer; the first is the press. Returns the dabs it makes certain, for the canvas.
    public mutating func add(_ raw: MaskPoint) -> [BrushDab] {
        var point = Self.quantized(raw)
        if case .line(let from) = constraint {
            // The line's start is kept at the press; the pointer only ever moves its end.
            let dabs = kept.isEmpty ? keep([Self.quantized(from)]) : []
            pending = room(steps(to: point))
            return dabs
        }
        guard let start = kept.first else { return keep([point]) }
        if constraint == .axis {
            if axis == nil {
                let dx = point.x - start.x, dy = point.y - start.y
                guard (dx * dx + dy * dy).squareRoot() >= BrushModel.axisDecisionDistance else { return [] }
                axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
            }
            point = axis == .horizontal ? MaskPoint(x: point.x, y: start.y) : MaskPoint(x: start.x, y: point.y)
        }
        guard let last = kept.last, point != last, !isFull else { pending = []; return [] }
        let dx = Double(point.x) - Double(last.x), dy = Double(point.y) - Double(last.y)
        if (dx * dx + dy * dy).squareRoot() >= thinning { return keep(steps(to: point)) }
        pending = room([point])
        return []
    }

    /// The dabs ending now would add: the last segment and the pending points, for the live canvas and the print.
    public var tail: [BrushDab] {
        var copy = path
        let out = pending.flatMap { copy.add($0) }
        return out + copy.end()
    }

    /// The stroke as the recipe would keep it if it ended now, or `nil` before the first point.
    public var stroke: BrushStroke? {
        let points = kept + pending
        guard !points.isEmpty, let packed = try? PackedPoints.pack(points) else { return nil }
        return BrushStroke(erase: settings.erase, followEdges: settings.followEdges, radius: settings.radius, feather: settings.feather,
                           flow: settings.flow, points: packed)
    }

    /// Ends the stroke: keeps the pending points, and returns the last dabs and the stroke, or `nil` before any point.
    public mutating func end() -> (dabs: [BrushDab], stroke: BrushStroke)? {
        guard let stroke else { return nil }
        let rest = pending
        var out = keep(rest)
        let last = path.end()
        laidDabs += last.count
        out += last
        return (out, stroke)
    }

    /// The points from the last kept one to `point`: `point` itself, or evenly spaced points on the chord when it is farther than `reach`.
    private func steps(to point: MaskPoint) -> [MaskPoint] {
        guard let last = kept.last else { return [point] }
        let dx = Double(point.x) - Double(last.x), dy = Double(point.y) - Double(last.y)
        let count = Int(((dx * dx + dy * dy).squareRoot() / reach).rounded(.up))
        guard count > 1 else { return point == last ? [] : [point] }
        var out: [MaskPoint] = []
        for j in 1..<count {
            let t = Double(j) / Double(count)
            let step = Self.quantized(MaskPoint(x: Float(Double(last.x) + dx * t), y: Float(Double(last.y) + dy * t)))
            if step != (out.last ?? last) { out.append(step) }
        }
        if point != out.last { out.append(point) }
        return out
    }

    /// As many of `points` as the budget leaves room for.
    private func room(_ points: [MaskPoint]) -> [MaskPoint] { Array(points.prefix(max(0, pointBudget - kept.count))) }

    private mutating func keep(_ points: [MaskPoint]) -> [BrushDab] {
        pending = []
        var dabs: [BrushDab] = []
        for point in points {
            guard kept.count < pointBudget else { isFull = true; break }
            kept.append(point)
            dabs += path.add(point)
        }
        if kept.count >= pointBudget { isFull = true }
        laidDabs += dabs.count
        return dabs
    }
}

/// A brush component's coverage on the CPU: the arithmetic the canvas kernels run, at any point, with each stroke rounded to half float
/// as the canvas is. For the overlay's reference and the tests; the print reads the GPU's canvas. A Follow edges stroke is the shape it
/// measured (`MeasuredStroke`), read at the slice texel a point lies in, as `brush_replay_measured` reads it.
public struct BrushField: Sendable {
    private struct Stroke: Sendable {
        let profile: BrushDabProfile
        let flow: Float
        let erase: Bool
    }
    /// A measured stroke's shape: its raster, where it lies, and the texel pitch of the slice it was measured over.
    private struct Shape: Sendable {
        let raster: MaskRaster
        let x: Int
        let y: Int
        let texelToPoint: SIMD2<Float>
    }
    private let strokes: [Stroke]
    /// Every dab in stroke order: its centre and its stroke; a measured stroke is one entry, `shape` its index in `shapes`, -1 for a dab.
    private let dabs: [(x: Float, y: Float, stroke: Int, shape: Int)]
    private let shapes: [Shape]
    /// Dab indices by grid cell, in order.
    private let cells: [Int: [Int]]
    private let rounding: Bool
    private static let cell: Float = 1.0 / 64

    public init(_ paint: BrushPaint) { self.init(paint.strokes) }

    /// `rounding` false keeps every value in `Float`, as an `r32Float` canvas would. Strokes without Follow edges only: see
    /// `init(_:rounding:shapes:)`.
    public init(_ list: [BrushStroke], rounding: Bool = true) {
        precondition(!list.contains(where: \.followEdges), "a Follow edges stroke reads its measured shape")
        try! self.init(list, rounding: rounding, shapes: nil)
    }

    /// Any strokes, a Follow edges stroke's measured shape read from `shapes`. Refuses one that has none (`MaskCoverageError`), and a
    /// shape `shapes` does not hold (`MaskRefinerError`).
    public init(_ list: [BrushStroke], rounding: Bool = true, shapes: (any MaskSeedProvider)?) throws {
        self.rounding = rounding
        var strokes: [Stroke] = [], dabs: [(x: Float, y: Float, stroke: Int, shape: Int)] = [], cells: [Int: [Int]] = [:], held: [Shape] = []
        func register(_ id: Int, _ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) {
            for cy in Self.cellIndex(y0)...Self.cellIndex(y1) {
                for cx in Self.cellIndex(x0)...Self.cellIndex(x1) { cells[Self.key(cx, cy), default: []].append(id) }
            }
        }
        for (index, stroke) in list.enumerated() {
            let profile = BrushDabProfile(radius: stroke.radius, feather: stroke.feather)
            strokes.append(Stroke(profile: profile, flow: stroke.flow, erase: stroke.erase))
            if stroke.followEdges {
                guard let measured = stroke.measured else { throw MaskCoverageError.unmeasuredStroke }
                guard let shapes else { throw MaskRefinerError.noSeedStore }
                let raster: MaskRaster
                do { raster = try shapes.seed(for: measured.raster) } catch { throw MaskRefinerError.seedUnavailable(measured.raster.id) }
                guard raster.width == measured.raster.width, raster.height == measured.raster.height else {
                    throw MaskRefinerError.seedMismatch(measured.raster.id)
                }
                let step = measured.field.texelToPoint
                let id = dabs.count
                dabs.append((0, 0, index, held.count))
                held.append(Shape(raster: raster, x: measured.x, y: measured.y, texelToPoint: step))
                register(id, Float(measured.x) * step.x, Float(measured.y) * step.y,
                         Float(measured.x + raster.width) * step.x, Float(measured.y + raster.height) * step.y)
                continue
            }
            for dab in BrushDabPath.dabs(of: stroke) {
                let id = dabs.count
                dabs.append((dab.x, dab.y, index, -1))
                let r = profile.outer
                register(id, dab.x - r, dab.y - r, dab.x + r, dab.y + r)
            }
        }
        self.strokes = strokes; self.dabs = dabs; self.cells = cells; self.shapes = held
    }

    /// A measured shape at `q`: its texel at the slice texel `q` lies in, 0 outside it. `Float(k) * (1 / 255)`, as the kernel has it.
    private func value(of shape: Shape, at q: SIMD2<Float>) -> Float {
        let at = (q / shape.texelToPoint).rounded(.down)
        let column = Int(at.x) - shape.x, row = Int(at.y) - shape.y
        guard column >= 0, row >= 0, column < shape.raster.width, row < shape.raster.height else { return 0 }
        return Float(shape.raster.plane[row * shape.raster.width + column]) * (1 / 255 as Float)
    }

    private static func cellIndex(_ v: Float) -> Int { Int((v / cell).rounded(.down)) }
    private static func key(_ x: Int, _ y: Int) -> Int { (y + 1 << 15) << 16 | (x + 1 << 15) }

    public var dabCount: Int { dabs.count }

    /// The component's coverage at `q`, before any invert.
    public func value(at q: SIMD2<Float>) -> Float {
        guard let list = cells[Self.key(Self.cellIndex(q.x), Self.cellIndex(q.y))] else { return 0 }
        var c: Float = 0, s: Float = 0, current = -1
        for id in list {
            let dab = dabs[id]
            if dab.stroke != current {
                if current >= 0 { c = finish(c, s, current) }
                s = 0; current = dab.stroke
            }
            if dab.shape >= 0 { s = max(s, value(of: shapes[dab.shape], at: q)); continue }
            let d = SIMD2<Float>(q.x - dab.x, q.y - dab.y)
            s = max(s, strokes[dab.stroke].profile.value(distance: (d * d).sum().squareRoot()))
        }
        if current >= 0 { c = finish(c, s, current) }
        return c
    }

    private func finish(_ c: Float, _ s: Float, _ stroke: Int) -> Float {
        let item = strokes[stroke]
        return rounding ? BrushCompositing.compose(c, stroke: BrushCompositing.half(s), flow: item.flow, erase: item.erase)
            : BrushCompositing.composeUnrounded(c, stroke: s, flow: item.flow, erase: item.erase)
    }
}
