import ArgentCore
import ArgentRoll
import AppKit
import Foundation

struct VisibleAutomatic: Equatable {
    let aim: PrintAim
    let settings: DevelopSettings
    let stockID: String
    let stockDigest: String
    let controls: RollControls
}

struct ManualUndoState: Equatable {
    var edit: ManualEdit?
    var held: ManualEdit?
    var issue: String?
}

/// One frame's part of a paste's undo step: its edit as `ManualUndoState` holds it, and its own Rated at and Lab balance, which a paste
/// carries and no other step does (docs/context-menus-plan.md, rule 6).
struct PasteUndoState: Equatable {
    var frame: URL
    var edit: ManualUndoState
    var own: FrameControls?
}

/// A frame's save that failed, and the edit revision it was saving.
struct ManualSaveFailure: Equatable {
    let revision: UInt64
    let message: String
}

/// What reading a frame's saved recipe into the session came to.
private enum ManualLoad {
    /// Read, or found to be unusable, which `manualErrors` says; with the recipe checked against
    /// its raw when the raw's digest is known.
    case loaded(RecipeStore.Checked?)
    /// Its raw could not be read; see `loadManualRecipe(for:generation:)`.
    case unread
    /// Another session began meanwhile.
    case superseded
}

extension RollModel {
    func manualAdjustments(for frame: Frame) -> ManualAdjustments {
        manualEdits[frame.url]?.adjustments ?? .identity
    }

    func setToneCurves(_ curves: ToneCurves, for frame: Frame) {
        setManualAdjustments(manualAdjustments(for: frame).settingCurves(curves), for: frame)
    }

    func resetToneCurves(for frame: Frame) { setToneCurves(.identity, for: frame) }

    func hasManualAdjustments(_ frame: Frame) -> Bool { manualEdits[frame.url] != nil }

    /// Where the frame's edits start: its Original once chosen, else Auto (docs/manual-development.md,
    /// "Starting from Original").
    func startingPoint(for frame: Frame) -> AutomaticBaseline.Origin { manualEdits[frame.url]?.baseline.origin ?? .auto }

    /// Whether the frame's adjustments can change. The first one pins the automatic result on screen
    /// (`AutomaticBaseline`), so it waits for the roll's settled decision and for that decision's film
    /// to be the one shown: a pin is never taken of an aim the roll is about to leave.
    func canAdjust(_ frame: Frame) -> Bool {
        guard isReadyToPin(frame) else { return false }
        if manualEdits[frame.url] != nil { return true }
        return settledVisibleAutomatic(for: frame) != nil
    }

    /// A first edit's guards short of Auto's: the session ready, the frame's recipe read, its RAW
    /// verified as it is now, its measurement made and no issue.
    private func isReadyToPin(_ frame: Frame) -> Bool {
        guard !isScanning, !isQuitting, !isRestoringManual, frameMove == nil, manualLoaded.contains(frame.url), adjustmentIssue(for: frame) == nil,
              let verified = manualReadySources[frame.url], SourceStamp.of(frame.url) == verified.source else { return false }
        return analysis(for: frame) != nil
    }

    /// Start from Original and Frame > Reset to Original: a first edit's guards, without waiting for
    /// the roll's settled decision, which an Original pin does not read; and something to clear, a
    /// frame from Auto or an Original with refinements.
    func canStartFromOriginal(_ frame: Frame) -> Bool {
        guard isReadyToPin(frame) else { return false }
        // A frame from Auto is pinned anew, through its stock: none installed, nothing to pin through.
        guard let edit = manualEdits[frame.url], edit.baseline.origin == .original else { return stock(for: frame) != nil }
        return !edit.adjustments.isIdentity
    }

    /// Reset to Current Auto: an edit to release, while the session is not opening, quitting or restoring.
    func canResetManual(_ frame: Frame) -> Bool {
        hasManualAdjustments(frame) && !isScanning && !isQuitting && !isRestoringManual && frameMove == nil
    }

    /// The inspector's Start from can choose the other starting point: Auto as Reset to Current Auto
    /// can, or Original as a first edit could.
    func canChangeStartingPoint(_ frame: Frame) -> Bool {
        startingPoint(for: frame) == .original ? canResetManual(frame) : isReadyToPin(frame)
    }

    /// The settled aim paired with the automatic render already on screen. A changed cast under
    /// Neutral, Warm or Cool can leave that render unchanged, so no film task runs to record the new
    /// aim. Matching the settings lets the first edit pin the settled aim without waiting for a
    /// redundant render; a change that affects the picture still waits until it is shown.
    private func settledVisibleAutomatic(for frame: Frame) -> VisibleAutomatic? {
        let index = stockIndex(for: frame)
        guard isBalanced, let visible = visibleAutomatic[frame.url], let stock = stock(for: frame),
              visible.stockID == stock.id, visible.stockDigest == stockDigests[index],
              visible.controls == controls(for: frame), visible.settings == settings(for: frame, stock: index)
        else { return nil }
        return VisibleAutomatic(aim: printAim(for: frame), settings: visible.settings,
                                stockID: visible.stockID, stockDigest: visible.stockDigest, controls: visible.controls)
    }

    /// Whether the roll's settled decision aims the edited frame elsewhere than its pin, which stays
    /// where it is: Auto never moves a pinned frame, nor learns from its edits. An Original has no
    /// Auto to follow.
    func hasUpdatedAuto(_ frame: Frame) -> Bool {
        guard isBalanced, let edit = manualEdits[frame.url], edit.baseline.origin == .auto else { return false }
        return edit.baseline.aim != printAim(for: frame)
    }

    /// What keeps the frame from printing its edit: an issue with the edit itself (`adjustmentIssue`), or a smart mask's seed that is
    /// missing or damaged (`maskSeedIssue`). Develop refuses a frame with one, and the frame view shows no film for it.
    func manualIssue(for frame: Frame) -> String? {
        adjustmentIssue(for: frame) ?? maskSeedIssue(for: frame)
    }

    /// An issue with the edit itself, which stops the frame being adjusted and a develop starting. A lost seed is not one: the mask
    /// that names it must stay removable, and it holds up only its own frame's save and develop.
    func adjustmentIssue(for frame: Frame) -> String? {
        if let error = manualErrors[frame.url] { return error }
        if let error = manualPreparationErrors[frame.url] { return error }
        guard let edit = manualEdits[frame.url], let stock = stock(for: frame) else { return nil }
        do {
            _ = try DevelopmentResolver.resolve(stock: stock, stockDigest: stockDigests[stockIndex(for: frame)],
                controls: controls(for: frame), aim: printAim(for: frame), manual: edit,
                grain: grain(for: frame).amount, grainSeed: frame.grainSeed, sharpen: true)
            return nil
        } catch { return error.localizedDescription }
    }

    func manualIssueRequiresReapply(for frame: Frame) -> Bool { heldManualEdits[frame.url] != nil }

    func recordVisibleAutomatic(for frame: Frame, stock: Int, aim: PrintAim, settings: DevelopSettings) {
        guard manualEdits[frame.url] == nil, settings.manual.adjustments.isIdentity,
              let films, films.stocks.indices.contains(stock) else { return }
        visibleAutomatic[frame.url] = VisibleAutomatic(aim: aim, settings: settings,
            stockID: films.stocks[stock].id, stockDigest: stockDigests[stock], controls: controls(for: frame))
    }

    func automaticSettings(for frame: Frame, stock: Int) -> DevelopSettings {
        var settings = settings(for: frame, stock: stock)
        settings.manual = (try? ManualRenderSettings(adjustments: .identity.setting(.lens, from: settings.manual.adjustments),
                                                    referenceStops: settings.manual.referenceStops, version: settings.manual.version)) ?? .identity
        return settings
    }

    func prepareManualAdjustments(for frame: Frame) async {
        let generation = manualGeneration
        // The roll restore owns each frame's first read, so an edit cannot race restoration.
        if let restoration = manualRestoreTask { await restoration.value }
        guard !Task.isCancelled, generation == manualGeneration,
              roll?.frames.contains(where: { $0.url == frame.url }) == true else { return }
        // A recipe the restore could not read is read first: its saved adjustments come before any edit.
        if !manualLoaded.contains(frame.url) {
            guard case .loaded = await loadManualRecipe(for: frame, generation: generation) else { return }
        }
        await analyze(frame, priority: .veryHigh)
        guard !Task.isCancelled, generation == manualGeneration else { return }
        let source = SourceStamp.of(frame.url)
        do {
            let verified = try await Task.detached(priority: .userInitiated) {
                try SourceDigests.shared.digest(of: frame.url)
            }.value
            guard !Task.isCancelled, generation == manualGeneration, verified.source == source,
                  SourceStamp.of(frame.url) == verified.source, sourceStamp(for: frame) == verified.source,
                  roll?.frames.contains(where: { $0.url == frame.url }) == true else { return }
            manualReadySources[frame.url] = verified
            manualPreparationErrors[frame.url] = nil
        } catch {
            guard !Task.isCancelled, generation == manualGeneration,
                  roll?.frames.contains(where: { $0.url == frame.url }) == true else { return }
            manualPreparationErrors[frame.url] = "Could not prepare adjustments: \(error.localizedDescription)"
        }
    }

