import CryptoKit
import Foundation
import Testing
@testable import ArgentRemoveHelper

/// Where the converted graphs are: `ARGENT_REMOVE_MODELS`, else the checkout's `build/models` (never in Git).
enum ConvertedModels {
    static let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["ARGENT_REMOVE_MODELS"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/models", isDirectory: true)
    }()
    static var present: Bool { (try? ObjectClearFolder(directory: directory).check()) != nil }
    static let folder = ObjectClearFolder(directory: directory)
}

/// Every suite that loads the 6 GB of graphs, one after the other: this Mac runs one heavy process at a time, and the helper's
/// process is never started while this one holds the graphs.
@Suite(.serialized, .enabled(if: ConvertedModels.present, "needs the four converted graphs in build/models or ARGENT_REMOVE_MODELS"))
struct WithTheGraphs {
    /// The graphs from Swift against Python's runtime and against PyTorch.
    @Suite(.serialized) struct Graphs {
        static let runtime = ObjectClearRuntime(folder: ConvertedModels.folder)

        /// Each graph's outputs on H1's arithmetic input hash as they did in Python: the arrays go in and come out as Python's.
        @Test(arguments: ObjectClearGraph.allCases) func theCanaryIsPythons(_ graph: ObjectClearGraph) async throws {
            var hash = SHA256Hasher()
            for input in graph.canaryInputs { hash.update(input.values) }
            #expect(hash.hex == graph.canaryInputSHA256)
            let started = ContinuousClock.now
            #expect(try await Self.runtime.canary(graph) == graph.canarySHA256)
            print("canary \(graph.rawValue): \(String(format: "%.2f", (ContinuousClock.now - started).seconds)) s with its load and first call")
        }

        /// A recorded job end to end through the graphs from Swift, with the recorded draws, against PyTorch's own picture: M2's
        /// gate is 35 dB; H1 measured 51 to 55 dB in Python.
        @Test(arguments: Goldens.runs) func aRecordedJobThroughTheGraphsIsPyTorchsPicture(_ run: String) async throws {
            try #require(Goldens.present, "needs the tensors H1 recorded")
            let golden = try Goldens(run)
            let text = try ConvertedModels.folder.textStates()
            try await Self.runtime.load()
            let noises = [try golden.tensor("vae_sample_noise_picture"), try golden.tensor("initial_noise"), try golden.tensor("vae_sample_noise_masked")]
            let input = try golden.picture("input", channels: 3)
            var seconds: [Double] = []
            var result: ObjectClearRun.Result!
            // Twice: the first run at a size compiles for it; the second is warm.
            for _ in 0..<2 {
                let started = ContinuousClock.now
                result = try await ObjectClearRun.run(image: input, mask: try golden.picture("mask", channels: 1), width: golden.width,
                                                      height: golden.height, steps: golden.steps, guidance: golden.guidance, noises: noises,
                                                      states: text.states, pooled: text.pooled, networks: Self.runtime)
                seconds.append((ContinuousClock.now - started).seconds)
            }
            let fused = psnr(result.fused, try golden.picture("fused", channels: 3))
            let generated = psnr(result.generated, try golden.picture("generated", channels: 3))
            let wanted = try golden.picture("attention_latent", channels: 1, latent: true)
            let flips = zip(result.attentionLatent, wanted).filter { ($0 > 128) != ($1 > 128) }.count
            let worst = zip(result.attentionLatent, wanted).map { abs(Int($0) - Int($1)) }.max() ?? 0
            print("\(run): fused \(String(format: "%.2f", fused)) dB, decoder's \(String(format: "%.2f", generated)) dB, attention worst \(worst) "
                  + "of 255 with \(flips) of \(wanted.count) across the threshold; first \(String(format: "%.2f", seconds[0])) s, "
                  + "warm \(String(format: "%.2f", seconds[1])) s")
            #expect(fused >= 35)
            // H1 found 0 to 8 values across the fusion's threshold on these runs in Python.
            #expect(flips <= wanted.count / 500)
        }
    }
}

/// SHA-256 of float32 values, little-endian, one tensor after another.
struct SHA256Hasher {
    private var hash = SHA256()
    mutating func update(_ values: [Float]) { values.withUnsafeBytes { hash.update(bufferPointer: $0) } }
    var hex: String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
}
