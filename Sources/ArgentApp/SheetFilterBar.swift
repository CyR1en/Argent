import SwiftUI

/// The contact sheet's second row, under the top bar: which frames show (All, Flagged, Unflagged,
/// each with its live count), which is also which frames Develop develops, and at its trailing end
/// the thumbnails' size, small to large, in the steps View > Larger and Smaller Thumbnails and a
/// pinch take. Short of room, as on the Develop page beside its panel in a narrow window, it gives up
/// the size control, which the View menu, its keys and a pinch still are, before it would hold the
/// workspace wider than the window has room for.
struct SheetFilterBar: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsSize: true)
            row(showsSize: false)
        }
    }

    private func row(showsSize: Bool) -> some View {
        let total = model.roll?.frames.count ?? 0
        let flagged = model.flaggedCount
        return HStack(spacing: Graphite.Metric.m) {
            GraphiteSegmented(selection: Binding(get: { model.flagFilter }, set: { model.showFrames($0) }),
                              segments: FlagFilter.allCases.map { filter in
                                  .init(value: filter, title: Self.title(filter, total: total, flagged: flagged),
                                        accessibilityLabel: Self.accessibilityLabel(filter, total: total, flagged: flagged),
                                        help: Self.help(filter))
                              },
                              size: .regular)
                .disabled(!model.canChangeFilter)
                .fixedSize()
                .accessibilityLabel("Show")
            Spacer(minLength: Graphite.Metric.m)
            GraySurroundToggle()
            if showsSize { ThumbnailSizeControl() }
        }
        .padding(.horizontal, Graphite.Metric.edge)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(height: Self.height)
    }

    /// The row's height, its control and the room above and under it; the notices on the sheet
    /// start under it (`NoticeStack`).
    static let height: CGFloat = 14 + 32 + 8

    /// How many of the roll's `total` frames `filter` shows, `flagged` of them being flagged.
    static func count(_ filter: FlagFilter, total: Int, flagged: Int) -> Int {
        switch filter {
        case .all: total
        case .flagged: flagged
        case .unflagged: max(0, total - flagged)
        }
    }

    /// The segment's title with its count, in a short form: "All 24", "Flagged 3",
    /// "Unflagged 21".
    static func title(_ filter: FlagFilter, total: Int, flagged: Int) -> String {
        "\(name(filter)) \(count(filter, total: total, flagged: flagged))"
    }

    /// What VoiceOver says for the segment: "Flagged, 3 frames", "All, 1 frame".
    static func accessibilityLabel(_ filter: FlagFilter, total: Int, flagged: Int) -> String {
        let count = count(filter, total: total, flagged: flagged)
        return "\(name(filter)), \(count == 1 ? "1 frame" : "\(count) frames")"
    }

    /// The segment's help tag: what it shows, that Develop follows it, and its View > Show key.
    static func help(_ filter: FlagFilter) -> String {
        switch filter {
        case .all: "Show every frame of the roll; Develop develops them all. Control-Command-0."
        case .flagged: "Show the flagged frames only; Develop develops just those. Control-Command-1."
        case .unflagged: "Show the frames not flagged only; Develop develops just those. Control-Command-2."
        }
    }

    private static func name(_ filter: FlagFilter) -> String {
        filter == .all ? "All" : filter.title
    }
}

/// The thumbnails' size: a small square, a slider with a stop for each of
/// `Metrics.thumbnailWidths`, and a large square. The squares step one size down or up; the slider
/// is dragged or clicked to a stop. VoiceOver reads it as one adjustable "Thumbnail size".
struct ThumbnailSizeControl: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button { model.changeSize(by: -1) } label: { SizeSquare(side: 11) }
                .buttonStyle(SizeSquareStyle())
                .disabled(!model.canChangeSize(by: -1))
                .help("Smaller thumbnails. Command-Minus, or pinch in.")
                .accessibilityLabel("Smaller Thumbnails")
            StepSlider(step: model.sizeStep, count: Metrics.thumbnailWidths.count) { target in
                model.changeSize(by: target - model.sizeStep)
            }
            // VoiceOver's slider, stepping as the drawn one does.
            .accessibilityRepresentation {
                Slider(value: Binding(get: { Double(model.sizeStep) },
                                      set: { model.changeSize(by: Int($0.rounded()) - model.sizeStep) }),
                       in: 0...Double(Metrics.thumbnailWidths.count - 1), step: 1) {
                    Text("Thumbnail size")
                }
            }
            .accessibilityValue(Self.sizeName(model.sizeStep))
            .help("Thumbnail size. Command-Plus and Command-Minus, or pinch.")
            Button { model.changeSize(by: 1) } label: { SizeSquare(side: 16) }
                .buttonStyle(SizeSquareStyle())
                .disabled(!model.canChangeSize(by: 1))
                .help("Larger thumbnails. Command-Plus, or pinch out.")
                .accessibilityLabel("Larger Thumbnails")
        }
    }

    /// The size VoiceOver reads for a step: "Small", "Medium", "Large", "Largest".
    static func sizeName(_ step: Int) -> String {
        let names = ["Small", "Medium", "Large", "Largest"]
        return names.indices.contains(step) ? names[step] : "\(step + 1) of \(Metrics.thumbnailWidths.count)"
    }
}

