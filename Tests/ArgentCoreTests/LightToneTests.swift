import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Stocks for the gain-table Light compilers' tests: the toy stock built in code, and each baked stock
/// the checkout has.
private func toneStocks() throws -> [Stock] {
    try [ToyStock.make()] + LightCompilerBaselineTests.bakedStocks.map { try Stock.load(from: $0) }
}

private func current(_ adjustments: ManualAdjustments, reference: Float = 0) throws -> ManualRenderSettings {
    try ManualRenderSettings(adjustments: adjustments, referenceStops: reference)
}

/// The same edit on the compiler before the current one, whose Highlights and Shadows read the base
/// after Exposure.
private func exposedBase(_ adjustments: ManualAdjustments, reference: Float = 0) throws -> ManualRenderSettings {
    try ManualRenderSettings(adjustments: adjustments, referenceStops: reference, version: ManualRenderSettings.exposedBaseVersion)
}

private let gainTableVersions = [ManualRenderSettings.currentVersion, ManualRenderSettings.exposedBaseVersion]

private func half(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(Float(Float16(rgb.x)), Float(Float16(rgb.y)), Float(Float16(rgb.z)))
}

/// One control at a value, the others zero.
private func single(_ control: ManualAdjustments.Control, _ value: Float) throws -> ManualAdjustments {
    try ManualAdjustments.identity.setting(control, to: value)
}

@Suite struct LightCompilerVersionTests {
    @Test func newEditsUseTheCurrentCompilerAndRecordedOnesKeepTheirs() throws {
        #expect(ManualRenderSettings.currentVersion == "2026-11-06-1")
        #expect(ManualRenderSettings.exposedBaseVersion == "2026-10-29-1" && ManualRenderSettings.regionsVersion == "2026-10-09-1")
        #expect(["2026-11-06-1", "2026-10-29-1", "2026-10-09-1"].allSatisfy(ManualRenderSettings.supports(version:)))
        #expect(!ManualRenderSettings.supports(version: "future"))
        let values = try ManualAdjustments(exposureEV: 0.5, highlights: -40)
        let new = try current(values, reference: 1)
        let tables = try exposedBase(values, reference: 1)
        let old = try ManualRenderSettings(adjustments: values, referenceStops: 1, version: ManualRenderSettings.regionsVersion)
        #expect(new.version == ManualRenderSettings.currentVersion && old.version == ManualRenderSettings.regionsVersion)
        #expect(tables.version == ManualRenderSettings.exposedBaseVersion)
        for manual in [new, tables, old] {
            let decoded = try JSONDecoder().decode(ManualRenderSettings.self, from: JSONEncoder().encode(manual))
            #expect(decoded == manual && decoded.version == manual.version)
        }
        // Identity is one value whichever compiler recorded it, so a reset releases the pin.
        #expect(try ManualRenderSettings(adjustments: .identity, referenceStops: 1, version: ManualRenderSettings.regionsVersion) == .identity)
        #expect(try exposedBase(.identity, reference: 1) == .identity)
        #expect(RenderGraph.version(for: DevelopSettings(manual: old)) == RenderGraph.version + "+manual-2026-10-09-1")
        #expect(RenderGraph.version(for: DevelopSettings(manual: tables)) == RenderGraph.version + "+manual-2026-10-29-1")
        #expect(RenderGraph.version(for: DevelopSettings(manual: new)) == RenderGraph.version + "+manual-2026-11-06-1")
        #expect(RenderGraph.version(for: DevelopSettings(manual: .identity)) == RenderGraph.version)
    }

    /// Both gain-table compilers go down the tables' path; a missed test here would send recorded edits
    /// down the regions'.
    @Test func onlyTheGainTableCompilersToneControlsNeedTablesAndOnlyLocalOnesTheBase() throws {
        for version in gainTableVersions {
            func edit(_ values: ManualAdjustments) throws -> ManualRenderSettings {
                try ManualRenderSettings(adjustments: values, referenceStops: 0, version: version)
            }
            #expect(!(try edit(ManualAdjustments(exposureEV: 2))).needsToneTables)
            #expect(try edit(single(.whites, 10)).needsToneTables && !(try edit(single(.whites, 10))).needsToneBase)
            #expect(try edit(single(.shadows, -10)).needsToneBase)
            let highlights = try edit(single(.highlights, -10))
            #expect(try highlights.parameters.sceneTables == 1 && highlights.toneTables(stock: ToyStock.make(), settings: DevelopSettings()) != nil)
        }
        let old = try ManualRenderSettings(adjustments: single(.highlights, 50), referenceStops: 0, version: ManualRenderSettings.regionsVersion)
        #expect(!old.needsToneTables && !old.needsToneBase)
        #expect(try old.toneTables(stock: ToyStock.make(), settings: DevelopSettings()) == nil)
        #expect(try old.parameters.sceneTables == 0)
        #expect(MemoryLayout<ManualCurveParameters>.stride == 68)
    }

