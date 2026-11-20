import CryptoKit
import Foundation
import Metal

// Where each mask acts, as one field the masked kernels share: `rgba16Float`, a `.type2DArray` of 2048 px on the picture's long side,
// four masks a slice, mask k in slice k / 4, channel k % 4, about 5.3 MiB a mask on a 3:2 frame (never a frame-sized texture per mask).
// Row 0 is the picture's bottom, as a frame texture's, so a kernel samples at its own pixel's uv with no flip. Each mask composes its
// components here: gradients analytically, a brush from its canvas (`BrushCanvas`), a smart selection from its refined field on the
// decode (`MaskRefiner`, tier 1), at the slice's own texels. A Follow edges stroke is laid on its brush's canvas from the shape it
// measured (`MeasuredStroke`), so a brush reads no decode either way; one with no measured shape refuses.
//
// A field of gradients and brushes is a function of the point in `MaskSpace` alone, so it depends on the picture only through which
// point a texel is. A smart selection's also reads the decode's light at the texel, so its field belongs to one decode
// (`MaskFieldKey.guide`).

/// A shape this build has no bake for. It refuses, because baking it as zero would print a frame without the mask's adjustment.
public enum MaskCoverageError: Error, Sendable, LocalizedError, Equatable, CustomStringConvertible {
    case unbakedShape(String)
    /// A Follow edges stroke that kept no measured shape: none is ever written (a stroke measures as it ends), so it is refused rather
    /// than laid as a plain one, which would paint across the edges it was meant to follow.
    case unmeasuredStroke

    public var errorDescription: String? {
        switch self {
        case .unbakedShape(let shape): return "This frame has a \(shape) mask, and this build cannot bake its coverage yet."
        case .unmeasuredStroke: return "A brush mask on this frame has a Follow edges stroke with no measured shape, so it cannot be baked."
        }
    }
    public var description: String { errorDescription ?? "These masks cannot be baked." }
}

/// The profiles measured from Lightroom (plan section 6; `docs/provenance.md`). They live here only: the kernel receives them
/// through `MaskBakeComponent`.
public enum MaskProfiles {
    /// Linear: `c = 1 − S((t − a)/(b − a))`, S the cosine step, t 0 at Full and 1 at Zero.
    public static let linear: (a: Float, b: Float) = (-0.046, 0.971)
    /// Radial: `c = 1 − smootherstep((n − a)/(b − a))`, n the elliptical radius, (a, b) by Feather, linear between knots. Feather 0
    /// is the hard edge, a smoothstep over 0.6 % of the radius, because Lightroom's edge scales with the picture.
    public static let radialKnots: [(feather: Float, a: Float, b: Float)] = [
        (0, 0.994, 1.003), (5, 0.942, 1.032), (10, 0.849, 1.082), (15, 0.725, 1.149), (20, 0.606, 1.212), (25, 0.492, 1.269),
        (35, 0.309, 1.351), (50, 0.192, 1.389), (60, 0.058, 1.443), (75, -0.142, 1.501), (85, -0.246, 1.503), (100, -0.354, 1.453),
    ]
    /// The first knot past Feather 0, where the step is all smootherstep.
    static let smootherFrom: Float = 5

    /// The (a, b) for `feather`, and the share of smootherstep in the step: 0 at Feather 0, 1 from Feather 5. Lightroom's Feather 0
    /// and 5 were measured and nothing between them (inference): (a, b) and the step run linearly from one to the other, so a slider
    /// dragged through them moves the field with no jump.
    public static func radial(feather: Float) -> (a: Float, b: Float, smootherShare: Float) {
        let f = min(max(feather, radialKnots[0].feather), radialKnots[radialKnots.count - 1].feather)
        let above = radialKnots.firstIndex { $0.feather >= f } ?? radialKnots.count - 1
        let share = min(f / smootherFrom, 1)
        guard above > 0 else { return (radialKnots[0].a, radialKnots[0].b, share) }
        let low = radialKnots[above - 1], high = radialKnots[above]
        let s = (f - low.feather) / (high.feather - low.feather)
        return (low.a + (high.a - low.a) * s, low.b + (high.b - low.b) * s, share)
    }
}

/// One component as the kernel takes it, `struct MaskBakeComponent` in `ShaderSource.maskCoverage`, 48 bytes.
struct MaskBakeComponent {
    var kind: UInt32
    var operation: UInt32
    var origin: SIMD2<Float>
    var axisU: SIMD2<Float>
    var axisV: SIMD2<Float>
    var start: Float
    var scale: Float
    var smootherShare: Float
    var complement: UInt32

    /// The component's value at `q`, as `mask_component` makes it.
    func value(at q: SIMD2<Float>) -> Float {
        let d = q - origin
        if kind == 0 {
            let x = Self.unit(((d * axisU).sum() - start) * scale)
            return 0.5 + 0.5 * cos(3.14159265 * x)
        }
        let e = SIMD2<Float>((d * axisU).sum(), (d * axisV).sum())
        let x = Self.unit(((e * e).sum().squareRoot() - start) * scale)
        let smooth = x * x * (3 - 2 * x)
        let smoother = x * x * x * (x * (x * 6 - 15) + 10)
        let v = 1 - (smooth + (smoother - smooth) * smootherShare)
        return complement != 0 ? 1 - v : v
    }

    private static func unit(_ x: Float) -> Float { min(max(x, 0), 1) }
}

/// What a raster component reads: a brush's strokes, made into a canvas by the field cache; or a smart selection, made into its refined
/// field on the decode by the render's refinement (`MaskRefinementSession.field(for:)`).
enum MaskRasterSource: Sendable, Hashable {
    case brush([BrushStroke])
    case refined(SmartSelection)
}

/// A mask's coverage compiled for the kernel and the CPU reference, which run the same numbers. Compiling is where the rules for
/// Invert and Intersect live, so neither copy of the arithmetic knows them:
/// - a linear's Invert swaps its Full and Zero, `profile(1 − t)`, which is not `1 − v` since the profile is asymmetric; a radial's and a
///   brush's is `1 − v`;
/// - Intersect is Subtract of the inverse, `c·(1 − inv v)`, as Lightroom stores it.
///
/// A brush is a raster component (kind 2) reading its canvas at the texel, or, with no stroke yet, the constant 0 (kind 3). A smart
/// selection is a raster component reading its refined field, whose invert is `1 − v` and Background's `1 − v` of Subject's; with
/// `substitute` it is the constant `substitute` instead, the two fields tier 2 composes a refined value with (`MaskSlots.composed`). A
/// mask with no raster bakes through Phase 1's `mask_bake`, unchanged.
struct MaskProgram {
    let components: [MaskBakeComponent]
    /// What each raster component reads, in order of first use; at most `BrushPipelines.rasterSlots`.
    let rasters: [MaskRasterSource]
    /// For each component, the index of its raster in `rasters`; 0 for one that reads none.
    let rasterOf: [UInt32]
    let remaps: [LensRemap]
    let remapOf: [UInt32]

