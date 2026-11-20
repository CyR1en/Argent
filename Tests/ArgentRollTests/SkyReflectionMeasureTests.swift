import ArgentCore
import CoreAI
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentRoll

/// Phase 2's reflection gate (masking-plan section 8), measured on the shipped route: each fixed 2560-pixel neutral print in
/// `ARGENT_SKY_REFLECTION_PRINTS` (a folder, P0-S4's `testset/neutral` or P0-S5's held-out prints, private, outside Git) goes
/// through what a Sky click does after its input picture, as the canary takes it: DA3 on its square as `SkyModelRunner` pads it
/// (task H's mirrored patch), the seed, Vision's water score and the gate, and EoMT and the water veto when the gate lets it run.
/// For each frame it writes the seed before and after the veto as 8-bit PNGs (`<name>.before.png`, `<name>.after.png`, the
/// stored seed's quantisation) and a line of `frames.jsonl` (the gate's score, whether EoMT ran, whether the veto fired, what it
/// removed); P0-S4's polygons score them outside (task I's `score_reflections.py`). `ARGENT_SKY_REFLECTION_NAMES` names a file of
/// names to read, one a line; without it every `.jpg` in the folder. Needs `build/models`; leaves no compiled copy behind.
///
///     ARGENT_MEASURE=1 ARGENT_SKY_REFLECTION_PRINTS=<folder> ARGENT_SKY_REFLECTION_OUT=<folder> \
///       swift test -c release -Xswiftc -enable-testing --filter SkyReflectionMeasureTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"
                                && ProcessInfo.processInfo.environment["ARGENT_SKY_REFLECTION_PRINTS"] != nil
                                && BundledMaskModel.allCases.allSatisfy {
                                    FileManager.default.fileExists(atPath: MaskCanary.models.appendingPathComponent("\($0.fileName)/main.hash").path)
                                }))
