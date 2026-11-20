import Foundation

/// The job's steps: the crop at the working size, its gain and curve, and the masks' own resampling and growth
/// (docs/remove-plan.md, section 4.4, steps 3 to 5 and 7). Each is the prototype's function it names, in its order of
/// operations, so a job equals what the research gave the model.
extension RemovalPipeline {
    /// The median is taken over every eleventh pixel of the crop (P).
    static let medianStride = 11
    /// A crop darker than this is given the gain of one this bright, so a black crop is not multiplied without end (P).
    static let medianFloor: Float = 1e-4
    /// Where the curve's shoulder would reach display white, in multiples of it (P: `shoulderWhite`).
    static let shoulderWhite: Float = 6

    /// Pointers for a loop over rows, each writing its own.
    private struct Rows: @unchecked Sendable {
        let source: UnsafePointer<Float16>
        let out: UnsafeMutablePointer<Float>
        let columns: UnsafePointer<Range<Int>>
    }

    /// The crop's pixels under one working pixel along one side, from `first`, each with the part of the working pixel it is:
    /// the parts add to one.
    private struct Shares: Sendable {
        let first: Int
        let parts: [Float]
    }

    /// Pointers for the area mean's loop over rows.
    private struct SharedRows: @unchecked Sendable {
        let source: UnsafePointer<Float16>
        let out: UnsafeMutablePointer<Float>
        let columns: UnsafePointer<Shares>
    }

    // MARK: the gain

    /// Step 4's gain (P): `medianTarget` over the crop's median luminance.
    static func gain(for crop: Crop) -> Float {
        let pixels = crop.box.width * crop.box.height, luma = Rec2020.luma
        var lights = [Float]()
        lights.reserveCapacity(pixels / medianStride + 1)
        crop.rgb.withUnsafeBufferPointer { rgb in
            for i in stride(from: 0, to: pixels, by: medianStride) {
                let light = luma.x * Float(rgb[i * 3]) + luma.y * Float(rgb[i * 3 + 1]) + luma.z * Float(rgb[i * 3 + 2])
                // A value that is not a number has no place in an order.
                lights.append(light.isNaN ? 0 : light)
            }
        }
        return medianTarget / max(ordered(&lights, at: lights.count / 2), medianFloor)
    }

    /// The value at `index` of `values` in ascending order: what the prototype read after sorting them all, found by
    /// partitioning around a middle value until the index is settled, which leaves the rest unsorted.
    static func ordered(_ values: inout [Float], at index: Int) -> Float {
        values.withUnsafeMutableBufferPointer { v in
            var low = 0, high = v.count - 1
            while low < high {
                let pivot = v[(low + high) / 2]
                var i = low, j = high
                while i <= j {
                    while v[i] < pivot { i += 1 }
                    while v[j] > pivot { j -= 1 }
                    if i <= j { v.swapAt(i, j); i += 1; j -= 1 }
                }
                if index <= j { high = j } else if index >= i { low = i } else { break }
            }
            return v[index]
        }
    }

    // MARK: the working size

