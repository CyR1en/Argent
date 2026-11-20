import ArgentCore
import ArgentRoll
import SwiftUI

extension EnvironmentValues {
    @Entry var isCompactAdjustInspector = false
    @Entry var editedInspectorFocus: EditedInspectorFocus?
}

struct EditedInspectorFocus {
    let model: RollModel
    let frame: URL
    let requestFilterFocus: () -> Void

    @MainActor var isCurrent: Bool {
        model.adjustInspectorFrame?.url == frame && model.inspectorNavigation.filter == .edited
    }
}

struct AdjustFilterPicker: View {
    let frame: Frame
    @Binding var keyboardFocusRequested: Bool
    @FocusState private var focused: Bool
    @Environment(RollModel.self) private var model

    var body: some View {
        let count = model.inspectorEdits(for: frame).count
        GraphiteSegmented(selection: Binding(get: { model.inspectorNavigation.filter },
                                             set: { model.setInspectorFilter($0, for: frame) }),
                          segments: [
                            .init(value: .allTools, title: "All tools"),
                            .init(value: .edited, title: "Edited",
                                  accessibilityLabel: "Edited, \(InspectorEdits.editCount(count))", badge: count.formatted()),
                          ], fillsWidth: true)
        // A mouse click leaves focus on the photograph. The last Edited slider can explicitly give the filter the arrow keys.
        .focusable(interactions: keyboardFocusRequested ? .automatic : .activate)
        .focused($focused)
        .onChange(of: keyboardFocusRequested) { _, requested in
            if requested { focused = true }
        }
        .onChange(of: focused) { _, focused in
            if !focused { keyboardFocusRequested = false }
        }
        .onKeyPress(.leftArrow) {
            model.setInspectorFilter(.allTools, for: frame)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.setInspectorFilter(.edited, for: frame)
            return .handled
        }
        .accessibilityLabel("Adjustment filter")
    }
}

struct AdjustSectionHeader: View {
    let frame: Frame
    let section: AdjustInspectorTab
    let hasLensProfile: Bool?
    let action: () -> Void
    @Environment(RollModel.self) private var model

    @Environment(\.isCompactAdjustInspector) private var isCompact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isOpen = model.openAdjustSection == section
        let isEditedList = model.inspectorNavigation.filter == .edited
        let edits = model.inspectorEdits(for: frame)
        let summary = edits.summary(for: section, hasLensProfile: hasLensProfile)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: isOpen ? .medium : .regular))
                    .frame(width: 23, height: 23)
                    .foregroundStyle(isOpen ? Graphite.selection : Graphite.secondaryText)
                    .background {
                        if isOpen {
                            RoundedRectangle(cornerRadius: 5).fill(Graphite.selection.opacity(0.12))
                        }
                    }
                    .accessibilityHidden(true)
                Text(verbatim: section.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Graphite.text)
                Spacer(minLength: 4)
                Text(verbatim: summary)
                    .font(Graphite.Typeface.caption.monospacedDigit())
                    .foregroundStyle(edits.count(in: section) > 0 ? Graphite.selection : Graphite.secondaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isOpen)
                    .frame(width: 10)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Graphite.Metric.adjustPadding)
            .frame(height: isCompact ? 34 : 40)
            .contentShape(Rectangle())
            .background(isOpen ? Graphite.ink(0.025) : .clear)
        }
        .buttonStyle(InspectorQuietStyle(radius: 0))
        .contextMenu(entries: { InspectorMenus.ground(of: section, frame: frame, model: model) })
        .accessibilityLabel(section.accessibilityLabel)
        .accessibilityValue(isEditedList ? summary : "\(isOpen ? "Expanded" : "Collapsed"). \(summary)")
        .accessibilityHint(isEditedList ? "Opens the full editor." : isOpen ? "Collapses this section." : "Expands this section.")
        .help(section.help)
    }
}

struct EditedAdjustmentsView: View {
    let frame: Frame
    let lensFile: LensFile?
    let hasLensProfile: Bool?
    let drillIn: (InspectorDestination) -> Void
    @Environment(RollModel.self) private var model

    var body: some View {
        // Keep editable rows in place through their gesture, even if the slider passes through its default.
        // The filter count and the section summaries follow the print while the gesture is under way.
        let edits = InspectorEdits(model.manualAdjustments(for: frame))
        if edits.count == 0 {
            Text("No edits on this frame.")
                .font(Graphite.Typeface.label)
                .foregroundStyle(Graphite.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Graphite.Metric.adjustPadding)
        } else {
            VStack(spacing: 0) {
                ForEach(AdjustInspectorTab.allCases, id: \.self) { section in
                    if edits.count(in: section) > 0 {
                        SectionDivider()
                        AdjustSectionHeader(frame: frame, section: section, hasLensProfile: hasLensProfile) {
                            model.showInspector(tab: section)
                        }
                        VStack(spacing: 8) {
                            rows(in: section, edits: edits)
                        }
                        .padding(.horizontal, Graphite.Metric.adjustPadding)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    @ViewBuilder private func rows(in section: AdjustInspectorTab, edits: InspectorEdits) -> some View {
        switch section {
        case .light:
            ForEach(edits.light, id: \.self) { slider in
                LightAdjustmentRow(frame: frame, slider: slider)
                    .disabled(!model.canAdjust(frame))
            }
        case .curve:
            ForEach(edits.curves, id: \.self) { channel in
                objectRow("\(channel.title) curve", detail: curveDetail(channel)) { drillIn(.curve(channel)) }
            }
        case .masks:
            ForEach(edits.masks) { mask in
                objectRow(model.maskName(mask.id, for: frame),
                          detail: mask.isEnabled ? MaskSummary.line(for: mask) : "Off") { drillIn(.mask(mask.id)) }
            }
        case .lens:
            EditedLensControls(frame: frame, file: lensFile, controls: edits.lens, distortionChanged: edits.distortionChanged)
                .disabled(!model.canAdjust(frame))
        case .remove:
            ForEach(model.removalRows(for: frame).filter { !$0.isPending }) { row in
                objectRow(row.title, detail: row.isOn ? row.caption?.text : "Off") { drillIn(.removal(row.id)) }
            }
        }
    }

    private func curveDetail(_ channel: ToneCurves.Channel) -> String? {
        let curve = model.manualAdjustments(for: frame).curves.curve(for: channel)
        if let preset = ToneCurves.Preset.allCases.first(where: { $0.curve == curve }) { return preset.title }
        if !curve.regions.isIdentity { return "Regions adjusted" }
        return nil
    }

    private func objectRow(_ title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(verbatim: title)
                    .font(Graphite.Typeface.label)
                    .foregroundStyle(Graphite.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let detail {
                    Text(verbatim: detail)
                        .font(Graphite.Typeface.caption)
                        .foregroundStyle(Graphite.secondaryText)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(Graphite.ink(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(InspectorQuietStyle())
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
        .accessibilityHint("Opens this edit in its tool.")
        .help([title, detail].compactMap { $0 }.joined(separator: " · "))
    }
}
