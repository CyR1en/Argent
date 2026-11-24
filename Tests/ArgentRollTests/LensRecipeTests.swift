import Foundation
import Testing
@testable import ArgentCore
@testable import ArgentRoll

@Suite struct LensRecipeTests {
    private func recipe(in folder: URL, manual: Bool = false, previous: Recipe? = nil) throws -> Recipe {
        let raw = folder.appendingPathComponent("frame.ARW")
        let frame = Frame(id: 0, url: raw, info: ARWFrameInfo())
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let baseline = AutomaticBaseline(sourceSHA256: String(repeating: "a", count: 64), stockID: stock.id,
            stockDigest: stock.digest, controls: RollControls(), aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        return try Recipe.make(frame: frame, byteCount: 3, stock: stock, stockDigest: stock.digest, roll: RollControls(),
                               own: FrameControls(), previous: previous,
                               manual: manual ? ManualEdit(adjustments: .identity, baseline: baseline) : nil)
    }

    private func receipt(_ recipe: Recipe, lens: ResolvedLensCorrection?) -> Recipe.Develop {
        let pins = DecodePins(version: DecodePins.currentVersion, decoderVersion: "8", baselineExposure: 0, shadowBias: 0, sharpness: 0,
            boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true, extendedDynamicRange: 1,
            neutralChromaticity: .init(x: 0.33, y: 0.35), moireReduction: 1, contrast: 0, detail: 0,
            anchorDecodedMidTone: 0.08, anchorVersion: "1", exposureGainStops: 1, luminanceNoiseReduction: 0.4,
            colorNoiseReduction: 0.5, lensCorrection: lens == nil, scale: 1, draftMode: false)
        return .init(date: Date(timeIntervalSince1970: 1000), software: "Argent test", output: OutputSettings(),
            file: "/tmp/lens-receipt.jpg", width: 10, height: 10, render: recipe.render, decode: pins, readback: nil,
            stockDigest: recipe.stock.digest, renderVersion: RenderGraph.version(for: recipe.render.settings, lens: lens))
    }

    @Test func resumeMatchesOnlyTheRecordedCorrectionOrAnUnchangedDecoderCorrectedReceipt() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = URL(fileURLWithPath: "/tmp/lens-receipt.jpg")
        let lens = ResolvedLensCorrection.identity
        let different = ResolvedLensCorrection.uncorrected("none in the file")
        let cases: [(name: String, recorded: ResolvedLensCorrection?, decoderLens: Bool, current: ResolvedLensCorrection,
                     changedSetting: Bool, matches: Bool)] = [
            ("lens-less, decoder on", nil, true, lens, false, true),
            ("lens-less, decoder off", nil, false, lens, false, false),
            ("same digest", lens, false, lens, false, true),
            ("different digest", lens, false, different, false, false),
            ("lens-less, changed setting", nil, true, lens, true, false),
            ("lens-named, changed setting", lens, false, lens, true, false)
        ]
        for item in cases {
            var record = try recipe(in: folder)
            var develop = receipt(record, lens: item.recorded)
            develop.decode?.lensCorrection = item.decoderLens
            record.develops = [develop]
            if item.changedSetting { record.render.printExposure += 0.5 }
            #expect(record.lastDevelopMatches(file: file, output: OutputSettings(), lens: item.current) == item.matches, "\(item.name)")
        }
    }

    @Test func onlyLensNamedReceiptsRequireEightAndRoundTripTheirCorrection() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let edited = try recipe(in: folder, manual: true)
        #expect(edited.version == 2 && edited.requiredVersion == 2)
        #expect(try Recipe.decodeStrict(edited.encoded(), readerVersion: 7) == edited)
        var stage = edited
        stage.develops = [receipt(stage, lens: .identity)]
        stage.version = stage.requiredVersion
        #expect(stage.version == 8)
        #expect(throws: Recipe.ReadFailure.unsupportedVersion(8)) { try Recipe.decodeStrict(stage.encoded(), readerVersion: 7) }
        let read = try Recipe.decodeStrict(stage.encoded())
        #expect(read == stage)
        #expect(read.develops[0].renderVersion?.hasSuffix("+lens-" + ResolvedLensCorrection.identity.digest) == true)
        stage.version = 7
        #expect(throws: Recipe.ReadFailure.invalid("the lens stage requires recipe version 8")) { try stage.validate() }
        let uncorrected = ResolvedLensCorrection.uncorrected("none in the file")
        #expect(RenderGraph.version(for: DevelopSettings(), lens: uncorrected)
                == RenderGraph.version(for: DevelopSettings()) + "+lens-" + uncorrected.digest)
    }

    @Test func aLensNamedReceiptMergedIntoAnUnmarkedRecordRequiresEight() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("frame.ARW")
        try Data([1, 2, 3]).write(to: raw)
        let frame = Frame(id: 0, url: raw, info: ARWFrameInfo())
        let library = folder.appendingPathComponent("library")
        let writer = RecipeWriter(digests: SourceDigests(settle: 0))
        var fresh = try recipe(in: folder)
        fresh.raw.sha256 = try RecipeStore.sha256(of: raw)
        let saved = try await writer.commit(recipe: fresh, for: frame, library: library)
        var exported = saved
        exported.develops.append(receipt(saved, lens: .identity))
        exported.version = exported.requiredVersion
        let output = folder.appendingPathComponent("frame.jpg")
        try Data([4]).write(to: output)
        let merged = try await writer.mergeExport(recipe: exported, for: frame, library: library)
        #expect(merged.version == 8 && merged.requiredVersion == 8)
    }
}

