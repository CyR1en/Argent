import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import os

/// Smart masks' seeds in the session: where they are kept, what a frame that has lost one shows, and the sweep. A seed is part of the
/// edit, so it is held, released, undone and cleared with it. The store only grows while the app runs; the sweep at launch removes what
/// no record and no undo step names, once it is a week old (masking-plan section 7; R6 sections 4.3, 5 and 6).
extension RollModel {
    private static let seedLog = Logger(subsystem: "camera.argent.Argent", category: "masks")

    /// The library's seeds: Application Support's in the app, a test's own library's in a test.
    var maskSeedStore: MaskRasterStore { MaskRasterStore(library: recipeLibrary) }

    /// Keeps a selection's result in the library, flushed to the disk, and returns the ref a mask names it by. The selection's queue
    /// calls this first, then puts the ref and its `MaskFrame` in the mask, so the save that follows names a seed already on the disk
    /// and the writer never meets a record naming nothing.
    func storeMaskSeed(_ raster: MaskRaster) async throws -> RasterRef {
        let store = maskSeedStore
        let ref = try await Task.detached(priority: .userInitiated) { try store.store(raster) }.value
        // The same pixels made again mend a damaged file of that name.
        for (url, damaged) in maskSeedDamage where damaged.contains(ref.id) {
            let left = damaged.subtracting([ref.id])
            maskSeedDamage[url] = left.isEmpty ? nil : left
        }
        return ref
    }

    /// The frame's edit names a smart mask's seed that the library does not hold, or that was found damaged when its recipe was read.
    /// No fallback: the frame shows no film, its develop fails with the reason and its saves wait (`maskSeedUnsaved`) until the mask
    /// is removed, its selection made again or its pack put back. It is the frame's alone: not an `adjustmentIssue`, so the mask stays
    /// removable and a develop of the roll goes on without it. A selection not made yet is not an issue; a develop refuses it
    /// (`RollDeveloper.seedFailure`).
    func maskSeedIssue(for frame: Frame) -> String? {
        guard let edit = manualEdits[frame.url] else { return nil }
        let damaged = maskSeedDamage[frame.url] ?? [], store = maskSeedStore
        for mask in edit.adjustments.masks.masks {
            for component in mask.components {
                if case .brush(let paint) = component.shape {
                    for raster in paint.strokes.compactMap(\.measured?.raster) {
                        if damaged.contains(raster.id) { return Self.strokeIssue(damaged: true) }
                        if !store.contains(raster.id) { return Self.strokeIssue(damaged: false) }
                    }
                }
                guard case .smart(let selection) = component.shape, let raster = selection.raster else { continue }
                if damaged.contains(raster.id) { return Self.seedIssue(selection.kind, damaged: true) }
                if !store.contains(raster.id) { return Self.seedIssue(selection.kind, damaged: false) }
            }
        }
        return nil
    }

    /// "A brush stroke’s edges are missing, …": a Follow edges stroke whose measured shape the library does not hold, or holds damaged.
    static func strokeIssue(damaged: Bool) -> String {
        let stops = damaged ? "this frame cannot be developed" : "this frame’s changes cannot be saved or developed"
        return "A Follow edges stroke’s shape is \(damaged ? "damaged" : "missing"), so \(stops). Undo the stroke or remove its mask."
    }

    /// "A Sky mask’s selection is missing, …": what `maskSeedIssue` says. A missing seed also stops the frame's saves (the writer
    /// refuses a record naming it); a damaged one only its develop.
    static func seedIssue(_ kind: SmartKind, damaged: Bool) -> String {
        let name = kind.rawValue.capitalized
        let stops = damaged ? "this frame cannot be developed" : "this frame’s changes cannot be saved or developed"
        return "A \(name) mask’s selection is \(damaged ? "damaged" : "missing"), so \(stops). Remove the mask or select the \(kind.rawValue) again."
    }