    var hasRasters: Bool { components.contains { $0.kind >= 2 } }
    /// The smart selections the program reads, in order of first use.
    var selections: [SmartSelection] { rasters.compactMap { if case .refined(let selection) = $0 { return selection } else { return nil } } }
    /// Whether the program reads a smart selection's refined field, which only a bake with the render's refinement can make.
    var isRefined: Bool { !selections.isEmpty }
    /// Whether the refined field depends on the decode. A `matte` is the stored alpha: it reads none, so its field is the picture's, whichever
    /// decode renders it.
    var readsDecode: Bool { selections.contains { $0.edge != .matte } }

    init(_ coverage: Mask.Coverage, substitute: Float? = nil, lens: MaskLens? = nil) throws {
        var rasters: [MaskRasterSource] = [], rasterOf: [UInt32] = []
        var remaps: [LensRemap] = [], remapOf: [UInt32] = []
        components = try coverage.components.map { component in
            let inverted = component.invert != (component.operation == .intersect)
            let operation: UInt32 = component.operation == .add ? 0 : 1
            var raster: UInt32 = 0
            defer { rasterOf.append(raster) }
            let maps: Bool
            switch component.shape {
            case .linear, .radial: maps = true
            case .brush(let paint): maps = !paint.strokes.isEmpty
            case .smart: maps = false
            }
            if maps, let r = lens?.toMask(component.shape) {
                if let at = remaps.firstIndex(of: r) { remapOf.append(UInt32(at + 1)) }
                else { remapOf.append(UInt32(remaps.count + 1)); remaps.append(r) }
            } else { remapOf.append(0) }
            switch component.shape {
            case .linear(let g):
                let (from, to) = inverted ? (g.zero, g.full) : (g.full, g.zero)
                let dx = Double(to.x) - Double(from.x), dy = Double(to.y) - Double(from.y)
                let square = dx * dx + dy * dy
                let p = MaskProfiles.linear
                return MaskBakeComponent(kind: 0, operation: operation, origin: SIMD2(from.x, from.y),
                                         axisU: SIMD2(Float(dx / square), Float(dy / square)), axisV: .zero,
                                         start: p.a, scale: Float(1 / (Double(p.b) - Double(p.a))), smootherShare: 0, complement: 0)
            case .radial(let g):
                let p = MaskProfiles.radial(feather: g.feather)
                let cosine = cos(Double(g.angle)), sine = sin(Double(g.angle))
                let a = Double(g.semiAxisA), b = Double(g.semiAxisB)
                return MaskBakeComponent(kind: 1, operation: operation, origin: SIMD2(g.center.x, g.center.y),
                                         axisU: SIMD2(Float(cosine / a), Float(sine / a)), axisV: SIMD2(Float(-sine / b), Float(cosine / b)),
                                         start: p.a, scale: Float(1 / (Double(p.b) - Double(p.a))), smootherShare: p.smootherShare,
                                         complement: inverted ? 1 : 0)
            case .brush(let paint):
                // A Follow edges stroke is laid from its measured shape with the brush's canvas, which refuses one that has none.
                guard !paint.strokes.isEmpty else {
                    return MaskBakeComponent(kind: 3, operation: operation, origin: .zero, axisU: .zero, axisV: .zero, start: 0, scale: 0,
                                             smootherShare: 0, complement: inverted ? 1 : 0)
                }
                let source = MaskRasterSource.brush(paint.strokes)
                if let at = rasters.firstIndex(of: source) {
                    raster = UInt32(at)
                } else {
                    raster = UInt32(rasters.count)
                    rasters.append(source)
                }
                return MaskBakeComponent(kind: 2, operation: operation, origin: .zero, axisU: .zero, axisV: .zero, start: 0, scale: 0,
                                         smootherShare: 0, complement: inverted ? 1 : 0)
            case .smart(let selection):
                guard selection.raster != nil else { throw MaskRefinerError.selectionPending(selection.kind) }
                let complement: UInt32 = inverted != selection.kind.invertsSeed ? 1 : 0
                if let substitute {
                    return MaskBakeComponent(kind: 3, operation: operation, origin: .zero, axisU: .zero, axisV: .zero, start: substitute,
                                             scale: 0, smootherShare: 0, complement: complement)
                }
                let source = MaskRasterSource.refined(selection)
                if let at = rasters.firstIndex(of: source) {
                    raster = UInt32(at)
                } else {
                    raster = UInt32(rasters.count)
                    rasters.append(source)
                }
                return MaskBakeComponent(kind: 2, operation: operation, origin: .zero, axisU: .zero, axisV: .zero, start: 0, scale: 0,
                                         smootherShare: 0, complement: complement)
            }
        }
        self.rasters = rasters
        self.rasterOf = rasterOf
        self.remaps = remaps
        self.remapOf = remapOf
    }

    /// The mask's coverage at `q`, left to right from 0, as `mask_compose` and `mask_bake_raster` make it. `raster(i, q)` is raster i's
    /// value there, before any invert; a program without rasters never asks.
    func coverage(at q: SIMD2<Float>, raster: (Int, SIMD2<Float>) -> Float = { _, _ in preconditionFailure("a raster needs its values") }) -> Float {
        var c: Float = 0
        for (index, component) in components.enumerated() {
            let mapped = remapOf[index] == 0 ? MaskPoint(x: q.x, y: q.y) : remaps[Int(remapOf[index]) - 1].point(MaskPoint(x: q.x, y: q.y))
            let p = SIMD2(mapped.x, mapped.y)
            let v: Float
            switch component.kind {
            case 0, 1: v = component.value(at: p)
            default:
                let held = component.kind == 2 ? raster(Int(rasterOf[index]), p) : component.start
                v = component.complement != 0 ? 1 - held : held
            }
            c = component.operation == 0 ? c + v - c * v : c * (1 - v)
        }
        return min(max(c, 0), 1)
    }

    /// The CPU's values of each raster, for `coverage(at:raster:)`, a Follow edges stroke's measured shape read from `shapes`. A refined
    /// field reads a decode and has none: callers refuse it first.
    func referenceRasters(shapes: (any MaskSeedProvider)? = nil) throws -> [BrushField] {
        try rasters.map { source in
            switch source {
            case .brush(let strokes): try BrushField(strokes, shapes: shapes)
            case .refined: preconditionFailure("the analytic reference refuses smart selections")
            }
        }
    }
}

/// The size of a field and what its texels are: the slice's pixels, and the part of `MaskSpace` they span. The long side is always
/// 2048, whatever the render's size, so a field does not depend on which render asked for it.
public struct MaskFieldSize: Sendable, Equatable, Hashable {
    public static let longSide = 2048

    public let width: Int
    public let height: Int
    /// The picture's bottom right corner in `MaskSpace`, `(W/L, H/L)`. It is the picture's own aspect, not the slice's, which rounds
    /// it to a texel: a render's uv then reaches the same point of the mask on every field.
    public let extent: MaskPoint

    public init(picture: MaskSpace) {
        let long = Double(picture.longSide), side = Double(Self.longSide)
        width = max(1, Int((Double(picture.width) * side / long).rounded()))
        height = max(1, Int((Double(picture.height) * side / long).rounded()))
        extent = picture.extent
    }

    /// Eight bytes a texel, four masks a slice.
    public var bytesPerSlice: Int { width * height * 8 }

