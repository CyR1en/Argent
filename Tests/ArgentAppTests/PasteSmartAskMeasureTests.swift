import ArgentCore
@testable import ArgentRoll
import Darwin
import Foundation
import Testing
@testable import ArgentApp

/// What a batch paste's Sky selections cost through the queue (docs/context-menus-plan.md, rule 4): one Sky ask on each raw of
/// `ARGENT_PASTE_RAWS`, all asked at once as a paste asks them and run one after another on `MaskInference`'s queue, through the
/// bundled models (`BundledSmartMasks`), with DA3 held for the batch as the paste holds it (`RollModel.holdingSkyModel`) and without,
/// alternating, each round on a queue of its own so nothing is answered from what an earlier round kept. Each round's time, each
/// selection's landing, the process's peak footprint over the round and its footprint two seconds after, and the models let go.
/// Needs `build/models` (or `ARGENT_MASK_MODELS`). Off unless `ARGENT_MEASURE=1`.
///
///     ARGENT_MEASURE=1 ARGENT_MASK_MODELS=<models> ARGENT_PASTE_RAWS=<a folder of copies> swift test --filter PasteSmartAskMeasureTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"
                              && ProcessInfo.processInfo.environment["ARGENT_PASTE_RAWS"] != nil))
struct PasteSmartAskMeasureTests {
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// The highest footprint seen every 10 ms while it runs.
    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var most = 0, running = true

        func start() {
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let now = PasteSmartAskMeasureTests.footprint()
                    lock.withLock { most = max(most, now) }
                    usleep(10_000)
                }
            }
        }

        func stop() -> Int { lock.withLock { running = false; return most } }
    }

    @Test func aBatchOfSkyAsksThroughTheQueue() async throws {
        let env = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(env["ARGENT_PASTE_RAWS"]), isDirectory: true)
        let raws = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.uppercased() == "ARW" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!raws.isEmpty)
        let models = env["ARGENT_MASK_MODELS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/models")
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("argent-paste-measure-\(UUID().uuidString)")
        let stock = support.appendingPathComponent("toy")
        try FileManager.default.createDirectory(at: stock, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try LUT3D.identity(size: 2).binaryData().write(to: stock.appendingPathComponent("negative.lut3d"))
        try LUT3D.identity(size: 2).binaryData().write(to: stock.appendingPathComponent("print.lut3d"))
        let manifest: [String: Any] = [
            "schema": 2, "id": "toy", "displayName": "Toy", "status": "synthetic", "boxSpeed": 400, "densityRange": 2.5,
            "negative": ["file": "negative.cube", "binary": "negative.lut3d", "size": 2,
                         "logEncoding": ["stopsBelowMidGray": 8, "stopsAboveMidGray": 5, "midGray": 0.18]],
            "print": ["file": "print.cube", "binary": "print.lut3d", "size": 2, "exposurePerUnit": [0.8, 0.8, 0.8]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: stock.appendingPathComponent(Stock.manifestName))
        let films = try FilmPreviews(stocks: StockLibrary.load(from: support).stocks, decoderChoices: DecoderChoices(route: .raw9))
        let bundled = MaskModels(directory: models, ledgerFile: support.appendingPathComponent("ledger.json"))
        try #require(bundled.isSkyAvailable, "\(bundled.unavailable)")
        let engine = BundledSmartMasks(films: films, models: bundled, app: "paste-measure")
        let frames = try raws.enumerated().map { Frame(id: $0.offset, url: $0.element, info: try ARWFrameInfo.read(from: $0.element)) }
        let sha = String(repeating: "0", count: 64)

        print("PASTE-MEASURE \(frames.count) frames; footprint at start \(Self.footprint() >> 20) MB")
        for (round, held) in [("warm-up", true), ("held", true), ("not held", false), ("held", true), ("not held", false)] {
            let inference = MaskInference(engine: engine, turns: DecodeTurns())
            let sampler = Sampler()
            let before = Self.footprint()
            sampler.start()
            let start = ContinuousClock.now
            if held { inference.tabOpened() }
            let asks = frames.map { inference.ask(.sky, on: $0, sourceSHA256: sha, lens: .default) }
            var landed: [Double] = [], found = 0
            for ask in asks {
                if case .found = await ask.outcome.value { found += 1 }
                landed.append((ContinuousClock.now - start).seconds)
            }
            if held { inference.tabClosed() }
            await inference.waitUntilIdle()
            let whole = (ContinuousClock.now - start).seconds
            let peak = sampler.stop()
            engine.releasePictures()
            try await Task.sleep(for: .seconds(2.5))
            let settled = Self.footprint(), stats = inference.statistics
            let gaps = zip(landed.dropFirst(), landed).map { $0 - $1 }
            print(String(format: "PASTE-MEASURE %@: %d asks, %d found, runs %d, Sky models let go %d | first %.2f s, all %.2f s, %.2f s a frame after the first (median gap %.2f s) | footprint %d MB before, peak %d MB (+%d), %d MB settled",
                         round, asks.count, found, stats.runs, stats.unloads, landed.first ?? 0, whole,
                         gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count), gaps.isEmpty ? 0 : gaps.sorted()[gaps.count / 2],
                         before >> 20, peak >> 20, (peak - before) >> 20, settled >> 20))
        }
    }
}

