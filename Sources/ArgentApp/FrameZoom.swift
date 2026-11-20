import AppKit
import ArgentCore
import SwiftUI

/// How far the frame view is zoomed into its frame, and where: the picture `scale` times its fitted
/// size, its centre `offset` points from the fitted centre. Once a pinch, a scroll or a menu item
/// settles it, the pictures are rendered again at the zoomed size, up to the raw's own pixels, so a
/// settled zoom shows its render one to one as the fitted frame does. Until the render comes, and
/// past the raw's own pixels, the last render is scaled.
struct FrameZoom: Equatable {
    private enum Mode: Equatable {
        case fit
        case zoom
        /// Actual Size follows the native dimensions even when they first arrive after the command.
        case actualSize
        /// The minimum when this pinch began; the picture can spring below it until release.
        case pinching(minimum: CGFloat)
    }

    private var mode: Mode = .fit
    /// A smart zoom selected before the header arrives still has to zoom about its pointer.
    private var pendingSmartAnchor: CGPoint?
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    /// The scale the pictures are rendered for: the settled `scale`, never past the raw's own pixels.
    var renderedScale: CGFloat = 1

    init() {}

    /// Fit follows the available room; an explicit zoom keeps its source-pixel magnification.
    /// Actual Size can have scale 1, or less, without becoming Fit.
    var isFitted: Bool { mode == .fit }
    var isZoomed: Bool { scale > 1 }

    /// What a zoom works within: the frame view's area, the picture's fitted size in it and its
    /// longer side in pixels, the raw's own longer side and the display's scale.
    struct Room: Equatable {
        var area: CGSize
        var fitted: CGSize
        var fitPixels: Int
        var fullPixels: Int
        var displayScale: CGFloat
        /// Until the header arrives, `fullPixels` is only the fitted size as a placeholder.
        var fullPixelsKnown = true

        /// The raw's own pixels one to one on the display's: Actual Size, and smart zoom's.
        var actualScale: CGFloat { CGFloat(max(1, fullPixels)) / CGFloat(max(1, fitPixels)) }
        /// Pinches and menu steps reach the smaller of Fit and Actual Size.
        var minimumScale: CGFloat { min(1, actualScale) }
        /// Four times Actual Size, near enough to count pixels, with Fit always available.
        var maximumScale: CGFloat { max(1, 4 * actualScale) }
    }

    /// View > Zoom In, Zoom Out, Actual Size and Zoom to Fit.
    enum Step: Equatable { case zoomIn, zoomOut, actualSize, fit }

    /// How far a pinch may take the picture below fitting, to spring back from.
    static let pinchFloor: CGFloat = 0.8

    /// The longer side of the raw at `url` as a full-size decode gives it: its header's crop, less
    /// the trim of a mode Apple's decoder runs past its valid data (`RawMode.filled`), or a full-frame
    /// a7 IV's when the header cannot be read.
    static func fullPixels(of url: URL) -> Int {
        guard let layout = try? ARWLayout.read(from: url) else { return 7008 }
        if let picture = BodyProfile.named(layout.model)?.mode(for: layout)?.filled(for: layout, longSide: .max) {
            return max(picture.width, picture.height)
        }
        return max(layout.cropSize.width, layout.cropSize.height)
    }

    /// The render's requested longer side: the fitted picture's at `renderedScale`. Settled zooms
    /// stop at the raw's own pixels; Fit can request a larger size and the view scales the raw to fit.
    func pixels(in room: Room) -> Int {
        max(1, Int((CGFloat(room.fitPixels) * renderedScale).rounded()))
    }

