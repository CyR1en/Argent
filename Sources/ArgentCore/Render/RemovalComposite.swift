import Foundation
import Metal

/// A frame's removals laid into its decode before the lens warp (docs/remove-plan.md, section 4.3): over each patch's box, the decode
/// mixed with the patch by one of its two alphas, in the frame's order.
///
/// A patch's raster is the model's, smaller than its box at full size and larger than it on a small preview. So it is read as the
/// warp reads the decode, with Catmull-Rom weights and the warp's limiter, from the level of its chain whose texels are nearest
/// the decode's in size: a preview needs no reduced copy of a patch, and a develop reads the patch's own pixels.
///
/// A decode of any size covers the whole picture, as the area resize that makes a small one maps all of the source onto all of the
/// output (`AreaResize`). So a texel's centre lies at the same fraction of the picture at every size, and a box in full-size pixels
/// is carried to a decode by those fractions, as a mask's coverage is.
final class RemovalComposite: @unchecked Sendable {
    /// The patches' textures kept between composites: five of the model's largest with their chains, 24 MB each at 1344 by
    /// 1344, or twenty of 640 by 640. A frame whose removals do not all fit uploads them again at every composite.
    static let defaultMaximumBytes = 128 << 20

    /// One removal to lay: its patch, and whether its effects' alpha or the object's alone mixes it in.
    typealias Shown = (patch: RemovalPatch, includesEffects: Bool)

    /// One level of a patch's chain, top row first. Level 0 is the patch's own planes; each further level has half the sides of
    /// the one before, rounded down, and each of its texels is the mean of the area above that it covers. A level's texels
    /// therefore cover the whole patch whatever its sides, and a box is read from any level by fractions.
    struct Level {
        let width: Int, height: Int
        let rgb: [Float16]
        let object: [UInt8]
        let effects: [UInt8]

        init(_ patch: RemovalPatch) {
            width = patch.width; height = patch.height
            rgb = patch.rgb; object = patch.objectAlpha; effects = patch.effectsAlpha
        }

        private init(width: Int, height: Int, rgb: [Float16], object: [UInt8], effects: [UInt8]) {
            self.width = width; self.height = height; self.rgb = rgb; self.object = object; self.effects = effects
        }

        /// The next level. A texel's weights are whole numbers, the shares of the texels above in units of one output texel's
        /// worth, and its mean is rounded once, to a half float's nearest and an alpha's nearest code. Sides that do not halve
        /// evenly put many means exactly between two half floats, and weights in fractions would round those either way.
        var halved: Level {
            let (wide, high) = (max(1, width / 2), max(1, height / 2))
            // An output texel's span of the level above, each side scaled by the other's count so that both are whole: its first
            // texel, and how much of each texel lies inside it.
            func spans(_ from: Int, _ to: Int) -> [(first: Int, shares: [Double])] {
                (0..<to).map { i in
                    let start = i * from, end = (i + 1) * from
                    let first = start / to, last = (end - 1) / to
                    return (first, (first...last).map { Double(min(($0 + 1) * to, end) - max($0 * to, start)) })
                }
            }
            let xs = spans(width, wide), ys = spans(height, high)
            let whole = Double(width) * Double(height)
            var light = [Float16](repeating: 0, count: wide * high * 3)
            var alone = [UInt8](repeating: 0, count: wide * high), both = alone
            rgb.withUnsafeBufferPointer { rgb in object.withUnsafeBufferPointer { object in effects.withUnsafeBufferPointer { effects in
                for j in 0..<high {
                    for i in 0..<wide {
                        var red = 0.0, green = 0.0, blue = 0.0, a = 0.0, b = 0.0
                        for (dy, sy) in ys[j].shares.enumerated() {
                            let row = (ys[j].first + dy) * width + xs[i].first
                            for (dx, sx) in xs[i].shares.enumerated() {
                                let at = row + dx, share = sy * sx
                                red += Double(rgb[at * 3]) * share
                                green += Double(rgb[at * 3 + 1]) * share
                                blue += Double(rgb[at * 3 + 2]) * share
                                a += Double(object[at]) * share
                                b += Double(effects[at]) * share
                            }
                        }
                        let to = j * wide + i
                        light[to * 3] = Float16(red / whole)
                        light[to * 3 + 1] = Float16(green / whole)
                        light[to * 3 + 2] = Float16(blue / whole)
                        alone[to] = UInt8(min(255, (a / whole).rounded()))
                        both[to] = UInt8(min(255, (b / whole).rounded()))
                    }
                }
            } } }
            return Level(width: wide, height: high, rgb: light, object: alone, effects: both)
        }
    }

