import SwiftUI

/// Where the split comparison stands in the frame view's area, in its points from the top left:
/// the area, the picture's rectangle in it as placed and zoomed, and the display's scale. The
/// divider's position is a fraction of the area's width (`RollModel.splitPosition`), so it stays
/// where it was put while the picture zooms and pans under it; the neutral raw is the part of the
/// picture left of it, masked in the picture's own coordinates so both sides keep one geometry.
struct SplitGeometry: Equatable {
    /// The picture as drawn, the rectangle the pictures, the overlay and the mask canvas use too.
    var frame: FrameGeometry

    var area: CGSize {
        get { frame.area }
        set { frame.area = newValue }
    }
    var picture: CGRect {
        get { frame.picture }
        set { frame.picture = newValue }
    }
    var displayScale: CGFloat {
        get { frame.displayScale }
        set { frame.displayScale = newValue }
    }

    init(_ frame: FrameGeometry) { self.frame = frame }

    init(area: CGSize, picture: CGRect, displayScale: CGFloat) {
        frame = FrameGeometry(area: area, picture: picture, displayScale: displayScale)
    }

    /// A tag is left out over a side narrower than this, rather than spill over the divider.
    static let minimumTagSide: CGFloat = 120
    /// How far one press of an arrow, or one VoiceOver swipe, moves the divider: a twentieth of the area.
    static let step: CGFloat = 0.05

    /// The part of the area the picture covers across: the divider never leaves it, so both sides
    /// always show some of the photograph, whether a portrait frame leaves surround beside it or a
    /// zoomed one runs past the area's edges.
    var span: ClosedRange<CGFloat> {
        let low = min(max(0, picture.minX), area.width), high = max(low, min(area.width, picture.maxX))
        return low...high
    }

    /// The divider's x for `position`, inside the picture's span and on a whole device pixel, so
    /// its hairline and the mask's edge are drawn sharp and agree.
    func dividerX(at position: CGFloat) -> CGFloat {
        let x = min(max(position * area.width, span.lowerBound), span.upperBound)
        return (x * displayScale).rounded() / displayScale
    }

    /// How much of the picture's width, from its left edge, shows the neutral raw.
    func neutralWidth(at position: CGFloat) -> CGFloat {
        min(max(dividerX(at: position) - picture.minX, 0), picture.width)
    }

    /// The position a pointer at `x` in the area puts the divider at, kept over the picture.
    func position(atX x: CGFloat) -> CGFloat {
        guard area.width > 0 else { return 0.5 }
        return min(max(x, span.lowerBound), span.upperBound) / area.width
    }

    /// The position that gives the neutral raw `percent` of the picture's width, kept over the
    /// part of the picture the area shows.
    func position(neutralPercent percent: Double) -> CGFloat {
        position(atX: picture.minX + picture.width * CGFloat(min(max(percent, 0), 100)) / 100)
    }

    /// `position` moved by `steps` of `step`, kept over the picture.
    func position(_ position: CGFloat, steppedBy steps: Int) -> CGFloat {
        self.position(atX: (position + CGFloat(steps) * Self.step) * area.width)
    }

    /// Where the tags at the top are centred down: under the top bar, or lower when the picture
    /// starts lower, a little inside its top edge, so they always sit on the photograph.
    func tagY(height: CGFloat, belowBar bar: CGFloat) -> CGFloat {
        max(bar, picture.minY + 12) + height / 2
    }

    /// Where the Space hint is centred down: a little inside the picture's bottom edge, or the
    /// area's when a zoomed picture runs on under the dock.
    func hintY(height: CGFloat) -> CGFloat {
        min(area.height, picture.maxY) - 14 - height / 2
    }

    /// The share of the picture's width the neutral raw has, 0 to 100, for VoiceOver.
    func neutralPercent(at position: CGFloat) -> Int {
        guard picture.width > 0 else { return 0 }
        return Int((neutralWidth(at: position) / picture.width * 100).rounded())
    }

    /// Where each side's tag is centred across: the middle of the picture's part on that side,
    /// as far as the area shows it; `nil` for a side too narrow to carry one.
    func tagCenters(at position: CGFloat) -> (neutral: CGFloat?, film: CGFloat?) {
        let divider = dividerX(at: position)
        let left = divider - span.lowerBound, right = span.upperBound - divider
        return (left >= Self.minimumTagSide ? span.lowerBound + left / 2 : nil,
                right >= Self.minimumTagSide ? divider + right / 2 : nil)
    }
}

/// What the frame view says it is comparing, over the picture: the split's two sides, the whole
/// neutral raw while Space is held, the Auto or Original starting point while the inspector's
/// Compare holds it, or that the neutral raw is still decoding. Each comparison has its own tags,
/// so the three never read alike: the split names both sides and keeps its divider and Space hint,
/// the whole neutral raw and the starting point are each one tag at the top centre.
enum CompareTags: Equatable {
    case none
    /// The split, its sides named: "Neutral RAW" and the right side's picture.
    case split(film: String)
    /// One tag at the top centre: "Neutral RAW", "Auto starting point", "Decoding the neutral RAW…".
    case single(String, busy: Bool = false)

