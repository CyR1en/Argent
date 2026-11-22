import AppKit
import ArgentRoll
import SwiftUI

/// Where the contact sheet's cells go: columns of at least the size step's width sharing the room,
/// each cell a 3:2 well with its file name under it, on whole points. Pure arithmetic, so the layout
/// can place any cell of any roll without walking the others, and arrow keys can scroll to a cell not
/// yet made.
struct SheetGeometry: Equatable {
    private typealias Spacing = ContactSheet.Spacing

    /// The file name's line: the label face's height, and the gap above it.
    static let labelHeight: CGFloat = 16
    static let labelGap: CGFloat = 6

    let width: CGFloat
    let columns: Int
    let cell: CGFloat
    /// The first column's left edge: the margin, and half of what whole-point cells leave over.
    let leading: CGFloat

    init(width: CGFloat, targetCell: CGFloat) {
        let available = max(0, width - 2 * Spacing.margin)
        let columns = Spacing.columns(fitting: available, cell: targetCell)
        let cell = max(Metrics.thumbnailWidths[0],
                       ((available - CGFloat(columns - 1) * Spacing.gutter) / CGFloat(columns)).rounded(.down))
        self.width = width
        self.columns = columns
        self.cell = cell
        let used = CGFloat(columns) * cell + CGFloat(columns - 1) * Spacing.gutter
        leading = Spacing.margin + max(0, ((available - used) / 2).rounded(.down))
    }

    var rowHeight: CGFloat { (cell * 2 / 3 + Self.labelGap + Self.labelHeight).rounded(.up) }
    private var pitch: CGFloat { rowHeight + Spacing.rowGap }

    /// The height of `count` cells' rows between the fades' room above and below them.
    func contentHeight(count: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return Spacing.topFade + (rows > 0 ? CGFloat(rows) * pitch - Spacing.rowGap : 0) + Spacing.bottomFade
    }

    func frame(ofItem index: Int) -> CGRect {
        CGRect(x: leading + CGFloat(index % columns) * (cell + Spacing.gutter),
               y: Spacing.topFade + CGFloat(index / columns) * pitch,
               width: cell, height: rowHeight)
    }

    /// The cell of the `count` under `point`, its picture or its file name; `nil` on the ground between and
    /// round them, where the sheet's own menu opens.
    func item(at point: CGPoint, count: Int) -> Int? {
        guard point.y >= Spacing.topFade, point.x >= leading else { return nil }
        let row = Int(((point.y - Spacing.topFade) / pitch).rounded(.down))
        let column = Int(((point.x - leading) / (cell + Spacing.gutter)).rounded(.down))
        guard column < columns else { return nil }
        let index = row * columns + column
        guard index < count, frame(ofItem: index).contains(point) else { return nil }
        return index
    }

    /// The cells of the `count` that `rect` may touch, whole rows of them.
    func items(in rect: CGRect, count: Int) -> Range<Int> {
        guard count > 0, !rect.isEmpty else { return 0..<0 }
        let firstRow = max(0, Int(((rect.minY - Spacing.topFade) / pitch).rounded(.down)))
        let lastRow = max(firstRow, Int(((rect.maxY - Spacing.topFade) / pitch).rounded(.down)))
        let first = min(count, firstRow * columns)
        return first..<min(count, (lastRow + 1) * columns)
    }

    /// Where the scroll view should stand, at `current` and `viewport` tall, to show cell `index`:
    /// in its middle, or as little as it takes to bring the cell clear of the fades.
    func offset(revealing index: Int, count: Int, current: CGFloat, viewport: CGFloat, centered: Bool) -> CGFloat {
        let item = frame(ofItem: index)
        var target = current
        if centered {
            target = item.midY - viewport / 2
        } else if item.minY - Spacing.topFade < current {
            target = item.minY - Spacing.topFade
        } else if item.maxY + Spacing.bottomFade > current + viewport {
            target = item.maxY + Spacing.bottomFade - viewport
        }
        return min(max(0, target), max(0, contentHeight(count: count) - viewport))
    }

