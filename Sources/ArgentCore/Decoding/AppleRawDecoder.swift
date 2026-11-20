import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal

/// The Core Image RAW decoder versions Argent runs, as the pins record them.
public enum AppleDecoderVersion: String, Sendable, Codable, CaseIterable {
    /// RAW 8: the classic demosaic and noise reduction, pinned since 2026-10-05, for every file
    /// RAW 9 does not take and as its fallback.
    case classic = "8"
    /// RAW 9: Apple's learned demosaic and denoise, a tiled Core ML network on the Neural Engine
    /// (macOS 27), for the a7 IV's Bayer modes since 2026-10-19 (docs/decoder.md section 18). It
    /// cannot be pinned across macOS or asset updates; on one build it repeats bit for bit.
    case learned = "9"

    /// The version as Core Image names it. Built from its name, so the app still opens on a
    /// macOS without RAW 9, where no file offers it.
    var coreImage: CIRAWDecoderVersion { CIRAWDecoderVersion(rawValue: rawValue) }
}

/// Apple's Core Image RAW decoder with its tone boost disabled, which yields
/// scene-linear output with Apple's demosaic, lens corrections, and noise reduction.
///
/// Every default that would change the pixels under a saved recipe is pinned in
/// `configure`: the decoder version, baseline exposure, shadow bias, sharpening, white
/// balance, moire reduction and the rest. A correctly metered mid-tone comes out at 0.18;
/// see `ExposureAnchor`. The pins travel with the frame as `DecodePins`.
///
/// `DecodeOptions.appleDecoder` picks RAW 8 or RAW 9. A RAW 9 decode works in extended linear
/// sRGB and is converted to the working space as it is written (`GPU.learnedWorkingColorSpace`).
public final class AppleRawDecoder: RawDecoder {
    /// CIE D55, the daylight the Kodak sheets assume. Apple's a7 IV profile reads it back
    /// as 5501 K with tint +10.0. `neutralTemperature` 5500 with tint 0 is not the same
    /// point: that is the Planckian locus, which sits 10 tint units magenta of D55.
    public static let daylightNeutral = DecodePins.Chromaticity(x: 0.33243, y: 0.34744)
    /// The version of the mid-tone anchor reasoning in `ExposureAnchor`.
    public static let anchorVersion = "1"
    /// The Core Image RAW decoder version `configure` pins by default, as the pins record it.
    public static let pinnedDecoderVersion = AppleDecoderVersion.classic.rawValue
    /// RAW 9's version, as the pins record it.
    public static let learnedDecoderVersion = AppleDecoderVersion.learned.rawValue

    /// Whether a decode at `scale` runs in Core Image's draft mode, its faster demosaic: RAW 8 at half
    /// size and below, where capture sharpening takes back its softness (`CaptureSharpening`). RAW 9
    /// never: draft mode saves it no time (about 0.5 s either way at 960 pixels), and without it a scaled
    /// decode's film keeps 0.87 to 1.06 of its develop's finest band area-resized and its neutral raw
    /// 0.87 to 1.03, against 0.89 to 1.12 with draft mode and the scaling mask and 0.76 to 0.90 (measured
    /// on the lossless sample and the still life from 960 to 4096 pixels, docs/decoder.md section 18).
    public static func draftMode(scale: Float, version: AppleDecoderVersion) -> Bool {
        version == .classic && scale <= 0.5
    }

    /// Whether Apple's decoder offers `version` for the file `filter` opened.
    public static func offers(_ version: AppleDecoderVersion, _ filter: CIRAWFilter) -> Bool {
        filter.supportedDecoderVersions.contains(version.coreImage)
    }

    private let gpu: GPU
    /// Whether each decode gets a Core Image context of its own (`init`). A frame view decode leaves 0.3
    /// to 0.84 GB in a shared context for 1 to 2 s, and in one of its own gives it back within 0.1 s
    /// (measured, docs/manual-development-validation.md, "Develops started with the frame view open").
    public let contextPerDecode: Bool

