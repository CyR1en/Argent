import Foundation
import Metal
import Testing
@testable import ArgentCore

/// The local tone base (`ToneBaseField`) on synthetic frames: the GPU against the CPU reference,
/// and the filter's properties. Tests of a property that holds for any constants make their own;
/// those whose bounds hold only for the compiler's say so.
@Suite struct ToneBaseFieldTests {
    /// A shape like the compiler's at a smaller field, so the CPU reference stays quick.
    private static let small = ToneBaseParameters(radiusFraction: 0.05, epsilon: 0.7, fieldLongSide: 256,
                                                  coefficientRadiusShare: 0.5)
    /// Compiler 2026-10-29-1's constants.
    private static let compiler = ToneBaseParameters.compiler2026_10_29_1

    /// A frame of `light(x, y)` as the half floats a texture holds, and that light as floats.
    static func frame(_ gpu: GPU, width: Int, height: Int,
                      light: (Int, Int) -> SIMD3<Float>) throws -> (frame: LinearFrame, pixels: [SIMD3<Float>]) {
        let texture = try gpu.texturePool.acquire(width: width, height: height)
        var halves = [Float16](repeating: 1, count: width * height * 4)
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = light(x, y), i = (y * width + x) * 4
                halves[i] = Float16(rgb.x); halves[i + 1] = Float16(rgb.y); halves[i + 2] = Float16(rgb.z)
                pixels.append(SIMD3(Float(halves[i]), Float(halves[i + 1]), Float(halves[i + 2])))
            }
        }
        halves.withUnsafeBytes { texture.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                         withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return (LinearFrame(image: texture, decoderVersion: "test", scale: 1), pixels)
    }

    /// Gray light `stops` from mid-gray.
    static func gray(_ stops: Float) -> SIMD3<Float> { SIMD3(repeating: 0.18 * exp2(stops)) }

    /// A value from 0 to 1 for each pixel, the same every run.
    static func hash(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
        h ^= h >> 13; h = h &* 0x5bd1_e995; h ^= h >> 15
        return Float(h & 0xffff) / 65535
    }

    /// Something of everything: regions with sharp edges between them, a gradient, fine texture
    /// and colour, with `specks` a sprinkle of signed light and black.
    private static func busy(_ x: Int, _ y: Int, width: Int, height: Int, specks: Bool = true) -> SIMD3<Float> {
        let u = Float(x) / Float(width), v = Float(y) / Float(height)
        var stops: Float = u < 0.3 ? -5 : (v < 0.4 ? 2.5 : -1 + 3 * (u - 0.3))
        stops += ((x / 3 + y / 3) % 2 == 0 ? 0.25 : -0.25) * (v > 0.7 ? 1 : 0)
        stops += 0.6 * sin(Float(x) * 0.05) * cos(Float(y) * 0.031)
        let tint = SIMD3<Float>(1 + 0.3 * u, 1, 1 - 0.4 * v)
        if specks && x % 97 == 13 && y % 89 == 7 { return SIMD3(-0.002, 0.001, -0.004) }
        if specks && x % 71 == 5 && y % 67 == 3 { return .zero }
        return gray(stops) * tint
    }

    /// A scene that tells averaging in linear light from averaging in log: dark foliage and trees
    /// against the sky that change a stop or two from one pixel to the next, a sky with a fine
    /// checker, and a textured gradient.
    static func scene(_ x: Int, _ y: Int, width: Int, height: Int) -> SIMD3<Float> {
        let u = Float(x) / Float(width), v = Float(y) / Float(height)
        let stops: Float
        if u < 0.3 {
            stops = -5 + 2 * (hash(x, y) - 0.5)
        } else if v < 0.4 {
            stops = u > 0.55 && u < 0.75 && v > 0.1 ? (hash(x, y) < 0.5 ? 2.5 : -1.5)
                : 2.5 + ((x / 3 + y / 3) % 2 == 0 ? 0.25 : -0.25)
        } else {
            stops = -1 + 3 * (u - 0.3) + 0.6 * sin(Float(x) * 0.02) * cos(Float(y) * 0.013)
        }
        return gray(stops)
    }

    private static func largest(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    /// The GPU's field and each pixel's base against the CPU reference, for a frame the field's
    /// size (no averaging), one that the field shrinks by an uneven ratio, and frames smaller than
    /// the box, with the coefficients boxed at half the radius and at all of it.
    @Test(arguments: [(1, 1), (5, 3), (200, 130), (611, 397)], [Float(0.5), 1])
    func gpuMatchesTheCPUReference(size: (width: Int, height: Int), share: Float) throws {
        let (width, height) = size
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        let parameters = ToneBaseParameters(radiusFraction: Self.small.radiusFraction, epsilon: Self.small.epsilon,
                                            fieldLongSide: Self.small.fieldLongSide, coefficientRadiusShare: share)
        let (frame, pixels) = try Self.frame(gpu, width: width, height: height) { Self.busy($0, $1, width: width, height: height) }
        let made = try field.field(for: frame, parameters: parameters)
        let size = parameters.fieldSize(width: width, height: height)
        #expect(made.width == size.width && made.height == size.height)
        #expect(made.texture.pixelFormat == .rg32Float)

        let reference = ToneBaseField.referenceField(luminance: pixels.map(ToneBaseField.luminance), width: width,
                                                     height: height, parameters: parameters)
        let coefficients = ToneBaseField.coefficients(of: made)
        let a = zip(coefficients, reference.coefficients).map { abs($0.x - $1.x) }.max() ?? 0
        let b = zip(coefficients, reference.coefficients).map { abs($0.y - $1.y) }.max() ?? 0
        #expect(coefficients.allSatisfy { $0.x >= 0 && $0.x <= 1 })
        let gpuBase = try field.baseMap(for: frame, field: made)
        let cpuBase = ToneBaseField.reference(pixels: pixels, width: width, height: height, parameters: parameters)
        let base = Self.largest(gpuBase, cpuBase)
        print(String(format: "MEASURE tone base %dx%d, coefficient boxes %.1f of the radius, GPU against CPU: box(a) %.1e, box(b) %.1e stops, base %.1e stops",
                     width, height, share, a, b, base))
        #expect(a < 5e-5 && b < 5e-5 && base < 1e-4)
    }

    /// Light `c` stops brighter makes a base `c` higher, to float precision: on the CPU for any
    /// `c`, on the GPU for whole stops, which half floats scale exactly.
    @Test func addingStopsAddsThemToTheBase() throws {
        let width = 300, height = 200
        let light = { (x: Int, y: Int) in Self.busy(x, y, width: width, height: height, specks: false) }
        let pixels = (0..<(width * height)).map { light($0 % width, $0 / width) }
        let base = ToneBaseField.reference(pixels: pixels, width: width, height: height, parameters: Self.small)
        var worst: Float = 0
        for c: Float in [1.37, -2.6] {
            let shifted = ToneBaseField.reference(pixels: pixels.map { $0 * exp2(c) }, width: width, height: height,
                                                  parameters: Self.small)
            worst = max(worst, zip(shifted, base).map { abs($0 - $1 - c) }.max() ?? 0)
        }

        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        let (frame, _) = try Self.frame(gpu, width: width, height: height, light: light)
        let gpuBase = try field.baseMap(for: frame, field: try field.field(for: frame, parameters: Self.small))
        var gpuWorst: Float = 0
        for c: Float in [2, -3] {
            let (shifted, _) = try Self.frame(gpu, width: width, height: height) { light($0, $1) * exp2(c) }
            let shiftedBase = try field.baseMap(for: shifted, field: try field.field(for: shifted, parameters: Self.small))
            gpuWorst = max(gpuWorst, zip(shiftedBase, gpuBase).map { abs($0 - $1 - c) }.max() ?? 0)
        }
        print(String(format: "MEASURE tone base shifted by c stops, base less c: CPU %.1e, GPU %.1e stops", worst, gpuWorst))
        #expect(worst < 1e-5 && gpuWorst < 1e-5)
    }

    /// A flat frame is its own base, at any level and any constants.
    @Test func aFlatFrameIsItsOwnBase() throws {
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        for stops: Float in [-12, -3, 0, 4.5] {
            let (frame, pixels) = try Self.frame(gpu, width: 640, height: 427) { _, _ in Self.gray(stops) }
            let guide = ToneBaseField.guide(pixels[0])
            for parameters in [Self.small, Self.compiler] {
                let base = try field.baseMap(for: frame, field: try field.field(for: frame, parameters: parameters))
                #expect(base.allSatisfy { abs($0 - guide) <= 2e-6 }, "\(stops) stops")
            }
            let small = ToneBaseField.reference(pixels: Array(pixels[0..<(64 * 40)]), width: 64, height: 40, parameters: Self.small)
            #expect(small.allSatisfy { abs($0 - guide) <= 2e-6 })
        }
    }

    /// One non-finite pixel (a decode is not expected to make one) spoils only its neighbourhood:
    /// the guide is held to ±40 stops, so the filters' running sums never turn to NaN, and the
    /// base stays finite everywhere and exact beyond the filters' reach.
    @Test(arguments: [Float.infinity, -Float.infinity, Float.nan])
    func aNonFinitePixelStaysLocal(_ bad: Float) throws {
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        let width = 1024, height = 683, x0 = 300, y0 = 200
        let (frame, pixels) = try Self.frame(gpu, width: width, height: height) { x, y in
            x == x0 && y == y0 ? SIMD3(repeating: bad) : Self.gray(-1)
        }
        let guide = ToneBaseField.guide(pixels[0])
        let base = try field.baseMap(for: frame, field: try field.field(for: frame, parameters: Self.compiler))
        let finite = base.allSatisfy { $0.isFinite }
        #expect(finite)
        let reach = 2 * Int((Self.compiler.radiusFraction * Float(width)).rounded()) + 2
        var far = 0, off = 0
        for y in 0..<height where abs(y - y0) > reach {
            for x in 0..<width where abs(x - x0) > reach {
                far += 1
                if abs(base[y * width + x] - guide) > 2e-6 { off += 1 }
            }
        }
        #expect(far > 0 && off == 0, "\(off) of \(far) pixels beyond the filters' reach moved")
    }

    /// The base beside a step of `contrast` stops between halves of a frame (the edge cutting a
    /// field pixel in two), against each pixel's own guide: the largest error at each whole number
    /// of field pixels from the edge, and nothing beyond twice the radius and a pixel, where no
    /// window reaches across.
    static func edgeProfile(_ gpu: GPU, _ field: ToneBaseField, contrast: Float,
                                     parameters: ToneBaseParameters) throws -> [Float] {
        let width = 2048, height = 1366, edge = 1001
        let (frame, pixels) = try Self.frame(gpu, width: width, height: height) { x, _ in Self.gray(x < edge ? -contrast / 2 : contrast / 2) }
        let base = try field.baseMap(for: frame, field: try field.field(for: frame, parameters: parameters))
        let pitch = Float(parameters.fieldSize(width: width, height: height).width) / Float(width)
        var profile = [Float](repeating: 0, count: 80)
        for y in stride(from: 300, to: 1000, by: 7) {
            for x in 0..<width {
                let distance = Int(abs(Float(x) + 0.5 - Float(edge)) * pitch)
                let error = base[y * width + x] - ToneBaseField.guide(pixels[y * width + x])
                if distance < profile.count && abs(error) > abs(profile[distance]) { profile[distance] = error }
            }
        }
        return profile
    }

    /// The base about a bright square `contrast` stops above its surround, 300 field pixels wide,
    /// against each pixel's own guide: the largest error within `near` field pixels of a corner,
    /// and of an edge's middle third.
    static func squareLean(_ gpu: GPU, _ field: ToneBaseField, contrast: Float, parameters: ToneBaseParameters,
                           near: Float = 4) throws -> (corner: Float, edge: Float) {
        let width = 2048, height = 1366, x0 = 724, x1 = 1324, y0 = 383, y1 = 983
        let (frame, pixels) = try Self.frame(gpu, width: width, height: height) { x, y in
            Self.gray((x0..<x1).contains(x) && (y0..<y1).contains(y) ? contrast / 2 : -contrast / 2)
        }
        let base = try field.baseMap(for: frame, field: try field.field(for: frame, parameters: parameters))
        let pitch = Float(parameters.fieldSize(width: width, height: height).width) / Float(width)
        var corner: Float = 0, edge: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let dx = min(abs(Float(x) + 0.5 - Float(x0)), abs(Float(x) + 0.5 - Float(x1))) * pitch
                let dy = min(abs(Float(y) + 0.5 - Float(y0)), abs(Float(y) + 0.5 - Float(y1))) * pitch
                let error = abs(base[y * width + x] - ToneBaseField.guide(pixels[y * width + x]))
                if dx < near && dy < near { corner = max(corner, error) }
                let middle = (x > x0 + 200 && x < x1 - 200 && dy < near) || (y > y0 + 200 && y < y1 - 200 && dx < near)
                if middle { edge = max(edge, error) }
            }
        }
        return (corner, edge)
    }

    /// Beyond the two radii and a pixel, no window reaches across an edge and the base is each
    /// side's own; nearer, the base leans toward the other side the less the step's variance
    /// outweighs epsilon. The bounds hold for the compiler's constants, radius 15 field pixels,
    /// coefficient boxes of 8 and epsilon 0.7, which the measurement prints.
    @Test func aStrongEdgeKeepsTheBaseOnEachSide() throws {
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        let parameters = Self.compiler
        let reach = parameters.radius(fieldLong: 1024) + parameters.coefficientRadius(fieldLong: 1024) + 2
        for contrast: Float in [8, 3] {
            let profile = try Self.edgeProfile(gpu, field, contrast: contrast, parameters: parameters)
            print("MEASURE tone base error beside a \(contrast)-stop edge by field pixels from it, the compiler's constants:",
                  [0, 1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 25, 30, 40].map { String(format: "%d:%+.3f", $0, profile[$0]) }.joined(separator: " "))
            #expect(profile[reach...].allSatisfy { abs($0) < 1e-5 })
            if contrast == 8 {
                #expect(profile.allSatisfy { abs($0) < 0.21 })
                #expect(profile[3...].allSatisfy { abs($0) < 0.17 })
                #expect(profile[10...].allSatisfy { abs($0) < 0.1 })
                #expect(profile[20...].allSatisfy { abs($0) < 0.03 })
            }
        }
        // A smaller epsilon keeps the edge closer, and so do coefficient boxes smaller than the
        // guide's: half the radius leans less than half as far as all of it.
        func lean(_ epsilon: Float, _ share: Float) throws -> Float {
            let profile = try Self.edgeProfile(gpu, field, contrast: 8, parameters: ToneBaseParameters(
                radiusFraction: parameters.radiusFraction, epsilon: epsilon, fieldLongSide: 1024, coefficientRadiusShare: share))
            return profile.map(abs).max()!
        }
        let compiler = try lean(parameters.epsilon, parameters.coefficientRadiusShare)
        #expect(try lean(0.25, parameters.coefficientRadiusShare) < compiler)
        #expect(compiler < 0.5 * (try lean(parameters.epsilon, 1)))
    }

    /// A checker of plus and minus a quarter stop: finer than a field pixel it leaves the base
    /// flat, and coarser but finer than the window the base keeps `v / (v + epsilon)` of it, `v`
    /// its variance, a twelfth at the compiler's epsilon, so a gain read from the base keeps the
    /// texture.
    @Test(arguments: [Float(0.7), 0.25])
    func fineTextureStaysOutOfTheBase(epsilon: Float) throws {
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        let width = 2048, height = 1366
        let parameters = ToneBaseParameters(radiusFraction: Self.compiler.radiusFraction, epsilon: epsilon, fieldLongSide: 1024,
                                            coefficientRadiusShare: Self.compiler.coefficientRadiusShare)
        let variance: Float = 0.0625
        for cell in [1, 2, 8, 32] {
            let (frame, pixels) = try Self.frame(gpu, width: width, height: height) { x, y in
                Self.gray((x / cell + y / cell) % 2 == 0 ? 0.25 : -0.25)
            }
            let base = try field.baseMap(for: frame, field: try field.field(for: frame, parameters: parameters))
            var lowest = Float.infinity, highest = -Float.infinity, low = Float.infinity, high = -Float.infinity
            for y in 400..<966 {
                for x in 700..<1348 {
                    lowest = min(lowest, base[y * width + x]); highest = max(highest, base[y * width + x])
                    let g = ToneBaseField.guide(pixels[y * width + x])
                    low = min(low, g); high = max(high, g)
                }
            }
            let kept = (highest - lowest) / (high - low)
            print(String(format: "MEASURE tone base keeps %.3f of a +-0.25-stop checker of %d-pixel cells (%.1f field pixels), epsilon %.2f",
                         kept, cell, Float(cell) / 2, epsilon))
            #expect(abs(kept - (cell == 1 ? 0 : variance / (variance + epsilon))) < 0.01)
        }
    }

    /// A frame and its quarter, area-resized as a preview is the develop in linear light. With
    /// fields of one size, as a develop's and the frame view's, they are the same field; with the
    /// quarter smaller than the field, as the contact sheet's, the quarter's field is coarser and
    /// agrees less closely. The field is compared through the quarter's own guide, and the base
    /// as each makes it, the frame's averaged onto the quarter's pixels.
    @Test func aFrameAndItsQuarterMakeTheSameField() throws {
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        let resize = try AreaResize(gpu: gpu)
        let width = 2048, height = 1366
        let (frame, _) = try Self.frame(gpu, width: width, height: height) { Self.scene($0, $1, width: width, height: height) }
        let quarter = LinearFrame(image: try resize.resized(frame.texture, scale: 0.25), decoderVersion: "test", scale: 0.25)
        for parameters in [ToneBaseParameters(radiusFraction: 0.03, epsilon: 0.25, fieldLongSide: 256), Self.compiler] {
            let (fieldError, baseError) = try Self.agreement(field, frame, quarter, parameters: parameters)
            print("MEASURE tone base \(width)x\(height) against its quarter, field long side \(parameters.fieldLongSide): field",
                  fieldError.summary, "| base", baseError.summary)
            if parameters.fieldLongSide == 256 {
                #expect(fieldError.max < 2e-3)
            } else {
                #expect(fieldError.p99 < 0.25 && fieldError.mean < 0.03)
            }
        }
    }

    struct Errors {
        let max: Float, p99: Float, p90: Float, mean: Float
        init(_ differences: [Float]) {
            let sorted = differences.map(abs).sorted()
            max = sorted.last ?? 0
            p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
            p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
            mean = sorted.reduce(0, +) / Float(sorted.count)
        }
        var summary: String { String(format: "max %.4f p99 %.4f p90 %.4f mean %.4f stops", max, p99, p90, mean) }
    }

    /// How `small`'s base agrees with `large`'s, of which it is an area-resize: through `small`'s
    /// own guide, `large`'s field against `small`'s; and `large`'s base averaged onto `small`'s
    /// pixels against `small`'s base.
    static func agreement(_ field: ToneBaseField, _ large: LinearFrame, _ small: LinearFrame,
                          parameters: ToneBaseParameters) throws -> (field: Errors, base: Errors) {
        let largeField = try field.field(for: large, parameters: parameters)
        let smallField = try field.field(for: small, parameters: parameters)
        let largeCoefficients = ToneBaseField.coefficients(of: largeField)
        let smallBase = try field.baseMap(for: small, field: smallField)
        let halves = ExposureAnalyzer.pixels(of: small.texture)
        var fieldDifferences: [Float] = []
        fieldDifferences.reserveCapacity(small.width * small.height)
        for y in 0..<small.height {
            for x in 0..<small.width {
                let i = (y * small.width + x) * 4
                let g = ToneBaseField.guide(SIMD3(Float(halves[i]), Float(halves[i + 1]), Float(halves[i + 2])))
                let uv = SIMD2<Float>((Float(x) + 0.5) / Float(small.width), (Float(y) + 0.5) / Float(small.height))
                let ab = ToneBaseField.interpolated(largeCoefficients, width: largeField.width, height: largeField.height, uv: uv)
                fieldDifferences.append(ab.x * g + ab.y - smallBase[y * small.width + x])
            }
        }
        let largeBase = try field.baseMap(for: large, field: largeField)
        let averaged = areaAverage(largeBase, width: large.width, height: large.height, to: small.width, small.height)
        return (Errors(fieldDifferences), Errors(zip(averaged, smallBase).map { $0 - $1 }))
    }

    /// `values` (`width` by `height`) area-averaged onto `ow` by `oh`, weighted as `AreaResize`.
    static func areaAverage(_ values: [Float], width sw: Int, height sh: Int, to ow: Int, _ oh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: ow * oh)
        for oy in 0..<oh {
            let y0 = oy * sh, y1 = y0 + sh
            for ox in 0..<ow {
                let x0 = ox * sw, x1 = x0 + sw
                var sum = 0.0
                for y in (y0 / oh)..<min((y1 + oh - 1) / oh, sh) {
                    let wy = Double(min((y + 1) * oh, y1) - max(y * oh, y0))
                    var row = 0.0
                    for x in (x0 / ow)..<min((x1 + ow - 1) / ow, sw) {
                        row += Double(min((x + 1) * ow, x1) - max(x * ow, x0)) * Double(values[y * sw + x])
                    }
                    sum += wy * row
                }
                out[oy * ow + ox] = Float(sum / (Double(sw) * Double(sh)))
            }
        }
        return out
    }

    /// A field takes three field-sized textures from the pool and gives back two when it is made;
    /// another frame of the size reuses them, and nothing frame-sized is taken.
    @Test func fieldsReuseThePoolAndTakeNothingFrameSized() throws {
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        let width = 1500, height = 1000
        let (frame, _) = try Self.frame(gpu, width: width, height: height) { Self.busy($0, $1, width: width, height: height) }
        let size = Self.compiler.fieldSize(width: width, height: height)
        let start = gpu.texturePool.allocationCount
        do {
            let made = try field.field(for: frame, parameters: Self.compiler)
            #expect(gpu.texturePool.allocationCount == start + 3)
            #expect(gpu.texturePool.idleByteCount == 2 * size.width * size.height * 8)
            withExtendedLifetime(made) {}
        }
        for _ in 0..<3 {
            let made = try field.field(for: frame, parameters: Self.compiler)
            withExtendedLifetime(made) {}
        }
        #expect(gpu.texturePool.allocationCount == start + 3)
        #expect(gpu.texturePool.idleByteCount == 3 * size.width * size.height * 8)
    }

    @Test func cachesOnlyTheSameDecodeAndParameters() throws {
        let gpu = try GPU(), field = try ToneBaseField(gpu: gpu)
        let (first, _) = try Self.frame(gpu, width: 48, height: 32) { Self.gray(Float($0 + $1) / 20) }
        let (second, _) = try Self.frame(gpu, width: 48, height: 32) { Self.gray(Float($0 - $1) / 20) }
        let a = try field.field(for: first, parameters: Self.compiler, reuse: true)
        #expect(try field.field(for: first, parameters: Self.compiler, reuse: true) === a)
        #expect(field.buildCount == 1)
        let b = try field.field(for: second, parameters: Self.compiler, reuse: true)
        #expect(b !== a)
        #expect(field.buildCount == 2)
        let changed = ToneBaseParameters(radiusFraction: Self.compiler.radiusFraction, epsilon: Self.compiler.epsilon + 1,
                                       fieldLongSide: Self.compiler.fieldLongSide,
                                       coefficientRadiusShare: Self.compiler.coefficientRadiusShare)
        #expect(try field.field(for: second, parameters: changed, reuse: true) !== b)
        #expect(field.buildCount == 3)
        field.removeAll()
        _ = try field.field(for: second, parameters: changed, reuse: true)
        #expect(field.buildCount == 4)
    }

    @Test func cacheRetainsTheDecodeAndReleasesItWhenClearedOrReplaced() throws {
        let gpu = try GPU(), field = try ToneBaseField(gpu: gpu)
        weak var image: PooledTexture?
        weak var output: PooledTexture?
        do {
            let (frame, _) = try Self.frame(gpu, width: 48, height: 32) { _, _ in Self.gray(0) }
            image = frame.image
            output = try field.field(for: frame, parameters: Self.compiler, reuse: true)
        }
        #expect(image != nil && output != nil)
        do {
            let (other, _) = try Self.frame(gpu, width: 48, height: 32) { _, _ in Self.gray(1) }
            _ = try field.field(for: other, parameters: Self.compiler, reuse: true)
            #expect(image == nil && output == nil)
            image = other.image
            output = try field.field(for: other, parameters: Self.compiler, reuse: true)
        }
        field.removeAll()
        #expect(image == nil && output == nil)
    }
}