    /// Reads, off the main queue, every seed the frame's edit and its held edit name, and records those whose file does not hold the
    /// pixels its name is the hash of, for `maskSeedIssue`. A missing one needs no read: the issue checks for its file each time.
    @discardableResult
    func verifyMaskSeeds(for frame: Frame) -> Task<Void, Never>? {
        let url = frame.url
        let refs = (manualEdits[url]?.adjustments.masks.rasters ?? []) + (heldManualEdits[url]?.adjustments.masks.rasters ?? [])
        guard !refs.isEmpty else {
            maskSeedDamage[url] = nil
            return nil
        }
        let store = maskSeedStore, generation = manualGeneration
        return Task {
            let damaged = await Task.detached(priority: .utility) { () -> Set<RasterID> in
                var found = Set<RasterID>()
                for ref in refs where store.contains(ref.id) {
                    if case MaskRasterStore.Failure.damaged? = Result(catching: { try store.load(ref) }).failure { found.insert(ref.id) }
                }
                return found
            }.value
            guard generation == manualGeneration else { return }
            maskSeedDamage[url] = damaged.isEmpty ? nil : damaged
        }
    }

    /// Removes the seeds no record in the library names, nor any edit, held edit or undo step of this session, once they are a week
    /// old (`MaskRasterStore.sweep`). The app runs it once at launch; run later, it still keeps everything the session may want back.
    @discardableResult
    func sweepMaskSeeds(now: Date = Date()) async -> MaskRasterStore.Sweep {
        let edits = Array(manualEdits.values) + Array(heldManualEdits.values)
        let keeping = undoSeeds.union(edits.flatMap(\.adjustments.masks.rasters).map(\.id))
        let library = recipeLibrary
        let sweep = await Task.detached(priority: .utility) { MaskRasterStore.sweep(library: library, keeping: keeping, now: now) }.value
        if let skipped = sweep.skipped {
            Self.seedLog.error("masks' seeds not swept: \(skipped, privacy: .public)")
        } else if !sweep.removed.isEmpty {
            Self.seedLog.info("masks' seeds swept: \(sweep.removed.count) files no edit names")
        }
        return sweep
    }
}

/// Frames whose adjustments cannot be saved as they stand, because a mask's seed is missing (`RollModel.maskSeedUnsaved`), when their
/// edits are about to go: the app quitting ("Quit Anyway"), or another roll opening, or this one again ("Open Anyway"). No retry can
/// save them, so unlike `UnsavedAdjustments` the alert offers only Cancel, the default, and a way to go on without them.
struct UnsavableAdjustments: Equatable {
    enum Answer { case cancel, proceed }

    var frames: Int
    /// The button that goes on without them.
    var proceed: String
    /// Whether what is missing is, for some frame, a removal's pixels and not only a mask's seed (`RollModel.missingPatchIssue`).
    var removals = false

    /// "1 frame’s adjustments cannot be saved: …", with what mends it.
    var message: String {
        if removals {
            return frames == 1
                ? "1 frame’s adjustments cannot be saved: a removal’s pixels are missing. Delete the removal, or put its .argentpatches "
                    + "pack back beside the RAW."
                : "\(frames) frames’ adjustments cannot be saved: their masks’ seeds or their removals’ pixels are missing. Remove them, or "
                    + "put their .argentmasks and .argentpatches packs back beside the RAWs."
        }
        return frames == 1
            ? "1 frame’s adjustments cannot be saved: a mask’s seed is missing. Remove the mask, or put its .argentmasks pack back beside the RAW."
            : "\(frames) frames’ adjustments cannot be saved: their masks’ seeds are missing. Remove the masks, or put their .argentmasks "
                + "packs back beside the RAWs."
    }

    /// Shows the alert and waits for its answer, as `RollModel.askAboutUnsavableAdjustments` does unless a test gives its own. A test
    /// process cannot answer an alert and would wait for ever, so it stops here instead.
    @MainActor static func alert(_ unsavable: UnsavableAdjustments) -> Answer {
        if ProcessInfo.isRunningTests {
            fatalError("A test reached the unsavable adjustments alert: give the model its own askAboutUnsavableAdjustments")
        }
        let alert = NSAlert()
        alert.messageText = "Adjustments cannot be saved"
        alert.informativeText = unsavable.message
        // First, so Return and Escape both keep the app open.
        alert.addButton(withTitle: "Cancel")
        let proceed = alert.addButton(withTitle: unsavable.proceed)
        proceed.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .proceed : .cancel
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
