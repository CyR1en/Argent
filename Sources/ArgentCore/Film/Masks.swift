import CryptoKit
import Foundation

// Masks in the data model: local adjustments, each a *where* (`Mask.components`) and a *what* (`Mask.adjustments`, `Mask.amount`).
//
// They sit in `ManualAdjustments.masks`, beside `curves`, so every site that asks `adjustments.isIdentity` (Edited, the dot,
// Develop again, pin release, Compare to Auto, the render slot, `RenderGraph.version`) is right with no change of its own.
// They hold only what a render reads. A mask's name and a seed's provenance are not pixels, and live in `ManualEdit.maskNotes`.
// A set compares by a digest of bytes written by hand, so a develop receipt can carry the digest alone and still compare equal.

public enum MaskError: Error, Sendable, LocalizedError, Equatable, CustomStringConvertible {
    case invalid(String)
    /// A `masks.schema` newer than this build: it may hold what this build would drop, so the read fails and the record is kept.
    case unsupportedSchema(Int)
    case unsupportedVersion(String)
    /// An edit on this Light compiler cannot take masks: it has no gain tables for their tone controls.
    case lightCompiler(String)
    case digestOnly

    public var errorDescription: String? {
        switch self {
        case .invalid(let why): return "These masks are not valid: \(why)."
        case .unsupportedSchema(let schema): return "These masks use schema \(schema), which this build does not read; they have been preserved."
        case .unsupportedVersion(let version): return "Masks compiler \(version) is unavailable. Update Automatic Baseline to continue."
        case .lightCompiler(let version): return "An edit on Light compiler \(version) cannot use masks. Update Automatic Baseline to continue."
        case .digestOnly: return "A develop receipt holds only a digest of its masks and cannot be rendered."
        }
    }
    /// A develop reports `"\(frame): \(error)"`, so the reason reads the same there.
    public var description: String { errorDescription ?? "These masks cannot be used." }
}

/// A point in `MaskSpace`: long-side units, from the upright picture's top left, y down. Positions may lie outside the picture.
public struct MaskPoint: Sendable, Equatable, Hashable, Codable {
    public var x: Float
    public var y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}

/// Where every mask position and size lives. A picture whose long side is L pixels covers `[0, W/L] × [0, H/L]`, with a pixel's
/// centre at `((x + 0.5)/L, (yTop + 0.5)/L)`, so a circle stays a circle at any render size and a size is a share of the long side.
/// It needs no rotation, since the decode is already upright. A frame texture holds the picture's bottom row in row 0, so the flip
/// happens once, at upload and download (`textureRow`), and shaders work in this space.
public struct MaskSpace: Sendable, Equatable, Hashable {
    /// How far outside a picture a position may lie, in long sides: far enough for any handle, and small enough that the squares
    /// a gradient's evaluation takes stay finite in `Float`.
    public static let coordinateRange: ClosedRange<Float> = -16...16
    /// The narrowest gradient span or semi-axis, 1/65536 of the long side (about a tenth of a pixel at 7008): below it the
    /// evaluation's division has no meaning, and its square would approach `Float`'s floor.
    public static let minimumExtent: Float = 1.0 / 65_536
    /// A brush dab's radius, in long sides (R8's constant 12).
    public static let brushRadiusRange: ClosedRange<Float> = 0.001...0.2
    /// Where a brush point may lie, in long sides: a dab's centre may leave the picture while its edge still paints.
    public static let brushCoordinateRange: ClosedRange<Float> = -1...2
    /// Brush points are quantized to 1/32768 of the long side, about 0.2 px at 7008 (R6).
    public static let brushPointsPerLongSide = 32_768

    public let width: Int
    public let height: Int

    /// The upright picture's size in pixels, either render's: a mask's positions do not depend on it.
    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw MaskError.invalid("a picture has a size") }
        self.width = width
        self.height = height
    }

    public var longSide: Int { max(width, height) }
    /// The picture's bottom right corner: `(W/L, H/L)`.
    public var extent: MaskPoint { MaskPoint(x: Float(width) / Float(longSide), y: Float(height) / Float(longSide)) }
    /// The centre of the pixel at `column`, `yTop` rows from the picture's top.
    public func point(column: Int, yTop: Int) -> MaskPoint {
        MaskPoint(x: (Float(column) + 0.5) / Float(longSide), y: (Float(yTop) + 0.5) / Float(longSide))
    }
    /// The texture row holding the picture's row `yTop`.
    public func textureRow(yTop: Int) -> Int { height - 1 - yTop }
}

/// What a brush or a smart seed was made on. Its geometry lets the renderer map into the picture on which it was made.
/// The other fields describe that picture and never cause a refusal: positions and rasters cover the whole upright frame whatever decoded it. RAW 8 and RAW 9
/// align to 0.06 px and the in-house route differs up to 7.6 px, which a seed's refinement re-snaps; a flip of lens correction moves
/// frames 9 to 93 px, and a different orientation or size is a different picture, so those are the mismatches worth a word.
public struct MaskFrame: Sendable, Equatable, Hashable, Codable {
    /// Exif orientation, 1 to 8; the decode is already upright, so this only tells a frame apart.
    public let orientation: Int
    /// The decoded picture's upright size in pixels at full resolution.
    public let width: Int
    public let height: Int
    public let decoder: DecoderChoice
    public let lensCorrection: Bool
    public var geometry: LensGeometry?

    public init(orientation: Int, width: Int, height: Int, decoder: DecoderChoice, lensCorrection: Bool, geometry: LensGeometry? = nil) throws {
        guard (1...8).contains(orientation) else { throw MaskError.invalid("an orientation is 1 to 8") }
        guard width > 0, height > 0 else { throw MaskError.invalid("a frame has a size") }
        self.orientation = orientation; self.width = width; self.height = height
        self.decoder = decoder; self.lensCorrection = lensCorrection; self.geometry = geometry
    }

    private enum CodingKeys: String, CodingKey { case orientation, width, height, decoder, lensCorrection, geometry }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(orientation: c.decode(Int.self, forKey: .orientation), width: c.decode(Int.self, forKey: .width),
                      height: c.decode(Int.self, forKey: .height), decoder: c.decode(DecoderChoice.self, forKey: .decoder),
                      lensCorrection: c.decode(Bool.self, forKey: .lensCorrection), geometry: c.decodeIfPresent(LensGeometry.self, forKey: .geometry))
    }
}

