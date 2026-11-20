import Foundation

/// The patch's steps: the area the model changed, its picture matched to the original along that area's edge, the alphas and
/// the face note (docs/remove-plan.md, section 4.4, steps 8 to 11).
extension RemovalPipeline {
    /// The membrane is relaxed this many times at each size (P: `smoothFill`).
    static let membraneSweeps = 24
    /// The log ratio is taken between values lifted by this, so black against black is no difference, and is held to two stops
    /// either way before it is smoothed (P: `boundaryMatch`).
    static let matchLift: Float = 1e-4
    static let matchLimit: Float = 2
    /// The changed area must cover this share of a face's box for the face to be noted (inference: a tenth is an eye or half a
    /// mouth, which is content a viewer would miss; less is the grown edge of a neighbouring object brushing the box's corner,
    /// which is rarely skin).
    static let faceReach: Float = 0.1
    /// A face whose box the object covers this much of is the object's own, removed with it, and gets no note (inference: a
    /// person's mask covers nearly all of their own face's box, and the face of someone left in the picture is mostly outside it.
    /// A face more than half hidden behind the object is therefore missed).
    static let faceOwned: Float = 0.5

    /// Step 8 (P): the object joined with the attention map at `attentionThreshold` and above, grown `growth` pixels.
    static func changedArea(object: [UInt8], attention: [UInt8], width: Int, height: Int, growth: Int) -> [UInt8] {
        var joined = [UInt8](repeating: 0, count: width * height)
        for i in joined.indices where object[i] >= 128 || attention[i] >= attentionThreshold { joined[i] = 255 }
        return grown(joined, width: width, height: height, by: growth)
    }

    // MARK: the match

    /// Step 9 (P: `boundaryMatch`). The model redraws the picture with its own colour and contrast, so its fill does not meet the
    /// original at the hole's edge. The log ratio of original to fill is known outside the hole; it is smoothed there and
    /// carried into the hole as a membrane, and the fill is multiplied by it. Outside the hole the result is the original
    /// again. Being a ratio, it follows the crop's exposure: a crop two stops brighter gives a fill two stops brighter.
    static func match(_ fill: inout [Float], to original: [Float], hole: [UInt8], width: Int, height: Int, blur: Int) {
        let count = width * height
        var ratio = [Float](repeating: 0, count: count * 3), known = [Float](repeating: 0, count: count)
        for p in 0..<count where hole[p] == 0 {
            known[p] = 1
            for k in 0..<3 {
                let q = (original[p * 3 + k] + matchLift) / (fill[p * 3 + k] + matchLift)
                // A quotient that is not positive has no logarithm; the prototype's clamp gave it the lower limit.
                ratio[p * 3 + k] = q > 0 ? min(matchLimit, max(-matchLimit, log2(q))) : -matchLimit
            }
        }
        let smoothed = blurred(ratio, width: width, height: height, channels: 3, radius: blur)
        let weight = blurred(known, width: width, height: height, channels: 1, radius: blur)
        for p in 0..<count where hole[p] == 0 {
            for k in 0..<3 { ratio[p * 3 + k] = smoothed[p * 3 + k] / max(weight[p], 1e-3) }
        }
        ratio = membrane(ratio, hole: hole, width: width, height: height, channels: 3)
        for p in 0..<count {
            if hole[p] != 0 {
                for k in 0..<3 { fill[p * 3 + k] *= exp2(ratio[p * 3 + k]) }
            } else {
                for k in 0..<3 { fill[p * 3 + k] = original[p * 3 + k] }
            }
        }
    }

