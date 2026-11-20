import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// A recipe beside a raw is the raw's only while the raw is the file it was made from, byte for
/// byte. These replace a raw under its recipe, with another size and with the same size, edit one
/// in place, and move one unchanged, with fake raws: none of them decodes, so a frame skipped as
/// developed shows as `alreadyDeveloped` and one developed again as a decode failure, and no
/// sample is needed.
@Suite struct SourceIdentityTests {
    private static func stock() -> Stock {
        Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
              exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
    }

    private static let analysis = ExposureAnalysis(meanStops: -0.4, validWeight: 0.9)
    private static let captured = Date(timeIntervalSince1970: 1_697_732_028.776)

    /// `count` bytes from `seed`, a raw's stand-in.
    static func bytes(_ count: Int, seed: UInt64) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        var words = [UInt64](repeating: 0, count: (count + 7) / 8)
        for index in words.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            words[index] = state
        }
        return words.withUnsafeBytes { Data($0.prefix(count)) }
    }

    /// `url`'s bytes with the one at `offset` changed, written over it in place, at the same size.
    static func edit(_ url: URL, at offset: Int) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let byte = try #require(try handle.read(upToCount: 1))
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data([byte[0] ^ 0x5A]))
    }

    private static func frame(_ url: URL) -> Frame {
        Frame(id: 0, url: url, info: ARWFrameInfo(captureDate: captured))
    }

    /// A pin set this build records, for the decoder `decoderVersion`.
    private static func pins(_ decoderVersion: String) -> DecodePins {
        DecodePins(version: DecodePins.currentVersion, decoderVersion: decoderVersion, baselineExposure: 0, shadowBias: 0,
                   sharpness: 0, boost: 0, boostShadow: 0, gamutMapping: false, highlightRecovery: true,
                   extendedDynamicRange: 1, neutralChromaticity: .init(x: 0.33, y: 0.35), moireReduction: 1, contrast: 0,
                   detail: 0, anchorDecodedMidTone: 0.08, anchorVersion: "1", exposureGainStops: 1,
                   luminanceNoiseReduction: 0.4, colorNoiseReduction: 0.5, lensCorrection: true, scale: 1, draftMode: false)
    }

    /// A roll of fake raws, a developer, and the output folder. The digests are the scene's own,
    /// kept as soon as read, so what each step reads is counted.
    private struct Scene {
        let root: URL
        let roll: URL
        let out: URL
        let library: URL
        let raw: URL
        let digests = SourceDigests(settle: 0)
        let developer: RollDeveloper
        let output = OutputSettings()
        var frame: Frame { SourceIdentityTests.frame(raw) }
        var developed: URL { out.appendingPathComponent("DSC00601.jpg") }

        init(rawBytes: Data) throws {
            root = try temporaryFolder()
            roll = root.appendingPathComponent("roll")
            out = root.appendingPathComponent("out")
            library = root.appendingPathComponent("library")
            for folder in [roll, out] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            raw = roll.appendingPathComponent("DSC00601.ARW")
            try rawBytes.write(to: raw)
            developer = try RollDeveloper(stocks: [SourceIdentityTests.stock()], software: "Argent test", library: library,
                                          digests: digests)
        }

        func read(_ frame: Frame? = nil) -> Recipe? { RecipeStore.read(for: frame ?? self.frame, library: library, digests: digests) }

        /// The recipe the app makes for the frame now, from what is beside it: as `read` gives it,
        /// or, `known`, as the app's develop does, from what the digests know without reading the raw.
        func job(for frame: Frame? = nil, analysis: ExposureAnalysis? = SourceIdentityTests.analysis,
                 measuredFrom: SourceStamp? = nil, known: Bool = false) -> RollDeveloper.Job {
            let frame = frame ?? self.frame
            let stock = SourceIdentityTests.stock()
            let previous = known ? opened([frame])[0]?.recipe : read(frame)
            return RollDeveloper.Job(frame: frame, recipe: Recipe(
                frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                roll: RollControls(ratedAt: .oneStopOver), own: FrameControls(labBalance: .warm), analysis: analysis,
                grain: output.grain, sharpen: true, previous: previous), measuredFrom: measuredFrom)
        }

        /// The recipes as opening the roll finds them, reading no raw.
        func opened(_ frames: [Frame]? = nil, stopped: @escaping @Sendable () -> Bool = { false }) -> [RecipeStore.Checked?] {
            RecipeStore.checked(for: frames ?? [frame], library: library, digests: digests, check: .knownOnly, stopped: stopped)
        }

        /// The recipe a develop of this build leaves beside the raw, to `developed`, which is
        /// there: the one the next develop skips. It records the raw's whole SHA-256.
        @discardableResult
        func developedRecipe() throws -> Recipe {
            var recipe = job().recipe
            recipe.raw.sha256 = try RecipeStore.sha256(of: raw)
            recipe.develops.append(.init(
                date: Date(timeIntervalSince1970: 1_697_800_000), software: "Argent test", output: output, file: developed.path, width: 6000, height: 4000,
                render: recipe.render, decode: SourceIdentityTests.pins(developer.decoderChoices.decoderVersion(for: raw)),
                readback: nil, stockDigest: recipe.stock.digest, renderVersion: RenderGraph.version(for: recipe.render.settings)))
            try Data("developed".utf8).write(to: developed)
            try RecipeStore.write(recipe, for: frame, library: library)
            return recipe
        }

        /// One develop of the frame as the app starts it.
        func develop(_ frame: Frame? = nil, measuredFrom: SourceStamp? = nil, known: Bool = false) async -> RollDeveloper.Outcome {
            await developer.develop([job(for: frame, measuredFrom: measuredFrom, known: known)], to: out, output: output)[0]
        }

        func restored(_ frame: Frame? = nil) -> RestoredRoll {
            let frame = frame ?? self.frame
            return RestoredRoll(frames: [frame], checked: [RecipeStore.checked(for: frame, library: library, digests: digests)])
        }

        var sidecar: Data? { try? Data(contentsOf: RecipeStore.besideRaw(raw)) }
    }

    private static func isAlreadyDeveloped(_ outcome: RollDeveloper.Outcome) -> Bool {
        if case .alreadyDeveloped = outcome { return true }
        return false
    }

    private static func isFailed(_ outcome: RollDeveloper.Outcome, saying words: String) -> Bool {
        if case .failed(let reason) = outcome { return reason.contains(words) }
        return false
    }

    // MARK: Another raw under the recipe's name

    @Test func aRawOfAnotherSizeGivesBackNeitherItsMeasurementNorItsDevelop() async throws {
        let scene = try Scene(rawBytes: Self.bytes(600_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.developedRecipe()
        try Self.bytes(640_000, seed: 2).write(to: scene.raw)

        #expect(scene.restored().analyses.isEmpty)
        #expect(scene.read()?.develops.isEmpty == true)
        // The settings are the user's and stay.
        #expect(scene.restored().overrides == [scene.raw: FrameControls(labBalance: .warm)])
        #expect(scene.restored().controls == RollControls(ratedAt: .oneStopOver))
        // Developed again, not skipped: the fake raw fails at its decode.
        let outcome = await scene.develop()
        #expect(!Self.isAlreadyDeveloped(outcome), "\(outcome)")
        // The develop of the other raw is not written over.
        #expect(try Data(contentsOf: scene.developed) == Data("developed".utf8))
    }

    @Test func aRawOfTheSameSizeAndOtherBytesKeepsOnlyItsSettings() async throws {
        let scene = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let recipe = try scene.developedRecipe()
        try Self.bytes(2_000_000, seed: 4).write(to: scene.raw)

        let read = try #require(scene.read())
        #expect(read.analysis == nil && read.printLevel == nil && read.printCast == nil)
        #expect(read.develops.isEmpty && read.raw.sha256 == nil)
        #expect(read.stock == recipe.stock && read.roll == recipe.roll && read.frame == recipe.frame)
        #expect(scene.restored().analyses.isEmpty && scene.restored().sources.isEmpty)
        #expect(scene.restored().overrides == [scene.raw: FrameControls(labBalance: .warm)])
        // The other raw's develop is not this one's: another name, and not skipped.
        #expect(RollDeveloper.files(for: [scene.job()], in: scene.out, output: scene.output).map(\.lastPathComponent)
                == ["DSC00601 2.jpg"])
        let outcome = await scene.develop()
        #expect(!Self.isAlreadyDeveloped(outcome), "\(outcome)")
        #expect(try Data(contentsOf: scene.developed) == Data("developed".utf8))
    }

    /// The counterexample to the sampled fingerprint of the first round: a 2,000,000-byte raw edited
    /// in place at byte 300,000, after the 256 KB head and before the first block it sampled, at the
    /// same size with the same headers. The whole file's SHA-256 sees it.
    @Test func aRawEditedInPlaceBetweenWhereAnySampleWouldFallIsAnotherRaw() async throws {
        let scene = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.developedRecipe()
        #expect(scene.restored().analyses == [scene.raw: Self.analysis])
        try Self.edit(scene.raw, at: 300_000)

        #expect(scene.restored().analyses.isEmpty)
        #expect(scene.read()?.develops.isEmpty == true)
        let outcome = await scene.develop()
        #expect(!Self.isAlreadyDeveloped(outcome), "\(outcome)")
        #expect(try Data(contentsOf: scene.developed) == Data("developed".utf8))
        // Any byte, the last one too.
        let other = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: other.root) }
        try other.developedRecipe()
        try Self.edit(other.raw, at: 1_999_999)
        #expect(other.restored().analyses.isEmpty)
        #expect(!Self.isAlreadyDeveloped(await other.develop()))
    }

    // MARK: The same raw

    /// Found unchanged, read whole once: a second open and a second develop read nothing, and the
    /// recipe is not written again.
    @Test func theSameRawComesBackWholeIsSkippedAndIsReadOnce() async throws {
        let scene = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let recipe = try scene.developedRecipe()
        #expect(scene.read() == recipe)
        #expect(scene.digests.readCount == 1)
        let restored = scene.restored()
        #expect(restored.analyses == [scene.raw: Self.analysis] && restored.sources == [scene.raw: SourceStamp.of(scene.raw)!])
        let sidecar = scene.sidecar
        #expect(Self.isAlreadyDeveloped(await scene.develop()))
        #expect(Self.isAlreadyDeveloped(await scene.develop()))
        #expect(scene.sidecar == sidecar)
        #expect(scene.digests.readCount == 1)
    }

    /// A raw rewritten with the same bytes, or touched, has another version: read whole again,
    /// found the same, and still skipped.
    @Test func theSameBytesWrittenAgainAreReadAgainAndStillTheSameRaw() async throws {
        let scene = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.developedRecipe()
        #expect(scene.restored().analyses.count == 1 && scene.digests.readCount == 1)
        let before = SourceStamp.of(scene.raw)
        try Data(contentsOf: scene.raw).write(to: scene.raw)
        #expect(SourceStamp.of(scene.raw) != before)
        #expect(scene.restored().analyses.count == 1 && scene.digests.readCount == 2)
        #expect(Self.isAlreadyDeveloped(await scene.develop()))
    }

    @Test func aRecipeMovedWithItsRawComesBackWholeAndIsSkipped() async throws {
        let scene = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let recipe = try scene.developedRecipe()
        // Copied, so another file, and moved, so the same file under another name.
        for move in [false, true] {
            let moved = scene.root.appendingPathComponent(move ? "moved" : "copied")
            try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
            for url in [scene.raw, RecipeStore.besideRaw(scene.raw)] {
                let to = moved.appendingPathComponent(url.lastPathComponent)
                if move { try FileManager.default.moveItem(at: url, to: to) } else { try FileManager.default.copyItem(at: url, to: to) }
            }
            let frame = Self.frame(moved.appendingPathComponent("DSC00601.ARW"))
            #expect(scene.read(frame) == recipe)
            #expect(scene.restored(frame).analyses == [frame.url: Self.analysis])
            #expect(Self.isAlreadyDeveloped(await scene.develop(frame)))
        }
    }

    /// Recipes from before this build: the first round's, which also carried a sampled fingerprint
    /// of the raw, and the ones before it, with the whole file's SHA-256 alone. The fingerprint is
    /// read past: the SHA-256 alone decides.
    @Test func aRecipeWithTheFirstRoundsFingerprintIsCheckedByItsSHA256Alone() async throws {
        let scene = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let recipe = try scene.developedRecipe()
        var json = try #require(try JSONSerialization.jsonObject(with: recipe.encoded()) as? [String: Any])
        var raw = try #require(json["raw"] as? [String: Any])
        raw["fingerprint"] = "s1:" + String(repeating: "ab", count: 32)
        json["raw"] = raw
        try JSONSerialization.data(withJSONObject: json).write(to: RecipeStore.besideRaw(scene.raw))
        #expect(scene.read() == recipe)
        #expect(Self.isAlreadyDeveloped(await scene.develop()))

        try Self.edit(scene.raw, at: 300_000)
        #expect(scene.restored().analyses.isEmpty)
        #expect(!Self.isAlreadyDeveloped(await scene.develop()))

        // Without a SHA-256 nothing vouches for the measurement or the develops.
        var unhashed = recipe
        unhashed.raw.sha256 = nil
        try RecipeStore.write(unhashed, for: scene.frame, library: scene.library)
        #expect(scene.restored().analyses.isEmpty && scene.read()?.develops == recipe.develops)
        #expect(RollDeveloper.checkingSource(RollDeveloper.Job(frame: scene.frame, recipe: unhashed), digests: scene.digests)
                .job?.recipe.develops.isEmpty == true)
    }

    // MARK: Opening a roll

    /// Opening a roll reads no raw whole. A recipe whose raw's version the digests do not know comes
    /// back with its stock, controls and develops but not its measurement, which the sheet makes
    /// again; once the raw has been read whole, by the disk cache or a develop's check, all of it.
    /// A raw replaced at the same size is not known either, so nothing of the old one is trusted.
    @Test func openingReadsNoRawAndTrustsOnlyAMeasurementOfAKnownVersion() throws {
        let scene = try Scene(rawBytes: Self.bytes(3 << 20, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let recipe = try scene.developedRecipe()

        let cold = scene.opened()
        let coldRoll = RestoredRoll(frames: [scene.frame], checked: cold)
        #expect(scene.digests.readCount == 0)
        #expect(cold == [RecipeStore.Checked(recipe: recipe.forgettingMeasurement(), source: nil)])
        #expect(coldRoll.analyses.isEmpty && coldRoll.sources.isEmpty)
        #expect(coldRoll.stockID == recipe.stock.id && coldRoll.controls == recipe.roll)
        #expect(coldRoll.overrides == [scene.raw: FrameControls(labBalance: .warm)])
        #expect(coldRoll.destination?.standardizedFileURL.path == scene.out.standardizedFileURL.path)

        let verified = try scene.digests.digest(of: scene.raw)
        let warm = scene.opened()
        let warmRoll = RestoredRoll(frames: [scene.frame], checked: warm)
        #expect(warm == [RecipeStore.Checked(recipe: recipe, source: verified.source)])
        #expect(warmRoll.analyses == [scene.raw: Self.analysis] && warmRoll.sources == [scene.raw: verified.source])
        #expect(scene.digests.readCount == 1)

        try Self.bytes(3 << 20, seed: 2).write(to: scene.raw)
        let replaced = scene.opened()
        #expect(scene.digests.readCount == 1)
        #expect(replaced == [RecipeStore.Checked(recipe: recipe.forgettingMeasurement(), source: nil)])
        #expect(RestoredRoll(frames: [scene.frame], checked: replaced).analyses.isEmpty)
        // Read whole since, by the sheet's disk cache: known to be another raw, its settings alone.
        _ = try scene.digests.digest(of: scene.raw)
        #expect(scene.opened() == [RecipeStore.Checked(recipe: recipe.forgettingSource(), source: nil)])
        // The exact read for those that need it still reads a raw it does not know.
        try Self.bytes(3 << 20, seed: 3).write(to: scene.raw)
        #expect(scene.read() == recipe.forgettingSource() && scene.digests.readCount == 3)
    }

    /// An open superseded by another reads no more recipes.
    @Test func anOpenSupersededReadsNoMoreRecipes() throws {
        let scene = try Scene(rawBytes: Self.bytes(600_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.developedRecipe()
        let frames = Array(repeating: scene.frame, count: 40)
        #expect(scene.opened(frames, stopped: { true }).allSatisfy { $0 == nil })
        #expect(scene.opened(frames).allSatisfy { $0 != nil })
        #expect(scene.digests.readCount == 0)
    }

    /// The app's develop builds its jobs from the recipes as opening finds them, reading no raw;
    /// its own check then reads each raw once and keeps the develops only for the raw they were
    /// made from: skipped for the same raw, made again, under another name, for another raw of
    /// the same size.
    @Test func aDevelopFromRecipesAsOpenedKeepsTheirDevelopsOnlyForTheirRaw() async throws {
        let scene = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        try scene.developedRecipe()
        #expect(Self.isAlreadyDeveloped(await scene.develop(known: true)))
        #expect(scene.digests.readCount == 1)

        try Self.bytes(2_000_000, seed: 4).write(to: scene.raw)
        #expect(scene.job(known: true).recipe.develops.count == 1 && scene.digests.readCount == 1)
        let outcome = await scene.develop(measuredFrom: SourceStamp.of(scene.raw), known: true)
        #expect(!Self.isAlreadyDeveloped(outcome), "\(outcome)")
        #expect(scene.digests.readCount == 2)
        #expect(try Data(contentsOf: scene.developed) == Data("developed".utf8))
    }

    @Test func aRecipeMadeFromOneForARawOfAnotherSizeKeepsNoDevelop() throws {
        let scene = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let previous = try scene.developedRecipe()
        let stock = Self.stock()
        func made(byteCount: Int) -> Recipe {
            Recipe(frame: scene.frame, byteCount: byteCount, stock: stock, stockDigest: stock.digest, roll: previous.roll,
                   own: previous.frame, analysis: Self.analysis, grain: .natural, sharpen: true, previous: previous)
        }
        let same = made(byteCount: 2_000_000)
        #expect(same.develops == previous.develops && same.raw == previous.raw)
        let other = made(byteCount: 2_000_001)
        #expect(other.develops.isEmpty && other.raw.sha256 == nil)
    }

    // MARK: A measurement is the raw's it was made from

    /// A develop given a recipe it cannot trust, as from a caller that did not read it through the
    /// store, checks the raw itself: a recipe measured from the raw it records fails for another
    /// raw rather than print it with the other raw's exposure and cast, and writes nothing.
    @Test func aMeasurementOfAnotherRawFailsTheFrame() async throws {
        let scene = try Scene(rawBytes: Self.bytes(2_000_000, seed: 1))
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let recipe = try scene.developedRecipe()
        let sidecar = scene.sidecar
        try Self.edit(scene.raw, at: 300_000)
        let stale = RollDeveloper.Job(frame: scene.frame, recipe: recipe)
        #expect(Self.isFailed(await scene.developer.develop([stale], to: scene.out, output: scene.output)[0],
                              saying: "changed after it was measured"))
        #expect(scene.sidecar == sidecar && (try? Data(contentsOf: scene.developed)) == Data("developed".utf8))

        // Measured from the raw there now by the caller: printed, its old develops gone.
        let now = try #require(SourceStamp.of(scene.raw))
        let fresh = RollDeveloper.Job(frame: scene.frame, recipe: recipe, measuredFrom: now)
        let checked = try #require(RollDeveloper.checkingSource(fresh, digests: scene.digests).job)
        #expect(checked.recipe.develops.isEmpty && checked.recipe.analysis == recipe.analysis)
        #expect(try checked.recipe.raw.sha256 == RecipeStore.sha256(of: scene.raw))

        // Measured from a version of the raw it is no longer at.
        try Self.edit(scene.raw, at: 1_000_000)
        #expect(Self.isFailed(await scene.develop(measuredFrom: now), saying: "changed after it was measured"))
        // With nothing measured there is nothing to fail: developed from the controls alone.
        let unmeasured = scene.job(analysis: nil, measuredFrom: now)
        #expect(!unmeasured.recipe.isMeasured)
        #expect(RollDeveloper.checkingSource(unmeasured, digests: scene.digests).job != nil)
    }

    // MARK: Reading the raw

    /// A raw that cannot be read to its end, or changes while it is read, is not given a SHA-256,
    /// and nothing is kept of the read.
    @Test func aReadThatIsNotWholeAndStillIsNotTrusted() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("raw")
        let digests = SourceDigests(settle: 0)
        func reading(_ during: @escaping (FileHandle) throws -> Void) throws -> Result<SourceDigests.Verified, Error> {
            try Self.bytes(3 << 20, seed: 8).write(to: url)
            var chunks = 0
            let writer = try FileHandle(forUpdating: url)
            defer { try? writer.close() }
            // Called before each megabyte: the file changes after the first.
            return Result {
                try digests.digest(of: url, stopped: {
                    chunks += 1
                    if chunks == 2 { try? during(writer) }
                    return false
                })
            }
        }
        // Cut short, grown, and written over in place at the same size.
        let short = try reading { try $0.truncate(atOffset: 1_500_000) }
        #expect(throws: SourceDigests.Failure.incomplete(expected: 3 << 20, read: 1_500_000)) { try short.get() }
        let grown = try reading { try $0.seekToEnd(); try $0.write(contentsOf: Data(count: 10)) }
        #expect(throws: SourceDigests.Failure.self) { try grown.get() }
        let rewritten = try reading { try $0.seek(toOffset: 3 << 20 - 1); try $0.write(contentsOf: Data([7])) }
        #expect(throws: SourceDigests.Failure.changedWhileRead) { try rewritten.get() }
        #expect(digests.known(url) == nil && digests.readCount == 0)
        // Replaced under its name while read.
        let replaced = try reading { _ in
            try Self.bytes(3 << 20, seed: 9).write(to: root.appendingPathComponent("other"))
            _ = try FileManager.default.replaceItemAt(url, withItemAt: root.appendingPathComponent("other"))
        }
        #expect(throws: SourceDigests.Failure.changedWhileRead) { try replaced.get() }
        #expect(throws: SourceDigests.Failure.self) { try digests.digest(of: root.appendingPathComponent("none")) }

        // Read whole and unchanged, it is kept; a change just before the read is not trusted to show.
        let whole = try digests.digest(of: url)
        #expect(try digests.known(url) == whole && whole.sha256 == RecipeStore.sha256(of: url))
        let careful = SourceDigests()
        _ = try careful.digest(of: url)
        #expect(careful.known(url) == nil)
    }

    /// The digests kept go to their file and come back from it, so a roll opened again after a
    /// relaunch is not read whole; at most `limit`, the least recently used going first.
    @Test func keptDigestsPersistAndAreBounded() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("digests.json")
        let urls = try (0..<4).map { index -> URL in
            let url = root.appendingPathComponent("\(index).ARW")
            try Self.bytes(10_000, seed: UInt64(index)).write(to: url)
            return url
        }
        let first = SourceDigests(limit: 3, settle: 0)
        first.persist(to: file)
        for url in urls.prefix(3) { _ = try first.digest(of: url) }
        first.flush()
        let again = SourceDigests(limit: 3, settle: 0)
        again.persist(to: file)
        #expect(urls.prefix(3).allSatisfy { again.known($0) != nil })
        _ = try again.digest(of: urls[3])
        #expect(urls.filter { again.known($0) != nil }.count <= 3 && again.known(urls[3]) != nil)
        // A file changed since is read again.
        try Self.edit(urls[3], at: 5)
        #expect(again.known(urls[3]) == nil)
    }

    /// A digest's volume is named by what stays the same from one mount to the next, not its device
    /// number: the Mac's own disk by its UUID; a network share, which has none, by its address
    /// (NetworkShareTests).
    @Test func aDigestsVolumeIsNamedByItsUUID() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("0.ARW")
        try Self.bytes(1000, seed: 1).write(to: url)
        let uuid = try #require(try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        #expect(SourceDigests.volumeName(of: url) == uuid)
    }

    /// A stamp of the file at one path is the same version with another device, as a share mounted
    /// again gives it, and another with any other field changed.
    @Test func aStampIsTheSameVersionOnAShareMountedAgain() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("0.ARW")
        try Self.bytes(1000, seed: 1).write(to: url)
        let stamp = try #require(SourceStamp.of(url))
        var remounted = stamp
        remounted.device &+= 1
        #expect(remounted != stamp && stamp.isSameVersion(atSamePathAs: remounted))
        for change in [{ (s: inout SourceStamp) in s.inode &+= 1 }, { $0.size += 1 }, { $0.modified += 1 }, { $0.changed += 1 }] {
            var other = remounted
            change(&other)
            #expect(!stamp.isSameVersion(atSamePathAs: other))
        }
    }

    /// A stamp keeps the status time only on a local volume, asked once per device; a network share's
    /// status time moves when a file is only mapped (NetworkShareTests), so there it is left out. A
    /// volume that cannot be asked keeps it, and is asked again. On the Mac's disk a change of status
    /// alone is another stamp.
    @Test func statusTimesAreKeptOnlyOnLocalVolumes() throws {
        let times = ChangeTimes()
        #expect(!times.kept(on: 7) { $0.f_flags = 0; return 0 })
        #expect(!times.kept(on: 7) { _ in Issue.record("asked again"); return 0 })
        #expect(times.kept(on: 8) { $0.f_flags = UInt32(MNT_LOCAL); return 0 })
        #expect(times.kept(on: 9) { _ in -1 })
        #expect(!times.kept(on: 9) { $0.f_flags = 0; return 0 })

        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("0.ARW")
        try Self.bytes(1000, seed: 1).write(to: url)
        let before = try #require(SourceStamp.of(url))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let after = try #require(SourceStamp.of(url))
        #expect(after.changed != before.changed && after.modified == before.modified)
    }

    // MARK: Stopping

    /// A roll of `count` frames developed before by a recipe with the raw's SHA-256, whose files
    /// are there: each would be read whole and skipped.
    private static func developedRoll(_ count: Int, in root: URL) throws -> (jobs: [RollDeveloper.Job], out: URL, sidecars: [Data]) {
        let stock = stock(), out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var jobs: [RollDeveloper.Job] = []
        for index in 0..<count {
            let raw = root.appendingPathComponent("DSC0\(1000 + index).ARW")
            try bytes(3 << 20, seed: UInt64(index)).write(to: raw)
            let frame = frame(raw)
            var recipe = Recipe(frame: frame, byteCount: 3 << 20, stock: stock, stockDigest: stock.digest, roll: RollControls(),
                                own: FrameControls(), analysis: analysis)
            recipe.raw.sha256 = try RecipeStore.sha256(of: raw)
            let file = out.appendingPathComponent("\(frame.name).jpg")
            try Data("developed".utf8).write(to: file)
            recipe.develops.append(.init(date: Date(), software: "Argent test", output: OutputSettings(), file: file.path,
                                         width: 1, height: 1, render: recipe.render, decode: pins(AppleRawDecoder.pinnedDecoderVersion),
                                         readback: nil, stockDigest: stock.digest, renderVersion: RenderGraph.version(for: recipe.render.settings)))
            try RecipeStore.write(recipe, for: frame, library: root.appendingPathComponent("library"))
            jobs.append(RollDeveloper.Job(frame: frame, recipe: recipe))
        }
        let sidecars = try jobs.map { try Data(contentsOf: RecipeStore.besideRaw($0.frame.url)) }
        return (jobs, out, sidecars)
    }

    private static func unchanged(_ roll: (jobs: [RollDeveloper.Job], out: URL, sidecars: [Data])) throws -> Bool {
        let sidecars = try roll.jobs.map { try Data(contentsOf: RecipeStore.besideRaw($0.frame.url)) }
        let files = try FileManager.default.contentsOfDirectory(atPath: roll.out.path)
        return sidecars == roll.sidecars && files.count == roll.jobs.count
            && files.allSatisfy { (try? Data(contentsOf: roll.out.appendingPathComponent($0))) == Data("developed".utf8) }
    }

    @Test func aDevelopStoppedBeforeItBeginsReadsNoRaw() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let roll = try Self.developedRoll(12, in: root)
        let digests = SourceDigests(settle: 0)
        let developer = try RollDeveloper(stocks: [Self.stock()], software: "Argent test",
                                          library: root.appendingPathComponent("library"), digests: digests)
        let started = Counter()
        developer.observeCheck = { _ in started.add() }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await developer.develop(roll.jobs, to: roll.out, output: OutputSettings())
        }
        task.cancel()
        #expect(await task.value == roll.jobs.map { _ in .stopped })
        #expect(started.value == 0 && digests.readCount == 0)
        #expect(try Self.unchanged(roll))
    }

    /// Stopped as the first raw begins its check: the raws being read stop between megabytes, and
    /// the rest of the roll is neither read, decoded nor written.
    @Test func aDevelopStoppedWhileCheckingStopsThere() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let roll = try Self.developedRoll(12, in: root)
        let digests = SourceDigests(settle: 0)
        let developer = try RollDeveloper(stocks: [Self.stock()], software: "Argent test",
                                          library: root.appendingPathComponent("library"), digests: digests)
        let started = Counter()
        let held = TaskHolder()
        developer.observeCheck = { _ in
            started.add()
            held.cancel()
        }
        let progress = Counter()
        held.task = Task {
            await developer.develop(roll.jobs, to: roll.out, output: OutputSettings()) { _, _ in progress.add() }
        }
        let outcomes = await held.task!.value
        #expect(outcomes == roll.jobs.map { _ in .stopped })
        #expect(started.value <= RollDeveloper.checkLanes && digests.readCount == 0 && progress.value == 0)
        #expect(try Self.unchanged(roll))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// The develop's task, for a check that starts before it is set to cancel it.
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Task<[RollDeveloper.Outcome], Never>?
    var task: Task<[RollDeveloper.Outcome], Never>? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }

    func cancel() {
        while task == nil { usleep(100) }
        task?.cancel()
    }
}

