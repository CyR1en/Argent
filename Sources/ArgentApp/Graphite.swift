import AppKit
import SwiftUI

/// The Graphite Immersive visual system (Roll workflow section 15, SPEC's Visual system): a title
/// strip across the window's top, a rail set into a narrow column of the chrome, one inset rounded
/// workspace, fine monochrome line icons, and the system's Liquid Glass for the controls over it: low
/// docks and panels, quieter secondary actions and the one primary action in each state in the theme's
/// primary colour. Every screen takes its colours, sizes and controls from here rather than styling
/// itself.
///
/// The colours are the chosen theme's (Themes.swift, Roll workflow section 16). Each token reads
/// `AppearanceSettings`, which is observable, so a view that draws with one follows a change of theme
/// or Mode; code that draws outside a view's body, an `NSView`'s `draw`, has its representable read
/// `palette` in its update so that it is asked to draw again.
@MainActor enum Graphite {
    private static var colors: GraphiteColors { AppearanceSettings.shared.colors }

    /// The palette in use, for a representable to depend on (see above).
    static var palette: ThemePalette { AppearanceSettings.shared.palette }
    static var isDark: Bool { colors.isDark }

    // MARK: Surfaces

    /// The window's chrome: the rail, the inspector column and the edge round the workspace.
    static var chrome: Color { colors.chrome }
    /// The inset workspace's matte ground, behind the contact sheet and the pages.
    static var workspace: Color { colors.workspace }
    /// Round a photograph in the frame view: neutral in every theme, so no tint sits beside it.
    static var photoSurround: Color { colors.photoSurround }
    /// A thumbnail's bed and a picture not arrived yet.
    static var well: Color { colors.well }
    static var placeholder: Color { colors.placeholder }
    /// A field with the keyboard in it.
    static var control: Color { colors.control }

