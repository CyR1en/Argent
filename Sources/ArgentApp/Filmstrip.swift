import ArgentRoll
import SwiftUI

/// The command bar's frame center: a lazy strip and the open frame's flag.
struct FilmstripDock: View {
    @Environment(RollModel.self) private var model

    @State private var stripRoom: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            // Place the strip once its host has laid out, so its first scroll reaches the selected frame.
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripRoom = $0 }
                .overlay(alignment: .leading) { Filmstrip(room: stripRoom) }
            if let frame = model.shownFrame {
                FlagToggle(frame: frame)
                    .fixedSize()
            }
        }
        .frame(height: 40)
    }
}

/// How the filmstrip's thumbnails sit in its room: whole thumbnails only, as many as fit, and which
/// of them shows first so the open frame is in view. Moving through the roll by keys scrolls the
/// strip only when the open frame would leave it, a thumbnail before reaching its end, so the strip
/// keeps still under most presses and the next frame either way is always in view.
struct FilmstripWindow: Equatable {
    /// The frames the strip holds.
    var count: Int
    /// The whole thumbnails its room shows.
    var slots: Int

    /// A 3:2 thumbnail, 32 points tall inside the command bar's 40-point center.
    static let thumbnail: CGFloat = 48
    static let gap: CGFloat = 4
    /// Room at each end for the open frame's ring.
    static let inset: CGFloat = 3
    static var pitch: CGFloat { thumbnail + gap }

    /// How many whole thumbnails fit across `width` points, one at the least.
    static func slots(fitting width: CGFloat) -> Int {
        max(1, Int(((width - 2 * inset + gap) / pitch).rounded(.down)))
    }

    /// The strip's width: its thumbnails, never more than it holds, and the ring's room.
    var width: CGFloat {
        let shown = CGFloat(max(1, min(slots, count)))
        return shown * Self.pitch - Self.gap + 2 * Self.inset
    }

    /// Every thumbnail the strip holds, side by side, with the ring's room.
    var contentWidth: CGFloat { CGFloat(max(1, count)) * Self.pitch - Self.gap + 2 * Self.inset }

    /// The strip's width in `room`: all of it while the strip holds more than its whole thumbnails,
    /// the next one fading at the edge rather than leaving a gap before the flag; its thumbnails
    /// alone when they all fit.
    func shownWidth(in room: CGFloat) -> CGFloat { min(max(room, 0), contentWidth) }

    /// The first thumbnail to show so the one at `selected` is in view: centred when the strip
    /// is first placed (`first` is `nil`), else `first` itself while `selected` stays clear of
    /// the ends, or moved just enough to keep one more thumbnail beyond it when the strip shows
    /// five or more.
    func first(showing selected: Int, from first: Int?) -> Int {
        let last = max(0, count - slots)
        guard count > 0 else { return 0 }
        let selected = min(max(selected, 0), count - 1)
        guard let first else { return min(max(selected - (slots - 1) / 2, 0), last) }
        let margin = slots >= 5 ? 1 : 0
        var target = min(max(first, 0), last)
        if selected < target + margin { target = selected - margin }
        if selected > target + slots - 1 - margin { target = selected - slots + 1 + margin }
        return min(max(target, 0), last)
    }

    /// Keep the selected thumbnail and its ring wholly visible, including after a fractional
    /// trackpad scroll or a resize that leaves the number of whole slots unchanged.
    func scrollOffset(showing selected: Int, from offset: CGFloat?, in room: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let selected = min(max(selected, 0), count - 1)
        let shown = shownWidth(in: room)
        let limit = max(0, contentWidth - shown)
        let current = offset.map { Int(($0 / Self.pitch).rounded()) }
        let first = first(showing: selected, from: current)
        var target = CGFloat(first) * Self.pitch
        if let offset, first == current {
            let leading = CGFloat(selected) * Self.pitch
            let trailing = leading + Self.thumbnail + 2 * Self.inset
            target = offset
            if leading < offset { target = leading }
            else if trailing > offset + shown { target = trailing - shown }
        }
        return min(max(target, 0), limit)
    }

    /// Where `selected` sits among `frames` for scrolling: its index, or for an open frame the
    /// filter leaves out, the index of the first shown after it in capture order, so the strip
    /// rests where the frame would be.
    static func index(of selected: Frame.ID?, in frames: [Frame]) -> Int? {
        guard let selected, !frames.isEmpty else { return nil }
        if let index = frames.firstIndex(where: { $0.id == selected }) { return index }
        return frames.firstIndex(where: { $0.id > selected }) ?? frames.count - 1
    }
}