    func beginManualGesture(for frame: Frame) {
        guard manualGestures[frame.url] == nil else { return }
        manualGestures[frame.url] = undoState(for: frame)
    }

    func setManualAdjustments(_ values: ManualAdjustments, for frame: Frame) {
        guard values != manualAdjustments(for: frame), canAdjust(frame) else { return }
        let standalone = manualGestures[frame.url] == nil
        if standalone { beginManualGesture(for: frame) }
        if var edit = manualEdits[frame.url] {
            edit.adjustments = values
            manualEdits[frame.url] = edit
        } else if let visible = settledVisibleAutomatic(for: frame), let verified = manualReadySources[frame.url] {
            let baseline = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: visible.stockID,
                stockDigest: visible.stockDigest, controls: visible.controls, aim: visible.aim,
                analysisVersion: ExposureAnalysis.currentVersion, resolverVersion: DevelopmentResolver.currentVersion,
                baseRender: Recipe.Render(settings: visible.settings, grain: grain(for: frame)))
            manualEdits[frame.url] = ManualEdit(adjustments: values, baseline: baseline)
        }
        if developPhase == .done { developPhase = .idle }
        if standalone { endManualGesture(for: frame) }
    }

    /// Ends the frame's gesture as one undo step called `actionName`. An edit from Auto left with no
    /// refinement releases its pin; an Original keeps its own (docs/manual-development.md, "Starting
    /// from Original"). A mask that went with it is no longer selected.
    func endManualGesture(for frame: Frame, actionName: String = "Adjust Frame") {
        // A Light row's steps the print took reach the edit first, inside the gesture, so they are this step (`moveLight`).
        if manualGestures[frame.url] != nil { takePrintedLight(for: frame, writing: true) }
        guard let before = manualGestures.removeValue(forKey: frame.url) else { return }
        // A removal whose patch arrived during the gesture enters the edit after it, as a step of its own.
        defer { removalRuns.gestureEnded(on: frame.url) }
        if manualEdits[frame.url]?.isEmpty == true { manualEdits[frame.url] = nil }
        smartMasksChanged(for: frame)
        if frame.url == shownFrame?.url {
            let kept = MaskEditor.kept(maskEditor.selection, in: masks(for: frame))
            if kept != maskEditor.selection { maskEditor.selection = kept }
        }
        guard before != undoState(for: frame) else { return }
        registerManualUndo(before, for: frame, actionName: actionName)
        saveManualFrame(frame)
    }

    /// Abandons the frame's gesture: back to how it began, with no undo step and nothing to save. A smart selection that arrived
    /// while the gesture was open is no part of it (`attachArrivals` wrote it into the edit, with no step) and stays, as it does
    /// through an Undo; what was saved as it arrived held the gesture's own changes, so the frame is saved again as it now is.
    func cancelManualGesture(for frame: Frame) {
        takePrintedLight(for: frame, writing: false)
        guard let before = manualGestures.removeValue(forKey: frame.url) else { return }
        defer { removalRuns.gestureEnded(on: frame.url) }
        manualEdits[frame.url] = before.edit
        heldManualEdits[frame.url] = before.held
        manualErrors[frame.url] = before.issue
        if var edit = before.edit, fillArrivals(in: &edit) {
            manualEdits[frame.url] = edit
            saveManualFrame(frame)
        }
    }

    /// Reset to Current Auto, and Start from Auto: every value cleared and the pin released, an
    /// Original's too. A Light-tab drag held on the frame goes on after it, as after a group reset.
    func resetManualAdjustments(for frame: Frame, actionName: String = "Adjust Frame") {
        guard canResetManual(frame) else { return }
        let held = suspendLightAdjusting(on: [frame.url])
        defer { resumeLightAdjusting(on: held) }
        beginManualGesture(for: frame)
        manualEdits[frame.url] = nil
        manualErrors[frame.url] = nil
        endManualGesture(for: frame, actionName: actionName)
        if developPhase == .done { developPhase = .idle }
        isComparingAuto = false
    }

    /// Start from Original, Frame > Reset to Original, and the inspector's Reset on an Original: Light
    /// and Curves cleared and the Original the starting point, in one undo step called `actionName`.
    /// An Original keeps its pin, at the current compiler as a new edit takes; a frame from Auto is
    /// pinned anew at the neutral aim, at the current stock, controls and resolver, without waiting
    /// for the roll's settled decision, which the pin does not read. A Light-tab drag held on the frame goes on after it, as after
    /// a group reset.
    func startFromOriginal(for frame: Frame, actionName: String = "Start from Original") {
        guard canStartFromOriginal(frame) else { return }
        let held = suspendLightAdjusting(on: [frame.url])
        defer { resumeLightAdjusting(on: held) }
        var edit: ManualEdit
        if let kept = manualEdits[frame.url], kept.baseline.origin == .original {
            edit = kept
            edit.adjustments = .identity
            edit.curveVersion = ManualRenderSettings.currentVersion
        } else {
            let controls = controls(for: frame), grain = grain(for: frame)
            guard let stock = stock(for: frame), let digest = stockDigests[safe: stockIndex(for: frame)],
                  let verified = manualReadySources[frame.url],
                  let base = try? DevelopmentResolver.resolve(stock: stock, stockDigest: digest,
                      controls: controls, aim: PrintAim(), manual: nil, grain: grain.amount,
                      grainSeed: frame.grainSeed, sharpen: true, origin: .original) else { return }
            edit = ManualEdit(adjustments: .identity, baseline: .original(sourceSHA256: verified.sha256, stockID: stock.id,
                stockDigest: digest, controls: controls, baseRender: Recipe.Render(settings: base, grain: grain)))
        }
        beginManualGesture(for: frame)
        manualEdits[frame.url] = edit
        endManualGesture(for: frame, actionName: actionName)
        if developPhase == .done { developPhase = .idle }
        isComparingAuto = false
    }

    /// The inspector's Start from: Auto as Reset to Current Auto, or Original. Each clears the frame's
    /// Light and Curve values, one undo step named for the choice.
    func startFrom(_ origin: AutomaticBaseline.Origin, for frame: Frame) {
        guard origin != startingPoint(for: frame) else { return }
        switch origin {
        case .auto: resetManualAdjustments(for: frame, actionName: "Start from Auto")
        case .original: startFromOriginal(for: frame)
        }
    }

    /// The Light tab's Reset Light (its Reset with Option held, as Lightroom's group headings): the
    /// six Light values to zero in one undo step, Curves, masks, Presence and the pin kept. With nothing
    /// left, the gesture's end releases an Auto pin, as Reset to Current Auto does; an Original stays.
    func resetLight(for frame: Frame) { reset(.light, for: frame) }

    /// Reset Presence: Texture, Clarity, Dehaze, Vibrance and Saturation cleared in one undo step, Light, the curves and the masks
    /// kept, as Reset Light keeps Presence. A frame left with nothing lets its pin go, as Reset Light's does.
    func resetPresence(for frame: Frame) { reset(.presence, for: frame) }

    func resetLens(for frame: Frame) { reset(.lens, for: frame) }

    /// A group reset. A Light-tab drag held on the frame is ended first and opened again after, as a paste ends and resumes one
    /// (`suspendLightAdjusting`): its pending values reach the edit before the reset rather than over it, and what it sets after the
    /// reset is printed from the cleared edit and written at its release (docs/presence-plan.md, section 3).
    private func reset(_ parts: ManualAdjustments.Parts, for frame: Frame) {
        let held = suspendLightAdjusting(on: [frame.url])
        defer { resumeLightAdjusting(on: held) }
        let values = manualAdjustments(for: frame), cleared = values.clearing(parts)
        guard cleared != values, canAdjust(frame) else { return }
        beginManualGesture(for: frame)
        setManualAdjustments(cleared, for: frame)
        endManualGesture(for: frame)
        if manualEdits[frame.url] == nil { isComparingAuto = false }
    }

    /// Update Automatic Baseline: the edit's values on its starting point taken again at the current
    /// versions, an Original's at the neutral aim, so an Original with no refinement can update too.
    func updateAutomaticBaseline(for frame: Frame) {
        guard let edit = manualEdits[frame.url], !edit.isEmpty else { return }
        replaceBaseline(for: frame, values: edit.adjustments, notes: edit.maskNotes, origin: edit.baseline.origin)
    }

    /// Reapply Adjustments onto new bytes: placed shapes come across with their ids and names, and a
    /// smart mask's seed stays behind, since it measured the old picture.
    func reapplyManualAdjustments(for frame: Frame) {
        guard let old = heldManualEdits[frame.url] else { return }
        do {
            replaceBaseline(for: frame, values: try old.adjustments.forAnotherPicture(freshIDs: false, geometry: maskLens(for: frame, settings: old.adjustments.lens)?.picture),
                            notes: old.maskNotes, origin: old.baseline.origin)
        } catch { manualErrors[frame.url] = error.localizedDescription }
    }

    private func replaceBaseline(for frame: Frame, values: ManualAdjustments, notes: MaskNotes, origin: AutomaticBaseline.Origin) {
        let generation = manualGeneration
        Task {
            guard !Task.isCancelled, generation == manualGeneration else { return }
            await prepareManualAdjustments(for: frame)
            // Pinned to the roll's settled decision, never to an aim it is about to leave. An Original
            // reads no decision.
            if origin == .auto { guard await settledDecision(priority: .veryHigh) != nil else { return } }
            guard !Task.isCancelled, generation == manualGeneration, !isScanning, !isQuitting,
                  let current = roll?.frames.first(where: { $0.url == frame.url }),
                  let verified = manualReadySources[frame.url], SourceStamp.of(frame.url) == verified.source,
                  let stock = stock(for: current),
                  analysis(for: frame) != nil else { return }
            let before = undoState(for: frame)
            let aim = origin == .original ? PrintAim() : printAim(for: frame), controls = controls(for: frame)
            let digest = stockDigests[stockIndex(for: current)], grain = grain(for: current)
            do {
                let base = try DevelopmentResolver.resolve(stock: stock, stockDigest: digest,
                    controls: controls, aim: aim, manual: nil, grain: grain.amount,
                    grainSeed: current.grainSeed, sharpen: true, origin: origin)
                let baseline = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: stock.id,
                    stockDigest: digest, controls: controls, aim: aim,
                    analysisVersion: ExposureAnalysis.currentVersion, resolverVersion: DevelopmentResolver.currentVersion,
                    baseRender: Recipe.Render(settings: base, grain: grain), origin: origin)
                // The current baseline and the current compilers, Light, curves, masks and Presence alike.
                let updated = try values.updatingVersions()
                manualEdits[frame.url] = ManualEdit(adjustments: updated, baseline: baseline,
                                                    curveVersion: ManualRenderSettings.currentVersion, maskNotes: notes)
                heldManualEdits[frame.url] = nil
                manualErrors[frame.url] = nil
                registerManualUndo(before, for: current)
                saveManualFrame(current)
                if developPhase == .done { developPhase = .idle }
            } catch { manualErrors[frame.url] = error.localizedDescription }
        }
    }

    private func undoState(for frame: Frame) -> ManualUndoState {
        ManualUndoState(edit: manualEdits[frame.url], held: heldManualEdits[frame.url], issue: manualErrors[frame.url])
    }

    func pasteUndoState(for frame: Frame) -> PasteUndoState {
        PasteUndoState(frame: frame.url, edit: undoState(for: frame), own: overrides[frame.url])
    }

    /// Registers the step back to `state`, named `actionName`; its Redo keeps the name.
    private func registerManualUndo(_ state: ManualUndoState, for frame: Frame, actionName: String = "Adjust Frame") {
        // A step that brings a smart mask back brings its seed's name back: the sweep keeps that seed while the step exists. A
        // removal's patch likewise: Try Again leaves the patch it replaced for its Undo to return to.
        undoSeeds.formUnion([state.edit, state.held].compactMap { $0 }.flatMap(\.adjustments.masks.rasters).map(\.id))
        undoPatches.formUnion([state.edit, state.held].compactMap { $0 }.flatMap(\.adjustments.removals).map(\.patch.id))
        manualUndoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreManualUndo(state, for: frame, actionName: actionName) }
        }
        manualUndoManager?.setActionName(actionName)
    }

    private func restoreManualUndo(_ state: ManualUndoState, for frame: Frame, actionName: String) {
        guard let current = roll?.frames.first(where: { $0.url == frame.url }) else { return }
        // A gradient moving under the pointer is let go first: the undo cannot sit inside its gesture. A Light drag still held is taken
        // back with the step, unwritten, and goes on from what the undo leaves; the undo opens this frame, so a drag on another is
        // left behind too.
        maskEditor.cancelPress()
        let held = suspendLightAdjusting(on: Set(roll?.frames.map(\.url) ?? []), writing: false)
        defer { resumeLightAdjusting(on: held) }
        registerManualUndo(undoState(for: current), for: current, actionName: actionName)
        let masksBefore = putBack(state, for: current)
        selection = current.id
        openFrame()
        isComparingAuto = false
        reconcileMaskSelection(from: masksBefore, for: current)
        saveManualFrame(current)
        if developPhase == .done { developPhase = .idle }
    }

    /// `state` as `frame`'s edit again, for an Undo or a Redo: its smart selections kept up with (`smartMasksRestored`), and a pin
    /// on a raw that has changed since held aside. The masks the frame had before, for the selection to follow.
    private func putBack(_ state: ManualUndoState, for frame: Frame) -> [Mask] {
        let masksBefore = masks(for: frame)
        manualEdits[frame.url] = state.edit
        heldManualEdits[frame.url] = state.held
        manualErrors[frame.url] = state.issue
        smartMasksRestored(for: frame, before: masksBefore)
        // A historical baseline may never attach itself to a replaced RAW via Undo.
        if let edit = state.edit {
            let verified = manualReadySources[frame.url]
            if verified?.sha256 != edit.baseline.sourceSHA256 || verified?.source != SourceStamp.of(frame.url) {
                holdManualForChangedSource(frame.url)
            }
        }
        return masksBefore
    }

    /// Registers a paste's step back to `states`, every frame it wrote, named `actionName`; its Redo keeps the name. With `reveal`,
    /// a paste on one frame, the Undo selects and opens that frame as any edit's does; a batch's moves neither the selection nor the
    /// page (docs/context-menus-plan.md, rule 6).
    func registerPasteUndo(_ states: [PasteUndoState], actionName: String, reveal: Bool) {
        let edits = states.flatMap { [$0.edit.edit, $0.edit.held].compactMap { $0 } }
        undoSeeds.formUnion(edits.flatMap(\.adjustments.masks.rasters).map(\.id))
        undoPatches.formUnion(edits.flatMap(\.adjustments.removals).map(\.patch.id))
        manualUndoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restorePasteUndo(states, actionName: actionName, reveal: reveal) }
        }
        manualUndoManager?.setActionName(actionName)
    }

    private func restorePasteUndo(_ states: [PasteUndoState], actionName: String, reveal: Bool) {
        let current = Dictionary((roll?.frames ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let frames = states.compactMap { state in current[state.frame].map { (state, $0) } }
        guard !frames.isEmpty else { return }
        maskEditor.cancelPress()
        // The undo puts back each frame's own controls: a Halation gesture still open is written first, so its end does not write over them.
        suspendHalationAdjusting(writing: true)
        // A Light drag still held on a frame the undo writes, or on any when it opens its frame, is taken back as an edit's undo takes it.
        let held = suspendLightAdjusting(on: reveal ? Set(current.keys) : Set(frames.map(\.1.url)), writing: false)
        defer { resumeLightAdjusting(on: held) }
        registerPasteUndo(frames.map { pasteUndoState(for: $0.1) }, actionName: actionName, reveal: reveal)
        var own = overrides, masksBefore: [URL: [Mask]] = [:]
        for (state, frame) in frames {
            masksBefore[frame.url] = putBack(state.edit, for: frame)
            own[frame.url] = state.own
        }
        let choicesSaved = writeOverrides(own)
        if reveal, let frame = frames.first?.1 {
            selection = frame.id
            openFrame()
            isComparingAuto = false
            reconcileMaskSelection(from: masksBefore[frame.url] ?? [], for: frame)
        } else if let shown = shownFrame, let before = masksBefore[shown.url] {
            isComparingAuto = false
            reconcileMaskSelection(from: before, for: shown)
        }
        for (_, frame) in frames { savePasted(frame, choicesSaved: choicesSaved) }
        if developPhase == .done { developPhase = .idle }
    }

    /// Every frame's own Rated at and Lab balance at once, as a paste and its Undo give them: one write, so the roll's choices are
    /// saved once (`settingsChanged`), not once a frame. Whether that saved them.
    func writeOverrides(_ own: [URL: FrameControls]) -> Bool {
        guard own != overrides else { return false }
        let saves = roll != nil && !isScanning && manualRestoreTask == nil
        overrides = own
        return saves
    }

    /// Saves a frame a paste or its Undo wrote, unless saving the roll's choices just did (`writeOverrides`).
    func savePasted(_ frame: Frame, choicesSaved: Bool) {
        guard !(choicesSaved && savesWithChoices(frame.url)) else { return }
        saveManualFrame(frame)
    }

    func holdManualForChangedSource(_ url: URL) {
        if let edit = manualEdits.removeValue(forKey: url) {
            heldManualEdits[url] = edit
            manualErrors[url] = "The RAW has changed. Reapply Adjustments to use these values with its new automatic result."
        }
        manualReadySources[url] = nil
        manualPreparationErrors[url] = nil
        visibleAutomatic[url] = nil
        manualRecipes[url] = nil
    }

    /// A held edit is the frame's own again once its RAW is back as the bytes the edit was pinned
    /// on, as a replaced RAW put back is.
    private func releaseHeldManual(_ url: URL, sha256: String?) {
        guard manualEdits[url] == nil, let held = heldManualEdits[url], held.baseline.sourceSHA256 == sha256 else { return }
        manualEdits[url] = held
        heldManualEdits[url] = nil
        manualErrors[url] = nil
    }

    func saveManualChoices() {
        guard !isScanning, manualRestoreTask == nil, let roll else { return }
        // New untouched rolls do not need sidecars. Once a recipe exists, choices and resets
        // are durable without requiring a Develop, including roll-level changes.
        for frame in roll.frames where savesWithChoices(frame.url) { saveManualFrame(frame) }
    }

    /// Whether saving the roll's choices saves the frame: its recipe was read, and it has an edit, a held one, its own controls
    /// (stock, Rated at, Lab balance, grain or halation), or a recipe, read or on its way from a save this session began. So a frame given
    /// only its own stock has its first recipe saved, and one that follows the roll again before that save lands is saved again.
    private func savesWithChoices(_ url: URL) -> Bool {
        manualLoaded.contains(url) && (manualEdits[url] != nil || heldManualEdits[url] != nil || manualRecipes[url] != nil
            || overrides[url] != nil || manualSaveTasks[url] != nil)
    }

    func saveManualFrame(_ frame: Frame) {
        // A frame whose files are on their way out of the roll was saved before they went (`RollModel+Frames`); a save
        // now would leave a recipe beside a raw that is no longer there.
        guard let stock = stock(for: frame), !movingFrames.contains(frame.url) else { return }
        editRevision &+= 1
        let lineage = manualRecipes[frame.url]?.editLineage ?? manualLineages[frame.url] ?? editLineage
        let revision = editRevision, generation = manualGeneration
        let missingRollID = missingRollStockID, missingRollName = missingRollStockName
        let rollControls = controls, own = frameControls(frame), analysis = analysis(for: frame)
        let rollStock = missingRollID ?? currentStock?.id
        let aim = printAim(for: frame), edit = manualEdits[frame.url], hold = heldManualEdits[frame.url], output = output
        let previous = manualRecipes[frame.url], digest = stockDigests[stockIndex(for: frame)]
        let preceding = manualSaveTasks[frame.url]
        manualSaveMessage = "Saving adjustments…"
        manualSaveTasks[frame.url] = Task {
            if let preceding { await preceding.value }
            do {
                let verified = try await Task.detached(priority: .utility) { try SourceDigests.shared.digest(of: frame.url) }.value
                // Back on the bytes it was pinned on, a held edit is saved as the frame's edit.
                let restored = edit == nil && hold?.baseline.sourceSHA256 == verified.sha256
                let manual = restored ? hold : edit, held = restored ? nil : hold
                var recipe: Recipe
                do {
                    recipe = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url),
                        stock: stock, stockDigest: digest, roll: rollControls, own: own, rollStock: rollStock, analysis: analysis, aim: aim,
                        grain: output.grain, halation: output.halation, sharpen: true, previous: previous, manual: manual,
                        editRevision: revision, editLineage: lineage, heldManual: held)
                } catch {
                    // Preserve undo intent for an unavailable baseline without pretending it
                    // can be re-resolved. Rendering/export remain blocked until explicit update.
                    guard let manual else { throw error }
                    var recorded = manual.baseline.baseRender.settings
                    if let compiled = previous?.render.manual, compiled.adjustments == manual.adjustments,
                       compiled.version == manual.curveVersion { recorded.manual = compiled }
                    else {
                        recorded.manual = try ManualRenderSettings(adjustments: manual.adjustments,
                            referenceStops: manual.baseline.aim.level, version: manual.curveVersion)
                    }
                    recipe = Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url),
                        stock: stock, stockDigest: digest, roll: rollControls, own: own, rollStock: rollStock, analysis: analysis,
                        aim: manual.baseline.aim,
                        grain: output.grain, halation: output.halation, sharpen: true, previous: previous, manual: manual,
                        editRevision: revision, editLineage: lineage, heldManual: held, resolved: recorded)
                }
                if let manual, manual.baseline.sourceSHA256 != verified.sha256 { throw ManualSaveError.sourceChanged }
                // When the roll's stock is missing, keep its original stock reference in recipes for
                // frames following the roll so unrelated edits never overwrite it with the preview fallback.
                if own.stock == nil, let missingRollID {
                    if let prevStock = previous?.stock, prevStock.id == missingRollID {
                        recipe.stock = prevStock
                    } else {
                        recipe.stock.id = missingRollID
                        recipe.stock.displayName = missingRollName ?? missingRollID
                        recipe.stock.status = "custom"
                        recipe.stock.digest = ""
                    }
                }
                recipe.raw.sha256 = verified.sha256
                let committed = try await RecipeWriter.shared.commit(recipe: recipe, for: frame, library: recipeLibrary)
                guard generation == manualGeneration else { return }
                manualLineages[frame.url] = committed.editLineage
                maskSeedUnsaved.remove(frame.url)
                if restored, SourceStamp.of(frame.url) == verified.source { releaseHeldManual(frame.url, sha256: verified.sha256) }
                if manualRecipes[frame.url]?.editRevision ?? 0 <= committed.editRevision ?? 0 {
                    manualRecipes[frame.url] = committed
                }
                manualSaveFailures[frame.url] = nil
                manualSaveFailed = !manualSaveFailures.isEmpty
                if let failure = manualSaveFailures.values.first { manualSaveMessage = failure.message }
                else if revision == editRevision { manualSaveMessage = nil }
            } catch RecipeWriter.Failure.missingRaster, RecipeWriter.Failure.missingPatch {
                // A seed that is nowhere, or a removal's patch, is this frame's issue (`maskSeedIssue`): the writer wrote nothing, the edit stays here, and
                // the session's saves are not failed by it, so no other frame waits. A save of the frame after its mask goes, or after
                // its pack is back beside the raw, writes it.
                guard generation == manualGeneration else { return }
                maskSeedUnsaved.insert(frame.url)
                manualSaveFailures[frame.url] = nil
                manualSaveFailed = !manualSaveFailures.isEmpty
                if let failure = manualSaveFailures.values.first { manualSaveMessage = failure.message }
                else if revision == editRevision { manualSaveMessage = nil }
            } catch {
                guard generation == manualGeneration else { return }
                manualSaveFailed = true
                let failure = "Could not save adjustments: \(error.localizedDescription)"
                manualSaveFailures[frame.url] = ManualSaveFailure(revision: revision, message: failure)
                manualSaveMessage = failure
            }
        }
    }

    func retryManualSave() {
        manualSaveFailed = false
        guard let roll else { return }
        // Only the saves that failed, and those a lost seed held back: a frame whose recipe could not be read must not be saved over it.
        for frame in roll.frames where manualLoaded.contains(frame.url)
            && (manualSaveFailures[frame.url] != nil || maskSeedUnsaved.contains(frame.url)) {
            saveManualFrame(frame)
        }
    }

    func flushManualSaves() async throws {
        if let restoration = manualRestoreTask { await restoration.value }
        // Frames a lost seed held back are tried again, once: a pack put back beside the raw since then gives the seed back.
        for frame in roll?.frames ?? [] where maskSeedUnsaved.contains(frame.url) && manualLoaded.contains(frame.url) {
            saveManualFrame(frame)
        }
        while true {
            for url in Array(manualGestures.keys) {
                if let frame = roll?.frames.first(where: { $0.url == url }) { endManualGesture(for: frame) }
            }
            let revision = editRevision
            let tasks = Array(manualSaveTasks.values)
            for task in tasks { await task.value }
            adoptFlushed(try await RecipeWriter.shared.flush(library: recipeLibrary))
            if revision == editRevision, manualGestures.isEmpty { break }
        }
        if manualSaveFailed { throw ManualSaveError.failed(manualSaveMessage ?? "Adjustments could not be saved") }
    }

    /// A save whose library write failed stays with the writer until its flush persists it; then
    /// it is saved, with its revision or a later one, and no longer a failure.
    private func adoptFlushed(_ persisted: [URL: Recipe]) {
        var cleared = false
        for (url, recipe) in persisted where manualLoaded.contains(url) {
            let saved = recipe.editRevision ?? 0
            if manualRecipes[url]?.editRevision ?? 0 <= saved { manualRecipes[url] = recipe }
            if let failure = manualSaveFailures[url], failure.revision <= saved {
                manualSaveFailures[url] = nil
                cleared = true
            }
        }
        guard cleared else { return }
        manualSaveFailed = !manualSaveFailures.isEmpty
        manualSaveMessage = manualSaveFailures.values.first?.message
    }

    func clearManualSession() {
        // A Halation gesture does not outlive the roll it began on.
        suspendHalationAdjusting(writing: false)
        manualRestoreTask?.cancel()
        manualRestoreTask = nil
        manualGeneration = UUID()
        endPasteSession()
        manualUndoManager?.removeAllActions(withTarget: self)
        undoSeeds = []; maskSeedDamage = [:]; maskSeedUnsaved = []
        smartMasks.reset()
        clearRemoveSession()
        manualEdits = [:]; heldManualEdits = [:]; manualErrors = [:]
        manualPreparationErrors = [:]
        manualReadySources = [:]; visibleAutomatic = [:]; manualRecipes = [:]; manualLineages = [:]; manualLoaded = []
        manualGestures = [:]; manualSaveTasks = [:]
        manualSaveMessage = nil; manualSaveFailed = false; manualSaveFailures = [:]; isComparingAuto = false; isAutoComparisonReady = false
        curveHistogram = nil; curveHistogramFrame = nil
        frameHistogram = nil; frameHistogramFrame = nil
        editRevision = UInt64(Date().timeIntervalSince1970 * 1_000_000); editLineage = UUID().uuidString
        manualChoicesChangedDuringRestore = false
        isRestoringManual = false
    }

    /// Lets go of everything the session holds for the frame at `url`, which has left the roll (`dropFrames`): its edit and
    /// the one held aside, its recipe as read, what stood in the way of its saves, and a
    /// smart mask's selection still running for it. Its recipe beside its raw went with the raw, as it was last saved.
    func forgetManual(_ url: URL) {
        for key in smartMasks.runs.keys where key.frame == url { stopSelection(key) }
        manualGestures[url] = nil; manualSaveTasks[url] = nil
        forgetRemovals(url)
        manualEdits[url] = nil; heldManualEdits[url] = nil; manualErrors[url] = nil; manualPreparationErrors[url] = nil
        maskSeedDamage[url] = nil; maskSeedUnsaved.remove(url)
        manualReadySources[url] = nil; visibleAutomatic[url] = nil; manualRecipes[url] = nil; manualLineages[url] = nil
        manualLoaded.remove(url); manualSaveFailures[url] = nil
        if curveHistogramFrame == url { curveHistogram = nil; curveHistogramFrame = nil }
        if frameHistogramFrame == url { frameHistogram = nil; frameHistogramFrame = nil }
    }

    func restoreManualSession(_ roll: Roll) {
        let generation = manualGeneration
        isRestoringManual = true
        manualRestoreTask = Task {
            var restored: [RecipeStore.Checked?] = []
            for frame in roll.frames {
                guard !Task.isCancelled, generation == manualGeneration else { return }
                switch await loadManualRecipe(for: frame, generation: generation) {
                case .superseded: return
                case .loaded(let checked): restored.append(checked)
                case .unread: restored.append(nil)
                }
            }
            guard !Task.isCancelled, generation == manualGeneration else { return }
            // The protected journal carries the latest roll choices even if a v1 binary
            // replaced its ordinary sidecars. Do not replace choices after an intervening edit.
            let latest = RestoredRoll(frames: roll.frames, checked: restored)
            if !manualChoicesChangedDuringRestore {
                isApplyingRestoredChoices = true
                if let id = latest.stockID, let index = films?.stocks.firstIndex(where: { $0.id == id }) { stockIndex = index }
                if let controls = latest.controls { self.controls = controls }
                for (url, own) in latest.overrides { setRestoredFrameControls(own, url: url) }
                isApplyingRestoredChoices = false
            }
            // On a locked card only the journal records a develop, so the sidecars the roll opened
            // with gave neither the folder it developed to nor the measurements it printed from.
            // The recipes' measurement of a frame's raw as it is now is its measurement, in place of
            // one its decode gave first: the roll balances only after this, so its first decision
            // does not depend on which finished first.
            if chosenDevelopFolder == nil, let folder = latest.destination {
                chosenDevelopFolder = restoredDevelopFolder(folder, for: roll)
            }
            for frame in roll.frames {
                guard let analysis = latest.analyses[frame.url], let source = latest.sources[frame.url] else { continue }
                films?.seedAnalysis(analysis, for: frame, source: source)
                recordRestored(FrameMeasurement(analysis: analysis, source: source), for: frame)
            }
            manualRestoreTask = nil
            isRestoringManual = false
            if manualChoicesChangedDuringRestore { saveManualChoices() }
            // The roll's choices are restored: its decision can be taken once every frame is measured.
            balanceIfReady()
        }
    }
}

