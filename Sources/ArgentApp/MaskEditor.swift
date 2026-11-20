import AppKit
import ArgentCore
import ArgentRoll
import CoreGraphics
import Observation
import QuartzCore

/// What a frame's compiler lets its first mask do. Masks render only under the current Light compiler, so
/// an edit on an older one takes a first mask only where moving to the current one changes no pixel: on
/// `exposedBaseVersion` the two differ only in reading Highlights and Shadows after Exposure, which needs both
/// to be set to matter (bit-identical otherwise, measured, T1). Pure, with a table in `MaskEditorStateTests`.
enum MaskCompilerGate: Equatable, Sendable {
    /// No edit yet, or one on the current compiler: the mask goes in as it is.
    case open
    /// On `exposedBaseVersion` with nothing that compiler reads differently: the first mask takes the edit
    /// to the current compiler in its own undo step, silently, and Undo takes it back.
    case movesToCurrent
    /// The tiles are disabled, with a notice pointing at Update Automatic Baseline: moving would change the
    /// picture, so it is the photographer's to ask for.
    case needsUpdate

    /// `curveVersion` is the frame's `ManualEdit`'s, nil with no edit yet; `adjustments` its values.
    static func forFirstMask(curveVersion: String?, adjustments: ManualAdjustments) -> MaskCompilerGate {
        switch curveVersion {
        case nil, ManualRenderSettings.currentVersion:
            return .open
        case ManualRenderSettings.exposedBaseVersion:
            let readsDifferently = adjustments.exposureEV != 0 && (adjustments.highlights != 0 || adjustments.shadows != 0)
            return readsDifferently ? .needsUpdate : .movesToCurrent
        default:
            return .needsUpdate
        }
    }
}

/// The masks tool's interface state, none of it a mask itself and only the overlay's colour saved: the tool
/// in hand, the selected mask, what the pointer rests on and the press under way, and the rule that says
/// whose a press on the photograph is. Owned by `RollModel` as its own object, so a change here reaches only
/// what reads it, and a moving gradient only the overlay. A mask itself is the frame's edit, written through
/// `RollModel`'s gestures in `RollModel+Manual.swift`.
@MainActor @Observable
final class MaskEditor {
    /// A tool the photograph can be worked with. None in hand, the frame view is as it always was.
    enum Tool: String, CaseIterable, Sendable {
        case brush, linear, radial

        /// A gradient's name in a mask's list and its components: "Linear".
        var title: String {
            switch self {
            case .brush: "Brush"
            case .linear: "Linear"
            case .radial: "Radial"
            }
        }

        /// The undo step that adds a shape of this tool: a new mask, or a component.
        func actionName(adding operation: MaskOperation?) -> String {
            guard let operation else { return "Add \(title) Gradient" }
            return "\(operation.title) \(title)"
        }
    }

    /// Which mask is selected, and which of its components when one is. With only the mask selected its
    /// first component takes what acts on a component: Invert and the handles (`MaskEditor.componentIndex`).
    struct Selection: Equatable, Sendable {
        var mask: UUID
        var component: Int?
    }

    /// The row the pointer rests on.
    enum Hover: Equatable, Sendable {
        case mask(UUID)
        case component(UUID, Int)
    }

    /// A press the canvas took: what it will do, and once it moves what it has made so far. The shape in
    /// progress stays here, and reaches the print at most `flushInterval` apart (`printed`), so 120 events a
    /// second do not set off a print for each; it reaches the edit once, on the release.
    struct Press {
        enum Kind: Equatable {
            case draw(Tool, MaskOperation?)
            case handle(MaskHandle)
            /// A press on a pin: its mask selected at the press, and nothing more as it moves.
            case pin(UUID)
            /// Option at a press on a pin: its mask's Amount from `from`, stored 0 to 2, as the Amount row's drag moves it.
            case amount(UUID, from: Float)
        }

        var kind: Kind
        let frame: Frame
        let from: MaskPoint
        let fromPoint: CGPoint
        /// The component being drawn or dragged, once there is one.
        var target: Selection?
        let selectionBefore: Selection?
        var startShape: MaskShape?
        var live: MaskShape?
        var lastFlush: CFTimeInterval = 0
        /// A pin's Option-drag has moved past `MaskHandleModel.dragThreshold`, and its gesture is open.
        var moved = false
        /// A press on the selected gradient's pin, where other pins lie under it: the mask a click there goes to if the press never moves.
        var stackedNext: UUID?

        /// A pin's own press, whatever it does.
        var isPin: Bool {
            switch kind {
            case .pin, .amount: true
            case .draw, .handle: false
            }
        }
    }

    /// A moving gradient's shape as the print last took it, for the frame view's print and the gradient's own
    /// numbers, which are all that follow a press before its release. Written at most `flushInterval` apart;
    /// the edit itself, and everything that reads it (the menus, the title, the mask list, the sliders, the
    /// strip), changes once, on the release. Written to the edit at each flush, it relaid the window and
    /// redrew every slider about 30 times a second, and the drag lost a fifth of the refreshes (T8, T9).
    struct Printed: Equatable {
        let frame: URL
        let mask: UUID
        let component: Int
        let shape: MaskShape
    }

    private(set) var printed: Printed?

    /// What the print takes in place of the edit, or nothing: the brush's flushes go through here, as a gradient's do.
    func print(_ printed: Printed?) {
        if self.printed != printed { self.printed = printed }
    }

