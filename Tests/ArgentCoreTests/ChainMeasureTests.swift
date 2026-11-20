import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// The app's chain stage by stage on a chart, for comparing with the bake's Python model
/// (docs/M3-auto.md section 19). Runs only with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 ARGENT_CHART_RAW=FILE.ARW ARGENT_CHART_CORNERS=x0,y0,x1,y1,x2,y2,x3,y3 \
///     ARGENT_STOCK=build/stocks/kodak-portra-400 ARGENT_OUT=chart.json \
///         swift test --skip-build --filter ChainMeasureTests/chart
///     ARGENT_MEASURE=1 ARGENT_PATCHES=in.json ARGENT_STOCK=... ARGENT_OUT=out.json \
///         swift test --skip-build --filter ChainMeasureTests/patches
///
/// `chart` decodes a raw with Apple's RAW 8 in one piece (`DecodeOptions()`; a develop takes RAW 9
/// in tiles), or with the in-house decoder with ARGENT_DECODER=inhouse, samples the 24 patches (corners: the centres of dark skin, bluish
/// green, white and black, boxes of 80 by 80) in the decoded linear Rec. 2020 frame and in the
/// film render's display-linear Rec. 2020, and writes both. `patches` takes linear Rec. 2020
/// values (`{"rgb": [[r, g, b], ...]}`, optional `"exposureStops"`) through the film render
/// alone and through the sRGB encode, and writes the display-linear and the 8-bit sRGB values.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"))
struct ChainMeasureTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func means(_ texture: MTLTexture, at centres: [(Double, Double)], half: Int) -> [[Double]] {
        centres.map { centre in
            let x0 = Int(centre.0) - half, y0 = Int(centre.1) - half, side = 2 * half
            var halves = [Float16](repeating: 0, count: side * side * 4)
            halves.withUnsafeMutableBytes { buffer in
                texture.getBytes(buffer.baseAddress!, bytesPerRow: side * 8,
                                 from: MTLRegionMake2D(x0, y0, side, side), mipmapLevel: 0)
            }
            var sum = [0.0, 0.0, 0.0]
            for i in 0..<(side * side) { for c in 0..<3 { sum[c] += Double(halves[i * 4 + c]) } }
            return sum.map { $0 / Double(side * side) }
        }
    }

    /// Patch centres in reading order from the four corner centres, as `sample_one.py` places them.
    private static func centres(_ c: [Double]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for r in 0..<4 {
            let v = Double(r) / 3
            for k in 0..<6 {
                let u = Double(k) / 5
                let x = (1 - u) * (1 - v) * c[0] + u * (1 - v) * c[2] + (1 - u) * v * c[4] + u * v * c[6]
                let y = (1 - u) * (1 - v) * c[1] + u * (1 - v) * c[3] + (1 - u) * v * c[5] + u * v * c[7]
                out.append((x, y))
            }
        }
        return out
    }

    private static func write(_ object: [String: Any]) throws {
        let url = URL(fileURLWithPath: environment["ARGENT_OUT"] ?? "chain.json")
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    @Test func chart() throws {
        let gpu = try GPU()
        let raw = URL(fileURLWithPath: try #require(Self.environment["ARGENT_CHART_RAW"]))
        let corners = try #require(Self.environment["ARGENT_CHART_CORNERS"]).split(separator: ",").compactMap { Double($0) }
        try #require(corners.count == 8)
        let stock = try Stock.load(from: URL(fileURLWithPath: try #require(Self.environment["ARGENT_STOCK"])))
        let decoder: RawDecoder = Self.environment["ARGENT_DECODER"] == "inhouse" ? try InHouseDecoder(gpu: gpu) : AppleRawDecoder(gpu: gpu)
        let frame = try decoder.decode(raw, options: DecodeOptions())
        // Core Image renders into a texture with its origin at the bottom, so a picture's row y is
        // the texture's row height - 1 - y.
        let points = Self.centres(corners).map { ($0.0, Double(frame.height - 1) - $0.1) }
        let linear = Self.means(frame.texture, at: points, half: 40)
        let rendered = try FilmRenderer(gpu: gpu, stock: stock).render(frame, settings: DevelopSettings())
        let print = Self.means(rendered.image.texture, at: points, half: 40)
        var pins: [String: Any] = [:]
        if let p = frame.pins {
            pins = ["gainStops": p.exposureGainStops, "rawMode": p.rawMode ?? "unprofiled",
                    "neutral": [p.neutralChromaticity.x, p.neutralChromaticity.y]]
        }
        try Self.write(["linear": linear, "print": print, "pins": pins, "decoder": frame.decoderVersion,
                        "width": frame.width, "height": frame.height])
    }

    @Test func patches() throws {
        let gpu = try GPU()
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try #require(Self.environment["ARGENT_PATCHES"])))) as! [String: Any]
        let rgb = (input["rgb"] as! [[Double]])
        let stock = try Stock.load(from: URL(fileURLWithPath: try #require(Self.environment["ARGENT_STOCK"])))
        // One 4 by 4 block per patch, so the encode's chroma handling cannot mix neighbours.
        let block = 4, columns = 16
        let rows = (rgb.count + columns - 1) / columns
        let width = columns * block, height = rows * block
        let texture = try gpu.makeTexture(width: width, height: height)
        var halves = [Float16](repeating: 0, count: width * height * 4)
        for (i, v) in rgb.enumerated() {
            for dy in 0..<block { for dx in 0..<block {
                let p = ((i / columns) * block + dy) * width + (i % columns) * block + dx
                halves[p * 4] = Float16(v[0]); halves[p * 4 + 1] = Float16(v[1]); halves[p * 4 + 2] = Float16(v[2]); halves[p * 4 + 3] = 1
            } }
        }
        halves.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                 withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        let frame = LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "test", scale: 1)
        var settings = DevelopSettings()
        if let stops = input["exposureStops"] as? Double {
            settings.ratedAt = stock.boxSpeed / Float(exp2(stops))
        }
        let rendered = try FilmRenderer(gpu: gpu, stock: stock).render(frame, settings: settings)
        let centres = rgb.indices.map { i in (Double((i % columns) * block + block / 2), Double((i / columns) * block + block / 2)) }
        let print = Self.means(rendered.image.texture, at: centres, half: 1)
        // The 8-bit sRGB values a JPEG develop encodes, through the app's own encoder.
        let encoder = try ImageEncoder(gpu: gpu)
        let picture = try encoder.picture(rendered.image.texture, colorSpace: gpu.workingColorSpace, format: .jpeg(quality: 1))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        // The picture is the texture turned the right way up (Core Image's origin is at the bottom).
        let srgb = centres.map { c in (0..<3).map { Double(bytes[((height - 1 - Int(c.1)) * width + Int(c.0)) * 4 + $0]) } }
        try Self.write(["print": print, "srgb8": srgb])
    }
}
