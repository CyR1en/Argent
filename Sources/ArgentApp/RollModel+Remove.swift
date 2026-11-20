import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import os
import SwiftUI

/// Remove, as the model does it (docs/remove-plan.md, sections 4.1 and 4.8): a selection painted on the open frame, Return, a run of
/// the model in its queue, and a removal in the frame's edit once its patch is stored, as one undo step. What the tab shows is
/// `RemoveSession` and `removalRows(for:)`; what it asks for is below.
///
/// The work itself is the steps' (`RemovalSteps`); the runs under way and what each patch says of itself are `RemovalRuns`. Here are
/// the rules:
///
/// - A run is not in the edit. Its removal enters the edit when its patch is in the store, so a save, a develop and an Undo never
///   meet an unfinished one, and Undo and Redo move between edits whose patches are all stored: neither runs the model.
/// - A frame's runs go one after another, each planned when its turn comes, so its crop holds every removal made before it and
///   none made after. A removal made again sees only the removals before it in the list.
/// - Remove acts on the lead frame only, whatever else is selected.
extension RollModel {
    // MARK: the steps

    /// The steps the app makes: the base's pieces over the film previews and the library.
    func makeRemovalSteps() -> (any RemovalSteps)? {
        guard let films else { return nil }
        return LiveRemovalSteps(films: films, library: recipeLibrary)
    }

    /// Whether Remove may act on `frame`: it is the lead of the frames selected.
    private func actsOnRemove(_ frame: Frame) -> Bool { frame.url == selectedFrame?.url }

    /// The Adjust inspector shows its Remove tab on the open frame.
    var isRemoveTabShown: Bool { removalRuns.showsTab && shownFrame != nil && openAdjustSection == .remove && isAdjustmentsShown }

    // MARK: what the tab shows

    /// The frame's rows: its removals in their order, then its runs that have no patch yet. A removal's caption is the first of
    /// `RemovalRowState.caption(run:isMissing:redrewFace:olderDecode:isSoft:isHealed:)` that applies, read from its patch's notes.
    func removalRows(for frame: Frame) -> [RemovalRowState] {
        let removals = manualAdjustments(for: frame).removals
        readPatchFacts(for: removals.map(\.patch))
        let decoder = removals.isEmpty ? nil : removalRuns.decoder(for: frame)
        var rows = removals.enumerated().map { index, removal -> RemovalRowState in
            let facts = removalRuns.facts[removal.patch.id]
            let older = facts?.decoder != nil && decoder != nil && facts?.decoder != decoder
            let caption = RemovalRowState.caption(run: remove.remaking[removal.id], isMissing: facts?.isMissing == true,
                                                  redrewFace: facts?.face != nil, olderDecode: older, isSoft: facts?.isSoft == true,
                                                  isHealed: facts?.isHealed == true)
            return RemovalRowState(id: removal.id, number: index + 1, isOn: removal.isOn, includesEffects: removal.includesEffects,
                                   caption: caption)
        }
        for var row in remove.pending[frame.url] ?? [] {
            row.number = rows.count + 1
            rows.append(row)
        }
        return rows
    }

    /// Whether Reset on the Remove tab has something to delete.
    func canResetRemovals(_ frame: Frame) -> Bool {
        (!manualAdjustments(for: frame).removals.isEmpty && canAdjust(frame)) || !removalRuns.runs(on: frame.url).isEmpty
    }

    /// A removal's outline for the row the pointer is over: its patch's object alpha over its box, carried to the corrected picture.
    /// A run with no patch yet is outlined by the selection it was made from.
    func removalOutline(_ id: UUID, on frame: Frame) -> RemoveCoverage? {
        if let run = removalRuns.run(id), !run.isRemake { return run.frame == frame.url ? run.outline : nil }
        guard let removal = manualAdjustments(for: frame).removals.first(where: { $0.id == id }) else { return nil }
        guard let facts = removalRuns.facts[removal.patch.id], let outline = removalRuns.outlines[removal.patch.id] else {
            readPatchFacts(for: [removal.patch], wantsOutline: true)
            return nil
        }
        guard let box = facts.box, let width = facts.frameWidth, let height = facts.frameHeight, width > 0, height > 0 else { return nil }
        return RemoveCoverage(width: outline.width, height: outline.height, values: outline.values,
                              frame: pictureRect(of: box, frameWidth: width, frameHeight: height, on: frame))
    }

