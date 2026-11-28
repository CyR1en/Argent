import ArgentRoll
import SwiftUI

/// Quiet floating notices at the top of the roll and of its Develop page: another roll being read, a card just inserted,
/// a line about a roll that could not be opened while this one is, and raws this roll could not
/// read. None is a dialog: they take no focus, block nothing and keep to one line each, centred at
/// the workspace's top. On the contact sheet they sit under its filter row rather than over it. Each drops in from
/// just above its place, a little small and out of focus, and leaves on a short fade.
struct NoticeStack: View {
    /// The notices' own height, without the room above them, for the contact sheet to move down by
    /// so none covers its first row; zero with none.
    @Binding var height: CGFloat
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The contact sheet's filter row at the workspace's top.
    static let sheetRowHeight = SheetFilterBar.height
    /// The split comparison's "Neutral RAW" and stock tags near the picture's top.
    static let splitTagsHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: Graphite.Metric.s - 2) {
            staying
                // The room the sheet makes is for the notices that stay. The clipboard's line comes and goes in a moment, and
                // would move the sheet down and back each time: it floats over the sheet's first row instead.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            if let notice = model.clipboardNotice {
                ClipboardNoticeView(notice: notice)
                    .transition(.dropsIn)
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, Graphite.Metric.edge)
        // On the sheet under its filter row; in the split comparison under the sides' tags.
        .padding(.top, model.isFrameOpen ? (model.isSplitComparing ? Self.splitTagsHeight : 0) : Self.sheetRowHeight)
        // A notice drops in as glass arrives and leaves on a short fade (`AnyTransition.dropsIn`).
        .animation(reduceMotion ? nil : (model.isScanning ? Graphite.Motion.arrive : Graphite.Motion.quick), value: model.isScanning)
        .animation(reduceMotion ? nil : (model.unreadableNotice != nil ? Graphite.Motion.arrive : Graphite.Motion.quick),
                   value: model.unreadableNotice)
        .animation(reduceMotion ? nil : (model.missingStockNotice != nil ? Graphite.Motion.arrive : Graphite.Motion.quick),
                   value: model.missingStockNotice)
        // Its coming and going, and a paste's spinner giving way to what it came to; not each count while it waits.
        .animation(reduceMotion ? nil : (model.clipboardNotice != nil ? Graphite.Motion.arrive : Graphite.Motion.quick),
                   value: model.clipboardNotice?.phase)
        #if DEBUG
        .onAppear { model.applyOpenRollDebugStates() }
        #endif
    }

    /// The notices that stay until what they speak of is over, which the contact sheet makes room for.
    private var staying: some View {
        VStack(spacing: Graphite.Metric.s - 2) {
            if model.isScanning {
                Notice(symbol: nil, text: "Reading the roll…") { EmptyView() }
                    .transition(.dropsIn)
            }
            if let card = model.offeredCard {
                CardOfferNotice(card: card)
                    .transition(.dropsIn)
            }
            if let message = model.rollNoticeMessage {
                MessageNotice(message: message)
                    .transition(.dropsIn)
            }
            if let line = model.unreadableNotice {
                UnreadableNotice(line: line)
                    .transition(.dropsIn)
            }
            if let line = model.missingStockNotice {
                MissingStockNotice(line: line)
                    .transition(.dropsIn)
            }
        }
    }
}

/// One floating notice: a fine symbol, one line, and its actions at the end. The line shortens
/// rather than wrap or push the actions out; its whole text is the help tag.
struct Notice<Actions: View>: View {
    /// The leading symbol, or a spinner when `nil`.
    let symbol: String?
    let text: String
    var truncation: Text.TruncationMode = .tail
    var lineLimit = 1
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: Graphite.Metric.m - 2) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(Graphite.secondaryText)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)
            Text(verbatim: text)
                .font(Graphite.Typeface.label)
                .foregroundStyle(Graphite.text)
                .lineLimit(lineLimit)
                .truncationMode(truncation)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .help(text)
            HStack(spacing: Graphite.Metric.xs) { actions }
                .fixedSize()
        }
        .padding(.leading, Graphite.Metric.m)
        .padding(.trailing, Graphite.Metric.xs + 2)
        .frame(minHeight: 38)
        .graphiteFloating(cornerRadius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text)
    }
}

/// What a copy or a paste of adjustments left (`RollModel.clipboardNotice`, docs/context-menus-plan.md, section 5): its line;
/// the spinner while a paste waits for its frames; Undo while the paste is the next step to undo; Details for the frames a
/// paste left out and why, in a popover as the unreadable raws' notice has; and a close. It goes by itself after a moment.
private struct ClipboardNoticeView: View {
    let notice: ClipboardNotice
    @Environment(RollModel.self) private var model
    @State private var isDetailsShown = false
    @State private var isHovered = false

