import ArgentRoll
import SwiftUI

/// The Rolls page, the rail's first item (docs/M2-shell.md, section 23): the library's rolls, each a strip of
/// negatives with its sprocket holes cut through to the Latent image behind (`OpenRollBackdrop`), grouped by month,
/// newest first; over them the title, a filter, and Import roll, which opens the sheet that chooses a card, a drive or a
/// folder (`ImportSourceSheet`). A card just inserted is offered under the title. An import's copy goes on here: the
/// new roll's strip fills in as its frames arrive, and once they are in, a notice at the foot offers to open it and to
/// eject its card.
///
/// The covers are a few of each roll's frames, kept by `RollCoverStore`, so a roll on a drive out of reach still shows
/// them, dimmed. A click opens a roll, or goes back to the one open now; a right-click has Show in Finder, Rename…
/// and Remove from Rolls, which only forgets it.
struct RollsPage: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    /// The title's frame and the drop card's, in the page's points from its top left, for the backdrop.
    @State private var headerFrame: CGRect?
    @State private var dropFrame: CGRect?
    @State private var filter = ""
    @State private var oldestFirst = false
    @State private var renameText = ""

    /// The widest the page's column grows.
    static let columnWidth: CGFloat = 1080
    /// The page's own coordinate space, the backdrop's.
    nonisolated private static let space = "RollsPage"

    var body: some View {
        ZStack {
            ScrollView {
                column
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            if model.isImportSourceShown {
                Color.black.opacity(0.3)
                    .contentShape(Rectangle())
                    .onTapGesture { model.isImportSourceShown = false }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                ImportSourceSheet()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            if model.openRollHero == .dropTargeted {
                DropCard()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { dropFrame = $0 }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            RollsFootNotice()
                .padding(.bottom, Graphite.Metric.edge)
                .padding(.horizontal, Graphite.Metric.xl)
        }
        .coordinateSpace(.named(Self.space))
        .background {
            ZStack {
                if AppearanceSettings.shared.showsOpenRollBackdrop, contrast != .increased {
                    OpenRollBackdrop(column: headerFrame, heroZone: model.openRollHero == .dropTargeted ? dropFrame : nil,
                                     hero: model.openRollHero, reduceMotion: reduceMotion)
                        .accessibilityHidden(true)
                }
                // The page's empty room moves the window, as the rail's does: the window has no title bar.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
            }
        }
        .animation(reduceMotion ? nil : Graphite.Motion.panel, value: model.isImportSourceShown)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: model.openRollHero)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: model.message)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: model.offeredCard)
        .animation(reduceMotion ? nil : Graphite.Motion.panel, value: model.importNotice)
        .onAppear {
            model.refreshLibraryAvailability()
            model.loadLibraryCovers(oldestFirst: oldestFirst)
            #if DEBUG
            model.applyOpenRollDebugStates()
            #endif
        }
        .onChange(of: model.library) { model.loadLibraryCovers(oldestFirst: oldestFirst) }
        .alert("Rename Roll", isPresented: Binding(get: { model.renamingRoll != nil }, set: { if !$0 { model.renamingRoll = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let id = model.renamingRoll { model.renameLibraryRoll(id: id, to: renameText) } }
            Button("Cancel", role: .cancel) { model.renamingRoll = nil }
        } message: {
            Text("The name Argent shows. The folder keeps its own.")
        }
        .onChange(of: model.renamingRoll) { _, id in
            renameText = id.flatMap { id in model.library.first { $0.id == id }?.name } ?? ""
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rolls")
    }

    private var column: some View {
        let rolls = model.libraryRolls(matching: filter, oldestFirst: oldestFirst)
        return VStack(alignment: .leading, spacing: 0) {
            header
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { headerFrame = $0 }
            if let message = model.message {
                RollsMessage(message: message, hint: model.openRollMessageHint) { model.message = nil }
                    .padding(.top, Graphite.Metric.xl)
                    .transition(.opacity)
            }
            if let card = model.offeredCard, !model.isImportSourceShown {
                CardBanner(card: card)
                    .padding(.top, Graphite.Metric.xl)
                    .transition(.opacity)
            }
            if case .copying(let review, let folder, let done, let total) = model.importSession {
                PageSectionHeading(title: "Importing", detail: review.card.name)
                    .padding(.top, 34)
                    .padding(.bottom, 14)
                PendingRollRow(name: folder.lastPathComponent, source: review.card.name, covers: model.importCovers,
                               done: done, total: total)
            }
            if rolls.isEmpty {
                if model.library.isEmpty {
                    if !model.importSession.isCopying { EmptyLibrary().padding(.top, 72) }
                } else {
                    Text(verbatim: "No roll is named \u{201C}\(filter)\u{201D}")
                        .font(Graphite.Typeface.row)
                        .foregroundStyle(Graphite.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 72)
                }
            } else {
                ForEach(RollMonth.grouping(rolls)) { month in
                    PageSectionHeading(title: month.title, detail: month.rolls.count == 1 ? "1 roll" : "\(month.rolls.count) rolls")
                        .padding(.top, 34)
                        .padding(.bottom, 14)
                    ForEach(month.rolls) { roll in
                        LibraryRollRow(roll: roll)
                    }
                }
            }
        }
        .frame(maxWidth: Self.columnWidth)
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 110)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: Graphite.Metric.m) {
            PageHeading(title: "Rolls", subtitle: subtitle)
            Spacer(minLength: Graphite.Metric.m)
            if !model.library.isEmpty {
                FilterField(text: $filter)
                Menu {
                    Picker("Order", selection: $oldestFirst) {
                        Text("Newest first").tag(false)
                        Text("Oldest first").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    MenuFace(text: oldestFirst ? "Oldest first" : "Newest first")
                }
                .graphiteMenu()
                .accessibilityLabel("Order")
                .accessibilityValue(oldestFirst ? "Oldest first" : "Newest first")
            }
            Button { model.showImportSource() } label: {
                Label("Import roll", systemImage: "plus")
            }
            .buttonStyle(.graphite(.primary))
            .disabled(!model.canShowImportSource)
            .help(model.importSourceHelp)
        }
    }

    private var subtitle: String {
        let rolls = model.library.count
        guard rolls > 0 else { return "Import a card or a folder to begin" }
        let frames = model.libraryFrameCount
        return (rolls == 1 ? "1 roll" : "\(rolls) rolls") + (frames > 0 ? " · \(frames.formatted()) frames" : "")
    }
}

// MARK: - Months

/// The rolls of one month, as the page groups them.
struct RollMonth: Identifiable, Equatable {
    let id: String
    let title: String
    let rolls: [BookmarkStore.LibraryRoll]

    /// `rolls`, in their order, cut into their months: "November 2026".
    static func grouping(_ rolls: [BookmarkStore.LibraryRoll]) -> [RollMonth] {
        var months: [RollMonth] = []
        for roll in rolls {
            let date = roll.date
            let calendar = RollDates.calendar(for: roll)
            let parts = calendar.dateComponents([.year, .month], from: date)
            let id = "\(parts.year ?? 0)-\(parts.month ?? 0)"
            if let last = months.last, last.id == id {
                months[months.count - 1] = RollMonth(id: id, title: last.title, rolls: last.rolls + [roll])
            } else {
                let title = date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.wide).year())
                months.append(RollMonth(id: id, title: title, rolls: [roll]))
            }
        }
        return months
    }
}

