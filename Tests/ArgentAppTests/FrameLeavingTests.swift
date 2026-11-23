import AppKit
import SwiftUI
import Testing
@testable import ArgentApp

/// The frame view on its way back to the sheet, in an attached workspace: how long it stays in the window once the frame
/// is closed, and what a click, a key and a scroll of the sheet find meanwhile. SwiftUI keeps a view that leaves on a
/// transition, drawn and taking clicks, until its animation has ended, and its own spring ends long after the frame
/// view has stopped moving (`RestingSpring`).
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

    /// The frame view's spring as SwiftUI drives it in a window, sent out and sent back on its way as a frame opened and
    /// closed is: by the animation's own clock, so a busy main thread changes nothing. The one sent back takes over from
    /// the one on its way, the value goes on from where it was, every value is the arithmetic's (`SpringLeg`), and the
    /// animation ends at the first time asked for at which the arithmetic is at rest.
    @Test func theSpringInAWindowGoesAndEndsAsItsArithmeticSays() async throws {
        let hero = try #require(Graphite.Motion.hero.base as? RestingSpring)
        let spring = Spring(response: hero.response, dampingRatio: hero.dampingFraction)
        // Tried again when the main thread was busy so long that the spring had ended before it could be sent back.
        for _ in 0..<3 {
            let record = WitnessedSpring.Record(), moved = Moved()
            let (window, _) = ContextMenuTests.window(Moves(moved: moved, animation: Animation(WitnessedSpring(spring: hero, record: record))))
            defer { window.close() }
            record.turn = { Task { @MainActor in moved.x = 0 } }
            moved.x = 300
            let start = CACurrentMediaTime()
            while record.ended == nil, CACurrentMediaTime() - start < 6 { try await Task.sleep(for: .milliseconds(10)) }
            let ended = try #require(record.ended)
            guard let merge = record.merges.first else { continue }
            #expect(record.merges.count == 1)
            #expect(merge.time >= WitnessedSpring.Record.turnsAt)
            let out = SpringLeg<Double>(), back = SpringLeg(target: 300.0).redirected(at: merge.time, from: 300, spring: spring)
            let given = record.given
            try #require(merge.asked > 0 && merge.asked < given.count)
            // No step where the one took over from the other.
            #expect(abs(given[merge.asked].value - back.state(at: merge.time, to: 0, spring: spring).position) < 300 * 6 * (given[merge.asked].time - merge.time) + 1e-6)
            for (index, asked) in given.enumerated() {
                let leg = index < merge.asked ? out : back, target = index < merge.asked ? 300.0 : 0
                let now = leg.state(at: asked.time, to: target, spring: spring)
                #expect(abs(asked.value - now.position) < 1e-6)
                #expect(!now.isAtRest)
            }
            #expect(back.state(at: ended, to: 0, spring: spring).isAtRest)
            return
        }
        Issue.record("The spring had ended before it could be sent back, three times")
    }

    /// How long a closed frame's view stays in the window, by the clock, so only when asked for (`ARGENT_MEASURE=1`) and
    /// run by itself: beside the other suites the main thread is theirs for much of a second at a time. About 0.8 s
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
        }
    }

    /// Opens the frame and closes it before the sheet it was opened from has gone, so that sheet comes back as it is,
    /// where `placed` left it: the sheet, once the frame view has left the window. Tried again when a busy main thread
    /// let the sheet go first and another came back; `nil` if that happened three times.
    private func sheetClosedOnto(_ model: RollModel, _ host: NSView,
                                 placed: @MainActor (NSScrollView) async throws -> Void = { _ in }) async throws -> NSScrollView? {
        for _ in 0..<3 {
            let first = try sheetScroller(host)
            try await placed(first)
            model.openFrame()
            try #require(try await wait(for: true, in: host, atMost: 2) != nil)
            try await Task.sleep(for: .milliseconds(200))
            model.closeFrame()
            try #require(try await wait(for: false, in: host, atMost: 6) != nil)
            try await Task.sleep(for: .milliseconds(300))
            if try sheetScroller(host) === first { return first }
        }
        return nil
    }

    @Test func aSheetStillThereWhenTheFrameIsClosedGoesToTheFrame() async throws {
        try await withWorkspace { model, host in
            // With no motion the sheet has gone at once, and none is there to come back.
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let frame = 15
            model.selection = frame
            let count = try #require(model.roll?.frames.count)
            var onTheFrame = CGFloat.zero
            // Opened and closed at once, before the sheet it was opened from has gone: that sheet comes back, where it
            // was. The frame view shrinks to where a sheet on the frame has its cell, so the sheet goes there too.
            let reused = try await sheetClosedOnto(model, host) { sheet in
                // The frame's row at the sheet's top, where a sheet that had just come back on the frame would not have it.
                let clip = sheet.contentView
                let geometry = SheetGeometry(width: clip.bounds.width, targetCell: Metrics.thumbnailWidths[model.sizeStep])
                clip.setBoundsOrigin(NSPoint(x: 0, y: geometry.frame(ofItem: frame).minY - ContactSheet.Spacing.topFade))
                sheet.reflectScrolledClipView(clip)
                try await Task.sleep(for: .milliseconds(300))
                onTheFrame = geometry.offset(revealing: frame, count: count, current: clip.bounds.minY, viewport: clip.bounds.height,
                                             centered: true)
                try #require(abs(clip.bounds.minY - onTheFrame) > 50)
            }
            let sheet = try #require(reused, "The sheet the frame was opened from had gone before the frame was closed, three times")
            #expect(abs(sheet.contentView.bounds.minY - onTheFrame) < 1)
        }
    }

    /// The sheet that comes back does not appear again, which is when a sheet takes the keys: Down Arrow still moves the
    /// selection, where it went nowhere once the frame view that had the keys was gone.
    @Test func aSheetStillThereWhenTheFrameIsClosedTakesTheKeys() async throws {
        try await withWorkspace { model, host in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let reused = try await sheetClosedOnto(model, host)
            _ = try #require(reused, "The sheet the frame was opened from had gone before the frame was closed, three times")
            let window = try #require(host.window), before = model.selection
            try press(NSDownArrowFunctionKey, code: 125, in: window)
            #expect(model.selection != before)
        }
    }

    @Test func aFrameOnItsWayOutLeavesClicksToTheSheet() async throws {
        try await withWorkspace { model, host in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let sheetTookIt = try await clickedOnTheWayOut(model, host)
            #expect(sheetTookIt)
        }
    }

    /// The other way about: a frame opened again before its view has gone gets that view back, which does not appear
    /// again either. Space still shows the neutral raw, where it went to a sheet that had gone.
    @Test func aFrameViewStillThereWhenTheFrameIsOpenedAgainTakesTheKeys() async throws {
        try await withWorkspace { model, host in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let window = try #require(host.window)
            var reused = false
            for _ in 0..<3 where !reused {
                model.openFrame()
                try #require(try await wait(for: true, in: host, atMost: 2) != nil)
                try await Task.sleep(for: .milliseconds(1200))
                let first = try #require(views(MaskCanvasView.self, in: host).first)
                model.closeFrame()
                try await Task.sleep(for: .milliseconds(200))
                model.openFrame()
                try await Task.sleep(for: .milliseconds(1200))
                reused = views(MaskCanvasView.self, in: host).first === first
                if reused {
                    #expect(!model.isComparing)
                    try press(0x20, code: 49, modifiers: [], in: window)
                    #expect(model.isComparing)
                    try press(0x20, code: 49, modifiers: [], up: true, in: window)
                    #expect(!model.isComparing)
                }
                model.closeFrame()
                try #require(try await wait(for: false, in: host, atMost: 6) != nil)
            }
            #expect(reused, "The frame view had left the window before the frame was opened again, three times")
        }
    }

    /// How much of the frame view is drawn, by the mask canvas it holds: 0 for one SwiftUI has made clear, or with no
    /// frame view in the window.
    private func frameViewOpacity(_ host: NSView) -> CGFloat {
        guard let canvas = views(MaskCanvasView.self, in: host).first else { return 0 }
        return sequence(first: canvas as NSView, next: { $0.superview }).reduce(1) { $0 * $1.alphaValue }
    }

    /// A key going down for the window, or coming `up`, as the keyboard sends it: an arrow, Home or End unless told.
    private func press(_ character: Int, code: UInt16, modifiers: NSEvent.ModifierFlags = [.numericPad, .function], up: Bool = false,
                       in window: NSWindow) throws {
        let characters = String(Character(UnicodeScalar(UInt16(character))!))
        let key = try #require(NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(key)
    }

    /// Closes the open frame, scrolls the sheet a tenth of a second later as `scroll` does, and says how much of the
    /// frame view, still in the window, is drawn once the sheet has moved: nothing, or what it was when it left. Tried
    /// again if the frame view had gone by then; `nil` after three.
    ///
    /// Waited for, not timed: the sheet scrolled by the keys moves on an animation whose first step comes after the model
    /// has heard of the scroll, 12 ms on an idle Mac and more than the 50 ms this once waited on a busy one, and SwiftUI
    /// draws the frame view clear in a later turn than a wheel's scroll moves the sheet in.
    private func opacityOnceScrolled(_ model: RollModel, _ host: NSView, scroll: @MainActor (NSScrollView) throws -> Void) async throws -> CGFloat? {
        for _ in 0..<3 {
            model.openFrame()
            try #require(try await wait(for: true, in: host, atMost: 2) != nil)
            try await Task.sleep(for: .milliseconds(1200))
            model.closeFrame()
            try await Task.sleep(for: .milliseconds(100))
            let before = frameViewOpacity(host)
            let sheet = try sheetScroller(host), from = sheet.contentView.bounds.minY
            try scroll(sheet)
            var moved = false, after: CGFloat?
            let start = CACurrentMediaTime()
            while CACurrentMediaTime() - start < 6 {
                moved = moved || sheet.contentView.bounds.minY != from
                let there = hasFrameView(host)
                if moved, there { after = frameViewOpacity(host) }
                if moved, !there || after == 0 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(moved, "The sheet did not move in six seconds")
            try #require(try await wait(for: false, in: host, atMost: 6) != nil)
            // Only a frame view drawn whole before the scroll and still there once the sheet had moved has been asked anything.
            if before == 1, let after { return after }
        }
        return nil
    }

    /// The frame view goes to where its cell was as the frame was closed, and is there until it has left the window. A
    /// sheet scrolled meanwhile has moved the cell from under it: it is not drawn from then on, which is the picture
    /// that stayed between the rows. Opened again, the frame is drawn.
    @Test func aFrameOnItsWayOutIsNotDrawnOverASheetScrolledFromUnderIt() async throws {
        try await withWorkspace { model, host in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            // By hand: a wheel's notch, as a mouse sends it.
            let byHand = try await opacityOnceScrolled(model, host) { sheet in
                let notch = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -5, wheel2: 0, wheel3: 0))
                sheet.scrollWheel(with: try #require(NSEvent(cgEvent: notch)))
            }
            #expect(byHand == 0, "The frame view had left the window before the sheet could be scrolled, if nil")
            model.openFrame()
            try #require(try await wait(for: true, in: host, atMost: 2) != nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(frameViewOpacity(host) == 1)
            model.closeFrame()
            try #require(try await wait(for: false, in: host, atMost: 6) != nil)

            // By the keys: End, to the roll's last frame, out of the sheet's view.
            let window = try #require(host.window)
            let byKeys = try await opacityOnceScrolled(model, host) { _ in
                try press(NSEndFunctionKey, code: 119, in: window)
            }
            #expect(byKeys == 0, "The frame view had left the window before the sheet could be scrolled, if nil")
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

/// A `RestingSpring` as SwiftUI drives it: what it is asked for and gives, by the animation's own clock, and when one
/// takes over from another.
private struct WitnessedSpring: CustomAnimation {
    final class Record: @unchecked Sendable {
        /// How far into its way the spring is sent back.
        static let turnsAt: TimeInterval = 0.2
        var given: [(time: TimeInterval, value: Double)] = []
        /// When one spring took over from another, and how many values had been given by then.
        var merges: [(time: TimeInterval, asked: Int)] = []
        /// When the animation ended.
        var ended: TimeInterval?
        /// Sends the spring back, once.
        var turn: (@Sendable () -> Void)?
    }

    var spring: RestingSpring
    let record: Record

    static func == (one: WitnessedSpring, other: WitnessedSpring) -> Bool { one.spring == other.spring && one.record === other.record }
    func hash(into hasher: inout Hasher) { hasher.combine(spring) }

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        let now = spring.animate(value: value, time: time, context: &context)
        if let now = now as? Double { record.given.append((time, now)) } else if now == nil { record.ended = time }
        if time >= Record.turnsAt, let turn = record.turn {
            record.turn = nil
            turn()
        }
        return now
    }

    func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        spring.velocity(value: value, time: time, context: context)
    }

    func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval, context: inout AnimationContext<V>) -> Bool {
        guard let previous = previous.base as? WitnessedSpring else { return false }
        record.merges.append((time, record.given.count))
        return spring.shouldMerge(previous: Animation(previous.spring), value: value, time: time, context: &context)
    }
}

/// A number a view is moved by, and the view.
@MainActor @Observable private final class Moved {
    var x = 0.0
}

private struct Moves: View {
    let moved: Moved
    let animation: Animation

    var body: some View {
        Color.clear.frame(width: 10, height: 10).modifier(Slid(x: moved.x)).animation(animation, value: moved.x)
    }
}

private struct Slid: ViewModifier, @preconcurrency Animatable {
    var x: Double
    var animatableData: Double {
        get { x }
        set { x = newValue }
    }

    func body(content: Content) -> some View { content.offset(x: x / 100) }
}
