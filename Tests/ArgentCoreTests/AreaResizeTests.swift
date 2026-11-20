import Foundation
import Metal
import Testing
@testable import ArgentCore

@Suite struct AreaResizeTests {
    /// A texture holding `values`, four channels a pixel, rows as given.
    private func texture(_ gpu: GPU, width: Int, height: Int, _ values: [Float]) throws -> MTLTexture {
        let texture = try gpu.makeTexture(width: width, height: height)
        let half = values.map { Float16($0) }
        half.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                               withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return texture
    }

    /// Values from a fixed generator, so a failure repeats.
    private func noise(_ count: Int, seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
    }

    /// The area resize computed on the CPU in double precision: each output pixel's footprint
    /// `[i * in / out, (i + 1) * in / out)` on both axes, partial pixels weighted by the share
    /// inside.
    private func reference(_ values: [Float], width: Int, height: Int, outWidth: Int, outHeight: Int) -> [Double] {
        func weights(_ i: Int, _ n: Int, _ m: Int) -> [(Int, Double)] {
            let a = Double(i * n) / Double(m), b = Double((i + 1) * n) / Double(m)
            return (Int(a.rounded(.down))..<min(n, Int(b.rounded(.up)))).map { ($0, min(Double($0 + 1), b) - max(Double($0), a)) }
        }
        var out = [Double](repeating: 0, count: outWidth * outHeight * 4)
        for y in 0..<outHeight {
            let wy = weights(y, height, outHeight)
            for x in 0..<outWidth {
                let wx = weights(x, width, outWidth)
                for c in 0..<4 {
                    var sum = 0.0, total = 0.0
                    for (sy, a) in wy { for (sx, b) in wx {
                        sum += a * b * Double(Float16(values[(sy * width + sx) * 4 + c]))
                        total += a * b
                    } }
                    out[(y * outWidth + x) * 4 + c] = sum / total
                }
            }
        }
        return out
    }

    /// Long-edge sizes come out exactly as before: each side rounded, the long one exact.
    @Test func theSizeIsEachSideRounded() {
        for (width, height, longEdge, expected) in [(7008, 4672, 2048, (2048, 1365)), (7008, 4672, 4096, (4096, 2731)),
                                                    (4672, 7008, 2048, (1365, 2048)), (701, 467, 409, (409, 272)),
                                                    (6000, 10, 960, (960, 2))] {
            let size = AreaResize.size(width: width, height: height, scale: Double(longEdge) / Double(max(width, height)))
            #expect(size.width == expected.0 && size.height == expected.1, "\(width)x\(height) to \(longEdge): \(size)")
        }
    }

    @Test func aFlatFieldStaysFlat() throws {
        let gpu = try GPU()
        let resize = try AreaResize(gpu: gpu)
        let pixel: [Float] = [0.18, 0.5, 0.03, 1]
        let values = [[Float]](repeating: pixel, count: 701 * 467).flatMap { $0 }
        let out = try resize.resized(try texture(gpu, width: 701, height: 467, values), scale: 409.0 / 701)
        #expect(out.width == 409 && out.height == 272)
        let pixels = ExposureAnalyzer.pixels(of: out.texture)
        for (c, value) in pixel.enumerated() {
            let channel = stride(from: c, to: pixels.count, by: 4).map { Float(pixels[$0]) }
            #expect(channel.allSatisfy { $0 == Float(Float16(value)) }, "channel \(c): \(channel.min()!)...\(channel.max()!)")
        }
    }

    /// An edge, lines and noise: nothing comes out beyond the input's range, as Lanczos did.
    @Test func nothingOvershootsTheInput() throws {
        let gpu = try GPU()
        let resize = try AreaResize(gpu: gpu)
        let width = 997, height = 331
        var values: [Float] = []
        let jitter = noise(width * height)
        for y in 0..<height {
            for x in 0..<width {
                // A step from near black to white, one-pixel white lines, and noise in the dark.
                let v: Float = x < 400 ? 0.01 : x < 700 ? 1 : (x % 7 == 0 ? 1 : 0.02 * jitter[y * width + x])
                values += [v, v, v, 1]
            }
        }
        for scale in [0.2922, 0.5, 0.731, 0.95] {
            let out = try resize.resized(try texture(gpu, width: width, height: height, values), scale: scale)
            let pixels = ExposureAnalyzer.pixels(of: out.texture).map(Float.init)
            #expect(pixels.min()! >= 0 && pixels.max()! <= 1, "scale \(scale): \(pixels.min()!)...\(pixels.max()!)")
            // The dark side of the step stays at its value right up to the pixel the edge cuts.
            let edge = Int(400 * Double(out.width) / Double(width))
            let row = out.height / 2
            for x in 0..<edge { #expect(abs(pixels[(row * out.width + x) * 4] - Float(Float16(0.01))) < 1e-5) }
        }
    }

    /// Every input pixel counts the same in total, so the mean is kept, at 7008 to 2048 too.
    @Test func theMeanIsKept() throws {
        let gpu = try GPU()
        let resize = try AreaResize(gpu: gpu)
        let width = 1752, height = 1168
        let values = noise(width * height * 4, seed: 11)
        let input = try texture(gpu, width: width, height: height, values)
        let inputMean = ExposureAnalyzer.pixels(of: input).enumerated().filter { $0.offset % 4 == 0 }
            .reduce(0.0) { $0 + Double($1.element) } / Double(width * height)
        for scale in [512.0 / 1752, 1024.0 / 1752, 0.9] {
            let out = try resize.resized(input, scale: scale)
            let pixels = ExposureAnalyzer.pixels(of: out.texture)
            let mean = stride(from: 0, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) } / Double(out.width * out.height)
            #expect(abs(mean - inputMean) < 2e-4, "scale \(scale): \(mean) against \(inputMean)")
        }
    }

