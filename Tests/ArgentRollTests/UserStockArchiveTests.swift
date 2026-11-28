import ArgentCore
import ArgentRoll
import Foundation
import Testing

@Suite struct UserStockArchiveTests {
    @Test func archiveRoundTripKeepsLookAndSpecWithoutOverwritingOnCollision() throws {
        try withFolder { root in
            let sending = UserStockStore(folder: root.appendingPathComponent("sending"))
            let receiving = UserStockStore(folder: root.appendingPathComponent("receiving"))
            let stock = try CubeImporter.bake(.identity(size: 2), id: "user-sunset", name: "Sunset",
                                              options: .init(grain: .coarse, halation: .strong, boxSpeed: 320),
                                              size: 5)
            let spec = Data(#"{"version":1}"#.utf8)
            try sending.save(stock, specData: spec)
            let archive = root.appendingPathComponent("Sunset.argentstock")
            try sending.exportStock(id: stock.id, to: archive)
            #expect(try Data(contentsOf: archive).prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))

            let imported = try receiving.importStock(from: archive)
            #expect(imported.id == stock.id)
            #expect(imported.digest == stock.digest)
            #expect(imported.origin == .userBuilt && imported.hasSpec)
            #expect(receiving.specData(for: imported.id) == spec)
            let copy = try receiving.importStock(from: archive)
            #expect(copy.id != imported.id)
            #expect(copy.digest == imported.digest)
            #expect(receiving.loadAll().stocks.count == 2)
        }
    }

    @Test func importsCubeOnlyFolderAndReassignsBundledID() throws {
        try withFolder { root in
            let source = root.appendingPathComponent("unpacked")
            let lut = LUT3D.identity(size: 3)
            try Stock(id: "argent-neutral", displayName: "Neutral Copy", status: "digital", boxSpeed: 100,
                      densityRange: 3, negative: lut, print: lut).write(to: source)
            for stage in ["negative", "print"] {
                try FileManager.default.removeItem(at: source.appendingPathComponent("\(stage).lut3d"))
                try lut.cubeText(title: stage).write(to: source.appendingPathComponent("\(stage).cube"), atomically: true, encoding: .utf8)
            }
            let store = UserStockStore(folder: root.appendingPathComponent("Stocks"))
            let stock = try store.importStock(from: source, excluding: ["user-neutral-copy"])
            #expect(stock.id == "user-neutral-copy-2")
            #expect(stock.origin == .userImported && !stock.hasSpec)
            let installed = try store.stockDirectory(for: stock.id)
            #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("print.lut3d").path))
            #expect(stock.print.sample(encoded: SIMD3(0.5, 0.25, 0.75)) == SIMD3(0.5, 0.25, 0.75))
        }
    }

    @Test func rejectsBrokenZipAndInvalidFolderWithoutInstalling() throws {
        try withFolder { root in
            let store = UserStockStore(folder: root.appendingPathComponent("Stocks"))
            let broken = root.appendingPathComponent("broken.argentstock")
            try Data("not a ZIP".utf8).write(to: broken)
            #expect(throws: UserStockStore.ArchiveError.self) { try store.importStock(from: broken) }
            try Data("not a stock".utf8).write(to: root.appendingPathComponent(Stock.manifestName))
            #expect(throws: StockError.self) { try store.importStock(from: root) }
            #expect(store.loadAll().stocks.isEmpty)
        }
    }

    @Test func rejectsBoxSpeedThatOverflowsWhenRatedTwoStopsUnder() throws {
        try withFolder { root in
            let store = UserStockStore(folder: root.appendingPathComponent("Stocks"))
            let source = root.appendingPathComponent("unpacked")
            let lut = LUT3D.identity(size: 2)
            let speed = Float(Int.max) / 2
            try Stock(id: "user-overflow", displayName: "Overflow", status: "custom", boxSpeed: speed,
                      densityRange: 3, negative: lut, print: lut).write(to: source)
            #expect(throws: StockError.self) { try store.importStock(from: source) }
            #expect(store.loadAll().stocks.isEmpty)
        }
    }

    private func withFolder(_ action: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-stock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try action(folder)
    }
}
