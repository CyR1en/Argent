import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import SwiftUI
import Testing
@testable import ArgentApp

/// The Adjust inspector's model-derived words: its save line, what it waits for, and the names of
/// its comparison and reset on its three tabs; and where its tab is kept.
@MainActor @Suite(.serialized) struct AdjustInspectorStateTests {
    private func header(_ url: URL) throws {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255)] }
        func u32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(n >> (8 * $0) & 255) } }
        var b: [UInt8] = [0x49, 0x49] + u16(42) + u32(8)
        b += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(26) + u32(0)
        b += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try Data(b).write(to: url, options: .atomic)
    }

    private func fixture() async throws -> (RollModel, Frame, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-adjust-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try header(folder.appendingPathComponent("DSC1.ARW"))
        try header(folder.appendingPathComponent("DSC2.ARW"))
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(folder)
        if let restore = model.manualRestoreTask { await restore.value }
        return (model, try #require(model.selectedFrame), folder)
    }

    private static func frame(of view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    /// What a row's name and its reset arrow take: the name as the row sets it (`ManualAdjustmentRow`), then the gap and the arrow.
    private static func nameWithArrow(_ title: String) -> CGFloat {
        let name = NSHostingView(rootView: Text(verbatim: title).font(Graphite.Typeface.label).lineLimit(1).fixedSize())
        name.layoutSubtreeIfNeeded()
        return name.fittingSize.width + AdjustRowMetric.nameGap + AdjustRowMetric.resetArrow
    }

    private func edit(on frame: Frame, origin: AutomaticBaseline.Origin = .auto) throws -> ManualEdit {
        let verified = try SourceDigests.shared.digest(of: frame.url)
        let pin = AutomaticBaseline(sourceSHA256: verified.sha256, stockID: "test", stockDigest: "digest",
            controls: .init(), aim: origin == .original ? PrintAim() : PrintAim(level: -0.5, cast: .zero),
            analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off), origin: origin)
        return ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3), baseline: pin)
    }

    @Test func theSaveLineFollowsTheFramesEditAndTheWriter() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Nothing of the frame's own: nothing to save.
        #expect(model.adjustSaveStatus(for: frame) == .unadjusted)
        model.manualEdits[frame.url] = try edit(on: frame)
        #expect(model.adjustSaveStatus(for: frame) == .saved)
        // A save under way anywhere in the roll reads as saving.
        model.manualSaveMessage = "Saving adjustments…"
        #expect(model.adjustSaveStatus(for: frame) == .saving)
        // A failure wins, with the writer's words, until Retry starts saving again.
        model.manualSaveMessage = "Could not save adjustments: disk full"
        model.manualSaveFailed = true
        #expect(model.adjustSaveStatus(for: frame) == .failed("Could not save adjustments: disk full"))
        model.manualSaveFailed = false
        model.manualSaveMessage = nil
        // A held edit, waiting for Reapply on a replaced raw, is still the frame's saved edit.
        model.manualEdits[frame.url] = nil
        model.heldManualEdits[frame.url] = try edit(on: frame)
        #expect(model.adjustSaveStatus(for: frame) == .saved)
    }

    @Test func preparationNamesWhatTheFrameWaitsFor() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Unverified and unmeasured: a first edit from Auto waits for the roll's settled decision.
        #expect(!model.canAdjust(frame))
        #expect(model.adjustPreparation(for: frame) == (model.isBalanced ? "Preparing Auto…" : "Balancing roll…"))
        // An edit from Auto waits for Auto, not the roll; an Original for its own guards.
        model.manualEdits[frame.url] = try edit(on: frame)
        #expect(model.adjustPreparation(for: frame) == "Preparing Auto…")
        model.manualEdits[frame.url] = try edit(on: frame, origin: .original)
        #expect(model.adjustPreparation(for: frame) == "Preparing Original…")
        // An issue is shown on its own, with its action, rather than as preparation.
        model.manualPreparationErrors[frame.url] = "Could not prepare adjustments: unreadable"
        #expect(model.adjustPreparation(for: frame) == nil)
    }

    @Test func theComparisonIsNamedForTheStartingPoint() {
        // One comparison name for every tab, from the frame's starting point.
        #expect(AdjustActionText.compare(from: .auto) == "Compare to Auto")
        #expect(AdjustActionText.compare(from: .original) == "Compare to Original")
    }

    /// The foot's Reset is one menu on every tab: the tab's own resets, then the return to the starting point, named for it.
    /// Nothing is behind Option.
    @Test func theResetMenuHoldsTheTabsOwnResetsThenTheStartingPoints() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        func titles(_ tab: AdjustInspectorTab) -> [String] { InspectorMenus.resetMenu(of: tab, frame: frame, model: model).titles }
        #expect(titles(.light) == ["Reset Light", "Reset Presence", "—", "Reset to Current Auto"])
        #expect(titles(.curve) == ["Reset Curves", "—", "Reset to Current Auto"])
        #expect(titles(.masks) == ["Reset Masks", "—", "Reset to Current Auto"])
        #expect(titles(.lens) == ["Reset Lens", "—", "Reset to Current Auto"])
        #expect(titles(.remove) == ["Reset Removals", "—", "Reset to Current Auto"])
        // With nothing of the frame's own, nothing to reset.
        #expect(InspectorMenus.resetMenu(of: .light, frame: frame, model: model).filter { !$0.isDivider }.allSatisfy { !$0.isEnabled })
        // From an Original the last row returns there, by the Frame menu's name for it.
        model.manualEdits[frame.url] = try edit(on: frame, origin: .original)
        for tab in AdjustInspectorTab.allCases {
            #expect(titles(tab).last == "Reset to Original", "\(tab)")
            #expect(InspectorMenus.resetMenu(of: tab, frame: frame, model: model).last?.id == "frame.reset.original")
        }
    }

    /// The heading's Start from is a menu: the two starting points, the frame's own checked, then what the other costs.
    @Test func theStartingPointMenuChecksTheFramesOwnAndSaysWhatTheOtherClears() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var menu = InspectorMenus.startingPoint(frame, model: model)
        #expect(menu.titles == ["Auto", "Original", "—", InspectorMenus.startingPointNote])
        #expect(menu.entry("adjust.start.auto")?.isOn == true && menu.entry("adjust.start.original")?.isOn == false)
        #expect(menu.entry("adjust.start.note")?.isEnabled == false)
        #expect(InspectorMenus.startingPointNote.contains("clears Light, Curve and Lens adjustments and masks"))
        model.manualEdits[frame.url] = try edit(on: frame, origin: .original)
        menu = InspectorMenus.startingPoint(frame, model: model)
        #expect(menu.entry("adjust.start.auto")?.isOn == false && menu.entry("adjust.start.original")?.isOn == true)
        // The choice not made waits for the frame, as the sliders do; the one made is never dimmed.
        #expect(menu.entry("adjust.start.original")?.isEnabled == true)
        #expect(menu.entry("adjust.start.auto")?.isEnabled == model.canChangeStartingPoint(frame))
    }

    /// The foot's two actions fit the panel at either starting point, Compare with its symbol. "Compare to Original" is the
    /// longer by 19 points and was cut while Reset's face was a pop-up's, 17 points wider than its word needs.
    @Test func theFootFitsThePanelAtEitherStartingPoint() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = NSApplication.shared
        // At its ideal width the foot is Compare's symbol and words, Reset and the padding: what the panel must hold.
        func width() -> CGFloat {
            let view = NSHostingView(rootView: AdjustFooter(frame: frame).environment(model).fixedSize())
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.width
        }
        model.manualEdits[frame.url] = try edit(on: frame)
        #expect(AdjustActionText.compare(from: model.startingPoint(for: frame)) == "Compare to Auto")
        #expect(width() <= Graphite.Metric.inspectorPanelWidth, "from Auto the foot takes \(width())")
        model.manualEdits[frame.url] = try edit(on: frame, origin: .original)
        #expect(AdjustActionText.compare(from: model.startingPoint(for: frame)) == "Compare to Original")
        #expect(width() <= Graphite.Metric.inspectorPanelWidth, "from the Original the foot takes \(width())")
        #expect(width() > 200, "the foot was measured")
    }

    /// A frame that can be adjusted, with Exposure and Clarity moved so that a reset of Light leaves it its edit, and an undo
    /// manager that groups by hand.
    private func ready(_ model: RollModel, _ frame: Frame) throws -> UndoManager {
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        model.manualEdits[frame.url] = try edit(on: frame)
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 0.3).settingPresence(try Presence([.clarity: 10]))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.manualUndoManager = undo
        return undo
    }

    /// A drag on one of the histogram's ranges is a Light row's gesture by another hand: opened at the press, its steps to the
    /// print alone, the edit and one undo step at its end.
    @Test func aDragOnTheHistogramIsOneLightGestureAndOneUndoStep() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let undo = try ready(model, frame)
        #expect(model.canAdjust(frame))

        undo.beginUndoGrouping()
        var drag = HistogramRangeDrag(at: 0.2, on: frame, model: model)
        #expect(drag.control == .shadows && drag.value == 0)
        drag.move(to: 0.1, on: frame, model: model)
        #expect(drag.value == 10)
        // The print has the step, and the edit not yet.
        #expect(model.printedEdit(for: frame)?.adjustments.value(for: .shadows) == 10)
        #expect(model.manualAdjustments(for: frame).value(for: .shadows) == 0)
        drag.move(to: 0.24, on: frame, model: model)
        // A move that changes nothing sends nothing.
        let printed = model.printedLight
        drag.move(to: 0.24, on: frame, model: model)
        #expect(drag.value == 24 && model.printedLight == printed)
        drag.end(on: frame, model: model)
        undo.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).value(for: .shadows) == 24 && model.printedLight == nil)
        #expect(undo.undoActionName == "Adjust Frame")
        let menuUndo = try #require(InspectorMenus.resetMenu(of: .light, frame: frame, model: model).entry("edit.undo"))
        #expect(menuUndo.title == undo.undoMenuItemTitle && menuUndo.isEnabled)
        menuUndo.choose()
        #expect(model.manualAdjustments(for: frame).value(for: .shadows) == 0)
        #expect(model.manualAdjustments(for: frame).exposureEV == 0.3, "the rest of the edit is as it was")

        // A press and a release with no move between is a gesture that changes nothing.
        undo.beginUndoGrouping()
        HistogramRangeDrag(at: 0.95, on: frame, model: model).end(on: frame, model: model)
        undo.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).value(for: .whites) == 0 && model.printedLight == nil)
    }

    @Test func histogramReleaseUsesTheFinalTravelAndHighlightsTheReleaseZone() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let undo = try ready(model, frame)
        undo.beginUndoGrouping()
        var drag = HistogramRangeDrag(at: 0.20, on: frame, model: model)
        drag.move(to: 0.10, on: frame, model: model)
        drag.release(at: 0.20, hovering: .exposure, on: frame, model: model)
        undo.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).shadows == 20)
        #expect(model.histogramZone == .exposure && model.printedLight == nil)
        undo.undo()
        #expect(model.manualAdjustments(for: frame).shadows == 0)
    }

    @Test func closingAdjustCommitsTheHeldHistogramValueAsOneUndoStep() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let undo = try ready(model, frame)
        let shown = model.isAdjustmentsShown
        defer { model.isAdjustmentsShown = shown }
        model.isAdjustmentsShown = true
        undo.beginUndoGrouping()
        var drag = HistogramRangeDrag(at: 0.2, on: frame, model: model)
        drag.move(to: 0.1, on: frame, model: model)
        model.isAdjustmentsShown = false
        drag.release(at: -1.5, hovering: .blacks, on: frame, model: model)
        undo.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).shadows == 10)
        #expect(model.printedLight == nil && model.lightAdjusting == nil)
        undo.undo()
        #expect(model.manualAdjustments(for: frame).shadows == 0)
    }

    @Test func openingSettingsCommitsTheHistogramBeforeThePanelMoves() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let undo = try ready(model, frame)
        let shown = model.isAdjustmentsShown
        defer { model.isAdjustmentsShown = shown }
        model.openFrame()
        model.isAdjustmentsShown = true
        undo.beginUndoGrouping()
        var drag = HistogramRangeDrag(at: 0.2, on: frame, model: model)
        drag.move(to: 0.1, on: frame, model: model)
        model.showWorkspacePage(.settings)
        #expect(model.adjustInspectorFrame == nil)
        #expect(model.manualAdjustments(for: frame).shadows == 10 && model.printedLight == nil)
        model.showWorkspacePage(.roll)
        drag.release(at: -1.5, hovering: .blacks, on: frame, model: model)
        undo.endUndoGrouping()
        #expect(model.histogramZone == nil && model.manualAdjustments(for: frame).shadows == 10)
        undo.undo()
        #expect(model.manualAdjustments(for: frame).shadows == 0 && !undo.canUndo)
        undo.redo()
        #expect(model.manualAdjustments(for: frame).shadows == 10)
    }

    @Test(arguments: [false, true])
    func undoUnderAHistogramDragKeepsAllSubsequentTravel(intermediateEvent: Bool) async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let undo = try ready(model, frame)
        undo.beginUndoGrouping()
        model.moveLight(.light(.contrast), to: 5, for: frame)
        undo.endUndoGrouping()
        var drag = HistogramRangeDrag(at: 0.2, on: frame, model: model)
        drag.move(to: 0.1, on: frame, model: model)
        undo.undo()
        undo.beginUndoGrouping()
        if intermediateEvent { drag.move(to: 0.112, on: frame, model: model) }
        drag.release(at: 0.2, hovering: .exposure, on: frame, model: model)
        undo.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).contrast == 0)
        #expect(model.manualAdjustments(for: frame).shadows == 10)
        undo.undo()
        #expect(model.manualAdjustments(for: frame).shadows == 0)
    }

    /// A reset under a drag on the histogram replaces the drag's gesture, as it does a row's: the drag goes on from the value
    /// the reset left and from where the pointer then is, and what it sets after is written at its end.
    @Test func aResetUnderADragOnTheHistogramIsWhereTheDragGoesOnFrom() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let undo = try ready(model, frame)

        undo.beginUndoGrouping()
        var drag = HistogramRangeDrag(at: 0.5, on: frame, model: model)
        #expect(drag.control == .exposure && drag.value == 0.3)
        drag.move(to: 0.2, on: frame, model: model)
        #expect(drag.value == 1.3)
        let generation = model.lightGestureGeneration
        model.resetLight(for: frame)
        #expect(model.lightGestureGeneration == generation + 1)
        #expect(model.manualAdjustments(for: frame).exposureEV == 0)
        // The first movement after the reset counts from the last event before it.
        drag.move(to: 0.3, on: frame, model: model)
        #expect(drag.value == 0.5)
        drag.move(to: 0.4, on: frame, model: model)
        #expect(drag.value == 1)
        drag.end(on: frame, model: model)
        undo.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).exposureEV == 1 && model.printedLight == nil)
    }

    /// A double-click on a range of the histogram resets its control: one step, and nothing at zero.
    @Test func aDoubleClickOnTheHistogramResetsItsRangesControl() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let undo = try ready(model, frame)
        undo.beginUndoGrouping()
        HistogramRangeDrag.reset(.exposure, on: frame, model: model)
        undo.endUndoGrouping()
        #expect(model.manualAdjustments(for: frame).exposureEV == 0 && undo.undoActionName == "Adjust Frame")
        // At zero there is nothing to reset: no gesture, so no group is needed for it.
        HistogramRangeDrag.reset(.exposure, on: frame, model: model)
        HistogramRangeDrag.reset(.blacks, on: frame, model: model)
        #expect(model.manualAdjustments(for: frame).exposureEV == 0 && model.printedLight == nil)
        undo.undo()
        #expect(model.manualAdjustments(for: frame).exposureEV == 0.3)
    }

    /// A press on Add while its popover is up closes the popover as the press goes down, and Add's own action, which follows
    /// as it comes up, does not open it again.
    @Test func addDoesNotOpenThePopoverItsOwnPressHasJustClosed() {
        let closed = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(MasksInspector.addToggles(dismissed: nil, now: closed))
        #expect(!MasksInspector.addToggles(dismissed: closed, now: closed.addingTimeInterval(0.08)))
        #expect(!MasksInspector.addToggles(dismissed: closed, now: closed.addingTimeInterval(MasksInspector.dismissalWindow)))
        #expect(MasksInspector.addToggles(dismissed: closed, now: closed.addingTimeInterval(MasksInspector.dismissalWindow + 0.01)))
    }

    @Test func aSectionCountsChangesOfItsOwn() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(AdjustInspectorTab.allCases.allSatisfy { model.inspectorEdits(for: frame).count(in: $0) == 0 })
        model.manualEdits[frame.url] = try edit(on: frame)
        #expect(AdjustInspectorTab.allCases.filter { model.inspectorEdits(for: frame).count(in: $0) > 0 } == [.light])
        var values = try ManualAdjustments().settingPresence(try Presence([.clarity: 10]))
        model.manualEdits[frame.url]?.adjustments = values
        #expect(AdjustInspectorTab.allCases.filter { model.inspectorEdits(for: frame).count(in: $0) > 0 } == [.light])
        values = try ManualAdjustments().settingCurves(try ToneCurves.identity.setting(.tone, to: ToneCurves.Preset.softContrast.curve))
        model.manualEdits[frame.url]?.adjustments = values
        #expect(AdjustInspectorTab.allCases.filter { model.inspectorEdits(for: frame).count(in: $0) > 0 } == [.curve])
        values = try ManualAdjustments().settingMasks(try MaskSet(masks: [Self.mask()]))
        model.manualEdits[frame.url]?.adjustments = values
        #expect(AdjustInspectorTab.allCases.filter { model.inspectorEdits(for: frame).count(in: $0) > 0 } == [.masks])
    }

    @Test func sectionNavigationRestoresAllToolsAndMenuCommandsOpenTheirSection() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferred = model.adjustTab, shown = model.isAdjustmentsShown
        defer { model.adjustTab = preferred; model.isAdjustmentsShown = shown }

        model.openFrame()
        model.showInspector(tab: .masks)
        let mask = Self.mask()
        model.maskEditor.selection = .init(mask: mask.id, component: nil)
        #expect(model.openAdjustSection == .masks)
        model.setInspectorFilter(.edited, for: frame)
        #expect(model.openAdjustSection == nil)
        #expect(model.maskEditor.selection == nil)
        #expect(model.inspectorNavigation.filter == .edited)
        #expect(InspectorMenus.resetMenu(of: model.openAdjustSection, frame: frame, model: model).titles == ["Reset to Current Auto"])

        model.setInspectorFilter(.allTools, for: frame)
        #expect(model.openAdjustSection == .masks)
        model.toggleInspectorSection(.masks, for: frame)
        #expect(model.openAdjustSection == nil)
        model.setInspectorFilter(.edited, for: frame)
        model.setInspectorFilter(.allTools, for: frame)
        #expect(model.openAdjustSection == nil)

        model.setInspectorFilter(.edited, for: frame)
        model.showInspector(tab: .curve)
        #expect(model.inspectorNavigation.filter == .allTools && model.openAdjustSection == .curve)
        #expect(model.curveGraphFocusRequest?.frame == frame.url)
        model.toggleInspectorSection(.lens, for: frame)
        #expect(model.openAdjustSection == .lens && model.curveGraphFocusRequest == nil)
    }

    @Test func aDeferredCurveFocusRequestBelongsToItsOriginalFrame() async throws {
        let (model, first, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferred = model.adjustTab, shown = model.isAdjustmentsShown
        defer { model.adjustTab = preferred; model.isAdjustmentsShown = shown }
        let second = try #require(model.roll?.frames.first { $0.id != first.id })
        _ = try ready(model, first)
        _ = try ready(model, second)
        model.openFrame()
        model.manualErrors[first.url] = "The saved adjustment uses an older rendering version."
        model.revealInspectorEdit(.curve(.green))
        let delayed = try #require(model.pendingCurveGraphFocus(for: first))
        #expect(!delayed())
        model.selection = second.id
        #expect(model.pendingCurveGraphFocus(for: second) == nil)
        model.selection = first.id
        model.manualErrors[first.url] = nil
        model.showInspector(tab: .curve)
        let current = try #require(model.pendingCurveGraphFocus(for: first))
        #expect(!delayed())
        #expect(current())
        #expect(!current())
    }

    @Test func editedDestinationsReachTheirToolAndStackedNoticesLeaveRoomToScroll() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferred = model.adjustTab, shown = model.isAdjustmentsShown
        defer { model.adjustTab = preferred; model.isAdjustmentsShown = shown }
        _ = try ready(model, frame)
        model.openFrame()
        model.showInspector(tab: .light)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 502),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ManualAdjustmentsView(frame: frame).environment(model))
        host.sizingOptions = []
        window.contentView = host
        func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { first(type, in: $0) }.first
        }
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
        }

        try await settle()
        model.setInspectorFilter(.edited, for: frame)
        try await settle()
        model.revealInspectorEdit(.curve(.green))
        try await settle()
        let graph = try #require(first(CurveGraphView.self, in: host))
        #expect(graph.channel == .green)
        graph.onChannel?(.blue)
        try await settle()
        model.showInspector(tab: .curve)
        try await settle()
        #expect(graph.channel == .blue)
        model.revealInspectorEdit(.curve(.tone))
        try await settle()
        #expect(graph.channel == .tone)
        model.setInspectorFilter(.edited, for: frame)
        let id = UUID()
        model.revealInspectorEdit(.removal(id))
        #expect(model.openAdjustSection == .remove && model.inspectorNavigation.destination == .removal(id))
        model.showInspector(tab: .masks)
        #expect(model.inspectorNavigation.destination == nil)

        let raster = try MaskRaster(width: 16, height: 16, plane: Array(repeating: 255, count: 256)).ref
        let picture = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let selection = SmartSelection(kind: .background, raster: raster, frame: picture)
        let mask = Mask(components: [MaskComponent(shape: .smart(selection))])
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments.identity.settingMasks(MaskSet(masks: [mask]))
        model.maskSeedDamage[frame.url] = [raster.id]
        model.maskSeedUnsaved.insert(frame.url)
        model.isBalanced = true
        try await settle()
        let scroll = try #require(first(NSScrollView.self, in: host))
        let document = try #require(scroll.documentView)
        #expect(scroll.contentSize.height > 100)
        document.scrollToVisible(NSRect(x: 0, y: document.bounds.maxY - 8, width: 8, height: 8))
        #expect(scroll.documentVisibleRect.maxY >= document.bounds.maxY - 1)
    }

    @Test func editedCountIncludesEachChangedControlAndSavedObjectOnce() throws {
        let id = try #require(PatchID(hex: String(repeating: "a", count: 64)))
        let patch = try PatchRef(id: id, width: 16, height: 16)
        let removal = Removal(patch: patch, isOn: false)
        let mask = Self.mask(isEnabled: false)
        let lens = try LensSettings.default.setting(.purpleHueLow, to: 20)
            .settingDistortion(isOn: false)
        let curves = try ToneCurves.identity.setting(.green, to: ToneCurves.Preset.liftedBlacks.curve)
        let values = try ManualAdjustments(exposureEV: 0.35, shadows: 24)
            .settingPresence(Presence([.clarity: 10])).settingCurves(curves)
            .settingMasks(MaskSet(masks: [mask])).settingLens(lens).settingRemovals([removal])
        let edits = InspectorEdits(values)
        #expect(edits.light == [.light(.exposure), .light(.shadows), .presence(.clarity)])
        #expect(edits.curves == [.green])
        #expect(edits.lens == [.purpleHueLow] && edits.distortionChanged)
        #expect(edits.masks == [mask] && edits.removals == [removal])
        #expect(edits.count == 8)
        #expect(edits.summary(for: .curve, hasLensProfile: nil) == "Green shaped")
        #expect(edits.summary(for: .masks, hasLensProfile: nil) == "1 mask")
        #expect(edits.summary(for: .remove, hasLensProfile: nil) == "1 removal")
        #expect(InspectorEdits(.identity).count == 0)
    }

    @Test func clickingTheAdjustmentFilterKeepsFrameNavigationOnThePhotograph() async throws {
        struct FrameAndFilter: View {
            let roll: Roll
            let frame: Frame
            @State var requestsFilterFocus = false

            var body: some View {
                HStack(spacing: 0) {
                    FrameView(roll: roll, frame: frame).frame(width: 240)
                    AdjustFilterPicker(frame: frame, keyboardFocusRequested: $requestsFilterFocus).frame(width: 240)
                }
            }
        }

        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.openFrame()
        let roll = try #require(model.roll)
        let (window, host) = ContextMenuTests.window(FrameAndFilter(roll: roll, frame: frame).environment(model),
                                                     size: NSSize(width: 480, height: 200))
        defer { window.close() }
        for (x, filter) in [(420, AdjustInspectorFilter.edited), (300, .allTools)] {
            try ContextMenuTests.click(.leftMouseDown, at: NSPoint(x: x, y: 100), in: window)
            ContextMenuTests.settle(host)
            #expect(model.inspectorNavigation.filter == filter)
        }
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: right, charactersIgnoringModifiers: right, isARepeat: false, keyCode: 124))
        window.sendEvent(key)
        ContextMenuTests.settle(host)
        #expect(model.shownFrame?.url == roll.frames[1].url)
        #expect(model.inspectorNavigation.filter == .allTools)
    }

    @Test func editedControlsStayMountedUntilTheLiveGestureCommits() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = model.adjustTab, shown = model.isAdjustmentsShown
        defer { model.adjustTab = tab; model.isAdjustmentsShown = shown }
        model.openFrame()
        model.isAdjustmentsShown = true
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        model.manualEdits[frame.url] = try edit(on: frame)
        model.manualEdits[frame.url]?.adjustments = try ManualAdjustments(exposureEV: 0.3)
            .settingPresence(Presence([.clarity: 10])).setting(.lens(.greenAmount), to: 7)
        model.setInspectorFilter(.edited, for: frame)
        #expect(model.canAdjust(frame))

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ManualAdjustmentsView(frame: frame).environment(model))
        let root = try #require(window.contentView)
        func controls(_ group: AdjustmentSliderGroup) -> [AdjustmentSliderControl] {
            root.layoutSubtreeIfNeeded()
            return AdjustmentSliderControl.sliders(in: group, under: root)
        }
        for _ in 0..<200 where controls(.light).count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controls(.light).map(\.spec.title) == ["Exposure", "Clarity"])
        #expect(controls(.lens).map(\.spec.title) == ["Green Amount"])
        #expect(model.inspectorEdits(for: frame).count == 3)
        model.beginLightAdjusting(for: frame)
        model.moveLight(.presence(.clarity), to: 0, for: frame)
        #expect(model.inspectorEdits(for: frame).count == 2)
        #expect(controls(.light).map(\.spec.title) == ["Exposure", "Clarity"])
        model.endLightAdjusting(for: frame)
        for _ in 0..<200 where controls(.light).count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controls(.light).map(\.spec.title) == ["Exposure"])
        #expect(model.inspectorEdits(for: frame).count == 2)
        let green = try #require(controls(.lens).first)
        #expect(green.accessibilityPerformIncrement())
        #expect(model.manualAdjustments(for: frame).lens.defringe.greenAmount == 8)

        // The edited list is a single keyboard sequence. A stored midpoint has no effect until vignetting is on.
        let dormantMidpoint = try model.manualAdjustments(for: frame).setting(.lens(.vignetteMidpoint), to: 33)
        model.setManualAdjustments(dormantMidpoint, for: frame)
        for _ in 0..<200 where controls(.lens).count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let exposure = try #require(controls(.light).first)
        let amount = try #require(controls(.lens).first)
        #expect(controls(.lens).last?.isEnabled == false)
        func key(_ text: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: text,
                                          charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
        }
        #expect(window.makeFirstResponder(exposure))
        exposure.keyDown(with: try key("."))
        #expect(window.firstResponder === amount)
        amount.keyDown(with: try key("."))
        #expect(window.firstResponder === exposure)
        exposure.keyDown(with: try key(","))
        #expect(window.firstResponder === amount)

        #expect(window.makeFirstResponder(exposure))
        for _ in 0..<3 { exposure.keyDown(with: try key("-")) }
        for _ in 0..<100 where window.firstResponder !== amount { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controls(.light).isEmpty)
        #expect(window.firstResponder === amount)
        amount.keyDown(with: try key("="))
        #expect(model.manualAdjustments(for: frame).lens.defringe.greenAmount == 13)

        // A menu reset can remove the focused row and its neighbors together.
        model.setManualAdjustments(try model.manualAdjustments(for: frame).setting(.presence(.clarity), to: 5), for: frame)
        for _ in 0..<100 where controls(.light).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let clarity = try #require(controls(.light).first)
        model.resetLens(for: frame)
        for _ in 0..<100 where window.firstResponder !== clarity { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controls(.lens).isEmpty && window.firstResponder === clarity)

        // Removing the last enabled row leaves Left on the filter.
        window.makeKeyAndOrderFront(nil)
        ContextMenuTests.settle(root)
        #expect(window.makeFirstResponder(clarity))
        clarity.keyDown(with: try key("-"))
        for _ in 0..<100 where !controls(.light).isEmpty || !(window.firstResponder is NSView) || window.firstResponder === clarity {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controls(.light).isEmpty)
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: left, charactersIgnoringModifiers: left, isARepeat: false, keyCode: 123))
        window.sendEvent(arrow)
        ContextMenuTests.settle(root)
        #expect(model.inspectorNavigation.filter == .allTools)
    }

    // MARK: The Masks tab's words

    private static func mask(components: Int = 1, values: ManualAdjustments = .identity, amount: Float = 1, isEnabled: Bool = true) -> Mask {
        let shape = MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: 0.5))))
        return Mask(isEnabled: isEnabled, components: Array(repeating: shape, count: components), amount: amount, adjustments: values)
    }

    /// What VoiceOver says of a row after its name.
    @Test func aRowsSpokenValueSaysWhetherItIsSelectedAndOn() {
        #expect(MaskSummary.spoken(Self.mask(), isSelected: true, status: nil) == "Selected, on, Linear gradient")
        #expect(MaskSummary.spoken(Self.mask(isEnabled: false), isSelected: false, status: nil) == "off, Linear gradient")
        let status = SmartRowStatus.stale(.sky)
        #expect(MaskSummary.spoken(Self.mask(), isSelected: false, status: status) == "on, \(status.text)")
    }

    @Test func aMasksRowSaysItsBalance() {
        var mask = Self.mask()
        mask.balance = MaskBalance(warmth: -40, magenta: 12)
        let warmth = AdjustmentSliderSpec.maskBalance(.warmth).formatted(-40), magenta = AdjustmentSliderSpec.maskBalance(.magenta).formatted(12)
        #expect(MaskSummary.line(for: mask) == "Warmth \(warmth), Magenta \(magenta)")
        // The panel's Balance group says the same beside its name while it is folded, and its Light group that nothing moved.
        #expect(MaskSummary.balance(of: mask) == "Warmth \(warmth), Magenta \(magenta)")
        #expect(MaskSummary.light(of: mask) == MaskSummary.unmoved)
    }

    @Test func aMasksRowSaysWhatItDoes() throws {
        #expect(MaskSummary.line(for: Self.mask()) == "Linear gradient")
        #expect(MaskSummary.line(for: Self.mask(components: 3)) == "Linear gradient and 2 more")
        let exposure = AdjustmentSliderSpec.light(.exposure).formatted(-0.6), shadows = AdjustmentSliderSpec.light(.shadows).formatted(25)
        #expect(MaskSummary.line(for: Self.mask(values: try ManualAdjustments(exposureEV: -0.6))) == "Exposure \(exposure)")
        #expect(MaskSummary.line(for: Self.mask(values: try ManualAdjustments(exposureEV: -0.6, shadows: 25))) == "Exposure \(exposure), Shadows \(shadows)")
        // Amount counts only where there is something for it to scale.
        #expect(MaskSummary.line(for: Self.mask(values: try ManualAdjustments(shadows: 25), amount: 0.5)) == "Shadows \(shadows), Amount 50")
        #expect(MaskSummary.line(for: Self.mask(amount: 0.5)) == "Linear gradient")
        let frame = try MaskFrame(orientation: 1, width: 600, height: 400, decoder: .apple, lensCorrection: true)
        #expect(MaskSummary.line(for: Mask(components: [MaskComponent(shape: .brush(BrushPaint(frame: frame)))])) == "Brush strokes")
        // A row never says a folded group's "No changes": with nothing moved it says what the mask is.
        for mask in [Self.mask(), Self.mask(components: 2), Self.mask(amount: 0)] {
            #expect(!MaskSummary.line(for: mask).contains(MaskSummary.unmoved))
        }
        #expect(MaskSummary.title(of: .smart(SmartSelection(kind: .sky))) == "Sky")
    }

    /// A folded group of the selected mask's panel says what it holds, in the list row's words, or that nothing in it has
    /// moved: at any Amount, which scales the group's rows and is none of them.
    @Test func aFoldedGroupSaysWhatItHolds() throws {
        #expect(MaskSummary.unmoved == "No changes")
        for mask in [Self.mask(), Self.mask(amount: 2), Self.mask(amount: 0)] {
            #expect(MaskSummary.light(of: mask) == "No changes" && MaskSummary.balance(of: mask) == "No changes")
        }
        let exposure = AdjustmentSliderSpec.light(.exposure).formatted(-0.6), shadows = AdjustmentSliderSpec.light(.shadows).formatted(25)
        let moved = Self.mask(values: try ManualAdjustments(exposureEV: -0.6, shadows: 25), amount: 0.5)
        #expect(MaskSummary.light(of: moved) == "Exposure \(exposure), Shadows \(shadows)")
        #expect(MaskSummary.balance(of: moved) == "No changes")
        for control in ManualAdjustments.Control.allCases {
            #expect(MaskSummary.light(of: Self.mask(values: try ManualAdjustments.identity.setting(control, to: 1))).hasPrefix(control.title), "\(control)")
        }
    }

    /// Light is open at first, and Balance and the shape's numbers folded; a group opens and folds by itself.
    @Test func theSelectedMasksGroupsFoldEachByItself() async throws {
        let (model, _, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = model.maskEditor
        #expect(editor.openGroups == [.light])
        editor.toggle(.balance)
        #expect(editor.openGroups == [.light, .balance])
        editor.toggle(.light)
        #expect(editor.openGroups == [.balance])
        // Another frame, or the tab left, puts down the tool and the selection, not how the panel was left.
        editor.reset()
        #expect(editor.openGroups == [.balance])
    }

    @Test func aTileIsLiveForTheBrushAndTheGradients() {
        #expect(MaskTile.linear.tool == .linear && MaskTile.radial.tool == .radial && MaskTile.brush.tool == .brush)
        for tile in [MaskTile.subject, .sky, .person, .background] {
            #expect(tile.tool == nil, "\(tile)")
        }
        // Chosen while its tool is in hand for a new mask, not while adding to one.
        #expect(MaskCopy.isChosen(.linear, tool: .linear, operation: nil))
        #expect(!MaskCopy.isChosen(.linear, tool: .radial, operation: nil))
        #expect(!MaskCopy.isChosen(.linear, tool: .linear, operation: .subtract))
        #expect(!MaskCopy.isChosen(.sky, tool: nil, operation: nil))
    }

    @Test func theTabsWordsAndTheToolsActionNames() {
        #expect(MaskCopy.needsUpdate.contains("Update Automatic Baseline"))
        #expect(MaskEditor.Tool.linear.actionName(adding: nil) == "Add Linear Gradient")
        #expect(MaskEditor.Tool.radial.actionName(adding: .intersect) == "Intersect Radial")
    }

    private func defaults() -> UserDefaults { ScratchDefaults() }

    @Test func thereAreFiveTabsInTheirOrder() {
        #expect(AdjustInspectorTab.allCases == [.light, .curve, .masks, .lens, .remove])
    }

    @Test func theOldBoolIsReadOnceAndMoved() throws {
        // A last session on Curve.
        let curve = defaults()
        curve.set(true, forKey: AdjustInspectorTab.legacyCurvesKey)
        #expect(AdjustInspectorTab.stored(in: curve) == .curve)
        #expect(curve.string(forKey: AdjustInspectorTab.storageKey) == "curve")
        #expect(curve.object(forKey: AdjustInspectorTab.legacyCurvesKey) == nil)
        // Read once: nothing brings it back or lets it speak again.
        curve.set(false, forKey: AdjustInspectorTab.legacyCurvesKey)
        #expect(AdjustInspectorTab.stored(in: curve) == .curve)
        #expect(curve.object(forKey: AdjustInspectorTab.legacyCurvesKey) != nil)

        // A last session on Light.
        let light = defaults()
        light.set(false, forKey: AdjustInspectorTab.legacyCurvesKey)
        #expect(AdjustInspectorTab.stored(in: light) == .light)
        #expect(light.string(forKey: AdjustInspectorTab.storageKey) == "light")
        #expect(light.object(forKey: AdjustInspectorTab.legacyCurvesKey) == nil)
    }

    @Test func aFreshInstallOpensOnLightAndTheNewKeyWins() throws {
        let fresh = defaults()
        #expect(AdjustInspectorTab.stored(in: fresh) == .light)
        #expect(fresh.string(forKey: AdjustInspectorTab.storageKey) == nil)

        let both = defaults()
        both.set("lens", forKey: AdjustInspectorTab.storageKey)
        both.set(true, forKey: AdjustInspectorTab.legacyCurvesKey)
        #expect(AdjustInspectorTab.stored(in: both) == .lens)

        let unknown = defaults()
        unknown.set("ranges", forKey: AdjustInspectorTab.storageKey)
        #expect(AdjustInspectorTab.stored(in: unknown) == .light)
    }

    @Test func thePickerOffersThePlansTiles() {
        // Three that are drawn and four that are found: every tile in one group or the other, and none left over.
        #expect(MaskTile.draw == [.brush, .linear, .radial])
        #expect(MaskTile.find == [.subject, .sky, .person, .background])
        #expect(MaskTile.draw + MaskTile.find == MaskTile.allCases)
        #expect(MaskTile.draw.allSatisfy { $0.tool != nil } && MaskTile.find.allSatisfy { $0.smartKind != nil })
        #expect(MaskTile.allCases.map(\.title) == ["Brush", "Linear", "Radial", "Subject", "Sky", "Person", "Background"])
        #expect(MaskTile.sky.accessibilityLabel == "Add sky mask")
        #expect(MaskTile.linear.accessibilityLabel == "Add linear gradient mask")
    }

    @Test func aTileSaysItsKeyOrWhatTheFrameWaitsFor() {
        #expect(MaskTile.brush.help(preparing: nil) == "Paint a mask. K.")
        #expect(MaskTile.linear.help(preparing: nil) == "Draw a linear gradient. M.")
        #expect(MaskTile.radial.help(preparing: nil) == "Draw a radial gradient. Shift-M.")
        #expect(MaskTile.sky.help(preparing: nil) == "Find the sky and mask it.")
        for tile in MaskTile.allCases {
            #expect(tile.help(preparing: "Balancing roll…") == "Balancing roll…")
        }
    }

    /// A row bound to something other than the frame's Light values, whose default is not zero.
    @Test func aRowOfAnySpecResetsToItsOwnDefaultInOneGesture() async throws {
        @MainActor final class Bound {
            var value: Float = 150
            var gestures: [String] = []
        }
        let (model, _, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bound = Bound()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView:
            ManualAdjustmentRow(spec: .maskAmount, help: "Scales the mask's sliders.",
                                value: Binding(get: { bound.value }, set: { bound.value = $0 }), snapshot: 1,
                                beginGesture: { bound.gestures.append("begin") }, endGesture: { bound.gestures.append("end") })
                .environment(model))
        let root = try #require(window.contentView)
        var found: AdjustmentSliderControl?
        for _ in 0..<200 where found == nil {
            root.layoutSubtreeIfNeeded()
            found = AdjustmentSliderControl.sliders(in: .mask, under: root).first
            try await Task.sleep(for: .milliseconds(10))
        }
        let slider = try #require(found)
        #expect(slider.spec == .maskAmount && slider.minValue == 0 && slider.maxValue == 200 && slider.doubleValue == 150)
        #expect(slider.accessibilityLabel() == "Amount" && slider.accessibilityValueDescription() == 150.formatted())

        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: slider.convert(NSPoint(x: 20, y: 12), to: nil), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        slider.mouseDown(with: click)
        #expect(bound.value == 100)
        #expect(bound.gestures == ["begin", "end"])
        // Back at its default a reset is nothing, and no undo step.
        slider.mouseDown(with: click)
        #expect(bound.gestures == ["begin", "end"])
    }

    @Test func lightDrawsAnExposureScaleThenSixRowsWithPresenceFolded() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = model.adjustTab
        defer { model.adjustTab = tab }
        model.adjustTab = .light
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ManualAdjustmentsView(frame: frame).environment(model))
        let root = try #require(window.contentView)
        func sliders() -> [AdjustmentSliderControl] {
            root.layoutSubtreeIfNeeded()
            return AdjustmentSliderControl.sliders(in: .light, under: root)
        }

        let light = ManualAdjustments.Control.allCases.map(ManualAdjustments.Slider.light)
        for _ in 0..<200 where sliders().count < light.count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sliders().map(\.spec) == light.map { AdjustmentSliderSpec.light($0) })
        let exposure = try #require(sliders().first)
        #expect(exposure.showsEVScale && exposure.accessibilityValueDescription() == "0.00 EV")
        #expect(sliders().dropFirst().allSatisfy { !$0.showsEVScale })
        #expect(Self.frame(of: exposure).width < Graphite.Metric.adjustColumn)
        #expect(sliders().dropFirst().allSatisfy { abs(Self.frame(of: $0).width - Graphite.Metric.adjustColumn) < 0.5 })
        #expect(sliders().allSatisfy { !$0.isEnabled })

        model.isInspectorPresenceExpanded = true
        let all = light + Presence.Control.allCases.map(ManualAdjustments.Slider.presence)
        for _ in 0..<200 where sliders().count < all.count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sliders().map { $0.accessibilityLabel() } == all.map(\.title))
        #expect(sliders().map { $0.accessibilityValueDescription() } == all.map { AdjustmentSliderSpec.light($0).spoken(0) })
        #expect(sliders().first?.accessibilityCustomActions()?.map(\.name) == ["Reset exposure"])
        #expect(sliders().last?.accessibilityCustomActions()?.map(\.name) == ["Reset saturation"])
        let frames = sliders().map(Self.frame(of:))
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.minY > $1.minY })

        model.toggleInspectorSection(.light, for: frame)
        for _ in 0..<200 where !sliders().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sliders().isEmpty && model.openAdjustSection == nil)
        model.showInspector(tab: .masks)
        #expect(sliders().isEmpty && model.openAdjustSection == .masks)
        #expect(!model.canAdjust(frame))
        #expect(model.adjustPreparation(for: frame) != nil)
    }

    /// The Light tab as it is drawn on a frame that can be adjusted: the eleven are enabled together, `.` goes on from Light's last
    /// into Presence's first, and Option on a Presence slider asks for no clipping view, where Exposure's asks for clipped
    /// highlights, so a Presence drag never asks for the clipping probe.
    @Test func aReadyFramesElevenAreOneWalkAndPresenceShowsNoClippingView() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = model.adjustTab
        defer { model.adjustTab = tab; model.lightClipping = nil }
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        model.manualEdits[frame.url] = try edit(on: frame)
        model.adjustTab = .light
        model.isInspectorPresenceExpanded = true
        #expect(model.canAdjust(frame))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ManualAdjustmentsView(frame: frame).environment(model))
        let root = try #require(window.contentView)
        func sliders() -> [AdjustmentSliderControl] {
            root.layoutSubtreeIfNeeded()
            return AdjustmentSliderControl.sliders(in: .light, under: root)
        }
        let count = (ManualAdjustments.Control.allCases.count + Presence.Control.allCases.count), light = ManualAdjustments.Control.allCases.count
        for _ in 0..<200 where sliders().count < count || !sliders().allSatisfy(\.isEnabled) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sliders().count == count && sliders().allSatisfy(\.isEnabled))

        let blacks = sliders()[light - 1], texture = sliders()[light]
        #expect(blacks.spec.title == "Blacks" && texture.spec.title == "Texture")
        #expect(window.makeFirstResponder(blacks))
        blacks.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: ".", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47)))
        #expect(window.firstResponder === texture)

        let exposure = sliders()[0]
        for presence in sliders()[light...] {
            exposure.onClipping?(true)
            #expect(model.lightClipping == .highlights)
            presence.onClipping?(true)
            #expect(model.lightClipping == nil, "\(presence.spec.title)")
        }
    }

    /// The Masks tab as it is drawn, with a mask selected: Amount first, the six Light rows, then the gradient's
    /// numbers, all in the mask's group so `.` and `,` walk them, and a slider's move is one step of its own name. At first
    /// Amount and Light's six alone are drawn, Balance and the gradient's numbers being folded; with every group open, all fifteen.
    @Test func aSelectedMasksPanelDrawsTheLightRows() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = model.adjustTab, shown = model.isAdjustmentsShown
        defer { model.maskEditor.reset(); model.adjustTab = tab; model.isAdjustmentsShown = shown }
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        model.manualEdits[frame.url] = try edit(on: frame)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.manualUndoManager = undo
        model.selection = frame.id
        model.openFrame()
        model.adjustTab = .masks
        model.isAdjustmentsShown = true
        model.perform(.newMask(.radial))
        undo.beginUndoGrouping()
        #expect(model.placeArmedGradient())
        undo.endUndoGrouping()
        let id = try #require(model.masks(for: frame).first?.id)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 1400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ManualAdjustmentsView(frame: frame).environment(model))
        let root = try #require(window.contentView)
        func sliders() -> [AdjustmentSliderControl] {
            root.layoutSubtreeIfNeeded()
            return AdjustmentSliderControl.sliders(in: .mask, under: root)
        }
        for _ in 0..<300 where sliders().count < 7 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sliders().map(\.spec.title) == ["Amount"] + ManualAdjustments.Control.allCases.map(\.title))
        model.maskEditor.openGroups = [.light, .balance, .shape]
        for _ in 0..<300 where sliders().count < 15 { try await Task.sleep(for: .milliseconds(10)) }
        let titles = sliders().map(\.spec.title)
        #expect(titles == ["Amount"] + ManualAdjustments.Control.allCases.map(\.title) + ["Warmth", "Magenta", "Feather", "Centre X", "Centre Y", "Width", "Height", "Angle"])
        for title in titles {
            #expect(Self.nameWithArrow(title) + AdjustRowMetric.spacing + AdjustRowMetric.value <= Graphite.Metric.adjustColumn,
                    "\(title) takes \(Self.nameWithArrow(title))")
        }
        #expect(sliders().first?.spec == .maskAmount && sliders().first?.doubleValue == 100)
        #expect(sliders().allSatisfy { $0.isEnabled })
        // No Light slider is on screen for `.` and `,` to walk into.
        #expect(AdjustmentSliderControl.sliders(in: .light, under: root).isEmpty)

        // One real key on the Exposure slider: its value lands on the mask, as its own step, and hides the overlay meanwhile.
        let exposure = try #require(sliders().first { $0.spec.title == "Exposure" })
        undo.beginUndoGrouping()
        #expect(exposure.accessibilityPerformIncrement())
        undo.endUndoGrouping()
        #expect(model.mask(id, for: frame)?.adjustments.exposureEV == AdjustmentSliderSpec.light(.exposure).arrowStep)
        #expect(model.manualAdjustments(for: frame).exposureEV == 0.3, "the frame's own Exposure is not the mask's")
        #expect(undo.undoActionName == "Adjust Mask" && !model.maskEditor.isAdjusting)
        undo.undo()
        #expect(model.mask(id, for: frame)?.adjustments.exposureEV == 0)
        // Feather's row writes the shape, and its step is the gradient's.
        let feather = try #require(sliders().first { $0.spec.title == "Feather" })
        #expect(feather.doubleValue == 50)
        undo.beginUndoGrouping()
        #expect(feather.accessibilityPerformDecrement())
        undo.endUndoGrouping()
        guard case .radial(let g)? = model.mask(id, for: frame)?.components[0].shape else { Issue.record("not radial"); return }
        #expect(g.feather == 49 && undo.undoActionName == "Adjust Gradient" && !model.maskEditor.isShaping)
    }

    /// Every row fits the column's 248 points (`Graphite.Metric.adjustColumn`): the tab's widest row sets the whole column's
    /// width, and a row past it pushes the tab's controls out of the panel. Each state of the tab that adds a row, with every
    /// group of the panel open.
    @Test func everyRowOfTheMasksTabFitsItsColumn() async throws {
        let (model, frame, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = model.adjustTab, shown = model.isAdjustmentsShown
        defer { model.maskEditor.reset(); model.adjustTab = tab; model.isAdjustmentsShown = shown }
        let verified = try SourceDigests.shared.digest(of: frame.url)
        model.manualReadySources[frame.url] = verified
        model.record(FrameMeasurement(analysis: ExposureAnalysis(meanStops: 0.3, validWeight: 1), source: verified.source), for: frame)
        model.manualEdits[frame.url] = try edit(on: frame)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.manualUndoManager = undo
        model.selection = frame.id
        model.openFrame()
        model.adjustTab = .masks
        model.isAdjustmentsShown = true
        model.maskEditor.openGroups = [.light, .balance, .shape]
        _ = NSApplication.shared
        func width() -> CGFloat {
            let view = NSHostingView(rootView: MasksInspector(frame: frame).environment(model).fixedSize())
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.width
        }
        // Measured at their ideal width. The empty tab's and a tool's sentences wrap, so an ideal says nothing there.
        model.perform(.newMask(.radial))
        undo.beginUndoGrouping()
        #expect(model.placeArmedGradient())
        undo.endUndoGrouping()
        #expect(width() <= Graphite.Metric.adjustColumn, "a radial selected")
        // The tiles are in Add's popover, which a view in no window never presents, and on a frame with no mask they are the
        // tab: measured by themselves, as either holds them, the seven with their two headings.
        let tiles = NSHostingView(rootView: MaskPicker(frame: frame).environment(model).fixedSize())
        tiles.layoutSubtreeIfNeeded()
        #expect(tiles.fittingSize.width <= Graphite.Metric.adjustColumn, "the tiles take \(tiles.fittingSize.width)")
        #expect(tiles.fittingSize.width > 0)
        model.perform(.newMask(.linear))
        undo.beginUndoGrouping()
        #expect(model.placeArmedGradient())
        undo.endUndoGrouping()
        #expect(width() <= Graphite.Metric.adjustColumn, "a linear selected")
        model.maskEditor.renaming = model.maskEditor.selection?.mask
        #expect(width() <= Graphite.Metric.adjustColumn, "a name being typed")
        model.maskEditor.renaming = nil
        model.maskEditor.isOverlayOn = true
        model.maskEditor.overlayColour = .green
        defer { model.maskEditor.overlayColour = .red }
        #expect(width() <= Graphite.Metric.adjustColumn, "the longest colour")
    }
}
