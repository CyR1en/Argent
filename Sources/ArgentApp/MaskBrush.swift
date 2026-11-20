import AppKit
import ArgentCore
import ArgentRoll
import CoreGraphics
import Observation
import os
import QuartzCore

// MARK: - Settings

/// The brush as the panel shows it and the keys step it. Size is the brush's diameter in hundredths of the picture's long side, so
/// the ring grows with the zoom as the picture does (R7 4.4) and a size reads as the gradients' numbers do (T6). Feather is the
/// share of the radius its edge falls over, and Flow how much one stroke lays down (`BrushCompositing`: one pass of Flow 50 reaches
/// half), both 0 to 100. Erase is the panel's: every stroke erases, as Option held at the press makes one stroke do. Follow edges (A)
/// keeps each stroke to the colour under the brush's centre and snaps it to the picture's edges as it ends (`FollowEdgesModel`). Pure,
/// so `MaskBrushTests` holds its steps.
struct MaskBrushSettings: Equatable, Sendable {
    /// A radius of 0.001 to 0.2 long sides (`MaskSpace.brushRadiusRange`), as a diameter in hundredths.
    static let sizeRange: ClosedRange<Float> = 0.2...40
    static let featherRange: ClosedRange<Float> = 0...100
    /// Flow 0 would paint nothing.
    static let flowRange: ClosedRange<Float> = 1...100
    /// ] and [: a quarter larger and a fifth smaller, so the pair comes back where it began (P0-S2's prototype), and never less than
    /// a step of Size's own, so the smallest brush still grows.
    static let sizeFactor: Float = 1.25
    static let sizeStep: Float = 0.1
    /// ⇧] and ⇧[ (P0-S2's prototype: a tenth of the range).
    static let featherStep: Float = 10
    /// What a new brush starts as. Flow 100, not R7's 50: R7 chose 50 when Flow was laid per dab, where one pass of 50 all but
    /// filled a stroke's core; per stroke (E) one pass of 50 leaves half, and a Subtract brush repairing a Sky mask should take it
    /// away in one pass. Size 6, about a 420-pixel brush on a 7008-pixel frame, and Feather 50 are Lightroom-like starting points
    /// (inference; Lightroom's own were not measured).
    static let standard = MaskBrushSettings(size: 6, feather: 50, flow: 100)

    var size: Float
    var feather: Float
    var flow: Float
    var erase = false
    var followEdges = false

    /// The radius in long sides, inside the engine's range.
    var radius: Float {
        min(MaskSpace.brushRadiusRange.upperBound, max(MaskSpace.brushRadiusRange.lowerBound, size / 200))
    }

    /// What a stroke paints with: `option` is Option held at its press, which turns the panel's choice over for that stroke.
    func engine(option: Bool) -> BrushSettings {
        BrushSettings(radius: radius, feather: min(1, max(0, feather / 100)), flow: min(1, max(0.01, flow / 100)), erase: erase != option,
                      followEdges: followEdges)
    }

    /// The dab's two circles, as the ring draws them, in long sides.
    var profile: BrushDabProfile { BrushDabProfile(radius: radius, feather: min(1, max(0, feather / 100))) }

    private static func snappedSize(_ value: Float) -> Float {
        min(sizeRange.upperBound, max(sizeRange.lowerBound, (value / sizeStep).rounded() * sizeStep))
    }

    /// ].
    func larger() -> MaskBrushSettings {
        var next = self
        next.size = Self.snappedSize(max(size * Self.sizeFactor, size + Self.sizeStep))
        return next
    }

    /// [.
    func smaller() -> MaskBrushSettings {
        var next = self
        next.size = Self.snappedSize(min(size / Self.sizeFactor, size - Self.sizeStep))
        return next
    }

    /// ⇧] and ⇧[.
    func feathered(by steps: Int) -> MaskBrushSettings {
        var next = self
        next.feather = min(Self.featherRange.upperBound, max(Self.featherRange.lowerBound, feather + Float(steps) * Self.featherStep))
        return next
    }

    /// Lightroom's digits: 1 is Flow 10 and so on, 0 is Flow 100.
    func flow(digit: Int) -> MaskBrushSettings {
        var next = self
        next.flow = digit == 0 ? 100 : Float(min(9, max(1, digit)) * 10)
        return next
    }

    // Kept across launches, as the overlay's colour is (R7 6.1), Follow edges with them as Lightroom keeps Auto Mask with its brush
    // (R7); Erase is not, so a new session never starts erasing unseen.
    static let sizeKey = "maskBrushSize", featherKey = "maskBrushFeather", flowKey = "maskBrushFlow", followEdgesKey = "maskBrushFollowEdges"

