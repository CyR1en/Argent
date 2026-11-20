import CoreAI
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ArgentCore
@testable import ArgentRoll

/// The Sky seed's edges by the square DA3 is given (task H). With the picture's edge repeated out to the square's edge, DA3 left a
/// portrait's outer columns at 190 to 245 of 255 over open sky, and a few landscapes' top rows, which refinement carried about 140 px
/// in: a pale strip at fit (task D). For each raw in `ARGENT_SKY_EDGE_RAWS` (paths, comma separated; private frames are read where
/// they lie): the input picture from the full-size decode, DA3 on the square padded each way (`ModelSquare.Padding`), and for each
/// seed its values next to each edge and the refined coverage by distance from it, over the lines that are sky at the edge and
/// 400 px in. Beside them, D's control: the edge-padded seed with its outer four lines set to the fifth's. And how far the two
/// seeds differ away from the edges. Writes `<out>/sky-edges.txt` and each seed as a PNG. Needs `build/models`; leaves no compiled
/// copy behind.
///
///     ARGENT_SKY_EDGE_RAWS=<a.ARW,b.ARW> ARGENT_REFINER_OUT=<folder> swift test --filter SkySeedEdgeTests
@Suite(.serialized, .rawDecodes, .enabled(if: (ProcessInfo.processInfo.environment["ARGENT_SKY_EDGE_RAWS"] != nil
                                            || ProcessInfo.processInfo.environment["ARGENT_SKY_EDGE_PRINTS"] != nil)
                                           && FileManager.default.fileExists(atPath: MaskCanary.models
                                               .appendingPathComponent("\(BundledMaskModel.sky.fileName)/main.hash").path)))
