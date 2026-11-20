import Metal

/// The in-house decoder's GPU half: a Bayer mosaic in a buffer to scene-linear Rec. 2020 in a
/// frame texture, with or without noise reduction.
///
/// The demosaic loads a tile of the mosaic with a margin into threadgroup memory, normalized by the
/// black and white levels and white-balanced, then interpolates green at red and blue sites by
/// Hamilton and Adams's rule (the smoother of the horizontal and vertical estimates, each corrected
/// by the site's own second difference), faded to the plain mean of the four greens where the
/// differences are no larger than the sensor's noise would make them, then red and blue from colour
/// differences against that green: the two neighbours at a green site, the four diagonals at a red
/// or blue one. Clipped highlights are rebuilt toward neutral, the colour matrix and the exposure
/// gain applied.
///
/// Without noise reduction that is one pass, writing each pixel upright in the frame textures'
/// bottom-to-top row order (Core Image's, so the frame lies as Apple's does). With it, the frame is
/// a decimated Laplacian pyramid in luminance and two colour ratios (docs/decoder.md, section 10),
/// samples far outside their neighbours pulled in first where the noise is extreme: one pass
/// demosaics and reduces straight to the half-size level, so the full-size frame is
/// never held twice; smaller passes reduce to the coarsest level and rebuild each finer one, keeping
/// of each level's detail what stands above the noise in its neighbourhood; and a last pass
/// demosaics again, keeps the full-size detail the same way, adds the rebuilt half-size level and
/// writes the frame. The pyramid's levels come from the texture pool; the full-size frame is the
/// only full-size texture.
public final class BayerDemosaic {
    /// What the kernel needs about the mosaic and the colour, laid out as `DemosaicParams` in
    /// `ShaderSource.demosaic`, field for field.
    public struct Parameters: Equatable {
        /// Samples per mosaic row.
        public var pitch: UInt32 = 0
        /// The crop's origin in the mosaic and its size, before orientation.
        public var originX: UInt32 = 0
        public var originY: UInt32 = 0
        public var width: UInt32 = 0
        public var height: UInt32 = 0
        /// The valid area: reads beyond it reflect back inside, keeping the CFA phase.
        public var limitX: UInt32 = 0
        public var limitY: UInt32 = 0
        /// Exif orientation, 1 to 8.
        public var orientation: UInt32 = 1
        /// Colour at each CFA position, `(y & 1) * 2 + (x & 1)` in mosaic coordinates.
        public var colour: (UInt32, UInt32, UInt32, UInt32) = (0, 1, 1, 2)
        /// Black level and the scale to white-balanced units, per CFA position: a sample `s` becomes
        /// `(s - black) * scale`, `scale` being the colour's white-balance gain over `white - black`.
        public var black: (Float, Float, Float, Float) = (0, 0, 0, 0)
        public var scale: (Float, Float, Float, Float) = (1, 1, 1, 1)
        /// A saturated sample in white-balanced units, per colour: the colour's gain.
        public var clip: (Float, Float, Float) = (1, 1, 1)
        /// The share of `clip` where highlight reconstruction begins to blend in.
        public var highlightStart: Float = 0.9
        /// White-balanced camera RGB to the working space, row-major, the exposure gain folded in.
        public var matrix: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (1, 0, 0, 0, 1, 0, 0, 0, 1)
        /// The variance of a white-balanced sample `v` of each colour is `noiseShot * v + noiseRead`;
        /// all zero, the demosaic is plain Hamilton-Adams.
        public var noiseShot: (Float, Float, Float) = (0, 0, 0)
        public var noiseRead: (Float, Float, Float) = (0, 0, 0)
        /// Hamilton-Adams's correction fades in as a site's differences go from `flatLow` to
        /// `flatHigh` times what noise alone would give them.
        public var flatLow: Float = 1.5
        public var flatHigh: Float = 3
        /// A sample further than this many noise deviations outside its eight same-colour
        /// neighbours' range is pulled to its edge; 0 leaves every sample alone.
        public var impulse: Float = 0
        /// The noise reduction's colour channels are red and blue less luminance `y` over
        /// `y + sqrt(liftShot * y + liftRead)` (`NoiseLevel`).
        public var liftShot: Float = 0
        public var liftRead: Float = 0
        /// The rows rendered, `rowOffset` up to `rowEnd`, of `height`; the dispatch covers them.
        public var rowOffset: Int32 = 0
        public var rowEnd: Int32 = .max
        /// 0 writes the frame upright; 1 writes rows `rowOffset` up to `rowEnd` as they lie, into a
        /// band texture whose first row is `rowOffset`, for the lens correction to resample.
        public var toBand: UInt32 = 0

        public init() {}

        public static func == (a: Parameters, b: Parameters) -> Bool {
            withUnsafeBytes(of: a) { x in withUnsafeBytes(of: b) { y in x.elementsEqual(y) } }
        }
    }

    /// One detail level's noise reduction, laid out as `NoiseLevel` in the shader. The pyramid's
    /// channels are luminance `y` and the colour ratios `(r - y) / base` and `(b - y) / base`, with
    /// `base = y + sqrt(liftShot * y + liftRead)`, a multiple of the noise added: luminance noise
    /// left in a clean pixel scales its colour rather than adding grey to it, and where the noise
    /// is as large as the signal the ratio stays bounded. A coefficient of channel `c` whose
    /// neighbourhood's mean square is `e`, where the local luminance is `y`, is kept by `1 - t / e`,
    /// at least 0, with `t = slope[c] * y + floor[c]`, over `base` squared for the colour channels:
    /// the squared threshold, the strength squared times the noise's variance there. The two
    /// colour channels share one gain, from their sums. A level keeps at least `inherit` (and
    /// `inheritColour`) times what the coarser level kept of its luminance there, so an edge,
    /// plain at the coarse levels where the noise is weak, keeps its fine detail.
    public struct NoiseLevel: Equatable {
        public var slope: (Float, Float, Float) = (0, 0, 0)
        public var floor: (Float, Float, Float) = (0, 0, 0)
        public var liftShot: Float = 0
        public var liftRead: Float = 0
        /// The share of the coarser level's luminance keep that this level keeps at least, of
        /// its luminance and its colour. 0 at the coarsest rebuilt level, whose coarser level is
        /// the reduced one and carries no keep.
        public var inherit: Float = 0
        public var inheritColour: Float = 0

        public init() {}

        public static func == (a: NoiseLevel, b: NoiseLevel) -> Bool {
            withUnsafeBytes(of: a) { x in withUnsafeBytes(of: b) { y in x.elementsEqual(y) } }
        }
    }

    /// The colour strength raised near neutral, for the rebuild kernels that take it (`ColourGain` in
    /// the shader): a level's colour strength times `1 + neutral * exp(-|c|^2 / width^2)`, `c` the
    /// coarser level's colour ratios where the coefficient lies. Apple's decoder takes nearly all the
    /// colour noise out of neutral areas and keeps more of it on coloured ones (docs/decoder.md,
    /// section 17). A decode without it runs the kernels that never had it.
    public struct ColourGain: Equatable {
        public var neutral: Float = 0
        public var width: Float = 1

        public init(neutral: Float = 0, width: Float = 1) {
            self.neutral = neutral
            self.width = width
        }
    }

