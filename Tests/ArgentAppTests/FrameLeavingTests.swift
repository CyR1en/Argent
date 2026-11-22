import AppKit
import SwiftUI
import Testing
@testable import ArgentApp

/// The frame view on its way back to the sheet, in an attached workspace: how long it stays in the window once the frame
/// is closed, and what a click finds meanwhile. SwiftUI keeps a view that leaves on a transition, drawn and taking
/// clicks, until its animation has ended, and its own spring ends long after it has stopped moving (`RestingSpring`).
@MainActor @Suite(.serialized) struct FrameLeavingTests {
    /// A roll of 24 frames on a sheet of large cells in a window the size of a laptop's screen, its eighth frame selected:
    /// the frame view's way to a cell is then long enough for SwiftUI's own spring to keep it 1.3 s.
    private func withWorkspace(_ body: @MainActor (RollModel, NSView) async throws -> Void) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            for index in AutoDecisionStateTests.names.count..<24 {
                let raw = fixture.roll.appendingPathComponent("Extra-\(index).ARW")
                try writeSequenceHeader(raw, captured: AutoDecisionStateTests.captured(index), tail: Data(UUID().uuidString.utf8))
            }
            let model = fixture.model()
            await model.open(fixture.roll)
            let wasShown = model.isAdjustmentsShown
            model.isAdjustmentsShown = false
            defer { model.isAdjustmentsShown = wasShown }
            let (window, host) = ContextMenuTests.window(ContentView().environment(model), size: CGSize(width: 1512, height: 950))
            defer { window.close() }
            model.changeSize(by: 1)
            model.changeSize(by: 1)
            model.selection = 7
            try await Task.sleep(for: .milliseconds(600))
            try await body(model, host)
        }
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    /// The sheet's scroll view, the one in the window now.
    private func sheetScroller(_ host: NSView) throws -> NSScrollView {
        let found = views(NSScrollView.self, in: host).first { $0.documentView is SheetCollectionView }
        return try #require(found)
    }

    /// Whether the frame view is in the window, by the mask canvas it holds.
    private func hasFrameView(_ host: NSView) -> Bool { !views(MaskCanvasView.self, in: host).isEmpty }

    /// Waits until the frame view is in the window, or is not, for no longer than `seconds`; the seconds it took, or
    /// `nil` if it did not happen.
    private func wait(for shown: Bool, in host: NSView, atMost seconds: TimeInterval) async throws -> TimeInterval? {
        let start = CACurrentMediaTime()
        while hasFrameView(host) != shown {
            guard CACurrentMediaTime() - start < seconds else { return nil }
            try await Task.sleep(for: .milliseconds(10))
        }
        return CACurrentMediaTime() - start
    }

    /// Opens the frame, closes it `open` later, and says how long the frame view then stayed in the window: the least of
    /// up to three tries, since a main thread busy with another suite can only keep it longer.
    private func secondsToLeave(_ model: RollModel, _ host: NSView, closedAfter open: Duration, within limit: TimeInterval) async throws -> TimeInterval {
        var least = TimeInterval.infinity
        for _ in 0..<3 where least >= limit {
            model.openFrame()
            try #require(try await wait(for: true, in: host, atMost: 2) != nil)
            try await Task.sleep(for: open)
            model.closeFrame()
            least = min(least, try #require(try await wait(for: false, in: host, atMost: 6)))
        }
        return least
    }

    @Test func theFrameViewLeavesOnASpringThatEndsAtRestToTheEye() {
        #expect(Graphite.Motion.hero.base is RestingSpring)
    }

    /// How long a closed frame's view stays in the window, by the clock, so only when asked for (`ARGENT_MEASURE=1`) and
    /// run by itself: beside the other suites the main thread is theirs for much of a second at a time. About 0.7 s
    /// either way; with SwiftUI's own spring 1.3 s here, and 3.2 s for a frame with its picture in it, closed before its
    /// way in had settled, which stayed drawn over a sheet that could be scrolled under it meanwhile.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"))
    func aClosedFrameHasLeftTheWindowOnceItHasLanded() async throws {
        try await withWorkspace { model, host in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            #expect(model.sheetGrid?.wellInWindow(of: 7) != nil)
            // Opened and left to settle, then closed.
            let settled = try await secondsToLeave(model, host, closedAfter: .milliseconds(1500), within: 1)
            // Closed before its way in has settled, as a frame looked at and left is.
            let turnedBack = try await secondsToLeave(model, host, closedAfter: .milliseconds(400), within: 1)
            print(String(format: "frame view left the window %.2f s after a settled close, %.2f s after one turned back", settled, turnedBack))
            #expect(settled < 1)
            #expect(turnedBack < 1)
            #expect(model.framePictureShown == nil)
        }
    }

    @Test func aSheetStillThereWhenTheFrameIsClosedGoesToTheFrame() async throws {
        try await withWorkspace { model, host in
            // The frame's row at the sheet's top, where a sheet that had just come back on the frame would not have it.
            let frame = 15
            model.selection = frame
            let first = try sheetScroller(host), clip = first.contentView
            let geometry = SheetGeometry(width: clip.bounds.width, targetCell: Metrics.thumbnailWidths[model.sizeStep])
            clip.setBoundsOrigin(NSPoint(x: 0, y: geometry.frame(ofItem: frame).minY - ContactSheet.Spacing.topFade))
            first.reflectScrolledClipView(clip)
            try await Task.sleep(for: .milliseconds(300))
            let count = try #require(model.roll?.frames.count)
            let onTheFrame = geometry.offset(revealing: frame, count: count, current: clip.bounds.minY, viewport: clip.bounds.height,
                                             centered: true)
            try #require(abs(clip.bounds.minY - onTheFrame) > 50)

            // Opened and closed at once, before the sheet it was opened from has gone: that sheet comes back, where it
            // was. The frame view shrinks to where a sheet on the frame has its cell, so the sheet goes there too.
            model.openFrame()
            try await Task.sleep(for: .milliseconds(200))
            model.closeFrame()
            #expect(try await wait(for: false, in: host, atMost: 6) != nil)
            try await Task.sleep(for: .milliseconds(300))
            let back = try sheetScroller(host)
            #expect(abs(back.contentView.bounds.minY - onTheFrame) < 1)
        }
    }

    @Test func aFrameOnItsWayOutLeavesClicksToTheSheet() async throws {
        try await withWorkspace { model, host in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let sheetTookIt = try await clickedOnTheWayOut(model, host)
            #expect(sheetTookIt)
        }
    }

    /// Closes the open frame and, while the frame view is still in the window, asks what a click in the middle of the
    /// frame's own cell lands on, which the frame view is over all the way there: whether it is the sheet's. Tried again
    /// if the frame view had already gone.
    private func clickedOnTheWayOut(_ model: RollModel, _ host: NSView) async throws -> Bool {
        for _ in 0..<3 {
            model.openFrame()
            try #require(try await wait(for: true, in: host, atMost: 2) != nil)
            try await Task.sleep(for: .milliseconds(1200))
            model.closeFrame()
            try await Task.sleep(for: .milliseconds(100))
            let sheet = try #require(views(SheetCollectionView.self, in: host).first)
            sheet.layoutSubtreeIfNeeded()
            let selection = try #require(model.selection)
            let cell = try #require(sheet.item(at: IndexPath(item: selection, section: 0))?.view)
            let point = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
            let under = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
            let wasLeaving = hasFrameView(host)
            try #require(try await wait(for: false, in: host, atMost: 6) != nil)
            if wasLeaving { return sequence(first: under, next: { $0?.superview }).contains { $0 is SheetCollectionView } }
        }
        Issue.record("The frame view had left the window before a click could be tried, three times")
        return false
    }
}
