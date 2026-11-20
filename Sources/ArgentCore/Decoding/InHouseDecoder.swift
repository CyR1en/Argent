import Darwin
import Foundation
import ImageIO
import Metal

/// The project's own raw decoder for the a7 IV's lossless-compressed L and uncompressed files, full
/// frame and APS-C: lossless L's tiles decompressed in parallel on the CPU or the uncompressed strip read as it
/// is, then demosaiced, white-balanced and put in the working space on the GPU in one pass
/// (docs/decoder.md).
///
/// It produces what `AppleRawDecoder` produces with the production pins, scene-linear Rec. 2020
/// upright at the same size, with the D55 neutral and the same exposure anchor, so a frame renders
/// through the film at the same brightness and colour, with noise reduction keyed to the ISO as
/// Apple's is (`InHouseNoiseReduction`), and with the lens corrections Apple's decoder applies: the
/// file's own distortion curve where the camera was set to correct distortion
/// (`SonyLensCorrection`, `LensWarp`). Every other file is refused with
/// `InHouseDecodeError.unsupported`, which is the caller's cue to use Apple's decoder;
/// `supports(_:)` asks first without decoding.
///
/// Safe to use from several threads at once.
public final class InHouseDecoder: RawDecoder, @unchecked Sendable {
    /// The decoder's name and the version of everything in it that changes pixels, recorded
    /// in the pins as `decoderVersion`.
    /// argent-2 added noise reduction and the demosaic's quieter green in flat areas.
    /// argent-3: the colour and the noise reduction's strengths refitted on data whose licence
    /// allows it, the CC0 samples and synthetic frames (docs/provenance.md).
    /// argent-4: the file's distortion correction, as Apple's decoder applies it
    /// (docs/decoder.md, section 13).
    /// argent-5: the noise reduction's strengths refitted under the a7 IV's published conversion
    /// gain, with neutral flat patches among the frames matched (docs/research/noise-and-hardware.md).
    public static let version = "argent-5"

    private let gpu: GPU
    private let demosaic: BayerDemosaic
    private let resize: AreaResize
    private let mosaics: MosaicBufferPool
    /// The noise reduction's pyramid levels, 175 MB a full-frame decode, and the lens correction's
    /// band, about 30 MB, kept apart from the frames' pool: returned to that pool they crowd out the
    /// last frame under a develop's cap, and every decode then allocates its frame afresh (a peak
    /// 447 MB above the decode without noise reduction, against 175 MB apart, measured). Holds one
    /// set idle.
    private let pyramids: TexturePool

    /// Builds the GPU pipelines; call it on one thread.
    public init(gpu: GPU) throws {
        self.gpu = gpu
        demosaic = try BayerDemosaic(device: gpu.device)
        resize = try AreaResize(gpu: gpu)
        mosaics = MosaicBufferPool(device: gpu.device)
        pyramids = TexturePool(device: gpu.device, maxIdleBytes: 240_000_000)
    }

    /// Where a decode's time went.
    public struct Timings: Sendable {
        /// Reading the file's structure and mapping it, or reading it whole off another disk; for an
        /// uncompressed file, reading its samples.
        public var read: Double
        /// Decompressing the tiles on the CPU, wall time; nothing for an uncompressed file.
        public var tiles: Double
        /// Estimating the sensor's noise from the mosaic.
        public var noise: Double
        /// The demosaic's command buffer on the GPU, with any noise reduction and resize.
        public var gpu: Double
        public var total: Double
    }

    /// True when `decode` would accept the file: an a7 IV lossless L or uncompressed raw, full frame
    /// or APS-C.
    public static func supports(_ url: URL) -> Bool {
        (try? check(url)) != nil
    }

    /// Whether a decode maps the file rather than reading it whole: only on the Mac's own fixed disk.
    /// A mapped file whose volume goes away under it, a network share dropped or a card pulled, kills
    /// the app at the next page the tiles touch (SIGBUS, reproduced on an SMB share, docs/M2-shell.md
    /// section 6); read whole, it is a read error or nothing. A card in a built-in reader is internal
    /// and removable. Reading costs the file in memory through the decode, 49 MB for an L raw.
    static func mapsFile(at url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        guard let volume = try? url.resourceValues(forKeys: keys) else { return false }
        return volume.volumeIsInternal == true && volume.volumeIsRemovable != true && volume.volumeIsEjectable != true
    }

