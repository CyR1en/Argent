import Foundation
import Testing
@testable import ArgentCore

/// Synthetic seeds and water maps: the veto takes arrays, so no test here runs a model.
private enum Scene {
    static let model = ModelProvenance(recipeID: "test-recipe", weightsSHA256: String(repeating: "a", count: 64),
                                       canarySHA256: String(repeating: "b", count: 64), fileSHA256: String(repeating: "c", count: 64))
    static func seed(_ width: Int, _ height: Int, _ value: (Int, Int) -> Float) throws -> SkySeed {
        try SkySeed(width: width, height: height, values: (0..<(width * height)).map { value($0 % width, $0 / width) }, model: model)
    }
    /// A water map over a square `side × 4` input holding a `width` × `height` picture at `originY`, as EoMT's layout puts a
    /// landscape; by default the picture fills the square.
    static func water(side: Int, width: Int? = nil, height: Int? = nil, originY: Int = 0, _ value: (Int, Int) -> Float) throws -> WaterMap {
        try WaterMap(side: side, values: (0..<(side * side)).map { value($0 % side, $0 / side) }, square: side * 4,
                     contentWidth: width ?? side * 4, contentHeight: height ?? side * 4, originX: 0, originY: originY, model: model,
                     mapsSHA256: String(repeating: "d", count: 64))
    }
    static func score(_ value: Float) -> WaterScore { WaterScore(labels: ["lake": value, "river": value / 2]) }
}

@Suite struct WaterVetoTests {
    /// S5 section 4's constants, pinned by name: a change of any is a new veto version.
    @Test func theConstantsAreS5s() {
        #expect(WaterGate.threshold == 0.03 && WaterVeto.gate == 0.03)
        #expect(WaterVeto.selected == 0.5 && WaterVeto.waterThreshold == 0.5 && WaterVeto.minimumShare == 0.01)
        #expect(WaterVeto.opening == 3 && WaterVeto.fringeRadius == 6 && SkySeed.clip == 0.6)
        #expect(WaterVeto.version == "water-veto-1")
        #expect(WaterGate.identifiers == ["water_body", "lake", "river", "ocean", "harbour", "waterways", "creek", "wetland"])
        #expect(SmartSeed.selectedLevel == 128)
    }

