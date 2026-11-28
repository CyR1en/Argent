import ArgentRoll
import Foundation
import Testing

@Suite struct PresetStoreTests {
    private func withFolder(_ work: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try work(folder)
    }

    @Test func createsUpdatesListsAndDeletesInAnInjectedFolder() throws {
        try withFolder { folder in
            let store = PresetStore(folder: folder.appendingPathComponent("Presets"))
            #expect(try store.loadAll().presets.isEmpty)
            var look = UserPreset(name: "Zebra")
            let file = try store.save(look)
            #expect(file.lastPathComponent == "\(look.id.uuidString).argentpreset")
            #expect(try store.load(id: look.id) == look)
            look.name = "Bright Zebra"
            look.updatedAt = look.createdAt.addingTimeInterval(30)
            #expect(try store.save(look) == file)
            let other = UserPreset(name: "Amber")
            try store.save(other)
            #expect(try store.loadAll().presets == [other, look])
            try store.delete(id: look.id)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try store.loadAll().presets == [other])
        }
    }

    @Test func exportsAndImportsWithoutOverwritingAndReportsUnreadableEntries() throws {
        try withFolder { folder in
            let store = PresetStore(folder: folder.appendingPathComponent("Source"))
            let receiving = PresetStore(folder: folder.appendingPathComponent("Destination"))
            let preset = UserPreset(name: "Test", includedParts: [.stock], baseStockID: "user-my-stock")
            try store.save(preset)
            let shared = folder.appendingPathComponent("Shared.argentpreset")
            try store.exportPreset(id: preset.id, to: shared)
            #expect(try receiving.importPreset(from: shared) == preset)
            #expect(throws: PresetStore.StoreError.alreadyExists(preset.name)) { try receiving.importPreset(from: shared) }
            let broken = receiving.folder.appendingPathComponent("\(UUID().uuidString).argentpreset")
            try Data("not JSON".utf8).write(to: broken)
            #expect(throws: PresetStore.StoreError.self) { try receiving.importPreset(from: broken) }
            let loaded = try receiving.loadAll()
            #expect(loaded.presets == [preset])
            #expect(loaded.issues.count == 1 && loaded.issues[0].contains(broken.lastPathComponent))
        }
    }
}