/// SHA-256 of a raster's canonical bytes (`MaskRaster.identity`), 64 lowercase hex digits.
public struct RasterID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let hex: String
    public init?(hex: String) {
        guard hex.count == 64, hex.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else { return nil }
        self.hex = hex
    }
    public var description: String { hex }
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = RasterID(hex: text) else { throw MaskError.invalid("a raster id is 64 lowercase hex digits") }
        self = id
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A smart mask's pinned output: 8-bit coverage over the whole upright frame, 0 outside and 255 inside, at its own width and
/// height, which need not share the frame's aspect (Vision's person mask is 4:3 for a 3:2 frame; it is stretched to fit).
public struct RasterRef: Sendable, Equatable, Hashable, Codable {
    /// Seeds are stored at the model's own size, capped at 4096 (plan section 7).
    public static let sideRange = 16...4096
    public let id: RasterID
    public let width: Int
    public let height: Int
    public init(id: RasterID, width: Int, height: Int) throws {
        guard Self.sideRange.contains(width), Self.sideRange.contains(height) else {
            throw MaskError.invalid("a raster's sides are \(Self.sideRange.lowerBound) to \(Self.sideRange.upperBound) pixels")
        }
        self.id = id; self.width = width; self.height = height
    }
    private enum CodingKeys: String, CodingKey { case id, width, height }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(RasterID.self, forKey: .id), width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height))
    }
}

/// The pixels a `RasterRef` names.
public struct MaskRaster: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let plane: [UInt8]
    public init(width: Int, height: Int, plane: [UInt8]) throws {
        guard RasterRef.sideRange.contains(width), RasterRef.sideRange.contains(height), plane.count == width * height else {
            throw MaskError.invalid("a raster is width times height bytes")
        }
        self.width = width; self.height = height; self.plane = plane
    }
    /// What names these pixels, whatever file format keeps them: SHA-256 of a marker, both sides and the plane.
    public var identity: RasterID {
        var hash = SHA256()
        hash.update(data: Data("ARGENT-MASK-1\n".utf8))
        for side in [UInt32(width), UInt32(height)] { withUnsafeBytes(of: side.littleEndian) { hash.update(bufferPointer: $0) } }
        plane.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return RasterID(hex: MaskSet.hex(hash.finalize()))!
    }
    public var ref: RasterRef { try! RasterRef(id: identity, width: width, height: height) }
}

public enum SmartKind: String, Sendable, Codable, CaseIterable {
    case sky, subject, person, background

    /// Whether a click can give this kind a `crisp` or `matte` edge: Subject and Background, its inverse.
    public var takesLearnedEdge: Bool { self == .subject || self == .background }
}

public enum MaskOperation: String, Sendable, Codable, CaseIterable { case add, subtract, intersect }

/// A brush stroke's points, in `MaskSpace` quantized to `MaskSpace.brushPointsPerLongSide`, each as a zigzag varint of its difference
/// from the last, in one base64 string. An array of point objects costs 88 bytes a point, since the recipe's pretty printer spreads
/// each over five lines, and this form under 10 (measured with a third value for pressure, which strokes no longer carry: R6 4.5).
public struct PackedPoints: Sendable, Equatable, Hashable, Codable {
    public let bytes: Data
    public let count: Int

    public static func pack(_ points: [MaskPoint]) throws -> PackedPoints {
        var out = [UInt8](), last = SIMD2<Int>(0, 0)
        out.reserveCapacity(points.count * 3)
        func put(_ v: Int) {
            var u = UInt64(bitPattern: Int64((v << 1) ^ (v >> 63)))
            while u >= 0x80 { out.append(UInt8(u & 0x7f) | 0x80); u >>= 7 }
            out.append(UInt8(u))
        }
        for point in points {
            guard MaskSpace.brushCoordinateRange.contains(point.x), MaskSpace.brushCoordinateRange.contains(point.y) else {
                throw MaskError.invalid("a brush point is in \(MaskSpace.brushCoordinateRange) long sides")
            }
            let q = SIMD2<Int>(Int((point.x * Float(MaskSpace.brushPointsPerLongSide)).rounded()),
                               Int((point.y * Float(MaskSpace.brushPointsPerLongSide)).rounded()))
            put(q.x - last.x); put(q.y - last.y)
            last = q
        }
        return PackedPoints(bytes: Data(out), count: points.count)
    }

    private init(bytes: Data, count: Int) { self.bytes = bytes; self.count = count }

    /// The points, each exact as it was packed once it is on the quantized grid. Both ways to a value checked its bytes.
    public var points: [MaskPoint] { try! Self.read(bytes, count: count) }

    /// Reads `count` points and every byte after them, refusing what a pack could not have written, so one list of points has one
    /// byte string and so one digest.
    private static func read(_ bytes: Data, count: Int) throws -> [MaskPoint] {
        guard count >= 0 else { throw MaskError.invalid("a brush stroke has a count of points") }
        var result: [MaskPoint] = [], index = bytes.startIndex, last = SIMD2<Int>(0, 0)
        func take() throws -> Int {
            var shift = 0, value: UInt64 = 0
            while true {
                guard index < bytes.endIndex, shift < 35 else { throw MaskError.invalid("a brush stroke's points are cut short") }
                let byte = bytes[index]; index += 1
                value |= UInt64(byte & 0x7f) << UInt64(shift)
                if byte & 0x80 == 0 {
                    guard byte != 0 || shift == 0 else { throw MaskError.invalid("a brush stroke's points are not canonical") }
                    break
                }
                shift += 7
            }
            return Int(Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1))
        }
        let scale = Float(MaskSpace.brushPointsPerLongSide)
        let lowest = Int(MaskSpace.brushCoordinateRange.lowerBound * scale), highest = Int(MaskSpace.brushCoordinateRange.upperBound * scale)
        for _ in 0..<count {
            last.x += try take(); last.y += try take()
            guard (lowest...highest).contains(last.x), (lowest...highest).contains(last.y) else {
                throw MaskError.invalid("a brush point is in \(MaskSpace.brushCoordinateRange) long sides")
            }
            result.append(MaskPoint(x: Float(last.x) / scale, y: Float(last.y) / scale))
        }
        guard index == bytes.endIndex else { throw MaskError.invalid("a brush stroke has bytes past its points") }
        return result
    }

    private enum CodingKeys: String, CodingKey { case points, count }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytes = try c.decode(Data.self, forKey: .points)
        count = try c.decode(Int.self, forKey: .count)
        _ = try Self.read(bytes, count: count)   // a stroke that cannot be read fails the record, which is then preserved
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bytes, forKey: .points)
        try c.encode(count, forKey: .count)
    }
}