    /// Zoomed to `scale`, with the point of the picture under `anchor` kept there. A pinch's `floor`
    /// is a fraction of its starting minimum, allowing a little spring below it until settlement.
    func zoomed(to scale: CGFloat, around anchor: CGPoint, in room: Room, floor: CGFloat? = nil) -> FrameZoom {
        var zoom = self
        zoom.pendingSmartAnchor = nil
        let minimum: CGFloat
        if let floor {
            if case .pinching(let startingMinimum) = mode { minimum = startingMinimum }
            else { minimum = min(room.minimumScale, self.scale) }
            zoom.mode = .pinching(minimum: minimum)
            zoom.scale = min(max(scale, minimum * floor), room.maximumScale)
        } else {
            zoom.mode = .zoom
            zoom.scale = min(max(scale, room.minimumScale), room.maximumScale)
        }
        let ratio = zoom.scale / self.scale
        let x = anchor.x - room.area.width / 2, y = anchor.y - room.area.height / 2
        zoom.offset = CGSize(width: x - (x - offset.width) * ratio, height: y - (y - offset.height) * ratio)
        return zoom.clamped(in: room)
    }

    func panned(by delta: CGSize, in room: Room) -> FrameZoom {
        var zoom = self
        zoom.offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        return zoom.clamped(in: room)
    }

    /// Kept over the area: along a side where the picture is larger than the area it covers it, and
    /// along one where it is smaller it is centred.
    func clamped(in room: Room) -> FrameZoom {
        func clamp(_ offset: CGFloat, _ fitted: CGFloat, _ area: CGFloat) -> CGFloat {
            let reach = max(0, (fitted * scale - area) / 2)
            return min(max(offset, -reach), reach)
        }
        var zoom = self
        zoom.offset = CGSize(width: clamp(offset.width, room.fitted.width, room.area.width),
                             height: clamp(offset.height, room.fitted.height, room.area.height))
        return zoom
    }

    /// At rest: rendered for its scale and moved on whole device pixels. A released pinch springs
    /// back to its minimum. Other explicit zooms may be below Fit after a room change, and stay there.
    /// Up to Actual Size the scale moves the fraction of a pixel to its render's own.
    func settled(in room: Room) -> FrameZoom {
        if isFitted { return FrameZoom() }
        var zoom = self
        var minimum = 1 / CGFloat(max(1, room.fitPixels))
        if case .pinching(let startingMinimum) = mode {
            if startingMinimum == 1, scale <= 1 { return FrameZoom() }
            minimum = max(minimum, startingMinimum)
        }
        zoom.mode = .zoom
        zoom.scale = mode == .actualSize ? room.actualScale : min(max(scale, minimum), room.maximumScale)
        zoom.renderedScale = min(zoom.scale, room.actualScale)
        zoom.renderedScale = CGFloat(zoom.pixels(in: room)) / CGFloat(room.fitPixels)
        if zoom.scale <= room.actualScale { zoom.scale = zoom.renderedScale }
        if zoom.scale == room.actualScale { zoom.mode = .actualSize }
        zoom = zoom.clamped(in: room)
        // Toward the centre, so a picture covering the area still does.
        func whole(_ value: CGFloat) -> CGFloat { (value * room.displayScale).rounded(.towardZero) / room.displayScale }
        zoom.offset = CGSize(width: whole(zoom.offset.width), height: whole(zoom.offset.height))
        return zoom
    }

