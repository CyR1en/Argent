import ArgentCore
import ArgentRoll
import SwiftUI

/// Where a frame sits in the frame view: as large as the workspace allows above the dock's band,
/// with no margin of its own, 3:2 or upright 2:3, a whole number of device pixels each way and with its corner
/// on one, so the screen shows the render one to one.
struct FrameLayout: Equatable {
    /// The workspace above the dock's band, in points: the frame view's own bounds.
    var area: CGSize
    /// The area's top-left corner in the window, in points.
    var origin: CGPoint = .zero
    var displayScale: CGFloat

    /// The picture's longer side in pixels, the size the frame view renders at: as long as the
    /// area allows, to the nearest pixel.
    func pixels(_ frame: Frame) -> Int {
        let long = frame.info.isPortrait ? min(area.height, area.width * 1.5) : min(area.width, area.height * 1.5)
        // Three warm comparisons fit inside the shared 256 MiB render budget even
        // on a very large display; 4912 x 3275 RGBA8 is less than 64 MiB per image.
        return min(4912, max(1, Int((long * displayScale).rounded())))
    }

    /// The picture's size in points: `pixels` on its longer side and two thirds of them on the
    /// shorter, rounded up as Apple's decoder rounds a 3:2 raw's shorter side.
    func box(_ frame: Frame) -> CGSize { box(frame, pixels: pixels(frame)) }

    /// The same for a picture rendered `long` pixels on its longer side, as a zoomed one is.
    func box(_ frame: Frame, pixels long: Int) -> CGSize {
        let short = (2 * long + 2) / 3
        let size = frame.info.isPortrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
        return CGSize(width: size.width / displayScale, height: size.height / displayScale)
    }

    /// What zooming into `frame` works within, the raw `fullPixels` on its longer side; one not yet
    /// known is taken as the fitted render's.
    func zoomRoom(_ frame: Frame, fullPixels: Int?) -> FrameZoom.Room {
        let fit = pixels(frame)
        return FrameZoom.Room(area: area, fitted: box(frame), fitPixels: fit, fullPixels: fullPixels ?? fit,
                              displayScale: displayScale, fullPixelsKnown: fullPixels != nil)
    }

    /// The point in the area to centre a picture of `size` on, so it sits in the middle with its
    /// top-left corner on a whole device pixel of the window. SwiftUI rounds a layer's edges to
    /// device pixels, so a picture a fraction of a pixel off either way would be drawn a pixel
    /// smaller or larger than it is and resampled.
    func center(of size: CGSize) -> CGPoint {
        func corner(_ start: CGFloat, _ free: CGFloat) -> CGFloat {
            ((start + free / 2) * displayScale).rounded() / displayScale - start
        }
        return CGPoint(x: corner(origin.x, area.width - size.width) + size.width / 2,
                       y: corner(origin.y, area.height - size.height) + size.height / 2)
    }
}

