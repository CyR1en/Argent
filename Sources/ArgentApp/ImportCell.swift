import AppKit
import ArgentRoll
import SwiftUI

struct ImportCellInputs: Equatable {
    var frame: ImportFrame
    var badge: ImportBadge?
    var isKept: Bool
    var isChanged: Bool
    var leftPlace: String
    var width: CGFloat
    var isSelected: Bool
    var isActive = true
}

extension ImportCellInputs {
    init(frame: ImportFrame, review: ImportReview, width: CGFloat, isActive: Bool = true) {
        self.init(frame: frame, badge: review.badge(frame.id), isKept: review.isKept(frame.id),
                  isChanged: review.isChanged(frame.id), leftPlace: review.leftPlace, width: width,
                  isSelected: review.isSelected(frame.id), isActive: isActive)
    }
}

struct ImportCell: View {
    let inputs: ImportCellInputs
    let loader: ThumbnailLoader
    /// A click, by the keys held with it (`ImportReview.click`).
    let toggle: () -> Void
    /// The frame sent the other way, as a plain click sends it: VoiceOver's press, which holds no keys.
    var press: () -> Void = {}
    /// The frame joins the frames selected, or leaves them.
    var select: () -> Void = {}
    @Environment(\.displayScale) private var displayScale
    @State private var isHovered = false
    @State private var thumbnail: (url: URL, image: CGImage?)?

    var body: some View {
        let frame = inputs.frame.frame
        let current = frame.flatMap { frame in thumbnail?.url == frame.url ? thumbnail : nil }
        let failed = frame == nil || (current != nil && current?.image == nil)
        VStack(alignment: .leading, spacing: SheetGeometry.labelGap) {
            ZStack(alignment: .bottomLeading) {
                well(frame: frame, image: current?.image, failed: failed)
                    .opacity(inputs.isKept ? 1 : 0.32)
                if let badge = inputs.badge, let image = ImportBadgeImage.image(badge, limit: inputs.width - 12, scale: displayScale) {
                    Image(decorative: image, scale: displayScale)
                        .padding(6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: inputs.width, height: inputs.width * 2 / 3)
            .wellOutline(isSelected: inputs.isSelected, isHovered: isHovered && !inputs.isSelected)
            fileName
        }
        .frame(width: inputs.width)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onChange(of: inputs.frame.id) { isHovered = false }
        .onTapGesture(perform: toggle)
        .help(Self.helpText(inputs))
        .accessibilityElement()
        .accessibilityLabel(Self.accessibilityText(inputs))
        .accessibilityAddTraits(inputs.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Changes where it goes. Space.")
        .accessibilityAction(.default, press)
        // VoiceOver's way to several frames: this one joins those selected, or leaves them, as a Command-click does.
        .accessibilityAction(named: inputs.isSelected ? "Remove from Selection" : "Add to Selection", select)
        .task(id: inputs.isActive ? frame.map { PreviewRequest(frame: $0.url, pixelSize: pixelSize) } : nil) {
            guard inputs.isActive, let frame else { return }
            if thumbnail?.url != frame.url { thumbnail = nil }
            let image: CGImage?
            if let cached = loader.cached(frame, maxPixelSize: pixelSize) {
                image = cached
            } else {
                image = await loader.thumbnail(for: frame, maxPixelSize: pixelSize)
                guard !Task.isCancelled else { return }
            }
            thumbnail = (frame.url, image)
            #if DEBUG
            if image != nil { ImportProbe.loaded.insert(inputs.frame.id) }
            #endif
        }
    }

    private var pixelSize: Int { Metrics.pixelSize(forWidth: inputs.width, scale: displayScale) }

    private func well(frame: Frame?, image: CGImage?, failed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius, style: .continuous)
        return ZStack {
            shape.fill(Graphite.well)
            shape.fill(failed ? Graphite.well : Graphite.placeholder)
                .aspectRatio(frame?.info.isPortrait == true ? 2.0 / 3.0 : 3.0 / 2.0, contentMode: .fit)
                .overlay { if failed { NoPreview(width: inputs.width) } }
                .opacity(image == nil ? 1 : 0)
            Image(decorative: image ?? Self.noPicture, scale: displayScale)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(shape)
                .opacity(image == nil ? 0 : 1)
        }
        .frame(width: inputs.width, height: inputs.width * 2 / 3)
    }

    private static let noPicture: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context!.makeImage()!
    }()

    private var fileName: some View {
        let color = inputs.isSelected || isHovered ? Graphite.text : inputs.isKept ? Graphite.secondaryText : Graphite.tertiaryText
        let image = SheetFileName.image(inputs.frame.name, color: color, limit: inputs.width - 4 - (inputs.isChanged ? 10 : 0),
                                        scale: displayScale)
        return ZStack(alignment: .leading) {
            if let image { Image(decorative: image, scale: displayScale) }
            if inputs.isChanged {
                Circle()
                    .fill(Graphite.secondaryText)
                    .frame(width: 4, height: 4)
                    .help("You changed where this frame goes")
                    .accessibilityHidden(true)
                    .offset(x: CGFloat(image?.width ?? 0) / displayScale + 6)
            }
        }
        .frame(width: inputs.width - 4, height: SheetGeometry.labelHeight, alignment: .leading)
        .padding(.horizontal, 2)
    }

    static func helpText(_ inputs: ImportCellInputs) -> String {
        inputs.isKept ? "To import. Click to leave it \(inputs.leftPlace)."
            : "\(inputs.badge?.text ?? "Left \(inputs.leftPlace)"). Click to import it."
    }

    static func accessibilityText(_ inputs: ImportCellInputs) -> String {
        var parts = [inputs.frame.name, inputs.isKept ? "to import" : "left \(inputs.leftPlace)"]
        switch inputs.badge {
        case .changedToImport, .changedToLeft: parts.append("changed")
        case .reason(let reason): parts.append(ImportBadge.reason(reason).text)
        case nil: break
        }
        return parts.joined(separator: ", ")
    }
}

/// A badge at the foot of a review cell's picture, a symbol and what it says on a translucent pill in the theme's
/// colours, over two lines in a narrow well, drawn once for each badge, colour and width and kept. Drawn rather than
/// a `Text` on glass: live glass under every badge of a 644-frame card resamples the pictures it passes in each display
/// frame, and a `Text` lays out on the main thread whenever a recycled cell takes another frame (docs/M2-shell.md,
/// section 20).
@MainActor enum ImportBadgeImage {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    private static let padding = CGSize(width: 8, height: 5)
    private static let symbolWidth: CGFloat = 12
    private static let gap: CGFloat = 5

