import SwiftUI

/// The rail's own coordinate space, in which its items say where they are.
private let appRailSpace = "appRail"

/// The rail: symbols set into the window's chrome down its leading column, centred on the workspace,
/// in stable groups: Rolls; Roll and Frame, the two views of a roll; Stock and Adjust, the two
/// tools; Develop; and Settings. Roll and Frame show where you are, Stock and Adjust whether their tool
/// is open, Rolls, Develop and Settings whether their page fills the workspace. Away from its page
/// Develop also says how a develop stands: a ring filling as one runs, and a dot once one has stopped
/// or left frames behind. Each item is the menu
/// command it repeats; its name and key are in its help tag and VoiceOver reads the name. The
/// column has no surface of its own: the chosen items sit on small lenses of Liquid Glass, the only
/// glass in it. The column's empty room moves the window, as a title bar does.
///
/// Where you are has one lens, which goes from one page's item to the next as a drop does (`Drop`), longer and a little
/// thinner on the way; Stock's and Adjust's lenses grow in under their items as their tools open. The light fill under
/// the pointer is one too, going from item to item (`HoverGlide`), and whatever an item sits on dips while it is pressed.
struct AppRail: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where each item is in the column, for the lens.
    @State private var frames: [RailPlace: CGRect] = [:]
    /// The item the pointer holds down.
    @State private var pressed: RailPlace?

    var body: some View {
        let page = model.workspacePage
        let here = RailPlace.page(page, isFrameOpen: model.isFrameOpen)
        VStack(spacing: 2) {
            item(.rolls, title: "Rolls", symbol: "film.stack", isSelected: here == .rolls,
                 help: "Rolls: every roll Argent keeps, and Import roll. Command-I imports a card or a folder.",
                 progress: page == .rolls ? nil : model.importFraction) {
                model.showWorkspacePage(.rolls)
            }
            RailSeparator()
            item(.roll, title: "Roll", symbol: "square.grid.2x2", isSelected: here == .roll,
                 help: "Roll: the roll as a contact sheet. Command-Up Arrow.") {
                model.showRoll()
            }
            .disabled(model.roll == nil || page == .importReview)
            item(.frame, title: "Frame", symbol: "photo", isSelected: here == .frame,
                 help: "Frame: the selected frame at the size of the window. Command-Down Arrow.") {
                model.showFrame()
            }
            .disabled(model.roll == nil || page == .importReview || (!model.isFrameOpen && !model.canOpenFrame && page == .roll))
            RailSeparator()
            item(.stock, title: "Stock", symbol: "square.3.layers.3d", isSelected: model.isStockPanelShown && page == .roll,
                 help: "Stock: the roll's film stock, and its Rated at, Lab balance and Grain. Keys 1 to 6 switch stocks.") {
                model.toggleStockPanel()
            }
            .disabled(model.roll == nil || page == .importReview || model.stockNames.isEmpty)
            item(.adjust, title: "Adjust", symbol: "slider.horizontal.3",
                 isSelected: model.isAdjustmentsShown && model.isFrameOpen && page == .roll,
                 help: "Adjust: this frame's Light, Curve, Masks and Lens. Shift-Command-A.") {
                model.toggleAdjust()
            }
            .disabled(model.roll == nil || page == .importReview || (!model.isFrameOpen && !model.canOpenFrame))
            RailSeparator()
            item(.develop, title: "Develop", symbol: "square.and.arrow.up", isSelected: here == .develop,
                 help: "Develop: the frames to develop, where their files go and as what, and the Develop button. Command-D.",
                 progress: page == .develop ? nil : model.developFraction,
                 wantsAttention: page != .develop && model.developWantsAttention) {
                model.toggleDevelopPage()
            }
            .disabled(model.roll == nil || page == .importReview)
            RailSeparator()
            item(.settings, title: "Settings", symbol: "gearshape", isSelected: here == .settings,
                 help: "Settings: appearance and develop memory. Command-Comma.") {
                model.showWorkspacePage(page == .settings ? .roll : .settings)
            }
        }
        // Over the hover's fill and under the items: the lens of where you are.
        .background(alignment: .topLeading) {
            if let frame = frames[here] { lens(on: here, at: frame) }
        }
        .hoverGlide(axis: .vertical, ink: 0.06, depth: 0.88)
        .coordinateSpace(.named(appRailSpace))
        .frame(width: Graphite.Metric.railWidth)
        // Centred on the workspace, which stops the bottom inset short of the window's edge.
        .frame(maxHeight: .infinity)
        .padding(.bottom, Graphite.Metric.workspaceInset)
        .background {
            // The column's own background moves the window; the rail's items take their clicks first.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }

    private func item(_ place: RailPlace, title: String, symbol: String, isSelected: Bool, help: String, progress: Double? = nil,
                      wantsAttention: Bool = false, action: @escaping () -> Void) -> some View {
        RailItem(title: title, symbol: symbol, isSelected: isSelected, growsLens: !place.isPage, help: help, progress: progress,
                 wantsAttention: wantsAttention, pressed: { isDown in
                     if isDown { pressed = place } else if pressed == place { pressed = nil }
                 }, action: action)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(appRailSpace)) } action: { frames[place] = $0 }
    }

    /// The lens of where you are, on the item at `frame`.
    private func lens(on place: RailPlace, at frame: CGRect) -> some View {
        let isPressed = pressed == place && !reduceMotion
        return Drop(id: place, span: Span(start: frame.minY, end: frame.maxY)) { span in
            RailLens()
                .frame(width: frame.width * (1 - 0.16 * span.stretch(from: frame.height)), height: max(0, span.length))
                .scaleEffect(isPressed ? 0.88 : 1)
                .animation(reduceMotion ? nil : (isPressed ? Graphite.Motion.press : Graphite.Motion.release), value: isPressed)
                .frame(width: frame.width)
                .offset(x: frame.minX, y: span.start)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The rail's items, by what they stand for. Five are pages, of which the workspace shows one, and share the lens that
/// travels; Stock and Adjust are tools, open or not beside any of them.
enum RailPlace: Hashable, Sendable {
    case rolls, roll, frame, stock, adjust, develop, settings

    var isPage: Bool { self != .stock && self != .adjust }

    /// The item that says where the workspace is.
    static func page(_ page: WorkspacePage, isFrameOpen: Bool) -> RailPlace {
        switch page {
        case .rolls, .importReview: .rolls
        case .roll: isFrameOpen ? .frame : .roll
        case .develop: .develop
        case .settings: .settings
        }
    }
}

/// A lens of Liquid Glass under a chosen rail item.
private struct RailLens: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.railItemRadius, style: .continuous)
        Color.clear.glassEffect(.regular, in: shape)
    }
}

