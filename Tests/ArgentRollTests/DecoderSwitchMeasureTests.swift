import ArgentCore
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArgentRoll

/// The decoder switch measured in the app's own paths (docs/decoder.md, section 14). Each runs in
/// a process of its own, with ARGENT_DECODER=apple for Apple's decoder everywhere, the app as it was
/// before the switch, or without it for the switch. They need the samples, the corpus and
/// build/stocks, and run only with ARGENT_MEASURE=1, in a release build with testing on, one at a
/// time:
///
///     ARGENT_MEASURE=1 ARGENT_MAKE_ROLL=/tmp/argent-switch-measure swift test -c release -Xswiftc -enable-testing --skip-build --filter DecoderSwitchMeasureTests/makeRoll
///     ARGENT_MEASURE=1 ARGENT_ROLL=/tmp/argent-switch-measure/mixed [ARGENT_DECODER=apple] swift test ... --filter DecoderSwitchMeasureTests/sheetFill
///
/// The develop is `DevelopMemoryTests/peakDuringADevelop` with ARGENT_ROLL.
@Suite(.serialized) struct DecoderSwitchMeasureTests {
    typealias M = FrameViewMeasureTests
    typealias A = AutoMeasureTests
    static var enabled: Bool { M.enabled }
    static let lossless = InHouseDecoderMeasureTests.lossless

    /// The lossless L sample's copies on the measurement roll, at ISOs either side of the cutoff.
    static let copyISOs = [100, 160, 200, 320, 400, 500, 640, 800, 1600, 3200, 6400]

    /// A copy of the raw at `source` with its Exif ISO (ISOSpeedRatings and RecommendedExposureIndex)
    /// set to `iso`, which both decoders and the decoder choice read.
    static func copyRaw(_ source: URL, to url: URL, iso: Int) throws {
        var data = try Data(contentsOf: source)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        func entry(_ ifd: Int, _ tag: Int) -> Int? { (0..<u16(ifd)).map { ifd + 2 + 12 * $0 }.first { u16($0) == tag } }
        let exif = u32(entry(u32(4), 0x8769)! + 8)
        if let e = entry(exif, 0x8827), u16(e + 2) == 3 {
            withUnsafeBytes(of: UInt16(min(iso, 65535)).littleEndian) { data.replaceSubrange(e + 8..<e + 10, with: $0) }
        }
        if let e = entry(exif, 0x8832), u16(e + 2) == 4 {
            withUnsafeBytes(of: UInt32(iso).littleEndian) { data.replaceSubrange(e + 8..<e + 12, with: $0) }
        }
        try data.write(to: url)
    }

