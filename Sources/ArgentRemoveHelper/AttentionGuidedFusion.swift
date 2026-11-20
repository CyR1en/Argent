import Foundation

/// ObjectClear's attention-guided fusion (`objectclear/utils/attention_guided_fusion.py`, `attention_guided_fusion` in the
/// reference) and the resize that brings its attention map to the working size: what turns the decoder's picture into the
/// engine's `out.png` and `attn.png`. Inside the attention map the decoder's picture; outside it the input's detail over the
/// decoder's colour, by five levels of a wavelet split. The reference's OpenCV and SciPy filters are written out, in the
/// precision each computes in.
enum AttentionGuidedFusion {
    /// `attention_guided_fusion`: `original` and `removed` are `H x W x 3` bytes, `attention` the map at the latents' size.
    static func fuse(original: [UInt8], removed: [UInt8], attention: [UInt8], width: Int, height: Int) -> [UInt8] {
        let plane = width * height, scale = ObjectClear.latentScale, latentWidth = width / scale
        // cv2.threshold is strict; each latent repeated over its 8 x 8 pixels.
        var inside = [Float](repeating: 0, count: plane)
        for y in 0..<height {
            for x in 0..<width where attention[(y / scale) * latentWidth + x / scale] > 128 { inside[y * width + x] = 1 }
        }
        let blurred = gaussian9(dilateEllipse21(inside, width: width, height: height), width: width, height: height)
        let merged = (0..<plane).map { min(max(max(inside[$0], blurred[$0]), 0), 1) }

        var content = [Float](repeating: 0, count: 3 * plane), style = content
        for p in 0..<plane {
            let keep = 1 - inside[p]
            for c in 0..<3 {
                content[c * plane + p] = Float(original[p * 3 + c]) * keep / 255
                style[c * plane + p] = Float(removed[p * 3 + c]) * keep / 255
            }
        }
        let high = waveletSplit(content, channels: 3, width: width, height: height).high
        let low = waveletSplit(style, channels: 3, width: width, height: height).low

        var out = [UInt8](repeating: 0, count: 3 * plane)
        for p in 0..<plane {
            let m = merged[p]
            for c in 0..<3 {
                let wave = Float(UInt8(min(max((high[c * plane + p] + low[c * plane + p]) * 255, 0), 255)))
                out[p * 3 + c] = UInt8(wave * (1 - m) + Float(removed[p * 3 + c]) * m)
            }
        }
        return out
    }

    // MARK: The wavelet split

    /// `_wavelet_split`: five levels, radius 1, 2, 4, 8 and 16; the detail summed, and what is left.
    static func waveletSplit(_ x: [Float], channels: Int, width: Int, height: Int) -> (high: [Float], low: [Float]) {
        var high = [Float](repeating: 0, count: x.count), current = x
        for level in 0..<5 {
            let low = waveletBlur(current, channels: channels, width: width, height: height, radius: 1 << level)
            for i in 0..<x.count { high[i] += current[i] - low[i] }
            current = low
        }
        return (high, current)
    }

    /// `_wavelet_blur`: the 3 x 3 blur, and for a radius above 1 a linear shrink to `1 / radius` and back.
    static func waveletBlur(_ x: [Float], channels: Int, width: Int, height: Int, radius: Int) -> [Float] {
        let y = blur3(x, channels: channels, width: width, height: height)
        guard radius > 1 else { return y }
        let smallHeight = Int((Double(height) / Double(radius)).rounded(.toNearestOrEven))
        let smallWidth = Int((Double(width) / Double(radius)).rounded(.toNearestOrEven))
        let small = zoomLinear(y, channels: channels, width: width, height: height, toWidth: smallWidth, toHeight: smallHeight)
        return zoomLinear(small, channels: channels, width: smallWidth, height: smallHeight, toWidth: width, toHeight: height)
    }

    /// `_blur3`: scipy.ndimage.convolve with `[1 2 1; 2 4 2; 1 2 1] / 16`, the edge repeated, summed in doubles in the reference's order.
    static func blur3(_ x: [Float], channels: Int, width: Int, height: Int) -> [Float] {
        let kernel: [Double] = [0.0625, 0.125, 0.0625, 0.125, 0.25, 0.125, 0.0625, 0.125, 0.0625]
        var out = [Float](repeating: 0, count: x.count)
        x.withUnsafeBufferPointer { x in
            out.withUnsafeMutableBufferPointer { out in
                for c in 0..<channels {
                    let base = c * width * height
                    for y in 0..<height {
                        let rows = (max(y - 1, 0), y, min(y + 1, height - 1))
                        for column in 0..<width {
                            let left = max(column - 1, 0), right = min(column + 1, width - 1)
                            var sum = 0.0
                            for (dy, row) in [rows.0, rows.1, rows.2].enumerated() {
                                let r = base + row * width
                                sum += Double(x[r + left]) * kernel[dy * 3]
                                sum += Double(x[r + column]) * kernel[dy * 3 + 1]
                                sum += Double(x[r + right]) * kernel[dy * 3 + 2]
                            }
                            out[base + y * width + column] = Float(sum)
                        }
                    }
                }
            }
        }
        return out
    }

