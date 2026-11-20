import CoreImage
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// A copy of the raw at `source`, written to `url`, with its Exif ISO (ISOSpeedRatings and
/// RecommendedExposureIndex) set to `iso`; 0 stands for a file whose ISO cannot be used.
func copyRaw(_ source: URL, to url: URL, iso: Int) throws {
    var data = try Data(contentsOf: source)
    func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    func entry(_ ifd: Int, _ tag: Int) -> Int? {
        (0..<u16(ifd)).map { ifd + 2 + 12 * $0 }.first { u16($0) == tag }
    }
    guard let exifEntry = entry(u32(4), 0x8769) else { throw ARWLayout.ReadError.noRawIFD }
    let exif = u32(exifEntry + 8)
    var written = 0
    if let e = entry(exif, 0x8827), u16(e + 2) == 3 {
        withUnsafeBytes(of: UInt16(min(iso, 65535)).littleEndian) { data.replaceSubrange(e + 8..<e + 10, with: $0) }
        written += 1
    }
    if let e = entry(exif, 0x8832), u16(e + 2) == 4 {
        withUnsafeBytes(of: UInt32(iso).littleEndian) { data.replaceSubrange(e + 8..<e + 12, with: $0) }
        written += 1
    }
    guard written > 0 else { throw ARWLayout.ReadError.noRawIFD }
    try data.write(to: url)
}

@Suite struct DecoderChoiceTests {
    /// A scaled in-house decode is sized as Apple's decoder sizes one, each side rounded up, so
    /// the frame view's box (two thirds of the long side, rounded up) fits either decoder's frame.
    @Test func scaledSizesRoundUpAsApplesDo() {
        func size(_ long: Int, _ w: Int = 7008, _ h: Int = 4672) -> (Int, Int) {
            let s = InHouseDecoder.scaledSize(width: w, height: h, scale: Float(long) / Float(max(w, h)))
            return (s.width, s.height)
        }
        // Apple's decoder on the lossless L sample (measured, docs/decoder.md, section 14).
        for (long, short) in [(256, 171), (900, 600), (960, 640), (1001, 668), (2188, 1459), (2189, 1460), (2190, 1460),
                              (2191, 1461), (2600, 1734), (3500, 2334), (3700, 2467), (4096, 2731)] {
            #expect(size(long) == (long, short), "\(long)")
            #expect(size(long) == (long, (2 * long + 2) / 3), "\(long)")
            #expect(size(long, 4672, 7008) == (short, long), "\(long), upright")
        }
        #expect(size(1, 7008, 4672) == (1, 1))
    }

    @Test func theCutoffIsISO3200() {
        #expect(DecoderChoice.inHouseISOLimit == 3200)
        #expect(DecoderChoice.inHouse(iso: 50) && DecoderChoice.inHouse(iso: 1250) && DecoderChoice.inHouse(iso: 1600) && DecoderChoice.inHouse(iso: 3200))
        #expect(!DecoderChoice.inHouse(iso: 3201) && !DecoderChoice.inHouse(iso: 4000) && !DecoderChoice.inHouse(iso: 0))
        #expect(DecoderChoice.inHouse.decoderVersion == InHouseDecoder.version)
        #expect(DecoderChoice.apple.decoderVersion == AppleRawDecoder.pinnedDecoderVersion && AppleRawDecoder.pinnedDecoderVersion == "8")
        #expect(DecoderChoice.raw9.decoderVersion == AppleRawDecoder.learnedDecoderVersion && AppleRawDecoder.learnedDecoderVersion == "9")
    }

