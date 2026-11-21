import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

/// A smart-mask engine that runs no model, for the session's tests (`MaskInferenceTests` has its twin): each kind answered from a
/// table, finds held until a test lets them go, and the pins of the models it would use.
final class SessionSmartEngine: SmartMaskEngine, @unchecked Sendable {
    let lock = NSLock()
    var answers: [SmartKind: SmartResult] = [:]
    var failure: (any Error)?
    var finds: [SmartKind] = []
    var pictureLenses: [LensSettings] = []
    var holds = false
    var current = SmartModelPins()
    var availabilities: [SmartKind: SmartAvailability] = [:]
    private var held: [CheckedContinuation<Void, Never>] = []

    func availability(of kind: SmartKind) -> SmartAvailability { lock.withLock { availabilities[kind] ?? .available } }
    var pins: SmartModelPins { lock.withLock { current } }
    func picture(of frame: Frame, lens: LensSettings, stopped: @escaping @Sendable () -> Bool) async -> SmartPictureHandle? {
        lock.withLock { pictureLenses.append(lens) }
        return SmartPictureHandle(frame: frame.url, content: 0)
    }
    func find(_ kind: SmartKind, on picture: SmartPictureHandle, frame: Frame, sourceSHA256: String,
              stage: @escaping @Sendable (SmartStage) -> Void) async throws -> (SmartResult, MaskFrame) {
        lock.withLock { finds.append(kind) }
        stage(.finding)
        if lock.withLock({ holds }) { await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } } }
        if let failure = lock.withLock({ failure }) { throw failure }
        return (lock.withLock { answers[kind] } ?? .seed(Self.seed(kind)), Self.maskFrame)
    }
    func unloadSky() async -> Bool { false }
    func releasePictures() {}

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { held = [] }; return held }
        for continuation in waiting { continuation.resume() }
    }
    var heldCount: Int { lock.withLock { held.count } }

    static let maskFrame = try! MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)

    static func provenance(_ kind: SmartKind, recipe: String = "da3-test-1") -> RasterProvenance {
        let sky = kind == .sky
        return RasterProvenance(engine: sky ? "coreai:\(recipe)" : kind == .person ? AppleSegmentation.personEngine : AppleSegmentation.subjectEngine,
                                engineRevision: sky ? recipe : "1",
                                parameters: sky ? ["model.recipe": recipe, "model.weights": "w", "veto": WaterVeto.version, "gate.revision": "2",
                                                   "veto.ran": "false"] : [:],
                                operatingSystem: "test", app: "test",
                                input: .init(kind: "neutral-print", width: 2560, height: 1707, colorSpace: "sRGB", sourceSHA256: String(repeating: "0", count: 64)),
                                created: Date(timeIntervalSince1970: 0))
    }

    /// A 32 × 32 seed whose left half is `value`; the kind's own number in its first pixel, so seeds of two kinds differ.
    static func seed(_ kind: SmartKind, value: UInt8 = 255, recipe: String = "da3-test-1") -> SmartSeed {
        var plane = [UInt8](repeating: 0, count: 32 * 32)
        for y in 0..<32 { for x in 0..<16 { plane[y * 32 + x] = value } }
        plane[1] = UInt8(SmartKind.allCases.firstIndex(of: kind)! + 1)
        return SmartSeed(kind: kind == .background ? .subject : kind, raster: try! MaskRaster(width: 32, height: 32, plane: plane),
                         provenance: provenance(kind, recipe: recipe))
    }
}

