import Foundation

/// The plan's steps: a selection carried to the decode's pixels, and the crop's box (docs/remove-plan.md, section 4.4, steps 1
/// and 2).
extension RemovalPipeline {
    /// A box of pixels by its first and last column and row.
    struct Bounds: Sendable, Equatable {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var width: Int { x1 - x0 + 1 }
        var height: Int { y1 - y0 + 1 }
        func joined(_ other: Bounds) -> Bounds {
            Bounds(x0: min(x0, other.x0), y0: min(y0, other.y0), x1: max(x1, other.x1), y1: max(y1, other.y1))
        }
    }

    /// A selection at the decode's pixels: the mask over `area` of the frame, and the box of what it selects.
    struct Carried: Sendable {
        let area: Bounds
        let mask: [UInt8]
        let bounds: Bounds?

        /// The mask over `box`, which may reach past `area`: nothing is selected there.
        func cut(to box: RemovalPatch.Box) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: box.width * box.height)
            let columns = max(area.x0, box.x)..<min(area.x1 + 1, box.x + box.width)
            let rows = max(area.y0, box.y)..<min(area.y1 + 1, box.y + box.height)
            guard columns.lowerBound < columns.upperBound, rows.lowerBound < rows.upperBound else { return out }
            for y in rows {
                let from = (y - area.y0) * area.width + columns.lowerBound - area.x0
                let to = (y - box.y) * box.width + columns.lowerBound - box.x
                out.replaceSubrange(to..<to + columns.count, with: mask[from..<from + columns.count])
            }
            return out
        }
    }

    /// The decode as a lens geometry: every radius read where it is. A remap from it to a corrected picture's geometry carries a
    /// decode pixel to where the lens stage shows it, since the stage reads the decode at the radius its green table gives.
    static var decodeGeometry: LensGeometry { ResolvedLensCorrection.identity.geometry }

    /// Pointers for a loop over row bands, each band writing its own rows.
    private struct Bands: @unchecked Sendable {
        let coverage: UnsafePointer<UInt8>
        let mask: UnsafeMutablePointer<UInt8>
        let found: UnsafeMutablePointer<Bounds?>
        let ratio: UnsafePointer<Float>?
    }

    /// Step 1. Each decode pixel's middle is carried to the corrected picture (`LensRemap` from the decode's geometry to
    /// `geometry`; a plain stretch with none) and the coverage is read there between its four nearest texels, as a texture is.
    /// A pixel is selected at 128 and above after rounding.
    ///
    /// Only the part of the frame the selection can reach is visited: its texels' box in the corrected picture, carried back to
    /// the decode by the opposite remap. The two remaps are tables and not exact inverses, so the part is widened until what it
    /// selects no longer touches its edge.
    static func carried(_ selection: Selection, geometry: LensGeometry?, frameWidth: Int, frameHeight: Int) -> Carried {
        let extent = MaskPoint(x: Float(frameWidth), y: Float(frameHeight))
        let toPicture = geometry.flatMap { LensRemap(from: decodeGeometry, to: $0, extent: extent) }
        let frame = Bounds(x0: 0, y0: 0, x1: frameWidth - 1, y1: frameHeight - 1)
        var area = reach(of: selection, geometry: toPicture == nil ? nil : geometry, frameWidth: frameWidth, frameHeight: frameHeight)
        while true {
            let made = sampled(selection, over: area, toPicture: toPicture, frameWidth: frameWidth, frameHeight: frameHeight)
            guard let bounds = made.bounds else { return made }
            let touches = (bounds.x0 == area.x0 && area.x0 > 0) || (bounds.y0 == area.y0 && area.y0 > 0)
                || (bounds.x1 == area.x1 && area.x1 < frame.x1) || (bounds.y1 == area.y1 && area.y1 < frame.y1)
            guard touches else { return made }
            area = Bounds(x0: max(0, area.x0 - 16), y0: max(0, area.y0 - 16), x1: min(frame.x1, area.x1 + 16), y1: min(frame.y1, area.y1 + 16))
        }
    }

    /// The decode pixels a selection can reach. A sample between texels is at 128 only beside a texel that is, so the reach is
    /// the selected texels' box and one texel more; under a lens, that box's outline carried to the decode.
    private static func reach(of selection: Selection, geometry: LensGeometry?, frameWidth: Int, frameHeight: Int) -> Bounds {
        let w = selection.width, h = selection.height
        var texels = Bounds(x0: w, y0: h, x1: -1, y1: -1)
        selection.coverage.withUnsafeBufferPointer { coverage in
            for y in 0..<h {
                let row = coverage.baseAddress! + y * w
                guard let first = (0..<w).first(where: { row[$0] >= 128 }) else { continue }
                let last = (0..<w).last(where: { row[$0] >= 128 })!
                texels = texels.joined(Bounds(x0: first, y0: y, x1: last, y1: y))
            }
        }
        let fw = Float(frameWidth), fh = Float(frameHeight)
        // In the corrected picture's pixels, a texel's middle at its index and a half.
        let left = max(0, (Float(texels.x0) - 0.5) * fw / Float(w)), right = min(fw, (Float(texels.x1) + 1.5) * fw / Float(w))
        let top = max(0, (Float(texels.y0) - 0.5) * fh / Float(h)), bottom = min(fh, (Float(texels.y1) + 1.5) * fh / Float(h))
        var low = MaskPoint(x: left, y: top), high = MaskPoint(x: right, y: bottom)
        if let geometry, let toDecode = LensRemap(from: geometry, to: decodeGeometry, extent: MaskPoint(x: fw, y: fh)) {
            // The remap is radial and one to one, so the outline's picture bounds the inside's.
            low = MaskPoint(x: .infinity, y: .infinity); high = MaskPoint(x: -.infinity, y: -.infinity)
            func visit(_ x: Float, _ y: Float) {
                let p = toDecode.point(MaskPoint(x: x, y: y))
                low = MaskPoint(x: min(low.x, p.x), y: min(low.y, p.y)); high = MaskPoint(x: max(high.x, p.x), y: max(high.y, p.y))
            }
            let across = max(1, Int((right - left).rounded(.up))), down = max(1, Int((bottom - top).rounded(.up)))
            for i in 0...across {
                let x = left + (right - left) * Float(i) / Float(across)
                visit(x, top); visit(x, bottom)
            }
            for j in 0...down {
                let y = top + (bottom - top) * Float(j) / Float(down)
                visit(left, y); visit(right, y)
            }
            low = MaskPoint(x: low.x - 2, y: low.y - 2); high = MaskPoint(x: high.x + 2, y: high.y + 2)
        }
        func pixel(_ position: Float, last: Int) -> Int { min(max(Int(position), 0), last) }
        let x0 = pixel((low.x - 0.5).rounded(.down), last: frameWidth - 1), x1 = pixel((high.x - 0.5).rounded(.up), last: frameWidth - 1)
        let y0 = pixel((low.y - 0.5).rounded(.down), last: frameHeight - 1), y1 = pixel((high.y - 0.5).rounded(.up), last: frameHeight - 1)
        return Bounds(x0: x0, y0: y0, x1: max(x0, x1), y1: max(y0, y1))
    }

    private static func sampled(_ selection: Selection, over area: Bounds, toPicture: LensRemap?, frameWidth: Int, frameHeight: Int) -> Carried {
        let w = selection.width, h = selection.height, fw = Float(frameWidth), fh = Float(frameHeight)
        let across = Float(w) / fw, down = Float(h) / fh
        // `LensRemap.point` to the letter, with the frame's half diagonal taken once for all its pixels.
        let centreX = fw / 2, centreY = fh / 2, halfDiagonal = hypot(fw, fh) / 2, intervals = RadialTable.intervals
        var mask = [UInt8](repeating: 0, count: area.width * area.height)
        let bands = max(1, min(area.height, 4 * ProcessInfo.processInfo.activeProcessorCount))
        var found = [Bounds?](repeating: nil, count: bands)
        let table = toPicture?.ratio ?? []
        selection.coverage.withUnsafeBufferPointer { coverage in
            mask.withUnsafeMutableBufferPointer { out in
                found.withUnsafeMutableBufferPointer { found in
                    table.withUnsafeBufferPointer { table in
                        let at = Bands(coverage: coverage.baseAddress!, mask: out.baseAddress!, found: found.baseAddress!,
                                       ratio: toPicture == nil ? nil : table.baseAddress)
                        DispatchQueue.concurrentPerform(iterations: bands) { band in
                            var box: Bounds?
                            for row in (band * area.height / bands)..<((band + 1) * area.height / bands) {
                                let y = area.y0 + row, line = at.mask + row * area.width
                                var first = -1, last = -1
                                for column in 0..<area.width {
                                    var px = Float(area.x0 + column) + 0.5, py = Float(y) + 0.5
                                    if let ratio = at.ratio {
                                        let dx = px - centreX, dy = py - centreY
                                        let t = min(hypot(dx, dy) / halfDiagonal, 1) * Float(intervals)
                                        let i = min(Int(t), intervals - 1)
                                        let r = ratio[i] + (ratio[i + 1] - ratio[i]) * (t - Float(i))
                                        px = centreX + dx * r; py = centreY + dy * r
                                        // The corrected picture shows nothing of a decode pixel it frames out.
                                        guard px >= 0, px <= fw, py >= 0, py <= fh else { continue }
                                    }
                                    let u = min(max(px * across - 0.5, 0), Float(w - 1)), v = min(max(py * down - 0.5, 0), Float(h - 1))
                                    let i = Int(u), j = Int(v), i1 = min(i + 1, w - 1), j1 = min(j + 1, h - 1)
                                    let s = u - Float(i), t = v - Float(j)
                                    let upper = Float(at.coverage[j * w + i]) * (1 - s) + Float(at.coverage[j * w + i1]) * s
                                    let lower = Float(at.coverage[j1 * w + i]) * (1 - s) + Float(at.coverage[j1 * w + i1]) * s
                                    guard upper * (1 - t) + lower * t >= 127.5 else { continue }
                                    line[column] = 255
                                    if first < 0 { first = column }
                                    last = column
                                }
                                guard first >= 0 else { continue }
                                let here = Bounds(x0: area.x0 + first, y0: y, x1: area.x0 + last, y1: y)
                                box = box.map { $0.joined(here) } ?? here
                            }
                            at.found[band] = box
                        }
                    }
                }
            }
        }
        let bounds = found.compactMap { $0 }.reduce(nil as Bounds?) { all, band in all?.joined(band) ?? band }
        return Carried(area: area, mask: mask, bounds: bounds)
    }

    /// Step 2: the object's box with context on every side, of a size the model can work on at the picture's own scale or at the
    /// largest that fits it, centred on the object and moved inside the frame (`contextShare`, and why).
    static func cropBox(around object: Bounds, frameWidth: Int, frameHeight: Int) throws -> RemovalPatch.Box {
        let limit = RemovalPatch.longSideLimit
        let wide = object.x1 - object.x0 + 1, tall = object.y1 - object.y0 + 1
        let context = min(max(Int(Float(max(wide, tall)) * contextShare), contextRange.lowerBound), contextRange.upperBound)
        var width = wide + 2 * context, height = tall + 2 * context
        if max(width, height) <= limit {
            // The picture's own scale: each side on the grid, with the model's training size at least.
            func stepped(_ side: Int) -> Int { min(limit, max(RemovalPatch.shortSide, (side + sizeStep - 1) / sizeStep * sizeStep)) }
            width = stepped(width)
            height = stepped(height)
        } else {
            // Reduced until its long side is the limit. The shorter side is widened, with context, until its working length is
            // on the grid and the model's training size at least; within half a working pixel of the grid it is on it. A square
            // crop stays square.
            let scale = Double(limit) / Double(max(width, height))
            func widened(_ side: Int) -> Int {
                let steps = Int(((Double(side) * scale - 0.5) / Double(sizeStep)).rounded(.up))
                let working = min(limit, max(RemovalPatch.shortSide, steps * sizeStep))
                return max(side, Int((Double(working) / scale).rounded()))
            }
            if width < height { width = widened(width) } else if height < width { height = widened(height) }
        }
        func placed(_ low: Int, _ high: Int, _ length: Int, frame: Int) -> (origin: Int, length: Int) {
            let length = min(frame, length)
            return (min(max((low + high) / 2 - length / 2, 0), frame - length), length)
        }
        let across = placed(object.x0, object.x1, width, frame: frameWidth), down = placed(object.y0, object.y1, height, frame: frameHeight)
        return try RemovalPatch.Box(x: across.origin, y: down.origin, width: across.length, height: down.length)
    }
}
