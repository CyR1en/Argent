import ArgentCore
import Foundation
import Metal
import Testing
@testable import ArgentRoll

@Suite struct CardTests {
    @Test func knowsDCFFolders() {
        #expect(CardScanner.isDCFFolder("100MSDCF"))
        #expect(CardScanner.isDCFFolder("999MSDCF"))
        // Sony's date form: the folder number, then the year's last digit, month and day.
        #expect(CardScanner.isDCFFolder("10061006"))
        #expect(!CardScanner.isDCFFolder("099MSDCF"))
        #expect(!CardScanner.isDCFFolder("MSDCF100"))
        #expect(!CardScanner.isDCFFolder("100MSDCF1"))
        #expect(!CardScanner.isDCFFolder("CANONMSC"))
    }

    @Test func findsRawFilesInACardsDCFFolders() throws {
        let volume = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: volume) }
        #expect(CardScanner.card(on: volume) == nil)
        let dcim = volume.appendingPathComponent("DCIM")
        for folder in ["100MSDCF", "10161006", "MISC"] {
            try FileManager.default.createDirectory(at: dcim.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // A card with only JPEGs and companions is not offered.
        try Data().write(to: dcim.appendingPathComponent("100MSDCF/DSC00001.JPG"))
        try Data().write(to: dcim.appendingPathComponent("100MSDCF/._DSC00002.ARW"))
        #expect(CardScanner.card(on: volume) == nil)
        try Data().write(to: dcim.appendingPathComponent("100MSDCF/DSC00002.ARW"))
        try Data().write(to: dcim.appendingPathComponent("10161006/DSC00003.arw"))
        // Raws outside a DCF folder are not the camera's.
        try Data().write(to: dcim.appendingPathComponent("MISC/DSC00004.ARW"))
        let card = try #require(CardScanner.card(on: volume, name: "Untitled"))
        #expect(card.rawCount == 2 && card.name == "Untitled" && card.volume == volume)
    }

    /// A card whose DCIM folder can be seen but not listed, as after "Don't Allow" in macOS's
    /// removable-volume prompt, is still a card, of unknown count; a volume without DCIM is not.
    @Test func aCardThatCannotBeListedIsOfferedUncounted() throws {
        let volume = try temporaryFolder()
        let dcim = volume.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: dcim.appendingPathComponent("100MSDCF"), withIntermediateDirectories: true)
        try Data().write(to: dcim.appendingPathComponent("100MSDCF/DSC00001.ARW"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dcim.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dcim.path)
            try? FileManager.default.removeItem(at: volume)
        }
        let card = try #require(CardScanner.card(on: volume, name: "Untitled"))
        #expect(card.rawCount == nil && card.name == "Untitled")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dcim.path)
        #expect(CardScanner.card(on: volume)?.rawCount == 1)
        try FileManager.default.removeItem(at: dcim)
        #expect(CardScanner.card(on: volume) == nil)
    }

    /// A full card, 500 raws and 500 JPEGs over two folders, is two directory listings.
    @Test func scansAFullCardInMilliseconds() throws {
        let volume = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: volume) }
        for folder in ["100MSDCF", "101MSDCF"] {
            let url = volume.appendingPathComponent("DCIM/\(folder)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for index in 0..<250 {
                try Data().write(to: url.appendingPathComponent(String(format: "DSC%05d.ARW", index)))
                try Data().write(to: url.appendingPathComponent(String(format: "DSC%05d.JPG", index)))
            }
        }
        let clock = ContinuousClock()
        var card: Card?
        let elapsed = clock.measure { card = CardScanner.card(on: volume) }
        print("MEASURE card scan, 1000 files: \(elapsed)")
        #expect(card?.rawCount == 500)
        #expect(elapsed < .milliseconds(100))
    }

    @Test func aFolderOnTheStartupDiskIsNotACard() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!CardScanner.isCardLike(folder))
        #expect(!CardScanner.isCardLike(URL(fileURLWithPath: "/")))
    }
}

@Suite struct BookmarkStoreTests {
    private func store(in folder: URL) -> BookmarkStore {
        // Outside the sandbox a security-scoped bookmark cannot be made; plain ones behave the same.
        BookmarkStore(file: folder.appendingPathComponent("Bookmarks.json"), securityScoped: false)
    }

