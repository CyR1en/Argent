import CryptoKit
import Foundation
import os

/// The green-channel map and framing scale on which a mask was made.
public struct LensGeometry: Sendable, Hashable, Codable {
    public let table: RadialTable
    public let scale: Double
    public let digest: String

    public init(table: RadialTable, scale: Double) throws {
        _ = try ResolvedLensCorrection(red: table, green: table, blue: table, gain: .one, status: .init(), scale: scale)
        self.init(unchecked: table, scale: scale)
    }

    init(unchecked table: RadialTable, scale: Double) {
        self.table = table
        self.scale = scale
        var bytes = Data()
        for sample in table.samples {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: scale.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.digest == rhs.digest }
    public func hash(into hasher: inout Hasher) { hasher.combine(digest) }

    private enum CodingKeys: String, CodingKey { case scale, knots }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bytes = try c.decode(Data.self, forKey: .knots)
        guard bytes.count.isMultiple(of: 4) else { throw LensCorrectionError.malformedTable }
        let knots: [Double] = bytes.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 4).map { Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))) }
        }
        try self.init(table: RadialTable(knots: knots), scale: c.decode(Double.self, forKey: .scale))
    }

    public func encode(to encoder: Encoder) throws {
        var knots = table.samples
        for n in 1...RadialTable.intervals where RadialTable.intervals.isMultiple(of: n) {
            let candidate = stride(from: 0, through: RadialTable.intervals, by: RadialTable.intervals / n).map { table.samples[$0] }
            if try RadialTable(knots: candidate.map(Double.init)).samples.map(\.bitPattern) == table.samples.map(\.bitPattern) {
                knots = candidate
                break
            }
        }
        var bytes = Data()
        for knot in knots { withUnsafeBytes(of: knot.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scale, forKey: .scale)
        try c.encode(bytes, forKey: .knots)
    }
}

public struct MaskLens: Sendable, Hashable {
    public let picture: LensGeometry
    public let legacy: LensGeometry
    public let extent: MaskPoint
    public init(picture: LensGeometry, legacy: LensGeometry, extent: MaskPoint) {
        self.picture = picture; self.legacy = legacy; self.extent = extent
    }
    public init(_ correction: ResolvedLensCorrection, extent: MaskPoint) {
        self.init(picture: correction.geometry, legacy: correction.legacy ?? correction.geometry, extent: extent)
    }
    public func toMask(_ shape: MaskShape) -> LensRemap? {
        LensRemap(from: picture, to: shape.geometry ?? legacy, extent: extent)
    }
    public func toPicture(_ shape: MaskShape) -> LensRemap? {
        LensRemap(from: shape.geometry ?? legacy, to: picture, extent: extent)
    }
}

/// The shared CPU map; shaders only interpolate its ratio table.
public struct LensRemap: Sendable, Hashable {
    public let from: LensGeometry
    public let to: LensGeometry
    public let extent: MaskPoint
    public let ratio: [Float]
    private static let tables = OSAllocatedUnfairLock(initialState: [String: [Float]]())