    /// A mask's Amount and Light values as the print takes them while one of its rows moves (a slider's drag, a scrub of its number,
    /// a key's step), for the frame view's print, which is all that follows them before the row's gesture ends; then the edit takes
    /// them once (`RollModel.endMaskAdjusting`), and with it everything that reads it: the Masks tab's list and panel, the inspector,
    /// the menus. Written to the edit at each step, a mask slider's drag ran and laid out the whole tab 30 times a second and lost
    /// 10 to 11 % of the refreshes at fit against a Light slider's 2 to 5 (G, H, I; measured again, J).
    struct PrintedValues: Equatable {
        let frame: URL
        let mask: UUID
        var amount: Float
        var adjustments: ManualAdjustments
        var balance: MaskBalance
    }

    private(set) var printedValues: PrintedValues?

    /// The values the print takes for a mask whose row moves; nothing lets go of them but `sliderEnded`.
    func print(_ values: PrintedValues) {
        if printedValues != values { printedValues = values }
    }

    /// The shape the print takes for `mask`'s `component` on `frame` while a press moves it, if one does.
    func printedShape(of mask: UUID, component: Int, on frame: Frame) -> MaskShape? {
        guard let printed, printed.frame == frame.url, printed.mask == mask, printed.component == component else { return nil }
        return printed.shape
    }

    /// The least time between a moving gradient's or a stroke's flushes to the print, so it follows at about 30 Hz while the overlay
    /// and the handles keep up with the pointer (R7 5.4). Whatever the print costs: the frame view renders one film at a time and
    /// takes the newest flush when the last ends (`FramePicture.printing`), so a slow print is followed as often as it can be. T8's
    /// ceiling, which spaced the flushes to five times a print over 30 ms, is gone with its cause: a large film cost the main thread
    /// its area only while Core Animation matched it to the display (`WindowChrome`); without it a Subtract stroke into a Sky mask at
    /// 2x put up 231 films in 8 s instead of 50 to 64, at 3x 131 to 147 instead of 34, losing no more refreshes (measured, J).
    static let flushInterval: CFTimeInterval = 1.0 / 30

    struct PictureLens: Hashable, Sendable {
        let frame: URL
        let lens: MaskLens
        let settings: LensSettings
    }

    private var pictureLens: PictureLens?

    func pictureLens(on frame: Frame) -> PictureLens? {
        pictureLens?.frame == frame.url ? pictureLens : nil
    }

    func lens(on frame: Frame) -> MaskLens? {
        pictureLens(on: frame)?.lens
    }

    private func editingLens(on frame: Frame) -> MaskLens? {
        lens(on: frame) ?? model.flatMap { $0.maskLens(for: frame, settings: $0.lensSettings(for: frame)) }
    }

    private func inPicture(_ shape: MaskShape, on frame: Frame) -> MaskShape {
        editingLens(on: frame).flatMap { $0.toPicture(shape) == nil ? nil : shape.moved(in: $0) { measured, _ in measured } } ?? shape
    }

    /// What the print last cost while a press moved a gradient or a brush painted: from the frame view's request to its film put up.
    @ObservationIgnored private(set) var printSeconds: CFTimeInterval = 0

    /// A rendered or cached film is on screen: its lens is the geometry new shapes and edits use.
    func pictureShown(for frame: Frame, settings: DevelopSettings) {
        let now = model?.maskLens(for: frame, settings: settings.lens).map { PictureLens(frame: frame.url, lens: $0, settings: settings.lens) }
        if pictureLens != now {
            pictureLens = now
            canvas?.pictureChanged()
        }
    }

    func pictureHidden() {
        pictureLens = nil
    }

    /// A newly rendered film also reports its print time to the active gradient or brush.
    func filmShown(for frame: Frame, settings: DevelopSettings, renderedIn seconds: CFTimeInterval) {
        pictureShown(for: frame, settings: settings)
        guard press?.frame.url == frame.url || brush.stroke?.frame.url == frame.url else { return }
        printSeconds = max(0, seconds)
        brush.filmShown(renderedIn: seconds)
    }

