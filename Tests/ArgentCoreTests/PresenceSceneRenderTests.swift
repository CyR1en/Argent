import Foundation
import Metal
import Testing
@testable import ArgentCore

/// The scene stages in a render's own passes, through the Negative LUT pass and the halation field as `FilmRenderer` makes them, with the
/// hand-made inputs of `PresenceSceneRig`.
@Suite struct PresenceSceneRenderTests {
    static let presence: [Presence.Control: Float] = [.dehaze: 100, .clarity: 60, .texture: -50]

    /// A gain-table compiler's tone controls with their base field, the oldest compiler, and masks, each with `presence`.
    static func edits(_ presence: [Presence.Control: Float] = presence) throws -> [ManualRenderSettings] {
        let masked = try MaskRender.manual(try ManualAdjustments(exposureEV: 0.3, shadows: 40), masks: [
            MaskRender.mask(MaskRender.linear(0.5, 0.1, 0.5, 0.7), try ManualAdjustments(exposureEV: 1, highlights: -60)),
            MaskRender.mask(MaskRender.radial(0.3, 0.6, 0.2, 0.15), try ManualAdjustments(contrast: 50, whites: -40)),
        ], reference: 0.4)
        return try [ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55), referenceStops: 0.4),
                    LightCompilerBaselineTests.edits()[0], masked].map { try PresenceSceneRig.with($0, presence) }
    }

    static func settings(_ manual: ManualRenderSettings, halation: Bool = true, tone: PrintTone = .identity) -> DevelopSettings {
        DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3, halation: halation, manual: manual, tone: tone)
    }

    /// The light `scene_at` (or `scene_masked_at`) gives each pixel of `frame`, bound as the Negative pass binds it for `settings`.
    static func mapped(_ rig: PresenceSceneRig, _ renderer: FilmRenderer, _ frame: LinearFrame, _ settings: DevelopSettings,
                       inputs: PresenceSceneInputs) throws -> [SIMD3<Float>] {
        let stock = renderer.stock
        let (scene, base) = try renderer.sceneInputs(frame, settings: settings, exposureStops: settings.exposureStops(boxSpeed: stock.boxSpeed),
                                                     printOffset: settings.printOffset(densityRange: stock.densityRange,
                                                                                       exposurePerUnit: stock.exposurePerUnit))
        return try withExtendedLifetime(base) {
            scene.masks == nil ? try rig.sceneAt(scene, inputs: inputs, pixels: PresenceSceneRig.pixels)
                : try rig.maskedAt(scene, inputs: inputs, pixels: PresenceSceneRig.pixels).scene
        }
    }

    /// The halation source maps the light the Negative pass does. Each is checked against a frame that already holds that light, rendered
    /// with no edit: the glow made from the frame with the stages set matches the glow made from that frame, and so do the densities, to
    /// the half floats that frame is held in. Without the stages in the source, the glow would be the one made with none.
    @Test func theHalationSourceMapsTheLightTheNegativePassDoes() throws {
        let gpu = try GPU()
        let rig = try PresenceSceneRig(gpu)
        let negative = try MaskRender.Negative(gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try LightCompilerBaselineTests.frame(gpu)
        let plain = Self.settings(.identity)
        for manual in try Self.edits() {
            let settings = Self.settings(manual), inputs = try rig.inputs(manual)
            let staged = try negative.run(frame, settings: settings) { $0.presence = inputs }
            let mapped = try MaskRender.frame(gpu, try Self.mapped(rig, negative.renderer, frame, settings, inputs: inputs), width: PresenceSceneRig.width)
            let held = try negative.run(mapped, settings: plain)
            let field = MaskRender.read(try #require(staged.texture).texture)
            let glow = Self.apart(field, MaskRender.read(try #require(held.texture).texture))
            let unstaged = Self.apart(field, MaskRender.read(try #require(try negative.run(frame, settings: settings).texture).texture))
            MaskRender.report("halation \(manual.version) masks \(manual.hasEffectiveMasks): glow \(glow) of its largest, without the stages \(unstaged)")
            #expect(glow < 2e-3 && unstaged > 0.1, "\(manual.adjustments): \(glow) against \(unstaged)")
            let densities = MaskRender.difference(staged.densities, try negative.run(mapped, settings: plain, field: staged.texture?.texture).densities)
            MaskRender.report("negative \(manual.version) masks \(manual.hasEffectiveMasks): \(densities)")
            #expect(densities.worst <= 2, "\(manual.adjustments): \(densities)")
        }
    }

    /// Auto's tone step takes the light the stages leave, and the base of the light Dehaze leaves: with a dodge alone, which takes no
    /// colour, the toned kernels' light is the untoned kernels' bit for bit. While Dehaze is 0 the base they leave for the print pass is the
    /// one they leave without Presence, to the bit, whatever Clarity, Texture and Light do, on each Light compiler. With Dehaze set it is
    /// that base through Dehaze's map, `PresenceScene.dehazedBase`, with halation and without, and light Dehaze takes below black leaves
    /// the darkest base.
    @Test func autosToneStepTakesTheStagesLightAndTheDehazedBase() throws {
        let gpu = try GPU()
        let rig = try PresenceSceneRig(gpu)
        let negative = try MaskRender.Negative(gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try LightCompilerBaselineTests.frame(gpu)
        let detail: [Presence.Control: Float] = [.clarity: 60, .texture: -50]
        let exposedBase = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55),
                                                   referenceStops: 0.4, version: ManualRenderSettings.exposedBaseVersion)
        let undehazed = try Self.edits(detail) + [try PresenceSceneRig.with(.identity, detail), try PresenceSceneRig.with(.identity, [.texture: 30]),
                                                  try PresenceSceneRig.with(exposedBase, detail)]
        var belowBlack = 0
        for manual in try Self.edits() + Self.edits([.dehaze: -100]) + undehazed {
            for halation in [false, true] {
                let inputs = try rig.inputs(manual)
                let toned = try negative.run(frame, settings: Self.settings(manual, halation: halation, tone: Self.dodge)) { $0.presence = inputs }
                let untoned = try negative.run(frame, settings: Self.settings(manual, halation: halation)) { $0.presence = inputs }
                let without = try negative.run(frame, settings: Self.settings(manual, halation: halation, tone: Self.dodge))
                let label = "\(manual.version) \(manual.adjustments.presence) masks \(manual.hasEffectiveMasks) halation \(halation)"
                #expect(Self.channels(toned.densities, 0..<3) == Self.channels(untoned.densities, 0..<3), "\(label)")
                #expect(Self.channels(toned.densities, 0..<3) != Self.channels(without.densities, 0..<3), "\(label)")
                if inputs.parameters.dehaze == 0 {
                    #expect(Self.channels(toned.densities, 3..<4) == Self.channels(without.densities, 3..<4), "\(label)")
                } else {
                    belowBlack += Self.expectDehazedBases(toned.densities, untouched: without.densities, rig: rig, inputs: inputs, label)
                }
            }
        }
        #expect(belowBlack > 0, "Dehaze +100 takes some of the frame below black")
    }

    /// The masked toned kernels are made from the toned kernels' text, so a frame with masks takes the tone step's base as one without
    /// does: through the masked Negative pass under Dehaze, its alpha is the base it leaves without Presence through Dehaze's map.
    @Test func aMaskedTonedRenderUnderDehazeTakesTheDehazedBase() throws {
        let gpu = try GPU()
        let rig = try PresenceSceneRig(gpu)
        let negative = try MaskRender.Negative(gpu, stock: LightCompilerBaselineTests.toyStock())
        let frame = try LightCompilerBaselineTests.frame(gpu)
        let masks = try MaskRender.manual(try ManualAdjustments(shadows: 30), masks: [
            MaskRender.mask(MaskRender.radial(0.4, 0.5, 0.3, 0.25), try ManualAdjustments(exposureEV: 0.7, shadows: 40)),
            MaskRender.mask(MaskRender.linear(0.5, 0.9, 0.5, 0.3), try ManualAdjustments(highlights: -50), balance: MaskBalance(warmth: 20, magenta: -10)),
        ], reference: 0.2)
        for value: Float in [-70, 85] {
            let manual = try PresenceSceneRig.with(masks, [.dehaze: value])
            for halation in [false, true] {
                let inputs = try rig.inputs(manual)
                var masked = false
                let toned = try negative.run(frame, settings: Self.settings(manual, halation: halation, tone: Self.dodge)) {
                    $0.presence = inputs
                    masked = $0.masks != nil
                }
                let without = try negative.run(frame, settings: Self.settings(manual, halation: halation, tone: Self.dodge))
                #expect(masked, "the masked kernels render it")
                Self.expectDehazedBases(toned.densities, untouched: without.densities, rig: rig, inputs: inputs, "Dehaze \(value) halation \(halation)")
            }
        }
    }

    static let dodge = PrintTone(burn: 0, dodge: 0.4, referenceStops: -0.3)

    static func channels(_ bits: [UInt16], _ wanted: Range<Int>) -> [UInt16] { bits.enumerated().filter { wanted.contains($0.offset % 4) }.map(\.element) }

    /// The base a toned Negative pass left in each pixel's alpha, in stops against 0.18, against `untouched`'s, a render without Presence,
    /// taken through `PresenceScene.dehazedBase` at the pixel's uv and held in a half float as the alpha holds it. They may differ by the
    /// half's step there and by what `presence_dehazed_base` may differ from `dehazedBase` (`PresenceSceneFitTests`), 1e-4 of the
    /// dehazed luminance's terms as a share of that luminance. Most bases must move. That share allows many stops near black, so where
    /// Dehaze takes a pixel's grey below 0 by more than it, the alpha must be the floor's own half. Returns how many pixels that holds.
    @discardableResult
    static func expectDehazedBases(_ toned: [UInt16], untouched: [UInt16], rig: PresenceSceneRig, inputs: PresenceSceneInputs, _ label: String) -> Int {
        let reference = log2(Float(0.18)), width = PresenceSceneRig.width, height = PresenceSceneRig.height, q = inputs.parameters
        let alpha = channels(toned, 3..<4).map { Float(Float16(bitPattern: $0)) }
        let before = channels(untouched, 3..<4).map { Float(Float16(bitPattern: $0)) }
        let floor = Float(Float16(log2(q.hazeGuideFloor) - reference))
        var worst: Float = 0, moved = 0, belowBlack = 0
        for (i, base) in before.enumerated() {
            let uv = (SIMD2(Float(i % width), Float(i / width)) + 0.5) / SIMD2(Float(width), Float(height))
            let dehazed = PresenceScene.dehazedBase(base + reference, q, at: rig.dehaze.at(uv)), level = exp2(dehazed)
            let expected = Float(Float16(dehazed - reference))
            let d = abs(alpha[i] - expected) / (Float(Float16(expected).ulp) + 1e-4 * (2 * q.airlightLuminance + level) / level)
            worst = max(worst, d)
            if alpha[i] != base { moved += 1 }
            #expect(d <= 1, "\(label) pixel \(i): \(alpha[i]) against \(expected) from \(base)")
            let grey = PresenceScene.dehazed(SIMD3(repeating: exp2(base + reference)), q, at: rig.dehaze.at(uv))
            if ToneBaseField.luminance(grey) < -1e-4 * 2 * q.airlightLuminance {
                belowBlack += 1
                #expect(alpha[i] == floor, "\(label) pixel \(i) below black: \(alpha[i]) against the floor \(floor) from \(base)")
            }
        }
        #expect(moved > before.count / 2, "\(label): \(moved) of \(before.count) moved")
        MaskRender.report("tone step's base, \(label): worst \(worst) of the tolerance from dehazedBase, \(moved) of \(before.count) moved, \(belowBlack) below black at the floor")
        return belowBlack
    }

    /// A smart mask's coverage reads the untouched pixel, so Dehaze leaves it where it was: with the mask's Exposure alone, the masked
    /// mapping is one gain of 2^coverage on the light, the same with and without Dehaze, on a frame large enough for the per-pixel
    /// refinement, which reads each pixel's colour. Read at the dehazed light instead, the coverage would move.
    @Test func aSmartMasksCoverageIsTheSameWithAndWithoutDehaze() throws {
        let gpu = try GPU()
        let rig = try PresenceSceneRig(gpu)
        let (width, height) = (1200, 800)
        let (pixels, matte) = Refine.scene(width: width, height: height)
        let raster = try Refine.seed(matte: matte, width: width, height: height, seedWidth: 378, seedHeight: 252, binary: true)
        gpu.maskRefiner.seeds = Refine.Seeds([raster])
        let frame = try MaskRender.frame(gpu, pixels, width: width, picture: try MaskSpace(width: 7008, height: 4672))
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let sky = Mask(components: [try Refine.component(.sky, raster)], adjustments: try ManualAdjustments(exposureEV: 1))
        let placed = PresenceSceneRig.placed(pixels, width: width)
        for value: Float in [100, -100] {
            let manual = try PresenceSceneRig.with(try MaskRender.manual(masks: [sky]), [.dehaze: value])
            let scene = try Refine.scene(renderer, frame, Self.settings(manual, halation: false))
            #expect(try #require(scene.masks).refinement.refined != 0, "the per-pixel refinement is on")
            let staged = try rig.inputs(manual)
            var unstaged = staged
            unstaged.parameters.active = 0
            let with = try rig.maskedAt(scene, inputs: staged, pixels: placed), without = try rig.maskedAt(scene, inputs: unstaged, pixels: placed)
            // One gain for the three channels, so green's is the pixel's.
            func coverage(_ out: SIMD3<Float>, _ light: SIMD3<Float>) -> Float? { abs(light.y) > 1e-4 ? log2(out.y / light.y) : nil }
            var compared = 0, worst: Float = 0, moved = 0, edge = 0
            for i in placed.indices {
                guard let a = coverage(with.scene[i], with.dehazed[i]), let b = coverage(without.scene[i], placed[i].rgb),
                      let wrong = coverage(with.atDehazed[i], with.dehazed[i]) else { continue }
                compared += 1
                worst = max(worst, abs(a - b))
                if b > 0.02 && b < 0.98 { edge += 1 }
                if abs(wrong - b) > 0.01 { moved += 1 }
            }
            MaskRender.report("smart mask, Dehaze \(value): \(compared) pixels, coverage moved at most \(worst); \(edge) on the edge; read at the dehazed light, \(moved) move")
            #expect(compared > placed.count * 9 / 10 && edge > 1000)
            #expect(worst < 1e-5, "Dehaze \(value): coverage moved by \(worst)")
            #expect(moved > edge / 10, "Dehaze \(value): read at the dehazed light, \(moved) of \(edge) edge pixels move")
        }
    }

    /// The largest difference of two fields, as a share of the second's largest value.
    static func apart(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        zip(a, b).map { MaskRender.apart($0, $1) }.max()! / b.map { $0.max() }.max()!
    }
}
