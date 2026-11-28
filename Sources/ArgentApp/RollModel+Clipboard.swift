import ArgentCore
import ArgentRoll
import Foundation

/// The parts of a frame's adjustments a paste can carry (docs/context-menus-plan.md, section 2).
struct AdjustmentParts: OptionSet, Hashable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// The six Light values, with the starting point they are measured from: Auto or Original.
    static let light = AdjustmentParts(rawValue: 1 << 0)
    /// Texture, Clarity, Dehaze, Vibrance and Saturation.
    static let presence = AdjustmentParts(rawValue: 1 << 4)
    /// The Tone, Red, Green and Blue curves.
    static let curve = AdjustmentParts(rawValue: 1 << 1)
    /// The masks, as another picture takes them (`MaskSet.forAnotherPicture`).
    static let masks = AdjustmentParts(rawValue: 1 << 2)
    /// The frame's own Rated at and Lab balance.
    static let frameControls = AdjustmentParts(rawValue: 1 << 3)

    static let lens = AdjustmentParts(rawValue: 1 << 5)

    /// The frame's own stock, grain and halation.
    static let film = AdjustmentParts(rawValue: 1 << 6)

    static let stock = AdjustmentParts(rawValue: 1 << 7)
    static let filmSettings = AdjustmentParts(rawValue: 1 << 8)

    static let all: AdjustmentParts = [.light, .presence, .curve, .masks, .lens, .frameControls, .film]
    /// One at a time, in the order Paste Only lists them, Presence after Light as the Light tab shows them.
    static let each: [AdjustmentParts] = [.light, .presence, .curve, .masks, .lens, .frameControls, .film]

    /// The parts that are parts of the values, each beside the `ManualAdjustments.Parts` it is. What a copy holds and what a paste
    /// writes both read it, so no part can be offered by one and dropped by the other. The masks and the frame's own controls are
    /// carried otherwise.
    private static let valueParts: [(part: AdjustmentParts, values: ManualAdjustments.Parts)] =
        [(.light, .light), (.presence, .presence), (.curve, .curves), (.lens, .lens)]

    /// The parts of `ManualAdjustments` these carry, each taken whole (`ManualAdjustments.setting(_:from:)`).
    var values: ManualAdjustments.Parts {
        Self.valueParts.filter { contains($0.part) }.reduce([]) { $0.union($1.values) }
    }

    /// The parts that carry what `held` holds.
    init(holding held: ManualAdjustments.Parts) {
        self = Self.valueParts.filter { held.contains($0.values) }.reduce([]) { $0.union($1.part) }
    }

    /// A single part's name in Paste Only.
    var title: String {
        switch self {
        case .light: "Light"
        case .presence: "Presence"
        case .curve: "Curve"
        case .masks: "Masks"
        case .lens: "Lens"
        case .frameControls: "Rated At and Lab Balance"
        case .film: "Film Stock, Grain and Halation"
        default: "Adjustments"
        }
    }

    /// A single part's id in a menu table: "light", "presence", "curve", "masks", "lens", "frameControls", "film".
    var name: String {
        switch self {
        case .light: "light"
        case .presence: "presence"
        case .curve: "curve"
        case .masks: "masks"
        case .lens: "lens"
        case .frameControls: "frameControls"
        case .film: "film"
        default: "all"
        }
    }
}

/// What Copy Adjustments took from a frame: its values, never its pin, a smart mask's seed or a pixel. Each
/// frame it is pasted on pins its own automatic result (docs/manual-development.md, "Copy and Paste
/// Adjustments"). The app's own, not the system pasteboard's, so Command-C in a field is untouched.
struct AdjustmentsClipboard: Equatable {
    /// The frame it was copied from, and its name for the notice.
    var source: URL
    var sourceName: String
    /// Where the source's Light values start from; it goes with the Light part.
    var origin: AutomaticBaseline.Origin
    /// The source's values as it held them. A paste takes them as another picture does.
    var adjustments: ManualAdjustments
    /// The masks' names.
    var maskNotes: MaskNotes
    /// The source's own stock, Rated at, Lab balance, grain and halation; empty when it followed its roll.
    var frameControls: FrameControls

    /// The parts it holds something in, which a paste can carry.
    var parts: AdjustmentParts {
        var parts = AdjustmentParts(holding: adjustments.heldParts)
        if origin == .original { parts.insert(.light) }
        if !adjustments.masks.isEmpty { parts.insert(.masks) }
        if frameControls.ratedAt != nil || frameControls.labBalance != nil { parts.insert(.frameControls) }
        if frameControls.stock != nil || frameControls.grain != nil || frameControls.halation != nil
            || frameControls.monochromeFilter != nil || frameControls.paperGrade != nil { parts.insert(.film) }
        return parts
    }

