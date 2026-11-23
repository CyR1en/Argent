import ArgentRoll
import SwiftUI

/// The workspace's Settings page. Changes are saved as they happen.
struct SettingsPage: View {
    private static let columnWidth: CGFloat = 720
    private static let pageInset: CGFloat = 44

    @Environment(RollModel.self) private var model
    @State private var pictures: [CGImage?] = []

    var body: some View {
        let settings = AppearanceSettings.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeading(title: "Settings", subtitle: "Changes are saved automatically")
                sectionHeading("Appearance")
                SettingsAppearance(settings: settings, pictures: pictures)
                sectionHeading("Window shell", reset: InspectorReset(
                    title: "Reset window shell", help: "Restore the default window shell settings",
                    isEnabled: !settings.shellIsAtDefaults, action: settings.resetShell))
                WindowShellCard(settings: settings)
                sectionHeading("Frame view", reset: InspectorReset(
                    title: "Reset frame view", help: "Restore the default surround, intensity and edge shadow",
                    isEnabled: !settings.frameSurroundIsAtDefaults, action: settings.resetFrameSurround))
                FrameSurroundCard(settings: settings, picture: pictures.first ?? nil)
                sectionHeading("Rolls")
                RollsBackdropCard(settings: settings)
                sectionHeading("Develop")
                DevelopMemoryCard(settings: model.developMemory)
            }
            .frame(maxWidth: Self.columnWidth)
            .padding(.horizontal, Self.pageInset)
            .padding(.top, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlay(alignment: .topTrailing) {
            CloseButton(help: "Close settings", bordered: true) { model.showWorkspacePage(.roll) }
                .keyboardShortcut(.cancelAction)
                .padding(Graphite.Metric.edge)
        }
        .task(id: model.roll?.folder) { await loadPictures() }
    }

    private func sectionHeading(_ title: String, reset: InspectorReset? = nil) -> some View {
        PageSectionHeading(title: title, reset: reset)
            .frame(height: 20)
            .padding(.top, 30)
            .padding(.bottom, 14)
    }

    private func loadPictures() async {
        pictures = []
        var loaded: [CGImage?] = []
        for (index, frame) in (model.roll?.frames.prefix(9) ?? []).enumerated() {
            let image = await model.thumbnails.thumbnail(for: frame, maxPixelSize: index == 0 ? 256 : 128)
            if Task.isCancelled { return }
            loaded.append(image)
        }
        pictures = loaded
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let note: String
    var labelWidth: CGFloat?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: Graphite.Metric.inspectorPadding) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(Graphite.Typeface.row)
                    .foregroundStyle(Graphite.text)
                    .accessibilityHidden(true)
                Text(verbatim: note)
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: labelWidth, alignment: .leading)
            .frame(maxWidth: labelWidth ?? .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, Graphite.Metric.inspectorPadding)
        .padding(.vertical, 10)
        .frame(minHeight: 62)
    }
}

private struct SettingsPercentField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let percent = value.formatted(.percent.precision(.fractionLength(0)))
        let wholePercent = Binding(get: { value }, set: { value = ($0 * 100).rounded() / 100 })
        SliderField(valueWidth: 54) {
            Text(percent)
                .font(Graphite.Typeface.number)
                .foregroundStyle(Graphite.text)
                .accessibilityHidden(true)
        } slider: {
            Slider(value: wholePercent, in: range)
                .controlSize(.small)
                .tint(Graphite.text)
                .accessibilityLabel(title)
                .accessibilityValue(percent)
        }
        .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct WindowShellCard: View {
    @Bindable var settings: AppearanceSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shell = settings.shellStyle(reduceTransparency: reduceTransparency)
        VStack(spacing: 0) {
            SettingsRow(title: "Transparency",
                        note: reduceTransparency ? "Reduce Transparency is on, so the shell is opaque"
                            : "How much desktop frost shows through",
                        labelWidth: 262) {
                SettingsPercentField(title: "Transparency", value: $settings.shellTransparency,
                                     range: AppearanceSettings.transparencyRange)
                    .disabled(reduceTransparency)
            }
            SectionDivider()
            SettingsRow(title: "Tint saturation", note: saturationNote(shell.saturationControl), labelWidth: 262) {
                SettingsPercentField(title: "Tint saturation", value: $settings.shellTintSaturation,
                                     range: AppearanceSettings.tintSaturationRange)
                    .disabled(shell.saturationControl != .available)
            }
            SectionDivider()
            SettingsRow(title: "Keep transparency when inactive", note: "Keep the desktop frost visible when another window has focus") {
                InspectorSwitch(title: "Keep transparency when inactive", isOn: settings.keepsTransparencyWhenInactive,
                                help: "Turn off to use the standard macOS inactive window appearance") {
                    settings.keepsTransparencyWhenInactive.toggle()
                }
                .disabled(reduceTransparency)
            }
        }
        .graphiteCard(cornerRadius: Graphite.Metric.m)
    }

    private func saturationNote(_ control: WindowShellStyle.SaturationControl) -> String {
        switch control {
        case .available: "At 100%, the tint matches the theme"
        case .neutral: "\(settings.theme.name)’s tint has no color to adjust"
        case .transparent: "Lower transparency to show the tint"
        }
    }
}

private struct FrameSurroundCard: View {
    @Bindable var settings: AppearanceSettings
    let picture: CGImage?
    @Environment(\.colorSchemeContrast) private var contrast
    private static let specimenFraction = 0.34

