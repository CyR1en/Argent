import Foundation
import Metal

// Follow edges, the brush's edge-aware mode (Lightroom's Auto Mask; plan section 6, R8 section 7.6; task L). A stroke painted with it
// keeps to the colours under its dabs' centres while it is painted: each dab's value at a texel is weighted by how near the texel's
// colour on the untouched decode is to the dab's own (`FollowEdgesModel`). When it ends, that shape is refined to the picture's edges by
// the smart masks' guided filter on the same decode, and kept: an 8-bit raster in the seed store (`MeasuredStroke`), which every render
// then reads as the stroke's shape. So the colour test and the refinement run once, on the frame view's decode as the stroke is painted,
// and never at a render: the print, the previews and the develop read one shape whatever decode each has, nothing measured reads a
// slider or a stock, and a develop pays only for reading the raster.

/// Follow edges' constants. A change of any changes what a new stroke measures, never what a stroke already made prints, since that
/// keeps what it measured; nor a plain stroke.
public enum FollowEdgesModel {
    /// The colour test (R8 7.6): a dab's weight at a texel is `1 − smoothstep((Δ − near)/(far − near))`, Δ the Oklab distance from the
    /// texel's colour to the dab's.
    public static let near: Float = 0.05
    public static let far: Float = 0.15
    /// A dab's colour is the mean light of the (2 r + 1)² slice texels about the texel its centre lies in, then Oklab: R8's 7 × 7
    /// canonical pixels.
    public static let sampleRadius = 3
    /// Each dab tests against its own colour, the colour under the brush's centre as it moves, rather than the stroke's first dab's: R8
    /// found it more inclusive, and it is what Lightroom asks of its Auto Mask (keep the centre on what is to be painted).
    public static let perDab = true
    /// The refinement as a stroke ends: R8's, a guided filter of radius 0.001 of the slice's long side (2 texels at 2048) and ε 0.01, on
    /// the smart masks' guide (log luminance and chroma of the untouched decode), at the slice's own texels.
    public static let refinement = MaskRefineParameters(radiusShare: 0.001, epsilon: 0.01)
}

