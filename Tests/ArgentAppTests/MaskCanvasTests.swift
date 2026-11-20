import AppKit
import ArgentCore
import Foundation
import Testing
@testable import ArgentApp

/// The canvas as AppKit sees it: what its hit test answers, and that a press reaches the editor. No test that
/// sets `pointerOverArmedCanvas`, a static every slider reads, awaits while it is true, and each leaves it false.
@MainActor @Suite(.serialized) struct MaskCanvasTests {
    private static let area = CGSize(width: 1188, height: 756)

    @MainActor private final class Stage {
        let editor = MaskEditor()
        let window: NSWindow
        let canvas: MaskCanvasView
        var geometry = FrameGeometry(area: MaskCanvasTests.area, picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2)
        var presses = 0

        /// The canvas filling a window's content, as it fills the frame view's area, offset from the
        /// window's corner so that its points are not the window's.
        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 900))
            window.contentView = content
            canvas = MaskCanvasView(editor: editor)
            canvas.frame = NSRect(origin: CGPoint(x: 60, y: 40), size: MaskCanvasTests.area)
            content.addSubview(canvas)
            editor.canvas = canvas
            canvas.geometry = { [unowned self] in self.geometry }
            canvas.onPress = { [unowned self] in self.presses += 1 }
        }

        func finish() {
            canvas.teardown()
            window.close()
        }

        /// A point in the frame view's area, in the superview's coordinates, as a hit test takes it.
        func inSuperview(_ point: CGPoint) -> NSPoint { canvas.convert(point, to: canvas.superview) }

        func event(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }
    }

    private static let onPicture = CGPoint(x: 594, y: 378)

    @Test func withNoToolItAnswersNothing() {
        let stage = Stage()
        defer { stage.finish() }
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) == nil)
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture)) == nil)
        #expect(!MaskCanvasView.pointerOverArmedCanvas)
    }

    @Test func armedItAnswersOverThePictureOnly() {
        let stage = Stage()
        defer { stage.finish() }
        stage.editor.arm(.linear)
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) === stage.canvas)
        // The surround beside a fitted picture stays the frame view's, and a double-click there closes.
        #expect(stage.canvas.hitTest(stage.inSuperview(CGPoint(x: 10, y: 378)), modifiers: []) == nil)
        // Outside the area altogether.
        #expect(stage.canvas.hitTest(stage.inSuperview(CGPoint(x: 594, y: 900)), modifiers: []) == nil)
        // Option and Shift change what the press does, not whose it is.
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: [.option, .shift]) === stage.canvas)
    }

    @Test func commandHandsThePressToTheFrameView() {
        let stage = Stage()
        defer { stage.finish() }
        stage.editor.arm(.linear)
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: .command) == nil)
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: [.command, .option]) == nil)
    }

    @Test func aHiddenCanvasAnswersNothing() {
        let stage = Stage()
        defer { stage.finish() }
        stage.editor.arm(.linear)
        stage.canvas.isHidden = true
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) == nil)
    }

    @Test func aPressReachesTheEditorOnceAndGivesThePhotographTheKeyboard() throws {
        let stage = Stage()
        defer { stage.finish() }
        stage.editor.arm(.radial)
        stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture))
        #expect(stage.presses == 1)
        #expect(stage.editor.canvasCounts.press == 1 && stage.editor.canvasCounts.drag == 0 && stage.editor.canvasCounts.release == 0)
        let down = try #require(stage.editor.lastCanvasEvent)
        #expect(down.phase == .press && down.clickCount == 1)
        #expect(abs(down.fractions.x - 0.5) < 1e-9 && abs(down.fractions.y - 0.5) < 1e-9)
        #expect(down.point == Self.onPicture)

        stage.canvas.mouseDragged(with: try stage.event(.leftMouseDragged, at: CGPoint(x: 621, y: 378)))
        stage.canvas.mouseDragged(with: try stage.event(.leftMouseDragged, at: CGPoint(x: 648, y: 378)))
        stage.canvas.mouseUp(with: try stage.event(.leftMouseUp, at: CGPoint(x: 648, y: 378)))
        #expect(stage.presses == 1)
        #expect(stage.editor.canvasCounts.press == 1 && stage.editor.canvasCounts.drag == 2 && stage.editor.canvasCounts.release == 1)
        let up = try #require(stage.editor.lastCanvasEvent)
        #expect(up.phase == .release && abs(up.fractions.x - (621.0 / 1134)) < 1e-9)
    }

    @Test func modifiersAndClicksTravelWithThePress() throws {
        let stage = Stage()
        defer { stage.finish() }
        stage.editor.arm(.brush)
        stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture, flags: .option, clicks: 2))
        let down = try #require(stage.editor.lastCanvasEvent)
        #expect(down.modifiers.contains(.option) && down.clickCount == 2)
    }

    @Test func aDragKeepsGoingOffThePictureAndOutOfTheArea() throws {
        let stage = Stage()
        defer { stage.finish() }
        stage.editor.arm(.linear)
        stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture))
        stage.canvas.mouseDragged(with: try stage.event(.leftMouseDragged, at: CGPoint(x: -40, y: 900)))
        #expect(stage.editor.canvasCounts.drag == 1)
        let drag = try #require(stage.editor.lastCanvasEvent)
        #expect(drag.fractions.x < 0 && drag.fractions.y > 1)
        stage.canvas.mouseUp(with: try stage.event(.leftMouseUp, at: CGPoint(x: -40, y: 900)))
        #expect(stage.editor.canvasCounts.release == 1)
    }

    /// A pinch or a scroll under a press moves the picture: the pointer is read against where it is now.
    @Test func aPictureThatMovesUnderAPressIsReadWhereItIsNow() throws {
        let stage = Stage()
        defer { stage.finish() }
        stage.editor.arm(.linear)
        stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture))
        stage.geometry.picture = CGRect(x: 0, y: 0, width: 1188, height: 792)
        stage.canvas.mouseDragged(with: try stage.event(.leftMouseDragged, at: Self.onPicture))
        let drag = try #require(stage.editor.lastCanvasEvent)
        #expect(abs(drag.fractions.x - 0.5) < 1e-9 && abs(drag.fractions.y - 378.0 / 792) < 1e-9)
    }

    @Test func aPressWithNoToolDoesNothingAndAToolPutDownMidPressEndsIt() throws {
        let stage = Stage()
        defer { stage.finish() }
        stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture))
        stage.canvas.mouseDragged(with: try stage.event(.leftMouseDragged, at: Self.onPicture))
        stage.canvas.mouseUp(with: try stage.event(.leftMouseUp, at: Self.onPicture))
        #expect(stage.presses == 0 && stage.editor.lastCanvasEvent == nil)

        stage.editor.arm(.linear)
        stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture))
        stage.editor.reset()
        stage.canvas.mouseDragged(with: try stage.event(.leftMouseDragged, at: Self.onPicture))
        stage.canvas.mouseUp(with: try stage.event(.leftMouseUp, at: Self.onPicture))
        #expect(stage.editor.canvasCounts.press == 1 && stage.editor.canvasCounts.drag == 0 && stage.editor.canvasCounts.release == 0)
    }

    /// A right-click is never a press, with a tool in hand or none: it asks for a menu, and the canvas's own buttons are the left's.
    /// With no frame to make a menu for there is none, and the click goes on up the responder chain.
    @Test func aRightClickNeverDrawsOrPaints() throws {
        let stage = Stage()
        defer { stage.finish() }
        for tool in MaskEditor.Tool.allCases {
            stage.editor.arm(tool)
            stage.canvas.rightMouseDown(with: try stage.event(.rightMouseDown, at: Self.onPicture))
            stage.canvas.rightMouseDragged(with: try stage.event(.rightMouseDragged, at: CGPoint(x: 700, y: 400)))
            stage.canvas.rightMouseUp(with: try stage.event(.rightMouseUp, at: CGPoint(x: 700, y: 400)))
            #expect(stage.editor.canvasCounts.press == 0 && stage.editor.canvasCounts.drag == 0 && stage.editor.canvasCounts.release == 0)
            #expect(stage.presses == 0 && stage.canvas.menusGiven == 0 && stage.editor.press == nil)
        }
    }

    /// A Control-click is the Mac's right-click: with a tool in hand it was a press of the canvas's (measured on the base commit through
    /// the window: it drew a gradient's press and the brush's). It is none now, and a drag after it moves nothing.
    @Test func aControlClickIsNeverAPress() throws {
        let stage = Stage()
        defer { stage.finish() }
        for tool in MaskEditor.Tool.allCases {
            stage.editor.arm(tool)
            stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture, flags: .control))
            stage.canvas.mouseDragged(with: try stage.event(.leftMouseDragged, at: CGPoint(x: 700, y: 400), flags: .control))
            stage.canvas.mouseUp(with: try stage.event(.leftMouseUp, at: CGPoint(x: 700, y: 400), flags: .control))
            #expect(stage.editor.canvasCounts.press == 0 && stage.editor.canvasCounts.drag == 0 && stage.editor.canvasCounts.release == 0)
            #expect(stage.presses == 0 && stage.editor.press == nil)
            // Control with Option or Shift too.
            stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture, flags: [.control, .option, .shift]))
            #expect(stage.editor.canvasCounts.press == 0)
        }
        // The click goes to the canvas over an armed picture, menu or none: nothing under it takes it as a press either.
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: .control, menuClick: true) === stage.canvas)
        stage.editor.reset()
        // With no frame to make a menu for, and no tool, it is nobody's here.
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: .control, menuClick: true) == nil)
        #expect(stage.canvas.menu(for: try stage.event(.rightMouseDown, at: Self.onPicture)) == nil)
    }

    /// What pinch, smart zoom and scroll go through is the window's monitor, before any view; the canvas
    /// leaves the responder's own methods alone in case one ever reaches it.
    @Test func itDoesNotTakeScrollOrMagnify() {
        for selector in [#selector(NSResponder.scrollWheel(with:)), #selector(NSResponder.magnify(with:)),
                         #selector(NSResponder.smartMagnify(with:))] {
            #expect(MaskCanvasView.instanceMethod(for: selector) == NSView.instanceMethod(for: selector))
        }
    }

    @Test func theKeyboardNeverStopsHere() {
        let stage = Stage()
        defer { stage.finish() }
        #expect(!stage.canvas.acceptsFirstResponder)
        #expect(stage.canvas.acceptsFirstMouse(for: nil))
    }

    @Test func thePointerOverAnArmedPictureIsWhatTheSliderAsksAbout() throws {
        let stage = Stage()
        defer { stage.finish() }
        // Unarmed there is nothing to know.
        stage.canvas.mouseMoved(with: try stage.event(.mouseMoved, at: Self.onPicture))
        #expect(!MaskCanvasView.pointerOverArmedCanvas)
        stage.editor.arm(.brush)
        stage.canvas.mouseMoved(with: try stage.event(.mouseMoved, at: Self.onPicture))
        #expect(MaskCanvasView.pointerOverArmedCanvas)
        // The surround is not the picture.
        stage.canvas.mouseMoved(with: try stage.event(.mouseMoved, at: CGPoint(x: 10, y: 378)))
        #expect(!MaskCanvasView.pointerOverArmedCanvas)
        stage.canvas.mouseEntered(with: try stage.event(.mouseMoved, at: Self.onPicture))
        #expect(MaskCanvasView.pointerOverArmedCanvas)
        // Off the view, and with the tool put down.
        stage.canvas.mouseExited(with: try stage.event(.mouseMoved, at: CGPoint(x: 2000, y: 2000)))
        #expect(!MaskCanvasView.pointerOverArmedCanvas)
        stage.canvas.mouseMoved(with: try stage.event(.mouseMoved, at: Self.onPicture))
        #expect(MaskCanvasView.pointerOverArmedCanvas)
        stage.editor.reset()
        #expect(!MaskCanvasView.pointerOverArmedCanvas)
    }

    /// A press on a handle with no tool in hand does not make Option the tool's: there is no tool to want it, and
    /// a focused slider may still show its clipping view.
    @Test func aHandleWithNoToolLeavesOptionToTheSlider() async throws {
        let stage = Stage()
        defer { stage.finish() }
        stage.canvas.mouseMoved(with: try stage.event(.mouseMoved, at: Self.onPicture))
        #expect(!MaskCanvasView.pointerOverArmedCanvas)
    }

    /// A canvas says what it knows and leaves the static alone otherwise, so a canvas that never had a tool under
    /// the pointer cannot take the answer from one that does.
    @Test func aCanvasWritesTheStaticOnlyWhenItsOwnAnswerChanges() throws {
        let stage = Stage()
        defer { stage.finish(); MaskCanvasView.pointerOverArmedCanvas = false }
        // Not arming here: arming reads where the real pointer is, which may be anywhere.
        MaskCanvasView.pointerOverArmedCanvas = true
        stage.editor.reset()
        stage.canvas.pictureChanged()
        stage.canvas.toolChanged()
        #expect(MaskCanvasView.pointerOverArmedCanvas)
    }

    private func window() -> (NSWindow, AdjustmentSliderControl) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let slider = AdjustmentSliderControl(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        slider.cell = NSSliderCell()
        slider.spec = .light(.exposure)
        slider.isEnabled = true
        window.contentView?.addSubview(slider)
        window.makeFirstResponder(slider)
        return (window, slider)
    }

    private func modifiers(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58))
    }

    private func typed(_ text: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                      characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 24))
    }

    /// Option with the pointer over an armed canvas is the tool's: the clipping view waits for the
    /// pointer to leave, and works as ever over the inspector. The slider is given its own wait and its own
    /// answer for where the pointer is, in place of the statics every slider and canvas share: other suites'
    /// canvases and sliders, running beside this one, wrote those during its waits and failed it (T8, T9).
    @Test func optionOverAnArmedCanvasDoesNotStartTheClippingView() async throws {
        let (window, exposure) = window()
        defer { window.close() }
        var shown: [Bool] = []
        final class Pointer: @unchecked Sendable { var over = true }
        let pointer = Pointer()
        exposure.onClipping = { shown.append($0) }
        exposure.isPointerOverArmedCanvas = { pointer.over }
        exposure.optionWait = .milliseconds(1)

        exposure.flagsChanged(with: try modifiers(.option))
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown.isEmpty && !exposure.isClipping)
        exposure.flagsChanged(with: try modifiers([]))

        // The pointer arriving during the wait ends it too.
        pointer.over = false
        exposure.optionWait = .milliseconds(50)
        exposure.flagsChanged(with: try modifiers(.option))
        pointer.over = true
        try await Task.sleep(for: .milliseconds(150))
        #expect(shown.isEmpty && !exposure.isClipping)
        exposure.flagsChanged(with: try modifiers([]))

        // Off the canvas it shows as ever.
        pointer.over = false
        exposure.optionWait = .milliseconds(1)
        exposure.flagsChanged(with: try modifiers(.option))
        // Waited for rather than looked for a tenth of a second on: another suite holding the main actor past that moment failed
        // this though the view came as it should. The bound is for a view that never comes.
        let limit = ContinuousClock.now + .seconds(10)
        while !exposure.isClipping, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
        #expect(shown == [true] && exposure.isClipping)
        exposure.flagsChanged(with: try modifiers([]))
        #expect(shown == [true, false] && !exposure.isClipping)

        // A key step with Option is the slider's own, wherever the pointer is.
        pointer.over = true
        exposure.keyDown(with: try typed("=", flags: .option))
        #expect(shown == [true, false, true] && Float(exposure.doubleValue) == 0.1)
    }

    /// A slider reads the canvases' shared answer unless given its own: what the app does.
    @Test func aSliderReadsTheCanvasesAnswerByDefault() {
        let (window, exposure) = window()
        defer { window.close(); MaskCanvasView.pointerOverArmedCanvas = false }
        #expect(exposure.optionWait == AdjustmentSliderControl.optionSettle && AdjustmentSliderControl.optionSettle == .milliseconds(250))
        MaskCanvasView.pointerOverArmedCanvas = true
        #expect(exposure.isPointerOverArmedCanvas())
        MaskCanvasView.pointerOverArmedCanvas = false
        #expect(!exposure.isPointerOverArmedCanvas())
    }

    /// A frame's canvas replaced by the next one's: SwiftUI may make the new before it lets the old go.
    @Test func lettingGoOfAnOldCanvasLeavesTheNewOne() {
        let stage = Stage()
        defer { stage.finish() }
        let next = MaskCanvasView(editor: stage.editor)
        stage.editor.canvas = next
        stage.canvas.teardown()
        #expect(stage.editor.canvas === next)
        next.teardown()
        #expect(stage.editor.canvas == nil)
    }
}