    /// The switch names a route: `apple` RAW 8 everywhere, `inhouse` M8's route, anything else RAW 9's.
    @Test func theSwitchNamesTheRoute() {
        #expect(DecoderChoices.route(named: nil) == .raw9 && DecoderChoices.route(named: "") == .raw9)
        #expect(DecoderChoices.route(named: "raw9") == .raw9 && DecoderChoices.route(named: "learned") == .raw9)
        #expect(DecoderChoices.route(named: "apple") == .apple && DecoderChoices.route(named: "Apple") == .apple
                && DecoderChoices.route(named: "raw8") == .apple)
        #expect(DecoderChoices.route(named: "inhouse") == .inHouse && DecoderChoices.route(named: "in-house") == .inHouse)
    }

    /// RAW 9 takes the a7 IV's three Bayer modes, at any crop, and neither lossless M nor S.
    @Test func theA7IVsBayerModesGoToRAW9() {
        let modes = Dictionary(uniqueKeysWithValues: BodyProfile.a7IV.modes.map { ($0.name, $0.learned) })
        #expect(modes == ["uncompressed": true, "compressed": true, "lossless L": true, "lossless M": false, "lossless S": false])
    }
}

/// Runs only where the CC0 samples are present.
@Suite(.serialized) struct DecoderChoiceSampleTests {
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")
    static let lossless = samples.appendingPathComponent("ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW")
    static var hasSamples: Bool { FileManager.default.fileExists(atPath: lossless.path) }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argent-choice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let uncompressed = samples.appendingPathComponent("ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
    static let medium = samples.appendingPathComponent("ILCE-7M4_DSC06675_FullFrame-LossLess-Compressed-Medium.ARW")
    static let small = samples.appendingPathComponent("ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW")
    static let compressed = samples.appendingPathComponent("ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW")

    /// On its route the in-house decoder takes the lossless L and uncompressed samples up to the
    /// cutoff and nothing else; a file whose ISO cannot be used goes to Apple's.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func choosesByFormatAndISO() throws {
        #expect(DecoderChoice.of(Self.lossless, route: .inHouse) == .inHouse && DecoderChoice.of(Self.uncompressed, route: .inHouse) == .inHouse)
        for url in [Self.medium, Self.small, Self.compressed] {
            #expect(DecoderChoice.of(url, route: .inHouse) == .apple, "\(url.lastPathComponent)")
        }
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let limit = DecoderChoice.inHouseISOLimit
        for source in [Self.lossless, Self.uncompressed] {
            for (iso, expected) in [(100, DecoderChoice.inHouse), (640, .inHouse), (1250, .inHouse), (limit, .inHouse), (limit + 1, .apple),
                                    (51200, .apple), (0, .apple)] {
                let copy = folder.appendingPathComponent("\(source.lastPathComponent)-iso\(iso).ARW")
                try copyRaw(source, to: copy, iso: iso)
                #expect(try ARWFrameInfo.read(from: copy).iso == iso)
                #expect(DecoderChoice.of(copy, route: .inHouse) == expected, "\(source.lastPathComponent) at ISO \(iso)")
            }
        }
        #expect(DecoderChoice.of(folder.appendingPathComponent("none.ARW"), route: .inHouse) == .apple)
        #expect(DecoderChoice.of(Self.lossless, route: .apple) == .apple)
    }

