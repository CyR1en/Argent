import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI
import Testing
@testable import ArgentApp

/// A frame's menu (`FrameMenu`) on the sheet, the filmstrip and the photograph, and the sheet's ground (`SheetMenu`):
/// their rows and order, what each row's enabled state follows, and that a row does what the menu bar's item does.
/// Then the sheet's own: a right-click or a Control-click on a cell selects it before its menu is made, the ground
/// opens its own, and nothing of either is read as a cell is drawn. No menu is shown (`ContextMenuTests.ShownMenus`).
@MainActor @Suite(.serialized) struct FrameMenuTests {
    typealias Fixture = AutoDecisionStateTests.Fixture

    /// The Auto suite's roll of eight frames, opened in a model with its own library.
    static func withModel(_ body: (RollModel, [Frame], Fixture) async throws -> Void) async throws {
        try await FlagStateTests.withRoll { fixture in
            let model = FlagStateTests.model(fixture), gate = MeasurementGate()
            let frames = try await FlagStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            try await body(model, frames, fixture)
        }
    }

    /// An edit of `adjustments` on an Auto pin, as a first change by hand leaves one.
    static func edit(_ adjustments: ManualAdjustments) -> ManualEdit {
        let pin = AutomaticBaseline(sourceSHA256: "test", stockID: "toy", stockDigest: "digest", controls: .init(),
                                    aim: PrintAim(level: -0.65, cast: SIMD3(0.2, -0.1, 0.15)), analysisVersion: ExposureAnalysis.currentVersion,
                                    baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        return ManualEdit(adjustments: adjustments, baseline: pin)
    }

    /// Each row's enabled state by its id, submenus' rows included.
    static func enabled(_ entries: [MenuEntry]) -> [String: Bool] {
        var states: [String: Bool] = [:]
        func walk(_ entries: [MenuEntry]) {
            for entry in entries where !entry.isDivider {
                states[entry.id] = entry.isEnabled
                walk(entry.children)
            }
        }
        walk(entries)
        return states
    }

    static let sheetRows = ["Open Frame", "Flag", "—", "Copy Adjustments", "Paste Adjustments", "Paste Only",
                            "Save Look as Preset…", "Look Presets…", "Paste to All Frames", "—",
                            "Reset", "—", "Develop This Frame…", "Show RAW in Finder", "Show Developed File in Finder"]
    /// The sheet's own last section: the frame leaves the roll (`FrameMenu.roll`).
    static let rollRows = ["—", "Move to Roll", "Remove from Roll…"]

    @Test func aFramesMenuHasItsRowsInOrderOnEachSurface() async throws {
        try await Self.withModel { model, frames, _ in
            let sheet = FrameMenu.entries(for: frames[1], on: .sheet, model: model)
            #expect(sheet.titles == Self.sheetRows + Self.rollRows)
            #expect(FrameMenu.entries(for: frames[1], on: .filmstrip, model: model).titles == Array(Self.sheetRows.dropFirst()))
            #expect(FrameMenu.entries(for: frames[1], on: .photograph, model: model).titles
                    == Self.sheetRows.filter { $0 != "Open Frame" && $0 != "Paste to All Frames" })
            #expect(sheet.entry("frame.pasteOnly")?.children.titles == ["Light", "Presence", "Curve", "Masks", "Lens", "Rated At and Lab Balance",
                                                                          "Film Stock, Grain and Halation"])
            #expect(sheet.entry("frame.reset")?.children.titles == ["Reset to Current Auto", "Reset to Original", "Same as Roll"])
            // The menu bar's keys, shown beside its words.
            #expect(sheet.compactMap { $0.chord?.symbols } == ["⌘\u{F701}", "F", "⌥⌘C", "⌥⌘V", "⌥⇧⌘V", FrameKeys.remove.symbols])
            #expect(sheet.allSatisfy { $0.isOn == nil })
        }
    }

    /// Each row is enabled as what it does can be done: Copy for a frame with an edit or its own Rated at or Lab balance,
    /// Paste and its parts for what the clipboard holds, the batch for frames shown other than the source, the resets for
    /// what there is to reset, Develop This Frame as Develop, the developed file while there is one; nothing while a roll
    /// opens. A disabled row stays, so the menu keeps its shape.
    #if DEBUG
    @Test func eachRowIsEnabledAsTheFramesStateAllows() async throws {
        try await Self.withModel { model, frames, _ in
            @MainActor func states(_ frame: Frame, _ surface: FrameMenu.Surface = .sheet) -> [String: Bool] {
                Self.enabled(FrameMenu.entries(for: frame, on: surface, model: model))
            }
            // A frame as Auto left it, nothing copied.
            var fresh = states(frames[1])
            #expect(fresh.removeValue(forKey: "frame.reset.original") == model.canStartFromOriginal(frames[1]))
            #expect(fresh == ["frame.open": true, "frame.flag": true, "frame.copy": false, "frame.paste": false,
                              "frame.pasteOnly": false, "frame.pasteOnly.light": false, "frame.pasteOnly.presence": false,
                              "frame.pasteOnly.curve": false,
                              "frame.pasteOnly.masks": false, "frame.pasteOnly.lens": false, "frame.pasteOnly.frameControls": false,
                              "frame.pasteOnly.film": false, "frame.pasteToShown": false,
                              "frame.savePreset": model.canSavePreset(from: frames[1]), "frame.lookPresets": true,
                              "frame.bakeStock": model.canBakeFrameAsStock(frames[1]),
                              "frame.reset": true, "frame.reset.auto": false, "frame.reset.roll": false,
                              "frame.develop": true, "frame.showRAW": true, "frame.showDeveloped": false,
                              "frames.move": true, "frames.move.new": true, "frames.remove": true])

            // Its own Rated at: there is something to copy, and to make the same as the roll.
            model.setRatedAt(.oneStopUnder, for: frames[0])
            #expect(states(frames[0])["frame.copy"] == true && states(frames[0])["frame.reset.roll"] == true)
            #expect(states(frames[0])["frame.reset.auto"] == false)
            // An edit: to copy, and to reset to Auto.
            model.manualEdits[frames[2].url] = Self.edit(try ManualAdjustments(exposureEV: 0.5))
            #expect(states(frames[2])["frame.copy"] == true && states(frames[2])["frame.reset.auto"] == true)
            #expect(states(frames[2])["frame.reset.roll"] == false)

            // Light copied: Paste and Paste Only's Light, and the batch, on the other frames.
            model.copyAdjustments(from: frames[2])
            let pasting = states(frames[1])
            #expect(pasting["frame.paste"] == true && pasting["frame.pasteOnly"] == true && pasting["frame.pasteToShown"] == true)
            #expect(pasting["frame.pasteOnly.light"] == true && pasting["frame.pasteOnly.curve"] == false)
            #expect(pasting["frame.pasteOnly.presence"] == false)
            #expect(pasting["frame.pasteOnly.masks"] == false && pasting["frame.pasteOnly.frameControls"] == false)
            // Rated at copied: its part alone.
            model.copyAdjustments(from: frames[0])
            let controls = states(frames[1])
            #expect(controls["frame.pasteOnly.frameControls"] == true && controls["frame.pasteOnly.light"] == false)
            #expect(controls["frame.pasteOnly.film"] == false)

            // The batch pastes on the frames shown, never on the source: with the source the only one shown, nothing.
            model.setFlag(true, for: frames[0])
            model.showFrames(.flagged)
            #expect(states(frames[0])["frame.pasteToShown"] == false && states(frames[0], .filmstrip)["frame.pasteToShown"] == false)
            model.showFrames(.all)

            // A flagged frame's row reads Unflag.
            #expect(FrameMenu.entries(for: frames[0], on: .sheet, model: model).entry("frame.flag")?.title == "Unflag")
            #expect(FrameMenu.entries(for: frames[1], on: .sheet, model: model).entry("frame.flag")?.title == "Flag")

            // While a develop runs, another cannot start.
            model.developPhase = .developing(DevelopProgress(total: 1))
            #expect(states(frames[1])["frame.develop"] == false)
            model.developPhase = .idle

            // While a roll opens, nothing that changes a frame.
            model.holdReadingForDebug()
            let opening = states(frames[2])
            for id in ["frame.flag", "frame.copy", "frame.paste", "frame.pasteOnly", "frame.pasteOnly.light", "frame.pasteToShown",
                       "frame.savePreset", "frame.bakeStock", "frame.lookPresets", "frame.reset.auto", "frame.develop"] {
                #expect(opening[id] == false, "\(id)")
            }
            #expect(opening["frame.showRAW"] == true)
        }
    }
    #endif

    /// Each row calls what the menu bar's item calls, on the menu's frame rather than the selected one.
    @Test func choosingARowDoesWhatTheMenuBarsItemDoes() async throws {
        try await Self.withModel { model, frames, _ in
            @MainActor func choose(_ id: String, _ frame: Frame, _ surface: FrameMenu.Surface = .sheet) throws {
                try #require(FrameMenu.entries(for: frame, on: surface, model: model).entry(id)).choose()
            }
            model.selection = frames[0].id
            // Flag, as Frame > Flag: this frame's, not the selected one's.
            try choose("frame.flag", frames[4], .filmstrip)
            #expect(model.isFlagged(frames[4]) && !model.isFlagged(frames[0]))
            try choose("frame.flag", frames[4])
            #expect(!model.isFlagged(frames[4]))

            // Copy Adjustments, as Edit > Copy Adjustments.
            model.setRatedAt(.oneStopUnder, for: frames[3])
            try choose("frame.copy", frames[3], .filmstrip)
            #expect(model.adjustmentsClipboard?.source == frames[3].url)
            // Paste Adjustments and the batch, as Edit's: each says what it did.
            model.dismissClipboardNotice()
            try choose("frame.paste", frames[5])
            #expect(model.clipboardNotice != nil)
            model.dismissClipboardNotice()
            try choose("frame.pasteToShown", frames[5], .filmstrip)
            #expect(model.clipboardNotice != nil)
            model.dismissClipboardNotice()

            // Frame > Same as Roll and Reset to Current Auto, for this frame.
            try choose("frame.reset.roll", frames[3])
            #expect(!model.isOverridden(frames[3]))
            model.manualEdits[frames[6].url] = Self.edit(try ManualAdjustments(exposureEV: -0.3))
            try choose("frame.reset.auto", frames[6], .filmstrip)
            #expect(!model.hasManualAdjustments(frames[6]))

            // Develop This Frame…: the quick develop dialog for this frame alone, and from its Develop the frame into the
            // roll's folder, without the Develop page.
            let jobs = FlagStateTests.capture(model)
            model.chooseDestination(model.roll!.folder.appendingPathComponent("Export"))
            try choose("frame.develop", frames[2], .filmstrip)
            #expect(model.quickDevelop?.frames == [frames[2].url] && model.developTask == nil && jobs.runs.isEmpty)
            await FlagStateTests.develop(model) { model.confirmQuickDevelop() }
            #expect(jobs.runs.last?.map(\.frame.url) == [frames[2].url] && model.workspacePage == .roll && model.quickDevelop == nil)
            model.observeDevelopJobs = nil

            // Open Frame, as Frame > Open Frame: on the sheet only, and this frame.
            #expect(FrameMenu.entries(for: frames[7], on: .filmstrip, model: model).entry("frame.open") == nil)
            try choose("frame.open", frames[7])
            #expect(model.selection == frames[7].id && model.isFrameOpen)
        }
    }

    /// The batch's title follows the filter, as Develop's count does, on a frame's menu and the sheet's ground alike.
    @Test func theBatchRowsTitleFollowsTheFilter() async throws {
        try await Self.withModel { model, frames, _ in
            model.setFlag(true, for: frames[1])
            for (filter, title) in [(FlagFilter.all, "Paste to All Frames"), (.flagged, "Paste to Flagged Frames"),
                                    (.unflagged, "Paste to Unflagged Frames")] {
                model.showFrames(filter)
                for surface in [FrameMenu.Surface.sheet, .filmstrip] {
                    #expect(FrameMenu.entries(for: frames[1], on: surface, model: model).entry("frame.pasteToShown")?.title == title)
                }
                #expect(SheetMenu.ground(model: model).entry("sheet.pasteToShown")?.title == title)
            }
        }
    }

    #if DEBUG
    @Test func theSheetsGroundHasTheViewAndRollMenusRowsAndDoesWhatTheyDo() async throws {
        try await Self.withModel { model, frames, _ in
            var ground = SheetMenu.ground(model: model)
            #expect(ground.titles == ["Show", "All Frames", "Flagged", "Unflagged", "—", "Larger Thumbnails", "Smaller Thumbnails",
                                      "Gray Surround", "—", "Paste to All Frames", "—", "Develop…", "Show Roll in Finder"])
            #expect(ground.compactMap { $0.chord?.symbols } == ["⌃⌘0", "⌃⌘1", "⌃⌘2", "⌘+", "⌘-", "⇧⌘G", "⌥⇧⌘V", "⌘D"])
            #expect(ground.map(\.isOn) == [nil, true, false, false, nil, nil, nil, false, nil, nil, nil, nil, nil])
            #expect(Self.enabled(ground) == ["sheet.show": false, "sheet.show.all": true, "sheet.show.flagged": true,
                                             "sheet.show.unflagged": true, "sheet.larger": true, "sheet.smaller": true,
                                             "sheet.graySurround": true, "sheet.pasteToShown": false, "sheet.develop": true,
                                             "sheet.showRoll": true])

            // View > Show: the filter, the one in force checked. On the sheet Develop… opens the Develop page whatever
            // shows; on that page's grid Develop counts the frames it shows, as the page's button does.
            model.setFlag(true, for: frames[2])
            model.setFlag(true, for: frames[5])
            try #require(ground.entry("sheet.show.flagged")).choose()
            ground = SheetMenu.ground(model: model)
            #expect(model.flagFilter == .flagged && ground.entry("sheet.show.flagged")?.isOn == true)
            #expect(ground.entry("sheet.show.all")?.isOn == false && ground.entry("sheet.develop")?.title == "Develop…")
            model.showDevelopPage()
            #expect(SheetMenu.ground(model: model).entry("sheet.develop")?.title == "Develop 2")
            // None shown: Develop as the button has it, and disabled; on the sheet the page still opens.
            model.setFlag(false, for: frames[2])
            model.setFlag(false, for: frames[5])
            ground = SheetMenu.ground(model: model)
            #expect(ground.entry("sheet.develop")?.title == "Develop" && ground.entry("sheet.develop")?.isEnabled == false)
            model.closeDevelopPage()
            ground = SheetMenu.ground(model: model)
            #expect(ground.entry("sheet.develop")?.title == "Develop…" && ground.entry("sheet.develop")?.isEnabled == true)
            try #require(ground.entry("sheet.show.all")).choose()
            #expect(model.flagFilter == .all)

            // The thumbnails' size, to its ends.
            let step = model.sizeStep
            try #require(SheetMenu.ground(model: model).entry("sheet.larger")).choose()
            #expect(model.sizeStep == step + 1)
            while model.canChangeSize(by: 1) { model.changeSize(by: 1) }
            #expect(SheetMenu.ground(model: model).entry("sheet.larger")?.isEnabled == false)
            try #require(SheetMenu.ground(model: model).entry("sheet.smaller")).choose()
            #expect(model.sizeStep == Metrics.thumbnailWidths.count - 2)
            while model.canChangeSize(by: -1) { model.changeSize(by: -1) }
            #expect(SheetMenu.ground(model: model).entry("sheet.smaller")?.isEnabled == false)

            // Gray Surround, a switch.
            let gray = model.graySurround
            try #require(SheetMenu.ground(model: model).entry("sheet.graySurround")).choose()
            #expect(model.graySurround == !gray && SheetMenu.ground(model: model).entry("sheet.graySurround")?.isOn == !gray)
            model.graySurround = gray

            // The batch, with something copied to paste.
            model.setRatedAt(.oneStopUnder, for: frames[0])
            model.copyAdjustments(from: frames[0])
            #expect(SheetMenu.ground(model: model).entry("sheet.pasteToShown")?.isEnabled == true)

            // Roll > Develop: the Develop page, where the filter still chooses the frames; nothing develops yet.
            try #require(SheetMenu.ground(model: model).entry("sheet.develop")).choose()
            #expect(model.workspacePage == .develop && model.developTask == nil)
            #expect(SheetMenu.ground(model: model).entry("sheet.show.flagged")?.isEnabled == true)
            model.closeDevelopPage()
            #expect(model.workspacePage == .roll)

            // While a roll opens, Develop cannot start.
            model.holdReadingForDebug()
            #expect(SheetMenu.ground(model: model).entry("sheet.develop")?.isEnabled == false)
            #expect(SheetMenu.ground(model: model).entry("sheet.pasteToShown")?.isEnabled == false)
        }
    }
    #endif

    /// The sheet's arithmetic finds the cell under a point, its picture or its name, and none on the ground between and
    /// round the cells, where the ground's menu opens.
    @Test func aPointFindsTheCellUnderItAndTheGroundElsewhere() {
        let geometry = SheetGeometry(width: 1000, targetCell: 168)
        let count = geometry.columns * 3 - 1
        for index in 0..<count {
            let cell = geometry.frame(ofItem: index)
            #expect(geometry.item(at: CGPoint(x: cell.midX, y: cell.midY), count: count) == index)
            #expect(geometry.item(at: CGPoint(x: cell.minX + 1, y: cell.maxY - 1), count: count) == index, "its name")
            #expect(geometry.item(at: CGPoint(x: cell.maxX + ContactSheet.Spacing.gutter / 2, y: cell.midY), count: count) == nil)
            #expect(geometry.item(at: CGPoint(x: cell.midX, y: cell.maxY + ContactSheet.Spacing.rowGap / 2), count: count) == nil)
        }
        let first = geometry.frame(ofItem: 0), last = geometry.frame(ofItem: count - 1)
        #expect(geometry.item(at: CGPoint(x: first.minX - 2, y: first.midY), count: count) == nil)
        #expect(geometry.item(at: CGPoint(x: first.midX, y: first.minY - 2), count: count) == nil)
        // Where a whole last row would have its last cell, and under the last row.
        #expect(geometry.item(at: CGPoint(x: last.maxX + ContactSheet.Spacing.gutter + 10, y: last.midY), count: count) == nil)
        #expect(geometry.item(at: CGPoint(x: last.midX, y: last.maxY + 40), count: count) == nil)
        #expect(geometry.item(at: CGPoint(x: geometry.width - 1, y: first.midY), count: count) == nil)
    }

    /// The roll's sheet in a window: its collection view, once it has laid out every cell it shows.
    static func sheet(_ model: RollModel, size: NSSize) throws -> (NSWindow, NSView, NSCollectionView) {
        let roll = try #require(model.roll)
        let (window, host) = ContextMenuTests.window(ContactSheet(roll: roll).environment(model), size: size)
        @MainActor func find(_ view: NSView) -> NSCollectionView? {
            (view as? NSCollectionView) ?? view.subviews.lazy.compactMap(find).first
        }
        var collection: NSCollectionView?
        for _ in 0..<100 {
            ContextMenuTests.settle(host, turns: 1)
            if let found = find(host), found.numberOfItems(inSection: 0) == roll.frames.count, !found.visibleItems().isEmpty {
                collection = found
                break
            }
        }
        return (window, host, try #require(collection, "the sheet laid out no cells"))
    }

    /// Where cell `index` is in the window: the middle of its picture.
    static func point(ofCell index: Int, in collection: NSCollectionView) -> NSPoint {
        let cell = frame(ofCell: index, in: collection)
        return collection.convert(NSPoint(x: cell.midX, y: cell.minY + cell.width / 3), to: nil)
    }

    static func frame(ofCell index: Int, in collection: NSCollectionView) -> NSRect {
        collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame ?? .zero
    }

    /// A right-click or a Control-click on a cell selects it first, as Finder does, so the ring shows what the menu is
    /// for, then makes its frame's menu; on the ground, the sheet's own, the selection left. A row chosen acts on that frame.
    @Test func aClickForAMenuOnTheSheetSelectsItsCellFirstAndTheGroundHasItsOwn() async throws {
        try await Self.withModel { model, frames, _ in
            model.selection = frames[0].id
            // Taller than the roll's rows, so there is sheet under the last of them.
            let (window, _, collection) = try Self.sheet(model, size: NSSize(width: 700, height: 900))
            defer { window.close() }
            let shown = ContextMenuTests.ShownMenus()
            defer { shown.stop() }
            shown.noting = { "selection \(model.selection.map(String.init) ?? "none")" }

            try ContextMenuTests.click(.rightMouseDown, at: Self.point(ofCell: 3, in: collection), in: window)
            #expect(shown.noted == ["selection 3"])
            #expect(shown.rows.first == ["Open Frame ⌘\u{F701}", "Flag F", "—", "Copy Adjustments ⌥⌘C", "Paste Adjustments ⌥⌘V",
                                         "Paste Only", "Save Look as Preset…", "Look Presets…", "Paste to All Frames ⌥⇧⌘V",
                                         "—", "Reset", "—", "Develop This Frame…",
                                         "Show RAW in Finder", "Show Developed File in Finder", "—", "Move to Roll",
                                         "Remove from Roll… ⌘\(String(FrameKeys.remove.key).uppercased())"])
            // Its Flag is that frame's.
            let menu = try #require(shown.menus.first)
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Flag"))
            #expect(model.isFlagged(frames[3]))

            // A Control-click, on another cell.
            try ContextMenuTests.click(.leftMouseDown, at: Self.point(ofCell: 5, in: collection), flags: .control, in: window)
            #expect(shown.noted == ["selection 3", "selection 5"] && shown.rows.count == 2)
            #expect(shown.rows.last?.first == "Open Frame ⌘\u{F701}")

            // The ground between two cells, and under the last row: the sheet's menu; the selection stays.
            let first = Self.frame(ofCell: 0, in: collection)
            let gutter = collection.convert(NSPoint(x: first.maxX + ContactSheet.Spacing.gutter / 2, y: first.midY), to: nil)
            try ContextMenuTests.click(.rightMouseDown, at: gutter, in: window)
            let last = Self.frame(ofCell: frames.count - 1, in: collection)
            let under = collection.convert(NSPoint(x: collection.bounds.midX, y: last.maxY + 160), to: nil)
            try ContextMenuTests.click(.leftMouseDown, at: under, flags: .control, in: window)
            #expect(shown.noted == ["selection 3", "selection 5", "selection 5", "selection 5"])
            #expect(shown.rows.count == 4 && shown.rows[2] == shown.rows[3])
            #expect(shown.rows[2].prefix(4) == ["Show", "All Frames ⌃⌘0", "Flagged ⌃⌘1", "Unflagged ⌃⌘2"])
            #expect(shown.rows[2].last == "Show Roll in Finder")
        }
    }

    /// The sheet's scrolling reads nothing a menu asks (docs/M2-shell.md, The contact sheet's scrolling): no menu is made
    /// as cells are drawn or recycled, and a change to the clipboard draws no cell again, where a flag draws its own.
    #if DEBUG
    @Test func noCellIsDrawnAgainWhenTheClipboardChangesAndNoMenuIsMadeAsTheSheetScrolls() async throws {
        try await Self.withModel { model, frames, _ in
            let urls = Set(frames.map(\.url))
            @MainActor func drawn() -> [URL: Int] { SheetProbe.cellsDrawn.filter { urls.contains($0.key) } }
            @MainActor func menusMade() -> Int { FrameMenu.made.filter { urls.contains($0.key) }.values.reduce(0, +) }
            model.setRatedAt(.oneStopUnder, for: frames[0])
            model.manualEdits[frames[1].url] = Self.edit(try ManualAdjustments(exposureEV: 0.4))
            let (window, host, collection) = try Self.sheet(model, size: NSSize(width: 420, height: 300))
            defer { window.close() }
            ContextMenuTests.settle(host)
            let settled = drawn()
            #expect(!settled.isEmpty && menusMade() == 0)

            model.copyAdjustments(from: frames[1])
            ContextMenuTests.settle(host)
            model.copyAdjustments(from: frames[0])
            ContextMenuTests.settle(host)
            model.adjustmentsClipboard = nil
            model.dismissClipboardNotice()
            ContextMenuTests.settle(host)
            #expect(drawn() == settled)

            // What makes this a test of anything: a flag draws its own cell again.
            model.setFlag(true, for: frames[0])
            ContextMenuTests.settle(host)
            #expect(drawn()[frames[0].url] ?? 0 > settled[frames[0].url] ?? 0)

            // Scrolled to the foot and back: cells are drawn for other frames; no menu is made.
            let scroller = try #require(collection.enclosingScrollView)
            let before = drawn().values.reduce(0, +)
            for y in [collection.bounds.height, 0] {
                scroller.contentView.scroll(to: NSPoint(x: 0, y: max(0, y - scroller.contentView.bounds.height)))
                scroller.reflectScrolledClipView(scroller.contentView)
                ContextMenuTests.settle(host)
            }
            #expect(drawn().values.reduce(0, +) > before, "the sheet did not scroll")
            #expect(menusMade() == 0)
        }
    }
    #endif
}
