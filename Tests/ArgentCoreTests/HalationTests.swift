import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct HalationTests {
    private let halation = Stock.Halation(strength: 0.015, greenShare: 0.25, radiusMicrometres: 180)

    /// A black frame of `width` by `height` with a `side`-pixel square of `value` in the middle.
    private func frame(_ gpu: GPU, width: Int, height: Int, side: Int, value: Float, background: Float = 0) throws -> LinearFrame {
        let texture = try gpu.texturePool.acquire(width: width, height: height)
        var pixels = [Float16](repeating: Float16(background), count: width * height * 4)
        for y in (height - side) / 2..<(height + side) / 2 {
            for x in (width - side) / 2..<(width + side) / 2 {
                let i = (y * width + x) * 4
                pixels[i] = Float16(value); pixels[i + 1] = Float16(value); pixels[i + 2] = Float16(value)
            }
        }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 1 }
        pixels.withUnsafeBytes { texture.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                         withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return LinearFrame(image: texture, decoderVersion: "test", scale: 1)
    }

    private func sums(_ texture: MTLTexture) -> SIMD3<Double> {
        let values = ExposureAnalyzer.pixels(of: texture)
        var sum = SIMD3<Double>(repeating: 0)
        for i in stride(from: 0, to: values.count, by: 4) {
            sum += SIMD3(Double(values[i]), Double(values[i + 1]), Double(values[i + 2]))
        }
        return sum
    }

    /// The halo returns the stock's strength of the light past the knee, red whole, green its
    /// share, blue none; light under the threshold makes none.
    @Test func returnsTheStrengthOfTheLightPastTheKnee() throws {
        let gpu = try GPU()
        let field = try HalationField(gpu: gpu)
        let width = 2048, height = 1366, side = 16
        let value: Float = 0.18 * exp2(6)
        let bright = try field.field(for: frame(gpu, width: width, height: height, side: side, value: value),
                                     exposureStops: 0, halation: halation)
        // Each field pixel stands for (2048 / 1024)^2 frame pixels.
        let perPixel = Double(width * height) / Double(bright.width * bright.height)
        let energy = sums(bright.texture) * perPixel
        let source = Double(side * side) * Double(value - 0.18 * exp2(HalationField.thresholdStops))
        print(String(format: "MEASURE halo energy over source energy: red %.4f, green %.4f, blue %.4f", energy.x / source, energy.y / source, energy.z / source))
        // The whole halo lands inside the frame.
        #expect(energy.x / source > 0.015 * 0.97 && energy.x / source < 0.015 * 1.02)
        #expect(abs(energy.y / energy.x - 0.25) < 0.01)
        #expect(energy.z == 0)

        let dim = try field.field(for: frame(gpu, width: width, height: height, side: side, value: 0.18 * exp2(1.5)),
                                  exposureStops: 0, halation: halation)
        #expect(sums(dim.texture).x == 0)
    }

    /// The Halation control multiplies the stock's strength (`DevelopSettings.halationAmount`): twice a stock's halation is, to
    /// the bit, the halation of a stock twice as strong, and none of it is the render without halation.
    @Test func theControlScalesTheStocksStrength() throws {
        let gpu = try GPU()
        let scene = try frame(gpu, width: 1024, height: 682, side: 48, value: 0.18 * exp2(6), background: 0.02)
        func printed(_ halation: Stock.Halation, _ settings: DevelopSettings) throws -> [Float16] {
            let toy = ToyStock.make()
            let stock = Stock(id: "halation-toy", displayName: "Halation", status: "synthetic", boxSpeed: toy.boxSpeed,
                              densityRange: toy.densityRange, exposurePerUnit: toy.exposurePerUnit, negative: toy.negative,
                              print: toy.print, halation: halation)
            return ExposureAnalyzer.pixels(of: try FilmRenderer(gpu: gpu, stock: stock).render(scene, settings: settings).image.texture)
        }
        var doubled = halation
        doubled.strength *= 2
        let none = try printed(halation, DevelopSettings())
        let own = try printed(halation, DevelopSettings(halation: true))
        let twice = try printed(halation, DevelopSettings(halation: true, halationAmount: 2))
        #expect(own != none && twice != own)
        #expect(try twice == printed(doubled, DevelopSettings(halation: true)))
        #expect(try none == printed(halation, DevelopSettings(halation: true, halationAmount: 0)))
    }

    /// The halo falls off from its source over the stock's radius and, as the base's reflection
    /// geometry has it, is all but gone by 4a.
    @Test func fallsOffWithDistance() throws {
        let gpu = try GPU()
        let field = try HalationField(gpu: gpu)
        let out = try field.field(for: frame(gpu, width: 1024, height: 682, side: 4, value: 0.18 * exp2(6)),
                                  exposureStops: 0, halation: halation)
        let values = ExposureAnalyzer.pixels(of: out.texture)
        let row = out.height / 2, centre = out.width / 2
        // a is 5.1 field pixels at 1024 px; the halo at 0.5a, 1a, 2a and 4a from the source.
        let at = [3, 5, 10, 20].map { Float(values[(row * out.width + centre + $0) * 4]) }
        print("MEASURE halo at 0.5a, 1a, 2a, 4a:", at)
        #expect(at[0] > at[1] && at[1] > at[2] && at[2] > at[3] && at[1] > 0)
        #expect(at[3] < 0.01 * at[1])
    }
}
