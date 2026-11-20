import CoreGraphics
import CryptoKit
import Foundation
import Metal

/// The picture every smart mask is made from, Vision's and the bundled models' alike (docs/masking-plan.md section 3, "What goes
/// in"): the frame's own decode through the neutral print, `LUT3D.neutralPrint`, at the decode's own size, then area-resized to
/// `longSide` pixels on its longer side and rounded to 8 bits. It does not depend on stock, grain or edits, so a mask never reads
/// edited pixels (plan section 4, rule 3), and it is made once a frame from the decode the frame view already holds.
///
/// One pixel path, always: an 8-bit `CGImage`, tagged sRGB as `argent-spike` tags its neutral prints, which are what R2, R4, S1b,
/// S3, S4 and S5 measured with. Vision's results move slightly with the path (a linear half-float image changes its bytes, R2), and
/// S5's water gate (0.03) was set on these prints at 2560 pixels. Not `FilmPreviews.frameNeutral`, which shows scene light as display
/// light and clips 2.47 stops over mid-gray: skies clip there.
///
/// The bundled models take the same print area-resized on the GPU straight to their squares' content (`modelContents`), S1b's
/// route B, which matched the prints Phase 0's references were made from within 0.8 codes on average.
public struct MaskInputPicture: @unchecked Sendable {
    /// The longer side, in pixels: Vision's measured input size (R2, S3) and the size S5's gate was set at.
    public static let longSide = 2560
    /// What `RasterProvenance.Input.kind` records for it.
    public static let kind = "neutral-print"
    /// R, G, B and a byte left unused.
    public static let bytesPerPixel = 4

    /// The picture, top row first, 8 bits a channel in sRGB's codes.
    public let image: CGImage
    public let width: Int
    public let height: Int
    /// What it was made from.
    public let source: Source
    /// The same print area-resized to the content of each bundled model's square (`ModelSquareLayout(side:width:height:)` for this
    /// picture's size), interleaved 8-bit RGB, top row first, by the square's side: 756 for the Sky model, 768 for the water model.
    public let modelContents: [Int: [UInt8]]
    /// The squares' sides the maker makes contents for.
    public static let modelSides = [SkyModelRunner.side, EomtModelRunner.side]
    /// The median Rec. 2020 luminance of the linear decode the picture was made from (the click's own, untouched): what the low-light
    /// rule reads (`LowLightRule`). `nil` for a picture not made by the maker, or a decode whose median is not a number, which then
    /// has no scene brightness and passes the rule only by its ISO clause.
    public let medianLuminance: Float?
    /// The bytes behind `image`, `bytesPerPixel` a pixel, rows `width * bytesPerPixel` long.
    private let pixels: CFData

    /// The decode a picture was made from, which is what makes two pictures of one frame differ.
    public struct Source: Sendable, Equatable, Codable {
        public var decodeWidth: Int
        public var decodeHeight: Int
        /// `LinearFrame.decoderVersion`.
        public var decoderVersion: String
        /// The decoder's settings, `nil` for a frame that came through none.
        public var pinsVersion: String?
        public var pinsDecoderVersion: String?
        /// The decode's scale against the raw's full size: 1 when it is the whole raw.
        public var decodeScale: Float
        /// The full-size upright picture the decode stands for (`LinearFrame.picture`; the decode's size over its scale for a frame
        /// that records none), and whether the decode corrected the lens: what a smart mask's `MaskFrame` records.
        public var pictureWidth: Int
        public var pictureHeight: Int
        public var lensCorrection: Bool
        public var geometry: LensGeometry?