    /// Below the gate the water map is never asked for, so EoMT never loads, and the seed comes back as it was; at the gate it is.
    @Test func belowTheGateNothingLoads() async throws {
        let seed = try Scene.seed(64, 48) { _, y in y < 24 ? 1 : 0.9 }
        let calls = Counter()
        for score in [Float(0), 0.01, 0.029, 0.0299999] {
            let (out, decision) = await WaterVeto.apply(to: seed, gate: Scene.score(score)) {
                calls.add()
                return try! Scene.water(side: 16) { _, _ in 1 }
            }
            #expect(out == seed && !decision.ran && !decision.fired && decision.removedPixels == 0 && decision.waterModel == nil)
            #expect(decision.seedBefore == WaterVeto.quantize(seed.values, width: 64, height: 48).identity)
        }
        #expect(calls.value == 0)
        let (_, atGate) = await WaterVeto.apply(to: seed, gate: Scene.score(0.03)) {
            calls.add()
            return try! Scene.water(side: 16) { _, _ in 0 }
        }
        #expect(calls.value == 1 && atGate.ran && !atGate.fired)
        // A failing model fails the click; it is not taken for "no water".
        await #expect(throws: MaskError.self) {
            _ = try await WaterVeto.apply(to: seed, gate: Scene.score(0.5)) { throw MaskError.invalid("no model") }
        }
    }

    /// The gate's score is the largest of the water labels, and only theirs.
    @Test func theGateReadsTheWaterLabels() {
        #expect(WaterGate.score(["lake": 0.02, "ocean": 0.04, "sky": 0.9]) == 0.04)
        #expect(WaterGate.score(["sky": 0.9]) == 0 && WaterGate.score([:]) == 0)
        #expect(!WaterScore(labels: ["creek": 0.0299]).passes && WaterScore(labels: ["creek": 0.03]).passes)
        #expect(WaterScore(labels: ["wetland": 0.2]).labels.count == WaterGate.identifiers.count)
    }

    /// The fringe is OpenCV's 13 × 13 `MORPH_ELLIPSE`, row by row, as S5's reference used it.
    @Test func theFringeIsOpenCVsEllipse() {
        #expect(WaterVeto.ellipseHalfWidths(radius: 6) == [0, 3, 4, 5, 6, 6, 6, 6, 6, 5, 4, 3, 0])
        let one = (0..<(15 * 15)).map { $0 == 7 * 15 + 7 }
        let grown = WaterVeto.dilateEllipse(one, width: 15, height: 15, radius: 6)
        #expect(grown.filter { $0 }.count == [0, 3, 4, 5, 6, 6, 6, 6, 6, 5, 4, 3, 0].reduce(0) { $0 + 2 * $1 + 1 })
        #expect(grown[1 * 15 + 7] && !grown[1 * 15 + 6] && !grown[0 * 15 + 7])
    }

    /// The opening drops specks and keeps a block; the candidates act only from 1 % of the seed's pixels.
    @Test func theOpeningAndTheOnePercentMinimum() throws {
        let w = 100, h = 100
        let seed = [Float](repeating: 1, count: w * h)
        func water(_ on: (Int, Int) -> Bool) -> [Float] { (0..<(w * h)).map { on($0 % w, $0 / w) ? 1 : 0 } }
        // A 10 × 10 block is exactly 1 % and fires; 9 × 11 is 0.99 % and does not.
        let block = WaterVeto.candidates(seed: seed, water: water { (40..<50).contains($0) && (60..<70).contains($1) }, width: w, height: h)
        #expect(block.share == 0.01 && block.mask.filter { $0 }.count == 100)
        let short = WaterVeto.candidates(seed: seed, water: water { (40..<49).contains($0) && (60..<71).contains($1) }, width: w, height: h)
        #expect(abs(short.share - 0.0099) < 1e-12 && !short.mask.contains(true))
        // Speckle and a two-pixel line vanish in the opening, whatever their total.
        let specks = WaterVeto.candidates(seed: seed, water: water { ($0 % 3 == 0 && $1 % 3 == 0) || $1 == 90 && $0 < 2 }, width: w, height: h)
        #expect(specks.share == 0 && !specks.mask.contains(true))
        // Unselected pixels are never candidates, however wet.
        let soft = WaterVeto.candidates(seed: [Float](repeating: 0.49, count: w * h), water: water { _, _ in true }, width: w, height: h)
        #expect(soft.share == 0)
        // The picture's edge counts as set in the erosion, so a block on the border keeps its edge rows.
        let edge = WaterVeto.candidates(seed: seed, water: water { _, y in y >= 90 }, width: w, height: h)
        #expect(edge.share == 0.1 && edge.mask[99 * w] && edge.mask[90 * w + 50] && !edge.mask[89 * w + 50])
    }

    /// When it fires: the vetoed pixels go, the unselected ones within the ellipse of them go, selected sky beside them stays,
    /// and every seed value on water goes, however far from the veto.
    @Test func firingClearsTheFringeAndTheSoftSeedOnWater() {
        let w = 60, h = 40
        var seed = [Float](repeating: 0, count: w * h), water = [Float](repeating: 0, count: w * h), veto = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            seed[i] = y < 10 ? 1 : 0.3                  // sky above, a soft seed below
            if (20..<30).contains(y) && (20..<30).contains(x) { seed[i] = 0.9; water[i] = 0.9; veto[i] = true }
            if y == 35 && x == 5 { water[i] = 0.5 }      // soft seed on water, far from the veto
            if y == 36 && x == 5 { water[i] = 0.4999 }   // just dry
        } }
        let out = WaterVeto.clear(seed: seed, veto: veto, water: water, width: w, height: h)
        #expect(out[25 * w + 25] == 0)                              // vetoed
        #expect(out[25 * w + 31] == 0 && out[25 * w + 35] == 0)    // unselected, inside the fringe (6 px)
        #expect(out[25 * w + 36] == 0.3)                            // 7 px out
        #expect(out[14 * w + 29] == 0 && out[14 * w + 30] == 0.3)  // six rows up the ellipse is one pixel wide
        #expect(out[15 * w + 32] == 0 && out[15 * w + 33] == 0.3)  // five rows up, three pixels out
        #expect(out[5 * w + 25] == 1)                               // sky stays
        #expect(out[35 * w + 5] == 0 && out[36 * w + 5] == 0.3)    // the soft clear, at water ≥ 0.5 only
        // Nothing fired, nothing cleared, the soft clear included.
        #expect(WaterVeto.clear(seed: seed, veto: [Bool](repeating: false, count: w * h), water: water, width: w, height: h) == seed)
    }

    /// The water map is read at each seed pixel's centre through the picture's rectangle in the square, edges replicated.
    @Test func theWaterMapIsReadThroughThePicturesRectangle() throws {
        // A 192 grid over a 768 square holding a 768 × 512 picture from row 128, as EoMT's layout does for 3:2.
        let side = 192
        let map = try WaterMap(side: side, values: (0..<(side * side)).map { Float($0 / side) }, square: 768, contentWidth: 768,
                               contentHeight: 512, originX: 0, originY: 128, model: Scene.model, mapsSHA256: "")
        let out = WaterVeto.resample(map, toWidth: 756, height: 504)
        // Row i's centre is at square row 128 + (i + 0.5) × 512 / 504, map row that / 4 − 0.5; the map's value is its row.
        for i in [0, 1, 250, 503] {
            let expected = Float((128 + (Double(i) + 0.5) * 512 / 504) / 4 - 0.5)
            #expect(abs(out[i * 756 + 17] - expected) < 1e-4, "row \(i)")
        }
        #expect(throws: MaskError.self) {
            try WaterMap(side: side, values: [], square: 768, contentWidth: 768, contentHeight: 512, originX: 0, originY: 128,
                         model: Scene.model, mapsSHA256: "")
        }
        #expect(throws: MaskError.self) {
            try WaterMap(side: side, values: map.values, square: 768, contentWidth: 768, contentHeight: 700, originX: 0, originY: 128,
                         model: Scene.model, mapsSHA256: "")
        }
    }

    /// A reflection under a sky: the veto takes the reflection and leaves the sky, and records what it did.
    @Test func aReflectionGoesAndTheSkyStays() async throws {
        let w = 96, h = 64
        // Sky in the top third, a bank in the middle, the sky's reflection in the bottom third.
        let seed = try Scene.seed(w, h) { _, y in y < 21 ? 1 : y < 43 ? 0.1 : 0.8 }
        // EoMT's grid is 24 over a 96 square, the picture from square row 16: map row 12 and down is water, from picture row
        // 30 or so, under the bank's top and over the whole reflection.
        let water = { try Scene.water(side: 24, width: w, height: h, originY: 16) { _, y in y >= 12 ? 0.95 : 0 } }
        let (out, decision) = try await WaterVeto.apply(to: seed, gate: Scene.score(0.2), water: water)
        #expect(decision.ran && decision.fired && decision.waterModel == Scene.model && decision.mapsSHA256 == String(repeating: "d", count: 64))
        #expect(out.values[10 * w + 40] == 1 && out.values[20 * w + 40] == 1)
        #expect(!out.values[(43 * w)...].contains { $0 > 0 })
        #expect(!out.values[(37 * w)..<(43 * w)].contains { $0 > 0 })   // the bank's soft seed in the fringe and on water
        #expect(decision.removedSelectedShare == Double(21 * w) / Double(w * h))
        #expect(decision.removedPixels == 21 * w)
        #expect(decision.seedBefore == WaterVeto.quantize(seed.values, width: w, height: h).identity)
        // The provenance holds the decision, and gives it back.
        #expect(WaterVeto.Decision(parameters: decision.parameters) == decision)
        #expect(decision.parameters["veto.constants"] == WaterVeto.constants)
        // A seed that keeps nothing selected is "No sky found", a result.
        let mirror = try Scene.seed(w, h) { _, _ in 0.8 }
        let (gone, all) = try await WaterVeto.apply(to: mirror, gate: Scene.score(0.2)) {
            try Scene.water(side: 24, width: w, height: h, originY: 16) { _, _ in 0.9 }
        }
        #expect(all.fired && !gone.values.contains { $0 > 0 })
    }

    /// The seed's quantization is S5's: half to even, clamped.
    @Test func aSeedIsStoredInEightBits() throws {
        let raster = WaterVeto.quantize([0, 0.5, 1, 0.25, 1.5 / 255, 2.5 / 255] + [Float](repeating: 0, count: 250), width: 16, height: 16)
        #expect(Array(raster.plane.prefix(6)) == [0, 128, 255, 64, 2, 2])
        #expect(throws: MaskError.self) { try SkySeed(width: 4, height: 4, values: [Float](repeating: 0, count: 16), model: Scene.model) }
        #expect(throws: MaskError.self) { try SkySeed(width: 16, height: 16, values: [Float](repeating: 1.5, count: 256), model: Scene.model) }
        let head = try SkySeed(skyHead: [-0.2, 0, 0.3, 0.6, 0.9, .nan] + [Float](repeating: 0, count: 250), width: 16, height: 16, model: Scene.model)
        #expect(Array(head.values.prefix(6)) == [0, 0, 0.5, 1, 1, 0])
    }
}

