import Foundation

/// Where a correctly metered mid-tone lands in a linear decode, and the gain that moves
/// it to the 0.18 the film model expects.
///
/// Raw counts already carry ISO times exposure, so the photographer's metering is in the
/// pixel. Sony meters middle gray about 3.6 stops under saturation of the green channel,
/// and Apple's linear decode at `baselineExposure` 0 puts a metered mid-tone near 0.080.
/// Left alone, a correctly metered frame reaches the Negative LUT about a stop dark.
///
/// The a7 IV states its ISO as a recommended exposure index (Sony's specification; Exif
/// SensitivityType 2 in every file), which CIPA DC-004 defines by an average focal-plane
/// exposure of 10/ISO lux-seconds for a uniform subject. At DXOMARK's measured saturation, ISO 68
/// at a setting of 100, and the decode's green full scale of 1.0035, that puts a metered mid-tone
/// at 0.088. The camera's own JPEG of each CC0 frame puts sRGB 118, 18 percent, at 0.082; four
/// other Sony bodies' JPEGs sit 0.21 to 0.29 stops under their own such prediction, which here
/// would give 0.074. Which reading of that gap is right, the meter's or the rendering's, needs a
/// gray-card raw; 0.080 is the middle of the bracket and good to about 0.15 EV. See
/// docs/research/camera.md, section 1.
public enum ExposureAnchor {
    /// A metered mid-tone in a decode with `baselineExposure` 0, at ISO 100 or above.
    public static let decodedMidTone: Float = 0.080
    /// A metered mid-tone as the film model expects it.
    public static let filmMidGray: Float = 0.18

    /// Stops to add so that a metered mid-tone decodes to `filmMidGray`.
    ///
    /// Below ISO 100 the sensor keeps ISO 100's gain, so the same metering leaves a raw
    /// value brighter by 100/ISO: ISO 100 is the a7 IV's lowest standard setting and 50 an
    /// extended one in Sony's specification. Checked at ISO 50 on two bodies, on sets the
    /// project may evaluate on but not choose constants on: the decoded green is 1.97 times ISO
    /// 100's on the a7 IV and 2.007 times on the A7C (docs/M1-spikes.md, docs/provenance.md).
    /// ISO 64 and 80 are in no obtainable corpus and remain inference.
    public static func gainStops(baselineExposure: Float = 0, iso: Float? = nil) -> Float {
        var lowISOStops: Float = 0
        if let iso, iso > 0 {
            lowISOStops = max(0, log2(100 / iso))
        }
        return log2(filmMidGray / decodedMidTone) - baselineExposure - lowISOStops
    }
}
