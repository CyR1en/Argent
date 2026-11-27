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
        // Fluorescent green cast is firmly removed (85%, up to 0.40 stops).
        let greenCast = AutoBalance.cast(redBlue: 0, greenMagenta: 0.30)
        let greenFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: greenCast))
        #expect(abs(greenFix.greenMagenta - 0.255) < 1e-4)
        #expect(abs(greenFix.redBlue) < 1e-5)

        // Cool blue cast is cleanly warmed (80%, up to 0.65 stops).
        let coolCast = AutoBalance.cast(redBlue: -0.60, greenMagenta: 0)
        let coolFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: coolCast))
        #expect(abs(coolFix.redBlue + 0.48) < 1e-4)

        // Mild warm indoor cast is trimmed gently (75%).
        let mildWarm = AutoBalance.cast(redBlue: 0.30, greenMagenta: 0)
        let mildFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: mildWarm))
        #expect(abs(mildFix.redBlue - 0.225) < 1e-4)

        // Strong sunset warmth (130 mired = +1.24 stops) stays predominantly warm (> 65% kept),
        // while keeping more warmth than film AutoBalance (which removes 0.57 stops).
        let sunset = AutoBalance.cast(redBlue: 1.24, greenMagenta: 0)
        let sunsetFix = AutoBalance.axes(NeutralAuto.whiteBalanceCorrection(for: sunset))
        let remainingWarmth = 1.24 - sunsetFix.redBlue
        #expect(sunsetFix.redBlue <= NeutralAuto.warmMoodLimit + 1e-5)
        #expect(remainingWarmth > 0.80)
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
    }
}
