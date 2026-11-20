import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// The canvas while the Remove tab shows (docs/remove-plan.md, section 4.8): a press on the photograph is the Remove brush's and
/// reaches `removeBrush`, never the masks; on another tab it is the masks' and never Remove's; and the ring is the brush's at the
/// session's size. No test here leaves `pointerOverArmedCanvas` true, a static every slider reads.
@MainActor @Suite(.serialized) struct RemoveCanvasTests {
    private static let area = CGSize(width: 1188, height: 756)
    private static let onPicture = CGPoint(x: 594, y: 378)

    /// The canvas over a bench's model, filling a window's content as it fills the frame view's area, with a stand-in for the
    /// model's commands.
    @MainActor private final class Stage {
        let bench: RemoveBench
        let recorder = RemoveRecorder()
        let window: NSWindow
        let canvas: MaskCanvasView
        var geometry = FrameGeometry(area: RemoveCanvasTests.area, picture: CGRect(x: 27, y: 0, width: 1134, height: 756), displayScale: 2)
        var presses = 0

        var model: RollModel { bench.model }
        var editor: MaskEditor { bench.model.maskEditor }

        init(tab: AdjustInspectorTab = .remove) async throws {
            bench = try await RemoveBench(tab: tab)
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 900))
            window.contentView = content
            canvas = MaskCanvasView(editor: bench.model.maskEditor)
            canvas.frame = NSRect(origin: CGPoint(x: 60, y: 40), size: RemoveCanvasTests.area)
            content.addSubview(canvas)
            bench.model.maskEditor.canvas = canvas
            canvas.geometry = { [unowned self] in self.geometry }
            canvas.onPress = { [unowned self] in self.presses += 1 }
            canvas.removeCommands = recorder
        }

        func finish() {
            canvas.teardown()
            window.close()
            bench.finish()
        }

        func inSuperview(_ point: CGPoint) -> NSPoint { canvas.convert(point, to: canvas.superview) }

        func event(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        /// A press, two drags and a release across the picture.
        func stroke(flags: NSEvent.ModifierFlags = []) throws {
            canvas.mouseDown(with: try event(.leftMouseDown, at: RemoveCanvasTests.onPicture, flags: flags))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 621, y: 378), flags: flags))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 648, y: 400), flags: flags))
            canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 648, y: 400), flags: flags))
        }

        var maskCounts: [Int] { [editor.canvasCounts.press, editor.canvasCounts.drag, editor.canvasCounts.release] }
        var removeCounts: [Int] { [canvas.removeCounts.press, canvas.removeCounts.drag, canvas.removeCounts.release] }
    }

    @Test func withTheRemoveTabAPressReachesRemoveBrushAndNotTheMasks() async throws {
        let stage = try await Stage()
        defer { stage.finish() }
        // No tool is armed and no mask selected: the tab alone puts the brush in hand.
        #expect(!stage.editor.isArmed && stage.editor.selection == nil)
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) === stage.canvas)
        try stage.stroke()
        #expect(stage.recorder.calls == ["removeBrush", "removeBrush", "removeBrush", "removeBrush"])
        #expect(stage.recorder.brush.map(\.phase) == [.press, .drag, .drag, .release])
        #expect(stage.recorder.frames.allSatisfy { $0 == stage.bench.frame.url })
        #expect(stage.removeCounts == [1, 2, 1] && stage.canvas.lastRemoveEvent == stage.recorder.brush.last)
        // Where on the picture, read from the rectangle as drawn.
        let down = try #require(stage.recorder.brush.first), up = try #require(stage.recorder.brush.last)
        #expect(abs(down.fractions.x - 0.5) < 1e-9 && abs(down.fractions.y - 0.5) < 1e-9 && down.point == Self.onPicture)
        #expect(abs(up.fractions.x - 621.0 / 1134) < 1e-9 && abs(up.fractions.y - 400.0 / 756) < 1e-9)
        // The masks heard nothing of it, and the photograph took the keyboard once.
        #expect(stage.maskCounts == [0, 0, 0] && stage.editor.lastCanvasEvent == nil && stage.editor.press == nil && !stage.editor.brush.isPainting)
        #expect(stage.presses == 1)
        // The press over, the canvas is at rest again.
        #expect(!stage.canvas.removeTakesPress(at: CGPoint(x: 10, y: 378), command: false))
    }

    @Test func withAnotherTabAPressReachesTheMasksAndNotRemoveBrush() async throws {
        let stage = try await Stage(tab: .masks)
        defer { stage.finish() }
        // With no tool the canvas answers nothing, as it always has.
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) == nil)
        #expect(!stage.canvas.removeTakesPress(at: Self.onPicture, command: false))
        stage.editor.arm(.linear)
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) === stage.canvas)
        try stage.stroke()
        #expect(stage.maskCounts == [1, 2, 1])
        #expect(stage.recorder.calls.isEmpty && stage.removeCounts == [0, 0, 0] && stage.canvas.lastRemoveEvent == nil)
        // Light, Curve and Lens have no tool at all.
        for tab in [AdjustInspectorTab.light, .curve, .lens] {
            stage.model.adjustTab = tab
            #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) == nil, "\(tab)")
            stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture))
            stage.canvas.mouseUp(with: try stage.event(.leftMouseUp, at: Self.onPicture))
        }
        #expect(stage.recorder.calls.isEmpty && stage.maskCounts == [1, 2, 1])
        // And with the inspector closed on the Remove tab, the brush is in nobody's hand.
        stage.model.adjustTab = .remove
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) === stage.canvas)
        stage.model.isAdjustmentsShown = false
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) == nil)
    }

    /// The rule the frame view's pan and double-click ask too: the picture the area shows, never with Command, never the surround.
    @Test func theBrushTakesThePictureAndLeavesCommandAndTheSurroundToTheFrameView() async throws {
        let stage = try await Stage()
        defer { stage.finish() }
        #expect(stage.canvas.takesPress(at: Self.onPicture, command: false))
        #expect(!stage.canvas.takesPress(at: Self.onPicture, command: true))
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: .command) == nil)
        #expect(stage.canvas.hitTest(stage.inSuperview(CGPoint(x: 10, y: 378)), modifiers: []) == nil)
        #expect(stage.canvas.hitTest(stage.inSuperview(CGPoint(x: 594, y: 900)), modifiers: []) == nil)
        // Option and Shift change what the stroke does, not whose it is.
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: [.option, .shift]) === stage.canvas)
        // A split's neutral side is the frame view's.
        stage.geometry.filmEdge = 700
        #expect(!stage.canvas.takesPress(at: Self.onPicture, command: false) && stage.canvas.takesPress(at: CGPoint(x: 800, y: 378), command: false))
        stage.geometry.filmEdge = nil
        // A Command-click and a Control-click paint nothing.
        stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture, flags: .control))
        stage.canvas.mouseUp(with: try stage.event(.leftMouseUp, at: Self.onPicture, flags: .control))
        #expect(stage.recorder.calls.isEmpty && stage.presses == 0)
    }

    @Test func optionAtThePressAndAStrokePastTheEdgeTravelWithIt() async throws {
        let stage = try await Stage()
        defer { stage.finish() }
        stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture, flags: .option))
        #expect(stage.recorder.brush.last?.modifiers.contains(.option) == true)
        // Once begun the stroke is the brush's wherever it goes, off the picture and out of the area.
        #expect(stage.canvas.takesPress(at: CGPoint(x: -40, y: 900), command: true))
        stage.canvas.mouseDragged(with: try stage.event(.leftMouseDragged, at: CGPoint(x: -40, y: 900), flags: .option))
        let drag = try #require(stage.recorder.brush.last)
        #expect(drag.phase == .drag && drag.fractions.x < 0 && drag.fractions.y > 1)
        stage.canvas.mouseUp(with: try stage.event(.leftMouseUp, at: CGPoint(x: -40, y: 900)))
        #expect(stage.recorder.brush.map(\.phase) == [.press, .drag, .release])
    }

    /// Space, Compare to Auto, the clipping view and a frame that cannot be adjusted: the canvas keeps the press, so nothing
    /// under it pans or closes the frame, and it does nothing.
    @Test func whileRemoveStandsDownAPressDoesNothing() async throws {
        let stage = try await Stage()
        defer { stage.finish() }
        stage.model.isComparing = true
        #expect(stage.canvas.hitTest(stage.inSuperview(Self.onPicture), modifiers: []) === stage.canvas)
        try stage.stroke()
        #expect(stage.recorder.calls.isEmpty && stage.removeCounts == [0, 0, 0] && stage.maskCounts == [0, 0, 0])
        #expect(stage.presses == 1)
        stage.model.isComparing = false
        stage.bench.block(true)
        try stage.stroke()
        #expect(stage.recorder.calls.isEmpty)
        stage.bench.block(false)
        try stage.stroke()
        #expect(stage.recorder.brush.map(\.phase) == [.press, .drag, .drag, .release])
    }

    /// Another tab chosen during a stroke ends it: the tab's going drops the selection, and the next events are nobody's.
    @Test func theTabGoingDuringAStrokeEndsIt() async throws {
        let stage = try await Stage()
        defer { stage.finish() }
        stage.canvas.mouseDown(with: try stage.event(.leftMouseDown, at: Self.onPicture))
        stage.model.adjustTab = .light
        stage.canvas.mouseDragged(with: try stage.event(.leftMouseDragged, at: CGPoint(x: 621, y: 378)))
        stage.canvas.mouseUp(with: try stage.event(.leftMouseUp, at: CGPoint(x: 621, y: 378)))
        #expect(stage.recorder.brush.map(\.phase) == [.press] && stage.maskCounts == [0, 0, 0])
        #expect(!stage.canvas.takesPress(at: Self.onPicture, command: false))
    }

    @Test func theRingIsTheBrushAtTheSessionsSize() async throws {
        let stage = try await Stage()
        defer { stage.finish(); MaskCanvasView.pointerOverArmedCanvas = false }
        // The real keyboard is the test machine's: with Command down no ring shows, and this has nothing to say.
        guard !NSEvent.modifierFlags.contains(.command) else { return }
        #expect(!stage.canvas.ring.isShown)
        stage.canvas.pointerMoved(to: Self.onPicture)
        #expect(stage.canvas.ring.isShown && stage.canvas.ring.position == Self.onPicture)
        // Size 4 is a diameter of 4 hundredths of the picture's 1134 points: a radius of 22.68, and no feather's circle.
        let radii = try #require(stage.canvas.ring.radii)
        #expect(abs(radii.outer - 22.68) < 1e-6 && radii.inner == 0)
        // Option is the brush's there, and no slider's.
        #expect(MaskCanvasView.pointerOverArmedCanvas)
        stage.model.remove.brushSize = 10
        stage.canvas.brushChanged()
        #expect(abs((stage.canvas.ring.radii?.outer ?? 0) - 56.7) < 1e-6)
        // It grows with the picture.
        stage.geometry.picture = CGRect(x: -540, y: -378, width: 2268, height: 1512)
        stage.canvas.pictureChanged()
        #expect(abs((stage.canvas.ring.radii?.outer ?? 0) - 113.4) < 1e-6)
        stage.geometry.picture = CGRect(x: 27, y: 0, width: 1134, height: 756)
        // Off the picture, standing down, and on another tab there is none.
        stage.canvas.pointerMoved(to: CGPoint(x: 10, y: 378))
        #expect(!stage.canvas.ring.isShown && !MaskCanvasView.pointerOverArmedCanvas)
        stage.canvas.pointerMoved(to: Self.onPicture)
        stage.model.isComparing = true
        stage.canvas.pictureChanged()
        #expect(!stage.canvas.ring.isShown)
        stage.model.isComparing = false
        stage.canvas.pictureChanged()
        #expect(stage.canvas.ring.isShown)
        stage.model.adjustTab = .light
        stage.canvas.pointerMoved(to: Self.onPicture)
        #expect(!stage.canvas.ring.isShown && !MaskCanvasView.pointerOverArmedCanvas)
    }
}
