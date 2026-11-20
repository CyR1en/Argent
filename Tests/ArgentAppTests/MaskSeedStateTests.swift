import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Testing
@testable import ArgentApp

/// Smart masks' seeds in the session: a lost or damaged one is an issue the frame shows while its mask stays removable, the resets that
/// return to a starting point drop seeds with their masks, and undo brings them back, their files kept while any step names them.
/// Each test has a library of its own (`recipeLibrary`), never Application Support's.
@MainActor @Suite(.serialized) struct MaskSeedStateTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    /// A roll of two frames, the first with an edit from Auto that can be adjusted, and an undo manager of its own.
    private func fixture() async throws -> (RollModel, Frame, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-seeds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        try header(folder.appendingPathComponent("DSC2.ARW"))
        let library = folder.appendingPathComponent("library", isDirectory: true)
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: library), flagStore: FlagStore(library: library),
                              recipeLibrary: library, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        let frame = try #require(model.selectedFrame)
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        model.manualEdits[frame.url] = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5), baseline: pin)
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        return (model, frame, folder)
    }

    /// A toy stock in `folder`'s Stocks, so the model's saves resolve and reach the writer.
    private func withStockModel(_ body: (URL, RollModel) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-seed-saves-\(UUID().uuidString)")
        let stock = folder.appendingPathComponent("Stocks/toy"), library = folder.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: stock, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
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
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder.appendingPathComponent("Stocks"), decisions: AutoDecisionStore(library: library),
                              flagStore: FlagStore(library: library), recipeLibrary: library,
                              previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        var failure: (any Error)?
        do { try await body(folder, model) } catch { failure = error }
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

    private func edit(_ exposure: Float, masks: MaskSet = .empty, on url: URL) throws -> ManualEdit {
        let pin = AutomaticBaseline(sourceSHA256: try SourceDigests.shared.digest(of: url).sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        return ManualEdit(adjustments: try ManualAdjustments(exposureEV: exposure, masks: masks), baseline: pin)
    }

    /// A lost seed is its frame's alone: that frame's save writes nothing and its edit waits in memory, while every other frame saves,
    /// the session's saves are not failed, and nothing stops a develop of the roll; the frame says why. With its pack put back
    /// beside the raw, the flush saves it; with its mask removed, so does the next save.
    /// A roll of two frames, each saved with Exposure +0.5, the first with a Sky mask; then the first's seed lost from the library
    /// and from beside its raw, and both frames changed and saved again: +0.8 on the first, which the writer refuses, +0.9 on the second.
    private struct LostSeed {
        let lost: Frame, kept: Frame, ref: RasterRef, pack: URL, packed: Data
    }

    private func loseASeed(in folder: URL, _ model: RollModel) async throws -> LostSeed {
        let roll = folder.appendingPathComponent("Roll")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        for (name, iso) in [("DSC1.ARW", 100), ("DSC2.ARW", 200)] {
            func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
            func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
            var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
            b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
            b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(iso) + u16(0) + u32(0)
            try Data(b).write(to: roll.appendingPathComponent(name))
        }
        await model.open(roll)
        if let restore = model.manualRestoreTask { await restore.value }
        let frames = try #require(model.roll?.frames)
        #expect(frames.count == 2)
        let lost = frames[0], kept = frames[1]
        let ref = try await model.storeMaskSeed(Self.seed)
        model.manualEdits[lost.url] = try edit(0.5, masks: try sky(ref), on: lost.url)
        model.manualEdits[kept.url] = try edit(0.5, on: kept.url)
        model.saveManualFrame(lost)
        model.saveManualFrame(kept)
        try await model.flushManualSaves()
        let pack = RecipeStore.masksBesideRaw(lost.url), packed = try Data(contentsOf: pack)
        try FileManager.default.removeItem(at: model.maskSeedStore.url(for: ref.id))
        try FileManager.default.removeItem(at: pack)
        model.manualEdits[lost.url]?.adjustments = try ManualAdjustments(exposureEV: 0.8, masks: try sky(ref))
        model.manualEdits[kept.url] = try edit(0.9, on: kept.url)
        model.saveManualFrame(lost)
        model.saveManualFrame(kept)
        try await model.flushManualSaves()
        return LostSeed(lost: lost, kept: kept, ref: ref, pack: pack, packed: packed)
    }

    private func saved(_ frame: Frame, in model: RollModel) async throws -> ManualAdjustments? {
        try await RecipeWriter.shared.load(for: frame, library: model.recipeLibrary)?.manual?.adjustments
    }

    @Test func aLostSeedHoldsUpOnlyItsOwnFrame() async throws {
        try await withStockModel { folder, model in
            let scene = try await loseASeed(in: folder, model)
            let lost = scene.lost, kept = scene.kept, ref = scene.ref, pack = scene.pack, packed = scene.packed
            let frames = [lost, kept]
            func saved(_ frame: Frame) async throws -> ManualAdjustments? { try await self.saved(frame, in: model) }
            #expect(!model.manualSaveFailed && model.manualSaveMessage == nil && model.maskSeedUnsaved == [lost.url])
            #expect(try await saved(kept)?.exposureEV == 0.9)
            #expect(try await saved(lost)?.exposureEV == 0.5, "the refused save wrote nothing")
            #expect(model.manualAdjustments(for: lost).exposureEV == 0.8, "the edit stays in memory")
            let issue = RollModel.seedIssue(.sky, damaged: false)
            #expect(model.manualIssue(for: lost) == issue && issue.contains("cannot be saved or developed"))
            #expect(model.adjustSaveStatus(for: lost) == .failed(issue) && model.adjustSaveStatus(for: kept) == .saved)
            // Nothing stops a develop of the roll: the lost frame's develop fails alone, before its decode
            // (`MaskSeedDevelopSampleTests` develops the other).
            #expect(frames.allSatisfy { model.adjustmentIssue(for: $0) == nil } && model.manualIssue(for: kept) == nil)
            // Saving the roll's choices again saves the other frame and fails no one.
            model.saveManualChoices()
            try await model.flushManualSaves()
            #expect(!model.manualSaveFailed && model.maskSeedUnsaved == [lost.url])

            // The pack put back beside the raw: the flush takes the seed from it and saves the frame.
            try packed.write(to: pack)
            try await model.flushManualSaves()
            #expect(model.maskSeedUnsaved.isEmpty && model.maskSeedStore.contains(ref.id) && model.manualIssue(for: lost) == nil)
            #expect(try await saved(lost)?.exposureEV == 0.8)

            // Lost again, then the mask removed: the frame saves without it.
            try FileManager.default.removeItem(at: model.maskSeedStore.url(for: ref.id))
            try FileManager.default.removeItem(at: pack)
            model.manualEdits[lost.url]?.adjustments = try ManualAdjustments(exposureEV: 0.7, masks: try sky(ref))
            model.saveManualFrame(lost)
            try await model.flushManualSaves()
            #expect(model.maskSeedUnsaved == [lost.url] && !model.manualSaveFailed)
            model.manualEdits[lost.url]?.adjustments = try ManualAdjustments(exposureEV: 0.7)
            model.saveManualFrame(lost)
            try await model.flushManualSaves()
            #expect(model.maskSeedUnsaved.isEmpty && model.manualIssue(for: lost) == nil)
            #expect(try await saved(lost) == (try ManualAdjustments(exposureEV: 0.7)))
        }
    }

    /// Quitting while a lost seed holds a frame's edit back asks first, as quitting with unsaved adjustments does, naming how many
    /// frames and why, and never asks to retry: Cancel keeps the app open with the edit, and once the pack is back the next quit
    /// saves it and asks nothing; Quit Anyway quits, the frame keeping its last saved record.
    @Test(arguments: [UnsavableAdjustments.Answer.cancel, .proceed])
    func quittingWithAnEditALostSeedHoldsBackAsksFirst(_ answer: UnsavableAdjustments.Answer) async throws {
        try await withStockModel { folder, model in
            let scene = try await loseASeed(in: folder, model)
            #expect(model.maskSeedUnsaved == [scene.lost.url] && !model.manualSaveFailed)
            var asked: [UnsavableAdjustments] = []
            model.askAboutUnsavedAdjustments = { unsaved in
                Issue.record("A lost seed is not a failed save: \(unsaved.error)")
                return .keep
            }
            model.askAboutUnsavableAdjustments = { unsavable in
                asked.append(unsavable)
                return asked.count == 1 ? answer : .cancel
            }
            // As the app's delegate quits.
            model.isQuitting = true
            await model.finishWritesForQuit()
            let quits = await model.saveAdjustmentsForQuit()
            #expect(asked == [UnsavableAdjustments(frames: 1, proceed: "Quit Anyway")])
            #expect(asked.first?.message == "1 frame’s adjustments cannot be saved: a mask’s seed is missing. "
                + "Remove the mask, or put its .argentmasks pack back beside the RAW.")
            #expect(quits == (answer == .proceed) && model.isQuitting == (answer == .proceed))
            #expect(model.manualAdjustments(for: scene.lost).exposureEV == 0.8, "the edit is still in memory")
            let lostSaved = try await saved(scene.lost, in: model), keptSaved = try await saved(scene.kept, in: model)
            #expect(lostSaved?.exposureEV == 0.5 && keptSaved?.exposureEV == 0.9)
            guard answer == .cancel else { return }
            // Kept open: the pack put back, the next quit saves the frame and asks nothing more.
            try scene.packed.write(to: scene.pack)
            model.isQuitting = true
            #expect(await model.saveAdjustmentsForQuit())
            #expect(asked.count == 1 && model.maskSeedUnsaved.isEmpty)
            #expect(try await saved(scene.lost, in: model)?.exposureEV == 0.8)
        }
    }

    /// A folder beside the lost seed's roll with one raw of its own, for another roll to open.
    private func otherRoll(in folder: URL) throws -> URL {
        let other = folder.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(400) + u16(0) + u32(0)
        try Data(b).write(to: other.appendingPathComponent("DSC3.ARW"))
        return other
    }

    /// Opening another roll while a lost seed holds a frame's edit back asks first, as quitting does, with "Open Anyway": Cancel keeps
    /// the roll open with the edit, and once the pack is back the next open saves it and asks nothing; Open Anyway opens the other roll,
    /// the frame keeping its last saved record. Every way to another roll (a drop, Open, Open Recent, a card) comes through `open`.
    @Test(arguments: [UnsavableAdjustments.Answer.cancel, .proceed])
    func openingAnotherRollWithAnEditALostSeedHoldsBackAsksFirst(_ answer: UnsavableAdjustments.Answer) async throws {
        try await withStockModel { folder, model in
            let scene = try await loseASeed(in: folder, model)
            let roll = folder.appendingPathComponent("Roll"), other = try otherRoll(in: folder)
            var asked: [UnsavableAdjustments] = []
            model.askAboutUnsavedAdjustments = { unsaved in
                Issue.record("A lost seed is not a failed save: \(unsaved.error)")
                return .keep
            }
            model.askAboutUnsavableAdjustments = { unsavable in
                asked.append(unsavable)
                return asked.count == 1 ? answer : .cancel
            }
            @MainActor func open(_ folder: URL) async {
                await model.open(folder)
                if let restore = model.manualRestoreTask { await restore.value }
            }
            await open(other)
            #expect(asked == [UnsavableAdjustments(frames: 1, proceed: "Open Anyway")])
            #expect(asked.first?.message.hasPrefix("1 frame’s adjustments cannot be saved: a mask’s seed is missing.") == true)
            #expect(model.roll?.folder.canonicalPath == (answer == .cancel ? roll : other).canonicalPath && !model.isScanning)
            #expect(try await saved(scene.lost, in: model)?.exposureEV == 0.5, "the refused save wrote nothing")
            guard answer == .cancel else {
                #expect(model.maskSeedUnsaved.isEmpty && model.manualEdits.isEmpty, "the other roll's session")
                return
            }
            #expect(model.manualAdjustments(for: scene.lost).exposureEV == 0.8 && model.maskSeedUnsaved == [scene.lost.url])
            // Kept open: the pack put back, the next open saves the frame first and asks nothing more.
            try scene.packed.write(to: scene.pack)
            await open(other)
            #expect(asked.count == 1 && model.roll?.folder.canonicalPath == other.canonicalPath)
            #expect(try await saved(scene.lost, in: model)?.exposureEV == 0.8)
        }
    }

    /// Open Without Saving, chosen for another frame's failed save, has already let the unsaved adjustments go: no second question.
    @Test func openWithoutSavingAsksNothingMoreAboutALostSeed() async throws {
        try await withStockModel { folder, model in
            let scene = try await loseASeed(in: folder, model)
            let other = try otherRoll(in: folder)
            let journals = RecipeWriter.journalURL(sha256: try SourceDigests.shared.digest(of: scene.kept.url).sha256, lineage: "x",
                                                   library: model.recipeLibrary).deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: journals.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journals.path) }
            model.manualEdits[scene.kept.url] = try edit(1.1, on: scene.kept.url)
            model.saveManualFrame(scene.kept)
            await model.manualSaveTasks[scene.kept.url]?.value
            #expect(model.manualSaveFailed && model.maskSeedUnsaved == [scene.lost.url])
            var unsaved = 0
            model.askAboutUnsavedAdjustments = { _ in unsaved += 1; return .discard }
            model.askAboutUnsavableAdjustments = { _ in Issue.record("asked twice"); return .cancel }
            await model.open(other)
            if let restore = model.manualRestoreTask { await restore.value }
            #expect(unsaved == 1 && model.roll?.folder.canonicalPath == other.canonicalPath)
        }
    }

    @Test func theUnsavableAlertNamesHowManyFramesAndWhy() {
        #expect(UnsavableAdjustments(frames: 3, proceed: "Quit Anyway").message == "3 frames’ adjustments cannot be saved: their masks’ "
            + "seeds are missing. Remove the masks, or put their .argentmasks packs back beside the RAWs.")
    }

    /// A test that leaves the alert to the model stops there, as no test can answer it, rather than waiting for ever.
    @Test(.enabled(if: ProcessInfo.isRunningTests))
    func theUnsavableAlertStopsATestThatLeftItUnanswered() async throws {
        let stop = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = await UnsavableAdjustments.alert(UnsavableAdjustments(frames: 1, proceed: "Quit Anyway"))
        }
        let said = String(decoding: try #require(stop).standardErrorContent, as: UTF8.self)
        #expect(said.contains("A test reached the unsavable adjustments alert"), "\(said)")
    }

    private static let seed: MaskRaster = {
        let plane: [UInt8] = (0..<(96 * 64)).map { (i: Int) -> UInt8 in UInt8(max(0, 255 - (i / 96) * 4)) }
        return try! MaskRaster(width: 96, height: 64, plane: plane)
    }()

    private func sky(_ ref: RasterRef) throws -> MaskSet {
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        return try MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: ref, frame: frame)))],
                                        adjustments: try ManualAdjustments(exposureEV: -0.7))])
    }

    private func step(_ model: RollModel, _ change: () -> Void) {
        model.manualUndoManager?.beginUndoGrouping()
        change()
        model.manualUndoManager?.endUndoGrouping()
    }

    /// A seed the library has lost is an issue on its frame, which Develop refuses (it refuses any frame with `manualIssue`); the
    /// frame can still be adjusted, so its mask can go, and with it the issue.
    @Test func aLostSeedIsAnIssueWhileItsMaskStaysRemovable() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ref = try await model.storeMaskSeed(Self.seed)
        #expect(model.maskSeedStore.folder.path.hasPrefix(model.recipeLibrary.path) && model.maskSeedStore.contains(ref.id))
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 0.5, masks: try sky(ref))
        #expect(model.manualIssue(for: frame) == nil)
        try FileManager.default.removeItem(at: model.maskSeedStore.url(for: ref.id))
        #expect(model.manualIssue(for: frame) == RollModel.seedIssue(.sky, damaged: false))
        #expect(model.manualIssue(for: frame)?.hasPrefix("A Sky mask’s selection is missing") == true)
        #expect(model.canAdjust(frame))
        step(model) { model.setManualAdjustments(model.manualAdjustments(for: frame).settingMasks(.empty), for: frame) }
        #expect(model.manualAdjustments(for: frame).masks.isEmpty && model.manualIssue(for: frame) == nil)
        // An undo brings the mask back, and the issue with it.
        model.manualUndoManager?.undo()
        #expect(model.manualIssue(for: frame) == RollModel.seedIssue(.sky, damaged: false))
    }

    /// A seed whose file holds other pixels is found when the frame's recipe is read, and is an issue until it is mended.
    @Test func aDamagedSeedIsFoundAndIsAnIssue() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ref = try await model.storeMaskSeed(Self.seed)
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(masks: try sky(ref))
        let file = model.maskSeedStore.url(for: ref.id)
        let png = try Data(contentsOf: file)
        try png.prefix(png.count - 20).write(to: file)
        await model.verifyMaskSeeds(for: frame)?.value
        #expect(model.manualIssue(for: frame) == RollModel.seedIssue(.sky, damaged: true))
        // Selected again, the same pixels mend the file and the issue goes.
        _ = try await model.storeMaskSeed(Self.seed)
        #expect(model.manualIssue(for: frame) == nil)
        await model.verifyMaskSeeds(for: frame)?.value
        #expect(model.manualIssue(for: frame) == nil && model.maskSeedDamage.isEmpty)
    }

    /// A Follow edges stroke's measured shape goes with its mask as a seed does: Reset Masks and Delete Mask take its name off the edit in one
    /// step, the file stays while an undo step names it and the undo brings the stroke back with a shape that loads; with no history left it goes.
    @Test func resetAndDeleteTakeAStrokesShapeAndUndoBringsItBack() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shape = try await model.storeMaskSeed(Self.seed), later = Date().addingTimeInterval(30 * 86_400)
        let picture = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let stroke = BrushStroke(followEdges: true, radius: 0.02, points: try PackedPoints.pack([MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.25, y: 0.21)]),
                                 measured: try MeasuredStroke(raster: shape, x: 100, y: 200, pictureWidth: 7008, pictureHeight: 4672))
        let mask = Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: picture, strokes: [stroke])))])
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 0.5, masks: try MaskSet(masks: [mask]))
        let before = try #require(model.manualEdits[frame.url])
        #expect(before.adjustments.masks.rasters == [shape])
        for (name, gesture) in [("Reset Masks", { model.resetMasks(for: frame) }), ("Delete Mask", { model.deleteMask(mask.id, for: frame) })] as [(String, () -> Void)] {
            model.manualEdits[frame.url] = before
            step(model, gesture)
            #expect(model.manualAdjustments(for: frame).masks.rasters.isEmpty, "\(name)")
            #expect(model.undoSeeds.contains(shape.id), "\(name)")
            #expect(await model.sweepMaskSeeds(now: later).removed.isEmpty && model.maskSeedStore.contains(shape.id), "\(name)")
            model.manualUndoManager?.undo()
            #expect(model.manualAdjustments(for: frame).masks.rasters == [shape], "\(name)")
            #expect(try model.maskSeedStore.load(shape) == Self.seed, "\(name)")
            #expect(model.maskSeedIssue(for: frame) == nil, "\(name)")
        }
        model.clearManualSession()
        #expect(await model.sweepMaskSeeds(now: later).removed == [shape.id.hex + ".png"])
    }

    /// Reset to Current Auto and Reset to Original take a frame's masks and their seeds' names in one step. The seeds stay on the disk:
    /// a sweep while the session lasts keeps what an undo step names, the undo brings the mask back with a seed that loads, and once
    /// the session's history is gone the sweep may remove it.
    @Test func resetsDropSeedsWithTheirMasksAndUndoKeepsTheSeedsAlive() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ref = try await model.storeMaskSeed(Self.seed), later = Date().addingTimeInterval(30 * 86_400)
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 0.5, masks: try sky(ref))
        let before = try #require(model.manualEdits[frame.url])
        step(model) { model.resetManualAdjustments(for: frame) }
        #expect(model.manualEdits[frame.url] == nil && model.undoSeeds.contains(ref.id))
        #expect(await model.sweepMaskSeeds(now: later).removed.isEmpty && model.maskSeedStore.contains(ref.id))
        model.manualUndoManager?.undo()
        #expect(model.manualEdits[frame.url] == before && model.manualIssue(for: frame) == nil)
        #expect(try model.maskSeedStore.load(ref) == Self.seed)
        model.manualUndoManager?.redo()
        #expect(model.manualEdits[frame.url] == nil)
        model.manualUndoManager?.undo()
        // An Original's Reset to Original: the same.
        model.manualEdits[frame.url]?.baseline.origin = .original
        model.manualEdits[frame.url]?.baseline.aim = PrintAim()
        step(model) { model.startFromOriginal(for: frame, actionName: "Reset to Original") }
        #expect(model.manualAdjustments(for: frame).masks.isEmpty)
        #expect(await model.sweepMaskSeeds(now: later).removed.isEmpty)
        model.manualUndoManager?.undo()
        #expect(model.manualAdjustments(for: frame).masks.rasters == [ref] && model.manualIssue(for: frame) == nil)
        // A new session has no history: nothing names the seed, and a month on it goes.
        model.clearManualSession()
        #expect(await model.sweepMaskSeeds(now: later).removed == [ref.id.hex + ".png"])
    }
}