    /// The file's bytes for a decode, mapped or read whole as `mapsFile(at:)` says.
    static func contents(of url: URL) throws -> Data {
        try Data(contentsOf: url, options: mapsFile(at: url) ? .alwaysMapped : [])
    }

    /// Frees the mosaic buffers and pyramid levels kept for the next decode, up to 386 MB.
    public func trim() {
        mosaics.trim()
        pyramids.trim()
    }

    /// The bytes of the mosaic buffers and pyramid levels kept for the next decode.
    public var keptBytes: Int { mosaics.idleBytes + pyramids.idleByteCount }

    public func decode(_ url: URL, options: DecodeOptions) throws -> LinearFrame {
        try decodeTimed(url, options: options).frame
    }

    /// `decode`, with where the time went.
    public func decodeTimed(_ url: URL, options: DecodeOptions) throws -> (frame: LinearFrame, timings: Timings) {
        let clock = ContinuousClock()
        let start = clock.now
        let (raw, info) = try Self.check(url)
        let layout = raw.mosaicLayout
        let mosaic = try mosaics.acquire(length: layout.pitch * raw.storedHeight * 2)
        defer { mosaics.recycle(mosaic) }
        let afterRead: ContinuousClock.Instant
        switch raw {
        case .lossless(let lossless):
            let file: Data
            do {
                file = try Self.contents(of: url)
            } catch {
                throw InHouseDecodeError.unreadable(url, "\(error)")
            }
            afterRead = clock.now
            do {
                try file.withUnsafeBytes { bytes in
                    try lossless.decodeTiles(bytes, into: mosaic.contents().bindMemory(to: UInt16.self, capacity: lossless.width * lossless.height))
                }
            } catch {
                throw InHouseDecodeError.malformed(url, "\(error)")
            }
        case .uncompressed(let uncompressed):
            // The samples are read straight into the mosaic, never mapped (`SonyUncompressedRaw.readSamples`).
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else { throw InHouseDecodeError.unreadable(url, String(cString: strerror(errno))) }
            defer { close(descriptor) }
            do {
                try uncompressed.readSamples(from: descriptor, into: mosaic.contents())
            } catch SonyUncompressedRaw.ReadFailure.short {
                throw InHouseDecodeError.malformed(url, "\(SonyUncompressedRaw.ReadFailure.short)")
            } catch {
                throw InHouseDecodeError.unreadable(url, "\(error)")
            }
            afterRead = clock.now
        }
        let afterTiles = clock.now

        let iso = info.iso.map(Float.init)
        let gainStops = ExposureAnchor.gainStops(iso: iso)
        let (frame, stages) = try render(mosaic, layout: layout, orientation: Int(info.orientation.rawValue),
                                         gainStops: gainStops, iso: iso, options: options, lens: raw.lens, encoding: raw.encoding)
        let end = clock.now
        let timings = Timings(read: (afterRead - start).seconds, tiles: (afterTiles - afterRead).seconds,
                              noise: stages.noise, gpu: stages.gpu, total: (end - start).seconds)
        return (frame, timings)
    }

