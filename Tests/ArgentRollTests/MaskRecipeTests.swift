import ArgentCore
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ArgentRoll

/// A roll's frame, its pin and its recipes, with fixed revision, lineage and receipts, so a recipe's bytes are the same on every
/// run and in every build. Each test has a temporary library of its own.
private struct Scene {
    /// The Light compiler the golden recipes were written under. It stays supported, so naming it keeps their bytes when a
    /// newer compiler becomes current.
    static let recordedLight = "2026-10-29-1"

    let root: URL
    let library: URL
    let frame: Frame
    let stock: Stock
    let sha: String
    let writer: RecipeWriter
    let aim = PrintAim(level: -0.3, cast: SIMD3(0.1, -0.05, -0.05))
    let controls = RollControls()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentMasks-\(UUID().uuidString)")
        library = root.appendingPathComponent("library", isDirectory: true)
        let roll = root.appendingPathComponent("roll", isDirectory: true)
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        let raw = roll.appendingPathComponent("frame.ARW")
        try Data(repeating: 71, count: 4096).write(to: raw)
        frame = Frame(id: 0, url: raw, info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1000)))
        stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                      exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let digests = SourceDigests(settle: 0)
        sha = try digests.digest(of: raw).sha256
        writer = RecipeWriter(digests: digests)
        // The library holds the Sky mask's seed, as a selection leaves it before the mask names it: the writer refuses one it lacks.
        try MaskRasterStore(library: library).store(Self.seed)
    }

    /// The Sky mask's seed: a smooth sky over a soft horizon, at a matte's size.
    static let seed: MaskRaster = try! MaskRaster(width: 756, height: 504, plane: (0..<(756 * 504)).map { i in
        let row = i / 756, column = i % 756
        return UInt8(max(0, min(255, 255 - (row - 200 - column / 12) * 4)))
    })

    func baseline(origin: AutomaticBaseline.Origin = .auto, aim override: PrintAim? = nil) -> AutomaticBaseline {
        let aim = origin == .original ? PrintAim() : (override ?? self.aim)
        return AutomaticBaseline(sourceSHA256: sha, stockID: stock.id, stockDigest: stock.digest, controls: controls, aim: aim,
                                 analysisVersion: ExposureAnalysis.currentVersion,
                                 baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: aim), grain: .off), origin: origin)
    }

    func recipe(_ manual: ManualEdit?, held: ManualEdit? = nil, aim override: PrintAim? = nil, receipts: Int = 0,
                revision: UInt64 = 12, previous: Recipe? = nil) throws -> Recipe {
        var recipe = try Recipe.make(frame: frame, byteCount: 4096, stock: stock, stockDigest: stock.digest, roll: controls, own: FrameControls(),
                                     analysis: ExposureAnalysis(meanStops: -0.3, validWeight: 1), aim: override ?? aim, grain: .off, previous: previous,
                                     manual: manual, editRevision: revision, editLineage: "golden-lineage", heldManual: held)
        recipe.raw.sha256 = sha
        for i in 0..<receipts {
            recipe.develops.append(Recipe.Develop(date: Date(timeIntervalSince1970: 3000 + Double(i)), software: "Argent test", output: OutputSettings(),
                file: "/tmp/out/frame\(i).jpg", width: 40, height: 20, render: recipe.render, decode: nil, readback: nil,
                stockDigest: stock.digest, renderVersion: RenderGraph.version(for: recipe.render.settings)))
        }
        return recipe
    }

    func settings(_ manual: ManualEdit?) throws -> DevelopSettings {
        try DevelopmentResolver.resolve(stock: stock, stockDigest: stock.digest, controls: controls, aim: aim, manual: manual, grain: 0, grainSeed: 0)
    }

    static func masks() throws -> MaskSet {
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let raster = seed.ref
        let points = try PackedPoints.pack((0..<40).map { MaskPoint(x: 0.25 + Float($0) / 256, y: 0.5) })
        return try MaskSet(masks: [
            Mask(id: id(1), components: [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: raster, frame: frame)))],
                 adjustments: try ManualAdjustments(exposureEV: -0.7, highlights: -30)),
            Mask(id: id(2), components: [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: 0.3))))],
                 amount: 1.5, adjustments: try ManualAdjustments(exposureEV: -0.4)),
            Mask(id: id(3), components: [MaskComponent(shape: .radial(.init(center: MaskPoint(x: 0.5, y: 0.4), semiAxisA: 0.3, semiAxisB: 0.2, feather: 50))),
                                         MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: frame, strokes: [BrushStroke(radius: 0.05, points: points)])), invert: true)],
                 adjustments: try ManualAdjustments(shadows: 25)),
        ])
    }

    static func id(_ n: UInt8) -> UUID { UUID(uuid: (n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)) }

    func provenance() -> RasterProvenance {
        RasterProvenance(engine: "coreml:da3-sky", engineRevision: "recipe-1", parameters: ["size": "756"], operatingSystem: "macOS test", app: "Argent test",
                         input: .init(kind: "neutral-print", width: 2048, height: 1365, colorSpace: "sRGB", sourceSHA256: sha),
                         created: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func notes(name: String = "Sky") -> MaskNotes {
        MaskNotes(names: [Self.id(1).uuidString: name], rasters: [Self.seed.identity.hex: provenance()])
    }
}

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite struct MaskRecipeBytesTests {
    /// The bytes of the real v5 code (main 3f67969, R6's `out/golden-v5.txt`), for six recipes with no masks. A frame with no masks writes
    /// what it wrote: if one of these moves, it is the code that moved. A change that is meant to move recipes without masks, a new
    /// recipe field or a new analysis version, is a new set of values made from that change, never from this one.
    @Test func recipesWithoutMasksEncodeByteForByteAsVersion5Did() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let light = try ManualAdjustments(exposureEV: 0.7, contrast: 10, highlights: -20)
        let curves = try ManualAdjustments(exposureEV: 0.2, curves: ToneCurves(tone: ToneCurves.Preset.softContrast.curve))
        let toneAim = PrintAim(level: -0.3, cast: SIMD3(0.1, -0.05, -0.05), burn: 0.6, dodge: 0.4)
        func edit(_ values: ManualAdjustments, origin: AutomaticBaseline.Origin = .auto) -> ManualEdit {
            ManualEdit(adjustments: values, baseline: scene.baseline(origin: origin), curveVersion: Scene.recordedLight)
        }
        let golden: [(name: String, recipe: Recipe, version: Int, bytes: Int, sha256: String)] = [
            ("automatic, no edit", try scene.recipe(nil), 2, 1047, "da15261c498d4c59de99d1d709d59c9936f6590dca90038d89356ae7762da247"),
            ("Light only", try scene.recipe(edit(light)), 2, 2273, "4270e061aafc1576421de5a717bc28629491f519cfd67d3c2daeff51b2dba9ac"),
            ("curves", try scene.recipe(edit(curves)), 3, 6123, "d8c9eeb07a5245e1c3b98b47c5e932334c3aa784739797c8dba40f89caf9833b"),
            ("identity Original", try scene.recipe(edit(.identity, origin: .original)), 4, 1949, "a948c984ea4660f2524a062d3d1babfdc257a58fc77c9491b29b08753cde68cb"),
            ("tone step", try scene.recipe(nil, aim: toneAim), 5, 1174, "2b09c6407d9977574204d590359d08252894972946e3bfa22bd2ad9ad2871e0d"),
            ("Light, held edit, 20 receipts", try scene.recipe(edit(light), held: edit(curves), receipts: 20), 3, 25021, "d002fac6f9f804358958d03c114e2ccc98f9a87c02f645a4c655a0210ae8919d"),
        ]
        for item in golden {
            let bytes = try item.recipe.encoded()
            #expect(item.recipe.version == item.version && item.recipe.requiredVersion == item.version, "\(item.name)")
            #expect(bytes.count == item.bytes, "\(item.name)")
            #expect(sha256(bytes) == item.sha256, "\(item.name)")
            #expect(!String(decoding: bytes, as: UTF8.self).contains("mask"), "\(item.name)")
        }
    }

    @Test func onlyMasksRequireRecipeVersion6() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let masked = try ManualAdjustments(masks: Scene.masks())
        let baseline = scene.baseline()
        func required(_ recipe: Recipe) -> Int { recipe.requiredVersion }
        #expect(required(try scene.recipe(nil)) == 2)
        #expect(required(try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(exposureEV: 1), baseline: baseline))) == 2)
        #expect(required(try scene.recipe(nil, aim: PrintAim(level: -0.3, burn: 0.6, dodge: 0.4))) == 5)
        #expect(required(try scene.recipe(ManualEdit(adjustments: masked, baseline: baseline))) == 6)
        // Held, the frame's own edit having none.
        #expect(required(try scene.recipe(nil, held: ManualEdit(adjustments: masked, baseline: baseline))) == 6)
        // Only in a receipt: a reset leaves the record at v6 while its newest 20 hold a digest, as curves leave one at v3.
        var withReceipt = try scene.recipe(nil)
        let masksRender = try scene.recipe(ManualEdit(adjustments: masked, baseline: baseline)).render
        withReceipt.develops.append(.init(date: Date(timeIntervalSince1970: 3000), software: "Argent test", output: OutputSettings(), file: "/tmp/x.jpg",
            width: 40, height: 20, render: masksRender, decode: nil, readback: nil, stockDigest: scene.stock.digest, renderVersion: "v"))
        #expect(required(withReceipt) == 6)
        withReceipt.version = 6
        let read = try Recipe.decodeStrict(try withReceipt.encoded())
        #expect(read.version == 6 && read.requiredVersion == 6 && read.manual == nil && read.develops[0].render == masksRender)
        var noReceipts = read
        noReceipts.develops = []
        #expect(noReceipts.requiredVersion == 2)
    }
}

