import ArgentCore
import ArgentRoll
import SwiftUI

/// A mask's two balance sliders. Lab balance's own words, since this is that move on part of the frame (`docs/SPEC.md`'s vocabulary).
enum MaskBalanceControl: CaseIterable, Hashable {
    case warmth, magenta

    var title: String {
        switch self {
        case .warmth: "Warmth"
        case .magenta: "Magenta"
        }
    }

    var help: String {
        switch self {
        case .warmth: "Print the mask's part of the frame warmer or cooler, as Lab balance does the whole frame."
        case .magenta: "Print the mask's part of the frame toward magenta or green, as Lab balance does the whole frame."
        }
    }

    /// The control a drive command names ("warmth"), as `ManualAdjustments.Control`'s raw value names a Light control.
    init?(named name: String) {
        guard let control = Self.allCases.first(where: { $0.title.lowercased() == name.lowercased() }) else { return nil }
        self = control
    }

    func value(in balance: MaskBalance) -> Float {
        switch self {
        case .warmth: balance.warmth
        case .magenta: balance.magenta
        }
    }

    func setting(_ value: Float, in balance: MaskBalance) -> MaskBalance {
        var result = balance
        switch self {
        case .warmth: result.warmth = value
        case .magenta: result.magenta = value
        }
        return result
    }
}

/// What a mask's row says it does. Pure, so `AdjustInspectorStateTests` holds the words.
enum MaskSummary {
    /// A shape in the panel's words.
    static func title(of shape: MaskShape) -> String {
        switch shape {
        case .linear: "Linear"
        case .radial: "Radial"
        case .brush: "Brush"
        case .smart(let selection): selection.kind.rawValue.capitalized
        }
    }

    /// The row's second line: the sliders that are moved, as the Light rows read them, with Amount if it is
    /// not at its default. With none moved, what it is: "No changes" is a folded group's, in the selected mask's panel.
    static func line(for mask: Mask) -> String {
        let moved = movedLight(mask) + movedBalance(mask)
        if moved.isEmpty {
            let more = mask.components.count - 1
            let title = mask.components.first.map { component -> String in
                // A gradient says so; a brush is its strokes, a smart mask its kind.
                switch component.shape {
                case .linear, .radial: "\(title(of: component.shape)) gradient"
                case .brush: "Brush strokes"
                case .smart: title(of: component.shape)
                }
            } ?? "Mask"
            return more > 0 ? "\(title) and \(more) more" : title
        }
        let amount = (mask.amount * 100).rounded()
        return (moved + (amount == 100 ? [] : ["Amount \(AdjustmentSliderSpec.maskAmount.formatted(amount))"])).joined(separator: ", ")
    }

    /// The mask's Light rows that are moved, as the rows read them, and its balance's.
    private static func movedLight(_ mask: Mask) -> [String] {
        ManualAdjustments.Control.allCases.compactMap { control in
            let value = mask.adjustments.value(for: control)
            return value == 0 ? nil : "\(control.title) \(AdjustmentSliderSpec.light(control).formatted(value))"
        }
    }

    private static func movedBalance(_ mask: Mask) -> [String] {
        MaskBalanceControl.allCases.compactMap { control in
            let value = control.value(in: mask.balance)
            return value == 0 ? nil : "\(control.title) \(AdjustmentSliderSpec.maskBalance(control).formatted(value))"
        }
    }

    /// What a folded group says with none of its rows moved.
    static let unmoved = "No changes"

    /// What the panel's Light group says beside its name while it is folded: its rows that are moved, as the list's row says them.
    static func light(of mask: Mask) -> String {
        let moved = movedLight(mask)
        return moved.isEmpty ? unmoved : moved.joined(separator: ", ")
    }

    /// The same for its Balance group.
    static func balance(of mask: Mask) -> String {
        let moved = movedBalance(mask)
        return moved.isEmpty ? unmoved : moved.joined(separator: ", ")
    }

    /// What VoiceOver says of a row after its name: selected or not, on or off, then what its status says or what it does.
    static func spoken(_ mask: Mask, isSelected: Bool, status: SmartRowStatus?) -> String {
        (isSelected ? "Selected, " : "") + (mask.isEnabled ? "on, " : "off, ") + (status?.text ?? line(for: mask))
    }
}