    /// What a paste of `parts` writes on each frame. Paste Adjustments writes all six, those the source left untouched included,
    /// so it resets them on the frame and the two frames end with the same settings (rule 1); Paste Only writes the part it names,
    /// if there is something of it here.
    func carried(_ parts: AdjustmentParts) -> AdjustmentParts {
        parts == .all ? .all : self.parts.intersection(parts)
    }
}

/// The line a copy or a paste leaves at the workspace's top for a moment (`NoticeStack`).
struct ClipboardNotice: Equatable {
    struct Detail: Equatable {
        var title: String
        var secondaryLines: [String] = []

        var plainText: String { ([title] + secondaryLines).joined(separator: " — ") }
    }

    enum Kind: Equatable {
        case copied
        /// A paste waiting for its frames to be ready: how many are, of how many.
        case pasting(done: Int, of: Int)
        /// A paste made: the frames that took it, and those that could not.
        case pasted(frames: Int, skipped: Int)
        case failed
        /// Work of another kind under way, such as frames being moved out of the roll (RollModel+Frames): the spinner.
        case working
        /// That work done, with its own symbol.
        case done(symbol: String)
    }

    var kind: Kind
    var text: String
    /// Why each frame left out could not take it, for the notice's Details.
    var details: [String] = []
    var detailEntries: [Detail] = []
    var plainDetails: [String] { details + detailEntries.map(\.plainText) }
    var detailsHeading: String?
    var detailsTitle: String {
        detailsHeading ?? (plainDetails.count == 1 ? "1 frame left as it was" : "\(plainDetails.count) frames left as they were")
    }
    /// The Details button's help, when it is not the frames' or the files' left behind.
    var detailsHint: String?
    var detailsHelp: String {
        if let detailsHint { return detailsHint }
        guard detailsHeading != nil || !detailEntries.isEmpty else { return "The frames left out, and why" }
        return details.isEmpty ? "The files left behind, and why" : "The frames and files left behind, and why"
    }
    /// Whether the notice offers Undo: a paste made, while its step is the next to undo.
    var offersUndo = false

    var dismissalDelay: Duration {
        offersUndo || !plainDetails.isEmpty ? .seconds(6) : .seconds(3)
    }
}

/// The clipboard's keys, in one place for the menu bar, the context menus' hints and the tests.
enum ClipboardKeys {
    /// Pages' Copy Style and Paste Style: Shift-Command-C, Lightroom's, is Split Compare's here.
    static let copy = KeyChord("c", [.option, .command])
    static let paste = KeyChord("v", [.option, .command])
    static let pasteToShown = KeyChord("v", [.option, .shift, .command])
}

// MARK: - Copy and paste
//
// The surfaces (the context menus, the menu bar, the notice) call only what is in this extension, by these
// signatures. The paste itself is under "The engine" below (docs/context-menus-plan.md, section 2).
extension RollModel {
    /// Whether the frame has anything to copy: an edit of its own, or its own Rated at or Lab balance.
    func canCopyAdjustments(from frame: Frame) -> Bool {
        !isScanning && !isQuitting && hasFrameEdits(frame)
    }

    /// Copy Adjustments: the frame's values as they are now, in place of what was copied before.
    func copyAdjustments(from frame: Frame) {
        guard canCopyAdjustments(from: frame) else { return }
        adjustmentsClipboard = clipboard(of: frame)
        showClipboardNotice(ClipboardNotice(kind: .copied, text: "Copied adjustments from \(frame.name)"))
    }

    /// The frame's values as Copy Adjustments takes them, without putting them on the clipboard: the drive hook pastes them so.
    func clipboard(of frame: Frame) -> AdjustmentsClipboard {
        let edit = manualEdits[frame.url]
        var values = edit?.adjustments ?? .identity
        if !values.masks.isDigestOnly, let lens = maskLens(for: frame, settings: values.lens),
           let masks = try? MaskSet(masks: values.masks.masks.map { inPicture($0, lens: lens) }, version: values.masks.version) {
            values = values.settingMasks(masks)
        }
        // A removal is this frame's pixels: a copy holds none and names none (docs/remove-plan.md, section 4.1).
        return AdjustmentsClipboard(source: frame.url, sourceName: frame.name, origin: edit?.baseline.origin ?? .auto,
                                    adjustments: values.withoutRemovals, maskNotes: edit?.maskNotes ?? .none,
                                    frameControls: frameControls(frame))
    }

