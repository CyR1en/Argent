import ArgentRoll
import SwiftUI

/// The strip across the window's top, one centre line: the window's buttons with "Argent" pinned
/// beside them, what the workspace shows set into the centre as a window's title is
/// (`ContextTitle`), and at the trailing end the view's actions, ending on the workspace's content
/// edge as the docks below do; over the inspector the actions keep to the window's end. Without a
/// roll in the workspace (Open roll, Settings) it holds "Argent" alone. Its empty room moves the
/// window. A card under review has its own (`ImportTopBar`).
struct TitleStrip: View {
    /// The dock under the sheet says whether Auto is ready, so the title need not.
    var dockShowsAuto = false
    @Environment(RollModel.self) private var model

    var body: some View {
        Group {
            if model.onboarding.isPresented {
                TitleStripLayout { Wordmark() }
            } else if model.workspacePage == .roll || model.workspacePage == .develop, model.roll != nil {
                WorkspaceTopBar(dockShowsAuto: dockShowsAuto)
            } else if model.workspacePage == .importReview {
                ImportTopBar()
            } else {
                TitleStripLayout { Wordmark() }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Graphite.Metric.titleStripHeight)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }
}

/// "Argent", beside the window's buttons on every page.
struct Wordmark: View {
    var body: some View {
        Text("Argent")
            .font(Graphite.Typeface.wordmark)
            .foregroundStyle(Graphite.shellText)
            .accessibilityAddTraits(.isHeader)
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// The title strip's parts across the window: "Argent" from `Graphite.Metric.titleStripLeading`, the
/// actions ending on the workspace's content edge, and between them the context centred in the
/// window, as a window's title is, while it clears both ends (the actions may be absent); else moved over to the room between
/// them, and cut short when even that is too narrow. Its ideal width is what the centred title needs,
/// so a `ViewThatFits` around it gives up the actions' titles before the title moves.
struct TitleStripLayout: Layout {
    var leading = Graphite.Metric.titleStripLeading
    var trailing = Graphite.Metric.workspaceInset + Graphite.Metric.edge
    var spacing = Graphite.Metric.l

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = ideal.map(\.height).max() ?? 0
        let lead = ideal.first?.width ?? 0
        let trail = subviews.count > 2 ? ideal[2].width : 0
        let center = subviews.count > 1 ? ideal[1].width : 0
        let side = max(leading + lead, trailing + trail) + spacing
        return CGSize(width: proposal.width ?? (2 * side + center), height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let lead = first.sizeThatFits(.unspecified)
        first.place(at: CGPoint(x: bounds.minX + leading, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(lead))
        var roomMax = bounds.maxX - trailing
        if subviews.count > 2 {
            let trail = subviews[2].sizeThatFits(.unspecified)
            subviews[2].place(at: CGPoint(x: roomMax, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trail))
            roomMax -= trail.width + spacing
        }
        guard subviews.count > 1 else { return }
        let roomMin = bounds.minX + leading + lead.width + spacing
        let room = max(0, roomMax - roomMin)
        let center = subviews[1].sizeThatFits(ProposedViewSize(width: room, height: bounds.height))
        let width = min(center.width, room)
        let x = min(max(bounds.midX - width / 2, roomMin), roomMax - width)
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: center.height))
    }
}

/// The roll's title strip: "Argent", what the workspace shows centred, and at the trailing end the
/// view's one action: Open frame on the contact sheet, Compare in the frame view. The Develop page has
/// none there: its one action is the button at the foot of its panel (`DevelopPageButton`).
struct WorkspaceTopBar: View {
    /// The dock under the sheet says whether Auto is ready, so the title need not.
    var dockShowsAuto = false
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The secondary action gives up its title for its symbol before the title moves off the
        // centre or shortens, as in a small window. One container renders the strip's glass together.
        GlassEffectContainer(spacing: Graphite.Metric.xs) {
            ViewThatFits(in: .horizontal) {
                strip(compact: false)
                strip(compact: true)
            }
        }
    }

    private func strip(compact: Bool) -> some View {
        let context = Self.context(model, dockShowsAuto: dockShowsAuto)
        return TitleStripLayout {
            Wordmark()
            ContextTitle(title: context.title, subtitle: context.subtitle, shortSubtitle: context.shortSubtitle,
                         detail: context.detail, badge: context.badge)
            if model.workspacePage == .roll {
                RollActionButton(compact: compact)
                    .fixedSize()
            }
        }
        // The action's glass takes its next title's width, and the title's lines move to their new middle with it.
        .animation(reduceMotion ? nil : Graphite.Motion.reshape, value: model.isFrameOpen)
    }

