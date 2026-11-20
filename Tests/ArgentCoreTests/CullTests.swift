import Foundation
import Testing
@testable import ArgentCore

@Suite struct CullTests {
    static func shoot() throws -> [CullInput] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/titos-scores.json")
        return try CullScoreFile.read(Data(contentsOf: url))
    }

    func fates(_ frames: [CullInput], _ settings: CullSettings = CullSettings()) -> [String: CullVerdict] {
        Dictionary(uniqueKeysWithValues: Cull.verdicts(frames, settings: settings).map { ($0.path, $0) })
    }

    static let walkingRun = (4809...4822).map { "DSC0\($0).ARW" }

    static let strictNormalAndLooseSoftFocus = [(0.30, 0.34), (0.26, 0.30), (0.20, 0.24)]
    static let narrowNormalAndWideSameMoment = [0.15, 0.25, 0.35]
    static let importChoices = strictNormalAndLooseSoftFocus.flatMap { soft, eyes in
        narrowNormalAndWideSameMoment.map { CullSettings(softFocusBelow: soft, eyesClosedBelow: eyes, sameMomentWithin: $0) }
    }

    static func frame(_ path: String, at seconds: TimeInterval, face: Double? = 0.5, print: [Float] = [0, 0]) -> CullInput {
        CullInput(path: path, captureDate: Date(timeIntervalSince1970: seconds),
                  scores: PreviewScores(faceQuality: face, aesthetics: 0.5, featurePrint: print))
    }

    @Test func theFixtureHoldsTheWholeShoot() throws {
        let frames = try Self.shoot()
        #expect(frames.count == 644)
        #expect(frames.filter { $0.scores?.faceQuality == nil }.count == 17)
        #expect(frames.allSatisfy { $0.captureDate != nil && $0.scores?.featurePrint.count == 768 })
    }

    @Test func theFourteenSoftestFacesStayOnTheCard() throws {
        let frames = try Self.shoot(), fates = fates(frames)
        let softest = frames.compactMap { frame in frame.scores?.faceQuality.map { (frame.path, $0) } }.sorted { $0.1 < $1.1 }.prefix(14)
        #expect(softest.count == 14)
        for (path, _) in softest {
            #expect([.softFocus, .failed].contains(fates[path]?.reason), "\(path)")
        }
    }

    @Test(arguments: importChoices) func theSharpF14PortraitIsNeverSoftOrFailed(_ settings: CullSettings) throws {
        let reason = fates(try Self.shoot(), settings)["DSC04181.ARW"]?.reason
        #expect(reason != .softFocus && reason != .failed)
    }

    @Test func theLeavesMissesFailAndClosedEyesStayOnTheCard() throws {
        let fates = fates(try Self.shoot())
        for path in ["DSC04404.ARW", "DSC04405.ARW", "DSC04412.ARW", "DSC04413.ARW"] {
            #expect(fates[path]?.reason == .failed, "\(path)")
        }
        #expect(fates["DSC04533.ARW"]?.reason == .eyesClosed)
        #expect(fates["DSC04619.ARW"]?.reason == .eyesClosed)
    }

    @Test func aBurstDuplicateIsTheSameMomentAsItsKeeper() throws {
        let fates = fates(try Self.shoot())
        #expect(fates["DSC04432.ARW"]?.reason == .sameMoment(keeper: "DSC04433.ARW")
            || fates["DSC04433.ARW"]?.reason == .sameMoment(keeper: "DSC04432.ARW"))
    }

    @Test func theWalkingRunKeepsMoreThanOneFrame() throws {
        let fates = fates(try Self.shoot())
        #expect(Self.walkingRun.filter { fates[$0]?.keep == true }.count > 1)
    }

    @Test func aLongerBurstGapStillKeepsDifferentMoments() throws {
        let frames = try Self.shoot()
        let short = fates(frames), long = fates(frames, CullSettings(burstGap: 1))
        #expect(Set(Self.walkingRun.compactMap { long[$0]?.burst }).count == 1)
        #expect(Self.walkingRun.filter { long[$0]?.keep == true }.count >= Self.walkingRun.filter { short[$0]?.keep == true }.count)
        #expect(long.values.filter(\.keep).count > Set(long.values.map(\.burst)).count)
    }

    @Test func aFrameWithNoScoresIsKept() throws {
        var frames = try Self.shoot()
        let failed = try #require(frames.firstIndex { $0.path == "DSC04404.ARW" })
        let keeper = try #require(frames.firstIndex { $0.path == "DSC04433.ARW" })
        frames[failed].scores = nil
        frames[keeper].scores = nil
        let fates = fates(frames)
        #expect(fates["DSC04404.ARW"]?.reason == nil)
        #expect(fates["DSC04433.ARW"]?.reason == nil)
        #expect(fates["DSC04432.ARW"]?.reason != .sameMoment(keeper: "DSC04433.ARW"))
    }

    @Test(arguments: importChoices + [CullSettings(burstGap: 1), CullSettings(sameMomentWithin: 0.4), CullSettings(leavesEyesClosed: false)])
    func everySameMomentNamesACopiedKeeperInItsBurst(_ settings: CullSettings) throws {
        let frames = try Self.shoot(), fates = fates(frames, settings)
        let prints = Dictionary(uniqueKeysWithValues: frames.map { ($0.path, $0.scores?.featurePrint ?? []) })
        for verdict in fates.values {
            guard case let .sameMoment(keeper) = verdict.reason else { continue }
            #expect(fates[keeper]?.keep == true && fates[keeper]?.burst == verdict.burst, "\(verdict.path)")
            #expect(Double(Cull.distance(prints[verdict.path]!, prints[keeper]!)) <= settings.sameMomentWithin, "\(verdict.path)")
        }
    }

    @Test func keepingClosedEyesStillLeavesADuplicateOfASharperFrame() throws {
        let fates = fates(try Self.shoot(), CullSettings(leavesEyesClosed: false))
        #expect(fates["DSC04619.ARW"]?.keep == true)
        #expect(fates["DSC04533.ARW"]?.reason == .sameMoment(keeper: "DSC04531.ARW"))
    }

    @Test func looseSoftFocusCopiesASoftFrameAndLeavesItsDuplicate() throws {
        let fates = fates(try Self.shoot(), CullSettings(softFocusBelow: 0.20, eyesClosedBelow: 0.24))
        #expect(fates["DSC04780.ARW"]?.keep == true)
        #expect(fates["DSC04781.ARW"]?.reason == .sameMoment(keeper: "DSC04780.ARW"))
    }

    @Test func verdictsComeInCaptureOrderWhateverTheInputOrder() throws {
        let frames = try Self.shoot()
        let verdicts = Cull.verdicts(frames)
        #expect(Cull.verdicts(frames.reversed()) == verdicts)
        let dates = Dictionary(uniqueKeysWithValues: frames.map { ($0.path, $0.captureDate!) })
        #expect(verdicts.map { dates[$0.path]! } == verdicts.map { dates[$0.path]! }.sorted())
    }

    @Test func aGapOfExactlyTheBurstGapIsOneBurstHoweverTheDateWasBuilt() throws {
        let header = try ["202", "552"].map { try #require(ARWFrameInfo.captureDate("2026:10:24 13:59:06", subseconds: $0)) }
        let stored = [1792850346.202, 1792850346.552].map(Date.init(timeIntervalSince1970:))
        for dates in [header, stored] {
            let frames = dates.enumerated().map { CullInput(path: "DSC0000\($0.offset).ARW", captureDate: $0.element, scores: nil) }
            #expect(Cull.verdicts(frames).map(\.burst) == [0, 0])
        }
    }

    @Test func aFrameWithNoDateIsItsOwnBurstAfterTheDatedOnes() {
        let undated = CullInput(path: "DSC00001.ARW", captureDate: nil, scores: nil)
        let verdicts = Cull.verdicts([undated, Self.frame("DSC00002.ARW", at: 0), Self.frame("DSC00003.ARW", at: 0.1)])
        #expect(verdicts.map(\.path) == ["DSC00002.ARW", "DSC00003.ARW", "DSC00001.ARW"])
        #expect(verdicts.map(\.burst) == [0, 0, 1])
    }

    @Test func aRepeatedFileNameInAnotherFolderIsAnotherFrame() {
        let verdicts = Cull.verdicts([Self.frame("101MSDCF/DSC00001.ARW", at: 0, face: 0.4), Self.frame("100MSDCF/DSC00001.ARW", at: 0.1)])
        #expect(verdicts == [CullVerdict(path: "101MSDCF/DSC00001.ARW", reason: .sameMoment(keeper: "100MSDCF/DSC00001.ARW"), burst: 0),
                             CullVerdict(path: "100MSDCF/DSC00001.ARW", reason: nil, burst: 0)])
    }

    @Test func aFrameLeftForItsOwnScoresIsNeverTheKeeper() {
        var failed = Self.frame("DSC00001.ARW", at: 0, face: 0.6)
        failed.scores?.aesthetics = -0.1
        #expect(Cull.verdicts([failed, Self.frame("DSC00002.ARW", at: 0.1)]).map(\.reason) == [.failed, nil])
    }

    @Test func emptyPrintsAreNeverTheSameMoment() {
        let verdicts = Cull.verdicts([Self.frame("DSC00001.ARW", at: 0, print: []), Self.frame("DSC00002.ARW", at: 0.1, print: [])])
        #expect(verdicts.allSatisfy { $0.keep })
    }

    @Test func theDistanceIsVisions() throws {
        let prints = Dictionary(uniqueKeysWithValues: try Self.shoot().map { ($0.path, $0.scores!.featurePrint) })
        for (a, b, vision) in [("DSC04432.ARW", "DSC04433.ARW", 0.07264512032270432), ("DSC04812.ARW", "DSC04813.ARW", 0.24454031884670258),
                               ("DSC04145.ARW", "DSC04146.ARW", 0.19903215765953064)] {
            #expect(abs(Double(Cull.distance(prints[a]!, prints[b]!)) - vision) < 1e-6, "\(a) \(b)")
        }
    }

    @Test(arguments: ["", " \n", "[]", "[\n]\n"]) func anEmptyFileHasNoFrames(_ text: String) throws {
        #expect(try CullScoreFile.read(Data(text.utf8)).isEmpty)
    }

    static let twoValues = "AAAAPA=="
    static let malformed: [(String, Int)] = [
        ("[\n{\"path\":\"a.ARW\",\"captureDate\":1,\"scores\":null},\n{\"path\":\"b.ARW\" \"captureDate\":2}\n]\n", 3),
        ("[\n{\"path\":\"a.ARW\",\"captureDate\":1,\"scores\":null},\n{\"path\":\"b.ARW\",\"scores\":{\"aesthetics\":\"x\",\"featurePrint\":\"\(twoValues)\"}}\n]\n", 3),
        ("[\n{\"path\":\"a.ARW\"},\n{\"path\":\"b.ARW\"},\n{\"captureDate\":3}\n]\n", 4),
        ("[\n{\"path\":\"a.ARW\"},\n{\"path\":\"b.ARW\",\"scores\":{\"aesthetics\":0.5,\"featurePrint\":\"not base64\"}}\n]\n", 3),
        ("[\n{\"path\":\"a.ARW\"},\n{\"path\":\"b.ARW\"},\n{\"path\":\"a.ARW\"}\n]\n", 4),
        ("[\n{\"path\":\"a.ARW\"},\n{\"path\":\"b.ARW\",\"scores\":{\"aesthetics\":0.5,\"featurePrint\":\"AH4Afg==\"}}\n]\n", 3),
        ("[\n{\"path\":\"a.ARW\"},\n{\"path\":\"b.ARW\",\n", 3),
        ("{\"path\":\"a.ARW\"}\n", 1),
    ]

    @Test(arguments: malformed) func aMalformedFileNamesTheLine(_ text: String, _ line: Int) {
        let error = #expect(throws: CullScoreFile.ReadError.self) { try CullScoreFile.read(Data(text.utf8)) }
        #expect(error?.line == line, "\(error?.localizedDescription ?? "")")
    }
}
