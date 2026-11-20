import Foundation

// A smart selection's Feather (the owner's decision 19, plan section 12): Lightroom gave its AI masks Feather in 15.5 because their edges
// looked cut out (R1). Argent's refined edges do not look cut out at ±1.5 EV (S3), so Feather here is a choice of look: a softer edge.
//
// It is a Gaussian blur of the selection's refined coverage, after refinement, with a standard deviation in long sides, so it covers the
// same part of the picture on every render. It runs on the 2048 slice's refined field (`MaskRefinementSession.field(for:)`), so the
// develop and every preview blur the same field the same way. A blur has no per-pixel form: the refined value at a pixel comes from that
// pixel's own light, and a blurred one from its neighbours' (S3: a blurred mask adds a glow and cannot use tier 2's per-pixel refinement).
// So a feathered selection reads its slice (tier 1) on every surface, alone or composed (`MaskRefiner.perPixelSelection`).
//
// Feather 0 is no blur and no change: the field, the tier and every byte are as they were before Feather existed. Its constants are part
// of masks compiler 2026-11-06-1's meaning. They changed once before masks reached main (the owner's decision 21); from that merge on,
// changing them is a new compiler (rule 6).

/// The blur a smart selection's Feather means.
public enum MaskFeather {
    /// The standard deviation at Feather 100, in long sides: 17.5 px at 7008, 5.1 texels of the 2048 slice. The owner chose it
    /// (decision 21) from sheets of Feather 100 at σ 18, 35, 70, 140 and 280 px at 7008, Sky at −1.5 EV on DSC04108 and a Person at
    /// +0.7 EV on DSC04059: "A is good enough". From about 70 px a lighter band of sky rims the ridge and the brightening spills onto
    /// what stands in front of the person, a halo (task K).
    public static let sigmaAt100: Float = 0.0025
    /// σ grows in proportion to Feather: Feather 25 is σ 4.4 px at 7008, 50 is 8.8 px, 100 is 17.5 px. A square curve would leave the
    /// slider's first third under half a texel of the slice, where a blur shows nothing past the slice's own look.
    public static let exponent: Float = 1
    /// How far the kernel reaches, in standard deviations: past it a Gaussian's weight is under 0.04 % of its peak.
    static let reach: Float = 4
    /// The most texels a kernel reaches on one side, far past any σ of `sigmaAt100` on a 2048 slice: it bounds the weights the kernel
    /// is handed (`setBytes`, 4 KB).
    static let maximumRadius = 1000

    /// σ in long sides for `feather`, 0 to 100: 0 at 0, `sigmaAt100` at 100.
    public static func sigma(_ feather: Float) -> Float {
        let f = min(max(feather, SmartSelection.featherRange.lowerBound), SmartSelection.featherRange.upperBound) / 100
        return sigmaAt100 * pow(f, exponent)
    }

    /// One side of the kernel for a standard deviation of `sigma` texels: `weights[0]` at the texel, `weights[i]` at ±i, summing to 1
    /// over both sides. A σ under a hundredth of a texel is no blur, `[1]`.
    static func weights(sigma: Float) -> [Float] {
        guard sigma >= 0.01 else { return [1] }
        let radius = min(maximumRadius, max(1, Int((Double(reach) * Double(sigma)).rounded(.up))))
        let s = Double(sigma)
        let raw = (0...radius).map { exp(-Double($0 * $0) / (2 * s * s)) }
        let total = raw[0] + 2 * raw.dropFirst().reduce(0, +)
        return raw.map { Float($0 / total) }
    }

    /// σ in texels of a field of `size` on each axis, for `feather`: the long sides a texel spans differ by the slice's rounding.
    static func texelSigma(_ feather: Float, size: MaskFieldSize) -> SIMD2<Float> {
        sigma(feather) / size.texelToPoint
    }

    /// `values`, `width` by `height` in either row order, blurred as the kernel blurs a field: a pass along rows, then one along columns,
    /// each with its edges held (a texel past the side reads the side's), in `Float`, summed in the kernel's order. For tests and for the
    /// overlay's seed before a decode is held.
    public static func blurred(_ values: [Float], width: Int, height: Int, sigmaX: Float, sigmaY: Float) -> [Float] {
        precondition(values.count == width * height, "a plane is width times height values")
        let across = pass(values, width: width, height: height, weights: weights(sigma: sigmaX), vertical: false)
        return pass(across, width: width, height: height, weights: weights(sigma: sigmaY), vertical: true)
    }

    /// `values` blurred for a picture of `width` by `height` at `feather`: σ is in long sides, so `max(width, height)` pixels to one.
    public static func blurred(_ values: [Float], width: Int, height: Int, feather: Float) -> [Float] {
        guard feather > 0 else { return values }
        let s = sigma(feather) * Float(max(width, height))
        return blurred(values, width: width, height: height, sigmaX: s, sigmaY: s)
    }

    private static func pass(_ values: [Float], width: Int, height: Int, weights: [Float], vertical: Bool) -> [Float] {
        guard weights.count > 1 else { return values }
        var out = [Float](repeating: 0, count: values.count)
        values.withUnsafeBufferPointer { v in
            for y in 0..<height {
                for x in 0..<width {
                    var sum = weights[0] * v[y * width + x]
                    for i in 1..<weights.count {
                        let a: Float, b: Float
                        if vertical {
                            a = v[max(y - i, 0) * width + x]; b = v[min(y + i, height - 1) * width + x]
                        } else {
                            a = v[y * width + max(x - i, 0)]; b = v[y * width + min(x + i, width - 1)]
                        }
                        sum += weights[i] * (a + b)
                    }
                    out[y * width + x] = sum
                }
            }
        }
        return out
    }
}
