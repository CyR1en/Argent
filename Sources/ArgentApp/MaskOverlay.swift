import ArgentCore
import ArgentRoll
import CoreGraphics
import QuartzCore
import SwiftUI

// MARK: - Coverage

/// What fills the overlay and the list's thumbnails: a mask's coverage, 0 to 255, at any size, top row first.
/// A protocol so the overlay does not care where it comes from, and the bake's own field can take over.
protocol MaskCoverageField: Sendable {
    /// `components`' combined coverage over a picture of `width` by `height` pixels, `width × height` bytes.
    func raster(of components: [MaskComponent], width: Int, height: Int) -> [UInt8]
    /// The same on `frame`, for a field that reads the frame's decode: a smart selection's refined edge, as the print has it.
    func raster(of components: [MaskComponent], width: Int, height: Int, on frame: Frame?, lens: MaskEditor.PictureLens?) -> [UInt8]
    /// The print's own coverage over the region a settled zoom shows (`MaskOverlaySharpRequest`), or `nil` where this field cannot read it.
    func sharpRaster(of request: MaskOverlaySharpRequest) async -> RegionCoverage?
}

extension MaskCoverageField {
    func raster(of components: [MaskComponent], width: Int, height: Int, on frame: Frame?, lens: MaskEditor.PictureLens?) -> [UInt8] {
        raster(of: components, width: width, height: height)
    }

    func sharpRaster(of request: MaskOverlaySharpRequest) async -> RegionCoverage? { nil }
}

/// The coverage engine's CPU reference (`MaskCoverage.reference(_:width:height:)`), at each pixel's centre: the
/// arithmetic the kernels run, on the numbers they receive, with the program compiled once a raster, so what the
/// red shows is what the print reads, with no copy of a constant here. The print samples a field baked over the
/// full-size picture's extent; the raster covers the drawn picture's, the same aspect to a point. A brush's strokes
/// are read as its canvas holds them (`BrushField`), a Follow edges stroke's measured shape from `shapes`; shapes the
/// bake cannot do select nothing on the overlay.
struct MaskCoverageReference: MaskCoverageField {
    /// Where a Follow edges stroke's measured shape is read: the library's store, through `MaskSeedCoverage`.
    var shapes: (any MaskSeedProvider)?
    var lens: MaskLens?

    func raster(of components: [MaskComponent], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        var readable = components.filter {
            switch $0.shape {
            case .linear, .radial: true
            case .brush(let paint): !paint.strokes.contains { $0.followEdges && $0.measured == nil }
            case .smart: false
            }
        }
        guard !readable.isEmpty else { return [UInt8](repeating: 0, count: width * height) }
        // What is first now is added, as a mask's first always is.
        readable[0].operation = .add
        guard let values = try? MaskCoverage.reference(Mask(components: readable), width: width, height: height, shapes: shapes, lens: lens) else {
            return [UInt8](repeating: 0, count: width * height)
        }
        return values.map { UInt8(min(255, max(0, $0 * 255 + 0.5))) }
    }
}

// MARK: - The rule

/// The overlay's colour, a view preference and never the theme's: it must read on the photograph, and the
/// theme's selection colour vanishes on a bright sky. The one saturated thing Graphite allows beside the
/// frame (plan section 5). Lightroom's four, cycled by Shift-O.
enum MaskOverlayColour: String, CaseIterable, Sendable {
    case red, green, white, black

    /// Where the choice is kept across launches.
    static let storageKey = "maskOverlayColour"
    /// How strongly coverage 1 tints the picture.
    static let opacity = 0.5
    /// The same with Increase Contrast or Reduce Transparency: firmer, and still translucent, since the picture under it is what it is for.
    static let firmOpacity = 0.65

    var title: String {
        switch self {
        case .red: "Red"
        case .green: "Green"
        case .white: "White"
        case .black: "Black"
        }
    }

    var color: Color {
        switch self {
        case .red: Color(red: 0.95, green: 0.11, blue: 0.1)
        case .green: Color(red: 0.13, green: 0.82, blue: 0.27)
        case .white: .white
        case .black: .black
        }
    }

