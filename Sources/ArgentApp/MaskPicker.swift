import ArgentCore
import ArgentRoll
import SwiftUI

/// What the picker offers: a place to start a mask. Three that are drawn on the photograph, and four that are found in it.
enum MaskTile: String, CaseIterable, Sendable {
    case brush, linear, radial, subject, sky, person, background

    /// The tiles under Draw, which put a tool in hand, and under Find, which make a mask at a click. The seven in two groups
    /// by what the photographer does next, where a grid of six left the seventh under "More:".
    static let draw: [MaskTile] = [.brush, .linear, .radial]
    static let find: [MaskTile] = [.subject, .sky, .person, .background]

    var title: String {
        switch self {
        case .brush: "Brush"
        case .linear: "Linear"
        case .radial: "Radial"
        case .subject: "Subject"
        case .sky: "Sky"
        case .person: "Person"
        case .background: "Background"
        }
    }

    /// SF Symbols at light weight, as everywhere in the app.
    var symbol: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .linear: "square.bottomhalf.filled"
        case .radial: "circle.circle"
        case .subject: "figure.stand"
        case .sky: "cloud"
        case .person: "person"
        case .background: "photo"
        }
    }

    /// The tool it puts in hand: the brush and the gradients. The smart tiles make a mask at once instead (`smartKind`).
    var tool: MaskEditor.Tool? {
        switch self {
        case .brush: .brush
        case .linear: .linear
        case .radial: .radial
        case .subject, .sky, .person, .background: nil
        }
    }

    /// The selection a smart tile makes with one click.
    var smartKind: SmartKind? {
        switch self {
        case .sky: .sky
        case .subject: .subject
        case .person: .person
        case .background: .background
        case .brush, .linear, .radial: nil
        }
    }

    private var key: MaskKey? {
        switch self {
        case .brush: MaskKeys.newBrush
        case .linear: MaskKeys.newLinear
        case .radial: MaskKeys.newRadial
        case .subject, .sky, .person, .background: nil
        }
    }

    /// What VoiceOver says, the tile being a button that adds a mask.
    var accessibilityLabel: String {
        switch self {
        case .linear: "Add linear gradient mask"
        case .radial: "Add radial gradient mask"
        default: "Add \(title.lowercased()) mask"
        }
    }

    /// The help tag: what it makes, with its key where it has one; on a tile that cannot be used, why.
    func help(preparing: String?) -> String {
        if let preparing { return preparing }
        let does = switch self {
        case .brush: "Paint a mask."
        case .linear: "Draw a linear gradient."
        case .radial: "Draw a radial gradient."
        case .subject: "Find the subject and mask it."
        case .sky: "Find the sky and mask it."
        case .person: "Find the people and mask them."
        case .background: "Find the background and mask it."
        }
        return key?.chord.map { "\(does) \($0.words)." } ?? does
    }
}

/// Whether a tile can be used now, and if not, why: a tile that cannot is dimmed and says why on hover, so a tile that works and
/// one that does not are never mistaken for each other (the owner, Phase 1). Pure, so `SmartMaskStateTests` holds the table.
enum MaskTileAvailability: Equatable, Sendable {
    case live
    /// This frame cannot take a mask yet, or at all: why, as the picker says it under the tiles.
    case waiting(String)
    /// Not in this build or on this Mac.
    case unavailable(String)

    var isLive: Bool { self == .live }

    /// Why it cannot be used, for the help tag and VoiceOver.
    var reason: String? {
        switch self {
        case .live: nil
        case .waiting(let why), .unavailable(let why): why
        }
    }

    /// `tile`'s availability: what the build can do comes first (a smart tile's kind, `smart`), then whether this frame can take
    /// a mask (`frame`, nil when it can). The gradients and the brush need nothing but the frame.
    static func of(_ tile: MaskTile, frame: String?, smart: SmartAvailability?) -> MaskTileAvailability {
        if tile.smartKind != nil, let why = (smart ?? .unavailable("Smart masks are not available.")).reason { return .unavailable(why) }
        if let frame { return .waiting(frame) }
        return .live
    }
}

/// The tab's words for the state of a frame's masks. Pure, so `AdjustInspectorStateTests` holds them.
enum MaskCopy {
    /// Under the tiles of a frame whose compiler cannot take a mask (`MaskCompilerGate.needsUpdate`).
    static let needsUpdate = "Update Automatic Baseline to add masks to this older edit."
    static let isFull = "A frame holds \(MaskSet.maximumMasks) masks at most."

    /// The pending row's words, until the first stroke makes the mask or the component.
    static let brushPending = "Ready to paint"

    /// The tile under the pointer's chosen look: its tool is in hand, for a new mask.
    static func isChosen(_ tile: MaskTile, tool: MaskEditor.Tool?, operation: MaskOperation?) -> Bool {
        tile.tool != nil && tile.tool == tool && operation == nil
    }
}

/// What starts a mask: the seven tiles in two groups, Draw and Find, by what the photographer does next. A Draw tile puts its
/// tool in hand, and the first drag on the photograph makes the mask, with no OK; a Find tile makes its mask at the click. On a
/// frame with no mask they are the tab; on one with masks they are in Add's popover (`MasksInspector`), so opening them moves
/// nothing in the tab. The two headings name the groups and say nothing of how a tool works: the tab carries no how-to text
/// (the owner, 2026-11-07). A mask is a first edit: while the frame cannot be adjusted the tiles stay disabled and say what
/// they wait for.
struct MaskPicker: View {
    let frame: Frame
    @Environment(RollModel.self) private var model

    /// Between two tiles.
    private static let gap: CGFloat = 6