    var body: some View {
        // A long frame name shortens in its middle, so the line's start and the name's end both stay.
        Notice(symbol: notice.symbol, text: notice.text, truncation: .middle) {
            ForEach(notice.actions, id: \.self) { action in
                switch action {
                case .undo:
                    Button("Undo") { model.undoPasteFromNotice() }
                        .buttonStyle(.graphite(.quiet, size: .small))
                        .help("Undo the paste. Command-Z.")
                case .details:
                    Button("Details") { isDetailsShown.toggle() }
                        .buttonStyle(.graphite(.quiet, size: .small))
                        .help(notice.detailsHelp)
                        .popover(isPresented: $isDetailsShown, arrowEdge: .bottom) {
                            ClipboardNoticeDetails(title: notice.detailsTitle, lines: notice.details, entries: notice.detailEntries)
                        }
                case .close:
                    // A paste still waiting for its frames is stopped by its close, not only hidden: nothing has been written yet.
                    if notice.isWaiting {
                        CloseButton(help: "Stop this paste") { model.stopPaste() }
                    } else if notice.kind == .working {
                        // Files on their way are not stopped half moved: the line stays until they have arrived.
                        EmptyView()
                    } else {
                        CloseButton(help: "Hide this") { model.dismissClipboardNotice() }
                    }
                }
            }
        }
        // It stays while it is being reached for: the pointer on it, or its Details open.
        .onHover { isHovered = $0 }
        .onChange(of: isHovered || isDetailsShown) { _, holds in model.holdClipboardNotice(holds) }
    }
}

/// The popover of a paste's notice: each frame it left out, with why.
private struct ClipboardNoticeDetails: View {
    let title: String
    let lines: [String]
    let entries: [ClipboardNotice.Detail]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .font(Graphite.Typeface.sectionTitle)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(Graphite.Typeface.label)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: entry.title)
                            .font(Graphite.Typeface.label)
                            .fontWeight(.medium)
                        ForEach(Array(entry.secondaryLines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(Graphite.Typeface.small)
                                .foregroundStyle(Graphite.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 440)
        .foregroundStyle(Graphite.text)
    }
}

extension ClipboardNotice {
    /// The notice's buttons after its line, in order.
    enum Action: Hashable {
        case undo, details, close
    }

    /// Undo while the paste is the next step to undo, Details when a frame was left out, and always the close.
    var actions: [Action] {
        (offersUndo ? [.undo] : []) + (plainDetails.isEmpty ? [] : [.details]) + [.close]
    }

    /// The leading symbol: none while a paste waits, so the notice shows the spinner; the copy's or the paste's own; the
    /// warning where a paste left frames out or nothing could be done.
    var symbol: String? {
        switch kind {
        case .copied: "doc.on.doc"
        case .pasting: nil
        case .pasted(_, let skipped): skipped > 0 ? "exclamationmark.triangle" : "doc.on.clipboard"
        case .failed: "exclamationmark.triangle"
        case .working: nil
        case .done(let symbol): symbol
        }
    }

    /// A paste still waiting for its frames to be ready.
    var isWaiting: Bool {
        if case .pasting = kind { return true }
        return false
    }

    /// What the stack animates on: the kind without a waiting paste's counts, so the spinner gives way to the result
    /// with the stack's fade, and each count as frames are made ready changes the line at once.
    var phase: Kind {
        if case .pasting = kind { return .pasting(done: 0, of: 0) }
        return kind
    }
}

/// Raws of the open roll its scan could not read: how many, the details in a popover, and a close
/// that holds for those same files.
private struct UnreadableNotice: View {
    let line: String
    @Environment(RollModel.self) private var model
    @State private var isDetailsShown = false

    var body: some View {
        Notice(symbol: "exclamationmark.triangle", text: line) {
            Button("Details") { isDetailsShown.toggle() }
                .buttonStyle(.graphite(.quiet, size: .small))
                .help("The files that could not be read, and why they are left out")
                .popover(isPresented: $isDetailsShown, arrowEdge: .bottom) { IssueDetails() }
            CloseButton(help: "Hide this for these files") { model.dismissUnreadableNotice() }
        }
    }
}

/// Non-blocking notice when the open roll (or one or more of its frames) references a stock
/// that is not currently installed.
private struct MissingStockNotice: View {
    let line: String
    @Environment(RollModel.self) private var model
    @State private var isDetailsShown = false

    var body: some View {
        Notice(symbol: "exclamationmark.triangle", text: line) {
            Button("Details") { isDetailsShown.toggle() }
                .buttonStyle(.graphite(.quiet, size: .small))
                .help("Which stocks are missing and how this roll is being previewed")
                .popover(isPresented: $isDetailsShown, arrowEdge: .bottom) { IssueDetails() }
            CloseButton(help: "Hide this notice") { model.isMissingStockNoticeDismissed = true }
        }
    }
}