    var next: MaskOverlayColour {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Whether the overlay is up, and whose: the plan's rule that it is an inspection aid and stays out of the
/// way. Pure, so `MaskOverlayTests` holds the table.
enum MaskOverlayVisibility {
    struct Inputs: Equatable {
        /// Space, Compare to Auto, the clipping view, or a frame that cannot be adjusted.
        var standsDown = false
        /// A mask's Amount or Light slider is moving. Its effect is what is being judged.
        var isAdjusting = false
        /// A gradient is being drawn, or a handle or a shape's number is moving.
        var isPlacing = false
        /// The pointer rests on a mask's or a component's row.
        var isHovering = false
        var hasSelection = false
        /// The Overlay switch, which O also sets.
        var isOn = false
        /// A gradient was just drawn or moved, and no slider has moved since.
        var justPlaced = false
    }

    enum Shown: Equatable { case nothing, selection, hovered }

    static func shown(_ inputs: Inputs) -> Shown {
        if inputs.standsDown || inputs.isAdjusting { return .nothing }
        if inputs.isPlacing { return .selection }
        if inputs.isHovering { return .hovered }
        return inputs.hasSelection && (inputs.isOn || inputs.justPlaced) ? .selection : .nothing
    }
}

// MARK: - The picture of it

/// One raster of the overlay: what it covers and its size in pixels. A slider cannot change it, since it
/// holds nothing but shapes, so a slider never rebuilds coverage.
struct MaskOverlayRequest: Hashable, Sendable {
    /// While a gradient moves: about 8 ms a component (measured), and a soft field loses nothing to the scale.
    static let draftLongSide = 512
    /// Once it has settled: about 32 ms a component (inference, from the draft's). A zoom at rest reads the visible region sharper (`MaskOverlaySharpRequest`).
    static let settledLongSide = 1024

    var components: [MaskComponent]
    var width: Int
    var height: Int
    /// The frame it is drawn over, whose decode a smart selection's refined edge is read from; told apart by its file.
    var frame: Frame?
    var lens: MaskEditor.PictureLens?

    /// `components` over a picture of `size`, `longSide` pixels on its longer side. The picture's rectangle
    /// can be a point out from 3:2 at a zoom, and rounding keeps that from asking for a new raster.
    init(components: [MaskComponent], picture size: CGSize, longSide: Int, frame: Frame? = nil, lens: MaskEditor.PictureLens? = nil) {
        self.components = components
        self.frame = frame
        self.lens = lens
        let long = max(size.width, size.height), side = CGFloat(longSide)
        width = long > 0 ? max(1, Int((size.width / long * side).rounded())) : longSide
        height = long > 0 ? max(1, Int((size.height / long * side).rounded())) : longSide
    }

    static func == (a: Self, b: Self) -> Bool {
        a.components == b.components && a.width == b.width && a.height == b.height && a.frame?.url == b.frame?.url && a.lens == b.lens
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(components)
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(frame?.url)
        hasher.combine(lens)
    }
}

/// Which film the frame view's picture is, as far as the frame view knows: a change means another decode, whose refined edge and picture
/// pixels the sharp raster must read.
struct MaskOverlayDecode: Hashable, Sendable {
    /// The longer side of the film up, once it is the film for this zoom; nil while the last zoom's is scaled in its place.
    var pixels: Int?
    var refined: Bool
}

/// The overlay over the part of the picture a settled zoom shows, for that zoom and that mask alone. The coarse raster
/// (`MaskOverlayRequest`) goes up the moment a pinch or a pan begins, and stays what is drawn until this one lands; this one is read
/// from the print itself (`RegionCoverage`), so it can never show another mask's edge than the film beside it has. Never while
/// the pointer shapes or paints, nor during a develop, whose memory gate does not count it (`MaskOverlayView`).
struct MaskOverlaySharpRequest: Hashable, Sendable {
    /// `components` as `MaskOverlayRequest` has them, first component `.add`.
    var components: [MaskComponent]
    /// The mask takes tier 2 in the print (`RollModel.overlayReadsPerPixel`).
    var perPixel: Bool
    /// The frame's masks' compiler.
    var version: String
    var frame: Frame
    /// The part of the picture to cover, as fractions from its top left (`FrameGeometry.visibleFractions`).
    var fractions: CGRect
    var decode: MaskOverlayDecode
    var lens: MaskEditor.PictureLens? = nil

    static func == (a: Self, b: Self) -> Bool {
        a.components == b.components && a.perPixel == b.perPixel && a.version == b.version && a.frame.url == b.frame.url
            && a.fractions == b.fractions && a.decode == b.decode && a.lens == b.lens
    }

    /// The same picture and shapes over the same place, on any decode of it: what the raster shows has not moved, and only the new decode's
    /// read will tell (a scaled decode becoming the refined one).
    func showsSamePlace(as other: Self) -> Bool {
        components == other.components && perPixel == other.perPixel && version == other.version && frame.url == other.frame.url && fractions == other.fractions && lens == other.lens
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(components)
        hasher.combine(perPixel)
        hasher.combine(version)
        hasher.combine(frame.url)
        hasher.combine(fractions.minX)
        hasher.combine(fractions.minY)
        hasher.combine(fractions.width)
        hasher.combine(fractions.height)
        hasher.combine(decode)
        hasher.combine(lens)
    }
}

/// The overlay's picture, made off the main actor and published at most every second refresh of the display,
/// the cadence P0-S2 measured with no refresh lost under the dock's glass. Only `MaskOverlayView` reads
/// `image`, so a moving gradient re-runs that one small body and not `FramePicture`'s. Old requests are
/// dropped, not queued: the raster in hand always goes on to the newest. Settled rasters are kept for the
/// selected mask and the rows the pointer rests on, so hovering back is immediate.
@MainActor @Observable
final class MaskOverlayStore {
    /// How many settled rasters are kept, at about 0.7 MB each.
    static let keptRasters = 4
    /// How many list thumbnails are kept, a few KB each.
    static let keptThumbnails = 48

    private(set) var image: CGImage?
    /// A brush stroke under way paints the overlay itself (`MaskBrush`): its pictures go up as it makes them, and what the rule asks
    /// for meanwhile waits for it to end.
    private(set) var isLive = false
    /// The sharp raster, and what it is of: drawn in place of `image` while it covers the place wanted; a new decode's read replaces it in place.
    private(set) var sharp: Sharp?

    /// `image` of `request`, `width` by `height` pixels, over `fractions` of the picture as the print's texels place it.
    struct Sharp: Equatable {
        let request: MaskOverlaySharpRequest
        let image: CGImage
        let fractions: CGRect
    }
    /// How long the picture must hold still before the sharp raster is read: past the zoom's own settling animation (0.2 s), so a pan
    /// or a pinch never starts one for a place it is about to leave.
    static let sharpSettle: CFTimeInterval = 0.25

    /// The display's refresh rate, which the canvas reports. A 120 Hz display until it has.
    @ObservationIgnored var refreshesPerSecond = 120
    @ObservationIgnored let field: any MaskCoverageField
    @ObservationIgnored private let clock: () -> CFTimeInterval
    @ObservationIgnored private var wanted: MaskOverlayRequest?
    @ObservationIgnored private var published: MaskOverlayRequest?
    @ObservationIgnored private var lastPublished: CFTimeInterval = -.infinity
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var kept: [(request: MaskOverlayRequest, image: CGImage)] = []
    /// A list thumbnail is of its shapes at its picture's shape: the same shapes on a landscape and a portrait frame (masks copied
    /// across, a raw replaced by one turned the other way) are two pictures.
    private struct ThumbnailKey: Hashable {
        let components: [MaskComponent]
        let portrait: Bool
    }
    /// The thumbnails made, `nil` for one that could not be, so it is not tried again at every draw.
    @ObservationIgnored private var thumbnails: [ThumbnailKey: CGImage?] = [:]
    /// Those being made off the main actor, each once.
    @ObservationIgnored private var thumbnailTasks: [ThumbnailKey: Task<Void, Never>] = [:]
    /// Counts the thumbnails that arrived from off the main actor: a row that asked before its picture was made reads this, and so
    /// draws again when one lands.
    private(set) var thumbnailsArrived = 0

    @ObservationIgnored private var wantedSharp: MaskOverlaySharpRequest?
    /// What a sharp raster could not be read for (no decode held yet): not asked again until something changes.
    @ObservationIgnored private var refusedSharp: MaskOverlaySharpRequest?
    @ObservationIgnored private var sharpDeadline: CFTimeInterval = 0
    @ObservationIgnored private var sharpTimer: Task<Void, Never>?
    @ObservationIgnored private var sharpWorker: Task<Void, Never>?
    /// Replaces `sharpSettle` for the tests.
    @ObservationIgnored var sharpSettleInterval = MaskOverlayStore.sharpSettle

    /// For the tests and the drive hook: rasters made and pictures published. In every build, so the tests compile in a
    /// release build too.
    @ObservationIgnored private(set) var rasterCount = 0
    @ObservationIgnored private(set) var publishCount = 0
    /// A sharp raster is wanted and none is up for it yet (for the drive hook).
    var isSharpWaiting: Bool { wantedSharp != nil && wantedSharp != sharp?.request && wantedSharp != refusedSharp }
    /// Sharp rasters put up, and what the last cost from its read beginning to its picture being up.
    @ObservationIgnored private(set) var sharpCount = 0
    @ObservationIgnored private(set) var sharpSeconds: CFTimeInterval = 0

    init(field: any MaskCoverageField = MaskSeedCoverage(), clock: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.field = field
        self.clock = clock
    }

    /// The least time between two published pictures, in seconds: every second refresh.
    static func publishInterval(refreshesPerSecond: Int) -> CFTimeInterval {
        2 / CFTimeInterval(max(1, refreshesPerSecond))
    }

    /// Asks for the overlay of `request`; nil when none shows.
    func want(_ request: MaskOverlayRequest?) {
        guard request != wanted else { return }
        wanted = request
        guard !isLive else { return }
        guard let request else {
            published = nil
            image = nil
            return
        }
        if let kept = kept.first(where: { $0.request == request })?.image {
            publish(kept, of: request)
            return
        }
        pump()
    }

    /// A stroke's picture of the mask's coverage, up at once: the stroke paces itself (every second refresh).
    func showLive(_ live: CGImage) {
        isLive = true
        image = live
        lastPublished = clock()
        publishCount += 1
    }

    /// The stroke ended. Its last picture is the canvas the print now reads, so it is kept as `request`'s, the mask with the stroke,
    /// at rest, and stays up; with none (a cancelled stroke) the rule's picture comes back.
    func endLive(keeping last: CGImage?, for request: MaskOverlayRequest?) {
        guard isLive else { return }
        isLive = false
        if let last, let request {
            kept.removeAll { $0.request == request }
            kept.append((request, last))
            if kept.count > Self.keptRasters { kept.removeFirst(kept.count - Self.keptRasters) }
            image = last
            published = request
        } else {
            published = nil
            image = nil
        }
        if let wanted, let found = kept.first(where: { $0.request == wanted })?.image {
            publish(found, of: wanted)
        } else {
            pump()
        }
    }

    /// Asks for the sharp raster of `request`, once the picture has held still `sharpSettleInterval`; nil lets go of what is up. A picture
    /// that moves replaces the request at each step and only moves the deadline: the last one wins, so a gesture costs nothing but
    /// comparing requests, on what is already the main thread's work for this view.
    func wantSharp(_ request: MaskOverlaySharpRequest?) {
        guard request != wantedSharp else { return }
        wantedSharp = request
        if refusedSharp != request { refusedSharp = nil }
        // What is up stays while only the decode has changed, so a scaled decode refining does not blink the red.
        if let sharp, sharp.request != request, !(request.map(sharp.request.showsSamePlace) ?? false) { self.sharp = nil }
        guard request != nil else {
            sharpTimer?.cancel()
            sharpTimer = nil
            return
        }
        sharpDeadline = clock() + sharpSettleInterval
        guard sharpTimer == nil else { return }
        sharpTimer = Task { [weak self] in
            while let self {
                let wait = self.sharpDeadline - self.clock()
                guard wait > 0 else { break }
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
            }
            self?.sharpTimer = nil
            self?.pumpSharp()
        }
    }

    /// Reads the sharp raster wanted, one at a time. Nothing is read until the deadline passes, and a request replaced meanwhile is read
    /// next, so what goes up is always the one the picture came to rest on.
    private func pumpSharp() {
        guard sharpWorker == nil, sharpTimer == nil, let request = wantedSharp, request != sharp?.request, request != refusedSharp else { return }
        let field = field, began = clock()
        sharpWorker = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> (CGImage, CGRect)? in
                guard let region = await field.sharpRaster(of: request),
                      let image = Self.image(of: region.values, width: region.width, height: region.height) else { return nil }
                return (image, region.fractions)
            }.value
            guard let self else { return }
            self.sharpWorker = nil
            if let made {
                if self.wantedSharp == request {
                    self.sharp = Sharp(request: request, image: made.0, fractions: made.1)
                    self.sharpCount += 1
                    self.sharpSeconds = self.clock() - began
                }
            } else {
                self.refusedSharp = request
            }
            self.pumpSharp()
        }
    }