extension RollModel {
    /// Reads the frame's saved recipe into the session. A raw that cannot be read, as a share can
    /// fail to for a moment, leaves its saved adjustments unknown rather than absent: the frame stays
    /// out of `manualLoaded`, so nothing saves over them, with an error that reading it again
    /// clears, from the inspector's Retry or before the next develop (`retryUnreadManualRecipes`).
    fileprivate func loadManualRecipe(for frame: Frame, generation: UUID) async -> ManualLoad {
        do {
            let recipe = try await RecipeWriter.shared.load(for: frame, library: recipeLibrary)
            // A held edit on the bytes it was pinned on is the frame's: its RAW was put back while the app
            // was closed, or a build before 2026-10-22 saved it held, and copies of the roll share that record.
            var restored: SourceDigests.Verified?
            if let recipe, recipe.manual == nil, recipe.heldManual != nil {
                restored = try await Task.detached(priority: .userInitiated) { try SourceDigests.shared.digest(of: frame.url) }.value
            }
            guard generation == manualGeneration else { return .superseded }
            manualPreparationErrors[frame.url] = nil
            manualLoaded.insert(frame.url)
            guard let recipe else { return .loaded(nil) }
            manualRecipes[frame.url] = recipe
            manualEdits[frame.url] = recipe.manual
            heldManualEdits[frame.url] = recipe.heldManual
            if recipe.heldManual != nil {
                manualErrors[frame.url] = "These adjustments belong to an earlier RAW. Reapply Adjustments to attach them to this image."
            }
            releaseHeldManual(frame.url, sha256: restored?.sha256)
            verifyMaskSeeds(for: frame)
            editRevision = max(editRevision, recipe.editRevision ?? 0)
            if let lineage = recipe.editLineage {
                manualLineages[frame.url] = lineage
                // A twin's record adds to the roll's lineage; the roll's other frames keep the roll's.
                editLineage = RecipeWriter.rollLineage(lineage, of: frame)
            }
            guard let verified = SourceDigests.shared.known(frame.url) else { return .loaded(nil) }
            manualReadySources[frame.url] = verified
            return .loaded(RecipeStore.Checked(recipe: recipe, source: verified.source))
        } catch {
            guard !Task.isCancelled, generation == manualGeneration else { return .superseded }
            if error is SourceDigests.Failure || (error as? CocoaError)?.isFileError == true {
                manualPreparationErrors[frame.url] = "Could not read the saved adjustments: \(error.localizedDescription)"
                return .unread
            }
            if case RecipeWriter.Failure.sourceChanged(let old) = error {
                heldManualEdits[frame.url] = old.manual
                manualLineages[frame.url] = old.editLineage
            }
            manualErrors[frame.url] = error.localizedDescription
            manualLoaded.insert(frame.url)
            return .loaded(nil)
        }
    }

