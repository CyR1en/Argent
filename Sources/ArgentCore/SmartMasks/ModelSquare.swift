import Foundation

/// Where a picture sits in a bundled model's padded square: area-resized so its longer side fills the square, centred, the rest
/// the picture's own edge repeated (docs/masking-plan.md section 3: "one padded 756 × 756 square for every frame, landscape padded
/// top and bottom, portrait left and right"). A 3:2 frame comes to 756 × 504 at row 126 in DA3's square (P0-S1b) and 768 × 512 at
/// row 128 in EoMT's (P0-S5); another aspect keeps its own shape, as S5's did, where S1b's prototype stretched every landscape
/// frame to 756 × 504.
public struct ModelSquareLayout: Sendable, Equatable, Codable {
    /// The square's side, in the model's input pixels.
    public let side: Int
    public let contentWidth: Int
    public let contentHeight: Int
    /// The content's left and top edges in the square.
    public let originX: Int
    public let originY: Int

    public init(side: Int, contentWidth: Int, contentHeight: Int, originX: Int, originY: Int) {
        self.side = side; self.contentWidth = contentWidth; self.contentHeight = contentHeight
        self.originX = originX; self.originY = originY
    }

    /// A `width` by `height` picture in a square of `side`: its longer side `side` pixels, the shorter rounded, centred.
    public init(side: Int, width: Int, height: Int) {
        let scale = Double(side) / Double(max(width, height))
        let w = max(1, min(side, Int((Double(width) * scale).rounded())))
        let h = max(1, min(side, Int((Double(height) * scale).rounded())))
        self.init(side: side, contentWidth: w, contentHeight: h, originX: (side - w) / 2, originY: (side - h) / 2)
    }
}

/// A bundled model's input: the mask input picture in the model's padded square, planar RGB, ImageNet-normalised, in half floats,
/// as P0-S1b's `SquareInput` and P0-S5's `EomtInput` made it, so the tensor is the one Python's reference saw from the same 8-bit
/// picture. The resize is OpenCV's `INTER_AREA` (fractional box weights in float32, rounded half to even to 8 bits): on the same
/// 8-bit picture S1b's Swift square equalled OpenCV's except for a tie in 2 to 14 of 571,536 values.
public struct ModelSquare: Sendable {
    /// ImageNet's mean and standard deviation, which both models were trained with.
    public static let mean: SIMD3<Float> = [0.485, 0.456, 0.406]
    public static let std: SIMD3<Float> = [0.229, 0.224, 0.225]

