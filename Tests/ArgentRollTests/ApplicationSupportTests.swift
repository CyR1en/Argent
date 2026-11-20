import Foundation
import Testing
@testable import ArgentRoll

/// Application Support's Argent folder is the app's alone (docs/ci-regression.md, "Test libraries"): a
/// test process knows it is one, and stops at once when anything asks for the folder, by name or
/// through a store's default library, before reading or writing in it.
@Suite struct ApplicationSupportTests {
    @Test func aTestProcessKnowsItIsOne() {
        #expect(ProcessInfo.isRunningTests)
    }

    @Test(.enabled(if: ProcessInfo.isRunningTests))
    func aTestThatAsksForTheAppsFolderStops() async throws {
        let stops = [
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { _ = ApplicationSupport.folder },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { _ = RecipeStore.defaultLibrary },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { _ = BookmarkStore.defaultFile },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { _ = AutoDecisionStore() },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { _ = FlagStore() },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                _ = try await RecipeWriter().flush()
            },
        ]
        for stop in stops {
            let said = String(decoding: try #require(stop).standardErrorContent, as: UTF8.self)
            #expect(said.contains("A test asked for Application Support's Argent folder"), "\(said)")
        }
    }
}
