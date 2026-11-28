import ArgentCore
import Foundation
import simd
import Testing
@testable import ArgentRoll

private func makeStock(id: String, displayName: String = "Test") -> Stock {
    Stock(id: id, displayName: displayName, status: id == NeutralAuto.stockID ? "digital" : "datasheet",
          boxSpeed: 100, densityRange: Float(16.0 * log10(2.0)),
          exposurePerUnit: SIMD3(repeating: 1),
          negative: LUT3D.identity(size: 9), print: LUT3D.identity(size: 9))
}

@Suite struct NeutralAutoTests {
    @Test func moodPreservingWhiteBalanceRemovesTintAndCoolCastsWhileKeepingSunsetWarm() {
        // Minor foliage/ambient green-magenta variance within deadband does NOT push pink/magenta.
        let foliageBounce = AutoBalance.cast(redBlue: 0, greenMagenta: 0.05)
        let foliageFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: foliageBounce))
        #expect(abs(foliageFix.greenMagenta) < 1e-5)

        // Genuine fluorescent green cast above deadband is cleaned without over-correcting.
        let greenCast = AutoBalance.cast(redBlue: 0, greenMagenta: 0.30)
        let greenFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: greenCast))
        #expect(abs(greenFix.greenMagenta - 0.60 * (0.30 - 0.06)) < 1e-4)
        #expect(abs(greenFix.redBlue) < 1e-5)

        // Cool blue cast above deadband is gently warmed (45%, up to 0.35 stops) without killing blue skies.
        let coolCast = AutoBalance.cast(redBlue: -0.60, greenMagenta: 0)
        let coolFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: coolCast))
        #expect(abs(coolFix.redBlue + 0.45 * (0.60 - 0.12)) < 1e-4)

        // Mild warm indoor cast above deadband is trimmed gently (55%).
        let mildWarm = AutoBalance.cast(redBlue: 0.30, greenMagenta: 0)
        let mildFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: mildWarm))
        #expect(abs(mildFix.redBlue - 0.55 * (0.30 - 0.12)) < 1e-4)

        // Strong sunset warmth stays intact; film AutoBalance still trims it.
        let sunset = AutoBalance.cast(redBlue: 1.24, greenMagenta: 0)
        let sunsetFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: sunset))
        let remainingWarmth = 1.24 - sunsetFix.redBlue
        #expect(sunsetFix.redBlue == 0)
        #expect(remainingWarmth > 0.92)
        #expect(sunsetFix.redBlue < AutoBalance.axes(AutoBalance.correction(for: sunset)).redBlue)
    }

    @Test func warmCorrectionFadesOutWithoutDroppingTintCleanup() {
        let knee = NeutralAuto.warmMoodKnee
        let threshold = NeutralAuto.warmMoodThreshold
        let atKnee = NeutralAuto.whiteBalanceCorrection(for: AutoBalance.cast(redBlue: knee, greenMagenta: 0))
        let between = NeutralAuto.whiteBalanceCorrection(for: AutoBalance.cast(redBlue: (knee + threshold) / 2, greenMagenta: 0))
        #expect(AutoBalance.axes(between).redBlue > 0)
        #expect(AutoBalance.axes(between).redBlue < AutoBalance.axes(atKnee).redBlue)

        let atThreshold = AutoBalance.cast(redBlue: threshold, greenMagenta: 0.20)
        let fix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: atThreshold))
        #expect(fix.redBlue == 0)
        #expect(abs(fix.greenMagenta - 0.60 * (0.20 - 0.06)) < 1e-4)
        #expect(NeutralAuto.whiteBalanceCorrection(for: .zero) == .zero)
    }

    @Test func legacyWhiteBalanceKeepsItsRecordedDeadbandsSharesAndLimits() {
        let cases: [(Float, Float, Float, Float)] = [
            (0.10, -0.05, 0, 0),
            (0.30, -0.20, 0.099, -0.084),
            (-0.60, 0.30, -0.216, 0.144),
            (-1.50, 0.80, -0.35, 0.25),
        ]
        for (redBlue, greenMagenta, expectedRedBlue, expectedGreenMagenta) in cases {
            let cast = AutoBalance.cast(redBlue: redBlue, greenMagenta: greenMagenta)
            let correction = AutoBalance.axes(NeutralAuto.legacyWhiteBalanceCorrection(for: cast))
            #expect(abs(correction.redBlue - expectedRedBlue) < 1e-5)
            #expect(abs(correction.greenMagenta - expectedGreenMagenta) < 1e-5)
        }
    }

    @Test func sunsetStrengthPrintKeepsPlainNeutralWarmth() {
        let neutral = makeStock(id: NeutralAuto.stockID, displayName: "Neutral")
        // Red-blue cast measured on the public DSC09550 beach sunset.
        let aim = PrintAim(level: -0.67, cast: AutoBalance.cast(redBlue: 0.776, greenMagenta: 0))
        let auto = RollControls(labBalance: .auto).settings(for: neutral, aim: aim)
        let plain = RollControls(labBalance: .neutral).settings(for: neutral, aim: aim)
        #expect(auto.labBalance == plain.labBalance)
    }

    @Test func rollControlsRoutesNeutralWhiteBalanceWithoutChangingFilmStocks() {
        let neutral = makeStock(id: NeutralAuto.stockID, displayName: "Neutral")
        let portra = makeStock(id: "kodak-portra-400", displayName: "Portra 400")
        let aim = PrintAim(cast: AutoBalance.cast(redBlue: 1.24, greenMagenta: 0.20))

        let neutralSettings = RollControls(labBalance: .auto).settings(for: neutral, aim: aim)
        let portraSettings = RollControls(labBalance: .auto).settings(for: portra, aim: aim)
        #expect(neutralSettings.labBalance != portraSettings.labBalance)

        // Neutral Lab balance off (.neutral) leaves both untouched.
        #expect(RollControls(labBalance: .neutral).settings(for: neutral, aim: aim).labBalance == .zero)
    }

    @Test func autoDevelopmentAddsSubtlePolishOnlyForNeutral() throws {
        let neutral = makeStock(id: NeutralAuto.stockID, displayName: "Neutral")
        let portra = makeStock(id: "kodak-portra-400", displayName: "Portra 400")
        let aim = PrintAim(level: -0.25)

        let neutralAuto = try DevelopmentResolver.resolve(stock: neutral, stockDigest: "d", controls: RollControls(),
                                                          aim: aim, manual: nil, grain: 0, grainSeed: 0)
        #expect(neutralAuto.manual == .identity)
        #expect(neutralAuto.autoPresence.isActive)
        #expect(neutralAuto.autoPresence.presence.vibrance == NeutralAuto.polishVibrance)
        #expect(neutralAuto.autoPresence.presence.clarity == NeutralAuto.polishClarity)
        #expect(neutralAuto.autoPresence.referenceStops == aim.level)
        #expect(neutralAuto.effectivePresence == NeutralAuto.polishPresence)
        #expect(neutralAuto.presenceReferenceStops == aim.level)

        let neutralOriginal = try DevelopmentResolver.resolve(stock: neutral, stockDigest: "d", controls: RollControls(),
                                                              aim: PrintAim(), manual: nil, grain: 0, grainSeed: 0, origin: .original)
        #expect(neutralOriginal.manual == .identity && !neutralOriginal.autoPresence.isActive)

        let portraAuto = try DevelopmentResolver.resolve(stock: portra, stockDigest: "d", controls: RollControls(),
                                                         aim: aim, manual: nil, grain: 0, grainSeed: 0)
        #expect(portraAuto.manual == .identity && !portraAuto.autoPresence.isActive)
    }

    @Test func neutralAutoPolishSurvivesManualEditsCacheKeysBudgetAndRecipes() throws {
        let neutral = makeStock(id: NeutralAuto.stockID, displayName: "Neutral")
        let portra = makeStock(id: "kodak-portra-400", displayName: "Portra 400")
        let aim = PrintAim(level: -0.3)

        let autoSettings = try DevelopmentResolver.resolve(stock: neutral, stockDigest: neutral.digest, controls: RollControls(),
                                                           aim: aim, manual: nil, grain: 0, grainSeed: 0)
        let autoKey = RenderedImageKey.film("frame|source|apple", stock: 0, stockID: neutral.id,
                                            settings: autoSettings, space: .sRGB, pixels: 960, frameSized: true)
        #expect(!autoKey.isManual, "untouched Neutral Auto stays in the Auto cache slot")
        #expect(DevelopBudget.presenceCost(settings: autoSettings, width: 4000, height: 3000) > 0)

        let baseline = AutomaticBaseline(sourceSHA256: String(repeating: "a", count: 64), stockID: neutral.id,
                                         stockDigest: neutral.digest, controls: RollControls(), aim: aim,
                                         analysisVersion: ExposureAnalysis.currentVersion,
                                         baseRender: Recipe.Render(settings: autoSettings, grain: .off))
        let maskEdit = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.4), baseline: baseline)
        let edited = try DevelopmentResolver.resolve(stock: neutral, stockDigest: neutral.digest, controls: RollControls(),
                                                     aim: aim, manual: maskEdit, grain: 0, grainSeed: 0)
        #expect(edited.autoPresence == autoSettings.autoPresence)
        #expect(edited.manual.adjustments == maskEdit.adjustments)
        #expect(edited.effectivePresence == NeutralAuto.polishPresence)
        let editedKey = RenderedImageKey.film("frame|source|apple", stock: 0, stockID: neutral.id,
                                              settings: edited, space: .sRGB, pixels: 960, frameSized: true)
        #expect(editedKey.isManual && editedKey.slot != autoKey.slot)

        // Switching to a film stock drops Neutral's auto polish; switching back to Neutral restores it.
        let switchedToPortra = try DevelopmentResolver.resolve(stock: portra, stockDigest: portra.digest, controls: RollControls(),
                                                               aim: aim, manual: maskEdit, grain: 0, grainSeed: 0)
        #expect(!switchedToPortra.autoPresence.isActive && switchedToPortra.effectivePresence.isIdentity)

        let portraBaseline = AutomaticBaseline(sourceSHA256: String(repeating: "a", count: 64), stockID: portra.id,
                                               stockDigest: portra.digest, controls: RollControls(), aim: aim,
                                               analysisVersion: ExposureAnalysis.currentVersion,
                                               baseRender: Recipe.Render(settings: try DevelopmentResolver.resolve(
                                                   stock: portra, stockDigest: portra.digest, controls: RollControls(),
                                                   aim: aim, manual: nil, grain: 0, grainSeed: 0), grain: .off))
        let portraEdit = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.4), baseline: portraBaseline)
        let switchedToNeutral = try DevelopmentResolver.resolve(stock: neutral, stockDigest: neutral.digest, controls: RollControls(),
                                                                aim: aim, manual: portraEdit, grain: 0, grainSeed: 0)
        #expect(switchedToNeutral.autoPresence == autoSettings.autoPresence)

        // Recipe round-trip at version 15 and rejection by older readers.
        let frame = Frame(id: 0, url: URL(fileURLWithPath: "/tmp/DSC04445.ARW"), info: ARWFrameInfo())
        var recipe = try Recipe.make(frame: frame, byteCount: 4096, stock: neutral, stockDigest: neutral.digest,
                                     roll: RollControls(), own: FrameControls(), aim: aim, manual: maskEdit)
        #expect(recipe.version == 15 && recipe.requiredVersion == 15)
        let decoded = try Recipe.decodeStrict(recipe.encoded())
        #expect(decoded == recipe && decoded.render.autoPresence == autoSettings.autoPresence)
        #expect(throws: Recipe.ReadFailure.unsupportedVersion(15)) {
            try Recipe.decodeStrict(recipe.encoded(), readerVersion: 14)
        }
        recipe.version = 14
        #expect(throws: Recipe.ReadFailure.invalid("Automatic Presence requires recipe version 15")) {
            try recipe.validate()
        }

        // Film stocks stay free of autoPresence and keep their earlier recipe version.
        let filmRecipe = try Recipe.make(frame: frame, byteCount: 4096, stock: portra, stockDigest: portra.digest,
                                         roll: RollControls(), own: FrameControls(), aim: aim)
        #expect(filmRecipe.render.autoPresence == nil && filmRecipe.requiredVersion == 2)
    }

    @Test func exposurePlacementRespondsToFacesOnNeutral() {
        let darkFace = ExposureAnalysis(meanStops: 0.2, validWeight: 1,
                                        faces: [FaceMeasure(box: [0.35, 0.3, 0.3, 0.3], levelStops: -1.4, area: 0.05)])
        let brightScene = ExposureAnalysis(meanStops: 0.2, validWeight: 1, faces: [])
        let faceLevel = AutoPrint.levelStops(darkFace)
        let sceneLevel = AutoPrint.levelStops(brightScene)
        // A darker face pulls the frame's aim down (so printing lifts the face brighter).
        #expect(faceLevel < sceneLevel)
    }

    @Test func instagramExportPresetsConfigureSRGBJpegAtSocialSizes() throws {
        let feed = OutputSettings.instagramFeed
        #expect(feed.format == .jpeg)
        #expect(feed.space == .sRGB)
        #expect(feed.size == .instagramFeed && feed.size.longEdge == 1080)
        #expect(feed.quality == 90 && feed.grain == .off)
        #expect(feed.isInstagramPreset)

        let portrait = OutputSettings.instagramPortrait
        #expect(portrait.format == .jpeg)
        #expect(portrait.space == .sRGB)
        #expect(portrait.size == .instagramPortrait && portrait.size.longEdge == 1350)
        #expect(portrait.quality == 90 && portrait.grain == .off)
        #expect(portrait.isInstagramPreset)

        #expect(!OutputSettings().isInstagramPreset)
        #expect(OutputSettings.Size.pickerOptions == [.full, .instagramFeed, .instagramPortrait])

        let encoded = try JSONEncoder().encode(feed)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: encoded)
        #expect(decoded == feed)

        // Applying an Instagram preset preserves roll grain and halation choices.
        let customRoll = OutputSettings(format: .tiff16, size: .full, space: .displayP3, grain: .natural, quality: 100, halation: 0)
        let social = customRoll.applyingInstagramPreset(.instagramPortrait)
        #expect(social.format == .jpeg && social.space == .sRGB && social.size == .instagramPortrait && social.quality == 90)
        #expect(social.grain == .natural && social.halation == 0)

        // Social sizes suffix filenames so they never overwrite full-size JPEGs.
        #expect(OutputSettings.Size.full.fileSuffix == "")
        #expect(OutputSettings.Size.instagramFeed.fileSuffix == "-1080px")
        #expect(OutputSettings.Size.instagramPortrait.fileSuffix == "-1350px")
    }
}
