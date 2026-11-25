import ArgentCore
import CoreAI
import Foundation
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The new Subject through the app's real engine: a lost model, and on the CC0 sample with every model, the seed path, Background and the settle. The frozen flow's decisions are `SubjectDesignTests`',
/// the bit-for-bit proof `SubjectClickMeasureTests`'.
@Suite(.serialized, .rawDecodes, .enabled(if: FileManager.default.fileExists(atPath: MaskCanary.sample.path)))
struct SubjectClickTests {
    static func film(in support: URL) throws -> FilmPreviews {
        try writeToyStock(id: "kodak-portra-400", in: support)
        return try FilmPreviews(stocks: StockLibrary.load(from: support).stocks, decoderChoices: DecoderChoices(route: .raw9))
    }

    static func frame() async throws -> Frame {
        try #require(await RollScanner.scan(MaskCanary.sample.deletingLastPathComponent()).frames.first { $0.name == MaskCanary.cc0 })
    }

    /// A build without the mask models: Sky, Subject and Background offer their download, Subject and Background instead of a Vision stand-in, and a click
    /// that comes anyway fails and says which model is missing, with no model loaded and no preparation.
    @Test func withoutItsModelsSubjectOffersTheDownloadAndNeverFallsBackToVision() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("argent-subject-lost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: support.appendingPathComponent("no-models"), ledgerFile: support.appendingPathComponent("ledger.json"))
        #expect(!models.isSubjectAvailable && models.subjectMissing != nil && !models.needsPreparation)
        let engine = BundledSmartMasks(films: try Self.film(in: support), models: models, app: "tests")
        let inference = MaskInference(engine: engine, turns: DecodeTurns())
        #expect(inference.availability(of: .subject) == .needsModels(BundledSmartMasks.needsModels(.subject)))
        #expect(inference.availability(of: .background) == .needsModels(BundledSmartMasks.needsModels(.background)))
        #expect(!models.isSkyAvailable && models.skyMissing != nil)
        #expect(inference.availability(of: .sky) == .needsModels(BundledSmartMasks.needsModels(.sky)), "DA3 is in the download: Sky offers it")
        #expect(inference.availability(of: .person).isAvailable, "Person needs no downloaded model")
        let frame = try await Self.frame()
        let stages = StageLog()
        let outcome = await inference.ask(.subject, on: frame, sourceSHA256: String(repeating: "0", count: 64), lens: .default, stage: { stages.add($0) }).outcome.value
        #expect(!stages.all.contains { if case .preparing = $0 { true } else { false } }, "no preparing without models")
        switch outcome {
        case .failed(let why): #expect(why.contains("s3od-sod-sq1024-f16") || why.contains("eomt") || why.contains("vitmatte"), "\(why)")
        case .found, .nothingFound: Issue.record("Subject made a selection without its models")
        case .cancelled: Issue.record("cancelled")
        }
        #expect(!engine.takeReleasedModels(), "nothing was loaded, so no settle is needed")
        let skyStages = StageLog()
        let skyOutcome = await inference.ask(.sky, on: frame, sourceSHA256: String(repeating: "0", count: 64), lens: .default, stage: { skyStages.add($0) }).outcome.value
        #expect(!skyStages.all.contains { if case .preparing = $0 { true } else { false } }, "no preparing without models")
        switch skyOutcome {
        case .failed(let why): #expect(why.contains(BundledMaskModel.sky.rawValue), "\(why)")
        case .found, .nothingFound: Issue.record("Sky made a selection without its models")
        case .cancelled: Issue.record("cancelled")
        }
        #expect(await !models.skyRunner.isLoaded)
        await models.unloadAll()
    }

    /// The real models on the CC0 frame, through "Preparing masks" first: the seed path, the decisions recorded, Background's raster and edge, the models unloaded after, and the settle.
    @Test(.enabled(if: MaskCanary.enabled)) func theClickOnTheSampleRunsThroughEveryStage() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("argent-subject-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: MaskCanary.models, ledgerFile: support.appendingPathComponent("ledger.json"))
        #expect(models.isSubjectAvailable && models.needsPreparation, "\(models.unavailable)")
        defer { for model in BundledMaskModel.allCases { try? AIModelCache.default.deleteEntries(for: try models.url(of: model)) } }
        let engine = BundledSmartMasks(films: try Self.film(in: support), models: models, app: "tests")
        let inference = MaskInference(engine: engine, turns: DecodeTurns())
        let frame = try await Self.frame()
        let stages = StageLog()
        let outcome = await inference.ask(.subject, on: frame, sourceSHA256: String(repeating: "0", count: 64), lens: .default, stage: { stages.add($0) }).outcome.value
        let seen = stages.all
        #expect(seen.contains { if case .preparing = $0 { true } else { false } }, "preparing masks ran first: \(seen)")
        #expect(seen.contains(.finding) && !seen.contains(.checkingWater), "matting is part of finding, and the gate says nothing of water: \(seen)")
        #expect(!models.needsPreparation)
        let subjectLoaded = await models.subjectRunner.isLoaded, matteLoaded = await models.matteRunner.isLoaded
        #expect(!subjectLoaded && !matteLoaded, "both unloaded after the click")
        #expect(inference.statistics.unloads == 1, "the settle ran")
        switch outcome {
        case .found(let seed, _):
            let p = seed.provenance.parameters
            #expect(seed.edge == .crisp || seed.edge == .matte)
            #expect(p["model.recipe"] == BundledMaskModel.subject.recipeID && p["design"] == SubjectDesign.version && p["rule.version"] == LowLightRule.version && p["iou.argmax"] != nil)
            let background = await inference.ask(.background, on: frame, sourceSHA256: String(repeating: "0", count: 64), lens: .default).outcome.value
            if case .found(let bg, _) = background {
                #expect(bg.kind == .background && bg.raster == seed.raster && bg.edge == seed.edge)
            } else { Issue.record("Background \(background)") }
        case .nothingFound(_, let provenance, _):
            #expect(provenance.parameters["outcome"]?.hasPrefix("none") == true && provenance.parameters["rule.in"] != nil)
        case .failed(let why): Issue.record("\(why)")
        case .cancelled: Issue.record("cancelled")
        }
        await models.unloadAll()
    }
}

private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [SmartStage] = []
    func add(_ stage: SmartStage) { lock.withLock { stages.append(stage) } }
    var all: [SmartStage] { lock.withLock { stages } }
}
