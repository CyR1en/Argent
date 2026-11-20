import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

/// A model left to either of its Caches defaults, the sheet's disk cache or the digests' file, stops a
/// test process before it is made, as one left to Application Support's library does (`CachesTests`,
/// docs/ci-regression.md, "Test libraries"), so no App test reaches the user's Caches by leaving one out.
@Suite struct ModelCachesTests {
    @Test(.enabled(if: ProcessInfo.isRunningTests))
    func aModelLeftToACachesDefaultStops() async throws {
        let stops = [
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-model-caches-\(UUID().uuidString)")
                await MainActor.run {
                    _ = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                                  stocksDirectory: folder, decisions: AutoDecisionStore(library: folder),
                                  flagStore: FlagStore(library: folder), recipeLibrary: folder, digestsFile: nil)
                }
            },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-model-caches-\(UUID().uuidString)")
                await MainActor.run {
                    _ = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                                  stocksDirectory: folder, decisions: AutoDecisionStore(library: folder),
                                  flagStore: FlagStore(library: folder), recipeLibrary: folder,
                                  previewCache: folder.appendingPathComponent("Linear Previews"))
                }
            },
        ]
        for stop in stops {
            let said = String(decoding: try #require(stop).standardErrorContent, as: UTF8.self)
            #expect(said.contains("A test asked for Caches' Argent folder"), "\(said)")
        }
    }
}
