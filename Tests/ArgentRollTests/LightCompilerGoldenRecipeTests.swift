import ArgentCore
import CryptoKit
import Foundation
import Testing
@testable import ArgentRoll

/// Recipes keep their bytes across a Light compiler: what a recipe holds is only its edit's recorded
/// compiler, so one with no edit does not name a compiler at all, and an edit recorded on an older
/// compiler reads and writes as it did. The digests are `Recipe.encoded()` at recipe version 5 on main,
/// before `2026-11-06-1` (research R6's `golden-v5.txt`, and this suite on main at 3f67969).
@Suite struct LightCompilerGoldenRecipeTests {
    private struct Scene {
        let root: URL
        let frame: Frame
        let stock: Stock
        let sha: String
        let aim = PrintAim(level: -0.3, cast: SIMD3(0.1, -0.05, -0.05))
        let controls = RollControls()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ArgentGolden-\(UUID().uuidString)")
            let roll = root.appendingPathComponent("roll", isDirectory: true)
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            let raw = roll.appendingPathComponent("frame.ARW")
            try Data(repeating: 71, count: 4096).write(to: raw)
            frame = Frame(id: 0, url: raw, info: ARWFrameInfo(captureDate: Date(timeIntervalSince1970: 1000)))
            stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
            sha = try SourceDigests(settle: 0).digest(of: raw).sha256
        }

        func baseline(origin: AutomaticBaseline.Origin = .auto) -> AutomaticBaseline {
            let aim = origin == .original ? PrintAim() : self.aim
            return AutomaticBaseline(sourceSHA256: sha, stockID: stock.id, stockDigest: stock.digest, controls: controls, aim: aim,
                                     analysisVersion: ExposureAnalysis.currentVersion,
                                     baseRender: Recipe.Render(settings: controls.settings(for: stock, aim: aim), grain: .off), origin: origin)
        }

        /// A recipe with fixed revision, lineage and receipts, so its bytes are the same on every run.
        func recipe(_ manual: ManualEdit?, held: ManualEdit? = nil, aim override: PrintAim? = nil, receipts: Int = 0) throws -> Recipe {
            var recipe = try Recipe.make(frame: frame, byteCount: 4096, stock: stock, stockDigest: stock.digest, roll: controls, own: FrameControls(),
                                         analysis: ExposureAnalysis(meanStops: -0.3, validWeight: 1), aim: override ?? aim, grain: .off,
                                         manual: manual, editRevision: 12, editLineage: "golden-lineage", heldManual: held)
            recipe.raw.sha256 = sha
            for i in 0..<receipts {
                recipe.develops.append(Recipe.Develop(date: Date(timeIntervalSince1970: 3000 + Double(i)), software: "Argent test", output: OutputSettings(),
                    file: "/tmp/out/frame\(i).jpg", width: 40, height: 20, render: recipe.render, decode: nil, readback: nil,
                    stockDigest: stock.digest, renderVersion: RenderGraph.version(for: recipe.render.settings)))
            }
            return recipe
        }

        /// The six shapes, each edit on `compiler`, or on what a new edit takes when it is nil.
        func shapes(compiler: String?) throws -> [(name: String, recipe: Recipe)] {
            let light = try ManualAdjustments(exposureEV: 0.7, contrast: 10, highlights: -20)
            let curves = try ManualAdjustments(exposureEV: 0.2, curves: ToneCurves(tone: ToneCurves.Preset.softContrast.curve))
            let toneAim = PrintAim(level: -0.3, cast: SIMD3(0.1, -0.05, -0.05), burn: 0.6, dodge: 0.4)
            func edit(_ values: ManualAdjustments, origin: AutomaticBaseline.Origin = .auto) -> ManualEdit {
                compiler.map { ManualEdit(adjustments: values, baseline: baseline(origin: origin), curveVersion: $0) }
                    ?? ManualEdit(adjustments: values, baseline: baseline(origin: origin))
            }
            return [
                ("automatic, no edit", try recipe(nil)),
                ("Light only", try recipe(edit(light))),
                ("curves", try recipe(edit(curves))),
                ("identity Original", try recipe(edit(.identity, origin: .original))),
                ("tone step", try recipe(nil, aim: toneAim)),
                ("Light, held edit, 20 receipts", try recipe(edit(light), held: edit(curves), receipts: 20)),
            ]
        }
    }

    private static let digests: [String: String] = [
        "automatic, no edit": "da15261c498d4c59de99d1d709d59c9936f6590dca90038d89356ae7762da247",
        "Light only": "4270e061aafc1576421de5a717bc28629491f519cfd67d3c2daeff51b2dba9ac",
        "curves": "d8c9eeb07a5245e1c3b98b47c5e932334c3aa784739797c8dba40f89caf9833b",
        "identity Original": "a948c984ea4660f2524a062d3d1babfdc257a58fc77c9491b29b08753cde68cb",
        "tone step": "2b09c6407d9977574204d590359d08252894972946e3bfa22bd2ad9ad2871e0d",
        "Light, held edit, 20 receipts": "d002fac6f9f804358958d03c114e2ccc98f9a87c02f645a4c655a0210ae8919d",
    ]

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Written fresh, and read and written again.
    @Test func recipesOnTheRecordedCompilerKeepTheirBytes() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        for (name, recipe) in try scene.shapes(compiler: "2026-10-29-1") {
            let bytes = try recipe.encoded()
            #expect(Self.sha256(bytes) == Self.digests[name], "\(name)")
            #expect(Self.sha256(try Recipe.decodeStrict(bytes).encoded()) == Self.digests[name], "\(name), read and written again")
        }
    }

    /// A new edit takes the current compiler, and that is all that changes in its recipe. A recipe with
    /// no edit does not name one, so its bytes do not move at all.
    @Test func aNewEditDiffersOnlyInItsCompilerAndNoEditNotAtAll() throws {
        let scene = try Scene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let current = ManualRenderSettings.currentVersion
        for (name, recipe) in try scene.shapes(compiler: nil) {
            let bytes = try recipe.encoded(), text = String(decoding: bytes, as: UTF8.self)
            let recorded = text.replacingOccurrences(of: current, with: "2026-10-29-1")
            #expect(Self.sha256(Data(recorded.utf8)) == Self.digests[name], "\(name)")
            #expect(try Recipe.decodeStrict(bytes).encoded() == bytes, "\(name), read and written again")
            if recipe.manual == nil {
                #expect(Self.sha256(bytes) == Self.digests[name], "\(name)")
                #expect(!text.contains(current), "\(name)")
            } else {
                #expect(recipe.manual?.curveVersion == current && text.contains(current), "\(name)")
            }
        }
    }
}