        public init(decodeWidth: Int, decodeHeight: Int, decoderVersion: String, pinsVersion: String?, pinsDecoderVersion: String?,
                    decodeScale: Float, pictureWidth: Int? = nil, pictureHeight: Int? = nil, lensCorrection: Bool = true, geometry: LensGeometry? = nil) {
            self.decodeWidth = decodeWidth; self.decodeHeight = decodeHeight; self.decoderVersion = decoderVersion
            self.pinsVersion = pinsVersion; self.pinsDecoderVersion = pinsDecoderVersion; self.decodeScale = decodeScale
            let scale = max(decodeScale, .leastNonzeroMagnitude)
            self.pictureWidth = pictureWidth ?? Int((Float(decodeWidth) / scale).rounded())
            self.pictureHeight = pictureHeight ?? Int((Float(decodeHeight) / scale).rounded())
            self.lensCorrection = lensCorrection
            self.geometry = geometry
        }
    }

    init(pixels: CFData, width: Int, height: Int, source: Source, modelContents: [Int: [UInt8]] = [:], medianLuminance: Float? = nil) throws {
        guard let provider = CGDataProvider(data: pixels),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * Self.bytesPerPixel,
                                  bytesPerRow: width * Self.bytesPerPixel, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw MaskInputError.imageCreation }
        self.image = image
        self.width = width
        self.height = height
        self.source = source
        self.pixels = pixels
        self.modelContents = modelContents
        self.medianLuminance = medianLuminance
    }

    /// The bytes it holds: 18.6 MB at 2560 × 1707 with the models' contents.
    public var byteCount: Int { width * height * Self.bytesPerPixel + modelContents.values.reduce(0) { $0 + $1.count } }

    /// Calls `body` with the picture's bytes and the length of a row.
    public func withPixels<R>(_ body: (UnsafeRawBufferPointer, Int) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: CFDataGetBytePtr(pixels), count: CFDataGetLength(pixels)), width * Self.bytesPerPixel)
    }

    /// Calls `body` with the picture's bytes and the length of a row, for a body that suspends (the matte's model): the bytes stay alive for the call.
    public func withPixelsAsync<R>(_ body: (UnsafeRawBufferPointer, Int) async throws -> R) async rethrows -> R {
        let pixels = self.pixels
        let result = try await body(UnsafeRawBufferPointer(start: CFDataGetBytePtr(pixels), count: CFDataGetLength(pixels)), width * Self.bytesPerPixel)
        withExtendedLifetime(pixels) {}
        return result
    }

    /// The SHA-256 of its R, G and B bytes, row by row from the top: names the picture a seed was made from.
    public var digest: String {
        withPixels { bytes, rowBytes in
            var hash = SHA256()
            var row = [UInt8](repeating: 0, count: width * 3)
            for y in 0..<height {
                for x in 0..<width {
                    let s = y * rowBytes + x * Self.bytesPerPixel
                    row[x * 3] = bytes[s]; row[x * 3 + 1] = bytes[s + 1]; row[x * 3 + 2] = bytes[s + 2]
                }
                hash.update(data: row)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// What a seed made from it records of its input, for the raw whose SHA-256 is `sourceSHA256`.
    public func provenance(sourceSHA256: String) -> RasterProvenance.Input {
        RasterProvenance.Input(kind: Self.kind, decoderVersion: source.pinsDecoderVersion ?? source.decoderVersion,
                               pinsVersion: source.pinsVersion, width: width, height: height, colorSpace: "sRGB",
                               sourceSHA256: sourceSHA256)
    }

    /// The size a `width` by `height` decode makes: `longSide` on its longer side, the other rounded as `AreaResize` rounds it, or
    /// the decode's own size when it is no longer than that.
    public static func size(decodeWidth width: Int, decodeHeight height: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > longSide else { return (width, height) }
        return AreaResize.size(width: width, height: height, scale: Double(longSide) / Double(long))
    }

    /// Whether a decode `longSide` pixels long at `scale` of the raw can make the picture: it is at least `longSide` long, or it
    /// is the whole raw and nothing larger exists.
    public static func canBeMade(fromDecodeLongSide decodeLongSide: Int, scale: Float) -> Bool {
        decodeLongSide >= longSide || scale >= 1
    }
}

public enum MaskInputError: Error, CustomStringConvertible, Equatable {
    /// The decode is a scaled one shorter than `MaskInputPicture.longSide`: it needs a larger decode, not an enlargement.
    case decodeTooSmall(longSide: Int)
    case imageCreation

    public var description: String {
        switch self {
        case .decodeTooSmall(let side):
            return "a decode \(side) pixels long is too small for the mask input picture (\(MaskInputPicture.longSide)); decode the frame larger"
        case .imageCreation: return "could not make the mask input picture's image"
        }
    }
}

/// Makes `MaskInputPicture`s on one GPU: the neutral print's pass at the decode's size, the area resizes to the picture and to the
/// models' squares, and the read back, in one command buffer (S1b's route B: 3 to 5 ms of GPU from a 4912-pixel decode for one
/// resize, about 2 ms to read back). The print is made at the decode's size before any resize, as the prints Phase 0 measured with
/// were: resizing first moved S1b's seeds by up to 2 percent. Use one from one thread at a time.
public final class MaskInputPictureMaker {
    private let gpu: GPU
    private let pass: LUTPass
    private let resize: AreaResize
    private let lut: LUT3D
    private let lutTexture: MTLTexture

    /// Builds the passes; call it on one thread, as the shader library is not thread-safe.
    public init(gpu: GPU) throws {
        self.gpu = gpu
        pass = try LUTPass(gpu: gpu)
        resize = try AreaResize(gpu: gpu)
        lut = LUT3D.neutralPrint()
        lutTexture = try lut.makeTexture(device: gpu.device)
    }

    /// The picture of `frame`, a decode at least `MaskInputPicture.longSide` long or the whole raw.
    public func make(from frame: LinearFrame) throws -> MaskInputPicture {
        let (w, h) = (frame.width, frame.height)
        guard MaskInputPicture.canBeMade(fromDecodeLongSide: max(w, h), scale: frame.scale) else {
            throw MaskInputError.decodeTooSmall(longSide: max(w, h))
        }
        let size = MaskInputPicture.size(decodeWidth: w, decodeHeight: h)
        let printed = try gpu.texturePool.acquire(width: w, height: h)
        let small = (size.width, size.height) == (w, h) ? nil : try gpu.texturePool.acquire(width: size.width, height: size.height)
        let layouts = MaskInputPicture.modelSides.map { ModelSquareLayout(side: $0, width: size.width, height: size.height) }
        let contents = try layouts.map { try gpu.texturePool.acquire(width: $0.contentWidth, height: $0.contentHeight) }
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        try pass.encode(input: frame.texture, output: printed.texture, lut: lutTexture, params: lut.params, into: commandBuffer)
        if let small { try resize.encode(printed.texture, to: small.texture, into: commandBuffer) }
        for content in contents { try resize.encode(printed.texture, to: content.texture, into: commandBuffer) }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        let result = small?.texture ?? printed.texture
        let pixels = Self.readBack(result)
        var modelContents: [Int: [UInt8]] = [:]
        for (layout, content) in zip(layouts, contents) {
            let rgbx = Self.readBack(content.texture) as Data
            modelContents[layout.side] = rgbx.withUnsafeBytes { bytes in
                var rgb = [UInt8](repeating: 0, count: layout.contentWidth * layout.contentHeight * 3)
                rgb.withUnsafeMutableBufferPointer { out in
                    for i in 0..<(layout.contentWidth * layout.contentHeight) {
                        out[i * 3] = bytes[i * 4]; out[i * 3 + 1] = bytes[i * 4 + 1]; out[i * 3 + 2] = bytes[i * 4 + 2]
                    }
                }
                return rgb
            }
        }
        withExtendedLifetime((printed, small, contents)) {}
        let source = MaskInputPicture.Source(decodeWidth: w, decodeHeight: h, decoderVersion: frame.decoderVersion,
                                             pinsVersion: frame.pins?.version, pinsDecoderVersion: frame.pins?.decoderVersion,
                                             decodeScale: frame.scale, pictureWidth: frame.picture?.width,
                                             pictureHeight: frame.picture?.height, lensCorrection: frame.pins?.lensCorrection ?? true, geometry: frame.lens?.geometry)
        return try MaskInputPicture(pixels: pixels, width: size.width, height: size.height, source: source, modelContents: modelContents,
                                    medianLuminance: Self.medianLuminance(of: frame.texture))
    }

    /// The median Rec. 2020 luminance (0.2627, 0.6780, 0.0593) of `texture`, as X1's rule defines it and `np.median` computes it on
    /// float32: the middle value, or for an even count the mean of the two middle values. `nil` for a median that is not a number.
    /// Read from the decode itself, before the neutral print: it describes the scene, not a print.
    ///
    /// Read a strip of rows at a time and counted, never held whole (`LowLightRule.median(counting:)`): every picture has one, though
    /// only Subject's rule reads it, since a picture is made before its kind is known and from a decode nothing keeps. With the frame
    /// view zoomed the decode is the whole raw, 7008 by 4672: held whole that was 262 MB read back and 131 MB of luminances for a
    /// quickselect; counted it is the same number from 6 MB (the selection alone on a buffer of that size, optimized, 2026-11-09:
    /// 266 ms held whole, 55 ms counted).
    static func medianLuminance(of texture: MTLTexture) -> Float? {
        let w = texture.width, h = texture.height
        guard w > 0, h > 0 else { return nil }
        let rows = max(1, min(h, medianStripTexels / w))
        var half = [UInt16](repeating: 0, count: w * rows * 4)
        var luma = [Float](repeating: 0, count: w * rows)
        return LowLightRule.median { take in
            var y = 0
            while y < h {
                let n = min(rows, h - y)
                half.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, y, w, n), mipmapLevel: 0) }
                half.withUnsafeBufferPointer { src in
                    luma.withUnsafeMutableBufferPointer { out in
                        for i in 0..<(w * n) {
                            let r = Float(Float16(bitPattern: src[i * 4])), g = Float(Float16(bitPattern: src[i * 4 + 1])), b = Float(Float16(bitPattern: src[i * 4 + 2]))
                            out[i] = 0.2627 * r + 0.6780 * g + 0.0593 * b
                        }
                        take(UnsafeBufferPointer(rebasing: out[0..<(w * n)]))
                    }
                }
                y += n
            }
        }
    }

    /// How many texels of the decode `medianLuminance` reads at a time: 4 MB of half floats and 2 MB of luminances.
    static let medianStripTexels = 1 << 19

    /// The half-float texture's codes in 8 bits, rounded half to even and clamped, top row first: Argent's textures hold the
    /// picture's bottom row first, as Core Image does.
    static func readBack(_ texture: MTLTexture) -> CFData {
        let w = texture.width, h = texture.height
        var half = [UInt16](repeating: 0, count: w * h * 4)
        half.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        let n = w * h * MaskInputPicture.bytesPerPixel
        let data = CFDataCreateMutable(nil, n)!
        CFDataSetLength(data, n)
        let out = CFDataGetMutableBytePtr(data)!
        codes.withUnsafeBufferPointer { codes in
            half.withUnsafeBufferPointer { src in
                for y in 0..<h {
                    let s = (h - 1 - y) * w * 4, d = y * w * MaskInputPicture.bytesPerPixel
                    for x in 0..<w {
                        let i = x * 4
                        out[d + i] = codes[Int(src[s + i])]
                        out[d + i + 1] = codes[Int(src[s + i + 1])]
                        out[d + i + 2] = codes[Int(src[s + i + 2])]
                        out[d + i + 3] = 255
                    }
                }
            }
        }
        return data
    }

    /// Every half float's 8-bit code, `v × 255` rounded half to even and clamped to 0...255 (NaN to 0), by its bits: a lookup a
    /// value where the arithmetic cost a second a picture in a debug build.
    private static let codes: [UInt8] = (0...UInt16.max).map { bits in
        let v = Float(Float16(bitPattern: bits)) * 255
        return v.isNaN ? 0 : UInt8(min(max(v.rounded(.toNearestOrEven), 0), 255))
    }
}