    /// Keeps an explicit zoom's device pixels per source pixel and the subject under the area's
    /// centre when a resize, inspector or display changes the room. Fit continues to fill the room.
    /// Actual Size follows the native size when its header arrives; an ordinary zoom keeps its
    /// displayed size instead. A live pinch remains live, using its existing render until release.
    func reframed(from previous: Room, to room: Room) -> FrameZoom {
        if previous == room { return self }
        if isFitted { return FrameZoom() }
        var zoom = self
        let fitRatio = CGFloat(previous.fitPixels) / CGFloat(room.fitPixels)
        zoom.scale = mode == .actualSize ? room.actualScale : scale * fitRatio
        let oldWidth = previous.fitted.width * scale, oldHeight = previous.fitted.height * scale
        zoom.offset = CGSize(width: oldWidth > 0 ? offset.width * (room.fitted.width * zoom.scale / oldWidth) : 0,
                             height: oldHeight > 0 ? offset.height * (room.fitted.height * zoom.scale / oldHeight) : 0)
        if let anchor = pendingSmartAnchor, room.fullPixelsKnown {
            let x = anchor.x - previous.area.width / 2, y = anchor.y - previous.area.height / 2
            zoom.offset = CGSize(width: anchor.x - room.area.width / 2 - (x - offset.width) * (room.fitted.width * zoom.scale / oldWidth),
                                 height: anchor.y - room.area.height / 2 - (y - offset.height) * (room.fitted.height * zoom.scale / oldHeight))
            zoom.pendingSmartAnchor = nil
        }
        if case .pinching(let minimum) = mode {
            zoom.mode = .pinching(minimum: min(minimum * fitRatio, room.minimumScale))
            zoom.renderedScale = renderedScale * fitRatio
            if zoom.scale > room.maximumScale {
                let ratio = room.maximumScale / zoom.scale
                zoom.scale = room.maximumScale
                zoom.offset = CGSize(width: zoom.offset.width * ratio, height: zoom.offset.height * ratio)
            }
            return zoom.clamped(in: room)
        }
        return zoom.settled(in: room)
    }

    /// The scales Zoom In and Zoom Out step through: fitting, then an eighth of Actual Size to four
    /// times it, doubling.
    static func levels(in room: Room) -> [CGFloat] {
        let native = [0.125, 0.25, 0.5, 1, 2, 4].map { $0 * room.actualScale }
            .filter { $0 >= room.minimumScale && $0 <= room.maximumScale }
        return Array(Set([CGFloat(1)] + native)).sorted()
    }

    /// A menu item's zoom, about the middle of the area.
    func stepped(_ step: Step, in room: Room) -> FrameZoom {
        let target: CGFloat
        switch step {
        case .fit: return FrameZoom()
        case .actualSize: target = room.actualScale
        case .zoomIn: target = Self.levels(in: room).first { $0 > scale * 1.01 } ?? room.maximumScale
        case .zoomOut:
            guard let smaller = Self.levels(in: room).last(where: { $0 < scale / 1.01 }) else { return self }
            target = smaller
        }
        if target == 1, step != .actualSize { return FrameZoom() }
        let middle = CGPoint(x: room.area.width / 2, y: room.area.height / 2)
        var zoom = zoomed(to: target, around: middle, in: room)
        if target == room.actualScale { zoom.mode = .actualSize }
        return zoom.settled(in: room)
    }

    /// Smart zoom, a double tap with two fingers: a zoomed frame fits again, and a fitted one goes
    /// to Actual Size about the pointer, or to twice its size when Fit already shows the raw's own.
    func toggled(around anchor: CGPoint, in room: Room) -> FrameZoom {
        if !isFitted { return FrameZoom() }
        let target = room.fullPixelsKnown && room.actualScale == 1 ? 2 : room.actualScale
        var zoom = zoomed(to: target, around: anchor, in: room)
        if target == room.actualScale { zoom.mode = .actualSize }
        if !room.fullPixelsKnown { zoom.pendingSmartAnchor = anchor }
        return zoom.settled(in: room)
    }

    /// Actual Size about `anchor`, a point in the frame view's area, kept where it is: View > Actual Size (`stepped(.actualSize, in:)`)
    /// zooms about the area's middle, and smart zoom about the pointer, but goes back to Fit from a zoomed frame and past Actual Size
    /// where Fit already shows the raw's own pixels. Already at Actual Size, nothing moves.
    func actualSize(around anchor: CGPoint, in room: Room) -> FrameZoom {
        zoomed(to: room.actualScale, around: anchor, in: room).settled(in: room)
    }
}

