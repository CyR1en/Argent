import Foundation
import Metal
import Testing
@testable import ArgentCore

/// What the scene stages add to a warm render, with every field and the weights already made (a slider step on a decode the cache holds,
/// plan section 6): the main command buffer's GPU time (`RenderedFrame.gpuSeconds`, the Negative and Print passes) and the whole
/// `render` call, which adds the halation source, where the stages run again. Fields made by hand at the sizes the analysis makes them.
/// The cases are interleaved, round after round, so drift and warm-up favour none; run when asked:
///
///     ARGENT_MEASURE=1 swift test --filter PresenceSceneMeasureTests
///
/// A debug build serves: Metal compiles the kernels at runtime whatever the build, so the GPU time is the same, and only the render's
/// own CPU share is slower than a release build's.
@Suite(.serialized) struct PresenceSceneMeasureTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["ARGENT_MEASURE"] != nil }

    /// With and without halation, whose source runs the stages again over every pixel of the frame in a command buffer of its own.
    @Test(.enabled(if: enabled), arguments: [(2190, 1460, true), (2190, 1460, false), (7008, 4672, true), (7008, 4672, false)])
    func whatTheStagesAddToAWarmRender(width: Int, height: Int, halation: Bool) throws {
        let gpu = try GPU()
        let constants = try #require(PresenceConstants.named(Presence.currentVersion))
        let stock = try LightCompilerBaselineTests.bakedStocks.first.map { try Stock.load(from: $0) } ?? LightCompilerBaselineTests.toyStock()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let pixels = (0..<(width * height)).map { i -> SIMD3<Float> in
            let x = Float(i % width) / Float(width), y = Float(i / width) / Float(height)
            let v = 0.18 * exp2(-6 + 10 * x + 2 * sin(9 * y) + ((i % width / 3 + i / width / 3) % 2 == 0 ? 0.3 : -0.3))
            return SIMD3(v * (0.9 + 0.2 * y), v, v * (1.1 - 0.2 * x))
        }
        let frame = try MaskRender.frame(gpu, pixels, width: width)
        func field(_ size: (Int, Int)) throws -> MTLTexture {
            let texture = try GPU.makeTexture(device: gpu.device, width: size.0, height: size.1, usage: .shaderRead, pixelFormat: .rg32Float)
            let values = (0..<(size.0 * size.1)).flatMap { i -> [Float] in [0.3 + 0.5 * Float(i % 7) / 7, -1.5 + Float(i % 5) / 5] }
            values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, size.0, size.1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size.0 * 8) }
            return texture
        }
        let side = (1024, 1024 * height / width)
        let band = constants.texture.field(decodeLongSide: width, fullLongSide: 7008).fieldSize(width: width, height: height)
        let analysis = PresenceAnalysis(key: .init(decode: frame.maskGuide, version: constants.version),
                                        clarity: .init(positive: try field(side), negative: try field(side)),
                                        texture: .init(coefficients: try field((band.width, band.height)),
                                                       field: constants.texture.field(decodeLongSide: width, fullLongSide: 7008)),
                                        haze: .init(transmission: try field(side), airlight: SIMD3(0.6, 0.62, 0.66)))
        let count = PresenceToneWeights.samplesPerTable
        let weights = PresenceToneWeights(start: -14, step: 0.05, tables: Dictionary(uniqueKeysWithValues: PresenceToneWeights.Table.allCases.map {
            ($0, (0..<count).map { 1 + 0.5 * sin(Float($0) / 40) })
        }))
        let buffer = try #require(weights.samples.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        let light = try ManualAdjustments(exposureEV: 0.3, contrast: 20, highlights: -40, shadows: 30)
        let cases: [(name: String, values: [Presence.Control: Float])] = [
            ("off", [:]), ("Dehaze", [.dehaze: 60]), ("Clarity", [.clarity: 60]), ("Texture", [.texture: 60]),
            ("all three", [.dehaze: 60, .clarity: 60, .texture: 60]),
        ]
        let prepared = try cases.map { c -> (name: String, settings: DevelopSettings, inputs: PresenceRenderInputs?) in
            let manual = try ManualRenderSettings(adjustments: light.settingPresence(try Presence(c.values)), referenceStops: 0.3)
            var inputs = PresenceRenderInputs.bypass
            inputs.scene = try PresenceScene.inputs(manual, constants: constants, analysis: analysis, weights: (weights, buffer))
            var settings = PresenceRenderTests.settings(manual)
            settings.halation = halation
            return (c.name, settings, c.values.isEmpty ? nil : inputs)
        }
        var gpuTimes = Array(repeating: [Double](), count: cases.count), wallTimes = gpuTimes
        var outputs = Array(repeating: [UInt16](), count: cases.count)
        for round in 0..<13 {
            for (index, c) in prepared.enumerated() {
                try autoreleasepool {
                    let start = ContinuousClock.now
                    let rendered = try renderer.render(frame, settings: c.settings, presence: c.inputs)
                    let wall = (ContinuousClock.now - start).seconds
                    if round == 0 { outputs[index] = MaskRender.bits(rendered.image.texture) }
                    if round >= 3 {
                        gpuTimes[index].append(rendered.gpuSeconds * 1000)
                        wallTimes[index].append(wall * 1000)
                    }
                }
            }
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "%.2f ms (%.2f to %.2f)", sorted[sorted.count / 2], sorted.first!, sorted.last!)
        }
        for (index, c) in prepared.enumerated() {
            if index > 0 { #expect(outputs[index] != outputs[0], "\(c.name) changes the picture") }
            print("[evidence] scene stages \(width) x \(height) halation \(halation) \(c.name): GPU \(summary(gpuTimes[index])), render \(summary(wallTimes[index])), "
                  + "\(gpuTimes[index].count) runs")
        }
    }
}