/// What a Follow edges stroke measured as it ended (task L): its shape, its dabs held to the colour under each dab's centre and then refined
/// to the picture's edges on the untouched decode (`FollowEdgesModel`), as an 8-bit raster of the part of the slice it reaches. Every
/// render reads this shape as the stroke's own, in place of its dabs, so no render measures again: the print, the previews and every
/// develop read one shape, whatever decode each has, and a change of the measurement's constants moves no stroke already made.
///
/// The raster's texel (i, j) is the slice texel (`x + i`, `y + j`) from the top left of the slice of the full-size picture
/// `pictureWidth` by `pictureHeight` it was measured over (`MaskFieldSize(picture:)`); on that picture's slice it is read texel for texel.
/// A picture whose slice differs (a copy to a frame of another shape) reads it by the point of `MaskSpace` each texel covers.
public struct MeasuredStroke: Sendable, Equatable, Hashable, Codable {
    public let raster: RasterRef
    public let x: Int
    public let y: Int
    public let pictureWidth: Int
    public let pictureHeight: Int

    /// Refuses a raster that does not lie inside the slice it was measured on.
    public init(raster: RasterRef, x: Int, y: Int, pictureWidth: Int, pictureHeight: Int) throws {
        guard pictureWidth > 0, pictureHeight > 0, x >= 0, y >= 0 else { throw MaskError.invalid("a measured stroke lies on its picture") }
        let field = MaskFieldSize(picture: try MaskSpace(width: pictureWidth, height: pictureHeight))
        // By subtraction: a slice and a raster are a few thousand texels a side, so these cannot overflow, as `x + raster.width`
        // would on a record that names an `x` near `Int.max`, and the read would trap where it should refuse.
        guard x <= field.width - raster.width, y <= field.height - raster.height else {
            throw MaskError.invalid("a measured stroke lies inside the slice it was measured on")
        }
        self.raster = raster; self.x = x; self.y = y; self.pictureWidth = pictureWidth; self.pictureHeight = pictureHeight
    }

    /// The slice it was measured over.
    public var field: MaskFieldSize { MaskFieldSize(picture: try! MaskSpace(width: pictureWidth, height: pictureHeight)) }

    private enum CodingKeys: String, CodingKey { case raster, x, y, pictureWidth, pictureHeight }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(raster: c.decode(RasterRef.self, forKey: .raster), x: c.decode(Int.self, forKey: .x), y: c.decode(Int.self, forKey: .y),
                      pictureWidth: c.decode(Int.self, forKey: .pictureWidth), pictureHeight: c.decode(Int.self, forKey: .pictureHeight))
    }
}

/// One stroke, in order, with no pressure: the owner paints on a trackpad, so radius and flow hold for the whole stroke.
public struct BrushStroke: Sendable, Equatable, Hashable, Codable {
    public var erase: Bool
    /// Follow edges (Lightroom's Auto Mask): the stroke keeps to the colours under its dabs' centres and snaps to the picture's edges as it
    /// ends. What it measured then is `measured`, which every render reads; one without it (none is ever written: a stroke in progress
    /// has none until it ends) cannot be baked and refuses.
    public var followEdges: Bool
    /// The dab's radius, in long sides (`MaskSpace.brushRadiusRange`).
    public var radius: Float
    /// 0 to 1: the share of the radius the dab's edge falls over; `flow` 0 to 1: how much one dab lays down.
    public var feather: Float
    public var flow: Float
    public var points: PackedPoints
    /// A Follow edges stroke's shape as it measured it (masks schema 3); `nil` for any other stroke, which then writes what it always did.
    public var measured: MeasuredStroke?
    public init(erase: Bool = false, followEdges: Bool = false, radius: Float, feather: Float = 0.5, flow: Float = 1, points: PackedPoints,
                measured: MeasuredStroke? = nil) {
        self.erase = erase; self.followEdges = followEdges; self.radius = radius
        self.feather = feather; self.flow = flow; self.points = points; self.measured = measured
    }
}

/// A brush component: its strokes in the order they were painted, and the frame they were painted on.
public struct BrushPaint: Sendable, Equatable, Hashable, Codable {
    public var frame: MaskFrame
    public var strokes: [BrushStroke]
    public init(frame: MaskFrame, strokes: [BrushStroke] = []) { self.frame = frame; self.strokes = strokes }
}

/// Which edge a selection's coverage takes, decided once, at the click, and stored: no later render asks the rule again.
/// `guided` is today's path (Person, Sky and every selection already in a record); `crisp` is the 1024 S3OD seed with V7's frozen filter
/// and contrast; `matte` is ViTMatte's alpha at the click print's size, stored as the raster, with no filter.
public enum SmartEdge: String, Codable, Sendable { case guided, crisp, matte }

/// A smart mask's seed. `raster` and `frame` come together: `nil` until the selection has been made; a mask with none has no
/// coverage, and the frame cannot be developed. `feather` softens the refined edge (decision 19, `MaskFeather`): 0, the default, is the
/// edge as refined, and a selection at 0 is the same record, digest and pixels as one made before Feather existed.
public struct SmartSelection: Sendable, Equatable, Hashable, Codable {
    /// Lightroom's scale for an AI mask's Feather, the radial's: 0 to 100.
    public static let featherRange: ClosedRange<Float> = 0...100

    public var kind: SmartKind
    public var raster: RasterRef?
    public var frame: MaskFrame?
    /// How far the refined coverage is blurred, 0 to 100. It is the user's, not the model's: it stays through an Update, a seed that
    /// lands for a pending selection, and Copy to another frame.
    public var feather: Float
    /// Which edge this selection's raster takes. `.guided`, the default, is not written, so every selection that exists keeps its bytes.
    public var edge: SmartEdge
    public init(kind: SmartKind, raster: RasterRef? = nil, frame: MaskFrame? = nil, feather: Float = 0, edge: SmartEdge = .guided) {
        self.kind = kind; self.raster = raster; self.frame = frame; self.feather = feather; self.edge = edge
    }