    /// `MaskSpace` long sides per slice texel, on each axis.
    var texelToPoint: SIMD2<Float> { SIMD2(extent.x / Float(width), extent.y / Float(height)) }

    /// The point of the mask at a texel's centre, `yTop` rows from the slice's top; the same sum as `mask_bake`'s.
    public func point(column: Int, yTop: Int) -> MaskPoint {
        let q = (SIMD2<Float>(Float(column), Float(yTop)) + 0.5) * texelToPoint
        return MaskPoint(x: q.x, y: q.y)
    }
}

/// What a field is, the whole of its cache key. It holds no slider, Amount, on/off, name or mask id, so nothing but a change of
/// shape misses, and an undo or a copy with the same shape hits. Gradients and brushes do not read the picture, so a field of only those
/// holds no decode and every render of the picture shares it; a smart selection's refinement reads the decode, so its field holds it.
public struct MaskFieldKey: Sendable, Equatable, Hashable {
    public let size: MaskFieldSize
    public let version: String
    public let coverage: Mask.Coverage
    /// The decode a smart selection's refinement read; `nil` for a field that reads none.
    public let guide: MaskGuideID?
    /// For tier 2's composed fields, the constant each smart selection is taken as, 0 or 1, in place of its refinement; such a field
    /// reads no decode. `nil` for a mask's own field.
    public let substitute: Float?
    public let lens: MaskLens?

    public init(size: MaskFieldSize, version: String, coverage: Mask.Coverage, guide: MaskGuideID? = nil, substitute: Float? = nil, lens: MaskLens? = nil) {
        self.size = size; self.version = version; self.coverage = coverage; self.guide = guide; self.substitute = substitute; self.lens = lens
    }

    var program: MaskProgram { get throws { try MaskProgram(coverage, substitute: substitute, lens: lens) } }
}

/// What the kernels need from a `MaskSet`: which mask sits where, and how many slices to read. Slot k is `masks[k]` in list order, in
/// slice k / 4, channel k % 4, on or off, so turning a mask off or on moves no other mask.
///
/// A mask that is off keeps its slot and has no field here: its sliders are already 0 through `Mask.scaledValue`, so a kernel's
/// `c · 0` does not read what its channel holds, and it needs no bake. Its channel holds 0 or an old field, always a finite coverage.
public struct MaskSlots: Sendable, Equatable {
    public struct Slot: Sendable, Equatable {
        public let index: Int
        public let maskID: UUID
        /// `nil` for a mask that is off.
        public let field: MaskFieldKey?
        public var slice: Int { index / MaskCoverage.masksPerSlice }
        public var channel: Int { index % MaskCoverage.masksPerSlice }
    }

    /// Tier 2 for a smart selection composed with other components: the mask's coverage is affine in the selection's refined value v,
    /// `c = c0 + (c1 − c0) · v`, where c0 and c1 are the mask baked with v taken as 0 and as 1. They read no decode, and sit in two slots
    /// after the masks', `low` and `low + 1`, with no slider of their own.
    public struct Composed: Sendable, Equatable {
        public let mask: Int
        public let low: Int
    }

    public let size: MaskFieldSize
    public let version: String
    /// The masks' slots, then the composed fields' (`composed`).
    public let slots: [Slot]
    /// The masks' own slots, `slots`' first `maskCount`.
    public let maskCount: Int
    public let composed: [Composed]

    /// Refuses a receipt's digest, a compiler this build lacks, and a mask that is on whose shape this build cannot bake or whose smart
    /// selection has not been made. A shape that is off is not read, so a brush turned off does not stop the frame. `guide` is the decode
    /// a smart selection is refined on; without one such a field has none and only a bake given the refinement can make it. `perPixel`
    /// adds the composed fields of the masks `MaskRefiner.perPixelPlan` evaluates per pixel: a frame that takes tier 2 at all.
    public init(masks: MaskSet, picture: MaskSpace, lens: MaskLens? = nil, guide: MaskGuideID? = nil, perPixel: Bool = true) throws {
        if masks.isDigestOnly { throw MaskError.digestOnly }
        guard MaskSet.supports(version: masks.version) else { throw MaskError.unsupportedVersion(masks.version) }
        let size = MaskFieldSize(picture: picture), version = masks.version
        var slots = try masks.masks.enumerated().map { index, mask in
            guard mask.isEnabled else { return Slot(index: index, maskID: mask.id, field: nil) }
            let readsDecode = try MaskProgram(mask.coverage).readsDecode
            let mapped = lens.flatMap { l in mask.components.contains { l.toMask($0.shape) != nil } ? l : nil }
            return Slot(index: index, maskID: mask.id,
                        field: MaskFieldKey(size: size, version: version, coverage: mask.coverage, guide: readsDecode ? guide : nil, lens: mapped))
        }
        var composed: [Composed] = []
        if perPixel {
            for plan in MaskRefiner.perPixelPlan(masks.masks) where plan.composedLow != nil {
                let mask = masks.masks[plan.slot], low = slots.count
                composed.append(Composed(mask: plan.slot, low: low))
                let mapped = lens.flatMap { l in mask.components.contains { l.toMask($0.shape) != nil } ? l : nil }
                for value: Float in [0, 1] {
                    slots.append(Slot(index: slots.count, maskID: mask.id,
                                      field: MaskFieldKey(size: size, version: version, coverage: mask.coverage, substitute: value, lens: mapped)))
                }
            }
        }
        self.slots = slots
        self.maskCount = masks.masks.count
        self.composed = composed
        self.size = size
        self.version = version
    }

    /// How many slices hold a slot. A kernel reads this many, and multiplies a slot past the last by 0.
    public var sliceCount: Int { (slots.count + MaskCoverage.masksPerSlice - 1) / MaskCoverage.masksPerSlice }

    /// Whether a slot that is on reads a smart selection's refinement, whose bake needs the decode's.
    public var needsRefinement: Bool {
        slots.contains { slot in
            guard let field = slot.field, field.substitute == nil else { return false }
            return field.coverage.components.contains { if case .smart = $0.shape { return true } else { return false } }
        }
    }

    /// Each different list of strokes among the brushes of the masks that are on: a bake lays one canvas for each.
    private var brushStrokeLists: Set<[BrushStroke]> {
        var lists = Set<[BrushStroke]>()
        for slot in slots {
            for component in slot.field?.coverage.components ?? [] {
                if case .brush(let paint) = component.shape, !paint.strokes.isEmpty { lists.insert(paint.strokes) }
            }
        }
        return lists
    }

    /// The brush canvases a bake of these slots holds at once when none is kept, as in a develop: one for each different list of
    /// strokes among the masks that are on, `BrushCanvas.byteCount` each (5.3 MiB on a 3:2 frame).
    public var brushCanvasBytes: Int { brushStrokeLists.count * BrushCanvas.byteCount(size) }

    /// The measured shapes of the Follow edges strokes a bake of these slots lays when no canvas is kept, as in a develop: their bytes,
    /// which the laying holds in buffers beside the seeds it read them from, and a second canvas for each brush that has any.
    public var measuredShapeBytes: Int {
        // With a second canvas while a brush that mixes them is laid in segments (`FollowEdgesReplay`).
        brushStrokeLists.reduce(0) { total, strokes in
            guard strokes.contains(where: \.followEdges) else { return total }
            return total + BrushCanvas.byteCount(size) + strokes.reduce(0) { $0 + ($1.measured.map { $0.raster.width * $0.raster.height } ?? 0) }
        }
    }