    @Test func keepsTheTenMostRecentRollsNewestFirstAcrossLaunches() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        var rolls: [URL] = []
        for index in 0..<12 {
            let roll = base.appendingPathComponent("roll\(index)")
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            rolls.append(roll)
        }
        let first = store(in: base)
        for (index, roll) in rolls.enumerated() {
            #expect(first.noteOpened(roll, at: Date(timeIntervalSince1970: Double(index))))
        }
        // Opening one again moves it to the top rather than adding it twice.
        first.noteOpened(rolls[5], at: Date(timeIntervalSince1970: 100))
        let names = first.recents.map(\.name)
        #expect(names.count == BookmarkStore.keptRecents)
        #expect(Array(names.prefix(3)) == ["roll5", "roll11", "roll10"])
        #expect(!names.contains("roll0") && !names.contains("roll1"))

        let second = store(in: base)
        #expect(second.recents.map(\.name) == names)
        let top = try #require(second.recents.first)
        #expect(second.resolve(top)?.canonicalPath == rolls[5].canonicalPath)

        // A roll that is gone does not resolve; the menu says so rather than opening nothing.
        try FileManager.default.removeItem(at: rolls[11])
        #expect(second.resolve(second.recents[1]) == nil)
        second.clearRecents()
        #expect(store(in: base).recents.isEmpty)
    }

    /// Remove from Recents takes one roll off, by either spelling of its path, keeps the others in their order across launches,
    /// and leaves the folder alone; opened again, the roll is back at the top.
    @Test func removesOneRecentAndKeepsTheOthersInOrder() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        var rolls: [URL] = []
        for index in 0..<3 {
            let roll = base.appendingPathComponent("roll\(index)")
            try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
            rolls.append(roll)
        }
        let first = store(in: base)
        for (index, roll) in rolls.enumerated() { first.noteOpened(roll, at: Date(timeIntervalSince1970: Double(index))) }
        #expect(first.recents.map(\.name) == ["roll2", "roll1", "roll0"])
        #expect(first.removeRecent(path: rolls[1].canonicalPath))
        #expect(first.recents.map(\.name) == ["roll2", "roll0"])
        #expect(FileManager.default.fileExists(atPath: rolls[1].path))
        #expect(store(in: base).recents.map(\.name) == ["roll2", "roll0"])
        // The temporary folder is under /var, a link to /private/var: the menu's path or the link's both find it.
        let linked = rolls[0].path.hasPrefix("/private/") ? String(rolls[0].path.dropFirst("/private".count)) : rolls[0].path
        #expect(first.removeRecent(path: linked))
        #expect(!first.removeRecent(path: rolls[0].path))
        #expect(!first.removeRecent(path: base.appendingPathComponent("elsewhere").path))
        #expect(store(in: base).recents.map(\.name) == ["roll2"])
        first.noteOpened(rolls[1], at: Date(timeIntervalSince1970: 10))
        #expect(first.recents.map(\.name) == ["roll1", "roll2"])
    }

    @Test func existingPathBasedChoicesFollowTheirRollsAfterRelaunch() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let roll = base.appendingPathComponent("Roll"), other = base.appendingPathComponent("Other")
        let out = base.appendingPathComponent("Prints"), moved = base.appendingPathComponent("Moved")
        for folder in [roll, other, out] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let first = store(in: base)
        // Before these rolls have library IDs, their settings use the original path keys.
        #expect(first.rememberDestination(out, forRoll: roll, usesSubfolder: true))
        #expect(first.rememberDestination(out, forRoll: other, usesSubfolder: false))
        let entry = try #require(first.addRoll(roll, origin: .inPlace))
        _ = try #require(first.addRoll(other, origin: .inPlace))
        try FileManager.default.moveItem(at: roll, to: moved)

        let reopened = store(in: base)
        #expect(reopened.resolve(entry)?.canonicalPath == moved.canonicalPath)
        #expect(reopened.addRoll(moved, origin: .inPlace)?.id == entry.id)
        let saved = store(in: base)
        #expect(saved.usedSubfolder(out, forRoll: moved) == true)
        #expect(saved.usedSubfolder(out, forRoll: other) == false)
    }

    @Test func bothTheRecipePathAndTheCurrentPathReachAMovedDestination() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let from = base.appendingPathComponent("Before"), to = base.appendingPathComponent("After")
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: false)
        #expect(store(in: base).rememberDestination(from))
        try FileManager.default.moveItem(at: from, to: to)

        #expect(store(in: base).destination(atPath: from.path)?.canonicalPath == to.canonicalPath)
        let reopened = store(in: base)
        #expect(reopened.destination(atPath: from.path)?.canonicalPath == to.canonicalPath)
        #expect(reopened.destination(atPath: to.path)?.canonicalPath == to.canonicalPath)
    }

    @Test func findsADestinationByEitherSpellingOfItsPath() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let out = base.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let first = store(in: base)
        #expect(first.rememberDestination(out))
        // The temporary folder is under /var, a link to /private/var: the recipe may name the
        // folder either way.
        let linked = out.path.hasPrefix("/private/") ? String(out.path.dropFirst("/private".count)) : out.path
        let second = store(in: base)
        #expect(second.destination(atPath: linked)?.canonicalPath == out.canonicalPath)
        #expect(second.destination(atPath: "/private" + linked)?.canonicalPath == out.canonicalPath)
        #expect(second.destination(atPath: base.appendingPathComponent("elsewhere").path) == nil)
    }
}

