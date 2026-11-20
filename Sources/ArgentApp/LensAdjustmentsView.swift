import ArgentCore
import ArgentRoll
import SwiftUI

/// The Adjust inspector's Lens tab: the lens the file names and where Distortion comes from, on one plate; then Distortion,
/// its switch on its heading and its Amount under it; Defringe, each colour's Amount over the range of hues it takes, one
/// track with two handles; and Vignetting. The tab's Reset is the foot's (`InspectorMenus.resetMenu`).
struct LensAdjustmentsView: View {
    let frame: Frame
    @Environment(RollModel.self) private var model
    var file: LensFile? = nil

    static func lensLine(_ file: LensFile) -> String { file.metadata?.summary ?? "No lens named in the file" }

    static func distortionLine(_ file: LensFile, settings: LensSettings) -> String {
        let availability = LensResolver.availability(file)
        if case .file = availability.distortion,
           case .none(let reason) = LensResolver.resolve(file, settings: settings).status.distortion {
            return "Distortion, " + reason
        }
        return availability.distortionLine
    }

    var body: some View {
        // Until the file's record is read the plate's two lines stay blank: they state nothing they do not know.
        let settings = model.lensSettings(for: frame)
        let availability = file.map(LensResolver.availability)
        let hasCurve = if case .file = availability?.distortion { true } else { false }
        VStack(alignment: .leading, spacing: 0) {
            LensPlate(lens: file.map(Self.lensLine) ?? " ", distortion: file.map { Self.distortionLine($0, settings: settings) } ?? " ")
            InspectorSectionHeader(title: "Distortion") {
                InspectorSwitch(title: "Distortion", isOn: settings.distortion.isOn, help: "Correct distortion using the curve from this file.") {
                    model.setDistortion(!model.lensSettings(for: frame).distortion.isOn, for: frame)
                }
                .disabled(!hasCurve)
            }
            .padding(.top, AdjustRowMetric.sectionSpacing)
            .padding(.bottom, AdjustRowMetric.rowSpacing)
            LensAmountRow(frame: frame, control: .distortion, offersDistortionSwitch: true)
                .disabled(!settings.distortion.isOn || !hasCurve)
            InspectorGroup(title: "Defringe", summary: settings.defringe == .default ? "No changes" : "Edited",
                           isOpen: model.isInspectorDefringeExpanded, toggle: {
                model.endLightAdjusting(for: frame)
                model.isInspectorDefringeExpanded.toggle()
            }) {
                VStack(alignment: .leading, spacing: 0) {
                    LensAmountRow(frame: frame, control: .purpleAmount, offersDistortionSwitch: false)
                    LensHueRow(frame: frame, title: "Purple Hue", low: .purpleHueLow, high: .purpleHueHigh)
                        .padding(.top, AdjustRowMetric.rowSpacing)
                    LensAmountRow(frame: frame, control: .greenAmount, offersDistortionSwitch: false)
                        .padding(.top, AdjustRowMetric.pairSpacing)
                    LensHueRow(frame: frame, title: "Green Hue", low: .greenHueLow, high: .greenHueHigh)
                        .padding(.top, AdjustRowMetric.rowSpacing)
                }
            }
            .padding(.top, AdjustRowMetric.sectionSpacing)
            InspectorSectionHeader(title: "Vignetting")
                .padding(.top, AdjustRowMetric.sectionSpacing)
                .padding(.bottom, AdjustRowMetric.rowSpacing)
            LensAmountRow(frame: frame, control: .vignette, offersDistortionSwitch: false)
            // Midpoint places a vignette, and waits for one.
            LensAmountRow(frame: frame, control: .vignetteMidpoint, offersDistortionSwitch: false)
                .disabled(settings.vignetting.amount == 0)
                .padding(.top, AdjustRowMetric.rowSpacing)
        }
        .disabled(!model.canAdjust(frame))

    }
}

/// What the file says of its lens, once: the lens it names, and under it where Distortion's curve comes from or why there is
/// none. On a ground of its own, since it is what the tab's controls act on and not one of them.
private struct LensPlate: View {
    let lens: String
    let distortion: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 20, weight: .ultraLight))
                .foregroundStyle(Graphite.secondaryText)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: lens)
                    .font(Graphite.Typeface.label)
                    .foregroundStyle(Graphite.text)
                Text(verbatim: distortion)
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Graphite.Metric.railItemRadius, style: .continuous).fill(Graphite.ink(0.05)))
        .accessibilityElement(children: .combine)
    }
}

private struct LensAmountRow: View {
    let frame: Frame
    let control: LensSettings.Control
    let offersDistortionSwitch: Bool
    var title: String? = nil
    var limits: ClosedRange<Float>? = nil
    @Environment(RollModel.self) private var model

