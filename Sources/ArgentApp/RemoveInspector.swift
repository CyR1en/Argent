import ArgentCore
import ArgentRoll
import SwiftUI

/// The Remove tab's own words. A row's caption says the seam's (`RemovalRowState.Caption`), and a row's controls their table's
/// (`RemoveRowAction`).
enum RemoveCopy {
    /// Under the Remove button while nothing is selected.
    static let hint = "Paint over an object, or click it."
    static let removeHelp = "Remove what is selected, with its shadow and reflections (Return)"
    /// Under Snap to Object's name, while this Mac can.
    static let snapNote = "A stroke or a click selects the whole object."

    /// The list's heading: how many removals the frame has, a run that has no patch yet among them.
    static func count(_ rows: Int) -> String { rows == 1 ? "1 removal" : "\(rows) removals" }
    static let sizeHelp = "The brush’s width, as a share of the picture’s longer side. ] and [ change it."

    /// Snap to Object's help: what it does, or why this Mac cannot.
    static func snapHelp(_ availability: ObjectSelector.Availability) -> String {
        switch availability {
        case .ready:
            return "A stroke or a click selects the whole object under it. Off, the selection is what you paint."
        case .downloading:
            return "macOS is downloading what Snap to Object needs. Until then the selection is what you paint."
        case .unavailable(let why):
            let reason = why.hasSuffix(".") ? String(why.dropLast()) : why
            return "\(reason). The selection is what you paint."
        }
    }
}

/// Which row of the Remove tab has its options open.
enum RemoveList {
    /// The open row after the frame's rows went from `old` to `new`: a removal that has just arrived, so Try Again is one click
    /// from its result, and with none arrived the row that was open, if it is still a removal. The tab's first rows count as
    /// arrived, so a frame's newest removal is open when the tab comes.
    static func opened(_ open: UUID?, from old: [RemovalRowState], to new: [RemovalRowState]) -> UUID? {
        let made = new.filter { !$0.isPending }
        let before = Set(old.filter { !$0.isPending }.map(\.id))
        if let arrived = made.last(where: { !before.contains($0.id) }) { return arrived.id }
        return made.contains { $0.id == open } ? open : nil
    }
}

/// The Adjust inspector's Remove tab (docs/remove-plan.md, section 4.8): the brush with its size drawn beside it, Snap to
/// Object and the Remove button, then the frame's removals under their count. The brush is in hand for as long as the tab
/// shows, so the tab has no tool to choose: paint or click on the photograph, then Return. Remove is the tab's one action and
/// the inspector's one primary button, with its key on it. The tab's Compare and Reset are the inspector's, at its foot.
struct RemoveInspector: View {
    let frame: Frame
    var initialRemoval: UUID? = nil
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The row whose options show, and the rows it was last chosen from, by their frame.
    @State private var open: UUID?
    @State private var known: (frame: URL, rows: [RemovalRowState])?