    /// Reads again the recipes the restore could not read, so a moment's failure to read a raw
    /// does not keep the roll from developing until it is opened again.
    func retryUnreadManualRecipes(_ frames: [Frame]) async {
        let generation = manualGeneration
        for frame in frames where !manualLoaded.contains(frame.url) {
            if case .superseded = await loadManualRecipe(for: frame, generation: generation) { return }
        }
    }
}

// MARK: - Masks

/// A mask's gestures, each one undo step with its name. Masks are part of the frame's edit, so they ride the
/// path Light does: a gesture opens, `setManualAdjustments` writes through it, and its end registers the step
/// and saves. A slider or Amount goes that same way and touches nothing but its value, so `Mask.coverage` is
/// the same before and after, and no coverage is rebuilt (plan section 4, rule 2).
extension RollModel {
    func masks(for frame: Frame) -> [Mask] { manualAdjustments(for: frame).masks.masks }

    func mask(_ id: UUID, for frame: Frame) -> Mask? { masks(for: frame).first { $0.id == id } }

    /// The selected mask, on the frame showing.
    func selectedMask(for frame: Frame) -> Mask? { maskEditor.selection.flatMap { mask($0.mask, for: frame) } }

    /// A mask's name, from the edit's notes, not its pixels: renaming one never develops it again.
    func maskName(_ id: UUID, for frame: Frame) -> String {
        manualEdits[frame.url]?.maskNotes.names[id.uuidString] ?? "Mask"
    }

