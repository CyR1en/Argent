import ArgentCore
import ArgentRoll
import SwiftUI

/// The Curve tab's controls: on one line the channel, four dots, and Point or Regions; the graph, square, with a step wedge
/// along each axis in place of the words Input and Output; then the selected point's numbers and its Delete, or the
/// four region sliders; and the four starting shapes, drawn. The inspector's foot has the actions
/// shared with Light.
struct CurveEditorView: View {
    let frame: Frame
    @Environment(RollModel.self) private var model
    let requestedChannel: ToneCurves.Channel?
    @State private var channel: ToneCurves.Channel
    @AppStorage("curveEditorMode") private var pointMode = true
    @State private var selectedPoint = -1
    @State private var inputNumber = ""
    @State private var outputNumber = ""
    @State private var validationMessage: String?
    @State private var numberCurve: ChannelCurve?
    @FocusState private var numberFocus: Axis?
    fileprivate enum Axis { case input, output }
    private var curves: ToneCurves { model.manualAdjustments(for: frame).curves }
    private var curve: ChannelCurve { curves.curve(for: channel) }
    private var selected: CurvePoint? { curve.points.indices.contains(selectedPoint) ? curve.points[selectedPoint] : nil }
    /// An interior point, whose Input can move between its neighbours; the endpoints' stay at 0 and 255.
    private var isInteriorSelected: Bool { selectedPoint > 0 && selectedPoint < curve.points.count - 1 }

    /// The region whose slider the pointer is over, which the graph lights.
    @State private var litRegion: CurveRegion?