/// Smart masks in the session (plan sections 2, 5 and 11): a click is one undo step at the click, its row there at once with its wait
/// named, and the selection arrives with no step of its own; undo while it runs cancels it, redo asks again; an empty or failed
/// selection is a quiet row state with what can be done; a seed from an earlier model offers Update and Keep and changes nothing by
/// itself; a develop waits for a selection under way; and the previews leave out a selection not made yet. Each test has a library
/// of its own and a fake engine.
@MainActor @Suite(.serialized) struct SmartMaskStateTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    /// A roll of two frames, both with an edit from Auto that can be adjusted, an undo manager of its own and the fake engine.
    private func fixture() async throws -> (RollModel, [Frame], URL, SessionSmartEngine) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-smart-masks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        try header(folder.appendingPathComponent("DSC2.ARW"))
        let library = folder.appendingPathComponent("library", isDirectory: true)
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: library), flagStore: FlagStore(library: library),
                              recipeLibrary: library, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        let frames = try #require(model.roll?.frames)
        for frame in frames {
            let verified = try SourceDigests.shared.digest(of: frame.url)
            model.manualReadySources[frame.url] = verified
            model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
            let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
                controls: .init(), aim: PrintAim(level: -0.65), analysisVersion: ExposureAnalysis.currentVersion,
                baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
            model.manualEdits[frame.url] = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5), baseline: pin)
        }
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        let engine = SessionSmartEngine()
        model.smartMasks.inference = MaskInference(engine: engine, turns: DecodeTurns())
        return (model, frames, folder, engine)
    }

    @Test func anAskPassesTheFramesLensAmountToTheEngine() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0], lens = try LensSettings(arguments: "distortion-amount=150")
        step(model) { model.setManualAdjustments(model.manualAdjustments(for: frame).settingLens(lens), for: frame) }
        step(model) { model.addSmartMask(.sky, for: frame) }
        await model.waitForSelections(on: [frame.url])
        #expect(engine.lock.withLock { engine.pictureLenses } == [lens])
    }

    private func step(_ model: RollModel, _ change: () -> Void) {
        model.manualUndoManager?.beginUndoGrouping()
        change()
        model.manualUndoManager?.endUndoGrouping()
    }

    private func undo(_ model: RollModel) { model.manualUndoManager?.undo() }
    private func redo(_ model: RollModel) { model.manualUndoManager?.redo() }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func selection(of mask: Mask?) -> SmartSelection? {
        mask?.components.lazy.compactMap { if case .smart(let s) = $0.shape { s } else { nil } }.first
    }

    // MARK: The click

    @Test func aClickIsOneStepAtOnceAndItsSelectionArrivesWithNoneOfItsOwn() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        engine.holds = true
        model.maskEditor.isPickerOpen = true
        step(model) { model.addSmartMask(.sky, for: frame) }
        let mask = try #require(model.masks(for: frame).last)
        #expect(!model.maskEditor.isPickerOpen)
        // The row is there at once, named, selected, and says what it waits for.
        #expect(mask.pendingSmart == [.sky] && model.maskName(mask.id, for: frame) == "Sky 1")
        #expect(model.maskEditor.selection?.mask == mask.id)
        #expect(model.smartStatus(of: mask, for: frame) == .working(.queued, kind: .sky, update: false))
        #expect(model.smartStatus(of: mask, for: frame)?.text == "Finding the sky…")
        #expect(model.manualUndoManager?.undoActionName == "Add Sky Mask")
        // The previews leave it out while it runs.
        #expect(RollModel.printable(model.manualEdits[frame.url])?.adjustments.masks.masks.last?.isEnabled == false)
        try await waitFor { engine.heldCount == 1 }
        engine.release()
        await model.waitForSelections(on: [frame.url])
        let made = try #require(selection(of: model.mask(mask.id, for: frame)))
        let ref = try #require(made.raster)
        #expect(made.frame == SessionSmartEngine.maskFrame)
        #expect(model.maskSeedStore.contains(ref.id))
        #expect(model.manualEdits[frame.url]?.maskNotes.rasters[ref.id.hex] == SessionSmartEngine.provenance(.sky))
        #expect(model.smartStatus(of: try #require(model.mask(mask.id, for: frame)), for: frame) == nil)
        #expect(RollModel.printable(model.manualEdits[frame.url]) == model.manualEdits[frame.url])
        // One step, the click's: undone, the mask goes; redone, it comes back with its selection and asks nothing.
        #expect(model.manualUndoManager?.undoActionName == "Add Sky Mask")
        undo(model)
        #expect(model.masks(for: frame).isEmpty && model.manualUndoManager?.canUndo == false)
        redo(model)
        #expect(selection(of: model.mask(mask.id, for: frame))?.raster == ref)
        #expect(model.smartMasks.runs.isEmpty && engine.finds == [.sky])
    }

    @Test func undoWhileItRunsCancelsAndRedoAsksAgain() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        engine.holds = true
        step(model) { model.addSmartMask(.person, for: frame) }
        let id = try #require(model.masks(for: frame).last?.id)
        try await waitFor { engine.heldCount == 1 }
        undo(model)
        #expect(model.masks(for: frame).isEmpty && model.smartMasks.runs.isEmpty)
        engine.release()
        await model.waitForSelections(on: [frame.url])
        #expect(model.masks(for: frame).isEmpty, "a cancelled selection fills nothing")
        redo(model)
        #expect(model.mask(id, for: frame)?.pendingSmart == [.person])
        #expect(model.smartMasks.run(.init(frame: frame.url, mask: id)) != nil, "redo asks again")
        try await waitFor { engine.heldCount == 1 }
        engine.release()
        await model.waitForSelections(on: [frame.url])
        #expect(selection(of: model.mask(id, for: frame))?.raster != nil)
        #expect(engine.finds == [.person, .person])
    }

    /// A slider moved while a selection runs is its own step; undoing it after the selection arrived keeps the selection, since a
    /// result belongs to its mask, not to a step.
    @Test func undoingASliderMovedWhileItRanKeepsTheSelection() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        engine.holds = true
        step(model) { model.addSmartMask(.sky, for: frame) }
        let id = try #require(model.masks(for: frame).last?.id)
        step(model) {
            model.beginManualGesture(for: frame)
            model.setMaskValue(.exposure, to: -1, mask: id, for: frame)
            model.endManualGesture(for: frame, actionName: "Adjust Mask")
        }
        try await waitFor { engine.heldCount == 1 }
        engine.release()
        await model.waitForSelections(on: [frame.url])
        let ref = try #require(selection(of: model.mask(id, for: frame))?.raster)
        #expect(model.mask(id, for: frame)?.adjustments.exposureEV == -1)
        undo(model)
        #expect(model.mask(id, for: frame)?.adjustments.exposureEV == 0)
        #expect(selection(of: model.mask(id, for: frame))?.raster == ref)
        #expect(model.manualEdits[frame.url]?.maskNotes.rasters[ref.id.hex] != nil)
        #expect(model.smartMasks.runs.isEmpty && engine.finds == [.sky])
    }

    /// A gesture abandoned after a selection arrived inside it (Escape in a stroke, a Shift press that never became one) goes back to
    /// how it began and keeps the selection, as an Undo does: a result belongs to its mask, not to the gesture it arrived in. Without
    /// it the mask went back to waiting with nothing running for it, and a develop refused the frame.
    @Test func abandoningAGestureASelectionArrivedInKeepsTheSelection() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        engine.holds = true
        step(model) { model.addSmartMask(.sky, for: frame) }
        let id = try #require(model.masks(for: frame).last?.id)
        try await waitFor { engine.heldCount == 1 }
        // A gesture opens and writes, as a stroke's press does, and the selection lands while it is open.
        model.beginManualGesture(for: frame)
        model.setMaskValue(.exposure, to: -1, mask: id, for: frame)
        engine.release()
        await model.waitForSelections(on: [frame.url])
        let ref = try #require(selection(of: model.mask(id, for: frame))?.raster)
        #expect(model.mask(id, for: frame)?.adjustments.exposureEV == -1)
        model.cancelManualGesture(for: frame)
        #expect(model.mask(id, for: frame)?.adjustments.exposureEV == 0, "the gesture's own change is gone")
        #expect(selection(of: model.mask(id, for: frame))?.raster == ref)
        #expect(model.manualEdits[frame.url]?.maskNotes.rasters[ref.id.hex] == SessionSmartEngine.provenance(.sky))
        #expect(model.smartStatus(of: try #require(model.mask(id, for: frame)), for: frame) == nil)
        #expect(RollModel.printable(model.manualEdits[frame.url]) == model.manualEdits[frame.url])
        #expect(model.manualUndoManager?.undoActionName == "Add Sky Mask" && model.smartMasks.runs.isEmpty && engine.finds == [.sky])
        // A gesture abandoned with nothing arrived in it is as it was: back to how it began.
        let before = model.manualEdits[frame.url]
        model.beginManualGesture(for: frame)
        model.setMaskValue(.exposure, to: -2, mask: id, for: frame)
        model.cancelManualGesture(for: frame)
        #expect(model.manualEdits[frame.url] == before)
    }

    /// A copy of a mask made while its selection is being found waits for the same selection: it joins the run, so both fill when
    /// it lands and the model runs once. Without it the copy stayed unmade, with nothing running for it. Undoing the copy lets its
    /// hold on the run go and leaves the original's.
    @Test func aCopyMadeWhileASelectionRunsWaitsForItToo() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        engine.holds = true
        step(model) { model.addSmartMask(.subject, for: frame) }
        let original = try #require(model.masks(for: frame).last?.id)
        try await waitFor { engine.heldCount == 1 }
        step(model) { model.duplicateMask(original, for: frame) }
        #expect(model.masks(for: frame).count == 2 && model.manualUndoManager?.undoActionName == "Duplicate Mask")
        let copy = try #require(model.masks(for: frame).last?.id)
        #expect(copy != original && model.maskEditor.selection?.mask == copy)
        #expect(model.mask(copy, for: frame)?.pendingSmart == [.subject])
        // Its row says it is being found, with Cancel, as its original's does.
        let copied = try #require(model.mask(copy, for: frame))
        let status = model.smartStatus(of: copied, for: frame)
        #expect(status?.isBusy == true && status?.actions == [.cancel], "\(String(describing: status))")
        // Undone while it runs, the copy goes and the original still waits; redone, it asks again and joins.
        undo(model)
        #expect(model.masks(for: frame).map(\.id) == [original] && model.smartMasks.run(.init(frame: frame.url, mask: original)) != nil)
        redo(model)
        #expect(model.smartMasks.run(.init(frame: frame.url, mask: copy)) != nil)
        engine.release()
        await model.waitForSelections(on: [frame.url])
        let made = try #require(selection(of: model.mask(original, for: frame))?.raster)
        #expect(selection(of: model.mask(copy, for: frame))?.raster == made)
        #expect(model.masks(for: frame).allSatisfy { $0.pendingSmart.isEmpty } && model.smartMasks.runs.isEmpty)
        #expect(engine.finds == [.subject], "one run for the two")
        // A copy of a mask whose selection is made has it, and asks for nothing.
        step(model) { model.duplicateMask(original, for: frame) }
        #expect(model.masks(for: frame).count == 3 && model.masks(for: frame).allSatisfy { selection(of: $0)?.raster == made })
        #expect(model.smartMasks.runs.isEmpty && engine.finds == [.subject])
    }

    @Test func aSecondClickWhileOneRunsSelectsItAndBackgroundIsSubjectInverted() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        engine.holds = true
        step(model) { model.addSmartMask(.subject, for: frame) }
        step(model) { model.addSmartMask(.subject, for: frame) }
        #expect(model.masks(for: frame).count == 1)
        step(model) { model.addSmartMask(.background, for: frame) }
        let masks = model.masks(for: frame)
        #expect(masks.count == 2 && model.maskName(masks[1].id, for: frame) == "Background 1")
        #expect(model.smartStatus(of: masks[1], for: frame)?.text == "Finding the background…")
        try await waitFor { engine.heldCount == 1 }
        engine.release()
        await model.waitForSelections(on: [frame.url])
        let subject = try #require(selection(of: model.mask(masks[0].id, for: frame)))
        let background = try #require(selection(of: model.mask(masks[1].id, for: frame)))
        #expect(subject.kind == .subject && background.kind == .background && subject.raster == background.raster)
        #expect(engine.finds == [.subject], "Background is Subject's run")
        // The overlay: Background reads the same seed as 1 − v.
        let field = MaskSeedCoverage(store: model.maskSeedStore)
        let one = field.raster(of: model.mask(masks[0].id, for: frame)!.components, width: 32, height: 32)
        let other = field.raster(of: model.mask(masks[1].id, for: frame)!.components, width: 32, height: 32)
        #expect(one[5 * 32 + 4] == 255 && one[5 * 32 + 28] == 0)
        #expect(other[5 * 32 + 4] == 0 && other[5 * 32 + 28] == 255)
    }

    @Test func aClickOnOneFrameFillsItsOwnWhateverFrameIsShown() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        engine.holds = true
        step(model) { model.addSmartMask(.sky, for: frames[0]) }
        let id = try #require(model.masks(for: frames[0]).last?.id)
        model.selection = frames[1].id
        try await waitFor { engine.heldCount == 1 }
        engine.release()
        await model.waitForSelections(on: [frames[0].url])
        #expect(selection(of: model.mask(id, for: frames[0]))?.raster != nil)
        #expect(model.masks(for: frames[1]).isEmpty)
    }

    // MARK: Quiet states

    @Test func nothingFoundIsAQuietRowWithPaintItInsteadAndRemove() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        engine.answers = [.sky: .nothingFound(.sky, SessionSmartEngine.provenance(.sky))]
        step(model) { model.addSmartMask(.sky, for: frame) }
        await model.waitForSelections(on: [frame.url])
        let mask = try #require(model.masks(for: frame).last)
        let status = try #require(model.smartStatus(of: mask, for: frame))
        #expect(status.text == "No sky found in this frame" && status.actions == [.paintInstead, .remove] && status.hasActionLine)
        #expect(mask.pendingSmart == [.sky])
        step(model) { model.perform(.paintInstead, on: mask.id, for: frame) }
        let painted = try #require(model.mask(mask.id, for: frame))
        guard case .brush(let paint) = painted.components[0].shape else { Issue.record("no brush"); return }
        #expect(paint.strokes.isEmpty && paint.frame == SessionSmartEngine.maskFrame)
        #expect(model.manualUndoManager?.undoActionName == "Paint Mask Instead")
        #expect(model.maskEditor.tool == .brush && model.maskEditor.selection == .init(mask: mask.id, component: 0))
        // The brush in hand paints that empty brush: its first stroke fills it, not a new mask (`MaskBrush.target`).
        #expect(model.maskEditor.brush.target(on: frame, model: model) == .init(mask: mask.id, component: 0))
        #expect(!model.brushIsPending(on: frame))
        #expect(model.smartStatus(of: painted, for: frame) == nil && model.maskName(mask.id, for: frame) == "Sky 1")
        // Or Remove.
        undo(model)
        model.maskEditor.reset()
        #expect(model.mask(mask.id, for: frame)?.pendingSmart == [.sky])
        step(model) { model.perform(.remove, on: mask.id, for: frame) }
        #expect(model.mask(mask.id, for: frame) == nil)
    }

    @Test func aFailureSaysSoAndTriesAgainAndASelectionNeverMadeSaysSoToo() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        engine.failure = MaskError.invalid("Vision failed")
        step(model) { model.addSmartMask(.subject, for: frame) }
        await model.waitForSelections(on: [frame.url])
        let mask = try #require(model.masks(for: frame).last)
        let failed = try #require(model.smartStatus(of: mask, for: frame))
        #expect(failed.text == "Could not find the subject" && failed.actions == [.retry, .remove] && failed.detail?.contains("Vision failed") == true)
        engine.failure = nil
        let steps = model.manualUndoManager?.undoActionName
        model.perform(.retry, on: mask.id, for: frame)
        await model.waitForSelections(on: [frame.url])
        #expect(selection(of: model.mask(mask.id, for: frame))?.raster != nil && model.manualUndoManager?.undoActionName == steps)

        // A selection asked in a session that ended before it came, as a relaunch finds it.
        let pending = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .person)))])
        let values = model.manualAdjustments(for: frame)
        model.manualEdits[frame.url]?.adjustments = values.settingMasks(try values.masks.appending(pending))
        let notMade = try #require(model.smartStatus(of: pending, for: frame))
        #expect(notMade.text == "Not found yet" && notMade.actions == [.retry, .remove] && notMade.detail?.hasPrefix("Finding people stopped") == true)
        model.perform(.retry, on: pending.id, for: frame)
        await model.waitForSelections(on: [frame.url])
        #expect(selection(of: model.mask(pending.id, for: frame))?.raster != nil)
    }

    // MARK: A newer model

    /// Plan section 2, step 6: after a model change the mask stays as it was; the row says a newer model exists and offers Update and
    /// Keep. The seed survives: nothing changes until Update, which is one step that Undo takes back to the old seed.
    @Test func aSeedFromAnEarlierModelSurvivesAndOffersUpdateAndKeep() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        let defaults = ScratchDefaults()
        model.smartMasks.defaults = defaults
        engine.current = SmartModelPins(sky: ModelProvenance(recipeID: "da3-test-2", weightsSHA256: "w", canarySHA256: "c", fileSHA256: "f"))
        let old = SessionSmartEngine.seed(.sky, value: 200, recipe: "da3-test-1")
        let ref = try await model.storeMaskSeed(old.raster)
        let mask = Mask(components: [MaskComponent(shape: .smart(old.selection(frame: SessionSmartEngine.maskFrame)))],
                        adjustments: try ManualAdjustments(exposureEV: -0.7))
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 0.5, masks: try MaskSet(masks: [mask]))
        model.manualEdits[frame.url]?.maskNotes.rasters[ref.id.hex] = old.provenance
        let before = model.manualEdits[frame.url]
        #expect(model.smartStatus(of: mask, for: frame) == .stale(.sky))
        #expect(model.smartStatus(of: mask, for: frame)?.text == "Made with an earlier model")
        #expect(model.smartStatus(of: mask, for: frame)?.actions == [.update, .keep])
        #expect(model.manualEdits[frame.url] == before && model.maskSeedStore.contains(ref.id), "nothing changes by itself")

        // Keep: the note goes, for this model, and stays gone in the next session.
        model.perform(.keep, on: mask.id, for: frame)
        #expect(model.smartStatus(of: mask, for: frame) == nil && model.manualEdits[frame.url] == before)
        #expect(SmartMasks(defaults: defaults).kept[ref.id.hex] == engine.current.pin(for: .sky))
        // A newer model still: the note comes back for it.
        engine.current.sky?.recipeID = "da3-test-3"
        let later = SmartMasks(defaults: defaults)
        later.inference = MaskInference(engine: engine, turns: DecodeTurns())
        #expect(later.pins.map { $0.pin(for: .sky) } != SmartMasks(defaults: defaults).kept[ref.id.hex])
        engine.current.sky?.recipeID = "da3-test-2"

        // Update: made again; the new seed in one step, the adjustments kept; Undo puts the old seed back, whose file is still there.
        defaults.removeObject(forKey: SmartMasks.keptKey)
        model.smartMasks.defaults = defaults
        #expect(model.smartStatus(of: mask, for: frame) == .stale(.sky))
        let newer = SessionSmartEngine.seed(.sky, value: 240, recipe: "da3-test-2")
        engine.answers = [.sky: .seed(newer)]
        engine.holds = true
        model.perform(.update, on: mask.id, for: frame)
        #expect(model.smartStatus(of: mask, for: frame)?.text == "Updating the sky…")
        #expect(selection(of: model.mask(mask.id, for: frame))?.raster == ref, "the old seed stays while the new one is made")
        try await waitFor { engine.heldCount == 1 }
        engine.release()
        step(model) {}
        model.manualUndoManager?.beginUndoGrouping()
        await model.waitForSelections(on: [frame.url])
        model.manualUndoManager?.endUndoGrouping()
        let updated = try #require(selection(of: model.mask(mask.id, for: frame))?.raster)
        #expect(updated == newer.raster.ref && model.mask(mask.id, for: frame)?.adjustments.exposureEV == -0.7)
        #expect(model.manualUndoManager?.undoActionName == "Update Mask")
        #expect(model.smartStatus(of: try #require(model.mask(mask.id, for: frame)), for: frame) == nil)
        undo(model)
        #expect(selection(of: model.mask(mask.id, for: frame))?.raster == ref && model.maskSeedStore.contains(ref.id))
    }

    /// An Update whose seed arrives while a gesture is open on its frame joins that gesture and leaves it open: the gesture ends as
    /// its row ends it, in one step that Undo takes back to the old seed. Ended by the Update instead, a Light row's drag was cut in
    /// two: what it moved after that stayed with the print, never reached the edit, and the film showed values the frame did not hold.
    @Test func anUpdateThatArrivesInAnOpenGestureJoinsIt() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        let defaults = ScratchDefaults()
        model.smartMasks.defaults = defaults
        engine.current = SmartModelPins(sky: ModelProvenance(recipeID: "da3-test-2", weightsSHA256: "w", canarySHA256: "c", fileSHA256: "f"))
        let old = SessionSmartEngine.seed(.sky, value: 200, recipe: "da3-test-1")
        let ref = try await model.storeMaskSeed(old.raster)
        let mask = Mask(components: [MaskComponent(shape: .smart(old.selection(frame: SessionSmartEngine.maskFrame)))],
                        adjustments: try ManualAdjustments(exposureEV: -0.7))
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 0.5, masks: try MaskSet(masks: [mask]))
        model.manualEdits[frame.url]?.maskNotes.rasters[ref.id.hex] = old.provenance
        let newer = SessionSmartEngine.seed(.sky, value: 240, recipe: "da3-test-2")
        engine.answers = [.sky: .seed(newer)]
        engine.holds = true
        model.perform(.update, on: mask.id, for: frame)
        try await waitFor { engine.heldCount == 1 }

        // A Light row's drag is under way as the new seed lands, and goes on after it.
        model.manualUndoManager?.beginUndoGrouping()
        model.beginLightAdjusting(for: frame)
        model.moveLight(.light(.exposure), to: 1, for: frame)
        engine.release()
        await model.waitForSelections(on: [frame.url])
        #expect(selection(of: model.mask(mask.id, for: frame))?.raster == newer.raster.ref)
        #expect(model.printedEdit(for: frame)?.adjustments.exposureEV == 1, "the print keeps the drag")
        model.moveLight(.light(.exposure), to: 1.5, for: frame)
        model.endLightAdjusting(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.printedLight == nil && model.manualAdjustments(for: frame).exposureEV == 1.5)
        #expect(model.printedEdit(for: frame) == model.manualEdits[frame.url])
        #expect(selection(of: model.mask(mask.id, for: frame))?.raster == newer.raster.ref)
        #expect(model.manualEdits[frame.url]?.maskNotes.rasters[newer.raster.ref.id.hex] == newer.provenance)
        #expect(model.smartStatus(of: try #require(model.mask(mask.id, for: frame)), for: frame) == nil)
        undo(model)
        #expect(model.manualAdjustments(for: frame).exposureEV == 0.5 && selection(of: model.mask(mask.id, for: frame))?.raster == ref)
        #expect(model.smartStatus(of: try #require(model.mask(mask.id, for: frame)), for: frame) == .stale(.sky))
    }

    // MARK: The develop and the print

    @Test func aDevelopWaitsForASelectionUnderWay() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        engine.holds = true
        step(model) { model.addSmartMask(.sky, for: frame) }
        var waited = false
        let develop = Task { @MainActor in
            await model.waitForSelections(on: [frame.url])
            waited = true
        }
        try await waitFor { engine.heldCount == 1 }
        #expect(!waited)
        // Another frame's develop does not wait for it.
        await model.waitForSelections(on: [frames[1].url])
        engine.release()
        await develop.value
        #expect(waited && selection(of: model.masks(for: frame).last)?.raster != nil)
    }

    @Test func thePreviewsLeaveOutASelectionNotMadeAndOnlyThat() throws {
        let made = Mask(components: [MaskComponent(shape: .smart(SessionSmartEngine.seed(.sky).selection(frame: SessionSmartEngine.maskFrame)))],
                        adjustments: try ManualAdjustments(exposureEV: -1))
        let pending = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .person)))], adjustments: try ManualAdjustments(exposureEV: 1))
        let pin = AutomaticBaseline(sourceSHA256: String(repeating: "0", count: 64), stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        let edit = ManualEdit(adjustments: try ManualAdjustments(masks: try MaskSet(masks: [made, pending])), baseline: pin)
        let printed = try #require(RollModel.printable(edit))
        #expect(printed.adjustments.masks.masks.map(\.isEnabled) == [true, false])
        #expect(printed.adjustments.masks.masks.map(\.components) == [made.components, pending.components])
        let plain = ManualEdit(adjustments: try ManualAdjustments(masks: try MaskSet(masks: [made])), baseline: pin)
        #expect(RollModel.printable(plain) == plain && RollModel.printable(nil) == nil)
    }

    // MARK: Words and tiles

    @Test func theRowNamesEachWait() {
        #expect(SmartRowStatus.words(for: .queued, kind: .sky, update: false) == "Finding the sky…")
        #expect(SmartRowStatus.words(for: .finding, kind: .person, update: false) == "Finding people…")
        #expect(SmartRowStatus.words(for: .reading, kind: .subject, update: false) == "Finding the subject…")
        #expect(SmartRowStatus.words(for: .preparing(0.4), kind: .sky, update: false) == "Preparing masks… 40 %")
        // Subject's preparing and finding are the same words, matting and all; a Vision fallback says so quietly, with a reason and no action.
        #expect(SmartRowStatus.words(for: .preparing(0.4), kind: .subject, update: false) == "Preparing masks… 40 %")
        #expect(SmartRowStatus.words(for: .finding, kind: .subject, update: false) == "Finding the subject…")
        let fallback = SmartRowStatus.visionFallback(.subject)
        #expect(fallback.text == "Found by Vision" && fallback.detail?.contains("Vision") == true && fallback.actions.isEmpty && !fallback.isBusy)
        #expect(SmartRowStatus.words(for: .waitingForDevelop, kind: .sky, update: false) == "Waiting for the develop…")
        #expect(SmartRowStatus.words(for: .checkingWater, kind: .sky, update: false) == "Leaving out reflections…")
        #expect(SmartRowStatus.words(for: .finding, kind: .sky, update: true) == "Updating the sky…")
        let preparing = SmartRowStatus.working(.preparing(0.25), kind: .sky, update: false)
        #expect(preparing.progress == 0.25 && preparing.isBusy && preparing.actions == [.cancel] && !preparing.hasActionLine)
        #expect(SmartRowStatus.empty(.person).text == "No people found in this frame")
    }

    /// The owner could not tell which tiles worked: one that cannot be used is dimmed and says why; the build's limits come first,
    /// then the frame's.
    @Test func aTileThatCannotBeUsedSaysWhy() {
        #expect(MaskTileAvailability.of(.brush, frame: nil, smart: nil) == .live)
        #expect(MaskTileAvailability.of(.brush, frame: "Balancing roll…", smart: nil) == .waiting("Balancing roll…"))
        #expect(MaskTileAvailability.of(.linear, frame: nil, smart: nil) == .live)
        #expect(MaskTileAvailability.of(.radial, frame: "Balancing roll…", smart: nil) == .waiting("Balancing roll…"))
        #expect(MaskTileAvailability.of(.sky, frame: nil, smart: .available) == .live)
        let noModels = SmartAvailability.unavailable("Sky needs the sky and water models, and this build of Argent was made without them.")
        #expect(MaskTileAvailability.of(.sky, frame: "Balancing roll…", smart: noModels) == .unavailable(noModels.reason!))
        #expect(MaskTileAvailability.of(.person, frame: "Balancing roll…", smart: .available) == .waiting("Balancing roll…"))
        #expect(MaskTileAvailability.of(.subject, frame: nil, smart: nil).reason != nil)
        // Without the Subject models the tile offers them, whatever the frame, and a click on it opens their screen rather than making a mask.
        let needs = SmartAvailability.needsModels(BundledSmartMasks.needsModels(.subject))
        #expect(MaskTileAvailability.of(.subject, frame: "Balancing roll…", smart: needs) == .offersModels(needs.reason!))
        #expect(MaskTileAvailability.of(.background, frame: nil, smart: needs).isEnabled && !MaskTileAvailability.of(.background, frame: nil, smart: needs).isLive)
        #expect(!MaskTileAvailability.of(.sky, frame: nil, smart: noModels).isEnabled)
    }

    @Test func aBuildWithoutTheModelsSaysWhySkyIsUnavailable() async throws {
        let (model, _, folder, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        // No film previews here (no stocks): the queue the app would make is not there either.
        model.smartMasks.inference = nil
        #expect(model.smartAvailability(.sky).reason != nil)
        let library = folder.appendingPathComponent("models-ledger.json")
        let models = MaskModels(directory: folder.appendingPathComponent("no-models"), ledgerFile: library)
        #expect(!models.isSkyAvailable)
    }
}

