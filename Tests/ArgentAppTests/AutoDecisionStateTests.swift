import ArgentCore
@testable import ArgentRoll
import CryptoKit
import Foundation
import Testing
@testable import ArgentApp

/// A raw's header as the a7 IV writes the parts roll smoothing reads: capture time, shutter, aperture,
/// ISO and flash, then `tail`, so each raw's bytes are its own.
func writeSequenceHeader(_ url: URL, captured: String, iso: Int = 400, flash: Bool = false, tail: Data) throws {
    func u16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8 & 255)] }
    func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 255) } }
    func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
        u16(tag) + u16(type) + u32(count) + value + [UInt8](repeating: 0, count: 4 - value.count)
    }
    let exif = 8 + 2 + 12 + 4, data = exif + 2 + 5 * 12 + 4
    let shutter = data, aperture = data + 8, date = data + 16
    let text = Array((captured + "\0").utf8)
    var bytes = [UInt8]([0x49, 0x49]) + u16(42) + u32(8)
    bytes += u16(1) + entry(0x8769, 4, 1, u32(exif)) + u32(0)
    bytes += u16(5) + entry(0x829A, 5, 1, u32(shutter)) + entry(0x829D, 5, 1, u32(aperture))
    bytes += entry(0x8827, 3, 1, u16(iso)) + entry(0x9003, 2, text.count, u32(date))
    bytes += entry(0x9209, 3, 1, u16(flash ? 1 : 0)) + u32(0)
    bytes += u32(1) + u32(250) + u32(28) + u32(10) + text
    try (Data(bytes) + tail).write(to: url, options: .atomic)
}

/// What each frame's measurement comes to and when: a frame's measurement waits until it is let
/// through, and then is the analysis given for it, or a failure, of its raw as it is then.
@MainActor final class MeasurementGate {
    var analyses: [String: ExposureAnalysis] = [:]
    var failing: Set<String> = []
    private var open: Set<URL> = []
    private var waiting: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var asked = 0

    var waitingFrames: Int { waiting.count }

    func measure(_ frame: Frame) async -> FilmPreviews.MeasurementOutcome {
        asked += 1
        if !open.contains(frame.url) { await withCheckedContinuation { waiting[frame.url, default: []].append($0) } }
        let name = frame.url.lastPathComponent, source = SourceStamp.of(frame.url)
        if failing.contains(name) { return .failed(source) }
        guard let analysis = analyses[name], let source else { return .stopped }
        return .measured(FrameMeasurement(analysis: analysis, source: source), nil)
    }

    func release(_ url: URL) {
        open.insert(url)
        for waiter in waiting.removeValue(forKey: url) ?? [] { waiter.resume() }
    }

    func releaseAll() {
        for url in Array(waiting.keys) { release(url) }
    }

    /// Lets every frame through as it is asked for from now on.
    func openAll(_ frames: [Frame]) { for frame in frames { release(frame.url) } }

    func waitUntilWaiting(for count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while waitingFrames < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(waitingFrames >= count)
    }
}

/// The roll's settled Auto decision in the app (docs/research/auto/sequence-consistency.md, "Stage 4
/// either way"): provisional aims are each frame's own; one snapshot of the whole roll is resolved
/// once, whatever order the measurements came in, a recipe's measurement before a decode's; the
/// decision is kept and settles the roll again on reopen, its failures measured again; a replaced raw,
/// a failure and Rebalance Roll behave as the plan says; a develop waits for it and records its
/// revision; a manual pin waits for it and never moves with it.
@MainActor @Suite(.serialized) struct AutoDecisionStateTests {
    /// Five frames ten seconds apart, one cluster, then three more after ten minutes, another.
    static let names = (1...8).map { "DSC0\($0).ARW" }
    static let levels: [Float] = [-1.0, 0.2, -0.4, 0.8, 0.0, 1.2, -0.6, 0.3]

    static func analysis(_ index: Int, shift: Float = 0) -> ExposureAnalysis {
        let level = levels[index] + shift
        return ExposureAnalysis(meanStops: level, validWeight: 1, grayEstimate: [0.1 * Float(index % 3), 0, -0.05 * level])
    }