extension LensRecipeTests {
    @Test func vignettingCodingIsSparseAndOnlyAnActiveAmountRequiresEleven() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        #expect(String(decoding: try encoder.encode(LensSettings.default), as: UTF8.self) == "{}")
        let lens = try LensSettings(arguments: "vignette=-50,vignette-midpoint=75")
        #expect(String(decoding: try encoder.encode(lens), as: UTF8.self)
            == #"{"vignetting":{"amount":-50,"midpoint":75}}"#)
        #expect(String(decoding: try encoder.encode(LensSettings(arguments: "vignette=50")), as: UTF8.self)
            == #"{"vignetting":{"amount":50}}"#)
        for argument in ["default", "vignette=-100", "vignette=100,vignette-midpoint=0", "vignette-midpoint=100"] {
            let settings = try LensSettings(arguments: argument)
            #expect(try LensSettings(arguments: settings.arguments) == settings)
            #expect(try decoder.decode(LensSettings.self, from: encoder.encode(settings)) == settings)
        }
        for argument in ["vignette=-101", "vignette=101", "vignette=nan", "vignette-midpoint=-1", "vignette-midpoint=101", "ca=off"] {
            #expect(throws: (any Error).self) { try LensSettings(arguments: argument) }
        }
        for json in [#"{"vignetting":{"amount":101}}"#, #"{"vignetting":{"midpoint":-1}}"#] {
            #expect(throws: (any Error).self) { try decoder.decode(LensSettings.self, from: Data(json.utf8)) }
        }
        #expect(try LensSettings.Vignetting(amount: -0, midpoint: -0).amount.bitPattern == Float(0).bitPattern)
        let settings = try lens.setting(.distortion, to: 150).setting(.purpleAmount, to: 8).settingDistortion(isOn: false)
        #expect(settings.vignetting == lens.vignetting)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try recipe(in: folder, manual: true)
        let baseline = try #require(original.manual?.baseline)
        let values = ManualAdjustments.identity.settingLens(lens)
        let edit = ManualEdit(adjustments: values, baseline: baseline)
        let render = try ManualRenderSettings(adjustments: values, referenceStops: 0)
        var current = original; current.manual = edit; current.render.manual = render
        var held = original; held.heldManual = edit
        var rendered = original; rendered.render.manual = render; rendered.manual = nil
        var historical = original; var develop = receipt(original, lens: .identity); develop.render.manual = render
        historical.develops = [develop]
        var pinned = original; pinned.heldManual = ManualEdit(adjustments: .identity, baseline: baseline)
        pinned.heldManual?.baseline.baseRender.manual = render
        for var record in [current, held, rendered, historical, pinned] {
            #expect(record.requiredVersion == 11)
            record.version = 11
            #expect(try Recipe.decodeStrict(record.encoded()) == record)
            #expect(throws: Recipe.ReadFailure.unsupportedVersion(11)) { try Recipe.decodeStrict(record.encoded(), readerVersion: 10) }
            record.version = 10
            #expect(throws: Recipe.ReadFailure.invalid("Vignetting requires recipe version 11")) { try record.validate() }
        }
        var midpoint = original
        midpoint.manual?.adjustments = .identity.settingLens(try LensSettings(arguments: "vignette-midpoint=75"))
        #expect(midpoint.requiredVersion == 9)
        #expect(original.requiredVersion == 2 && Recipe.currentVersion == 14)
    }

    @Test func defaultsKeepTheirBytesAndLensAnywhereRequiresNine() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try recipe(in: folder)
        #expect(!String(decoding: try original.encoded(), as: UTF8.self).contains("\"lens\""))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(ManualAdjustments.identity) == encoder.encode(ManualAdjustments(lens: .default)))
        #expect(String(decoding: try encoder.encode(ManualAdjustments.identity), as: UTF8.self)
            == #"{"blacks":0,"contrast":0,"exposureEV":0,"highlights":0,"shadows":0,"whites":0}"#)
        let values = ManualAdjustments.identity.settingLens(try LensSettings(arguments: "distortion=off,distortion-amount=150"))
        let pin = try #require(try recipe(in: folder, manual: true).manual?.baseline)
        let edit = ManualEdit(adjustments: values, baseline: pin)
        let manual = try ManualRenderSettings(adjustments: values, referenceStops: 0)
        var variants: [Recipe] = []
        var current = original
        current.manual = edit
        current.render.manual = manual
        variants.append(current)
        var held = original; held.heldManual = edit; variants.append(held)
        var render = original; render.render.manual = manual; variants.append(render)
        var baseline = original
        baseline.heldManual = ManualEdit(adjustments: .identity, baseline: pin)
        baseline.heldManual?.baseline.baseRender.manual = manual
        variants.append(baseline)
        var history = original
        var develop = receipt(original, lens: .identity); develop.render.manual = manual
        history.develops = [develop]; variants.append(history)
        for var record in variants {
            #expect(record.requiredVersion == 9)
            record.version = 9
            let data = try record.encoded()
            #expect(try Recipe.decodeStrict(data) == record)
            #expect(throws: Recipe.ReadFailure.unsupportedVersion(9)) { try Recipe.decodeStrict(data, readerVersion: 8) }
            record.version = 8
            #expect(throws: Recipe.ReadFailure.invalid("Lens settings require recipe version 9")) { try record.validate() }
        }
    }
}