    init(size: Float, feather: Float, flow: Float, erase: Bool = false, followEdges: Bool = false) {
        self.size = size; self.feather = feather; self.flow = flow; self.erase = erase; self.followEdges = followEdges
    }

    /// The settings `defaults` keep, each inside its range, the standard ones where none is kept.
    init(defaults: UserDefaults) {
        func read(_ key: String, _ range: ClosedRange<Float>, _ standard: Float) -> Float {
            guard let value = defaults.object(forKey: key) as? NSNumber, value.floatValue.isFinite else { return standard }
            return min(range.upperBound, max(range.lowerBound, value.floatValue))
        }
        self.init(size: read(Self.sizeKey, Self.sizeRange, Self.standard.size),
                  feather: read(Self.featherKey, Self.featherRange, Self.standard.feather),
                  flow: read(Self.flowKey, Self.flowRange, Self.standard.flow),
                  followEdges: defaults.bool(forKey: Self.followEdgesKey))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(size, forKey: Self.sizeKey)
        defaults.set(feather, forKey: Self.featherKey)
        defaults.set(flow, forKey: Self.flowKey)
        defaults.set(followEdges, forKey: Self.followEdgesKey)
    }
}

extension AdjustmentSliderSpec {
    /// The brush's three, in their own group, so . and , stay among them.
    static let brushSize = AdjustmentSliderSpec(title: "Size", range: MaskBrushSettings.sizeRange, step: MaskBrushSettings.sizeStep,
                                                defaultValue: MaskBrushSettings.standard.size, polarity: .unipolar, arrowStep: 0.1,
                                                smallKeyStep: 1, largeKeyStep: 5, fractionDigits: 1, group: .brush, order: 0)
    static let brushFeather = AdjustmentSliderSpec(title: "Feather", range: MaskBrushSettings.featherRange, step: 1,
                                                   defaultValue: MaskBrushSettings.standard.feather, polarity: .unipolar, arrowStep: 1,
                                                   smallKeyStep: 5, largeKeyStep: 20, group: .brush, order: 1)
    static let brushFlow = AdjustmentSliderSpec(title: "Flow", range: MaskBrushSettings.flowRange, step: 1,
                                                defaultValue: MaskBrushSettings.standard.flow, polarity: .unipolar, arrowStep: 1,
                                                smallKeyStep: 5, largeKeyStep: 20, group: .brush, order: 2)
}

// MARK: - The stroke

/// Where a stroke's canvas comes from: in the app the previews' own GPU, whose field cache the print reads (`FilmPreviews`); in a test,
/// a GPU of the test's own.
protocol MaskBrushCanvasSource: AnyObject {
    func brushPicture(for frame: Frame, lens: LensSettings) -> (picture: MaskSpace, frame: MaskFrame)?
    /// Asks for a decode of `frame`, if none is held, for the next press (`FilmPreviews.wantFrameDecode`).
    func wantFrameDecode(_ frame: Frame, lens: LensSettings, pixels: Int)
    func brushStrokeSession(frame: Frame, lens: LensSettings, picture: MaskSpace, mask: Mask, component: Int, settings: BrushSettings,
                            constraint: StrokeSampler.Constraint) throws -> BrushStrokeSession
}

extension FilmPreviews: MaskBrushCanvasSource {}

/// A stroke's session on a queue of its own. Every call into the session waits for the GPU, which the print's renders keep busy: driven
/// from the main thread, a stroke spent 2.1 to 2.3 s of every 8 waiting there, and lost three times the refreshes a Light slider's drag
/// did at fit (measured, G). The press and the release wait for the lane, so a stroke still begins and lands as one step in its own
/// turn, and an Undo, Escape or the next press find the edit settled; the ticks, the overlay's reads and the print's snapshots between
/// them do not hold up the main thread. The session is driven by one thread at a time, as it asks. A test runs the lane inline.
final class MaskBrushLane: @unchecked Sendable {
    private static let log = Logger(subsystem: "camera.argent.Argent", category: "masks")
    private let queue: DispatchQueue?
    private let session: BrushStrokeSession
    /// Where a Follow edges stroke's measured shape is kept (`MaskRasterStore`), flushed before the edit names it.
    private let shapes: MaskRasterStore?
    // Touched on the lane only, or by `sync` once it has drained.
    private var overlay: CGContext?
    private var ticks: [Double] = []
    private var waits = (tick: 0.0, overlay: 0.0, print: 0.0)

    init(session: BrushStrokeSession, inline: Bool, shapes: MaskRasterStore? = nil) {
        self.session = session
        self.shapes = shapes
        queue = inline ? nil : DispatchQueue(label: "camera.argent.brush-stroke", qos: .userInteractive)
    }

    var isInline: Bool { queue == nil }

