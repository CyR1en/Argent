import ArgentCore
import Foundation

/// ObjectClear's pipeline around its four graphs (docs/remove-plan.md, section 4.5): what `scripts/models/objectclear_reference.py`
/// computes between the networks, ported function by function, with the reference's name beside each. Tensors are planar and row
/// major, `N x C x H x W` with N = 1, in 32-bit floats. Where the pipeline held a half float, `half` rounds there, so a step given
/// its recorded inputs gives the recorded output exactly (`ObjectClearReferenceTests`).
///
/// `H` and `W` are the working size in pixels, `h = H / 8` and `w = W / 8` the latents'.
enum ObjectClear {
    /// `vae/config.json`'s scaling factor.
    static let scaling: Float = 0.13025
    /// The row of the text states the object's embedding replaces: the prompt's token "object".
    static let fuseIndex = 5
    static let tokens = 77
    static let stateWidth = 2048
    static let pooledWidth = 1280
    /// The object encoder's square.
    static let objectSide = 224
    /// Pixels a latent.
    static let latentScale = 8
    /// The working sizes the graphs take, each side a multiple of 16 (H1's conversion): the app plans its crops to them.
    static let sides = RemovalPatch.leastWorkingSide...RemovalPatch.longSideLimit

    /// Rounds to half precision and widens again: where the pipeline held a float16.
    @inline(__always) static func half(_ x: Float) -> Float { Float(Float16(x)) }

    static func half(_ values: [Float]) -> [Float] { values.map { Float(Float16($0)) } }

    // MARK: Pixels to tensors

    /// `picture_tensor`: `H x W x 3` bytes to `1 x 3 x H x W` in [-1, 1].
    static func pictureTensor(_ rgb: [UInt8], width: Int, height: Int) -> [Float] {
        let plane = width * height
        var out = [Float](repeating: 0, count: 3 * plane)
        rgb.withUnsafeBufferPointer { rgb in
            out.withUnsafeMutableBufferPointer { out in
                for p in 0..<plane {
                    for c in 0..<3 { out[c * plane + p] = Float(rgb[p * 3 + c]) / 255 * 2 - 1 }
                }
            }
        }
        return out
    }

    /// `mask_tensor`: 1 where the value over 255 is a half or more (128 and up).
    static func maskTensor(_ gray: [UInt8]) -> [Float] {
        gray.map { Float($0) / 255 >= 0.5 ? 1 : 0 }
    }

    /// `object_alone`: the picture where the mask is set, zero (mid grey) elsewhere.
    static func objectAlone(_ picture: [Float], mask: [Float]) -> [Float] {
        let plane = mask.count
        var out = picture
        for c in 0..<3 {
            for p in 0..<plane where !(mask[p] > 0.5) { out[c * plane + p] = picture[c * plane + p] * 0 }
        }
        return out
    }