@Suite struct CanonicalPathTests {
    /// A folder reached through a bookmark comes back as /private/tmp/x where its recipe says
    /// /tmp/x; a develop has to know its own files either way (found in the running app).
    @Test func aDevelopKnowsItsOwnFilesUnderEitherSpelling() throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5),
                          print: LUT3D.identity(size: 5))
        let frame = Frame(id: 0, url: URL(fileURLWithPath: "/tmp/roll/DSC00601.ARW"), info: ARWFrameInfo())
        let real = out.appendingPathComponent("DSC00601.jpg")
        try Data().write(to: real)
        let other = real.path.hasPrefix("/private/") ? String(real.path.dropFirst("/private".count)) : "/private" + real.path
        var recipe = Recipe(frame: frame, byteCount: 1, stock: stock, stockDigest: stock.digest,
                            roll: RollControls(), own: FrameControls())
        recipe.develops.append(.init(date: Date(), software: "Argent", output: OutputSettings(), file: other,
                                     width: 1, height: 1, render: recipe.render,
                                     decode: nil, readback: nil, stockDigest: stock.digest))
        let files = RollDeveloper.files(for: [RollDeveloper.Job(frame: frame, recipe: recipe)], in: out, output: OutputSettings())
        #expect(files.map(\.lastPathComponent) == ["DSC00601.jpg"])
        #expect(real.canonicalPath == other.canonicalPath)
    }
}

@Suite struct LinearDiskCacheTests {
    private func frame(_ gpu: GPU, value: Float16) throws -> LinearFrame {
        let texture = try gpu.texturePool.acquire(width: 12, height: 8)
        let pixels = [Float16](repeating: value, count: 12 * 8 * 4)
        pixels.withUnsafeBytes { texture.texture.replace(region: MTLRegionMake2D(0, 0, 12, 8), mipmapLevel: 0,
                                                         withBytes: $0.baseAddress!, bytesPerRow: 12 * 8) }
        return LinearFrame(image: texture, decoderVersion: "8", scale: 0.125)
    }

    /// An entry keeps the picture's full size, and one written before it was recorded still reads, with none.
    @Test func anEntryKeepsThePicturesSizeAndAnOldOneStillReads() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gpu = try GPU()
        let cache = LinearDiskCache(folder: folder, limitBytes: 1 << 20)
        let plain = try frame(gpu, value: 0.5)
        let told = LinearFrame(image: plain.image, decoderVersion: "8", scale: 0.125, picture: try MaskSpace(width: 7008, height: 4672))
        cache.store(told, key: "new")
        cache.store(plain, key: "none")
        cache.flush()
        #expect(cache.load("new", pool: gpu.texturePool)?.picture == (try MaskSpace(width: 7008, height: 4672)))
        #expect(cache.load("none", pool: gpu.texturePool)?.picture == nil)

