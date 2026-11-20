import Foundation
import Metal
import Testing
@testable import ArgentCore

/// The renderer's Presence: inputs it makes through their owners, or inputs a test gives it (`FilmRenderer.render(_:settings:presence:)`).
/// A stage package renders its stage this way, with fields, weights and blocks of its own making and nothing of another package's.
@Suite struct PresenceRenderTests {
    static func settings(_ manual: ManualRenderSettings, tone: PrintTone = .identity) -> DevelopSettings {
        DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3, grain: 1, grainSeed: 37,
                        halation: true, sharpen: true, manual: manual, tone: tone)
    }

    /// Every recorded Light compiler's edits, the current one's with and without masks, so every Negative kernel the generators make
    /// is reached: plain, halation, toned, masked, and the halation source plain and masked.
    static func edits() throws -> [(manual: ManualRenderSettings, tone: PrintTone)] {
        let current = try [ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55, whites: -30, blacks: 20),
                           ManualAdjustments(exposureEV: -1, highlights: 100, curves: ToneCurves(tone: ToneCurves.Preset.softContrast.curve))]
            .map { try ManualRenderSettings(adjustments: $0, referenceStops: 0.4) }
        let masked = try MaskRender.manual(try ManualAdjustments(exposureEV: 0.3, shadows: 40), masks: [
            MaskRender.mask(MaskRender.linear(0.5, 0.1, 0.5, 0.7), try ManualAdjustments(exposureEV: 1, highlights: -60)),
            MaskRender.mask(MaskRender.radial(0.3, 0.6, 0.2, 0.15), try ManualAdjustments(contrast: 50, whites: -40)),
        ], reference: 0.4)
        let light = try LightCompilerBaselineTests.edits() + LightCompilerBaselineTests.exposedBaseEdits() + current + [masked]
        return light.map { ($0, .identity) } + [(current[0], LightCompilerBaselineTests.toneStep), (masked, LightCompilerBaselineTests.toneStep)]
    }

    static func bits(_ renderer: FilmRenderer, _ gpu: GPU, _ settings: DevelopSettings, presence: PresenceRenderInputs?) throws -> [UInt16] {
        MaskRender.bits(try renderer.render(try LightCompilerBaselineTests.frame(gpu), settings: settings, presence: presence).image.texture)
    }

    /// The scene branch taken (`active` 1) with every stage off renders today's bytes in every kernel: the two-input Light mapping with
    /// the same light is today's, and the stages, off, change nothing. Package C keeps this true when it writes them.
    @Test func anActiveSceneBlockWithEveryStageOffRendersTodaysBytes() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        var active = PresenceRenderInputs.bypass
        active.scene.parameters.active = 1
        for (manual, tone) in try Self.edits() {
            let settings = Self.settings(manual, tone: tone)
            #expect(try Self.bits(renderer, gpu, settings, presence: active) == (try Self.bits(renderer, gpu, settings, presence: nil)),
                    "\(manual.version) \(manual.adjustments) tone \(tone.isActive)")
        }
    }

    /// Package C's seam: an analysis, weights and a block made by hand, bound by every scene pass. With every strength at 0 the render
    /// is today's; with C's stages written, the same inputs with strengths set test them.
    @Test func handMadeFieldsAndWeightsRenderThroughTheSceneStages() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let builder = HandMadeAnalysisBuilder(device: gpu.device)
        let frame = try LightCompilerBaselineTests.frame(gpu)
        let constants = try #require(PresenceConstants.named(Presence.currentVersion))
        let analysis = PresenceAnalysis(key: .init(decode: frame.maskGuide, version: constants.version),
                                        clarity: try builder.clarity(of: frame, constants: constants),
                                        texture: try builder.texture(of: frame, constants: constants),
                                        haze: try builder.haze(of: frame, constants: constants))
        let ramp = (0..<PresenceToneWeights.samplesPerTable).map { Float($0) / Float(PresenceToneWeights.samplesPerTable) }
        let weights = PresenceToneWeights(start: -12, step: 0.05, tables: Dictionary(uniqueKeysWithValues: PresenceToneWeights.Table.allCases.map { ($0, ramp) }))
        #expect(weights.value(.texturePositive, at: -12) == 0 && weights.value(.clarityNegative, at: 100) == ramp.last)
        let buffer = try #require(weights.samples.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        var inputs = PresenceRenderInputs.bypass
        inputs.scene = PresenceSceneInputs(weights: buffer, clarity: analysis.clarity?.positive, texture: analysis.texture?.coefficients,
                                           dehaze: analysis.haze?.transmission, analysis: analysis)
        inputs.scene.parameters.active = 1
        inputs.scene.parameters.clarityWeights = UInt32(weights.offset(of: .clarityPositive))
        inputs.scene.parameters.weightCount = UInt32(PresenceToneWeights.samplesPerTable)
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.4, highlights: -30), referenceStops: 0.2)
        #expect(try Self.bits(renderer, gpu, Self.settings(manual), presence: inputs) == (try Self.bits(renderer, gpu, Self.settings(manual), presence: nil)))
    }

    /// Package D's seam: a print block given by hand, read by both print kernels and their toned copies. With both controls off the
    /// render is today's.
    @Test func aPrintBlockWithBothControlsOffRendersTodaysBytes() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        var inputs = PresenceRenderInputs.bypass
        inputs.print.active = 1
        let constants = try #require(PresenceConstants.named(Presence.currentVersion))
        inputs.print.toProPhoto = PresencePrintParameters.nine(constants.vibrance.toProPhoto)
        let edits = try Self.edits()
        for (manual, tone) in edits.prefix(3) + [edits[edits.count - 2]] {
            let settings = Self.settings(manual, tone: tone)
            #expect(try Self.bits(renderer, gpu, settings, presence: inputs) == (try Self.bits(renderer, gpu, settings, presence: nil)))
        }
    }

    /// The halation source's storage scale makes room for what Presence can add, and is today's without it.
    @Test func theHalationStoreMakesRoomForPresence() throws {
        for manual in try [ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.5), referenceStops: 0),
                           ManualRenderSettings(adjustments: ManualAdjustments(presence: Presence([.dehaze: 40])), referenceStops: 0)] {
            var scene = try ManualSceneInputs(manual)
            let today = HalationField.storageStops(exposureStops: 1, scene: scene)
            scene.presence.maximumGainStops = 2.5
            let light: Float = scene.parameters.sceneActive == 0 ? 0 : max(0, manual.adjustments.exposureEV)
            #expect(HalationField.storageStops(exposureStops: 1, scene: scene) == (1 + light + 2.5).rounded(.up))
            #expect(today == (scene.parameters.sceneActive == 0 ? 0 : (1 + light).rounded(.up)))
        }
    }
}
