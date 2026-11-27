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

        // Strong sunset warmth (130 mired = +1.24 stops) stays predominantly warm (> 74% kept),
        // while keeping more warmth than film AutoBalance (which removes 0.57 stops).
        let sunset = AutoBalance.cast(redBlue: 1.24, greenMagenta: 0)
        let sunsetFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: sunset))
        let remainingWarmth = 1.24 - sunsetFix.redBlue
        #expect(sunsetFix.redBlue <= NeutralAuto.warmMoodLimit + 1e-5)
        #expect(remainingWarmth > 0.92)
        #expect(sunsetFix.redBlue < AutoBalance.axes(AutoBalance.correction(for: sunset)).redBlue)
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
        #expect(neutralAuto.manual.adjustments.presence.vibrance == NeutralAuto.polishVibrance)
        #expect(neutralAuto.manual.adjustments.presence.clarity == NeutralAuto.polishClarity)
        #expect(neutralAuto.manual.referenceStops == aim.level)

        let portraAuto = try DevelopmentResolver.resolve(stock: portra, stockDigest: "d", controls: RollControls(),
                                                         aim: aim, manual: nil, grain: 0, grainSeed: 0)
        #expect(portraAuto.manual == .identity)
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
