import Foundation
import Testing
@testable import ArgentCore

@Suite(.serialized) struct PreviewScoringSampleTests {
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    static var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ARW" }.sorted { $0.path < $1.path }
    }
    static var hasSamples: Bool { files.count == 5 }

    @Test(.enabled(if: PreviewScoringSampleTests.hasSamples))
    func eachSamplesPreviewScores() throws {
        for url in Self.files {
            let info = try ARWFrameInfo.read(from: url)
            let preview = try EmbeddedJPEG.image(at: try #require(info.preview), in: url, maxPixelSize: .max, orientation: .up)
            let scores = try PreviewScoring.scores(of: preview, orientation: info.orientation)
            #expect(scores.featurePrint.count == 768, "\(url.lastPathComponent)")
            #expect(scores.featurePrint.allSatisfy { $0.isFinite }, "\(url.lastPathComponent)")
            #expect((-1...1).contains(scores.aesthetics), "\(url.lastPathComponent)")
        }
    }
}