    /// The lens correction's parameters for one band, laid out as `WarpParams` in the shader.
    struct WarpParameters {
        var width: UInt32 = 0
        var height: UInt32 = 0
        var orientation: UInt32 = 1
        var rowOffset: Int32 = 0
        var rowEnd: Int32 = 0
        var centreX: Float = 0
        var centreY: Float = 0
        var inverseRMax: Float = 0
        var inverseScale: Float = 1
        var count: UInt32 = 0
        var knots: (Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        /// The band's column and row of the crop's (0, 0).
        var bandX: Int32 = 0
        var bandY: Int32 = 0
        var bandWidth: UInt32 = 0
        var bandHeight: UInt32 = 0

        init(_ warp: LensWarp, orientation: UInt32) {
            width = UInt32(warp.width)
            height = UInt32(warp.height)
            self.orientation = orientation
            centreX = Float(warp.centreX)
            centreY = Float(warp.centreY)
            inverseRMax = Float(1 / warp.rMax)
            inverseScale = Float(1 / warp.scale)
            count = UInt32(min(warp.knots.count, LensWarp.maximumKnots))
            withUnsafeMutableBytes(of: &knots) { bytes in
                let k = bytes.bindMemory(to: Float.self)
                for (i, value) in warp.knots.prefix(LensWarp.maximumKnots).enumerated() { k[i] = Float(value) }
            }
        }
    }

    /// Output size for a crop of `width` by `height` under Exif `orientation`.
    public static func outputSize(width: Int, height: Int, orientation: Int) -> (width: Int, height: Int) {
        orientation >= 5 && orientation <= 8 ? (height, width) : (width, height)
    }

    /// The size of each pyramid level after the full-size one: halved, rounded up, `levels` times.
    static func pyramidSizes(width: Int, height: Int, levels: Int) -> [(width: Int, height: Int)] {
        var sizes: [(width: Int, height: Int)] = []
        var w = width, h = height
        for _ in 0..<levels {
            w = (w + 1) / 2
            h = (h + 1) / 2
            sizes.append((w, h))
        }
        return sizes
    }

    /// The kernels' tile side, `DM_TILE` in the shader.
    static let tile = 16

    private let device: MTLDevice
    private let plain: MTLComputePipelineState
    private let demosaicReduce: MTLComputePipelineState
    private let reduce: MTLComputePipelineState
    private let rebuild: MTLComputePipelineState
    private let demosaicRebuild: MTLComputePipelineState
    private let rebuildGain: MTLComputePipelineState
    private let demosaicRebuildGain: MTLComputePipelineState
    private let lensWarp: MTLComputePipelineState
    let library: MTLLibrary