    /// A box of the decode as fractions of the corrected picture: its corners and its sides' middles carried through the lens,
    /// since a patch lies before the warp and the overlay is drawn after it.
    private func pictureRect(of box: RemovalPatch.Box, frameWidth: Int, frameHeight: Int, on frame: Frame) -> CGRect {
        let plain = CGRect(x: Double(box.x) / Double(frameWidth), y: Double(box.y) / Double(frameHeight),
                           width: Double(box.width) / Double(frameWidth), height: Double(box.height) / Double(frameHeight))
        guard let space = try? MaskSpace(width: frameWidth, height: frameHeight),
              let geometry = removalRuns.work?.geometry(for: frame, lens: lensSettings(for: frame)),
              let remap = LensRemap(from: ResolvedLensCorrection.identity.geometry, to: geometry, extent: space.extent) else { return plain }
        let long = Float(space.longSide), places: [(Float, Float)] = [(0, 0), (0.5, 0), (1, 0), (0, 0.5), (1, 0.5), (0, 1), (0.5, 1), (1, 1)]
        let carried = places.map { place in
            remap.point(MaskPoint(x: (Float(box.x) + place.0 * Float(box.width)) / long, y: (Float(box.y) + place.1 * Float(box.height)) / long))
        }
        let xs = carried.map { CGFloat($0.x / space.extent.x) }, ys = carried.map { CGFloat($0.y / space.extent.y) }
        guard let left = xs.min(), let right = xs.max(), let top = ys.min(), let bottom = ys.max() else { return plain }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Reads, off the main actor, what the rows say of `refs`' patches, each once a session. `again` reads those found missing
    /// once more, since a pack put back beside the raw gives a patch back; `wantsOutline` reads one whose outline was let go.
    private func readPatchFacts(for refs: [PatchRef], again: Bool = false, wantsOutline: Bool = false) {
        guard !refs.isEmpty, let steps = removalRuns.work else { return }
        let generation = manualGeneration
        for ref in refs where !removalRuns.isReading(ref.id) {
            let known = removalRuns.facts[ref.id]
            guard known == nil || (again && known?.isMissing == true)
                    || (wantsOutline && known?.isMissing != true && removalRuns.outlines[ref.id] == nil) else { continue }
            removalRuns.setReading(Task { [weak self] in
                let patch = await Self.loadPatch(ref, with: steps)
                guard let self, generation == self.manualGeneration else { return }
                self.removalRuns.setReading(nil, for: ref.id)
                if let patch { self.removalRuns.note(patch) } else { self.removalRuns.set(.missing, for: ref.id) }
            }, for: ref.id)
        }
    }

    /// Megabytes unpacked and hashed: never on the main actor.
    nonisolated private static func loadPatch(_ ref: PatchRef, with steps: any RemovalSteps) async -> RemovalPatch? {
        try? steps.load(ref)
    }

    // MARK: the tab and the selection

    /// The Remove tab came to show `frame`: the model is wanted soon (`RemovalQueue.noteUse`), and Snap to Object says whether it
    /// can.
    func removeTabShown(for frame: Frame) {
        guard actsOnRemove(frame) else { return }
        if remove.frame != frame.url {
            dropRemoveSelection()
            remove.frame = frame.url
        }
        removalRuns.forgetDecoder(for: frame.url)
        guard let steps = removalRuns.work else {
            let none = RemovalEngineState.absent("Remove needs the film previews, which need a stock.")
            if remove.engine != none { remove.engine = none }
            return
        }
        steps.noteUse()
        noteRemoveEngine()
        let generation = manualGeneration
        removalRuns.availabilityTask = Task { [weak self] in
            let availability = await steps.snapAvailability()
            guard let self, !Task.isCancelled, generation == self.manualGeneration else { return }
            if self.remove.selection.snap != availability { self.remove.selection.snap = availability }
        }
        readPatchFacts(for: manualAdjustments(for: frame).removals.map(\.patch), again: true)
    }

    /// The tab went, or the frame closed: the selection is dropped. Runs in flight go on.
    func removeTabHidden() {
        dropRemoveSelection()
        remove.reset()
    }

    /// The engine as the tab says it, read again where it may have changed.
    private func noteRemoveEngine() {
        guard let state = removalRuns.work?.engineState, remove.engine != state else { return }
        remove.engine = state
    }

    /// Writes the selection, and keeps what the menu bar reads of it.
    private func writeRemoveSelection(_ change: (inout RemoveSelectionState) -> Void) {
        var selection = remove.selection
        change(&selection)
        if selection != remove.selection { remove.selection = selection }
        removalRuns.noteSelection(canRemove: selection.canRemove)
    }

    /// Nothing is selected any more, and no stroke on its way to its object will select anything.
    private func dropRemoveSelection() {
        removalRuns.sizeTask?.cancel()
        removalRuns.sizeTask = nil
        removalRuns.snapGeneration += 1
        removalRuns.snapTask?.cancel()
        removalRuns.snapTask = nil
        removalRuns.snapsWaiting = 0
        removalRuns.stroke = nil
        removalRuns.snapped = nil
        writeRemoveSelection { selection in
            selection.coverage = nil
            selection.stroke = []
            selection.strokeSubtracts = false
            selection.isSnapping = false
        }
    }

    /// A press, a drag or a release of the Remove brush on the photograph. A click is a point; a stroke is painted with the session's
    /// brush size; Option at the press subtracts. On release the stroke snaps to the object under it where Snap to Object is on and
    /// available, and is the selection as painted where it is not.
    func removeBrush(_ event: MaskCanvasEvent, on frame: Frame) {
        guard actsOnRemove(frame) else { return }
        switch event.phase {
        case .press:
            if remove.frame != frame.url {
                dropRemoveSelection()
                remove.frame = frame.url
            }
            removalRuns.work?.noteUse()
            removalRuns.stroke = RemovalRuns.Stroke(start: event.point)
            writeRemoveSelection { selection in
                selection.stroke = [event.fractions]
                selection.strokeSubtracts = event.modifiers.contains(RemoveKeys.subtracts)
            }
        case .drag, .release:
            guard var stroke = removalRuns.stroke, remove.frame == frame.url else { return }
            stroke.travel = max(stroke.travel, hypot(event.point.x - stroke.start.x, event.point.y - stroke.start.y))
            // The stroke's points alone change as it is drawn: written straight, so nothing else is asked again at each.
            if remove.selection.stroke.last != event.fractions { remove.selection.stroke.append(event.fractions) }
            guard event.phase == .release else {
                removalRuns.stroke = stroke
                return
            }
            removalRuns.stroke = nil
            finishRemoveStroke(isClick: stroke.travel <= RemoveKeys.clickTravel, on: frame)
        }
    }

    /// The stroke was released: it goes to the segmenter, or is the selection as painted.
    private func finishRemoveStroke(isClick: Bool, on frame: Frame) {
        let points = remove.selection.stroke, subtracts = remove.selection.strokeSubtracts
        guard let first = points.first else { return }
        let size = RemoveCoverage.paintedSize(for: frame)
        let painted = RemoveCoverage.painted(isClick ? [first] : points, brushSize: remove.brushSize, width: size.width, height: size.height)
        guard remove.selection.snapsToObject, remove.selection.snap == .ready, let steps = removalRuns.work else {
            removalRuns.snapped = nil
            writeRemoveSelection { selection in
                Self.paint(painted, subtracts: subtracts, in: &selection)
                selection.stroke = []
                selection.strokeSubtracts = false
            }
            announceRemoveSize(on: frame)
            return
        }
        // A stroke drawn while the last one is still finding its object goes after it, so each adds to what the one before left.
        let generation = removalRuns.snapGeneration, previous = removalRuns.snapTask, lens = lensSettings(for: frame)
        removalRuns.snapsWaiting += 1
        writeRemoveSelection { $0.isSnapping = true }
        removalRuns.snapTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.removalRuns.snapGeneration else { return }
            var asked: RemovalRuns.Snapped?
            if !subtracts {
                let prompt: ObjectSelector.Prompt? = isClick ? .point(x: Float(first.x), y: Float(first.y))
                    : painted.map { .scribble(width: $0.width, height: $0.height, coverage: $0.values) }
                asked = prompt.map { RemovalRuns.Snapped(prompt: $0, before: self.remove.selection.coverage) }
            } else if var last = self.removalRuns.snapped {
                // Option on a snapped object says where it is not, and the object is asked for again.
                last.excluded += isClick ? [first] : Self.sampled(points, count: RemoveKeys.excludedPoints)
                asked = last
            }
            var found: RemoveCoverage?
            if let asked {
                found = (try? await steps.snap(asked.prompt, excluded: asked.excluded, on: frame, lens: lens)).map { RemoveCoverage($0) }
                guard generation == self.removalRuns.snapGeneration else { return }
            }
            self.removalRuns.snapsWaiting -= 1
            let last = self.removalRuns.snapsWaiting == 0
            self.writeRemoveSelection { selection in
                if let asked, let found, !found.isEmpty {
                    selection.coverage = asked.before.map { $0.adding(found) } ?? found
                    self.removalRuns.snapped = asked
                } else {
                    // The segmenter found nothing, or is not to be had: the stroke is the selection as painted.
                    Self.paint(painted, subtracts: subtracts, in: &selection)
                    self.removalRuns.snapped = nil
                }
                if last {
                    selection.isSnapping = false
                    // The stroke shows until it snaps, unless another is being drawn.
                    if self.removalRuns.stroke == nil {
                        selection.stroke = []
                        selection.strokeSubtracts = false
                    }
                }
            }
            if last { self.announceRemoveSize(on: frame) }
        }
    }

