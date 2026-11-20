import Foundation

/// One way a body records raw, and what Apple's decoder needs to make it match the others.
///
/// This is profile data, not code: a new body or a new mode adds a row to `BodyProfile`.
public struct RawMode: Sendable, Equatable {
    /// The camera's name for the mode, which the pins record.
    public var name: String
    public var encoding: ARWLayout.Encoding
    /// The camera crop this mode writes, or `nil` for any size.
    public var cropSize: ARWLayout.Size?
    /// Stops added to the decode gain so this mode meets uncompressed and lossless L for the
    /// same exposure.
    public var exposureStops: Float
    /// Where Apple's decoder places its output window inside the stored data, when it does
    /// not use the file's own crop origin. `nil` when it does, or when it never runs past
    /// the valid area.
    public var decoderCropOrigin: ARWLayout.Point?
    /// Whether the mode goes to Apple's RAW 9, the learned demosaic and denoise
    /// (`DecoderRoute.raw9`): a mode whose files RAW 9 takes, a Bayer mosaic its network reads. The
    /// decode still asks each file, and one RAW 9 does not take goes to RAW 8.
    public var learned: Bool

    public init(name: String, encoding: ARWLayout.Encoding, cropSize: ARWLayout.Size? = nil,
                exposureStops: Float = 0, decoderCropOrigin: ARWLayout.Point? = nil, learned: Bool = false) {
        self.name = name
        self.encoding = encoding
        self.cropSize = cropSize
        self.exposureStops = exposureStops
        self.decoderCropOrigin = decoderCropOrigin
        self.learned = learned
    }

    /// Output pixels to drop at the right and bottom of a decode at `scale` so no pixel
    /// comes from outside the valid area. Both are the sensor's, before the file's
    /// orientation turns the frame upright.
    ///
    /// Apple's decoder spreads the bad data a few pixels further than the overrun, at most
    /// 3 columns and 2 rows at every scale measured, so the trim adds `spill`. It is then
    /// rounded up to a whole multiple of the crop's aspect ratio, which keeps a 3:2 frame 3:2.
    public func trim(for layout: ARWLayout, scale: Float) -> (columns: Int, rows: Int) {
        guard let origin = decoderCropOrigin, let valid = layout.validSize else { return (0, 0) }
        let overrunX = origin.x + layout.cropSize.width - valid.width
        let overrunY = origin.y + layout.cropSize.height - valid.height
        guard overrunX > 0 || overrunY > 0 else { return (0, 0) }
        var columns = Int((Float(max(0, overrunX)) * scale).rounded(.up)) + Self.spill.columns
        var rows = Int((Float(max(0, overrunY)) * scale).rounded(.up)) + Self.spill.rows

        let unit = Self.aspectUnit(layout.cropSize)
        if unit.x <= 16, unit.y <= 16 {
            let k = max((columns + unit.x - 1) / unit.x, (rows + unit.y - 1) / unit.y)
            columns = k * unit.x
            rows = k * unit.y
        }
        return (columns, rows)
    }

    /// Pixels of bad data beyond the overrun, measured on the full-frame lossless S sample
    /// at scales 1, 0.5, 0.25 and 0.125: at most 3 columns and 2 rows.
    public static let spill = (columns: 4, rows: 2)

    /// How far the bad data still shows in a decode below full size, in its own pixels: a line
    /// whose nearer edge lies closer than this to the overrun carries some of it. Measured on the
    /// full-frame lossless S sample at 80 sizes from 600 to 3444 pixels, as each line's mean colour
    /// against the full-size decode area-resized: lines up to 2.34 columns and 2.74 rows from the
    /// overrun carry it, none from 3 on (docs/M3-auto.md, section 41).
    public static let scaledSpillReach = 3.0

