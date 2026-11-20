import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// Presence through the model (docs/presence-plan.md, section 3): Light's gesture and its print-only lane, the release, undo, the
/// save, Update Automatic Baseline, and the two resets, a drag held through them included.
@MainActor @Suite(.serialized) struct PresenceModelTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    /// A roll of one frame with an edit pinned on it, as `ManualStateTests` makes one.
    private func fixture(_ values: ManualAdjustments) async throws -> (RollModel, Frame, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-presence-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        let frame = try #require(model.selectedFrame)
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest", controls: .init(),
                                    aim: PrintAim(level: -0.65), analysisVersion: ExposureAnalysis.currentVersion,
                                    baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        model.manualEdits[frame.url] = ManualEdit(adjustments: values, baseline: pin)
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        return (model, frame, folder)
    }

    /// One undo group, as one event of the app makes.
    private func step(_ model: RollModel, _ action: () -> Void) {
        model.manualUndoManager?.beginUndoGrouping()
        action()
        model.manualUndoManager?.endUndoGrouping()
    }

    @Test func resetPresenceClearsTheFiveInOneUndoStepAndResetLightLeavesThem() async throws {
        let presence = try Presence([.clarity: 30, .vibrance: -20])
        let (model, frame, folder) = try await fixture(try ManualAdjustments(exposureEV: 0.5, shadows: 40, presence: presence))
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(model.manualEdits[frame.url])
        model.manualUndoManager?.beginUndoGrouping()
        model.resetLight(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).presence == presence && model.manualAdjustments(for: frame).exposureEV == 0)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before)
        model.manualUndoManager?.beginUndoGrouping()
        model.resetPresence(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(exposureEV: 0.5, shadows: 40)))
        #expect(model.manualEdits[frame.url]?.baseline == before.baseline)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before && model.manualUndoManager?.canUndo == false)
        // Nothing left to clear is no undo step.
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 0.5)
        model.resetPresence(for: frame)
        #expect(model.manualUndoManager?.canUndo == false)
    }

    /// A Presence row's drag rides Light's lane: its steps reach the print alone, and its release writes them over the edit as one
    /// undo step. A value outside Light's six was lost twice on that lane, unprinted and unwritten.
    @Test func aPresenceDragPrintsAndIsWrittenAtRelease() async throws {
        let (model, frame, folder) = try await fixture(try ManualAdjustments(exposureEV: 0.5, shadows: 40))
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(model.manualEdits[frame.url])
        model.manualUndoManager?.beginUndoGrouping()
        model.beginLightAdjusting(for: frame)
        model.moveLight(.presence(.clarity), to: 20, for: frame)
        model.moveLight(.presence(.clarity), to: 35, for: frame)
        model.moveLight(.presence(.vibrance), to: -15, for: frame)
        model.moveLight(.light(.exposure), to: 0.75, for: frame)
        #expect(model.manualEdits[frame.url] == before, "the steps reach the print alone")
        let printed = try #require(model.printedEdit(for: frame))
        #expect(printed.adjustments == (try ManualAdjustments(exposureEV: 0.75, shadows: 40, presence: Presence([.clarity: 35, .vibrance: -15]))))
        #expect(printed.baseline == before.baseline)
        model.endLightAdjusting(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        let written = try ManualAdjustments(exposureEV: 0.75, shadows: 40, presence: Presence([.clarity: 35, .vibrance: -15]))
        #expect(model.manualAdjustments(for: frame) == written && model.manualEdits[frame.url]?.baseline == before.baseline)
        #expect(model.printedLight == nil && model.printedEdit(for: frame) == model.manualEdits[frame.url])
        #expect(model.manualUndoManager?.undoActionName == "Adjust Frame")
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before && model.manualUndoManager?.canUndo == false, "one undo step")
        model.manualUndoManager?.redo()
        #expect(model.manualAdjustments(for: frame) == written)
    }

    /// A Presence slider moves through the Light tab's gesture: outside a drag it writes the edit at once.
    @Test func aPresenceSliderMovesThroughTheLightGesture() async throws {
        let (model, frame, folder) = try await fixture(try ManualAdjustments(exposureEV: 0.5))
        defer { try? FileManager.default.removeItem(at: folder) }
        model.manualUndoManager?.beginUndoGrouping()
        model.moveLight(.presence(.dehaze), to: 25, for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).presence.dehaze == 25 && model.manualAdjustments(for: frame).exposureEV == 0.5)
    }

    // MARK: A reset while a Light-tab drag is held (docs/presence-plan.md, section 3)

    /// Reset Light with a drag held clears the six, and the drag's pending values do not write them back as it ends. What the drag
    /// sets after the reset is shown and written at its release, as a step of its own.
    @Test func resetLightWithADragHeldClearsTheSixForGood() async throws {
        let presence = try Presence([.clarity: 30, .vibrance: -20])
        let start = try ManualAdjustments(exposureEV: 0.5, shadows: 40, presence: presence)
        let (model, frame, folder) = try await fixture(start)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A Presence row held: what the print holds pending under its Clarity is Light's six as they were.
        model.beginLightAdjusting(for: frame)
        model.moveLight(.presence(.clarity), to: 45, for: frame)
        step(model) { model.resetLight(for: frame) }
        let cleared = try ManualAdjustments(presence: Presence([.clarity: 45, .vibrance: -20]))
        #expect(model.manualAdjustments(for: frame) == cleared && model.printedEdit(for: frame) == model.manualEdits[frame.url])
        step(model) { model.endLightAdjusting(for: frame) }
        #expect(model.manualAdjustments(for: frame) == cleared, "the six stay cleared when the drag ends")
        #expect(model.printedLight == nil && model.manualGestures[frame.url] == nil)

        // A Light row held: after the reset its steps print over the cleared six, and its release writes them.
        model.manualEdits[frame.url]?.adjustments = start
        let before = try #require(model.manualEdits[frame.url])
        model.beginLightAdjusting(for: frame)
        model.moveLight(.light(.exposure), to: 1, for: frame)
        step(model) { model.resetLight(for: frame) }
        let reset = try #require(model.manualEdits[frame.url])
        #expect(reset.adjustments == (try ManualAdjustments(presence: presence)))
        model.moveLight(.light(.exposure), to: 1.25, for: frame)
        #expect(model.printedEdit(for: frame)?.adjustments == (try ManualAdjustments(exposureEV: 1.25, presence: presence)), "shown")
        #expect(model.manualEdits[frame.url] == reset, "on the print alone until the release")
        step(model) { model.endLightAdjusting(for: frame) }
        #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(exposureEV: 1.25, presence: presence)), "written")
        #expect(model.printedLight == nil && model.manualGestures[frame.url] == nil)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == reset, "the rest of the drag is a step of its own")
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before)
    }

    /// Reset Presence with a drag held clears the five, and the drag's pending values do not write them back as it ends. What the
    /// drag sets after the reset is shown and written at its release, as a step of its own.
    @Test func resetPresenceWithADragHeldClearsTheFiveForGood() async throws {
        let start = try ManualAdjustments(exposureEV: 0.5, shadows: 40, presence: Presence([.clarity: 30, .vibrance: -20]))
        let (model, frame, folder) = try await fixture(start)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A Light row held: what the print holds pending under its Exposure is Presence's five as they were.
        model.beginLightAdjusting(for: frame)
        model.moveLight(.light(.exposure), to: 1, for: frame)
        step(model) { model.resetPresence(for: frame) }
        let cleared = try ManualAdjustments(exposureEV: 1, shadows: 40)
        #expect(model.manualAdjustments(for: frame) == cleared && model.printedEdit(for: frame) == model.manualEdits[frame.url])
        step(model) { model.endLightAdjusting(for: frame) }
        #expect(model.manualAdjustments(for: frame) == cleared, "the five stay cleared when the drag ends")
        #expect(model.printedLight == nil && model.manualGestures[frame.url] == nil)

        // A Presence row held: after the reset its steps print over the cleared five, and its release writes them.
        model.manualEdits[frame.url]?.adjustments = start
        let before = try #require(model.manualEdits[frame.url])
        model.beginLightAdjusting(for: frame)
        model.moveLight(.presence(.clarity), to: 45, for: frame)
        step(model) { model.resetPresence(for: frame) }
        let reset = try #require(model.manualEdits[frame.url])
        #expect(reset.adjustments == (try ManualAdjustments(exposureEV: 0.5, shadows: 40)))
        model.moveLight(.presence(.clarity), to: 10, for: frame)
        let moved = try ManualAdjustments(exposureEV: 0.5, shadows: 40, presence: Presence([.clarity: 10]))
        #expect(model.printedEdit(for: frame)?.adjustments == moved, "shown")
        #expect(model.manualEdits[frame.url] == reset, "on the print alone until the release")
        step(model) { model.endLightAdjusting(for: frame) }
        #expect(model.manualAdjustments(for: frame) == moved, "written")
        #expect(model.printedLight == nil && model.manualGestures[frame.url] == nil)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == reset, "the rest of the drag is a step of its own")
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before)
    }

    // MARK: On a roll whose Auto has settled

    /// Opens the fixture's roll with every frame measured and its Auto settled, and the first frame's Auto on screen.
    private func withSettledFrame(_ body: (AutoDecisionStateTests.Fixture, RollModel, Frame) async throws -> Void) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames), frame = frames[0]
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            await model.prepareManualAdjustments(for: frame)
            let stock = model.stockIndex
            model.recordVisibleAutomatic(for: frame, stock: stock, aim: model.printAim(for: frame), settings: model.settings(for: frame, stock: stock))
            model.manualUndoManager = UndoManager()
            model.manualUndoManager?.groupsByEvent = false
            try await body(fixture, model, frame)
            try await model.flushManualSaves()
        }
    }

    /// A Presence row's first step on a frame with no edit pins the Auto on screen, as a Light row's does, and the drag is one undo
    /// step. The save writes Presence in a version 7 recipe, and the roll opened again reads it back.
    @Test func aPresenceDragsFirstStepPinsAndTheSaveReadsBack() async throws {
        try await withSettledFrame { fixture, model, frame in
            #expect(model.manualEdits[frame.url] == nil && model.canAdjust(frame))
            model.beginLightAdjusting(for: frame)
            model.moveLight(.presence(.texture), to: 25, for: frame)
            let pinned = try #require(model.manualEdits[frame.url], "the first step pins")
            #expect(pinned.adjustments == (try ManualAdjustments(presence: Presence([.texture: 25]))))
            #expect(pinned.baseline.origin == .auto && pinned.baseline.aim == model.printAim(for: frame))
            model.moveLight(.presence(.texture), to: 40, for: frame)
            model.moveLight(.presence(.saturation), to: -30, for: frame)
            step(model) { model.endLightAdjusting(for: frame) }
            let edit = try #require(model.manualEdits[frame.url])
            #expect(edit.adjustments == (try ManualAdjustments(presence: Presence([.texture: 40, .saturation: -30]))))
            #expect(edit.baseline == pinned.baseline)
            model.manualUndoManager?.undo()
            #expect(model.manualEdits[frame.url] == nil && model.manualUndoManager?.canUndo == false, "one step, the pin with it")
            model.manualUndoManager?.redo()
            #expect(model.manualEdits[frame.url] == edit)

            try await model.flushManualSaves()
            let saved = try #require(try await RecipeWriter.shared.load(for: frame, library: model.recipeLibrary))
            #expect(saved.manual == edit && saved.version == 7)
            await model.open(fixture.roll)
            if let restoration = model.manualRestoreTask { await restoration.value }
            #expect(model.manualEdits[frame.url] == edit)
        }
    }

    /// Reset to Current Auto and Reset to Original with a drag held clear every value, and the drag's pending values, Presence's
    /// among them, do not come back as it ends. What the drag sets after the reset is written at its release, from the new start.
    @Test(arguments: [AutomaticBaseline.Origin.auto, .original])
    func aStartingPointResetWithADragHeldClearsForGood(origin: AutomaticBaseline.Origin) async throws {
        try await withSettledFrame { _, model, frame in
            step(model) {
                model.setManualAdjustments(try! ManualAdjustments(exposureEV: 0.5, shadows: 40, presence: Presence([.clarity: 30])), for: frame)
            }
            model.beginLightAdjusting(for: frame)
            model.moveLight(.light(.exposure), to: 1, for: frame)
            step(model) {
                if origin == .auto { model.resetManualAdjustments(for: frame) }
                else { model.startFromOriginal(for: frame, actionName: "Reset to Original") }
            }
            #expect(model.manualAdjustments(for: frame).isIdentity && model.printedLight == nil)
            model.moveLight(.light(.exposure), to: 1.5, for: frame)
            step(model) { model.endLightAdjusting(for: frame) }
            let written = try ManualAdjustments(exposureEV: 1.5)
            #expect(model.manualAdjustments(for: frame) == written)
            #expect(model.startingPoint(for: frame) == origin && model.printedLight == nil && model.manualGestures[frame.url] == nil)
        }
    }

    /// Update Automatic Baseline takes Presence again at the current constants, its values kept, as it does the curves and the
    /// masks: a recipe whose Presence a build with other constants recorded renders after it.
    @Test func updateAutomaticBaselineTakesPresenceAtTheCurrentConstants() async throws {
        try await withSettledFrame { _, model, frame in
            step(model) { model.setManualAdjustments(try! ManualAdjustments(exposureEV: 0.5), for: frame) }
            let recorded = try JSONDecoder().decode(Presence.self, from: Data(
                #"{"version": "2026-12-01-1", "texture": 0, "clarity": 30, "dehaze": 0, "vibrance": 0, "saturation": -10}"#.utf8))
            model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 0.5, presence: recorded)
            #expect(throws: ManualDevelopmentError.self) { try model.settings(for: frame, stock: model.stockIndex).manual.validateSupportedVersion() }

            model.manualUndoManager?.beginUndoGrouping()
            model.updateAutomaticBaseline(for: frame)
            let deadline = ContinuousClock.now + .seconds(20)
            while model.manualAdjustments(for: frame).presence.version == recorded.version, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            model.manualUndoManager?.endUndoGrouping()
            #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(exposureEV: 0.5, presence: Presence([.clarity: 30, .saturation: -10]))))
            try model.settings(for: frame, stock: model.stockIndex).manual.validateSupportedVersion()
        }
    }
}
