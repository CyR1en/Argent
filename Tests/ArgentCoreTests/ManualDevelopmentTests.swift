import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct ManualDevelopmentValueTests {
    @Test func rejectsInvalidValuesAndUnknownCompilers() throws {
        #expect(throws: ManualDevelopmentError.self) { try ManualAdjustments(exposureEV: .nan) }
        #expect(throws: ManualDevelopmentError.self) { try ManualAdjustments(exposureEV: 5.01) }
        #expect(throws: ManualDevelopmentError.self) { try ManualAdjustments(exposureEV: -5.01) }
        #expect(throws: ManualDevelopmentError.self) { try ManualAdjustments(shadows: .infinity) }
        #expect(throws: ManualDevelopmentError.self) { try ManualAdjustments(contrast: -101) }
        #expect(throws: ManualDevelopmentError.self) {
            try ManualRenderSettings(adjustments: .identity, referenceStops: .nan)
        }
        #expect(throws: ManualDevelopmentError.self) {
            try ManualRenderSettings(adjustments: .identity, referenceStops: 0, version: "future")
        }
        let invalidJSON = Data("""
            {"exposureEV":0,"contrast":0,"highlights":0,"shadows":101,"whites":0,"blacks":0}
            """.utf8)
        #expect(throws: ManualDevelopmentError.self) { try JSONDecoder().decode(ManualAdjustments.self, from: invalidJSON) }
    }

    @Test func canonicalIdentityRoundTripsAndRetainsBaseCompatibility() throws {
        let values = try ManualAdjustments(exposureEV: -0.0, contrast: -0.0, blacks: -0.0)
        #expect(values.isIdentity)
        #expect(values.exposureEV.sign == .plus)
        let manual = try ManualRenderSettings(adjustments: values, referenceStops: 2.5)
        #expect(manual == .identity)
        #expect(try JSONDecoder().decode(ManualRenderSettings.self, from: JSONEncoder().encode(manual)) == manual)
        #expect(RenderGraph.version(for: DevelopSettings(manual: manual)) == RenderGraph.version)
        let edited = try ManualRenderSettings(adjustments: values.setting(.exposure, to: 1), referenceStops: 0)
        #expect(RenderGraph.version(for: DevelopSettings(manual: edited)) != RenderGraph.version)
    }

    @Test func controlsExposeTheProductRanges() throws {
        #expect(ManualAdjustments.Control.allCases.count == 6)
        for control in ManualAdjustments.Control.allCases {
            let values = try ManualAdjustments.identity.setting(control, to: control.range.upperBound)
            #expect(values.value(for: control) == control.range.upperBound)
            #expect(try values.setting(control, to: 0).isIdentity)
            #expect(control.step > 0 && !control.title.isEmpty)
        }
    }

    /// Exposure widened from ±3 to Lightroom's ±5 EV on 2026-10-29: every value saved before still
    /// decodes as it was, and the compiler of that time renders the new ends.
    @Test func exposureTakesLightroomsRangeAndKeepsEverySavedValue() throws {
        for hundredths in stride(from: -300, through: 300, by: 5) {
            let value = Float(hundredths) / 100
            let json = Data(#"{"exposureEV":\#(value),"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0}"#.utf8)
            #expect(try JSONDecoder().decode(ManualAdjustments.self, from: json).exposureEV == value)
        }
        #expect(ManualAdjustments.Control.exposure.range == -5...5 && ManualAdjustments.Control.exposure.step == 0.01)
        for exposure: Float in [-5, 5] {
            let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: exposure, contrast: 100,
                highlights: -100, shadows: 100, whites: 100, blacks: -100), referenceStops: 0, version: "2026-10-09-1")
            for rgb: SIMD3<Float> in [SIMD3(0.18, 0.18, 0.18), SIMD3(-0.02, 0.4, 1.3), SIMD3(repeating: 65504)] {
                let scene = try manual.applyingScene(to: rgb)
                let printed = try manual.applyingPrint(to: scene)
                #expect((0..<3).allSatisfy { scene[$0].isFinite && printed[$0].isFinite })
            }
            let plain = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: exposure), referenceStops: 0,
                                                 version: "2026-10-09-1")
            #expect(try plain.applyingScene(to: SIMD3(0.12, 0.18, 0.5)) == SIMD3(0.12, 0.18, 0.5) * exp2(exposure))
        }
    }

    @Test func unavailableRecordedCompilerRestoresIntentButCannotRender() throws {
        let json = Data("""
            {"adjustments":{"exposureEV":1,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0},
             "referenceStops":1.5,"version":"future-mapping"}
            """.utf8)
        let recorded = try JSONDecoder().decode(ManualRenderSettings.self, from: json)
        #expect(recorded.adjustments.exposureEV == 1 && recorded.referenceStops == 1.5)
        #expect(recorded.version == "future-mapping")
        #expect(throws: ManualDevelopmentError.self) { try recorded.validateSupportedVersion() }
        #expect(throws: ManualDevelopmentError.self) { try recorded.applyingScene(to: SIMD3(repeating: 0.18)) }
        #expect(throws: ManualDevelopmentError.self) { try recorded.applyingPrint(to: SIMD3(repeating: 0.18)) }
        let identityJSON = Data("""
            {"adjustments":{"exposureEV":0,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0},
             "referenceStops":1.5,"version":"future-mapping"}
            """.utf8)
        #expect(try JSONDecoder().decode(ManualRenderSettings.self, from: identityJSON) == .identity)
    }
}