    /// Where a decode at a reduced scale finds the picture the full-size decode keeps after the
    /// trim, so the frame view's picture covers exactly the file's area at exactly its own pixels.
    ///
    /// Everything is in the scaled decode's pixels as the sensor sees it, with y up as Core Image
    /// has it. Apple's decoder at scale s makes its output ceil(size × s) pixels and puts pixel
    /// (i, j) over the window's ((i + 0.5) / s, (j + 0.5) / s), counted from the window's
    /// bottom-left corner (measured on the full-frame lossless S sample; docs/M3-auto.md, section 41).
    public struct FilledPicture: Sendable, Equatable {
        /// The decode's scale: the trimmed full-size long side onto the picture's.
        public var scale: Float
        /// The picture's pixels, which start at column 0 and at row `bottom`.
        public var width: Int
        public var height: Int
        public var bottom: Int
        /// How far above their own centres the picture's rows sample the decode, within half a
        /// pixel, so they lie where the full-size picture's rows do once it is area-resized to the
        /// same pixels.
        public var rowPhase: Double
        /// The decode's pixels clear of the bad data (`scaledSpillReach`): the columns before
        /// `cleanWidth` and the rows from `cleanBottom` up.
        public var cleanWidth: Int
        public var cleanBottom: Int

        public init(scale: Float, width: Int, height: Int, bottom: Int, rowPhase: Double, cleanWidth: Int, cleanBottom: Int) {
            self.scale = scale
            self.width = width
            self.height = height
            self.bottom = bottom
            self.rowPhase = rowPhase
            self.cleanWidth = cleanWidth
            self.cleanBottom = cleanBottom
        }
    }

    /// The full-size decode's trimmed picture as a decode with its long side `longSide` pixels
    /// finds it, or `nil` when this mode has no trim on `layout`. A long side as long as the
    /// trimmed raw or longer gets the whole raw at full size, trimmed as a develop is.
    ///
    /// The trimmed picture's long side over `longSide` sets the scale, so its columns land on the
    /// decode's. Its lower edge lands between the decode's rows wherever the trimmed rows times
    /// the scale is not whole, hence `rowPhase`. Its height scaled can also end up to a third of a
    /// pixel off the picture's whole rows, as every scaled decode's does; the two are centred on
    /// each other, which leaves the picture's top and bottom rows within a sixth of a pixel of the
    /// file's. The trim at the reduced scale itself (`trim(for:scale:)`) drops more of the frame
    /// than the full size's, since the spill and the 3:2 rounding do not shrink with the scale: a
    /// frame view filled through it showed 0.2 percent less of the frame than the file, magnified
    /// to fit.
    public func filled(for layout: ARWLayout, longSide: Int) -> FilledPicture? {
        let full = trim(for: layout, scale: 1)
        guard full.columns > 0 || full.rows > 0, let origin = decoderCropOrigin, let valid = layout.validSize else {
            return nil
        }
        let kept = (width: layout.cropSize.width - full.columns, height: layout.cropSize.height - full.rows)
        let long = max(kept.width, kept.height)
        guard longSide < long else {
            return FilledPicture(scale: 1, width: kept.width, height: kept.height, bottom: full.rows, rowPhase: 0,
                                 cleanWidth: kept.width, cleanBottom: full.rows)
        }
        let scale = Float(max(1, longSide)) / Float(long)
        let s = Double(scale)
        let width = Int((Double(kept.width) * s).rounded()), height = Int((Double(kept.height) * s).rounded())
        // Where the picture's lower edge samples the decode: the trimmed picture's, moved by half
        // the difference between its scaled height and the picture's whole rows.
        let lowerEdge = Double(full.rows) * s + (Double(kept.height) * s - Double(height)) / 2
        let bottom = Int(lowerEdge.rounded())
        let overrunX = origin.x + layout.cropSize.width - valid.width
        let overrunY = origin.y + layout.cropSize.height - valid.height
        var cleanWidth = Int.max, cleanBottom = 0
        if overrunX > 0 {
            cleanWidth = Int((Double(layout.cropSize.width - overrunX) * s - Self.scaledSpillReach).rounded(.down))
        }
        if overrunY > 0 { cleanBottom = Int((Double(overrunY) * s + Self.scaledSpillReach).rounded(.up)) }
        // A picture of a few pixels keeps at least its first column and its top row.
        return FilledPicture(scale: scale, width: width, height: height, bottom: bottom, rowPhase: lowerEdge - Double(bottom),
                             cleanWidth: max(1, cleanWidth), cleanBottom: min(cleanBottom, bottom + height - 1))
    }