    /// `mask_latents`: the mask's every eighth pixel from (0, 0), as F.interpolate's nearest does.
    static func maskLatents(_ mask: [Float], width: Int, height: Int) -> [Float] {
        let w = width / latentScale, h = height / latentScale
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { out[y * w + x] = mask[(y * latentScale) * width + x * latentScale] }
        }
        return out
    }

    // MARK: The object encoder's resize

    /// `_antialias_weights`: for each output sample, its first input and its normalised triangle weights.
    private static func antialiasWeights(from sizeIn: Int, to sizeOut: Int) -> [(first: Int, weights: [Double])] {
        let scale = Double(sizeIn) / Double(sizeOut), support = max(scale, 1)
        return (0..<sizeOut).map { i in
            let center = scale * (Double(i) + 0.5)
            let lo = max(Int(center - support + 0.5), 0), hi = min(Int(center + support + 0.5), sizeIn)
            var weights = (0..<(hi - lo)).map { j in max(0, 1 - abs((Double(j + lo) - center + 0.5) / support)) }
            let sum = numpySum(weights)
            weights = weights.map { $0 / sum }
            return (lo, weights)
        }
    }

    /// `resize_antialias`: `1 x C x H x W` to `1 x C x side x side` with a triangle filter as wide as the scale, columns then rows,
    /// in doubles as the reference sums them.
    static func resizeAntialias(_ x: [Float], channels: Int, width: Int, height: Int, side: Int = objectSide) -> [Float] {
        let columns = antialiasWeights(from: width, to: side), rows = antialiasWeights(from: height, to: side)
        var across = [Double](repeating: 0, count: channels * height * side)
        x.withUnsafeBufferPointer { x in
            for c in 0..<channels {
                for y in 0..<height {
                    let row = (c * height + y) * width
                    for (i, column) in columns.enumerated() {
                        var sum = 0.0
                        for (k, weight) in column.weights.enumerated() { sum += Double(x[row + column.first + k]) * weight }
                        across[(c * height + y) * side + i] = sum
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: channels * side * side)
        for c in 0..<channels {
            for (j, row) in rows.enumerated() {
                for i in 0..<side {
                    var sum = 0.0
                    for (k, weight) in row.weights.enumerated() { sum += across[(c * height + row.first + k) * side + i] * weight }
                    out[(c * side + j) * side + i] = Float(sum)
                }
            }
        }
        return out
    }

    /// NumPy's sum of a short row of doubles, so a weight divided by it is the reference's to the last bit: pairwise, by eight
    /// running sums when there are eight or more.
    static func numpySum(_ values: [Double]) -> Double {
        guard values.count >= 8 else { return values.reduce(0, +) }
        var r = Array(values[0..<8])
        var i = 8
        while i + 8 <= values.count {
            for k in 0..<8 { r[k] += values[i + k] }
            i += 8
        }
        var sum = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
        while i < values.count { sum += values[i]; i += 1 }
        return sum
    }

    /// `fuse_prompt`: the fused row in place of row `fuseIndex` of the fixed states.
    static func fusePrompt(_ states: [Float], row: [Float]) -> [Float] {
        var out = states
        out.replaceSubrange((fuseIndex * stateWidth)..<((fuseIndex + 1) * stateWidth), with: row)
        return out
    }

    // MARK: Latents

    /// `sample_latents`: the encoder's moments (`1 x 8 x h x w`, mean then log variance) sampled with `noise` and scaled.
    static func sampleLatents(moments: [Float], noise: [Float]) -> [Float] {
        let count = noise.count
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let mean = moments[i], logvar = min(max(moments[count + i], -30), 20)
            out[i] = half(half(mean + half(Foundation.exp(0.5 * logvar)) * noise[i]) * scaling)
        }
        return out
    }

    /// The first latents: the starting noise times the schedule's first factor.
    static func initialLatents(noise: [Float], factor: Float) -> [Float] {
        noise.map { half($0 * factor) }
    }

    /// `unet_sample`: the latents scaled for this sigma, the mask, the masked picture's latents: `1 x 9 x h x w`.
    static func unetSample(latents: [Float], sigma: Float, maskLatents: [Float], maskedPictureLatents: [Float]) -> [Float] {
        let divisor = Foundation.pow(sigma * sigma + 1, 0.5)
        var out = latents.map { half($0 / divisor) }
        out.reserveCapacity(9 * maskLatents.count)
        out += maskLatents
        out += maskedPictureLatents
        return out
    }

    /// `guide`: the unconditional prediction moved `guidance` times the way the conditional one points.
    static func guide(unconditional: [Float], conditional: [Float], guidance: Float) -> [Float] {
        zip(unconditional, conditional).map { u, c in half(u + half(guidance * half(c - u))) }
    }

    /// `euler_step`: `x + eps * (sigma_next - sigma)` as the scheduler computes it, `sigma * eps` in half and the rest in floats.
    static func eulerStep(latents: [Float], noise: [Float], sigma: Float, next: Float) -> [Float] {
        let delta = next - sigma
        return zip(latents, noise).map { x, eps in
            let denoised = x - half(sigma * eps)
            return half(x + (x - denoised) / sigma * delta)
        }
    }

    /// `after_first_step`: at step 0 only, outside the mask the latents are the picture's again, at the noise the next step expects.
    static func afterFirstStep(_ stepped: [Float], pictureLatents: [Float], noise: [Float], nextSigma: Float, maskLatents: [Float]) -> [Float] {
        let plane = maskLatents.count, sigma = half(nextSigma)
        return (0..<stepped.count).map { i in
            let noised = half(pictureLatents[i] + half(noise[i] * sigma))
            let m = maskLatents[i % plane]
            return half(half((1 - m) * noised) + half(m * stepped[i]))
        }
    }

    // MARK: Outputs

    /// The attention map the pipeline returns, at the latents' size, from the UNet's reduced output (`1 x 1 x h/2 x w/2`, the mean of
    /// its heads at the object's token): twice the size, stretched to its range, times 255 in half precision and truncated. `nil`
    /// when the map is flat, which has no range to stretch.
    static func attentionBytes(_ reduced: [Float], latentWidth w: Int, latentHeight h: Int) -> [UInt8]? {
        let up = upsampleBilinear2x(half(reduced), width: w / 2, height: h / 2).map(half)
        guard let lo = up.min(), let hi = up.max(), hi > lo, lo.isFinite, hi.isFinite else { return nil }
        let range = hi - lo
        return up.map { value in
            let stretched = half((value - lo) / range)
            return UInt8(half(stretched * 255))
        }
    }

    /// `_upsample_bilinear_2x`: F.interpolate at scale 2, bilinear, `align_corners` false.
    static func upsampleBilinear2x(_ x: [Float], width: Int, height: Int) -> [Float] {
        func axis(_ n: Int) -> [(Int, Int, Float)] {
            (0..<(2 * n)).map { i in
                let source = max((Double(i) + 0.5) / 2 - 0.5, 0)
                let i0 = Int(source.rounded(.down))
                return (i0, min(i0 + 1, n - 1), Float(source - Double(i0)))
            }
        }
        let rows = axis(height), columns = axis(width)
        var top = [Float](repeating: 0, count: 2 * height * width)
        for (r, (r0, r1, t)) in rows.enumerated() {
            for c in 0..<width { top[r * width + c] = x[r0 * width + c] * (1 - t) + x[r1 * width + c] * t }
        }
        var out = [Float](repeating: 0, count: 4 * height * width)
        for r in 0..<(2 * height) {
            for (c, (c0, c1, t)) in columns.enumerated() {
                out[r * 2 * width + c] = top[r * width + c0] * (1 - t) + top[r * width + c1] * t
            }
        }
        return out
    }

    /// `picture_bytes`: the decoder's `1 x 3 x H x W`, about [-1, 1], to `H x W x 3` bytes: `x / 2 + 0.5` clamped in half
    /// precision, times 255, rounded half to even.
    static func pictureBytes(_ decoded: [Float], width: Int, height: Int) -> [UInt8] {
        let plane = width * height
        var out = [UInt8](repeating: 0, count: 3 * plane)
        decoded.withUnsafeBufferPointer { decoded in
            for c in 0..<3 {
                for p in 0..<plane {
                    let unit = min(max(half(half(decoded[c * plane + p] / 2) + 0.5), 0), 1)
                    out[p * 3 + c] = UInt8((unit * 255).rounded(.toNearestOrEven))
                }
            }
        }
        return out
    }
}

/// The Euler scheduler as the pipeline configures it (`schedule`): `scaled_linear` betas 0.00085 to 0.012 over 1000 steps,
/// "leading" spacing with an offset of 1.
struct EulerSchedule: Equatable {
    let timesteps: [Float]
    /// One more than the steps: the last is 0.
    let sigmas: [Float]
    /// What the first noise is multiplied by.
    let initialFactor: Float

    init(timesteps: [Float], sigmas: [Float], initialFactor: Float) {
        self.timesteps = timesteps; self.sigmas = sigmas; self.initialFactor = initialFactor
    }

    init(steps: Int) {
        // torch.linspace in floats: from the start up to the middle, from the end down after it.
        let lo = Float(Foundation.pow(0.00085, 0.5)), hi = Float(Foundation.pow(0.012, 0.5))
        let step = (hi - lo) / Float(999)
        var cumulative: Float = 1
        var all = [Float](repeating: 0, count: 1000)
        for i in 0..<1000 {
            let n = Float(i)
            let root = i < 500 ? lo + step * n : hi - step * (Float(999) - n)
            let beta = root * root
            cumulative *= 1 - beta
            all[i] = ((1 - cumulative) / cumulative).squareRoot()
        }
        let spacing = 1000 / steps
        timesteps = (0..<steps).reversed().map { Float($0 * spacing + 1) }
        // The timesteps are whole numbers, where np.interp reads the table exactly.
        sigmas = timesteps.map { all[Int($0)] } + [0]
        initialFactor = Foundation.pow(sigmas[0] * sigmas[0] + 1, 0.5)
    }
}

/// The three normal draws of a job, from its seed: the picture's latent sample, the starting noise, the masked picture's latent
/// sample, in that order, as the pipeline draws them from one generator. Not torch's generator: a removal is stored as pixels, so
/// only this engine's own runs need agree, and a seed gives the same draws on every Mac.
struct NoiseDraws {
    private var state: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        var mixer = seed
        func next() -> UInt64 {
            mixer &+= 0x9E37_79B9_7F4A_7C15
            var z = mixer
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        state = (next(), next(), next(), next())
    }

    /// xoshiro256**.
    private mutating func next() -> UInt64 {
        let result = ((state.1 &* 5) << 7 | (state.1 &* 5) >> 57) &* 9
        let t = state.1 << 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = state.3 << 45 | state.3 >> 19
        return result
    }

    /// `count` standard normal values, Box and Muller's, rounded to half floats as the pipeline draws them.
    mutating func normal(_ count: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(count + 1)
        while out.count < count {
            // (0, 1]: the logarithm never sees zero.
            let u1 = (Double(next() >> 11) + 1) / 9_007_199_254_740_992
            let u2 = Double(next() >> 11) / 9_007_199_254_740_992
            let radius = (-2 * Foundation.log(u1)).squareRoot(), angle = 2 * Double.pi * u2
            out.append(ObjectClear.half(Float(radius * Foundation.cos(angle))))
            out.append(ObjectClear.half(Float(radius * Foundation.sin(angle))))
        }
        return Array(out.prefix(count))
    }
}