    /// On RAW 9's route, the app's, RAW 9 takes the lossless L, uncompressed and compressed samples
    /// at every ISO, and RAW 8 lossless M and S; and Apple's decoder offers version 9 for exactly the
    /// files the route gives RAW 9, so a macOS update that changes which modes RAW 9 takes fails here.
    /// The APS-C crop, which the samples lack, is measured in `Raw9MeasureTests/defaults`.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func raw9TakesTheBayerModesAtEveryISO() throws {
        for url in [Self.lossless, Self.uncompressed, Self.compressed] {
            #expect(DecoderChoice.of(url) == .raw9, "\(url.lastPathComponent)")
        }
        for url in [Self.medium, Self.small] {
            #expect(DecoderChoice.of(url) == .apple, "\(url.lastPathComponent)")
        }
        for url in [Self.lossless, Self.uncompressed, Self.compressed, Self.medium, Self.small] {
            let filter = try #require(CIRAWFilter(imageURL: url))
            #expect(AppleRawDecoder.offers(.learned, filter) == (DecoderChoice.of(url) == .raw9), "\(url.lastPathComponent)")
            #expect(AppleRawDecoder.offers(.classic, filter), "\(url.lastPathComponent)")
        }
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        for source in [Self.lossless, Self.uncompressed] {
            for iso in [50, 3200, 3201, 6400, 204800, 0] {
                let copy = folder.appendingPathComponent("\(source.lastPathComponent)-iso\(iso).ARW")
                try copyRaw(source, to: copy, iso: iso)
                #expect(DecoderChoice.of(copy) == .raw9, "\(source.lastPathComponent) at ISO \(iso)")
            }
        }
        #expect(DecoderChoice.of(folder.appendingPathComponent("none.ARW")) == .apple)
    }

    /// Through the app's decoder, RAW 9's route decodes the Bayer samples with RAW 9 and lossless M
    /// and S with RAW 8, each frame recording the decoder that made it.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func raw9DecodesTheBayerModesAndRAW8TheRest() throws {
        let gpu = try GPU()
        var options = DecodeOptions()
        options.maxLongSide = 960
        // Filled, so lossless S's trim leaves it the same long side.
        options.fillsMaxLongSide = true
        let chosen = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9))
        for (url, decoder) in [(Self.lossless, "9"), (Self.uncompressed, "9"), (Self.compressed, "9"), (Self.medium, "8"), (Self.small, "8")] {
            let frame = try chosen.decode(url, options: options)
            #expect(frame.decoderVersion == decoder && frame.pins?.decoderVersion == decoder, "\(url.lastPathComponent)")
            #expect(max(frame.width, frame.height) == 960 && frame.readback != nil, "\(url.lastPathComponent)")
        }
        #expect(chosen.choices.choice(for: Self.lossless) == .raw9 && chosen.choices.choice(for: Self.medium) == .apple)
    }

    /// A file RAW 9 fails on decodes with RAW 8, then and for the rest of the session while the file
    /// is unchanged; another session tries RAW 9 again. A file that cannot be read is a read error,
    /// not a RAW 9 failure: once it can be read again it is RAW 9's.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func aRAW9FailureFallsBackToRAW8ForTheSession() throws {
        let gpu = try GPU()
        let folder = try scratch()
        let copy = folder.appendingPathComponent("frame.ARW"), refused = folder.appendingPathComponent("refused.ARW")
        func readable(_ yes: Bool) throws {
            try FileManager.default.setAttributes([.posixPermissions: yes ? 0o644 : 0], ofItemAtPath: copy.path)
        }
        defer {
            try? readable(true)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.copyItem(at: Self.lossless, to: copy)
        try FileManager.default.copyItem(at: Self.lossless, to: refused)
        var options = DecodeOptions()
        options.maxLongSide = 960
        let choices = DecoderChoices(route: .raw9)
        let chosen = ChosenDecoder(gpu: gpu, choices: choices)
        choices.refuseRAW9(refused)
        #expect(choices.choice(for: refused) == .raw9)
        let fellBack = try chosen.decode(refused, options: options)
        #expect(fellBack.decoderVersion == AppleRawDecoder.pinnedDecoderVersion && fellBack.pins?.colorNoiseReduction == 0.5)
        #expect(choices.choice(for: refused) == .apple && choices.decoderVersion(for: refused) == "8")
        #expect(DecoderChoices(route: .raw9).choice(for: refused) == .raw9)

        try readable(false)
        #expect(throws: DecodeError.self) { try DecoderChoice.read(copy) }
        #expect(choices.choice(for: copy) == .apple)
        do {
            _ = try chosen.decode(copy, options: options)
            Issue.record("decoded a file it cannot read")
        } catch DecodeError.unreadable {
        } catch {
            Issue.record("\(error)")
        }
        try readable(true)
        #expect(choices.choice(for: copy) == .raw9)
        #expect(try chosen.decode(copy, options: options).decoderVersion == AppleRawDecoder.learnedDecoderVersion)
    }

    /// RAW 9 failing for the machine rather than the file, a texture the GPU could not allocate or a
    /// command buffer Metal failed, is tried again once; failing again, it is thrown and not noted, so
    /// the file stays RAW 9's for the session and decodes with RAW 9 once the machine can.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func aMachineFailureOfRAW9IsTriedAgainAndNeverNoted() throws {
        let gpu = try GPU()
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("frame.ARW")
        try FileManager.default.copyItem(at: Self.lossless, to: copy)
        var options = DecodeOptions()
        options.maxLongSide = 960
        let learned = AppleRawDecoder.learnedDecoderVersion
        let machine: [any Error] = [GPUError.textureAllocation,
                                    NSError(domain: MTLCommandBufferErrorDomain, code: Int(MTLCommandBufferError.Code.outOfMemory.rawValue))]
        for error in machine {
            let choices = DecoderChoices(route: .raw9)
            let chosen = ChosenDecoder(gpu: gpu, choices: choices)
            choices.refuseRAW9(copy, with: error, times: 1)
            #expect(try chosen.decode(copy, options: options).decoderVersion == learned, "\(error)")
            choices.refuseRAW9(copy, with: error)
            #expect(throws: (any Error).self, "\(error)") { try chosen.decode(copy, options: options) }
            #expect(choices.choice(for: copy) == .raw9, "\(error)")
            #expect(try ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9)).decode(copy, options: options).decoderVersion
                    == learned, "\(error)")
        }
    }

    /// A session's choices: Apple's decoder for everything when asked; otherwise each file's own
    /// choice, read again when the file changes, and Apple's for a file the in-house decoder failed on.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func choicesFollowTheSwitchTheFileAndFailures() throws {
        #expect(DecoderChoices(route: .apple).choice(for: Self.lossless) == .apple)
        #expect(DecoderChoices(route: .apple).decoderVersion(for: Self.lossless) == AppleRawDecoder.pinnedDecoderVersion)
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("frame.ARW")
        try copyRaw(Self.lossless, to: copy, iso: 400)
        let choices = DecoderChoices(route: .inHouse)
        #expect(choices.choice(for: copy) == .inHouse && choices.decoderVersion(for: copy) == InHouseDecoder.version)
        // The same path, now shot at ISO 6400 as far as the file says.
        try copyRaw(Self.lossless, to: copy, iso: 6400)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: copy.path)
        #expect(choices.choice(for: copy) == .apple)
        #expect(choices.choice(for: Self.lossless) == .inHouse)
        choices.noteFailure(Self.lossless, readAt: DecoderChoices.stamp(Self.lossless.path))
        #expect(choices.choice(for: Self.lossless) == .apple)
        #expect(DecoderChoices(route: .inHouse).choice(for: Self.lossless) == .inHouse)
        // RAW 9's route: by the mode, whatever the ISO, with failures as on the in-house route.
        let learned = DecoderChoices(route: .raw9)
        #expect(learned.choice(for: copy) == .raw9 && learned.decoderVersion(for: copy) == AppleRawDecoder.learnedDecoderVersion)
        learned.noteFailure(copy, readAt: DecoderChoices.stamp(copy.path))
        #expect(learned.choice(for: copy) == .apple && DecoderChoices(route: .raw9).choice(for: copy) == .raw9)
    }

    /// A replacement may preserve size and modification time. Routing and white-balance metadata
    /// still belong to the old inode; an in-place rewrite with its time restored is also another version.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func choicesAndReadbackFollowAReplacementWithTheSameSizeAndDate() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("frame.ARW")
        let replacement = folder.appendingPathComponent("replacement.ARW")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try copyRaw(Self.lossless, to: copy, iso: 400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.path)
        let first = try #require(DecoderChoices.stamp(copy.path))
        let choices = DecoderChoices(route: .inHouse)
        #expect(choices.choice(for: copy) == .inHouse)
        let readback = DecodeReadback(asShotTemperature: 5000, asShotTint: 0, neutralTemperature: 5500, neutralTint: 10)
        choices.keepReadback(readback, for: copy, readAt: first)
        #expect(choices.knownReadback(copy) == readback)

        try copyRaw(Self.lossless, to: replacement, iso: 6400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: copy)
        try FileManager.default.moveItem(at: replacement, to: copy)
        let second = try #require(DecoderChoices.stamp(copy.path))
        #expect(second.size == first.size && second.modified == first.modified && second.inode != first.inode)
        // Reject a read-back from the earlier file even before a new routing lookup.
        #expect(choices.knownReadback(copy) == nil)
        choices.keepReadback(readback, for: copy, readAt: first)
        #expect(choices.choice(for: copy) == .apple && choices.knownReadback(copy) == nil)
        // Nor may a late reader of the old file contaminate the new entry.
        choices.keepReadback(readback, for: copy, readAt: first)
        #expect(choices.knownReadback(copy) == nil)

        // In place, on the temporary directory's local volume: only status time reveals the write.
        try copyRaw(Self.lossless, to: copy, iso: 400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.path)
        let third = try #require(DecoderChoices.stamp(copy.path))
        #expect(third.size == second.size && third.modified == second.modified && third.inode == second.inode)
        #expect(third.changed != nil && third.changed != second.changed)
        #expect(choices.choice(for: copy) == .inHouse)
    }

    /// A decoder failure remains sticky for unchanged bytes; a replacement retries, and a failure
    /// delivered late from the old decode cannot mark the replacement as failed. On both routes that
    /// fall back, the in-house decoder's and RAW 9's.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples), arguments: [(DecoderRoute.inHouse, DecoderChoice.inHouse), (.raw9, .raw9)])
    func failuresBelongToTheVersionThatFailed(_ route: DecoderRoute, chosen: DecoderChoice) throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("frame.ARW")
        let replacement = folder.appendingPathComponent("replacement.ARW")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.copyItem(at: Self.lossless, to: copy)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.path)
        let first = try #require(DecoderChoices.stamp(copy.path))
        let choices = DecoderChoices(route: route)
        #expect(choices.choice(for: copy) == chosen)
        choices.noteFailure(copy, readAt: first)
        #expect(choices.choice(for: copy) == .apple && choices.choice(for: copy) == .apple)

        try FileManager.default.copyItem(at: Self.lossless, to: replacement)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: copy)
        try FileManager.default.moveItem(at: replacement, to: copy)
        let second = try #require(DecoderChoices.stamp(copy.path))
        #expect(second.size == first.size && second.modified == first.modified && second.inode != first.inode)
        #expect(choices.choice(for: copy) == chosen)
        choices.noteFailure(copy, readAt: first)
        #expect(choices.choice(for: copy) == chosen)
        choices.noteFailure(copy, readAt: second)
        #expect(choices.choice(for: copy) == .apple)
    }

    /// An in-house frame carries the white-balance read-back Apple's decode of it records.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func inHouseFramesCarryApplesReadback() throws {
        let gpu = try GPU()
        var options = DecodeOptions()
        options.maxLongSide = 960
        let chosen = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .inHouse))
        let first = try chosen.decode(Self.lossless, options: options)
        let again = try chosen.decode(Self.lossless, options: options)
        let apple = try AppleRawDecoder(gpu: gpu).decode(Self.lossless, options: options)
        #expect(first.decoderVersion == InHouseDecoder.version && first.pins?.decoderVersion == InHouseDecoder.version)
        #expect(first.width == 960 && first.height == 640 && first.pins?.draftMode == false)
        #expect(first.readback != nil && first.readback == apple.readback && again.readback == apple.readback)
        let forced = try ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .apple)).decode(Self.lossless, options: options)
        #expect(forced.decoderVersion == AppleRawDecoder.pinnedDecoderVersion && forced.pins?.draftMode == true)
    }

    /// A file the in-house decoder takes but cannot decode goes to Apple's, then and for the rest of
    /// the session.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func fallsBackToApplesDecoder() throws {
        let gpu = try GPU()
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let damaged = folder.appendingPathComponent("damaged.ARW")
        var data = try Data(contentsOf: Self.lossless)
        let raw = try SonyLosslessRaw.read(from: Self.lossless)
        // The last tile's start of scan, where the in-house decoder reads its Huffman table, made
        // a marker it refuses.
        let last = raw.tileOffsets.last!
        data.replaceSubrange(last..<last + 4, with: [0xFF, 0xD8, 0xFF, 0x01])
        try data.write(to: damaged)
        #expect(InHouseDecoder.supports(damaged))
        var options = DecodeOptions()
        options.maxLongSide = 960
        #expect(throws: (any Error).self) { try InHouseDecoder(gpu: gpu).decode(damaged, options: options) }
        let choices = DecoderChoices(route: .inHouse)
        #expect(choices.choice(for: damaged) == .inHouse)
        let chosen = ChosenDecoder(gpu: gpu, choices: choices)
        // Apple's decoder may refuse the damage too; the fallback then throws Apple's error, not the
        // in-house decoder's.
        switch Result(catching: { try AppleRawDecoder(gpu: gpu).decode(damaged, options: options) }) {
        case .success(let apple):
            let frame = try chosen.decode(damaged, options: options)
            #expect(frame.decoderVersion == AppleRawDecoder.pinnedDecoderVersion && frame.decoderVersion == apple.decoderVersion)
        case .failure(let refused):
            print("Apple's decoder refused the damaged copy too: \(refused)")
            let error = #expect(throws: (any Error).self) { try chosen.decode(damaged, options: options) }
            #expect(error.map { "\(type(of: $0)): \($0)" } == "\(type(of: refused)): \(refused)")
        }
        #expect(choices.choice(for: damaged) == .apple)
    }

    /// A file that cannot be read, as when its share drops, is a read error and not a file the in-house
    /// decoder fails on: once it can be read again it is the in-house decoder's, its choice not kept
    /// from the failed read nor given to Apple's for the session. A copy without read permission
    /// stands in for the dropped share; its size and date stay as they were.
    @Test(.enabled(if: DecoderChoiceSampleTests.hasSamples))
    func anUnreadableFileIsNotAnInHouseFailure() throws {
        let gpu = try GPU()
        let folder = try scratch()
        let copy = folder.appendingPathComponent("frame.ARW")
        func readable(_ yes: Bool) throws {
            try FileManager.default.setAttributes([.posixPermissions: yes ? 0o644 : 0], ofItemAtPath: copy.path)
        }
        defer {
            try? readable(true)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.copyItem(at: Self.lossless, to: copy)
        let choices = DecoderChoices(route: .inHouse)
        try readable(false)
        #expect(throws: InHouseDecodeError.self) { try DecoderChoice.read(copy, route: .inHouse) }
        #expect(choices.choice(for: copy) == .apple)
        try readable(true)
        #expect(choices.choice(for: copy) == .inHouse)

        var options = DecodeOptions()
        options.maxLongSide = 960
        let chosen = ChosenDecoder(gpu: gpu, choices: choices)
        try readable(false)
        do {
            _ = try chosen.decode(copy, options: options)
            Issue.record("decoded a file it cannot read")
        } catch InHouseDecodeError.unreadable {
        } catch {
            Issue.record("\(error)")
        }
        try readable(true)
        #expect(choices.choice(for: copy) == .inHouse)
        #expect(try chosen.decode(copy, options: options).decoderVersion == InHouseDecoder.version)
    }
}
