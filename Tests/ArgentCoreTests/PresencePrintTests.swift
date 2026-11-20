import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Saturation and Vibrance on the print (`PresencePrint`, docs/presence-plan.md section 7.D): the block and its CPU reference against
/// `fit_colour.py` (`PresencePrintFixture.swift`), the kernel against the reference, and the stage inside the real print passes.
@Suite struct PresencePrintTests {
    static let portra = "kodak-portra-400"
    /// V3's Portra 400 strengths (validate/colour/report.md section 3.1), set by hand: the base's data holds 1 until package A's refresh.
    static let portraStrength = PresenceConstants.Vibrance.Strength(positive: 1.45, negative: 1.72)

    /// The current constants with Portra 400's strengths above and 1 for every other stock, so a refresh of the measured strengths
    /// leaves these tests where they are.
    static func constants() throws -> PresenceConstants {
        let c = try #require(PresenceConstants.named(Presence.currentVersion)), v = c.vibrance
        let vibrance = PresenceConstants.Vibrance(toProPhoto: v.toProPhoto, fromProPhoto: v.fromProPhoto, proPhotoToLMS: v.proPhotoToLMS,
                                                  oklabA: v.oklabA, oklabB: v.oklabB, proPhotoLuma: v.proPhotoLuma,
                                                  lightnessReference: v.lightnessReference, saturationKnee: v.saturationKnee,
                                                  positive: v.positive, negative: v.negative, strengths: [portra: portraStrength],
                                                  defaultStrength: .init(positive: 1, negative: 1))
        return PresenceConstants(version: c.version, source: c.source, texture: c.texture, clarity: c.clarity, dehaze: c.dehaze,
                                 saturation: c.saturation, vibrance: vibrance, detailLimitStops: c.detailLimitStops)
    }

    static func block(saturation: Float = 0, vibrance: Float = 0, stock: String = "light-toy",
                      constants: PresenceConstants) throws -> PresencePrintParameters {
        try PresencePrint.parameters(Presence([.saturation: saturation, .vibrance: vibrance]), constants: constants, stockID: stock)
    }

    static func colours(_ base64: String) -> [SIMD3<Float>] {
        let floats = Data(base64Encoded: base64)!.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (0..<floats.count / 3).map { SIMD3(floats[3 * $0], floats[3 * $0 + 1], floats[3 * $0 + 2]) }
    }

    /// The largest magnitude of the three, NaN if any is: `max` alone can drop a NaN, and a NaN must fail every bound.
    static func largest(_ a: SIMD3<Float>) -> Float {
        [a.x, a.y, a.z].contains { $0.isNaN } ? .nan : max(abs(a.x), abs(a.y), abs(a.z))
    }

    /// HSV saturation in linear ProPhoto, what Vibrance moves.
    static func proPhotoSaturation(_ rgb: SIMD3<Float>, _ v: PresenceConstants.Vibrance) -> Float {
        let p = v.toProPhoto.applied(to: rgb)
        return (p.max() - p.min()) / p.max()
    }

