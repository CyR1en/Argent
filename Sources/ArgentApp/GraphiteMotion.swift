import AppKit
import SwiftUI

// The pieces the interface's motion is made from (`Graphite.Motion`; Roll workflow section 24): a number on an animation of its
// own, a drop that stretches as it travels, the light under the pointer on glass, one hover highlight shared by a dock's
// controls, and how glass arrives. Each stands still with Reduce Motion.

// MARK: - A number on its own animation

/// A number on an animation of its own: `content` is drawn again at each step from the last value to this one. Two of them,
/// one inside the other, give what one transaction cannot: two numbers of one shape that move differently (`Drop`).
/// Only for something small; its content is made again at every display frame while it moves.
struct Animated<Content: View>: View, Animatable {
    var value: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    nonisolated var animatableData: CGFloat {
        get { value }
        set { value = newValue }
    }

    var body: some View { content(value) }
}

// MARK: - A run of changes

/// Tells a change that stands by itself from one of a run, each within `Graphite.Motion.runGap` of the one before: a
/// held arrow key's steps through the frames, or the values a drag sends. What animates to a change by itself shows a
/// run as it comes; animating after each it would trail the run, and draw at every display frame for as long as it lasts.
@MainActor
final class ChangePace<Value: Equatable> {
    private var last: (value: Value, at: CFTimeInterval, isInRun: Bool)?
    private let now: () -> CFTimeInterval

    /// `now` is the clock, in seconds; a test gives its own.
    init(now: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.now = now
    }

    /// Whether `value` came as one of a run: it is not the value before, and follows it within the gap. Asked again
    /// about the same value it answers the same, so a view may ask each time it is drawn; the first value is no run's.
    func isInRun(_ value: Value) -> Bool {
        if let last, last.value == value { return last.isInRun }
        let time = now()
        let isInRun = last.map { time - $0.at < Graphite.Motion.runGap } ?? false
        last = (value, time, isInRun)
        return isInRun
    }
}

// MARK: - A drop

/// Where something starts and ends along one axis.
struct Span: Equatable, Sendable {
    var start: CGFloat
    var end: CGFloat

    var length: CGFloat { end - start }
    var mid: CGFloat { (start + end) / 2 }

    /// How far past `rest` it is stretched, 0 at rest and 1 at twice as long.
    func stretch(from rest: CGFloat) -> CGFloat {
        rest > 0 ? min(max((length - rest) / rest, 0), 1) : 0
    }
}

/// Something that goes from one place to the next as a drop of liquid does: the edge in front on a quicker spring than the
/// one behind, so it stretches on the way and gathers itself where it lands. The chosen segment's thumb, the rail's lens and a
/// dock's hover highlight are drops.
///
/// `id` is what it is on. Going to another is the drop's move; the same one in another place, as a window's resize leaves it,
/// is put there at once.
struct Drop<ID: Equatable, Content: View>: View {
    let id: ID
    let span: Span
    @ViewBuilder let content: (Span) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Shown?

    private struct Shown: Equatable {
        var id: ID
        var span: Span
        var start: Animation?
        var end: Animation?
    }

    private struct Target: Equatable {
        var id: ID
        var span: Span
    }

    var body: some View {
        // What it was last on, until `onChange` below has chosen each edge's spring for the way to the new one, and then
        // that move; the same thing in another place, at once.
        let now = shown.flatMap { $0.id != id || $0.span == span ? $0 : nil } ?? Shown(id: id, span: span)
        Animated(value: now.span.start) { start in
            Animated(value: now.span.end) { end in
                // Drawn where the two edges are at each step, and not eased there again; what it animates of its own, a
                // press or a lift, it says inside.
                content(Span(start: start, end: end))
                    .transaction { $0.animation = nil }
            }
            .animation(now.end, value: now.span.end)
        }
        .animation(now.start, value: now.span.start)
        .onChange(of: Target(id: id, span: span), initial: true) { old, new in
            let moves = old.id != new.id && !reduceMotion
            let forward = new.span.mid >= old.span.mid
            shown = Shown(id: new.id, span: new.span,
                          start: moves ? (forward ? Graphite.Motion.trail : Graphite.Motion.lead) : nil,
                          end: moves ? (forward ? Graphite.Motion.lead : Graphite.Motion.trail) : nil)
        }
    }
}

// MARK: - A press