    /// The picture well of cell `index`, without its file name.
    func well(ofItem index: Int) -> CGRect {
        var well = frame(ofItem: index)
        well.size.height = cell * 2 / 3
        return well
    }

    /// Where cell `index`'s well will be, in the scroll view's own points from its top left, once a sheet that comes back
    /// `viewport` tall has brought the cell to its middle, as it does for the frame that was open (`ContactSheet`). The
    /// frame view shrinks to it on the way back, before the sheet is there to ask (`FrameHero`).
    func wellRevealed(ofItem index: Int, count: Int, viewport: CGFloat) -> CGRect {
        let scrolled = offset(revealing: index, count: count, current: 0, viewport: viewport, centered: true)
        return well(ofItem: index).offsetBy(dx: 0, dy: -scrolled)
    }
}

/// A sheet cell's file name as a picture, drawn once for each name, colour and width and kept. A `Text`
/// lays out and draws its glyphs on the main thread whenever a recycled cell takes another frame, the
/// largest part of what a new row costs (docs/M2-shell.md, The contact sheet's scrolling).
@MainActor enum SheetFileName {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 16 << 20
        return cache
    }()

    /// `name` in the sheet's label face with tabular figures, truncated in the middle to `limit` points,
    /// on a canvas `SheetGeometry.labelHeight` tall and only as wide as the text.
    static func image(_ name: String, color: Color, limit: CGFloat, scale: CGFloat) -> CGImage? {
        guard !name.isEmpty, limit > 0, scale > 0,
              let resolved = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let key = "\(name)|\(resolved.redComponent),\(resolved.greenComponent),\(resolved.blueComponent),\(resolved.alphaComponent)|\(limit)|\(scale)" as NSString
        if let kept = cache.object(forKey: key) { return kept.image }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: resolved,
            .paragraphStyle: paragraph,
        ])
        let width = min(limit, text.size().width.rounded(.up))
        let pixels = (width: Int((width * scale).rounded(.up)), height: Int((SheetGeometry.labelHeight * scale).rounded(.up)))
        guard pixels.width > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(in: NSRect(x: 0, y: 0, width: width, height: SheetGeometry.labelHeight))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        cache.setObject(Entry(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

/// The contact sheet's scroll view and its cells. SwiftUI's lazy grid builds a whole view graph for each
/// cell that scrolls in and tears down each that leaves, on the main thread, and walks every cell it has
/// in each display frame; on a 120 Hz display a new row alone took two to six frames. This keeps the
/// cells as they are, each a SwiftUI `SheetCell`, but an `NSCollectionView` recycles them: a cell leaving
/// the sheet's top comes back at its foot with another frame's inputs, and between rows a display frame
/// only moves the scroll view's layers. Measured in docs/M2-shell.md, The contact sheet's scrolling.
struct SheetGrid: NSViewRepresentable {
    let controller: SheetGridController
    let frames: [Frame]
    let geometry: SheetGeometry
    /// The thumbnails' size step (`Metrics.thumbnailWidths`): a change of it is glided to, where a change of the sheet's
    /// width, which moves the cells too, is not.
    var sizeStep = 0
    let selection: Frame.ID?
    /// The frames selected, the lead (`selection`) among them: each wears the ring.
    var selected: Set<Frame.ID> = []
    let isFlagged: (Frame) -> Bool
    /// The Develop page's mark on a frame; none on the roll's own sheet.
    var mark: (Frame) -> DevelopMark? = { _ in nil }
    let model: RollModel
    /// A click on a frame's cell, with what the keys held with it ask (`SelectionClick`).
    let select: (Frame, SelectionClick) -> Void
    let pinched: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView { controller.makeScrollView() }

    func updateNSView(_ scroller: NSScrollView, context: Context) {
        controller.update(SheetGridController.Content(frames: frames, geometry: geometry, sizeStep: sizeStep, selection: selection,
                                                      selected: selected.isEmpty ? Set([selection].compactMap { $0 }) : selected,
                                                      isFlagged: isFlagged, mark: mark, model: model, select: select, pinched: pinched))
    }
}

/// What a recycled cell shows: its inputs compared, so one that has not changed is not asked to redraw.
struct SheetCellInputs: Equatable {
    var frame: Frame
    var width: CGFloat
    var isSelected: Bool
    var isFlagged: Bool
    var mark: DevelopMark?
    /// In the sheet rather than waiting to be used again, so its picture work is let go.
    var isActive = true
}

/// How a cell takes inputs that differ from the ones it shows. Nothing moves when a recycled cell takes another frame;
/// what changes on the frame it already shows may.
struct SheetCellMotion: Equatable {
    /// The frame's flag or its develop's mark changed: the badge lands on the picture, or leaves it.
    var lands = false
    /// The thumbnails' size changed: the cell grows or shrinks to it, as the sheet moves it to its new place.
    var resizes = false
}

/// A cell as its hosting view shows it.
private struct HostedSheetCell: View {
    let inputs: SheetCellInputs?
    var motion = SheetCellMotion()
    let model: RollModel
    let select: () -> Void
    let opens: () -> Bool
    let showMenu: () -> Void

    var body: some View {
        if let inputs {
            SheetCell(frame: inputs.frame, width: inputs.width, isSelected: inputs.isSelected, isFlagged: inputs.isFlagged,
                      mark: inputs.mark, isActive: inputs.isActive, lands: motion.lands, select: select, opens: opens,
                      showMenu: showMenu)
                .animation(motion.resizes ? SheetGridController.sizeEase : nil, value: inputs.width)
                .environment(model)
        }
    }
}

/// A cell's hosting view, which gives a right-click and a Control-click to the sheet's menu (`SheetCollectionView`).
/// SwiftUI's own would take a right-click as a click on a cell with no menu of its own, and never ask for one.
///
/// It also keeps what the press it last took asks of a click (`click`), from the press's own event: the keys held with
/// it, or nothing for a press that opened the menu. SwiftUI's tap, which comes at the release and carries no event,
/// reads it there. It takes a right-click's release for a tap too, and a plain tap on one of several frames selected
/// would leave it alone selected under the menu just opened for them all.
private final class SheetCellHost: NSHostingView<HostedSheetCell> {
    /// What the last press on the cell asks of the tap that follows it; `nil` for one that opened the menu.
    private(set) var click: SelectionClick? = .alone

    private var sheet: SheetCollectionView? {
        sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? SheetCollectionView }.first
    }

    override func rightMouseDown(with event: NSEvent) {
        click = nil
        sheet?.openMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.asksForContextMenu, let sheet {
            click = nil
            sheet.openMenu(with: event)
        } else {
            click = SelectionClick(event.modifierFlags)
            super.mouseDown(with: event)
        }
    }

    /// A Control-click in a window in the background opens the menu, as a right-click does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        event?.asksForContextMenu == true || super.acceptsFirstMouse(for: event)
    }
}