/// Follow edges on the CPU: the arithmetic the kernels run, for the tests.
public enum FollowEdges {
    /// Rec. 2020 linear light to Oklab, through linear sRGB, as `follow_oklab` makes it (R8's matrices).
    public static func oklab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let s = SIMD3<Float>(1.6605 * rgb.x - 0.5876 * rgb.y - 0.0728 * rgb.z, -0.1246 * rgb.x + 1.1329 * rgb.y - 0.0083 * rgb.z,
                             -0.0182 * rgb.x - 0.1006 * rgb.y + 1.1187 * rgb.z)
        let c = SIMD3<Float>(max(s.x, 0), max(s.y, 0), max(s.z, 0))
        func root(_ v: Float) -> Float { Float(pow(Double(max(v, 1e-12)), 1.0 / 3.0)) }
        let l = root(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z)
        let m = root(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z)
        let q = root(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * q, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * q,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * q)
    }

    /// A dab's weight at a texel `distance` from its colour in Oklab.
    public static func weight(_ distance: Float) -> Float {
        let t = min(max((distance - FollowEdgesModel.near) / (FollowEdgesModel.far - FollowEdgesModel.near), 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// The slice texel a dab's centre lies in, from the picture's top: where its colour is sampled.
    static func sampleTexel(_ dab: BrushDab, size: MaskFieldSize) -> SIMD2<Int32> {
        let at = (SIMD2(dab.x, dab.y) / size.texelToPoint).rounded(.down)
        let limit = SIMD2<Float>(Float(Int32.max / 2), Float(Int32.max / 2))
        return SIMD2(Int32(min(max(at.x, -limit.x), limit.x)), Int32(min(max(at.y, -limit.y), limit.y)))
    }

    /// A dab's colour in Oklab, on `light` (the guide frame at the slice's size, row 0 the picture's bottom).
    public static func colour(at dab: BrushDab, light: [SIMD3<Float>], size: MaskFieldSize) -> SIMD3<Float> {
        let at = sampleTexel(dab, size: size), r = FollowEdgesModel.sampleRadius
        var sum = SIMD3<Float>.zero
        for dy in -r...r {
            for dx in -r...r {
                let x = min(max(Int(at.x) + dx, 0), size.width - 1), top = min(max(Int(at.y) + dy, 0), size.height - 1)
                sum += light[(size.height - 1 - top) * size.width + x]
            }
        }
        return oklab(sum / Float((2 * r + 1) * (2 * r + 1)))
    }

    /// A stroke's colour-tested shape at every slice texel, row 0 the picture's bottom, rounded to half as the canvas holds it: the largest
    /// of its dabs' values each weighted by the colour test, each dab against its own colour (`perDab`) or the first's.
    public static func shape(dabs: [BrushDab], profile: BrushDabProfile, light: [SIMD3<Float>], size: MaskFieldSize,
                             perDab: Bool = FollowEdgesModel.perDab) -> [Float] {
        guard let first = dabs.first else { return [Float](repeating: 0, count: size.width * size.height) }
        let colours = perDab ? dabs.map { colour(at: $0, light: light, size: size) }
            : [SIMD3<Float>](repeating: colour(at: first, light: light, size: size), count: dabs.count)
        var out = [Float](repeating: 0, count: size.width * size.height)
        let step = size.texelToPoint
        for (index, dab) in dabs.enumerated() {
            guard let region = BrushRegion.touched(by: dab, radius: profile.outer, size: size) else { continue }
            for top in region.y..<(region.y + region.height) {
                let row = size.height - 1 - top
                for x in region.x..<(region.x + region.width) {
                    let q = (SIMD2<Float>(Float(x), Float(top)) + 0.5) * step, d = q - SIMD2(dab.x, dab.y)
                    let v = profile.value(distance: (d * d).sum().squareRoot())
                    guard v > out[row * size.width + x] else { continue }
                    let here = oklab(light[row * size.width + x]), apart = here - colours[index]
                    out[row * size.width + x] = max(out[row * size.width + x], v * weight((apart * apart).sum().squareRoot()))
                }
            }
        }
        return out.map { BrushCompositing.half($0) }
    }
}

/// Follow edges' library (`ShaderSource.followEdges`), compiled the first time a Follow edges stroke is painted or laid.
final class FollowEdgesPipelines: @unchecked Sendable {
    let colours: MTLComputePipelineState
    let tick: MTLComputePipelineState
    let lay: MTLComputePipelineState

    init(device: MTLDevice) throws {
        let source = ShaderSource.maskCoverage + "\n" + ShaderSource.brushCanvas + "\n" + ShaderSource.followEdges
        let library = try device.makeLibrary(source: source, options: nil)
        func state(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
            return try device.makeComputePipelineState(function: function)
        }
        colours = try state("follow_dab_colours")
        tick = try state("brush_tick_follow")
        lay = try state("brush_lay_measured")
    }
}

/// `struct FollowParams`, 32 bytes.
struct FollowParamsGPU {
    var near = FollowEdgesModel.near
    var far = FollowEdgesModel.far
    var sampleRadius = UInt32(FollowEdgesModel.sampleRadius)
    var count: UInt32 = 0
    var width: UInt32
    var height: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0

    init(size: MaskFieldSize, count: Int) {
        width = UInt32(size.width)
        height = UInt32(size.height)
        self.count = UInt32(count)
    }
}

/// `struct BrushMeasuredGPU`, 40 bytes.
struct BrushMeasuredGPU {
    var x: Int32
    var y: Int32
    var width: UInt32
    var height: UInt32
    var offset: UInt32
    var same: UInt32
    var recordedTexelToPoint: SIMD2<Float>
    var flow: Float
    var erase: UInt32
}

/// Strokes from the recipe where some kept a measured shape. They are laid in segments, in order: each run of plain strokes by the brush
/// library's own `brush_replay`, so a plain stroke has one arithmetic whichever brush it is in (two libraries compiled from one text need
/// not round alike: measured, one half-float step on 66 texels of a faint dab edge), and each run of measured strokes by
/// `brush_lay_measured`, which only reads their rasters. Each segment reads the last one's canvas and writes the other of two, ending on the
/// canvas being made. A list with no Follow edges stroke never comes here: `BrushReplay` lays it in one dispatch, as before.
enum FollowEdgesReplay {
    enum Segment {
        case plain([BrushStroke])
        case measured([BrushMeasuredGPU], shapes: [UInt8])
    }

    struct Inputs {
        let segments: [Segment]
        /// The measured rasters' bytes, which a laying holds while it is encoded.
        var byteCount: Int {
            segments.reduce(0) { total, segment in if case .measured(_, let shapes) = segment { total + shapes.count } else { total } }
        }
    }

    /// The texels of `size` a measured stroke's raster reaches, from the picture's top, or `nil` when none.
    static func region(of measured: MeasuredStroke, size: MaskFieldSize) -> BrushRegion? {
        let recorded = measured.field, w = measured.raster.width, h = measured.raster.height
        if recorded == size { return BrushRegion(x: measured.x, y: measured.y, width: w, height: h) }
        let step = recorded.texelToPoint, here = size.texelToPoint
        let x0 = Int((Float(measured.x) * step.x / here.x).rounded(.down)) - 1, x1 = Int((Float(measured.x + w) * step.x / here.x).rounded(.up)) + 1
        let y0 = Int((Float(measured.y) * step.y / here.y).rounded(.down)) - 1, y1 = Int((Float(measured.y + h) * step.y / here.y).rounded(.up)) + 1
        let left = max(0, x0), top = max(0, y0), right = min(size.width, x1), bottom = min(size.height, y1)
        guard left < right, top < bottom else { return nil }
        return BrushRegion(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// `strokes` in segments, the measured strokes' shapes read from `shapes`. Refuses a Follow edges stroke with no shape, and a shape
    /// `shapes` does not hold, before anything is encoded.
    static func inputs(_ strokes: [BrushStroke], size: MaskFieldSize, shapes: (any MaskSeedProvider)?) throws -> Inputs {
        var segments: [Segment] = [], plain: [BrushStroke] = [], measured: [BrushMeasuredGPU] = [], bytes: [UInt8] = []
        func close() {
            if !plain.isEmpty { segments.append(.plain(plain)); plain = [] }
            if !measured.isEmpty { segments.append(.measured(measured, shapes: bytes)); measured = []; bytes = [] }
        }
        for stroke in strokes {
            guard stroke.followEdges else {
                if !measured.isEmpty { close() }
                plain.append(stroke)
                continue
            }
            guard let shape = stroke.measured else { throw MaskCoverageError.unmeasuredStroke }
            if !plain.isEmpty { close() }
            let raster = try load(shape.raster, from: shapes)
            let recorded = shape.field
            measured.append(BrushMeasuredGPU(x: Int32(shape.x), y: Int32(shape.y), width: UInt32(raster.width), height: UInt32(raster.height),
                                             offset: UInt32(bytes.count), same: recorded == size ? 1 : 0, recordedTexelToPoint: recorded.texelToPoint,
                                             flow: stroke.flow, erase: stroke.erase ? 1 : 0))
            bytes += raster.plane
        }
        close()
        return Inputs(segments: segments)
    }

    /// A measured shape's pixels, checked against the size its stroke records.
    static func load(_ ref: RasterRef, from shapes: (any MaskSeedProvider)?) throws -> MaskRaster {
        guard let shapes else { throw MaskRefinerError.noSeedStore }
        let raster: MaskRaster
        do { raster = try shapes.seed(for: ref) } catch { throw MaskRefinerError.seedUnavailable(ref.id) }
        guard raster.width == ref.width, raster.height == ref.height else { throw MaskRefinerError.seedMismatch(ref.id) }
        return raster
    }

    /// Encodes `inputs` laid onto `base` (or onto 0) into `target`, both of `size`. Segments after the first need a second canvas, made
    /// here and let go with the command buffer.
    static func encode(_ inputs: Inputs, onto base: MTLTexture?, into target: MTLTexture, size: MaskFieldSize, encoder: MTLComputeCommandEncoder,
                       brush: BrushPipelines, follow: FollowEdgesPipelines, device: MTLDevice) throws {
        let count = inputs.segments.count
        let scratch = count > 1 ? try BrushCanvas.makeTexture(device: device, size: size, label: "Brush canvas, laying") : nil
        var current = base
        for (index, segment) in inputs.segments.enumerated() {
            // The last segment writes `target`; before it they alternate, so each reads what the one before wrote.
            let into = (count - 1 - index) % 2 == 0 ? target : scratch!
            switch segment {
            case .plain(let strokes):
                try BrushReplay.encode(strokes, onto: current, into: into, size: size, encoder: encoder, pipelines: brush, device: device)
            case .measured(let measured, let shapes):
                try lay(measured, shapes: shapes, onto: current, into: into, size: size, region: nil, encoder: encoder,
                        follow: follow, placeholder: brush.placeholder, device: device)
            }
            current = into
        }
    }

    /// One run of measured strokes onto `base` (or onto 0) into `target`: over the whole slice, or over `region` (from the picture's top)
    /// alone, the rest of `target` left as it is.
    static func lay(_ measured: [BrushMeasuredGPU], shapes: [UInt8], onto base: MTLTexture?, into target: MTLTexture, size: MaskFieldSize,
                    region: BrushRegion?, encoder: MTLComputeCommandEncoder, follow: FollowEdgesPipelines, placeholder: MTLTexture,
                    device: MTLDevice) throws {
        let area = region ?? BrushRegion(x: 0, y: 0, width: size.width, height: size.height)
        guard !area.isEmpty else { return }
        var params = BrushCanvasParams(size: size)
        params.originX = UInt32(area.x)
        params.originY = UInt32(size.height - area.y - area.height)
        params.hasBase = base == nil ? 0 : 1
        var count = UInt32(measured.count)
        encoder.setComputePipelineState(follow.lay)
        encoder.setTexture(base ?? placeholder, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<BrushCanvasParams>.stride, index: 0)
        try BrushReplay.bind(measured, index: 1, encoder: encoder, device: device)
        try BrushReplay.bind(shapes, index: 2, encoder: encoder, device: device)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.dispatchPixels(follow.lay, width: area.width, height: area.height)
    }
}

/// How a Follow edges stroke measures its shape as it ends: its colour-tested shape, refined to the picture's edges, kept as 8 bits over
/// the part of the slice it reaches.
public struct FollowEdgesMeasurement: Sendable {
    /// The shape, cropped to where it is not 0 (at least `RasterRef.sideRange`'s 16 texels a side), and where it lies.
    public let raster: MaskRaster
    public let measured: MeasuredStroke
    /// The refinement's build, and its GPU time with the wall time of evaluating it on the slice.
    public let build: MaskRefineBuild
    public let seconds: Double

    /// Measures from `shape` (the colour-tested shape, `r16Float` of `size`, row 0 the picture's bottom, 0 outside `region`, from the
    /// picture's top), on `guideFrame` (the refinement's guide frame of the decode), the slice of `picture`:
    /// 1. the shape in 8 bits is the seed, as a smart mask's is;
    /// 2. `MaskRefiner` builds its coefficients against the guide frame (`FollowEdgesModel.refinement`) and evaluates them at each texel
    ///    of the slice, as tier 1 does;
    /// 3. that refined shape in 8 bits, cropped, is what the stroke keeps.
    /// The refined shape is 0 wherever the seed is 0 for twice the radius around, so the crop is read from `region` grown by that.
    static func measure(shape: MTLTexture, region: BrushRegion, guideFrame: MTLTexture, picture: MaskSpace,
                        refiner: MaskRefiner) throws -> FollowEdgesMeasurement {
        let size = MaskFieldSize(picture: picture)
        let parameters = FollowEdgesModel.refinement
        let r = parameters.radius(seedWidth: size.width, seedHeight: size.height)
        // 1. The seed.
        var plane = [UInt8](repeating: 0, count: size.width * size.height)
        let within = read(shape, region: region, size: size)
        for row in 0..<region.height {
            for column in 0..<region.width {
                plane[(region.y + row) * size.width + region.x + column] = quantized(within[row * region.width + column])
            }
        }
        let seed = try MaskRaster(width: size.width, height: size.height, plane: plane)
        // 2. Refined, on the slice's texels.
        let (coefficients, build) = try refiner.build(seed: try refiner.upload(seed), guideFrame: guideFrame, parameters: parameters)
        let started = Date()
        let field = try refiner.field(coefficients: coefficients, guideFrame: guideFrame, size: size)
        let fieldSeconds = Date().timeIntervalSince(started)
        // 3. Cropped to where it is not 0.
        let reach = 2 * r + 2
        let grown = BrushRegion(x: max(0, region.x - reach), y: max(0, region.y - reach),
                                width: min(size.width, region.x + region.width + reach) - max(0, region.x - reach),
                                height: min(size.height, region.y + region.height + reach) - max(0, region.y - reach))
        let refined = read(field, region: grown, size: size).map(quantized)
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for row in 0..<grown.height {
            for column in 0..<grown.width where refined[row * grown.width + column] != 0 {
                x0 = min(x0, column); x1 = max(x1, column); y0 = min(y0, row); y1 = max(y1, row)
            }
        }
        if x1 < 0 { x0 = 0; y0 = 0; x1 = 0; y1 = 0 }
        // At least 16 a side, inside the slice.
        let side = RasterRef.sideRange.lowerBound
        func span(_ low: Int, _ high: Int, offset: Int, limit: Int) -> (Int, Int) {
            var start = offset + low, length = high - low + 1
            if length < side { start -= (side - length) / 2; length = side }
            start = min(max(start, 0), max(0, limit - length))
            return (start, min(length, limit))
        }
        let (cx, cw) = span(x0, x1, offset: grown.x, limit: size.width), (cy, ch) = span(y0, y1, offset: grown.y, limit: size.height)
        var crop = [UInt8](repeating: 0, count: cw * ch)
        for row in 0..<ch {
            let gy = cy + row - grown.y
            guard gy >= 0, gy < grown.height else { continue }
            for column in 0..<cw {
                let gx = cx + column - grown.x
                guard gx >= 0, gx < grown.width else { continue }
                crop[row * cw + column] = refined[gy * grown.width + gx]
            }
        }
        let raster = try MaskRaster(width: cw, height: ch, plane: crop)
        let measured = try MeasuredStroke(raster: raster.ref, x: cx, y: cy, pictureWidth: picture.width, pictureHeight: picture.height)
        return FollowEdgesMeasurement(raster: raster, measured: measured, build: build, seconds: build.gpuSeconds + fieldSeconds)
    }

    /// A value in 8 bits, as a seed is stored.
    static func quantized(_ v: Float) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }

    /// An `r16Float` texture of `size` over `region` (from the picture's top), top row first.
    static func read(_ texture: MTLTexture, region: BrushRegion, size: MaskFieldSize) -> [Float] {
        guard !region.isEmpty else { return [] }
        var halves = [Float16](repeating: 0, count: region.width * region.height)
        halves.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: region.width * 2,
                             from: MTLRegionMake2D(region.x, size.height - region.y - region.height, region.width, region.height), mipmapLevel: 0)
        }
        var out = [Float](repeating: 0, count: halves.count)
        for row in 0..<region.height {
            let from = (region.height - 1 - row) * region.width
            for column in 0..<region.width { out[row * region.width + column] = Float(halves[from + column]) }
        }
        return out
    }
}
