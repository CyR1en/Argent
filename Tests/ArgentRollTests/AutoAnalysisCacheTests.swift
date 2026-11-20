import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

@Suite struct AutoAnalysisCacheTests {
    @Test func onlyCurrentAnalysisSeedsTheCacheAndDoesNotReplaceAnExistingMeasurement() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.ARW")
        try Data([1, 2, 3]).write(to: url)
        let frame = Frame(id: 0, url: url, info: ARWFrameInfo())
        let source = try #require(SourceStamp.of(url))
        let cache = try FilmPreviews(stocks: [])
        cache.seedAnalysis(ExposureAnalysis(version: "2026-10-07-4", meanStops: 3, validWeight: 1), for: frame, source: source)
        #expect(cache.cachedMeasurement(frame)?.analysis == nil)
        let current = ExposureAnalysis(meanStops: 0.2, validWeight: 1)
        cache.seedAnalysis(current, for: frame, source: source)
        #expect(cache.cachedMeasurement(frame)?.analysis == current)
        cache.seedAnalysis(ExposureAnalysis(meanStops: 1, validWeight: 1), for: frame, source: source)
        #expect(cache.cachedMeasurement(frame)?.analysis == current)
    }
}