/// The sheet's collection view, whose one menu is a cell's or the ground's by where it is asked for
/// (`SheetGridController.menu(at:)`), so the table is made only then and from the sheet's own arithmetic. Opened
/// here on a right-click and a Control-click alike, rather than given to AppKit by `menu(for:)`, which the window
/// would show itself on a Control-click (`ContextMenuPresentation`). The import review's grid is one too (`ImportGridController`).
final class SheetCollectionView: NSCollectionView {
    var menuAt: (NSPoint) -> NSMenu? = { _ in nil }

    func openMenu(with event: NSEvent) {
        guard let menu = menuAt(convert(event.locationInWindow, from: nil)) else { return }
        ContextMenuPresentation.popUp(menu, event, self)
    }

    override func rightMouseDown(with event: NSEvent) { openMenu(with: event) }

    override func mouseDown(with event: NSEvent) {
        if event.asksForContextMenu { openMenu(with: event) } else { super.mouseDown(with: event) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        event?.asksForContextMenu == true || super.acceptsFirstMouse(for: event)
    }
}

/// A recycled cell's own view, which keeps the hosting view put in it by `host(_:)` at its bounds. It sets that frame
/// as it puts the view in, as the cell is resized (in `resizeSubviews(withOldSize:)`, so inside whatever animation
/// resizes the cell), and as the item is recycled (`fitHosted()`); at no other time. Not by autoresizing, which adds
/// each change of the cell's size to the hosting view's frame as it stands: a hosting view glided to a new size has its
/// frame stepped there (`SheetGridController.sizeGlide`), so a second size step before the first has landed would be
/// added to a frame still on its way, and leave the cell's contents another size than the cell and off their place for
/// good. Set to the bounds as the cell is sized, the frame glides with the cell as it did. Any other subview resizes by
/// its own autoresizing mask, as in any view. An import's review has its cells in one too (`ImportItem`).
final class HostedCellView: NSView {
    /// The hosting view kept at the bounds.
    private(set) weak var hosted: NSView?