    var body: some View {
        let selection = model.remove.selection, rows = model.removalRows(for: frame)
        let canAdjust = model.canAdjust(frame)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                brush
                snap(selection)
                    .padding(.top, AdjustRowMetric.pairSpacing)
                removeButton
                    .padding(.top, AdjustRowMetric.pairSpacing)
                hint(selection)
                    .padding(.top, Graphite.Metric.s)
            }
            .disabled(!canAdjust)
            if !rows.isEmpty {
                SectionDivider()
                    .padding(.top, Graphite.Metric.m)
                InspectorSectionHeader(title: RemoveCopy.count(rows.count))
                    .padding(.top, Graphite.Metric.m)
                    .padding(.bottom, AdjustRowMetric.rowSpacing)
                VStack(spacing: Graphite.Metric.xs) {
                    ForEach(rows) { row in
                        RemoveRow(frame: frame, row: row, isOpen: open == row.id, canAdjust: canAdjust) { toggle(row.id) }
                            .id(row.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Removals for this frame")
        // The model is wanted soon, and Snap to Object says whether it can, while this tab shows a frame.
        .onAppear { model.removeTabShown(for: frame) }
        .onChange(of: frame.url) { model.removeTabShown(for: frame) }
        .onDisappear { model.removeTabHidden() }
        .onChange(of: rows, initial: true) { _, rows in follow(rows) }
        .onChange(of: initialRemoval) { _, requested in
            if let requested, rows.contains(where: { $0.id == requested && !$0.isPending }) { open = requested }
        }
    }

    /// Keeps the open row with the frame's rows as they change (`RemoveList.opened`); another frame's start again.
    private func follow(_ rows: [RemovalRowState]) {
        let old = known?.frame == frame.url ? known?.rows ?? [] : []
        let requested = initialRemoval.flatMap { id in
            old.contains { $0.id == id && !$0.isPending } ? nil : rows.first { $0.id == id && !$0.isPending }?.id
        }
        let next = requested ?? RemoveList.opened(known?.frame == frame.url ? open : nil, from: old, to: rows)
        known = (frame.url, rows)
        guard next != open else { return }
        withAnimation(reduceMotion || old.isEmpty ? nil : Graphite.Motion.quick) { open = next }
    }

    /// A click on a row's head: its options open, and the row that was open closes; on the open row, they close.
    private func toggle(_ id: UUID) {
        withAnimation(reduceMotion ? nil : Graphite.Motion.quick) { open = open == id ? nil : id }
    }

    // MARK: The brush

    /// The brush's one number, the Light tab's own row (`ManualAdjustmentRow`), in the masks' brush's group so its keys are the
    /// same. It is how the next stroke paints, and no undo step.
    private var brush: some View {
        let session = model.remove, spec = AdjustmentSliderSpec.removeBrushSize
        return VStack(alignment: .leading, spacing: AdjustRowMetric.rowSpacing) {
            InspectorSectionHeader(title: "Brush")
            HStack(alignment: .center, spacing: Graphite.Metric.m) {
                ManualAdjustmentRow(spec: spec, help: RemoveCopy.sizeHelp,
                                    value: Binding(get: { spec.snapped(Float(session.brushSize)) },
                                                   set: { session.brushSize = RemovePhotograph.size(spec.snapped($0)) }),
                                    snapshot: session.brushSize, beginGesture: {}, endGesture: {})
                BrushSizePreview(fraction: spec.fraction(of: spec.snapped(Float(session.brushSize))))
            }
        }
    }

    /// Snap to Object: on, a stroke or a click becomes the object under it. Where this Mac cannot, it is off and says why,
    /// under its name and in its help tag.
    private func snap(_ selection: RemoveSelectionState) -> some View {
        let isReady = selection.snap == .ready
        return HStack(alignment: .center, spacing: Graphite.Metric.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Snap to Object")
                    .font(Graphite.Typeface.label)
                    .foregroundStyle(isReady ? Graphite.text : Graphite.tertiaryText)
                Text(verbatim: isReady ? RemoveCopy.snapNote : RemoveCopy.snapHelp(selection.snap))
                    .font(Graphite.Typeface.caption)
                    .foregroundStyle(isReady ? Graphite.secondaryText : Graphite.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            InspectorSwitch(title: "Snap to Object", isOn: isReady && selection.snapsToObject, help: RemoveCopy.snapHelp(selection.snap)) {
                model.setRemoveSnapsToObject(!selection.snapsToObject)
            }
            .disabled(!isReady)
        }
    }

    // MARK: Remove

    /// The tab's one action, in the primary colour, with the key that does the same on it.
    private var removeButton: some View {
        Button { model.commitRemoval(on: frame) } label: {
            HStack(spacing: 6) {
                Text("Remove")
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.7)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.graphite(.primary))
        .disabled(!RemovePhotograph.canRemove(on: frame, model: model))
        .help(RemoveCopy.removeHelp)
        .accessibilityLabel("Remove")
    }

    /// What to do, while nothing is selected. Its line stays when it has nothing to say, so the first stroke moves nothing
    /// under it.
    private func hint(_ selection: RemoveSelectionState) -> some View {
        let isShown = selection.coverage == nil && selection.stroke.isEmpty && !selection.isSnapping
        return Text(verbatim: RemoveCopy.hint)
            .font(Graphite.Typeface.small)
            .foregroundStyle(Graphite.secondaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .opacity(isShown ? 1 : 0)
            .accessibilityHidden(!isShown)
            .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isShown)
    }
}

/// The brush's size beside its slider: a ring in a small well that grows with the slider, so the number, a share of the
/// picture's longer side, has something to be read against before the pointer is over the photograph.
private struct BrushSizePreview: View {
    /// How far along its range the size stands.
    let fraction: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The well, as tall as the row beside it (`AdjustRowMetric`).
    static let side: CGFloat = AdjustRowMetric.line + AdjustRowMetric.track

    var body: some View {
        let diameter = 5 + min(1, max(0, fraction)) * (Self.side - 11)
        RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
            .fill(Graphite.ink(0.05))
            .frame(width: Self.side, height: Self.side)
            .overlay {
                Circle()
                    .fill(Graphite.ink(0.1))
                    .overlay { Circle().strokeBorder(Graphite.text.opacity(0.85), lineWidth: 1) }
                    .frame(width: diameter, height: diameter)
                    .animation(reduceMotion ? nil : Graphite.Motion.follow, value: diameter)
            }
            .opacity(isEnabled ? 1 : 0.42)
            .accessibilityHidden(true)
    }
}
