import ArgentCore
import ArgentRoll
import SwiftUI

// Remove on the photograph (docs/remove-plan.md, section 4.8): whose a press is while its tab shows, where a selection and a
// stroke land on the picture as drawn, and the view that draws them. The model's part is `RollModel+Remove.swift`; what both
// read is `RemoveState.swift`.

// MARK: - What the tab asks of the model

/// What the Remove tab asks of the model, by the model's own names (`RollModel+Remove.swift`). A protocol so a test can stand
/// in for the model and see what a press and each control call; in the app it is always the model.
@MainActor protocol RemoveCommands: AnyObject {
    func removeBrush(_ event: MaskCanvasEvent, on frame: Frame)
    func setRemoveSnapsToObject(_ snaps: Bool)
    func commitRemoval(on frame: Frame)
    func cancelRemoval(_ id: UUID, on frame: Frame)
    func setRemoval(_ id: UUID, isOn: Bool, on frame: Frame)
    func setRemoval(_ id: UUID, includesEffects: Bool, on frame: Frame)
    func remakeRemoval(_ id: UUID, better: Bool, on frame: Frame)
    func deleteRemoval(_ id: UUID, on frame: Frame)
    func resetRemovals(for frame: Frame)
    func showRemovalFace(_ id: UUID, on frame: Frame)
}

extension RollModel: RemoveCommands {}

// MARK: - The brush in hand

/// The Remove brush on the photograph. It is in hand for as long as its tab shows, with nothing to arm, so the canvas, the frame
/// view's keys and the overlay all ask here whether it is.
@MainActor enum RemovePhotograph {
    /// The frame the Remove tab works on: the open frame, while the inspector shows the Remove tab beside it.
    static func frame(_ model: RollModel) -> Frame? {
        model.workspacePage == .roll && model.isAdjustmentsShown && model.openAdjustSection == .remove ? model.shownFrame : nil
    }

    /// Whether Return and the Remove button remove what is selected on `frame`: something is selected and has snapped, on a frame
    /// that can take an edit.
    static func canRemove(on frame: Frame, model: RollModel) -> Bool {
        model.remove.selection.canRemove && model.canAdjust(frame)
    }

    /// Escape on the photograph while the Remove tab shows: whether Remove took it, before it goes on to close the frame. What
    /// is in hand goes first, the stroke and the selection, as a mask's press and tool do; then the frame's newest run.
    static func escape(_ model: RollModel) -> Bool {
        guard let frame = frame(model) else { return false }
        let selection = model.remove.selection
        if selection.coverage != nil || !selection.stroke.isEmpty || selection.isSnapping {
            model.clearRemoveSelection()
            return true
        }
        return model.cancelNewestRemoval(on: frame)
    }

    /// The brush's radius in long sides of the picture, from its size, a diameter in hundredths of one, inside the range the
    /// masks' brush keeps to (`MaskBrushSettings.radius`).
    nonisolated static func brushRadius(size: Double) -> CGFloat {
        let range = MaskSpace.brushRadiusRange
        return CGFloat(min(Double(range.upperBound), max(Double(range.lowerBound), size / 200)))
    }

    /// A size the slider or a key came to, in the slider's own tenths: a `Float`'s 4.1 is a little off as a `Double`.
    nonisolated static func size(_ value: Float) -> Double {
        (Double(value) * 10).rounded() / 10
    }
}

extension AdjustmentSliderSpec {
    /// The Remove brush's one number: the masks' Size by its range, its steps and its keys, starting at the session's own 4.
    static let removeBrushSize: AdjustmentSliderSpec = {
        var spec = AdjustmentSliderSpec.brushSize
        spec.defaultValue = 4
        return spec
    }()
}

// MARK: - A removal's arrival

/// A removal changing the frame's picture: one arriving, or its eye, its shadow switch, a delete or an undo. The frame view fades
/// the new film in over the old one, so the object is seen to go (plan section 4.8, step 5), where any other film that replaces
/// one on a frame with adjustments takes its place at once.
enum RemovalArrival {
    /// How long the object takes to go.
    static let seconds = 0.15

    static var animation: Animation { Graphite.Motion.ease(seconds) }

    /// Whether the film of `new` replacing the film of `old` is one: what the lens stage composites of the frame's removals
    /// differs between them (`[Removal].renderDigest`). A first film is none.
    static func isOne(from old: DevelopSettings?, to new: DevelopSettings) -> Bool {
        guard let old else { return false }
        return old.lens.removals.renderDigest != new.lens.removals.renderDigest
    }
}