    /// The levels of a `width` by `height` patch's chain, down to one texel.
    static func levelCount(width: Int, height: Int) -> Int { Int.bitWidth - max(width, height, 1).leadingZeroBitCount }

    /// One side of a patch's box against one side of a decode, in whole numbers: a texel on a box's edge, or one that reads a
    /// patch texel's very centre, is placed by arithmetic and not by how a float happens to round.
    struct Axis: Equatable {
        /// The picture's side at full size and the decode's, in pixels; the box's start and length in full-size pixels, counted as
        /// a texture counts; and the side of the patch's level that is read.
        let full: Int, frame: Int, start: Int, length: Int, level: Int

        private static func floorDivide(_ a: Int, _ b: Int) -> Int { a / b - (a % b < 0 ? 1 : 0) }
        private static func ceilDivide(_ a: Int, _ b: Int) -> Int { -floorDivide(-a, b) }

        /// The decode's texels whose centres lie in the box: texel `q`'s centre is `(2q + 1) * full / (2 * frame)` full-size pixels
        /// along, and the box takes those from its start up to its end.
        var texels: Range<Int> {
            func first(atOrPast edge: Int) -> Int { Self.ceilDivide(Self.ceilDivide(2 * frame * edge, full) - 1, 2) }
            let lower = min(max(first(atOrPast: start), 0), frame)
            return lower..<max(lower, min(first(atOrPast: start + length), frame))
        }

        /// Where the centre of the decode's texel `q` reads the level, a level texel's centre at its index: the texel before it,
        /// and how far past that texel it lies, from 0 up to 1.
        func tap(_ q: Int) -> (base: Int, t: Double) {
            let numerator = ((2 * q + 1) * full - 2 * frame * start) * level - frame * length, denominator = 2 * frame * length
            let base = Self.floorDivide(numerator, denominator)
            return (base, Double(numerator - base * denominator) / Double(denominator))
        }
    }

    /// Where one patch falls in a decode: the texels it reaches and how each reads the patch.
    struct Placement: Equatable {
        /// The decode's texels whose centres lie in the patch's box, row 0 the picture's bottom, as a texture's.
        let columns: Range<Int>, rows: Range<Int>
        /// The level of the patch's chain that is read: the one whose texels are nearest the decode's in size over the box, the
        /// patch's own while it is enlarged.
        let level: Int
        /// How a column and a row read that level, its rows counted from the patch's bottom.
        let x: Axis, y: Axis
    }

    /// The placement of a `width` by `height` patch over `box` in a decode `frame` pixels in size of a picture `full` pixels at
    /// full size; `nil` where it reaches none of the decode's texels.
    static func placement(box: RemovalPatch.Box, width: Int, height: Int, frame: (width: Int, height: Int),
                          full: (width: Int, height: Int)) -> Placement? {
        let density = max(Double(width * full.width) / Double(frame.width * box.width), Double(height * full.height) / Double(frame.height * box.height))
        let level = density > 1 ? min(levelCount(width: width, height: height) - 1, Int(log2(density).rounded())) : 0
        let x = Axis(full: full.width, frame: frame.width, start: box.x, length: box.width, level: max(1, width >> level))
        // A box counts its rows from the picture's top and a texture from its bottom.
        let y = Axis(full: full.height, frame: frame.height, start: full.height - box.y - box.height, length: box.height, level: max(1, height >> level))
        let columns = x.texels, rows = y.texels
        guard !columns.isEmpty, !rows.isEmpty else { return nil }
        return Placement(columns: columns, rows: rows, level: level, x: x, y: y)
    }