/// The local tone base on the CC0 a7 IV sample and at a develop's size: how a develop's base
/// agrees with its previews', and what the field costs. Runs only with ARGENT_MEASURE=1 and the
/// samples (`scripts/fetch-samples.sh`):
///
///     ARGENT_MEASURE=1 swift test --filter ToneBaseFieldMeasureTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"), .serialized)
struct ToneBaseFieldMeasureTests {
    private static let sample = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")

    /// The full-size decode against its area-resizes to the frame view's sizes and the contact
    /// sheet's, with the compiler's constants, and the field's GPU time for each.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: ToneBaseFieldMeasureTests.sample.path)))
    func aDevelopAndItsPreviewsAgree() throws {
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        let resize = try AreaResize(gpu: gpu)
        let develop = try AppleRawDecoder(gpu: gpu).decode(Self.sample, options: DecodeOptions())
        func time(_ frame: LinearFrame) throws {
            var times: [Double] = []
            for _ in 0..<8 {
                let made = try field.field(for: frame, parameters: .compiler2026_10_29_1)
                times.append(field.lastGPUSeconds * 1000)
                withExtendedLifetime(made) {}
            }
            times.sort()
            print(String(format: "MEASURE tone base field for the a7 IV at %dx%d: GPU median %.2f ms (%.2f to %.2f)",
                         frame.width, frame.height, times[times.count / 2], times.first!, times.last!))
        }
        try time(develop)
        for longSide in [3800, 2190, 1752, 960] {
            let scale = Double(longSide) / Double(max(develop.width, develop.height))
            let preview = LinearFrame(image: try resize.resized(develop.texture, scale: scale), decoderVersion: "test", scale: Float(scale))
            try time(preview)
            let (fieldError, baseError) = try ToneBaseFieldTests.agreement(field, develop, preview, parameters: .compiler2026_10_29_1)
            print("MEASURE tone base a7 IV \(develop.width)x\(develop.height) against \(preview.width)x\(preview.height): field",
                  fieldError.summary, "| base", baseError.summary)
            if longSide >= 1024 { #expect(fieldError.p99 < 0.05) }
        }
    }

    /// The halo beside edges and at a bright square's corners, and the texture each keeps, with
    /// the coefficients boxed at the guide's radius and at half of it, for the provisional and the
    /// fitted constants.
    @Test func haloOfFullAndHalfRadiusCoefficientBoxes() throws {
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        for (name, radiusFraction, epsilon) in [("provisional", Float(0.03), Float(0.25)), ("fitted", 0.015, 0.7)] {
            for share: Float in [1, 0.5] {
                let parameters = ToneBaseParameters(radiusFraction: radiusFraction, epsilon: epsilon, fieldLongSide: 1024,
                                                    coefficientRadiusShare: share)
                for contrast: Float in [8, 3] {
                    let profile = try ToneBaseFieldTests.edgeProfile(gpu, field, contrast: contrast, parameters: parameters)
                    let beyond = (0..<profile.count).first { profile[$0...].allSatisfy { abs($0) < 0.05 } } ?? profile.count
                    print("MEASURE tone base halo, \(name) share \(share), \(contrast)-stop edge:",
                          [0, 1, 2, 3, 5, 8, 10, 15, 20, 30, 40].map { String(format: "%d:%+.3f", $0, profile[$0]) }.joined(separator: " "),
                          "| under 0.05 beyond \(beyond) field px")
                }
                let square = try ToneBaseFieldTests.squareLean(gpu, field, contrast: 8, parameters: parameters)
                var kept: [String] = []
                for cell in [2, 8, 32] {
                    let (frame, pixels) = try ToneBaseFieldTests.frame(gpu, width: 2048, height: 1366) { x, y in
                        ToneBaseFieldTests.gray((x / cell + y / cell) % 2 == 0 ? 0.25 : -0.25)
                    }
                    let base = try field.baseMap(for: frame, field: try field.field(for: frame, parameters: parameters))
                    var lowest = Float.infinity, highest = -Float.infinity
                    for y in 400..<966 { for x in 700..<1348 { lowest = min(lowest, base[y * 2048 + x]); highest = max(highest, base[y * 2048 + x]) } }
                    let g = pixels.map(ToneBaseField.guide)
                    kept.append(String(format: "%d px %.3f", cell, (highest - lowest) / (g.max()! - g.min()!)))
                }
                print(String(format: "MEASURE tone base halo, %@ share %.1f: 8-stop square corner %.3f, edge middle %.3f; texture kept ",
                             name, share, square.corner, square.edge) + kept.joined(separator: ", "))
            }
        }
    }

    /// The field's GPU time at a develop's size and the previews' on `scene`, whose pixel-sized
    /// random texture makes it slower than a decode (11 ms at 33 MP against the sample's 5.5, as
    /// the texture's lossless compression has less to work with, it seems), from the pool's
    /// textures after the first, with the compiler's constants.
    @Test func cost() throws {
        let gpu = try GPU()
        let field = try ToneBaseField(gpu: gpu)
        for (width, height) in [(7008, 4672), (3800, 2533), (2190, 1460), (960, 640)] {
            let (frame, _) = try ToneBaseFieldTests.frame(gpu, width: width, height: height) { x, y in
                ToneBaseFieldTests.scene(x, y, width: width, height: height)
            }
            _ = try field.field(for: frame, parameters: .compiler2026_10_29_1)
            let allocations = gpu.texturePool.allocationCount
            var times: [Double] = []
            for _ in 0..<10 {
                let made = try field.field(for: frame, parameters: .compiler2026_10_29_1)
                times.append(field.lastGPUSeconds * 1000)
                withExtendedLifetime(made) {}
            }
            times.sort()
            let size = ToneBaseParameters.compiler2026_10_29_1.fieldSize(width: width, height: height)
            print(String(format: "MEASURE tone base field for %dx%d: GPU median %.2f ms (%.2f to %.2f), field %dx%d, %.1f MB held while made, %.1f MB kept",
                         width, height, times[times.count / 2], times.first!, times.last!, size.width, size.height,
                         Double(3 * size.width * size.height * 8) / 1e6, Double(size.width * size.height * 8) / 1e6))
            #expect(gpu.texturePool.allocationCount == allocations)
        }
    }
}