/// One frame as large as the workspace above the dock's band allows, in place of the contact sheet:
/// the camera's full-size JPEG at once, then the film render from the raw. It is fitted, never
/// cropped, with no margin of its own and nothing over it: its title and actions are in the title
/// strip above the workspace, and the dock keeps its band, so the frame's bottom edge always shows at fit.
/// A zoomed frame runs on under the dock to the workspace's rounded edges, and pans no further
/// than brings each of its edges into the area. Hold space for the neutral raw and release for
/// film, or split the two with Compare (`SplitDivider`); the arrow keys move through the frames
/// the sheet shows and Escape goes back to the sheet. Pinch, smart zoom or View > Zoom In zooms
/// in, and two fingers or a drag move round the zoomed frame.
struct FrameView: View {
    let roll: Roll
    let frame: Frame
    /// Its top left in the window as its workspace measures it, where it has: on its way from the sheet and back the
    /// frame view is scaled and moved (`FrameHero`), and what it measured of itself would be on the way too.
    var origin: CGPoint?
    @Environment(RollModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var focused: Bool
    /// The raw's own longer side in pixels, for the source version it was read for.
    @State private var fullPixels: FrameNativeSize?
    /// A drag's movement so far, while one moves the zoomed frame.
    @State private var dragged: CGSize?
    /// The drag under way is not the frame view's to pan with: it began as a press the mask canvas took, or as a Control-click,
    /// which is the photograph's menu. Decided once at its first movement.
    @State private var dragIsCanvasPress: Bool?

    /// Whether a press at `point` is the canvas's: a mask tool's, a handle's or a pin's, or the Remove brush's while its tab
    /// shows. The canvas's own rule, which its hit test asks too (`MaskCanvasView.takesPress`).
    private func canvasTakesPress(at point: CGPoint) -> Bool {
        let editor = model.maskEditor, command = MaskEditor.isCommandHeld
        return editor.canvas?.takesPress(at: point, command: command) ?? editor.canvasTakesPress(at: point, command: command)
    }

    /// Tells the model where the frame is and what zooming works within. Only while it is the open frame's view: one
    /// on its way out, after `closeFrame` has cleared them, would put them back.
    private func publish(_ layout: FrameLayout, _ room: FrameZoom.Room) {
        guard model.isFrameOpen else { return }
        if model.frameLayout != layout { model.frameLayout = layout }
        guard model.frameZoomRoom != room else { return }
        if let previous = model.frameZoomRoom {
            model.frameZoom = model.frameZoom.reframed(from: previous, to: room)
        } else {
            model.frameZoom = model.frameZoom.settled(in: room)
        }
        model.frameZoomRoom = room
    }

    var body: some View {
        let request = FrameSourceRequest(frame: frame.url, source: model.sourceStamp(for: frame))
        GeometryReader { geometry in
            let layout = FrameLayout(area: geometry.size, origin: origin ?? geometry.frame(in: .global).origin,
                                     displayScale: displayScale)
            let room = layout.zoomRoom(frame, fullPixels: fullPixels?.pixels(for: request))
            // A press on the canvas leaves the keyboard with the photograph: arrows, Space and Escape
            // keep working after it, whichever control had the keyboard before.
            FramePicture(frame: frame, layout: layout, zoom: model.frameZoom, room: room, onCanvasPress: { focused = true })
                .id(request)
                .onChange(of: layout, initial: true) { publish(layout, room) }
                .onChange(of: room) { publish(layout, room) }
                // A view on its way out that is wanted again, the frame opened before it had gone, says them again, and
                // takes back the keys the sheet had: it does not appear again. Here, where a view on its way out still
                // hears of the change; the frame view's own body does not.
                .onChange(of: model.isFrameOpen) {
                    publish(layout, room)
                    if model.isFrameOpen { focused = true }
                }
        }
        .background {
            // Under a workspace sheet the trackpad is the sheet's: its licence texts scroll, and the photograph stays put.
            TrackpadEvents(magnify: { if !model.isSheetShown { model.pinchFrame(by: $0, at: $1, ended: $2) } },
                           smartMagnify: { if !model.isSheetShown { model.smartZoomFrame(at: $0) } },
                           scroll: { !model.isSheetShown && model.panFrame(by: $0, ended: $1) })
        }
        .contentShape(Rectangle())
        // SwiftUI feeds this drag and the double-click below the events an AppKit child took as well
        // (measured, P0-S2: a stroke panned a zoomed frame), so they ask the rule the canvas's hit test does;
        // and a Control-click is the photograph's menu (`MaskCanvasView.menu(for:)`), never a pan or a close.
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                let isCanvasPress = dragIsCanvasPress ?? (MaskEditor.isHandlingMenuClick || canvasTakesPress(at: value.startLocation))
                dragIsCanvasPress = isCanvasPress
                guard !isCanvasPress else { return }
                let last = dragged ?? .zero
                dragged = value.translation
                model.panFrame(by: CGSize(width: value.translation.width - last.width,
                                          height: value.translation.height - last.height), ended: false)
            }
            .onEnded { value in
                defer { dragIsCanvasPress = nil }
                guard dragIsCanvasPress != true else { return }
                let last = dragged ?? .zero
                dragged = nil
                model.panFrame(by: CGSize(width: value.translation.width - last.width,
                                          height: value.translation.height - last.height), ended: true)
            })
        .pointerStyle(model.frameZoom.isZoomed ? (dragged == nil ? .grabIdle : .grabActive) : nil)
        .task(id: request) {
            guard let dimensions = await FrameNativeSize.load(request), !Task.isCancelled else { return }
            fullPixels = dimensions
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // Back to the sheet, unless the press was the canvas's or a Control-click's; the surround still closes the frame.
        .gesture(SpatialTapGesture(count: 2).onEnded { value in
            guard !MaskEditor.isHandlingMenuClick, !canvasTakesPress(at: value.location) else { return }
            model.closeFrame()
        })
        .onTapGesture { focused = true }
        // Under a workspace sheet no key is the photograph's, wherever the keys are: Return and Escape go on to
        // the sheet's buttons (`QuickDevelopSheet`, `SubjectModelsSheet`). The model is read as a key comes, not as the view is drawn.
        .workspaceHorizontalArrows { step, _ in
            model.moveSelection(by: step)
            return .handled
        }
        .onKeyPress(.home) {
            guard !model.isSheetShown else { return .ignored }
            model.moveSelection(toLast: false)
            return .handled
        }
        .onKeyPress(.end) {
            guard !model.isSheetShown else { return .ignored }
            model.moveSelection(toLast: true)
            return .handled
        }
        .onKeyPress(.escape) {
            guard !model.isSheetShown else { return .ignored }
            // The press under way, the tool in hand and the selection go before the frame does; on the Remove tab, what is being
            // selected and then the newest run.
            if !model.maskEditor.escape(), !RemovePhotograph.escape(model) { model.closeFrame() }
            return .handled
        }
        // With a gradient tool in hand and no pointer to draw with, Return places one. On the Remove tab it removes what is
        // selected, as the tab's button does.
        .onKeyPress(.return) {
            guard !model.isSheetShown else { return .ignored }
            if let frame = RemovePhotograph.frame(model), RemovePhotograph.canRemove(on: frame, model: model) {
                model.commitRemoval(on: frame)
                return .handled
            }
            return model.placeArmedGradient() ? .handled : .ignored
        }
        // The Remove brush's size, by the masks' brush's own keys. Their menu items are the masks' brush's and are disabled here,
        // and a disabled item passes its key on (measured, P0-S2), so the photograph takes it.
        .onKeyPress(keys: ["[", "]"]) { press in
            guard !model.isSheetShown, RemovePhotograph.frame(model) != nil else { return .ignored }
            model.stepBrush { press.key == "]" ? $0.larger() : $0.smaller() }
            return .handled
        }
        // The photograph's own key, never a menu's: a focused slider would pass Delete on to the menu.
        .onKeyPress(keys: MaskKeys.delete) { _ in
            !model.isSheetShown && model.maskEditor.deleteSelection() ? .handled : .ignored
        }
        // Compare: the neutral raw while space is down, film again when it comes up; the key's release always ends it.
        .onKeyPress(keys: [.space], phases: [.down, .repeat, .up]) { press in
            guard !model.isSheetShown || press.phase == .up else { return .ignored }
            model.isComparing = press.phase != .up
            return .handled
        }
        .onAppear { focused = true; model.films?.setFocusedFrame(frame) }
        .onChange(of: frame.url) { model.films?.setFocusedFrame(frame) }
        .onChange(of: model.maskEditor.photographFocusRequests) { focused = true }
        .restoreWorkspaceFocus { focused = true }
        // A key-up that goes to another window would leave the neutral raw showing.
        .onChange(of: activeState) {
            if activeState != .key { model.isComparing = false; model.isComparingAuto = false; model.lightClipping = nil }
        }
        .onDisappear {
            model.isComparing = false; model.isComparingAuto = false; model.isAutoComparisonReady = false; model.lightClipping = nil
            model.films?.setFocusedFrame(nil)
            model.maskEditor.pictureHidden()
            model.framePictureShown = nil
        }
    }

}

