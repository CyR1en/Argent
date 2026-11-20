import ArgentCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// What the Auto tone step is fitted from (docs/research/auto/balance-research.md, section 7c): each
/// frame through Portra 400 at box speed over a grid of print aims, burns and dodges, with the print's
/// tone distribution on 240-pixel cells and its mean L* in bands of the decode's scene stops. A fit then
/// needs no raw. Observational, and it runs only with ARGENT_MEASURE=1 and ARGENT_TONESWEEP_OUT:
///
///     ARGENT_MEASURE=1 ARGENT_TONESWEEP_OUT=<folder> ARGENT_TONESWEEP_LISTS=a7:<raws.txt>,fivek:<dngs.txt> \
///       swift test -c release -Xswiftc -enable-testing --skip-build --filter AutoToneMeasureTests
///
/// ARGENT_TONESWEEP_EVERY takes every Nth frame, for a pilot. ARGENT_TONESWEEP_SHAPE overrides the curve
/// with nine comma-separated knots: burn rise, burn fall and keep, dodge rise and fall. Everything written is
/// derived data from raws whose terms may forbid redistribution: keep it outside Git.
@Suite(.serialized) struct AutoToneMeasureTests {
    typealias M = FrameViewMeasureTests
    typealias G = GateMeasureTests

    static let aims: [Float] = stride(from: -1.75, through: 1.25, by: 0.25).map { Float($0) }
    static let burns: [Float] = [0, 0.3, 0.6, 0.9, 1.2, 1.5]
    static let dodges: [Float] = [0, 0.15, 0.3, 0.45]
    /// The bands of the decode's scene stops the print is measured in.
    static let bandEdges: [Double] = stride(from: -5.0, through: 5.0, by: 1.0).map { $0 }

    struct Row: Codable {
        var set: String
        var name: String
        var iso: Int?
        var shutter: Double?
        var aperture: Double?
        var level: Float
        var levelPositive: Float
        var shadowSpread: Float
        var highlightSpread: Float
        var bright: Float
        var dark: Float
        var faceWeight: Float
        var faceOffset: Float
        var faceFrameLevel: Float
        var shippedAim: Float
        var bandShare: [Double]
        var histogram: [Float]
        var aims: [Float]
        var burns: [Float]
        var dodges: [Float]
        /// By aim, burn and dodge: mean, p10, p25, p50, p75, p90, the share at L* 97 or more, the largest
        /// face's L* (-1 without one), then each band's mean L* (-1 for a band with too few cells).
        var values: [[Double]]
    }

    /// A 240-pixel box-filtered half-float RGB copy, its width and height first, as `PlacementFitMeasureTests` keeps
    /// the experts' renditions, rows from the bottom.
    static func derivative(_ pixels: [Float16], width: Int, height: Int) -> [Float16] {
        let step = max(1, max(width, height) / 240)
        let w = width / step, h = height / step
        var out = [Float16](repeating: 0, count: w * h * 3 + 2)
        out[0] = Float16(Float(w)); out[1] = Float16(Float(h))
        for y in 0..<h {
            for x in 0..<w {
                var s = SIMD3<Float>(repeating: 0)
                for yy in 0..<step { for xx in 0..<step {
                    let i = ((y * step + yy) * width + x * step + xx) * 4
                    s += SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                } }
                s /= Float(step * step)
                let o = 2 + (y * w + x) * 3
                out[o] = Float16(s.x); out[o + 1] = Float16(s.y); out[o + 2] = Float16(s.z)
            }
        }
        return out
    }

    static func shape(_ environment: [String: String]) -> PrintTone.Shape? {
        guard let text = environment["ARGENT_TONESWEEP_SHAPE"] else { return nil }
        let k = text.split(separator: ",").compactMap { Float($0) }
        guard k.count == 9 else { return nil }
        return PrintTone.Shape(burnRise: k[0]...k[1], burnFall: k[2]...k[3], burnKeep: k[4], burnColour: PrintTone.Shape.v2026_11_05_2.burnColour, dodgeRise: k[5]...k[6], dodgeFall: k[7]...k[8],
                               support: PrintTone.Shape.v2026_11_05_2.support)
    }