    /// The GPU half of a decode: `mosaic` laid out as `layout` to a frame, upright by Exif
    /// `orientation`, at `gainStops`, with the options' noise reduction for `iso`, their lens
    /// correction from `lens`, the file's curves, and their scale.
    /// `matrix`, when given, replaces the camera matrix and the gain, for measuring the decoder in
    /// camera space; `tuning` replaces the noise reduction the options select, for measuring it.
    /// Returns the frame, the seconds spent estimating the noise and the command buffer's GPU time.
    func render(_ mosaic: MTLBuffer, layout: BayerMosaicLayout, orientation: Int, gainStops: Float, iso: Float?,
                options: DecodeOptions, lens: SonyLensCorrection? = nil, encoding: ARWLayout.Encoding = .losslessBayer,
                matrix: [[Double]]? = nil, tuning: InHouseNoiseReduction.Tuning? = nil) throws -> (LinearFrame, (noise: Double, gpu: Double)) {
        // With a lens correction the region rendered is the crop and the valid samples around it,
        // which the correction's reads stay inside.
        let correction = options.lensCorrection ? lens.flatMap { Self.lensWarp($0, layout: layout) } : nil
        var region = layout
        if let margin = correction?.margin {
            region.cropOrigin = .init(x: layout.cropOrigin.x - margin.x, y: layout.cropOrigin.y - margin.y)
            region.cropSize = .init(width: layout.cropSize.width + 2 * margin.x, height: layout.cropSize.height + 2 * margin.y)
        }
        var parameters = Self.parameters(for: region, orientation: orientation, gainStops: gainStops)
        if let matrix {
            let m = matrix.map { $0.map(Float.init) }
            parameters.matrix = (m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2])
        }
        let clock = ContinuousClock(), start = clock.now
        let samples = mosaic.contents().bindMemory(to: UInt16.self, capacity: mosaic.length / 2)
        let noise = SensorNoise.estimate(samples, layout: layout)
        let luminance = options.luminanceNoiseReduction ?? NoiseReduction.luminanceAmount(iso: iso)
        let colour = options.colorNoiseReduction
        let chosen = tuning ?? InHouseNoiseReduction.tuning(luminance: luminance, colour: colour, iso: iso)
        InHouseNoiseReduction.apply(chosen, noise: noise, to: &parameters)
        let levels = InHouseNoiseReduction.levels(chosen, noise: noise, parameters: parameters)
        let noiseSeconds = (clock.now - start).seconds

        let size = BayerDemosaic.outputSize(width: layout.cropSize.width, height: layout.cropSize.height, orientation: orientation)
        let full = try gpu.texturePool.acquire(width: size.width, height: size.height)
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        var pyramid: [PooledTexture] = []
        let gain = InHouseNoiseReduction.colourGain(chosen)
        if let correction {
            pyramid = try demosaic.encode(mosaic: mosaic, parameters: parameters, levels: levels, colourGain: gain, warp: correction.warp,
                                          margin: correction.margin, output: full.texture, pool: pyramids, into: commandBuffer)
        } else if let levels {
            pyramid = try demosaic.encode(mosaic: mosaic, parameters: parameters, levels: levels, colourGain: gain, output: full.texture,
                                          pool: pyramids, into: commandBuffer)
        } else {
            try demosaic.encode(mosaic: mosaic, parameters: parameters, output: full.texture, into: commandBuffer)
        }