#if DEBUG
/// When the frame view last put a picture up, for the drive hook's latency measurements: the
/// settings a new film was rendered with, and when the Auto comparison appeared.
@MainActor enum FrameShowProbe {
    static var film: (settings: DevelopSettings, time: CFTimeInterval)?
    static var automaticShown: CFTimeInterval?
    /// The latest films put up, oldest first: the frame, whether from a refined decode, when, the film's longer side and its time
    /// from the request to the film put up.
    static var shown: [(frame: URL, refined: Bool, time: CFTimeInterval, side: Int, seconds: CFTimeInterval)] = []
    /// The last film put up, by identity rather than held, so the drive hook can find it on screen
    /// without keeping it in memory.
    static var lastFilm: (frame: URL, image: ObjectIdentifier, width: Int, height: Int, time: CFTimeInterval)?
    /// What the frame view draws on top, as of its last body: the frame, which picture (film, neutral,
    /// automatic, preview or placeholder) and the picture, the one its state already holds.
    static var displayed: (frame: URL, kind: String, image: CGImage?)?

    static func record(_ frame: URL, refined: Bool, side: Int = 0, seconds: CFTimeInterval = 0) {
        shown.append((frame, refined, CACurrentMediaTime(), side, seconds))
        if shown.count > 256 { shown.removeFirst(shown.count - 256) }
    }
}
#endif

/// What the frame view's refinement waits on: the frame and its size, its film being up at that
/// size outside a develop, whether a decode for it is kept (a frame shown from the render cache
/// has none until one is made again) and whether that decode is refined already.
private struct RefineRequest: Equatable {
    var frame: URL
    var pixelSize: Int
    var source: SourceStamp?
    var filmShown: Bool
    var developing: Bool
    var decodeKept: Bool
    var refined: Bool
}

/// Lightroom's clipping view of one film image, while a Light slider asks for one.
private struct ClippingPicture {
    var kind: LightClipping
    var image: CGImage
}

/// What the clipping view is made from: the view asked for and the film on screen.
private struct ClippingRequest: Equatable {
    var kind: LightClipping?
    var film: ObjectIdentifier?
}

/// The inspector's histogram: the film it measures, and whether the inspector is there to show it.
private struct HistogramRequest: Equatable {
    var film: ObjectIdentifier?
    var shown: Bool
}

/// The frame's pictures, stacked: the embedded JPEG (or, for the first instant, the sheet's
/// thumbnail), the film render over it, and the neutral raw over both while comparing, the whole of
/// it or, split, the part left of the divider, placed in the area by `FrameLayout` and zoomed into
/// by `FrameZoom`. The split's divider and the comparison's tags are drawn over it here, where the
/// picture's rectangle is known. Its identity is the frame, so
/// moving through the roll starts each frame afresh, from whatever the caches already hold.
private struct FramePicture: View {
    let frame: Frame
    let layout: FrameLayout
    let zoom: FrameZoom
    let room: FrameZoom.Room
    /// The mask canvas took a press.
    let onCanvasPress: @MainActor () -> Void

    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var preview: CGImage?
    @State private var film: CGImage?
    /// The size `film` was rendered at, so only a resize waits before rendering again.
    @State private var filmPixels: Int?
    /// The settings `film` was rendered with. During a drag the model is often a step ahead of the
    /// film on screen, and the clipping view must judge the film against its own print's ends.
    @State private var filmSettings: DevelopSettings?
    /// The colour space `film` is in, for the same reason: the print's ends are that space's codes.
    @State private var filmSpace: OutputSpace?
    /// Changes with every new film image, so the old one fades out under the new one.
    @State private var filmGeneration = 0
    /// The settings of the film render under way, while one is. The film's request keeps them until that render ends, so a
    /// drag that changes the settings at each step does not cancel each render before it is shown; the next render takes
    /// the settings as they are by then. Unpaced, once a step no longer cost the main thread a refresh, a Light slider's drag
    /// put up 1 to 4 films in 8 s (T9).
    @State private var printing: DevelopSettings?
    /// The picture a new film replaces, held opaque under it until the film is fully in. Two
    /// pictures fading across each other let the placeholder through, a quarter of it halfway, a
    /// blink each time a zoom or a refinement brought a new render.
    @State private var outgoing: CGImage?
    /// The clipping view of the latest film, over it while `RollModel.lightClipping` asks for that
    /// view. The last one made stays up until the next replaces it, so a drag never flickers back to film.
    @State private var clipping: ClippingPicture?
    /// The print's ends last found for this frame's histogram, measured with until this film's own come.
    @State private var histogramLimits: PrintLimits?
    @State private var neutral: CGImage?
    @State private var automatic: CGImage?
    @State private var automaticRequest: FilmRequest?
    /// The size whose decode has been refined, the develop's own decode area-resized
    /// (`FilmPreviews.refineFrame`): the film, the Auto comparison and the neutral raw are then
    /// made again from it.
    @State private var refinedPixels: Int?
    /// The frame that was open before this one, as it was last shown: held under this frame's pictures while they fade in
    /// over it, a tenth of a second, so one frame gives way to the next and nothing of the surround shows between them.
    /// Only with a picture of this frame to hand, and not while an arrow key is held (`takeCached`).
    @State private var leaving: CGImage?
    /// How much of this frame's pictures shows over `leaving`.
    @State private var arrival = 1.0

    private var fitPixels: Int { layout.pixels(frame) }
    /// The pictures' longer side (`FrameGeometry.renderPixels`).
    private var pixels: Int {
        FrameGeometry.renderPixels(layout: layout, zoom: zoom, room: room, frame: frame, isDeveloping: model.isDeveloping)
    }
    private var refined: Bool { refinedPixels == pixels }
    /// The embedded JPEG decodes at the fitted raw decode's size.
    private var previewPixels: Int { FilmPreviews.frameDecodeSide(forPixels: fitPixels) }

    private var stock: Int? { model.films == nil ? nil : model.stockIndex(for: frame) }

    private var currentAutomaticRequest: FilmRequest? {
        stock.map { FilmRequest(frame: frame.url, stock: $0, settings: model.automaticSettings(for: frame, stock: $0),
            space: model.output.space, pixelSize: pixels, analyzed: model.analysis(for: frame) != nil, source: model.sourceStamp(for: frame),
            refined: refined) }
    }