extension RollModel {
    /// A zoom comes to rest on a spring, so one begun before the last has settled goes on from where the picture is.
    private var zoomAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Graphite.Motion.settle
    }

    func zoomFrame(_ step: FrameZoom.Step) {
        guard let room = frameZoomRoom else { return }
        withAnimation(zoomAnimation) { frameZoom = frameZoom.stepped(step, in: room) }
    }

    /// A pinch, `magnification` more than the last event's, about the pointer; the picture follows the
    /// fingers, a little below fitting too, and settles once they lift.
    func pinchFrame(by magnification: CGFloat, at anchor: CGPoint, ended: Bool) {
        guard let room = frameZoomRoom else { return }
        if magnification != 0 {
            frameZoom = frameZoom.zoomed(to: frameZoom.scale * (1 + magnification), around: anchor, in: room,
                                         floor: FrameZoom.pinchFloor)
        }
        if ended { withAnimation(zoomAnimation) { frameZoom = frameZoom.settled(in: room) } }
    }

    func smartZoomFrame(at anchor: CGPoint) {
        guard let room = frameZoomRoom else { return }
        withAnimation(zoomAnimation) { frameZoom = frameZoom.toggled(around: anchor, in: room) }
    }

    /// The photograph's menu's Actual Size: View > Actual Size, about `anchor`, where the menu was opened.
    func zoomFrame(toActualSizeAt anchor: CGPoint) {
        guard let room = frameZoomRoom else { return }
        withAnimation(zoomAnimation) { frameZoom = frameZoom.actualSize(around: anchor, in: room) }
    }

    /// Moves a zoomed picture with a scroll or a drag; `false`, leaving the event to others, for a fitted one.
    @discardableResult
    func panFrame(by delta: CGSize, ended: Bool) -> Bool {
        guard let room = frameZoomRoom, frameZoom.isZoomed else { return false }
        frameZoom = frameZoom.panned(by: delta, in: room)
        if ended { frameZoom = frameZoom.settled(in: room) }
        return true
    }
}

/// The trackpad's pinch, smart zoom and two-finger scroll over the frame view. SwiftUI offers no
/// gesture for the last two, so a view behind the frame that takes no clicks watches its window's
/// events and hands on those over it, with their locations in its own space from the top left.
struct TrackpadEvents: NSViewRepresentable {
    /// The pinch's magnification since its last event, where, and whether the fingers lifted.
    var magnify: (CGFloat, CGPoint, Bool) -> Void
    var smartMagnify: (CGPoint) -> Void
    /// A scroll's movement in points and whether it ended; `false` when it was not used, so it
    /// goes on to the views under the pointer.
    var scroll: (CGSize, Bool) -> Bool

    func makeNSView(context: Context) -> EventView { EventView() }

    func updateNSView(_ view: EventView, context: Context) { view.events = self }

    final class EventView: NSView {
        var events: TrackpadEvents?
        private var monitor: Any?
        /// A pinch or scroll that began over the view, followed to its end wherever the pointer goes.
        private var pinching = false
        private var scrolling = false

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify, .scrollWheel]) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        /// Whether `event` was used.
        private func handle(_ event: NSEvent) -> Bool {
            guard let events, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
            let location = convert(event.locationInWindow, from: nil)
            let over = bounds.contains(location)
            switch event.type {
            case .magnify:
                guard over || pinching else { return false }
                let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
                pinching = !ended
                events.magnify(event.magnification, location, ended)
                return true
            case .smartMagnify:
                guard over else { return false }
                events.smartMagnify(location)
                return true
            case .scrollWheel:
                guard over || scrolling else { return false }
                // A wheel's notches come as lines, a trackpad's movement as points.
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                let phases = event.phase.union(event.momentumPhase)
                let ended = phases.isEmpty || event.momentumPhase.contains(.ended) || phases.contains(.cancelled)
                    || (event.phase.contains(.ended) && event.momentumPhase.isEmpty)
                let used = events.scroll(CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step), ended)
                scrolling = used && !ended
                return used
            default:
                return false
            }
        }
    }
}