    /// The masks that are on. With none, every slider is 0 and a render can pick today's kernels.
    public var activeCount: Int { slots.prefix(maskCount).reduce(0) { $0 + ($1.field == nil ? 0 : 1) } }

    /// What the kernels read, for the render key: SHA-256 of the compiler, the field's size and aspect, and each slot's shape, written
    /// by hand so it holds across runs, as `MaskSet.digest` is. It holds no slider. A slot that is off has no bytes but its place.
    public var identity: String {
        var bytes = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
        func float(_ v: Float) { u32((v == 0 ? 0 : v).bitPattern) }   // one zero for both signs, as equality has it
        func point(_ p: MaskPoint) { float(p.x); float(p.y) }
        func text(_ s: String) { let b = Data(s.utf8); u32(UInt32(b.count)); bytes.append(b) }
        text("ARGENT-COVERAGE"); text(version)
        u32(UInt32(size.width)); u32(UInt32(size.height)); point(size.extent); u32(UInt32(slots.count))
        for slot in slots {
            guard let field = slot.field else { text("off"); continue }
            u32(UInt32(field.coverage.components.count))
            for component in field.coverage.components {
                text(component.operation.rawValue); bytes.append(component.invert ? 1 : 0)
                switch component.shape {
                case .linear(let g): text("linear"); point(g.full); point(g.zero)
                case .radial(let g): text("radial"); point(g.center); float(g.semiAxisA); float(g.semiAxisB); float(g.angle); float(g.feather)
                case .brush(let paint):
                    // The strokes alone: the frame they were painted on moves no pixel.
                    text("brush"); u32(UInt32(paint.strokes.count))
                    for stroke in paint.strokes {
                        bytes.append(stroke.erase ? 1 : 0); bytes.append(stroke.followEdges ? 1 : 0)
                        float(stroke.radius); float(stroke.feather); float(stroke.flow)
                        u32(UInt32(stroke.points.count)); u32(UInt32(stroke.points.bytes.count)); bytes.append(stroke.points.bytes)
                        // Only when set, as the digest has it.
                        if let m = stroke.measured {
                            text("measured"); text(m.raster.id.hex); u32(UInt32(m.raster.width)); u32(UInt32(m.raster.height))
                            u32(UInt32(m.x)); u32(UInt32(m.y)); u32(UInt32(m.pictureWidth)); u32(UInt32(m.pictureHeight))
                        }
                    }
                case .smart(let selection):
                    // The seed and the refinement it takes; the decode it is refined on is the render key's own.
                    guard let raster = selection.raster else { preconditionFailure("MaskSlots refuses a pending selection") }
                    let p = MaskRefineParameters.of(selection.kind)
                    text("smart"); text(selection.kind.rawValue); text(raster.id.hex); u32(UInt32(raster.width)); u32(UInt32(raster.height))
                    float(p.radiusShare); float(p.epsilon); u32(UInt32(p.grid))
                    if selection.feather != 0 { text("feather"); float(selection.feather) }   // only when set, as the digest has it
                    if selection.edge != .guided { text("edge"); text(selection.edge.rawValue) }   // only when set, as the digest has it
                }
                if field.lens != nil, let geometry = component.shape.geometry { text("geometry"); text(geometry.digest) }
            }
            if let lens = field.lens { text("lens"); text(lens.picture.digest); text(lens.legacy.digest) }
            if let substitute = field.substitute { text("substitute"); float(substitute) }
        }
        return MaskSet.hex(SHA256.hash(data: bytes))
    }
}

/// One array of slices in the cache. Its fields change only under the cache's lock while nothing else holds it.
final class MaskCoverageSlices {
    let texture: MTLTexture
    let size: MaskFieldSize
    /// What each slot holds: `nil` for 0 everywhere. A slot past the masks of the set it was baked for keeps its field, for an undo.
    var fields: [MaskFieldKey?]
    /// The mask each slot was last baked or asked for: a new shape from the same mask replaces its old field where it lies.
    var owners: [UUID?]

    init(texture: MTLTexture, size: MaskFieldSize) {
        self.texture = texture
        self.size = size
        let slots = texture.arrayLength * MaskCoverage.masksPerSlice
        fields = Array(repeating: nil, count: slots)
        owners = Array(repeating: nil, count: slots)
    }

    var byteCount: Int { texture.width * texture.height * texture.arrayLength * 8 }
    func hasShape(of size: MaskFieldSize) -> Bool { texture.width == size.width && texture.height == size.height }

    /// Whether this array already holds everything `slots` will read. A slot that is off reads nothing, so it matches anything: that
    /// is why turning a mask off or on again rebuilds nothing.
    func serves(_ slots: MaskSlots) -> Bool {
        guard hasShape(of: slots.size), texture.arrayLength >= slots.sliceCount else { return false }
        return slots.slots.allSatisfy { $0.field == nil || fields[$0.index] == $0.field }
    }
}

/// The coverage of one `MaskSet` on one picture, ready to bind, and held for as long as a render needs it. While any of these is alive
/// its bytes do not change, so keep one until the GPU has finished with the render and no longer: a cached array held across frames
/// makes the next drag allocate. Safe to use from any thread.
public final class MaskCoverage: @unchecked Sendable {
    public static let masksPerSlice = 4
    public static let pixelFormat = MTLPixelFormat.rgba16Float

    private let slices: MaskCoverageSlices
    public let slots: MaskSlots

    init(slices: MaskCoverageSlices, slots: MaskSlots) {
        self.slices = slices
        self.slots = slots
    }

    /// `.type2DArray`, `.rgba16Float`, at least `sliceCount` slices. Sample it bilinear with clamped edges at a pixel's
    /// `(gid + 0.5) / frameSize`, unflipped, since a frame texture and a slice both hold the picture's bottom in row 0.
    public var texture: MTLTexture { slices.texture }
    public var sliceCount: Int { slots.sliceCount }
    /// For the render key: `MaskSlots.identity`, which needs no GPU and can be taken before a bake.
    public var identity: String { slots.identity }

