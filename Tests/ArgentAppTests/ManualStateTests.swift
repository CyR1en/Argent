import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

@MainActor @Suite(.serialized) struct ManualStateTests {
    private func header(_ url: URL, iso: UInt16 = 100) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        let exif = 26
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(exif) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(Int(iso)) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    private func fixture() async throws -> (RollModel, Frame, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-manual-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        try header(folder.appendingPathComponent("DSC2.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        let frame = try #require(model.selectedFrame)
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        let aim = PrintAim(level: -0.65, cast: SIMD3(0.2, -0.1, 0.15))
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: aim, analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(labBalance: SIMD3(0.1, 0.2, 0.3)), grain: .off))
        model.manualEdits[frame.url] = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5, shadows: 40), baseline: pin)
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        return (model, frame, folder)
    }

    @Test func resetUndoRestoresTheWholePinAndSelectsItsFrame() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = model.manualEdits[frame.url]
        model.manualUndoManager?.beginUndoGrouping()
        model.resetManualAdjustments(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualEdits[frame.url] == nil)
        model.selection = 1
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before)
        #expect(model.selection == frame.id)
        #expect(model.isFrameOpen)
        model.manualUndoManager?.redo()
        #expect(model.manualEdits[frame.url] == nil)
    }

    @Test func curveGestureAndResetPreserveLightAndUndoTheCompleteIntent() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(model.manualEdits[frame.url])
        model.manualUndoManager?.beginUndoGrouping()
        model.beginManualGesture(for: frame)
        model.setToneCurves(try ToneCurves(tone: ToneCurves.Preset.softContrast.curve), for: frame)
        model.setToneCurves(try ToneCurves(tone: ToneCurves.Preset.strongContrast.curve), for: frame)
        model.endManualGesture(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        let refined = try #require(model.manualEdits[frame.url])
        #expect(refined.baseline == before.baseline)
        #expect(refined.adjustments.exposureEV == before.adjustments.exposureEV)
        #expect(refined.adjustments.shadows == before.adjustments.shadows)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before)
        model.manualUndoManager?.redo()
        #expect(model.manualEdits[frame.url] == refined)
        model.manualUndoManager?.beginUndoGrouping()
        model.resetToneCurves(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualEdits[frame.url] == before)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == refined)
    }

    @Test func curveOnlyIntentRemainsPinnedWhenLightIsZeroAndMakesDevelopAvailable() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try #require(model.manualEdits[frame.url])
        let curves = try ToneCurves(tone: ToneCurves.Preset.liftedBlacks.curve)
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(curves: curves)
        let inputs = DevelopInputs(model)
        model.beginManualGesture(for: frame)
        model.setManualAdjustments(try ManualAdjustments(curves: curves).setting(.exposure, to: 0.5), for: frame)
        model.setManualAdjustments(try ManualAdjustments(curves: curves), for: frame)
        model.endManualGesture(for: frame)
        #expect(model.manualEdits[frame.url]?.baseline == old.baseline)
        #expect(model.hasManualAdjustments(frame))
        model.manualUndoManager?.beginUndoGrouping()
        model.setToneCurves(try ToneCurves(tone: ToneCurves.Preset.softContrast.curve), for: frame)
        model.manualUndoManager?.endUndoGrouping()
        model.developPhase = .developing(DevelopProgress(total: 2))
        model.recordDevelop(DevelopReport(frames: [frame], outcomes: [.developed(folder.appendingPathComponent("DSC1.jpg"))], destination: folder), inputs: inputs)
        #expect(model.developPhase == .idle)
    }

    @Test func resetLightClearsTheSixValuesInOneUndoStepAndKeepsCurvesAndThePin() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 4.5, contrast: 20, highlights: -60,
            shadows: 40, whites: 10, blacks: -5, curves: curves)
        let before = try #require(model.manualEdits[frame.url])
        model.manualUndoManager?.beginUndoGrouping()
        model.resetLight(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(curves: curves)))
        #expect(model.manualEdits[frame.url]?.baseline == before.baseline)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before)
        #expect(model.manualUndoManager?.canUndo == false)
        // With no curve left either, Reset Light releases the pin as Reset to Current Auto does.
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: -0.33)
        model.isComparingAuto = true
        model.manualUndoManager?.beginUndoGrouping()
        model.resetLight(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualEdits[frame.url] == nil && !model.isComparingAuto)
        // Nothing to clear is no undo step.
        model.manualUndoManager?.removeAllActions()
        model.resetLight(for: frame)
        #expect(model.manualUndoManager?.canUndo == false)
    }

    private func masks() throws -> MaskSet {
        try MaskSet(masks: [Mask(components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: 0.5))))],
                                 adjustments: try ManualAdjustments(exposureEV: -0.7))])
    }

    /// Reset Light rebuilt its values from the curves alone until masks; they are the frame's, and the Light tab's reset leaves them.
    @Test func resetLightKeepsMasksAndThePinTheyNeed() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = try masks(), curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 1, shadows: 40, curves: curves, masks: set)
        let before = try #require(model.manualEdits[frame.url])
        model.manualUndoManager?.beginUndoGrouping()
        model.resetLight(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(curves: curves, masks: set)))
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before)
        // Masks with every slider at zero and no curves are still an edit: the pin stays, and the frame is Edited.
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 1, masks: set)
        model.manualUndoManager?.beginUndoGrouping()
        model.resetLight(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualEdits[frame.url]?.baseline == before.baseline)
        #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(masks: set)))
        #expect(model.hasManualAdjustments(frame) && !model.manualAdjustments(for: frame).isIdentity)
        // Curves too leave them.
        model.manualUndoManager?.beginUndoGrouping()
        model.setToneCurves(curves, for: frame)
        model.setToneCurves(.identity, for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).masks == set && model.hasManualAdjustments(frame))
    }

    /// Every reset that returns to a starting point removes masks with the rest, in one undo step, and takes their notes.
    @Test func resetToAutoAndStartFromClearMasksInOneUndoStep() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = try masks()
        let named = MaskNotes(names: [set.masks[0].id.uuidString: "Sky"])
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(masks: set)
        model.manualEdits[frame.url]?.maskNotes = named
        let before = try #require(model.manualEdits[frame.url])
        model.manualUndoManager?.beginUndoGrouping()
        model.resetManualAdjustments(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualEdits[frame.url] == nil && model.manualAdjustments(for: frame).masks.isEmpty)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before && model.manualEdits[frame.url]?.maskNotes == named)
        #expect(model.manualUndoManager?.canUndo == false)
        // An Original kept as the starting point keeps its pin, and none of its masks or their names.
        var original = before
        original.baseline.origin = .original
        original.baseline.aim = PrintAim()
        model.manualEdits[frame.url] = original
        model.manualUndoManager?.beginUndoGrouping()
        model.startFromOriginal(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        let cleared = try #require(model.manualEdits[frame.url])
        #expect(cleared.baseline.origin == .original && cleared.adjustments.isIdentity && cleared.maskNotes == .none)
    }

    /// A mask-only edit reads as one everywhere the app asks: Compare to Auto takes it away and leaves the others alone.
    @Test func aMaskOnlyEditIsAnEditAndCompareShowsAutoWithoutIt() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(masks: try masks())
        #expect(model.manualEdits[frame.url]?.isEmpty == false && model.hasManualAdjustments(frame))
        // Reset to Current Auto and Start from take it. Reset to Original would pin it anew through a stock, which this roll has
        // none of (`FrameStockTests.resetToOriginalNeedsAStock`).
        #expect(model.canResetManual(frame) && model.canChangeStartingPoint(frame) && !model.canStartFromOriginal(frame))
        #expect(model.automaticSettings(for: frame, stock: 0).manual == .identity)
    }

    // MARK: Masks: each gesture one undo step, named

    private func gradient(_ y: Float = 0.5) -> MaskShape {
        .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: y)))
    }

    /// Runs `body` as one event's worth of undo, and says what it registered.
    private func step(_ model: RollModel, _ body: () -> Void) -> String? {
        let before = model.manualUndoManager?.undoCount ?? 0
        model.manualUndoManager?.beginUndoGrouping()
        body()
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualUndoManager?.undoCount == before + 1, "one undo step")
        return model.manualUndoManager?.undoActionName
    }

    /// `body` as one group, for what is not counted: the fixture's undo manager has no event to group by.
    private func grouped(_ model: RollModel, _ body: () -> Void) {
        model.manualUndoManager?.beginUndoGrouping()
        body()
        model.manualUndoManager?.endUndoGrouping()
    }

    /// A mask on the fixture's frame, made as a tile and a drag make it, selected as they leave it.
    @discardableResult private func addMask(_ model: RollModel, _ frame: Frame, shape: MaskShape? = nil) -> UUID? {
        var made: UUID?
        model.manualUndoManager?.beginUndoGrouping()
        if let target = model.beginDrawnShape(shape ?? gradient(), tool: .linear, operation: nil, for: frame) {
            model.endManualGesture(for: frame, actionName: "Add Linear Gradient")
            made = target.mask
            model.maskEditor.selection = target
        }
        model.manualUndoManager?.endUndoGrouping()
        return made
    }

    /// Every gesture of a mask is one step with its name, undoes to exactly what was before and redoes to what it did.
    @Test func everyMaskGestureIsOneNamedUndoStep() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.adjustTab = .masks
        model.isAdjustmentsShown = true
        model.openFrame()
        defer { model.maskEditor.reset() }
        let id = try #require(addMask(model, frame))
        func masks() -> MaskSet { model.manualAdjustments(for: frame).masks }

        let gestures: [(String, () -> Void)] = [
            ("Adjust Mask", {
                model.beginManualGesture(for: frame)
                for value in stride(from: Float(-0.1), through: -0.6, by: -0.1) { model.setMaskValue(.exposure, to: value, mask: id, for: frame) }
                model.endManualGesture(for: frame, actionName: "Adjust Mask")
            }),
            ("Adjust Mask", {
                model.beginManualGesture(for: frame)
                for amount in [Float(0.5), 0.7, 1.5] { model.setMaskAmount(amount, mask: id, for: frame) }
                model.endManualGesture(for: frame, actionName: "Adjust Mask")
            }),
            ("Adjust Gradient", {
                model.beginManualGesture(for: frame)
                for y in [Float(0.2), 0.3] { model.setComponentShape(self.gradient(y), of: id, component: 0, for: frame) }
                model.endManualGesture(for: frame, actionName: "Adjust Gradient")
            }),
            ("Rename Mask", { model.renameMask(id, to: "Sky", for: frame) }),
            ("Turn Mask Off", { model.setMaskEnabled(false, mask: id, for: frame) }),
            ("Turn Mask On", { model.setMaskEnabled(true, mask: id, for: frame) }),
            ("Invert Mask", { model.invertSelectedComponent(for: frame) }),
            ("Duplicate Mask", { model.duplicateMask(id, for: frame) }),
            ("Delete Mask", { model.deleteMask(masks().masks[1].id, for: frame) }),
        ]
        for (name, gesture) in gestures {
            let before = try #require(model.manualEdits[frame.url])
            #expect(step(model, gesture) == name)
            let after = try #require(model.manualEdits[frame.url])
            #expect(after != before, "\(name) changed something")
            model.manualUndoManager?.undo()
            #expect(model.manualEdits[frame.url] == before, "\(name) undoes")
            model.manualUndoManager?.redo()
            #expect(model.manualEdits[frame.url] == after, "\(name) redoes")
        }
    }

    @Test func aMaskTakesAndGivesUpComponentsAsOneStepEach() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.adjustTab = .masks
        model.isAdjustmentsShown = true
        model.openFrame()
        defer { model.maskEditor.reset() }
        let id = try #require(addMask(model, frame))
        for (operation, name) in [(MaskOperation.add, "Add Linear"), (.subtract, "Subtract Linear"), (.intersect, "Intersect Linear")] {
            model.manualUndoManager?.beginUndoGrouping()
            let target = try #require(model.beginDrawnShape(gradient(0.3), tool: .linear, operation: operation, for: frame))
            model.endManualGesture(for: frame, actionName: MaskEditor.Tool.linear.actionName(adding: operation))
            model.manualUndoManager?.endUndoGrouping()
            #expect(target.mask == id && model.manualUndoManager?.undoActionName == name)
        }
        var mask = try #require(model.mask(id, for: frame))
        #expect(mask.components.map(\.operation) == [.add, .add, .subtract, .intersect])
        #expect(step(model) { model.setComponentOperation(.subtract, component: 1, of: id, for: frame) } == "Subtract in Mask")
        // The first of a mask is added, whatever is asked, and asking is no step.
        model.setComponentOperation(.subtract, component: 0, of: id, for: frame)
        #expect(model.mask(id, for: frame)?.components[0].operation == .add)
        // Invert acts on the selected component, or with only the mask selected the first.
        model.maskEditor.selection = MaskEditor.Selection(mask: id, component: 2)
        _ = step(model) { model.invertSelectedComponent(for: frame) }
        mask = try #require(model.mask(id, for: frame))
        #expect(mask.components.map(\.invert) == [false, false, true, false])
        model.maskEditor.selection = MaskEditor.Selection(mask: id, component: nil)
        _ = step(model) { model.invertSelectedComponent(for: frame) }
        #expect(model.mask(id, for: frame)?.components.map(\.invert) == [true, false, true, false])
        // What comes first after a removal is added, since a mask starts from nothing.
        #expect(step(model) { model.removeComponent(0, of: id, for: frame) } == "Remove from Mask")
        mask = try #require(model.mask(id, for: frame))
        #expect(mask.components.count == 3 && mask.components[0].operation == .add)
        _ = step(model) { model.removeComponent(0, of: id, for: frame) }
        _ = step(model) { model.removeComponent(0, of: id, for: frame) }
        #expect(model.mask(id, for: frame)?.components.count == 1)
        // The last one takes the mask with it.
        #expect(step(model) { model.removeComponent(0, of: id, for: frame) } == "Delete Mask")
        #expect(model.mask(id, for: frame) == nil)
    }

    /// A slider writes its value and nothing else: `Mask.coverage` is the key of the field, so a slider, Amount, the
    /// switch and a name leave it alone, and a rename does not even move the digest a develop compares.
    @Test func aMaskSliderNeverTouchesCoverage() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(addMask(model, frame))
        let coverage = try #require(model.mask(id, for: frame)?.coverage)
        grouped(model) {
            model.setMaskValue(.exposure, to: -0.6, mask: id, for: frame)
            model.setMaskValue(.shadows, to: 25, mask: id, for: frame)
            model.setMaskAmount(1.5, mask: id, for: frame)
            model.setMaskEnabled(false, mask: id, for: frame)
        }
        #expect(model.mask(id, for: frame)?.adjustments.exposureEV == -0.6)
        let digest = model.manualAdjustments(for: frame).masks.digest
        grouped(model) { model.renameMask(id, to: "Sky", for: frame) }
        #expect(model.mask(id, for: frame)?.coverage == coverage)
        #expect(model.manualAdjustments(for: frame).masks.digest == digest)
        #expect(model.maskName(id, for: frame) == "Sky")
        // A slider's reach is the Light tab's, through the same validation.
        model.setMaskValue(.exposure, to: 99, mask: id, for: frame)
        #expect(model.mask(id, for: frame)?.adjustments.exposureEV == -0.6)
        model.setMaskAmount(3, mask: id, for: frame)
        #expect(model.mask(id, for: frame)?.amount == 1.5)
    }

    @Test func aMaskWithEverySliderAtZeroKeepsThePin() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Nothing else on the edit: only the mask holds the pin.
        model.manualEdits[frame.url]?.adjustments = .identity
        let baseline = model.manualEdits[frame.url]?.baseline
        let id = try #require(addMask(model, frame))
        #expect(model.mask(id, for: frame)?.adjustments.isIdentity == true)
        #expect(model.manualEdits[frame.url]?.baseline == baseline && model.hasManualAdjustments(frame) && model.manualEdits[frame.url]?.isEmpty == false)
        // And without it the pin goes, as it does for a Light value set back to zero.
        grouped(model) { model.deleteMask(id, for: frame) }
        #expect(model.manualEdits[frame.url] == nil)
    }

    /// A name and a mask go together: a mask's notes are in the edit, the undo restores them, and they go with it.
    @Test func aNameIsInTheNotesAndGoesWithItsMask() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(addMask(model, frame))
        #expect(model.manualEdits[frame.url]?.maskNotes.names[id.uuidString] == "Linear 1")
        // Nothing to say and the same name are no step at all.
        model.manualUndoManager?.removeAllActions()
        model.renameMask(id, to: "  ", for: frame)
        model.renameMask(id, to: "Linear 1", for: frame)
        #expect(model.maskName(id, for: frame) == "Linear 1" && model.manualUndoManager?.canUndo == false)
        grouped(model) { model.renameMask(id, to: " Sky ", for: frame) }
        #expect(model.manualEdits[frame.url]?.maskNotes.names[id.uuidString] == "Sky")
        grouped(model) { model.duplicateMask(id, for: frame) }
        let copy = try #require(model.masks(for: frame).last)
        #expect(model.maskName(copy.id, for: frame) == "Sky copy" && copy.id != id && copy.coverage == model.mask(id, for: frame)?.coverage)
        #expect(model.masks(for: frame).map(\.id).first == id)
        grouped(model) { model.deleteMask(id, for: frame) }
        #expect(model.manualEdits[frame.url]?.maskNotes.names[id.uuidString] == nil)
        #expect(model.maskName(UUID(), for: frame) == "Mask")
    }

    // MARK: Masks: resets

    /// Reset masks takes every mask in one step and leaves Light, curves and the pin.
    @Test func resetMasksKeepsLightCurvesAndThePin() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 1, shadows: 40, curves: curves)
        let baseline = model.manualEdits[frame.url]?.baseline
        let one = try #require(addMask(model, frame)), two = try #require(addMask(model, frame))
        grouped(model) { model.renameMask(one, to: "Sky", for: frame) }
        let before = try #require(model.manualEdits[frame.url])
        #expect(step(model) { model.resetMasks(for: frame) } == "Reset Masks")
        #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(exposureEV: 1, shadows: 40, curves: curves)))
        #expect(model.manualEdits[frame.url]?.baseline == baseline && model.manualEdits[frame.url]?.maskNotes == MaskNotes.none)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before && model.mask(two, for: frame) != nil && model.maskName(one, for: frame) == "Sky")
        // With nothing else on the edit the pin goes too, and on an Original it stays.
        let alone = try ManualAdjustments(masks: model.manualAdjustments(for: frame).masks)
        model.manualEdits[frame.url]?.adjustments = alone
        grouped(model) { model.resetMasks(for: frame) }
        #expect(model.manualEdits[frame.url] == nil)
        model.manualUndoManager?.undo()
        model.manualEdits[frame.url]?.baseline.origin = .original
        grouped(model) { model.resetMasks(for: frame) }
        #expect(model.manualEdits[frame.url]?.baseline.origin == .original && model.manualAdjustments(for: frame).isIdentity)
        // Nothing to reset is no step.
        model.manualUndoManager?.removeAllActions()
        model.resetMasks(for: frame)
        #expect(model.manualUndoManager?.canUndo == false)
    }

    /// Reset Light and Reset curves leave masks alone; each is its own step.
    @Test func resetLightAndResetCurvesKeepMasks() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let curves = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
        grouped(model) { model.setToneCurves(curves, for: frame) }
        let id = try #require(addMask(model, frame))
        grouped(model) { model.setMaskValue(.exposure, to: -0.5, mask: id, for: frame) }
        let masks = model.manualAdjustments(for: frame).masks
        _ = step(model) { model.resetLight(for: frame) }
        #expect(model.manualAdjustments(for: frame).masks == masks && model.manualAdjustments(for: frame).exposureEV == 0 && !model.manualAdjustments(for: frame).curves.isIdentity)
        _ = step(model) { model.resetToneCurves(for: frame) }
        #expect(model.manualAdjustments(for: frame).masks == masks && model.manualAdjustments(for: frame).curves.isIdentity)
    }

    /// Reset to Auto, Start from and Reset to Original clear masks in one step, and no mask stays selected.
    @Test func everyResetToAStartingPointLetsTheSelectionGo() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.adjustTab = .masks
        model.isAdjustmentsShown = true
        model.openFrame()
        defer { model.maskEditor.reset() }
        let id = try #require(addMask(model, frame))
        #expect(model.maskEditor.selection?.mask == id)
        #expect(step(model) { model.resetManualAdjustments(for: frame) } == "Adjust Frame")
        #expect(model.masks(for: frame).isEmpty && model.maskEditor.selection == nil)
        model.manualUndoManager?.undo()
        #expect(model.mask(id, for: frame) != nil && model.maskEditor.selection?.mask == id)
        // An Original keeps its pin and clears its masks.
        model.manualEdits[frame.url]?.baseline.origin = .original
        model.manualEdits[frame.url]?.baseline.aim = PrintAim()
        #expect(step(model) { model.startFromOriginal(for: frame, actionName: "Reset to Original") } == "Reset to Original")
        #expect(model.masks(for: frame).isEmpty && model.maskEditor.selection == nil && model.manualEdits[frame.url]?.baseline.origin == .original)
    }

    /// Compare to Auto shows none of them.
    @Test func compareToAutoShowsNoMask() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try #require(addMask(model, frame))
        #expect(model.automaticSettings(for: frame, stock: 0).manual == .identity)
        #expect(model.settings(for: frame, stock: 0).manual == .identity || model.films == nil)
    }

    @Test func theClippingViewIsAViewOnlyAndEndsWithTheFrameView() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let edit = model.manualEdits[frame.url], settings = model.settings(for: frame, stock: 0)
        model.openFrame()
        model.lightClipping = .highlights
        #expect(model.settings(for: frame, stock: 0) == settings)
        #expect(model.manualEdits[frame.url] == edit && model.manualUndoManager?.canUndo == false)
        model.closeFrame()
        #expect(model.lightClipping == nil)
    }

    @Test func aContinuousGestureCrossingZeroKeepsItsStartingPin() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(model.manualEdits[frame.url])
        model.manualUndoManager?.beginUndoGrouping()
        model.beginManualGesture(for: frame)
        model.setManualAdjustments(.identity, for: frame)
        #expect(model.manualEdits[frame.url]?.baseline == before.baseline)
        model.setManualAdjustments(try ManualAdjustments(exposureEV: -0.5), for: frame)
        model.endManualGesture(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualEdits[frame.url]?.baseline == before.baseline)
        #expect(model.manualAdjustments(for: frame).exposureEV == -0.5)
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before)
    }

    /// A Light row's gesture (J): its steps reach the print alone, so nothing that reads the edit runs for them; its end writes the
    /// six values over the edit as it is by then (a mask that landed meanwhile stays), lets the print go and makes one step.
    @Test func aLightSlidersStepsReachTheEditOnlyAtItsEnd() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(model.manualEdits[frame.url])
        model.manualUndoManager?.beginUndoGrouping()
        model.beginLightAdjusting(for: frame)
        for step in 1...4 { model.moveLight(.light(.exposure), to: 0.5 + 0.25 * Float(step), for: frame) }
        model.moveLight(.light(.shadows), to: 10, for: frame)
        #expect(model.manualEdits[frame.url] == before)
        let printed = try #require(model.printedEdit(for: frame))
        #expect(printed.adjustments.exposureEV == 1.5 && printed.adjustments.shadows == 10 && printed.baseline == before.baseline)
        // A mask made meanwhile (a smart selection landing) goes to the edit, and the print shows it under the moving values.
        let set = try masks()
        model.setManualAdjustments(model.manualAdjustments(for: frame).settingMasks(set), for: frame)
        #expect(model.printedEdit(for: frame)?.adjustments.masks == set && model.printedEdit(for: frame)?.adjustments.exposureEV == 1.5)
        model.endLightAdjusting(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.printedLight == nil && model.printedEdit(for: frame) == model.manualEdits[frame.url])
        #expect(model.manualAdjustments(for: frame).exposureEV == 1.5 && model.manualAdjustments(for: frame).shadows == 10)
        #expect(model.manualAdjustments(for: frame).masks == set && model.manualEdits[frame.url]?.baseline == before.baseline)
        #expect(model.manualUndoManager?.undoActionName == "Adjust Frame")
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before)
        // A cancelled gesture lets the print go and writes nothing; outside a gesture a step is the edit's at once.
        model.beginLightAdjusting(for: frame)
        model.moveLight(.light(.contrast), to: 30, for: frame)
        model.cancelManualGesture(for: frame)
        #expect(model.printedLight == nil && model.manualEdits[frame.url] == before)
        model.endLightAdjusting(for: frame)
        grouped(model) { model.moveLight(.light(.contrast), to: 20, for: frame) }
        #expect(model.manualAdjustments(for: frame).contrast == 20 && model.printedLight == nil)
    }

    @Test func sourceReplacementHoldsValuesWithoutAttachingOldPin() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = model.manualEdits[frame.url]
        try header(frame.url, iso: 6400)
        #expect(model.forgetChangedSources())
        #expect(model.manualEdits[frame.url] == nil)
        #expect(model.heldManualEdits[frame.url] == old)
        #expect(model.manualIssueRequiresReapply(for: frame))
        #expect(!model.canAdjust(frame))
        #expect(model.manualReadySources[frame.url] == nil)
    }

    @Test func aReplacementMeasurementHoldsTheOldPinBeforeTheWatcherRuns() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = model.manualEdits[frame.url]
        try header(frame.url, iso: 6400)
        let replacement = try SourceDigests.shared.digest(of: frame.url)
        let measurement = ExposureAnalysis(meanStops: 1.2, validWeight: 1)

        model.record(FrameMeasurement(analysis: measurement, source: replacement.source), for: frame)

        #expect(model.manualEdits[frame.url] == nil)
        #expect(model.heldManualEdits[frame.url] == old)
        #expect(model.manualIssueRequiresReapply(for: frame))
        #expect(model.manualReadySources[frame.url] == nil)
        #expect(model.sourceStamp(for: frame) == replacement.source)
        #expect(model.analysis(for: frame) == measurement)
        #expect(!model.forgetChangedSources())
    }

    @Test func undoBeforeTheWatcherRunsCannotAttachAPinToAReplacement() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = model.manualEdits[frame.url]
        model.manualUndoManager?.beginUndoGrouping()
        model.resetManualAdjustments(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        try header(frame.url, iso: 6400)

        model.manualUndoManager?.undo()

        #expect(model.manualEdits[frame.url] == nil)
        #expect(model.heldManualEdits[frame.url] == old)
        #expect(model.manualIssueRequiresReapply(for: frame))
        #expect(model.selection == frame.id)
        #expect(model.isFrameOpen)
    }

    @Test func cancelledPreparationCannotPublishReadiness() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.manualReadySources[frame.url] = nil
        let preparation = Task { await model.prepareManualAdjustments(for: frame) }
        preparation.cancel()
        await preparation.value
        #expect(model.manualReadySources[frame.url] == nil)
        #expect(model.manualPreparationErrors.isEmpty)
    }

    @Test func preparationWaitingForRestoreCannotPopulateANewSession() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoration = AsyncStream<Void>.makeStream()
        model.manualRestoreTask = Task { for await _ in restoration.stream {} }
        var started = false
        let preparation = Task {
            started = true
            await model.prepareManualAdjustments(for: frame)
        }
        while !started { await Task.yield() }

        model.clearManualSession()
        restoration.continuation.finish()
        await preparation.value

        #expect(model.manualReadySources.isEmpty)
        #expect(model.manualPreparationErrors.isEmpty)
        #expect(model.manualErrors.isEmpty)
    }

    @Test func successfulPreparationRecoversAReadFailureAndPreservesRecipeIssues() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.manualEdits[frame.url] = nil
        model.manualReadySources[frame.url] = nil
        try FileManager.default.removeItem(at: frame.url)
        await model.prepareManualAdjustments(for: frame)
        #expect(model.manualIssue(for: frame)?.hasPrefix("Could not prepare adjustments:") == true)

        try header(frame.url)
        #expect(model.forgetChangedSources())
        await model.prepareManualAdjustments(for: frame)
        #expect(model.manualIssue(for: frame) == nil)
        #expect(model.manualReadySources[frame.url]?.source == SourceStamp.of(frame.url))

        model.manualErrors[frame.url] = "Unsupported saved recipe"
        await model.prepareManualAdjustments(for: frame)
        #expect(model.manualIssue(for: frame) == "Unsupported saved recipe")
    }

    @Test func preparationCannotReadyAReplacementBeforeItsHeaderAndAnalysisRefresh() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.manualReadySources[frame.url] = nil
        try header(frame.url, iso: 6400)
        await model.prepareManualAdjustments(for: frame)
        #expect(model.manualReadySources[frame.url] == nil)
        #expect(!model.canAdjust(frame))
    }

    @Test func openingAnotherRollLeavesTheDevelopPageAndClearsManualSession() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.showDevelopPage()
        #expect(model.workspacePage == .develop)
        let next = folder.appendingPathComponent("Next", isDirectory: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try header(next.appendingPathComponent("NEXT.ARW"))

        await model.open(next)
        if let restoration = model.manualRestoreTask { await restoration.value }

        #expect(model.roll?.folder == next)
        #expect(model.workspacePage == .roll)
        #expect(model.manualEdits[frame.url] == nil)
        #expect(model.heldManualEdits.isEmpty)
        #expect(model.manualReadySources[frame.url] == nil)
    }

    @Test func menuResetAvailabilityTracksEditsAndSessionReadiness() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let edit = model.manualEdits[frame.url]
        #expect(!model.menuState.canResetManual)
        model.openFrame()
        #expect(model.menuState.canResetManual)
        model.manualUndoManager?.beginUndoGrouping()
        model.resetManualAdjustments(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(!model.menuState.canResetManual)
        model.manualEdits[frame.url] = edit
        #expect(model.menuState.canResetManual)
        model.isQuitting = true
        #expect(!model.menuState.canResetManual)
        model.isQuitting = false
        model.isRestoringManual = true
        #expect(!model.menuState.canResetManual)
        model.isRestoringManual = false

        let restoration = AsyncStream<Void>.makeStream()
        model.manualRestoreTask = Task { for await _ in restoration.stream {} }
        let opening = Task { await model.open(folder) }
        while !model.isScanning { await Task.yield() }
        #expect(!model.menuState.canResetManual)
        restoration.continuation.finish()
        await opening.value
        if let restore = model.manualRestoreTask { await restore.value }
        #expect(!model.menuState.canResetManual)
    }

    @Test func manualChangeDuringExportLeavesDevelopAvailable() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inputs = DevelopInputs(model)
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 1)
        model.developPhase = .developing(DevelopProgress(total: 2))
        let report = DevelopReport(frames: [frame], outcomes: [.developed(folder.appendingPathComponent("DSC1.jpg"))], destination: folder)
        model.recordDevelop(report, inputs: inputs)
        #expect(model.developPhase == .idle)
        #expect(model.manualAdjustments(for: frame).exposureEV == 1)
    }

    /// A toy stock's folder in `folder`, so a model's saves have a stock to resolve through.
    private func toyStocks(in folder: URL) throws -> URL {
        let stocks = folder.appendingPathComponent("Stocks"), stock = stocks.appendingPathComponent("toy")
        try FileManager.default.createDirectory(at: stock, withIntermediateDirectories: true)
        let lut = LUT3D.identity(size: 2)
        try lut.binaryData().write(to: stock.appendingPathComponent("negative.lut3d"))
        try lut.binaryData().write(to: stock.appendingPathComponent("print.lut3d"))
        let manifest: [String: Any] = [
            "schema": 2, "id": "toy", "displayName": "Toy", "status": "synthetic", "boxSpeed": 400, "densityRange": 2.5,
            "negative": ["file": "negative.cube", "binary": "negative.lut3d", "size": 2,
                         "logEncoding": ["stopsBelowMidGray": 8, "stopsAboveMidGray": 5, "midGray": 0.18]],
            "print": ["file": "print.cube", "binary": "print.lut3d", "size": 2, "exposurePerUnit": [0.8, 0.8, 0.8]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: stock.appendingPathComponent(Stock.manifestName))
        return stocks
    }

    /// Runs `body` with a temporary folder and a model whose toy stock is in its Stocks and whose
    /// recipes and decisions are in its Library. The folder goes once the model's balance and decision
    /// writes are done, so a decision kept as `body` ends is not written into it after it has gone.
    private func withLibraryModel(_ name: String, _ body: (URL, RollModel) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("Library", isDirectory: true)
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: try toyStocks(in: folder), decisions: AutoDecisionStore(library: library),
                              flagStore: FlagStore(library: library), recipeLibrary: library,
                              previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        var failure: (any Error)?
        do { try await body(folder, model) } catch { failure = error }
        // A measurement under way when the test ends still balances the roll and saves its decision.
        model.analysisTask?.cancel()
        await model.analysisTask?.value
        while true {
            let balance = model.balanceTask, save = model.decisionSave
            await balance?.value
            await save?.value
            if model.balanceTask == balance, model.decisionSave == save { break }
        }
        model.clearManualSession()
        if let failure { throw failure }
    }

    /// A raw replaced and then put back, as DSC04059 was (smoke test, 2026-10-22), is again the raw
    /// its held edit was pinned on: the edit is the frame's own again, saved as one, and Develop does
    /// not ask for it to be reapplied. Nor does an untouched copy of the roll that a build before
    /// this fix left the edit held for, through the journal they share.
    @Test func aRawPutBackGetsBackTheEditItsReplacementHeld() async throws {
        try await withLibraryModel("held-edit") { folder, model in
            let roll = folder.appendingPathComponent("Roll"), copy = folder.appendingPathComponent("Copy")
            let library = folder.appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            let raw = roll.appendingPathComponent("DSC1.ARW")
            try header(raw)
            await model.open(roll)
            if let restore = model.manualRestoreTask { await restore.value }
            let frame = try #require(model.selectedFrame)
            let original = try Data(contentsOf: raw)
            let sha = try SourceDigests.shared.digest(of: raw).sha256
            let aim = PrintAim(level: -0.65, cast: SIMD3(0.2, -0.1, 0.15))
            let pin = AutomaticBaseline(sourceSHA256: sha, stockID: "test", stockDigest: "digest",
                controls: .init(), aim: aim, analysisVersion: ExposureAnalysis.currentVersion,
                baseRender: Recipe.Render(settings: DevelopSettings(labBalance: SIMD3(0.1, 0.2, 0.3)), grain: .off))
            let edit = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5), baseline: pin)
            model.manualEdits[frame.url] = edit
            model.saveManualFrame(frame)
            try await model.flushManualSaves()

            try header(raw, iso: 6400)
            #expect(model.forgetChangedSources())
            try await model.flushManualSaves()
            #expect(model.heldManualEdits[frame.url] == edit && model.manualIssueRequiresReapply(for: frame))

            try original.write(to: raw, options: .atomic)
            #expect(model.forgetChangedSources())
            try await model.flushManualSaves()
            #expect(model.manualEdits[frame.url] == edit)
            #expect(model.heldManualEdits[frame.url] == nil)
            #expect(model.manualIssue(for: frame) == nil)
            let saved = try #require(try await RecipeWriter.shared.load(for: frame, library: library))
            #expect(saved.manual == edit && saved.heldManual == nil)

            // What the build before this fix saved on the put-back: the edit held on its own bytes. An
            // untouched copy of the roll, its sidecar of the same lineage and older, opens to that record.
            try FileManager.default.copyItem(at: roll, to: copy)
            let stock = try #require(model.currentStock)
            var held = try Recipe.make(frame: frame, byteCount: original.count, stock: stock, stockDigest: stock.digest,
                roll: RollControls(), own: FrameControls(), aim: aim, previous: saved, manual: nil,
                editRevision: (saved.editRevision ?? 0) + 1, editLineage: saved.editLineage, heldManual: edit)
            held.raw.sha256 = sha
            _ = try await RecipeWriter.shared.commit(recipe: held, for: frame, library: library)
            await model.open(copy)
            if let restore = model.manualRestoreTask { await restore.value }
            let copied = try #require(model.roll?.frames.first)
            #expect(copied.url.deletingLastPathComponent().lastPathComponent == "Copy")
            #expect(model.manualEdits[copied.url] == edit)
            #expect(model.heldManualEdits[copied.url] == nil)
            #expect(model.manualIssue(for: copied) == nil)
        }
    }

    /// An edit of +`exposure` EV pinned on the raw at `url` as it is now.
    private func edit(_ exposure: Float, on url: URL) throws -> ManualEdit {
        let pin = AutomaticBaseline(sourceSHA256: try SourceDigests.shared.digest(of: url).sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65, cast: SIMD3(0.2, -0.1, 0.15)), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(labBalance: SIMD3(0.1, 0.2, 0.3)), grain: .off))
        return ManualEdit(adjustments: try ManualAdjustments(exposureEV: exposure), baseline: pin)
    }

    private func reopen(_ model: RollModel, _ roll: URL) async {
        await model.open(roll)
        if let restore = model.manualRestoreTask { await restore.value }
    }

    /// A roll whose last frame is a twin, a copy of another of its frames, opens with the roll's
    /// lineage, not the twin's; a frame of it whose RAW is touched saves, and keeps its edit.
    @Test func aTwinsLineageIsNotTheRollsAndTouchedFramesStillSave() async throws {
        try await withLibraryModel("twin-lineage") { folder, model in
            let roll = folder.appendingPathComponent("Roll")
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            try header(roll.appendingPathComponent("DSC0.ARW"), iso: 100)
            try header(roll.appendingPathComponent("DSC1.ARW"), iso: 200)
            try header(roll.appendingPathComponent("DSC2.ARW"), iso: 200)
            await reopen(model, roll)
            let frames = try #require(model.roll?.frames)
            #expect(frames.map(\.name) == ["DSC0", "DSC1", "DSC2"])
            for (index, frame) in frames.enumerated() {
                model.manualEdits[frame.url] = try edit(0.5 + Float(index) / 10, on: frame.url)
                model.saveManualFrame(frame)
                try await model.flushManualSaves()
            }
            let lineage = try #require(model.manualRecipes[frames[0].url]?.editLineage)
            #expect(model.manualRecipes[frames[2].url]?.editLineage != lineage)

            await reopen(model, roll)
            #expect(model.editLineage == lineage)
            let touched = frames[0], kept = model.manualEdits[frames[0].url]
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: touched.url.path)
            #expect(model.forgetChangedSources())
            try await model.flushManualSaves()
            #expect(model.manualEdits[touched.url] == kept && model.heldManualEdits[touched.url] == nil)
            #expect(model.manualIssue(for: touched) == nil)
        }
    }

    /// A RAW replaced while the app is closed, in a roll where it alone has a recipe, its held edit
    /// saved, and put back while the app is closed again: it opens with its edit, not asking for Reapply.
    @Test func aRawPutBackWhileTheAppWasClosedOpensWithItsEdit() async throws {
        try await withLibraryModel("closed-put-back") { folder, model in
            let roll = folder.appendingPathComponent("Roll"), elsewhere = folder.appendingPathComponent("Elsewhere")
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let raw = roll.appendingPathComponent("DSC1.ARW")
            try header(raw)
            try header(roll.appendingPathComponent("DSC2.ARW"), iso: 400)
            try header(elsewhere.appendingPathComponent("OTHER.ARW"), iso: 800)
            await reopen(model, roll)
            let frame = try #require(model.roll?.frames.first { $0.url.lastPathComponent == "DSC1.ARW" })
            let original = try Data(contentsOf: raw), kept = try edit(0.5, on: raw)
            model.manualEdits[frame.url] = kept
            model.saveManualFrame(frame)
            try await model.flushManualSaves()

            await reopen(model, elsewhere)
            try header(raw, iso: 6400)
            await reopen(model, roll)
            #expect(model.heldManualEdits[frame.url] == kept)
            model.controls = RollControls(labBalance: .warm)
            try await model.flushManualSaves()

            await reopen(model, elsewhere)
            try original.write(to: raw, options: .atomic)
            await reopen(model, roll)
            #expect(model.manualEdits[frame.url] == kept)
            #expect(model.heldManualEdits[frame.url] == nil && model.manualIssue(for: frame) == nil)
        }
    }

    /// Retry saves again only what failed: a frame whose recipe could not be read is not saved over it.
    @Test func retrySavesOnlyTheFramesWhoseSavesFailed() async throws {
        try await withLibraryModel("retry") { folder, model in
            let roll = folder.appendingPathComponent("Roll")
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            try header(roll.appendingPathComponent("DSC1.ARW"))
            try header(roll.appendingPathComponent("DSC2.ARW"), iso: 400)
            await reopen(model, roll)
            let frames = try #require(model.roll?.frames)
            #expect(frames.allSatisfy { model.manualLoaded.contains($0.url) })
            model.manualEdits[frames[0].url] = try edit(0.5, on: frames[0].url)
            model.manualSaveFailures[frames[0].url] = ManualSaveFailure(revision: 1, message: "fixture failure")
            model.manualSaveFailed = true
            model.retryManualSave()
            #expect(model.manualSaveTasks[frames[0].url] != nil)
            #expect(model.manualSaveTasks[frames[1].url] == nil)
            try await model.flushManualSaves()
        }
    }

    /// A locked card edited, another card later edited at the same mount path and file name, and
    /// the first card back: it opens with its own edit, as the journal alone keeps it.
    @Test func aLockedCardOpensWithItsEditAfterAnotherCardAtItsPath() async throws {
        try await withLibraryModel("card") { folder, model in
            let card = folder.appendingPathComponent("Untitled/DCIM/100MSDCF"), elsewhere = folder.appendingPathComponent("Elsewhere")
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: card.path) }
            try header(elsewhere.appendingPathComponent("OTHER.ARW"), iso: 3200)
            let raw = card.appendingPathComponent("DSC00001.ARW")
            @MainActor func insert(iso: UInt16) throws {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: card.path)
                try header(raw, iso: iso)
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: card.path)
            }
            try insert(iso: 100)
            await reopen(model, card)
            var frame = try #require(model.roll?.frames.first)
            let first = try edit(0.5, on: raw)
            model.manualEdits[frame.url] = first
            model.saveManualFrame(frame)
            try await model.flushManualSaves()
            #expect(!FileManager.default.fileExists(atPath: RecipeStore.besideRaw(raw).path))
            await reopen(model, elsewhere)

            try insert(iso: 800)
            await reopen(model, card)
            frame = try #require(model.roll?.frames.first)
            #expect(model.manualEdits[frame.url] == nil && model.heldManualEdits[frame.url] == nil)
            model.manualEdits[frame.url] = try edit(-0.4, on: raw)
            model.saveManualFrame(frame)
            try await model.flushManualSaves()
            await reopen(model, elsewhere)

            try insert(iso: 100)
            await reopen(model, card)
            frame = try #require(model.roll?.frames.first)
            #expect(model.manualEdits[frame.url] == first && model.manualIssue(for: frame) == nil)
        }
    }

    /// Locks the journal folder of `frame`'s raw in the model's library, so a save of it fails until
    /// `unlock`, and saves `edit` to the frame: the failed save stays with the recipe writer.
    private func failSave(of frame: Frame, _ edit: ManualEdit, in model: RollModel) async throws -> URL {
        let sha = try SourceDigests.shared.digest(of: frame.url).sha256
        let journals = RecipeWriter.journalURL(sha256: sha, lineage: "locked", library: model.recipeLibrary).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: journals.path)
        model.manualEdits[frame.url] = edit
        model.saveManualFrame(frame)
        await model.manualSaveTasks[frame.url]?.value
        #expect(model.manualSaveFailed)
        return journals
    }

    private func unlock(_ journals: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journals.path)
    }

    /// Opening another roll while an adjustment cannot be saved asks first, as the alert does: Keep
    /// Current Roll Open keeps the roll and its failed save for a later flush, Retry saves again and
    /// opens once it can, and Open Without Saving opens the other roll and lets the failed save go.
    @Test(arguments: [UnsavedAdjustments.Answer.keep, .retry, .discard])
    func openingAnotherRollWithUnsavedAdjustmentsAsksFirst(_ answer: UnsavedAdjustments.Answer) async throws {
        try await withLibraryModel("unsaved") { folder, model in
            let roll = folder.appendingPathComponent("Roll"), other = folder.appendingPathComponent("Other")
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try header(roll.appendingPathComponent("DSC1.ARW"))
            try header(other.appendingPathComponent("DSC2.ARW"), iso: 400)
            await reopen(model, roll)
            let frame = try #require(model.roll?.frames.first), kept = try edit(0.5, on: frame.url)
            let journals = try await failSave(of: frame, kept, in: model)
            defer { unlock(journals) }

            var asked: [UnsavedAdjustments] = []
            model.askAboutUnsavedAdjustments = { unsaved in
                asked.append(unsaved)
                // Retry once the journal can be written; asked again, the test has failed, and keeps the roll.
                if answer == .retry, asked.count == 1 { self.unlock(journals) }
                return asked.count == 1 ? answer : .keep
            }
            await reopen(model, other)
            #expect(asked.count == 1)
            #expect(asked.first.map { [$0.keep, $0.discard] } == ["Keep Current Roll Open", "Open Without Saving"])
            #expect(model.roll?.folder.canonicalPath == (answer == .keep ? roll : other).canonicalPath)

            unlock(journals)
            if answer == .keep {
                #expect(model.manualSaveFailed)
                try await model.flushManualSaves()
                #expect(!model.manualSaveFailed)
            } else {
                #expect(try await RecipeWriter.shared.flush(library: model.recipeLibrary).isEmpty)
            }
            let saved = try await RecipeWriter.shared.load(for: frame, library: model.recipeLibrary)
            #expect(saved?.manual == (answer == .discard ? nil : kept))
        }
    }

    /// Quitting while an adjustment cannot be saved asks first, as the alert does: Keep Open keeps the app
    /// open, with its roll and its failed save for a later flush, Retry saves again and quits once it can,
    /// and Quit Without Saving quits with the save not made.
    @Test(arguments: [UnsavedAdjustments.Answer.keep, .retry, .discard])
    func quittingWithUnsavedAdjustmentsAsksFirst(_ answer: UnsavedAdjustments.Answer) async throws {
        try await withLibraryModel("quit-unsaved") { folder, model in
            let roll = folder.appendingPathComponent("Roll")
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            try header(roll.appendingPathComponent("DSC1.ARW"))
            await reopen(model, roll)
            let frame = try #require(model.roll?.frames.first), kept = try edit(0.5, on: frame.url)
            let journals = try await failSave(of: frame, kept, in: model)
            defer { unlock(journals) }

            var asked: [UnsavedAdjustments] = []
            model.askAboutUnsavedAdjustments = { unsaved in
                asked.append(unsaved)
                // Retry once the journal can be written; asked again, the test has failed, and keeps the app open.
                if answer == .retry, asked.count == 1 { self.unlock(journals) }
                return asked.count == 1 ? answer : .keep
            }
            // As the app's delegate quits.
            model.isQuitting = true
            await model.finishWritesForQuit()
            let quits = await model.saveAdjustmentsForQuit()
            #expect(asked.count == 1)
            #expect(asked.first.map { [$0.keep, $0.discard] } == ["Keep Open", "Quit Without Saving"])
            #expect(quits == (answer != .keep))
            #expect(model.isQuitting == (answer != .keep))
            #expect(model.roll?.folder.canonicalPath == roll.canonicalPath)

            unlock(journals)
            switch answer {
            case .keep:
                #expect(model.manualSaveFailed)
                try await model.flushManualSaves()
                #expect(!model.manualSaveFailed)
            case .retry:
                #expect(!model.manualSaveFailed)
            case .discard:
                // The failed save goes with the app's process, as it ends.
                #expect(model.manualSaveFailed)
                await RecipeWriter.shared.discardPending(for: [frame], library: model.recipeLibrary)
            }
            let saved = try await RecipeWriter.shared.load(for: frame, library: model.recipeLibrary)
            #expect(saved?.manual == (answer == .discard ? nil : kept))
        }
    }

    /// A test that leaves the alert to the model stops there, as no test can answer it, rather than
    /// waiting for ever.
    @Test(.enabled(if: ProcessInfo.isRunningTests))
    func theAlertStopsATestThatLeftItUnanswered() async throws {
        let stop = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = await UnsavedAdjustments.alert(UnsavedAdjustments(error: CocoaError(.fileWriteNoPermission), keep: "Keep Open",
                                                                  discard: "Quit Without Saving"))
        }
        let said = String(decoding: try #require(stop).standardErrorContent, as: UTF8.self)
        #expect(said.contains("A test reached the unsaved adjustments alert"), "\(said)")
    }

    /// A model's flush is its own library's: another model's failed save, in a library of its own,
    /// neither fails this model's saves and opens nor is saved by them, as the App suites' models each
    /// keep their own library side by side.
    @Test func aModelsFlushLeavesAnotherLibrarysFailedSave() async throws {
        try await withLibraryModel("flush-theirs") { theirFolder, theirs in
            try await withLibraryModel("flush-mine") { folder, model in
                let theirRoll = theirFolder.appendingPathComponent("Roll"), roll = folder.appendingPathComponent("Roll")
                let other = folder.appendingPathComponent("Other")
                for (place, iso) in [(theirRoll, UInt16(100)), (roll, 200), (other, 400)] {
                    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                    try header(place.appendingPathComponent("DSC1.ARW"), iso: iso)
                }
                await reopen(theirs, theirRoll)
                let theirFrame = try #require(theirs.roll?.frames.first), theirEdit = try edit(0.5, on: theirFrame.url)
                let journals = try await failSave(of: theirFrame, theirEdit, in: theirs)
                defer { unlock(journals) }

                var asked = 0
                model.askAboutUnsavedAdjustments = { _ in
                    asked += 1
                    return .keep
                }
                await reopen(model, roll)
                let frame = try #require(model.roll?.frames.first), mine = try edit(-0.4, on: frame.url)
                model.manualEdits[frame.url] = mine
                model.saveManualFrame(frame)
                try await model.flushManualSaves()
                await reopen(model, other)
                #expect(asked == 0 && model.roll?.folder.canonicalPath == other.canonicalPath)
                #expect(try await RecipeWriter.shared.load(for: frame, library: model.recipeLibrary)?.manual == mine)
                #expect(theirs.manualSaveFailed)

                unlock(journals)
                try await theirs.flushManualSaves()
                #expect(!theirs.manualSaveFailed)
                #expect(try await RecipeWriter.shared.load(for: theirFrame, library: theirs.recipeLibrary)?.manual == theirEdit)
            }
        }
    }

    @Test func newRollClearsSessionUndoAndManualPins() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.manualUndoManager?.beginUndoGrouping()
        model.resetManualAdjustments(for: frame)
        model.manualUndoManager?.endUndoGrouping()
        #expect(model.manualUndoManager?.canUndo == true)
        model.clearManualSession()
        #expect(model.manualUndoManager?.canUndo == false)
        #expect(model.manualEdits.isEmpty)
        #expect(model.heldManualEdits.isEmpty)
    }
}
