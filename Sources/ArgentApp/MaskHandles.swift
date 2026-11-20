import AppKit
import ArgentCore
import SwiftUI

extension FrameGeometry {
    /// An area point in `MaskSpace`: long sides from the picture's top left, y down, whatever the zoom or
    /// the display's scale, so a mask drawn at fit lands on the same part of the photograph at 100.
    /// Never fractions of each side, which would turn a circle into an ellipse on a 3:2 frame.
    func maskPoint(_ point: CGPoint) -> MaskPoint {
        guard longSide > 0 else { return MaskPoint(x: 0, y: 0) }
        return MaskPoint(x: Float((point.x - picture.minX) / longSide), y: Float((point.y - picture.minY) / longSide))
    }

    /// The area point of a place in `MaskSpace`, on or off the picture.
    func point(for position: MaskPoint) -> CGPoint {
        CGPoint(x: picture.minX + CGFloat(position.x) * longSide, y: picture.minY + CGFloat(position.y) * longSide)
    }

    /// The picture's bottom right corner in `MaskSpace`: `(W/L, H/L)`.
    var maskExtent: MaskPoint {
        guard longSide > 0 else { return MaskPoint(x: 1, y: 1) }
        return MaskPoint(x: Float(picture.width / longSide), y: Float(picture.height / longSide))
    }
}

/// A place on a gradient that the pointer can take hold of.
enum MaskHandle: Hashable, Sendable {
    /// A linear gradient's Full and Zero points, and the point between them that moves it whole.
    case full, zero, middle
    /// A radial gradient's centre, which moves it whole, the ends of its two axes, the handle that turns
    /// it and the one on its inner edge that sets Feather.
    case center, axisA, axisB, rotation, feather

    /// Whether a drag of it moves the whole gradient.
    var movesWhole: Bool { self == .middle || self == .center }
}

/// Everything about a gradient on the photograph that is arithmetic: where its handles are, which one a
/// point lands on, what a drag makes of the shape and how a gesture draws one. Pure, in `MaskSpace` except
/// for what is measured on screen, so `MaskHandleTests` holds it at fit, zoomed, portrait and at each
/// display scale. The pointer's own rule is `MaskEditor.canvasTakesPress`, which asks `hit` here.
enum MaskHandleModel {
    /// How far from a handle's centre a press still takes it, in points: 24 across, whatever the zoom.
    static let hitRadius: CGFloat = 12
    /// How far a press moves before it is a drag rather than a click, as `FrameView`'s own pan.
    static let dragThreshold: CGFloat = 3
    /// How far past the outline the handle that turns a radial stands, in points.
    static let rotationReach: CGFloat = 24
    /// How far from the picture a handle may be taken, in long sides. Past it the handle could be lost
    /// off the area with nothing to bring it back but a typed value.
    static let positionRange: ClosedRange<Float> = -1...2
    /// The narrowest gradient a gesture makes, in long sides, about 14 pixels at 7008.
    static let minimumExtent: Float = 0.002
    /// The largest semi-axis a gesture makes, in long sides.
    static let maximumSemiAxis: Float = 2
    /// How far in from the outline the Feather handle stands at Feather 100, as a share of the semi-axis.
    /// A place to take hold of, not a measurement: the profile itself is plan section 6's.
    static let featherReach: Float = 0.8

    // MARK: Handles

