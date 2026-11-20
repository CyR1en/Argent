import AppKit
@testable import ArgentRoll
import Foundation
import SwiftUI
import Testing
@testable import ArgentApp

/// The Graphite shell read from the model: the rail's pages, views and tools, and what the title
/// strip says about the roll and the open frame.
@MainActor @Suite(.serialized) struct WorkspaceStateTests {
    /// A model without stocks over a roll of `raws` header-only raws, its bookmarks, recipes and
    /// flags in a folder of the run's own.
    private static func withRoll(raws: Int = 3, _ body: @MainActor (RollModel) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-workspace-\(UUID().uuidString)")
        let roll = folder.appendingPathComponent("Workspace roll"), library = folder.appendingPathComponent("Library")
        for directory in [roll, library] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<raws { try writeHeader(roll.appendingPathComponent("DSC\(index + 1).ARW")) }
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: library, decisions: AutoDecisionStore(library: library), flagStore: FlagStore(library: library),
                              recipeLibrary: library, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        await model.open(roll)
        try await body(model)
        await model.flagSave?.value
    }

    /// A raw's header alone, of a unique size so no two runs share a digest: enough for the scan.
    private static func writeHeader(_ url: URL) throws {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8 & 255)] }
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 255) } }
        let exif = 8 + 2 + 12 + 4
        var bytes = [UInt8]([0x49, 0x49]) + u16(42) + u32(8)
        bytes += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(exif) + u32(0)
        bytes += u16(1) + u16(0x8827) + u16(3) + u32(1) + u16(100) + u16(0) + u32(0)
        try (Data(bytes) + Data(UUID().uuidString.utf8)).write(to: url, options: .atomic)
    }

    /// The inspector's scroll view ran up under the window's title bar, where its clip hid it but
    /// did not stop it taking clicks: with Adjust open, Compare and Develop did nothing (2026-11-05),
    /// as with the zoomed photograph before it (2026-11-04). The title strip comes first. Since 2026-11-17 the panel's
    /// head, its heading, histogram and tabs, stands over the scroll view, which begins under them and no longer reaches
    /// the strip; the strip's clicks are asked for all the same, across the inspector's column.
    @Test func withAdjustOpenTheTitleStripKeepsItsClicks() async throws {
        try await Self.withRoll { model in
            let wasShown = model.isAdjustmentsShown
            defer { model.isAdjustmentsShown = wasShown }
            model.selection = try #require(model.roll?.frames.first?.id)
            model.openFrame()
            model.isAdjustmentsShown = true

            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860), styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = NSHostingView(rootView: ContentView().environment(model))

            @MainActor func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            @MainActor func isInTheInspectorsColumn(_ view: NSScrollView) -> Bool {
                view.convert(view.bounds, to: nil).minX > 800
            }
            let root = try #require(window.contentView?.superview)
            var panel: NSScrollView?
            for _ in 0..<200 where panel == nil {
                root.layoutSubtreeIfNeeded()
                panel = scrollViews(in: root).first(where: isInTheInspectorsColumn)
                try await Task.sleep(for: .milliseconds(10))
            }
            // What makes this a test of anything: the panel is up, and its scroll view is in its column.
            let scroller = try #require(panel, "no scroll view in the inspector's column")
            let column = scroller.convert(scroller.bounds, to: nil)
            #expect(column.maxY <= window.frame.height - Graphite.Metric.titleStripHeight, "the panel's scroll view runs under the title strip")

            for x in stride(from: column.minX + 8, through: column.maxX - 8, by: 40) {
                let point = NSPoint(x: x, y: window.frame.height - Graphite.Metric.titleStripHeight / 2)
                var view = root.hitTest(point)
                while let found = view {
                    #expect(!(found is NSScrollView), "a click at \(point) goes to the scroll view")
                    view = found.superview
                }
            }
        }
    }

    @Test func withoutARollTheWorkspaceIsRollsUntilSettingsIsAskedFor() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: folder, decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        #expect(model.workspacePage == .rolls)
        model.showWorkspacePage(.settings)
        #expect(model.workspacePage == .settings)
        // Roll in the rail without a roll still shows Rolls.
        model.showRoll()
        #expect(model.workspacePage == .rolls)
        // And so does its Develop page.
        model.showDevelopPage()
        #expect(model.workspacePage == .rolls)
    }

    /// Develop in the rail: the roll's Develop page, from the sheet or the frame view, which closing it goes back
    /// to; a frame opened from its grid opens on the roll.
    @Test func theDevelopPageOpensFromTheRollAndGoesBackToWhereItWasLeft() async throws {
        try await Self.withRoll { model in
            let frames = try #require(model.roll?.frames)
            model.toggleDevelopPage()
            #expect(model.workspacePage == .develop && !model.isFrameOpen)
            model.toggleDevelopPage()
            #expect(model.workspacePage == .roll && !model.isFrameOpen)

            // From the frame view the frame closes under the page's grid, and the page's close goes back to the
            // frame view, on the frame selected in the grid by then.
            model.selection = frames[0].id
            model.showFrame()
            model.showDevelopPage()
            #expect(model.workspacePage == .develop && !model.isFrameOpen && model.selection == frames[0].id)
            // The title names the roll and the frames the page shows, never the frame that was open.
            let title = WorkspaceTopBar.context(model)
            #expect(title.title == "Workspace roll" && title.subtitle == "3 frames")
            model.selection = frames[2].id
            // Settings over the page, then the rail's Develop: the page again, with the same way back.
            model.showWorkspacePage(.settings)
            model.toggleDevelopPage()
            #expect(model.workspacePage == .develop)
            model.closeDevelopPage()
            #expect(model.workspacePage == .roll && model.isFrameOpen && model.shownFrame?.id == frames[2].id)

            // A frame opened from the grid opens on the roll.
            model.showRoll()
            model.showDevelopPage()
            model.selection = frames[1].id
            model.openFrame()
            #expect(model.workspacePage == .roll && model.isFrameOpen && model.shownFrame?.id == frames[1].id)
            // The rail's Roll from the page is the sheet, whatever the page was opened from.
            model.showDevelopPage()
            model.showRoll()
            #expect(model.workspacePage == .roll && !model.isFrameOpen)

            // The Details popover goes with its page.
            model.showDevelopPage()
            model.isIssueDetailsShown = true
            model.closeDevelopPage()
            #expect(!model.isIssueDetailsShown)
        }
    }

    @Test func theRailMovesBetweenTheSheetTheFrameAndItsTools() async throws {
        try await Self.withRoll { model in
            #expect(model.workspacePage == .roll)
            #expect(!model.isFrameOpen)

            model.showFrame()
            #expect(model.isFrameOpen)
            model.showRoll()
            #expect(!model.isFrameOpen)

            // Adjust from the sheet opens the selected frame with its inspector.
            model.isAdjustmentsShown = false
            model.toggleAdjust()
            #expect(model.isFrameOpen && model.isAdjustmentsShown)
            model.toggleAdjust()
            #expect(model.isFrameOpen && !model.isAdjustmentsShown)

            // Settings, then Adjust: back to the roll with the inspector rather than closing it.
            model.showWorkspacePage(.settings)
            model.toggleAdjust()
            #expect(model.workspacePage == .roll && model.isAdjustmentsShown)

            // Stock from another page opens the panel on the roll; again closes it.
            model.isStockPanelShown = false
            model.showWorkspacePage(.rolls)
            model.toggleStockPanel()
            #expect(model.workspacePage == .roll && model.isStockPanelShown)
            model.toggleStockPanel()
            #expect(!model.isStockPanelShown)

            // The split comparison is the frame view's and ends with it.
            model.isSplitComparing = true
            model.showRoll()
            #expect(!model.isSplitComparing)
        }
    }

    @Test func leavingRollsForTheRollLetsGoOfAFailedOpensLine() async throws {
        try await Self.withRoll { model in
            model.showWorkspacePage(.rolls)
            model.message = "Gone roll is not available"
            model.showRoll()
            #expect(model.message == nil)

            // A line over the roll itself stays until closed, whatever page the rail shows next.
            model.message = "Drop a folder or a card, not single files"
            model.showWorkspacePage(.settings)
            model.showWorkspacePage(.roll)
            #expect(model.message == "Drop a folder or a card, not single files")
        }
    }

    @Test func aRollThatCannotBeReachedIsMarkedUntilItOpensAgain() async throws {
        try await Self.withRoll { model in
            let first = try #require(model.roll?.folder)
            let gone = first.deletingLastPathComponent().appendingPathComponent("Gone roll")
            try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
            try Self.writeHeader(gone.appendingPathComponent("DSC1.ARW"))
            await model.open(gone)
            await model.open(first)
            let recent = try #require(model.recents.first { $0.name == "Gone roll" })
            try FileManager.default.removeItem(at: gone)

            model.openRecent(path: recent.path)
            #expect(model.message == "Gone roll is not available")

            // On the Rolls page the roll is marked, and a click tries again.
            let entry = try #require(model.library.first { $0.name == "Gone roll" })
            model.message = nil
            model.openLibraryRoll(id: entry.id)
            #expect(model.message == "Gone roll is not available")
            #expect(model.unavailableRolls == [entry.id])
            try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
            try Self.writeHeader(gone.appendingPathComponent("DSC1.ARW"))
            await model.open(gone)
            #expect(model.unavailableRolls.isEmpty)
        }
    }

    @Test func aRollOpeningShowsItsSheetWhateverPageWasUp() async throws {
        try await Self.withRoll { model in
            model.showWorkspacePage(.rolls)
            await model.open(model.roll!.folder)
            #expect(model.workspacePage == .roll)
        }
    }

    @Test func theTitleNamesTheRollAndWhatTheSheetShows() async throws {
        try await Self.withRoll { model in
            let sheet = WorkspaceTopBar.context(model)
            #expect(sheet.title == "Workspace roll")
            #expect(sheet.subtitle == "3 frames")
            #expect(sheet.badge == nil)
            // Its detail is the whole line the heading gave.
            #expect(sheet.detail == RollHeading.subtitle(model))
        }
    }

    @Test func autoReadyIsSaidOnceByTheDockOrElseByTheTitle() async throws {
        try await FlagStateTests.withRoll { fixture in
            let model = FlagStateTests.model(fixture), gate = MeasurementGate()
            _ = try await FlagStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            _ = try #require(await model.settledDecision())
            #expect(AutoStatusLabel.text(model) == "Auto ready")
            // A dock short of room drops its Auto line, and the title says it instead.
            #expect(WorkspaceTopBar.context(model).subtitle.hasSuffix(" · Auto ready"))
            #expect(!WorkspaceTopBar.context(model, dockShowsAuto: true).subtitle.contains("Auto"))
        }
    }

    @Test func inTheFrameViewTheTitleSaysWhereTheFrameIsAndWhatSetsItApart() async throws {
        try await Self.withRoll { model in
            model.selection = 1
            model.openFrame()
            let frame = try #require(model.shownFrame)
            #expect(WorkspaceTopBar.context(model).subtitle == "2 of 3 · \(frame.name)")

            model.setRatedAt(.oneStopUnder, for: frame)
            #expect(WorkspaceTopBar.context(model).subtitle == "2 of 3 · \(frame.name) · Own settings")
            #expect(WorkspaceTopBar.context(model).detail.hasPrefix("\(frame.name), "))

            model.clearOverrides(for: frame)
            #expect(WorkspaceTopBar.context(model).subtitle == "2 of 3 · \(frame.name)")

            // A flagged frame says so on its own line; no badge sits by the roll's name.
            model.setFlag(true, for: frame)
            #expect(model.isFlagged(frame))
            #expect(WorkspaceTopBar.context(model).subtitle == "2 of 3 · \(frame.name) · Flagged")
            // A narrow title keeps the name and the flag before the place in the roll.
            #expect(WorkspaceTopBar.context(model).shortSubtitle == "\(frame.name) · Flagged")
            #expect(WorkspaceTopBar.context(model).badge == nil)
        }
    }
}
