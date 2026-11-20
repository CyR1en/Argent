import ArgentCore
import ArgentRoll
import SwiftUI

/// What a cell's pictures depend on, so it reloads when any of it changes. The frame is part
/// of it because the stock panel shows whichever frame is selected in the same cells.
struct PreviewRequest: Equatable {
    var frame: URL
    var pixelSize: Int
    var source: SourceStamp? = nil
    /// The frame view's decode at this size has been refined (`FilmPreviews.refineFrame`).
    var refined = false
    /// A neutral raw's colour space, which follows the film's; nil for an embedded JPEG, which keeps its own.
    var space: OutputSpace? = nil
    var lens: LensSettings = .default
}

struct FrameSourceRequest: Hashable {
    var frame: URL
    var source: SourceStamp?
}

struct FilmRequest: Equatable {
    var frame: URL
    var stock: Int
    var settings: DevelopSettings
    /// The colour space a develop is to write, which the film is shown in.
    var space: OutputSpace
    var pixelSize: Int
    /// The frame's auto-development measurement has arrived; a film waits for it.
    var analyzed = true
    var source: SourceStamp? = nil
    /// The frame view's decode at this size has been refined (`FilmPreviews.refineFrame`).
    var refined = false
}

/// One frame in a 3:2 well: its embedded preview at once, then its film render crossfading
/// over it as it completes, 400 ms the first time and 200 ms when the stock or the settings
/// change. Portrait frames sit upright inside the well, on its bed, so every frame keeps its
/// whole picture and the sheet keeps one rhythm. A frame whose file gives no preview says so
/// quietly in its well rather than waiting on a placeholder that never fills. The selection and
/// hover outlines are the caller's (`wellOutline`). A film already made comes up with no crossfade.
struct FrameCell: View {
    let frame: Frame
    let width: CGFloat
    /// The stock to render through, or `nil` for the embedded preview alone.
    let stock: Int?
    var priority: Operation.QueuePriority = .normal
    /// The stock panel's tiles show the frame the frame view shows, while it is open, and
    /// take their pictures from its decode.
    var followsFrameView = false
    /// The well's bed; the contact sheet leaves it out on the gray surround, which is then the
    /// bed itself.
    var showsBed = true
    /// Whether it is on screen, for a cell that waits to be used again (`SheetGrid`): waiting, it asks
    /// for no pictures and lets go of those it was waiting for.
    var isActive = true

