import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The photograph's menus in the frame view (docs/context-menus-plan.md, section 3): the frame's, with Put Tool Away while a tool is
/// in hand, and a mask's on its pin, as tables; that each row does what its menu bar item does and is enabled as that item's action
/// asks; and whose a right-click or a Control-click is (`MaskEditor.canvasTakesMenu`), on a frame with two masks on the Masks tab.
@MainActor @Suite(.serialized) struct PhotographMenuTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    private static let linear = MaskShape.linear(.init(full: MaskPoint(x: 0.2, y: 0.5), zero: MaskPoint(x: 0.2, y: 0.6)))
    private static let radial = MaskShape.radial(.init(center: MaskPoint(x: 0.75, y: 0.4), semiAxisA: 0.1, semiAxisB: 0.08, feather: 50))

    /// The first frame of a roll of two open, with an edit holding a Linear and a Radial, on the Masks tab, a canvas over it and the
    /// pointer over the area.
    @MainActor private final class Bench {
        let model: RollModel, frame: Frame, other: Frame, folder: URL, canvas: MaskCanvasView
        var geometry = FrameGeometry(area: CGSize(width: 1188, height: 756), picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2)
        var keyboardRequests = 0

        init(model: RollModel, frame: Frame, other: Frame, folder: URL) {
            self.model = model
            self.frame = frame
            self.other = other
            self.folder = folder
            canvas = MaskCanvasView(editor: model.maskEditor)
            model.maskEditor.canvas = canvas
            canvas.geometry = { [unowned self] in self.geometry }
            canvas.onPress = { [unowned self] in self.keyboardRequests += 1 }
        }

        var editor: MaskEditor { model.maskEditor }
        var masks: [Mask] { model.masks(for: frame) }
        var undo: UndoManager { model.manualUndoManager! }
        func pin(_ index: Int) -> CGPoint { editor.pins(on: frame, geometry: geometry).first { $0.id == masks[index].id }!.point }

        /// What a right-click at `point` would open.
        func menu(at point: CGPoint) -> [MenuEntry]? { PhotographMenu.entries(at: point, model: model) }
        /// The photograph's menu, as a right-click away from the pins opens it.
        var photograph: [MenuEntry] { menu(at: PhotographMenuTests.away) ?? [] }

        /// A step of the model's, as one group, as one event loop's turn is.
        func choose(_ id: String, in entries: [MenuEntry]) {
            undo.beginUndoGrouping()
            entries.entry(id)?.choose()
            undo.endUndoGrouping()
        }

        func finish() {
            canvas.teardown()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// On the picture, away from both pins.
    private static let away = CGPoint(x: 600, y: 650)

    private func withBench(_ body: (Bench) async throws -> Void) async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown"), tab = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-photograph-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        try header(folder.appendingPathComponent("DSC2.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        let frames = try #require(model.roll?.frames)
        let frame = frames[0]
        model.selection = frame.id
        model.openFrame()
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: PrintAim(level: -0.65, cast: .zero), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        let masks = [Mask(components: [MaskComponent(shape: Self.linear)]), Mask(components: [MaskComponent(shape: Self.radial)])]
        let adjustments = try ManualAdjustments(exposureEV: 0.5).settingMasks(try MaskSet(masks: masks))
        var edit = ManualEdit(adjustments: adjustments, baseline: pin)
        edit.maskNotes.names[masks[0].id.uuidString] = "Linear 1"
        edit.maskNotes.names[masks[1].id.uuidString] = "Radial 1"
        model.manualEdits[frame.url] = edit
        model.manualUndoManager = UndoManager()
        model.manualUndoManager?.groupsByEvent = false
        model.adjustTab = .masks
        model.isAdjustmentsShown = true
        let bench = Bench(model: model, frame: frame, other: frames[1], folder: folder)
        bench.canvas.pointerMoved(to: Self.away)
        defer {
            bench.finish()
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(tab, forKey: AdjustInspectorTab.storageKey)
        }
        try await body(bench)
    }

    // MARK: The photograph's menu

    @Test func thePhotographsMenuIsInThePlansOrder() async throws {
        try await withBench { bench in
            let menu = bench.photograph
            #expect(menu.titles == ["Flag", "—", "Copy Adjustments", "Paste Adjustments", "Paste Only", "—",
                                    "Split Compare", "Zoom to Fit", "Actual Size", "—", "New Mask", "—", "Reset", "—",
                                    "Develop This Frame…", "Show RAW in Finder", "Show Developed File in Finder"])
            #expect(menu.entry("frame.pasteOnly")?.children.titles == ["Light", "Presence", "Curve", "Masks", "Lens", "Rated At and Lab Balance",
                                                                         "Film Stock, Grain and Halation"])
            #expect(menu.entry("photograph.newMask")?.children.titles == ["Brush", "Linear Gradient", "Radial Gradient", "—",
                                                                         "Subject", "Sky", "Person", "Background"])
            #expect(menu.entry("frame.reset")?.children.titles == ["Reset to Current Auto", "Reset to Original", "Same as Roll"])
            // The photograph is no place for the frames the sheet shows, nor for opening a frame already open.
            #expect(menu.entry("frame.pasteToShown") == nil && menu.entry("frame.open") == nil)
            // Each key is the menu bar's own, shown and bound there.
            #expect(menu.entry("photograph.split")?.chord == KeyChord("c", [.shift, .command]))
            #expect(menu.entry("photograph.fit")?.chord == KeyChord("9", [.command]))
            #expect(menu.entry("photograph.actualSize")?.chord == KeyChord("0", [.command]))
            #expect(menu.entry("photograph.newMask.brush")?.chord == KeyChord("k"))
            #expect(menu.entry("photograph.newMask.linear")?.chord == KeyChord("m"))
            #expect(menu.entry("photograph.newMask.radial")?.chord == KeyChord("m", [.shift]))
            #expect(menu.entry("photograph.newMask.sky")?.chord == nil)
            #expect(menu.entry("frame.copy")?.chord == ClipboardKeys.copy && menu.entry("frame.paste")?.chord == ClipboardKeys.paste)
        }
    }

    /// With a tool in hand every press on the picture is the tool's, so the menu leads with putting it down, as Escape does.
    @Test func aToolInHandLeadsWithPutToolAway() async throws {
        try await withBench { bench in
            let plain = bench.photograph.titles
            #expect(bench.photograph.entry("photograph.putToolAway") == nil)
            for command in [MaskCommand.newMask(.linear), .newMask(.radial), .newMask(.brush)] {
                bench.model.perform(command)
                let menu = bench.photograph
                #expect(Array(menu.titles.prefix(3)) == ["Put Tool Away", "—", "Flag"])
                #expect(menu.entry("photograph.putToolAway")?.chord == KeyChord("\u{1B}"))
                #expect(Array(menu.titles.dropFirst(2)) == plain, "the rest of the menu follows")
                menu.entry("photograph.putToolAway")?.choose()
                #expect(bench.editor.tool == nil && !bench.editor.isArmed)
                // Escape's step, and only that: the frame stays open, the tab and the masks as they were.
                #expect(bench.model.isFrameOpen && bench.model.adjustTab == .masks && bench.masks.count == 2)
                #expect(bench.editor.brush.target == nil)
            }
            // The same as Escape does to a tool in hand.
            bench.model.perform(.newMask(.radial))
            #expect(bench.editor.escape() && bench.editor.tool == nil)
        }
    }

    @Test func copyAndPasteFollowTheFrameAndTheClipboard() async throws {
        try await withBench { bench in
            var menu = bench.photograph
            #expect(menu.entry("frame.copy")?.isEnabled == true, "the frame has an edit")
            #expect(menu.entry("frame.paste")?.isEnabled == false && menu.entry("frame.pasteOnly")?.isEnabled == false, "nothing copied")
            #expect(menu.entry("frame.pasteOnly")?.children.allSatisfy { !$0.isEnabled } == true)
            menu.entry("frame.copy")?.choose()
            #expect(bench.model.adjustmentsClipboard?.source == bench.frame.url)
            menu = bench.photograph
            #expect(menu.entry("frame.paste")?.isEnabled == true && menu.entry("frame.pasteOnly")?.isEnabled == true)
            // Paste Only offers the parts the clipboard holds: Light and Masks here.
            #expect(menu.entry("frame.pasteOnly.light")?.isEnabled == true && menu.entry("frame.pasteOnly.masks")?.isEnabled == true)
            #expect(menu.entry("frame.pasteOnly.curve")?.isEnabled == false && menu.entry("frame.pasteOnly.frameControls")?.isEnabled == false)

            // A frame with nothing of its own has nothing to copy, and takes a paste.
            bench.model.selection = bench.other.id
            let other = bench.photograph
            #expect(other.entry("frame.copy")?.isEnabled == false && other.entry("frame.paste")?.isEnabled == true)
        }
    }

    /// The comparison and the zoom, as the View menu's items, which are enabled whenever a frame is open.
    @Test func splitCompareIsCheckedWhileOnAndTheZoomIsTheViewMenus() async throws {
        try await withBench { bench in
            let model = bench.model
            #expect(bench.photograph.entry("photograph.split")?.isOn == false)
            bench.photograph.entry("photograph.split")?.choose()
            #expect(model.isSplitComparing && bench.photograph.entry("photograph.split")?.isOn == true)
            bench.photograph.entry("photograph.split")?.choose()
            #expect(!model.isSplitComparing)

            let room = FrameZoom.Room(area: bench.geometry.area, fitted: CGSize(width: 1134, height: 756), fitPixels: 2268, fullPixels: 7008,
                                      displayScale: 2)
            model.frameZoomRoom = room
            model.frameZoom = FrameZoom()
            for id in ["photograph.split", "photograph.fit", "photograph.actualSize"] { #expect(bench.photograph.entry(id)?.isEnabled == true) }
            // Actual Size about where the menu was opened, not the middle as the View menu's.
            let anchor = CGPoint(x: 300, y: 200)
            bench.menu(at: anchor)?.entry("photograph.actualSize")?.choose()
            #expect(model.frameZoom == FrameZoom().actualSize(around: anchor, in: room))
            #expect(model.frameZoom.scale == room.actualScale && model.frameZoom != FrameZoom().stepped(.actualSize, in: room))
            bench.photograph.entry("photograph.fit")?.choose()
            #expect(model.frameZoom == FrameZoom() && model.frameZoom.isFitted)
        }
    }

    /// The point clicked stays under the pointer, as smart zoom keeps it, to a device pixel; from the middle it is the View menu's
    /// Actual Size; zoomed in further or out, it comes to Actual Size about the point; at Actual Size, nothing moves.
    @Test func actualSizeAtThePointerKeepsWhatWasClickedUnderIt() {
        let room = FrameZoom.Room(area: CGSize(width: 1464, height: 880), fitted: CGSize(width: 1320, height: 880), fitPixels: 2640,
                                  fullPixels: 7008, displayScale: 2)
        func spot(_ point: CGPoint, _ zoom: FrameZoom) -> CGPoint {
            CGPoint(x: (point.x - room.area.width / 2 - zoom.offset.width) / (room.fitted.width * zoom.scale),
                    y: (point.y - room.area.height / 2 - zoom.offset.height) / (room.fitted.height * zoom.scale))
        }
        let middle = CGPoint(x: 732, y: 440)
        #expect(FrameZoom().actualSize(around: middle, in: room) == FrameZoom().stepped(.actualSize, in: room))
        for start in [FrameZoom(), FrameZoom().zoomed(to: 4, around: CGPoint(x: 1000, y: 300), in: room).settled(in: room),
                      FrameZoom().zoomed(to: 1.5, around: CGPoint(x: 200, y: 700), in: room).settled(in: room)] {
            let anchor = CGPoint(x: 500, y: 300)
            let actual = start.actualSize(around: anchor, in: room)
            #expect(actual.scale == room.actualScale && actual.pixels(in: room) == 7008 && !actual.isFitted)
            let before = spot(anchor, start), after = spot(anchor, actual)
            // Half a device pixel of the picture, which the offset's whole pixels round to.
            #expect(abs(after.x - before.x) * room.fitted.width * actual.scale <= 0.5)
            #expect(abs(after.y - before.y) * room.fitted.height * actual.scale <= 0.5)
            #expect(actual.actualSize(around: CGPoint(x: 100, y: 800), in: room) == actual, "at Actual Size, nothing moves")
        }
    }

    /// New Mask is the tiles, each as its Mask menu item does it, each enabled by its tile's own rule.
    @Test func newMaskIsTheTilesAsTheMaskMenuMakesThem() async throws {
        try await withBench { bench in
            let model = bench.model
            for (id, tool) in [("brush", MaskEditor.Tool.brush), ("linear", .linear), ("radial", .radial)] {
                model.adjustTab = .light
                let row = try #require(bench.photograph.entry("photograph.newMask.\(id)"))
                #expect(row.isEnabled)
                row.choose()
                #expect(bench.editor.tool == tool && model.adjustTab == .masks, "the tool in hand and the Masks tab, as \(id)'s item does")
                bench.editor.putToolAway()
            }
            // A smart tile that cannot be used here is disabled, as on the tab.
            for kind in [SmartKind.subject, .sky, .person, .background] {
                let tile = try #require(MaskTile.allCases.first { $0.smartKind == kind })
                let enabled = MaskTileAvailability.of(tile, frame: nil, smart: model.smartAvailability(kind)).isEnabled
                #expect(bench.photograph.entry("photograph.newMask.\(tile.rawValue)")?.isEnabled == enabled)
            }
            // When Subject/Background need the downloadable models, their New Mask rows stay enabled and open the licence screen.
            let engine = SessionSmartEngine()
            engine.availabilities = [
                .subject: .needsModels(BundledSmartMasks.needsModels(.subject)),
                .background: .needsModels(BundledSmartMasks.needsModels(.background)),
                .sky: .unavailable("no sky"),
            ]
            model.smartMasks.inference = MaskInference(engine: engine, turns: DecodeTurns())
            #expect(bench.photograph.entry("photograph.newMask.subject")?.isEnabled == true)
            #expect(bench.photograph.entry("photograph.newMask.background")?.isEnabled == true)
            #expect(bench.photograph.entry("photograph.newMask.sky")?.isEnabled == false)
            #expect(bench.photograph.entry("photograph.newMask.person")?.isEnabled == true)
            bench.photograph.entry("photograph.newMask.subject")?.choose()
            #expect(model.subjectModels.isShown && bench.masks.count == 2)
            model.subjectModels.close()
            // A frame that cannot take a mask yet: nothing in New Mask can act.
            model.manualReadySources[bench.frame.url] = nil
            #expect(!model.canAdjust(bench.frame))
            let waiting = try #require(bench.photograph.entry("photograph.newMask"))
            #expect(!waiting.isEnabled && waiting.children.filter { !$0.isDivider }.allSatisfy { !$0.isEnabled })
            // The photograph's menu still opens there: Copy, Paste and the rest do not wait for it.
            #expect(bench.menu(at: Self.away) != nil && bench.photograph.entry("frame.copy")?.isEnabled == true)
        }
    }

    /// The flag, Reset and the frame's files are the frame's menu's own (`FrameMenu`), the same on the photograph as on the sheet.
    @Test func theFramesOwnRowsAreTheFrameMenus() async throws {
        try await withBench { bench in
            let model = bench.model, frame = bench.frame, menu = bench.photograph
            #expect(menu.entry("frame.flag")?.isEnabled == model.canFlag(frame))
            #expect(menu.entry("frame.reset.auto")?.isEnabled == model.canResetManual(frame))
            #expect(menu.entry("frame.reset.original")?.isEnabled == model.canStartFromOriginal(frame))
            #expect(menu.entry("frame.reset.roll")?.isEnabled == model.isOverridden(frame))
            #expect(menu.entry("frame.develop")?.isEnabled == model.canDevelopFrame(frame))
            #expect(menu.entry("frame.showDeveloped")?.isEnabled == (model.developedFile(for: frame) != nil))
            if model.canFlag(frame) {
                bench.choose("frame.flag", in: menu)
                #expect(model.isFlagged(frame) && bench.photograph.entry("frame.flag")?.title == "Unflag")
            }
            bench.choose("frame.reset.auto", in: bench.photograph)
            #expect(!model.hasManualAdjustments(frame) && bench.masks.isEmpty)
        }
    }

    // MARK: A mask's menu on its pin

    @Test func aRightClickOnAPinSelectsItsMaskAndOpensItsMenu() async throws {
        try await withBench { bench in
            let editor = bench.editor, radial = bench.masks[1]
            #expect(editor.selection == nil)
            let menu = try #require(bench.menu(at: bench.pin(1)))
            #expect(editor.selection == MaskEditor.Selection(mask: radial.id, component: nil))
            #expect(menu.titles == ["Radial 1", "Show Overlay", "Invert", "Duplicate", "Turn Off", "Rename", "—", "Delete Mask"])
            if case .heading = menu[0].kind {} else { Issue.record("the name is a heading") }
            #expect(menu.entry("mask.overlay")?.chord == KeyChord("o") && menu.entry("mask.invert")?.chord == KeyChord("'"))
            #expect(menu.entry("mask.delete")?.isDestructive == true)
            // A component chosen in the panel gives way to the mask, as a click on its pin does.
            editor.selection = MaskEditor.Selection(mask: bench.masks[0].id, component: 0)
            #expect(bench.menu(at: bench.pin(0))?.first?.title == "Linear 1")
            #expect(editor.selection == MaskEditor.Selection(mask: bench.masks[0].id, component: nil))
            // Away from the pins, the photograph's, and the selection stays.
            #expect(bench.menu(at: Self.away)?.first?.title == "Flag" && editor.selection?.mask == bench.masks[0].id)
            // Pins hidden by H, or with a tool in hand, take no click: the photograph's menu there.
            editor.togglePins()
            #expect(bench.menu(at: bench.pin(1))?.first?.title == "Flag")
            editor.togglePins()
            bench.model.perform(.newMask(.linear))
            #expect(bench.menu(at: bench.pin(1))?.first?.title == "Put Tool Away")
        }
    }

    @Test func aMasksRowsDoWhatTheMaskMenuAndItsRowDo() async throws {
        try await withBench { bench in
            let editor = bench.editor, model = bench.model, frame = bench.frame
            let id = bench.masks[1].id
            @MainActor func menu() -> [MenuEntry] { bench.menu(at: bench.pin(1)) ?? [] }
            for row in ["mask.overlay", "mask.invert", "mask.duplicate", "mask.switch", "mask.rename", "mask.delete"] {
                #expect(menu().entry(row)?.isEnabled == true, "\(row)")
            }

            // Show Overlay: checked while on, O's toggle.
            #expect(menu().entry("mask.overlay")?.isOn == false)
            menu().entry("mask.overlay")?.choose()
            #expect(editor.isOverlayOn && menu().entry("mask.overlay")?.isOn == true)
            menu().entry("mask.overlay")?.choose()
            #expect(!editor.isOverlayOn)

            bench.choose("mask.invert", in: menu())
            #expect(bench.masks[1].components[0].invert && bench.undo.undoActionName == "Invert Mask")

            bench.choose("mask.switch", in: menu())
            #expect(!bench.masks[1].isEnabled && bench.undo.undoActionName == "Turn Mask Off")
            #expect(menu().entry("mask.switch")?.title == "Turn On")
            bench.choose("mask.switch", in: menu())
            #expect(bench.masks[1].isEnabled && menu().entry("mask.switch")?.title == "Turn Off")

            // Rename: the row's name field open, on the Masks tab, where the pins are.
            menu().entry("mask.rename")?.choose()
            #expect(model.adjustTab == .masks && model.isAdjustmentsShown && editor.renaming == id)
            editor.renaming = nil

            bench.choose("mask.duplicate", in: menu())
            #expect(bench.masks.count == 3 && bench.masks[2].components == bench.masks[1].components)
            let copy = bench.masks[2].id
            #expect(editor.selection?.mask == copy && bench.undo.undoActionName == "Duplicate Mask")
            #expect(model.maskName(copy, for: frame) == "Radial 1 copy")

            // The copy's pin is on its original's, selected and so on top: the menu there is the copy's, as its overlay shows.
            #expect(menu().first?.title == "Radial 1 copy")
            bench.choose("mask.delete", in: menu())
            #expect(bench.masks.count == 2 && !bench.masks.contains { $0.id == copy } && bench.masks[1].id == id)
            #expect(bench.undo.undoActionName == "Delete Mask")
            bench.choose("mask.delete", in: menu())
            #expect(bench.masks.count == 1 && !bench.masks.contains { $0.id == id })
        }
    }

    /// As the row's menu: nothing it offers can be done to a frame that cannot be adjusted, and Duplicate waits for room for one more.
    @Test func aMasksMenuIsDisabledAsItsRowsIsWhileTheFrameCannotBeAdjusted() async throws {
        try await withBench { bench in
            let model = bench.model, id = bench.masks[0].id
            model.manualReadySources[bench.frame.url] = nil
            let menu = PhotographMenu.mask(id, for: bench.frame, model: model)
            for row in ["mask.invert", "mask.duplicate", "mask.switch", "mask.rename", "mask.delete"] {
                #expect(menu.entry(row)?.isEnabled == false, "\(row)")
            }
            // Show Overlay changes no edit, as O changes none.
            #expect(menu.entry("mask.overlay")?.isEnabled == true)
            // And the masks stand down: no pin takes a click, so a right-click there is the photograph's.
            #expect(bench.menu(at: bench.pin(0))?.first?.title == "Flag")
        }
    }

    // MARK: Whose a right-click is

    @Test func theMenuOpensAnywhereOnTheAreaButNeverDuringAGestureOrSpace() async throws {
        try await withBench { bench in
            let editor = bench.editor, model = bench.model, frame = bench.frame
            // On the picture, on the surround beside it, with a tool in hand or none.
            #expect(editor.canvasTakesMenu(at: Self.away) && editor.canvasTakesMenu(at: CGPoint(x: 10, y: 378)))
            #expect(!editor.canvasTakesMenu(at: CGPoint(x: 1200, y: 378)), "off the area")
            model.perform(.newMask(.linear))
            #expect(editor.canvasTakesMenu(at: Self.away))

            // A press under way: the gradient being drawn.
            editor.canvasEvent(MaskCanvasEvent(phase: .press, fractions: bench.geometry.normalized(Self.away), point: Self.away, modifiers: [], clickCount: 1))
            #expect(editor.press != nil && !editor.canvasTakesMenu(at: Self.away) && PhotographMenu.entries(at: Self.away, model: model) == nil)
            editor.cancelPress()
            editor.putToolAway()
            #expect(editor.canvasTakesMenu(at: Self.away))

            // A mask's slider or number, and a Light slider.
            model.beginMaskAdjusting(for: frame)
            #expect(!editor.canvasTakesMenu(at: Self.away))
            model.endMaskAdjusting(for: frame)
            editor.shapeRowBegan()
            #expect(!editor.canvasTakesMenu(at: Self.away))
            editor.shapeRowEnded()
            model.beginLightAdjusting(for: frame)
            #expect(!editor.canvasTakesMenu(at: Self.away))
            model.endLightAdjusting(for: frame)
            #expect(editor.canvasTakesMenu(at: Self.away))

            // Space's neutral raw.
            model.isComparing = true
            #expect(!editor.canvasTakesMenu(at: Self.away))
            model.isComparing = false

            // The split's divider keeps its own pointer; beside it, the film side and the neutral, the menu opens.
            bench.geometry.filmEdge = 500
            for x in [490.0, 500, 510] { #expect(!editor.canvasTakesMenu(at: CGPoint(x: x, y: 378)), "\(x)") }
            #expect(editor.canvasTakesMenu(at: CGPoint(x: 489, y: 378)) && editor.canvasTakesMenu(at: CGPoint(x: 520, y: 378)))
            // Above a letterboxed picture's top the divider has no strip.
            bench.geometry.picture = CGRect(x: 27, y: 100, width: 1134, height: 556)
            #expect(editor.canvasTakesMenu(at: CGPoint(x: 500, y: 50)) && !editor.canvasTakesMenu(at: CGPoint(x: 500, y: 300)))
        }
    }

    @Test func aRightClickOrControlClickIsTheCanvasesWhereItOpensAMenu() async throws {
        try await withBench { bench in
            let canvas = bench.canvas, editor = bench.editor
            // With no tool and off the pins a press is not the canvas's, and a menu click is.
            #expect(canvas.hitTest(Self.away, modifiers: []) == nil)
            #expect(canvas.hitTest(Self.away, modifiers: [], menuClick: true) === canvas)
            #expect(canvas.hitTest(CGPoint(x: 10, y: 378), modifiers: .control, menuClick: true) === canvas, "on the surround too")
            // During Space it is nobody's to open: the frame view's, as a press there is.
            bench.model.isComparing = true
            #expect(canvas.hitTest(Self.away, modifiers: [], menuClick: true) == nil)
            #expect(canvas.menu(for: try rightClick(at: Self.away, in: canvas)) == nil && canvas.menusGiven == 0)
            bench.model.isComparing = false

            // The menu, made at the event: the photograph's, and the keyboard back with the photograph.
            let menu = try #require(canvas.menu(for: try rightClick(at: Self.away, in: canvas)))
            #expect(menu.items.first?.title == "Flag" && canvas.menusGiven == 1 && bench.keyboardRequests == 1)
            #expect(menu.items.first { $0.title == "Actual Size" }?.keyEquivalent == "0")
            // Never kept as the view's menu, which AppKit would search for its keys: the menu bar binds them.
            #expect(canvas.menu == nil && !menu.autoenablesItems)

            // On a pin, its mask's, the mask selected.
            let onPin = try #require(canvas.menu(for: try rightClick(at: bench.pin(0), in: canvas)))
            #expect(onPin.items.first?.title == "Linear 1" && editor.selection?.mask == bench.masks[0].id)
            #expect(onPin.items.first { $0.title == "Show Overlay" }?.state == .off)
        }
    }

    /// AppKit asks a view's menu for a Control-click before it sends the press, opens the menu in its place, and sends the press only
    /// when it gets none (measured through `NSWindow.sendEvent` on a shown window: on the base commit a Control-click with a Linear or the
    /// brush in hand reached the canvas's `mouseDown` and was a press). So the canvas gives the menu, and a press that comes anyway is none.
    /// Called on the canvas, as AppKit calls it, rather than through a window, which would have to be shown with its menu.
    @Test func aControlClickWithAToolInHandIsTheMenuNeverAPress() async throws {
        try await withBench { bench in
            let canvas = bench.canvas, editor = bench.editor
            @MainActor func click(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = .control) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(Self.away, to: nil), modifierFlags: flags,
                                                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                                                pressure: type == .leftMouseUp ? 0 : 1))
            }
            for command in [MaskCommand.newMask(.linear), .newMask(.brush)] {
                bench.model.perform(command)
                let counts = editor.canvasCounts
                // The canvas is the view AppKit asks, and what it asks for is the menu, Put Tool Away first.
                #expect(canvas.hitTest(Self.away, modifiers: .control, menuClick: true) === canvas)
                #expect(canvas.menu(for: try click(.leftMouseDown))?.items.first?.title == "Put Tool Away")
                // A press with Control, were it ever sent, draws nothing, paints no dab and places nothing.
                canvas.mouseDown(with: try click(.leftMouseDown))
                canvas.mouseDragged(with: try click(.leftMouseDragged))
                canvas.mouseUp(with: try click(.leftMouseUp))
                #expect(editor.canvasCounts == counts && editor.press == nil && !editor.brush.isPainting)
                #expect(bench.masks.count == 2 && editor.isArmed, "the tool stays in hand")

                // During Space there is no menu, and AppKit sends the press, which is still none.
                bench.model.isComparing = true
                #expect(canvas.menu(for: try click(.leftMouseDown)) == nil)
                canvas.mouseDown(with: try click(.leftMouseDown))
                canvas.mouseUp(with: try click(.leftMouseUp))
                #expect(editor.canvasCounts == counts)
                bench.model.isComparing = false

                // A plain click is still the tool's.
                canvas.mouseDown(with: try click(.leftMouseDown, flags: []))
                canvas.mouseUp(with: try click(.leftMouseUp, flags: []))
                #expect(editor.canvasCounts.press == counts.press + 1)
                editor.cancelPress()
                editor.putToolAway()
            }
        }
    }

    // MARK: VoiceOver

    @Test func voiceOversCopyAndPasteAreTheMenus() async throws {
        try await withBench { bench in
            let model = bench.model
            PhotographMenu.copyForVoiceOver(bench.other, model: model)
            #expect(model.adjustmentsClipboard == nil, "the other frame has nothing to copy")
            PhotographMenu.pasteForVoiceOver(bench.other, model: model)
            #expect(model.clipboardNotice == nil, "nothing copied to paste")
            PhotographMenu.copyForVoiceOver(bench.frame, model: model)
            #expect(model.adjustmentsClipboard?.source == bench.frame.url)
        }
    }

    // MARK: The rule

    @Test func whatIsAMenuClick() throws {
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseDragged, .rightMouseUp] { #expect(MaskEditor.isMenuClick(try event(type))) }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            #expect(MaskEditor.isMenuClick(try event(type, .control)))
            #expect(MaskEditor.isMenuClick(try event(type, [.control, .option])))
            #expect(!MaskEditor.isMenuClick(try event(type)))
            #expect(!MaskEditor.isMenuClick(try event(type, [.command, .option, .shift])))
        }
        #expect(!MaskEditor.isMenuClick(try event(.mouseMoved, .control)) && !MaskEditor.isMenuClick(nil))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        #expect(!MaskEditor.isMenuClick(key))
    }

    private func rightClick(at point: CGPoint, in canvas: MaskCanvasView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                        windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