        let scale = Self.scale(options, longSide: max(size.width, size.height))
        var image = full
        if scale < 1 {
            let scaled = Self.scaledSize(width: size.width, height: size.height, scale: scale)
            image = try gpu.texturePool.acquire(width: scaled.width, height: scaled.height)
            try resize.encode(full.texture, to: image.texture, into: commandBuffer)
        }
        commandBuffer.commit()
        withExtendedLifetime((mosaic, full, pyramid)) { commandBuffer.waitUntilCompleted() }
        if let error = commandBuffer.error { throw error }
        let pins = Self.pins(gainStops: gainStops, scale: scale, luminance: levels == nil ? 0 : chosen.luminanceAmount,
                             colour: levels == nil ? 0 : chosen.colourAmount, lensCorrection: options.lensCorrection,
                             encoding: encoding)
        let frame = LinearFrame(image: image, decoderVersion: Self.version, scale: scale, pins: pins,
                                picture: try MaskSpace(width: size.width, height: size.height))
        return (frame, (noiseSeconds, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime))
    }

    /// Why `url` is refused, from what reading its structure threw: unreadable where the file system
    /// failed the read, as a dropped share does, so that is not taken for a file the decoder does not take.
    private static func refusal(_ url: URL, _ error: Error) -> InHouseDecodeError {
        error is CocoaError || error is POSIXError ? .unreadable(url, "\(error)") : .unsupported(url, "\(error)")
    }

    /// The file's raw layout and frame information when the decoder takes it, else why not.
    static func check(_ url: URL) throws -> (raw: InHouseRaw, info: ARWFrameInfo) {
        let layout: ARWLayout
        do {
            layout = try ARWLayout.read(from: url)
        } catch {
            throw refusal(url, error)
        }
        guard layout.model == InHouseColor.model else {
            throw InHouseDecodeError.unsupported(url, "the camera is \(layout.model.isEmpty ? "unnamed" : layout.model), not the a7 IV")
        }
        guard InHouseRaw.encodings.contains(layout.encoding) else {
            throw InHouseDecodeError.unsupported(url, "the raw is \(layout.encoding.rawValue), not lossless L or uncompressed")
        }
        guard InHouseColor.crops.contains(layout.cropSize) else {
            throw InHouseDecodeError.unsupported(url, "the crop is \(layout.cropSize.width) by \(layout.cropSize.height), not full frame or APS-C")
        }
        let raw: InHouseRaw, info: ARWFrameInfo
        do {
            raw = layout.encoding == .losslessBayer ? .lossless(try SonyLosslessRaw.read(from: url))
                : .uncompressed(try SonyUncompressedRaw.read(from: url))
            info = try ARWFrameInfo.read(from: url)
        } catch {
            throw refusal(url, error)
        }
        // A distortion curve that folds the picture is left to Apple's decoder (`LensWarp.readRises`).
        if let lens = raw.lens, lens.correctsDistortion, let curve = lens.distortion, !LensWarp.readRises(curve) {
            throw InHouseDecodeError.unsupported(url, "its distortion curve folds the picture")
        }
        return (raw, info)
    }

    /// The distortion correction for a frame laid out as `layout` whose file carries `lens`, and
    /// the valid samples rendered around the crop for it, the same on both sides so the crop's centre
    /// stays the correction's: `nil` unless the camera was set to correct distortion, as Apple's
    /// decoder does, and the curve moves something. The file's shading and lateral colour curves
    /// are not applied: neither the camera's JPEG nor Apple's decode applies the shading curve, and
    /// the colour curves do not reproduce the lens's measured fringes (docs/decoder.md, section 13).
    static func lensWarp(_ lens: SonyLensCorrection, layout: BayerMosaicLayout) -> (warp: LensWarp, margin: (x: Int, y: Int))? {
        guard lens.correctsDistortion, let curve = lens.distortion else { return nil }
        let margin = (x: min(layout.cropOrigin.x, layout.validSize.width - layout.cropOrigin.x - layout.cropSize.width),
                      y: min(layout.cropOrigin.y, layout.validSize.height - layout.cropOrigin.y - layout.cropSize.height))
        guard margin.x >= 0, margin.y >= 0,
              let warp = LensWarp.plan(curve, width: layout.cropSize.width, height: layout.cropSize.height, margin: margin)
        else { return nil }
        return (warp, margin)
    }

    /// The kernel's parameters for a mosaic laid out as `raw`, turned upright by `orientation`,
    /// with `gainStops`.
    static func parameters(for raw: BayerMosaicLayout, orientation: Int, gainStops: Float) -> BayerDemosaic.Parameters {
        var p = BayerDemosaic.Parameters()
        p.pitch = UInt32(raw.pitch)
        p.originX = UInt32(raw.cropOrigin.x)
        p.originY = UInt32(raw.cropOrigin.y)
        p.width = UInt32(raw.cropSize.width)
        p.height = UInt32(raw.cropSize.height)
        p.limitX = UInt32(raw.validSize.width)
        p.limitY = UInt32(raw.validSize.height)
        p.orientation = UInt32((1...8).contains(orientation) ? orientation : 1)
        let gains = InHouseColor.daylightGains
        let colours = raw.cfa.map { UInt32($0) }
        p.colour = (colours[0], colours[1], colours[2], colours[3])
        let black = raw.blackLevels.map(Float.init)
        p.black = (black[0], black[1], black[2], black[3])
        let scale = (0..<4).map { Float(gains[raw.cfa[$0]]) / (Float(raw.whiteLevel) - black[$0]) }
        p.scale = (scale[0], scale[1], scale[2], scale[3])
        p.clip = (Float(gains[0]), Float(gains[1]), Float(gains[2]))
        p.highlightStart = InHouseColor.highlightStart
        let m = InHouseColor.cameraToWorking.map { row in row.map { Float($0) * exp2(gainStops) } }
        p.matrix = (m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2])
        return p
    }

    /// A scaled decode's size: each side scaled and rounded up, as Apple's decoder sizes its scaled
    /// decodes (a 7008 by 4672 frame asked for 2189 pixels comes back 2189 by 1460 from both,
    /// measured), so the frame view's box, made by that rule, fits either decoder's frame. The
    /// tolerance keeps a side the scale makes exact, at Float precision, from rounding up past it.
    static func scaledSize(width: Int, height: Int, scale: Float) -> (width: Int, height: Int) {
        func side(_ n: Int) -> Int { max(1, Int((Double(n) * Double(scale) - 1e-3).rounded(.up))) }
        return (side(width), side(height))
    }

    static func scale(_ options: DecodeOptions, longSide: Int) -> Float {
        let scale = options.maxLongSide.map { longSide > 0 ? min(1, Float($0) / Float(longSide)) : 1 } ?? options.scale
        return scale > 0 ? min(1, scale) : 1
    }

    /// What this decoder did to the frame, in the fields Apple's decoder records. The noise
    /// reduction amounts are Apple's scale, which `InHouseNoiseReduction` keys its strengths to
    /// (the decoder version says which strengths); lens correction is the option, as Apple's pins
    /// record it, the decoder version saying what it does; it has no moire reduction, sharpening
    /// or tone controls, so those read as off; the neutral, the anchor and the gain are Apple's pins.
    static func pins(gainStops: Float, scale: Float, luminance: Float, colour: Float, lensCorrection: Bool,
                     encoding: ARWLayout.Encoding = .losslessBayer) -> DecodePins {
        DecodePins(
            version: DecodePins.currentVersion, decoderVersion: version, baselineExposure: 0, shadowBias: 0,
            sharpness: 0, boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true,
            extendedDynamicRange: 0, neutralChromaticity: AppleRawDecoder.daylightNeutral, moireReduction: nil,
            contrast: 0, detail: 0, anchorDecodedMidTone: ExposureAnchor.decodedMidTone,
            anchorVersion: AppleRawDecoder.anchorVersion, exposureGainStops: gainStops,
            luminanceNoiseReduction: luminance, colorNoiseReduction: colour, lensCorrection: lensCorrection, scale: scale,
            draftMode: false, rawMode: BodyProfile.a7IV.modes.first { $0.encoding == encoding }?.name)
    }
}

