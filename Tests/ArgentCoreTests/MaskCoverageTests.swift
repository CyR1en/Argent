import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Shared shapes and readers. The picture is a 33 MP 3:2 frame unless a test says otherwise.
private enum Field {
    static let picture = try! MaskSpace(width: 7008, height: 4672)
    /// What a value read from the array may lie from the reference: one half-float step at the top of the range, 2^-11, with the
    /// float parity added. This GPU rounds a write to `rgba16Float` toward zero (measured), not to nearest, so the whole step is used.
    static let halfFloatStep: Float = 4.9e-4 + 1e-5

    static func linear(_ fx: Float, _ fy: Float, _ zx: Float, _ zy: Float, operation: MaskOperation = .add, invert: Bool = false) -> MaskComponent {
        MaskComponent(operation: operation, shape: .linear(.init(full: MaskPoint(x: fx, y: fy), zero: MaskPoint(x: zx, y: zy))), invert: invert)
    }

    static func radial(_ x: Float, _ y: Float, _ a: Float, _ b: Float, angle: Float = 0, feather: Float = 50, operation: MaskOperation = .add,
                       invert: Bool = false) -> MaskComponent {
        MaskComponent(operation: operation, shape: .radial(.init(center: MaskPoint(x: x, y: y), semiAxisA: a, semiAxisB: b, angle: angle, feather: feather)),
                      invert: invert)
    }

    static func mask(_ components: MaskComponent..., isEnabled: Bool = true, amount: Float = 1, exposure: Float = 0, id: UUID = UUID()) -> Mask {
        Mask(id: id, isEnabled: isEnabled, components: components, amount: amount, adjustments: try! ManualAdjustments(exposureEV: exposure))
    }

    static func cpu(_ mask: Mask, _ x: Float, _ y: Float) throws -> Float { try MaskCoverage.reference(mask, at: MaskPoint(x: x, y: y)) }

    /// A cache of its own, so a test's counts are its own.
    static func cache(on gpu: GPU, maximumBytes: Int = MaskFieldCache.defaultMaximumBytes) -> MaskFieldCache {
        MaskFieldCache(device: gpu.device, queue: gpu.queue, maximumBytes: maximumBytes)
    }