    var body: some View {
        let gesture = model.lightGestureGeneration
        let slider = ManualAdjustments.Slider.lens(control)
        ManualAdjustmentRow(spec: spec, help: slider.adjustmentHelp,
                            value: Binding(get: { model.manualAdjustments(for: frame).value(for: slider) },
                                           set: { if model.lightGestureGeneration == gesture { model.moveLight(slider, to: $0, for: frame) } }),
                            snapshot: model.manualAdjustments(for: frame), gesture: gesture,
                            beginGesture: { model.beginLightAdjusting(for: frame) },
                            endGesture: { model.endLightAdjusting(for: frame) },
                            groupReset: { InspectorMenus.resetLens(frame, model: model) },
                            menuSwitch: offersDistortionSwitch ? { @MainActor in InspectorMenus.lensDistortion(frame, model: model) } : nil,
                            limits: limits)
    }

    private var spec: AdjustmentSliderSpec {
        var spec = AdjustmentSliderSpec.lensAmount(control)
        if let title { spec.title = title }
        return spec
    }
}

struct EditedLensControls: View {
    let frame: Frame
    let file: LensFile?
    let controls: [LensSettings.Control]
    let distortionChanged: Bool
    @Environment(RollModel.self) private var model

    var body: some View {
        let settings = model.lensSettings(for: frame)
        let hasCurve = if case .file = file.map(LensResolver.availability)?.distortion { true } else { false }
        VStack(spacing: 8) {
            if distortionChanged {
                InspectorSectionHeader(title: "Distortion") {
                    InspectorSwitch(title: "Distortion", isOn: settings.distortion.isOn,
                                    help: "Correct distortion using the curve from this file.") {
                        model.setDistortion(!model.lensSettings(for: frame).distortion.isOn, for: frame)
                    }
                    .disabled(!hasCurve)
                }
            }
            ForEach(controls, id: \.self) { control in
                LensAmountRow(frame: frame, control: control, offersDistortionSwitch: control == .distortion,
                              title: title(for: control), limits: limits(for: control, settings: settings))
                    .disabled(control == .distortion && (!settings.distortion.isOn || !hasCurve)
                              || control == .vignetteMidpoint && settings.vignetting.amount == 0)
            }
        }
    }

    private func title(for control: LensSettings.Control) -> String {
        switch control {
        case .distortion: "Distortion Amount"
        case .vignette: "Vignetting Amount"
        case .vignetteMidpoint: "Vignetting Midpoint"
        default: control.title
        }
    }

    private func limits(for control: LensSettings.Control, settings: LensSettings) -> ClosedRange<Float>? {
        switch control {
        case .purpleHueLow: 0...(settings.defringe.purpleHue.upperBound - RollModel.lensHueGap)
        case .purpleHueHigh: (settings.defringe.purpleHue.lowerBound + RollModel.lensHueGap)...100
        case .greenHueLow: 0...(settings.defringe.greenHue.upperBound - RollModel.lensHueGap)
        case .greenHueHigh: (settings.defringe.greenHue.lowerBound + RollModel.lensHueGap)...100
        default: nil
        }
    }
}

/// The hues a Defringe colour takes, as one range: a strip of the hues with two handles on it, where the tab had two sliders,
/// Low and High, a row each. The handles are those two sliders still, each a row of its own with its value, its keys, its
/// reset and its menu (`ManualAdjustmentRow`), laid one over the other on the strip (`ManualAdjustmentRowLayout`), so a
/// keyboard, VoiceOver and a typed value reach each end as they did. A press on the strip takes the nearer handle
/// (`AdjustmentSliderControl.mouseDown`), and each stops ten short of the other, as the values are kept.
private struct LensHueRow: View {
    let frame: Frame
    let title: String
    let low: LensSettings.Control
    let high: LensSettings.Control
    @Environment(RollModel.self) private var model
    @State private var isHovered = false
    @FocusState private var resetFocused: Bool

    /// What both ends' help tags and VoiceOver's hints begin with: the track is one, and the end on top answers for it
    /// wherever the pointer rests, so neither says it is the low end or the high.
    private var help: String {
        "Set the range of \(low == .purpleHueLow ? "purple" : "green") fringe hues Defringe takes. Each end stops 10 short of the other."
    }