    // What the synthesized coding wrote, with `feather` and `edge` only when they are set, so a selection without them keeps its bytes.
    private enum CodingKeys: String, CodingKey { case kind, raster, frame, feather, edge }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SmartKind.self, forKey: .kind)
        raster = try c.decodeIfPresent(RasterRef.self, forKey: .raster)
        frame = try c.decodeIfPresent(MaskFrame.self, forKey: .frame)
        feather = try c.decodeIfPresent(Float.self, forKey: .feather) ?? 0
        edge = try c.decodeIfPresent(SmartEdge.self, forKey: .edge) ?? .guided
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(raster, forKey: .raster)
        try c.encodeIfPresent(frame, forKey: .frame)
        if feather != 0 { try c.encode(feather, forKey: .feather) }
        if edge != .guided { try c.encode(edge, forKey: .edge) }
    }
}

/// What a component selects. Range masks are not here: schema 1 has none, and adding them bumps `MaskSet.schema`.
public enum MaskShape: Sendable, Equatable, Hashable {
    /// Coverage falls from 1 at `full` to 0 at `zero`, measured perpendicular to the line between them, on a fixed profile that is
    /// scale-free in that span, so a linear gradient has no feather (plan section 6). Nested so it does not clash with SwiftUI's.
    public struct LinearGradient: Sendable, Equatable, Hashable, Codable {
        public var full: MaskPoint
        public var zero: MaskPoint
        public var geometry: LensGeometry?
        public init(full: MaskPoint, zero: MaskPoint, geometry: LensGeometry? = nil) {
            self.full = full; self.zero = zero; self.geometry = geometry
        }
    }

    /// The true ellipse Argent stores and draws: elliptical radius 1 on the outline (plan section 6). `semiAxisA` lies along `angle`,
    /// `semiAxisB` along `angle` + 90°, both in long sides; `angle` is in radians from +x toward +y, so clockwise on the picture.
    /// `feather` is on Lightroom's scale, 0 to 100, on which the coverage constants were measured.
    public struct RadialGradient: Sendable, Equatable, Hashable, Codable {
        public static let featherRange: ClosedRange<Float> = 0...100
        public var center: MaskPoint
        public var semiAxisA: Float
        public var semiAxisB: Float
        public var angle: Float
        public var feather: Float
        public var geometry: LensGeometry?
        public init(center: MaskPoint, semiAxisA: Float, semiAxisB: Float, angle: Float = 0, feather: Float = 50, geometry: LensGeometry? = nil) {
            self.center = center; self.semiAxisA = semiAxisA; self.semiAxisB = semiAxisB
            self.angle = angle; self.feather = feather; self.geometry = geometry
        }
    }

    case linear(LinearGradient)
    case radial(RadialGradient)
    case brush(BrushPaint)
    case smart(SmartSelection)

    /// The frame a brush was painted on or a smart seed was made on, to compare with the frame's own; `nil` for a gradient, whose
    /// positions need none, and for a selection not made yet.
    public var frame: MaskFrame? {
        switch self {
        case .linear, .radial: return nil
        case .brush(let paint): return paint.frame
        case .smart(let selection): return selection.frame
        }
    }
}

extension MaskShape: Codable {
    private enum CodingKeys: String, CodingKey { case type, linear, radial, brush, smart }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "linear": self = .linear(try c.decode(LinearGradient.self, forKey: .linear))
        case "radial": self = .radial(try c.decode(RadialGradient.self, forKey: .radial))
        case "brush": self = .brush(try c.decode(BrushPaint.self, forKey: .brush))
        case "smart": self = .smart(try c.decode(SmartSelection.self, forKey: .smart))
        // A kind this build does not know fails the read, so the record is preserved and never read as a mask without it.
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown mask shape \(other)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear(let shape): try c.encode("linear", forKey: .type); try c.encode(shape, forKey: .linear)
        case .radial(let shape): try c.encode("radial", forKey: .type); try c.encode(shape, forKey: .radial)
        case .brush(let shape): try c.encode("brush", forKey: .type); try c.encode(shape, forKey: .brush)
        case .smart(let shape): try c.encode("smart", forKey: .type); try c.encode(shape, forKey: .smart)
        }
    }
}

/// One part of a mask's where. `invert` is the component's, not the mask's, because what it means depends on the shape: a linear
/// gradient's swaps Full and Zero, `profile(1 − t)`, which is not `1 − v` since that profile is asymmetric, and any other shape's is
/// `1 − v` (plan section 6). The panel's Invert toggles the selected component.
public struct MaskComponent: Sendable, Equatable, Hashable, Codable {
    public var operation: MaskOperation
    public var shape: MaskShape
    public var invert: Bool
    public init(operation: MaskOperation = .add, shape: MaskShape, invert: Bool = false) {
        self.operation = operation; self.shape = shape; self.invert = invert
    }
}

/// A mask's print balance: enlarger filtration for its own pixels, the same move as the frame's Lab balance, so the colour still goes
/// through the stock's paper. Each is -100 to 100 and 0 is no change. It sits beside `adjustments`, not in it, since it is no Light control:
/// a Light control scales the scene's light, and this shifts the paper's exposure channel by channel.
public struct MaskBalance: Sendable, Equatable, Hashable, Codable {
    public static let range: ClosedRange<Float> = -100...100
    public static let neutral = MaskBalance()
    /// How far the masks' summed slider may go at any pixel: Amount runs to 2 and masks overlap, and this holds a stack to twice one full slider.
    public static let sumLimit: Float = 200
    /// Paper stops per channel, red, green, blue, for one unit of each slider. 100 on Warmth is the 60 mired Auto's lab balance may
    /// move, three of Lab balance's Warm steps (`RollControls.LabBalance.stepPaperStops`, 0.062 stops of red against blue each way for 20 mired).
    /// 100 on Magenta spans half that between green and the other two, the bound Auto keeps for green. To be judged on real rolls.
    public static let warmthAxis = SIMD3<Float>(1, 0, -1) * (0.186 / 100)
    public static let magentaAxis = SIMD3<Float>(0.5, -1, 0.5) * (0.124 / 100)

    public var warmth: Float
    public var magenta: Float

    public var isNeutral: Bool { warmth == 0 && magenta == 0 }

    public init(warmth: Float = 0, magenta: Float = 0) {
        self.warmth = warmth; self.magenta = magenta
    }
}

