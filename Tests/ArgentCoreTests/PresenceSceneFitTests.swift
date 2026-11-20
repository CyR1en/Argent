import Foundation
import Metal
import Testing
@testable import ArgentCore

/// `PresenceScene.applying` against the fits' own prototypes on recorded pixels (`PresenceSceneFitFixture`): `fit_dehaze.py`'s `dehaze`
/// and `fit_texture_clarity.py`'s stage, run by the fixture's script on the CC0 probe raw with the constants' own inputs. The block comes
/// from `PresenceScene.inputs`, so the laws at each value, the airlight, the fade, each side's strength and table and where the weights
/// are read are the ones a render takes.
@Suite struct PresenceSceneFitTests {
    typealias Fixture = PresenceSceneFitFixture
    static let constants = PresenceConstants.named(Presence.currentVersion)!

    /// One pixel of the fixture: its light, and the coefficients each field holds at it.
    struct Pixel {
        let rgb: SIMD3<Float>
        let dehaze: SIMD2<Float>, clarityPositive: SIMD2<Float>, clarityNegative: SIMD2<Float>, texture: SIMD2<Float>
    }

    static let pixels: [Pixel] = (0..<Fixture.count).map { i in
        let p = Array(Fixture.pixels[(i * 11)..<(i * 11 + 11)])
        return Pixel(rgb: SIMD3(p[0], p[1], p[2]), dehaze: SIMD2(p[3], p[4]), clarityPositive: SIMD2(p[5], p[6]),
                     clarityNegative: SIMD2(p[7], p[8]), texture: SIMD2(p[9], p[10]))
    }

    /// Dehaze's floor cases: each one's light and the coefficients stated for it.
    static let floorCases: [(rgb: SIMD3<Float>, dehaze: SIMD2<Float>)] = (0..<Fixture.floorCount).map { i in
        let p = Array(Fixture.floorCases[(i * 5)..<(i * 5 + 5)])
        return (SIMD3(p[0], p[1], p[2]), SIMD2(p[3], p[4]))
    }

    /// What the prototype's Dehaze made of the recorded pixel `i`, or of the floor case `i`, at `Fixture.dehazeValues[value]`.
    static func fitsDehaze(_ i: Int, value: Int, floor: Bool) -> SIMD3<Float> {
        let made = floor ? Fixture.floorDehazed : Fixture.dehazed, at = (i * Fixture.dehazeValues.count + value) * 3
        return SIMD3(made[at], made[at + 1], made[at + 2])
    }

    /// An analysis whose textures are never read, `applying` taking the coefficients from the fixture, but for Dehaze's `transmission`
    /// when a kernel reads it.
    static func analysis(_ gpu: GPU, transmission: MTLTexture? = nil) throws -> PresenceAnalysis {
        func field() throws -> MTLTexture { try GPU.makeTexture(device: gpu.device, width: 1, height: 1, usage: .shaderRead, pixelFormat: .rg32Float) }
        let frame = try LightCompilerBaselineTests.frame(gpu)
        return PresenceAnalysis(key: .init(decode: frame.maskGuide, version: constants.version), clarity: .init(positive: try field(), negative: try field()),
                                texture: .init(coefficients: try field(), field: constants.texture.field(decodeLongSide: Fixture.frame.width, fullLongSide: 7008)),
                                haze: .init(transmission: try transmission ?? field(), airlight: Fixture.airlight))
    }