    /// P: `boxBlur`. A box of `radius` pixels each way, rows then columns, the edge pixel repeated past the edge. The sum runs
    /// along each line as the prototype's does, so the two agree to the last bit but for rounding the compiler may reorder.
    static func blurred(_ values: [Float], width w: Int, height h: Int, channels c: Int, radius r: Int) -> [Float] {
        guard r > 0 else { return values }
        var rows = [Float](repeating: 0, count: values.count), out = rows
        let n = Float(2 * r + 1)
        values.withUnsafeBufferPointer { values in
            rows.withUnsafeMutableBufferPointer { rows in
                for y in 0..<h { for k in 0..<c {
                    var sum: Float = 0
                    for i in -r...r { sum += values[(y * w + min(max(i, 0), w - 1)) * c + k] }
                    for x in 0..<w {
                        rows[(y * w + x) * c + k] = sum / n
                        sum += values[(y * w + min(x + r + 1, w - 1)) * c + k] - values[(y * w + max(x - r, 0)) * c + k]
                    }
                } }
                out.withUnsafeMutableBufferPointer { out in
                    for x in 0..<w { for k in 0..<c {
                        var sum: Float = 0
                        for i in -r...r { sum += rows[(min(max(i, 0), h - 1) * w + x) * c + k] }
                        for y in 0..<h {
                            out[(y * w + x) * c + k] = sum / n
                            sum += rows[(min(y + r + 1, h - 1) * w + x) * c + k] - rows[(max(y - r, 0) * w + x) * c + k]
                        }
                    } }
                }
            }
        }
        return out
    }

    /// P: `smoothFill`. The hole filled from its edge as a membrane, coarse to fine: at half the size first, where a pixel is
    /// known when any of its four is, that fill enlarged as the start, then each hole pixel set to the mean of its four
    /// neighbours `membraneSweeps` times, in reading order, each using the neighbours already set.
    static func membrane(_ values: [Float], hole: [UInt8], width w: Int, height h: Int, channels c: Int) -> [Float] {
        let inside = hole.indices.filter { hole[$0] != 0 }
        guard !inside.isEmpty else { return values }
        var out = values
        if w > 2 && h > 2 {
            let nw = (w + 1) / 2, nh = (h + 1) / 2
            var small = [Float](repeating: 0, count: nw * nh * c), smallHole = [UInt8](repeating: 0, count: nw * nh)
            var sum = [Float](repeating: 0, count: c)
            for y in 0..<nh { for x in 0..<nw {
                for k in 0..<c { sum[k] = 0 }
                var known: Float = 0
                for dy in 0..<2 { for dx in 0..<2 {
                    let sx = x * 2 + dx, sy = y * 2 + dy
                    guard sx < w, sy < h, hole[sy * w + sx] == 0 else { continue }
                    for k in 0..<c { sum[k] += values[(sy * w + sx) * c + k] }
                    known += 1
                } }
                if known > 0 {
                    for k in 0..<c { small[(y * nw + x) * c + k] = sum[k] / known }
                } else {
                    smallHole[y * nw + x] = 255
                }
            } }
            let start = enlarged(membrane(small, hole: smallHole, width: nw, height: nh, channels: c), width: nw, height: nh,
                                 channels: c, to: (w, h))
            for i in inside { for k in 0..<c { out[i * c + k] = start[i * c + k] } }
        }
        out.withUnsafeMutableBufferPointer { out in
            for _ in 0..<membraneSweeps {
                for i in inside {
                    let x = i % w, y = i / w
                    let left = (y * w + max(x - 1, 0)) * c, right = (y * w + min(x + 1, w - 1)) * c
                    let up = (max(y - 1, 0) * w + x) * c, down = (min(y + 1, h - 1) * w + x) * c
                    for k in 0..<c { out[i * c + k] = 0.25 * (out[left + k] + out[right + k] + out[up + k] + out[down + k]) }
                }
            }
        }
        return out
    }

    // MARK: the alphas

