import AppKit
import ArgentCore
@testable import ArgentRoll
import Foundation
import Testing
import SwiftUI
@testable import ArgentApp

/// The armed tool's life: nothing stays armed behind the photographer's back, and the routing rule.
@MainActor @Suite(.serialized) struct MaskEditorStateTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    /// A roll of two frames in a library of its own, the first open.
    private func withOpenFrame(_ body: (RollModel, Frame) throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        try header(folder.appendingPathComponent("DSC2.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        // The inspector's two preferences are the test process's own: left as they were found.
        let shown = model.isAdjustmentsShown, tab = model.adjustTab
        defer { model.adjustTab = tab; model.isAdjustmentsShown = shown }
        model.selection = try #require(model.roll?.frames.first?.id)
        model.openFrame()
        model.isAdjustmentsShown = true
        try body(model, try #require(model.selectedFrame))
    }

    /// Compare's split: the neutral side shows neither the red nor the mask's effect, so a tool's new press there is not the tool's (the frame view keeps it); a
    /// press under way, a handle and a pin keep theirs wherever they are.
    @Test func theNeutralSideOfASplitIsNotATool() async throws {
        try await withBench { bench in
            let editor = bench.editor, middle = CGPoint(x: bench.geometry.picture.midX, y: bench.geometry.picture.midY)
            bench.geometry.filmEdge = middle.x
            let neutral = CGPoint(x: middle.x - 200, y: middle.y), film = CGPoint(x: middle.x + 200, y: middle.y)
            #expect(bench.geometry.toolPicture == CGRect(x: middle.x, y: 0, width: bench.geometry.picture.maxX - middle.x, height: 756))

            editor.arm(.radial)
            #expect(editor.canvasTakesPress(at: film, command: false), "the film side is the tool's")
            #expect(!editor.canvasTakesPress(at: neutral, command: false), "the neutral side is the frame view's")
            #expect(!editor.canvasTakesPress(at: CGPoint(x: middle.x - 1, y: middle.y), command: false))
            #expect(editor.canvasTakesPress(at: CGPoint(x: middle.x, y: middle.y), command: false), "the edge is the film side")

            // A press begun on the film side keeps going across the divider.
            bench.event(.press, film)
            #expect(editor.canvasTakesPress(at: neutral, command: false))
            bench.event(.release, film)
            editor.finishPress()

            // With no tool in hand, a handle on the neutral side is pressed as on the film side.
            editor.arm(.linear)
            bench.geometry.filmEdge = nil
            bench.drag(CGPoint(x: bench.geometry.picture.midX, y: bench.geometry.picture.midY - 180),
                       CGPoint(x: bench.geometry.picture.midX, y: bench.geometry.picture.midY - 60))
            let handle = MaskHandleModel.handles(of: bench.masks[0].components[0].shape, in: bench.geometry)
                .first { $0.0.movesWhole }!.1
            bench.geometry.filmEdge = handle.x + 400
            #expect(handle.x < bench.geometry.filmEdge!, "the handle stands on the neutral side")
            #expect(!editor.isArmed)
            #expect(editor.canvasTakesPress(at: handle, command: false), "a handle stays the photographer's on the neutral side")
            #expect(!editor.canvasTakesPress(at: CGPoint(x: handle.x, y: handle.y + 250), command: false), "and nothing else is")
        }
    }

    /// The canvas's ring follows the rule: on the film side with the brush, not on the neutral side, and a stroke under way keeps it over the divider.
    @Test func theRingStaysOnTheFilmSide() async throws {
        try await withBench { bench in
            let editor = bench.editor, middle = CGPoint(x: bench.geometry.picture.midX, y: bench.geometry.picture.midY)
            bench.geometry.filmEdge = middle.x
            editor.arm(.brush)
            bench.canvas.pointerMoved(to: CGPoint(x: middle.x + 100, y: middle.y))
            #expect(bench.canvas.ring.isShown)
            bench.canvas.pointerMoved(to: CGPoint(x: middle.x - 100, y: middle.y))
            #expect(!bench.canvas.ring.isShown, "no ring where a press will not paint")
            bench.canvas.pointerMoved(to: CGPoint(x: middle.x, y: middle.y))
            #expect(bench.canvas.ring.isShown)
            editor.reset()
        }
    }

    @Test func oneToolIsInHandAtATime() async throws {
        try await withOpenFrame { model, _ in
            let editor = model.maskEditor
            #expect(editor.tool == nil && !editor.isArmed)
            editor.arm(.linear)
            #expect(editor.tool == .linear && editor.isArmed)
            editor.arm(.radial)
            #expect(editor.tool == .radial)
            editor.reset()
            #expect(editor.tool == nil && !editor.isArmed)
        }
    }

    @Test func anotherTabPutsTheToolDownAndTheSameTabDoesNot() async throws {
        try await withOpenFrame { model, _ in
            model.adjustTab = .masks
            model.maskEditor.arm(.linear)
            model.adjustTab = .masks
            #expect(model.maskEditor.tool == .linear)
            model.showInspector(tab: .masks)
            #expect(model.maskEditor.tool == .linear)
            model.adjustTab = .light
            #expect(model.maskEditor.tool == nil)
            // The View menu's way, too.
            model.adjustTab = .masks
            model.maskEditor.arm(.radial)
            model.showInspector(tab: .curve)
            #expect(model.maskEditor.tool == nil)
        }
    }

    @Test func closingTheInspectorPutsTheToolDown() async throws {
        try await withOpenFrame { model, _ in
            model.maskEditor.arm(.linear)
            model.isAdjustmentsShown = true
            #expect(model.maskEditor.tool == .linear)
            model.isAdjustmentsShown = false
            #expect(model.maskEditor.tool == nil)
        }
    }

    @Test func anotherFramePutsTheToolDownAndTheSameFrameDoesNot() async throws {
        try await withOpenFrame { model, frame in
            model.maskEditor.arm(.linear)
            model.selection = frame.id
            #expect(model.maskEditor.tool == .linear)
            model.moveSelection(by: 1)
            #expect(model.selection != frame.id)
            #expect(model.maskEditor.tool == nil)
        }
    }

    @Test func leavingTheFramePutsTheToolDown() async throws {
        try await withOpenFrame { model, _ in
            model.maskEditor.arm(.linear)
            model.closeFrame()
            #expect(!model.isFrameOpen && model.maskEditor.tool == nil)
        }
    }

    @Test func anotherPagePutsTheToolDown() async throws {
        try await withOpenFrame { model, _ in
            model.maskEditor.arm(.linear)
            model.showWorkspacePage(.roll)
            #expect(model.maskEditor.tool == .linear)
            model.showWorkspacePage(.settings)
            #expect(model.maskEditor.tool == nil)
        }
    }

    @Test func escapePutsTheToolDownBeforeItLeavesTheFrame() async throws {
        try await withOpenFrame { model, _ in
            let editor = model.maskEditor
            editor.arm(.brush)
            #expect(editor.escape() && editor.tool == nil)
            // Nothing left of the masks to take it: it goes on to close the frame, as it did.
            #expect(!editor.escape())
        }
    }

    /// Escape in the name field reaches the editor, not the field, so it closes the field first and leaves the selection alone.
    @Test func escapeClosesTheNameFieldBeforeAnythingElse() async throws {
        try await withOpenFrame { model, _ in
            let editor = model.maskEditor
            let id = UUID()
            editor.selection = MaskEditor.Selection(mask: id, component: nil)
            editor.renaming = id
            #expect(editor.escape())
            #expect(editor.renaming == nil && editor.selection?.mask == id)
        }
    }

    @Test func deleteWithNoSelectionGoesOn() async throws {
        try await withOpenFrame { model, _ in
            #expect(!model.maskEditor.deleteSelection())
        }
    }

    @Test func theMenuStateFollowsTheTool() async throws {
        try await withOpenFrame { model, _ in
            #expect(model.menuState.armedMaskTool == nil && model.menuState.canMask)
            model.maskEditor.arm(.radial)
            #expect(model.menuState.armedMaskTool == .radial)
            model.maskEditor.reset()
            #expect(model.menuState.armedMaskTool == nil)
            model.closeFrame()
            #expect(!model.menuState.canMask)
        }
    }

    @Test func theMasksCommandOpensTheInspectorOnItsTab() async throws {
        try await withOpenFrame { model, frame in
            model.adjustTab = .light
            model.isAdjustmentsShown = false
            model.perform(.showMasks)
            #expect(model.isAdjustmentsShown && model.adjustTab == .masks && model.curveGraphFocusRequest == nil)
            // Only the curve graph takes the keyboard.
            model.showInspector(tab: .curve)
            #expect(model.curveGraphFocusRequest?.frame == frame.url)
            model.showInspector(tab: .light)
            #expect(model.curveGraphFocusRequest == nil)
        }
    }

    @Test func aTabKeepsAcrossLaunchesUnderItsOwnKey() async throws {
        try await withOpenFrame { model, _ in
            model.adjustTab = .light
            model.adjustTab = .masks
            #expect(UserDefaults.standard.string(forKey: AdjustInspectorTab.storageKey) == "masks")
            #expect(AdjustInspectorTab.stored() == .masks)
        }
    }

    /// The rule the canvas's hit test and `FrameView`'s two gestures share.
    @Test func thePressIsTheCanvassOnlyWithAToolOverThePictureWithoutCommand() {
        let editor = MaskEditor()
        let canvas = MaskCanvasView(editor: editor)
        // No canvas yet, or no tool: never.
        editor.arm(.linear)
        #expect(!editor.canvasTakesPress(at: CGPoint(x: 100, y: 100), command: false))
        editor.reset()
        editor.canvas = canvas
        canvas.geometry = { FrameGeometry(area: CGSize(width: 1188, height: 756), picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2) }
        let picture = CGPoint(x: 594, y: 378), surround = CGPoint(x: 10, y: 378)
        #expect(!editor.canvasTakesPress(at: picture, command: false))
        editor.arm(.linear)
        #expect(editor.canvasTakesPress(at: picture, command: false))
        #expect(!editor.canvasTakesPress(at: picture, command: true))
        #expect(!editor.canvasTakesPress(at: surround, command: false))
        #expect(!editor.canvasTakesPress(at: surround, command: true))
        // Its edges: the top left is on it, the far edges are not.
        #expect(editor.canvasTakesPress(at: CGPoint(x: 27, y: 0), command: false))
        #expect(!editor.canvasTakesPress(at: CGPoint(x: 26.9, y: 0), command: false))
        #expect(!editor.canvasTakesPress(at: CGPoint(x: 1161, y: 100), command: false))
        editor.reset()
        #expect(!editor.canvasTakesPress(at: picture, command: false))
    }

    /// A zoomed picture runs on past the area, and what is out there is not the frame view's.
    @Test func thePressStopsAtTheEdgeOfTheArea() {
        let editor = MaskEditor()
        let canvas = MaskCanvasView(editor: editor)
        editor.canvas = canvas
        canvas.geometry = { FrameGeometry(area: CGSize(width: 1188, height: 756), picture: CGRect(x: -1158, y: -790, width: 3504, height: 2336), displayScale: 2) }
        editor.arm(.radial)
        #expect(editor.canvasTakesPress(at: CGPoint(x: 594, y: 378), command: false))
        #expect(editor.canvasTakesPress(at: CGPoint(x: 0, y: 0), command: false))
        #expect(!editor.canvasTakesPress(at: CGPoint(x: 594, y: 800), command: false))
        #expect(!editor.canvasTakesPress(at: CGPoint(x: -20, y: 300), command: false))
    }

    /// The rule reads the geometry each time, so a zoom a moment ago counts before SwiftUI has drawn it.
    @Test func theRuleReadsThePictureNowNotAsItLastWas() {
        let editor = MaskEditor()
        let canvas = MaskCanvasView(editor: editor)
        editor.canvas = canvas
        final class Picture: @unchecked Sendable { var rect = CGRect(x: 27, y: 0, width: 1134, height: 756) }
        let picture = Picture()
        canvas.geometry = { FrameGeometry(area: CGSize(width: 1188, height: 756), picture: picture.rect, displayScale: 2) }
        editor.arm(.linear)
        #expect(!editor.canvasTakesPress(at: CGPoint(x: 10, y: 378), command: false))
        picture.rect = CGRect(x: -300, y: -200, width: 1752, height: 1168)
        #expect(editor.canvasTakesPress(at: CGPoint(x: 10, y: 378), command: false))
    }

    // MARK: The compiler's say

    /// Masks render only under the current Light compiler, so a first mask takes an edit there only where no
    /// pixel changes. The table is the whole rule.
    @Test func theCompilerGateTable() throws {
        let exposed = ManualRenderSettings.exposedBaseVersion, current = ManualRenderSettings.currentVersion, regions = ManualRenderSettings.regionsVersion
        let table: [(String?, ManualAdjustments, MaskCompilerGate)] = [
            (nil, .identity, .open),
            (current, .identity, .open),
            (current, try ManualAdjustments(exposureEV: 1, highlights: -50, shadows: 20), .open),
            (exposed, .identity, .movesToCurrent),
            // Exposure 0: Highlights and Shadows read the same base either way.
            (exposed, try ManualAdjustments(highlights: -50, shadows: 20), .movesToCurrent),
            (exposed, try ManualAdjustments(contrast: 30, highlights: -50, whites: 5), .movesToCurrent),
            // Highlights and Shadows both 0: nothing reads the base.
            (exposed, try ManualAdjustments(exposureEV: 1), .movesToCurrent),
            (exposed, try ManualAdjustments(exposureEV: -2, contrast: 40, whites: 10, blacks: -10), .movesToCurrent),
            // Both at once: the two compilers print different pictures.
            (exposed, try ManualAdjustments(exposureEV: 1, highlights: -50), .needsUpdate),
            (exposed, try ManualAdjustments(exposureEV: 0.01, shadows: 1), .needsUpdate),
            (exposed, try ManualAdjustments(exposureEV: -1, highlights: 10, shadows: 10), .needsUpdate),
            (regions, .identity, .needsUpdate),
            (regions, try ManualAdjustments(exposureEV: 1), .needsUpdate),
            (regions, try ManualAdjustments(highlights: -50), .needsUpdate),
            ("2020-01-01-1", .identity, .needsUpdate),
        ]
        for (version, values, gate) in table {
            #expect(MaskCompilerGate.forFirstMask(curveVersion: version, adjustments: values) == gate, "\(version ?? "none") \(values)")
        }
    }

    /// An open frame with an edit, ready to adjust, a canvas over it and a clock the test turns.
    @MainActor private final class Bench {
        let model: RollModel, frame: Frame, folder: URL, canvas: MaskCanvasView
        var geometry = FrameGeometry(area: CGSize(width: 1188, height: 756), picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2)
        var now: CFTimeInterval = 100

        init(model: RollModel, frame: Frame, folder: URL) {
            self.model = model
            self.frame = frame
            self.folder = folder
            canvas = MaskCanvasView(editor: model.maskEditor)
            model.maskEditor.canvas = canvas
            canvas.geometry = { [unowned self] in self.geometry }
            model.maskEditor.clock = { [unowned self] in self.now }
        }

        var editor: MaskEditor { model.maskEditor }
        var masks: [Mask] { model.masks(for: frame) }
        var undo: UndoManager { model.manualUndoManager! }

        func event(_ phase: MaskCanvasEvent.Phase, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            editor.canvasEvent(MaskCanvasEvent(phase: phase, fractions: geometry.normalized(point), point: point, modifiers: modifiers, clickCount: 1))
        }

        /// One whole press, as one group of the undo manager, as one event loop's turn is.
        func drag(_ from: CGPoint, _ to: CGPoint, steps: Int = 4, modifiers: NSEvent.ModifierFlags = []) {
            undo.beginUndoGrouping()
            press(from, to, steps: steps, modifiers: modifiers)
            undo.endUndoGrouping()
        }

        /// The same with no group: for a press that must register nothing at all.
        func press(_ from: CGPoint, _ to: CGPoint, steps: Int = 4, modifiers: NSEvent.ModifierFlags = []) {
            event(.press, from, modifiers: modifiers)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                now += 1
                event(.drag, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), modifiers: modifiers)
            }
            event(.release, to, modifiers: modifiers)
        }

        /// A step of the model's, as one group.
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }

        func finish() {
            canvas.teardown()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func bench(edit: (ManualEdit) throws -> ManualEdit = { $0 }) async throws -> Bench {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-mask-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        try header(folder.appendingPathComponent("DSC2.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        let frame = try #require(model.roll?.frames.first)
        model.selection = frame.id
        model.openFrame()
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65, cast: .zero), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        model.manualEdits[frame.url] = try edit(ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5), baseline: pin))
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        model.adjustTab = .masks
        model.isAdjustmentsShown = true
        return Bench(model: model, frame: frame, folder: folder)
    }

    /// The preferences the bench's model touches are the test process's own: left as they were found.
    private func withBench(edit: (ManualEdit) throws -> ManualEdit = { $0 }, _ body: (Bench) throws -> Void) async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown"), tab = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        let bench = try await bench(edit: edit)
        defer {
            bench.finish()
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(tab, forKey: AdjustInspectorTab.storageKey)
        }
        try body(bench)
    }

    private static let a = CGPoint(x: 594, y: 100), b = CGPoint(x: 594, y: 400)

    // MARK: Drawing a gradient

    /// One drag makes the mask, with no OK: selected, named, showing, its tool gone back, one undo step.
    @Test func oneDragDrawsALinearFromFullToZero() async throws {
        try await withBench { bench in
            bench.editor.arm(.linear)
            bench.drag(Self.a, Self.b)
            let mask = try #require(bench.masks.first)
            #expect(bench.masks.count == 1)
            guard case .linear(let g) = mask.components[0].shape else { Issue.record("not linear"); return }
            let full = bench.geometry.maskPoint(Self.a), zero = bench.geometry.maskPoint(Self.b)
            #expect(g.full == full && g.zero == zero)
            #expect(mask.adjustments.isIdentity && mask.amount == 1 && mask.isEnabled)
            #expect(bench.editor.tool == nil && bench.editor.selection == MaskEditor.Selection(mask: mask.id, component: nil))
            #expect(bench.editor.justPlaced && bench.editor.press == nil)
            #expect(bench.model.maskName(mask.id, for: bench.frame) == "Linear 1")
            #expect(bench.undo.undoActionName == "Add Linear Gradient")
            bench.undo.undo()
            #expect(bench.masks.isEmpty && !bench.undo.canUndo)
        }
    }

    @Test func oneDragDrawsARadialFromTheCentreOutward() async throws {
        try await withBench { bench in
            bench.editor.arm(.radial)
            bench.drag(Self.a, CGPoint(x: Self.a.x + 113.4, y: Self.a.y + 56.7))
            let mask = try #require(bench.masks.first)
            guard case .radial(let g) = mask.components[0].shape else { Issue.record("not radial"); return }
            #expect(g.center == bench.geometry.maskPoint(Self.a))
            #expect(abs(g.semiAxisA - 0.1) < 1e-4 && abs(g.semiAxisB - 0.05) < 1e-4)
            #expect(bench.undo.undoActionName == "Add Radial Gradient")
        }
    }

    @Test func aClickWithNoDragLeavesTheToolInHandAndNothingElse() async throws {
        try await withBench { bench in
            let before = bench.model.manualEdits[bench.frame.url]
            bench.editor.arm(.linear)
            bench.event(.press, Self.a)
            bench.event(.drag, CGPoint(x: Self.a.x + 1, y: Self.a.y + 1))
            bench.event(.release, CGPoint(x: Self.a.x + 1, y: Self.a.y + 1))
            #expect(bench.masks.isEmpty && bench.editor.tool == .linear && bench.editor.selection == nil)
            #expect(bench.model.manualEdits[bench.frame.url] == before && !bench.undo.canUndo)
        }
    }

    @Test func eachNewMaskTakesTheLowestNumberFree() async throws {
        try await withBench { bench in
            for tool in [MaskEditor.Tool.linear, .linear, .radial, .linear] {
                bench.editor.arm(tool)
                bench.drag(Self.a, Self.b)
            }
            #expect(bench.masks.map { bench.model.maskName($0.id, for: bench.frame) } == ["Linear 1", "Linear 2", "Radial 1", "Linear 3"])
            bench.step { bench.model.deleteMask(bench.masks[1].id, for: bench.frame) }
            bench.editor.arm(.linear)
            bench.drag(Self.a, Self.b)
            #expect(bench.masks.map { bench.model.maskName($0.id, for: bench.frame) } == ["Linear 1", "Radial 1", "Linear 3", "Linear 2"])
        }
    }

    /// While the pointer moves, the shape reaches the print about every 33 ms and the edit only on the release,
    /// which always lands: 120 events a second reach the overlay and handles, the print follows at 30 Hz, and
    /// nothing else that reads the edit (the menus, the title, the list, the sliders, the strip) moves before
    /// the release (T9: written to the edit at each flush, it relaid the window and lost a fifth of the refreshes).
    @Test func aMovingGradientReachesThePrintAtMost30TimesASecondAndTheEditOnItsRelease() async throws {
        try await withBench { bench in
            bench.editor.arm(.linear)
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.a)
            bench.event(.drag, CGPoint(x: Self.a.x, y: Self.a.y + 50))
            let drawn = bench.editor.flushCount, begun = bench.model.manualEdits[bench.frame.url]
            #expect(bench.editor.printed == nil)
            // Eight events a thirtieth of a second apart in a clock that does not move: none is flushed.
            for step in 1...8 { bench.event(.drag, CGPoint(x: Self.a.x, y: Self.a.y + 50 + CGFloat(step))) }
            #expect(bench.editor.flushCount == drawn && bench.editor.printed == nil)
            // What shows is the pointer's place all the same.
            guard case .linear(let live)? = bench.editor.shapeUnderHandles(in: bench.frame) else { Issue.record("no live shape"); return }
            #expect(live.zero == bench.geometry.maskPoint(CGPoint(x: Self.a.x, y: Self.a.y + 58)))
            guard case .linear(let saved) = bench.masks[0].components[0].shape else { Issue.record("not linear"); return }
            #expect(saved.zero != live.zero)
            bench.now += 2 * MaskEditor.flushInterval
            bench.event(.drag, CGPoint(x: Self.a.x, y: Self.a.y + 60))
            #expect(bench.editor.flushCount == drawn + 1)
            // The flush is the print's: the frame view's edit has the shape, the edit itself has not moved.
            let id = bench.masks[0].id, flushed = bench.geometry.maskPoint(CGPoint(x: Self.a.x, y: Self.a.y + 60))
            guard case .linear(let printed)? = bench.editor.printedShape(of: id, component: 0, on: bench.frame),
                  case .linear(let printedEdit)? = bench.model.printedEdit(for: bench.frame)?.adjustments.masks.masks.first?.components.first?.shape
            else { Issue.record("not printed"); return }
            #expect(printed.zero == flushed && printedEdit.zero == flushed)
            #expect(bench.model.manualEdits[bench.frame.url] == begun)
            bench.event(.release, Self.b)
            bench.undo.endUndoGrouping()
            guard case .linear(let final) = bench.masks[0].components[0].shape else { Issue.record("not linear"); return }
            #expect(final.zero == bench.geometry.maskPoint(Self.b))
            #expect(bench.editor.printed == nil && bench.model.printedEdit(for: bench.frame) == bench.model.manualEdits[bench.frame.url])
            bench.undo.undo()
            #expect(bench.masks.isEmpty && !bench.undo.canUndo)
        }
    }

    /// The App's body reads `menus`, which changes only when a menu would: each step of a slider's drag writes the
    /// edit and leaves it alone, so the window is not rebuilt for it (T9), and a change that a menu shows reaches
    /// it a turn later.
    @Test func aWriteOfTheEditThatChangesNoMenuLeavesTheMenusAlone() async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown"), tab = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        let bench = try await bench()
        defer {
            bench.finish()
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(tab, forKey: AdjustInspectorTab.storageKey)
        }
        let model = bench.model, frame = bench.frame
        func settle() async { for _ in 0..<50 where model.menus != model.menuState { await Task.yield() } }
        await settle()
        #expect(model.menus == model.menuState && model.menus.canResetManual)
        final class Changed: @unchecked Sendable { var count = 0 }
        let changed = Changed()
        withObservationTracking { _ = model.menus } onChange: { changed.count += 1 }
        bench.undo.beginUndoGrouping()
        model.beginManualGesture(for: frame)
        for step in 1...5 {
            model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.5 + Float(step) / 10), for: frame)
            await Task.yield()
        }
        model.endManualGesture(for: frame)
        bench.undo.endUndoGrouping()
        await settle()
        #expect(model.manualAdjustments(for: frame).exposureEV == 1.0)
        #expect(changed.count == 0 && model.menus == model.menuState)
        model.maskEditor.arm(.linear)
        #expect(model.menus.armedMaskTool == nil)
        await settle()
        #expect(changed.count == 1 && model.menus.armedMaskTool == .linear)
    }

    /// A handle's drag is the same: the print follows it, the edit takes it once on the release in one undo step,
    /// and Escape during it leaves the print and the edit as they were.
    @Test func aHandleDragReachesTheEditOnlyOnItsRelease() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let id = bench.masks[0].id, before = bench.model.manualEdits[bench.frame.url]
            let handles = MaskHandleModel.handles(of: bench.masks[0].components[0].shape, in: bench.geometry)
            let (_, start) = try #require(handles.first { "\($0.handle)" == "middle" })
            bench.undo.beginUndoGrouping()
            bench.event(.press, start)
            for step in 1...6 {
                bench.now += MaskEditor.flushInterval
                bench.event(.drag, CGPoint(x: start.x + 10 * CGFloat(step), y: start.y + 5 * CGFloat(step)))
            }
            #expect(bench.editor.flushCount > 0 && bench.editor.printedShape(of: id, component: 0, on: bench.frame) != nil)
            #expect(bench.model.manualEdits[bench.frame.url] == before && bench.model.printedEdit(for: bench.frame) != before)
            #expect(bench.editor.escape())
            bench.undo.endUndoGrouping()
            #expect(bench.editor.printed == nil && bench.model.manualEdits[bench.frame.url] == before)
            bench.undo.beginUndoGrouping()
            bench.event(.press, start)
            for step in 1...6 {
                bench.now += MaskEditor.flushInterval
                bench.event(.drag, CGPoint(x: start.x + 10 * CGFloat(step), y: start.y + 5 * CGFloat(step)))
            }
            #expect(bench.model.manualEdits[bench.frame.url] == before)
            bench.event(.release, CGPoint(x: start.x + 60, y: start.y + 30))
            bench.undo.endUndoGrouping()
            #expect(bench.editor.printed == nil && bench.model.manualEdits[bench.frame.url] != before)
            #expect(bench.undo.undoActionName == "Adjust Gradient")
            bench.undo.undo()
            #expect(bench.model.manualEdits[bench.frame.url] == before)
        }
    }

    /// A mask row's gesture (J): its steps reach the print alone, so nothing that reads the edit (the Masks tab, the inspector)
    /// runs for them; its end writes the edit once, the print letting go in the same turn, as one "Adjust Mask" step.
    @Test func aMaskSlidersStepsReachTheEditOnlyAtItsEnd() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let id = bench.masks[0].id, before = bench.model.manualEdits[bench.frame.url]
            bench.undo.beginUndoGrouping()
            bench.model.beginMaskAdjusting(for: bench.frame)
            for step in 1...4 { bench.model.moveMaskValue(.exposure, to: -0.25 * Float(step), mask: id, for: bench.frame) }
            bench.model.moveMaskAmount(1.5, mask: id, for: bench.frame)
            #expect(bench.model.manualEdits[bench.frame.url] == before)
            let printed = try #require(bench.model.printedEdit(for: bench.frame)?.adjustments.masks.masks.first { $0.id == id })
            #expect(printed.adjustments.exposureEV == -1 && printed.amount == 1.5)
            #expect(bench.editor.isAdjusting && bench.model.overlayComponents(for: bench.frame) == nil)
            bench.model.endMaskAdjusting(for: bench.frame)
            bench.undo.endUndoGrouping()
            #expect(bench.editor.printedValues == nil && !bench.editor.isAdjusting)
            #expect(bench.model.mask(id, for: bench.frame)?.adjustments.exposureEV == -1 && bench.model.mask(id, for: bench.frame)?.amount == 1.5)
            #expect(bench.model.printedEdit(for: bench.frame) == bench.model.manualEdits[bench.frame.url])
            #expect(bench.undo.undoActionName == "Adjust Mask")
            bench.undo.undo()
            #expect(bench.model.manualEdits[bench.frame.url] == before)
            // Outside a row's gesture (the drive hook's `mask set`), a write goes to the edit at once, as its own step.
            bench.undo.beginUndoGrouping()
            bench.model.moveMaskValue(.shadows, to: 20, mask: id, for: bench.frame)
            bench.undo.endUndoGrouping()
            #expect(bench.model.mask(id, for: bench.frame)?.adjustments.shadows == 20 && bench.editor.printedValues == nil)
        }
    }

    /// A Balance row's gesture is a Light row's: its steps reach the print alone, the edit takes them once at its end as one "Adjust Mask"
    /// step, and a Light step in the same gesture keeps what the balance moved.
    @Test func aBalanceSlidersStepsReachTheEditOnlyAtItsEnd() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let id = bench.masks[0].id, before = bench.model.manualEdits[bench.frame.url]
            bench.undo.beginUndoGrouping()
            bench.model.beginMaskAdjusting(for: bench.frame)
            for step in 1...4 { bench.model.moveMaskBalance(.warmth, to: 10 * Float(step), mask: id, for: bench.frame) }
            bench.model.moveMaskBalance(.magenta, to: -25, mask: id, for: bench.frame)
            bench.model.moveMaskValue(.exposure, to: -0.5, mask: id, for: bench.frame)
            #expect(bench.model.manualEdits[bench.frame.url] == before)
            let printed = try #require(bench.model.printedEdit(for: bench.frame)?.adjustments.masks.masks.first { $0.id == id })
            #expect(printed.balance == MaskBalance(warmth: 40, magenta: -25) && printed.adjustments.exposureEV == -0.5)
            #expect(bench.editor.isAdjusting)
            bench.model.endMaskAdjusting(for: bench.frame)
            bench.undo.endUndoGrouping()
            #expect(bench.editor.printedValues == nil && !bench.editor.isAdjusting)
            #expect(bench.model.mask(id, for: bench.frame)?.balance == MaskBalance(warmth: 40, magenta: -25))
            #expect(bench.model.mask(id, for: bench.frame)?.adjustments.exposureEV == -0.5)
            #expect(bench.model.printedEdit(for: bench.frame) == bench.model.manualEdits[bench.frame.url])
            #expect(bench.undo.undoActionName == "Adjust Mask")
            bench.undo.undo()
            #expect(bench.model.manualEdits[bench.frame.url] == before)
            // Outside a row's gesture a write goes to the edit at once, and a value past the slider's end is refused.
            bench.step {
                bench.model.moveMaskBalance(.magenta, to: 15, mask: id, for: bench.frame)
                bench.model.moveMaskBalance(.warmth, to: 101, mask: id, for: bench.frame)
            }
            #expect(bench.model.mask(id, for: bench.frame)?.balance == MaskBalance(magenta: 15) && bench.editor.printedValues == nil)
        }
    }

    /// Duplicate Mask copies everything a mask holds but its id: its switch, shape, Amount, Light and balance. It once left the balance behind.
    @Test func aDuplicateKeepsEverythingButTheID() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let id = bench.masks[0].id
            bench.step {
                bench.model.setMaskBalance(.warmth, to: 40, mask: id, for: bench.frame)
                bench.model.setMaskBalance(.magenta, to: -12, mask: id, for: bench.frame)
                bench.model.setMaskValue(.exposure, to: -1, mask: id, for: bench.frame)
                bench.model.setMaskAmount(1.5, mask: id, for: bench.frame)
            }
            bench.step { bench.model.duplicateMask(id, for: bench.frame) }
            let original = try #require(bench.masks.first), copy = try #require(bench.masks.last)
            #expect(bench.masks.count == 2 && copy.id != original.id)
            #expect(copy == original.copy(id: copy.id))
            #expect(copy.balance == MaskBalance(warmth: 40, magenta: -12) && copy.amount == 1.5 && copy.adjustments.exposureEV == -1)
            #expect(MaskSummary.line(for: copy) == MaskSummary.line(for: original))
        }
    }

    /// A shape in progress is what the overlay shows too, ahead of the edit.
    @Test func theOverlayShowsTheShapeInProgress() async throws {
        try await withBench { bench in
            bench.editor.arm(.linear)
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.a)
            bench.event(.drag, CGPoint(x: Self.a.x, y: Self.a.y + 50))
            bench.event(.drag, CGPoint(x: Self.a.x, y: Self.a.y + 80))
            guard case .linear(let shown)? = bench.model.overlayComponents(for: bench.frame)?.first?.shape else { Issue.record("not shown"); return }
            #expect(shown.zero == bench.geometry.maskPoint(CGPoint(x: Self.a.x, y: Self.a.y + 80)))
            #expect(bench.editor.isPlacing)
            bench.event(.release, CGPoint(x: Self.a.x, y: Self.a.y + 80))
            bench.undo.endUndoGrouping()
            #expect(!bench.editor.isPlacing && bench.model.overlayComponents(for: bench.frame) != nil)
        }
    }

    // MARK: Handles

    private func drawnLinear(_ bench: Bench) {
        bench.editor.arm(.linear)
        bench.drag(Self.a, Self.b)
    }

    /// With no tool in hand a handle is the canvas's and the rest of the picture is not: the frame view still
    /// pans and closes there. The same rule answers the hit test and the frame view's own gestures.
    @Test func aHandleTakesThePressWithNoToolArmedAndNothingElseDoes() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let handles = MaskHandleModel.handles(of: bench.masks[0].components[0].shape, in: bench.geometry)
            for (_, point) in handles {
                #expect(bench.editor.canvasTakesPress(at: point, command: false))
                #expect(!bench.editor.canvasTakesPress(at: point, command: true))
                #expect(bench.canvas.hitTest(point, modifiers: []) === bench.canvas)
                #expect(bench.canvas.hitTest(point, modifiers: .command) == nil)
            }
            let elsewhere = CGPoint(x: 200, y: 600)
            #expect(!bench.editor.canvasTakesPress(at: elsewhere, command: false))
            #expect(bench.canvas.hitTest(elsewhere, modifiers: []) == nil)
            #expect(!bench.editor.canvasTakesPress(at: CGPoint(x: Self.a.x, y: (Self.a.y + 250) / 2), command: false))
            // Nothing selected, no handles; the middle, where the linear's mask has its pin, is the pin's (MaskPinTests).
            bench.editor.selection = nil
            for (handle, point) in handles { #expect(bench.editor.canvasTakesPress(at: point, command: false) == handle.movesWhole) }
        }
    }

    /// A handle zoomed off the area has no rectangle for a cursor: the null one `intersection` gives then is one
    /// AppKit throws on, in the display cycle, which took the app down in use.
    @Test func aHandleOffTheAreaMakesNoCursorRect() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1188, height: 756), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            bench.canvas.frame = NSRect(x: 0, y: 0, width: 1188, height: 756)
            window.contentView?.addSubview(bench.canvas)
            defer { bench.canvas.removeFromSuperview() }
            // Every handle far off the area, and then some on it and some off.
            for picture in [CGRect(x: 40_000, y: 40_000, width: 4536, height: 3024), CGRect(x: -2000, y: -300, width: 4536, height: 3024)] {
                bench.geometry.picture = picture
                bench.canvas.resetCursorRects()
                bench.canvas.discardCursorRects()
                #expect(bench.editor.selection != nil, "still selected, with its handles out of sight")
            }
        }
    }

    @Test func aHandleDragIsOneUndoStepAndGoesThroughTheRule() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let before = bench.masks[0]
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.b)
            bench.now += 1
            bench.event(.drag, CGPoint(x: Self.b.x, y: Self.b.y + 40))
            // The handle has gone from where the press began, and the press is still the canvas's: FrameView asks at its first movement.
            #expect(bench.editor.canvasTakesPress(at: Self.b, command: false))
            #expect(bench.editor.canvasTakesPress(at: Self.b, command: true))
            bench.now += 1
            bench.event(.drag, CGPoint(x: Self.b.x + 20, y: Self.b.y + 60))
            bench.event(.release, CGPoint(x: Self.b.x + 20, y: Self.b.y + 60))
            bench.undo.endUndoGrouping()
            guard case .linear(let g) = bench.masks[0].components[0].shape else { Issue.record("not linear"); return }
            #expect(g.zero == bench.geometry.maskPoint(CGPoint(x: Self.b.x + 20, y: Self.b.y + 60)) && g.full == bench.geometry.maskPoint(Self.a))
            #expect(bench.undo.undoActionName == "Adjust Gradient" && bench.editor.justPlaced)
            bench.undo.undo()
            #expect(bench.masks[0] == before)
            #expect(bench.undo.undoActionName == "Add Linear Gradient")
        }
    }

    @Test func aHandleTouchedAndNotMovedIsNoStep() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let edit = bench.model.manualEdits[bench.frame.url]
            bench.undo.removeAllActions()
            bench.event(.press, Self.b)
            bench.event(.release, Self.b)
            #expect(bench.model.manualEdits[bench.frame.url] == edit && !bench.undo.canUndo)
        }
    }

    @Test func aRadialsHandlesWorkFromThePointer() async throws {
        try await withBench { bench in
            bench.editor.arm(.radial)
            bench.drag(CGPoint(x: 594, y: 378), CGPoint(x: 694, y: 438))
            let handles = Dictionary(uniqueKeysWithValues: MaskHandleModel.handles(of: bench.masks[0].components[0].shape, in: bench.geometry).map { ($0.handle, $0.point) })
            let feather = try #require(handles[.feather])
            bench.drag(feather, CGPoint(x: feather.x + 20, y: feather.y))
            guard case .radial(let inner) = bench.masks[0].components[0].shape else { Issue.record("not radial"); return }
            #expect(inner.feather > 50)
            let center = try #require(handles[.center])
            bench.drag(center, CGPoint(x: center.x - 30, y: center.y))
            guard case .radial(let moved) = bench.masks[0].components[0].shape else { Issue.record("not radial"); return }
            #expect(moved.center != inner.center && moved.feather == inner.feather)
            #expect(bench.undo.undoActionName == "Adjust Gradient")
        }
    }

    /// A zoom under a press does not move the mask point the pointer is read at.
    @Test func handlesAreReadWhereThePictureIsNow() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            guard case .linear(let was) = bench.masks[0].components[0].shape else { Issue.record("not linear"); return }
            bench.geometry.picture = CGRect(x: -500, y: -300, width: 2268, height: 1512)
            let moved = bench.geometry.point(for: was.zero)
            #expect(bench.editor.canvasTakesPress(at: moved, command: false))
            bench.drag(moved, CGPoint(x: moved.x + 100, y: moved.y))
            guard case .linear(let now) = bench.masks[0].components[0].shape else { Issue.record("not linear"); return }
            #expect(abs(now.zero.x - (was.zero.x + Float(100.0 / 2268))) < 1e-4)
        }
    }

    // MARK: Standing down

    /// Space, Compare to Auto, the clipping view and a frame that cannot be adjusted: no handle, no overlay, and
    /// a press on the armed picture is kept, so the frame does not pan under it, and does nothing.
    @Test(arguments: ["space", "compare", "clipping", "notReady"])
    func theToolsStandDown(_ state: String) async throws {
        try await withBench { bench in
            drawnLinear(bench)
            bench.editor.setOverlay(on: true)
            #expect(bench.model.overlayComponents(for: bench.frame) != nil && bench.editor.shapeUnderHandles(in: bench.frame) != nil)
            let handle = Self.a, count = bench.masks.count
            @MainActor func set(_ on: Bool) {
                switch state {
                case "space": bench.model.isComparing = on
                case "compare": bench.model.isComparingAuto = on
                case "clipping": bench.model.lightClipping = on ? .highlights : nil
                default:
                    if on { bench.model.manualReadySources[bench.frame.url] = nil }
                }
            }
            let ready = bench.model.manualReadySources[bench.frame.url]
            set(true)
            #expect(bench.model.masksStandDown(bench.frame))
            #expect(bench.model.overlayComponents(for: bench.frame) == nil && bench.editor.shapeUnderHandles(in: bench.frame) == nil)
            // No handle to take: the press is the frame view's.
            #expect(!bench.editor.canvasTakesPress(at: handle, command: false))
            // With a tool: kept and ignored.
            bench.editor.arm(.radial)
            #expect(bench.editor.canvasTakesPress(at: handle, command: false))
            bench.drag(handle, Self.b)
            #expect(bench.masks.count == count && bench.editor.tool == .radial && bench.editor.press == nil)
            // Return places nothing.
            #expect(!bench.model.placeArmedGradient())
            _ = bench.editor.escape()
            set(false)
            if state == "notReady" { bench.model.manualReadySources[bench.frame.url] = ready }
            #expect(bench.editor.selection != nil && bench.editor.shapeUnderHandles(in: bench.frame) != nil)
        }
    }

    /// Space held during a handle's drag: it stops following, and the release still ends the one step.
    @Test func aDragStandsDownWithSpaceAndStillEndsAsOneStep() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let moved = CGPoint(x: Self.b.x, y: Self.b.y + 40)
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.b)
            bench.now += 1
            bench.event(.drag, moved)
            bench.model.isComparing = true
            bench.now += 1
            bench.event(.drag, CGPoint(x: Self.b.x, y: Self.b.y + 200))
            bench.event(.release, CGPoint(x: Self.b.x, y: Self.b.y + 200))
            bench.model.isComparing = false
            bench.undo.endUndoGrouping()
            guard case .linear(let g) = bench.masks[0].components[0].shape else { Issue.record("not linear"); return }
            #expect(g.zero == bench.geometry.maskPoint(moved) && bench.undo.undoActionName == "Adjust Gradient" && bench.editor.press == nil)
        }
    }

    // MARK: The Escape ladder and Delete

    @Test func escapeStepsBackOneRungAtATime() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let id = bench.masks[0].id
            bench.editor.selection = MaskEditor.Selection(mask: id, component: 0)
            bench.editor.isPickerOpen = true
            bench.editor.arm(.radial)
            #expect(!bench.editor.isPickerOpen) // a choice collapses the tiles
            bench.editor.isPickerOpen = true
            #expect(bench.editor.escape() && bench.editor.tool == nil && bench.editor.isPickerOpen)
            #expect(bench.editor.escape() && !bench.editor.isPickerOpen && bench.editor.selection?.component == 0)
            #expect(bench.editor.escape() && bench.editor.selection == MaskEditor.Selection(mask: id, component: nil))
            #expect(bench.editor.escape() && bench.editor.selection == nil && !bench.editor.justPlaced)
            #expect(!bench.editor.escape())
        }
    }

    /// Escape with a gradient half drawn: nothing to show for it, no step, and the tool still in hand.
    @Test func escapeInADrawLeavesNothingAndTheToolInHand() async throws {
        try await withBench { bench in
            let edit = bench.model.manualEdits[bench.frame.url]
            bench.editor.arm(.linear)
            bench.event(.press, Self.a)
            bench.event(.drag, Self.b)
            #expect(bench.masks.count == 1)
            #expect(bench.editor.escape())
            #expect(bench.masks.isEmpty && bench.editor.tool == .linear && bench.editor.selection == nil && bench.editor.press == nil)
            #expect(bench.model.manualEdits[bench.frame.url] == edit && !bench.undo.canUndo)
            #expect(bench.model.manualGestures[bench.frame.url] == nil)
            // What the rest of the press does is nothing.
            bench.event(.drag, Self.a)
            bench.event(.release, Self.a)
            #expect(bench.masks.isEmpty && bench.editor.press == nil)
        }
    }

    @Test func escapeInAHandleDragPutsItBack() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let before = bench.masks[0]
            bench.event(.press, Self.b)
            bench.now += 1
            bench.event(.drag, CGPoint(x: Self.b.x, y: Self.b.y + 40))
            #expect(bench.editor.escape())
            #expect(bench.masks[0] == before && bench.editor.selection?.mask == before.id && bench.undo.undoActionName == "Add Linear Gradient")
        }
    }

    @Test func deleteTakesTheComponentThenTheMask() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            bench.editor.arm(.radial, operation: .subtract)
            bench.drag(Self.a, Self.b)
            let id = bench.masks[0].id
            #expect(bench.masks[0].components.count == 2 && bench.editor.selection == MaskEditor.Selection(mask: id, component: 1))
            #expect(bench.undo.undoActionName == "Subtract Radial")
            bench.undo.beginUndoGrouping()
            #expect(bench.editor.deleteSelection())
            bench.undo.endUndoGrouping()
            #expect(bench.masks[0].components.count == 1 && bench.undo.undoActionName == "Remove from Mask")
            // Its component gone, the mask stays selected.
            #expect(bench.editor.selection == MaskEditor.Selection(mask: id, component: nil))
            bench.undo.beginUndoGrouping()
            #expect(bench.editor.deleteSelection())
            bench.undo.endUndoGrouping()
            #expect(bench.masks.isEmpty && bench.editor.selection == nil && bench.undo.undoActionName == "Delete Mask")
            #expect(!bench.editor.deleteSelection())
        }
    }

    // MARK: Undo and the selection

    @Test func undoAndRedoKeepTheSelectionHonest() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let id = bench.masks[0].id
            // A mask undone away is no longer selected, and redone it is again.
            bench.undo.undo()
            #expect(bench.masks.isEmpty && bench.editor.selection == nil)
            bench.undo.redo()
            #expect(bench.masks.first?.id == id && bench.editor.selection == MaskEditor.Selection(mask: id, component: nil))
            // Deleted: gone. Undone: it comes back selected.
            bench.step { bench.model.deleteMask(id, for: bench.frame) }
            #expect(bench.editor.selection == nil)
            bench.undo.undo()
            #expect(bench.masks.first?.id == id && bench.editor.selection?.mask == id)
            // A step on another mask brings the selection to what it changed.
            bench.editor.arm(.radial)
            bench.drag(Self.a, Self.b)
            let other = bench.masks[1].id
            #expect(bench.editor.selection?.mask == other)
            bench.step {
                bench.model.setMaskEnabled(false, mask: id, for: bench.frame)
            }
            #expect(bench.editor.selection?.mask == other)
            bench.undo.undo()
            #expect(bench.editor.selection?.mask == id)
        }
    }

    /// A selected component that an undo takes away leaves its mask selected.
    @Test func aComponentUndoneAwayLeavesItsMask() throws {
        let id = UUID()
        func shape(_ y: Float) -> MaskComponent { MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0, y: 0), zero: MaskPoint(x: 0, y: y)))) }
        let two = Mask(id: id, components: [shape(0.2), shape(0.3)]), one = Mask(id: id, components: [shape(0.2)])
        #expect(MaskEditor.reconciled(MaskEditor.Selection(mask: id, component: 1), from: [two], to: [one]) == MaskEditor.Selection(mask: id, component: nil))
        #expect(MaskEditor.reconciled(MaskEditor.Selection(mask: id, component: 0), from: [two], to: [one]) == MaskEditor.Selection(mask: id, component: 0))
        #expect(MaskEditor.reconciled(MaskEditor.Selection(mask: id, component: 0), from: [two], to: []) == nil)
        #expect(MaskEditor.reconciled(nil, from: [], to: []) == nil)
        #expect(MaskEditor.reconciled(nil, from: [], to: [one]) == MaskEditor.Selection(mask: id, component: nil))
        #expect(MaskEditor.kept(MaskEditor.Selection(mask: UUID(), component: nil), in: [one]) == nil)
    }

    /// An Undo that arrives while a gradient moves lets it go, and what is restored is what the undo says.
    @Test func undoDuringADragLetsTheDragGo() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let before = bench.masks[0]
            bench.step { bench.model.setMaskEnabled(false, mask: before.id, for: bench.frame) }
            bench.event(.press, Self.b)
            bench.now += 1
            bench.event(.drag, CGPoint(x: Self.b.x, y: Self.b.y + 40))
            bench.undo.undo()
            #expect(bench.editor.press == nil && bench.masks[0] == before)
            #expect(bench.model.manualGestures[bench.frame.url] == nil)
        }
    }

    @Test(arguments: ["tab", "inspector", "frame", "close", "page"])
    func theSelectionGoesWhenTheTabOrFrameDoes(_ occasion: String) async throws {
        try await withBench { bench in
            drawnLinear(bench)
            bench.editor.setOverlay(on: false)
            #expect(bench.editor.selection != nil)
            switch occasion {
            case "tab": bench.model.adjustTab = .light
            case "inspector": bench.model.isAdjustmentsShown = false
            case "frame": bench.model.moveSelection(by: 1)
            case "close": bench.model.closeFrame()
            default: bench.model.showWorkspacePage(.settings)
            }
            #expect(bench.editor.selection == nil && bench.editor.tool == nil && !bench.editor.justPlaced)
        }
    }

    /// A gesture under way when the tab goes ends as its one step rather than hanging open.
    @Test func aPressFinishesWhenTheTabGoes() async throws {
        try await withBench { bench in
            bench.editor.arm(.linear)
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.a)
            bench.event(.drag, Self.b)
            bench.model.adjustTab = .light
            bench.undo.endUndoGrouping()
            #expect(bench.editor.press == nil && bench.masks.count == 1 && bench.model.manualGestures[bench.frame.url] == nil)
            #expect(bench.undo.undoActionName == "Add Linear Gradient")
        }
    }

    // MARK: The keyboard alone

    /// M, Return, and the gradient is on the frame, selected and showing, with no pointer.
    @Test func aGradientCanBePlacedWithNoPointer() async throws {
        try await withBench { bench in
            bench.model.adjustTab = .light
            bench.model.perform(.newMask(.linear))
            #expect(bench.model.adjustTab == .masks && bench.editor.tool == .linear && bench.editor.photographFocusRequests == 1)
            bench.step { #expect(bench.model.placeArmedGradient()) }
            #expect(bench.masks.count == 1 && bench.editor.tool == nil && bench.editor.justPlaced)
            #expect(bench.editor.selection?.mask == bench.masks[0].id && bench.undo.undoActionName == "Add Linear Gradient")
            guard case .linear(let g) = bench.masks[0].components[0].shape else { Issue.record("not linear"); return }
            #expect(g.full.y == 0)
            // With nothing in hand Return is not the masks'.
            #expect(!bench.model.placeArmedGradient())
            // N: a new mask like the selected one's last shape, and a shape can be added the same way.
            bench.model.perform(.newLikeSelected)
            #expect(bench.editor.tool == .linear && bench.editor.pendingOperation == nil)
            bench.step { #expect(bench.model.placeArmedGradient()) }
            #expect(bench.masks.count == 2)
            bench.model.perform(.addShape(.radial, .subtract))
            #expect(bench.editor.tool == .radial && bench.editor.pendingOperation == .subtract)
            bench.step { #expect(bench.model.placeArmedGradient()) }
            #expect(bench.masks.count == 2 && bench.masks[1].components.count == 2 && bench.undo.undoActionName == "Subtract Radial")
            #expect(bench.masks[1].components[1].operation == .subtract)
        }
    }

    /// A component with no pointer: Next and Previous Component go round the selected mask's from the mask as a whole, and Set Component
    /// changes a later one's operation; the first, always added, stays as it is.
    @Test func aComponentCanBeReachedWithNoPointer() async throws {
        try await withBench { bench in
            bench.model.perform(.newMask(.linear))
            bench.step { #expect(bench.model.placeArmedGradient()) }
            bench.model.perform(.addShape(.radial, .add))
            bench.step { #expect(bench.model.placeArmedGradient()) }
            let id = bench.masks[0].id
            #expect(bench.masks[0].components.count == 2)
            bench.editor.selection = MaskEditor.Selection(mask: id, component: nil)
            bench.model.perform(.nextComponent)
            #expect(bench.editor.selection == MaskEditor.Selection(mask: id, component: 0))
            bench.model.perform(.nextComponent)
            #expect(bench.editor.selection == MaskEditor.Selection(mask: id, component: 1))
            bench.model.perform(.nextComponent)
            #expect(bench.editor.selection == MaskEditor.Selection(mask: id, component: 0))
            bench.model.perform(.previousComponent)
            #expect(bench.editor.selection == MaskEditor.Selection(mask: id, component: 1))
            bench.editor.selection = MaskEditor.Selection(mask: id, component: nil)
            bench.model.perform(.previousComponent)
            #expect(bench.editor.selection == MaskEditor.Selection(mask: id, component: 1))
            bench.step { bench.model.perform(.componentOperation(.subtract)) }
            #expect(bench.masks[0].components[1].operation == .subtract && bench.undo.undoActionName == "Subtract in Mask")
            bench.editor.selection = MaskEditor.Selection(mask: id, component: 0)
            bench.step { bench.model.perform(.componentOperation(.subtract)) }
            #expect(bench.masks[0].components[0].operation == .add)
        }
    }

    @Test func theMenuReachesTheRest() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            bench.step { bench.model.perform(.placeGradient) }
            #expect(bench.masks.count == 1)
            bench.editor.arm(.radial)
            bench.step { bench.model.perform(.placeGradient) }
            #expect(bench.masks.count == 2)
            let first = bench.masks[0].id, second = bench.masks[1].id
            bench.model.perform(.nextMask)
            #expect(bench.editor.selection?.mask == first)
            bench.model.perform(.previousMask)
            #expect(bench.editor.selection?.mask == second)
            bench.model.perform(.renameMask)
            #expect(bench.editor.renaming == second)
            bench.step { bench.model.perform(.invert) }
            #expect(bench.masks[1].components[0].invert)
            bench.step { bench.model.perform(.switchMask) }
            #expect(!bench.masks[1].isEnabled)
            bench.step { bench.model.perform(.duplicateMask) }
            #expect(bench.masks.count == 3)
            bench.step { bench.model.perform(.deleteMask) }
            #expect(bench.masks.count == 2)
            let colour = bench.editor.overlayColour
            defer { bench.editor.overlayColour = colour }
            bench.editor.selection = MaskEditor.Selection(mask: first, component: nil)
            bench.editor.setOverlay(on: false)
            bench.model.perform(.showOverlay)
            #expect(bench.editor.isOverlayOn)
            bench.model.perform(.nextOverlayColour)
            #expect(bench.editor.overlayColour == colour.next)
            bench.step { bench.model.perform(.resetMasks) }
            #expect(bench.masks.isEmpty)
        }
    }

    // MARK: The compiler and a first mask

    /// On `2026-10-29-1` with no pair of controls it reads differently, a first mask takes the edit to the current
    /// compiler in that same step, silently; Undo puts both back; and from then on it is a current edit.
    @Test(arguments: [(Float(0), Float(-50)), (1, 0)])
    func aFirstMaskMovesAnEditThatRendersTheSameInItsOwnStep(_ values: (exposure: Float, highlights: Float)) async throws {
        try await withBench(edit: { edit in
            var edit = edit
            edit.curveVersion = ManualRenderSettings.exposedBaseVersion
            edit.adjustments = try ManualAdjustments(exposureEV: values.exposure, highlights: values.highlights)
            return edit
        }) { bench in
            let before = try #require(bench.model.manualEdits[bench.frame.url])
            #expect(bench.model.maskCompilerGate(for: bench.frame) == .movesToCurrent && bench.model.canAddMask(bench.frame))
            drawnLinear(bench)
            let moved = try #require(bench.model.manualEdits[bench.frame.url])
            #expect(moved.curveVersion == ManualRenderSettings.currentVersion && moved.adjustments.masks.count == 1)
            #expect(moved.adjustments.exposureEV == values.exposure && moved.adjustments.highlights == values.highlights)
            #expect(moved.baseline == before.baseline && bench.model.manualIssue(for: bench.frame) == nil)
            #expect(bench.undo.undoActionName == "Add Linear Gradient")
            // Now it is open like any current edit, and stays there through a second mask and a delete.
            #expect(bench.model.maskCompilerGate(for: bench.frame) == .open)
            bench.undo.undo()
            #expect(bench.model.manualEdits[bench.frame.url] == before && !bench.undo.canUndo)
            bench.undo.redo()
            #expect(bench.model.manualEdits[bench.frame.url] == moved)
            bench.step { bench.model.deleteMask(bench.masks[0].id, for: bench.frame) }
            #expect(bench.model.manualEdits[bench.frame.url]?.curveVersion == ManualRenderSettings.currentVersion)
        }
    }

    /// Return's way takes the same step.
    @Test func placingByKeyMovesTheCompilerToo() async throws {
        try await withBench(edit: { edit in
            var edit = edit
            edit.curveVersion = ManualRenderSettings.exposedBaseVersion
            return edit
        }) { bench in
            bench.model.perform(.newMask(.radial))
            bench.step { #expect(bench.model.placeArmedGradient()) }
            #expect(bench.model.manualEdits[bench.frame.url]?.curveVersion == ManualRenderSettings.currentVersion)
            bench.undo.undo()
            #expect(bench.model.manualEdits[bench.frame.url]?.curveVersion == ManualRenderSettings.exposedBaseVersion && bench.masks.isEmpty)
        }
    }

    /// Where moving would change the picture the tiles are disabled and nothing else opens the way, until the
    /// photographer asks for Update Automatic Baseline.
    @Test(arguments: [ManualRenderSettings.exposedBaseVersion, ManualRenderSettings.regionsVersion])
    func anEditThatWouldChangeTakesNoMask(_ version: String) async throws {
        try await withBench(edit: { edit in
            var edit = edit
            edit.curveVersion = version
            edit.adjustments = try ManualAdjustments(exposureEV: 1, highlights: -50)
            return edit
        }) { bench in
            let before = bench.model.manualEdits[bench.frame.url]
            #expect(bench.model.maskCompilerGate(for: bench.frame) == .needsUpdate && !bench.model.canAddMask(bench.frame))
            // It can still be adjusted: only masks wait.
            #expect(bench.model.canAdjust(bench.frame))
            bench.model.perform(.newMask(.linear))
            #expect(bench.model.adjustTab == .masks && bench.editor.tool == nil)
            // A tool that was in hand gets nowhere either.
            bench.editor.arm(.linear)
            bench.press(Self.a, Self.b)
            #expect(bench.masks.isEmpty && bench.model.manualEdits[bench.frame.url] == before && !bench.undo.canUndo)
            #expect(!bench.model.placeArmedGradient())
        }
    }

    @Test func aFrameHoldsSixteenMasks() async throws {
        try await withBench { bench in
            for _ in 0..<MaskSet.maximumMasks {
                bench.editor.arm(.linear)
                bench.drag(Self.a, Self.b)
            }
            #expect(bench.masks.count == MaskSet.maximumMasks && !bench.model.canAddMask(bench.frame))
            bench.editor.arm(.linear)
            bench.drag(Self.a, Self.b)
            #expect(bench.masks.count == MaskSet.maximumMasks)
            bench.step { bench.model.duplicateMask(bench.masks[0].id, for: bench.frame) }
            #expect(bench.masks.count == MaskSet.maximumMasks)
        }
    }

    // MARK: The overlay, through the model

    @Test func theOverlayFollowsThePlansRuleOnAMask() async throws {
        try await withBench { bench in
            drawnLinear(bench)
            let id = bench.masks[0].id, components = bench.masks[0].components
            // Shown after creating.
            #expect(bench.model.overlayComponents(for: bench.frame) == components)
            // Hidden as a slider moves, and not back once it stops.
            bench.editor.sliderBegan()
            #expect(bench.model.overlayComponents(for: bench.frame) == nil)
            bench.editor.sliderEnded()
            #expect(bench.model.overlayComponents(for: bench.frame) == nil)
            // A handle's drag shows it again.
            bench.drag(Self.b, CGPoint(x: Self.b.x, y: Self.b.y + 30))
            #expect(bench.model.overlayComponents(for: bench.frame) == bench.masks[0].components)
            bench.editor.toggleOverlay()
            #expect(bench.model.overlayComponents(for: bench.frame) == nil)
            // Hovering a row shows that mask, with the checkbox off, and a second mask's row shows that one.
            bench.editor.arm(.radial)
            bench.drag(Self.a, Self.b)
            bench.editor.toggleOverlay()
            bench.editor.hover = .mask(id)
            #expect(bench.model.overlayComponents(for: bench.frame) == bench.masks[0].components)
            bench.editor.hover = nil
            #expect(bench.model.overlayComponents(for: bench.frame) == nil)
            // A component's row shows that component alone, as it selects.
            bench.editor.arm(.linear, operation: .subtract)
            bench.drag(Self.a, Self.b)
            bench.editor.toggleOverlay()
            let second = bench.masks[1]
            bench.editor.hover = .component(second.id, 1)
            #expect(bench.model.overlayComponents(for: bench.frame) == [MaskComponent(shape: second.components[1].shape)])
            bench.editor.hover = .component(second.id, 9)
            #expect(bench.model.overlayComponents(for: bench.frame) == nil)
        }
    }

    /// With no mask selected and the pointer on no row, there is nothing to work out, and the frame view is
    /// exactly as it was.
    @Test func nothingShowsOnAFrameWithNoMasks() async throws {
        try await withBench { bench in
            #expect(bench.model.overlayComponents(for: bench.frame) == nil)
            #expect(bench.editor.shapeUnderHandles(in: bench.frame) == nil)
            #expect(!bench.editor.followsPointer)
            bench.editor.setOverlay(on: true)
            #expect(bench.model.overlayComponents(for: bench.frame) == nil)
        }
    }
}



#if DEBUG
extension MaskEditorStateTests {
    private func withGeometryBench(_ body: (Bench, MaskLens, LensGeometry) async throws -> Void) async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown"), tab = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        defer {
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(tab, forKey: AdjustInspectorTab.storageKey)
        }
        try await AutoDecisionStateTests.withRoll { fixture in
            let raw = fixture.raw(0).resolvingSymlinksInPath()
            try cloneLensGeometrySample(to: raw)
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            let frames = try #require(model.roll?.frames), frame = frames[0]
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            await model.prepareManualAdjustments(for: frame)
            model.recordVisibleAutomatic(for: frame, stock: model.stockIndex, aim: model.printAim(for: frame), settings: model.settings(for: frame, stock: model.stockIndex))
            model.setManualAdjustments(try ManualAdjustments(exposureEV: 0.5, lens: LensSettings(arguments: "distortion=off")), for: frame)
            model.selection = frame.id
            model.openFrame()
            model.adjustTab = .masks
            model.isAdjustmentsShown = true
            model.manualUndoManager = UndoManager()
            model.manualUndoManager?.groupsByEvent = false
            let bench = Bench(model: model, frame: frame, folder: fixture.folder)
            defer { bench.canvas.teardown() }
            _ = try #require(model.films).key(frame, lens: model.lensSettings(for: frame))
            bench.editor.filmShown(for: frame, settings: model.printSettings(for: frame, stock: model.stockIndex), renderedIn: 0)
            let lens = try #require(bench.editor.lens(on: frame))
            try #require(lens.picture != lens.legacy)
            let madeOn = try LensGeometry(table: RadialTable(knots: [1, 0.99, 0.96]), scale: 1)
            try await body(bench, lens, madeOn)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func reapplyStampsShapesWithTheHeldEditsLens() async throws {
        try await withGeometryBench { bench, lens, _ in
            let model = bench.model, frame = bench.frame
            model.manualUndoManager = nil
            let shape = MaskShape.linear(.init(full: .init(x: 0.2, y: 0.1), zero: .init(x: 0.4, y: 0.3)))
            let mask = Mask(components: [.init(shape: shape)])
            let values = try model.manualAdjustments(for: frame).settingMasks(MaskSet(masks: [mask]))
            model.manualEdits[frame.url]?.adjustments = values
            let held = try #require(model.manualEdits[frame.url])
            model.heldManualEdits[frame.url] = held
            model.manualEdits[frame.url] = nil
            try #require(model.lensSettings(for: frame) != held.adjustments.lens)
            try #require(model.maskLens(for: frame, settings: model.lensSettings(for: frame))?.picture != lens.picture)
            model.reapplyManualAdjustments(for: frame)
            for _ in 0..<1000 where model.heldManualEdits[frame.url] != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            let reapplied = try #require(model.manualEdits[frame.url])
            #expect(model.heldManualEdits[frame.url] == nil)
            #expect(reapplied.adjustments.lens == held.adjustments.lens)
            #expect(reapplied.adjustments.masks.masks[0].components[0].shape.geometry == lens.picture)
            try await model.flushManualSaves()
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func anOverlayOnAnotherFrameDoesNotUseThePreviousPicturesLens() async throws {
        try await withGeometryBench { bench, _, madeOn in
            let model = bench.model, editor = bench.editor
            model.manualUndoManager = nil
            let other = try #require(model.roll?.frames.first { $0.url != bench.frame.url })
            await model.prepareManualAdjustments(for: other)
            model.recordVisibleAutomatic(for: other, stock: model.stockIndex, aim: model.printAim(for: other),
                                         settings: model.settings(for: other, stock: model.stockIndex))
            let shape = MaskShape.radial(.init(center: .init(x: 0.85, y: 0.12), semiAxisA: 0.08, semiAxisB: 0.05, feather: 10, geometry: madeOn))
            let mask = Mask(components: [.init(shape: shape)])
            model.setManualAdjustments(try ManualAdjustments(masks: MaskSet(masks: [mask])), for: other)
            model.selection = other.id
            model.openFrame()
            editor.pictureShown(for: bench.frame, settings: model.printSettings(for: bench.frame, stock: model.stockIndex))
            try #require(editor.lens(on: bench.frame) != nil && editor.lens(on: other) == nil)
            editor.selection = .init(mask: mask.id, component: nil)
            editor.setOverlay(on: true)
            let components = try #require(model.overlayComponents(for: other))
            let request = MaskOverlayRequest(components: components, picture: bench.geometry.picture.size, longSide: 1024, frame: other)
            let field = editor.overlay.field
            let expected = try #require(MaskOverlayStore.image(of: field.raster(of: components, width: request.width, height: request.height, on: other, lens: nil),
                                                               width: request.width, height: request.height))
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: MaskOverlayView(frame: other, geometry: bench.geometry, neutralWidth: nil,
                                                               decode: MaskOverlayDecode(pixels: nil, refined: false)).environment(model))
            window.contentView = host
            for _ in 0..<200 where editor.overlay.image == nil {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            await editor.overlay.settle()
            let actual = try #require(editor.overlay.image)
            #expect((actual.dataProvider?.data as Data?) == (expected.dataProvider?.data as Data?))
            try await model.flushManualSaves()
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func geometryMapsHandlesAndAnEditMovesTheWholeMaskInOneUndoStep() async throws {
        try await withGeometryBench { bench, lens, madeOn in
            let linear = MaskShape.linear(.init(full: .init(x: 0.12, y: 0.12), zero: .init(x: 0.24, y: 0.26), geometry: madeOn))
            let radial = MaskShape.radial(.init(center: .init(x: 0.23, y: 0.16), semiAxisA: 0.05, semiAxisB: 0.04, geometry: madeOn))
            let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: false, geometry: madeOn)
            let brush = MaskShape.brush(.init(frame: frame, strokes: [.init(radius: 0.02, points: try .pack([.init(x: 0.18, y: 0.18)]))]))
            let mask = Mask(components: [.init(shape: linear), .init(shape: radial), .init(shape: brush)])
            let values = try bench.model.manualAdjustments(for: bench.frame).settingMasks(MaskSet(masks: [mask]))
            bench.model.manualEdits[bench.frame.url]?.adjustments = values
            bench.editor.selection = .init(mask: mask.id, component: 0)
            let expected = linear.moved(in: lens) { m, _ in m }
            #expect(bench.editor.shapeUnderHandles(in: bench.frame) == expected)
            let handles = MaskHandleModel.handles(of: expected, in: bench.geometry)
            let full = try #require(handles.first { $0.handle == .full }).point
            let to = CGPoint(x: full.x + 40, y: full.y + 30)
            let before = bench.model.manualEdits[bench.frame.url]
            bench.drag(full, to)
            let moved = try #require(bench.masks.first)
            #expect(moved.components.allSatisfy { $0.shape.geometry == lens.picture })
            #expect(moved.components[1].shape == radial.moved(in: lens) { m, _ in m })
            #expect(moved.components[2].shape == brush.moved(in: lens) { m, _ in m })
            guard case .linear(let changed) = moved.components[0].shape else { Issue.record("linear"); return }
            let at = bench.geometry.maskPoint(to)
            #expect(hypot(changed.full.x - at.x, changed.full.y - at.y) < 1e-6)
            bench.undo.undo()
            #expect(bench.model.manualEdits[bench.frame.url] == before && !bench.undo.canUndo)
            let digests = bench.masks[0].components.map { $0.shape.geometry?.digest }
            let coverage = bench.masks[0].coverage
            bench.step { bench.model.setMaskAmount(0.7, mask: mask.id, for: bench.frame) }
            #expect(bench.masks[0].components.map { $0.shape.geometry?.digest } == digests)
            #expect(bench.masks[0].coverage == coverage)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func aCachedFilmSetsTheLensResetKeepsItAndFrameDisappearanceForgetsIt() async throws {
        try await withGeometryBench { bench, lens, _ in
            let model = bench.model, frame = bench.frame, films = try #require(model.films)
            let settings = model.printSettings(for: frame, stock: model.stockIndex), space = model.output.space
            _ = try #require(await films.frameFilm(frame, stock: model.stockIndex, settings: settings, space: space, pixels: 600))
            try #require(films.cachedFrameFilm(frame, stock: model.stockIndex, settings: settings, space: space, pixels: 600) != nil)
            bench.editor.pictureHidden()
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            // Keep loadFilm from reporting a lens, so only takeCached can satisfy this assertion.
            model.manualPreparationErrors[frame.url] = "hold the asynchronous film path"
            try #require(model.hasManualAdjustments(frame) && model.manualIssue(for: frame) != nil)
            let host = NSHostingView(rootView: AnyView(FrameView(roll: try #require(model.roll), frame: frame)
                .environment(model).environment(\.displayScale, 1)))
            window.contentView = host
            for _ in 0..<200 where bench.editor.pictureLens(on: frame) == nil {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(bench.editor.lens(on: frame) == lens, "only the cached film path can report its lens")
            bench.editor.reset()
            #expect(bench.editor.lens(on: frame) == lens)
            model.closeFrame()
            host.rootView = AnyView(EmptyView())
            for _ in 0..<200 where bench.editor.pictureLens(on: frame) != nil {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(bench.editor.pictureLens(on: frame) == nil)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func equalShapeWritesAndAHandleDraggedBackLeaveLegacyBytesAlone() async throws {
        try await withGeometryBench { bench, _, _ in
            let shape = MaskShape.linear(.init(full: .init(x: 0.25, y: 0.125), zero: .init(x: 0.5, y: 0.375)))
            let mask = Mask(components: [.init(shape: shape)])
            let values = try bench.model.manualAdjustments(for: bench.frame).settingMasks(MaskSet(masks: [mask]))
            bench.model.manualEdits[bench.frame.url]?.adjustments = values
            bench.editor.selection = .init(mask: mask.id, component: 0)
            bench.undo.groupsByEvent = true
            bench.undo.removeAllActions()
            let before = bench.model.manualEdits[bench.frame.url]
            let digest = bench.model.manualAdjustments(for: bench.frame).masks.digest
            bench.model.beginManualGesture(for: bench.frame)
            bench.model.setComponentShape(shape, of: mask.id, component: 0, for: bench.frame)
            bench.model.endManualGesture(for: bench.frame, actionName: "Adjust Gradient")
            #expect(!bench.undo.canUndo)
            #expect(bench.model.manualEdits[bench.frame.url] == before)
            #expect(bench.model.manualAdjustments(for: bench.frame).masks.digest == digest)
            #expect(bench.masks[0].components[0].shape.geometry == nil)
            let displayed = try #require(bench.editor.shapeUnderHandles(in: bench.frame))
            let handle = try #require(MaskHandleModel.handles(of: displayed, in: bench.geometry).first { $0.handle == .middle }).point
            bench.event(.press, handle)
            bench.event(.drag, CGPoint(x: handle.x + 60, y: handle.y + 40))
            bench.event(.release, handle)
            #expect(!bench.undo.canUndo && bench.model.manualEdits[bench.frame.url] == before)
            #expect(bench.model.manualAdjustments(for: bench.frame).masks.digest == digest)
            #expect(bench.masks[0].components[0].shape.geometry == nil)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func drawnAndPlacedGradientsRecordTheShownGeometry() async throws {
        try await withGeometryBench { bench, lens, _ in
            bench.editor.arm(.radial)
            bench.undo.beginUndoGrouping()
            bench.event(.press, Self.a)
            bench.event(.drag, Self.b)
            #expect(bench.editor.press?.live?.geometry == lens.picture)
            bench.event(.release, Self.b)
            bench.undo.endUndoGrouping()
            #expect(bench.masks[0].components[0].shape.geometry == lens.picture)
            bench.editor.arm(.linear)
            bench.step { #expect(bench.model.placeArmedGradient()) }
            #expect(bench.masks[1].components[0].shape.geometry == lens.picture)
        }
    }
    @Test(.enabled(if: hasLensGeometrySample)) func theShownFilmsSettingsOwnTheEditorLensAndAutoKeepsLens() async throws {
        try await withGeometryBench { bench, lens, _ in
            let model = bench.model, frame = bench.frame
            let old = model.settings(for: frame, stock: model.stockIndex)
            bench.step { model.setManualAdjustments(model.manualAdjustments(for: frame).settingLens(try! LensSettings(arguments: "distortion-amount=150")), for: frame) }
            bench.editor.pictureShown(for: frame, settings: old)
            #expect(bench.editor.pictureLens(on: frame)?.settings == old.lens)
            #expect(bench.editor.lens(on: frame) == lens)
            let current = model.settings(for: frame, stock: model.stockIndex)
            let automatic = model.automaticSettings(for: frame, stock: model.stockIndex)
            #expect(automatic.lens == current.lens)
            #expect(automatic.manual.adjustments.clearing(.lens).isIdentity)
            bench.editor.pictureShown(for: frame, settings: current)
            #expect(bench.editor.pictureLens(on: frame)?.settings == current.lens)
            #expect(bench.editor.lens(on: frame)?.picture != lens.picture)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func aPointerShapeBeforeAFilmKeepsTheSettingsGeometryAndCoordinates() async throws {
        try await withGeometryBench { bench, _, _ in
            let model = bench.model, frame = bench.frame
            bench.step { model.setManualAdjustments(model.manualAdjustments(for: frame).settingLens(try! LensSettings(arguments: "distortion-amount=150")), for: frame) }
            bench.editor.pictureHidden()
            let lens = try #require(model.maskLens(for: frame, settings: model.lensSettings(for: frame)))
            try #require(lens.picture != lens.legacy)
            bench.editor.arm(.radial)
            bench.drag(Self.a, Self.b)
            let saved = try #require(bench.masks.first?.components.first?.shape)
            let expected = try #require(MaskHandleModel.drawn(.radial, from: bench.geometry.maskPoint(Self.a),
                                                             to: bench.geometry.maskPoint(Self.b), constrain: false)).stamped(lens.picture)
            #expect(saved == expected)
            #expect(saved.geometry == lens.picture)
            let displayed = try #require(bench.editor.shapeUnderHandles(in: frame))
            #expect(displayed == expected)
            let handle = try #require(MaskHandleModel.handles(of: displayed, in: bench.geometry).first { $0.handle == .center })
            let to = CGPoint(x: handle.point.x + 60, y: handle.point.y + 40)
            bench.drag(handle.point, to)
            let dragged = MaskHandleModel.dragged(.center, start: expected, from: bench.geometry.maskPoint(handle.point),
                                                   to: bench.geometry.maskPoint(to), constrain: false)
            #expect(bench.masks[0].components[0].shape == dragged)
        }
    }

    @Test(.enabled(if: hasLensGeometrySample)) func aShapePlacedBeforeAFilmRecordsTheSettingsGeometry() async throws {
        try await withGeometryBench { bench, lens, _ in
            bench.editor.pictureHidden()
            bench.editor.arm(.linear)
            bench.step { #expect(bench.model.placeArmedGradient()) }
            #expect(bench.masks[0].components[0].shape.geometry == lens.picture)
            let digest = bench.model.manualAdjustments(for: bench.frame).masks.digest
            bench.step { bench.model.setManualAdjustments(bench.model.manualAdjustments(for: bench.frame).settingLens(.default), for: bench.frame) }
            #expect(bench.model.manualAdjustments(for: bench.frame).masks.digest == digest)
        }
    }

}

#endif
