import ArgentCore
import CoreGraphics
import Foundation
import Testing
@testable import ArgentRoll

@Suite struct UserStockStoreTests {
    private static func makeStock(id: String, displayName: String, boxSpeed: Float = 400,
                                  canisterColor: Stock.CanisterColor? = nil,
                                  characterLine: String? = nil) -> Stock {
        Stock(
            id: id,
            displayName: displayName,
            status: "custom",
            boxSpeed: boxSpeed,
            densityRange: 3.0,
            exposurePerUnit: SIMD3<Float>(repeating: 1),
            negative: LUT3D.identity(size: 5),
            print: LUT3D.identity(size: 5),
            origin: .userImported,
            canisterColor: canisterColor,
            characterLine: characterLine
        )
    }

    private static func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("argent-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func tinyImage(width: Int = 4, height: Int = 4, bytesPerRow: Int = 32) throws -> CGImage {
        let data = Data(repeating: 120, count: bytesPerRow * height)
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func validatesAndGeneratesSafeUserStockIDs() {
        #expect(UserStockStore.isValidUserStockID("user-portra-warm"))
        #expect(UserStockStore.isValidUserStockID("user-my_stock_2"))
        #expect(!UserStockStore.isValidUserStockID("user-"))
        #expect(!UserStockStore.isValidUserStockID("kodak-portra-400"))
        #expect(!UserStockStore.isValidUserStockID("user-../escape"))
        #expect(!UserStockStore.isValidUserStockID("user-has space"))

        #expect(UserStockStore.makeID(from: "Portra Warm 400!") == "user-portra-warm-400")
        #expect(UserStockStore.makeID(from: "Portra Warm", existingIDs: ["user-portra-warm"]) == "user-portra-warm-2")
        #expect(UserStockStore.makeID(from: "Portra Warm", existingIDs: ["user-portra-warm", "user-portra-warm-2"]) == "user-portra-warm-3")
        #expect(UserStockStore.makeID(from: "   ") == "user-stock")
    }

    @Test func savesUpdatesAndDeletesUserStocksAtomically() throws {
        let dir = try Self.makeTempDir("user-store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UserStockStore(folder: dir)

        let v1 = Self.makeStock(id: "user-cinematic", displayName: "Cinematic 400", boxSpeed: 400,
                                canisterColor: .init(red: 0.2, green: 0.5, blue: 0.7),
                                characterLine: "muted greens, soft highlight roll-off")
        let specV1 = Data(#"{"version":1,"contrast":0.2}"#.utf8)
        try store.save(v1, specData: specV1)

        var loaded = store.loadAll()
        #expect(loaded.failures.isEmpty)
        #expect(loaded.stocks.count == 1)
        #expect(loaded.stocks[0].id == "user-cinematic")
        #expect(loaded.stocks[0].origin == .userBuilt)
        #expect(loaded.stocks[0].hasSpec)
        #expect(store.specData(for: "user-cinematic") == specV1)
        let digestV1 = loaded.stocks[0].digest

        // Overwriting the same id replaces atomically and updates the digest.
        let v2 = Self.makeStock(id: "user-cinematic", displayName: "Cinematic 800", boxSpeed: 800)
        try store.save(v2, specData: nil)
        loaded = store.loadAll()
        #expect(loaded.stocks.count == 1)
        #expect(loaded.stocks[0].displayName == "Cinematic 800")
        #expect(loaded.stocks[0].boxSpeed == 800)
        #expect(loaded.stocks[0].origin == .userImported)
        #expect(!loaded.stocks[0].hasSpec)
        #expect(loaded.stocks[0].digest != digestV1)

        try store.delete(id: "user-cinematic")
        #expect(store.loadAll().stocks.isEmpty)
        #expect(throws: UserStockStoreError.notFound("user-cinematic")) {
            try store.delete(id: "user-cinematic")
        }
        #expect(throws: UserStockStoreError.invalidID("kodak-portra-400")) {
            try store.save(Self.makeStock(id: "kodak-portra-400", displayName: "Fake Portra"))
        }
    }

    @Test func stockLibraryLoadsBundledBeforeUserAndRejectsCollisions() throws {
        let bundledDir = try Self.makeTempDir("bundled-stocks")
        let userDir = try Self.makeTempDir("user-stocks")
        defer {
            try? FileManager.default.removeItem(at: bundledDir)
            try? FileManager.default.removeItem(at: userDir)
        }

        // Bundled stocks: Portra 400 and Neutral.
        try Self.makeStock(id: "kodak-portra-400", displayName: "Portra 400")
            .write(to: bundledDir.appendingPathComponent("kodak-portra-400"))
        try Self.makeStock(id: "argent-neutral", displayName: "Neutral")
            .write(to: bundledDir.appendingPathComponent("argent-neutral"))

        // Valid user stocks (one built with spec.json, one imported without).
        let store = UserStockStore(folder: userDir)
        try store.save(Self.makeStock(id: "user-zeta", displayName: "Zeta Look"))
        try store.save(Self.makeStock(id: "user-alpha", displayName: "Alpha Look"), specData: Data("{}".utf8))

        // Invalid user stock without user- prefix (attempts to shadow bundled stock).
        try Self.makeStock(id: "kodak-portra-400", displayName: "Shadow Portra")
            .write(to: userDir.appendingPathComponent("shadow-portra"))

        // Duplicate user stock id in another folder.
        try Self.makeStock(id: "user-alpha", displayName: "Duplicate Alpha")
            .write(to: userDir.appendingPathComponent("zz-duplicate-alpha"))

        let result = StockLibrary.load(from: bundledDir, userDirectory: userDir)
        // Bundled in StockLibrary.order first, then user stocks sorted by displayName.
        #expect(result.stocks.map(\.id) == ["argent-neutral", "kodak-portra-400", "user-alpha", "user-zeta"])
        #expect(result.stocks[0].origin == .bundled)
        #expect(result.stocks[1].origin == .bundled)
        #expect(result.stocks[2].origin == .userBuilt)
        #expect(result.stocks[3].origin == .userImported)
        #expect(result.failures.count == 2)
        #expect(result.failures.map(\.folder).contains("shadow-portra"))
        #expect(result.failures.map(\.folder).contains("zz-duplicate-alpha"))
    }

    @Test func renderedImageCacheSeparatesStockDigestsAndEvictsByStockID() throws {
        let cache = RenderedImageCache(byteLimit: 1 << 20)
        let img1 = try Self.tinyImage()
        let img2 = try Self.tinyImage()
        let settings = DevelopSettings()

        let v1Key = RenderedImageKey.film("frame|src|apple", stock: 2, stockID: "user-warm", stockDigest: "digest-v1",
                                          settings: settings, space: .displayP3, pixels: 300)
        let v2Key = RenderedImageKey.film("frame|src|apple", stock: 2, stockID: "user-warm", stockDigest: "digest-v2",
                                          settings: settings, space: .displayP3, pixels: 300)
        let otherKey = RenderedImageKey.film("frame|src|apple", stock: 0, stockID: "kodak-portra-400", stockDigest: "digest-portra",
                                             settings: settings, space: .displayP3, pixels: 300)

        #expect(cache.store(img1, for: v1Key))
        #expect(cache.store(img2, for: otherKey))
        // Editing the custom stock changes its digest, so the old cached picture is a miss.
        #expect(cache.image(for: v1Key) != nil)
        #expect(cache.image(for: v2Key) == nil)

        // Evicting only the edited stock leaves unrelated stocks warm.
        cache.removeImages(forStockIDs: ["user-warm"])
        #expect(cache.image(for: v1Key) == nil)
        #expect(cache.image(for: otherKey) != nil)
    }
}