@Suite struct ManualDevelopmentCurveTests {
    @Test func identityIsBitExactForSignedAndNearZeroRGB() throws {
        let pixels: [SIMD3<Float>] = [.zero, SIMD3(-0.4, 0.3, 1.2), SIMD3(1e-9, -1e-9, 0),
                                     SIMD3(repeating: 65504)]
        for rgb in pixels {
            #expect(try ManualRenderSettings.identity.applyingScene(to: rgb) == rgb)
            #expect(try ManualRenderSettings.identity.applyingPrint(to: rgb) == rgb)
        }
    }

    @Test func exposureIsAnIndependentSceneStopAndAbsentSignalStaysAbsent() throws {
        let plusOne = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 1), referenceStops: 2)
        let minusOne = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: -1), referenceStops: -2)
        for rgb in [SIMD3<Float>(0.12, 0.18, 0.5), SIMD3(-0.02, 0.03, 0.1), .zero] {
            #expect(try plusOne.applyingScene(to: rgb) == rgb * 2)
            #expect(try minusOne.applyingScene(to: rgb) == rgb * 0.5)
            #expect(try plusOne.applyingPrint(to: rgb) == rgb)
        }
        let allScene = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 3, highlights: 100, shadows: 100), referenceStops: 0,
                                                 version: ManualRenderSettings.regionsVersion)
        #expect(try allScene.applyingScene(to: .zero) == .zero)
    }

    @Test func sceneRampsRemainMonotoneAcrossOpposedExtrema() throws {
        for exposure: Float in [-3, 0, 3] {
            for highlights: Float in [-100, 0, 100] {
                for shadows: Float in [-100, 0, 100] {
                    for reference: Float in [-3, 0, 3] {
                        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: exposure,
                            highlights: highlights, shadows: shadows), referenceStops: reference, version: ManualRenderSettings.regionsVersion)
                        var previous: Float = -1
                        for i in 0...640 {
                            let value = i == 0 ? 0 : 0.18 * exp2(-16 + Float(i) / 20)
                            let mapped = ManualRenderSettings.luminance(try manual.applyingScene(to: SIMD3(repeating: value)))
                            #expect(mapped.isFinite && mapped >= previous,
                                    "EV \(exposure), H \(highlights), S \(shadows), ref \(reference), input \(value)")
                            previous = mapped
                        }
                    }
                }
            }
        }
    }

    @Test func printRampsRemainMonotoneIncludingSignedAndOverWhiteValues() throws {
        for contrast: Float in [-100, 0, 100] {
            for whites: Float in [-100, 0, 100] {
                for blacks: Float in [-100, 0, 100] {
                    let manual = try ManualRenderSettings(adjustments: ManualAdjustments(contrast: contrast,
                        whites: whites, blacks: blacks), referenceStops: 0, version: ManualRenderSettings.regionsVersion)
                    var previous: Float = -.infinity
                    let ramp: [Float] = [-2, -1, -0.1, -1e-5, -1e-8, 0, 1e-8, 1e-6, 1e-5]
                        + (1...1000).map { Float($0) / 1000 } + [1.001, 1.1, 2, 16]
                    for value in ramp {
                        let mapped = ManualRenderSettings.luminance(try manual.applyingPrint(to: SIMD3(repeating: value)))
                        #expect(mapped.isFinite && mapped + 1e-7 >= previous,
                                "C \(contrast), W \(whites), B \(blacks), input \(value), \(previous) -> \(mapped)")
                        previous = mapped
                    }
                }
            }
        }
    }

    @Test func printEndpointsAndMidtoneContrastHaveTheirDeclaredDirection() throws {
        let regions = ManualRenderSettings.regionsVersion
        let lifted = try ManualRenderSettings(adjustments: ManualAdjustments(blacks: 100), referenceStops: 0, version: regions)
        let deeper = try ManualRenderSettings(adjustments: ManualAdjustments(blacks: -100), referenceStops: 0, version: regions)
        #expect(abs(try lifted.applyingPrint(to: .zero).x - 0.04) < 1e-6)
        #expect(abs(try deeper.applyingPrint(to: .zero).x + 0.04) < 1e-6)
        let whites = try ManualRenderSettings(adjustments: ManualAdjustments(whites: -100), referenceStops: 0, version: regions)
        #expect(abs(try whites.applyingPrint(to: SIMD3(repeating: 1)).x - 0.8) < 1e-6)
        let contrast = try ManualRenderSettings(adjustments: ManualAdjustments(contrast: 100), referenceStops: 0, version: regions)
        #expect(abs(try contrast.applyingPrint(to: SIMD3(repeating: 0.18)).x - 0.18) < 1e-6)
        #expect(try contrast.applyingPrint(to: SIMD3(repeating: 0.1)).x < 0.1)
        #expect(try contrast.applyingPrint(to: SIMD3(repeating: 0.4)).x > 0.4)
    }

    @Test func signedWideGamutPatchesStayFiniteAndSceneChromaticityIsPreserved() throws {
        let patches: [SIMD3<Float>] = [.zero, SIMD3(-0.2, 0.5, 1.4), SIMD3(1.2, -0.1, 0.03),
            SIMD3(-1, -0.5, 0.2), SIMD3(-0.6780, 0.2627, 0), SIMD3(repeating: 1e-10), SIMD3(repeating: 65504)]
        for strength: Float in [-100, 100] {
            let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 3,
                contrast: strength, highlights: strength, shadows: -strength, whites: strength, blacks: -strength), referenceStops: -3,
                version: ManualRenderSettings.regionsVersion)
            for patch in patches {
                let scene = try manual.applyingScene(to: patch)
                let print = try manual.applyingPrint(to: patch)
                #expect((0..<3).allSatisfy { scene[$0].isFinite && print[$0].isFinite })
                if patch.x != 0 && patch.y != 0 {
                    #expect(abs(scene.x / scene.y - patch.x / patch.y) < 1e-5)
                }
            }
        }
    }
}