    /// The size of the full-size decode of `frame`'s picture: its own when it is that decode, else the picture's the decoder
    /// recorded, else its own over its scale, which is its long side over the full decode's.
    static func fullSize(of frame: LinearFrame) -> (width: Int, height: Int) {
        guard frame.scale > 0, frame.scale < 1 else { return (frame.width, frame.height) }
        if let picture = frame.picture { return (picture.width, picture.height) }
        func side(_ pixels: Int) -> Int { max(pixels, Int((Double(pixels) / Double(frame.scale)).rounded())) }
        return (side(frame.width), side(frame.height))
    }

    /// A patch on the GPU: its light in `rgba16Float` and its two alphas in `rg8Unorm`, the object's in red, each with the patch's
    /// bottom row in row 0, as a decode holds the picture's.
    private struct Raster {
        let light: MTLTexture
        let alphas: MTLTexture
        /// The levels of the patch's chain the textures hold, the first in their level 0.
        let levels: Range<Int>
        let bytes: Int
    }

    private struct Parameters {
        var limit: Float
        var originX: UInt32, originY: UInt32, columns: UInt32, firstRow: UInt32, level: UInt32, channel: UInt32
    }

    /// Where a column or a row of the decode reads a patch's level, as the kernel takes it (`Axis.tap`).
    private struct Tap {
        var base: Int32, t: Float
        init(_ tap: (base: Int, t: Double)) {
            base = Int32(tap.base)
            t = Float(tap.t)
        }
    }

    private let gpu: GPU
    private let pipeline: MTLComputePipelineState
    private let lock = NSLock()
    /// The patches kept, least recently used first; under `lock`.
    private var kept: [(id: PatchID, raster: Raster)] = []
    private var limit = RemovalComposite.defaultMaximumBytes
    private var counts = (uploads: 0, composites: 0)

    init(gpu: GPU) throws {
        let library = try gpu.device.makeLibrary(source: ShaderSource.removalComposite, options: nil)
        guard let function = library.makeFunction(name: "removal_composite") else { throw GPUError.shaderFunctionMissing("removal_composite") }
        pipeline = try gpu.device.makeComputePipelineState(function: function)
        self.gpu = gpu
    }

    /// Patches uploaded and patches laid into a decode so far, for tests.
    var statistics: (uploads: Int, composites: Int) { lock.withLock { counts } }

    /// The bytes of the patches' textures kept for the next composite.
    var residentBytes: Int { lock.withLock { kept.reduce(0) { $0 + $1.raster.bytes } } }

    /// The most that is kept; the least recently used go first.
    var maximumBytes: Int {
        get { lock.withLock { limit } }
        set { lock.withLock { limit = max(0, newValue); trim() } }
    }

    func removeAll() { lock.withLock { kept.removeAll() } }

    /// Call it holding `lock`.
    private func trim() {
        var bytes = kept.reduce(0) { $0 + $1.raster.bytes }
        while bytes > limit, !kept.isEmpty { bytes -= kept.removeFirst().raster.bytes }
    }