    /// `contextPerDecode` gives each decode a Core Image context of its own, freed with it.
    /// Core Image keeps working surfaces in a context for each frame size it has rendered, so
    /// a shared context grew past 3.8 GB over 19 full-size files of mixed modes against 2.2 GB
    /// with a context each, for about 25 ms a frame (measured, docs/M2-shell.md). A develop
    /// wants that, and so do the previews since 2026-10-19: while a shared context that has
    /// rendered a decode lives, a decode in a context of its own on the same GPU in 768-pixel tiles
    /// takes 1.6 times as long with RAW 9 and 3.2 times with RAW 8, and a context each costs the
    /// sheet's small decodes nothing measurable (docs/decoder.md section 18).
    public init(gpu: GPU, contextPerDecode: Bool = false) {
        self.gpu = gpu
        self.contextPerDecode = contextPerDecode
    }

    public func decode(_ url: URL, options: DecodeOptions) throws -> LinearFrame {
        try decode(url, options: options, stopped: { false })
    }

    /// The same, asking `stopped` before each tile of a tiled decode and throwing
    /// `DecodeError.stopped` once it says so; a decode rendered whole runs to the end.
    public func decode(_ url: URL, options: DecodeOptions, stopped: () -> Bool) throws -> LinearFrame {
        try autoreleasepool { try decodeNow(url, options: options, stopped: stopped) }
    }

    /// The full-size decode `decode` makes in `options.tileSize` tiles, area-resized onto `size`
    /// without ever being held whole: each tile is rendered into a texture of its own size and its
    /// share of the resize added before the next (`AreaResize.Pieces`). So it holds a tile and 16
    /// bytes an output pixel beside Core Image's tiles, where the frame would take 8 bytes a source
    /// pixel, 250 MB at 33 MP. Its pixels are the whole frame's area-resized to within a step of a
    /// half float where tiles meet (tested). `stopped` is asked before each tile, as by
    /// `decode(_:options:stopped:)`. The frame's scale is its long side over the full decode's.
    public func decode(_ url: URL, options: DecodeOptions, areaResizedTo size: (width: Int, height: Int),
                       using resize: AreaResize, stopped: () -> Bool) throws -> LinearFrame {
        try autoreleasepool {
            let prepared = try prepare(url, options: options)
            let extent = prepared.extent, pins = prepared.pins
            let (width, height) = (Int(extent.width), Int(extent.height))
            let output = try gpu.texturePool.acquire(width: size.width, height: size.height)
            let pieces = try resize.pieces(sourceWidth: width, sourceHeight: height, onto: output.texture)
            let context = self.context(for: pins)
            // Without a tile size the whole frame is the one piece.
            for rect in Self.tiles(of: extent, side: pins.tileSize ?? max(width, height)) {
                guard !stopped() else { throw DecodeError.stopped(url) }
                let piece = try gpu.texturePool.acquire(width: Int(rect.width), height: Int(rect.height))
                let destination = CIRenderDestination(mtlTexture: piece.texture, commandBuffer: nil)
                destination.colorSpace = gpu.workingColorSpace
                let task = try context.startTask(toRender: prepared.image, from: rect, to: destination, at: .zero)
                _ = try task.waitUntilCompleted()
                // Core Image lays a tile's rows into its own texture as into the frame's, so the
                // tile goes in at its offset in the frame (tested against the whole decode).
                try pieces.add(piece.texture, x: Int(rect.minX - extent.minX), y: Int(rect.minY - extent.minY))
            }
            try pieces.finish()
            return LinearFrame(image: output, decoderVersion: pins.decoderVersion,
                               scale: Float(max(size.width, size.height)) / Float(max(width, height)),
                               pins: pins, readback: prepared.readback, picture: prepared.picture)
        }
    }

    /// A decode ready to render: the raw's image upright and trimmed, its integral extent, and
    /// what `configure` applied and read back. The filter is kept with its image.
    private struct Prepared {
        let filter: CIRAWFilter
        let image: CIImage
        let extent: CGRect
        let pins: DecodePins
        let readback: DecodeReadback
        /// The full-size decode's upright, trimmed size, whatever this decode's scale.
        let picture: MaskSpace
    }

    /// The Core Image context a decode under `pins` renders in: RAW 9's in extended linear sRGB,
    /// RAW 8's in the working space; the shared one, or one of its own (`contextPerDecode`).
    private func context(for pins: DecodePins) -> CIContext {
        let learned = pins.decoderVersion == Self.learnedDecoderVersion
        if contextPerDecode { return learned ? gpu.makeLearnedContext() : gpu.makeContext() }
        return learned ? gpu.learnedContext : gpu.ciContext
    }

