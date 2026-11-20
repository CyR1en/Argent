import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import os
import Vision

/// Paint or a click turned into the object under it, by macOS 27's iterative segmentation (docs/remove-plan.md, section 4.6). The
/// model was measured not to find an object from a part of it, so a rough stroke is enough only because this finds the whole
/// object first.
///
/// It runs in the app, on the picture smart masks are given (`MaskInputPicture.image`). Its model is an asset the system
/// downloads; where that is not ready the Remove tab's selection is what was painted, and the tab says so.
///
/// What `GenerateIterativeSegmentationRequest` turned out to be, measured on 2026-11-16 (macOS 27.2, M5 Pro) on drawn shapes and
/// on a 2560-pixel print of a sample frame. Each of these shapes the code below:
///
/// - **Its points are measured from the bottom left,** as all of Vision's are, and a prompt's from the top left. Its mask comes
///   back at the picture's size, half floats from about 0 to 1, top row first; a scribble buffer is read top row first too.
/// - **What a request refines belongs to the process, not to the request.** A request that carries included or excluded points
///   does not look at the picture it is performed on: it refines the last mask any request of this kind made, on the last
///   picture one of them encoded. One that carried a point before its first run answered in 8 ms from another picture (11,060
///   pixels where 53,000 were right), and so did one refined after another request had run between. So every selection is the
///   seed alone first, then all its other points at once, with no other selection between the two (`Turns`).
/// - **A scribble is read as rough paint over the object or a ring around it, not as a line across it.** A thin stroke inside
///   a large object comes back as the stroke: 4 of 4 on objects 130 pixels wide and more (overlap with the object 0.03 to
///   0.11), where paint three times as wide found the same objects (0.98 to 1.00), and paint that ran past the object mostly
///   found the ground. The same strokes read as one click at the middle of their paint found the object in 25 of 25 (0.91 to
///   1.00), those that ran past it at both ends included. Further points along the paint found more of a figure of three
///   parts that touch (whole in 3 of 4 against 1 of 4) but selected the ground wherever paint ran past the object (13 of 19
///   on the sample frame against 19 of 19); a part that is missed costs one more stroke, so a stroke is read at its middle
///   alone (`StrokeReading`).
/// - **The asset's status says whether this process holds the model, not whether the Mac has it.** It is `notReady` in a
///   process that has not asked, on a Mac that has the model; asking returns in 2 to 17 ms, and the status is then `ready` only
///   while the request that asked is alive, or once any request has run. So one request is kept to ask on (`keeper`).
/// - **A click takes 57 to 63 ms and a refinement 10 to 18 ms** at 2560 pixels on a quiet machine, at any of the three
///   quality levels, which is why the level is left at the request's own, `balanced`: `fast` returns a 256-pixel mask, and
///   `accurate` cost the same and chose differently where a click was ambiguous, not visibly better.
///
/// No request here is given a compute device. Forcing one on this request killed the masking research's process with SIGKILL
/// (docs/masking-plan.md, R2), and Vision already runs it on the GPU, the only device it lists for it on this Mac.
public struct ObjectSelector: Sendable {
    public enum Availability: Sendable, Equatable {
        case ready
        /// The system is fetching the model.
        case downloading
        /// Not on this Mac, and why: Snap to Object is then off.
        case unavailable(String)
    }

    /// What was painted, as fractions of the picture from its top left.
    public enum Prompt: Sendable, Equatable {
        /// A click.
        case point(x: Float, y: Float)
        /// A stroke: its coverage over the whole picture, 0 outside and 255 inside, at any size.
        case scribble(width: Int, height: Int, coverage: [UInt8])
    }

    /// How a stroke is put to the request.
    public enum StrokeReading: Sendable, Equatable {
        /// As a click half-way along its paint, and one more for each further piece of paint: the reading that found the whole
        /// object from a line across part of it. It cannot read a ring drawn around an object, whose middle is on the ring.
        case middle
        /// As the request's own scribble buffer, the paint at the size it was given: Vision stretches a buffer of any size and
        /// shape over the picture (the same answer from 256 by 256, half size and full size), so resampling it here would only
        /// soften it. Right for paint that covers much of the object or rings it, and kept so the two readings can be compared
        /// on real frames (`ObjectSelectorMeasureTests`).
        case scribble
    }

