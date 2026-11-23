import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import ArgentRoll

private func toyStock() throws -> Stock {
    Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
}

private func frame(_ name: String = "DSC00601.ARW", in folder: URL? = nil) -> Frame {
    let folder = folder ?? URL(fileURLWithPath: "/tmp/roll")
    return Frame(id: 0, url: folder.appendingPathComponent(name),
                 info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1_697_732_028.776)))
}

/// The pins this build records for a full-size decode.
private func pins() -> DecodePins {
    DecodePins(version: DecodePins.currentVersion, decoderVersion: "8", baselineExposure: 0, shadowBias: 0, sharpness: 0,
               boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true, extendedDynamicRange: 1,
               neutralChromaticity: .init(x: 0.33, y: 0.35), moireReduction: 1, contrast: 0, detail: 0,
               anchorDecodedMidTone: 0.08, anchorVersion: "1", exposureGainStops: 1, luminanceNoiseReduction: 0.4,
               colorNoiseReduction: 0.5, lensCorrection: true, scale: 1, draftMode: false)
}

@Suite struct RecipeTests {
    private func receipt(date: Date, render: Recipe.Render) -> Recipe.Develop {
        .init(date: date, software: "Argent synthetic receipt", output: OutputSettings(),
              file: "/tmp/synthetic.jpg", width: 10, height: 10, render: render, decode: pins(),
              readback: nil, stockDigest: "synthetic", renderVersion: RenderGraph.version(for: render.settings))
    }

