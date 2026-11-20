import Foundation
import Metal
import Testing
@testable import ArgentCore

/// What Saturation and Vibrance add to a render on the GPU: the main command buffer's time (`RenderedFrame.gpuSeconds`, the Negative
/// and Print passes) with each print block against the same render without it, interleaved, on Portra 400's baked stock, at the frame
/// view's 2190 pixels and at a 33 MP develop's 7008. Runs only when asked:
///
///     ARGENT_MEASURE=1 swift test --filter PresencePrintMeasureTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"))
struct PresencePrintMeasureTests {
    /// Every hue across the width, saturation from grey to full and light from 5 stops under 0.18 to 2 over down the height, so the
    /// print meets the stage's branches (grey, the skin window, the knee) as a photograph's does.
    static func frame(_ gpu: GPU, width: Int, height: Int) throws -> LinearFrame {
        let texture = try gpu.makeTexture(width: width, height: height)
        var row = [Float16](repeating: 1, count: width * 4)
        for y in 0..<height {
            let v = Float(y) / Float(height - 1)
            let level = 0.18 * exp2(-5 + 7 * v), saturation = (v * 4).truncatingRemainder(dividingBy: 1)
            for x in 0..<width {
                let hue = Float(x) / Float(width) * 6
                func channel(_ k: Float) -> Float16 {
                    let d = abs((hue - 2 * k).truncatingRemainder(dividingBy: 6))
                    return Float16(level * (1 - saturation * min(max(min(d, 6 - d) - 1, 0), 1)))
                }
                row[x * 4] = channel(0); row[x * 4 + 1] = channel(1); row[x * 4 + 2] = channel(2)
            }
            row.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        }
        return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "presence-print-measure", scale: Float(width) / 7008)
    }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    @Test func whatTheStageAdds() throws {
        let gpu = try GPU()
        let url = try #require(LightCompilerBaselineTests.bakedStocks.first { $0.lastPathComponent == "kodak-portra-400" })
        let renderer = try FilmRenderer(gpu: gpu, stock: try Stock.load(from: url))
        let constants = try #require(PresenceConstants.named(Presence.currentVersion))
        func block(_ values: [Presence.Control: Float]) throws -> PresenceRenderInputs {
            var inputs = PresenceRenderInputs.bypass
            inputs.print = try PresencePrint.parameters(Presence(values), constants: constants, stockID: "kodak-portra-400")
            return inputs
        }
        let cases: [(name: String, inputs: PresenceRenderInputs?)] = [
            ("none", nil), ("Saturation +50", try block([.saturation: 50])), ("Vibrance +50", try block([.vibrance: 50])),
            ("Vibrance -50", try block([.vibrance: -50])), ("Saturation +50, Vibrance +50", try block([.saturation: 50, .vibrance: 50])),
        ]
        let settings = DevelopSettings(labBalance: SIMD3(0.1, -0.05, 0.03), printExposure: 0.3, grain: 1, grainSeed: 37, halation: true, sharpen: true)
        var lines: [String] = []
        for (width, height, runs) in [(2190, 1460, 40), (7008, 4672, 15)] {
            let frame = try Self.frame(gpu, width: width, height: height)
            var times: [String: [Double]] = [:]
            for run in 0..<(runs + 3) {
                for item in cases {
                    let seconds = try autoreleasepool { try renderer.render(frame, settings: settings, presence: item.inputs).gpuSeconds }
                    if run >= 3 { times[item.name, default: []].append(seconds) }
                }
            }
            let none = Self.median(times["none"]!)
            lines.append(String(format: "%d x %d, %d runs each after 3 warm-up rounds, interleaved: render median %.3f ms", width, height, runs, none * 1000))
            for item in cases.dropFirst() {
                let values = times[item.name]!, sorted = values.sorted()
                lines.append(String(format: "  %@: median %.3f ms, adds %+.3f ms (its own p10 to p90 %.3f to %.3f ms)", item.name,
                                    Self.median(values) * 1000, (Self.median(values) - none) * 1000,
                                    sorted[values.count / 10] * 1000, sorted[values.count * 9 / 10] * 1000))
            }
            let spread = times["none"]!.sorted()
            lines.append(String(format: "  none: p10 to p90 %.3f to %.3f ms", spread[runs / 10] * 1000, spread[runs * 9 / 10] * 1000))
        }
        print(lines.joined(separator: "\n"))
    }
}
