import ArgentCore
import ArgentRoll
import CoreGraphics
import Observation
import SwiftUI

// Pins: one small glass dot on the photograph for each mask, Lightroom's way between masks (R1's sixth invariant, decision 9). A click
// selects its mask and the list follows, hovering one shows its mask's overlay as hovering its row does, Option-drag changes its Amount
// as the Amount row's drag does, and H hides them. They are a pointer's convenience: the list keeps masks keyboard-complete.

// MARK: - Where a pin sits

/// Where a mask's pin sits, as its own shape says, so no slider can move it: a slider holds nothing but values (plan section 4, rule 2).
enum MaskPinAnchor: Equatable, Sendable {
    /// In `MaskSpace`: a gradient's middle or centre, a brush's first point.
    case space(MaskPoint)
    /// As fractions of the picture, upright from its top left: a smart selection's point, found on its seed.
    case fractions(CGPoint)

    /// The anchor in the frame view's area.
    func point(in geometry: FrameGeometry) -> CGPoint {
        switch self {
        case .space(let position): geometry.point(for: position)
        case .fractions(let fractions): geometry.point(forNormalized: fractions)
        }
    }
}

/// What a smart selection's seed says of its pin: a point found, nothing selected, or not read yet.
enum MaskSeedPinPoint: Equatable, Sendable {
    case found(CGPoint)
    case nothing
    case unknown
}

/// Which component a mask's pin stands for and where, from the components alone. Pure, held by `MaskPinTests`.
///
/// A mask's pin is its first component's that has one: a linear's middle, the point between Full and Zero its middle handle moves it by;
/// a radial's centre; a brush's first stroke's first point, where it began (the first that paints, not one that erases); and a smart
/// selection's point inside what its seed selected (`MaskSeedPin`). Components are appended, so adding one never moves the pin. A
/// selection whose seed is still being read holds the pin back rather than lend it to a later component, so it does not jump when it lands.
enum MaskPinPlacement {
    enum Answer: Equatable {
        case anchor(MaskPinAnchor)
        /// A selection whose seed has not been read yet.
        case pending
        /// The component has nowhere to stand: a brush with no stroke, a selection not made or that selects nothing.
        case none
    }

    static func anchor(of shape: MaskShape, seed: (SmartSelection) -> MaskSeedPinPoint) -> Answer {
        switch shape {
        case .linear(let g):
            return .anchor(.space(MaskPoint(x: (g.full.x + g.zero.x) / 2, y: (g.full.y + g.zero.y) / 2)))
        case .radial(let g):
            return .anchor(.space(g.center))
        case .brush(let paint):
            let painting = paint.strokes.first { !$0.erase && $0.points.count > 0 } ?? paint.strokes.first { $0.points.count > 0 }
            guard let first = painting?.points.points.first else { return .none }
            return .anchor(.space(first))
        case .smart(let selection):
            guard selection.raster != nil else { return .none }
            switch seed(selection) {
            case .found(let point): return .anchor(.fractions(point))
            case .nothing: return .none
            case .unknown: return .pending
            }
        }
    }

    /// The mask's pin and the component it stands for; nil while it has none, or waits for a seed.
    static func anchor(of mask: Mask, seed: (SmartSelection) -> MaskSeedPinPoint) -> (anchor: MaskPinAnchor, component: Int)? {
        for (index, component) in mask.components.enumerated() {
            switch anchor(of: component.shape, seed: seed) {
            case .anchor(let anchor): return (anchor, index)
            case .pending: return nil
            case .none: continue
            }
        }
        return nil
    }
}

/// A smart selection's pin: the point of its seed farthest from any edge of what it selected, the picture's own edges included, so the
/// pin stands well inside the largest part of it and clear of the frame. Read from the seed as stored, never from edited pixels, nor from
/// its Feather or the frame's refined edge, so no slider and no Feather moves it; a Background's is inside the complement it selects. Its
/// Invert is the component's and is not asked, as a radial's pin stays at its centre inverted. Pure, held by `MaskPinTests`.
enum MaskSeedPin {
    /// The grid the seed is read on, in cells on the picture's longer side: about 1 % of the picture a cell, finer than a pin is wide.
    static let gridLongSide = 96
    /// Coverage at or above this is selected, as the overlay's half tint shows it.
    static let selected: Float = 0.5
    /// Below this nowhere is selected at all, and the pin has nowhere to stand.
    static let least: Float = 0.02

