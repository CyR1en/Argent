import Foundation

/// The matting of a Subject seed inside the low-light rule: the frozen tile loop, trimap and blend of research task Y2 (`recipe/matte_coreai.py`, its section 6, frozen in
/// `lowlight/evidence/Z1/FROZEN.md`), in Swift, reproducing Y2's alpha bit for bit: the seed bilinear to the print and thresholded at 128, an unknown band 16 px either side of
/// its contour, 1024 px tiles at stride 768 with a 128 px ramp, the band's edge blended over 4 px, then contrast 1.5 about 0.5, stored as an 8-bit raster at the print's size.
/// Every step here is the Python's: PIL's fixed-point bilinear (Pillow 13, 22 precision bits, horizontal then vertical, clipping to 8 bits between the passes); SciPy's exact
/// Euclidean distance transform; numpy's float32 accumulation over the tiles; float64 arithmetic for the composite; the same `+1e-6` inside the band's weight that the frozen
/// script adds, which the frozen report's `clamp((16 - d) / 4, 0, 1)` leaves out and code decides.
public enum SubjectMatte {
    /// The band each side of the seed's contour, at 2560 px.
    public static let outBand = 16, inBand = 16
    public static let tile = MatteRunner.side, stride = 768, ramp = 128
    public static let blend = 4.0, gain = 1.5
    /// What a matte's provenance names as its design; a change of meaning is a new version.
    public static let version = "y2-band16-16-tile1024-768-ramp128-blend4-gain1.5-1"

    /// What the matting came to.
    public struct Result: Sendable {
        public let alpha: MaskRaster
        /// Tiles the model ran on.
        public let tiles: Int
        /// The share of the print inside the unknown band.
        public let unknownShare: Double
    }

    /// The trimap, its values 0, 128, 255, and the squared distances to the contour, in or out of the seed, row-major.
    struct Trimap {
        let values: [UInt8]
        let inside: [Bool]
        let distancesIn: [Int32]
        let distancesOut: [Int32]
    }

    /// The print's alpha for `seed` on the print `pixels` (`bytesPerPixel` bytes each, of which the first three are R, G and B). `run` is the model on one tile.
    public static func alpha(seed: MaskRaster, picturePixels bytes: UnsafeRawBufferPointer, width: Int, height: Int, rowBytes: Int, bytesPerPixel: Int,
                             run: ([Float16]) async throws -> [Float]) async throws -> Result {
        let inside = bilinearThreshold(seed, toWidth: width, height: height)
        let trimap = makeTrimap(inside: inside, width: width, height: height)
        var unknown = 0
        for v in trimap.values where v == 128 { unknown += 1 }
        let (accumulated, tiles) = try await tileLoop(trimap: trimap.values, picturePixels: bytes, width: width, height: height, rowBytes: rowBytes, bytesPerPixel: bytesPerPixel, run: run)
        let plane = composite(alpha: accumulated, trimap: trimap, width: width, height: height)
        return Result(alpha: try MaskRaster(width: width, height: height, plane: plane), tiles: tiles, unknownShare: Double(unknown) / Double(width * height))
    }

    // MARK: Pillow's bilinear

    /// `Image.resize((toW, toH), Image.BILINEAR) >= 128`: Pillow's fixed-point resampling, which the frozen script's trimap reads.
    static func bilinearThreshold(_ seed: MaskRaster, toWidth: Int, height toHeight: Int) -> [Bool] {
        let resized = pilBilinear(seed.plane, width: seed.width, height: seed.height, toWidth: toWidth, toHeight: toHeight)
        return resized.map { $0 >= SmartSeed.selectedLevel }
    }