// MARK: - Where it lands

/// Where the Remove tab's coverage and strokes are drawn in the frame view's area. A coverage and a stroke are in fractions of the
/// corrected picture from its top left, which is the picture `FrameGeometry` places, so they keep with it through a zoom and a
/// pan. Pure; `RemoveOverlayTests` holds it.
enum RemoveOverlayGeometry {
    /// The rectangle `fractions` of the picture take in the area: a coverage's `frame`.
    static func rect(of fractions: CGRect, in geometry: FrameGeometry) -> CGRect {
        let picture = geometry.picture
        return CGRect(x: picture.minX + fractions.minX * picture.width, y: picture.minY + fractions.minY * picture.height,
                      width: fractions.width * picture.width, height: fractions.height * picture.height)
    }

    /// A stroke's points in the area.
    static func points(of stroke: [CGPoint], in geometry: FrameGeometry) -> [CGPoint] {
        stroke.map(geometry.point(forNormalized:))
    }

    /// How wide a stroke of a brush of `size` is drawn: the ring's diameter on the picture as drawn now.
    static func strokeWidth(size: Double, in geometry: FrameGeometry) -> CGFloat {
        2 * RemovePhotograph.brushRadius(size: size) * geometry.longSide
    }

    /// The part of the picture the overlay may draw on: the whole of it, less a split comparison's neutral side on its left, which
    /// shows neither the tint nor the removal.
    static func filmSide(of geometry: FrameGeometry, neutralWidth: CGFloat?) -> CGRect {
        let picture = geometry.picture, neutral = min(max(neutralWidth ?? 0, 0), picture.width)
        return CGRect(x: picture.minX + neutral, y: picture.minY, width: picture.width - neutral, height: picture.height)
    }
}

// MARK: - The edge

/// A coverage's edge as lines: where it crosses one half, found on a grid of at most `longSide` cells and joined into closed
/// loops, in the unit square of the coverage's `frame`. The overlay strokes them at a width of its own, so the edge is as fine at
/// 400 % as at fit, where a raster of the edge would grow with the zoom.
enum RemoveOutline {
    /// The longer side of the grid the edge is found on. A selection comes at the brush picture's size, thousands of pixels a
    /// side; the edge of an object needs no more than this, and the lines are smoothed between its crossings.
    static let longSide = 512

    /// `coverage` averaged over blocks of `block` pixels a side: `width` by `height` values, 0 to 255, top row first.
    static func reduced(_ coverage: RemoveCoverage, block: Int) -> (width: Int, height: Int, values: [Float]) {
        let width = (coverage.width + block - 1) / block, height = (coverage.height + block - 1) / block
        var values = [Float](repeating: 0, count: width * height)
        coverage.values.withUnsafeBufferPointer { source in
            for y in 0..<height {
                let rows = (y * block)..<min(coverage.height, (y + 1) * block)
                for x in 0..<width {
                    let columns = (x * block)..<min(coverage.width, (x + 1) * block)
                    var sum = 0
                    for row in rows {
                        let base = row * coverage.width
                        for column in columns { sum += Int(source[base + column]) }
                    }
                    values[y * width + x] = Float(sum) / Float(rows.count * columns.count)
                }
            }
        }
        return (width, height, values)
    }

