import ArgentCore
import ArgentRoll
import SwiftUI

/// The roll as a contact sheet: its frames in capture order in 3:2 wells that fill the width,
/// each with its file name under it, a 2 pt ring in the selection colour round each frame selected and a small
/// flag badge on each flagged one. Arrow keys move the selection, and with Shift extend it; a Command-click and a
/// Shift-click select several frames (RollModel+Selection); a pinch, the filter row's size
/// control or the View menu changes the size. With a filter on it shows the flagged or the
/// unflagged frames only, and says so when there are none.
struct ContactSheet: View {
    /// The sheet's spacing: the workspace's edge either side, a
    /// narrower gutter between columns than between rows, whose file names sit under them.
    enum Spacing {
        /// Above the sheet's filter row, whose own room puts its control on the content edge.
        static let pageTop = Graphite.Metric.edge - 14
        static let margin = Graphite.Metric.edge
        static let gutter: CGFloat = 12
        static let rowGap: CGFloat = 16
        /// Under the filter row, room for the top row's ring included.
        static let top: CGFloat = 14
        static let bottom: CGFloat = 16
        /// How far the scroll view runs past those, under the filter row's foot and down to the dock's
        /// top edge, for its pictures to fade out there rather than stop at a line. The fades are as
        /// tall as the room they stand in, so a resting sheet's first and last rows are clear of them.
        static let topOverlap: CGFloat = 8
        static let bottomOverlap = Graphite.Metric.dockBand - Graphite.Metric.dockTop
        static var topFade: CGFloat { top + topOverlap }
        static var bottomFade: CGFloat { bottom + bottomOverlap }

        /// How many columns of at least `cell` fit in `width`.
        static func columns(fitting width: CGFloat, cell: CGFloat) -> Int {
            max(1, Int((width + gutter) / (cell + gutter)))
        }
    }

    let roll: Roll
    /// The Develop page's mark on each frame, by file (`RollModel.developMarks`); none on the roll's own sheet.
    var marks: [URL: DevelopMark] = [:]
    /// What VoiceOver calls the grid: the contact sheet, or the Develop page's frames to develop.
    var name = "Contact sheet"
    /// The roll's own sheet, which the frame view grows from and shrinks back to (`RollModel.sheetGrid`).
    var isRollSheet = false
    @Environment(RollModel.self) private var model
    @FocusState private var focused: Bool
    @State private var grid = SheetGridController()
    /// The sheet's width, read from the scroll view's own geometry.
    @State private var width: CGFloat = 0

    var body: some View {
        let frames = model.shownFrames
        if roll.frames.isEmpty {
            NoFramesLeft(roll: roll)
        } else if frames.isEmpty, model.flagFilter != .all {
            NoShownFrames(filter: model.flagFilter)
        } else {
            sheet(frames)
        }
    }