    /// What the frame's compiler lets a first mask do (`MaskCompilerGate`).
    func maskCompilerGate(for frame: Frame) -> MaskCompilerGate {
        let edit = manualEdits[frame.url]
        return .forFirstMask(curveVersion: edit?.curveVersion, adjustments: edit?.adjustments ?? .identity)
    }

    /// Whether a tile can start a mask: a mask is a first edit, so it waits for what a slider does, and its
    /// compiler has a say, and a frame holds so many.
    func canAddMask(_ frame: Frame) -> Bool {
        canAdjust(frame) && maskCompilerGate(for: frame) != .needsUpdate && masks(for: frame).count < MaskSet.maximumMasks
    }

    /// Whether the masks' handles and overlay step back, and a press on the picture does nothing: Space,
    /// Compare to Auto, the clipping view, and a frame that cannot be adjusted.
    func masksStandDown(_ frame: Frame) -> Bool {
        isComparing || isComparingAuto || lightClipping != nil || !canAdjust(frame)
    }

    /// Whether the mask the overlay shows on `frame` evaluates its selection per pixel in the print (tier 2, `MaskRefiner.perPixelPlan`
    /// over the frame's whole list, so its place in the list counts), for the sharp raster to read as the print does. False for a
    /// component shown alone, which prints with no such thing, and for what is not the selected or hovered mask.
    func overlayReadsPerPixel(for frame: Frame) -> Bool {
        let editor = maskEditor
        let id: UUID?
        switch MaskOverlayVisibility.shown(MaskOverlayVisibility.Inputs(isPlacing: editor.isPlacing, isHovering: editor.hover != nil,
                                                                        hasSelection: editor.selection != nil,
                                                                        isOn: editor.isOverlayOn, justPlaced: editor.justPlaced)) {
        case .nothing: id = nil
        case .selection: id = editor.selection?.mask
        case .hovered:
            if case .mask(let hovered) = editor.hover { id = hovered } else { id = nil }
        }
        guard let id else { return false }
        let all = masks(for: frame)
        guard let slot = all.firstIndex(where: { $0.id == id }) else { return false }
        return MaskRefiner.perPixelPlan(all).contains { $0.slot == slot }
    }

