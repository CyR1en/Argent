import ArgentCore
import ArgentRoll
import SwiftUI

/// What a removal's row can be asked for (docs/remove-plan.md, section 4.8). One table for the row's controls, its menu and its
/// VoiceOver actions: which of them a row shows, what each is called, when it can be used and which of the model's commands it
/// is. Pure but for the call, so `RemoveInspectorTests` holds it for every kind of row.
enum RemoveRowAction: String, CaseIterable, Sendable {
    /// The row's eye.
    case toggle
    /// Include Shadow and Reflections.
    case effects
    case tryAgain, better, delete
    /// Stops the row's run.
    case cancel
    /// The face note's click: the frame glides to the face at 100 %.
    case face

    /// What a row offers, in the menu's order. A run with no patch yet has its caption and Cancel and nothing else; a removal
    /// has its eye, its shadow switch, Try Again, Better and Delete whatever its state, each enabled by the row's own rule, with
    /// Cancel while it is made again and the way to the face where its caption is the face note.
    static func shown(for row: RemovalRowState) -> [RemoveRowAction] {
        if row.isPending { return row.canCancel ? [.cancel] : [] }
        var actions: [RemoveRowAction] = [.toggle, .effects, .tryAgain, .better]
        if row.caption?.opensFace == true { actions.append(.face) }
        if row.canCancel { actions.append(.cancel) }
        return actions + [.delete]
    }

    func title(for row: RemovalRowState) -> String {
        switch self {
        case .toggle: row.isOn ? "Turn Off" : "Turn On"
        case .effects: "Include Shadow and Reflections"
        case .tryAgain: "Try Again"
        case .better: "Better"
        case .delete: "Delete"
        case .cancel: "Cancel"
        case .face: "Show Face at Full Size"
        }
    }

    func help(for row: RemovalRowState) -> String {
        switch self {
        case .toggle: row.isOn ? "Turn this removal off. The object comes back, and the removal stays as it is." : "Turn this removal on."
        case .effects: "Remove the object’s shadow and reflections with it. Off, only the object goes."
        case .tryAgain: "Make this removal again. The result differs each time."
        case .better: "Make this removal again more carefully. It takes longer."
        case .delete: "Delete this removal. The object comes back."
        case .cancel: row.isPending ? "Stop this removal." : "Stop making this removal again. It stays as it was."
        case .face: row.caption?.help ?? ""
        }
    }

    /// Whether the row lets it be used: the row's own rule for each (`RemovalRowState`), on a frame that can be adjusted. A run
    /// can be stopped, and a face looked at, on any frame.
    func isEnabled(for row: RemovalRowState, canAdjust: Bool = true) -> Bool {
        switch self {
        case .toggle, .effects: canAdjust && row.canToggle
        case .tryAgain, .better: canAdjust && row.canRemake
        case .delete: canAdjust && row.canDelete
        case .cancel: row.canCancel
        case .face: row.caption?.opensFace == true
        }
    }

    /// Asks the model for it, if the row lets it be used.
    @MainActor func perform(on row: RemovalRowState, frame: Frame, canAdjust: Bool = true, with commands: any RemoveCommands) {
        guard isEnabled(for: row, canAdjust: canAdjust) else { return }
        switch self {
        case .toggle: commands.setRemoval(row.id, isOn: !row.isOn, on: frame)
        case .effects: commands.setRemoval(row.id, includesEffects: !row.includesEffects, on: frame)
        case .tryAgain: commands.remakeRemoval(row.id, better: false, on: frame)
        case .better: commands.remakeRemoval(row.id, better: true, on: frame)
        case .delete: commands.deleteRemoval(row.id, on: frame)
        case .cancel: commands.cancelRemoval(row.id, on: frame)
        case .face: commands.showRemovalFace(row.id, on: frame)
        }
    }
}