    @ViewBuilder private func sheet(_ frames: [Frame]) -> some View {
        let geometry = SheetGeometry(width: width, targetCell: Metrics.thumbnailWidths[model.sizeStep])
        let columns = geometry.columns
        let flagged = model.flagged
        // The reader stands between the scroll view and the window: without it the window's root hosting
        // view works out its whole minimum size again, the dock's narrow layouts built and all, as the
        // sheet scrolls, which cost a third of the main thread and most of the frames missed.
        GeometryReader { _ in
            // Laid out once the width is known, so no cell asks for pictures at a size it is about to leave.
            SheetGrid(controller: grid, frames: width > 0 ? frames : [], geometry: geometry, sizeStep: model.sizeStep,
                      selection: model.selection, selected: model.selected, isFlagged: { flagged[$0.url] != nil },
                      mark: { marks[$0.url] }, model: model) { frame, click in
                model.select(frame, click)
                focused = true
            } pinched: { pinch in
                if pinch > 1.2 { model.changeSize(by: 1) } else if pinch < 0.83 { model.changeSize(by: -1) }
            }
        }
        .overlay(alignment: .top) { edgeFade(height: Spacing.topFade, from: .top, to: .bottom) }
        .overlay(alignment: .bottom) { edgeFade(height: Spacing.bottomFade, from: .bottom, to: .top) }
        // The room offered, not the grid's width, which follows from it: with minimums of
        // zero the frame does not grow to fit what it measures.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // Under the quick develop dialog no key is the sheet's, wherever the keys are: Return and Escape go on to the
        // dialog's buttons (`QuickDevelopSheet`). The model is read as a key comes, not as the sheet is drawn, which would
        // draw the sheet again at each choice made in the dialog.
        // With Shift an arrow, Home or End extends the selection from where it started to the frame reached.
        .workspaceHorizontalArrows { step, key in move(step, extending: key.modifiers.contains(.shift)) }
        .onKeyPress(keys: [.upArrow]) { move(-columns, extending: $0.modifiers.contains(.shift)) }
        .onKeyPress(keys: [.downArrow]) { move(columns, extending: $0.modifiers.contains(.shift)) }
        .onKeyPress(keys: [.home]) { moveToEnd(last: false, extending: $0.modifiers.contains(.shift)) }
        .onKeyPress(keys: [.end]) { moveToEnd(last: true, extending: $0.modifiers.contains(.shift)) }
        .onKeyPress(.return) {
            guard !model.isSheetShown else { return .ignored }
            model.openFrame()
            return .handled
        }
        // Escape lets go of the frames selected beside the lead; with one selected it is not the sheet's key.
        .onKeyPress(.escape) {
            guard !model.isSheetShown, model.hasSeveralSelected else { return .ignored }
            model.collapseSelection()
            return .handled
        }
        // Edit > Select All, Command-A, while the sheet has the keys: every frame shown.
        .onCommand(#selector(NSResponder.selectAll(_:))) { if !model.isSheetShown { model.selectAllShown() } }
        .onAppear {
            focused = true
            if isRollSheet { model.sheetGrid = grid }
        }
        .restoreWorkspaceFocus { focused = true }
        // Back from the frame view, on the frame that was open, once the grid is laid out.
        .onChange(of: width > 0) {
            if width > 0, let selection = model.selection { grid.reveal(selection, centered: true) }
        }
        // Another size: on the selected frame still, the sheet scrolling there as its thumbnails glide to their size.
        .onChange(of: model.sizeStep) {
            if let selection = model.selection { grid.reveal(selection, centered: true, resizing: true) }
        }
        // Another filter, on the frame the selection moved to; also when the sheet comes back from
        // showing no frame, already as wide as it was, on the frame the selection went back to.
        .onChange(of: model.flagFilter, initial: true) {
            if width > 0, let selection = model.selection { grid.reveal(selection, centered: true) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel((model.flagFilter == .all ? "\(name), \(roll.frames.count) frames"
                             : "\(name), \(model.flagFilter.title.lowercased()) frames, \(frames.count) of \(roll.frames.count) shown")
                            + (model.selectedCountText.map { ", \($0)" } ?? ""))
    }

    /// The sheet's ground over its pictures at the scroll view's edge, easing out so no line shows
    /// where the fade starts or the view ends. The ground, not a mask, so it costs the scroll nothing.
    private func edgeFade(height: CGFloat, from: UnitPoint, to: UnitPoint) -> some View {
        let ground = model.graySurround ? Palette.gray18 : Graphite.workspace
        return LinearGradient(stops: [.init(color: ground, location: 0),
                                      .init(color: ground.opacity(0.86), location: 0.25),
                                      .init(color: ground.opacity(0.5), location: 0.5),
                                      .init(color: ground.opacity(0.14), location: 0.75),
                                      .init(color: ground.opacity(0), location: 1)],
                              startPoint: from, endPoint: to)
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// File name, capture time, shutter, aperture and ISO, for VoiceOver.
    static func accessibilityText(_ frame: Frame) -> String {
        var parts = [frame.name]
        if let date = frame.info.captureDate { parts.append(timeFormat.string(from: date)) }
        if let t = frame.info.exposureTime, let shutter = Self.shutterText(t) { parts.append(shutter) }
        if let f = frame.info.fNumber { parts.append(String(format: "f/%.1f", f)) }
        if let iso = frame.info.iso { parts.append("ISO \(iso)") }
        return parts.joined(separator: ", ")
    }

    /// "1/250 second", "2 seconds", "0.4 seconds"; `nil` for a time the Exif cannot have
    /// meant, such as 0 from a zero rational.
    static func shutterText(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 1 {
            let whole = seconds.rounded()
            return abs(seconds - whole) < 0.05 ? "\(Int(whole)) seconds" : String(format: "%.1f seconds", seconds)
        }
        let reciprocal = 1 / seconds
        if abs(reciprocal - reciprocal.rounded()) < 0.05 * reciprocal { return "1/\(Int(reciprocal.rounded())) second" }
        return String(format: "%.1f seconds", seconds)
    }

    /// Capture times are the camera's wall clock, stored as UTC, so they are shown in UTC.
    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private func move(_ offset: Int, extending: Bool) -> KeyPress.Result {
        guard !model.isSheetShown else { return .ignored }
        if extending { model.extendSelection(by: offset) } else { model.moveSelection(by: offset) }
        if let selection = model.selection { grid.reveal(selection, centered: false, animated: true) }
        return .handled
    }

    /// Home and End: the first or the last frame shown.
    private func moveToEnd(last: Bool, extending: Bool) -> KeyPress.Result {
        guard !model.isSheetShown else { return .ignored }
        if extending { model.extendSelection(toLast: last) } else { model.moveSelection(toLast: last) }
        if let selection = model.selection { grid.reveal(selection, centered: false, animated: true) }
        return .handled
    }
}

/// The sheet when the filter shows no frame: what is missing, why, and the way back to every frame.
private struct NoShownFrames: View {
    let filter: FlagFilter
    @Environment(RollModel.self) private var model

    var body: some View {
        VStack(spacing: Graphite.Metric.s) {
            Image(systemName: filter == .flagged ? "flag" : "flag.slash")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Graphite.tertiaryText)
                .padding(.bottom, Graphite.Metric.xs)
                .accessibilityHidden(true)
            Text(filter == .flagged ? "No flagged frames" : "No unflagged frames")
                .font(Graphite.Typeface.panelTitle)
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)
            Text(filter == .flagged ? "Frames flagged with F show here." : "Every frame of the roll is flagged.")
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
            Button("Show All Frames") { model.showFrames(.all) }
                .buttonStyle(.graphite(.secondary))
                .disabled(!model.canChangeFilter)
                .help("Show every frame of the roll. Control-Command-0.")
                .padding(.top, Graphite.Metric.m)
        }
        .multilineTextAlignment(.center)
        .padding(Spacing.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private typealias Spacing = ContactSheet.Spacing
}

/// The sheet of a roll whose last frames have left it, to the Trash or to another roll (RollModel+Frames): what
/// happened, and the way to the Rolls page, where the roll can be removed.
private struct NoFramesLeft: View {
    let roll: Roll
    @Environment(RollModel.self) private var model

    var body: some View {
        VStack(spacing: Graphite.Metric.s) {
            Image(systemName: "film")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Graphite.tertiaryText)
                .padding(.bottom, Graphite.Metric.xs)
                .accessibilityHidden(true)
            Text("No frames in this roll")
                .font(Graphite.Typeface.panelTitle)
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)
            Text("Every frame of \(roll.name) has been moved out of it.")
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
            Button("Show Rolls") { model.showWorkspacePage(.rolls) }
                .buttonStyle(.graphite(.secondary))
                .padding(.top, Graphite.Metric.m)
        }
        .multilineTextAlignment(.center)
        .padding(ContactSheet.Spacing.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// One frame on the sheet: its well, a flag badge at the picture's upper left when it is flagged, on the
/// Develop page its develop's mark at the lower right (`DevelopMarkBadge`),
/// and under it the file name and, for a frame with its own settings or adjustments, a small dot.
/// `SheetGrid` recycles it: another frame comes to the same view. Its menu (`FrameMenu`) is the sheet's, from
/// AppKit, made when a right-click asks for it (`SheetGridController.menu(at:)`): nothing of it is read here, so a
/// cell drawn as the sheet scrolls reads neither the clipboard nor anything the menu's rows ask.
struct SheetCell: View {
    let frame: Frame
    let width: CGFloat
    let isSelected: Bool
    /// Given, as `isSelected` is, so a flag changed redraws its own cell alone.
    let isFlagged: Bool
    /// Given too, so a frame a develop finishes redraws its own cell alone.
    var mark: DevelopMark?
    /// Whether it is in the sheet, rather than waiting to be used again.
    var isActive = true
    /// The flag or the mark changed on the frame the cell already shows: the badge lands, or leaves (`SheetCellMotion`).
    var lands = false
    let select: () -> Void
    /// Whether a double click opens the frame: not one made with Command or Shift held, whose clicks are selecting.
    var opens: () -> Bool = { true }
    /// Opens its menu, for VoiceOver's Show Menu.
    var showMenu: () -> Void = {}
    @Environment(RollModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var isHovered = false

    var body: some View {
        #if DEBUG
        let _ = SheetProbe.cellDrawn(frame.url)
        #endif
        let isOverridden = model.hasFrameEdits(frame)
        let isAdjusted = model.hasManualAdjustments(frame)
        VStack(alignment: .leading, spacing: SheetGeometry.labelGap) {
            FrameCell(frame: frame, width: width, stock: model.films == nil ? nil : model.stockIndex(for: frame),
                      showsBed: !model.graySurround, isActive: isActive)
                .overlay(alignment: .topLeading) {
                    if isFlagged {
                        FlagBadge(side: FlagBadge.side(forWell: width))
                            .padding(FlagBadge.side(forWell: width) / 3)
                            .offset(x: Self.pictureInset(frame, width: width))
                            .transition(.lands)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let mark {
                        DevelopMarkBadge(mark: mark, side: FlagBadge.side(forWell: width))
                            .padding(FlagBadge.side(forWell: width) / 3)
                            .offset(x: -Self.pictureInset(frame, width: width))
                            .transition(.lands)
                    }
                }
                // A badge lands on the frame the cell already shows; a recycled cell's is simply there.
                .animation(lands ? Graphite.Motion.land : nil, value: isFlagged)
                .animation(lands ? Graphite.Motion.land : nil, value: mark)
                .wellOutline(isSelected: isSelected, isHovered: isHovered && !isSelected)
            fileName(isOverridden: isOverridden, isAdjusted: isAdjusted)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        // The pointer is over another frame's cell, or none, when a recycled cell comes back.
        .onChange(of: frame.id) { isHovered = false }
        .accessibilityElement()
        .accessibilityLabel(ContactSheet.accessibilityText(frame) + (isAdjusted ? ", manually adjusted" : isOverridden ? ", own settings" : "")
                            + (isFlagged ? ", flagged" : "") + (mark == .developed ? ", developed" : mark == .failed ? ", not developed" : ""))
        .accessibilityAddTraits(isSelected ? [.isImage, .isSelected] : .isImage)
        .accessibilityHint("Opens the frame. Return or Command-Down Arrow.")
        .accessibilityAction {
            model.selection = frame.id
            model.openFrame()
        }
        // VoiceOver's way to several frames: this one joins those selected, or leaves them, as a Command-click does.
        .accessibilityAction(named: isSelected ? "Remove from Selection" : "Add to Selection") {
            model.select(frame, .toggle)
        }
        .accessibilityAction(named: isFlagged ? "Unflag" : "Flag") { model.toggleFlag(frame) }
        // Offered whether or not they can act, which is asked when one is chosen and never as the cell is drawn.
        .accessibilityAction(named: "Copy Adjustments") { model.copyAdjustmentsByAction(from: frame) }
        .accessibilityAction(named: "Paste Adjustments") { model.pasteAdjustmentsByAction(to: frame) }
        .accessibilityAction(.showMenu, showMenu)
        .onTapGesture(perform: select)
        // A double click opens the frame; the first click has selected it. With Command or Shift held the clicks are
        // selecting, and open nothing.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if opens() { model.openFrame() } })
    }

    /// The file name, drawn once and kept (`SheetFileName`), and for a frame with its own settings or
    /// adjustments a small dot after it.
    private func fileName(isOverridden: Bool, isAdjusted: Bool) -> some View {
        // On the gray surround black, which keeps its contrast there; white falls just short.
        let color = model.graySurround ? Color.black : isSelected || isHovered ? Graphite.text : Graphite.secondaryText
        let limit = width - 4 - (isOverridden ? 11 : 0)
        let image = SheetFileName.image(frame.name, color: color, limit: limit, scale: displayScale)
        return ZStack(alignment: .leading) {
            if let image { Image(decorative: image, scale: displayScale) }
            if isOverridden {
                Circle()
                    .fill(model.graySurround ? AnyShapeStyle(Color.black) : AnyShapeStyle(Graphite.secondaryText))
                    .frame(width: 5, height: 5)
                    .help(isAdjusted ? "This frame has its own adjustments" : "This frame has its own Rated at or Lab balance")
                    .accessibilityHidden(true)
                    .offset(x: CGFloat(image?.width ?? 0) / displayScale + 6)
            }
        }
        .frame(width: width - 4, height: SheetGeometry.labelHeight, alignment: .leading)
        .padding(.horizontal, 2)
    }

    /// How far a portrait frame's picture sits in from its well's leading edge, upright in the 3:2
    /// well as `FrameCell` draws it, so the badge stays on the picture rather than the bed.
    static func pictureInset(_ frame: Frame, width: CGFloat) -> CGFloat {
        guard frame.info.isPortrait else { return 0 }
        let height = width * 2 / 3
        return ((width - height * 2 / 3) / 2).rounded()
    }
}

/// A flagged frame's mark on its picture: a small rounded square in the selection colour with the flag in
/// graphite, with a soft shadow, so it reads on a bright sky as on a night scene. The sheet's
/// thumbnails and the frame view's filmstrip both draw it, at their own sizes.
struct FlagBadge: View {
    let side: CGFloat

    /// The badge's side for a well `width` wide: 20 pt on the smallest thumbnails, up to 25.
    static func side(forWell width: CGFloat) -> CGFloat {
        min(25, max(20, (width * 0.085).rounded()))
    }

    @Environment(\.isOnGlass) private var isOnGlass
    @Environment(\.appearsActive) private var appearsActive

    /// A drop of glass over the photograph, tinted light so the flag reads on any picture; in the
    /// filmstrip, whose dock is glass already, a plain light tile.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side / 4, style: .continuous)
        Image(systemName: "flag.fill")
            .font(.system(size: (side * 0.52).rounded(), weight: .semibold))
            // An inactive window's glass drops its tint; the filmstrip's plain tile keeps its colour.
            .foregroundStyle(isOnGlass || appearsActive ? Graphite.onPrimary : Graphite.text)
            .frame(width: side, height: side)
            .background { if isOnGlass { shape.fill(Graphite.selection.opacity(0.94)) } }
            .glassEffect(isOnGlass ? .identity : Glass.regular.tint(Graphite.selection.opacity(0.85)), in: shape)
            .glassEffectTransition(.materialize)
            .help("This frame is flagged")
            .accessibilityHidden(true)
    }
}

/// The contact sheet's ground, between and under its cells: what the View and Roll menus do for the sheet,
/// the paste on the frames shown, and the roll's folder (docs/context-menus-plan.md, section 3). Opened from
/// AppKit, since no cell is there (`SheetGridController.menu(at:)`).
@MainActor enum SheetMenu {
    static func ground(model: RollModel) -> [MenuEntry] {
        MenuEntry.sections([
            show(model: model),
            size(model: model),
            [.action("sheet.pasteToShown", model.pasteToShownTitle, chord: ClipboardKeys.pasteToShown,
                     isEnabled: model.canPasteToShownFrames) { model.pasteAdjustmentsToShownFrames() }],
            files(model: model),
        ])
    }

    /// View > Show's three, the one in force checked.
    static func show(model: RollModel) -> [MenuEntry] {
        [.heading("sheet.show", "Show")] + FlagFilter.allCases.map { filter in
            .action("sheet.show.\(filter.rawValue)", filter.title, chord: KeyChord(filter.key.character, [.control, .command]),
                    isEnabled: model.canChangeFilter, isOn: model.flagFilter == filter) { model.showFrames(filter) }
        }
    }

    /// The thumbnails' size and Gray Surround, as the View menu has them on the sheet.
    static func size(model: RollModel) -> [MenuEntry] {
        [
            .action("sheet.larger", "Larger Thumbnails", chord: KeyChord("+", [.command]), isEnabled: model.canChangeSize(by: 1)) {
                model.changeSize(by: 1)
            },
            .action("sheet.smaller", "Smaller Thumbnails", chord: KeyChord("-", [.command]), isEnabled: model.canChangeSize(by: -1)) {
                model.changeSize(by: -1)
            },
            .action("sheet.graySurround", "Gray Surround", chord: KeyChord("g", [.shift, .command]), isOn: model.graySurround) {
                model.graySurround.toggle()
            },
        ]
    }

    /// Roll > Develop, and the roll's folder in Finder. On the sheet "Develop…" opens the Develop page; on that
    /// page's grid it is the page's button while that starts a develop, with its count (`developCommand`).
    static func files(model: RollModel) -> [MenuEntry] {
        let onPage = model.workspacePage == .develop
        return [
            .action("sheet.develop", onPage ? DevelopPrimary.develop(count: model.framesToDevelop().count).title : "Develop…",
                    chord: KeyChord("d", [.command]), isEnabled: onPage ? model.canDevelop : model.roll != nil && !model.isScanning) {
                        model.developCommand()
                    },
            .action("sheet.showRoll", "Show Roll in Finder", isEnabled: model.roll != nil) { model.showRollInFinder() },
        ]
    }
}

#if DEBUG
/// What the contact sheet has on screen, for the drive hook's sheet and stock-switch measurements: the
/// frames whose cells are at least partly in the scroll view, and when each frame's sheet cell last put
/// up its embedded preview and its film, with the stock and settings the film was rendered with.
@MainActor enum SheetProbe {
    static var visibleFrames: () -> [URL] = { [] }
    static var previews: [URL: (pixels: Int, time: CFTimeInterval)] = [:]
    static var films: [URL: (stock: Int, settings: DevelopSettings, time: CFTimeInterval)] = [:]
    /// How many times each frame's sheet cell has been drawn, for the tests that hold what makes one draw again.
    static var cellsDrawn: [URL: Int] = [:]
    static func cellDrawn(_ frame: URL) { cellsDrawn[frame, default: 0] += 1 }

    static var visible: [URL] { visibleFrames() }
}
#endif