    /// The tags for the frame view's state. `neutralReady` is whether the neutral raw is decoded,
    /// `startingPoint` the starting point ("Auto" or "Original") while the inspector's Compare
    /// holds it, `nil` when it does not, and `startingPointReady` whether its picture is up.
    static func shown(splitting: Bool, holdingSpace: Bool, neutralReady: Bool, startingPoint: String?,
                      startingPointReady: Bool, filmName: String) -> CompareTags {
        if holdingSpace || splitting, !neutralReady { return .single("Decoding the neutral RAW…", busy: true) }
        if holdingSpace { return .single("Neutral RAW") }
        if let startingPoint {
            if !startingPointReady { return .single("Rendering the \(startingPoint) starting point…", busy: true) }
            let name = "\(startingPoint) starting point"
            return splitting ? .split(film: name) : .single(name)
        }
        return splitting ? .split(film: filmName) : .none
    }
}

/// The split comparison's divider: a hairline of the selection colour the height of the picture with a round
/// handle on it, and a wider strip round it that takes the pointer. Dragging it moves the divider
/// and never the photograph; with the keyboard (Tab to it, then the arrows) or VoiceOver's
/// adjustable action it moves a twentieth of the area at a time.
///
/// The handle is a drop of glass that answers the pointer: it swells a little under it, grows and parts its chevrons
/// while it is held, leans the way it is moved, and settles past its rest when let go. The line under it is always
/// where the pointer put it.
struct SplitDivider: View {
    let geometry: SplitGeometry
    /// Where the divider is drawn, as a fraction of the area's width: the model's, unless the split is on its way in
    /// from the picture's edge or back to it (`FramePicture`).
    var position: CGFloat?
    /// How far the split has come in, 0 to 1: the handle grows as the line leaves the picture's edge.
    var reveal: CGFloat = 1
    @Environment(RollModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var isDragging = false
    @State private var isHovered = false
    /// How far the handle leans, by how fast it is moved; it comes back upright when the pointer rests.
    @State private var lean: CGFloat = 0
    @State private var upright: Task<Void, Never>?

    /// The strip each side of the line that takes the pointer; the photograph's menu keeps off it too (`MaskEditor.isOnDivider`).
    static let reach: CGFloat = 10
    private static let handle: CGFloat = 26
    /// The most the handle leans, and the speed in points a second that leans it so far.
    private static let mostLean: CGFloat = 0.24
    private static let leanSpeed: CGFloat = 1400

    var body: some View {
        let x = geometry.dividerX(at: position ?? model.splitPosition)
        let picture = geometry.picture
        // The handle sits in the middle of the picture as far as the area shows it.
        let top = max(0, picture.minY), bottom = min(geometry.area.height, picture.maxY)
        let handleY = (top + bottom) / 2
        ZStack {
            Rectangle()
                .fill(Graphite.selection.opacity(contrast == .increased ? 1 : 0.88))
                .frame(width: 1, height: picture.height)
                .shadow(color: .black.opacity(0.35), radius: 1)
                .position(x: x, y: picture.midY)
            handleView
                .scaleEffect(min(1, max(0, reveal) / 0.6))
                .position(x: x, y: handleY)
                // Held, the handle comes after the pointer on a short spring; the line does not wait for it. Not held, it
                // moves as its line does: when the area's width is on its way to another, beside the inspector, with it.
                .transaction(value: x) { transaction in
                    if isDragging, !reduceMotion { transaction.animation = Graphite.Motion.follow }
                }
        }
        .frame(width: geometry.area.width, height: geometry.area.height)
        .allowsHitTesting(false)
        .overlay(alignment: .topLeading) {
            // What takes the pointer: the line's strip, and the handle.
            Rectangle()
                .fill(Color.clear)
                .frame(width: Self.reach * 2, height: max(0, bottom - top))
                .contentShape(Rectangle())
                .position(x: x, y: (top + bottom) / 2)
                .gesture(drag)
                .onHover { isHovered = $0 }
                .pointerStyle(.columnResize)
                .help("Drag to move the divider between the neutral RAW and film.")
                // A slider to VoiceOver: how much of the picture is the neutral raw, in steps of five.
                .accessibilityRepresentation {
                    Slider(value: Binding(get: { Double(geometry.neutralPercent(at: model.splitPosition)) },
                                          set: { model.splitPosition = geometry.position(neutralPercent: $0) }),
                           in: 0...100, step: 5) {
                        Text("Compare divider")
                    }
                    .accessibilityValue("Neutral RAW \(geometry.neutralPercent(at: model.splitPosition)) percent")
                    .accessibilityHint("Moves the line between the neutral RAW on the left and film on the right.")
                }
                // Tab reaches it; a click does not take the arrows from the frame view.
                .focusable(interactions: .activate)
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { move(by: -1); return .handled }
                .onKeyPress(.rightArrow) { move(by: 1); return .handled }
        }
        .onDisappear { upright?.cancel() }
    }

    private var handleView: some View {
        let moves = !reduceMotion
        // Larger under the pointer, and larger again while it is held.
        let grown: CGFloat = !moves ? 1 : isDragging ? 1.36 : isHovered ? 1.18 : 1
        return HStack(spacing: isDragging && moves ? 5.8 : 1) {
            Image(systemName: "chevron.left")
            Image(systemName: "chevron.right")
        }
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(Graphite.text)
        .frame(width: Self.handle, height: Self.handle)
        // A drop of glass on the divider, answering the pointer.
        .glassEffect(Glass.regular.interactive(), in: Circle())
        .overlay {
            Circle().strokeBorder(Graphite.selection.opacity(focused || isDragging ? 1 : 0.8),
                                  lineWidth: focused ? Graphite.Metric.focusRing : 1)
        }
        .shadow(color: Graphite.shadow, radius: isDragging && moves ? 7 : 4, y: isDragging && moves ? 2 : 1)
        .scaleEffect(x: grown * (1 + lean), y: grown * (1 - lean / 2))
        .animation(moves ? (isDragging ? Graphite.Motion.grab : isHovered ? Graphite.Motion.swell : Graphite.Motion.release) : nil,
                   value: grown)
        .animation(moves ? Graphite.Motion.swell : nil, value: lean)
        .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(FramePictureSpace.name))
            .onChanged { value in
                isDragging = true
                model.splitPosition = geometry.position(atX: value.location.x)
                lean(with: value.velocity.width)
            }
            .onEnded { value in
                isDragging = false
                model.splitPosition = geometry.position(atX: value.location.x)
                upright?.cancel()
                lean = 0
            }
    }