/// A thin square outline, the size control's small and large ends.
private struct SizeSquare: View {
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side > 12 ? 3.5 : 2.5, style: .continuous)
            .strokeBorder(lineWidth: 1.3)
            .frame(width: side, height: side)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

/// The squares' buttons: the line in the text colour, brighter on hover, dimmed when disabled.
private struct SizeSquareStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SizeSquareButton(configuration: configuration)
    }

    private struct SizeSquareButton: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered || configuration.isPressed ? Graphite.text : Graphite.secondaryText)
                .opacity(isEnabled ? 1 : 0.42)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
                .pressSpring(configuration.isPressed, depth: 0.86)
        }
    }
}

/// A slider with `count` stops and no fill: a matte track and a pale knob at `step`. A drag or a
/// click takes the knob to the nearest stop, which `change` is asked for.
///
/// The knob is a drop of glass that answers the pointer: it swells a little under it; taken up it grows into a lens and
/// goes where the pointer does along the track, leaning the way it is moved, while the size steps as it passes each
/// stop; let go, it settles on the stop it chose and shrinks back. With Reduce Motion it goes from stop to stop.
private struct StepSlider: View {
    let step: Int
    let count: Int
    let change: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false
    /// Where the pointer holds the knob along the track, 0 to 1, while it is dragged.
    @State private var held: CGFloat?
    /// How far the knob leans, by how fast it is moved; upright when the pointer rests.
    @State private var lean: CGFloat = 0
    @State private var upright: Task<Void, Never>?

    private let trackWidth: CGFloat = 106
    private let knob: CGFloat = 13
    /// The knob taken up: a lens, 23 points across.
    private static let lens: CGFloat = 23
    private static let mostLean: CGFloat = 0.26
    private static let leanSpeed: CGFloat = 900

    var body: some View {
        let span = trackWidth - knob
        let rest = count > 1 ? CGFloat(step) / CGFloat(count - 1) : 0
        let fraction = held ?? rest
        let grown: CGFloat = reduceMotion ? 1 : held != nil ? Self.lens / knob : isHovered ? 1.22 : 1
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Graphite.ink(contrast == .increased ? 0.55 : 0.36))
                .frame(height: 3)
            // The knob is a drop of primary-tinted glass, as the system's sliders' knobs are glass.
            Circle()
                .fill(Color.white.opacity(isHovered ? 0.12 : 0))
                .frame(width: knob, height: knob)
                .glassEffect(Graphite.primaryGlass(), in: Circle())
                .scaleEffect(x: grown * (1 + lean), y: grown * (1 - lean / 2))
                .animation(reduceMotion ? nil : (held != nil ? Graphite.Motion.grab : isHovered ? Graphite.Motion.swell
                                                 : Graphite.Motion.spring(0.44, 0.7)), value: grown)
                .animation(reduceMotion ? nil : Graphite.Motion.swell, value: lean)
                .offset(x: span * fraction)
                // Held, a short spring after the pointer; let go, onto its stop and a little past it.
                .animation(reduceMotion ? nil
                           : held != nil ? Graphite.Motion.follow : Graphite.Motion.spring(0.36, 0.62), value: fraction)
        }
        .frame(width: trackWidth, height: 22)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard count > 1, span > 0 else { return }
                    let position = min(max(0, (value.location.x - knob / 2) / span), 1)
                    if !reduceMotion {
                        held = position
                        lean(with: value.velocity.width)
                    }
                    let target = Int((position * CGFloat(count - 1)).rounded())
                    if target != step { change(target) }
                }
                .onEnded { _ in
                    held = nil
                    upright?.cancel()
                    lean = 0
                }
        )
        .onDisappear { upright?.cancel() }
    }

    /// Leans the knob by how fast it is moved, and stands it up once no move has come for a moment.
    private func lean(with speed: CGFloat) {
        let wanted = min(Self.mostLean, abs(speed) / Self.leanSpeed)
        if abs(wanted - lean) > 0.02 { lean = wanted }
        upright?.cancel()
        upright = Task {
            try? await Task.sleep(for: .milliseconds(90))
            if !Task.isCancelled { lean = 0 }
        }
    }
}

/// The 18 percent gray proofing surround, also View > Gray Surround: quiet, beside the size, as the
/// sheet's one view option. Its half-filled circle turns over as the surround is turned on, and back.
private struct GraySurroundToggle: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { model.graySurround.toggle() } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 13, weight: .light))
                .rotationEffect(.degrees(model.graySurround ? 180 : 0))
                .animation(reduceMotion ? nil : Graphite.Motion.spring(0.5, 0.7), value: model.graySurround)
        }
        .buttonStyle(.graphite(.icon, size: .small, isOn: model.graySurround))
        .help("Judge the photographs against an 18 percent gray surround. Shift-Command-G.")
        .accessibilityLabel("Gray surround")
        .accessibilityValue(model.graySurround ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
