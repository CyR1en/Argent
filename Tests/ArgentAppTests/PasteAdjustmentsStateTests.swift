import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// A smart-mask engine whose Sky this build cannot make, as a build without DA3 and EoMT: the other kinds answer as the session's
/// fake engine does.
final class SkylessSmartEngine: SmartMaskEngine, @unchecked Sendable {
    static let reason = "Sky needs the sky and water models, and this build of Argent was made without them."
    let lock = NSLock()
    var finds: [SmartKind] = []

    func availability(of kind: SmartKind) -> SmartAvailability { kind == .sky ? .unavailable(Self.reason) : .available }
    var pins: SmartModelPins { SmartModelPins() }
    func picture(of frame: Frame, lens: LensSettings, stopped: @escaping @Sendable () -> Bool) async -> SmartPictureHandle? { SmartPictureHandle(frame: frame.url, content: 0) }
    func find(_ kind: SmartKind, on picture: SmartPictureHandle, frame: Frame, sourceSHA256: String,
              stage: @escaping @Sendable (SmartStage) -> Void) async throws -> (SmartResult, MaskFrame) {
        lock.withLock { finds.append(kind) }
        return (.seed(SessionSmartEngine.seed(kind)), SessionSmartEngine.maskFrame)
    }
    func unloadSky() async -> Bool { false }
    func releasePictures() {}
}

/// Copy and Paste Adjustments (docs/context-menus-plan.md, section 2): each rule of the contract on a roll of eight frames on the
/// toy stock, every frame measured and the roll settled, with a library of its own, an undo manager of its own and a fake smart-mask
/// engine. Edits are made as a photographer makes them, from Auto once it is on screen, so each pin is a real one.
@MainActor @Suite(.serialized) struct PasteAdjustmentsStateTests {
    struct Opened {
        let model: RollModel
        let gate: MeasurementGate
        let frames: [Frame]
        let engine: SessionSmartEngine
    }

    /// Opens the fixture's roll, lets every measurement through and waits for the roll to settle.
    private func open(_ fixture: AutoDecisionStateTests.Fixture) async throws -> Opened {
        let model = fixture.model(), gate = MeasurementGate()
        try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
        let frames = try #require(model.roll?.frames)
        gate.openAll(frames)
        _ = try #require(await model.settledDecision())
        let engine = SessionSmartEngine()
        model.smartMasks.inference = MaskInference(engine: engine, turns: DecodeTurns())
        model.askAboutUnsavableAdjustments = { _ in .proceed }
        return Opened(model: model, gate: gate, frames: frames, engine: engine)
    }

    /// The undo manager the steps after setting up go to, grouped by hand as `ManualStateTests` groups them.
    private func undoable(_ model: RollModel) {
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
    }

    /// A step of the test's own, grouped by hand.
    private func step(_ model: RollModel, _ change: () throws -> Void) rethrows {
        model.manualUndoManager?.beginUndoGrouping()
        defer { model.manualUndoManager?.endUndoGrouping() }
        try change()
    }

    /// Gives `frame` `values` as a photographer would: from Auto once it is on screen, or from its Original.
    private func edit(_ model: RollModel, _ frame: Frame, _ values: ManualAdjustments, origin: AutomaticBaseline.Origin = .auto,
                      notes: MaskNotes = .none) async throws {
        await model.prepareManualAdjustments(for: frame)
        let stock = model.stockIndex
        model.recordVisibleAutomatic(for: frame, stock: stock, aim: model.printAim(for: frame), settings: model.settings(for: frame, stock: stock))
        if origin == .original { model.startFromOriginal(for: frame) }
        model.setManualAdjustments(values, for: frame)
        if notes != .none { model.manualEdits[frame.url]?.maskNotes = notes }
        try #require(model.manualAdjustments(for: frame) == values && model.startingPoint(for: frame) == origin)
    }

    /// Paste Adjustments on `frame`, waited for.
    @discardableResult
    private func paste(_ model: RollModel, to frame: Frame, _ parts: AdjustmentParts = .all) async throws -> PasteReport {
        let before = model.pasteTask
        model.pasteAdjustments(to: frame, parts: parts)
        try #require(model.pasteTask != before, "the paste did not start")
        return try #require(await model.pasteTask?.value)
    }

    @discardableResult
    private func pasteToShown(_ model: RollModel, _ parts: AdjustmentParts = .all) async throws -> PasteReport {
        let before = model.pasteTask
        model.pasteAdjustmentsToShownFrames(parts: parts)
        try #require(model.pasteTask != before, "the paste did not start")
        return try #require(await model.pasteTask?.value)
    }