    /// Waits for the picture in hand. For the tests.
    func settle() async {
        while let running = worker ?? sharpTimer ?? sharpWorker ?? thumbnailTasks.values.first { await running.value }
    }

    private func pump() {
        guard worker == nil, let request = wanted, request != published else { return }
        rasterCount += 1
        let field = field
        worker = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) {
                Self.image(of: field.raster(of: request.components, width: request.width, height: request.height, on: request.frame, lens: request.lens),
                           width: request.width, height: request.height)
            }.value
            guard let self else { return }
            let interval = Self.publishInterval(refreshesPerSecond: self.refreshesPerSecond)
            let wait = self.lastPublished + interval - self.clock()
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            self.worker = nil
            // A stroke began meanwhile: its own pictures are up, and this waits for it to end.
            guard !self.isLive else { return }
            if let made {
                self.keep(made, of: request)
                // Newer shapes may be wanted by now: this one is still nearer them than what is up. Not
                // once nothing is wanted, when it would come back up after the overlay went away.
                if self.wanted != nil { self.publish(made, of: request) }
            }
            self.pump()
        }
    }

    private func publish(_ image: CGImage, of request: MaskOverlayRequest) {
        self.image = image
        published = request
        lastPublished = clock()
        publishCount += 1
    }

    private func keep(_ image: CGImage, of request: MaskOverlayRequest) {
        guard max(request.width, request.height) == MaskOverlayRequest.settledLongSide else { return }
        kept.removeAll { $0.request == request }
        kept.append((request, image))
        if kept.count > Self.keptRasters { kept.removeFirst(kept.count - Self.keptRasters) }
    }

    /// A list row's small picture of `components`, 72 by 48 or its portrait. Shapes alone are made here: about a millisecond's work
    /// at most, and a slider cannot ask for a new one, since it holds nothing but shapes. One that reads the library (a smart
    /// selection's seed, a Follow edges stroke's shape: a PNG read and checked, 4 to 23 ms each when the session's loader does not
    /// already hold it) is made off the main actor, as the overlay's rasters are, since a row's body asks: `nil` until it lands,
    /// a moment later, when the row draws again (`thumbnailsArrived`).
    func thumbnail(of components: [MaskComponent], portrait: Bool) -> CGImage? {
        let key = ThumbnailKey(components: components, portrait: portrait)
        if let kept = thumbnails[key] { return kept }
        let width = portrait ? 48 : 72, height = portrait ? 72 : 48, field = field
        guard Self.readsLibrary(components) else {
            let made = Self.image(of: field.raster(of: components, width: width, height: height), width: width, height: height)
            keep(thumbnail: made, for: key)
            return made
        }
        _ = thumbnailsArrived
        guard thumbnailTasks[key] == nil else { return nil }
        thumbnailTasks[key] = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) {
                Self.image(of: field.raster(of: components, width: width, height: height), width: width, height: height)
            }.value
            guard let self else { return }
            self.thumbnailTasks[key] = nil
            self.keep(thumbnail: made, for: key)
            self.thumbnailsArrived += 1
        }
        return nil
    }

    private func keep(thumbnail: CGImage?, for key: ThumbnailKey) {
        if thumbnails.count >= Self.keptThumbnails { thumbnails.removeAll() }
        thumbnails[key] = .some(thumbnail)
    }

    /// Whether a picture of `components` reads the library: a smart selection's seed, or a Follow edges stroke's measured shape.
    nonisolated static func readsLibrary(_ components: [MaskComponent]) -> Bool {
        components.contains { component in
            switch component.shape {
            case .smart(let selection): return selection.raster != nil
            case .brush(let paint): return paint.strokes.contains { $0.measured != nil }
            case .linear, .radial: return false
            }
        }
    }

    /// An 8-bit alpha-only picture: tinted by a template `Image` and five times cheaper for the app than
    /// premultiplied RGBA (measured, P0-S2). Swift needs the gray space; an sRGB one returns nil.
    nonisolated static func image(of coverage: [UInt8], width: Int, height: Int) -> CGImage? {
        guard coverage.count == width * height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return nil }
        let row = context.bytesPerRow
        coverage.withUnsafeBytes { source in
            for y in 0..<height {
                (data + y * row).copyMemory(from: source.baseAddress! + y * width, byteCount: width)
            }
        }
        return context.makeImage()
    }
}

