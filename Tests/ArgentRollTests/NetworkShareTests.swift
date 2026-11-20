import Darwin
import Foundation
import Metal
import Testing
@testable import ArgentCore
@testable import ArgentRoll

/// A roll on a network share, behind docs/M2-shell.md section 6. Runs only with ARGENT_SHARE_ROLL
/// naming a folder on a mounted share that holds copies of the CC0 samples:
///
///     ARGENT_SHARE_ROLL="/Volumes/Shared/Argent NAS test" swift test --filter NetworkShareTests
///
/// With ARGENT_SHARE_DIGESTS naming a file as well, the first run keeps the roll's digests in it, and
/// a run after the share is mounted again checks that no raw would be read whole again.
@Suite(.serialized, .rawDecodes) struct NetworkShareTests {
    static let roll = ProcessInfo.processInfo.environment["ARGENT_SHARE_ROLL"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let digestsFile = ProcessInfo.processInfo.environment["ARGENT_SHARE_DIGESTS"].map { URL(fileURLWithPath: $0) }
    static var enabled: Bool { roll != nil }
    static var remounting: Bool { roll != nil && digestsFile != nil }
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples")

    static func raws() throws -> [URL] {
        let raws = RollScanner.rawFiles(in: try #require(roll)).sorted { $0.path < $1.path }
        try #require(!raws.isEmpty, "no raws in the share's roll")
        return raws
    }

    /// The local sample `raw` is a copy of, if there is one.
    static func sample(_ raw: URL) -> URL? {
        let url = samples.appendingPathComponent(raw.lastPathComponent)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file `data`'s bytes are mapped from, if they are.
    static func mappedFile(of data: Data) -> String? {
        data.withUnsafeBytes { bytes -> String? in
            guard let base = bytes.baseAddress else { return nil }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_regionfilename(getpid(), UInt64(UInt(bitPattern: base)), &path, UInt32(path.count))
            return length > 0 ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        }
    }

    /// The roll is on a network volume, which digests name by its address without the user, and the
    /// in-house decoder reads its raws whole where it maps the same raw on the Mac's disk.
    @Test(.enabled(if: NetworkShareTests.enabled))
    func theShareIsReadWholeAndNamedByItsAddress() throws {
        for url in try Self.raws() {
            #expect(try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == false, "not on a share: \(url.path)")
            let name = try #require(SourceDigests.volumeName(of: url))
            #expect(name.contains("://") && !name.contains("@"), "\(name)")
            #expect(!InHouseDecoder.mapsFile(at: url))
            let bytes = try InHouseDecoder.contents(of: url)
            #expect(Self.mappedFile(of: bytes) == nil, "\(url.lastPathComponent) is mapped")
            if let local = Self.sample(url) {
                let mapped = try InHouseDecoder.contents(of: local)
                #expect(Self.mappedFile(of: mapped) != nil && mapped == bytes, "\(url.lastPathComponent)")
            }
        }
    }

    /// Each raw decodes from the share to the pixels it decodes to from the Mac's disk, by the decoder
    /// the app gives it, at the sheet's size and at full size.
    @Test(.enabled(if: NetworkShareTests.enabled))
    func decodesAsFromTheMacsDisk() throws {
        let gpu = try GPU()
        let decoder = ChosenDecoder(gpu: gpu, choices: DecoderChoices(route: .raw9))
        var compared = 0
        for url in try Self.raws() {
            guard let local = Self.sample(url) else { continue }
            for longSide in [FilmPreviews.previewLongSide, nil] {
                var options = DecodeOptions()
                options.maxLongSide = longSide
                let shared = try decoder.decode(url, options: options), own = try decoder.decode(local, options: options)
                #expect(shared.decoderVersion == own.decoderVersion && shared.readback == own.readback, "\(url.lastPathComponent)")
                #expect(TiledDecodeTests.pixels(shared.texture) == TiledDecodeTests.pixels(own.texture),
                        "\(url.lastPathComponent) at \(longSide.map(String.init) ?? "full size")")
                compared += 1
            }
        }
        try #require(compared > 0, "no raw in the share's roll is a copy of a sample")
    }

    /// The roll develops from the share, every frame, and a develop of it again with the same recipes
    /// finds every frame developed: Argent's own reads leave each raw the file it was.
    @Test(.enabled(if: NetworkShareTests.enabled))
    func theRollDevelopsAndIsSkippedAgain() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let roll = await RollScanner.scan(try #require(Self.roll))
        for frame in roll.frames {
            try #require(!FileManager.default.fileExists(atPath: RecipeStore.besideRaw(frame.url).path),
                         "Use disposable RAW copies without existing Argent recipes: \(frame.url.lastPathComponent)")
        }
        defer {
            for frame in roll.frames { try? FileManager.default.removeItem(at: RecipeStore.besideRaw(frame.url)) }
        }
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let library = root.appendingPathComponent("library"), out = root.appendingPathComponent("out")
        let developer = try RollDeveloper(stocks: [stock], software: "Argent share test", library: library)
        let output = OutputSettings(format: .jpeg, size: .longEdge2048, space: .sRGB)
        func jobs() -> [RollDeveloper.Job] {
            roll.frames.map { frame in
                RollDeveloper.Job(frame: frame, recipe: Recipe(frame: frame, byteCount: RecipeStore.byteCount(of: frame.url),
                                                               stock: stock, stockDigest: stock.digest, roll: RollControls(),
                                                               own: FrameControls(), previous: RecipeStore.read(for: frame, library: library)))
            }
        }
        let first = await developer.develop(jobs(), to: out, output: output)
        #expect(first.count == roll.frames.count && first.allSatisfy { if case .developed = $0 { true } else { false } }, "\(first)")
        let second = await developer.develop(jobs(), to: out, output: output)
        #expect(second == first.compactMap(\.file).map { .alreadyDeveloped($0) }, "\(second)")
    }

    /// The digests kept for the roll come back after the share is mounted again, under another device
    /// number: the first run keeps them in ARGENT_SHARE_DIGESTS, as the app keeps its own, with the
    /// share's device number beside them; the run after the share is mounted again finds every raw
    /// known, by the SHA-256 it has, and reads none whole.
    @Test(.enabled(if: NetworkShareTests.remounting))
    func digestsOutliveMountingTheShareAgain() throws {
        let file = try #require(Self.digestsFile), devices = file.appendingPathExtension("device")
        let raws = try Self.raws()
        let device = try #require(SourceStamp.of(raws[0])).device
        guard FileManager.default.fileExists(atPath: file.path) else {
            let digests = SourceDigests()
            digests.persist(to: file)
            for url in raws { _ = try digests.digest(of: url) }
            digests.flush()
            try Data("\(device)".utf8).write(to: devices)
            print("kept \(raws.count) digests at device \(device); mount the share again and run again")
            return
        }
        #expect(try String(contentsOf: devices, encoding: .utf8) != "\(device)", "the share was not mounted again since the first run")
        let digests = SourceDigests()
        digests.persist(to: file)
        for url in raws {
            let known = try #require(digests.known(url), "\(url.lastPathComponent) would be read whole again")
            #expect(known.sha256 == (try SourceDigests.read(url).sha256))
        }
        #expect(digests.readCount == 0)
    }
}
