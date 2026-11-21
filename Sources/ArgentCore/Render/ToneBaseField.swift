import Foundation
import Metal

/// The local tone base's constants. Each manual compiler that uses the base has one set, and
/// changing a set changes that compiler's renders, so a new set goes with a new compiler.
public struct ToneBaseParameters: Sendable, Equatable, Hashable {
    /// The box radius as a share of the field's long side, so a frame and its preview smooth over
    /// the same part of the picture.
    public let radiusFraction: Float
    /// The guided filter's regularization, in stops squared: a window whose log luminance varies
    /// by much less than its square root is smoothed flat, one that varies by much more keeps its
    /// edge. Texture of variance `v` keeps `v / (v + epsilon)` of itself in the base.
    public let epsilon: Float
    /// The field's long side; smaller frames use their own size.
    public let fieldLongSide: Int
    /// The radius of the boxes that smooth the coefficients, as a share of the guide's boxes'
    /// radius. 1 is the guided filter as published; less keeps an edge's lean on its other side
    /// nearer the edge, a halo, at the same smoothing of texture.
    public let coefficientRadiusShare: Float

    public init(radiusFraction: Float, epsilon: Float, fieldLongSide: Int, coefficientRadiusShare: Float = 1) {
        precondition(radiusFraction > 0 && epsilon > 0 && fieldLongSide > 0
                     && coefficientRadiusShare > 0 && coefficientRadiusShare <= 1, "invalid tone base parameters")
        self.radiusFraction = radiusFraction
        self.epsilon = epsilon
        self.fieldLongSide = fieldLongSide
        self.coefficientRadiusShare = coefficientRadiusShare
    }

    /// The gain-table manual compilers': the radius and epsilon fitted to Lightroom's Highlights and
    /// Shadows (`scripts/lightroom-probe/fit_targets.py`, docs/research/lightroom-sliders.md), and
    /// the coefficients boxed at half the radius, which keeps a third of the halo beside a strong
    /// edge for 0.003 of the fit's R².
    public static let compiler2026_10_29_1 = ToneBaseParameters(radiusFraction: 0.015, epsilon: 0.7, fieldLongSide: 1024,
                                                                coefficientRadiusShare: 0.5)

    /// The field's size for a `width` by `height` frame: the long side `fieldLongSide` or the
    /// frame's, whichever is less, the short side in proportion, rounded, as `HalationField`'s.
    public func fieldSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let longSide = max(width, height)
        let fieldLong = min(fieldLongSide, longSide)
        return (max(1, Int((Float(width) * Float(fieldLong) / Float(longSide)).rounded())),
                max(1, Int((Float(height) * Float(fieldLong) / Float(longSide)).rounded())))
    }

    /// The box radius in field pixels for a field `fieldLong` pixels on its long side.
    public func radius(fieldLong: Int) -> Int {
        max(1, Int((radiusFraction * Float(fieldLong)).rounded()))
    }

    /// The radius of the coefficients' boxes in field pixels: `coefficientRadiusShare` of `radius`.
    public func coefficientRadius(fieldLong: Int) -> Int {
        max(1, Int((Float(radius(fieldLong: fieldLong)) * coefficientRadiusShare).rounded()))
    }
}

/// The local tone base: for each pixel, the log2 luminance of its surroundings, smoothed within
/// regions and kept apart across the edges between them. The manual tone mapping reads it to tell
/// a bright area from a bright detail, so Highlights and Shadows act on regions, as Lightroom's
/// do, and keep the texture inside them (docs/manual-development.md, "Local base").
///
/// It is a self-guided fast guided filter (He and Sun, 2015) in log2 luminance. A pixel's guide
/// is `g = log2(sqrt(Y^2 + 1e-12))`, `Y` the Rec. 2020 luminance of its light before any manual
/// exposure. The field, `fieldLongSide` pixels at most on the long side as `HalationField`'s,
/// takes the same of `Y` area-averaged into it. There, with boxes of radius `radiusFraction`
/// times the field's long side and the edges clamped, `mu = box(g)`, `sigma^2 = box(g^2) -
/// mu^2`, `a = sigma^2 / (sigma^2 + epsilon)`, `b = mu - a mu`, and the field holds `box(a)` and
/// `box(b)`, boxes of `coefficientRadiusShare` of that radius (the published filter uses the same
/// radius; half of it leans a third as far across a strong edge for the same smoothing of
/// texture). A pixel's base is `box(a) g + box(b)`, its own guide and the coefficients
/// interpolated bilinearly to it. In a flat window `a` is 0 and the base is the window's mean;
/// across a strong edge `a` is near 1 and the base follows the pixel's own level. Being
/// self-guided and in log space, adding `c` stops to the frame adds `c` to the base, so exposure
/// and the manual reference are offsets on it, and the field depends only on the frame and the
/// constants, never on slider values.
///
/// The field averages luminance in linear light, not its log, because a preview is the develop
/// averaged in linear light: a frame and an area-resize of it at the field's size or more then
/// make the same field (3e-4 stops on a synthetic frame with pixel-sized texture, where log
/// averaging differed by up to a stop), so a preview's base and a develop's agree. Its
/// coefficients are `rg32Float`, eight bytes a texel as `rgba16Float` is, because `box(b)` is
/// near the log luminance itself, up to 20 stops from zero, where a half float's step is a
/// sixty-fourth of a stop. A renderer's lanes may make fields at once: each call has its own
/// textures and command buffer.
public final class ToneBaseField {
    /// The guide's floor, as the manual scene mapping's: luminance this far below zero is black.
    public static let guideEpsilon: Float = 1e-6
    /// The pixels a box thread slides over, at least: with its own first window at most as long,
    /// a pixel costs about three reads whatever the radius. 32 and 128 were slower (measured).
    static let minimumSegment = 64