    /// Pillow's `ImagingResample` for an 8-bit single-channel image with a bilinear filter: the horizontal pass to 8 bits, then the vertical pass.
    static func pilBilinear(_ plane: [UInt8], width w: Int, height h: Int, toWidth W: Int, toHeight H: Int) -> [UInt8] {
        if w == W && h == H { return plane }
        // The vertical pass reads every row the horizontal pass makes.
        var temp = [UInt8](repeating: 0, count: W * h)
        let horizontal = coefficients(inSize: w, outSize: W)
        temp.withUnsafeMutableBufferPointer { out in
            plane.withUnsafeBufferPointer { input in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<W {
                        let (xmin, count, offset) = horizontal.span(x)
                        var ss = Int64(1) << (preciseBits - 1)
                        for k in 0..<count { ss += Int64(input[row + xmin + k]) * Int64(horizontal.weights[offset + k]) }
                        out[y * W + x] = clip8(ss)
                    }
                }
            }
        }
        var output = [UInt8](repeating: 0, count: W * H)
        let vertical = coefficients(inSize: h, outSize: H)
        output.withUnsafeMutableBufferPointer { out in
            temp.withUnsafeBufferPointer { input in
                for y in 0..<H {
                    let (ymin, count, offset) = vertical.span(y)
                    for x in 0..<W {
                        var ss = Int64(1) << (preciseBits - 1)
                        for k in 0..<count { ss += Int64(input[(ymin + k) * W + x]) * Int64(vertical.weights[offset + k]) }
                        out[y * W + x] = clip8(ss)
                    }
                }
            }
        }
        return output
    }

    private static let preciseBits = 22

    private static func clip8(_ value: Int64) -> UInt8 {
        let shifted = value >> Int64(preciseBits)
        return shifted < 0 ? 0 : (shifted > 255 ? 255 : UInt8(shifted))
    }

    /// `precompute_coeffs` and `normalize_coeffs_8bpc` for a bilinear filter, support 1.
    private static func coefficients(inSize: Int, outSize: Int) -> SpanTable {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1.0)
        let support = 1.0 * filterScale
        var bounds = [(Int, Int, Int)](repeating: (0, 0, 0), count: outSize)
        var weights: [Int32] = []
        weights.reserveCapacity(outSize * (Int(support.rounded(.up)) * 2 + 1))
        var line = [Double]()
        for xx in 0..<outSize {
            let center = (Double(xx) + 0.5) * scale
            var xmin = Int(center - support + 0.5)
            if xmin < 0 { xmin = 0 }
            var xmax = Int(center + support + 0.5)
            if xmax > inSize { xmax = inSize }
            xmax -= xmin
            line.removeAll(keepingCapacity: true)
            var sum = 0.0
            for x in 0..<xmax {
                var f = (Double(x + xmin) - center + 0.5) * (1.0 / filterScale)
                if f < 0 { f = -f }
                let weight = f < 1 ? 1 - f : 0
                line.append(weight)
                sum += weight
            }
            let offset = weights.count
            for x in 0..<xmax {
                let k = sum != 0 ? line[x] / sum : line[x]
                let scaled = k * Double(1 << preciseBits)
                weights.append(Int32(scaled < 0 ? Int(-0.5 + scaled) : Int(0.5 + scaled)))
            }
            bounds[xx] = (xmin, xmax, offset)
        }
        return SpanTable(bounds: bounds, weights: weights)
    }

    private struct SpanTable {
        let bounds: [(Int, Int, Int)]
        let weights: [Int32]
        func span(_ index: Int) -> (Int, Int, Int) { bounds[index] }
    }

    // MARK: The trimap

    /// SciPy's `distance_transform_edt` of `~inside` and of `inside`, and the trimap of the band: exact squared distances (Meijster's algorithm, the distances are exact
    /// integers).
    static func makeTrimap(inside: [Bool], width w: Int, height h: Int) -> Trimap {
        let squaredOut = squaredDistances(mask: inside, target: true, width: w, height: h)   // for pixels out of the seed: to the nearest seed pixel
        let squaredIn = squaredDistances(mask: inside, target: false, width: w, height: h)   // for pixels in the seed: to the nearest pixel out of it
        let limit = Int32(outBand * outBand), limitIn = Int32(inBand * inBand)
        var values = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            if inside[i] {
                values[i] = squaredIn[i] <= limitIn ? 128 : 255
            } else {
                values[i] = squaredOut[i] <= limit ? 128 : 0
            }
        }
        return Trimap(values: values, inside: inside, distancesIn: squaredIn, distancesOut: squaredOut)
    }

    /// The squared Euclidean distance of each pixel to the nearest pixel where `mask == target` (0 on those pixels). Exact integers, Meijster's two passes.
    static func squaredDistances(mask: [Bool], target: Bool, width m: Int, height n: Int) -> [Int32] {
        let infinity = Int64(m + n)
        var g = [Int64](repeating: 0, count: m * n)
        // The columns.
        for x in 0..<m {
            g[x] = mask[x] == target ? 0 : infinity
            var y = 1
            while y < n {
                let i = y * m + x
                g[i] = mask[i] == target ? 0 : min(g[i - m] + 1, infinity)
                y += 1
            }
            y = n - 2
            while y >= 0 {
                let i = y * m + x
                if g[i + m] < g[i] { g[i] = g[i + m] + 1 }
                y -= 1
            }
        }
        // The rows.
        var out = [Int32](repeating: 0, count: m * n)
        var s = [Int](repeating: 0, count: m), t = [Int](repeating: 0, count: m)
        g.withUnsafeBufferPointer { g in
            out.withUnsafeMutableBufferPointer { out in
                for y in 0..<n {
                    let row = y * m
                    func f(_ x: Int, _ i: Int) -> Int64 {
                        let dx = Int64(x - i), gi = g[row + i]
                        return dx * dx + gi * gi
                    }
                    func sep(_ i: Int, _ u: Int) -> Int {
                        let gu = g[row + u], gi = g[row + i], numerator = Int64(u * u - i * i) + gu * gu - gi * gi, denominator = Int64(2 * (u - i))
                        // Integer floor division.
                        var q = numerator / denominator
                        if numerator % denominator != 0 && (numerator < 0) != (denominator < 0) { q -= 1 }
                        return Int(q)
                    }
                    var q = 0
                    s[0] = 0; t[0] = 0
                    for u in 1..<m {
                        while q >= 0 && f(t[q], s[q]) > f(t[q], u) { q -= 1 }
                        if q < 0 {
                            q = 0
                            s[0] = u
                        } else {
                            let w = 1 + sep(s[q], u)
                            if w < m {
                                q += 1
                                s[q] = u
                                t[q] = w
                            }
                        }
                    }
                    var u = m - 1
                    while u >= 0 {
                        out[row + u] = Int32(min(f(u, s[q]), Int64(Int32.max)))
                        if u == t[q] { q -= 1 }
                        u -= 1
                    }
                }
            }
        }
        return out
    }

    // MARK: The tiles

    static func axis(_ n: Int) -> [Int] {
        if n <= tile { return [0] }
        var positions = Array(Swift.stride(from: 0, to: n - tile, by: stride))
        positions.append(n - tile)
        return positions
    }

    /// The blending window's one-dimensional ramp, float32 as numpy's `linspace` makes it: `np.linspace(0, 1, r + 2, dtype=float32)[1:-1]` at each end.
    static func rampWindow(count n: Int, ramp r: Int) -> [Float] {
        var a = [Float](repeating: 1, count: n)
        for i in 1...r {
            let e = Float(Double(i) * (1.0 / Double(r + 1)))
            a[i - 1] = e
            a[n - i] = e
        }
        return a
    }

    /// The accumulation of the model's alpha over every tile with an unknown pixel: float32, as numpy accumulates. `run` is called with the planar normalised tile.
    static func tileLoop(trimap: [UInt8], picturePixels bytes: UnsafeRawBufferPointer, width w: Int, height h: Int, rowBytes: Int, bytesPerPixel: Int,
                         run: ([Float16]) async throws -> [Float]) async throws -> (alpha: [Float], tiles: Int) {
        var acc = [Float](repeating: 0, count: w * h), weight = [Float](repeating: 0, count: w * h)
        let window1 = rampWindow(count: tile, ramp: ramp)
        let codes: [Float16] = (0...255).map { Float16((Float($0) / 255 - 0.5) / 0.5) }
        let triCodes: [Float16] = (0...255).map { Float16(Float($0) / 255) }
        var tiles = 0
        let plane = tile * tile
        for y0 in axis(h) {
            for x0 in axis(w) {
                let ph = min(tile, h - y0), pw = min(tile, w - x0)
                var any = false
                search: for y in 0..<ph {
                    for x in 0..<pw where trimap[(y0 + y) * w + x0 + x] == 128 { any = true; break search }
                }
                if !any { continue }
                var input = [Float16](repeating: 0, count: 4 * plane)
                input.withUnsafeMutableBufferPointer { dst in
                    trimap.withUnsafeBufferPointer { tri in
                        for y in 0..<tile {
                            let sy = reflect(y, count: ph)
                            let srow = (y0 + sy) * rowBytes
                            let trow = (y0 + sy) * w
                            for x in 0..<tile {
                                let sx = reflect(x, count: pw)
                                let s = srow + (x0 + sx) * bytesPerPixel
                                let d = y * tile + x
                                dst[d] = codes[Int(bytes[s])]
                                dst[plane + d] = codes[Int(bytes[s + 1])]
                                dst[2 * plane + d] = codes[Int(bytes[s + 2])]
                                dst[3 * plane + d] = triCodes[Int(tri[trow + x0 + sx])]
                            }
                        }
                    }
                }
                let alpha = try await run(input)
                acc.withUnsafeMutableBufferPointer { acc in
                    weight.withUnsafeMutableBufferPointer { weight in
                        alpha.withUnsafeBufferPointer { alpha in
                            for y in 0..<ph {
                                let row = (y0 + y) * w + x0
                                for x in 0..<pw {
                                    let g = window1[y] * window1[x]
                                    acc[row + x] += alpha[y * tile + x] * g
                                    weight[row + x] += g
                                }
                            }
                        }
                    }
                }
                tiles += 1
            }
        }
        let epsilon = Float(1e-6)
        for i in 0..<(w * h) { acc[i] = weight[i] > 0 ? acc[i] / max(weight[i], epsilon) : 0 }
        return (acc, tiles)
    }

    /// numpy's `pad(mode='reflect')` on the far side only: position `i` past a tile `count` long folds back about its last line (a tile near the frame's edge is padded only if
    /// the frame is shorter than a tile).
    private static func reflect(_ i: Int, count n: Int) -> Int {
        guard i >= n else { return i }
        guard n > 1 else { return 0 }
        let period = 2 * (n - 1), r = (i - (n - 1)) % period
        return r <= n - 1 ? n - 1 - r : r - (n - 1)
    }

    // MARK: The composite

    /// The alpha where the trimap is unknown, blended into the seed's 0 or 1 at the band's edge; contrast 1.5 about 0.5; 8 bits by truncation of `v × 255 + 0.5`. Float64 throughout,
    /// as the script is.
    static func composite(alpha: [Float], trimap t: Trimap, width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let known: Double = t.inside[i] ? 1 : 0
            var value = known
            if t.values[i] == 128 {
                let d = t.inside[i] ? Double(t.distancesIn[i]).squareRoot() : Double(t.distancesOut[i]).squareRoot()
                let band = Double(t.inside[i] ? inBand : outBand)
                let ws = min(max((band - d) / blend + 1e-6, 0), 1)
                let a = Double(min(max(alpha[i], 0), 1))
                value = ws * a + (1 - ws) * known
            }
            let result = min(max(gain * (value - 0.5) + 0.5, 0), 1)
            out[i] = UInt8((result * 255 + 0.5).rounded(.towardZero))
        }
        return out
    }
}
