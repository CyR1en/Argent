import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Fixed values, so a digest is the same on every run.
private enum Fixture {
    static func id(_ n: UInt8) -> UUID {
        UUID(uuid: (n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n))
    }
    static func frame(lens: Bool = true, decoder: DecoderChoice = .raw9) throws -> MaskFrame {
        try MaskFrame(orientation: 6, width: 4672, height: 7008, decoder: decoder, lensCorrection: lens)
    }
    static func raster(byte: UInt8 = 0xab, width: Int = 64, height: Int = 48) throws -> RasterRef {
        try RasterRef(id: #require(RasterID(hex: String(repeating: String(format: "%02x", byte), count: 32))), width: width, height: height)
    }
    static var linear: MaskShape {
        .linear(.init(full: MaskPoint(x: 0.25, y: 0), zero: MaskPoint(x: 0.25, y: 0.5)))
    }
    static var radial: MaskShape {
        .radial(.init(center: MaskPoint(x: 0.75, y: 0.5), semiAxisA: 0.25, semiAxisB: 0.125, angle: 0.5, feather: 35))
    }
    static func stroke(erase: Bool = false, followEdges: Bool = false, points: Int = 3) throws -> BrushStroke {
        try BrushStroke(erase: erase, followEdges: followEdges, radius: 0.0625, feather: 0.5, flow: 0.75,
                        points: PackedPoints.pack((0..<points).map { MaskPoint(x: 0.25 + Float($0 % 8) / 64, y: 0.5) }))
    }
    static func brush() throws -> MaskShape {
        .brush(BrushPaint(frame: try frame(), strokes: [try stroke(), try stroke(erase: true, followEdges: true)]))
    }
    static func smart(_ kind: SmartKind = .sky) throws -> MaskShape {
        .smart(SmartSelection(kind: kind, raster: try raster(), frame: try frame()))
    }
    /// One mask holding every shape, operation and invert, with every slider set.
    static func everything() throws -> Mask {
        Mask(id: id(1), isEnabled: true, components: [
            MaskComponent(shape: linear),
            MaskComponent(operation: .add, shape: radial, invert: true),
            MaskComponent(operation: .subtract, shape: try brush()),
            MaskComponent(operation: .intersect, shape: try smart(), invert: true),
        ], amount: 1.5, adjustments: try ManualAdjustments(exposureEV: -0.75, contrast: 10, highlights: -30, shadows: 25, whites: 5, blacks: -5))
    }
    static func set(_ masks: Mask...) throws -> MaskSet { try MaskSet(masks: masks) }
    static func json(_ set: MaskSet) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(set), as: UTF8.self)
    }
    static func decode(_ text: String) throws -> MaskSet { try JSONDecoder().decode(MaskSet.self, from: Data(text.utf8)) }
}

@Suite struct MaskSpaceTests {
    @Test func positionsAreLongSideUnitsFromTheUprightTopLeftAndAreFreeOfTheRenderSize() throws {
        let landscape = try MaskSpace(width: 7008, height: 4672), portrait = try MaskSpace(width: 4672, height: 7008)
        #expect(landscape.longSide == 7008 && portrait.longSide == 7008)
        #expect(landscape.extent == MaskPoint(x: 1, y: Float(4672) / 7008))
        #expect(portrait.extent == MaskPoint(x: Float(4672) / 7008, y: 1))
        #expect(landscape.point(column: 0, yTop: 0) == MaskPoint(x: 0.5 / 7008, y: 0.5 / 7008))
        #expect(landscape.point(column: 7007, yTop: 4671) == MaskPoint(x: 7007.5 / 7008, y: 4671.5 / 7008))
        // The same place at half the size, so a circle stays a circle and a shape needs no size.
        let half = try MaskSpace(width: 3504, height: 2336)
        #expect(half.extent == landscape.extent)
        #expect(half.point(column: 100, yTop: 200) == MaskPoint(x: Float(201) / 7008, y: Float(401) / 7008))
        #expect(throws: MaskError.self) { try MaskSpace(width: 0, height: 10) }
    }

    /// A frame texture's row 0 is the picture's bottom row: the one flip, at upload and download.
    @Test func aPicturesTopRowIsTheTexturesLast() throws {
        let space = try MaskSpace(width: 6, height: 4)
        #expect(space.textureRow(yTop: 0) == 3 && space.textureRow(yTop: 3) == 0)
    }

    @Test func aFrameDescriptorIsValidOrRefused() throws {
        for orientation in 1...8 { _ = try MaskFrame(orientation: orientation, width: 10, height: 10, decoder: .apple, lensCorrection: false) }
        #expect(throws: MaskError.self) { try MaskFrame(orientation: 0, width: 10, height: 10, decoder: .apple, lensCorrection: false) }
        #expect(throws: MaskError.self) { try MaskFrame(orientation: 9, width: 10, height: 10, decoder: .apple, lensCorrection: false) }
        #expect(throws: MaskError.self) { try MaskFrame(orientation: 1, width: 0, height: 10, decoder: .apple, lensCorrection: false) }
        let text = #"{"orientation":9,"width":10,"height":10,"decoder":"apple","lensCorrection":true}"#
        #expect(throws: MaskError.self) { try JSONDecoder().decode(MaskFrame.self, from: Data(text.utf8)) }
        let frame = try Fixture.frame()
        #expect(try JSONDecoder().decode(MaskFrame.self, from: JSONEncoder().encode(frame)) == frame)
        #expect(try Fixture.frame(lens: false) != frame && Fixture.frame(decoder: .inHouse) != frame)
    }

    /// A gradient needs none; a brush and a made seed carry the frame they were made on.
    @Test func rasterAndBrushComponentsCarryTheirFrame() throws {
        let frame = try Fixture.frame()
        #expect(Fixture.linear.frame == nil && Fixture.radial.frame == nil)
        #expect(try Fixture.brush().frame == frame && Fixture.smart().frame == frame)
        #expect(MaskShape.smart(SmartSelection(kind: .person)).frame == nil)
    }
}

@Suite struct MaskValidationTests {
    private func mask(_ shape: MaskShape, amount: Float = 1) -> Mask {
        Mask(components: [MaskComponent(shape: shape)], amount: amount)
    }

    private func refused(_ name: String, _ masks: () throws -> [Mask]) {
        do {
            _ = try MaskSet(masks: masks())
            Issue.record("\(name) was accepted")
        } catch MaskError.invalid { } catch { Issue.record("\(name): \(error)") }
    }

