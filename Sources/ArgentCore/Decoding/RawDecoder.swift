import Foundation
import Metal

/// A decoded frame in scene-linear light, in the working color space, ready for the render graph.
///
/// A correctly metered mid-tone is 0.18, which is what the film model's middle gray means.
/// Each decoder applies its own gain to get there; see `ExposureAnchor`.
public struct LinearFrame {
    /// The frame's pixels. Holding the frame keeps the texture checked out of the pool.
    public let image: PooledTexture
    public let decoderVersion: String
    public let scale: Float
    /// What the decoder was set to for this frame. `nil` for a frame that did not come
    /// through a raw decoder, such as a texture a test fills by hand.
    public let pins: DecodePins?
    /// What the decoder said about white balance before and after the pins. `nil` as for `pins`.
    public let readback: DecodeReadback?
    /// The whole picture's upright size at full resolution, the develop's own, whatever this frame's size. Every render of a picture
    /// asks for the same coverage field by it, so a preview and the develop read one field (`MaskFieldCache`). `scale` cannot recover
    /// it, since a rounded short side over a scale is not a whole number. `nil` for a frame that came through no decoder, such as a
    /// texture a test fills by hand, or a decode kept on disk before this was recorded: `maskPicture` then takes the frame's own size.
    public let picture: MaskSpace?
    /// The correction the lens stage made this scene with; nil on a decode kept for Auto or on disk.
    public let lens: ResolvedLensCorrection?

    public init(image: PooledTexture, decoderVersion: String, scale: Float,
                pins: DecodePins? = nil, readback: DecodeReadback? = nil, picture: MaskSpace? = nil,
                lens: ResolvedLensCorrection? = nil) {
        self.image = image
        self.decoderVersion = decoderVersion
        self.scale = scale
        self.pins = pins
        self.readback = readback
        self.picture = picture
        self.lens = lens
    }

    public var texture: MTLTexture { image.texture }
    public var width: Int { image.width }
    public var height: Int { image.height }
}

public struct DecodeOptions: Sendable {
    /// 1.0 is full resolution; 0.25 is the quarter-size preview path.
    public var scale: Float = 1.0
    /// When set, the scale is chosen per file so the frame's longer side is at most this many
    /// pixels, and `scale` is ignored. A contact sheet wants the same pixel size from a
    /// full-frame and an APS-C file; Apple's decoder costs the same per file either way.
    public var maxLongSide: Int? = nil
    /// With `maxLongSide`, makes up a raw mode's trim: the decode shows the full-size decode's
    /// trimmed picture at exactly `maxLongSide` pixels on its longer side, rather than a few pixels
    /// short of it (lossless S drops 12 to 24) or a smaller part of the frame
    /// (`RawMode.filled(for:longSide:)`). The frame view shows its decode one to one and needs
    /// exactly its own pixels, lying where the file's do.
    public var fillsMaxLongSide = false
    /// Whether the decoder applies its own lens warp. App paths set this false and use the lens stage.
    public var lensCorrection = true
    /// 0...1 on RAW 8's scale, which the in-house decoder shares, or `nil` to key the amount to the
    /// frame's ISO through `NoiseReduction`'s tiers. Kept light because grain covers luminance noise
    /// (spec, Auto development).
    public var luminanceNoiseReduction: Float? = nil
    /// The same on RAW 9's own scale, or `nil` for `NoiseReduction.learnedLuminanceAmount`. Apart from
    /// RAW 8's, so an amount recorded by one decoder never reaches the other, as when a RAW 9 decode
    /// falls back to RAW 8.
    public var learnedLuminanceNoiseReduction: Float? = nil
    /// 0...1. Always on because color noise reads as digital under grain. RAW 9 has no such
    /// control: its network removes colour noise itself, and the amount is not set.
    public var colorNoiseReduction: Float = 0.5
    /// Which Core Image RAW decoder Apple's decoder runs: RAW 8 unless a route asks for RAW 9
    /// (`DecoderChoices`). The in-house decoder ignores it.
    public var appleDecoder: AppleDecoderVersion = .classic
    /// When set, the decode is rendered in square tiles of this many pixels rather than whole,
    /// which bounds the decoder's working memory. It changes a few hundred isolated pixels of
    /// a frame, so it is pinned and recorded like every other setting that changes pixels.
    public var tileSize: Int? = nil
    /// The same for RAW 9's decodes, or `nil` for `tileSize`. Apart from RAW 8's, so a RAW 9 decode
    /// that falls back to RAW 8 renders in RAW 8's own tiles, as RAW 8's develops do.
    public var learnedTileSize: Int? = nil