/// What a batch paste's one turn costs the main thread on a large roll (docs/context-menus-plan.md, rule 7): a roll of
/// `ARGENT_PASTE_FRAMES` synthetic frames (300 unless given) on the toy stock, settled, and Paste to All Frames from a frame with
/// Light, a curve and two gradients, every other frame pinned anew. The whole paste from the ask to its report, and the longest the
/// main actor went without a turn meanwhile, which is the write's one turn or a frame's preparation. Off unless `ARGENT_MEASURE=1`.
///
///     ARGENT_MEASURE=1 swift test --filter PasteBatchMeasureTests
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"))
struct PasteBatchMeasureTests {
    /// The longest gap between the main actor's turns, and whether to go on watching.
    @MainActor final class Watch {
        var longest = 0.0
        var running = true
    }

    @Test func aBatchOnALargeRoll() async throws {
        let count = ProcessInfo.processInfo.environment["ARGENT_PASTE_FRAMES"].flatMap(Int.init) ?? 300
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-paste-batch-\(UUID().uuidString)")
        let roll = folder.appendingPathComponent("Roll"), stock = folder.appendingPathComponent("Stocks/toy")
        let library = folder.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stock, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = (0..<count).map { String(format: "DSC%05d.ARW", $0) }
        for (index, name) in names.enumerated() {
            try writeSequenceHeader(roll.appendingPathComponent(name),
                                    captured: String(format: "2026:10:21 %02d:%02d:%02d", 8 + index / 3600, index / 60 % 60, index % 60),
                                    tail: Data(UUID().uuidString.utf8))
        }
        try LUT3D.identity(size: 2).binaryData().write(to: stock.appendingPathComponent("negative.lut3d"))
        try LUT3D.identity(size: 2).binaryData().write(to: stock.appendingPathComponent("print.lut3d"))
        let manifest: [String: Any] = [
            "schema": 2, "id": "toy", "displayName": "Toy", "status": "synthetic", "boxSpeed": 400, "densityRange": 2.5,
            "negative": ["file": "negative.cube", "binary": "negative.lut3d", "size": 2,
                         "logEncoding": ["stopsBelowMidGray": 8, "stopsAboveMidGray": 5, "midGray": 0.18]],
            "print": ["file": "print.cube", "binary": "print.lut3d", "size": 2, "exposurePerUnit": [0.8, 0.8, 0.8]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: stock.appendingPathComponent(Stock.manifestName))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder.appendingPathComponent("Stocks"), decisions: AutoDecisionStore(library: library),
                              flagStore: FlagStore(library: library), recipeLibrary: library,
                              previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        let gate = MeasurementGate()
        for (index, name) in names.enumerated() {
            gate.analyses[name] = ExposureAnalysis(meanStops: Float(index % 7) * 0.2 - 0.6, validWeight: 1, grayEstimate: [0, 0, 0])
        }
        model.measureFrame = { await gate.measure($0) }
        await model.open(roll)
        if let restoration = model.manualRestoreTask { await restoration.value }
        let frames = try #require(model.roll?.frames)
        gate.openAll(frames)
        _ = try #require(await model.settledDecision())
        defer { AutoDecisionStateTests.close(model, gate) }
        let source = frames[0]
        await model.prepareManualAdjustments(for: source)
        model.recordVisibleAutomatic(for: source, stock: model.stockIndex, aim: model.printAim(for: source),
                                     settings: model.settings(for: source, stock: model.stockIndex))
        let gradients = try (0..<2).map { index in
            Mask(components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: Float(index) * 0.2),
                                                                  zero: MaskPoint(x: 0.5, y: Float(index) * 0.2 + 0.4))))],
                 adjustments: try ManualAdjustments(exposureEV: -0.5))
        }
        model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.6, shadows: 20, curves: try ToneCurves(tone: ToneCurves.Preset.softContrast.curve),
                                                         masks: try MaskSet(masks: gradients)), for: source)
        model.copyAdjustments(from: source)
        model.manualUndoManager = UndoManager()

        let watch = Watch()
        let watcher = Task { @MainActor in
            var last = ContinuousClock.now
            while watch.running {
                try? await Task.sleep(for: .milliseconds(1))
                let now = ContinuousClock.now
                watch.longest = max(watch.longest, (now - last).seconds)
                last = now
            }
        }
        let start = ContinuousClock.now
        model.pasteAdjustmentsToShownFrames()
        let report = try #require(await model.pasteTask?.value)
        let whole = (ContinuousClock.now - start).seconds
        watch.running = false
        await watcher.value
        let saving = ContinuousClock.now
        try await model.flushManualSaves()
        print(String(format: "PASTE-BATCH %d frames: %d pasted, %d left out; ask to report %.2f s; the longest the main actor went without a turn %.1f ms; saves flushed %.2f s after",
                     frames.count, report.pasted.count, report.skipped.count, whole, watch.longest * 1000, (ContinuousClock.now - saving).seconds))
        #expect(report.pasted.count == frames.count - 1)
    }
}