    /// Fed a piece at a time, as the frame view's refinement feeds it Apple's tiles, the resize comes
    /// out as the whole one: the same where a pixel's footprint lies in one piece, and at most a
    /// step of a half float off where pieces share it. Pieces larger and smaller than a footprint,
    /// the last in each row and column cut short.
    @Test(arguments: [(1000, 700, 0.2411, 128), (997, 331, 0.731, 200), (50, 40, 0.2, 3)])
    func piecesComeOutAsTheWholeResize(_ width: Int, _ height: Int, _ scale: Double, _ side: Int) throws {
        let gpu = try GPU()
        let resize = try AreaResize(gpu: gpu)
        let values = noise(width * height * 4, seed: UInt64(side))
        let source = try texture(gpu, width: width, height: height, values)
        let whole = try resize.resized(source, scale: scale)
        let output = try gpu.makeTexture(width: whole.width, height: whole.height)
        let pieces = try resize.pieces(sourceWidth: width, sourceHeight: height, onto: output)
        for y in stride(from: 0, to: height, by: side) {
            for x in stride(from: 0, to: width, by: side) {
                let piece = try gpu.makeTexture(width: min(side, width - x), height: min(side, height - y))
                let rows = (y..<y + piece.height).flatMap { row in values[(row * width + x) * 4..<(row * width + x + piece.width) * 4] }
                let half = rows.map { Float16($0) }
                half.withUnsafeBytes { piece.replace(region: MTLRegionMake2D(0, 0, piece.width, piece.height), mipmapLevel: 0,
                                                     withBytes: $0.baseAddress!, bytesPerRow: piece.width * 8) }
                try pieces.add(piece, x: x, y: y)
            }
        }
        try pieces.finish()
        // The output columns and rows whose footprints a piece's edge cuts through.
        func shared(_ count: Int, _ length: Int) -> Set<Int> {
            Set(stride(from: side, to: length, by: side).filter { ($0 * count) % length != 0 }.map { $0 * count / length })
        }
        let columns = shared(whole.width, width), rows = shared(whole.height, height)
        let expected = ExposureAnalyzer.pixels(of: whole.texture), made = ExposureAnalyzer.pixels(of: output)
        var differing = 0
        for (i, (a, b)) in zip(made, expected).enumerated() where a != b {
            differing += 1
            let pixel = i / 4
            #expect(columns.contains(pixel % whole.width) || rows.contains(pixel / whole.width), "pixel \(pixel % whole.width), \(pixel / whole.width)")
            #expect(a.nextUp == b || a.nextDown == b, "\(a) against \(b)")
        }
        print("MEASURE pieces of \(side) on \(width)x\(height) to \(whole.width)x\(whole.height): \(differing) of \(made.count) samples differ")
    }

    /// 7008 to 2048 is 3.421875 input pixels an output pixel across, and the 4672 rows come to
    /// 1365, 3.42271 each: every pixel, the last row and column with them, is the exact mean of
    /// its footprint, fractional pixels and all.
    @Test func anOddScaleCoversEachFootprintExactly() throws {
        let gpu = try GPU()
        let resize = try AreaResize(gpu: gpu)
        let scale = 2048.0 / 7008
        for (width, height) in [(7008, 13), (11, 4672)] {
            let values = noise(width * height * 4, seed: UInt64(width))
            let out = try resize.resized(try texture(gpu, width: width, height: height, values), scale: scale)
            let size = AreaResize.size(width: width, height: height, scale: scale)
            #expect(out.width == size.width && out.height == size.height)
            let expected = reference(values, width: width, height: height, outWidth: out.width, outHeight: out.height)
            let pixels = ExposureAnalyzer.pixels(of: out.texture)
            var worst = 0.0
            for i in expected.indices { worst = max(worst, abs(Double(pixels[i]) - expected[i])) }
            // Half-float output: 2^-11 of a value up to 1.
            #expect(worst < 6e-4, "\(width)x\(height): worst \(worst)")
            // The last column and row in particular.
            let last = ((out.height - 1) * out.width + out.width - 1) * 4
            #expect(abs(Double(pixels[last]) - expected[last]) < 6e-4)
        }
    }
}
