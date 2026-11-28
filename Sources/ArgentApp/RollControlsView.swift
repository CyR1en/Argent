import AppKit
import ArgentCore
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
    @Environment(RollModel.self) private var model

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
                if (frame.flatMap(model.stock(for:)) ?? model.currentStock)?.monochrome != nil {
                    setting("Lens filter") {
                        let titles: [MonochromeFilter: String] = [.none: "None", .yellow: "Yellow", .orange: "Orange", .red: "Red"]
                        filmChoice("Lens filter", values: MonochromeFilter.allCases, defaultValue: .none,
                                   roll: \.monochromeFilter, own: \.monochromeFilter) { titles[$0] ?? "" }
                    }
                    setting("Paper grade") {
                        let titles = ["0 · Soft", "1 · Medium soft", "2 · Normal", "3 · Medium hard", "4 · Hard", "5 · Extra hard"]
                        filmChoice("Paper grade", values: PaperGrade.allCases, defaultValue: .normal,
                                   roll: \.paperGrade, own: \.paperGrade) { titles[$0.rawValue] }
                    }
                } else {
                    setting("Lab balance") { LabBalanceControl(frame: frame) }
                }
                setting("Grain") { GrainControl(frame: frame) }
                SectionDivider()
                    .padding(.top, 2)
                    .padding(.bottom, 1)
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

    private func filmChoice<Value: Hashable>(_ label: String, values: [Value], defaultValue: Value,
                                             roll: WritableKeyPath<RollControls, Value?>,
                                             own: WritableKeyPath<FrameControls, Value?>,
                                             title: @escaping (Value) -> String) -> some View {
        let rollValue = model.controls[keyPath: roll] ?? defaultValue
        let override = frame.flatMap { model.frameControls($0)[keyPath: own] }
        let selection = Binding(get: { override ?? rollValue }, set: { value in
            if let frame {
                var controls = model.frameControls(frame)
                controls[keyPath: own] = value == rollValue ? nil : value
                model.setRestoredFrameControls(controls, url: frame.url)
            } else {
                model.controls[keyPath: roll] = value == defaultValue ? nil : value
            }
        })
        return Menu {
            Picker(label, selection: selection) {
                ForEach(values, id: \.self) { Text(verbatim: title($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if let frame {
                Divider()
                Button(Self.sameAsRollItem(title(rollValue))) {
                    var controls = model.frameControls(frame)
                    controls[keyPath: own] = nil
                    model.setRestoredFrameControls(controls, url: frame.url)
                }
                .disabled(override == nil)
            }
        } label: {
            MenuFace(text: title(selection.wrappedValue), minWidth: 100)
        }
        .graphiteMenu()
        .disabled(model.roll == nil)
        .accessibilityLabel(label)
        .accessibilityValue(title(selection.wrappedValue) + Self.ownership(ControlsScope(frame: frame), isOwn: override != nil))
        .modifier(FrameOverrideIndicator(isOwn: override != nil))
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
/// halation, in a recessed Liquid Glass scrubber bar matching the menus above it. A gesture's steps go to the frame view's
/// print alone, and the roll or the frame takes the value as it ends (`RollModel.printedHalation`), since each write saves
/// every frame's choices. With a frame, the bar's default detent and reset are "same as roll", and an inline dock-accent dot,
/// tint and readout mark a frame override without wrapping the row in a box. Disabled where the stock has no halation, and
/// while no stock is loaded.
struct HalationControl: View {
    let frame: Frame?
    @Environment(RollModel.self) private var model

    var body: some View {
        let roll = model.output.halation
        let value = frame.map(model.halation(for:)) ?? roll
        let own = frame.map { model.frameControls($0).halation != nil } ?? false
        // The stock the control acts on: the frame's, its own or the roll's, or on the sheet the roll's.
        let stock = if let frame { model.stock(for: frame) } else { model.currentStock }
        let unavailable = stock.map { $0.halation == nil ? "\($0.displayName) has no halation." : nil } ?? "No stock is loaded."
        let defaultValue = frame != nil ? roll : OutputSettings.defaultHalation
        var spec = AdjustmentSliderSpec.halation
        if frame != nil { spec.defaultValue = Float(roll) }
        spec.spokenNote = RollControlsView.ownership(ControlsScope(frame: frame), isOwn: own)
        let resetAction: @MainActor () -> Void = {
            if let frame {
                model.setHalation(nil, for: frame)
            } else {
                model.beginHalationAdjusting(for: nil)
                model.moveHalation(OutputSettings.defaultHalation, for: nil)
                model.endHalationAdjusting()
            }
        }
        return HalationScrubberBar(
            spec: spec,
            value: value,
            defaultValue: defaultValue,
            isFrame: frame != nil,
            isOwn: own,
            isAvailable: unavailable == nil,
            help: unavailable ?? help(roll: roll, own: own),
            snapshot: frame.map { .frame($0.url) } ?? .roll,
            beginGesture: { model.beginHalationAdjusting(for: frame) },
            moveValue: { model.moveHalation($0, for: frame) },
            endGesture: { model.endHalationAdjusting() },
            resetValue: resetAction,
            menuEntries: { isDragging in
                Self.menuEntries(frame: frame, roll: roll, value: value, isOwn: own,
                                 isAvailable: unavailable == nil, isDragging: isDragging,
                                 model: model, reset: resetAction)
            }
        )
    }

    /// The row's menu's way back to the roll's value, off while the frame follows the roll already, and while the row is
    /// disabled (its stock has no halation), so a frame's own kept for its stock's return is not cleared from a disabled row.
    @MainActor static func sameAsRoll(_ frame: Frame, roll: Int, isOwn: Bool, isAvailable: Bool = true,
                                      model: RollModel) -> MenuEntry {
        .action("film.halationSameAsRoll", RollControlsView.sameAsRollItem(AdjustmentSliderSpec.halation.formatted(Float(roll))),
                isEnabled: isOwn && isAvailable) { model.setHalation(nil, for: frame) }
    }

    /// The bar's context menu: "Same as roll" for a frame, then "Reset Halation".
    @MainActor static func menuEntries(frame: Frame?, roll: Int, value: Int, isOwn: Bool, isAvailable: Bool,
                                       isDragging: Bool, model: RollModel,
                                       reset: @escaping @MainActor () -> Void) -> [MenuEntry] {
        let sameAsRoll = frame.map { frame in
            [Self.sameAsRoll(frame, roll: roll, isOwn: isOwn, isAvailable: isAvailable && !isDragging, model: model)]
        } ?? []
        let target = frame != nil ? roll : OutputSettings.defaultHalation
        let resetRow = InspectorMenus.sliderRow(title: AdjustmentSliderSpec.halation.title,
                                                isChanged: value != target,
                                                isEnabled: isAvailable && !isDragging,
                                                reset: reset)
        return MenuEntry.sections([sameAsRoll, resetRow])
    }

    /// Maps a horizontal pointer coordinate along the bar's width to a clamped Halation integer (0...200).
    static func value(at x: CGFloat, width: CGFloat, range: ClosedRange<Int> = OutputSettings.halationRange) -> Int {
        guard width > 0 else { return OutputSettings.defaultHalation }
        let fraction = min(1, max(0, x / width))
        let span = CGFloat(range.upperBound - range.lowerBound)
        return min(range.upperBound, max(range.lowerBound, range.lowerBound + Int((fraction * span).rounded())))
    }

    /// Scrubs Halation relatively from `start` by `steps` (positive right, negative left), clamped to `spec.range`.
    static func scrubbed(from start: Int, steps: CGFloat, spec: AdjustmentSliderSpec = .halation) -> Int {
        Int(spec.scrubbed(from: Float(start), steps: steps).rounded())
    }

    /// Advances a readout scrub by horizontal drag `delta` (10x when `largeStep` is held), clamping accumulated steps
    /// to the reachable range around `start` so overshooting 0 or 200 reverses immediately without dead travel.
    static func advanceScrub(steps: CGFloat, delta: CGFloat, from start: Int, largeStep: Bool,
                             spec: AdjustmentSliderSpec = .halation) -> (steps: CGFloat, value: Int) {
        let stepSize = CGFloat(max(spec.step, Float.leastNonzeroMagnitude))
        let minSteps = (CGFloat(spec.range.lowerBound) - CGFloat(start)) / stepSize
        let maxSteps = (CGFloat(spec.range.upperBound) - CGFloat(start)) / stepSize
        let nextSteps = min(maxSteps, max(minSteps, steps + delta * (largeStep ? 10 : 1)))
        return (nextSteps, scrubbed(from: start, steps: nextSteps, spec: spec))
    }

    private func help(roll: Int, own: Bool) -> String {
        let scale = "The glow around bright lights: 100 is the stock's own, 0 none and 200 twice as much."
        guard frame != nil else { return "The roll's Halation. \(scale) Every frame without its own develops with it." }
        return own ? "This frame's own Halation. \(scale) The roll's is \(roll)."
            : "This frame's Halation, the same as the roll's. \(scale) Changing it gives the frame its own."
    }
}

/// Coalesces high-rate pointer drags to `AdjustmentSlider.dragWriteInterval`, flushing the final value on release.
@MainActor
private final class HalationDragThrottle {
    private var pending: Int?
    private var lastWrite: CFTimeInterval = 0
    private var task: Task<Void, Never>?

    func push(_ value: Int, write: @escaping @MainActor (Int) -> Void) {
        pending = value
        let now = CACurrentMediaTime()
        let wait = AdjustmentSlider.dragWriteInterval - (now - lastWrite)
        if wait <= 0 {
            flush(write: write)
        } else if task == nil {
            task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.task = nil
                self.flush(write: write)
            }
        }
    }

    func flush(write: @MainActor (Int) -> Void) {
        let value = pending
        cancel()
        guard let value else { return }
        lastWrite = CACurrentMediaTime()
        write(value)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}

/// Identifies the editing target for typed Halation input, so a non-optional value distinguishes roll edits from nil.
private enum HalationSnapshot: Equatable, Sendable {
    case roll
    case frame(URL)
}

/// Recessed Liquid Glass horizontal scrubber bar for Film settings' Halation control.
private struct HalationScrubberBar: View {
    let spec: AdjustmentSliderSpec
    let value: Int
    let defaultValue: Int
    let isFrame: Bool
    let isOwn: Bool
    let isAvailable: Bool
    let help: String
    let snapshot: HalationSnapshot
    let beginGesture: @MainActor () -> Void
    let moveValue: @MainActor (Int) -> Void
    let endGesture: @MainActor () -> Void
    let resetValue: @MainActor () -> Void
    let menuEntries: @MainActor (Bool) -> [MenuEntry]

    private static let height: CGFloat = 30
    private static let cornerRadius: CGFloat = Graphite.Metric.actionRadius
    private static let barSpace = "halationScrubberBar"

    @Environment(\.isEnabled) private var environmentEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var live: Int?
    @State private var isDragging = false
    @State private var suppressDrag = false
    @State private var scrubStartValue = 0
    @State private var scrubLastX: CGFloat = 0
    @State private var scrubSteps: CGFloat = 0
    @State private var barWidth: CGFloat = 228
    @State private var spot = PointerSpot()
    @State private var resetHovered = false
    @State private var number = ""
    @State private var numberSnapshot: HalationSnapshot?
    @State private var validationMessage: String?
    @State private var written: Int?
    @State private var arrivals = ValueArrivals()
    @State private var throttle = HalationDragThrottle()
    @State private var showsKeyboardFocus = false

    @FocusState private var barFocused: Bool
    @FocusState private var numberFocused: Bool
    @AccessibilityFocusState private var numberAccessibilityFocused: Bool

    private var isActive: Bool { isAvailable && environmentEnabled }
    private var isHovered: Bool { spot.isInside && isActive }
    private var current: Int { live ?? value }
    private var isChanged: Bool { current != defaultValue }
    private var canReset: Bool { isActive && (isChanged || isOwn) }
    private var isOwnValue: Bool { isDragging || written == current }

    var body: some View {
        let glides = !reduceMotion && arrivals.glides(to: Float(current), isOwn: isOwnValue)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let showsTint = isFrame && (isOwn || (isDragging && current != defaultValue))

        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                // Interactive track layer: well, animated fill, default detent pips, and leading edge needle.
                Animated(value: CGFloat(current)) { animatedValue in
                    trackSurface(for: animatedValue, shape: shape, showsTint: showsTint)
                        .transaction { $0.animation = nil }
                }
                .animation(glides ? Graphite.Motion.value : nil, value: current)
                .contentShape(shape)
                .pointerStyle(isActive && !numberFocused ? .columnResize : nil)
                .gesture(barDrag, isEnabled: isActive && !numberFocused)

                // Foreground labels and trailing controls.
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(verbatim: spec.title)
                            .font(Graphite.Typeface.label)
                            .foregroundStyle(Graphite.text)
                            .lineLimit(1)
                        if showsTint {
                            Circle()
                                .fill(Graphite.dockAccent)
                                .frame(width: 5, height: 5)
                                .transition(reduceMotion ? .identity : .scale(scale: 0.4).combined(with: .opacity))
                                .accessibilityHidden(true)
                        }
                    }
                    .allowsHitTesting(false)

                    Spacer(minLength: 4)
                        .allowsHitTesting(false)

                    HStack(spacing: 3) {
                        if canReset {
                            resetButton
                        }
                        valueReadout(glides: glides, showsTint: showsTint)
                    }
                    .opacity(numberFocused ? 0 : 1)
                    .allowsHitTesting(!numberFocused)
                }
                .padding(.leading, 11)
                .padding(.trailing, 6)

                // Kept mounted so clicking the value focuses it on the first click without shifting the reset button.
                inlineNumberField
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .coordinateSpace(name: Self.barSpace)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            .overlay {
                borderOverlay(shape: shape)
                    .allowsHitTesting(false)
            }
            .overlay {
                if isActive {
                    PointerLight(spot: spot, shape: shape, isPressed: isDragging, reach: 75, bloom: 32)
                }
            }
            .opacity(isActive ? 1 : 0.42)
            .onContinuousHover { spot.follow($0) }
            .contextMenu(entries: { menuEntries(isDragging) })
            .help(isActive ? spec.sliderHelp(help) : help)
            .focusable(isActive && !numberFocused)
            .focused($barFocused)
            .focusEffectDisabled()
            .onChange(of: barFocused) { _, focused in
                if focused {
                    let type = NSApp.currentEvent?.type
                    showsKeyboardFocus = type != .leftMouseDown && type != .leftMouseUp && type != .leftMouseDragged
                } else {
                    showsKeyboardFocus = false
                }
            }
            .onKeyPress(phases: [.down, .repeat]) { key in
                guard isActive, !numberFocused else { return .ignored }
                return handleKey(key)
            }
            .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
            .animation(reduceMotion ? nil : Graphite.Motion.quick, value: showsTint)
            .accessibilityElement(children: numberFocused ? .contain : .ignore)
            .accessibilityLabel(spec.title)
            .accessibilityValue(spec.spoken(Float(current)))
            .accessibilityHint(help)
            .accessibilityAdjustableAction { direction in
                guard isActive else { return }
                let delta = direction == .increment ? 1 : -1
                stepValue(to: current + delta)
            }
            .accessibilityAction(named: "Edit \(spec.title.lowercased()) value") {
                guard isActive, !numberFocused else { return }
                numberFocused = true
            }
            .accessibilityAction(named: isFrame ? "Same as roll" : "Reset halation") {
                guard canReset else { return }
                performReset()
            }

            if let validationMessage {
                Text(verbatim: validationMessage)
                    .font(Graphite.Typeface.caption)
                    .foregroundStyle(Graphite.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { number = spec.formatted(Float(value)) }
        .onChange(of: value) { _, new in
            if written != nil, written != new { written = nil }
        }
        .onChange(of: snapshot) { _, updated in
            if numberFocused, updated != numberSnapshot { numberFocused = false }
            if !numberFocused { validationMessage = nil }
        }
        .onChange(of: numberFocused) { _, focused in
            if focused {
                number = spec.formatted(Float(value))
                numberSnapshot = snapshot
                validationMessage = nil
                Task { @MainActor in
                    if numberFocused { numberAccessibilityFocused = true }
                }
            } else {
                commitNumber()
                numberSnapshot = nil
            }
        }
        .onDisappear {
            if numberFocused { commitNumber() }
            if isDragging { finishDrag() } else { throttle.cancel() }
        }
    }

    @ViewBuilder
    private func trackSurface(for animatedValue: CGFloat, shape: RoundedRectangle, showsTint: Bool) -> some View {
        let lower = CGFloat(OutputSettings.halationRange.lowerBound)
        let span = CGFloat(OutputSettings.halationRange.upperBound - OutputSettings.halationRange.lowerBound)
        let fraction = span > 0 ? min(1, max(0, (animatedValue - lower) / span)) : 0
        let defaultFraction = spec.fraction(of: Float(defaultValue))
        let isDark = Graphite.isDark

        GeometryReader { proxy in
            let size = proxy.size
            let fillWidth = fraction * size.width
            let needleWidth: CGFloat = (isHovered || isDragging) ? 3 : 2.5

            ZStack(alignment: .leading) {
                // Recessed well + subtle top depth shadow.
                shape.fill(Graphite.ink(isDark ? 0.055 : 0.045))
                LinearGradient(
                    colors: [Color.black.opacity(isDark ? 0.22 : 0.06), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 4)
                .frame(maxHeight: .infinity, alignment: .top)

                // Luminous translucent glass fill.
                if fillWidth > 0.5 {
                    ZStack(alignment: .top) {
                        LinearGradient(
                            colors: showsTint
                                ? [Graphite.dockAccent.opacity(isDark ? 0.21 : 0.17),
                                   Graphite.dockAccent.opacity(isDark ? 0.12 : 0.10)]
                                : [Graphite.ink(isDark ? 0.18 : 0.12),
                                   Graphite.ink(isDark ? 0.11 : 0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        Rectangle()
                            .fill(Color.white.opacity(isDark ? 0.08 : 0.38))
                            .frame(height: 1)
                    }
                    .frame(width: fillWidth, height: size.height)
                }

                // Top and bottom edge pips at the default/roll value (e.g. 100).
                if defaultFraction > 0.02 && defaultFraction < 0.98 {
                    let detentX = defaultFraction * size.width
                    VStack(spacing: 0) {
                        Rectangle().fill(Graphite.tertiaryText.opacity(0.55)).frame(width: 1, height: 4)
                        Spacer(minLength: 0)
                        Rectangle().fill(Graphite.tertiaryText.opacity(0.55)).frame(width: 1, height: 4)
                    }
                    .padding(.vertical, 1)
                    .frame(width: 1, height: size.height)
                    .position(x: detentX, y: size.height / 2)
                }

                // Leading edge needle.
                if fraction > 0.001 {
                    let needleX = min(size.width - 1 - needleWidth / 2,
                                      max(1 + needleWidth / 2, fillWidth - needleWidth / 2))
                    Capsule()
                        .fill(showsTint ? Graphite.dockAccent : Graphite.selection)
                        .opacity(isHovered || isDragging ? 1 : (showsTint ? 0.92 : 0.70))
                        .frame(width: needleWidth, height: max(0, size.height - 10))
                        .position(x: needleX, y: size.height / 2)
                }
            }
            .clipShape(shape)
        }
        .accessibilityHidden(true)
    }

    private func borderOverlay(shape: RoundedRectangle) -> some View {
        let strokeColor: Color = if showsKeyboardFocus {
            Graphite.dockAccent.opacity(0.85)
        } else if contrast == .increased {
            Graphite.strongBorder
        } else if isHovered || isDragging {
            Graphite.ink(Graphite.isDark ? 0.22 : 0.20)
        } else {
            Graphite.border
        }
        return shape.strokeBorder(strokeColor, lineWidth: showsKeyboardFocus ? 1.5 : 1)
    }

    private var resetButton: some View {
        Button(action: performReset) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(resetHovered ? Graphite.text : Graphite.secondaryText)
                .frame(width: 18, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(resetHovered ? Graphite.hoverFill : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(resetHovered ? 1 : (isHovered || isDragging || showsKeyboardFocus ? 0.92 : 0.42))
        .pointerStyle(.default)
        .onHover { resetHovered = $0 }
        .help(isFrame ? "Same as roll (\(defaultValue)). You can also double-click the bar."
              : "Reset halation to \(defaultValue). You can also double-click the bar.")
        .accessibilityLabel(isFrame ? "Same as roll" : "Reset halation")
    }

    private var inlineNumberField: some View {
        let fieldShape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return TextField(spec.title, text: $number)
            .textFieldStyle(.plain)
            .font(Graphite.Typeface.number.weight(.medium))
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Graphite.text)
            .padding(.horizontal, 5)
            .frame(width: 40, height: 20)
            .background(fieldShape.fill(Graphite.control))
            .overlay { fieldShape.strokeBorder(Graphite.dockAccent.opacity(0.75), lineWidth: 1) }
            .focused($numberFocused)
            .accessibilityFocused($numberAccessibilityFocused)
            .opacity(numberFocused ? 1 : 0)
            .allowsHitTesting(numberFocused)
            .accessibilityHidden(!numberFocused)
            .accessibilityLabel("\(spec.title) value")
            .accessibilityHint(validationMessage ?? spec.entryHelp(help))
            .onSubmit { commitNumber(); numberFocused = false }
            .onKeyPress(.escape) {
                number = spec.formatted(Float(value))
                validationMessage = nil
                numberFocused = false
                return .handled
            }
    }

    private func valueReadout(glides: Bool, showsTint: Bool) -> some View {
        let textColor: Color = showsTint ? Graphite.dockAccent
            : (isDragging || isHovered ? Graphite.text : Graphite.secondaryText)
        return Animated(value: CGFloat(current)) { counted in
            Text(verbatim: spec.formatted(spec.snapped(Float(counted))))
                .font(Graphite.Typeface.number.weight(.medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .transaction { $0.animation = nil }
        }
        .animation(glides ? Graphite.Motion.value : nil, value: current)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(isActive ? spec.entryHelp(help) + " Drag left or right over the value to change it, Shift in larger steps." : help)
        .gesture(valueClickOrDrag, isEnabled: isActive)
    }

    // MARK: Gestures & Keyboard

    private var barDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.barSpace))
            .onChanged { gesture in
                if !isDragging && !suppressDrag {
                    if NSApp.currentEvent?.clickCount == 2 {
                        suppressDrag = true
                        performReset()
                        return
                    }
                    beginDrag()
                }
                guard !suppressDrag else { return }
                applyDragValue(HalationControl.value(at: gesture.location.x, width: barWidth))
            }
            .onEnded { _ in
                if suppressDrag {
                    suppressDrag = false
                    return
                }
                if isDragging { finishDrag() }
            }
    }

    /// Click on the number edits it inline; dragging past 3 pt scrubs relative to its starting value (Shift in 10x steps).
    private var valueClickOrDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.barSpace))
            .onChanged { gesture in
                if !isDragging {
                    guard abs(gesture.translation.width) >= ValueScrubView.dragThreshold else { return }
                    scrubStartValue = current
                    scrubLastX = gesture.startLocation.x
                    scrubSteps = 0
                    beginDrag()
                }
                let dx = gesture.location.x - scrubLastX
                scrubLastX = gesture.location.x
                let advanced = HalationControl.advanceScrub(steps: scrubSteps, delta: dx, from: scrubStartValue,
                                                            largeStep: NSEvent.modifierFlags.contains(.shift), spec: spec)
                scrubSteps = advanced.steps
                applyDragValue(advanced.value)
            }
            .onEnded { _ in
                if isDragging {
                    finishDrag()
                } else if NSApp.currentEvent?.clickCount == 2 {
                    performReset()
                } else {
                    numberFocused = true
                }
            }
    }

    private func beginDrag() {
        if numberFocused { commitNumber(); numberFocused = false }
        isDragging = true
        beginGesture()
    }

    private func applyDragValue(_ next: Int) {
        guard next != current else { return }
        live = next
        written = next
        throttle.push(next, write: moveValue)
    }

    private func finishDrag() {
        throttle.flush(write: moveValue)
        isDragging = false
        endGesture()
        live = nil
    }

    private func performReset() {
        numberFocused = false
        validationMessage = nil
        written = nil
        resetValue()
    }

    private func stepValue(to target: Int) {
        let range = OutputSettings.halationRange
        let clamped = min(range.upperBound, max(range.lowerBound, target))
        guard clamped != value else { return }
        written = clamped
        beginGesture()
        moveValue(clamped)
        endGesture()
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let delta = press.modifiers.contains(.shift) ? 10 : 1
        switch press.key {
        case .leftArrow, .downArrow:
            stepValue(to: current - delta)
            return .handled
        case .rightArrow, .upArrow:
            stepValue(to: current + delta)
            return .handled
        case .home:
            stepValue(to: OutputSettings.halationRange.lowerBound)
            return .handled
        case .end:
            stepValue(to: OutputSettings.halationRange.upperBound)
            return .handled
        case .return:
            guard press.phase == .down else { return .ignored }
            numberFocused = true
            return .handled
        default:
            return .ignored
        }
    }

    private func commitNumber() {
        switch ManualAdjustmentNumberInput.resolve(number, spec: spec, startingAt: numberSnapshot, current: snapshot) {
        case .value(let stepped):
            let clamped = Int(stepped.rounded())
            if clamped != value {
                written = nil
                beginGesture()
                moveValue(clamped)
                endGesture()
            }
            number = spec.formatted(Float(clamped))
            validationMessage = nil
        case .invalid:
            validationMessage = spec.entryLimits
        case .superseded:
            number = spec.formatted(Float(value))
            validationMessage = nil
        }
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