    /// White over a dark theme's surfaces and black over a light one's, for light fills and lines.
    static func ink(_ opacity: Double) -> Color { colors.ink.opacity(opacity) }
    /// The same for code that draws with AppKit.
    static func inkNSColor(_ opacity: CGFloat) -> NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
    }
    /// Hover over a quiet control.
    static var hoverFill: Color { ink(0.06) }

    // MARK: Text

    /// The theme's text, never pure white on a dark theme.
    static var text: Color { colors.text }
    static var secondaryText: Color { colors.secondaryText }
    /// The title and rail sit directly over the desktop frost, where the palette's normal text can lose contrast.
    static var shellText: Color { colors.ink }
    static var shellSecondaryText: Color { colors.shellSecondaryText }
    /// Muted meta and captions: at least 4.5 to 1 on the workspace, the least small text may have
    /// (`ThemeTests`).
    static var tertiaryText: Color { colors.tertiaryText }

    // MARK: Lines

    /// Separators inside a surface.
    static var hairline: Color { ink(0.09) }
    /// A control's or a floating surface's edge.
    static var border: Color { ink(0.12) }
    /// The same with Increase Contrast.
    static var strongBorder: Color { colors.strongBorder }
    /// The selected thumbnail's ring and the keyboard focus ring.
    static var selection: Color { colors.selection }
    /// Warm selection ink on the dock, with a darker brass for light themes.
    static var dockAccent: Color {
        isDark ? Color(red: 0.95, green: 0.82, blue: 0.61) : Color(red: 0.44, green: 0.30, blue: 0.10)
    }

    /// The chosen segment lifted on its track.
    static var segmentThumb: Color { colors.segmentThumb }

    // MARK: Primary

    /// The primary action's colour, lit from above: pale silver in Graphite's dark version.
    static var primaryTop: Color { colors.primaryTop }
    static var primaryBottom: Color { colors.primaryBottom }
    /// Text on the primary colour: at least 4.5 to 1 against either edge (`ThemeTests`).
    static var onPrimary: Color { colors.onPrimary }

    // MARK: Over the glass

    /// A small mark drawn plainly on a glass surface (the stock in use's check), opaque enough to
    /// hold over the picture under it. Liquid Glass itself is the system's (`glassEffect`), which
    /// turns frosted with Reduce Transparency.
    static var floatingOpaque: Color { colors.floatingOpaque }
    /// Under the split divider's handle.
    static let shadow = Color.black.opacity(0.30)

    /// Colours of the stand-in photographs used by Settings.
    enum ProofArtwork {
        static let scenes: [[UInt32]] = [
            [0x66768c, 0xd2ae8c, 0x47515c, 0x2c343c],
            [0xc5c9c5, 0xa4ada8, 0x647268, 0x2f3a33],
            [0xb79d84, 0xa58970, 0x9b8068, 0x8c715a],
            [0xb9c2b4, 0x8a9a66, 0x637746, 0x4c5f3a],
            [0x171d2a, 0x232a38, 0x232a38, 0x0e1117],
            [0xcdd3d9, 0xe6e9eb, 0x6f7a80, 0xe3e6e8],
            [0x86a8c2, 0xc4cfcf, 0xad8c62, 0x86663f],
            [0x3a332d, 0x433933, 0x322a25, 0x1f1c1a],
            [0xc3d1d8, 0xdbe2e0, 0x5d7c84, 0x3c5862],
        ]

        static let trees: UInt32 = 0x222d27
        static let figure: UInt32 = 0x1e222c
        static let streetlights: [UInt32] = [0xffc482, 0xaac8eb, 0xffaa78]
        static let moon: UInt32 = 0xecdfc8
    }

    // MARK: Type

    /// One scale of seven sizes, 11, 12, 13, 14, 15, 19 and 26 points, in two weights: regular,
    /// and semibold for titles and the primary action. A view takes its type from here rather than
    /// sizing its own.
    enum Typeface {
        /// "Settings", "Drop a roll here".
        static let pageTitle = Font.system(size: 26, weight: .semibold)
        /// "Choose stock", "Develop roll", "Adjust".
        static let panelTitle = Font.system(size: 19, weight: .semibold)
        /// "Argent" at the upper left of the Open roll page.
        static let wordmark = Font.system(size: 19)
        static let sectionTitle = Font.system(size: 15, weight: .semibold)
        /// A list row's name ("Sample roll"), a setting's ("Format") and the line under a page's
        /// or a sheet's title.
        static let row = Font.system(size: 15)
        /// The roll's name in the title strip's centre.
        static let chipTitle = Font.system(size: 13, weight: .semibold)
        /// The primary and secondary actions at the top of the workspace.
        static let action = Font.system(size: 14, weight: .semibold)
        static let secondaryAction = Font.system(size: 13)
        static let body = Font.system(size: 13)
        static let label = Font.system(size: 13)
        static let small = Font.system(size: 12)
        static let pageSection = Font.system(size: 11, weight: .semibold)
        static let pill = Font.system(size: 10, weight: .semibold)
        static let caption = Font.system(size: 11)
        /// Counts and values, with tabular figures.
        static let number = Font.system(size: 13).monospacedDigit()
    }

    // MARK: Metrics

    enum Metric {
        // The title strip.
        /// The strip across the window's top: the window's buttons, the roll's title and the
        /// view's actions on one centre line. A unified title bar's height, so macOS centres its
        /// buttons on the same line (`WindowChrome`).
        static let titleStripHeight: CGFloat = 52
        /// Where the strip's "Argent" starts: clear of the window's close, minimize and zoom
        /// buttons, which end about 78 points in.
        static let titleStripLeading: CGFloat = 94

        // The rail.
        /// The column down the leading edge that the rail's symbols are set into: its 40-point
        /// items and 10 points either side.
        static let railWidth: CGFloat = 60
        /// A rail item, its chosen lens's corners and its symbol.
        static let railItem: CGFloat = 40
        static let railItemRadius: CGFloat = 10
        static let railIcon: CGFloat = 17

        // The workspace.
        /// Between the workspace and the window's trailing and bottom edges; the title strip is
        /// above it.
        static let workspaceInset: CGFloat = 6
        static let workspaceRadius: CGFloat = 16
        /// From the workspace's edges to its content and its floating docks; the title strip's
        /// chip and actions line up with the docks on it.
        static let edge: CGFloat = 18

        // Controls.
        static let actionHeight: CGFloat = 32
        static let actionRadius: CGFloat = 8
        static let controlHeight: CGFloat = 28
        static let controlRadius: CGFloat = 7
        static let segmentRadius: CGFloat = 6
        static let focusRing: CGFloat = 2

        // Docks and panels.
        static let dockHeight: CGFloat = 54
        static let dockRadius: CGFloat = 13
        static let dockInset: CGFloat = 12
        /// From the workspace's foot to a dock's top edge, where the sheet's pictures fade out.
        static let dockTop: CGFloat = dockHeight + dockInset
        /// The workspace's bottom band a dock takes: the dock and the room under and above it, so
        /// the sheet and the fitted frame end above it.
        static let dockBand: CGFloat = dockTop + 10
        static let panelRadius: CGFloat = 16

        // The inspector beside the workspace.
        /// The inspector's glass panel, and the room either side of it: wider than the workspace's
        /// own 6-point inset, since a glass panel's bright edge reads as touching closer than that.
        static let inspectorPanelWidth: CGFloat = 280
        static let inspectorGutter: CGFloat = 12
        /// The column the inspector takes beyond the workspace.
        static let inspectorWidth: CGFloat = inspectorPanelWidth + 2 * inspectorGutter
        static let inspectorPadding: CGFloat = 20
        /// The Adjust inspector's own: from the panel's edges to its controls, which leaves a slider's track, running its row's
        /// width, 248 points.
        static let adjustPadding: CGFloat = 16
        static let adjustColumn: CGFloat = inspectorPanelWidth - 2 * adjustPadding

        // Pictures.
        static let thumbnailRadius: CGFloat = 4
        static let selectionWidth: CGFloat = 2

        // Spacing.
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// How the interface moves (SPEC's Visual system; Roll workflow section 24). Fades and colours ease out; what has a
    /// place and a size, a control under a press, a lens, a panel, a picture, moves on a spring, so a move that is
    /// interrupted goes on from where it is and at the speed it has. None of it runs with Reduce Motion.
    enum Motion {
        static let quick = ease(0.15)
        static let panel = ease(0.22)

        /// A control dipping under a press, and coming back up when it is let go, a little past its rest.
        static let press = spring(0.2, 0.85)
        static let release = spring(0.42, 0.5)
        /// Something small growing under the pointer: a knob, a handle, a tile.
        static let swell = spring(0.3, 0.78)
        /// A handle or a knob taken up, and following the pointer while it is held.
        static let grab = spring(0.25, 0.64)
        static let follow = spring(0.12, 0.92)
        /// A drop's two edges (`Drop`): the one in front is quicker than the one behind, so it stretches as it goes.
        static let lead = spring(0.3, 0.84)
        static let trail = spring(0.46, 0.9)
        /// A ring or a highlight going from one thing to the next.
        static let glide = spring(0.32, 0.86)
        /// A mark landing: a flag, a check, a pin's core.
        static let land = spring(0.36, 0.55)
        /// Glass arriving over the workspace: a notice, a tag.
        static let arrive = spring(0.46, 0.72)
        /// A button's glass taking the width of its next title, and one budding off the button beside it.
        static let reshape = spring(0.42, 0.76)
        static let bud = spring(0.52, 0.74)
        /// A panel or a column coming in beside or over the workspace, which makes room with it.
        static let surface = spring(0.43, 0.87)
        /// Between the contact sheet and the frame view: the thumbnail grows into the frame. A spring that ends at
        /// rest to the eye, so the frame view shrunk back onto its cell leaves the window then (`RestingSpring`).
        static let hero = restingSpring(0.46, 0.86)
        /// A zoom coming to rest, and the split comparison's divider coming in.
        static let settle = spring(0.4, 0.85)
        static let wipe = spring(0.5, 0.86)
        /// A value going back to where a reset, an undo or a paste left it.
        static let value = spring(0.36, 0.9)

        /// A spring by how long it takes to answer, in seconds, and how damped it is, 1 with no overshoot.
        /// Changes closer together than this are a run's, a held key's steps or the values a drag sends: what animates
        /// to a change by itself shows a run as it comes (`ChangePace`). In real seconds, whatever `slow` is.
        static let runGap: CFTimeInterval = 0.3

        static func spring(_ response: Double, _ damping: Double) -> Animation {
            .spring(response: response * slow, dampingFraction: damping)
        }

        /// The same spring, ending once it is at rest to the eye: for a move a view leaves on (`RestingSpring`).
        static func restingSpring(_ response: Double, _ damping: Double) -> Animation {
            Animation(RestingSpring(response: response * slow, dampingFraction: damping))
        }

        /// An ease out over `duration` seconds.
        static func ease(_ duration: Double) -> Animation {
            .easeOut(duration: duration * slow)
        }

        /// How many times slower than it is everything here moves: 1, except in a debug build launched with
        /// `ARGENT_MOTION_SLOW`, 10 for a tenth of the speed, to watch a move or capture it part of the way.
        static let slow: Double = {
            #if DEBUG
            if let asked = ProcessInfo.processInfo.environment["ARGENT_MOTION_SLOW"].flatMap(Double.init), asked >= 1 { return asked }
            #endif
            return 1
        }()
    }
}

