import ArgentCore
import ArgentRoll
import SwiftUI

/// A selected mask's groups of rows, each of which folds under its name (`MaskEditor.openGroups`).
enum MaskGroup: Hashable, Sendable {
    /// The six Light rows.
    case light
    /// Warmth and Magenta.
    case balance
    /// The selected component's gradient as numbers, or a selection's Feather.
    case shape
}

/// The Adjust inspector's Masks tab: the tiles that start a mask, the frame's masks and the selected mask's
/// panel. The tab's Compare and Reset are the inspector's, at its foot. A frame with no mask
/// shows what masks are for and the tiles; one with masks has the tiles in Add's popover, so opening them moves nothing
/// in the list under it, and a choice closes them. Nothing here covers the photograph, and nothing draws glass on the
/// inspector's glass.
struct MasksInspector: View {
    let frame: Frame
    @Environment(RollModel.self) private var model

    /// How many rows the list shows before it scrolls inside itself, with a half row to say there is more.
    static let visibleRows: CGFloat = 4.5
    static let rowSpacing: CGFloat = Graphite.Metric.xs

    var body: some View {
        let editor = model.maskEditor, brush = editor.brush
        // A stroke making its mask or component changes the tab when it lands, not at its press (`MaskBrush.making`).
        let making = brush.making?.frame == frame.url ? brush.making : nil
        let madeMask = making?.target.component == 0 ? making?.target.mask : nil
        let masks = model.masks(for: frame).compactMap { mask in mask.id == madeMask ? nil : brush.shown(mask) }
        VStack(alignment: .leading, spacing: Graphite.Metric.m) {
            if masks.isEmpty {
                MaskPicker(frame: frame)
                guidance
                if let pending = model.brushPendingRow(on: frame) { MaskBrushPendingRow(kind: pending) }
                if editor.tool == .brush { MaskBrushOptions() }
            } else {
                header(count: masks.count)
                guidance
                list(masks)
                if editor.tool == .brush {
                    SectionDivider()
                    MaskBrushOptions()
                }
                if let selected = model.selectedMask(for: frame), selected.id != madeMask {
                    SectionDivider()
                    let shown = brush.shown(selected)
                    MaskPanel(frame: frame, mask: shown,
                              selectedComponent: making.map { min($0.before?.component ?? 0, shown.components.count - 1) } ?? editor.componentIndex)
                        .equatable()
                        .id(InspectorDestination.mask(selected.id))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Masks for this frame")
        // Smart masks: the frame's input picture made ahead of a click, and DA3 kept loaded, while this tab shows.
        .onAppear { model.masksTabAppeared() }
        .task(id: frame.url) { model.masksTabShows(frame) }
        .onDisappear { model.masksTabDisappeared() }
    }

    /// Why no tile is live. The wait for the frame is the picker's own words, under the tiles that wait, and so is a frame
    /// that holds all the masks it can: said in the tab, that line came in between Add and the list as Add's popover opened,
    /// and moved the list the popover is there to leave alone. A tool in
    /// hand says nothing here: the tab stays clean, and how each tool works is left to a tips dialog (the owner,
    /// 2026-11-07).
    @ViewBuilder private var guidance: some View {
        let editor = model.maskEditor
        if editor.tool == nil, model.canAdjust(frame), model.maskCompilerGate(for: frame) == .needsUpdate {
            VStack(alignment: .leading, spacing: Graphite.Metric.s) {
                Text(verbatim: MaskCopy.needsUpdate)
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Update Automatic Baseline") { model.updateAutomaticBaseline(for: frame) }
                    .buttonStyle(.graphite(.secondary, size: .small))
                    .help("Keep the adjustment values and take this frame's starting point again with the current rendering versions. The picture can change.")
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// When Add's popover was last closed by a press outside it, for `addPressed`.
    @State private var pickerDismissed: Date?

    /// How long after its popover closed a press on Add is taken for the press that closed it.
    static let dismissalWindow: TimeInterval = 0.5

    /// Whether a press on Add opens or closes the tiles: not when the popover has only just closed. A press on Add while its
    /// popover is up is a press outside the popover, which closes it as the press goes down; Add's own action follows as the
    /// press comes up, and toggling then would open the popover the same click had closed.
    static func addToggles(dismissed: Date?, now: Date) -> Bool {
        guard let dismissed else { return true }
        return now.timeIntervalSince(dismissed) > dismissalWindow
    }

    /// How many masks the frame has, and Add, whose popover holds the tiles (`MaskPicker`): over the list and not in it, so
    /// the masks under it stay where they are while a kind is chosen.
    private func header(count: Int) -> some View {
        let editor = model.maskEditor
        return InspectorSectionHeader(title: count == 1 ? "1 mask" : "\(count) masks") {
            Button {
                let toggles = Self.addToggles(dismissed: pickerDismissed, now: Date())
                pickerDismissed = nil
                if toggles { editor.isPickerOpen.toggle() }
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.graphite(.secondary, size: .small, isOn: editor.isPickerOpen))
            .help("Start another mask on this frame")
            .accessibilityLabel("Add mask")
            .accessibilityValue(editor.isPickerOpen ? "Tiles shown" : "")
            .popover(isPresented: Binding(get: { editor.isPickerOpen }, set: { shown in
                // Closed by the popover itself, on a press outside it or Escape; a tile's choice closes it through the editor.
                if !shown, editor.isPickerOpen { pickerDismissed = Date() }
                editor.isPickerOpen = shown
            }), arrowEdge: .bottom) {
                MaskPicker(frame: frame)
                    .padding(Graphite.Metric.m)
                    .frame(width: Graphite.Metric.adjustColumn + 2 * Graphite.Metric.m)
                    .environment(model)
            }
        }
    }

    /// One list for every mask, given as values (`MaskList`), so a write that leaves its rows as they were runs no part of it. A step
    /// of a mask's slider writes no edit at all until its release (`MaskEditor.printedValues`).
    private func list(_ masks: [Mask]) -> some View {
        // A brush waiting for its first stroke has its row at the end (`MaskBrushPendingRow`), a mask row's height.
        let pendingMask = model.brushPendingRow(on: frame).flatMap { if case .mask = $0 { $0 } else { nil } }
        return MaskList(frame: frame, masks: masks, names: masks.map { model.maskName($0.id, for: frame) },
                        statuses: masks.map { model.smartStatus(of: $0, for: frame) }, pending: pendingMask,
                        canAdjust: model.canAdjust(frame), canDuplicate: model.canAddMask(frame))
            .equatable()
    }

    /// The list's height for rows of `heights`: all of them up to `visibleRows`, then a half row to say there is more.
    static func listHeight(_ heights: [CGFloat]) -> CGFloat {
        let whole = Int(Self.visibleRows), shown = heights.prefix(whole + 1)
        var total = shown.prefix(whole).reduce(0, +) + CGFloat(max(0, min(heights.count, whole) - 1)) * Self.rowSpacing
        if heights.count > whole, let next = shown.last { total += Self.rowSpacing + next * (Self.visibleRows - CGFloat(whole)) }
        return total
    }
}

/// The mask list. Focused, it takes Delete, the arrows and Return, as the photograph takes Delete: never a menu's, since a focused
/// slider would pass the key on and delete a mask. Everything it shows is given as values, so the tab's body running again for a write
/// that leaves them as they were runs none of it: its scroll view, key handlers and rows (a mask slider's step laid it out again, G).
private struct MaskList: View, Equatable {
    let frame: Frame
    let masks: [Mask]
    let names: [String]
    let statuses: [SmartRowStatus?]
    let pending: MaskBrushPendingRow.Kind?
    let canAdjust: Bool
    let canDuplicate: Bool
    @Environment(RollModel.self) private var model
    @FocusState private var listFocused: Bool
    /// The list took the keyboard from a click on a row: no bar on the row and no ring for that, as the app's controls draw none for a pointer.
    @State private var focusedByPointer = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.frame == b.frame && a.masks == b.masks && a.names == b.names && a.statuses == b.statuses && a.pending == b.pending
            && a.canAdjust == b.canAdjust && a.canDuplicate == b.canDuplicate
    }

    var body: some View {
        let editor = model.maskEditor
        let heights = statuses.map(MaskRow.height(for:)) + (pending == nil ? [] : [MaskRow.height])
        let hasKeyboard = listFocused && !focusedByPointer
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(spacing: MasksInspector.rowSpacing) {
                    // What each row shows, given as values, so a write of one mask's slider runs only that mask's row (T9).
                    ForEach(Array(masks.enumerated()), id: \.element.id) { index, mask in
                        MaskRow(frame: frame, mask: mask, name: names[index], canAdjust: canAdjust, canDuplicate: canDuplicate,
                                status: statuses[index], listHasKeyboard: hasKeyboard, onMenu: takeKeyboardFromPointer)
                            .equatable()
                            .id(mask.id)
                            .simultaneousGesture(TapGesture().onEnded(takeKeyboardFromPointer))
                    }
                    if let pending { MaskBrushPendingRow(kind: pending).id("pending brush") }
                }
            }
            .frame(height: MasksInspector.listHeight(heights))
            .scrollDisabled(CGFloat(heights.count) <= MasksInspector.visibleRows && !statuses.contains { $0?.hasActionLine == true })
            .scrollIndicators(.automatic)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            // Reached by Tab, the selected row says so (`MaskRow.listHasKeyboard`): a ring round the list would be a box round that row's box.
            // With no row selected there is nothing to say it, and the list draws the ring the controls do.
            .overlay {
                if hasKeyboard, !masks.contains(where: { $0.id == editor.selection?.mask }) {
                    RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius + 2, style: .continuous)
                        .strokeBorder(Graphite.selection, lineWidth: Graphite.Metric.focusRing)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: listFocused) { _, focused in if !focused { focusedByPointer = false } }
            // The row that shows the keyboard has to be in sight.
            .onChange(of: hasKeyboard) { _, has in if has, let id = editor.selection?.mask { reader.scrollTo(id) } }
            .accessibilityLabel("Mask list")
            .onChange(of: editor.selection?.mask, initial: true) { _, id in if let id { reader.scrollTo(id) } }
            // Under a workspace sheet the list's keys are the sheet's.
            .onKeyPress(.upArrow) { model.isSheetShown ? .ignored : step(-1) }
            .onKeyPress(.downArrow) { model.isSheetShown ? .ignored : step(1) }
            .onKeyPress(.return) {
                guard !model.isSheetShown, let id = editor.selection?.mask, editor.renaming == nil else { return .ignored }
                editor.renaming = id
                return .handled
            }
            .onKeyPress(.escape) {
                guard !model.isSheetShown else { return .ignored }
                if !editor.escape() { listFocused = false; editor.requestPhotographFocus() }
                return .handled
            }
            .onKeyPress(keys: MaskKeys.delete) { _ in !model.isSheetShown && editor.deleteSelection() ? .handled : .ignored }
        }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        model.selectMask(by: offset, for: frame)
        return .handled
    }

    /// A click or a right-click on a row gives the list the keyboard, drawing no bar or ring for it.
    private func takeKeyboardFromPointer() {
        focusedByPointer = true
        listFocused = true
    }
}

/// The selected mask's panel: its name, how its shape is built, the overlay and Invert, then Amount and the
/// six Light rows at zero, its Balance, and last the numbers of the gradient its handles move. A mask owns the adjustments,
/// Amount and name; its components own only the shape (R1). Each row is the Light tab's own
/// (`ManualAdjustmentRow`), with its scrubbing, keys, double-click reset and Option clipping view. A row's gesture
/// writes the print alone until it ends (`RollModel.moveMaskValue`), so a slider's drag runs none of the tab but the
/// dragged row's number; the edit, written once at its end, runs this body, and the parts with menus take what they
/// show as values and compare equal, so they are not built again for it (T9: the tab's menus, rebuilt at each step
/// of a mask slider's drag, cost it most of its refreshes).
private struct MaskPanel: View, Equatable {
    let frame: Frame
    let mask: Mask
    let selectedComponent: Int
    @Environment(RollModel.self) private var model

    /// What the panel shows is these and what its body reads of the model, which observation follows: a write elsewhere in the tab,
    /// or a stroke's press that the tab holds back, does not build its rows again.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.frame == b.frame && a.mask == b.mask && a.selectedComponent == b.selectedComponent
    }

    var body: some View {
        let canAdjust = model.canAdjust(frame), name = model.maskName(mask.id, for: frame)
        let editor = model.maskEditor, component = min(selectedComponent, mask.components.count - 1)
        VStack(alignment: .leading, spacing: 0) {
            MaskPanelHeading(frame: frame, name: name, invert: mask.components[component].invert, canAdjust: canAdjust)
                .equatable()
            VStack(spacing: Graphite.Metric.xs) {
                ForEach(mask.components.indices, id: \.self) { index in
                    MaskComponentRow(frame: frame, maskID: mask.id, component: mask.components[index], index: index, canAdjust: canAdjust)
                        .equatable()
                }
                if let pending = model.brushPendingRow(on: frame), case .component = pending { MaskBrushPendingRow(kind: pending) }
            }
            .padding(.top, Graphite.Metric.s)
            MaskOperationsRow(frame: frame, canAdd: model.canAddComponent(for: frame))
                .equatable()
                .padding(.top, AdjustRowMetric.rowSpacing)
            // Amount scales everything the mask does, so it stays out of the groups and in reach.
            amountRow
                .disabled(!canAdjust)
                .padding(.top, AdjustRowMetric.pairSpacing)
                .padding(.bottom, Graphite.Metric.m)
            InspectorGroup(title: "Light", summary: MaskSummary.light(of: mask), isOpen: editor.openGroups.contains(.light),
                           toggle: { editor.toggle(.light) }) {
                VStack(spacing: 0) {
                    ForEach(Array(ManualAdjustments.Control.allCases.enumerated()), id: \.element) { index, control in
                        lightRow(control)
                            .padding(.top, index == 0 ? 0 : index.isMultiple(of: 2) ? AdjustRowMetric.pairSpacing : AdjustRowMetric.rowSpacing)
                    }
                }
                .disabled(!canAdjust)
            }
            InspectorGroup(title: "Balance", summary: MaskSummary.balance(of: mask), isOpen: editor.openGroups.contains(.balance),
                           toggle: { editor.toggle(.balance) }) {
                VStack(spacing: AdjustRowMetric.rowSpacing) {
                    ForEach(MaskBalanceControl.allCases, id: \.self) { control in
                        balanceRow(control)
                    }
                }
                .disabled(!canAdjust)
            }
            MaskShapeRows(frame: frame, maskID: mask.id, component: component, shape: mask.components[component].shape,
                          isOpen: editor.openGroups.contains(.shape))
                .equatable()
                .disabled(!canAdjust)
        }
    }

    // MARK: Amount and Light

    private func beginAdjusting() { model.beginMaskAdjusting(for: frame) }

    private func endAdjusting() { model.endMaskAdjusting(for: frame) }

    /// Amount reads 0 to 200 and is stored as a hundredth of that. The binding reads the edit, which a row's gesture leaves alone
    /// until it ends; the row shows its gesture's own newest value meanwhile (`ManualAdjustmentRow`).
    private var amountRow: some View {
        let id = mask.id
        return ManualAdjustmentRow(spec: .maskAmount,
                                   help: "Scale everything this mask does. At 0 it changes nothing, and at 200 it does twice as much.",
                                   value: Binding(get: { ((model.mask(id, for: frame)?.amount ?? 1) * 100).rounded() },
                                                  set: { model.moveMaskAmount($0 / 100, mask: id, for: frame) }),
                                   snapshot: mask, beginGesture: beginAdjusting, endGesture: endAdjusting)
            .equatable()
    }

    private func balanceRow(_ control: MaskBalanceControl) -> some View {
        let id = mask.id
        return ManualAdjustmentRow(spec: .maskBalance(control), help: control.help,
                                   value: Binding(get: { model.mask(id, for: frame).map { control.value(in: $0.balance) } ?? 0 },
                                                  set: { model.moveMaskBalance(control, to: $0, mask: id, for: frame) }),
                                   snapshot: mask, beginGesture: beginAdjusting, endGesture: endAdjusting)
            .equatable()
    }

    private func lightRow(_ control: ManualAdjustments.Control) -> some View {
        let id = mask.id
        return ManualAdjustmentRow(spec: .light(control, group: .mask), help: control.adjustmentHelp,
                                   value: Binding(get: { model.mask(id, for: frame)?.adjustments.value(for: control) ?? 0 },
                                                  set: { model.moveMaskValue(control, to: $0, mask: id, for: frame) }),
                                   snapshot: mask, beginGesture: beginAdjusting, endGesture: endAdjusting)
            .equatable()
    }
}

/// Add, Subtract and Intersect: each a menu of what to do it with, whose choice puts that tool in hand, and the next
/// drag on the photograph is the new component. Its own view, equal while what it shows is (`MaskPanel`).
private struct MaskOperationsRow: View, Equatable {
    let frame: Frame
    let canAdd: Bool
    @Environment(RollModel.self) private var model

    nonisolated static func == (a: Self, b: Self) -> Bool { a.frame == b.frame && a.canAdd == b.canAdd }

    var body: some View {
        HStack(spacing: Graphite.Metric.xs) {
            ForEach(MaskOperation.allCases, id: \.self) { operation in
                Menu {
                    ForEach([MaskEditor.Tool.linear, .radial], id: \.self) { tool in
                        Button(tool.title) { model.perform(.addShape(tool, operation)) }
                    }
                } label: {
                    MaskOperationFace(title: operation.title)
                }
                .menuStyle(.button)
                .buttonStyle(MaskPressStyle())
                .menuIndicator(.hidden)
                .help("\(operation.title) another shape in this mask")
                .accessibilityLabel("\(operation.title) a shape")
            }
        }
        .disabled(!canAdd)
    }
}

/// The selected mask's name, with its two switches beside it: Overlay, in the overlay's colour, with the colours in a menu
/// at its end, and Invert, for the selected component. Its own view, equal while what it shows is.
private struct MaskPanelHeading: View, Equatable {
    let frame: Frame
    let name: String
    let invert: Bool
    let canAdjust: Bool
    @Environment(RollModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.frame == b.frame && a.name == b.name && a.invert == b.invert && a.canAdjust == b.canAdjust
    }

    /// A switch's face: as tall as the row's own type allows beside a name.
    static let height: CGFloat = 22

    var body: some View {
        let editor = model.maskEditor
        HStack(spacing: 6) {
            Text(verbatim: name)
                .font(Graphite.Typeface.chipTitle)
                .foregroundStyle(Graphite.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            overlay(editor)
            face(isOn: invert) {
                Button { model.invertSelectedComponent(for: frame) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 10, weight: .light))
                            .accessibilityHidden(true)
                        Text("Invert")
                    }
                    .padding(.horizontal, 7)
                    .frame(height: Self.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MaskPressStyle())
                .help("Select the other side of this shape. The ' key does too.")
                .accessibilityLabel("Invert")
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(invert ? "On" : "Off")
            }
            .opacity(canAdjust ? 1 : 0.42)
            .disabled(!canAdjust)
        }
        .frame(height: 24)
    }

    /// Overlay: its switch, and at its end the menu of its colours.
    private func overlay(_ editor: MaskEditor) -> some View {
        face(isOn: editor.isOverlayOn) {
            HStack(spacing: 0) {
                Button { editor.setOverlay(on: !editor.isOverlayOn) } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(editor.overlayColour.color)
                            .overlay { Circle().strokeBorder(Graphite.border, lineWidth: 1) }
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                        Text("Overlay")
                    }
                    .padding(.leading, 7)
                    .padding(.trailing, 3)
                    .frame(height: Self.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MaskPressStyle())
                .help("Keep this mask's overlay up. O shows or hides it.")
                .accessibilityLabel("Show overlay")
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(editor.isOverlayOn ? "On" : "Off")
                Menu {
                    ForEach(MaskOverlayColour.allCases, id: \.self) { colour in
                        Toggle(colour.title, isOn: Binding(get: { editor.overlayColour == colour }, set: { _ in editor.overlayColour = colour }))
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Graphite.secondaryText)
                        .frame(width: 16, height: Self.height)
                        .contentShape(Rectangle())
                }
                .graphiteMenu()
                .help("The overlay's colour. Shift-O changes it.")
                .accessibilityLabel("Overlay colour")
                .accessibilityValue(editor.overlayColour.title)
            }
        }
    }

