import ArgentCore
import ArgentRoll
import Darwin
import Foundation
import Testing
@testable import ArgentRemoveHelper

extension WithTheGraphs {
    /// M2's numbers (docs/remove-plan.md, section 7), measured on the helper's process as the app runs it: a release build named by
    /// `ARGENT_REMOVE_HELPER`, through `FolderEngine`, its own lines read for its footprint. Deletes the helper's compiled copies
    /// first, to time the one-time preparation. Off unless `ARGENT_REMOVE_MEASURE=1`; it prints, and asserts only what M2 stops on.
    @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ARGENT_REMOVE_MEASURE"] == "1"))
    struct Measure {
        static func seconds(_ body: () async throws -> Void) async rethrows -> Double {
            let started = ContinuousClock.now
            try await body()
            return (ContinuousClock.now - started).seconds
        }

        static func say(_ line: String) {
            print("M2 " + line)
        }

        @Test func theHelpersNumbers() async throws {
            await WithTheGraphs.Graphs.runtime.unload()
            let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/coreai-cache/\(MaskModels.osBuild)")
                .appendingPathComponent(Helper.executable.lastPathComponent)
            try? FileManager.default.removeItem(at: cache)
            let root = try Helper.folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let log = root.appendingPathComponent("helper.log")
            let helper = Helper(["--models", ConvertedModels.directory.path], log: log)
            defer {
                helper.stopAll()
                print((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            }
            let engine = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
            let tall = try Server.job(width: 512, height: 1328), other = try Server.job(width: 512, height: 784)

            // The one-time preparation, then the load.
            var states = StateLog(engine)
            var loading = await Self.seconds {
                engine.load()
                await Helper.until("loaded", seconds: 900) { engine.state == .ready }
            }
            states.stop()
            let preparedSeconds = Self.logged(log, "prepared in")
            Self.say(String(format: "first launch, compiled copies made: ready in %.2f s, of which the preparation %@ s; said %@", loading,
                            preparedSeconds.map { String(format: "%.2f", $0) } ?? "?", Self.kinds(states.all)))
            Self.say("compiled copies: \(Self.bytes(of: cache)) bytes in \(cache.path)")

            // A size nobody announced, then the same size warm.
            var cold = try await Self.seconds { _ = try await engine.run(tall) { _, _ in } }
            Self.say(String(format: "first job at 512 x 1328, 8 steps, no hint: %.2f s", cold))
            var warm: [Double] = []
            for _ in 0..<3 { warm.append(try await Self.seconds { _ = try await engine.run(tall) { _, _ in } }) }
            Self.say("warm 8 steps at 512 x 1328: " + warm.map { String(format: "%.2f s", $0) }.joined(separator: ", "))
            let better = try await Self.seconds { _ = try await engine.run(try Server.job(width: 512, height: 1328, steps: 20, guidance: 2.5)) { _, _ in } }
            Self.say(String(format: "warm 20 steps at 2.5 at 512 x 1328: %.2f s", better))

            // Announced, as the app does once a selection is made.
            let compiling = await Self.seconds {
                engine.prepare(width: 512, height: 784)
                await Helper.until("compiling", seconds: 30) { if case .preparing = engine.state { true } else { false } }
                await Helper.until("compiled", seconds: 120) { engine.state == .ready }
            }
            let hinted = try await Self.seconds { _ = try await engine.run(other) { _, _ in } }
            Self.say(String(format: "512 x 784 announced: compiled in %.2f s while idle, then its first job in %.2f s", compiling, hinted))

            var gone = await Self.seconds { await engine.unload() }
            Self.say(String(format: "unloaded with the model warm: the process gone %.3f s after the wish", gone))

            // A fresh process with the compiled copies there: the load, and a first job at a size, with and without the hint.
            let engine2 = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
            states = StateLog(engine2)
            loading = await Self.seconds {
                engine2.load()
                await Helper.until("loaded", seconds: 600) { engine2.state == .ready }
            }
            states.stop()
            Self.say(String(format: "second launch: ready in %.2f s; said %@", loading, Self.kinds(states.all)))
            cold = try await Self.seconds { _ = try await engine2.run(tall) { _, _ in } }
            Self.say(String(format: "fresh process, first job at 512 x 1328, no hint: %.2f s", cold))
            gone = await Self.seconds { await engine2.unload() }
            Self.say(String(format: "unloaded: gone in %.3f s", gone))

            let engine3 = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
            var total = await Self.seconds {
                engine3.load()
                await Helper.until("the process serves", seconds: 60) { Helper.engineFile(root)?.pid == helper.processes.last?.processIdentifier }
                engine3.prepare(width: 512, height: 1328)
                await Helper.until("compiled", seconds: 600) {
                    engine3.state == .ready && ((try? String(contentsOf: log, encoding: .utf8))?.components(separatedBy: "compiled for 512 x 1328").count ?? 0) >= 2
                }
            }
            let afterHint = try await Self.seconds { _ = try await engine3.run(tall) { _, _ in } }
            Self.say(String(format: "fresh process, 512 x 1328 announced at the load: loaded and compiled in %.2f s, then the job in %.2f s", total, afterHint))
            gone = await Self.seconds { await engine3.unload() }

            // Three sizes in one process, the UNet reloaded for each: the memory must not grow from one to the next.
            let engine4 = FolderEngine(root: root, launcher: helper.launcher, unloadLimit: 20)
            total = try await Self.seconds {
                for (width, height) in [(512, 512), (768, 512), (1344, 512), (512, 1344)] {
                    _ = try await engine4.run(try Server.job(width: width, height: height)) { _, _ in }
                }
            }
            Self.say(String(format: "four sizes in one process, each a first: %.2f s", total))
            gone = await Self.seconds { await engine4.unload() }
            Self.say(String(format: "unloaded: gone in %.3f s", gone))

            let peaks = Self.loggedAll(log, "peak")
            Self.say("peak footprint over every line: \(String(format: "%.2f", peaks.max() ?? 0)) GB")
            #expect((peaks.max() ?? 0) < 12, "M2's stop is 12 GB")
        }

        /// The number after `marker` in the helper's last line that has it.
        static func logged(_ log: URL, _ marker: String) -> Double? {
            loggedAll(log, marker).last
        }

        static func loggedAll(_ log: URL, _ marker: String) -> [Double] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.components(separatedBy: "\n").compactMap { line in
                guard let range = line.range(of: marker + " ") else { return nil }
                return Double(line[range.upperBound...].prefix { $0.isNumber || $0 == "." })
            }
        }

        static func kinds(_ states: [RemovalEngineState]) -> String {
            states.map { state in
                switch state {
                case .preparing(let fraction?): String(format: "preparing %.2f", fraction)
                default: "\(state)"
                }
            }.joined(separator: ", ")
        }

        static func bytes(of folder: URL) -> Int {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            var total = 0
            while let file = files?.nextObject() as? URL {
                total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            }
            return total
        }
    }
}