    public init() {}
}

/// The decoder's luminance noise reduction by ISO, used when `DecodeOptions` leaves it to us.
///
/// The tiers and their boundaries are the spec's light, moderate and strong. What each amount
/// removes, measured with decoder 8 on the CC0 APS-C sample at its own ISO 640 as the share of
/// high-pass luma noise in flat patches (docs/provenance.md): 0.4 about 19 percent, 0.6 about 29,
/// 0.9 about 68 and 1.0 about 88; the CC0 full-frame sample simulated at ISO 1600 to 51200 gives
/// 20 to 21, 30 to 32, 69 to 73 and 91 to 97, and at its own ISO 250 the amounts up to 0.8
/// remove only 2 to 8 percent. The response is about half the amount up to 0.75 and rises steeply above
/// it, so the tiers stay off that knee until the noise is bad enough to need it. The decoder
/// scales the effect by the ISO it reads from the file, so the same amount does less on a clean
/// frame.
public enum NoiseReduction {
    /// Below ISO 1600.
    public static let lowISOLuminance: Float = 0.4
    /// ISO 1600 to 6400 inclusive.
    public static let highISOLuminance: Float = 0.6
    /// Above ISO 6400.
    public static let extremeISOLuminance: Float = 0.9

    /// A frame with no usable ISO gets the low tier, the one that does least.
    public static func luminanceAmount(iso: Float?) -> Float {
        guard let iso, iso > 0 else { return lowISOLuminance }
        if iso < 1600 { return lowISOLuminance }
        if iso <= 6400 { return highISOLuminance }
        return extremeISOLuminance
    }

    /// RAW 9's luminance amount by ISO: Apple's own RAW 9 default for the a7 IV, which depends on
    /// the Exif ISO alone (the same on all 74 Bayer files here at their ISOs, and on copies of one file
    /// with the ISO rewritten), read to six decimals at every third-stop ISO from 50 to 204800 under
    /// macOS 27.0.1 on 2026-10-19 (measured, `Raw9MeasureTests/defaults`; docs/decoder.md section 18).
    /// It is pinned here so a later default cannot move pixels. Flat at its first amount to ISO 640 and
    /// at its last from 32000; between the knots it runs linearly in stops, within 0.001 of Apple's own
    /// default at ISOs between them. On RAW 9's own scale, not RAW 8's: at ISO 6400 an amount of 0.5
    /// leaves about the luminance noise RAW 8's 0.6 does.
    public static let learnedLuminanceTable: [(iso: Float, amount: Float)] = [
        (640, 0.010000), (800, 0.012408), (1000, 0.023151), (1250, 0.041459), (1600, 0.069141), (2000, 0.099630),
        (2500, 0.134121), (3200, 0.175559), (4000, 0.214731), (5000, 0.254345), (6400, 0.297300), (8000, 0.334094),
        (10000, 0.367767), (12800, 0.400002), (16000, 0.423355), (20000, 0.440026), (25600, 0.449303), (32000, 0.450000),
    ]

    /// RAW 9's amount for a frame at `iso` (`learnedLuminanceTable`); a frame with no usable ISO gets
    /// the table's first, the one that does least.
    public static func learnedLuminanceAmount(iso: Float?) -> Float {
        let table = learnedLuminanceTable
        guard let first = table.first, let last = table.last else { return 0 }
        guard let iso, iso > first.iso else { return first.amount }
        guard iso < last.iso else { return last.amount }
        let upper = table.firstIndex { $0.iso >= iso }!
        let a = table[upper - 1], b = table[upper]
        let t = log2(iso / a.iso) / log2(b.iso / a.iso)
        return a.amount + (b.amount - a.amount) * t
    }
}