    /// A slot's coverage read back, top row first (the flip at download), width by height of `slots.size`. For the overlay and tests;
    /// a slot that is off reads as whatever its channel holds.
    public func values(slot: Int) -> [Float] {
        let width = texture.width, height = texture.height, channel = slot % Self.masksPerSlice
        var halves = [Float16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 8, bytesPerImage: 0,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: slot / Self.masksPerSlice)
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (height - 1 - y) * width
            for x in 0..<width { out[y * width + x] = Float(halves[(row + x) * 4 + channel]) }
        }
        return out
    }

    /// A mask's coverage at one point of `MaskSpace` on the CPU: the arithmetic the kernel runs, on the numbers it receives, in
    /// `Float` as it is, ignoring `isEnabled`. Refuses the shapes the bake refuses.
    public static func reference(_ mask: Mask, at point: MaskPoint, shapes: (any MaskSeedProvider)? = nil, lens: MaskLens? = nil) throws -> Float {
        try reference(mask, at: [point], shapes: shapes, lens: lens)[0]
    }

    /// `reference(_:at:)` at many points, compiled once: a brush's dabs are made again from its strokes for each call, and a Follow edges
    /// stroke's measured shape read from `shapes`. Refuses a smart selection, whose coverage reads a decode: read its field back instead
    /// (`values(slot:)`).
    public static func reference(_ mask: Mask, at points: [MaskPoint], shapes: (any MaskSeedProvider)? = nil, lens: MaskLens? = nil) throws -> [Float] {
        let program = try analytic(mask, lens: lens), rasters = try program.referenceRasters(shapes: shapes)
        return points.map { point in program.coverage(at: SIMD2(point.x, point.y)) { rasters[$0].value(at: $1) } }
    }

    private static func analytic(_ mask: Mask, lens: MaskLens? = nil) throws -> MaskProgram {
        let program = try MaskProgram(mask.coverage, lens: lens)
        guard !program.isRefined else { throw MaskCoverageError.unbakedShape("smart") }
        return program
    }

    /// `reference` at the centre of every pixel of a picture `width` by `height` pixels, top row first: pixel (x, y) at
    /// `((x + 0.5) / L, (y + 0.5) / L)`, L the longer side, as `MaskSpace.point(column:yTop:)` puts it. The program is compiled once,
    /// not a pixel at a time. For the overlay and the list's thumbnails, whose red is then the arithmetic the print reads.
    public static func reference(_ mask: Mask, width: Int, height: Int, shapes: (any MaskSeedProvider)? = nil, lens: MaskLens? = nil) throws -> [Float] {
        guard width > 0, height > 0 else { return [] }
        let program = try analytic(mask, lens: lens), long = Float(max(width, height)), rasters = try program.referenceRasters(shapes: shapes)
        var out = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let y = (Float(row) + 0.5) / long
            for column in 0..<width {
                out[row * width + column] = program.coverage(at: SIMD2((Float(column) + 0.5) / long, y)) { rasters[$0].value(at: $1) }
            }
        }
        return out
    }
}

/// Bakes coverage and keeps it: a slider never rebuilds a field (plan section 4, rule 2). One per `GPU` (`GPU.maskFields`).
///
/// A request is answered by the first of these that applies:
/// 1. An array already holds every field the set will read. Nothing runs: this is a slider, Amount, or a mask turned off or on.
/// 2. No render holds an array whose one wrong slot is this mask's old shape, or is empty. That channel alone is written: a drag.
/// 3. A new array, unless that would pass `maximumBytes`, then the oldest no render holds, written over. Each slot takes its field by
///    value from wherever it lies, and only a field held nowhere is baked. So deleting a mask from the middle bakes nothing, and
///    leaves the old array for an undo.
///
/// Why arrays and not a texture a field: the kernels need four masks a slice, and a second copy of each field would cost 5.3 MiB a mask.
/// Not `TexturePool`, which makes only single 2D textures and whose `byteCount` assumes one slice. Only an array no render holds is
/// written, so a render never sees a field change under it; a drag needs a second array only while a render is in flight.
///
/// The limit never refuses a request: a set larger than it is baked and handed over, and goes with its lease. Eviction frees an array
/// once the last render holding it lets go. Safe to call from any thread: one lock, held through a bake's GPU wait, a few milliseconds
/// at most (measured under load), so two lanes asking for the same field bake it once.
///
/// **Brush canvases** are kept here too, keyed by their strokes (`BrushCanvasKey`), so a field rebaked for another component's sake
/// lays no stroke again. A canvas is found, in order: a stroke in progress's, registered by its session for the print and never kept
/// (`register(live:)`); one kept; one kept whose strokes this one's begin with, continued with the rest; else laid from nothing. A
/// finished stroke's canvas is kept as its session ends (`keep`), so the bake after the stroke lays nothing. Canvases take at most
/// half of `maximumBytes`, and at most `defaultCanvasBytes`: none in a develop, whose limit is 0.
public final class MaskFieldCache: @unchecked Sendable {
    /// What the cache has done since it was made, to prove what it did not.
    public struct Statistics: Sendable, Equatable {
        public var hits = 0
        /// Fields computed. A mask's channel counts one, whatever its components.
        public var bakes = 0
        /// Fields moved from one slot to another without computing them.
        public var moves = 0
        public var allocations = 0
        /// The GPU time of the last command buffer that wrote anything.
        public var lastGPUSeconds: Double = 0
        /// Brush canvases laid from strokes (`BrushReplay`), from nothing or continuing a kept one, and the strokes they laid.
        public var replays = 0
        public var strokesReplayed = 0
        /// Brush canvases found already made: kept, or a stroke in progress's.
        public var canvasHits = 0
    }

    /// Two arrays of 16 masks on a 3:2 frame, 179 MB: a drag while a render is in flight needs both. A develop needs one, 89 MB, and
    /// should say so (`GPU.maskFields.maximumBytes`), since it has about 120 MiB of headroom: past the limit it writes over its last frame's.
    public static let defaultMaximumBytes = 2 * 4 * 2048 * 1365 * 8
    /// Twelve brush canvases on a 3:2 frame, 67 MB: a mask's few brushes, an undo's, and a stroke's base.
    public static let defaultCanvasBytes = 12 * 2048 * 1365 * 2

    private struct Pipelines {
        let bake: MTLComputePipelineState
        let move: MTLComputePipelineState
        let moveWithin: MTLComputePipelineState
        let clear: MTLComputePipelineState
    }

    private struct Params {
        var texelToPoint: SIMD2<Float>
        var fieldHeight: UInt32
        var count: UInt32
        var slice: UInt32
        var channel: UInt32
    }

    private struct Move {
        var sourceSlice: UInt32
        var sourceChannel: UInt32
        var targetSlice: UInt32
        var targetChannel: UInt32
    }

    private enum Fill {
        case bake(MaskProgram, slot: Int)
        case move(from: MaskCoverageSlices, slot: Int, to: Int)
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let lock = NSLock()
    private var pipelines: Pipelines?
    private var brush: BrushPipelines?
    private var remap: (bake: MTLComputePipelineState, placeholder: MTLTexture)?
    private var follow: FollowEdgesPipelines?
    /// Oldest first.
    private var entries: [MaskCoverageSlices] = []
    /// Brush canvases, least recently used first.
    private var canvases: [BrushCanvas] = []
    /// Strokes in progress' canvases, as their sessions registered them for the print. Never written while registered; never kept.
    private var live: [BrushCanvas] = []
    private let liveLock = NSLock()
    private var limit: Int
    private var counts = Statistics()

    public init(device: MTLDevice, queue: MTLCommandQueue, maximumBytes: Int = MaskFieldCache.defaultMaximumBytes) {
        self.device = device
        self.queue = queue
        self.limit = maximumBytes
    }