    var body: some View {
        let allowsAmbient = contrast != .increased
        let ambientActive = settings.showsAmbientSurround && allowsAmbient
        let surroundHelp = "Ambient diffuses colors from the open photograph into the surround; Neutral keeps a flat gray surround"
        let showsSurround = Binding(get: { settings.showsAmbientSurround }, set: { settings.setShowsAmbientSurround($0) })
        VStack(alignment: .leading, spacing: Graphite.Metric.m) {
            SplitCardLayout(leadingFraction: Self.specimenFraction) {
                FrameSurroundSpecimen(picture: picture, palette: settings.palette, ambient: ambientActive,
                                      intensity: settings.ambientSurroundIntensity,
                                      showsShadow: ambientActive && settings.showsAmbientSurroundShadow)
                    .overlay(alignment: .trailing) { Graphite.hairline.frame(width: 1) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                    SettingsRow(title: "Surround", note: surroundNote) {
                        GraphiteSegmented(
                            selection: showsSurround,
                            segments: [
                                .init(value: true, title: "Ambient", help: surroundHelp),
                                .init(value: false, title: "Neutral", help: surroundHelp),
                            ],
                            size: .large,
                            fillsWidth: true
                        )
                        .frame(width: 196)
                        .disabled(!allowsAmbient)
                        .accessibilityLabel("Frame surround")
                    }
                    SectionDivider()
                    SettingsRow(title: "Intensity", note: "How strongly the frame tints it") {
                        SettingsPercentField(title: "Intensity", value: $settings.ambientSurroundIntensity,
                                             range: AppearanceSettings.ambientSurroundIntensityRange)
                            .frame(width: 196)
                            .disabled(!ambientActive)
                    }
                    SectionDivider()
                    SettingsRow(title: "Edge shadow", note: "A soft shadow under the frame") {
                        InspectorSwitch(title: "Ambient edge shadow", isOn: settings.showsAmbientSurroundShadow,
                                        help: "Adds a soft grounding shadow outside the photograph's crisp edge while Ambient is on") {
                            settings.setShowsAmbientSurroundShadow(!settings.showsAmbientSurroundShadow)
                        }
                        .disabled(!ambientActive)
                    }
                }
            }
            .graphiteCard(cornerRadius: Graphite.Metric.m)

            Label("View › Gray Surround (⇧⌘G) \(ambientActive ? "always " : "")switches to 18% gray for proofing",
                  systemImage: "info.circle")
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.tertiaryText)
        }
    }

    private var surroundNote: String {
        if contrast == .increased { return "Increase Contrast keeps the surround neutral" }
        return settings.showsAmbientSurround ? "Colors from the open frame" : "Flat gray in every theme"
    }
}

/// Splits a card into a leading specimen and trailing rows whose height sizes the card.
private struct SplitCardLayout: Layout {
    let leadingFraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let trailingFraction = max(0.01, 1 - leadingFraction)
        let width: CGFloat
        if let proposed = proposal.width {
            width = max(0, proposed)
        } else {
            width = subviews[1].sizeThatFits(.unspecified).width / trailingFraction
        }
        let trailing = subviews[1].sizeThatFits(ProposedViewSize(width: width * trailingFraction, height: proposal.height))
        return CGSize(width: width, height: trailing.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let leadingWidth = bounds.width * leadingFraction
        subviews[0].place(at: bounds.origin,
                          proposal: ProposedViewSize(width: leadingWidth, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + leadingWidth, y: bounds.minY),
                          proposal: ProposedViewSize(width: bounds.width - leadingWidth, height: bounds.height))
    }
}

private struct RollsBackdropCard: View {
    let settings: AppearanceSettings
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        let allowsBackdrop = contrast != .increased
        SettingsRow(title: "Backdrop",
                    note: allowsBackdrop ? "Grain drifts behind the Rolls page and follows the pointer"
                        : "Increase Contrast hides the backdrop") {
            InspectorSwitch(title: "Rolls backdrop", isOn: settings.showsOpenRollBackdrop,
                            help: "On shows grain drifting behind the Rolls page; Off leaves the page plain") {
                settings.setShowsOpenRollBackdrop(!settings.showsOpenRollBackdrop)
            }
            .disabled(!allowsBackdrop)
        }
        .background {
            if isVisible && settings.showsOpenRollBackdrop && allowsBackdrop {
                OpenRollBackdrop(column: .zero, heroZone: nil, hero: .ready, reduceMotion: reduceMotion)
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0.36), .init(color: .white, location: 0.78)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .opacity(0.75)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .graphiteCard(cornerRadius: Graphite.Metric.m)
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
    }
}

struct DevelopMemoryCard: View {
    let settings: DevelopMemorySettings

    static let enabledNote = "More memory lets two frames decode at once; changes apply from the next develop"
    static let disabledNote = "Higher limits require at least 12 GB of memory"

    var body: some View {
        let selection = Binding(get: { settings.choice }, set: { settings.setChoice($0) })
        SettingsRow(title: "Memory while developing",
                    note: settings.hasExtraChoices ? Self.enabledNote : Self.disabledNote) {
            GraphiteSegmented(
                selection: selection,
                segments: settings.offeredChoices.map { choice in
                    .init(value: choice, title: choice.title,
                          help: Self.help(for: choice, hasExtraChoices: settings.hasExtraChoices))
                },
                size: .large,
                fillsWidth: true
            )
            .frame(width: max(84, CGFloat(settings.offeredChoices.count) * 76))
            .disabled(!settings.hasExtraChoices)
            .accessibilityLabel("Memory while developing")
        }
        .graphiteCard(cornerRadius: Graphite.Metric.m)
    }

    private static func help(for choice: DevelopBudget.Choice, hasExtraChoices: Bool) -> String {
        guard hasExtraChoices else { return disabledNote }
        switch choice {
        case .default: return "Keep develops under the standard memory limit"
        case .gb3, .gb4, .gb6: return "Allow develops up to \(choice.title) so two frames can decode at once"
        }
    }
}