    /// Compiles the kernels; call it on one thread.
    public init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: ShaderSource.demosaic, options: nil)
        self.library = library
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
            let pipeline = try device.makeComputePipelineState(function: function)
            guard pipeline.maxTotalThreadsPerThreadgroup >= Self.tile * Self.tile else {
                throw InHouseDecodeError.device("\(name) needs \(Self.tile * Self.tile) threads a threadgroup and this GPU runs \(pipeline.maxTotalThreadsPerThreadgroup)")
            }
            return pipeline
        }
        plain = try pipeline("demosaic_bayer")
        demosaicReduce = try pipeline("nr_demosaic_reduce")
        reduce = try pipeline("nr_reduce")
        rebuild = try pipeline("nr_rebuild")
        demosaicRebuild = try pipeline("nr_demosaic_rebuild")
        rebuildGain = try pipeline("nr_rebuild_gain")
        demosaicRebuildGain = try pipeline("nr_demosaic_rebuild_gain")
        lensWarp = try pipeline("lens_warp")
    }

    /// Demosaics `mosaic` into `output`, which must be `outputSize(...)` of the crop.
    public func encode(mosaic: MTLBuffer, parameters: Parameters, output: MTLTexture, into commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        var p = parameters
        encoder.setComputePipelineState(plain)
        encoder.setBuffer(mosaic, offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<Parameters>.size, index: 1)
        encoder.setTexture(output, index: 0)
        encoder.dispatchThreadgroups(Self.groups(Int(p.width), Int(p.height)), threadsPerThreadgroup: Self.threads)
        encoder.endEncoding()
    }

    /// Demosaics `mosaic` into `output` with noise reduction: `levels` holds one entry per detail
    /// level from the full-size one, so the pyramid has `levels.count` reduced levels. The
    /// pyramid's textures come from `pool` and are returned; hold them until the command buffer
    /// has completed.
    public func encode(mosaic: MTLBuffer, parameters: Parameters, levels: [NoiseLevel], colourGain: ColourGain? = nil,
                       output: MTLTexture, pool: TexturePool, into commandBuffer: MTLCommandBuffer) throws -> [PooledTexture] {
        let pyramid = try Pyramid(parameters: parameters, levels: levels, pool: pool)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        encodePyramid(pyramid, mosaic: mosaic, parameters: parameters, levels: levels, gain: colourGain, encoder: encoder)
        encodeLast(pyramid, mosaic: mosaic, parameters: parameters, level: levels[0], gain: colourGain, output: output, encoder: encoder)
        encoder.endEncoding()
        return pyramid.textures
    }

    /// Demosaics `mosaic`, with noise reduction when `levels` is given, and corrects the lens's
    /// distortion by `warp` into `output`, `outputSize` of the warp's crop under the parameters'
    /// orientation. `parameters` describe the region rendered, the crop widened by `margin` on each
    /// side, which the warp's reads stay inside. The region is rendered a band of rows at a time, the
    /// uncorrected rows the warp's `bandRows` corrected rows read, into one band texture from `pool`,
    /// and each band resampled into the frame upright, so no second full-size frame is held. Returns
    /// the textures to hold until the command buffer has completed.
    public func encode(mosaic: MTLBuffer, parameters: Parameters, levels: [NoiseLevel]?, colourGain: ColourGain? = nil,
                       warp: LensWarp, margin: (x: Int, y: Int), output: MTLTexture, pool: TexturePool,
                       into commandBuffer: MTLCommandBuffer) throws -> [PooledTexture] {
        let regionHeight = Int(parameters.height)
        var bands: [(rows: Range<Int>, region: Range<Int>)] = []
        for top in stride(from: 0, to: warp.height, by: max(1, warp.bandRows)) {
            let rows = top..<min(warp.height, top + max(1, warp.bandRows))
            let source = warp.sourceRows(rows)
            let low = min(max(source.lowerBound + margin.y, 0), regionHeight - 1)
            let high = max(min(source.upperBound + margin.y, regionHeight), low + 1)
            bands.append((rows, low..<high))
        }
        let band = try pool.acquire(width: Int(parameters.width), height: bands.map(\.region.count).max() ?? 1)
        let pyramid = try levels.map { try Pyramid(parameters: parameters, levels: $0, pool: pool) }
        let held = [band] + (pyramid?.textures ?? [])
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        if let pyramid, let levels {
            encodePyramid(pyramid, mosaic: mosaic, parameters: parameters, levels: levels, gain: colourGain, encoder: encoder)
        }
        var w = WarpParameters(warp, orientation: parameters.orientation)
        w.bandX = Int32(margin.x)
        w.bandWidth = UInt32(band.width)
        w.bandHeight = UInt32(band.height)
        for (rows, region) in bands {
            var p = parameters
            p.rowOffset = Int32(region.lowerBound)
            p.rowEnd = Int32(region.upperBound)
            p.toBand = 1
            if let pyramid, let levels {
                encodeLast(pyramid, mosaic: mosaic, parameters: p, level: levels[0], gain: colourGain, output: band.texture, encoder: encoder)
            } else {
                encoder.setComputePipelineState(plain)
                encoder.setBuffer(mosaic, offset: 0, index: 0)
                encoder.setBytes(&p, length: MemoryLayout<Parameters>.size, index: 1)
                encoder.setTexture(band.texture, index: 0)
                encoder.dispatchThreadgroups(Self.groups(Int(p.width), region.count), threadsPerThreadgroup: Self.threads)
            }
            w.rowOffset = Int32(rows.lowerBound)
            w.rowEnd = Int32(rows.upperBound)
            w.bandY = Int32(margin.y - region.lowerBound)
            encoder.setComputePipelineState(lensWarp)
            encoder.setTexture(band.texture, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&w, length: MemoryLayout<WarpParameters>.size, index: 0)
            encoder.dispatchPixels(lensWarp, width: warp.width, height: rows.count)
        }
        encoder.endEncoding()
        return held
    }

    /// The noise reduction's pyramid levels for a region, each as reduced and then as rebuilt; the
    /// coarsest is its own rebuild.
    struct Pyramid {
        var sizes: [(width: Int, height: Int)]
        var reduced: [PooledTexture]
        var rebuilt: [PooledTexture]
        var textures: [PooledTexture] { reduced + rebuilt }

        init(parameters: Parameters, levels: [NoiseLevel], pool: TexturePool) throws {
            precondition(!levels.isEmpty, "noise reduction needs at least one level")
            sizes = BayerDemosaic.pyramidSizes(width: Int(parameters.width), height: Int(parameters.height), levels: levels.count)
            reduced = try sizes.map { try pool.acquire(width: $0.width, height: $0.height) }
            rebuilt = try sizes.dropLast().map { try pool.acquire(width: $0.width, height: $0.height) }
        }
    }

    /// Everything but the last pass: the region demosaiced and reduced, and every level rebuilt
    /// down to the half-size one.
    private func encodePyramid(_ pyramid: Pyramid, mosaic: MTLBuffer, parameters: Parameters, levels: [NoiseLevel],
                               gain: ColourGain?, encoder: MTLComputeCommandEncoder) {
        let sizes = pyramid.sizes, reduced = pyramid.reduced, rebuilt = pyramid.rebuilt
        var p = parameters

        encoder.setComputePipelineState(demosaicReduce)
        encoder.setBuffer(mosaic, offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<Parameters>.size, index: 1)
        encoder.setTexture(reduced[0].texture, index: 0)
        encoder.dispatchThreadgroups(Self.groups(sizes[0].width, sizes[0].height), threadsPerThreadgroup: Self.threads)

        encoder.setComputePipelineState(reduce)
        for l in 1..<sizes.count {
            encoder.setTexture(reduced[l - 1].texture, index: 0)
            encoder.setTexture(reduced[l].texture, index: 1)
            encoder.dispatchPixels(reduce, width: sizes[l].width, height: sizes[l].height)
        }

        var colourGain = gain ?? ColourGain()
        encoder.setComputePipelineState(gain == nil ? rebuild : rebuildGain)
        if gain != nil { encoder.setBytes(&colourGain, length: MemoryLayout<ColourGain>.size, index: 1) }
        for l in stride(from: sizes.count - 1, through: 1, by: -1) {
            var level = levels[l]
            encoder.setTexture(reduced[l - 1].texture, index: 0)
            encoder.setTexture(reduced[l].texture, index: 1)
            encoder.setTexture(l == sizes.count - 1 ? reduced[l].texture : rebuilt[l].texture, index: 2)
            encoder.setTexture(rebuilt[l - 1].texture, index: 3)
            encoder.setBytes(&level, length: MemoryLayout<NoiseLevel>.size, index: 0)
            encoder.dispatchThreadgroups(Self.groups(sizes[l - 1].width, sizes[l - 1].height), threadsPerThreadgroup: Self.threads)
        }
    }

    /// The last pass: demosaics again, keeps the full-size detail and writes the frame upright, or
    /// the parameters' rows into a band.
    private func encodeLast(_ pyramid: Pyramid, mosaic: MTLBuffer, parameters: Parameters, level: NoiseLevel,
                            gain: ColourGain?, output: MTLTexture, encoder: MTLComputeCommandEncoder) {
        var p = parameters, finest = level, colourGain = gain ?? ColourGain()
        let rows = p.toBand != 0 ? Int(p.rowEnd - p.rowOffset) : Int(p.height)
        encoder.setComputePipelineState(gain == nil ? demosaicRebuild : demosaicRebuildGain)
        encoder.setBuffer(mosaic, offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<Parameters>.size, index: 1)
        encoder.setBytes(&finest, length: MemoryLayout<NoiseLevel>.size, index: 2)
        if gain != nil { encoder.setBytes(&colourGain, length: MemoryLayout<ColourGain>.size, index: 3) }
        encoder.setTexture(pyramid.reduced[0].texture, index: 0)
        encoder.setTexture(pyramid.sizes.count == 1 ? pyramid.reduced[0].texture : pyramid.rebuilt[0].texture, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.dispatchThreadgroups(Self.groups(Int(p.width), rows), threadsPerThreadgroup: Self.threads)
    }

    private static let threads = MTLSize(width: tile, height: tile, depth: 1)

    private static func groups(_ width: Int, _ height: Int) -> MTLSize {
        MTLSize(width: (width + tile - 1) / tile, height: (height + tile - 1) / tile, depth: 1)
    }
}