    /// What the overlay shows on `frame` now, by the plan's rule (`MaskOverlayVisibility`): the selected mask's
    /// components with any shape in progress, or the row the pointer rests on's; nil for nothing.
    func overlayComponents(for frame: Frame) -> [MaskComponent]? {
        let editor = maskEditor
        guard editor.selection != nil || editor.hover != nil else { return nil }
        // A slider moving hides it whatever else holds (`MaskOverlayVisibility`): asked first, so the overlay reads no mask, and a
        // write of the slider's does not build the overlay again at each step (measured, G).
        guard !editor.isAdjusting else { return nil }
        let inputs = MaskOverlayVisibility.Inputs(standsDown: masksStandDown(frame), isAdjusting: editor.isAdjusting, isPlacing: editor.isPlacing,
                                                  isHovering: editor.hover != nil, hasSelection: editor.selection != nil,
                                                  isOn: editor.isOverlayOn, justPlaced: editor.justPlaced)
        switch MaskOverlayVisibility.shown(inputs) {
        case .nothing:
            return nil
        case .selection:
            guard let selection = editor.selection, var components = mask(selection.mask, for: frame)?.components else { return nil }
            if let press = editor.press, let live = press.live, let target = press.target, target.mask == selection.mask,
               components.indices.contains(target.component ?? 0) {
                components[target.component ?? 0].shape = live
            }
            return components
        case .hovered:
            switch editor.hover {
            case .mask(let id): return mask(id, for: frame)?.components
            case .component(let id, let index):
                // That component alone, as it selects.
                guard let components = mask(id, for: frame)?.components, components.indices.contains(index) else { return nil }
                return [MaskComponent(shape: components[index].shape, invert: components[index].invert)]
            case nil: return nil
            }
        }
    }

    /// A picture's far corner in `MaskSpace`, by its shape, for a gradient placed with no pointer.
    private func maskExtent(for frame: Frame) -> MaskPoint {
        frame.info.isPortrait ? MaskPoint(x: 2.0 / 3, y: 1) : MaskPoint(x: 1, y: 2.0 / 3)
    }

    func lensSettings(for frame: Frame) -> LensSettings { printedEdit(for: frame)?.adjustments.lens ?? .default }

    func canSetDistortion(_ frame: Frame) -> Bool {
        canAdjust(frame) && films?.lensCorrection(for: frame, settings: .default)?.status.distortion == .file
    }

    func setDistortion(_ isOn: Bool, for frame: Frame) {
        let held = suspendLightAdjusting(on: [frame.url])
        defer { resumeLightAdjusting(on: held) }
        setManualAdjustments(manualAdjustments(for: frame).settingLens(lensSettings(for: frame).settingDistortion(isOn: isOn)), for: frame)
    }

    func maskLens(for frame: Frame, settings: LensSettings) -> MaskLens? {
        films?.lensCorrection(for: frame, settings: settings).map { MaskLens($0, extent: maskExtent(for: frame)) }
    }

    /// Moves gradients and brushes into the picture shown. A brush with an unavailable measured shape stays as stored.
    func inPicture(_ mask: Mask, lens: MaskLens?) -> Mask {
        guard let lens else { return mask }
        var moved = mask
        let store = maskSeedStore
        for i in moved.components.indices {
            if let shape = try? moved.components[i].shape.moved(in: lens, remeasure: { measured, toMask in
                let made = try measured.moved(try store.load(measured.raster), by: toMask)
                _ = try store.store(made.raster)
                return made.measured
            }) { moved.components[i].shape = shape }
        }
        return moved
    }

    func moveMaskToPicture(_ id: UUID, for frame: Frame) {
        guard let mask = mask(id, for: frame) else { return }
        let moved = inPicture(mask, lens: maskEditor.lens(on: frame) ?? maskLens(for: frame, settings: lensSettings(for: frame)))
        if moved != mask { replaceMask(moved, for: frame) }
    }

    /// The gradient Return would place on `frame`, which a shape's number resets to.
    func placedShape(_ tool: MaskEditor.Tool, for frame: Frame) -> MaskShape? {
        MaskHandleModel.placed(tool, extent: maskExtent(for: frame))
    }

    /// A tile, or M or Shift-M: the tab comes up, and a tool is in hand if the frame can take a mask. With
    /// `operation`, adding to the selected mask. The keyboard goes to the photograph, where Return places one.
    func armMaskTool(_ tool: MaskEditor.Tool, adding operation: MaskOperation? = nil) {
        guard let frame = shownFrame else { return }
        showInspector(tab: .masks)
        guard operation == nil ? canAddMask(frame) : canAddComponent(for: frame) else { return }
        maskEditor.arm(tool, operation: operation)
        maskEditor.requestPhotographFocus()
    }

    /// Whether the selected mask can take another component.
    func canAddComponent(for frame: Frame) -> Bool {
        guard canAdjust(frame), let mask = selectedMask(for: frame) else { return false }
        return mask.components.count < MaskSet.maximumComponents
    }