    /// Leans the handle by how fast it is moved, and stands it up once no move has come for a moment: a pointer held
    /// still sends none.
    private func lean(with speed: CGFloat) {
        guard !reduceMotion else { return }
        let wanted = min(Self.mostLean, abs(speed) / Self.leanSpeed)
        if abs(wanted - lean) > 0.02 { lean = wanted }
        upright?.cancel()
        upright = Task {
            try? await Task.sleep(for: .milliseconds(90))
            if !Task.isCancelled { lean = 0 }
        }
    }

    private func move(by steps: Int) {
        model.splitPosition = geometry.position(model.splitPosition, steppedBy: steps)
    }
}

/// The coordinate space of the frame view's area, where the picture is placed and the divider drags.
enum FramePictureSpace {
    static let name = "framePicture"
}

/// The comparison's tags over the frame view's area (`CompareTags`): near its top, centred
/// on each side of the split or on the area, and in the split the Space hint near the bottom. A tag arrives as glass
/// does (`AnyTransition.arrives`) and leaves on a short fade; the split's wait until its divider has come in.
struct CompareTagsOverlay: View {
    let tags: CompareTags
    let geometry: SplitGeometry
    let position: CGFloat
    /// How far the split has come in, 0 to 1 (`FramePicture`).
    var reveal: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The least room above the tags: the workspace's content edge, now that nothing floats over the
    /// top of the frame.
    private static let bar = Graphite.Metric.edge
    /// An OverlayTag's height.
    private static let height: CGFloat = 26

    var body: some View {
        let top = geometry.tagY(height: Self.height, belowBar: Self.bar)
        ZStack(alignment: .topLeading) {
            switch tags {
            case .none:
                EmptyView()
            case .single(let text, let busy):
                tag(text, busy: busy)
                    .position(x: geometry.area.width / 2, y: top)
                    .transition(.arrives)
            case .split(let film):
                let centers = geometry.tagCenters(at: position)
                // Once the divider is most of the way in, so no tag stands over a side still closed.
                let shown = Double(min(1, max(0, (reveal - 0.45) / 0.4)))
                Group {
                    if let neutral = centers.neutral {
                        tag("Neutral RAW").position(x: neutral, y: top)
                    }
                    if let right = centers.film {
                        tag(film).position(x: right, y: top)
                    }
                    OverlayTag(text: "Hold Space for the whole neutral RAW")
                        .fixedSize()
                        .position(x: geometry.area.width / 2, y: geometry.hintY(height: Self.height))
                        .accessibilityHidden(true)
                }
                .opacity(shown)
                .transition(.arrives)
            }
        }
        .frame(width: geometry.area.width, height: geometry.area.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : (tags == .none ? Graphite.Motion.quick : Graphite.Motion.arrive), value: tags)
    }

    @ViewBuilder private func tag(_ text: String, busy: Bool = false) -> some View {
        if busy {
            // An OverlayTag with a spinner in place of its symbol.
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                Text(verbatim: text)
            }
            .font(Graphite.Typeface.small)
            .foregroundStyle(Graphite.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .graphiteFloating(cornerRadius: 7)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
        } else {
            OverlayTag(text: text)
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(text)
        }
    }
}
