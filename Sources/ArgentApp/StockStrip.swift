import ArgentCore
import ArgentRoll
import SwiftUI

/// The dock's sample shelf; the parent owns the shell, settings and dismissal.
struct StockShelf: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var visible = CGRect.zero

    var body: some View {
        GeometryReader { room in
            let layout = StockShelfLayout(width: room.size.width, count: model.stockNames.count)
            HStack(spacing: StockShelfLayout.pagingGap) {
                if layout.showsPaging { pageButton(forward: false, layout: layout) }
                ScrollView(.horizontal) {
                    HStack(spacing: StockShelfLayout.gap) {
                        ForEach(model.stockNames.indices, id: \.self) { index in
                            StockSample(frame: model.paletteFrame, index: index, width: layout.sampleWidth)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { old, new in
                    visible = new
                    if old.width != new.width {
                        revealSelection(layout: layout, from: new.minX)
                    }
                }
                .onChange(of: model.shownStockIndex, initial: true) { old, new in
                    revealSelection(layout: layout, animated: old != new)
                }
                .onChange(of: layout) {
                    // A resize can change the samples' widths even when the scroll offset is unchanged.
                    revealSelection(layout: layout)
                }
                if layout.showsPaging { pageButton(forward: true, layout: layout) }
            }
        }
        .frame(height: StockShelfLayout.sampleHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Film stocks")
    }

    private func revealSelection(layout: StockShelfLayout, from offset: CGFloat? = nil, animated: Bool = false) {
        let target = layout.offset(revealing: model.shownStockIndex, from: offset ?? visible.minX)
        withAnimation(animated && !reduceMotion ? Graphite.Motion.glide : nil) {
            position.scrollTo(x: target)
        }
    }

    private func pageButton(forward: Bool, layout: StockShelfLayout) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Graphite.Motion.glide) {
                position.scrollTo(x: layout.pageOffset(forward: forward, from: visible.minX))
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Graphite.secondaryText)
                .frame(width: StockShelfLayout.pagingWidth, height: StockShelfLayout.sampleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(forward ? visible.minX >= layout.maximumOffset - 1 : visible.minX <= 1)
        .accessibilityLabel(forward ? "Show next stocks" : "Show previous stocks")
        .help(forward ? "Show next stocks" : "Show previous stocks")
    }
}

/// Horizontal layout shared by sizing, paging and selection reveal, including room for the arrows.
struct StockShelfLayout: Equatable {
    static let gap: CGFloat = 6
    static let pagingGap: CGFloat = 4
    static let pagingWidth: CGFloat = 20
    static let minimumSampleWidth: CGFloat = 108
    static let pictureHeight: CGFloat = 48
    static let sampleHeight: CGFloat = pictureHeight + 4 + 15 + 8

    let count: Int
    let sampleWidth: CGFloat
    let viewportWidth: CGFloat
    let showsPaging: Bool

    init(width: CGFloat, count: Int) {
        self.count = max(0, count)
        let gaps = CGFloat(max(0, count - 1)) * Self.gap
        showsPaging = count > 0 && CGFloat(count) * Self.minimumSampleWidth + gaps > max(0, width)
        viewportWidth = max(0, width - (showsPaging ? 2 * (Self.pagingWidth + Self.pagingGap) : 0))
        sampleWidth = max(Self.minimumSampleWidth, floor((viewportWidth - gaps) / CGFloat(max(1, count))))
    }

    var contentWidth: CGFloat { CGFloat(count) * sampleWidth + CGFloat(max(0, count - 1)) * Self.gap }
    var maximumOffset: CGFloat { max(0, contentWidth - viewportWidth) }

    func offset(revealing index: Int, from offset: CGFloat) -> CGFloat {
        guard (0..<count).contains(index) else { return clamped(offset) }
        let leading = CGFloat(index) * (sampleWidth + Self.gap)
        let current = clamped(offset)
        if leading < current || sampleWidth > viewportWidth { return clamped(leading) }
        if leading + sampleWidth > current + viewportWidth { return clamped(leading + sampleWidth - viewportWidth) }
        return current
    }

    func pageOffset(forward: Bool, from offset: CGFloat) -> CGFloat {
        let pitch = sampleWidth + Self.gap
        let page = max(1, floor(viewportWidth / pitch)) * pitch
        return clamped(offset + (forward ? page : -page))
    }

    private func clamped(_ offset: CGFloat) -> CGFloat { min(max(0, offset), maximumOffset) }
}

private struct StockSample: View {
    let frame: Frame?
    let index: Int
    let width: CGFloat
    @Environment(RollModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let current = model.shownStockIndex == index
        let scope = model.shownFrame == nil ? "the whole roll" : "this frame"
        // In the frame view, the roll's own stock is marked, so a frame given another can find its way back.
        let isRollsOwn = model.shownFrame != nil && model.stockIndex == index
        let name = model.stockNames[index]
        let key = index < 9 ? String(index + 1) : nil
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button {
            model.selectStock(index)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                picture
                    .overlay(alignment: .topTrailing) {
                        if let key { StockKeycap(text: key).padding(3) }
                    }
                HStack(spacing: 4) {
                    Text(verbatim: name)
                        .font(.system(size: 12, weight: current ? .semibold : .medium))
                        .foregroundStyle(current ? Graphite.dockAccent : Graphite.text)
                        .lineLimit(1)
                    if isRollsOwn {
                        Spacer(minLength: 0)
                        Text("Roll")
                            .font(.system(size: 9, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(Graphite.secondaryText)
                            .fixedSize()
                    }
                }
                .frame(height: 15, alignment: .leading)
                .padding(.horizontal, 1)
            }
            .padding(4)
            .frame(width: width, height: StockShelfLayout.sampleHeight, alignment: .leading)
            .background(shape.fill(current ? Graphite.dockAccent.opacity(0.08) : Graphite.ink(hovered ? 0.07 : 0)))
            .overlay {
                shape.strokeBorder(current ? Graphite.dockAccent.opacity(contrast == .increased ? 1 : 0.7)
                                   : contrast == .increased ? Graphite.strongBorder : Color.clear,
                                   lineWidth: contrast == .increased ? 2 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(StockSampleStyle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: hovered)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: current)
        .help(model.stockAfterLines[index] ?? name)
        .accessibilityLabel(name)
        .accessibilityValue([current ? "In use for \(scope)" : nil, isRollsOwn ? "the roll's stock" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint([
            isRollsOwn && !current ? "Makes this frame follow the roll's stock again." : "Develops \(scope) through \(name).",
            key.map { "Key \($0)." },
            current ? StockCharacter.sentence(for: model.shownStock) : nil,
            model.stockAfterLines[index]
        ].compactMap { $0 }.joined(separator: " "))
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var picture: some View {
        let pictureWidth = width - 8
        return Group {
            if let frame {
                // FrameCell fits portraits inside a 3:2 bed. Enlarge that bed to fill the swatch before cropping.
                let renderWidth = frame.info.isPortrait ? pictureWidth * 9 / 4 : pictureWidth
                FrameCell(frame: frame, width: renderWidth, stock: index, priority: .high, followsFrameView: true)
            } else {
                Graphite.well
            }
        }
        .frame(width: pictureWidth, height: StockShelfLayout.pictureHeight)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct StockSampleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressSpring(configuration.isPressed, depth: 0.98)
    }
}

/// Keycaps remain legible over both light and dark photographs.
private struct StockKeycap: View {
    let text: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        Text(verbatim: text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(shape.fill(.black.opacity(contrast == .increased ? 0.9 : 0.7)))
            .overlay { shape.strokeBorder(.white.opacity(contrast == .increased ? 0.85 : 0.3), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

/// What each stock is like, in the words of the spec's film library: the character its model
/// is built to reproduce, without the film's name, which only the stock's descriptive line
/// gives (spec, Naming policy). Keyed by stock id; a stock without a line shows its name alone.
enum StockCharacter {
    static func line(for stock: Stock?) -> String? {
        if let custom = stock?.characterLine, !custom.isEmpty { return custom }
        return line(for: stock?.id)
    }

    static func line(for id: String?) -> String? {
        guard let id else { return nil }
        return lines[id]
    }

    /// The current stock's description in the command bar, starting with a capital: "Warm
    /// neutral skin, soft highlight roll-off".
    static func sentence(for stock: Stock?) -> String? {
        guard let line = line(for: stock), let first = line.first else { return nil }
        return first.uppercased() + line.dropFirst()
    }

    static func sentence(for id: String?) -> String? {
        guard let line = line(for: id), let first = line.first else { return nil }
        return first.uppercased() + line.dropFirst()
    }

    private static let lines: [String: String] = [
        "argent-neutral": "camera colour, moderate contrast, soft highlights, open shadows",
        "kodak-portra-400": "warm neutral skin, soft highlight roll-off",
        "kodak-portra-160": "lowest contrast, pastel skin, very fine grain",
        "kodak-portra-800": "more contrast, visible grain, warmer shadows",
        "kodak-gold-200": "warm yellows and reds, cyan skies",
        "kodak-ultramax-400": "warm and punchy, coarser grain",
        "kodak-ektar-100": "highest saturation, cool clean shadows",
        "fujifilm-superia-400": "daylight-balanced consumer film, ISO 400",
        "fujifilm-pro-400h": "professional daylight film with gentle gradation",
        "fujifilm-c200": "daylight-balanced consumer film, ISO 200",
        "kodak-portra-160-natural": "Portra 160 with gentler colour, for natural skin",
        "kodak-colorplus-200": "a softer approximation based on Gold 200",
        "kodak-vision3-500t": "3200 K cinema negative, restrained halation",
        "kodak-vision3-500t-cinema": "same negative as Tungsten 500, with a projected cinema print",
        "cinestill-800t": "3200 K C-41 approximation with broad red halation",
    ]
}
