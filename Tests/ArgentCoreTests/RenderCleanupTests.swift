import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct RenderCleanupGPUTests {
    /// What Core Image keeps for the sizes it has rendered goes only with its context, so the GPU's
    /// shared one can be replaced, and Apple's decoder can give each decode its own.
    @Test func theSharedContextCanBeReplacedAndADecodeCanHaveItsOwn() throws {
        let gpu = try GPU()
        let shared = gpu.ciContext
        gpu.renewContext()
        #expect(gpu.ciContext !== shared)
        #expect(!AppleRawDecoder(gpu: gpu).contextPerDecode)
        #expect(AppleRawDecoder(gpu: gpu, contextPerDecode: true).contextPerDecode)
    }

    private func texture(_ gpu: GPU, pixels: [SIMD3<Float>]) throws -> MTLTexture {
        let texture = try gpu.makeTexture(width: pixels.count, height: 1)
        var halves = [Float16](repeating: 1, count: pixels.count * 4)
        for (index, pixel) in pixels.enumerated() {
            for channel in 0..<3 { halves[index * 4 + channel] = Float16(pixel[channel]) }
        }
        halves.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, pixels.count, 1), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: pixels.count * 8)
        }
        return texture
    }

    private func printPixels(_ gpu: GPU, pass: PrintPass, pixels: [SIMD3<Float>],
                             manual: ManualRenderSettings, sharpened: Bool = false) throws -> [SIMD3<Float>] {
        let input = try texture(gpu, pixels: pixels)
        let output = try gpu.makeTexture(width: pixels.count, height: 1)
        let lut = try LUT3D.identity(size: 2).makeTexture(device: gpu.device)
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        try pass.encode(input: input, output: output, lut: lut, params: PrintParams(offset: .zero, lutSize: 2),
                        sharpening: sharpened ? [1, 1] : nil, manual: manual, into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        let halves = ExposureAnalyzer.pixels(of: output)
        return stride(from: 0, to: halves.count, by: 4).map {
            SIMD3(Float(halves[$0]), Float(halves[$0 + 1]), Float(halves[$0 + 2]))
        }
    }

    private func half(_ pixel: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(Float(Float16(pixel.x)), Float(Float16(pixel.y)), Float(Float16(pixel.z)))
    }

    @Test(arguments: [false, true])
    func legalSteepComposedCurvesStayFiniteAtTheOutputBoundary(sharpened: Bool) throws {
        let gpu = try GPU(), pass = try PrintPass(gpu: gpu)
        let steep = try ChannelCurve(points: [CurvePoint(input: 0, output: 0),
                                             CurvePoint(input: 254, output: 0),
                                             CurvePoint(input: 255, output: 255)])
        let curves = try ToneCurves(tone: steep, red: steep, green: steep, blue: steep)
        // Compiler 2026-10-09-1's print-side Whites carries white past the curve's end.
        let regions = ManualRenderSettings.regionsVersion
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(whites: 100, curves: curves),
                                             referenceStops: 0, version: regions)
        let white = SIMD3<Float>(repeating: 1)
        let mapped = try manual.applyingPrint(to: white)
        #expect(mapped.min() > 65504) // reproduce the overflow before the texture boundary
        let expected = half(mapped.clamped(lowerBound: SIMD3(repeating: -65504),
                                           upperBound: SIMD3(repeating: 65504)))
        let legacyCurves = try ToneCurves(tone: steep, red: steep, green: steep, blue: steep,
                                         version: "2026-10-09-curves-1")
        let legacy = try ManualRenderSettings(adjustments: ManualAdjustments(whites: 100, curves: legacyCurves),
                                             referenceStops: 0, version: regions)
        let legacyPixels = try printPixels(gpu, pass: pass, pixels: [white], manual: legacy, sharpened: sharpened)
        #expect((0..<3).allSatisfy { legacyPixels[0][$0].isInfinite })
        let actual = try printPixels(gpu, pass: pass, pixels: [white], manual: manual, sharpened: sharpened)
        #expect(actual == [expected])
        #expect((0..<3).allSatisfy { actual[0][$0].isFinite })
        #expect(MemoryLayout<ToneCurveParameters>.stride == 48)
    }

    @Test func retainedAndCurrentCurveTablesUseTheirOwnSampleCounts() throws {
        let gpu = try GPU(), pass = try PrintPass(gpu: gpu)
        let sharp = try ChannelCurve(points: [CurvePoint(input: 0, output: 0),
                                             CurvePoint(input: 31, output: 0),
                                             CurvePoint(input: 32, output: 255),
                                             CurvePoint(input: 33, output: 0),
                                             CurvePoint(input: 255, output: 255)])
        // Input 32 is halfway between legacy grid samples but exact on the current grid.
        // This narrow peak retains a visible difference after the input's half conversion.
        let pixels = [Float(0), 31.75 / 255, 32 / 255, 32.25 / 255, 33.25 / 255, 1]
            .map { SIMD3<Float>(repeating: CompiledToneCurves.decode($0)) }
        var rendered: [[SIMD3<Float>]] = []
        // Run v1, then v2, then v1 through one pass so cache replacement is exercised too.
        for version in ["2026-10-09-curves-1", "2026-10-09-curves-2", "2026-10-09-curves-1"] {
            let curves = try ToneCurves(red: sharp, version: version)
            let manual = try ManualRenderSettings(adjustments: ManualAdjustments(curves: curves), referenceStops: 0)
            let actual = try printPixels(gpu, pass: pass, pixels: pixels, manual: manual)
            let expected = try pixels.map { try manual.applyingPrint(to: half($0)) }
            for (result, reference) in zip(actual, expected) {
                let difference = result - reference
                #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) < 0.001)
            }
            rendered.append(actual)
        }
        #expect(rendered[0] == rendered[2])
        #expect(zip(rendered[0], rendered[1]).contains { abs($0.x - $1.x) > 0.01 })
    }
}
