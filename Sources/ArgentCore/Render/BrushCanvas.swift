import Foundation
import Metal

// A brush component's coverage as the slice bake reads it: a canvas of the slice's own size, `r16Float`, row 0 the picture's bottom,
// made by laying the component's strokes down in order (`BrushCompositing`). Eight bits accumulate badly (R8 7.5: 0.0187 against
// 0.0046 for half float on a low-flow stroke), so it is half float; a stroke's shape is kept apart from the canvas while it is painted,
// so the canvas takes one rounding a stroke.
//
// A canvas is made two ways that give the same bits: a stroke in progress laid down tick by tick (`BrushStrokeSession`), and strokes
// replayed from the recipe in one dispatch (`BrushReplay`). Once made it is never written again, so a render may read it while the next
// stroke is painted on a copy.

/// What a brush canvas is, the whole of its cache key: the field's size, the masks compiler, and the strokes in order. Not the frame
/// the brush was painted on, which moves no pixel, nor a mask's id, so an undo or a copy with the same strokes hits.
public struct BrushCanvasKey: Sendable, Hashable {
    public let size: MaskFieldSize
    public let version: String
    public let strokes: [BrushStroke]

    public init(size: MaskFieldSize, version: String, strokes: [BrushStroke]) {
        self.size = size; self.version = version; self.strokes = strokes
    }

    /// Whether this canvas is `other` with strokes added: a canvas to continue rather than replay from nothing.
    func extends(_ other: BrushCanvasKey) -> Bool {
        size == other.size && version == other.version && strokes.count > other.strokes.count
            && strokes.starts(with: other.strokes)
    }
}

/// One component's canvas, made once and then only read. Safe to share between threads.
public final class BrushCanvas: @unchecked Sendable {
    public static let pixelFormat = MTLPixelFormat.r16Float

    public let key: BrushCanvasKey
    /// `.r16Float`, `key.size`'s width and height, row 0 the picture's bottom.
    public let texture: MTLTexture

    init(key: BrushCanvasKey, texture: MTLTexture) {
        self.key = key
        self.texture = texture
    }

    /// Two bytes a texel: 5.6 MB on a 3:2 picture, 8.4 MB on a square one.
    public static func byteCount(_ size: MaskFieldSize) -> Int { size.width * size.height * 2 }
    var byteCount: Int { Self.byteCount(key.size) }

    /// The canvas read back, top row first, for tests and measurements.
    public func values() -> [Float] {
        let width = texture.width, height = texture.height
        var halves = [Float16](repeating: 0, count: width * height)
        halves.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 2, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (height - 1 - y) * width
            for x in 0..<width { out[y * width + x] = Float(halves[row + x]) }
        }
        return out
    }

    static func makeTexture(device: MTLDevice, size: MaskFieldSize, label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: size.width, height: size.height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
        texture.label = label
        return texture
    }
}

/// `struct BrushDabGPU` in `ShaderSource.brushCanvas`, 24 bytes.
struct BrushDabGPU {
    var center: SIMD2<Float>
    var outer: Float
    var inner: Float
    var stroke: UInt32
    var pad: UInt32 = 0
}

/// `struct BrushStrokeGPU`, 8 bytes.
struct BrushStrokeGPU {
    var flow: Float
    var erase: UInt32
}

/// `struct BrushCanvasParams`, 64 bytes.
struct BrushCanvasParams {
    var texelToPoint: SIMD2<Float>
    var width: UInt32
    var height: UInt32
    var originX: UInt32 = 0
    var originY: UInt32 = 0
    var tile: UInt32 = 0
    var tilesX: UInt32 = 0
    var freshCount: UInt32 = 0
    var tailCount: UInt32 = 0
    var flow: Float = 0
    var erase: UInt32 = 0
    var hasBase: UInt32 = 0
    var pad: UInt32 = 0

    init(size: MaskFieldSize) {
        texelToPoint = size.texelToPoint
        width = UInt32(size.width)
        height = UInt32(size.height)
    }
}