// MARK: - Liquid Glass

extension EnvironmentValues {
    /// Inside a Liquid Glass surface (a dock, the rail, a panel, a card, a notice): controls there
    /// draw plainly on the surface's glass rather than as glass of their own, since glass is not
    /// stacked on glass.
    @Entry var isOnGlass = false
}

extension Graphite {
    /// The primary action's glass: Liquid Glass tinted the primary colour, so it stays the one lit
    /// control in each state, and answering the pointer as the system's buttons do.
    static func primaryGlass(isEnabled: Bool = true) -> Glass {
        Glass.regular.tint(primaryTop.opacity(0.9)).interactive(isEnabled)
    }

    /// A control's glass: the system's regular glass, answering the pointer. A toggle drawn as a button keeps it while it
    /// is on, and takes its tint from the wash over it (`ToggleWash`).
    static func controlGlass(isEnabled: Bool = true) -> Glass {
        Glass.regular.interactive(isEnabled)
    }
}

// MARK: - Buttons

/// The workspace's buttons, on Liquid Glass: `primary` is the tinted glass of the one next
/// action in each state, `secondary` the system's regular glass beside it, `quiet` borderless until
/// hovered (a dock's own actions), and `icon` a square of glass for a symbol alone. On a glass
/// surface a secondary or icon button draws plainly instead (`isOnGlass`). Each keeps its size
/// whatever its label, answers hover and press, dims when disabled and draws a focus ring when the
/// keyboard reaches it.
struct GraphiteButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, icon }
    enum Size { case regular, small, large }

    var kind: Kind = .secondary
    var size: Size = .regular
    /// For a toggle drawn as a button: on.
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        GraphiteButton(configuration: configuration, style: self)
    }

    var height: CGFloat {
        switch size {
        case .regular: Graphite.Metric.actionHeight
        case .small: Graphite.Metric.controlHeight
        case .large: 36
        }
    }
}