    /// Tells the engine the working size the selection's job will have, as soon as there is a selection: the plan is made as
    /// Return will make it, off the main actor, and its box gives the size. A selection that changes meanwhile announces its own.
    private func announceRemoveSize(on frame: Frame) {
        removalRuns.sizeTask?.cancel()
        removalRuns.sizeTask = nil
        guard let selection = remove.selection.coverage?.selection, let steps = removalRuns.work else { return }
        let lens = lensSettings(for: frame)
        removalRuns.sizeTask = Task.detached(priority: .utility) {
            guard let picture = try? await steps.frame(frame, lens: lens), !Task.isCancelled,
                  let plan = try? steps.plan(selection, on: picture), !Task.isCancelled else { return }
            let size = RemovalPipeline.workingSize(width: plan.box.width, height: plan.box.height)
            steps.prepareSize(width: size.width, height: size.height)
        }
    }

    /// `painted` added to the selection, or taken from it.
    private static func paint(_ painted: RemoveCoverage?, subtracts: Bool, in selection: inout RemoveSelectionState) {
        guard let painted else { return }
        if subtracts {
            selection.coverage = selection.coverage?.subtracting(painted)
        } else {
            selection.coverage = selection.coverage?.adding(painted) ?? painted
        }
    }

    /// `count` of `points` at most, evenly along them.
    private static func sampled(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count > count, count > 1 else { return points }
        return (0..<count).map { points[$0 * (points.count - 1) / (count - 1)] }
    }