    /// The pin's place as fractions of the picture, upright from its top left; nil when the seed selects nothing. `width` and `height` are
    /// the picture's, for its shape: the seed is stretched over it as the coverage engine stretches it (`MaskSeedCoverage.stretched`).
    static func point(of seed: MaskRaster, complement: Bool, width: Int, height: Int) -> CGPoint? {
        let long = max(width, height), side = gridLongSide
        guard long > 0 else { return nil }
        let gw = width >= height ? side : max(1, Int((Double(side) * Double(width) / Double(long)).rounded()))
        let gh = height > width ? side : max(1, Int((Double(side) * Double(height) / Double(long)).rounded()))
        let values = MaskSeedCoverage.stretched(seed, width: gw, height: gh, complement: complement)
        func centre(_ index: Int) -> CGPoint {
            CGPoint(x: (CGFloat(index % gw) + 0.5) / CGFloat(gw), y: (CGFloat(index / gw) + 0.5) / CGFloat(gh))
        }
        let inside = values.map { $0 >= selected }
        guard inside.contains(true) else {
            // Nowhere at half: the most selected cell, if any is selected at all.
            guard let best = values.indices.max(by: { values[$0] < values[$1] }), values[best] >= least else { return nil }
            return centre(best)
        }
        let distances = squaredDistances(inside, width: gw, height: gh)
        // Ties go to the cell nearest the selection's centroid, then to the first, so the answer is one point.
        var sx = 0.0, sy = 0.0, n = 0.0
        for index in inside.indices where inside[index] { sx += Double(index % gw); sy += Double(index / gw); n += 1 }
        let cx = sx / n, cy = sy / n
        var best = 0, bestDistance = -1.0, bestSpread = Double.infinity
        for index in distances.indices where inside[index] {
            let d = distances[index], spread = pow(Double(index % gw) - cx, 2) + pow(Double(index / gw) - cy, 2)
            if d > bestDistance || (d == bestDistance && spread < bestSpread) { best = index; bestDistance = d; bestSpread = spread }
        }
        return centre(best)
    }

    /// Each cell's squared distance, in cells, to the nearest cell not selected, the grid's surround counting as not selected (Felzenszwalb
    /// and Huttenlocher's exact transform, a column pass then a row pass). Pure arithmetic on `inside`.
    static func squaredDistances(_ inside: [Bool], width: Int, height: Int) -> [Double] {
        // Padded by a cell of surround each side.
        let pw = width + 2, ph = height + 2, far = Double(pw * pw + ph * ph)
        var grid = [Double](repeating: 0, count: pw * ph)
        for y in 0..<height { for x in 0..<width where inside[y * width + x] { grid[(y + 1) * pw + x + 1] = far } }
        var column = [Double](repeating: 0, count: ph)
        for x in 0..<pw {
            for y in 0..<ph { column[y] = grid[y * pw + x] }
            let done = transform(column)
            for y in 0..<ph { grid[y * pw + x] = done[y] }
        }
        var row = [Double](repeating: 0, count: pw)
        for y in 0..<ph {
            for x in 0..<pw { row[x] = grid[y * pw + x] }
            let done = transform(row)
            for x in 0..<pw { grid[y * pw + x] = done[x] }
        }
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { out[y * width + x] = grid[(y + 1) * pw + x + 1] } }
        return out
    }

    /// The one-dimensional squared distance transform of `f`: the lower envelope of parabolas rooted at each sample.
    private static func transform(_ f: [Double]) -> [Double] {
        let n = f.count
        guard n > 0 else { return [] }
        var d = [Double](repeating: 0, count: n), v = [Int](repeating: 0, count: n), z = [Double](repeating: 0, count: n + 1)
        var k = 0
        z[0] = -.infinity; z[1] = .infinity
        for q in 1..<max(1, n) {
            var s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
            while s <= z[k] {
                k -= 1
                s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
            }
            k += 1
            v[k] = q; z[k] = s; z[k + 1] = .infinity
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            d[q] = Double((q - v[k]) * (q - v[k])) + f[v[k]]
        }
        return d
    }
}

