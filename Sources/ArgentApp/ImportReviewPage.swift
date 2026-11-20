import AppKit
import ArgentRoll
import SwiftUI

struct ImportReviewPage: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        switch model.importSession {
        case .idle:
            Color.clear
        case .scanning(_, let done, let total):
            ImportWait(title: ImportTopBar.readingText(total), detail: "\(done) of \(total)")
        case .reviewing(let review):
            ImportReviewSheet(review: review)
        case .copying(_, let folder, let done, let total):
            ImportWait(title: ImportTopBar.copyingText(done, of: total), detail: "To \(DevelopStatusText.abbreviated(folder))")
        case .finished(_, let folder, let new, let total):
            ImportWait(title: ImportTopBar.openingText(folder), detail: ImportTopBar.newText(new, of: total))
        case .failed(_, let message, let imported):
            ImportFailure(message: message, imported: imported)
        }
    }
}

struct ImportTopBar: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the strip's buttons are for, which changes how many there are and what they say.
    private enum Phase: Equatable { case none, reading, reviewing, copying, failed }

    private static func phase(_ session: ImportSession) -> Phase {
        switch session {
        case .idle, .finished: .none
        case .scanning: .reading
        case .reviewing: .reviewing
        case .copying: .copying
        case .failed: .failed
        }
    }

    var body: some View {
        let session = model.importSession
        let phase = Self.phase(session)
        GlassEffectContainer(spacing: Graphite.Metric.xs) {
            TitleStripLayout {
                Wordmark()
                ContextTitle(title: session.card?.name ?? "", subtitle: Self.subtitle(session))
                HStack(spacing: Graphite.Metric.m) {
                    if phase != .none {
                        dismissal(session)
                    }
                    // One button while the frames are read and once they are: two, each with its own way in and out,
                    // would have one leave over Close as the other came.
                    if phase == .reading || phase == .reviewing {
                        importButton(session)
                    }
                }
                .fixedSize()
            }
            // Import goes back into Close when there is nothing to import, an import that failed.
            .animation(reduceMotion ? nil : Graphite.Motion.bud, value: phase)
        }
    }

    /// Close, or Cancel for a copy: the strip is not up while the frames are copied (`RollModel.workspacePage`), where
    /// the Rolls page has Cancel, so this is Close whenever it shows.
    private func dismissal(_ session: ImportSession) -> some View {
        var copyingTo: URL?
        if case .copying(_, let folder, _, _) = session { copyingTo = folder }
        return Button {
            if copyingTo != nil { model.cancelCopy() } else { model.closeImport() }
        } label: {
            Text(copyingTo != nil ? "Cancel" : "Close").foregroundStyle(Graphite.shellText)
        }
        .buttonStyle(.graphite(.secondary))
        .keyboardShortcut(.cancelAction)
        .help(copyingTo.map { "Stop copying and go back to the review. The frames copied stay in \(DevelopStatusText.abbreviated($0)). Escape." }
              ?? "Close without importing. Nothing at the source is changed. Escape.")
    }

    /// Import, which waits while the frames are read and then says how many it takes.
    private func importButton(_ session: ImportSession) -> some View {
        var review: ImportReview?
        if case .reviewing(let reviewed) = session { review = reviewed }
        return Button {
            if review != nil { model.startCopy() }
        } label: {
            Text(verbatim: Self.importTitle(session))
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : Graphite.Motion.quick, value: Self.importTitle(session))
        }
        .buttonStyle(.graphite(.primary))
        .keyboardShortcut(review != nil ? .defaultAction : nil)
        .disabled(review.map { !$0.canCopy } ?? true)
        .help(review.map { review in
            review.clash.map(ImportReview.clashText)
                ?? "Copy the frames to import into \(Self.place(model.importSettings.destination, for: review)), "
                + "a new roll on the Rolls page. Return."
        } ?? "Import starts once the frames are read")
        .transition(.buds(reach: Graphite.Metric.m + 6))
    }

    static func subtitle(_ session: ImportSession) -> String {
        switch session {
        case .idle: ""
        case .scanning(_, _, let total): readingText(total)
        case .reviewing(let review): review.clash.map(ImportReview.clashText) ?? review.summary
        case .copying(_, _, let done, let total): copyingText(done, of: total)
        case .finished(_, let folder, _, _): openingText(folder)
        case .failed(_, _, let imported): imported.map { "\(RollModel.framesText($0.count)) in \($0.folder.lastPathComponent)" } ?? "Nothing imported"
        }
    }

    static func importTitle(_ session: ImportSession) -> String {
        guard case .reviewing(let review) = session else { return "Import" }
        return "Import \(RollModel.framesText(review.importCount))"
    }

    static func readingText(_ total: Int) -> String { "Reading \(RollModel.framesText(total))" }

    private static func place(_ destination: ImportDestination, for review: ImportReview) -> String {
        switch destination {
        case .pictures: DevelopStatusText.abbreviated(RollModel.picturesFolder(for: review))
        case .folder(let folder): DevelopStatusText.abbreviated(folder.appendingPathComponent(review.folderName, isDirectory: true))
        }
    }

    static func copyingText(_ done: Int, of total: Int) -> String { "Copying \(min(done + 1, total)) of \(total)" }

    static func openingText(_ folder: URL) -> String { "Opening \(folder.lastPathComponent)…" }

    static func keptText(_ imported: ImportedFrames?) -> String {
        guard let imported else { return "Nothing was imported, and nothing on the card was changed." }
        return "\(RollModel.framesText(imported.count)) \(imported.count == 1 ? "is" : "are") in \(DevelopStatusText.abbreviated(imported.folder)) "
            + "and \(imported.count == 1 ? "stays" : "stay") there. Nothing on the card was changed."
    }

    static func newText(_ new: Int, of total: Int) -> String {
        if new == total { return "\(RollModel.framesText(total)) copied" }
        if new == 0 { return total == 1 ? "The frame was there already" : "All \(total) frames were there already" }
        return "\(RollModel.framesText(new)) copied, \(total - new) there already"
    }
}