    /// Puts `view` in the cell at its bounds, in place of the hosting view there before.
    func host(_ view: NSView) {
        if hosted !== view { hosted?.removeFromSuperview() }
        view.autoresizingMask = []
        view.frame = bounds
        if view.superview !== self { addSubview(view) }
        hosted = view
    }

    /// Puts the hosting view back on the bounds at once, as the item is recycled: its cell has left the view in its old
    /// role, so whatever the frame was gliding to there is nothing now. A plain set, which stops a glide of the frame,
    /// even when called inside an animation group that lets changes animate, as the sheet's size glide does.
    func fitHosted() {
        guard let hosted, hosted.frame != bounds else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            hosted.frame = bounds
        }
    }

    /// What `NSView` does, each subview resized by its autoresizing mask, for every subview but the hosting view, which
    /// is set to the bounds.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for subview in subviews where subview !== hosted { subview.resize(withOldSuperviewSize: oldSize) }
        hosted?.frame = bounds
    }
}

/// One recycled cell: a hosting view, kept from one frame to the next.
private final class SheetItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SheetItem")
    private var host: SheetCellHost?
    private(set) var inputs: SheetCellInputs?
    /// What the last press on the cell asks of the tap that follows it (`SheetCellHost.click`).
    var click: SelectionClick? { host.map(\.click) ?? .alone }

    private let cell = HostedCellView()

    override func loadView() {
        view = cell
        view.wantsLayer = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cell.fitHosted()
    }

    /// `moves` is whether anything may move at all: not with Reduce Motion. `resizes` is whether a new width is a new
    /// size step's, to be glided to.
    func show(_ inputs: SheetCellInputs, moves: Bool = false, resizes: Bool = false, model: RollModel, select: @escaping () -> Void,
              opens: @escaping () -> Bool, showMenu: @escaping () -> Void) {
        guard inputs != self.inputs else { return }
        var motion = SheetCellMotion()
        // Only on the frame the cell already shows, in the sheet: a recycled cell takes its next frame as it is. By its file:
        // frames are numbered again when some leave the roll, and another may come to wear this one's number.
        if moves, let shown = self.inputs, shown.frame.url == inputs.frame.url, shown.isActive, inputs.isActive {
            motion.lands = shown.isFlagged != inputs.isFlagged || shown.mark != inputs.mark
            motion.resizes = resizes && shown.width != inputs.width
        }
        self.inputs = inputs
        let root = HostedSheetCell(inputs: inputs, motion: motion, model: model, select: select, opens: opens, showMenu: showMenu)
        if let host {
            host.rootView = root
        } else {
            let made = SheetCellHost(rootView: root)
            // The item gives it its size (`HostedCellView`); the window's title bar is nothing to it.
            made.sizingOptions = []
            made.safeAreaRegions = []
            cell.host(made)
            host = made
        }
    }
}

/// Places the cells by `SheetGeometry` alone, so its cost does not grow with the roll.
final class SheetGridLayout: NSCollectionViewLayout {
    var geometry = SheetGeometry(width: 0, targetCell: Metrics.thumbnailWidths[0])
    var count = 0

    override var collectionViewContentSize: NSSize {
        NSSize(width: geometry.width, height: geometry.contentHeight(count: count))
    }

