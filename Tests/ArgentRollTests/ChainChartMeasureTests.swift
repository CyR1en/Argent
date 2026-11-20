import Foundation
import Metal
import Testing
@testable import ArgentCore

/// A chart written into a copy of the CC0 a7 IV sample (`SyntheticRaw`) through both decoders and
/// the film, for comparing with the bake's Python model (docs/M3-auto.md section 19). Runs only
/// with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 ARGENT_PATCHES=in.json ARGENT_STOCK=build/stocks/kodak-portra-400 ARGENT_OUT=out.json \
///         swift test --skip-build --filter ChainChartMeasureTests
///
/// The patches (`{"rgb": [[r, g, b], ...]}`) are linear Rec. 2020 as a decode at exposure gain 0
/// should give them, times ARGENT_SCALE (default 0.5, so the brightest stay under the clip). Each
/// becomes camera RGB through the inverse of the in-house decoder's colour (`InHouseColor`): white-
/// balanced camera RGB is the inverse matrix times the colour, and the raw is that over the D55
/// gains. The in-house decoder must give the colours back by construction; Apple's gives them back
/// as far as the in-house colour fit matches it. Lens correction is off so the patches stay put.
@Suite(.serialized, .syntheticRaws, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"))
struct ChainChartMeasureTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func inverse(_ m: [[Double]]) -> [[Double]] {
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
                [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
                [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
    }

    private static func means(_ texture: MTLTexture, at centres: [(Int, Int)], half: Int) -> [[Double]] {
        centres.map { centre in
            let side = 2 * half
            var halves = [Float16](repeating: 0, count: side * side * 4)
            halves.withUnsafeMutableBytes { buffer in
                texture.getBytes(buffer.baseAddress!, bytesPerRow: side * 8,
                                 from: MTLRegionMake2D(centre.0 - half, centre.1 - half, side, side), mipmapLevel: 0)
            }
            var sum = [0.0, 0.0, 0.0]
            for i in 0..<(side * side) { for c in 0..<3 { sum[c] += Double(halves[i * 4 + c]) } }
            return sum.map { $0 / Double(side * side) }
        }
    }

    @Test func chart() throws {
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try #require(Self.environment["ARGENT_PATCHES"])))) as! [String: Any]
        let scale = Double(Self.environment["ARGENT_SCALE"] ?? "") ?? 0.5
        let colours = (input["rgb"] as! [[Double]]).map { $0.map { $0 * scale } }
        let toCamera = Self.inverse(InHouseColor.cameraToWorking), gains = InHouseColor.daylightGains
        let raws: [SIMD3<Double>] = colours.map { v in
            let wb = toCamera.map { $0[0] * v[0] + $0[1] * v[1] + $0[2] * v[2] }
            return SIMD3(wb[0] / gains[0], wb[1] / gains[1], wb[2] / gains[2])
        }
        let side = 400
        var placed: [(x: Int, y: Int)] = []
        let url = try SyntheticRaw.write("chain-chart.ARW", iso: 250) { samples, l in
            let range = Double(l.white - l.black), black = Double(l.black), columns = l.cropWidth / side
            func colour(_ x: Int, _ y: Int) -> Int { l.cfa[(y & 1) * 2 + (x & 1)] }
            var ground = [Double](repeating: 0, count: l.width * l.height)
            for y in 0..<l.height { for x in 0..<l.width { ground[y * l.width + x] = SyntheticRaw.neutral[colour(x, y)] * 0.1 } }
            for (i, rgb) in raws.enumerated() {
                let x0 = l.cropX + (i % columns) * side, y0 = l.cropY + (i / columns) * side
                placed.append((x0 - l.cropX + side / 2, y0 - l.cropY + side / 2))
                for y in y0..<(y0 + side) { for x in x0..<(x0 + side) { ground[y * l.width + x] = rgb[colour(x, y)] } }
            }
            for i in samples.indices { samples[i] = UInt16(min(max((ground[i] * range + black).rounded(), 0), Double(l.white))) }
        }
        let gpu = try GPU()
        let stock = try Stock.load(from: URL(fileURLWithPath: try #require(Self.environment["ARGENT_STOCK"])))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        var options = DecodeOptions()
        options.lensCorrection = false
        var out: [String: Any] = ["written": colours, "rawMax": raws.map { $0.max() }.max()!]
        let decoders: [(String, () throws -> LinearFrame)] = [
            ("apple", { try AppleRawDecoder(gpu: gpu).decode(url, options: options) }),
            ("inhouse", { try InHouseDecoderMeasureTests.inHouse(url, decoder: try InHouseDecoder(gpu: gpu), gpu: gpu, options: options) }),
        ]
        for (name, decode) in decoders {
            let frame = try decode()
            // Both decoders leave the picture's top row as the texture's last, as Core Image does.
            let centres = placed.map { ($0.x, frame.height - 1 - $0.y) }
            out[name] = ["linear": Self.means(frame.texture, at: centres, half: 80),
                         "print": Self.means(try renderer.render(frame, settings: DevelopSettings()).image.texture, at: centres, half: 80),
                         "gainStops": frame.pins?.exposureGainStops ?? .nan, "width": frame.width, "height": frame.height]
        }
        let target = URL(fileURLWithPath: Self.environment["ARGENT_OUT"] ?? "chain-chart.json")
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: target)
    }
}