    /// Step 10: a mask as an alpha, its edge a ramp `feather` pixels wide and centred on it, so the alpha is at 128 and above
    /// exactly where the mask is and the mask can be read back from it. Each pixel stands at its middle: a half pixel inside the
    /// edge for the mask's outermost ring, a half pixel outside for the ring around it, and so on. At a feather of 3 that is 170
    /// on the outermost ring and 85 on the ring around it. The raster's own edge is no edge: a mask that runs to it stays full.
    ///
    /// The prototype cross-faded over 6 crop pixels outside a hole it had grown as much, so this ramp is narrower than what was
    /// measured where the crop is small, and wider where it is large.
    static func feathered(_ mask: [UInt8], width: Int, height: Int, by feather: Int) -> [UInt8] {
        var alpha = mask.map { $0 >= 128 ? UInt8(255) : 0 }
        var inner = alpha, outer = alpha
        var ring = 1
        while Float(ring) - 0.5 < Float(feather) / 2 {
            let step = (Float(ring) - 0.5) / Float(feather)
            let inside = UInt8((255 * (0.5 + step)).rounded()), outside = UInt8((255 * (0.5 - step)).rounded())
            let within = shrunk(inner, width: width, height: height, by: 1), around = grown(outer, width: width, height: height, by: 1)
            for i in alpha.indices {
                if inner[i] != 0 && within[i] == 0 { alpha[i] = inside }
                if outer[i] == 0 && around[i] != 0 { alpha[i] = outside }
            }
            inner = within; outer = around; ring += 1
        }
        return alpha
    }

    // MARK: the face note

    /// Step 11: the box of a face the removal drew new pixels in, though the face was not what was removed, or `nil`.
    ///
    /// A face's box is taken where it lies in the frame and counted over the working pixels whose middles it holds; what of it
    /// lies outside the crop is counted as untouched. The face is noted when the changed area, the object included, covers
    /// `faceReach` of the box or more, and the object alone covers less than `faceOwned` of it. The object counts toward the
    /// reach because the model draws what was behind it: a hand taken off a forehead leaves a forehead the model made up. Of
    /// several such faces the one most covered is given, since a patch holds one.
    static func redrawnFace(_ faces: [FaceMeasure], changed: [UInt8], object: [UInt8], width: Int, height: Int, plan: Plan) -> [Float]? {
        let box = plan.box, fw = Float(plan.frameWidth), fh = Float(plan.frameHeight)
        let across = Float(width) / Float(box.width), down = Float(height) / Float(box.height)
        var noted: (share: Float, box: [Float])?
        for face in faces {
            guard face.box.count == 4, face.box.allSatisfy(\.isFinite), face.box[2] > 0, face.box[3] > 0 else { continue }
            // The box inside the frame, in the working raster's pixels.
            let left = (max(face.box[0], 0) * fw - Float(box.x)) * across, right = (min(face.box[0] + face.box[2], 1) * fw - Float(box.x)) * across
            let top = (max(face.box[1], 0) * fh - Float(box.y)) * down, bottom = (min(face.box[1] + face.box[3], 1) * fh - Float(box.y)) * down
            guard right > left, bottom > top else { continue }
            let x0 = max(0, Int((left - 0.5).rounded(.up))), x1 = min(width - 1, Int((right - 0.5).rounded(.down)))
            let y0 = max(0, Int((top - 0.5).rounded(.up))), y1 = min(height - 1, Int((bottom - 0.5).rounded(.down)))
            guard x0 <= x1, y0 <= y1 else { continue }
            var redrawn = 0, owned = 0
            for y in y0...y1 { for x in x0...x1 {
                if changed[y * width + x] != 0 { redrawn += 1 }
                if object[y * width + x] >= 128 { owned += 1 }
            } }
            // A small box can hold more pixel middles than its area.
            let area = max((right - left) * (bottom - top), Float((x1 - x0 + 1) * (y1 - y0 + 1)))
            let share = Float(redrawn) / area, own = Float(owned) / area
            guard share >= faceReach, faceOwned > own, share > (noted?.share ?? 0) else { continue }
            noted = (share, face.box)
        }
        return noted?.box
    }
}