    private func attributes(_ index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = geometry.frame(ofItem: index)
        return attributes
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        geometry.items(in: rect, count: count).map(attributes)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        indexPath.item < count ? attributes(indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { false }
}

/// The sheet's collection view, kept with the sheet's state so the sheet can ask it to scroll.
@MainActor final class SheetGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    struct Content {
        var frames: [Frame]
        var geometry: SheetGeometry
        var sizeStep = 0
        var selection: Frame.ID?
        var selected: Set<Frame.ID> = []
        var isFlagged: (Frame) -> Bool
        var mark: (Frame) -> DevelopMark? = { _ in nil }
        var model: RollModel
        var select: (Frame, SelectionClick) -> Void
        var pinched: (CGFloat) -> Void
    }

    private var content: Content?
    private let layout = SheetGridLayout()
    private weak var scroller: NSScrollView?
    private weak var collection: SheetCollectionView?
    private var pendingReveal: (frame: Frame.ID, centered: Bool, duration: TimeInterval?)?
    private var preparing: Task<Void, Never>?
    private static let rowsAhead = 3
    /// The cells of the update under way go to a new size step's width (`SheetCellMotion.resizes`).
    private var isResizing = false
    /// How a change of the thumbnails' size is glided to: the cells to their new places over `sizeGlide` on `sizeCurve`,
    /// which AppKit moves, and each cell's contents to their new size over the same time on the same curve, which SwiftUI
    /// moves, so a cell and what is in it stay together and no picture runs over its neighbour on the way.
    static let sizeGlide: TimeInterval = 0.4 * Graphite.Motion.slow
    static let sizeCurve: (Float, Float, Float, Float) = (0.2, 0.9, 0.3, 1)
    static let sizeEase = Animation.timingCurve(Double(sizeCurve.0), Double(sizeCurve.1), Double(sizeCurve.2), Double(sizeCurve.3),
                                                duration: sizeGlide)
    private var movesAllowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func makeScrollView() -> NSScrollView {
        let collection = SheetCollectionView()
        collection.menuAt = { [weak self] point in self?.menu(at: point) }
        collection.collectionViewLayout = layout
        collection.register(SheetItem.self, forItemWithIdentifier: SheetItem.identifier)
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.isSelectable = false
        collection.autoresizingMask = [.width]
        collection.addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(magnified(_:))))

