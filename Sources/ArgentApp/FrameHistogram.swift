import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI

/// The distribution of the film the frame view shows, as the Adjust inspector draws it above its tabs:
/// red, green and blue in the codes of the colour space a develop writes, each scaled to the same height
/// so they compare, and how much of the picture is clipped at either end. Measured from the edited film
/// itself, so it follows every edit; it stays the film's while Space shows the neutral raw, Compare to
/// Auto holds the starting point or Option shows clipping, since it describes what the frame develops to.
struct FrameHistogram: Sendable, Equatable {
    static let binCount = 128
    /// What share of the picture has to be clipped before the inspector marks it: a speck at the
    /// print's black or white is not worth a mark.
    static let clippingThreshold = 0.0005
    /// The bins either side of a print's end that its spike reaches once smoothed.
    private static let endReach = 2

    /// Heights from 0 to 1, `binCount` each, shadows first.
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    /// The share of pixels with a channel at or past the print's black, and at or past its white, as the
    /// Option-held clipping view counts them (`LightClipping`).
    var shadowsClipped: Double
    var highlightsClipped: Double

    var clipsShadows: Bool { shadowsClipped > Self.clippingThreshold }
    var clipsHighlights: Bool { highlightsClipped > Self.clippingThreshold }

    /// Measures `image` sampled small in its own colour space, which keeps its codes (sRGB if it names
    /// none that is RGB). Sampled rather than filtered, as `LightClipping.picture` reads it, so a speck of
    /// white stays white and grain keeps its spread rather than being averaged into tones the frame does
    /// not have. `limits` are the print's own ends for the frame's stock and settings
    /// (`FilmPreviews.printLimits`), since a film print can end inside the display's codes.
    static func measure(_ image: CGImage, limits: PrintLimits = .display) -> Self? {
        let width = min(256, max(1, image.width))
        let height = max(1, Int((Double(image.height) / Double(max(1, image.width)) * Double(width)).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return measure(rgbx: pixels, limits: limits)
    }

    /// The histogram of 8-bit pixels laid out red, green, blue and one byte unused. A curve that turns
    /// the print's ends round (white below black) leaves the display's ends, as the clipping view does.
    static func measure(rgbx pixels: [UInt8], limits: PrintLimits = .display) -> Self? {
        let count = pixels.count / 4
        guard count > 0 else { return nil }
        let limits = (0..<3).allSatisfy { limits.white[$0] > limits.black[$0] } ? limits : .display
        var counts = [[Float]](repeating: .init(repeating: 0, count: binCount), count: 3)
        var black = 0, white = 0
        for i in stride(from: 0, to: count * 4, by: 4) {
            let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
            counts[0][bin(r)] += 1
            counts[1][bin(g)] += 1
            counts[2][bin(b)] += 1
            if r <= limits.black.x || g <= limits.black.y || b <= limits.black.z { black += 1 }
            if r >= limits.white.x || g >= limits.white.y || b >= limits.white.z { white += 1 }
        }
        let smoothed = counts.map(smooth)
        // One scale for the three, from the tallest bin between the print's ends and clear of their
        // spikes' reach, so a crushed black or a paper white does not flatten everything else; the
        // spike is cut at the top instead. A picture all at its ends scales by its spike.
        let low = bin(limits.black.max()) + endReach + 1, high = bin(limits.white.min()) - endReach - 1
        let interior = low <= high ? smoothed.map { $0[low...high].max() ?? 0 }.max() ?? 0 : 0
        let scale = interior > 0 ? interior : max(1, smoothed.flatMap { $0 }.max() ?? 1)
        let heights = smoothed.map { channel in channel.map { min(1, $0 / scale) } }
        return Self(red: heights[0], green: heights[1], blue: heights[2],
                    shadowsClipped: Double(black) / Double(count), highlightsClipped: Double(white) / Double(count))
    }

    /// The bin of an 8-bit code: two codes to a bin.
    static func bin(_ code: UInt8) -> Int { Int(code) * binCount / 256 }

    /// A five-bin binomial average, so a downscaled picture's comb of empty bins and its noise read as
    /// the shape they are, not as a row of spikes.
    private static func smooth(_ bins: [Float]) -> [Float] {
        let weights: [Float] = [1, 4, 6, 4, 1]
        return bins.indices.map { i in
            weights.indices.reduce(Float(0)) { sum, k in
                sum + weights[k] * bins[min(bins.count - 1, max(0, i + k - 2))]
            } / 16
        }
    }

    /// What VoiceOver and the help tag say of it.
    var summary: String {
        func percent(_ share: Double) -> String { share.formatted(.percent.precision(.fractionLength(1))) }
        switch (clipsShadows, clipsHighlights) {
        case (true, true): return "Shadows clipped \(percent(shadowsClipped)), highlights clipped \(percent(highlightsClipped))"
        case (true, false): return "Shadows clipped \(percent(shadowsClipped))"
        case (false, true): return "Highlights clipped \(percent(highlightsClipped))"
        case (false, false): return "No clipping"
        }
    }
}

// MARK: - The histogram's tonal ranges

extension FrameHistogram {
    /// The five ranges of the histogram that a drag moves, as Lightroom's histogram has them, shadows first: Blacks, Shadows,
    /// Exposure, Highlights and Whites, each a share of its width. A control's row lights the same range, so what a row shows
    /// is what a drag there would move.
    static let ranges: [(control: ManualAdjustments.Control, range: ClosedRange<Double>)] = [
        (.blacks, 0...0.10), (.shadows, 0.10...0.35), (.exposure, 0.35...0.65), (.highlights, 0.65...0.90), (.whites, 0.90...1),
    ]

    /// The range `control` works in: its own of the five. Contrast works across the whole.
    static func range(of control: ManualAdjustments.Control) -> ClosedRange<Double> {
        ranges.first { $0.control == control }?.range ?? 0...1
    }

    /// The control whose range holds `fraction` of the histogram's width; past either end, the one at that end.
    static func control(at fraction: Double) -> ManualAdjustments.Control {
        ranges.first { fraction < $0.range.upperBound }?.control ?? .whites
    }

    /// `control` after a drag of `distance`, a share of the histogram's width, from `start`: the whole width is half the
    /// control's range, so a drag across a range moves it far enough to see and not past where it began to matter.
    static func dragged(_ control: ManualAdjustments.Control, from start: Float, by distance: Double) -> Float {
        control.snapped(start + Float(distance) * (control.range.upperBound - control.range.lowerBound) / 2)
    }
}

/// A drag on one of the histogram's ranges, apart from the view that takes the pointer, so its pairing with the model's Light
/// gesture is held by tests. Begun, it has opened the gesture (`RollModel.beginLightAdjusting`); each move sends the range's
/// control a step, to the print alone (`moveLight`); ended, it closes the gesture, which writes the edit and its one undo step.
struct HistogramRangeDrag: Equatable {
    let control: ManualAdjustments.Control
    /// The value the drag counts from and the pointer's travel it is counted from, a share of the histogram's width: the
    /// press's, or where a reset, a paste or an undo under the drag left them.
    private var start: Float
    private var origin: Double
    private var lastTravel: Double = 0
    private(set) var value: Float
    /// The Light gesture the drag is in (`RollModel.lightGestureGeneration`).
    private var generation: Int

    /// A drag begun at `fraction` of the histogram's width: on the control whose range holds it, with the gesture opened.
    @MainActor init(at fraction: Double, on frame: Frame, model: RollModel) {
        control = FrameHistogram.control(at: fraction)
        model.beginLightAdjusting(for: frame)
        start = model.manualAdjustments(for: frame).value(for: control)
        origin = 0
        value = start
        generation = model.lightGestureGeneration
    }

    /// The pointer is `travel` from its press, a share of the width: the control goes that far from where it began
    /// (`FrameHistogram.dragged`). A reset, a paste or an undo under the drag replaces the gesture, and the drag goes on from
    /// the new value and the last pointer position delivered before the interruption.
    @MainActor mutating func move(to travel: Double, on frame: Frame, model: RollModel) {
        if generation != model.lightGestureGeneration {
            generation = model.lightGestureGeneration
            start = model.manualAdjustments(for: frame).value(for: control)
            origin = lastTravel
            value = start
        }
        lastTravel = travel
        let moved = FrameHistogram.dragged(control, from: start, by: travel - origin)
        guard moved != value else { return }
        value = moved
        model.moveLight(.light(control), to: moved, for: frame)
    }

    /// The drag is over, however it ended: the gesture is closed.
    @MainActor func end(on frame: Frame, model: RollModel) {
        model.endLightAdjusting(for: frame)
    }

    /// Mouse-up can carry movement beyond the last drag event. An interrupted press no longer
    /// owns the model's gesture and must leave the committed edit alone.
    @MainActor mutating func release(at travel: Double, hovering zone: ManualAdjustments.Control?, on frame: Frame, model: RollModel) {
        guard model.lightAdjusting == frame.url else { return }
        move(to: travel, on: frame, model: model)
        end(on: frame, model: model)
        model.histogramZone = zone
    }

    /// A double-click on `control`'s range: the control back at zero, one gesture and one undo step, unless it is there.
    @MainActor static func reset(_ control: ManualAdjustments.Control, on frame: Frame, model: RollModel) {
        guard model.manualAdjustments(for: frame).value(for: control) != 0 else { return }
        model.beginLightAdjusting(for: frame)
        model.moveLight(.light(control), to: 0, for: frame)
        model.endLightAdjusting(for: frame)
    }
}

/// The inspector's histogram for `frame`, apart from the inspector's body: a new film comes up to 30
/// times a second in a Light drag, and only this leaf reads it, so the heading, the tabs and the rows
/// are not built again for each (docs/manual-development.md, the Light drag).
///
/// It also controls the frame’s global Light values. The pointer over it lights the range under it, one of five
/// (`FrameHistogram.ranges`), and a drag there moves that range's control, left to lower it and right to raise it, as one edit
/// gesture and one undo step: the print follows each step and the edit takes the last (`RollModel.moveLight`), as a row's drag
/// does (`HistogramRangeDrag`). The range's name stands in it with the value as it moves, since the row itself shows the value
/// only once the gesture ends. A double-click resets the range's control. A Light row lights its own range from its side
/// (`RollModel.histogramZone`).
///
/// A drag ends when its gesture does, and also when the histogram stops being a control under it: another tab chosen by its
/// key, the inspector closed, or a frame that can no longer be adjusted. The rest of an interrupted press is ignored.
struct InspectorHistogram: View {
    let frame: Frame
    var compact = false
    @Environment(RollModel.self) private var model
    @State private var drag: HistogramRangeDrag?
    @State private var size = CGSize.zero
    @State private var interrupted = false
    @GestureState private var tracking = false

    private var isLive: Bool {
        model.adjustInspectorFrame?.url == frame.url && model.canAdjust(frame)
    }

    var body: some View {
        // Keep the range quiet while the frame cannot be edited.
        let lit = isLive ? drag?.control ?? model.histogramZone : nil
        FrameHistogramView(histogram: model.frameHistogramFrame == frame.url ? model.frameHistogram : nil,
                           compact: compact, zone: lit.map { control in
                               let values = model.printedLight.flatMap { $0.frame == frame.url ? $0.values : nil }
                                   ?? model.manualAdjustments(for: frame)
                               let value = AdjustmentSliderSpec.light(control).formatted(drag?.value ?? values.value(for: control))
                               return FrameHistogramView.Zone(range: FrameHistogram.range(of: control),
                                                              title: "\(control.title) \(value)\(control == .exposure ? " EV" : "")")
                           },
                           help: isLive ? "Drag a tonal range left or right to change it. Double-click to reset it." : nil)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard drag == nil, !interrupted else { return }
                switch phase {
                case .active(let point):
                    let zone = zone(at: point)
                    if model.histogramZone != zone { model.histogramZone = zone }
                case .ended: model.histogramZone = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
                .updating($tracking) { _, tracking, _ in tracking = true }
                .onChanged(move)
                .onEnded { gesture in
                    if var last = drag, isLive, size.width > 0 {
                        last.release(at: gesture.translation.width / size.width, hovering: zone(at: gesture.location), on: frame, model: model)
                        drag = nil
                    } else {
                        end()
                    }
                    interrupted = false
                })
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                guard isLive, size.width > 0 else { return }
                HistogramRangeDrag.reset(FrameHistogram.control(at: point.x / size.width), on: frame, model: model)
            }
            .onChange(of: isLive) { _, live in if !live { interrupt() } }
            .onChange(of: model.inspectorNavigation) { _, _ in interrupt() }
            .onChange(of: tracking) { _, active in
                // A canceled recognizer resets its gesture state without delivering a release.
                if !active {
                    if drag != nil { interrupt() }
                    interrupted = false
                }
            }
            .onDisappear { interrupt() }
    }

    private func zone(at point: CGPoint) -> ManualAdjustments.Control? {
        isLive && CGRect(origin: .zero, size: size).contains(point) ? FrameHistogram.control(at: point.x / size.width) : nil
    }

    private func move(_ gesture: DragGesture.Value) {
        guard isLive, size.width > 0 else { interrupt(); return }
        guard !interrupted else { return }
        if drag != nil, model.lightAdjusting != frame.url { interrupt(); return }
        var now = drag ?? HistogramRangeDrag(at: gesture.startLocation.x / size.width, on: frame, model: model)
        if drag == nil { model.histogramZone = now.control }
        now.move(to: gesture.translation.width / size.width, on: frame, model: model)
        if now != drag { drag = now }
    }

    private func interrupt() {
        if drag != nil || tracking { interrupted = true }
        end()
        model.histogramZone = nil
    }

    private func end() {
        guard let ended = drag else { return }
        drag = nil
        if model.lightAdjusting == frame.url { ended.end(on: frame, model: model) }
    }
}

/// The histogram at the top of the Adjust inspector: the three channels as soft fills that add up to
/// gray where they agree, so colour shows only where the channels part, under one fine line, in a well of the panel's ink,
/// over a step wedge that says which end is dark. A mark in each upper corner fills when the picture clips at that end. A lit
/// range (`Zone`) is a band across it with its name. Until the film is measured it keeps its height, the well and the wedge
/// alone.
struct FrameHistogramView: View {
    let histogram: FrameHistogram?
    var compact = false
    /// The tonal range lit, with what to call it.
    var zone: Zone?
    /// What the help tag says before the clipping, when the histogram is also a control.
    var help: String?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Zone: Equatable {
        var range: ClosedRange<Double>
        var title: String
    }

