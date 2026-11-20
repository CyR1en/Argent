import Foundation
import Testing
@testable import ArgentRoll

@Suite struct ContentStoreTests {
    private let kind = ContentStore.Kind(folderName: "blobs", fileExtension: "blob", packMagic: Data("PACK\n".utf8))

    @Test(arguments: [false, true]) func aPackHasTheConcatenatedLayout(empty: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ContentStore(library: root, kind: kind)
        let hexes = empty ? [] : [String(repeating: "ab", count: 32), String(repeating: "cd", count: 32)]
        let blobs = empty ? [] : [Data(repeating: 37, count: 2 * 1024 * 1024 + 17), Data()]
        for (hex, blob) in zip(hexes, blobs) {
            try ContentStore.durableWrite(blob, to: store.url(for: hex), library: root, fault: nil)
        }
        var expected = kind.packMagic
        withUnsafeBytes(of: UInt32(hexes.count).littleEndian) { expected.append(contentsOf: $0) }
        var offset = UInt64(kind.packMagic.count + 4 + hexes.count * 48)
        for (index, blob) in blobs.enumerated() {
            expected.append(Data(repeating: index == 0 ? 0xab : 0xcd, count: 32))
            withUnsafeBytes(of: offset.littleEndian) { expected.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt64(blob.count).littleEndian) { expected.append(contentsOf: $0) }
            offset += UInt64(blob.count)
        }
        for blob in blobs { expected.append(blob) }
        let pack = root.appendingPathComponent("pack")
        var checked: [String] = []
        try store.writePack(hexes, to: pack, fault: nil) { checked.append($0) }
        #expect(checked == hexes)
        #expect(try Data(contentsOf: pack) == expected)
        var read: [Data] = []
        try store.readPack(at: pack, wanted: nil) { _, data in read.append(data) }
        #expect(read == blobs)
    }

    @Test func aFailedReadRemovesTheTemporaryAndKeepsTheDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ContentStore(library: root, kind: kind)
        let a = String(repeating: "ab", count: 32), b = String(repeating: "cd", count: 32)
        for hex in [a, b] {
            try ContentStore.durableWrite(Data([1, 2, 3]), to: store.url(for: hex), library: root, fault: nil)
        }
        let pack = root.appendingPathComponent("pack")
        try Data([42]).write(to: pack)
        #expect(throws: (any Error).self) {
            try store.writePack([a, b], to: pack, fault: nil) { hex in
                if hex == b { try FileManager.default.removeItem(at: store.url(for: a)) }
            }
        }
        #expect(try Data(contentsOf: pack) == Data([42]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".tmp-") })
    }

    @Test func aCrashLeavesTheCompleteTemporaryBeforeRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { MaskWriteFaults.shared.clear(library: root) }
        let store = ContentStore(library: root, kind: kind)
        let hex = String(repeating: "ab", count: 32)
        try ContentStore.durableWrite(Data([1, 2, 3]), to: store.url(for: hex), library: root, fault: nil)
        let pack = root.appendingPathComponent("pack")
        MaskWriteFaults.shared.inject(.rasterBeforeRename, library: root)
        #expect(throws: MaskWriteFaults.Crash.self) {
            try store.writePack([hex], to: pack, fault: .rasterBeforeRename) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: pack.path))
        let temporary = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".tmp-") })
        #expect(try ContentStore.packEntries(at: temporary, magic: kind.packMagic)?.map(\.length) == [3])
    }
}