    /// `presence_print` itself on the GPU, one pixel a thread, compiled as the render's library is (default options, so fast math).
    static func kernel(_ pixels: [SIMD3<Float>], _ q: PresencePrintParameters) throws -> [SIMD3<Float>] {
        let gpu = try GPU()
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        \(ShaderSource.presenceParameters)
        \(ShaderSource.presencePrint)
        kernel void probe_print(constant PresencePrintParameters &q [[buffer(0)]], device const float *rgb [[buffer(1)]],
                                device float *out [[buffer(2)]], uint i [[thread_position_in_grid]]) {
            float3 c = presence_print(float3(rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2]), q);
            out[3 * i] = c.x; out[3 * i + 1] = c.y; out[3 * i + 2] = c.z;
        }
        """
        let library = try gpu.device.makeLibrary(source: source, options: nil)
        let pipeline = try gpu.device.makeComputePipelineState(function: try #require(library.makeFunction(name: "probe_print")))
        let flat = pixels.flatMap { [$0.x, $0.y, $0.z] }
        let input = try #require(gpu.device.makeBuffer(bytes: flat, length: 4 * flat.count, options: .storageModeShared))
        let output = try #require(gpu.device.makeBuffer(length: 4 * flat.count, options: .storageModeShared))
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        var block = q
        encoder.setBytes(&block, length: MemoryLayout<PresencePrintParameters>.stride, index: 0)
        encoder.setBuffer(input, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: pixels.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let values = UnsafeBufferPointer(start: output.contents().bindMemory(to: Float.self, capacity: flat.count), count: flat.count)
        return (0..<pixels.count).map { SIMD3(values[3 * $0], values[3 * $0 + 1], values[3 * $0 + 2]) }
    }

    static func render(_ renderer: FilmRenderer, _ gpu: GPU, _ settings: DevelopSettings,
                       presence: PresenceRenderInputs? = nil) throws -> [SIMD3<Float>] {
        MaskRender.read(try renderer.render(try LightCompilerBaselineTests.frame(gpu), settings: settings, presence: presence).image.texture)
    }

    /// The block from `parameters` and `applying` reproduce `sat_lightroom`, then `vib_hsv` at the stock's strength, on colours across
    /// the skin window, the knee and lightness, both signs, to 1e-5.
    @Test func applyingMatchesTheFitScript() throws {
        let constants = try Self.constants(), colours = Self.colours(Self.fixtureColours)
        for item in Self.fixtureCases {
            let q = try Self.block(saturation: item.saturation, vibrance: item.vibrance, stock: item.stock, constants: constants)
            let expected = Self.colours(item.output)
            #expect(expected.count == colours.count)
            let errors = zip(colours, expected).map { Self.largest(PresencePrint.applying(to: $0, parameters: q) - $1) }
            let worst = errors.indices.max { errors[$0] < errors[$1] }!
            #expect(errors[worst] <= 1e-5, "saturation \(item.saturation) vibrance \(item.vibrance) on \(item.stock): \(errors[worst]) at \(colours[worst])")
        }
    }

    /// `presence_print`, compiled as the render compiles it, gives `applying`'s numbers on every fixture colour and case.
    @Test func theKernelMatchesApplying() throws {
        let constants = try Self.constants(), colours = Self.colours(Self.fixtureColours)
        for item in Self.fixtureCases {
            let q = try Self.block(saturation: item.saturation, vibrance: item.vibrance, stock: item.stock, constants: constants)
            for (rgb, gpu) in zip(colours, try Self.kernel(colours, q)) {
                let cpu = PresencePrint.applying(to: rgb, parameters: q)
                #expect(Self.largest(gpu - cpu) <= 1e-5 * max(1, Self.largest(cpu)), "saturation \(item.saturation) vibrance \(item.vibrance): \(rgb)")
            }
        }
    }

    /// Both print kernels, plain and sharpened, run the stage on the Print LUT's output: their print is `applying` of the print without
    /// it, to the half floats both are stored in.
    @Test func thePrintKernelsApplyTheStage() throws {
        let gpu = try GPU(), constants = try Self.constants()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        for sharpen in [false, true] {
            let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3, grain: 1, grainSeed: 37,
                                           halation: true, sharpen: sharpen)
            let plain = try Self.render(renderer, gpu, settings)
            for (saturation, vibrance) in [(Float(0), Float(100)), (0, -100), (60, -40)] {
                var inputs = PresenceRenderInputs.bypass
                inputs.print = try Self.block(saturation: saturation, vibrance: vibrance, constants: constants)
                let staged = try Self.render(renderer, gpu, settings, presence: inputs)
                #expect(zip(plain, staged).contains { $0 != $1 }, "the stage moved the print")
                for (before, after) in zip(plain, staged) {
                    let expected = PresencePrint.applying(to: before, parameters: inputs.print)
                    #expect(Self.largest(after - expected) <= 4e-3 * max(Self.largest(expected), 1e-2),
                            "sharpen \(sharpen) saturation \(saturation) vibrance \(vibrance): \(before) printed \(after), expected \(expected)")
                }
            }
        }
    }

    /// Saturation -100 prints grey through the whole render, Presence in the edit as the app gives it: C* at most 0.1 on every pixel of
    /// the toy stock's print, with every recorded Light compiler, Auto's tone step, and both print kernels.
    @Test func saturationMinus100PrintsGrey() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let grey = try Presence([.saturation: -100])
        let light = try LightCompilerBaselineTests.edits().prefix(2) + LightCompilerBaselineTests.exposedBaseEdits().prefix(1)
            + [ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55), referenceStops: 0.4)]
        for edit in light {
            let manual = try ManualRenderSettings(adjustments: edit.adjustments.settingPresence(grey), referenceStops: edit.referenceStops,
                                                  version: edit.version)
            for tone in [PrintTone.identity, LightCompilerBaselineTests.toneStep] {
                for sharpen in [false, true] {
                    let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3, grain: 1, grainSeed: 37,
                                                   halation: true, sharpen: sharpen, manual: manual, tone: tone)
                    var coloured = settings
                    coloured.manual = edit
                    func chroma(_ rgb: SIMD3<Float>) -> Float { let lab = BalanceEdge.lab(rgb); return (lab.y * lab.y + lab.z * lab.z).squareRoot() }
                    #expect(try Self.render(renderer, gpu, coloured).map(chroma).contains { $0 > 5 }, "the print without the stage has colour")
                    let printed = try Self.render(renderer, gpu, settings).map(chroma)
                    #expect(printed.allSatisfy { $0 <= 0.1 }, "\(edit.version) tone \(tone.isActive) sharpen \(sharpen): C* up to \(printed.max()!)")
                }
            }
        }
    }

    /// The slip V3 named first: Saturation's grey must be Lightroom's, the colour's luminance in ProPhoto (the row Vibrance's lightness
    /// reads, through its matrix), not Rec. 2020's own luminance row. Red and blue tell the two apart by more than 0.01. F3's row is
    /// scaled to sum to 1, which puts it 4e-6 from the one through the matrix.
    @Test func saturationsGreyIsProPhotosLuminanceNotRec2020s() throws {
        let constants = try Self.constants(), v = constants.vibrance
        let q = try Self.block(saturation: -100, constants: constants)
        let rec2020Luminance = SIMD3<Float>(0.2627, 0.677998, 0.059302)
        for rgb in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0.8, 0.3, 0.1), SIMD3(0.1, 0.2, 0.7)] {
            let grey = PresencePrint.applying(to: rgb, parameters: q)
            let lightroom = (v.proPhotoLuma * v.toProPhoto.applied(to: rgb)).sum()
            #expect(grey == SIMD3(repeating: grey.x) && abs(grey.x - lightroom) <= 1e-5 * lightroom, "\(rgb): \(grey), ProPhoto's luminance \(lightroom)")
        }
        for rgb in [SIMD3<Float>(1, 0, 0), SIMD3(0, 0, 1)] {
            #expect(abs(PresencePrint.applying(to: rgb, parameters: q).x - (rec2020Luminance * rgb).sum()) > 0.01, "\(rgb)")
        }
    }

    /// The slip V3 named second: the stock's strength. Under the knee the positive side's boost of HSV saturation is the strength times
    /// strength 1's, and the negative side keeps over its floor `1 - t (1 + kappa (1 - t))` strength 1's share divided by the strength.
    /// A stock not listed takes the default.
    @Test func vibranceTakesTheStocksStrengthForEachSign() throws {
        let constants = try Self.constants(), v = constants.vibrance
        let muted = v.fromProPhoto.applied(to: SIMD3(0.184, 0.19, 0.2)), s0 = Self.proPhotoSaturation(muted, v)
        func saturation(_ value: Float, _ stock: String) throws -> Float {
            Self.proPhotoSaturation(PresencePrint.applying(to: muted, parameters: try Self.block(vibrance: value, stock: stock, constants: constants)), v)
        }
        for value: Float in [25, 50, 100] {
            let one = try saturation(value, "light-toy") / s0 - 1, strong = try saturation(value, Self.portra) / s0 - 1
            #expect(abs(strong / one - Self.portraStrength.positive) < 1e-3, "+\(value): \(strong / one)")
        }
        for value: Float in [-25, -50, -100] {
            let t = -value / 100, floor = 1 - t * (1 + v.negative.kappa * (1 - t))
            let one = try saturation(value, "light-toy") / s0 - floor, strong = try saturation(value, Self.portra) / s0 - floor
            #expect(abs(one / strong - Self.portraStrength.negative) < 1e-3, "\(value): \(one / strong)")
        }
        let unlisted = try Self.block(vibrance: 50, stock: "kodak-gold-200", constants: constants)
        #expect(unlisted.gainAmplitude == (try Self.block(vibrance: 50, stock: "light-toy", constants: constants)).gainAmplitude)
    }

    /// A Presence with neither print control set gets the bypass block, and a block with both off returns the pixel as it came.
    @Test func neitherControlIsTheBypass() throws {
        let constants = try Self.constants()
        for presence in [Presence.identity, try Presence([.clarity: 40, .dehaze: -20, .texture: 10])] {
            #expect(try PresencePrint.parameters(presence, constants: constants, stockID: Self.portra).active == 0)
        }
        var active = PresencePrintParameters.bypass
        active.active = 1
        for rgb in Self.colours(Self.fixtureColours) {
            #expect(PresencePrint.applying(to: rgb, parameters: active) == rgb)
        }
    }

    /// Saturation and Vibrance read no analysis part and no tone weights, so a render with them, at any step, builds neither.
    @Test func aPrintStepBuildsNothing() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        for values: [Presence.Control: Float] in [[.saturation: 30], [.saturation: 31], [.vibrance: -70], [.saturation: -5, .vibrance: 100]] {
            let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.3, presence: Presence(values)), referenceStops: 0)
            _ = try Self.render(renderer, gpu, PresenceRenderTests.settings(manual))
        }
        #expect(gpu.presenceAnalyses.statistics.builds == 0 && renderer.presenceWeightsBuilt == 0)
    }
}
