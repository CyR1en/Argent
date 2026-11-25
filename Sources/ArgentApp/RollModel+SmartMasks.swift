import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import QuartzCore

/// Smart masks: one click on Sky, Subject, Person or Background makes a mask (plan section 2). The click is one undo step: the mask
/// appears at once with its selection not yet made, and the selection, when it arrives, goes into that mask with no step of its own
/// and is saved. A develop never runs a model: it waits for a selection under way, and refuses a frame whose selection was never
/// made (`RollDeveloper.seedFailure`). The queue that makes them is `MaskInference`.
extension RollModel {
    // MARK: Availability

    /// Whether `kind` can be asked for in this build and on this Mac, and why not. Asked of the engine once (`SmartMasks.availability`).
    func smartAvailability(_ kind: SmartKind) -> SmartAvailability {
        smartMasks.availability(of: kind) ?? .unavailable("Smart masks need the film previews, which need a stock.")
    }

    /// Where downloaded models go: `Models` beside `recipeLibrary` (`ApplicationSupport.folder/Models` in the app, and a test's own folder in tests).
    var downloadedModelsFolder: URL {
        recipeLibrary.deletingLastPathComponent().appendingPathComponent("Models", isDirectory: true)
    }

    /// Removes orphaned `.install-*` staging folders in `downloadedModelsFolder` left behind by a quit or crash during download or install.
    func sweepMaskModelStaging() async {
        guard !maskModels.isRunning else { return }
        let folder = downloadedModelsFolder
        let task = Task.detached(priority: .utility) { MaskModelPack.sweepStaging(in: folder) }
        maskModelStagingSweep = task
        await task.value
        maskModelStagingSweep = nil
    }

    /// The queue the app makes: the film previews' input pictures, and the app's models and the downloaded mask models, whose ledger sits beside the recipes.
    func makeMaskInference() -> MaskInference? {
        guard let films else { return nil }
        let models = MaskModels(directories: [MaskModels.bundledDirectory, downloadedModelsFolder].compactMap(\.self),
                                ledgerFile: recipeLibrary.deletingLastPathComponent().appendingPathComponent("Mask models.json"))
        return MaskInference(engine: BundledSmartMasks(films: films, models: models, app: Self.software), turns: films.decodeTurns)
    }

    /// The mask models' licence and download screen, the only modal over the workspace: Quick Develop and Add's picker go.
    func showMaskModels() {
        quickDevelop = nil
        maskEditor.isPickerOpen = false
        maskModels.show()
    }

    // MARK: The click

