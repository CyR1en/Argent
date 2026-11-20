import Foundation

/// Capture sharpening: one mild unsharp mask on the dye amounts after the Negative LUT and
/// before grain, so grain is never sharpened and the paper's curve shapes the result
/// (docs/M3-auto.md, section 7).
///
/// It takes back some of the softness of the sensor, the demosaic and the lens, which lives at
/// the sensor's pixel scale, so the mask's blur is a fixed size in sensor pixels and follows
/// the render's scale: a decode at a quarter of the sensor's pixels gets a blur a quarter as
/// wide, the same filter at every frequency both renders can show. The blur is Lindeberg's
/// discrete Gaussian, whose variance is exactly sigma squared at any sigma, so a 0.2-pixel blur
/// at the contact sheet's scale is the same filter and not a rounding of it.
///
/// A smaller picture should look as sharp as the full-size develop area-resized to it, and
/// Apple's decoder, asked for a scaled decode in draft mode, returns one softer than that, by
/// about a fixed blur in its own pixels (measured). So a draft decode also gets a second mask
/// fixed in the decode's pixels, which takes that blur out; a decode above draft mode is as sharp
/// as the area-resized develop already, and a full-size decode needs nothing. RAW 9's scaled decodes
/// run without draft mode, as sharp as its develop area-resized, and get no such mask
/// (`AppleRawDecoder.draftMode`).
///
/// The mask works on a luminance of the dye amounts and adds the same detail to all three
/// layers, which is a change in neutral density: edges gain contrast without colour fringes, and
/// the blue layer's noise, the worst of the three, barely enters. A soft threshold leaves detail
/// smaller than the decode's noise mostly alone.
public enum CaptureSharpening {
    /// One unsharp mask: its blur, a Gaussian's sigma in the render's pixels, and the share of
    /// the detail it adds back.
    public struct Mask: Sendable, Equatable {
        public var sigma: Float
        public var amount: Float

        public init(sigma: Float, amount: Float) {
            self.sigma = sigma
            self.amount = amount
        }
    }

    /// The sensor's mask at full size: its sigma in sensor pixels, the blur a Gaussian step fits on
    /// a sharp edge of the full-size decode of the CC0 samples (1.10 to 1.84 px over three frames,
    /// median 1.15) rounded down to a tenth, and a round amount (docs/provenance.md).
    public static let sensor = Mask(sigma: 1.1, amount: 1.0)
    /// The mask for Apple's scaling in draft mode (scales up to a half), in the decode's own
    /// pixels: of the masks that bring a scaled decode's finest detail nearest the develop
    /// area-resized to its size on the CC0 samples, the one with the smallest amount. Above draft
    /// mode a scaled decode needs none (docs/provenance.md; docs/M3-auto.md, section 9).
    public static let draftScaling = Mask(sigma: 0.6, amount: 1.0)
    /// Detail below about this much luminance, in normalized dye amounts, is mostly left alone: the
    /// smallest of 0.002, 0.004, 0.006 and 0.009 at which the sensor's mask raises the L* noise of
    /// flat patches by under 10 percent, without grain, on the CC0 sample simulated at ISO 3200
    /// (8.6 percent, measured; docs/provenance.md).
    public static let threshold: Float = 0.009
    /// The widest kernel the shader takes, in taps either side; `SHARPEN_MAX_RADIUS` in the
    /// Metal source.
    public static let maxRadius = 6
    /// The kernel is cut where less than this much of its weight lies beyond.
    static let tailMass = 1e-3

    /// The two masks for `frame`: the sensor's at the frame's scale against the sensor's pixels,
    /// and the one for Apple's scaling, `nil` for a frame not decoded in draft mode. A frame
    /// resized after its decode, as the contact sheet's can be from the frame view's, carries
    /// the decoder's blur shrunk by the resize, and its mask shrinks with it.
    public static func masks(for frame: LinearFrame) -> (sensor: Mask, scaling: Mask?) {
        masks(for: frame, sensor: sensor, draftScaling: draftScaling)
    }

    /// The same for other constants, which the measurements that choose them sweep.
    static func masks(for frame: LinearFrame, sensor base: Mask, draftScaling draft: Mask) -> (sensor: Mask, scaling: Mask?) {
        let sensor = Mask(sigma: base.sigma * frame.scale, amount: base.amount)
        guard let pins = frame.pins, pins.draftMode, pins.scale < 1, pins.scale > 0 else { return (sensor, nil) }
        return (sensor, Mask(sigma: draft.sigma * min(1, frame.scale / pins.scale), amount: draft.amount))
    }

    /// A mask's blur, normalized, `2r + 1` taps; one tap where the blur is too small to matter.
    public static func kernel(sigma: Float) -> [Float] {
        let t = Double(sigma) * Double(sigma)
        guard t > 1e-4 else { return [1] }
        // T(n; t) = e^-t I_n(t), the modified Bessel function of the first kind.
        var taps: [Double] = []
        var outside = 1.0
        for n in 0...maxRadius {
            let value = exp(-t) * besselI(n, t)
            taps.append(value)
            outside -= n == 0 ? value : 2 * value
            if outside < tailMass { break }
        }
        let side: [Double] = Array(taps.dropFirst().reversed()) + taps
        let total = side.reduce(0, +)
        return side.map { Float($0 / total) }
    }

    /// I_n(t) by its series, the sum over k of (t/2)^(2k+n) / (k! (k+n)!).
    static func besselI(_ n: Int, _ t: Double) -> Double {
        let half = t / 2
        var term = pow(half, Double(n)) / tgamma(Double(n + 1))
        var sum = term
        var k = 0
        while term > 1e-17 * sum, k < 100 {
            k += 1
            term *= half * half / (Double(k) * Double(k + n))
            sum += term
        }
        return sum
    }

    /// The soft threshold: detail well above `threshold` passes whole, detail well below it
    /// goes as its cube, so noise is not raised.
    public static func cored(_ detail: Float, threshold: Float = threshold) -> Float {
        let squared = detail * detail
        return detail * squared / max(squared + threshold * threshold, 1e-20)
    }
}