    /// N: a tool like the selected mask's last component, for a new mask.
    func armToolLikeSelected() {
        guard let frame = shownFrame, let last = selectedMask(for: frame)?.components.last else { return }
        switch last.shape {
        case .linear: armMaskTool(.linear)
        case .radial: armMaskTool(.radial)
        case .brush: armBrush()
        case .smart: break
        }
    }

    /// Opens the gesture of a drawn shape and writes it: a new mask, named and selected by the caller, or a
    /// component of the selected one. What it writes stays in that gesture to its end. Taking a first mask
    /// moves an edit from a compiler that renders it the same way to the current one, inside this same step.
    /// Nil if the frame cannot take it, with nothing changed.
    func beginDrawnShape(_ shape: MaskShape, tool: MaskEditor.Tool, operation: MaskOperation?, for frame: Frame) -> MaskEditor.Selection? {
        let shape = shape.geometry == nil ? shape.stamped((maskEditor.lens(on: frame) ?? maskLens(for: frame, settings: lensSettings(for: frame)))?.picture) : shape
        if let operation {
            guard canAddComponent(for: frame), let selected = selectedMask(for: frame) else { return nil }
            beginManualGesture(for: frame)
            var mask = inPicture(selected, lens: maskEditor.lens(on: frame) ?? maskLens(for: frame, settings: lensSettings(for: frame)))
            mask.components.append(MaskComponent(operation: operation, shape: shape))
            guard replaceMask(mask, for: frame) else {
                cancelManualGesture(for: frame)
                return nil
            }
            return MaskEditor.Selection(mask: mask.id, component: mask.components.count - 1)
        }
        guard canAddMask(frame) else { return nil }
        beginManualGesture(for: frame)
        if maskCompilerGate(for: frame) == .movesToCurrent { manualEdits[frame.url]?.curveVersion = ManualRenderSettings.currentVersion }
        let mask = Mask(components: [MaskComponent(shape: shape)]), name = nextMaskName(tool.title, for: frame)
        guard let set = try? manualAdjustments(for: frame).masks.appending(mask) else {
            cancelManualGesture(for: frame)
            return nil
        }
        setManualAdjustments(manualAdjustments(for: frame).settingMasks(set), for: frame)
        guard self.mask(mask.id, for: frame) != nil else {
            cancelManualGesture(for: frame)
            return nil
        }
        manualEdits[frame.url]?.maskNotes.names[mask.id.uuidString] = name
        return MaskEditor.Selection(mask: mask.id, component: nil)
    }

    /// Return with a gradient tool in hand: one in the usual place, as one step, selected and showing, so a
    /// gradient needs no pointer. Whether one was placed.
    @discardableResult func placeArmedGradient() -> Bool {
        let editor = maskEditor
        guard let frame = shownFrame, let tool = editor.tool, !masksStandDown(frame), let shape = placedShape(tool, for: frame) else { return false }
        let operation = editor.pendingOperation
        guard let target = beginDrawnShape(shape, tool: tool, operation: operation, for: frame) else { return false }
        endManualGesture(for: frame, actionName: tool.actionName(adding: operation))
        editor.didPlace(target)
        announce("\(tool.title) gradient placed")
        return true
    }

    /// "Linear 1", the lowest number no mask has.
    func nextMaskName(_ title: String, for frame: Frame) -> String {
        let names = Set(masks(for: frame).map { maskName($0.id, for: frame) })
        var number = 1
        while names.contains("\(title) \(number)") { number += 1 }
        return "\(title) \(number)"
    }

    /// `mask` in place of the one with its id, through the path a Light slider takes. Whether it was written.
    @discardableResult private func replaceMask(_ mask: Mask, for frame: Frame) -> Bool {
        let values = manualAdjustments(for: frame)
        guard let set = try? values.masks.replacing(mask) else { return false }
        setManualAdjustments(values.settingMasks(set), for: frame)
        return self.mask(mask.id, for: frame) == mask
    }

    /// One whole gesture of its own: a press under way ends first, so that it stays one step too. That press writes the edit as it
    /// ends (a stroke, a gradient's drag), so `change` reads the masks it changes for itself: a copy read before this call is the
    /// edit without the press, and writing it would take the press away again.
    private func maskStep(for frame: Frame, _ actionName: String, _ change: () -> Void) {
        maskEditor.finishPress()
        guard canAdjust(frame) else { return }
        beginManualGesture(for: frame)
        change()
        endManualGesture(for: frame, actionName: actionName)
    }

    /// A step that changes the mask `id` alone: `change` gets it as the press that just ended left it.
    private func maskStep(for frame: Frame, _ actionName: String, changing id: UUID, _ change: (inout Mask) -> Void) {
        maskStep(for: frame, actionName) {
            guard var mask = mask(id, for: frame) else { return }
            change(&mask)
            replaceMask(mask, for: frame)
        }
    }

    // MARK: Sliders

    /// A mask's Light control, in a gesture its row opens.
    func setMaskValue(_ control: ManualAdjustments.Control, to value: Float, mask id: UUID, for frame: Frame) {
        guard var mask = mask(id, for: frame), let values = try? mask.adjustments.setting(control, to: value) else { return }
        mask.adjustments = values
        replaceMask(mask, for: frame)
    }

    /// A mask's Amount, stored 0 to 2, in a gesture its row opens.
    func setMaskAmount(_ amount: Float, mask id: UUID, for frame: Frame) {
        guard var mask = mask(id, for: frame), amount.isFinite, Mask.amountRange.contains(amount) else { return }
        mask.amount = amount
        replaceMask(mask, for: frame)
    }

    /// A mask's Warmth or Magenta, in a gesture its row opens.
    func setMaskBalance(_ control: MaskBalanceControl, to value: Float, mask id: UUID, for frame: Frame) {
        guard var mask = mask(id, for: frame), MaskBalance.range.contains(value) else { return }
        mask.balance = control.setting(value, in: mask.balance)
        replaceMask(mask, for: frame)
    }

    /// A mask row's gesture began (`MaskPanel`): a slider's drag, a scrub of its number, a key's step or a typed value. Its
    /// values go to the print alone (`moveMaskValue`, `moveMaskAmount`) until `endMaskAdjusting`.
    func beginMaskAdjusting(for frame: Frame) {
        beginManualGesture(for: frame)
        maskEditor.sliderBegan()
    }

    /// A mask's Light control from its row, inside the gesture the row opened: to the print (`MaskEditor.printedValues`), so the
    /// edit, and the tab that reads it, change once, as the gesture ends. With no gesture open, to the edit.
    func moveMaskValue(_ control: ManualAdjustments.Control, to value: Float, mask id: UUID, for frame: Frame) {
        guard maskEditor.isAdjusting else { return setMaskValue(control, to: value, mask: id, for: frame) }
        guard var values = movingValues(of: id, for: frame), let adjusted = try? values.adjustments.setting(control, to: value) else { return }
        values.adjustments = adjusted
        maskEditor.print(values)
    }

    /// A mask's Amount from its row, as `moveMaskValue`.
    func moveMaskAmount(_ amount: Float, mask id: UUID, for frame: Frame) {
        guard maskEditor.isAdjusting else { return setMaskAmount(amount, mask: id, for: frame) }
        guard var values = movingValues(of: id, for: frame), amount.isFinite, Mask.amountRange.contains(amount) else { return }
        values.amount = amount
        maskEditor.print(values)
    }

    /// A mask's Warmth or Magenta from its row, as `moveMaskValue`.
    func moveMaskBalance(_ control: MaskBalanceControl, to value: Float, mask id: UUID, for frame: Frame) {
        guard maskEditor.isAdjusting else { return setMaskBalance(control, to: value, mask: id, for: frame) }
        guard var values = movingValues(of: id, for: frame), MaskBalance.range.contains(value) else { return }
        values.balance = control.setting(value, in: values.balance)
        maskEditor.print(values)
    }

    /// A mask's values as its row moves them: what the print took last, or the edit's as the gesture began.
    private func movingValues(of id: UUID, for frame: Frame) -> MaskEditor.PrintedValues? {
        if let printed = maskEditor.printedValues, printed.frame == frame.url, printed.mask == id { return printed }
        guard canAdjust(frame), let mask = mask(id, for: frame) else { return nil }
        return MaskEditor.PrintedValues(frame: frame.url, mask: id, amount: mask.amount, adjustments: mask.adjustments, balance: mask.balance)
    }