/// One mask: where (`components`, combined in order) and what (`adjustments` and `balance`, scaled by `amount`). `components` is the only part
/// coverage depends on, so a slider on a mask never rebuilds a coverage field (`coverage`).
public struct Mask: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Lightroom's mask Amount, 0 to 200 % as shown (plan decision 15). It multiplies every slider, and the product is not capped.
    public static let amountRange: ClosedRange<Float> = 0...2

    public let id: UUID
    public var isEnabled: Bool
    public var components: [MaskComponent]
    /// Stored 0 to 2, default 1. Amount 0 changes no pixel and keeps the mask.
    public var amount: Float
    /// The six Light values for the mask's own pixels. They take the frame's pinned reference. No masks and no curves in schema 1.
    public var adjustments: ManualAdjustments
    /// The print balance for the mask's own pixels. Written only when it is not neutral (masks schema 5).
    public var balance: MaskBalance

    public init(id: UUID = UUID(), isEnabled: Bool = true, components: [MaskComponent], amount: Float = 1,
                adjustments: ManualAdjustments = .identity, balance: MaskBalance = .neutral) {
        self.id = id; self.isEnabled = isEnabled; self.components = components
        self.amount = amount; self.adjustments = adjustments; self.balance = balance
    }

    private enum CodingKeys: String, CodingKey { case id, isEnabled, components, amount, adjustments, balance }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        components = try c.decode([MaskComponent].self, forKey: .components)
        amount = try c.decode(Float.self, forKey: .amount)
        adjustments = try c.decode(ManualAdjustments.self, forKey: .adjustments)
        balance = try c.decodeIfPresent(MaskBalance.self, forKey: .balance) ?? .neutral
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(isEnabled, forKey: .isEnabled); try c.encode(components, forKey: .components)
        try c.encode(amount, forKey: .amount); try c.encode(adjustments, forKey: .adjustments)
        // A mask with no balance is written as before it existed.
        if !balance.isNeutral { try c.encode(balance, forKey: .balance) }
    }

    /// What this mask adds to a pixel's summed slider where its coverage is 1: Amount × the slider, in stops for Exposure, and 0 for a
    /// mask turned off. The render law's `Ak·Vk,X` (plan section 4).
    public func scaledValue(for control: ManualAdjustments.Control) -> Float {
        isEnabled ? amount * adjustments.value(for: control) : 0
    }

    /// What this mask adds to a pixel's summed Warmth and Magenta where its coverage is 1, by the render law's `Ak·Vk`; 0 for a mask turned off.
    public var scaledBalance: MaskBalance {
        isEnabled ? MaskBalance(warmth: amount * balance.warmth, magenta: amount * balance.magenta) : .neutral
    }

    /// This mask under another id and everything else its own. A copy is made here, beside the fields, so that what a copy keeps cannot fall
    /// behind what a mask holds (Duplicate Mask once listed them itself and left out the balance).
    public func copy(id: UUID = UUID()) -> Mask {
        Mask(id: id, isEnabled: isEnabled, components: components, amount: amount, adjustments: adjustments, balance: balance)
    }

    /// Everything a coverage field is made from: the part no slider, Amount, on/off or rename can change. It holds neither the
    /// picture nor the compiler, so a field's cache key adds those: see `coverage`.
    public struct Coverage: Sendable, Equatable, Hashable {
        public var components: [MaskComponent]
    }
    /// The field's cache key, with the picture it is baked for and `MaskSet.version`.
    public var coverage: Coverage { Coverage(components: components) }

    /// The points its brushes' strokes hold, of the `MaskSet.maximumBrushPoints` a mask may: what a stroke's budget and the row
    /// that says a brush is full both count.
    public var brushPointCount: Int {
        components.reduce(0) { total, component in
            guard case .brush(let paint) = component.shape else { return total }
            return total + paint.strokes.reduce(0) { $0 + $1.points.count }
        }
    }

    /// The smart selections without a raster.
    public var pendingSmart: [SmartKind] {
        components.compactMap { if case .smart(let selection) = $0.shape, selection.raster == nil { return selection.kind } else { return nil } }
    }
}

/// A frame's masks, in list order, with the version of the compiler that turns them into pixels.
///
/// Equality, hashing and the render fingerprint are the digest of `canonicalBytes`, which is written by hand and so does not move
/// with an encoder: SHA-256 of the version and every field of every mask in order. A develop receipt keeps the digest and the count
/// alone (`digestOnly`), which compares equal to the set it came from and cannot be rendered.
public struct MaskSet: Sendable, Equatable, Hashable, Codable {
    /// The newest schema this build reads. Anything an older reader would drop (a field, shape, kind or operation) bumps it, so that
    /// reader fails and keeps the record. 2 adds a smart selection's `feather`; 3 a Follow edges stroke's `measured` shape; 4 a smart
    /// selection's `edge` other than `guided`; 5 a mask's `balance`; 6 a shape's `geometry`. A record is written at the schema it needs (`schema(of:)`), so a set with none of them is
    /// schema 1 byte for byte, and a build from before Feather reads it; a set with a feather and no measured stroke is schema 2, which a
    /// build from before Follow edges reads; a set with no `crisp` or `matte` selection is what a build from before them wrote and reads.
    public static let schema = 6

    /// The schema a record of `masks` needs: 6 where a shape records a geometry, 5 where a mask has a balance, 4 where a smart selection has an edge other than `guided`, 3 where a brush stroke keeps a
    /// measured shape, 2 where a smart selection has a feather, 1 otherwise.
    public static func schema(of masks: [Mask]) -> Int {
        let components = masks.flatMap(\.components)
        if components.contains(where: { $0.shape.geometry != nil }) { return 6 }
        if masks.contains(where: { !$0.balance.isNeutral }) { return 5 }
        let edged = components.contains { if case .smart(let selection) = $0.shape { return selection.edge != .guided } else { return false } }
        if edged { return 4 }
        let measured = components.contains { if case .brush(let paint) = $0.shape { return paint.strokes.contains { $0.measured != nil } } else { return false } }
        if measured { return 3 }
        let feathered = components.contains { if case .smart(let selection) = $0.shape { return selection.feather != 0 } else { return false } }
        return feathered ? 2 : 1
    }
    /// How coverage and the local adjustments are computed from the definitions: a new rule is a new version, and a recipe keeps the
    /// one it recorded, as the Light and curve compilers are kept.
    public static let currentVersion = "2026-11-06-1"
    public static let maximumMasks = 16
    public static let maximumComponents = 16
    /// Brush points in one mask, about 130 KB packed: past it a Flatten step bakes them to a raster, no larger (R6 4.5).
    public static let maximumBrushPoints = 16_384