    /// `frame`'s decode with `shown` laid in, in order: the decode's own texture when `inPlace`, else a copy from the pool, the
    /// decode left as it was. A develop gives its decode up and makes each frame once, so its patches go into the decode and
    /// their textures are let go as each is laid; a preview keeps its decode, and keeps the textures for the next lens move.
    func composited(_ shown: [Shown], onto frame: LinearFrame, inPlace: Bool, bandRows: Int) throws -> PooledTexture {
        let target = inPlace ? frame.image : try gpu.texturePool.acquire(width: frame.width, height: frame.height)
        if !inPlace {
            try run { commandBuffer in
                guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw GPUError.noEncoder }
                blit.copy(from: frame.texture, to: target.texture)
                blit.endEncoding()
            }
        }
        try lay(shown, into: target.texture, columns: 0..<frame.width, rows: 0..<frame.height, frame: (frame.width, frame.height),
                full: Self.fullSize(of: frame), keeping: !inPlace, bandRows: bandRows)
        return target
    }

    /// The full-size decode `frame` over `box`, `shown` laid in and the decode left as it was: red, green and blue, top row first,
    /// `box.width * box.height * 3` values. Only the box is copied, so a removal's input costs its crop and not a second frame.
    func pixels(of frame: LinearFrame, over box: RemovalPatch.Box, compositing shown: [Shown], bandRows: Int) throws -> [Float16] {
        let (width, height) = (box.width, box.height), bottom = frame.height - box.y - height
        // Not from the pool, which would keep a texture of a size no frame asks for.
        let crop = try gpu.makeTexture(width: width, height: height)
        try run { commandBuffer in
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw GPUError.noEncoder }
            blit.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: box.x, y: bottom, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: crop, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        try lay(shown, into: crop, columns: box.x..<(box.x + width), rows: bottom..<(bottom + height), frame: (frame.width, frame.height),
                full: (frame.width, frame.height), keeping: true, bandRows: bandRows)
        var rgb = [Float16](repeating: 0, count: width * height * 3)
        let band = max(1, min(height, 256))
        var halves = [Float16](repeating: 0, count: width * band * 4)
        for first in stride(from: 0, to: height, by: band) {
            let count = min(band, height - first)
            halves.withUnsafeMutableBytes {
                crop.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, first, width, count), mipmapLevel: 0)
            }
            halves.withUnsafeBufferPointer { halves in
                rgb.withUnsafeMutableBufferPointer { rgb in
                    for row in 0..<count {
                        // The texture's row `first + row` is the picture's row counted from the box's bottom.
                        let to = (height - 1 - first - row) * width * 3, from = row * width * 4
                        for x in 0..<width {
                            rgb[to + x * 3] = halves[from + x * 4]
                            rgb[to + x * 3 + 1] = halves[from + x * 4 + 1]
                            rgb[to + x * 3 + 2] = halves[from + x * 4 + 2]
                        }
                    }
                }
            }
        }
        return rgb
    }

    /// Lays `shown` into `target`, which holds `columns` and `rows` of a decode `frame` pixels in size, in one command buffer a
    /// patch, waited for, so a patch that is not kept is let go before the next is uploaded.
    private func lay(_ shown: [Shown], into target: MTLTexture, columns: Range<Int>, rows: Range<Int>, frame: (width: Int, height: Int),
                     full: (width: Int, height: Int), keeping: Bool, bandRows: Int) throws {
        for (patch, includesEffects) in shown {
            guard let placement = Self.placement(box: patch.box, width: patch.width, height: patch.height, frame: frame, full: full) else { continue }
            // The part of it `target` holds.
            let across = placement.columns.clamped(to: columns), down = placement.rows.clamped(to: rows)
            guard !across.isEmpty, !down.isEmpty else { continue }
            let raster = try raster(of: patch, level: placement.level, keeping: keeping)
            // Worked out here for the decode's own texels, so a texel reads the patch from the same place whichever texture it is
            // written to, and more exactly than a float's 24 bits place a texel thousands of rows into a box.
            let taps = across.map { Tap(placement.x.tap($0)) } + down.map { Tap(placement.y.tap($0)) }
            guard let places = taps.withUnsafeBytes({
                gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }) else { throw GPUError.textureAllocation }
            var parameters = Parameters(limit: (LensStage.limiterRatio - 1) / (LensStage.limiterRatio + 1),
                                        originX: UInt32(across.lowerBound - columns.lowerBound), originY: UInt32(down.lowerBound - rows.lowerBound),
                                        columns: UInt32(across.count), firstRow: 0,
                                        level: UInt32(placement.level - raster.levels.lowerBound), channel: includesEffects ? 1 : 0)
            try run { commandBuffer in
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(target, index: 0)
                encoder.setTexture(raster.light, index: 1)
                encoder.setTexture(raster.alphas, index: 2)
                encoder.setBuffer(places, offset: 0, index: 1)
                // In the warp's bands, so no dispatch runs longer than the warp's.
                for first in stride(from: 0, to: down.count, by: bandRows) {
                    parameters.firstRow = UInt32(first)
                    encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
                    encoder.dispatchPixels(pipeline, width: across.count, height: min(bandRows, down.count - first))
                }
                encoder.endEncoding()
            }
            lock.withLock { counts.composites += 1 }
        }
    }

    private func run(_ encode: (MTLCommandBuffer) throws -> Void) throws {
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        try encode(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
    }

    /// `patch` on the GPU with `level` of its chain: the one kept, which holds every level, or one made now, kept with its whole
    /// chain when `keeping` and else made of that level alone, the least a composite at one size needs.
    private func raster(of patch: RemovalPatch, level: Int, keeping: Bool) throws -> Raster {
        let id = patch.identity
        let found = lock.withLock { () -> Raster? in
            guard let index = kept.firstIndex(where: { $0.id == id }) else { return nil }
            let item = kept.remove(at: index)
            kept.append(item)
            return item.raster
        }
        if let found { return found }
        let made = try upload(patch, levels: keeping ? 0..<Self.levelCount(width: patch.width, height: patch.height) : level..<(level + 1))
        lock.withLock {
            counts.uploads += 1
            // A patch larger than the whole budget is used and let go.
            guard keeping, made.bytes <= limit else { return }
            kept.removeAll { $0.id == id }
            kept.append((id, made))
            trim()
        }
        return made
    }

    private func upload(_ patch: RemovalPatch, levels: Range<Int>) throws -> Raster {
        var level = Level(patch)
        for _ in 0..<levels.lowerBound { level = level.halved }
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: level.width, height: level.height, mipmapped: false)
            descriptor.mipmapLevelCount = levels.count
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
            return texture
        }
        let light = try texture(.rgba16Float), alphas = try texture(.rg8Unorm)
        var bytes = 0
        for index in 0..<levels.count {
            if index > 0 { level = level.halved }
            Self.fill(light, alphas, level: index, from: level)
            bytes += level.width * level.height * 10
        }
        return Raster(light: light, alphas: alphas, levels: levels, bytes: bytes)
    }

    /// Writes `level` into the textures' level `index`, its rows turned over, a band of rows at a time so that an upload holds a
    /// band beside the patch and not a second copy of it.
    private static func fill(_ light: MTLTexture, _ alphas: MTLTexture, level index: Int, from level: Level) {
        let width = level.width, height = level.height, band = max(1, min(height, 64))
        var halves = [Float16](repeating: 1, count: width * band * 4), codes = [UInt8](repeating: 0, count: width * band * 2)
        for first in stride(from: 0, to: height, by: band) {
            let count = min(band, height - first)
            level.rgb.withUnsafeBufferPointer { rgb in level.object.withUnsafeBufferPointer { object in level.effects.withUnsafeBufferPointer { effects in
                halves.withUnsafeMutableBufferPointer { halves in codes.withUnsafeMutableBufferPointer { codes in
                    for row in 0..<count {
                        let from = (height - 1 - first - row) * width, to = row * width
                        for x in 0..<width {
                            halves[(to + x) * 4] = rgb[(from + x) * 3]
                            halves[(to + x) * 4 + 1] = rgb[(from + x) * 3 + 1]
                            halves[(to + x) * 4 + 2] = rgb[(from + x) * 3 + 2]
                            codes[(to + x) * 2] = object[from + x]
                            codes[(to + x) * 2 + 1] = effects[from + x]
                        }
                    }
                } }
            } } }
            let region = MTLRegionMake2D(0, first, width, count)
            halves.withUnsafeBytes { light.replace(region: region, mipmapLevel: index, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
            codes.withUnsafeBytes { alphas.replace(region: region, mipmapLevel: index, withBytes: $0.baseAddress!, bytesPerRow: width * 2) }
        }
    }
}
