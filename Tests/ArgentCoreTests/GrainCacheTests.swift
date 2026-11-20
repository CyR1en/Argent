import Metal
import Testing
@testable import ArgentCore

@Suite struct GrainCacheTests {
    private func field(_ gpu: GPU) throws -> GrainField {
        let field = GrainField(device: gpu.device, queue: gpu.queue)
        try field.prepare(library: gpu.shaderLibrary())
        return field
    }

    private func samePixels(_ left: MTLTexture, _ right: MTLTexture) -> Bool {
        ExposureAnalyzer.pixels(of: left) == ExposureAnalyzer.pixels(of: right)
    }

    /// The full-frame S crop and APS-C S output share a bucket; neither can choose its grain.
    @Test(arguments: [(3480, 3504), (3504, 3480)])
    func theFirstRequestDoesNotChangeABucketsGrain(first: Int, second: Int) throws {
        let gpu = try GPU()
        let cached = try field(gpu), fresh = try field(gpu)
        let initial = try cached.tiles(longSide: first)
        let reused = try cached.tiles(longSide: second)
        let expected = try fresh.tiles(longSide: second)

        #expect(initial.0 === reused.0 && initial.1 === reused.1)
        #expect(samePixels(reused.0, expected.0))
        #expect(samePixels(reused.1, expected.1))
    }

    @Test func anEvictedBucketRegeneratesTheSameGrain() throws {
        let gpu = try GPU()
        let field = try field(gpu)
        let initial = try field.tiles(longSide: 3504)
        for size in [2048, 4096, 7008, 9504] {
            _ = try field.tiles(longSide: size)
        }
        let regenerated = try field.tiles(longSide: 3480)

        #expect(initial.0 !== regenerated.0 && initial.1 !== regenerated.1)
        #expect(samePixels(initial.0, regenerated.0))
        #expect(samePixels(initial.1, regenerated.1))
    }
}