    /// A switch drawn as a small button on the glass: a fine edge, and filled while it is on.
    private func face(isOn: Bool, @ViewBuilder content: () -> some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.segmentRadius, style: .continuous)
        return content()
            .font(Graphite.Typeface.caption)
            .foregroundStyle(isOn ? Graphite.text : Graphite.secondaryText)
            .background(shape.fill(Graphite.ink(isOn ? 0.13 : 0)))
            .overlay { shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1) }
            .fixedSize()
    }
}

/// The selected component's gradient as numbers, for a keyboard: what its handles do, and Feather; a smart selection's Feather. While a press
/// on the photograph moves the gradient they follow the print (`MaskEditor.printed`), which with the overlay and
/// the handles is all that does before the release; a view of their own, so the rest of the panel does not. It takes
/// the component's shape as a value and compares equal while that is unchanged, so a step of Amount or a Light slider
/// does not build its four to six rows again (measured, G: each part of the panel rebuilt at a step costs that drag).
private struct MaskShapeRows: View, Equatable {
    let frame: Frame
    let maskID: UUID
    let component: Int
    let shape: MaskShape
    /// The group is open (`MaskEditor.openGroups`): folded, its rows are not built, and a handle dragged on the photograph
    /// runs its name's line alone.
    let isOpen: Bool
    @Environment(RollModel.self) private var model

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.frame == b.frame && a.maskID == b.maskID && a.component == b.component && a.shape == b.shape && a.isOpen == b.isOpen
    }

    var body: some View {
        let shape = model.maskEditor.printedShape(of: maskID, component: component, on: frame) ?? self.shape
        let fields = MaskShapeField.fields(of: shape)
        if !fields.isEmpty {
            InspectorGroup(title: MaskShapeField.heading(of: shape), summary: summary(of: fields, in: shape), isOpen: isOpen,
                           toggle: { model.maskEditor.toggle(.shape) }) {
                VStack(alignment: .leading, spacing: AdjustRowMetric.rowSpacing) {
                    ForEach(fields.indices, id: \.self) { order in
                        row(fields[order], order: order, shape: shape)
                    }
                }
            }
            .id(component)
        }
    }

    /// What the folded group says beside its name: its Feather, the one of a shape's numbers that is not a place on the
    /// picture; nothing for a linear gradient, which has none.
    private func summary(of fields: [MaskShapeField], in shape: MaskShape) -> String {
        guard let index = fields.firstIndex(where: { $0 == .feather || $0 == .selectionFeather }) else { return "" }
        let field = fields[index], spec = field.spec(default: field.tool.flatMap { model.placedShape($0, for: frame) }, order: 10 + index)
        return "\(field.title) \(spec.formatted(spec.snapped(field.value(in: shape) ?? spec.defaultValue)))"
    }

    private func row(_ field: MaskShapeField, order: Int, shape: MaskShape) -> some View {
        let id = maskID, component = component, spec = field.spec(default: field.tool.flatMap { model.placedShape($0, for: frame) }, order: 10 + order)
        return ManualAdjustmentRow(spec: spec, help: field.help,
                                   value: Binding(get: {
                                       // On the row's own resolution, so an untouched field commits no change.
                                       let now = model.maskEditor.printedShape(of: id, component: component, on: frame)
                                           ?? model.mask(id, for: frame)?.components[safe: component]?.shape
                                       return spec.snapped(now.flatMap { field.value(in: $0) } ?? spec.defaultValue)
                                   }, set: { number in
                                       guard let now = model.mask(id, for: frame)?.components[safe: component]?.shape,
                                             let updated = field.setting(number, in: now) else { return }
                                       model.setComponentShape(updated, of: id, component: component, for: frame)
                                   }),
                                   snapshot: shape,
                                   beginGesture: {
                                       model.beginManualGesture(for: frame)
                                       model.maskEditor.shapeRowBegan()
                                   },
                                   endGesture: {
                                       model.maskEditor.shapeRowEnded()
                                       model.endManualGesture(for: frame, actionName: MaskShapeField.actionName(of: shape))
                                   })
    }
}

