import ArgentCore
import Foundation
import Metal
import Testing
@testable import ArgentRoll

/// What the current Light compiler costs on a full-size frame, and renders of its controls to look
/// at beside Lightroom's. Runs only with ARGENT_MEASURE=1:
///
///     ARGENT_MEASURE=1 ARGENT_RAW=samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW \
///     ARGENT_STOCK=build/stocks/kodak-portra-400 ARGENT_OUT=/tmp/light \
///         swift test --skip-build --filter LightToneMeasureTests
///
/// The frame is decoded whole with RAW 8 and printed at its Auto aim, as the app would with the
/// default roll controls. Table builds are timed on the CPU; the Negative and Print passes by the GPU's
/// timestamps; the local base field by the wall clock of its own synchronous command buffer.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"))
struct LightToneMeasureTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    @Test func costsAndRenders() throws {
        let gpu = try GPU()
        let raw = URL(fileURLWithPath: try #require(Self.environment["ARGENT_RAW"]))
        let stock = try Stock.load(from: URL(fileURLWithPath: try #require(Self.environment["ARGENT_STOCK"])))
        let out = URL(fileURLWithPath: Self.environment["ARGENT_OUT"] ?? "light", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let frame = try AppleRawDecoder(gpu: gpu).decode(raw, options: DecodeOptions())
        let analysis = ExposureAnalyzer.analyze(frame, workingSpace: gpu.workingColorSpace)
        let aim = PrintAim(level: AutoPrint.levelStops(analysis), cast: AutoBalance.cast(analysis))
        var automatic = RollControls().settings(for: stock, aim: aim)
        automatic.halation = stock.halation != nil
        let renderer = try FilmRenderer(gpu: gpu, stock: stock)
        let encoder = try ImageEncoder(gpu: gpu)
        var report = ["\(frame.width) x \(frame.height), aim level \(aim.level)"]

        func settings(_ values: ManualAdjustments, version: String = ManualRenderSettings.currentVersion) throws -> DevelopSettings {
            var s = automatic
            s.manual = try ManualRenderSettings(adjustments: values, referenceStops: aim.level, version: version)
            return s
        }
        func timed(_ s: DevelopSettings, runs: Int = 7) throws -> (gpu: Double, wall: Double) {
            _ = try renderer.render(frame, settings: s)
            var gpuTimes: [Double] = [], wall: [Double] = []
            for _ in 0..<runs {
                let start = Date()
                let result = try renderer.render(frame, settings: s)
                wall.append(Date().timeIntervalSince(start))
                gpuTimes.append(result.gpuSeconds)
            }
            return (Self.median(gpuTimes) * 1000, Self.median(wall) * 1000)
        }

        // Tables, built afresh each time: what a drag of a tone control costs per render.
        var builds: [Double] = []
        for i in 0..<41 {
            let values = try ManualAdjustments(contrast: Float(i % 7) * 10, highlights: -Float(i), shadows: Float(i) / 2,
                                               whites: 15, blacks: -Float(i % 5))
            let manual = try ManualRenderSettings(adjustments: values, referenceStops: aim.level)
            let start = Date()
            _ = try manual.toneTables(stock: stock, settings: automatic)
            builds.append(Date().timeIntervalSince(start) * 1000)
        }
        report.append("table build: median \(Self.median(builds)) ms, max \(builds.max()!) ms")

        var fields: [Double] = []
        for _ in 0..<7 {
            let start = Date()
            _ = try ToneBaseField(gpu: gpu).field(for: frame, parameters: ToneBaseParameters.compiler2026_10_29_1)
            fields.append(Date().timeIntervalSince(start) * 1000)
        }
        report.append("base field (wall, incl. pipeline setup): median \(Self.median(fields)) ms")
        let baseField = try ToneBaseField(gpu: gpu)
        fields = []
        for _ in 0..<7 {
            let start = Date()
            _ = try baseField.field(for: frame, parameters: ToneBaseParameters.compiler2026_10_29_1)
            fields.append(Date().timeIntervalSince(start) * 1000)
        }
        report.append("base field (wall): median \(Self.median(fields)) ms")

        let cases: [(String, DevelopSettings)] = [
            ("automatic", automatic),
            ("2026-10-09-1 all six", try settings(ManualAdjustments(exposureEV: 0.3, contrast: 30, highlights: -60, shadows: 40,
                                                                     whites: -20, blacks: 10), version: ManualRenderSettings.regionsVersion)),
            ("current exposure", try settings(ManualAdjustments(exposureEV: 0.3))),
            ("current global", try settings(ManualAdjustments(exposureEV: 0.3, contrast: 30, whites: -20, blacks: 10))),
            ("current all six", try settings(ManualAdjustments(exposureEV: 0.3, contrast: 30, highlights: -60, shadows: 40,
                                                                whites: -20, blacks: 10))),
        ]
        for (name, s) in cases {
            var noHalation = s
            noHalation.halation = false
            let without = try timed(noHalation), with = try timed(s)
            report.append("\(name): negative+print GPU \(without.gpu) ms, render wall \(without.wall) ms; with halation wall \(with.wall) ms")
        }

        // Renders to compare with Lightroom's exports of the same raw.
        let looks: [(String, ManualAdjustments)] = [
            ("auto", .identity),
            ("highlights-100", try ManualAdjustments(highlights: -100)), ("highlights+100", try ManualAdjustments(highlights: 100)),
            ("shadows+100", try ManualAdjustments(shadows: 100)), ("shadows-100", try ManualAdjustments(shadows: -100)),
            ("whites+50", try ManualAdjustments(whites: 50)), ("whites-100", try ManualAdjustments(whites: -100)),
            ("blacks-50", try ManualAdjustments(blacks: -50)), ("blacks+100", try ManualAdjustments(blacks: 100)),
            ("contrast+100", try ManualAdjustments(contrast: 100)), ("contrast-100", try ManualAdjustments(contrast: -100)),
        ]
        for (name, values) in looks {
            let rendered = try renderer.render(frame, settings: settings(values))
            try encoder.write(rendered.image.texture, to: out.appendingPathComponent("\(name).jpg"), format: .jpeg(quality: 0.9),
                              metadataFrom: nil, longEdge: 1600)
        }
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("costs.txt"), atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
    }
}