    /// The parts of the clipboard a paste of `parts` would carry.
    func pasteableParts(_ parts: AdjustmentParts = .all) -> AdjustmentParts {
        adjustmentsClipboard?.parts.intersection(parts) ?? []
    }

    /// Whether a paste of `parts` can be asked for on `frame`: something is copied that holds them, and the
    /// roll is open to edits, not opening, quitting or being restored (rule 8). A frame not ready yet is waited for
    /// by the paste, not refused here.
    func canPasteAdjustments(to frame: Frame, parts: AdjustmentParts = .all) -> Bool {
        guard !isScanning, !isQuitting, !isRestoringManual, frameMove == nil, !pasteableParts(parts).isEmpty else { return false }
        return true
    }

    /// The frames Paste to Frames Shown would paste on: the frames the sheet shows, in capture order,
    /// without the frame the clipboard came from.
    var pasteTargets: [Frame] {
        guard let clipboard = adjustmentsClipboard else { return [] }
        return shownFrames.filter { $0.url != clipboard.source }
    }

    var canPasteToShownFrames: Bool {
        !isScanning && !isQuitting && !isRestoringManual && frameMove == nil && !pasteableParts().isEmpty && !pasteTargets.isEmpty
    }

    /// The batch paste's title, which follows the filter as Develop's count does: "Paste to All Frames",
    /// "Paste to Flagged Frames", "Paste to Unflagged Frames".
    var pasteToShownTitle: String {
        switch flagFilter {
        case .all: "Paste to All Frames"
        case .flagged: "Paste to Flagged Frames"
        case .unflagged: "Paste to Unflagged Frames"
        }
    }

    /// Shows `notice`, and takes it away after a moment unless it is a paste still waiting; one with Undo or Details stays
    /// longer, to be reached. VoiceOver hears each line but a paste's count as it climbs (plan section 5). A new line ends the
    /// last one's offer of Undo.
    func showClipboardNotice(_ notice: ClipboardNotice, for duration: Duration? = nil) {
        clipboardNoticeTask?.cancel()
        stopWatchingPasteUndo()
        clipboardNotice = notice
        if case .pasting = notice.kind { return }
        if case .working = notice.kind { return }
        announce(notice.text)
        // A line that takes a held notice's place stays until the notice is let go.
        guard !isClipboardNoticeHeld else { return }
        let duration = duration ?? notice.dismissalDelay
        clipboardNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.clipboardNotice = nil
        }
    }

    func dismissClipboardNotice() {
        clipboardNoticeTask?.cancel()
        stopWatchingPasteUndo()
        isClipboardNoticeHeld = false
        clipboardNotice = nil
    }

    /// Keeps the notice while it is being reached for, the pointer on it or its Details open, and lets it go a moment after.
    /// A paste still waiting keeps its line by itself.
    func holdClipboardNotice(_ holds: Bool, lettingGoAfter moment: Duration = .seconds(2)) {
        isClipboardNoticeHeld = holds
        guard let notice = clipboardNotice else { return }
        if case .pasting = notice.kind { return }
        if case .working = notice.kind { return }
        clipboardNoticeTask?.cancel()
        guard !holds else { return }
        clipboardNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: moment)
            guard !Task.isCancelled else { return }
            self?.clipboardNotice = nil
        }
    }

    /// The waiting notice's close: the paste stops before it has written anything, and its line goes. A paste that has written
    /// is not stopped by this; its Undo takes it back.
    func stopPaste() {
        guard case .pasting = clipboardNotice?.kind else { return }
        pasteTask?.cancel()
        dismissClipboardNotice()
    }

    /// The notice's Undo, offered while the paste it speaks of is the next step to undo (`ClipboardNotice.offersUndo`).
    func undoPasteFromNotice() {
        guard clipboardNotice?.offersUndo == true else { return }
        dismissClipboardNotice()
        manualUndoManager?.undo()
    }
}

// MARK: - The engine (work package A)

/// What a paste came to: the frames that took it, in the order asked, and each one left as it was, with why.
struct PasteReport: Equatable {
    struct Skip: Equatable {
        var frame: URL
        var name: String
        var why: String
    }

    var asked: Int
    var pasted: [URL] = []
    var skipped: [Skip] = []
    /// Whether it changed anything, and so left an undo step.
    var isUndoable = false
}

/// The clipboard's masks as a paste gives them (rule 4), checked once a paste: a Follow edges stroke whose measured shape the library
/// holds keeps it, and one whose shape the library cannot give goes as it was painted, so no frame is given an edit that names a raster
/// its store does not hold. Each frame then takes them as another picture does, under new ids and with their names.
struct PastedMasks: Equatable {
    let masks: MaskSet
    let notes: MaskNotes

