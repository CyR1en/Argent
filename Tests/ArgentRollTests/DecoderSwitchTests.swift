@testable import ArgentCore
import CoreGraphics
import Foundation
import Testing
@testable import ArgentRoll

private func toyStock() throws -> Stock {
    Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
}

/// The app's decoder routes (docs/decoder.md, sections 14 and 18): the sheet's disk cache and a roll's
/// develops are keyed by the decoder that made each frame, so moving between routes decodes and
/// develops again exactly the frames whose decoder changes. Runs only where the CC0 samples are
/// present; each develop decodes at full size.
@Suite(.serialized, .rawDecodes) struct DecoderSwitchSampleTests {
    private static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    static let lossless = "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"
    static let compressed = "ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW"
    private static var hasSamples: Bool { FileManager.default.fileExists(atPath: samples.appendingPathComponent(lossless).path) }

    /// A roll folder of hard links to the samples, so recipes land in a scratch folder.
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

    /// The sheet's decodes on disk are kept per decoder: RAW 9's route decodes again the three frames
    /// RAW 9 takes (lossless L, uncompressed and compressed) and reads the lossless M and S frames
    /// back from RAW 8's; the in-house route decodes its two again; each route opened again reads
    /// everything back.
    @Test(.enabled(if: DecoderSwitchSampleTests.hasSamples))
    func theDiskCacheKeepsEachDecodersFrames() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeToyStock(id: "kodak-portra-400", in: directory)
        let stocks = StockLibrary.load(from: directory).stocks
        let disk = LinearDiskCache(folder: directory.appendingPathComponent("linear"))
        let roll = await RollScanner.scan(Self.samples)
        #expect(roll.frames.count == 5)