/// A smart selection's Feather in the session (decision 19): a drag of its row is one undo step, as a gradient's numbers are; a Feather
/// set while the selection is still being found stays when it lands; and Update keeps it.
extension SmartMaskStateTests {
    /// What the Feather row does through a drag: the gesture's begin, its steps, its end with the row's own name.
    private func drag(_ model: RollModel, _ mask: UUID, on frame: Frame, through values: [Float]) {
        // The fixture's undo manager does not group by event: the event's group, as the run loop opens it for a real drag.
        model.manualUndoManager?.beginUndoGrouping()
        defer { model.manualUndoManager?.endUndoGrouping() }
        model.beginManualGesture(for: frame)
        model.maskEditor.shapeRowBegan()
        for value in values {
            guard let now = model.mask(mask, for: frame)?.components[0].shape,
                  let updated = MaskShapeField.selectionFeather.setting(value, in: now) else { continue }
            model.setComponentShape(updated, of: mask, component: 0, for: frame)
        }
        model.maskEditor.shapeRowEnded()
        let shape = model.mask(mask, for: frame)?.components[0].shape
        model.endManualGesture(for: frame, actionName: shape.map(MaskShapeField.actionName(of:)) ?? "")
    }

    @Test func aFeatherDragIsOneStepAndUndoes() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        _ = engine
        step(model) { model.addSmartMask(.sky, for: frame) }
        await model.waitForSelections(on: [frame.url])
        let mask = try #require(model.masks(for: frame).last)
        let made = try #require(selection(of: mask))
        #expect(made.raster != nil && made.feather == 0 && model.manualUndoManager?.undoActionName == "Add Sky Mask")
        drag(model, mask.id, on: frame, through: [4, 11, 19, 30, 42])
        let feathered = try #require(selection(of: model.mask(mask.id, for: frame)))
        #expect(feathered.feather == 42 && feathered.raster == made.raster && feathered.frame == made.frame)
        #expect(model.manualUndoManager?.undoActionName == "Feather Mask")
        // The record that is saved holds it, at masks schema 2.
        #expect(MaskSet.schema(of: model.masks(for: frame)) == 2)
        undo(model)
        #expect(selection(of: model.mask(mask.id, for: frame)) == made && model.manualUndoManager?.undoActionName == "Add Sky Mask")
        redo(model)
        #expect(selection(of: model.mask(mask.id, for: frame))?.feather == 42)
        // A typed value or a double-click to the default is one step too.
        drag(model, mask.id, on: frame, through: [MaskShapeField.selectionFeather.spec(default: nil, order: 10).defaultValue])
        #expect(selection(of: model.mask(mask.id, for: frame))?.feather == 0)
        undo(model)
        #expect(selection(of: model.mask(mask.id, for: frame))?.feather == 42)
    }

    @Test func aFeatherSetWhileTheSelectionIsFoundStaysAndUpdateKeepsIt() async throws {
        let (model, frames, folder, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        let defaults = ScratchDefaults()
        model.smartMasks.defaults = defaults
        engine.holds = true
        step(model) { model.addSmartMask(.sky, for: frame) }
        let mask = try #require(model.masks(for: frame).last)
        #expect(mask.pendingSmart == [.sky])
        drag(model, mask.id, on: frame, through: [25])
        #expect(selection(of: model.mask(mask.id, for: frame))?.feather == 25 && selection(of: model.mask(mask.id, for: frame))?.raster == nil)
        try await waitFor { engine.heldCount == 1 }
        engine.release()
        await model.waitForSelections(on: [frame.url])
        let landed = try #require(selection(of: model.mask(mask.id, for: frame)))
        #expect(landed.raster != nil && landed.feather == 25)

        // Update, made again by a newer model: the new seed, the Feather kept.
        engine.holds = false
        engine.current = SmartModelPins(sky: ModelProvenance(recipeID: "da3-test-2", weightsSHA256: "w", canarySHA256: "c", fileSHA256: "f"))
        #expect(model.smartStatus(of: try #require(model.mask(mask.id, for: frame)), for: frame) == .stale(.sky))
        let newer = SessionSmartEngine.seed(.sky, value: 240, recipe: "da3-test-2")
        engine.answers = [.sky: .seed(newer)]
        step(model) { model.perform(.update, on: mask.id, for: frame) }
        model.manualUndoManager?.beginUndoGrouping()
        await model.waitForSelections(on: [frame.url])
        model.manualUndoManager?.endUndoGrouping()
        let updated = try #require(selection(of: model.mask(mask.id, for: frame)))
        #expect(updated.raster == newer.raster.ref && updated.feather == 25)
    }

    /// The overlay shows the feathered edge: before a decode is held it shows the seed, blurred over the same share of the long side
    /// as the print's field; at Feather 0 it is the seed as it was.
    @Test func theOverlayShowsTheFeatheredSeed() async throws {
        let (model, frames, folder, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frame = frames[0]
        step(model) { model.addSmartMask(.sky, for: frame) }
        await model.waitForSelections(on: [frame.url])
        let mask = try #require(model.masks(for: frame).last)
        let made = try #require(selection(of: mask))
        let field = MaskSeedCoverage(store: model.maskSeedStore)
        let (w, h) = (1200, 800)   // Feather 100 is σ 3 px here
        var feathered = made
        feathered.feather = 100
        let sharp = field.raster(of: [MaskComponent(shape: .smart(made))], width: w, height: h)
        let soft = field.raster(of: [MaskComponent(shape: .smart(feathered))], width: w, height: h)
        let seed = try model.maskSeedStore.load(try #require(made.raster))
        let stretched = MaskSeedCoverage.stretched(seed, width: w, height: h, complement: false)
        #expect(sharp == stretched.map { UInt8(min(255, max(0, $0 * 255 + 0.5))) })
        let expected = MaskFeather.blurred(stretched, width: w, height: h, feather: 100).map { UInt8(min(255, max(0, $0 * 255 + 0.5))) }
        #expect(soft == expected && soft != sharp)
        // The seed's left half is sky, stretched into a ramp from x 581 to 619: the feathered overlay reaches a σ past both its ends.
        let row = 400 * w
        #expect(sharp[row + 578] == 255 && sharp[row + 622] == 0)
        #expect(soft[row + 578] < 255 && soft[row + 622] > 0 && soft[row + 540] == 255 && soft[row + 660] == 0)
    }
}