    @Test func everyValueIsFiniteAndInItsRange() throws {
        let nan = Float.nan, infinity = Float.infinity
        let o = MaskPoint(x: 0.5, y: 0.5), p = MaskPoint(x: 0.5, y: 0.75)
        // Amount.
        for amount in [nan, infinity, -0.01, 2.01] { refused("amount \(amount)") { [mask(Fixture.linear, amount: amount)] } }
        // Linear: positions finite and bounded, Full and Zero apart.
        for bad in [MaskPoint(x: nan, y: 0), MaskPoint(x: 0, y: infinity), MaskPoint(x: 16.5, y: 0), MaskPoint(x: 0, y: -16.5)] {
            refused("a linear Full at \(bad)") { [mask(.linear(.init(full: bad, zero: p)))] }
            refused("a linear Zero at \(bad)") { [mask(.linear(.init(full: p, zero: bad)))] }
        }
        refused("Full on Zero") { [mask(.linear(.init(full: o, zero: o)))] }
        refused("Full and Zero under a tenth of a pixel apart") {
            [mask(.linear(.init(full: o, zero: MaskPoint(x: 0.5, y: 0.5 + MaskSpace.minimumExtent / 4))))]
        }
        // Radial.
        for bad in [nan, infinity, 0, -0.1, MaskSpace.minimumExtent / 2, 16.5] {
            refused("semi-axis \(bad)") { [mask(.radial(.init(center: o, semiAxisA: bad, semiAxisB: 0.25)))] }
            refused("semi-axis \(bad)") { [mask(.radial(.init(center: o, semiAxisA: 0.25, semiAxisB: bad)))] }
        }
        for bad in [nan, infinity, -0.5, 100.5] {
            refused("radial feather \(bad)") { [mask(.radial(.init(center: o, semiAxisA: 0.25, semiAxisB: 0.25, feather: bad)))] }
        }
        refused("a radial angle that is not finite") { [mask(.radial(.init(center: o, semiAxisA: 0.25, semiAxisB: 0.25, angle: nan)))] }
        refused("a radial centre that is not finite") {
            [mask(.radial(.init(center: MaskPoint(x: nan, y: 0), semiAxisA: 0.25, semiAxisB: 0.25)))]
        }
        // Brush.
        let points = try PackedPoints.pack([o]), frame = try Fixture.frame()
        for radius in [nan, infinity, 0, 0.0005, 0.25] {
            refused("brush radius \(radius)") { [mask(.brush(BrushPaint(frame: frame, strokes: [BrushStroke(radius: radius, points: points)])))] }
        }
        for value in [nan, infinity, -0.01, 1.01] {
            refused("brush feather \(value)") { [mask(.brush(BrushPaint(frame: frame, strokes: [BrushStroke(radius: 0.05, feather: value, points: points)])))] }
            refused("brush flow \(value)") { [mask(.brush(BrushPaint(frame: frame, strokes: [BrushStroke(radius: 0.05, flow: value, points: points)])))] }
        }
        refused("a stroke with no points") {
            [mask(.brush(BrushPaint(frame: frame, strokes: [BrushStroke(radius: 0.05, points: try PackedPoints.pack([]))])))]
        }
        // Smart: a seed and the frame it was made on come together.
        refused("a seed with no frame") { [mask(.smart(SmartSelection(kind: .sky, raster: try Fixture.raster())))] }
        refused("a frame with no seed") { [mask(.smart(SmartSelection(kind: .sky, frame: frame)))] }
        // And what is in range is taken: the ends of each.
        _ = try Fixture.set(mask(Fixture.linear, amount: 0), mask(Fixture.linear, amount: 2),
                            mask(.linear(.init(full: MaskPoint(x: -16, y: -16), zero: MaskPoint(x: 16, y: 16)))),
                            mask(.radial(.init(center: o, semiAxisA: MaskSpace.minimumExtent, semiAxisB: 16, feather: 0))),
                            mask(.radial(.init(center: o, semiAxisA: 16, semiAxisB: MaskSpace.minimumExtent, feather: 100))),
                            mask(.brush(BrushPaint(frame: frame, strokes: [BrushStroke(radius: 0.001, feather: 0, flow: 0, points: points)]))),
                            mask(.brush(BrushPaint(frame: frame, strokes: [BrushStroke(radius: 0.2, feather: 1, flow: 1, points: points)]))),
                            mask(.brush(BrushPaint(frame: frame))), // A brush armed before its first stroke.
                            mask(.smart(SmartSelection(kind: .person))))
    }

    @Test func theCapsAreSixteenMasksSixteenComponentsAnd16384BrushPoints() throws {
        #expect(MaskSet.maximumMasks == 16 && MaskSet.maximumComponents == 16 && MaskSet.maximumBrushPoints == 16_384)
        let one = { [self] in mask(Fixture.linear) }
        _ = try MaskSet(masks: (0..<16).map { _ in one() })
        refused("seventeen masks") { (0..<17).map { _ in one() } }
        let parts = (0..<16).map { _ in MaskComponent(shape: Fixture.linear) }
        _ = try Fixture.set(Mask(components: parts))
        refused("seventeen components") { [Mask(components: parts + [MaskComponent(shape: Fixture.linear)])] }
        refused("no components") { [Mask(components: [])] }
        // Across a mask's strokes and its brush components alike.
        let frame = try Fixture.frame(), half = try Fixture.stroke(points: 8192), one8192 = MaskShape.brush(BrushPaint(frame: frame, strokes: [half]))
        _ = try Fixture.set(Mask(components: [MaskComponent(shape: one8192), MaskComponent(shape: one8192)]))
        let more = try Fixture.stroke(points: 1)
        refused("16,385 points in one stroke list") { [mask(.brush(BrushPaint(frame: frame, strokes: [half, half, more])))] }
        refused("16,385 points over two components") {
            [Mask(components: [MaskComponent(shape: one8192), MaskComponent(shape: .brush(BrushPaint(frame: frame, strokes: [half, more])))])]
        }
        // Another mask has its own allowance.
        _ = try Fixture.set(mask(.brush(BrushPaint(frame: frame, strokes: [half, half]))), mask(.brush(BrushPaint(frame: frame, strokes: [half, half]))))
    }

    @Test func theFirstComponentAddsIdsDoNotRepeatAndAMaskHoldsNoMasksOrCurves() throws {
        refused("a first component that subtracts") { [Mask(components: [MaskComponent(operation: .subtract, shape: Fixture.linear)])] }
        refused("a first component that intersects") { [Mask(components: [MaskComponent(operation: .intersect, shape: Fixture.linear)])] }
        let id = UUID()
        refused("a repeated id") {
            [Mask(id: id, components: [MaskComponent(shape: Fixture.linear)]), Mask(id: id, components: [MaskComponent(shape: Fixture.radial)])]
        }
        refused("curves in a mask") {
            [Mask(components: [MaskComponent(shape: Fixture.linear)],
                  adjustments: try ManualAdjustments(curves: ToneCurves(tone: ToneCurves.Preset.softContrast.curve)))]
        }
        refused("masks in a mask") {
            [Mask(components: [MaskComponent(shape: Fixture.linear)],
                  adjustments: ManualAdjustments.identity.settingMasks(try Fixture.set(mask(Fixture.radial))))]
        }
    }