        // The bytes the build before this one wrote: its header has no picture in it.
        let header = #"{"width":12,"height":8,"scale":0.125,"decoderVersion":"8"}"#
        var data = Data("ARGENT-LINEAR-1\n".utf8)
        withUnsafeBytes(of: UInt32(header.utf8.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(header.utf8))
        data.append(Data(count: 12 * 8 * 8))
        try data.write(to: folder.appendingPathComponent("old.linear"))
        let old = try #require(cache.load("old", pool: gpu.texturePool))
        #expect(old.width == 12 && old.height == 8 && old.picture == nil)
        #expect(try old.maskPicture == (try MaskSpace(width: 12, height: 8)))
    }

    @Test func storesLoadsAndEvictsTheLeastRecentlyUsed() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gpu = try GPU()
        // Room for two entries of 768 bytes of pixels and a small header.
        let cache = LinearDiskCache(folder: folder, limitBytes: 2 * 1024)
        cache.store(try frame(gpu, value: 0.25), key: "a")
        cache.store(try frame(gpu, value: 0.5), key: "b")
        cache.flush()
        let loaded = try #require(cache.load("a", pool: gpu.texturePool))
        #expect(loaded.width == 12 && loaded.height == 8 && loaded.scale == 0.125 && loaded.decoderVersion == "8")
        var pixel = [Float16](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { loaded.texture.getBytes($0.baseAddress!, bytesPerRow: 8,
                                                               from: MTLRegionMake2D(5, 5, 1, 1), mipmapLevel: 0) }
        #expect(pixel == [0.25, 0.25, 0.25, 0.25])
        #expect(cache.load("missing", pool: gpu.texturePool) == nil)

        // "a" was used last, so a third entry pushes out "b".
        Thread.sleep(forTimeInterval: 0.02)
        _ = cache.load("a", pool: gpu.texturePool)
        cache.store(try frame(gpu, value: 0.75), key: "c")
        cache.flush()
        cache.trim()
        #expect(cache.load("b", pool: gpu.texturePool) == nil)
        #expect(cache.load("a", pool: gpu.texturePool) != nil && cache.load("c", pool: gpu.texturePool) != nil)

        // A damaged file is a miss, not a crash.
        try Data("ARGENT-LINEAR-1\n????".utf8).write(to: folder.appendingPathComponent("d.linear"))
        #expect(cache.load("d", pool: gpu.texturePool) == nil)
    }

    @Test func keysFollowTheRawsContentAndTheDecoder() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.ARW"), b = folder.appendingPathComponent("b.ARW")
        try Data(repeating: 1, count: 1000).write(to: a)
        try Data(repeating: 1, count: 1000).write(to: b)
        let apple = AppleRawDecoder.pinnedDecoderVersion
        func key(_ url: URL, _ side: Int = 960, _ decoder: String = apple) -> String? {
            LinearDiskCache.key(for: url, longSide: side, decoderVersion: decoder)
        }
        // The same bytes under another name are the same raw; a size or a byte apart are not.
        #expect(key(a) == key(b))
        #expect(key(a) != key(a, 512))
        // A frame from one decoder, RAW 8, RAW 9 or the in-house one, is never read back for another.
        #expect(key(a) != key(a, 960, InHouseDecoder.version))
        #expect(key(a) != key(a, 960, AppleRawDecoder.learnedDecoderVersion))
        #expect(key(a, 960, InHouseDecoder.version) != key(a, 960, AppleRawDecoder.learnedDecoderVersion))
        try Data(repeating: 1, count: 1001).write(to: b)
        #expect(key(a) != key(b))
        #expect(key(folder.appendingPathComponent("none.ARW")) == nil)
        // The whole raw is the key: a byte changed in place anywhere at the same size, past the
        // first 256 KB the key once read, is another raw.
        try Data(repeating: 1, count: 2_000_000).write(to: a)
        let whole = key(a)
        let handle = try FileHandle(forUpdating: a)
        try handle.seek(toOffset: 300_000)
        try handle.write(contentsOf: Data([2]))
        try handle.close()
        #expect(key(a) != whole && key(a) != nil)
    }
}