    /// The handles of `shape` in the frame view's area, in hit order: those a press is most likely to mean
    /// first, so where two overlap on a tiny gradient the one that changes it least wins.
    static func handles(of shape: MaskShape, in geometry: FrameGeometry) -> [(handle: MaskHandle, point: CGPoint)] {
        switch shape {
        case .linear(let g):
            let middle = MaskPoint(x: (g.full.x + g.zero.x) / 2, y: (g.full.y + g.zero.y) / 2)
            return [(.middle, geometry.point(for: middle)), (.full, geometry.point(for: g.full)), (.zero, geometry.point(for: g.zero))]
        case .radial(let g):
            let center = geometry.point(for: g.center), a = axisA(g), b = axisB(g)
            let outline = geometry.point(for: MaskPoint(x: g.center.x - b.x * g.semiAxisB, y: g.center.y - b.y * g.semiAxisB))
            let n = featherPosition(g.feather)
            return [(.center, center),
                    (.axisA, geometry.point(for: MaskPoint(x: g.center.x + a.x * g.semiAxisA, y: g.center.y + a.y * g.semiAxisA))),
                    (.axisB, geometry.point(for: MaskPoint(x: g.center.x + b.x * g.semiAxisB, y: g.center.y + b.y * g.semiAxisB))),
                    (.feather, geometry.point(for: MaskPoint(x: g.center.x - a.x * g.semiAxisA * n, y: g.center.y - a.y * g.semiAxisA * n))),
                    (.rotation, CGPoint(x: outline.x - CGFloat(b.x) * rotationReach, y: outline.y - CGFloat(b.y) * rotationReach))]
        case .brush, .smart:
            return []
        }
    }

    /// The handle a press at `point` takes: the nearest within `hitRadius`, and only what the area shows,
    /// since a handle out past its edge is under the dock or off the workspace. Nothing else on the
    /// gradient is a target, so a press between handles still pans a zoomed frame.
    static func hit(at point: CGPoint, of shape: MaskShape, in geometry: FrameGeometry) -> MaskHandle? {
        guard CGRect(origin: .zero, size: geometry.area).contains(point) else { return nil }
        var best: (handle: MaskHandle, distance: CGFloat)?
        for (handle, place) in handles(of: shape, in: geometry) {
            let distance = hypot(place.x - point.x, place.y - point.y)
            if distance <= hitRadius, distance < (best?.distance ?? .infinity) { best = (handle, distance) }
        }
        return best?.handle
    }

    /// What a drag of `handle` makes of `start`, the shape at the press, for a pointer moved from `from` to
    /// `to`. Measured from the press rather than the handle, so a press beside the handle does not make it
    /// jump. `constrain` is Shift: a linear's moving point stays level or plumb with the other.
    static func dragged(_ handle: MaskHandle, start: MaskShape, from: MaskPoint, to: MaskPoint, constrain: Bool = false) -> MaskShape {
        let delta = MaskPoint(x: to.x - from.x, y: to.y - from.y)
        switch start {
        case .linear(var g):
            switch handle {
            case .middle:
                let moved = movedKeepingInRange([g.full, g.zero], by: delta)
                g.full = moved[0]; g.zero = moved[1]
            case .full: g.full = placed(MaskPoint(x: g.full.x + delta.x, y: g.full.y + delta.y), from: g.zero, constrain: constrain)
            case .zero: g.zero = placed(MaskPoint(x: g.zero.x + delta.x, y: g.zero.y + delta.y), from: g.full, constrain: constrain)
            default: break
            }
            return .linear(g)
        case .radial(var g):
            let a = axisA(g), b = axisB(g)
            switch handle {
            case .center:
                g.center = movedKeepingInRange([g.center], by: delta)[0]
            case .axisA:
                g.semiAxisA = clampedSemiAxis(g.semiAxisA + delta.x * a.x + delta.y * a.y)
            case .axisB:
                g.semiAxisB = clampedSemiAxis(g.semiAxisB + delta.x * b.x + delta.y * b.y)
            case .rotation:
                let was = atan2(from.y - g.center.y, from.x - g.center.x), now = atan2(to.y - g.center.y, to.x - g.center.x)
                g.angle = normalizedAngle(g.angle + now - was)
            case .feather:
                // The handle stands on the side opposite axis A, so moving outward along that side feathers less.
                let along = -(delta.x * a.x + delta.y * a.y) / max(g.semiAxisA, MaskSpace.minimumExtent)
                g.feather = featherValue(atPosition: featherPosition(g.feather) + along)
            default: break
            }
            return .radial(g)
        case .brush, .smart:
            return start
        }
    }