    public var statistics: Statistics { lock.withLock { counts } }
    /// Whether anything has been asked of Metal yet. A frame with no masks leaves this false.
    var hasPipelines: Bool { lock.withLock { pipelines != nil } }
    /// The bytes the cache holds, arrays and brush canvases. An array it has let go of that a render still holds is not among them.
    public var residentBytes: Int { lock.withLock { entries.reduce(0) { $0 + $1.byteCount } + canvases.reduce(0) { $0 + $1.byteCount } } }
    /// The brush canvases' share of `residentBytes`.
    public var canvasBytes: Int { lock.withLock { canvases.reduce(0) { $0 + $1.byteCount } } }
    /// Changing it evicts at once if it must.
    public var maximumBytes: Int {
        get { lock.withLock { limit } }
        set { lock.withLock { limit = newValue; evict(to: newValue) } }
    }

    /// The coverage of `masks` on a picture of that size, or `nil` for a set with no masks, which touches no Metal object. Pass the
    /// full-size picture's size from every render of it where it is known, so previews and the develop share one field; a render's
    /// own size also works, and differs only by its rounding of the aspect (and a field of its own unless the aspect is the same).
    ///
    /// A smart selection's field is its refinement on the decode `refinement` reads (`MaskRefiner.session`): one a decode, kept like any
    /// other, so a slider still bakes nothing. Without `refinement` a set with a smart selection that is on refuses, before Metal.
    public func coverage(for masks: MaskSet, picture: MaskSpace, lens: MaskLens? = nil, refinement: MaskRefinementSession? = nil) throws -> MaskCoverage? {
        guard !masks.isEmpty else { return nil }
        return try coverage(for: MaskSlots(masks: masks, picture: picture, lens: lens, guide: refinement?.guide, perPixel: refinement?.perPixel ?? true),
                            refinement: refinement)
    }

    /// See `coverage(for:picture:refinement:)`.
    public func coverage(for slots: MaskSlots, refinement: MaskRefinementSession? = nil) throws -> MaskCoverage {
        if refinement == nil, slots.needsRefinement { throw MaskCoverageError.unbakedShape("smart") }
        // A Follow edges stroke with no measured shape is only ever a stroke in progress, whose canvas its session registers: any other
        // refuses here, before Metal.
        for slot in slots.slots {
            for component in slot.field?.coverage.components ?? [] {
                guard case .brush(let paint) = component.shape, paint.strokes.contains(where: { $0.followEdges && $0.measured == nil }) else { continue }
                let key = BrushCanvasKey(size: slots.size, version: slots.version, strokes: paint.strokes)
                guard liveLock.withLock({ live.contains { $0.key == key } }) else { throw MaskCoverageError.unmeasuredStroke }
            }
        }
        return try lock.withLock {
            if let index = entries.lastIndex(where: { $0.serves(slots) }) {
                let entry = entries.remove(at: index)
                entries.append(entry)
                for slot in slots.slots where slot.field != nil { entry.owners[slot.index] = slot.maskID }
                counts.hits += 1
                return MaskCoverage(slices: entry, slots: slots)
            }
            let made = try pipeline()
            let (entry, fresh) = try storage(for: slots)
            do {
                try write(slots, into: entry, clearing: fresh, pipelines: made, refinement: refinement)
            } catch {
                // Part of it may be written, so nothing can believe its fields.
                entries.removeAll { $0 === entry }
                throw error
            }
            entries.removeAll { $0 === entry }
            entries.append(entry)
            evict(to: limit)
            return MaskCoverage(slices: entry, slots: slots)
        }
    }

    /// Frees the oldest arrays until the cache holds at most `bytes`. A render holding one keeps it until it lets go.
    public func evict(downTo bytes: Int = 0) { lock.withLock { evict(to: bytes) } }

    /// Frees every array, for `FilmPreviews.trimForDevelop`. A field is quick to make again.
    public func removeAll() { evict(downTo: 0) }

    private func evict(to bytes: Int) {
        var held = entries.reduce(0) { $0 + $1.byteCount }
        while held > bytes, !entries.isEmpty { held -= entries.removeFirst().byteCount }
        evictCanvases(to: Self.canvasLimit(bytes))
    }

    /// What brush canvases may hold under a limit of `bytes`.
    static func canvasLimit(_ bytes: Int) -> Int { min(defaultCanvasBytes, bytes / 2) }

    private func evictCanvases(to bytes: Int) {
        var held = canvases.reduce(0) { $0 + $1.byteCount }
        while held > bytes, !canvases.isEmpty { held -= canvases.removeFirst().byteCount }
    }

    // MARK: the bake

    /// The library, compiled the first time a frame has masks, apart from `GPU.shaderLibrary()` (plan section 4, rule 4).
    private func pipeline() throws -> Pipelines {
        if let pipelines { return pipelines }
        let library = try device.makeLibrary(source: ShaderSource.maskCoverage, options: nil)
        func state(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
            return try device.makeComputePipelineState(function: function)
        }
        let made = Pipelines(bake: try state("mask_bake"), move: try state("mask_move"), moveWithin: try state("mask_move_within"),
                             clear: try state("mask_clear"))
        pipelines = made
        return made
    }

    /// Where `slots` goes, and whether it is new. Only an array no render holds is ever written, and none is handed out while written,
    /// since a new lease needs this lock. An array's uniqueness can only grow while the lock is held.
    private func storage(for slots: MaskSlots) throws -> (MaskCoverageSlices, fresh: Bool) {
        // Oldest first, so a drag alternates between two arrays when a render holds the other, and the other survives for it.
        var oldestFree: MaskCoverageSlices?
        for index in entries.indices {
            guard entries[index].hasShape(of: slots.size), entries[index].texture.arrayLength == slots.sliceCount,
                  isKnownUniquelyReferenced(&entries[index]) else { continue }
            let entry = entries[index]
            if oldestFree == nil { oldestFree = entry }
            // The wrong slots are one mask's (its own, and its composed fields for tier 2), and each holds nothing or that mask's old
            // shape: a drag, or a mask added or turned on. Another mask's field in such a slot (a deletion shifted it, or this is another
            // frame) is worth keeping, so it goes to a new array.
            let wrong = slots.slots.filter { $0.field != nil && entry.fields[$0.index] != $0.field }
            if let first = wrong.first, wrong.allSatisfy({ $0.maskID == first.maskID }),
               wrong.allSatisfy({ entry.owners[$0.index] == nil || entry.owners[$0.index] == $0.maskID }) {
                return (entry, false)
            }
        }
        let bytes = slots.size.bytesPerSlice * slots.sliceCount
        if entries.reduce(0, { $0 + $1.byteCount }) + bytes > limit, let oldestFree { return (oldestFree, false) }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = MaskCoverage.pixelFormat
        descriptor.width = slots.size.width
        descriptor.height = slots.size.height
        descriptor.arrayLength = slots.sliceCount
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
        texture.label = "Mask coverage"
        counts.allocations += 1
        return (MaskCoverageSlices(texture: texture, size: slots.size), true)
    }