    /// The plot's height, and the whole's with its wedge under it.
    static let plotHeight: CGFloat = 76
    static let height: CGFloat = plotHeight + StepWedge.thickness
    static let radius: CGFloat = 6
    /// A clipping mark, and how far in from the corner it stands.
    private static let mark: CGFloat = 6
    private static let markInset: CGFloat = 6
    /// The dark themes' fills are added in a layer of their own and laid on the panel at this opacity,
    /// so where the three channels agree they make a light gray under the text's, never a white.
    private static let darkLayerOpacity = 0.8

    var body: some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(height: compact ? 52 : Self.plotHeight)
            .overlay { GeometryReader { proxy in band(in: proxy.size) }.allowsHitTesting(false) }
            StepWedge()
                .frame(height: StepWedge.thickness)
        }
        .frame(maxWidth: .infinity)
        .background(Graphite.well)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: zone?.range)
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(histogram?.summary ?? "Not measured")
        .help([help, histogram?.summary ?? (help == nil ? "Histogram" : nil)].compactMap { $0 }.joined(separator: " "))
    }

    /// The readout uses the full plot so long labels fit even over its narrow end zones.
    @ViewBuilder private func band(in size: CGSize) -> some View {
        if let zone {
            let start = zone.range.lowerBound * size.width, end = zone.range.upperBound * size.width
            let labelAlignment: Alignment = zone.range.lowerBound >= 0.5 ? .trailing : zone.range.upperBound <= 0.5 ? .leading : .center
            Rectangle()
                .fill(Graphite.ink(0.07))
                .overlay(alignment: .leading) { Graphite.ink(0.3).frame(width: 1) }
                .overlay(alignment: .trailing) { Graphite.ink(0.3).frame(width: 1) }
                .frame(width: max(0, end - start), height: size.height)
                .offset(x: start)
                .transition(.opacity)
            Text(verbatim: zone.title)
                .font(Graphite.Typeface.caption.monospacedDigit())
                .foregroundStyle(Graphite.text)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Graphite.chrome.opacity(0.94)))
                .frame(maxWidth: .infinity, alignment: labelAlignment)
                .padding(.horizontal, Self.markInset + Self.mark + 3)
                .padding(.top, 2)
                .accessibilityHidden(true)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // The plot stands on the wedge under it. Room above the tallest bin for the clipping marks.
        let baseline = size.height
        let plot = CGRect(x: 0, y: Self.markInset + Self.mark + 4, width: size.width, height: baseline - Self.markInset - Self.mark - 4)
        let increased = contrast == .increased
        let isDark = Graphite.isDark

        // A ring in each upper corner, filled where the picture clips at that end: there whether or not it does, so the mark
        // that comes is known for what it is.
        for (isRight, clips) in [(false, histogram?.clipsShadows == true), (true, histogram?.clipsHighlights == true)] {
            let ring = CGRect(x: isRight ? size.width - Self.markInset - Self.mark : Self.markInset, y: Self.markInset, width: Self.mark, height: Self.mark)
            if clips {
                context.fill(Path(ellipseIn: ring), with: .color(Graphite.text.opacity(0.92)))
            } else {
                context.stroke(Path(ellipseIn: ring.insetBy(dx: 0.5, dy: 0.5)), with: .color(Graphite.ink(increased ? 0.6 : 0.3)), lineWidth: 1)
            }
        }
        guard let histogram else { return }

        let channels: [([Float], Color)] = [
            (histogram.red, Self.channelColor(0, isDark: isDark)),
            (histogram.green, Self.channelColor(1, isDark: isDark)),
            (histogram.blue, Self.channelColor(2, isDark: isDark)),
        ]
        // Added on a dark panel, in their own layer, and multiplied on a light one, so where the three
        // agree they make gray and colour shows only where they part.
        func fill(_ layer: inout GraphicsContext, top: Double, bottom: Double) {
            for (values, color) in channels {
                layer.fill(Self.path(values, in: plot, baseline: baseline, closed: true),
                           with: .linearGradient(Gradient(colors: [color.opacity(top), color.opacity(bottom)]),
                                                 startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: baseline)))
            }
        }
        if isDark {
            var layered = context
            layered.opacity = Self.darkLayerOpacity
            layered.drawLayer { layer in
                layer.blendMode = .plusLighter
                fill(&layer, top: 0.85, bottom: 0.35)
            }
        } else {
            var multiplied = context
            multiplied.blendMode = .multiply
            fill(&multiplied, top: 0.9, bottom: 0.45)
        }

        // One fine line along the top of the three, the shape read first; kept off the foot where
        // the picture has nothing, so the wedge's edge stays the wedge's.
        let envelope = zip(histogram.red, zip(histogram.green, histogram.blue)).map { max($0, $1.0, $1.1) }
        var line = context
        line.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: baseline - 1)))
        line.stroke(Self.path(envelope, in: plot, baseline: baseline, closed: false),
                    with: .color(Graphite.ink(increased ? 0.8 : isDark ? 0.5 : 0.45)),
                    style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }

    /// Red, green or blue, softened so the three sum to a neutral: light tints added on a dark
    /// panel, pale ones multiplied on a light one.
    nonisolated static func channelColor(_ channel: Int, isDark: Bool) -> Color {
        let dark: [(Double, Double, Double)] = [(1.0, 0.40, 0.40), (0.40, 0.86, 0.52), (0.42, 0.62, 1.0)]
        let light: [(Double, Double, Double)] = [(1.0, 0.62, 0.62), (0.62, 0.92, 0.70), (0.64, 0.76, 1.0)]
        let (r, g, b) = (isDark ? dark : light)[channel]
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    /// A smooth line through the bins' tops, across `plot`, closed down to the baseline for a fill.
    nonisolated static func path(_ values: [Float], in plot: CGRect, baseline: CGFloat, closed: Bool) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            let step = plot.width / CGFloat(values.count - 1)
            let points = values.enumerated().map { i, value in
                CGPoint(x: plot.minX + CGFloat(i) * step, y: baseline - CGFloat(value) * (baseline - plot.minY))
            }
            if closed {
                path.move(to: CGPoint(x: points[0].x, y: baseline))
                path.addLine(to: points[0])
            } else {
                path.move(to: points[0])
            }
            // Through the midpoints, each bin's top the control: smooth, and never above the tallest bin.
            for i in 1..<points.count {
                let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                path.addQuadCurve(to: mid, control: points[i - 1])
            }
            path.addLine(to: points[points.count - 1])
            if closed {
                path.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseline))
                path.closeSubpath()
            }
        }
    }
}
