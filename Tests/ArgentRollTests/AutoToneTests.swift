import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// The tone step through Auto's decisions and recipes: aims carry it, a roll pulls it together as it pulls the
/// level, recipes keep what they recorded, and an edit pinned before it existed prints as it did.
@Suite struct AutoToneTests {
    private static let stock = Stock(id: "tone-test", displayName: "Tone test", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                                     exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))

    private static func frame(_ index: Int, seconds: Double) -> Frame {
        Frame(id: index, url: URL(fileURLWithPath: "/roll/DSC\(index).ARW"),
              info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1_700_000_000 + seconds), exposureTime: 1.0 / 64, fNumber: 4, iso: 100))
    }

    /// A long bright tail when `wide`, with the whole measurement else the same.
    private static func analysis(level: Float = -0.5, wide: Bool) -> ExposureAnalysis {
        var histogram = [Float](repeating: 0, count: ExposureAnalysis.histogramBins)
        histogram[8] = 0.5; histogram[9] = 0.3
        if wide { histogram[16] = 0.1; histogram[17] = 0.1 } else { histogram[10] = 0.2 }
        return ExposureAnalysis(meanStops: level, validWeight: 1, histogram: histogram, asShotTemperature: 5200)
    }

    @Test func anAimCarriesItsToneCountedFromItsOwnLevel() {
        let aim = PrintAim(level: -0.4, burn: 0.3, dodge: 0.1)
        #expect(aim.tone == PrintTone(burn: 0.3, dodge: 0.1, referenceStops: -0.4))
        #expect(PrintAim(level: -0.4).tone == .identity, "no strength is the old render, whatever the level")
        let settings = RollControls().settings(for: Self.stock, aim: aim)
        #expect(settings.tone == aim.tone)
        #expect(RollControls().settings(for: Self.stock, aim: PrintAim(level: -0.4)).tone == .identity)
    }

    @Test func anAutoAimIsItsMeasurementsOwn() {
        let analysis = Self.analysis(wide: true)
        let aim = AutoPrint.aim(analysis)
        let tone = FittedTone.strengths(analysis)
        #expect(aim.level == AutoPrint.levelStops(analysis) && aim.burn == tone.burn && aim.dodge == tone.dodge)
        #expect(aim.cast == AutoBalance.cast(analysis))
        #expect(AutoDecisions.ownAim(analysis) == aim)
        #expect(aim.burn > 0, "every frame the fit saw takes some")
    }

    @Test func aRollPullsItsToneAsItPullsItsLevel() throws {
        let frames = (0..<3).map { Self.frame($0, seconds: Double($0)) }
        let analyses = [frames[0].url: Self.analysis(wide: false), frames[1].url: Self.analysis(wide: false), frames[2].url: Self.analysis(wide: true)]
        // One cluster, whatever the tails: the histogram split is what keeps them together here.
        let aims = RollSmoothing.aims(frames, analyses: analyses)
        for frame in frames {
            let aim = try #require(aims[frame.url])
            let own = FittedTone.strengths(try #require(analyses[frame.url]))
            let clusters = RollSmoothing.clusters(frames, analyses: analyses).first { $0.contains { $0.url == frame.url } } ?? []
            if clusters.count == 1 {
                #expect(abs(aim.burn - own.burn) < 1e-5 && abs(aim.dodge - own.dodge) < 1e-5, "a frame alone keeps its own")
            } else {
                let tones = clusters.compactMap { analyses[$0.url] }.map(FittedTone.strengths)
                let median = RollSmoothing.median(tones.map(\.burn))
                #expect(abs(aim.burn - median) <= RollSmoothing.maximumToneDeviation + 1e-5)
                #expect(abs(aim.burn - median) <= abs(own.burn - median) + 1e-5, "pulled toward the cluster, never past it")
            }
        }
    }

    @Test func aTonePrintedLiveIsRecordedAndRestored() throws {
        let aim = PrintAim(level: 0.1, burn: 0.3, dodge: 0.1)
        let settings = RollControls().settings(for: Self.stock, aim: aim)
        let render = Recipe.Render(settings: settings, grain: .off)
        #expect(render.tone == aim.tone)
        #expect(render.settings.tone == aim.tone)
        let decoded = try JSONDecoder().decode(Recipe.Render.self, from: JSONEncoder().encode(render))
        #expect(decoded == render)
        var plain = render
        plain.tone = nil
        #expect(plain != render, "a develop at another tone is made again")
    }

    @Test func aRenderWithoutAToneWritesAndReadsAsItDidBefore() throws {
        let render = Recipe.Render(settings: RollControls().settings(for: Self.stock, aim: PrintAim(level: 0.1)), grain: .off)
        #expect(render.tone == nil)
        let text = String(decoding: try JSONEncoder().encode(render), as: UTF8.self)
        #expect(!text.contains("tone"), "no new field in a recipe with no tone step")
        #expect(RenderGraph.version(for: render.settings) == RenderGraph.version, "and its develop keeps its version")
    }

    @Test func anAimWithoutAToneWritesAndReadsAsItDidBefore() throws {
        let plain = PrintAim(level: 0.25, cast: SIMD3(0.1, 0, -0.1))
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!text.contains("burn") && !text.contains("dodge"))
        let old = Data(#"{"level":0.25,"cast":[0.1,0,-0.1]}"#.utf8)
        #expect(try JSONDecoder().decode(PrintAim.self, from: old) == plain)
        let toned = PrintAim(level: 0.25, cast: SIMD3(0.1, 0, -0.1), burn: 0.4, dodge: 0.2)
        #expect(try JSONDecoder().decode(PrintAim.self, from: JSONEncoder().encode(toned)) == toned)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PrintAim.self, from: Data(#"{"level":0,"cast":[0,0,0],"burn":-1}"#.utf8)) }
    }

    private func recipe(_ aim: PrintAim, manual: ManualEdit? = nil) throws -> Recipe {
        try Recipe.make(frame: Self.frame(0, seconds: 0), byteCount: 4096, stock: Self.stock, stockDigest: Self.stock.digest, roll: RollControls(),
                        own: FrameControls(), analysis: nil, aim: aim, grain: .off, sharpen: true, manual: manual)
    }

    @Test func aRecipeWithAToneNeedsItsVersion() throws {
        let toned = try recipe(PrintAim(level: 0.1, burn: 0.3))
        #expect(toned.requiredVersion == 5)
        #expect(toned.version == 5)
        let plain = try recipe(PrintAim(level: 0.1))
        #expect(plain.requiredVersion < 5, "a recipe with no tone step stays readable by a build without one")
    }

    /// The owner's edits on the roll were pinned before the tone step: they must print exactly as they did.
    @Test func anEditPinnedBeforeTheToneStepPrintsAsItDid() throws {
        let controls = RollControls()
        let oldAim = PrintAim(level: 0.3, cast: SIMD3(0.05, 0, -0.05))
        let baseline = AutomaticBaseline(sourceSHA256: String(repeating: "a", count: 64), stockID: Self.stock.id, stockDigest: Self.stock.digest,
                                         controls: controls, aim: oldAim, analysisVersion: "2026-10-29-1",
                                         baseRender: Recipe.Render(settings: controls.settings(for: Self.stock, aim: oldAim), grain: .off))
        let edit = ManualEdit(adjustments: try ManualAdjustments(highlights: -75, shadows: 37), baseline: baseline)
        // Today's Auto would aim this frame elsewhere, with a tone; the pin does not move.
        let today = PrintAim(level: -0.2, burn: 0.5, dodge: 0.2)
        let settings = try DevelopmentResolver.resolve(stock: Self.stock, stockDigest: Self.stock.digest, controls: controls, aim: today,
                                                       manual: edit, grain: 0, grainSeed: 0)
        #expect(settings.tone == .identity)
        #expect(settings.labBalance == baseline.baseRender.settings.labBalance)
        #expect(settings.manual.referenceStops == oldAim.level)
    }

    /// An edit pinned on the new Auto keeps its tone, and Compare to Auto, which reads the same pin, shows it.
    @Test func anEditPinnedOnTheToneKeepsIt() throws {
        let controls = RollControls()
        let aim = PrintAim(level: -0.1, burn: 0.4, dodge: 0.15)
        let baseline = AutomaticBaseline(sourceSHA256: String(repeating: "a", count: 64), stockID: Self.stock.id, stockDigest: Self.stock.digest,
                                         controls: controls, aim: aim, analysisVersion: ExposureAnalysis.currentVersion,
                                         baseRender: Recipe.Render(settings: controls.settings(for: Self.stock, aim: aim), grain: .off))
        let edit = ManualEdit(adjustments: try ManualAdjustments(shadows: 20), baseline: baseline)
        let settings = try DevelopmentResolver.resolve(stock: Self.stock, stockDigest: Self.stock.digest, controls: controls,
                                                       aim: PrintAim(level: 0.4, burn: 0.1), manual: edit, grain: 0, grainSeed: 0)
        #expect(settings.tone == aim.tone)
        let decoded = try JSONDecoder().decode(AutomaticBaseline.self, from: JSONEncoder().encode(baseline))
        #expect(decoded == baseline && decoded.aim.tone == aim.tone)
    }

    @Test func anOriginalHasNoTone() {
        #expect(PrintAim().tone == .identity)
        #expect(RollControls().settings(for: Self.stock, aim: PrintAim()).tone == .identity)
    }

    /// A frame saved on the tone step's first version keeps it: its recipe writes and reads it, its develop's render version
    /// names it, and its pin keeps it even when a new rating solves the table again. A new frame, and a new pin, take the
    /// current version (`PrintTone.WhiteHold`).
    @Test func aFrameSavedOnTheFirstToneVersionKeepsIt() throws {
        let controls = RollControls()
        let aim = PrintAim(level: -0.1, burn: 0.4, dodge: 0.15)
        #expect(aim.tone.version == PrintTone.currentVersion && PrintTone.currentVersion != "2026-11-05-2", "a new frame takes the current table")
        var first = controls.settings(for: Self.stock, aim: aim)
        first.tone.version = "2026-11-05-2"
        let render = Recipe.Render(settings: first, grain: .off)
        let text = String(decoding: try JSONEncoder().encode(render), as: UTF8.self)
        #expect(text.contains(#""version":"2026-11-05-2""#))
        let decoded = try JSONDecoder().decode(Recipe.Render.self, from: Data(text.utf8))
        #expect(decoded == render && decoded.settings.tone.version == "2026-11-05-2")
        #expect(RenderGraph.version(for: decoded.settings) == RenderGraph.version + "+tone-2026-11-05-2", "its develop is not made again")
        var current = render
        current.tone?.version = PrintTone.currentVersion
        #expect(current != render && RenderGraph.version(for: current.settings) != RenderGraph.version(for: render.settings))

        let baseline = AutomaticBaseline(sourceSHA256: String(repeating: "a", count: 64), stockID: Self.stock.id, stockDigest: Self.stock.digest,
                                         controls: controls, aim: aim, analysisVersion: ExposureAnalysis.currentVersion, baseRender: render)
        let edit = ManualEdit(adjustments: try ManualAdjustments(shadows: 20), baseline: baseline)
        func resolve(_ controls: RollControls, _ manual: ManualEdit?) throws -> DevelopSettings {
            try DevelopmentResolver.resolve(stock: Self.stock, stockDigest: Self.stock.digest, controls: controls, aim: aim, manual: manual,
                                            grain: 0, grainSeed: 0)
        }
        #expect(try resolve(controls, edit).tone == first.tone, "the pin prints its recorded render")
        let rated = RollControls(ratedAt: .oneStopOver)
        let again = try resolve(rated, edit)
        #expect(again.ratedAt != first.ratedAt && again.tone.version == "2026-11-05-2", "a new rating keeps the pin's table version")
        #expect(again.tone.burn == aim.burn && again.tone.dodge == aim.dodge && again.tone.referenceStops == aim.level)
        #expect(try resolve(rated, nil).tone.version == PrintTone.currentVersion, "a new pin takes the current version")
    }
}
