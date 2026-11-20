#if DEBUG
@testable import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

/// Remove through the app's own steps (`LiveRemovalSteps`), end to end on the CC0 sample: the real pipeline, the previews' real
/// crop, a `FakeRemovalEngine` in a real `RemovalQueue`, and a real `PatchStore` in the fixture's library. No model runs.
///
/// Off until the packages it calls are merged: package A's `FilmPreviews.removalInput`, package B's `PatchStore.store` and `load`
/// and the recipe writer's pack beside the raw, package C's `RemovalPipeline.plan`, `plan(retrying:)`, `prepare` and `finish`, and
/// package D's `RemovalQueue.run`. Until then each of them throws `RemovalError.notBuilt`.
@MainActor @Suite(.serialized) struct RemoveEndToEndTests {
    @Test(.enabled(if: hasLensGeometrySample)) func aPaintedObjectBecomesAStoredPatchInTheEditAndTheRecipe() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let raw = fixture.raw(0).resolvingSymlinksInPath()
            try cloneLensGeometrySample(to: raw)
            let model = fixture.model(), measurements = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: measurements)
            defer { AutoDecisionStateTests.close(model, measurements) }
            let frames = try #require(model.roll?.frames), frame = frames[0]
            measurements.openAll(frames)
            _ = try #require(await model.settledDecision())
            await model.prepareManualAdjustments(for: frame)
            model.recordVisibleAutomatic(for: frame, stock: model.stockIndex, aim: model.printAim(for: frame),
                                         settings: model.settings(for: frame, stock: model.stockIndex))
            model.manualUndoManager = UndoManager()
            model.manualUndoManager?.groupsByEvent = false
            let engine = FakeRemovalEngine()
            model.removalRuns.steps = LiveRemovalSteps(films: try #require(model.films), library: fixture.library, makeEngine: { engine })
            model.removalRuns.showsTab = true
            model.selection = frame.id
            try #require(model.canAdjust(frame))

            // Painted, so no system model is asked for: a stroke across the middle of the picture, and Return.
            model.removeTabShown(for: frame)
            model.setRemoveSnapsToObject(false)
            model.remove.brushSize = 6
            model.paintRemoval([CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.55, y: 0.5)], on: frame)
            model.commitRemoval(on: frame)
            try #require(model.removalRows(for: frame).count == 1, "the run has its row: \(model.clipboardNotice?.details ?? [])")
            await model.removalsSettled()
            let first = try #require(model.manualAdjustments(for: frame).removals.first, "\(model.clipboardNotice?.details ?? [])")
            #expect(model.manualUndoManager?.undoActionName == "Remove Object" && engine.counts.runs == 1)

            // Its patch is in the library, checked, at the model's size, over a box of the decode around the stroke.
            let store = PatchStore(library: fixture.library)
            let patch = try store.load(first.patch)
            #expect(patch.ref == first.patch && patch.width.isMultiple(of: RemovalPatch.sideMultiple) && patch.height.isMultiple(of: RemovalPatch.sideMultiple))
            #expect(max(patch.width, patch.height) <= RemovalPatch.longSideLimit && !patch.isSoftAtFullSize)
            let width = try #require(patch.notes.frameWidth), height = try #require(patch.notes.frameHeight)
            #expect(patch.box.x + patch.box.width <= width && patch.box.y + patch.box.height <= height)
            #expect(patch.box.x < width / 2 && patch.box.x + patch.box.width > width / 2 && patch.box.y < height / 2 && patch.box.y + patch.box.height > height / 2)
            #expect(patch.notes.engine == FakeRemovalEngine.engineID && patch.notes.steps == RemovalJob.defaultSteps && patch.notes.seed != nil)
            #expect(patch.notes.decoder == model.films?.decoderChoices.choice(for: frame.url).decoderVersion)
            #expect(patch.objectAlpha.contains { $0 >= 128 } && patch.effectsAlpha.contains { $0 >= 128 })
            let row = try #require(model.removalRows(for: frame).first)
            #expect(row.id == first.id && !row.isPending && row.caption != .missing && row.caption != .olderDecode)
            #expect(model.removalOutline(first.id, on: frame) != nil)

            // Undo and Redo move between stored patches and run nothing.
            model.manualUndoManager?.undo()
            #expect(model.manualEdits[frame.url] == nil)
            model.manualUndoManager?.redo()
            #expect(model.manualAdjustments(for: frame).removals == [first] && engine.counts.runs == 1)

            // A second object, planned with the first in the lens settings; then the first made again at Better's settings.
            model.paintRemoval([CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.25, y: 0.3)], on: frame)
            model.commitRemoval(on: frame)
            await model.removalsSettled()
            let two = model.manualAdjustments(for: frame).removals
            try #require(two.count == 2 && two[0] == first, "\(model.clipboardNotice?.details ?? [])")
            #expect(store.contains(two[1].patch.id) && two[1].patch.id != first.patch.id && engine.counts.runs == 2)
            model.remakeRemoval(first.id, better: true, on: frame)
            await model.removalsSettled()
            let again = model.manualAdjustments(for: frame).removals
            #expect(engine.counts.runs == 3 && again.map(\.id) == two.map(\.id) && again[1] == two[1])
            #expect(model.removalRows(for: frame).allSatisfy { !$0.isPending && $0.caption?.isBusy != true })
            #expect(again.allSatisfy { store.contains($0.patch.id) })

            // Saved: the recipe names both, and their pack is beside the raw before it.
            try await model.flushManualSaves()
            #expect(model.manualRecipes[frame.url]?.manual?.adjustments.removals == again)
            #expect(FileManager.default.fileExists(atPath: RecipeStore.patchesBesideRaw(frame.url).path))
            #expect(model.patchesInUse.isSuperset(of: Set(again.map(\.patch.id))))
        }
    }
}
#endif