    init(frame: Frame, requestedChannel: ToneCurves.Channel? = nil) {
        self.frame = frame
        self.requestedChannel = requestedChannel
        _channel = State(initialValue: requestedChannel ?? .tone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Four dots of 24 points and their gaps, 102, then Point and Regions in 138: the column's 248 with 8 between.
            HStack(spacing: 0) {
                channels
                Spacer(minLength: Graphite.Metric.s)
                modes
            }
            graphPanel
                .padding(.top, Graphite.Metric.m)
            editorControls
                .padding(.top, Graphite.Metric.m)
            InspectorSectionHeader(title: "Starting shape") {
                Text(verbatim: presetTitle)
                    .font(Graphite.Typeface.caption)
                    .foregroundStyle(Graphite.tertiaryText)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .padding(.top, AdjustRowMetric.sectionSpacing)
            .padding(.bottom, AdjustRowMetric.rowSpacing)
            CurveShapeTiles(chosen: ToneCurves.Preset.allCases.first { $0.curve == curve }, channel: channel, choose: choose)
                .equatable()
        }
        .disabled(!model.canAdjust(frame))
        .onChange(of: selectedPoint) { _, _ in syncNumbers() }
        .onChange(of: curve) { _, new in
            if !new.points.indices.contains(selectedPoint) { selectedPoint = -1 }
            if numberFocus != nil, new != numberCurve { numberFocus = nil; syncNumbers(force: true) }
            syncNumbers()
        }
        .onChange(of: requestedChannel) { _, requested in
            if let requested { channel = requested }
        }
        .onChange(of: channel) { _, _ in selectedPoint = -1; syncNumbers() }
        .onChange(of: numberFocus) { old, new in
            if old != nil { commitNumber(axis: old) }
            if new != nil { syncNumbers(force: true); numberCurve = curve; validationMessage = nil }
        }
        .onDisappear { commitNumber(); model.endManualGesture(for: frame) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Curve adjustments for this frame")
    }

    private var modes: some View {
        GraphiteSegmented(selection: Binding(get: { pointMode }, set: { point in
            commitNumber(); numberFocus = nil; pointMode = point
        }), segments: [
            .init(value: true, title: "Point", accessibilityLabel: "Point curve mode",
                  help: "Shape the curve with points on the graph."),
            .init(value: false, title: "Regions", accessibilityLabel: "Regions curve mode",
                  help: "Shape the curve with Shadows, Darks, Lights and Highlights strengths. Points and regions combine."),
        ], fillsWidth: true)
        .frame(width: Self.modesWidth)
    }

    /// Point and Regions, each as wide as the longer, "Regions" with 8 points beside it: what the column has beside the four
    /// channels.
    private static let modesWidth: CGFloat = 138

    /// The four curves as dots in their own colours, Tone's half dark and half light: the graph names the one chosen, and its
    /// line is drawn in that colour. A channel whose curve is shaped has a dot at its corner, as a tab that holds something has.
    private var channels: some View {
        HStack(spacing: 2) {
            ForEach(ToneCurves.Channel.allCases, id: \.self) { candidate in
                CurveChannelDot(channel: candidate, isChosen: candidate == channel, isShaped: !curves.curve(for: candidate).isIdentity) {
                    commitNumber(); numberFocus = nil; channel = candidate
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Curve channel")
    }

    /// The graph, square, in the column's width less its upright wedge. A wedge runs along each axis, black at the graph's
    /// origin, over the stretch the curve's own tones cover (the graph draws 5 points in from its edges).
    private var graphPanel: some View {
        VStack(alignment: .leading, spacing: Self.wedgeGap) {
            HStack(alignment: .top, spacing: Self.wedgeGap) {
                StepWedge(direction: .bottomToTop)
                    .frame(width: StepWedge.thickness)
                    .padding(.vertical, 5)
                CurveGraph(curve: Binding(get: { curve }, set: { setCurve($0) }), selectedPoint: $selectedPoint,
                    channel: $channel, version: curves.version, pointMode: pointMode,
                    histogram: model.curveHistogramFrame == frame.url ? model.curveHistogram?.values(for: channel) ?? [] : [],
                    litRegion: pointMode ? nil : litRegion,
                    takeFocusRequest: model.pendingCurveGraphFocus(for: frame),
                    onEditingChanged: { editing in
                        if editing { commitNumber(); numberFocus = nil; model.beginManualGesture(for: frame) }
                        else { model.endManualGesture(for: frame) }
                    },
                    shapeMenu: { InspectorMenus.curveShape(presets: presetEntries(), frame: frame, model: model) })
                    .aspectRatio(1, contentMode: .fit)
            }
            .fixedSize(horizontal: false, vertical: true)
            StepWedge(direction: .leftToRight)
                .frame(height: StepWedge.thickness)
                .padding(.leading, StepWedge.thickness + Self.wedgeGap + 5)
                .padding(.trailing, 5)
        }
        // The graph sets its own tooltip; a .help here would also replace its accessibility
        // help, which carries the keyboard keys.
    }

    private static let wedgeGap: CGFloat = 4

    private var deleteButton: some View {
        Button {
            numberFocus = nil
            var points = curve.points; points.remove(at: selectedPoint)
            if let result = try? curve.setting(points: points) { setCurve(result); selectedPoint = -1 }
        } label: {
            Image(systemName: "trash").font(.system(size: 12, weight: .light))
                .frame(width: 24, height: Graphite.Metric.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(InspectorQuietStyle(radius: Graphite.Metric.segmentRadius))
        .disabled(!isInteriorSelected)
        .accessibilityLabel("Delete selected curve point")
        .help("Delete the selected interior point (or press Delete, or double-click it). The black and white endpoints stay.")
    }

    @ViewBuilder private var editorControls: some View {
        if pointMode { pointControls } else {
            VStack(spacing: AdjustRowMetric.rowSpacing) {
                ForEach(CurveRegion.allCases, id: \.self) { region in
                    CurveRegionRow(region: region, channel: channel, frame: frame).id(channel)
                        .onHover { isOver in
                            if isOver { litRegion = region } else if litRegion == region { litRegion = nil }
                        }
                }
            }
        }
    }

    private var pointControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Graphite.Metric.m) {
                pointField("In", name: "Input", axis: .input, number: $inputNumber)
                    .disabled(!isInteriorSelected)
                pointField("Out", name: "Output", axis: .output, number: $outputNumber)
                    .disabled(selected == nil)
                Spacer(minLength: 0)
                deleteButton
            }
            if let validationMessage {
                Text(verbatim: validationMessage)
                    .font(Graphite.Typeface.caption)
                    .foregroundStyle(Graphite.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A point's number with its axis before it, "In" or "Out": short, since the graph's wedges say which axis is which and
    /// the tag on the point says the pair. VoiceOver is told the whole word (`name`).
    private func pointField(_ title: String, name: String, axis: Axis, number: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize()
                .accessibilityHidden(true)
            PointNumberField(name: name.lowercased(), isFocused: numberFocus == axis,
                             step: { step(axis, by: $0) }) {
                TextField("—", text: number)
                    .focused($numberFocus, equals: axis)
                    .accessibilityLabel("Selected curve point \(name.lowercased())")
                    .accessibilityHint(validationMessage ?? "Enter an integer from 0 to 255.")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: step(axis, by: 1)
                        case .decrement: step(axis, by: -1)
                        @unknown default: break
                        }
                    }
            }
            .onSubmit { commitNumber(); numberFocus = nil }
            .help((axis == .input ? "The original tone, from 0 (black) to 255 (white). Points remain ordered."
                  : "The new tone, from 0 (black) to 255 (white).")
                  + " The arrows step it by one. With the graph focused, + and − select the next or previous point and Return adds one.")
        }
    }

    private var presetTitle: String {
        ToneCurves.Preset.allCases.first { $0.curve == curve }?.title ?? "Custom"
    }

    /// The four starting shapes, one table for the Curve shape menu and the graph's context menu, made as either opens.
    private func presetEntries() -> [MenuEntry] {
        InspectorMenus.curvePresets(isEnabled: model.canAdjust(frame), choose: choose)
    }

    /// A preset in place of this channel's points and regions, one undo step; its middle point selected, none for Linear.
    private func choose(_ preset: ToneCurves.Preset) {
        commitNumber(); numberFocus = nil
        setCurve(preset.curve)
        selectedPoint = preset == .linear ? -1 : preset.curve.points.count / 2
        syncNumbers()
    }
    private func setCurve(_ value: ChannelCurve) {
        guard let changed = try? curves.setting(channel, to: value) else { return }
        model.setToneCurves(changed, for: frame)
    }
    private func syncNumbers(force: Bool = false) {
        guard numberFocus == nil || force else { return }
        inputNumber = selected.map { String($0.input) } ?? ""
        outputNumber = selected.map { String($0.output) } ?? ""
        validationMessage = nil
    }

    /// A stepper's click: the selected point one unit along `axis`, as one edit and one undo step,
    /// kept inside 0...255 and, for Input, between its neighbours.
    private func step(_ axis: Axis, by delta: Int) {
        if numberFocus != nil { commitNumber(); numberFocus = nil }
        guard let point = selected else { return }
        let points = curve.points
        let value: Int
        if axis == .input {
            guard isInteriorSelected else { return }
            value = min(points[selectedPoint + 1].input - 1, max(points[selectedPoint - 1].input + 1, point.input + delta))
        } else {
            value = min(255, max(0, point.output + delta))
        }
        guard value != (axis == .input ? point.input : point.output),
              let new = try? CurvePoint(input: axis == .input ? value : point.input, output: axis == .output ? value : point.output)
        else { NSSound.beep(); return }
        var updated = points; updated[selectedPoint] = new
        if let result = try? curve.setting(points: updated) { setCurve(result) }
    }

    private func commitNumber(axis: Axis? = nil) {
        guard let axis = axis ?? numberFocus, let point = selected, numberCurve == curve else { return }
        let text = (axis == .input ? inputNumber : outputNumber).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text), (0...255).contains(value) else { validationMessage = "Enter an integer from 0 to 255."; return }
        if axis == .input {
            guard selectedPoint > 0, selectedPoint < curve.points.count - 1,
                  value > curve.points[selectedPoint - 1].input, value < curve.points[selectedPoint + 1].input else {
                validationMessage = "Input must stay between the neighboring points."; return
            }
        }
        guard let new = try? CurvePoint(input: axis == .input ? value : point.input, output: axis == .output ? value : point.output) else { return }
        var points = curve.points; points[selectedPoint] = new
        if let result = try? curve.setting(points: points) { setCurve(result) }
    }
}

/// A point's number in a field with a stepper inside its trailing edge. The field
/// itself takes VoiceOver's increment and decrement, as the stepper does.
private struct PointNumberField<Field: View>: View {
    /// The axis, for the stepper's VoiceOver labels.
    let name: String
    var isFocused: Bool
    let step: (Int) -> Void
    @ViewBuilder let field: Field
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        HStack(spacing: 0) {
            field
                .textFieldStyle(.plain)
                .font(Graphite.Typeface.number)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                stepButton("chevron.up", delta: 1, label: "Increase")
                stepButton("chevron.down", delta: -1, label: "Decrease")
            }
            .frame(width: 18)
            .padding(.trailing, 3)
        }
        // Room for "255" and the steppers, narrow enough that Input and Output share the
        // inspector's line with their names.
        .frame(width: 62, height: Graphite.Metric.controlHeight)
        .background(shape.fill(isFocused ? Graphite.control : Graphite.ink(0.05)))
        .overlay {
            shape.strokeBorder(isFocused ? Graphite.selection.opacity(0.7)
                               : contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
        }
        .opacity(isEnabled ? 1 : 0.42)
    }

    private func stepButton(_ symbol: String, delta: Int, label: String) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .semibold))
                .frame(width: 18, height: 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Graphite.secondaryText)
        .accessibilityLabel("\(label) \(name)")
    }
}