/// A roll's date as the page writes it. A first frame's time is the camera's clock, kept as if it were UTC; a roll
/// without one has the time it was added, in the Mac's own zone.
enum RollDates {
    static func calendar(for roll: BookmarkStore.LibraryRoll) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = roll.firstCapture == nil ? .current : TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// "SAT 8 NOV 2026".
    static func line(_ roll: BookmarkStore.LibraryRoll) -> String {
        roll.date.formatted(Date.FormatStyle(timeZone: calendar(for: roll).timeZone).weekday(.abbreviated).day().month(.abbreviated).year())
            .replacingOccurrences(of: ",", with: "").uppercased()
    }

    /// "08·11·26", for the strip's edge print.
    static func edge(_ roll: BookmarkStore.LibraryRoll) -> String {
        let parts = calendar(for: roll).dateComponents([.year, .month, .day], from: roll.date)
        return String(format: "%02d·%02d·%02d", parts.day ?? 0, parts.month ?? 0, (parts.year ?? 0) % 100)
    }
}

// MARK: - Rows

/// A roll's context menu on the Rolls page, as a table: Open (or Back to Roll for the roll open now), Show in Finder,
/// off while the roll cannot be reached, Rename…, and Remove from Rolls, which forgets the roll and leaves its folder.
@MainActor enum LibraryRollMenu {
    static func entries(for roll: BookmarkStore.LibraryRoll, model: RollModel) -> [MenuEntry] {
        let isOpen = model.openLibraryRoll?.id == roll.id
        return MenuEntry.sections([
            [
                .action("roll.open", isOpen ? "Back to Roll" : "Open") { model.openLibraryRoll(id: roll.id) },
                .action("roll.showInFinder", "Show in Finder", isEnabled: !model.unavailableRolls.contains(roll.id)) {
                    model.showLibraryRollInFinder(id: roll.id)
                },
                .action("roll.rename", "Rename…") { model.renamingRoll = roll.id },
            ],
            [.action("roll.remove", "Remove from Rolls") { model.removeLibraryRoll(id: roll.id) }],
        ])
    }
}