/// Over the picture, under the canvas: the overlay, tinted, at the picture's rectangle so it keeps with it
/// through a zoom, and the selected gradient's handles over that. No hits, and nothing at all with no mask
/// selected or hovered. It is the only view that reads a moving gradient, so 120 events a second run this body.
/// A settled zoom draws the sharp raster of the visible region in place of the coarse one (`MaskOverlaySharpRequest`).
/// While Compare splits the picture the overlay is the film side's alone: the neutral side shows neither its red nor its effect.
struct MaskOverlayView: View {
    let frame: Frame
    let geometry: FrameGeometry
    /// How much of the picture's width, from its left edge, shows the neutral raw, while Compare splits it: the neutral layer's own number,
    /// so their edges agree to the pixel. Nil with no split up.
    let neutralWidth: CGFloat?
    let decode: MaskOverlayDecode
    @Environment(RollModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let editor = model.maskEditor, store = editor.overlay
        let components = model.overlayComponents(for: frame)
        let request = components.map {
            MaskOverlayRequest(components: $0, picture: geometry.picture.size,
                               longSide: editor.isPlacing ? MaskOverlayRequest.draftLongSide : MaskOverlayRequest.settledLongSide,
                               frame: frame, lens: editor.pictureLens(on: frame))
        }
        let wantedSharp = sharpRequest(components: components, editor: editor, isLive: store.isLive)
        Color.clear
            .overlay {
                if request != nil || store.isLive, let image = store.image {
                    let sharp = store.sharp.flatMap { up in wantedSharp.flatMap { up.request.showsSamePlace(as: $0) ? up : nil } }
                    drawn(sharp: sharp, coarse: image, colour: editor.overlayColour.color)
                }
            }
            .overlay {
                if let shape = editor.shapeUnderHandles(in: frame) {
                    // Equatable: a slider's step, which rewrites the mask but not its shape, draws no handle again.
                    MaskHandlesView(shape: shape, geometry: geometry)
                        .equatable()
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: request, initial: true) { _, wanted in store.want(wanted) }
            .onChange(of: wantedSharp, initial: true) { _, wanted in store.wantSharp(wanted) }
    }

    /// The sharp raster this view wants of `components`, or nil: only over a zoomed picture at rest, and never while the pointer shapes a mask
    /// or paints (which keep the coarse raster), during a stroke's own pictures, or during a develop, whose memory gate does not count it.
    private func sharpRequest(components: [MaskComponent]?, editor: MaskEditor, isLive: Bool) -> MaskOverlaySharpRequest? {
        guard let components, !isLive, !editor.isPlacing, !model.isDeveloping, model.frameZoom.isZoomed, decode.pixels != nil,
              let fractions = geometry.visibleFractions else { return nil }
        return MaskOverlaySharpRequest(components: components, perPixel: model.overlayReadsPerPixel(for: frame),
                                       version: model.manualAdjustments(for: frame).masks.version, frame: frame,
                                       fractions: fractions, decode: decode, lens: editor.pictureLens(on: frame))
    }

    /// The overlay's picture over the picture's rectangle: the sharp raster where it holds, the coarse one otherwise, tinted and clipped to
    /// the picture's rounded corners and to the film side of a split.
    @ViewBuilder private func drawn(sharp: MaskOverlayStore.Sharp?, coarse: CGImage, colour: Color) -> some View {
        let picture = geometry.picture
        ZStack(alignment: .topLeading) {
            if let sharp {
                tint(sharp.image, colour)
                    .frame(width: sharp.fractions.width * picture.width, height: sharp.fractions.height * picture.height)
                    .offset(x: sharp.fractions.minX * picture.width, y: sharp.fractions.minY * picture.height)
            } else {
                tint(coarse, colour)
                    .frame(width: picture.width, height: picture.height)
            }
        }
        .frame(width: picture.width, height: picture.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .modifier(MaskOverlayFilmSide(filmWidth: neutralWidth.map { max(0, picture.width - $0) }))
        .position(geometry.center)
    }

    private func tint(_ image: CGImage, _ colour: Color) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.medium)
            .renderingMode(.template)
            .foregroundStyle(colour)
            .opacity(contrast == .increased || reduceTransparency ? MaskOverlayColour.firmOpacity : MaskOverlayColour.opacity)
    }
}

/// The overlay's part of a split comparison: the film side, the part of the picture right of the divider. Kept apart so the overlay with no
/// split is exactly as it always was: no mask in its chain.
private struct MaskOverlayFilmSide: ViewModifier {
    let filmWidth: CGFloat?

    func body(content: Content) -> some View {
        if let filmWidth {
            content.mask(alignment: .trailing) { Rectangle().frame(width: filmWidth) }
        } else {
            content
        }
    }
}