/// The smart selections' pins, found off the main actor from the seeds as stored and kept by what names them: a raster's id is its
/// pixels' digest, so a point found once is that seed's for good. Only the frame view's pins read `points`, so a seed's landing redraws
/// them and nothing else.
@MainActor @Observable
final class MaskPinSeeds {
    /// What a point is found from: the seed's pixels, whether the selection is their complement (Background), and the picture's shape.
    struct Key: Hashable, Sendable {
        let raster: RasterID
        let complement: Bool
        let width: Int
        let height: Int

        init(_ selection: SmartSelection, raster: RasterRef) {
            self.raster = raster.id
            complement = selection.kind == .background
            width = selection.frame?.width ?? raster.width
            height = selection.frame?.height ?? raster.height
        }
    }

    /// Points kept, a few bytes each.
    static let kept = 64

    private(set) var points: [Key: CGPoint?] = [:]
    /// Reads a seed's pixels, off the main actor: the model's library, set once it is known. None in a test of placement alone.
    @ObservationIgnored var load: (@Sendable (RasterRef) -> MaskRaster?)?
    @ObservationIgnored private var running: Set<Key> = []
    /// For the tests and the drive hook: the seeds read for a pin.
    @ObservationIgnored private(set) var readCount = 0

    /// What `selection`'s seed says of its pin now.
    func point(for selection: SmartSelection) -> MaskSeedPinPoint {
        guard let raster = selection.raster else { return .nothing }
        guard let found = points[Key(selection, raster: raster)] else { return .unknown }
        return found.map(MaskSeedPinPoint.found) ?? .nothing
    }

