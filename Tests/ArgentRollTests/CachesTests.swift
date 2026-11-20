import Foundation
import Testing
@testable import ArgentRoll

/// Caches' Argent folder is the app's alone, as Application Support's is (docs/ci-regression.md, "Test
/// libraries"): a test process stops at once when anything asks for it, by name or through the disk
/// cache's or the digests' default, before reading or writing in it.
@Suite struct CachesTests {
    @Test(.enabled(if: ProcessInfo.isRunningTests))
    func aTestThatAsksForTheAppsCachesStops() async throws {
        let stops = [
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { _ = Caches.folder },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { _ = SourceDigests.defaultFile },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { _ = LinearDiskCache.defaultFolder },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) { _ = LinearDiskCache() },
        ]
        for stop in stops {
            let said = String(decoding: try #require(stop).standardErrorContent, as: UTF8.self)
            #expect(said.contains("A test asked for Caches' Argent folder"), "\(said)")
        }
    }
}