    /// `_zoom_linear`: scipy.ndimage.zoom with order 1, the corners of input and output aligned, in doubles.
    static func zoomLinear(_ x: [Float], channels: Int, width: Int, height: Int, toWidth: Int, toHeight: Int) -> [Float] {
        func axis(_ sizeIn: Int, _ sizeOut: Int) -> [(Int, Int, Double)] {
            (0..<sizeOut).map { i in
                let source = sizeOut > 1 ? Double(i) * (Double(sizeIn - 1) / Double(sizeOut - 1)) : 0
                let i0 = min(Int(source.rounded(.down)), sizeIn - 1)
                return (i0, min(i0 + 1, sizeIn - 1), source - Double(i0))
            }
        }
        let rows = axis(height, toHeight), columns = axis(width, toWidth)
        var out = [Float](repeating: 0, count: channels * toWidth * toHeight)
        var across = [Double](repeating: 0, count: width)
        x.withUnsafeBufferPointer { x in
            for c in 0..<channels {
                let base = c * width * height
                for (j, (r0, r1, t)) in rows.enumerated() {
                    for i in 0..<width { across[i] = Double(x[base + r0 * width + i]) * (1 - t) + Double(x[base + r1 * width + i]) * t }
                    let target = (c * toHeight + j) * toWidth
                    for (i, (c0, c1, s)) in columns.enumerated() { out[target + i] = Float(across[c0] * (1 - s) + across[c1] * s) }
                }
            }
        }
        return out
    }

    // MARK: The mask's edge

    /// `_dilate_ellipse21`: cv2.dilate by the 21 x 21 ellipse, the greatest value under it, the picture's outside ignored.
    static func dilateEllipse21(_ x: [Float], width: Int, height: Int) -> [Float] {
        // Each row of the ellipse spans its own half-width: the greatest value within each reach along a row, made from the
        // reach one shorter, then the greatest over the rows.
        let reaches = (-10...10).map { dy in Int((10 * (Double(100 - dy * dy) / 100).squareRoot()).rounded(.toNearestOrEven)) }
        var spans = [x]
        for reach in 1...10 {
            let shorter = spans[reach - 1]
            var span = shorter
            for y in 0..<height {
                let row = y * width
                for column in 0..<width {
                    if column >= reach { span[row + column] = max(span[row + column], x[row + column - reach]) }
                    if column + reach < width { span[row + column] = max(span[row + column], x[row + column + reach]) }
                }
            }
            spans.append(span)
        }
        var out = [Float](repeating: -.infinity, count: x.count)
        for (index, reach) in reaches.enumerated() {
            let dy = index - 10, span = spans[reach]
            for y in max(-dy, 0)..<min(height - dy, height) {
                for column in 0..<width { out[y * width + column] = max(out[y * width + column], span[(y + dy) * width + column]) }
            }
        }
        return out
    }

    /// `_gaussian9`: cv2.GaussianBlur with 9 taps of sigma 2 a side, the border mirrored without repeating the edge, in doubles.
    static func gaussian9(_ x: [Float], width: Int, height: Int) -> [Float] {
        var kernel = (0..<9).map { Foundation.exp(-Double(($0 - 4) * ($0 - 4)) / 8) }
        let sum = ObjectClear.numpySum(kernel)
        kernel = kernel.map { Double(Float($0 / sum)) }
        func mirror(_ i: Int, _ n: Int) -> Int {
            var i = i
            if i < 0 { i = -i }
            if i >= n { i = 2 * (n - 1) - i }
            return i
        }
        var rows = [Double](repeating: 0, count: x.count)
        for y in 0..<height {
            for column in 0..<width {
                var total = 0.0
                for k in 0..<9 { total += Double(x[y * width + mirror(column + k - 4, width)]) * kernel[k] }
                rows[y * width + column] = total
            }
        }
        var out = [Float](repeating: 0, count: x.count)
        for y in 0..<height {
            for column in 0..<width {
                var total = 0.0
                for k in 0..<9 { total += rows[mirror(y + k - 4, height) * width + column] * kernel[k] }
                out[y * width + column] = Float(total)
            }
        }
        return out
    }

    // MARK: The attention map's resize

    /// `resize_bicubic_u8`: Pillow's `resize` of an 8-bit grey picture with its default bicubic, 22-bit fixed point, columns then
    /// rows, each pass rounded to 8 bits. How `run_oc.py` brings the attention map to the working size.
    static func resizeBicubic(_ gray: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        let columns = pillowCoefficients(from: width, to: toWidth), rows = pillowCoefficients(from: height, to: toHeight)
        var across = [Int](repeating: 0, count: height * toWidth)
        for y in 0..<height {
            for (i, column) in columns.enumerated() {
                var sum = 0
                for (k, weight) in column.weights.enumerated() { sum += Int(gray[y * width + column.first + k]) * weight }
                across[y * toWidth + i] = min(max((sum + (1 << 21)) >> 22, 0), 255)
            }
        }
        var out = [UInt8](repeating: 0, count: toWidth * toHeight)
        for (j, row) in rows.enumerated() {
            for i in 0..<toWidth {
                var sum = 0
                for (k, weight) in row.weights.enumerated() { sum += across[(row.first + k) * toWidth + i] * weight }
                out[j * toWidth + i] = UInt8(min(max((sum + (1 << 21)) >> 22, 0), 255))
            }
        }
        return out
    }

    private static func bicubic(_ x: Double) -> Double {
        let x = abs(x), a = -0.5
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }

    private static func pillowCoefficients(from sizeIn: Int, to sizeOut: Int) -> [(first: Int, weights: [Int])] {
        let scale = Double(sizeIn) / Double(sizeOut), filterScale = max(scale, 1), support = 2 * filterScale
        return (0..<sizeOut).map { i in
            let center = (Double(i) + 0.5) * scale
            let lo = max(Int(center - support + 0.5), 0), hi = min(Int(center + support + 0.5), sizeIn)
            var weights = (0..<(hi - lo)).map { j in bicubic((Double(j + lo) - center + 0.5) / filterScale) }
            let sum = ObjectClear.numpySum(weights)
            weights = weights.map { $0 / sum }
            return (lo, weights.map { $0 < 0 ? Int(-0.5 + $0 * Double(1 << 22)) : Int(0.5 + $0 * Double(1 << 22)) })
        }
    }
}