private struct CurveRegionRow: View {
    let region: CurveRegion
    let channel: ToneCurves.Channel
    let frame: Frame
    @Environment(RollModel.self) private var model
    @State private var number = "0"
    @State private var message: String?
    @State private var numberCurve: ChannelCurve?
    @State private var isHovered = false
    @FocusState private var focused: Bool
    private var curve: ChannelCurve { model.manualAdjustments(for: frame).curves.curve(for: channel) }
    private var value: Float { model.manualAdjustments(for: frame).curves.curve(for: channel).regions.value(for: region) }
    var body: some View {
        // A Light row's shape (`ManualAdjustmentRow`): the name and the value on a line, the track under them.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(region.title)
                    .font(Graphite.Typeface.label)
                    .foregroundStyle(Graphite.text)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: AdjustRowMetric.spacing)
                TextField(region.title, text: $number)
                    .modifier(AdjustValueFieldStyle(isFocused: focused, isHovered: isHovered, isZero: value == 0))
                    .focused($focused).onSubmit { commit(); focused = false }
                    .accessibilityLabel("\(channel.title) curve \(region.title.lowercased()) value")
                    .accessibilityHint(message ?? "Enter −100 to +100.")
                    .help("Enter −100 to +100.")
                    .padding(.trailing, -4)
            }
            .frame(height: AdjustRowMetric.line)
            AdjustmentSlider(value: Binding(get: { value }, set: { set($0) }), spec: .light(.shadows, group: nil),
                label: "\(channel.title) curve \(region.title.lowercased())",
                onEditingChanged: { editing in
                    if editing { if focused { commit(); focused = false }; model.beginManualGesture(for: frame) }
                    else { model.endManualGesture(for: frame) }
                }, onReset: { focused = false; set(0) }, onFocusChanged: { _ in }, showsRuler: isHovered)
                .frame(height: AdjustRowMetric.track)
                .help("Shape \(region.title.lowercased()) in the \(channel.title.lowercased()) curve. Double-click to reset. Shift-arrow uses ten steps.")
            if let message {
                Text(message).font(Graphite.Typeface.caption).foregroundStyle(Graphite.secondaryText)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onAppear { number = formatted(value) }
        .onChange(of: value) { _, new in if !focused { number = formatted(new); message = nil } }
        .onChange(of: curve) { _, new in
            if focused, new != numberCurve { focused = false; number = formatted(value) }
        }
        .onChange(of: focused) { _, new in
            if new { number = formatted(value); numberCurve = curve; message = nil } else { commit() }
        }
        .onDisappear { if focused { commit() }; model.endManualGesture(for: frame) }
    }
    private func formatted(_ value: Float) -> String { value.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))) }
    private func set(_ value: Float) {
        let curves = model.manualAdjustments(for: frame).curves
        guard let curve = try? curves.curve(for: channel).setting(region, to: value), let result = try? curves.setting(channel, to: curve) else { return }
        model.setToneCurves(result, for: frame)
    }
    private func commit() {
        guard numberCurve == curve else { return }
        guard let parsed = Float(number.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.isFinite, (-100...100).contains(parsed) else {
            message = "Enter −100 to +100."; return
        }
        set(parsed.rounded())
    }
}

