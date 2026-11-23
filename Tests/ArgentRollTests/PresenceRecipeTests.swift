import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// A frame and its recipe with fixed revision and lineage, as `MaskRecipeTests` makes them, for the record a frame with Presence
/// writes. Each test has a temporary library of its own.
private struct PresenceScene {
    let root: URL
    let frame: Frame
    let stock: Stock
    let sha: String
    let writer: RecipeWriter
    let library: URL
    let controls = RollControls()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentPresence-\(UUID().uuidString)")
        library = root.appendingPathComponent("library", isDirectory: true)
        let roll = root.appendingPathComponent("roll", isDirectory: true)
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        let raw = roll.appendingPathComponent("frame.ARW")
        try Data(repeating: 53, count: 4096).write(to: raw)
        frame = Frame(id: 0, url: raw, info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1000)))
        stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                      exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let digests = SourceDigests(settle: 0)
        sha = try digests.digest(of: raw).sha256
        writer = RecipeWriter(digests: digests)
    }

    func baseline() -> AutomaticBaseline {
        let aim = PrintAim(level: -0.3, cast: SIMD3(0.1, -0.05, -0.05))
        return AutomaticBaseline(sourceSHA256: sha, stockID: stock.id, stockDigest: stock.digest, controls: controls, aim: aim,
                                 analysisVersion: ExposureAnalysis.currentVersion,
                                 baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: aim), grain: .off))
    }

    func edit(_ values: ManualAdjustments) -> ManualEdit { ManualEdit(adjustments: values, baseline: baseline()) }

    func recipe(_ manual: ManualEdit?, held: ManualEdit? = nil) throws -> Recipe {
        var recipe = try Recipe.make(frame: frame, byteCount: 4096, stock: stock, stockDigest: stock.digest, roll: controls, own: FrameControls(),
                                     analysis: ExposureAnalysis(meanStops: -0.3, validWeight: 1), aim: PrintAim(level: -0.3), grain: .off,
                                     previous: nil, manual: manual, editRevision: 12, editLineage: "presence-lineage", heldManual: held)
        recipe.raw.sha256 = sha
        return recipe
    }

    /// A develop's receipt of `render`, the only place a frame that has been reset can still hold Presence.
    func receipt(of render: Recipe.Render) -> Recipe.Develop {
        .init(date: Date(timeIntervalSince1970: 3000), software: "Argent test", output: OutputSettings(), file: "/tmp/x.jpg",
              width: 40, height: 20, render: render, decode: nil, readback: nil, stockDigest: stock.digest, renderVersion: "v")
    }
}

@Suite struct PresenceRecipeTests {
    private static let presence = try! ManualAdjustments(contrast: 10, presence: Presence([.clarity: 35, .saturation: -20]))

    @Test func presenceAnywhereRequiresVersion7AndNothingElseDoes() throws {
        let scene = try PresenceScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        #expect(Recipe.currentVersion == 13)
        let light = try ManualAdjustments(contrast: 10)
        #expect(try scene.recipe(scene.edit(light)).requiredVersion == 2, "Light without Presence keeps its version")
        #expect(try scene.recipe(scene.edit(Self.presence)).requiredVersion == 7)
        #expect(try scene.recipe(nil, held: scene.edit(Self.presence)).requiredVersion == 7, "a held edit")
        let masked = try ManualAdjustments(masks: MaskSet(masks: [Mask(components: [MaskComponent(shape: .linear(.init(
            full: MaskPoint(x: 0.5, y: 0.2), zero: MaskPoint(x: 0.5, y: 0.6))))], adjustments: try ManualAdjustments(exposureEV: 1))]))
        #expect(try scene.recipe(scene.edit(masked.settingPresence(Self.presence.presence))).requiredVersion == 7, "Presence comes before masks")
        var reset = try scene.recipe(nil)
        reset.develops.append(scene.receipt(of: try scene.recipe(scene.edit(Self.presence)).render))
        #expect(reset.requiredVersion == 7, "a receipt")
        reset.develops = []
        #expect(reset.requiredVersion == 2)
    }

    @Test func aRecipeWithPresenceRoundTripsAtVersion7() async throws {
        let scene = try PresenceScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var recipe = try scene.recipe(scene.edit(Self.presence))
        recipe.develops.append(scene.receipt(of: recipe.render))
        #expect(recipe.version == 7)
        let bytes = try recipe.encoded()
        let read = try Recipe.decodeStrict(bytes)
        #expect(read == recipe)
        #expect(read.manual?.adjustments.presence == Self.presence.presence && read.develops[0].render.manual?.adjustments.presence == Self.presence.presence)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("\"version\" : 7") && text.contains("\"clarity\" : 35"))
        let saved = try await scene.writer.commit(recipe: recipe, for: scene.frame, library: scene.library)
        #expect(saved.version == 7)
        #expect(try await scene.writer.load(for: scene.frame, library: scene.library)?.manual?.adjustments.presence == Self.presence.presence)
    }