    public static let empty = MaskSet()

    public let masks: [Mask]
    public let version: String
    private let digestHex: String
    /// The count of a digest-only set.
    private let held: Int

    public var isEmpty: Bool { masks.isEmpty && held == 0 }
    public var count: Int { masks.isEmpty ? held : masks.count }
    public var digest: String { digestHex }
    public var isDigestOnly: Bool { masks.isEmpty && held > 0 }

    private init() { masks = []; version = Self.currentVersion; digestHex = ""; held = 0 }

    public init(masks: [Mask], version: String = MaskSet.currentVersion) throws {
        guard Self.supports(version: version) else { throw MaskError.unsupportedVersion(version) }
        try Self.validate(masks)
        self.masks = masks
        self.version = masks.isEmpty ? Self.currentVersion : version
        self.held = 0
        digestHex = masks.isEmpty ? "" : Self.digest(of: masks, version: version)
    }

    private init(digest: String, count: Int, version: String) { masks = []; held = count; digestHex = digest; self.version = version }

    /// The same set as a receipt keeps it.
    public var digestOnly: MaskSet { isEmpty || isDigestOnly ? self : MaskSet(digest: digestHex, count: masks.count, version: version) }

    /// Keep recorded compilers here when adding a new rule. An unavailable version is an explicit error, rather than silently
    /// reinterpreting a saved shape.
    public static func supports(version: String) -> Bool { version == currentVersion }

    /// Refuses what must not print, rather than print without it: an unavailable masks compiler, a receipt's digest, and masks under
    /// `ManualRenderSettings.regionsVersion`, which has no gain tables for their tone controls. Every other supported Light compiler
    /// takes masks. `lightCompiler` is the version of the Light mapping they would render with.
    public func requireRenderable(lightCompiler: String) throws {
        guard !isEmpty else { return }
        guard Self.supports(version: version) else { throw MaskError.unsupportedVersion(version) }
        if isDigestOnly { throw MaskError.digestOnly }
        // Masks read Highlights and Shadows before Exposure, so the panel beside them must too: older compilers take a first mask
        // only by moving to the current one (silently where that changes no pixel, by Reapply otherwise; masking-plan section 7).
        guard lightCompiler != ManualRenderSettings.regionsVersion, lightCompiler != ManualRenderSettings.exposedBaseVersion else {
            throw MaskError.lightCompiler(lightCompiler)
        }
    }

    public func updatingVersion() throws -> MaskSet { try editing({ $0 }, version: Self.currentVersion) }

    /// The masks as another picture takes them: Copy Adjustments to another frame, or Reapply Adjustments onto a replaced raw.
    /// Placed shapes (gradients, brush strokes) come across, since they are positions, and a brush keeps the frame it was painted on,
    /// so its mismatch can be flagged. A Follow edges stroke comes across with the shape it measured: it is the stroke's own shape, which
    /// cannot be made again without the hand that painted it, and a brush on a different photo has no good answer either way (R6). A smart selection is a measurement of the picture it was made on, as Auto's analysis is, so
    /// it is cleared and made again for the new one. A copy to another frame takes new ids; a Reapply onto the same frame's replaced
    /// raw keeps its own, and with them the names in `MaskNotes`. Either is a new edit, so it takes the current compiler.
    public func forAnotherPicture(freshIDs: Bool, geometry: LensGeometry? = nil) throws -> MaskSet {
        try editing({ masks in
            masks.map { mask in
                let components = mask.components.map { component -> MaskComponent in
                    guard case .smart(var selection) = component.shape else {
                        var copied = component; copied.shape = component.shape.stamped(geometry); return copied
                    }
                    selection.raster = nil
                    selection.frame = nil
                    selection.edge = .guided   // decided by the click that makes it again, and read from nothing else
                    return MaskComponent(operation: component.operation, shape: .smart(selection), invert: component.invert)
                }
                var copied = mask.copy(id: freshIDs ? UUID() : mask.id)
                copied.components = components
                return copied
            }
        }, version: Self.currentVersion)
    }

    public static func == (a: MaskSet, b: MaskSet) -> Bool { a.digestHex == b.digestHex && a.version == b.version && a.count == b.count }
    public func hash(into hasher: inout Hasher) { hasher.combine(digestHex); hasher.combine(version); hasher.combine(count) }

    // MARK: editing (the model's gestures call these; each validates)

    /// A receipt's digest has no masks to edit: treating it as an empty list would lose them.
    private func editing(_ change: ([Mask]) throws -> [Mask], version: String) throws -> MaskSet {
        if isDigestOnly { throw MaskError.digestOnly }
        return try MaskSet(masks: change(masks), version: version)
    }

    public func appending(_ mask: Mask) throws -> MaskSet { try editing({ $0 + [mask] }, version: version) }
    public func replacing(_ mask: Mask) throws -> MaskSet {
        try editing({ masks in
            guard let index = masks.firstIndex(where: { $0.id == mask.id }) else { throw MaskError.invalid("no such mask") }
            var all = masks
            all[index] = mask
            return all
        }, version: version)
    }
    public func removing(_ id: UUID) throws -> MaskSet { try editing({ $0.filter { $0.id != id } }, version: version) }

    /// Every raster the set names, for the store to keep and the writer to find before it commits: smart selections' seeds and Follow edges
    /// strokes' measured shapes, in list order.
    public var rasters: [RasterRef] {
        masks.flatMap(\.components).flatMap { component -> [RasterRef] in
            switch component.shape {
            case .smart(let selection): return selection.raster.map { [$0] } ?? []
            case .brush(let paint): return paint.strokes.compactMap { $0.measured?.raster }
            case .linear, .radial: return []
            }
        }
    }

    // MARK: validation

