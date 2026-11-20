import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The seam of docs/remove-plan.md, section 4.3, in the previews: a removal that is on names a frame's decode and one that is off
/// does not; it reaches the sheet's and the frame view's pictures as the lens stage lays it; Auto measures the decode and never a
/// removal; a Light slider builds nothing in the stage; and the model's input is cut from the full-size decode. No model runs:
/// the patches are made here and held in memory. Runs where the CC0 samples are.
@Suite(.serialized, .rawDecodes) struct RemovalSeamTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    /// 7008 by 4672, for the previews; and the same camera's small raw, 3480 by 2320 once trimmed, for the full-size decodes.
    private static let large = samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    private static let small = samples.appendingPathComponent("ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW")
    private static var hasSamples: Bool {
        FileManager.default.fileExists(atPath: large.path) && FileManager.default.fileExists(atPath: small.path)
    }

    /// A folder of the test's own with a copy of `sample` and a toy stock.
    private func scene(_ sample: URL = RemovalSeamTests.large) throws -> (URL, Frame, [Stock]) {
        let folder = try temporaryFolder()
        let raw = folder.appendingPathComponent("frame.ARW")
        try FileManager.default.copyItem(at: sample, to: raw)
        try writeToyStock(id: "toy", in: folder)
        return (folder, Frame(id: 0, url: raw, info: try ARWFrameInfo.read(from: raw)), StockLibrary.load(from: folder).stocks)
    }

    /// A patch over `box` of the full-size decode: light far brighter than the scene's, so it shows in any picture, mixed in over
    /// the box's middle with a soft rim; the object's alpha is the smaller.
    private func patch(x: Int, y: Int, width: Int, height: Int, light: Float16 = 6) throws -> RemovalPatch {
        let (wide, high) = (64, 48)
        var rgb = [Float16](repeating: 0, count: wide * high * 3)
        for i in rgb.indices { rgb[i] = light * Float16(1 + Float(i % 7) / 16) }
        func disc(_ inner: Double, _ outer: Double) -> [UInt8] {
            (0..<(wide * high)).map { i in
                let d = hypot((Double(i % wide) + 0.5) / Double(wide) - 0.5, (Double(i / wide) + 0.5) / Double(high) - 0.5)
                return UInt8((255 * min(1, max(0, (outer - d) / (outer - inner)))).rounded())
            }
        }
        return try RemovalPatch(box: RemovalPatch.Box(x: x, y: y, width: width, height: height), width: wide, height: high, rgb: rgb,
                                objectAlpha: disc(0.15, 0.25), effectsAlpha: disc(0.25, 0.42))
    }

    private func develop(_ removals: [Removal], lens arguments: String = "default", exposure: Float = 0) throws -> DevelopSettings {
        let adjustments = try ManualAdjustments(exposureEV: exposure).settingLens(LensSettings(arguments: arguments)).settingRemovals(removals)
        return DevelopSettings(manual: try ManualRenderSettings(adjustments: adjustments, referenceStops: 0))
    }

    private func bytes(_ image: CGImage) throws -> Data { try #require(image.dataProvider?.data as Data?) }

    /// `frame`'s red, green and blue over `box`, the picture's top row first: a crop as the model is given it.
    private func cut(_ frame: LinearFrame, _ box: RemovalPatch.Box) -> [Float16] {
        let pixels = ExposureAnalyzer.pixels(of: frame.texture)
        var out = [Float16]()
        out.reserveCapacity(box.width * box.height * 3)
        for y in box.y..<(box.y + box.height) {
            let row = (frame.height - 1 - y) * frame.width
            for x in box.x..<(box.x + box.width) { out += pixels[(row + x) * 4..<(row + x) * 4 + 3] }
        }
        return out
    }

    // MARK: keys

    @Test(.enabled(if: RemovalSeamTests.hasSamples))
    func aRemovalThatIsOnNamesTheDecodeAndOneThatIsOffDoesNot() throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try patch(x: 2600, y: 1500, width: 1600, height: 1200), second = try patch(x: 900, y: 700, width: 800, height: 600, light: 3)
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple), patches: FixedPatchSource([first, second]))
        let a = Removal(patch: first.ref), b = Removal(patch: second.ref)
        for arguments in ["default", "distortion=off", "distortion-amount=140", "vignette=40", "defringe-purple=8"] {
            let values = try LensSettings(arguments: arguments)
            let key = films.key(frame, lens: values)
            let lens = try #require(films.lensCorrection(for: frame, settings: values))
            #expect(key.hasSuffix("|" + lens.digest) && !key.contains("+remove-"))
            // On: the same key with the removals' digest after it, so the decode before it is the same family of pictures.
            let on = try values.settingRemovals([a, b]), digest = try #require([a, b].renderDigest)
            #expect(films.key(frame, lens: on) == key + "+remove-" + digest)
            #expect(films.lensCorrection(for: frame, settings: on)?.removals == [a, b])
            // Off: the key of the frame with nothing removed, which the cache may still hold.
            #expect(films.key(frame, lens: try values.settingRemovals([a.setting(isOn: false), b.setting(isOn: false)])) == key)
            #expect(films.key(frame, lens: try values.settingRemovals([a.setting(isOn: false), b])) == films.key(frame, lens: try values.settingRemovals([b])))
            // The order and each one's alpha are what the stage composites, so each is a key of its own.
            let others = [[a], [b], [b, a], [a.setting(includesEffects: false), b]]
            let keys = try others.map { films.key(frame, lens: try values.settingRemovals($0)) } + [key, films.key(frame, lens: on)]
            #expect(Set(keys).count == keys.count)
            // The render graph's version follows the same digest.
            let settings = try develop([a, b], lens: arguments), plain = try develop([], lens: arguments)
            let removed = try #require(films.lensCorrection(for: frame, settings: on))
            #expect(RenderGraph.version(for: settings, lens: removed) == RenderGraph.version(for: settings, lens: lens) + "+remove-" + digest)
            #expect(RenderGraph.version(for: settings, lens: removed) != RenderGraph.version(for: plain, lens: lens))
            let hidden = try develop([a.setting(isOn: false), b.setting(isOn: false)], lens: arguments)
            let hiddenLens = try #require(films.lensCorrection(for: frame, settings: hidden.lens))
            #expect(RenderGraph.version(for: hidden, lens: hiddenLens) == RenderGraph.version(for: hidden, lens: lens))
        }
        #expect(films.decodeCount == 0 && films.removalStatistics == (0, 0), "a key decodes nothing and lays nothing")
    }

    // MARK: pictures

    @Test(.enabled(if: RemovalSeamTests.hasSamples))
    func aRemovalReachesTheSheetsAndTheFrameViewsPicturesAsTheStageLaysIt() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let made = try patch(x: 2600, y: 1500, width: 1600, height: 1200), source = FixedPatchSource([made])
        let removals = [Removal(patch: made.ref)]
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple), patches: source)
        let gpu = try GPU(), stage = try LensStage(gpu: gpu, patches: source), decoder = AppleRawDecoder(gpu: gpu, contextPerDecode: true)
        let renderer = try FilmRenderer(gpu: gpu, stock: stocks[0])
        for arguments in ["default", "distortion=off"] {
            let settings = try develop(removals, lens: arguments), plain = try develop([], lens: arguments)
            let lens = LensResolver.correction(for: frame.url, settings: settings.lens)
            #expect(lens.removals == removals && lens.isIdentity == (arguments != "default"))
            // The sheet: its own decode, staged with the removal.
            var options = DecodeOptions()
            options.maxLongSide = FilmPreviews.previewLongSide
            options.lensCorrection = false
            let decoded = try decoder.decode(frame.url, options: options)
            let sheet = try stage.correct(decoded, with: lens)
            let expected = try films.displayImage(renderer.render(sheet, settings: settings).image.texture, space: .displayP3, maxPixelSize: 336)
            let shown = try #require(await films.film(frame, stock: 0, settings: settings, maxPixelSize: 336))
            #expect(try bytes(shown) == bytes(expected), "\(arguments)")
            let without = try #require(await films.film(frame, stock: 0, settings: plain, maxPixelSize: 336))
            #expect(try bytes(shown) != bytes(without), "\(arguments): the removal shows on the sheet")
            // The frame view: the decode it holds is the stage's scene, and its pictures are made from that.
            let pixels = 1201
            let neutral = try #require(await films.frameNeutral(frame, lens: settings.lens, pixels: pixels))
            let held = try #require(films.frameDecode(of: frame, lens: settings.lens, pixels: pixels))
            var frameOptions = FilmPreviews.frameDecodeOptions(longSide: pixels)
            frameOptions.lensCorrection = false
            let input = try decoder.decode(frame.url, options: frameOptions)
            let scene = try stage.correct(input, with: lens)
            #expect(held.lens == lens)
            #expect(ExposureAnalyzer.pixels(of: held.texture) == ExposureAnalyzer.pixels(of: scene.texture), "\(arguments)")
            #expect(ExposureAnalyzer.pixels(of: scene.texture) != ExposureAnalyzer.pixels(of: try stage.correct(input, with: lens.removing([])).texture))
            #expect(try bytes(neutral) == bytes(films.displayImage(scene.texture, space: .displayP3, maxPixelSize: pixels)))
            let film = try #require(await films.frameFilm(frame, stock: 0, settings: settings, pixels: pixels))
            #expect(try bytes(film) == bytes(films.displayImage(renderer.render(scene, settings: settings).image.texture, space: .displayP3, maxPixelSize: pixels)))
            // Hidden, the frame view stages the decode it kept again, and that decode is still the raw's own: the removal went
            // into a copy.
            let hidden = try develop(removals.map { $0.setting(isOn: false) }, lens: arguments)
            let decodes = films.decodeCount
            _ = try #require(await films.frameNeutral(frame, lens: hidden.lens, pixels: pixels))
            let again = try #require(films.frameDecode(of: frame, lens: hidden.lens, pixels: pixels))
            #expect(films.decodeCount == decodes, "\(arguments): no decode for the eye")
            #expect(ExposureAnalyzer.pixels(of: again.texture) == ExposureAnalyzer.pixels(of: try stage.correct(input, with: lens.removing([])).texture),
                    "\(arguments)")
        }
        // A previews given no patches finds none and skips the removal: the frame's own picture.
        let bare = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple))
        let skipped = try #require(await bare.film(frame, stock: 0, settings: try develop(removals), maxPixelSize: 336))
        let own = try #require(await bare.film(frame, stock: 0, settings: try develop([]), maxPixelSize: 336))
        #expect(try bytes(skipped) == bytes(own) && bare.removalStatistics == (0, 0))
    }

    // MARK: Auto

    @Test(.enabled(if: RemovalSeamTests.hasSamples))
    func autoMeasuresTheDecodeAndNeverARemoval() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A third of the frame, eight stops over a mid-gray: Auto would not miss it.
        let made = try patch(x: 1200, y: 600, width: 4600, height: 3400, light: 40)
        let removals = [Removal(patch: made.ref)]
        // What Auto reads of the frame with nothing removed.
        let plain = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple))
        let own = try #require(await plain.film(frame, stock: 0, settings: try develop([]), maxPixelSize: 336))
        let expected = try #require(plain.cachedMeasurement(frame)), descriptor = try #require(plain.cachedDescriptor(frame))
        let workingSpace = try GPU().workingColorSpace

        for arguments in ["default", "distortion=off"] {
            // The first thing asked of the frame is its picture with the removal, so its sheet decode is measured as it is staged
            // with one; with Distortion off the stage's identity path is the one that hands the decode back.
            let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple), patches: FixedPatchSource([made]))
            let removed = try #require(await films.film(frame, stock: 0, settings: try develop(removals, lens: arguments), maxPixelSize: 336))
            #expect(films.removalStatistics == (1, 1) && films.decodeCount == 1)
            if arguments == "default" { #expect(try bytes(removed) != bytes(own), "the removal shows") }
            #expect(films.cachedMeasurement(frame) == expected, "\(arguments)")
            #expect(films.cachedDescriptor(frame) == descriptor, "\(arguments)")
            #expect(await films.measure(frame) == .measured(expected, descriptor), "\(arguments)")
            #expect(await films.analysis(frame) == expected.analysis && films.decodeCount == 1, "\(arguments)")
            // The picture itself is another frame to a meter: measured, the staged scene would read brighter.
            let lens = try develop(removals, lens: arguments).lens
            _ = try #require(await films.frameNeutral(frame, lens: lens, pixels: FilmPreviews.previewLongSide))
            let scene = try #require(films.frameDecode(of: frame, lens: lens, pixels: FilmPreviews.previewLongSide))
            let seen = ExposureAnalyzer.measure(scene, workingSpace: workingSpace, info: frame.info)
            #expect(seen.analysis != expected.analysis, "\(arguments): the removal is large enough to move a measurement")
            #expect(films.cachedMeasurement(frame) == expected, "\(arguments)")
        }
    }

    // MARK: sliders

    @Test(.enabled(if: RemovalSeamTests.hasSamples))
    func aLightSliderBuildsNothingInTheStageAndALensSliderLaysTheKeptPatchAgain() async throws {
        let (folder, frame, stocks) = try scene()
        defer { try? FileManager.default.removeItem(at: folder) }
        let made = try patch(x: 2600, y: 1500, width: 1600, height: 1200), removals = [Removal(patch: made.ref)]
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple), patches: FixedPatchSource([made]))
        let side = 1000, lens = try develop(removals).lens
        let first = try #require(await films.frameFilm(frame, stock: 0, settings: try develop(removals), pixels: side))
        let staged = try #require(films.frameDecode(of: frame, lens: lens, pixels: side))
        let built = films.removalStatistics, decodes = films.decodeCount, held = films.heldBytes
        #expect(built == (1, 1) && decodes == 1)
        // What is held is what a previews with no patch holds of the same frame, and the patch with its chain: 4095 texels, ten
        // bytes each. The develop's gate counts it.
        let bare = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple))
        _ = try #require(await bare.frameFilm(frame, stock: 0, settings: try develop(removals), pixels: side))
        #expect(held == bare.heldBytes + 40_950)
        // A drag of Exposure: each value is another film from the scene already staged.
        var pictures = [try bytes(first)]
        for exposure in stride(from: Float(-1), through: 1, by: 0.25) where exposure != 0 {
            let film = try #require(await films.frameFilm(frame, stock: 0, settings: try develop(removals, exposure: exposure), pixels: side))
            pictures.append(try bytes(film))
            #expect(films.removalStatistics == built && films.decodeCount == decodes, "exposure \(exposure)")
            #expect(films.frameDecode(of: frame, lens: lens, pixels: side)?.image === staged.image, "exposure \(exposure)")
        }
        #expect(Set(pictures).count == pictures.count, "each value made a picture of its own")
        // The sheet's picture of the same frame comes down from that scene too.
        _ = try #require(await films.film(frame, stock: 0, settings: try develop(removals, exposure: 0.5), maxPixelSize: 336, frameViewSide: side))
        #expect(films.removalStatistics == built)

        // A drag of Distortion's amount stages the kept decode again: the patch is laid each time, and uploaded never.
        for (index, amount) in [110, 120, 130, 140].enumerated() {
            let settings = try develop(removals, lens: "distortion-amount=\(amount)")
            _ = try #require(await films.frameFilm(frame, stock: 0, settings: settings, pixels: side))
            #expect(films.removalStatistics == (built.uploads, built.composites + index + 1) && films.decodeCount == decodes)
            #expect(films.frameDecode(of: frame, lens: settings.lens, pixels: side)?.lens?.removals == removals)
        }
        // While a develop runs the stage keeps half as much of patches, as the masks' caches do; its trim lets the texture go
        // with the rest.
        #expect(films.keptPatchLimit == LensStage.defaultKeptPatchBytes)
        films.isDevelopRunning = true
        #expect(films.keptPatchLimit == FilmPreviews.developPatchBytes && FilmPreviews.developPatchBytes == 64 << 20)
        films.isDevelopRunning = false
        #expect(films.keptPatchLimit == LensStage.defaultKeptPatchBytes)
        films.trimForDevelop()
        #expect(films.heldBytes == 0)
        try films.prepareStocks()
        _ = try #require(await films.frameFilm(frame, stock: 0, settings: try develop(removals), pixels: side))
        #expect(films.removalStatistics.uploads == built.uploads + 1, "uploaded again after the trim")
    }

    // MARK: the model's input

    @Test(.enabled(if: RemovalSeamTests.hasSamples))
    func theModelsInputIsCutFromTheFullSizeDecodeWithTheEarlierRemovalsLaid() async throws {
        let (folder, frame, stocks) = try scene(Self.small)
        defer { try? FileManager.default.removeItem(at: folder) }
        let made = try patch(x: 1000, y: 700, width: 900, height: 700), source = FixedPatchSource([made])
        let removals = [Removal(patch: made.ref)]
        let films = try FilmPreviews(stocks: stocks, decoderChoices: DecoderChoices(route: .apple), patches: source)
        let notes = Notes()
        films.observeWork = { notes.add($0) }
        // The develop's own decode of the frame: whole, in its tiles, with no lens correction.
        let gpu = try GPU(), stage = try LensStage(gpu: gpu, patches: source)
        var options = DecodeOptions()
        options.tileSize = RollDeveloper.decodeTile
        options.learnedTileSize = RollDeveloper.learnedDecodeTile
        options.lensCorrection = false
        let decoded = try AppleRawDecoder(gpu: gpu, contextPerDecode: true).decode(frame.url, options: options)
        #expect(decoded.scale == 1 && LensStage.isFullSize(decoded))
        let before = ExposureAnalyzer.pixels(of: decoded.texture)

        // With nothing removed, the decode's own pixels over the box, whatever the lens values.
        let box = try RemovalPatch.Box(x: 1300, y: 800, width: 700, height: 520)
        let plain = try await films.removalInput(frame, lens: try LensSettings(arguments: "distortion-amount=150,vignette=30"), box: box)
        #expect(plain.box == box && plain.decoder == decoded.decoderVersion)
        #expect(plain.rgb == cut(decoded, box))
        #expect(notes.count("removal-input-decode \(frame.name) +") == 1, "no decode is held, so one is made")
        // With an earlier removal, the stage's composite of it over that decode, and one that is off is not there.
        let removed = try await films.removalInput(frame, lens: try LensSettings.default.settingRemovals(removals), box: box)
        #expect(removed.rgb == (try stage.removalInput(decoded, removals: removals, box: box)))
        #expect(removed.rgb != plain.rgb, "the earlier removal is in the crop")
        #expect(ExposureAnalyzer.pixels(of: decoded.texture) == before)
        let hidden = try await films.removalInput(frame, lens: try LensSettings.default.settingRemovals(removals.map { $0.setting(isOn: false) }), box: box)
        #expect(hidden == plain)
        #expect(notes.count("removal-input-decode \(frame.name) +") == 3 && films.removalStatistics == (1, 1))

        // The frame view at 100 % holds the whole raw's decode: the input is cut from it, and it is left as it was.
        let flat = try LensSettings(arguments: "distortion=off")
        await films.holdFrameDecode(frame, lens: flat, pixels: 8000)
        let held = try #require(films.frameDecode(of: frame, lens: flat, pixels: 8000))
        #expect(held.width == decoded.width && held.height == decoded.height && held.lens?.isIdentity == true)
        let whole = ExposureAnalyzer.pixels(of: held.texture)
        let unstaged = LinearFrame(image: held.image, decoderVersion: held.decoderVersion, scale: held.scale, pins: held.pins, picture: held.picture)
        let fromHeld = try await films.removalInput(frame, lens: .default, box: box)
        #expect(fromHeld.rgb == cut(unstaged, box) && fromHeld.decoder == held.decoderVersion)
        let laid = try await films.removalInput(frame, lens: try flat.settingRemovals(removals), box: box)
        #expect(laid.rgb == (try stage.removalInput(unstaged, removals: removals, box: box)) && laid.rgb != fromHeld.rgb)
        #expect(notes.count("removal-input-decode \(frame.name) +") == 3, "the held decode served both")
        #expect(notes.count("removal-input \(frame.name) +") == 5 && notes.count("removal-input \(frame.name) -") == 5)
        #expect(ExposureAnalyzer.pixels(of: held.texture) == whole, "the frame view's decode is left as it was")

        // What it refuses.
        await #expect(throws: RemovalError.invalid("a removal's input lies inside the frame")) {
            try await films.removalInput(frame, lens: .default, box: try RemovalPatch.Box(x: 3000, y: 2000, width: 700, height: 520))
        }
        let gone = Frame(id: 1, url: folder.appendingPathComponent("gone.ARW"), info: frame.info)
        await #expect(throws: RemovalError.invalid("the raw cannot be read")) { try await films.removalInput(gone, lens: .default, box: box) }
    }
}

/// What the previews said they did (`FilmPreviews.observeWork`), from whichever thread.
private final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    func add(_ note: String) { lock.withLock { said.append(note) } }
    func count(_ note: String) -> Int { lock.withLock { said.filter { $0 == note }.count } }
}