    /// Puts into `entry` each field `slots` will read that it does not hold, in slot order, and waits for it. The list is made before
    /// anything is encoded, so a refusal leaves no half-open encoder, and made against what each slot will hold by then, since a
    /// source later in the array may already have been written over.
    /// A smart selection's refined field is fetched here too, before anything is encoded: its build or a missing seed may refuse.
    private func write(_ slots: MaskSlots, into entry: MaskCoverageSlices, clearing: Bool, pipelines: Pipelines,
                       refinement: MaskRefinementSession?) throws {
        var fills: [Fill] = []
        var baked = 0, moved = 0
        var canvases = CanvasPlan()
        canvases.refinement = refinement
        canvases.shapes = refinement?.shapes
        for slot in slots.slots {
            guard let field = slot.field else { continue }
            defer { entry.owners[slot.index] = slot.maskID }
            guard entry.fields[slot.index] != field else { continue }
            if let (source, at) = locate(field, excluding: entry) ?? entry.fields.firstIndex(of: field).map({ (entry, $0) }) {
                fills.append(.move(from: source, slot: at, to: slot.index))
                moved += 1
            } else {
                let program = try field.program
                try canvases.add(program, size: slots.size, version: slots.version, cache: self)
                fills.append(.bake(program, slot: slot.index))
                baked += 1
            }
            entry.fields[slot.index] = field
        }
        guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        if clearing { encodeClear(encoder, texture: entry.texture, pipelines: pipelines) }
        try encodeLaying(canvases, encoder: encoder)
        for fill in fills {
            switch fill {
            case .bake(let program, let slot):
                try encodeBake(encoder, program: program, size: slots.size, texture: entry.texture, slice: slot / MaskCoverage.masksPerSlice,
                           channel: slot % MaskCoverage.masksPerSlice, pipelines: pipelines,
                           rasters: canvases.textures(for: program, size: slots.size, version: slots.version))
            case .move(let source, let from, let to):
                var move = Move(sourceSlice: UInt32(from / MaskCoverage.masksPerSlice), sourceChannel: UInt32(from % MaskCoverage.masksPerSlice),
                                targetSlice: UInt32(to / MaskCoverage.masksPerSlice), targetChannel: UInt32(to % MaskCoverage.masksPerSlice))
                let within = source === entry
                encoder.setComputePipelineState(within ? pipelines.moveWithin : pipelines.move)
                if within {
                    encoder.setTexture(entry.texture, index: 0)
                } else {
                    encoder.setTexture(source.texture, index: 0)
                    encoder.setTexture(entry.texture, index: 1)
                }
                encoder.setBytes(&move, length: MemoryLayout<Move>.stride, index: 0)
                encoder.dispatchPixels(within ? pipelines.moveWithin : pipelines.move, width: entry.texture.width, height: entry.texture.height)
            }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        counts.bakes += baked
        counts.moves += moved
        counts.lastGPUSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        keepLaid(canvases)
    }

    /// The field in another array, newest first. Reading one a render holds is safe, since only an array nobody holds is ever written.
    private func locate(_ field: MaskFieldKey, excluding entry: MaskCoverageSlices) -> (MaskCoverageSlices, Int)? {
        for candidate in entries.reversed() where candidate !== entry && candidate.hasShape(of: field.size) {
            if let at = candidate.fields.firstIndex(of: field) { return (candidate, at) }
        }
        return nil
    }

    private func encodeClear(_ encoder: MTLComputeCommandEncoder, texture: MTLTexture, pipelines: Pipelines) {
        encoder.setComputePipelineState(pipelines.clear)
        encoder.setTexture(texture, index: 0)
        for slice in 0..<texture.arrayLength {
            var index = UInt32(slice)
            encoder.setBytes(&index, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.dispatchPixels(pipelines.clear, width: texture.width, height: texture.height)
        }
    }

    private func encodeBake(_ encoder: MTLComputeCommandEncoder, program: MaskProgram, size: MaskFieldSize, texture: MTLTexture,
                            slice: Int, channel: Int, pipelines: Pipelines, rasters: [MTLTexture] = []) throws {
        var params = Params(texelToPoint: size.texelToPoint, fieldHeight: UInt32(size.height), count: UInt32(program.components.count),
                            slice: UInt32(slice), channel: UInt32(channel))
        // Phase 1's kernel for a mask with no raster, so its bytes do not move; the brush library's for one with.
        let state: MTLComputePipelineState
        if !program.remaps.isEmpty, let remap {
            state = remap.bake
            for i in 0..<16 { encoder.setTexture(i < rasters.count ? rasters[i] : remap.placeholder, index: i + 1) }
            program.rasterOf.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            program.remapOf.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
            try BrushReplay.bind(program.remaps.flatMap(\.ratio), index: 4, encoder: encoder, device: device)
        } else if program.hasRasters, let brush {
            state = brush.bakeRaster
            brush.bindRasters(rasters, to: encoder)
            program.rasterOf.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        } else {
            state = pipelines.bake
        }
        encoder.setComputePipelineState(state)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        program.components.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.dispatchPixels(state, width: size.width, height: size.height)
    }

    /// Bakes one program into a float array of `size` that the caller owns, clearing it first: for tests, which compare the kernel's
    /// floats with the CPU's in `rgba32Float` before a half float rounds them, and for measurements of a bake's GPU time.
    @discardableResult
    func bake(_ program: MaskProgram, size: MaskFieldSize, into texture: MTLTexture, slice: Int = 0, channel: Int = 0,
              version: String = MaskSet.currentVersion, refinement: MaskRefinementSession? = nil) throws -> Double {
        try lock.withLock {
            let made = try pipeline()
            var canvases = CanvasPlan()
            canvases.refinement = refinement
            canvases.shapes = refinement?.shapes
            try canvases.add(program, size: size, version: version, cache: self)
            guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
            encodeClear(encoder, texture: texture, pipelines: made)
            try encodeLaying(canvases, encoder: encoder)
            try encodeBake(encoder, program: program, size: size, texture: texture, slice: slice, channel: channel, pipelines: made,
                       rasters: canvases.textures(for: program, size: size, version: version))
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw error }
            keepLaid(canvases)
            return commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        }
    }

    private func remapPipelines() throws -> (bake: MTLComputePipelineState, placeholder: MTLTexture) {
        if let remap { return remap }
        let library = try device.makeLibrary(source: ShaderSource.maskCoverage + "\n" + ShaderSource.maskBakeMapped, options: nil)
        guard let function = library.makeFunction(name: "mask_bake_mapped") else { throw GPUError.shaderFunctionMissing("mask_bake_mapped") }
        let state = try device.makeComputePipelineState(function: function)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let placeholder = device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
        var zero = Float16(0)
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 2)
        let made = (bake: state, placeholder: placeholder)
        remap = made
        return made
    }

    // MARK: brush canvases

    /// The brush library, compiled the first time a mask has a brush.
    private func brushPipelines() throws -> BrushPipelines {
        if let brush { return brush }
        let made = try BrushPipelines(device: device)
        brush = made
        return made
    }

    /// The brush library for a stroke in progress, compiled outside the cache's lock as Follow edges' is (0.5 s on a cold compile cache, measured), so
    /// a render does not wait with it; two that race both compile and the first kept is everyone's.
    func brushLibrary() throws -> BrushPipelines {
        if let made = lock.withLock({ brush }) { return made }
        let made = try BrushPipelines(device: device)
        return lock.withLock {
            if let kept = brush { return kept }
            brush = made
            return made
        }
    }