    static func aspectUnit(_ size: ARWLayout.Size) -> (x: Int, y: Int) {
        var a = size.width, b = size.height
        while b != 0 { (a, b) = (b, a % b) }
        guard a > 0 else { return (Int.max, Int.max) }
        return (size.width / a, size.height / a)
    }
}

/// The raw modes of the bodies Argent supports, keyed by the Exif model name.
public struct BodyProfile: Sendable {
    public var model: String
    public var modes: [RawMode]
    /// The sensor's noise and how Apple's decoder scales it, for taking the decoder's lift of
    /// dark noise out of auto development's measurement (`DecodedNoise`); `nil` when unknown.
    public var noise: BodyNoise?

    public init(model: String, modes: [RawMode], noise: BodyNoise? = nil) {
        self.model = model
        self.modes = modes
        self.noise = noise
    }

    /// The mode a layout was recorded in, or `nil` when this body has no such mode.
    public func mode(for layout: ARWLayout) -> RawMode? {
        modes.first { $0.encoding == layout.encoding && ($0.cropSize == nil || $0.cropSize == layout.cropSize) }
    }

    public static func named(_ model: String) -> BodyProfile? {
        all.first { $0.model == model }
    }

    public static let all: [BodyProfile] = [a7IV]

    /// The Sony a7 IV, measured on macOS 27.0 with decoder version 8 (docs/M1-spikes.md,
    /// docs/research/camera.md).
    ///
    /// Lossless M and S decode brighter than L and uncompressed for the same exposure, by
    /// +0.26 and +0.27 stops, because Apple renormalizes their white balance so no channel is
    /// attenuated: each CC0 frame read against its own camera JPEG, which takes the light's
    /// changes between the handheld frames out (M +0.260 to +0.264; S +0.267 to +0.282, full frame
    /// and APS-C; `RawModeMeasureTests`). The earlier +0.18 to +0.26 from aligned frames carried
    /// those changes. Lossy-compressed raw needs nothing: it reads within 0.02 stop of uncompressed
    /// against its own JPEG, in Apple's decode and LibRaw's alike, and the format's block coding
    /// can move a frame's mean by at most 0.006 stop (simulated on the CC0 uncompressed frame);
    /// the 0.13 to 0.15 stops it read darker on the samples was the light. Apple also places
    /// its output window at a fixed origin for each of them, ignoring the file's own crop:
    /// (4, 4) for M, harmlessly, and (32, 22) for S, the APS-C S origin, which on a
    /// full-frame S file runs 20 columns and 14 rows past its 3516 by 2344 of valid data.
    /// Verified against LibRaw's decode of both S files.
    ///
    /// RAW 9 takes the three Bayer modes, full frame and APS-C, and not lossless M or S, which
    /// store YCbCr: of the 76 a7 IV files here, the 74 in Bayer modes offer version 9 and the two in
    /// lossless M and S do not (macOS 27.0.1, measured; docs/decoder.md section 18).
    public static let a7IV = BodyProfile(model: "ILCE-7M4", modes: [
        RawMode(name: "uncompressed", encoding: .uncompressed, learned: true),
        RawMode(name: "compressed", encoding: .compressed, learned: true),
        RawMode(name: "lossless L", encoding: .losslessBayer, learned: true),
        RawMode(name: "lossless M", encoding: .losslessYCbCr, cropSize: .init(width: 4608, height: 3072),
                exposureStops: -0.26, decoderCropOrigin: .init(x: 4, y: 4)),
        RawMode(name: "lossless S", encoding: .losslessYCbCr, cropSize: .init(width: 3504, height: 2336),
                exposureStops: -0.27, decoderCropOrigin: .init(x: 32, y: 22)),
    ], noise: BodyNoise(
        shotAtISO100: 100 / 411.3,
        readLog2Electrons: [
            (100, 2.20), (200, 2.04), (320, 1.87), (400, 0.43), (800, 0.40), (1600, 0.40), (3200, 0.32),
            (6400, 0.29), (12800, 0.18), (25600, 0.15), (51200, 0.07),
        ],
        highGainISO: 400, unityGainISO: 411.3,
        decodedUnitsPerDN: SIMD3(3.5237e-4, 1.4227e-4, 2.2966e-4)))
}