    private func gradient(_ y: Float = 0, exposure: Float = -0.7) throws -> Mask {
        Mask(components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: y), zero: MaskPoint(x: 0.5, y: y + 0.5))))],
             adjustments: try ManualAdjustments(exposureEV: exposure))
    }

    private func named(_ masks: [Mask], _ names: [String]) -> MaskNotes {
        MaskNotes(names: Dictionary(uniqueKeysWithValues: zip(masks.map(\.id.uuidString), names)))
    }

    private func names(_ model: RollModel, _ frame: Frame) -> [String] {
        model.masks(for: frame).map { model.maskName($0.id, for: frame) }
    }

    private func expectedPaste(_ mask: Mask, on frame: Frame, model: RollModel) throws -> Mask {
        try MaskSet(masks: [mask]).forAnotherPicture(freshIDs: false,
            geometry: model.maskLens(for: frame, settings: model.lensSettings(for: frame))?.picture).masks[0]
    }

    private func lightValues(_ values: ManualAdjustments) -> [Float] { ManualAdjustments.Control.allCases.map { values.value(for: $0) } }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static let picture = try! MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)

    /// A Follow edges stroke whose measured shape is stored in the model's library, in a mask of its own.
    private func followedMask(_ model: RollModel) async throws -> (Mask, RasterRef) {
        let shape = try await model.storeMaskSeed(try MaskRaster(width: 40, height: 24, plane: (0..<960).map { UInt8($0 % 251) }))
        let stroke = BrushStroke(followEdges: true, radius: 0.02, flow: 0.8,
                                 points: try PackedPoints.pack([MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.25, y: 0.21)]),
                                 measured: try MeasuredStroke(raster: shape, x: 300, y: 200, pictureWidth: 7008, pictureHeight: 4672))
        return (Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: Self.picture, strokes: [stroke])))],
                     adjustments: try ManualAdjustments(exposureEV: 0.4)), shape)
    }

    /// A second roll beside the fixture's, of the same names, so the gate measures it as it does the first, opened in `model` and
    /// settled.
    private func openSecondRoll(_ fixture: AutoDecisionStateTests.Fixture, in opened: Opened) async throws -> [Frame] {
        let folder = fixture.folder.appendingPathComponent("Roll B")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in AutoDecisionStateTests.names.indices {
            try writeSequenceHeader(folder.appendingPathComponent(AutoDecisionStateTests.names[index]),
                                    captured: AutoDecisionStateTests.captured(index), tail: Data(UUID().uuidString.utf8))
        }
        await opened.model.open(folder)
        if let restoration = opened.model.manualRestoreTask { await restoration.value }
        let frames = try #require(opened.model.roll?.frames)
        try #require(frames.first?.url.deletingLastPathComponent().lastPathComponent == "Roll B")
        opened.gate.openAll(frames)
        _ = try #require(await opened.model.settledDecision())
        return frames
    }

    // MARK: Rule 1: a new edit that replaces

    /// The frame's Light, Curve and masks become the copied ones, a part the source left untouched resetting the frame's, and its own
    /// Rated at and Lab balance become the source's, following the roll where the source did.
    @Test func pasteReplacesAndResetsWhatTheSourceLeftUntouched() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            let light = try ManualAdjustments(exposureEV: 0.7, contrast: 10, shadows: 20)
            try await edit(model, source, light)
            model.setRatedAt(.oneStopOver, for: source)
            let set = try MaskSet(masks: [try gradient()])
            try await edit(model, frame, try ManualAdjustments(exposureEV: -0.4, highlights: -30,
                                                               curves: try ToneCurves(tone: ToneCurves.Preset.strongContrast.curve), masks: set))
            model.setLabBalance(.warm, for: frame)
            undoable(model)

            model.copyAdjustments(from: source)
            #expect(model.adjustmentsClipboard?.parts == [.light, .frameControls])
            let report = try await paste(model, to: frame)
            #expect(report.pasted == [frame.url] && report.skipped.isEmpty)
            #expect(model.manualAdjustments(for: frame) == light, "Light the source's, curves and masks reset")
            #expect(model.frameControls(frame) == FrameControls(ratedAt: .oneStopOver), "Rated at the source's, Lab balance the roll's")
            #expect(model.controls(for: frame) == model.controls(for: source))

            // A source with nothing but its own Rated at: the frame's edit goes, and its pin with it, as Reset to Current Auto lets it go.
            step(model) { model.resetManualAdjustments(for: source) }
            model.copyAdjustments(from: source)
            try await paste(model, to: frame)
            #expect(model.manualEdits[frame.url] == nil && !model.hasManualAdjustments(frame))
            #expect(model.frameControls(frame) == FrameControls(ratedAt: .oneStopOver))
        }
    }

    // MARK: Rule 5: Paste Only

    /// Each part alone: it replaces that part and keeps the frame's others, its pin and its compiler. Rated At and Lab Balance
    /// carries those two alone and leaves the frame's own stock and grain; Film Stock and Grain carries those and leaves the others.
    @Test(arguments: AdjustmentParts.each)
    func eachPartAloneKeepsTheOthersAndThePin(part: AdjustmentParts) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            try AutoDecisionStateTests.writeToyStock("alternate", in: fixture.stocks)
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            let theirs = try gradient(0.1), ours = try gradient(0.3, exposure: 1)
            // The frame's curves on the first curve compiler, which a change by hand keeps.
            let soft = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)
            let strong = try ToneCurves(tone: ToneCurves.Preset.strongContrast.curve, version: "2026-10-09-curves-1")
            let given = try Presence([.clarity: 30, .dehaze: 15]), kept = try Presence([.texture: -20])
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7, shadows: 20, curves: soft, masks: try MaskSet(masks: [theirs]),
                                                                presence: given, lens: LensSettings(arguments: "distortion-amount=150")), notes: named([theirs], ["Theirs"]))
            model.setRatedAt(.oneStopOver, for: source)
            let grain: OutputSettings.Grain = model.output.grain == .natural ? .off : .natural
            model.setGrain(grain, for: source)
            try await edit(model, frame, try ManualAdjustments(exposureEV: -0.4, highlights: -30, curves: strong, masks: try MaskSet(masks: [ours]),
                                                               presence: kept, lens: LensSettings(arguments: "distortion=off")), notes: named([ours], ["Ours"]))
            model.setLabBalance(.warm, for: frame)
            let other = try #require(model.films?.stocks.indices.first { $0 != model.stockIndex })
            model.setStock(other, for: frame)
            let otherID = try #require(model.films?.stocks[other].id)
            let before = try #require(model.manualEdits[frame.url]), ownBefore = model.frameControls(frame)
            #expect(ownBefore == FrameControls(labBalance: .warm, stock: otherID))
            undoable(model)

            model.copyAdjustments(from: source)
            #expect(model.canPasteAdjustments(to: frame, parts: part))
            try await paste(model, to: frame, part)
            let after = try #require(model.manualEdits[frame.url])
            #expect(after.baseline == before.baseline && after.curveVersion == before.curveVersion, "the frame's pin and compiler kept")
            let values = after.adjustments
            #expect(lightValues(values) == (part == .light ? [0.7, 0, 0, 20, 0, 0] : lightValues(before.adjustments)))
            #expect(values.curves.tone == (part == .curve ? soft.tone : strong.tone) && values.curves.version == strong.version)
            #expect(values.presence == (part == .presence ? given : kept))
            #expect(values.lens == (part == .lens ? model.manualAdjustments(for: source).lens : before.adjustments.lens))
            if part == .masks {
                let expected = try expectedPaste(theirs, on: frame, model: model)
                #expect(values.masks.count == 1 && values.masks.masks[0].id != theirs.id && values.masks.masks[0].coverage == expected.coverage)
                #expect(names(model, frame) == ["Theirs"])
            } else {
                #expect(values.masks == before.adjustments.masks && names(model, frame) == ["Ours"])
            }
            #expect(model.frameControls(frame) == (part == .frameControls ? FrameControls(ratedAt: .oneStopOver, stock: otherID)
                                                   : part == .film ? FrameControls(labBalance: .warm, grain: grain) : ownBefore))
            #expect(model.manualUndoManager?.undoActionName == "Paste Adjustments")
        }
    }

    /// Paste Only keeps an older Light compiler, as a slider moved by hand keeps it; Paste Adjustments, a new edit, takes the current.
    @Test func pasteOnlyKeepsAnOlderLightCompiler() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7, curves: try ToneCurves(tone: ToneCurves.Preset.softContrast.curve)))
            try await edit(model, frame, try ManualAdjustments(exposureEV: -0.4, highlights: -30))
            model.manualEdits[frame.url]?.curveVersion = ManualRenderSettings.exposedBaseVersion
            let pin = try #require(model.manualEdits[frame.url]?.baseline)
            model.copyAdjustments(from: source)
            for part in [AdjustmentParts.light, .curve] {
                try await paste(model, to: frame, part)
                #expect(model.manualEdits[frame.url]?.curveVersion == ManualRenderSettings.exposedBaseVersion)
                #expect(model.manualEdits[frame.url]?.baseline == pin)
            }
            #expect(model.manualAdjustments(for: frame) == model.manualAdjustments(for: source))
            try await paste(model, to: frame)
            #expect(model.manualEdits[frame.url]?.curveVersion == ManualRenderSettings.currentVersion)
        }
    }

    /// Presence is a part of its own: a source with Presence alone offers Presence and not Light, Paste Only ▸ Presence replaces
    /// the frame's five and keeps its Light, and Paste Adjustments gives the frame the source's Presence, none where the source has
    /// none, so the two frames end with the same settings.
    @Test func presenceIsAPartOfItsOwn() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1], plain = roll.frames[2]
            let given = try Presence([.clarity: 30, .vibrance: 15])
            try await edit(model, source, try ManualAdjustments(presence: given))
            try await edit(model, frame, try ManualAdjustments(shadows: 10, presence: try Presence([.texture: -20, .saturation: 40])))
            try await edit(model, plain, try ManualAdjustments(exposureEV: 0.7))
            let pin = try #require(model.manualEdits[frame.url]?.baseline)
            undoable(model)

            model.copyAdjustments(from: source)
            #expect(model.adjustmentsClipboard?.parts == [.presence])
            #expect(!model.canPasteAdjustments(to: frame, parts: .light) && model.canPasteAdjustments(to: frame, parts: .presence))
            try await paste(model, to: frame, .presence)
            #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(shadows: 10, presence: given)))
            #expect(model.manualEdits[frame.url]?.baseline == pin)

            model.copyAdjustments(from: plain)
            #expect(model.adjustmentsClipboard?.parts == [.light])
            try await paste(model, to: frame)
            #expect(model.manualAdjustments(for: frame) == model.manualAdjustments(for: plain), "the frame's Presence reset")
        }
    }

    /// Paste Only ▸ Presence keeps the frame's constants, as a slider moved by hand keeps them, and a paste that pins anew takes the
    /// current ones. This build has one constants version, so the source's is one another build recorded: its values arrive at the
    /// frame's version, and the frame still renders.
    @Test func pasteOnlyPresenceKeepsTheFramesConstants() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1], fresh = roll.frames[2]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7))
            let recorded = try JSONDecoder().decode(Presence.self, from: Data(
                #"{"version": "2026-12-01-1", "texture": 0, "clarity": 30, "dehaze": 0, "vibrance": 0, "saturation": -10}"#.utf8))
            model.manualEdits[source.url]?.adjustments = try ManualAdjustments(exposureEV: 0.7, presence: recorded)
            try await edit(model, frame, try ManualAdjustments(highlights: -20, presence: try Presence([.texture: -20])))
            let version = try #require(model.manualEdits[frame.url]?.adjustments.presence.version)
            model.copyAdjustments(from: source)

            try await paste(model, to: frame, .presence)
            let values = try Presence([.clarity: 30, .saturation: -10])
            #expect(model.manualAdjustments(for: frame) == (try ManualAdjustments(highlights: -20, presence: values)))
            #expect(model.manualAdjustments(for: frame).presence.version == version)
            try model.settings(for: frame, stock: model.stockIndex).manual.validateSupportedVersion()

            try await paste(model, to: fresh)
            #expect(model.manualAdjustments(for: fresh) == (try ManualAdjustments(exposureEV: 0.7, presence: values)))
            #expect(model.manualAdjustments(for: fresh).presence.version == Presence.currentVersion)
            try model.settings(for: fresh, stock: model.stockIndex).manual.validateSupportedVersion()
        }
    }

    /// On a frame with no edit, Paste Only pins as Paste Adjustments does, at the current compilers; Rated at and Lab balance alone
    /// need no pin and make no edit.
    @Test func pasteOnlyOnAFrameWithNoEditPinsItsOwnAuto() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[2], other = roll.frames[3]
            let old = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve, version: "2026-10-09-curves-1")
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7, curves: old))
            model.setLabBalance(.cool, for: source)
            model.copyAdjustments(from: source)

            try await paste(model, to: frame, .curve)
            let edit = try #require(model.manualEdits[frame.url])
            let verified = try SourceDigests.shared.digest(of: frame.url)
            #expect(edit.baseline.origin == .auto && edit.baseline.aim == model.printAim(for: frame))
            #expect(edit.baseline.sourceSHA256 == verified.sha256 && edit.baseline.controls == model.controls(for: frame))
            #expect(edit.curveVersion == ManualRenderSettings.currentVersion && edit.adjustments.curves.version == ToneCurves.currentVersion)
            #expect(edit.adjustments.curves.tone == old.tone && lightValues(edit.adjustments) == [0, 0, 0, 0, 0, 0])

            try await paste(model, to: other, .frameControls)
            #expect(model.manualEdits[other.url] == nil && model.frameControls(other) == FrameControls(labBalance: .cool))
        }
    }

    /// Light carries its starting point: an Original's Light makes the frame an Original, at the neutral aim, keeping its curves; the
    /// Curve alone does not.
    @Test func lightCarriesTheOriginal() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1], plain = roll.frames[2], whole = roll.frames[3]
            let soft = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve), strong = try ToneCurves(tone: ToneCurves.Preset.strongContrast.curve)
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.5, curves: soft), origin: .original)
            try await edit(model, frame, try ManualAdjustments(highlights: -20, curves: strong))
            let before = try #require(model.manualEdits[frame.url])
            model.copyAdjustments(from: source)
            #expect(model.adjustmentsClipboard?.origin == .original)

            try await paste(model, to: frame, .light)
            let edit = try #require(model.manualEdits[frame.url])
            #expect(edit.baseline.origin == .original && edit.baseline.aim == PrintAim() && edit.baseline != before.baseline)
            #expect(lightValues(edit.adjustments) == [0.5, 0, 0, 0, 0, 0] && edit.adjustments.curves == strong)

            try await paste(model, to: plain, .curve)
            #expect(model.startingPoint(for: plain) == .auto && model.manualAdjustments(for: plain).curves == soft)
            try await paste(model, to: whole)
            #expect(model.startingPoint(for: whole) == .original && model.manualAdjustments(for: whole) == model.manualAdjustments(for: source))

            // An Original with every value at zero is still a choice, and Light alone carries it.
            model.startFromOriginal(for: source, actionName: "Reset to Original")
            model.copyAdjustments(from: source)
            #expect(model.adjustmentsClipboard?.parts == [.light])
            let fresh = roll.frames[4]
            try await paste(model, to: fresh, .light)
            #expect(model.startingPoint(for: fresh) == .original && model.manualAdjustments(for: fresh).isIdentity)
        }
    }

    /// Rule 5's compiler: an edit on `2026-10-29-1` whose masks would change a pixel is left out and told why; one where they would
    /// not moves to the current compiler; `2026-10-09-1` is left out.
    @Test func masksOnAnOlderCompilerFollowTheGate() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], moving = roll.frames[1], held = roll.frames[2], regions = roll.frames[3]
            try await edit(model, source, try ManualAdjustments(masks: try MaskSet(masks: [try gradient()])))
            try await edit(model, moving, try ManualAdjustments(highlights: -20))
            try await edit(model, held, try ManualAdjustments(exposureEV: 0.5, highlights: -20))
            try await edit(model, regions, try ManualAdjustments(shadows: 10))
            model.manualEdits[moving.url]?.curveVersion = ManualRenderSettings.exposedBaseVersion
            model.manualEdits[held.url]?.curveVersion = ManualRenderSettings.exposedBaseVersion
            model.manualEdits[regions.url]?.curveVersion = ManualRenderSettings.regionsVersion
            let heldBefore = model.manualEdits[held.url], regionsBefore = model.manualEdits[regions.url]
            let pinBefore = model.manualEdits[moving.url]?.baseline
            model.copyAdjustments(from: source)

            let report = try await pasteToShown(model, .masks)
            #expect(Set(report.skipped.map(\.frame)) == [held.url, regions.url])
            #expect(report.skipped.allSatisfy { $0.why.contains("Update Automatic Baseline") })
            #expect(model.manualEdits[held.url] == heldBefore && model.manualEdits[regions.url] == regionsBefore)
            let moved = try #require(model.manualEdits[moving.url])
            #expect(moved.curveVersion == ManualRenderSettings.currentVersion && moved.baseline == pinBefore && moved.adjustments.masks.count == 1)
            #expect(model.clipboardNotice?.text == "Pasted to 5 of 7 frames" && model.clipboardNotice?.details.count == 2)
        }
    }

    // MARK: Rules 2 and 3: each frame's own pin, the current compilers

    /// Each destination pins its own settled aim and raw, never the source's, and one that had a pin is pinned anew. The paste takes
    /// the current compilers, and the source keeps its own.
    @Test func eachFramePinsItsOwnAimAtTheCurrentCompilers() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], pinned = roll.frames[1]
            let old = try ToneCurves(tone: ToneCurves.Preset.softContrast.curve, version: "2026-10-09-curves-1")
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7, shadows: 20, curves: old))
            model.manualEdits[source.url]?.curveVersion = ManualRenderSettings.exposedBaseVersion
            let sourceEdit = try #require(model.manualEdits[source.url])
            try await edit(model, pinned, try ManualAdjustments(blacks: -10))
            // A pin taken of an aim the roll has left since.
            model.manualEdits[pinned.url]?.baseline.aim = PrintAim(level: 2.5)
            model.copyAdjustments(from: source)

            let report = try await pasteToShown(model)
            #expect(report.pasted.count == 7 && report.skipped.isEmpty)
            var aims = Set<[UInt32]>()
            for frame in roll.frames.dropFirst() {
                let edit = try #require(model.manualEdits[frame.url])
                #expect(edit.baseline.aim == model.printAim(for: frame) && edit.baseline.aim != PrintAim(level: 2.5))
                #expect(edit.baseline.sourceSHA256 == (try SourceDigests.shared.digest(of: frame.url)).sha256)
                #expect(edit.baseline.sourceSHA256 != sourceEdit.baseline.sourceSHA256)
                #expect(edit.baseline.resolverVersion == DevelopmentResolver.currentVersion)
                #expect(edit.curveVersion == ManualRenderSettings.currentVersion && edit.adjustments.curves.version == ToneCurves.currentVersion)
                #expect(edit.adjustments.curves.tone == old.tone && lightValues(edit.adjustments) == [0.7, 0, 0, 20, 0, 0])
                aims.insert(AutoDecisionStateTests.bits(edit.baseline.aim))
            }
            #expect(aims.count > 1, "the frames' aims are their own")
            #expect(model.manualEdits[source.url] == sourceEdit, "the source is not migrated")
        }
    }

    // MARK: Rule 4: masks as another picture takes them

    /// Fresh ids, names kept, placed shapes and a Follow edges stroke's shape kept, a smart selection cleared and asked for again on
    /// the frame, where it lands as the frame's own.
    @Test func masksGoAsAnotherPictureTakesThem() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            let seed = try await model.storeMaskSeed(SessionSmartEngine.seed(.sky, value: 200).raster)
            let line = try gradient()
            let sky = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: seed, frame: Self.picture)))],
                           adjustments: try ManualAdjustments(exposureEV: -0.7))
            let (painted, shape) = try await followedMask(model)
            var notes = named([line, sky, painted], ["Gradient", "Sky", "Edges"])
            notes.rasters[seed.id.hex] = SessionSmartEngine.provenance(.sky)
            try await edit(model, source, try ManualAdjustments(masks: try MaskSet(masks: [line, sky, painted])), notes: notes)
            let sourceEdit = try #require(model.manualEdits[source.url])
            undoable(model)
            roll.engine.holds = true

            model.copyAdjustments(from: source)
            try await paste(model, to: frame)
            let masks = model.masks(for: frame)
            #expect(masks.count == 3 && Set(masks.map(\.id)).isDisjoint(with: [line.id, sky.id, painted.id]))
            #expect(names(model, frame) == ["Gradient", "Sky", "Edges"])
            let expectedLine = try expectedPaste(line, on: frame, model: model)
            let expectedPainted = try expectedPaste(painted, on: frame, model: model)
            #expect(masks[0].coverage == expectedLine.coverage && masks[2].components == expectedPainted.components)
            #expect(model.manualAdjustments(for: frame).masks.rasters == [shape] && model.maskSeedStore.contains(shape.id))
            #expect(masks[1].pendingSmart == [.sky] && model.manualEdits[frame.url]?.maskNotes.rasters.isEmpty == true, "no seed travels")
            #expect(model.smartStatus(of: masks[1], for: frame) == .working(.queued, kind: .sky, update: false)
                    || model.smartStatus(of: masks[1], for: frame) == .working(.finding, kind: .sky, update: false))
            // The previews leave it out while it is found.
            #expect(RollModel.printable(model.manualEdits[frame.url])?.adjustments.masks.masks[1].isEnabled == false)
            try await waitFor { roll.engine.heldCount == 1 }
            roll.engine.release()
            await model.waitForSelections(on: [frame.url])
            let found = try #require(model.mask(masks[1].id, for: frame)?.components.first)
            guard case .smart(let selection) = found.shape else { Issue.record("not a selection"); return }
            #expect(selection.raster != nil && selection.raster != seed, "the frame's own selection")
            #expect(model.manualEdits[source.url] == sourceEdit, "the source keeps its seed")
            #expect(roll.engine.finds == [.sky])
            try await model.flushManualSaves()
        }
    }

    /// No edit may name a raster its store does not hold: a Follow edges stroke whose shape the library has lost goes as it was
    /// painted, unless the pack beside the source's raw gives it back. Across rolls the library is the same, so the shape goes with
    /// it; lost there, with the source's roll out of reach, the stroke goes as painted.
    @Test func aStrokeTheStoreCannotGiveGoesAsPainted() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], store = model.maskSeedStore
            let (painted, shape) = try await followedMask(model)
            try await edit(model, source, try ManualAdjustments(masks: try MaskSet(masks: [painted])))
            model.copyAdjustments(from: source)
            @MainActor func stroke(_ frame: Frame) throws -> BrushStroke {
                let component = try #require(model.masks(for: frame).first?.components.first)
                guard case .brush(let paint) = component.shape, let stroke = paint.strokes.first else { throw CancellationError() }
                return stroke
            }

            // Within the roll: the library has lost it, and the pack beside the source's raw holds it.
            try store.writePack([shape], to: RecipeStore.masksBesideRaw(source.url))
            try FileManager.default.removeItem(at: store.url(for: shape.id))
            try await paste(model, to: roll.frames[1])
            #expect(try stroke(roll.frames[1]).measured?.raster == shape && store.contains(shape.id))
            // Lost from both: as painted, and the frame names nothing its store lacks.
            try FileManager.default.removeItem(at: store.url(for: shape.id))
            try FileManager.default.removeItem(at: RecipeStore.masksBesideRaw(source.url))
            try await paste(model, to: roll.frames[2])
            let lost = try stroke(roll.frames[2]), kept = try stroke(roll.frames[1])
            #expect(lost.measured == nil && !lost.followEdges && lost.points == kept.points && lost.radius == kept.radius)
            #expect(model.manualAdjustments(for: roll.frames[2]).masks.rasters.isEmpty && model.maskSeedIssue(for: roll.frames[2]) == nil)

            // Across rolls: the shape back in the library, the clipboard taken to another roll.
            _ = try store.store(try MaskRaster(width: 40, height: 24, plane: (0..<960).map { UInt8($0 % 251) }))
            model.copyAdjustments(from: source)
            model.manualEdits[roll.frames[1].url] = nil
            model.manualEdits[roll.frames[2].url] = nil
            model.manualEdits[source.url] = nil
            let other = try await openSecondRoll(fixture, in: roll)
            try await paste(model, to: other[1])
            #expect(try stroke(other[1]).measured?.raster == shape && model.maskSeedIssue(for: other[1]) == nil)
            try FileManager.default.removeItem(at: store.url(for: shape.id))
            try await paste(model, to: other[2])
            #expect(try stroke(other[2]).measured == nil && model.manualAdjustments(for: other[2]).masks.rasters.isEmpty)
            try await model.flushManualSaves()
            // The frame given the stroke as painted saves; the one whose shape this test took from the library cannot.
            #expect(model.maskSeedUnsaved == [other[1].url])
        }
    }

    // MARK: Rule 6: one undo step

    /// One frame's paste is one step, "Paste Adjustments": its Undo puts back the edit, the pin and the frame's own Rated at and Lab
    /// balance, and selects and opens the frame; Redo pastes again.
    @Test func oneFramesPasteIsOneStepThatOpensTheFrame() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7))
            model.setRatedAt(.oneStopOver, for: source)
            try await edit(model, frame, try ManualAdjustments(highlights: -40, masks: try MaskSet(masks: [try gradient()])))
            model.setLabBalance(.warm, for: frame)
            let before = model.pasteUndoState(for: frame)
            model.selection = roll.frames[5].id
            model.closeFrame()
            undoable(model)

            model.copyAdjustments(from: source)
            try await paste(model, to: frame)
            let after = model.pasteUndoState(for: frame)
            #expect(after != before && model.manualUndoManager?.undoActionName == "Paste Adjustments")
            #expect(model.selection == roll.frames[5].id && !model.isFrameOpen, "the paste moves nothing")
            model.manualUndoManager?.undo()
            #expect(model.pasteUndoState(for: frame) == before)
            #expect(model.selection == frame.id && model.isFrameOpen)
            #expect(model.manualUndoManager?.canUndo == false, "one step")
            model.manualUndoManager?.redo()
            #expect(model.pasteUndoState(for: frame) == after)
            #expect(model.manualUndoManager?.undoActionName == "Paste Adjustments")
        }
    }

    /// A batch is one step, "Paste Adjustments to 7 Frames", whose Undo restores every frame, their pins and their own Rated at and
    /// Lab balance included, and moves neither the selection nor the page.
    @Test func aBatchIsOneStepThatMovesNothing() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], targets = Array(roll.frames.dropFirst())
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7, shadows: 15))
            model.setLabBalance(.cool, for: source)
            try await edit(model, roll.frames[2], try ManualAdjustments(whites: 20))
            model.setRatedAt(.oneStopUnder, for: roll.frames[2])
            model.setLabBalance(.warm, for: roll.frames[4])
            let before = targets.map(model.pasteUndoState(for:))
            model.selection = roll.frames[3].id
            model.openFrame()
            undoable(model)

            model.copyAdjustments(from: source)
            #expect(model.pasteTargets.map(\.url) == targets.map(\.url) && model.pasteToShownTitle == "Paste to All Frames")
            let report = try await pasteToShown(model)
            #expect(report.pasted.count == 7)
            let after = targets.map(model.pasteUndoState(for:))
            #expect(targets.allSatisfy { model.frameControls($0) == FrameControls(labBalance: .cool) })
            #expect(model.manualUndoManager?.undoActionName == "Paste Adjustments to 7 Frames")
            #expect(model.clipboardNotice?.text == "Pasted adjustments to 7 frames" && model.clipboardNotice?.offersUndo == true)
            model.selection = roll.frames[6].id
            model.closeFrame()
            model.manualUndoManager?.undo()
            #expect(targets.map(model.pasteUndoState(for:)) == before)
            #expect(model.selection == roll.frames[6].id && !model.isFrameOpen, "neither the selection nor the page moves")
            #expect(model.manualUndoManager?.canUndo == false, "one step")
            model.manualUndoManager?.redo()
            #expect(targets.map(model.pasteUndoState(for:)) == after)
            #expect(model.selection == roll.frames[6].id && !model.isFrameOpen)

            // The filter chooses the frames, and the title follows it.
            model.manualUndoManager?.undo()
            step(model) {
                for flagged in [roll.frames[2], roll.frames[5], source] { model.setFlag(true, for: flagged) }
            }
            model.flagFilter = .flagged
            #expect(model.pasteTargets.map(\.url) == [roll.frames[2].url, roll.frames[5].url] && model.pasteToShownTitle == "Paste to Flagged Frames")
            let flagged = try await pasteToShown(model)
            #expect(flagged.pasted == [roll.frames[2].url, roll.frames[5].url])
            #expect(model.manualUndoManager?.undoActionName == "Paste Adjustments to 2 Frames")
            #expect(model.pasteUndoState(for: roll.frames[3]) == before[2], "a frame the filter leaves out is left alone")
        }
    }

    /// The notice offers Undo while the paste is the next step: the next step, or an Undo, takes the offer away; the notice's own
    /// Undo takes the paste back.
    @Test func theNoticeOffersUndoWhileThePasteIsNext() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7))
            undoable(model)
            model.copyAdjustments(from: source)
            #expect(model.clipboardNotice == ClipboardNotice(kind: .copied, text: "Copied adjustments from \(source.name)"))

            @MainActor func copy(_ exposure: Float) throws {
                try step(model) { model.setManualAdjustments(try ManualAdjustments(exposureEV: exposure), for: source) }
                model.copyAdjustments(from: source)
            }

            try await paste(model, to: frame)
            #expect(model.clipboardNotice == ClipboardNotice(kind: .pasted(frames: 1, skipped: 0), text: "Pasted adjustments to \(frame.name)",
                                                             offersUndo: true))
            let first = model.pasteUndoState(for: frame)
            try copy(0.2)
            #expect(model.clipboardNotice?.kind == .copied && model.clipboardNotice?.offersUndo == false)

            try await paste(model, to: frame)
            #expect(model.clipboardNotice?.offersUndo == true)
            try step(model) { model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.3), for: source) }
            #expect(model.clipboardNotice?.offersUndo == false, "another step came after it")
            model.manualUndoManager?.undo()

            #expect(model.manualUndoManager?.undoActionName == "Paste Adjustments")
            model.manualUndoManager?.undo()
            #expect(model.pasteUndoState(for: frame) == first)
            model.manualUndoManager?.redo()
            let second = model.pasteUndoState(for: frame)
            #expect(second != first)

            try copy(-0.3)
            try await paste(model, to: frame)
            #expect(model.clipboardNotice?.offersUndo == true)
            model.manualUndoManager?.undo()
            #expect(model.clipboardNotice?.offersUndo == false, "undone by Command-Z")
            model.manualUndoManager?.redo()
            #expect(model.clipboardNotice?.offersUndo == false, "a redo does not offer it again")

            try copy(0.9)
            try await paste(model, to: frame)
            let third = model.pasteUndoState(for: frame)
            #expect(third != second && model.clipboardNotice?.offersUndo == true)
            model.undoPasteFromNotice()
            #expect(model.clipboardNotice == nil && model.manualAdjustments(for: frame).exposureEV == -0.3)
            let undone = model.pasteUndoState(for: frame)
            model.undoPasteFromNotice()
            #expect(model.pasteUndoState(for: frame) == undone, "nothing offered, nothing undone")
        }
    }

    /// A smart selection a paste asked for is cancelled by its Undo, and asked for again by its Redo.
    @Test func undoCancelsTheSelectionsAPasteAskedFor() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            let seed = try await model.storeMaskSeed(SessionSmartEngine.seed(.person).raster)
            let person = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .person, raster: seed, frame: Self.picture)))])
            try await edit(model, source, try ManualAdjustments(masks: try MaskSet(masks: [person])))
            undoable(model)
            roll.engine.holds = true
            model.copyAdjustments(from: source)

            try await paste(model, to: frame)
            let id = try #require(model.masks(for: frame).first?.id)
            #expect(model.smartMasks.run(.init(frame: frame.url, mask: id)) != nil)
            try await waitFor { roll.engine.heldCount == 1 }
            model.manualUndoManager?.undo()
            #expect(model.masks(for: frame).isEmpty && model.smartMasks.runs.isEmpty, "undo cancels it")
            roll.engine.release()
            await model.waitForSelections(on: [frame.url])
            model.manualUndoManager?.redo()
            #expect(model.mask(id, for: frame)?.pendingSmart == [.person] && model.smartMasks.run(.init(frame: frame.url, mask: id)) != nil,
                    "redo asks again")
            try await waitFor { roll.engine.heldCount == 1 }
            roll.engine.release()
            await model.waitForSelections(on: [frame.url])
            #expect(model.mask(id, for: frame)?.pendingSmart.isEmpty == true && roll.engine.finds == [.person, .person])
        }
    }

    /// A batch keeps DA3 loaded while its Sky selections run, one after another, and lets it go once they have landed: the queue
    /// keeps the model rather than loading it for each frame.
    @Test func aBatchKeepsTheSkyModelUntilItsSelectionsLand() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0]
            let seed = try await model.storeMaskSeed(SessionSmartEngine.seed(.sky).raster)
            let sky = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: seed, frame: Self.picture)))])
            try await edit(model, source, try ManualAdjustments(masks: try MaskSet(masks: [sky])))
            roll.engine.holds = true
            model.copyAdjustments(from: source)
            let queue = try #require(model.smartMasks.queue)
            #expect(!queue.isTabOpen)

            try await pasteToShown(model)
            #expect(queue.isTabOpen, "held while the batch's selections run")
            #expect(model.smartMasks.runs.count == 7)
            for landed in 1...7 {
                try await waitFor { roll.engine.heldCount == 1 }
                #expect(queue.isTabOpen)
                roll.engine.release()
                try await waitFor { roll.engine.finds.count == landed && roll.engine.heldCount == 0 }
            }
            await model.waitForSelections(on: roll.frames.map(\.url))
            try await waitFor { !queue.isTabOpen }
            #expect(queue.statistics.runs == 7 && roll.frames.dropFirst().allSatisfy { model.masks(for: $0).first?.pendingSmart.isEmpty == true })
            try await model.flushManualSaves()
        }
    }

    /// Where this build cannot make a kind, its pasted mask's row says so, as the kind's tile does, and nothing is asked.
    @Test func aKindThisBuildCannotMakeSaysSoInItsRow() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            let seed = try await model.storeMaskSeed(SessionSmartEngine.seed(.sky).raster)
            let sky = Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: seed, frame: Self.picture)))])
            try await edit(model, source, try ManualAdjustments(masks: try MaskSet(masks: [sky])))
            let engine = SkylessSmartEngine()
            model.smartMasks.inference = MaskInference(engine: engine, turns: DecodeTurns())
            model.copyAdjustments(from: source)

            try await paste(model, to: frame)
            let mask = try #require(model.masks(for: frame).first)
            #expect(mask.pendingSmart == [.sky])
            let status = try #require(model.smartStatus(of: mask, for: frame))
            #expect(status == .failed(.sky, why: SkylessSmartEngine.reason) && status.detail == SkylessSmartEngine.reason)
            model.retrySelection(mask.id, for: frame)
            #expect(model.smartStatus(of: mask, for: frame) == status && engine.finds.isEmpty && model.smartMasks.queue?.isTabOpen == false)
        }
    }

    // MARK: Rule 7: the frames shown, those left out counted

    /// A frame that cannot take it is left as it was and counted: a held edit, an issue, a recipe unread. The notice names each
    /// with why, and says the same to VoiceOver.
    @Test func framesThatCannotTakeItAreLeftOutAndCounted() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0]
            let held = roll.frames[2], troubled = roll.frames[3], unread = roll.frames[5]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7))
            try await edit(model, held, try ManualAdjustments(whites: 20))
            model.holdManualForChangedSource(held.url)
            model.manualErrors[troubled.url] = "Something is wrong with this edit."
            // A sidecar beside the raw that cannot be read, as a share can fail to for a moment: its saved adjustments are unknown.
            model.manualLoaded.remove(unread.url)
            let sidecar = RecipeStore.besideRaw(unread.url)
            try Data("{}".utf8).write(to: sidecar)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sidecar.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path) }
            let before = [held, troubled, unread].map(model.pasteUndoState(for:))
            model.copyAdjustments(from: source)

            let report = try await pasteToShown(model)
            #expect(report.pasted.count == 4 && report.skipped.map(\.frame) == [held.url, troubled.url, unread.url])
            #expect([held, troubled, unread].map(model.pasteUndoState(for:)) == before, "left as they were")
            #expect(!model.manualLoaded.contains(unread.url) && report.skipped[2].why.hasPrefix("Could not read the saved adjustments"))
            #expect(report.skipped[0].why.contains("Reapply") && report.skipped[1].why == "Something is wrong with this edit.")
            let notice = try #require(model.clipboardNotice)
            #expect(notice.kind == .pasted(frames: 4, skipped: 3) && notice.text == "Pasted to 4 of 7 frames" && notice.offersUndo)
            #expect(notice.details.count == 3 && notice.details[0].hasPrefix(held.name + ": "))
        }
    }

    /// While frames are made ready the notice counts them; a paste asked for meanwhile goes after it.
    @Test func theNoticeCountsWhileFramesAreMadeReady() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7))
            model.copyAdjustments(from: source)
            let (wait, go) = AsyncStream<Void>.makeStream()
            model.pasteTask = Task { for await _ in wait { break }; return nil }
            model.pasteAdjustmentsToShownFrames()
            #expect(model.clipboardNotice == ClipboardNotice(kind: .pasting(done: 0, of: 7), text: "Pasting adjustments… 0 of 7"))
            model.pasteAdjustments(to: roll.frames[1], parts: .light)
            let last = model.pasteTask
            go.finish()
            let report = try #require(await last?.value)
            #expect(report.pasted == [roll.frames[1].url], "the second paste went after the first")
            #expect(roll.frames.dropFirst().allSatisfy { model.manualAdjustments(for: $0).exposureEV == 0.7 })
        }
    }

    // MARK: Rule 8: never during a scan, a quit or a restore; a gesture ends first

    #if DEBUG
    @Test func nothingIsPastedDuringAScanAQuitOrARestore() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7))
            model.copyAdjustments(from: source)
            @MainActor func refuses() {
                let task = model.pasteTask, notice = model.clipboardNotice
                #expect(!model.canPasteAdjustments(to: frame) && !model.canPasteToShownFrames)
                model.pasteAdjustments(to: frame)
                model.pasteAdjustmentsToShownFrames()
                #expect(model.pasteTask == task && model.manualEdits[frame.url] == nil && model.clipboardNotice == notice)
            }
            model.isQuitting = true
            refuses()
            model.isQuitting = false
            model.isRestoringManual = true
            refuses()
            model.isRestoringManual = false

            // A paste waiting for its frames when the app begins to quit writes nothing.
            let (wait, go) = AsyncStream<Void>.makeStream()
            model.pasteTask = Task { for await _ in wait { break }; return nil }
            model.pasteAdjustments(to: frame)
            let waiting = model.pasteTask
            model.isQuitting = true
            go.finish()
            #expect(await waiting?.value == nil)
            #expect(model.manualEdits[frame.url] == nil && model.clipboardNotice?.kind == .failed)
            model.isQuitting = false

            // Nor when the roll's session ends under it.
            let (hold, release) = AsyncStream<Void>.makeStream()
            model.pasteTask = Task { for await _ in hold { break }; return nil }
            model.pasteAdjustments(to: frame)
            let ended = model.pasteTask
            model.clearManualSession()
            release.finish()
            #expect(await ended?.value == nil && model.clipboardNotice == nil && model.adjustmentsClipboard != nil)

            model.holdReadingForDebug()
            refuses()
        }
    }
    #endif

    /// A gesture open on the frame ends first as its own step, so the paste neither lands inside it nor goes with its Undo.
    @Test func aGestureOpenOnTheFrameEndsFirst() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7))
            try await edit(model, frame, try ManualAdjustments(shadows: 10))
            undoable(model)
            let start = model.pasteUndoState(for: frame)
            model.copyAdjustments(from: source)
            // A slider's drag under way when ⌥⌘V comes.
            try step(model) {
                model.beginManualGesture(for: frame)
                model.setManualAdjustments(try ManualAdjustments(shadows: 30), for: frame)
                model.pasteAdjustments(to: frame)
            }
            #expect(model.manualGestures[frame.url] == nil)
            let dragged = model.pasteUndoState(for: frame)
            _ = await model.pasteTask?.value
            #expect(model.manualAdjustments(for: frame).exposureEV == 0.7)
            model.manualUndoManager?.undo()
            #expect(model.pasteUndoState(for: frame) == dragged, "the paste's step alone")
            model.manualUndoManager?.undo()
            #expect(model.pasteUndoState(for: frame) == start, "then the gesture's")
        }
    }

    /// A Light drag begun while a paste waits continues from the pasted values and lets its printed values go when it ends.
    @Test func aLightDragBegunWhileAPasteWaitsGoesOnAfterIt() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7))
            try await edit(model, frame, try ManualAdjustments(shadows: 10))
            undoable(model)
            model.copyAdjustments(from: source)
            step(model) {
                model.pasteAdjustments(to: frame)
                model.beginLightAdjusting(for: frame)
                model.moveLight(.light(.shadows), to: 30, for: frame)
            }
            _ = await model.pasteTask?.value
            #expect(model.manualAdjustments(for: frame).exposureEV == 0.7)
            #expect(model.printedLight == nil)
            step(model) {
                model.moveLight(.light(.contrast), to: 20, for: frame)
                model.endLightAdjusting(for: frame)
            }
            #expect(model.printedLight == nil)
            #expect(model.manualGestures[frame.url] == nil)
            #expect(model.manualAdjustments(for: frame).contrast == 20)
            #expect(model.manualAdjustments(for: frame).exposureEV == 0.7)
        }
    }

    /// A Light drag under way when a paste is asked for continues from the pasted values and closes its own gesture on release.
    @Test func aLightDragUnderWayWhenAPasteIsAskedGoesOnAfterIt() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7))
            try await edit(model, frame, try ManualAdjustments(shadows: 10))
            undoable(model)
            model.copyAdjustments(from: source)
            step(model) {
                model.beginLightAdjusting(for: frame)
                model.moveLight(.light(.shadows), to: 30, for: frame)
                model.pasteAdjustments(to: frame)
            }
            _ = await model.pasteTask?.value
            step(model) {
                model.moveLight(.light(.contrast), to: 20, for: frame)
                model.endLightAdjusting(for: frame)
            }
            #expect(model.printedLight == nil)
            #expect(model.manualGestures[frame.url] == nil)
            #expect(model.manualAdjustments(for: frame).contrast == 20)
            #expect(model.manualAdjustments(for: frame).exposureEV == 0.7)
        }
    }

    // MARK: The clipboard across rolls, and on its own source

    /// The clipboard is kept across a roll switch, and pastes there on every frame shown, the source being in no roll of these.
    @Test func theClipboardSurvivesARollSwitch() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0]
            let values = try ManualAdjustments(exposureEV: 0.7, curves: try ToneCurves(tone: ToneCurves.Preset.liftedBlacks.curve))
            try await edit(model, source, values)
            model.setRatedAt(.oneStopUnder, for: source)
            model.copyAdjustments(from: source)
            let clipboard = model.adjustmentsClipboard
            try await model.flushManualSaves()

            let other = try await openSecondRoll(fixture, in: roll)
            #expect(model.adjustmentsClipboard == clipboard && model.canPasteToShownFrames)
            #expect(model.pasteTargets.count == 8)
            let report = try await pasteToShown(model)
            #expect(report.pasted.count == 8)
            #expect(other.allSatisfy { model.manualAdjustments(for: $0) == values && model.frameControls($0) == FrameControls(ratedAt: .oneStopUnder) })
        }
    }

    /// Pasted on the frame it came from, the copy gives the frame its values as they were copied, pinned again at the current
    /// compilers, in one step.
    @Test func pasteOnTheSourceItself() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0]
            let line = try gradient()
            let values = try ManualAdjustments(exposureEV: 0.7, masks: try MaskSet(masks: [line]))
            try await edit(model, source, values, notes: named([line], ["Gradient"]))
            undoable(model)
            model.copyAdjustments(from: source)
            #expect(!model.pasteTargets.contains { $0.url == source.url })
            try step(model) { model.setManualAdjustments(try ManualAdjustments(exposureEV: -1), for: source) }
            let changed = model.pasteUndoState(for: source)

            try await paste(model, to: source)
            let edit = try #require(model.manualEdits[source.url])
            let expectedLine = try expectedPaste(line, on: source, model: model)
            #expect(lightValues(edit.adjustments) == lightValues(values) && edit.adjustments.masks.masks.map(\.coverage) == [expectedLine.coverage])
            #expect(edit.adjustments.masks.masks[0].id != line.id && names(model, source) == ["Gradient"])
            #expect(edit.baseline.aim == model.printAim(for: source))
            model.manualUndoManager?.undo()
            #expect(model.pasteUndoState(for: source) == changed)
        }
    }

    // MARK: Rule 9: saved, Edited, developed again

    /// Each pasted frame saves as any edit does, its own Rated at and Lab balance with it, is marked Edited, and develops again.
    @Test func aPastedFrameIsSavedEditedAndDevelopsAgain() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let roll = try await open(fixture)
            defer { AutoDecisionStateTests.close(roll.model, roll.gate) }
            let model = roll.model, source = roll.frames[0], frame = roll.frames[1], owned = roll.frames[2]
            try await edit(model, source, try ManualAdjustments(exposureEV: 0.7, masks: try MaskSet(masks: [try gradient()])))
            model.setLabBalance(.warm, for: source)
            let stock = model.stockIndex, settings = model.settings(for: frame, stock: stock)
            model.developPhase = .done
            model.copyAdjustments(from: source)

            try await paste(model, to: frame)
            #expect(model.developPhase == .idle && model.hasManualAdjustments(frame) && model.hasFrameEdits(frame))
            #expect(model.settings(for: frame, stock: stock) != settings, "a new render, so a new develop")
            // A develop under way keeps the frames it started with (its jobs are its own snapshot): the paste leaves it running.
            model.developPhase = .developing(DevelopProgress(total: 2))
            try await paste(model, to: owned, .frameControls)
            #expect(model.developPhase == .developing(DevelopProgress(total: 2)))
            model.developPhase = .idle
            try await model.flushManualSaves()
            for pasted in [frame, owned] {
                let recipe = try #require(try await RecipeWriter.shared.load(for: pasted, library: fixture.library))
                #expect(recipe.manual == model.manualEdits[pasted.url] && recipe.frame == FrameControls(labBalance: .warm))
                #expect(model.manualRecipes[pasted.url]?.manual == model.manualEdits[pasted.url])
            }
        }
    }
}