    static func image(_ badge: ImportBadge, limit: CGFloat, scale: CGFloat) -> CGImage? {
        guard limit > 0, scale > 0,
              let ink = NSColor(Graphite.text).usingColorSpace(.sRGB),
              let ground = NSColor(Graphite.chrome.opacity(0.78)).usingColorSpace(.sRGB),
              let edge = NSColor(Graphite.ink(0.16)).usingColorSpace(.sRGB) else { return nil }
        let key = "\(badge.symbol)|\(badge.text)|\(limit)|\(scale)|\(ink)|\(ground)|\(edge)" as NSString
        if let kept = cache.object(forKey: key) { return kept.image }

        let font = NSFont.systemFont(ofSize: 11)
        let text = NSAttributedString(string: badge.text, attributes: [.font: font, .foregroundColor: ink])
        let textLimit = max(1, limit - 2 * padding.width - symbolWidth - gap)
        let measured = text.boundingRect(with: CGSize(width: textLimit, height: 100), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textSize = CGSize(width: min(textLimit, measured.width.rounded(.up)), height: measured.height.rounded(.up))
        let size = CGSize(width: 2 * padding.width + symbolWidth + gap + textSize.width, height: 2 * padding.height + textSize.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let pill = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
        ground.setFill()
        pill.fill()
        edge.setStroke()
        pill.lineWidth = 0.5
        pill.stroke()
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        if let symbol = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium).applying(.init(paletteColors: [ink]))) {
            let middle = size.height - padding.height - lineHeight / 2
            symbol.draw(in: NSRect(x: padding.width + (symbolWidth - symbol.size.width) / 2, y: middle - symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height))
        }
        text.draw(with: NSRect(x: padding.width + symbolWidth + gap, y: padding.height, width: textSize.width, height: textSize.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        cache.setObject(Entry(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

private struct HostedImportCell: View {
    let inputs: ImportCellInputs?
    let loader: ThumbnailLoader
    let toggle: () -> Void
    let press: () -> Void
    let select: () -> Void

    var body: some View {
        if let inputs { ImportCell(inputs: inputs, loader: loader, toggle: toggle, press: press, select: select) }
    }
}

/// A review cell's hosting view, which gives a right-click and a Control-click to the review's menu
/// (`SheetCollectionView`, `ImportMenu`): SwiftUI would take either as a click that sends the frame the other way.
/// It keeps what the press it last took asks of the tap that follows, as the sheet's cells do (`SheetCellHost`).
private final class ImportCellHost: NSHostingView<HostedImportCell> {
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
        if event.asksForContextMenu {
            click = nil
            sheet?.openMenu(with: event)
        } else {
            click = SelectionClick(event.modifierFlags)
            super.mouseDown(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        event?.asksForContextMenu == true || super.acceptsFirstMouse(for: event)
    }
}

final class ImportItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ImportItem")
    private var host: ImportCellHost?
    private(set) var inputs: ImportCellInputs?
    /// What the last press on the cell asks of the tap that follows it (`ImportCellHost.click`).
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

    func show(_ inputs: ImportCellInputs, loader: ThumbnailLoader, toggle: @escaping () -> Void, press: @escaping () -> Void,
              select: @escaping () -> Void) {
        guard inputs != self.inputs else { return }
        self.inputs = inputs
        let root = HostedImportCell(inputs: inputs, loader: loader, toggle: toggle, press: press, select: select)
        if let host {
            host.rootView = root
        } else {
            let made = ImportCellHost(rootView: root)
            made.sizingOptions = []
            made.safeAreaRegions = []
            cell.host(made)
            host = made
        }
    }
}

#if DEBUG
@MainActor enum ImportProbe {
    static var visibleFrames: () -> [ImportFrame.ID] = { [] }
    static var loaded: Set<ImportFrame.ID> = []
}
#endif