    /// The masks for one frame: new ids, the names kept by the order the two lists share, smart selections cleared to be asked again.
    func forAnotherFrame(geometry: LensGeometry?) throws -> (masks: MaskSet, notes: MaskNotes) {
        let fresh = try masks.forAnotherPicture(freshIDs: true, geometry: geometry)
        var names: [String: String] = [:]
        for (old, new) in zip(masks.masks, fresh.masks) {
            if let name = notes.names[old.id.uuidString] { names[new.id.uuidString] = name }
        }
        return (fresh, MaskNotes(names: names, rasters: notes.rasters).keeping(fresh))
    }

    /// `masks` with every Follow edges stroke whose measured shape is not in `held` painted as it was drawn: without the shape it
    /// measured such a stroke cannot be baked, and the shape cannot be measured again without the hand that drew it (R6).
    static func painting(_ masks: MaskSet, keeping held: Set<RasterID>) throws -> MaskSet {
        let all = masks.masks.map { mask -> Mask in
            var mask = mask
            mask.components = mask.components.map { component in
                guard case .brush(var paint) = component.shape else { return component }
                paint.strokes = paint.strokes.map { stroke in
                    guard let raster = stroke.measured?.raster, !held.contains(raster.id) else { return stroke }
                    var painted = stroke
                    painted.followEdges = false
                    painted.measured = nil
                    return painted
                }
                var painted = component
                painted.shape = .brush(paint)
                return painted
            }
            return mask
        }
        return try MaskSet(masks: all, version: masks.version)
    }
}

/// Why a frame was left out of a paste, in the words its Details give.
private struct PasteRefusal: Error {
    let why: String
}

extension RollModel {
    /// Paste Adjustments on one frame: the copied `parts` in place of the frame's own, as one undo step, "Paste Adjustments", whose
    /// Undo selects and opens the frame as any edit's does.
    func pasteAdjustments(to frame: Frame, parts: AdjustmentParts = .all) {
        guard canPasteAdjustments(to: frame, parts: parts), let clipboard = adjustmentsClipboard else { return }
        paste(clipboard, parts: parts, to: [frame], batch: false)
    }

    /// Paste to Frames Shown: the copied `parts` on every frame of `pasteTargets`, as one undo step, "Paste Adjustments to 12
    /// Frames", whose Undo restores every frame and moves neither the selection nor the page.
    func pasteAdjustmentsToShownFrames(parts: AdjustmentParts = .all) {
        guard canPasteToShownFrames, !pasteableParts(parts).isEmpty, let clipboard = adjustmentsClipboard else { return }
        paste(clipboard, parts: parts, to: pasteTargets, batch: true)
    }

    /// A paste waits behind the one asked before it, and stopping it stops that one too, so the notice's close stops
    /// every paste still waiting.
    static func wait<Value: Sendable>(behind previous: Task<Value, Never>?) async {
        _ = await withTaskCancellationHandler { await previous?.value } onCancel: { previous?.cancel() }
    }

    /// Pastes `clipboard`'s `parts` on `frames`: a press or a gesture open on them ends first, then each frame is made ready as Update
    /// Automatic Baseline makes one, and once every frame is, all are written in one turn and one undo step. A frame that cannot take
    /// it is left as it was and counted. A paste asked for while another waits goes after it. The task gives what it came to, `nil`
    /// when the roll went or the app quit first.
    @discardableResult
    func paste(_ clipboard: AdjustmentsClipboard, parts: AdjustmentParts, to frames: [Frame], batch: Bool,
               includingEmptyParts: Bool = false) -> Task<PasteReport?, Never>? {
        let carried = includingEmptyParts ? parts : clipboard.carried(parts)
        guard !carried.isEmpty, !frames.isEmpty, !isScanning, !isQuitting, !isRestoringManual, frameMove == nil else { return nil }
        endGestures(on: frames)
        let generation = manualGeneration, previous = pasteTask
        showClipboardNotice(Self.pastingNotice(done: 0, of: frames.count))
        let task = Task { [weak self] () -> PasteReport? in
            await Self.wait(behind: previous)
            guard let self else { return nil }
            return await self.runPaste(clipboard, carried: carried, to: frames, batch: batch, generation: generation)
        }
        pasteTask = task
        return task
    }

