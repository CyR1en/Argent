import Foundation
import Metal
import Testing
@testable import ArgentCore

/// The render graph on the GPU against a CPU walk through the same two LUTs.
@Suite struct FilmRendererGPUTests {
    private static let side = 8

    /// Values a half-float texture holds exactly, spread across the log range and including
    /// zero and over-white, with the channels deliberately unequal.
    private static func testPixels() -> [SIMD3<Float>] {
        let ramp: [Float] = [-0.125, 0, 0.0005, 0.003, 0.01, 0.05, 0.1, 0.18, 0.3, 0.5, 0.75, 1, 1.5, 2, 3, 6]
        return (0..<(side * side)).map { (i: Int) -> SIMD3<Float> in
            let r = ramp[i % ramp.count]
            let g = ramp[(i * 7 + 3) % ramp.count]
            let b = ramp[(i * 11 + 5) % ramp.count]
            return SIMD3<Float>(r, g, b)
        }
    }

    /// What a half-float texture holds after it stores `value`.
    private static func halfRounded(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(Float(Float16(value.x)), Float(Float16(value.y)), Float(Float16(value.z)))
    }

    private static func mean(_ pixels: [SIMD3<Float>]) -> Float {
        var sum: Float = 0
        for pixel in pixels { sum += pixel.x + pixel.y + pixel.z }
        return sum / Float(pixels.count * 3)
    }