    var body: some View {
        // What the print has, so the strip's bracket follows a handle as it is dragged.
        let range = Self.range(low, in: model.lensSettings(for: frame))
        let isChanged = range.lowerBound != low.defaultValue || range.upperBound != high.defaultValue
        ZStack(alignment: .topLeading) {
            HStack(spacing: AdjustRowMetric.nameGap) {
                Text(verbatim: title)
                    .font(Graphite.Typeface.label)
                    .foregroundStyle(Graphite.text)
                    .lineLimit(1)
                    .fixedSize()
                    .onTapGesture(count: 2, perform: reset)
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .medium))
                        .frame(width: AdjustRowMetric.resetArrow, height: AdjustRowMetric.line)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Graphite.secondaryText)
                .focused($resetFocused)
                .disabled(!isChanged)
                .opacity(isChanged && (isHovered || resetFocused) ? 1 : 0)
                .accessibilityHidden(!isChanged)
                .help("Reset both ends of \(title.lowercased()). You can also double-click its name.")
                .accessibilityLabel("Reset \(title.lowercased())")
            }
            .frame(height: AdjustRowMetric.line)
            HueStrip(colors: low == .purpleHueLow ? HueStrip.purple : HueStrip.green,
                     low: CGFloat(range.lowerBound) / 100, high: CGFloat(range.upperBound) / 100)
                .frame(height: AdjustRowMetric.track)
                .padding(.top, AdjustRowMetric.line)
            end(low, layout: .rangeLow, limits: 0...(range.upperBound - RollModel.lensHueGap))
            end(high, layout: .rangeHigh, limits: (range.lowerBound + RollModel.lensHueGap)...100)
        }
        .onHover { isHovered = $0 }
    }

    private static func range(_ low: LensSettings.Control, in settings: LensSettings) -> ClosedRange<Float> {
        low == .purpleHueLow ? settings.defringe.purpleHue : settings.defringe.greenHue
    }

    private func end(_ control: LensSettings.Control, layout: ManualAdjustmentRowLayout, limits: ClosedRange<Float>) -> some View {
        let gesture = model.lightGestureGeneration
        let slider = ManualAdjustments.Slider.lens(control)
        return ManualAdjustmentRow(spec: .lensHue(control, partner: control == low ? high : low), help: help,
                                   value: Binding(get: { model.manualAdjustments(for: frame).value(for: slider) },
                                                  set: { if model.lightGestureGeneration == gesture { model.moveLight(slider, to: $0, for: frame) } }),
                                   snapshot: model.manualAdjustments(for: frame), gesture: gesture,
                                   beginGesture: { model.beginLightAdjusting(for: frame) },
                                   endGesture: { model.endLightAdjusting(for: frame) },
                                   groupReset: { InspectorMenus.resetLens(frame, model: model) },
                                   layout: layout, limits: limits)
    }

    private func reset() { model.resetLensHue(low: low, high: high, for: frame) }
}

extension RollModel {
    /// The least a Defringe hue range's two ends stand apart (`LensSettings.setting(_:to:)`).
    static let lensHueGap: Float = 10

    /// Both ends of a Defringe hue range back at their defaults, one gesture and one undo step, unless they are there: the
    /// range's name double-clicked, or the arrow beside it. Each end is kept ten from the other as it is set, so the one
    /// that has room goes first: Low, unless High stands so low that Low's default would be stopped short of it.
    func resetLensHue(low: LensSettings.Control, high: LensSettings.Control, for frame: Frame) {
        let lens = manualAdjustments(for: frame).lens
        guard lens.value(for: low) != low.defaultValue || lens.value(for: high) != high.defaultValue else { return }
        beginLightAdjusting(for: frame)
        let first = low.defaultValue <= lens.value(for: high) - Self.lensHueGap ? low : high
        for control in [first, first == low ? high : low] {
            moveLight(.lens(control), to: control.defaultValue, for: frame)
        }
        endLightAdjusting(for: frame)
    }
}

/// A Defringe range's track: the hues it can take, the part between the two handles at full strength in a fine frame and the
/// rest stepped back, so the range reads as a window on the strip. Its ends are where the handles' centres travel
/// (`AdjustmentSliderCell.barRect`).
private struct HueStrip: View {
    let colors: [Color]
    let low: CGFloat
    let high: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    static let purple: [Color] = [Color(.sRGB, red: 0.24, green: 0.39, blue: 0.88), Color(.sRGB, red: 0.42, green: 0.32, blue: 0.88),
                                  Color(.sRGB, red: 0.60, green: 0.31, blue: 0.85), Color(.sRGB, red: 0.78, green: 0.27, blue: 0.75),
                                  Color(.sRGB, red: 0.88, green: 0.27, blue: 0.50)]
    static let green: [Color] = [Color(.sRGB, red: 0.78, green: 0.75, blue: 0.22), Color(.sRGB, red: 0.55, green: 0.76, blue: 0.25),
                                 Color(.sRGB, red: 0.27, green: 0.70, blue: 0.34), Color(.sRGB, red: 0.18, green: 0.68, blue: 0.55),
                                 Color(.sRGB, red: 0.18, green: 0.62, blue: 0.75)]

    private static let height: CGFloat = 8
    /// Half a knob: how far in from either end a handle's centre stands at the range's end.
    private static let inset: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let strip = CGRect(x: 0, y: (size.height - Self.height) / 2, width: size.width, height: Self.height)
            let travel = size.width - 2 * Self.inset
            let start = Self.inset + low * travel, end = Self.inset + high * travel
            let shape = Path(roundedRect: strip, cornerRadius: Self.height / 2)
            let gradient = GraphicsContext.Shading.linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: strip.minX, y: 0),
                                                                  endPoint: CGPoint(x: strip.maxX, y: 0))
            var dimmed = context
            dimmed.opacity = isEnabled ? 0.3 : 0.14
            dimmed.fill(shape, with: gradient)
            var window = context
            window.opacity = isEnabled ? 1 : 0.4
            window.clip(to: Path(CGRect(x: start, y: 0, width: max(0, end - start), height: size.height)))
            window.fill(shape, with: gradient)
            let frame = CGRect(x: start, y: strip.minY - 1.5, width: max(0, end - start), height: Self.height + 3)
            context.stroke(Path(roundedRect: frame, cornerRadius: 3), with: .color(Graphite.text.opacity(isEnabled ? 0.85 : 0.35)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