extension ButtonStyle where Self == GraphiteButtonStyle {
    static func graphite(_ kind: GraphiteButtonStyle.Kind, size: GraphiteButtonStyle.Size = .regular,
                         isOn: Bool = false) -> GraphiteButtonStyle {
        GraphiteButtonStyle(kind: kind, size: size, isOn: isOn)
    }
}

private struct GraphiteButton: View {
    let configuration: ButtonStyle.Configuration
    let style: GraphiteButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isOnGlass) private var isOnGlass
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hoverGlide) private var hoverGlide
    /// Where the pointer is on it, for the light it leaves and for where a toggle's tint washes in from.
    @State private var spot = PointerSpot()

    private var radius: CGFloat {
        style.size == .small ? Graphite.Metric.controlRadius : Graphite.Metric.actionRadius
    }

    /// A quiet button on a surface with a shared hover highlight leaves its hover to that (`HoverGlide`).
    private var glides: Bool { style.kind == .quiet && hoverGlide != nil }
    private var isHovered: Bool { spot.isInside }

    var body: some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: style.kind == .icon ? style.height : nil, minHeight: style.height)
            .background {
                if style.kind != .primary {
                    ToggleWash(isOn: style.isOn, shape: shape, color: Graphite.ink(onInk), spot: spot)
                }
            }
            .background { shape.fill(Graphite.ink(fill(pressed: pressed))) }
            .overlay {
                if showsBorder {
                    shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
                }
            }
            .overlay {
                if style.kind != .quiet {
                    PointerLight(spot: spot, shape: shape, isPressed: pressed, reach: 70, bloom: 44)
                }
            }
            .glassEffect(glass, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
            .onContinuousHover { spot.follow($0) }
            .animation(Graphite.Motion.quick, value: isHovered)
            // The fill under a press comes in quickly and lets go slowly, as the light does; the dip is a spring.
            .animation(reduceMotion ? nil : Graphite.Motion.ease(pressed ? 0.07 : 0.35), value: pressed)
            .pressSpring(pressed)
            // Outside the dip, which would otherwise be in the place it reports: the shared highlight dips by itself.
            .joinsHoverGlide(radius: radius, isPressed: pressed, isJoined: glides)
    }

    /// The glass under the label: none for a quiet button, or for a secondary one on glass. A toggle that is on keeps the
    /// plain glass and takes its tint from the wash over it, which can come in from where it was clicked.
    private var glass: Glass {
        switch style.kind {
        case .primary: Graphite.primaryGlass(isEnabled: isEnabled)
        case .secondary, .icon: isOnGlass ? .identity : Graphite.controlGlass(isEnabled: isEnabled)
        case .quiet: .identity
        }
    }

    /// Ink over the label's ground: the plain button's own fill, or a light touch of hover and
    /// press on glass that already answers the pointer. A toggle's tint is the wash's (`onInk`).
    private func fill(pressed: Bool) -> Double {
        switch style.kind {
        case .primary:
            return 0
        case .secondary, .icon:
            if isOnGlass { return pressed ? 0.13 : isHovered ? 0.09 : 0.05 }
            return pressed ? 0.08 : isHovered ? 0.04 : 0
        case .quiet:
            return pressed ? 0.12 : isHovered && !glides ? 0.07 : 0
        }
    }

    /// The tint of a toggle that is on, over its fill.
    private var onInk: Double {
        switch style.kind {
        case .primary: 0
        case .secondary, .icon: isOnGlass ? 0.15 : (Graphite.isDark ? 0.22 : 0.14)
        case .quiet: 0.14
        }
    }

    private var showsBorder: Bool {
        switch style.kind {
        case .primary: contrast == .increased
        case .secondary, .icon: isOnGlass || contrast == .increased
        case .quiet: (isHovered && !glides) || style.isOn
        }
    }

    private var font: Font {
        switch style.kind {
        case .primary:
            switch style.size {
            case .small: .system(size: 12, weight: .semibold)
            case .regular: Graphite.Typeface.action
            case .large: .system(size: 15, weight: .semibold)
            }
        case .secondary, .icon: style.size == .small ? Graphite.Typeface.small : Graphite.Typeface.secondaryAction
        case .quiet: Graphite.Typeface.small
        }
    }

    private var horizontalPadding: CGFloat {
        switch style.kind {
        case .icon: 0
        case .quiet: 8
        default: style.size == .small ? 10 : 16
        }
    }

    private var foreground: Color {
        switch style.kind {
        // An inactive window's glass drops its tint, and the label then sits on the plain glass.
        case .primary: appearsActive ? Graphite.onPrimary : Graphite.text
        case .quiet: isHovered || style.isOn ? Graphite.text : Graphite.secondaryText
        default: Graphite.text
        }
    }
}