extension PasteAdjustmentsStateTests {
    @Test func copyUsesTheSourcePictureAndPasteStampsTheDestination() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let opened = try await open(fixture), model = opened.model, source = opened.frames[0]
            let madeOn = try LensGeometry(table: RadialTable(knots: [1, 0.99, 0.96]), scale: 1)
            let destination = try LensGeometry(table: RadialTable(knots: [1, 0.98]), scale: 1.01)
            let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: false, geometry: madeOn)
            let shapes: [MaskShape] = [
                .linear(.init(full: .init(x: 0.1, y: 0.1), zero: .init(x: 0.25, y: 0.3), geometry: madeOn)),
                .radial(.init(center: .init(x: 0.2, y: 0.15), semiAxisA: 0.04, semiAxisB: 0.03, geometry: madeOn)),
                .brush(.init(frame: frame, strokes: [.init(radius: 0.02, points: try .pack([.init(x: 0.16, y: 0.15)]))])),
            ]
            let mask = Mask(components: shapes.map { .init(shape: $0) })
            try await edit(model, source, ManualAdjustments(exposureEV: 0.5).settingMasks(MaskSet(masks: [mask])))
            _ = try #require(model.films).key(source, lens: .default)
            let lens = try #require(model.maskLens(for: source, settings: .default))
            let before = model.manualEdits[source.url]
            let clipboard = model.clipboard(of: source)
            let copied = try #require(clipboard.adjustments.masks.masks.first)
            for (old, new) in zip(shapes, copied.components) {
                #expect(new.shape == old.moved(in: lens) { m, _ in m })
                #expect(new.shape.geometry == lens.picture)
            }
            #expect(copied != mask && model.manualEdits[source.url] == before)
            let pasted = try PastedMasks(masks: clipboard.adjustments.masks, notes: .none).forAnotherFrame(geometry: destination).masks
            #expect(pasted.masks[0].id != copied.id)
            for (old, new) in zip(copied.components, pasted.masks[0].components) {
                #expect(new.shape == old.shape.stamped(destination))
            }
            let noGeometry = try PastedMasks(masks: clipboard.adjustments.masks, notes: .none).forAnotherFrame(geometry: nil).masks
            #expect(noGeometry.masks[0].components.allSatisfy { $0.shape.geometry == nil })
        }
    }
}