    /// The frozen rule, rendered: each frame at the shipped path's own aim and tone through Portra 400 at box speed
    /// and at the roll's two under, for scoring against the sweep's interpolation and the references. FiveK's frames
    /// take ARGENT_TONEFROZEN_FIVEK_OFFSET, their own intercept. Writes the same statistics, and a tile per frame.
    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_TONEFROZEN_OUT"] != nil))
    func frozen() throws {
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(environment["ARGENT_TONEFROZEN_OUT"]))
        try #require(!out.resolvingSymlinksInPath().path.hasPrefix(M.root.path + "/"), "keep derived data outside the repository")
        try FileManager.default.createDirectory(at: out.appendingPathComponent("cells"), withIntermediateDirectories: true)
        let offset = environment["ARGENT_TONEFROZEN_FIVEK_OFFSET"].flatMap(Float.init) ?? 0
        var entries: [(set: String, url: URL)] = []
        for part in try #require(environment["ARGENT_TONESWEEP_LISTS"]).split(separator: ",") {
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            entries += try String(contentsOfFile: pieces[1], encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { (pieces[0], URL(fileURLWithPath: $0)) }
        }
        let rowsURL = out.appendingPathComponent("rows.jsonl")
        FileManager.default.createFile(atPath: rowsURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: rowsURL)
        defer { try? handle.close() }
        struct Frozen: Codable { var set: String; var name: String; var aim: Float; var burn: Float; var dodge: Float; var box: [Double]; var twoUnder: [Double]; var millisecondsField: Double }
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let raw9 = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9), contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        let apple = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for entry in entries {
            try autoreleasepool {
                let header = try? ARWFrameInfo.read(from: entry.url)
                let frame = entry.set == "fivek" ? try apple.decode(entry.url, options: options) : try raw9.decode(entry.url, options: options)
                let analysis = ExposureAnalyzer.analyze(frame, workingSpace: gpu.workingColorSpace, info: header)
                var aim = AutoPrint.aim(analysis)
                if entry.set == "fivek" { aim.level = min(max(aim.level + offset, -AutoPrint.bound), AutoPrint.bound) }
                func stats(_ controls: RollControls) throws -> ([Double], [Float16]) {
                    let settings = try DevelopmentResolver.resolve(stock: stock, stockDigest: stock.digest, controls: controls, aim: aim, manual: nil, grain: 0, grainSeed: 0, sharpen: true)
                    let cells = Self.derivative(ExposureAnalyzer.pixels(of: try renderer.render(frame, settings: settings).image.texture), width: frame.width, height: frame.height)
                    var l: [Double] = []
                    l.reserveCapacity((cells.count - 2) / 3)
                    for c in 0..<((cells.count - 2) / 3) {
                        l.append(G.lightness(max(0.2627 * Double(cells[2 + c * 3]) + 0.6780 * Double(cells[3 + c * 3]) + 0.0593 * Double(cells[4 + c * 3]), 0)))
                    }
                    let white = Double(l.filter { $0 >= 97 }.count) / Double(l.count)
                    let mean = l.reduce(0, +) / Double(l.count)
                    l.sort()
                    func q(_ p: Double) -> Double { l[min(l.count - 1, Int(p * Double(l.count)))] }
                    return ([mean, q(0.1), q(0.25), q(0.5), q(0.75), q(0.9), white], cells)
                }
                let name = entry.url.deletingPathExtension().lastPathComponent
                let (box, boxCells) = try stats(RollControls(ratedAt: .boxSpeed, labBalance: .auto))
                let (two, _) = try stats(RollControls(ratedAt: .twoStopsUnder, labBalance: .auto))
                try boxCells.withUnsafeBytes { try Data($0).write(to: out.appendingPathComponent("cells/\(name)-new.f16")) }
                let record = Frozen(set: entry.set, name: name, aim: aim.level, burn: aim.burn, dodge: aim.dodge, box: box, twoUnder: two, millisecondsField: 0)
                try handle.write(contentsOf: encoder.encode(record) + Data("\n".utf8))
            }
        }
        print("TONEFROZEN done \(entries.count)")
    }

    /// Trying curves on skies: each listed frame through each variant in ARGENT_SKY_VARIANTS, a JSON list of label, burn and
    /// dodge multipliers, an aim offset and nine knots, beside Lightroom's export, on one sheet, with each band's L* and spread.
    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_SKY_OUT"] != nil))
    func skyVariants() throws {
        struct Variant: Codable { var label: String; var burn: Float; var dodge: Float; var aim: Float; var knots: [Float]; var addBurn: Float?; var reach: [Float]?; var colour: Float? }
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(environment["ARGENT_SKY_OUT"]))
        try #require(!out.resolvingSymlinksInPath().path.hasPrefix(M.root.path + "/"), "keep derived data outside the repository")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let variants = try JSONDecoder().decode([Variant].self, from: Data(contentsOf: URL(fileURLWithPath: try #require(environment["ARGENT_SKY_VARIANTS"]))))
        let list = try String(contentsOfFile: try #require(environment["ARGENT_SKY_FRAMES"]), encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let exports = URL(fileURLWithPath: try #require(environment["ARGENT_LR_EXPORTS"]))
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9), contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        typealias D = RollDiagnosticsMeasureTests
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        let tileW = 480, tileH = 320, gap = 8, margin = 16, labelH = 24, header = 44, columns = variants.count + 1
        let width = margin * 2 + columns * tileW + (columns - 1) * gap, height = header + list.count * (tileH + labelH + gap) + margin
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.13, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (c, v) in variants.enumerated() { D.draw(v.label, at: CGPoint(x: margin + c * (tileW + gap), y: height - 28), in: context, color: CGColor(gray: 0.95, alpha: 1)) }
        D.draw("Lightroom Auto", at: CGPoint(x: margin + variants.count * (tileW + gap), y: height - 28), in: context, color: CGColor(gray: 0.95, alpha: 1))
        func place(_ image: CGImage?, _ c: Int, _ top: Int) {
            guard let image else { return }
            let scale = min(Double(tileW) / Double(image.width), Double(tileH) / Double(image.height))
            let iw = Double(image.width) * scale, ih = Double(image.height) * scale
            context.draw(image, in: CGRect(x: Double(margin + c * (tileW + gap)) + (Double(tileW) - iw) / 2, y: Double(height - top - tileH) + (Double(tileH) - ih) / 2, width: iw, height: ih))
        }
        var records: [[String: Any]] = []
        for (r, path) in list.enumerated() {
            try autoreleasepool {
                let url = URL(fileURLWithPath: path), stem = url.deletingPathExtension().lastPathComponent
                let frame = try decoder.decode(url, options: options)
                let analysis = ExposureAnalyzer.analyze(frame, workingSpace: gpu.workingColorSpace, info: try? ARWFrameInfo.read(from: url))
                let aim = AutoPrint.aim(analysis)
                let top = header + r * (tileH + labelH + gap)
                let decode = Self.derivative(ExposureAnalyzer.pixels(of: frame.texture), width: frame.width, height: frame.height)
                let controls = RollControls(ratedAt: .boxSpeed, labBalance: .auto)
                for (c, v) in variants.enumerated() {
                    let level = aim.level + v.aim
                    var settings = try DevelopmentResolver.resolve(stock: stock, stockDigest: stock.digest, controls: controls, aim: PrintAim(level: level, cast: aim.cast),
                                                                   manual: nil, grain: 0, grainSeed: 0, sharpen: true)
                    var burn = aim.burn * v.burn + (v.addBurn ?? 0)
                    if let reach = v.reach {
                        let bins = analysis.histogram
                        var below: Float = 0, q99: Float = 5
                        let total = bins.reduce(0, +)
                        for (index, share) in bins.enumerated() where share > 0 {
                            if below + share >= 0.99 * total { q99 = -5 + 0.5 * (Float(index) + (0.99 * total - below) / share); break }
                            below += share
                        }
                        burn = min(max(reach[0] + reach[1] * (q99 - 3), 0), reach[2])
                    }
                    var tone = PrintTone(burn: burn, dodge: aim.dodge * v.dodge, referenceStops: level)
                    let k = v.knots
                    tone.shapeOverride = PrintTone.Shape(burnRise: k[0]...k[1], burnFall: k[2]...k[3], burnKeep: k[4], burnColour: v.colour ?? PrintTone.Shape.v2026_11_05_2.burnColour, dodgeRise: k[5]...k[6], dodgeFall: k[7]...k[8],
                                                         support: PrintTone.Shape.v2026_11_05_2.support)
                    settings.tone = tone
                    let pixels = ExposureAnalyzer.pixels(of: try renderer.render(frame, settings: settings).image.texture)
                    place(D.tile(pixels, width: frame.width, height: frame.height, gpu: gpu, longSide: 480), c, top)
                    let cells = Self.derivative(pixels, width: frame.width, height: frame.height)
                    var sums = [[Double]](repeating: [0, 0, 0], count: 10)
                    for i in 0..<((cells.count - 2) / 3) {
                        let y = 0.2627 * Double(decode[2 + i * 3]) + 0.6780 * Double(decode[3 + i * 3]) + 0.0593 * Double(decode[4 + i * 3])
                        let s = log2(max(y, 1e-5) / 0.18)
                        guard let b = Self.bandEdges.indices.dropLast().first(where: { s >= Self.bandEdges[$0] && s < Self.bandEdges[$0 + 1] }) else { continue }
                        let l = G.lightness(max(0.2627 * Double(cells[2 + i * 3]) + 0.6780 * Double(cells[3 + i * 3]) + 0.0593 * Double(cells[4 + i * 3]), 0))
                        sums[b][0] += 1; sums[b][1] += l; sums[b][2] += l * l
                    }
                    records.append(["name": stem, "variant": v.label, "burn": Double(tone.burn), "dodge": Double(tone.dodge), "level": Double(level), "bands": sums])
                }
                if let source = CGImageSourceCreateWithURL(exports.appendingPathComponent("auto/\(stem).tif") as CFURL, nil),
                   let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 960,
                                                                                 kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { place(picture, variants.count, top) }
                D.draw(String(format: "%@   aim %+.2f, burn %.2f, dodge %.2f", stem, aim.level, aim.burn, aim.dodge), at: CGPoint(x: margin, y: height - top - tileH - 16), in: context, color: CGColor(gray: 0.72, alpha: 1))
            }
        }
        try JSONSerialization.data(withJSONObject: records).write(to: out.appendingPathComponent("bands.json"))
        try D.writePNG(try #require(context.makeImage()), to: out.appendingPathComponent("variants.png"))
    }

    /// What holding a gray's colour changes, on real frames: each frame at the frozen aim, with and without the hold, in bands
    /// of the decode's scene stops, as mean a*, b* and C* of the print. ARGENT_TONECOLOUR_OUT is the file.
    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_TONECOLOUR_OUT"] != nil))
    func colour() throws {
        let environment = ProcessInfo.processInfo.environment
        let outURL = URL(fileURLWithPath: try #require(environment["ARGENT_TONECOLOUR_OUT"]))
        try #require(!outURL.resolvingSymlinksInPath().path.hasPrefix(M.root.path + "/"), "keep derived data outside the repository")
        let list = try String(contentsOfFile: try #require(environment["ARGENT_TONESWEEP_LIST"]), encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9), contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        // Rec. 2020 to XYZ, D65.
        func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
            let x = 0.636958 * r + 0.144617 * g + 0.168881 * b, y = 0.262700 * r + 0.677998 * g + 0.059302 * b, z = 0.028073 * g + 1.060985 * b
            func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (841.0 / 108) * t + 4.0 / 29 }
            let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
            return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
        }
        var rows: [[String: Any]] = []
        for path in list {
            try autoreleasepool {
                let url = URL(fileURLWithPath: path)
                let frame = try decoder.decode(url, options: options)
                let w = frame.width, h = frame.height
                let analysis = ExposureAnalyzer.analyze(frame, workingSpace: gpu.workingColorSpace, info: try? ARWFrameInfo.read(from: url))
                let aim = AutoPrint.aim(analysis)
                let cast = aim.cast
                let decode = Self.derivative(ExposureAnalyzer.pixels(of: frame.texture), width: w, height: h)
                func measure(_ name: String, level: Float, tone: PrintTone) throws {
                    var settings = try DevelopmentResolver.resolve(stock: stock, stockDigest: stock.digest, controls: RollControls(ratedAt: .boxSpeed, labBalance: .auto),
                                                                   aim: PrintAim(level: level, cast: cast), manual: nil, grain: 0, grainSeed: 0, sharpen: true)
                    settings.tone = tone
                    let cells = Self.derivative(ExposureAnalyzer.pixels(of: try renderer.render(frame, settings: settings).image.texture), width: w, height: h)
                    var sums = [[Double]](repeating: [0, 0, 0, 0, 0], count: 10)
                    for c in 0..<((cells.count - 2) / 3) {
                        let y = 0.2627 * Double(decode[2 + c * 3]) + 0.6780 * Double(decode[3 + c * 3]) + 0.0593 * Double(decode[4 + c * 3])
                        let s = log2(max(y, 1e-5) / 0.18)
                        guard let b = Self.bandEdges.indices.dropLast().first(where: { s >= Self.bandEdges[$0] && s < Self.bandEdges[$0 + 1] }) else { continue }
                        let v = lab(max(Double(cells[2 + c * 3]), 0), max(Double(cells[3 + c * 3]), 0), max(Double(cells[4 + c * 3]), 0))
                        sums[b][0] += 1; sums[b][1] += v.0; sums[b][2] += v.1; sums[b][3] += v.2; sums[b][4] += (v.1 * v.1 + v.2 * v.2).squareRoot()
                    }
                    rows.append(["name": url.lastPathComponent, "variant": name, "bands": sums])
                }
                var uneven = aim.tone
                uneven.holdsColour = false
                try measure("none", level: aim.level, tone: .identity)
                try measure("plain", level: aim.level, tone: uneven)
                try measure("held", level: aim.level, tone: aim.tone)
            }
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: outURL)
    }

    /// What the tone step adds to a render, at the sheet's size and a develop's, on one raw: the whole render's wall time
    /// without it and with it, and the base field's own GPU time.
    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_TONECOST_RAW"] != nil))
    func cost() throws {
        let raw = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARGENT_TONECOST_RAW"]))
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9), contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        for side in [960, 2190, 0] {
            var options = DecodeOptions()
            if side > 0 { options.maxLongSide = side }
            let frame = try decoder.decode(raw, options: options)
            func settings(_ tone: PrintTone) throws -> DevelopSettings {
                var s = try DevelopmentResolver.resolve(stock: stock, stockDigest: stock.digest, controls: RollControls(), aim: PrintAim(level: 0.1), manual: nil,
                                                        grain: 1, grainSeed: 7, sharpen: true)
                s.tone = tone
                return s
            }
            func median(_ tone: PrintTone) throws -> Double {
                var times: [Double] = []
                for _ in 0..<9 {
                    let start = Date()
                    _ = try renderer.render(frame, settings: try settings(tone))
                    times.append(Date().timeIntervalSince(start) * 1000)
                }
                return times.sorted()[4]
            }
            _ = try median(.identity)
            let plain = try median(.identity)
            let toned = try median(PrintTone(burn: 0.3, dodge: 0.1, referenceStops: 0.1))
            // A frame's first toned render also builds its table.
            var builds: [Double] = []
            for i in 0..<21 {
                let start = Date()
                _ = try PrintTone(burn: 0.3 + Float(i) * 0.01, dodge: 0.1, referenceStops: 0.1).table(stock: stock, settings: try settings(.identity))
                builds.append(Date().timeIntervalSince(start) * 1000)
            }
            print(String(format: "TONECOST %dx%d: without %.1f ms, with %.1f ms, added %.1f ms; a table takes %.2f ms", frame.width, frame.height, plain, toned, toned - plain, builds.sorted()[10]))
        }
    }

    /// A sheet for the owner to judge by eye: frames of the roll as Auto printed them before the tone step, as it prints
    /// them now, at box speed and at the roll's two under, beside Lightroom's Auto and the camera's JPEG. The new aims are
    /// the roll's own, through `RollSmoothing`, as the app settles them; the old come from ARGENT_BEFORE, a frame's
    /// name to its aim. Grain is on, as the app's prints have it.
    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_BEFOREAFTER_OUT"] != nil))
    func beforeAfter() async throws {
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(environment["ARGENT_BEFOREAFTER_OUT"]))
        try #require(!out.resolvingSymlinksInPath().path.hasPrefix(M.root.path + "/"), "keep derived data outside the repository")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let before = try JSONDecoder().decode([String: [Double]].self, from: Data(contentsOf: URL(fileURLWithPath: try #require(environment["ARGENT_BEFORE"]))))
        let exports = URL(fileURLWithPath: try #require(environment["ARGENT_LR_EXPORTS"]))
        let chosen = try #require(environment["ARGENT_BEFOREAFTER_FRAMES"]).split(separator: ",").map(String.init)
        let folder = URL(fileURLWithPath: try #require(environment["ARGENT_BEFOREAFTER_ROLL"]))
        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9), contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let roll = await RollScanner.scan(folder)
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        var analyses: [URL: ExposureAnalysis] = [:]
        for frame in roll.frames {
            try autoreleasepool {
                analyses[frame.url] = ExposureAnalyzer.analyze(try decoder.decode(frame.url, options: options), workingSpace: gpu.workingColorSpace, info: frame.info)
            }
        }
        let aims = RollSmoothing.aims(roll.frames, analyses: analyses)
        try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: aims.map { ($0.key.lastPathComponent, [$0.value.level, $0.value.burn, $0.value.dodge].map(Double.init)) }), options: [.sortedKeys])
            .write(to: out.appendingPathComponent("aims.json"))
        let labels = ["Auto today, box speed", "New Auto, box speed", "New Auto, one under", "New Auto, two under", "Lightroom Auto", "Camera JPEG"]
        let tileW = 480, tileH = 320, gap = 8, margin = 20, labelH = 26, header = 52
        let frames = chosen.compactMap { name in roll.frames.first { $0.url.lastPathComponent == name } }
        let width = margin * 2 + labels.count * tileW + (labels.count - 1) * gap
        let height = header + frames.count * (tileH + labelH + gap) + margin
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.13, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        typealias D = RollDiagnosticsMeasureTests
        for (c, label) in labels.enumerated() {
            D.draw(label, at: CGPoint(x: margin + c * (tileW + gap), y: height - 34), in: context, color: CGColor(gray: 0.95, alpha: 1))
        }
        func place(_ image: CGImage?, _ c: Int, _ top: Int) {
            guard let image else { return }
            let scale = min(Double(tileW) / Double(image.width), Double(tileH) / Double(image.height))
            let iw = Double(image.width) * scale, ih = Double(image.height) * scale
            let x = Double(margin + c * (tileW + gap)), y = Double(height - top - tileH)
            context.draw(image, in: CGRect(x: x + (Double(tileW) - iw) / 2, y: y + (Double(tileH) - ih) / 2, width: iw, height: ih))
        }
        for (r, frame) in frames.enumerated() {
            try autoreleasepool {
                let top = header + r * (tileH + labelH + gap)
                let sheet = try decoder.decode(frame.url, options: options)
                let w = sheet.width, h = sheet.height
                let aim = try #require(aims[frame.url])
                let old = try #require(before[frame.url.deletingPathExtension().lastPathComponent])
                func print(_ aim: PrintAim, _ controls: RollControls) throws -> CGImage? {
                    let settings = try DevelopmentResolver.resolve(stock: stock, stockDigest: stock.digest, controls: controls, aim: aim, manual: nil,
                                                                   grain: OutputSettings.Grain.natural.amount, grainSeed: frame.grainSeed, sharpen: true)
                    return D.tile(ExposureAnalyzer.pixels(of: try renderer.render(sheet, settings: settings).image.texture), width: w, height: h, gpu: gpu, longSide: 480)
                }
                let box = RollControls(ratedAt: .boxSpeed, labBalance: .auto)
                place(try print(PrintAim(level: Float(old[0]), cast: aim.cast), box), 0, top)
                place(try print(aim, box), 1, top)
                place(try print(aim, RollControls(ratedAt: .oneStopUnder, labBalance: .auto)), 2, top)
                place(try print(aim, RollControls(ratedAt: .twoStopsUnder, labBalance: .auto)), 3, top)
                let stem = frame.url.deletingPathExtension().lastPathComponent
                if let source = CGImageSourceCreateWithURL(exports.appendingPathComponent("auto/\(stem).tif") as CFURL, nil),
                   let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 960,
                                                                                 kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { place(picture, 4, top) }
                if let range = frame.info.fullSizePreview, let jpeg = try? EmbeddedJPEG.image(at: range, in: frame.url, maxPixelSize: 960, orientation: frame.info.orientation) { place(jpeg, 5, top) }
                let caption = String(format: "%@   today: aim %+.2f   new: aim %+.2f, burn %.2f, dodge %.2f", stem, old[0], aim.level, aim.burn, aim.dodge)
                D.draw(caption, at: CGPoint(x: margin, y: height - top - tileH - 16), in: context, color: CGColor(gray: 0.72, alpha: 1))
            }
        }
        try D.writePNG(try #require(context.makeImage()), to: out.appendingPathComponent("before-after.png"))
    }

    @Test(.enabled(if: FrameViewMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_TONESWEEP_OUT"] != nil))
    func sweep() throws {
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(environment["ARGENT_TONESWEEP_OUT"]))
        try #require(!out.resolvingSymlinksInPath().path.hasPrefix(M.root.path + "/"), "keep derived data outside the repository")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let every = environment["ARGENT_TONESWEEP_EVERY"].flatMap(Int.init) ?? 1
        let override = Self.shape(environment)
        var entries: [(set: String, url: URL)] = []
        for part in try #require(environment["ARGENT_TONESWEEP_LISTS"]).split(separator: ",") {
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            let lines = try String(contentsOfFile: pieces[1], encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            entries += lines.enumerated().filter { $0.offset % every == 0 }.map { (pieces[0], URL(fileURLWithPath: $0.element)) }
        }
        let rowsURL = out.appendingPathComponent("rows.jsonl")
        FileManager.default.createFile(atPath: rowsURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: rowsURL)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let gpu = try GPU(maxIdlePoolBytes: 256 << 20)
        let raw9 = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9), contextPerDecode: true, inHouseAtOnce: FilmPreviews.inHouseDecodesAtOnce)
        let apple = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let controls = RollControls(ratedAt: .boxSpeed, labBalance: .auto)
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide

        for (index, entry) in entries.enumerated() {
            try autoreleasepool {
                let header = try? ARWFrameInfo.read(from: entry.url)
                let frame = entry.set == "fivek" ? try apple.decode(entry.url, options: options) : try raw9.decode(entry.url, options: options)
                let w = frame.width, h = frame.height
                let analysis = ExposureAnalyzer.analyze(frame, workingSpace: gpu.workingColorSpace, info: header)
                let f = FittedPlacement.Features(analysis)
                let cast = AutoBalance.cast(analysis)
                let face = analysis.faces.max(by: { $0.area < $1.area }).map { GateEvaluationProtocol.Face($0, width: w, height: h) }
                // The same cells in every rendering, placed by the decode's light.
                let decode = Self.derivative(ExposureAnalyzer.pixels(of: frame.texture), width: w, height: h)
                let cellCount = (decode.count - 2) / 3
                var band = [Int](repeating: -1, count: cellCount)
                var counts = [Int](repeating: 0, count: Self.bandEdges.count - 1)
                for c in 0..<cellCount {
                    let y = 0.2627 * Double(decode[2 + c * 3]) + 0.6780 * Double(decode[3 + c * 3]) + 0.0593 * Double(decode[4 + c * 3])
                    let s = log2(max(y, 1e-5) / 0.18)
                    if let b = Self.bandEdges.indices.dropLast().first(where: { s >= Self.bandEdges[$0] && s < Self.bandEdges[$0 + 1] }) {
                        band[c] = b
                        counts[b] += 1
                    }
                }
                var values: [[Double]] = []
                values.reserveCapacity(Self.aims.count * Self.burns.count * Self.dodges.count)
                for aim in Self.aims {
                    for burn in Self.burns {
                        for dodge in Self.dodges {
                            try autoreleasepool {
                                var settings = try DevelopmentResolver.resolve(stock: stock, stockDigest: stock.digest, controls: controls, aim: PrintAim(level: aim, cast: cast),
                                                                               manual: nil, grain: 0, grainSeed: 0, sharpen: true)
                                var tone = PrintTone(burn: burn, dodge: dodge, referenceStops: aim)
                                tone.shapeOverride = override
                                settings.tone = tone
                                let pixels = ExposureAnalyzer.pixels(of: try renderer.render(frame, settings: settings).image.texture)
                                let cells = Self.derivative(pixels, width: w, height: h)
                                var lightness = [Double](repeating: 0, count: cellCount)
                                var bandSum = [Double](repeating: 0, count: counts.count)
                                var white = 0.0
                                for c in 0..<cellCount {
                                    let y = 0.2627 * Double(cells[2 + c * 3]) + 0.6780 * Double(cells[3 + c * 3]) + 0.0593 * Double(cells[4 + c * 3])
                                    let l = G.lightness(max(y, 0))
                                    lightness[c] = l
                                    if l >= 97 { white += 1 }
                                    if band[c] >= 0 { bandSum[band[c]] += l }
                                }
                                let mean = lightness.reduce(0, +) / Double(cellCount)
                                lightness.sort()
                                func q(_ p: Double) -> Double { lightness[min(cellCount - 1, Int(p * Double(cellCount)))] }
                                var row = [mean, q(0.1), q(0.25), q(0.5), q(0.75), q(0.9), white / Double(cellCount)]
                                row.append(face.map { G.measure(pixels, width: w, height: h, region: $0.region).lightness } ?? -1)
                                for b in counts.indices { row.append(counts[b] >= 20 ? bandSum[b] / Double(counts[b]) : -1) }
                                values.append(row)
                            }
                        }
                    }
                }
                let record = Row(set: entry.set, name: entry.url.deletingPathExtension().lastPathComponent, iso: header?.iso, shutter: header?.exposureTime, aperture: header?.fNumber,
                                 level: f.level, levelPositive: max(f.level, 0), shadowSpread: f.shadowSpread, highlightSpread: f.highlightSpread, bright: f.bright, dark: f.dark,
                                 faceWeight: f.faceWeight, faceOffset: f.faceOffset, faceFrameLevel: f.faceFrameLevel, shippedAim: AutoPrint.levelStops(analysis),
                                 bandShare: counts.map { Double($0) / Double(cellCount) }, histogram: analysis.histogram, aims: Self.aims, burns: Self.burns, dodges: Self.dodges, values: values)
                try handle.write(contentsOf: encoder.encode(record) + Data("\n".utf8))
                if (index + 1) % 20 == 0 { print("TONESWEEP \(index + 1) of \(entries.count), footprint \(physicalFootprint() >> 20) MB") }
            }
        }
        print("TONESWEEP done \(entries.count)")
    }
}
