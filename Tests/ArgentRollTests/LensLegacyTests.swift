import Foundation
import Testing
@testable import ArgentCore
@testable import ArgentRoll

@Suite(.serialized, .rawDecodes) struct LensLegacyTests {
    private static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: LensLegacyTests.sample.path),
                   "CC0 samples absent; run scripts/fetch-samples.sh to enable this case"))
    func cameraOffKeepsPreLC5ReceiptsButRemakesLC5Receipts() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("legacy.ARW")
        try FileManager.default.copyItem(at: Self.sample, to: raw)
        // Camera Off, written into a copy of the CC0 raw. Its usable curve stays untouched.
        try {
            let handle = try FileHandle(forReadingFrom: raw)
            defer { try? handle.close() }
            let reader = try TIFFReader(handle: handle)
            let first = try reader.readIFD(at: reader.firstIFDOffset)
            let offsets = try reader.integers(#require(first[0x014A]))
            var data = try Data(contentsOf: raw), changed = false
            for offset in offsets {
                let count = Int(TIFFReader.uint16(try reader.bytes(at: offset, count: 2), 0, littleEndian: reader.littleEndian))
                let entries = try reader.bytes(at: offset + 2, count: count * 12)
                for index in 0..<count where TIFFReader.uint16(entries, index * 12, littleEndian: reader.littleEndian) == 0x7036 {
                    let value = offset + 2 + index * 12 + 8
                    data[value] = 0; data[value + 1] = 0
                    changed = true
                }
            }
            try #require(changed)
            try data.write(to: raw, options: .atomic)
        }()
        let resolved = LensResolver.correction(for: raw, settings: .default)
        try #require(resolved.status.distortion == .file && resolved.legacy == ResolvedLensCorrection.identity.geometry)
        let frame = Frame(id: 0, url: raw, info: try ARWFrameInfo.read(from: raw))
        try writeToyStock(id: "toy", in: folder)
        let stock = try #require(StockLibrary.load(from: folder).stocks.first)
        let library = folder.appendingPathComponent("library")
        let writer = RecipeWriter(digests: SourceDigests(settle: 0))
        let developer = try RollDeveloper(stocks: [stock], software: "Argent LC5 legacy proof", library: library,
            digests: SourceDigests(settle: 0), decoderChoices: DecoderChoices(route: .apple), recipeWriter: writer)
        defer { developer.trim() }
        let destination = folder.appendingPathComponent("out")
        let output = OutputSettings(format: .jpeg, size: .longEdge2048, grain: .off)
        let fresh = Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: raw), stock: stock,
            stockDigest: stock.digest, roll: RollControls(), own: FrameControls())
        let first = await developer.develop([.init(frame: frame, recipe: fresh)], to: destination, output: output)
        let file = try #require(first.first?.file, "\(first)")
        #expect(first == [.developed(file)])
        var legacy = try #require(try await writer.load(for: frame, library: library))
        #expect(RenderGraph.namesLens(legacy.develops.last?.renderVersion))
        legacy.develops[0].renderVersion = RenderGraph.version(for: legacy.render.settings)
        legacy.develops[0].decode?.lensCorrection = true
        legacy.version = legacy.requiredVersion
        // Replace every persisted copy of the receipt, including the protected journal and RAW sidecar.
        func persist(_ record: Recipe) throws {
            let records = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            for case let url as URL in records where ["argent", "json"].contains(url.pathExtension) {
                if let data = try? Data(contentsOf: url), Recipe.decoded(data) != nil {
                    try record.encoded().write(to: url, options: .atomic)
                }
            }
        }
        try persist(legacy)
        let resumed = try #require(try await writer.load(for: frame, library: library))
        #expect(resumed.develops == legacy.develops)
        let bytes = try Data(contentsOf: file)
        let modified = try #require(URL(fileURLWithPath: file.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let second = await developer.develop([.init(frame: frame, recipe: resumed)], to: destination, output: output)
        #expect(second == [.alreadyDeveloped(file)])
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        var lc5 = resumed
        lc5.develops[0].renderVersion = RenderGraph.version(for: lc5.render.settings,
            lens: .uncorrected("the camera was not set to correct it"))
        lc5.develops[0].decode?.lensCorrection = false
        lc5.version = lc5.requiredVersion
        try persist(lc5)
        let oldStage = try #require(try await writer.load(for: frame, library: library))
        let remade = await developer.develop([.init(frame: frame, recipe: oldStage)], to: destination, output: output)
        #expect(remade == [.developed(file)])
        let remadeRecipe = try #require(try await writer.load(for: frame, library: library))
        #expect(remadeRecipe.develops.count == 2)
        #expect(remadeRecipe.develops.last?.renderVersion == RenderGraph.version(for: remadeRecipe.render.settings, lens: resolved))
        let changed = Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: raw), stock: stock,
            stockDigest: stock.digest, roll: RollControls(), own: FrameControls(labBalance: .warm), previous: remadeRecipe)
        let third = await developer.develop([.init(frame: frame, recipe: changed)], to: destination, output: output)
        #expect(third == [.developed(file)])
        let written = try #require(try await writer.load(for: frame, library: library))
        #expect(written.version == 8 && written.develops.count == 3)
        #expect(written.develops.last?.decode?.lensCorrection == false)
        #expect(written.develops.last?.renderVersion == RenderGraph.version(for: written.render.settings,
            lens: LensResolver.correction(for: raw, settings: .default)))
        print("LC7_LEGACY camera-Off pre-LC5 skipped; LC5 receipt remade; changed setting developed through the stage")
    }
    @Test(.enabled(if: FileManager.default.fileExists(atPath: LensLegacyTests.sample.path),
                   "CC0 samples absent; run scripts/fetch-samples.sh to enable this case"))
    func anUnchangedLegacyDevelopIsSkippedAndASettingChangeUsesTheStage() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("legacy.ARW")
        try FileManager.default.copyItem(at: Self.sample, to: raw)
        let frame = Frame(id: 0, url: raw, info: try ARWFrameInfo.read(from: raw))
        try writeToyStock(id: "toy", in: folder)
        let stock = try #require(StockLibrary.load(from: folder).stocks.first)
        let library = folder.appendingPathComponent("library")
        let writer = RecipeWriter(digests: SourceDigests(settle: 0))
        let developer = try RollDeveloper(stocks: [stock], software: "Argent LC5 legacy proof", library: library,
            digests: SourceDigests(settle: 0), decoderChoices: DecoderChoices(route: .apple), recipeWriter: writer)
        defer { developer.trim() }
        let destination = folder.appendingPathComponent("out")
        let output = OutputSettings(format: .jpeg, size: .longEdge2048, grain: .off)
        let fresh = Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: raw), stock: stock,
            stockDigest: stock.digest, roll: RollControls(), own: FrameControls())
        let first = await developer.develop([.init(frame: frame, recipe: fresh)], to: destination, output: output)
        let file = try #require(first.first?.file, "\(first)")
        #expect(first == [.developed(file)])
        var legacy = try #require(try await writer.load(for: frame, library: library))
        #expect(RenderGraph.namesLens(legacy.develops.last?.renderVersion))
        legacy.develops[0].renderVersion = RenderGraph.version(for: legacy.render.settings)
        legacy.develops[0].decode?.lensCorrection = true
        legacy.version = legacy.requiredVersion
        // Replace every persisted copy of the receipt, including the protected journal and RAW sidecar.
        try {
            let records = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            for case let url as URL in records where ["argent", "json"].contains(url.pathExtension) {
                if let data = try? Data(contentsOf: url), Recipe.decoded(data) != nil {
                    try legacy.encoded().write(to: url, options: .atomic)
                }
            }
        }()
        let resumed = try #require(try await writer.load(for: frame, library: library))
        #expect(resumed.develops == legacy.develops)
        let bytes = try Data(contentsOf: file)
        let modified = try #require(URL(fileURLWithPath: file.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let second = await developer.develop([.init(frame: frame, recipe: resumed)], to: destination, output: output)
        #expect(second == [.alreadyDeveloped(file)])
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        let changed = Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: raw), stock: stock,
            stockDigest: stock.digest, roll: RollControls(), own: FrameControls(labBalance: .warm), previous: resumed)
        let third = await developer.develop([.init(frame: frame, recipe: changed)], to: destination, output: output)
        #expect(third == [.developed(file)])
        let written = try #require(try await writer.load(for: frame, library: library))
        #expect(written.version == 8 && written.develops.count == 2)
        #expect(written.develops.last?.decode?.lensCorrection == false)
        #expect(written.develops.last?.renderVersion == RenderGraph.version(for: written.render.settings,
            lens: LensResolver.correction(for: raw, settings: .default)))
        print("LC5_LEGACY skipped unchanged bytes and modification time; changed setting developed through the stage")
    }
    @Test(.enabled(if: FileManager.default.fileExists(atPath: LensLegacyTests.sample.path)))
    func aDevelopRecordsAmount150AndDevelopsAgainAtDefault() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("amount.ARW")
        try FileManager.default.copyItem(at: Self.sample, to: raw)
        let frame = Frame(id: 0, url: raw, info: try ARWFrameInfo.read(from: raw))
        try writeToyStock(id: "toy", in: folder)
        let stock = try #require(StockLibrary.load(from: folder).stocks.first)
        let library = folder.appendingPathComponent("library")
        let writer = RecipeWriter(digests: SourceDigests(settle: 0))
        let developer = try RollDeveloper(stocks: [stock], software: "Argent Lens amount test", library: library,
            digests: SourceDigests(settle: 0), decoderChoices: DecoderChoices(route: .apple), recipeWriter: writer)
        defer { developer.trim() }
        let lens = try LensSettings(arguments: "distortion-amount=150")
        let baseline = AutomaticBaseline(sourceSHA256: try RecipeStore.sha256(of: raw), stockID: stock.id, stockDigest: stock.digest,
            controls: RollControls(), aim: PrintAim(), analysisVersion: ExposureAnalysis.currentVersion,
            baseRender: Recipe.Render(settings: DevelopSettings(), grain: .off))
        let recipe = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: raw), stock: stock, stockDigest: stock.digest,
            roll: RollControls(), own: FrameControls(), manual: ManualEdit(adjustments: .identity.settingLens(lens), baseline: baseline))
        let destination = folder.appendingPathComponent("out")
        let output = OutputSettings(format: .jpeg, size: .longEdge2048, grain: .off)
        let first = await developer.develop([.init(frame: frame, recipe: recipe)], to: destination, output: output)
        let file = try #require(first.first?.file)
        #expect(first == [.developed(file)])
        let written = try #require(try await writer.load(for: frame, library: library))
        let resolved = LensResolver.correction(for: raw, settings: lens)
        try #require(resolved.digest != LensResolver.correction(for: raw, settings: .default).digest)
        #expect(written.develops.last?.renderVersion == RenderGraph.version(for: written.render.settings, lens: resolved))
        #expect(written.develops.last?.render.manual?.adjustments.lens == lens)
        let reset = try Recipe.make(frame: frame, byteCount: RecipeStore.byteCount(of: raw), stock: stock, stockDigest: stock.digest,
            roll: RollControls(), own: FrameControls(), previous: written,
            editRevision: (written.editRevision ?? 0) + 1, editLineage: written.editLineage)
        let savedReset = try await writer.commit(recipe: reset, for: frame, library: library)
        let second = await developer.develop([.init(frame: frame, recipe: savedReset)], to: destination, output: output)
        #expect(second == [.developed(file)])
        let final = try #require(try await writer.load(for: frame, library: library))
        #expect(final.develops.count == 2)
        #expect(final.develops.last?.renderVersion == RenderGraph.version(for: final.render.settings,
            lens: LensResolver.correction(for: raw, settings: .default)))
    }

}