private struct ImportWait: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Graphite.Metric.s) {
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, Graphite.Metric.xs)
            Text(title)
                .font(Graphite.Typeface.panelTitle.monospacedDigit())
                .foregroundStyle(Graphite.text)
            Text(detail)
                .font(Graphite.Typeface.body.monospacedDigit())
                .foregroundStyle(Graphite.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ImportFailure: View {
    let message: String
    let imported: ImportedFrames?
    @Environment(RollModel.self) private var model

    var body: some View {
        VStack(spacing: Graphite.Metric.s) {
            Image(systemName: "sdcard")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Graphite.tertiaryText)
                .padding(.bottom, Graphite.Metric.xs)
                .accessibilityHidden(true)
            Text(message)
                .font(Graphite.Typeface.panelTitle)
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)
            Text(ImportTopBar.keptText(imported))
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
            Button("Close") { model.closeImport() }
                .buttonStyle(.graphite(.secondary))
                .padding(.top, Graphite.Metric.m)
        }
        .multilineTextAlignment(.center)
        .padding(ContactSheet.Spacing.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct ImportReviewSheet: View {
    let review: ImportReview
    @Environment(RollModel.self) private var model
    @FocusState private var focused: Bool
    @State private var grid = ImportGridController()
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Graphite.Metric.edge - 14)
            filterRow.zIndex(1)
            if let stop = review.stop {
                Notice(symbol: stop.failure == nil ? "folder" : "exclamationmark.triangle", text: stop.text, lineLimit: 3) { EmptyView() }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, Graphite.Metric.edge)
                    .padding(.bottom, Graphite.Metric.s)
                    .zIndex(1)
            }
            if review.shown.isEmpty {
                Text(review.filter == .toImport ? "No frames to import" : "No frames left \(review.leftPlace)")
                    .font(Graphite.Typeface.panelTitle)
                    .foregroundStyle(Graphite.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sheet.padding(.top, -ContactSheet.Spacing.topOverlap)
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: Graphite.Metric.m) {
            GraphiteSegmented(selection: Binding(get: { review.filter }, set: { filter in model.reviewImport { $0.show(filter) } }),
                              segments: ImportFilter.allCases.map { filter in
                                  let count = review.count(filter)
                                  let title = filter.title(isFolder: review.isFolder)
                                  return .init(value: filter, title: "\(title) \(count)",
                                               accessibilityLabel: "\(title), \(RollModel.framesText(count))")
                              },
                              size: .regular)
                .fixedSize()
                .accessibilityLabel("Show")
            Spacer(minLength: Graphite.Metric.m)
            // How many are selected stays whole in a narrow window; the hint after it shortens first.
            if review.selected.count > 1 {
                Text("\(review.selected.count) selected")
                    .font(Graphite.Typeface.small.monospacedDigit())
                    .foregroundStyle(Graphite.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(review.selected.count > 1 ? "Click one or press Space to change where they go"
                 : "Click a frame or press Space to change where it goes")
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.tertiaryText)
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .padding(.horizontal, Graphite.Metric.edge)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(height: SheetFilterBar.height)
    }

    private var sheet: some View {
        let geometry = SheetGeometry(width: width, targetCell: Metrics.thumbnailWidths[1])
        let columns = geometry.columns
        return GeometryReader { _ in
            ImportGrid(controller: grid, frames: width > 0 ? review.shown : [], geometry: geometry, review: review,
                       loader: model.importThumbnails, menu: { [model] in ImportMenu.entries(on: $0, model: model) }) { id, click in
                model.reviewImport { $0.click(id, click) }
                focused = true
            }
        }
        .overlay(alignment: .top) { edgeFade(height: ContactSheet.Spacing.topFade, from: .top, to: .bottom) }
        .overlay(alignment: .bottom) { edgeFade(height: ContactSheet.Spacing.bottom, from: .bottom, to: .top) }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard review.selection != nil else { return .ignored }
            model.reviewImport { $0.toggleSelected() }
            return .handled
        }
        // With Shift an arrow, Home or End extends the selection from where it started to the frame reached.
        .onKeyPress(keys: [.leftArrow]) { press in move { $0.moveSelection(by: -1, extending: press.modifiers.contains(.shift)) } }
        .onKeyPress(keys: [.rightArrow]) { press in move { $0.moveSelection(by: 1, extending: press.modifiers.contains(.shift)) } }
        .onKeyPress(keys: [.upArrow]) { press in move { $0.moveSelection(by: -columns, extending: press.modifiers.contains(.shift)) } }
        .onKeyPress(keys: [.downArrow]) { press in move { $0.moveSelection(by: columns, extending: press.modifiers.contains(.shift)) } }
        .onKeyPress(keys: [.home]) { press in move { $0.selectEnd(last: false, extending: press.modifiers.contains(.shift)) } }
        .onKeyPress(keys: [.end]) { press in move { $0.selectEnd(last: true, extending: press.modifiers.contains(.shift)) } }
        // Edit > Select All, Command-A, while the review has the keys: every frame shown.
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.reviewImport { $0.selectAll() } }
        .onAppear { focused = true }
        .onChange(of: review.selection) {
            if let selection = review.selection { grid.reveal(selection) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frames \(review.isFolder ? "in the folder" : "on the card"), \(review.summary)")
    }

    private func move(_ change: (inout ImportReview) -> Void) -> KeyPress.Result {
        model.reviewImport(change)
        return .handled
    }

    private func edgeFade(height: CGFloat, from: UnitPoint, to: UnitPoint) -> some View {
        let ground = Graphite.workspace
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
}

private struct ImportGrid: NSViewRepresentable {
    let controller: ImportGridController
    let frames: [ImportFrame]
    let geometry: SheetGeometry
    let review: ImportReview
    let loader: ThumbnailLoader
    /// The menu for a right-click on a frame's cell, or on the ground between them (`ImportMenu`).
    let menu: (ImportFrame.ID?) -> [MenuEntry]
    /// A click on a frame's cell, with what the keys held with it ask.
    let click: (ImportFrame.ID, SelectionClick) -> Void

    func makeNSView(context: Context) -> NSScrollView { controller.makeScrollView() }

    func updateNSView(_ scroller: NSScrollView, context: Context) {
        controller.update(.init(frames: frames, geometry: geometry, review: review, loader: loader, menu: menu, click: click))
    }
}

/// The review's menu, on a frame's cell or the ground between them: the frame, or the several selected when it is one
/// of them, sent to import or left at the source, and Select All. Made when it is asked for, from the review as it is
/// then. A right-click on a frame that is not one of several selected selects it first, and changes nothing of where
/// it goes.
@MainActor enum ImportMenu {
    static func entries(on frame: ImportFrame.ID?, model: RollModel) -> [MenuEntry] {
        guard case .reviewing(let review) = model.importSession else { return [] }
        let selectAll = MenuEntry.action("import.selectAll", "Select All", chord: KeyChord("a", [.command]), isEnabled: !review.shown.isEmpty) {
            model.reviewImport { $0.selectAll() }
        }
        guard let frame else { return [selectAll] }
        let frames = review.framesActedOn(from: frame)
        if frames.count == 1, review.selection != frame || review.selected.count > 1 { model.reviewImport { $0.selection = frame } }
        return MenuEntry.sections([sending(frames, review: review, model: model), [selectAll]])
    }

    /// "Import" and "Leave on the Card", or with several "Import 5 Frames" and "Leave 5 Frames on the Card".
    static func sending(_ frames: [ImportFrame.ID], review: ImportReview, model: RollModel) -> [MenuEntry] {
        let place = review.isFolder ? "in the Folder" : "on the Card"
        let count = frames.count > 1 ? " \(RollModel.framesTitle(frames.count))" : ""
        return [
            .action("import.take", "Import" + count, isEnabled: frames.contains { !review.isKept($0) }) {
                model.reviewImport { $0.setKept(true, for: frames) }
            },
            .action("import.leave", "Leave\(count) \(place)", isEnabled: frames.contains(where: review.isKept)) {
                model.reviewImport { $0.setKept(false, for: frames) }
            },
        ]
    }
}

@MainActor final class ImportGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    struct Content {
        var frames: [ImportFrame]
        var geometry: SheetGeometry
        var review: ImportReview
        var loader: ThumbnailLoader
        var menu: (ImportFrame.ID?) -> [MenuEntry]
        var click: (ImportFrame.ID, SelectionClick) -> Void
    }

    private var content: Content?
    private let layout = SheetGridLayout()
    private weak var scroller: NSScrollView?
    private weak var collection: SheetCollectionView?
    private var pendingReveal: ImportFrame.ID?
    private var preparing: Task<Void, Never>?

    func makeScrollView() -> NSScrollView {
        let collection = SheetCollectionView()
        collection.menuAt = { [weak self] point in self?.menu(at: point) }
        collection.collectionViewLayout = layout
        collection.register(ImportItem.self, forItemWithIdentifier: ImportItem.identifier)
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.isSelectable = false
        collection.autoresizingMask = [.width]

        let scroller = NSScrollView()
        scroller.documentView = collection
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.horizontalScrollElasticity = .none
        self.scroller = scroller
        self.collection = collection
        #if DEBUG
        ImportProbe.visibleFrames = { [weak self] in self?.visibleFrames ?? [] }
        ImportProbe.loaded = []
        #endif
        return scroller
    }

    func update(_ new: Content) {
        let old = content
        content = new
        guard let collection else { return }
        if old?.geometry != new.geometry || old?.frames.count != new.frames.count {
            layout.geometry = new.geometry
            layout.count = new.frames.count
            layout.invalidateLayout()
        }
        if old?.frames.map(\.id) != new.frames.map(\.id) {
            collection.reloadData()
        } else {
            for path in collection.indexPathsForVisibleItems() {
                (collection.item(at: path) as? ImportItem).map { show($0, at: path.item) }
            }
        }
        revealPending()
        if new.geometry.width > 0, !new.frames.isEmpty, old?.geometry != new.geometry || old?.frames.count != new.frames.count {
            prepareAhead()
        }
    }

    private func prepareAhead() {
        preparing?.cancel()
        preparing = Task { [weak self] in
            for rows in 1...3 {
                try? await Task.sleep(for: .milliseconds(rows == 1 ? 150 : 40))
                guard !Task.isCancelled, let self, let scroller, let collection, let content else { return }
                let reach = CGFloat(rows) * (content.geometry.rowHeight + ContactSheet.Spacing.rowGap)
                collection.prepareContent(in: scroller.contentView.bounds.insetBy(dx: 0, dy: -reach))
            }
        }
    }

    func reveal(_ frame: ImportFrame.ID) {
        pendingReveal = frame
        DispatchQueue.main.async { [weak self] in self?.revealPending() }
    }

    private func revealPending() {
        guard let frame = pendingReveal, let content, content.geometry.width > 0, let scroller else { return }
        pendingReveal = nil
        guard let index = content.frames.firstIndex(where: { $0.id == frame }) else { return }
        scroller.layoutSubtreeIfNeeded()
        let clip = scroller.contentView
        let y = content.geometry.offset(revealing: index, count: content.frames.count, current: clip.bounds.minY,
                                        viewport: clip.bounds.height, centered: false)
        guard abs(y - clip.bounds.minY) >= 0.5 else { return }
        let target = NSPoint(x: clip.bounds.minX, y: y)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clip.setBoundsOrigin(target)
        } else {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.2
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(target)
            }
        }
        scroller.reflectScrolledClipView(clip)
    }

    private func show(_ item: ImportItem, at index: Int, isActive: Bool = true) {
        guard let content, content.frames.indices.contains(index) else { return }
        let frame = content.frames[index], review = content.review
        let inputs = ImportCellInputs(frame: frame, review: review, width: content.geometry.cell, isActive: isActive)
        item.show(inputs, loader: content.loader,
                  toggle: { [weak self, weak item] in
                      guard let item, let click = item.click else { return }
                      self?.content?.click(frame.id, click)
                  },
                  press: { [weak self] in self?.content?.click(frame.id, .alone) },
                  select: { [weak self] in self?.content?.click(frame.id, .toggle) })
    }

    /// The menu asked for at `point` in the collection view: a cell's frame's, or the ground's (`ImportMenu`).
    private func menu(at point: NSPoint) -> NSMenu? {
        guard let content else { return nil }
        let frame = content.geometry.item(at: point, count: content.frames.count).map { content.frames[$0].id }
        let entries = content.menu(frame)
        // A frame the menu selected is ringed at once: the grid's own update follows the model in a later turn, and the
        // menu about to open would otherwise stand over the old ring.
        if let frame, content.review.framesActedOn(from: frame).count == 1, content.review.selected != [frame] {
            var ringed = content
            ringed.review.selection = frame
            update(ringed)
            collection?.displayIfNeeded()
        }
        return entries.isEmpty ? nil : NSMenu(entries: entries)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        content?.frames.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ImportItem.identifier, for: indexPath)
        if let item = item as? ImportItem { show(item, at: indexPath.item) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard let item = item as? ImportItem, let inputs = item.inputs, content?.frames.indices.contains(indexPath.item) == true,
              content?.frames[indexPath.item].id == inputs.frame.id else { return }
        show(item, at: indexPath.item, isActive: false)
    }

    #if DEBUG
    private var visibleFrames: [ImportFrame.ID] {
        guard let content, let scroller else { return [] }
        return content.geometry.items(in: scroller.contentView.bounds, count: content.frames.count).compactMap { index in
            content.geometry.frame(ofItem: index).intersects(scroller.contentView.bounds) ? content.frames[index].id : nil
        }
    }
    #endif
}