    /// Why there is no selection.
    public enum Failure: Error, Equatable, LocalizedError, CustomStringConvertible {
        /// The request ran and found nothing under the prompt, the stroke had no paint, or an Option-stroke took away all that
        /// was selected. Not a fault: there is nothing to tint.
        case nothingSelected
        /// The model is not on this Mac yet, and what `availability` said: the selection is what was painted.
        case notReady(Availability)
        /// Vision failed, in its own words.
        case request(String)

        public var description: String {
            switch self {
            case .nothingSelected: return "Nothing is selected."
            case .notReady(.unavailable(let why)): return why
            case .notReady: return "Snap to Object is waiting for a model macOS is downloading."
            case .request(let why): return "Snap to Object failed: \(why)"
            }
        }

        public var errorDescription: String? { description }
    }

    public let strokes: StrokeReading

    public init(strokes: StrokeReading = .middle) {
        self.strokes = strokes
    }

    // MARK: the asset

    /// Whether the model is on this Mac. Where the process does not hold it yet this asks macOS for it, which is also what
    /// starts its download on a Mac without it; later calls then say `downloading` until it has come, or why it could not. One
    /// ask is out at a time, and another is made only after one has failed. It waits at most `grace`, and only while an ask is
    /// out.
    public func availability() async -> Availability {
        let status = await Self.keeper.assetStatus
        if case .ready = status { return .ready }
        if case .downloading = status { return .downloading }
        switch await Self.settled(Self.ask()) {
        case .going: return .downloading
        case .done(let why?): return .unavailable(why)
        case .done(nil): return Self.known(await Self.keeper.assetStatus) ?? .unavailable("Snap to Object needs a model macOS has not made ready.")
        }
    }

    /// How long `availability` waits for macOS to answer an ask. `notReady` is also what a process that has not asked is told
    /// about a model the Mac already has, and asking then returns in milliseconds (measured), so a short wait tells that apart
    /// from a download, which would otherwise read as one on every launch.
    static let grace: Duration = .seconds(1)

    /// The request every ask is made on, kept for the life of the process: the status of every request reads `ready` only
    /// while one that asked is alive (measured), so asking on a request that is then let go would have to be done again each
    /// time. It is never performed.
    private static let keeper = GenerateIterativeSegmentationRequest(seedPoint: .zero)

    /// The ask that is out, if one is.
    private static let asking = OSAllocatedUnfairLock<Task<String?, Never>?>(initialState: nil)

    /// The ask that is out, or a new one: why the model could not be had, or `nil` once it is here.
    private static func ask() -> Task<String?, Never> {
        asking.withLock { out in
            if let out { return out }
            let ask = Task.detached { () -> String? in
                // Cleared when it ends, so that a failure can be asked about again; a success never is, since the status
                // then answers.
                defer { asking.withLock { $0 = nil } }
                do {
                    try await keeper.downloadAssets()
                    return nil
                } catch {
                    return reason(error)
                }
            }
            out = ask
            return ask
        }
    }

    private enum Ask: Sendable {
        case done(String?)
        case going
    }

    /// What an ask came to, or `going` when it is still out after `grace`.
    private static func settled(_ ask: Task<String?, Never>) async -> Ask {
        let (answers, answer) = AsyncStream<Ask>.makeStream()
        // Waiting on a task cannot be given up, so the wait and the clock each answer a stream and the first answer is taken.
        // The waiter ends with the download.
        Task {
            answer.yield(.done(await ask.value))
            answer.finish()
        }
        let clock = Task {
            try? await Task.sleep(for: grace)
            answer.yield(.going)
            answer.finish()
        }
        defer { clock.cancel() }
        for await first in answers { return first }
        return .going
    }

    /// A status that says where the model is; `nil` for `notReady`, which does not.
    private static func known(_ status: DownloadableAssetsRequestStatus) -> Availability? {
        switch status {
        case .ready: return .ready
        case .downloading: return .downloading
        case .error(let error): return .unavailable(reason(error))
        case .notReady: return nil
        @unknown default: return nil
        }
    }

    private static func reason(_ error: any Error) -> String {
        "Snap to Object needs a model macOS could not download. \(error.localizedDescription)"
    }

    // MARK: a selection