    /// Mirrors `ToneBaseParams`.
    struct Params {
        var epsilon: Float
        var radius: UInt32
        var coefficientRadius: UInt32
        var segment: UInt32

        init(_ parameters: ToneBaseParameters, fieldLong: Int) {
            let radius = parameters.radius(fieldLong: fieldLong)
            epsilon = parameters.epsilon
            self.radius = UInt32(radius)
            coefficientRadius = UInt32(parameters.coefficientRadius(fieldLong: fieldLong))
            segment = UInt32(max(ToneBaseField.minimumSegment, 2 * radius + 1))
        }
    }

    /// Mirrors `ToneBasePass`.
    struct Pass {
        var columns: UInt32
        var stage: UInt32
    }

    /// The field's guide and box kernels, apart from the textures they run on, so Presence's analysis can make two fields from one guide
    /// and Texture's band a band of rows at a time, from the same kernels as the base's own field.
    struct Kernels {
        let guide: MTLComputePipelineState
        let box: MTLComputePipelineState

        init(library: MTLLibrary, device: MTLDevice) throws {
            func pipeline(_ name: String) throws -> MTLComputePipelineState {
                guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
                return try device.makeComputePipelineState(function: function)
            }
            guide = try pipeline("tone_base_guide")
            box = try pipeline("tone_base_box")
        }

        /// `frame`'s luminance area-averaged into `guide`, which sets the field's size, then its log.
        func encodeGuide(_ encoder: MTLComputeCommandEncoder, frame: MTLTexture, into guide: MTLTexture) {
            encoder.setComputePipelineState(self.guide)
            encoder.setTexture(frame, index: 0)
            encoder.setTexture(guide, index: 1)
            encoder.dispatchPixels(self.guide, width: guide.width, height: guide.height)
        }

        /// One box pass of `input`'s every line into `output`. A thread's x is its row or column, so a SIMD group's reads are neighbours.
        func encodeBox(_ encoder: MTLComputeCommandEncoder, _ params: Params, _ pass: Pass, input: MTLTexture, output: MTLTexture) {
            var params = params, pass = pass
            let (lines, length) = pass.columns == 0 ? (input.height, input.width) : (input.width, input.height)
            encoder.setComputePipelineState(box)
            encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            encoder.setBytes(&pass, length: MemoryLayout<Pass>.stride, index: 1)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.dispatchPixels(box, width: lines, height: (length + Int(params.segment) - 1) / Int(params.segment))
        }

        /// The field under `parameters` from `guide` into `output`, through `scratch`, all three the field's size: the guide's boxes
        /// into the coefficients, then theirs into the field. `guide` is only read, so another field of its size can follow from it.
        func encodeBoxes(_ encoder: MTLComputeCommandEncoder, parameters: ToneBaseParameters, guide: MTLTexture, scratch: MTLTexture,
                         output: MTLTexture) {
            let params = Params(parameters, fieldLong: max(guide.width, guide.height))
            encodeBox(encoder, params, Pass(columns: 0, stage: 0), input: guide, output: scratch)
            encodeBox(encoder, params, Pass(columns: 1, stage: 0), input: scratch, output: output)
            encodeBox(encoder, params, Pass(columns: 0, stage: 1), input: output, output: scratch)
            encodeBox(encoder, params, Pass(columns: 1, stage: 1), input: scratch, output: output)
        }
    }

    private let gpu: GPU
    private let kernels: Kernels
    private let map: MTLComputePipelineState
    private let timing = NSLock()
    private var gpuSeconds: Double = 0
    private let cacheLock = NSLock()
    private var cached: (image: PooledTexture, parameters: ToneBaseParameters, field: PooledTexture)?
    private var builds = 0
    private var cacheGeneration: UInt64 = 0
    var buildCount: Int { cacheLock.withLock { builds } }