/// What VoiceOver says of a row after its name: whether it is on, then its caption with the caption's longer sentence, so the
/// face note is read with the row and nowhere else.
enum RemoveRowSpeech {
    static func value(_ row: RemovalRowState) -> String {
        let caption = row.caption.map { [$0.text, $0.help].compactMap { $0 }.joined(separator: ". ") }
        if row.isPending { return caption ?? "" }
        let state = (row.isOn ? "on" : "off") + (row.includesEffects ? "" : ", object only")
        return [state, caption].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One row of the Remove tab: a removal, or a run that has no patch yet. Its head is the eye, its name and its menu, with the
/// row's one caption under the name; a click opens its options under it, the shadow switch, Try Again, Better and Delete. The
/// pointer resting on it shows its outline on the photograph. The head is one element for VoiceOver, with its actions named.
struct RemoveRow: View {
    let frame: Frame
    let row: RemovalRowState
    /// Its options show under its head.
    let isOpen: Bool
    let canAdjust: Bool
    /// A click on its head.
    let onOpen: () -> Void
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    /// The head's height, whether or not the row has a caption: without one its name stands in the middle.
    static let height: CGFloat = 44
    /// From the row's leading edge to its name, past the eye.
    static let inset: CGFloat = 18 + Graphite.Metric.s
    /// A made row's options under its head: the switch, a gap, the buttons and the row's foot.
    static let optionsHeight: CGFloat = 24 + 6 + Graphite.Metric.controlHeight + 8

    /// The row's height as it is drawn.
    static func height(of row: RemovalRowState, isOpen: Bool) -> CGFloat {
        height + (isOpen && !row.isPending ? optionsHeight : 0)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        let showsOptions = isOpen && !row.isPending
        VStack(alignment: .leading, spacing: 0) {
            head
            if showsOptions {
                options.transition(.opacity)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(height: Self.height(of: row, isOpen: isOpen), alignment: .top)
        .background { shape.fill(Graphite.ink(isHovered ? 0.06 : showsOptions ? 0.04 : 0)) }
        .rowMenu(onOpen: {}, entries: menuEntries)
        .contentShape(shape)
        .onHover { over in
            isHovered = over
            if over {
                model.remove.hovered = row.id
            } else if model.remove.hovered == row.id {
                model.remove.hovered = nil
            }
        }
        .onDisappear { if model.remove.hovered == row.id { model.remove.hovered = nil } }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
    }

    // MARK: The head

    private var head: some View {
        HStack(spacing: Graphite.Metric.s) {
            if row.isPending {
                // A run has no eye yet; its name stands where the others' do.
                Color.clear.frame(width: 18, height: 28)
            } else {
                eye
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Graphite.Metric.xs) {
                    Text(verbatim: row.title)
                        .font(Graphite.Typeface.label)
                        .foregroundStyle(row.isOn || row.isPending ? Graphite.text : Graphite.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !row.isPending { menu }
                }
                .frame(height: 16)
                if let caption = row.caption {
                    RemoveCaptionLine(caption: caption, canCancel: row.canCancel, cancelHelp: RemoveRowAction.cancel.help(for: row),
                                      showFace: { perform(.face) }, cancel: { perform(.cancel) })
                        .transition(.opacity)
                }
            }
            // The name rises as a caption comes under it and settles back as it goes; the row keeps its height.
            .animation(reduceMotion ? nil : Graphite.Motion.quick, value: row.caption != nil)
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onTapGesture { if !row.isPending { onOpen() } }
        .help(row.caption?.help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(RemoveRowSpeech.value(row))
        .accessibilityHint(row.isPending ? "" : "Shows or hides this removal’s options.")
        .accessibilityAddTraits(row.isPending ? .isStaticText : .isButton)
        .accessibilityAction { if !row.isPending { onOpen() } }
        .modifier(RemoveRowActions(row: row, canAdjust: canAdjust, perform: perform))
    }

    /// The row's master switch: off, the object is back and the removal keeps everything. An eye, as a mask's is.
    private var eye: some View {
        Button { perform(.toggle) } label: {
            Image(systemName: row.isOn ? "eye" : "eye.slash")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(!enabled(.toggle) ? Graphite.tertiaryText : row.isOn ? Graphite.text : Graphite.secondaryText)
                .frame(width: 18, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled(.toggle))
        .help(RemoveRowAction.toggle.help(for: row))
    }

    private var menu: some View {
        Menu {
            MenuEntries(make: menuEntries)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(Graphite.secondaryText)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .graphiteMenu()
        .help("Turn off, make again or delete \(row.title)")
        .accessibilityLabel("\(row.title) actions")
    }

    // MARK: The options

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            MaskCheck(title: RemoveRowAction.effects.title(for: row), isOn: row.includesEffects, help: RemoveRowAction.effects.help(for: row)) {
                perform(.effects)
            }
            .disabled(!enabled(.effects))
            HStack(spacing: Graphite.Metric.xs) {
                button(.tryAgain)
                button(.better)
                Spacer(minLength: Graphite.Metric.s)
                button(.delete, quiet: true)
            }
        }
        .padding(.leading, Self.inset)
        .padding(.trailing, 4)
        .frame(height: Self.optionsHeight, alignment: .top)
    }

    private func button(_ action: RemoveRowAction, quiet: Bool = false) -> some View {
        Button(action.title(for: row)) { perform(action) }
            .buttonStyle(.graphite(quiet ? .quiet : .secondary, size: .small))
            .disabled(!enabled(action))
            .help(action.help(for: row))
    }

    // MARK: What it does

    private func enabled(_ action: RemoveRowAction) -> Bool { action.isEnabled(for: row, canAdjust: canAdjust) }

    private func perform(_ action: RemoveRowAction) {
        action.perform(on: row, frame: frame, canAdjust: canAdjust, with: model)
    }

    /// What the ⋯ and a right-click on the row offer, made as either opens.
    private func menuEntries() -> [MenuEntry] {
        InspectorMenus.removalRow(row, frame: frame, canAdjust: canAdjust, commands: model)
    }
}

/// The one line under a row's name: a wait's spinner, or its bar where it can say how far it is, then the caption's words, with
/// Cancel at its end while the run can be stopped. The face note is a quiet link: its symbol and its words, which a click
/// follows to the face. Nothing else here takes the pointer, and nothing takes the keyboard.
private struct RemoveCaptionLine: View {
    let caption: RemovalRowState.Caption
    let canCancel: Bool
    let cancelHelp: String
    let showFace: () -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLinkHovered = false

    static let height: CGFloat = 14
    /// The bar's size: a step's worth is a few points, enough to see it move.
    static let barWidth: CGFloat = 24, barHeight: CGFloat = 3

    var body: some View {
        // Cancel's own frame is its room: the words run up to it.
        HStack(spacing: 0) {
            if caption.opensFace {
                Button(action: showFace) { words }
                    .buttonStyle(.plain)
                    .onHover { isLinkHovered = $0 }
                    .pointerStyle(.link)
            } else {
                words
            }
            Spacer(minLength: 0)
            if canCancel {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Graphite.secondaryText)
                        .frame(width: 24, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(cancelHelp)
            }
        }
        .frame(height: Self.height)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isLinkHovered)
    }

    private var words: some View {
        HStack(spacing: 5) {
            if caption.isBusy {
                if let progress = caption.progress {
                    bar(progress)
                } else {
                    ProgressView().controlSize(.mini)
                        .frame(width: 12, height: 12)
                }
            } else if let symbol = caption.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .light))
            }
            RollingText(text: caption.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .underline(isLinkHovered, color: Graphite.secondaryText)
        }
        .font(Graphite.Typeface.caption)
        .foregroundStyle(caption.isBusy || isLinkHovered ? Graphite.text : Graphite.secondaryText)
        .contentShape(Rectangle())
    }

    private func bar(_ progress: Double) -> some View {
        Capsule()
            .fill(Graphite.ink(0.14))
            .frame(width: Self.barWidth, height: Self.barHeight)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Graphite.text)
                    .frame(width: max(Self.barHeight, Self.barWidth * min(1, max(0, progress))), height: Self.barHeight)
                    .animation(reduceMotion ? nil : Graphite.Motion.quick, value: progress)
            }
    }
}

/// A row's actions for VoiceOver, named as its controls are.
private struct RemoveRowActions: ViewModifier {
    let row: RemovalRowState
    let canAdjust: Bool
    let perform: (RemoveRowAction) -> Void

    func body(content: Content) -> some View {
        RemoveRowAction.shown(for: row).filter { $0.isEnabled(for: row, canAdjust: canAdjust) }.reduce(AnyView(content)) { view, action in
            AnyView(view.accessibilityAction(named: action.title(for: row)) { perform(action) })
        }
    }
}