    @MainActor struct Fixture {
        let folder: URL
        let roll: URL
        let stocks: URL
        let library: URL
        /// Every model made, so `withRoll` waits for what they still write before the folder goes.
        let made = Made()

        @MainActor final class Made {
            var models: [RollModel] = []
        }

        /// A model keeping its decisions, recipes and flags in the fixture's library, or in `library`.
        func model(library: URL? = nil) -> RollModel {
            let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                                  stocksDirectory: stocks, decisions: AutoDecisionStore(library: library ?? self.library),
                                  flagStore: FlagStore(library: library ?? self.library), recipeLibrary: library ?? self.library,
                                  previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
            made.models.append(model)
            return model
        }

        func raw(_ index: Int) -> URL { roll.appendingPathComponent(AutoDecisionStateTests.names[index]) }

        /// Writes frame `index` again, so it is another raw at the same path.
        func replace(_ index: Int) throws {
            try writeSequenceHeader(raw(index), captured: AutoDecisionStateTests.captured(index), iso: 400,
                                    tail: Data(UUID().uuidString.utf8))
        }
    }

    static func captured(_ index: Int) -> String {
        let seconds = index < 5 ? 10 * index : 600 + 10 * index
        return String(format: "2026:10:21 10:%02d:%02d", seconds / 60, seconds % 60)
    }