    /// Writes the measurement rolls into `folder`: `mixed`, hard links to the M2 gate's 19 files (the
    /// five CC0 samples, one in each raw mode, and the 14 photographyblog frames, uncompressed and
    /// compressed) and copies of the lossless L sample at `copyISOs`, 30 frames of which 8 went to the
    /// in-house decoder at ISO 1250's cutoff; `inhouse`, the frames M8's route gives the in-house
    /// decoder; and `owner`, the mixed roll with photographyblog's frames given back the a7 IV's model
    /// name (`DecoderCoverageMeasureTests.asA7IV`), as the owner's files read: RAW 9's route gives RAW 9
    /// 28 of its 30 frames and RAW 8 lossless M and S, M8's route the in-house decoder 25.
    static func makeRolls(in folder: URL) throws {
        let mixed = folder.appendingPathComponent("mixed"), inHouse = folder.appendingPathComponent("inhouse")
        let owner = folder.appendingPathComponent("owner")
        for roll in [mixed, inHouse, owner] { try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true) }
        for file in M.gateFiles() {
            try FileManager.default.linkItem(at: file, to: mixed.appendingPathComponent(file.lastPathComponent))
            let copy = try DecoderCoverageMeasureTests.asA7IV(file), target = owner.appendingPathComponent(file.lastPathComponent)
            if copy == file { try FileManager.default.linkItem(at: file, to: target) } else { try FileManager.default.moveItem(at: copy, to: target) }
        }
        for iso in copyISOs {
            let name = String(format: "DSC06674-ISO%05d.ARW", iso)
            try copyRaw(lossless, to: mixed.appendingPathComponent(name), iso: iso)
            try FileManager.default.linkItem(at: mixed.appendingPathComponent(name), to: owner.appendingPathComponent(name))
        }
        for file in RollScanner.rawFiles(in: mixed) where DecoderChoice.of(file, route: .inHouse) == .inHouse {
            try FileManager.default.linkItem(at: file, to: inHouse.appendingPathComponent(file.lastPathComponent))
        }
    }

    @Test(.enabled(if: enabled && ProcessInfo.processInfo.environment["ARGENT_MAKE_ROLL"] != nil))
    func makeRoll() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARGENT_MAKE_ROLL"]!)
        try Self.makeRolls(in: folder)
        for name in ["mixed", "inhouse", "owner"] {
            let roll = await RollScanner.scan(folder.appendingPathComponent(name))
            let own = roll.frames.filter { DecoderChoice.of($0.url, route: .inHouse) == .inHouse }.count
            let learned = roll.frames.filter { DecoderChoice.of($0.url) == .raw9 }.count
            print("MEASURE roll \(name): \(roll.frames.count) frames, \(own) in-house on M8's route, \(learned) RAW 9 on RAW 9's, the rest RAW 8")
        }
    }

    /// The roll's frames: ARGENT_ROLL, or the M2 gate's files.
    static func frames() async -> [Frame] {
        if let roll = ProcessInfo.processInfo.environment["ARGENT_ROLL"] {
            return await RollScanner.scan(URL(fileURLWithPath: roll)).frames
        }
        var frames: [Frame] = []
        for folder in ["samples", "references/corpus/photographyblog-a7iv"] {
            frames += await RollScanner.scan(M.root.appendingPathComponent(folder)).frames
        }
        return frames
    }

    /// build/stocks, which may be a link to another checkout's (the library does not follow one).
    static var stocks: URL { M.root.appendingPathComponent("build/stocks").resolvingSymlinksInPath() }

    /// ARGENT_INHOUSE_AT_ONCE for the previews' bound on in-house decodes, 0 for none.
    static var atOnce: Int? {
        guard let given = ProcessInfo.processInfo.environment["ARGENT_INHOUSE_AT_ONCE"].flatMap(Int.init) else {
            return FilmPreviews.inHouseDecodesAtOnce
        }
        return given > 0 ? given : nil
    }

    /// The route this process runs, as the measurements name it.
    static var decoderName: String { routeName(DecoderChoices.requestedRoute) }

    /// A route as the measurements name it: RAW 8 everywhere is "Apple's decoder only" and M8's route
    /// "the decoder switch", as the measurements before RAW 9 named them.
    static func routeName(_ route: DecoderRoute) -> String {
        switch route {
        case .apple: return "Apple's decoder only"
        case .inHouse: return "the decoder switch"
        case .raw9: return "RAW 9's route"
        }
    }

    /// How a run on `route` groups its frames: by the decoder its route gives each by header, and a run
    /// of RAW 8 alone as RAW 9's route would, so its groups line up with that run's.
    static func group(_ url: URL, _ route: DecoderRoute) -> DecoderChoice {
        DecoderChoice.of(url, route: route == .apple ? .raw9 : route)
    }

    static func settings(_ frame: Frame) -> DevelopSettings {
        DevelopSettings(grain: 1, grainSeed: frame.grainSeed, halation: true, sharpen: true)
    }

    /// A roll's sheet filling as the app fills it: every frame asked for at once at a cell's
    /// pixels, through the six stocks' previews, decodes two at a time, first with an empty disk
    /// cache and then opened again from it. When each film arrives, the decodes, and the process's
    /// footprint at its peak, as the last film arrives, once the sheet has been idle past
    /// `FilmPreviews.idleTrimDelay`, and after the trim a develop makes.
    @Test(.enabled(if: enabled))
    func sheetFill() async throws {
        let stocks = StockLibrary.load(from: Self.stocks).stocks
        #expect(stocks.count == 6)
        let frames = await Self.frames()
        let choices = DecoderChoices()
        // Grouped by the decoder the route gives each frame, a run of RAW 8 alone as RAW 9's route would.
        let byDecoder = Dictionary(grouping: frames.indices) { Self.group(frames[$0].url, choices.route) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("argent-sheet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let disk = LinearDiskCache(folder: cache)
        // Shaders and decoders warmed outside the measurement, with no disk cache.
        do {
            let warm = try FilmPreviews(stocks: stocks, decoderChoices: choices)
            for frame in byDecoder.values.compactMap({ $0.first }).map({ frames[$0] }) {
                _ = await warm.film(frame, stock: 0, settings: Self.settings(frame), maxPixelSize: 448)
            }
            warm.removeAll()
            warm.trimForDevelop()
        }
        // Until the warm-up's idle trim has run and let it go.
        try await Task.sleep(for: FilmPreviews.idleTrimDelay + .seconds(1))
        print("MEASURE sheet fill with \(Self.decoderName), \(frames.count) frames (\(byDecoder[.raw9]?.count ?? 0) RAW 9's, \(byDecoder[.inHouse]?.count ?? 0) the in-house decoder's by header), decodes at once \(FilmPreviews.concurrentDecodes), in-house \(Self.atOnce.map(String.init) ?? "unbounded"), load \(InHouseDecoderMeasureTests.loadAverage())")
        for pass in ["first open", "opened again"] {
            let films = try FilmPreviews(stocks: stocks, diskCache: disk, decoderChoices: choices, inHouseDecodesAtOnce: Self.atOnce)
            let clock = ContinuousClock(), start = clock.now
            let arrivals = Arrivals(count: frames.count)
            // The footprint by kind where a 5 ms sampler saw its highest.
            let kinds = StageTimeline([])
            kinds.start()
            let (base, peak) = await peakFootprint {
                await withTaskGroup(of: Void.self) { group in
                    for (index, frame) in frames.enumerated() {
                        group.addTask {
                            let film = await films.film(frame, stock: 0, settings: Self.settings(frame), maxPixelSize: 448)
                            arrivals.set(index, film == nil ? .nan : M.ms(clock.now - start))
                        }
                    }
                }
            }
            let total = M.ms(clock.now - start)
            print("MEASURE   \(pass), \(kinds.stop())")
            disk.flush()
            let filled = physicalFootprint()
            try await Task.sleep(for: FilmPreviews.idleTrimDelay + .seconds(1))
            let idle = physicalFootprint()
            films.trimForDevelop()
            let trimmed = physicalFootprint()
            let times = arrivals.all
            func part(_ decoder: DecoderChoice) -> String {
                guard let indices = byDecoder[decoder], !indices.isEmpty else { return "none" }
                let t = indices.map { times[$0] }.sorted()
                return String(format: "%d, last at %.0f ms", t.count, t.last!)
            }
            // Each group is the frames the route gives that decoder by header, in every run.
            print(String(format: "MEASURE   %@: all %d films in %.0f ms (%.1f frames a second), %d decodes, %d from disk; RAW 9 frames %@; in-house frames %@; RAW 8's %@; footprint %d MB at start, peak %d MB, %d MB filled, %d MB idle, %d MB after the develop's trim",
                         pass, frames.count, total, Double(frames.count) / total * 1000, films.decodeCount, films.diskHitCount,
                         part(.raw9), part(.inHouse), part(.apple), base >> 20, peak >> 20, filled >> 20, idle >> 20, trimmed >> 20))
            #expect(!times.contains { $0.isNaN })
        }
    }

    /// Opening each frame of the roll in the frame view as the app does (docs/M2-shell.md,
    /// section 4): its film at 2190 px, its neutral raw and the stock strip's six chips from one
    /// decode; a stock switch; and the film of a frame decoded ahead. By decoder. With ARGENT_REFINE=1,
    /// also when an Apple-decoded frame's film from its refined decode is up.
    @Test(.enabled(if: enabled))
    func frameView() async throws {
        let stocks = StockLibrary.load(from: Self.stocks).stocks
        let choices = DecoderChoices()
        let films = try FilmPreviews(stocks: stocks, decoderChoices: choices, inHouseDecodesAtOnce: Self.atOnce)
        let frames = await Self.frames()
        let clock = ContinuousClock()
        for frame in Dictionary(grouping: frames, by: { Self.group($0.url, choices.route) }).values.compactMap(\.first) {
            _ = await films.frameFilm(frame, stock: 0, settings: Self.settings(frame), pixels: 900)
        }
        films.removeAll()
        let pixels = 2190
        // ARGENT_PAUSE seconds between frames, as a person looks at each; past the idle trim the
        // in-house decoder makes its buffers again.
        let pause = ProcessInfo.processInfo.environment["ARGENT_PAUSE"].flatMap(Double.init) ?? 0
        var firstFilm: [DecoderChoice: [Double]] = [:], allChips: [DecoderChoice: [Double]] = [:]
        var switches: [DecoderChoice: [Double]] = [:], ahead: [DecoderChoice: [Double]] = [:]
        for frame in frames {
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
            // Grouped by the decoder the route gives the frame, a run of RAW 8 alone as RAW 9's route would.
            let decoder = Self.group(frame.url, choices.route)
            let before = films.decodeCount
            let start = clock.now
            async let large = films.frameFilm(frame, stock: 0, settings: Self.settings(frame), pixels: pixels)
            async let neutral = films.frameNeutral(frame, lens: .default, pixels: pixels)
            let chips = Task {
                await withTaskGroup(of: Void.self) { group in
                    for stock in 0..<6 {
                        group.addTask {
                            _ = await films.film(frame, stock: stock, settings: Self.settings(frame), maxPixelSize: 208, priority: .high,
                                                 frameViewSide: FilmPreviews.frameDecodeSide(forPixels: pixels))
                        }
                    }
                }
                return clock.now
            }
            _ = await large
            firstFilm[decoder, default: []].append(M.ms(clock.now - start))
            _ = await neutral
            allChips[decoder, default: []].append(M.ms(await chips.value - start))
            #expect(films.decodeCount - before == 1, "\(frame.name)")
            for stock in 1..<6 {
                let s = clock.now
                _ = await films.frameFilm(frame, stock: stock, settings: Self.settings(frame), pixels: pixels)
                switches[decoder, default: []].append(M.ms(clock.now - s))
            }
        }
        films.removeAll()
        for frame in frames {
            _ = await films.frameFilm(frame, stock: 0, settings: Self.settings(frame), pixels: pixels, priority: .low)
            let s = clock.now
            var other = Self.settings(frame)
            other.labBalance = SIMD3(0.01, 0, 0)
            _ = await films.frameFilm(frame, stock: 0, settings: other, pixels: pixels)
            ahead[Self.group(frame.url, choices.route), default: []].append(M.ms(clock.now - s))
        }
        print("MEASURE frame view with \(Self.decoderName) at \(pixels) px\(pause > 0 ? ", \(pause) s between frames" : ""), load \(InHouseDecoderMeasureTests.loadAverage())")
        for decoder in [DecoderChoice.raw9, .inHouse, .apple] where firstFilm[decoder] != nil {
            print("MEASURE   frames the route gives the \(decoder.rawValue) decoder: first film \(M.summary(firstFilm[decoder]!)); six chips done \(M.summary(allChips[decoder]!)); stock switch \(M.summary(switches[decoder]!)); film of a frame decoded ahead \(M.summary(ahead[decoder]!))")
        }
        let all = firstFilm.values.flatMap { $0 }
        print("MEASURE   every frame: first film \(M.summary(all)); six chips done \(M.summary(allChips.values.flatMap { $0 }))")
        // ARGENT_REFINE=1: each frame Apple decodes opened again as the frame view opens it, its film up
        // and on screen `refineSettle`, then refined (`refineFrame`) and its film rendered from the
        // develop's own decode: when the refined film is up, from the open.
        guard ProcessInfo.processInfo.environment["ARGENT_REFINE"] == "1" else { return }
        films.removeAll()
        var refinedUp: [DecoderChoice: [Double]] = [:], refinement: [DecoderChoice: [Double]] = [:]
        for frame in frames {
            let decoder = Self.group(frame.url, choices.route)
            let start = clock.now
            _ = await films.frameFilm(frame, stock: 0, settings: Self.settings(frame), pixels: pixels)
            try await Task.sleep(for: FilmPreviews.refineSettle)
            let asked = clock.now
            guard await films.refineFrame(frame, lens: .default, pixels: pixels) else { continue }
            _ = await films.frameFilm(frame, stock: 0, settings: Self.settings(frame), pixels: pixels)
            refinedUp[decoder, default: []].append(M.ms(clock.now - start))
            refinement[decoder, default: []].append(M.ms(clock.now - asked))
        }
        for decoder in [DecoderChoice.raw9, .inHouse, .apple] where refinedUp[decoder] != nil {
            print("MEASURE   frames the route gives the \(decoder.rawValue) decoder: refined film up \(M.summary(refinedUp[decoder]!)) from the open, settling \(FilmPreviews.refineSettle); the refinement and its film \(M.summary(refinement[decoder]!))")
        }
    }

    /// The in-house decoder's scaled decodes, rendered as the sheet and the frame view render
    /// them, against its full-size develop area-resized to the same pixels (docs/M3-auto.md,
    /// sections 9 and 11): the three detail bands' amplitude, and Apple's decoder the same way
    /// beside it. On the CC0 lossless L sample through the decoder, the CC0 uncompressed sample and
    /// Imaging Resource's ISO 100 still life through its GPU half (the still life for evaluation
    /// only), with the still life's two chart edges.
    @Test(.enabled(if: enabled))
    func sharpness() throws {
        typealias F = FrameViewSharpnessMeasureTests
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let inHouse = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu)
        let stock = try Stock.load(from: M.root.appendingPathComponent("build/stocks/kodak-portra-400"))
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let resize = try AreaResize(gpu: gpu)
        let sharpened = DevelopSettings(sharpen: true)
        let sides = ProcessInfo.processInfo.environment["FRAME_VIEW_SIZES"].map { $0.split(separator: ",").compactMap { Int($0) } }
            ?? [960, 900, 1408, 2048, 2190, 2600, 2944, 3072, 3500, 3700, 4096, 6144]
        let frames: [(name: String, url: URL)] = [
            ("CC0 lossless L", Self.lossless),
            ("CC0 uncompressed", SyntheticRaw.base),
            ("still life ISO 100 (evaluation)", F.stillLife),
        ]
        func bands(_ texture: MTLTexture) -> [Float] { A.bands(A.lightness(ExposureAnalyzer.pixels(of: texture)), width: texture.width) }
        func ratio(_ a: [Float], _ b: [Float]) -> String { zip(a, b).map { String(format: "%.2f", $0 / $1) }.joined(separator: ", ") }
        for (name, url) in frames {
            func ours(_ options: DecodeOptions) throws -> LinearFrame {
                try InHouseDecoderMeasureTests.inHouse(url, decoder: inHouse, gpu: gpu, options: options)
            }
            let ourFull = try ours(DecodeOptions()), appleFull = try apple.decode(url, options: DecodeOptions())
            let ourDevelop = try renderer.render(ourFull, settings: sharpened).image
            let appleDevelop = try renderer.render(appleFull, settings: sharpened).image
            print("MEASURE sharpness, \(name), the scaled decode rendered over the develop area-resized, bands near 0.31, 0.15, 0.08 cycles a pixel")
            for side in sides {
                var options = DecodeOptions()
                options.maxLongSide = side
                options.fillsMaxLongSide = true
                let ourScaled = try ours(options), appleScaled = try apple.decode(url, options: options)
                let ourTarget = try A.area(ourDevelop.texture, longSide: side, resize: resize)
                let appleTarget = try A.area(appleDevelop.texture, longSide: side, resize: resize)
                let ourRender = try renderer.render(ourScaled, settings: sharpened).image
                let appleRender = try renderer.render(appleScaled, settings: sharpened).image
                let t = A.bands(A.lightness(ourTarget.pixels), width: ourTarget.width)
                let u = A.bands(A.lightness(appleTarget.pixels), width: appleTarget.width)
                // The neutral raw against the full-size decode area-resized.
                let rawTarget = try A.area(ourFull.texture, longSide: side, resize: resize)
                var line = String(format: "MEASURE   %d px: in-house %@ (%d by %d, scaling mask %@); Apple %@ (%@); in-house neutral raw %@",
                                  side, ratio(bands(ourRender.texture), t), ourScaled.width, ourScaled.height,
                                  CaptureSharpening.masks(for: ourScaled).scaling == nil ? "none" : "on",
                                  ratio(bands(appleRender.texture), u), appleScaled.pins?.draftMode == true ? "draft" : "not draft",
                                  ratio(bands(ourScaled.texture), A.bands(A.lightness(rawTarget.pixels), width: rawTarget.width)))
                if url == F.stillLife {
                    let s = Float(side) / Float(ourFull.width)
                    let tl = A.lightness(ourTarget.pixels), rl = A.lightness(ExposureAnalyzer.pixels(of: ourRender.texture))
                    line += "\nMEASURE     edges: in-house develop \(F.edges(tl, width: ourTarget.width, s: s)); in-house scaled \(F.edges(rl, width: ourRender.width, s: s))"
                }
                print(line)
            }
            // The sheet's picture made from the frame view's decode, as FilmPreviews makes it when the
            // frame view is open: the frame view's decode area-resized to 960 before the film.
            for side in [2190, 3700] {
                var options = DecodeOptions()
                options.maxLongSide = side
                let large = try ours(options)
                let scale = 960 / Double(max(large.width, large.height))
                let small = try resize.resized(large.texture, scale: scale)
                let frame = LinearFrame(image: small, decoderVersion: large.decoderVersion, scale: large.scale * Float(scale),
                                        pins: large.pins, readback: large.readback)
                let target = try A.area(ourDevelop.texture, longSide: 960, resize: resize)
                let rendered = try renderer.render(frame, settings: sharpened).image
                print("MEASURE   960 px from the frame view's \(side) px decode: in-house \(ratio(bands(rendered.texture), A.bands(A.lightness(target.pixels), width: target.width)))")
            }
        }
    }

    /// Auto development's measurement of a frame from each decoder's 960-pixel decode: the level,
    /// the gray estimate and the histogram, in-house against Apple. On the CC0 lossless L sample and
    /// its copies at other ISOs, and through the GPU half on the CC0 uncompressed sample and the
    /// photographyblog frames whose mosaics it reads (evaluation only).
    @Test(.enabled(if: enabled))
    func analysis() throws {
        let gpu = try GPU(maxIdlePoolBytes: 1 << 30)
        let inHouse = try InHouseDecoder(gpu: gpu)
        let apple = AppleRawDecoder(gpu: gpu)
        var options = DecodeOptions()
        options.maxLongSide = FilmPreviews.previewLongSide
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var files = [Self.lossless]
        for iso in [100, 640] {
            let copy = folder.appendingPathComponent("DSC06674-ISO\(iso).ARW")
            try Self.copyRaw(Self.lossless, to: copy, iso: iso)
            files.append(copy)
        }
        files.append(SyntheticRaw.base)
        files += RollScanner.rawFiles(in: M.root.appendingPathComponent("references/corpus/photographyblog-a7iv")).sorted { $0.path < $1.path }
        var levels: [Double] = [], grays: [Double] = [], distances: [Double] = [], corrections: [Double] = []
        for url in files {
            guard let ours = try? InHouseDecoderMeasureTests.inHouse(url, decoder: inHouse, gpu: gpu, options: options) else { continue }
            let theirs = try apple.decode(url, options: options)
            let a = ExposureAnalyzer.analyze(ours, workingSpace: gpu.workingColorSpace)
            let b = ExposureAnalyzer.analyze(theirs, workingSpace: gpu.workingColorSpace)
            let gray = a.grayEstimate.count == 3 && b.grayEstimate.count == 3 ? zip(a.grayEstimate, b.grayEstimate).map { $0 - $1 } : []
            let distance = a.histogramDistance(to: b) ?? .nan
            levels.append(Double(a.meanStops - b.meanStops))
            if let worst = gray.map({ abs(Double($0)) }).max() { grays.append(worst) }
            distances.append(Double(distance))
            // What auto lab balance prints from each: the correction's two axes, in mired and in stops.
            let ca = AutoBalance.correction(for: AutoBalance.cast(a)), cb = AutoBalance.correction(for: AutoBalance.cast(b))
            let axesA = AutoBalance.axes(ca), axesB = AutoBalance.axes(cb)
            corrections.append(Double(abs(axesA.redBlue - axesB.redBlue) / AutoBalance.stopsPerMired))
            print(String(format: "MEASURE analysis %@ (ISO %d): level %+.3f stops (Apple %.2f), gray estimate %@ stops, histogram distance %.3f stops, faces %d against %d; lab balance red-blue %+.1f mired against Apple's %+.1f, green-magenta %+.3f stops against %+.3f",
                         url.lastPathComponent, (try? ARWFrameInfo.read(from: url).iso ?? 0) ?? 0, a.meanStops - b.meanStops, b.meanStops,
                         gray.map { String(format: "%+.3f", $0) }.joined(separator: ", "), distance, a.faces.count, b.faces.count,
                         axesA.redBlue / AutoBalance.stopsPerMired, axesB.redBlue / AutoBalance.stopsPerMired, axesA.greenMagenta, axesB.greenMagenta))
        }
        func spread(_ v: [Double]) -> String {
            let s = v.map(abs).sorted()
            return String(format: "median %.3f, largest %.3f (n=%d)", s[s.count / 2], s.last!, s.count)
        }
        print("MEASURE analysis, in-house against Apple: level \(spread(levels)) stops; worst gray channel \(spread(grays)) stops; histogram distance \(spread(distances)) stops; lab balance red-blue \(spread(corrections)) mired")
    }
}

private final class Arrivals: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double]
    init(count: Int) { times = Array(repeating: .nan, count: count) }
    func set(_ index: Int, _ value: Double) { lock.withLock { times[index] = value } }
    var all: [Double] { lock.withLock { times } }
}