    @Environment(RollModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preview: CGImage?
    @State private var film: CGImage?
    /// Changes with every new film image, so the old one fades out under the new one.
    @State private var filmGeneration = 0
    @State private var shownSource: FrameSourceRequest?
    /// The preview was asked for and the file gave none: missing, unreadable or without an
    /// embedded JPEG. Only what the load returned; a film arriving still covers it.
    @State private var previewFailed = false

    private var pixelSize: Int { Metrics.pixelSize(forWidth: width, scale: displayScale) }

    /// Whether the pictures held are this frame's. A cell given another frame shows none of the last
    /// one's in the moment before its tasks run.
    private var picturesAreCurrent: Bool {
        shownSource == FrameSourceRequest(frame: frame.url, source: model.sourceStamp(for: frame))
    }

    var body: some View {
        let isCurrent = picturesAreCurrent
        let showsPreview = isCurrent && preview != nil, showsFilm = isCurrent && film != nil, showsFailure = isCurrent && previewFailed
        // One structure whatever is up, the pictures hidden rather than left out: a recycled cell takes
        // its next frame's pictures without SwiftUI building or tearing down any of its views, which is
        // what makes it cheap (`SheetGrid`).
        ZStack {
            RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius, style: .continuous)
                .fill(showsBed ? Graphite.well : Color.clear)
            RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius, style: .continuous)
                .fill(showsFailure ? Graphite.well : Graphite.placeholder)
                .aspectRatio(frame.info.isPortrait ? 2.0 / 3.0 : 3.0 / 2.0, contentMode: .fit)
                .overlay {
                    if showsFailure, !showsFilm { NoPreview(width: width) }
                }
                .opacity(showsPreview ? 0 : 1)
            picture(preview ?? Self.noPicture)
                .opacity(showsPreview ? 1 : 0)
            picture(film ?? Self.noPicture)
                .opacity(showsFilm ? 1 : 0)
                .id(filmGeneration)
                .transition(.opacity)
        }
        .frame(width: width, height: width * 2 / 3)
        .contentShape(Rectangle())
        .task(id: isActive ? PreviewRequest(frame: frame.url, pixelSize: pixelSize, source: model.sourceStamp(for: frame)) : nil) {
            guard isActive else { return }
            resetPicturesIfNeeded()
            let source = model.sourceStamp(for: frame)
            guard SourceStamp.of(frame.url) == source else {
                // A file gone from the folder has nothing to show until the roll is read again.
                if source != nil, SourceStamp.of(frame.url) == nil { previewFailed = true }
                return
            }
            model.cellPixelSizes.insert(pixelSize)
            if let cached = model.thumbnails.cached(frame, maxPixelSize: pixelSize) {
                preview = cached
                previewFailed = false
                #if DEBUG
                noteShown(preview: true)
                #endif
                return
            }
            let loaded = await model.thumbnails.thumbnail(for: frame, maxPixelSize: pixelSize)
            guard !Task.isCancelled, SourceStamp.of(frame.url) == source else { return }
            withAnimation(reduceMotion ? nil : Motion.stateChange) {
                preview = loaded
                previewFailed = loaded == nil
            }
            #if DEBUG
            if loaded != nil { noteShown(preview: true) }
            #endif
        }
        .task(id: isActive ? stock.map { FilmRequest(frame: frame.url, stock: $0, settings: model.settings(for: frame, stock: $0),
                                                     space: model.output.space, pixelSize: pixelSize, analyzed: model.isMeasured(frame),
                                                     source: model.sourceStamp(for: frame)) } : nil) {
            guard isActive else { return }
            resetPicturesIfNeeded()
            guard let stock, let films = model.films else {
                film = nil
                return
            }
            // A frame's film waits for its auto-development measurement, from the sheet's decode
            // whichever cell asks, or for its failure, which prints at the fallback aim; the
            // arrival changes this task's id and runs it again. Until the roll settles the film is
            // at the frame's own aim, and moves once, to the settled one (RollModel+Auto).
            if !model.isMeasured(frame) {
                await model.analyze(frame, priority: priority)
                return
            }
            let request = FilmRequest(frame: frame.url, stock: stock, settings: model.settings(for: frame, stock: stock),
                                      space: model.output.space, pixelSize: pixelSize, source: model.sourceStamp(for: frame))
            guard SourceStamp.of(frame.url) == request.source else { return }
            let image = films.cachedFilm(frame, stock: request.stock, settings: request.settings, space: request.space,
                                         maxPixelSize: request.pixelSize)
            let rendered: CGImage?
            if let image {
                rendered = image
            } else {
                let frameViewSide = followsFrameView
                    ? model.frameLayout.map { FilmPreviews.frameDecodeSide(forPixels: $0.pixels(frame)) } : nil
                rendered = await films.film(frame, stock: request.stock, settings: request.settings, space: request.space,
                                            maxPixelSize: request.pixelSize, priority: priority, frameViewSide: frameViewSide)
            }
            guard !Task.isCancelled, SourceStamp.of(frame.url) == request.source, let rendered else { return }
            // A film already made, on a cell that has just come back into the sheet, does not arrive
            // again: it is simply there, and cells scrolling in do not each run a crossfade. The first
            // film fades in over the preview; a later one takes a new identity, so the last fades out
            // under it.
            let isReturning = image != nil && film == nil
            let replaces = film != nil
            // A film for a new thumbnail size waits while the sheet's cells glide to that size: put up at once it would
            // be at its full size in a cell still on its way there. The film it replaces grows with the cell meanwhile.
            let gliding = SheetGridController.sizeGlide - (CACurrentMediaTime() - model.sizeStepChanged)
            if replaces, !reduceMotion, gliding > 0 {
                do { try await Task.sleep(for: .seconds(gliding)) } catch { return }
            }
            let animation = reduceMotion || isReturning ? nil : (replaces ? Motion.stateChange : Motion.filmArrives)
            withAnimation(animation) {
                film = rendered
                if replaces { filmGeneration += 1 }
            }
            #if DEBUG
            noteShown(preview: false, stock: request.stock, settings: request.settings)
            #endif
        }
    }

    #if DEBUG
    /// Records a picture put up for `SheetProbe`; the stock panel's tiles, which follow the frame view,
    /// are not the sheet's.
    private func noteShown(preview: Bool, stock: Int = 0, settings: DevelopSettings = DevelopSettings()) {
        guard !followsFrameView else { return }
        if preview { SheetProbe.previews[frame.url] = (pixelSize, CACurrentMediaTime()) }
        else { SheetProbe.films[frame.url] = (stock, settings, CACurrentMediaTime()) }
    }
    #endif

    private func resetPicturesIfNeeded() {
        let source = FrameSourceRequest(frame: frame.url, source: model.sourceStamp(for: frame))
        guard source != shownSource else { return }
        shownSource = source
        preview = nil
        film = nil
        previewFailed = false
    }

    /// What a hidden picture holds until it has one of its own.
    private static let noPicture: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context!.makeImage()!
    }()

    private func picture(_ image: CGImage) -> some View {
        Image(decorative: image, scale: displayScale)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius, style: .continuous))
    }
}

/// A well whose file gave no preview: a thin symbol, and where the well has room, "No preview",
/// both quiet, so a sheet of good frames is not shouted over by one bad file.
struct NoPreview: View {
    let width: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: width < 140 ? 15 : 19, weight: .light))
            if width >= 140 {
                Text("No preview")
                    .font(Graphite.Typeface.caption)
            }
        }
        .foregroundStyle(Graphite.tertiaryText)
        .help("Argent could not read a preview from this file. It may be missing, unreadable or still being copied.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No preview")
    }
}

/// The ring round a well, a few points outside it with a sliver of the surface showing between:
/// the selection a 2 pt ring (`Graphite.selection`), a hovered well a quiet 1 pt line,
/// both stronger with Increase Contrast. `outset` is from the well's edge to the ring's outer edge.
struct WellOutline: ViewModifier {
    var isSelected: Bool
    var isHovered = false
    var outset: CGFloat = 3
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if isSelected || isHovered {
                RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius + outset, style: .continuous)
                    .strokeBorder(isSelected ? Graphite.selection : Graphite.ink(contrast == .increased ? 0.7 : 0.3),
                                  lineWidth: isSelected ? Graphite.Metric.selectionWidth : 1)
                    .padding(-outset)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func wellOutline(isSelected: Bool, isHovered: Bool = false, outset: CGFloat = 3) -> some View {
        modifier(WellOutline(isSelected: isSelected, isHovered: isHovered, outset: outset))
    }
}