/// The tint of a toggle drawn as a button, while it is on: it washes in from where the button was clicked, or from its
/// middle when a key or a menu turned it on, and fades when it is turned off.
private struct ToggleWash<S: Shape>: View {
    let isOn: Bool
    let shape: S
    let color: Color
    let spot: PointerSpot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the wash starts, in the button's points; its middle when `nil`.
    @State private var origin: CGPoint?
    /// How far the wash has spread, 0 to 1, and how much of it shows.
    @State private var spread: CGFloat
    @State private var strength: Double

    init(isOn: Bool, shape: S, color: Color, spot: PointerSpot) {
        self.isOn = isOn
        self.shape = shape
        self.color = color
        self.spot = spot
        _spread = State(initialValue: isOn ? 1 : 0)
        _strength = State(initialValue: isOn ? 1 : 0)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // From any point of the button to its farthest corner.
            let reach = hypot(size.width, size.height)
            shape.fill(color)
                .mask {
                    Circle()
                        .frame(width: 2 * reach, height: 2 * reach)
                        .scaleEffect(spread)
                        .position(origin ?? CGPoint(x: size.width / 2, y: size.height / 2))
                }
                .opacity(strength)
        }
        .allowsHitTesting(false)
        .onChange(of: isOn) { _, on in
            guard !reduceMotion else {
                spread = on ? 1 : 0
                strength = on ? 1 : 0
                return
            }
            if on {
                origin = spot.isInside ? spot.location : nil
                strength = 1
                withAnimation(Graphite.Motion.ease(0.42)) { spread = 1 }
            } else {
                withAnimation(Graphite.Motion.ease(0.25)) { strength = 0 } completion: {
                    // Ready to wash in again, unless it already has.
                    if strength == 0 { spread = 0 }
                }
            }
        }
    }
}

// MARK: - Floating surfaces

extension View {
    /// A borderless frosted floating surface with the workspace's drop shadow: a dock, a side panel,
    /// a notice or a tag. Controls on it draw plainly (`isOnGlass`); with Increase Contrast it takes
    /// a firm edge, and with Reduce Transparency its fill turns solid. `besideWorkspace` is for a
    /// panel in the inspector's column: its shadow stays off the workspace across the gutter.
    func graphiteFloating(cornerRadius: CGFloat = Graphite.Metric.dockRadius, besideWorkspace: Bool = false) -> some View {
        modifier(FloatingSurface(cornerRadius: cornerRadius, isCard: false,
                                 sparedLeadingGap: besideWorkspace ? Graphite.Metric.inspectorGutter : nil))
    }

    /// A card on the workspace, sharing the same borderless floating surface and drop shadow with a
    /// denser fill for forms and settings sections.
    func graphiteCard(cornerRadius: CGFloat = Graphite.Metric.panelRadius) -> some View {
        modifier(FloatingSurface(cornerRadius: cornerRadius, isCard: true))
    }
}

struct FloatingSurface: ViewModifier {
    let cornerRadius: CGFloat
    let isCard: Bool
    var sparedLeadingGap: CGFloat?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The theme's floating colour over the material. A floating surface can sit over a photograph as
    /// bright or as dark as one gets (the dock over a zoomed frame), so its tint is the least that keeps
    /// text and secondary text at 4.5 to 1 there in every theme, through the material as measured over
    /// white and black (`ThemeTests`): One Dark needs 0.85, Catppuccin Latte 0.80. A card sits on the workspace.
    static func tintOpacity(isCard: Bool, isDark: Bool) -> Double {
        isCard ? (isDark ? 0.60 : 0.66) : (isDark ? 0.85 : 0.80)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tintOpacity = Self.tintOpacity(isCard: isCard, isDark: Graphite.isDark)
        content
            .environment(\.isOnGlass, true)
            .background {
                if reduceTransparency {
                    Graphite.floatingOpaque
                } else {
                    ZStack {
                        if isCard {
                            Rectangle().fill(.thinMaterial)
                        } else {
                            Rectangle().fill(.ultraThinMaterial)
                        }
                        Graphite.floatingOpaque.opacity(tintOpacity)
                    }
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .background {
                WorkspaceShadow(cornerRadius: cornerRadius, isDark: Graphite.isDark,
                                fill: Graphite.floatingOpaque, cutoutInterior: !reduceTransparency,
                                sparedLeadingGap: sparedLeadingGap)
            }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Graphite.strongBorder, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Context

/// What the workspace shows, set into the title strip's centre as a window's title is: the roll's
/// name over where it stands ("Sample roll" over "10 of 24 · DSC04059"), with no surface of its own.
/// The second line shortens before it is cut short; the whole of it goes to the help tag and
/// VoiceOver. A drag on it moves the window, as on a title.
struct ContextTitle: View {
    let title: String
    let subtitle: String
    /// A shorter second line for a narrow window, before the whole one is cut short.
    var shortSubtitle: String?
    /// The whole of what the title says, for the help tag and VoiceOver.
    var detail: String?
    /// A symbol after the title, such as the open frame's flag.
    var badge: String?

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(Graphite.Typeface.chipTitle)
                    .foregroundStyle(Graphite.shellText)
                    .truncationMode(.middle)
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Graphite.shellSecondaryText)
                        .accessibilityHidden(true)
                }
            }
            if !subtitle.isEmpty {
                ViewThatFits(in: .horizontal) {
                    subtitleText(subtitle).fixedSize()
                    if let shortSubtitle { subtitleText(shortSubtitle).fixedSize() }
                    subtitleText(shortSubtitle ?? subtitle)
                }
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .help(detail ?? subtitle)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? subtitle)
    }