    /// The local table's read: before Exposure on the current compiler, after it, with the global
    /// table's, on the one before. With Exposure at 0 they are the same bits.
    @Test func theLocalTableReadsTheBaseBeforeExposureOnTheCurrentCompilerOnly() throws {
        for reference: Float in [0, 0.6, -2.5] {
            for exposure: Float in [-3, -0.5, 0, 1, 5] {
                let values = try ManualAdjustments(exposureEV: exposure, contrast: 20, highlights: -50)
                let new = try current(values, reference: reference).parameters, old = try exposedBase(values, reference: reference).parameters
                #expect(new.baseOffset == reference - log2(Float(0.18)))
                #expect(new.guideOffset == exposure + reference - log2(Float(0.18)))
                #expect(old.guideOffset == new.guideOffset && old.baseOffset == old.guideOffset)
                #expect((new.baseOffset == old.baseOffset) == (exposure == 0))
                if exposure == 0 { #expect(new.baseOffset.bitPattern == old.baseOffset.bitPattern) }
            }
        }
    }
}

@Suite struct LightToneTableTests {
    @Test func targetsAreLinearInValueAndShapePreservingInLightness() throws {
        let rows = LightroomToneTargets.highlights
        #expect(ManualToneTables.Target(rows, value: 0) == nil)
        for (row, value) in LightroomToneTargets.values.enumerated() {
            let target = try #require(ManualToneTables.Target(rows, value: value))
            for (column, lightness) in LightroomToneTargets.lightness.enumerated() {
                #expect(abs(target.change(at: lightness) - rows[row][column]) < 1e-5)
            }
        }
        // Halfway to the implicit zero row, and halfway between two measured rows.
        let lowest = try #require(LightroomToneTargets.values.firstIndex { $0 > 0 })
        let small = try #require(ManualToneTables.Target(rows, value: LightroomToneTargets.values[lowest] / 2))
        let between = try #require(ManualToneTables.Target(rows, value: (LightroomToneTargets.values[lowest]
            + LightroomToneTargets.values[lowest + 1]) / 2))
        for (column, lightness) in LightroomToneTargets.lightness.enumerated() {
            #expect(abs(small.change(at: lightness) - rows[lowest][column] / 2) < 1e-5)
            #expect(abs(between.change(at: lightness) - (rows[lowest][column] + rows[lowest + 1][column]) / 2) < 1e-5)
        }
        // No overshoot between columns, and constant beyond the ends.
        for table in [LightroomToneTargets.contrast, LightroomToneTargets.highlights, LightroomToneTargets.shadows,
                      LightroomToneTargets.whites, LightroomToneTargets.blacks] {
            for value in LightroomToneTargets.values {
                let target = try #require(ManualToneTables.Target(table, value: value))
                let l = LightroomToneTargets.lightness, c = target.change
                for i in 0..<(l.count - 1) {
                    for k in 1..<8 {
                        let v = target.change(at: l[i] + (l[i + 1] - l[i]) * Float(k) / 8)
                        #expect(v >= min(c[i], c[i + 1]) - 1e-4 && v <= max(c[i], c[i + 1]) + 1e-4)
                    }
                }
                #expect(target.change(at: -20) == c[0] && target.change(at: 130) == c[c.count - 1])
            }
        }
        #expect(LightroomToneTargets.lightness.first == 0 && LightroomToneTargets.lightness.last == 100)
    }

    /// T̃ is T, in the print's own lightness, wherever T rises at least the minimum slope, and its
    /// inverse returns the stops it came from there and everywhere else.
    @Test func theTransferInvertsWhereTheFilmSeparatesTones() throws {
        for stock in try toneStocks() {
            for settings in [DevelopSettings(), DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.2, -0.1, 0.05), printExposure: -0.6)] {
                let manual = try current(ManualAdjustments(contrast: 30), reference: 0.8)
                let tables = try #require(try manual.toneTables(stock: stock, settings: settings))
                let t = tables.transfer, black = t[0], span = max(t[t.count - 1] - black, 1)
                let own = t.map { 100 * ($0 - black) / span }
                var exact = 0
                for i in own.indices {
                    let x = tables.start + Float(i) * tables.step
                    let back = ManualToneTables.inverse(tables.regularized[i], regularized: tables.regularized,
                                                        start: tables.start, step: tables.step)
                    #expect(abs(back - x) < 2e-3, "\(stock.id) sample \(i)")
                    if i > 0 { #expect(tables.regularized[i] > tables.regularized[i - 1], "\(stock.id): T̃ rises at sample \(i)") }
                    if abs(tables.regularized[i] - own[i]) < 1e-3 { exact += 1 }
                }
                // The film separates tones over several stops; T̃ is exact across them.
                #expect(Float(exact) * tables.step > 3, "\(stock.id): \(Float(exact) * tables.step) stops exact")
            }
        }
    }

    /// The lightness a neutral flat area gets: its own base, so `xb = x`.
    private func flatLightness(_ manual: ManualRenderSettings, tables: ManualToneTables, x: Float) throws -> (before: Float, after: Float) {
        let gray = 0.18 * exp2(x - manual.referenceStops - manual.adjustments.exposureEV)
        let rgb = SIMD3<Float>(repeating: gray)
        let mapped = try manual.applyingScene(to: rgb, baseLog2: ManualRenderSettings.guideLog2(rgb), tables: tables)
        let after = log2(ManualRenderSettings.luminance(mapped) / (0.18 * exp2(-manual.referenceStops)))
        return (tables.value(tables.transfer, at: x), tables.value(tables.transfer, at: after))
    }

    /// Where the film separates tones and no gain is limited, each control alone moves a flat
    /// neutral area's lightness, in the print's own scale, by its target.
    @Test func eachControlMeetsItsTargetWhereTheFilmSeparatesTones() throws {
        for stock in try toneStocks() {
            for control in [ManualAdjustments.Control.contrast, .highlights, .shadows, .whites, .blacks] {
                for value: Float in [-100, -50, 30, 100] {
                    let manual = try current(single(control, value), reference: 0.4)
                    let tables = try #require(try manual.toneTables(stock: stock, settings: DevelopSettings()))
                    let rows = switch control {
                    case .contrast: LightroomToneTargets.contrast
                    case .highlights: LightroomToneTargets.highlights
                    case .shadows: LightroomToneTargets.shadows
                    case .whites: LightroomToneTargets.whites
                    default: LightroomToneTargets.blacks
                    }
                    let target = try #require(ManualToneTables.Target(rows, value: value))
                    let t = tables.transfer, black = t[0], span = max(t[t.count - 1] - black, 1)
                    let own = t.map { 100 * ($0 - black) / span }
                    func exact(_ x: Float) -> Bool {
                        let i = Int(((x - tables.start) / tables.step).rounded(.down))
                        guard i >= 1, i + 2 < own.count else { return false }
                        return (i - 1...i + 2).allSatisfy { abs(tables.regularized[$0] - own[$0]) < 1e-3 }
                    }
                    // Where a measured row dips, the monotone floor, not the target, sets the aim.
                    var floored = [Bool](repeating: false, count: own.count), previous = -Float.infinity
                    for i in own.indices {
                        let r = tables.regularized[i], aim = r + target.change(at: r)
                        let floor = i == 0 ? aim : previous + ManualToneTables.minimumTargetSlope * (r - tables.regularized[i - 1])
                        floored[i] = floor > aim
                        previous = max(aim, floor)
                    }
                    var checked = 0
                    for i in own.indices where (10...90).contains(own[i]) && !floored[i] {
                        let x = tables.start + Float(i) * tables.step
                        let gain = tables.value(tables.local, at: x) + tables.value(tables.global, at: x + tables.value(tables.local, at: x))
                        guard abs(gain) < ManualToneTables.gainKnee, exact(x), exact(x + gain) else { continue }
                        let (before, after) = try flatLightness(manual, tables: tables, x: x)
                        let expected = own[i] + target.change(at: own[i])
                        let reached = 100 * (after - black) / span
                        #expect(abs(reached - expected) < 0.35, "\(stock.id) \(control) \(value) at L* \(before)")
                        checked += 1
                    }
                    #expect(checked > 20, "\(stock.id) \(control) \(value): \(checked) samples checked")
                }
            }
        }
    }

    /// On the neutral axis: Highlights leaves the print below about L* 40 nearly alone, Shadows
    /// above about L* 70, and Contrast turns about its pivot.
    @Test func eachControlActsInItsLightnessRegion() throws {
        for stock in try LightCompilerBaselineTests.bakedStocks.map({ try Stock.load(from: $0) }) {
            func effect(_ control: ManualAdjustments.Control, _ value: Float) throws -> [(lightness: Float, change: Float)] {
                let manual = try current(single(control, value), reference: 0)
                let tables = try #require(try manual.toneTables(stock: stock, settings: DevelopSettings()))
                return try stride(from: Float(-6), through: 5, by: 0.05).map { x in
                    let (before, after) = try flatLightness(manual, tables: tables, x: x)
                    return (before, after - before)
                }
            }
            for value: Float in [-100, 100] {
                let highlights = try effect(.highlights, value)
                let peak = highlights.map { abs($0.change) }.max() ?? 0
                let below = highlights.filter { $0.lightness < 35 }.map { abs($0.change) }.max() ?? 0
                #expect(peak > 2 && below <= 0.2 * peak, "\(stock.id) Highlights \(value): \(below) below L* 35, peak \(peak)")
                let lights = highlights.filter { $0.lightness > 60 && $0.lightness < 95 }.map(\.change)
                #expect(lights.reduce(0, +) * value > 0, "\(stock.id) Highlights \(value) moves the lights its way")

                let shadows = try effect(.shadows, value)
                let shadowPeak = shadows.map { abs($0.change) }.max() ?? 0
                let above = shadows.filter { $0.lightness > 75 }.map { abs($0.change) }.max() ?? 0
                #expect(shadowPeak > 2 && above <= 0.2 * shadowPeak, "\(stock.id) Shadows \(value): \(above) above L* 75, peak \(shadowPeak)")
                let darks = shadows.filter { $0.lightness > 10 && $0.lightness < 40 }.map(\.change)
                #expect(darks.reduce(0, +) * value > 0, "\(stock.id) Shadows \(value) moves the darks its way")

                let contrast = try effect(.contrast, value)
                let sign: Float = value > 0 ? 1 : -1
                #expect(contrast.filter { (15...30).contains($0.lightness) }.allSatisfy { $0.change * sign < 0 },
                        "\(stock.id) Contrast \(value) darkens or lifts the darks")
                #expect(contrast.filter { (65...85).contains($0.lightness) }.allSatisfy { $0.change * sign > 0 },
                        "\(stock.id) Contrast \(value) lifts or lowers the lights")
                let middle = contrast.filter { (10...90).contains($0.lightness) }
                let crossing = zip(middle, middle.dropFirst()).first { ($0.change * sign < 0) && ($1.change * sign >= 0) }
                let pivot = try #require(crossing).1.lightness
                #expect((35...60).contains(pivot), "\(stock.id) Contrast \(value) pivots at L* \(pivot)")
            }
        }
    }

    /// For a fixed base the map keeps luminance order, over the whole range and every combination
    /// of extremes, and neither signed, near-zero nor the largest half-float input leaves it finite.
    @Test func theMapRisesWithLightForAFixedBaseAndStaysFinite() throws {
        // Every control alone at either extreme, and every combination of extremes.
        let corners = (0..<32).map { mask in (0..<5).map { mask & (1 << $0) == 0 ? Float(-100) : 100 } }
        let alone = (0..<10).map { i in (0..<5).map { $0 == i / 2 ? (i % 2 == 0 ? Float(-100) : 100) : 0 } }
        let ramp = ([Float(0), 1e-12, 1e-9, 1e-7] + (0...220).map { 0.18 * exp2(-24 + Float($0) / 7.5) } + [65504, 1e8]).sorted()
        for stock in try toneStocks() {
            for (index, v) in (corners + alone).enumerated() {
                do {
                    let (contrast, highlights, shadows, whites, blacks) = (v[0], v[1], v[2], v[3], v[4])
                    let manual = try current(ManualAdjustments(exposureEV: index % 2 == 0 ? 3 : -3, contrast: contrast, highlights: highlights,
                        shadows: shadows, whites: whites, blacks: blacks), reference: index % 3 == 0 ? 2.5 : -2.5)
                    let tables = try #require(try manual.toneTables(stock: stock, settings: DevelopSettings(ratedAt: 800)))
                    for base: Float in [-30, -3, 1, 20] {
                        var previous = -Float.infinity
                        for value in ramp {
                            let mapped = try manual.applyingScene(to: SIMD3(repeating: value), baseLog2: base, tables: tables)
                            let luminance = ManualRenderSettings.luminance(mapped)
                            #expect(luminance.isFinite && luminance >= previous,
                                    "\(stock.id) C\(contrast) H\(highlights) S\(shadows) W\(whites) B\(blacks) base \(base) at \(value)")
                            previous = luminance
                        }
                    }
                    for patch: SIMD3<Float> in [.zero, SIMD3(-0.2, 0.5, 1.4), SIMD3(1.2, -0.1, 0.03), SIMD3(-1, -0.5, 0.2),
                                                SIMD3(-0.6780, 0.2627, 0), SIMD3(repeating: 1e-10), SIMD3(repeating: 65504)] {
                        let mapped = try manual.applyingScene(to: patch, baseLog2: ManualRenderSettings.guideLog2(patch), tables: tables)
                        #expect((0..<3).allSatisfy { mapped[$0].isFinite })
                        if patch.y != 0 { #expect(abs(mapped.x / mapped.y - patch.x / patch.y) < 1e-5) }
                    }
                }
            }
        }
    }

    /// On the current compiler Exposure does not move the local gain: a pixel gets what its base gets
    /// at Exposure 0. On the compiler before it the same table is read Exposure further along. The global
    /// table reads the pixel's light after Exposure and the local gain on both.
    @Test func theLocalGainDoesNotMoveWithExposureOnTheCurrentCompiler() throws {
        let rgb = SIMD3<Float>(0.09, 0.2, 0.31)
        let settings = DevelopSettings(ratedAt: 200, printExposure: 0.2)
        for stock in try toneStocks() {
            for reference: Float in [0.6, -0.4] {
                let toneValues = try ManualAdjustments(highlights: -100, shadows: 60)
                let tables = try #require(try current(toneValues, reference: reference).toneTables(stock: stock, settings: settings))
                let both = try ManualAdjustments(contrast: 35, highlights: -100, shadows: 60, whites: 25)
                let allTables = try #require(try current(both, reference: reference).toneTables(stock: stock, settings: settings))
                let o = reference - log2(Float(0.18))
                var moved = 0
                for exposure: Float in [-1.5, -1, -0.5, 0.5, 1, 1.5] {
                    let values = try toneValues.setting(.exposure, to: exposure), withGlobal = try both.setting(.exposure, to: exposure)
                    let exposed = rgb * exp2(exposure)
                    for base in stride(from: Float(-9), through: 3, by: 0.5) {
                        let still = tables.value(tables.local, at: base + o), along = tables.value(tables.local, at: base + (exposure + reference - log2(Float(0.18))))
                        #expect(try current(values, reference: reference).applyingScene(to: rgb, baseLog2: base, tables: tables) == exposed * exp2(still))
                        #expect(try exposedBase(values, reference: reference).applyingScene(to: rgb, baseLog2: base, tables: tables) == exposed * exp2(along))
                        if still != along { moved += 1 }

                        let local = allTables.value(allTables.local, at: base + o)
                        let global = allTables.value(allTables.global, at: ManualRenderSettings.guideLog2(rgb) + (exposure + reference - log2(Float(0.18))) + local)
                        #expect(try current(withGlobal, reference: reference).applyingScene(to: rgb, baseLog2: base, tables: allTables) == exposed * exp2(local + global))
                    }
                }
                #expect(moved > 100, "\(stock.id): the older read differs at \(moved) of 300 bases")
            }
        }
    }

    @Test func zeroValuesBypassAndExposureAloneIsTheScenesGainUnderEveryCompiler() throws {
        let pixels: [SIMD3<Float>] = [.zero, SIMD3(-0.4, 0.3, 1.2), SIMD3(1e-9, -1e-9, 0), SIMD3(repeating: 65504)]
        let curvesOnly = try ManualAdjustments(curves: ToneCurves(tone: ToneCurves.Preset.softContrast.curve))
        for version in gainTableVersions + [ManualRenderSettings.regionsVersion] {
            let zero = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: -0.0, contrast: -0.0), referenceStops: 2, version: version)
            let exposure = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 1), referenceStops: -1, version: version)
            let curves = try ManualRenderSettings(adjustments: curvesOnly, referenceStops: 1, version: version)
            for rgb in pixels {
                #expect(try zero.applyingScene(to: rgb, baseLog2: 3, tables: nil) == rgb)
                #expect(try zero.applyingPrint(to: rgb) == rgb)
                #expect(try curves.applyingScene(to: rgb, baseLog2: -2, tables: nil) == rgb)
                #expect(try exposure.applyingScene(to: rgb, baseLog2: 0, tables: nil) == rgb * 2)
                #expect(try exposure.applyingPrint(to: rgb) == rgb)
            }
        }
        // The gain-table compilers map nothing on the print; curves still apply there.
        for version in gainTableVersions {
            let tones = try ManualRenderSettings(adjustments: ManualAdjustments(contrast: 80, whites: -60, blacks: 40, curves: curvesOnly.curves),
                                                 referenceStops: 0, version: version)
            let rgb = SIMD3<Float>(0.1, 0.3, 0.5)
            #expect(try tones.applyingPrint(to: rgb) == (try curvesOnly.curves.compiled().applying(to: rgb)))
        }
    }

    @Test func tablesDependOnTheToneControlsReferenceAndPrintButNotOnExposure() throws {
        let stock = ToyStock.make(), settings = DevelopSettings(ratedAt: 200, printExposure: 0.4)
        let one = try current(ManualAdjustments(exposureEV: -1, contrast: 40, shadows: 20), reference: 0.5)
        let two = try current(ManualAdjustments(exposureEV: 2.5, contrast: 40, shadows: 20), reference: 0.5)
        #expect(try one.toneTables(stock: stock, settings: settings) == (try two.toneTables(stock: stock, settings: settings)))
        let moved = try current(ManualAdjustments(contrast: 40, shadows: 20), reference: 1.5)
        #expect(try one.toneTables(stock: stock, settings: settings) != (try moved.toneTables(stock: stock, settings: settings)))
        #expect(try one.toneTables(stock: stock, settings: settings) != (try one.toneTables(stock: stock, settings: DevelopSettings())))
        let tables = try #require(try one.toneTables(stock: stock, settings: settings))
        #expect(tables.global.count == ManualToneTables.sampleCount && tables.local.count == ManualToneTables.sampleCount)
        #expect(tables.globalActive && tables.localActive)
        #expect(tables.global.allSatisfy { abs($0) <= ManualToneTables.gainLimit } && tables.local.allSatisfy { abs($0) <= ManualToneTables.gainLimit })
        let globalOnly = try #require(try current(single(.whites, 50)).toneTables(stock: stock, settings: settings))
        #expect(!globalOnly.localActive && globalOnly.local.allSatisfy { $0 == 0 })
    }
}

