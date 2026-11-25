import Foundation
import Testing
@testable import ArgentRoll

struct MaskModelLicencesTests {
    @Test func theCheckedInListPinsTheReadingOrderAndExclusions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let list = try String(contentsOf: root.appendingPathComponent("scripts/models/mask-licences.txt"), encoding: .utf8)
        let names = MaskModelLicences.filenames(in: list)
        #expect(names == [
            "NOTICE.txt",
            "DINOv3-LICENSE.md",
            "S3OD-LICENSE-MIT.txt",
            "EoMT-LICENSE-MIT.txt",
            "ViTMatte-LICENSE-MIT.txt",
            "DA3-LICENSE",
            "ADE20K-terms.txt",
            "FLUX1-Krea-dev-LICENSE.md",
            "S3OD-sod-model-card.md",
            "ViTMatte-S-Composition1k-model-card.md",
        ])
        #expect(!names.contains("README.md"))
        #expect(!names.contains { $0.localizedCaseInsensitiveContains("objectclear") })
    }

    @Test func emptyListsHaveNoNames() {
        #expect(MaskModelLicences.filenames(in: "").isEmpty)
        #expect(MaskModelLicences.filenames(in: "\n\n").isEmpty)
    }

    @Test func textsKeepListOrderAndSkipMissingOrUnreadableFiles() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = resources.appendingPathComponent("Model Licences")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        #expect(MaskModelLicences.texts(in: resources).isEmpty)
        let list = resources.appendingPathComponent("mask-licences.txt")
        try "second.txt\nmissing.txt\nbad.txt\nfirst.txt\n".write(to: list, atomically: true, encoding: .utf8)
        try "second".write(to: folder.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        try "first".write(to: folder.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try Data([0xff]).write(to: folder.appendingPathComponent("bad.txt"))
        let texts = MaskModelLicences.texts(in: resources)
        #expect(texts.map(\.name) == ["second.txt", "first.txt"])
        #expect(texts.map(\.text) == ["second", "first"])
        try "".write(to: list, atomically: true, encoding: .utf8)
        #expect(MaskModelLicences.texts(in: resources).isEmpty)
        try Data([0xff]).write(to: list)
        #expect(MaskModelLicences.texts(in: resources).isEmpty)
    }
}