/// One row of the mask list: its switch, a small picture of what it covers, its name and what it does, and its
/// menu. Everything a mask owns is here or in the panel under the list; a click selects it, the pointer resting
/// on it shows its overlay. A right-click selects it too and opens the ⋯'s menu, one table (`InspectorMenus.maskRow`).
/// One element for VoiceOver, with its actions named.
struct MaskRow: View, Equatable {
    let frame: Frame
    let mask: Mask
    /// What the row shows of the frame's edit beyond the mask, given as values with it, so a row whose mask a
    /// write left as it was compares equal and is not built again (`MaskPanel`, T9).
    let name: String
    let canAdjust: Bool
    let canDuplicate: Bool
    /// What a smart mask's row says of its selection while it is not simply made (`RollModel.smartStatus`).
    var status: SmartRowStatus? = nil
    /// Tab has brought the keyboard to the list, whose arrows and Return act on the selected row: that row says so, in place of a ring round the list.
    var listHasKeyboard = false
    /// A right-click selected the row: the list takes the keyboard, as a click on the row gives it (`MaskList`). Not compared, being
    /// what the row does rather than what it shows.
    var onMenu: (() -> Void)? = nil
    @Environment(RollModel.self) private var model
    @State private var isHovered = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    static let height: CGFloat = 44
    /// The line of a smart row's buttons under it: Paint It Instead and Remove, Try Again, Update and Keep. Their 28 points, and room above
    /// the row's foot: at 28 they ran into the selection ring (R).
    static let actionLineHeight: CGFloat = 34

