import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import SwiftUI
import Testing
@testable import ArgentApp

/// The Adjust inspector's context menus (docs/context-menus-plan.md, section 3): each table's rows, their order and when each is
/// enabled, and that choosing a row does what the control it stands for does, as that control's one undo step with its name; that a
/// right-click selects its row first and draws the table the row's ⋯ draws; and that no table is made until its menu is asked for.
@MainActor @Suite(.serialized) struct InspectorMenuTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    /// An open frame with an edit (Exposure +0.5), ready to adjust, on the tab asked for, with an undo manager the test groups.
    @MainActor final class Bench {
        let model: RollModel, frame: Frame, undo: UndoManager

        init(model: RollModel, frame: Frame, undo: UndoManager) {
            self.model = model
            self.frame = frame
            self.undo = undo
        }

        var editor: MaskEditor { model.maskEditor }
        var masks: [Mask] { model.masks(for: frame) }

        /// A step of the model's, as one group, as one turn of the event loop is.
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }

        /// Chooses the row `id`, which must be enabled, as one group.
        func choose(_ id: String, in entries: [MenuEntry]) throws {
            let entry = try #require(entries.entry(id), "no row \(id)")
            #expect(entry.isEnabled, "\(id) is disabled")
            step { entry.choose() }
        }

        /// A gradient placed by Return, as one step, and selected.
        @discardableResult func placeMask(_ tool: MaskEditor.Tool = .linear) throws -> Mask {
            model.perform(.newMask(tool))
            var placed = false
            step { placed = model.placeArmedGradient() }
            #expect(placed)
            return try #require(masks.last)
        }

        /// A component added to the selected mask, as one step.
        func addComponent(_ tool: MaskEditor.Tool, _ operation: MaskOperation) {
            model.perform(.addShape(tool, operation))
            step { _ = model.placeArmedGradient() }
        }

        /// An issue holds the frame, so it cannot be adjusted.
        func block(_ blocked: Bool) {
            model.manualPreparationErrors[frame.url] = blocked ? "Could not prepare adjustments: test" : nil
        }
    }

    private func withBench(tab: AdjustInspectorTab = .masks, _ body: @MainActor (Bench) async throws -> Void) async throws {
        let shown = UserDefaults.standard.object(forKey: "manualInspectorShown"), stored = UserDefaults.standard.object(forKey: AdjustInspectorTab.storageKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-inspector-menus-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults.standard.set(shown, forKey: "manualInspectorShown")
            UserDefaults.standard.set(stored, forKey: AdjustInspectorTab.storageKey)
        }
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
        model.manualEdits[frame.url] = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5), baseline: pin)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.manualUndoManager = undo
        model.adjustTab = tab
        model.isInspectorPresenceExpanded = true
        model.isAdjustmentsShown = true
        defer { model.maskEditor.reset() }
        #expect(model.canAdjust(frame))
        try await body(Bench(model: model, frame: frame, undo: undo))
    }

    // MARK: A window to draw in

    /// `view` drawn in a window of its own, laid out until `ready` holds.
    private func host(_ view: some View, width: CGFloat = 280, height: CGFloat = 1400,
                      until ready: (NSView) -> Bool) async throws -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        let root = try #require(window.contentView)
        for _ in 0..<300 {
            root.layoutSubtreeIfNeeded()
            if ready(root) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return window
    }

    /// Lets SwiftUI apply what a step changed.
    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func views<T: NSView>(_ type: T.Type, under view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, under: $0) }
    }

    /// A press of `type` at `point` in `window`. Never posted to the application: an event posted and taken back leaves the test
    /// process's run loop stopped, and the process exits at the next await, quietly, as if every test had run (measured: `exit` from
    /// `swift_task_asyncMainDrainQueue`). A row's catcher is handed it as the press being handled (`RowMenuView.currentEvent`).
    private func press(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The window's own answer to which view takes a press at `point`.
    private func hit(_ point: NSPoint, in window: NSWindow) -> NSView? {
        window.contentView?.superview?.hitTest(point)
    }

    /// Whether the press at `point` is `view`'s: a Bool, so a failure does not print a hosting view's whole tree.
    private func lands(at point: NSPoint, on view: NSView, in window: NSWindow) -> Bool { hit(point, in: window) === view }

    private static func centre(of view: NSView) -> NSPoint {
        let frame = view.convert(view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// A menu's rows as the tables' tests read them: titles, a separator as "—", and which are enabled.
    private static func rows(_ menu: NSMenu?) -> [String] { menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? [] }
    private static func enabled(_ menu: NSMenu?) -> [Bool] { menu?.items.filter { !$0.isSeparatorItem }.map(\.isEnabled) ?? [] }
    private static func enabled(_ entries: [MenuEntry]) -> [Bool] { entries.filter { !$0.isDivider }.map(\.isEnabled) }

    private func rightClick(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try press(.rightMouseDown, at: point, in: window)
    }

    // MARK: A mask's row

    @Test func aMasksRowHoldsWhatItsMenuHeldInItsOrder() async throws {
        try await withBench { bench in
            let mask = try bench.placeMask()
            let table = { @MainActor (canAdjust: Bool, canDuplicate: Bool) in
                InspectorMenus.maskRow(bench.model.mask(mask.id, for: bench.frame)!, frame: bench.frame, canAdjust: canAdjust,
                                       canDuplicate: canDuplicate, model: bench.model)
            }
            #expect(table(true, true).titles == ["Rename", "Invert", "Duplicate", "Turn Off", "—", "Delete"])
            #expect(table(true, true).map(\.id) == ["mask.rename", "mask.invert", "mask.duplicate", "mask.turn", "divider.4", "mask.delete"])
            #expect(Self.enabled(table(true, true)) == [true, true, true, true, true])
            // Duplicate waits for room for another mask; nothing can be done to a frame that cannot be adjusted.
            #expect(Self.enabled(table(true, false)) == [true, true, false, true, true])
            #expect(Self.enabled(table(false, true)) == [false, false, false, false, false])
            // Off, it offers to turn the mask on.
            try bench.choose("mask.turn", in: table(true, true))
            #expect(table(true, true).titles == ["Rename", "Invert", "Duplicate", "Turn On", "—", "Delete"])
        }
    }

    /// Each row does what the ⋯'s button did, through the same call, as one step of that call's name.
    @Test func choosingAMasksRowDoesWhatItsControlDoesAsOneStep() async throws {
        try await withBench { bench in
            let mask = try bench.placeMask()
            let id = mask.id
            @MainActor func table() -> [MenuEntry] {
                InspectorMenus.maskRow(bench.model.mask(id, for: bench.frame)!, frame: bench.frame, canAdjust: true, canDuplicate: true,
                                       model: bench.model)
            }
            bench.editor.selection = nil

            try bench.choose("mask.turn", in: table())
            #expect(bench.model.mask(id, for: bench.frame)?.isEnabled == false && bench.undo.undoActionName == "Turn Mask Off")
            try bench.choose("mask.turn", in: table())
            #expect(bench.model.mask(id, for: bench.frame)?.isEnabled == true && bench.undo.undoActionName == "Turn Mask On")

            // Invert selects the row first, as the ⋯'s did, and inverts its first component.
            bench.editor.selection = nil
            try bench.choose("mask.invert", in: table())
            #expect(bench.editor.selection == MaskEditor.Selection(mask: id, component: nil))
            #expect(bench.model.mask(id, for: bench.frame)?.components[0].invert == true && bench.undo.undoActionName == "Invert Mask")
            bench.undo.undo()
            #expect(bench.model.mask(id, for: bench.frame)?.components[0].invert == false)

            // Rename selects it and opens its name, no step until a name is typed.
            bench.editor.selection = nil
            let before = bench.undo.undoActionName
            table().entry("mask.rename")?.choose()
            #expect(bench.editor.selection == MaskEditor.Selection(mask: id, component: nil) && bench.editor.renaming == id)
            #expect(bench.undo.undoActionName == before)
            bench.editor.renaming = nil

            try bench.choose("mask.duplicate", in: table())
            #expect(bench.masks.count == 2 && bench.masks[0].id == id && bench.undo.undoActionName == "Duplicate Mask")
            #expect(bench.editor.selection?.mask == bench.masks[1].id)
            #expect(bench.model.maskName(bench.masks[1].id, for: bench.frame) == "Linear 1 copy")
            bench.undo.undo()
            #expect(bench.masks.count == 1)

            try bench.choose("mask.delete", in: table())
            #expect(bench.masks.isEmpty && bench.undo.undoActionName == "Delete Mask")
            bench.undo.undo()
            #expect(bench.masks.map(\.id) == [id])
        }
    }

    // MARK: A component's row

    @Test func aComponentsRowHoldsInvertItsOperationsAndRemove() async throws {
        try await withBench { bench in
            let mask = try bench.placeMask()
            bench.addComponent(.radial, .subtract)
            let components = try #require(bench.model.mask(mask.id, for: bench.frame)?.components)
            #expect(components.count == 2 && components[1].operation == .subtract)
            @MainActor func table(_ index: Int, canAdjust: Bool = true) -> [MenuEntry] {
                let component = bench.model.mask(mask.id, for: bench.frame)!.components[index]
                return InspectorMenus.componentRow(component, index: index, of: mask.id, frame: bench.frame, canAdjust: canAdjust, model: bench.model)
            }
            // The first is always added: nothing comes before it to subtract from.
            #expect(table(0).titles == ["Invert", "—", "Remove"])
            #expect(Self.enabled(table(0)) == [true, true])
            #expect(table(1).titles == ["Invert", "—", "Add", "Subtract", "Intersect", "—", "Remove"])
            #expect(table(1).map(\.id) == ["component.invert", "divider.1", "component.add", "component.subtract", "component.intersect",
                                           "divider.5", "component.remove"])
            // The operation it has is the one it cannot be changed to.
            #expect(Self.enabled(table(1)) == [true, true, false, true, true])
            #expect(Self.enabled(table(1, canAdjust: false)).allSatisfy { !$0 })

            bench.editor.selection = nil
            try bench.choose("component.invert", in: table(1))
            #expect(bench.editor.selection == MaskEditor.Selection(mask: mask.id, component: 1))
            #expect(bench.model.mask(mask.id, for: bench.frame)?.components[1].invert == true && bench.undo.undoActionName == "Invert Mask")
            #expect(bench.model.mask(mask.id, for: bench.frame)?.components[0].invert == false)

            try bench.choose("component.intersect", in: table(1))
            #expect(bench.model.mask(mask.id, for: bench.frame)?.components[1].operation == .intersect)
            #expect(bench.undo.undoActionName == "Intersect in Mask")
            #expect(Self.enabled(table(1)) == [true, true, true, false, true])

            try bench.choose("component.remove", in: table(1))
            #expect(bench.model.mask(mask.id, for: bench.frame)?.components.count == 1 && bench.undo.undoActionName == "Remove from Mask")
            // The last one takes its mask with it, as its ⋯'s Remove did.
            try bench.choose("component.remove", in: table(0))
            #expect(bench.masks.isEmpty && bench.undo.undoActionName == "Delete Mask")
        }
    }

    // MARK: A right-click on a row

    /// The row as it is drawn: a right-click, or a Control-click, is the row's menu, which selects the row before its table is made and
    /// is the ⋯'s own table; a click passes through to the row; and while its name is typed in, the field keeps the press.
    @Test func aRightClickOnAMasksRowSelectsItAndOpensTheTableItsMenuDraws() async throws {
        try await withBench { bench in
            let mask = try bench.placeMask()
            bench.editor.selection = nil
            var opened = 0
            let window = try await host(MaskRow(frame: bench.frame, mask: mask, name: "Linear 1", canAdjust: true, canDuplicate: false,
                                                onMenu: { opened += 1 })
                                            .environment(bench.model),
                                        height: 60) { !Self.views(RowMenuView.self, under: $0).isEmpty }
            defer { window.close() }
            let root = try #require(window.contentView)
            let catcher = try #require(Self.views(RowMenuView.self, under: root).first)
            let point = Self.centre(of: catcher)
            #expect(!catcher.isAccessibilityElement())

            /// The press the catcher is handling.
            @MainActor func handling(_ event: NSEvent) -> NSEvent {
                catcher.currentEvent = { event }
                return event
            }
            _ = handling(try rightClick(at: point, in: window))
            #expect(lands(at: point, on: catcher, in: window))
            _ = handling(try press(.leftMouseDown, at: point, in: window, flags: .control))
            #expect(lands(at: point, on: catcher, in: window), "a Control-click is a right-click")
            _ = handling(try press(.leftMouseDown, at: point, in: window))
            #expect(!lands(at: point, on: catcher, in: window), "a click is the row's")
            _ = handling(try press(.mouseMoved, at: point, in: window))
            #expect(!lands(at: point, on: catcher, in: window), "the pointer's hover is the row's")

            let handled = handling(try rightClick(at: point, in: window))
            let made = InspectorMenus.tablesMade
            let menu = catcher.menu(for: handled)
            #expect(InspectorMenus.tablesMade == made + 1)
            #expect(bench.editor.selection == MaskEditor.Selection(mask: mask.id, component: nil) && opened == 1)
            let table = InspectorMenus.maskRow(mask, frame: bench.frame, canAdjust: true, canDuplicate: false, model: bench.model)
            #expect(Self.rows(menu) == table.titles)
            #expect(Self.enabled(menu) == Self.enabled(table) && Self.enabled(menu) == [true, true, false, true, true])

            // Chosen from the right-click's menu, as from the ⋯'s.
            let item = try #require(menu?.items.firstIndex { $0.title == "Turn Off" })
            bench.step { menu?.performActionForItem(at: item) }
            #expect(bench.model.mask(mask.id, for: bench.frame)?.isEnabled == false && bench.undo.undoActionName == "Turn Mask Off")

            // While its name is typed in, the field's own menu: the row takes no press.
            bench.editor.renaming = mask.id
            try await settle(window)
            #expect(!catcher.isActive && !lands(at: point, on: catcher, in: window))
            #expect(catcher.menu(for: handled) == nil && opened == 1)
            bench.editor.renaming = nil
        }
    }

    @Test func aRightClickOnAComponentsRowSelectsItFirst() async throws {
        try await withBench { bench in
            let mask = try bench.placeMask()
            bench.addComponent(.radial, .intersect)
            let component = try #require(bench.model.mask(mask.id, for: bench.frame)?.components[1])
            bench.editor.selection = MaskEditor.Selection(mask: mask.id, component: nil)
            let window = try await host(MaskComponentRow(frame: bench.frame, maskID: mask.id, component: component, index: 1, canAdjust: true)
                                            .environment(bench.model),
                                        height: 40) { !Self.views(RowMenuView.self, under: $0).isEmpty }
            defer { window.close() }
            let root = try #require(window.contentView)
            let catcher = try #require(Self.views(RowMenuView.self, under: root).first)
            let point = Self.centre(of: catcher), handled = try rightClick(at: point, in: window)
            catcher.currentEvent = { handled }
            #expect(lands(at: point, on: catcher, in: window))
            let menu = catcher.menu(for: handled)
            #expect(bench.editor.selection == MaskEditor.Selection(mask: mask.id, component: 1))
            let table = InspectorMenus.componentRow(component, index: 1, of: mask.id, frame: bench.frame, canAdjust: true, model: bench.model)
            #expect(Self.rows(menu) == table.titles && Self.enabled(menu) == [true, true, true, false, true])
        }
    }

    // MARK: A slider's row

    @Test func aSlidersRowOffersItsResetByItsOwnName() {
        var resets = 0
        let row = InspectorMenus.sliderRow(title: "Exposure", isChanged: true, isEnabled: true) { resets += 1 }
        #expect(row.titles == ["Reset Exposure"] && row.map(\.id) == ["slider.reset"] && row[0].isEnabled)
        row[0].choose()
        #expect(resets == 1)
        // At its reset value, or disabled, or moving: nothing to reset.
        #expect(!InspectorMenus.sliderRow(title: "Amount", isChanged: false, isEnabled: true) {}[0].isEnabled)
        #expect(!InspectorMenus.sliderRow(title: "Warmth", isChanged: true, isEnabled: false) {}[0].isEnabled)
        #expect(InspectorMenus.sliderRow(title: "Warmth", isChanged: true, isEnabled: true) {}.titles == ["Reset Warmth"])
        // A row with a group's reset offers it after its own, whether or not the row is at its reset value, but not while the row
        // is disabled or moving.
        var groups = 0
        let group = MenuEntry.action("adjust.resetPresence", "Reset Presence") { groups += 1 }
        let grouped = InspectorMenus.sliderRow(title: "Clarity", isChanged: false, isEnabled: true, reset: {}, group: group)
        #expect(grouped.titles == ["Reset Clarity", "—", "Reset Presence"] && Self.enabled(grouped) == [false, true])
        grouped.entry("adjust.resetPresence")?.choose()
        #expect(groups == 1)
        #expect(Self.enabled(InspectorMenus.sliderRow(title: "Clarity", isChanged: true, isEnabled: false, reset: {}, group: group)) == [false, false])
        var nothing = group
        nothing.isEnabled = false
        #expect(Self.enabled(InspectorMenus.sliderRow(title: "Clarity", isChanged: true, isEnabled: true, reset: {}, group: nothing)) == [true, false])
    }

    /// A Presence row's menu as it is drawn: its own reset, then Reset Presence, from the slider and from its value; chosen, the five
    /// are cleared as one "Adjust Frame" step, Light kept. A Light row's menu keeps its one reset.
    @Test func aPresenceRowsMenuOffersResetPresenceAfterItsOwn() async throws {
        try await withBench(tab: .light) { bench in
            bench.step { bench.model.moveLight(.presence(.clarity), to: 30, for: bench.frame) }
            bench.step { bench.model.moveLight(.presence(.vibrance), to: -20, for: bench.frame) }
            let before = bench.model.manualAdjustments(for: bench.frame)
            #expect(before.presence == (try Presence([.clarity: 30, .vibrance: -20])) && before.exposureEV == 0.5)
            let window = try await host(ManualAdjustmentsView(frame: bench.frame).environment(bench.model)) {
                AdjustmentSliderControl.sliders(in: .light, under: $0).count == ManualAdjustments.Control.allCases.count + Presence.Control.allCases.count
            }
            defer { window.close() }
            let root = try #require(window.contentView)
            @MainActor func slider(_ tabSlider: ManualAdjustments.Slider) throws -> AdjustmentSliderControl {
                try #require(AdjustmentSliderControl.sliders(in: .light, under: root).first { $0.spec == .light(tabSlider) })
            }
            @MainActor func scrub(_ tabSlider: ManualAdjustments.Slider) -> ValueScrubView? {
                Self.views(ValueScrubView.self, under: root).first { $0.spec == .light(tabSlider) }
            }
            let clarity = try slider(.presence(.clarity)), event = try rightClick(at: Self.centre(of: clarity), in: window)
            #expect(Self.rows(clarity.menu(for: event)) == ["Reset Clarity", "—", "Reset Presence"])
            #expect(Self.enabled(clarity.menu(for: event)) == [true, true])
            #expect(Self.rows(scrub(.presence(.clarity))?.menu(for: event)) == ["Reset Clarity", "—", "Reset Presence"])
            // At zero its own reset waits; the group's does not.
            let texture = try slider(.presence(.texture))
            #expect(Self.rows(texture.menu(for: event)) == ["Reset Texture", "—", "Reset Presence"])
            #expect(Self.enabled(texture.menu(for: event)) == [false, true])
            #expect(Self.rows(try slider(.light(.exposure)).menu(for: event)) == ["Reset Exposure"])
            // During the row's own gesture both wait.
            clarity.onEditingChanged?(true)
            #expect(Self.enabled(clarity.menu(for: event)) == [false, false])
            clarity.onEditingChanged?(false)

            let menu = try #require(texture.menu(for: event))
            bench.step { menu.performActionForItem(at: 2) }
            #expect(bench.model.manualAdjustments(for: bench.frame) == (try ManualAdjustments(exposureEV: 0.5)))
            #expect(bench.undo.undoActionName == "Adjust Frame" && bench.model.printedLight == nil)
            try await settle(window)
            #expect(Self.enabled(try slider(.presence(.clarity)).menu(for: event)) == [false, false])
            bench.undo.undo()
            #expect(bench.model.manualAdjustments(for: bench.frame) == before)
        }
    }

    /// The Light tab as it is drawn: the slider and its value both give the row's menu; its Reset is the double-click's, one "Adjust
    /// Frame" step through the print, disabled at zero and during the row's own gesture; and the value, typed in, keeps its field's menu.
    @Test func aLightRowsRightClickResetsItAsADoubleClickDoes() async throws {
        try await withBench(tab: .light) { bench in
            let window = try await host(ManualAdjustmentsView(frame: bench.frame).environment(bench.model)) {
                AdjustmentSliderControl.sliders(in: .light, under: $0).count == ManualAdjustments.Control.allCases.count + Presence.Control.allCases.count
            }
            defer { window.close() }
            let root = try #require(window.contentView)
            @MainActor func slider(_ control: ManualAdjustments.Control) throws -> AdjustmentSliderControl {
                try #require(AdjustmentSliderControl.sliders(in: .light, under: root).first { $0.spec == .light(control) })
            }
            @MainActor func scrub(_ control: ManualAdjustments.Control) -> ValueScrubView? {
                Self.views(ValueScrubView.self, under: root).first { $0.spec == .light(control) }
            }
            let exposure = try slider(.exposure), point = Self.centre(of: exposure)
            let event = try rightClick(at: point, in: window)
            #expect(Self.rows(exposure.menu(for: event)) == ["Reset Exposure"] && Self.enabled(exposure.menu(for: event)) == [true])
            #expect(Self.rows(scrub(.exposure)?.menu(for: event)) == ["Reset Exposure"])
            // Contrast is at its reset value.
            #expect(Self.rows(try slider(.contrast).menu(for: event)) == ["Reset Contrast"])
            #expect(Self.enabled(try slider(.contrast).menu(for: event)) == [false])

            // During the row's own gesture its reset waits.
            exposure.onEditingChanged?(true)
            #expect(Self.enabled(exposure.menu(for: event)) == [false])
            exposure.onEditingChanged?(false)
            #expect(Self.enabled(exposure.menu(for: event)) == [true])

            let menu = try #require(exposure.menu(for: event))
            bench.step { menu.performActionForItem(at: 0) }
            #expect(bench.model.manualAdjustments(for: bench.frame).exposureEV == 0)
            #expect(bench.undo.undoActionName == "Adjust Frame" && bench.model.printedLight == nil)
            try await settle(window)
            #expect(Self.enabled(try slider(.exposure).menu(for: event)) == [false])
            bench.undo.undo()
            #expect(bench.model.manualAdjustments(for: bench.frame).exposureEV == 0.5)
            try await settle(window)

            // A right-click on the value is its scrubber's, whose menu is the row's; a click types into it (the scrubber's `onClick`),
            // and the scrubber, the row's menu with it, steps aside for the field's own text menu. No catcher covers a slider's row.
            let value = try #require(scrub(.exposure)), field = Self.centre(of: value)
            #expect(lands(at: field, on: value, in: window) && lands(at: point, on: exposure, in: window))
            #expect(Self.views(RowMenuView.self, under: root).isEmpty)
            value.onClick?()
            try await settle(window)
            #expect(scrub(.exposure) == nil && scrub(.contrast) != nil)
            let taker = hit(field, in: window)
            #expect(!(taker is ValueScrubView) && !(taker is RowMenuView) && !(taker is AdjustmentSliderControl))
            #expect(Self.enabled(exposure.menu(for: event)) == [true], "the slider keeps the row's menu while the value is typed in")
        }
    }

    /// A mask's rows are the same row: Reset Amount at 100 waits; a mask's Exposure resets as one "Adjust Mask" step.
    @Test func aMasksSliderRowsResetAsTheirDoubleClickDoes() async throws {
        try await withBench(tab: .masks) { bench in
            let mask = try bench.placeMask(.radial)
            // Balance's rows are drawn once its group is open.
            bench.editor.openGroups = [.light, .balance, .shape]
            let window = try await host(ManualAdjustmentsView(frame: bench.frame).environment(bench.model)) {
                AdjustmentSliderControl.sliders(in: .mask, under: $0).count >= 9
            }
            defer { window.close() }
            let root = try #require(window.contentView)
            @MainActor func slider(_ title: String) throws -> AdjustmentSliderControl {
                try #require(AdjustmentSliderControl.sliders(in: .mask, under: root).first { $0.spec.title == title })
            }
            let event = try rightClick(at: Self.centre(of: try slider("Amount")), in: window)
            #expect(Self.rows(try slider("Amount").menu(for: event)) == ["Reset Amount"])
            #expect(Self.enabled(try slider("Amount").menu(for: event)) == [false])
            #expect(Self.rows(try slider("Warmth").menu(for: event)) == ["Reset Warmth"])
            #expect(Self.rows(try slider("Magenta").menu(for: event)) == ["Reset Magenta"])

            bench.step { _ = try? slider("Exposure").accessibilityPerformIncrement() }
            #expect(bench.model.mask(mask.id, for: bench.frame)?.adjustments.exposureEV == AdjustmentSliderSpec.light(.exposure).arrowStep)
            try await settle(window)
            let menu = try #require(try slider("Exposure").menu(for: event))
            #expect(Self.rows(menu) == ["Reset Exposure"] && Self.enabled(menu) == [true])
            bench.step { menu.performActionForItem(at: 0) }
            #expect(bench.model.mask(mask.id, for: bench.frame)?.adjustments.exposureEV == 0)
            #expect(bench.undo.undoActionName == "Adjust Mask" && !bench.editor.isAdjusting && bench.editor.printedValues == nil)
            #expect(bench.model.manualAdjustments(for: bench.frame).exposureEV == 0.5, "the frame's own Exposure is not the mask's")
        }
    }

    // MARK: The tabs' ground

    @Test func eachTabsGroundHoldsTheFramesAdjustmentsAndItsOwnReset() async throws {
        try await withBench { bench in
            for (tab, resets) in [(AdjustInspectorTab.light, ["Reset Light", "Reset Presence"]), (.curve, ["Reset Curves"]), (.masks, ["Reset Masks"]), (.lens, ["Distortion", "—", "Reset Lens"]),
                                  (.remove, ["Reset Removals"])] {
                let ground = InspectorMenus.ground(of: tab, frame: bench.frame, model: bench.model)
                #expect(ground.titles == ["Copy Adjustments", "Paste Adjustments", "Paste Only",
                                          "Save Look as Preset…", "Look Presets…", "—"] + resets, "\(tab)")
                // The photograph's rows: no batch paste, whose frames are not in view here.
                #expect(ground.entry("frame.pasteToShown") == nil)
                #expect(ground.entry("frame.pasteOnly")?.children.titles == AdjustmentParts.each.map(\.title))
            }
            // Copy is for a frame with an edit, and takes it, as Edit > Copy Adjustments does; Paste waits for something copied.
            let ground = { @MainActor in InspectorMenus.ground(of: .light, frame: bench.frame, model: bench.model) }
            bench.model.adjustmentsClipboard = nil
            #expect(ground().entry("frame.copy")?.isEnabled == true && ground().entry("frame.paste")?.isEnabled == false)
            #expect(ground().entry("frame.pasteOnly")?.isEnabled == false)
            try bench.choose("frame.copy", in: ground())
            #expect(bench.model.adjustmentsClipboard?.source == bench.frame.url)
            bench.model.dismissClipboardNotice()
            // Light alone copied from another frame: Paste, and Paste Only's Light.
            let other = try #require(bench.model.roll?.frames.last)
            #expect(other.url != bench.frame.url)
            bench.model.adjustmentsClipboard = AdjustmentsClipboard(source: other.url, sourceName: other.name, origin: .auto,
                                                                    adjustments: try ManualAdjustments(exposureEV: -1), maskNotes: .none,
                                                                    frameControls: FrameControls())
            #expect(ground().entry("frame.paste")?.isEnabled == true && ground().entry("frame.pasteOnly")?.isEnabled == true)
            #expect(ground().entry("frame.pasteOnly.light")?.isEnabled == true && ground().entry("frame.pasteOnly.curve")?.isEnabled == false)
            bench.model.adjustmentsClipboard = nil
        }
    }

    /// Each reset by its button's rule, and chosen, the button's own call: one step with that call's name. Reset Light and Reset
    /// Presence each clear their own group and leave the other's.
    @Test func eachTabsResetIsEnabledByItsButtonsRuleAndDoesWhatItDoes() async throws {
        try await withBench { bench in
            // The Remove tab's reset is its own suite's (`RemoveInspectorTests`): it has nothing to delete here.
            @MainActor func resets() -> [MenuEntry] {
                AdjustInspectorTab.allCases.filter { $0 != .remove }.flatMap { InspectorMenus.resets(of: $0, frame: bench.frame, model: bench.model) }
            }
            @MainActor func enabled() -> [String: Bool] {
                Dictionary(uniqueKeysWithValues: resets().map { ($0.title, $0.isEnabled) })
            }
            #expect(resets().map(\.id) == ["adjust.resetLight", "adjust.resetPresence", "adjust.resetCurves", "adjust.resetMasks", "adjust.resetLens"])
            // Exposure +0.5 and nothing else.
            #expect(enabled() == ["Reset Light": true, "Reset Presence": false, "Reset Curves": false, "Reset Masks": false, "Reset Lens": false])

            let curves = try ToneCurves.identity.setting(.tone, to: ToneCurves.Preset.softContrast.curve)
            bench.step { bench.model.setToneCurves(curves, for: bench.frame) }
            try bench.placeMask()
            bench.step { bench.model.moveLight(.presence(.dehaze), to: 40, for: bench.frame) }
            #expect(enabled().filter { $0.key != "Reset Lens" }.values.allSatisfy { $0 })

            bench.step { bench.model.moveLight(.lens(.distortion), to: 150, for: bench.frame) }
            #expect(enabled()["Reset Lens"] == true)

            // A frame that cannot be adjusted can be reset by none of them, as its buttons cannot.
            bench.block(true)
            #expect(enabled().values.allSatisfy { !$0 })
            bench.block(false)

            try bench.choose("adjust.resetLight", in: resets())
            #expect(bench.model.manualAdjustments(for: bench.frame).exposureEV == 0 && bench.undo.undoActionName == "Adjust Frame")
            #expect(bench.model.manualAdjustments(for: bench.frame).presence.dehaze == 40)
            #expect(!bench.model.manualAdjustments(for: bench.frame).curves.isIdentity && bench.masks.count == 1)
            #expect(enabled()["Reset Light"] == false && enabled()["Reset Presence"] == true)

            bench.step { bench.model.moveLight(.light(.shadows), to: 25, for: bench.frame) }
            try bench.choose("adjust.resetPresence", in: resets())
            #expect(bench.model.manualAdjustments(for: bench.frame).presence.isIdentity && bench.undo.undoActionName == "Adjust Frame")
            #expect(bench.model.manualAdjustments(for: bench.frame).shadows == 25)
            #expect(!bench.model.manualAdjustments(for: bench.frame).curves.isIdentity && bench.masks.count == 1)
            #expect(enabled()["Reset Presence"] == false && enabled()["Reset Light"] == true)
            bench.undo.undo()
            #expect(bench.model.manualAdjustments(for: bench.frame).presence.dehaze == 40)
            bench.undo.redo()

            try bench.choose("adjust.resetLens", in: resets())
            #expect(bench.model.lensSettings(for: bench.frame).isDefault && bench.masks.count == 1)
            #expect(!bench.model.manualAdjustments(for: bench.frame).curves.isIdentity)

            try bench.choose("adjust.resetCurves", in: resets())
            #expect(bench.model.manualAdjustments(for: bench.frame).curves.isIdentity && bench.undo.undoActionName == "Adjust Frame")
            #expect(bench.masks.count == 1 && enabled()["Reset Curves"] == false)

            try bench.choose("adjust.resetMasks", in: resets())
            #expect(bench.masks.isEmpty && bench.undo.undoActionName == "Reset Masks" && enabled()["Reset Masks"] == false)
            bench.undo.undo()
            #expect(bench.masks.count == 1)
        }
    }

    @Test func lensTabDisablesAmountAndTheSwitchWithoutACurve() async throws {
        try await withBench(tab: .lens) { bench in
            let window = try await host(ManualAdjustmentsView(frame: bench.frame).environment(bench.model)) {
                AdjustmentSliderControl.sliders(in: .lens, under: $0).count == LensSettings.Control.allCases.count
            }
            defer { window.close() }
            let root = try #require(window.contentView)
            let amount = try #require(AdjustmentSliderControl.sliders(in: .lens, under: root).first)
            #expect(amount.spec == .lensAmount(.distortion) && !amount.isEnabled)
            #expect(AdjustmentSliderControl.sliders(in: .light, under: root).isEmpty)
            let ground = InspectorMenus.ground(of: .lens, frame: bench.frame, model: bench.model)
            #expect(ground.entry("lens.distortion")?.isOn == true)
            #expect(ground.entry("lens.distortion")?.isEnabled == false)
            ground.entry("lens.distortion")?.choose()
            #expect(bench.model.lensSettings(for: bench.frame).distortion.isOn)
            #expect(!bench.model.menuState.canSetDistortion)
            #expect(!InspectorMenus.resetLens(bench.frame, model: bench.model).isEnabled)
            #expect(bench.model.lensSettings(for: bench.frame).isDefault)
        }
    }

    // MARK: Made as the menu opens

    /// No table is made while the inspector is drawn, on any tab, nor while a slider moves; one is, as a menu is asked for. So a row
    /// drawn during a drag reads nothing more of the edit or the clipboard than it did.
    @Test func noTableIsMadeUntilItsMenuIsAskedFor() async throws {
        try await withBench(tab: .light) { bench in
            let made = InspectorMenus.tablesMade
            let window = try await host(ManualAdjustmentsView(frame: bench.frame).environment(bench.model)) {
                AdjustmentSliderControl.sliders(in: .light, under: $0).count == ManualAdjustments.Control.allCases.count + Presence.Control.allCases.count
            }
            defer { window.close() }
            let root = try #require(window.contentView)
            let exposure = try #require(AdjustmentSliderControl.sliders(in: .light, under: root).first)
            bench.step { _ = exposure.accessibilityPerformIncrement() }
            try await settle(window)
            bench.model.adjustTab = .curve
            for _ in 0..<100 where Self.views(CurveGraphView.self, under: root).isEmpty { try await settle(window) }
            #expect(!Self.views(CurveGraphView.self, under: root).isEmpty)
            try bench.placeMask()
            bench.model.adjustTab = .masks
            for _ in 0..<100 where AdjustmentSliderControl.sliders(in: .mask, under: root).count < 9 { try await settle(window) }
            #expect(!Self.views(RowMenuView.self, under: root).isEmpty)
            let amount = try #require(AdjustmentSliderControl.sliders(in: .mask, under: root).first)
            bench.step { _ = amount.accessibilityPerformDecrement() }
            try await settle(window)
            #expect(InspectorMenus.tablesMade == made)

            _ = amount.menu(for: try rightClick(at: Self.centre(of: amount), in: window))
            #expect(InspectorMenus.tablesMade == made + 1)
        }
    }

    // MARK: The curve graph

    /// Where the graph draws `point`, in its own flipped coordinates (`CurveGraphView.position`).
    private static func spot(_ point: CurvePoint, in graph: CurveGraphView) -> NSPoint {
        let r = graph.bounds.insetBy(dx: 5, dy: 5)
        return NSPoint(x: r.minX + CGFloat(point.input) / 255 * r.width, y: r.maxY - CGFloat(point.output) / 255 * r.height)
    }

    private func typed(_ text: String, keyCode: UInt16 = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode))
    }

    /// A view that takes the keyboard, to hold it while the graph is right-clicked.
    private final class Focusable: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test func thePresetsAreOneTableAndLinearIsAChannelsReset() throws {
        var chosen: [ToneCurves.Preset] = []
        let presets = InspectorMenus.curvePresets(isEnabled: true) { chosen.append($0) }
        #expect(presets.titles == ["Linear", "Soft contrast", "Lifted blacks", "Strong contrast"])
        #expect(presets.map(\.id) == ToneCurves.Preset.allCases.map { "curve.preset.\($0.rawValue)" })
        presets.forEach { $0.choose() }
        #expect(chosen == ToneCurves.Preset.allCases)
        #expect(InspectorMenus.curvePresets(isEnabled: false) { _ in }.allSatisfy { !$0.isEnabled })
        // No Reset Curve stands beside them: Linear puts a channel's points and regions back exactly as a reset would.
        let edited = try ChannelCurve(points: ToneCurves.Preset.softContrast.curve.points, regions: try CurveRegions(shadows: 30))
        let curves = try ToneCurves.identity.setting(.red, to: edited)
        #expect(ToneCurves.Preset.linear.curve == ChannelCurve.identity)
        #expect(try curves.setting(.red, to: ToneCurves.Preset.linear.curve) == ToneCurves.identity)
    }

    /// On an interior point: it is selected first, inside an edit bracket as a click's, and Delete Point does what Delete does on it,
    /// as one edit. The keyboard stays on the graph, and its keys go on working.
    @Test func deletePointByTheGraphsMenuDoesWhatDeleteDoes() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        window.contentView = graph
        graph.curve = ToneCurves.Preset.softContrast.curve
        var phases: [Bool] = [], chosen: [ToneCurves.Preset] = []
        graph.onEditingChanged = { phases.append($0) }
        graph.shapeEntries = { InspectorMenus.curvePresets(isEnabled: true) { chosen.append($0) } }
        #expect(window.makeFirstResponder(graph))

        let entries = graph.contextEntries(at: Self.spot(graph.curve.points[2], in: graph))
        #expect(graph.selectedPoint == 2 && phases == [true, false])
        #expect(entries.titles == ["Delete Point", "—", "Linear", "Soft contrast", "Lifted blacks", "Strong contrast"])
        #expect(entries[0].id == "curve.deletePoint" && entries[0].isEnabled)

        // Delete on the same point, for what the menu must do.
        let keyed = CurveGraphView(frame: graph.frame)
        keyed.curve = ToneCurves.Preset.softContrast.curve
        keyed.select(2)
        keyed.keyDown(with: try typed("\u{7f}", keyCode: 51))
        entries[0].choose()
        #expect(graph.curve == keyed.curve && graph.curve.points.count == 4 && graph.selectedPoint == keyed.selectedPoint)
        #expect(phases == [true, false, true, false])
        #expect(window.firstResponder === graph)
        graph.keyDown(with: try typed("+"))
        #expect(graph.selectedPoint == keyed.selectedPoint + 1, "the graph's keys are as they were")

        // The presets come from the Curve tab's table.
        entries.entry("curve.preset.strongContrast")?.choose()
        #expect(chosen == [.strongContrast])

        // The window asks for the same menu.
        let point = graph.convert(Self.spot(graph.curve.points[1], in: graph), to: nil)
        let menu = graph.menu(for: try rightClick(at: point, in: window))
        #expect(Self.rows(menu) == entries.titles && graph.selectedPoint == 1)
    }

    /// An endpoint stays, so its Delete Point is there and disabled; away from a point, a disabled graph, or Regions, no point is
    /// selected; and a right-click takes the keyboard from nothing.
    @Test func theGraphsMenuElsewhereSelectsNothingAndMovesNoKeyboard() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 280), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 280))
        window.contentView = content
        let graph = CurveGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        let other = Focusable(frame: NSRect(x: 0, y: 250, width: 240, height: 30))
        content.addSubview(graph)
        content.addSubview(other)
        graph.curve = ToneCurves.Preset.softContrast.curve
        var phases: [Bool] = []
        graph.onEditingChanged = { phases.append($0) }
        graph.shapeEntries = { InspectorMenus.curvePresets(isEnabled: true) { _ in } }
        #expect(window.makeFirstResponder(other))

        let endpoint = graph.contextEntries(at: Self.spot(graph.curve.points[0], in: graph))
        #expect(endpoint.titles.first == "Delete Point" && !endpoint[0].isEnabled && graph.selectedPoint == 0)
        #expect(window.firstResponder === other, "a right-click moves no keyboard")

        phases = []
        graph.select(3)
        let away = graph.contextEntries(at: NSPoint(x: 120, y: 30))
        #expect(away.titles == ["Linear", "Soft contrast", "Lifted blacks", "Strong contrast"] && graph.selectedPoint == 3 && phases.isEmpty)

        graph.isEnabled = false
        let disabled = graph.contextEntries(at: Self.spot(graph.curve.points[1], in: graph))
        #expect(!disabled[0].isEnabled && graph.selectedPoint == 3 && phases.isEmpty)
        graph.isEnabled = true
        graph.pointMode = false
        #expect(graph.contextEntries(at: Self.spot(graph.curve.points[1], in: graph)).first?.id == "curve.preset.linear")
        #expect(graph.selectedPoint == 3 && window.firstResponder === other)
    }

    /// The Curve tab as it is drawn: the graph's menu is the Curve shape menu's table and Reset Curves, by its button's rule, and each
    /// row is that control's one "Adjust Frame" step on the frame.
    @Test func theCurveTabsGraphMenuEditsTheFrameAsItsControlsDo() async throws {
        try await withBench(tab: .curve) { bench in
            let window = try await host(CurveEditorView(frame: bench.frame).environment(bench.model), height: 600) {
                !Self.views(CurveGraphView.self, under: $0).isEmpty
            }
            defer { window.close() }
            let root = try #require(window.contentView)
            let graph = try #require(Self.views(CurveGraphView.self, under: root).first)
            let away = NSPoint(x: graph.bounds.midX, y: 20)
            let entries = graph.contextEntries(at: away)
            #expect(entries.titles == ["Linear", "Soft contrast", "Lifted blacks", "Strong contrast", "—", "Reset Curves"])
            #expect(Self.enabled(entries) == [true, true, true, true, false])

            try bench.choose("curve.preset.strongContrast", in: entries)
            #expect(bench.model.manualAdjustments(for: bench.frame).curves.tone == ToneCurves.Preset.strongContrast.curve)
            #expect(bench.undo.undoActionName == "Adjust Frame")
            try await settle(window)
            #expect(graph.curve == ToneCurves.Preset.strongContrast.curve && graph.selectedPoint == 2, "its middle point selected")

            let onPoint = graph.contextEntries(at: Self.spot(graph.curve.points[1], in: graph))
            #expect(graph.selectedPoint == 1)
            try bench.choose("curve.deletePoint", in: onPoint)
            #expect(bench.model.manualAdjustments(for: bench.frame).curves.tone.points.map(\.input) == [0, 128, 192, 255])
            #expect(bench.undo.undoActionName == "Adjust Frame")
            try await settle(window)

            try bench.choose("adjust.resetCurves", in: graph.contextEntries(at: away))
            #expect(bench.model.manualAdjustments(for: bench.frame).curves.isIdentity && bench.undo.undoActionName == "Adjust Frame")
            bench.undo.undo()
            #expect(bench.model.manualAdjustments(for: bench.frame).curves.tone.points.count == 4)
        }
    }
}
