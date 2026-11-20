import AppKit
import ArgentCore
import ArgentRoll
import QuartzCore
import SwiftUI

/// One step of a press the mask canvas took. `fractions` is where on the picture, upright, from its top
/// left (`FrameGeometry.normalized`), read from the rectangle drawn at that moment, so a zoom or a
/// resize under a press stays right; `point` is the same place in the frame view's area.
struct MaskCanvasEvent: Equatable {
    enum Phase: Equatable { case press, drag, release }

    var phase: Phase
    var fractions: CGPoint
    var point: CGPoint
    var modifiers: NSEvent.ModifierFlags
    var clickCount: Int
    /// The event's own time, from system start, for a stroke's report of how often the pointer reported. Not compared.
    var time: TimeInterval = 0

    static func == (a: MaskCanvasEvent, b: MaskCanvasEvent) -> Bool {
        a.phase == b.phase && a.fractions == b.fractions && a.point == b.point
            && a.modifiers.rawValue == b.modifiers.rawValue && a.clickCount == b.clickCount
    }
}

/// The thin AppKit view over the photograph, in `FramePicture`'s stack under the split divider and the
/// comparison's tags, that takes the pointer while a mask tool is armed, over the picture the area shows, or
/// on a handle of the selected gradient or on a pin, and never with Command held (`MaskEditor.canvasTakesPress`).
/// Pinch, smart zoom and scroll pass through the window's monitor (`TrackpadEvents`), which AppKit runs before it
/// picks a view, so no tool can disturb them. With no tool armed, no mask selected and no pin wanted it answers no
/// press and tracks nothing.
///
/// While the Remove tab shows it is the Remove brush's instead (docs/remove-plan.md, section 4.8): every press on the picture
/// goes to `RollModel.removeBrush`, none to the masks, and the ring is the brush's at the session's size.
///
/// It is also where the photograph's menu comes from, and a pin's (`PhotographMenu`): a right-click or a Control-click
/// anywhere on the area (`MaskEditor.canvasTakesMenu`). An AppKit view is given the event the menu was asked with, so
/// Actual Size can zoom about the pointer as smart zoom does, and a pin under it is known; SwiftUI's `contextMenu`
/// gives neither. And the canvas already says whose the pointer is, so a click is the menu's or a press's in one place.
struct MaskCanvas: NSViewRepresentable {
    let editor: MaskEditor
    /// The picture as drawn, read afresh at each event rather than as of the last body.
    let geometry: @MainActor () -> FrameGeometry
    /// The canvas took a press: the photograph takes the keyboard back.
    let onPress: @MainActor () -> Void

    func makeNSView(context: Context) -> MaskCanvasView {
        let view = MaskCanvasView(editor: editor)
        editor.canvas = view
        return view
    }

    func updateNSView(_ view: MaskCanvasView, context: Context) {
        view.geometry = geometry
        view.onPress = onPress
        view.pictureChanged()
    }

    static func dismantleNSView(_ view: MaskCanvasView, coordinator: ()) { view.teardown() }
}

@MainActor
final class MaskCanvasView: NSView {
    /// The pointer is on the picture of an armed canvas, so Option is the tool's: a Light slider still
    /// holding the keyboard does not start its clipping view (`AdjustmentSliderControl.flagsChanged`).
    /// Static because the slider has no model to ask.
    static var pointerOverArmedCanvas = false

    var geometry: (@MainActor () -> FrameGeometry)?
    var onPress: (@MainActor () -> Void)?

    private let editor: MaskEditor
    private var tracking: NSTrackingArea?
    private var flagsMonitor: Any?
    private var pointer: CGPoint?
    /// Whether the press under way is this view's.
    private var isPressed = false
    /// This canvas's own answer to `pointerOverArmedCanvas`, which it writes only when that changes.
    private var isPointerOverArmed = false
    /// `followsPointer` as this canvas last set itself up for it, and whether it is watching for a change.
    private var follows = false, isObserving = false

    /// A press the Remove brush took: its frame, whether Option was down at it, which makes the whole stroke subtract, and
    /// whether the model is told of it. A press while Remove stands down is the canvas's and does nothing, as a tool's is.
    private struct RemovePress {
        let frame: Frame
        let subtracts: Bool
        let isSent: Bool
    }