    /// Its figures roll to the next as the frame or the count changes ("10 of 24" to "11 of 24"); another line, as the
    /// frame view's is to the sheet's, comes on a short fade (`RollingText`).
    private func subtitleText(_ text: String) -> some View {
        RollingText(text: text)
            .font(Graphite.Typeface.caption.monospacedDigit())
            .foregroundStyle(Graphite.shellSecondaryText)
            .truncationMode(.tail)
    }
}

/// A short glass label over a photograph: "Neutral RAW", "Portra 400", "Hold Space to compare".
struct OverlayTag: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium)).accessibilityHidden(true)
            }
            Text(verbatim: text)
        }
        .font(Graphite.Typeface.small)
        .foregroundStyle(Graphite.text)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .graphiteFloating(cornerRadius: 7)
    }
}

// MARK: - Docks

/// A vertical hairline between a dock's groups.
struct DockDivider: View {
    var height: CGFloat = 30

    var body: some View {
        Graphite.hairline.frame(width: 1, height: height).accessibilityHidden(true)
    }
}

/// A horizontal hairline between an inspector's or a panel's sections.
struct SectionDivider: View {
    var body: some View {
        Graphite.hairline.frame(height: 1).frame(maxWidth: .infinity).accessibilityHidden(true)
    }
}

/// A slider and its value, on a panel or card.
struct SliderField<ValueFace: View, Track: View>: View {
    let valueWidth: CGFloat
    @ViewBuilder let value: ValueFace
    @ViewBuilder let slider: Track
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        let border = contrast == .increased ? Graphite.strongBorder : Graphite.border
        HStack(spacing: 0) {
            value.frame(width: valueWidth)
            border.frame(width: 1).accessibilityHidden(true)
            slider.padding(.horizontal, 10)
        }
        .frame(height: Graphite.Metric.controlHeight)
        .background(shape.fill(Graphite.ink(0.05)))
        .overlay { shape.strokeBorder(border, lineWidth: 1) }
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(Graphite.Typeface.pageTitle)
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: subtitle)
                .font(Graphite.Typeface.body.monospacedDigit())
                .foregroundStyle(Graphite.secondaryText)
        }
    }
}

struct PageSectionHeading: View {
    let title: String
    var detail: String?
    var reset: InspectorReset?

    var body: some View {
        HStack(spacing: Graphite.Metric.m) {
            Text(verbatim: title.uppercased())
                .font(Graphite.Typeface.pageSection)
                .tracking(1.4)
                .foregroundStyle(Graphite.tertiaryText)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(verbatim: detail)
                    .font(Graphite.Typeface.caption)
                    .foregroundStyle(Graphite.tertiaryText)
            }
            SectionDivider()
            if let reset, reset.isEnabled {
                Button(action: reset.action) {
                    Text("Reset")
                        .font(Graphite.Typeface.caption)
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InspectorQuietStyle())
                .accessibilityLabel(reset.title)
                .help(reset.help)
            }
        }
    }
}

/// A small tag for the open roll, a new roll, or the version the window shows.
struct Pill: View {
    /// Stops at 0.10 so text stays at least 4.5 to 1 in every theme (`ThemeTests`).
    static let fillInk = 0.10