/// One of the four curves over the graph: a dot in the colour its line is drawn in, Tone's half dark and half light, on a
/// small face that is lifted for the one chosen. A curve that is shaped has a dot at the face's corner. The keys 1 to 4
/// choose them too, with the graph focused.
private struct CurveChannelDot: View {
    let channel: ToneCurves.Channel
    let isChosen: Bool
    let isShaped: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 24, height: 24)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.segmentRadius, style: .continuous)
        Button(action: action) {
            dot
                .frame(width: 10, height: 10)
                .frame(width: Self.size.width, height: Self.size.height)
                .background(shape.fill(Graphite.ink(isChosen ? 0.13 : isHovered ? 0.06 : 0)))
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Graphite.selection)
                        .frame(width: 4, height: 4)
                        .padding(3)
                        .opacity(isShaped ? 1 : 0)
                }
                .opacity(isEnabled ? 1 : 0.42)
                .contentShape(shape)
        }
        .buttonStyle(MaskPressStyle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isChosen)
        .help(channel == .tone ? "Tone: shape overall light while preserving color away from black."
              : "\(channel.title): shape the \(channel.title.lowercased()) channel to tune color.")
        .accessibilityLabel("\(channel.title) curve channel")
        .accessibilityValue(isShaped ? "Shaped" : "")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    @ViewBuilder private var dot: some View {
        if channel == .tone {
            Circle()
                .fill(Graphite.text.opacity(0.3))
                .overlay { Circle().trim(from: 0.25, to: 0.75).fill(Graphite.text).rotationEffect(.degrees(180)) }
        } else {
            Circle().fill(Color(nsColor: CurveGraphView.color(of: channel)))
        }
    }
}