    /// The six sliders are the panel's own: its ranges hold in a mask too, and a stored value out of range fails the read.
    @Test func aMasksSlidersKeepThePanelsRanges() throws {
        let set = try Fixture.set(Mask(id: Fixture.id(1), components: [MaskComponent(shape: Fixture.linear)],
                                       adjustments: try ManualAdjustments(shadows: 25)))
        let text = try Fixture.json(set)
        #expect(try Fixture.decode(text) == set)
        #expect(throws: ManualDevelopmentError.self) { try Fixture.decode(text.replacingOccurrences(of: #""shadows":25"#, with: #""shadows":101"#)) }
    }

    /// What a read finds invalid is what a write refuses: the same rules, and the record is kept.
    @Test func aStoredValueOutOfRangeFailsTheRead() throws {
        let text = try Fixture.json(try Fixture.set(Mask(id: Fixture.id(1), components: [MaskComponent(shape: Fixture.radial)])))
        for (old, new) in [(#""amount":1"#, #""amount":2.5"#), (#""feather":35"#, #""feather":101"#), (#""semiAxisA":0.25"#, #""semiAxisA":0"#),
                           (#""semiAxisA":0.25"#, #""semiAxisA":17"#)] {
            let changed = text.replacingOccurrences(of: old, with: new)
            #expect(changed != text)
            #expect(throws: MaskError.self) { try Fixture.decode(changed) }
        }
        let all = (0..<17).map { Mask(id: Fixture.id(UInt8($0)), components: [MaskComponent(shape: Fixture.linear)]) }
        let sixteen = try Fixture.json(try MaskSet(masks: Array(all.prefix(16)))), one = try Fixture.json(try Fixture.set(all[16]))
        let opening = #""list":["#
        let object = one[try #require(one.range(of: opening)).upperBound..<(try #require(one.lastIndex(of: "]")))]
        #expect(throws: MaskError.self) { try Fixture.decode(sixteen.replacingOccurrences(of: opening, with: opening + object + ",")) }
    }
}

@Suite struct PackedPointsTests {
    @Test func pointsComeBackOnTheQuantizedGridAndPackingThemAgainIsTheSameBytes() throws {
        let unit = 1 / Float(MaskSpace.brushPointsPerLongSide)
        let exact = [MaskPoint(x: 0, y: 0), MaskPoint(x: 1, y: 2.0 / 3 - (2.0 / 3).remainder(dividingBy: unit)), MaskPoint(x: -1, y: 2), MaskPoint(x: 0.5, y: 0.25)]
        let packed = try PackedPoints.pack(exact)
        #expect(packed.count == 4 && packed.points == exact)
        #expect(try PackedPoints.pack(packed.points) == packed)
        let rough = try PackedPoints.pack([MaskPoint(x: 0.123456, y: 0.654321)])
        #expect(abs(rough.points[0].x - 0.123456) <= unit / 2 && abs(rough.points[0].y - 0.654321) <= unit / 2)
        #expect(try PackedPoints.pack(rough.points) == rough)
        #expect(try PackedPoints.pack([]).points.isEmpty)
    }

    /// No pressure: two values a point, so a dense stroke costs under the 5 to 10 bytes the plan allows, before base64.
    @Test func aPointCostsAFewBytes() throws {
        let path = (0..<1000).map { i -> MaskPoint in
            let t = Float(i) / 1000
            return MaskPoint(x: 0.2 + 0.5 * t + 0.02 * sin(t * 40), y: 0.3 + 0.3 * t * t)
        }
        let packed = try PackedPoints.pack(path)
        #expect(packed.bytes.count <= path.count * 5, "\(packed.bytes.count) bytes for \(path.count) points")
        let base64 = packed.bytes.base64EncodedString().utf8.count
        #expect(base64 <= path.count * 10)
    }

    @Test func aPointOutsideItsRangeIsRefused() {
        for bad in [MaskPoint(x: -1.01, y: 0), MaskPoint(x: 0, y: 2.01), MaskPoint(x: .nan, y: 0), MaskPoint(x: 0, y: .infinity)] {
            #expect(throws: MaskError.self) { try PackedPoints.pack([bad]) }
        }
    }

    private func read(points: [UInt8], count: Int) throws -> PackedPoints {
        let text = #"{"points":"\#(Data(points).base64EncodedString())","count":\#(count)}"#
        return try JSONDecoder().decode(PackedPoints.self, from: Data(text.utf8))
    }

    /// A stroke that cannot be read fails the record, and one list of points has one byte string, so one digest.
    @Test func malformedBytesFailTheRead() throws {
        #expect(try read(points: [2, 4], count: 1).points == [MaskPoint(x: 1 / 32768, y: 2 / 32768)])
        #expect(throws: MaskError.self) { try read(points: [2], count: 1) }                  // cut short
        #expect(throws: MaskError.self) { try read(points: [2, 4, 6], count: 1) }            // bytes past its points
        #expect(throws: MaskError.self) { try read(points: [2, 4], count: 2) }               // fewer than it says
        #expect(throws: MaskError.self) { try read(points: [2, 4], count: -1) }              // a count below zero
        #expect(throws: MaskError.self) { try read(points: [0x82, 0x00, 4], count: 1) }      // an overlong varint for 1
        #expect(throws: MaskError.self) { try read(points: [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 4], count: 1) } // a huge one
        let far = 200_000 << 1                                                                // past 2 long sides
        let varint: [UInt8] = [UInt8(far & 0x7f) | 0x80, UInt8(far >> 7 & 0x7f) | 0x80, UInt8(far >> 14 & 0x7f)]
        #expect(throws: MaskError.self) { try read(points: varint + [0], count: 1) }
    }
}

@Suite struct MaskSetTests {
    /// Written by hand, so no encoder or OS can move it. This value fixes `canonicalBytes`: changing what they write for a field moves
    /// the digest of every saved mask and develops every masked frame again, so it never gets a new value here.
    @Test func theDigestIsAGoldenValue() throws {
        let set = try Fixture.set(try Fixture.everything())
        #expect(set.digest == "df762b0ce8a1d96c3d68de47478de548a41edbc700c2b8d02ee45de469aa0b86")
        #expect(set.digest.count == 64 && RasterID(hex: set.digest) != nil)
        #expect(MaskSet.canonicalBytes(set.masks, version: set.version).prefix(14 + 4) == Data([14, 0, 0, 0]) + Data("ARGENT-MASKSET".utf8))
    }

    @Test func emptyIsEmptyWhateverMadeIt() throws {
        #expect(MaskSet.empty.isEmpty && MaskSet.empty.count == 0 && MaskSet.empty.digest.isEmpty && !MaskSet.empty.isDigestOnly)
        #expect(try MaskSet(masks: []) == .empty)
        let set = try Fixture.set(try Fixture.everything())
        #expect(try set.removing(Fixture.id(1)) == .empty)
        #expect(try Fixture.decode(#"{"schema":1,"version":"anything","list":[]}"#) == .empty)
        #expect(MaskSet.empty.digestOnly == .empty)
    }

    /// Every field that reaches a render moves the digest, so moves the fingerprint and the Develop-again comparison.
    @Test func everyFieldMovesTheDigest() throws {
        let base = try Fixture.everything(), original = try Fixture.set(base)
        func changed(_ name: String, _ edit: (inout Mask) throws -> Void) throws {
            var mask = base
            try edit(&mask)
            let other = try Fixture.set(mask)
            #expect(other != original, "\(name) did not move the digest")
            #expect(other.digest != original.digest && other.hashValue != original.hashValue)
        }
        func shape(_ index: Int, _ new: MaskShape) -> (inout Mask) -> Void { { $0.components[index].shape = new } }
        try changed("on or off") { $0.isEnabled = false }
        try changed("amount") { $0.amount = 1 }
        for control in ManualAdjustments.Control.allCases {
            try changed(control.title) { $0.adjustments = try $0.adjustments.setting(control, to: 1) }
        }
        try changed("operation") { $0.components[1].operation = .subtract }
        try changed("invert") { $0.components[1].invert = false }
        try changed("linear Full", shape(0, .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.25, y: 0.5)))))
        try changed("linear Zero", shape(0, .linear(.init(full: MaskPoint(x: 0.25, y: 0), zero: MaskPoint(x: 0.25, y: 0.75)))))
        let o = MaskPoint(x: 0.75, y: 0.5)
        try changed("radial centre", shape(1, .radial(.init(center: MaskPoint(x: 0.5, y: 0.5), semiAxisA: 0.25, semiAxisB: 0.125, angle: 0.5, feather: 35))))
        try changed("radial axis A", shape(1, .radial(.init(center: o, semiAxisA: 0.5, semiAxisB: 0.125, angle: 0.5, feather: 35))))
        try changed("radial axis B", shape(1, .radial(.init(center: o, semiAxisA: 0.25, semiAxisB: 0.25, angle: 0.5, feather: 35))))
        try changed("radial angle", shape(1, .radial(.init(center: o, semiAxisA: 0.25, semiAxisB: 0.125, angle: 1, feather: 35))))
        try changed("radial feather", shape(1, .radial(.init(center: o, semiAxisA: 0.25, semiAxisB: 0.125, angle: 0.5, feather: 36))))
        let frame = try Fixture.frame(), stroke = try Fixture.stroke()
        func withStroke(_ edit: (inout BrushStroke) throws -> Void) throws -> MaskShape {
            var s = stroke; try edit(&s)
            return .brush(BrushPaint(frame: frame, strokes: [s, try Fixture.stroke(erase: true, followEdges: true)]))
        }
        try changed("erase", shape(2, try withStroke { $0.erase = true }))
        try changed("follow edges", shape(2, try withStroke { $0.followEdges = true }))
        try changed("radius", shape(2, try withStroke { $0.radius = 0.125 }))
        try changed("brush feather", shape(2, try withStroke { $0.feather = 0.25 }))
        try changed("flow", shape(2, try withStroke { $0.flow = 0.25 }))
        try changed("points", shape(2, try withStroke { $0.points = try PackedPoints.pack([MaskPoint(x: 0.25, y: 0.5)]) }))
        try changed("a stroke fewer", shape(2, .brush(BrushPaint(frame: frame, strokes: [stroke]))))
        try changed("the brush's frame", shape(2, .brush(BrushPaint(frame: try Fixture.frame(lens: false), strokes: [stroke, try Fixture.stroke(erase: true, followEdges: true)]))))
        try changed("smart kind", shape(3, try Fixture.smart(.person)))
        try changed("raster id", shape(3, .smart(SmartSelection(kind: .sky, raster: try Fixture.raster(byte: 1), frame: frame))))
        try changed("raster size", shape(3, .smart(SmartSelection(kind: .sky, raster: try Fixture.raster(width: 128), frame: frame))))
        try changed("the seed's frame", shape(3, .smart(SmartSelection(kind: .sky, raster: try Fixture.raster(), frame: try Fixture.frame(lens: false)))))
        try changed("a seed cleared", shape(3, .smart(SmartSelection(kind: .sky))))
    }