/// A hairline between the rail's groups.
private struct RailSeparator: View {
    var body: some View {
        Graphite.hairline
            .frame(width: 20, height: 1)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }
}

/// One rail item: a fine line symbol. A page's item leaves its lens to the rail, whose one lens travels; a tool's own
/// grows in under it while the tool is open (`growsLens`). The fill under the pointer is the rail's too.
private struct RailItem: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let growsLens: Bool
    let help: String
    /// How far the work behind the item is, drawn as a ring round its symbol; `nil` with none under way.
    var progress: Double?
    /// A dot at the item's corner: something on its page waits to be seen.
    var wantsAttention = false
    /// The pointer went down on the item, or let it go.
    let pressed: (Bool) -> Void
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                // Inside its ring the symbol steps down a size, so the two do not touch.
                .font(.system(size: progress == nil ? Graphite.Metric.railIcon : Graphite.Metric.railIcon - 4, weight: .light))
                .foregroundStyle(isSelected || isHovered && isEnabled ? Graphite.shellText : Graphite.shellSecondaryText)
                .frame(width: Graphite.Metric.railItem, height: Graphite.Metric.railItem)
                .overlay {
                    if let progress {
                        ZStack {
                            Circle().stroke(Graphite.ink(0.16), lineWidth: 1.5)
                            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                                .stroke(Graphite.primaryTop, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(reduceMotion ? nil : Motion.stateChange, value: progress)
                        }
                        .padding(5)
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if wantsAttention {
                        Circle().fill(Graphite.shellText)
                            .frame(width: 7, height: 7)
                            .overlay { Circle().stroke(lineWidth: 2).padding(-1).blendMode(.destinationOut) }
                            .padding(5)
                            .allowsHitTesting(false)
                            .transition(.lands)
                    }
                }
                .compositingGroup()
                .contentShape(RoundedRectangle(cornerRadius: Graphite.Metric.railItemRadius, style: .continuous))
        }
        .buttonStyle(RailItemStyle(showsLens: growsLens && isSelected, isJoined: !isSelected, pressed: pressed))
        .opacity(isEnabled ? 1 : 0.38)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isSelected)
        .animation(reduceMotion ? nil : Graphite.Motion.land, value: wantsAttention)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent" } ?? (wantsAttention ? "Needs attention" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A rail item under the pointer's press: its symbol dips with whatever it sits on, and comes back up past its rest.
private struct RailItemStyle: ButtonStyle {
    /// A tool's own lens, under its symbol while the tool is open.
    let showsLens: Bool
    /// Whether the rail's hover fill comes to it; not to a chosen item, which has its lens.
    let isJoined: Bool
    let pressed: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration, style: self)
    }

    private struct Pressable: View {
        let configuration: ButtonStyle.Configuration
        let style: RailItemStyle
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background {
                    if style.showsLens {
                        RailLens().transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : Graphite.Motion.swell, value: style.showsLens)
                .pressSpring(configuration.isPressed, depth: 0.88)
                .joinsHoverGlide(radius: Graphite.Metric.railItemRadius, isPressed: configuration.isPressed, isJoined: style.isJoined)
                .onChange(of: configuration.isPressed) { _, isDown in style.pressed(isDown) }
        }
    }
}