/// An import's panel, beside its frames in the inspector's column: the roll's name and the folder it is made in, then
/// Cull, its switch and its four choices, then how the frames divide. Each change is kept for the next import
/// (`ImportSettings`), which starts as this one was left; Reset to defaults puts the cull back as it first was. A
/// change to the cull judges the frames again and keeps the ones moved by hand where they were put.
struct ImportPanel: View {
    let review: ImportReview
    @Environment(RollModel.self) private var model

    private static let top = Graphite.Metric.edge

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Roll")
                        .font(Graphite.Typeface.panelTitle)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 0) { rollRows }
                        .padding(.top, 14)
                        .padding(.bottom, 18)
                    SectionDivider()
                    VStack(alignment: .leading, spacing: 0) { cull }
                        .padding(.vertical, 18)
                }
                .padding(.horizontal, Graphite.Metric.inspectorPadding)
                .padding(.top, Self.top)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            SectionDivider()
            tally
                .padding(.horizontal, Graphite.Metric.inspectorPadding)
                .padding(.vertical, Graphite.Metric.inspectorPadding)
        }
        .frame(width: Graphite.Metric.inspectorPanelWidth)
        .graphiteFloating(cornerRadius: Graphite.Metric.workspaceRadius, besideWorkspace: true)
        .foregroundStyle(Graphite.text)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Import")
    }

    // MARK: The roll

    @ViewBuilder private var rollRows: some View {
        let defaultName = ImportReview.defaultName(firstCapture: review.firstCaptureDate)
        label("Name")
        TextField(defaultName, text: Binding(get: { review.name }, set: { name in model.reviewImport { $0.name = name } }))
            .textFieldStyle(.roundedBorder)
            .font(Graphite.Typeface.label)
            .help("The roll's name, and its folder's. The first frame's day until changed.")
            .accessibilityLabel("Name")
        label("Copy to")
            .padding(.top, 14)
        Menu { destinationChoices } label: { MenuFace(text: Self.title(model.importSettings.destination)) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityRepresentation {
                Menu("Copy to") { destinationChoices }
                    .accessibilityValue(Self.title(model.importSettings.destination))
            }
            .help("The folder Import makes the roll's folder in: ~/Pictures/Argent, or a folder you choose")
        Text(verbatim: "\u{2192} " + DevelopStatusText.abbreviated(rollFolder) + "/")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Graphite.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.top, 7)
            .help(rollFolder.path)
            .accessibilityLabel("The roll's folder, \(DevelopStatusText.abbreviated(rollFolder))")
    }

    /// The roll's folder as the import will make it, without reaching a chosen folder's bookmark.
    private var rollFolder: URL {
        let parent: URL = switch model.importSettings.destination {
        case .pictures: RollModel.argentPictures
        case .folder(let folder): folder
        }
        return parent.appendingPathComponent(review.folderName, isDirectory: true)
    }

    @ViewBuilder private var destinationChoices: some View {
        let current = model.importSettings.destination
        Picker("Copy to", selection: Binding(get: { current }, set: { model.setImportDestination($0) })) {
            Text(verbatim: Self.title(.pictures)).tag(ImportDestination.pictures)
            if case .folder = current { Text(verbatim: Self.title(current)).tag(current) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button("Choose…") { model.chooseImportDestination() }
    }

    static func title(_ destination: ImportDestination) -> String {
        switch destination {
        case .pictures: "~/Pictures/Argent"
        case .folder(let folder): DevelopStatusText.abbreviated(folder)
        }
    }

    // MARK: Cull

    @ViewBuilder private var cull: some View {
        let settings = model.importSettings
        HStack {
            Text("Cull")
                .font(Graphite.Typeface.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Toggle("Cull", isOn: Binding(get: { settings.isCulling }, set: { model.importSettings.isCulling = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(settings.isCulling ? "Import every frame" : "Leave the frames you would likely skip \(review.leftPlace)")
        }
        Text("Leaves the frames you would likely skip \(review.leftPlace). You can still move any frame by hand.")
            .font(Graphite.Typeface.small)
            .foregroundStyle(Graphite.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        Group {
            label("Burst gap").padding(.top, 14)
            segmented("Burst gap", BurstGapChoice.allCases, selected: BurstGapChoice(settings.cull), title: \.title,
                      help: "Frames taken no farther apart than this are one burst") {
                model.importSettings.cull.burstGap = $0.seconds
            }
            label("Soft focus").padding(.top, 12)
            segmented("Soft focus", SoftFocusChoice.allCases, selected: SoftFocusChoice(settings.cull), title: \.title,
                      help: "How soft a face may be before its frame is left out: Strict leaves more out, Loose fewer") {
                $0.apply(to: &model.importSettings.cull)
            }
            label("Eyes closed").padding(.top, 12)
            segmented("Eyes closed", [true, false], selected: settings.cull.leavesEyesClosed, title: { $0 ? "Leave out" : "Keep" },
                      help: "Whether a frame whose face has its eyes closed is left out or imported") {
                model.importSettings.cull.leavesEyesClosed = $0
            }
            label("Same moment").padding(.top, 12)
            segmented("Same moment", SameMomentChoice.allCases, selected: SameMomentChoice(settings.cull), title: \.title,
                      help: "How alike a burst's frame must be to the frame imported to be left out: Wide leaves more out, Narrow fewer") {
                model.importSettings.cull.sameMomentWithin = $0.within
            }
        }
        .disabled(!settings.isCulling)
        .opacity(settings.isCulling ? 1 : 0.45)
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .accessibilityHidden(true)
            Text(model.isImportCullDefault ? "The defaults" : "As your last import")
            Text(verbatim: "·").accessibilityHidden(true)
            Button("Reset to defaults") { model.resetImportCull() }
                .buttonStyle(.plain)
                .underline()
                .foregroundStyle(Graphite.secondaryText)
                .disabled(model.isImportCullDefault)
                .help("Put the cull back as it first was, and on")
        }
        .font(Graphite.Typeface.caption)
        .foregroundStyle(Graphite.tertiaryText)
        .padding(.top, 14)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Graphite.Typeface.small)
            .foregroundStyle(Graphite.secondaryText)
            .padding(.bottom, 6)
            .accessibilityHidden(true)
    }

    private func segmented<Value: Hashable>(_ label: String, _ values: [Value], selected: Value?, title: (Value) -> String,
                                            help: String, choose: @escaping (Value) -> Void) -> some View {
        GraphiteSegmented(selection: Binding(get: { selected }, set: { if let value = $0 { choose(value) } }),
                          segments: values.map { .init(value: $0, title: title($0), help: help) },
                          size: .small, fillsWidth: true)
            .accessibilityLabel(label)
    }

    // MARK: Tally

    private var tally: some View {
        let total = max(review.frames.count, 1)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Graphite.ink(0.12))
                    Capsule().fill(Graphite.text)
                        .frame(width: proxy.size.width * CGFloat(review.importCount) / CGFloat(total))
                }
            }
            .frame(height: 6)
            .animation(Graphite.Motion.quick, value: review.importCount)
            .accessibilityHidden(true)
            HStack {
                Text("\(Text("\(review.importCount)").fontWeight(.semibold)) to import")
                Spacer()
                Text("\(Text("\(review.count(.left))").fontWeight(.semibold)) left \(review.leftPlace)")
            }
            .font(Graphite.Typeface.small.monospacedDigit())
            .foregroundStyle(Graphite.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}