    @Test func millisecondReceiptDatesKeepTheirIdentityAcrossRepeatedRecipeRoundTrips() throws {
        let stock = try toyStock()
        let cases: [(Double, String)] = [
            (1_700_000_000.002, "2023-11-14T22:13:20.002Z"),
            (1_700_000_000.005, "2023-11-14T22:13:20.005Z"),
            (1_700_000_000.009, "2023-11-14T22:13:20.009Z"),
            (-0.002, "1969-12-31T23:59:59.998Z"),
            (-0.0004, "1970-01-01T00:00:00.000Z"),
            (0.9996, "1970-01-01T00:00:01.000Z")
        ]
        for (seconds, timestamp) in cases {
            var recipe = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest,
                                roll: RollControls(), own: FrameControls())
            let original = receipt(date: Date(timeIntervalSince1970: seconds), render: recipe.render)
            recipe.develops = [original]
            for cycle in 0..<5 {
                let data = try recipe.encoded()
                let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let develops = try #require(json["develops"] as? [[String: Any]])
                #expect(develops[0]["date"] as? String == timestamp, "\(seconds), cycle \(cycle)")
                recipe = try Recipe.decodeStrict(data)
                #expect(Recipe.sameDevelopReceipt(original, recipe.develops[0]), "\(seconds), cycle \(cycle)")
            }
        }
    }

    @Test func receiptIdentityKeepsAdjacentMillisecondsAndOtherFieldsDistinct() throws {
        let stock = try toyStock()
        let recipe = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls())
        let original = receipt(date: Date(timeIntervalSince1970: 1_700_000_000.002), render: recipe.render)
        var adjacent = original
        adjacent.date = Date(timeIntervalSince1970: 1_700_000_000.003)
        #expect(!Recipe.sameDevelopReceipt(original, adjacent))
        var altered = original
        altered.software = "another exporter"
        #expect(!Recipe.sameDevelopReceipt(original, altered))
        altered = original
        altered.width += 1
        #expect(!Recipe.sameDevelopReceipt(original, altered))
        altered = original
        altered.render.printExposure = 0.1
        #expect(!Recipe.sameDevelopReceipt(original, altered))
    }

    @Test func anOutOfRangeDateCannotTrapEncodingOrMatchAReceipt() throws {
        let stock = try toyStock()
        var recipe = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls())
        let valid = receipt(date: Date(timeIntervalSince1970: 1_700_000_000.002), render: recipe.render)
        let invalid = receipt(date: Date(timeIntervalSince1970: 1e20), render: recipe.render)
        #expect(!Recipe.sameDevelopReceipt(valid, invalid))
        #expect(!Recipe.sameDevelopReceipt(invalid, invalid))
        recipe.develops = [invalid]
        #expect(throws: EncodingError.self) { try recipe.encoded() }
    }

    @Test func changingLegacyControlsAndReplayingAnExportKeepsExactlyTwoReceipts() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = frame("synthetic.ARW", in: root), stock = try toyStock()
        try Data([1, 2, 3]).write(to: raw.url)
        let writer = RecipeWriter(digests: SourceDigests(settle: 0)), library = root.appendingPathComponent("library")
        let output = root.appendingPathComponent("synthetic.jpg")
        try Data("synthetic image".utf8).write(to: output)
        let warm = Recipe(frame: raw, byteCount: 3, stock: stock, stockDigest: stock.digest,
                          roll: RollControls(), own: FrameControls(labBalance: .warm))
        var exported = try await writer.commit(recipe: warm, for: raw, library: library)
        var first = receipt(date: Date(timeIntervalSince1970: 1_700_000_000.009), render: exported.render)
        first.file = output.path
        first.stockDigest = stock.digest
        first.outputSource = SourceStamp.of(output)
        exported.develops.append(first)
        _ = try await writer.mergeExport(recipe: exported, for: raw, library: library)
        let loaded = try #require(try await writer.load(for: raw, library: library))
        #expect(loaded.develops.count == 1)
        let cool = Recipe(frame: raw, byteCount: 3, stock: stock, stockDigest: stock.digest,
                          roll: RollControls(), own: FrameControls(labBalance: .cool), previous: loaded)
        var second = try await writer.commit(recipe: cool, for: raw, library: library)
        var next = first
        next.date = Date(timeIntervalSince1970: 1_700_000_010.009)
        next.render = second.render
        second.develops.append(next)
        let saved = try await writer.mergeExport(recipe: second, for: raw, library: library)
        #expect(saved.develops.count == 2)
        let replayed = try await writer.mergeExport(recipe: second, for: raw, library: library)
        #expect(replayed.develops.count == 2)
        #expect(replayed.frame == FrameControls(labBalance: .cool))
        #expect(replayed.render == second.render)
    }

    @Test func previousAnalysisWithFaceSkinRoundTripsButIsNotRestoredAsCurrent() throws {
        let literal = Data(#"{"version":"2026-10-07-4","meanStops":3,"validWeight":1,"histogram":[],"grayEstimate":[0.2,0,-0.2],"faces":[{"box":[0.4,0.3,0.2,0.3],"levelStops":0,"area":0.04,"skin":[0.3,0.2,0.1],"skinArea":0.028}]}"#.utf8)
        let oldAnalysis = try JSONDecoder().decode(ExposureAnalysis.self, from: literal)
        #expect(!oldAnalysis.isCurrent)
        let stock = try toyStock(), oldFrame = frame(), currentFrame = frame("current.ARW")
        let recipe = Recipe(frame: oldFrame, byteCount: 1, stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls(), analysis: oldAnalysis)
        let read = try Recipe.decodeStrict(recipe.encoded())
        #expect(read == recipe && read.analysis == oldAnalysis)
        #expect(read.analysis?.faces.first?.skin == [0.3, 0.2, 0.1])
        #expect(read.analysis?.faces.first?.skinArea == 0.028)
        let currentAnalysis = ExposureAnalysis(meanStops: 0.2, validWeight: 1)
        let current = Recipe(frame: currentFrame, byteCount: 1, stock: stock, stockDigest: stock.digest,
                             roll: RollControls(), own: FrameControls(), analysis: currentAnalysis)
        #expect(RestoredRoll(frames: [oldFrame, currentFrame], recipes: [read, current]).analyses == [currentFrame.url: currentAnalysis])
    }

    @Test func changedLiveAutoRenderDoesNotResumeAnOlderPrint() throws {
        let stock = try toyStock(), raw = frame(), file = URL(fileURLWithPath: "/tmp/out/DSC00601.jpg")
        let face = FaceMeasure(box: [0.4, 0.3, 0.2, 0.3], levelStops: 0, area: 0.04)
        let current = ExposureAnalysis(meanStops: 3, validWeight: 1, faces: [face])
        var old = try Recipe.make(frame: raw, byteCount: 1, stock: stock, stockDigest: stock.digest,
            roll: RollControls(), own: FrameControls(), aim: PrintAim(level: 1.5))
        old.develops.append(.init(date: Date(), software: "Argent before face fix", output: OutputSettings(),
            file: file.path, width: 10, height: 10, render: old.render, decode: pins(), readback: nil,
            stockDigest: stock.digest, renderVersion: RenderGraph.version(for: old.render.settings)))
        #expect(old.lastDevelopMatches(file: file, output: OutputSettings()))
        let refreshed = try Recipe.make(frame: raw, byteCount: 1, stock: stock, stockDigest: stock.digest,
            roll: RollControls(), own: FrameControls(), analysis: current, previous: old)
        #expect(abs(try #require(refreshed.printLevel) - AutoPrint.levelStops(current)) < 1e-5)
        #expect(AutoPrint.levelStops(current) != 1.5)
        #expect(refreshed.render != old.render && refreshed.develops == old.develops)
        #expect(!refreshed.lastDevelopMatches(file: file, output: OutputSettings()))
    }

    @Test func roundTripsAndRefusesWhatItCannotRead() throws {
        let stock = try toyStock()
        var recipe = Recipe(frame: frame(), byteCount: 1234, stock: stock, stockDigest: stock.digest,
                            roll: RollControls(ratedAt: .oneStopUnder), own: FrameControls(labBalance: .warm),
                            analysis: ExposureAnalysis(meanStops: -0.4, validWeight: 0.9))
        recipe.raw.sha256 = "abc"
        let data = try recipe.encoded()
        #expect(Recipe.decoded(data) == recipe)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"format\" : \"camera.argent.recipe\""))

        var future = recipe
        future.version = Recipe.currentVersion + 1
        #expect(Recipe.decoded(try future.encoded()) == nil)
        var other = recipe
        other.format = "something.else"
        #expect(Recipe.decoded(try other.encoded()) == nil)
        #expect(Recipe.decoded(Data("{}".utf8)) == nil)
    }

    /// A re-bake that changes only the grain or the halation changes the stock's digest, so its
    /// frames develop again (found in review); a stock without either hashes as before.
    @Test func theDigestCoversGrainAndHalation() throws {
        let base = try toyStock()
        func stock(grain: GrainTable?, halation: Stock.Halation?) -> Stock {
            Stock(id: base.id, displayName: base.displayName, status: base.status, boxSpeed: base.boxSpeed,
                  densityRange: base.densityRange, exposurePerUnit: base.exposurePerUnit, negative: base.negative,
                  print: base.print, grain: grain, halation: halation)
        }
        let grain = GrainTable(amounts: [[0, 0, 0], [1, 1, 1]], sigma48: [[0.002, 0.003, 0.006], [0.002, 0.003, 0.006]])
        let coarser = GrainTable(amounts: grain.amounts, sigma48: [[0.002, 0.004, 0.006], [0.002, 0.003, 0.006]])
        let halation = Stock.Halation(strength: 0.015, greenShare: 0.25, radiusMicrometres: 180)
        let stronger = Stock.Halation(strength: 0.02, greenShare: 0.25, radiusMicrometres: 180)
        let digests = [stock(grain: nil, halation: nil), stock(grain: grain, halation: nil), stock(grain: coarser, halation: nil),
                       stock(grain: grain, halation: halation), stock(grain: grain, halation: stronger)].map(\.digest)
        #expect(Set(digests).count == digests.count)
        #expect(digests[0] == base.digest)
        #expect(stock(grain: grain, halation: halation).digest == digests[3])
    }

    /// A stock's name is not a render setting. Renaming the six, to Argent's own names on
    /// 2026-10-07 and back to the films' names since, leaves each digest as it was, so a roll
    /// developed under the old name is not developed again; a sidecar written under the old name
    /// ("Studio 400") still reads, restores its stock by id, and the next recipe keeps its develop
    /// record and writes the new name.
    @Test func aRenamedStockKeepsItsDigestAndRecipesWrittenBeforeStillMatch() throws {
        let base = try toyStock()
        func named(_ name: String, film: String? = nil) -> Stock {
            Stock(id: "kodak-portra-400", displayName: name, modelledFilm: film, status: "datasheet", boxSpeed: base.boxSpeed,
                  densityRange: base.densityRange, exposurePerUnit: base.exposurePerUnit, negative: base.negative,
                  print: base.print)
        }
        let before = named("Studio 400", film: "Kodak Portra 400"), after = named("Portra 400", film: "Kodak Portra 400")
        #expect(after.digest == before.digest)

        let file = URL(fileURLWithPath: "/tmp/out/DSC00601.jpg")
        var old = Recipe(frame: frame(), byteCount: 1, stock: before, stockDigest: before.digest, roll: RollControls(),
                         own: FrameControls(), grain: .natural, sharpen: true)
        old.develops.append(.init(date: Date(), software: "Argent", output: OutputSettings(), file: file.path,
                                  width: 10, height: 10, render: old.render, decode: pins(), readback: nil,
                                  stockDigest: before.digest, renderVersion: RenderGraph.version))
        let text = try #require(String(data: try old.encoded(), encoding: .utf8))
        #expect(text.contains("\"displayName\" : \"Studio 400\""))

        let read = try #require(Recipe.decoded(Data(text.utf8)))
        #expect(read.stock.displayName == "Studio 400" && read.lastDevelopMatches(file: file, output: OutputSettings()))
        #expect(RestoredRoll(frames: [frame()], recipes: [read]).stockID == "kodak-portra-400")
        let next = Recipe(frame: frame(), byteCount: 1, stock: after, stockDigest: after.digest, roll: read.roll,
                          own: read.frame, grain: .natural, sharpen: true, previous: read)
        #expect(next.stock.displayName == "Portra 400" && next.develops == read.develops)
        #expect(next.lastDevelopMatches(file: file, output: OutputSettings()))
    }

    /// Develops recorded before grain existed had none; they read as Off.
    @Test func olderOutputSettingsReadAsWithoutGrain() throws {
        let old = Data(#"{"format":"jpeg","size":0,"space":"sRGB"}"#.utf8)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: old)
        #expect(decoded.grain == .off && decoded.format == .jpeg)
        #expect(OutputSettings().grain == .natural)
        let stock = try toyStock()
        let recipe = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(),
                            own: FrameControls(), grain: .natural)
        #expect(recipe.render.grain == "natural" && recipe.render.settings.grain == 1)
        #expect(recipe.render.settings.grainSeed == frame().grainSeed)
    }

    /// The app's develops have capture sharpening and their recipes say so; a recipe written
    /// before it existed still reads, as a develop without it, and is developed again.
    @Test func recordsSharpeningAndReadsOlderRecipesAsWithout() throws {
        let stock = try toyStock()
        var recipe = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(),
                            own: FrameControls(), grain: .natural, sharpen: true)
        #expect(recipe.render.sharpen == "on" && recipe.render.settings.sharpen)
        #expect(Recipe.decoded(try recipe.encoded()) == recipe)

        var older = recipe
        older.render.sharpen = nil
        let text = try #require(String(data: try older.encoded(), encoding: .utf8))
        #expect(!text.contains("sharpen"))
        let read = try #require(Recipe.decoded(Data(text.utf8)))
        #expect(read.render.sharpen == nil && !read.render.settings.sharpen)

        let file = URL(fileURLWithPath: "/tmp/out/DSC00601.jpg")
        recipe.develops.append(.init(date: Date(), software: "Argent", output: OutputSettings(), file: file.path,
                                     width: 10, height: 10, render: read.render, decode: nil, readback: nil,
                                     stockDigest: stock.digest, renderVersion: RenderGraph.version))
        recipe.develops[0].decode = pins()
        #expect(!recipe.lastDevelopMatches(file: file, output: OutputSettings()))
        recipe.develops[0].render = recipe.render
        #expect(recipe.lastDevelopMatches(file: file, output: OutputSettings()))
    }

    /// The render settings are the controls resolved for the stock, the frame's own on top of
    /// the roll's, as the sheet renders them.
    @Test func resolvesTheFramesControlsOverTheRolls() throws {
        let stock = try toyStock()
        let roll = RollControls(ratedAt: .oneStopUnder, labBalance: .neutral)
        let own = FrameControls(labBalance: .warm)
        let recipe = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest, roll: roll, own: own)
        #expect(recipe.render.settings == RollControls(ratedAt: .oneStopUnder, labBalance: .warm).settings(for: stock))
        #expect(recipe.render.grain == "off" && recipe.render.halation == "off")
        #expect(recipe.roll == roll && recipe.frame == own && recipe.stock.id == "toy")
    }

    @Test func aDevelopIsSkippedOnlyForTheSameFileSettingsStockAndDecoder() throws {
        let stock = try toyStock()
        var recipe = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls())
        let file = URL(fileURLWithPath: "/tmp/out/DSC00601.jpg")
        #expect(!recipe.lastDevelopMatches(file: file, output: OutputSettings()))
        let pins = DecodePins(version: DecodePins.currentVersion, decoderVersion: "8", baselineExposure: 0, shadowBias: 0,
                              sharpness: 0, boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true,
                              extendedDynamicRange: 1, neutralChromaticity: .init(x: 0.33, y: 0.35), moireReduction: 1,
                              contrast: 0, detail: 0, anchorDecodedMidTone: 0.08, anchorVersion: "1", exposureGainStops: 1,
                              luminanceNoiseReduction: 0.4, colorNoiseReduction: 0.5, lensCorrection: true, scale: 1,
                              draftMode: false)
        recipe.develops.append(.init(date: Date(), software: "Argent", output: OutputSettings(), file: file.path,
                                     width: 10, height: 10, render: recipe.render, decode: pins, readback: nil,
                                     stockDigest: stock.digest, renderVersion: RenderGraph.version))
        #expect(recipe.lastDevelopMatches(file: file, output: OutputSettings()))
        #expect(!recipe.lastDevelopMatches(file: file, output: OutputSettings(format: .heic)))
        // Another quality makes another JPEG; TIFF has none, so its slider never asks for a develop again.
        #expect(!recipe.lastDevelopMatches(file: file, output: OutputSettings(quality: 80)))
        var tiff = recipe
        tiff.develops[0].output = OutputSettings(format: .tiff16, quality: 40)
        #expect(tiff.lastDevelopMatches(file: file, output: OutputSettings(format: .tiff16)))
        // A develop made smaller, before every develop was full size, is made again.
        var smaller = recipe
        smaller.develops[0].output.size = .longEdge2048
        #expect(!smaller.lastDevelopMatches(file: file, output: OutputSettings()))
        #expect(!recipe.lastDevelopMatches(file: URL(fileURLWithPath: "/tmp/other/DSC00601.jpg"), output: OutputSettings()))
        var rebaked = recipe
        rebaked.stock.digest = "changed"
        #expect(!rebaked.lastDevelopMatches(file: file, output: OutputSettings()))
        // New settings for the frame: the recipe built for this develop carries the old record.
        let warmer = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest,
                            roll: RollControls(labBalance: .warm), own: FrameControls(), previous: recipe)
        #expect(warmer.develops == recipe.develops)
        #expect(!warmer.lastDevelopMatches(file: file, output: OutputSettings()))
        var oldPins = recipe
        oldPins.develops[0].decode?.version = "2020-01-01"
        #expect(!oldPins.lastDevelopMatches(file: file, output: OutputSettings()))
        // A develop from the other decoder is made again (review 4).
        var inHouse = recipe
        inHouse.develops[0].decode?.decoderVersion = InHouseDecoder.version
        #expect(!inHouse.lastDevelopMatches(file: file, output: OutputSettings()))
        #expect(inHouse.lastDevelopMatches(file: file, output: OutputSettings(), decoderVersion: InHouseDecoder.version))
        #expect(!recipe.lastDevelopMatches(file: file, output: OutputSettings(), decoderVersion: InHouseDecoder.version))
        // Apple's made it because the in-house decoder failed on the file: not tried again, until
        // the in-house decoder changes (review 5).
        var fellBack = recipe
        fellBack.develops[0].fallbackFrom = InHouseDecoder.version
        #expect(fellBack.lastDevelopMatches(file: file, output: OutputSettings(), decoderVersion: InHouseDecoder.version))
        #expect(fellBack.lastDevelopMatches(file: file, output: OutputSettings()))
        fellBack.develops[0].fallbackFrom = "argent-1"
        #expect(!fellBack.lastDevelopMatches(file: file, output: OutputSettings(), decoderVersion: InHouseDecoder.version))
        let encoded = try #require(String(data: try recipe.encoded(), encoding: .utf8))
        #expect(!encoded.contains("fallbackFrom"))
        // A develop from another render graph, or from before the graph was recorded, is made again.
        var oldGraph = recipe
        oldGraph.develops[0].renderVersion = "2020-01-01"
        #expect(!oldGraph.lastDevelopMatches(file: file, output: OutputSettings()))
        oldGraph.develops[0].renderVersion = nil
        let text = try #require(String(data: try oldGraph.encoded(), encoding: .utf8))
        #expect(!text.contains("renderVersion"))
        let unrecorded = try #require(Recipe.decoded(Data(text.utf8)))
        #expect(unrecorded.develops[0].renderVersion == nil)
        #expect(!unrecorded.lastDevelopMatches(file: file, output: OutputSettings()))
    }

    @Test func qualityReachesTheEncoderAndOlderSettingsKeepTheirs() throws {
        #expect(OutputSettings().quality == 92)
        #expect(OutputSettings(quality: 75).encoding == .jpeg(quality: 0.75))
        #expect(OutputSettings(format: .heic, quality: 60).encoding == .heic(quality: 0.6))
        #expect(OutputSettings(format: .tiff16, quality: 60).encoding == .tiff16)
        #expect(OutputSettings(quality: 140).quality == 100)
        var low = OutputSettings()
        low.quality = -5
        #expect(low.quality == 0)
        // Settings and develops recorded before the slider were at the format's fixed quality.
        for (format, quality) in [("jpeg", 92), ("heic", 90), ("tiff16", 92)] {
            let json = #"{"grain":"off","size":0,"format":"\#(format)","space":"sRGB"}"#
            let read = try JSONDecoder().decode(OutputSettings.self, from: Data(json.utf8))
            #expect(read.quality == quality, "\(format)")
        }
        let written = try JSONEncoder().encode(OutputSettings(quality: 70))
        #expect(try JSONDecoder().decode(OutputSettings.self, from: written).quality == 70)
    }

    @Test func aReadOnlyRollKeepsItsRecipesInTheLibrary() throws {
        let root = try temporaryFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("roll").path)
            try? FileManager.default.removeItem(at: root)
        }
        let roll = root.appendingPathComponent("roll"), library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        let raw = frame(in: roll)
        try Data("raw".utf8).write(to: raw.url)
        let stock = try toyStock()
        let recipe = Recipe(frame: raw, byteCount: 3, stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls(ratedAt: .oneStopOver))

        #expect(try RecipeStore.write(recipe, for: raw, library: library) == [RecipeStore.besideRaw(raw.url)])
        #expect(RecipeStore.read(for: raw, library: library) == recipe)
        try FileManager.default.removeItem(at: RecipeStore.besideRaw(raw.url))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roll.path)
        let written = try RecipeStore.write(recipe, for: raw, library: library)
        #expect(written == [RecipeStore.inLibrary(raw, byteCount: 3, library: library)])
        #expect(!FileManager.default.fileExists(atPath: RecipeStore.besideRaw(raw.url).path))
        #expect(RecipeStore.read(for: raw, library: library) == recipe)
    }

    @Test func aRollOpensAsItsNewestDevelopLeftIt() throws {
        let stock = try toyStock()
        let a = frame("DSC00601.ARW"), b = frame("DSC00602.ARW"), c = frame("DSC00603.ARW")
        func recipe(_ f: Frame, roll: RollControls, own: FrameControls, developed: Date?, to folder: String) -> Recipe {
            var recipe = Recipe(frame: f, byteCount: 1, stock: stock, stockDigest: stock.digest, roll: roll, own: own)
            if let developed {
                recipe.develops.append(.init(date: developed, software: "Argent", output: OutputSettings(),
                                             file: "\(folder)/\(f.name).jpg", width: 1, height: 1, render: recipe.render,
                                             decode: nil, readback: nil, stockDigest: stock.digest))
            }
            return recipe
        }
        let older = recipe(a, roll: RollControls(ratedAt: .oneStopOver), own: FrameControls(labBalance: .cool),
                           developed: Date(timeIntervalSince1970: 100), to: "/tmp/first")
        let newer = recipe(b, roll: RollControls(ratedAt: .twoStopsUnder, labBalance: .warm), own: FrameControls(),
                           developed: Date(timeIntervalSince1970: 200), to: "/tmp/second")
        var stale = newer
        stale.analysis = ExposureAnalysis(version: "old", meanStops: 1, validWeight: 1)
        var measured = older
        measured.analysis = ExposureAnalysis(meanStops: -0.3, validWeight: 1)
        // A measurement this build makes comes back; one from an older analysis does not.
        #expect(RestoredRoll(frames: [a, b], recipes: [measured, stale]).analyses == [a.url: ExposureAnalysis(meanStops: -0.3, validWeight: 1)])
        let restored = RestoredRoll(frames: [a, b, c], recipes: [older, newer, nil])
        #expect(restored.stockID == "toy")
        #expect(restored.controls == RollControls(ratedAt: .twoStopsUnder, labBalance: .warm))
        #expect(restored.overrides == [a.url: FrameControls(labBalance: .cool)])
        #expect(restored.destination?.path == "/tmp/second")
        #expect(RestoredRoll(frames: [a], recipes: [nil]) == RestoredRoll(frames: [], recipes: []))
    }

    /// A frame through a stock of its own records it as the recipe's stock, the roll's beside it, and its own grain in
    /// the render; the roll reopens on its own stock even when that frame's recipe is the newest.
    @Test func aFrameWithItsOwnStockKeepsTheRollsBesideIt() throws {
        let stock = try toyStock()
        let a = frame("DSC00601.ARW"), b = frame("DSC00602.ARW")
        let own = FrameControls(stock: stock.id, grain: .off)
        var recipe = Recipe(frame: a, byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(), own: own,
                            rollStock: "kodak-portra-400", grain: .natural)
        recipe.editRevision = 2
        #expect(recipe.stock.id == stock.id && recipe.rollStock == "kodak-portra-400")
        #expect(recipe.render.grain == OutputSettings.Grain.off.rawValue)
        let decoded = try Recipe.decodeStrict(recipe.encoded())
        #expect(decoded.frame == own && decoded.rollStock == "kodak-portra-400")
        var follows = Recipe(frame: b, byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(), own: FrameControls(),
                             rollStock: "ignored", grain: .natural)
        follows.editRevision = 1
        // A frame that follows the roll keeps no second id: its stock is the roll's.
        #expect(follows.rollStock == nil && follows.render.grain == OutputSettings.Grain.natural.rawValue)
        let restored = RestoredRoll(frames: [a, b], recipes: [recipe, follows])
        #expect(restored.stockID == "kodak-portra-400")
        #expect(restored.overrides == [a.url: own])
        // A recipe written before frames had their own decodes without them.
        var old = try #require(JSONSerialization.jsonObject(with: follows.encoded()) as? [String: Any])
        old["frame"] = ["labBalance": "warm"]
        let legacy = try Recipe.decodeStrict(JSONSerialization.data(withJSONObject: old))
        #expect(legacy.frame == FrameControls(labBalance: .warm) && legacy.rollStock == nil)
    }

    /// A frame's own grain is the grain its develop records and the next develop compares (`RollDeveloper.output`): a change of the
    /// roll's grain makes again the frames that follow the roll, and skips one whose own grain it does not reach.
    @Test func aFramesOwnGrainIsTheGrainItsDevelopRecordsAndCompares() throws {
        let stock = try toyStock(), file = URL(fileURLWithPath: "/tmp/out/DSC00601.jpg")
        func developed(own: FrameControls, roll grain: OutputSettings.Grain) -> (RollDeveloper.Job, OutputSettings) {
            var recipe = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(), own: own,
                                grain: grain)
            let job = RollDeveloper.Job(frame: frame(), recipe: recipe)
            let output = RollDeveloper.output(OutputSettings(grain: grain), for: job)
            recipe.develops.append(.init(date: Date(), software: "Argent", output: output, file: file.path, width: 10, height: 10,
                                         render: recipe.render, decode: pins(), readback: nil, stockDigest: stock.digest,
                                         renderVersion: RenderGraph.version(for: recipe.render.settings)))
            return (RollDeveloper.Job(frame: frame(), recipe: recipe), output)
        }
        // Its own Off, on a roll at Natural: recorded at Off.
        let (own, recorded) = developed(own: FrameControls(grain: .off), roll: .natural)
        #expect(recorded.grain == .off)
        // The roll goes to Off: the frame's recipe is the same, and its file is skipped.
        var again = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(),
                           own: FrameControls(grain: .off), grain: .off, previous: own.recipe)
        let next = RollDeveloper.Job(frame: frame(), recipe: again)
        #expect(again.render == own.recipe.render)
        #expect(again.lastDevelopMatches(file: file, output: RollDeveloper.output(OutputSettings(grain: .off), for: next)))
        // A frame that follows the roll is made again.
        let (follows, _) = developed(own: FrameControls(), roll: .natural)
        again = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(), own: FrameControls(),
                       grain: .off, previous: follows.recipe)
        #expect(!again.lastDevelopMatches(file: file, output: RollDeveloper.output(OutputSettings(grain: .off),
                                                                                 for: RollDeveloper.Job(frame: frame(), recipe: again))))
    }

    /// A frame's own stock or grain requires recipe version 13, so a build before it refuses the record rather than reopening the
    /// roll on the frame's stock and saving the frame back without them; a frame with neither keeps the version it needed.
    @Test func aFramesOwnStockOrGrainRequiresVersion13() throws {
        let stock = try toyStock()
        let a = frame("DSC00601.ARW")
        let plain = Recipe(frame: a, byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(),
                           own: FrameControls(ratedAt: .oneStopUnder, labBalance: .warm), grain: .natural)
        #expect(plain.requiredVersion < 13 && plain.version == plain.requiredVersion)
        #expect(try Recipe.decodeStrict(plain.encoded(), readerVersion: 12) == plain)
        for own in [FrameControls(stock: stock.id), FrameControls(grain: .off), FrameControls(labBalance: .warm, stock: stock.id, grain: .natural)] {
            var record = Recipe(frame: a, byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(), own: own,
                                rollStock: "kodak-portra-400", grain: .natural)
            #expect(record.requiredVersion == 13 && record.version == 13)
            #expect(try Recipe.decodeStrict(record.encoded()) == record)
            #expect(throws: Recipe.ReadFailure.unsupportedVersion(13)) { try Recipe.decodeStrict(record.encoded(), readerVersion: 12) }
            record.version = 12
            #expect(throws: Recipe.ReadFailure.invalid("a frame's own stock or grain requires recipe version 13")) { try record.validate() }
        }
    }

    /// `toyStock` with halation, which it has none of.
    private func halatingStock() throws -> Stock {
        let base = try toyStock()
        return Stock(id: base.id, displayName: base.displayName, status: base.status, boxSpeed: base.boxSpeed,
                     densityRange: base.densityRange, exposurePerUnit: base.exposurePerUnit, negative: base.negative,
                     print: base.print, halation: Stock.Halation(strength: 0.015, greenShare: 0.25, radiusMicrometres: 180))
    }

    /// A Halation amount requires recipe version 14, a frame's own or a render at any amount but the stock's own, so a build
    /// before the control refuses the record rather than printing it at the stock's. At 100 a record is the one it was, and a
    /// stock without halation takes none of the control.
    @Test func aHalationAmountRequiresVersion14() throws {
        let stock = try halatingStock(), a = frame("DSC00601.ARW")
        func recipe(_ stock: Stock, own: FrameControls = FrameControls(), halation: Int = 100) throws -> Recipe {
            try Recipe.make(frame: a, byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(), own: own,
                            grain: .natural, halation: halation)
        }
        // The stock's own: no amount recorded, no newer version, and a build before the control reads the record.
        let plain = try recipe(stock)
        #expect(plain.render.halation == "on" && plain.render.halationAmount == nil && plain.render.settings.halationAmount == 1)
        #expect(plain.requiredVersion < 13 && plain.version == plain.requiredVersion)
        #expect(try Recipe.decodeStrict(plain.encoded(), readerVersion: 13) == plain)
        // The roll's at another value, a frame's own, and a frame's own none.
        let cases: [(FrameControls, Int, Float)] = [(FrameControls(), 150, 1.5), (FrameControls(halation: 40), 100, 0.4),
                                                    (FrameControls(halation: 0), 150, 0)]
        for (own, roll, amount) in cases {
            var record = try recipe(stock, own: own, halation: roll)
            #expect(record.render.halationAmount == amount && record.render.settings.halationAmount == amount)
            #expect(record.render != plain.render)
            #expect(record.requiredVersion == 14 && record.version == 14)
            #expect(try Recipe.decodeStrict(record.encoded()) == record)
            #expect(throws: Recipe.ReadFailure.unsupportedVersion(14)) { try Recipe.decodeStrict(record.encoded(), readerVersion: 13) }
            record.version = 13
            #expect(throws: Recipe.ReadFailure.invalid("a Halation amount requires recipe version 14")) { try record.validate() }
        }
        // A pin keeps none of the control, which stays live under it.
        let pin = AutomaticBaseline(sourceSHA256: String(repeating: "a", count: 64), stockID: stock.id, stockDigest: stock.digest,
                                    controls: RollControls(), aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
                                    baseRender: try recipe(stock, halation: 150).render)
        #expect(pin.baseRender.halationAmount == nil && pin.baseRender == plain.render)
        // A stock without halation: its render does not move with the control.
        let base = try toyStock(), without = try recipe(base, halation: 150)
        #expect(without.render.halation == "off" && without.render.halationAmount == nil && without.requiredVersion < 13)
        #expect(without.render == (try recipe(base)).render)
        // Output settings saved before the control are at the stock's own, and a value past the range is held to it.
        let saved = try JSONDecoder().decode(OutputSettings.self, from: Data(#"{"grain":"off","size":0,"format":"jpeg","space":"sRGB"}"#.utf8))
        #expect(saved.halation == 100 && OutputSettings(halation: 900).halation == 200 && OutputSettings.halationAmount(-5) == 0)
        // And written only off it, so a record at the stock's own keeps its bytes.
        let written = { try String(decoding: JSONEncoder().encode($0 as OutputSettings), as: UTF8.self) }
        #expect(try !written(OutputSettings()).contains("halation") && written(OutputSettings(halation: 150)).contains(#""halation":150"#))
        #expect(try JSONDecoder().decode(OutputSettings.self, from: JSONEncoder().encode(OutputSettings(halation: 150))).halation == 150)
    }

    /// A frame's own Halation is the one its develop records and the next develop compares, as its own grain is: a change of the
    /// roll's makes again the frames that follow the roll, and skips one whose own it does not reach.
    @Test func aFramesOwnHalationIsTheHalationItsDevelopRecordsAndCompares() throws {
        let stock = try halatingStock(), file = URL(fileURLWithPath: "/tmp/out/DSC00601.jpg")
        func recipe(own: FrameControls, roll halation: Int, previous: Recipe? = nil) -> Recipe {
            Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest, roll: RollControls(), own: own,
                   grain: .natural, halation: halation, previous: previous)
        }
        func output(_ recipe: Recipe, roll halation: Int) -> OutputSettings {
            RollDeveloper.output(OutputSettings(halation: halation), for: RollDeveloper.Job(frame: frame(), recipe: recipe))
        }
        func developed(own: FrameControls, roll halation: Int) -> Recipe {
            var made = recipe(own: own, roll: halation)
            made.develops.append(.init(date: Date(), software: "Argent", output: output(made, roll: halation), file: file.path,
                                       width: 10, height: 10, render: made.render, decode: pins(), readback: nil,
                                       stockDigest: stock.digest, renderVersion: RenderGraph.version(for: made.render.settings)))
            return made
        }
        // Its own 150, on a roll at 100: recorded at 150.
        let own = developed(own: FrameControls(halation: 150), roll: 100)
        #expect(own.develops.last?.output.halation == 150 && own.render.halationAmount == 1.5)
        // The roll goes to 60: the frame's recipe is the same, and its file is skipped.
        var again = recipe(own: FrameControls(halation: 150), roll: 60, previous: own)
        #expect(again.render == own.render)
        #expect(again.lastDevelopMatches(file: file, output: output(again, roll: 60)))
        // A frame that follows the roll is made again.
        let follows = developed(own: FrameControls(), roll: 100)
        again = recipe(own: FrameControls(), roll: 60, previous: follows)
        #expect(again.render != follows.render)
        #expect(!again.lastDevelopMatches(file: file, output: output(again, roll: 60)))
    }

    /// A destination that cannot be written fails every frame at once, before any decode,
    /// with a line that says so.
    @Test func refusesADestinationItCannotWriteBeforeDecoding() async throws {
        let out = try temporaryFolder(), library = try temporaryFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path)
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: library)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
        let stock = try toyStock()
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library)
        // The raw does not exist: a decode would fail with another message.
        let job = RollDeveloper.Job(frame: frame(), recipe: Recipe(frame: frame(), byteCount: 1, stock: stock,
                                                                   stockDigest: stock.digest, roll: RollControls(),
                                                                   own: FrameControls()))
        let outcomes = await developer.develop([job, job], to: out, output: OutputSettings())
        #expect(outcomes == [.failed("Cannot write to \(out.path)"), .failed("Cannot write to \(out.path)")])
    }

    @Test func namesFilesAroundOtherFramesAndForeignFiles() throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let stock = try toyStock()
        let a = frame("DSC00601.ARW", in: URL(fileURLWithPath: "/tmp/card/100MSDCF"))
        let b = frame("DSC00601.ARW", in: URL(fileURLWithPath: "/tmp/card/101MSDCF"))
        let c = frame("DSC00602.ARW", in: URL(fileURLWithPath: "/tmp/card/100MSDCF"))
        // A file nobody developed has c's name; a's own earlier develop has its name.
        try Data().write(to: out.appendingPathComponent("DSC00602.jpg"))
        try Data().write(to: out.appendingPathComponent("DSC00601.jpg"))
        func job(_ f: Frame, ownFile: URL? = nil) -> RollDeveloper.Job {
            var recipe = Recipe(frame: f, byteCount: 1, stock: stock, stockDigest: stock.digest,
                                roll: RollControls(), own: FrameControls())
            if let ownFile {
                recipe.develops.append(.init(date: Date(), software: "Argent", output: OutputSettings(), file: ownFile.path,
                                             width: 1, height: 1, render: recipe.render, decode: nil, readback: nil,
                                             stockDigest: ""))
            }
            return RollDeveloper.Job(frame: f, recipe: recipe)
        }
        let files = RollDeveloper.files(for: [job(a, ownFile: out.appendingPathComponent("DSC00601.jpg")), job(b), job(c)],
                                        in: out, output: OutputSettings())
        #expect(files.map(\.lastPathComponent) == ["DSC00601.jpg", "DSC00601 2.jpg", "DSC00602 2.jpg"])
    }

    /// A develop's file is known by its inode, size and times at its path, not its device, which a
    /// network share mounted again gives anew: on a share mounted again it is still skipped; written
    /// over, it is not.
    @Test func aDevelopOnAShareMountedAgainIsStillSkipped() throws {
        let stock = try toyStock()
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("DSC00601.jpg")
        try Data("developed".utf8).write(to: file)
        var recipe = Recipe(frame: frame(), byteCount: 1, stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls())
        var remounted = try #require(SourceStamp.of(file))
        remounted.device &+= 1
        recipe.develops.append(.init(date: Date(), software: "Argent", output: OutputSettings(), file: file.path,
                                     width: 10, height: 10, render: recipe.render, decode: pins(), readback: nil,
                                     stockDigest: stock.digest, renderVersion: RenderGraph.version(for: recipe.render.settings),
                                     outputSource: remounted))
        #expect(recipe.lastDevelopMatches(file: file, output: OutputSettings()))
        try FileManager.default.removeItem(at: file)
        try Data("another".utf8).write(to: file)
        #expect(!recipe.lastDevelopMatches(file: file, output: OutputSettings()))
    }
}