@Suite struct LightToneGPUTests {
    static let width = 96, height = 64

    /// Gradients, flat blocks with sharp edges, a specular patch and signed and zero pixels, so the
    /// local base differs from the pixels and halation has a source.
    static func pixels() -> [SIMD3<Float>] {
        (0..<(width * height)).map { i -> SIMD3<Float> in
            let x = i % width, y = i / width
            if i == 5 { return .zero }
            if i == 7 { return SIMD3(-0.05, 0.03, 0.4) }
            let stops: Float
            if (40..<56).contains(x) && (20..<44).contains(y) { stops = (x + y) % 2 == 0 ? 4.5 : 3.5 }
            else if x < 32 { stops = -9 + 14 * Float(y) / Float(height - 1) }
            else if x >= 64 { stops = y < 32 ? -2.5 : 1.5 }
            else { stops = -4 + 8 * Float(x - 32) / 31 }
            let v = 0.18 * exp2(stops)
            return SIMD3(v * 0.85, v, v * 1.15)
        }
    }

    private func frame(_ gpu: GPU, _ pixels: [SIMD3<Float>], width: Int = width) throws -> LinearFrame {
        let height = pixels.count / width
        let texture = try gpu.makeTexture(width: width, height: height)
        var values = [Float16](repeating: 1, count: pixels.count * 4)
        for (i, rgb) in pixels.enumerated() {
            values[i * 4] = Float16(rgb.x); values[i * 4 + 1] = Float16(rgb.y); values[i * 4 + 2] = Float16(rgb.z)
        }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "light-test", scale: 1)
    }

    private func read(_ texture: MTLTexture) -> [SIMD3<Float>] {
        let values = ExposureAnalyzer.pixels(of: texture)
        return stride(from: 0, to: values.count, by: 4).map { SIMD3(Float(values[$0]), Float(values[$0 + 1]), Float(values[$0 + 2])) }
    }

    /// The CPU walk: the base field's reference, the scene map, both LUTs and the print mapping.
    private func reference(_ pixels: [SIMD3<Float>], stock: Stock, settings: DevelopSettings) throws -> [SIMD3<Float>] {
        let input = pixels.map(half)
        let tables = try settings.manual.toneTables(stock: stock, settings: settings)
        let bases = settings.manual.needsToneBase
            ? ToneBaseField.reference(pixels: input, width: Self.width, height: input.count / Self.width, parameters: ToneBaseParameters.compiler2026_10_29_1)
            : input.map(ManualRenderSettings.guideLog2)
        let encoding = stock.negative.encoding, rated = settings.exposureStops(boxSpeed: stock.boxSpeed)
        let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        return try zip(input, bases).map { rgb, base in
            let adjusted = GamutCompression.compress(try settings.manual.applyingScene(to: rgb, baseLog2: base, tables: tables))
            func encode(_ v: Float) -> Float {
                min(max((log2(max(v, 1e-6) / encoding.midGray) + rated + encoding.stopsBelowMidGray) / encoding.range, 0), 1)
            }
            let negative = half(stock.negative.sample(encoded: SIMD3(encode(adjusted.x), encode(adjusted.y), encode(adjusted.z))))
            let density = (negative + offset).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
            return try settings.manual.applyingPrint(to: stock.print.sample(encoded: density))
        }
    }

    static let edits: [ManualAdjustments] = [
        try! ManualAdjustments(exposureEV: 0.4, contrast: 60, highlights: -80, shadows: 50, whites: -40, blacks: 30),
        try! ManualAdjustments(exposureEV: -1.2, contrast: -100, highlights: 100, shadows: -100, whites: 100, blacks: -100),
        try! ManualAdjustments(contrast: 100, highlights: -100, shadows: 100, whites: -100, blacks: 100),
        try! ManualAdjustments(highlights: -65, shadows: 35),
        try! ManualAdjustments(exposureEV: 0.75, whites: 45, blacks: -20),
    ]

    @Test func theNegativePassMatchesTheCPUReferenceOnEveryStock() throws {
        let gpu = try GPU()
        let pixels = Self.pixels()
        func worst(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
            var worst: Float = 0
            for (gpuPixel, cpuPixel) in zip(a, b) {
                let difference = gpuPixel - cpuPixel
                worst = max(worst, abs(difference.x), abs(difference.y), abs(difference.z))
            }
            return worst
        }
        for stock in try toneStocks() {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            for (index, values) in Self.edits.enumerated() {
                func settings(_ version: String) throws -> DevelopSettings {
                    DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.2,
                                    manual: try ManualRenderSettings(adjustments: values, referenceStops: 0.6, version: version))
                }
                let compilers = try gainTableVersions.map { version in
                    (version: version, actual: read(try renderer.render(try frame(gpu, pixels), settings: try settings(version)).image.texture),
                     expected: try reference(pixels, stock: stock, settings: try settings(version)))
                }
                for compiler in compilers {
                    let difference = worst(compiler.actual, compiler.expected)
                    #expect(difference < 0.004, "\(stock.id) \(compiler.version) edit \(index): worst difference \(difference)")
                }
                // The tolerance tells the two reads apart wherever they differ, so this checks the GPU's.
                if values.exposureEV != 0 && (values.highlights != 0 || values.shadows != 0) {
                    let crossed = worst(compilers[0].actual, compilers[1].expected)
                    #expect(crossed > 0.004, "\(stock.id) edit \(index): the compilers differ by only \(crossed)")
                }
            }
        }
        // The passes' two frame-sized textures and the base field's three, every render after the
        // first from the pool.
        #expect(gpu.texturePool.allocationCount == 2 + 3)
    }

    @Test(arguments: gainTableVersions)
    func theHalationSourceUsesItsCompilersSceneMap(version: String) throws {
        let gpu = try GPU()
        let stock = ToyStock.make()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let field = try HalationField(gpu: gpu)
        let pixels = Self.pixels()
        let settings = DevelopSettings(ratedAt: 200, manual: try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.75,
            contrast: 30, highlights: -100, shadows: 60, whites: 40), referenceStops: 0.5, version: version))
        let tone = try #require(try renderer.toneInputs(settings, exposureStops: 1, printOffset: .zero))
        let base = try ToneBaseField(gpu: gpu).field(for: frame(gpu, pixels), parameters: ToneBaseParameters.compiler2026_10_29_1)
        let scene = try ManualSceneInputs(settings.manual, tables: tone.tables, buffer: tone.buffer, base: base.texture)
        let halation = Stock.Halation(strength: 0.015, greenShare: 0.25, radiusMicrometres: 180)
        let mapped = try field.field(for: frame(gpu, pixels), exposureStops: 1, halation: halation, scene: scene)
        let bases = ToneBaseField.reference(pixels: pixels.map(half), width: Self.width, height: Self.height,
                                            parameters: ToneBaseParameters.compiler2026_10_29_1)
        let sourceMapped = try zip(pixels, bases).map { try settings.manual.applyingScene(to: half($0), baseLog2: $1, tables: tone.tables) }
        let expected = try field.field(for: frame(gpu, sourceMapped), exposureStops: 1, halation: halation)
        var worst: Float = 0, largest: Float = 0
        for (a, b) in zip(read(mapped.texture), read(expected.texture)) {
            worst = max(worst, abs(a.x - b.x), abs(a.y - b.y))
            largest = max(largest, b.x)
        }
        #expect(largest > 0.001 && worst < 0.01 * largest, "worst \(worst) of \(largest)")
        // The other compiler's map makes another field, by more than that tolerance.
        let otherVersion = version == ManualRenderSettings.currentVersion ? ManualRenderSettings.exposedBaseVersion : ManualRenderSettings.currentVersion
        let other = try ManualRenderSettings(adjustments: settings.manual.adjustments, referenceStops: 0.5, version: otherVersion)
        let otherMapped = try zip(pixels, bases).map { try other.applyingScene(to: half($0), baseLog2: $1, tables: tone.tables) }
        let otherField = try field.field(for: frame(gpu, otherMapped), exposureStops: 1, halation: halation)
        var crossed: Float = 0
        for (a, b) in zip(read(mapped.texture), read(otherField.texture)) { crossed = max(crossed, abs(a.x - b.x), abs(a.y - b.y)) }
        #expect(crossed > 0.01 * largest, "the compilers' fields differ by only \(crossed) of \(largest)")
    }

    /// With Exposure at 0 the current compiler renders the same bytes as the one before it, grain,
    /// halation and sharpening on, with and without the tone step. So does Exposure with no Highlights or
    /// Shadows, whose global table reads the same level on both. Only their pair differs.
    @Test func withoutExposureOnTheLocalTableTheCurrentCompilerRendersTheBytesOfTheOneBefore() throws {
        let gpu = try GPU()
        var stocks = [LightCompilerBaselineTests.toyStock()]
        for url in LightCompilerBaselineTests.bakedStocks { stocks.append(try Stock.load(from: url)) }
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        let same: [(ManualAdjustments, Float)] = [
            (try ManualAdjustments(contrast: 40, highlights: -70, shadows: 55, whites: -30, blacks: 20), 1.25),
            (try ManualAdjustments(contrast: -100, highlights: 100, shadows: -100, whites: 100, blacks: -100), -2),
            (try ManualAdjustments(highlights: -65, shadows: 35), 0.6),
            (try ManualAdjustments(shadows: 100), 0),
            (try ManualAdjustments(highlights: -35, curves: curves), 0.4),
            (try ManualAdjustments(exposureEV: 1.5, contrast: 65, whites: 45, blacks: -20), -0.3),
            (try ManualAdjustments(exposureEV: -2), 0.7),
        ]
        let different: [(ManualAdjustments, Float)] = [
            (try ManualAdjustments(exposureEV: 0.5, highlights: -50), 0.4),
            (try ManualAdjustments(exposureEV: -1, shadows: 100), -0.3),
        ]
        func digest(_ edits: [(ManualAdjustments, Float)], _ stock: Stock, _ tone: PrintTone, _ version: String) throws -> String {
            try LightCompilerBaselineTests.digest(stock: stock, gpu: gpu, edits: edits.map {
                try ManualRenderSettings(adjustments: $0.0, referenceStops: $0.1, version: version)
            }, tone: tone)
        }
        let new = ManualRenderSettings.currentVersion, old = ManualRenderSettings.exposedBaseVersion
        for tone in [PrintTone.identity, LightCompilerBaselineTests.toneStep] {
            for stock in stocks {
                #expect(try digest(same, stock, tone, new) == digest(same, stock, tone, old), "\(stock.id), tone step \(tone.isActive)")
            }
            // One stock is enough here: the negative pass's test tells the reads apart on all of them.
            for edit in different {
                #expect(try digest([edit], stocks[0], tone, new) != digest([edit], stocks[0], tone, old), "tone step \(tone.isActive), \(edit.0)")
            }
        }
    }

    @Test func theBrightestInputStaysFiniteWithEveryControlAtItsExtreme() throws {
        let gpu = try GPU()
        let toy = ToyStock.make()
        let stock = Stock(id: "light-toy", displayName: "Light", status: "synthetic", boxSpeed: toy.boxSpeed,
            densityRange: toy.densityRange, exposurePerUnit: toy.exposurePerUnit, negative: toy.negative, print: toy.print,
            halation: Stock.Halation(strength: 0.0195, greenShare: 0.25, radiusMicrometres: 180))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let pixels = [SIMD3<Float>](repeating: SIMD3(repeating: 65504), count: 64 * 64)
        for strength: Float in [-100, 100] {
            let manual = try current(ManualAdjustments(exposureEV: 3, contrast: strength, highlights: strength, shadows: strength,
                                                        whites: strength, blacks: strength))
            let output = try renderer.render(frame(gpu, pixels, width: 64), settings: DevelopSettings(ratedAt: 100, halation: true, manual: manual))
            #expect(read(output.image.texture).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        }
    }

    /// Zero values render the automatic image under every compiler, and Exposure alone renders
    /// the same bytes under each: the later compilers changed the tone controls, not Exposure.
    @Test func zeroValuesAreTheAutomaticImageAndExposureAloneMatchesTheRecordedCompiler() throws {
        let gpu = try GPU()
        let stock = LightCompilerBaselineTests.toyStock()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let pixels = Self.pixels()
        func render(_ manual: ManualRenderSettings) throws -> [SIMD3<Float>] {
            read(try renderer.render(frame(gpu, pixels), settings: DevelopSettings(ratedAt: 200, grain: 1, grainSeed: 9,
                halation: true, sharpen: true, manual: manual)).image.texture)
        }
        let automatic = try render(.identity)
        for version in gainTableVersions + [ManualRenderSettings.regionsVersion] {
            _ = try render(try ManualRenderSettings(adjustments: ManualAdjustments(highlights: 40, shadows: -30, whites: 20),
                                                    referenceStops: 1, version: version))
            let zero = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: -0.0, highlights: -0.0), referenceStops: -2,
                                                version: version)
            #expect(try render(zero) == automatic, "\(version)")
        }
        let exposure = try ManualAdjustments(exposureEV: 1.35)
        #expect(try render(current(exposure, reference: 0.3)) == (try render(ManualRenderSettings(adjustments: exposure, referenceStops: 0.3,
                                                                                                 version: ManualRenderSettings.regionsVersion))))
        #expect(try render(current(exposure, reference: 0.3)) == (try render(exposedBase(exposure, reference: 0.3))))
    }

    /// The same edit renders the same whether the print goes over the frame or beside it.
    @Test func inPlaceAndSeparateOutputsMatchWithTheCurrentCompiler() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let settings = DevelopSettings(grain: 1, grainSeed: 13, halation: true, sharpen: true, manual: try current(Self.edits[0], reference: 0.5))
        let separate = try renderer.render(frame(gpu, Self.pixels()), settings: settings)
        let inPlace = try renderer.render(frame(gpu, Self.pixels()), settings: settings, inPlace: true)
        #expect(read(separate.image.texture) == read(inPlace.image.texture))
    }
}