@Suite struct MaskRecipeTests {
    @Test func aRecipeWithMasksRoundTripsWithItsNotesAndWritesOnlyDigestsInReceipts() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks()
        let edit = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3, masks: set), baseline: scene.baseline(), maskNotes: scene.notes())
        let recipe = try scene.recipe(edit, receipts: 20)
        #expect(recipe.version == 6 && recipe.requiredVersion == 6)
        let bytes = try recipe.encoded()
        let read = try Recipe.decodeStrict(bytes)
        #expect(read == recipe)
        #expect(read.manual == recipe.manual && read.manual?.maskNotes == scene.notes())
        #expect(read.render == recipe.render && read.render.manual?.adjustments.masks.masks == set.masks)
        #expect(read.manual?.adjustments.masks.masks == set.masks)
        // Receipts: a digest, equal to what they came from, that cannot print.
        #expect(read.develops.count == 20)
        #expect(read.develops.allSatisfy { $0.render.manual?.adjustments.masks.isDigestOnly == true && $0.render == recipe.render })
        #expect(throws: MaskError.digestOnly) { try read.develops[0].render.settings.manual.validateSupportedVersion() }
        // The set appears in the manual edit and the resolved render, and in no receipt.
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.components(separatedBy: "\"list\"").count - 1 == 2)
        #expect(text.components(separatedBy: "\"digest\" : \"\(set.digest)\"").count - 1 == 20)
        // Writing again changes nothing, the receipts already digests.
        #expect(try read.encoded() == bytes)
        // Twenty full copies would be far larger, and that is why they are not written.
        let whole = JSONEncoder()
        whole.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        whole.dateEncodingStrategy = .iso8601
        #expect(try whole.encode(recipe).count > bytes.count * 3)
    }

    @Test func masksLabelledAnOlderVersionAreRefused() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        var recipe = try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(masks: Scene.masks()), baseline: scene.baseline()))
        recipe.version = 5
        #expect(throws: Recipe.ReadFailure.invalid("masks require recipe version 6")) { try recipe.validate() }
        #expect(throws: Recipe.ReadFailure.invalid("masks require recipe version 6")) { try Recipe.decodeStrict(try recipe.encoded()) }
    }

    /// Only a receipt may hold a digest: a current edit that does would print nothing it could read.
    @Test func aDigestInACurrentEditFailsTheRead() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks()
        let good = try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: scene.baseline()))
        var bad = good
        bad.manual?.adjustments = good.manual!.adjustments.settingMasks(set.digestOnly)
        #expect(throws: Recipe.ReadFailure.self) { try bad.validate() }
        var badRender = good
        badRender.render.manual = good.render.manual?.digestingMasks()
        #expect(badRender.render == good.render)
        #expect(throws: Recipe.ReadFailure.self) { try badRender.validate() }
        var badHeld = try scene.recipe(nil, held: ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: scene.baseline()))
        badHeld.heldManual?.adjustments = try ManualAdjustments(masks: set.digestOnly)
        #expect(throws: Recipe.ReadFailure.self) { try badHeld.validate() }
    }

    @Test func aHeldEditKeepsItsMasksInFull() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks()
        let held = ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: scene.baseline(), maskNotes: scene.notes())
        let recipe = try scene.recipe(nil, held: held)
        #expect(recipe.version == 6)
        let saved = try await scene.writer.commit(recipe: recipe, for: scene.frame, library: scene.library)
        #expect(saved.heldManual == held)
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(loaded?.heldManual?.adjustments.masks.masks == set.masks && loaded?.heldManual?.maskNotes == scene.notes())
    }

    /// Everything a v6 reader cannot read is preserved, and nothing overwrites it: a newer recipe version, a masks schema, and a
    /// shape, kind or operation it does not know, through the writer's own load and commit.
    @Test(arguments: [("a newer recipe version", "\"version\" : 6", "\"version\" : \(Recipe.currentVersion + 1)"),
                      ("a masks schema newer than this build", "\"schema\" : 1", "\"schema\" : 7"),
                      ("a mask shape this build does not know", "\"type\" : \"linear\"", "\"type\" : \"depth\""),
                      ("a range mask, not in schema 1", "\"type\" : \"linear\"", "\"type\" : \"range\""),
                      ("a smart kind this build does not know", "\"kind\" : \"sky\"", "\"kind\" : \"water\""),
                      ("a mask operation this build does not know", "\"operation\" : \"subtract\"", "\"operation\" : \"xor\"")])
    func whatThisBuildCannotReadFailsAndIsPreserved(name: String, old: String, new: String) async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let edit = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3, masks: Scene.masks()), baseline: scene.baseline())
        let saved = try await scene.writer.commit(recipe: scene.recipe(edit), for: scene.frame, library: scene.library)
        #expect(saved.version == 6)
        let sidecar = RecipeStore.besideRaw(scene.frame.url)
        let text = String(decoding: try saved.encoded(), as: UTF8.self)
        let changed = text.replacingOccurrences(of: old, with: new)
        #expect(changed != text, "\(name) is not in the record")
        #expect(throws: (any Error).self) { try Recipe.decodeStrict(Data(changed.utf8)) }
        if name == "a newer recipe version" {
            #expect(throws: Recipe.ReadFailure.unsupportedVersion(Recipe.currentVersion + 1)) { try Recipe.decodeStrict(Data(changed.utf8)) }
        }
        #expect(Recipe.decoded(Data(changed.utf8)) == nil)
        try Data(changed.utf8).write(to: sidecar, options: .atomic)
        await #expect(throws: (any Error).self) { try await scene.writer.load(for: scene.frame, library: scene.library) }
        await #expect(throws: (any Error).self) { try await scene.writer.commit(recipe: saved, for: scene.frame, library: scene.library) }
        #expect(try Data(contentsOf: sidecar) == Data(changed.utf8), "\(name) was overwritten")
    }

    @Test func anExportOfRevision12KeepsItsMasksWhileRevision13ChangesThem() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks()
        var slid = set.masks[1]
        slid.amount = 0.5
        let changed = try set.replacing(slid)
        var exported = try await scene.writer.commit(recipe: scene.recipe(ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: scene.baseline())),
                                                     for: scene.frame, library: scene.library)
        let edited = try await scene.writer.commit(recipe: scene.recipe(ManualEdit(adjustments: try ManualAdjustments(masks: changed), baseline: scene.baseline()),
                                                                        revision: 13, previous: exported), for: scene.frame, library: scene.library)
        let output = scene.root.appendingPathComponent("image.jpg")
        try Data("exported image".utf8).write(to: output)
        exported.develops.append(.init(date: Date(timeIntervalSince1970: 2000), software: "Argent test", output: OutputSettings(), file: output.path, width: 40, height: 20,
            render: exported.render, decode: nil, readback: nil, stockDigest: scene.stock.digest,
            renderVersion: RenderGraph.version(for: exported.render.settings), outputSource: SourceStamp.of(output)))
        let merged = try await scene.writer.mergeExport(recipe: exported, for: scene.frame, library: scene.library)
        #expect(merged.editRevision == 13 && merged.manual?.adjustments.masks == changed && merged.render == edited.render)
        #expect(merged.develops.count == 1 && merged.develops[0].render == exported.render)
        #expect(!FileManager.default.fileExists(atPath: output.deletingPathExtension().appendingPathExtension("argent").path))
        let current = try #require(try await scene.writer.load(for: scene.frame, library: scene.library))
        #expect(current.manual?.adjustments.masks.masks == changed.masks && current.develops.count == 1)
        #expect(current.develops[0].render.manual?.adjustments.masks.isDigestOnly == true)
        #expect(current.develops[0].render == exported.render && current.develops[0].render != current.render)
    }

    /// A read-only card: the library keeps the record with its masks, as it keeps sliders.
    @Test func aLockedCardKeepsItsMasksInTheLibrary() async throws {
        let scene = try Scene()
        let roll = scene.frame.url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roll.path)
            try? FileManager.default.removeItem(at: scene.root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roll.path)
        let set = try Scene.masks()
        let saved = try await scene.writer.commit(recipe: scene.recipe(ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: scene.baseline())),
                                                  for: scene.frame, library: scene.library)
        #expect(saved.version == 6 && !FileManager.default.fileExists(atPath: RecipeStore.besideRaw(scene.frame.url).path))
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(loaded?.manual?.adjustments.masks.masks == set.masks)
    }

    @Test func notesAreOmittedWhenEmptyAndGoWithTheirMasks() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks(), notes = scene.notes(), base = scene.baseline()
        // Empty: no key, so a frame with no masks writes what it wrote.
        let plain = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 1), baseline: base)
        #expect(try plain.maskNotes == .none && !String(decoding: JSONEncoder().encode(plain), as: UTF8.self).contains("maskNotes"))
        var edit = ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: base, maskNotes: notes)
        #expect(edit.maskNotes == notes)
        #expect(String(decoding: try JSONEncoder().encode(edit), as: UTF8.self).contains("maskNotes"))
        #expect(try JSONDecoder().decode(ManualEdit.self, from: JSONEncoder().encode(edit)) == edit)
        // A name goes with its mask, a seed's provenance with its seed.
        edit.adjustments = edit.adjustments.settingMasks(try set.removing(Scene.id(1)))
        #expect(edit.maskNotes == .none)
        var kept = ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: base, maskNotes: notes)
        kept.adjustments = try kept.adjustments.setting(.exposure, to: 0.5)
        #expect(kept.maskNotes == notes)
        kept.adjustments = kept.adjustments.settingMasks(try set.forAnotherPicture(freshIDs: false))
        #expect(kept.maskNotes.names == notes.names && kept.maskNotes.rasters.isEmpty)
        // Clearing the masks clears them all, and notes for what is not there are not written or read.
        kept.adjustments = .identity
        #expect(kept.maskNotes == .none)
        #expect(ManualEdit(adjustments: .identity, baseline: base, maskNotes: notes).maskNotes == .none)
        let stale = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).dropLast() + #","maskNotes":{"names":{"x":"Sky"},"rasters":{}}}"#
        #expect(try JSONDecoder().decode(ManualEdit.self, from: Data(stale.utf8)).maskNotes == .none)
    }
}

