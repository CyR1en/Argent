import CryptoKit
import Foundation
import Testing
@testable import ArgentCore

/// A generator with a fixed sequence, so a failure here is the same failure next time.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The toy stock built in code, and each baked stock the checkout has.
private func sceneStocks() throws -> [Stock] {
    try [LightCompilerBaselineTests.toyStock()] + LightCompilerBaselineTests.bakedStocks.map { try Stock.load(from: $0) }
}

private let sceneSettings = [
    DevelopSettings(),
    DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3),
]

private func bits(_ v: SIMD3<Float>) -> [UInt32] { [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }

/// Pixels and bases across and past the film's range: coloured, zero, signed and near zero, with
/// bases that differ from the pixels.
private func samples(reference: Float) -> [(rgb: SIMD3<Float>, base: Float)] {
    var out: [(rgb: SIMD3<Float>, base: Float)] = [(.zero, -8), (SIMD3(-0.05, 0.02, 0.4), -3), (SIMD3(1e-7, 2e-7, -1e-7), -20), (SIMD3(repeating: 40), 5)]
    for i in 0..<400 {
        let stops = -16 + 26 * Float(i) / 399 - reference
        let v = 0.18 * exp2(stops)
        let rgb = SIMD3<Float>(v * (0.8 + 0.4 * Float(i % 5) / 4), v, v * (1.2 - 0.4 * Float(i % 7) / 6))
        let base = ManualRenderSettings.guideLog2(rgb) + (i % 3 == 0 ? 0 : Float(i % 11) - 5)
        out.append((rgb, base))
    }
    return out
}

@Suite struct LocalSceneTableTests {
    @Test func theBufferIsLaidOutAsDocumented() throws {
        let scene = LocalScene(referenceStops: 0.5, stock: ToyStock.make(), settings: DevelopSettings())
        typealias L = LocalScene.Layout
        #expect(L.tableFloats == 17 * 512)
        #expect(L.count == 5 * 17 * 512 + 512 + 1401 + 3 * 17)
        #expect(scene.tables.count == L.count && scene.byteCount == L.count * 4)
        #expect(LocalScene.saturatingAxis.value(atKnot: 0) == -100 && LocalScene.saturatingAxis.last == 100 && LocalScene.saturatingAxis.spacing == 12.5)
        #expect(LocalScene.extendingAxis.value(atKnot: 0) == -200 && LocalScene.extendingAxis.last == 200 && LocalScene.extendingAxis.spacing == 25)
        // The generated rows sit on the axis, with the implicit zero.
        #expect(LightroomLocalToneTargets.stretchValues == (0..<L.knots).map { LocalScene.extendingAxis.value(atKnot: $0) })
        #expect(LightroomLocalToneTargets.values == (0..<L.knots).map { LocalScene.extendingAxis.value(atKnot: $0) }.filter { $0 != 0 })
        #expect(LightroomLocalToneTargets.lightness == LightroomToneTargets.lightness)
        for table in LocalScene.Table.allCases {
            // The zero knot is the middle one, and changes nothing.
            let zero = table.offset + (L.knots / 2) * L.samples
            #expect(table.axis.value(atKnot: L.knots / 2) == 0)
            #expect(scene.tables[zero..<(zero + L.samples)].allSatisfy { $0 == 0 })
        }
        #expect(Array(scene.tables[L.blackPoint..<L.outputFloor]) == LightroomLocalToneTargets.blackPoint)
        #expect(Array(scene.tables[L.outputFloor..<L.whitePoint]) == LightroomLocalToneTargets.outputFloor)
        #expect(Array(scene.tables[L.whitePoint..<L.count]) == LightroomLocalToneTargets.whitePoint)
    }

    /// k(|s|) is fitted at 25, 50, 75 and 100, and is the panel itself at the last.
    @Test func theScaleIsLinearBetweenItsFitsAndOneAtFullSize() {
        let negative = LightroomLocalToneTargets.highlightsScaleNegative, positive = LightroomLocalToneTargets.highlightsScalePositive
        for (i, size) in LightroomLocalToneTargets.scaleMagnitudes.enumerated() {
            #expect(LocalScene.scale(at: -size, negative: negative, positive: positive) == negative[i])
            #expect(LocalScene.scale(at: size, negative: negative, positive: positive) == positive[i])
        }
        #expect(LocalScene.scale(at: 12.5, negative: negative, positive: positive) == positive[0])
        #expect(abs(LocalScene.scale(at: -62.5, negative: negative, positive: positive) - (negative[1] + negative[2]) / 2) < 1e-6)
        for scale in [negative, positive, LightroomLocalToneTargets.shadowsScaleNegative, LightroomLocalToneTargets.shadowsScalePositive] {
            #expect(scale.last == 1 && scale.allSatisfy { $0 >= 1 })
        }
    }

    /// T̃'s row and its inverse row agree with `ManualToneTables.inverse`, and the inverse row's range
    /// holds T̃ on every stock, at the settings a print can reach, so the stretch never reads past it.
    @Test func theInverseRowInvertsTheTransfer() throws {
        let wide = [DevelopSettings(), DevelopSettings(ratedAt: 25, printExposure: 2), DevelopSettings(ratedAt: 6400, printExposure: -2)]
        for stock in try sceneStocks() {
            for settings in wide {
                let scene = LocalScene(referenceStops: 0.4, stock: stock, settings: settings)
                let neutral = ManualToneTables.Transfer(referenceStops: 0.4, stock: stock, settings: settings)
                #expect(Array(scene.tables[LocalScene.Layout.regularized..<LocalScene.Layout.inverse]) == neutral.regularized)
                #expect(neutral.regularized[0] >= LocalScene.Layout.inverseStart)
                #expect(neutral.regularized[511] <= LocalScene.Layout.inverseStart + Float(LocalScene.Layout.inverseCount - 1) / LocalScene.Layout.inverseScale)
                for i in stride(from: 0, to: 512, by: 7) {
                    let x = neutral.start + Float(i) * neutral.step
                    #expect(abs(scene.lightness(at: x) - neutral.regularized[i]) < 2e-3)
                    #expect(abs(scene.stops(atLightness: neutral.regularized[i]) - x) < 0.02, "\(stock.id) sample \(i)")
                }
            }
        }
    }

    /// Nothing a slider does can change the buffer, because no slider reaches it; these do.
    @Test func theTablesDependOnTheStockRatingPrintAndReference() throws {
        let stock = ToyStock.make()
        let base = LocalScene(referenceStops: 0.5, stock: stock, settings: DevelopSettings())
        #expect(base == LocalScene(referenceStops: 0.5, stock: stock, settings: DevelopSettings(grain: 1, grainSeed: 9, halation: true, sharpen: true)))
        #expect(base != LocalScene(referenceStops: 1.5, stock: stock, settings: DevelopSettings()))
        #expect(base != LocalScene(referenceStops: 0.5, stock: stock, settings: DevelopSettings(ratedAt: 200)))
        #expect(base != LocalScene(referenceStops: 0.5, stock: stock, settings: DevelopSettings(printExposure: 0.3)))
        // As the panel's ToneKey has it: the print offset holds the lab balance as well.
        #expect(base != LocalScene(referenceStops: 0.5, stock: stock, settings: DevelopSettings(labBalance: SIMD3(0.2, 0, 0))))
        // A panel at the same reference and settings shares the geometry the scene reads it with.
        let panel = try #require(try ManualRenderSettings(adjustments: ManualAdjustments(contrast: 30), referenceStops: 0.5)
            .toneTables(stock: stock, settings: DevelopSettings()))
        #expect(panel.start == base.start && panel.step == base.step)
    }

    /// Golden tables: every float of the buffer, by stock fingerprint. A change here changes every
    /// print with a mask, so it needs a new compiler id (plan section 4, rule 6). The toy stock must have a recorded
    /// digest, and when `build/stocks` is present so must every baked stock: one without fails and is named, as in
    /// `LightCompilerBaselineTests`, so a bake change cannot quietly leave the baked stocks unchecked.
    @Test func theTablesAreTheOnesFrozen() throws {
        var unrecorded: [String] = []
        for stock in try sceneStocks() {
            let fingerprint = LightCompilerBaselineTests.fingerprint(stock)
            var hash = SHA256()
            for settings in sceneSettings {
                let scene = LocalScene(referenceStops: 0.4, stock: stock, settings: settings)
                scene.tables.withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard let expected = Self.recorded[fingerprint] else {
                unrecorded.append("\(stock.id) (\(fingerprint))")
                continue
            }
            #expect(digest == expected, "\(stock.id)")
        }
        #expect(unrecorded.isEmpty, """
                Stocks have no recorded scene table digest: \(unrecorded.joined(separator: ", ")). \
                Record them in LocalSceneTableTests.recorded after an intended change of the bake, \
                or re-bake build/stocks if this checkout's bake is out of date.
                """)
    }

    /// Digests by stock fingerprint (`LightCompilerBaselineTests.fingerprint`). The toy stock's was taken when
    /// `LightroomLocalToneTargets` was first generated and is unchanged. The 14 baked stocks' were recorded on `main` at
    /// `e5bca7c7` on 2026-11-23 (macOS 27.2 build 26B123), with `build/stocks` as baked then. The bake had changed every
    /// stock: no fingerprint of the six stocks recorded first is among today's 14, so those entries were dropped. Scene gamut
    /// compression (2026-11-19) acts in the shader and leaves these tables alone, which the toy stock's unchanged digest
    /// shows. Two pairs of stocks, told apart by other numbers, make the same tables and so the same digest:
    /// kodak-colorplus-200 and kodak-gold-200, and kodak-portra-160 and kodak-portra-160-natural.
    static let recorded: [String: String] = [
        "c57831f42cf2fff7": "88c964539876921ffdf8fc6ff5a7b0a4ac83199bb923c86fba138180d7117cf7", // light-toy
        "949d6164d3351a62": "36c343aca7463ec021e0078d4544a59ea4fd77b3f3c00cbc6c2a07c218afe207", // cinestill-800t
        "a6da1896b2b4f9b5": "e2e6f1564b26c256f9f2de8b4526858a3359061e8d511b7198057d604200e34a", // fujifilm-c200
        "ab3fc45ad153d406": "79edcdc3a5106511cbdf075cf223aee9c1cb66fd370e09c5df246490e6484996", // fujifilm-pro-400h
        "034d966e7021564d": "b65faf6e6ff10d4c78aa157c0cde9a985bb8a5609dda12935481ad588eb3b236", // fujifilm-superia-400
        "99e292f723e67e6c": "a2a96c390eea88f5f8f902c12102a2a932e5e5964b53f8943865d1c5e74aa32f", // kodak-colorplus-200
        "41dd35cf8baec974": "8abd8c7693b6fc450b01f96694c2dac58226d46bc10d3946b2f2708067163a12", // kodak-ektar-100
        "b4fa9fe6f7e0e06f": "a2a96c390eea88f5f8f902c12102a2a932e5e5964b53f8943865d1c5e74aa32f", // kodak-gold-200
        "ef2f5ccafa11838d": "4d9aa04162de823239a9c909361485a7bab8faa9630ae2301417952cc12693c1", // kodak-portra-160
        "e92abdcb666a21d9": "4d9aa04162de823239a9c909361485a7bab8faa9630ae2301417952cc12693c1", // kodak-portra-160-natural
        "fc81ea0b270e96f3": "2aeab8c2152ab37002f09c8af19d21c1ba2104ddd93d842cbe5f040866f5879c", // kodak-portra-400
        "fdfd3cce8c35fb37": "f0e7a3e268aa7fd7e778ba84e2b90e834e549a5e03409e68d1ba40f711e243f1", // kodak-portra-800
        "46b68f5377170d20": "70a4d3401f1048850a71ddeb9bf18ffa7f7ad038e96c05f298c18db227046dee", // kodak-ultramax-400
        "d0334068916dcff7": "20a648f61712db4ec0f247b5928f563afa3d8085daec4226e55bbb21c958212f", // kodak-vision3-500t
        "712fa666980b0174": "44c5d5e0f8fb45f9b21052314dfff2a1595749ee2af41162d635daf102521dce", // kodak-vision3-500t-cinema
    ]
}

@Suite struct LocalSceneEvaluationTests {
    /// No masks: the panel's own result, bit for bit, whichever panel. These are the edits every Light
    /// compiler since `2026-10-29-1` renders alike, so it says the same before and after the current
    /// one changes; Exposure with Highlights or Shadows is the next test's.
    @Test func zeroSlidersAreThePanelExactly() throws {
        let edits = [
            try ManualAdjustments(),
            try ManualAdjustments(exposureEV: 1.5),
            try ManualAdjustments(whites: 40),
            try ManualAdjustments(highlights: -60),
            try ManualAdjustments(contrast: 40, highlights: -70, shadows: 55, whites: -30, blacks: 20),
            try ManualAdjustments(contrast: -100, highlights: 100, shadows: -100, whites: 100, blacks: -100),
            try ManualAdjustments(exposureEV: 0.65, contrast: 40, whites: -30, blacks: 20),
        ]
        for stock in try sceneStocks() {
            for settings in sceneSettings {
                let reference: Float = 0.75
                let scene = LocalScene(referenceStops: reference, stock: stock, settings: settings)
                for edit in edits {
                    let manual = try ManualRenderSettings(adjustments: edit, referenceStops: reference)
                    let tables = try manual.toneTables(stock: stock, settings: settings)
                    let panel = try LocalScene.Panel(manual, tables: tables)
                    for (rgb, base) in samples(reference: reference) {
                        let own = try manual.applyingScene(to: rgb, baseLog2: base, tables: tables)
                        let mine = scene.applying(to: rgb, baseLog2: base, sliders: .zero, panel: panel)
                        #expect(bits(mine) == bits(own), "\(stock.id) \(edit) \(rgb)")
                    }
                }
            }
        }
    }

    /// With no panel either, the evaluation's gain is zero and the pixel comes back untouched.
    @Test func zeroSlidersOverNoPanelAreZero() throws {
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0, stock: stock, settings: DevelopSettings())
            for (rgb, base) in samples(reference: 0) {
                #expect(scene.gain(x: ManualRenderSettings.guideLog2(rgb), xb: base, sliders: .zero, panel: .none) == 0)
                #expect(bits(scene.applying(to: rgb, baseLog2: base, sliders: .zero, panel: .none)) == bits(rgb))
            }
        }
    }

    /// One offset: the panel's local table reads the unexposed base, as a mask's Highlights and Shadows
    /// do, whatever Exposure the panel has. Only Contrast, Whites and Blacks move with it.
    @Test func thePanelsLocalTableReadsTheUnexposedBaseAsTheMasksDo() throws {
        let stock = ToyStock.make(), reference: Float = 0.25
        let scene = LocalScene(referenceStops: reference, stock: stock, settings: DevelopSettings())
        let o = scene.referenceOffset
        for e0: Float in [-1.5, 0, 1] {
            let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: e0, highlights: -60), referenceStops: reference)
            let tables = try #require(try manual.toneTables(stock: stock, settings: DevelopSettings()))
            let panel = try LocalScene.Panel(manual, tables: tables)
            let k = LocalScene.scale(at: -60, negative: LightroomLocalToneTargets.highlightsScaleNegative, positive: LightroomLocalToneTargets.highlightsScalePositive)
            #expect(panel.highlightsFade == 1 / k - 1)
            for x in stride(from: Float(-9), through: 2, by: 0.5) {
                let xb = x - 1, ub = xb + o
                #expect(scene.gain(x: x, xb: xb, sliders: .zero, panel: panel) == tables.value(tables.local, at: ub))
                let move = scene.gain(.highlights, at: ub, value: -90) - scene.gain(.highlights, at: ub, value: -60) * (1 + 0.5 * panel.highlightsFade)
                #expect(scene.gain(x: x, xb: xb, sliders: LocalSliders(highlights: -30), panel: panel) == tables.value(tables.local, at: ub) + move)
            }
        }
    }

    /// A compiler that takes no mask says so.
    @Test func theOldestCompilerTakesNoMask() throws {
        let old = try ManualRenderSettings(adjustments: ManualAdjustments(highlights: 20), referenceStops: 0, version: ManualRenderSettings.regionsVersion)
        #expect(throws: ManualDevelopmentError.self) { try LocalScene.Panel(old, tables: nil) }
    }

    /// Two masks, the helper and the evaluation together: one holding both, and either order.
    @Test func twoMasksEqualOneHoldingBothInEitherOrder() throws {
        let a = LocalSliders(exposureEV: 0.5, highlights: -50, whites: 30)
        let b = LocalSliders(contrast: 25, shadows: 40, blacks: -20)
        let both = LocalSliders(exposureEV: 0.5, contrast: 25, highlights: -50, shadows: 40, whites: 30, blacks: -20)
        #expect(LocalSliders(summing: [(a, 1, 1), (b, 1, 1)]) == both)
        #expect(LocalSliders(summing: [(b, 1, 1), (a, 1, 1)]) == both)
        // Partial coverage and Amount, the same in either order, bit for bit.
        let ab = LocalSliders(summing: [(a, 0.37, 1.4), (a, 0.61, 0.3)])
        let ba = LocalSliders(summing: [(a, 0.61, 0.3), (a, 0.37, 1.4)])
        #expect(ab == ba)
        let held = LocalSliders(exposureEV: 0.37 * 0.5, contrast: 0.37 * 25, highlights: 0.37 * -50, shadows: 0.37 * 40, whites: 0.37 * 30, blacks: 0.37 * -20)
        #expect(LocalSliders(summing: [(both, 0.37, 1)]) == held)
        #expect(LocalSliders(summing: [(a, 0.37, 1), (b, 0.37, 1)]) == held)

        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0.5, stock: stock, settings: DevelopSettings())
            for (rgb, base) in samples(reference: 0.5) {
                let one = scene.applying(to: rgb, baseLog2: base, sliders: both, panel: .none)
                let first = scene.applying(to: rgb, baseLog2: base, sliders: LocalSliders(summing: [(a, 1, 1), (b, 1, 1)]), panel: .none)
                let second = scene.applying(to: rgb, baseLog2: base, sliders: LocalSliders(summing: [(b, 1, 1), (a, 1, 1)]), panel: .none)
                #expect(bits(first) == bits(one) && bits(second) == bits(one), "\(stock.id) \(rgb)")
            }
        }
    }

    /// Three and more masks in another order: addition does not associate, so the sum can move by an
    /// ulp, and the evaluation by far less than any print can show. The worst difference in stops.
    static func worstOfAnotherOrder(_ stock: Stock) -> Float {
        let scene = LocalScene(referenceStops: 0, stock: stock, settings: DevelopSettings())
        var random = SplitMix64(state: 20261106)
        var worst: Float = 0
        for _ in 0..<500 {
            let masks = (0..<16).map { _ -> (mask: LocalSliders, coverage: Float, amount: Float) in
                let v = { Float.random(in: -100...100, using: &random) }
                return (LocalSliders(exposureEV: Float.random(in: -5...5, using: &random), contrast: v(), highlights: v(), shadows: v(), whites: v(), blacks: v()),
                        Float.random(in: 0...1, using: &random), Float.random(in: 0...2, using: &random))
            }
            let one = LocalSliders(summing: masks), other = LocalSliders(summing: masks.reversed())
            let x = Float.random(in: -12...4, using: &random)
            worst = max(worst, abs(scene.gain(x: x, xb: x, sliders: one, panel: .none) - scene.gain(x: x, xb: x, sliders: other, panel: .none)))
        }
        return worst
    }

    @Test func manyMasksInAnotherOrderAreWithinAnUlpOfTheSum() throws {
        for stock in try sceneStocks() {
            let worst = Self.worstOfAnotherOrder(stock)
            #expect(worst < 2e-4, "\(stock.id): \(worst) stops")
        }
    }

    /// Amount multiplies the slider, on every control and past 100: Lightroom's W+50 at Amount 2 is
    /// its W+100, 0.000.
    @Test func amountTwoAtFiftyIsAHundredExactly() throws {
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0.5, stock: stock, settings: DevelopSettings())
            let cases: [(LocalSliders, LocalSliders)] = [
                (LocalSliders(whites: 50), LocalSliders(whites: 100)),
                (LocalSliders(whites: 100), LocalSliders(whites: 200)),
                (LocalSliders(blacks: -50), LocalSliders(blacks: -100)),
                (LocalSliders(contrast: 75), LocalSliders(contrast: 150)),
                (LocalSliders(highlights: -50, shadows: 25), LocalSliders(highlights: -100, shadows: 50)),
                (LocalSliders(exposureEV: 1.25), LocalSliders(exposureEV: 2.5)),
            ]
            for (mask, doubled) in cases {
                let sum = LocalSliders(summing: [(mask, 1, 2)])
                #expect(sum == doubled)
                for (rgb, base) in samples(reference: 0.5) {
                    #expect(bits(scene.applying(to: rgb, baseLog2: base, sliders: sum, panel: .none))
                        == bits(scene.applying(to: rgb, baseLog2: base, sliders: doubled, panel: .none)))
                }
            }
            #expect(LocalSliders(summing: [(LocalSliders(whites: 77, blacks: -3), 0.4, 0)]) == .zero)
        }
    }

    /// A mask over the whole frame is the panel for Exposure, exactly.
    @Test func aWholeFrameMasksExposureIsThePanelsExactly() throws {
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0.5, stock: stock, settings: DevelopSettings())
            for e: Float in [-5, -1.5, -0.25, 0.65, 2, 5] {
                let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: e), referenceStops: 0.5)
                for (rgb, base) in samples(reference: 0.5) {
                    let mask = scene.applying(to: rgb, baseLog2: base, sliders: LocalSliders(exposureEV: e), panel: .none)
                    #expect(bits(mask) == bits(try manual.applyingScene(to: rgb, baseLog2: base, tables: nil)))
                }
            }
        }
    }

    /// A mask over the whole frame is, for Highlights and Shadows, the panel's table times k at the
    /// table's knots, so the panel itself at ±100, bit for bit.
    @Test func aWholeFrameMasksHighlightsAndShadowsAreThePanelsTimesK() throws {
        let controls: [(ManualAdjustments.Control, LocalScene.Table, [Float], [Float])] = [
            (.highlights, .highlights, LightroomLocalToneTargets.highlightsScaleNegative, LightroomLocalToneTargets.highlightsScalePositive),
            (.shadows, .shadows, LightroomLocalToneTargets.shadowsScaleNegative, LightroomLocalToneTargets.shadowsScalePositive),
        ]
        for stock in try sceneStocks() {
            for settings in sceneSettings {
                let reference: Float = 0.5
                let scene = LocalScene(referenceStops: reference, stock: stock, settings: settings)
                for (control, table, negative, positive) in controls {
                    for knot in 0..<LocalScene.Layout.knots where knot != LocalScene.Layout.knots / 2 {
                        let value = table.axis.value(atKnot: knot)
                        let manual = try ManualRenderSettings(adjustments: ManualAdjustments.identity.setting(control, to: value), referenceStops: reference)
                        let tables = try #require(try manual.toneTables(stock: stock, settings: settings))
                        let k = LocalScene.scale(at: value, negative: negative, positive: positive)
                        // Each row, sample for sample.
                        let row = Array(scene.tables[(table.offset + knot * 512)..<(table.offset + (knot + 1) * 512)])
                        #expect(row == tables.local.map { $0 * k }, "\(stock.id) \(control) \(value)")
                        guard abs(value) == 100 else { continue }
                        // At ±100, the whole evaluation against the panel's.
                        var s = LocalSliders()
                        if control == .highlights { s.highlights = value } else { s.shadows = value }
                        for (rgb, base) in samples(reference: reference) {
                            let own = try manual.applyingScene(to: rgb, baseLog2: base, tables: tables)
                            #expect(bits(scene.applying(to: rgb, baseLog2: base, sliders: s, panel: .none)) == bits(own), "\(stock.id) \(control) \(value)")
                        }
                    }
                }
            }
        }
    }

    /// Between knots the table is linear, and the panel's table times k is a little off that line:
    /// at the slider's value both are read through T̃ and compared in L*. Worst rms and worst level.
    static func betweenKnots(_ stock: Stock) throws -> (rms: Float, level: Float) {
        let controls: [(ManualAdjustments.Control, LocalScene.Table, [Float], [Float])] = [
            (.highlights, .highlights, LightroomLocalToneTargets.highlightsScaleNegative, LightroomLocalToneTargets.highlightsScalePositive),
            (.shadows, .shadows, LightroomLocalToneTargets.shadowsScaleNegative, LightroomLocalToneTargets.shadowsScalePositive),
        ]
        var worstRMS: Float = 0, worstLevel: Float = 0
        let scene = LocalScene(referenceStops: 0.5, stock: stock, settings: DevelopSettings())
        for (control, table, negative, positive) in controls {
            for value: Float in [-93, -81, -60, -44, -31, -19, -6, 6, 19, 31, 44, 60, 81, 93] {
                let manual = try ManualRenderSettings(adjustments: ManualAdjustments.identity.setting(control, to: value), referenceStops: 0.5)
                let tables = try #require(try manual.toneTables(stock: stock, settings: DevelopSettings()))
                let k = LocalScene.scale(at: value, negative: negative, positive: positive)
                var sum: Float = 0
                for i in 0..<512 {
                    let x = scene.start + Float(i) * scene.step
                    let interpolated = scene.lightness(at: x + scene.gain(table, at: x, value: value))
                    let exact = scene.lightness(at: x + k * tables.value(tables.local, at: x))
                    let d = abs(interpolated - exact)
                    worstLevel = max(worstLevel, d)
                    sum += d * d
                }
                worstRMS = max(worstRMS, (sum / 512).squareRoot())
            }
        }
        return (worstRMS, worstLevel)
    }

    @Test func betweenKnotsHighlightsAndShadowsStayWithinTheInterpolationTolerance() throws {
        for stock in try sceneStocks() {
            let worst = try Self.betweenKnots(stock)
            #expect(worst.rms < 0.03 && worst.level < 0.4, "\(stock.id): worst rms \(worst.rms), worst level \(worst.level) L*")
        }
    }

    /// A mask's Contrast, Whites and Blacks land on their local targets through the transfer: where
    /// the film separates tones and no floor or limit acts, T̃(x + G(x, s)) − T̃(x) is the target's
    /// change. Past 100 too, on every row.
    @Test func aMasksContrastWhitesAndBlacksMeetTheirLocalTargets() throws {
        let controls: [(LocalScene.Table, [[Float]])] = [(.contrast, LightroomLocalToneTargets.contrast), (.whites, LightroomLocalToneTargets.whites), (.blacks, LightroomLocalToneTargets.blacks)]
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0.4, stock: stock, settings: DevelopSettings())
            let neutral = ManualToneTables.Transfer(referenceStops: 0.4, stock: stock, settings: DevelopSettings())
            let t = neutral.regularized
            for (table, rows) in controls {
                for knot in 0..<LocalScene.Layout.knots where knot != LocalScene.Layout.knots / 2 {
                    let value = table.axis.value(atKnot: knot)
                    let target = try #require(ManualToneTables.Target(rows, value: value, values: LightroomLocalToneTargets.values, lightness: LightroomLocalToneTargets.lightness))
                    var checked = 0
                    var previous = -Float.infinity
                    for i in 0..<512 {
                        let x = neutral.xs[i]
                        let aim = t[i] + target.change(at: t[i])
                        // Where the targets' slope floor has acted, or still would, the aim moved.
                        let floored = aim < previous + ManualToneTables.minimumTargetSlope * (i > 0 ? t[i] - t[i - 1] : 0)
                        previous = max(aim, previous + ManualToneTables.minimumTargetSlope * (i > 0 ? t[i] - t[i - 1] : 0))
                        let g = scene.tables[table.offset + knot * 512 + i]
                        guard !floored, abs(g) < ManualToneTables.gainKnee, x + g > neutral.xs[0], x + g < neutral.xs[511], aim > t[0], aim < t[511] else { continue }
                        let reached = scene.lightness(at: x + g)
                        #expect(abs(reached - aim) < 0.02, "\(stock.id) \(table) \(value) sample \(i)")
                        checked += 1
                    }
                    #expect(checked > 100, "\(stock.id) \(table) \(value): \(checked)")
                }
            }
        }
    }

    /// The rows themselves hold Lightroom's published shape: white stays white and black black except
    /// where the control moves them, past 100 keeps going, and the stretch's rows are monotone.
    @Test func theGeneratedRowsHaveLightroomsShape() throws {
        let t = LightroomLocalToneTargets.self
        let at = { (rows: [[Float]], value: Float) in rows[t.values.firstIndex(of: value)!] }
        #expect(t.values.count == 16 && t.lightness.count == 41 && t.whites.allSatisfy { $0.count == 41 })
        // Whites −100 takes white to about 79.7, Blacks +100 black to about 30: the columns the
        // panel's file holds at zero are measured here.
        #expect(abs(at(t.whites, -100)[40] - (79.7 - 100)) < 0.5)
        #expect(abs(at(t.blacks, 100)[0] - 29.77) < 0.5)
        #expect(at(t.whites, 100)[40] == 0 && at(t.blacks, -100)[0] == 0)
        // Past 100, more of the same: Lightroom's Amount 2 is about 1.4 to 2.1 times Amount 1.
        for rows in [t.contrast, t.whites, t.blacks] {
            for sign: Float in [-1, 1] {
                let one = at(rows, sign * 100).map(abs).reduce(0, +), two = at(rows, sign * 200).map(abs).reduce(0, +)
                let between = at(rows, sign * 150).map(abs).reduce(0, +)
                #expect(two > one && between > one && between < two)
            }
        }
        // White point falls and black point rises with the slider; floor rises above 0.
        let knots = t.stretchValues.count
        for i in 1..<knots {
            #expect(t.whitePoint[i] < t.whitePoint[i - 1])
            #expect(t.blackPoint[i] <= t.blackPoint[i - 1])
            #expect(t.outputFloor[i] >= t.outputFloor[i - 1])
        }
        #expect(t.whitePoint[knots / 2] == 100 && t.blackPoint[knots / 2] == 0 && t.outputFloor[knots / 2] == 0)
    }

    /// The stretch is taken exactly where Whites is set and Blacks is below 0; a single control and
    /// Blacks above 0 stay on the tables. Where the film separates tones it lands on the levels.
    @Test func whitesWithBlacksBelowZeroIsOneStretch() throws {
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0.4, stock: stock, settings: DevelopSettings())
            for x in stride(from: Float(-10), through: 6, by: 0.37) {
                let w = LocalSliders(whites: 50), b = LocalSliders(blacks: -50), lift = LocalSliders(blacks: 50)
                let both = LocalSliders(whites: 50, blacks: -50), withLift = LocalSliders(whites: 50, blacks: 50)
                #expect(scene.gain(x: x, xb: x, sliders: w, panel: .none) == scene.gain(.whites, at: x + scene.referenceOffset, value: 50))
                #expect(scene.gain(x: x, xb: x, sliders: b, panel: .none) == scene.gain(.blacks, at: x + scene.referenceOffset, value: -50))
                #expect(scene.gain(x: x, xb: x, sliders: lift, panel: .none) == scene.gain(.blacks, at: x + scene.referenceOffset, value: 50))
                let level = x + scene.referenceOffset
                #expect(scene.gain(x: x, xb: x, sliders: both, panel: .none) == scene.stretchGain(at: level, whites: 50, blacks: -50))
                let first = scene.gain(.whites, at: level, value: 50)
                #expect(scene.gain(x: x, xb: x, sliders: withLift, panel: .none) == first + scene.gain(.blacks, at: level + first, value: 50))
            }
            // The levels themselves.
            let black: Float = 18.19, white: Float = 87.79
            for lightness in stride(from: Float(25), through: 80, by: 5) {
                let level = scene.stops(atLightness: lightness)
                let reached = scene.lightness(at: level + scene.stretchGain(at: level, whites: 50, blacks: -50))
                #expect(abs(reached - 100 * (lightness - black) / (white - black)) < 0.1, "\(stock.id) at L* \(lightness)")
            }
        }
    }

    /// Highlights and Shadows read the base before any Exposure, a mask's or the panel's; Contrast,
    /// Whites and Blacks read the exposed level.
    @Test func highlightsAndShadowsReadTheUnexposedBase() throws {
        let reference: Float = 0.4
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: reference, stock: stock, settings: DevelopSettings())
            let exposed = { (e: Float) throws -> LocalScene.Panel in
                let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: e), referenceStops: reference)
                return try LocalScene.Panel(manual, tables: nil)
            }
            for (rgb, base) in samples(reference: reference) {
                let x = ManualRenderSettings.guideLog2(rgb)
                for tone in [LocalSliders(highlights: -50), LocalSliders(shadows: 60), LocalSliders(highlights: 100, shadows: -100)] {
                    let unexposed = scene.gain(x: x, xb: base, sliders: tone, panel: .none)
                    #expect(unexposed == scene.gain(.highlights, at: base + scene.referenceOffset, value: tone.highlights)
                        + scene.gain(.shadows, at: base + scene.referenceOffset, value: tone.shadows))
                    for e: Float in [-1.5, 1.5] {
                        var withExposure = tone
                        withExposure.exposureEV = e
                        #expect(scene.gain(x: x, xb: base, sliders: withExposure, panel: .none) == unexposed, "\(stock.id) mask's \(e)")
                        #expect(scene.gain(x: x, xb: base, sliders: tone, panel: try exposed(e)) == unexposed, "\(stock.id) panel's \(e)")
                        let applied = scene.applying(to: rgb, baseLog2: base, sliders: withExposure, panel: .none)
                        #expect(bits(applied) == bits(rgb * exp2(e) * exp2(unexposed)))
                    }
                }
                // Whites reads the exposed level: it is the table at u, a mask's Exposure and the panel's alike.
                for e: Float in [-1.5, 1.5] {
                    let u = x + scene.referenceOffset
                    let g = scene.gain(x: x, xb: base, sliders: LocalSliders(exposureEV: e, whites: 50), panel: .none)
                    #expect(abs(g - scene.gain(.whites, at: u + e, value: 50)) < 2e-5)
                }
            }
        }
    }

    /// Past its axis a control stays where its axis ends: ±100 for Highlights and Shadows, ±200 for
    /// Contrast, Whites and Blacks.
    @Test func sumsClampToTheirAxes() throws {
        let scene = LocalScene(referenceStops: 0, stock: ToyStock.make(), settings: DevelopSettings())
        for x in stride(from: Float(-14), through: 10, by: 0.61) {
            let level = x + scene.referenceOffset
            for (table, end) in [(LocalScene.Table.highlights, Float(100)), (.shadows, 100), (.contrast, 200), (.whites, 200), (.blacks, 200)] {
                #expect(scene.gain(table, at: level, value: end * 3) == scene.gain(table, at: level, value: end))
                #expect(scene.gain(table, at: level, value: -end * 3) == scene.gain(table, at: level, value: -end))
            }
            #expect(scene.stretchGain(at: level, whites: 900, blacks: -900) == scene.stretchGain(at: level, whites: 200, blacks: -200))
            #expect(scene.gain(x: x, xb: x, sliders: LocalSliders(exposureEV: 100), panel: .none)
                == scene.gain(x: x, xb: x, sliders: LocalSliders(exposureEV: LocalScene.exposureLimit), panel: .none))
        }
    }

    /// Finite everywhere it can be asked, at the extremes of every axis at once: ±5 EV on the panel,
    /// the Exposure of sixteen masks at Amount 2, ±200 sums, with zero and signed channels.
    @Test func extremesStayFinite() throws {
        let extremes: [Float] = [-1000, -200, 0, 200, 1000]
        let exposures: [Float] = [-160, -10, -5, 0, 5, 10, 160]
        let pixels: [(rgb: SIMD3<Float>, base: Float)] = [
            (.zero, 40), (.zero, -40), (SIMD3(-1, 0, 1), 0), (SIMD3(0, 1, 0), -100), (SIMD3(repeating: 1e6), 40),
            (SIMD3(repeating: 1e-30), -40), (SIMD3(1e6, -1e6, 0), 12), (SIMD3(0.18, 0.18, 0.18), .nan),
        ]
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0.4, stock: stock, settings: DevelopSettings(ratedAt: 800, printExposure: 1))
            for e0: Float in [-5, 0, 5] {
                for edit in [ManualAdjustments.identity, try ManualAdjustments(contrast: 100, highlights: -100, shadows: 100, whites: 100, blacks: -100)] {
                    let manual = try ManualRenderSettings(adjustments: edit.setting(.exposure, to: e0), referenceStops: 0.4)
                    let tables = try manual.toneTables(stock: stock, settings: DevelopSettings(ratedAt: 800, printExposure: 1))
                    let panel = try LocalScene.Panel(manual, tables: tables)
                    for e in exposures {
                        for c in extremes {
                            for h in extremes {
                                for w in extremes {
                                    for b in extremes {
                                        let s = LocalSliders(exposureEV: e, contrast: c, highlights: h, shadows: -h, whites: w, blacks: b)
                                        for (rgb, base) in pixels {
                                            let out = scene.applying(to: rgb, baseLog2: base, sliders: s, panel: panel)
                                            #expect(out.x.isFinite && out.y.isFinite && out.z.isFinite, "\(stock.id) \(s) \(rgb)")
                                            #expect(abs(scene.gain(x: ManualRenderSettings.guideLog2(rgb), xb: base, sliders: s, panel: panel)) <= LocalScene.gainLimit)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Zero sliders with Exposure and Highlights or Shadows both set: the arithmetic of Light compiler
    /// `2026-11-06-1`, the first masks render under, written out, bit for bit. (Once that compiler is
    /// current in the tree, this can read `manual.applyingScene`.)
    @Test func zeroSlidersWithExposureAreTheCurrentCompilersOwnResult() throws {
        let edits = [
            try ManualAdjustments(exposureEV: 1.5),
            try ManualAdjustments(exposureEV: -1.5, highlights: -60),
            try ManualAdjustments(exposureEV: 0.65, contrast: 40, highlights: -70, shadows: 55, whites: -30, blacks: 20),
            try ManualAdjustments(exposureEV: 1, contrast: -100, highlights: 100, shadows: -100, whites: 100, blacks: -100),
        ]
        for stock in try sceneStocks() {
            let reference: Float = 0.75
            let scene = LocalScene(referenceStops: reference, stock: stock, settings: DevelopSettings())
            for edit in edits {
                let manual = try ManualRenderSettings(adjustments: edit, referenceStops: reference)
                let tables = try manual.toneTables(stock: stock, settings: DevelopSettings())
                let panel = try LocalScene.Panel(manual, tables: tables)
                #expect(panel.highlights == edit.highlights && panel.shadows == edit.shadows)
                let guideOffset = edit.exposureEV + reference - log2(Float(0.18))
                for (rgb, base) in samples(reference: reference) {
                    var own = rgb * exp2(edit.exposureEV)
                    if let tables {
                        let local = tables.localActive ? tables.value(tables.local, at: base + scene.referenceOffset) : 0
                        let global = tables.globalActive ? tables.value(tables.global, at: ManualRenderSettings.guideLog2(rgb) + guideOffset + local) : 0
                        own = own * exp2(local + global)
                    }
                    #expect(bits(scene.applying(to: rgb, baseLog2: base, sliders: .zero, panel: panel)) == bits(own), "\(stock.id) \(edit)")
                }
            }
        }
    }

    /// H0 = S0 = 0: the masks' own evaluation exactly, written out, with no panel, a panel of nothing
    /// and panels on other controls.
    @Test func zeroPanelIsTheMasksOwnEvaluationExactly() throws {
        let masks = [LocalSliders(highlights: -37), LocalSliders(shadows: 60), LocalSliders(exposureEV: 0.7, contrast: 20, highlights: 13, shadows: -90, whites: 30, blacks: 40)]
        for stock in try sceneStocks() {
            let reference: Float = 0.5
            let scene = LocalScene(referenceStops: reference, stock: stock, settings: DevelopSettings())
            let o = scene.referenceOffset
            for edit in [ManualAdjustments.identity, try ManualAdjustments(exposureEV: 1), try ManualAdjustments(whites: 40), try ManualAdjustments(exposureEV: -1, contrast: 30, blacks: -20)] {
                let manual = try ManualRenderSettings(adjustments: edit, referenceStops: reference)
                let tables = try manual.toneTables(stock: stock, settings: DevelopSettings())
                let panel = try LocalScene.Panel(manual, tables: tables)
                #expect(panel.highlights == 0 && panel.shadows == 0 && panel.highlightsFade == 0 && panel.shadowsFade == 0)
                for mask in masks {
                    for (rgb, base) in samples(reference: reference) {
                        let x = ManualRenderSettings.guideLog2(rgb)
                        let u = x + (edit.exposureEV + reference - log2(Float(0.18))) + mask.exposureEV
                        var t: Float = 0
                        if mask.highlights != 0 { t += scene.gain(.highlights, at: base + o, value: mask.highlights) }
                        if mask.shadows != 0 { t += scene.gain(.shadows, at: base + o, value: mask.shadows) }
                        if let tables, tables.globalActive { t += tables.value(tables.global, at: u + t) }
                        if mask.contrast != 0 { t += scene.gain(.contrast, at: u + t, value: mask.contrast) }
                        if mask.whites != 0 { t += scene.gain(.whites, at: u + t, value: mask.whites) }
                        if mask.blacks != 0 { t += scene.gain(.blacks, at: u + t, value: mask.blacks) }
                        let own = min(max(t, -8), 8)
                        #expect(scene.gain(x: x, xb: base, sliders: mask, panel: panel).bitPattern == own.bitPattern, "\(stock.id) \(edit) \(mask)")
                    }
                    if edit.isIdentity {
                        #expect(bits(scene.applying(to: SIMD3(0.2, 0.18, 0.1), baseLog2: -2, sliders: mask, panel: panel))
                            == bits(scene.applying(to: SIMD3(0.2, 0.18, 0.1), baseLog2: -2, sliders: mask, panel: .none)))
                    }
                }
            }
        }
    }

    /// What an evaluation does not need, it does not read: poisoned floats would show. No read of a
    /// zero row at H0 = 0, none of Highlights' or Shadows' tables without a mask's slider, and none of
    /// Whites' or Blacks' once the stretch has taken over.
    @Test func anEvaluationReadsOnlyWhatItNeeds() throws {
        typealias L = LocalScene.Layout
        let stock = ToyStock.make(), reference: Float = 0.5
        let clean = LocalScene(referenceStops: reference, stock: stock, settings: DevelopSettings())
        func poisoned(_ ranges: [Range<Int>]) -> LocalScene {
            var floats = clean.tables
            for range in ranges { for i in range { floats[i] = .nan } }
            return LocalScene(clean, tables: floats)
        }
        func whole(_ table: LocalScene.Table) -> Range<Int> { table.offset..<(table.offset + L.tableFloats) }
        func zeroKnot(_ table: LocalScene.Table) -> Range<Int> { (table.offset + (L.knots / 2) * L.samples)..<(table.offset + (L.knots / 2 + 1) * L.samples) }
        let onlyWhites = try ManualRenderSettings(adjustments: ManualAdjustments(whites: 40), referenceStops: reference)
        let withWhites = try LocalScene.Panel(onlyWhites, tables: try onlyWhites.toneTables(stock: stock, settings: DevelopSettings()))
        let onlyLocal = try ManualRenderSettings(adjustments: ManualAdjustments(highlights: -60, shadows: 20), referenceStops: reference)
        let withLocal = try LocalScene.Panel(onlyLocal, tables: try onlyLocal.toneTables(stock: stock, settings: DevelopSettings()))
        let cases: [(LocalScene, LocalSliders, LocalScene.Panel)] = [
            // H0 = S0 = 0: G(·, 0) unread, with and without a panel, over a mask's value not next to it.
            (poisoned([zeroKnot(.highlights), zeroKnot(.shadows)]), LocalSliders(highlights: -50, shadows: 30), .none),
            (poisoned([zeroKnot(.highlights), zeroKnot(.shadows)]), LocalSliders(highlights: -50, shadows: 30), withWhites),
            // A panel on them and no mask's slider: their tables unread.
            (poisoned([whole(.highlights), whole(.shadows)]), LocalSliders(contrast: 20), withLocal),
            // Past the blend, the stretch alone.
            (poisoned([whole(.whites), whole(.blacks)]), LocalSliders(whites: 50, blacks: -25), .none),
            (poisoned([whole(.whites), whole(.blacks)]), LocalSliders(whites: 25, blacks: -200), .none),
            // Unset controls.
            (poisoned([whole(.contrast), whole(.whites), whole(.blacks)]), LocalSliders(exposureEV: 1, highlights: -20), .none),
        ]
        for (scene, sliders, panel) in cases {
            for x in stride(from: Float(-14), through: 8, by: 0.31) {
                let t = scene.gain(x: x, xb: x - 0.7, sliders: sliders, panel: panel)
                #expect(t == clean.gain(x: x, xb: x - 0.7, sliders: sliders, panel: panel), "\(sliders) at \(x)")
            }
        }
        // And the poison shows where the tables are needed: inside the blend, and at a moved panel.
        let tables = poisoned([whole(.whites)])
        #expect(tables.gain(x: 0, xb: 0, sliders: LocalSliders(whites: 10, blacks: -50), panel: .none).isNaN)
        #expect(poisoned([whole(.highlights)]).gain(x: 0, xb: 0, sliders: LocalSliders(highlights: -10), panel: withLocal).isNaN)
    }

    /// A panel and a mask on Highlights or Shadows: the move along one row, with k's share of the panel's
    /// row fading out, written out; and its four anchors.
    @Test func aPanelAndAMaskMoveAlongOneRow() throws {
        let scale = { (table: LocalScene.Table, value: Float) -> Float in
            table == .highlights
                ? LocalScene.scale(at: value, negative: LightroomLocalToneTargets.highlightsScaleNegative, positive: LightroomLocalToneTargets.highlightsScalePositive)
                : LocalScene.scale(at: value, negative: LightroomLocalToneTargets.shadowsScaleNegative, positive: LightroomLocalToneTargets.shadowsScalePositive)
        }
        for stock in try sceneStocks() {
            let reference: Float = 0.5
            let scene = LocalScene(referenceStops: reference, stock: stock, settings: DevelopSettings())
            let o = scene.referenceOffset
            for (h0, s0, e0) in [(Float(-50), Float(0), Float(0)), (0, 40, 1.5), (-100, 60, -1.5), (25, -25, 0.5)] {
                let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: e0, highlights: h0, shadows: s0), referenceStops: reference)
                let tables = try #require(try manual.toneTables(stock: stock, settings: DevelopSettings()))
                let panel = try LocalScene.Panel(manual, tables: tables)
                for (sH, sS) in [(Float(-30), Float(0)), (0, 45), (-60, 70), (80, -120), (-1e-3, 1e-3)] {
                    for x in stride(from: Float(-12), through: 6, by: 0.53) {
                        let xb = x - 0.4, ub = xb + o
                        var own = tables.value(tables.local, at: ub)
                        if sH != 0 {
                            let moved = scene.gain(.highlights, at: ub, value: h0 + sH)
                            let w = h0 == 0 ? 0 : min(abs(sH) / abs(h0), 1)
                            own += h0 == 0 ? moved : moved - scene.gain(.highlights, at: ub, value: h0) * (1 + w * (1 / scale(.highlights, h0) - 1))
                        }
                        if sS != 0 {
                            let moved = scene.gain(.shadows, at: ub, value: s0 + sS)
                            let w = s0 == 0 ? 0 : min(abs(sS) / abs(s0), 1)
                            own += s0 == 0 ? moved : moved - scene.gain(.shadows, at: ub, value: s0) * (1 + w * (1 / scale(.shadows, s0) - 1))
                        }
                        #expect(scene.gain(x: x, xb: xb, sliders: LocalSliders(highlights: sH, shadows: sS), panel: panel) == own, "\(stock.id) \(h0) \(s0) \(sH) \(sS)")
                    }
                }
            }
            // The anchors, on a knot and away from the shoulder, where the row at P is k(P) times the panel's.
            for (table, value) in [(LocalScene.Table.highlights, Float(-50)), (.highlights, 75), (.shadows, 50), (.shadows, -25)] {
                let edit = table == .highlights ? try ManualAdjustments(highlights: value) : try ManualAdjustments(shadows: value)
                let manual = try ManualRenderSettings(adjustments: edit, referenceStops: reference)
                let tables = try #require(try manual.toneTables(stock: stock, settings: DevelopSettings()))
                let panel = try LocalScene.Panel(manual, tables: tables)
                func t(_ mask: Float) -> [Float] {
                    (0..<512).map { i -> Float in
                        let x = scene.start + Float(i) * scene.step - o
                        return scene.gain(x: x, xb: x, sliders: table == .highlights ? LocalSliders(highlights: mask) : LocalSliders(shadows: mask), panel: panel)
                    }
                }
                let levels = (0..<512).map { scene.start + Float($0) * scene.step }
                let local = levels.map { tables.value(tables.local, at: $0) }
                // s → 0: the panel's table, with no step at the mask's edge.
                #expect(zip(t(value * 1e-5), local).map { abs($0 - $1) }.max()! < 2e-3, "\(stock.id) \(table) \(value): s → 0")
                // s = P: the mask's row at the sum, and s = −P: no gain at all.
                let sum = zip(t(value), levels).map { abs($0 - scene.gain(table, at: $1, value: 2 * value)) }.max()!
                #expect(sum < 1e-4, "\(stock.id) \(table) \(value): at the sum, \(sum)")
                let none = t(-value).map(abs).max()!
                #expect(none < 1e-4, "\(stock.id) \(table) \(value): cancelled, \(none)")
            }
            // It saturates: past ±100 the sum has nowhere to go. k(±100) is 1, so the fade is 0 and the mask adds nothing.
            let manual = try ManualRenderSettings(adjustments: ManualAdjustments(highlights: -100, shadows: 100), referenceStops: reference)
            let tables = try #require(try manual.toneTables(stock: stock, settings: DevelopSettings()))
            let panel = try LocalScene.Panel(manual, tables: tables)
            #expect(panel.highlightsFade == 0 && panel.shadowsFade == 0)
            for x in stride(from: Float(-12), through: 6, by: 0.53) {
                #expect(scene.gain(x: x, xb: x, sliders: LocalSliders(highlights: -50, shadows: 200), panel: panel) == tables.value(tables.local, at: x + o))
            }
        }
    }

    /// The fall of `f` over the samples where the base follows the pixel: in L*, read through T̃, and
    /// the least slope. On the samples `f` is piecewise linear, so its samples are its extremes.
    static func fall(_ scene: LocalScene, _ f: [Float]) -> (lightness: Float, slope: Float) {
        var highest = -Float.infinity, worst: Float = 0, slope = Float.infinity
        for i in f.indices {
            highest = max(highest, f[i])
            worst = max(worst, scene.lightness(at: highest) - scene.lightness(at: f[i]))
            if i > 0 { slope = min(slope, (f[i] - f[i - 1]) / scene.step) }
        }
        return (worst, slope)
    }

    /// The worst falls where the base follows the pixel (a smooth sky), in L*: a mask alone on one
    /// control and on both; a panel and a mask on one control at the same sign and opposed; on both
    /// controls; and the form the evaluation replaced, two tables added, at panel −100 and mask −50.
    /// Panels ±7 to ±100 and masks ±7 to ±200, on and off the knots, the measurement's grid.
    static func panelAndMaskFalls(_ stock: Stock) throws -> (alone: Float, aloneBoth: Float, sameSign: Float, opposed: Float, both: Float, added: Float) {
        let sizes: [Float] = [7, 12.5, 19, 25, 33, 37.5, 44, 50, 60, 62.5, 75, 81, 87.5, 93, 100]
        let panels = sizes.flatMap { [-$0, $0] }
        let masks = (sizes + [150, 200]).flatMap { [-$0, $0] }
        let reference: Float = 0, settings = DevelopSettings()
        let scene = LocalScene(referenceStops: reference, stock: stock, settings: settings)
        let o = scene.referenceOffset
        let xs = (0..<512).map { scene.start + Float($0) * scene.step - o }
        func worst(_ sliders: LocalSliders, _ panel: LocalScene.Panel) -> Float {
            fall(scene, xs.map { $0 + o + scene.gain(x: $0, xb: $0, sliders: sliders, panel: panel) }).lightness
        }
        var result: (alone: Float, aloneBoth: Float, sameSign: Float, opposed: Float, both: Float, added: Float) = (0, 0, 0, 0, 0, 0)
        for mask in masks {
            result.alone = max(result.alone, worst(LocalSliders(highlights: mask), .none), worst(LocalSliders(shadows: mask), .none))
        }
        for table in [LocalScene.Table.highlights, .shadows] {
            for value in panels {
                let edit = table == .highlights ? try ManualAdjustments(highlights: value) : try ManualAdjustments(shadows: value)
                let manual = try ManualRenderSettings(adjustments: edit, referenceStops: reference)
                let panel = try LocalScene.Panel(manual, tables: try manual.toneTables(stock: stock, settings: settings))
                for mask in masks {
                    let fell = worst(table == .highlights ? LocalSliders(highlights: mask) : LocalSliders(shadows: mask), panel)
                    if value * mask > 0 { result.sameSign = max(result.sameSign, fell) } else { result.opposed = max(result.opposed, fell) }
                }
            }
        }
        let values: [Float] = [-100, -50, -25, 25, 50, 100]
        for h0 in [0] + values {
            for s0 in [0] + values {
                let panel: LocalScene.Panel
                if h0 == 0 && s0 == 0 {
                    panel = .none
                } else {
                    let manual = try ManualRenderSettings(adjustments: ManualAdjustments(highlights: h0, shadows: s0), referenceStops: reference)
                    panel = try LocalScene.Panel(manual, tables: try manual.toneTables(stock: stock, settings: settings))
                }
                for sH in values {
                    for sS in values {
                        let fell = worst(LocalSliders(highlights: sH, shadows: sS), panel)
                        if h0 == 0 && s0 == 0 { result.aloneBoth = max(result.aloneBoth, fell) } else { result.both = max(result.both, fell) }
                    }
                }
            }
        }
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(highlights: -100), referenceStops: reference)
        let tables = try #require(try manual.toneTables(stock: stock, settings: settings))
        result.added = fall(scene, xs.map { $0 + o + tables.value(tables.local, at: $0 + o) + scene.gain(.highlights, at: $0 + o, value: -50) }).lightness
        return result
    }

    /// The toy and each baked stock, a test case each, since they run side by side.
    static let orderStocks: [URL?] = [nil] + LightCompilerBaselineTests.bakedStocks

    /// Order where the base follows the pixel. The form this replaced falls by up to 4.8 L* here on
    /// Portra 160. This one cannot be held to no fall at all, and these are the bounds it must be
    /// allowed, measured over the grid above, for two reasons:
    /// - A mask's row is the panel's times k > 1, which the gate fixes, and k can tip a slope that was
    ///   nearly flat just below zero. On one control under 0.03 L*. On both, where two rows' slopes add
    ///   on one stock's shoulder, under 0.3.
    /// - Off the knots a row is interpolated between its neighbours, so the row at the panel's value
    ///   over k is not exactly the panel's table, and the difference stays behind once the fade has
    ///   run. Under 0.55 L*, the worst on one stock's shoulder at a small panel value.
    @Test(arguments: orderStocks)
    func thePanelAndAMaskKeepOrderWhereTheBaseFollowsThePixel(url: URL?) throws {
        let stock = try url.map { try Stock.load(from: $0) } ?? LightCompilerBaselineTests.toyStock()
        let falls = try Self.panelAndMaskFalls(stock)
        #expect(falls.alone < 0.03, "\(stock.id): \(falls)")
        #expect(falls.aloneBoth < 0.3, "\(stock.id): \(falls)")
        #expect(falls.sameSign < 0.55 && falls.opposed < 0.55 && falls.both < 0.55, "\(stock.id): \(falls)")
        // The test's teeth: the form it replaced falls this far on the Portras.
        if stock.id.hasPrefix("kodak-portra") { #expect(falls.added > 3, "\(stock.id): \(falls)") }
    }

    /// The blend, written out: the two tables in sequence while the smaller slider is under 25, the
    /// stretch at 25 and past it, and either end meets the path beside it.
    @Test func whitesWithBlacksBlendFromTheTablesToTheStretch() throws {
        func smoothstep(_ v: Float) -> Float { let u = min(max(v / 25, 0), 1); return u * u * (3 - 2 * u) }
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0.4, stock: stock, settings: DevelopSettings())
            for x in stride(from: Float(-10), through: 6, by: 0.37) {
                let level = x + scene.referenceOffset
                for (w, b) in [(Float(10), Float(-50)), (50, -10), (-5, -80), (24.99, -24.99), (12.5, -12.5)] {
                    let joint = scene.stretchGain(at: level, whites: w, blacks: b)
                    let first = scene.gain(.whites, at: level, value: w)
                    let sequence = first + scene.gain(.blacks, at: level + first, value: b)
                    let own = sequence + (joint - sequence) * smoothstep(min(abs(w), abs(b)))
                    #expect(abs(scene.gain(x: x, xb: x, sliders: LocalSliders(whites: w, blacks: b), panel: .none) - own) < 1e-5, "\(stock.id) \(w) \(b)")
                }
                for (w, b) in [(Float(25), Float(-25)), (25, -200), (-100, -25), (200, -60)] {
                    #expect(scene.gain(x: x, xb: x, sliders: LocalSliders(whites: w, blacks: b), panel: .none) == scene.stretchGain(at: level, whites: w, blacks: b), "\(stock.id) \(w) \(b)")
                }
                // At the ends: Whites or Blacks all but gone is the other's table, and just under 25 the stretch.
                let tiny: Float = 1e-3
                #expect(abs(scene.gain(x: x, xb: x, sliders: LocalSliders(whites: tiny, blacks: -80), panel: .none) - scene.gain(.blacks, at: level, value: -80)) < 1e-3)
                #expect(abs(scene.gain(x: x, xb: x, sliders: LocalSliders(whites: 80, blacks: -tiny), panel: .none) - scene.gain(.whites, at: level, value: 80)) < 1e-3)
                #expect(abs(scene.gain(x: x, xb: x, sliders: LocalSliders(whites: 24.999, blacks: -60), panel: .none) - scene.stretchGain(at: level, whites: 25, blacks: -60)) < 2e-3)
            }
        }
    }

    /// The largest step between neighbouring rows of an overlap ramp, the chart's own (every row the
    /// same ramp, 300 rows): Whites +100 on a gradient over 0.1 to 0.7 of the frame, Blacks −100 on one
    /// over 0.9 to 0.3, with the measured linear profile. `hard` is the earlier law, the stretch from
    /// the first nonzero slider: it steps by more than 2 L* on a line across the frame.
    static func largestRowStep(_ scene: LocalScene, hard: Bool) -> Float {
        func cosine(_ t: Float) -> Float {
            let u = min(max((t + 0.046) / (0.971 + 0.046), 0), 1)
            return 1 - (1 - cos(Float.pi * u)) / 2
        }
        let levels = stride(from: Float(3), through: 97, by: 1).map { scene.stops(atLightness: $0) }
        var previous: [Float] = [], worst: Float = 0
        for row in 0..<300 {
            let y = (Float(row) + 0.5) / 300
            let w = 100 * cosine((y - 0.1) / 0.6), b = -100 * cosine((y - 0.9) / -0.6)
            let current = levels.map { level -> Float in
                let t: Float
                if hard && w != 0 && b < 0 {
                    t = scene.stretchGain(at: level, whites: w, blacks: b)
                } else {
                    t = scene.gain(x: level - scene.referenceOffset, xb: level - scene.referenceOffset, sliders: LocalSliders(whites: w, blacks: b), panel: .none)
                }
                return scene.lightness(at: level + t)
            }
            if !previous.isEmpty { worst = max(worst, zip(current, previous).map { abs($0 - $1) }.max()!) }
            previous = current
        }
        return worst
    }

    /// Where one mask's Whites or Blacks runs out under another's, there is no line. Lightroom's own
    /// render of this overlap steps 0.35 L* at most.
    @Test func anOverlapOfWhitesAndBlacksHasNoSeam() throws {
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0, stock: stock, settings: DevelopSettings())
            let step = Self.largestRowStep(scene, hard: false)
            #expect(step < 0.8, "\(stock.id): \(step) L*")
            if stock.id != LightCompilerBaselineTests.toyStock().id {
                #expect(Self.largestRowStep(scene, hard: true) > 1.5, "\(stock.id): the earlier law should show the seam")
            }
        }
    }

    /// Slope of the pixel map for one stack, over the levels at a fixed base: the worst and where.
    static func worstSlope(_ scene: LocalScene, sliders: LocalSliders, xb: Float, count: Int = 400) -> Float {
        let low = scene.start + 1 - scene.referenceOffset, high = scene.start + 20 - scene.referenceOffset
        let step = (high - low) / Float(count - 1)
        var worst = Float.infinity
        var previous = low + scene.gain(x: low, xb: xb, sliders: sliders, panel: .none)
        for i in 1..<count {
            let x = low + Float(i) * step
            let mapped = x + scene.gain(x: x, xb: xb, sliders: sliders, panel: .none)
            worst = min(worst, (mapped - previous) / step)
            previous = mapped
        }
        return worst
    }

    /// Random stacks of 1, 3, 8 and 16 masks (L1c's recipe: coverage 0.2 to 1, each tone control
    /// present half the time at ±25 to ±100, here with Amount to 2): nothing reverses, and a stack of
    /// sixteen flattens no more than the tables' own floor allows. The summed slider is clamped to
    /// its axis, so the worst any number of masks can reach is one corner of the axes.
    @Test func luminanceOrderHoldsAndDoesNotWeakenWithTheNumberOfMasks() throws {
        for stock in try sceneStocks() {
            let scene = LocalScene(referenceStops: 0, stock: stock, settings: DevelopSettings())
            // Every corner of the axes: the floor a sum can reach, whatever the stack.
            var floor = Float.infinity
            for c: Float in [-200, 0, 200] {
                for w: Float in [-200, 0, 200] {
                    for b: Float in [-200, 0, 200] {
                        for h: Float in [-100, 0, 100] {
                            floor = min(floor, Self.worstSlope(scene, sliders: LocalSliders(contrast: c, highlights: h, shadows: -h, whites: w, blacks: b), xb: 0))
                        }
                    }
                }
            }
            #expect(floor > 0, "\(stock.id) flattest corner \(floor)")
            var random = SplitMix64(state: 20261106)
            let values: [Float] = [-100, -75, -50, -25, 25, 50, 75, 100]
            var medians: [Float] = []
            for n in [1, 3, 8, 16] {
                var worsts: [Float] = []
                for _ in 0..<60 {
                    var sum = LocalSliders()
                    for _ in 0..<n {
                        let pick = { (_: Int) -> Float in Bool.random(using: &random) ? values[Int.random(in: 0..<8, using: &random)] : 0 }
                        let mask = LocalSliders(contrast: pick(0), highlights: pick(1), shadows: pick(2), whites: pick(3), blacks: pick(4))
                        sum.add(mask, coverage: Float.random(in: 0.2...1, using: &random), amount: Float.random(in: 0.5...2, using: &random))
                    }
                    worsts.append(Self.worstSlope(scene, sliders: sum, xb: 0))
                }
                let smallest = worsts.min()!
                #expect(smallest > 0, "\(stock.id) \(n) masks: smallest slope \(smallest)")
                // Interpolating between rows is a convex mix of slopes, so no sum goes below the
                // worst corner by more than the sampling of the level axis allows.
                #expect(smallest > floor * 0.5, "\(stock.id) \(n) masks: \(smallest) against the corners' \(floor)")
                medians.append(worsts.sorted()[worsts.count / 2])
            }
            // No compounding: the median of the worst slopes stops falling once sums reach the axes'
            // ends; R5's composition fell by a factor of 100 from one mask to sixteen.
            #expect(medians[3] > medians[2] * 0.5, "\(stock.id) medians \(medians)")
            #expect(medians[3] > medians[1] * 0.25, "\(stock.id) medians \(medians)")
        }
    }

    /// In a large smooth area the base follows the pixel, so Highlights' and Shadows' own tables shape
    /// the map. The panel's keep it rising (their targets' slope floor); times k > 1 a row can dip a
    /// little where the floor was nearly met. Measured, and held here: at most a slope of −0.06 over at
    /// most 0.02 stops. At ±100, the panel itself, it never dips.
    @Test func highlightsAndShadowsBarelyLoseOrderInASmoothArea() throws {
        for stock in try sceneStocks() {
            for settings in sceneSettings {
                let scene = LocalScene(referenceStops: 0, stock: stock, settings: settings)
                for table in [LocalScene.Table.highlights, .shadows] {
                    for knot in 0..<LocalScene.Layout.knots {
                        let row = Array(scene.tables[(table.offset + knot * 512)..<(table.offset + (knot + 1) * 512)])
                        var highest = -Float.infinity, depth: Float = 0, least = Float.infinity
                        for i in 0..<512 {
                            let mapped = scene.start + Float(i) * scene.step + row[i]
                            highest = max(highest, mapped)
                            depth = max(depth, highest - mapped)
                            if i > 0 { least = min(least, (scene.step + row[i] - row[i - 1]) / scene.step) }
                        }
                        #expect(least > -0.06 && depth < 0.02, "\(stock.id) \(table) knot \(knot): slope \(least), depth \(depth) stops")
                        if knot == 0 || knot == LocalScene.Layout.knots - 1 { #expect(least > 0, "\(stock.id) \(table) at ±100: \(least)") }
                    }
                }
            }
        }
    }
}

/// Writes the tables and a few thousand evaluations for `score_local_scene.py` beside the task's
/// evidence, and times the build. Runs only with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 ARGENT_OUT=DIR swift test --filter LocalSceneMeasureTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"))
struct LocalSceneMeasureTests {
    @Test func export() throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARGENT_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var index: [[String: Any]] = []
        for url in LightCompilerBaselineTests.bakedStocks {
            let stock = try Stock.load(from: url)
            for (name, settings, reference) in [("default", DevelopSettings(), Float(0)), ("pushed", DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3), Float(0.75))] {
                let scene = LocalScene(referenceStops: reference, stock: stock, settings: settings)
                let stem = "\(stock.id)-\(name)"
                try scene.tables.withUnsafeBytes { try Data($0).write(to: out.appendingPathComponent("\(stem).tables.f32")) }
                // Evaluations: random pixels and sums, half the sums on knots.
                var random = SplitMix64(state: 20261106)
                var rows: [Float] = []
                for i in 0..<4000 {
                    let onKnot = i % 2 == 0
                    let value = { (end: Float, spacing: Float) -> Float in
                        if Int.random(in: 0..<3, using: &random) == 0 { return 0 }
                        return onKnot ? Float(Int.random(in: -8...8, using: &random)) * spacing : Float.random(in: -1.1...1.1, using: &random) * end
                    }
                    let s = LocalSliders(exposureEV: Float.random(in: -3...3, using: &random), contrast: value(200, 25), highlights: value(100, 12.5),
                                         shadows: value(100, 12.5), whites: value(200, 25), blacks: value(200, 25))
                    let x = Float.random(in: -16...10, using: &random), xb = x + Float.random(in: -3...3, using: &random)
                    // A third with a panel on Highlights and Shadows, on the new compiler's offset.
                    let h0: Float = i % 3 == 0 ? [-100, -50, 25, 50, 100, -33][i % 6 == 0 ? (i / 6) % 6 : (i / 3) % 6] : 0
                    let s0: Float = i % 3 == 0 ? [50, -25, 100, 0, -100, 19][(i / 3) % 6] : 0
                    let panel: LocalScene.Panel
                    if h0 != 0 || s0 != 0 {
                        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(highlights: h0, shadows: s0), referenceStops: reference)
                        panel = try LocalScene.Panel(manual, tables: try manual.toneTables(stock: stock, settings: settings))
                    } else {
                        panel = .none
                    }
                    rows += [x, xb, s.exposureEV, s.contrast, s.highlights, s.shadows, s.whites, s.blacks, h0, s0, scene.gain(x: x, xb: xb, sliders: s, panel: panel)]
                }
                try rows.withUnsafeBytes { try Data($0).write(to: out.appendingPathComponent("\(stem).evaluations.f32")) }
                let manual = try ManualRenderSettings(adjustments: ManualAdjustments(contrast: 1), referenceStops: reference)
                let panel = try #require(try manual.toneTables(stock: stock, settings: settings))
                index.append(["stock": stock.id, "name": name, "stem": stem, "start": scene.start, "step": scene.step, "referenceStops": reference, "transfer": panel.transfer])
            }
        }
        try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted]).write(to: out.appendingPathComponent("index.json"))
    }

    /// Table build time and bytes, and the two tolerances' measured sizes. Timings taken beside other
    /// builds mean little, so this reports the minimum of 40. Run it with `-c release -Xswiftc -enable-testing`.
    @Test func buildTime() throws {
        var lines: [String] = []
        for url in LightCompilerBaselineTests.bakedStocks {
            let stock = try Stock.load(from: url)
            var best = Double.infinity
            var bytes = 0
            for _ in 0..<40 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let scene = LocalScene(referenceStops: 0.4, stock: stock, settings: DevelopSettings())
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) * 1e-6)
                bytes = scene.byteCount
            }
            let between = try LocalSceneEvaluationTests.betweenKnots(stock)
            lines.append("\(stock.id): \(String(format: "%.2f", best)) ms, \(bytes) bytes; between knots worst rms \(between.rms), worst level \(between.level) L*; "
                + "another order \(LocalSceneEvaluationTests.worstOfAnotherOrder(stock)) stops; falls \(try LocalSceneEvaluationTests.panelAndMaskFalls(stock))")
        }
        print(lines.joined(separator: "\n"))
    }
}