    /// The GPU time of the last field made, for measurements.
    var lastGPUSeconds: Double { timing.withLock { gpuSeconds } }

    /// Builds the pipelines; call it on one thread, as the shader library is not thread-safe.
    public init(gpu: GPU) throws {
        let library = try gpu.shaderLibrary()
        self.gpu = gpu
        kernels = try Kernels(library: library, device: gpu.device)
        guard let function = library.makeFunction(name: "tone_base_map") else { throw GPUError.shaderFunctionMissing("tone_base_map") }
        map = try gpu.device.makeComputePipelineState(function: function)
    }

    public func removeAll() {
        cacheLock.withLock {
            cached = nil
            cacheGeneration &+= 1
        }
    }

    /// The field for `frame` under `parameters`: an `rg32Float` texture of the field's size from
    /// the pool, `box(a)` in red and `box(b)` in green, for `tone_base_log2`. Run now; it holds
    /// two more textures of its size while it runs. With `reuse`, keeps the last field and its decode's
    /// loan alive until replaced or cleared; neither texture can return to the pool while cached.
    public func field(for frame: LinearFrame, parameters: ToneBaseParameters, reuse: Bool = false) throws -> PooledTexture {
        let (hit, generation) = cacheLock.withLock { () -> (PooledTexture?, UInt64) in
            if reuse, let cached, cached.image === frame.image, cached.parameters == parameters {
                return (cached.field, cacheGeneration)
            }
            return (nil, cacheGeneration)
        }
        if let hit { return hit }
        let size = parameters.fieldSize(width: frame.width, height: frame.height)
        func texture() throws -> PooledTexture {
            try gpu.texturePool.acquire(width: size.width, height: size.height, pixelFormat: .rg32Float)
        }
        let first = try texture(), second = try texture(), output = try texture()

        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        kernels.encodeGuide(encoder, frame: frame.texture, into: first.texture)
        kernels.encodeBoxes(encoder, parameters: parameters, guide: first.texture, scratch: second.texture, output: output.texture)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((frame, first, second)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        timing.withLock { gpuSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime }
        cacheLock.withLock {
            builds += 1
            if reuse, generation == cacheGeneration { cached = (frame.image, parameters, output) }
        }
        return output
    }

    /// Each pixel of `frame`'s base from `field`, as `tone_base_log2` gives it to a kernel, read
    /// back row by row: for tests and measurements.
    func baseMap(for frame: LinearFrame, field: PooledTexture) throws -> [Float] {
        let width = frame.width, height = frame.height
        let out = try gpu.texturePool.acquire(width: width, height: height, pixelFormat: .rg32Float)
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encoder.setComputePipelineState(map)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setTexture(field.texture, index: 1)
        encoder.setTexture(out.texture, index: 2)
        encoder.dispatchPixels(map, width: width, height: height)
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((frame, field)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        return Self.coefficients(of: out).map(\.x)
    }

    /// A field's two coefficients, read back row by row: for tests and measurements.
    static func coefficients(of field: PooledTexture) -> [SIMD2<Float>] {
        let width = field.width, height = field.height
        var values = [SIMD2<Float>](repeating: .zero, count: width * height)
        values.withUnsafeMutableBytes { buffer in
            field.texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 8,
                                   from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return values
    }

    /// The Rec. 2020 luminance of linear light `rgb`.
    static func luminance(_ rgb: SIMD3<Float>) -> Float { (rgb * Rec2020.luma).sum() }

    /// A pixel's guide: the log2 of the luminance of its light `rgb`, floored at `guideEpsilon` and
    /// held to ±`guideLimit` stops, as `tone_base_field_guide` holds it.
    static func guide(_ rgb: SIMD3<Float>) -> Float {
        let y = luminance(rgb)
        return limited(log2(sqrt(y * y + guideEpsilon * guideEpsilon)))
    }

    /// No finite light comes near it; it keeps a non-finite pixel from spreading through the
    /// filters' running sums (IEEE minimum and maximum take the number over a NaN).
    static let guideLimit: Float = 40
    static func limited(_ g: Float) -> Float { .maximum(.minimum(g, guideLimit), -guideLimit) }

    /// The base on the CPU: each pixel's base log2 luminance, row by row, for `pixels` the frame's
    /// linear light row by row (half floats, as the frame's texture holds them, to compare with
    /// the GPU). The same math, its sums in double precision; the coefficients are kept as floats,
    /// as the field keeps them, and interpolated as `tone_base_log2` interpolates them.
    public static func reference(pixels: [SIMD3<Float>], width: Int, height: Int,
                                 parameters: ToneBaseParameters) -> [Float] {
        precondition(pixels.count == width * height, "pixels must be width by height")
        let (fieldWidth, fieldHeight, coefficients) = referenceField(luminance: pixels.map(luminance), width: width,
                                                                     height: height, parameters: parameters)
        var base = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let uv = SIMD2<Float>((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height))
                let ab = interpolated(coefficients, width: fieldWidth, height: fieldHeight, uv: uv)
                base[y * width + x] = ab.x * guide(pixels[y * width + x]) + ab.y
            }
        }
        return base
    }

    /// The field on the CPU from each frame pixel's luminance: its size and coefficients row by row.
    static func referenceField(luminance: [Float], width: Int, height: Int,
                               parameters: ToneBaseParameters) -> (width: Int, height: Int, coefficients: [SIMD2<Float>]) {
        let (fw, fh) = parameters.fieldSize(width: width, height: height)
        let radius = parameters.radius(fieldLong: max(fw, fh))
        let coefficientRadius = parameters.coefficientRadius(fieldLong: max(fw, fh))
        // The luminance area-averaged as `tone_base_guide` does it, at whole-number positions in
        // units of 1 / (frame side * field side), so every weight is exact; then its log.
        let floor = Double(guideEpsilon) * Double(guideEpsilon)
        var g = [Double](repeating: 0, count: fw * fh)
        for oy in 0..<fh {
            let y0 = oy * height, y1 = y0 + height
            for ox in 0..<fw {
                let x0 = ox * width, x1 = x0 + width
                var sum = 0.0
                for y in (y0 / fh)..<min((y1 + fh - 1) / fh, height) {
                    let wy = Double(min((y + 1) * fh, y1) - max(y * fh, y0))
                    var row = 0.0
                    for x in (x0 / fw)..<min((x1 + fw - 1) / fw, width) {
                        row += Double(min((x + 1) * fw, x1) - max(x * fw, x0)) * Double(luminance[y * width + x])
                    }
                    sum += wy * row
                }
                let mean = sum / (Double(width) * Double(height))
                let limit = Double(guideLimit)
                g[oy * fw + ox] = .maximum(.minimum(log2((mean * mean + floor).squareRoot()), limit), -limit)
            }
        }
        let mu = box(g, width: fw, height: fh, radius: radius)
        let square = box(g.map { $0 * $0 }, width: fw, height: fh, radius: radius)
        let epsilon = Double(parameters.epsilon)
        var a = [Double](repeating: 0, count: fw * fh), b = a
        for i in 0..<(fw * fh) {
            let variance = max(square[i] - mu[i] * mu[i], 0)
            a[i] = variance / (variance + epsilon)
            b[i] = mu[i] - a[i] * mu[i]
        }
        let meanA = box(a, width: fw, height: fh, radius: coefficientRadius)
        let meanB = box(b, width: fw, height: fh, radius: coefficientRadius)
        return (fw, fh, (0..<(fw * fh)).map { SIMD2(Float(meanA[$0]), Float(meanB[$0])) })
    }

    /// `values`' mean over the square of side 2 `radius` + 1 about each pixel, the edges clamped:
    /// a window past the field repeats its edge pixel.
    static func box(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        func line(_ v: [Double]) -> [Double] {
            let n = v.count
            var prefix = [Double](repeating: 0, count: n + 1)
            for i in 0..<n { prefix[i + 1] = prefix[i] + v[i] }
            return (0..<n).map { i in
                let lo = i - radius, hi = i + radius
                let inside = prefix[min(hi, n - 1) + 1] - prefix[max(lo, 0)]
                let edges = Double(max(0, -lo)) * v[0] + Double(max(0, hi - (n - 1))) * v[n - 1]
                return (inside + edges) / Double(2 * radius + 1)
            }
        }
        var across = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = line(Array(values[(y * width)..<((y + 1) * width)]))
            for x in 0..<width { across[y * width + x] = row[x] }
        }
        var out = across
        for x in 0..<width {
            let column = line((0..<height).map { across[$0 * width + x] })
            for y in 0..<height { out[y * width + x] = column[y] }
        }
        return out
    }

    /// The coefficients at `uv`, bilinear between the four nearest texel centres with the edges
    /// clamped, as `tone_base_log2` reads them.
    static func interpolated(_ coefficients: [SIMD2<Float>], width: Int, height: Int, uv: SIMD2<Float>) -> SIMD2<Float> {
        let s = uv * SIMD2(Float(width), Float(height)) - 0.5
        let cell = s.rounded(.down)
        let t = s - cell
        let x0 = min(max(Int(cell.x), 0), width - 1), x1 = min(max(Int(cell.x) + 1, 0), width - 1)
        let y0 = min(max(Int(cell.y), 0), height - 1), y1 = min(max(Int(cell.y) + 1, 0), height - 1)
        func at(_ x: Int, _ y: Int) -> SIMD2<Float> { coefficients[y * width + x] }
        let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * t.x
        let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * t.x
        return top + (bottom - top) * t.y
    }
}