@Suite struct MaskFingerprintTests {
    /// A name is not pixels; a raster, a slider, a shape and an Amount are.
    @Test func aRenameChangesNoFingerprintAndARenderInputDoes() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks(), baseline = scene.baseline()
        func edit(_ masks: MaskSet, notes: MaskNotes = .none) throws -> ManualEdit {
            ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3, masks: masks), baseline: baseline, maskNotes: notes)
        }
        let named = try edit(set, notes: scene.notes(name: "Sky")), renamed = try edit(set, notes: scene.notes(name: "Heaven"))
        let base = try scene.settings(named), other = try scene.settings(renamed)
        #expect(base.manual.adjustments.masks == set && base.manual.adjustments.masks.count == 3)
        #expect(other == base && other.hashValue == base.hashValue)
        #expect(set.digest == renamed.adjustments.masks.digest)
        #expect(named != renamed, "the edit differs, so it saves")
        #expect(RenderGraph.version(for: other) == RenderGraph.version(for: base))
        func key(_ settings: DevelopSettings) -> RenderedImageKey {
            .film("frame|source|apple", stock: 0, stockID: "toy", settings: settings, pixels: 100)
        }
        #expect(key(other) == key(base))

        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        var sky = set.masks[0]
        sky.components = [MaskComponent(shape: .smart(SmartSelection(kind: .sky, raster: try RasterRef(id: #require(RasterID(hex: String(repeating: "cd", count: 32))), width: 756, height: 504), frame: frame)))]
        var slid = set.masks[2]
        slid.adjustments = try slid.adjustments.setting(.shadows, to: 26)
        var scaled = set.masks[1]
        scaled.amount = 1.25
        var moved = set.masks[1]
        moved.components = [MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.5, y: 0), zero: MaskPoint(x: 0.5, y: 0.5))))]
        var off = set.masks[1]
        off.isEnabled = false
        for changed in [sky, slid, scaled, moved, off] {
            let settings = try scene.settings(try edit(try set.replacing(changed)))
            #expect(settings != base && settings.hashValue != base.hashValue, "\(changed.id)")
            #expect(key(settings) != key(base))
        }
    }

    /// `Mask.coverage` holds no slider: a drag on a mask keeps its cache key, and moves the render's.
    @Test func aSliderChangesTheSettingsAndNotThatMasksCoverageKey() throws {
        let set = try Scene.masks()
        var slid = set.masks[0]
        slid.adjustments = try slid.adjustments.setting(.exposure, to: -1.2)
        slid.amount = 0.5
        #expect(try set.replacing(slid) != set && slid.coverage == set.masks[0].coverage)
    }

    /// A mask-only edit is a manual render: the Auto picture Compare shows stays in Auto's slot while a mask moves.
    @Test func aMaskOnlyEditTakesTheManualSlotAndCompareSurvivesADrag() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks(), baseline = scene.baseline()
        let edit = ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: baseline)
        #expect(!edit.isEmpty && !edit.adjustments.isIdentity)
        let settings = try scene.settings(edit)
        #expect(!settings.manual.isIdentity && settings.manual.referenceStops == baseline.aim.level)
        let key = RenderedImageKey.film("frame|source|apple", stock: 0, stockID: "toy", settings: settings, pixels: 100)
        #expect(key.isManual && key.renderVersion == RenderGraph.version(for: settings))
        // Compare to Auto takes the masks away with the rest of the edit.
        var auto = settings
        auto.manual = .identity
        #expect(auto.manual.adjustments.masks.isEmpty)
        let compare = RenderedImageKey.film("frame|source|apple", stock: 0, stockID: "toy", settings: auto, pixels: 100)
        #expect(!compare.isManual && compare != key)
        let cache = RenderedImageCache(byteLimit: 1024)
        let picture = try Self.image()
        #expect(cache.store(picture, for: compare))
        var slid = set.masks[1]
        for amount: Float in [0.25, 0.5, 0.75] {
            slid.amount = amount
            let moved = ManualEdit(adjustments: try ManualAdjustments(masks: try set.replacing(slid)), baseline: baseline)
            let manual = RenderedImageKey.film("frame|source|apple", stock: 0, stockID: "toy", settings: try scene.settings(moved), pixels: 100)
            #expect(cache.store(picture, for: manual, ticket: cache.beginRequest(for: manual)))
            #expect(cache.image(for: compare) != nil && cache.image(for: manual) != nil)
        }
    }

    private static func image() throws -> CGImage {
        let data = Data(repeating: 100, count: 16 * 4)
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Whether a develop is made again: not for a rename, which changes no pixel, and yes for a change that does.
    @Test func aDevelopIsMadeAgainWhenAMaskChangesAndNotWhenItIsRenamed() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks(), baseline = scene.baseline()
        let output = scene.root.appendingPathComponent("image.jpg")
        try Data("exported image".utf8).write(to: output)
        func recipe(_ masks: MaskSet, notes: MaskNotes = .none, previous: Recipe? = nil) throws -> Recipe {
            try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(masks: masks), baseline: baseline, maskNotes: notes), previous: previous)
        }
        var developed = try recipe(set)
        developed.develops.append(.init(date: Date(timeIntervalSince1970: 2000), software: "Argent test", output: OutputSettings(), file: output.path, width: 40, height: 20,
            render: developed.render, decode: DecodePins.testPins, readback: nil, stockDigest: scene.stock.digest,
            renderVersion: RenderGraph.version(for: developed.render.settings), outputSource: SourceStamp.of(output)))
        let read = try Recipe.decodeStrict(try developed.encoded())
        #expect(read.lastDevelopMatches(file: output, output: OutputSettings()), "a digest in the receipt still matches its render")
        #expect(try recipe(set, notes: scene.notes(name: "Renamed"), previous: read).lastDevelopMatches(file: output, output: OutputSettings()))
        var slid = set.masks[0]
        slid.adjustments = try slid.adjustments.setting(.exposure, to: -0.9)
        #expect(!(try recipe(try set.replacing(slid), previous: read)).lastDevelopMatches(file: output, output: OutputSettings()))
        var scaled = set.masks[0]
        scaled.amount = 0.5
        #expect(!(try recipe(try set.replacing(scaled), previous: read)).lastDevelopMatches(file: output, output: OutputSettings()))
        var unmade = set.masks[0]
        unmade.components = [MaskComponent(shape: .smart(SmartSelection(kind: .sky)))]
        #expect(!(try recipe(try set.replacing(unmade), previous: read)).lastDevelopMatches(file: output, output: OutputSettings()))
        // A develop made before the masks does not stand for the frame with them.
        var plain = try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.25), baseline: baseline))
        plain.develops.append(.init(date: Date(timeIntervalSince1970: 2000), software: "Argent test", output: OutputSettings(), file: output.path, width: 40, height: 20,
            render: plain.render, decode: DecodePins.testPins, readback: nil, stockDigest: scene.stock.digest,
            renderVersion: RenderGraph.version(for: plain.render.settings), outputSource: SourceStamp.of(output)))
        #expect(plain.lastDevelopMatches(file: output, output: OutputSettings()))
        let added = try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.25, masks: set), baseline: baseline), previous: plain)
        #expect(!added.lastDevelopMatches(file: output, output: OutputSettings()))
    }

    /// The resolver is where preview, comparison and export meet: an old edit cannot take a mask, and a new one carries them.
    @Test func theResolverRefusesMasksOnOlderLightCompilersAndCarriesThemOnTheCurrentOne() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks(), baseline = scene.baseline(), regions = ManualRenderSettings.regionsVersion
        let plainOld = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5), baseline: baseline, curveVersion: regions)
        #expect(try scene.settings(plainOld).manual.version == regions)
        let old = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.5, masks: set), baseline: baseline, curveVersion: regions)
        #expect(throws: MaskError.lightCompiler(regions)) { try scene.settings(old) }
        let exposedBase = ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: baseline, curveVersion: ManualRenderSettings.exposedBaseVersion)
        #expect(throws: MaskError.lightCompiler(ManualRenderSettings.exposedBaseVersion)) { try scene.settings(exposedBase) }
        for version in [ManualRenderSettings.currentVersion] {
            let edit = ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: baseline, curveVersion: version)
            let settings = try scene.settings(edit)
            #expect(settings.manual.version == version && settings.manual.adjustments.masks == set)
            #expect(RenderGraph.version(for: settings).hasSuffix("+manual-\(version)+masks-\(MaskSet.currentVersion)"))
        }
    }
}