    static func manual(_ values: [Presence.Control: Float], exposure: Float = 0) throws -> ManualRenderSettings {
        try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: exposure, presence: try Presence(values)), referenceStops: 0)
    }

    /// The error scale of `A + (I - A) G`: its terms, which cancel where the light lands near 0.
    static func terms(_ expected: SIMD3<Float>) -> Float {
        (0..<3).map { abs(Fixture.airlight[$0]) + abs(expected[$0] - Fixture.airlight[$0]) }.max()!
    }

    @Test func dehazeIsTheFitsDehazeAtEveryValue() throws {
        let worst = try Self.worstDehaze(Self.pixels.map { ($0.rgb, $0.dehaze) }, floor: false)
        MaskRender.report("Dehaze against fit_dehaze.py: \(Self.pixels.count) pixels at \(Fixture.dehazeValues.count) values, worst \(worst) of its terms")
    }

    /// Light no photograph reaches: luminance below 0, at 0 and within four stops of the floor of the guide the field was fitted under,
    /// where Light's guide reads another level. The field is read at the pixel's own guide as `Field.transmission` reads it.
    @Test func dehazeIsTheFitsDehazeAtAndBelowTheGuidesFloor() throws {
        let worst = try Self.worstDehaze(Self.floorCases, floor: true)
        MaskRender.report("Dehaze against fit_dehaze.py: \(Self.floorCases.count) floor cases at \(Fixture.dehazeValues.count) values, worst \(worst) of its terms")
    }

    /// `applying` with Dehaze alone and Light left out against the prototype on `cases` at every value; the worst error, of its terms.
    static func worstDehaze(_ cases: [(rgb: SIMD3<Float>, dehaze: SIMD2<Float>)], floor: Bool) throws -> Float {
        let analysis = try analysis(try GPU())
        var worst: Float = 0
        for (index, value) in Fixture.dehazeValues.enumerated() {
            let inputs = try PresenceScene.inputs(try manual([.dehaze: value]), constants: constants, analysis: analysis, weights: nil)
            for (i, pixel) in cases.enumerated() {
                let expected = fitsDehaze(i, value: index, floor: floor)
                let out = try PresenceScene.applying(to: pixel.rgb, inputs: inputs, at: .init(dehaze: pixel.dehaze), weights: nil) { light, _ in light }
                let d = MaskRender.apart(out, expected) / terms(expected)
                worst = max(worst, d)
                #expect(d < 1e-5, "Dehaze \(value) \(floor ? "floor case" : "pixel") \(i) \(pixel.rgb) at \(pixel.dehaze): \(out) against \(expected)")
            }
        }
        return worst
    }

    /// `scene_at`, which every Negative kernel and the halation source map light by, against the prototype's own numbers on every recorded
    /// pixel and floor case, and against `applying` on the same pixels. With Light at rest it leaves the light Dehaze leaves. Each case's
    /// coefficients sit in a texel of their own, read at its centre.
    @Test func theKernelIsTheFitsDehazeOnEveryRecordedPixelAndFloorCase() throws {
        let gpu = try GPU()
        let rig = try PresenceSceneRig(gpu)
        let cases = Self.pixels.map { (rgb: $0.rgb, dehaze: $0.dehaze) } + Self.floorCases
        let width = 1 << Int(log2(Double(cases.count)).rounded(.up))
        let field = try PresenceSceneRig.field(gpu.device, width: width, height: 1,
                                               coefficients: cases.map(\.dehaze) + Array(repeating: .zero, count: width - cases.count))
        let analysis = try Self.analysis(gpu, transmission: field.texture)
        let placed = cases.enumerated().map { i, pixel in (rgb: pixel.rgb, uv: SIMD2((Float(i) + 0.5) / Float(width), 0.5)) }
        var worst: (fit: Float, reference: Float) = (0, 0)
        for (index, value) in Fixture.dehazeValues.enumerated() {
            let manual = try Self.manual([.dehaze: value])
            let inputs = try PresenceScene.inputs(manual, constants: Self.constants, analysis: analysis, weights: nil)
            let out = try rig.sceneAt(manual, tables: nil, inputs: inputs, pixels: placed)
            for (i, pixel) in placed.enumerated() {
                let floor = i >= Fixture.count
                let expected = Self.fitsDehaze(floor ? i - Fixture.count : i, value: index, floor: floor)
                let reference = try PresenceScene.applying(to: pixel.rgb, inputs: inputs, at: .init(dehaze: field.at(pixel.uv)), weights: nil) { light, _ in light }
                let fit = MaskRender.apart(out[i], expected) / Self.terms(expected), cpu = MaskRender.apart(out[i], reference) / Self.terms(reference)
                worst = (max(worst.fit, fit), max(worst.reference, cpu))
                #expect(fit < 1e-4 && cpu < 1e-4, "Dehaze \(value) case \(i) \(pixel.rgb): \(out[i]) against the fit's \(expected) and applying's \(reference)")
            }
        }
        MaskRender.report("scene_at's Dehaze on \(cases.count) cases at \(Fixture.dehazeValues.count) values: worst \(worst.fit) of its terms from fit_dehaze.py, \(worst.reference) from applying")
    }

    /// Auto's tone step's cases (`PresenceDehazedBaseFixture`): each one's base and the coefficients of Dehaze's field at it.
    static let baseCases: [(base: Float, dehaze: SIMD2<Float>)] = stride(from: 0, to: PresenceDehazedBaseFixture.cases.count, by: 3).map { i in
        let c = PresenceDehazedBaseFixture.cases
        return (c[i], SIMD2(c[i + 1], c[i + 2]))
    }

    /// Two dehazed bases apart, by the luminance each is the guide of, against that luminance's terms, A_Y and (y - A_Y) G, which cancel
    /// where it lands near 0: together they are at most 2 A_Y + |Y|.
    static func basesApart(_ a: Float, _ b: Float) -> Float {
        abs(exp2(a) - exp2(b)) / (2 * ToneBaseField.luminance(Fixture.airlight) + exp2(b))
    }

    /// `dehazedBase` against the fit's Dehaze of a grey at the base, its transmission read at the grey's own level, on every case of
    /// `PresenceDehazedBaseFixture` at every value: the recorded pixels and the floor cases at the guide of their light, bases past the
    /// floor of the guide Dehaze's field is read under, and bases whose dehazed luminance cancels to 0.
    @Test func theDehazedBaseIsTheFitsDehazeOfAGreyAtThatBase() throws {
        let analysis = try Self.analysis(try GPU())
        #expect(Self.baseCases.count == PresenceDehazedBaseFixture.recordedCount + PresenceDehazedBaseFixture.floorCount
                + PresenceDehazedBaseFixture.statedCount + PresenceDehazedBaseFixture.crossingCount)
        var worst: Float = 0, moved = 0
        for (index, value) in Fixture.dehazeValues.enumerated() {
            let q = try PresenceScene.inputs(try Self.manual([.dehaze: value]), constants: Self.constants, analysis: analysis, weights: nil).parameters
            for (i, c) in Self.baseCases.enumerated() {
                let expected = PresenceDehazedBaseFixture.dehazedBases[i * Fixture.dehazeValues.count + index]
                let out = PresenceScene.dehazedBase(c.base, q, at: c.dehaze)
                let d = Self.basesApart(out, expected)
                worst = max(worst, d)
                if Self.basesApart(c.base, expected) > 1e-3 { moved += 1 }
                #expect(d < 1e-5, "Dehaze \(value) case \(i) base \(c.base) at \(c.dehaze): \(out) against \(expected)")
            }
        }
        #expect(moved > Self.baseCases.count * Fixture.dehazeValues.count / 2, "\(moved) cases move")
        MaskRender.report("dehazedBase against fit_dehaze.py: \(Self.baseCases.count) cases at \(Fixture.dehazeValues.count) values, worst \(worst) of its terms; \(moved) moved")
    }

    /// `presence_dehazed_base`, which the toned kernels take Auto's tone step's base through, against `dehazedBase` and the fit's numbers
    /// on every case of `PresenceDehazedBaseFixture`. Each case's coefficients sit in a texel of their own, read at its centre. With
    /// Dehaze at 0 it returns the base.
    @Test func theKernelsDehazedBaseIsTheReferenceAndTheFitsOnEveryCase() throws {
        let gpu = try GPU()
        let rig = try PresenceSceneRig(gpu)
        let width = 1 << Int(log2(Double(Self.baseCases.count)).rounded(.up))
        let field = try PresenceSceneRig.field(gpu.device, width: width, height: 1,
                                               coefficients: Self.baseCases.map(\.dehaze) + Array(repeating: .zero, count: width - Self.baseCases.count))
        let analysis = try Self.analysis(gpu, transmission: field.texture)
        let placed = Self.baseCases.enumerated().map { i, c in (base: c.base, uv: SIMD2((Float(i) + 0.5) / Float(width), 0.5)) }
        var worst: (fit: Float, reference: Float) = (0, 0)
        for (index, value) in Fixture.dehazeValues.enumerated() {
            let inputs = try PresenceScene.inputs(try Self.manual([.dehaze: value]), constants: Self.constants, analysis: analysis, weights: nil)
            let out = try rig.dehazedBase(inputs, bases: placed)
            for (i, c) in placed.enumerated() {
                let expected = PresenceDehazedBaseFixture.dehazedBases[i * Fixture.dehazeValues.count + index]
                let reference = PresenceScene.dehazedBase(c.base, inputs.parameters, at: field.at(c.uv))
                let fit = Self.basesApart(out[i], expected), cpu = Self.basesApart(out[i], reference)
                worst = (max(worst.fit, fit), max(worst.reference, cpu))
                #expect(fit < 1e-4 && cpu < 1e-4, "Dehaze \(value) case \(i) base \(c.base): \(out[i]) against the fit's \(expected) and dehazedBase's \(reference)")
            }
        }
        let untouched = try rig.dehazedBase(.bypass, bases: placed)
        #expect(zip(untouched, placed).allSatisfy { $0.bitPattern == $1.base.bitPattern }, "Dehaze 0 returns the base")
        MaskRender.report("presence_dehazed_base on \(placed.count) cases at \(Fixture.dehazeValues.count) values: worst \(worst.fit) of its terms from fit_dehaze.py, \(worst.reference) from dehazedBase")
    }

    /// Light Dehaze takes below black is the darkest base. For each case whose grey Dehaze takes below 0 at a positive value, up to +100,
    /// `dehazedBase` and `presence_dehazed_base` return the floor of Dehaze's own guide, log2(hazeGuideFloor), and never more than they
    /// return for that base at Dehaze 0. A base under that floor is the exception: Dehaze reads it at the floor, as its transmission does.
    /// A guide of the light's magnitude would read it brighter the further below black it falls.
    @Test func lightTakenBelowBlackIsTheDarkestBase() throws {
        let gpu = try GPU()
        let rig = try PresenceSceneRig(gpu)
        let width = 1 << Int(log2(Double(Self.baseCases.count)).rounded(.up))
        let field = try PresenceSceneRig.field(gpu.device, width: width, height: 1,
                                               coefficients: Self.baseCases.map(\.dehaze) + Array(repeating: .zero, count: width - Self.baseCases.count))
        let analysis = try Self.analysis(gpu, transmission: field.texture)
        let placed = Self.baseCases.enumerated().map { i, c in (base: c.base, uv: SIMD2((Float(i) + 0.5) / Float(width), 0.5)) }
        let floor = log2(PresenceAnalysisBuilder.hazeGuideFloor)
        let zero = try PresenceScene.inputs(try Self.manual([.dehaze: 0]), constants: Self.constants, analysis: analysis, weights: nil)
        let atZero = (cpu: placed.map { PresenceScene.dehazedBase($0.base, zero.parameters, at: field.at($0.uv)) },
                      gpu: try rig.dehazedBase(zero, bases: placed))
        var below = 0, underTheFloor = 0, worst: Float = 0
        for value in Fixture.dehazeValues where value > 0 {
            let inputs = try PresenceScene.inputs(try Self.manual([.dehaze: value]), constants: Self.constants, analysis: analysis, weights: nil)
            let kernel = try rig.dehazedBase(inputs, bases: placed)
            for (i, c) in placed.enumerated() {
                let grey = PresenceScene.dehazed(SIMD3(repeating: exp2(c.base)), inputs.parameters, at: field.at(c.uv))
                guard ToneBaseField.luminance(grey) < 0 else { continue }
                below += 1
                let cpu = PresenceScene.dehazedBase(c.base, inputs.parameters, at: field.at(c.uv))
                worst = max(worst, abs(kernel[i] - floor))
                let label = "Dehaze \(value) case \(i) base \(c.base): dehazedBase \(cpu), the kernel \(kernel[i]), at 0 \(atZero.cpu[i]) and \(atZero.gpu[i])"
                #expect(cpu == floor && abs(kernel[i] - floor) < 1e-5, "\(label), against the floor \(floor)")
                if c.base < floor {
                    underTheFloor += 1
                } else {
                    #expect(cpu <= atZero.cpu[i] && kernel[i] <= atZero.gpu[i], "\(label)")
                }
            }
        }
        #expect(below - underTheFloor >= 100, "\(below) cases below black, \(underTheFloor) of them under the floor")
        MaskRender.report("below black: \(below) case-values at the floor, \(underTheFloor) of them under it, the kernel worst \(worst) stops from it")
    }

    /// Exposure multiplies the dehazed light, which is Dehaze with `2^E A`: the prototype run on the exposed decode, its field and airlight
    /// made from it, is the stage on the untouched decode with Exposure after it.
    @Test func exposureAfterDehazeIsTheFitsDehazeOfTheExposedFrame() throws {
        let analysis = try Self.analysis(try GPU())
        for (index, (exposure, value)) in Fixture.exposed.enumerated() {
            let manual = try Self.manual([.dehaze: value], exposure: exposure)
            let inputs = try PresenceScene.inputs(manual, constants: Self.constants, analysis: analysis, weights: nil)
            for (i, pixel) in Self.pixels.enumerated() {
                let at = (i * Fixture.exposed.count + index) * 3
                let expected = SIMD3(Fixture.exposedDehazed[at], Fixture.exposedDehazed[at + 1], Fixture.exposedDehazed[at + 2])
                let out = try PresenceScene.applying(to: pixel.rgb, inputs: inputs, at: .init(dehaze: pixel.dehaze), weights: nil) { light, untouched in
                    try manual.applyingScene(to: light, baseLog2: ManualRenderSettings.guideLog2(untouched), tables: nil)
                }
                #expect(MaskRender.apart(out, expected) / (exp2(exposure) * Self.terms(expected / exp2(exposure))) < 1e-5,
                        "Exposure \(exposure) Dehaze \(value) pixel \(i): \(out) against \(expected)")
            }
        }
    }

    /// Clarity and Texture: `k(v) m(L*(base)) (g - base)` stops on all three channels, the weights read through the fixture's transfer
    /// line from tables that hold the constants' `ToneWeight` at each sample.
    @Test func clarityAndTextureAreTheFitsStageAtEveryValue() throws {
        let gpu = try GPU()
        let analysis = try Self.analysis(gpu)
        let count = PresenceToneWeights.samplesPerTable
        func table(_ side: PresenceConstants.DetailSide) -> [Float] {
            (0..<count).map { i in
                let x = Fixture.tableStart + Float(i) * Fixture.tableStep
                return side.weight.at(lightness: min(max(50 + x / Fixture.transferSlope, 0), 100))
            }
        }
        let weights = PresenceToneWeights(start: Fixture.tableStart, step: Fixture.tableStep, tables: [
            .clarityPositive: table(Self.constants.clarity.positive), .clarityNegative: table(Self.constants.clarity.negative),
            .texturePositive: table(Self.constants.texture.positive), .textureNegative: table(Self.constants.texture.negative),
        ])
        let buffer = try #require(weights.samples.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        var worst: Float = 0
        for control in [Presence.Control.clarity, .texture] {
            let stops = control == .clarity ? Fixture.clarityStops : Fixture.textureStops
            for (index, value) in Fixture.detailValues.enumerated() {
                let inputs = try PresenceScene.inputs(try Self.manual([control: value]), constants: Self.constants, analysis: analysis,
                                                      weights: (weights, buffer))
                for (i, pixel) in Self.pixels.enumerated() {
                    let sample = control == .clarity ? PresenceScene.FieldSample(clarity: value > 0 ? pixel.clarityPositive : pixel.clarityNegative)
                        : PresenceScene.FieldSample(texture: pixel.texture)
                    let delta = stops[i * Fixture.detailValues.count + index]
                    let expected = pixel.rgb * exp2(min(max(delta, -Self.constants.detailLimitStops), Self.constants.detailLimitStops))
                    let out = try PresenceScene.applying(to: pixel.rgb, inputs: inputs, at: sample, weights: weights) { light, _ in light }
                    let d = MaskRender.apart(out, expected) / expected.max()
                    worst = max(worst, d)
                    #expect(d < 1e-5, "\(control) \(value) pixel \(i): \(out) against \(expected), \(delta) stops")
                }
            }
        }
        MaskRender.report("Clarity and Texture against fit_texture_clarity.py: \(Self.pixels.count) pixels at \(Fixture.detailValues.count) values each, worst \(worst)")
    }

    /// The pixels reach what the stage branches on: light past the airlight's luminance on both sides of the fade's end, both signs'
    /// fields, and stops that move a pixel visibly.
    @Test func theRecordedPixelsReachTheFadeAndBothSides() {
        let airlight = ToneBaseField.luminance(Fixture.airlight)
        let levels = Self.pixels.map { ToneBaseField.luminance($0.rgb) / airlight }
        #expect(levels.filter { $0 >= 1 && $0 < 2 }.count >= 10 && levels.filter { $0 >= 2 }.count >= 10 && levels.filter { $0 < 1 }.count >= 100)
        #expect(Fixture.clarityStops.map(abs).max()! > 1 && Fixture.textureStops.map(abs).max()! > 0.3)
    }

    /// The floor cases reach where Dehaze's guide and Light's part, under fields sloped both ways: luminance below 0, the review's case
    /// first, and luminance above 0 within four stops of the floor the field was fitted under.
    @Test func theFloorCasesReachBelowZeroAndTheFloor() {
        let levels = Self.floorCases.map { ToneBaseField.luminance($0.rgb) }
        #expect(levels.filter { $0 < 0 }.count >= 16 && levels.filter { $0 > 0 && $0 <= 16 * PresenceAnalysisBuilder.hazeGuideFloor }.count >= 16)
        #expect(Self.floorCases[0].rgb == SIMD3(0.1, -0.1, 0) && Self.floorCases[0].dehaze == SIMD2(0.05, 0.9))
        #expect(Self.floorCases.contains { $0.dehaze.x > 0 } && Self.floorCases.contains { $0.dehaze.x < 0 })
    }
}