/// Runs only where the CC0 samples are present. Each develop decodes at full size, about 2 s
/// a frame through RAW 9 (T4, docs/decoder.md) and under 1 s through RAW 8.
@Suite(.serialized, .rawDecodes) struct DevelopSampleTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    private static var hasSamples: Bool {
        FileManager.default.fileExists(atPath: samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW").path)
    }

    /// A roll folder of hard links to the samples (the scan skips symbolic links), so recipes
    /// land in a scratch folder; copies where the scratch folder is on another volume.
    private func roll(_ names: [String]) async throws -> (Roll, URL) {
        let root = try temporaryFolder()
        let folder = root.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            let source = Self.samples.appendingPathComponent(name), link = folder.appendingPathComponent(name)
            do {
                try FileManager.default.linkItem(at: source, to: link)
            } catch {
                try FileManager.default.copyItem(at: source, to: link)
            }
        }
        return (await RollScanner.scan(folder), root)
    }

    private func jobs(_ roll: Roll, _ developer: RollDeveloper, _ stock: Stock, own: FrameControls = FrameControls(),
                      autoRevision: String? = nil) -> [RollDeveloper.Job] {
        roll.frames.map { frame in
            RollDeveloper.Job(frame: frame, recipe: Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url),
                                                           stock: stock, stockDigest: stock.digest,
                                                           roll: RollControls(), own: own, previous: RecipeStore.read(for: frame, library: developer.library)),
                              autoRevision: autoRevision)
        }
    }

    private static func pixels(_ url: URL) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(image.dataProvider?.data as Data?)
    }

    @Test(.enabled(if: DevelopSampleTests.hasSamples))
    func developsSkipsTheSameRecipeAndDevelopsAgainFromTheSidecarAlone() async throws {
        let (roll, root) = try await roll(["ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW",
                                           "ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW"])
        defer { try? FileManager.default.removeItem(at: root) }
        let stock = try toyStock()
        let library = root.appendingPathComponent("library")
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library)
        let out = root.appendingPathComponent("out")
        let output = OutputSettings(format: .jpeg, size: .longEdge2048, space: .sRGB)
        let progress = ProgressLog()
        // The roll's settled Auto decision the jobs print at, which each receipt records.
        let revision = String(repeating: "5", count: 64)

        let first = await developer.develop(jobs(roll, developer, stock, own: FrameControls(labBalance: .warm), autoRevision: revision),
                                            to: out, output: output) { index, outcome in progress.add(index, outcome) }
        let files = first.compactMap(\.file)
        #expect(files.count == 2 && first.allSatisfy { if case .developed = $0 { true } else { false } }, "\(first)")
        #expect(progress.count == 2)
        for (frame, file) in zip(roll.frames, files) {
            let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
            #expect(max(width, height) == 2048)
            let recipe = try #require(RecipeStore.read(for: frame, library: library))
            #expect(FileManager.default.fileExists(atPath: RecipeStore.besideRaw(frame.url).path))
            #expect(recipe.develops.count == 1 && recipe.develops[0].file == file.path)
            #expect(recipe.develops[0].decode?.version == DecodePins.currentVersion)
            #expect(recipe.develops[0].renderVersion == RenderGraph.version(for: recipe.render.settings,
                lens: LensResolver.correction(for: frame.url, settings: .default)))
            #expect(recipe.develops[0].readback != nil && recipe.raw.sha256?.count == 64)
            #expect(recipe.develops[0].autoRevision == revision)
            #expect(recipe.frame == FrameControls(labBalance: .warm))
        }
        // Only the developed images are written to the output folder; no sidecars or partial files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
                == files.map(\.lastPathComponent).sorted())

        // The same develop again finds every file there from the same recipe.
        let modified = try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let second = await developer.develop(jobs(roll, developer, stock, own: FrameControls(labBalance: .warm), autoRevision: revision),
                                             to: out, output: output)
        #expect(second == files.map { .alreadyDeveloped($0) })
        #expect(try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } == modified)

        // A new setting develops every frame again, over its own file.
        let fourth = await developer.develop(jobs(roll, developer, stock, own: FrameControls(labBalance: .cool)),
                                             to: out, output: output)
        #expect(fourth == files.map { .developed($0) })
        #expect(RecipeStore.read(for: roll.frames[0], library: library)?.develops.count == 2)

        // From the sidecar alone, into another folder, the same pixels as its newest develop.
        let refs = try files.map { try Self.pixels($0) }
        let again = root.appendingPathComponent("again")
        let fromSidecar = roll.frames.map { RollDeveloper.Job(frame: $0, recipe: RecipeStore.read(for: $0, library: library)!) }
        let third = await developer.develop(fromSidecar, to: again, output: output)
        #expect(third.count == files.count && third.allSatisfy { if case .developed = $0 { true } else { false } }, "\(third)")
        for (reference, redone) in zip(refs, third.compactMap(\.file)) {
            #expect(try reference == Self.pixels(redone), "\(redone.lastPathComponent)")
        }
        developer.trim()
    }

    /// The print written over the decoded frame's own texture, as a develop writes it, is the
    /// print written to a texture of its own, sample for sample, at full size through each decoder.
    @Test(.enabled(if: DevelopSampleTests.hasSamples))
    func aPrintWrittenOverItsFrameIsTheSame() throws {
        let stock = try toyStock()
        let file = Self.samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
        for route in DecoderRoute.allCases {
            let gpu = try GPU(maxIdlePoolBytes: 0)
            let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: route))
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let settings = DevelopSettings(printExposure: 0.3, grain: 1, grainSeed: 11, halation: true, sharpen: true)
            func samples(inPlace: Bool) throws -> Data {
                try autoreleasepool {
                    let decoded = try decoder.decode(file, options: DecodeOptions())
                    let texture = try renderer.render(decoded, settings: settings, inPlace: inPlace).image.texture
                    var data = Data(count: texture.width * texture.height * 8)
                    data.withUnsafeMutableBytes {
                        texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
                    }
                    return data
                }
            }
            let separate = try samples(inPlace: false)
            #expect(separate.count == 7008 * 4672 * 8)
            #expect(try samples(inPlace: true) == separate, "route \(route)")
        }
    }

    @Test(.enabled(if: DevelopSampleTests.hasSamples))
    func stopsAtFrameBoundaries() async throws {
        let names = ["ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW", "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW",
                     "ILCE-7M4_DSC06675_FullFrame-LossLess-Compressed-Medium.ARW", "ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW",
                     "ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW"]
        let (roll, root) = try await roll(names)
        defer { try? FileManager.default.removeItem(at: root) }
        let stock = try toyStock()
        // Memory enough for both lanes whatever this process holds; the budget's own stop is tested below.
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: root.appendingPathComponent("library"),
                                          memoryTarget: 64 << 30)
        let out = root.appendingPathComponent("out")
        let (decodeStarted, started) = AsyncStream<Void>.makeStream()
        let resumeDecode = DispatchSemaphore(value: 0)
        developer.observeStage = { _, stage, begins in
            if stage == .decode, begins {
                started.yield(())
                resumeDecode.wait()
            }
        }
        let task = Task {
            defer { started.finish() }
            return await developer.develop(jobs(roll, developer, stock), to: out,
                                           output: OutputSettings(size: .longEdge2048))
        }
        // Source verification and durable recipe publication precede decode. Stop at a
        // known frame boundary rather than assume a particular machine reaches it in 150 ms.
        let bothDecoding = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var count = 0
                for await _ in decodeStarted {
                    count += 1
                    if count == RollDeveloper.lanes { return true }
                }
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(15)) } catch { return false }
                return false
            }
            let ready = await group.next() ?? false
            group.cancelAll()
            return ready
        }
        task.cancel()
        for _ in 0..<RollDeveloper.lanes { resumeDecode.signal() }
        let outcomes = await task.value
        #expect(bothDecoding, "Both decode lanes did not start before the bounded wait ended")
        developer.observeStage = nil
        let developed = outcomes.compactMap(\.file)
        // The two frames decoding when the stop came finish; the rest wait for the next develop.
        #expect(developed.count == RollDeveloper.lanes, "\(outcomes)")
        #expect(outcomes.filter { $0 == .stopped }.count == names.count - RollDeveloper.lanes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
                == developed.map(\.lastPathComponent).sorted())

        // The next develop picks up the rest and skips the two already there.
        let rest = await developer.develop(jobs(roll, developer, stock), to: out, output: OutputSettings(size: .longEdge2048))
        #expect(rest.filter { if case .alreadyDeveloped = $0 { true } else { false } }.count == RollDeveloper.lanes)
        #expect(rest.filter { if case .developed = $0 { true } else { false } }.count == names.count - RollDeveloper.lanes)
    }
}