/// One roll: its date, name and what it holds beside its strip. Hover slides the strip along; a click opens it.
private struct LibraryRollRow: View {
    let roll: BookmarkStore.LibraryRoll
    @Environment(RollModel.self) private var model

    var body: some View {
        let isOpen = model.openLibraryRoll?.id == roll.id
        let isUnavailable = model.unavailableRolls.contains(roll.id)
        Button { model.openLibraryRoll(id: roll.id) } label: {
            RollRowFace(date: RollDates.line(roll), name: roll.name, info: info, status: status(isUnavailable: isUnavailable),
                        statusSymbol: isUnavailable ? "exclamationmark.triangle" : roll.origin == .inPlace ? "link" : nil,
                        isWarning: isUnavailable, pill: isOpen ? "Open" : nil, isMarked: isOpen) { isHovered in
                FilmStrip(covers: model.rollCovers[roll.id] ?? [], slots: slots, developed: nil,
                          edge: "ARGENT  \u{25C2} \(RollDates.edge(roll)) \u{25B8}  \(roll.name.uppercased())"
                              + (roll.frameCount.map { "  ·  \($0) EXP" } ?? ""),
                          shift: isHovered ? -56 : 0)
                    .saturation(isUnavailable ? 0 : 1)
                    .opacity(isUnavailable ? 0.5 : 1)
            }
        }
        .buttonStyle(RollRowStyle())
        .contextMenu(entries: { [roll, model] in LibraryRollMenu.entries(for: roll, model: model) })
        .help(isUnavailable ? RollModel.unavailableText(roll) + ". Click to try again." : roll.path)
        .accessibilityLabel(roll.name)
        .accessibilityValue([info, status(isUnavailable: isUnavailable), isOpen ? "open now" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(isOpen ? "Goes back to the roll" : "Opens the roll")
        .accessibilityActions {
            Button("Show in Finder") { model.showLibraryRollInFinder(id: roll.id) }
            Button("Rename") { model.renamingRoll = roll.id }
            Button("Remove from Rolls") { model.removeLibraryRoll(id: roll.id) }
        }
    }

    private var slots: Int {
        let covers = model.rollCovers[roll.id]?.count ?? 0
        if covers > 0 { return covers }
        return min(roll.frameCount ?? RollCoverStore.count, RollCoverStore.count)
    }

    /// "36 frames · Imported from SONY A7 IV".
    private var info: String {
        var parts: [String] = []
        if let count = roll.frameCount { parts.append(RollModel.framesText(count)) }
        if roll.origin == .imported, let source = roll.source { parts.append("Imported from \(source)") }
        return parts.isEmpty ? "Not read yet" : parts.joined(separator: " · ")
    }

    private func status(isUnavailable: Bool) -> String? {
        if isUnavailable {
            return roll.volume.map { "On \u{201C}\($0)\u{201D}, not connected" } ?? "Not available"
        }
        guard roll.origin == .inPlace else { return nil }
        return "Added in place · " + DevelopStatusText.abbreviated(URL(fileURLWithPath: roll.path))
    }
}

/// The roll an import is copying into: its covers come up as its frames arrive.
private struct PendingRollRow: View {
    let name: String
    let source: String
    let covers: [CGImage]
    let done: Int
    let total: Int

    var body: some View {
        let slots = max(covers.count, min(total, RollCoverStore.count))
        let developed = total > 0 ? Int((Double(done) / Double(total) * Double(slots)).rounded(.down)) : 0
        RollRowFace(date: "COPYING", name: name, info: "\(RollModel.framesText(total)) · From \(source)",
                    status: "\(min(done, total)) of \(total) copied", statusSymbol: nil, isWarning: false, pill: "New",
                    isMarked: true, progress: total > 0 ? Double(done) / Double(total) : 0) { _ in
            FilmStrip(covers: covers, slots: slots, developed: developed,
                      edge: "ARGENT  \u{25C2} NEW \u{25B8}  \(name.uppercased())  ·  \(total) EXP", shift: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), copying \(min(done, total)) of \(total)")
    }
}

/// A row's two columns: the words, at a fixed width, and the strip filling the rest.
private struct RollRowFace<Strip: View>: View {
    let date: String
    let name: String
    let info: String
    let status: String?
    let statusSymbol: String?
    let isWarning: Bool
    let pill: String?
    /// A bar at the words' leading edge: the roll open now, or the one being imported.
    let isMarked: Bool
    var progress: Double?
    @ViewBuilder let strip: (_ isHovered: Bool) -> Strip
    @Environment(\.rollRowHovered) private var isHovered

    /// The words' column.
    static var metaWidth: CGFloat { 236 }

    var body: some View {
        HStack(spacing: Graphite.Metric.xl) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: date)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Graphite.tertiaryText)
                HStack(spacing: Graphite.Metric.s) {
                    Text(verbatim: name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Graphite.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .underline(isHovered, color: Graphite.ink(0.3))
                    if let pill { Pill(text: pill) }
                }
                .padding(.top, 5)
                Text(verbatim: info)
                    .font(Graphite.Typeface.body.monospacedDigit())
                    .foregroundStyle(Graphite.secondaryText)
                    .lineLimit(1)
                    .padding(.top, 5)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(RollColors.edgePrint)
                        .frame(width: 96)
                        .padding(.top, 9)
                        .accessibilityHidden(true)
                }
                if let status {
                    HStack(spacing: 5) {
                        if let statusSymbol {
                            Image(systemName: statusSymbol)
                                .font(.system(size: 10, weight: .medium))
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: status)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(Graphite.Typeface.caption.monospacedDigit())
                    .foregroundStyle(isWarning ? RollColors.edgePrint : Graphite.tertiaryText)
                    .padding(.top, 7)
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, 14)
            .frame(width: Self.metaWidth, alignment: .leading)
            .overlay(alignment: .leading) {
                if isMarked {
                    Capsule().fill(Graphite.text).frame(width: 2).padding(.vertical, 6)
                        .accessibilityHidden(true)
                }
            }
            strip(isHovered)
        }
        .padding(.bottom, 22)
    }
}

extension EnvironmentValues {
    /// The pointer is over the row this view is in (`RollRowStyle`).
    @Entry var rollRowHovered = false
}

/// A roll's row as a button: the pointer over it slides its strip and underlines its name; the press dims it.
private struct RollRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .environment(\.rollRowHovered, isHovered)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: isHovered)
        }
    }
}