/// A raw the in-house decoder takes: an a7 IV lossless L file, whose tiles decode to the mosaic, or
/// an uncompressed one, whose strip is the mosaic, full frame or APS-C. Both hold the same sensor's 14-bit
/// samples at the same black and white levels, crop and valid area, and the same lens tags
/// (docs/decoder.md, section 17), so everything after the mosaic is one path.
enum InHouseRaw: Sendable, Equatable {
    case lossless(SonyLosslessRaw)
    case uncompressed(SonyUncompressedRaw)

    /// The raw encodings the decoder takes.
    static let encodings: Set<ARWLayout.Encoding> = [.losslessBayer, .uncompressed]

    var encoding: ARWLayout.Encoding {
        switch self {
        case .lossless: return .losslessBayer
        case .uncompressed: return .uncompressed
        }
    }

    var mosaicLayout: BayerMosaicLayout {
        switch self {
        case .lossless(let raw): return raw.mosaicLayout
        case .uncompressed(let raw): return raw.mosaicLayout
        }
    }

    /// The mosaic's stored rows.
    var storedHeight: Int {
        switch self {
        case .lossless(let raw): return raw.height
        case .uncompressed(let raw): return raw.height
        }
    }

    var lens: SonyLensCorrection? {
        switch self {
        case .lossless(let raw): return raw.lens
        case .uncompressed(let raw): return raw.lens
        }
    }
}

public enum InHouseDecodeError: Error, CustomStringConvertible {
    /// Not a file this decoder takes; decode it with Apple's.
    case unsupported(URL, String)
    /// The file system failed the read, as when the file's share drops: not the decoder's failure, and
    /// not a cue to use Apple's decoder, which could not read it either.
    case unreadable(URL, String)
    /// A file that looked supported and failed to decode.
    case malformed(URL, String)
    /// The GPU cannot run the demosaic.
    case device(String)

