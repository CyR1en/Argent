import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The new Subject's two edges on real frames (the build's task B2): the real path's coverage from the stored seeds and alphas against the research's
/// candidates, the plan's per-surface table through the film, a develop's memory, and a slider's latency. Private frames are read where they
/// lie and nothing of them enters Git. It runs only when asked, on a release build with testing on:
///
///     ARGENT_MEASURE=1 ARGENT_EDGE_OUT=<folder> ARGENT_EDGE_COVERAGE=<items.json> swift test -c release -Xswiftc -enable-testing --filter SubjectEdgeProofTests/theCoverage
///     ARGENT_MEASURE=1 ARGENT_EDGE_OUT=<folder> ARGENT_EDGE_SURFACES=<manifest.json> ... --filter SubjectEdgeProofTests/theSurfaces
///     ARGENT_MEASURE=1 ARGENT_EDGE_OUT=<folder> ARGENT_EDGE_ROLL=<folder of raws> ... --filter SubjectEdgeProofTests/theDevelop
///     ARGENT_MEASURE=1 ARGENT_EDGE_OUT=<folder> ARGENT_EDGE_SLIDER=<raw> ... --filter SubjectEdgeProofTests/theSlider
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] != nil && ProcessInfo.processInfo.environment["ARGENT_EDGE_OUT"] != nil))
struct SubjectEdgeProofTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var out: URL { URL(fileURLWithPath: environment["ARGENT_EDGE_OUT"]!, isDirectory: true) }

    struct CoverageItem: Codable { var id: String; var raw: String; var seed: String?; var edge: SmartEdge; var refW: Int; var refH: Int }
    struct V6Variant: Codable { var name: String; var seed: String; var edge: SmartEdge; var plusPointSeven: Bool? }
    struct V6Frame: Codable { var id: String; var raw: String; var seeds: [String: String] }
    struct V6Manifest: Codable { var frames: [V6Frame]; var variants: [V6Variant] }

    static func raster(_ path: String) throws -> MaskRaster {
        try MaskRefinerSurfaceTests.seed(.init(stem: "edge", raw: "", kind: "subject", seed: path, format: "png"), frameWidth: 1, frameHeight: 1)
    }

    static func decode(_ c: MaskRefinerSurfaceTests.Context, _ path: String) throws -> LinearFrame {
        var options = DecodeOptions()
        options.tileSize = RollDeveloper.decodeTile
        options.learnedTileSize = RollDeveloper.learnedDecodeTile
        return try c.decoder.decode(URL(fileURLWithPath: path), options: options)
    }

    static func edged(_ edge: SmartEdge, _ component: MaskComponent) throws -> MaskComponent {
        guard case .smart(var selection) = component.shape else { throw MaskError.invalid("not a selection") }
        selection.edge = edge
        var edged = component
        edged.shape = .smart(selection)
        return edged
    }

    /// The real path's coverage from the stored seed or alpha, as V7's and Y2's candidates were written: Exposure −1.5 EV on the full-size decode, read
    /// by the probe per pixel, area-averaged to the reference's size, top row first, `cov/<id>.f32`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_EDGE_COVERAGE"] != nil))
    func theCoverage() throws {
        let items = try JSONDecoder().decode([CoverageItem].self, from: Data(contentsOf: URL(fileURLWithPath: Self.environment["ARGENT_EDGE_COVERAGE"]!)))
        let folder = Self.out.appendingPathComponent("cov", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let c = try MaskRefinerSurfaceTests.context()
        for item in items {
            guard let path = item.seed else { continue }
            let frame = try Self.decode(c, item.raw)
            let raster = try Self.raster(path)
            c.seeds.add(raster)
            let base = try MaskRefinerSurfaceTests.settings(c, URL(fileURLWithPath: item.raw), grain: false)
            let component = try Self.edged(item.edge, try MaskRefinerSurfaceTests.component("subject", raster, background: false, width: frame.width, height: frame.height))
            let settings = try MaskRefinerSurfaceTests.masked(base, component, exposure: -1.5)
            let values = try #require(try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, frame, settings, coverage: true).coverage)
            c.gpu.maskRefiner.removeAll(); c.gpu.maskFields.removeAll()
            let small = MaskRefinerSurfaceTests.resized(values, width: frame.width, height: frame.height, toWidth: item.refW, toHeight: item.refH)
            var flipped = [Float](repeating: 0, count: small.count)
            for y in 0..<item.refH { let from = y * item.refW, to = (item.refH - 1 - y) * item.refW; flipped[to..<(to + item.refW)] = small[from..<(from + item.refW)] }
            try flipped.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("\(item.id).f32")) }
            print("EDGE coverage \(item.id) \(item.edge) \(frame.width)x\(frame.height)")
        }
    }

    /// A develop with crisp and matte selections through the real developer, at each format: its peak footprint.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_EDGE_ROLL"] != nil))
    func theDevelop() async throws {
        let files = RollScanner.rawFiles(in: URL(fileURLWithPath: Self.environment["ARGENT_EDGE_ROLL"]!))
        let (stocks, stock) = try PerformanceTargetMeasureTests.stocks()
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = try SubjectEdgeProofFixtures.alpha(width: 2560, height: 1707), seed = try SubjectEdgeProofFixtures.alpha(width: 1024, height: 683)
        let picture = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        func selection(_ kind: SmartKind, _ raster: MaskRaster, _ edge: SmartEdge, feather: Float = 0) -> MaskComponent {
            MaskComponent(shape: .smart(SmartSelection(kind: kind, raster: raster.ref, frame: picture, feather: feather, edge: edge)))
        }
        let exposure = try ManualAdjustments(exposureEV: -0.7), tone = try ManualAdjustments(highlights: -30, shadows: 20)
        let masks = try MaskSet(masks: [Mask(components: [selection(.subject, seed, .crisp)], adjustments: exposure),
                                        Mask(components: [selection(.subject, alpha, .matte)], adjustments: try ManualAdjustments(exposureEV: 0.7)),
                                        Mask(components: [selection(.background, alpha, .matte)], adjustments: tone),
                                        Mask(components: [selection(.subject, seed, .crisp, feather: 30)], adjustments: try ManualAdjustments(exposureEV: 0.3))])
        let controls = RollControls()
        // A roll and a library each: a develop's recipe is a first edit of its frame.
        for (index, format) in [OutputSettings.Format.jpeg, .heic, .tiff16].enumerated() {
            let folder = root.appendingPathComponent("roll-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let frames = try await PerformanceTargetMeasureTests.roll(files, in: folder)
            let library = root.appendingPathComponent("library-\(index)")
            let store = MaskRasterStore(library: library)
            try store.store(alpha); try store.store(seed)
            let jobs = try frames.map { frame in
                let baseline = AutomaticBaseline(sourceSHA256: try RecipeStore.sha256(of: frame.url), stockID: stock.id, stockDigest: stock.digest,
                                                 controls: controls, aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
                                                 baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
                return RollDeveloper.Job(frame: frame, recipe: try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                                                                                roll: controls, own: FrameControls(), manual: ManualEdit(adjustments: try ManualAdjustments(masks: masks), baseline: baseline)))
            }
            let developer = try RollDeveloper(stocks: stocks, software: "Argent measure", library: library)
            var outcomes: [RollDeveloper.Outcome] = []
            let (base, peak) = await peakFootprint {
                outcomes = await developer.develop(jobs, to: root.appendingPathComponent("out-\(index)"), output: OutputSettings(format: format))
            }
            let failed = PerformanceTargetMeasureTests.failures(outcomes)
            print("EDGE develop \(format.title): \(jobs.count) frames, \(failed.count) failed, footprint \(base >> 20) MB at start, peak \(peak >> 20) MB (target 2000); \(developer.heldReport)")
            for reason in failed.prefix(5) { print("EDGE failed: \(reason)") }
            #expect(failed.isEmpty)
            #expect(peak >> 20 < 2000, "\(format.title) peak \(peak >> 20) MB")
        }
    }

    /// A slider through the frame view's film on a crisp and a matte selection, from the second step on: each step asks the coverage for
    /// nothing new. The film the previews make, as the app reads it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_EDGE_SLIDER"] != nil))
    func theSlider() async throws {
        let raw = URL(fileURLWithPath: Self.environment["ARGENT_EDGE_SLIDER"]!)
        let (stocks, _) = try PerformanceTargetMeasureTests.stocks()
        let frame = try #require(await RollScanner.scan(raw.deletingLastPathComponent()).frames.first { $0.url.lastPathComponent == raw.lastPathComponent })
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .raw9))
        let picture = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let alpha = try SubjectEdgeProofFixtures.alpha(width: 2560, height: 1707), seed = try SubjectEdgeProofFixtures.alpha(width: 1024, height: 683)
        films.maskSeeds = SubjectEdgeProofFixtures.Seeds(rasters: [alpha, seed])
        for (label, raster, edge) in [("crisp", seed, SmartEdge.crisp), ("matte", alpha, .matte)] {
            for pixels in [1201, 2190, 4912] {
                var times: [Double] = []
                for step in 0..<60 {
                    let ev = Float(step + 1) * 0.0137 - 0.97   // a value of its own each step, so no film is found kept
                    let settings = try MaskFixtures.settings(MaskSet(masks: [Mask(components: [MaskComponent(shape: .smart(SmartSelection(kind: .subject, raster: raster.ref, frame: picture, edge: edge)))],
                                                                                 adjustments: try ManualAdjustments(exposureEV: ev))]))
                    let started = Date()
                    _ = try #require(await films.frameFilm(frame, stock: 0, settings: settings, pixels: pixels))
                    if step > 0 { times.append(Date().timeIntervalSince(started) * 1000) }
                }
                let sorted = times.sorted(), p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                print(String(format: "EDGE slider %@ at %d px: p95 %.1f ms, median %.1f ms, worst %.1f ms", label, pixels, p95, sorted[sorted.count / 2], sorted.last ?? 0))
                #expect(p95 < 100, "\(label) at \(pixels)")
            }
        }
    }

    // MARK: V6's table

    struct V6Row: Codable {
        var id: String; var variant: String; var adjustment: String; var surface: String; var size: Int
        var filmP99: Float; var maskP99: Float; var excess: Float; var coverageP99: Float; var bandPixels: Int
        var limitExcess: Float; var limitCoverage: Float; var passes: Bool; var gain: Float
        // The same p99s on today's develop band, so a variant's own narrower band does not move them: `fixed*`.
        var fixedFilmP99: Float; var fixedMaskP99: Float; var fixedExcess: Float; var fixedCoverageP99: Float; var fixedBandPixels: Int
        // The same p99s within 6 surface px of the develop's 0.5 contour, a band that does not depend on the edge's width: `contour*`.
        var contourFilmP99: Float; var contourMaskP99: Float; var contourExcess: Float; var contourCoverageP99: Float; var contourBandPixels: Int
    }
    struct V6Step: Codable { var id: String; var variant: String; var adjustment: String; var size: Int; var step: Float; var settle: Float; var ratio: Float }
    struct V6Selection: Codable {
        var id: String; var variant: String; var surface: String; var size: Int; var gain: Float
        var contourShiftP50: Float; var contourShiftP95: Float
        var flipShare: Float; var flipLargest: Int
        var softShare: Float; var softLargest: Int
        var selectedShare: Float
        // Per contour pixel of the develop's selection at this size: pixels where the coverages differ by more than 0.1 and 0.25 (the width of the disagreeing strip), the edge's partial-coverage width on the surface and on the develop, and the mean signed difference (shown − develop) over the same pixels.
        var strip010: Float; var strip025: Float; var shownEdgeWidth: Float; var developEdgeWidth: Float; var meanSigned: Float
    }

    /// Two-pass chamfer distance (1, √2) to the nearest `true` of `source`.
    static func chamfer(_ source: [Bool], width w: Int, height h: Int) -> [Float] {
        let far = Float(w + h), diagonal = Float(2).squareRoot()
        var d = source.map { $0 ? Float(0) : far }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var v = d[i]
                if x > 0 { v = min(v, d[i - 1] + 1) }
                if y > 0 {
                    v = min(v, d[i - w] + 1)
                    if x > 0 { v = min(v, d[i - w - 1] + diagonal) }
                    if x < w - 1 { v = min(v, d[i - w + 1] + diagonal) }
                }
                d[i] = v
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                var v = d[i]
                if x < w - 1 { v = min(v, d[i + 1] + 1) }
                if y < h - 1 {
                    v = min(v, d[i + w] + 1)
                    if x > 0 { v = min(v, d[i + w - 1] + diagonal) }
                    if x < w - 1 { v = min(v, d[i + w + 1] + diagonal) }
                }
                d[i] = v
            }
        }
        return d
    }

    static func contour(_ b: [Bool], width w: Int, height h: Int) -> [Bool] {
        var c = [Bool](repeating: false, count: b.count)
        for y in 0..<h {
            for x in 0..<w where b[y * w + x] {
                let i = y * w + x
                if x == 0 || x == w - 1 || y == 0 || y == h - 1 || !b[i - 1] || !b[i + 1] || !b[i - w] || !b[i + w] { c[i] = true }
            }
        }
        return c
    }

    /// The area of `mark`, and its largest 4-connected blob.
    static func blobs(_ mark: [Bool], width w: Int, height h: Int) -> (area: Int, largest: Int) {
        var seen = mark.map { !$0 }, largest = 0, area = 0, stack: [Int] = []
        for start in mark.indices where !seen[start] {
            seen[start] = true; stack.append(start); var n = 0
            while let i = stack.popLast() {
                n += 1
                let x = i % w
                if x > 0, !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if i >= w, !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
                if i + w < w * h, !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
            }
            area += n; largest = max(largest, n)
        }
        return (area, largest)
    }

    /// What differs between a surface's coverage and the develop's at the surface's size, beyond an edge's width: the 0.5 contour's shift, the pixels whose side of 0.5 flips more than 2 px away from both contours,
    /// and the pixels whose coverage differs by more than 0.2 more than 3 px from both contours.
    static func selectionDifference(id: String, variant: String, surface: String, size: Int, gain: Float, shown: [Float], develop: [Float], width w: Int, height h: Int) -> V6Selection {
        let bs = shown.map { $0 >= 0.5 }, bd = develop.map { $0 >= 0.5 }
        let cs = contour(bs, width: w, height: h), cd = contour(bd, width: w, height: h)
        let ds = chamfer(cs, width: w, height: h), dd = chamfer(cd, width: w, height: h)
        var shifts: [Float] = []
        for i in shown.indices {
            if cs[i] { shifts.append(dd[i]) }
            if cd[i] { shifts.append(ds[i]) }
        }
        shifts.sort()
        let p50 = shifts.isEmpty ? 0 : shifts[shifts.count / 2], p95 = shifts.isEmpty ? 0 : shifts[min(shifts.count - 1, Int(Float(shifts.count) * 0.95))]
        var flip = [Bool](repeating: false, count: shown.count), soft = flip
        var selected = 0
        for i in shown.indices {
            if bd[i] { selected += 1 }
            if bs[i] != bd[i], ds[i] > 2, dd[i] > 2 { flip[i] = true }
            if abs(shown[i] - develop[i]) > 0.2, ds[i] > 3, dd[i] > 3 { soft[i] = true }
        }
        let f = blobs(flip, width: w, height: h), g = blobs(soft, width: w, height: h)
        let base = Float(max(selected, 1))
        var developContour = 0, shownContour = 0, near010 = 0, near025 = 0, partialShown = 0, partialDevelop = 0, signedCount = 0
        var signed: Float = 0
        for i in shown.indices {
            if cd[i] { developContour += 1 }
            if cs[i] { shownContour += 1 }
            let delta = shown[i] - develop[i]
            if abs(delta) > 0.1 { near010 += 1; signed += delta; signedCount += 1 }
            if abs(delta) > 0.25 { near025 += 1 }
            if shown[i] > 0.05 && shown[i] < 0.95 { partialShown += 1 }
            if develop[i] > 0.05 && develop[i] < 0.95 { partialDevelop += 1 }
        }
        let perimeter = Float(max(developContour, 1))
        return V6Selection(id: id, variant: variant, surface: surface, size: size, gain: gain, contourShiftP50: p50, contourShiftP95: p95,
                           flipShare: Float(f.area) / base, flipLargest: f.largest, softShare: Float(g.area) / base, softLargest: g.largest,
                           selectedShare: base / Float(w * h), strip010: Float(near010) / perimeter, strip025: Float(near025) / perimeter,
                           shownEdgeWidth: Float(partialShown) / Float(max(shownContour, 1)), developEdgeWidth: Float(partialDevelop) / perimeter,
                           meanSigned: signed / Float(max(signedCount, 1)))
    }


    /// The plan's per-surface table on the real edges (V6's and Y2's harness): each surface's own decode against the develop, through the film, grain off.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_EDGE_SURFACES"] != nil))
        func theSurfaces() throws {
        let manifest = try JSONDecoder().decode(V6Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: Self.environment["ARGENT_EDGE_SURFACES"]!)))
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let rowsURL = Self.out.appendingPathComponent("v6-rows.jsonl"), stepsURL = Self.out.appendingPathComponent("v6-steps.jsonl"), selectionURL = Self.out.appendingPathComponent("v6-selection.jsonl")
        func append(_ text: String, _ url: URL) throws {
            if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)) } else { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        let c = try MaskRefinerSurfaceTests.context()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for frameInfo in manifest.frames {
            let started = Date()
            let url = URL(fileURLWithPath: frameInfo.raw)
            let develop = try Self.decode(c, frameInfo.raw)
            let full = max(develop.width, develop.height)
            let base = try MaskRefinerSurfaceTests.settings(c, url, grain: false)
            var seeds: [String: MaskRaster] = [:]
            for (name, path) in frameInfo.seeds { let r = try Self.raster(path); c.seeds.add(r); seeds[name] = r }
            struct Preview { let surface: String; let size: Int; let frame: LinearFrame }
            var previews: [Preview] = []
            var sheetOptions = DecodeOptions()
            sheetOptions.maxLongSide = FilmPreviews.previewLongSide
            previews.append(Preview(surface: "sheet", size: 960, frame: try c.decoder.decode(url, options: sheetOptions)))
            for size in [2190, 4912] where size < full {
                let scaled = try c.decoder.decode(url, options: FilmPreviews.frameDecodeOptions(longSide: size))
                previews.append(Preview(surface: "scaled", size: size, frame: scaled))
                let texture = try MaskRefinerSurfaceTests.resizedTexture(c.gpu, c.resize, develop.texture, width: scaled.width, height: scaled.height)
                previews.append(Preview(surface: "refined", size: size, frame: LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: develop.decoderVersion,
                                                                                           scale: Float(scaled.width) / Float(develop.width), picture: develop.picture)))
            }
            var plainAt: [String: [Float]] = [:]
            do {
                let developPlain = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop, base, coverage: false).image
                for p in previews where plainAt["\(p.frame.width)x\(p.frame.height)"] == nil {
                    plainAt["\(p.frame.width)x\(p.frame.height)"] = MaskRefinerSurfaceTests.lightness(MaskRefinerSurfaceTests.pixels(try MaskRefinerSurfaceTests.resizedTexture(c.gpu, c.resize, developPlain.texture, width: p.frame.width, height: p.frame.height)))
                }
            }
            let previewPlain = try previews.map { MaskRefinerSurfaceTests.lightness(MaskRefinerSurfaceTests.pixels(try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, $0.frame, base, coverage: false).image.texture)) }
            var rows = "", steps = "", selections = ""
            var todayBand: [String: [Bool]] = [:]
            for variant in manifest.variants {
                guard let raster = seeds[variant.seed] else { continue }
                var adjustments: [(String, MaskComponent, Float)] = [
                    ("e-1.5", try Self.edged(variant.edge, try MaskRefinerSurfaceTests.component("subject", raster, background: false, width: develop.width, height: develop.height)), -1.5),
                    ("e+1.5", try Self.edged(variant.edge, try MaskRefinerSurfaceTests.component("subject", raster, background: false, width: develop.width, height: develop.height)), 1.5),
                    ("bg-1.5", try Self.edged(variant.edge, try MaskRefinerSurfaceTests.component("subject", raster, background: true, width: develop.width, height: develop.height)), -1.5),
                ]
                if variant.plusPointSeven ?? false {
                    adjustments.append(("e+0.7", try Self.edged(variant.edge, try MaskRefinerSurfaceTests.component("subject", raster, background: false, width: develop.width, height: develop.height)), 0.7))
                }
                var coverageDone = false
                for (name, component, exposure) in adjustments {
                    let settings = try MaskRefinerSurfaceTests.masked(base, component, exposure: exposure)
                    let developed = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, develop, settings, coverage: true)
                    let developCoverage = try #require(developed.coverage)
                    var maskedPreviews: [String: [Float]] = [:]
                    for (index, preview) in previews.enumerated() {
                        let (w, h) = (preview.frame.width, preview.frame.height)
                        let key = "\(w)x\(h)"
                        let developL = MaskRefinerSurfaceTests.lightness(MaskRefinerSurfaceTests.pixels(try MaskRefinerSurfaceTests.resizedTexture(c.gpu, c.resize, developed.image.texture, width: w, height: h)))
                        let developC = MaskRefinerSurfaceTests.resized(developCoverage, width: develop.width, height: develop.height, toWidth: w, toHeight: h)
                        let edge = MaskRefinerSurfaceTests.band(developC, width: w, height: h)
                        let gain: Float = 0
                        let shown = try MaskRefinerSurfaceTests.render(c.gpu, c.renderer, preview.frame, settings, coverage: true)
                        let previewL = MaskRefinerSurfaceTests.lightness(MaskRefinerSurfaceTests.pixels(shown.image.texture))
                        maskedPreviews["\(preview.surface)\(preview.size)"] = previewL
                        let film = MaskRefinerSurfaceTests.p99(previewPlain[index], try #require(plainAt[key]), in: edge)
                        let mask = MaskRefinerSurfaceTests.p99(previewL, developL, in: edge)
                        let coverage = try #require(shown.coverage)
                        let cp99 = MaskRefinerSurfaceTests.p99(coverage, developC, in: edge)
                        // Today's band is the first variant's develop band at this size: the first variant must be today's.
                        let bandName = "\(preview.surface)\(preview.size)"
                        if todayBand[bandName] == nil { todayBand[bandName] = edge }
                        let fixedEdge = try #require(todayBand[bandName])
                        let fixedFilm = MaskRefinerSurfaceTests.p99(previewPlain[index], try #require(plainAt[key]), in: fixedEdge)
                        let fixedMask = MaskRefinerSurfaceTests.p99(previewL, developL, in: fixedEdge)
                        let fixedCover = MaskRefinerSurfaceTests.p99(coverage, developC, in: fixedEdge)
                        let bd = developC.map { $0 >= 0.5 }
                        let contourBand = Self.chamfer(Self.contour(bd, width: w, height: h), width: w, height: h).map { $0 <= 6 }
                        let contourFilm = MaskRefinerSurfaceTests.p99(previewPlain[index], try #require(plainAt[key]), in: contourBand)
                        let contourMask = MaskRefinerSurfaceTests.p99(previewL, developL, in: contourBand)
                        let contourCover = MaskRefinerSurfaceTests.p99(coverage, developC, in: contourBand)
                        let limit = MaskRefinerSurfaceTests.limits(surface: preview.surface, kind: "subject")
                        let row = V6Row(id: frameInfo.id, variant: variant.name, adjustment: name, surface: preview.surface, size: preview.size, filmP99: film, maskP99: mask, excess: mask - film,
                                        coverageP99: cp99, bandPixels: edge.reduce(0) { $0 + ($1 ? 1 : 0) }, limitExcess: limit.excess, limitCoverage: limit.coverage,
                                        passes: mask - film <= limit.excess && cp99 <= limit.coverage, gain: gain,
                                        fixedFilmP99: fixedFilm, fixedMaskP99: fixedMask, fixedExcess: fixedMask - fixedFilm, fixedCoverageP99: fixedCover,
                                        fixedBandPixels: fixedEdge.reduce(0) { $0 + ($1 ? 1 : 0) },
                                        contourFilmP99: contourFilm, contourMaskP99: contourMask, contourExcess: contourMask - contourFilm, contourCoverageP99: contourCover,
                                        contourBandPixels: contourBand.reduce(0) { $0 + ($1 ? 1 : 0) })
                        rows += String(decoding: try encoder.encode(row), as: UTF8.self) + "\n"
                        if !coverageDone {
                            let selection = Self.selectionDifference(id: frameInfo.id, variant: variant.name, surface: preview.surface, size: preview.size, gain: gain, shown: coverage, develop: developC, width: w, height: h)
                            selections += String(decoding: try encoder.encode(selection), as: UTF8.self) + "\n"
                        }
                    }
                    coverageDone = true
                    for size in [2190, 4912] {
                        guard let scaledIndex = previews.firstIndex(where: { $0.surface == "scaled" && $0.size == size }),
                              let refinedIndex = previews.firstIndex(where: { $0.surface == "refined" && $0.size == size }),
                              let scaledL = maskedPreviews["scaled\(size)"], let refinedL = maskedPreviews["refined\(size)"] else { continue }
                        let preview = previews[refinedIndex].frame
                        let developC = MaskRefinerSurfaceTests.resized(developCoverage, width: develop.width, height: develop.height, toWidth: preview.width, toHeight: preview.height)
                        let edge = MaskRefinerSurfaceTests.band(developC, width: preview.width, height: preview.height)
                        let step = MaskRefinerSurfaceTests.p99(scaledL, refinedL, in: edge), settle = MaskRefinerSurfaceTests.p99(previewPlain[scaledIndex], previewPlain[refinedIndex], in: edge)
                        steps += String(decoding: try encoder.encode(V6Step(id: frameInfo.id, variant: variant.name, adjustment: name, size: size, step: step, settle: settle, ratio: step / max(settle, 1e-6))), as: UTF8.self) + "\n"
                    }
                }
                c.gpu.maskRefiner.removeAll()
                c.gpu.maskFields.removeAll()
            }
            try append(rows, rowsURL); try append(steps, stepsURL); try append(selections, selectionURL)
            print("V6 \(frameInfo.id) \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        }
    }}

/// A soft, structured raster the size of a seed or of a print's alpha, for the develop's and the slider's measures.
enum SubjectEdgeProofFixtures {
    static func alpha(width: Int, height: Int) throws -> MaskRaster {
        var plane = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = 0.5 + 0.3 * sin(Float(x) / 37) * cos(Float(y) / 23) + 0.2 * sin(Float(x + y) / 5.5)
                plane[y * width + x] = UInt8(min(max(v * 255, 0), 255).rounded())
            }
        }
        return try MaskRaster(width: width, height: height, plane: plane)
    }

    struct Seeds: MaskSeedProvider {
        let rasters: [RasterID: MaskRaster]
        init(rasters: [MaskRaster]) { self.rasters = Dictionary(rasters.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first }) }
        func seed(for ref: RasterRef) throws -> MaskRaster {
            guard let raster = rasters[ref.id] else { throw CocoaError(.fileNoSuchFile) }
            return raster
        }
    }
}