    /// Finds the points of `selections` not found yet, each once.
    func want(_ selections: [SmartSelection]) {
        guard let load else { return }
        for selection in selections {
            guard let raster = selection.raster else { continue }
            let key = Key(selection, raster: raster)
            guard points[key] == nil, !running.contains(key) else { continue }
            running.insert(key)
            readCount += 1
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) { () -> CGPoint? in
                    guard let seed = load(raster) else { return nil }
                    return MaskSeedPin.point(of: seed, complement: key.complement, width: key.width, height: key.height)
                }.value
                guard let self else { return }
                self.running.remove(key)
                if self.points.count >= Self.kept { self.points.removeAll() }
                self.points[key] = .some(found)
            }
        }
    }

    /// Waits for the points under way. For the tests.
    func settle() async {
        while !running.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

// MARK: - The pins on screen

/// One mask's pin, where it is in the frame view's area.
struct MaskPin: Equatable, Identifiable, Sendable {
    /// The mask's.
    let id: UUID
    var point: CGPoint
    /// The component it stands for.
    var component: Int
    var isSelected = false
    var isHovered = false
    /// A mask turned off: its pin stays, dimmed.
    var isEnabled = true
    /// The selected gradient's own handle that moves it whole stands here: one target, whose dot is the pin's core.
    var isOnHandle = false
    /// The pointer holds it down: it lifts.
    var isPressed = false
}

/// Whether the pins show and take the pointer: Lightroom's Auto mode, the one this app has, and H for none. Pure, held by `MaskPinTests`.
enum MaskPinVisibility {
    struct Inputs: Equatable {
        /// The Adjust inspector shows its Masks tab, on a frame open in the frame view.
        var isMasksTabShown = false
        var hasMasks = false
        /// H: hidden, for this session.
        var isHidden = false
        /// Space, Compare to Auto, the clipping view, or a frame that cannot be adjusted.
        var standsDown = false
        /// A tool is in hand, whose press every point of the picture is: a pin there would be a target that does nothing.
        var isArmed = false
        /// A gradient is being drawn, a handle or a shape's number moves, or a stroke paints.
        var isPlacing = false
        /// The pointer is over the frame view's area: not the inspector, the dock or the strip.
        var isPointerInArea = false
        /// A pin's own press is under way, wherever the pointer has gone since.
        var isPinPressed = false
    }

    /// The pins take presses and hovering.
    static func isLive(_ inputs: Inputs) -> Bool {
        inputs.isMasksTabShown && inputs.hasMasks && !inputs.isHidden && !inputs.standsDown && !inputs.isArmed && !inputs.isPlacing
    }

    /// The pins are drawn.
    static func isShown(_ inputs: Inputs) -> Bool {
        isLive(inputs) && (inputs.isPointerInArea || inputs.isPinPressed)
    }
}

/// The pins' arithmetic on screen: which one a point takes, and what an Option-drag makes of an Amount. Pure, held by `MaskPinTests`.
enum MaskPinModel {
    /// How far from a pin's centre a press still takes it, in points: the handles' reach, whatever the zoom.
    static let hitRadius: CGFloat = MaskHandleModel.hitRadius
    /// Pins this close are on one another, as a duplicated mask's are on its original's: a click there goes to the next of them in turn.
    static let stackReach: CGFloat = 1
    /// The pin's glass, in points across: unselected, and selected.
    static let diameter: CGFloat = 14, selectedDiameter: CGFloat = 16

    /// The pins in the order they are drawn: the list's, the selected last, on top.
    static func drawingOrder(_ pins: [MaskPin]) -> [MaskPin] {
        pins.filter { !$0.isSelected } + pins.filter(\.isSelected)
    }

    /// The pin the pointer at `point` rests on: the nearest within `hitRadius`, on the area only, and of pins on one another the one on top.
    static func hovered(at point: CGPoint, in pins: [MaskPin], area: CGSize) -> UUID? {
        stack(at: point, in: pins, area: area).last?.id
    }

    /// The mask a press at `point` selects: the pin on top, or where pins are on one another and the selected one is among them, the
    /// next after it in the list, so a click reaches each in turn.
    static func pressed(at point: CGPoint, in pins: [MaskPin], area: CGSize) -> UUID? {
        let stacked = stack(at: point, in: pins, area: area)
        guard stacked.count > 1, let selected = pins.firstIndex(where: \.isSelected), stacked.contains(where: \.isSelected) else {
            return stacked.last?.id
        }
        // The list's order, from the one after the selected, round to it.
        let around = (1...pins.count).map { pins[(selected + $0) % pins.count] }
        return around.first { pin in stacked.contains { $0.id == pin.id } }?.id
    }

    /// The pins nearest `point` within reach, those on one another together, in drawing order.
    private static func stack(at point: CGPoint, in pins: [MaskPin], area: CGSize) -> [MaskPin] {
        guard CGRect(origin: .zero, size: area).contains(point) else { return [] }
        let reached = pins.map { ($0, hypot($0.point.x - point.x, $0.point.y - point.y)) }.filter { $0.1 <= hitRadius }
        guard let nearest = reached.map(\.1).min() else { return [] }
        let ids = Set(reached.filter { $0.1 <= nearest + stackReach }.map(\.0.id))
        return drawingOrder(pins).filter { ids.contains($0.id) }
    }

    /// The Amount an Option-drag of `dx` points makes of `start`, stored 0 to 2: one per point, as scrubbing the Amount's number goes
    /// (`AdjustmentSliderSpec.scrubbed`). Left and right only, as Lightroom's.
    static func amount(from start: Float, dragged dx: CGFloat) -> Float {
        AdjustmentSliderSpec.maskAmount.scrubbed(from: (start * 100).rounded(), steps: dx) / 100
    }

    /// The value tag's words: "Amount 120", as the row reads it, with no percent sign (SPEC).
    static func tag(_ amount: Float) -> String {
        "Amount \(AdjustmentSliderSpec.maskAmount.formatted((amount * 100).rounded()))"
    }
}

/// The pins over the picture, under the canvas, which has the pointer: no hits. Nothing at all while they do not show, so a frame with
/// pins hidden or the pointer away draws none. Its dots take their pins as values, so a body that runs again with the same pins (a print
/// coming in) draws no dot again.
struct MaskPinsView: View {
    let frame: Frame
    let geometry: FrameGeometry
    @Environment(RollModel.self) private var model

    var body: some View {
        let editor = model.maskEditor
        let pins = editor.shownPins(on: frame, geometry: geometry)
        ZStack {
            MaskPinDots(pins: pins).equatable()
            if let tag = editor.pinAmountTagPlace(on: frame, geometry: geometry) {
                MaskPinAmountTag(mask: tag.mask)
                    .position(tag.point)
            }
        }
        .frame(width: geometry.area.width, height: geometry.area.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: model.masks(for: frame).compactMap(\.pinnedSelection), initial: true) { _, wanted in
            editor.pinSeeds.want(wanted)
        }
    }
}

extension Mask {
    /// The smart selection the pin is found on, where the component it stands for is one: the placement's own walk, stopped there.
    var pinnedSelection: SmartSelection? {
        var wanted: SmartSelection?
        _ = MaskPinPlacement.anchor(of: self) { selection in
            wanted = selection
            return .unknown
        }
        return wanted
    }
}

/// The Option-drag's value tag, "Amount 120": its own view, the only one that reads the Amount as it moves (`MaskEditor.pinDragAmount`,
/// ahead of the print), so a step of the drag runs this body and not the pins'. The tag is most of what the drag costs the main thread: 21 to 24 % of it at 2× with the tag, 12 to 13 %
/// in an experiment build without it (measured, task M).
private struct MaskPinAmountTag: View {
    let mask: UUID
    @Environment(RollModel.self) private var model

    var body: some View {
        if let text = model.maskEditor.pinAmountTagText(for: mask) {
            OverlayTag(text: text).fixedSize()
        }
    }
}

/// The dots, as values.
private struct MaskPinDots: View, Equatable {
    let pins: [MaskPin]

    var body: some View {
        ZStack {
            ForEach(MaskPinModel.drawingOrder(pins)) { pin in
                MaskPinDot(pin: pin).position(pin.point)
            }
        }
    }
}

/// One pin: a drop of glass with a white rim over a dark hairline, the handles' line, which reads on a bright sky and on black in every
/// theme; the selected one a little larger with a solid white core, its gradient's handle's dot when it stands on one. Fixed colours, as
/// the handles' and the ring's: the frame stays the only saturated thing, and no theme colour vanishes on the picture. Increase Contrast
/// makes the hairline firm.
///
/// It answers the pointer as a drop does: it grows under it and as it is selected, a little past its size and back, its core lands in
/// it, and it lifts while it is held. Where it is on the picture is never animated: a zoom, a pan and a gradient's move put it there.
private struct MaskPinDot: View {
    let pin: MaskPin
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let diameter = (pin.isSelected ? MaskPinModel.selectedDiameter : MaskPinModel.diameter) + (pin.isHovered ? 3 : 0)
        let dark = Color.black.opacity(MaskOnPicture.hairline(increased: contrast == .increased))
        let lifted = pin.isPressed && !reduceMotion
        // The rim and the core are the glass's own content, drawn over it, as the split divider's chevrons are on its handle.
        ZStack {
            Circle().inset(by: 1.1).stroke(dark, lineWidth: 2.25)
            Circle().inset(by: 1.1).stroke(Color.white, lineWidth: pin.isHovered ? 1.5 : 1)
            if pin.isSelected {
                // The handle's own dot (`MaskHandlesView`): radius 5 in white over 6 dark.
                ZStack {
                    Circle().fill(dark).frame(width: 12, height: 12)
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                }
                .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(width: diameter, height: diameter)
        .glassEffect(.regular, in: Circle())
        .opacity(pin.isEnabled ? 1 : 0.55)
        .scaleEffect(lifted ? 1.22 : 1)
        .shadow(color: Color.black.opacity(lifted ? 0.3 : 0), radius: 4, y: 2)
        .animation(reduceMotion ? nil : Graphite.Motion.spring(0.28, 0.58), value: diameter)
        .animation(reduceMotion ? nil : Graphite.Motion.spring(0.34, 0.55), value: pin.isSelected)
        .animation(reduceMotion ? nil : (lifted ? Graphite.Motion.spring(0.26, 0.65) : Graphite.Motion.release), value: lifted)
    }
}