    /// "Pasting adjustments… 3 of 12", or for one frame "Pasting adjustments…".
    private static func pastingNotice(done: Int, of count: Int) -> ClipboardNotice {
        ClipboardNotice(kind: .pasting(done: done, of: count),
                        text: count == 1 ? "Pasting adjustments…" : "Pasting adjustments… \(done) of \(count)")
    }

    /// Rule 8: a press under way on the photograph, a mask row's drag and any other gesture open on a frame the paste writes, ended
    /// as their own steps, so the paste neither lands inside one nor is taken back by its end. A Light drag still held opens again
    /// so the rest of its drag is a gesture of its own; while its slider's pointer is down the window's undo manager keeps one group
    /// open, so the drag and the paste are undone together.
    @discardableResult
    func endGestures(on frames: [Frame], resumingLight: Bool = true) -> URL? {
        maskEditor.finishPress()
        let urls = Set(frames.map(\.url))
        if maskEditor.isAdjusting, let shown = shownFrame, urls.contains(shown.url) { endMaskAdjusting(for: shown) }
        if case .frame(let url) = halationAdjusting, urls.contains(url) { suspendHalationAdjusting(writing: true) }
        let light = suspendLightAdjusting(on: urls)
        for frame in frames where manualGestures[frame.url] != nil { endManualGesture(for: frame) }
        if resumingLight { resumeLightAdjusting(on: light) }
        return light
    }

    private func runPaste(_ clipboard: AdjustmentsClipboard, carried: AdjustmentParts, to frames: [Frame], batch: Bool,
                          generation: UUID) async -> PasteReport? {
        guard isCurrentPaste(generation) else { return nil }
        showClipboardNotice(Self.pastingNotice(done: 0, of: frames.count))
        var masks: PastedMasks?
        if carried.contains(.masks) {
            do { masks = try await pastedMasks(of: clipboard) } catch {
                showClipboardNotice(ClipboardNotice(kind: .failed, text: "Could not paste the masks: \(error.localizedDescription)"))
                return PasteReport(asked: frames.count)
            }
        }
        // Each frame made ready as Update Automatic Baseline makes one: its recipe read, its raw verified as it is now, its
        // measurement made. Side by side, since each mostly waits for its raw to be read.
        var done = 0
        await withTaskGroup(of: Void.self) { group in
            for frame in frames {
                group.addTask {
                    await self.prepareManualAdjustments(for: frame)
                    if carried.contains(.masks) { _ = await self.films?.lensFile(for: frame) }
                }
            }
            for await _ in group {
                done += 1
                if isCurrentPaste(generation) { showClipboardNotice(Self.pastingNotice(done: done, of: frames.count)) }
            }
        }
        // An Auto pin is the roll's settled aim, never one it is about to leave (rule 2); an Original reads no decision.
        if frames.contains(where: { pinning(clipboard, carried: carried, on: $0) == (.auto, true) }) {
            if !isBalanced, isCurrentPaste(generation) {
                showClipboardNotice(ClipboardNotice(kind: .pasting(done: done, of: frames.count),
                                                    text: "Pasting adjustments… waiting for the roll to balance"))
            }
            _ = await settledDecision(priority: .veryHigh)
        }
        guard isCurrentPaste(generation) else { return nil }
        guard !isScanning, !isQuitting, !isRestoringManual else {
            showClipboardNotice(ClipboardNotice(kind: .failed, text: "Paste Adjustments stopped: the roll is closing"))
            return nil
        }
        return writePaste(clipboard, carried: carried, masks: masks, to: frames, batch: batch)
    }

    private func isCurrentPaste(_ generation: UUID) -> Bool { !Task.isCancelled && generation == manualGeneration }

    /// The clipboard's masks, their Follow edges strokes checked against the library (`PastedMasks`). The library is the app's, so
    /// another roll's shapes are in reach there; where it has lost one, the pack beside the source's raw gives it back when that raw
    /// is in the roll open now, as its save would. Read off the main actor, since each shape is loaded and its pixels checked.
    private func pastedMasks(of clipboard: AdjustmentsClipboard) async throws -> PastedMasks {
        let set = clipboard.adjustments.masks
        let refs = set.masks.flatMap(\.components).flatMap { component -> [RasterRef] in
            guard case .brush(let paint) = component.shape else { return [] }
            return paint.strokes.compactMap { $0.measured?.raster }
        }
        guard !refs.isEmpty else { return PastedMasks(masks: set, notes: clipboard.maskNotes) }
        let store = maskSeedStore, pack = RecipeStore.masksBesideRaw(clipboard.source)
        let inReach = roll?.frames.contains { $0.url == clipboard.source } == true
        let held = await Task.detached(priority: .userInitiated) { () -> Set<RasterID> in
            let missing = store.missing(refs)
            if !missing.isEmpty, inReach { _ = try? store.importPack(from: pack, wanted: Set(missing.map(\.id))) }
            return Set(refs.filter { (try? store.load($0)) != nil }.map(\.id))
        }.value
        return PastedMasks(masks: try PastedMasks.painting(set, keeping: held), notes: clipboard.maskNotes)
    }