extension ShaderSource {
    static let demosaic = """
    #include <metal_stdlib>
    using namespace metal;

    struct DemosaicParams {
        uint  pitch;
        uint  originX;
        uint  originY;
        uint  width;
        uint  height;
        uint  limitX;
        uint  limitY;
        uint  orientation;
        uint  colour[4];
        float black[4];
        float scale[4];
        float clip[3];
        float highlightStart;
        float matrix[9];
        float noiseShot[3];
        float noiseRead[3];
        float flatLow;
        float flatHigh;
        float impulse;
        float liftShot;
        float liftRead;
        int   rowOffset;
        int   rowEnd;
        uint  toBand;
    };

    struct NoiseLevel {
        float slope[3];
        float floor[3];
        float liftShot;
        float liftRead;
        float inherit;
        float inheritColour;
    };

    #define DM_TILE 16
    #define DM_THREADS (DM_TILE * DM_TILE)

    // Reflects about 0 and limit - 1, which keeps the CFA phase of the coordinate.
    static inline int dm_reflect(int v, int limit) {
        if (v < 0) { v = -v; }
        if (v >= limit) { v = 2 * (limit - 1) - v; }
        return clamp(v, 0, limit - 1);
    }

    // Where the crop's pixel (x, y), counted from the top left, goes in a frame turned upright
    // (Exif orientation), counted from the top left.
    static inline int2 dm_oriented(int x, int y, int w, int h, uint orientation) {
        switch (orientation) {
            case 2: return int2(w - 1 - x, y);
            case 3: return int2(w - 1 - x, h - 1 - y);
            case 4: return int2(x, h - 1 - y);
            case 5: return int2(y, x);
            case 6: return int2(h - 1 - y, x);
            case 7: return int2(h - 1 - y, w - 1 - x);
            case 8: return int2(y, w - 1 - x);
            default: return int2(x, y);
        }
    }

    // The mosaic from (mx0, my0), rw by rh samples, into raw: black-subtracted, scaled to the white
    // level and white-balanced. With impulse above 0, a sample further than that many noise
    // deviations outside the range of its eight same-colour neighbours is pulled to the range's
    // edge: a hot or dead pixel, or noise's far tail, which the demosaic would spread into a speck.
    static void dm_load(device const ushort* mosaic, constant DemosaicParams& p, threadgroup float* raw,
                        int mx0, int my0, int rw, int rh, uint index) {
        for (uint i = index; i < uint(rw * rh); i += DM_THREADS) {
            int mx = dm_reflect(mx0 + int(i % uint(rw)), int(p.limitX));
            int my = dm_reflect(my0 + int(i / uint(rw)), int(p.limitY));
            uint k = uint((my & 1) * 2 + (mx & 1));
            float v = (float(mosaic[my * int(p.pitch) + mx]) - p.black[k]) * p.scale[k];
            if (p.impulse > 0.0f) {
                float lo = INFINITY, hi = -INFINITY;
                for (int dy = -2; dy <= 2; dy += 2) {
                    for (int dx = -2; dx <= 2; dx += 2) {
                        if (dx == 0 && dy == 0) { continue; }
                        int nx = dm_reflect(mx + dx, int(p.limitX)), ny = dm_reflect(my + dy, int(p.limitY));
                        float n = (float(mosaic[ny * int(p.pitch) + nx]) - p.black[k]) * p.scale[k];
                        lo = min(lo, n);
                        hi = max(hi, n);
                    }
                }
                uint c = p.colour[k];
                float above = p.impulse * sqrt(p.noiseShot[c] * max(hi, 0.0f) + p.noiseRead[c]);
                float below = p.impulse * sqrt(p.noiseShot[c] * max(lo, 0.0f) + p.noiseRead[c]);
                v = v > hi + above ? hi : (v < lo - below ? lo : v);
            }
            raw[i] = v;
        }
    }

    // Green for the raw tile less two samples on every side, gw by gh: the sample itself at a
    // green site, Hamilton-Adams at red and blue, faded to the mean of the four greens where the
    // site's differences are no larger than the noise would make them.
    static void dm_green(constant DemosaicParams& p, threadgroup const float* raw, threadgroup float* green,
                         int mx0, int my0, int rw, int gw, int gh, uint index) {
        for (uint i = index; i < uint(gw * gh); i += DM_THREADS) {
            int rx = int(i % uint(gw)) + 2, ry = int(i / uint(gw)) + 2;
            int at = ry * rw + rx;
            float c = raw[at];
            uint colour = p.colour[uint(((my0 + ry) & 1) * 2 + ((mx0 + rx) & 1))];
            float g = c;
            if (colour != 1) {
                float gl = raw[at - 1], gr = raw[at + 1], gu = raw[at - rw], gd = raw[at + rw];
                float l2 = raw[at - 2], r2 = raw[at + 2], u2 = raw[at - 2 * rw], d2 = raw[at + 2 * rw];
                float lh = 2.0f * c - l2 - r2;
                float lv = 2.0f * c - u2 - d2;
                float dh = fabs(gl - gr) + fabs(lh), dv = fabs(gu - gd) + fabs(lv);
                float gh = 0.5f * (gl + gr) + 0.25f * lh, gv = 0.5f * (gu + gd) + 0.25f * lv;
                g = dh < dv ? gh : (dv < dh ? gv : 0.5f * (gh + gv));
                // What |gl - gr| + |lh| averages from noise alone: E|N(0, s^2)| is 0.798 s, a green
                // difference has twice a green's variance and lh six times the site colour's.
                float flat = 0.25f * (gl + gr + gu + gd);
                float local = 0.2f * (c + l2 + r2 + u2 + d2);
                float vg = p.noiseShot[1] * max(flat, 0.0f) + p.noiseRead[1];
                float vc = p.noiseShot[colour] * max(local, 0.0f) + p.noiseRead[colour];
                float expected = 0.798f * (sqrt(2.0f * vg) + sqrt(6.0f * vc));
                if (expected > 0.0f) {
                    float w = smoothstep(p.flatLow, p.flatHigh, 0.5f * (dh + dv) / expected);
                    g = w >= 1.0f ? g : mix(flat, g, w);
                }
            }
            green[i] = g;
        }
    }

    // Camera RGB at raw index at (green index gat), mosaic position (mx, my): red and blue from
    // colour differences against green.
    static float3 dm_rgb(constant DemosaicParams& p, threadgroup const float* raw, threadgroup const float* green,
                         int at, int rw, int gat, int gw, int mx, int my) {
        uint colour = p.colour[uint((my & 1) * 2 + (mx & 1))];
        float G = green[gat];
        if (colour == 1) {
            float h = 0.5f * ((raw[at - 1] - green[gat - 1]) + (raw[at + 1] - green[gat + 1]));
            float v = 0.5f * ((raw[at - rw] - green[gat - gw]) + (raw[at + rw] - green[gat + gw]));
            uint across = p.colour[uint((my & 1) * 2 + ((mx + 1) & 1))];
            return across == 0 ? float3(G + h, G, G + v) : float3(G + v, G, G + h);
        }
        float diagonal = 0.25f * ((raw[at - rw - 1] - green[gat - gw - 1]) + (raw[at - rw + 1] - green[gat - gw + 1])
                                + (raw[at + rw - 1] - green[gat + gw - 1]) + (raw[at + rw + 1] - green[gat + gw + 1]));
        float own = raw[at];
        return colour == 0 ? float3(own, G, G + diagonal) : float3(G + diagonal, G, own);
    }

    // A channel near its clip is raised toward the brightest channel, so a clipped highlight
    // goes neutral and keeps rising until the last channel clips, as Apple's highlight
    // recovery does; below highlightStart of its clip a channel is untouched. Then the matrix.
    static float3 dm_finish(constant DemosaicParams& p, float3 rgb) {
        float3 clip = float3(p.clip[0], p.clip[1], p.clip[2]);
        float brightest = max(rgb.r, max(rgb.g, rgb.b));
        float3 near = saturate((rgb / clip - p.highlightStart) / (1.0f - p.highlightStart));
        rgb += near * max(brightest - rgb, 0.0f);
        return float3(p.matrix[0] * rgb.r + p.matrix[1] * rgb.g + p.matrix[2] * rgb.b,
                      p.matrix[3] * rgb.r + p.matrix[4] * rgb.g + p.matrix[5] * rgb.b,
                      p.matrix[6] * rgb.r + p.matrix[7] * rgb.g + p.matrix[8] * rgb.b);
    }

    // Frame textures run bottom to top, as Core Image renders them: the first row is the
    // picture's bottom.
    static void dm_write(constant DemosaicParams& p, texture2d<half, access::write> out, float3 o, int x, int y) {
        int2 upright = dm_oriented(x, y, int(p.width), int(p.height), p.orientation);
        out.write(half4(half3(o), 1.0h), uint2(upright.x, int(out.get_height()) - 1 - upright.y));
    }

    // The frame upright, or a band of rows as they lie, top down, for the lens correction.
    static void dm_store(constant DemosaicParams& p, texture2d<half, access::write> out, float3 o, int x, int y) {
        if (p.toBand != 0) {
            out.write(half4(half3(o), 1.0h), uint2(x, y - p.rowOffset));
        } else {
            dm_write(p, out, o, x, y);
        }
    }

    #define DM_RAW (DM_TILE + 6)
    #define DM_GREEN (DM_TILE + 2)

    kernel void demosaic_bayer(device const ushort* mosaic [[buffer(0)]],
                               constant DemosaicParams& p [[buffer(1)]],
                               texture2d<half, access::write> out [[texture(0)]],
                               uint2 lid [[thread_position_in_threadgroup]],
                               uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float raw[DM_RAW * DM_RAW];
        threadgroup float green[DM_GREEN * DM_GREEN];
        const int x0 = int(group.x) * DM_TILE, y0 = int(group.y) * DM_TILE + p.rowOffset;
        // Mosaic coordinates of the raw tile's top-left sample, three outside the output tile.
        const int mx0 = int(p.originX) + x0 - 3, my0 = int(p.originY) + y0 - 3;
        const uint index = lid.y * DM_TILE + lid.x;
        dm_load(mosaic, p, raw, mx0, my0, DM_RAW, DM_RAW, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        dm_green(p, raw, green, mx0, my0, DM_RAW, DM_GREEN, DM_GREEN, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);

        const int x = x0 + int(lid.x), y = y0 + int(lid.y);
        if (x >= int(p.width) || y >= min(int(p.height), p.rowEnd)) { return; }
        const int at = (int(lid.y) + 3) * DM_RAW + int(lid.x) + 3;
        const int gat = (int(lid.y) + 1) * DM_GREEN + int(lid.x) + 1;
        float3 rgb = dm_rgb(p, raw, green, at, DM_RAW, gat, DM_GREEN, mx0 + int(lid.x) + 3, my0 + int(lid.y) + 3);
        dm_store(p, out, dm_finish(p, rgb), x, y);
    }

    // The pyramid works on luminance and red and blue less it over it, lifted by a multiple of
    // the noise there: luminance noise left in a clean pixel then scales its colour instead of
    // adding grey, and where the noise is as large as the signal the ratio stays bounded.
    constant float3 NR_LUMA = float3(0.2627f, 0.6780f, 0.0593f);

    static inline float nr_base(float y, float liftShot, float liftRead) {
        float lum = max(y, 0.0f);
        return max(lum + sqrt(liftShot * lum + liftRead), 1e-4f);
    }

    static inline float3 nr_opponent(float3 c, constant DemosaicParams& p) {
        float y = dot(NR_LUMA, c), d = nr_base(y, p.liftShot, p.liftRead);
        return float3(y, (c.r - y) / d, (c.b - y) / d);
    }

    static inline float3 nr_rgb(float3 o, constant DemosaicParams& p) {
        float d = nr_base(o.x, p.liftShot, p.liftRead);
        float r = o.x + o.y * d, b = o.x + o.z * d;
        return float3(r, (o.x - NR_LUMA.r * r - NR_LUMA.b * b) / NR_LUMA.g, b);
    }

    // floor(v / 2) for negative v too.
    static inline int nr_half(int v) { return v >= 0 ? v / 2 : -((1 - v) / 2); }

    // The coarse level expanded to fine position f along one axis, as three taps from coarse
    // index base: the binomial 1 4 6 4 1 filter, doubled, on the coarse samples spread apart.
    static inline void nr_taps(int f, thread int& base, thread float3& w) {
        int k = nr_half(f);
        if ((f & 1) == 0) { base = k - 1; w = float3(0.125f, 0.75f, 0.125f); }
        else { base = k; w = float3(0.5f, 0.5f, 0.0f); }
    }

    // The coarse tile (cx0, cy0), cw wide, expanded to fine position (fx, fy).
    template <typename T>
    static T nr_expand(threadgroup const T* coarse, int cw, int cx0, int cy0, int fx, int fy) {
        int bx, by;
        float3 wx, wy;
        nr_taps(fx, bx, wx);
        nr_taps(fy, by, wy);
        T sum = T(0.0f);
        for (int j = 0; j < 3; j++) {
            int row = (by + j - cy0) * cw + bx - cx0;
            sum += wy[j] * (wx[0] * coarse[row] + wx[1] * coarse[row + 1] + wx[2] * coarse[row + 2]);
        }
        return sum;
    }

    // How much of a coefficient to keep, for luminance and for colour: what stands above the
    // noise. neighbourhood is the mean square of its eight neighbours, itself left out so that a
    // lone outlier, which noise's tails and hot pixels make, does not vouch for itself; y is the
    // local luminance. parent is what the coarser level kept of its luminance here: structure such
    // as an edge stands far above the noise at the coarser levels, so where the coarser level was
    // sure (kept from three quarters up, which noise alone reaches about once in a thousand) a
    // share of that is kept whatever this level's own neighbourhood says.
    // Returns the luminance and colour keeps, and in z the luminance keep from this level's own
    // neighbourhood alone, which the next finer level reads as its parent: the evidence does not
    // chain down the levels, since at the coarsest ones nearly everything stands above the noise.
    static float3 nr_keep(float3 neighbourhood, float y, float parent, constant NoiseLevel& n) {
        float lum = max(y, 0.0f), base = nr_base(y, n.liftShot, n.liftRead);
        float3 t = float3(n.slope[0], n.slope[1], n.slope[2]) * lum + float3(n.floor[0], n.floor[1], n.floor[2]);
        t.yz /= base * base;
        float keepY = max(0.0f, 1.0f - t.x / max(neighbourhood.x, 1e-20f));
        float keepC = max(0.0f, 1.0f - (t.y + t.z) / max(neighbourhood.y + neighbourhood.z, 1e-20f));
        float2 inherited = smoothstep(0.75f, 1.0f, parent) * float2(n.inherit, n.inheritColour);
        return float3(max(float2(keepY, keepC), inherited), keepY);
    }

    // The coarse tile a 16-pixel fine tile and its one-pixel ring need: from floor((x0 - 1) / 2) - 1,
    // twelve wide.
    #define NR_COARSE 12
    #define NR_RING (DM_TILE + 2)

    static void nr_load_coarse(texture2d<half, access::read> level, threadgroup float3* coarse,
                               int cx0, int cy0, uint index) {
        int w = int(level.get_width()), h = int(level.get_height());
        for (uint i = index; i < NR_COARSE * NR_COARSE; i += DM_THREADS) {
            int x = clamp(cx0 + int(i % NR_COARSE), 0, w - 1), y = clamp(cy0 + int(i / NR_COARSE), 0, h - 1);
            coarse[i] = float3(level.read(uint2(x, y)).rgb);
        }
    }

    // The same with the fourth channel, which in a rebuilt level is what it kept of its luminance.
    static void nr_load_coarse(texture2d<half, access::read> level, threadgroup float4* coarse,
                               int cx0, int cy0, uint index) {
        int w = int(level.get_width()), h = int(level.get_height());
        for (uint i = index; i < NR_COARSE * NR_COARSE; i += DM_THREADS) {
            int x = clamp(cx0 + int(i % NR_COARSE), 0, w - 1), y = clamp(cy0 + int(i / NR_COARSE), 0, h - 1);
            coarse[i] = float4(level.read(uint2(x, y)));
        }
    }

    // The full-size frame demosaiced and reduced straight to the half-size level: each group
    // demosaics the 36 by 36 pixels its 16 by 16 reduced pixels draw on, in the working space,
    // and reduces them with the binomial 1 4 6 4 1 filter at stride 2. Pixel i of the reduced
    // level sits on pixel 2i of the full-size one.
    #define NR_SPAN (2 * DM_TILE + 4)
    #define NR_SPAN_GREEN (NR_SPAN + 2)
    #define NR_SPAN_RAW (NR_SPAN + 6)

    kernel void nr_demosaic_reduce(device const ushort* mosaic [[buffer(0)]],
                                   constant DemosaicParams& p [[buffer(1)]],
                                   texture2d<half, access::write> reduced [[texture(0)]],
                                   uint2 lid [[thread_position_in_threadgroup]],
                                   uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float raw[NR_SPAN_RAW * NR_SPAN_RAW];
        threadgroup float green[NR_SPAN_GREEN * NR_SPAN_GREEN];
        threadgroup half3 frame[NR_SPAN * NR_SPAN];
        const uint index = lid.y * DM_TILE + lid.x;
        // The full-size pixels drawn on start two before the first reduced pixel's.
        const int fx0 = 2 * int(group.x) * DM_TILE - 2, fy0 = 2 * int(group.y) * DM_TILE - 2;
        const int mx0 = int(p.originX) + fx0 - 3, my0 = int(p.originY) + fy0 - 3;
        dm_load(mosaic, p, raw, mx0, my0, NR_SPAN_RAW, NR_SPAN_RAW, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        dm_green(p, raw, green, mx0, my0, NR_SPAN_RAW, NR_SPAN_GREEN, NR_SPAN_GREEN, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = index; i < NR_SPAN * NR_SPAN; i += DM_THREADS) {
            int fx = int(i % NR_SPAN), fy = int(i / NR_SPAN);
            int at = (fy + 3) * NR_SPAN_RAW + fx + 3, gat = (fy + 1) * NR_SPAN_GREEN + fx + 1;
            float3 rgb = dm_rgb(p, raw, green, at, NR_SPAN_RAW, gat, NR_SPAN_GREEN, mx0 + fx + 3, my0 + fy + 3);
            frame[i] = half3(nr_opponent(dm_finish(p, rgb), p));
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        const int cx = int(group.x) * DM_TILE + int(lid.x), cy = int(group.y) * DM_TILE + int(lid.y);
        if (cx >= int(reduced.get_width()) || cy >= int(reduced.get_height())) { return; }
        const float k[5] = {0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f};
        float3 sum = 0.0f;
        for (int v = 0; v < 5; v++) {
            int row = (2 * int(lid.y) + v) * NR_SPAN + 2 * int(lid.x);
            float3 across = 0.0f;
            for (int u = 0; u < 5; u++) { across += k[u] * float3(frame[row + u]); }
            sum += k[v] * across;
        }
        reduced.write(half4(half3(sum), 1.0h), uint2(cx, cy));
    }

    // One level reduced to the next: the binomial filter at stride 2, edges repeated.
    kernel void nr_reduce(texture2d<half, access::read> fine [[texture(0)]],
                          texture2d<half, access::write> coarse [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= coarse.get_width() || gid.y >= coarse.get_height()) { return; }
        const int w = int(fine.get_width()), h = int(fine.get_height());
        const float k[5] = {0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f};
        float3 sum = 0.0f;
        for (int v = 0; v < 5; v++) {
            int y = clamp(2 * int(gid.y) + v - 2, 0, h - 1);
            float3 across = 0.0f;
            for (int u = 0; u < 5; u++) {
                across += k[u] * float3(fine.read(uint2(clamp(2 * int(gid.x) + u - 2, 0, w - 1), y)).rgb);
            }
            sum += k[v] * across;
        }
        coarse.write(half4(half3(sum), 1.0h), gid);
    }

    // One level rebuilt: the rebuilt coarser level expanded, plus what this level's detail keeps.
    kernel void nr_rebuild(texture2d<half, access::read> level [[texture(0)]],
                           texture2d<half, access::read> coarse [[texture(1)]],
                           texture2d<half, access::read> coarseRebuilt [[texture(2)]],
                           texture2d<half, access::write> out [[texture(3)]],
                           constant NoiseLevel& n [[buffer(0)]],
                           uint2 lid [[thread_position_in_threadgroup]],
                           uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float3 cG[NR_COARSE * NR_COARSE];
        threadgroup float4 cR[NR_COARSE * NR_COARSE];
        threadgroup float3 detail[NR_RING * NR_RING];
        const uint index = lid.y * DM_TILE + lid.x;
        const int x0 = int(group.x) * DM_TILE, y0 = int(group.y) * DM_TILE;
        const int cx0 = nr_half(x0 - 1) - 1, cy0 = nr_half(y0 - 1) - 1;
        nr_load_coarse(coarse, cG, cx0, cy0, index);
        nr_load_coarse(coarseRebuilt, cR, cx0, cy0, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const int w = int(level.get_width()), h = int(level.get_height());
        for (uint i = index; i < NR_RING * NR_RING; i += DM_THREADS) {
            int fx = x0 - 1 + int(i % NR_RING), fy = y0 - 1 + int(i / NR_RING);
            float3 g = float3(level.read(uint2(clamp(fx, 0, w - 1), clamp(fy, 0, h - 1))).rgb);
            detail[i] = g - nr_expand(cG, NR_COARSE, cx0, cy0, fx, fy);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        const int x = x0 + int(lid.x), y = y0 + int(lid.y);
        if (x >= w || y >= h) { return; }
        float3 squares = 0.0f;
        for (int j = 0; j < 3; j++) {
            for (int i = 0; i < 3; i++) {
                float3 d = detail[(int(lid.y) + j) * NR_RING + int(lid.x) + i];
                squares += d * d;
            }
        }
        float3 d = detail[(int(lid.y) + 1) * NR_RING + int(lid.x) + 1];
        squares -= d * d;
        float y_local = nr_expand(cG, NR_COARSE, cx0, cy0, x, y).x;
        float4 base = nr_expand(cR, NR_COARSE, cx0, cy0, x, y);
        float3 keep = nr_keep(squares / 8.0f, y_local, base.w, n);
        out.write(half4(half3(base.xyz + d * float3(keep.x, keep.y, keep.y)), half(keep.z)), uint2(x, y));
    }

    // The last pass: demosaics the tile and its one-pixel ring again, keeps of the full-size detail
    // what stands above the noise, adds the rebuilt half-size level and writes the pixel upright.
    #define NR_RING_GREEN (NR_RING + 2)
    #define NR_RING_RAW (NR_RING + 6)

    kernel void nr_demosaic_rebuild(device const ushort* mosaic [[buffer(0)]],
                                    constant DemosaicParams& p [[buffer(1)]],
                                    constant NoiseLevel& n [[buffer(2)]],
                                    texture2d<half, access::read> coarse [[texture(0)]],
                                    texture2d<half, access::read> coarseRebuilt [[texture(1)]],
                                    texture2d<half, access::write> out [[texture(2)]],
                                    uint2 lid [[thread_position_in_threadgroup]],
                                    uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float raw[NR_RING_RAW * NR_RING_RAW];
        threadgroup float green[NR_RING_GREEN * NR_RING_GREEN];
        threadgroup float3 cG[NR_COARSE * NR_COARSE];
        threadgroup float4 cR[NR_COARSE * NR_COARSE];
        threadgroup float3 detail[NR_RING * NR_RING];
        const uint index = lid.y * DM_TILE + lid.x;
        const int x0 = int(group.x) * DM_TILE, y0 = int(group.y) * DM_TILE + p.rowOffset;
        const int mx0 = int(p.originX) + x0 - 4, my0 = int(p.originY) + y0 - 4;
        const int cx0 = nr_half(x0 - 1) - 1, cy0 = nr_half(y0 - 1) - 1;
        dm_load(mosaic, p, raw, mx0, my0, NR_RING_RAW, NR_RING_RAW, index);
        nr_load_coarse(coarse, cG, cx0, cy0, index);
        nr_load_coarse(coarseRebuilt, cR, cx0, cy0, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        dm_green(p, raw, green, mx0, my0, NR_RING_RAW, NR_RING_GREEN, NR_RING_GREEN, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = index; i < NR_RING * NR_RING; i += DM_THREADS) {
            int rx = int(i % NR_RING), ry = int(i / NR_RING);
            int at = (ry + 3) * NR_RING_RAW + rx + 3, gat = (ry + 1) * NR_RING_GREEN + rx + 1;
            float3 rgb = dm_rgb(p, raw, green, at, NR_RING_RAW, gat, NR_RING_GREEN, mx0 + rx + 3, my0 + ry + 3);
            detail[i] = nr_opponent(dm_finish(p, rgb), p) - nr_expand(cG, NR_COARSE, cx0, cy0, x0 - 1 + rx, y0 - 1 + ry);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        const int x = x0 + int(lid.x), y = y0 + int(lid.y);
        if (x >= int(p.width) || y >= min(int(p.height), p.rowEnd)) { return; }
        float3 squares = 0.0f;
        for (int j = 0; j < 3; j++) {
            for (int i = 0; i < 3; i++) {
                float3 d = detail[(int(lid.y) + j) * NR_RING + int(lid.x) + i];
                squares += d * d;
            }
        }
        float3 d = detail[(int(lid.y) + 1) * NR_RING + int(lid.x) + 1];
        squares -= d * d;
        float y_local = nr_expand(cG, NR_COARSE, cx0, cy0, x, y).x;
        float4 base = nr_expand(cR, NR_COARSE, cx0, cy0, x, y);
        float3 keep = nr_keep(squares / 8.0f, y_local, base.w, n);
        dm_store(p, out, nr_rgb(base.xyz + d * float3(keep.x, keep.y, keep.y), p), x, y);
    }

    // The rebuild kernels again with the colour strength raised near neutral (ColourGain): Apple's
    // decoder takes nearly all the colour noise out of neutral areas and keeps more of it on coloured
    // ones. Kept apart from nr_rebuild and nr_demosaic_rebuild, which stay the code they were, so a
    // decode without the gain gives the pixels it always gave.
    struct ColourGain {
        float neutral;
        float width;
    };

    static float3 nr_keep_gain(float3 neighbourhood, float y, float parent, float2 colour, constant NoiseLevel& n,
                               constant ColourGain& g) {
        float lum = max(y, 0.0f), base = nr_base(y, n.liftShot, n.liftRead);
        float3 t = float3(n.slope[0], n.slope[1], n.slope[2]) * lum + float3(n.floor[0], n.floor[1], n.floor[2]);
        float gain = 1.0f + g.neutral * exp(-dot(colour, colour) / (g.width * g.width));
        t.yz *= gain * gain / (base * base);
        float keepY = max(0.0f, 1.0f - t.x / max(neighbourhood.x, 1e-20f));
        float keepC = max(0.0f, 1.0f - (t.y + t.z) / max(neighbourhood.y + neighbourhood.z, 1e-20f));
        float2 inherited = smoothstep(0.75f, 1.0f, parent) * float2(n.inherit, n.inheritColour);
        return float3(max(float2(keepY, keepC), inherited), keepY);
    }

    kernel void nr_rebuild_gain(texture2d<half, access::read> level [[texture(0)]],
                                texture2d<half, access::read> coarse [[texture(1)]],
                                texture2d<half, access::read> coarseRebuilt [[texture(2)]],
                                texture2d<half, access::write> out [[texture(3)]],
                                constant NoiseLevel& n [[buffer(0)]],
                                constant ColourGain& g [[buffer(1)]],
                                uint2 lid [[thread_position_in_threadgroup]],
                                uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float3 cG[NR_COARSE * NR_COARSE];
        threadgroup float4 cR[NR_COARSE * NR_COARSE];
        threadgroup float3 detail[NR_RING * NR_RING];
        const uint index = lid.y * DM_TILE + lid.x;
        const int x0 = int(group.x) * DM_TILE, y0 = int(group.y) * DM_TILE;
        const int cx0 = nr_half(x0 - 1) - 1, cy0 = nr_half(y0 - 1) - 1;
        nr_load_coarse(coarse, cG, cx0, cy0, index);
        nr_load_coarse(coarseRebuilt, cR, cx0, cy0, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const int w = int(level.get_width()), h = int(level.get_height());
        for (uint i = index; i < NR_RING * NR_RING; i += DM_THREADS) {
            int fx = x0 - 1 + int(i % NR_RING), fy = y0 - 1 + int(i / NR_RING);
            float3 c = float3(level.read(uint2(clamp(fx, 0, w - 1), clamp(fy, 0, h - 1))).rgb);
            detail[i] = c - nr_expand(cG, NR_COARSE, cx0, cy0, fx, fy);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        const int x = x0 + int(lid.x), y = y0 + int(lid.y);
        if (x >= w || y >= h) { return; }
        float3 squares = 0.0f;
        for (int j = 0; j < 3; j++) {
            for (int i = 0; i < 3; i++) {
                float3 d = detail[(int(lid.y) + j) * NR_RING + int(lid.x) + i];
                squares += d * d;
            }
        }
        float3 d = detail[(int(lid.y) + 1) * NR_RING + int(lid.x) + 1];
        squares -= d * d;
        float y_local = nr_expand(cG, NR_COARSE, cx0, cy0, x, y).x;
        float4 base = nr_expand(cR, NR_COARSE, cx0, cy0, x, y);
        float3 keep = nr_keep_gain(squares / 8.0f, y_local, base.w, base.yz, n, g);
        out.write(half4(half3(base.xyz + d * float3(keep.x, keep.y, keep.y)), half(keep.z)), uint2(x, y));
    }

    kernel void nr_demosaic_rebuild_gain(device const ushort* mosaic [[buffer(0)]],
                                         constant DemosaicParams& p [[buffer(1)]],
                                         constant NoiseLevel& n [[buffer(2)]],
                                         constant ColourGain& g [[buffer(3)]],
                                         texture2d<half, access::read> coarse [[texture(0)]],
                                         texture2d<half, access::read> coarseRebuilt [[texture(1)]],
                                         texture2d<half, access::write> out [[texture(2)]],
                                         uint2 lid [[thread_position_in_threadgroup]],
                                         uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float raw[NR_RING_RAW * NR_RING_RAW];
        threadgroup float green[NR_RING_GREEN * NR_RING_GREEN];
        threadgroup float3 cG[NR_COARSE * NR_COARSE];
        threadgroup float4 cR[NR_COARSE * NR_COARSE];
        threadgroup float3 detail[NR_RING * NR_RING];
        const uint index = lid.y * DM_TILE + lid.x;
        const int x0 = int(group.x) * DM_TILE, y0 = int(group.y) * DM_TILE + p.rowOffset;
        const int mx0 = int(p.originX) + x0 - 4, my0 = int(p.originY) + y0 - 4;
        const int cx0 = nr_half(x0 - 1) - 1, cy0 = nr_half(y0 - 1) - 1;
        dm_load(mosaic, p, raw, mx0, my0, NR_RING_RAW, NR_RING_RAW, index);
        nr_load_coarse(coarse, cG, cx0, cy0, index);
        nr_load_coarse(coarseRebuilt, cR, cx0, cy0, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        dm_green(p, raw, green, mx0, my0, NR_RING_RAW, NR_RING_GREEN, NR_RING_GREEN, index);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = index; i < NR_RING * NR_RING; i += DM_THREADS) {
            int rx = int(i % NR_RING), ry = int(i / NR_RING);
            int at = (ry + 3) * NR_RING_RAW + rx + 3, gat = (ry + 1) * NR_RING_GREEN + rx + 1;
            float3 rgb = dm_rgb(p, raw, green, at, NR_RING_RAW, gat, NR_RING_GREEN, mx0 + rx + 3, my0 + ry + 3);
            detail[i] = nr_opponent(dm_finish(p, rgb), p) - nr_expand(cG, NR_COARSE, cx0, cy0, x0 - 1 + rx, y0 - 1 + ry);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        const int x = x0 + int(lid.x), y = y0 + int(lid.y);
        if (x >= int(p.width) || y >= min(int(p.height), p.rowEnd)) { return; }
        float3 squares = 0.0f;
        for (int j = 0; j < 3; j++) {
            for (int i = 0; i < 3; i++) {
                float3 d = detail[(int(lid.y) + j) * NR_RING + int(lid.x) + i];
                squares += d * d;
            }
        }
        float3 d = detail[(int(lid.y) + 1) * NR_RING + int(lid.x) + 1];
        squares -= d * d;
        float y_local = nr_expand(cG, NR_COARSE, cx0, cy0, x, y).x;
        float4 base = nr_expand(cR, NR_COARSE, cx0, cy0, x, y);
        float3 keep = nr_keep_gain(squares / 8.0f, y_local, base.w, base.yz, n, g);
        dm_store(p, out, nr_rgb(base.xyz + d * float3(keep.x, keep.y, keep.y), p), x, y);
    }

    // The lens's distortion corrected: the corrected frame's pixel q, crop pixels from the top left
    // before orientation, shows the band at c + (q - c) (1 + d(|q - c| / rMax)) / scale, d the file's
    // curve as g - 1 at knots from the centre to the corner, read by Catmull-Rom from the band of
    // uncorrected rows rendered for these corrected rows, and is written upright.
    struct WarpParams {
        uint  width;
        uint  height;
        uint  orientation;
        int   rowOffset;
        int   rowEnd;
        float centreX;
        float centreY;
        float inverseRMax;
        float inverseScale;
        uint  count;
        float knots[16];
        int   bandX;
        int   bandY;
        uint  bandWidth;
        uint  bandHeight;
    };

    static inline float4 lw_weights(float t) {
        float t2 = t * t, t3 = t2 * t;
        return float4(-0.5f * t3 + t2 - 0.5f * t, 1.5f * t3 - 2.5f * t2 + 1.0f,
                      -1.5f * t3 + 2.0f * t2 + 0.5f * t, 0.5f * t3 - 0.5f * t2);
    }

    kernel void lens_warp(texture2d<half, access::read> band [[texture(0)]],
                          texture2d<half, access::write> out [[texture(1)]],
                          constant WarpParams& w [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        const int x = int(gid.x), y = int(gid.y) + w.rowOffset;
        if (x >= int(w.width) || y >= w.rowEnd) { return; }
        const float vx = float(x) - w.centreX, vy = float(y) - w.centreY;
        const float t = min(sqrt(vx * vx + vy * vy) * w.inverseRMax, 1.0f) * float(w.count - 1);
        const int i = min(int(t), int(w.count) - 2);
        const float f = (1.0f + mix(w.knots[i], w.knots[i + 1], t - float(i))) * w.inverseScale;
        // The position and its fraction in crop pixels, then the band's whole-pixel offset, so a
        // pixel reads the same whichever band it falls in.
        const float sx = w.centreX + vx * f, sy = w.centreY + vy * f;
        const float fx = floor(sx), fy = floor(sy);
        const float4 wx = lw_weights(sx - fx), wy = lw_weights(sy - fy);
        const int bx = int(fx) - 1 + w.bandX, by = int(fy) - 1 + w.bandY;
        const int right = int(w.bandWidth) - 1, bottom = int(w.bandHeight) - 1;
        const uint c0 = uint(clamp(bx, 0, right)), c1 = uint(clamp(bx + 1, 0, right));
        const uint c2 = uint(clamp(bx + 2, 0, right)), c3 = uint(clamp(bx + 3, 0, right));
        float3 sum = 0.0f;
        for (int j = 0; j < 4; j++) {
            const uint row = uint(clamp(by + j, 0, bottom));
            sum += wy[j] * (wx[0] * float3(band.read(uint2(c0, row)).rgb) + wx[1] * float3(band.read(uint2(c1, row)).rgb)
                          + wx[2] * float3(band.read(uint2(c2, row)).rgb) + wx[3] * float3(band.read(uint2(c3, row)).rgb));
        }
        const int2 upright = dm_oriented(x, y, int(w.width), int(w.height), w.orientation);
        out.write(half4(half3(sum), 1.0h), uint2(upright.x, int(out.get_height()) - 1 - upright.y));
    }

    // Writes sizeof(DemosaicParams), sizeof(NoiseLevel) and sizeof(WarpParams), so a test can hold
    // the Swift layouts to them.
    kernel void demosaic_params_size(device uint* out [[buffer(0)]]) {
        out[0] = sizeof(DemosaicParams);
        out[1] = sizeof(NoiseLevel);
        out[2] = sizeof(WarpParams);
        out[3] = sizeof(ColourGain);
    }
    """
}