@Suite struct MaskDevelopTests {
    /// Through the real developer, whose stand-in raw cannot be decoded: a skip decodes nothing, and a develop made again fails there.
    @Test func anUnchangedFrameWithMasksIsSkippedARenameTooAndAChangeIsMadeAgain() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let set = try Scene.masks(), baseline = scene.baseline()
        let file = scene.root.appendingPathComponent("frame.jpg")
        try Data("developed".utf8).write(to: file)
        let developer = try RollDeveloper(stocks: [scene.stock], software: "Argent test", library: scene.library,
                                          digests: SourceDigests(settle: 0), decoderChoices: DecoderChoices(route: .apple))
        let made = try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(masks: set), baseline: baseline))
        // The receipt as a saved record holds it: a digest, read back.
        var written = made
        written.develops = [.init(date: Date(timeIntervalSince1970: 2000), software: "Argent test", output: OutputSettings(), file: file.path, width: 40, height: 20,
                                  render: made.render, decode: DecodePins.testPins, readback: nil, stockDigest: scene.stock.digest,
                                  renderVersion: RenderGraph.version(for: made.render.settings))]
        let receipts = try Recipe.decodeStrict(try written.encoded()).develops
        #expect(receipts[0].render.manual?.adjustments.masks.isDigestOnly == true)
        func job(_ masks: MaskSet, notes: MaskNotes = .none) throws -> RollDeveloper.Job {
            var recipe = try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(masks: masks), baseline: baseline, maskNotes: notes))
            recipe.develops = receipts
            return RollDeveloper.Job(frame: scene.frame, recipe: recipe)
        }
        #expect(await developer.develop([try job(set)], to: scene.root, output: OutputSettings()) == [.alreadyDeveloped(file)])
        #expect(await developer.develop([try job(set, notes: scene.notes(name: "Renamed"))], to: scene.root, output: OutputSettings()) == [.alreadyDeveloped(file)])
        var slid = set.masks[0]
        slid.amount = 0.5
        let outcomes = await developer.develop([try job(try set.replacing(slid))], to: scene.root, output: OutputSettings())
        guard case .failed = outcomes[0] else {
            Issue.record("A changed mask must be developed again, and the stand-in cannot be decoded: \(outcomes)")
            return
        }
    }
}

