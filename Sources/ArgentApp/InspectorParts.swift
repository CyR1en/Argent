import SwiftUI

// The Adjust inspector's own parts, which its five tabs share: a group's heading and its reset, a group that folds, a switch,
// a menu's chip and the step wedge. Each is drawn plainly on the inspector's glass, in the theme's ink.

/// A group's reset, on its heading: what VoiceOver calls it ("Reset Presence"), its help tag, whether the group has anything
/// to clear, and the reset itself.
struct InspectorReset {
    var title: String
    var help: String
    var isEnabled: Bool
    var action: () -> Void
}

/// A group's name over its rows ("Presence", "Defringe"), in the small secondary type, with what belongs on its line after it:
/// a switch, a count's button. Its Reset shows while the pointer is over the heading or the keyboard is on the button, and
/// only while the group has something to clear, so a column of headings at rest is words alone.
struct InspectorSectionHeader<Trailing: View>: View {
    let title: String
    var reset: InspectorReset?
    @ViewBuilder var trailing: Trailing
    @State private var isHovered = false
    @FocusState private var resetFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var height: CGFloat { 20 }

    var body: some View {
        HStack(spacing: Graphite.Metric.s) {
            Text(verbatim: title)
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let reset {
                Button(action: reset.action) {
                    Text("Reset")
                        .font(Graphite.Typeface.caption)
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InspectorQuietStyle())
                .focused($resetFocused)
                .disabled(!reset.isEnabled)
                .opacity(reset.isEnabled && (isHovered || resetFocused) ? 1 : 0)
                .accessibilityHidden(!reset.isEnabled)
                .accessibilityLabel(reset.title)
                .help(reset.help)
            }
            trailing
        }
        // A button on its line is taller than its words.
        .frame(minHeight: Self.height)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
    }
}

extension InspectorSectionHeader where Trailing == EmptyView {
    init(title: String, reset: InspectorReset? = nil) {
        self.init(title: title, reset: reset) { EmptyView() }
    }
}

/// A word or a symbol that is a button on the inspector's glass: secondary until the pointer is over it, then the text's
/// colour on a light fill. It draws its own disabled look (`MaskPressStyle`).
struct InspectorQuietStyle: ButtonStyle {
    var radius: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, radius: radius)
    }

    private struct Face: View {
        let configuration: ButtonStyle.Configuration
        let radius: CGFloat
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(!isEnabled ? Graphite.tertiaryText : isHovered ? Graphite.text : Graphite.secondaryText)
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Graphite.ink(configuration.isPressed ? 0.14 : isHovered && isEnabled ? 0.09 : 0))
                }
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
        }
    }
}

/// A switch in the theme's own colours, on a group's heading or a row's trailing edge: Graphite has no accent for the system's
/// to draw in. On, its track is the selection colour and its knob the colour text takes on that.
struct InspectorSwitch: View {
    /// What VoiceOver calls it; its words are the heading or the row beside it.
    let title: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 30, height: 18)
    private static let knob: CGFloat = 14

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Graphite.selection) : AnyShapeStyle(Graphite.ink(0.2)))
                .frame(width: Self.size.width, height: Self.size.height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(Graphite.onPrimary) : AnyShapeStyle(Graphite.text))
                        .frame(width: Self.knob, height: Self.knob)
                        .shadow(color: Color.black.opacity(0.3), radius: 1, y: 0.5)
                        .padding(2)
                }
                .opacity(isEnabled ? 1 : 0.42)
                .contentShape(Capsule())
                .animation(reduceMotion ? nil : Graphite.Motion.press, value: isOn)
        }
        .buttonStyle(MaskPressStyle())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A group of rows that folds under its name: open, the rows; closed, the name with what the group holds beside it
/// ("Warmth −8"), so a long panel is a few lines until a group is wanted, and a closed group still says what it does.
struct InspectorGroup<Content: View>: View {
    let title: String
    /// What the closed group holds, in a row's own words; "No changes" with nothing moved.
    let summary: String
    let isOpen: Bool
    let toggle: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var headHeight: CGFloat { 30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionDivider()
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    Text(verbatim: title)
                        .font(Graphite.Typeface.small)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: Graphite.Metric.s)
                    if !isOpen {
                        Text(verbatim: summary)
                            .font(Graphite.Typeface.caption.monospacedDigit())
                            .foregroundStyle(Graphite.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .transition(.opacity)
                    }
                }
                .frame(height: Self.headHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(InspectorGroupHeadStyle())
            .accessibilityLabel(title)
            .accessibilityValue(isOpen ? "Shown" : summary)
            .accessibilityHint(isOpen ? "Hides this group’s sliders." : "Shows this group’s sliders.")
            .help(isOpen ? "Hide \(title)" : "Show \(title)")
            if isOpen {
                content
                    .padding(.top, 2)
                    .padding(.bottom, Graphite.Metric.m)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isOpen)
    }
}

/// A folding group's head: its words secondary, the text's colour under the pointer, with no fill.
private struct InspectorGroupHeadStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered ? Graphite.text : Graphite.secondaryText)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovered = $0 }
        }
    }
}

/// A small pop-up's face in a line of words: its value and a chevron on a light fill ("Auto ⌄" after "starting from").
struct InspectorChipFace: View {
    let text: String
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.segmentRadius, style: .continuous)
        HStack(spacing: 3) {
            Text(verbatim: text)
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.text)
                .lineLimit(1)
                .contentTransition(.opacity)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Graphite.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(height: 20)
        .background(shape.fill(Graphite.ink(isHovered && isEnabled ? 0.12 : 0.07)))
        .overlay { if contrast == .increased { shape.strokeBorder(Graphite.strongBorder, lineWidth: 1) } }
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.42)
        .onHover { isHovered = $0 }
    }
}

/// A menu's face beside a button at the inspector's foot: its word and a chevron on the glass, a small button's height and no
/// wider than its word needs. `MenuFace` gives its word 12 points a side and a spring before its chevron, 17 points more for
/// "Reset", which the foot's Compare needs for "Compare to Original" (`AdjustFooter`).
struct InspectorMenuFace: View {
    let title: String
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(Graphite.Typeface.label)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Graphite.secondaryText)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Graphite.text)
        .padding(.horizontal, 10)
        .frame(height: Graphite.Metric.controlHeight)
        .background(shape.fill(Graphite.ink(isHovered && isEnabled ? 0.09 : 0.05)))
        .overlay { shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1) }
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.42)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
    }
}

/// A step wedge: eleven grays from black to white, as a darkroom's step tablet has them. Under the histogram and along the
/// curve graph's two axes it says which end is dark, in the picture's own terms and in every theme alike, where a word would
/// need turning on its side.
struct StepWedge: View {
    enum Direction { case leftToRight, bottomToTop }
    var direction = Direction.leftToRight

    static let steps = 11
    static let thickness: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            for step in 0..<Self.steps {
                // A little brighter than linear in code, so the dark steps part on a dark panel.
                let level = pow(Double(step) / Double(Self.steps - 1), 1 / 1.15)
                let start = CGFloat(step) / CGFloat(Self.steps), end = CGFloat(step + 1) / CGFloat(Self.steps)
                let rect = direction == .leftToRight
                    ? CGRect(x: start * size.width, y: 0, width: (end - start) * size.width, height: size.height)
                    : CGRect(x: 0, y: (1 - end) * size.height, width: size.width, height: (end - start) * size.height)
                context.fill(Path(rect), with: .color(Color(.sRGB, white: level, opacity: 1)))
            }
        }
        .accessibilityHidden(true)
    }
}