/// A press on a control that draws its own face and its own disabled look: `.plain` dims a disabled control again over that, which took
/// words held at 4.5 to 1 down to 2.5 (measured on screen, Middle gray Dark, task R).
struct MaskPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Add, Subtract or Intersect's face: the three share the row's 240 points, which a `MenuFace` apiece would not
/// fit, and are drawn plainly on the inspector's glass.
private struct MaskOperationFace: View {
    let title: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        let edge = contrast == .increased ? Graphite.strongBorder : Graphite.border
        HStack(spacing: Graphite.Metric.xs) {
            Text(verbatim: title)
                .font(Graphite.Typeface.small)
                .foregroundStyle(isEnabled ? Graphite.text : Graphite.tertiaryText)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isEnabled ? Graphite.secondaryText : Graphite.tertiaryText)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: Graphite.Metric.controlHeight)
        .background(shape.fill(Graphite.ink(isEnabled ? MaskTileStyle.restInk : MaskTileStyle.disabledInk)))
        // A tile that cannot be used, as `MaskTileStyle` draws one: dimmed by its edge and its words, which still read at 4.5 to 1.
        .overlay {
            shape.strokeBorder(edge, style: StrokeStyle(lineWidth: 1, dash: isEnabled ? [] : MaskTileStyle.disabledDash))
        }
        .contentShape(shape)
    }
}

/// A small check in the theme's own colours: Graphite has no accent for a system checkbox to draw in.
struct MaskCheck: View {
    let title: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.square" : "square")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(!isEnabled ? Graphite.tertiaryText : isOn ? Graphite.text : Graphite.secondaryText)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(isEnabled ? Graphite.text : Graphite.tertiaryText)
                    .fixedSize()
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(MaskPressStyle())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