/// The same with real raws, decoded: runs only where the CC0 samples are present.
@Suite(.serialized, .rawDecodes) struct SourceIdentitySampleTests {
    private static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
    private static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path) }

    /// A copy of the sample in a roll of its own, and a toy stock.
    private static func roll() async throws -> (root: URL, frame: Frame, stocks: [Stock]) {
        let root = try temporaryFolder()
        let folder = root.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sample, to: folder.appendingPathComponent(sample.lastPathComponent))
        try writeToyStock(id: "kodak-portra-400", in: root)
        let frame = try #require(await RollScanner.scan(folder).frames.first)
        return (root, frame, StockLibrary.load(from: root).stocks)
    }

    /// The raw darkened in place at the same size: its raw samples from a third of the way in to a
    /// megabyte from its end zeroed, its header, Exif and preview as they were.
    private static func darken(_ url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let start = bytes.count / 3, end = bytes.count - (1 << 20)
        bytes.replaceSubrange(start..<end, with: Data(count: end - start))
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: bytes)
    }

    /// Developed, skipped, then a byte in its raw samples changed in place, at the same size:
    /// developed again, beside the other raw's file.
    @Test(.enabled(if: SourceIdentitySampleTests.hasSample))
    func aRawChangedInPlaceIsDevelopedAgain() async throws {
        let (root, frame, _) = try await Self.roll()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        let stock = Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: 400, densityRange: 2.5,
                          exposurePerUnit: SIMD3(0.8, 0.85, 0.8), negative: LUT3D.identity(size: 5), print: LUT3D.identity(size: 5))
        let library = root.appendingPathComponent("library")
        let developer = try RollDeveloper(stocks: [stock], software: "Argent test", library: library)
        let output = OutputSettings(size: .longEdge2048)
        func develop() async -> RollDeveloper.Outcome {
            let job = RollDeveloper.Job(frame: frame, recipe: Recipe(
                frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: stock.digest,
                roll: RollControls(), own: FrameControls(), sharpen: true, previous: RecipeStore.read(for: frame, library: library)))
            return await developer.develop([job], to: out, output: output)[0]
        }

        let first = await develop()
        let file = try #require(first.file)
        #expect(first == .developed(file))
        let recipe = try #require(RecipeStore.read(for: frame, library: library))
        #expect(try recipe.raw.sha256 == RecipeStore.sha256(of: frame.url))
        #expect(await develop() == .alreadyDeveloped(file))

        try SourceIdentityTests.edit(frame.url, at: RecipeStore.byteCount(of: frame.url) / 2)
        let again = await develop()
        #expect(again == .developed(out.appendingPathComponent("\(frame.name) 2.jpg")), "\(again)")
        let redone = try #require(RecipeStore.read(for: frame, library: library))
        #expect(try redone.develops.count == 1 && redone.raw.sha256 == RecipeStore.sha256(of: frame.url))
        #expect(FileManager.default.fileExists(atPath: file.path))
        developer.trim()
    }

    /// A roll opened again after its raw was changed at the same size, past the first 256 KB the disk
    /// cache once keyed: decoded and measured again, not read back from the old raw's pixels.
    @Test(.enabled(if: SourceIdentitySampleTests.hasSample))
    func theDiskCacheDoesNotGiveAChangedRawTheOldPixels() async throws {
        let (root, frame, stocks) = try await Self.roll()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LinearDiskCache(folder: root.appendingPathComponent("linear"))
        let first = try FilmPreviews(stocks: stocks, diskCache: disk)
        let before = try #require(await first.analysis(frame))
        disk.flush()
        // Unchanged, it is read back.
        let unchanged = try FilmPreviews(stocks: stocks, diskCache: disk)
        #expect(await unchanged.analysis(frame) == before && unchanged.diskHitCount == 1 && unchanged.decodeCount == 0)

        try Self.darken(frame.url)
        let again = try FilmPreviews(stocks: stocks, diskCache: disk)
        let after = try #require(await again.analysis(frame))
        #expect(again.diskHitCount == 0 && again.decodeCount == 1)
        #expect(after.meanStops < before.meanStops - 0.5, "\(before.meanStops) to \(after.meanStops)")
    }

    /// A raw changed while its roll is open: its decode, render and measurement are made again
    /// from the raw there now, and the measurement says which version it is of.
    @Test(.enabled(if: SourceIdentitySampleTests.hasSample))
    func aRawChangedWhileItsRollIsOpenIsMeasuredAgain() async throws {
        let (root, frame, stocks) = try await Self.roll()
        defer { try? FileManager.default.removeItem(at: root) }
        let films = try FilmPreviews(stocks: stocks)
        let before = try #require(await films.measurement(frame))
        #expect(before.source == SourceStamp.of(frame.url))
        let film = try #require(await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
        // A measurement from a recipe of this version is not taken over the one made of it.
        films.seedAnalysis(ExposureAnalysis(meanStops: 2, validWeight: 1), for: frame, source: before.source)
        #expect(films.cachedMeasurement(frame) == before)

        try Self.darken(frame.url)
        #expect(films.cachedMeasurement(frame) == nil && !films.hasLinearPreview(frame, lens: .default))
        #expect(films.cachedFilm(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336) == nil)
        let after = try #require(await films.measurement(frame))
        #expect(films.decodeCount == 2 && after.source == SourceStamp.of(frame.url) && after.source != before.source)
        #expect(after.analysis.meanStops < before.analysis.meanStops - 0.5)
        let redone = try #require(await films.film(frame, stock: 0, settings: DevelopSettings(), maxPixelSize: 336))
        #expect(redone !== film && redone.dataProvider?.data as Data? != film.dataProvider?.data as Data?)
    }
}