    /// Step 3: each working pixel is the mean of the crop's area under it, a pixel that lies partly under it counted by that
    /// part. A crop smaller than the working size both ways is enlarged between its pixels instead (P: `resizeBilinear`), which
    /// leaves a crop of the working size as it is. A pixel whose sum is not finite, which no decode gives, is black.
    ///
    /// With `wholePixels` it is the prototype's (P: `resizeArea`): every pixel a working pixel touches counts whole, summed row
    /// by row. That is what its two runs were made with, at half the picture's scale and less, and what the suite that holds
    /// this port against its files asks for. It is not what the app uses: a crop reduced by a hair, 1345 pixels to 1344, has
    /// two pixels each way under nearly every working pixel, and their plain mean blurs the whole crop.
    static func resized(_ rgb: [Float16], width: Int, height: Int, to size: (width: Int, height: Int), wholePixels: Bool = false) -> [Float] {
        let nw = size.width, nh = size.height
        if nw >= width && nh >= height {
            return enlarged(rgb.map { Float($0).isFinite ? Float($0) : 0 }, width: width, height: height, channels: 3, to: size)
        }
        guard wholePixels else { return areaMean(rgb, width: width, height: height, to: size) }
        let sx = Float(width) / Float(nw), sy = Float(height) / Float(nh)
        let columns = (0..<nw).map { under($0, sx, width) }
        var out = [Float](repeating: 0, count: nw * nh * 3)
        rgb.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { out in
                columns.withUnsafeBufferPointer { columns in
                    let at = Rows(source: source.baseAddress!, out: out.baseAddress!, columns: columns.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: nh) { y in
                        let rows = under(y, sy, height)
                        for x in 0..<nw {
                            let span = at.columns[x]
                            var red: Float = 0, green: Float = 0, blue: Float = 0
                            for row in rows {
                                var pixel = at.source + (row * width + span.lowerBound) * 3
                                for _ in span {
                                    red += Float(pixel[0]); green += Float(pixel[1]); blue += Float(pixel[2])
                                    pixel += 3
                                }
                            }
                            let count = Float(rows.count * span.count), to = at.out + (y * nw + x) * 3
                            to[0] = red.isFinite ? red / count : 0
                            to[1] = green.isFinite ? green / count : 0
                            to[2] = blue.isFinite ? blue / count : 0
                        }
                    }
                }
            }
        }
        return out
    }

    /// The area mean of `resized`: the rows and the columns each have their shares, and a pixel's weight is the product.
    private static func areaMean(_ rgb: [Float16], width: Int, height: Int, to size: (width: Int, height: Int)) -> [Float] {
        let nw = size.width, nh = size.height
        let across = Double(width) / Double(nw), down = Double(height) / Double(nh)
        let columns = (0..<nw).map { shares($0, across, width) }
        var out = [Float](repeating: 0, count: nw * nh * 3)
        rgb.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { out in
                columns.withUnsafeBufferPointer { columns in
                    let at = SharedRows(source: source.baseAddress!, out: out.baseAddress!, columns: columns.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: nh) { y in
                        let rows = shares(y, down, height)
                        for x in 0..<nw {
                            let span = at.columns[x]
                            var red: Float = 0, green: Float = 0, blue: Float = 0
                            for (row, tall) in rows.parts.enumerated() {
                                var pixel = at.source + ((rows.first + row) * width + span.first) * 3
                                for wide in span.parts {
                                    let part = tall * wide
                                    red += Float(pixel[0]) * part; green += Float(pixel[1]) * part; blue += Float(pixel[2]) * part
                                    pixel += 3
                                }
                            }
                            let to = at.out + (y * nw + x) * 3
                            to[0] = red.isFinite ? red : 0
                            to[1] = green.isFinite ? green : 0
                            to[2] = blue.isFinite ? blue : 0
                        }
                    }
                }
            }
        }
        return out
    }

    /// The crop's pixels under working pixel `index` along one side, which reaches from `index * scale` to the next one's
    /// start: each pixel's part is the length of it that lies in that reach, over the reach's own length.
    private static func shares(_ index: Int, _ scale: Double, _ limit: Int) -> Shares {
        let start = Double(index) * scale, end = min(Double(limit), Double(index + 1) * scale)
        let first = min(limit - 1, Int(start)), last = min(limit - 1, max(first, Int(end.rounded(.up)) - 1))
        let lengths = (first...last).map { max(0, min(end, Double($0 + 1)) - max(start, Double($0))) }
        let whole = lengths.reduce(0, +)
        guard whole > 0 else { return Shares(first: first, parts: [1]) }
        return Shares(first: first, parts: lengths.map { Float($0 / whole) })
    }

    /// The prototype's reach: the crop's pixels under working pixel `index` along one side, from where it starts, rounded down,
    /// to where the next starts, rounded up, and one pixel at the least (P).
    private static func under(_ index: Int, _ scale: Float, _ limit: Int) -> Range<Int> {
        let first = Int(Float(index) * scale)
        return first..<max(first + 1, min(limit, Int((Float(index + 1) * scale).rounded(.up))))
    }

    /// P: `resizeBilinear`. A picture of `channels` values a pixel enlarged to `size`, pixel middles aligned and held at the edge.
    static func enlarged(_ values: [Float], width: Int, height: Int, channels c: Int, to size: (width: Int, height: Int)) -> [Float] {
        let nw = size.width, nh = size.height
        var out = [Float](repeating: 0, count: nw * nh * c)
        let sx = Float(width) / Float(nw), sy = Float(height) / Float(nh)
        values.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { out in
                for y in 0..<nh {
                    let fy = min(max((Float(y) + 0.5) * sy - 0.5, 0), Float(height - 1))
                    let y0 = Int(fy), y1 = min(y0 + 1, height - 1), wy = fy - Float(y0)
                    for x in 0..<nw {
                        let fx = min(max((Float(x) + 0.5) * sx - 0.5, 0), Float(width - 1))
                        let x0 = Int(fx), x1 = min(x0 + 1, width - 1), wx = fx - Float(x0)
                        let a = (y0 * width + x0) * c, b = (y0 * width + x1) * c, e = (y1 * width + x0) * c, f = (y1 * width + x1) * c
                        let to = (y * nw + x) * c
                        for k in 0..<c {
                            let top = source[a + k] * (1 - wx) + source[b + k] * wx
                            let bottom = source[e + k] * (1 - wx) + source[f + k] * wx
                            out[to + k] = top * (1 - wy) + bottom * wy
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: the curve

    /// Step 4 (P: `lamaEncode`): scene-linear Rec. 2020 to the 8-bit sRGB picture the model sees. The gain puts the crop's median
    /// at `medianTarget`, and a soft shoulder keeps highlights from clipping outright.
    static func encoded(_ rgb: [Float], gain: Float) -> [UInt8] {
        let white = shoulderWhite * shoulderWhite
        func byte(_ light: Float) -> UInt8 {
            // Past ten thousand the curve is white whatever the value, and this keeps an infinity from becoming no number.
            let x = light > 0 ? min(light, 1e4) : 0
            let y = x * (1 + x / white) / (1 + x)
            let s = y <= 0.0031308 ? 12.92 * y : 1.055 * powf(y, 1 / 2.4) - 0.055
            return UInt8(min(max(s, 0), 1) * 255 + 0.5)
        }
        var out = [UInt8](repeating: 0, count: rgb.count)
        rgb.withUnsafeBufferPointer { rgb in
            out.withUnsafeMutableBufferPointer { out in
                for p in stride(from: 0, to: rgb.count, by: 3) {
                    let r = rgb[p], g = rgb[p + 1], b = rgb[p + 2]
                    out[p] = byte((1.6605 * r - 0.5876 * g - 0.0728 * b) * gain)
                    out[p + 1] = byte((-0.1246 * r + 1.1329 * g - 0.0083 * b) * gain)
                    out[p + 2] = byte((-0.0182 * r - 0.1006 * g + 1.1187 * b) * gain)
                }
            }
        }
        return out
    }

    /// Step 7 (P: `lamaDecode`): the model's 8-bit picture back to scene-linear Rec. 2020 with the job's gain. A byte has 256
    /// values, so the curve is undone once for each.
    static func decoded(_ image: [UInt8], gain: Float) -> [Float] {
        let white = shoulderWhite * shoulderWhite
        let light = (0...255).map { byte -> Float in
            let s = Float(byte) / 255
            let y = min(s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4), 0.999)
            return white / 2 * (-(1 - y) + ((1 - y) * (1 - y) + 4 * y / white).squareRoot()) / gain
        }
        var out = [Float](repeating: 0, count: image.count)
        image.withUnsafeBufferPointer { image in
            out.withUnsafeMutableBufferPointer { out in
                for p in stride(from: 0, to: image.count, by: 3) {
                    let r = light[Int(image[p])], g = light[Int(image[p + 1])], b = light[Int(image[p + 2])]
                    out[p] = 0.6274 * r + 0.3293 * g + 0.0433 * b
                    out[p + 1] = 0.0691 * r + 0.9195 * g + 0.0114 * b
                    out[p + 2] = 0.0164 * r + 0.0880 * g + 0.8956 * b
                }
            }
        }
        return out
    }

    // MARK: masks

    /// A mask at another size, 0 and 255. Along a side that gets shorter, a pixel is selected when any pixel under it is, each
    /// source pixel under one target (P's reduction of the object's mask). Along a side that gets longer, each pixel takes the
    /// one it lies in. The two undo each other: a mask stretched and reduced again is the mask it was, which is what lets a
    /// removal be tried again on its own mask (`plan(retrying:)`).
    static func resampled(_ mask: [UInt8], width: Int, height: Int, to size: (width: Int, height: Int)) -> [UInt8] {
        let nw = size.width, nh = size.height
        // For each pixel of the longer side, its pixel of the shorter.
        func pairs(_ source: Int, _ target: Int) -> [Int] {
            source >= target ? (0..<source).map { min(target - 1, $0 * target / source) } : (0..<target).map { min(source - 1, $0 * source / target) }
        }
        let across = pairs(width, nw), down = pairs(height, nh)
        var rows = [UInt8](repeating: 0, count: nw * height)
        for y in 0..<height {
            if width >= nw {
                for x in 0..<width where mask[y * width + x] >= 128 { rows[y * nw + across[x]] = 255 }
            } else {
                for x in 0..<nw where mask[y * width + across[x]] >= 128 { rows[y * nw + x] = 255 }
            }
        }
        var out = [UInt8](repeating: 0, count: nw * nh)
        if height >= nh {
            for y in 0..<height { for x in 0..<nw where rows[y * nw + x] != 0 { out[down[y] * nw + x] = 255 } }
        } else {
            for y in 0..<nh { for x in 0..<nw where rows[down[y] * nw + x] != 0 { out[y * nw + x] = 255 } }
        }
        return out
    }

    /// P: `dilated`. A mask grown `reach` pixels as a square: along rows, then along columns, each pixel selected when one
    /// within reach is.
    static func grown(_ mask: [UInt8], width: Int, height: Int, by reach: Int) -> [UInt8] {
        guard reach > 0 else { return mask.map { $0 >= 128 ? 255 : 0 } }
        var rows = [UInt8](repeating: 0, count: mask.count), out = rows
        mask.withUnsafeBufferPointer { mask in
            rows.withUnsafeMutableBufferPointer { rows in
                for y in 0..<height {
                    // How far back the last selected pixel lies, from the left and then from the right.
                    var away = reach + 1
                    for x in 0..<width {
                        away = mask[y * width + x] >= 128 ? 0 : min(away + 1, reach + 1)
                        if away <= reach { rows[y * width + x] = 255 }
                    }
                    away = reach + 1
                    for x in stride(from: width - 1, through: 0, by: -1) {
                        away = mask[y * width + x] >= 128 ? 0 : min(away + 1, reach + 1)
                        if away <= reach { rows[y * width + x] = 255 }
                    }
                }
                out.withUnsafeMutableBufferPointer { out in
                    for x in 0..<width {
                        var away = reach + 1
                        for y in 0..<height {
                            away = rows[y * width + x] != 0 ? 0 : min(away + 1, reach + 1)
                            if away <= reach { out[y * width + x] = 255 }
                        }
                        away = reach + 1
                        for y in stride(from: height - 1, through: 0, by: -1) {
                            away = rows[y * width + x] != 0 ? 0 : min(away + 1, reach + 1)
                            if away <= reach { out[y * width + x] = 255 }
                        }
                    }
                }
            }
        }
        return out
    }

    /// A mask shrunk `reach` pixels: what is left when all that is not selected is grown. Past the raster's edge counts as
    /// selected, so a mask that runs to the edge keeps it, and growing the result gives back a mask that was itself grown.
    static func shrunk(_ mask: [UInt8], width: Int, height: Int, by reach: Int) -> [UInt8] {
        grown(mask.map { $0 >= 128 ? 0 : 255 }, width: width, height: height, by: reach).map { $0 != 0 ? 0 : 255 }
    }
}