    private static func validate(_ masks: [Mask]) throws {
        guard masks.count <= maximumMasks else { throw MaskError.invalid("at most \(maximumMasks) masks") }
        guard Set(masks.map(\.id)).count == masks.count else { throw MaskError.invalid("mask ids repeat") }
        for mask in masks {
            guard (1...maximumComponents).contains(mask.components.count), mask.components[0].operation == .add else {
                throw MaskError.invalid("a mask has 1 to \(maximumComponents) components, the first added")
            }
            guard mask.amount.isFinite, Mask.amountRange.contains(mask.amount) else { throw MaskError.invalid("amount is 0 to 2") }
            guard MaskBalance.range.contains(mask.balance.warmth), MaskBalance.range.contains(mask.balance.magenta) else {
                throw MaskError.invalid("a mask's balance is -100 to 100")
            }
            guard mask.adjustments.masks.isEmpty, mask.adjustments.curves.isIdentity, mask.adjustments.presence.isIdentity, mask.adjustments.lens.isDefault else {
                throw MaskError.invalid("a mask's own adjustments hold no masks, no curves, no Presence and no Lens settings")
            }
            var points = 0
            for component in mask.components {
                switch component.shape {
                case .linear(let g):
                    try validate(position: g.full)
                    try validate(position: g.zero)
                    let span = (Double(g.zero.x) - Double(g.full.x), Double(g.zero.y) - Double(g.full.y))
                    guard (span.0 * span.0 + span.1 * span.1).squareRoot() >= Double(MaskSpace.minimumExtent) else {
                        throw MaskError.invalid("a linear gradient's Full and Zero points are apart")
                    }
                case .radial(let g):
                    try validate(position: g.center)
                    guard g.angle.isFinite else { throw MaskError.invalid("values are finite") }
                    guard g.semiAxisA.isFinite, g.semiAxisB.isFinite, g.semiAxisA >= MaskSpace.minimumExtent, g.semiAxisB >= MaskSpace.minimumExtent,
                          g.semiAxisA <= MaskSpace.coordinateRange.upperBound, g.semiAxisB <= MaskSpace.coordinateRange.upperBound else {
                        throw MaskError.invalid("a radial gradient's semi-axes are \(MaskSpace.minimumExtent) to \(MaskSpace.coordinateRange.upperBound) long sides")
                    }
                    guard g.feather.isFinite, MaskShape.RadialGradient.featherRange.contains(g.feather) else {
                        throw MaskError.invalid("feather is 0 to 100")
                    }
                case .brush(let paint):
                    for stroke in paint.strokes {
                        guard stroke.radius.isFinite, stroke.feather.isFinite, stroke.flow.isFinite,
                              MaskSpace.brushRadiusRange.contains(stroke.radius),
                              (0...1).contains(stroke.feather), (0...1).contains(stroke.flow), stroke.points.count > 0 else {
                            throw MaskError.invalid("a brush stroke has a radius, feather, flow and points")
                        }
                        guard stroke.measured == nil || stroke.followEdges else {
                            throw MaskError.invalid("only a Follow edges stroke keeps a measured shape")
                        }
                        points += stroke.points.count
                    }
                case .smart(let selection):
                    guard (selection.raster == nil) == (selection.frame == nil) else {
                        throw MaskError.invalid("a smart selection's raster and frame come together")
                    }
                    guard selection.feather.isFinite, SmartSelection.featherRange.contains(selection.feather) else {
                        throw MaskError.invalid("a smart selection's feather is 0 to 100")
                    }
                    // Only a click makes a `crisp` or `matte` edge, on Subject's seed: Person, Sky and a selection not made yet keep today's.
                    guard selection.edge == .guided || (selection.raster != nil && selection.kind.takesLearnedEdge) else {
                        throw MaskError.invalid("only a made Subject or Background has a crisp or matte edge")
                    }
                }
            }
            guard points <= maximumBrushPoints else { throw MaskError.invalid("a brush mask is \(maximumBrushPoints) points at most; flatten it to a raster") }
        }
    }

    private static func validate(position p: MaskPoint) throws {
        guard p.x.isFinite, p.y.isFinite, MaskSpace.coordinateRange.contains(p.x), MaskSpace.coordinateRange.contains(p.y) else {
            throw MaskError.invalid("a position is finite and in \(MaskSpace.coordinateRange) long sides")
        }
    }

    // MARK: canonical bytes

    private struct Writer {
        var data = Data()
        mutating func byte(_ v: UInt8) { data.append(v) }
        mutating func flag(_ v: Bool) { byte(v ? 1 : 0) }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func int(_ v: Int) { u32(UInt32(truncatingIfNeeded: v)) }
        mutating func float(_ v: Float) { u32((v == 0 ? 0 : v).bitPattern) }   // one zero for both signs
        mutating func text(_ s: String) { let b = Data(s.utf8); u32(UInt32(b.count)); data.append(b) }
        mutating func blob(_ b: Data) { u32(UInt32(b.count)); data.append(b) }
        mutating func point(_ p: MaskPoint) { float(p.x); float(p.y) }
        mutating func frame(_ f: MaskFrame) {
            int(f.orientation); int(f.width); int(f.height); text(f.decoder.rawValue); flag(f.lensCorrection)
            if let g = f.geometry { text("geometry"); text(g.digest) }
        }
        mutating func measured(_ m: MeasuredStroke) {
            text("measured"); text(m.raster.id.hex); int(m.raster.width); int(m.raster.height)
            int(m.x); int(m.y); int(m.pictureWidth); int(m.pictureHeight)
        }
    }