    /// Compiles the brush's library, so a stroke's first press does not wait for it.
    public func prepareBrushLibrary() throws { _ = try brushLibrary() }

    /// Follow edges' library, compiled the first time a Follow edges stroke is painted or laid.
    private func followPipelines() throws -> FollowEdgesPipelines {
        if let follow { return follow }
        let made = try FollowEdgesPipelines(device: device)
        follow = made
        return made
    }

    /// Follow edges' library for a stroke in progress, compiled outside the cache's lock: it is the slowest compile the masks have (1.7 s on a
    /// fresh app, measured), and a render that asks the cache for a canvas or a field while it runs would otherwise wait with it. Two that race
    /// both compile and the first kept is everyone's.
    func followLibrary() throws -> FollowEdgesPipelines {
        if let made = lock.withLock({ follow }) { return made }
        let made = try FollowEdgesPipelines(device: device)
        return lock.withLock {
            if let kept = follow { return kept }
            follow = made
            return made
        }
    }

    /// Compiles Follow edges' library, so a stroke's press does not wait for it.
    public func prepareFollowEdges() throws { _ = try followLibrary() }

    /// The canvases and refined fields a request needs, each found or to be laid, made before anything is encoded.
    struct CanvasPlan {
        struct Laying {
            let canvas: BrushCanvas
            let onto: BrushCanvas?
            let strokes: [BrushStroke]
            /// Where `strokes` hold a Follow edges stroke: their entries and measured shapes, read before anything is encoded.
            var measured: FollowEdgesReplay.Inputs?
        }
        var found: [BrushCanvasKey: BrushCanvas] = [:]
        var laying: [Laying] = []
        /// The render's refinement, which makes a smart selection's refined field on its decode.
        var refinement: MaskRefinementSession?
        var refined: [SmartSelection: MTLTexture] = [:]
        /// Where a Follow edges stroke's measured shape is read when its canvas must be laid.
        var shapes: (any MaskSeedProvider)?

        mutating func add(_ program: MaskProgram, size: MaskFieldSize, version: String, cache: MaskFieldCache) throws {
            if !program.remaps.isEmpty { _ = try cache.remapPipelines() }
            guard program.hasRasters else { return }
            _ = try cache.brushPipelines()
            for source in program.rasters {
                switch source {
                case .brush(let strokes):
                    let key = BrushCanvasKey(size: size, version: version, strokes: strokes)
                    guard found[key] == nil else { continue }
                    let (canvas, lay) = try cache.locate(key)
                    if var lay {
                        if lay.strokes.contains(where: \.followEdges) {
                            lay.measured = try FollowEdgesReplay.inputs(lay.strokes, size: size, shapes: shapes)
                            _ = try cache.followPipelines()
                        }
                        laying.append(lay)
                    }
                    found[key] = canvas
                case .refined(let selection):
                    guard refined[selection] == nil else { continue }
                    guard let refinement, refinement.fieldSize == size else { throw MaskCoverageError.unbakedShape("smart") }
                    refined[selection] = try refinement.field(for: selection)
                }
            }
        }

        func textures(for program: MaskProgram, size: MaskFieldSize, version: String) -> [MTLTexture] {
            program.rasters.map { source in
                switch source {
                case .brush(let strokes): found[BrushCanvasKey(size: size, version: version, strokes: strokes)]!.texture
                case .refined(let selection): refined[selection]!
                }
            }
        }
    }

    /// Where `key`'s canvas comes from: made already, or a new one and what to lay on it. The lock is held.
    private func locate(_ key: BrushCanvasKey) throws -> (BrushCanvas, CanvasPlan.Laying?) {
        if let canvas = liveLock.withLock({ live.last { $0.key == key } }) {
            counts.canvasHits += 1
            return (canvas, nil)
        }
        if let index = canvases.lastIndex(where: { $0.key == key }) {
            let canvas = canvases.remove(at: index)
            canvases.append(canvas)
            counts.canvasHits += 1
            return (canvas, nil)
        }
        let prefix = (canvases + liveLock.withLock { live })
            .filter { key.extends($0.key) }.max { $0.key.strokes.count < $1.key.strokes.count }
        let canvas = BrushCanvas(key: key, texture: try BrushCanvas.makeTexture(device: device, size: key.size, label: "Brush canvas"))
        return (canvas, CanvasPlan.Laying(canvas: canvas, onto: prefix, strokes: Array(key.strokes.dropFirst(prefix?.key.strokes.count ?? 0))))
    }

    private func encodeLaying(_ plan: CanvasPlan, encoder: MTLComputeCommandEncoder) throws {
        guard !plan.laying.isEmpty else { return }
        let brush = try brushPipelines()
        for lay in plan.laying {
            if let measured = lay.measured {
                try FollowEdgesReplay.encode(measured, onto: lay.onto?.texture, into: lay.canvas.texture, size: lay.canvas.key.size,
                                             encoder: encoder, brush: brush, follow: try followPipelines(), device: device)
            } else {
                try BrushReplay.encode(lay.strokes, onto: lay.onto?.texture, into: lay.canvas.texture, size: lay.canvas.key.size,
                                       encoder: encoder, pipelines: brush, device: device)
            }
            counts.replays += 1
            counts.strokesReplayed += lay.strokes.count
        }
    }

    /// Keeps what a request laid, once its command buffer is done.
    private func keepLaid(_ plan: CanvasPlan) {
        for lay in plan.laying { canvases.append(lay.canvas) }
        evictCanvases(to: Self.canvasLimit(limit))
    }

    /// `key`'s canvas, laid now if nothing holds it, and kept. For a stroke in progress's base, the overlay's other brushes, and tests.
    /// A Follow edges stroke laid now reads its measured shape from `shapes`.
    public func canvas(for key: BrushCanvasKey, shapes: (any MaskSeedProvider)? = nil) throws -> BrushCanvas {
        try lock.withLock {
            let (canvas, found) = try locate(key)
            guard var lay = found else { return canvas }
            if lay.strokes.contains(where: \.followEdges) {
                lay.measured = try FollowEdgesReplay.inputs(lay.strokes, size: key.size, shapes: shapes)
                _ = try followPipelines()
            }
            var plan = CanvasPlan()
            plan.laying = [lay]
            guard let commandBuffer = queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
            try encodeLaying(plan, encoder: encoder)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw error }
            counts.lastGPUSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
            keepLaid(plan)
            return canvas
        }
    }

    /// Keeps a canvas a finished stroke made, so the bake that follows lays nothing. It must never be written again.
    func keep(_ canvas: BrushCanvas) {
        lock.withLock {
            canvases.removeAll { $0.key == canvas.key }
            canvases.append(canvas)
            evictCanvases(to: Self.canvasLimit(limit))
        }
    }

    /// A stroke in progress's canvas for the print: a render whose brush has exactly these strokes reads it and lays nothing. It is
    /// never kept, and must not be written while registered.
    func register(live canvas: BrushCanvas) { liveLock.withLock { live.append(canvas) } }
    func unregister(live canvas: BrushCanvas) { liveLock.withLock { live.removeAll { $0 === canvas } } }
    /// How many are registered, for tests.
    var liveCount: Int { liveLock.withLock { live.count } }
}
