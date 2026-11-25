import Foundation
import Testing
@testable import ArgentCore

/// The base of docs/remove-plan.md: the record and its guards (section 4.1), the patch and its file (4.2), the engine's contract
/// and the fake every suite runs on (4.5), and what the packages have still to build.
@Suite struct RemovalContractTests {
    private static func ref(_ byte: String = "ab", width: Int = 512, height: Int = 512) throws -> PatchRef {
        try PatchRef(id: PatchID(hex: String(repeating: byte, count: 32))!, width: width, height: height)
    }

    private static func removal(_ byte: String = "ab", isOn: Bool = true, includesEffects: Bool = true) throws -> Removal {
        Removal(patch: try ref(byte), isOn: isOn, includesEffects: includesEffects)
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: the record

    @Test func aRemovalWritesItsSwitchesOnlyWhenTheyAreNotTheDefault() throws {
        let plain = try Self.removal()
        let text = try Self.json(plain)
        #expect(!text.contains("off") && !text.contains("objectOnly"))
        #expect(try JSONDecoder().decode(Removal.self, from: Data(text.utf8)) == plain)

        let hidden = plain.setting(isOn: false).setting(includesEffects: false)
        let hiddenText = try Self.json(hidden)
        #expect(hiddenText.contains("\"off\":true") && hiddenText.contains("\"objectOnly\":true"))
        let read = try JSONDecoder().decode(Removal.self, from: Data(hiddenText.utf8))
        #expect(read == hidden && !read.isOn && !read.includesEffects && read.id == plain.id)
    }

    @Test func tryAgainKeepsARemovalsPlaceAndSwitches() throws {
        let first = try Self.removal().setting(isOn: false)
        let again = first.replacingPatch(try Self.ref("cd"))
        #expect(again.id == first.id && !again.isOn && again.patch.id.hex.hasPrefix("cd"))
    }

    @Test func aListIsRefusedWithTwoOfOneIdOrMoreThanAFrameHolds() throws {
        let one = try Self.removal()
        #expect(throws: RemovalError.self) { try [one, one].validated() }
        let many = try (0...Removal.limit).map { _ in try Self.removal() }
        #expect(throws: RemovalError.self) { try many.validated() }
        #expect(try Array(many.dropLast()).validated().count == Removal.limit)
    }

    @Test func aPatchIdIsSixtyFourLowercaseHexDigits() {
        #expect(PatchID(hex: String(repeating: "A", count: 64)) == nil)
        #expect(PatchID(hex: String(repeating: "a", count: 63)) == nil)
        #expect(PatchID(hex: String(repeating: "0f", count: 32)) != nil)
        #expect(throws: RemovalError.self) { try PatchRef(id: PatchID(hex: String(repeating: "a", count: 64))!, width: 8, height: 512) }
    }

    @Test func theRenderDigestFollowsWhatIsCompositedAndNothingElse() throws {
        let a = try Self.removal("aa"), b = try Self.removal("bb")
        #expect([Removal]().renderDigest == nil)
        #expect([a.setting(isOn: false)].renderDigest == nil, "a removal that is off is a frame with none")
        let both = try #require([a, b].renderDigest)
        #expect(both.count == 64)
        #expect([b, a].renderDigest != both, "order")
        #expect([a, b.setting(includesEffects: false)].renderDigest != both, "which alpha")
        #expect([a, b.setting(isOn: false)].renderDigest == [a].renderDigest, "one off is as if it were not there")
        // The id is the removal's place in the list, not its pixels: another id over the same patch renders the same.
        #expect([Removal(patch: a.patch)].renderDigest == [a].renderDigest)
        #expect([a, b, a.replacingPatch(b.patch)].patches.count == 2, "each patch once")
    }

    // MARK: in the lens settings

    @Test func lensSettingsWithNothingRemovedAreWrittenAsBefore() throws {
        #expect(try Self.json(LensSettings.default) == "{}")
        let vignette = try LensSettings.default.setting(.vignette, to: 20)
        #expect(!(try Self.json(vignette)).contains("removals"))
        #expect(try JSONDecoder().decode(LensSettings.self, from: Data("{}".utf8)) == .default)
    }

    @Test func removalsRoundTripInTheLensSettingsAndBadListsAreRefused() throws {
        let removals = [try Self.removal("aa"), try Self.removal("bb", isOn: false)]
        let lens = try LensSettings.default.settingRemovals(removals)
        let text = try Self.json(lens)
        #expect(text.contains("removals"))
        #expect(try JSONDecoder().decode(LensSettings.self, from: Data(text.utf8)) == lens)
        #expect(throws: RemovalError.self) { try LensSettings.default.settingRemovals([removals[0], removals[0]]) }
        let twice = text.replacingOccurrences(of: removals[1].id.uuidString, with: removals[0].id.uuidString)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LensSettings.self, from: Data(twice.utf8)) }
    }

    @Test func everyLensSetterKeepsTheRemovals() throws {
        let removals = [try Self.removal()]
        let lens = try LensSettings.default.settingRemovals(removals)
        for control in LensSettings.Control.allCases {
            let value = control.range.lowerBound + (control.range.upperBound - control.range.lowerBound) / 4
            #expect(try lens.setting(control, to: value).removals == removals, "\(control)")
        }
        #expect(lens.settingDistortion(isOn: false).removals == removals)
        #expect(lens.settingDefringe(try .init(purpleAmount: 4, purpleHue: 20...80, greenAmount: 0, greenHue: 40...60)).removals == removals)
        #expect(lens.ignoringInactiveHue.removals == removals)
        #expect(try LensSettings(arguments: "vignette=10").removals.isEmpty)
        #expect(lens.arguments == "default", "the words are the lens values'")
    }

    @Test func aRemovalMakesTheSettingsNotDefaultButLeavesTheirValuesDefault() throws {
        let lens = try LensSettings.default.settingRemovals([try Self.removal()])
        #expect(!lens.isDefault && lens.hasDefaultValues)
        #expect(LensSettings.default.isDefault && LensSettings.default.hasDefaultValues)
        let moved = try lens.setting(.distortion, to: 50)
        #expect(!moved.isDefault && !moved.hasDefaultValues)
    }

    // MARK: the guards in the adjustments

    @Test func settingTheLensKeepsTheFramesOwnRemovals() throws {
        let mine = [try Self.removal("aa")], theirs = [try Self.removal("bb")]
        let frame = try ManualAdjustments(exposureEV: 0.5).settingRemovals(mine)
        let other = try LensSettings.default.setting(.vignette, to: 30).settingRemovals(theirs)

        let set = frame.settingLens(other)
        #expect(set.removals == mine && set.lens.vignetting.amount == 30)
        #expect(frame.settingLens(.default).removals == mine)

        // A paste of the Lens part, Reset Lens and the print-only lane's sliders all come through `setting(_:from:)`.
        let source = try ManualAdjustments().settingLens(other).settingRemovals(theirs)
        let pasted = frame.setting(.lens, from: source)
        #expect(pasted.removals == mine && pasted.lens.vignetting.amount == 30)
        #expect(frame.setting(.sliders, from: source).removals == mine)
        #expect(frame.settingLens(other).clearing(.lens).removals == mine)
        #expect(frame.settingLens(other).clearing(.lens).lens.hasDefaultValues)
        // And a frame with none takes none.
        #expect(try ManualAdjustments().setting(.lens, from: source).removals.isEmpty)
    }

    @Test func aRemovalIsAnEditThatHoldsNoLensPart() throws {
        let removed = try ManualAdjustments().settingRemovals([try Self.removal()])
        #expect(!removed.isIdentity)
        #expect(!removed.heldParts.contains(.lens), "Copy offers no Lens part and the Lens tab shows no mark")
        #expect(removed.withoutRemovals.isIdentity)
        #expect(try removed.settingLens(LensSettings.default.setting(.distortion, to: 50)).heldParts.contains(.lens))
    }

    @Test func adjustmentsWriteTheirLensForARemovalAloneAndAreUnchangedWithout() throws {
        #expect(!(try Self.json(ManualAdjustments.identity)).contains("lens"))
        let removed = try ManualAdjustments().settingRemovals([try Self.removal()])
        let text = try Self.json(removed)
        #expect(text.contains("\"lens\":{\"removals\":["))
        #expect(try JSONDecoder().decode(ManualAdjustments.self, from: Data(text.utf8)) == removed)
    }

    // MARK: the patch

    private static func patch(width: Int = 32, height: Int = 16, seed: UInt64 = 1, notes: RemovalPatch.Notes = .none,
                              box: RemovalPatch.Box? = nil) throws -> RemovalPatch {
        var state = seed
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        let rgb = (0..<(width * height * 3)).map { _ in Float16(Float(next() % 4096) / 1024) }
        let object = (0..<(width * height)).map { _ in UInt8(next() % 256) }
        let effects = object.map { max($0, UInt8(next() % 256)) }
        return try RemovalPatch(box: try box ?? .init(x: 100, y: 200, width: 640, height: 320), width: width, height: height, rgb: rgb,
                                objectAlpha: object, effectsAlpha: effects, notes: notes)
    }

    @Test func aPatchRoundTripsThroughItsFile() throws {
        let notes = RemovalPatch.Notes(engine: "fake", weights: FakeRemovalEngine.weightsID, steps: 8, guidance: 1, seed: 42, decoder: "argent-5",
                                       frameWidth: 7008, frameHeight: 4672, face: [0.1, 0.2, 0.05, 0.08],
                                       made: Date(timeIntervalSince1970: 1_800_000_000))
        let patch = try Self.patch(notes: notes)
        let file = try patch.encoded()
        #expect(file.prefix(RemovalPatch.magic.count) == RemovalPatch.magic)
        let read = try RemovalPatch(decoding: file)
        #expect(read == patch && read.identity == patch.identity && read.notes == notes)
        #expect(read.ref == patch.ref && read.ref.width == 32 && read.ref.height == 16)
        // A file read from the middle of a pack has indices that do not start at zero.
        let inside = (Data([1, 2, 3]) + file).dropFirst(3)
        #expect(try RemovalPatch(decoding: inside) == patch)
    }

    @Test func aPatchIsNamedByItsBoxAndPixelsAndNotByItsNotes() throws {
        let patch = try Self.patch()
        var noted = patch
        noted.notes.face = [0, 0, 0.1, 0.1]
        #expect(noted.identity == patch.identity)
        #expect(try RemovalPatch(decoding: noted.encoded()).identity == patch.identity)
        #expect(try Self.patch(seed: 2).identity != patch.identity)
        #expect(try Self.patch(box: .init(x: 101, y: 200, width: 640, height: 320)).identity != patch.identity)
        #expect(patch.identity.hex.count == 64)
    }

    @Test func aDamagedPatchFileIsRefused() throws {
        let file = try Self.patch().encoded()
        #expect(throws: RemovalError.self) { try RemovalPatch(decoding: Data("not a patch".utf8)) }
        #expect(throws: RemovalError.self) { try RemovalPatch(decoding: file.dropLast(1)) }
        #expect(throws: RemovalError.self) { try RemovalPatch(decoding: file + Data([0])) }
        #expect(throws: RemovalError.self) { try RemovalPatch(decoding: file.prefix(RemovalPatch.magic.count + 2)) }
        var header = file
        header[RemovalPatch.magic.count + 3] = 0x7f   // a header length past the file
        #expect(throws: RemovalError.self) { try RemovalPatch(decoding: header) }
        var plane = file
        plane[plane.count - 3] ^= 0xff
        let read = try? RemovalPatch(decoding: plane), original = try Self.patch().identity
        #expect(read == nil || read?.identity != original, "a changed plane is refused or is another patch")
    }

    /// The file `patch` encodes to, with its header's JSON changed by `edit`.
    private static func file(of patch: RemovalPatch, editing edit: (inout [String: Any]) -> Void) throws -> Data {
        let file = try patch.encoded()
        let start = RemovalPatch.magic.count + 4
        let length = file[RemovalPatch.magic.count..<start].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var header = try #require(try JSONSerialization.jsonObject(with: file[start..<start + length]) as? [String: Any])
        edit(&header)
        let edited = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var out = RemovalPatch.magic
        withUnsafeBytes(of: UInt32(edited.count).littleEndian) { out.append(contentsOf: $0) }
        return out + edited + file[(start + length)...]
    }

    @Test func aPatchFileWithHugeLengthsOrBoxIsRefusedNotTrapped() throws {
        let patch = try Self.patch()
        for key in ["rgb", "object", "effects"] {
            let file = try Self.file(of: patch) { $0[key] = Int.max }
            #expect(throws: RemovalError.self, "\(key)") { try RemovalPatch(decoding: file) }
        }
        let both = try Self.file(of: patch) { $0["rgb"] = Int.max; $0["object"] = Int.max }
        #expect(throws: RemovalError.self) { try RemovalPatch(decoding: both) }
        for (key, side) in [("x", "width"), ("y", "height")] {
            let file = try Self.file(of: patch) {
                var box = $0["box"] as! [String: Any]
                box[key] = Int.max - 807; box[side] = 1000
                $0["box"] = box
            }
            #expect(throws: RemovalError.self, "\(key)") { try RemovalPatch(decoding: file) }
        }
        #expect(throws: RemovalError.self) { try RemovalPatch.Box(x: Int.max - 807, y: 0, width: 1000, height: 64) }
        #expect(throws: RemovalError.self) { try RemovalPatch.Box(x: 0, y: Int.max, width: 64, height: Int.max) }
        #expect(throws: RemovalError.self) { try RemovalPatch.Box(x: 0, y: 0, width: Int.max, height: 64) }
        #expect(try RemovalPatch.Box(x: RemovalPatch.Box.limit - 64, y: 0, width: 64, height: 64).x == RemovalPatch.Box.limit - 64)
        // The file rebuilt without a change still reads, so the refusals above are the large values'.
        #expect(try RemovalPatch(decoding: Self.file(of: patch) { _ in }) == patch)
    }

    @Test func aPatchChecksItsSizesAndItsPixels() throws {
        let box = try RemovalPatch.Box(x: 0, y: 0, width: 64, height: 64)
        let rgb = [Float16](repeating: 0.5, count: 16 * 16 * 3), alpha = [UInt8](repeating: 255, count: 16 * 16)
        #expect(throws: RemovalError.self) { try RemovalPatch(box: box, width: 16, height: 16, rgb: Array(rgb.dropLast()), objectAlpha: alpha, effectsAlpha: alpha) }
        #expect(throws: RemovalError.self) { try RemovalPatch(box: box, width: 8, height: 16, rgb: rgb, objectAlpha: alpha, effectsAlpha: alpha) }
        var infinite = rgb
        infinite[7] = .infinity
        #expect(throws: RemovalError.self) { try RemovalPatch(box: box, width: 16, height: 16, rgb: infinite, objectAlpha: alpha, effectsAlpha: alpha) }
        #expect(throws: RemovalError.self) { try RemovalPatch.Box(x: -1, y: 0, width: 4, height: 4) }
        #expect(throws: RemovalError.self) { try RemovalPatch.Box(x: 0, y: 0, width: 0, height: 4) }
        let patch = try RemovalPatch(box: box, width: 16, height: 16, rgb: rgb, objectAlpha: alpha, effectsAlpha: alpha)
        #expect(patch.isSoftAtFullSize, "64 over 16 is more than twice")
        #expect(!(try RemovalPatch(box: .init(x: 0, y: 0, width: 32, height: 32), width: 16, height: 16, rgb: rgb,
                                   objectAlpha: alpha, effectsAlpha: alpha)).isSoftAtFullSize)
    }

    @Test func aFixedSourceGivesAPatchByItsNameAndSize() throws {
        let patch = try Self.patch()
        let source = FixedPatchSource([patch])
        #expect(source.patch(patch.ref) == patch)
        #expect(source.patch(try Self.ref()) == nil)
        #expect(source.patch(try PatchRef(id: patch.identity, width: 64, height: 16)) == nil, "another size is another patch")
    }

    // MARK: the working size

    @Test func theWorkingSizeIsTheCropsOwnWhereItFitsAndTheLargestThatFitsWhereItDoesNot() {
        func size(_ width: Int, _ height: Int) -> [Int] {
            let made = RemovalPipeline.workingSize(width: width, height: height)
            return [made.width, made.height]
        }
        #expect(size(512, 640) == [512, 640] && size(1024, 1344) == [1024, 1344], "the picture's own scale")
        #expect(size(1344, 1344) == [1344, 1344] && size(1008, 1078) == [1008, 1072], "any crop within the limit, to sixteens")
        #expect(size(2000, 2000) == [1344, 1344] && size(1112, 2524) == [592, 1344], "past the limit: reduced until the long side is it")
        #expect(size(300, 300) == [512, 512] && size(200, 150) == [688, 512], "a crop the frame leaves small is enlarged to the model's size")
        #expect(size(400, 4000) == [128, 1344], "and one too long to enlarge keeps the limit")
        func prototype(_ width: Int, _ height: Int) -> [Int] {
            let made = RemovalPipeline.prototypeWorkingSize(width: width, height: height)
            return [made.width, made.height]
        }
        #expect(prototype(1590, 4096) == [512, 1328], "the first measured run's crop, as it was run")
        #expect(prototype(300, 469) == [512, 800], "the prototype cuts the scaled side to a whole number before it rounds up")
        for (w, h) in [(777, 1234), (5000, 640), (64, 9000), (2048, 2049)] {
            let made = size(w, h)
            #expect(made.allSatisfy { $0.isMultiple(of: 16) && $0 >= RemovalPatch.leastWorkingSide } && made.max()! <= RemovalPatch.longSideLimit,
                    "\(w) x \(h)")
        }
    }

    // MARK: the engine

    private static func job(steps: Int = 4) throws -> RemovalJob {
        let side = 32
        var image = [UInt8](repeating: 0, count: side * side * 3), mask = [UInt8](repeating: 0, count: side * side)
        for p in 0..<(side * side) { image[p * 3] = 100; image[p * 3 + 1] = 150; image[p * 3 + 2] = 200 }
        for y in 12..<20 { for x in 12..<20 {
            mask[y * side + x] = 255
            for c in 0..<3 { image[(y * side + x) * 3 + c] = 255 }
        } }
        return try RemovalJob(width: side, height: side, image: image, mask: mask, steps: steps, seed: 7)
    }

    @Test func aJobChecksItsSizesAndItsSettings() throws {
        let job = try Self.job()
        #expect(job.steps == 4 && job.guidance == RemovalJob.defaultGuidance)
        #expect(throws: RemovalError.self) { try RemovalJob(width: 30, height: 32, image: job.image, mask: job.mask, seed: 1) }
        #expect(throws: RemovalError.self) { try RemovalJob(width: 32, height: 32, image: job.image, mask: Array(job.mask.dropLast()), seed: 1) }
        #expect(throws: RemovalError.self) { try RemovalJob(width: 32, height: 32, image: job.image, mask: job.mask, steps: 0, seed: 1) }
        #expect(throws: RemovalError.self) { try RemovalJob(width: 32, height: 32, image: job.image, mask: job.mask, guidance: 0.5, seed: 1) }
    }

    @Test func theFakeEngineLoadsRunsAndDrawsTheObjectOut() async throws {
        let engine = FakeRemovalEngine(effectReach: 2)
        #expect(engine.state == .idle)
        let steps = StepLog()
        let output = try await engine.run(try Self.job()) { done, of in steps.add(done, of) }
        #expect(engine.state == .ready && engine.counts == .init(loads: 1, unloads: 0, runs: 1, cancelled: 0))
        #expect(steps.all == [[1, 4], [2, 4], [3, 4], [4, 4]])
        #expect(output.engine == FakeRemovalEngine.engineID && output.width == 32 && output.height == 32)
        let inside = (15 * 32 + 15) * 3, outside = (2 * 32 + 2) * 3
        #expect(Array(output.image[inside..<inside + 3]) == [100, 150, 200], "the object is painted with what lies outside it")
        #expect(Array(output.image[outside..<outside + 3]) == [100, 150, 200])
        // The attention is the mask grown by two, which stands for a shadow.
        #expect(output.attention[10 * 32 + 10] == 255 && output.attention[21 * 32 + 21] == 255)
        #expect(output.attention[9 * 32 + 10] == 0 && output.attention[22 * 32 + 21] == 0)
        await engine.unload()
        #expect(engine.state == .idle && engine.counts.unloads == 1)
    }

    @Test func theFakeEngineStopsBetweenStepsFailsOnRequestAndSaysWhenItIsAbsent() async throws {
        // The run cancels itself from its second step, so nothing here waits on a clock.
        let stopped = FakeRemovalEngine()
        let seen = StepLog()
        let run = Task {
            try await stopped.run(try Self.job(steps: 50)) { done, of in
                seen.add(done, of)
                if done == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(seen.all == [[1, 50], [2, 50]], "it stops before the next step")
        #expect(stopped.counts.cancelled == 1 && stopped.state == .ready, "stopped, and still loaded")

        let failing = FakeRemovalEngine()
        failing.failNext(.unresponsive)
        await #expect(throws: RemovalRunFailure.unresponsive) { try await failing.run(try Self.job()) { _, _ in } }
        _ = try await failing.run(try Self.job()) { _, _ in }
        #expect(failing.counts.runs == 2, "the next run draws")

        let absent = FakeRemovalEngine(state: .absent("no model here"))
        absent.load()
        #expect(absent.state == .absent("no model here") && absent.counts.loads == 0)
        await #expect(throws: RemovalRunFailure.failed("no model here")) { try await absent.run(try Self.job()) { _, _ in } }
    }

    // MARK: the folder

    @Test func theFoldersFilesHaveTheNamesAndFieldsBothServersWrite() throws {
        // The helper writes these and the app's client reads them, each by hand, so the words are pinned here.
        let engine = RemovalFolder.Engine(state: .preparing, preparing: 0.4, engine: "objectclear-pytorch-mps", weights: "w", pid: 7, beat: 12.5)
        #expect(try Self.json(engine) == #"{"beat":12.5,"engine":"objectclear-pytorch-mps","pid":7,"preparing":0.4,"state":"preparing","weights":"w"}"#)
        #expect(engine.engineState == .preparing(0.4))
        let idle = try JSONDecoder().decode(RemovalFolder.Engine.self,
                                            from: Data(#"{"state":"idle","engine":"e","weights":"w","pid":1,"beat":3}"#.utf8))
        #expect(idle.engineState == .idle && idle.preparing == nil)
        #expect(try Self.json(RemovalFolder.Job(try Self.job())) == #"{"guidance":1,"height":32,"seed":7,"steps":4,"width":32}"#)
        #expect(try Self.json(RemovalFolder.Status(state: .running, step: 3, steps: 8)) == #"{"state":"running","step":3,"steps":8}"#)
        #expect(try Self.json(RemovalFolder.Status(state: .failed, error: "no memory")) == #"{"error":"no memory","state":"failed"}"#)
        #expect(RemovalFolder.Want.loaded.rawValue == "loaded" && RemovalFolder.Want.unloaded.rawValue == "unloaded")
        #expect([RemovalFolder.engineFile, RemovalFolder.wantFile, RemovalFolder.jobsFolder, RemovalFolder.jobFile, RemovalFolder.imageFile,
                 RemovalFolder.maskFile, RemovalFolder.statusFile, RemovalFolder.outputFile, RemovalFolder.attentionFile, RemovalFolder.cancelFile,
                 RemovalFolder.prepareFile]
            == ["engine.json", "want", "jobs", "job.json", "image.png", "mask.png", "status.json", "out.png", "attn.png", "cancel", "prepare.json"])
        #expect(try Self.json(RemovalFolder.Prepare(width: 512, height: 1328)) == #"{"height":1328,"width":512}"#)
    }

    // MARK: the selection

    @Test func aSelectionHoldsSomethingWhereverInThePictureItIs() throws {
        #expect(throws: RemovalError.self) { try RemovalPipeline.Selection(width: 4, height: 4, coverage: [UInt8](repeating: 0, count: 16)) }
        #expect(throws: RemovalError.self) { try RemovalPipeline.Selection(width: 5, height: 5, coverage: [UInt8](repeating: 127, count: 25)) }
        // Found in a whole word, and in the bytes left over after the last one.
        for place in [0, 9, 23, 24] {
            var coverage = [UInt8](repeating: 0, count: 25)
            coverage[place] = 128
            #expect(try RemovalPipeline.Selection(width: 5, height: 5, coverage: coverage).coverage[place] == 128, "\(place)")
        }
    }
}

/// The steps an engine reported, from whatever thread it reported them on.
private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [[Int]] = []
    func add(_ done: Int, _ of: Int) { lock.withLock { steps.append([done, of]) } }
    var all: [[Int]] { lock.withLock { steps } }
}

extension RemovalPipeline {
    /// The prototype's working size for a crop: 512 on the short side, each side a multiple of sixteen by its own arithmetic (P:
    /// the scaled side in single precision, cut to a whole number, then rounded up), the long side `RemovalPatch.longSideLimit`
    /// at most. Both measured runs were made at it; the app's rule is `workingSize`.
    static func prototypeWorkingSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let multiple = RemovalPatch.sideMultiple
        let short = Float(RemovalPatch.shortSide) / Float(min(width, height))
        func up(_ pixels: Int) -> Int { max(multiple, (Int(Float(pixels) * short) + multiple - 1) / multiple * multiple) }
        let made = (up(width), up(height))
        guard max(made.0, made.1) > RemovalPatch.longSideLimit else { return made }
        let long = Double(RemovalPatch.longSideLimit) / Double(max(width, height))
        func down(_ pixels: Int) -> Int { max(multiple, Int((Double(pixels) * long / Double(multiple)).rounded(.down)) * multiple) }
        return (down(width), down(height))
    }
}