    /// The film's and the neutral raw's sizes in pixels, those on screen (`FrameGeometry.make`).
    private var renderedSizes: [CGSize] {
        [film, neutral].compactMap { $0 }.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// The picture's rectangle as the mask canvas needs it: afresh from the model at each event, since
    /// a scroll the window's monitor handled a moment ago has moved `frameZoom` before SwiftUI draws it.
    private var liveGeometry: @MainActor () -> FrameGeometry {
        { [model, frame, layout, room, rendered = renderedSizes, neutralUp = neutral != nil] in
            var live = FrameGeometry.make(layout: model.frameLayout ?? layout, zoom: model.frameZoom, room: model.frameZoomRoom ?? room,
                                          frame: frame, isDeveloping: model.isDeveloping, rendered: rendered)
            // What `splits` says in the body, for the event in hand: the neutral side is not a tool's.
            if neutralUp, model.isSplitComparing, !model.isComparing { live.filmEdge = SplitGeometry(live).dividerX(at: model.splitPosition) }
            return live
        }
    }

    private var shownClipping: ClippingPicture? {
        clipping.flatMap { $0.kind == model.lightClipping ? $0 : nil }
    }

    /// The Auto or Original starting point is on screen, while the inspector's Compare holds it.
    private var showsAutomatic: Bool {
        model.isComparingAuto && automaticRequest == currentAutomaticRequest && automatic != nil
    }

    /// What the comparison's tags say now (`CompareTags`); nothing without stocks, which leave no
    /// film and no neutral raw to compare.
    private var compareTags: CompareTags {
        guard model.films != nil else { return .none }
        return CompareTags.shown(splitting: model.isSplitComparing, holdingSpace: model.isComparing,
                                 neutralReady: neutral != nil,
                                 startingPoint: model.isComparingAuto ? (model.startingPoint(for: frame) == .original ? "Original" : "Auto") : nil,
                                 startingPointReady: showsAutomatic,
                                 filmName: film != nil ? (model.stockName(for: frame) ?? "Film") : "Camera preview")
    }

    /// Whether the soft grounding shadow behind the photograph should show: only alongside Ambient
    /// Surround, never under 18% Gray Surround, Increase Contrast, or an empty placeholder.
    private var showsAmbientShadow: Bool {
        let appearance = AppearanceSettings.shared
        return !model.graySurround
            && appearance.showsAmbientSurround
            && appearance.showsAmbientSurroundShadow
            && contrast != .increased
            && (film != nil || preview != nil || outgoing != nil)
    }

    /// Generous padding around the shadow rect inside the compositing group so the 24 pt blur tail
    /// is never clipped when knocking out the interior.
    private static let ambientShadowPad: CGFloat = 64

    /// Soft grounding shadow locked to the animated photo rectangle so releasing a pinch-out or
    /// zooming never exposes a detached shadow box on the ambient surround behind it. Two sibling
    /// single-shadow rounded rectangles avoid nested offscreen shadow rasterization, stay 1 pt
    /// concentric inside the photo's rounded corners so no dark fringe shows at fractional scales,
    /// and punch out their solid interior so nothing black ever bleeds through a fading photo.
    @ViewBuilder private var ambientShadow: some View {
        let appearance = AppearanceSettings.shared
        let isDark = appearance.palette.isDark
        let scale = 0.45 + 0.55 * appearance.ambientSurroundIntensity
        let wideOpacity = (isDark ? 0.34 : 0.14) * scale
        let tightOpacity = (isDark ? 0.24 : 0.10) * scale
        let shape = RoundedRectangle(cornerRadius: max(0, Metrics.cornerRadius - 1))
        let inset = Self.ambientShadowPad + 1
        ZStack {
            shape.fill(Color.black)
                .padding(inset)
                .shadow(color: Color.black.opacity(wideOpacity), radius: isDark ? 24 : 20, y: 2)
            shape.fill(Color.black)
                .padding(inset)
                .shadow(color: Color.black.opacity(tightOpacity), radius: isDark ? 5 : 4, y: 0)
            shape.fill(Color.black)
                .padding(inset)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    var body: some View {
        let showsNeutral = model.isComparing && neutral != nil, isFlagged = model.isFlagged(frame)
        // Split: the neutral raw left of the divider, while Space does not show the whole of it.
        let isSplit = model.isSplitComparing && neutral != nil
        let splits = isSplit && !model.isComparing
        let geometry = FrameGeometry.make(layout: layout, zoom: zoom, room: room, frame: frame,
                                          isDeveloping: model.isDeveloping, rendered: renderedSizes)
        let shown = geometry.picture.size
        // While rubber-band pinching below the minimum scale, keep the ambient colour field anchored
        // to the settled box so the surround stays calm instead of pumping during the spring bounce.
        let surroundPhotoRect: CGRect = if zoom.scale < room.minimumScale {
            FrameGeometry.make(layout: layout, zoom: zoom.settled(in: room), room: room, frame: frame,
                               isDeveloping: model.isDeveloping, rendered: renderedSizes).picture
        } else {
            geometry.picture
        }
        let visibleWorkspace = CGRect(x: 0, y: 0, width: layout.area.width,
                                      height: layout.area.height + Graphite.Metric.dockBand)
        let shadowRect = showsAmbientShadow
            ? FrameSurroundController.clampedShadowRect(for: geometry.picture, visibleWorkspace: visibleWorkspace)
            : nil
        let split = SplitGeometry(geometry)
        #if DEBUG
        let _ = noteDisplayed(showsNeutral: showsNeutral, splits: splits)
        #endif
        ZStack {
            if let shadowRect {
                let shadowOpacity: Double = if let leaving {
                    (leaving.height > leaving.width) == frame.info.isPortrait ? 1 : 0
                } else {
                    1
                }
                ambientShadow
                    .frame(width: shadowRect.width + Self.ambientShadowPad * 2,
                           height: shadowRect.height + Self.ambientShadowPad * 2)
                    .opacity(shadowOpacity)
                    .animation(reduceMotion ? nil : Graphite.Motion.ease(0.11), value: shadowOpacity)
                    .position(x: shadowRect.midX, y: shadowRect.midY)
            }
            if let leaving {
                // The last frame, where it was fitted.
                picture(leaving)
                    .frame(width: layout.area.width, height: layout.area.height)
                    .accessibilityHidden(true)
                    .transition(.identity)
            }
            // The split comes in from the picture's left edge to where its divider stands, and goes back there.
            Animated(value: isSplit ? 1 : 0) { reveal in
                pictures(showsNeutral: showsNeutral,
                         neutralWidth: wipes(reveal) ? split.neutralWidth(at: splitPosition(reveal, in: split)) : nil)
            }
            .animation(reduceMotion ? nil : Graphite.Motion.wipe, value: isSplit)
            .frame(width: shown.width, height: shown.height)
            .opacity(arrival)
            .modifier(Loading(picture: self, showsNeutral: showsNeutral))
            .accessibilityElement()
            .accessibilityLabel(ContactSheet.accessibilityText(frame) + (model.hasManualAdjustments(frame) ? ", manually adjusted" : model.isOverridden(frame) ? ", own settings" : "")
                                + (isFlagged ? ", flagged" : ""))
            .accessibilityValue(accessibilityValue(showsNeutral: showsNeutral, splits: splits))
            .accessibilityAddTraits(.isImage)
            .accessibilityHint("Hold Space for the whole neutral RAW. Left and right arrows move through the frames shown. Escape returns to the contact sheet.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.moveSelection(by: 1)
                case .decrement: model.moveSelection(by: -1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: model.isComparing ? "Show film" : "Show the neutral raw") { model.isComparing.toggle() }
            .accessibilityAction(named: isFlagged ? "Unflag" : "Flag") { model.toggleFlag(frame) }
            // Copy and Paste Adjustments, as the photograph's menu has them, by name for VoiceOver. Offered always, as Flag is:
            // whether one can act is asked as it is performed, not here, where it would read the clipboard each time a stroke or a
            // drag draws the picture again.
            .accessibilityAction(named: "Copy Adjustments") { PhotographMenu.copyForVoiceOver(frame, model: model) }
            .accessibilityAction(named: "Paste Adjustments") { PhotographMenu.pasteForVoiceOver(frame, model: model) }
            .accessibilityAction(.escape) { model.closeFrame() }
            // A zoomed picture runs on to the workspace's rounded edges, which cut it; the frame
            // with its own settings is marked on the filmstrip, as on the sheet, not under it.
            .position(geometry.center)
            MaskOverlayView(frame: frame, geometry: geometry, neutralWidth: splits ? split.neutralWidth(at: model.splitPosition) : nil,
                            decode: MaskOverlayDecode(pixels: filmPixels == pixels ? filmPixels : nil, refined: refined))
            // The Remove tab's selection, stroke and hovered outline, where the masks' overlay is while that tab shows.
            RemoveOverlayView(frame: frame, geometry: geometry, neutralWidth: splits ? split.neutralWidth(at: model.splitPosition) : nil)
            // The masks' pins, over the overlay and the handles; the canvas under them takes their presses.
            MaskPinsView(frame: frame, geometry: geometry)
            // Under the divider and the tags, so the divider's drag still wins; it takes the pointer only
            // while a tool is armed or on a handle, and otherwise is not there for any event.
            MaskCanvas(editor: model.maskEditor, geometry: liveGeometry, onPress: onCanvasPress)
                .frame(width: layout.area.width, height: layout.area.height)
                .accessibilityHidden(true)
            Animated(value: isSplit ? 1 : 0) { reveal in
                ZStack {
                    if wipes(reveal) {
                        SplitDivider(geometry: split, position: reveal < 1 ? splitPosition(reveal, in: split) : nil, reveal: reveal)
                    }
                    CompareTagsOverlay(tags: compareTags, geometry: split, position: splitPosition(reveal, in: split), reveal: reveal)
                }
            }
            .animation(reduceMotion ? nil : Graphite.Motion.wipe, value: isSplit)
        }
        .frame(width: layout.area.width, height: layout.area.height)
        .coordinateSpace(.named(FramePictureSpace.name))
        .onChange(of: surroundPhotoRect, initial: true) { _, rect in
            model.frameSurround.updateGeometry(photoRect: rect, for: frame.url)
        }
        // A workspace on its way to another width, as the inspector comes or goes, moves none of this with it. The film
        // is made again for the new size and is where it will be at once; what went there on the workspace's spring would
        // be beside it meanwhile, the neutral raw's half of a split at one size and the film's at another.
        .transaction(value: layout.area) { $0.animation = nil }
    }

    /// Whether the split shows, `reveal` of the way in: not while Space shows the whole neutral raw, which is at once.
    private func wipes(_ reveal: CGFloat) -> Bool {
        reveal > 0.001 && !model.isComparing && neutral != nil
    }

    /// Where the divider is drawn `reveal` of the way in: from the picture's left edge to where it stands.
    private func splitPosition(_ reveal: CGFloat, in split: SplitGeometry) -> CGFloat {
        guard reveal < 1, split.area.width > 0 else { return model.splitPosition }
        let edge = split.span.lowerBound / split.area.width
        return edge + (model.splitPosition - edge) * max(0, reveal)
    }

    private func accessibilityValue(showsNeutral: Bool, splits: Bool) -> String {
        let starting = model.startingPoint(for: frame) == .original ? "Original starting point" : "Auto starting point"
        if showsNeutral { return "Neutral RAW" }
        let right = model.isComparingAuto ? starting
            : shownClipping.map { $0.kind == .highlights ? "Clipped highlights" : "Clipped shadows" }
            ?? (film != nil ? (model.stockName(for: frame) ?? "Film") : "Camera preview")
        return splits ? "Split: Neutral RAW left of the divider, \(right) right of it" : right
    }

    /// The layers; `neutralWidth`, while split, how much of the picture from its left edge shows the
    /// neutral raw, the rest the film (or the starting point) under it.
    @ViewBuilder private func pictures(showsNeutral: Bool, neutralWidth: CGFloat?) -> some View {
        ZStack {
            if let preview {
                picture(preview)
            } else if film == nil, outgoing == nil {
                // Put where the picture is at once while no image has arrived yet: once film or outgoing
                // is on screen, a non-animated placeholder underneath snaps ahead to the settled box on
                // zoom spring animations (e.g. releasing a pinch-out) and flashes gray round the photo.
                RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(Graphite.placeholder)
                    .transaction { $0.animation = nil }
            }
            if let outgoing {
                picture(outgoing).transition(.identity)
            }
            if let film {
                picture(film)
                    .id(filmGeneration)
                    .transition(.opacity)
            }
            if let shownClipping {
                picture(shownClipping.image)
            }
            if model.isComparingAuto, automaticRequest == currentAutomaticRequest, let automatic {
                picture(automatic).onAppear {
                    #if DEBUG
                    FrameShowProbe.automaticShown = CACurrentMediaTime()
                    #endif
                }
            }
            // Compare is instant: no fade between film and the neutral raw.
            if showsNeutral, let neutral {
                picture(neutral)
            } else if let neutralWidth, let neutral {
                picture(neutral)
                    .mask(alignment: .leading) { Rectangle().frame(width: neutralWidth) }
            }
        }
    }

    #if DEBUG
    /// Records what the body draws on top, for the drive hook's `shown`.
    /// Split, the kind is the right side's, after "split-": the neutral raw is only part of the top.
    private func noteDisplayed(showsNeutral: Bool, splits: Bool) {
        let clipped = shownClipping.map { ("clipping-\($0.kind == .highlights ? "highlights" : "shadows")", Optional($0.image)) }
        let top: (String, CGImage?) = showsNeutral ? ("neutral", neutral) : showsAutomatic ? ("automatic", automatic)
            : clipped ?? (film != nil ? ("film", film) : preview != nil ? ("preview", preview) : ("placeholder", nil))
        FrameShowProbe.displayed = (frame.url, splits ? "split-" + top.0 : top.0, top.1)
    }
    #endif

    /// What loads the pictures and keeps them current, apart from the body so it type-checks.
    private struct Loading: ViewModifier {
        let picture: FramePicture
        let showsNeutral: Bool

        func body(content: Content) -> some View {
            let view = picture, frame = picture.frame, model = picture.model
            content
                .onAppear(perform: view.takeCached)
                .onChange(of: showsNeutral, initial: true) { model.isNeutralShown = showsNeutral }
                .task(id: PreviewRequest(frame: frame.url, pixelSize: view.previewPixels, source: model.sourceStamp(for: frame))) { await view.loadPreview() }
                .task(id: view.stock.map { FilmRequest(frame: frame.url, stock: $0, settings: view.printing ?? model.printSettings(for: frame, stock: $0),
                                                       space: model.output.space, pixelSize: view.pixels, analyzed: model.isMeasured(frame),
                                                       source: model.sourceStamp(for: frame), refined: view.refined) }) { await view.loadFilm() }
                .task(id: PreviewRequest(frame: frame.url, pixelSize: view.pixels, source: model.sourceStamp(for: frame),
                                         refined: view.refined, space: model.output.space, lens: view.pictureLensSettings)) { await view.loadNeutral() }
                .task(id: RefineRequest(frame: frame.url, pixelSize: view.pixels, source: model.sourceStamp(for: frame),
                                        filmShown: view.film != nil && view.filmPixels == view.pixels,
                                        developing: model.isDeveloping,
                                        decodeKept: model.films?.keepsFrameDecode(frame, lens: view.pictureLensSettings, pixels: view.pixels) == true,
                                        refined: view.refined)) { await view.refine() }
                // A decode for another size starts scaled again.
                .onChange(of: view.pixels) { view.refinedPixels = nil }
                // A memory setting change that switches RAW 9's develop tile drops kept RAW 9 refinements.
                .onChange(of: model.developMemory.choice) {
                    if model.films?.isFrameDecodeRefined(frame, lens: view.pictureLensSettings, pixels: view.pixels) != true {
                        view.refinedPixels = nil
                    }
                }
                .task(id: view.currentAutomaticRequest) { await view.loadAutomatic() }
                .task(id: ClippingRequest(kind: model.lightClipping, film: view.film.map(ObjectIdentifier.init))) {
                    await view.loadClipping()
                }
                .task(id: view.automaticRequest) {
                    guard let request = view.automaticRequest, let image = view.automatic else { return }
                    let histogram = await Task.detached(priority: .utility) { CurveHistogram.measure(image) }.value
                    guard !Task.isCancelled, request == view.automaticRequest, request == view.currentAutomaticRequest,
                          model.shownFrame?.url == frame.url else { return }
                    model.curveHistogram = histogram
                    model.curveHistogramFrame = frame.url
                }
                // The inspector's histogram, of the film as it is shown, again for each film an edit brings;
                // none measured while the inspector is closed.
                .task(id: HistogramRequest(film: view.film.map(ObjectIdentifier.init), shown: model.isAdjustmentsShown)) {
                    await view.loadHistogram()
                }
                // A frame opened again after its stock or source changed elsewhere starts without the old one.
                .onDisappear {
                    if model.frameHistogramFrame == frame.url { model.frameHistogram = nil; model.frameHistogramFrame = nil }
                }
                .onChange(of: view.currentAutomaticRequest, initial: true) { _, request in
                    model.isAutoComparisonReady = view.automaticRequest != nil && view.automaticRequest == request
                }
        }
    }

    private func picture(_ image: CGImage) -> some View {
        Image(decorative: image, scale: layout.displayScale)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
    }

    private var pictureLensSettings: LensSettings {
        model.isSplitComparing ? model.lensSettings(for: frame) : model.manualAdjustments(for: frame).lens
    }

    /// The best pictures already in memory: the film and neutral, else the JPEG or largest thumbnail.
    private func takeCached() {
        guard SourceStamp.of(frame.url) == model.sourceStamp(for: frame) else { return }
        if let films = model.films, let stock {
            let settings = model.printSettings(for: frame, stock: stock), space = model.output.space
            film = films.cachedFrameFilm(frame, stock: stock, settings: settings, space: space, pixels: pixels)
            filmPixels = film == nil ? nil : pixels
            filmSettings = film == nil ? nil : settings
            filmSpace = film == nil ? nil : space
            if film != nil { model.maskEditor.pictureShown(for: frame, settings: settings) }
            neutral = films.cachedFrameNeutral(frame, lens: settings.lens, space: space, pixels: pixels)
        }
        if film == nil {
            preview = model.thumbnails.cachedFullSize(frame, maxPixelSize: previewPixels) ?? largestThumbnail()
        }
        fadeFromLastFrame()
    }

    /// Starts this frame's pictures fading in over the frame that was open before it, when there was one and this frame
    /// has a picture to show; a step that comes within `stepHold` of the last, as an arrow key held down sends them,
    /// cuts as it always has, so a run through the roll stays sharp.
    private func fadeFromLastFrame() {
        let now = CACurrentMediaTime(), last = model.framePictureShown
        let isHeld = now - model.lastFrameStep < Self.stepHold
        model.lastFrameStep = now
        let isInitialOpen = last == nil
        let surroundPacing: FrameSurroundMotion.Pacing = isInitialOpen ? .instant : (isHeld ? .live : .step)
        notePicture(pacing: surroundPacing, seedSynchronously: isInitialOpen)
        guard let last, last.frame != frame.url, !reduceMotion, !isHeld, film != nil || preview != nil else { return }
        leaving = last.image
        arrival = 0
        withAnimation(Graphite.Motion.ease(0.11)) { arrival = 1 } completion: { leaving = nil }
    }

    /// Steps closer together than this are a held key's.
    static let stepHold = Graphite.Motion.runGap

    /// Tells the model what this frame shows, for the next frame to fade in over and for the
    /// ambient surround to sample off the main thread.
    private func notePicture(
        pacing: FrameSurroundMotion.Pacing = .step,
        seedSynchronously: Bool = false,
        space: OutputSpace? = nil
    ) {
        guard let image = film ?? preview else { return }
        model.framePictureShown = (frame.url, image)
        guard AppearanceSettings.shared.showsAmbientSurround, !model.graySurround, contrast != .increased else { return }
        model.frameSurround.submit(
            image: image,
            for: frame.url,
            space: space ?? filmSpace ?? model.output.space,
            pacing: reduceMotion ? .instant : pacing,
            seedSynchronously: seedSynchronously
        )
    }

    private func largestThumbnail() -> CGImage? {
        for pixels in model.cellPixelSizes.sorted(by: >) {
            if let image = model.thumbnails.cached(frame, maxPixelSize: pixels) { return image }
        }
        return nil
    }

    private func loadPreview() async {
        // Once film is up the JPEG is not seen again.
        guard film == nil else { return }
        let source = model.sourceStamp(for: frame)
        guard let image = await model.thumbnails.fullSize(for: frame, maxPixelSize: previewPixels), !Task.isCancelled,
              SourceStamp.of(frame.url) == source
        else { return }
        guard image !== preview else { return }
        // The same picture as the thumbnail it replaces, only sharper, so no fade.
        preview = image
        notePicture(pacing: model.frameSurround.currentSample == nil ? .instant : .live)
    }

    private func loadFilm() async {
        guard let stock, let films = model.films else {
            film = nil
            filmSettings = nil
            filmSpace = nil
            return
        }
        let size = pixels
        let source = model.sourceStamp(for: frame)
        guard SourceStamp.of(frame.url) == source else { return }
        // The film waits for the frame's auto-development measurement, from the sheet's decode as
        // every frame's is, or for its failure; its arrival runs this again.
        if !model.isMeasured(frame) {
            await model.analyze(frame, priority: .veryHigh)
            return
        }
        if model.hasManualAdjustments(frame), model.manualIssue(for: frame) != nil { return }
        let aim = model.printAim(for: frame)
        let settings = model.printSettings(for: frame, stock: stock), space = model.output.space
        let fromRefined = refined
        // During a live resize the old render stays up; render the new size once it
        // settles. Cached choices still pass through frameFilm to cancel obsolete work.
        if films.cachedFrameFilm(frame, stock: stock, settings: settings, space: space, pixels: size) == nil,
           film != nil, filmPixels != size {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        }
        // One render at a time: the request holds these settings until this one ends (`printing`), and a film of settings the
        // model has moved past since is shown all the same, as the step on the way that it is.
        printing = settings
        defer { if printing == settings { printing = nil } }
        let requested = CACurrentMediaTime()
        guard let image = await films.frameFilm(frame, stock: stock, settings: settings, space: space, pixels: size),
              !Task.isCancelled, SourceStamp.of(frame.url) == source, model.output.space == space else { return }
        show(image, at: size, settings: settings, space: space)
        // What the print cost, for the ceiling on a moving gradient's next flushes.
        model.maskEditor.filmShown(for: frame, settings: settings, renderedIn: CACurrentMediaTime() - requested)
        // A develop lets the decodes go; the one made again is scaled until refined in its turn.
        if fromRefined, !films.isFrameDecodeRefined(frame, lens: settings.lens, pixels: size) { refinedPixels = nil }
        #if DEBUG
        FrameShowProbe.film = (settings, CACurrentMediaTime())
        FrameShowProbe.lastFilm = (frame.url, ObjectIdentifier(image), image.width, image.height, CACurrentMediaTime())
        FrameShowProbe.record(frame.url, refined: films.isRefinedFrameFilm(image, frame: frame, stock: stock, settings: settings,
                                                                           space: space, pixels: size),
                              side: max(image.width, image.height), seconds: CACurrentMediaTime() - requested)
        #endif
        if let image = film,
           let request = currentAutomaticRequest, request.settings == settings, request.space == space, request.pixelSize == size {
            automatic = image
            automaticRequest = request
            model.isAutoComparisonReady = true
        }
        model.recordVisibleAutomatic(for: frame, stock: stock, aim: aim, settings: settings)
        await prefetch(films)
    }

    private func show(_ image: CGImage, at size: Int, settings: DevelopSettings, space: OutputSpace) {
        guard image !== film else { return }
        // A removal's change of the picture, against the film on screen: the object is seen to go, or to come back.
        let removalArrives = film != nil && RemovalArrival.isOne(from: filmSettings, to: settings)
        filmPixels = size
        filmSettings = settings
        filmSpace = space
        // The JPEG or the last film stays under the new film until it is fully in.
        let replaced = film ?? preview
        preview = nil
        let isLiveEdit = model.hasManualAdjustments(frame) && !removalArrives
        if isLiveEdit || reduceMotion {
            // No fade, so the picture takes the new film in place: a new identity would put a new view in and
            // place the whole window again for each film of a drag (T9).
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { outgoing = nil; film = image }
        } else {
            outgoing = replaced
            withAnimation(removalArrives ? RemovalArrival.animation : Motion.stateChange) {
                film = image
                filmGeneration += 1
            } completion: {
                if outgoing === replaced { outgoing = nil }
            }
        }
        notePicture(pacing: isLiveEdit ? .live : .step, space: space)
    }

    private func loadAutomatic() async {
        // An untouched frame's film is already its Auto image. Loading it twice would
        // duplicate the first GPU render; loadFilm publishes the shared image instead.
        guard model.hasManualAdjustments(frame), let request = currentAutomaticRequest, request.analyzed,
              let films = model.films, model.manualIssue(for: frame) == nil else { return }
        model.isAutoComparisonReady = automaticRequest == request
        guard let image = await films.frameFilm(frame, stock: request.stock, settings: request.settings, space: request.space,
                                                pixels: request.pixelSize),
              !Task.isCancelled, SourceStamp.of(frame.url) == request.source,
              request == currentAutomaticRequest else { return }
        automatic = image
        automaticRequest = request
        model.isAutoComparisonReady = true
    }

    /// The clipping view of the film on screen, made off the main actor for each new film while one is
    /// asked for (`LightClipping.picture(of:limits:)`), against the print's own ends for the frame's
    /// settings; let go once none is.
    private func loadClipping() async {
        guard let kind = model.lightClipping, let film else {
            clipping = nil
            return
        }
        var limits = PrintLimits.display
        if let films = model.films, let stock,
           let made = await films.printLimits(stock: stock, settings: filmSettings ?? model.printSettings(for: frame, stock: stock),
                                              space: filmSpace ?? model.output.space) {
            limits = made
        }
        guard !Task.isCancelled else { return }
        let image = await Task.detached(priority: .userInitiated) { kind.picture(of: film, limits: limits) }.value
        guard !Task.isCancelled, let image, model.lightClipping == kind else { return }
        clipping = ClippingPicture(kind: kind, image: image)
    }

    /// Measures the film for the inspector's histogram (`FrameHistogram`): at once with the print's ends
    /// last found for this frame, then, once no new film has come for `histogramSettle`, with the ends of
    /// this film's own stock and settings if they differ. Their probe renders, so a drag, whose next film
    /// cancels the wait, asks for none until it pauses.
    private func loadHistogram() async {
        guard model.isAdjustmentsShown, let image = film else { return }
        let settings = filmSettings, space = filmSpace
        func publish(_ limits: PrintLimits) async -> Bool {
            let histogram = await Task.detached(priority: .utility) { FrameHistogram.measure(image, limits: limits) }.value
            guard !Task.isCancelled, image === film, model.shownFrame?.url == frame.url else { return false }
            model.frameHistogram = histogram
            model.frameHistogramFrame = frame.url
            return true
        }
        let known = histogramLimits ?? .display
        guard await publish(known) else { return }
        do { try await Task.sleep(for: Self.histogramSettle) } catch { return }
        guard let films = model.films, let stock,
              let made = await films.printLimits(stock: stock, settings: settings ?? model.printSettings(for: frame, stock: stock),
                                                 space: space ?? model.output.space),
              !Task.isCancelled else { return }
        histogramLimits = made
        if made != known { _ = await publish(made) }
    }

    /// How long the film stays the same before the histogram asks for the print's ends.
    static let histogramSettle = Duration.milliseconds(150)

    /// Once the film is up and the frame has stayed on screen `FilmPreviews.refineSettle`, has the
    /// frame view's decode replaced by the develop's own, so the pictures show what a develop resized
    /// to them shows. Never during a develop, whose memory gate does not count it.
    private func refine() async {
        guard let films = model.films, film != nil, filmPixels == pixels, !refined, !model.isDeveloping else { return }
        let size = pixels
        do { try await Task.sleep(for: FilmPreviews.refineSettle) } catch { return }
        guard await films.refineFrame(frame, lens: pictureLensSettings, pixels: size), !Task.isCancelled, size == pixels else { return }
        refinedPixels = size
    }

    private func loadNeutral() async {
        guard let films = model.films else { return }
        let source = model.sourceStamp(for: frame)
        if neutral != nil {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        }
        guard let image = await films.frameNeutral(frame, lens: pictureLensSettings, space: model.output.space, pixels: pixels), !Task.isCancelled,
              SourceStamp.of(frame.url) == source else { return }
        neutral = image
    }

    /// With this frame on screen, gets the next one in the direction of travel ready to show
    /// as film at once, and the full-size JPEGs on both sides, at low priority: the frames the arrows
    /// move to, among those the sheet shows. Not the film while a develop runs, whose frames that
    /// decode would wait for (`FilmPreviews.decodeTurns`). Each through the stock it shows through, its own or the roll's,
    /// which may not be this frame's: the film is kept by stock and settings.
    private func prefetch(_ films: FilmPreviews) async {
        let (ahead, behind) = model.framesAround(frame)
        let thumbnails = model.thumbnails, space = model.output.space
        var jobs: [(neighbour: Frame, withFilm: Bool)] = []
        for case let (neighbour?, withFilm) in [(ahead, true), (behind, false)] { jobs.append((neighbour, withFilm)) }
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                let neighbour = job.neighbour, pixels = layout.pixels(neighbour)
                let side = FilmPreviews.frameDecodeSide(forPixels: pixels)
                group.addTask { _ = await thumbnails.fullSize(for: neighbour, maxPixelSize: side, priority: .low) }
                guard job.withFilm, !model.isDeveloping else { continue }
                let measured = model.isMeasured(neighbour), stock = model.stockIndex(for: neighbour)
                group.addTask {
                    // Measured from the sheet's decode, as every frame is, then decoded ahead.
                    if !measured { await model.analyze(neighbour, priority: .low) }
                    guard await model.analysis(for: neighbour) != nil else { return }
                    let settings = await model.settings(for: neighbour, stock: stock)
                    _ = await films.frameFilm(neighbour, stock: stock, settings: settings, space: space, pixels: pixels, priority: .low)
                }
            }
        }
    }
}