// MARK: - The strip

/// The colours of film the page draws whatever the theme: the base of a strip of negatives, dark in every theme as
/// film is, and its edge print.
enum RollColors {
    static let filmBase = Color(red: 12 / 255, green: 13 / 255, blue: 20 / 255).opacity(0.9)
    static let edgePrint = Color(red: 0.89, green: 0.64, blue: 0.35)
}

/// A strip of negatives: a rebate with sprocket holes and edge print above and below a row of frames, the holes cut
/// through to whatever is behind. It runs past the row's end and fades out there.
struct FilmStrip: View {
    let covers: [CGImage]
    /// Frames drawn; those without a cover are blank, as unexposed film is.
    let slots: Int
    /// For a roll being copied, how many of its frames have arrived; the rest are blank. `nil` shows every cover.
    let developed: Int?
    let edge: String
    var shift: CGFloat = 0

    static let frame = CGSize(width: 144, height: 96)
    /// From one frame's left edge to the next's.
    static let pitch: CGFloat = 152
    static let rebate: CGFloat = 20

    var body: some View {
        // The film is drawn over a space as wide as the row offers, never asking for its own width: a long roll runs on
        // past the row's end and fades there rather than widen the page.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.frame.height + 2 * Self.rebate)
            .overlay(alignment: .leading) {
                film
                    .offset(x: shift)
            }
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72),
                                       .init(color: .clear, location: 0.99)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .accessibilityHidden(true)
    }

    private var film: some View {
        let width = CGFloat(max(slots, 1)) * Self.pitch
        return VStack(spacing: 0) {
            Rebate(isTop: true) {
                Text(verbatim: Array(repeating: edge, count: 4).joined(separator: "            "))
                    .padding(.top, 10)
            }
            HStack(spacing: Self.pitch - Self.frame.width) {
                ForEach(0..<max(slots, 1), id: \.self) { index in
                    slot(index)
                }
            }
            .padding(.horizontal, (Self.pitch - Self.frame.width) / 2)
            .frame(height: Self.frame.height)
            .background(RollColors.filmBase)
            Rebate(isTop: false) {
                HStack(spacing: 0) {
                    ForEach(0..<max(slots, 1), id: \.self) { index in
                        Text(verbatim: "\u{25B8}\(index + 1)    \(index + 1)A")
                            .frame(width: Self.pitch, alignment: .leading)
                            .padding(.leading, 4)
                    }
                }
                .padding(.top, 1)
            }
        }
        .frame(width: width)
        .fixedSize()
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
    }

    @ViewBuilder private func slot(_ index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        if index < covers.count, developed.map({ index < $0 }) ?? true {
            Image(decorative: covers[index], scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: Self.frame.width, height: Self.frame.height)
                .clipShape(shape)
                .transition(.opacity)
        } else {
            shape.fill(Color.white.opacity(0.035))
                .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
                .frame(width: Self.frame.width, height: Self.frame.height)
        }
    }
}