    /// `body` on the lane after what is queued before it; at once, inline.
    func async(_ body: @escaping @Sendable (MaskBrushLane) -> Void) {
        guard let queue else { return body(self) }
        queue.async { body(self) }
    }

    /// Waits for what is queued, then runs `body` on the lane.
    func sync<T>(_ body: (MaskBrushLane) throws -> T) rethrows -> T {
        guard let queue else { return try body(self) }
        return try queue.sync { try body(self) }
    }

    /// The mask with `stroke` on the session's component: from what the session was made with, which nothing changes.
    func mask(with stroke: BrushStroke) -> Mask { session.mask(with: stroke) }

    // MARK: On the lane

    func add(_ point: MaskPoint) {
        let began = CACurrentMediaTime()
        defer { waits.tick += CACurrentMediaTime() - began }
        do {
            try session.add(point)
            ticks.append(session.lastTickSeconds)
        } catch {
            Self.log.error("brush tick failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The mask's coverage from the stroke's canvas, the part that changed written into one alpha-only bitmap, as a picture; nil when
    /// nothing changed since the last, unless `always`. A picture made before keeps its pixels: `makeImage` copies the pages written
    /// after it (measured).
    func overlayImage(always: Bool = false) -> CGImage? {
        let began = CACurrentMediaTime()
        defer { waits.overlay += CACurrentMediaTime() - began }
        if overlay == nil {
            overlay = CGContext(data: nil, width: session.size.width, height: session.size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        }
        guard let context = overlay, let data = context.data else { return nil }
        do {
            guard try session.overlay(into: data, bytesPerRow: context.bytesPerRow) != nil || always else { return nil }
        } catch {
            Self.log.error("brush overlay failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return context.makeImage()
    }

    func snapshot() -> Mask? {
        let began = CACurrentMediaTime()
        defer { waits.print += CACurrentMediaTime() - began }
        do { return try session.printSnapshot() } catch {
            Self.log.error("brush snapshot failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The recipe's stroke, or nil with no point, and the overlay's last picture: the canvas the print now reads. A Follow edges stroke's
    /// measured shape is stored here first, on the lane, so the edit that names it is never saved before it is on the disk (as a smart
    /// mask's seed is: `RollModel.storeMaskSeed`).
    func end() throws -> (stroke: BrushStroke?, image: CGImage?) {
        guard let stroke = try session.end() else { return (nil, nil) }
        if let measured = session.measurement {
            guard let shapes else { throw MaskRasterStore.Failure.unwritable("no library to keep it in") }
            try shapes.store(measured.raster)
        }
        return (stroke, overlayImage(always: true))
    }

    /// What measuring a Follow edges stroke cost at its release, and its refinement's GPU time; 0 for any other stroke.
    var measureSeconds: (whole: Double, refinement: Double) { (session.measureSeconds, session.measurement?.build.gpuSeconds ?? 0) }

    func cancel() { session.cancel() }

    /// What the lane did, for the stroke's report.
    var report: (ticks: [Double], waits: (tick: Double, overlay: Double, print: Double)) { (ticks, waits) }
}

/// The brush in hand: its settings, the brush component its strokes go to, and the stroke under way, from the press to the release.
///
/// A stroke runs through E's `BrushStrokeSession` on the previews' own GPU, so the canvas it paints is the one the print reads, on a
/// lane of its own (`MaskBrushLane`). Each event's dabs are laid at once; the overlay shows the mask's coverage from that canvas at most
/// every second refresh (P0-S2), written only where it changed into one alpha-only bitmap; the print takes the stroke so far at most
/// `MaskEditor.flushInterval` apart, as often as it can be printed, through `MaskEditor.printed`, so the edit and everything
/// that reads it change once, on the release, as one undo step. A brush mask is pending until its first stroke, which makes it (R7 6.1),
/// and an undo of that stroke leaves the brush in hand with the mask pending again (plan section 5, unlike Lightroom).
@MainActor @Observable
final class MaskBrush {
    private static let log = Logger(subsystem: "camera.argent.Argent", category: "masks")

    /// A stroke from its press to its release.
    final class Stroke {
        let frame: Frame
        /// The brush component painted.
        let target: MaskEditor.Selection
        let component: Int
        let erase: Bool
        /// The press made the mask or the component, so cancelling the stroke takes it away again.
        let made: Bool
        let selectionBefore: MaskEditor.Selection?
        let picture: MaskSpace
        let settings: BrushSettings
        var lane: MaskBrushLane?
        /// A Shift press after a stroke waits to see which it is: let go where it was pressed, a line from the last stroke's end; moved,
        /// a stroke held to the horizontal or the vertical.
        var heldShift: (point: CGPoint, at: MaskPoint, from: MaskPoint)?
        var lastPublish: CFTimeInterval = -.infinity
        var lastFlush: CFTimeInterval = -.infinity
        var unpublished = false
        var unflushed = false
        /// An overlay read or a print snapshot is on the lane: the next waits for it, so none queue behind a slow GPU.
        var overlayInFlight = false
        var printInFlight = false
        /// The pointer's events, by their own times: the stroke's report.
        var eventTimes: [TimeInterval] = []
        /// How long the release waited for the lane.
        var landing: Double = 0
        var publishes = 0
        var flushes = 0
        /// When each flush reached the print, and how long after the newest flush its request saw each film went up: the print's lag
        /// behind the stroke, which the ring and the overlay do not have.
        var flushTimes: [CFTimeInterval] = []
        var printLags: [Double] = []
        /// What the press cost on the main thread: making the mask or component in the edit, and the stroke's session.
        var pressShape: Double = 0
        var pressSession: Double = 0

        init(frame: Frame, target: MaskEditor.Selection, erase: Bool, made: Bool, selectionBefore: MaskEditor.Selection?,
             picture: MaskSpace, settings: BrushSettings) {
            self.frame = frame; self.target = target; component = target.component ?? 0; self.erase = erase; self.made = made
            self.selectionBefore = selectionBefore; self.picture = picture; self.settings = settings
        }
    }

    /// How far a Shift press moves before it is a drag, as a gradient's press (`MaskHandleModel.dragThreshold`).
    static let shiftDragThreshold: CGFloat = MaskHandleModel.dragThreshold

    var settings: MaskBrushSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            editor?.canvas?.brushChanged()
        }
    }
    /// The brush component the strokes go to once the first has made it, or the one ⇧K or ⌥K took up. None while the brush waits for
    /// its first stroke; one that has gone, by an undo or a delete, is pending again (`target(on:)`).
    var target: MaskEditor.Selection?
    private(set) var stroke: Stroke?
    /// The last stroke's report, for the drive hook and the log: its events and what they cost.
    @ObservationIgnored private(set) var lastReport = "no stroke"
    /// Why the last press painted nothing, if it did not.
    @ObservationIgnored private(set) var lastRefusal: String?
    /// For the tests and the drive hook, in every build: strokes ended, cancelled and refused.
    @ObservationIgnored private(set) var counts = (ended: 0, cancelled: 0, refused: 0)

    @ObservationIgnored weak var editor: MaskEditor?
    /// The canvases' source in place of the model's previews, for a test.
    @ObservationIgnored var source: (any MaskBrushCanvasSource)?
    @ObservationIgnored var clock: () -> CFTimeInterval = CACurrentMediaTime
    /// Runs each stroke's lane on the caller's thread, for a test, whose events and expectations take turns.
    @ObservationIgnored var runsInline = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var followUp: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = MaskBrushSettings(defaults: defaults)
    }

    var isPainting: Bool { stroke != nil }

    /// A stroke under way that made its mask (component 0) or component at its press, and the selection before it.
    struct Making: Equatable {
        var target: MaskEditor.Selection
        var before: MaskEditor.Selection?
        var frame: URL
    }

    /// The Masks tab shows what a stroke made only once the stroke lands, keeping the pending row in its place meanwhile: built at the
    /// press, the new row and the selected mask's panel cost the stroke's first refreshes 95 to 106 ms for a mask and 63 to 68 for a
    /// component, against 8 to 24 for a stroke into a brush that was there (H, measured on the drag roll at fit; G saw 64 to 121).
    /// Set by a press that makes, cleared as its stroke lands or goes, and by nothing else, so a stroke into a brush that was there
    /// leaves the tab alone.
    private(set) var making: Making?

    /// What the Masks tab shows of `mask` while a stroke is under way: without the component the stroke is making.
    func shown(_ mask: Mask) -> Mask {
        guard let making, making.target.mask == mask.id, let index = making.target.component, index > 0,
              mask.components.indices.contains(index) else { return mask }
        var held = mask
        held.components.remove(at: index)
        return held
    }

    /// The brush component strokes go to on `frame`, if it is still there.
    func target(on frame: Frame, model: RollModel) -> MaskEditor.Selection? {
        guard let target, let mask = model.mask(target.mask, for: frame), let index = target.component,
              mask.components.indices.contains(index), case .brush = mask.components[index].shape else { return nil }
        return target
    }

    /// Taken up again for a new mask, or for a component of the selected mask: ⇧K and ⌥K on a selected brush component of their own
    /// operation go on painting it.
    func takeUp(operation: MaskOperation?, model: RollModel, frame: Frame) {
        target = nil
        guard let operation, let selection = editor?.selection, let index = selection.component,
              let component = model.mask(selection.mask, for: frame)?.components[safe: index],
              case .brush = component.shape, component.operation == operation || index == 0 && operation == .add else { return }
        target = selection
    }

    // MARK: The press

    func press(_ event: MaskCanvasEvent) {
        lastRefusal = nil
        guard let editor, let model = editor.model, let frame = model.shownFrame, let geometry = editor.canvas?.geometry?(),
              !model.masksStandDown(frame) else { return refuse("the masks stand down") }
        guard let films = source ?? model.films, let held = films.brushPicture(for: frame, lens: editor.pictureLens(on: frame)?.settings ?? model.lensSettings(for: frame)) else {
            // A frame seen earlier can show its film with no decode held; it is made again for the next press, as the frame view's own would be.
            if let pixels = model.frameLayout?.pixels(frame) ?? Self.pixels(of: geometry) {
                (source ?? model.films)?.wantFrameDecode(frame, lens: editor.pictureLens(on: frame)?.settings ?? model.lensSettings(for: frame), pixels: pixels)
            }
            return refuse("the frame's picture is not ready")
        }
        let point = geometry.maskPoint(event.point)
        let pressed = CACurrentMediaTime()
        let option = event.modifiers.contains(.option), engine = settings.engine(option: option)
        // Where it paints: the brush it has painted, or a new mask or component, made now in the stroke's own gesture.
        let made: Bool, target: MaskEditor.Selection
        let selectionBefore = editor.selection
        if let existing = self.target(on: frame, model: model) {
            model.beginManualGesture(for: frame)
            model.moveMaskToPicture(existing.mask, for: frame)
            guard let shape = model.mask(existing.mask, for: frame)?.components[existing.component ?? 0].shape,
                  editor.lens(on: frame)?.toPicture(shape) == nil else {
                model.cancelManualGesture(for: frame)
                return refuse("this brush’s measured shapes cannot be read")
            }
            target = existing
            made = false
        } else {
            let shape = MaskShape.brush(BrushPaint(frame: held.frame))
            guard let drawn = model.beginDrawnShape(shape, tool: .brush, operation: editor.pendingOperation, for: frame) else {
                return refuse("the frame cannot take this mask")
            }
            target = MaskEditor.Selection(mask: drawn.mask, component: drawn.component ?? 0)
            editor.selection = drawn
            made = true
        }
        let stroke = Stroke(frame: frame, target: target, erase: engine.erase, made: made, selectionBefore: selectionBefore,
                            picture: held.picture, settings: engine)
        stroke.pressShape = CACurrentMediaTime() - pressed
        stroke.eventTimes.append(event.time)
        // Shift: a line from the last stroke's end, or with none, a stroke held to an axis.
        let last = lastPoint(of: target, on: frame, model: model)
        if made { making = Making(target: target, before: selectionBefore, frame: frame.url) }
        if event.modifiers.contains(.shift), let last {
            stroke.heldShift = (event.point, point, last)
            self.stroke = stroke
            self.target = target
            return
        }
        let starting = CACurrentMediaTime()
        guard start(stroke, constraint: event.modifiers.contains(.shift) ? .axis : .none, model: model) else { return }
        stroke.pressSession = CACurrentMediaTime() - starting
        self.target = target
        self.stroke = stroke
        add(point, to: stroke)
    }

    /// The frame view's long side in pixels, for a decode, when no layout has said it.
    private static func pixels(of geometry: FrameGeometry) -> Int? {
        geometry.longSide > 0 ? Int(geometry.longSide * geometry.displayScale) : nil
    }

    func drag(_ event: MaskCanvasEvent) {
        guard let stroke, let editor, let model = editor.model, let geometry = editor.canvas?.geometry?() else { return }
        stroke.eventTimes.append(event.time)
        guard !model.masksStandDown(stroke.frame) else { return }
        if let held = stroke.heldShift {
            guard hypot(event.point.x - held.point.x, event.point.y - held.point.y) >= Self.shiftDragThreshold else { return }
            stroke.heldShift = nil
            guard start(stroke, constraint: .axis, model: model) else { return }
            add(held.at, to: stroke)
        }
        add(geometry.maskPoint(event.point), to: stroke)
    }

    func release(_ event: MaskCanvasEvent) {
        guard let stroke else { return }
        if let held = stroke.heldShift, let model = editor?.model {
            stroke.heldShift = nil
            stroke.eventTimes.append(event.time)
            guard start(stroke, constraint: .line(from: held.from), model: model) else { return }
            add(held.at, to: stroke)
        } else {
            drag(event)
        }
        finish()
    }

    /// The stroke on its first point: its session, its overlay, and the print's first snapshot.
    private func start(_ stroke: Stroke, constraint: StrokeSampler.Constraint, model: RollModel) -> Bool {
        guard let films = source ?? model.films, let mask = model.mask(stroke.target.mask, for: stroke.frame) else {
            abandon(stroke, why: "the mask has gone")
            return false
        }
        do {
            let session = try films.brushStrokeSession(frame: stroke.frame, lens: editor?.pictureLens(on: stroke.frame)?.settings ?? model.lensSettings(for: stroke.frame), picture: stroke.picture, mask: mask, component: stroke.component,
                                                       settings: stroke.settings, constraint: constraint)
            stroke.lane = MaskBrushLane(session: session, inline: runsInline, shapes: model.maskSeedStore)
            return true
        } catch {
            abandon(stroke, why: "\(error)")
            return false
        }
    }

    private func add(_ point: MaskPoint, to stroke: Stroke) {
        guard let lane = stroke.lane else { return }
        lane.async { $0.add(point) }
        stroke.unpublished = true
        stroke.unflushed = true
        keepUp()
    }

    /// `body` on the main thread, after the lane: at once for an inline lane, whose caller is the main thread.
    nonisolated private static func onMain(_ inline: Bool, _ body: @escaping @MainActor @Sendable () -> Void) {
        if inline {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    // MARK: Keeping the overlay and the print up with it

    /// The overlay at most every second refresh, the print at most at its own ceiling; whichever is not due yet goes when it is, so
    /// a pointer that stops still reaches both.
    private func keepUp() {
        guard let stroke, let editor else { return }
        let now = clock()
        let publishInterval = MaskOverlayStore.publishInterval(refreshesPerSecond: editor.overlay.refreshesPerSecond)
        let flushInterval = MaskEditor.flushInterval
        if stroke.unpublished, !stroke.overlayInFlight, now - stroke.lastPublish >= publishInterval { publish(stroke) }
        if stroke.unflushed, !stroke.printInFlight, now - stroke.lastFlush >= flushInterval { flush(stroke) }
        // What waits for its interval is followed up; what waits for the lane goes on when the lane's answer comes back.
        let overlayWaits = stroke.unpublished && !stroke.overlayInFlight, printWaits = stroke.unflushed && !stroke.printInFlight
        guard followUp == nil, overlayWaits || printWaits else { return }
        let wait = min(overlayWaits ? stroke.lastPublish + publishInterval - now : .infinity,
                       printWaits ? stroke.lastFlush + flushInterval - now : .infinity)
        followUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, wait)))
            guard let self, !Task.isCancelled else { return }
            self.followUp = nil
            self.keepUp()
        }
    }

    /// The mask's coverage from the stroke's canvas onto the overlay, read on the lane.
    private func publish(_ stroke: Stroke) {
        guard let lane = stroke.lane else { return }
        stroke.unpublished = false
        stroke.lastPublish = clock()
        stroke.overlayInFlight = true
        let inline = lane.isInline
        lane.async { [weak self] lane in
            let image = lane.overlayImage()
            Self.onMain(inline) { self?.published(image, from: lane) }
        }
    }

    private func published(_ image: CGImage?, from lane: MaskBrushLane) {
        guard let stroke, stroke.lane === lane else { return }
        stroke.overlayInFlight = false
        if let image, let editor {
            stroke.publishes += 1
            editor.overlay.showLive(image)
        }
        keepUp()
    }

    /// The stroke so far to the print, through `MaskEditor.printed`: the render reads its canvas as registered and lays nothing.
    private func flush(_ stroke: Stroke) {
        guard let lane = stroke.lane else { return }
        stroke.unflushed = false
        stroke.lastFlush = clock()
        stroke.printInFlight = true
        let inline = lane.isInline
        lane.async { [weak self] lane in
            let mask = lane.snapshot()
            Self.onMain(inline) { self?.snapshotted(mask, from: lane) }
        }
    }

    private func snapshotted(_ mask: Mask?, from lane: MaskBrushLane) {
        guard let stroke, stroke.lane === lane else { return }
        stroke.printInFlight = false
        if let mask, let editor {
            stroke.flushes += 1
            stroke.flushTimes.append(clock())
            editor.print(MaskEditor.Printed(frame: stroke.frame.url, mask: mask.id, component: stroke.component,
                                            shape: mask.components[stroke.component].shape))
        }
        keepUp()
    }

    /// A film went up `seconds` after its request: during a stroke, its lag behind the newest flush its request could take.
    func filmShown(renderedIn seconds: CFTimeInterval) {
        guard let stroke else { return }
        let now = clock(), requested = now - seconds
        if let flushed = stroke.flushTimes.last(where: { $0 <= requested }) { stroke.printLags.append(now - flushed) }
    }

    // MARK: The release

    /// Ends the stroke under way as one undo step, Paint Mask or Erase from Mask: the release, or anything that moves on during one.
    /// A stroke with no point leaves nothing, and a mask its press made goes again.
    func finish() {
        guard let stroke, let editor, let model = editor.model else { return }
        followUp?.cancel()
        followUp = nil
        guard let lane = stroke.lane else {
            // A Shift press that never became a stroke.
            return abandon(stroke, why: nil)
        }
        // The release waits for the lane's ticks, then lays the stroke's last dabs.
        let landing = CACurrentMediaTime()
        let ended: (stroke: BrushStroke?, image: CGImage?)
        do { ended = try lane.sync { try $0.end() } } catch {
            Self.log.error("brush end failed: \(String(describing: error), privacy: .public)")
            return abandon(stroke, why: "\(error)")
        }
        stroke.landing = CACurrentMediaTime() - landing
        guard let painted = ended.stroke else { return abandon(stroke, why: nil) }
        // The overlay's last picture is the canvas the print now reads: real coverage, and the overlay at rest starts from it.
        let finalImage = ended.image
        if let finalImage { editor.overlay.showLive(finalImage) }
        self.stroke = nil
        making = nil
        let mask = lane.mask(with: painted)
        // The edit takes the stroke before the print lets go of its own, in the same turn, as a gradient's release does.
        model.setComponentShape(mask.components[stroke.component].shape, of: stroke.target.mask, component: stroke.component, for: stroke.frame)
        editor.print(nil)
        model.endManualGesture(for: stroke.frame, actionName: stroke.erase ? "Erase from Mask" : "Paint Mask")
        counts.ended += 1
        report(stroke, lane: lane, painted: painted)
        let components = model.mask(stroke.target.mask, for: stroke.frame)?.components
        let request = components.flatMap { components in
            (editor.canvas?.geometry?()).map {
                MaskOverlayRequest(components: components, picture: $0.picture.size, longSide: MaskOverlayRequest.settledLongSide,
                                   frame: stroke.frame, lens: editor.pictureLens(on: stroke.frame))
            }
        }
        editor.overlay.endLive(keeping: finalImage, for: request)
        editor.didPaint()
    }

    /// Abandons the stroke under way with nothing to show for it and no undo step: Escape, an Undo during it, or a stroke that could
    /// not run. A mask or component its press made goes with it; the brush stays in hand.
    func cancel() {
        guard let stroke else { return }
        abandon(stroke, why: nil)
    }

    private func abandon(_ stroke: Stroke, why: String?) {
        followUp?.cancel()
        followUp = nil
        stroke.lane?.sync { $0.cancel() }
        if self.stroke === stroke { self.stroke = nil }
        if making?.target == stroke.target { making = nil }
        guard let editor else { return }
        editor.print(nil)
        editor.overlay.endLive(keeping: nil, for: nil)
        editor.model?.cancelManualGesture(for: stroke.frame)
        if stroke.made { editor.selection = stroke.selectionBefore }
        if let why {
            refuse(why)
        } else {
            counts.cancelled += 1
        }
    }

    private func refuse(_ why: String) {
        counts.refused += 1
        lastRefusal = why
        Self.log.info("brush press refused: \(why, privacy: .public)")
    }

    /// The last point of the target's last stroke, where Shift-click draws a line from.
    private func lastPoint(of target: MaskEditor.Selection, on frame: Frame, model: RollModel) -> MaskPoint? {
        guard let index = target.component, let component = model.mask(target.mask, for: frame)?.components[safe: index],
              case .brush(let paint) = component.shape else { return nil }
        return paint.strokes.last?.points.points.last
    }

    // MARK: The report

    /// What the pointer gave the stroke and what it cost, in the log for every stroke, so the first strokes on the owner's trackpad
    /// say how often it reports (P0-S2: AppKit coalesces drags to one a display refresh at most).
    private func report(_ stroke: Stroke, lane: MaskBrushLane, painted: BrushStroke) {
        let times = stroke.eventTimes, lanes = lane.sync { $0.report }, tickSeconds = lanes.ticks, waits = lanes.waits
        let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.sorted()
        func at(_ share: Double) -> Double { intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, Int(Double(intervals.count) * share))] }
        let ticks = tickSeconds.sorted(), lags = stroke.printLags.sorted()
        func lag(_ share: Double) -> Double { lags.isEmpty ? 0 : lags[min(lags.count - 1, Int(Double(lags.count) * share))] * 1000 }
        let duration = (times.last ?? 0) - (times.first ?? 0)
        let measured = lane.sync { $0.measureSeconds }
        lastReport = String(format: "events %d over %.2f s (%.0f a second), interval median %.1f p95 %.1f max %.1f ms; points %d;"
                            + " tick median %.2f max %.2f ms; overlay %d, print %d, films %d lag median %.0f p95 %.0f ms;"
                            + " on its lane %.0f ms (ticks %.0f, overlay %.0f, print %.0f), the release waited %.1f ms;"
                            + " the press %.1f ms (%@ %.1f, session %.1f); %@%@",
                            times.count, duration, duration > 0 ? Double(times.count - 1) / duration : 0, at(0.5), at(0.95),
                            intervals.last ?? 0, painted.points.count, (ticks.isEmpty ? 0 : ticks[ticks.count / 2]) * 1000,
                            (ticks.last ?? 0) * 1000, stroke.publishes, stroke.flushes, lags.count, lag(0.5), lag(0.95),
                            (waits.tick + waits.overlay + waits.print) * 1000, waits.tick * 1000, waits.overlay * 1000, waits.print * 1000,
                            stroke.landing * 1000, (stroke.pressShape + stroke.pressSession) * 1000,
                            stroke.made ? "making the shape" : "the edit", stroke.pressShape * 1000, stroke.pressSession * 1000,
                            stroke.erase ? "erase" : "paint",
                            painted.followEdges ? String(format: ", following edges: measured in %.1f ms (refinement GPU %.1f)",
                                                         measured.whole * 1000, measured.refinement * 1000) : "")
        Self.log.info("brush stroke: \(self.lastReport, privacy: .public)")
    }
}

// MARK: - Taking it up

extension RollModel {
    /// K, the Brush tile, ⇧K and ⌥K: the Masks tab comes up and the brush is in hand, for a new mask that its first stroke makes, or
    /// with `operation` for a component of the selected mask, if the frame can take one. The keyboard goes to the photograph, and the
    /// brush's kernels compile meanwhile, Follow edges' among them whether or not it is on, so neither the first press nor the first press after
    /// A waits for them.
    func armBrush(adding operation: MaskOperation? = nil) {
        guard let frame = shownFrame else { return }
        showInspector(tab: .masks)
        guard operation == nil ? canAddMask(frame) : canAddComponent(for: frame) else { return }
        let editor = maskEditor
        editor.finishPress()
        editor.brush.takeUp(operation: operation, model: self, frame: frame)
        // A new mask: nothing else's panel shows while its row waits for the first stroke.
        if operation == nil { editor.selection = nil }
        editor.arm(.brush, operation: operation)
        editor.requestPhotographFocus()
        guard let films else { return }
        if let held = films.brushPicture(for: frame, lens: maskEditor.pictureLens(on: frame)?.settings ?? lensSettings(for: frame)) {
            Task { await films.prepareBrush(picture: held.picture, followEdges: true) }
        } else if let layout = frameLayout {
            // A frame seen earlier whose decode has been let go: held again for the first press, then its kernels as above.
            let pixels = layout.pixels(frame)
            Task {
                await films.holdFrameDecode(frame, lens: maskEditor.pictureLens(on: frame)?.settings ?? lensSettings(for: frame), pixels: pixels)
                if let held = films.brushPicture(for: frame, lens: maskEditor.pictureLens(on: frame)?.settings ?? lensSettings(for: frame)) { await films.prepareBrush(picture: held.picture, followEdges: true) }
            }
        }
    }

    /// ] [ ⇧] ⇧[ and Flow's digits, with the brush in hand; asked of the live tool, since a key can beat the menu's refresh.
    /// On the Remove tab ] and [ are its brush's, which has a size and nothing else: the same steps, on the session's size.
    func stepBrush(_ change: (MaskBrushSettings) -> MaskBrushSettings) {
        if RemovePhotograph.frame(self) != nil {
            let stepped = change(MaskBrushSettings(size: Float(remove.brushSize), feather: 0, flow: 100)).size
            // Kept to the slider's own tenths, which a Float carries a little off.
            let size = (Double(stepped) * 10).rounded() / 10
            if size != remove.brushSize { remove.brushSize = size }
            return
        }
        guard maskEditor.tool == .brush else { return }
        maskEditor.brush.settings = change(maskEditor.brush.settings)
    }

    /// A, and the panel's check: Follow edges on or off for the brush in hand, from the next stroke. Its kernels compile meanwhile.
    func toggleFollowEdges() {
        guard maskEditor.tool == .brush else { return }
        stepBrush { var next = $0; next.followEdges.toggle(); return next }
        if maskEditor.brush.settings.followEdges, let frame = shownFrame, let films, let held = films.brushPicture(for: frame, lens: maskEditor.pictureLens(on: frame)?.settings ?? lensSettings(for: frame)) {
            Task { await films.prepareBrush(picture: held.picture, followEdges: true) }
        }
    }

    /// Whether the brush in hand waits for its first stroke on `frame`: what its pending row shows, for a new mask or for a component
    /// of the selected one.
    func brushIsPending(on frame: Frame) -> Bool {
        maskEditor.tool == .brush && maskEditor.brush.target(on: frame, model: self) == nil
    }
}