/// A body's sensor noise, and how Apple's decoder scales its raw samples, in a profile's terms.
///
/// A sample `s` digital numbers above black varies by `shot * s + read` squared digital numbers
/// (`SensorNoise`). For the a7 IV: `readLog2Electrons` is PhotonsToPhotos' published input-referred
/// read noise of the ILCE-7M4 (https://www.photonstophotos.net/Charts/RN_e.htm, read 2026-10-07;
/// reported), in digital numbers through that chart's unity gain at ISO 411 (its `unityEv` of
/// 7.04), with the switch to the high conversion gain at ISO 400 a step; `shotAtISO100` is the same
/// unity gain's conversion gain, 100 / 411.3 digital numbers an electron, proportional to the ISO
/// (the chart's full well, 65,432 electrons, is the clip at 0.2426). With Poisson photon noise
/// these give DXOMARK's measured SNR at 18 percent of the clip within 0.2 dB from ISO 800 to 51200,
/// and within 0.7 dB from 100 to 400, where a pixel response non-uniformity of 0.38 percent accounts
/// for the rest (computed, docs/research/noise-and-hardware.md). Until 2026-10-07 the shot term was
/// 0.355, what `SensorNoise` reads from the CC0 sample at ISO 250, whose texture raises its
/// estimate: that model's frames carried 1.46 times the camera's variance (1.0 to 1.7 dB below
/// DXOMARK's SNR from ISO 100 to 51200), and on the CC0 APS-C frame at ISO 640 a copy of the ISO 250
/// sample made with it read 2.50 where the real frame reads 1.88, against 2.00 with this one
/// (measured). Below ISO 100 the gain stays at ISO 100's.
///
/// `decodedUnitsPerDN` is what one digital number of each channel becomes in the decode, for a
/// neutral, under `AppleRawDecoder`'s pins at a gain of `ExposureAnchor.gainStops()` and a mode
/// of no exposure correction: measured on flat neutral patches written into a copy of the CC0
/// uncompressed sample, decoded at 960 pixels and at full size alike (`DarkLevelMeasureTests
/// /decodedGain`); red against green 2.48 and blue 1.61, the D55 pin's white balance.
public struct BodyNoise: Sendable {
    public var shotAtISO100: Double
    public var readLog2Electrons: [(iso: Double, log2e: Double)]
    /// Where the read noise steps down to the high conversion gain's.
    public var highGainISO: Double
    public var unityGainISO: Double
    public var decodedUnitsPerDN: SIMD3<Float>

    public init(shotAtISO100: Double, readLog2Electrons: [(iso: Double, log2e: Double)], highGainISO: Double,
                unityGainISO: Double, decodedUnitsPerDN: SIMD3<Float>) {
        self.shotAtISO100 = shotAtISO100
        self.readLog2Electrons = readLog2Electrons
        self.highGainISO = highGainISO
        self.unityGainISO = unityGainISO
        self.decodedUnitsPerDN = decodedUnitsPerDN
    }

    /// The sensor noise at `iso`, in digital numbers.
    public func sensorNoise(iso: Double) -> SensorNoise {
        let gainISO = max(iso, readLog2Electrons.first?.iso ?? iso)
        return SensorNoise(shot: shotAtISO100 * gainISO / 100, read: read(iso: gainISO))
    }

    /// Read noise at `iso`, squared digital numbers: the table interpolated in stops, a step at
    /// the switch to high conversion gain, and the last entry's electrons beyond it.
    public func read(iso: Double) -> Double {
        let table = readLog2Electrons
        guard let first = table.first, let last = table.last else { return 0 }
        var log2e = last.log2e
        if iso <= first.iso {
            log2e = first.log2e
        } else if let index = table.indices.dropFirst().first(where: { iso <= table[$0].iso }) {
            let a = table[index - 1], b = table[index]
            if a.iso < highGainISO, b.iso >= highGainISO {
                log2e = iso < highGainISO ? a.log2e : b.log2e
            } else {
                log2e = a.log2e + (b.log2e - a.log2e) * log2(iso / a.iso) / log2(b.iso / a.iso)
            }
        }
        let electrons = exp2(log2e), gain = iso / unityGainISO
        return electrons * electrons * gain * gain
    }
}