/// A strip's rebate: film base with a row of sprocket holes cut through it, on the outer side, and its print on the
/// inner side.
private struct Rebate<Print: View>: View {
    let isTop: Bool
    @ViewBuilder let print: Print

    static var holePitch: CGFloat { 18 }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RollColors.filmBase))
            context.blendMode = .destinationOut
            let y: CGFloat = isTop ? 4 : size.height - 10
            var x: CGFloat = 5.5
            while x < size.width {
                context.fill(Path(roundedRect: CGRect(x: x, y: y, width: 7, height: 6), cornerRadius: 1.2), with: .color(.black))
                x += Self.holePitch
            }
        }
        .overlay(alignment: .topLeading) {
            print
                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(RollColors.edgePrint.opacity(0.75))
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .frame(height: FilmStrip.rebate)
        .clipped()
    }
}

// MARK: - Around the rows

/// The card just inserted, offered for import: Not now until it is inserted again, or Import, which reads it and
/// shows its frames to review.
private struct CardBanner: View {
    let card: Card
    @Environment(RollModel.self) private var model

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 14) {
            Image(systemName: "sdcard")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Graphite.text)
                .frame(width: 34, height: 34)
                .background(Graphite.ink(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Circle().fill(RollColors.edgePrint).frame(width: 8, height: 8).offset(x: 2, y: -2)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Card \u{201C}\(card.name)\u{201D} inserted")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Graphite.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: card.rawCount.map(RollModel.framesText) ?? "Its folders could not be read")
                    .font(Graphite.Typeface.small.monospacedDigit())
                    .foregroundStyle(Graphite.secondaryText)
            }
            Spacer(minLength: Graphite.Metric.m)
            Button("Not now") { model.dismissCard(card) }
                .buttonStyle(.graphite(.quiet, size: .small))
                .help("Hide this until the card is inserted again")
            Button("Import…") { model.startImport(card) }
                .buttonStyle(.graphite(.secondary, size: .small))
                .disabled(!model.canImport(card))
                .help(model.importHelp(card))
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(minHeight: 58)
        .background { shape.fill(Graphite.chrome.opacity(0.6)) }
        .overlay { shape.strokeBorder(Graphite.ink(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RollModel.offerText(card))
    }
}

/// Why the last open gave no roll, as the model says it, with the way on under it and a close.
private struct RollsMessage: View {
    let message: String
    let hint: String?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Graphite.Metric.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Graphite.secondaryText)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: message)
                    .font(Graphite.Typeface.body)
                    .foregroundStyle(Graphite.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                if let hint {
                    Text(verbatim: hint)
                        .font(Graphite.Typeface.small)
                        .foregroundStyle(Graphite.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            CloseButton(help: "Hide this message", action: dismiss)
                .padding(.top, -4)
                .padding(.trailing, -4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .graphiteCard(cornerRadius: 10)
        .frame(maxWidth: 640, alignment: .leading)
    }
}

/// The filter over the rolls, by name.
private struct FilterField: View {
    @Binding var text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Graphite.secondaryText)
                .accessibilityHidden(true)
            TextField("Filter rolls", text: $text)
                .textFieldStyle(.plain)
                .font(Graphite.Typeface.label)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Graphite.tertiaryText)
                .help("Show every roll")
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 190, height: Graphite.Metric.controlHeight)
        .glassEffect(Graphite.controlGlass(), in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter rolls")
    }
}