private extension DecodePins {
    /// The pins this build records for a full-size decode: a develop compares their versions.
    static var testPins: DecodePins {
        DecodePins(version: DecodePins.currentVersion, decoderVersion: AppleRawDecoder.pinnedDecoderVersion, baselineExposure: 0, shadowBias: 0, sharpness: 0,
                   boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true, extendedDynamicRange: 1,
                   neutralChromaticity: .init(x: 0.33, y: 0.35), moireReduction: nil, contrast: 0, detail: 0,
                   anchorDecodedMidTone: 0.08, anchorVersion: "1", exposureGainStops: 1, luminanceNoiseReduction: 0.4,
                   colorNoiseReduction: 0.5, lensCorrection: true, scale: 1, draftMode: false)
    }
}

/// A smart selection's Feather (decision 19) through recipe v6: written only where it is set, with the masks schema 2 that makes a
/// build from before Feather refuse the record and keep it rather than print the mask without it; read back exactly, through the
/// writer's own commit and load, into the render it resolves to.
@Suite struct MaskFeatherRecipeTests {
    private static func feathered(_ set: MaskSet, _ feather: Float) throws -> MaskSet {
        var sky = set.masks[0]
        guard case .smart(var selection) = sky.components[0].shape else { throw MaskError.invalid("the fixture's first mask is Sky") }
        selection.feather = feather
        sky.components[0].shape = .smart(selection)
        return try set.replacing(sky)
    }