    /// A value that does not change: both signs of zero, one digest, as `ManualAdjustments` keeps one identity.
    @Test func bothZerosAreOneDigestAndAnIdIsPartOfIt() throws {
        func set(_ zero: Float, id: UInt8 = 1) throws -> MaskSet {
            try Fixture.set(Mask(id: Fixture.id(id), components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: zero, y: 0), zero: MaskPoint(x: 0.5, y: 0.5))))]))
        }
        #expect(try set(0) == set(-0.0) && set(0).digest == set(-0.0).digest)
        #expect(try set(0, id: 2) != set(0))
    }

    /// Long-side units are any float a drag leaves: JSON brings each one back exact, so a saved set keeps its digest.
    @Test func arbitraryPositionsSurviveJSONExactly() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let v = (0..<8).map { _ in Float.random(in: -1.5...1.5, using: &generator) }
            let set = try Fixture.set(Mask(components: [
                MaskComponent(shape: .linear(.init(full: MaskPoint(x: v[0], y: v[1]), zero: MaskPoint(x: v[0] + 1, y: v[3])))),
                MaskComponent(shape: .radial(.init(center: MaskPoint(x: v[4], y: v[5]), semiAxisA: abs(v[6]) + 0.01, semiAxisB: abs(v[7]) + 0.01, angle: v[2], feather: abs(v[3]) * 60))),
            ], amount: abs(v[0])))
            let read = try JSONDecoder().decode(MaskSet.self, from: JSONEncoder().encode(set))
            #expect(read == set && read.digest == set.digest)
        }
    }

    @Test func everyComponentKindRoundTrips() throws {
        var shapes: [MaskShape] = [Fixture.linear, Fixture.radial, try Fixture.brush(), .brush(BrushPaint(frame: try Fixture.frame()))]
        for kind in SmartKind.allCases {
            shapes.append(try Fixture.smart(kind))
            shapes.append(.smart(SmartSelection(kind: kind)))
        }
        for shape in shapes {
            for operation in MaskOperation.allCases {
                for invert in [false, true] {
                    let parts = [MaskComponent(shape: Fixture.linear), MaskComponent(operation: operation, shape: shape, invert: invert)]
                    let set = try Fixture.set(Mask(id: Fixture.id(7), isEnabled: !invert, components: parts, amount: 0.5,
                                                   adjustments: try ManualAdjustments(exposureEV: 0.25)))
                    let read = try JSONDecoder().decode(MaskSet.self, from: JSONEncoder().encode(set))
                    #expect(read == set && read.masks == set.masks && read.masks[0].components[1] == parts[1])
                }
            }
        }
        // And a component may be first with any shape, added, on its own.
        for shape in shapes { _ = try Fixture.set(Mask(components: [MaskComponent(shape: shape, invert: true)])) }
    }

    /// The record's own digest field is never trusted when it holds the list.
    @Test func aStoredDigestIsRecomputed() throws {
        let set = try Fixture.set(try Fixture.everything())
        let text = try Fixture.json(set)
        let forged = text.replacingOccurrences(of: #"{"list":"#, with: #"{"digest":"\#(String(repeating: "0", count: 64))","count":1,"list":"#)
        #expect(try forged != text && Fixture.decode(forged).digest == set.digest)
    }

    @Test func anUnknownSchemaShapeKindOrOperationFailsTheRead() throws {
        let text = try Fixture.json(try Fixture.set(try Fixture.everything()))
        #expect(throws: MaskError.unsupportedSchema(7)) { try Fixture.decode(text.replacingOccurrences(of: #""schema":1"#, with: #""schema":7"#)) }
        #expect(throws: MaskError.unsupportedSchema(0)) { try Fixture.decode(text.replacingOccurrences(of: #""schema":1"#, with: #""schema":0"#)) }
        for (name, old, new) in [("shape", #""type":"linear""#, #""type":"depth""#),
                                 ("a range shape, not in schema 1", #""type":"linear""#, #""type":"range""#),
                                 ("kind", #""kind":"sky""#, #""kind":"water""#),
                                 ("operation", #""operation":"subtract""#, #""operation":"xor""#),
                                 ("decoder", #""decoder":"raw9""#, #""decoder":"raw10""#)] {
            let changed = text.replacingOccurrences(of: old, with: new)
            #expect(changed != text, "\(name) is not in the fixture")
            #expect(throws: (any Error).self, "\(name)") { try Fixture.decode(changed) }
        }
    }

    /// Why anything an older reader would drop bumps the schema: a field it does not know is dropped silently.
    @Test func aFieldThisBuildDoesNotKnowIsDropped() throws {
        let set = try Fixture.set(Mask(id: Fixture.id(1), components: [MaskComponent(shape: Fixture.radial)]))
        let text = try Fixture.json(set)
        let extra = text.replacingOccurrences(of: #""feather":35"#, with: #""feather":35,"depthFalloff":3"#)
        #expect(try extra != text && Fixture.decode(extra) == set)
    }

    @Test func aReceiptsDigestEqualsItsSetAndCannotRenderOrBeEdited() throws {
        let mask = try Fixture.everything(), set = try Fixture.set(mask), receipt = set.digestOnly
        #expect(receipt.isDigestOnly && receipt.masks.isEmpty && receipt.count == 1 && !receipt.isEmpty)
        #expect(receipt == set && receipt.hashValue == set.hashValue && receipt.digest == set.digest)
        #expect(receipt.digestOnly == receipt && receipt.rasters.isEmpty)
        let read = try Fixture.decode(try Fixture.json(receipt))
        #expect(read.isDigestOnly && read == set && read.count == 1)
        #expect(!(try Fixture.json(receipt)).contains("list"))
        #expect(throws: MaskError.digestOnly) { try receipt.requireRenderable(lightCompiler: ManualRenderSettings.currentVersion) }
        #expect(throws: MaskError.digestOnly) { try receipt.appending(mask) }
        #expect(throws: MaskError.digestOnly) { try receipt.replacing(mask) }
        #expect(throws: MaskError.digestOnly) { try receipt.removing(mask.id) }
        #expect(throws: MaskError.digestOnly) { try receipt.forAnotherPicture(freshIDs: true) }
        #expect(throws: MaskError.digestOnly) { try receipt.updatingVersion() }
        // Malformed digests fail the read.
        let digest = String(repeating: "a", count: 64)
        for text in [#"{"schema":1,"version":"v","count":0,"digest":"\#(digest)"}"#, #"{"schema":1,"version":"v","count":17,"digest":"\#(digest)"}"#,
                     #"{"schema":1,"version":"v","count":1,"digest":"short"}"#, #"{"schema":1,"version":"v","count":1}"#, #"{"schema":1,"version":"v"}"#] {
            #expect(throws: (any Error).self) { try Fixture.decode(text) }
        }
    }

    @Test func aDigestOnlySettingsComparesEqualAndRefusesToRender() throws {
        let set = try Fixture.set(try Fixture.everything())
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.25, masks: set), referenceStops: 0.5)
        let receipt = manual.digestingMasks()
        #expect(receipt == manual && receipt.hashValue == manual.hashValue && receipt.adjustments.masks.isDigestOnly)
        #expect(receipt.referenceStops == 0.5 && receipt.version == manual.version)
        #expect(throws: MaskError.digestOnly) { try receipt.validateSupportedVersion() }
        #expect(throws: MaskError.digestOnly) { try receipt.applyingScene(to: SIMD3(repeating: 0.18)) }
        #expect(throws: MaskError.digestOnly) { try ManualRenderSettings(adjustments: receipt.adjustments, referenceStops: 0) }
        let read = try JSONDecoder().decode(ManualRenderSettings.self, from: JSONEncoder().encode(receipt))
        #expect(read == manual && read.adjustments.masks.isDigestOnly)
        let plain = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.25), referenceStops: 0.5)
        #expect(plain.digestingMasks() == plain && ManualRenderSettings.identity.digestingMasks() == .identity)
    }

    /// `coverage` is what a slider cannot change, and every change of shape changes it: the cache key of a coverage field.
    @Test func coverageChangesWithTheShapeAndWithNothingElse() throws {
        let base = try Fixture.everything()
        func sameKey(_ edit: (inout Mask) throws -> Void) throws -> Bool {
            var mask = base
            try edit(&mask)
            return mask.coverage == base.coverage && mask.coverage.hashValue == base.coverage.hashValue
        }
        #expect(try sameKey { $0.adjustments = try $0.adjustments.setting(.exposure, to: -1.5) })
        #expect(try sameKey { $0.amount = 0 })
        #expect(try sameKey { $0.isEnabled = false })
        #expect(try !sameKey { $0.components[0].invert = true })
        #expect(try !sameKey { $0.components[1].operation = .subtract })
        #expect(try !sameKey { $0.components[0].shape = Fixture.radial })
        #expect(try !sameKey { $0.components.removeLast() })
        #expect(try !sameKey { $0.components[2].shape = .brush(BrushPaint(frame: try Fixture.frame(lens: false))) })
    }

    @Test func amountIsStoredZeroToTwoDefaultsToOneAndZeroKeepsTheMask() throws {
        #expect(Mask.amountRange == 0...2)
        let mask = Mask(components: [MaskComponent(shape: Fixture.linear)], adjustments: try ManualAdjustments(exposureEV: -1, whites: 50))
        #expect(mask.amount == 1)
        #expect(mask.scaledValue(for: .exposure) == -1 && mask.scaledValue(for: .whites) == 50 && mask.scaledValue(for: .shadows) == 0)
        var doubled = mask
        doubled.amount = 2
        #expect(doubled.scaledValue(for: .exposure) == -2 && doubled.scaledValue(for: .whites) == 100)
        var none = mask
        none.amount = 0
        for control in ManualAdjustments.Control.allCases { #expect(none.scaledValue(for: control) == 0) }
        let kept = try Fixture.set(none)
        #expect(kept.count == 1 && !ManualAdjustments.identity.settingMasks(kept).isIdentity && kept != .empty)
        var off = mask
        off.isEnabled = false
        for control in ManualAdjustments.Control.allCases { #expect(off.scaledValue(for: control) == 0) }
    }

    @Test func invertIsTheComponentsAndEachComponentHasItsOwn() throws {
        var mask = Mask(id: Fixture.id(1), components: [MaskComponent(shape: Fixture.linear), MaskComponent(operation: .subtract, shape: Fixture.radial)])
        #expect(mask.components.allSatisfy { !$0.invert })
        let plain = try Fixture.set(mask)
        mask.components[1].invert.toggle()
        let inverted = try Fixture.set(mask)
        #expect(inverted != plain && inverted.masks[0].components[1].invert && !inverted.masks[0].components[0].invert)
        #expect(try Fixture.decode(try Fixture.json(inverted)).masks[0].components[1].invert)
    }

    /// Another picture takes placed shapes, not a smart seed, which measured this one; a copy takes new ids, a Reapply its own.
    @Test func anotherPictureKeepsPlacedShapesAndClearsSmartRasters() throws {
        let smart = Mask(id: Fixture.id(1), components: [MaskComponent(shape: try Fixture.smart()), MaskComponent(operation: .subtract, shape: try Fixture.brush(), invert: true)],
                         amount: 1.5, adjustments: try ManualAdjustments(exposureEV: -0.5))
        let placed = Mask(id: Fixture.id(2), isEnabled: false, components: [MaskComponent(shape: Fixture.linear), MaskComponent(operation: .intersect, shape: Fixture.radial, invert: true)],
                          amount: 0.5, adjustments: try ManualAdjustments(shadows: 20))
        let set = try Fixture.set(smart, placed)
        #expect(set.rasters.count == 1 && set.masks[0].pendingSmart.isEmpty)
        for fresh in [true, false] {
            let other = try set.forAnotherPicture(freshIDs: fresh)
            #expect(other.count == 2 && other.rasters.isEmpty && other != set)
            #expect(other.masks[0].pendingSmart == [.sky])
            #expect(other.masks[0].components[0].shape == .smart(SmartSelection(kind: .sky)))
            #expect(other.masks[0].components[1] == smart.components[1])     // The brush, with the frame it was painted on.
            #expect(other.masks[1].coverage == placed.coverage && other.masks[1].isEnabled == false)
            #expect(other.masks.map(\.amount) == [1.5, 0.5] && other.masks[0].adjustments == smart.adjustments)
            #expect(Set(other.masks.map(\.id)).isDisjoint(with: set.masks.map(\.id)) == fresh)
            #expect(fresh || other.masks.map(\.id) == set.masks.map(\.id))
        }
        let unmade = try set.forAnotherPicture(freshIDs: false).forAnotherPicture(freshIDs: false)
        #expect(unmade == (try set.forAnotherPicture(freshIDs: false)))
        let adjustments = try ManualAdjustments(exposureEV: 0.25, masks: set).forAnotherPicture(freshIDs: true)
        #expect(adjustments.exposureEV == 0.25 && adjustments.masks.rasters.isEmpty && adjustments.masks.count == 2)
    }

    @Test func editsValidateAndNameTheirMask() throws {
        let a = Mask(id: Fixture.id(1), components: [MaskComponent(shape: Fixture.linear)])
        var b = Mask(id: Fixture.id(2), components: [MaskComponent(shape: Fixture.radial)])
        var set = try Fixture.set(a).appending(b)
        #expect(set.masks.map(\.id) == [a.id, b.id])
        b.amount = 2
        set = try set.replacing(b)
        #expect(set.masks[1].amount == 2)
        #expect(throws: MaskError.self) { try set.appending(b) } // Its id repeats.
        b.amount = 3
        #expect(throws: MaskError.self) { try set.replacing(b) }
        #expect(throws: MaskError.invalid("no such mask")) { try set.replacing(Mask(components: a.components)) }
        #expect(try set.removing(a.id).masks.map(\.id) == [b.id] && set.removing(UUID()) == set)
        #expect(try set.updatingVersion() == set)
    }

    @Test func aRasterIsNamedByItsPixels() throws {
        let plane = (0..<(16 * 32)).map { UInt8(truncatingIfNeeded: $0) }
        let raster = try MaskRaster(width: 16, height: 32, plane: plane)
        #expect(raster.identity.hex == "2796622bc088868e7aac7451ad30a453be8b1918e1d628f61d05f1cfb9e02949")
        #expect(raster.ref == (try RasterRef(id: raster.identity, width: 16, height: 32)))
        #expect(try MaskRaster(width: 32, height: 16, plane: plane).identity != raster.identity)
        #expect(throws: MaskError.self) { try MaskRaster(width: 16, height: 32, plane: []) }
        #expect(throws: MaskError.self) { try MaskRaster(width: 8, height: 64, plane: plane) }
        #expect(throws: MaskError.self) { try RasterRef(id: raster.identity, width: 4097, height: 32) }
        #expect(RasterID(hex: "abc") == nil && RasterID(hex: String(repeating: "A", count: 64)) == nil)
        #expect(throws: MaskError.self) { try JSONDecoder().decode(RasterID.self, from: Data(#""xyz""#.utf8)) }
    }
}

@Suite struct MaskCompilerTests {
    /// A Light compiler every edit since 2026-10-30 holds, kept supported, whose id is not the masks compiler's.
    private static let otherLight = ManualRenderSettings.currentVersion

    private func masks() throws -> MaskSet {
        try Fixture.set(Mask(id: Fixture.id(1), components: [MaskComponent(shape: Fixture.linear)]))
    }

    @Test func aMaskWithEverySliderAtZeroIsStillAnEditWithItsReference() throws {
        let values = try ManualAdjustments(masks: masks())
        #expect(!values.isIdentity && values != .identity)
        let manual = try ManualRenderSettings(adjustments: values, referenceStops: 0.75)
        #expect(!manual.isIdentity && manual.referenceStops == 0.75 && manual != .identity)
        #expect(ManualAdjustments.identity.masks.isEmpty && ManualRenderSettings.identity.adjustments.masks.isEmpty)
        // No Light value, so no tone tables or base for the panel's own pass.
        #expect(!manual.needsToneTables && !manual.needsToneBase)
    }

    @Test func masksRideThroughEveryOtherEditAndResetLightKeepsThem() throws {
        let set = try masks(), curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        let values = try ManualAdjustments(exposureEV: 0.5, contrast: 10, highlights: -10, shadows: 10, whites: 10, blacks: -10, curves: curves, masks: set)
        #expect(try values.setting(.exposure, to: 1).masks == set)
        #expect(values.settingCurves(.identity).masks == set)
        let cleared = values.clearing(.light)
        #expect(cleared.masks == set && cleared.curves == curves)
        #expect(ManualAdjustments.Control.allCases.allSatisfy { cleared.value(for: $0) == 0 })
        #expect(ManualAdjustments.identity.clearing(.light).isIdentity)
        #expect(values.settingMasks(.empty) != values && values.settingMasks(.empty).masks.isEmpty)
    }

    /// A frame with no masks writes what it wrote: no key, and the JSON of an adjustment is unchanged.
    @Test func noMasksMeansNoKeyAndAReadWithoutOneIsEmpty() throws {
        let plain = try ManualAdjustments(exposureEV: 0.5)
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("masks"))
        #expect(try JSONDecoder().decode(ManualAdjustments.self, from: JSONEncoder().encode(plain)) == plain)
        let masked = try ManualAdjustments(masks: masks())
        #expect(String(decoding: try JSONEncoder().encode(masked), as: UTF8.self).contains("masks"))
        #expect(try JSONDecoder().decode(ManualAdjustments.self, from: JSONEncoder().encode(masked)) == masked)
    }

    @Test func theRenderGraphNamesTheCompilerOnlyWithMasks() throws {
        #expect(MaskSet.currentVersion == "2026-11-06-1")
        let light = ManualRenderSettings.currentVersion, curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        let base = RenderGraph.version
        func version(_ values: ManualAdjustments) throws -> String {
            RenderGraph.version(for: DevelopSettings(manual: try ManualRenderSettings(adjustments: values, referenceStops: 0)))
        }
        let set = try masks()
        #expect(try version(.identity) == base)
        #expect(try version(ManualAdjustments(exposureEV: 1)) == "\(base)+manual-\(light)")
        #expect(try version(ManualAdjustments(curves: curves)) == "\(base)+manual-\(light)+\(curves.version)")
        #expect(try version(ManualAdjustments(masks: set)) == "\(base)+manual-\(light)+masks-2026-11-06-1")
        #expect(try version(ManualAdjustments(exposureEV: 1, masks: set)) == "\(base)+manual-\(light)+masks-2026-11-06-1")
        #expect(try version(ManualAdjustments(curves: curves, masks: set)) == "\(base)+manual-\(light)+\(curves.version)+masks-2026-11-06-1")
        var toned = DevelopSettings(manual: try ManualRenderSettings(adjustments: ManualAdjustments(masks: set), referenceStops: 0))
        toned.tone = PrintTone(burn: 0.5, dodge: 0.5)
        #expect(RenderGraph.version(for: toned) == "\(base)+tone-\(toned.tone.version)+manual-\(light)+masks-2026-11-06-1")
        // A receipt names the same, so a develop it recorded still matches.
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(masks: set), referenceStops: 0)
        #expect(RenderGraph.version(for: DevelopSettings(manual: manual.digestingMasks())) == RenderGraph.version(for: DevelopSettings(manual: manual)))
    }

    /// Only the current Light compiler takes masks. A saved edit on an older one keeps its intent and asks for the update.
    @Test func olderLightCompilersRefuseMasksAndTheCurrentOneTakesThem() throws {
        let set = try masks(), regions = ManualRenderSettings.regionsVersion
        let values = try ManualAdjustments(exposureEV: 0.25, masks: set)
        #expect(throws: MaskError.lightCompiler(regions)) { try ManualRenderSettings(adjustments: values, referenceStops: 0, version: regions) }
        #expect(throws: MaskError.lightCompiler(regions)) { try set.requireRenderable(lightCompiler: regions) }
        #expect(throws: MaskError.lightCompiler(ManualRenderSettings.exposedBaseVersion)) { try set.requireRenderable(lightCompiler: ManualRenderSettings.exposedBaseVersion) }
        try set.requireRenderable(lightCompiler: ManualRenderSettings.currentVersion)
        #expect(MaskError.lightCompiler(regions).errorDescription?.contains("Update Automatic Baseline") == true)
        // No masks: as it always did.
        _ = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.25), referenceStops: 0, version: regions)
        try MaskSet.empty.requireRenderable(lightCompiler: regions)
        // Recorded: the intent reads, and rendering refuses. The masks' own version is another string.
        let saved = try ManualRenderSettings(adjustments: values, referenceStops: 0.5, version: Self.otherLight)
        // The Light compiler and the masks' are both "version", and today the same string: edit the record's own.
        var record = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        record["version"] = regions
        let recorded = try JSONDecoder().decode(ManualRenderSettings.self, from: JSONSerialization.data(withJSONObject: record))
        #expect(recorded.version == regions && recorded.adjustments.masks == set && recorded.referenceStops == 0.5)
        #expect(throws: MaskError.lightCompiler(regions)) { try recorded.validateSupportedVersion() }
        #expect(throws: MaskError.lightCompiler(regions)) { try recorded.applyingScene(to: SIMD3(repeating: 0.18)) }
        // Every other supported compiler: the current one, and the one every edit since 2026-10-30 holds.
        for version in [ManualRenderSettings.currentVersion] {
            let manual = try ManualRenderSettings(adjustments: values, referenceStops: 0, version: version)
            try manual.validateSupportedVersion()
            #expect(manual.version == version)
        }
    }

    @Test func anUnavailableMasksCompilerKeepsItsIntentAndCannotRender() throws {
        let set = try masks()
        #expect(throws: MaskError.unsupportedVersion("future")) { try MaskSet(masks: set.masks, version: "future") }
        let text = try Fixture.json(set).replacingOccurrences(of: #""version":"\#(MaskSet.currentVersion)""#, with: #""version":"future""#)
        let read = try Fixture.decode(text)
        #expect(read.version == "future" && read.masks == set.masks && read != set)
        #expect(throws: MaskError.unsupportedVersion("future")) { try read.requireRenderable(lightCompiler: ManualRenderSettings.currentVersion) }
        #expect(MaskError.unsupportedVersion("future").errorDescription?.contains("Update Automatic Baseline") == true)
        // The explicit updates adopt the current one: Update Automatic Baseline, and Reapply onto new bytes.
        #expect(try read.updatingVersion() == set)
        #expect(try read.forAnotherPicture(freshIDs: false) == set)
        let values = ManualAdjustments.identity.settingMasks(read)
        #expect(throws: MaskError.unsupportedVersion("future")) { try ManualRenderSettings(adjustments: values, referenceStops: 0) }
        let saved = try ManualRenderSettings(adjustments: ManualAdjustments(masks: set), referenceStops: 0, version: Self.otherLight)
        // The masks' own "version", not the Light compiler's, which is today the same string.
        var record = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var adjustments = try #require(record["adjustments"] as? [String: Any])
        var held = try #require(adjustments["masks"] as? [String: Any])
        held["version"] = "future"; adjustments["masks"] = held; record["adjustments"] = adjustments
        let recorded = try JSONDecoder().decode(ManualRenderSettings.self, from: JSONSerialization.data(withJSONObject: record))
        #expect(throws: MaskError.unsupportedVersion("future")) { try recorded.validateSupportedVersion() }
    }
}

@Suite struct MaskGeometryTests {
    @Test func legacyBytesStayAndGeometryRequiresSchemaSix() throws {
        let mask = Mask(id: Fixture.id(1), components: [MaskComponent(shape: Fixture.linear), MaskComponent(shape: try Fixture.brush())])
        let set = try MaskSet(masks: [mask])
        let bytes = try Fixture.json(set)
        let read = try Fixture.decode(bytes)
        #expect(read.masks.flatMap(\.components).allSatisfy { $0.shape.geometry == nil })
        #expect(try Fixture.json(read) == bytes && read.digest == set.digest)
        let geometry = try LensGeometry(table: RadialTable(knots: [1, 0.98]), scale: 1)
        let copied = try set.forAnotherPicture(freshIDs: false, geometry: geometry)
        #expect(copied.masks[0].components.allSatisfy { $0.shape.geometry == geometry })
        #expect(MaskSet.schema(of: copied.masks) == 6 && copied.digest != set.digest)
        let encoded = try Fixture.json(copied)
        #expect(try Fixture.decode(encoded) == copied)
        #expect(throws: MaskError.self) { try Fixture.decode(encoded.replacingOccurrences(of: #""schema":6"#, with: #""schema":5"#)) }
        let cleared = try copied.forAnotherPicture(freshIDs: false)
        #expect(cleared == set)
    }

    @Test func movingShapesMapsPointsAndKeepsSelections() throws {
        let a = try LensGeometry(table: RadialTable(knots: [1, 0.96]), scale: 1)
        let b = try LensGeometry(table: RadialTable(knots: [1, 1]), scale: 1)
        let lens = MaskLens(picture: b, legacy: a, extent: .init(x: 1, y: 2.0 / 3))
        let remap = try #require(lens.toPicture(Fixture.linear))
        guard case .linear(let original) = Fixture.linear,
              case .linear(let moved) = Fixture.linear.moved(in: lens, remeasure: { m, _ in m }) else { Issue.record("linear"); return }
        #expect(moved.full == remap.point(original.full) && moved.zero == remap.point(original.zero) && moved.geometry == b)
        guard case .radial(let radial) = Fixture.radial,
              case .radial(let ellipse) = Fixture.radial.moved(in: lens, remeasure: { m, _ in m }) else { Issue.record("radial"); return }
        let c = remap.point(radial.center)
        let end = remap.point(.init(x: radial.center.x + radial.semiAxisA * cos(radial.angle), y: radial.center.y + radial.semiAxisA * sin(radial.angle)))
        let other = remap.point(.init(x: radial.center.x - radial.semiAxisB * sin(radial.angle), y: radial.center.y + radial.semiAxisB * cos(radial.angle)))
        #expect(ellipse.center == c && ellipse.feather == radial.feather && ellipse.geometry == b)
        #expect(abs(ellipse.semiAxisA - hypot(end.x - c.x, end.y - c.y)) < 1e-7)
        #expect(abs(ellipse.semiAxisB - hypot(other.x - c.x, other.y - c.y)) < 1e-7)
        #expect(abs(ellipse.angle - atan2(end.y - c.y, end.x - c.x)) < 1e-7)
        let brush = try Fixture.brush()
        guard case .brush(let paint) = brush, case .brush(let movedPaint) = brush.moved(in: lens, remeasure: { m, _ in m }) else { Issue.record("brush"); return }
        for (stroke, changed) in zip(paint.strokes, movedPaint.strokes) {
            let mean = stroke.points.points.reduce(Float(0)) { $0 + remap.ratio(at: $1) } / Float(stroke.points.count)
            #expect(abs(changed.radius - stroke.radius * mean) < 1e-7)
            for (p, q) in zip(stroke.points.points, changed.points.points) {
                let at = remap.point(p)
                #expect(hypot(q.x - at.x, q.y - at.y) < 1.0 / 32768)
            }
        }
        #expect(movedPaint.frame.geometry == b)
        let selection = try Fixture.smart()
        #expect(selection.moved(in: lens, remeasure: { m, _ in m }) == selection)
    }

    @Test func movingAMeasuredStrokeKeepsItsTrackedCentroid() throws {
        let picture = try MaskSpace(width: 7008, height: 4672), field = MaskFieldSize(picture: picture)
        let raster = try MaskRaster(width: 32, height: 32, plane: [UInt8](repeating: 255, count: 1024))
        let measured = try MeasuredStroke(raster: raster.ref, x: 250, y: 220, pictureWidth: picture.width, pictureHeight: picture.height)
        let a = try LensGeometry(table: RadialTable(knots: [1, 0.96]), scale: 1)
        let b = try LensGeometry(table: RadialTable(knots: [1, 1]), scale: 1)
        let backward = try #require(LensRemap(from: b, to: a, extent: picture.extent))
        let forward = try #require(LensRemap(from: a, to: b, extent: picture.extent))
        let moved = try measured.moved(raster, by: backward)
        var total: Float = 0, x: Float = 0, y: Float = 0
        for j in 0..<moved.raster.height { for i in 0..<moved.raster.width {
            let v = Float(moved.raster.plane[j * moved.raster.width + i])
            let p = field.point(column: moved.measured.x + i, yTop: moved.measured.y + j)
            total += v; x += v * p.x; y += v * p.y
        } }
        let original = MaskPoint(x: Float(measured.x + 16) * field.texelToPoint.x, y: Float(measured.y + 16) * field.texelToPoint.y)
        let tracked = forward.point(original)
        #expect(hypot(x / total - tracked.x, y / total - tracked.y) * 2048 < 1)
        #expect(moved.measured.pictureWidth == picture.width && moved.measured.pictureHeight == picture.height)
    }
}

extension MaskValidationTests {
    @Test func refusesLensSettingsInsideAMask() throws {
        let mask = Mask(components: [MaskComponent(shape: Fixture.linear)],
                        adjustments: .identity.settingLens(try LensSettings(arguments: "distortion=off")))
        #expect(throws: MaskError.self) { try MaskSet(masks: [mask]) }
        let valid = try Fixture.json(Fixture.set(Mask(components: [MaskComponent(shape: Fixture.linear)])))
        let bad = valid.replacingOccurrences(of: "\"exposureEV\":0", with: "\"exposureEV\":0,\"lens\":{\"distortion\":{\"on\":false}}")
        #expect(bad != valid)
        #expect(throws: (any Error).self) { try Fixture.decode(bad) }
    }
}