    /// The gradient a drag from `from` to `to` draws: Lightroom's gesture, a linear from Full to Zero and
    /// a radial from the centre outward with the pointer at the corner of its two axes. `constrain` is
    /// Shift: a linear level or plumb, a radial a circle. Nil while the drag is too short to mean anything.
    static func drawn(_ tool: MaskEditor.Tool, from: MaskPoint, to: MaskPoint, constrain: Bool = false) -> MaskShape? {
        let start = clampedPosition(from)
        switch tool {
        case .linear:
            guard hypot(to.x - start.x, to.y - start.y) >= minimumExtent else { return nil }
            return .linear(.init(full: start, zero: placed(to, from: start, constrain: constrain)))
        case .radial:
            let dx = abs(to.x - start.x), dy = abs(to.y - start.y)
            guard hypot(dx, dy) >= minimumExtent else { return nil }
            let radius = hypot(dx, dy)
            return .radial(.init(center: start, semiAxisA: clampedSemiAxis(constrain ? radius : dx),
                                 semiAxisB: clampedSemiAxis(constrain ? radius : dy)))
        case .brush:
            return nil
        }
    }

    /// A gradient where a keyboard's Return puts one, with no pointer to say where: a linear from the
    /// picture's top edge to its middle, the usual sky, and a radial at the middle of the picture.
    static func placed(_ tool: MaskEditor.Tool, extent: MaskPoint) -> MaskShape? {
        switch tool {
        case .linear:
            return .linear(.init(full: MaskPoint(x: extent.x / 2, y: 0), zero: MaskPoint(x: extent.x / 2, y: extent.y / 2)))
        case .radial:
            return .radial(.init(center: MaskPoint(x: extent.x / 2, y: extent.y / 2), semiAxisA: extent.x / 4, semiAxisB: extent.y / 4))
        case .brush:
            return nil
        }
    }

    // MARK: Arithmetic

    static func axisA(_ g: MaskShape.RadialGradient) -> MaskPoint { MaskPoint(x: cos(g.angle), y: sin(g.angle)) }
    static func axisB(_ g: MaskShape.RadialGradient) -> MaskPoint { MaskPoint(x: -sin(g.angle), y: cos(g.angle)) }

    /// Where the Feather handle stands at `feather`, as a share of the semi-axis in from the centre.
    static func featherPosition(_ feather: Float) -> Float { 1 - featherReach * feather / 100 }

    /// The whole-number Feather a handle at `position` means.
    static func featherValue(atPosition position: Float) -> Float {
        let feather = (1 - position) / featherReach * 100
        return min(MaskShape.RadialGradient.featherRange.upperBound, max(MaskShape.RadialGradient.featherRange.lowerBound, feather.rounded()))
    }

    static func normalizedAngle(_ angle: Float) -> Float {
        var result = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if result > .pi { result -= 2 * .pi }
        if result <= -.pi { result += 2 * .pi }
        return result
    }

    static func clampedSemiAxis(_ value: Float) -> Float { min(maximumSemiAxis, max(minimumExtent, value)) }

    static func clampedPosition(_ point: MaskPoint) -> MaskPoint {
        MaskPoint(x: min(positionRange.upperBound, max(positionRange.lowerBound, point.x)),
                  y: min(positionRange.upperBound, max(positionRange.lowerBound, point.y)))
    }