    private func makeFrame(_ gpu: GPU, pixels: [SIMD3<Float>]) throws -> LinearFrame {
        let side = Self.side
        let texture = try gpu.makeTexture(width: side, height: side)
        var halves = [Float16](repeating: 1, count: side * side * 4)
        for (i, pixel) in pixels.enumerated() {
            halves[i * 4] = Float16(pixel.x)
            halves[i * 4 + 1] = Float16(pixel.y)
            halves[i * 4 + 2] = Float16(pixel.z)
        }
        halves.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: side * 8)
        }
        return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "test", scale: 1)
    }

    private func readBack(_ texture: MTLTexture) -> [SIMD3<Float>] {
        let side = Self.side
        var halves = [Float16](repeating: 0, count: side * side * 4)
        halves.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: side * 8,
                             from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(side * side)
        for i in 0..<(side * side) {
            let base = i * 4
            pixels.append(SIMD3<Float>(Float(halves[base]), Float(halves[base + 1]), Float(halves[base + 2])))
        }
        return pixels
    }

    /// The same chain on the CPU: exposure shift, log encoding, Negative LUT, lab balance, Print LUT.
    private func reference(_ rgb: SIMD3<Float>, stock: Stock, settings: DevelopSettings) -> SIMD3<Float> {
        let encoding = stock.negative.encoding
        let stops = settings.exposureStops(boxSpeed: stock.boxSpeed)
        func encode(_ v: Float) -> Float {
            let s = log2(max(v, 1e-6) / encoding.midGray) + stops
            return min(max((s + encoding.stopsBelowMidGray) / encoding.range, 0), 1)
        }
        let mapped = GamutCompression.compress(rgb)
        let encoded = SIMD3<Float>(encode(mapped.x), encode(mapped.y), encode(mapped.z))
        let densities = stock.negative.sample(encoded: encoded)
        let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        let shifted = (densities + offset).clamped(lowerBound: .zero, upperBound: SIMD3<Float>(repeating: 1))
        return stock.print.sample(encoded: shifted)
    }

    private func render(_ settings: DevelopSettings, stock: Stock = ToyStock.make(), pixels: [SIMD3<Float>]? = nil) throws -> (gpu: [SIMD3<Float>], cpu: [SIMD3<Float>]) {
        let gpu = try GPU()
        let pixels = pixels ?? Self.testPixels()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let rendered = try renderer.render(try makeFrame(gpu, pixels: pixels), settings: settings)
        #expect(rendered.gpuSeconds >= 0)
        let expected = pixels.map { reference(Self.halfRounded($0), stock: stock, settings: settings) }
        return (readBack(rendered.image.texture), expected)
    }

    private func expectClose(_ actual: [SIMD3<Float>], _ expected: [SIMD3<Float>], tolerance: Float = 3e-3) {
        for (i, (a, e)) in zip(actual, expected).enumerated() {
            let worst = max(abs(a.x - e.x), abs(a.y - e.y), abs(a.z - e.z))
            #expect(worst < tolerance, "pixel \(i): gpu \(a), cpu \(e)")
        }
    }

    @Test func defaultSettingsMatchTheCPUReference() throws {
        let (actual, expected) = try render(DevelopSettings())
        expectClose(actual, expected)
    }

    @Test func negativeChannelSceneColorsMatchTheCPUReference() throws {
        let pixels = Array(repeating: SIMD3<Float>(0.5, -0.125, 0.125), count: Self.side * Self.side)
        let (actual, expected) = try render(DevelopSettings(), pixels: pixels)
        expectClose(actual, expected)
    }

    @Test func ratedAtLabBalanceAndPrintExposureMatchTheCPUReference() throws {
        let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.4, -0.3, 0.2), printExposure: 0.5)
        let (actual, expected) = try render(settings)
        expectClose(actual, expected)
    }

    /// The renderer must divide the offset by the stock's `exposurePerUnit`: the same
    /// settings on a stock with ones give a different print.
    @Test func theOffsetUsesTheStocksExposurePerUnit() throws {
        let settings = DevelopSettings(labBalance: SIMD3(0.5, 0, -0.5), printExposure: 0.5)
        let ones = Stock(id: "toy-ones", displayName: "Toy", status: "synthetic", boxSpeed: ToyStock.boxSpeed,
                         densityRange: ToyStock.densityRange, negative: ToyStock.make().negative, print: ToyStock.make().print)
        let (scaled, scaledReference) = try render(settings)
        let (unit, unitReference) = try render(settings, stock: ones)
        expectClose(scaled, scaledReference)
        expectClose(unit, unitReference)
        let largest = zip(scaled, unit).map { max(abs($0.x - $1.x), abs($0.y - $1.y), abs($0.z - $1.z)) }.max() ?? 0
        #expect(largest > 0.01)
    }

    @Test func positivePrintExposureLightensThePrint() throws {
        let (flat, _) = try render(DevelopSettings())
        let (lighter, _) = try render(DevelopSettings(printExposure: 1))
        #expect(Self.mean(lighter) > Self.mean(flat))
    }

    @Test func ratedAtBelowBoxSpeedLightensThePrint() throws {
        let (boxed, _) = try render(DevelopSettings())
        let (overexposed, _) = try render(DevelopSettings(ratedAt: 200))
        #expect(Self.mean(overexposed) > Self.mean(boxed))
    }

    @Test func rendersRepeatedFramesWithoutGrowingThePool() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        let pixels = Self.testPixels()
        for _ in 0..<5 {
            let rendered = try renderer.render(try makeFrame(gpu, pixels: pixels), settings: DevelopSettings())
            withExtendedLifetime(rendered) {}
        }
        // One density texture and one output texture, reused every frame.
        #expect(gpu.texturePool.allocationCount == 2)
    }

    @Test(arguments: [false, true])
    func toneBaseIsReusedAcrossEditsWithoutChangingPixels(masked: Bool) throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        let frame = try makeFrame(gpu, pixels: Self.testPixels())
        _ = try renderer.render(frame, settings: DevelopSettings())
        #expect(renderer.toneBaseBuildCount == 0)
        let mask = MaskRender.mask(MaskRender.linear(0, 0, 1, 1), try ManualAdjustments(shadows: 45))
        func settings(_ exposure: Float) throws -> DevelopSettings {
            DevelopSettings(labBalance: SIMD3(exposure / 10, 0, 0), manual: try MaskRender.manual(
                ManualAdjustments(exposureEV: exposure, highlights: -60, shadows: 30), masks: masked ? [mask] : []))
        }
        _ = try renderer.render(frame, settings: settings(0), reuseToneBase: true)
        #expect(renderer.toneBaseBuildCount == 1)
        let cached = try renderer.render(frame, settings: settings(0.7), reuseToneBase: true)
        #expect(renderer.toneBaseBuildCount == 1)
        renderer.clearToneBase()
        let uncached = try renderer.render(frame, settings: settings(0.7))
        #expect(renderer.toneBaseBuildCount == 2)
        #expect(MaskRender.bits(cached.image.texture) == MaskRender.bits(uncached.image.texture))
        _ = try renderer.render(try makeFrame(gpu, pixels: Self.testPixels()), settings: settings(0.7), reuseToneBase: true)
        #expect(renderer.toneBaseBuildCount == 3)
    }

    @Test(arguments: [false, true])
    func developsBuildEveryTimeAndReleaseTheirDecode(inPlace: Bool) throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        let settings = DevelopSettings(manual: try ManualRenderSettings(
            adjustments: ManualAdjustments(highlights: -60, shadows: 30), referenceStops: 0))
        weak var image: PooledTexture?
        do {
            let frame = try makeFrame(gpu, pixels: Self.testPixels())
            image = frame.image
            for _ in 0..<2 {
                if inPlace {
                    let input = try makeFrame(gpu, pixels: Self.testPixels())
                    image = input.image
                    _ = try renderer.render(input, settings: settings, inPlace: true, reuseToneBase: true)
                } else {
                    _ = try renderer.render(frame, settings: settings)
                }
            }
            #expect(renderer.toneBaseBuildCount == 2)
        }
        #expect(image == nil)
    }

    @Test func inPlaceInvalidatesAPreviouslyCachedDecode() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        let settings = DevelopSettings(manual: try ManualRenderSettings(
            adjustments: ManualAdjustments(highlights: -60), referenceStops: 0))
        weak var image: PooledTexture?
        do {
            let frame = try makeFrame(gpu, pixels: Self.testPixels())
            image = frame.image
            _ = try renderer.render(frame, settings: settings, reuseToneBase: true)
            _ = try renderer.render(frame, settings: settings, inPlace: true, reuseToneBase: true)
            #expect(renderer.toneBaseBuildCount == 2)
        }
        #expect(image == nil)
    }
}