/// `struct MaskOverlayParams`, 32 bytes.
struct MaskOverlayParams {
    var texelToPoint: SIMD2<Float>
    var fieldHeight: UInt32
    var count: UInt32
    var originX: UInt32
    var originY: UInt32
    var width: UInt32
    var height: UInt32
}

/// A rectangle of texels, `x` from the left and `y` from the picture's top, half open. What a tick changed, for the overlay.
public struct BrushRegion: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func union(_ other: BrushRegion?) -> BrushRegion {
        guard let other, !other.isEmpty else { return self }
        guard !isEmpty else { return other }
        let x0 = min(x, other.x), y0 = min(y, other.y)
        let x1 = max(x + width, other.x + other.width), y1 = max(y + height, other.y + other.height)
        return BrushRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The texels a dab may touch, with a texel to spare, clipped to the field; `nil` when it misses the field.
    static func touched(by dab: BrushDab, radius: Float, size: MaskFieldSize) -> BrushRegion? {
        let step = size.texelToPoint
        let x0 = Int(((dab.x - radius) / step.x - 0.5).rounded(.down)) - 1, x1 = Int(((dab.x + radius) / step.x - 0.5).rounded(.up)) + 1
        let y0 = Int(((dab.y - radius) / step.y - 0.5).rounded(.down)) - 1, y1 = Int(((dab.y + radius) / step.y - 0.5).rounded(.up)) + 1
        let left = max(0, x0), top = max(0, y0), right = min(size.width - 1, x1), bottom = min(size.height - 1, y1)
        guard left <= right, top <= bottom else { return nil }
        return BrushRegion(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    static func touched(by dabs: [BrushDab], radius: Float, size: MaskFieldSize) -> BrushRegion? {
        var out: BrushRegion?
        for dab in dabs { if let r = touched(by: dab, radius: radius, size: size) { out = r.union(out) } }
        return out
    }
}

/// The brush library's pipelines, and a texture to bind where a raster slot has none.
struct BrushPipelines {
    static let rasterSlots = 16

    let tick: MTLComputePipelineState
    let replay: MTLComputePipelineState
    let bakeRaster: MTLComputePipelineState
    let overlay: MTLComputePipelineState
    let placeholder: MTLTexture

    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: ShaderSource.maskCoverage + "\n" + ShaderSource.brushCanvas, options: nil)
        func state(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
            return try device.makeComputePipelineState(function: function)
        }
        tick = try state("brush_tick")
        replay = try state("brush_replay")
        bakeRaster = try state("mask_bake_raster")
        overlay = try state("mask_overlay")
        placeholder = try GPU.makeTexture(device: device, width: 1, height: 1, usage: [.shaderRead], pixelFormat: BrushCanvas.pixelFormat)
        placeholder.label = "Brush placeholder"
        var zero = Float16(0)
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 2)
    }

    /// Binds a mask's rasters to texture slots 1 to 16, the placeholder where it has fewer.
    func bindRasters(_ textures: [MTLTexture], to encoder: MTLComputeCommandEncoder) {
        for slot in 0..<Self.rasterSlots { encoder.setTexture(slot < textures.count ? textures[slot] : placeholder, index: 1 + slot) }
    }
}

/// Strokes from the recipe laid on a canvas in one dispatch: every stroke's dabs made again by `BrushDabPath`, binned into tiles on the
/// CPU, and each texel walking its tile's list in stroke order (R8 7.4).
enum BrushReplay {
    /// Tile side in canvas texels. R8 binned 128 px tiles on a 4096 canvas; at 2048 a 64 px tile covers the same share of the picture.
    static let tile = 64

    struct Inputs {
        let dabs: [BrushDabGPU]
        let strokes: [BrushStrokeGPU]
        let offsets: [UInt32]
        let list: [UInt32]
        let tilesX: Int
    }