    /// Where the frame's values start after the paste, and whether it pins anew there: Paste Adjustments is a new edit and pins anew
    /// (rule 2), as does a part on a frame with no edit; Paste Only keeps a pin it finds where it starts from (rule 5), so only Light
    /// from the other starting point moves it.
    private func pinning(_ clipboard: AdjustmentsClipboard, carried: AdjustmentParts, on frame: Frame) -> (AutomaticBaseline.Origin, Bool) {
        let edit = manualEdits[frame.url]
        let origin = carried.contains(.light) ? clipboard.origin : edit?.baseline.origin ?? .auto
        return (origin, carried == .all || edit == nil || edit?.baseline.origin != origin)
    }

    /// What a paste makes of `frame`'s values before any pin is taken: the parts carried in place of its own, and where they start.
    private struct PastePlan {
        var values: ManualAdjustments
        var origin: AutomaticBaseline.Origin
        var notes: MaskNotes
        var own: FrameControls
        /// Whether anything is left to pin: nothing from Auto is no edit, as Reset to Current Auto leaves a frame.
        var isEdit: Bool
        /// Whether the frame is pinned anew (`pinning`).
        var pins: Bool
    }

    private func pastePlan(_ clipboard: AdjustmentsClipboard, carried: AdjustmentParts, masks: PastedMasks?,
                           on frame: Frame) -> Result<PastePlan, PasteRefusal> {
        let edit = manualEdits[frame.url]
        let (origin, pins) = pinning(clipboard, carried: carried, on: frame)
        var values = edit?.adjustments ?? .identity, notes = edit?.maskNotes ?? .none
        do {
            // Light goes with its starting point (`pinning`).
            values = values.setting(carried.values, from: clipboard.adjustments)
            if carried.contains(.masks), let masks {
                let given = try masks.forAnotherFrame(geometry: maskLens(for: frame, settings: values.lens)?.picture)
                values = values.settingMasks(given.masks)
                notes = given.notes
            }
        } catch { return .failure(PasteRefusal(why: error.localizedDescription)) }
        // Each part of the frame's own controls carries its own alone: Rated At and Lab Balance leaves the frame's stock,
        // grain and halation as they are, and Film Stock, Grain and Halation its Rated at and Lab balance.
        var own = frameControls(frame)
        if carried.contains(.frameControls) {
            own.ratedAt = clipboard.frameControls.ratedAt
            own.labBalance = clipboard.frameControls.labBalance
        }
        if carried.contains(.film) || carried.contains(.stock) {
            own.stock = clipboard.frameControls.stock
        }
        if carried.contains(.film) || carried.contains(.filmSettings) {
            own.grain = clipboard.frameControls.grain
            own.halation = clipboard.frameControls.halation
            own.monochromeFilter = clipboard.frameControls.monochromeFilter
            own.paperGrade = clipboard.frameControls.paperGrade
        }
        let isEdit = !(values.isIdentity && origin == .auto)
        return .success(PastePlan(values: values, origin: origin, notes: notes, own: own, isEdit: isEdit, pins: isEdit && pins))
    }

