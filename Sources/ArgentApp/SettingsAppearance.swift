import SwiftUI

struct SettingsAppearance: View {
    /// Theme tile fills held to 4.5 to 1 across every palette (`ThemeTests`).
    static let tileRestInk = 0.05, tileHoverInk = 0.07, tileBadgeInk = 0.03

    let settings: AppearanceSettings
    let pictures: [CGImage?]

    var body: some View {
        let theme = settings.theme
        VStack(alignment: .leading, spacing: 0) {
            appearanceLine("Mode", note: modeNote) {
                GraphiteSegmented(
                    selection: Binding(get: { settings.mode }, set: settings.setMode),
                    segments: ThemeMode.allCases.map {
                        .init(value: $0, title: $0.title, accessibilityLabel: "Mode: \($0.title)",
                              symbol: $0.symbol, showsTitleWithSymbol: true)
                    },
                    size: .large,
                    fillsWidth: true
                )
                .frame(width: 312)
                .accessibilityLabel("Mode")
            }
            HStack(alignment: .top, spacing: Graphite.Metric.l) {
                ThemeProof(mode: .light, version: theme.light, settings: settings, pictures: pictures)
                ThemeProof(mode: .dark, version: settings.darkVersion(of: theme), settings: settings, pictures: pictures)
            }
            .padding(.top, 14)
            appearanceLine("Theme", note: "A theme brings both of its versions, and Mode says which shows") { EmptyView() }
                .padding(.top, 22)
            // Three equal columns, drawn at once: a lazy grid would have its scroll view move the page when a change
            // of theme lays it out again.
            let themes = ThemeCatalog.themes
            Grid(horizontalSpacing: Graphite.Metric.s, verticalSpacing: Graphite.Metric.s) {
                ForEach(Array(stride(from: 0, to: themes.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(themes[start..<min(start + 3, themes.count)]) { theme in
                            ThemeTile(theme: theme, dark: settings.darkVersion(of: theme), isSelected: settings.themeID == theme.id) {
                                settings.selectTheme(theme.id)
                            }
                        }
                    }
                }
            }
            .padding(.top, Graphite.Metric.m)
        }
    }

    private var modeNote: String {
        guard settings.mode == .system else { return "" }
        return "Follows the Mac, \(settings.systemIsDark ? "dark" : "light") now"
    }

    private func appearanceLine<Control: View>(_ title: String, note: String,
                                               @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: Graphite.Metric.m) {
            Text(verbatim: title)
                .font(Graphite.Typeface.row)
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: note)
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(note.isEmpty)
            control()
        }
        .frame(minHeight: 34)
    }
}