extension DevelopSampleTests {
    /// A develop whose recipe holds masks prints through them: only the developed picture goes to the output folder.
    @Test(.enabled(if: DevelopSampleTests.hasSamples))
    func aFrameWithMasksDevelopsThroughThem() async throws {
        let (roll, root) = try await roll(["ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"])
        defer { try? FileManager.default.removeItem(at: root) }
        let stock = try toyStock(), destination = root.appendingPathComponent("out"), controls = RollControls()
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: root.appendingPathComponent("library"))
        let frame = try #require(roll.frames.first)
        let masks = try MaskSet(masks: [Mask(components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: 0.5))))],
                                             adjustments: try ManualAdjustments(exposureEV: -1))])
        let baseline = AutomaticBaseline(sourceSHA256: try RecipeStore.sha256(of: frame.url), stockID: stock.id, stockDigest: stock.digest, controls: controls,
                                         aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
                                         baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: PrintAim()), grain: .off))
        let recipe = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest, roll: controls,
                                     own: FrameControls(), manual: ManualEdit(adjustments: try ManualAdjustments(masks: masks), baseline: baseline))
        let outcomes = await developer.develop([RollDeveloper.Job(frame: frame, recipe: recipe)], to: destination, output: OutputSettings(size: .longEdge2048))
        #expect(outcomes.count == 1)
        if case .developed = outcomes[0] {} else { Issue.record("\(outcomes)") }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        #expect(written.sorted().map { URL(fileURLWithPath: $0).pathExtension } == ["jpg"], "\(written)")
    }

    @Test(.enabled(if: DevelopSampleTests.hasSamples), arguments: [false, true])
    func aFileAppearingOrChangingDuringEncodeIsPreserved(replacing: Bool) async throws {
        let (roll, root) = try await roll(["ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"])
        defer { try? FileManager.default.removeItem(at: root) }
        let stock = try toyStock(), destination = root.appendingPathComponent("out")
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: root.appendingPathComponent("library"))
        let output = OutputSettings(size: .longEdge2048)
        let frame = try #require(roll.frames.first)
        let file = destination.appendingPathComponent(frame.name).appendingPathExtension("jpg")
        if replacing {
            #expect(await developer.develop(jobs(roll, developer, stock), to: destination, output: output) == [.developed(file)])
        }
        let foreign = Data("a file from another application".utf8)
        developer.observeStage = { _, stage, begins in
            if stage == .encode, begins {
                do { try foreign.write(to: file, options: .atomic) }
                catch { Issue.record("Could not create the competing output: \(error)") }
            }
        }
        let outcomes = await developer.develop(jobs(roll, developer, stock, own: FrameControls(labBalance: .warm)),
                                               to: destination, output: output)
        guard case .failed(let reason) = outcomes[0] else {
            Issue.record("A competing output must be preserved, not replaced")
            return
        }
        #expect(reason.contains(replacing ? "output changed" : "another file took the output name"))
        #expect(try Data(contentsOf: file) == foreign)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy { !$0.contains(".partial-") })
        developer.observeStage = nil

        let resumed = await developer.develop(jobs(roll, developer, stock, own: FrameControls(labBalance: .warm)),
                                               to: destination, output: output)
        let renamed = destination.appendingPathComponent("\(frame.name) 2.jpg")
        #expect(resumed == [.developed(renamed)])
        #expect(try Data(contentsOf: file) == foreign)
        developer.trim()
    }

    @Test(.enabled(if: DevelopSampleTests.hasSamples))
    func aRawReplacedWhileEncodingCannotPublishItsOldPicture() async throws {
        let (roll, root) = try await roll(["ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"])
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = try #require(roll.frames.first)
        let stock = try toyStock(), destination = root.appendingPathComponent("out")
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: root.appendingPathComponent("library"))
        developer.observeStage = { _, stage, begins in
            if stage == .encode, begins {
                // Replace the scratch hard link rather than change the shared CC0 sample's bytes.
                do { try Data("a replacement raw".utf8).write(to: frame.url, options: .atomic) }
                catch { Issue.record("Could not replace the raw during encode: \(error)") }
            }
        }
        let outcomes = await developer.develop(jobs(roll, developer, stock), to: destination, output: OutputSettings(size: .longEdge2048))
        #expect(outcomes == [.failed("\(frame.name): the raw changed while it was developed")])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        developer.trim()
    }

    @Test(.enabled(if: DevelopSampleTests.hasSamples))
    func aWrittenImageWithAFailedRecipeIsReportedAndItsReceiptCanRecover() async throws {
        let (roll, root) = try await roll(["ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"])
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = try #require(roll.frames.first)
        let stock = try toyStock(), destination = root.appendingPathComponent("out"), library = root.appendingPathComponent("library")
        let digests = SourceDigests(settle: 0), writer = RecipeWriter(digests: digests)
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library,
                                          digests: digests, recipeWriter: writer)
        var captured = try #require(jobs(roll, developer, stock).first)
        captured.recipe.editRevision = 1
        captured.recipe.editLineage = "receipt-recovery"
        let job = captured
        developer.observeStage = { _, stage, begins in
            if stage == .encode, begins {
                // Source checks have completed; make only the final working-recipe write fail.
                do { try Data("not a directory".utf8).write(to: library) }
                catch { Issue.record("Could not block the recipe library: \(error)") }
            }
        }
        let output = OutputSettings(size: .longEdge2048)
        let outcomes = await developer.develop([job], to: destination, output: output)
        let file = destination.appendingPathComponent(frame.name).appendingPathExtension("jpg")
        guard case .failed(let reason) = outcomes[0] else {
            Issue.record("A failed recipe write must not claim a complete export")
            return
        }
        #expect(reason.contains("image was written to \(file.path)") && reason.contains("recipe could not be saved"))
        #expect(try !Self.pixels(file).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [file.lastPathComponent])

        developer.observeStage = nil
        try FileManager.default.removeItem(at: library)
        try await writer.flush(library: library)
        let recovered = try #require(try await writer.load(for: frame, library: library))
        #expect(recovered.editRevision == 1 && recovered.develops.count == 1)
        #expect(await developer.develop([RollDeveloper.Job(frame: frame, recipe: recovered)], to: destination, output: output)
                == [.alreadyDeveloped(file)])
        developer.trim()
    }

    /// A budget with room for no frame beside another develops every frame, one at a time, and a stop
    /// leaves the frames still waiting to be let in, with no file of theirs.
    @Test(.enabled(if: DevelopSampleTests.hasSamples))
    func aTightBudgetDevelopsOneFrameAtATimeAndStops() async throws {
        let names = ["ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW", "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW",
                     "ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW"]
        let (roll, root) = try await roll(names)
        defer { try? FileManager.default.removeItem(at: root) }
        let stock = try toyStock()
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: root.appendingPathComponent("library"),
                                          memoryTarget: 1 << 20)
        let inFlight = InFlight()
        developer.observeStage = { index, stage, begins in
            if stage == .decode || stage == .render { inFlight.note(index, begins) }
        }
        let out = root.appendingPathComponent("out")
        let outcomes = await developer.develop(jobs(roll, developer, stock), to: out, output: OutputSettings(size: .longEdge2048))
        #expect(outcomes.allSatisfy { if case .developed = $0 { true } else { false } }, "\(outcomes)")
        #expect(inFlight.most == 1)
        #expect(developer.lastAdmissions.map { $0.admitted == names.count && $0.waited > 0 } == true)

        // Cancel after the first frame is admitted, not after a guessed hashing/decoding delay.
        // Hold its decode until cancellation reaches the waiting operations.
        let again = root.appendingPathComponent("again")
        let (decodeStarted, started) = AsyncStream<Void>.makeStream()
        let resumeDecode = DispatchSemaphore(value: 0)
        developer.observeStage = { _, stage, begins in
            if stage == .decode, begins {
                started.yield(())
                resumeDecode.wait()
            }
        }
        let task = Task {
            defer { started.finish() }
            return await developer.develop(jobs(roll, developer, stock), to: again, output: OutputSettings(size: .longEdge2048))
        }
        for await _ in decodeStarted { break }
        task.cancel()
        resumeDecode.signal()
        let stopped = await task.value
        #expect(stopped.compactMap(\.file).count == 1, "\(stopped)")
        #expect(stopped.filter { $0 == .stopped }.count == names.count - 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: again.path).sorted()
                == stopped.compactMap(\.file).map(\.lastPathComponent).sorted())
    }

    /// A develop at 3000 MiB or above decodes RAW 9 in 2048-pixel tiles, weighs the frame at 2048 in
    /// the memory gate, records 2048 in the receipt's decode pins and reports it on the developer;
    /// an explicit tile at init still wins, RAW 8 keeps 768, and a tile change never redoes a file
    /// already developed.
    @Test(.enabled(if: DevelopSampleTests.hasSamples))
    func aRaisedTargetDevelopsRAW9At2048WeighsAt2048AndRecordsIt() async throws {
        let large = "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"
        let small = "ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW"
        let (roll, root) = try await roll([large, small])
        defer { try? FileManager.default.removeItem(at: root) }
        let raw9Frame = try #require(roll.frames.first { $0.name.contains("Large") })
        let raw8Frame = try #require(roll.frames.first { $0.name.contains("Small") })
        let stock = try toyStock()
        let library = root.appendingPathComponent("library")
        let digests = SourceDigests(settle: 0)
        let writer = RecipeWriter(digests: digests)
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library,
                                          digests: digests, memoryTarget: 2000 << 20, recipeWriter: writer)
        let output = OutputSettings(size: .longEdge2048)

        func makeJob(_ frame: Frame) throws -> RollDeveloper.Job {
            RollDeveloper.Job(frame: frame, recipe: try Recipe.make(
                frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                roll: RollControls(), own: FrameControls(), grain: output.grain, sharpen: true,
                editRevision: 1, editLineage: "tile-test"))
        }

        // Default target (2000 MiB): RAW 9 decodes and weighs at 1024 and records 1024 in the receipt.
        let outDefault = root.appendingPathComponent("out-2000")
        let defaultOutcomes = await developer.develop([try makeJob(raw9Frame)], to: outDefault, output: output, memoryTarget: 2000 << 20)
        guard case .developed(let defaultFile) = defaultOutcomes[0] else { Issue.record("\(defaultOutcomes)"); return }
        let raw9Size = RollDeveloper.pixelSize(of: raw9Frame.url)
        #expect(developer.lastMemoryTarget == 2000 << 20)
        #expect(developer.lastLearnedDecodeTile == 1024)
        #expect(developer.lastWeighedDecodeCost == DevelopBudget.decodeCost(width: raw9Size.width, height: raw9Size.height, decoder: .raw9, tile: 1024))
        let receipt2000 = try #require(try await writer.load(for: raw9Frame, library: library))
        #expect(receipt2000.develops.last?.decode?.tileSize == 1024)

        // Files already developed at 1024 are skipped at 3000 MiB: changing the tile never redoes them.
        let skipped = await developer.develop([RollDeveloper.Job(frame: raw9Frame, recipe: receipt2000)],
                                              to: outDefault, output: output, memoryTarget: 3000 << 20)
        #expect(skipped == [.alreadyDeveloped(defaultFile)])

        // Raised target (3000 MiB) into a new folder on the same developer: RAW 9 decodes and weighs at 2048 and records 2048.
        let outRaised = root.appendingPathComponent("out-3000")
        let raisedOutcomes = await developer.develop([try makeJob(raw9Frame)], to: outRaised, output: output, memoryTarget: 3000 << 20)
        guard case .developed = raisedOutcomes[0] else { Issue.record("\(raisedOutcomes)"); return }
        #expect(developer.lastMemoryTarget == 3000 << 20)
        #expect(developer.lastLearnedDecodeTile == 2048)
        #expect(developer.lastWeighedDecodeCost == DevelopBudget.decodeCost(width: raw9Size.width, height: raw9Size.height, decoder: .raw9, tile: 2048))
        let receipt3000 = try #require(try await writer.load(for: raw9Frame, library: library))
        #expect(receipt3000.develops.last?.decode?.tileSize == 2048)

        // RAW 8 keeps its 768-pixel tile even when the develop's target is raised.
        let raw8Outcomes = await developer.develop([try makeJob(raw8Frame)], to: outRaised, output: output, memoryTarget: 3000 << 20)
        guard case .developed = raw8Outcomes[0] else { Issue.record("\(raw8Outcomes)"); return }
        let raw8Size = RollDeveloper.pixelSize(of: raw8Frame.url)
        #expect(developer.lastWeighedDecodeCost == DevelopBudget.decodeCost(width: raw8Size.width, height: raw8Size.height, decoder: .apple, tile: 768))
        let raw8Receipt = try #require(try await writer.load(for: raw8Frame, library: library))
        #expect(raw8Receipt.develops.last?.decode?.tileSize == 768)

        // An explicit tile at init still wins over the target's rule.
        let pinned = try RollDeveloper(stocks: [stock], software: "Argent test", library: library,
                                       digests: digests, learnedDecodeTile: 1536, memoryTarget: 2000 << 20, recipeWriter: writer)
        let outPinned = root.appendingPathComponent("out-pinned")
        let pinnedOutcomes = await pinned.develop([try makeJob(raw9Frame)], to: outPinned, output: output, memoryTarget: 4000 << 20)
        guard case .developed = pinnedOutcomes[0] else { Issue.record("\(pinnedOutcomes)"); return }
        #expect(pinned.lastLearnedDecodeTile == 1536)
        #expect(pinned.lastWeighedDecodeCost == DevelopBudget.decodeCost(width: raw9Size.width, height: raw9Size.height, decoder: .raw9, tile: 1536))
        let pinnedReceipt = try #require(try await writer.load(for: raw9Frame, library: library))
        #expect(pinnedReceipt.develops.last?.decode?.tileSize == 1536)
        developer.trim()
        pinned.trim()
    }
}

