import ArgentRoll
import SwiftUI

/// Which values a line of roll controls sets: the whole roll's, or the open frame's own.
enum ControlsScope: Equatable, Sendable {
    case roll
    case frame

    init(frame: Frame?) { self = frame == nil ? .roll : .frame }

    /// What the line says it sets: "Whole roll" or "This frame".
    var title: String {
        switch self {
        case .roll: "Whole roll"
        case .frame: "This frame"
        }
    }
}

/// Content for the dock's settings popover. The parent owns presentation and padding.
struct RollControlsView: View {
    let frame: Frame?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Film settings")
                    .font(Graphite.Typeface.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                CloseButton(help: "Close film settings") { dismiss() }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    scopeHeading(ControlsScope(frame: frame))
                    Spacer(minLength: 8)
                    if let frame { SameAsRollButton(frame: frame) }
                }
                setting("Rated at") { RatedAtControl(frame: frame) }
                setting("Lab balance") { LabBalanceControl(frame: frame) }
                setting("Grain") { GrainControl(frame: frame) }
                HalationControl(frame: frame)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ControlsScope(frame: frame).title)
            AutoStatusLabel()
        }
        .foregroundStyle(Graphite.text)
        .frame(width: 228)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Film settings")
    }

    private func scopeHeading(_ scope: ControlsScope) -> some View {
        Text(verbatim: scope.title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(Graphite.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func setting(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(Graphite.Typeface.label)
                .foregroundStyle(Graphite.secondaryText)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            control()
        }
    }

    /// "800, one stop under", or the position's name when no stock is loaded.
    static func ratedAtItem(_ position: RollControls.RatedAt, boxSpeed: Float) -> String {
        boxSpeed > 0 ? "\(position.iso(boxSpeed: boxSpeed)), \(position.title.lowercased())" : position.title
    }

    /// A pop-up's face: the speed alone ("800"; the stock's box speed says how far it is from
    /// it, and the help tag says it in words), or the position's name when no stock is loaded.
    /// ISO speeds read without a grouping separator: 1600, not 1,600.
    static func ratedAtFace(_ position: RollControls.RatedAt, boxSpeed: Float) -> String {
        boxSpeed > 0 ? "\(position.iso(boxSpeed: boxSpeed))" : position.title
    }

    /// The item that makes a frame follow the roll again: "Same as roll, 400, box speed".
    static func sameAsRollItem(_ rollValue: String) -> String { "Same as roll, " + rollValue }

    /// For VoiceOver and the help tags in the frame view: whether the value is the frame's own or
    /// the roll's.
    static func ownership(_ scope: ControlsScope, isOwn: Bool) -> String {
        guard scope == .frame else { return "" }
        return isOwn ? ", this frame only" : ", same as roll"
    }
}

/// Marks a pop-up when the open frame has its own value.
struct FrameOverrideIndicator: ViewModifier {
    let isOwn: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isOwn {
                    RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
                        .strokeBorder(Graphite.dockAccent.opacity(0.6), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isOwn {
                    Circle().fill(Graphite.dockAccent)
                        .frame(width: 7, height: 7)
                        .overlay { Circle().strokeBorder(Graphite.floatingOpaque, lineWidth: 1) }
                        .offset(x: 2, y: -2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// Rated at: the roll's, or with a frame its own, with "Same as roll" in the menu.
struct RatedAtControl: View {
    let frame: Frame?
    @Environment(RollModel.self) private var model

    var body: some View {
        // The speeds follow the stock the frame develops through, its own or the roll's.
        let box = (frame.flatMap(model.stock(for:)) ?? model.currentStock)?.boxSpeed ?? 0
        let own = frame.map { model.frameControls($0) } ?? FrameControls()
        let current = frame.map { model.controls(for: $0) } ?? model.controls
        let scope = ControlsScope(frame: frame)
        let label = frame == nil ? "Rated at" : "Rated at for this frame"
        let value = RollControlsView.ratedAtItem(current.ratedAt, boxSpeed: box)
        Menu {
            Picker("Rated at", selection: ratedAt) { items(box) }
                .pickerStyle(.inline)
                .labelsHidden()
            if let frame {
                Divider()
                Button {
                    model.setRatedAt(nil, for: frame)
                } label: {
                    Text(verbatim: RollControlsView.sameAsRollItem(RollControlsView.ratedAtItem(model.controls.ratedAt, boxSpeed: box)))
                }
                .disabled(own.ratedAt == nil)
            }
        } label: {
            MenuFace(text: RollControlsView.ratedAtFace(current.ratedAt, boxSpeed: box), minWidth: 100)
        }
        .graphiteMenu()
        .disabled(model.roll == nil)
        .help(help(value: value, own: own.ratedAt != nil, roll: RollControlsView.ratedAtItem(model.controls.ratedAt, boxSpeed: box)))
        // A menu here drops its accessibility label, so VoiceOver gets a picker of the same
        // positions; choosing the roll's own makes a frame follow the roll, as Same as Roll does.
        .accessibilityRepresentation {
            Picker(label, selection: ratedAt) { items(box) }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(value + RollControlsView.ownership(scope, isOwn: own.ratedAt != nil))
        }
        .modifier(FrameOverrideIndicator(isOwn: own.ratedAt != nil))
    }

    private func help(value: String, own: Bool, roll: String) -> String {
        guard frame != nil else { return "The roll's Rated at: \(value). Every frame without its own develops at it." }
        return own ? "This frame's own Rated at: \(value). The roll's is \(roll)."
            : "This frame's Rated at: \(value), the same as the roll's. Choosing another gives the frame its own."
    }

    @ViewBuilder private func items(_ box: Float) -> some View {
        ForEach(RollControls.RatedAt.allCases, id: \.self) { position in
            Text(verbatim: RollControlsView.ratedAtItem(position, boxSpeed: box)).tag(position)
        }
    }

    private var ratedAt: Binding<RollControls.RatedAt> {
        Binding(get: { frame.map { model.controls(for: $0).ratedAt } ?? model.controls.ratedAt },
                set: { value in
                    if let frame { model.setRatedAt(value, for: frame) } else { model.controls.ratedAt = value }
                })
    }
}

/// Lab balance: the roll's, or with a frame its own, with "Same as roll" in the menu.
struct LabBalanceControl: View {
    let frame: Frame?
    @Environment(RollModel.self) private var model

    var body: some View {
        let own = frame.map { model.frameControls($0) } ?? FrameControls()
        let current = frame.map { model.controls(for: $0) } ?? model.controls
        let scope = ControlsScope(frame: frame)
        let label = frame == nil ? "Lab balance" : "Lab balance for this frame"
        Menu {
            Picker("Lab balance", selection: labBalance) { items }
                .pickerStyle(.inline)
                .labelsHidden()
            if let frame {
                Divider()
                Button {
                    model.setLabBalance(nil, for: frame)
                } label: {
                    Text(verbatim: RollControlsView.sameAsRollItem(model.controls.labBalance.title))
                }
                .disabled(own.labBalance == nil)
            }
        } label: {
            MenuFace(text: current.labBalance.title, minWidth: 100)
        }
        .graphiteMenu()
        .disabled(model.roll == nil)
        .help(help(value: current.labBalance.title, own: own.labBalance != nil))
        .accessibilityRepresentation {
            Picker(label, selection: labBalance) { items }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(current.labBalance.title + RollControlsView.ownership(scope, isOwn: own.labBalance != nil))
        }
        .modifier(FrameOverrideIndicator(isOwn: own.labBalance != nil))
    }

    private func help(value: String, own: Bool) -> String {
        guard frame != nil else { return "The roll's Lab balance: \(value). Every frame without its own prints with it." }
        return own ? "This frame's own Lab balance: \(value). The roll's is \(model.controls.labBalance.title)."
            : "This frame's Lab balance: \(value), the same as the roll's. Choosing another gives the frame its own."
    }

    @ViewBuilder private var items: some View {
        ForEach(RollControls.LabBalance.allCases, id: \.self) { balance in
            Text(balance.title).tag(balance)
        }
    }

    private var labBalance: Binding<RollControls.LabBalance> {
        Binding(get: { frame.map { model.controls(for: $0).labBalance } ?? model.controls.labBalance },
                set: { value in
                    if let frame { model.setLabBalance(value, for: frame) } else { model.controls.labBalance = value }
                })
    }
}

/// Grain: the roll's, the Develop page's choice, so the previews and the develops keep matching; or with
/// a frame its own, with "Same as roll" in the menu.
struct GrainControl: View {
    let frame: Frame?
    @Environment(RollModel.self) private var model

    var body: some View {
        let own = frame.map { model.frameControls($0).grain != nil } ?? false
        let current = frame.map(model.grain(for:)) ?? model.output.grain
        let label = frame == nil ? "Grain" : "Grain for this frame"
        Menu {
            Picker("Grain", selection: grain) { items }
                .pickerStyle(.inline)
                .labelsHidden()
            if let frame {
                Divider()
                Button {
                    model.setGrain(nil, for: frame)
                } label: {
                    Text(verbatim: RollControlsView.sameAsRollItem(model.output.grain.title))
                }
                .disabled(!own)
            }
        } label: {
            MenuFace(text: current.title, minWidth: 100)
        }
        .graphiteMenu()
        .help(help(value: current.title, own: own))
        .accessibilityRepresentation {
            Picker(label, selection: grain) { items }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(current.title + RollControlsView.ownership(ControlsScope(frame: frame), isOwn: own))
        }
        .modifier(FrameOverrideIndicator(isOwn: own))
    }

    private func help(value: String, own: Bool) -> String {
        guard frame != nil else { return "The roll's Grain: \(value), as on the Develop page. Every frame without its own develops with it." }
        return own ? "This frame's own Grain: \(value). The roll's is \(model.output.grain.title)."
            : "This frame's Grain: \(value), the same as the roll's. Choosing another gives the frame its own."
    }

    @ViewBuilder private var items: some View {
        ForEach(OutputSettings.Grain.allCases, id: \.self) { Text($0.title).tag($0) }
    }

    private var grain: Binding<OutputSettings.Grain> {
        Binding(get: { frame.map(model.grain(for:)) ?? model.output.grain },
                set: { value in
                    if let frame { model.setGrain(value, for: frame) } else { model.output.grain = value }
                })
    }
}

/// Halation: the roll's, kept for every roll as Grain is, or with a frame its own. 0 to 200, where 100 is the stock's own
/// halation, on the inspector's slider row, which names itself. A gesture's steps go to the frame view's print alone, and the
/// roll or the frame takes the value as it ends (`RollModel.printedHalation`), since each write saves every frame's choices.
/// With a frame the row's reset is "same as roll": the roll's value is its default, and the frame's own stands off it on the
/// track. Disabled where the stock has no halation.
struct HalationControl: View {
    let frame: Frame?
    @Environment(RollModel.self) private var model

    var body: some View {
        let roll = model.output.halation
        let value = frame.map(model.halation(for:)) ?? roll
        let own = frame.map { model.frameControls($0).halation != nil } ?? false
        // The stock the control acts on: the frame's, its own or the roll's, or on the sheet the roll's.
        let stock = if let frame { model.stock(for: frame) } else { model.currentStock }
        var spec = AdjustmentSliderSpec.halation
        if frame != nil { spec.defaultValue = Float(roll) }
        return ManualAdjustmentRow(spec: spec, help: help(roll: roll, own: own, without: stock?.halation == nil ? stock?.displayName : nil),
                                   value: Binding(get: { Float(value) }, set: { model.moveHalation(Int($0.rounded()), for: frame) }),
                                   snapshot: frame?.url, beginGesture: {}, endGesture: { model.endHalationAdjusting() })
            .disabled(stock?.halation == nil)
            .modifier(FrameOverrideIndicator(isOwn: own))
    }

    /// `without` is the stock's name where it has no halation.
    private func help(roll: Int, own: Bool, without: String?) -> String {
        if let without { return "\(without) has no halation." }
        let scale = "The glow around bright lights: 100 is the stock's own, 0 none and 200 twice as much."
        guard frame != nil else { return "The roll's Halation. \(scale) Every frame without its own develops with it." }
        return own ? "This frame's own Halation. \(scale) The roll's is \(roll)."
            : "This frame's Halation, the same as the roll's. \(scale) Changing it gives the frame its own."
    }
}

/// Clears a frame's own stock, Rated at, Lab balance, grain and halation, so it follows the roll again (Frame >
/// Same as Roll); disabled while it has none.
struct SameAsRollButton: View {
    let frame: Frame
    @Environment(RollModel.self) private var model

    var body: some View {
        Button("Same as roll") { model.clearOverrides(for: frame) }
            .buttonStyle(.graphite(.quiet, size: .small))
            .disabled(model.frameControls(frame).isEmpty)
            .help("Make this frame follow the roll's stock, Rated at, Lab balance, Grain and Halation")
    }
}