    public init?(from: LensGeometry, to: LensGeometry, extent: MaskPoint) {
        guard from != to else { return nil }
        self.from = from; self.to = to; self.extent = extent
        ratio = Self.tables.withLock { tables in
            let key = from.digest + to.digest
            if let held = tables[key] { return held }
            let made = (0...RadialTable.intervals).map { i -> Float in
                let t = Double(i) / Double(RadialTable.intervals)
                if i == 0 { return Float((from.table.value(at: 0) / from.scale) / (to.table.value(at: 0) / to.scale)) }
                let rho = t * from.table.value(at: t) / from.scale
                var low = 0.0, high = 16.0
                for _ in 0..<40 {
                    let mid = (low + high) / 2
                    if mid * to.table.value(at: mid) / to.scale < rho { low = mid } else { high = mid }
                }
                return Float((low + high) / (2 * t))
            }
            if tables.count >= 8 { tables.removeAll() }
            tables[key] = made
            return made
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.from == rhs.from && lhs.to == rhs.to && lhs.extent == rhs.extent }
    public func hash(into hasher: inout Hasher) { hasher.combine(from); hasher.combine(to); hasher.combine(extent) }
    public func ratio(at p: MaskPoint) -> Float {
        let dx = p.x - extent.x / 2, dy = p.y - extent.y / 2
        let x = min(hypot(dx, dy) / (hypot(extent.x, extent.y) / 2), 1) * Float(RadialTable.intervals)
        let i = min(Int(x), RadialTable.intervals - 1)
        return ratio[i] + (ratio[i + 1] - ratio[i]) * (x - Float(i))
    }
    public func point(_ p: MaskPoint) -> MaskPoint {
        let r = ratio(at: p)
        return MaskPoint(x: extent.x / 2 + (p.x - extent.x / 2) * r, y: extent.y / 2 + (p.y - extent.y / 2) * r)
    }
    public var reach: Float { ratio.map { abs($0 - 1) }.max()! }
}

extension MaskShape {
    public var geometry: LensGeometry? {
        switch self {
        case .linear(let g): g.geometry
        case .radial(let g): g.geometry
        case .brush(let p): p.frame.geometry
        case .smart(let s): s.frame?.geometry
        }
    }
    public func stamped(_ geometry: LensGeometry?) -> MaskShape {
        switch self {
        case .linear(var g): g.geometry = geometry; return .linear(g)
        case .radial(var g): g.geometry = geometry; return .radial(g)
        case .brush(var p): p.frame.geometry = geometry; return .brush(p)
        case .smart: return self
        }
    }
    public func moved(in lens: MaskLens, remeasure: (MeasuredStroke, LensRemap) throws -> MeasuredStroke) rethrows -> MaskShape {
        guard let r = lens.toPicture(self) else { return stamped(lens.picture) }
        func clamped(_ p: MaskPoint, to range: ClosedRange<Float> = MaskSpace.coordinateRange) -> MaskPoint {
            MaskPoint(x: min(max(p.x, range.lowerBound), range.upperBound), y: min(max(p.y, range.lowerBound), range.upperBound))
        }
        let moved: MaskShape
        switch self {
        case .linear(var g):
            g.full = clamped(r.point(g.full)); g.zero = clamped(r.point(g.zero)); moved = .linear(g)
        case .radial(var g):
            let c = r.point(g.center), cosine = cos(g.angle), sine = sin(g.angle)
            let a = r.point(MaskPoint(x: g.center.x + g.semiAxisA * cosine, y: g.center.y + g.semiAxisA * sine))
            let b = r.point(MaskPoint(x: g.center.x - g.semiAxisB * sine, y: g.center.y + g.semiAxisB * cosine))
            g.center = c
            g.semiAxisA = min(max(hypot(a.x - c.x, a.y - c.y), MaskSpace.minimumExtent), MaskSpace.coordinateRange.upperBound)
            g.semiAxisB = min(max(hypot(b.x - c.x, b.y - c.y), MaskSpace.minimumExtent), MaskSpace.coordinateRange.upperBound)
            g.angle = atan2(a.y - c.y, a.x - c.x)
            moved = .radial(g)
        case .brush(var paint):
            for i in paint.strokes.indices {
                var stroke = paint.strokes[i]
                let points = stroke.points.points
                let mean = points.reduce(Float(0)) { $0 + r.ratio(at: $1) } / Float(points.count)
                stroke.radius = min(max(stroke.radius * mean, MaskSpace.brushRadiusRange.lowerBound), MaskSpace.brushRadiusRange.upperBound)
                stroke.points = try! PackedPoints.pack(points.map { clamped(r.point($0), to: MaskSpace.brushCoordinateRange) })
                if let measured = stroke.measured { stroke.measured = try remeasure(measured, lens.toMask(self)!) }
                paint.strokes[i] = stroke
            }
            moved = .brush(paint)
        case .smart: return self
        }
        return moved.stamped(lens.picture)
    }
}

extension MeasuredStroke {
    public func moved(_ raster: MaskRaster, by toMask: LensRemap) throws -> (measured: MeasuredStroke, raster: MaskRaster) {
        let field = self.field
        let grow = Int(ceil(toMask.reach * hypot(Float(field.width), Float(field.height)) / 2)) + 1
        let left = max(0, x - grow), top = max(0, y - grow)
        let right = min(field.width, x + raster.width + grow), bottom = min(field.height, y + raster.height + grow)
        let step = field.texelToPoint
        func value(_ i: Int, _ j: Int) -> Float {
            guard (0..<raster.width).contains(i), (0..<raster.height).contains(j) else { return 0 }
            return Float(raster.plane[j * raster.width + i])
        }
        var plane = [UInt8](); plane.reserveCapacity((right - left) * (bottom - top))
        for j in top..<bottom {
            for i in left..<right {
                let p = toMask.point(field.point(column: i, yTop: j))
                let u = p.x / step.x - 0.5 - Float(x), v = p.y / step.y - 0.5 - Float(y)
                let a = Int(floor(u)), b = Int(floor(v)), s = u - Float(a), t = v - Float(b)
                let upper = value(a, b) * (1 - s) + value(a + 1, b) * s
                let lower = value(a, b + 1) * (1 - s) + value(a + 1, b + 1) * s
                plane.append(UInt8(min(max((upper * (1 - t) + lower * t).rounded(), 0), 255)))
            }
        }
        let made = try MaskRaster(width: right - left, height: bottom - top, plane: plane)
        return (try MeasuredStroke(raster: made.ref, x: left, y: top, pictureWidth: pictureWidth, pictureHeight: pictureHeight), made)
    }
}

extension LinearFrame {
    public var maskLens: MaskLens? { lens.map { MaskLens($0, extent: try! maskPicture.extent) } }
}