/// The strip of thumbnails, scrolled to keep the open frame in view (`FilmstripWindow`). Its cells
/// are lazy: only the thumbnails in view, and a few either side, load their pictures, at the strip's
/// own small size and low priority, so the open frame's render comes first.
private struct Filmstrip: View {
    /// The room the dock gives the strip.
    let room: CGFloat
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .leading)
    /// How far the strip is scrolled, a scroll of the trackpad's included.
    @State private var offset: CGFloat = 0
    /// Whether the strip has been placed once, centred on the open frame.
    @State private var isPlaced = false

    var body: some View {
        let frames = model.shownFrames
        let window = FilmstripWindow(count: frames.count, slots: FilmstripWindow.slots(fitting: room))
        let hasStocks = model.films != nil
        ScrollView(.horizontal) {
            LazyHStack(spacing: FilmstripWindow.gap) {
                ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                    FilmstripThumbnail(frame: frame, stock: hasStocks ? model.stockIndex(for: frame) : nil, number: index + 1, position: "\(index + 1) of \(frames.count)",
                                       isOpen: frame.id == model.selection)
                }
            }
            .padding(.horizontal, FilmstripWindow.inset)
            .frame(height: FilmstripWindow.thumbnail * 2 / 3 + 2 * FilmstripWindow.inset)
            // The open frame's ring: one, which goes along the strip to the next frame opened.
            .overlay(alignment: .topLeading) {
                if let open = frames.firstIndex(where: { $0.id == model.selection }) {
                    RoundedRectangle(cornerRadius: Metrics.cornerRadius + 2, style: .continuous)
                        .strokeBorder(Graphite.dockAccent, lineWidth: 1.5)
                        .frame(width: FilmstripWindow.thumbnail + 4, height: FilmstripWindow.thumbnail * 2 / 3 + 4)
                        .offset(x: FilmstripWindow.inset + CGFloat(open) * FilmstripWindow.pitch - 2, y: FilmstripWindow.inset - 2)
                        .animation(reduceMotion ? nil : Graphite.Motion.glide, value: open)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset = x }
        .frame(width: room > 0 ? window.shownWidth(in: room) : 0)
        .mask { edgeFade(window) }
        .opacity(frames.isEmpty ? 0 : 1)
        .onChange(of: model.selection, initial: true) { follow(frames, window) }
        .onChange(of: room) { follow(frames, window) }
        .onChange(of: frames.map(\.id)) { follow(frames, window) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filmstrip")
    }

    /// Fades the strip's ends where thumbnails continue past them, so a part thumbnail reads as more
    /// to scroll to rather than as one cut off.
    private func edgeFade(_ window: FilmstripWindow) -> some View {
        let fade: CGFloat = 8
        let shown = window.shownWidth(in: room)
        let leading = offset > 1, trailing = offset < window.contentWidth - shown - 1
        return HStack(spacing: 0) {
            LinearGradient(colors: [leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
            Color.black
            LinearGradient(colors: [.black, trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
        }
    }

    private func follow(_ frames: [Frame], _ window: FilmstripWindow) {
        guard room > 0, let selected = FilmstripWindow.index(of: model.selection, in: frames) else { return }
        let target = window.scrollOffset(showing: selected, from: isPlaced ? offset : nil, in: room)
        guard !isPlaced || abs(target - offset) > 0.5 else { return }
        let animation = isPlaced && !reduceMotion ? Graphite.Motion.spring(0.38, 0.9) : nil
        isPlaced = true
        withAnimation(animation) { position.scrollTo(x: target) }
    }
}

/// One frame on the strip: its FrameCell, with the marks the sheet gives it, the dot of a frame with its own settings and
/// the flag, which lands on it as it is flagged. A click opens it; the open frame's ring is the strip's (`Filmstrip`).
///
/// A right-click or a Control-click opens its frame's menu (`FrameMenu`) and does not open the frame: the open frame
/// stays, its photograph and inspector with it, so Copy Adjustments from a neighbour and then Paste Adjustments
/// here is two right-clicks, not a trip away and back. A thin ring in the selection colour marks the thumbnail the
/// menu is for while it is open. The menu is AppKit's (`ContextMenuArea`), which says when it opens and closes,
/// and is made only then.
private struct FilmstripThumbnail: View {
    let frame: Frame
    let stock: Int?
    let number: Int
    /// "3 of 24", among the frames shown.
    let position: String
    let isOpen: Bool
    @Environment(RollModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    /// Its menu is open.
    @State private var isMenuShown = false
    @State private var menuAnchor = ContextMenuAnchor()

    /// Opens this frame as the arrows would reach it, so the frame ahead in that direction is the
    /// one decoded ahead (`RollModel.travel`).
    private func open() {
        let shown = model.shownFrames
        if let from = shown.firstIndex(where: { $0.id == model.selection }),
           let to = shown.firstIndex(where: { $0.id == frame.id }) {
            model.moveSelection(by: to - from)
        } else {
            model.selection = frame.id
        }
    }

    /// The thin ring of the thumbnail a menu is open for, in the selection colour; the pointer's in gray.
    private var ringColor: Color {
        if isMenuShown { return Graphite.dockAccent }
        return contrast == .increased ? Graphite.strongBorder : Graphite.secondaryText.opacity(0.6)
    }

    private var picture: some View {
        FrameCell(frame: frame, width: FilmstripWindow.thumbnail, stock: stock, priority: .low)
            .opacity(isOpen || isHovered || isMenuShown ? 1 : 0.72)
            .overlay(alignment: .bottomLeading) {
                Text(verbatim: String(format: "%02d", number))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 2))
                    .padding(2)
                    .accessibilityHidden(true)
            }
    }

    var body: some View {
        let isFlagged = model.isFlagged(frame), hasOwn = model.hasFrameEdits(frame)
        let ring = RoundedRectangle(cornerRadius: Metrics.cornerRadius + 2, style: .continuous)
        Button { open() } label: {
            picture
                .overlay(alignment: .bottomTrailing) {
                    // A frame with its own Rated at, Lab balance or Light and Curve: the sheet's dot.
                    if hasOwn {
                        Circle().fill(Graphite.dockAccent)
                            .frame(width: 4, height: 4)
                            .overlay { Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 1).padding(-1) }
                            .padding(3)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // The sheet's flag badge, small, on the picture: a portrait frame's sits in from
                    // the well's bed, as on the sheet.
                    if isFlagged {
                        let inset = frame.info.isPortrait
                            ? ((FilmstripWindow.thumbnail - FilmstripWindow.thumbnail * 4 / 9) / 2).rounded() : 0
                        FlagBadge(side: 9)
                            .padding(.leading, 3 + inset)
                            .padding(.top, 3)
                            .transition(.lands)
                    }
                }
                .overlay {
                    // Not on the open frame, which the strip's own ring is round.
                    ring.strokeBorder(ringColor, lineWidth: 1)
                        .padding(-2)
                        .opacity(!isOpen && (isHovered || isMenuShown) ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Graphite.Motion.land, value: isFlagged)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
        .overlay {
            ContextMenuArea(entries: { FrameMenu.entries(for: frame, on: .filmstrip, model: model) },
                            isOpen: { isMenuShown = $0 }, anchor: menuAnchor)
        }
        .onHover { isHovered = $0 }
        .help(frame.name)
        .accessibilityLabel("\(frame.name), \(position)"
                            + (model.hasManualAdjustments(frame) ? ", manually adjusted" : hasOwn ? ", own settings" : "")
                            + (isFlagged ? ", flagged" : ""))
        .accessibilityAddTraits(isOpen ? [.isSelected, .isImage] : .isImage)
        .accessibilityHint(isOpen ? "" : "Opens this frame.")
        // The menu's rows a frame not open has nowhere else: the menu bar's act on the open frame. Offered whether or
        // not they can act, which is asked when one is chosen and never as the strip is drawn.
        .accessibilityAction(named: isFlagged ? "Unflag" : "Flag") { model.toggleFlag(frame) }
        .accessibilityAction(named: "Copy Adjustments") { model.copyAdjustmentsByAction(from: frame) }
        .accessibilityAction(named: "Paste Adjustments") { model.pasteAdjustmentsByAction(to: frame) }
        .accessibilityAction(.showMenu) { menuAnchor.open() }
    }
}

/// The open frame's flag: flagged frames are the ones Develop takes under the Flagged filter. The flag fills in place and
/// springs as the frame is flagged.
private struct FlagToggle: View {
    let frame: Frame
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isFlagged = model.isFlagged(frame)
        Button { model.toggleFlag(frame) } label: {
            Image(systemName: isFlagged ? "flag.fill" : "flag")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(Graphite.text)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : isFlagged)
                .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isFlagged)
                // Another frame's flag is another flag, shown as it is: a step from a flagged frame to one that is not
                // flags nothing, and neither fills nor springs.
                .id(frame.id)
                .frame(width: 14)
        }
        .buttonStyle(.graphite(.quiet, size: .small))
        .disabled(!model.canFlag(frame))
        .help(isFlagged ? "Unflag this frame. F." : "Flag this frame, to develop it with the flagged frames. F.")
        .accessibilityLabel(isFlagged ? "Unflag" : "Flag")
    }
}