/// A stock baked by `argent-bake`, found through `ARGENT_BAKED_STOCK`. Baking the synthetic
/// stock locally and pointing here (bake/README.md) keeps the Python and Swift halves honest
/// about the format, the LUT domains, and the mid-gray calibration.
@Suite struct BakedStockContractTests {
    private static let path = ProcessInfo.processInfo.environment["ARGENT_BAKED_STOCK"]

    @Test(.enabled(if: BakedStockContractTests.path != nil))
    func loadsAndPrintsMidGrayAsNeutralMidGray() throws {
        let stock = try Stock.load(from: URL(fileURLWithPath: try #require(Self.path)))
        #expect(stock.negative.size >= 9 && stock.print.size >= 9)

        let encoding = stock.negative.encoding
        let midGray = SIMD3<Float>(repeating: encoding.encode(encoding.midGray))
        let densities = stock.negative.sample(encoded: midGray)
        #expect(densities.min() > 0 && densities.max() <= 1)

        // The bake calibrates the daylight reference: scene mid-gray at box speed, no lab
        // balance, prints as a neutral 18 percent gray.
        let printed = stock.print.sample(encoded: densities)
        for channel in [printed.x, printed.y, printed.z] {
            #expect(abs(channel - 0.18) < 0.01, "mid-gray printed as \(printed)")
        }

        // Denser negatives print lighter, so paper black is at density zero and white at one.
        let black = stock.print.sample(encoded: SIMD3<Float>(repeating: 0))
        let white = stock.print.sample(encoded: SIMD3<Float>(repeating: 1))
        #expect(black.max() < 0.05)
        #expect(white.min() > 0.8)
    }

    @Test(.enabled(if: BakedStockContractTests.path != nil))
    func rendersMidGrayOnTheGPU() throws {
        let gpu = try GPU()
        let stock = try Stock.load(from: URL(fileURLWithPath: try #require(Self.path)))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)

        let texture = try gpu.makeTexture(width: 2, height: 2)
        var halves = [Float16](repeating: 1, count: 2 * 2 * 4)
        for i in 0..<4 {
            halves[i * 4] = Float16(0.18)
            halves[i * 4 + 1] = Float16(0.18)
            halves[i * 4 + 2] = Float16(0.18)
        }
        halves.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: 2 * 8)
        }
        let frame = LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "test", scale: 1)
        let rendered = try renderer.render(frame, settings: DevelopSettings())

        var out = [Float16](repeating: 0, count: 2 * 2 * 4)
        out.withUnsafeMutableBytes { buffer in
            rendered.image.texture.getBytes(buffer.baseAddress!, bytesPerRow: 2 * 8,
                                            from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        }
        for channel in 0..<3 {
            #expect(abs(Float(out[channel]) - 0.18) < 0.015, "channel \(channel) = \(out[channel])")
        }
    }
}