private final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int: Int] = [:]
    private var peak = 0
    func note(_ index: Int, _ begins: Bool) {
        lock.withLock {
            frames[index, default: 0] += begins ? 1 : -1
            if frames[index] == 0 { frames[index] = nil }
            peak = max(peak, frames.count)
        }
    }
    var most: Int { lock.withLock { peak } }
}

@Suite struct DevelopBudgetTests {
    @Test func theTargetIsTheSpecsOrAnEighthOfMemory() {
        #expect(DevelopBudget.target(physicalMemory: 16 << 30) == 2000 << 20)
        #expect(DevelopBudget.target(physicalMemory: 64 << 30) == 2000 << 20)
        #expect(DevelopBudget.target(physicalMemory: 8 << 30) == 1024 << 20)
    }

    @Test func choicesFollowAQuarterOfPhysicalMemory() {
        #expect(DevelopBudget.Choice.default.bytes == nil)
        #expect(DevelopBudget.Choice.gb3.bytes == 3000 << 20)
        #expect(DevelopBudget.Choice.gb4.bytes == 4000 << 20)
        #expect(DevelopBudget.Choice.gb6.bytes == 6000 << 20)
        #expect(DevelopBudget.choices(physicalMemory: 8 << 30) == [.default])
        #expect(DevelopBudget.choices(physicalMemory: 12 << 30) == [.default, .gb3])
        #expect(DevelopBudget.choices(physicalMemory: 16 << 30) == [.default, .gb3, .gb4])
        #expect(DevelopBudget.choices(physicalMemory: 24 << 30) == [.default, .gb3, .gb4, .gb6])
        #expect(DevelopBudget.choices(physicalMemory: 64 << 30) == [.default, .gb3, .gb4, .gb6])
    }

