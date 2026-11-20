import Foundation
import Testing
@testable import ArgentCore

/// Clarity's and Texture's tone weights are `fit_texture_clarity.py`'s `weight_at` at the CIE L* the stock's neutral transfer gives
/// each sample (design/synthesis.md, Decisions closed here), on the grid the Light tables use.
@Suite struct PresenceToneWeightsTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let fitScript = """
        import json, sys
        from pathlib import Path
        root, version = Path(sys.argv[1]), sys.argv[2]
        sys.path.insert(0, str(root / "scripts" / "lightroom-probe"))
        import fit_texture_clarity
        inputs = root / "scripts" / "presence" / version
        clarity = json.loads((inputs / "clarity-round2.json").read_text())["recommendation"]["clarity-guided"]
        texture = json.loads((inputs / "texture-clarity.json").read_text())["candidates"]["texture-guided-band"]
        sides = {"clarityPositive": clarity["positive"], "clarityNegative": clarity["negative"],
                 "texturePositive": texture["positive"], "textureNegative": texture["negative"]}
        json.dump([{name: fit_texture_clarity.weight_at(s, lstar).tolist() for name, s in sides.items()}
                   for lstar in json.load(sys.stdin)], sys.stdout)
        """

    private static func fitWeights(_ lightness: [[Float]], version: String) throws -> [[String: [Double]]] {
        let python = root.appendingPathComponent(".venv/bin/python")
        try #require(FileManager.default.isExecutableFile(atPath: python.path), "the repository's .venv with numpy (docs/ci-regression.md)")
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-c", fitScript, root.path, version]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(lightness.map { $0.map(Double.init) }))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(String(decoding: failure, as: UTF8.self))")
        return try JSONDecoder().decode([[String: [Double]]].self, from: data)
    }

    private static func stocks() throws -> [Stock] {
        let baked = try ["kodak-portra-400", "kodak-ektar-100"].map { id in
            try Stock.load(from: try #require(LightCompilerBaselineTests.bakedStocks.first { $0.lastPathComponent == id }, "build/stocks/\(id)"))
        }
        return [LightCompilerBaselineTests.toyStock()] + baked
    }

    private static let renders: [(referenceStops: Float, settings: DevelopSettings)] = [
        (0, DevelopSettings()),
        (0.6, DevelopSettings(ratedAt: 200, labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3)),
    ]

    @Test func eachTableIsTheFitScriptsWeightAtTheTransfersLightness() throws {
        let constants = try #require(PresenceConstants.named(Presence.currentVersion))
        var cases: [(label: String, weights: PresenceToneWeights, lightness: [Float])] = []
        for stock in try Self.stocks() {
            for render in Self.renders {
                let transfer = ManualToneTables.Transfer(referenceStops: render.referenceStops, stock: stock, settings: render.settings)
                let weights = try PresenceToneWeights(constants: constants, referenceStops: render.referenceStops, stock: stock,
                                                      settings: render.settings)
                cases.append(("\(stock.id) at \(render.referenceStops)", weights, transfer.lightness))
            }
        }
        let read = cases.flatMap(\.lightness)
        #expect(PresenceConstants.ToneWeight.lightness.dropLast().allSatisfy { knot in read.contains { (knot..<knot + 10).contains($0) } },
                "the cases read every span between knots")
        let expected = try Self.fitWeights(cases.map(\.lightness), version: constants.version)
        try #require(expected.count == cases.count)
        for (item, fit) in zip(cases, expected) {
            for table in PresenceToneWeights.Table.allCases {
                let offset = item.weights.offset(of: table)
                let ours = item.weights.samples[offset..<offset + PresenceToneWeights.samplesPerTable].map(Double.init)
                let theirs = try #require(fit["\(table)"])
                let worst = zip(ours, theirs).map { abs($0 - $1) }.max() ?? .infinity
                #expect(ours.count == theirs.count && worst <= 1e-6, "\(item.label), \(table): \(worst)")
            }
        }
    }

    @Test func theTablesShareTheLightTablesGrid() throws {
        let constants = try #require(PresenceConstants.named(Presence.currentVersion))
        for stock in try Self.stocks() {
            for render in Self.renders {
                let weights = try PresenceToneWeights(constants: constants, referenceStops: render.referenceStops, stock: stock,
                                                      settings: render.settings)
                let light = ManualToneTables(adjustments: try ManualAdjustments(contrast: 30), referenceStops: render.referenceStops,
                                             stock: stock, settings: render.settings)
                #expect(weights.start == light.start && weights.step == light.step, "\(stock.id) at \(render.referenceStops)")
                #expect(weights.samples.count == PresenceToneWeights.Table.allCases.count * ManualToneTables.sampleCount)
            }
        }
    }
}