    /// The tool in hand, for at most as long as the frame, the inspector and its Masks tab stay.
    private(set) var tool: Tool?
    /// With a tool in hand: Add, Subtract or Intersect to the selected mask. None, and it draws a new mask.
    private(set) var pendingOperation: MaskOperation?
    /// Cleared on the same occasions as the tool (R7 6.1). A mask that has gone, by a reset or an undo, is
    /// never left selected (`reconcile`).
    var selection: Selection? {
        didSet {
            guard selection != oldValue else { return }
            // Another mask chosen while the brush paints one puts the brush down, as Lightroom's does: its strokes would go where
            // the panel no longer shows.
            if tool == .brush, !brush.isPainting, let model, let frame = model.shownFrame,
               let target = brush.target(on: frame, model: model), selection?.mask != target.mask {
                putDownTool()
            }
            canvas?.toolChanged()
        }
    }
    var hover: Hover?
    /// The tiles in Add's popover, on a frame that has masks. With none they are all the tab has.
    var isPickerOpen = false
    /// The selected mask's groups of rows that are open (`MaskPanel`): Light at first, with Balance and the shape's numbers
    /// folded under their names. For this session, whichever mask is selected, as the overlay is.
    var openGroups: Set<MaskGroup> = [.light]
    /// The mask whose name is being typed.
    var renaming: UUID?
    /// The Overlay switch beside a selected mask's name, for this session.
    var isOverlayOn = false
    var overlayColour: MaskOverlayColour {
        didSet { defaults.set(overlayColour.rawValue, forKey: MaskOverlayColour.storageKey) }
    }
    /// H: the pins hidden, for this session, as the Overlay switch is; a new session shows them again, so they never stay lost
    /// behind a key the tab does not mention.
    private(set) var arePinsHidden = false
    /// The pointer is over the frame view's area, where the pins show: Lightroom's Auto, and none over the inspector, the dock or the strip.
    private(set) var isPointerInArea = false
    /// The pin the pointer rests on, whose mask's overlay shows as its row's would.
    private(set) var hoveredPin: UUID?
    /// A pin's Option-drag's newest Amount, stored 0 to 2, which its value tag shows at once; the print takes it at most every
    /// `flushInterval` (`flushPinAmount`). Only the tag reads it.
    private(set) var pinDragAmount: Float?
    /// When the print last took a pin's Amount.
    @ObservationIgnored private var pinAmountFlushed: CFTimeInterval = -.infinity
    /// The smart selections' pins, found on their seeds.
    @ObservationIgnored let pinSeeds = MaskPinSeeds()
    /// The last pins' anchors and what they were made from, so a pointer's every move does not unpack a brush's points again.
    @ObservationIgnored private var pinMemo: (masks: [Mask], seeds: [MaskPinSeeds.Key: CGPoint?], anchors: [PinAnchor])?
    /// A gradient was just drawn or moved, and no slider has moved since.
    private(set) var justPlaced = false
    /// A mask's Amount or Light slider is moving.
    private(set) var isAdjusting = false
    /// A shape's number is moving.
    private(set) var isShaping = false
    private(set) var press: Press?
    /// Grows when the keyboard should come back to the photograph, as it does on a press of the canvas.
    private(set) var photographFocusRequests = 0

    /// The frame view's canvas, while there is one: what says where the picture is.
    @ObservationIgnored weak var canvas: MaskCanvasView?
    /// What gestures write through. None in a test of the rule alone.
    @ObservationIgnored weak var model: RollModel?
    @ObservationIgnored let overlay: MaskOverlayStore
    /// The brush: its settings, what it paints, and the stroke under way (`MaskBrush`).
    let brush: MaskBrush
    @ObservationIgnored var clock: () -> CFTimeInterval = CACurrentMediaTime
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// For the tests and the drive hook: what reached the canvas, and how many times a moving gradient was flushed to the
    /// print. In every build, so the tests compile in a release build too, as the measuring suites are run.
    @ObservationIgnored private(set) var canvasCounts = (press: 0, drag: 0, release: 0)
    @ObservationIgnored private(set) var lastCanvasEvent: MaskCanvasEvent?
    @ObservationIgnored private(set) var flushCount = 0
    #if DEBUG
    /// For the drive hook: how often the photograph's Delete reached the editor.
    @ObservationIgnored private(set) var deletePresses = 0
    #endif

    init(defaults: UserDefaults = .standard, overlay: MaskOverlayStore = MaskOverlayStore()) {
        self.defaults = defaults
        self.overlay = overlay
        brush = MaskBrush(defaults: defaults)
        overlayColour = defaults.string(forKey: MaskOverlayColour.storageKey).flatMap(MaskOverlayColour.init(rawValue:)) ?? .red
        brush.editor = self
    }

    var isArmed: Bool { tool != nil }
    /// A gradient is being drawn, a handle or a shape's number moves, or the brush paints.
    var isPlacing: Bool { press?.live != nil || isShaping || brush.isPainting }
    /// The canvas needs to know where the pointer is: for a tool, for handles that are showing, or for pins that would.
    var followsPointer: Bool { isArmed || selection != nil || arePinsWanted }
    /// The component a selection acts on: the chosen one, or with only the mask chosen, its first.
    var componentIndex: Int { selection?.component ?? 0 }

    /// Opens a folded group of the selected mask's rows, or folds an open one.
    func toggle(_ group: MaskGroup) {
        if openGroups.contains(group) { openGroups.remove(group) } else { openGroups.insert(group) }
    }

    /// Takes `tool` in hand, in place of any other; with `operation`, to add to the selected mask.
    func arm(_ tool: Tool, operation: MaskOperation? = nil) {
        guard self.tool != tool || pendingOperation != operation else { return }
        self.tool = tool
        pendingOperation = operation
        isPickerOpen = false
        justPlaced = false
        canvas?.toolChanged()
    }

    /// The photograph's menu's Put Tool Away: what Escape does to a tool in hand, and nothing more. The menu never opens over a press
    /// under way (`canvasTakesMenu`), so there is none to let go first, as Escape's ladder would.
    func putToolAway() { putDownTool() }

    /// Puts down the tool in hand, and only that: Escape's step, and what drawing a gradient ends in.
    private func putDownTool() {
        guard tool != nil else { return }
        tool = nil
        pendingOperation = nil
        brush.target = nil
        canvas?.toolChanged()
    }