    /// What fills the square around the picture: the picture mirrored about its edge pixel (OpenCV's `BORDER_REFLECT_101`) for
    /// `mirrored` lines past it, and the last of them repeated out to the square's edge. `edge` mirrors none, so the picture's own edge
    /// repeats (OpenCV's `BORDER_REPLICATE`), as P0-S1b's and P0-S5's squares did; `mirror` mirrors all the way.
    public struct Padding: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
        public var mirrored: Int
        /// Black all round, code 0 in the picture's own bytes: S3OD's padding (research task V4). `mirrored` is then 0 and unused.
        public var isBlack: Bool
        public init(mirrored: Int) { self.mirrored = max(0, mirrored); isBlack = false }
        private init(black: Void) { mirrored = 0; isBlack = true }
        public static let edge = Padding(mirrored: 0)
        public static let mirror = Padding(mirrored: Int.max)
        public static let black = Padding(black: ())
        public var description: String {
            if isBlack { return "black" }
            switch mirrored {
            case 0: return "edge"
            case Int.max: return "mirror"
            default: return "mirror \(mirrored), then edge"
            }
        }
    }

    public let layout: ModelSquareLayout
    public let padding: Padding
    /// 3 × side × side, planar R, G, B, the model's input.
    public let input: [Float16]

    public init(layout: ModelSquareLayout, padding: Padding = .edge, input: [Float16]) {
        precondition(input.count == 3 * layout.side * layout.side, "a square's input is 3 × side × side")
        self.layout = layout
        self.padding = padding
        self.input = input
    }

    /// `picture` in a square of `side`, padded with `padding`: the content the maker resized from the same print on the GPU for this
    /// side, or else the picture area-resized on the CPU.
    public init(_ picture: MaskInputPicture, side: Int, padding: Padding) {
        let layout = ModelSquareLayout(side: side, width: picture.width, height: picture.height)
        let content = picture.modelContents[side] ?? picture.withPixels { pixels, bytesPerRow in
            Self.areaResize(pixels, width: picture.width, height: picture.height, bytesPerPixel: MaskInputPicture.bytesPerPixel,
                            bytesPerRow: bytesPerRow, toWidth: layout.contentWidth, height: layout.contentHeight)
        }
        self.init(contentRGB8: content, layout: layout, padding: padding)
    }

    /// What a seed's provenance says of the square it was cut from: side, resize, placement and padding.
    public static func recipe(side: Int, padding: Padding) -> String { "square \(side), area-resized, centred, padding \(padding)" }

    /// The content's index a square's position `i` (relative to the content's origin) reads, for content `n` long.
    @inline(__always) static func source(_ i: Int, count n: Int, padding: Padding) -> Int {
        guard i < 0 || i >= n else { return i }
        guard n > 1, padding.mirrored > 0 else { return min(max(i, 0), n - 1) }
        // How far past the edge, held to the mirrored lines, then mirrored about the edge pixel.
        let past = min(i < 0 ? -i : i - (n - 1), padding.mirrored)
        let period = 2 * (n - 1)
        var j = (i < 0 ? past : n - 1 + past) % period
        if j >= n { j = period - j }
        return j
    }

    /// Each channel's 256 codes normalised: `((code / 255) − mean) / std` in float32, to half, as numpy computes it, so a table
    /// gives the same bits as the arithmetic and costs a lookup a value.
    private static let normalised: [[Float16]] = (0..<3).map { c in
        (0...255).map { Float16(((Float($0) / 255) - mean[c]) / std[c]) }
    }

    /// A picture already the content's size, interleaved 8-bit RGB, top row first: padded and normalised.
    public init(contentRGB8 content: [UInt8], layout: ModelSquareLayout, padding: Padding = .edge) {
        precondition(content.count == layout.contentWidth * layout.contentHeight * 3, "content is contentWidth × contentHeight RGB")
        let n = layout.side, plane = n * n
        var input = [Float16](repeating: 0, count: 3 * plane)
        let (r, g, b) = (Self.normalised[0], Self.normalised[1], Self.normalised[2])
        if padding.isBlack {
            // Black all round, code 0 normalised as any other pixel is, then the picture over it: S3OD's square (V4).
            for c in 0..<3 { for i in 0..<plane { input[c * plane + i] = Self.normalised[c][0] } }
            for y in 0..<layout.contentHeight {
                let s = y * layout.contentWidth * 3, d = (y + layout.originY) * n + layout.originX
                for x in 0..<layout.contentWidth {
                    input[d + x] = r[Int(content[s + x * 3])]
                    input[plane + d + x] = g[Int(content[s + x * 3 + 1])]
                    input[2 * plane + d + x] = b[Int(content[s + x * 3 + 2])]
                }
            }
            self.init(layout: layout, padding: padding, input: input)
            return
        }
        r.withUnsafeBufferPointer { r in g.withUnsafeBufferPointer { g in b.withUnsafeBufferPointer { b in
            content.withUnsafeBufferPointer { src in
                input.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<n {
                        let row = Self.source(y - layout.originY, count: layout.contentHeight, padding: padding) * layout.contentWidth
                        for x in 0..<n {
                            let s = (row + Self.source(x - layout.originX, count: layout.contentWidth, padding: padding)) * 3, d = y * n + x
                            dst[d] = r[Int(src[s])]
                            dst[plane + d] = g[Int(src[s + 1])]
                            dst[2 * plane + d] = b[Int(src[s + 2])]
                        }
                    }
                }
            }
        } } }
        self.init(layout: layout, padding: padding, input: input)
    }

    /// A plane of a model's output over its square, `planeSide` pixels a side (the square's own, or a quarter of it for EoMT),
    /// cropped to the content, row-major.
    public static func crop(_ plane: [Float], planeSide: Int, layout: ModelSquareLayout) -> [Float] {
        precondition(planeSide == layout.side && plane.count == planeSide * planeSide, "crop takes a plane at the square's own size")
        var out = [Float](repeating: 0, count: layout.contentWidth * layout.contentHeight)
        for y in 0..<layout.contentHeight {
            let src = (y + layout.originY) * planeSide + layout.originX
            for x in 0..<layout.contentWidth { out[y * layout.contentWidth + x] = plane[src + x] }
        }
        return out
    }

    /// A plane of a model's output over its square, `planeSide` pixels a side, sampled bilinearly at each pixel centre of a
    /// `width` by `height` grid laid over the content (P0-S5's `EomtInput.resample`, which its veto's golden masks were made with):
    /// y = (originY + (i + 0.5) contentHeight / height) / k − 0.5, with k the square's pixels to a plane pixel, x likewise.
    public static func resample(_ plane: [Float], planeSide: Int, layout: ModelSquareLayout, toWidth width: Int, height: Int) -> [Float] {
        precondition(plane.count == planeSide * planeSide, "a plane is planeSide × planeSide")
        var out = [Float](repeating: 0, count: width * height)
        let k = Double(layout.side) / Double(planeSide)
        let last = Double(planeSide - 1)
        for y in 0..<height {
            let fy = min(max((Double(layout.originY) + (Double(y) + 0.5) * Double(layout.contentHeight) / Double(height)) / k - 0.5, 0), last)
            let y0 = Int(fy.rounded(.down)), y1 = min(y0 + 1, planeSide - 1), wy = Float(fy - Double(y0))
            for x in 0..<width {
                let fx = min(max((Double(layout.originX) + (Double(x) + 0.5) * Double(layout.contentWidth) / Double(width)) / k - 0.5, 0), last)
                let x0 = Int(fx.rounded(.down)), x1 = min(x0 + 1, planeSide - 1), wx = Float(fx - Double(x0))
                let a = plane[y0 * planeSide + x0], b = plane[y0 * planeSide + x1]
                let c = plane[y1 * planeSide + x0], d = plane[y1 * planeSide + x1]
                out[y * width + x] = (a * (1 - wx) + b * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy
            }
        }
        return out
    }

    // MARK: OpenCV's INTER_AREA

    struct Tap { var dst: Int; var src: Int; var alpha: Float }

    /// The fractional-box weights of a resize from `srcSize` to `dstSize` samples, as OpenCV's `computeResizeAreaTab`.
    static func areaTable(srcSize: Int, dstSize: Int) -> [Tap] {
        let scale = Double(srcSize) / Double(dstSize)
        var table: [Tap] = []
        table.reserveCapacity(srcSize * 2)
        for d in 0..<dstSize {
            let f1 = Double(d) * scale, f2 = f1 + scale
            let cell = min(scale, Double(srcSize) - f1)
            var s1 = Int(f1.rounded(.up)), s2 = Int(f2.rounded(.down))
            s2 = min(s2, srcSize - 1)
            s1 = min(s1, s2)
            if Double(s1) - f1 > 1e-3 { table.append(Tap(dst: d, src: s1 - 1, alpha: Float((Double(s1) - f1) / cell))) }
            if s1 < s2 { for s in s1..<s2 { table.append(Tap(dst: d, src: s, alpha: Float(1.0 / cell))) } }
            if f2 - Double(s2) > 1e-3 { table.append(Tap(dst: d, src: s2, alpha: Float(min(min(f2 - Double(s2), 1.0), cell) / cell))) }
        }
        return table
    }

    /// An 8-bit picture, `bytesPerPixel` bytes a pixel of which the first three are R, G and B, area-resized to `toWidth` by
    /// `height` interleaved RGB: horizontal then vertical, float32 sums, rounded half to even (S1b's `areaResize`).
    public static func areaResize(_ src: UnsafeRawBufferPointer, width srcW: Int, height srcH: Int, bytesPerPixel: Int, bytesPerRow: Int,
                                  toWidth dstW: Int, height dstH: Int) -> [UInt8] {
        let xt = areaTable(srcSize: srcW, dstSize: dstW), yt = areaTable(srcSize: srcH, dstSize: dstH)
        var tmp = [Float](repeating: 0, count: srcH * dstW * 3)
        tmp.withUnsafeMutableBufferPointer { tp in
            for y in 0..<srcH {
                let row = y * bytesPerRow, trow = y * dstW * 3
                for t in xt {
                    let a = t.alpha, si = row + t.src * bytesPerPixel, di = trow + t.dst * 3
                    tp[di] += a * Float(src[si]); tp[di + 1] += a * Float(src[si + 1]); tp[di + 2] += a * Float(src[si + 2])
                }
            }
        }
        var acc = [Float](repeating: 0, count: dstH * dstW * 3)
        tmp.withUnsafeBufferPointer { tp in
            acc.withUnsafeMutableBufferPointer { ap in
                for t in yt {
                    let a = t.alpha, trow = t.src * dstW * 3, arow = t.dst * dstW * 3
                    for i in 0..<(dstW * 3) { ap[arow + i] += a * tp[trow + i] }
                }
            }
        }
        return acc.map { UInt8(min(max($0.rounded(.toNearestOrEven), 0), 255)) }
    }

    /// The same for interleaved 8-bit RGB.
    public static func areaResize(_ rgb8: [UInt8], width: Int, height: Int, toWidth dstW: Int, height dstH: Int) -> [UInt8] {
        rgb8.withUnsafeBytes { areaResize($0, width: width, height: height, bytesPerPixel: 3, bytesPerRow: width * 3, toWidth: dstW, height: dstH) }
    }
}