/// The four starting shapes, each drawn as the curve it puts in place of this channel's, with its name's first word under it
/// and the whole name in its help tag: Linear, Soft contrast, Lifted blacks, Strong contrast. The one the channel's curve is
/// now wears the selection's ring; none does once the curve is its own. The graph's menu has the same four
/// (`InspectorMenus.curvePresets`).
private struct CurveShapeTiles: View, Equatable {
    let chosen: ToneCurves.Preset?
    let channel: ToneCurves.Channel
    let choose: (ToneCurves.Preset) -> Void
    @Environment(\.isEnabled) private var isEnabled

    /// What it shows is these two: the tab's body runs at each step of a point's drag, and the four curves are not built again for it.
    nonisolated static func == (a: Self, b: Self) -> Bool { a.chosen == b.chosen && a.channel == b.channel }

    /// Each shape as its curve's heights across the tones, made once.
    private static let samples: [ToneCurves.Preset: [Float]] = Dictionary(uniqueKeysWithValues: ToneCurves.Preset.allCases.map { preset in
        let all = preset.curve.compiled().samples
        return (preset, stride(from: 0, to: all.count, by: max(1, all.count / 48)).map { all[$0] } + [all.last ?? 1])
    })

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(ToneCurves.Preset.allCases, id: \.self) { preset in
                let isChosen = preset == chosen
                VStack(spacing: 4) {
                    Button { choose(preset) } label: {
                        CurveShapeGlyph(samples: Self.samples[preset] ?? [])
                            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .padding(7)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(MaskTileStyle(isChosen: isChosen))
                    .help("\(preset.title): replace this channel's point and region curve with this shape. Other channels and Light adjustments stay as they are.")
                    .accessibilityLabel("\(preset.title), \(channel.title.lowercased()) curve shape")
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                    Text(verbatim: preset.title.split(separator: " ").first.map(String.init) ?? preset.title)
                        .font(Graphite.Typeface.caption)
                        .foregroundStyle(!isEnabled ? Graphite.tertiaryText : isChosen ? Graphite.text : Graphite.secondaryText)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// A curve as a line across a tile, black at the lower left as on the graph.
private struct CurveShapeGlyph: Shape {
    let samples: [Float]

    func path(in rect: CGRect) -> Path {
        Path { path in
            guard samples.count > 1 else { return }
            for (index, sample) in samples.enumerated() {
                let point = CGPoint(x: rect.minX + CGFloat(index) / CGFloat(samples.count - 1) * rect.width,
                                    y: rect.maxY - CGFloat(min(1, max(0, sample))) * rect.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