    /// The dabs of `strokes`, numbered from 0, and the tile lists.
    static func inputs(_ strokes: [BrushStroke], size: MaskFieldSize) -> Inputs {
        var dabs: [BrushDabGPU] = [], regions: [BrushRegion?] = [], gpuStrokes: [BrushStrokeGPU] = []
        for (index, stroke) in strokes.enumerated() {
            let profile = BrushDabProfile(radius: stroke.radius, feather: stroke.feather)
            gpuStrokes.append(BrushStrokeGPU(flow: stroke.flow, erase: stroke.erase ? 1 : 0))
            for dab in BrushDabPath.dabs(of: stroke) {
                dabs.append(BrushDabGPU(center: SIMD2(dab.x, dab.y), outer: profile.outer, inner: profile.inner, stroke: UInt32(index)))
                regions.append(BrushRegion.touched(by: dab, radius: profile.outer, size: size))
            }
        }
        let (offsets, list, tilesX) = bin(regions, size: size)
        return Inputs(dabs: dabs, strokes: gpuStrokes, offsets: offsets, list: list, tilesX: tilesX)
    }

    /// Each tile's dabs, in order: `offsets[t]..<offsets[t + 1]` of `list` are the indices of the dabs whose region meets tile t. Tiles
    /// count from the texture's row 0, the picture's bottom, as the kernels' `gid` does.
    static func bin(_ regions: [BrushRegion?], size: MaskFieldSize) -> (offsets: [UInt32], list: [UInt32], tilesX: Int) {
        let tilesX = (size.width + tile - 1) / tile, tilesY = (size.height + tile - 1) / tile
        var counts = [UInt32](repeating: 0, count: tilesX * tilesY + 1)
        func tiles(_ r: BrushRegion) -> (ClosedRange<Int>, ClosedRange<Int>) {
            let rowTop = size.height - 1 - r.y, rowBottom = size.height - r.y - r.height
            return ((r.x / tile)...((r.x + r.width - 1) / tile), (rowBottom / tile)...(rowTop / tile))
        }
        for region in regions {
            guard let region else { continue }
            let (xs, ys) = tiles(region)
            for ty in ys { for tx in xs { counts[ty * tilesX + tx + 1] += 1 } }
        }
        for i in 1..<counts.count { counts[i] += counts[i - 1] }
        var fill = counts
        var list = [UInt32](repeating: 0, count: Int(counts[counts.count - 1]))
        for (index, region) in regions.enumerated() {
            guard let region else { continue }
            let (xs, ys) = tiles(region)
            for ty in ys {
                for tx in xs {
                    list[Int(fill[ty * tilesX + tx])] = UInt32(index)
                    fill[ty * tilesX + tx] += 1
                }
            }
        }
        return (counts, list, tilesX)
    }

    /// Encodes `strokes` laid onto `base` (or onto 0) into `target`, both of `size`.
    static func encode(_ strokes: [BrushStroke], onto base: MTLTexture?, into target: MTLTexture, size: MaskFieldSize,
                       encoder: MTLComputeCommandEncoder, pipelines: BrushPipelines, device: MTLDevice) throws {
        let inputs = inputs(strokes, size: size)
        var params = BrushCanvasParams(size: size)
        params.tile = UInt32(tile)
        params.tilesX = UInt32(inputs.tilesX)
        params.hasBase = base == nil ? 0 : 1
        encoder.setComputePipelineState(pipelines.replay)
        encoder.setTexture(base ?? pipelines.placeholder, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<BrushCanvasParams>.stride, index: 0)
        try bind(inputs.dabs, index: 1, encoder: encoder, device: device)
        try bind(inputs.strokes, index: 2, encoder: encoder, device: device)
        try bind(inputs.offsets, index: 3, encoder: encoder, device: device)
        try bind(inputs.list, index: 4, encoder: encoder, device: device)
        encoder.dispatchPixels(pipelines.replay, width: size.width, height: size.height)
    }

    /// Binds `values` at `index`: inline when small, else in a buffer the command buffer keeps alive. Never empty, so a kernel's pointer
    /// is always bound.
    static func bind<T>(_ values: [T], index: Int, encoder: MTLComputeCommandEncoder, device: MTLDevice) throws {
        let length = MemoryLayout<T>.stride * values.count
        if length == 0 {
            var zero = [UInt32](repeating: 0, count: 4)
            encoder.setBytes(&zero, length: 16, index: index)
        } else if length <= 4096 {
            values.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: index) }
        } else {
            guard let buffer = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
            else { throw GPUError.textureAllocation }
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
    }
}
