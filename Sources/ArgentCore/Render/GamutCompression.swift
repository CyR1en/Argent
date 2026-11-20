import Foundation

/// ACES Reference Gamut Compression v1.0's curve, with Argent's scene threshold and limits.
/// See https://github.com/ampas/aces-dev/blob/v1.3/transforms/ctl/lmt/LMT.Academy.ReferenceGamutCompress.ctl.
/// Limits come from the CIE 1931 2-degree locus in Rec.2020, derived and pinned in
/// bake/argent_bake/gamut.py. Applied before Negative LUT log encoding, never to the print.
public enum GamutCompression {
    public static let threshold: Float = 0.90
    public static let power: Float = 1.2
    public static let limits = SIMD3<Float>(1.3964, 1.1686, 1.0246)

    public static func compress(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let ach = rgb.max()
        guard ach > 0 else { return rgb }
        var result = rgb
        for channel in 0..<3 {
            let distance = (ach - rgb[channel]) / abs(ach)
            guard distance > threshold else { continue }
            let width = limits[channel] - threshold
            let scale = width / pow(pow((1 - threshold) / width, -power) - 1, 1 / power)
            let nd = (distance - threshold) / scale
            let cd = threshold + scale * nd / pow(1 + pow(nd, power), 1 / power)
            result[channel] = ach - cd * abs(ach)
        }
        return result
    }
}