    /// `points` moved by `delta`, as far as keeps all of them in `positionRange`, so a gradient moved
    /// whole keeps its shape at the limit instead of folding up.
    private static func movedKeepingInRange(_ points: [MaskPoint], by delta: MaskPoint) -> [MaskPoint] {
        func limit(_ value: Float, _ coordinates: [Float]) -> Float {
            let low = positionRange.lowerBound - (coordinates.min() ?? 0), high = positionRange.upperBound - (coordinates.max() ?? 0)
            return min(max(high, low), max(min(high, low), value))
        }
        let dx = limit(delta.x, points.map(\.x)), dy = limit(delta.y, points.map(\.y))
        return points.map { MaskPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// `point` kept in range and at least `minimumExtent` from `other`, level or plumb with it under Shift.
    private static func placed(_ point: MaskPoint, from other: MaskPoint, constrain: Bool) -> MaskPoint {
        var result = clampedPosition(point)
        if constrain {
            if abs(result.x - other.x) >= abs(result.y - other.y) { result.y = other.y } else { result.x = other.x }
        }
        let distance = hypot(result.x - other.x, result.y - other.y)
        guard distance < minimumExtent else { return result }
        // Too close: held on the same side at the shortest span there is.
        guard distance > 0 else { return clampedPosition(MaskPoint(x: other.x, y: other.y + minimumExtent)) }
        return MaskPoint(x: other.x + (result.x - other.x) / distance * minimumExtent, y: other.y + (result.y - other.y) / distance * minimumExtent)
    }
}

// MARK: - The panel's fields

/// One number of a gradient in the selected mask's panel, so a gradient can be placed and changed with no
/// pointer: SPEC's keyboard-complete, with painting the one exception (plan section 5). Each is a row like
/// the Light rows, with its slider, field and keys. Positions and sizes read in hundredths of the long
/// side, `MaskSpace` times 100, which a picture of any shape shares. A smart selection's one number is its
/// Feather (decision 19), in the same place and the same kind of row.
enum MaskShapeField: String, CaseIterable, Hashable, Sendable {
    case fullX, fullY, zeroX, zeroY
    case centerX, centerY, width, height, angle, feather
    case selectionFeather

    static let perUnit: Float = 100

    static func fields(of shape: MaskShape) -> [MaskShapeField] {
        switch shape {
        case .linear: [.fullX, .fullY, .zeroX, .zeroY]
        case .radial: [.feather, .centerX, .centerY, .width, .height, .angle]
        case .smart: [.selectionFeather]
        case .brush: []
        }
    }

    /// What the rows of `shape` are headed with: "Radial gradient", or a selection's kind, "Sky".
    static func heading(of shape: MaskShape) -> String {
        switch shape {
        case .smart: MaskSummary.title(of: shape)
        case .linear, .radial, .brush: "\(MaskSummary.title(of: shape)) gradient"
        }
    }

    /// The undo step a drag or entry of `shape`'s rows makes.
    static func actionName(of shape: MaskShape) -> String {
        if case .smart = shape { return "Feather Mask" }
        return "Adjust Gradient"
    }

    /// The tool whose gradient has this number; `nil` for a selection's, which no tool places.
    var tool: MaskEditor.Tool? {
        switch self {
        case .fullX, .fullY, .zeroX, .zeroY: .linear
        case .centerX, .centerY, .width, .height, .angle, .feather: .radial
        case .selectionFeather: nil
        }
    }

    var title: String {
        switch self {
        case .fullX: "Full X"
        case .fullY: "Full Y"
        case .zeroX: "Zero X"
        case .zeroY: "Zero Y"
        case .centerX: "Centre X"
        case .centerY: "Centre Y"
        case .width: "Width"
        case .height: "Height"
        case .angle: "Angle"
        case .feather, .selectionFeather: "Feather"
        }
    }

    /// What it does, which its help tags and VoiceOver's hint begin with.
    var help: String {
        switch self {
        case .fullX: "How far across the picture the gradient is at its full effect, in hundredths of the long side."
        case .fullY: "How far down the picture the gradient is at its full effect, in hundredths of the long side."
        case .zeroX: "How far across the picture the gradient has faded to nothing, in hundredths of the long side."
        case .zeroY: "How far down the picture the gradient has faded to nothing, in hundredths of the long side."
        case .centerX: "How far across the picture the gradient's centre is, in hundredths of the long side."
        case .centerY: "How far down the picture the gradient's centre is, in hundredths of the long side."
        case .width: "From the gradient's centre to its edge along its first axis, in hundredths of the long side."
        case .height: "From the gradient's centre to its edge along its second axis, in hundredths of the long side."
        case .angle: "How far the gradient is turned, clockwise, in degrees."
        case .feather: "How gradually the gradient's edge falls away."
        case .selectionFeather: "How softly the selection's edge falls away. At 0 it follows the picture's edges as found."
        }
    }

    /// The row's slider, resetting to the placed gradient's value (`MaskHandleModel.placed`), since a
    /// position has no zero that means no change. In the mask's group, after its seven, so `.` and `,`
    /// reach it.
    func spec(default shape: MaskShape?, order: Int) -> AdjustmentSliderSpec {
        let start = shape.flatMap { value(in: $0) } ?? 0
        switch self {
        case .fullX, .fullY, .zeroX, .zeroY, .centerX, .centerY:
            let range = MaskHandleModel.positionRange
            return AdjustmentSliderSpec(title: title, range: (range.lowerBound * Self.perUnit)...(range.upperBound * Self.perUnit), step: 0.1,
                                        defaultValue: start, polarity: .unipolar, arrowStep: 0.1, smallKeyStep: 1, largeKeyStep: 5,
                                        fractionDigits: 1, group: .mask, order: order)
        case .width, .height:
            return AdjustmentSliderSpec(title: title, range: (MaskHandleModel.minimumExtent * Self.perUnit)...(MaskHandleModel.maximumSemiAxis * Self.perUnit),
                                        step: 0.1, defaultValue: start, polarity: .unipolar, arrowStep: 0.1, smallKeyStep: 1, largeKeyStep: 5,
                                        fractionDigits: 1, group: .mask, order: order)
        case .angle:
            return AdjustmentSliderSpec(title: title, range: -180...180, step: 1, defaultValue: 0, arrowStep: 1, smallKeyStep: 5, largeKeyStep: 15,
                                        unit: "°", group: .mask, order: order)
        case .feather:
            return AdjustmentSliderSpec(title: title, range: MaskShape.RadialGradient.featherRange, step: 1, defaultValue: 50, polarity: .unipolar,
                                        arrowStep: 1, smallKeyStep: 5, largeKeyStep: 20, group: .mask, order: order)
        case .selectionFeather:
            // At 0 a selection is its refined edge, so 0 is what a double-click goes back to, as a Light row's 0.
            return AdjustmentSliderSpec(title: title, range: SmartSelection.featherRange, step: 1, defaultValue: 0, polarity: .unipolar,
                                        arrowStep: 1, smallKeyStep: 5, largeKeyStep: 20, group: .mask, order: order)
        }
    }

    /// The number this field shows for `shape`; nil if the shape has no such number.
    func value(in shape: MaskShape) -> Float? {
        switch (self, shape) {
        case (.fullX, .linear(let g)): g.full.x * Self.perUnit
        case (.fullY, .linear(let g)): g.full.y * Self.perUnit
        case (.zeroX, .linear(let g)): g.zero.x * Self.perUnit
        case (.zeroY, .linear(let g)): g.zero.y * Self.perUnit
        case (.centerX, .radial(let g)): g.center.x * Self.perUnit
        case (.centerY, .radial(let g)): g.center.y * Self.perUnit
        case (.width, .radial(let g)): g.semiAxisA * Self.perUnit
        case (.height, .radial(let g)): g.semiAxisB * Self.perUnit
        case (.angle, .radial(let g)): MaskHandleModel.normalizedAngle(g.angle) * 180 / .pi
        case (.feather, .radial(let g)): g.feather
        case (.selectionFeather, .smart(let selection)): selection.feather
        default: nil
        }
    }

    /// `shape` with this field at `number`, or nil where that is no gradient, as Full on top of Zero.
    func setting(_ number: Float, in shape: MaskShape) -> MaskShape? {
        guard number.isFinite else { return nil }
        let unit = number / Self.perUnit
        switch (self, shape) {
        case (.fullX, .linear(var g)): g.full.x = unit; return Self.checked(g)
        case (.fullY, .linear(var g)): g.full.y = unit; return Self.checked(g)
        case (.zeroX, .linear(var g)): g.zero.x = unit; return Self.checked(g)
        case (.zeroY, .linear(var g)): g.zero.y = unit; return Self.checked(g)
        case (.centerX, .radial(var g)): g.center.x = unit; return .radial(g)
        case (.centerY, .radial(var g)): g.center.y = unit; return .radial(g)
        case (.width, .radial(var g)): g.semiAxisA = MaskHandleModel.clampedSemiAxis(unit); return .radial(g)
        case (.height, .radial(var g)): g.semiAxisB = MaskHandleModel.clampedSemiAxis(unit); return .radial(g)
        case (.angle, .radial(var g)): g.angle = MaskHandleModel.normalizedAngle(number * .pi / 180); return .radial(g)
        case (.feather, .radial(var g)): g.feather = min(100, max(0, number)); return .radial(g)
        case (.selectionFeather, .smart(var selection)):
            selection.feather = min(SmartSelection.featherRange.upperBound, max(SmartSelection.featherRange.lowerBound, number))
            return .smart(selection)
        default: return nil
        }
    }

    private static func checked(_ g: MaskShape.LinearGradient) -> MaskShape? {
        hypot(g.zero.x - g.full.x, g.zero.y - g.full.y) >= MaskSpace.minimumExtent ? .linear(g) : nil
    }
}

// MARK: - On the photograph

/// What every mark on the photograph shares: white over a black hairline, in fixed colours, so it reads on any picture in any theme. Increase
/// Contrast makes the hairline firm, on the handles, the pins and the brush's ring alike.
enum MaskOnPicture {
    static func hairline(increased: Bool) -> Double { increased ? 0.9 : 0.55 }
}

/// The selected gradient on the photograph: its lines and handles, drawn at the picture's rectangle so they
/// keep with it through a zoom, in white over a black hairline, which reads on any photograph. They are tools
/// as the split divider is, and take no event: the canvas has the pointer. Fixed colours, for that reason.
struct MaskHandlesView: View, Equatable {
    let shape: MaskShape
    let geometry: FrameGeometry
    @Environment(\.colorSchemeContrast) private var contrast

    nonisolated static func == (a: Self, b: Self) -> Bool { a.shape == b.shape && a.geometry == b.geometry }

    var body: some View {
        let dark = Color.black.opacity(MaskOnPicture.hairline(increased: contrast == .increased))
        ZStack {
            // The lines stop at the picture; a handle may stand off it, and stays in reach there.
            HandleLines(shape: shape)
                .stroke(dark, style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
                .overlay { HandleLines(shape: shape).stroke(Color.white, style: StrokeStyle(lineWidth: 1, lineCap: .round)) }
                .clipped()
            HandleStems(shape: shape)
                .stroke(dark, lineWidth: 2.25)
                .overlay { HandleStems(shape: shape).stroke(Color.white, lineWidth: 1) }
            HandleDots(shape: shape, filled: false).fill(dark)
            HandleDots(shape: shape, filled: true).fill(Color.white, style: FillStyle(eoFill: true))
        }
        .frame(width: geometry.picture.width, height: geometry.picture.height)
        .position(geometry.center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A rectangle a shape is drawn in as the picture: the handle model's arithmetic in its own points. Plain arithmetic on its
    /// argument, for the shapes' `path(in:)`, which SwiftUI calls off the main actor.
    nonisolated fileprivate static func geometry(in rect: CGRect) -> FrameGeometry {
        FrameGeometry(area: rect.size, picture: CGRect(origin: .zero, size: rect.size), displayScale: 1)
    }

    /// A linear's lines: where it is full and where it reaches zero, across the picture, and the line it
    /// is moved by between them. A radial's: its outline and its inner edge.
    private struct HandleLines: Shape {
        let shape: MaskShape

        func path(in rect: CGRect) -> Path {
            let geometry = MaskHandlesView.geometry(in: rect)
            var path = Path()
            switch shape {
            case .linear(let g):
                let full = geometry.point(for: g.full), zero = geometry.point(for: g.zero)
                let dx = zero.x - full.x, dy = zero.y - full.y, length = max(hypot(dx, dy), 0.001)
                // Across the gradient, far enough to leave the picture both ways; the clip stops it there.
                let reach = (rect.width + rect.height) * 2, ux = -dy / length * reach, uy = dx / length * reach
                for center in [full, CGPoint(x: (full.x + zero.x) / 2, y: (full.y + zero.y) / 2), zero] {
                    path.move(to: CGPoint(x: center.x - ux, y: center.y - uy))
                    path.addLine(to: CGPoint(x: center.x + ux, y: center.y + uy))
                }
            case .radial(let g):
                let center = geometry.point(for: g.center), long = max(rect.width, rect.height)
                let a = CGFloat(g.semiAxisA) * long, b = CGFloat(g.semiAxisB) * long, n = CGFloat(MaskHandleModel.featherPosition(g.feather))
                let turned = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(g.angle))
                path.addEllipse(in: CGRect(x: -a, y: -b, width: 2 * a, height: 2 * b), transform: turned)
                if g.feather > 0 {
                    path.addEllipse(in: CGRect(x: -a * n, y: -b * n, width: 2 * a * n, height: 2 * b * n), transform: turned)
                }
            case .brush, .smart:
                break
            }
            return path
        }
    }

    /// What ties a handle standing clear of its gradient to it: the stem up to the handle that turns a
    /// radial, and a linear's Full to its Zero.
    private struct HandleStems: Shape {
        let shape: MaskShape

        func path(in rect: CGRect) -> Path {
            let geometry = MaskHandlesView.geometry(in: rect)
            var path = Path()
            switch shape {
            case .linear(let g):
                path.move(to: geometry.point(for: g.full))
                path.addLine(to: geometry.point(for: g.zero))
            case .radial(let g):
                let handles = MaskHandleModel.handles(of: .radial(g), in: geometry)
                let b = MaskHandleModel.axisB(g)
                if let rotation = handles.first(where: { $0.handle == .rotation })?.point {
                    path.move(to: rotation)
                    path.addLine(to: CGPoint(x: rotation.x + CGFloat(b.x) * MaskHandleModel.rotationReach,
                                             y: rotation.y + CGFloat(b.y) * MaskHandleModel.rotationReach))
                }
            case .brush, .smart:
                break
            }
            return path
        }
    }

    /// The handles' dots: a little larger under the white for the hairline. Full is solid and Zero an open
    /// ring, so which way a linear falls reads at a glance; the handle that moves the whole is larger.
    private struct HandleDots: Shape {
        let shape: MaskShape
        let filled: Bool

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for (handle, point) in MaskHandleModel.handles(of: shape, in: MaskHandlesView.geometry(in: rect)) {
                let radius: CGFloat = handle.movesWhole ? 5 : 4
                let outer = radius + (filled ? 0 : 1)
                path.addEllipse(in: CGRect(x: point.x - outer, y: point.y - outer, width: 2 * outer, height: 2 * outer))
                if filled, handle == .zero || handle == .feather || handle == .rotation {
                    // A ring: the view fills this shape even-odd, so a circle inside the dot leaves it open.
                    let inner = radius - 1.5
                    path.addEllipse(in: CGRect(x: point.x - inner, y: point.y - inner, width: 2 * inner, height: 2 * inner))
                }
            }
            return path
        }
    }
}