    @Test func budgetPrecedencePrefersOverridesThenChoiceThenDefaultRule() {
        let ram24: UInt64 = 24 << 30
        // Environment override beats UserDefaults override, user choice and default rule.
        #expect(DevelopBudget.resolve(choice: .gb6, environmentOverride: "3500", defaultsOverride: 5000, physicalMemory: ram24)
                == 3500 << 20)
        // UserDefaults override beats user choice and default rule.
        #expect(DevelopBudget.resolve(choice: .gb6, environmentOverride: nil, defaultsOverride: 5000, physicalMemory: ram24)
                == 5000 << 20)
        // Invalid or non-positive overrides fall through to the next source.
        #expect(DevelopBudget.resolve(choice: .gb4, environmentOverride: "0", defaultsOverride: 3200, physicalMemory: ram24)
                == 3200 << 20)
        #expect(DevelopBudget.resolve(choice: .gb4, environmentOverride: "not-a-number", defaultsOverride: -1, physicalMemory: ram24)
                == 4000 << 20)
        #expect(DevelopBudget.resolve(choice: .gb4, environmentOverride: nil, defaultsOverride: true, physicalMemory: ram24)
                == 4000 << 20)
        // User choice beats default rule when offered.
        #expect(DevelopBudget.resolve(choice: .gb3, physicalMemory: 12 << 30) == 3000 << 20)
        #expect(DevelopBudget.resolve(choice: .gb4, physicalMemory: 16 << 30) == 4000 << 20)
        #expect(DevelopBudget.resolve(choice: .gb6, physicalMemory: ram24) == 6000 << 20)
        // Default rule when nothing else is chosen.
        #expect(DevelopBudget.resolve(choice: .default, physicalMemory: 8 << 30) == 1024 << 20)
        #expect(DevelopBudget.resolve(choice: .default, physicalMemory: 12 << 30) == 1536 << 20)
        #expect(DevelopBudget.resolve(choice: .default, physicalMemory: 16 << 30) == 2000 << 20)
        #expect(DevelopBudget.resolve(choice: .default, physicalMemory: 64 << 30) == 2000 << 20)

        // End-to-end key lookup through `target(choice:physicalMemory:environment:defaults:)`.
        let defaults = MemoryDefaults()
        #expect(DevelopBudget.target(choice: .gb4, physicalMemory: ram24, environment: [:], defaults: defaults) == 4000 << 20)
        defaults.set(3500, forKey: DevelopBudget.overrideDefaultsKey)
        #expect(DevelopBudget.target(choice: .gb4, physicalMemory: ram24, environment: [:], defaults: defaults) == 3500 << 20)
        #expect(DevelopBudget.target(choice: .gb4, physicalMemory: ram24,
                                     environment: [DevelopBudget.overrideEnvironmentKey: "2500"], defaults: defaults) == 2500 << 20)
        defaults.set(true, forKey: DevelopBudget.overrideDefaultsKey)
        #expect(DevelopBudget.target(choice: .gb4, physicalMemory: ram24, environment: [:], defaults: defaults) == 4000 << 20)
    }

    @Test func aSavedChoiceNoLongerOfferedFallsBackToDefault() {
        #expect(DevelopBudget.effectiveChoice(.gb6, physicalMemory: 16 << 30) == .default)
        #expect(DevelopBudget.resolve(choice: .gb6, physicalMemory: 16 << 30) == 2000 << 20)

        #expect(DevelopBudget.effectiveChoice(.gb4, physicalMemory: 12 << 30) == .default)
        #expect(DevelopBudget.resolve(choice: .gb4, physicalMemory: 12 << 30) == 1536 << 20)

        #expect(DevelopBudget.effectiveChoice(.gb3, physicalMemory: 8 << 30) == .default)
        #expect(DevelopBudget.resolve(choice: .gb3, physicalMemory: 8 << 30) == 1024 << 20)

        #expect(DevelopBudget.effectiveChoice(.gb6, physicalMemory: 8 << 30) == .default)
        #expect(DevelopBudget.resolve(choice: .gb6, physicalMemory: 8 << 30) == 1024 << 20)
    }

    @Test func aPerDevelopMemoryTargetReachesTheGate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("argent-per-develop-budget-\(UUID().uuidString)")
        let rollDir = root.appendingPathComponent("roll"), outDir = root.appendingPathComponent("out")
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: rollDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rawURL = rollDir.appendingPathComponent("DSC00601.ARW")
        try Data("not a real raw".utf8).write(to: rawURL)
        let stock = try toyStock()
        let digests = SourceDigests(settle: 0)
        let writer = RecipeWriter(digests: digests)
        let defaultTarget = 2000 << 20
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library,
                                          digests: digests, memoryTarget: defaultTarget, recipeWriter: writer)
        let item = frame("DSC00601.ARW", in: rollDir)
        let recipe = Recipe(frame: item, byteCount: RecipeStore.byteCount(of: rawURL), stock: stock,
                            stockDigest: stock.digest, roll: RollControls(), own: FrameControls(),
                            editRevision: 1, editLineage: "budget-test")
        let job = RollDeveloper.Job(frame: item, recipe: recipe)

        // Passing an explicit budget uses it for the gate without mutating the developer's default.
        _ = await developer.develop([job], to: outDir, output: OutputSettings(), memoryTarget: 4000 << 20)
        #expect(developer.memoryTarget == defaultTarget)
        #expect(developer.lastMemoryTarget == 4000 << 20)
        #expect(developer.lastGateCeiling == (4000 << 20) - DevelopBudget.margin)
        #expect(developer.lastAdmissions?.admitted == 1)

        // A tight per-develop budget on the same developer actually makes the gate wait before admitting.
        _ = await developer.develop([job], to: outDir, output: OutputSettings(), memoryTarget: 1 << 20)
        #expect(developer.lastMemoryTarget == 1 << 20)
        #expect(developer.lastGateCeiling == (1 << 20) - DevelopBudget.margin)
        #expect(developer.lastAdmissions.map { $0.admitted == 1 && $0.waited == 1 } == true)

        // A generous per-develop budget on the same developer admits immediately without waiting.
        _ = await developer.develop([job], to: outDir, output: OutputSettings(), memoryTarget: 6000 << 20)
        #expect(developer.lastMemoryTarget == 6000 << 20)
        #expect(developer.lastGateCeiling == (6000 << 20) - DevelopBudget.margin)
        #expect(developer.lastAdmissions.map { $0.admitted == 1 && $0.waited == 0 } == true)

        // Omitting `memoryTarget` falls back to the developer's own target.
        _ = await developer.develop([job], to: outDir, output: OutputSettings())
        #expect(developer.lastMemoryTarget == defaultTarget)
        #expect(developer.lastGateCeiling == defaultTarget - DevelopBudget.margin)
    }

    @Test func raw9TileFollowsTheMemoryTarget() {
        #expect(DevelopBudget.learnedDecodeTile(forMemoryTarget: 1999 << 20) == 1024)
        #expect(DevelopBudget.learnedDecodeTile(forMemoryTarget: 2000 << 20) == 1024)
        #expect(DevelopBudget.learnedDecodeTile(forMemoryTarget: 2999 << 20) == 1024)
        #expect(DevelopBudget.learnedDecodeTile(forMemoryTarget: 3000 << 20) == 2048)
        #expect(DevelopBudget.learnedDecodeTile(forMemoryTarget: 4000 << 20) == 2048)
        #expect(DevelopBudget.learnedDecodeTile(forMemoryTarget: 6000 << 20) == 2048)
        #expect(RollDeveloper.decodeTile == 768)
        #expect(RollDeveloper.learnedDecodeTile == 1024)
    }

    @Test func aDevelopPicksRAW9sTileFromItsTargetAndAnExplicitTileStillWins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("argent-develop-tile-\(UUID().uuidString)")
        let rollDir = root.appendingPathComponent("roll"), outDir = root.appendingPathComponent("out")
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: rollDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rawURL = rollDir.appendingPathComponent("DSC00601.ARW")
        try Data("not a real raw".utf8).write(to: rawURL)
        let stock = try toyStock()
        let digests = SourceDigests(settle: 0)
        let writer = RecipeWriter(digests: digests)
        let item = frame("DSC00601.ARW", in: rollDir)
        let recipe = Recipe(frame: item, byteCount: RecipeStore.byteCount(of: rawURL), stock: stock,
                            stockDigest: stock.digest, roll: RollControls(), own: FrameControls(),
                            editRevision: 1, editLineage: "tile-unit")
        let job = RollDeveloper.Job(frame: item, recipe: recipe)

        let automatic = try RollDeveloper(stocks: [stock], software: "Argent test", library: library,
                                          digests: digests, memoryTarget: 2000 << 20, recipeWriter: writer)
        #expect(automatic.lastLearnedDecodeTile == nil)
        #expect(automatic.learnedDecodeTile == 1024)

        _ = await automatic.develop([job], to: outDir, output: OutputSettings(), memoryTarget: 2999 << 20)
        #expect(automatic.lastLearnedDecodeTile == 1024)
        _ = await automatic.develop([job], to: outDir, output: OutputSettings(), memoryTarget: 3000 << 20)
        #expect(automatic.lastLearnedDecodeTile == 2048)
        _ = await automatic.develop([job], to: outDir, output: OutputSettings(), memoryTarget: 6000 << 20)
        #expect(automatic.lastLearnedDecodeTile == 2048)
        _ = await automatic.develop([job], to: outDir, output: OutputSettings())
        #expect(automatic.lastLearnedDecodeTile == 1024)

        let fixed = try RollDeveloper(stocks: [stock], software: "Argent test", library: library,
                                      digests: digests, learnedDecodeTile: 1536, memoryTarget: 2000 << 20, recipeWriter: writer)
        #expect(fixed.learnedDecodeTile == 1536)
        _ = await fixed.develop([job], to: outDir, output: OutputSettings(), memoryTarget: 2000 << 20)
        #expect(fixed.lastLearnedDecodeTile == 1536)
        _ = await fixed.develop([job], to: outDir, output: OutputSettings(), memoryTarget: 4000 << 20)
        #expect(fixed.lastLearnedDecodeTile == 1536)

        let whole = try RollDeveloper(stocks: [stock], software: "Argent test", library: library,
                                      digests: digests, learnedDecodeTile: .some(nil), memoryTarget: 4000 << 20, recipeWriter: writer)
        #expect(whole.learnedDecodeTile == nil)
        _ = await whole.develop([job], to: outDir, output: OutputSettings(), memoryTarget: 4000 << 20)
        #expect(whole.lastLearnedDecodeTile == nil)
    }

    @Test func aDecodeAddsItsFrameAndItsDecodersWorkingMemory() {
        let mb = 1 << 20, pixels = 7008 * 4672
        #expect(DevelopBudget.decodeCost(width: 7008, height: 4672, decoder: .apple, tile: 768) == pixels * 8 + 212 * mb)
        #expect(DevelopBudget.decodeCost(width: 7008, height: 4672, decoder: .apple, tile: 1024) == pixels * 8 + 387 * mb)
        #expect(DevelopBudget.decodeCost(width: 7008, height: 4672, decoder: .raw9, tile: 768) == pixels * 8 + 530 * mb)
        #expect(DevelopBudget.decodeCost(width: 7008, height: 4672, decoder: .raw9, tile: nil) == pixels * 8 + 1080 * mb)
        #expect(DevelopBudget.decodeCost(width: 7008, height: 4672, decoder: .inHouse, tile: 768) == pixels * 8 + pixels * 87 / 10)
        // The in-house decoder's buffers kept from its last decode are not allocated again.
        #expect(DevelopBudget.decodeCost(width: 7008, height: 4672, decoder: .inHouse, tile: 768, inHouseKept: 300 * mb) == pixels * 8)
    }

    @Test func slowEncodersKeepTwoFramesInFlight() {
        #expect(DevelopBudget.plan(for: .jpeg, lanes: 2, pictures: 2, allInHouse: true) == .init(framesInFlight: 4, keepsInHouseBuffers: true))
        #expect(DevelopBudget.plan(for: .heic, lanes: 2, pictures: 2, allInHouse: true) == .init(framesInFlight: 2, keepsInHouseBuffers: true))
        #expect(DevelopBudget.plan(for: .tiff16, lanes: 2, pictures: 1, allInHouse: true) == .init(framesInFlight: 2, keepsInHouseBuffers: false))
        // Beside Apple's decodes the in-house decoder's buffers go after each decode.
        #expect(DevelopBudget.plan(for: .jpeg, lanes: 2, pictures: 2, allInHouse: false) == .init(framesInFlight: 4, keepsInHouseBuffers: false))
    }

    @Test func theGateLetsInWhatFitsBesideTheFootprintAndOneFrameAlways() async {
        let footprint = Footprint(900)
        let gate = MemoryGate(ceiling: 1000, maxInFlight: 2, pendingWindow: 0.2, loneWait: 0.1, footprint: { footprint.value })
        // Over the ceiling with no other frame in, after waiting for memory on its way back.
        #expect(gate.admit(decode: 300, stopped: { false }))
        // Beside it only once the footprint has room for its decode.
        let second = Task.detached { gate.admit(decode: 300, stopped: { false }) }
        try? await Task.sleep(for: .milliseconds(100))
        footprint.value = 701
        try? await Task.sleep(for: .milliseconds(100))
        #expect(gate.counts.admitted == 1)
        footprint.value = 700
        #expect(await second.value)
        // Both waited, the first for memory on its way back.
        #expect(gate.counts == (2, 2))
        // No third while two are in flight, whatever the room; a frame waiting when the develop stops
        // is not let in.
        footprint.value = 0
        #expect(!gate.admit(decode: 1, stopped: { true }))
        gate.leave()
        #expect(gate.admit(decode: 1, stopped: { true }))
        gate.leave()
        gate.leave()
        #expect(gate.admit(decode: 5000, stopped: { false }))
        #expect(gate.loneCount == 2)
    }

    /// The previews' decodes and a develop's frames take turns, so the gate never lets a frame in
    /// beside a preview decode it cannot see coming (docs/manual-development-validation.md,
    /// "Develops started with the frame view open").
    @Test func theDevelopsFramesAndThePreviewsDecodesTakeTurns() async {
        let turns = DecodeTurns()
        let gate = MemoryGate(ceiling: 1000, maxInFlight: 2, turns: turns, footprint: { 0 })
        // Outside a develop a preview decode only counts itself in, and holds a develop's first frame back.
        #expect(turns.beginPreview(stopped: { true }))
        let first = Task.detached { gate.admit(decode: 100, stopped: { false }) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(turns.counts.frames == 0)
        turns.endPreview()
        #expect(await first.value)

        // While a develop runs a preview decode waits for the frames under way, and no frame starts
        // while it waits, whatever the room.
        turns.isDevelopRunning = true
        let preview = Task.detached { turns.beginPreview(stopped: { false }) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(turns.counts == (frames: 1, previewsWaiting: 1, previewsRunning: 0))
        #expect(!gate.admit(decode: 1, stopped: { true }))
        gate.leave()
        #expect(await preview.value)

        // Nor while it runs, nor beside a second one, which waits for the first; then the frame goes in.
        let second = Task.detached { turns.beginPreview(stopped: { false }) }
        let frame = Task.detached { gate.admit(decode: 1, stopped: { false }) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(turns.counts == (frames: 0, previewsWaiting: 1, previewsRunning: 1))
        turns.endPreview()
        #expect(await second.value)
        turns.endPreview()
        #expect(await frame.value)

        // A preview decode given up on while it waits is not counted.
        #expect(!turns.beginPreview(stopped: { true }))
        #expect(turns.counts == (frames: 1, previewsWaiting: 0, previewsRunning: 0))
        gate.leave()
        turns.isDevelopRunning = false
        #expect(turns.counts == (frames: 0, previewsWaiting: 0, previewsRunning: 0))
    }

    /// The gate reads the floor it starts from once the previews are quiet, and lowers its ceiling by how
    /// far the floor, with what the previews hold now, is above the reference (docs/manual-development-
    /// validation.md, "Develops started with the frame view open").
    @Test func theGateLowersItsCeilingByTheFloorsExcess() async {
        let turns = DecodeTurns()
        let held = Footprint(100), footprint = Footprint(600)
        turns.previewsHeld = { held.value }
        let gate = MemoryGate(ceiling: 2000, maxInFlight: 2, turns: turns, floorReference: 250,
                              floorQuiet: 0.05, floorWaitLimit: 5, pendingWindow: 0.2, loneWait: 0.1, footprint: { footprint.value })
        // Not while a preview render runs.
        turns.beginRender()
        let first = Task.detached { gate.admit(decode: 300, stopped: { false }) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(gate.counts.admitted == 0)
        turns.endRender()
        #expect(await first.value)
        // The footprint less what the previews hold.
        #expect(gate.floorReport.floor == 500)
        #expect(gate.floorReport.quiet)

        // 500 + 100 - 250 = 350 comes off the ceiling: a frame beside the first fits under 1650.
        footprint.value = 1351
        let second = Task.detached { gate.admit(decode: 300, stopped: { false }) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(gate.counts.admitted == 1)
        footprint.value = 1350
        #expect(await second.value)
        #expect(gate.floorReport.largestExcess == 350)

        // What the previews take back during the develop comes off it too.
        gate.leave()
        held.value = 200
        footprint.value = 1251
        let third = Task.detached { gate.admit(decode: 300, stopped: { false }) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(gate.counts.admitted == 2)
        footprint.value = 1250
        #expect(await third.value)
        #expect(gate.floorReport.largestExcess == 450)

        // With none in flight a frame still goes in, whatever the excess, after at most its wait.
        gate.leave()
        gate.leave()
        footprint.value = 5000
        #expect(gate.admit(decode: 300, stopped: { false }))
    }

    /// A frame let in with none in flight waits, at most `loneWait`, for the footprint with its decode
    /// to fit, and its decode counts beside the footprint for `pendingWindow` when the next frame is
    /// weighed: a decode shows in the footprint only 0.17 to 0.42 s after it starts, and two frames let
    /// in together took S3 over the target (docs/manual-development-validation.md, "Develops started
    /// with the frame view open").
    @Test func aFrameLetInAloneIsWeighedAndCountedUntilItShows() async {
        func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        let footprint = Footprint(1800)
        // A reference above any floor here, so no excess.
        let gate = MemoryGate(ceiling: 2000, maxInFlight: 2, floorReference: 1 << 40, floorQuiet: 0.01,
                              pendingWindow: 1, loneWait: 0.2, footprint: { footprint.value })
        let asked = uptime()
        #expect(gate.admit(decode: 300, stopped: { false }))
        let first = uptime()
        #expect(first - asked >= 0.2)
        #expect(gate.loneCount == 1)

        // Beside it, its decode counts until 1 s after it went in: 1500 + 300 + 300 is over 2000.
        footprint.value = 1500
        #expect(!gate.admit(decode: 300, stopped: { true }))
        #expect(gate.admit(decode: 300, stopped: { false }))
        #expect(uptime() - first >= 1)

        // A frame let in beside another is not counted: the next fits at once beside it.
        gate.leave()
        #expect(gate.admit(decode: 300, stopped: { true }))
        #expect(gate.loneCount == 1)
        gate.leave()
        gate.leave()

        // Alone and fitting, a frame goes in at once.
        footprint.value = 0
        #expect(gate.admit(decode: 300, stopped: { true }))
    }

    /// While the floor is above the reference, every frame let in counts its decode until it shows, not
    /// only one let in alone: in S3 a frame let in beside others, and another 62 ms later beside it, took
    /// the develop over the target (docs/manual-development-validation.md, "Develops started with the
    /// frame view open").
    @Test func aboveTheReferenceFloorEveryFrameLetInIsCounted() async {
        func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        let footprint = Footprint(500)
        // Floor 500 against a reference of 100: an excess of 400, so frames fit under 2600.
        let gate = MemoryGate(ceiling: 3000, maxInFlight: 2, floorReference: 100, floorQuiet: 0.01,
                              pendingWindow: 1, loneWait: 0.2, footprint: { footprint.value })
        #expect(gate.admit(decode: 300, stopped: { true }))
        footprint.value = 1000
        #expect(gate.admit(decode: 300, stopped: { true }))
        let second = uptime()
        #expect(gate.loneCount == 1)
        #expect(gate.floorReport.largestExcess == 400)
        // The first leaves; beside the second, its decode counts: 2000 + 300 + 300 is over 2600.
        gate.leave()
        footprint.value = 2000
        #expect(!gate.admit(decode: 300, stopped: { true }))
        #expect(gate.admit(decode: 300, stopped: { false }))
        #expect(uptime() - second >= 1)
    }

    /// A decode that shows in the footprint gradually, RAW 9's, counts beside it for what of it has not
    /// shown yet, from all of it to none over its time, though its frame went in beside others and the floor
    /// is at the reference: two RAW 9 frames let in 0.14 s apart took 16-bit TIFF develops with frames
    /// opened during them over the target (docs/manual-development-validation.md, "RAW 9 on the M5 Pro").
    @Test func aDecodeThatShowsGraduallyCountsUntilItHasShown() async {
        func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        let footprint = Footprint(100)
        // At the reference floor, and RAW 8's window 0: only the gradual decode is counted.
        let gate = MemoryGate(ceiling: 1500, maxInFlight: 3, floorReference: 1 << 40, floorQuiet: 0.01,
                              pendingWindow: 0, loneWait: 0.1, footprint: { footprint.value })
        #expect(gate.admit(decode: 300, stopped: { true }))
        // Beside the first, a frame weighed as RAW 8's would fit, and again after it.
        #expect(gate.admit(decode: 800, showsOver: 1, stopped: { true }))
        let gradual = uptime()
        // 100 + 800 + 700 is over 1500 at once; it fits once 100 of the 800 has had time to show.
        #expect(!gate.admit(decode: 700, stopped: { true }))
        #expect(gate.admit(decode: 700, stopped: { false }))
        #expect(uptime() - gradual >= 0.1)
        gate.leave(); gate.leave(); gate.leave()
        // Without `showsOver` the same frames go in at once.
        let classic = MemoryGate(ceiling: 1500, maxInFlight: 3, floorReference: 1 << 40, floorQuiet: 0.01,
                                 pendingWindow: 0, loneWait: 0.1, footprint: { footprint.value })
        #expect(classic.admit(decode: 300, stopped: { true }))
        #expect(classic.admit(decode: 800, stopped: { true }))
        #expect(classic.admit(decode: 700, stopped: { true }))
    }

    /// While the floor is above the reference, the film passes still to come of a frame in flight count
    /// beside the footprint until they are done; at or under it they do not (docs/manual-development-
    /// validation.md, "fix⁗").
    @Test func filmPassesStillToComeCountAboveTheReferenceFloor() {
        let footprint = Footprint(500)
        // Floor 500, reference 100: frames fit under 3000 - 400 = 2600. No decode pending after 0.
        let gate = MemoryGate(ceiling: 3000, maxInFlight: 2, floorReference: 100, floorQuiet: 0.01,
                              pendingWindow: 0, loneWait: 0.1, footprint: { footprint.value })
        #expect(gate.admit(decode: 300, filmPasses: 400, frame: 0, stopped: { true }))
        // 1901 + 400 + 300 is over 2600 until frame 0's film passes are done.
        footprint.value = 1901
        #expect(!gate.admit(decode: 300, filmPasses: 400, frame: 1, stopped: { true }))
        gate.filmPassesDone(frame: 0)
        #expect(gate.admit(decode: 300, filmPasses: 400, frame: 1, stopped: { true }))
        // Leaving takes a frame's film passes with it.
        gate.leave(frame: 0)
        #expect(!gate.admit(decode: 300, filmPasses: 400, frame: 2, stopped: { true }))
        gate.leave(frame: 1)
        gate.leave()

        // At the reference floor nothing is counted so.
        let level = MemoryGate(ceiling: 3000, maxInFlight: 2, floorReference: 1 << 40, floorQuiet: 0.01,
                               pendingWindow: 0, loneWait: 0.1, footprint: { footprint.value })
        footprint.value = 500
        #expect(level.admit(decode: 300, filmPasses: 400, frame: 0, stopped: { true }))
        footprint.value = 2300
        #expect(level.admit(decode: 300, filmPasses: 400, frame: 1, stopped: { true }))
    }

    /// A decode's end and a trim restart the quiet; the gate reads the floor at its wait's limit whatever
    /// runs, and a frame stopped before then is not let in.
    @Test func theGateWaitsForTheQuietAtMostItsLimit() async {
        let turns = DecodeTurns()
        func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        // Outside a develop a preview decode only counts itself in; the floor waits for its end and then the quiet.
        let afterDecode = MemoryGate(ceiling: 2000, maxInFlight: 2, turns: turns, floorQuiet: 0.2, floorWaitLimit: 5, footprint: { 900 })
        #expect(turns.beginPreview(stopped: { false }))
        let first = Task.detached { afterDecode.admit(decode: 1, stopped: { false }) ? uptime() : 0 }
        try? await Task.sleep(for: .milliseconds(50))
        let ended = uptime()
        turns.endPreview()
        #expect(await first.value - ended >= 0.2)
        #expect(afterDecode.floorReport.quiet)
        afterDecode.leave()

        let afterTrim = MemoryGate(ceiling: 2000, maxInFlight: 2, turns: turns, floorQuiet: 0.2, floorWaitLimit: 5, footprint: { 900 })
        let trimmed = uptime()
        turns.trimmed()
        #expect(afterTrim.admit(decode: 1, stopped: { false }))
        #expect(uptime() - trimmed >= 0.2)
        afterTrim.leave()

        // A render that does not end holds the floor back only to the limit.
        let limited = MemoryGate(ceiling: 2000, maxInFlight: 2, turns: turns, floorQuiet: 0.05, floorWaitLimit: 0.2, footprint: { 900 })
        let stopped = MemoryGate(ceiling: 2000, maxInFlight: 2, turns: turns, floorQuiet: 0.05, floorWaitLimit: 5, footprint: { 0 })
        turns.beginRender()
        let started = uptime()
        #expect(limited.admit(decode: 1, stopped: { false }))
        #expect(uptime() - started >= 0.2)
        #expect(limited.floorReport.floor == 900)
        #expect(!limited.floorReport.quiet)
        limited.leave()
        #expect(!stopped.admit(decode: 1, stopped: { true }))
        #expect(stopped.floorReport.floor == nil)
        turns.endRender()
    }
}

private final class Footprint: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int
    init(_ bytes: Int) { self.bytes = bytes }
    var value: Int {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int, RollDeveloper.Outcome)] = []
    func add(_ index: Int, _ outcome: RollDeveloper.Outcome) { lock.withLock { entries.append((index, outcome)) } }
    var count: Int { lock.withLock { entries.count } }
}

private final class MemoryDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "argent-roll-tests-memory")! }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
}