extension View {
    /// Dips under a press and comes back up past its rest when let go (`Graphite.Motion.press`, `release`).
    func pressSpring(_ isPressed: Bool, depth: CGFloat = 0.95) -> some View {
        modifier(PressSpring(isPressed: isPressed, depth: depth))
    }
}

private struct PressSpring: ViewModifier {
    let isPressed: Bool
    let depth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? depth : 1)
            .animation(reduceMotion ? nil : (isPressed ? Graphite.Motion.press : Graphite.Motion.release), value: isPressed)
    }
}

// MARK: - Light under the pointer

/// Where the pointer is over one control or surface, for the light it leaves there. Kept apart from the view it is over, so
/// a move of the pointer draws the light again and not the control.
@MainActor @Observable
final class PointerSpot {
    /// In the view's own points.
    var location = CGPoint.zero
    var isInside = false

    func follow(_ phase: HoverPhase) {
        switch phase {
        case .active(let point):
            location = point
            if !isInside { isInside = true }
        case .ended:
            isInside = false
        }
    }
}

/// The light a pointer leaves on glass: along the rim near it while it rests there, and under it while it presses. Drawn
/// over the glass, which the system does not light this way on the Mac. Nothing with Reduce Motion or Increase Contrast,
/// whose firm edge it would soften.
struct PointerLight<S: InsettableShape>: View {
    let spot: PointerSpot
    let shape: S
    var isPressed = false
    /// How far the rim's light reaches from the pointer, and the bloom's under a press.
    var reach: CGFloat = 90
    var bloom: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if !reduceMotion, contrast != .increased, isEnabled {
            GeometryReader { proxy in
                let size = proxy.size
                let center = UnitPoint(x: size.width > 0 ? spot.location.x / size.width : 0.5,
                                       y: size.height > 0 ? spot.location.y / size.height : 0.5)
                let light = Color.white
                ZStack {
                    if bloom > 0 {
                        shape.fill(RadialGradient(colors: [light.opacity(Graphite.isDark ? 0.22 : 0.5), light.opacity(0)],
                                                  center: center, startRadius: 0, endRadius: bloom))
                            .opacity(isPressed ? 1 : 0)
                            .animation(isPressed ? Graphite.Motion.ease(0.1) : Graphite.Motion.ease(0.55), value: isPressed)
                    }
                    shape.strokeBorder(RadialGradient(colors: [light.opacity(Graphite.isDark ? 0.7 : 0.95), light.opacity(0)],
                                                      center: center, startRadius: 0, endRadius: reach),
                                       lineWidth: 1)
                        .opacity(spot.isInside ? (isPressed ? 1 : 0.6) : 0)
                        .animation(spot.isInside ? Graphite.Motion.ease(0.2) : Graphite.Motion.ease(0.45), value: spot.isInside)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - One hover highlight for a dock's controls

/// The controls of one glass surface that share a hover highlight: each says where it is and when the pointer is on it, and
/// the surface draws one fill under whichever that is, which goes from one to the next as a drop (`HoverGlideHighlight`),
/// in place of a fill of each control's own cut in and out.
@MainActor @Observable
final class HoverGlide {
    struct Place: Equatable {
        var id: Int
        var frame: CGRect
        var radius: CGFloat
    }

    /// Where the highlight is, in the surface's space: under the control the pointer is on, or was last on, where it fades.
    private(set) var place: Place?
    /// The pointer is on one of the controls.
    private(set) var isOver = false
    private(set) var isPressed = false
    /// Counts the highlight's moves from one control to the next. It is not counted up when the highlight comes back
    /// after it has faded, so it is then put where it is wanted and does not cross the dock to get there.
    private(set) var travel = 0
    @ObservationIgnored let space = "hoverGlide-\(UUID().uuidString)"
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var leftAt: CFTimeInterval = 0
    /// How long after the pointer left a control the highlight still travels to the next, the time its fade takes.
    static let linger: CFTimeInterval = 0.2

    func makeID() -> Int {
        nextID += 1
        return nextID
    }

    func hover(_ new: Place, _ isOn: Bool) {
        if isOn {
            guard !isOver || place != new else { return }
            let arrives = place == nil || (!isOver && CACurrentMediaTime() - leftAt > Self.linger)
            if !arrives, place?.id != new.id { travel += 1 }
            place = new
            isOver = true
        } else if isOver, place?.id == new.id {
            isOver = false
            isPressed = false
            leftAt = CACurrentMediaTime()
        }
    }

    /// The control moved, as a dock's do when its room changes.
    func moved(_ new: Place) {
        if place?.id == new.id, place != new { place = new }
    }

    func press(_ id: Int, _ isDown: Bool) {
        guard !isDown || (isOver && place?.id == id) else { return }
        if isPressed != isDown { isPressed = isDown }
    }
}

extension EnvironmentValues {
    /// The surface's shared hover highlight, for a control on it to join; none where each control keeps its own.
    @Entry var hoverGlide: HoverGlide?
}

extension View {
    /// Joins the surface's shared hover highlight, if it has one: reports where the control is and when the pointer is on
    /// it or presses it. `isJoined` is false while a control keeps the highlight off itself, as a chosen rail item does.
    func joinsHoverGlide(radius: CGFloat, isPressed: Bool = false, isJoined: Bool = true) -> some View {
        modifier(HoverGlideMember(radius: radius, isPressed: isPressed, isJoined: isJoined))
    }

    /// Gives the controls inside one shared hover highlight, drawn under them, which goes from one to the next along
    /// `axis`: `ink` is how strong it is, and `depth` how far it dips under a press.
    func hoverGlide(axis: Axis = .horizontal, ink: Double = 0.07, depth: CGFloat = 0.92) -> some View {
        modifier(HoverGlideSurface(axis: axis, ink: ink, depth: depth))
    }
}

private struct HoverGlideMember: ViewModifier {
    let radius: CGFloat
    let isPressed: Bool
    let isJoined: Bool
    @Environment(\.hoverGlide) private var glide
    @Environment(\.isEnabled) private var isEnabled
    @State private var id: Int?
    @State private var frame = CGRect.zero
    @State private var isOver = false

    func body(content: Content) -> some View {
        if let glide {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(glide.space)) } action: { frame in
                    self.frame = frame
                    if let id { glide.moved(.init(id: id, frame: frame, radius: radius)) }
                }
                .onHover { isOver = $0 }
                .onChange(of: isOver && isEnabled && isJoined) { _, isOn in
                    let id = self.id ?? glide.makeID()
                    self.id = id
                    glide.hover(.init(id: id, frame: frame, radius: radius), isOn)
                }
                .onChange(of: isPressed) { _, isDown in
                    if let id { glide.press(id, isDown) }
                }
                .onDisappear {
                    if let id { glide.hover(.init(id: id, frame: frame, radius: radius), false) }
                }
        } else {
            content
        }
    }
}

private struct HoverGlideSurface: ViewModifier {
    let axis: Axis
    let ink: Double
    let depth: CGFloat
    @State private var glide = HoverGlide()

    func body(content: Content) -> some View {
        content
            .environment(\.hoverGlide, glide)
            .background(alignment: .topLeading) { HoverGlideHighlight(glide: glide, axis: axis, ink: ink, depth: depth) }
            .coordinateSpace(.named(glide.space))
    }
}

/// The shared highlight itself: under the control the pointer is on, going to the next as a drop, dipping under a press,
/// and fading where it was when the pointer leaves.
private struct HoverGlideHighlight: View {
    let glide: HoverGlide
    let axis: Axis
    let ink: Double
    let depth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let place = glide.place {
            let isShown = glide.isOver, isPressed = glide.isPressed && !reduceMotion
            let frame = place.frame, along = axis == .horizontal
            Drop(id: glide.travel, span: along ? Span(start: frame.minX, end: frame.maxX) : Span(start: frame.minY, end: frame.maxY)) { span in
                RoundedRectangle(cornerRadius: place.radius, style: .continuous)
                    .fill(Graphite.ink(ink))
                    .frame(width: along ? max(0, span.length) : frame.width, height: along ? frame.height : max(0, span.length))
                    .scaleEffect(isPressed ? depth : 1)
                    .animation(reduceMotion ? nil : (isPressed ? Graphite.Motion.press : Graphite.Motion.release), value: isPressed)
                    .offset(x: along ? span.start : frame.minX, y: along ? frame.minY : span.start)
            }
            .opacity(isShown ? 1 : 0)
            .animation(reduceMotion ? nil : (isShown ? Graphite.Motion.ease(0.1) : Graphite.Motion.ease(0.22)), value: isShown)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Glass arriving

/// Glass arriving over the workspace, a notice or a tag: a little small and out of focus, coming up to its size; it leaves
/// on a short fade. The caller's animation paces it (`Graphite.Motion.arrive` in, `quick` out).
private struct Arrival: ViewModifier {
    /// 0 away, 1 arrived.
    let progress: CGFloat
    var drop: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.86 + 0.14 * progress)
            .blur(radius: 4 * (1 - progress))
            .offset(y: -drop * (1 - progress))
            .opacity(Double(progress))
    }
}

extension AnyTransition {
    /// Glass arriving in place (`Arrival`).
    static var arrives: AnyTransition {
        .asymmetric(insertion: .modifier(active: Arrival(progress: 0), identity: Arrival(progress: 1)),
                    removal: .opacity.combined(with: .scale(scale: 0.96)))
    }

    /// A notice dropping in from just above where it rests.
    static var dropsIn: AnyTransition {
        .asymmetric(insertion: .modifier(active: Arrival(progress: 0, drop: 14), identity: Arrival(progress: 1, drop: 14)),
                    removal: .opacity.combined(with: .scale(scale: 0.96)))
    }

    /// A mark landing on a picture: from half its size, on `Graphite.Motion.land`.
    static var lands: AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.4).combined(with: .opacity), removal: .scale(scale: 0.6).combined(with: .opacity))
    }
}