    /// Puts down the tool and lets go of the selection, finishing any press first. A switch of tab, the
    /// inspector closing, another frame and leaving the frame all come here, so nothing stays armed or
    /// selected behind the photographer's back.
    func reset() {
        finishPress()
        tool = nil
        pendingOperation = nil
        brush.target = nil
        selection = nil
        hover = nil
        if hoveredPin != nil { hoveredPin = nil }
        isPickerOpen = false
        renaming = nil
        justPlaced = false
        isAdjusting = false
        isShaping = false
        canvas?.toolChanged()
    }

    /// Asks for the keyboard to come back to the photograph, where Return places a gradient.
    func requestPhotographFocus() { photographFocusRequests &+= 1 }

    // MARK: The rule

    /// The whole routing rule: a press belongs to the canvas when a tool is armed and the point, in the frame
    /// view's area, is on the picture the area shows; or with no tool, when it lands on a handle of the selected
    /// gradient, on the picture or off it, or on a pin. Never with Command held (Command-drag pans), and always once
    /// the canvas has one under way, whose handle may have moved from under where it began. A tool in hand takes
    /// every press on the film side of the picture, so a pin never takes a stroke's. A split's neutral side is not the tool's: it
    /// shows no red and no effect, so the frame view keeps it, and a stroke begun on the film side crosses it unbroken.
    /// The canvas's hit test asks it, and so do
    /// `FrameView`'s pan and double-click, since SwiftUI feeds them the same events even when an AppKit child took
    /// them (measured, P0-S2: a stroke panned a zoomed frame).
    func canvasTakesPress(at point: CGPoint, command: Bool) -> Bool {
        if press != nil || brush.isPainting { return true }
        guard !command, let geometry = canvas?.geometry?() else { return false }
        if isArmed { return geometry.toolPicture.contains(point) }
        if selection != nil, let frame = model?.shownFrame, let shape = shapeUnderHandles(in: frame),
           MaskHandleModel.hit(at: point, of: shape, in: geometry) != nil {
            return true
        }
        return pin(at: point, pressing: false) != nil
    }

    /// Command as the event being handled has it, the same for the hit test and for the gestures.
    static var isCommandHeld: Bool {
        (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command)
    }

    /// The rule's other half: whether a right-click or a Control-click at `point`, in the frame view's area, opens a menu there,
    /// the photograph's or a pin's (`PhotographMenu`). Anywhere on the area, a tool in hand or not, but never while a press, a stroke,
    /// a slider's or a number's gesture is open on the frame (a menu chosen then would act on an edit half made), while Space shows
    /// the neutral raw, or on the split's divider, whose strip keeps its own pointer. The canvas's hit test asks it for those two
    /// clicks, and its menu is built only once it says yes.
    func canvasTakesMenu(at point: CGPoint) -> Bool {
        guard press == nil, !brush.isPainting, !isAdjusting, !isShaping, let model, let frame = model.shownFrame,
              !model.isComparing, model.manualGestures[frame.url] == nil, let geometry = canvas?.geometry?(),
              CGRect(origin: .zero, size: geometry.area).contains(point) else { return false }
        return !Self.isOnDivider(point, in: geometry)
    }

    /// The divider's strip each side of its line (`SplitDivider`), which takes the pointer over the part of the picture the area
    /// shows. It is above the canvas and keeps its clicks; the rule says so too, so it does not hang on the views' order.
    static var dividerReach: CGFloat { SplitDivider.reach }

    /// Whether `point` is on the split's divider, while a split is up (`FrameGeometry.filmEdge`).
    static func isOnDivider(_ point: CGPoint, in geometry: FrameGeometry) -> Bool {
        guard let edge = geometry.filmEdge else { return false }
        let shown = geometry.visiblePicture
        guard !shown.isNull, point.y >= shown.minY, point.y <= shown.maxY else { return false }
        return abs(point.x - edge) <= dividerReach
    }