    /// A tile: a mask of `kind`, one undo step named for it, its row at once with its wait named, selected and showing its red as
    /// soon as the selection lands. A second click of the same kind while one is being found on the frame selects that one instead.
    /// When the mask models are not installed yet, opens their licence and download screen instead.
    func addSmartMask(_ kind: SmartKind, for frame: Frame) {
        if case .needsModels = smartAvailability(kind) {
            showMaskModels()
            return
        }
        guard canAddMask(frame), smartAvailability(kind).isAvailable else { return }
        maskEditor.finishPress()
        if let running = masks(for: frame).last(where: { mask in
            mask.pendingSmart.contains(kind) && smartMasks.run(.init(frame: frame.url, mask: mask.id)).map { if case .working = $0.state { true } else { false } } == true
        }) {
            maskEditor.selection = MaskEditor.Selection(mask: running.id, component: nil)
            return
        }
        let clicked = CACurrentMediaTime()
        beginManualGesture(for: frame)
        if maskCompilerGate(for: frame) == .movesToCurrent { manualEdits[frame.url]?.curveVersion = ManualRenderSettings.currentVersion }
        let mask = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: kind)))])
        let name = nextMaskName(kind.title, for: frame)
        guard let set = try? manualAdjustments(for: frame).masks.appending(mask) else {
            cancelManualGesture(for: frame)
            return
        }
        setManualAdjustments(manualAdjustments(for: frame).settingMasks(set), for: frame)
        guard self.mask(mask.id, for: frame) != nil else {
            cancelManualGesture(for: frame)
            return
        }
        manualEdits[frame.url]?.maskNotes.names[mask.id.uuidString] = name
        // The run's row says what it waits for from the first frame the row is drawn in.
        smartMasks.timings[mask.id] = SmartMasks.Timing(clicked: clicked)
        askSelection(kind, mask: mask.id, for: frame)
        endManualGesture(for: frame, actionName: "Add \(kind.title) Mask")
        maskEditor.didPlace(MaskEditor.Selection(mask: mask.id, component: nil))
        // Add's popover closes on the tiles again, as a gradient's tile closes it.
        maskEditor.isPickerOpen = false
    }

    /// Starts the selection for `mask`'s pending `kind`, or for an Update, its seed made again (kept until the new one arrives).
    /// A kind this build or this Mac cannot make is not asked for: the row says why, as the kind's tile does, with Try Again and
    /// Remove. A tile cannot ask for one, but an Undo, a Redo or a paste can bring one back.
    private func askSelection(_ kind: SmartKind, mask id: UUID, for frame: Frame, update: Bool = false) {
        let key = SmartMasks.RunKey(frame: frame.url, mask: id)
        if let why = smartAvailability(kind).reason {
            smartMasks.setRun(.init(kind: kind, state: .failed(why), ticket: nil, source: nil), for: key)
            return
        }
        guard let queue = smartMasks.queue, let sha = manualEdits[frame.url]?.baseline.sourceSHA256 ?? manualReadySources[frame.url]?.sha256 else {
            smartMasks.setRun(.init(kind: kind, state: .failed("Its RAW is not verified yet."), ticket: nil, source: nil), for: key)
            return
        }
        if let old = smartMasks.run(key)?.ticket { queue.cancel(old) }
        if update { queue.forget(frame.url) }
        let source = SourceStamp.of(frame.url)
        smartMasks.setRun(.init(kind: kind, state: .working(.queued, update: update), ticket: nil, source: source), for: key)
        let smart = smartMasks
        let asked = queue.ask(kind, on: frame, sourceSHA256: sha, lens: lensSettings(for: frame)) { stage in
            Task { @MainActor in smart.setStage(stage, for: key) }
        }
        var run = smartMasks.run(key)
        run?.ticket = asked.ticket
        smartMasks.setRun(run, for: key)
        smartMasks.fills[key]?.task.cancel()
        let generation = manualGeneration, id = UUID()
        smartMasks.fills[key] = (id, Task { [weak self] in
            let outcome = await asked.outcome.value
            guard let self, generation == self.manualGeneration else { return }
            await self.receive(outcome, kind: kind, key: key, ticket: asked.ticket, source: source, update: update)
            if self.smartMasks.fills[key]?.id == id { self.smartMasks.fills[key] = nil }
        })
    }

    /// What a selection came to, into the mask that asked if it still waits for it: stored first, flushed, then named in the mask
    /// with its frame and provenance and saved, with no undo step (C: the store before the record that names it).
    private func receive(_ outcome: SmartOutcome, kind: SmartKind, key: SmartMasks.RunKey, ticket: MaskInference.Ticket,
                         source: SourceStamp?, update: Bool) async {
        // Another ask for the same mask took over (Try Again, Update), or the mask went.
        guard smartMasks.run(key)?.ticket == ticket, let frame = roll?.frames.first(where: { $0.url == key.frame }) else { return }
        guard source == SourceStamp.of(frame.url) else {
            smartMasks.setRun(.init(kind: kind, state: .failed("The RAW changed while it was being looked at."), ticket: nil, source: source), for: key)
            return
        }
        switch outcome {
        case .found(let seed, let maskFrame):
            let ref: RasterRef
            do { ref = try await storeMaskSeed(seed.raster) } catch {
                smartMasks.setRun(.init(kind: kind, state: .failed(error.localizedDescription), ticket: nil, source: source), for: key)
                return
            }
            guard smartMasks.run(key)?.ticket == ticket else { return }
            let selection = SmartSelection(kind: kind, raster: ref, frame: maskFrame, edge: seed.edge)
            if update {
                replaceSelection(of: key.mask, with: selection, provenance: seed.provenance, for: frame)
            } else {
                smartMasks.arrived[key.mask] = SmartMasks.Arrival(kind: kind, selection: selection, provenance: seed.provenance)
                attachArrivals(for: frame)
            }
            smartMasks.setRun(nil, for: key)
            announce(update ? "Updated \(kind.object)" : "Found \(kind.object)")
            if var timing = smartMasks.timings[key.mask] {
                timing.arrived = CACurrentMediaTime()
                smartMasks.timings[key.mask] = timing
            }
        case .nothingFound(_, _, let maskFrame):
            smartMasks.setRun(.init(kind: kind, state: update ? .updateFoundNothing : .empty(maskFrame), ticket: nil, source: source), for: key)
            announce(update ? SmartRowStatus.updateFoundNothing(kind).text : SmartResult.nothingFoundMessage(kind))
        case .failed(let why):
            smartMasks.setRun(.init(kind: kind, state: .failed(why), ticket: nil, source: source), for: key)
            announce("Could not find \(kind.object)")
        case .cancelled:
            smartMasks.setRun(nil, for: key)
        }
    }

    /// Puts what arrived into the frame's edit: each mask with a pending selection of the kind that arrived for it. No undo step, and
    /// saved: a result is derived data of a mask that already exists (R7 6.3).
    private func attachArrivals(for frame: Frame) {
        guard var edit = manualEdits[frame.url], fillArrivals(in: &edit) else { return }
        manualEdits[frame.url] = edit
        saveManualFrame(frame)
        if frame.url == shownFrame?.url { maskEditor.canvas?.pictureChanged() }
    }

    /// Fills `edit`'s pending selections from what arrived for their masks; whether it changed anything. A restored undo state that
    /// predates an arrival is filled this way too, so undoing a slider moved while a selection ran never takes the selection away.
    @discardableResult
    func fillArrivals(in edit: inout ManualEdit) -> Bool {
        guard !smartMasks.arrived.isEmpty else { return false }
        var masks = edit.adjustments.masks.masks, changed = false
        for index in masks.indices {
            guard let arrival = smartMasks.arrived[masks[index].id] else { continue }
            for c in masks[index].components.indices {
                guard case .smart(let selection) = masks[index].components[c].shape, selection.kind == arrival.kind, selection.raster == nil else { continue }
                var filled = arrival.selection
                filled.feather = selection.feather   // a Feather set while it ran stays
                masks[index].components[c].shape = .smart(filled)
                if let ref = arrival.selection.raster { edit.maskNotes.rasters[ref.id.hex] = arrival.provenance }
                changed = true
            }
        }
        guard changed, let set = try? MaskSet(masks: masks, version: edit.adjustments.masks.version) else { return false }
        edit.adjustments = edit.adjustments.settingMasks(set)
        return true
    }

    /// Update: the new selection in place of the old in one undo step, the mask's adjustments kept. Undo brings the old seed back.
    ///
    /// A seed that arrives while a gesture is open on the frame (a slider's drag, a stroke, a gradient's handle) joins that gesture
    /// and leaves it open, so the step that gesture ends as is the one that brings the old seed back. Ending the gesture here cut it
    /// in two: its second half was a step with the wrong name, and a Light row's drag left what it moved after that with the print
    /// alone (`endLightAdjusting` writes it only inside a gesture), so the film showed values the edit did not hold.
    private func replaceSelection(of id: UUID, with selection: SmartSelection, provenance: RasterProvenance, for frame: Frame) {
        guard var mask = mask(id, for: frame),
              let index = mask.components.firstIndex(where: { if case .smart(let s) = $0.shape { s.kind == selection.kind } else { false } }),
              canAdjust(frame), let set = try? { () throws -> MaskSet in
                  var updated = selection
                  if case .smart(let old) = mask.components[index].shape { updated.feather = old.feather }   // Update keeps the Feather
                  mask.components[index].shape = .smart(updated)
                  return try manualAdjustments(for: frame).masks.replacing(mask)
              }() else { return }
        let joins = manualGestures[frame.url] != nil
        if !joins { beginManualGesture(for: frame) }
        setManualAdjustments(manualAdjustments(for: frame).settingMasks(set), for: frame)
        if let ref = selection.raster { manualEdits[frame.url]?.maskNotes.rasters[ref.id.hex] = provenance }
        if !joins { endManualGesture(for: frame, actionName: "Update Mask") }
    }

    /// Says `text` to VoiceOver: what a key or a finished wait did, where nothing the keyboard is on changes.
    func announce(_ text: String) {
        guard let window = NSApp?.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // MARK: Keeping up with the edit

    /// The masks of `frame` changed by a gesture: a run whose mask has gone, or no longer waits for it, stops.
    func smartMasksChanged(for frame: Frame) {
        let present = Dictionary(masks(for: frame).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, run) in smartMasks.runs where key.frame == frame.url {
            let waits = present[key.mask].map { mask in
                if case .working(_, update: true) = run.state { return true }
                return mask.pendingSmart.contains(run.kind)
            } ?? false
            if !waits { stopSelection(key) }
        }
    }

    /// An Undo or a Redo restored `frame`'s edit: what arrived goes into the restored masks; a run whose mask the step took away
    /// stops (undo while it runs cancels); and a pending selection the step brought back with nothing running for it is asked
    /// for again (redo asks again).
    func smartMasksRestored(for frame: Frame, before: [Mask]) {
        if var edit = manualEdits[frame.url], fillArrivals(in: &edit) { manualEdits[frame.url] = edit }
        smartMasksChanged(for: frame)
        let had = Set(before.filter { !$0.pendingSmart.isEmpty }.map(\.id))
        for mask in masks(for: frame) where !had.contains(mask.id) {
            guard let kind = mask.pendingSmart.first, smartMasks.run(.init(frame: frame.url, mask: mask.id)) == nil else { continue }
            askSelection(kind, mask: mask.id, for: frame)
        }
    }

    /// Runs `ask`, which asks for the smart selections a paste brought to `frames`, keeping DA3 loaded until the Sky ones among
    /// them have all landed or stopped, as an open Masks tab keeps it (`MaskInference.tabOpened`): one run after another on the
    /// queue, a batch would otherwise load the model and let it go again for every frame. Held before the first ask, so the first
    /// run cannot let it go before the hold. The other models are loaded and let go inside each run, by their own rule.
    func holdingSkyModel(for frames: [Frame], _ ask: () -> Void) {
        let asksSky = frames.contains { frame in masks(for: frame).contains { $0.pendingSmart.contains(.sky) } }
        let queue = asksSky && smartAvailability(.sky).isAvailable ? smartMasks.queue : nil
        queue?.tabOpened()
        ask()
        guard let queue else { return }
        let urls = Set(frames.map(\.url))
        let fills = smartMasks.fills.filter { urls.contains($0.key.frame) && smartMasks.run($0.key)?.kind == .sky }.map(\.value.task)
        Task {
            for fill in fills { await fill.value }
            queue.tabClosed()
        }
    }

    func stopSelection(_ key: SmartMasks.RunKey) {
        if let ticket = smartMasks.run(key)?.ticket { smartMasks.queue?.cancel(ticket) }
        smartMasks.fills[key]?.task.cancel()
        smartMasks.fills[key] = nil
        smartMasks.setRun(nil, for: key)
    }

    // MARK: The row's actions

    /// Cancel on a row whose selection runs: the click undone, as if it had not been made. An Update in progress just stops.
    func cancelSelection(_ id: UUID, for frame: Frame) {
        let key = SmartMasks.RunKey(frame: frame.url, mask: id)
        if case .working(_, update: true)? = smartMasks.run(key)?.state {
            stopSelection(key)
            return
        }
        stopSelection(key)
        deleteMask(id, for: frame)
    }

    /// Try Again on a failed or unfinished selection: asked again, no undo step, since the mask already waits for it.
    /// When the mask models are not installed yet, opens their licence and download screen instead.
    func retrySelection(_ id: UUID, for frame: Frame) {
        guard let kind = mask(id, for: frame)?.pendingSmart.first else { return }
        if case .needsModels = smartAvailability(kind) {
            showMaskModels()
            return
        }
        askSelection(kind, mask: id, for: frame)
    }

    /// `copy`, a duplicate of `original` made while `original`'s selection is being found, waits for the same selection: an arrival
    /// goes to the mask that asked (`receive`), so a copy that asked for nothing would stay unmade with nothing running for it. Its
    /// ask joins the run under way (`MaskInference`, "Coalesced") and runs no model again.
    func joinSelection(of original: UUID, as copy: UUID, for frame: Frame) {
        guard case .working(_, update: false)? = smartMasks.run(.init(frame: frame.url, mask: original))?.state,
              let kind = mask(copy, for: frame)?.pendingSmart.first else { return }
        askSelection(kind, mask: copy, for: frame)
    }

    /// Paint It Instead on an empty selection: the mask keeps its row, name and adjustments, its selection becomes a brush to paint,
    /// selected with the brush in hand. One undo step.
    func paintInstead(_ id: UUID, for frame: Frame) {
        let key = SmartMasks.RunKey(frame: frame.url, mask: id)
        guard mask(id, for: frame)?.pendingSmart.isEmpty == false, canAdjust(frame) else { return }
        guard case .empty(let looked)? = smartMasks.run(key)?.state, let maskFrame = looked ?? smartMasks.arrived[id]?.selection.frame else { return }
        // A press under way ends first and writes the edit as it does, so the masks are read after it.
        maskEditor.finishPress()
        guard var mask = mask(id, for: frame),
              let index = mask.components.firstIndex(where: { if case .smart(let s) = $0.shape { s.raster == nil } else { false } }) else { return }
        mask.components[index] = MaskComponent(operation: mask.components[index].operation, shape: .brush(BrushPaint(frame: maskFrame)),
                                               invert: mask.components[index].invert)
        guard canAdjust(frame), let set = try? manualAdjustments(for: frame).masks.replacing(mask) else { return }
        beginManualGesture(for: frame)
        setManualAdjustments(manualAdjustments(for: frame).settingMasks(set), for: frame)
        endManualGesture(for: frame, actionName: "Paint Mask Instead")
        smartMasks.setRun(nil, for: key)
        maskEditor.selection = MaskEditor.Selection(mask: id, component: index)
        // The brush paints the component it leaves selected: the first stroke fills that brush, not a new mask (`MaskBrush.target`).
        maskEditor.brush.target = maskEditor.selection
        maskEditor.arm(.brush)
        maskEditor.requestPhotographFocus()
        if let films, let held = films.brushPicture(for: frame, lens: maskEditor.pictureLens(on: frame)?.settings ?? lensSettings(for: frame)) {
            Task { await films.prepareBrush(picture: held.picture) }
        }
    }

    /// Update on a stale seed: made again with the current model, the old one kept until the new one arrives (one undo step then).
    func updateSelection(_ id: UUID, for frame: Frame) {
        guard let kind = staleSelection(of: id, for: frame)?.kind else { return }
        if case .needsModels = smartAvailability(kind) {
            showMaskModels()
            return
        }
        askSelection(kind, mask: id, for: frame, update: true)
    }

    /// Keep on a stale seed: the note goes for this model, and the seed stays as it is.
    func keepSelection(_ id: UUID, for frame: Frame) {
        let key = SmartMasks.RunKey(frame: frame.url, mask: id)
        if case .updateFoundNothing? = smartMasks.run(key)?.state { smartMasks.setRun(nil, for: key) }
        guard let stale = staleSelection(of: id, for: frame, ignoringKept: true), let pins = smartMasks.pins, let raster = stale.raster else { return }
        smartMasks.keep(raster.id, against: pins.pin(for: stale.kind))
    }

    func perform(_ action: SmartRowStatus.Action, on id: UUID, for frame: Frame) {
        switch action {
        case .cancel: cancelSelection(id, for: frame)
        case .paintInstead: paintInstead(id, for: frame)
        case .remove:
            stopSelection(.init(frame: frame.url, mask: id))
            deleteMask(id, for: frame)
        case .retry: retrySelection(id, for: frame)
        case .update: updateSelection(id, for: frame)
        case .keep: keepSelection(id, for: frame)
        }
    }

    // MARK: What the row shows

    /// The selection a stale seed came from, if `mask`'s seed was made with an earlier model and no Keep dismissed it for this one.
    private func staleSelection(of id: UUID, for frame: Frame, ignoringKept: Bool = false) -> SmartSelection? {
        guard let mask = mask(id, for: frame), let pins = smartMasks.pins else { return nil }
        for component in mask.components {
            guard case .smart(let selection) = component.shape, let raster = selection.raster,
                  let provenance = manualEdits[frame.url]?.maskNotes.rasters[raster.id.hex],
                  pins.isStale(provenance, kind: selection.kind) else { continue }
            if !ignoringKept, smartMasks.kept[raster.id.hex] == pins.pin(for: selection.kind) { continue }
            return selection
        }
        return nil
    }

    /// Whether Vision, not the bundled models, found `mask`'s selection: a seed an earlier Argent made where a model was absent, its provenance
    /// saying why in `fallback`. This build never makes one.
    private func isVisionFallback(of id: UUID, for frame: Frame) -> Bool {
        guard let mask = mask(id, for: frame) else { return false }
        return mask.components.contains { component in
            guard case .smart(let selection) = component.shape, let raster = selection.raster else { return false }
            return manualEdits[frame.url]?.maskNotes.rasters[raster.id.hex]?.parameters["fallback"] != nil
        }
    }

    /// What `mask`'s row says about its selection, or of a brush with no point left for a stroke; `nil` when it has nothing to say.
    func smartStatus(of mask: Mask, for frame: Frame) -> SmartRowStatus? {
        let key = SmartMasks.RunKey(frame: frame.url, mask: mask.id)
        let kind = mask.components.lazy.compactMap { if case .smart(let s) = $0.shape { s.kind } else { nil } }.first
        guard let kind else { return SmartRowStatus.brushIsFull(mask) ? .brushFull : nil }
        if let run = smartMasks.run(key) {
            switch run.state {
            case .working(let stage, let update): return .working(stage, kind: kind, update: update)
            case .empty: return .empty(kind)
            case .failed(let why): return .failed(kind, why: why)
            case .updateFoundNothing: return .updateFoundNothing(kind)
            }
        }
        if !mask.pendingSmart.isEmpty { return .notMade(kind) }
        if staleSelection(of: mask.id, for: frame) != nil { return .stale(kind) }
        if isVisionFallback(of: mask.id, for: frame) { return .visionFallback(kind) }
        return SmartRowStatus.brushIsFull(mask) ? .brushFull : nil
    }

    // MARK: The Masks tab and the develop

    /// The Masks tab appeared: DA3 stays loaded once a Sky click loads it, until the tab goes; and Follow edges' kernels and the refiner's compile now,
    /// off the main thread, so a press does not wait for them (N, measured: 1.7 s at the press on a cold compile cache, when they waited for A or K).
    func masksTabAppeared() {
        smartMasks.queue?.tabOpened()
        if let films { Task { await films.prepareMaskKernels() } }
    }

    /// The Masks tab shows `frame`: its input picture is made now, ahead of a click.
    func masksTabShows(_ frame: Frame) { smartMasks.queue?.tabShows(frame, lens: lensSettings(for: frame)) }

    /// The Masks tab has gone: DA3 goes with it.
    func masksTabDisappeared() { smartMasks.inference?.tabClosed() }

    /// Before a develop saves and prints: the selections under way on its frames land first, so each prints what its row will show.
    /// A frame whose selection was never made is the developer's to refuse.
    func waitForSelections(on frames: [URL]) async {
        let wanted = Set(frames)
        var awaited = Set<UUID>()
        while true {
            // A selection asked again meanwhile (Try Again on another frame's row) is waited for too.
            let waiting = smartMasks.fills.filter { wanted.contains($0.key.frame) && !awaited.contains($0.value.id) }.map(\.value)
            guard !waiting.isEmpty, !Task.isCancelled else { return }
            for fill in waiting {
                await fill.task.value
                awaited.insert(fill.id)
            }
        }
    }

    // MARK: The print

    /// The edit as the previews print it: a mask whose selection is not made yet is left out, so the print stays as it was while
    /// it runs and the sliders take effect when it lands (R7 8). A develop is never given this: it refuses such a frame.
    nonisolated static func printable(_ edit: ManualEdit?) -> ManualEdit? {
        guard var edit, edit.adjustments.masks.masks.contains(where: { !$0.pendingSmart.isEmpty }) else { return edit }
        let masks = edit.adjustments.masks.masks.map { mask -> Mask in
            guard !mask.pendingSmart.isEmpty else { return mask }
            var off = mask
            off.isEnabled = false
            return off
        }
        guard let set = try? MaskSet(masks: masks, version: edit.adjustments.masks.version) else { return edit }
        edit.adjustments = edit.adjustments.settingMasks(set)
        return edit
    }
}
