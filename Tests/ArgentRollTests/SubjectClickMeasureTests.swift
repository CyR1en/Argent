import ArgentCore
import CoreAI
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// The real Subject click (`MaskInference.ask` through `BundledSmartMasks`) on a list of raws, for the proof against the research (masking plan decisions 19 to 24): for each entry of
/// `ARGENT_SUBJECT_LIST` (`[{id, raw}]`), the outcome, the stored raster and every decision of its provenance are written to `ARGENT_SUBJECT_OUT` as `<id>.row.json` and `<id>.raster.png`.
/// Needs `build/models` (or `ARGENT_MASK_MODELS`) with all four models. Off unless `ARGENT_MEASURE=1`.
///
///     ARGENT_MEASURE=1 ARGENT_SUBJECT_LIST=<json> ARGENT_SUBJECT_OUT=<folder> swift test -c release -Xswiftc -enable-testing --filter SubjectClickMeasureTests
@Suite(.serialized, .rawDecodes, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1" && ProcessInfo.processInfo.environment["ARGENT_SUBJECT_LIST"] != nil))
struct SubjectClickMeasureTests {
    struct Entry: Codable { var id: String; var raw: String }

    /// A frame's header where `ARWFrameInfo` can read it, else the orientation alone (what X1's harness gave non-TIFF raws).
    static func info(_ url: URL) -> ARWFrameInfo {
        if let real = try? ARWFrameInfo.read(from: url) { return real }
        var value = ARWFrameInfo()
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = all[kCGImagePropertyOrientation] as? UInt32, let o = CGImagePropertyOrientation(rawValue: raw) { value.orientation = o }
        return value
    }

    @Test func theClickOnEveryListedRaw() async throws {
        let env = ProcessInfo.processInfo.environment
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env["ARGENT_SUBJECT_LIST"]))))
        let out = URL(fileURLWithPath: try #require(env["ARGENT_SUBJECT_OUT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("argent-subject-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try writeToyStock(id: "kodak-portra-400", in: support)
        let films = try FilmPreviews(stocks: StockLibrary.load(from: support).stocks, decoderChoices: DecoderChoices(route: .raw9))
        let models = MaskModels(directory: MaskCanary.models, ledgerFile: support.appendingPathComponent("ledger.json"))
        #expect(models.isSubjectAvailable, "\(models.unavailable)")
        let engine = BundledSmartMasks(films: films, models: models, app: "subject-click-measure")
        let inference = MaskInference(engine: engine, turns: DecodeTurns())
        var failures = 0
        for (index, entry) in entries.enumerated() {
            let url = URL(fileURLWithPath: entry.raw)
            let frame = Frame(id: index, url: url, info: Self.info(url))
            let t0 = ContinuousClock.now
            let asked = inference.ask(.subject, on: frame, sourceSHA256: String(repeating: "0", count: 64), lens: .default)
            let outcome = await asked.outcome.value
            var row: [String: Any] = ["id": entry.id, "click_ms": (ContinuousClock.now - t0).seconds * 1000]
            switch outcome {
            case .found(let seed, let maskFrame):
                row["found"] = true
                row["edge"] = seed.edge.rawValue
                row["width"] = seed.raster.width; row["height"] = seed.raster.height
                row["identity"] = seed.raster.identity.hex
                row["provenance"] = seed.provenance.parameters
                row["engine"] = seed.provenance.engine
                row["maskFrame"] = "\(maskFrame.width)x\(maskFrame.height)"
                try SkyReflectionMeasureTests.writeGray(seed.raster.plane, width: seed.raster.width, height: seed.raster.height, to: out.appendingPathComponent("\(entry.id).raster.png"))
                let again = await inference.ask(.background, on: frame, sourceSHA256: String(repeating: "0", count: 64), lens: .default).outcome.value
                if case .found(let bg, _) = again { #expect(bg.kind == .background && bg.raster == seed.raster && bg.edge == seed.edge && bg.provenance == seed.provenance, "\(entry.id)") } else { Issue.record("\(entry.id): Background \(again)") }
            case .nothingFound(_, let provenance, let maskFrame):
                row["found"] = false
                row["provenance"] = provenance.parameters
                row["engine"] = provenance.engine
                row["maskFrame"] = "\(maskFrame.width)x\(maskFrame.height)"
            case .failed(let why):
                failures += 1
                row["failed"] = why
                Issue.record("\(entry.id) failed: \(why)")
            case .cancelled:
                failures += 1
                row["failed"] = "cancelled"
                Issue.record("\(entry.id) cancelled")
            }
            try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]).write(to: out.appendingPathComponent("\(entry.id).row.json"))
            print("SUBJECT \(entry.id) \(row["found"] as? Bool == true ? "found \(row["edge"] ?? "?")" : (row["failed"] as? String) ?? "nothing") \(Int((ContinuousClock.now - t0).seconds * 1000)) ms")
            engine.releasePictures()
            await Task.yield()
        }
        print("SUBJECT done, failures \(failures) of \(entries.count); statistics \(inference.statistics)")
        await models.unloadAll()
    }
}
