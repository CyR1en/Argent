import ArgentCore
import ArgentRoll
import SwiftUI

/// The brush's options while it is in hand: Size, Feather and Flow as the Light tab's own rows (`ManualAdjustmentRow`), with their
/// keys, scrubbing, typed values and double-click reset, in a group of their own so . and , stay among them; Erase; and Follow edges
/// (A). None is a mask's or an undo step: they are how the next stroke paints, kept across launches but Erase (R7 6.1, 6.3).
struct MaskBrushOptions: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        let brush = model.maskEditor.brush
        VStack(alignment: .leading, spacing: Graphite.Metric.s) {
            InspectorSectionHeader(title: "Brush")
            VStack(spacing: AdjustRowMetric.rowSpacing) {
                row(.brushSize, help: "The brush's width, as a share of the picture's longer side. ] and [ change it.", \.size)
                row(.brushFeather, help: "How far in from its edge the brush's softness reaches. Shift-] and Shift-[ change it.", \.feather)
                row(.brushFlow, help: "How much one stroke lays down; strokes over it build up. The number keys set it, 1 to 0.", \.flow)
            }
            HStack(spacing: Graphite.Metric.s) {
                MaskCheck(title: "Erase", isOn: brush.settings.erase,
                          help: "Strokes take this brush's paint away. Holding Option as you press does the same for one stroke.") {
                    brush.settings.erase.toggle()
                }
                Spacer(minLength: 0)
                MaskCheck(title: "Follow edges", isOn: brush.settings.followEdges,
                          help: "Strokes keep to the colour under the brush's centre, and snap to the picture's edges as they end. A turns it on or off.") {
                    model.toggleFollowEdges()
                }
            }
        }
    }

    private func row(_ spec: AdjustmentSliderSpec, help: String, _ setting: WritableKeyPath<MaskBrushSettings, Float>) -> some View {
        let brush = model.maskEditor.brush
        return ManualAdjustmentRow(spec: spec, help: help,
                                   value: Binding(get: { spec.snapped(brush.settings[keyPath: setting]) },
                                                  set: { brush.settings[keyPath: setting] = spec.snapped($0) }),
                                   snapshot: brush.settings, beginGesture: {}, endGesture: {})
    }
}

/// The row a brush waits in until its first stroke makes it: in the list for a new mask (K, the Brush tile), among the selected
/// mask's components for ⇧K and ⌥K. Undoing that first stroke brings it back with the brush still in hand (plan section 5).
struct MaskBrushPendingRow: View {
    enum Kind: Equatable {
        /// A new mask and its name to be.
        case mask(String)
        case component(MaskOperation)
    }

    let kind: Kind

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        let isMask = { if case .mask = kind { true } else { false } }()
        HStack(spacing: Graphite.Metric.s) {
            Image(systemName: MaskTile.brush.symbol)
                .font(.system(size: isMask ? 14 : 12, weight: .light))
                .foregroundStyle(Graphite.secondaryText)
                .frame(width: isMask ? 18 : 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(Graphite.Typeface.label)
                    .foregroundStyle(Graphite.text)
                    .lineLimit(1)
                if isMask {
                    Text(verbatim: MaskCopy.brushPending)
                        .font(Graphite.Typeface.caption)
                        .foregroundStyle(Graphite.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .component(let operation) = kind {
                Text(verbatim: MaskCopy.brushPending)
                    .font(Graphite.Typeface.caption)
                    .foregroundStyle(Graphite.secondaryText)
                Image(systemName: operation.symbol)
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(Graphite.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: isMask ? MaskRow.height : Graphite.Metric.controlHeight)
        .overlay { shape.strokeBorder(Graphite.selection, style: StrokeStyle(lineWidth: Graphite.Metric.selectionWidth, dash: [4, 3])) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(MaskCopy.brushPending)
        // Without a trait its role is unknown, and VoiceOver goes past it.
        .accessibilityAddTraits(.isStaticText)
    }

    private var title: String {
        switch kind {
        case .mask(let name): name
        case .component(let operation): "\(operation.title) Brush"
        }
    }
}

extension RollModel {
    /// The pending row a brush in hand shows on `frame`, if it waits for its first stroke, or while that stroke is under way.
    func brushPendingRow(on frame: Frame) -> MaskBrushPendingRow.Kind? {
        if let making = maskEditor.brush.making, making.frame == frame.url, let index = making.target.component,
           let mask = mask(making.target.mask, for: frame), mask.components.indices.contains(index) {
            return index == 0 ? .mask(maskName(making.target.mask, for: frame)) : .component(mask.components[index].operation)
        }
        guard brushIsPending(on: frame) else { return nil }
        if let operation = maskEditor.pendingOperation { return .component(operation) }
        return .mask(nextBrushName(for: frame))
    }

    /// "Brush 1", the lowest number no mask has: what the pending mask will be called.
    private func nextBrushName(for frame: Frame) -> String {
        let names = Set(masks(for: frame).map { maskName($0.id, for: frame) })
        var number = 1
        while names.contains("Brush \(number)") { number += 1 }
        return "Brush \(number)"
    }
}