    /// The object under `prompt` in `picture`, as a selection at the picture's size; `excluded` are Option-clicks, places that are
    /// not the object. Throws `Failure.nothingSelected` when the request finds nothing there, `Failure.notReady` without running
    /// it where the model is not on this Mac, and `Failure.request` when Vision itself fails.
    public func select(_ prompt: Prompt, excluded: [(x: Float, y: Float)] = [], in picture: CGImage) async throws -> RemovalPipeline.Selection {
        let asked = try Self.asked(prompt, excluded: excluded, reading: strokes)
        let availability = await availability()
        guard availability == .ready else { throw Failure.notReady(availability) }
        let (width, height) = (picture.width, picture.height)
        return try await Turns.shared.take {
            let request: GenerateIterativeSegmentationRequest
            switch asked.seed {
            case .point(let point):
                request = GenerateIterativeSegmentationRequest(seedPoint: point)
            case .scribble(let width, let height, let paint):
                let buffer = try Self.scribbleBuffer(width: width, height: height, paint: paint)
                request = GenerateIterativeSegmentationRequest(seedScribbleBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: buffer))
            }
            let observation: PixelBufferObservation?
            do {
                // The seed alone first: only that run encodes the picture, and the points refine what it finds. Performing a
                // request once more than this refines its own answer again, so there is no third run. The picture is upright,
                // as every picture the masks are given is.
                let seeded = try await request.perform(on: picture, orientation: .up)
                if asked.included.isEmpty && asked.excluded.isEmpty {
                    observation = seeded
                } else {
                    for point in asked.included { try request.addIncludedPoint(point) }
                    for point in asked.excluded { try request.addExcludedPoint(point) }
                    observation = try await request.perform(on: picture, orientation: .up)
                }
            } catch {
                throw Failure.request(error.localizedDescription)
            }
            guard let observation else { throw Failure.nothingSelected }
            return try observation.pixelBuffer.withUnsafeBuffer { try Self.selection(from: $0, width: width, height: height) }
        }
    }

    /// The selection after one more stroke or click: the object under `prompt` joined to `selection`, or taken out of it when
    /// `subtracting`, the Option-stroke. With no selection yet it is the object alone.
    ///
    /// Each stroke is a selection of its own and the two are combined here, not one request refined stroke after stroke. What a
    /// request refines is the process's (see the type's comment), so a request kept between strokes would answer from whatever
    /// ran since. And a later stroke given to the same request as a point makes the model choose again, so that what nobody
    /// painted comes and goes: legs, then a point on the head, brought a fifth of the body between them, and a point taken
    /// back by an Option-point left two thirds of its shape selected. A selection each is exact: a stroke adds what it finds,
    /// an Option-stroke removes what it finds, and nothing else moves. Each costs one request, about 60 ms.
    ///
    /// Throws `Failure.nothingSelected` when the stroke finds nothing or leaves nothing; the caller then keeps what it had.
    public func select(_ prompt: Prompt, subtracting: Bool, from selection: RemovalPipeline.Selection?,
                       in picture: CGImage) async throws -> RemovalPipeline.Selection {
        guard let selection else {
            guard !subtracting else { throw Failure.nothingSelected }
            return try await select(prompt, in: picture)
        }
        return try Self.combined(selection, with: try await select(prompt, in: picture), subtracting: subtracting)
    }

    /// `selection` with `object` joined to it or taken out of it, at `object`'s size, which is the picture's; a selection of
    /// another size, a painted one, is stretched to it.
    static func combined(_ selection: RemovalPipeline.Selection, with object: RemovalPipeline.Selection,
                         subtracting: Bool) throws -> RemovalPipeline.Selection {
        let (width, height) = (object.width, object.height)
        var held = selection.coverage
        if selection.width != width || selection.height != height {
            let columns = (0..<width).map { $0 * selection.width / width }
            held = [UInt8](repeating: 0, count: width * height)
            selection.coverage.withUnsafeBufferPointer { source in
                held.withUnsafeMutableBufferPointer { out in
                    for y in 0..<height {
                        let row = (y * selection.height / height) * selection.width
                        for x in 0..<width { out[y * width + x] = source[row + columns[x]] }
                    }
                }
            }
        }
        // Eight pixels at a time: a byte of 128 or more is one with its top bit set, and that bit spread over its byte is 255.
        let count = width * height, words = count / 8
        var coverage = [UInt8](repeating: 0, count: count)
        held.withUnsafeBytes { held in
            object.coverage.withUnsafeBytes { found in
                coverage.withUnsafeMutableBytes { out in
                    let top: UInt64 = 0x8080_8080_8080_8080
                    for word in 0..<words {
                        let had = held.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self) & top
                        let has = found.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self) & top
                        out.storeBytes(of: ((subtracting ? had & ~has : had | has) >> 7) &* 0xFF, toByteOffset: word * 8, as: UInt64.self)
                    }
                    for i in (words * 8)..<count {
                        let had = held[i] >= 128, has = found[i] >= 128
                        out[i] = (subtracting ? had && !has : had || has) ? 255 : 0
                    }
                }
            }
        }
        guard isAnySelected(coverage) else { throw Failure.nothingSelected }
        return try RemovalPipeline.Selection(width: width, height: height, coverage: coverage)
    }

    // MARK: planes the picture's size

    /// Whether any byte of `plane` is 255. These planes are the picture's size, 4.4 million bytes, and Argent is usually run as
    /// a debug build, where a loop over one a byte at a time cost a quarter of a second against the request's own 60 ms
    /// (measured). So here and below they are searched and thresholded by the C library and vImage, or eight bytes at a time.
    private static func isAnySelected(_ plane: [UInt8]) -> Bool {
        plane.withUnsafeBytes { memchr($0.baseAddress, 255, $0.count) != nil }
    }

    /// `plane` with every byte of 128 or more at 255 and the rest at 0.
    static func binary(_ plane: [UInt8]) -> [UInt8] {
        guard !plane.isEmpty else { return [] }
        var made = [UInt8](repeating: 0, count: plane.count)
        plane.withUnsafeBytes { source in
            made.withUnsafeMutableBytes { out in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: 1, width: vImagePixelCount(plane.count), rowBytes: plane.count)
                var to = vImage_Buffer(data: out.baseAddress, height: 1, width: vImagePixelCount(plane.count), rowBytes: plane.count)
                _ = vImageTableLookUp_Planar8(&from, &to, halfAndOver, vImage_Flags(kvImageNoFlags))
            }
        }
        return made
    }

    private static let halfAndOver: [Pixel_8] = (0...255).map { $0 >= 128 ? 255 : 0 }

    // MARK: a prompt in Vision's terms

    /// What a request starts from.
    enum Seed: Sendable, Equatable {
        case point(NormalizedPoint)
        /// A stroke's paint, 255 inside and 0 outside.
        case scribble(width: Int, height: Int, paint: [UInt8])
    }

    /// A prompt as the request takes it: its seed, then the points it is told are the object's too and those that are not.
    struct Asked: Sendable, Equatable {
        var seed: Seed
        var included: [NormalizedPoint] = []
        var excluded: [NormalizedPoint] = []
    }

    /// At most this many pieces of one prompt's paint are read, the largest first: a stroke is one piece, and paint in more
    /// than a few is spray, not objects.
    static let pieceLimit = 8

    static func asked(_ prompt: Prompt, excluded: [(x: Float, y: Float)], reading: StrokeReading) throws -> Asked {
        let excluded = try excluded.map { try visionPoint(x: $0.x, y: $0.y) }
        switch prompt {
        case .point(let x, let y):
            return Asked(seed: .point(try visionPoint(x: x, y: y)), excluded: excluded)
        case .scribble(let width, let height, let coverage):
            guard width > 0, height > 0, coverage.count == width * height else {
                throw RemovalError.invalid("a stroke's coverage is its width by its height")
            }
            let paint = binary(coverage)
            guard isAnySelected(paint) else { throw Failure.nothingSelected }
            switch reading {
            case .scribble:
                return Asked(seed: .scribble(width: width, height: height, paint: paint), excluded: excluded)
            case .middle:
                let middles = try middles(width: width, height: height, paint: paint).map { try visionPoint(x: $0.x, y: $0.y) }
                return Asked(seed: .point(middles[0]), included: Array(middles.dropFirst()), excluded: excluded)
            }
        }
    }

    /// A place in the picture as Vision counts it: the same fraction across, and up from the bottom where a prompt counts down
    /// from the top. A place just outside the picture is its nearest edge.
    static func visionPoint(x: Float, y: Float) throws -> NormalizedPoint {
        guard x.isFinite, y.isFinite else { throw RemovalError.invalid("a prompt's point is a place in the picture") }
        return NormalizedPoint(x: CGFloat(min(max(x, 0), 1)), y: CGFloat(1 - min(max(y, 0), 1)))
    }

    /// The middle of each piece of paint, the largest piece first, as fractions of the picture from its top left: the place
    /// half-way along the piece, moved to the middle of the paint's width, and always on paint. Half-way along and not the
    /// paint's centre of mass, which is off the paint of a curved stroke; and the middle and not the ends, which is where paint
    /// runs past the object.
    ///
    /// `paint` is 255 inside and 0 outside (`binary`). The middles are found on a grid of cells at most 256 on the longer side,
    /// a cell painted when any pixel in it is, so the thinnest stroke stays in one piece.
    static func middles(width: Int, height: Int, paint: [UInt8]) -> [(x: Float, y: Float)] {
        let cell = max(1, (max(width, height) + 255) / 256)
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var painted = [Bool](repeating: false, count: columns * rows)
        paint.withUnsafeBytes { paint in
            for y in 0..<height {
                // From one painted pixel to the next past its cell, by the C library's search: most of a row has no paint.
                let row = paint.baseAddress! + y * width
                var x = 0
                while x < width, let found = memchr(row + x, 255, width - x) {
                    let column = (UnsafeRawPointer(found) - row) / cell
                    painted[(y / cell) * columns + column] = true
                    x = (column + 1) * cell
                }
            }
        }

        // How far each painted cell is from one that is not, in cells and counting diagonals as one: the middle of the paint's
        // width is where this is greatest.
        var depth = [Int32](repeating: 0, count: columns * rows)
        func isEdge(_ x: Int, _ y: Int) -> Bool { x == 0 || y == 0 || x == columns - 1 || y == rows - 1 }
        for y in 0..<rows {
            for x in 0..<columns where painted[y * columns + x] {
                let i = y * columns + x
                depth[i] = isEdge(x, y) ? 1 : min(depth[i - 1], depth[i - columns - 1], depth[i - columns], depth[i - columns + 1]) + 1
            }
        }
        for y in stride(from: rows - 1, through: 0, by: -1) {
            for x in stride(from: columns - 1, through: 0, by: -1) where painted[y * columns + x] && !isEdge(x, y) {
                let i = y * columns + x
                depth[i] = min(depth[i], min(depth[i + 1], depth[i + columns + 1], depth[i + columns], depth[i + columns - 1]) + 1)
            }
        }

        /// The painted cells reached from `start`, in the order reached, each with the cell it was reached from.
        func spread(from start: Int, into parent: inout [Int32]) -> [Int] {
            var reached = [start], next = 0
            parent[start] = Int32(start)
            while next < reached.count {
                let from = reached[next]
                next += 1
                let (fx, fy) = (from % columns, from / columns)
                for y in max(0, fy - 1)...min(rows - 1, fy + 1) {
                    for x in max(0, fx - 1)...min(columns - 1, fx + 1) {
                        let to = y * columns + x
                        guard painted[to], parent[to] < 0 else { continue }
                        parent[to] = Int32(from)
                        reached.append(to)
                    }
                }
            }
            return reached
        }

        // Each piece, by the cell farthest from where it was first met, which is one of its two ends.
        var pieces: [(size: Int, end: Int)] = []
        var seen = [Int32](repeating: -1, count: columns * rows)
        for start in 0..<(columns * rows) where painted[start] && seen[start] < 0 {
            let reached = spread(from: start, into: &seen)
            pieces.append((reached.count, reached[reached.count - 1]))
        }
        pieces.sort { $0.size > $1.size }

        return pieces.prefix(pieceLimit).map { piece in
            // From one end to the cell farthest from it, the other end, and back along the way that was taken.
            var parent = [Int32](repeating: -1, count: columns * rows)
            let reached = spread(from: piece.end, into: &parent)
            var path = [reached[reached.count - 1]]
            while Int(parent[path[path.count - 1]]) != path[path.count - 1] { path.append(Int(parent[path[path.count - 1]])) }
            var middle = path[path.count / 2]
            while true {
                let (mx, my) = (middle % columns, middle / columns)
                var deepest = middle
                for y in max(0, my - 1)...min(rows - 1, my + 1) {
                    for x in max(0, mx - 1)...min(columns - 1, mx + 1) where depth[y * columns + x] > depth[deepest] {
                        deepest = y * columns + x
                    }
                }
                guard deepest != middle else { break }
                middle = deepest
            }
            // The cell's painted pixel nearest its centre, so that the point is on paint however thin the stroke.
            let (x0, y0) = (middle % columns * cell, middle / columns * cell)
            let centre = (x: Float(x0) + Float(cell) / 2, y: Float(y0) + Float(cell) / 2)
            var nearest = (x: centre.x, y: centre.y, distance: Float.infinity)
            for y in y0..<min(height, y0 + cell) {
                for x in x0..<min(width, x0 + cell) where paint[y * width + x] == 255 {
                    let (px, py) = (Float(x) + 0.5, Float(y) + 0.5)
                    let distance = (px - centre.x) * (px - centre.x) + (py - centre.y) * (py - centre.y)
                    if distance < nearest.distance { nearest = (px, py, distance) }
                }
            }
            return (nearest.x / Float(width), nearest.y / Float(height))
        }
    }

    /// The paint as the buffer `seedScribbleBuffer` takes: one byte a pixel at the paint's own size, top row first.
    static func scribbleBuffer(width: Int, height: Int, paint: [UInt8]) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_OneComponent8, nil, &made) == kCVReturnSuccess, let buffer = made else {
            throw Failure.request("a scribble's buffer could not be made")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.request("a scribble's buffer could not be written") }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        paint.withUnsafeBytes { paint in
            for y in 0..<height { (base + y * rowBytes).copyMemory(from: paint.baseAddress! + y * width, byteCount: width) }
        }
        return buffer
    }

    // MARK: Vision's mask as a selection

    /// Vision's mask as a selection `width` by `height`: selected where the mask is one half or more. The mask has been the
    /// picture's size in every run; one of another size is read at the nearest of its pixels.
    static func selection(from mask: CVPixelBuffer, width: Int, height: Int) throws -> RemovalPipeline.Selection {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let (maskWidth, maskHeight) = (CVPixelBufferGetWidth(mask), CVPixelBufferGetHeight(mask))
        guard width > 0, height > 0, maskWidth > 0, maskHeight > 0, let base = CVPixelBufferGetBaseAddress(mask) else {
            throw Failure.request("Vision returned a mask that cannot be read")
        }
        // The mask in 8 bits first, by vImage, which rounds to the nearest code: one half is 127.5 and becomes 128, and the
        // largest half float under it becomes 127, so 128 and over is one half and over exactly. A value that is not a number
        // becomes 0.
        var codes = [UInt8](repeating: 0, count: maskWidth * maskHeight)
        let format = CVPixelBufferGetPixelFormatType(mask)
        let converted: vImage_Error = codes.withUnsafeMutableBytes { out in
            var from = vImage_Buffer(data: base, height: vImagePixelCount(maskHeight), width: vImagePixelCount(maskWidth),
                                     rowBytes: CVPixelBufferGetBytesPerRow(mask))
            var to = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(maskHeight), width: vImagePixelCount(maskWidth), rowBytes: maskWidth)
            switch format {
            case kCVPixelFormatType_OneComponent16Half: return vImageConvert_Planar16FtoPlanar8(&from, &to, vImage_Flags(kvImageNoFlags))
            case kCVPixelFormatType_OneComponent32Float: return vImageConvert_PlanarFtoPlanar8(&from, &to, 1, 0, vImage_Flags(kvImageNoFlags))
            case kCVPixelFormatType_OneComponent8: return vImageCopyBuffer(&from, &to, 1, vImage_Flags(kvImageNoFlags))
            default: return kvImageInvalidImageFormat
            }
        }
        guard converted == kvImageNoError else {
            throw Failure.request("Vision returned a mask in a format that is not read (\(format))")
        }
        var coverage = binary(codes)
        if maskWidth != width || maskHeight != height {
            let columns = (0..<width).map { $0 * maskWidth / width }
            let read = coverage
            coverage = [UInt8](repeating: 0, count: width * height)
            read.withUnsafeBufferPointer { read in
                coverage.withUnsafeMutableBufferPointer { out in
                    for y in 0..<height {
                        let row = (y * maskHeight / height) * maskWidth
                        for x in 0..<width { out[y * width + x] = read[row + columns[x]] }
                    }
                }
            }
        }
        guard isAnySelected(coverage) else { throw Failure.nothingSelected }
        return try RemovalPipeline.Selection(width: width, height: height, coverage: coverage)
    }
}

/// One selection at a time in the process, first come first served. What a request refines is shared by every request of its
/// kind in the process (`ObjectSelector`'s comment), so a second selection between a first one's seed and its points would have
/// the first answer from the second's picture; nothing else in Argent makes this request.
private actor Turns {
    static let shared = Turns()

    private var taken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        // An actor lets another caller in at every wait, so the turn is held by hand and handed to the next in line.
        if taken {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            taken = true
        }
        defer {
            if waiting.isEmpty { taken = false } else { waiting.removeFirst().resume() }
        }
        return try await work()
    }
}