extension LensRecipeTests {
    @Test func defringeJSONIsStrictSparseAndRequiresTenEvenForInactiveHueHandles() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        #expect(String(decoding: try encoder.encode(LensSettings.default), as: UTF8.self) == "{}")
        let settings = try LensSettings(arguments: "defringe-purple=8,defringe-green=4")
        #expect(String(decoding: try encoder.encode(settings), as: UTF8.self)
            == #"{"defringe":{"greenAmount":4,"purpleAmount":8}}"#)
        let hues = try LensSettings(arguments: "defringe-purple-hue=20:80,defringe-green-hue=30:70")
        #expect(String(decoding: try encoder.encode(hues), as: UTF8.self)
            == #"{"defringe":{"greenHue":[30,70],"purpleHue":[20,80]}}"#)
        #expect(try decoder.decode(LensSettings.self, from: encoder.encode(settings)) == settings)
        for json in [#"{"purpleAmount":21}"#, #"{"greenAmount":-1}"#, #"{"purpleHue":[0,9]}"#,
                     #"{"purpleHue":[90,80]}"#, #"{"greenHue":[0,101]}"#, #"{"greenHue":[40]}"#] {
            #expect(throws: (any Error).self) { try decoder.decode(LensSettings.Defringe.self, from: Data(json.utf8)) }
        }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try recipe(in: folder, manual: true)
        let baseline = try #require(original.manual?.baseline)
        for lens in [settings,hues] {
            let values = ManualAdjustments.identity.settingLens(lens)
            let edit = ManualEdit(adjustments: values, baseline: baseline)
            let render = try ManualRenderSettings(adjustments: values, referenceStops: 0)
            var current = original; current.manual = edit; current.render.manual = render
            var held = original; held.heldManual = edit
            var rendered = original; rendered.render.manual = render; rendered.manual = nil
            var historical = original; var develop = receipt(original, lens: .identity); develop.render.manual = render
            historical.develops = [develop]
            var pinned = original; pinned.heldManual = ManualEdit(adjustments: .identity, baseline: baseline)
            pinned.heldManual?.baseline.baseRender.manual = render
            for var record in [current,held,rendered,historical,pinned] {
                #expect(record.requiredVersion == 10)
                record.version = 10
                #expect(try Recipe.decodeStrict(record.encoded()) == record)
                #expect(throws: Recipe.ReadFailure.unsupportedVersion(10)) { try Recipe.decodeStrict(record.encoded(), readerVersion: 9) }
                record.version = 9
                #expect(throws: Recipe.ReadFailure.invalid("Defringe requires recipe version 10")) { try record.validate() }
            }
        }
        var explicitDefault = original
        explicitDefault.render.manual = try ManualRenderSettings(adjustments: .identity.settingLens(.default), referenceStops: 0)
        var implicitDefault = original
        implicitDefault.render.manual = try ManualRenderSettings(adjustments: .identity, referenceStops: 0)
        #expect(try explicitDefault.encoded() == implicitDefault.encoded())
        #expect(original.requiredVersion == 2)
    }
}

extension LensRecipeTests {
    @Test func completeDefaultRecipeBytesMatchTheParent() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = try recipe(in: folder, manual: true)
        let bytes = try record.encoded()
        #expect(record.requiredVersion == 2)
        if let output = ProcessInfo.processInfo.environment["ARGENT_LC8_RECIPE_PROOF"] {
            try bytes.write(to: URL(fileURLWithPath: output))
        }
    }
}