    private func prepare(_ url: URL, options: DecodeOptions) throws -> Prepared {
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedFile(url) }
        // RAW 9 only where Apple offers it: not lossless M or S, nor a macOS or camera without it.
        if options.appleDecoder != .classic, !Self.offers(options.appleDecoder, filter) {
            throw DecodeError.versionUnsupported(url, version: options.appleDecoder.rawValue)
        }
        // The raw mode's trim is on the sensor's right and bottom, wherever the file's
        // orientation turns them, so the decode is filled and trimmed as the sensor sees it
        // and turned upright last. Core Image's own turn gives the same pixels (verified).
        let orientation = filter.orientation
        filter.orientation = .up
        // The full-size picture's sensor size, read before `configure` sets a scale: below scale 1 RAW 9 reports another size, and
        // not in proportion (3572 by 2120 for the lossless L sample's 7008 by 4672, measured on macOS 27.2), which would put a mask's
        // field on another aspect in a scaled decode than in the develop's. RAW 7, 8 and 9 report the same at scale 1.
        let native = filter.nativeSize
        // A file whose layout cannot be read decodes without per-mode corrections.
        let layout = try? ARWLayout.read(from: url)
        let iso = Self.isoSpeed(of: filter)
        // Filled to the frame view's pixels, a trimmed mode is decoded at the scale that puts the
        // full-size decode's trimmed picture on exactly those pixels, and cut out where it lies.
        var request = options
        var filled: RawMode.FilledPicture?
        if options.fillsMaxLongSide, let longSide = options.maxLongSide, let layout,
           let picture = BodyProfile.named(layout.model)?.mode(for: layout)?.filled(for: layout, longSide: longSide) {
            filled = picture
            request.maxLongSide = nil
            request.scale = picture.scale
        }
        let configured = Self.configure(filter, options: request, iso: iso, layout: layout)
        var pins = configured.pins

