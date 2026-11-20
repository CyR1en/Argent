#if DEBUG
import ArgentCore
import Foundation
import Testing

private let lensGeometrySample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")

/// Whether the sample has been fetched. A test that clones it runs only then, as the other real-RAW tests do.
let hasLensGeometrySample = FileManager.default.fileExists(atPath: lensGeometrySample.path)

/// Each geometry test edits its own copy of the CC0 sample.
func cloneLensGeometrySample(to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    try FileManager.default.copyItem(at: lensGeometrySample, to: url)
    let file = LensResolver.correction(for: url, settings: .default)
    try #require(file.geometry != ResolvedLensCorrection.identity.geometry, "the sample must have a usable file curve")
}
#endif