    let text: String

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(Graphite.Typeface.pill)
            .tracking(0.5)
            .foregroundStyle(Graphite.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Graphite.ink(Self.fillInk), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A symbol and a line of state: "Auto ready", "Saved", "Roll developed".
struct StatusLabel: View {
    let symbol: String
    let text: String
    var isBusy = false
    var emphasis = false
    /// A line beside a title rather than one of its own: the caption's size, its symbol and spinner to match.
    var isCompact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: isCompact ? 4 : 8) {
            // One place for the spinner and the symbol, so the line's words do not move as one gives way to the other.
            ZStack {
                // Each leaves at once: the line's words change with it, and where the label is set against a trailing edge
                // what was fading would be left where the line used to begin.
                if isBusy {
                    ProgressView().controlSize(isCompact ? .mini : .small)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                } else {
                    // The symbol is drawn on as the wait ends, and one symbol gives way to the next in place.
                    Image(systemName: symbol)
                        .font(.system(size: isCompact ? 11 : 15, weight: isCompact ? .regular : .light))
                        .contentTransition(.symbolEffect(.replace))
                        .transition(AsymmetricTransition(insertion: .symbolEffect(.drawOn), removal: .identity))
                }
            }
            .accessibilityHidden(true)
            RollingText(text: text)
                .lineLimit(1)
        }
        .font(emphasis ? Graphite.Typeface.sectionTitle : isCompact ? Graphite.Typeface.caption : Graphite.Typeface.label)
        .foregroundStyle(emphasis ? Graphite.text : Graphite.secondaryText)
        .animation(reduceMotion ? nil : Graphite.Motion.panel, value: isBusy)
        .animation(reduceMotion ? nil : Graphite.Motion.panel, value: symbol)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Menus

/// A pop-up's face, for `Menu` labels: the value and a chevron on a pill of glass, or drawn plainly
/// on a glass surface (`isOnGlass`).
struct MenuFace: View {
    let text: String
    var minWidth: CGFloat?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isOnGlass) private var isOnGlass
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hoverGlide) private var hoverGlide
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        // On a surface with a shared hover highlight the face leaves its hover to that (`HoverGlide`).
        let lifts = isHovered && hoverGlide == nil
        HStack(spacing: 8) {
            Text(verbatim: text)
                .font(Graphite.Typeface.label)
                .lineLimit(1)
                // A value chosen gives way to the next in place.
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Graphite.secondaryText)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Graphite.text)
        .padding(.horizontal, 12)
        .frame(minWidth: minWidth, minHeight: Graphite.Metric.controlHeight)
        .background {
            shape.fill(Graphite.ink(isOnGlass ? (lifts ? 0.09 : 0.05) : (lifts ? 0.04 : 0)))
        }
        .overlay {
            if isOnGlass || contrast == .increased {
                shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
            }
        }
        .glassEffect(isOnGlass ? .identity : Graphite.controlGlass(isEnabled: isEnabled), in: shape)
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.42)
        .onHover { isHovered = $0 }
        .joinsHoverGlide(radius: Graphite.Metric.controlRadius, isJoined: isOnGlass)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: text)
        .fixedSize(horizontal: minWidth == nil, vertical: true)
    }
}

extension View {
    /// A `Menu` drawn by its own label (a `MenuFace`), without the system's bezel or indicator.
    func graphiteMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

// MARK: - Segmented

/// The track's own coordinate space, in which its segments say where they are.
private let segmentedTrackSpace = "segmentedTrack"

/// A segmented choice in the system's shape: a track of glass (drawn plainly on a glass surface)
/// and the chosen segment lifted on it, which goes to the next choice as a drop does (`Drop`) and lifts a little further
/// while the pointer holds the track down. Each segment is a button VoiceOver reads with its selected state; `Equal`
/// widths share the track.
struct GraphiteSegmented<Value: Hashable>: View {
    struct Segment {
        var value: Value
        var title: String
        /// What VoiceOver says for the segment, when the title alone is not enough.
        var accessibilityLabel: String?
        var help: String?
        var isEnabled = true
        var badge: String?
        var symbol: String?
        var showsTitleWithSymbol = false
    }

    @Binding var selection: Value
    let segments: [Segment]
    var size: GraphiteButtonStyle.Size = .small
    /// Every segment as wide as the widest, filling the width offered.
    var fillsWidth = false
    /// The thumb goes under the pointer at a press and follows a drag along the track, and the segment it is on is
    /// chosen when the pointer lets go, as the system's segmented control does. The choice is not made on the way: a
    /// tab passed over would be left again, and leaving a tab can cost what it held (the Masks tab's tool and
    /// selection). Without it a click chooses as it is let go.
    var scrubs = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isOnGlass) private var isOnGlass
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each segment's place in the track, by its index, for the thumb.
    @State private var frames: [Int: CGRect] = [:]
    /// The pointer holds the track down.
    @State private var isHeld = false
    /// The segment a scrub has the thumb on, until the pointer lets go and it is chosen.
    @State private var scrubbed: Int?