/// Every decoder setting that changes the pixels, as applied to one frame.
///
/// A recipe sidecar stores this so a later run, or a later macOS, can be checked against
/// what produced the frame. `version` changes whenever a pinned value changes.
public struct DecodePins: Sendable, Codable, Equatable {
    /// CIE 1931 chromaticity coordinates.
    public struct Chromaticity: Sendable, Codable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The set of pins this build applies. 2026-10-06-2 added the per-mode exposure and
    /// the lossless S trim; 2026-10-06-3 the decode tile size; 2026-10-06-4 applies the trim
    /// on the sensor's edges before the decode is turned upright, which changes a turned
    /// lossless S frame: it was trimmed on the wrong edges, kept the bad band and lost 3:2;
    /// 2026-10-07-1 moves lossless M and S from -0.20 and -0.25 stops to -0.26 and -0.27.
    /// RAW 9 (2026-10-19) changed no pin of RAW 8 or the in-house decoder, so the version stays:
    /// RAW 9's pins are new, told apart by `decoderVersion` 9, which nothing recorded before, and
    /// the colour amount and detail it does not take read as absent (docs/decoder.md section 18).
    public static let currentVersion = "2026-10-07-1"

    public var version: String
    public var decoderVersion: String
    public var baselineExposure: Float
    public var shadowBias: Float
    public var sharpness: Float
    public var boost: Float
    public var boostShadow: Float
    public var gamutMapping: Bool
    public var highlightRecovery: Bool
    public var extendedDynamicRange: Float
    public var neutralChromaticity: Chromaticity
    /// `nil` when the decoder version has no such control; version 9 reports it unsupported.
    public var moireReduction: Float?
    public var contrast: Float
    /// `nil` when the decoder version has no such control, as version 9.
    public var detail: Float?
    /// `ExposureAnchor.decodedMidTone` and the version of the reasoning behind it.
    public var anchorDecodedMidTone: Float
    public var anchorVersion: String
    /// The gain applied to this frame, which depends on its ISO below ISO 100.
    public var exposureGainStops: Float
    /// The amounts actually used, after the ISO keying. The colour amount is `nil` for a decoder
    /// version without the control, as version 9, whose network removes colour noise itself.
    public var luminanceNoiseReduction: Float
    public var colorNoiseReduction: Float?
    public var lensCorrection: Bool
    public var scale: Float
    /// Core Image's faster, lower-quality demosaic, which the decoder turns on for previews.
    public var draftMode: Bool
    /// The body's name for the raw mode, from `BodyProfile`; `nil` for a file whose body or
    /// mode has no profile, which gets no per-mode correction.
    public var rawMode: String?
    /// Stops added for the mode on top of `exposureGainStops`; see `RawMode.exposureStops`.
    public var modeExposureStops: Float
    /// Output pixels dropped at the sensor's right and bottom, where Apple's decoder reads
    /// past the mode's valid data, before the decode is turned upright; see
    /// `RawMode.trim(for:scale:)`. A decode filled to the frame view's pixels records what its
    /// cut drops (`RawMode.filled(for:longSide:)`).
    public var trimColumns: Int
    public var trimRows: Int
    /// The decode's tile size, `nil` for a decode rendered whole; see `DecodeOptions.tileSize`.
    public var tileSize: Int?