    /// A float array as a bake writes it, for comparing the kernel's floats with the CPU's before a half float rounds them.
    static func floatArray(_ gpu: GPU, _ size: MaskFieldSize, slices: Int = 1) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = size.width
        descriptor.height = size.height
        descriptor.arrayLength = slices
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return try #require(gpu.device.makeTexture(descriptor: descriptor))
    }

    /// One channel of a float array, in texture rows: row 0 the picture's bottom.
    static func channel(_ texture: MTLTexture, slice: Int = 0, channel: Int = 0) -> [Float] {
        let width = texture.width, height = texture.height
        var texels = [Float](repeating: 0, count: width * height * 4)
        texels.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 16, bytesPerImage: 0,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: slice)
        }
        return (0..<(width * height)).map { texels[$0 * 4 + channel] }
    }

    /// Every channel of a slice as the array holds its bits: to compare what is written, and what was left alone, exactly.
    static func bits(_ coverage: MaskCoverage, slice: Int) -> [UInt16] {
        let texture = coverage.texture, width = texture.width, height = texture.height
        var halves = [UInt16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 8, bytesPerImage: 0,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: slice)
        }
        return halves
    }

    /// A channel of the array at a render's pixels through a real bilinear sampler, at the uv a masked kernel uses: the render's
    /// `(gid + 0.5) / size`, unflipped. Row 0 is the picture's bottom, as in a frame texture.
    static func sampled(_ gpu: GPU, _ array: MTLTexture, slice: Int = 0, channel: Int = 0, width: Int, height: Int) throws -> MTLTexture {
        let out = try GPU.makeTexture(device: gpu.device, width: width, height: height, usage: [.shaderRead, .shaderWrite], pixelFormat: .r32Float)
        let library = try gpu.device.makeLibrary(source: source, options: nil)
        let pipeline = try gpu.device.makeComputePipelineState(function: try #require(library.makeFunction(name: "sample_channel")))
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        var select = SIMD2<UInt32>(UInt32(slice), UInt32(channel))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(array, index: 0)
        encoder.setTexture(out, index: 1)
        encoder.setBytes(&select, length: 8, index: 0)
        encoder.dispatchPixels(pipeline, width: width, height: height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return out
    }

    /// `source`, an `r32Float` develop, area-averaged in linear light to `width` by `height`, with exact weights: the preview it should agree with.
    static func areaResized(_ gpu: GPU, _ source: MTLTexture, width: Int, height: Int) throws -> MTLTexture {
        let out = try GPU.makeTexture(device: gpu.device, width: width, height: height, usage: [.shaderRead, .shaderWrite], pixelFormat: .r32Float)
        let library = try gpu.device.makeLibrary(source: self.source, options: nil)
        let pipeline = try gpu.device.makeComputePipelineState(function: try #require(library.makeFunction(name: "area_average")))
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(out, index: 1)
        encoder.dispatchPixels(pipeline, width: width, height: height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return out
    }

    static func read(_ texture: MTLTexture) -> [Float] {
        let width = texture.width, height = texture.height
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return values
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void sample_channel(texture2d_array<float, access::sample> coverage [[texture(0)]],
                               texture2d<float, access::write> out [[texture(1)]],
                               constant uint2 &select [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        constexpr sampler bilinear(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5f) / float2(out.get_width(), out.get_height());
        out.write(coverage.sample(bilinear, uv, select.x)[select.y], gid);
    }

    kernel void area_average(texture2d<float, access::read> source [[texture(0)]],
                             texture2d<float, access::write> out [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint sw = source.get_width(), sh = source.get_height(), dw = out.get_width(), dh = out.get_height();
        uint x0 = gid.x * sw, x1 = x0 + sw, y0 = gid.y * sh, y1 = y0 + sh;
        float sum = 0.0f, weights = 0.0f;
        for (uint y = y0 / dh; y < min((y1 + dh - 1) / dh, sh); y++) {
            float wy = float(min((y + 1) * dh, y1) - max(y * dh, y0));
            for (uint x = x0 / dw; x < min((x1 + dw - 1) / dw, sw); x++) {
                float w = wy * float(min((x + 1) * dw, x1) - max(x * dw, x0));
                sum += w * source.read(uint2(x, y)).r;
                weights += w;
            }
        }
        out.write(float4(sum / weights), gid);
    }
    """
}

/// `MaskSpace` and the slices: which texel is which point, on a full frame, an APS-C frame, a portrait and a square.
@Suite struct MaskFieldSizeTests {
    @Test func theSliceIs2048OnThePicturesLongSideAtEveryRenderSize() throws {
        for (width, height, fieldWidth, fieldHeight) in [(7008, 4672, 2048, 1365), (4912, 3275, 2048, 1365), (3800, 2533, 2048, 1365),
                                                         (2190, 1460, 2048, 1365), (960, 640, 2048, 1365), (4608, 3072, 2048, 1365),
                                                         (4672, 7008, 1365, 2048), (3000, 3000, 2048, 2048), (40, 20, 2048, 1024)] {
            let size = MaskFieldSize(picture: try MaskSpace(width: width, height: height))
            #expect(size.width == fieldWidth && size.height == fieldHeight, "\(width) x \(height)")
        }
    }

    /// Plan section 4's figure: about 5.3 MiB a mask, four to a 21.3 MiB slice, 85.3 MiB for 16.
    @Test func aMaskCosts5Point3MiBOnAThreeTwoFrame() {
        let size = MaskFieldSize(picture: Field.picture)
        #expect(abs(Double(size.bytesPerSlice) / Double(MaskCoverage.masksPerSlice) / 1_048_576 - 5.33) < 0.01)
        #expect(abs(Double(size.bytesPerSlice * 4) / 1_048_576 - 85.3) < 0.1)
    }

    /// The extent is the picture's own, not the slice's rounding: uv 1 is the picture's far edge whatever the slice rounded to.
    @Test func aSliceReachesThePicturesOwnExtent() throws {
        let size = MaskFieldSize(picture: Field.picture)
        #expect(size.extent == MaskPoint(x: 1, y: Float(4672) / 7008))
        // The last texel's far edge, half a texel past its centre.
        let last = size.point(column: size.width - 1, yTop: size.height - 1)
        #expect(abs(last.x + 0.5 * size.texelToPoint.x - 1) < 1e-6)
        #expect(abs(last.y + 0.5 * size.texelToPoint.y - 4672.0 / 7008) < 1e-6)
    }

    /// The flip happens once, in the bake: a texture row against the picture's top, as `MaskSpace.textureRow` says of a frame.
    @Test(arguments: [(7008, 4672), (4608, 3072), (4672, 7008), (3000, 3000)])
    func aFieldsRowsAreThePicturesKnownPixels(width: Int, height: Int) throws {
        let gpu = try GPU()
        let picture = try MaskSpace(width: width, height: height)
        // Full at the picture's top edge, Zero at its bottom: coverage 1 up there and 0 down here.
        let extent = picture.extent
        let mask = Field.mask(Field.linear(0, 0, 0, extent.y))
        let cache = Field.cache(on: gpu)
        let coverage = try #require(try cache.coverage(for: MaskSet(masks: [mask]), picture: picture))
        let size = coverage.slots.size
        let bits = Field.bits(coverage, slice: 0)
        func rawTexture(column: Int, row: Int) -> Float { Float(Float16(bitPattern: bits[(row * size.width + column) * 4])) }
        #expect(rawTexture(column: size.width / 2, row: size.height - 1) > 0.98, "the top of the picture is the texture's last row")
        #expect(rawTexture(column: size.width / 2, row: 0) < 0.02, "the bottom of the picture is texture row 0")

        // A small disc in the picture's top left corner reaches only texels with a high row and a low column.
        let disc = Field.mask(Field.radial(0.05, 0.05, 0.02, 0.02, feather: 5))
        let corner = try #require(try cache.coverage(for: MaskSet(masks: [disc]), picture: picture))
        let values = corner.values(slot: 0)
        let at = { (x: Float, y: Float) -> Float in values[Int(y / size.texelToPoint.y) * size.width + Int(x / size.texelToPoint.x)] }
        #expect(at(0.05, 0.05) > 0.99, "values read back top row first")
        #expect(at(extent.x - 0.05, 0.05) < 0.001 && at(0.05, extent.y - 0.05) < 0.001 && at(extent.x - 0.05, extent.y - 0.05) < 0.001)
    }

    /// A render's pixel, at the uv a kernel samples, against that pixel's point in `MaskSpace`. Soft masks stay within R8's figure for a
    /// field at 2048, 0.0061, at any aspect ratio.
    @Test(arguments: [(7008, 4672), (4608, 3072), (4672, 7008), (3000, 3000)])
    func aPixelSamplesTheMaskAtItsOwnPoint(width: Int, height: Int) throws {
        let gpu = try GPU()
        let picture = try MaskSpace(width: width, height: height)
        let e = picture.extent
        let masks = [Field.mask(Field.radial(e.x * 0.6, e.y * 0.4, 0.35, 0.2, angle: 0.5, feather: 50)),
                     Field.mask(Field.linear(e.x * 0.2, 0.05, e.x * 0.8, e.y - 0.05)),
                     Field.mask(Field.radial(e.x * 0.5, e.y * 0.5, 0.3, 0.3, feather: 25, invert: true))]
        let renderWidth = width / 4, renderHeight = height / 4
        for (slot, mask) in masks.enumerated() {
            let coverage = try #require(try Field.cache(on: gpu).coverage(for: MaskSet(masks: [mask]), picture: picture))
            let out = Field.read(try Field.sampled(gpu, coverage.texture, slice: 0, channel: 0, width: renderWidth, height: renderHeight))
            var worst: Float = 0
            let renderSpace = try MaskSpace(width: renderWidth, height: renderHeight)
            for yTop in stride(from: 3, to: renderHeight, by: 37) {
                for column in stride(from: 5, to: renderWidth, by: 41) {
                    // The picture's point at this pixel, on the picture's own aspect; then its texture row, flipped once.
                    let uv = SIMD2((Float(column) + 0.5) / Float(renderWidth), (Float(yTop) + 0.5) / Float(renderHeight))
                    let expected = try Field.cpu(mask, uv.x * e.x, uv.y * e.y)
                    let sampled = out[renderSpace.textureRow(yTop: yTop) * renderWidth + column]
                    worst = max(worst, abs(sampled - expected))
                }
            }
            #expect(worst < 0.0061, "mask \(slot) on \(width) x \(height): \(worst)")
        }
    }
}

/// The kernel against the CPU reference, in floats and then as the half floats the array keeps.
@Suite struct MaskCoverageParityTests {
    private static let shapes: [(String, Mask)] = [
        ("linear down", Field.mask(Field.linear(0.5, 0.1, 0.5, 0.6))),
        ("linear diagonal, off the picture", Field.mask(Field.linear(-0.2, -0.3, 1.4, 1.1))),
        ("linear short", Field.mask(Field.linear(0.5, 0.3, 0.5, 0.35))),
        ("linear inverted", Field.mask(Field.linear(0.2, 0.2, 0.8, 0.5, invert: true))),
        ("radial feather 50", Field.mask(Field.radial(0.5, 0.33, 0.3, 0.3))),
        ("radial ellipse, rotated", Field.mask(Field.radial(0.4, 0.3, 0.45, 0.12, angle: 0.7, feather: 35))),
        ("radial feather 100", Field.mask(Field.radial(0.5, 0.33, 0.3, 0.2, feather: 100))),
        ("radial feather 2", Field.mask(Field.radial(0.6, 0.4, 0.2, 0.3, feather: 2))),
        ("radial inverted", Field.mask(Field.radial(0.6, 0.4, 0.2, 0.3, feather: 25, invert: true))),
        ("four, every operation", Field.mask(Field.linear(0, 0, 1, 0), Field.radial(0.5, 0.3, 0.3, 0.2, operation: .subtract),
                                             Field.linear(0, 0, 0, 0.66, operation: .intersect), Field.radial(0.7, 0.5, 0.2, 0.2, feather: 10, operation: .add, invert: true))),
    ]

    /// R8's row 2: to 1e-5, at the 2048 texels themselves. A float array holds what the kernel computed before a half float rounds it.
    @Test func theKernelMatchesTheCPUAtTheTexelsInFloats() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        for picture in [Field.picture, try MaskSpace(width: 4608, height: 3072), try MaskSpace(width: 4672, height: 7008), try MaskSpace(width: 3000, height: 3000)] {
            let size = MaskFieldSize(picture: picture)
            let array = try Field.floatArray(gpu, size)
            for (name, mask) in Self.shapes {
                let program = try MaskProgram(mask.coverage)
                try cache.bake(program, size: size, into: array)
                let out = Field.channel(array)
                var worst: Float = 0
                for row in stride(from: 0, to: size.height, by: 7) {
                    let yTop = size.height - 1 - row
                    for column in stride(from: 0, to: size.width, by: 5) {
                        let q = size.point(column: column, yTop: yTop)
                        worst = max(worst, abs(out[row * size.width + column] - program.coverage(at: SIMD2(q.x, q.y))))
                    }
                }
                #expect(worst <= 1e-5, "\(name) on \(picture.width) x \(picture.height): \(worst)")
            }
        }
    }

    /// Feather 0's edge is 0.6 % of the radius wide, so a float's own error in the radius moves it most. Reported apart, with its bound.
    @Test func theHardEdgeMatchesToAFloatsErrorInTheRadius() throws {
        let gpu = try GPU()
        let size = MaskFieldSize(picture: Field.picture)
        let array = try Field.floatArray(gpu, size)
        let mask = Field.mask(Field.radial(0.5, 0.33, 0.3, 0.3, feather: 0))
        let program = try MaskProgram(mask.coverage)
        try Field.cache(on: gpu).bake(program, size: size, into: array)
        let out = Field.channel(array)
        var worst: Float = 0
        for row in 0..<size.height {
            for column in stride(from: 0, to: size.width, by: 3) {
                let q = size.point(column: column, yTop: size.height - 1 - row)
                worst = max(worst, abs(out[row * size.width + column] - program.coverage(at: SIMD2(q.x, q.y))))
            }
        }
        #expect(worst <= 4e-5, "\(worst)")
    }

    /// Between texels, through a real bilinear sampler, where a smooth profile is locally straight: the sampler adds nothing.
    @Test func betweenTexelsASmoothMaskIsStillTheReference() throws {
        let gpu = try GPU()
        #expect(gpu.device.supports32BitFloatFiltering)
        let size = MaskFieldSize(picture: Field.picture)
        let array = try Field.floatArray(gpu, size)
        let cache = Field.cache(on: gpu)
        for (name, mask) in [("linear", Field.mask(Field.linear(0.5, 0.0, 0.5, 0.66))), ("radial", Field.mask(Field.radial(0.5, 0.33, 0.45, 0.45, feather: 100)))] {
            let program = try MaskProgram(mask.coverage)
            try cache.bake(program, size: size, into: array)
            // A render whose pixels fall between the texels.
            let width = 1777, height = Int((Float(width) * size.extent.y).rounded())
            let out = Field.read(try Field.sampled(gpu, array, width: width, height: height))
            var worst: Float = 0
            for row in stride(from: 10, to: height - 10, by: 11) {
                for column in stride(from: 10, to: width - 10, by: 13) {
                    let uv = SIMD2((Float(column) + 0.5) / Float(width), (Float(row) + 0.5) / Float(height))
                    let q = SIMD2(uv.x * size.extent.x, (1 - uv.y) * size.extent.y)
                    worst = max(worst, abs(out[row * width + column] - program.coverage(at: q)))
                }
            }
            #expect(worst <= 1e-5, "\(name): \(worst)")
        }
    }

    /// What the array keeps is the reference rounded to a half float: at most one step of its level from it, this GPU rounding a write
    /// toward zero (measured), plus the floats' own parity, which is what is left near 0, where a half float's step is finer than
    /// `1 − y`'s rounding in `Float`.
    @Test func theArrayHoldsTheReferenceAsHalfFloats() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        for (name, mask) in Self.shapes {
            let coverage = try #require(try cache.coverage(for: MaskSet(masks: [mask]), picture: Field.picture))
            let size = coverage.slots.size
            let values = coverage.values(slot: 0)
            let program = try MaskProgram(mask.coverage)
            var worst: Float = 0, inRange = true
            for yTop in stride(from: 0, to: size.height, by: 9) {
                for column in stride(from: 0, to: size.width, by: 7) {
                    let q = size.point(column: column, yTop: yTop)
                    let value = values[yTop * size.width + column], reference = program.coverage(at: SIMD2(q.x, q.y))
                    let step = Float(Float16(reference).nextUp.ulp)
                    worst = max(worst, abs(value - reference) - step - 1e-5)
                    inRange = inRange && value >= 0 && value <= 1
                }
            }
            #expect(worst <= 0, "\(name): \(worst) past a step and the parity")
            #expect(inRange, "\(name) leaves 0 to 1")
        }
    }

    /// `MaskBakeComponent` is read by the kernel as these bytes.
    @Test func theComponentHasTheKernelsLayout() {
        #expect(MemoryLayout<MaskBakeComponent>.stride == 48)
        #expect(MemoryLayout<MaskBakeComponent>.offset(of: \.origin) == 8)
        #expect(MemoryLayout<MaskBakeComponent>.offset(of: \.start) == 32)
        #expect(MemoryLayout<MaskBakeComponent>.offset(of: \.complement) == 44)
    }
}

/// The profiles' constants, as the plan gives them.
@Suite struct MaskProfileTests {
    /// Measured from Lightroom's export (plan section 6), to the fit's own worst, 0.013 at t = 0.1.
    @Test func theLinearProfileReadsAsMeasured() throws {
        let mask = Field.mask(Field.linear(0.5, 0, 0.5, 1))
        for (t, expected) in [(Float(0.1), Float(0.963)), (0.25, 0.808), (0.5, 0.437), (0.75, 0.119), (0.9, 0.020)] {
            #expect(abs(try Field.cpu(mask, 0.5, t) - expected) < 0.015, "t \(t)")
        }
        #expect(try Field.cpu(mask, 0.5, -0.05) == 1, "fully on past the Full side")
        #expect(try Field.cpu(mask, 0.5, 0.98) == 0, "fully off past b")
    }

    /// t is in pixels, perpendicular to the line: moving along the line changes nothing.
    @Test func theLinearProfileIsPerpendicularToTheLine() throws {
        let mask = Field.mask(Field.linear(0.2, 0.2, 0.8, 0.6))
        let d = SIMD2<Float>(0.6, 0.4), across = SIMD2<Float>(-d.y, d.x)
        let base = SIMD2<Float>(0.5, 0.4)
        for s in [Float(-0.5), -0.1, 0.3, 1] {
            let q = base + across * s
            #expect(abs(try Field.cpu(mask, q.x, q.y) - (try Field.cpu(mask, base.x, base.y))) < 2e-6)
        }
    }

    @Test func theRadialIsATrueEllipse() throws {
        // On the drawn outline, n = 1 at every angle, so every point has one coverage.
        let g = MaskShape.RadialGradient(center: MaskPoint(x: 0.5, y: 0.3), semiAxisA: 0.4, semiAxisB: 0.1, angle: 0.6, feather: 35)
        let mask = Mask(components: [MaskComponent(shape: .radial(g))])
        let expected = try Field.cpu(mask, 0.5 + 0.4 * cos(0.6), 0.3 + 0.4 * sin(0.6))
        for u in stride(from: Float(0), to: 6.28, by: 0.37) {
            let along = 0.4 * cos(u), across = 0.1 * sin(u)
            let x = 0.5 + along * cos(0.6) - across * sin(0.6), y = 0.3 + along * sin(0.6) + across * cos(0.6)
            #expect(abs(try Field.cpu(mask, x, y) - expected) < 2e-5, "at \(u)")
        }
        // Plan section 6: the drawn outline carries 0.12 to 0.21 of the effect at Feather 5 to 100.
        for feather in [Float(5), 10, 25, 50, 75, 100] {
            let c = try Field.cpu(Field.mask(Field.radial(0.5, 0.3, 0.3, 0.3, feather: feather)), 0.8, 0.3)
            #expect(c > 0.09 && c < 0.26, "feather \(feather): \(c)")
        }
    }

    /// Feather 0 is a smoothstep from 0.994 to 1.003, and is the same in n at any radius (it scales with the picture).
    @Test func featherZeroIsTheHardEdgeInN() throws {
        for radius in [Float(0.1), 0.3, 0.5] {
            let mask = Field.mask(Field.radial(0, 0, radius, radius, feather: 0))
            #expect(try Field.cpu(mask, radius * 0.99, 0) == 1)
            #expect(try Field.cpu(mask, radius * 1.01, 0) == 0)
            let x = (Float(0.998) - 0.994) / (1.003 - 0.994)
            #expect(abs(try Field.cpu(mask, radius * 0.998, 0) - (1 - x * x * (3 - 2 * x))) < 2e-3)
        }
    }

    @Test func theFeatherTableIsThePlansAtItsKnots() {
        let table: [(Float, Float, Float)] = [(5, 0.942, 1.032), (10, 0.849, 1.082), (15, 0.725, 1.149), (20, 0.606, 1.212), (25, 0.492, 1.269), (35, 0.309, 1.351),
                                              (50, 0.192, 1.389), (60, 0.058, 1.443), (75, -0.142, 1.501), (85, -0.246, 1.503), (100, -0.354, 1.453)]
        for (f, a, b) in table {
            let p = MaskProfiles.radial(feather: f)
            #expect(p.a == a && p.b == b && p.smootherShare == 1, "feather \(f)")
        }
        let zero = MaskProfiles.radial(feather: 0)
        #expect(zero.a == 0.994 && zero.b == 1.003 && zero.smootherShare == 0)
        // Linear in f between knots.
        let mid = MaskProfiles.radial(feather: 30)
        #expect(abs(mid.a - (0.492 + 0.309) / 2) < 1e-5 && abs(mid.b - (1.269 + 1.351) / 2) < 1e-5)
    }

    /// Dragging the slider moves the field with no jump. On each side of every knot, and at Feather 0 where the step changes shape, a
    /// change of 0.001 in Feather moves coverage little: a jump in (a, b), or a step that switched shape at Feather 0 (up to 0.058), would
    /// not shrink with that change. And for every Feather, coverage falls as n grows.
    @Test func theFeatherTableIsContinuous() throws {
        let radii = stride(from: Float(0), through: 1.7, by: 0.01).map { $0 } + stride(from: Float(0.9), through: 1.1, by: 0.0005).map { $0 }
        func profile(_ feather: Float) throws -> [Float] {
            let program = try MaskProgram(Field.mask(Field.radial(0, 0, 1, 1, feather: feather)).coverage)
            return radii.map { program.coverage(at: SIMD2($0, 0)) }
        }
        let change: Float = 0.001
        var worst: (feather: Float, by: Float) = (0, 0)
        for knot in MaskProfiles.radialKnots.map(\.feather) {
            let at = try profile(knot)
            for side in [knot - change, knot + change] where MaskShape.RadialGradient.featherRange.contains(side) {
                let moved = zip(at, try profile(side)).map { abs($0 - $1) }.max()!
                if moved > worst.by { worst = (knot, moved) }
            }
        }
        // The steepest place: below Feather 5, (a, b) moves 0.0104 and 0.0058 a unit of Feather over a band 0.009 wide.
        #expect(worst.by < 0.005, "at Feather \(worst.feather): \(worst.by)")

        let falling = radii.sorted()
        for feather in stride(from: Float(0), through: 100, by: 0.5) {
            let program = try MaskProgram(Field.mask(Field.radial(0, 0, 1, 1, feather: feather)).coverage)
            let values = falling.map { program.coverage(at: SIMD2($0, 0)) }
            let rises = zip(values, values.dropFirst()).filter { $1 > $0 + 1e-6 }.count
            #expect(rises == 0, "feather \(feather)")
        }
    }
}

/// Plan section 6's composition: left to right from 0, inverting first.
@Suite struct MaskCompositionTests {
    private static let a = Field.radial(0.4, 0.3, 0.3, 0.2, angle: 0.4, feather: 40)
    private static let b = Field.linear(0.2, 0.1, 0.9, 0.6)
    private static let c = Field.radial(0.7, 0.4, 0.25, 0.25, feather: 80)
    private static let points: [SIMD2<Float>] = stride(from: Float(0.01), to: 1, by: 0.07).flatMap { x in
        stride(from: Float(0.01), to: 0.66, by: 0.05).map { SIMD2(x, $0) }
    }

    private func value(_ component: MaskComponent, _ q: SIMD2<Float>) throws -> Float {
        var first = component
        first.operation = .add
        return try MaskProgram(Mask(components: [first]).coverage).coverage(at: q)
    }

    private func composed(_ components: [MaskComponent], _ q: SIMD2<Float>) throws -> Float {
        try MaskProgram(Mask(components: components).coverage).coverage(at: q)
    }

    /// Add's value is `c + v − cv`, its order free and its grouping free.
    @Test func addIsAssociativeAndCommutative() throws {
        let (a, b, c) = (Self.a, Self.b, Self.c)
        for q in Self.points {
            let abc = try composed([a, b, c], q)
            #expect(abs(abc - (try composed([c, a, b], q))) < 1e-6)
            #expect(abs(abc - (try composed([b, c, a], q))) < 1e-6)
            let (va, vb, vc) = (try value(a, q), try value(b, q), try value(c, q))
            func add(_ x: Float, _ y: Float) -> Float { x + y - x * y }
            #expect(abs(add(add(va, vb), vc) - add(va, add(vb, vc))) < 1e-6)
            #expect(abs(abc - add(add(va, vb), vc)) < 1e-6)
        }
    }

    @Test func subtractAndIntersectAreThePlans() throws {
        let (a, b) = (Self.a, Self.b)
        var minus = b; minus.operation = .subtract
        for q in Self.points {
            let (va, vb) = (try value(a, q), try value(b, q))
            #expect(abs(try composed([a, minus], q) - va * (1 - vb)) < 1e-6)
            // `A·(1−B) + A·B = A`, on a radial B, where `inv v` is `1 − v`.
            var radialMinus = Self.c; radialMinus.operation = .subtract
            var radialIntersect = Self.c; radialIntersect.operation = .intersect
            #expect(abs(try composed([a, radialMinus], q) + (try composed([a, radialIntersect], q)) - va) < 2e-6)
        }
    }

    /// Intersect is Subtract of the inverse, for both shapes and either invert, and for a linear that is not `c·v`.
    @Test func intersectIsSubtractOfTheInverse() throws {
        let a = Self.a
        for shape in [Self.b, Self.c] {
            for invert in [false, true] {
                var intersect = shape; intersect.operation = .intersect; intersect.invert = invert
                var subtract = shape; subtract.operation = .subtract; subtract.invert = !invert
                for q in Self.points { #expect(try composed([a, intersect], q) == composed([a, subtract], q)) }
            }
        }
        // Linear intersect: `c·(1 − profile(1 − t))`, up to 0.126 from `c·v` (L1b).
        var intersect = Self.b; intersect.operation = .intersect
        var differs: Float = 0
        for q in Self.points {
            differs = max(differs, abs(try composed([a, intersect], q) - (try value(a, q)) * (try value(Self.b, q))))
        }
        #expect(differs > 0.05, "\(differs)")
    }

    @Test func everyCompositeStaysInZeroToOne() throws {
        for q in Self.points {
            for operation in [MaskOperation.add, .subtract, .intersect] {
                for invert in [false, true] {
                    var second = Self.b; second.operation = operation; second.invert = invert
                    var third = Self.c; third.operation = operation; third.invert = !invert
                    let v = try composed([Self.a, second, third], q)
                    #expect(v >= 0 && v <= 1)
                }
            }
        }
    }

    /// The first add from 0 is the component.
    @Test func oneComponentIsItself() throws {
        for q in Self.points { #expect(try composed([Self.a], q) == value(Self.a, q)) }
    }

    /// A linear's Invert swaps Full and Zero, so it is `profile(1 − t)` and not `1 − v`, which differ by up to 0.12 (plan section 6).
    @Test func aLinearsInvertSwapsFullAndZero() throws {
        let plain = Field.linear(0.2, 0.1, 0.8, 0.5)
        let inverted = Field.linear(0.2, 0.1, 0.8, 0.5, invert: true)
        let swapped = Field.linear(0.8, 0.5, 0.2, 0.1)
        var mostFromComplement: Float = 0
        for q in Self.points {
            #expect(try value(inverted, q) == value(swapped, q))
            mostFromComplement = max(mostFromComplement, abs(try value(inverted, q) - (1 - (try value(plain, q)))))
        }
        #expect(mostFromComplement > 0.1, "\(mostFromComplement)")
        // The profile is asymmetric: its middle sums to 0.88, as Lightroom's does.
        let middle = SIMD2<Float>(0.5, 0.3)
        #expect(abs(try value(plain, middle) + (try value(inverted, middle)) - 0.88) < 0.02)
    }

    @Test func aRadialsInvertIsTheComplement() throws {
        for feather in [Float(0), 3, 25, 100] {
            let plain = Field.radial(0.5, 0.3, 0.3, 0.2, angle: 0.3, feather: feather)
            let inverted = Field.radial(0.5, 0.3, 0.3, 0.2, angle: 0.3, feather: feather, invert: true)
            for q in Self.points { #expect(abs(try value(inverted, q) + (try value(plain, q)) - 1) < 1e-6) }
        }
    }

    /// R8's row 12: the working format's step in stops, at the adjustment plan section 6 allows.
    @Test func aHalfFloatStepIsUnder0Point003StopsAt5EV() throws {
        for level in [Float(0.01), 0.1, 0.25, 0.5, 0.75, 0.999] {
            #expect(Float(Float16(level).ulp) * 5 < 0.003, "at \(level)")
        }
        // In what a bake wrote: across a long gradient, no neighbouring texels differ by more than the gradient's own slope and a step.
        let gpu = try GPU()
        let picture = Field.picture
        let mask = Field.mask(Field.linear(0, 0, 0, picture.extent.y))
        let coverage = try #require(try Field.cache(on: gpu).coverage(for: MaskSet(masks: [mask]), picture: picture))
        let size = coverage.slots.size
        let values = coverage.values(slot: 0)
        let program = try MaskProgram(mask.coverage)
        var worst: Float = 0
        for row in 0..<size.height {
            let q = size.point(column: 0, yTop: row)
            worst = max(worst, abs(values[row * size.width] - program.coverage(at: SIMD2(q.x, q.y))) * 5)
        }
        #expect(worst < 0.003, "\(worst) stops")
    }
}

/// A preview samples the field its develop sampled, at its own pixels (plan section 6: 0.0032 for gradients).
@Suite struct MaskRenderSizeTests {
    private static let soft: [(String, Mask)] = [
        ("radial feather 50", Field.mask(Field.radial(0.5, 0.33, 0.3, 0.3, feather: 50))),
        ("radial feather 25, ellipse", Field.mask(Field.radial(0.4, 0.3, 0.45, 0.2, angle: 0.5, feather: 25))),
        ("radial feather 10", Field.mask(Field.radial(0.5, 0.33, 0.3, 0.3, feather: 10))),
        ("linear long", Field.mask(Field.linear(0.5, 0.05, 0.5, 0.62))),
        ("linear 0.05", Field.mask(Field.linear(0.2, 0.3, 0.25, 0.3))),
        ("two composed", Field.mask(Field.linear(0, 0, 1, 0.66), Field.radial(0.5, 0.33, 0.3, 0.2, feather: 40, operation: .subtract))),
    ]
    /// The sizes the app renders a 7008 × 4672 frame at, with their rounding (plan section 8, R8 section 4).
    private static let sizes: [(Int, Int)] = [(4912, 3275), (3800, 2533), (2190, 1460), (960, 640)]

    private func worstAgainstDevelop(_ gpu: GPU, develop: MTLTexture, preview: MTLTexture) throws -> Float {
        let resized = Field.read(try Field.areaResized(gpu, develop, width: preview.width, height: preview.height))
        let values = Field.read(preview)
        return resized.withUnsafeBufferPointer { a in
            values.withUnsafeBufferPointer { b in
                var worst: Float = 0
                for i in 0..<a.count { worst = max(worst, abs(a[i] - b[i])) }
                return worst
            }
        }
    }

    /// One field for every render of the picture, as `MaskFieldCache` asks for it: the full size named by every render.
    @Test func coverageIsIndependentOfRenderSizeOnOneField() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        let picture = Field.picture
        for (name, mask) in Self.soft {
            let coverage = try #require(try cache.coverage(for: MaskSet(masks: [mask]), picture: picture))
            let develop = try Field.sampled(gpu, coverage.texture, width: picture.width, height: picture.height)
            for (width, height) in Self.sizes {
                let preview = try Field.sampled(gpu, coverage.texture, width: width, height: height)
                let worst = try worstAgainstDevelop(gpu, develop: develop, preview: preview)
                #expect(worst <= 0.0032, "\(name) at \(width): \(worst)")
            }
        }
    }

    /// A field baked for each render's own size, as a render that knows only that would ask, on its own rounding of the aspect.
    @Test func coverageIsIndependentOfRenderSizeOnFieldsOfTheirOwn() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        for (name, mask) in Self.soft {
            let full = try #require(try cache.coverage(for: MaskSet(masks: [mask]), picture: Field.picture))
            let develop = try Field.sampled(gpu, full.texture, width: Field.picture.width, height: Field.picture.height)
            for (width, height) in Self.sizes {
                let own = try #require(try cache.coverage(for: MaskSet(masks: [mask]), picture: MaskSpace(width: width, height: height)))
                let preview = try Field.sampled(gpu, own.texture, width: width, height: height)
                let worst = try worstAgainstDevelop(gpu, develop: develop, preview: preview)
                #expect(worst <= 0.0032, "\(name) at \(width): \(worst)")
            }
        }
    }

    /// Against the mask's exact value at a develop's pixels: R8's 0.0061 for a field at 2048 on soft masks.
    @Test func theFieldIsWithinR8sLimitOfTheExactDevelop() throws {
        let gpu = try GPU()
        let picture = Field.picture
        let cache = Field.cache(on: gpu)
        for (name, mask) in Self.soft {
            let coverage = try #require(try cache.coverage(for: MaskSet(masks: [mask]), picture: picture))
            let develop = Field.read(try Field.sampled(gpu, coverage.texture, width: picture.width, height: picture.height))
            let program = try MaskProgram(mask.coverage)
            var worst: Float = 0
            for yTop in stride(from: 0, to: picture.height, by: 19) {
                for column in stride(from: 0, to: picture.width, by: 23) {
                    let q = picture.point(column: column, yTop: yTop)
                    worst = max(worst, abs(develop[picture.textureRow(yTop: yTop) * picture.width + column] - program.coverage(at: SIMD2(q.x, q.y))))
                }
            }
            #expect(worst <= 0.0061, "\(name): \(worst)")
        }
    }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func note() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Rule 2: nothing but a change of shape writes a field, proved by counting.
@Suite struct MaskFieldCacheTests {
    private static let picture = Field.picture
    private static let shapes = [Field.linear(0.5, 0.1, 0.5, 0.6), Field.radial(0.5, 0.33, 0.3, 0.3), Field.radial(0.2, 0.2, 0.1, 0.3, feather: 25),
                                 Field.linear(0.1, 0.1, 0.9, 0.5), Field.radial(0.8, 0.4, 0.2, 0.1, feather: 80), Field.linear(0.9, 0.6, 0.1, 0.1, invert: true)]

    private func set(_ count: Int) throws -> MaskSet {
        try MaskSet(masks: (0..<count).map { Field.mask(Self.shapes[$0 % Self.shapes.count], exposure: Float($0) * 0.25) })
    }

    /// Reads what a fresh cache bakes for `masks`, as bits.
    private func fresh(_ gpu: GPU, _ masks: MaskSet) throws -> [[UInt16]] {
        let coverage = try #require(try Field.cache(on: gpu).coverage(for: masks, picture: Self.picture))
        return (0..<coverage.sliceCount).map { Field.bits(coverage, slice: $0) }
    }

    @Test func aFrameWithNoMasksPaysNothing() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        #expect(try cache.coverage(for: .empty, picture: Self.picture) == nil)
        #expect(!cache.hasPipelines, "no library is compiled for a frame with no masks")
        #expect(cache.residentBytes == 0)
        #expect(!gpu.maskFields.hasPipelines, "a new GPU has compiled nothing for masks")
        // Today's library holds no mask kernel: this one is its own.
        let library = try gpu.shaderLibrary()
        #expect(library.makeFunction(name: "mask_bake") == nil)
    }

    @Test func theLayoutIsFourMasksASlice() throws {
        let gpu = try GPU()
        for (count, slices) in [(1, 1), (4, 1), (5, 2), (8, 2), (9, 3), (16, 4)] {
            let coverage = try #require(try Field.cache(on: gpu).coverage(for: set(count), picture: Self.picture))
            #expect(coverage.sliceCount == slices)
            #expect(coverage.texture.textureType == .type2DArray && coverage.texture.pixelFormat == .rgba16Float)
            #expect(coverage.texture.arrayLength == slices && coverage.texture.width == 2048 && coverage.texture.height == 1365)
            for slot in coverage.slots.slots {
                #expect(slot.slice == slot.index / 4 && slot.channel == slot.index % 4)
            }
        }
        // Each mask is in its own channel, against the reference at one texel.
        let masks = try set(6)
        let coverage = try #require(try Field.cache(on: gpu).coverage(for: masks, picture: Self.picture))
        let size = coverage.slots.size
        for (index, mask) in masks.masks.enumerated() {
            let values = coverage.values(slot: index)
            for (column, yTop) in [(300, 200), (1000, 700), (1800, 1200)] {
                let q = size.point(column: column, yTop: yTop)
                #expect(abs(values[yTop * size.width + column] - (try MaskCoverage.reference(mask, at: q))) < Field.halfFloatStep, "slot \(index)")
            }
        }
    }

    /// Bake reuses the cache under a slider change: no bake, no write, the same array.
    @Test func aSliderOrAmountOrToggleRebuildsNothing() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        let masks = try set(6)
        let first = try #require(try cache.coverage(for: masks, picture: Self.picture))
        let before = cache.statistics
        #expect(before.bakes == 6)
        var changed = masks.masks[2]
        changed.adjustments = try changed.adjustments.setting(.exposure, to: -1.5)
        changed.amount = 0.4
        var off = masks.masks[4]
        off.isEnabled = false
        for edit in [changed, off, masks.masks[4], { var m = masks.masks[0]; m.amount = 0; return m }()] {
            let next = try #require(try cache.coverage(for: masks.replacing(edit), picture: Self.picture))
            #expect(next.texture === first.texture, "the same array")
        }
        let after = cache.statistics
        #expect(after.bakes == before.bakes && after.moves == before.moves && after.allocations == before.allocations)
        #expect(after.hits == before.hits + 4)
    }

    /// The render key: no slider moves it, and a shape does.
    @Test func theIdentityIsTheShapesAlone() throws {
        let picture = Self.picture
        let masks = try set(3)
        let identity = try MaskSlots(masks: masks, picture: picture).identity
        var slider = masks.masks[1]; slider.adjustments = try slider.adjustments.setting(.contrast, to: 40); slider.amount = 1.7
        #expect(try MaskSlots(masks: masks.replacing(slider), picture: picture).identity == identity)
        // It holds across runs: the same bytes on any machine.
        let golden = try MaskSet(masks: [Mask(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, components: [Field.linear(0.5, 0.1, 0.5, 0.6)])])
        #expect(try MaskSlots(masks: golden, picture: picture).identity == "a838dfad5656450b15d7c93f13832b777dc3c90f71c84c6d39530039a1ac2474")
        var moved = masks.masks[1]; moved.components = [Field.radial(0.5, 0.33, 0.3, 0.31)]
        #expect(try MaskSlots(masks: masks.replacing(moved), picture: picture).identity != identity)
        var off = masks.masks[1]; off.isEnabled = false
        #expect(try MaskSlots(masks: masks.replacing(off), picture: picture).identity != identity)
        #expect(try MaskSlots(masks: masks, picture: MaskSpace(width: 3000, height: 3000)).identity != identity)
        let negativeZero = try MaskSet(masks: [Field.mask(Field.linear(0, 0.1, 0.5, 0.6))])
        let positiveZero = try MaskSet(masks: [Field.mask(Field.linear(-0.0, 0.1, 0.5, 0.6))])
        #expect(try MaskSlots(masks: negativeZero, picture: picture).identity == MaskSlots(masks: positiveZero, picture: picture).identity)
    }

    /// Dragging one gradient bakes its channel and leaves the other three in its slice, and every other slice, bit for bit.
    @Test func draggingOneGradientRebakesOnlyItsChannel() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        let masks = try set(6)
        var held = try cache.coverage(for: masks, picture: Self.picture)
        let first = try #require(held).texture
        let before = (0..<2).map { Field.bits(held!, slice: $0) }
        let counts = cache.statistics

        // A render in flight holds the first array, so the drag does not touch it: a new array, the others moved rather than baked.
        var dragged = masks.masks[2]
        dragged.components = [Field.radial(0.25, 0.25, 0.12, 0.3, feather: 25)]
        var second = try cache.coverage(for: masks.replacing(dragged), picture: Self.picture)
        #expect(try #require(second).texture !== first)
        #expect(cache.statistics.bakes == counts.bakes + 1, "the dragged mask alone")
        #expect(cache.statistics.moves == counts.moves + 5, "the others, by value")
        for slice in 0..<2 { #expect(Field.bits(held!, slice: slice) == before[slice], "a held array does not change") }

        // No render holds either array now. A further drag writes one channel of the older, and neither allocates nor moves anything.
        held = nil
        second = nil
        let allocated = cache.statistics.allocations, moved = cache.statistics.moves
        dragged.components = [Field.radial(0.26, 0.25, 0.12, 0.3, feather: 25)]
        let third = try #require(try cache.coverage(for: masks.replacing(dragged), picture: Self.picture))
        #expect(cache.statistics.allocations == allocated, "it reuses an array")
        #expect(cache.statistics.moves == moved, "it moves nothing")
        #expect(cache.statistics.bakes == counts.bakes + 2)
        #expect(third.texture === first, "the older of the two, so the newer stays for a render that might hold it")

        // Channel 2 of slice 0 changed; 0, 1 and 3 are bit for bit what the fresh array baked, and so is the other slice.
        let bits = Field.bits(third, slice: 0), original = before[0]
        var changed = 0, others = 0
        for i in 0..<(bits.count / 4) {
            if bits[i * 4 + 2] != original[i * 4 + 2] { changed += 1 }
            if bits[i * 4] != original[i * 4] || bits[i * 4 + 1] != original[i * 4 + 1] || bits[i * 4 + 3] != original[i * 4 + 3] { others += 1 }
        }
        #expect(changed > 0 && others == 0, "\(changed) changed, \(others) elsewhere")
        #expect(Field.bits(third, slice: 1) == before[1], "the other slice is untouched")
        // What is in the array is what a fresh bake would write.
        let expected = try fresh(gpu, masks.replacing(dragged))
        for slice in 0..<third.sliceCount { #expect(Field.bits(third, slice: slice) == expected[slice]) }
    }

    /// Slots shift when a mask leaves the middle. Nothing bakes; each field moves by value and lands as a fresh bake would.
    @Test func deletingFromTheMiddleBakesNothing() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        let masks = try set(6)
        do { _ = try cache.coverage(for: masks, picture: Self.picture) }
        let counts = cache.statistics
        let fewer = try masks.removing(masks.masks[1].id)
        let coverage = try #require(try cache.coverage(for: fewer, picture: Self.picture))
        #expect(cache.statistics.bakes == counts.bakes, "no field is new")
        #expect(cache.statistics.moves == counts.moves + 5)
        let expected = try fresh(gpu, fewer)
        // Channels past the set are 0 in both, since this array is new too.
        for slice in 0..<coverage.sliceCount {
            let bits = Field.bits(coverage, slice: slice)
            #expect(bits == expected[slice], "slice \(slice)")
        }
        // The undo finds the old array whole.
        let bakes = cache.statistics
        let undone = try #require(try cache.coverage(for: masks, picture: Self.picture))
        #expect(cache.statistics.bakes == bakes.bakes && cache.statistics.moves == bakes.moves && cache.statistics.allocations == bakes.allocations)
        #expect(undone.sliceCount == 2)
    }

    /// At a limit that holds one array, a deletion moves the fields within it, in slot order, so each is read before it is written over.
    @Test func atATightLimitADeletionMovesWithinTheArray() throws {
        let gpu = try GPU()
        let slice = MaskFieldSize(picture: Self.picture).bytesPerSlice
        let cache = Field.cache(on: gpu, maximumBytes: slice)
        let masks = try set(4)
        do { _ = try cache.coverage(for: masks, picture: Self.picture) }
        let counts = cache.statistics
        let fewer = try masks.removing(masks.masks[1].id)
        let coverage = try #require(try cache.coverage(for: fewer, picture: Self.picture))
        #expect(cache.statistics.bakes == counts.bakes && cache.statistics.moves == counts.moves + 2 && cache.statistics.allocations == counts.allocations)
        let expected = try #require(try Field.cache(on: gpu).coverage(for: fewer, picture: Self.picture))
        for slot in 0..<3 { #expect(coverage.values(slot: slot) == expected.values(slot: slot), "slot \(slot)") }
    }

    /// Keyed by value: a copy with new ids, and two masks of one shape, bake once.
    @Test func theCacheKeysByValueNotID() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        let masks = try set(3)
        do { _ = try cache.coverage(for: masks, picture: Self.picture) }
        let counts = cache.statistics
        let copy = try masks.forAnotherPicture(freshIDs: true)
        _ = try cache.coverage(for: copy, picture: Self.picture)
        #expect(cache.statistics.bakes == counts.bakes && cache.statistics.allocations == counts.allocations)
        let twins = try MaskSet(masks: [Field.mask(Self.shapes[0]), Field.mask(Self.shapes[1]), Field.mask(Self.shapes[1])])
        let other = Field.cache(on: gpu)
        let coverage = try #require(try other.coverage(for: twins, picture: Self.picture))
        #expect(other.statistics.bakes == 2 && other.statistics.moves == 1)
        #expect(coverage.values(slot: 1) == coverage.values(slot: 2))
    }

    /// A mask that is off holds a slot, needs no bake, and moves nothing when it comes back.
    @Test func aMaskThatIsOffKeepsItsSlotAndIsNotBaked() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        var masks = try set(5)
        var off = masks.masks[1]; off.isEnabled = false
        masks = try masks.replacing(off)
        let slots = try MaskSlots(masks: masks, picture: Self.picture)
        #expect(slots.slots.count == 5 && slots.sliceCount == 2 && slots.activeCount == 4)
        #expect(slots.slots[1].field == nil && slots.slots[2].index == 2)
        do {
            let coverage = try #require(try cache.coverage(for: masks, picture: Self.picture))
            #expect(cache.statistics.bakes == 4, "it did not need baking for the render")
            #expect(coverage.values(slot: 1).allSatisfy { $0 == 0 }, "a channel never baked reads 0")
        }
        // On again: only its own channel is written, in place, and no other slot's layout moved.
        let bits = cache.statistics
        var on = off; on.isEnabled = true
        let back = try masks.replacing(on)
        let onSlots = try MaskSlots(masks: back, picture: Self.picture)
        for index in [0, 2, 3, 4] { #expect(onSlots.slots[index].field == slots.slots[index].field, "no other mask re-keys") }
        let coverage = try #require(try cache.coverage(for: back, picture: Self.picture))
        #expect(cache.statistics.bakes == bits.bakes + 1 && cache.statistics.moves == bits.moves && cache.statistics.allocations == bits.allocations)
        #expect(coverage.sliceCount == 2)
        // Off once more, and on: the field stayed in its channel, so neither writes.
        let bakes = cache.statistics.bakes
        _ = try cache.coverage(for: masks, picture: Self.picture)
        _ = try cache.coverage(for: back, picture: Self.picture)
        #expect(cache.statistics.bakes == bakes)
    }

    /// All off: nothing to bake, and a set a render can route to today's kernels.
    @Test func everyMaskOffBakesNothing() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        let masks = try MaskSet(masks: [Field.mask(Self.shapes[0], isEnabled: false)])
        let coverage = try #require(try cache.coverage(for: masks, picture: Self.picture))
        #expect(coverage.slots.activeCount == 0 && cache.statistics.bakes == 0)
        #expect(coverage.values(slot: 0).allSatisfy { $0 == 0 })
    }

    /// A Follow edges stroke that kept no measured shape (the brush itself bakes: `BrushCoverageTests`; a measured one: `FollowEdgesTests`);
    /// a smart selection not made yet; and a smart selection with no decode to be refined on (`MaskRefiner`) each refuse.
    @Test func aSmartMaskOrAFollowEdgesStrokeRefusesRatherThanBakeAsZero() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .apple, lensCorrection: true)
        let stroke = BrushStroke(followEdges: true, radius: 0.01, points: try PackedPoints.pack([MaskPoint(x: 0.5, y: 0.3)]))
        let brush = MaskComponent(shape: .brush(BrushPaint(frame: frame, strokes: [stroke])))
        let pending = MaskComponent(shape: .smart(SmartSelection(kind: .sky)))
        let seed = try MaskRaster(width: 16, height: 16, plane: [UInt8](repeating: 9, count: 256))
        let smart = MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: seed.ref, frame: frame)))
        #expect(throws: MaskCoverageError.unmeasuredStroke) {
            try cache.coverage(for: MaskSet(masks: [Mask(components: [brush])]), picture: Self.picture)
        }
        #expect(throws: MaskRefinerError.selectionPending(.sky)) {
            try cache.coverage(for: MaskSet(masks: [Field.mask(Self.shapes[0]), Mask(components: [Self.shapes[0], pending])]), picture: Self.picture)
        }
        #expect(throws: MaskCoverageError.unbakedShape("smart")) {
            try cache.coverage(for: MaskSet(masks: [Field.mask(Self.shapes[0]), Mask(components: [Self.shapes[0], smart])]), picture: Self.picture)
        }
        #expect(cache.statistics.bakes == 0 && !cache.hasPipelines, "it refuses before Metal")
        #expect(MaskCoverageError.unbakedShape("smart").description.contains("smart"))
        #expect(throws: MaskCoverageError.unbakedShape("smart")) { try MaskCoverage.reference(Mask(components: [smart]), at: MaskPoint(x: 0, y: 0)) }
        // Off, it is not read, so it does not stop the frame.
        let off = try MaskSet(masks: [Field.mask(Self.shapes[0]), Mask(isEnabled: false, components: [smart])])
        let coverage = try #require(try cache.coverage(for: off, picture: Self.picture))
        #expect(coverage.slots.activeCount == 1)
    }

    @Test func aReceiptsDigestRefuses() throws {
        let gpu = try GPU()
        let digest = try set(2).digestOnly
        #expect(throws: MaskError.digestOnly) { try Field.cache(on: gpu).coverage(for: digest, picture: Self.picture) }
    }

    /// The byte limit, `evict` and `removeAll`, with a render still holding what they let go of.
    @Test func theLimitEvictsOldestAndARenderKeepsWhatItHolds() throws {
        let gpu = try GPU()
        let slice = MaskFieldSize(picture: Self.picture).bytesPerSlice
        let cache = Field.cache(on: gpu, maximumBytes: 2 * slice)
        let a = try MaskSet(masks: [Field.mask(Self.shapes[0])])
        let b = try MaskSet(masks: [Field.mask(Self.shapes[1])])
        let c = try MaskSet(masks: [Field.mask(Self.shapes[2])])
        let heldA = try #require(try cache.coverage(for: a, picture: Self.picture))
        let heldB = try #require(try cache.coverage(for: b, picture: Self.picture))
        #expect(cache.residentBytes == 2 * slice)
        let aBefore = heldA.values(slot: 0)
        let heldC = try #require(try cache.coverage(for: c, picture: Self.picture))
        #expect(cache.residentBytes <= 2 * slice, "A went; it is still held below")
        #expect(heldA.values(slot: 0) == aBefore)
        // A again: the cache no longer has it, so it bakes once more into a new array.
        let bakes = cache.statistics.bakes
        _ = try cache.coverage(for: a, picture: Self.picture)
        #expect(cache.statistics.bakes == bakes + 1)

        cache.evict(downTo: slice)
        #expect(cache.residentBytes <= slice)
        cache.removeAll()
        #expect(cache.residentBytes == 0)
        #expect(heldB.values(slot: 0).contains { $0 > 0.9 } && heldC.values(slot: 0).contains { $0 > 0.5 }, "still readable")

        // Past the limit with nothing held, it writes over the oldest array rather than freeing one and allocating another.
        let tight = Field.cache(on: gpu, maximumBytes: slice)
        do { _ = try tight.coverage(for: a, picture: Self.picture) }
        do { _ = try tight.coverage(for: b, picture: Self.picture) }
        #expect(tight.statistics.allocations == 1 && tight.residentBytes == slice)

        // A limit below one array still answers.
        let none = Field.cache(on: gpu, maximumBytes: 0)
        let lone = try #require(try none.coverage(for: a, picture: Self.picture))
        #expect(none.residentBytes == 0)
        #expect(lone.values(slot: 0).contains { $0 > 0.9 })
    }

    /// Each lane may ask at once. Every answer is right, and a field asked for at once is baked once.
    @Test func lanesMayAskAtOnce() throws {
        let gpu = try GPU()
        let cache = Field.cache(on: gpu)
        let sets = try (1...4).map { try set($0) }
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 32) { i in
            do {
                let masks = sets[i % sets.count]
                guard let coverage = try cache.coverage(for: masks, picture: Self.picture) else { return failures.note() }
                let size = coverage.slots.size
                for (index, mask) in masks.masks.enumerated() {
                    let q = size.point(column: 1000, yTop: 600)
                    let values = coverage.values(slot: index)
                    let expected = try MaskCoverage.reference(mask, at: q)
                    if abs(values[600 * size.width + 1000] - expected) > Field.halfFloatStep { failures.note() }
                }
            } catch {
                failures.note()
            }
        }
        #expect(failures.count == 0)
        #expect(cache.statistics.bakes <= 10, "\(cache.statistics.bakes)")
    }

    /// A bake's cost, to compare with R8's gate of 2 ms for 16 components. Timing is an integration gate (`docs/ci-regression.md`), so
    /// this only keeps the bake from being far off; the figure itself is in the task's report.
    @Test func sixteenComponentsBakeInTime() throws {
        let gpu = try GPU()
        let size = MaskFieldSize(picture: Self.picture)
        let array = try Field.floatArray(gpu, size)
        var components: [MaskComponent] = []
        for i in 0..<16 {
            if i % 2 == 0 {
                components.append(Field.radial(Float(i) * 0.06, 0.3, 0.2, 0.3, feather: 40, operation: i == 0 ? .add : .subtract))
            } else {
                components.append(Field.linear(0, Float(i) * 0.03, 1, 0.6, operation: .add))
            }
        }
        let program = try MaskProgram(Mask(components: components).coverage)
        let times = try (0..<5).map { _ in try Field.cache(on: gpu).bake(program, size: size, into: array) }
        #expect(times.min()! < 0.05, "\(times)")
    }
}

/// The reference over a whole raster, for the overlay: every pixel the point reference at its centre, the program compiled once.
@Suite struct MaskReferenceRasterTests {
    @Test func aRasterIsThePointReferenceAtEachPixelsCentre() throws {
        let mask = Mask(components: [
            MaskComponent(shape: .radial(.init(center: MaskPoint(x: 0.4, y: 0.3), semiAxisA: 0.25, semiAxisB: 0.12, angle: 0.4, feather: 35))),
            MaskComponent(operation: .subtract, shape: .linear(.init(full: MaskPoint(x: 0.2, y: 0.5), zero: MaskPoint(x: 0.6, y: 0.1))), invert: true),
        ])
        for (width, height) in [(48, 32), (20, 30)] {
            let raster = try MaskCoverage.reference(mask, width: width, height: height)
            let long = Float(max(width, height))
            #expect(raster.count == width * height)
            for row in 0..<height {
                for column in 0..<width {
                    let point = MaskPoint(x: (Float(column) + 0.5) / long, y: (Float(row) + 0.5) / long)
                    #expect(raster[row * width + column] == (try MaskCoverage.reference(mask, at: point)), "\(column),\(row)")
                }
            }
        }
        #expect(try MaskCoverage.reference(mask, width: 0, height: 4).isEmpty)
        // What the bake refuses, the raster refuses too; a brush with no stroke covers nothing.
        let brush = Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: try MaskFrame(orientation: 1, width: 600, height: 400,
                                                                                                       decoder: .apple, lensCorrection: false),
                                                                               strokes: [])))])
        #expect(try MaskCoverage.reference(brush, width: 4, height: 4) == [Float](repeating: 0, count: 16))
        let smart = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky)))])
        #expect(throws: (any Error).self) { try MaskCoverage.reference(smart, width: 4, height: 4) }
    }
}

@Suite struct MaskCoverageGeometryTests {
    @Test func mappedGradientsAgreeWithTheReferenceAndKeepEqualGeometryBytes() throws {
        let gpu = try GPU()
        let a = try LensGeometry(table: RadialTable(knots: [1, 0.985, 0.96]), scale: 1)
        let b = try LensGeometry(table: RadialTable(knots: [1, 1]), scale: 1)
        for picture in [Field.picture, try MaskSpace(width: 4672, height: 7008)] {
            for target in [b, try LensGeometry(table: a.table, scale: 1.015)] {
                let lens = MaskLens(picture: target, legacy: a, extent: picture.extent)
                let mask = Field.mask(Field.linear(0.08, 0.12, 0.24, 0.35),
                                      Field.radial(0.2, 0.2, 0.1, 0.09, operation: .subtract, invert: true),
                                      Field.linear(0.5, 0.4, 0.15, 0.1, operation: .intersect))
                let size = MaskFieldSize(picture: picture), cache = Field.cache(on: gpu)
                let texture = try Field.floatArray(gpu, size)
                let program = try MaskProgram(mask.coverage, lens: lens)
                #expect(program.remaps.count == 1 && program.remapOf == [1, 1, 1])
                try cache.bake(program, size: size, into: texture)
                let values = Field.channel(texture)
                let points = stride(from: 0, to: size.height, by: 13).flatMap { y in
                    stride(from: 0, to: size.width, by: 17).map { x in size.point(column: x, yTop: y) }
                }
                let reference = try MaskCoverage.reference(mask, at: points, lens: lens)
                var worst: Float = 0, i = 0
                for y in stride(from: 0, to: size.height, by: 13) { for x in stride(from: 0, to: size.width, by: 17) {
                    worst = max(worst, abs(values[(size.height - 1 - y) * size.width + x] - reference[i])); i += 1
                } }
                #expect(worst < 2e-5)
                let set = try MaskSet(masks: [mask])
                let plain = try MaskSlots(masks: set, picture: picture)
                let equal = try MaskSlots(masks: set, picture: picture, lens: MaskLens(picture: a, legacy: a, extent: picture.extent))
                #expect(plain == equal && plain.identity == equal.identity)
                let plainCache = Field.cache(on: gpu), cold = Field.cache(on: gpu)
                let first = try plainCache.coverage(for: plain), before = plainCache.statistics
                let second = try cold.coverage(for: equal)
                #expect(Field.bits(first, slice: 0) == Field.bits(second, slice: 0))
                var plainCounts = before, equalCounts = cold.statistics
                plainCounts.lastGPUSeconds = 0; equalCounts.lastGPUSeconds = 0
                #expect(plainCounts == equalCounts)
                let mappedPipeline = try #require(Mirror(reflecting: cold).children.first { $0.label == "remap" })
                let resamplePipeline = try #require(Mirror(reflecting: gpu.maskRefiner).children.first { $0.label == "resample" })
                #expect(Mirror(reflecting: mappedPipeline.value).children.isEmpty)
                #expect(Mirror(reflecting: resamplePipeline.value).children.isEmpty)
                let changed = try MaskSlots(masks: set, picture: picture, lens: lens)
                #expect(changed.identity != plain.identity)
                var off = mask; off.isEnabled = false
                let offSet = try MaskSet(masks: [off])
                #expect(try MaskSlots(masks: offSet, picture: picture, lens: lens).identity == MaskSlots(masks: offSet, picture: picture).identity)
            }
        }
    }

    @Test func everyKindFollowsItsGeometry() throws {
        let gpu = try GPU(), picture = Field.picture, size = MaskFieldSize(picture: Field.picture)
        let a = try LensGeometry(table: RadialTable(knots: [1, 0.99, 0.975]), scale: 1)
        let b = try LensGeometry(table: RadialTable(knots: [1, 1]), scale: 1)
        let lens = MaskLens(picture: b, legacy: a, extent: picture.extent)
        let toMask = try #require(LensRemap(from: b, to: a, extent: picture.extent))
        let toPicture = try #require(LensRemap(from: a, to: b, extent: picture.extent))
        let center = MaskPoint(x: 0.21, y: 0.16)
        let maskFrame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: false, geometry: a)
        let seedWidth = 768, seedHeight = 512
        let seed = try MaskRaster(width: seedWidth, height: seedHeight, plane: (0..<(seedWidth * seedHeight)).map { i in
            let p = MaskPoint(x: (Float(i % seedWidth) + 0.5) / Float(seedWidth), y: (Float(i / seedWidth) + 0.5) / Float(seedWidth))
            let r = hypot(p.x - center.x, p.y - center.y) / 0.012
            return UInt8((255 * exp(-r * r / 2)).rounded())
        })
        let measuredRaster = try MaskRaster(width: 48, height: 48, plane: (0..<(48 * 48)).map { i in
            let d = hypot(Float(i % 48) - 23.5, Float(i / 48) - 23.5)
            return UInt8((255 * max(0, 1 - d / 20)).rounded())
        })
        let measured = try MeasuredStroke(raster: measuredRaster.ref, x: Int(center.x * 2048) - 24, y: Int(center.y * Float(size.height) / picture.extent.y) - 24,
                                          pictureWidth: picture.width, pictureHeight: picture.height)
        let stroke = BrushStroke(radius: 0.015, points: try .pack([center]))
        var followed = stroke; followed.followEdges = true; followed.measured = measured
        let shapes: [MaskShape] = [
            .linear(.init(full: .init(x: 0.2, y: 0.2), zero: .init(x: 0.4, y: 0.4), geometry: a)),
            .radial(.init(center: center, semiAxisA: 0.02, semiAxisB: 0.02, geometry: a)),
            .brush(.init(frame: maskFrame, strokes: [stroke])),
            .brush(.init(frame: maskFrame, strokes: [followed])),
            .smart(.init(kind: .sky, raster: seed.ref, frame: maskFrame)),
            .smart(.init(kind: .subject, raster: seed.ref, frame: maskFrame, edge: .matte)),
        ]
        let base = try MaskRender.frame(gpu, [SIMD3<Float>](repeating: .init(repeating: 0.2), count: 1200 * 800), width: 1200, picture: picture)
        let correction = try ResolvedLensCorrection(red: b.table, green: b.table, blue: b.table, gain: .one, status: .init(), scale: b.scale).remembering(legacy: a)
        let changedFrame = LinearFrame(image: base.image, decoderVersion: base.decoderVersion, scale: base.scale, picture: picture, lens: correction)
        let seeds = Refine.Seeds([seed, measuredRaster])
        gpu.maskRefiner.seeds = seeds
        let baseSession = gpu.maskRefiner.session(for: base, picture: picture)
        let mappedSession = gpu.maskRefiner.session(for: changedFrame, picture: picture)
        func sample(_ values: [Float], at p: MaskPoint) -> Float {
            let u = p.x / size.texelToPoint.x - 0.5, v = p.y / size.texelToPoint.y - 0.5
            let x = Int(floor(u)), y = Int(floor(v)), s = u - Float(x), t = v - Float(y)
            func read(_ i: Int, _ j: Int) -> Float { values[min(max(j, 0), size.height - 1) * size.width + min(max(i, 0), size.width - 1)] }
            return (read(x, y) * (1 - s) + read(x + 1, y) * s) * (1 - t) + (read(x, y + 1) * (1 - s) + read(x + 1, y + 1) * s) * t
        }
        func centroid(_ values: [Float]) -> MaskPoint {
            var mass = 0.0, sx = 0.0, sy = 0.0
            for y in 0..<size.height { for x in 0..<size.width {
                let v = Double(values[y * size.width + x])
                mass += v; sx += v * Double(x); sy += v * Double(y)
            } }
            return MaskPoint(x: (Float(sx / mass) + 0.5) * size.texelToPoint.x, y: (Float(sy / mass) + 0.5) * size.texelToPoint.y)
        }
        for (kind, shape) in shapes.enumerated() {
            let mask = Mask(components: [.init(shape: shape)]), set = try MaskSet(masks: [mask]), cache = Field.cache(on: gpu)
            let original = try #require(try cache.coverage(for: set, picture: picture, refinement: baseSession)).values(slot: 0)
            let mapped = try #require(try cache.coverage(for: set, picture: picture, lens: lens, refinement: mappedSession)).values(slot: 0)
            var worst: Float = 0
            for y in stride(from: 20, to: size.height - 20, by: 11) { for x in stride(from: 20, to: size.width - 20, by: 11) {
                let p = size.point(column: x, yTop: y)
                worst = max(worst, abs(mapped[y * size.width + x] - sample(original, at: toMask.point(p))))
            } }
            #expect(worst < 0.015, "kind \(kind): \(worst)")
            if kind > 0 {
                let tracked = toPicture.point(centroid(original)), actual = centroid(mapped)
                #expect(hypot(tracked.x - actual.x, tracked.y - actual.y) * 2048 < 1, "kind \(kind)")
            }
        }
    }
}


extension MaskCoverageGeometryTests {
    @Test func aSmartSelectionAndGradientAgreeBetweenTierTwoAndTheSliceUnderALens() throws {
        let gpu = try GPU(), picture = Field.picture
        let a = try LensGeometry(table: RadialTable(knots: [1, 0.985, 0.96]), scale: 1)
        let b = ResolvedLensCorrection.identity.geometry
        let maskFrame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: false, geometry: a)
        let seedWidth = 192, seedHeight = 128
        let seed = try MaskRaster(width: seedWidth, height: seedHeight, plane: (0..<(seedWidth * seedHeight)).map { i in
            let x = (Float(i % seedWidth) + 0.5) / Float(seedWidth), y = (Float(i / seedWidth) + 0.5) / Float(seedWidth)
            return UInt8((255 * min(max((0.1 - hypot(x - 0.2, y - 0.15)) / 0.03, 0), 1)).rounded())
        })
        let seeds = Refine.Seeds([seed])
        let base = try MaskRender.frame(gpu, [SIMD3<Float>](repeating: .init(repeating: 0.2), count: 1200 * 800), width: 1200, picture: picture)
        let correction = try ResolvedLensCorrection(red: b.table, green: b.table, blue: b.table, gain: .one, status: .init(), scale: b.scale).remembering(legacy: a)
        let changed = LinearFrame(image: base.image, decoderVersion: base.decoderVersion, scale: base.scale, picture: picture, lens: correction)
        let region = try #require(MaskRegion(frameWidth: 1200, frameHeight: 800, left: 0, top: 0, right: 1, bottom: 1))
        for edge in [SmartEdge.guided, .crisp, .matte] {
            let components = [
                MaskComponent(shape: .smart(.init(kind: .subject, raster: seed.ref, frame: maskFrame, edge: edge))),
                MaskComponent(operation: .subtract, shape: .radial(.init(center: .init(x: 0.16, y: 0.12), semiAxisA: 0.05,
                                                                       semiAxisB: 0.03, angle: 0.5, geometry: a))),
            ]
            let perPixel = Mask(components: components, adjustments: try ManualAdjustments(exposureEV: 1))
            let slice = Mask(components: components, adjustments: try ManualAdjustments(contrast: 20))
            try #require(MaskRefiner.perPixelPlan([perPixel]).first?.composedLow != nil && MaskRefiner.perPixelPlan([slice]).isEmpty)
            let plainTwo = try gpu.regionCoverage(of: perPixel, on: base, region: region, seeds: seeds)
            let plainOne = try gpu.regionCoverage(of: slice, on: base, region: region, seeds: seeds)
            let two = try gpu.regionCoverage(of: perPixel, on: changed, region: region, seeds: seeds)
            let one = try gpu.regionCoverage(of: slice, on: changed, region: region, seeds: seeds)
            let baseline = zip(plainOne, plainTwo).map { abs(Int($0) - Int($1)) }.max()!
            let difference = zip(one, two).map { abs(Int($0) - Int($1)) }.max()!
            let moved = zip(one, plainOne).map { abs(Int($0) - Int($1)) }.max()!
            #expect(difference <= baseline + 3, "\(edge): lens difference \(difference), no-lens \(baseline)")
            #expect(moved > 20, "\(edge): the slice must actually move")
        }
    }
}