    func clearRemoveSelection() {
        dropRemoveSelection()
    }

    func setRemoveSnapsToObject(_ snaps: Bool) {
        if !snaps { removalRuns.snapped = nil }
        writeRemoveSelection { $0.snapsToObject = snaps }
    }

    // MARK: removals

    /// Return, and the Remove button: the selection becomes a run, and the selection is cleared so another object can be painted.
    /// The removal enters the edit when its patch is stored, as one undo step, "Remove Object".
    func commitRemoval(on frame: Frame) {
        guard actsOnRemove(frame), remove.frame == frame.url, remove.selection.canRemove, canAdjust(frame),
              let coverage = remove.selection.coverage, let steps = removalRuns.work else { return }
        guard let selection = coverage.selection else {
            dropRemoveSelection()
            return
        }
        if case .absent(let why) = steps.engineState {
            // The selection stays: nothing was tried.
            noteRemoveEngine()
            sayRemovalFailed(why)
            return
        }
        guard manualAdjustments(for: frame).removals.count + (remove.pending[frame.url]?.count ?? 0) < Removal.limit else {
            sayRemovalFailed("A frame holds at most \(Removal.limit) removals.")
            return
        }
        startRemovalRun(.selection(selection), id: UUID(), outline: coverage, better: false, on: frame)
        dropRemoveSelection()
    }

