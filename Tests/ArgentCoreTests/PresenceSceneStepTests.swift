import Foundation
import Metal
import Testing
@testable import ArgentCore

/// A scene slider step builds nothing (plan section 8): no analysis part on a decode the cache holds and no tone weights, through the
/// renderer's own `presenceInputs`, with package A's weights and package B's builds. On a tree without them it is skipped: their own
/// not-built tests say so.
@Suite struct PresenceSceneStepTests {
    /// Whether the weights and the three builds make something rather than stop as not built. Any other error runs the suite, so it
    /// fails where it is.
    static let piecesBuilt: Bool = {
        guard let constants = PresenceConstants.named(Presence.currentVersion) else { return true }
        do {
            let gpu = try GPU()
            let frame = try LightCompilerBaselineTests.frame(gpu)
            _ = try PresenceToneWeights(constants: constants, referenceStops: 0, stock: LightCompilerBaselineTests.toyStock(), settings: DevelopSettings())
            let builder = PresenceAnalysisBuilder(device: gpu.device, queue: gpu.queue)
            _ = try builder.clarity(of: frame, constants: constants)
            _ = try builder.texture(of: frame, constants: constants)
            _ = try builder.haze(of: frame, constants: constants)
            return true
        } catch is PresenceError {
            return false
        } catch {
            return true
        }
    }()

    /// A decode the cache keeps (`PresenceAnalyses.keptMinimumLongSide`), with levels across the film's range and fine detail.
    static func frame(_ gpu: GPU) throws -> LinearFrame {
        let (width, height) = (1200, 800)
        let pixels = (0..<(width * height)).map { i -> SIMD3<Float> in
            let x = Float(i % width) / Float(width), y = Float(i / width) / Float(height)
            let detail: Float = (i % width / 3 + i / width / 3) % 2 == 0 ? 0.3 : -0.3
            let v = 0.18 * exp2(-6 + 10 * x + 2 * sin(9 * y) + detail)
            return SIMD3(v * (0.9 + 0.2 * y), v, v * (1.1 - 0.2 * x))
        }
        return try MaskRender.frame(gpu, pixels, width: width)
    }

    @Test(.enabled(if: piecesBuilt, "needs package A's tone weights and package B's builds"))
    func aSliderStepAnExposureDragAndAnUndoBuildNothing() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try Self.frame(gpu)
        func render(_ values: [Presence.Control: Float], exposure: Float = 0, on renderer: FilmRenderer) throws -> [UInt16] {
            let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: exposure, presence: try Presence(values)), referenceStops: 0.3)
            return MaskRender.bits(try renderer.render(frame, settings: PresenceRenderTests.settings(manual)).image.texture)
        }
        func built() -> (analysis: Int, weights: Int) { (gpu.presenceAnalyses.statistics.builds, renderer.presenceWeightsBuilt) }

        let first = try render([.clarity: 20], on: renderer)
        #expect(gpu.presenceAnalyses.statistics.clarityBuilds == 1 && built() == (1, 1), "the first nonzero scene control builds its part")
        var previous = first
        for value: Float in [21, 35, -40, -100, 5] {
            let now = try render([.clarity: value], on: renderer)
            #expect(now != previous, "Clarity \(value) moves the picture")
            previous = now
        }
        for exposure: Float in [0.5, -1] { _ = try render([.clarity: 5], exposure: exposure, on: renderer) }
        #expect(built() == (1, 1), "a step, Clarity crossing zero and an Exposure drag build nothing")

        _ = try render([.clarity: 5, .texture: 30], on: renderer)
        #expect(gpu.presenceAnalyses.statistics.textureBuilds == 1 && built() == (2, 1), "a second control builds its part alone")
        for value: Float in [31, -60] { _ = try render([.clarity: 5, .texture: value], on: renderer) }
        _ = try render([.clarity: 5, .texture: -60, .dehaze: 40], on: renderer)
        #expect(gpu.presenceAnalyses.statistics.hazeBuilds == 1 && built() == (3, 1))
        for value: Float in [41, -100, 10] { _ = try render([.clarity: 5, .texture: -60, .dehaze: value], on: renderer) }
        #expect(try render([.clarity: 20], on: renderer) == first, "an undo renders what it rendered")
        #expect(built() == (3, 1), "the steps, the sign changes and the undo build nothing")

        let other = try FilmRenderer(gpu: gpu, stock: try LightCompilerBaselineTests.bakedStocks.first.map { try Stock.load(from: $0) }
                                    ?? LightCompilerBaselineTests.toyStock())
        _ = try render([.clarity: -100, .texture: 50, .dehaze: -30], on: other)
        _ = try render([.clarity: -99, .texture: 50, .dehaze: -30], on: other)
        #expect(gpu.presenceAnalyses.statistics.builds == 3 && other.presenceWeightsBuilt == 1,
                "another stock reads the decode's analysis and builds its weights once")
    }
}