        func renderAll(_ route: DecoderRoute) async throws -> FilmPreviews {
            let films = try FilmPreviews(stocks: stocks, diskCache: disk, decoderChoices: DecoderChoices(route: route))
            for frame in roll.frames {
                _ = try #require(await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
            }
            disk.flush()
            return films
        }
        let apple = try await renderAll(.apple)
        #expect(apple.decodeCount == 5 && apple.diskHitCount == 0)
        let learnedFrames = roll.frames.filter { DecoderChoice.of($0.url, route: .raw9) == .raw9 }.count
        let ownFrames = roll.frames.filter { DecoderChoice.of($0.url, route: .inHouse) == .inHouse }.count
        #expect(learnedFrames == 3 && ownFrames == 2)
        let learned = try await renderAll(.raw9)
        #expect(learned.decodeCount == learnedFrames && learned.diskHitCount == 5 - learnedFrames)
        let learnedAgain = try await renderAll(.raw9)
        #expect(learnedAgain.decodeCount == 0 && learnedAgain.diskHitCount == 5)
        let inHouse = try await renderAll(.inHouse)
        #expect(inHouse.decodeCount == ownFrames && inHouse.diskHitCount == 5 - ownFrames)
        let inHouseAgain = try await renderAll(.inHouse)
        #expect(inHouseAgain.decodeCount == 0 && inHouseAgain.diskHitCount == 5)
        let appleAgain = try await renderAll(.apple)
        #expect(appleAgain.decodeCount == 0 && appleAgain.diskHitCount == 5)
    }

    /// A roll developed by RAW 8 develops its RAW 9 frames again on RAW 9's route, and a develop after
    /// that skips everything; M8's route develops again the frames whose decoder changes (the lossless
    /// L frame in-house, the compressed one back to RAW 8), and going back to Apple's decoder develops
    /// again only the in-house frame. Each develop records its decoder and its read-back.
    @Test(.enabled(if: DecoderSwitchSampleTests.hasSamples))
    func aRollDevelopsAgainExactlyTheFramesWhoseDecoderChanges() async throws {
        let (roll, root) = try await roll([Self.lossless, Self.compressed])
        defer { try? FileManager.default.removeItem(at: root) }
        let stock = try toyStock()
        let library = root.appendingPathComponent("library")
        let out = root.appendingPathComponent("out")
        let output = OutputSettings(size: .longEdge2048)
        func develop(_ route: DecoderRoute) async throws -> [RollDeveloper.Outcome] {
            let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library,
                                              decoderChoices: DecoderChoices(route: route))
            let jobs = roll.frames.map { frame in
                RollDeveloper.Job(frame: frame, recipe: Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url),
                                                               stock: stock, stockDigest: stock.digest, roll: RollControls(),
                                                               own: FrameControls(), previous: RecipeStore.read(for: frame, library: library)))
            }
            return await developer.develop(jobs, to: out, output: output)
        }
        let isLossless = roll.frames.map { $0.url.lastPathComponent == Self.lossless }
        func decoders() -> [String?] { roll.frames.map { RecipeStore.read(for: $0, library: library)?.develops.last?.decode?.decoderVersion } }
        func kinds(_ outcomes: [RollDeveloper.Outcome]) -> [String] {
            outcomes.map { if case .developed = $0 { "developed" } else if case .alreadyDeveloped = $0 { "skipped" } else { "\($0)" } }
        }
        let apple = AppleRawDecoder.pinnedDecoderVersion, learned = AppleRawDecoder.learnedDecoderVersion, inHouse = InHouseDecoder.version

        #expect(kinds(try await develop(.apple)) == ["developed", "developed"])
        #expect(decoders() == [apple, apple])
        #expect(kinds(try await develop(.raw9)) == ["developed", "developed"])
        #expect(decoders() == [learned, learned])
        #expect(kinds(try await develop(.raw9)) == ["skipped", "skipped"])
        #expect(kinds(try await develop(.inHouse)) == ["developed", "developed"])
        #expect(decoders() == isLossless.map { $0 ? inHouse : apple })
        #expect(kinds(try await develop(.inHouse)) == ["skipped", "skipped"])
        #expect(kinds(try await develop(.apple)) == isLossless.map { $0 ? "developed" : "skipped" })
        #expect(decoders() == [apple, apple])
        // RAW 9's and the in-house develops kept their frame's read-back, as RAW 8's do; RAW 9's
        // recorded neither a colour amount nor detail, which it does not take.
        let recipe = try #require(RecipeStore.read(for: roll.frames[isLossless.firstIndex(of: true)!], library: library))
        let own = recipe.develops.filter { $0.decode?.decoderVersion == inHouse }
        #expect(own.count == 1 && own[0].readback != nil && own[0].readback == recipe.develops.first?.readback)
        let nines = recipe.develops.filter { $0.decode?.decoderVersion == learned }
        #expect(nines.count == 1 && nines[0].readback != nil && nines[0].fallbackFrom == nil)
        #expect(nines.first?.decode?.colorNoiseReduction == nil && nines.first?.decode?.detail == nil
                && nines.first?.decode?.moireReduction == nil)
    }

    /// A frame RAW 9 fails on develops through RAW 8, its recipe recording that RAW 9 was meant
    /// (`Develop.fallbackFrom`), and that develop stands: the next develop skips it, in the same
    /// session and in the next, as after an in-house failure.
    @Test(.enabled(if: DecoderSwitchSampleTests.hasSamples))
    func aFrameRAW9FailsOnDevelopsThroughRAW8AndStands() async throws {
        let (roll, root) = try await roll([Self.lossless])
        defer { try? FileManager.default.removeItem(at: root) }
        let stock = try toyStock()
        let library = root.appendingPathComponent("library")
        let out = root.appendingPathComponent("out")
        let frame = try #require(roll.frames.first)
        func develop(_ choices: DecoderChoices) async throws -> RollDeveloper.Outcome {
            let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library, decoderChoices: choices)
            let job = RollDeveloper.Job(frame: frame, recipe: Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url),
                                                                     stock: stock, stockDigest: stock.digest, roll: RollControls(),
                                                                     own: FrameControls(), previous: RecipeStore.read(for: frame, library: library)))
            return await developer.develop([job], to: out, output: OutputSettings(size: .longEdge2048))[0]
        }
        let failing = DecoderChoices(route: .raw9)
        failing.refuseRAW9(frame.url)
        guard case .developed = try await develop(failing) else { Issue.record("not developed"); return }
        let recipe = try #require(RecipeStore.read(for: frame, library: library))
        #expect(recipe.develops.count == 1 && recipe.develops[0].decode?.decoderVersion == AppleRawDecoder.pinnedDecoderVersion)
        #expect(recipe.develops[0].fallbackFrom == AppleRawDecoder.learnedDecoderVersion)
        // In RAW 8's own tiles, as RAW 8's develops decode.
        #expect(recipe.develops[0].decode?.tileSize == RollDeveloper.decodeTile)
        guard case .alreadyDeveloped = try await develop(failing) else { Issue.record("developed again in the session"); return }
        guard case .alreadyDeveloped = try await develop(DecoderChoices(route: .raw9)) else { Issue.record("developed again in the next"); return }
    }

    /// A frame RAW 9 fails on twice for the machine, not the file, fails rather than develop through
    /// RAW 8: no develop is recorded to pin it to RAW 8, the session still sends it to RAW 9, and the
    /// next develop makes it with RAW 9.
    @Test(.enabled(if: DecoderSwitchSampleTests.hasSamples))
    func aFrameRAW9FailsOnForTheMachineFailsAndDevelopsWithRAW9Later() async throws {
        let (roll, root) = try await roll([Self.lossless])
        defer { try? FileManager.default.removeItem(at: root) }
        let stock = try toyStock()
        let library = root.appendingPathComponent("library")
        let out = root.appendingPathComponent("out")
        let frame = try #require(roll.frames.first)
        func develop(_ choices: DecoderChoices) async throws -> RollDeveloper.Outcome {
            let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library, decoderChoices: choices)
            let job = RollDeveloper.Job(frame: frame, recipe: Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url),
                                                                     stock: stock, stockDigest: stock.digest, roll: RollControls(),
                                                                     own: FrameControls(), previous: RecipeStore.read(for: frame, library: library)))
            return await developer.develop([job], to: out, output: OutputSettings(size: .longEdge2048))[0]
        }
        let failing = DecoderChoices(route: .raw9)
        failing.refuseRAW9(frame.url, with: GPUError.textureAllocation)
        let outcome = try await develop(failing)
        guard case .failed = outcome else { Issue.record("not failed: \(outcome)"); return }
        #expect(RecipeStore.read(for: frame, library: library)?.develops.isEmpty ?? true)
        #expect(failing.choice(for: frame.url) == .raw9)
        guard case .developed = try await develop(DecoderChoices(route: .raw9)) else { Issue.record("not developed"); return }
        let recipe = try #require(RecipeStore.read(for: frame, library: library))
        #expect(recipe.develops.count == 1 && recipe.develops[0].decode?.decoderVersion == AppleRawDecoder.learnedDecoderVersion)
        #expect(recipe.develops[0].fallbackFrom == nil)
    }
}