    /// Try Again (another seed) and Better (the model's own guidance, 2.5): the removal is made again from its own patch's object, and takes the new
    /// patch as one undo step when it arrives. The old result stays on screen until then.
    func remakeRemoval(_ id: UUID, better: Bool, on frame: Frame) {
        guard actsOnRemove(frame), canAdjust(frame), removalRuns.run(id) == nil, let steps = removalRuns.work,
              let removal = manualAdjustments(for: frame).removals.first(where: { $0.id == id }),
              removalRuns.facts[removal.patch.id]?.isMissing != true else { return }
        if case .absent(let why) = steps.engineState {
            noteRemoveEngine()
            remove.remaking[id] = .failed(why)
            return
        }
        startRemovalRun(.retrying(removal.patch), id: id, outline: nil, better: better, on: frame)
    }

    /// What the run's row says before the queue has said anything of it.
    private func openingCaption(behindAnother: Bool, steps count: Int) -> RemovalRowState.Caption {
        guard !behindAnother, let state = removalRuns.work?.engineState else { return .queued }
        switch state {
        case .ready: return isDeveloping ? .waitingForDevelop : .removing(step: 0, of: count)
        case .running: return .queued
        default: return RemovalRowState.caption(for: .waiting(state, forDevelop: isDeveloping))
        }
    }

    private func setRemovalCaption(_ caption: RemovalRowState.Caption, for run: RemovalRuns.Run) {
        if run.isRemake {
            if remove.remaking[run.id] != caption { remove.remaking[run.id] = caption }
        } else if var rows = remove.pending[run.frame], let index = rows.firstIndex(where: { $0.id == run.id }), rows[index].caption != caption {
            rows[index].caption = caption
            remove.pending[run.frame] = rows
        }
    }

    /// The run is over: its row goes, or its removal's caption is its patch's again.
    private func endRemovalRun(_ run: RemovalRuns.Run) {
        guard removalRuns.isCurrent(run.id, run.token) else { return }
        removalRuns.end(run.id)
        if run.isRemake {
            remove.remaking[run.id] = nil
        } else if let rows = remove.pending[run.frame] {
            let left = rows.filter { $0.id != run.id }
            remove.pending[run.frame] = left.isEmpty ? nil : left
        }
        noteRemoveEngine()
    }