    /// A right-click, or a Control-click, which is the Mac's other way to ask for a view's menu: never a press, of the canvas's or of
    /// the frame view's own pan and double-click. AppKit asks a view's menu for a Control-click before it sends the press, but only
    /// of a view that has one, and SwiftUI's gestures see the press either way (P0-S2), so each asks here.
    static func isMenuClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: return true
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return event.modifierFlags.contains(.control)
        default: return false
        }
    }

    /// Whether the event being handled is a right-click or a Control-click, for the frame view's gestures, as `isCommandHeld`.
    static var isHandlingMenuClick: Bool { isMenuClick(NSApp.currentEvent) }

    /// The gradient whose handles show on `frame`, with its shape in progress if it is moving: the selected
    /// mask's component. None while a tool waits for its first drag, or under Space, Compare to Auto, the
    /// clipping view or a frame that cannot be adjusted (`RollModel.masksStandDown`).
    func shapeUnderHandles(in frame: Frame) -> MaskShape? {
        guard let model, let selection, !isArmed || press?.live != nil, !model.masksStandDown(frame),
              let mask = model.mask(selection.mask, for: frame) else { return nil }
        if let press, let live = press.live, press.target?.mask == selection.mask { return live }
        let index = selection.component ?? 0
        guard mask.components.indices.contains(index) else { return nil }
        switch mask.components[index].shape {
        case .linear, .radial: return inPicture(mask.components[index].shape, on: frame)
        case .brush, .smart: return nil
        }
    }

    // MARK: The press

    /// One step of a press the canvas took.
    func canvasEvent(_ event: MaskCanvasEvent) {
        switch event.phase {
        case .press: canvasCounts.press += 1
        case .drag: canvasCounts.drag += 1
        case .release: canvasCounts.release += 1
        }
        lastCanvasEvent = event
        switch event.phase {
        case .press:
            if tool == .brush { brush.press(event) } else { beginPress(event) }
        case .drag:
            if brush.isPainting { brush.drag(event) } else { movePress(event) }
        case .release:
            if brush.isPainting {
                brush.release(event)
            } else {
                movePress(event)
                finishPress()
            }
        }
    }

    private func beginPress(_ event: MaskCanvasEvent) {
        press = nil
        // While standing down the canvas keeps the press and it does nothing.
        guard let model, let frame = model.shownFrame, let geometry = canvas?.geometry?(), !model.masksStandDown(frame) else { return }
        let from = geometry.maskPoint(event.point)
        let option = event.modifiers.contains(.option)
        if let tool {
            guard tool != .brush else { return }
            press = Press(kind: .draw(tool, pendingOperation), frame: frame, from: from, fromPoint: event.point, selectionBefore: selection)
        } else if let selection, let shape = shapeUnderHandles(in: frame),
                  let handle = MaskHandleModel.hit(at: event.point, of: shape, in: geometry) {
            // The handle that moves the gradient whole is its mask's pin when the pin stands there: Option takes its Amount there too.
            if option, handle.movesWhole, let mask = model.mask(selection.mask, for: frame),
               pins(on: frame, geometry: geometry).contains(where: { $0.id == mask.id && $0.isOnHandle }) {
                press = Press(kind: .amount(mask.id, from: mask.amount), frame: frame, from: from, fromPoint: event.point,
                              target: Selection(mask: mask.id, component: nil), selectionBefore: selection)
                return
            }
            press = Press(kind: .handle(handle), frame: frame, from: from, fromPoint: event.point,
                          target: Selection(mask: selection.mask, component: selection.component ?? 0),
                          selectionBefore: selection, startShape: shape)
            // Pins on the one that stands on this handle, as a duplicate's: a click that does not move goes on to the next of them.
            if handle.movesWhole, let next = pin(at: event.point, pressing: true), next != selection.mask { press?.stackedNext = next }
        } else if let id = pin(at: event.point, pressing: true), let mask = model.mask(id, for: frame) {
            // A gradient's pin is the handle that moves it whole, which shows once it is selected: a drag from it moves it, one press from
            // first to last. Its pin stands for its first component, the one its handles then show.
            let gradient: (shape: MaskShape, whole: MaskHandle)? = pins(on: frame, geometry: geometry).first { $0.id == id }.flatMap { pin in
                guard pin.component == 0 else { return nil }
                switch inPicture(mask.components[0].shape, on: frame) {
                case .linear(let g): return (.linear(g), .middle)
                case .radial(let g): return (.radial(g), .center)
                case .brush, .smart: return nil
                }
            }
            let kind: Press.Kind = option ? .amount(id, from: mask.amount) : gradient.map { .handle($0.whole) } ?? .pin(id)
            let pinned = Press(kind: kind, frame: frame, from: from, fromPoint: event.point,
                               target: Selection(mask: id, component: gradient != nil && !option ? 0 : nil), selectionBefore: selection,
                               startShape: option ? nil : gradient?.shape)
            // The press first, then the selection: a change of selection asks whether a press is under way (`MaskCanvasView.toolChanged`),
            // and a canvas told none lets the drag go. The pin's mask is selected as its row's click selects it, and the list follows.
            press = pinned
            selection = Selection(mask: id, component: nil)
        }
    }

    private func movePress(_ event: MaskCanvasEvent) {
        guard var press, let model, let geometry = canvas?.geometry?(), !model.masksStandDown(press.frame) else { return }
        switch press.kind {
        case .pin:
            return
        case .amount(let id, let start):
            // As the Amount row's drag: its gesture opens at the first movement, its steps go to the print alone, and its release
            // writes the edit once (`RollModel.endMaskAdjusting`).
            if !press.moved {
                guard abs(event.point.x - press.fromPoint.x) >= MaskHandleModel.dragThreshold else { return }
                model.beginMaskAdjusting(for: press.frame)
                press.moved = true
                self.press = press
                pinAmountFlushed = -.infinity
            }
            let amount = MaskPinModel.amount(from: start, dragged: event.point.x - press.fromPoint.x)
            if pinDragAmount != amount { pinDragAmount = amount }
            flushPinAmount(of: id, force: false)
            return
        case .draw, .handle:
            break
        }
        if press.live == nil {
            guard hypot(event.point.x - press.fromPoint.x, event.point.y - press.fromPoint.y) >= MaskHandleModel.dragThreshold else { return }
        }
        let to = geometry.maskPoint(event.point), constrain = event.modifiers.contains(.shift)
        switch press.kind {
        case .draw(let tool, let operation):
            guard let shape = MaskHandleModel.drawn(tool, from: press.from, to: to, constrain: constrain)?.stamped(editingLens(on: press.frame)?.picture) else { return }
            if press.target == nil {
                // One drag makes the mask, with no OK. Its gesture stays open to the release.
                guard let target = model.beginDrawnShape(shape, tool: tool, operation: operation, for: press.frame) else {
                    self.press = nil
                    return
                }
                press.target = target
                press.lastFlush = clock()
                selection = target
            }
            press.live = shape
        case .handle(let handle):
            guard let start = press.startShape else { return }
            if press.live == nil {
                model.beginManualGesture(for: press.frame)
                press.lastFlush = -.infinity
            }
            press.live = MaskHandleModel.dragged(handle, start: start, from: press.from, to: to, constrain: constrain)
        case .pin, .amount:
            return
        }
        self.press = press
        flushIfDue()
    }

    /// A pin's Option-drag's Amount to the print (`RollModel.moveMaskAmount`, inside the row's gesture), at most every `flushInterval`, as a
    /// moving gradient's shape and a stroke reach it, and the newest at the end of the interval if the pointer stops; with `force`, now.
    /// Unpaced, the print followed this drag at up to 109 films a second at fit and 42 at 2×, against the Amount slider's 27, and at 2×
    /// lost more refreshes than the slider's drag on average (measured, task M).
    private func flushPinAmount(of id: UUID, force: Bool) {
        guard let press, press.moved, let amount = pinDragAmount, let model else { return }
        let elapsed = clock() - pinAmountFlushed, interval = Self.flushInterval
        if force || elapsed >= interval {
            flushTask?.cancel()
            flushTask = nil
            model.moveMaskAmount(amount, mask: id, for: press.frame)
            pinAmountFlushed = clock()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(interval - elapsed))
                guard let self, !Task.isCancelled else { return }
                self.flushTask = nil
                self.flushPinAmount(of: id, force: true)
            }
        }
    }

    /// Flushes the moving shape to the print if it is time, and otherwise sees that the last place the pointer
    /// came to reaches the print even if it stops there.
    private func flushIfDue() {
        guard let press else { return }
        let elapsed = clock() - press.lastFlush, interval = Self.flushInterval
        if elapsed >= interval {
            flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(interval - elapsed))
                guard let self, !Task.isCancelled else { return }
                self.flushTask = nil
                self.flush()
            }
        }
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard var press, let live = press.live, let target = press.target else { return }
        flushCount += 1
        let flushed = Printed(frame: press.frame.url, mask: target.mask, component: target.component ?? 0, shape: live)
        if printed != flushed { printed = flushed }
        press.lastFlush = clock()
        self.press = press
    }

    /// Ends the press, one undo step if it did anything: the release, or anything that moves on while one
    /// is under way. A click that never moved leaves the tool in hand and nothing changed.
    func finishPress() {
        brush.finish()
        guard let done = press else { return }
        if done.isPin {
            // A pin's: a click selected and is done; an Option-drag's last Amount goes to the print, and it ends as the Amount row's
            // gesture ends, one "Adjust Mask" step.
            if done.moved, case .amount(let id, _) = done.kind { flushPinAmount(of: id, force: true) }
            press = nil
            pinDragAmount = nil
            if done.moved { model?.endMaskAdjusting(for: done.frame) }
            canvas?.pictureChanged()
            return
        }
        flushTask?.cancel()
        flushTask = nil
        guard let live = done.live, let target = done.target, let model else {
            press = nil
            printed = nil
            if let next = done.stackedNext { selection = Selection(mask: next, component: nil) }
            return
        }
        // The edit takes the shape before the print lets go of its own, in the same turn, so the frame view
        // never asks for the shape the press began with.
        if live != done.startShape {
            model.setComponentShape(live, of: target.mask, component: target.component ?? 0, for: done.frame)
        }
        press = nil
        printed = nil
        switch done.kind {
        case .draw(let tool, let operation):
            model.endManualGesture(for: done.frame, actionName: tool.actionName(adding: operation))
            putDownTool()
        case .handle:
            model.endManualGesture(for: done.frame, actionName: "Adjust Gradient")
        case .pin, .amount:
            break
        }
        justPlaced = true
        canvas?.pictureChanged()
    }

    /// Abandons the press with nothing to show for it and no undo step: Escape, or an Undo that arrives
    /// during one. The tool stays in hand.
    func cancelPress() {
        brush.cancel()
        guard let done = press else { return }
        if done.isPin {
            // The Amount goes back to where the press found it; the click's selection stays.
            flushTask?.cancel()
            flushTask = nil
            press = nil
            pinDragAmount = nil
            guard done.moved else { return }
            sliderEnded()
            model?.cancelManualGesture(for: done.frame)
            canvas?.pictureChanged()
            return
        }
        flushTask?.cancel()
        flushTask = nil
        press = nil
        printed = nil
        guard done.live != nil else { return }
        model?.cancelManualGesture(for: done.frame)
        selection = done.selectionBefore
        canvas?.pictureChanged()
    }

    /// A stroke ended: its mask shows, as a gradient just drawn does, until a slider moves.
    func didPaint() { justPlaced = true }

    /// A gradient placed by the keyboard is as one drawn: the tool goes back, it is selected and it shows.
    func didPlace(_ target: Selection) {
        selection = target
        putDownTool()
        justPlaced = true
    }

    // MARK: Sliders

    /// A mask's Amount or Light slider began to move: the red steps aside so the change can be judged, and
    /// what a gradient's drawing left up does not come back. Until it ends its values go to the print alone (`printedValues`).
    func sliderBegan() {
        isAdjusting = true
        justPlaced = false
    }

    /// The slider stopped, and the edit has taken what the print took (`RollModel.endMaskAdjusting`): the print lets go of it.
    func sliderEnded() {
        isAdjusting = false
        printedValues = nil
    }

    /// A shape's number began to move, which is placing it, not adjusting.
    func shapeRowBegan() { isShaping = true }

    func shapeRowEnded() {
        isShaping = false
        justPlaced = true
    }

    // MARK: Pins

    /// A mask's pin before it is placed on screen: where it stands and the component it stands for.
    struct PinAnchor: Equatable {
        let mask: Mask
        let anchor: MaskPinAnchor
        let component: Int
    }

    /// H, from the Mask menu's Show Pins.
    func togglePins() {
        arePinsHidden.toggle()
        if arePinsHidden, let pin = hoveredPin {
            hoveredPin = nil
            if hover == .mask(pin) { hover = nil }
        }
        canvas?.toolChanged()
    }

    /// The pointer moved: over the frame view's area or not, and onto a pin or off one. Hovering a pin shows its mask's overlay as its
    /// row's hover does (`hover`), and going off it lets that go. Written only when it changes, so a pointer's moves redraw nothing else.
    func pointerMoved(inArea: Bool, over pin: UUID?) {
        if isPointerInArea != inArea { isPointerInArea = inArea }
        guard hoveredPin != pin else { return }
        if let old = hoveredPin, hover == .mask(old) { hover = nil }
        hoveredPin = pin
        if let pin { hover = .mask(pin) }
    }

    /// The Masks tab is open on a frame with masks, and H has not hidden its pins: the canvas follows the pointer for them.
    var arePinsWanted: Bool {
        guard !arePinsHidden, let model, let frame = model.shownFrame, model.openAdjustSection == .masks, model.isAdjustmentsShown else { return false }
        return !model.masks(for: frame).isEmpty
    }

    /// What `MaskPinVisibility` asks, on `frame` now.
    func pinInputs(on frame: Frame) -> MaskPinVisibility.Inputs {
        guard let model else { return MaskPinVisibility.Inputs() }
        let shown = model.openAdjustSection == .masks && model.isAdjustmentsShown && model.shownFrame?.url == frame.url
        return MaskPinVisibility.Inputs(isMasksTabShown: shown, hasMasks: !model.masks(for: frame).isEmpty, isHidden: arePinsHidden,
                                        standsDown: shown && model.masksStandDown(frame), isArmed: isArmed, isPlacing: isPlacing,
                                        isPointerInArea: isPointerInArea, isPinPressed: press?.isPin == true)
    }

    /// Each mask's pin on `frame` with the component it stands for, in the list's order; a mask with none yet has no entry. A smart
    /// selection's waits for its seed's point (`pinSeeds`), which reading here observes, so the pins redraw as it lands.
    func pinAnchors(on frame: Frame) -> [PinAnchor] {
        guard let model else { return [] }
        let masks = model.masks(for: frame), seeds = pinSeeds.points
        if let memo = pinMemo, memo.masks == masks, memo.seeds == seeds { return memo.anchors }
        let anchors = masks.compactMap { mask in
            MaskPinPlacement.anchor(of: mask, seed: pinSeeds.point(for:)).map { PinAnchor(mask: mask, anchor: $0.anchor, component: $0.component) }
        }
        pinMemo = (masks, seeds, anchors)
        return anchors
    }

    /// The frame's pins where `geometry` puts them, in the list's order. The selected gradient's pin stands on its handle that moves it
    /// whole when that handle shows: the two are one target there (`isOnHandle`).
    func pins(on frame: Frame, geometry: FrameGeometry) -> [MaskPin] {
        let anchors = pinAnchors(on: frame)
        guard !anchors.isEmpty else { return [] }
        let handled = shapeUnderHandles(in: frame) != nil
        return anchors.map { entry in
            let selected = selection?.mask == entry.mask.id
            let gradient = switch entry.mask.components[entry.component].shape {
            case .linear, .radial: true
            case .brush, .smart: false
            }
            let at = entry.anchor.point(in: geometry)
            let remap = lens(on: frame)?.toPicture(entry.mask.components[entry.component].shape)
            return MaskPin(id: entry.mask.id, point: remap.map { geometry.point(for: $0.point(geometry.maskPoint(at))) } ?? at, component: entry.component, isSelected: selected,
                           isHovered: hoveredPin == entry.mask.id, isEnabled: entry.mask.isEnabled,
                           isOnHandle: selected && handled && gradient && entry.component == componentIndex,
                           isPressed: isPressing(pinOf: entry.mask.id))
        }
    }

    /// Whether the press under way is on `mask`'s pin: the pin's own press or its Option-drag, or for a gradient the press on the
    /// handle its pin stands on, which moves it whole.
    private func isPressing(pinOf mask: UUID) -> Bool {
        guard let press else { return false }
        switch press.kind {
        case .pin(let id), .amount(let id, _): return id == mask
        case .handle(let handle): return press.target?.mask == mask && (handle == .middle || handle == .center)
        case .draw: return false
        }
    }

    /// The pins drawn on `frame` now: none unless they show (`MaskPinVisibility`), and only those the area shows.
    func shownPins(on frame: Frame, geometry: FrameGeometry) -> [MaskPin] {
        guard MaskPinVisibility.isShown(pinInputs(on: frame)) else { return [] }
        let reach = MaskPinModel.selectedDiameter
        let area = CGRect(origin: .zero, size: geometry.area).insetBy(dx: -reach, dy: -reach)
        return pins(on: frame, geometry: geometry).filter { area.contains($0.point) }
    }

    /// The pin at area point `point` on the frame shown, while pins take the pointer: the one on top for hovering, and for a press the
    /// one a click there goes to (`MaskPinModel.pressed`).
    func pin(at point: CGPoint, pressing: Bool) -> UUID? {
        guard let model, let frame = model.shownFrame, let geometry = canvas?.geometry?(), MaskPinVisibility.isLive(pinInputs(on: frame)) else {
            return nil
        }
        let pins = pins(on: frame, geometry: geometry)
        return pressing ? MaskPinModel.pressed(at: point, in: pins, area: geometry.area) : MaskPinModel.hovered(at: point, in: pins, area: geometry.area)
    }

    /// Where the value tag stands over a pin whose Option-drag moves its mask's Amount: above the pin and inside the area. It reads the
    /// press, which changes at the press and at its first movement, and not the Amount, which changes at every step.
    func pinAmountTagPlace(on frame: Frame, geometry: FrameGeometry) -> (mask: UUID, point: CGPoint)? {
        guard let press, press.moved, case .amount(let id, _) = press.kind, press.frame.url == frame.url,
              let pin = pins(on: frame, geometry: geometry).first(where: { $0.id == id }) else {
            return nil
        }
        let above = MaskPinModel.selectedDiameter / 2 + 20
        let x = min(max(pin.point.x, 48), geometry.area.width - 48), y = pin.point.y - above < 16 ? pin.point.y + above : pin.point.y - above
        return (id, CGPoint(x: x, y: y))
    }

    /// The value tag's words: the drag's newest Amount, which the print takes at most every `flushInterval`.
    func pinAmountTagText(for mask: UUID) -> String? {
        guard let press, case .amount(let id, _) = press.kind, id == mask, let amount = pinDragAmount else { return nil }
        return MaskPinModel.tag(amount)
    }

    /// The value tag, its words and where: for the tests and the drive hook.
    func pinAmountTag(on frame: Frame, geometry: FrameGeometry) -> (text: String, point: CGPoint)? {
        guard let place = pinAmountTagPlace(on: frame, geometry: geometry), let text = pinAmountTagText(for: place.mask) else { return nil }
        return (text, place.point)
    }

    // MARK: Overlay

    /// O, and what unticking the checkbox does: hides what is up, or else keeps it up. Hover and placing a
    /// gradient still show it (the plan's rule); this is about the selected mask at rest.
    func toggleOverlay() {
        if isOverlayOn || justPlaced {
            isOverlayOn = false
            justPlaced = false
        } else {
            isOverlayOn = true
        }
    }

    /// The checkbox: on keeps it up through sliders; off hides what is up.
    func setOverlay(on: Bool) {
        isOverlayOn = on
        if !on { justPlaced = false }
    }

    func nextOverlayColour() { overlayColour = overlayColour.next }

    // MARK: Escape and Delete

    /// Escape on the photograph: whether something of the masks took it, before it goes on to close the
    /// frame. The ladder is the press or stroke under way, the tool, the picker, the component, the mask.
    func escape() -> Bool {
        // The name field's own Escape never fires: its field editor has the key and sends it on, here, past the row (measured, task R).
        if renaming != nil {
            renaming = nil
            return true
        }
        if press != nil || brush.isPainting { cancelPress(); return true }
        if isArmed { putDownTool(); return true }
        if isPickerOpen { isPickerOpen = false; return true }
        if selection?.component != nil { selection?.component = nil; return true }
        if selection != nil {
            selection = nil
            justPlaced = false
            return true
        }
        return false
    }

    /// Delete on the photograph or the mask list: whether there was a selection to delete. With none, the
    /// key goes on as it did.
    func deleteSelection() -> Bool {
        #if DEBUG
        deletePresses += 1
        #endif
        guard let model, let frame = model.shownFrame, selection != nil else { return false }
        return model.deleteSelection(for: frame)
    }

    // MARK: Keeping up with the edit

    /// The selection after the masks changed under it, by an Undo or a Redo: a mask that came back is selected,
    /// so is the one mask a step changed, and a mask that has gone is not. Pure.
    static func reconciled(_ selection: Selection?, from old: [Mask], to new: [Mask]) -> Selection? {
        let known = Set(old.map(\.id))
        if let added = new.first(where: { !known.contains($0.id) }) { return Selection(mask: added.id, component: nil) }
        let changed = new.filter { mask in old.first { $0.id == mask.id }.map { $0 != mask } ?? false }
        if changed.count == 1, changed[0].id != selection?.mask { return Selection(mask: changed[0].id, component: nil) }
        return kept(selection, in: new)
    }

    /// `selection` if what it names is still there; its mask if only its component has gone.
    static func kept(_ selection: Selection?, in masks: [Mask]) -> Selection? {
        guard let selection, let mask = masks.first(where: { $0.id == selection.mask }) else { return nil }
        if let component = selection.component, !mask.components.indices.contains(component) {
            return Selection(mask: selection.mask, component: nil)
        }
        return selection
    }
}

extension MaskOperation {
    /// In the panel and in undo's words.
    var title: String {
        switch self {
        case .add: "Add"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        }
    }

    /// A component row's sign.
    var symbol: String {
        switch self {
        case .add: "plus"
        case .subtract: "minus"
        case .intersect: "multiply"
        }
    }
}
