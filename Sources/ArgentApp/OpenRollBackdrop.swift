import AppKit
import Metal
#if DEBUG
import os
#endif
import QuartzCore
import SwiftUI

/// The Latent image behind the Open roll page: the backdrop's motion and renderer on a Metal layer,
/// with the page's column kept clear and its centre's drop and read answered.
///
/// It takes no clicks: the page's empty room still moves the window, and its rows and buttons
/// hover and click as they would without it.
struct OpenRollBackdrop: NSViewRepresentable {
    /// The column of words in the backdrop's points from its top left; nil until measured, and
    /// nothing is drawn until it is.
    var column: CGRect?
    /// The drop zone round the page's centre, in the same coordinates.
    var heroZone: CGRect?
    var hero: RollModel.OpenRollHero
    var reduceMotion: Bool

    func makeNSView(context: Context) -> OpenRollBackdropView { OpenRollBackdropView() }

    func updateNSView(_ view: OpenRollBackdropView, context: Context) {
        // The field is drawn in the theme's colours: a change of theme asks for this update.
        let palette = Graphite.palette
        view.update(column: column, heroZone: heroZone, hero: hero, reduceMotion: reduceMotion, palette: palette)
    }

    static func dismantleNSView(_ view: OpenRollBackdropView, coordinator: ()) {
        view.stop()
    }
}