    @Test func aFeatheredSkyRoundTripsThroughRecipeVersion6() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let plain = try Scene.masks(), set = try Self.feathered(plain, 35)
        let edit = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3, masks: set), baseline: scene.baseline(), maskNotes: scene.notes())
        let recipe = try scene.recipe(edit, receipts: 2)
        #expect(recipe.version == 6 && recipe.requiredVersion == 6)
        let bytes = try recipe.encoded(), text = String(decoding: bytes, as: UTF8.self)
        // In the edit and in its resolved render; receipts keep the digest, which an older build may read.
        #expect(text.components(separatedBy: "\"feather\" : 35").count - 1 == 2)
        #expect(text.components(separatedBy: "\"schema\" : 2").count - 1 == 2 && text.components(separatedBy: "\"schema\" : 1").count - 1 == 2)
        let read = try Recipe.decodeStrict(bytes)
        #expect(read == recipe && read.manual?.adjustments.masks.masks == set.masks && read.render.manual?.adjustments.masks == set)
        #expect(try read.encoded() == bytes)
        let saved = try await scene.writer.commit(recipe: recipe, for: scene.frame, library: scene.library)
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        #expect(saved.manual?.adjustments.masks == set && loaded?.manual?.adjustments.masks.masks == set.masks)
        guard case .smart(let selection) = loaded?.manual?.adjustments.masks.masks[0].components[0].shape else { Issue.record("no Sky"); return }
        #expect(selection.feather == 35)
        // The render resolves with it, and a Feather moves what a develop compares, as a shape does.
        #expect(try scene.settings(read.manual).manual.adjustments.masks == set)
        #expect(try scene.settings(read.manual) != scene.settings(ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3, masks: plain), baseline: scene.baseline())))
        // Without a Feather the same edit is schema 1 and names no feather: the bytes a build from before Feather wrote and reads.
        let before = String(decoding: try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3, masks: plain), baseline: scene.baseline(),
                                                                  maskNotes: scene.notes()), receipts: 2).encoded(), as: UTF8.self)
        func feathers(_ text: String) -> Int { text.components(separatedBy: "\"feather\" :").count - 1 }   // the radial's and strokes' too
        #expect(!before.contains("\"schema\" : 2") && feathers(before) == feathers(text) - 2)
    }
}