    /// A mask row's gesture ended: the edit takes what the print took, before the print lets go of it in the same turn (as a
    /// gradient's release does), so the film on screen is the edit's and no render starts for it; then the one undo step.
    func endMaskAdjusting(for frame: Frame) {
        if let values = maskEditor.printedValues, values.frame == frame.url, var mask = mask(values.mask, for: frame) {
            mask.amount = values.amount
            mask.adjustments = values.adjustments
            mask.balance = values.balance
            replaceMask(mask, for: frame)
        }
        maskEditor.sliderEnded()
        endManualGesture(for: frame, actionName: "Adjust Mask")
    }

    /// A component's shape, in a gesture a press or a number's row opens.
    func setComponentShape(_ shape: MaskShape, of id: UUID, component: Int, for frame: Frame) {
        guard var mask = mask(id, for: frame), mask.components.indices.contains(component),
              mask.components[component].shape != shape else { return }
        mask.components[component].shape = shape
        replaceMask(inPicture(mask, lens: maskEditor.lens(on: frame) ?? maskLens(for: frame, settings: lensSettings(for: frame))), for: frame)
    }

    /// A component added at the end of a mask, in a gesture of the caller's: the drive hook's stand-in for painting a stroke until the
    /// brush's painting UI lands. Whether it was written.
    @discardableResult func appendMaskComponent(_ component: MaskComponent, to id: UUID, for frame: Frame) -> Bool {
        guard var mask = mask(id, for: frame) else { return false }
        mask.components.append(component)
        return replaceMask(inPicture(mask, lens: maskEditor.lens(on: frame) ?? maskLens(for: frame, settings: lensSettings(for: frame))), for: frame)
    }

    // MARK: Steps

    func renameMask(_ id: UUID, to name: String, for frame: Frame) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, mask(id, for: frame) != nil, name != maskName(id, for: frame) else { return }
        maskStep(for: frame, "Rename Mask") { manualEdits[frame.url]?.maskNotes.names[id.uuidString] = name }
    }

    /// A copy beside its original, selected. A copy of a mask whose selection is being found waits for it with its original
    /// (`joinSelection`).
    func duplicateMask(_ id: UUID, for frame: Frame) {
        guard canAddMask(frame), mask(id, for: frame) != nil else { return }
        var made: UUID?
        maskStep(for: frame, "Duplicate Mask") {
            let values = manualAdjustments(for: frame)
            guard let index = values.masks.masks.firstIndex(where: { $0.id == id }) else { return }
            let copy = values.masks.masks[index].copy()
            var all = values.masks.masks
            all.insert(copy, at: index + 1)
            guard let set = try? MaskSet(masks: all, version: values.masks.version) else { return }
            let name = "\(maskName(id, for: frame)) copy"
            setManualAdjustments(values.settingMasks(set), for: frame)
            guard mask(copy.id, for: frame) != nil else { return }
            manualEdits[frame.url]?.maskNotes.names[copy.id.uuidString] = name
            made = copy.id
        }
        guard let made else { return }
        joinSelection(of: id, as: made, for: frame)
        maskEditor.selection = MaskEditor.Selection(mask: made, component: nil)
    }

    /// A mask's switch: off, it changes no pixel and keeps everything.
    func setMaskEnabled(_ isEnabled: Bool, mask id: UUID, for frame: Frame) {
        guard let mask = mask(id, for: frame), mask.isEnabled != isEnabled else { return }
        maskStep(for: frame, isEnabled ? "Turn Mask On" : "Turn Mask Off", changing: id) { $0.isEnabled = isEnabled }
    }

    func deleteMask(_ id: UUID, for frame: Frame) {
        guard mask(id, for: frame) != nil else { return }
        maskStep(for: frame, "Delete Mask") {
            let values = manualAdjustments(for: frame)
            guard let set = try? values.masks.removing(id) else { return }
            setManualAdjustments(values.settingMasks(set), for: frame)
        }
    }

    /// Delete: the selected component if it has others beside it, or else the mask. Whether it took the key.
    func deleteSelection(for frame: Frame) -> Bool {
        guard canAdjust(frame), let selection = maskEditor.selection, let mask = mask(selection.mask, for: frame) else { return false }
        if let component = selection.component, mask.components.count > 1 {
            removeComponent(component, of: mask.id, for: frame)
        } else {
            deleteMask(mask.id, for: frame)
        }
        return true
    }

    /// Invert: of the selected component, or with only the mask selected, its first (a mask has no Invert of
    /// its own, plan section 6, since what it means depends on the shape).
    func invertSelectedComponent(for frame: Frame) {
        guard let selection = maskEditor.selection, let mask = mask(selection.mask, for: frame) else { return }
        let index = selection.component ?? 0
        guard mask.components.indices.contains(index) else { return }
        maskStep(for: frame, "Invert Mask", changing: selection.mask) { mask in
            guard mask.components.indices.contains(index) else { return }
            mask.components[index].invert.toggle()
        }
    }

    /// A component's Add, Subtract or Intersect. The first is always added.
    func setComponentOperation(_ operation: MaskOperation, component: Int, of id: UUID, for frame: Frame) {
        guard let mask = mask(id, for: frame), component > 0, mask.components.indices.contains(component),
              mask.components[component].operation != operation else { return }
        maskStep(for: frame, "\(operation.title) in Mask", changing: id) { mask in
            guard mask.components.indices.contains(component) else { return }
            mask.components[component].operation = operation
        }
    }

    /// A component out of its mask; the last one left takes the mask with it. The one that comes first
    /// after is added, since a mask starts from nothing and has nothing to subtract from.
    func removeComponent(_ component: Int, of id: UUID, for frame: Frame) {
        guard let mask = mask(id, for: frame), mask.components.indices.contains(component) else { return }
        guard mask.components.count > 1 else {
            deleteMask(id, for: frame)
            return
        }
        maskStep(for: frame, "Remove from Mask", changing: id) { mask in
            guard mask.components.count > 1, mask.components.indices.contains(component) else { return }
            mask.components.remove(at: component)
            mask.components[0].operation = .add
        }
    }

    /// Reset masks: every mask gone in one step, Light, curves and the pin kept, unless nothing else was
    /// holding it, when it goes as it does for Reset Light.
    func resetMasks(for frame: Frame) {
        guard !manualAdjustments(for: frame).masks.isEmpty else { return }
        maskStep(for: frame, "Reset Masks") { setManualAdjustments(manualAdjustments(for: frame).settingMasks(.empty), for: frame) }
        if manualEdits[frame.url] == nil { isComparingAuto = false }
    }

    /// The previous or next mask in the list, wrapping; the first if none is selected.
    func selectMask(by offset: Int, for frame: Frame) {
        let all = masks(for: frame)
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.id == maskEditor.selection?.mask }
        let next = index.map { ($0 + offset + all.count) % all.count } ?? (offset < 0 ? all.count - 1 : 0)
        maskEditor.selection = MaskEditor.Selection(mask: all[next].id, component: nil)
    }

    /// The selection after an Undo or a Redo. Only where the masks' list is on screen: elsewhere nothing shows
    /// a selection, and one left behind would reappear with its handles.
    private func reconcileMaskSelection(from old: [Mask], for frame: Frame) {
        guard openAdjustSection == .masks, isAdjustmentsShown, frame.url == shownFrame?.url else {
            maskEditor.selection = nil
            return
        }
        maskEditor.selection = MaskEditor.reconciled(maskEditor.selection, from: old, to: masks(for: frame))
    }
}

/// The alert shown when adjustments could not be saved before the roll goes, as another roll opens or
/// the app quits: Retry, keep the roll open, or go on without saving them.
struct UnsavedAdjustments {
    enum Answer { case retry, keep, discard }

    /// Why the adjustments could not be saved.
    var error: any Error
    /// The second button's title, which keeps the roll open, and the third's, which goes on without them.
    var keep: String
    var discard: String

    /// Shows the alert and waits for its answer, as `RollModel.askAboutUnsavedAdjustments` does unless a
    /// test gives its own. A test process cannot answer an alert and would wait for ever, so it stops
    /// here instead.
    @MainActor static func alert(_ unsaved: UnsavedAdjustments) -> Answer {
        if ProcessInfo.isRunningTests {
            fatalError("A test reached the unsaved adjustments alert: give the model its own askAboutUnsavedAdjustments")
        }
        let alert = NSAlert()
        alert.messageText = "Adjustments have not been saved"
        alert.informativeText = unsaved.error.localizedDescription
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: unsaved.keep)
        alert.addButton(withTitle: unsaved.discard)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertThirdButtonReturn: return .discard
        default: return .keep
        }
    }
}

private enum ManualSaveError: LocalizedError {
    case sourceChanged, failed(String)
    var errorDescription: String? {
        switch self {
        case .sourceChanged: "The RAW changed while adjustments were saving. Reapply the adjustments to its new version."
        case .failed(let message): message
        }
    }
}
