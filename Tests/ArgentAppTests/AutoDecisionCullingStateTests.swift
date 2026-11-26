import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct AutoDecisionCullingStateTests {
    @Test func cullingWhileOpenPreservesTheDecisionThroughReopenAndUntilRebalance() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            let frames = try #require(model.roll?.frames), removed = frames[2]
            gate.openAll(frames)
            let original = try #require(await model.settledDecision())
            await model.decisionSave?.value

            try FileManager.default.removeItem(at: removed.url)
            #expect(model.forgetChangedSources())
            #expect(model.isBalanced && model.autoDecision?.revision == original.revision)
            #expect(model.analysis(for: removed) == nil && model.sourceStamp(for: removed) == nil)
            #expect(model.measurementFailures[removed.url] == MeasurementFailure(source: nil))
            // A later failed read must not undo preservation or start a balance.
            model.recordFailure(at: nil, for: removed)
            await model.analyze(removed)
            let remaining = frames.filter { $0.url != removed.url }
            #expect(AutoDecisionStateTests.bits(model.printAims, remaining) == AutoDecisionStateTests.bits(original.aims, remaining))
            await model.decisionSave?.value
            let stored = try #require(model.decisions.record(for: fixture.roll))
            #expect(stored.revision == original.revision && stored.frames.count == remaining.count)
            AutoDecisionStateTests.close(model, gate)

            let again = fixture.model(), waiting = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: again, through: waiting)
            defer { AutoDecisionStateTests.close(again, waiting) }
            #expect(again.isBalanced && again.autoDecision?.revision == original.revision)
            #expect(AutoDecisionStateTests.bits(again.printAims, remaining) == AutoDecisionStateTests.bits(original.aims, remaining))
            waiting.openAll(remaining)
            await again.analysisTask?.value
            #expect(again.isBalanced && again.autoDecision?.revision == original.revision)

            // An explicit Rebalance is a new input snapshot and may change surviving prints.
            again.rebalanceRoll()
            let rebalanced = try #require(await again.settledDecision())
            #expect(rebalanced.revision != original.revision)
            #expect(rebalanced.record.frames.count == remaining.count)
            #expect(remaining.contains { rebalanced.aims[$0.url] != original.aims[$0.url] })
        }
    }

    @Test func reopeningACulledRollSavesMembershipAndAddingAFrameResolvesAgain() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let first = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: first, through: gate)
            let frames = try #require(first.roll?.frames), removed = frames[2]
            gate.openAll(frames)
            let original = try #require(await first.settledDecision())
            await first.decisionSave?.value
            AutoDecisionStateTests.close(first, gate)
            let raw = try Data(contentsOf: removed.url)
            try FileManager.default.removeItem(at: removed.url)

            let culled = fixture.model(), waiting = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: culled, through: waiting)
            #expect(culled.isBalanced && culled.autoDecision?.revision == original.revision)
            let remaining = try #require(culled.roll?.frames)
            #expect(remaining.count == frames.count - 1)
            #expect(AutoDecisionStateTests.bits(culled.printAims, remaining) == AutoDecisionStateTests.bits(original.aims, remaining))
            await culled.decisionSave?.value
            #expect(culled.decisions.record(for: fixture.roll)?.frames.count == remaining.count)
            AutoDecisionStateTests.close(culled, waiting)

            // Even a former member is an addition to the saved membership and must resolve again.
            try raw.write(to: removed.url)
            let added = fixture.model(), measuring = MeasurementGate()
            measuring.analyses[removed.url.lastPathComponent] = AutoDecisionStateTests.analysis(2, shift: 1)
            try await AutoDecisionStateTests.open(fixture, in: added, through: measuring)
            defer { AutoDecisionStateTests.close(added, measuring) }
            #expect(!added.isBalanced && added.autoDecision == nil)
            measuring.openAll(try #require(added.roll?.frames))
            let resolved = try #require(await added.settledDecision())
            #expect(resolved.revision != original.revision && resolved.record.frames.count == frames.count)
        }
    }

    @Test func removingAndReplacingSourcesTogetherStillRebalances() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames)
            gate.openAll(frames)
            let original = try #require(await model.settledDecision())
            try FileManager.default.removeItem(at: frames[2].url)
            try fixture.replace(3)
            gate.failing.insert(frames[2].url.lastPathComponent)
            gate.analyses[frames[3].url.lastPathComponent] = AutoDecisionStateTests.analysis(3, shift: 1)
            #expect(model.forgetChangedSources())
            #expect(!model.isBalanced)
            let resolved = try #require(await model.settledDecision())
            #expect(resolved.revision != original.revision)
            #expect(resolved.failed.contains(frames[2].url))
        }
    }

    @Test func deletingABridgingRawThenChangingRatingKeepsSurvivorsSeparate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-auto-cull-bridge-\(UUID().uuidString)")
        let roll = folder.appendingPathComponent("Roll"), stocks = folder.appendingPathComponent("Stocks")
        let library = folder.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stocks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try AutoDecisionStateTests.writeToyStock("toy", in: stocks)
        let times = ["2026:10:01 12:00:00", "2026:10:01 12:01:30", "2026:10:01 12:03:00"]
        let names = ["DSC01.ARW", "DSC02.ARW", "DSC03.ARW"]
        for i in names.indices {
            try writeSequenceHeader(roll.appendingPathComponent(names[i]), captured: times[i], tail: Data("bridge-\(i)".utf8))
        }
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: stocks, decisions: AutoDecisionStore(library: library),
                              flagStore: FlagStore(library: library), recipeLibrary: library,
                              previewCache: folder.appendingPathComponent("Cache"), digestsFile: nil)
        let gate = MeasurementGate()
        gate.analyses = [
            names[0]: ExposureAnalysis(meanStops: -1.0, validWeight: 1, grayEstimate: [0.2, 0, -0.2]),
            names[1]: ExposureAnalysis(meanStops: 0.0, validWeight: 1, grayEstimate: [0, 0, 0]),
            names[2]: ExposureAnalysis(meanStops: 1.0, validWeight: 1, grayEstimate: [-0.2, 0, 0.2]),
        ]
        model.measureFrame = { await gate.measure($0) }
        await model.open(roll)
        if let restoration = model.manualRestoreTask { await restoration.value }
        defer { AutoDecisionStateTests.close(model, gate) }
        let frames = try #require(model.roll?.frames)
        gate.openAll(frames)
        let original = try #require(await model.settledDecision())
        #expect(original.aims[frames[0].url] != AutoDecisions.ownAim(gate.analyses[names[0]]!))
        #expect(original.aims[frames[2].url] != AutoDecisions.ownAim(gate.analyses[names[2]]!))

        try FileManager.default.removeItem(at: frames[1].url)
        #expect(model.forgetChangedSources())
        #expect(model.isBalanced && model.autoDecision?.aims[frames[1].url] == nil)

        model.controls.ratedAt = .oneStopUnder
        let updated = try #require(await model.settledDecision())
        #expect(updated.record.frames.map(\.fileName) == [names[0], names[2]])
        #expect(updated.aims[frames[1].url] == nil && updated.failed.isEmpty)
        #expect(updated.aims[frames[0].url] == AutoDecisions.ownAim(gate.analyses[names[0]]!))
        #expect(updated.aims[frames[2].url] == AutoDecisions.ownAim(gate.analyses[names[2]]!))
        await model.balanceTask?.value
        await model.decisionSave?.value
    }
}