// MARK: - A button reshaping

/// A button's title that gives way to the next, each out of focus as it goes and comes, while the button, one view
/// whatever it says, takes the next title's width and its glass with it. The caller's animation paces both
/// (`Graphite.Motion.reshape`).
struct ReshapingTitle: View {
    let text: String

    var body: some View {
        ZStack {
            Text(verbatim: text)
                .id(text)
                .transition(.blurReplace)
        }
    }
}

/// A button budding off the one before it: narrow and against that one's edge, drawing out to its place and size. In a
/// `GlassEffectContainer` the two are one drop of glass until it has come clear.
private struct Bud: ViewModifier {
    /// 0 against its neighbour, 1 in place.
    let progress: CGFloat
    let reach: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.3 + 0.7 * progress, y: 0.82 + 0.18 * progress, anchor: .leading)
            .offset(x: -reach * (1 - progress))
            .opacity(Double(min(1, progress * 1.6)))
    }
}

extension AnyTransition {
    /// A button budding off the one `reach` points before it (`Bud`).
    static func buds(reach: CGFloat) -> AnyTransition {
        .modifier(active: Bud(progress: 0, reach: reach), identity: Bud(progress: 1, reach: reach))
    }
}

// MARK: - Words and figures that change

/// A line that changes in place. Where it keeps its shape and a few of its characters change, as a count does ("10 of 24"
/// to "11 of 24"), those roll to their next; where it becomes another line it gives way on a short fade, since a whole
/// line rolling reads as noise.
///
/// A line run through, as a held arrow key runs the title through the frames, is shown as it comes: rolling from each to
/// the next it would be mid-roll for as long as the key is down, and never read.
struct RollingText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The line before this one, to tell a count's step from another line.
    @State private var last: String?
    @State private var pace = ChangePace<String>()

    var body: some View {
        let isRun = pace.isInRun(text)
        Text(verbatim: text)
            .contentTransition(Self.rolls(from: last ?? text, to: text) ? .numericText() : .opacity)
            .animation(reduceMotion || isRun ? nil : Graphite.Motion.quick, value: text)
            .onChange(of: text, initial: true) { _, new in last = new }
    }

    /// Whether `new` is `old` with a few characters changed: as long, and no more than two in five of them different.
    nonisolated static func rolls(from old: String, to new: String) -> Bool {
        let a = Array(old), b = Array(new)
        guard a.count == b.count, !a.isEmpty else { return false }
        let changed = zip(a, b).filter { $0 != $1 }.count
        return Double(changed) <= Double(a.count) * 0.4
    }
}