        let scroller = NSScrollView()
        scroller.documentView = collection
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.horizontalScrollElasticity = .none
        self.scroller = scroller
        self.collection = collection
        // A scroll of the user's, by wheel, trackpad or scroller.
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: name, object: scroller)
        }
        #if DEBUG
        SheetProbe.visibleFrames = { [weak self] in self?.visibleFrames ?? [] }
        #endif
        return scroller
    }

    /// The sheet was scrolled by hand, or by the keys to a frame out of its view. The roll's sheet tells the model, for
    /// a frame view on its way to a cell that is then no longer where it is going (`RollModel.sheetScrolled`).
    @objc private func scrolled() {
        guard let model = content?.model, model.sheetGrid === self else { return }
        model.sheetScrolled()
    }

    func update(_ new: Content) {
        let old = content
        content = new
        guard let collection else { return }
        // The same frames in the same places, by number and by file: frames that leave the roll number the rest again.
        let sameFrames = old.map { $0.frames.count == new.frames.count
            && zip($0.frames, new.frames).allSatisfy { $0.id == $1.id && $0.url == $1.url } } ?? false
        // Another size step for the frames already there, in a sheet as wide as it was: the cells glide to their new
        // places and sizes. A resize of the window, a filter or another roll places them at once, as they always were.
        isResizing = sameFrames && movesAllowed && collection.window != nil && old.map { $0.sizeStep != new.sizeStep
            && $0.geometry.width == new.geometry.width && $0.geometry.width > 0 } == true
        defer { isResizing = false }
        if old?.geometry != new.geometry || old?.frames.count != new.frames.count {
            if isResizing {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.sizeGlide
                    context.timingFunction = CAMediaTimingFunction(controlPoints: Self.sizeCurve.0, Self.sizeCurve.1, Self.sizeCurve.2, Self.sizeCurve.3)
                    context.allowsImplicitAnimation = true
                    collection.animator().performBatchUpdates({
                        layout.geometry = new.geometry
                        layout.count = new.frames.count
                        layout.invalidateLayout()
                    }, completionHandler: nil)
                }
            } else {
                layout.geometry = new.geometry
                layout.count = new.frames.count
                layout.invalidateLayout()
            }
        }
        if !sameFrames {
            collection.reloadData()
        } else {
            for path in collection.indexPathsForVisibleItems() {
                (collection.item(at: path) as? SheetItem).map { show($0, at: path.item) }
            }
        }
        revealPending()
        if new.geometry.width > 0, !new.frames.isEmpty, old?.geometry != new.geometry || old?.frames.count != new.frames.count {
            prepareAhead()
        }
    }

    /// Makes the cells of a few rows past each edge, a row a turn, while nothing is scrolling. A hosting
    /// view is slow to make and quick to reuse: made here, the first scroll of a roll only reuses them,
    /// and cells near the view have their pictures up when they arrive.
    private func prepareAhead() {
        preparing?.cancel()
        preparing = Task { [weak self] in
            for rows in 1...Self.rowsAhead {
                try? await Task.sleep(for: .milliseconds(rows == 1 ? 150 : 40))
                guard !Task.isCancelled, let self, let scroller = self.scroller, let collection = self.collection,
                      let content = self.content else { return }
                let reach = CGFloat(rows) * (content.geometry.rowHeight + ContactSheet.Spacing.rowGap)
                collection.prepareContent(in: scroller.contentView.bounds.insetBy(dx: 0, dy: -reach))
            }
        }
    }

    /// Where `frame`'s well is in the window's content, in points from its top left, as SwiftUI's global space has it;
    /// `nil` when the sheet is not in a window, does not show the frame, or has its well outside the scroll view.
    func wellInWindow(of frame: Frame.ID) -> CGRect? {
        guard let content, let collection, let scroller, let root = collection.window?.contentView,
              let index = content.frames.firstIndex(where: { $0.id == frame }) else { return nil }
        let well = content.geometry.well(ofItem: index)
        guard well.intersects(scroller.contentView.bounds) else { return nil }
        var rect = collection.convert(well, to: root)
        if !root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
        return rect
    }

    /// Scrolls to frame `frame` once the sheet has taken in what is changing with it: at once, or `animated` as
    /// `Motion.stateChange` moves things, or with the thumbnails as they glide to a new size (`resizing`).
    func reveal(_ frame: Frame.ID, centered: Bool, animated: Bool = false, resizing: Bool = false) {
        pendingReveal = (frame, centered, resizing ? Self.sizeGlide : animated ? 0.2 : nil)
        DispatchQueue.main.async { [weak self] in self?.revealPending() }
    }

    private func revealPending() {
        // Kept until the sheet has its width; a frame the sheet does not show has nowhere to go.
        guard let request = pendingReveal, let content, content.geometry.width > 0, let scroller else { return }
        pendingReveal = nil
        guard let index = content.frames.firstIndex(where: { $0.id == request.frame }) else { return }
        scroller.layoutSubtreeIfNeeded()
        let clip = scroller.contentView
        let y = content.geometry.offset(revealing: index, count: content.frames.count, current: clip.bounds.minY,
                                        viewport: clip.bounds.height, centered: request.centered)
        guard abs(y - clip.bounds.minY) >= 0.5 else { return }
        // To a frame the keys moved to; a sheet put on its frame, as one coming back from the frame view is, has not left it.
        if !request.centered { scrolled() }
        let target = NSPoint(x: clip.bounds.minX, y: y)
        if let duration = request.duration, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = duration
                // With the thumbnails as they glide to a new size, on their curve; else as `Motion.stateChange` eases.
                animation.timingFunction = duration == Self.sizeGlide
                    ? CAMediaTimingFunction(controlPoints: Self.sizeCurve.0, Self.sizeCurve.1, Self.sizeCurve.2, Self.sizeCurve.3)
                    : CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scroller.reflectScrolledClipView(clip)
    }

    private func show(_ item: SheetItem, at index: Int, isActive: Bool = true) {
        guard let content, content.frames.indices.contains(index) else { return }
        let frame = content.frames[index]
        let inputs = SheetCellInputs(frame: frame, width: content.geometry.cell, isSelected: content.selected.contains(frame.id),
                                     isFlagged: content.isFlagged(frame), mark: content.mark(frame), isActive: isActive)
        item.show(inputs, moves: movesAllowed, resizes: isResizing, model: content.model,
                  select: { [weak self, weak item] in
                      // As the press asked: with its keys, or not at all after one that opened the menu.
                      guard let item, let click = item.click else { return }
                      self?.content?.select(frame, click)
                  },
                  opens: { [weak item] in item?.click == .alone },
                  showMenu: { [weak self] in self?.showMenu(for: frame) })
    }

    // MARK: The sheet's menus

    /// The menu asked for at `point` in the collection view: on a cell, its frame's (`FrameMenu`), the cell selected
    /// first as Finder selects what it opens a menu for, so the ring shows what the menu is for; on a cell that is one
    /// of several selected, theirs, the selection left as it is; on the ground between and under them, the sheet's own
    /// (`SheetMenu`). Made now, from what the model holds now: never as a cell is drawn.
    private func menu(at point: NSPoint) -> NSMenu? {
        guard let content else { return nil }
        guard let index = content.geometry.item(at: point, count: content.frames.count) else {
            return NSMenu(entries: SheetMenu.ground(model: content.model))
        }
        return NSMenu(entries: FrameMenu.entries(for: framesForMenu(on: content.frames[index]), on: .sheet, model: content.model))
    }

    /// The frames a menu opened on `frame`'s cell is for: the several selected when it is one of them, else the frame,
    /// selected alone first.
    private func framesForMenu(on frame: Frame) -> [Frame] {
        guard let content else { return [frame] }
        let frames = content.model.framesActedOn(from: frame)
        if frames.count == 1 { select(frame) }
        return frames
    }

    /// Selects `frame` alone as a click does, and rings it at once: the sheet's own update follows the model in a
    /// later turn, and the menu about to open would otherwise stand over the old ring.
    private func select(_ frame: Frame) {
        guard var content else { return }
        content.select(frame, .alone)
        guard content.selection != frame.id || content.selected != [frame.id] else { return }
        content.selection = frame.id
        content.selected = [frame.id]
        update(content)
        collection?.displayIfNeeded()
    }

    /// VoiceOver's Show Menu on a cell: the menu under the cell's picture, the cell selected first as a click's is.
    private func showMenu(for frame: Frame) {
        guard let content, let collection, let index = content.frames.firstIndex(where: { $0.id == frame.id }) else { return }
        let frames = framesForMenu(on: frame)
        let well = content.geometry.frame(ofItem: index)
        NSMenu(entries: FrameMenu.entries(for: frames, on: .sheet, model: content.model))
            .popUp(positioning: nil, at: NSPoint(x: well.midX, y: well.minY + content.geometry.cell / 3), in: collection)
    }

    @objc private func magnified(_ recognizer: NSMagnificationGestureRecognizer) {
        if recognizer.state == .ended { content?.pinched(1 + recognizer.magnification) }
    }

    // MARK: NSCollectionViewDataSource, NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        content?.frames.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: SheetItem.identifier, for: indexPath)
        if let item = item as? SheetItem { show(item, at: indexPath.item) }
        return item
    }

    /// A cell off the sheet lets its picture work go, as one a lazy grid removes does: a fast scroll
    /// does not leave the decodes of every frame it passed waiting in the queues.
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard let item = item as? SheetItem, let inputs = item.inputs, content?.frames.indices.contains(indexPath.item) == true,
              content?.frames[indexPath.item].id == inputs.frame.id else { return }
        show(item, at: indexPath.item, isActive: false)
    }

    #if DEBUG
    /// The frames whose cells are at least partly inside the scroll view, for `SheetProbe`.
    private var visibleFrames: [URL] {
        guard let content, let scroller else { return [] }
        return content.geometry.items(in: scroller.contentView.bounds, count: content.frames.count).compactMap { index in
            content.geometry.frame(ofItem: index).intersects(scroller.contentView.bounds) ? content.frames[index].url : nil
        }
    }
    #endif
}