/// A selection's edge (masks schema 4) through recipe v6: written only for a `crisp` or `matte` selection, read back exactly, through the writer's own
/// commit and load, into the render it resolves to; a build that cannot read 4 refuses and keeps the record, as a schema it does not know.
@Suite struct SmartEdgeRecipeTests {
    private static func edged(_ set: MaskSet, _ edge: SmartEdge) throws -> MaskSet {
        var sky = set.masks[0]
        guard case .smart(var selection) = sky.components[0].shape else { throw MaskError.invalid("the fixture's first mask is a selection") }
        selection.kind = .subject
        selection.edge = edge
        sky.components[0].shape = .smart(selection)
        return try set.replacing(sky)
    }

    @Test func aMatteSelectionRoundTripsThroughRecipeVersion6() async throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let plain = try Self.edged(try Scene.masks(), .guided), set = try Self.edged(try Scene.masks(), .matte)
        let edit = ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3, masks: set), baseline: scene.baseline(), maskNotes: scene.notes())
        let recipe = try scene.recipe(edit, receipts: 2)
        #expect(recipe.version == 6 && recipe.requiredVersion == 6)
        let bytes = try recipe.encoded(), text = String(decoding: bytes, as: UTF8.self)
        // In the edit and its resolved render, schema 4; a receipt keeps the digest, which an older build may read.
        #expect(text.components(separatedBy: "\"edge\" : \"matte\"").count - 1 == 2)
        #expect(text.components(separatedBy: "\"schema\" : 4").count - 1 == 2 && text.components(separatedBy: "\"schema\" : 1").count - 1 == 2)
        let read = try Recipe.decodeStrict(bytes)
        #expect(read == recipe && read.manual?.adjustments.masks.masks == set.masks && read.render.manual?.adjustments.masks == set)
        #expect(try read.encoded() == bytes)
        _ = try await scene.writer.commit(recipe: recipe, for: scene.frame, library: scene.library)
        let loaded = try await scene.writer.load(for: scene.frame, library: scene.library)
        guard case .smart(let selection) = loaded?.manual?.adjustments.masks.masks[0].components[0].shape else { Issue.record("no selection"); return }
        #expect(selection.edge == .matte)
        // A shape's edge moves what a develop compares; the same edit on today's edge names no edge and keeps its schema.
        #expect(try scene.settings(read.manual) != scene.settings(ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3, masks: plain), baseline: scene.baseline())))
        let before = String(decoding: try scene.recipe(ManualEdit(adjustments: try ManualAdjustments(exposureEV: 0.3, masks: plain), baseline: scene.baseline(), maskNotes: scene.notes()), receipts: 2).encoded(), as: UTF8.self)
        #expect(!before.contains("\"edge\"") && !before.contains("\"schema\" : 4"))
    }
}