/// S5's golden masks (`out/golden_sq768_t05` in `P0-S5-eomt`'s evidence): per frame the seed, the water map on the seed grid,
/// the veto and the vetoed seed from the Python (OpenCV) reference, and EoMT's raw map with its geometry. They come from
/// private frames, so they stay out of the repository: set `ARGENT_WATER_VETO_GOLDEN` to the folder, or put it at
/// `references/masks/water-veto-golden`.
@Suite struct WaterVetoGoldenTests {
    static let folder: URL? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [ProcessInfo.processInfo.environment["ARGENT_WATER_VETO_GOLDEN"].map { URL(fileURLWithPath: $0) },
                          root.appendingPathComponent("references/masks/water-veto-golden")].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DSC04073.meta.json").path) }
    }()

    /// The plan's canary (section 8): the veto must fire on 4908, a1017 and DSC04073, removing about 29, 4.7 and 1.2 % of the
    /// frame, here within a tenth of each, and not on DSC04064; nor on DSC04100 and DSC04091, which S5 also kept.
    static let removed: [String: ClosedRange<Double>] = [
        "Y-JG-A7-IV-FE-24-105-4908": 0.261...0.319, "a1017-kme_427": 0.0423...0.0517, "DSC04073": 0.0108...0.0132,
        "DSC04064": 0...0, "DSC04100": 0...0, "DSC04091": 0...0,
    ]

    @Test(.enabled(if: WaterVetoGoldenTests.folder != nil))
    func s5sGoldenMasksPassPixelForPixel() async throws {
        let folder = try #require(Self.folder)
        let ids = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".meta.json") }
            .map { String($0.dropLast(".meta.json".count)) }.sorted()
        #expect(ids.count == 11)
        func floats(_ name: String) throws -> [Float] {
            try Data(contentsOf: folder.appendingPathComponent(name)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        for id in ids {
            let meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("\(id).meta.json"))) as? [String: Any])
            let w = try #require(meta["w"] as? Int), h = try #require(meta["h"] as? Int)
            let geo = try #require(meta["geo"] as? [String: Any])
            #expect(meta["thr"] as? Double == 0.5)
            let seed = try floats("\(id).seed.f32"), water = try floats("\(id).waterseed.f32"), out = try floats("\(id).out.f32")
            let veto = try Data(contentsOf: folder.appendingPathComponent("\(id).veto.u8")).map { $0 != 0 }
            #expect(seed.count == w * h && water.count == w * h && veto.count == w * h)

            // The veto, on the reference's own water map.
            let (mask, _) = WaterVeto.candidates(seed: seed, water: water, width: w, height: h)
            #expect(zip(mask, veto).filter { $0 != $1 }.count == 0, "\(id): veto pixels")
            #expect(mask.filter { $0 }.count == meta["veto_pixels"] as? Int, "\(id)")
            // The cleared seed: the reference's, plus the soft clear on water when it fired (S5's `apply_veto_soft`).
            let fired = veto.contains(true)
            let expected = zip(out, water).map { fired && $1 >= WaterVeto.waterThreshold ? 0 : $0 }
            let cleared = WaterVeto.clear(seed: seed, veto: mask, water: water, width: w, height: h)
            #expect(cleared == expected, "\(id): cleared seed")

            // EoMT's own map through the resample: within 1e-5 of OpenCV's, no pixel across 0.5, and the same veto.
            let raw = try floats("\(id).waterraw.f32")
            let side = Int(Double(raw.count).squareRoot().rounded())
            let map = try WaterMap(side: side, values: raw, square: try #require(geo["H"] as? Int),
                                   contentWidth: try #require(geo["w"] as? Int), contentHeight: try #require(geo["h"] as? Int),
                                   originX: try #require(geo["left"] as? Int), originY: try #require(geo["top"] as? Int),
                                   model: Scene.model, mapsSHA256: "")
            let resampled = WaterVeto.resample(map, toWidth: w, height: h)
            let worst = zip(resampled, water).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < 1e-5, "\(id): resample off by \(worst)")
            #expect(zip(resampled, water).filter { ($0 >= 0.5) != ($1 >= 0.5) }.isEmpty, "\(id): resample crosses 0.5")
            #expect(WaterVeto.candidates(seed: seed, water: resampled, width: w, height: h).mask == mask, "\(id)")

            // The whole step, behind the gate, as the app runs it.
            let score = WaterScore(labels: ["lake": Float(try #require(meta["ws"] as? Double))])
            let (after, decision) = await WaterVeto.apply(to: try SkySeed(width: w, height: h, values: seed, model: Scene.model),
                                                          gate: score) { map }
            #expect(decision.fired == (score.passes && fired), "\(id)")
            if score.passes { #expect(after.values == expected, "\(id)") } else { #expect(after.values == seed, "\(id)") }
            let selectedBefore = seed.filter { $0 >= 0.5 }.count, selectedAfter = after.values.filter { $0 >= 0.5 }.count
            let share = Double(selectedBefore - selectedAfter) / Double(w * h)
            #expect(abs(share - decision.removedSelectedShare) < 1e-12)
            if let range = Self.removed[id] { #expect(range.contains(share), "\(id): removed \(share)") }
            // The reference's own removal, before the soft clear, as S5's tables give it.
            let reference = Double(selectedBefore - out.filter { $0 >= 0.5 }.count) / Double(w * h)
            print("MEASURE water veto golden \(id): \(w)x\(h) gate \(score.score) veto px \(mask.filter { $0 }.count) "
                  + String(format: "removed %.4f%% of the frame (reference before the soft clear %.4f%%), soft mass %.4f%%, resample within %.2e",
                           share * 100, reference * 100, decision.removedSoftShare * 100, worst))
        }
    }
}

/// A count the closures below can bump from any isolation.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
