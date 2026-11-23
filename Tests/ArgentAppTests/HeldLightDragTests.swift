import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI
import Testing
@testable import ArgentApp

/// A Light-tab drag held while the model replaces its gesture (a reset, a paste, an undo or a redo), driven as a hand drives it: the
/// inspector in a window, the slider's or the value's own tracking loop taking the pointer's moves from that window, and an undo
/// manager that groups by event as the window's does, so a group opened while the slider tracks closes only after the release.
@MainActor @Suite(.serialized) struct HeldLightDragTests {
    /// The inspector on a frame of a settled roll, in a window of its own.
    @MainActor struct Inspector {
        let model: RollModel
        let frame: Frame
        let window: EventWindow

        /// The Light tab's slider for `slider`.
        func slider(_ slider: ManualAdjustments.Slider) throws -> AdjustmentSliderControl {
            window.contentView?.layoutSubtreeIfNeeded()
            let root = try #require(window.contentView)
            return try #require(AdjustmentSliderControl.sliders(in: .light, under: root).first { $0.spec == .light(slider) })
        }

        /// The value at the end of `slider`'s row, which a drag over it scrubs.
        func value(_ slider: ManualAdjustments.Slider) throws -> ValueScrubView {
            func found(_ view: NSView) -> [ValueScrubView] {
                if let scrub = view as? ValueScrubView { return scrub.spec == .light(slider) ? [scrub] : [] }
                return view.subviews.flatMap(found)
            }
            window.contentView?.layoutSubtreeIfNeeded()
            let root = try #require(window.contentView)
            return try #require(found(root).first)
        }

        func values() -> ManualAdjustments { model.manualAdjustments(for: frame) }
        /// What the frame view prints, a drag's steps included.
        func printed() -> ManualAdjustments? { model.printedEdit(for: frame)?.adjustments }
    }