// MARK: - A spring that ends when it is at rest to the eye

/// One leg of a spring's way: from where it was, at the speed it had, to where it was last sent. A spring sent somewhere
/// else on its way starts another leg from where it is, at the speed it has, so the move goes on without a step.
///
/// Positions are measured from where the animation began, as SwiftUI gives a custom animation its values.
struct SpringLeg<V: VectorArithmetic> {
    /// When the leg began, in the animation's own seconds.
    var start: TimeInterval = 0
    /// Where it began, and how fast it was going there.
    var from = V.zero
    var velocity = V.zero
    /// Where it was last sent; nothing until the animation has been asked for a value.
    var target: V?
    /// The largest the move has been over all of its legs, as `energy` measures one: what "at rest" is measured
    /// against, so a leg that begins a hair from its target is at rest at once, and not held to a hair of a hair.
    var reach = 0.0

    /// How close to its target, and how slow, counts as at rest, as a part of the move's reach: a point in a thousand,
    /// which the frame view's way to its cell ends within a point of.
    static var restFraction: Double { 0.001 }

    /// Where the leg is `time` into the animation on its way to `target`, how fast, and whether it has come to rest there.
    func state(at time: TimeInterval, to target: V, spring: Spring) -> (position: V, velocity: V, isAtRest: Bool) {
        let elapsed = max(0, time - start)
        var distance = target
        distance -= from
        var position = spring.value(target: distance, initialVelocity: velocity, time: elapsed)
        let speed = spring.velocity(target: distance, initialVelocity: velocity, time: elapsed)
        var remaining = distance
        remaining -= position
        position += from
        let reach = max(self.reach, Self.energy(distance, velocity, spring: spring))
        return (position, speed, Self.energy(remaining, speed, spring: spring) <= Self.restFraction * Self.restFraction * reach)
    }