    /// The edge's closed loops, each a run of points in the unit square. A coverage that reaches its raster's side closes along
    /// that side, so every loop is whole.
    static func loops(of coverage: RemoveCoverage) -> [[CGPoint]] {
        guard coverage.width > 0, coverage.height > 0, coverage.values.count == coverage.width * coverage.height else { return [] }
        let block = max(1, (max(coverage.width, coverage.height) + longSide - 1) / longSide)
        let grid = reduced(coverage, block: block)
        // A border of nothing round the grid: marching squares then closes what the raster's side cuts.
        let across = grid.width + 2, down = grid.height + 2
        var nodes = [Float](repeating: 0, count: across * down)
        for y in 0..<grid.height {
            for x in 0..<grid.width { nodes[(y + 1) * across + x + 1] = grid.values[y * grid.width + x] }
        }
        // A node is a block's centre; the border's lie as far outside the raster as the first centres lie inside, so what fills
        // the raster to its side crosses one half on that side.
        func place(_ i: Int, _ j: Int) -> CGPoint {
            CGPoint(x: (CGFloat(i - 1) + 0.5) * CGFloat(block) / CGFloat(coverage.width),
                    y: (CGFloat(j - 1) + 0.5) * CGFloat(block) / CGFloat(coverage.height))
        }
        let half: Float = 127.5
        // A cell's edges are named by the node they start at: the one going right from it, and the one going down.
        func right(_ i: Int, _ j: Int) -> Int { 2 * (j * across + i) }
        func below(_ i: Int, _ j: Int) -> Int { 2 * (j * across + i) + 1 }
        var crossings: [Int: CGPoint] = [:]
        func cross(_ edge: Int, _ a: (Int, Int), _ b: (Int, Int)) {
            guard crossings[edge] == nil else { return }
            let va = nodes[a.1 * across + a.0], vb = nodes[b.1 * across + b.0]
            let t = CGFloat(vb == va ? 0.5 : min(max((half - va) / (vb - va), 0), 1))
            let pa = place(a.0, a.1), pb = place(b.0, b.1)
            crossings[edge] = CGPoint(x: min(max(pa.x + (pb.x - pa.x) * t, 0), 1), y: min(max(pa.y + (pb.y - pa.y) * t, 0), 1))
        }
        var segments: [(Int, Int)] = []
        for j in 0..<(down - 1) {
            for i in 0..<(across - 1) {
                let a = nodes[j * across + i], b = nodes[j * across + i + 1]
                let c = nodes[(j + 1) * across + i + 1], d = nodes[(j + 1) * across + i]
                let inside = (a > half ? 1 : 0) | (b > half ? 2 : 0) | (c > half ? 4 : 0) | (d > half ? 8 : 0)
                guard inside != 0, inside != 15 else { continue }
                let top = right(i, j), bottom = right(i, j + 1), left = below(i, j), far = below(i + 1, j)
                // Two corners inside across a diagonal: joined through the middle when the middle is inside.
                let joined = (a + b + c + d) / 4 > half
                let lines: [(Int, Int)] = switch inside {
                case 1, 14: [(left, top)]
                case 2, 13: [(top, far)]
                case 3, 12: [(left, far)]
                case 4, 11: [(far, bottom)]
                case 6, 9: [(top, bottom)]
                case 7, 8: [(left, bottom)]
                case 5: joined ? [(top, far), (left, bottom)] : [(left, top), (far, bottom)]
                default: joined ? [(left, top), (far, bottom)] : [(top, far), (left, bottom)]
                }
                for line in lines {
                    for edge in [line.0, line.1] {
                        switch edge {
                        case top: cross(edge, (i, j), (i + 1, j))
                        case bottom: cross(edge, (i, j + 1), (i + 1, j + 1))
                        case left: cross(edge, (i, j), (i, j + 1))
                        default: cross(edge, (i + 1, j), (i + 1, j + 1))
                        }
                    }
                    segments.append(line)
                }
            }
        }
        // Each crossing is an end of two segments, one from the cell on either side of its edge: followed from one to the next
        // they close.
        var meeting: [Int: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            meeting[segment.0, default: []].append(index)
            meeting[segment.1, default: []].append(index)
        }
        var used = [Bool](repeating: false, count: segments.count)
        var loops: [[CGPoint]] = []
        for start in segments.indices where !used[start] {
            var loop: [CGPoint] = []
            var segment = start, edge = segments[start].1
            let first = segments[start].0
            used[start] = true
            if let point = crossings[first] { loop.append(point) }
            while edge != first {
                if let point = crossings[edge] { loop.append(point) }
                guard let next = meeting[edge]?.first(where: { $0 != segment && !used[$0] }) else { break }
                used[next] = true
                segment = next
                edge = segments[next].0 == edge ? segments[next].1 : segments[next].0
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    /// The loops as one path in the unit square, each rounded through the middles of its sides: a grid's crossings step, and an
    /// object's edge does not.
    static func path(of loops: [[CGPoint]]) -> Path {
        var path = Path()
        for loop in loops where loop.count >= 3 {
            let count = loop.count
            func middle(_ index: Int) -> CGPoint {
                let a = loop[index % count], b = loop[(index + 1) % count]
                return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
            path.move(to: middle(count - 1))
            for index in 0..<count { path.addQuadCurve(to: middle(index), control: loop[index]) }
            path.closeSubpath()
        }
        return path
    }
}

/// A coverage made ready to draw, off the main actor: its tint as an alpha-only picture, which a template `Image` colours as the
/// masks' overlay is coloured, and its edge.
struct RemovePicture: @unchecked Sendable {
    /// The tint's longer side at most: a soft wash loses nothing to the scale, and the edge is drawn apart.
    static let tintLongSide = MaskOverlayRequest.settledLongSide

    let tint: CGImage?
    /// In the unit square of `frame`.
    let edge: Path
    /// Where the coverage lies, in fractions of the picture (`RemoveCoverage.frame`).
    let frame: CGRect

    static func make(_ coverage: RemoveCoverage) -> RemovePicture {
        guard coverage.width > 0, coverage.height > 0, coverage.values.count == coverage.width * coverage.height else {
            return RemovePicture(tint: nil, edge: Path(), frame: coverage.frame)
        }
        let block = max(1, (max(coverage.width, coverage.height) + tintLongSide - 1) / tintLongSide)
        let tint: CGImage?
        if block == 1 {
            tint = MaskOverlayStore.image(of: coverage.values, width: coverage.width, height: coverage.height)
        } else {
            let small = RemoveOutline.reduced(coverage, block: block)
            tint = MaskOverlayStore.image(of: small.values.map { UInt8(min(255, max(0, $0 + 0.5))) }, width: small.width, height: small.height)
        }
        return RemovePicture(tint: tint, edge: RemoveOutline.path(of: RemoveOutline.loops(of: coverage)), frame: coverage.frame)
    }
}

// MARK: - The view

/// Over the picture, under the canvas, while the Remove tab shows: what is selected as a tint in the overlay's colour with a
/// clear edge, the stroke under the pointer, and the outline of the removal whose row the pointer rests on. It takes no event and
/// stands down as the masks' overlay does (Space, Compare to Auto, the clipping view, a frame that cannot be adjusted).
struct RemoveOverlayView: View {
    let frame: Frame
    let geometry: FrameGeometry
    /// How much of the picture's width, from its left edge, shows the neutral raw while Compare splits it; nil with no split up.
    let neutralWidth: CGFloat?
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// The selection's coverage and the hovered removal's, made ready to draw.
    @State private var selected: RemovePicture?
    @State private var outlined: RemovePicture?

    /// How much of the tint's strength a stroke that subtracts is drawn at: half, which shows where the brush has been on a busy
    /// picture and is plainly lighter than what is selected beside it. At a third it was lost on foliage (seen, 2026-11-16).
    static let subtractShare = 0.5
    /// How far the edge and the stroke dim, and how long each way, while the segmenter finds the object.
    static let pulseDepth = 0.4, pulseSeconds = 0.7

    /// The removal whose outline shows, and the patch it was read from: one made again draws its new outline.
    private struct Outlined: Equatable {
        var id: UUID?
        var patch: PatchID?
    }

    var body: some View {
        let isShown = RemovePhotograph.frame(model)?.url == frame.url && !model.masksStandDown(frame)
        let selection = isShown ? model.remove.selection : nil
        let hovered = isShown ? model.remove.hovered : nil
        let patch = hovered.flatMap { id in model.manualAdjustments(for: frame).removals.first { $0.id == id }?.patch.id }
        let strength = contrast == .increased || reduceTransparency ? MaskOverlayColour.firmOpacity : MaskOverlayColour.opacity
        // The hovered removal's outline is kept while it fades, so it is drawn for as long as there is one.
        let outline = isShown ? outlined : nil
        Color.clear
            .overlay {
                if selection != nil || outline != nil {
                    ZStack {
                        if let selection {
                            RemoveSelectionLayer(selection: selection, picture: selection.coverage == nil ? nil : selected, geometry: geometry,
                                                 brushSize: model.remove.brushSize, colour: model.maskEditor.overlayColour.color,
                                                 strength: strength)
                        }
                        if let outline {
                            RemoveEdgeLines(edge: outline.edge, rect: RemoveOverlayGeometry.rect(of: outline.frame, in: geometry))
                                .transition(.opacity)
                        }
                    }
                    .mask { RemoveOverlayClip(geometry: geometry, neutralWidth: neutralWidth) }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: selection?.coverage) {
                guard let coverage = selection?.coverage else {
                    selected = nil
                    return
                }
                let made = await Task.detached(priority: .userInitiated) { RemovePicture.make(coverage) }.value
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : Graphite.Motion.quick) { selected = made }
            }
            .task(id: Outlined(id: hovered, patch: patch)) {
                guard let hovered, let coverage = model.removalOutline(hovered, on: frame) else {
                    withAnimation(reduceMotion ? nil : Graphite.Motion.quick) { outlined = nil }
                    return
                }
                let made = await Task.detached(priority: .userInitiated) { RemovePicture.make(coverage) }.value
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : Graphite.Motion.quick) { outlined = made }
            }
    }
}

/// What is being selected: the coverage's tint and the stroke as one wash, so where they overlap is no darker; a stroke that
/// subtracts cut out of it and drawn lighter; then the coverage's edge. The edge and the stroke breathe while the object is found.
private struct RemoveSelectionLayer: View {
    let selection: RemoveSelectionState
    let picture: RemovePicture?
    let geometry: FrameGeometry
    let brushSize: Double
    let colour: Color
    let strength: Double

    var body: some View {
        let points = RemoveOverlayGeometry.points(of: selection.stroke, in: geometry)
        let swath = points.isEmpty ? nil : RemoveStroke(points: points, width: RemoveOverlayGeometry.strokeWidth(size: brushSize, in: geometry))
        let rect = picture.map { RemoveOverlayGeometry.rect(of: $0.frame, in: geometry) }
        ZStack {
            ZStack {
                if let tint = picture?.tint, let rect {
                    Image(decorative: tint, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .renderingMode(.template)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity)
                }
                if let swath {
                    if selection.strokeSubtracts {
                        swath.fill(Color.black).blendMode(.destinationOut)
                    } else {
                        swath.fill().modifier(RemovePulse(isOn: selection.isSnapping))
                    }
                }
            }
            .foregroundStyle(colour)
            .compositingGroup()
            .opacity(strength)
            if let swath, selection.strokeSubtracts {
                swath.fill(colour)
                    .opacity(strength * RemoveOverlayView.subtractShare)
                    .modifier(RemovePulse(isOn: selection.isSnapping))
            }
            if let edge = picture?.edge, let rect {
                RemoveEdgeLines(edge: edge, rect: rect)
                    .modifier(RemovePulse(isOn: selection.isSnapping))
                    .transition(.opacity)
            }
        }
    }
}

/// A stroke's swath in the frame view's area: its line at the brush's width with round ends, a click as the brush's circle.
private struct RemoveStroke: Shape {
    let points: [CGPoint]
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        guard let first = points.first else { return Path() }
        guard points.count > 1 else {
            return Path(ellipseIn: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
        }
        var line = Path()
        line.addLines(points)
        return line.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// A coverage's edge on the photograph, over `rect` of the area: white over a dark hairline, as the brush's ring and a gradient's
/// handles are drawn, which reads on any picture and takes no colour of the theme's.
private struct RemoveEdgeLines: View {
    let edge: Path
    let rect: CGRect
    @Environment(\.colorSchemeContrast) private var contrast

    /// The edge's path scaled from the unit square to the rectangle it is given.
    private struct Lines: Shape {
        let edge: Path

        func path(in rect: CGRect) -> Path {
            edge.applying(CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY))
        }
    }

    var body: some View {
        let dark = Color.black.opacity(MaskOnPicture.hairline(increased: contrast == .increased))
        Lines(edge: edge)
            .stroke(dark, style: StrokeStyle(lineWidth: 2.25, lineJoin: .round))
            .overlay { Lines(edge: edge).stroke(Color.white, style: StrokeStyle(lineWidth: 1, lineJoin: .round)) }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

/// A quiet pulse while something is being found: what it is on dims and comes back, and stands still with Reduce Motion.
private struct RemovePulse: ViewModifier {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDim = false

    func body(content: Content) -> some View {
        content
            .opacity(isDim ? RemoveOverlayView.pulseDepth : 1)
            .onChange(of: isOn, initial: true) { _, on in
                guard !reduceMotion else {
                    isDim = false
                    return
                }
                if on {
                    withAnimation(.easeInOut(duration: RemoveOverlayView.pulseSeconds * Graphite.Motion.slow).repeatForever(autoreverses: true)) { isDim = true }
                } else {
                    withAnimation(Graphite.Motion.quick) { isDim = false }
                }
            }
    }
}

/// What the overlay may draw on, as its mask: the picture's rounded rectangle, and of that only the film side of a split.
private struct RemoveOverlayClip: View {
    let geometry: FrameGeometry
    let neutralWidth: CGFloat?

    var body: some View {
        let picture = geometry.picture, film = RemoveOverlayGeometry.filmSide(of: geometry, neutralWidth: neutralWidth)
        RoundedRectangle(cornerRadius: Metrics.cornerRadius)
            .frame(width: picture.width, height: picture.height)
            .position(x: picture.midX, y: picture.midY)
            .mask {
                Rectangle()
                    .frame(width: film.width, height: film.height)
                    .position(x: film.midX, y: film.midY)
            }
    }
}