    public init(version: String, decoderVersion: String, baselineExposure: Float, shadowBias: Float, sharpness: Float,
                boost: Float, boostShadow: Float, gamutMapping: Bool, highlightRecovery: Bool,
                extendedDynamicRange: Float, neutralChromaticity: Chromaticity, moireReduction: Float?,
                contrast: Float, detail: Float?, anchorDecodedMidTone: Float, anchorVersion: String,
                exposureGainStops: Float, luminanceNoiseReduction: Float, colorNoiseReduction: Float?,
                lensCorrection: Bool, scale: Float, draftMode: Bool, rawMode: String? = nil,
                modeExposureStops: Float = 0, trimColumns: Int = 0, trimRows: Int = 0, tileSize: Int? = nil) {
        self.version = version
        self.decoderVersion = decoderVersion
        self.baselineExposure = baselineExposure
        self.shadowBias = shadowBias
        self.sharpness = sharpness
        self.boost = boost
        self.boostShadow = boostShadow
        self.gamutMapping = gamutMapping
        self.highlightRecovery = highlightRecovery
        self.extendedDynamicRange = extendedDynamicRange
        self.neutralChromaticity = neutralChromaticity
        self.moireReduction = moireReduction
        self.contrast = contrast
        self.detail = detail
        self.anchorDecodedMidTone = anchorDecodedMidTone
        self.anchorVersion = anchorVersion
        self.exposureGainStops = exposureGainStops
        self.luminanceNoiseReduction = luminanceNoiseReduction
        self.colorNoiseReduction = colorNoiseReduction
        self.lensCorrection = lensCorrection
        self.scale = scale
        self.draftMode = draftMode
        self.rawMode = rawMode
        self.modeExposureStops = modeExposureStops
        self.trimColumns = trimColumns
        self.trimRows = trimRows
        self.tileSize = tileSize
    }
}

/// What the decoder reports about white balance around the neutral pin.
///
/// The as-shot pair is the camera's white balance as Apple's camera profile reads it
/// before the pin. The neutral pair is how the same profile reads the pinned chromaticity
/// back. An OS update that changes the profile moves these numbers while the pins stay put.
public struct DecodeReadback: Sendable, Codable, Equatable {
    public var asShotTemperature: Float
    public var asShotTint: Float
    public var neutralTemperature: Float
    public var neutralTint: Float

    public init(asShotTemperature: Float, asShotTint: Float, neutralTemperature: Float, neutralTint: Float) {
        self.asShotTemperature = asShotTemperature
        self.asShotTint = asShotTint
        self.neutralTemperature = neutralTemperature
        self.neutralTint = neutralTint
    }
}

public enum DecodeError: Error, CustomStringConvertible {
    case unsupportedFile(URL)
    case noOutput(URL)
    case emptyImage(URL, nativeSize: CGSize)
    /// The caller stopped a tiled decode part way; nothing is wrong with the file.
    case stopped(URL)
    /// Apple's decoder does not offer the version asked for on this file, as RAW 9 on lossless M
    /// or S, or on a macOS without it; the caller decodes it with RAW 8.
    case versionUnsupported(URL, version: String)
    /// The file could not be read now, as when its share drops: not a cue to try another decoder.
    case unreadable(URL, String)

    public var description: String {
        switch self {
        case .unsupportedFile(let url):
            return "The decoder could not open \(url.lastPathComponent)."
        case .noOutput(let url):
            return "The decoder produced no image for \(url.lastPathComponent)."
        case .emptyImage(let url, let size):
            return "The decoder opened \(url.lastPathComponent) but decoded nothing (native size \(Int(size.width))x\(Int(size.height))). The file is probably corrupt or not a supported raw."
        case .stopped(let url):
            return "The decode of \(url.lastPathComponent) was stopped."
        case .versionUnsupported(let url, let version):
            return "Apple's decoder offers no version \(version) for \(url.lastPathComponent)."
        case .unreadable(let url, let why):
            return "Could not read \(url.lastPathComponent): \(why)."
        }
    }
}

/// The seam between Argent and whichever raw decoder sits underneath it.
///
/// `AppleRawDecoder` implements it with Apple's Core Image RAW filter: RAW 9, Apple's learned
/// demosaic and denoise, for the a7 IV's Bayer modes, and RAW 8 for everything else and as the
/// fallback (docs/decoder.md section 18). `InHouseDecoder`, the project's own lossless-JPEG tiles
/// and Metal demosaic for the a7 IV's lossless L and uncompressed files, implements it too, kept
/// for comparison and as a route of its own (`DecoderRoute.inHouse`).
public protocol RawDecoder {
    func decode(_ url: URL, options: DecodeOptions) throws -> LinearFrame
}