#if DEBUG
extension PasteAdjustmentsStateTests {
    @Test(.enabled(if: hasLensGeometrySample)) func theModelsPastePathStampsTheDestinationPictureGeometry() async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let raw = fixture.raw(1).resolvingSymlinksInPath()
            try cloneLensGeometrySample(to: raw)
            let opened = try await open(fixture), model = opened.model
            let sourceFrame = opened.frames.first { $0.url.lastPathComponent == AutoDecisionStateTests.names[0] }
            let source = try #require(sourceFrame)
            let destinationFrame = opened.frames.first { $0.url.lastPathComponent == raw.lastPathComponent }
            let destination = try #require(destinationFrame)
            let mask = try gradient()
            try await edit(model, source, ManualAdjustments(exposureEV: 0.5).settingMasks(MaskSet(masks: [mask])))
            await model.prepareManualAdjustments(for: destination)
            try await edit(model, destination, model.manualAdjustments(for: destination).settingLens(LensSettings(arguments: "distortion=off")))
            _ = try #require(model.films).key(destination, lens: model.lensSettings(for: destination))
            let lens = try #require(model.maskLens(for: destination, settings: model.lensSettings(for: destination)))
            try #require(lens.picture != lens.legacy)
            model.copyAdjustments(from: source)
            let report = try await paste(model, to: destination, .masks)
            #expect(report.pasted == [destination.url])
            let pasted = try #require(model.masks(for: destination).first)
            #expect(pasted.id != mask.id)
            #expect(pasted.components[0].shape == mask.components[0].shape.stamped(lens.picture))
        }
    }
}
#endif