    @Test func presenceLabelledVersion6IsRefused() throws {
        let scene = try PresenceScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var recipe = try scene.recipe(scene.edit(Self.presence))
        recipe.version = 6
        #expect(throws: Recipe.ReadFailure.invalid("Presence requires recipe version 7")) { try recipe.validate() }
        #expect(throws: Recipe.ReadFailure.invalid("Presence requires recipe version 7")) { try Recipe.decodeStrict(try recipe.encoded()) }
    }

    /// A build whose newest recipe version is 6 reads this record as unsupported and so preserves it, rather than print the frame
    /// without its Presence and save it back without it. A record without Presence is still one it reads.
    @Test func aVersion6ReaderRefusesTheRecord() throws {
        let scene = try PresenceScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let withPresence = try scene.recipe(scene.edit(Self.presence)).encoded()
        #expect(throws: Recipe.ReadFailure.unsupportedVersion(7)) { try Recipe.decodeStrict(withPresence, readerVersion: 6) }
        let without = try scene.recipe(scene.edit(try ManualAdjustments(contrast: 10))).encoded()
        #expect(try Recipe.decodeStrict(without, readerVersion: 6).version == 2)
    }

    @Test func theRenderGraphNamesPresenceOnlyWhenItIsSet() throws {
        var settings = DevelopSettings()
        settings.manual = try ManualRenderSettings(adjustments: try ManualAdjustments(contrast: 10), referenceStops: 0)
        let light = RenderGraph.version(for: settings)
        #expect(!light.contains("presence"))
        settings.manual = try ManualRenderSettings(adjustments: Self.presence, referenceStops: 0)
        #expect(RenderGraph.version(for: settings) == light + "+presence-" + Presence.currentVersion)
        let legacy = try ManualAdjustments(contrast: 10, presence: Presence([.vibrance: 40], version: "2026-11-11-1"))
        settings.manual = try ManualRenderSettings(adjustments: legacy, referenceStops: 0)
        #expect(RenderGraph.version(for: settings) == light + "+presence-2026-11-11-1")
        #expect(RenderGraph.version(for: settings) != light + "+presence-" + Presence.currentVersion)
        settings.manual = try ManualRenderSettings(adjustments: ManualAdjustments(presence: Presence([.dehaze: 0])), referenceStops: 0)
        #expect(RenderGraph.version(for: settings) == RenderGraph.version(for: DevelopSettings()), "identity Presence is no edit")
    }
}

@Suite struct PresenceDevelopTests {
    /// A develop's gate weighs a frame's analysis with its film passes, and nothing for Saturation and Vibrance, which read none.
    @Test func aDevelopWeighsTheAnalysisOfTheSceneControls() throws {
        var settings = DevelopSettings()
        settings.manual = try ManualRenderSettings(adjustments: ManualAdjustments(presence: Presence([.saturation: 40, .vibrance: 20])),
                                                   referenceStops: 0)
        #expect(DevelopBudget.presenceCost(settings: settings, width: 7008, height: 4672) == 0)
        #expect(DevelopBudget.presenceCost(settings: DevelopSettings(), width: 7008, height: 4672) == 0)
        let presence = try Presence([.clarity: 40, .dehaze: -20])
        settings.manual = try ManualRenderSettings(adjustments: ManualAdjustments(presence: presence), referenceStops: 0)
        #expect(DevelopBudget.presenceCost(settings: settings, width: 7008, height: 4672)
                == PresenceAnalyses.developBytes(presence, width: 7008, height: 4672))
        #expect(DevelopBudget.presenceCost(settings: settings, width: 7008, height: 4672) > 0)
    }

    /// The previews keep less while a develop runs, and their own again after it, as they do the masks' fields.
    @Test func thePreviewsKeepLessWhileADevelopRuns() throws {
        let films = try FilmPreviews(stocks: [])
        #expect(films.presenceAnalysisLimit == PresenceAnalyses.defaultMaximumBytes)
        films.isDevelopRunning = true
        #expect(films.presenceAnalysisLimit == PresenceAnalyses.developRunningMaximumBytes)
        films.isDevelopRunning = false
        #expect(films.presenceAnalysisLimit == PresenceAnalyses.defaultMaximumBytes)
    }
}