    /// The title's lines: the roll's name, over how many of its frames show and, unless the dock
    /// under the sheet says it (`dockShowsAuto`), whether Auto is ready; in the frame view, where
    /// the frame is among those shown, its file name, "Neutral RAW" while the neutral raw shows, whether the frame was not developed, is edited or has its
    /// own Rated at or Lab balance, and whether it is flagged. The whole line
    /// (`RollHeading.subtitle`, with the exposure) is its detail, for the help tag and VoiceOver.
    static func context(_ model: RollModel, dockShowsAuto: Bool = false)
        -> (title: String, subtitle: String, shortSubtitle: String?, detail: String, badge: String?) {
        guard let roll = model.roll else { return ("Argent", "", nil, "", nil) }
        let detail = RollHeading.subtitle(model)
        if model.isFrameOpen, let frame = model.selectedFrame {
            var parts = [model.shownPosition(of: frame), frame.name]
            if model.isNeutralShown { parts.append("Neutral RAW") }
            // What sets this frame apart from the roll, as the heading said before the title strip.
            if !model.isDeveloping, model.lastDevelop?.failure(for: frame.url) != nil { parts.append("Not developed") }
            if model.hasManualAdjustments(frame) { parts.append("Edited") } else if model.isOverridden(frame) { parts.append("Own settings") }
            // In words on the frame's line, not as a badge by the roll's name, which would flag the roll.
            if model.isFlagged(frame) { parts.append("Flagged") }
            // Narrow, the frame's name and state keep their room before its place in the roll does.
            return (roll.name, parts.joined(separator: " · "), parts.dropFirst().joined(separator: " · "),
                    "\(frame.name), \(detail)", nil)
        }
        var parts = [model.shownCountText]
        if !dockShowsAuto, let auto = AutoStatusLabel.text(model) { parts.append(auto) }
        return (roll.name, parts.joined(separator: " · "), nil, detail, nil)
    }
}

/// The roll's one action in the title strip: on the contact sheet Open frame, the selected frame at the size of the
/// window; in the frame view Compare, the split comparison of the neutral raw and film, which without stocks has no film
/// and no neutral raw to set beside it. One button for both, so its glass keeps its place between the two views and
/// takes the next title's width, while the titles give way to each other (`ReshapingTitle`).
private struct RollActionButton: View {
    /// The symbol alone, in a narrow workspace.
    var compact = false
    @Environment(RollModel.self) private var model

    var body: some View {
        let compares = model.isFrameOpen
        Button {
            if compares { model.isSplitComparing.toggle() } else { model.showFrame() }
        } label: {
            Label {
                ReshapingTitle(text: compares ? "Compare" : "Open frame")
            } icon: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .labelStyle(GraphiteActionLabelStyle(iconOnly: compact))
            .foregroundStyle(Graphite.shellText)
        }
        .buttonStyle(.graphite(compact ? .icon : .secondary, isOn: compares && model.isSplitComparing))
        .disabled(compares ? model.films == nil : !model.canOpenFrame)
        .help(compares ? "Compare the neutral RAW and film side by side, split by a divider you drag. Shift-Command-C. Hold Space for the whole neutral RAW."
              : "Open the selected frame. Return or Command-Down Arrow.")
        .accessibilityLabel(compares ? "Split compare" : "Open frame")
        .accessibilityValue(compares ? (model.isSplitComparing ? "On" : "Off") : "")
    }
}

/// A symbol and a title on an action, 8 points apart.
struct GraphiteActionLabelStyle: LabelStyle {
    /// The symbol alone; the title stays the button's accessibility label.
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 14, weight: .light))
            if !iconOnly { configuration.title }
        }
    }
}

/// Whether the roll's Auto has settled: "Auto ready", or "Balancing roll…" with a spinner while the
/// frames are measured and the roll decides; nothing before a roll or without stocks.
struct AutoStatusLabel: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        if let text = Self.text(model) {
            StatusLabel(symbol: "checkmark.circle", text: text, isBusy: model.isBalancing && !model.isDeveloping)
                .help(model.isBalanced ? "Auto has measured every frame and settled the roll's exposure and lab balance."
                      : "Auto is measuring the frames and balancing the roll.")
                // Shown in a dock, so the title strip leaves it out.
                .preference(key: ShowsAutoStatus.self, value: true)
        }
    }

    static func text(_ model: RollModel) -> String? {
        guard model.roll != nil, model.films != nil else { return nil }
        if model.isBalanced { return "Auto ready" }
        if model.isBalancing { return "Balancing roll…" }
        return nil
    }
}

/// Whether a dock shows `AutoStatusLabel`: the docks drop it first when short of room, and the
/// title strip says it only then, so the state is said once.
struct ShowsAutoStatus: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
