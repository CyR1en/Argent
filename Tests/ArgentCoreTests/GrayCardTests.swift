import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct GrayCardTests {
    /// A width by height RGBA16Float texture whose pixel (x, y) is `value(x, y)` in every channel.
    private func texture(_ gpu: GPU, width: Int, height: Int, _ value: (Int, Int) -> Float) throws -> MTLTexture {
        let texture = try gpu.makeTexture(width: width, height: height)
        var halves = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(value(x, y))
                halves[(y * width + x) * 4] = v
                halves[(y * width + x) * 4 + 1] = v
                halves[(y * width + x) * 4 + 2] = v
            }
        }
        halves.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    @Test func anEvenCardAtMidGrayMeansTheAnchorIsRight() throws {
        let gpu = try GPU()
        let reading = GrayCard.read(try texture(gpu, width: 100, height: 60) { _, _ in 0.18 })
        #expect(abs(reading.luminance - 0.18) < 1e-3)
        #expect(abs(reading.spread - 1) < 1e-3)
        #expect(abs(reading.anchorErrorStops) < 0.01)
        #expect(abs(reading.impliedDecodedMidTone - 0.080) < 1e-3)
    }

    @Test func aCardHalfAStopDarkMovesTheAnchorDown() throws {
        let gpu = try GPU()
        let dark = Float(0.18 * exp2(-0.5))
        // Only the central fifth is read, so a bright surround does not count.
        let reading = GrayCard.read(try texture(gpu, width: 100, height: 100) { x, y in
            (40..<60).contains(x) && (40..<60).contains(y) ? dark : 0.9
        })
        #expect(abs(reading.anchorErrorStops + 0.5) < 0.01)
        #expect(abs(reading.impliedDecodedMidTone - 0.080 * exp2(-0.5)) < 1e-3)
    }

    @Test func anUnevenCardIsFlagged() throws {
        let gpu = try GPU()
        let reading = GrayCard.read(try texture(gpu, width: 100, height: 100) { x, _ in 0.1 + 0.01 * Float(x) })
        #expect(reading.spread > GrayCard.maximumSpread)
    }
}