    /// Every field of every mask, in a fixed order and encoding that no library decides; `MaskTests` holds a golden value. What is
    /// written for a field never changes, since that would move every saved digest and develop every masked frame again. A field added
    /// later is written only when it is set, so a set without it keeps its digest. `schema` is not here: it says which builds can read a
    /// record, not what the record prints, so bumping it moves no digest.
    static func canonicalBytes(_ masks: [Mask], version: String) -> Data {
        var w = Writer()
        w.text("ARGENT-MASKSET"); w.text(version); w.int(masks.count)
        for mask in masks {
            w.data.append(contentsOf: withUnsafeBytes(of: mask.id.uuid) { Array($0) })
            w.flag(mask.isEnabled); w.float(mask.amount)
            let a = mask.adjustments
            for value in [a.exposureEV, a.contrast, a.highlights, a.shadows, a.whites, a.blacks] { w.float(value) }
            w.int(mask.components.count)
            for component in mask.components {
                w.text(component.operation.rawValue); w.flag(component.invert)
                switch component.shape {
                case .linear(let g):
                    w.text("linear"); w.point(g.full); w.point(g.zero)
                    if let geometry = g.geometry { w.text("geometry"); w.text(geometry.digest) }
                case .radial(let g):
                    w.text("radial"); w.point(g.center); w.float(g.semiAxisA); w.float(g.semiAxisB); w.float(g.angle); w.float(g.feather)
                    if let geometry = g.geometry { w.text("geometry"); w.text(geometry.digest) }
                case .brush(let paint):
                    w.text("brush"); w.frame(paint.frame); w.int(paint.strokes.count)
                    for s in paint.strokes {
                        w.flag(s.erase); w.flag(s.followEdges); w.float(s.radius); w.float(s.feather); w.float(s.flow)
                        w.int(s.points.count); w.blob(s.points.bytes)
                        // Schema 3, written only when set.
                        if let m = s.measured { w.measured(m) }
                    }
                case .smart(let s):
                    w.text("smart"); w.text(s.kind.rawValue)
                    if let raster = s.raster, let frame = s.frame {
                        w.flag(true); w.text(raster.id.hex); w.int(raster.width); w.int(raster.height); w.frame(frame)
                    } else { w.flag(false) }
                    // Schema 2, written only when set.
                    if s.feather != 0 { w.text("feather"); w.float(s.feather) }
                    // Schema 4, written only when set.
                    if s.edge != .guided { w.text("edge"); w.text(s.edge.rawValue) }
                }
            }
            // Schema 5, written only when set.
            if !mask.balance.isNeutral { w.text("balance"); w.float(mask.balance.warmth); w.float(mask.balance.magenta) }
        }
        return w.data
    }

    private static func digest(of masks: [Mask], version: String) -> String {
        hex(SHA256.hash(data: canonicalBytes(masks, version: version)))
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case schema, version, list, digest, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(Int.self, forKey: .schema)
        guard (1...Self.schema).contains(schema) else { throw MaskError.unsupportedSchema(schema) }
        let version = try c.decode(String.self, forKey: .version)
        if let list = try c.decodeIfPresent([Mask].self, forKey: .list) {
            try Self.validate(list)
            // A record holds no more than its schema says: a feather in a schema 1 record, a measured stroke in one below 3, or an edge
            // other than `guided` in one below 4, or a balance in one below 5, is what an older build would have dropped.
            guard Self.schema(of: list) <= schema else {
                throw MaskError.invalid(["a smart selection's feather needs masks schema 2", "a measured Follow edges stroke needs masks schema 3",
                                         "a smart selection's edge needs masks schema 4", "a mask's balance needs masks schema 5", "a shape's geometry needs masks schema 6"][Self.schema(of: list) - 2])
            }
            // An unavailable compiler keeps its intent: read, and refused at render (`requireRenderable`).
            masks = list; held = 0; self.version = list.isEmpty ? Self.currentVersion : version
            digestHex = list.isEmpty ? "" : Self.digest(of: list, version: version)   // recomputed, never trusted
        } else {
            masks = []; held = try c.decode(Int.self, forKey: .count); digestHex = try c.decode(String.self, forKey: .digest); self.version = version
            guard (1...Self.maximumMasks).contains(held), RasterID(hex: digestHex) != nil else {
                throw MaskError.invalid("a digest-only set has a count and a digest")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // A receipt's digest holds no field an older build would drop.
        try c.encode(isDigestOnly ? 1 : Self.schema(of: masks), forKey: .schema)
        try c.encode(version, forKey: .version)
        if isDigestOnly {
            try c.encode(held, forKey: .count)
            try c.encode(digestHex, forKey: .digest)
        } else {
            try c.encode(masks, forKey: .list)
        }
    }
}

/// What a seed's maker recorded, for the inspector and for deciding whether to make it again. Never part of a render, and never read to
/// reproduce a seed: the seed is the pin.
public struct RasterProvenance: Sendable, Equatable, Codable {
    /// "vision.person-segmentation", "vision.foreground-instance" or "coreml:<model id>".
    public var engine: String
    /// The Vision request revision, or a model's recipe id and weights digest.
    public var engineRevision: String
    public var parameters: [String: String]
    /// `ProcessInfo.operatingSystemVersionString` where it was made, as the disk cache keys Apple's decodes.
    public var operatingSystem: String
    public var app: String
    public var input: Input
    public var created: Date

    public struct Input: Sendable, Equatable, Codable {
        /// "neutral-print", the frame's own decode through `LUT3D.neutralPrint` (plan section 3).
        public var kind: String
        /// For a decode: `DecodePins.decoderVersion` and `DecodePins.currentVersion`.
        public var decoderVersion: String?
        public var pinsVersion: String?
        public var width: Int
        public var height: Int
        public var colorSpace: String
        /// The raw it was made from.
        public var sourceSHA256: String
        public init(kind: String, decoderVersion: String? = nil, pinsVersion: String? = nil, width: Int, height: Int,
                    colorSpace: String, sourceSHA256: String) {
            self.kind = kind; self.decoderVersion = decoderVersion; self.pinsVersion = pinsVersion
            self.width = width; self.height = height; self.colorSpace = colorSpace; self.sourceSHA256 = sourceSHA256
        }
    }

    public init(engine: String, engineRevision: String, parameters: [String: String] = [:], operatingSystem: String,
                app: String, input: Input, created: Date) {
        self.engine = engine; self.engineRevision = engineRevision; self.parameters = parameters
        self.operatingSystem = operatingSystem; self.app = app; self.input = input; self.created = created
    }
}

/// What the recipe keeps about masks that is not pixels, so renaming a mask or reading its provenance never changes a render's
/// fingerprint or makes a frame develop again.
public struct MaskNotes: Sendable, Equatable, Codable {
    /// Mask names by `UUID.uuidString`, so the JSON is an object.
    public var names: [String: String]
    /// By raster id.
    public var rasters: [String: RasterProvenance]
    public static let none = MaskNotes()
    public init(names: [String: String] = [:], rasters: [String: RasterProvenance] = [:]) { self.names = names; self.rasters = rasters }
    public var isEmpty: Bool { names.isEmpty && rasters.isEmpty }

    /// The notes on what `masks` still holds, so they go with their masks and a frame with no masks writes none.
    public func keeping(_ masks: MaskSet) -> MaskNotes {
        guard !isEmpty else { return self }
        let ids = Set(masks.masks.map(\.id.uuidString)), rasterIDs = Set(masks.rasters.map(\.id.hex))
        return MaskNotes(names: names.filter { ids.contains($0.key) }, rasters: rasters.filter { rasterIDs.contains($0.key) })
    }
}