    var body: some View {
        let track = RoundedRectangle(cornerRadius: Graphite.Metric.segmentRadius + 2, style: .continuous)
        let selected = segments.firstIndex { $0.value == selection }
        // Where the thumb is: on the choice, or during a scrub on the segment under the pointer.
        let thumbed = scrubbed ?? selected
        HStack(spacing: 2) {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                // Until its place is known a chosen segment draws the thumb itself, so the control never shows without one.
                SegmentButton(title: segment.title, badge: segment.badge, symbol: segment.symbol, showsTitleWithSymbol: segment.showsTitleWithSymbol, isSelected: index == thumbed, drawsThumb: frames[index] == nil,
                              height: height, fillsWidth: fillsWidth) { choose(segment) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(segmentedTrackSpace)) } action: { frames[index] = $0 }
                    .disabled(!segment.isEnabled)
                    .help(segment.help ?? "")
                    .accessibilityLabel(segment.accessibilityLabel ?? segment.title)
                    .accessibilityAddTraits(index == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(alignment: .topLeading) {
            if let thumbed, let frame = frames[thumbed] {
                thumb(on: thumbed, at: frame)
            }
        }
        .background(track.fill(Graphite.ink(isOnGlass ? 0.05 : 0)))
        .overlay {
            if isOnGlass || contrast == .increased {
                track.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
            }
        }
        .glassEffect(isOnGlass ? .identity : .regular, in: track)
        .simultaneousGesture(hold, isEnabled: isEnabled)
        .coordinateSpace(.named(segmentedTrackSpace))
        .accessibilityElement(children: .contain)
    }

    /// The chosen segment lifted on the track. On its way to the next choice it is longer and a little thinner, and
    /// under the pointer's hold it lifts: larger, lighter and with more shadow under it.
    private func thumb(on index: Int, at frame: CGRect) -> some View {
        let lifted = isHeld && !reduceMotion
        return Drop(id: index, span: Span(start: frame.minX, end: frame.maxX)) { span in
            RoundedRectangle(cornerRadius: Graphite.Metric.segmentRadius, style: .continuous)
                .fill(Graphite.segmentThumb)
                .overlay {
                    RoundedRectangle(cornerRadius: Graphite.Metric.segmentRadius, style: .continuous)
                        .fill(Graphite.ink(lifted ? 0.07 : 0))
                }
                .shadow(color: Color.black.opacity(0.22), radius: lifted ? 5 : 1.5, y: lifted ? 2 : 0.5)
                .frame(width: max(0, span.length), height: frame.height)
                .scaleEffect(x: lifted ? 1.04 : 1, y: (1 - 0.22 * span.stretch(from: frame.width)) * (lifted ? 1.1 : 1))
                .animation(reduceMotion ? nil : (lifted ? Graphite.Motion.grab : Graphite.Motion.release), value: lifted)
                .offset(x: span.start, y: frame.minY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The pointer on the track: the thumb lifts while it is down, and where the control scrubs it goes to the segment
    /// under the pointer, at the press and as it moves, which is chosen when the pointer lets go. Beside the segments'
    /// own buttons, which the keyboard and VoiceOver press.
    private var hold: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(segmentedTrackSpace))
            .onChanged { value in
                if !isHeld { isHeld = true }
                guard scrubs, let index = segment(at: value.location.x), segments[index].isEnabled else { return }
                if scrubbed != index { scrubbed = index }
            }
            .onEnded { _ in
                isHeld = false
                guard let index = scrubbed else { return }
                scrubbed = nil
                if segments.indices.contains(index) { choose(segments[index]) }
            }
    }

    /// The segment at `x` along the track; past either end, the one at that end.
    private func segment(at x: CGFloat) -> Int? {
        let placed = segments.indices.compactMap { index in frames[index].map { (index, $0) } }
        if let within = placed.first(where: { x >= $0.1.minX - 1 && x <= $0.1.maxX + 1 }) { return within.0 }
        guard let first = placed.min(by: { $0.1.minX < $1.1.minX }), let last = placed.max(by: { $0.1.maxX < $1.1.maxX }) else { return nil }
        return x < first.1.minX ? first.0 : x > last.1.maxX ? last.0 : nil
    }

    private func choose(_ segment: Segment) {
        guard segment.value != selection else { return }
        if reduceMotion {
            selection = segment.value
        } else {
            withAnimation(Graphite.Motion.quick) { selection = segment.value }
        }
    }

    private var height: CGFloat {
        switch size {
        case .small: 24
        case .regular: 28
        case .large: 34
        }
    }
}

private struct SegmentButton: View {
    let title: String
    let badge: String?
    let symbol: String?
    let showsTitleWithSymbol: Bool
    let isSelected: Bool
    /// The thumb under a chosen segment, until the track knows where its segments are and draws the one that travels.
    let drawsThumb: Bool
    let height: CGFloat
    let fillsWidth: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.segmentRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 16)
                }
                if symbol == nil || showsTitleWithSymbol {
                    Text(verbatim: title)
                        .font(height > 30 ? Graphite.Typeface.body : Graphite.Typeface.label)
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                if let badge {
                    Text(verbatim: badge)
                        .font(Graphite.Typeface.caption.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Graphite.ink(0.08)))
                        .accessibilityHidden(true)
                }
            }
                .foregroundStyle(isSelected ? Graphite.text : isHovered ? Graphite.text : Graphite.secondaryText)
                .padding(.horizontal, symbol != nil ? 7 : (fillsWidth ? 8 : 14))
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: height)
                .background {
                    if isSelected, drawsThumb {
                        shape.fill(Graphite.segmentThumb)
                            .shadow(color: Color.black.opacity(0.22), radius: 1.5, y: 0.5)
                    } else {
                        shape.fill(Graphite.hoverFill).opacity(isHovered && !isSelected ? 1 : 0)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.42)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isSelected)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: title)
    }
}

// MARK: - Panels

/// A thin cross, for a panel, a page or a dock.
struct CloseButton: View {
    var help = "Close"
    var bordered = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .light))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.graphite(bordered ? .icon : .quiet, size: .small))
        .help(help)
        .accessibilityLabel(help)
    }
}