    /// Starts a run for `frame`, after the frame's runs before it. `id` is the removal's: the one it takes, or the one it has.
    private func startRemovalRun(_ source: RemovalRequest.Source, id: UUID, outline: RemoveCoverage?, better: Bool, on frame: Frame) {
        guard let steps = removalRuns.work else { return }
        let isRemake = if case .retrying = source { true } else { false }
        let count = better ? RemovalJob.betterSteps : RemovalJob.defaultSteps
        let guidance = better ? RemovalJob.betterGuidance : RemovalJob.defaultGuidance
        let previous = removalRuns.last(on: frame.url), behind = !removalRuns.runs(on: frame.url).isEmpty
        let run = RemovalRuns.Run(id: id, frame: frame.url, isRemake: isRemake, outline: outline)
        removalRuns.begin(run)
        let caption = openingCaption(behindAnother: behind, steps: count)
        if isRemake {
            remove.remaking[id] = caption
        } else {
            remove.pending[frame.url, default: []].append(RemovalRowState(id: id, number: 0, isPending: true, caption: caption))
        }
        let generation = manualGeneration
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.removalRuns.finished(run.token, on: frame.url) }
            guard generation == self.manualGeneration, self.removalRuns.isCurrent(id, run.token) else { return }
            await self.makeRemoval(run, source: source, steps: count, guidance: guidance, better: better, with: steps, generation: generation)
        }
        removalRuns.setTask(task, for: id)
    }

    /// One run in its turn: planned from the edit as it is now, made, and put in the edit.
    private func makeRemoval(_ run: RemovalRuns.Run, source: RemovalRequest.Source, steps count: Int, guidance: Float, better: Bool,
                             with steps: any RemovalSteps, generation: UUID) async {
        func isCurrent() -> Bool { generation == manualGeneration && removalRuns.isCurrent(run.id, run.token) }
        guard let frame = roll?.frames.first(where: { $0.url == run.frame }) else { return endRemovalRun(run) }
        // The removals made before this one: all the edit holds for a new one, those before it in the list for one made again.
        let lens = manualAdjustments(for: frame).lens
        var earlier = lens
        if run.isRemake {
            guard let index = lens.removals.firstIndex(where: { $0.id == run.id }),
                  let before = try? lens.settingRemovals(Array(lens.removals[..<index])) else { return endRemovalRun(run) }
            earlier = before
        }
        setRemovalCaption(openingCaption(behindAnother: false, steps: count), for: run)
        let stamp = SourceStamp.of(frame.url)
        let request = RemovalRequest(frame: frame, shown: lensSettings(for: frame), lens: earlier, source: source, steps: count, guidance: guidance,
                                     seed: UInt64.random(in: 0...UInt64.max), faces: analysis(for: frame)?.faces ?? [])
        let patch: RemovalPatch
        do {
            patch = try await steps.patch(for: request) { [weak self] progress in
                await self?.removalProgressed(progress, run: run)
            }
        } catch {
            // A cancel took the row with it.
            guard isCurrent() else { return }
            if error is CancellationError || Task.isCancelled { return endRemovalRun(run) }
            return removalFailed(run, why: error.localizedDescription)
        }
        guard isCurrent(), !Task.isCancelled else { return }
        removalRuns.note(patch)
        // A slider or a handle still held on the frame is let go first: the removal is a step of its own, never part of a drag's.
        while manualGestures[frame.url] != nil {
            await removalRuns.waitForGesture(on: frame.url)
            guard isCurrent(), !Task.isCancelled else { return }
        }
        guard let current = roll?.frames.first(where: { $0.url == run.frame }) else { return endRemovalRun(run) }
        // A patch cut from a raw that has since been written over is not this picture's.
        guard SourceStamp.of(run.frame) == stamp else { return removalFailed(run, why: "The RAW changed while the object was being removed.") }
        takeRemoval(patch.ref, from: run, better: better, on: current)
    }

    private func removalProgressed(_ progress: RemovalQueue.Progress, run: RemovalRuns.Run) {
        guard removalRuns.isCurrent(run.id, run.token) else { return }
        setRemovalCaption(RemovalRowState.caption(for: progress), for: run)
        noteRemoveEngine()
    }

    /// The patch is in the store: its removal enters the edit, or takes it in place of the one it had, as one undo step.
    private func takeRemoval(_ patch: PatchRef, from run: RemovalRuns.Run, better: Bool, on frame: Frame) {
        let removals = manualAdjustments(for: frame).removals
        var next = removals
        let actionName: String
        if run.isRemake {
            // Deleted, reset or undone away meanwhile: there is nothing to give the patch to.
            guard let index = removals.firstIndex(where: { $0.id == run.id }) else { return endRemovalRun(run) }
            next[index] = removals[index].replacingPatch(patch)
            actionName = better ? "Remove Object Better" : "Remove Object Again"
        } else {
            next.append(Removal(id: run.id, patch: patch))
            actionName = "Remove Object"
        }
        guard next != removals else { return endRemovalRun(run) }
        guard canAdjust(frame) else { return removalFailed(run, why: "The frame cannot be adjusted now.") }
        guard setRemovals(next, for: frame, actionName: actionName) else {
            return removalFailed(run, why: "The removal could not be added to the frame’s adjustments.")
        }
        endRemovalRun(run)
        announce(run.isRemake ? "Object removed again" : "Object removed")
    }

    /// A run ended without a picture. A removal made again keeps its old pixels, and its row says why and offers Try Again. A new
    /// one has no row to keep: it goes, the selection it was made from comes back if nothing else has been painted since, so
    /// Return tries again, and the notice says why.
    private func removalFailed(_ run: RemovalRuns.Run, why: String) {
        guard removalRuns.isCurrent(run.id, run.token) else { return }
        endRemovalRun(run)
        if run.isRemake {
            remove.remaking[run.id] = .failed(why)
            announce(RemovalRowState.Caption.failed(why).text)
            return
        }
        if let outline = run.outline, remove.frame == run.frame, remove.selection.coverage == nil, remove.selection.stroke.isEmpty,
           !remove.selection.isSnapping, removalRuns.stroke == nil {
            writeRemoveSelection { $0.coverage = outline }
        }
        sayRemovalFailed(why)
    }

    private func sayRemovalFailed(_ why: String) {
        showClipboardNotice(ClipboardNotice(kind: .failed, text: "Could not remove the object", details: [why]))
    }

    /// A row's Cancel: the run stops between two steps and its row goes. For a removal being made again, the old pixels stay.
    func cancelRemoval(_ id: UUID, on frame: Frame) {
        guard let run = removalRuns.run(id), run.frame == frame.url else { return }
        run.task?.cancel()
        endRemovalRun(run)
    }

    /// Escape: cancels the frame's newest run, and says whether there was one, so the key falls through when there was not.
    @discardableResult
    func cancelNewestRemoval(on frame: Frame) -> Bool {
        guard let newest = removalRuns.runs(on: frame.url).last else { return false }
        cancelRemoval(newest.id, on: frame)
        return true
    }

    /// The frame's runs stop: it left the roll, or the tab's Reset took everything of Remove from it.
    func cancelRemovals(on frame: URL) {
        for run in removalRuns.runs(on: frame) {
            run.task?.cancel()
            endRemovalRun(run)
        }
    }

    /// Returns once every run, snap and read of a patch under way for `frames`, or for every frame, has ended.
    func removalsSettled(on frames: Set<URL>? = nil) async {
        var awaited: [Task<Void, Never>] = []
        while true {
            // A run that ended may have let the next begin.
            let tasks = removalRuns.tasks(on: frames).filter { !awaited.contains($0) }
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
            awaited += tasks
        }
    }

    /// `removals` as the frame's, through the path a Light slider takes, as one undo step called `actionName`. A press or a
    /// drag open on the frame ends first, as its own step; a patch never meets one, since it waits for it (`makeRemoval`).
    /// Whether they were written.
    @discardableResult
    private func setRemovals(_ removals: [Removal], for frame: Frame, actionName: String) -> Bool {
        guard let values = try? manualAdjustments(for: frame).settingRemovals(removals), canAdjust(frame) else { return false }
        // One step, whatever opened the turn this runs in: a patch arrives outside any event.
        let manager = manualUndoManager, opens = manager?.groupingLevel == 0
        if opens { manager?.beginUndoGrouping() }
        let light = manualGestures[frame.url] != nil ? endGestures(on: [frame], resumingLight: false) : nil
        beginManualGesture(for: frame)
        setManualAdjustments(values, for: frame)
        endManualGesture(for: frame, actionName: actionName)
        if opens { manager?.endUndoGrouping() }
        resumeLightAdjusting(on: light)
        if manualEdits[frame.url] == nil { isComparingAuto = false }
        return manualAdjustments(for: frame).removals == removals
    }

    /// The frame's removals with the one called `id` changed by `change`, as one step.
    private func changeRemoval(_ id: UUID, on frame: Frame, actionName: String, _ change: (Removal) -> Removal) {
        guard actsOnRemove(frame) else { return }
        let removals = manualAdjustments(for: frame).removals
        guard let index = removals.firstIndex(where: { $0.id == id }) else { return }
        var next = removals
        next[index] = change(removals[index])
        guard next != removals else { return }
        setRemovals(next, for: frame, actionName: actionName)
    }

    /// The row's eye.
    func setRemoval(_ id: UUID, isOn: Bool, on frame: Frame) {
        changeRemoval(id, on: frame, actionName: isOn ? "Turn Removal On" : "Turn Removal Off") { $0.setting(isOn: isOn) }
    }

    /// Include Shadow and Reflections.
    func setRemoval(_ id: UUID, includesEffects: Bool, on frame: Frame) {
        changeRemoval(id, on: frame, actionName: includesEffects ? "Include Shadow and Reflections" : "Exclude Shadow and Reflections") {
            $0.setting(includesEffects: includesEffects)
        }
    }

    func deleteRemoval(_ id: UUID, on frame: Frame) {
        guard actsOnRemove(frame) else { return }
        let removals = manualAdjustments(for: frame).removals
        guard removals.contains(where: { $0.id == id }) else { return }
        guard setRemovals(removals.filter { $0.id != id }, for: frame, actionName: "Delete Removal") else { return }
        // A run making it again has nothing left to give its patch to.
        cancelRemoval(id, on: frame)
        remove.remaking[id] = nil
        if remove.hovered == id { remove.hovered = nil }
    }

    /// The Remove tab's Reset: the frame's removals alone, as one undo step. Its runs under way stop too: they are not in the
    /// edit, so no step holds them.
    func resetRemovals(for frame: Frame) {
        guard actsOnRemove(frame) else { return }
        cancelRemovals(on: frame.url)
        let removals = manualAdjustments(for: frame).removals
        guard !removals.isEmpty, setRemovals([], for: frame, actionName: "Reset Removals") else { return }
        for removal in removals { remove.remaking[removal.id] = nil }
        remove.hovered = nil
    }

    /// A click on "Redrew part of a face": the frame glides to that face at 100 %.
    func showRemovalFace(_ id: UUID, on frame: Frame) {
        guard frame.url == shownFrame?.url, let room = frameZoomRoom,
              let removal = manualAdjustments(for: frame).removals.first(where: { $0.id == id }),
              let face = removalRuns.facts[removal.patch.id]?.face, face.count == 4, face.allSatisfy(\.isFinite) else { return }
        // Actual Size, with the face's middle in the area's: the picture's centre moves the other way by the face's distance from it.
        var zoom = frameZoom.actualSize(around: CGPoint(x: room.area.width / 2, y: room.area.height / 2), in: room)
        let x = CGFloat(face[0] + face[2] / 2) - 0.5, y = CGFloat(face[1] + face[3] / 2) - 0.5
        zoom.offset = CGSize(width: -x * room.fitted.width * zoom.scale, height: -y * room.fitted.height * zoom.scale)
        zoom = zoom.clamped(in: room).settled(in: room)
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Graphite.Motion.glide) { frameZoom = zoom }
    }

    // MARK: the session and the library

    /// The roll's session ends: every run stops, and what was read of its patches goes.
    func clearRemoveSession() {
        removalRuns.reset()
        undoPatches = []
        remove.pending = [:]
        remove.remaking = [:]
        remove.reset()
    }

    /// The frame at `url` left the roll: its runs stop, and an arrival waiting on its gesture waits no more.
    func forgetRemovals(_ url: URL) {
        cancelRemovals(on: url)
        removalRuns.gestureEnded(on: url)
        remove.pending[url] = nil
        if remove.frame == url { removeTabHidden() }
    }

    /// Before a develop's gate reads the footprint: the model that removes objects gives its memory back, and its runs wait
    /// (`RemovalQueue.developWillStart`). Nothing is made for it: a session that removed nothing has no model.
    func removalsYieldToDevelop() async {
        await removalRuns.steps?.developWillStart()
    }

    func removalsResumeAfterDevelop() {
        removalRuns.steps?.developDidEnd()
    }

    private static let removeLog = Logger(subsystem: "camera.argent.Argent", category: "remove")

    /// Why a frame's adjustments are not saved when it is a removal's pixels that are nowhere: the writer names no patch the
    /// library and the pack beside the RAW both lack (`RecipeWriter.Failure.missingPatch`), so the edit waits as it does for a
    /// mask's seed (`maskSeedUnsaved`). `nil` for a frame whose removals' patches are all there.
    func missingPatchIssue(for frame: Frame) -> String? {
        removalRows(for: frame).contains { $0.caption == .missing }
            ? "This frame’s adjustments are not saved: a removal’s pixels are missing. Delete the removal, or put its .argentpatches pack back beside the RAW."
            : nil
    }

    /// Whether a frame whose save waits does so for a removal's pixels.
    var isUnsavedForMissingPatches: Bool {
        (roll?.frames ?? []).contains { maskSeedUnsaved.contains($0.url) && missingPatchIssue(for: $0) != nil }
    }

    /// Every patch this session may want back: those its edits and held edits name, and those an undo or a redo step names.
    var patchesInUse: Set<PatchID> {
        let edits = Array(manualEdits.values) + Array(heldManualEdits.values)
        return undoPatches.union(edits.flatMap(\.adjustments.removals).map(\.patch.id))
    }

    /// Removes the patches no record in the library names, nor any edit, held edit or undo step of this session, once they are a
    /// week old (`PatchStore.sweep`). The app runs it once at launch, beside the seeds' sweep; run later, it still keeps everything
    /// the session may want back, the result Try Again replaced among it.
    @discardableResult
    func sweepPatches(now: Date = Date()) async -> PatchStore.Sweep {
        let keeping = patchesInUse, library = recipeLibrary
        let sweep = await Task.detached(priority: .utility) { PatchStore.sweep(library: library, keeping: keeping, now: now) }.value
        if let skipped = sweep.skipped {
            Self.removeLog.error("removals' patches not swept: \(skipped, privacy: .public)")
        } else if !sweep.removed.isEmpty {
            Self.removeLog.info("removals' patches swept: \(sweep.removed.count) files no edit names")
        }
        return sweep
    }
}