struct SkyReflectionMeasureTests {
    @Test func theSkyRouteOnFixedPrints() async throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(environment["ARGENT_SKY_REFLECTION_PRINTS"]), isDirectory: true)
        let out = URL(fileURLWithPath: environment["ARGENT_SKY_REFLECTION_OUT"] ?? NSTemporaryDirectory() + "argent-sky-reflection",
                      isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let names: [String]
        if let list = environment["ARGENT_SKY_REFLECTION_NAMES"] {
            names = try String(contentsOfFile: list, encoding: .utf8).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".jpg") }
                .map { String($0.dropLast(4)) }.sorted()
        }

        let support = FileManager.default.temporaryDirectory.appendingPathComponent("argent-sky-reflection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let models = MaskModels(directory: MaskCanary.models, ledgerFile: support.appendingPathComponent("ledger.json"))
        #expect(models.isSkyAvailable, "\(models.unavailable)")
        defer { for model in BundledMaskModel.allCases { try? AIModelCache.default.deleteEntries(for: try models.url(of: model)) } }
        try await models.skyRunner.load(from: try models.url(of: .sky))
        let da3 = ModelProvenance(try models.identity(of: .sky)), eomt = ModelProvenance(try models.identity(of: .water))

        var lines: [String] = [], missing: [String] = [], belowGateRuns = 0
        for name in names {
            guard let url = ["jpg", "png"].map({ folder.appendingPathComponent("\(name).\($0)") })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let file = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(file, 0, nil) else {
                missing.append(name)
                continue
            }
            let start = Date()
            // The canary's fixed-print route: the picture's RGB, each square's content area-resized on the CPU, padded as each
            // runner pads it.
            let vision = try AppleSegmentation.Picture(image)
            let bytes = vision.bytes, w = vision.width, h = vision.height
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) { rgb[i * 3] = bytes[i * 4]; rgb[i * 3 + 1] = bytes[i * 4 + 1]; rgb[i * 3 + 2] = bytes[i * 4 + 2] }
            func square(_ side: Int) -> ModelSquare {
                let layout = ModelSquareLayout(side: side, width: w, height: h)
                return ModelSquare(contentRGB8: ModelSquare.areaResize(rgb, width: w, height: h, toWidth: layout.contentWidth, height: layout.contentHeight),
                                   layout: layout, padding: side == SkyModelRunner.side ? SkyModelRunner.padding : EomtModelRunner.padding)
            }
            let sky = try await models.skyRunner.run(square(SkyModelRunner.side))
            let seed = try SkySeed(skyHead: ModelSquare.crop(sky.sky, planeSide: SkyModelRunner.side, layout: sky.layout),
                                   width: sky.layout.contentWidth, height: sky.layout.contentHeight, model: da3, square: sky.squareRecipe)
            let gate = try AppleSegmentation.waterScore(vision)
            var waterCalled = false
            let (vetoed, decision) = try await WaterVeto.apply(to: seed, gate: gate) {
                waterCalled = true
                try await models.waterRunner.load(from: try models.url(of: .water))
                let maps = try await models.waterRunner.run(square(EomtModelRunner.side))
                await models.waterRunner.unload()
                return try WaterMap(side: EomtModelRunner.mapSide, values: maps.water, square: EomtModelRunner.side,
                                    contentWidth: maps.layout.contentWidth, contentHeight: maps.layout.contentHeight,
                                    originX: maps.layout.originX, originY: maps.layout.originY, model: eomt, mapsSHA256: maps.digest)
            }
            if !gate.passes && waterCalled { belowGateRuns += 1 }
            let before = WaterVeto.quantize(seed.values, width: seed.width, height: seed.height)
            let after = WaterVeto.quantize(vetoed.values, width: vetoed.width, height: vetoed.height)
            try SkySeedEdgeTests.writePNG(before, to: out.appendingPathComponent("\(name).before.png"))
            if decision.fired { try SkySeedEdgeTests.writePNG(after, to: out.appendingPathComponent("\(name).after.png")) }
            let selected = { (r: MaskRaster) in Double(r.plane.filter { $0 >= 128 }.count) / Double(r.plane.count) }
            let line: [String: Any] = [
                "name": name, "width": w, "height": h, "seedWidth": seed.width, "seedHeight": seed.height,
                "square": sky.squareRecipe, "gate": Double(gate.score), "passes": gate.passes, "waterCalled": waterCalled,
                "ran": decision.ran, "fired": decision.fired, "candidateShare": decision.candidateShare,
                "removedSelectedShare": decision.removedSelectedShare, "removedSoftShare": decision.removedSoftShare,
                "removedPixels": decision.removedPixels, "selectedBefore": selected(before), "selectedAfter": selected(after),
                "seed": after.identity.hex, "seconds": Date().timeIntervalSince(start),
            ]
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))
            if lines.count % 25 == 0 { print("REFLECTION \(lines.count) of \(names.count)") }
        }
        await models.unloadAll()
        try (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("frames.jsonl"), atomically: true, encoding: .utf8)
        print("REFLECTION ran \(lines.count) of \(names.count); not present: \(missing.count) \(missing.prefix(10)); "
              + "EoMT called below the gate: \(belowGateRuns)")
        #expect(belowGateRuns == 0, "the veto's model ran on a frame below the gate")
        #expect(!lines.isEmpty)
    }

    /// The refined coverage a stored seed gives on its raw's full-size decode, as the develop refines it (task I's review sheets show
    /// it beside the prints): `ARGENT_SKY_COVERAGE` names a JSON list of `{"stem", "raw", "seed"}` (the seed an 8-bit PNG as the
    /// library keeps it; `"kind"` Sky unless it says "subject"), each written as `<stem>.coverage.png` (8-bit, top row first) into
    /// `ARGENT_SKY_REFLECTION_OUT`, with the coverage at 0, 20, … 180 px from each edge over the lines that are sky 400 px in. With
    /// `ARGENT_SKY_COVERAGE_PRINT` set, also `<stem>.print.png`: the same decode through the film, no mask, as a full-size sRGB print.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_SKY_COVERAGE"] != nil))
    func theRefinedCoverageOfStoredSeeds() throws {
        struct Item: Codable { var stem: String; var raw: String; var seed: String; var kind: String? }
        let environment = ProcessInfo.processInfo.environment
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: try #require(environment["ARGENT_SKY_COVERAGE"]))))
        let out = URL(fileURLWithPath: environment["ARGENT_SKY_REFLECTION_OUT"] ?? NSTemporaryDirectory() + "argent-sky-coverage", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let c = try MaskRefinerSurfaceTests.context()
        var report: [String] = []
        for item in items {
            let url = URL(fileURLWithPath: item.raw)
            var options = DecodeOptions()
            options.tileSize = RollDeveloper.decodeTile
            options.learnedTileSize = RollDeveloper.learnedDecodeTile
            let frame = try c.decoder.decode(url, options: options)
            let kind = item.kind ?? "sky"
            let entry = MaskRefinerSurfaceTests.Entry(stem: item.stem, raw: item.raw, kind: kind, seed: item.seed, format: "png")
            let raster = try MaskRefinerSurfaceTests.seed(entry, frameWidth: frame.width, frameHeight: frame.height)
            c.seeds.add(raster)
            let base = try MaskRefinerSurfaceTests.settings(c, url, grain: false)
            let component = try MaskRefinerSurfaceTests.component(kind, raster, background: false, width: frame.width, height: frame.height)
            let settings = try MaskRefinerSurfaceTests.masked(base, component, exposure: -1.5)
            let values = try #require(try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, frame, settings, coverage: true).coverage)
            let (w, h) = (frame.width, frame.height)
            if environment["ARGENT_SKY_COVERAGE_PRINT"] != nil {
                let unmasked = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, frame, base, coverage: false).image
                try MaskRefinerSurfaceTests.crop(c.gpu, unmasked.texture, x: 0, y: 0, width: w, height: h,
                                                 to: out.appendingPathComponent("\(item.stem).print.png"))
            }
            // The buffer is the bottom row first.
            var plane = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { plane[y * w + x] = UInt8((min(max(values[(h - 1 - y) * w + x], 0), 1) * 255).rounded()) } }
            try Self.writeGray(plane, width: w, height: h, to: out.appendingPathComponent("\(item.stem).coverage.png"))
            var line = "\(item.stem) \(w) × \(h), seed \(raster.width) × \(raster.height), coverage mean \(String(format: "%.4f", values.reduce(0, +) / Float(values.count)))"
            for side in ["top", "left", "right"] {
                func at(_ i: Int, _ d: Int) -> Float {
                    let (x, y): (Int, Int) = side == "top" ? (i, d) : side == "left" ? (d, i) : (w - 1 - d, i)
                    return Float(plane[y * w + x]) / 255
                }
                let count = side == "top" ? w : h
                let lines = (0..<count).filter { at($0, 400) > 0.98 }
                guard !lines.isEmpty else { line += " | \(side): no sky line"; continue }
                let means = stride(from: 0, to: 200, by: 20).map { d in lines.reduce(0) { $0 + at($1, d) } / Float(lines.count) }
                line += " | \(side) (\(lines.count) lines) " + means.map { String(format: "%.3f", $0) }.joined(separator: " ")
            }
            report.append(line)
            print("COVERAGE \(line)")
        }
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("coverage.txt"), atomically: true, encoding: .utf8)
    }

    /// An 8-bit gray PNG of any size (a raster's sides are bounded; a full-size coverage is not a raster).
    static func writeGray(_ plane: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let provider = CGDataProvider(data: Data(plane) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