    private var removePress: RemovePress?
    /// The Remove brush's size as the ring last drew it.
    private var removeSize: Double?
    /// What a Remove press goes to in place of the model, for a test.
    var removeCommands: (any RemoveCommands)?
    /// For the tests and the drive hook: what the canvas gave the Remove brush.
    private(set) var removeCounts = (press: 0, drag: 0, release: 0)
    private(set) var lastRemoveEvent: MaskCanvasEvent?
    /// The brush's ring, over everything the canvas covers.
    let ring = MaskBrushRing()

    init(editor: MaskEditor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(ring.layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Flipped, and the area's size, so its points are the frame view's named space's.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func teardown() {
        removeFlagsMonitor()
        removePress = nil
        if editor.canvas === self {
            setPointerOverArmed(false)
            editor.canvas = nil
        }
    }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let event = NSApp.currentEvent
        return hitTest(point, modifiers: event?.modifierFlags ?? [], menuClick: MaskEditor.isMenuClick(event))
    }

    /// `point` in the superview's coordinates, as `hitTest(_:)` has it, and the modifiers and the kind of click apart so a
    /// test can say them. A right-click or a Control-click is the canvas's where it opens a menu, and where a press would be
    /// the canvas's: there it opens nothing while a press is open, but reaches nothing under the canvas either.
    func hitTest(_ point: NSPoint, modifiers: NSEvent.ModifierFlags, menuClick: Bool = false) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        if menuClick, removePress == nil, editor.canvasTakesMenu(at: local) { return self }
        return takesPress(at: local, command: modifiers.contains(.command)) ? self : nil
    }

    // MARK: Remove

    /// The frame the Remove brush works on: the open frame, while the inspector shows the Remove tab.
    private var removeFrame: Frame? { editor.model.flatMap(RemovePhotograph.frame) }

    /// The canvas needs to know where the pointer is: for the masks (`MaskEditor.followsPointer`), or for the Remove brush's ring.
    private var followsPointer: Bool { editor.followsPointer || removeFrame != nil }

    /// Whose a press at `point` is, for the hit test and for the frame view's pan and double-click, which SwiftUI feeds the same
    /// events: the Remove brush's while its tab shows, else the masks' by their own rule (`MaskEditor.canvasTakesPress`).
    func takesPress(at point: CGPoint, command: Bool) -> Bool {
        removeTakesPress(at: point, command: command) || editor.canvasTakesPress(at: point, command: command)
    }

    /// The Remove brush takes every press on the part of the picture the area shows, on the film side of a split, and never
    /// with Command held, which pans; and always once it has one under way.
    func removeTakesPress(at point: CGPoint, command: Bool) -> Bool {
        if removePress != nil { return true }
        guard !command, removeFrame != nil, let geometry = geometry?() else { return false }
        return geometry.toolPicture.contains(point)
    }

    // MARK: The menu

    /// For the tests and the drive hook: how many menus the canvas has given AppKit to open, and the last while AppKit holds it.
    private(set) var menusGiven = 0
    private(set) weak var lastMenu: NSMenu?

    /// The menu for a right-click or a Control-click, made from its table at the event (`PhotographMenu.entries`) and never kept as the
    /// view's `menu`, so its keys are shown and bind nothing: the menu bar's items keep them. AppKit asks this before it sends a
    /// Control-click's press, and opens what it gets in place of the press (measured: with none, the press came, and a tool drew).
    /// The keyboard stays with the photograph, as after a press.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard removePress == nil, let model = editor.model,
              let entries = PhotographMenu.entries(at: convert(event.locationInWindow, from: nil), model: model),
              !entries.isEmpty else { return nil }
        menusGiven += 1
        onPress?()
        let menu = NSMenu(entries: entries)
        lastMenu = menu
        return menu
    }

    // MARK: The press

    override func mouseDown(with event: NSEvent) {
        // A Control-click comes here only when no menu was given (Space held, a slider's gesture open, the divider): it is no press
        // either, which would draw, paint a dab or place a gradient where the photographer asked for a menu.
        guard !MaskEditor.isMenuClick(event) else { return }
        let point = convert(event.locationInWindow, from: nil), command = event.modifierFlags.contains(.command)
        if removeTakesPress(at: point, command: command), let frame = removeFrame {
            removePress = RemovePress(frame: frame, subtracts: event.modifierFlags.contains(.option),
                                      isSent: !(editor.model?.masksStandDown(frame) ?? true))
        } else if !editor.canvasTakesPress(at: point, command: command) {
            super.mouseDown(with: event)
            return
        }
        isPressed = true
        onPress?()
        send(.press, event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPressed else { super.mouseDragged(with: event); return }
        send(.drag, event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { super.mouseUp(with: event); return }
        isPressed = false
        send(.release, event)
        if removePress != nil {
            removePress = nil
            updateRing()
        }
        // Where the release left the pointer, for the pins: a drag's moves are not the pointer's hovering.
        notePins()
    }

    private func send(_ phase: MaskCanvasEvent.Phase, _ event: NSEvent) {
        guard let geometry = geometry?() else { return }
        let point = convert(event.locationInWindow, from: nil)
        self.pointer = point
        // The ring first: it lands at the next refresh, whatever the stroke's own work costs.
        updateRing()
        let step = MaskCanvasEvent(phase: phase, fractions: geometry.normalized(point), point: point,
                                   modifiers: event.modifierFlags, clickCount: event.clickCount, time: event.timestamp)
        if let removePress {
            if removePress.isSent { sendRemove(step, on: removePress.frame) }
        } else {
            editor.canvasEvent(step)
        }
        if phase == .release { updateRing() }
    }

    private func sendRemove(_ step: MaskCanvasEvent, on frame: Frame) {
        switch step.phase {
        case .press: removeCounts.press += 1
        case .drag: removeCounts.drag += 1
        case .release: removeCounts.release += 1
        }
        lastRemoveEvent = step
        (removeCommands ?? editor.model)?.removeBrush(step, on: frame)
    }

    // MARK: Following the tool and the pointer

    /// A tool was armed or put down, or a mask selected: tracking and the Command monitor exist only while
    /// there is a tool in hand or a handle showing.
    func toolChanged() {
        // A tool put down during its press ends the press; a handle's goes on with no tool.
        if !editor.isArmed, editor.press == nil, !editor.brush.isPainting, removePress == nil { isPressed = false }
        // The Remove tab gone during its press ends that one: the tab's going drops the selection (`RollModel.removeTabHidden`).
        if removePress != nil, removeFrame == nil {
            removePress = nil
            isPressed = false
        }
        updateTrackingAreas()
        updateFlagsMonitor()
        // A pointer that has not moved: no event will say where it is.
        if let window, followsPointer {
            pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
        pictureChanged()
    }

    /// The picture moved under the pointer, or Command changed what the pointer does there.
    func pictureChanged() {
        noteHover()
        updateRing()
        guard followsPointer || hasCursorRect else { return }
        window?.invalidateCursorRects(for: self)
    }

    /// The brush's size, feather or Erase changed: the ring follows at once.
    func brushChanged() { updateRing() }

    /// The ring at the pointer, sized by the brush on the picture as drawn now, or hidden: only with the brush in hand, the pointer on
    /// the picture the area shows and on the film side of a split (a stroke under way keeps its ring past it, as past the picture's edge), Command up (a drag then pans) and the masks not standing down (Space, Compare to Auto, the clipping
    /// view, a frame not ready). Set with actions off, so it lands at the next refresh with no SwiftUI between (R7 5.2, P0-S2).
    /// The Remove brush's is the same ring by the same rule, a circle its size with no feather's, and a minus while Option would
    /// make the stroke subtract.
    func updateRing() {
        let modifiers = NSEvent.modifierFlags
        if let frame = removeFrame, let model = editor.model {
            // A stroke under way keeps its ring past the picture's edge; one the canvas took while Remove stood down has none.
            guard let pointer, let geometry = geometry?(), !modifiers.contains(.command),
                  removePress != nil || geometry.toolPicture.contains(pointer),
                  removePress?.isSent ?? !model.masksStandDown(frame) else {
                ring.hide()
                return
            }
            let radius = RemovePhotograph.brushRadius(size: model.remove.brushSize) * geometry.longSide
            ring.show(at: pointer, outer: radius, inner: 0, erase: removePress?.subtracts ?? modifiers.contains(.option))
            return
        }
        guard editor.tool == .brush, let pointer, let geometry = geometry?(),
              editor.brush.isPainting || geometry.toolPicture.contains(pointer), !modifiers.contains(.command),
              !(editor.model.flatMap { model in model.shownFrame.map(model.masksStandDown) } ?? false) else {
            ring.hide()
            return
        }
        let brush = editor.brush.settings, profile = brush.profile
        ring.show(at: pointer, outer: CGFloat(profile.outer) * geometry.longSide, inner: CGFloat(profile.inner) * geometry.longSide,
                  erase: brush.erase != modifiers.contains(.option))
    }

    private func noteHover() {
        guard editor.canvas === self else { return }
        setPointerOverArmed((editor.isArmed || removeFrame != nil)
                            && (pointer.map { takesPress(at: $0, command: NSEvent.modifierFlags.contains(.command)) } ?? false))
        if !isPressed { notePins() }
    }

    /// Whether the pointer is over the area, where the pins show, and on which pin: the editor's to keep (`MaskEditor.pointerMoved`).
    private func notePins() {
        guard editor.canvas === self else { return }
        let area = geometry?().area ?? bounds.size
        let inArea = pointer.map { CGRect(origin: .zero, size: area).contains($0) } ?? false
        editor.pointerMoved(inArea: inArea, over: inArea ? pointer.flatMap { editor.pin(at: $0, pressing: false) } : nil)
    }

    /// Asks again whenever what `followsPointer` reads changes (the tab, the frame's masks, H): pins need the pointer with no tool in
    /// hand and nothing selected, and nothing else would tell the canvas so. The Remove brush's size is read with it, so its ring
    /// follows the slider and the keys alike.
    private func followFollowsPointer() {
        guard window != nil else { isObserving = false; return }
        isObserving = true
        let now = withObservationTracking {
            (follows: followsPointer, size: removeFrame == nil ? nil : editor.model?.remove.brushSize)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followFollowsPointer() }
        }
        let resized = now.size != removeSize
        removeSize = now.size
        if now.follows != follows {
            follows = now.follows
            toolChanged()
        } else if resized {
            updateRing()
        }
    }

    /// Where the canvas last had the pointer, in the area: for the drive hook, to tell whether a posted move reached it.
    var pointerLocation: CGPoint? { pointer }

    /// For the drive hook: the pointer as a move to `point` in the area would leave it, or off the area with none.
    func pointerMoved(to point: CGPoint?) {
        pointer = point
        noteHover()
        updateRing()
    }

    private func setPointerOverArmed(_ over: Bool) {
        guard over != isPointerOverArmed else { return }
        isPointerOverArmed = over
        Self.pointerOverArmedCanvas = over
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !isObserving { followFollowsPointer() }
        updateFlagsMonitor()
        if let rate = window?.screen?.maximumFramesPerSecond, rate > 0 { editor.overlay.refreshesPerSecond = rate }
        if window != nil, followsPointer { toolChanged() }
    }

    /// Cursor rects do not refresh when a modifier key changes, and Command turns the canvas into a pan,
    /// so a monitor asks AppKit to rebuild them; the grab hand then follows the key.
    private func updateFlagsMonitor() {
        guard window != nil, followsPointer else { removeFlagsMonitor(); return }
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Command hides the ring and Option turns it to an eraser's, wherever the keyboard is.
            if let self, event.window === self.window { self.pictureChanged() }
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard followsPointer else { pointer = nil; return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }

    override func mouseExited(with event: NSEvent) {
        // A stroke goes on past the edge; the ring with it.
        if !editor.brush.isPainting, removePress == nil { pointer = nil }
        noteHover()
        updateRing()
    }

    private func track(_ event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        noteHover()
        updateRing()
    }

    // MARK: The cursor

    private var hasCursorRect = false

    /// A crosshair over the picture while a tool is armed; with Command held the press is the frame
    /// view's, so the grab hand where a drag would pan and otherwise whatever the frame view shows. With no
    /// tool, over the selected gradient's handles only: an open hand on what moves it whole, a crosshair on
    /// the rest. The rect beats the frame view's own pointer style (measured, P0-S2).
    override func resetCursorRects() {
        hasCursorRect = false
        guard followsPointer, let geometry = geometry?() else { return }
        let command = NSEvent.modifierFlags.contains(.command)
        if let frame = removeFrame {
            // The Remove brush's ring is its cursor, as the masks' brush's is; a crosshair while it stands down and no ring shows.
            guard !command || geometry.canPan else { return }
            let standsDown = editor.model?.masksStandDown(frame) ?? false
            addCursor(geometry.toolPicture, command ? .openHand : standsDown ? .crosshair : Self.blankCursor)
            return
        }
        guard editor.isArmed else {
            guard !command, let frame = editor.model?.shownFrame else { return }
            // Option over a pin is an Amount's drag, left and right.
            let option = NSEvent.modifierFlags.contains(.option), reach = MaskHandleModel.hitRadius
            let pins = MaskPinVisibility.isLive(editor.pinInputs(on: frame)) ? editor.pins(on: frame, geometry: geometry) : []
            let pinOnHandle = pins.contains(where: \.isOnHandle)
            if let shape = editor.shapeUnderHandles(in: frame) {
                for (handle, point) in MaskHandleModel.handles(of: shape, in: geometry) {
                    let cursor: NSCursor = handle.movesWhole ? (option && pinOnHandle ? .resizeLeftRight : .openHand) : .crosshair
                    addCursor(CGRect(x: point.x - reach, y: point.y - reach, width: 2 * reach, height: 2 * reach), cursor)
                }
            }
            for pin in pins where !pin.isOnHandle {
                addCursor(CGRect(x: pin.point.x - reach, y: pin.point.y - reach, width: 2 * reach, height: 2 * reach),
                          option ? .resizeLeftRight : .pointingHand)
            }
            return
        }
        guard !command || geometry.canPan else { return }
        // The brush's ring is its cursor, so the system's is blank over the picture; the rect beats the frame view's pointer style
        // (P0-S2). Not while the masks stand down, when no ring shows.
        let standsDown = editor.model.flatMap { model in model.shownFrame.map(model.masksStandDown) } ?? false
        let armed: NSCursor = editor.tool == .brush && !standsDown ? Self.blankCursor : .crosshair
        addCursor(geometry.toolPicture, command ? .openHand : armed)
    }

    /// A cursor with nothing to see, for the brush, whose ring stands in for it. A cursor rect, not `NSCursor.hide()`, whose unbalanced
    /// calls can leave the cursor lost (R7 5.2).
    static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// `rect`'s part of this view, if it has one. A handle zoomed out of the area has none, and the null rectangle
    /// `intersection` gives then is one AppKit throws on, in the display cycle (measured: it took the app down).
    private func addCursor(_ rect: CGRect, _ cursor: NSCursor) {
        let shown = rect.intersection(bounds)
        guard !shown.isNull, !shown.isEmpty else { return }
        addCursorRect(shown, cursor: cursor)
        hasCursorRect = true
    }
}

/// The brush's ring: the outer circle its size, the inner where its feather begins, and a small cross at the centre, a minus for an
/// eraser. Each line is drawn twice, dark under light, so it reads on any picture with no colour of the theme's: the frame stays the
/// only saturated thing on screen. Layers, not SwiftUI: moved inside a transaction with actions off, they land at the next refresh.
@MainActor
final class MaskBrushRing {
    let layer = CALayer()
    private let dark = CAShapeLayer(), light = CAShapeLayer()
    private var drawn: (outer: CGFloat, inner: CGFloat, erase: Bool)?

    /// The light line's width and the dark one's under it, in points.
    static let lineWidth: CGFloat = 1, shadowWidth: CGFloat = 2.5
    /// The centre mark's half length.
    static let markReach: CGFloat = 4

    /// Increase Contrast's hairline as it was last drawn, so a change of the setting redraws the ring and nothing else does.
    private var firm = false

    init() {
        for (shape, colour, width) in [(dark, NSColor.black.withAlphaComponent(MaskOnPicture.hairline(increased: false)), Self.shadowWidth),
                                       (light, NSColor.white.withAlphaComponent(0.95), Self.lineWidth)] {
            shape.fillColor = nil
            shape.strokeColor = colour.cgColor
            shape.lineWidth = width
            layer.addSublayer(shape)
        }
        layer.isHidden = true
        layer.zPosition = 10
    }

    var isShown: Bool { !layer.isHidden }
    var position: CGPoint { layer.position }
    var radii: (outer: CGFloat, inner: CGFloat)? { drawn.map { ($0.outer, $0.inner) } }

    func show(at point: CGPoint, outer: CGFloat, inner: CGFloat, erase: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if increased != firm {
            firm = increased
            dark.strokeColor = NSColor.black.withAlphaComponent(MaskOnPicture.hairline(increased: increased)).cgColor
        }
        if drawn.map({ $0.outer != outer || $0.inner != inner || $0.erase != erase }) ?? true {
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(x: -outer, y: -outer, width: 2 * outer, height: 2 * outer))
            // The feather's circle only where it is apart from the outer one.
            if inner > 0.5, outer - inner > 1.5 { path.addEllipse(in: CGRect(x: -inner, y: -inner, width: 2 * inner, height: 2 * inner)) }
            let reach = Self.markReach
            path.move(to: CGPoint(x: -reach, y: 0)); path.addLine(to: CGPoint(x: reach, y: 0))
            if !erase { path.move(to: CGPoint(x: 0, y: -reach)); path.addLine(to: CGPoint(x: 0, y: reach)) }
            dark.path = path
            light.path = path
            drawn = (outer, inner, erase)
        }
        layer.position = point
        layer.isHidden = false
        CATransaction.commit()
    }

    func hide() {
        guard !layer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
    }
}
