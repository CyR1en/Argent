import ArgentCore
import ArgentRoll
import Darwin
import Foundation
import Testing
@testable import ArgentRemoveHelper

extension WithTheGraphs {
    /// The helper's process with the four graphs, driven through `FolderEngine`'s launched mode on a temporary folder.
    @Suite(.serialized) struct Server {
        /// A 512 square: a soft gradient with a dark disc on it, the object, and the disc's offset shadow.
        static func job(width: Int = 512, height: Int = 512, steps: Int = 8, guidance: Float = 1) throws -> RemovalJob {
            var image = [UInt8](repeating: 0, count: width * height * 3), mask = [UInt8](repeating: 0, count: width * height)
            let cx = width / 2, cy = height / 2, r = min(width, height) / 8
            for y in 0..<height {
                for x in 0..<width {
                    let p = y * width + x
                    var rgb = [140 + x * 60 / width, 150 + y * 50 / height, 170]
                    let dx = x - cx, dy = y - cy, sx = x - cx - r / 2, sy = y - cy - r / 3
                    if sx * sx + sy * sy < r * r { rgb = rgb.map { $0 * 3 / 5 } }
                    if dx * dx + dy * dy < r * r {
                        rgb = [40, 30, 25]
                        mask[p] = 255
                    }
                    for c in 0..<3 { image[p * 3 + c] = UInt8(rgb[c]) }
                }
            }
            return try RemovalJob(width: width, height: height, image: image, mask: mask, steps: steps, guidance: guidance, seed: 42)
        }

        @Test func theHelperRemovesTheObjectCancelsBetweenStepsHonoursPrepareAndGoesWhenUnloaded() async throws {
            await WithTheGraphs.Graphs.runtime.unload()
            let root = try Helper.folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let log = root.appendingPathComponent("helper.log")
            let helper = Helper(["--models", ConvertedModels.directory.path], log: log)
            defer {
                helper.stopAll()
                print((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            }
            let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
            engine.load()
            await Helper.until("the graphs are loaded", seconds: 600) { engine.state == .ready }
            let served = try #require(Helper.engineFile(root))
            #expect(served.engine == "objectclear-coreai" && served.weights == ObjectClearFolder.weightsSHA256)

            // The size announced while the selection is made: compiled for while idle.
            let states = StateLog(engine)
            engine.prepare(width: 512, height: 512)
            await Helper.until("it has compiled for 512 x 512", seconds: 120) {
                states.all.contains { if case .preparing = $0 { true } else { false } } && engine.state == .ready
            }
            states.stop()

            let job = try Self.job()
            let steps = StepPairs()
            let output = try await engine.run(job) { steps.add($0, $1) }
            #expect(steps.all == (1...8).map { [$0, 8] })
            #expect(output.engine == "objectclear-coreai" && output.weights == ObjectClearFolder.weightsSHA256)
            // The object is in the attention map, and outside the map the picture is the input's.
            let inside = job.mask.indices.filter { job.mask[$0] == 255 }
            #expect(inside.filter { output.attention[$0] > 128 }.count > inside.count * 9 / 10)
            let far = job.mask.indices.filter { p in
                let x = p % job.width, y = p / job.width
                return abs(x - job.width / 2) > job.width / 3 || abs(y - job.height / 2) > job.height / 3
            }
            let outside = psnr(far.flatMap { p in (0..<3).map { output.image[p * 3 + $0] } }, far.flatMap { p in (0..<3).map { job.image[p * 3 + $0] } })
            #expect(outside > 30, "\(outside) dB away from the object")
            // Where the disc was, it is gone: the fill is near the background's brightness, not the disc's.
            let fill = inside.reduce(0) { $0 + Int(output.image[$1 * 3]) } / inside.count
            #expect(fill > 90, "the fill's red is \(fill); the disc's was 40")

            // Cancelled after two steps: stopped between two steps, the process still serving.
            let cancelled = StepPairs()
            let run = Task { try await engine.run(try Self.job(steps: 20)) { cancelled.add($0, $1) } }
            await Helper.until("two steps are done", seconds: 120) { cancelled.all.count >= 2 }
            run.cancel()
            await #expect(throws: CancellationError.self) { try await run.value }
            #expect(cancelled.all.count < 20 && helper.processes[0].isRunning)

            let started = ContinuousClock.now
            await engine.unload()
            let gone = (ContinuousClock.now - started).seconds
            #expect(!helper.processes[0].isRunning && helper.processes[0].terminationStatus == 0)
            #expect(gone < 2, "the develop waits 2 s at most: \(gone) s")
        }
    }
}