    /// A row's height with what its status shows.
    static func height(for status: SmartRowStatus?) -> CGFloat { height + (status?.hasActionLine == true ? actionLineHeight : 0) }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.frame == b.frame && a.mask == b.mask && a.name == b.name && a.canAdjust == b.canAdjust && a.canDuplicate == b.canDuplicate
            && a.status == b.status && a.listHasKeyboard == b.listHasKeyboard
    }

    var body: some View {
        let editor = model.maskEditor, isSelected = editor.selection?.mask == mask.id
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            line(editor: editor)
                .frame(height: Self.height)
            if let status, status.hasActionLine { actionLine(status) }
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(height: Self.height(for: status), alignment: .top)
        .background { if isHovered { shape.fill(Graphite.hoverFill) } }
        .overlay { if isSelected { shape.strokeBorder(Graphite.selection, lineWidth: Graphite.Metric.selectionWidth) } }
        // A bar in the row's left margin, against the ring. A fill would say the same but costs the words their contrast: 0.08 of ink
        // already took one theme's under 4.5 to 1, where the bar is the selection's colour and lies under no words.
        .overlay(alignment: .leading) {
            if isSelected, listHasKeyboard {
                Capsule()
                    .fill(Graphite.selection)
                    .frame(width: 3, height: 20)
                    .padding(.leading, Graphite.Metric.selectionWidth)
                    .frame(height: Self.height, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // The ⋯'s menu, for the row selected first; not while its name is typed in, whose field has its own.
        .rowMenu(isActive: editor.renaming != mask.id, onOpen: { select(); onMenu?() }, entries: menuEntries)
        .contentShape(shape)
        .onTapGesture { select() }
        .onHover { over in
            isHovered = over
            if over {
                editor.hover = .mask(mask.id)
            } else if editor.hover == .mask(mask.id) {
                editor.hover = nil
            }
        }
        .onDisappear { if editor.hover == .mask(mask.id) { editor.hover = nil } }
        .help(status.map { $0.detail ?? $0.text } ?? MaskSummary.line(for: mask))
        // One element with its actions named, but for the name field while it is open, which has to be reached.
        .accessibilityElement(children: editor.renaming == mask.id ? .contain : .ignore)
        .accessibilityLabel("\(name) mask")
        .accessibilityValue(MaskSummary.spoken(mask, isSelected: isSelected, status: status))
        .accessibilityHint("Selects this mask. Its Amount and adjustments are in the panel after the list.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityActions {
            // As the row's menu: nothing it offers can be done to a frame that cannot be adjusted.
            if canAdjust {
                Button(mask.isEnabled ? "Turn off" : "Turn on", action: toggle)
                Button("Invert") { select(); model.invertSelectedComponent(for: frame) }
                // A turn later: focus asked for inside the accessibility action's own turn does not take, and the field closes.
                Button("Rename") {
                    select()
                    DispatchQueue.main.async { editor.renaming = mask.id }
                }
                if canDuplicate { Button("Duplicate") { model.duplicateMask(mask.id, for: frame) } }
                Button("Delete") { model.deleteMask(mask.id, for: frame) }
            }
        }
        .modifier(SmartRowActions(actions: (status?.actions ?? []).filter { $0 == .cancel || canAdjust }) { model.perform($0, on: mask.id, for: frame) })
    }

    /// The row's one line: its switch, its picture, its name and what it does, and its menu; while a selection is found, a spinner
    /// in the picture's place, the wait in words, and Cancel in the menu's.
    private func line(editor: MaskEditor) -> some View {
        HStack(spacing: Graphite.Metric.s) {
            switchButton
            // A row with buttons under it has nothing to picture yet, and its words need the room.
            if status?.hasActionLine != true { thumbnail }
            VStack(alignment: .leading, spacing: 1) {
                if editor.renaming == mask.id {
                    nameField
                } else {
                    Text(verbatim: name)
                        .font(Graphite.Typeface.label)
                        .foregroundStyle(mask.isEnabled ? Graphite.text : Graphite.secondaryText)
                        .lineLimit(1)
                }
                if let status {
                    HStack(spacing: 4) {
                        Text(verbatim: status.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(Graphite.Typeface.caption)
                    .foregroundStyle(status.isBusy ? Graphite.text : Graphite.secondaryText)
                } else {
                    Text(verbatim: MaskSummary.line(for: mask))
                        .font(Graphite.Typeface.caption)
                        .foregroundStyle(Graphite.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status?.actions.contains(.cancel) == true {
                cancelButton
            } else {
                menu(name: name)
            }
        }
    }

    /// Cancel, in the menu's place while a selection is found: the click undone.
    private var cancelButton: some View {
        Button { model.perform(.cancel, on: mask.id, for: frame) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Graphite.secondaryText)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(SmartRowStatus.Action.cancel.help)
        .accessibilityLabel("Cancel")
    }

    /// The buttons under a smart row's name: what can be done about its selection, small and plain on the inspector's glass.
    private func actionLine(_ status: SmartRowStatus) -> some View {
        HStack(spacing: Graphite.Metric.xs) {
            ForEach(status.actions.filter { $0 != .cancel }, id: \.self) { action in
                Button(action.title) { model.perform(action, on: mask.id, for: frame) }
                    .buttonStyle(.graphite(.secondary, size: .small))
                    .help(action.help)
                    .disabled(!canAdjust)
            }
            Spacer(minLength: 0)
        }
        // Under the name, past the switch.
        .padding(.leading, 18 + Graphite.Metric.s)
        .frame(height: Self.actionLineHeight - 4, alignment: .top)
    }

    private func select() {
        model.maskEditor.selection = MaskEditor.Selection(mask: mask.id, component: nil)
    }

    private func toggle() { model.setMaskEnabled(!mask.isEnabled, mask: mask.id, for: frame) }

    /// The mask's master switch: off, it changes no pixel and keeps everything. An eye, as Lightroom's, since
    /// it hides what the mask does; the overlay has its own.
    private var switchButton: some View {
        Button(action: toggle) {
            Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(mask.isEnabled ? Graphite.text : Graphite.secondaryText)
                .frame(width: 18, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canAdjust)
        .help(mask.isEnabled ? "Turn this mask off. It stays as it is." : "Turn this mask on.")
    }

    /// What it covers, the theme's text on the bed of a thumbnail, for telling rows apart at a glance; a spinner while a selection
    /// is being found.
    @ViewBuilder private var thumbnail: some View {
        let busy = status?.isBusy == true
        let picture = busy ? nil : model.maskEditor.overlay.thumbnail(of: mask.components, portrait: frame.info.isPortrait)
        ZStack {
            RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius, style: .continuous).fill(Graphite.well)
            if busy {
                if let progress = status?.progress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini)
                } else {
                    ProgressView().controlSize(.mini)
                }
            } else if let picture {
                Image(decorative: picture, scale: 2)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Graphite.text)
                    .opacity(mask.isEnabled ? 1 : 0.5)
            }
        }
        .frame(width: 36, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius, style: .continuous)
                .strokeBorder(Graphite.border, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var nameField: some View {
        TextField("Mask name", text: $draftName)
            .textFieldStyle(.plain)
            .font(Graphite.Typeface.label)
            .foregroundStyle(Graphite.text)
            .focused($nameFocused)
            // The field's prompt is no label of VoiceOver's.
            .accessibilityLabel("Mask name")
            .onAppear {
                draftName = name
                nameFocused = true
            }
            .onSubmit(commitName)
            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            .onKeyPress(.escape) {
                model.maskEditor.renaming = nil
                return .handled
            }
    }

    private func commitName() {
        guard model.maskEditor.renaming == mask.id else { return }
        model.maskEditor.renaming = nil
        model.renameMask(mask.id, to: draftName, for: frame)
    }

    /// What the ⋯ and a right-click on the row offer, made as either opens.
    private func menuEntries() -> [MenuEntry] {
        InspectorMenus.maskRow(mask, frame: frame, canAdjust: canAdjust, canDuplicate: canDuplicate, model: model)
    }

    private func menu(name: String) -> some View {
        Menu {
            MenuEntries(make: menuEntries)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(Graphite.secondaryText)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .graphiteMenu()
        .disabled(!canAdjust)
        .help("Rename, invert, duplicate or delete \(name)")
        .accessibilityLabel("\(name) actions")
    }
}

/// One component in the selected mask's panel: what shape it is, how it joins the ones before it, and its menu.
/// A click selects it, for Invert, the handles and Delete; the pointer resting on it shows it alone. A right-click
/// selects it too and opens the ⋯'s menu, one table (`InspectorMenus.componentRow`).
struct MaskComponentRow: View, Equatable {
    let frame: Frame
    let maskID: UUID
    /// The component as values, not its mask, so a write of the mask's sliders leaves the row equal and unbuilt (T9).
    let component: MaskComponent
    let index: Int
    let canAdjust: Bool
    @Environment(RollModel.self) private var model
    @State private var isHovered = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.frame == b.frame && a.maskID == b.maskID && a.component == b.component && a.index == b.index && a.canAdjust == b.canAdjust
    }

    var body: some View {
        let editor = model.maskEditor, isSelected = editor.selection?.mask == maskID && editor.selection?.component == index
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        let title = MaskSummary.title(of: component.shape) + (component.invert ? ", inverted" : "")
        HStack(spacing: Graphite.Metric.s) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Graphite.secondaryText)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(Graphite.Typeface.label)
                .foregroundStyle(Graphite.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: component.operation.symbol)
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Graphite.secondaryText)
                .help(component.operation.title)
                .accessibilityHidden(true)
            menu
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(height: Graphite.Metric.controlHeight)
        .background { if isHovered { shape.fill(Graphite.hoverFill) } }
        .overlay { if isSelected { shape.strokeBorder(Graphite.selection, lineWidth: Graphite.Metric.selectionWidth) } }
        .rowMenu(onOpen: select, entries: menuEntries)
        .contentShape(shape)
        .onTapGesture { select() }
        .onHover { over in
            isHovered = over
            if over {
                editor.hover = .component(maskID, index)
            } else if editor.hover == .component(maskID, index) {
                editor.hover = nil
            }
        }
        .onDisappear { if editor.hover == .component(maskID, index) { editor.hover = nil } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue((isSelected ? "Selected, " : "") + component.operation.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityActions {
            if canAdjust {
                Button("Invert") { select(); model.invertSelectedComponent(for: frame) }
                // The menu's choices. The first of a mask is always added.
                if index > 0 {
                    ForEach(MaskOperation.allCases.filter { $0 != component.operation }, id: \.self) { operation in
                        Button("Change to \(operation.title)") { model.setComponentOperation(operation, component: index, of: maskID, for: frame) }
                    }
                }
                Button("Remove") { model.removeComponent(index, of: maskID, for: frame) }
            }
        }
    }

    private var symbol: String {
        switch component.shape {
        case .linear: MaskTile.linear.symbol
        case .radial: MaskTile.radial.symbol
        case .brush: MaskTile.brush.symbol
        case .smart(let selection): selection.kind.tile.symbol
        }
    }

    private func select() {
        model.maskEditor.selection = MaskEditor.Selection(mask: maskID, component: index)
    }

    /// What the ⋯ and a right-click on the row offer, made as either opens.
    private func menuEntries() -> [MenuEntry] {
        InspectorMenus.componentRow(component, index: index, of: maskID, frame: frame, canAdjust: canAdjust, model: model)
    }

    private var menu: some View {
        Menu {
            MenuEntries(make: menuEntries)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(Graphite.secondaryText)
                .frame(width: 24, height: Graphite.Metric.controlHeight)
                .contentShape(Rectangle())
        }
        .graphiteMenu()
        .disabled(!canAdjust)
        .help("Invert or remove this component")
        .accessibilityLabel("Actions")
    }
}

/// A smart row's actions for VoiceOver, named as the buttons are.
private struct SmartRowActions: ViewModifier {
    let actions: [SmartRowStatus.Action]
    let perform: (SmartRowStatus.Action) -> Void

    func body(content: Content) -> some View {
        actions.reduce(AnyView(content)) { view, action in
            AnyView(view.accessibilityAction(named: action.title) { perform(action) })
        }
    }
}
