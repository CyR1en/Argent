import ArgentCore
import ArgentRoll
import Darwin
import Foundation
import Observation
import Testing
@testable import ArgentApp

/// Prepared, distinct RAW copies live in ARGENT_COVER_LIBRARY; ARGENT_COVER_STATE holds local bookmarks and covers.
@MainActor @Suite struct LibraryCoverMeasureTests {
    private final class Scans: @unchecked Sendable {
        let lock = NSLock()
        var active = 0
        var peak = 0

        func read(_ folder: URL) -> RollCoverStore.Read? {
            lock.withLock { active += 1; peak = max(peak, active) }
            defer { lock.withLock { active -= 1 } }
            return RollCoverStore.read(folder)
        }
    }

    @MainActor private final class Progress {
        let model: RollModel
        let count: Int
        let start = Date.timeIntervalSinceReferenceDate
        var first: Double?
        let signal: AsyncStream<Void>.Continuation

        init(_ model: RollModel, count: Int, signal: AsyncStream<Void>.Continuation) {
            self.model = model
            self.count = count
            self.signal = signal
        }

        func observe() {
            let ready = withObservationTracking {
                model.rollCovers.values.filter { !$0.isEmpty }.count
            } onChange: {
                Task { @MainActor in self.observe() }
            }
            if ready > 0, first == nil { first = Date.timeIntervalSinceReferenceDate - start }
            if ready == count { signal.finish() }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1"))
    func library() async throws {
        let env = ProcessInfo.processInfo.environment
        let count = Int(env["ARGENT_COVER_ROLLS"] ?? "24")!
        let library = URL(fileURLWithPath: try #require(env["ARGENT_COVER_LIBRARY"]))
        let folder = URL(fileURLWithPath: try #require(env["ARGENT_COVER_STATE"]))
        let warm = env["ARGENT_COVER_WARM"] == "1"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmarks = BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false)
        if env["ARGENT_COVER_SETUP"] == "1" {
            for roll in 0..<count {
                _ = try #require(bookmarks.addRoll(library.appendingPathComponent(String(format: "Roll-%02d", roll)), origin: .inPlace))
            }
        }
        let model = RollModel(bookmarks: bookmarks, stocksDirectory: folder,
                              decisions: AutoDecisionStore(library: folder), flagStore: FlagStore(library: folder),
                              recipeLibrary: folder, previewCache: folder.appendingPathComponent("Previews"), digestsFile: nil)
        model.library = bookmarks.rolls
        #expect(model.library.count == count)
        if env["ARGENT_COVER_SETUP"] == "1" {
            for entry in model.library {
                if warm {
                    let read = try #require(RollCoverStore.read(URL(fileURLWithPath: entry.path)))
                    model.coverStore.keep(read.covers, for: entry.id)
                    bookmarks.updateRoll(id: entry.id) { $0.frameCount = read.frameCount; $0.firstCapture = read.firstCapture }
                } else {
                    model.coverStore.remove(entry.id)
                }
            }
            return
        }
        let scans = Scans()
        model.libraryCoverReader = { scans.read($0) }
        let (done, signal) = AsyncStream<Void>.makeStream()
        let progress = Progress(model, count: count, signal: signal)
        progress.observe()
        model.loadLibraryCovers()
        for await _ in done {}
        let all = Date.timeIntervalSinceReferenceDate - progress.start
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "COVER_MEASURE rolls=%d frames=24 warm=%d rss_mib=%.2f peak_scans=%d first_s=%.6f all_s=%.6f", count, warm ? 1 : 0,
                     Double(usage.ru_maxrss) / 1_048_576, scans.peak, progress.first!, all))
        #expect(model.library.allSatisfy { $0.frameCount == 24 })
    }
}