private struct ThemeProof: View {
    let mode: ThemeMode
    let version: ThemeVersion?
    let settings: AppearanceSettings
    let pictures: [CGImage?]
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    private var showing: Bool { version?.palette == settings.palette }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Graphite.Metric.railItemRadius) }

    var body: some View {
        VStack(spacing: Graphite.Metric.m) {
            Button { settings.setMode(mode) } label: {
                Graphite.well
                    .aspectRatio(DevelopProof.size.width / DevelopProof.size.height, contentMode: .fit)
                    .overlay {
                        if let version {
                            GeometryReader { geometry in
                                DevelopProof(palette: version.palette, pictures: pictures)
                                    .frame(width: DevelopProof.size.width, height: DevelopProof.size.height)
                                    .scaleEffect(geometry.size.width / DevelopProof.size.width, anchor: .topLeading)
                            }
                            .brightness(isHovered ? 0.03 : 0)
                        } else {
                            missingLightProof
                        }
                    }
                    .clipShape(shape)
                    .shadow(color: Graphite.shadow.opacity(showing ? 0.53 : 0.4), radius: showing ? 9 : 7, y: 4)
                    .overlay { outline.allowsHitTesting(false) }
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityLabel("\(mode.title) preview")
            .accessibilityValue(proofAccessibilityValue)
            .accessibilityAddTraits(showing ? .isSelected : [])

            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(Graphite.Typeface.label)
                    .accessibilityHidden(true)
                if mode == .dark, let version, settings.theme.dark.count > 1 {
                    darkVersions(version)
                } else {
                    Text(verbatim: version?.title ?? "None")
                        .font(Graphite.Typeface.label)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                if showing { Pill(text: "Showing") }
            }
            .foregroundStyle(showing ? Graphite.text : Graphite.secondaryText)
            .padding(.horizontal, 2)
            .frame(height: 20)
        }
    }

    private var proofAccessibilityValue: String {
        guard let version else { return "\(settings.theme.name) has no light version, so Argent stays dark" }
        return showing ? "\(version.title), showing" : version.title
    }

    @ViewBuilder private var outline: some View {
        if showing {
            RoundedRectangle(cornerRadius: Graphite.Metric.railItemRadius + 4)
                .strokeBorder(Graphite.selection, lineWidth: Graphite.Metric.selectionWidth)
                .padding(-4)
        } else {
            shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
        }
    }

    private var missingLightProof: some View {
        VStack(spacing: Graphite.Metric.xs) {
            Text("No light version")
                .font(Graphite.Typeface.chipTitle)
                .foregroundStyle(Graphite.text)
            Text("\(settings.theme.name) is dark only, so Argent stays dark")
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Canvas { context, size in
                var hatch = Path()
                for x in stride(from: -size.height, through: size.width, by: 12 * CGFloat(2).squareRoot()) {
                    hatch.move(to: CGPoint(x: x + size.height, y: 0))
                    hatch.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(hatch, with: .color(Graphite.ink(0.035)), lineWidth: 6)
            }
        }
    }

    private func darkVersions(_ version: ThemeVersion) -> some View {
        let theme = settings.theme
        let label = "\(theme.name) dark versions"
        let selection = Binding(get: { settings.darkVersion(of: theme).id },
                                set: { settings.selectDarkVersion($0, of: theme.id) })
        return Menu {
            Picker(label, selection: selection) {
                ForEach(theme.dark) { Text(verbatim: $0.title).tag($0.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            InspectorChipFace(text: version.title)
        }
        .graphiteMenu()
        .accessibilityRepresentation {
            Picker(label, selection: selection) {
                ForEach(theme.dark) { Text(verbatim: $0.title).tag($0.id) }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(label)
        }
        .help("More dark versions of \(theme.name)")
    }
}

private struct ThemeTile: View {
    let theme: AppTheme
    let dark: ThemeVersion
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let label = theme.light.map { "\(theme.name): \($0.title) and \(dark.title)" } ?? "\(theme.name): dark only"
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.m)
        Button(action: action) {
            HStack(spacing: Graphite.Metric.m) {
                swatch
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: theme.name)
                            .font(isSelected ? Graphite.Typeface.chipTitle : Graphite.Typeface.label)
                        if isSelected {
                            Image(systemName: "checkmark.circle")
                                .font(Graphite.Typeface.label)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(verbatim: theme.light.map { "\($0.title) · \(dark.title)" } ?? dark.title)
                            .foregroundStyle(Graphite.secondaryText)
                        if theme.dark.count > 1 {
                            let badgeShape = RoundedRectangle(cornerRadius: Graphite.Metric.xs)
                            Text("+\(theme.dark.count - 1)")
                                .monospacedDigit()
                                .padding(.horizontal, Graphite.Metric.xs)
                                .background(Graphite.ink(SettingsAppearance.tileBadgeInk), in: badgeShape)
                                .overlay {
                                    badgeShape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border,
                                                            lineWidth: 1)
                                }
                                .fixedSize()
                        }
                    }
                    .font(Graphite.Typeface.caption)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Graphite.text)
            .padding(.horizontal, Graphite.Metric.m)
            .frame(height: 56)
            .background(shape.fill(Graphite.ink(isHovered ? SettingsAppearance.tileHoverInk : SettingsAppearance.tileRestInk)))
            .overlay {
                shape.strokeBorder(isSelected ? Graphite.text : contrast == .increased ? Graphite.strongBorder : Graphite.border,
                                   lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var swatch: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        return HStack(spacing: 0) {
            if let light = theme.light { swatchHalf(light.palette) }
            swatchHalf(dark.palette)
        }
        .frame(width: 52, height: 34)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Graphite.strongBorder, lineWidth: 0.5) }
    }

    private func swatchHalf(_ palette: ThemePalette) -> some View {
        let colors = GraphiteColors(palette)
        return VStack(alignment: .leading, spacing: 3) {
            Capsule().fill(colors.text).frame(width: 12, height: 2)
            Capsule().fill(colors.text.opacity(0.5)).frame(width: 12, height: 2)
            Spacer(minLength: 0)
            Capsule().fill(colors.primaryBottom).frame(width: 14, height: 6)
        }
        .padding(.leading, 5)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.workspace)
    }
}