struct SkySeedEdgeTests {
    /// One side's numbers: the seed's mean over the chosen lines at each of its first six positions from the edge (0 to 255), and
    /// the refined coverage's at 0, 20, … 180 px.
    struct Side {
        var name: String
        var lines: Int
        var seed: [Float]
        var coverage: [Float]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_SKY_EDGE_RAWS"] != nil))
    func theSeedsEdgesByPadding() async throws {
        let environment = ProcessInfo.processInfo.environment
        let raws = try #require(environment["ARGENT_SKY_EDGE_RAWS"]).split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let out = MaskRefinerSurfaceTests.out
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("argent-sky-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: MaskCanary.models, ledgerFile: support.appendingPathComponent("ledger.json"))
        defer { try? AIModelCache.default.deleteEntries(for: try models.url(of: .sky)) }
        try await models.skyRunner.load(from: try models.url(of: .sky))
        defer { Task { await models.skyRunner.unload() } }

        let c = try MaskRefinerSurfaceTests.context()
        var report: [String] = []
        for url in raws {
            let stem = url.deletingPathExtension().lastPathComponent
            var options = DecodeOptions()
            options.tileSize = RollDeveloper.decodeTile
            options.learnedTileSize = RollDeveloper.learnedDecodeTile
            let frame = try c.decoder.decode(url, options: options)
            let picture = try MaskInputPictureMaker(gpu: c.gpu).make(from: frame)
            let base = try MaskRefinerSurfaceTests.settings(c, url, grain: false)

            var seeds: [(String, MaskRaster)] = []
            for padding in Self.paddings {
                let outputs = try await models.skyRunner.run(ModelSquare(picture, side: SkyModelRunner.side, padding: padding))
                let seed = outputs.seed
                let name = padding.mirrored == 0 ? "edge" : padding.mirrored == .max ? "mirror" : "mirror\(padding.mirrored)"
                seeds.append((name, WaterVeto.quantize(seed.values, width: seed.width, height: seed.height)))
            }
            // D's control: the edge-padded seed with its outer four lines on every side set to the fifth's.
            let edge = seeds[0].1, (sw, sh) = (edge.width, edge.height)
            var plane = edge.plane
            for y in 0..<sh {
                for x in 0..<4 { plane[y * sw + x] = plane[y * sw + 4]; plane[y * sw + sw - 1 - x] = plane[y * sw + sw - 5] }
            }
            for x in 0..<sw {
                for y in 0..<4 { plane[y * sw + x] = plane[4 * sw + x]; plane[(sh - 1 - y) * sw + x] = plane[(sh - 5) * sw + x] }
            }
            seeds.append(("repaired", try MaskRaster(width: sw, height: sh, plane: plane)))

            var coverages: [[Float]] = []
            for (name, raster) in seeds {
                c.seeds.add(raster)
                try Self.writePNG(raster, to: out.appendingPathComponent("\(stem)-\(name).png"))
                let component = try MaskRefinerSurfaceTests.component("sky", raster, background: false, width: frame.width, height: frame.height)
                let settings = try MaskRefinerSurfaceTests.masked(base, component, exposure: -1.5)
                coverages.append(try #require(try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, frame, settings, coverage: true).coverage))
            }
            let (w, h) = (frame.width, frame.height)
            report.append("\(stem) \(w) × \(h), seed \(sw) × \(sh), padding \(frame.width >= frame.height ? "top and bottom" : "left and right")")
            for side in ["left", "right", "top", "bottom"] {
                // The lines, by the repaired seed's coverage: sky at the edge and 400 px in.
                let horizontal = side == "left" || side == "right"
                let count = horizontal ? h : w
                // Coverage at distance d from this side on line i, the picture's top row first (the buffer is bottom row first).
                func at(_ values: [Float], _ i: Int, _ d: Int) -> Float {
                    let (x, y): (Int, Int) = switch side {
                    case "left": (d, i)
                    case "right": (w - 1 - d, i)
                    case "top": (i, d)
                    default: (i, h - 1 - d)
                    }
                    return values[(h - 1 - y) * w + x]
                }
                let repaired = coverages[coverages.count - 1]
                let lines = (0..<count).filter { at(repaired, $0, 0) > 0.98 && at(repaired, $0, 400) > 0.98 }
                guard !lines.isEmpty else {
                    report.append("  \(side): no sky line")
                    continue
                }
                // The seed's lines under them.
                let seedCount = horizontal ? sh : sw, seedSide = horizontal ? sw : sh
                let seedLines = Set(lines.map { $0 * seedCount / count })
                func seedAt(_ raster: MaskRaster, _ i: Int, _ d: Int) -> Float {
                    let (x, y): (Int, Int) = switch side {
                    case "left": (d, i)
                    case "right": (sw - 1 - d, i)
                    case "top": (i, d)
                    default: (i, sh - 1 - d)
                    }
                    return Float(raster.plane[y * sw + x])
                }
                _ = seedSide
                var row = "  \(side), \(lines.count) sky lines (\(seedLines.count) of the seed's):"
                for (index, (name, raster)) in seeds.enumerated() {
                    let seedMeans = (0..<6).map { d in seedLines.reduce(0) { $0 + seedAt(raster, $1, d) } / Float(seedLines.count) }
                    let coverage = stride(from: 0, to: 200, by: 20).map { d in lines.reduce(0) { $0 + at(coverages[index], $1, d) } / Float(lines.count) }
                    let worst = lines.map { at(coverages[index], $0, 0) }.min() ?? 0
                    row += "\n    \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) seed "
                        + seedMeans.map { String(format: "%.0f", $0) }.joined(separator: " ")
                        + " | coverage " + coverage.map { String(format: "%.3f", $0) }.joined(separator: " ")
                        + String(format: " | edge min %.3f", worst)
                }
                report.append(row)
            }
            // Away from the edges, how far each other padding's seed is from the edge-padded one: past 16 seed pixels from every side;
            // and the refined coverage over the whole frame.
            for index in 1..<(seeds.count - 1) {
                let other = seeds[index].1
                var differences: [Float] = [], flips = 0
                for y in 16..<(sh - 16) {
                    for x in 16..<(sw - 16) {
                        let a = edge.plane[y * sw + x], b = other.plane[y * sw + x]
                        differences.append(abs(Float(a) - Float(b)))
                        if (a >= 128) != (b >= 128) { flips += 1 }
                    }
                }
                differences.sort()
                let interior = Float(differences.count)
                var whole: Float = 0, wholeMax: Float = 0
                for i in 0..<(w * h) { let d = abs(coverages[index][i] - coverages[0][i]); whole += d; wholeMax = max(wholeMax, d) }
                report.append(String(format: "  %@ against edge: seed 16 px in mean |Δ| %.2f, p99 %.0f, max %.0f of 255, %d of %.0f cross 128 (%.2f %%); refined coverage mean |Δ| %.4f, max %.3f",
                                     seeds[index].0, differences.reduce(0, +) / interior, differences[Int(interior * 0.99)], differences.last ?? 0,
                                     flips, interior, Float(flips) / interior * 100, whole / Float(w * h), wholeMax))
            }
            print(report.suffix(8).joined(separator: "\n"))
        }
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("sky-edges.txt"), atomically: true, encoding: .utf8)
    }

    /// The same seeds on fixed prints (`ARGENT_SKY_EDGE_PRINTS`, a folder of 2560-pixel neutral prints, P0-S4's `testset/neutral`;
    /// `ARGENT_SKY_EDGE_NAMES` the names to read), their squares made on the CPU as the canary makes them: each padding's seed share
    /// at or above 128, by sixth of the frame from the top, and against the edge-padded seed. Writes `<out>/sky-prints.txt`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_SKY_EDGE_PRINTS"] != nil))
    func theSeedsOnFixedPrintsByPadding() async throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(environment["ARGENT_SKY_EDGE_PRINTS"]), isDirectory: true)
        let names = try #require(environment["ARGENT_SKY_EDGE_NAMES"]).split(separator: ",").map(String.init)
        let out = MaskRefinerSurfaceTests.out
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("argent-sky-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: MaskCanary.models, ledgerFile: support.appendingPathComponent("ledger.json"))
        defer { try? AIModelCache.default.deleteEntries(for: try models.url(of: .sky)) }
        try await models.skyRunner.load(from: try models.url(of: .sky))
        var report: [String] = []
        for name in names {
            guard let url = ["jpg", "png"].map({ folder.appendingPathComponent("\(name).\($0)") }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let file = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(file, 0, nil) else {
                report.append("\(name): not present")
                continue
            }
            let vision = try AppleSegmentation.Picture(image)
            let bytes = vision.bytes, w = vision.width, h = vision.height
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) { rgb[i * 3] = bytes[i * 4]; rgb[i * 3 + 1] = bytes[i * 4 + 1]; rgb[i * 3 + 2] = bytes[i * 4 + 2] }
            let layout = ModelSquareLayout(side: SkyModelRunner.side, width: w, height: h)
            let content = ModelSquare.areaResize(rgb, width: w, height: h, toWidth: layout.contentWidth, height: layout.contentHeight)
            var seeds: [(String, MaskRaster)] = []
            for padding in Self.paddings {
                let outputs = try await models.skyRunner.run(ModelSquare(contentRGB8: content, layout: layout, padding: padding))
                let seed = outputs.seed
                seeds.append(("\(padding)", WaterVeto.quantize(seed.values, width: seed.width, height: seed.height)))
            }
            report.append("\(name) \(w) × \(h), seed \(layout.contentWidth) × \(layout.contentHeight)")
            let (sw, sh) = (layout.contentWidth, layout.contentHeight)
            for (padding, raster) in seeds {
                let bands = (0..<6).map { band -> String in
                    let rows = (band * sh / 6)..<((band + 1) * sh / 6)
                    var set = 0
                    for y in rows { for x in 0..<sw where raster.plane[y * sw + x] >= 128 { set += 1 } }
                    return String(format: "%5.1f", Double(set) / Double(rows.count * sw) * 100)
                }
                let all = raster.plane.filter { $0 >= 128 }.count
                let crossed = zip(raster.plane, seeds[0].1.plane).filter { ($0 >= 128) != ($1 >= 128) }.count
                report.append(String(format: "  %@ sky %5.2f %% | by sixth %@ | cross 128 against edge %.2f %%", padding.padding(toLength: 22, withPad: " ", startingAt: 0),
                                     Double(all) / Double(sw * sh) * 100, bands.joined(separator: " "), Double(crossed) / Double(sw * sh) * 100))
            }
            print(report.suffix(seeds.count + 1).joined(separator: "\n"))
        }
        await models.skyRunner.unload()
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("sky-prints.txt"), atomically: true, encoding: .utf8)
    }

    /// The paddings compared: `ARGENT_SKY_EDGE_MIRRORED` (lines mirrored, comma separated; 0 the edge, -1 all) or edge, all and three bands.
    static var paddings: [ModelSquare.Padding] {
        let lines = ProcessInfo.processInfo.environment["ARGENT_SKY_EDGE_MIRRORED"].map { $0.split(separator: ",").compactMap { Int($0) } }
            ?? [0, -1, 14, 28, 56]
        return lines.map { ModelSquare.Padding(mirrored: $0 < 0 ? .max : $0) }
    }

    static func writePNG(_ raster: MaskRaster, to url: URL) throws {
        let data = Data(raster.plane) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: raster.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