    public var description: String {
        switch self {
        case .unsupported(let url, let why): return "The in-house decoder does not take \(url.lastPathComponent): \(why)."
        case .unreadable(let url, let why): return "Could not read \(url.lastPathComponent): \(why)."
        case .malformed(let url, let why): return "\(url.lastPathComponent) is damaged: \(why)."
        case .device(let why): return "The in-house decoder cannot run here: \(why)."
        }
    }
}

/// The in-house decoder's colour for the a7 IV, measured against Apple's decoder.
///
/// Apple's decode under the D55 pin is a per-channel gain in camera space followed by a fixed
/// 3 by 3 matrix (docs/M1-spikes.md), so the two are fitted as one: a weighted least-squares
/// fit of 16-pixel block means of black-subtracted, white-normalized camera RGB to Apple's linear
/// Rec. 2020 output at baseline exposure 0, lens correction and noise reduction off, clipped blocks
/// left out. The frames are ones whose licence allows choosing constants on them (docs/provenance.md):
/// the three CC0 samples this decoder's GPU half reads (lossless L and uncompressed at ISO 250,
/// uncompressed APS-C at ISO 640) and two frames of synthetic colour patches written into a copy of
/// the uncompressed sample (`SyntheticRaw`), which span the colours a 3 by 3 needs. The neutral is the
/// camera RGB the fit maps to equal channels, normalized to green; the matrix is the fit after it.
/// The camera RGB is this decoder's own demosaic; `InHouseDecoderMeasureTests/colourFit` re-runs the
/// fit, and checks it on the photographyblog and Imaging Resource frames the first fit used, now as
/// evaluation only. The file's own matrix, Sony's tag 0x7800 in the encrypted SR2 data, is a rendering
/// adjustment near the identity, not a sensor characterization, and cannot give Apple's colour
/// (docs/decoder.md, section 2).
public enum InHouseColor {
    public static let model = "ILCE-7M4"
    public static let fullFrameCrop = ARWLayout.Size(width: 7008, height: 4672)
    /// The APS-C (Super 35) crop of lossless L, here called "M" by Sony's menu but a Bayer mosaic, and
    /// of uncompressed. Its file writes the first 11 of the curve's knots, which reach the crop's corner
    /// as the full frame's 16 reach its own: on the CC0 APS-C frames every patch sits within 0.24 px of
    /// Apple's decode (full frame 0.34), and the frames land as the full-frame ones of the same scene
    /// (docs/decoder.md, section 17).
    public static let apsCCrop = ARWLayout.Size(width: 4608, height: 3072)
    /// The crops the decoder takes.
    public static let crops = [fullFrameCrop, apsCCrop]

    /// Camera RGB gains for the D55 neutral, green 1.
    public static let daylightGains: [Double] = [2.481785, 1, 1.630095]

    /// White-balanced camera RGB, 1 at a saturated sample, to linear Rec. 2020 at baseline
    /// exposure 0. Each row sums to 0.998214, the level of a white-balanced neutral at green's clip.
    public static let cameraToWorking: [[Double]] = [
        [1.121206, 0.023553, -0.146545],
        [-0.042143, 1.481152, -0.440795],
        [0.005260, -0.238506, 1.231460],
    ]

    /// Where highlight reconstruction starts, as a share of a channel's clip.
    public static let highlightStart: Float = 0.9
}

/// Mosaic buffers kept for reuse: a full-frame lossless L mosaic is 73 MB, an uncompressed one 66 MB,
/// and a fresh one pays for its pages on first touch. Holds at most two idle.
final class MosaicBufferPool: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var idle: [MTLBuffer] = []
    private let maxIdle = 2

    init(device: MTLDevice) {
        self.device = device
    }

    func acquire(length: Int) throws -> MTLBuffer {
        if let buffer = lock.withLock({ () -> MTLBuffer? in
            guard let index = idle.firstIndex(where: { $0.length == length }) else { return nil }
            return idle.remove(at: index)
        }) { return buffer }
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { throw GPUError.textureAllocation }
        return buffer
    }

    func recycle(_ buffer: MTLBuffer) {
        lock.withLock {
            if idle.count < maxIdle { idle.append(buffer) }
        }
    }

    func trim() {
        lock.withLock { idle.removeAll() }
    }

    /// The bytes of the buffers waiting for reuse.
    var idleBytes: Int { lock.withLock { idle.reduce(0) { $0 + $1.length } } }
}