/// No rolls yet: Import roll, or a folder added where it is.
private struct EmptyLibrary: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            FilmStrip(covers: [], slots: 2, developed: 0, edge: "ARGENT  \u{25C2} UNEXPOSED \u{25B8}")
                .frame(width: 210)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                                           .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .padding(.bottom, 28)
            Text("No rolls yet")
                .font(Graphite.Typeface.pageTitle)
                .foregroundStyle(Graphite.text)
            Text("Import a camera card or a folder of ARW files. Argent copies it into a roll and keeps it here.")
                .font(Graphite.Typeface.row)
                .foregroundStyle(Graphite.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 8)
            HStack(spacing: Graphite.Metric.m) {
                Button("Add an existing folder…") { model.chooseExistingFolder() }
                    .buttonStyle(.graphite(.secondary, size: .large))
                    .help("Open a folder of ARW files where it is, and keep it as a roll. Command-O.")
                Button { model.showImportSource() } label: { Label("Import roll", systemImage: "plus") }
                    .buttonStyle(.graphite(.primary, size: .large))
                    .disabled(!model.canShowImportSource)
                    .help(model.importSourceHelp)
            }
            .padding(.top, 28)
            Text("or drop a folder or a card anywhere on the window")
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.tertiaryText)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A folder or a card held over the window.
private struct DropCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40, weight: .ultraLight))
                .accessibilityHidden(true)
            Text("Release to open")
                .font(Graphite.Typeface.panelTitle)
            Text("The folder opens as a roll and joins your rolls")
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
        }
        .foregroundStyle(Graphite.text)
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .graphiteCard(cornerRadius: Graphite.Metric.panelRadius)
        .accessibilityElement(children: .combine)
    }
}

/// The notice at the page's foot: a roll being read, an import's copy, or what the last import came to.
private struct RollsFootNotice: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        Group {
            if case .copying(_, let folder, let done, let total) = model.importSession {
                HStack(spacing: Graphite.Metric.m) {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("\(Text(verbatim: ImportTopBar.copyingText(done, of: total)).fontWeight(.semibold))\(Text(verbatim: " to \(DevelopStatusText.abbreviated(folder))").foregroundStyle(Graphite.secondaryText))")
                        .font(Graphite.Typeface.label.monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Cancel") { model.cancelCopy() }
                        .buttonStyle(.graphite(.secondary, size: .small))
                        .help("Stop copying and go back to the review. The frames copied stay in \(DevelopStatusText.abbreviated(folder)).")
                }
                .footNotice()
            } else if let notice = model.importNotice {
                HStack(spacing: Graphite.Metric.m) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .light))
                        .accessibilityHidden(true)
                    Text(verbatim: notice.text)
                        .font(Graphite.Typeface.label.monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if notice.ejectable != nil {
                        Button { model.ejectImportSource() } label: {
                            Label("Eject \u{201C}\(notice.ejectName ?? notice.source)\u{201D}", systemImage: "eject")
                        }
                        .buttonStyle(.graphite(.secondary, size: .small))
                        .help("Eject \(notice.ejectName ?? notice.source). Nothing on it is changed.")
                    }
                    if notice.roll != nil {
                        Button(model.importNoticeIsOpenRoll ? "Reload roll" : "Open roll") { model.openImportedRoll() }
                            .buttonStyle(.graphite(.primary, size: .small))
                            .disabled(model.importNoticeIsOpenRoll && model.isDeveloping)
                            .help(model.importNoticeIsOpenRoll ? (model.isDeveloping ? "Read the roll again when the develop is done"
                                                                                     : "Read the roll again with the frames just imported")
                                                               : "Open the roll")
                    }
                    CloseButton(help: "Hide this notice") { model.importNotice = nil }
                }
                .footNotice()
            } else if model.openRollHero == .reading {
                HStack(spacing: Graphite.Metric.m) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("Reading the roll…")
                        .font(Graphite.Typeface.label)
                }
                .footNotice()
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private extension View {
    func footNotice() -> some View {
        foregroundStyle(Graphite.text)
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(minHeight: 44)
            .graphiteFloating(cornerRadius: 14)
            .accessibilityElement(children: .contain)
    }
}