    /// `frame` as the paste leaves it, its edit and its own Rated at and Lab balance, or why it cannot take the paste (rule 7): an
    /// issue, a held edit, a raw that changed or was not verified, a recipe unread, a measurement not made, a roll not settled for an
    /// Auto pin, or masks its compiler cannot take (rule 5).
    private func pasted(_ clipboard: AdjustmentsClipboard, carried: AdjustmentParts, masks: PastedMasks?,
                        on frame: Frame) -> Result<(edit: ManualEdit?, own: FrameControls), PasteRefusal> {
        let url = frame.url
        func refuse(_ why: String) -> Result<(edit: ManualEdit?, own: FrameControls), PasteRefusal> { .failure(PasteRefusal(why: why)) }
        guard manualLoaded.contains(url) else { return refuse(manualPreparationErrors[url] ?? "Its saved adjustments have not been read yet.") }
        guard heldManualEdits[url] == nil else { return refuse("Its RAW has changed since it was adjusted. Reapply Adjustments first.") }
        if let issue = manualIssue(for: frame) { return refuse(issue) }
        guard let verified = manualReadySources[url], SourceStamp.of(url) == verified.source else {
            return refuse(manualPreparationErrors[url] ?? "Its RAW could not be verified as it is now.")
        }
        guard analysis(for: frame) != nil else {
            return refuse(measurementFailures[url] != nil ? "Its RAW could not be measured." : "It has not been measured yet.")
        }
        let plan: PastePlan
        switch pastePlan(clipboard, carried: carried, masks: masks, on: frame) {
        case .success(let made): plan = made
        case .failure(let refusal): return .failure(refusal)
        }
        guard plan.isEdit else { return .success((nil, plan.own)) }
        do {
            if !plan.pins, var edit = manualEdits[url] {
                // Paste Only keeps the frame's pin and its compilers, as a change made by hand would: a curve takes the frame's curve
                // compiler, Presence the frame's constants, and masks the Light compiler's leave (`MaskCompilerGate`).
                let values = try plan.values.keepingVersions(carried.values, of: edit.adjustments)
                if carried.contains(.masks), !values.masks.isEmpty {
                    switch maskCompilerGate(for: frame) {
                    case .open: break
                    case .movesToCurrent: edit.curveVersion = ManualRenderSettings.currentVersion
                    case .needsUpdate:
                        return refuse("Its adjustments were made with an earlier version of Argent. Update Automatic Baseline to add masks to it.")
                    }
                }
                edit.adjustments = values
                if carried.contains(.masks) { edit.maskNotes = plan.notes.keeping(values.masks) }
                return .success((edit.isEmpty ? nil : edit, plan.own))
            }
            // A new pin, as Update Automatic Baseline takes one: an Auto frame's settled aim, an Original's neutral one, resolved at
            // the frame's controls as the paste leaves them, and the current compilers, Light, curves, masks and Presence alike (rule 3).
            // Through the stock and grain the paste leaves the frame with.
            let index = stockIndex(own: plan.own), grain = plan.own.grain ?? output.grain
            guard let stock = films?.stocks[safe: index] else { return refuse("No stock is loaded.") }
            if plan.origin == .auto, !isBalanced { return refuse("The roll has not settled on its Auto yet.") }
            let aim = plan.origin == .original ? PrintAim() : printAim(for: frame), controls = plan.own.applied(to: self.controls)
            let base = try DevelopmentResolver.resolve(stock: stock, stockDigest: stockDigests[index], controls: controls, aim: aim,
                                                       manual: nil, grain: grain.amount, grainSeed: frame.grainSeed, sharpen: true,
                                                       origin: plan.origin)
            let baseline = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: stock.id, stockDigest: stockDigests[index],
                                             controls: controls, aim: aim, analysisVersion: ExposureAnalysis.currentVersion,
                                             resolverVersion: DevelopmentResolver.currentVersion,
                                             baseRender: Recipe.Render(settings: base, grain: grain), origin: plan.origin)
            let values = try plan.values.updatingVersions()
            return .success((ManualEdit(adjustments: values, baseline: baseline, curveVersion: ManualRenderSettings.currentVersion,
                                        maskNotes: plan.notes), plan.own))
        } catch { return refuse(error.localizedDescription) }
    }

    /// Writes the paste on every frame that can take it, in one turn: their edits, their own Rated at and Lab balance at once, one
    /// undo step, their saves, and their smart selections asked for again. Then the notice, and VoiceOver, say what it came to.
    private func writePaste(_ clipboard: AdjustmentsClipboard, carried: AdjustmentParts, masks: PastedMasks?, to frames: [Frame],
                            batch: Bool) -> PasteReport {
        // One step, whatever the event that ends this wait opened: a press or a gesture begun on these frames while they were made
        // ready ends first (rule 8), inside it, as a press ends inside a mask's step (`maskStep`).
        let manager = manualUndoManager, opens = manager?.groupingLevel == 0
        if opens { manager?.beginUndoGrouping() }
        let light = endGestures(on: frames, resumingLight: false)
        var report = PasteReport(asked: frames.count)
        var states: [PasteUndoState] = [], written: [Frame] = [], masksBefore: [URL: [Mask]] = [:], own = overrides
        // The roll's frames are indexed by raw once because looking up each pasted frame would otherwise compare every pair in a large batch.
        let current = Dictionary((roll?.frames ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        for asked in frames {
            guard let frame = current[asked.url] else {
                report.skipped.append(.init(frame: asked.url, name: asked.name, why: "It is no longer in the roll."))
                continue
            }
            switch pasted(clipboard, carried: carried, masks: masks, on: frame) {
            case .failure(let refusal):
                report.skipped.append(.init(frame: frame.url, name: frame.name, why: refusal.why))
            case .success(let result):
                states.append(pasteUndoState(for: frame))
                masksBefore[frame.url] = self.masks(for: frame)
                manualEdits[frame.url] = result.edit
                manualErrors[frame.url] = nil
                own[frame.url] = result.own.isEmpty ? nil : result.own
                written.append(frame)
            }
        }
        report.pasted = written.map(\.url)
        let choicesSaved = writeOverrides(own)
        // A selection running for a mask the paste took away stops; each smart selection the paste brought is asked for again.
        holdingSkyModel(for: written) {
            for frame in written { smartMasksRestored(for: frame, before: masksBefore[frame.url] ?? []) }
        }
        for frame in written { savePasted(frame, choicesSaved: choicesSaved) }
        if let shown = shownFrame, written.contains(where: { $0.url == shown.url }) {
            isComparingAuto = false
            let kept = MaskEditor.kept(maskEditor.selection, in: self.masks(for: shown))
            if kept != maskEditor.selection { maskEditor.selection = kept }
        }
        if !written.isEmpty, developPhase == .done { developPhase = .idle }
        report.isUndoable = zip(states, written).contains { $0 != pasteUndoState(for: $1) }
        if report.isUndoable {
            let name = batch ? "Paste Adjustments to \(written.count) \(written.count == 1 ? "Frame" : "Frames")" : "Paste Adjustments"
            registerPasteUndo(states, actionName: name, reveal: !batch)
        }
        if opens { manager?.endUndoGrouping() }
        // The drag still under way gets a gesture of its own once the paste's step is closed.
        resumeLightAdjusting(on: light)
        showClipboardNotice(notice(for: report, batch: batch))
        if report.isUndoable { watchPasteUndo() }
        return report
    }

    /// The line a paste leaves: "Pasted adjustments to DSC00412", "Pasted adjustments to 12 frames", "Pasted to 10 of 12 frames"
    /// with each frame left out and why, or that it could not paste at all.
    private func notice(for report: PasteReport, batch: Bool) -> ClipboardNotice {
        let details = report.skipped.map { "\($0.name): \($0.why)" }
        let pasted = report.pasted.count
        guard pasted > 0 else {
            let text = batch ? "Could not paste to \(report.asked == 1 ? "the frame" : "any of the \(report.asked) frames")"
                : "Could not paste to \(report.skipped.first?.name ?? "the frame")"
            return ClipboardNotice(kind: .failed, text: text, details: details)
        }
        let text: String
        if !report.skipped.isEmpty {
            text = "Pasted to \(pasted) of \(report.asked) frames"
        } else if !batch, let url = report.pasted.first, let frame = roll?.frames.first(where: { $0.url == url }) {
            text = "Pasted adjustments to \(frame.name)"
        } else {
            text = "Pasted adjustments to \(pasted) \(pasted == 1 ? "frame" : "frames")"
        }
        return ClipboardNotice(kind: .pasted(frames: pasted, skipped: report.skipped.count), text: text, details: details,
                               offersUndo: report.isUndoable)
    }

    // MARK: The notice's Undo

    /// Takes the notice's offer of Undo away once the paste is no longer the next step: another step opens, or anything is undone
    /// or redone. The undo manager is the window's, used on the main thread only, so its notes arrive there.
    private func watchPasteUndo() {
        stopWatchingPasteUndo()
        guard let manager = manualUndoManager else { return }
        pasteUndoWatch = NotificationCenter.default.addObserver(forName: nil, object: manager, queue: nil) { [weak self] note in
            let name = note.name
            guard name == .NSUndoManagerDidOpenUndoGroup || name == .NSUndoManagerDidUndoChange || name == .NSUndoManagerDidRedoChange
            else { return }
            MainActor.assumeIsolated { self?.pasteStepPassed() }
        }
    }

    private func pasteStepPassed() {
        stopWatchingPasteUndo()
        if clipboardNotice?.offersUndo == true { clipboardNotice?.offersUndo = false }
    }

    func stopWatchingPasteUndo() {
        if let watch = pasteUndoWatch { NotificationCenter.default.removeObserver(watch) }
        pasteUndoWatch = nil
    }

    /// The roll's session ends (another roll, or this one again): a paste waiting for its frames stops, its line goes, and a line
    /// offering Undo stops offering it, since the undo history goes with the session. The clipboard stays.
    func endPasteSession() {
        pasteTask?.cancel()
        pasteTask = nil
        if case .pasting? = clipboardNotice?.kind { dismissClipboardNotice() }
        pasteStepPassed()
    }
}