    /// A roll of `names` with a toy stock and a decision library of its own, all removed after `body`
    /// once its models' balances and decision writes are done: a decision kept as `body` ends would
    /// otherwise be written after the folder is removed, and make it again in the temporary folder.
    static func withRoll(_ body: (Fixture) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-auto-decision-\(UUID().uuidString)")
        let fixture = Fixture(folder: folder, roll: folder.appendingPathComponent("Roll"), stocks: folder.appendingPathComponent("Stocks"),
                              library: folder.appendingPathComponent("Library"))
        try FileManager.default.createDirectory(at: fixture.roll, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in names.indices {
            try writeSequenceHeader(fixture.raw(index), captured: captured(index), tail: Data(UUID().uuidString.utf8))
        }
        try writeToyStock("toy", in: fixture.stocks)
        var failure: (any Error)?
        do { try await body(fixture) } catch { failure = error }
        for model in fixture.made.models {
            await model.balanceTask?.value
            await model.decisionSave?.value
        }
        if let failure { throw failure }
    }

    static func writeToyStock(_ id: String, in stocks: URL) throws {
        let stock = stocks.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: stock, withIntermediateDirectories: true)
        let lut = LUT3D.identity(size: 2)
        try lut.binaryData().write(to: stock.appendingPathComponent("negative.lut3d"))
        try lut.binaryData().write(to: stock.appendingPathComponent("print.lut3d"))
        let manifest: [String: Any] = [
            "schema": 2, "id": id, "displayName": id.capitalized, "status": "synthetic", "boxSpeed": 400, "densityRange": 2.5,
            "negative": ["file": "negative.cube", "binary": "negative.lut3d", "size": 2,
                         "logEncoding": ["stopsBelowMidGray": 8, "stopsAboveMidGray": 5, "midGray": 0.18]],
            "print": ["file": "print.cube", "binary": "print.lut3d", "size": 2, "exposurePerUnit": [0.8, 0.8, 0.8]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: stock.appendingPathComponent(Stock.manifestName))
    }

    /// Opens the fixture's roll in `model`, measured through `gate`, and waits for its saved choices.
    static func open(_ fixture: Fixture, in model: RollModel, through gate: MeasurementGate) async throws {
        for (index, name) in names.enumerated() { gate.analyses[name] = gate.analyses[name] ?? analysis(index) }
        model.measureFrame = { await gate.measure($0) }
        await model.open(fixture.roll)
        if let restoration = model.manualRestoreTask { await restoration.value }
        _ = try #require(model.films)
    }

    static func close(_ model: RollModel, _ gate: MeasurementGate) {
        model.stopDevelop()
        model.analysisTask?.cancel()
        gate.releaseAll()
        model.clearManualSession()
    }

    /// Bit for bit.
    static func bits(_ aim: PrintAim) -> [UInt32] {
        [aim.level.bitPattern, aim.cast.x.bitPattern, aim.cast.y.bitPattern, aim.cast.z.bitPattern]
    }

    static func bits(_ aims: [URL: PrintAim], _ frames: [Frame]) -> [[UInt32]] {
        frames.map { aims[$0.url].map(bits) ?? [] }
    }

    /// A shuffle of `0..<count` from `seed`, the same on every run.
    static func order(_ count: Int, seed: UInt64) -> [Int] {
        var state = seed, order = Array(0..<count)
        for i in stride(from: count - 1, to: 0, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            order.swapAt(i, Int(state >> 33) % (i + 1))
        }
        return order
    }

    @Test func anyMeasurementOrderSettlesOnceOnTheSameAims() async throws {
        try await Self.withRoll { fixture in
            // A raw's revision fingerprint is its SHA-256 once `SourceDigests` keeps it, which it does
            // only for a raw read whole two seconds or more after it was written, and else its stamp
            // (`AutoDecisions.Identity`): every raw is read past that first, as an open of old raws
            // reads them, so a stall in this test cannot give one order stamps and another digests.
            try await Task.sleep(for: .seconds(2.2))
            for index in Self.names.indices { _ = try SourceDigests.shared.digest(of: fixture.raw(index)) }
            var settled: [[[UInt32]]] = [], revisions: [String] = []
            for seed: UInt64 in [1, 7, 20_261_022] {
                // A library each, so no order finds the decision another kept.
                let model = fixture.model(library: fixture.folder.appendingPathComponent("Library \(seed)")), gate = MeasurementGate()
                var published: [String] = []
                model.observeAutoDecision = { published.append($0.revision) }
                try await Self.open(fixture, in: model, through: gate)
                defer { Self.close(model, gate) }
                let frames = try #require(model.roll?.frames)
                try await gate.waitUntilWaiting(for: frames.count)
                #expect(!model.isBalancing && !RollHeading.subtitle(model).contains("Balancing roll"))

                for (step, index) in Self.order(frames.count, seed: seed).enumerated() {
                    gate.release(frames[index].url)
                    while !model.isMeasured(frames[index]) { await Task.yield() }
                    guard step < frames.count - 1 else { break }
                    // Until the roll settles, each measured frame shows its own aim, and nothing is published.
                    for frame in frames {
                        let own = model.analysis(for: frame).map(AutoDecisions.ownAim)
                        #expect(model.printAims[frame.url] == own, "\(frame.name) after \(step + 1) measured")
                    }
                    #expect(!model.isBalanced && model.autoDecision == nil && published.isEmpty)
                    #expect(model.isBalancing && RollHeading.subtitle(model).hasSuffix("· Balancing roll…"))
                }
                let decision = try #require(await model.settledDecision())
                #expect(model.isBalanced && !model.isBalancing && !RollHeading.subtitle(model).contains("Balancing roll"))
                #expect(published == [decision.revision] && decision.record.frames.allSatisfy { $0.sha256 != nil })
                // Roll smoothing as shipped, over the whole roll measured, is the control's decision.
                let analyses = Dictionary(uniqueKeysWithValues: frames.enumerated().map { ($1.url, Self.analysis($0)) })
                #expect(Self.bits(model.printAims, frames) == Self.bits(RollSmoothing.aims(frames, analyses: analyses), frames))
                settled.append(Self.bits(model.printAims, frames))
                revisions.append(decision.revision)
                // Nothing more is published once settled.
                try await Task.sleep(for: .milliseconds(50))
                #expect(published.count == 1)
            }
            #expect(Set(revisions).count == 1)
            #expect(settled.allSatisfy { $0 == settled[0] })
        }
    }

    @Test func aKeptDecisionSettlesTheRollAgainWithoutBalancing() async throws {
        try await Self.withRoll { fixture in
            let first = fixture.model(), gate = MeasurementGate()
            try await Self.open(fixture, in: first, through: gate)
            gate.openAll(try #require(first.roll?.frames))
            let decision = try #require(await first.settledDecision())
            await first.decisionSave?.value
            let kept = try #require(AutoDecisionStore(library: fixture.library).record(for: fixture.roll))
            #expect(kept == decision.record)
            Self.close(first, gate)

            // Opened again: settled at once on the kept decision, while its frames are not yet measured.
            let again = fixture.model(), waiting = MeasurementGate()
            var published: [String] = []
            again.observeAutoDecision = { published.append($0.revision) }
            try await Self.open(fixture, in: again, through: waiting)
            defer { Self.close(again, waiting) }
            let frames = try #require(again.roll?.frames)
            #expect(again.isBalanced && again.autoDecision?.revision == decision.revision && published == [decision.revision])
            #expect(again.analyses.isEmpty && !again.isBalancing)
            #expect(Self.bits(again.printAims, frames) == Self.bits(decision.aims, frames))

            // Measured again, differently (another decode of the same raws): the kept decision stands.
            for (index, name) in Self.names.enumerated() { waiting.analyses[name] = Self.analysis(index, shift: 0.25) }
            try await waiting.waitUntilWaiting(for: frames.count)
            waiting.releaseAll()
            while again.analyses.count < frames.count { await Task.yield() }
            #expect(again.isBalanced && published == [decision.revision])
            #expect(Self.bits(again.printAims, frames) == Self.bits(decision.aims, frames))
        }
    }

    @Test func ratingChangesOnReopenWaitForAllMeasurementsBeforeReplacingTheKeptDecision() async throws {
        try await Self.withRoll { fixture in
            let first = fixture.model(), gate = MeasurementGate()
            try await Self.open(fixture, in: first, through: gate)
            gate.openAll(try #require(first.roll?.frames))
            let kept = try #require(await first.settledDecision())
            await first.decisionSave?.value
            Self.close(first, gate)

            let again = fixture.model(), waiting = MeasurementGate()
            var published: [String] = []
            again.observeAutoDecision = { published.append($0.revision) }
            try await Self.open(fixture, in: again, through: waiting)
            defer { Self.close(again, waiting) }
            let frames = try #require(again.roll?.frames)
            try await waiting.waitUntilWaiting(for: frames.count)
            waiting.release(frames[0].url)
            while !again.isMeasured(frames[0]) { await Task.yield() }
            try #require(again.isBalanced && again.autoDecision?.revision == kept.revision)
            try #require(frames.dropFirst().allSatisfy { !again.isMeasured($0) })

            again.controls.ratedAt = .oneStopUnder
            #expect(!again.isBalanced && published == [kept.revision])
            #expect(again.printAim(for: frames[0]) == kept.aims[frames[0].url])
            await again.decisionSave?.value
            let store = AutoDecisionStore(library: fixture.library)
            #expect(store.record(for: fixture.roll) == kept.record)

            waiting.openAll(frames)
            let next = try #require(await again.settledDecision())
            #expect(next.revision != kept.revision && published == [kept.revision, next.revision])
            #expect(next.failed.isEmpty && next.record.controls?.roll.ratedAt == .oneStopUnder)
            await again.decisionSave?.value
            #expect(store.record(for: fixture.roll) == next.record)
        }
    }

    @Test func aReplacedRawMakesANewRevision() async throws {
        try await Self.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            var published: [String] = []
            model.observeAutoDecision = { published.append($0.revision) }
            try await Self.open(fixture, in: model, through: gate)
            defer { Self.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            gate.openAll(frames)
            let before = try #require(await model.settledDecision())

            gate.analyses[Self.names[1]] = Self.analysis(1, shift: 1)
            try fixture.replace(1)
            #expect(model.forgetChangedSources())
            #expect(!model.isBalanced && model.analysis(for: frames[1]) == nil)
            // The other frames keep their settled aims meanwhile, and the replaced one has none.
            for (index, frame) in frames.enumerated() where index != 1 {
                #expect(model.printAims[frame.url] == before.aims[frame.url])
            }
            #expect(model.printAims[frames[1].url] == nil)

            let after = try #require(await model.settledDecision())
            #expect(after.revision != before.revision && published == [before.revision, after.revision])
            #expect(after.record.frames[1].stamp == SourceStamp.of(fixture.raw(1)))
            await model.decisionSave?.value
            #expect(AutoDecisionStore(library: fixture.library).record(for: fixture.roll)?.revision == after.revision)
        }
    }

    @Test func aFailedFrameLetsTheRollSettleAtTheFallbackUntilRebalanced() async throws {
        try await Self.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            gate.failing = [Self.names[2]]
            var published: [String] = []
            model.observeAutoDecision = { published.append($0.revision) }
            try await Self.open(fixture, in: model, through: gate)
            defer { Self.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            gate.openAll(frames)
            let decision = try #require(await model.settledDecision())
            #expect(model.measurementFailures.keys.sorted { $0.path < $1.path } == [frames[2].url])
            #expect(model.analyses.count == frames.count - 1 && model.isMeasured(frames[2]))
            #expect(decision.aims[frames[2].url] == PrintAim() && model.printAim(for: frames[2]) == PrintAim())
            #expect(decision.record.frames[2].status == .failed && decision.record.frames[2].initial == nil)
            #expect(model.menuState.canRebalance)

            // Rebalance Roll measures it again; now readable, it joins a new revision.
            gate.failing = []
            model.rebalanceRoll()
            #expect(!model.isBalanced && !model.menuState.canRebalance)
            let rebalanced = try #require(await model.settledDecision())
            #expect(model.measurementFailures.isEmpty && rebalanced.record.frames[2].status == .measured)
            #expect(rebalanced.revision != decision.revision && published == [decision.revision, rebalanced.revision])

            // Rebalanced again on the same measurements, it is the same revision.
            model.rebalanceRoll()
            let same = try #require(await model.settledDecision())
            #expect(same.revision == rebalanced.revision && Self.bits(same.aims, frames) == Self.bits(rebalanced.aims, frames))
        }
    }

    @Test func aKeptFailureIsMeasuredAgainOnOpenAndBalancesTheRollOnceItMeasures() async throws {
        try await Self.withRoll { fixture in
            let first = fixture.model(), gate = MeasurementGate()
            gate.failing = [Self.names[2]]
            try await Self.open(fixture, in: first, through: gate)
            let frames = try #require(first.roll?.frames)
            gate.openAll(frames)
            let decision = try #require(await first.settledDecision())
            #expect(decision.failed == [frames[2].url] && decision.aims[frames[2].url] == PrintAim())
            await first.decisionSave?.value
            Self.close(first, gate)

            // Opened again while it still fails: measured again, it keeps the fallback, and the kept
            // decision stands.
            let still = fixture.model(), failing = MeasurementGate()
            failing.failing = [Self.names[2]]
            var kept: [String] = []
            still.observeAutoDecision = { kept.append($0.revision) }
            try await Self.open(fixture, in: still, through: failing)
            #expect(still.isBalanced && still.autoDecision?.failed == [frames[2].url] && kept == [decision.revision])
            try await failing.waitUntilWaiting(for: frames.count)
            failing.releaseAll()
            while !frames.allSatisfy(still.isMeasured) { await Task.yield() }
            #expect(Set(still.measurementFailures.keys) == [frames[2].url])
            #expect(still.isBalanced && kept == [decision.revision] && still.printAim(for: frames[2]) == PrintAim())
            #expect(Self.bits(still.printAims, frames) == Self.bits(decision.aims, frames))
            Self.close(still, failing)

            // Opened once it reads: it shows its own aim as soon as it is measured, the other frames
            // their settled ones, and the roll balances again into a new revision, which is kept.
            let again = fixture.model(), readable = MeasurementGate()
            var published: [String] = []
            again.observeAutoDecision = { published.append($0.revision) }
            try await Self.open(fixture, in: again, through: readable)
            defer { Self.close(again, readable) }
            #expect(again.isBalanced && again.autoDecision?.revision == decision.revision)
            try await readable.waitUntilWaiting(for: frames.count)
            readable.release(frames[2].url)
            while again.analysis(for: frames[2]) == nil { await Task.yield() }
            #expect(!again.isBalanced && again.isBalancing)
            #expect(again.printAims[frames[2].url] == AutoDecisions.ownAim(Self.analysis(2)))
            for (index, frame) in frames.enumerated() where index != 2 {
                #expect(again.printAims[frame.url] == decision.aims[frame.url], "\(frame.name)")
            }
            readable.releaseAll()
            let rebalanced = try #require(await again.settledDecision())
            #expect(rebalanced.revision != decision.revision && rebalanced.failed.isEmpty)
            #expect(rebalanced.record.frames[2].status == .measured && published == [decision.revision, rebalanced.revision])
            let analyses = Dictionary(uniqueKeysWithValues: frames.enumerated().map { ($1.url, Self.analysis($0)) })
            #expect(Self.bits(again.printAims, frames) == Self.bits(RollSmoothing.aims(frames, analyses: analyses), frames))
            await again.decisionSave?.value
            #expect(AutoDecisionStore(library: fixture.library).record(for: fixture.roll)?.revision == rebalanced.revision)
        }
    }

    /// A frame the kept decision printed at the fallback whose recipe the next open finds, so that it
    /// is not measured again, is a new input all the same: the roll balances again once its choices
    /// are restored.
    @Test func aKeptFailureARecipeMeasuresOnOpenBalancesTheRollAgain() async throws {
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.8, 0.8), negative: LUT3D.identity(size: 2), print: LUT3D.identity(size: 2))
        let recipes = Self.analysis(2, shift: -0.7)
        try await Self.withRoll { fixture in
            let first = fixture.model(), gate = MeasurementGate()
            gate.failing = [Self.names[2]]
            try await Self.open(fixture, in: first, through: gate)
            let frames = try #require(first.roll?.frames)
            gate.openAll(frames)
            let decision = try #require(await first.settledDecision())
            #expect(decision.failed == [frames[2].url])
            await first.decisionSave?.value
            Self.close(first, gate)

            // Its recipe, beside it, has its measurement, and its raw has been read whole since, so the
            // open finds the measurement without reading it (`RecipeStore.Check.knownOnly`).
            let raw = await RollScanner.scan(fixture.roll).frames[2]
            var recipe = Recipe(frame: raw, byteCount: RecipeStore.byteCount(of: raw.url), stock: stock,
                                stockDigest: stock.digest, roll: RollControls(), own: FrameControls(), analysis: recipes)
            recipe.raw.sha256 = SHA256.hash(data: try Data(contentsOf: raw.url)).map { String(format: "%02x", $0) }.joined()
            try recipe.encoded().write(to: RecipeStore.besideRaw(raw.url))
            try await Task.sleep(for: .seconds(2.2))
            #expect(try SourceDigests.shared.digest(of: raw.url).sha256 == recipe.raw.sha256)

            let again = fixture.model(), readable = MeasurementGate()
            var published: [String] = []
            again.observeAutoDecision = { published.append($0.revision) }
            try await Self.open(fixture, in: again, through: readable)
            defer { Self.close(again, readable) }
            #expect(again.analysis(for: frames[2]) == recipes && published == [decision.revision])
            #expect(!again.isBalanced && again.printAims[frames[2].url] == AutoDecisions.ownAim(recipes))
            for (index, frame) in frames.enumerated() where index != 2 {
                #expect(again.printAims[frame.url] == decision.aims[frame.url], "\(frame.name)")
            }
            readable.openAll(frames)
            let rebalanced = try #require(await again.settledDecision())
            #expect(rebalanced.revision != decision.revision && rebalanced.failed.isEmpty)
            #expect(rebalanced.record.frames[2].initial == AutoPrint.levelStops(recipes))
            #expect(published == [decision.revision, rebalanced.revision])
        }
    }

    /// A recipe's measurement of a raw outranks the one its decode gives, whichever arrives first:
    /// here the frame's sidecar, which the open does not check, since that would read the raw whole,
    /// and the restore of the roll's choices does. Each order on a roll of its own, whose raws no
    /// digest knows yet. (The library's journal reaches the same restore; the test keeps out of the
    /// owner's library.)
    @Test func aRecipesMeasurementOutranksTheDecodesWhicheverArrivesFirst() async throws {
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.8, 0.8), negative: LUT3D.identity(size: 2), print: LUT3D.identity(size: 2))
        let recipes = Self.analysis(2, shift: -0.7)
        try await Self.withRoll { decodeFirst in
            try await Self.withRoll { restoreFirst in
                for fixture in [decodeFirst, restoreFirst] {
                    let raw = await RollScanner.scan(fixture.roll).frames[2]
                    var recipe = Recipe(frame: raw, byteCount: RecipeStore.byteCount(of: raw.url), stock: stock,
                                        stockDigest: stock.digest, roll: RollControls(), own: FrameControls(), analysis: recipes)
                    recipe.raw.sha256 = SHA256.hash(data: try Data(contentsOf: raw.url)).map { String(format: "%02x", $0) }.joined()
                    try recipe.encoded().write(to: RecipeStore.besideRaw(raw.url))
                }
                // A raw read within 2 s of its last change has its digest read again next time, not
                // kept (`SourceDigests`), and the restore would leave its recipe's measurement out.
                try await Task.sleep(for: .seconds(2.2))
                var settled: [[[UInt32]]] = []
                for (fixture, decodeArrivesFirst) in [(decodeFirst, true), (restoreFirst, false)] {
                    let model = fixture.model(), gate = MeasurementGate()
                    for (index, name) in Self.names.enumerated() { gate.analyses[name] = Self.analysis(index) }
                    model.measureFrame = { await gate.measure($0) }
                    await model.open(fixture.roll)
                    defer { Self.close(model, gate) }
                    let frames = try #require(model.roll?.frames)
                    #expect(model.analysis(for: frames[2]) == nil && model.manualRestoreTask != nil)
                    if decodeArrivesFirst {
                        // Its decode's measurement arrives while the restore reads the recipes.
                        let source = try #require(SourceStamp.of(frames[2].url))
                        model.record(FrameMeasurement(analysis: Self.analysis(2), source: source), for: frames[2])
                        #expect(model.analysis(for: frames[2]) == Self.analysis(2))
                    }
                    if let restoration = model.manualRestoreTask { await restoration.value }
                    #expect(model.analysis(for: frames[2]) == recipes)
                    gate.openAll(frames)
                    let decision = try #require(await model.settledDecision())
                    #expect(model.analysis(for: frames[2]) == recipes && decision.record.frames[2].initial == AutoPrint.levelStops(recipes))
                    var analyses = Dictionary(uniqueKeysWithValues: frames.enumerated().map { ($1.url, Self.analysis($0)) })
                    analyses[frames[2].url] = recipes
                    #expect(Self.bits(decision.aims, frames) == Self.bits(RollSmoothing.aims(frames, analyses: analyses), frames))
                    settled.append(Self.bits(decision.aims, frames))
                }
                #expect(settled.count == 2 && settled[0] == settled[1])
            }
        }
    }

    @Test func aDevelopWaitsForTheSettledDecisionAndPrintsItsAims() async throws {
        try await Self.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            var captured: [RollDeveloper.Job] = []
            model.observeDevelopJobs = { jobs in
                captured = jobs
                // Stopped before any frame: a develop run to its end needs the app's bundle.
                model.stopDevelop()
            }
            try await Self.open(fixture, in: model, through: gate)
            defer { Self.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            try await gate.waitUntilWaiting(for: frames.count)
            gate.release(frames[0].url)
            while !model.isMeasured(frames[0]) { await Task.yield() }

            model.startDevelop(to: fixture.folder.appendingPathComponent("Export"))
            let developing = try #require(model.developTask)
            let deadline = ContinuousClock.now + .seconds(10)
            while !model.isDevelopBalancing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.isDevelopBalancing && captured.isEmpty)
            #expect(!RollHeading.subtitle(model).contains("Balancing roll"))

            gate.releaseAll()
            gate.openAll(frames)
            await developing.value
            let decision = try #require(model.autoDecision)
            #expect(model.isBalanced && !model.isDevelopBalancing)
            #expect(captured.count == frames.count && captured.allSatisfy { $0.autoRevision == decision.revision })
            // The develop prints what the sheet shows at the same revision.
            let stock = model.stockIndex
            for job in captured {
                let preview = Recipe.Render(settings: model.settings(for: job.frame, stock: stock), grain: model.output.grain)
                #expect(job.recipe.render == preview, "\(job.frame.name)")
                #expect(job.recipe.printLevel == decision.aims[job.frame.url]?.level)
            }
            #expect(model.lastDevelop?.wasStopped == true && model.developPhase == .idle)
        }
    }

    @Test func aDevelopKeepsItsRatingWhenTheSheetRebalancesWhileItWaits() async throws {
        try await Self.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            var jobs: [RollDeveloper.Job] = []
            model.observeDevelopJobs = { made in
                jobs = made
                model.stopDevelop()
            }
            try await Self.open(fixture, in: model, through: gate)
            defer { Self.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            try await gate.waitUntilWaiting(for: frames.count)
            let capturedControls = model.controls
            model.startDevelop(to: fixture.folder.appendingPathComponent("Export"))
            let developing = try #require(model.developTask)
            let deadline = ContinuousClock.now + .seconds(10)
            while !model.isDevelopBalancing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(model.isDevelopBalancing)

            model.controls.ratedAt = .oneStopUnder
            gate.openAll(frames)
            await developing.value

            let sheet = try #require(model.autoDecision)
            #expect(sheet.record.controls?.roll.ratedAt == .oneStopUnder)
            try #require(jobs.count == frames.count)
            #expect(jobs.allSatisfy { $0.autoRevision != sheet.revision })

            model.controls = capturedControls
            let captured = try #require(await model.settledDecision())
            for job in jobs {
                let preview = Recipe.Render(settings: model.settings(for: job.frame, stock: model.stockIndex), grain: model.output.grain)
                #expect(job.autoRevision == captured.revision)
                #expect(job.recipe.render == preview, "\(job.frame.name)")
            }
        }
    }

    @Test func theFirstPinWaitsForTheSettledDecisionAndIsNeverRebased() async throws {
        try await Self.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            gate.failing = [Self.names[3]]
            try await Self.open(fixture, in: model, through: gate)
            defer { Self.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            let frame = frames[0], stock = model.stockIndex
            try await gate.waitUntilWaiting(for: frames.count)
            gate.release(frame.url)
            while !model.isMeasured(frame) { await Task.yield() }
            model.manualReadySources[frame.url] = try SourceDigests.shared.digest(of: frame.url)
            #expect(model.manualLoaded.contains(frame.url))
            let shown = model.printAim(for: frame)
            model.recordVisibleAutomatic(for: frame, stock: stock, aim: shown, settings: model.settings(for: frame, stock: stock))
            let edit = try ManualAdjustments(exposureEV: 0.5)
            // Not while the roll is balancing: the pin would hold an aim it is about to leave.
            #expect(!model.canAdjust(frame))
            model.beginManualGesture(for: frame)
            model.setManualAdjustments(edit, for: frame)
            #expect(model.manualEdits[frame.url] == nil)

            gate.openAll(frames)
            let decision = try #require(await model.settledDecision())
            let settledAim = try #require(decision.aims[frame.url])
            #expect(settledAim != shown)
            // Nor on the film shown at the frame's own aim, until the settled one is up.
            #expect(!model.canAdjust(frame))
            model.recordVisibleAutomatic(for: frame, stock: stock, aim: model.printAim(for: frame),
                                         settings: model.settings(for: frame, stock: stock))
            #expect(model.canAdjust(frame))
            model.setManualAdjustments(edit, for: frame)
            let pin = try #require(model.manualEdits[frame.url]?.baseline)
            #expect(pin.aim == settledAim && !model.hasUpdatedAuto(frame))

            // A new revision moves the frame's Auto aim; its pin stays.
            gate.failing = []
            model.rebalanceRoll()
            let moved = try #require(await model.settledDecision())
            #expect(moved.revision != decision.revision && moved.aims[frame.url] != settledAim)
            #expect(model.manualEdits[frame.url]?.baseline == pin)
            #expect(model.hasUpdatedAuto(frame))
        }
    }
}