    /// The leg that goes on from this one at `time`, when a spring on its way to `target` is sent somewhere else.
    func redirected(at time: TimeInterval, from target: V, spring: Spring) -> SpringLeg {
        let now = state(at: time, to: target, spring: spring)
        var distance = target
        distance -= from
        return SpringLeg(start: time, from: now.position, velocity: now.velocity,
                         reach: max(reach, Self.energy(distance, velocity, spring: spring)))
    }

    /// A distance and a speed as one squared length: the speed counts as the distance the spring covers at it in one
    /// radian of its swing, so a spring passing through its target at speed is not taken to be at rest there.
    private static func energy(_ distance: V, _ speed: V, spring: Spring) -> Double {
        let radian = spring.response / (2 * .pi)
        return distance.magnitudeSquared + speed.magnitudeSquared * radian * radian
    }
}

/// A spring that ends once it is at rest to the eye (`SpringLeg.restFraction`), where SwiftUI's own runs on until it is
/// at rest to the last bit of a floating-point number: 1.3 s for the frame view's, and 3.2 s for one sent back before
/// it had settled, whose two springs are merged (measured in a hosted window). It moves as that spring does, and one
/// sent somewhere else on its way goes on from where it is at the speed it has.
///
/// For a move a view leaves on. A view leaving on a transition stays in the window, drawn and taking clicks, until its
/// animation has ended: the frame view, shrunk onto its cell half a second after it was closed, stayed drawn there for
/// seconds more, and a sheet scrolled in that time moved under a picture that did not (`Graphite.Motion.hero`).
struct RestingSpring: CustomAnimation {
    var response: Double
    var dampingFraction: Double

    private var spring: Spring { Spring(response: response, dampingRatio: dampingFraction) }

    private struct LegKey<V: VectorArithmetic>: AnimationStateKey {
        static var defaultValue: SpringLeg<V> { SpringLeg() }
    }

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        var leg = context.state[LegKey<V>.self]
        // Kept for the leg that follows this one, which starts from where this one was on its way to.
        leg.target = value
        context.state[LegKey<V>.self] = leg
        let now = leg.state(at: time, to: value, spring: spring)
        return now.isAtRest ? nil : now.position
    }

    func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        context.state[LegKey<V>.self].state(at: time, to: value, spring: spring).velocity
    }

    /// Takes over from a spring of this kind on its way, of whatever response: the context holds that one's leg, and
    /// `time` goes on from its start. Any other animation runs on beside this one, as SwiftUI combines the two.
    func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval, context: inout AnimationContext<V>) -> Bool {
        guard let previous = previous.base as? RestingSpring else { return false }
        let leg = context.state[LegKey<V>.self]
        // One never asked for a value has not moved: this spring starts as it would by itself.
        if let target = leg.target {
            context.state[LegKey<V>.self] = leg.redirected(at: time, from: target, spring: previous.spring)
        }
        return true
    }
}