    var body: some View {
        let preparing = model.adjustPreparation(for: frame), canAdd = model.canAddMask(frame)
        let waiting = canAdd ? nil : preparing ?? frameReason
        VStack(alignment: .leading, spacing: 0) {
            InspectorSectionHeader(title: "Draw")
                .padding(.bottom, AdjustRowMetric.rowSpacing)
            // Three across, each its symbol over its word.
            HStack(spacing: Self.gap) {
                ForEach(MaskTile.draw, id: \.self) { tile in
                    button(tile, waiting: waiting) {
                        VStack(spacing: Graphite.Metric.xs) {
                            Image(systemName: tile.symbol)
                                .font(.system(size: Graphite.Metric.railIcon, weight: .light))
                                .frame(height: 20)
                                .accessibilityHidden(true)
                            Text(verbatim: tile.title)
                                .font(Graphite.Typeface.small)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                    }
                }
            }
            InspectorSectionHeader(title: "Find")
                .padding(.top, Graphite.Metric.m)
                .padding(.bottom, AdjustRowMetric.rowSpacing)
            // Two across, each its symbol beside its word, so the longest, Background, has its room.
            VStack(spacing: Self.gap) {
                ForEach(0..<(MaskTile.find.count + 1) / 2, id: \.self) { row in
                    HStack(spacing: Self.gap) {
                        ForEach(MaskTile.find.dropFirst(row * 2).prefix(2), id: \.self) { tile in
                            button(tile, waiting: waiting) {
                                HStack(spacing: 6) {
                                    Image(systemName: tile.symbol)
                                        .font(.system(size: 13, weight: .light))
                                        .frame(width: 18)
                                        .accessibilityHidden(true)
                                    Text(verbatim: tile.title)
                                        .font(Graphite.Typeface.small)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                .padding(.horizontal, Graphite.Metric.s)
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            }
                        }
                    }
                }
            }
            if let preparing {
                StatusLabel(symbol: "hourglass", text: preparing, isBusy: true, isCompact: true)
                    .padding(.top, Graphite.Metric.m)
            } else if model.masks(for: frame).count >= MaskSet.maximumMasks {
                // Why every tile is dimmed, where the tiles are: a frame with all its masks has them in Add's popover.
                Text(verbatim: MaskCopy.isFull)
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Graphite.Metric.m)
            }
        }
    }

    /// Why no tile can start a mask on this frame, when it is not that the frame is still getting ready.
    private var frameReason: String {
        if model.maskCompilerGate(for: frame) == .needsUpdate { return MaskCopy.needsUpdate }
        if model.masks(for: frame).count >= MaskSet.maximumMasks { return MaskCopy.isFull }
        return model.manualIssue(for: frame) ?? "This frame cannot be adjusted now."
    }

    private func button(_ tile: MaskTile, waiting: String?, @ViewBuilder label: () -> some View) -> some View {
        let editor = model.maskEditor
        let availability = MaskTileAvailability.of(tile, frame: waiting, smart: tile.smartKind.map(model.smartAvailability))
        return Button {
            if let tool = tile.tool { model.perform(.newMask(tool)) }
            if let kind = tile.smartKind { model.addSmartMask(kind, for: frame) }
        } label: { label() }
            .buttonStyle(MaskTileStyle(isChosen: MaskCopy.isChosen(tile, tool: editor.tool, operation: editor.pendingOperation)))
            .disabled(!availability.isLive)
            // Why it cannot be used, on hover, in place of what it does.
            .help(availability.reason ?? tile.help(preparing: nil))
            .accessibilityLabel(tile.accessibilityLabel)
            .accessibilityValue(availability.reason ?? "")
            .accessibilityAddTraits(MaskCopy.isChosen(tile, tool: editor.tool, operation: editor.pendingOperation) ? .isSelected : [])
    }
}

/// A tile on the inspector's glass, drawn plainly: no glass on glass. The tile whose tool is in hand wears the selection's 2-point
/// ring. A tile that cannot be used is dimmed so it reads as such at a glance, where the owner could not tell which worked when it
/// differed only by its text's shade: no fill, a dashed edge, and its words and symbol in the tertiary text, which still reads at
/// 4.5 to 1, so a grid dimmed together while the frame gets ready can be read. `ThemeTests` holds both to 4.5 to 1 in every theme.
struct MaskTileStyle: ButtonStyle {
    /// The ink over the glass at rest, hovered and pressed. Pressed stops short of a secondary button's
    /// 0.13 on glass, under which two themes' text falls below 4.5 to 1 (Middle gray Dark, One Dark).
    static let restInk = 0.05, hoverInk = 0.08, pressedInk = 0.10
    /// A tile that cannot be used: no fill, so its words sit on the glass itself.
    static let disabledInk = 0.0
    /// Its dashed edge: dashes of 3 points with gaps of 3.
    static let disabledDash: [CGFloat] = [3, 3]

    var isChosen = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, isChosen: isChosen)
    }

    private struct Face: View {
        let configuration: Configuration
        let isChosen: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isEnabled ? Graphite.text : Graphite.tertiaryText)
                .background {
                    shape.fill(Graphite.ink(!isEnabled ? disabledInk : configuration.isPressed ? pressedInk : isHovered ? hoverInk : restInk))
                }
                .overlay {
                    if isChosen {
                        shape.strokeBorder(Graphite.selection, lineWidth: Graphite.Metric.selectionWidth)
                    } else if !isEnabled {
                        shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border,
                                           style: StrokeStyle(lineWidth: 1, dash: disabledDash))
                    } else {
                        shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
                    }
                }
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
        }
    }
}