@Suite struct ManualDevelopmentGPUTests {
    private func frame(_ gpu: GPU, pixels: [SIMD3<Float>], width: Int? = nil) throws -> LinearFrame {
        let width = width ?? pixels.count
        let height = pixels.count / width
        let texture = try gpu.makeTexture(width: width, height: height)
        var values = [Float16](repeating: 1, count: pixels.count * 4)
        for (i, rgb) in pixels.enumerated() {
            values[i * 4] = Float16(rgb.x)
            values[i * 4 + 1] = Float16(rgb.y)
            values[i * 4 + 2] = Float16(rgb.z)
        }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "manual-test", scale: 1)
    }

    private func read(_ texture: MTLTexture) -> [SIMD3<Float>] {
        let values = ExposureAnalyzer.pixels(of: texture)
        return stride(from: 0, to: values.count, by: 4).map {
            SIMD3(Float(values[$0]), Float(values[$0 + 1]), Float(values[$0 + 2]))
        }
    }

    private func half(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(Float(Float16(rgb.x)), Float(Float16(rgb.y)), Float(Float16(rgb.z)))
    }

    private func reference(_ rgb: SIMD3<Float>, stock: Stock, settings: DevelopSettings) throws -> SIMD3<Float> {
        let adjusted = GamutCompression.compress(try settings.manual.applyingScene(to: half(rgb)))
        let encoding = stock.negative.encoding
        let rated = settings.exposureStops(boxSpeed: stock.boxSpeed)
        let encoded = SIMD3<Float>(
            min(max((log2(max(adjusted.x, 1e-6) / encoding.midGray) + rated + encoding.stopsBelowMidGray) / encoding.range, 0), 1),
            min(max((log2(max(adjusted.y, 1e-6) / encoding.midGray) + rated + encoding.stopsBelowMidGray) / encoding.range, 0), 1),
            min(max((log2(max(adjusted.z, 1e-6) / encoding.midGray) + rated + encoding.stopsBelowMidGray) / encoding.range, 0), 1))
        let negative = half(stock.negative.sample(encoded: encoded))
        let shifted = (negative + settings.printOffset(densityRange: stock.densityRange,
            exposurePerUnit: stock.exposurePerUnit)).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
        return try settings.manual.applyingPrint(to: stock.print.sample(encoded: shifted))
    }

    @Test func pointAndRegionCurvesMatchTheCPUAfterThePrintAndKeepIdentityExact() throws {
        let gpu = try GPU(), stock = ToyStock.make()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let pixels = (0..<64).map { i -> SIMD3<Float> in
            let x = Float(i) / 32
            return SIMD3(x, x * 0.8, x * 1.2)
        }
        let input = try frame(gpu, pixels: pixels)
        let green = try ChannelCurve.identity.setting(.shadows, to: 65).setting(.lights, to: -30)
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve,
                                   red: ToneCurves.Preset.liftedBlacks.curve, green: green,
                                   blue: ToneCurves.Preset.strongContrast.curve)
        let sliders = try ManualAdjustments(exposureEV: 0.35, contrast: 20, highlights: -35, shadows: 15, blacks: 5)
        let regions = ManualRenderSettings.regionsVersion
        let manual = try ManualRenderSettings(adjustments: sliders.settingCurves(curves), referenceStops: 0.7, version: regions)
        let settings = DevelopSettings(manual: manual)
        let actual = read(try renderer.render(input, settings: settings).image.texture)
        for (i, pair) in zip(actual, try pixels.map { try reference($0, stock: stock, settings: settings) }).enumerated() {
            let difference = pair.0 - pair.1
            #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) < 0.004,
                    "curve pixel \(i): GPU \(pair.0), CPU \(pair.1)")
        }
        let old = DevelopSettings(manual: try ManualRenderSettings(adjustments: sliders, referenceStops: 0.7, version: regions))
        let identity = DevelopSettings(manual: try ManualRenderSettings(adjustments: sliders.settingCurves(.identity), referenceStops: 0.7,
                                                                        version: regions))
        #expect(read(try renderer.render(input, settings: old).image.texture) == read(try renderer.render(input, settings: identity).image.texture))
        #expect(gpu.texturePool.allocationCount == 2)
        #expect(MemoryLayout<ToneCurveParameters>.stride == 48)
    }

    @Test func fusedPassesMatchTheCPUReferenceWithoutExtraFullSizeTextures() throws {
        let gpu = try GPU()
        let stock = ToyStock.make()
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let pixels = (0..<96).map { i -> SIMD3<Float> in
            let value = i == 0 ? 0 : 0.18 * exp2(-10 + Float(i) / 6)
            return SIMD3(value, value * 0.8, value * 1.2)
        } + [SIMD3(-0.1, 0.2, 1.1), SIMD3(1.3, -0.03, 0.1)]
        let input = try frame(gpu, pixels: pixels)
        for strength: Float in [-100, 100] {
            let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.65,
                contrast: strength, highlights: -strength, shadows: strength, whites: strength, blacks: -strength), referenceStops: 1.25,
                version: ManualRenderSettings.regionsVersion)
            let settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), manual: manual)
            let result = try renderer.render(input, settings: settings)
            let actual = read(result.image.texture)
            for (i, pair) in zip(actual, try pixels.map { try reference($0, stock: stock, settings: settings) }).enumerated() {
                let difference = pair.0 - pair.1
                let error = max(abs(difference.x), abs(difference.y), abs(difference.z))
                #expect(error < 0.004, "pixel \(i): GPU \(pair.0), CPU \(pair.1)")
            }
        }
        #expect(gpu.texturePool.allocationCount == 2)
    }

    @Test func halationUsesTheSceneMapBeforeItsThresholdAndAreaAverage() throws {
        let gpu = try GPU()
        let field = try HalationField(gpu: gpu)
        let pixels = (0..<(2048 * 32)).map { i -> SIMD3<Float> in
            SIMD3(repeating: i % 2 == 0 ? 0.18 * exp2(5) : 0.18 * exp2(1))
        }
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 0.75,
            highlights: -100, shadows: 60), referenceStops: 0.5, version: ManualRenderSettings.regionsVersion)
        let stockHalation = Stock.Halation(strength: 0.015, greenShare: 0.25, radiusMicrometres: 180)
        let mapped = try field.field(for: frame(gpu, pixels: pixels, width: 2048), exposureStops: 1,
                                     halation: stockHalation, manual: manual)
        let sourceMapped = try pixels.map { try manual.applyingScene(to: half($0)) }
        let reference = try field.field(for: frame(gpu, pixels: sourceMapped, width: 2048), exposureStops: 1,
                                        halation: stockHalation)
        for pair in zip(read(mapped.texture), read(reference.texture)) {
            let difference = pair.0 - pair.1
            #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) < 0.0001)
        }
    }

    @Test func brightestFiniteInputStaysFiniteWithMaximumSceneAdjustmentAndHalation() throws {
        let gpu = try GPU()
        let field = try HalationField(gpu: gpu)
        let pixels = [SIMD3<Float>](repeating: SIMD3(repeating: 65504), count: 64 * 64)
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 3,
            highlights: 100, shadows: 100), referenceStops: 0, version: ManualRenderSettings.regionsVersion)
        let source = try frame(gpu, pixels: pixels, width: 64)
        let output = try field.field(for: source, exposureStops: 2,
            halation: Stock.Halation(strength: 0.0195, greenShare: 0.25, radiusMicrometres: 180), manual: manual)
        let values = read(output.texture)
        #expect(values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        #expect(values[32 * 64 + 32].x > 1000)
        // The strongest stock at the Halation control's most, 0.14 twice over: the halo passes a half float, and is held at
        // its largest, where an infinite texel would make the pixels beside it NaN in the Negative LUT pass.
        let strongest = try field.field(for: source, exposureStops: 2,
            halation: Stock.Halation(strength: 0.28, greenShare: 0.06, radiusMicrometres: 270), manual: manual)
        let most = read(strongest.texture)
        #expect(most.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        #expect(most[32 * 64 + 32].x == 65504)
    }

    @Test func inPlaceAndSeparateOutputsMatchWithAllFilmStages() throws {
        let gpu = try GPU()
        let toy = ToyStock.make()
        let stock = Stock(id: "manual-toy", displayName: "Manual", status: "synthetic", boxSpeed: toy.boxSpeed,
            densityRange: toy.densityRange, exposurePerUnit: toy.exposurePerUnit, negative: toy.negative,
            print: toy.print, grain: GrainTable(amounts: [[0, 0, 0], [1, 1, 1]],
                sigma48: [[0.01, 0.02, 0.015], [0.005, 0.01, 0.02]]),
            halation: Stock.Halation(strength: 0.02, greenShare: 0.3, radiusMicrometres: 180))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let pixels = (0..<(64 * 64)).map { i -> SIMD3<Float> in
            let value: Float = i % 11 == 0 ? 3.5 : 0.1 + Float(i % 13) / 25
            return SIMD3<Float>(repeating: value)
        }
        let manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 1,
            contrast: 25, highlights: -65, shadows: 35, whites: -20, blacks: 12), referenceStops: 0.5)
        let settings = DevelopSettings(grain: 1, grainSeed: 13, halation: true, sharpen: true, manual: manual)
        let separate = try renderer.render(frame(gpu, pixels: pixels, width: 64), settings: settings)
        let inPlace = try renderer.render(frame(gpu, pixels: pixels, width: 64), settings: settings, inPlace: true)
        #expect(read(separate.image.texture) == read(inPlace.image.texture))
    }

    private static var bakedStocks: [URL] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/stocks")
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Stock.manifestName).path) }
    }

    @Test(.enabled(if: !ManualDevelopmentGPUTests.bakedStocks.isEmpty))
    func resetIsExactlyTheAutomaticImageForEveryBakedStockAndGrainMode() throws {
        let gpu = try GPU()
        let pixels = (0..<(64 * 64)).map { i -> SIMD3<Float> in
            let value = 0.18 * exp2(-5 + Float(i % 48) / 4)
            return SIMD3(value, value * 0.7, value * 1.1)
        }
        let input = try frame(gpu, pixels: pixels, width: 64)
        for url in Self.bakedStocks {
            let renderer = try FilmRenderer(gpu: gpu, stock: Stock.load(from: url))
            for grain: Float in [0, 1] {
                var settings = DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, 0.02, -0.03),
                                               grain: grain, grainSeed: 37, halation: true, sharpen: true)
                let baseline = read(try renderer.render(input, settings: settings).image.texture)
                settings.manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: 1,
                    contrast: 50, shadows: 30, blacks: 15), referenceStops: 1)
                _ = try renderer.render(input, settings: settings)
                settings.manual = try ManualRenderSettings(adjustments: ManualAdjustments(exposureEV: -0.0), referenceStops: -2)
                #expect(read(try renderer.render(input, settings: settings).image.texture) == baseline,
                        "\(url.lastPathComponent), grain \(grain)")
            }
        }
    }
}