/// The backdrop's AppKit side: the motion and the renderer, the Metal layer the cells are shown on,
/// the pointer's tracking area, and the display link that steps and draws them.
///
/// The view is flipped, so its points run from the top left as the motion's and the renderer's do.
/// The layer is a whole number of cells from the top left, one texel a cell magnified without
/// filtering, so the cells are crisp squares at any backing scale; where it runs past the view's
/// bounds the view clips it. Without a Metal device, or a renderer, the view stays empty.
final class OpenRollBackdropView: NSView {
    /// The renderer, made once for every backdrop: its source is compiled at run time, which costs
    /// more than a page's appearance should. Nil where Metal cannot draw it.
    private static let sharedRenderer: OpenRollBackdropRenderer? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? OpenRollBackdropRenderer(device: device)
    }()

    private var motion = OpenRollBackdropMotion()
    private let renderer: OpenRollBackdropRenderer?
    private let metalLayer: CAMetalLayer?
    private var tracking: NSTrackingArea?
    private var link: CADisplayLink?
    /// The last tick's timestamp; nil after a pause, so the first tick after it steps by nothing.
    private var lastTimestamp: CFTimeInterval?
    /// The rate the link runs at now, frames a second; 0 while it is paused.
    private var rate = 0
    /// The size the drawable was last made for, in points.
    private var drawnSize: CGSize = .zero

    private var column: CGRect?
    private var heroZone: CGRect?
    private var hero: RollModel.OpenRollHero = .ready
    private var reduceMotion = false
    private var palette: ThemePalette = Graphite.palette
    /// The pointer in the view's points; nil while it is away.
    private var pointer: CGPoint?
    #if DEBUG
    /// The frames drawn and their GPU time over the last second, for the drive hook.
    private let counters = OpenRollBackdropCounters()
    #endif

    override init(frame frameRect: NSRect) {
        renderer = Self.sharedRenderer
        metalLayer = renderer.map { renderer in
            let layer = CAMetalLayer()
            layer.device = renderer.device
            layer.pixelFormat = OpenRollBackdropRenderer.pixelFormat
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.isOpaque = false
            layer.framebufferOnly = true
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            layer.contentsGravity = .resize
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(),
                             "anchorPoint": NSNull(), "contentsScale": NSNull()]
            return layer
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        if let metalLayer { layer?.addSublayer(metalLayer) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Clicks go to the page under the backdrop.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// What the page says, on every update. A change of the column, the zone or the palette is drawn
    /// at once, in the transaction that moves the page, so the clear zone never trails the words as
    /// they scroll; the field's clock is not stepped for it.
    func update(column: CGRect?, heroZone: CGRect?, hero: RollModel.OpenRollHero, reduceMotion: Bool, palette: ThemePalette) {
        let changed = column != self.column || heroZone != self.heroZone || palette != self.palette
        let wasStill = isStill
        let wasReady = isReady
        self.column = column
        self.heroZone = heroZone
        self.hero = hero
        self.reduceMotion = reduceMotion
        self.palette = palette
        let stillChanged = isStill != wasStill
        if stillChanged || isReady != wasReady { updateRate() }
        if isStill {
            if changed || stillChanged || isReady != wasReady { drawStill(inTransaction: true) }
        } else if changed {
            render(inTransaction: true)
        }
    }

    /// Whether the field holds still, as under Reduce Motion.
    private var isStill: Bool {
        #if DEBUG
        if let still = Self.debugStill { return still }
        #endif
        return reduceMotion
    }

    /// The pointer the motion follows: the tracking area's, or in a debug build the drive hook's.
    private var shownPointer: CGPoint? {
        #if DEBUG
        if let hold = Self.debugPointer { return hold.position(at: CACurrentMediaTime()) }
        #endif
        return pointer
    }

    /// The link invalidated and every observer removed: the backdrop stops.
    func stop() {
        link?.invalidate()
        link = nil
        rate = 0
        lastTimestamp = nil
        NotificationCenter.default.removeObserver(self)
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        pointer = nil
    }

    // MARK: The window

    /// Every move stops the backdrop, a move to another parent in the same window too: the move's
    /// other half makes the link and the observers again, and the old link would run on beside the new.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, renderer != nil else { return }
        let center = NotificationCenter.default
        let shown: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification]
        for name in shown + [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            center.addObserver(self, selector: #selector(stateChanged(_:)), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(windowResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        let app: [Notification.Name] = [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                                        NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        for name in app + [NSApplication.didChangeScreenParametersNotification] {
            center.addObserver(self, selector: #selector(stateChanged(_:)), name: name, object: NSApp)
        }
        center.addObserver(self, selector: #selector(powerStateChanged(_:)), name: .NSProcessInfoPowerStateDidChange, object: nil)
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
        metalLayer?.contentsScale = window.backingScaleFactor
        updateTrackingAreas()
        updateRate()
        if isStill { drawStill() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window { metalLayer?.contentsScale = window.backingScaleFactor }
    }

    @objc private func stateChanged(_ notification: Notification) { updateRate() }

    /// Posted on whichever thread changed the power state.
    @objc nonisolated private func powerStateChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateRate() }
    }

    /// The tracking area answers only in the key window: once it is not key, the pointer has left.
    @objc private func windowResignedKey(_ notification: Notification) { pointer = nil }

    /// A pointer that has not moved since the window became key: no event will say where it is.
    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        pointer = bounds.contains(point) ? point : nil
    }

    /// Whether the backdrop shows: in a window that is at least partly visible, not in the Dock,
    /// in an app that is not hidden, with some of the field on a screen.
    private var isShown: Bool {
        guard let window, window.occlusionState.contains(.visible), !window.isMiniaturized, !NSApp.isHidden else { return false }
        let field = window.convertToScreen(convert(bounds, to: nil))
        return Self.isOnScreen(field, screens: NSScreen.screens.map(\.frame))
    }

    /// The least of the field, in points each way, that counts as on a screen.
    nonisolated static let onScreenMinimum: CGFloat = 8

    /// Whether a field at `field` shows on one of `screens`, all in global points. A tiling window
    /// manager hides a window of another workspace by moving it into a screen's corner with a sliver
    /// left on it, which the window's occlusion state still counts as visible; the field is not drawn
    /// for a sliver.
    nonisolated static func isOnScreen(_ field: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { screen in
            let part = screen.intersection(field)
            return !part.isNull && part.width >= onScreenMinimum && part.height >= onScreenMinimum
        }
    }

    /// Whether the backdrop is paced as in the active app, which it is drawn at its full rates for.
    private var isActive: Bool {
        #if DEBUG
        if let active = Self.debugActive { return Self.pacesAsActive(appIsActive: active, hero: hero) }
        #endif
        return Self.pacesAsActive(appIsActive: NSApp.isActive, hero: hero)
    }

    /// A drop over the window counts as the active app: a drag from Finder leaves Finder active,
    /// while the owner watches this window for where the drop will land.
    nonisolated static func pacesAsActive(appIsActive: Bool, hero: RollModel.OpenRollHero) -> Bool {
        appIsActive || hero == .dropTargeted
    }

    /// Whether there is anything to draw: a renderer, a field with room in it, and the column's frame known.
    private var isReady: Bool {
        renderer != nil && column != nil && bounds.width > 0 && bounds.height > 0
    }

    /// Sets the link's rate from what is shown and what moves; at 0 it is paused, and the first tick
    /// after a pause starts the clock again rather than stepping across it.
    private func updateRate() {
        guard let link else { return }
        let next = OpenRollBackdropMotion.framesPerSecond(
            isShown: isShown && isReady, isActive: isActive,
            isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, reduceMotion: isStill, isLively: motion.isLively)
        guard next != rate else { return }
        if rate == 0 { lastTimestamp = nil }
        rate = next
        if let range = Self.frameRateRange(framesPerSecond: next) {
            link.preferredFrameRateRange = range
            link.isPaused = false
        } else {
            link.isPaused = true
        }
    }

    /// The link's range for a rate: up to the rate and preferring it, down to half of it where the
    /// display cannot keep it; nil for 0, which pauses the link.
    nonisolated static func frameRateRange(framesPerSecond: Int) -> CAFrameRateRange? {
        guard framesPerSecond > 0 else { return nil }
        let rate = Float(framesPerSecond)
        return CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard window != nil, renderer != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil) }
    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil) }
    override func mouseExited(with event: NSEvent) { pointer = nil }

    // MARK: Drawing

    /// The Metal layer's frame in the view's points and its drawable's size in texels for a view of
    /// `size`: a whole number of cells from the top left, covering the view, one texel a cell.
    nonisolated static func layerGeometry(for size: CGSize) -> (frame: CGRect, drawableSize: CGSize) {
        let cells = OpenRollBackdropRenderer.cells(for: size)
        let cell = OpenRollBackdropRenderer.cell
        return (CGRect(x: 0, y: 0, width: CGFloat(cells.width) * cell, height: CGFloat(cells.height) * cell),
                CGSize(width: cells.width, height: cells.height))
    }

    override func layout() {
        super.layout()
        guard let metalLayer, bounds.size != drawnSize else { return }
        drawnSize = bounds.size
        let geometry = Self.layerGeometry(for: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = convertToLayer(geometry.frame)
        metalLayer.drawableSize = geometry.drawableSize
        CATransaction.commit()
        // The field may have come onto a screen or left it, or had no room to draw in before.
        updateRate()
        // The drawable of the old size would be stretched until the next tick.
        if isStill { drawStill(inTransaction: true) } else { render(inTransaction: true) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard isReady else { return }
        let dt = lastTimestamp.map { link.timestamp - $0 } ?? 0
        lastTimestamp = link.timestamp
        motion.step(dt: dt, input: input)
        render()
        updateRate()
    }

    private var input: OpenRollBackdropMotion.Input {
        OpenRollBackdropMotion.Input(pointer: shownPointer, hero: hero, reduceMotion: isStill)
    }

    /// The still field of Reduce Motion, drawn once for what has changed.
    private func drawStill(inTransaction: Bool = false) {
        guard isReady else { return }
        motion.step(dt: 0, input: input)
        render(inTransaction: inTransaction)
    }

    /// Draws the motion as it stands into the next drawable, or skips the frame when there is none.
    /// A frame drawn for a new size or a column that has moved is presented in the transaction that
    /// brings the change, so the old drawable is never shown stretched or over the words. A tick's
    /// frame is presented by the GPU when it is done, which keeps the main thread from waiting on it.
    private func render(inTransaction: Bool = false) {
        guard isReady, let renderer, let metalLayer, let column else { return }
        let frame = OpenRollBackdropFrame(size: bounds.size, column: column, heroZone: heroZone, palette: palette, motion: motion)
        metalLayer.presentsWithTransaction = inTransaction
        guard let drawable = metalLayer.nextDrawable() else { return }
        guard let buffer = renderer.draw(frame, to: drawable.texture) else { return }
        #if DEBUG
        counters.noteFrame()
        let counters = counters
        buffer.addCompletedHandler { buffer in
            guard buffer.status == .completed else { return }
            counters.noteGPU(milliseconds: (buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
        }
        #endif
        if inTransaction {
            buffer.commit()
            buffer.waitUntilScheduled()
            drawable.present()
        } else {
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

#if DEBUG
extension OpenRollBackdropView {
    /// Debug builds only: the pointer the drive hook holds every backdrop's at, whatever the real
    /// one does; nil gives it back to the tracking area.
    static var debugPointer: OpenRollBackdropPointerHold?
    /// Debug builds only: the field held still as under Reduce Motion, or let move, whatever the
    /// system's setting; nil gives it back to the setting.
    static var debugStill: Bool?
    /// Debug builds only: the backdrop paced as in the active app, or in the background, whatever
    /// the app is; nil gives it back to the app's state. A script cannot bring the app forward.
    static var debugActive: Bool?

    /// Takes up a change of `debugPointer`, `debugStill` or `debugActive`: the rate they ask for, and the still
    /// field drawn for them.
    func debugHoldsChanged() {
        updateRate()
        if isStill { drawStill() }
    }

    /// One line for the drive hook: whether the backdrop shows, the app is active and the field can
    /// be drawn; the field in points and cells; the link's rate and the display's most; whether the
    /// motion is lively; and over the last second the frames drawn and a frame's GPU time.
    var debugState: String {
        let cells = OpenRollBackdropRenderer.cells(for: bounds.size)
        let counted = counters.lastSecond()
        func ms(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "none" }
        let range = link.map { "\(Int($0.preferredFrameRateRange.minimum))-\(Int($0.preferredFrameRateRange.maximum))" } ?? "none"
        let still = Self.debugStill.map { "held \($0)" } ?? "system \(reduceMotion)"
        let held = Self.debugPointer.map { hold in
            hold.position(at: CACurrentMediaTime()).map { "held \(Int($0.x)),\(Int($0.y))" } ?? "held away"
        } ?? pointer.map { "tracked \(Int($0.x)),\(Int($0.y))" } ?? "away"
        return "shown \(isShown) active \(Self.debugActive.map { "held \($0)" } ?? "\(NSApp.isActive)") ready \(isReady) field \(Int(bounds.width))x\(Int(bounds.height)) pt \(cells.width)x\(cells.height) cells"
            + " rate \(rate) range \(range) paused \(link?.isPaused ?? true) display max \(window?.screen?.maximumFramesPerSecond ?? 0)"
            + " lively \(motion.isLively) intro \(String(format: "%.2f", motion.intro)) still \(still) pointer \(held)"
            + " drawn \(counted.frames)/s total \(counted.total) gpu mean \(ms(counted.mean)) worst \(ms(counted.worst)) ms"
    }
}

/// Debug builds only: a pointer held by the drive hook, at one point or moving along a line from
/// `from` to `to` over `duration` seconds from `start`, then resting at `to`; or held away from
/// the field.
struct OpenRollBackdropPointerHold: Equatable, Sendable {
    var from: CGPoint
    var to: CGPoint
    var start: CFTimeInterval
    var duration: Double
    var isAway = false

    /// A pointer held away from the field, wherever the real one is.
    static let away = OpenRollBackdropPointerHold(from: .zero, to: .zero, start: 0, duration: 0, isAway: true)

    /// A pointer held still at `point`.
    init(at point: CGPoint) {
        self.init(from: point, to: point, start: 0, duration: 0)
    }

    init(from: CGPoint, to: CGPoint, start: CFTimeInterval, duration: Double, isAway: Bool = false) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = duration
        self.isAway = isAway
    }

    /// Where the pointer is at `time`, on the media clock; nil while it is held away.
    func position(at time: CFTimeInterval) -> CGPoint? {
        guard !isAway else { return nil }
        guard duration > 0 else { return to }
        let t = min(max((time - start) / duration, 0), 1)
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }
}

/// Debug builds only: the backdrop's frames drawn and their GPU times, kept for a second. The GPU's
/// come from command buffers' completion handlers, off the main thread, so they are behind a lock.
final class OpenRollBackdropCounters: Sendable {
    private struct Samples: Sendable {
        var total = 0
        var frames: [CFTimeInterval] = []
        var gpu: [(at: CFTimeInterval, milliseconds: Double)] = []
    }

    private let samples = OSAllocatedUnfairLock(initialState: Samples())

    /// A frame handed to the GPU now.
    func noteFrame() {
        let now = CACurrentMediaTime()
        samples.withLock { samples in
            samples.total += 1
            samples.frames.removeAll { now - $0 > 1 }
            samples.frames.append(now)
        }
    }

    /// A frame's time on the GPU, from its command buffer's start to its end.
    func noteGPU(milliseconds: Double) {
        let now = CACurrentMediaTime()
        samples.withLock { samples in
            samples.gpu.removeAll { now - $0.at > 1 }
            samples.gpu.append((now, milliseconds))
        }
    }

    /// The frames drawn in the last second and since the view was made, and the mean and the worst
    /// GPU time of those finished in the last second.
    func lastSecond() -> (frames: Int, total: Int, mean: Double?, worst: Double?) {
        let now = CACurrentMediaTime()
        return samples.withLock { samples in
            let frames = samples.frames.filter { now - $0 <= 1 }.count
            let gpu = samples.gpu.filter { now - $0.at <= 1 }.map(\.milliseconds)
            let mean = gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count)
            return (frames, samples.total, mean, gpu.max())
        }
    }
}
#endif