        guard let sensorImage = filter.outputImage else { throw DecodeError.noOutput(url) }
        let sensorPicture: CIImage
        if let filled {
            sensorPicture = Self.cut(filled, from: sensorImage)
            pins.trimColumns = Int(sensorImage.extent.integral.width) - filled.width
            pins.trimRows = filled.bottom
        } else {
            var extent = sensorImage.extent.integral
            if pins.trimColumns > 0 || pins.trimRows > 0 {
                // Core Image puts y = 0 at the bottom of the frame, so dropping the bottom rows
                // raises the origin.
                extent = CGRect(x: extent.minX, y: extent.minY + CGFloat(pins.trimRows),
                                width: extent.width - CGFloat(pins.trimColumns),
                                height: extent.height - CGFloat(pins.trimRows))
            }
            sensorPicture = sensorImage.cropped(to: extent)
        }
        let image = sensorPicture.oriented(orientation)
        let extent = image.extent.integral
        // A zero extent means the decoder opened the file but could not decode it:
        // a corrupt or unsupported raw, not a bug in the render graph.
        guard Self.hasPixels(extent) else { throw DecodeError.emptyImage(url, nativeSize: filter.nativeSize) }
        let picture = try Self.fullSizePicture(native: native, orientation: orientation, layout: layout)
        return Prepared(filter: filter, image: image, extent: extent, pins: pins, readback: configured.readback, picture: picture)
    }

    /// The size a full-size decode of the file comes out at: the sensor's as the filter reports it with no turn set, less the raw mode's
    /// trim at full size, turned upright. A decode at any scale knows it this way, without making one (tested on the samples).
    static func fullSizePicture(native: CGSize, orientation: CGImagePropertyOrientation, layout: ARWLayout?) throws -> MaskSpace {
        let trim = layout.flatMap { layout in BodyProfile.named(layout.model)?.mode(for: layout)?.trim(for: layout, scale: 1) } ?? (columns: 0, rows: 0)
        let width = Int(native.width.rounded(.up)) - trim.columns, height = Int(native.height.rounded(.up)) - trim.rows
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: return try MaskSpace(width: height, height: width)
        default: return try MaskSpace(width: width, height: height)
        }
    }

    /// Whether a decode's integral `extent` has pixels to render: whole sides of at least one pixel. An
    /// infinite or NaN side is not one, and `Int(_:)` would trap on it, so it is converted only exactly.
    static func hasPixels(_ extent: CGRect) -> Bool {
        guard let width = Int(exactly: extent.width), let height = Int(exactly: extent.height) else { return false }
        return width > 0 && height > 0
    }

    /// `extent` in `side`-pixel tiles, row by row up from Core Image's y = 0, the frame's bottom,
    /// the last in each row and column cut short.
    private static func tiles(of extent: CGRect, side: Int) -> [CGRect] {
        var tiles: [CGRect] = []
        var y = extent.minY
        while y < extent.maxY {
            var x = extent.minX
            while x < extent.maxX {
                tiles.append(CGRect(x: x, y: y, width: min(CGFloat(side), extent.maxX - x), height: min(CGFloat(side), extent.maxY - y)))
                x += CGFloat(side)
            }
            y += CGFloat(side)
        }
        return tiles
    }

    private func decodeNow(_ url: URL, options: DecodeOptions, stopped: () -> Bool) throws -> LinearFrame {
        let prepared = try prepare(url, options: options)
        let image = prepared.image, extent = prepared.extent, pins = prepared.pins
        let frameTexture = try gpu.texturePool.acquire(width: Int(extent.width), height: Int(extent.height))
        let context = self.context(for: pins)

        // Tile by tile into the one texture, so the decoder's working surfaces are tile-sized; without a tile
        // size the whole frame is the one tile. Each goes through a Core Image task, on the context's own
        // command queue. Rendered into command buffers of the GPU's one queue, RAW 9 decodes made at once in
        // contexts of their own came back with a tile of RAW 9's network black or garbled, 49 of 120 at the
        // sheet's size two at once, and none alone, through tasks or with RAW 8; through a task a decode's
        // pixels are the same to the bit (measured 2026-10-29, docs/decoder.md section 18).
        let destination = CIRenderDestination(mtlTexture: frameTexture.texture, commandBuffer: nil)
        destination.colorSpace = gpu.workingColorSpace
        for rect in Self.tiles(of: extent, side: pins.tileSize ?? max(Int(extent.width), Int(extent.height))) {
            guard pins.tileSize == nil || !stopped() else { throw DecodeError.stopped(url) }
            let task = try context.startTask(toRender: image, from: rect, to: destination,
                                             at: CGPoint(x: rect.minX - extent.minX, y: rect.minY - extent.minY))
            _ = try task.waitUntilCompleted()
        }

        return LinearFrame(image: frameTexture, decoderVersion: pins.decoderVersion, scale: pins.scale,
                           pins: pins, readback: prepared.readback, picture: prepared.picture)
    }

    /// `picture` cut from `sensorImage`, the decode at `picture.scale` as the sensor sees it. The
    /// lines the bad data reaches repeat the nearest clean one: at the frame view's sizes from 900
    /// pixels, up to two columns at the right and one to four rows at the bottom, mostly two
    /// (computed). The rows are then moved by the picture's row phase with a Lanczos-3
    /// filter, so each pixel lies where the full-size decode's does once area-resized to the same
    /// pixels. Core Image cannot place a scaled decode between its own rows: a translation after it
    /// is sampled bilinearly, which cost 9 to 15 percent of the finest detail (measured; docs/M3-auto.md,
    /// section 41).
    static func cut(_ picture: RawMode.FilledPicture, from sensorImage: CIImage) -> CIImage {
        let extent = sensorImage.extent.integral
        let cleanBottom = min(CGFloat(picture.cleanBottom), extent.height - 1)
        let clean = CGRect(x: extent.minX, y: extent.minY + cleanBottom,
                           width: min(extent.width, CGFloat(picture.cleanWidth)), height: extent.height - cleanBottom)
        var image = sensorImage.cropped(to: clean).clampedToExtent()
        if abs(picture.rowPhase) > 0.001 {
            let shift = CIFilter.convolution9Vertical()
            shift.inputImage = image
            shift.weights = rowShiftWeights(picture.rowPhase)
            shift.bias = 0
            image = shift.outputImage ?? image
        }
        return image.cropped(to: CGRect(x: extent.minX, y: extent.minY + CGFloat(picture.bottom),
                                        width: CGFloat(picture.width), height: CGFloat(picture.height)))
    }

    /// Weights for Core Image's nine-row vertical convolution that make each row the image
    /// `phase` pixels above it, Core Image's y being up: Lanczos-3, normalized so a flat field
    /// stays flat. The convolution's first weight is for the row four above (verified,
    /// `AppleRawDecoderTests/rowShiftMovesRowsUp`).
    static func rowShiftWeights(_ phase: Double) -> CIVector {
        func lanczos3(_ x: Double) -> Double {
            guard x != 0 else { return 1 }
            guard abs(x) < 3 else { return 0 }
            let px = Double.pi * x
            return 3 * sin(px) * sin(px / 3) / (px * px)
        }
        let taps = (0..<9).map { lanczos3(Double(4 - $0) - phase) }
        let total = taps.reduce(0, +)
        return CIVector(values: taps.map { CGFloat($0 / total) }, count: 9)
    }

    /// Applies every pin to `filter` and returns what was applied and what the filter said
    /// about white balance before and after. `iso` is the frame's ISO, which keys the
    /// exposure gain below ISO 100 and the luminance noise reduction when `options` leaves
    /// it to the decoder. `layout`, when the file's could be read, selects the body's raw
    /// mode, whose exposure correction goes into the gain and whose trim goes into the pins
    /// for `decode` to apply. The decoder version is `options.appleDecoder` where the file offers
    /// it; `decode` refuses a file that does not offer RAW 9 when asked for it.
    @discardableResult
    public static func configure(_ filter: CIRAWFilter, options: DecodeOptions, iso: Float?,
                                 layout: ARWLayout? = nil) -> (pins: DecodePins, readback: DecodeReadback) {
        // Apple does not promise the same bits across decoder versions, and a newer macOS
        // can change the default. Version 8 is the default today and covers every a7 IV mode;
        // version 9 covers the Bayer modes (lossless L, uncompressed and lossy compressed).
        if offers(options.appleDecoder, filter) {
            filter.decoderVersion = options.appleDecoder.coreImage
        }
        let learned = filter.decoderVersion.rawValue == learnedDecoderVersion

        // Linear response: no tone curve, no shadow boost, no gamut squeeze, no baseline lift,
        // no black-point offset. Sharpening is off because the decoder would apply it in
        // scene-linear light, ahead of the film curve; the spec sharpens after the print.
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.isGamutMappingEnabled = false
        filter.baselineExposure = 0
        filter.shadowBias = 0
        filter.sharpnessAmount = 0
        filter.isHighlightRecoveryEnabled = true

        // A fixed daylight white balance, so the decode ignores the camera's. Daylight film
        // has no white balance: a tungsten scene stays warm and the lab balance trims the
        // cast without removing it, as the spec says. The camera's own reading is kept for
        // the readback, taken before the pin replaces it.
        let asShotTemperature = filter.neutralTemperature
        let asShotTint = filter.neutralTint
        filter.neutralChromaticity = CGPoint(x: daylightNeutral.x, y: daylightNeutral.y)

        // Apple's per-file default is 1.0 up to about ISO 500 and 0.0 from ISO 640 up, so an
        // unpinned roll would demosaic its high-ISO frames differently from the rest. The
        // a7 IV has at most a weak one-direction low-pass filter and colour moire shows on
        // fine fabric, so it stays on everywhere. About 21 ms, 5 percent of a full-size decode.
        // Decoder 9 reports it unsupported.
        var moireReduction: Float?
        if filter.isMoireReductionSupported {
            filter.moireReductionAmount = 1
            moireReduction = 1
        }
        // Both default to 0 today; set so a future default cannot change pixels. RAW 9 offers
        // no detail control, so it is left alone and recorded as absent.
        filter.contrastAmount = 0
        var detail: Float?
        if !learned || filter.isDetailSupported {
            filter.detailAmount = 0
            detail = filter.detailAmount
        }
        // At boost 0 this amount was measured to have no effect at 0, 1 or 2. It is pinned so
        // a future default cannot change pixels. Highlight headroom comes from highlight
        // recovery, which extends clipped neutrals to about +4.95 EV over 0.18.
        filter.extendedDynamicRangeAmount = 1

        // Put a correctly metered mid-tone at 0.18, where the film model expects it.
        let gainStops = ExposureAnchor.gainStops(iso: iso)
        let mode = layout.flatMap { BodyProfile.named($0.model)?.mode(for: $0) }
        let modeStops = mode?.exposureStops ?? 0
        filter.exposure = gainStops + modeStops
        let scale = options.maxLongSide.map { maxLongSide -> Float in
            let longSide = Float(max(filter.nativeSize.width, filter.nativeSize.height))
            return longSide > 0 ? min(1, Float(maxLongSide) / longSide) : options.scale
        } ?? options.scale
        let trim = layout.flatMap { layout in mode?.trim(for: layout, scale: scale) } ?? (columns: 0, rows: 0)
        filter.scaleFactor = scale
        filter.isDraftModeEnabled = draftMode(scale: scale, version: learned ? .learned : .classic)
        filter.isLensCorrectionEnabled = options.lensCorrection
        // Each version on its own scale: RAW 9's table is Apple's RAW 9 defaults, pinned.
        let luminance = learned
            ? options.learnedLuminanceNoiseReduction ?? NoiseReduction.learnedLuminanceAmount(iso: iso)
            : options.luminanceNoiseReduction ?? NoiseReduction.luminanceAmount(iso: iso)
        filter.luminanceNoiseReductionAmount = luminance
        // RAW 9's network removes colour noise itself and offers no control: not set, recorded absent.
        var colour: Float?
        if !learned || filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = options.colorNoiseReduction
            colour = filter.colorNoiseReductionAmount
        }

        let pins = DecodePins(
            version: DecodePins.currentVersion,
            decoderVersion: filter.decoderVersion.rawValue,
            baselineExposure: filter.baselineExposure,
            shadowBias: filter.shadowBias,
            sharpness: filter.sharpnessAmount,
            boost: filter.boostAmount,
            boostShadow: filter.boostShadowAmount,
            gamutMapping: filter.isGamutMappingEnabled,
            highlightRecovery: filter.isHighlightRecoveryEnabled,
            extendedDynamicRange: filter.extendedDynamicRangeAmount,
            neutralChromaticity: daylightNeutral,
            moireReduction: moireReduction,
            contrast: filter.contrastAmount,
            detail: detail,
            anchorDecodedMidTone: ExposureAnchor.decodedMidTone,
            anchorVersion: anchorVersion,
            exposureGainStops: gainStops,
            luminanceNoiseReduction: luminance,
            colorNoiseReduction: colour,
            lensCorrection: filter.isLensCorrectionEnabled,
            scale: filter.scaleFactor,
            draftMode: filter.isDraftModeEnabled,
            rawMode: mode?.name,
            modeExposureStops: modeStops,
            trimColumns: trim.columns,
            trimRows: trim.rows,
            tileSize: learned ? options.learnedTileSize ?? options.tileSize : options.tileSize)
        let readback = DecodeReadback(
            asShotTemperature: asShotTemperature, asShotTint: asShotTint,
            neutralTemperature: filter.neutralTemperature, neutralTint: filter.neutralTint)
        return (pins, readback)
    }

    /// What a decode of `url` reports about white balance (`DecodeReadback`), read from the file's
    /// metadata through the same camera profile without decoding it: the read-back of a frame
    /// another decoder made. `nil` when Core Image cannot open the file.
    public static func readback(of url: URL) -> DecodeReadback? {
        autoreleasepool {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            if offers(.classic, filter) { filter.decoderVersion = AppleDecoderVersion.classic.coreImage }
            let asShotTemperature = filter.neutralTemperature, asShotTint = filter.neutralTint
            filter.neutralChromaticity = CGPoint(x: daylightNeutral.x, y: daylightNeutral.y)
            return DecodeReadback(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                                  neutralTemperature: filter.neutralTemperature, neutralTint: filter.neutralTint)
        }
    }

    /// The ISO the camera recorded, from the Exif block Core Image reads with the file.
    public static func isoSpeed(of filter: CIRAWFilter) -> Float? {
        guard let exif = filter.properties[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        return isoSpeed(exif: exif)
    }

    /// `ISOSpeedRatings` is an Exif SHORT and saturates at 65535 (measured on ISO 102400
    /// and 204800 files), so `RecommendedExposureIndex`, a LONG, is preferred whenever the
    /// ratings are absent or saturated. A saturated rating with nothing better is still
    /// returned: it says the ISO is at least that, which is what the noise tiers need.
    public static func isoSpeed(exif: [String: Any]) -> Float? {
        let ratings = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.floatValue
        let recommended = (exif[kCGImagePropertyExifRecommendedExposureIndex as String] as? NSNumber)?.floatValue
        if let ratings, ratings != 65535 { return ratings }
        return recommended ?? ratings
    }
}