    /// A roll whose Auto has settled, `values` on its frame `index` as their own undo step, and the inspector on that frame, or on the
    /// selected frame as the window shows it, made again for each (`ContentView`).
    private func withInspector(_ values: ManualAdjustments, on index: Int = 0, followingSelection: Bool = false,
                               _ body: (Inspector, [Frame]) async throws -> Void) async throws {
        try await AutoDecisionStateTests.withRoll { fixture in
            let model = fixture.model(), gate = MeasurementGate()
            try await AutoDecisionStateTests.open(fixture, in: model, through: gate)
            defer { AutoDecisionStateTests.close(model, gate) }
            let frames = try #require(model.roll?.frames), frame = frames[index]
            gate.openAll(frames)
            _ = try #require(await model.settledDecision())
            for frame in frames.prefix(2) {
                await model.prepareManualAdjustments(for: frame)
                let stock = model.stockIndex
                model.recordVisibleAutomatic(for: frame, stock: stock, aim: model.printAim(for: frame),
                                             settings: model.settings(for: frame, stock: stock))
            }
            model.selection = frame.id
            // The window's own kind: grouped by event.
            model.manualUndoManager = UndoManager()
            model.setManualAdjustments(values, for: frame)
            await endTurn()
            let tab = model.adjustTab
            defer { model.adjustTab = tab }
            model.adjustTab = .light
            model.isInspectorPresenceExpanded = true
            let window = EventWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1100), styleMask: [.titled],
                                     backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = followingSelection ? NSHostingView(rootView: AnyView(SelectedInspector().environment(model)))
                : NSHostingView(rootView: AnyView(ManualAdjustmentsView(frame: frame).environment(model)))
            let inspector = Inspector(model: model, frame: frame, window: window)
            try await settled(window)
            try await body(inspector, frames)
            try await model.flushManualSaves()
        }
    }

    /// Waits for the inspector's eleven sliders to be drawn, enabled, and to stay where they are.
    private func settled(_ window: NSWindow) async throws {
        var last: [NSRect] = [], still = 0
        for _ in 0..<500 where still < 3 {
            try await Task.sleep(for: .milliseconds(10))
            window.contentView?.layoutSubtreeIfNeeded()
            let sliders = window.contentView.map { AdjustmentSliderControl.sliders(in: .light, under: $0) } ?? []
            let frames = sliders.map { $0.convert($0.bounds, to: nil) }
            let ready = sliders.count == ManualAdjustments.Control.allCases.count + Presence.Control.allCases.count && sliders.allSatisfy(\.isEnabled)
            still = ready && frames == last ? still + 1 : 0
            last = frames
        }
        try #require(still >= 3, "the Light tab's eleven sliders, drawn and enabled")
    }

    /// The end of the turn, where the undo manager closes the group the turn opened.
    private func endTurn() async {
        try? await Task.sleep(for: .milliseconds(5))
    }

    // MARK: The hand

    /// The pointer, during a press: each move is made an event where the control is drawn when its loop takes it.
    @MainActor struct Hand {
        let window: EventWindow

        /// Moves the pointer to `point` and waits for the control's loop to take the move.
        func move(_ point: @escaping @MainActor (EventWindow) -> NSPoint) async throws {
            window.queue(.leftMouseDragged, at: point)
            // Twenty seconds at most: two were not enough when another suite held the main actor.
            for _ in 0..<20000 where !window.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
            try #require(window.isWaiting, "the move was taken")
        }

        /// Moves to where `value` stands on `slider`'s track.
        func move(to value: Float, on slider: AdjustmentSliderControl) async throws {
            try await move { _ in HeldLightDragTests.point(value, on: slider) }
        }

        /// Moves right by `units` of `slider`'s value, from wherever the pointer is.
        func move(by units: Float, on slider: AdjustmentSliderControl) async throws {
            try await move { window in
                let track = HeldLightDragTests.track(of: slider), span = slider.spec.range.upperBound - slider.spec.range.lowerBound
                return NSPoint(x: window.location.x + CGFloat(units / span) * track.width, y: window.location.y)
            }
        }

        /// Moves right by `points`, as a scrub of a value counts them, one step a point.
        func move(byPoints points: CGFloat) async throws {
            try await move { window in NSPoint(x: window.location.x + points, y: window.location.y) }
        }
    }

    static func track(of slider: AdjustmentSliderControl) -> NSRect {
        (slider.cell as? NSSliderCell)?.barRect(flipped: slider.isFlipped) ?? .zero
    }

    /// Where `value` stands on `slider`'s track, in its window.
    static func point(_ value: Float, on slider: AdjustmentSliderControl) -> NSPoint {
        let track = track(of: slider)
        return slider.convert(NSPoint(x: track.minX + slider.spec.fraction(of: value) * track.width, y: slider.bounds.midY), to: nil)
    }

    /// Presses `control` at `press`, runs `held` while the button stays down, then lets go where the pointer is, with no move of its
    /// own. The press is sent from the run loop, as an event is, so the main actor's work runs inside the control's loop as it does
    /// in the app: `held`, the slider's own timed write, and the inspector's updates.
    ///
    /// From the run loop's own turn, and not from one that a suite running beside this one has begun inside its main-actor work, as
    /// `ContextMenuTests.settle` does: the main actor is that work's until its turn ends, so nothing of the main actor's ran inside
    /// the control's loop, `held` did not move the pointer, and the press was let go when the loop gave up thirty seconds later.
    private func hold(_ control: NSView, at press: @escaping @MainActor (EventWindow) -> NSPoint,
                      _ held: @escaping @MainActor (Hand) async throws -> Void) async throws {
        let window = try #require(control.window as? EventWindow)
        let handed = Unchecked((control, window, press, held)), nesting = RunLoopNesting()
        defer { nesting.invalidate() }
        await withCheckedContinuation { (released: CheckedContinuation<Void, Never>) in
            @Sendable func arm(after interval: TimeInterval) {
                RunLoop.main.add(Timer(timeInterval: interval, repeats: false) { _ in
                    guard nesting.depth <= 0 else { return arm(after: 0.005) }
                    MainActor.assumeIsolated {
                        let (control, window, press, held) = handed.value
                        Task { @MainActor in
                            do { try await held(Hand(window: window)) } catch { Issue.record(error) }
                            window.queue(.leftMouseUp) { $0.location }
                        }
                        control.mouseDown(with: window.event(.leftMouseDown, at: press(window)))
                    }
                    released.resume()
                }, forMode: .default)
            }
            arm(after: 0)
        }
        try #require(!window.timedOut, "the release came")
        await endTurn()
    }

    /// Presses `slider`'s knob.
    private func hold(_ slider: AdjustmentSliderControl, _ held: @escaping @MainActor (Hand) async throws -> Void) async throws {
        try await hold(slider, at: { _ in Self.point(Float(slider.doubleValue), on: slider) }, held)
    }

    /// Presses the middle of a row's value.
    private func hold(_ value: ValueScrubView, _ held: @escaping @MainActor (Hand) async throws -> Void) async throws {
        try await hold(value, at: { _ in value.convert(NSPoint(x: value.bounds.midX, y: value.bounds.midY), to: nil) }, held)
    }

    /// Waits for `slider`'s knob and what VoiceOver reads of its row to show `value`, then expects them to.
    private func expectShown(_ value: Float, on slider: AdjustmentSliderControl, _ comment: String,
                             sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let spoken = slider.spec.spoken(value)
        for _ in 0..<300 where slider.doubleValue != Double(value) || slider.accessibilityValueDescription() != spoken {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(slider.doubleValue == Double(value), "knob: \(comment)", sourceLocation: sourceLocation)
        #expect(slider.accessibilityValueDescription() == spoken, "value: \(comment)", sourceLocation: sourceLocation)
    }

    /// Waits for the frame view's print to hold `values`.
    private func expectPrinted(_ values: ManualAdjustments, _ inspector: Inspector, _ comment: String,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<300 where inspector.printed() != values { try await Task.sleep(for: .milliseconds(5)) }
        #expect(inspector.printed() == values, "\(comment)", sourceLocation: sourceLocation)
    }

    /// A drag's first write goes at once; with this, every later one waits for the release, so it is still queued when a test looks.
    private static let queued: CFTimeInterval = 60

    // MARK: An ordinary drag

    /// With nothing to replace its gesture, a drag is as it was: its first step is printed at once and the rest wait their turn, the
    /// edit is untouched until the release, which writes the newest value as one undo step.
    @Test func anOrdinaryDragPrintsItsStepsAndWritesTheLastAtReleaseAsOneStep() async throws {
        let start = try ManualAdjustments(exposureEV: 0.5, presence: Presence([.clarity: 10]))
        try await withInspector(start) { inspector, _ in
            let clarity = try inspector.slider(.presence(.clarity)), manager = try #require(inspector.model.manualUndoManager)
            clarity.dragWriteInterval = Self.queued
            try await hold(clarity) { hand in
                try await hand.move(to: 20, on: clarity)
                try await hand.move(to: 30, on: clarity)
                try await hand.move(to: 40, on: clarity)
                #expect(inspector.printed() == (try start.setting(.presence(.clarity), to: 20)), "the first step at once, the rest queued")
                #expect(inspector.values() == start, "the edit untouched")
                #expect(clarity.doubleValue == 40, "the knob follows every move")
            }
            let written = try start.setting(.presence(.clarity), to: 40)
            #expect(inspector.values() == written && inspector.printed() == written)
            try await expectShown(40, on: clarity, "after the release")
            manager.undo()
            #expect(inspector.values() == start, "one undo step")
            manager.undo()
            #expect(inspector.model.manualEdits[inspector.frame.url] == nil && !manager.canUndo)
        }
    }

    /// The menu bar's state reads the edit and not the print, the Frame menu's Distortion item included, so a drag's steps do not
    /// make it read again.
    @Test func aDragsStepsDoNotMakeTheMenuStateReadAgain() async throws {
        let start = try ManualAdjustments(exposureEV: 0.5, presence: Presence([.clarity: 10]))
        try await withInspector(start) { inspector, _ in
            let clarity = try inspector.slider(.presence(.clarity))
            clarity.dragWriteInterval = Self.queued
            inspector.model.openFrame()
            try #require(inspector.model.shownFrame != nil, "the Frame menu reads the open frame")
            final class Changed: @unchecked Sendable { var count = 0 }
            let changed = Changed()
            try await hold(clarity) { hand in
                withObservationTracking { _ = inspector.model.menuState } onChange: { changed.count += 1 }
                try await hand.move(to: 20, on: clarity)
                try await hand.move(to: 30, on: clarity)
                #expect(changed.count == 0, "the menus take a gesture once, as it ends")
            }
        }
    }

    // MARK: A reset with a write queued

    enum Reset: String, CaseIterable, Sendable { case presence, light, currentAuto, original }

    /// Each reset, invoked while a drag holds a write it has not made yet, holds through the release: the queued value is the old
    /// gesture's and is not written. The row and the knob show what the reset left while the button is still down.
    @Test(arguments: Reset.allCases)
    func aResetWithAWriteQueuedHoldsThroughTheRelease(_ reset: Reset) async throws {
        let start = try ManualAdjustments(exposureEV: 0.5, contrast: 20, presence: Presence([.clarity: 10, .vibrance: 20]))
        try await withInspector(start) { inspector, _ in
            let model = inspector.model, frame = inspector.frame
            // A slider of the group the reset clears.
            let dragged: ManualAdjustments.Slider = reset == .light ? .light(.contrast) : .presence(.clarity)
            let slider = try inspector.slider(dragged)
            slider.dragWriteInterval = Self.queued
            let cleared: ManualAdjustments = switch reset {
            case .presence: start.clearing(.presence)
            case .light: start.clearing(.light)
            case .currentAuto, .original: .identity
            }
            try await hold(slider) { hand in
                try await hand.move(to: 40, on: slider)
                try await hand.move(to: 60, on: slider)
                #expect(inspector.printed()?.value(for: dragged) == 40, "60 is queued, not written")
                switch reset {
                case .presence: model.resetPresence(for: frame)
                case .light: model.resetLight(for: frame)
                case .currentAuto: model.resetManualAdjustments(for: frame)
                case .original: model.startFromOriginal(for: frame, actionName: "Reset to Original")
                }
                #expect(inspector.values() == cleared)
                try await expectShown(0, on: slider, "the reset's value, while the button is down")
            }
            #expect(inspector.values() == cleared, "the reset holds")
            #expect(model.printedLight == nil && model.manualGestures[frame.url] == nil)
            if reset == .original { #expect(model.startingPoint(for: frame) == .original) }
            try await expectShown(0, on: slider, "after the release")
        }
    }

    // MARK: A paste with a write queued

    /// A paste that lands while a drag holds a write it has not made yet holds through the release.
    @Test func aPasteWithAWriteQueuedHoldsThroughTheRelease() async throws {
        let start = try ManualAdjustments(shadows: 10, presence: Presence([.clarity: 5]))
        try await withInspector(start, on: 1) { inspector, frames in
            let model = inspector.model, source = frames[0]
            let pasted = try ManualAdjustments(exposureEV: 0.7, presence: Presence([.texture: -30, .clarity: 60]))
            model.setManualAdjustments(pasted, for: source)
            await endTurn()
            model.copyAdjustments(from: source)
            let clarity = try inspector.slider(.presence(.clarity))
            clarity.dragWriteInterval = Self.queued
            try await hold(clarity) { hand in
                try await hand.move(to: 20, on: clarity)
                try await hand.move(to: 40, on: clarity)
                #expect(inspector.printed()?.presence.clarity == 20, "40 is queued, not written")
                model.pasteAdjustments(to: inspector.frame)
                _ = await model.pasteTask?.value
                #expect(inspector.values() == pasted)
                try await expectShown(60, on: clarity, "the pasted value, while the button is down")
            }
            #expect(inspector.values() == pasted, "the paste holds")
            try await expectShown(60, on: clarity, "after the release")
        }
    }

    /// The slider's timed write can come in the reset's own turn, before the inspector is drawn again with the new gesture (the run
    /// loop takes the main queue's work before its observers draw): that write is the old gesture's too, and the reset holds.
    @Test func aTimedWriteInTheResetsOwnTurnIsTheOldGesturesToo() async throws {
        let start = try ManualAdjustments(exposureEV: 0.5, presence: Presence([.clarity: 10, .vibrance: 20]))
        try await withInspector(start) { inspector, _ in
            let model = inspector.model, clarity = try inspector.slider(.presence(.clarity))
            let slider = try #require(clarity.target as? AdjustmentSlider.Coordinator)
            clarity.dragWriteInterval = Self.queued
            try await hold(clarity) { hand in
                try await hand.move(to: 40, on: clarity)
                try await hand.move(to: 60, on: clarity)
                model.resetPresence(for: inspector.frame)
                // As the write's timer does when it fires in this turn.
                slider.writePending()
                try await expectShown(0, on: clarity, "the reset's value")
                #expect(inspector.printed() == start.clearing(.presence), "nothing printed over the reset")
            }
            #expect(inspector.values() == start.clearing(.presence), "the reset holds")
        }
    }

    // MARK: An undo or a redo while a drag is held

    /// An undo while a drag is held takes the drag's steps back with it, and the release does not write them, nor the undone values
    /// the print held under them. Undone to a state that still has an edit, so the release could have written one.
    @Test func anUndoWhileADragIsHeldIsNotReversedAtTheRelease() async throws {
        let first = try ManualAdjustments(exposureEV: 1)
        try await withInspector(first) { inspector, _ in
            let model = inspector.model, manager = try #require(model.manualUndoManager)
            model.setManualAdjustments(try first.setting(.light(.contrast), to: 20), for: inspector.frame)
            await endTurn()
            let clarity = try inspector.slider(.presence(.clarity))
            clarity.dragWriteInterval = Self.queued
            try await hold(clarity) { hand in
                try await hand.move(to: 20, on: clarity)
                try await hand.move(to: 30, on: clarity)
                manager.undo()
                #expect(inspector.values() == first)
                try await expectShown(0, on: clarity, "the undone value, while the button is down")
                #expect(inspector.printed() == first, "the print holds the undone edit")
            }
            #expect(inspector.values() == first, "the undo holds")
            #expect(manager.canRedo, "the release made no step, so the Redo is still there")
            manager.undo()
            #expect(model.manualEdits[inspector.frame.url] == nil && !manager.canUndo, "the first step, then nothing")
        }
    }

    /// A redo while a drag is held is not reversed at the release either.
    @Test func aRedoWhileADragIsHeldIsNotReversedAtTheRelease() async throws {
        let first = try ManualAdjustments(exposureEV: 1), second = try first.setting(.light(.contrast), to: 20)
        try await withInspector(first) { inspector, _ in
            let model = inspector.model, manager = try #require(model.manualUndoManager)
            model.setManualAdjustments(second, for: inspector.frame)
            await endTurn()
            manager.undo()
            await endTurn()
            let clarity = try inspector.slider(.presence(.clarity))
            clarity.dragWriteInterval = Self.queued
            try await hold(clarity) { hand in
                try await hand.move(to: 20, on: clarity)
                try await hand.move(to: 30, on: clarity)
                manager.redo()
                #expect(inspector.values() == second)
                try await expectShown(0, on: clarity, "the redone value, while the button is down")
            }
            #expect(inspector.values() == second, "the redo holds")
            manager.undo()
            #expect(inspector.values() == first)
            manager.undo()
            #expect(model.manualEdits[inspector.frame.url] == nil && !manager.canUndo)
        }
    }

    // MARK: A drag that goes on after the replacement

    /// After a reset the drag goes on from the value the reset left, the knob taken up where the pointer is: a move is shown and
    /// printed from there, and the release writes it. The hold is one undo step, the reset in it.
    @Test func aDragGoesOnFromWhatAResetLeft() async throws {
        let start = try ManualAdjustments(exposureEV: 0.5, presence: Presence([.clarity: 10, .vibrance: 20]))
        try await withInspector(start) { inspector, _ in
            let model = inspector.model, manager = try #require(model.manualUndoManager)
            let clarity = try inspector.slider(.presence(.clarity))
            clarity.dragWriteInterval = Self.queued
            let cleared = start.clearing(.presence), moved = try cleared.setting(.presence(.clarity), to: 10)
            try await hold(clarity) { hand in
                try await hand.move(to: 40, on: clarity)
                try await hand.move(to: 60, on: clarity)
                model.resetPresence(for: inspector.frame)
                try await expectShown(0, on: clarity, "the reset's value")
                clarity.dragWriteInterval = AdjustmentSlider.dragWriteInterval
                try await hand.move(by: 10, on: clarity)
                try await expectShown(10, on: clarity, "ten on from the reset's value")
                try await expectPrinted(moved, inspector, "printed over the reset")
                #expect(inspector.values() == cleared, "the edit takes it at the release")
            }
            #expect(inspector.values() == moved, "written at the release")
            manager.undo()
            #expect(inspector.values() == start, "the hold, one step")
        }
    }

    /// After an undo the drag goes on from the undone edit, and its release is a new step.
    @Test func aDragGoesOnFromWhatAnUndoLeft() async throws {
        let first = try ManualAdjustments(exposureEV: 1)
        try await withInspector(first) { inspector, _ in
            let model = inspector.model, manager = try #require(model.manualUndoManager)
            model.setManualAdjustments(try first.setting(.light(.contrast), to: 20), for: inspector.frame)
            await endTurn()
            let clarity = try inspector.slider(.presence(.clarity))
            clarity.dragWriteInterval = Self.queued
            let moved = try first.setting(.presence(.clarity), to: 10)
            try await hold(clarity) { hand in
                try await hand.move(to: 20, on: clarity)
                try await hand.move(to: 30, on: clarity)
                manager.undo()
                try await expectShown(0, on: clarity, "the undone value")
                clarity.dragWriteInterval = AdjustmentSlider.dragWriteInterval
                try await hand.move(by: 10, on: clarity)
                try await expectShown(10, on: clarity, "ten on from the undone value")
                try await expectPrinted(moved, inspector, "printed over the undone edit")
            }
            #expect(inspector.values() == moved, "written at the release")
            #expect(!manager.canRedo, "a new step, after which there is nothing to redo")
            manager.undo()
            #expect(inspector.values() == first)
            manager.undo()
            #expect(model.manualEdits[inspector.frame.url] == nil && !manager.canUndo)
        }
    }

    /// A scrub of a row's value goes on from what a reset left too: one step a point from there, not from where the scrub began.
    @Test func aScrubGoesOnFromWhatAResetLeft() async throws {
        let start = try ManualAdjustments(exposureEV: 0.5, presence: Presence([.clarity: 10, .vibrance: 20]))
        try await withInspector(start) { inspector, _ in
            let model = inspector.model, value = try inspector.value(.presence(.clarity))
            let clarity = try inspector.slider(.presence(.clarity)), cleared = start.clearing(.presence)
            try await hold(value) { hand in
                try await hand.move(byPoints: 4)
                try await hand.move(byPoints: 6)
                try await expectPrinted(try start.setting(.presence(.clarity), to: 20), inspector, "ten points, ten steps")
                model.resetPresence(for: inspector.frame)
                try await expectShown(0, on: clarity, "the reset's value")
                try await hand.move(byPoints: 5)
                try await expectPrinted(try cleared.setting(.presence(.clarity), to: 5), inspector, "five on from the reset's value")
            }
            #expect(inspector.values() == (try cleared.setting(.presence(.clarity), to: 5)))
        }
    }

    // MARK: A change of frame while a drag is held

    /// The inspector moving to another frame while a drag is held takes the row, its slider and any write it has queued away with it:
    /// the old frame keeps the drag as far as the print had it, as one step, nothing reaches the new frame, and no gesture stays open.
    @Test func aFrameChangeWhileADragIsHeldKeepsTheDragSoFarAndNothingElse() async throws {
        let start = try ManualAdjustments(exposureEV: 0.5, presence: Presence([.clarity: 10]))
        try await withInspector(start, followingSelection: true) { inspector, frames in
            let model = inspector.model, manager = try #require(model.manualUndoManager), other = frames[1]
            let clarity = try inspector.slider(.presence(.clarity))
            var printed: ManualAdjustments?
            try await hold(clarity) { hand in
                try await hand.move(to: 40, on: clarity)
                try await hand.move(to: 60, on: clarity)
                printed = inspector.printed()
                model.selection = other.id
                // Longer than the slider's write interval, so a write it had queued would have landed by now.
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(printed != nil && inspector.values() == printed, "the drag as far as the print had it")
            #expect(model.manualEdits[other.url] == nil && model.manualGestures.isEmpty && model.printedLight == nil)
            manager.undo()
            #expect(inspector.values() == start, "one step")
        }
    }

    // MARK: Undo steps for a hold

    enum Replacement: String, CaseIterable, Sendable { case reset, paste }

    /// A reset or a paste that lands while a drag is held is undone with the drag, in one step: the window's undo manager closes its
    /// group only once the slider's tracking loop has let go, so the drag so far, the write and the rest of the drag share it. The
    /// paste's place in this is the resets' rule (docs/presence-plan.md, section 3).
    @Test(arguments: Replacement.allCases)
    func aResetOrAPasteDuringAHeldDragIsUndoneWithTheDrag(_ replacement: Replacement) async throws {
        let start = try ManualAdjustments(shadows: 10, presence: Presence([.clarity: 5]))
        try await withInspector(start, on: 1) { inspector, frames in
            let model = inspector.model, source = frames[0], manager = try #require(model.manualUndoManager)
            let pasted = try ManualAdjustments(exposureEV: 0.7, presence: Presence([.texture: -30, .clarity: 60]))
            model.setManualAdjustments(pasted, for: source)
            await endTurn()
            model.copyAdjustments(from: source)
            let clarity = try inspector.slider(.presence(.clarity))
            try await hold(clarity) { hand in
                try await hand.move(to: 20, on: clarity)
                try await expectPrinted(try start.setting(.presence(.clarity), to: 20), inspector, "the drag so far")
                switch replacement {
                case .reset: model.resetPresence(for: inspector.frame)
                case .paste:
                    model.pasteAdjustments(to: inspector.frame)
                    _ = await model.pasteTask?.value
                }
            }
            #expect(inspector.values() == (replacement == .reset ? start.clearing(.presence) : pasted))
            manager.undo()
            #expect(inspector.values() == start, "the drag and the \(replacement.rawValue), one step")
        }
    }
}

/// A window whose pointer events come from the test, as a hand's come from the window server: a tracking loop's `nextEvent` takes
/// them in order, each made where things are drawn as it is taken, and while none waits the run loop runs in the loop's mode, as it
/// does while the window server waits.
final class EventWindow: NSWindow {
    private var queued: [(type: NSEvent.EventType, point: @MainActor (EventWindow) -> NSPoint)] = []
    /// Where the pointer is: the last event taken.
    private(set) var location = NSPoint.zero
    private(set) var timedOut = false
    /// Nothing is queued: the last move was taken.
    var isWaiting: Bool { queued.isEmpty }

    func queue(_ type: NSEvent.EventType, at point: @escaping @MainActor (EventWindow) -> NSPoint) { queued.append((type, point)) }

    func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        location = point
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                  pressure: type == .leftMouseUp ? 0 : 1)!
    }

    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode,
                            dequeue: Bool) -> NSEvent? {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let next = queued.first, mask.contains(NSEvent.EventTypeMask(type: next.type)) {
                queued.removeFirst()
                return event(next.type, at: next.point(self))
            }
            if CFRunLoopRunInMode(CFRunLoopMode(mode.rawValue as CFString), 0.002, true) == .finished { usleep(1000) }
        }
        timedOut = true
        return event(.leftMouseUp, at: location)
    }
}

/// How many turns of the main run loop have begun since this was made and not ended: none in the turn it was made in. One begun
/// inside main-actor work, by a test that turns the run loop itself, holds the main actor until it ends.
private final class RunLoopNesting: @unchecked Sendable {
    private(set) var depth = 0
    private var observer: CFRunLoopObserver?

    init() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.entry, .exit]).rawValue, true, 0) { [unowned self] _, activity in
            depth += activity == .entry ? 1 : -1
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func invalidate() {
        observer.map(CFRunLoopObserverInvalidate)
        observer = nil
    }
}

/// What the run loop's timer hands to the main thread, where it runs.
private final class Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The Adjust inspector on the selected frame, made again for each, as the window shows it.
private struct SelectedInspector: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        if let frame = model.selectedFrame { ManualAdjustmentsView(frame: frame).id(frame.url) }
    }
}
