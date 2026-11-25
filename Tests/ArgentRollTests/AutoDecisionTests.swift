import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// Settled decisions (`AutoDecisions`; docs/research/auto/sequence-consistency.md, "Stage 4 either
/// way"): the same snapshot gives the same revision and aims bit for bit; the revision reads what the
/// method reads and nothing else; a kept decision holds only for the same raws; the store keeps one a
/// roll and leaves what it cannot read.
@Suite struct AutoDecisionTests {
    private static let stock = Stock(id: "decision-test", displayName: "Decision test", status: "synthetic", boxSpeed: 400,
                                     densityRange: 2.5, exposurePerUnit: SIMD3(0.8, 0.8, 0.8),
                                     negative: LUT3D.identity(size: 2), print: LUT3D.identity(size: 2))
    private static let start = Date(timeIntervalSince1970: 1_792_000_000)

    /// Six frames, the first four ten seconds apart and the last two after ten minutes.
    private static var frames: [Frame] {
        (0..<6).map { index in
            Frame(id: index, url: URL(fileURLWithPath: "/decisions/DSC0\(index).ARW"),
                  info: ARWFrameInfo(captureDate: start.addingTimeInterval(index < 4 ? 10 * Double(index) : 600 + 10 * Double(index)),
                                     exposureTime: 1 / 250, fNumber: 2.8, iso: 400, flashFired: false))
        }
    }

    private static func analysis(_ index: Int, shift: Float = 0) -> ExposureAnalysis {
        ExposureAnalysis(meanStops: [-1, 0.3, 0.6, -0.2, 1.1, 0.4][index] + shift, validWeight: 1,
                         grayEstimate: [0.05 * Float(index), 0, -0.02 * Float(index)])
    }

    private static func stamp(_ index: Int, inode: UInt64 = 0) -> SourceStamp {
        var info = stat()
        info.st_dev = 1
        info.st_ino = 100 + UInt64(index) + inode
        info.st_size = 1_000_000 + Int64(index)
        info.st_mtimespec = timespec(tv_sec: 1_792_000_000, tv_nsec: index)
        info.st_ctimespec = info.st_mtimespec
        return SourceStamp(info, keepsChangeTime: true)
    }

    private static func identity(_ frame: Frame, sha256: String? = nil, inode: UInt64 = 0) -> AutoDecisions.Identity {
        let stamp = stamp(frame.id, inode: inode)
        return AutoDecisions.Identity(fileName: frame.url.lastPathComponent, byteCount: Int(stamp.size),
                                      captureDate: frame.info.captureDate, sha256: sha256, stamp: stamp)
    }

    private static func snapshot(failed: Set<Int> = [], shift: [Int: Float] = [:], controls: RollControls = RollControls(),
                                 own: [Int: FrameControls] = [:], sha: [Int: String] = [:], reversed: Bool = false) -> AutoDecisions.Snapshot {
        let frames = frames
        var analyses: [URL: ExposureAnalysis] = [:], identities: [URL: AutoDecisions.Identity] = [:]
        var frameControls: [URL: FrameControls] = [:]
        // Filled in either order: a dictionary's order must not reach the decision.
        for frame in reversed ? frames.reversed() : frames {
            if !failed.contains(frame.id) { analyses[frame.url] = analysis(frame.id, shift: shift[frame.id] ?? 0) }
            identities[frame.url] = identity(frame, sha256: sha[frame.id])
            if let mine = own[frame.id] { frameControls[frame.url] = mine }
        }
        let input = SequenceAims.Input(frames: frames, analyses: analyses, descriptors: [:], stock: stock, controls: controls,
                                       frameControls: frameControls)
        return AutoDecisions.Snapshot(input: input, stockDigest: stock.digest, identities: identities,
                                      failed: Set(failed.map { frames[$0].url }))
    }

    private static func bits(_ aims: [URL: PrintAim]) -> [[UInt32]] {
        frames.map { frame in
            aims[frame.url].map { [$0.level.bitPattern, $0.cast.x.bitPattern, $0.cast.y.bitPattern, $0.cast.z.bitPattern] } ?? []
        }
    }

    @Test func theSameSnapshotGivesTheSameRevisionAndAimsBitForBit() {
        let one = AutoDecisions.decide(Self.snapshot(), method: .control)
        let other = AutoDecisions.decide(Self.snapshot(reversed: true), method: .control)
        #expect(one.revision == other.revision && one.revision.count == 64)
        #expect(Self.bits(one.aims) == Self.bits(other.aims))
        #expect(one.record == other.record)
        // The control is roll smoothing as shipped over the whole roll.
        let analyses = Dictionary(uniqueKeysWithValues: Self.frames.map { ($0.url, Self.analysis($0.id)) })
        #expect(Self.bits(one.aims) == Self.bits(RollSmoothing.aims(Self.frames, analyses: analyses)))
        #expect(one.record.frames.map(\.initial) == Self.frames.map { AutoPrint.levelStops(Self.analysis($0.id)) })
        #expect(one.record.decisionVersion == AutoDecisions.version && one.record.method == .control)
        #expect(one.record.controls == nil)
    }

    @Test func aFailedFramePrintsAtTheFallbackAndTheRestSettle() {
        let decision = AutoDecisions.decide(Self.snapshot(failed: [1]))
        let frames = Self.frames
        #expect(decision.aims.count == frames.count && decision.aims[frames[1].url] == PrintAim())
        #expect(decision.failed == [frames[1].url] && AutoDecisions.decide(Self.snapshot()).failed.isEmpty)
        #expect(decision.record.frames[1].status == .failed && decision.record.frames[1].initial == nil)
        #expect(decision.record.frames[1].analysisVersion == nil && decision.record.frames[0].status == .measured)
        #expect(decision.revision != AutoDecisions.decide(Self.snapshot()).revision)
    }

    @Test func theRevisionReadsWhatTheMethodReads() {
        let base = AutoDecisions.decide(Self.snapshot(), method: .control).revision
        // The measurements and the raws.
        #expect(AutoDecisions.decide(Self.snapshot(shift: [2: 0.001]), method: .control).revision != base)
        #expect(AutoDecisions.decide(Self.snapshot(sha: [3: String(repeating: "a", count: 64)]), method: .control).revision != base)
        // Roll smoothing reads neither the stock nor the controls.
        let warm = RollControls(ratedAt: .oneStopOver, labBalance: .warm)
        #expect(AutoDecisions.decide(Self.snapshot(controls: warm, own: [0: FrameControls(labBalance: .cool)]), method: .control).revision == base)
        #expect(AutoDecisions.decide(Self.snapshot(), method: .smoothing).revision != base)
        // The control reads no parameter either: a change of the defaults leaves its revision, so
        // its rolls are not developed again. The candidates read theirs.
        var parameters = SequenceAims.Parameters()
        parameters.neighbours = 4
        let edited = AutoDecisions.decide(Self.snapshot(), method: .control, parameters: parameters)
        #expect(edited.revision == base && Self.bits(edited.aims) == Self.bits(AutoDecisions.decide(Self.snapshot(), method: .control).aims))
        let smoothing = AutoDecisions.decide(Self.snapshot(), method: .smoothing).revision
        #expect(AutoDecisions.decide(Self.snapshot(), method: .smoothing, parameters: parameters).revision != smoothing)
        // A method that renders through the stock reads it and the controls.
        let render = AutoDecisions.decide(Self.snapshot(), method: .render)
        #expect(AutoDecisions.decide(Self.snapshot(), method: .render, parameters: parameters).revision != render.revision)
        #expect(render.record.controls == AutoDecisions.Record.Controls(stockID: Self.stock.id, stockDigest: Self.stock.digest,
                                                                         roll: RollControls(), frames: [:]))
        #expect(AutoDecisions.decide(Self.snapshot(controls: warm), method: .render).revision != render.revision)
        #expect(AutoDecisions.decide(Self.snapshot(own: [0: FrameControls(labBalance: .cool)]), method: .render).revision
                != render.revision)
    }

    @Test func aKeptDecisionHoldsOnlyForTheSameRaws() {
        let frames = Self.frames, sha = String(repeating: "b", count: 64)
        let decision = AutoDecisions.decide(Self.snapshot(sha: [0: sha]))
        func now(_ change: (inout [URL: AutoDecisions.Identity]) -> Void = { _ in }) -> [URL: AutoDecisions.Identity] {
            var identities = Dictionary(uniqueKeysWithValues: frames.map { ($0.url, Self.identity($0, sha256: $0.id == 0 ? sha : nil)) })
            change(&identities)
            return identities
        }
        func restored(_ identities: [URL: AutoDecisions.Identity], frames: [Frame] = Self.frames,
                      method: SequenceAims.Method = AutoDecisions.method) -> AutoDecisions.Decision? {
            AutoDecisions.restored(decision.record, frames: frames, identities: identities, stockDigest: Self.stock.digest,
                                   controls: RollControls(), frameControls: [:], method: method)
        }
        // The same raws, on a share mounted again (another device), with the same aims bit for bit.
        let again = restored(now { identities in
            for frame in frames { identities[frame.url]?.stamp?.device = 9 }
        })
        #expect(again?.revision == decision.revision && again.map { Self.bits($0.aims) } == Self.bits(decision.aims))
        // A SHA-256 both know decides, whatever the stamp says.
        #expect(restored(now { $0[frames[0].url]?.stamp?.inode = 1 }) != nil)
        #expect(restored(now { $0[frames[0].url]?.sha256 = String(repeating: "c", count: 64) }) == nil)
        // Otherwise the stamp: another version of a raw, another size or name invalidates it.
        #expect(restored(now { $0[frames[2].url]?.stamp?.modified += 1 }) == nil)
        #expect(restored(now { $0[frames[2].url]?.byteCount += 1 }) == nil)
        #expect(restored(now { $0[frames[2].url]?.fileName = "DSC09.ARW" }) == nil)
        #expect(restored(now(), frames: Array(frames.dropLast()))?.revision == decision.revision)
        // Another method.
        #expect(restored(now(), method: .smoothing) == nil)
        // Other parameters, which the shipped method does not read; a candidate holds only for its own.
        var parameters = SequenceAims.Parameters()
        parameters.minimumOverlap = 0.5
        #expect(AutoDecisions.restored(decision.record, frames: frames, identities: now(), stockDigest: Self.stock.digest,
                                       controls: RollControls(), frameControls: [:], parameters: parameters)?.revision == decision.revision)
        let candidate = AutoDecisions.decide(Self.snapshot(sha: [0: sha]), method: .smoothing).record
        #expect(AutoDecisions.restored(candidate, frames: frames, identities: now(), stockDigest: Self.stock.digest,
                                       controls: RollControls(), frameControls: [:], method: .smoothing) != nil)
        #expect(AutoDecisions.restored(candidate, frames: frames, identities: now(), stockDigest: Self.stock.digest,
                                       controls: RollControls(), frameControls: [:], method: .smoothing, parameters: parameters) == nil)
        // Measurements of another version, which print the roll again: so is its decision made again.
        var stale = decision.record
        stale.frames[2].analysisVersion = "2026-10-19-1"
        #expect(AutoDecisions.restored(stale, frames: frames, identities: now(), stockDigest: Self.stock.digest,
                                       controls: RollControls(), frameControls: [:]) == nil)
        // A frame that failed has no measurement to be stale.
        let failed = AutoDecisions.decide(Self.snapshot(failed: [2], sha: [0: sha])).record
        #expect(failed.frames[2].analysisVersion == nil)
        // It is restored as failed, so that one measured since balances the roll again.
        #expect(AutoDecisions.restored(failed, frames: frames, identities: now(), stockDigest: Self.stock.digest,
                                       controls: RollControls(), frameControls: [:])?.failed == [frames[2].url])
    }

    @Test func detailDecisionTracksEffectiveStocksAndToneInputs() {
        var snapshot = Self.snapshot()
        let url = Self.frames[0].url
        snapshot.frameStockDigests[url] = "effective-stock"
        let settled = AutoDecisions.decide(snapshot)
        #expect(settled.record.method == .detail)
        #expect(settled.record.controls?.frameStockDigests == [url.lastPathComponent: "effective-stock"])
        func restore(_ digest: String, _ own: [URL: FrameControls] = [:]) -> AutoDecisions.Decision? {
            AutoDecisions.restored(settled.record, frames: snapshot.input.frames, identities: snapshot.identities,
                                   stockDigest: snapshot.stockDigest, controls: snapshot.input.controls,
                                   frameControls: own, frameStockDigests: [url: digest])
        }
        #expect(restore("effective-stock") == settled)
        #expect(restore("changed-stock") == nil)
        #expect(restore("effective-stock", [url: FrameControls(ratedAt: .oneStopUnder)]) == nil)
        #expect(restore("effective-stock", [url: FrameControls(labBalance: .cool)]) == nil)
        #expect(restore("effective-stock", [url: FrameControls(halation: 0)]) == settled)
        snapshot.frameStockDigests[url] = "changed-stock"
        #expect(AutoDecisions.decide(snapshot).revision != settled.revision)
    }

    @Test func cullingPreservesTheRevisionAndEverySurvivingAim() throws {
        let snapshot = Self.snapshot(), original = AutoDecisions.decide(snapshot)
        // First, middle/bridging, last, and repeated culls, including a single surviving frame.
        for removed in [[0], [1, 2], [5], [0, 1, 3, 4, 5]] {
            let frames = Self.frames.filter { !removed.contains($0.id) }
            let kept = try #require(AutoDecisions.restored(original.record, frames: frames, identities: snapshot.identities,
                stockDigest: Self.stock.digest, controls: RollControls(), frameControls: [:]))
            #expect(kept.revision == original.revision)
            #expect(kept.aims == original.aims.filter { url, _ in frames.contains { $0.url == url } })
            #expect(kept.record.frames.map(\.fileName) == frames.map { $0.url.lastPathComponent })
            let roundTripped = try JSONDecoder().decode(AutoDecisions.Record.self, from: JSONEncoder().encode(kept.record))
            #expect(AutoDecisions.restored(roundTripped, frames: frames, identities: snapshot.identities,
                stockDigest: Self.stock.digest, controls: RollControls(), frameControls: [:]) == kept)
            // Membership is projected, so putting a culled file back requires a new resolution.
            #expect(AutoDecisions.restored(roundTripped, frames: Self.frames, identities: snapshot.identities,
                stockDigest: Self.stock.digest, controls: RollControls(), frameControls: [:]) == nil)
        }
        // Rebalancing the smaller input is allowed to move aims; ordinary culling must not do this.
        var smaller = snapshot
        smaller.input.frames.removeFirst()
        let recalculated = AutoDecisions.decide(smaller)
        #expect(recalculated.revision != original.revision)
        #expect(smaller.input.frames.contains { recalculated.aims[$0.url] != original.aims[$0.url] })

        // Removed failures and stale measurements do not invalidate the surviving decision.
        var failed = AutoDecisions.decide(Self.snapshot(failed: [1])).record
        failed.frames[2].analysisVersion = "old"
        let remaining = Self.frames.filter { ![1, 2].contains($0.id) }
        let kept = try #require(AutoDecisions.restored(failed, frames: remaining, identities: snapshot.identities,
            stockDigest: Self.stock.digest, controls: RollControls(), frameControls: [:]))
        #expect(kept.failed.isEmpty && kept.revision == failed.revision)
        // Reordering or ambiguous records are not culls.
        #expect(AutoDecisions.restored(original.record, frames: Array(Self.frames.reversed()), identities: snapshot.identities,
            stockDigest: Self.stock.digest, controls: RollControls(), frameControls: [:]) == nil)
        var duplicate = original.record
        duplicate.frames.append(duplicate.frames[0])
        #expect(AutoDecisions.restored(duplicate, frames: remaining, identities: snapshot.identities,
            stockDigest: Self.stock.digest, controls: RollControls(), frameControls: [:]) == nil)
    }

    @Test func aCulledStockReadingDecisionChecksOnlySurvivingOverrides() throws {
        let snapshot = Self.snapshot(own: [1: FrameControls(ratedAt: .oneStopOver), 3: FrameControls(labBalance: .warm)])
        let original = AutoDecisions.decide(snapshot, method: .render)
        let frames = Self.frames.filter { $0.id != 1 }
        let own = [Self.frames[3].url: FrameControls(labBalance: .warm)]
        let kept = try #require(AutoDecisions.restored(original.record, frames: frames, identities: snapshot.identities,
            stockDigest: Self.stock.digest, controls: RollControls(), frameControls: own, method: .render))
        #expect(kept.revision == original.revision)
        #expect(kept.record.controls?.frames == [Self.frames[3].url.lastPathComponent: FrameControls(labBalance: .warm)])
        #expect(AutoDecisions.restored(original.record, frames: frames, identities: snapshot.identities,
            stockDigest: Self.stock.digest, controls: RollControls(), frameControls: [:], method: .render) == nil)
        #expect(AutoDecisions.restored(original.record, frames: frames, identities: snapshot.identities,
            stockDigest: Self.stock.digest, controls: RollControls(labBalance: .cool), frameControls: own, method: .render) == nil)
        #expect(AutoDecisions.restored(original.record, frames: frames, identities: snapshot.identities,
            stockDigest: "changed", controls: RollControls(), frameControls: own, method: .render) == nil)
        var changed = snapshot.identities
        changed[frames[0].url]?.stamp?.modified += 1
        #expect(AutoDecisions.restored(original.record, frames: frames, identities: changed,
            stockDigest: Self.stock.digest, controls: RollControls(), frameControls: own, method: .render) == nil)
    }

    @Test func aKeptStockReadingDecisionHoldsOnlyForItsControls() {
        let frames = Self.frames
        let decision = AutoDecisions.decide(Self.snapshot(own: [1: FrameControls(ratedAt: .oneStopOver)]), method: .render)
        let identities = Dictionary(uniqueKeysWithValues: frames.map { ($0.url, Self.identity($0)) })
        func restored(_ controls: RollControls, own: [URL: FrameControls], digest: String = Self.stock.digest) -> Bool {
            AutoDecisions.restored(decision.record, frames: frames, identities: identities, stockDigest: digest,
                                   controls: controls, frameControls: own, method: .render) != nil
        }
        let mine = [frames[1].url: FrameControls(ratedAt: .oneStopOver)]
        #expect(restored(RollControls(), own: mine))
        #expect(!restored(RollControls(labBalance: .warm), own: mine))
        #expect(!restored(RollControls(), own: [:]))
        #expect(!restored(RollControls(), own: mine, digest: "another"))
    }

    @Test func theStorePreservesADecisionItCannotRead() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("argent-decisions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let store = AutoDecisionStore(library: library)
        let roll = URL(fileURLWithPath: "/Volumes/Card/DCIM/100MSDCF")
        let record = AutoDecisions.decide(Self.snapshot(failed: [4])).record
        #expect(try store.save(record, for: roll))
        let file = store.file(for: roll)
        let original = try Data(contentsOf: file)
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)

        #expect(store.stored(for: roll) == .unreadable)
        #expect(store.record(for: roll) == nil)
        let replacement = AutoDecisions.decide(Self.snapshot()).record
        #expect(try !store.save(replacement, for: roll))

        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func theStoreKeepsADecisionARollAndLeavesWhatItCannotRead() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("argent-decisions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let store = AutoDecisionStore(library: library)
        let roll = URL(fileURLWithPath: "/Volumes/Card/DCIM/100MSDCF"), other = URL(fileURLWithPath: "/Volumes/Card/DCIM/101MSDCF")
        #expect(store.stored(for: roll) == AutoDecisionStore.Stored.none)
        let file = store.file(for: roll)
        #expect(file.deletingLastPathComponent() == library.appendingPathComponent("AutoDecisions/v1", isDirectory: true))
        #expect(file.lastPathComponent.count == 64 + 5 && file != store.file(for: other))

        let record = AutoDecisions.decide(Self.snapshot(failed: [4])).record
        #expect(try store.save(record, for: roll))
        let kept = try #require(store.record(for: roll))
        #expect(kept == record && Self.bits(Dictionary(uniqueKeysWithValues: zip(Self.frames.map(\.url), kept.frames.map(\.aim))))
                == Self.bits(Dictionary(uniqueKeysWithValues: zip(Self.frames.map(\.url), record.frames.map(\.aim)))))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"format\" : \"camera.argent.auto-decisions\"") && text.contains("\"version\" : 1"))
        #expect(text.contains("\"status\" : \"failed\""))

        // A later layout is preserved, read as none and never written over.
        var future = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        future["version"] = AutoDecisions.Record.currentVersion + 1
        let futureBytes = try JSONSerialization.data(withJSONObject: future)
        try futureBytes.write(to: file)
        #expect(store.stored(for: roll) == .future(AutoDecisions.Record.currentVersion + 1) && store.record(for: roll) == nil)
        #expect(try !store.save(record, for: roll))
        #expect(try Data(contentsOf: file) == futureBytes)

        // So is a file this build cannot read.
        for unreadable in [Data("not json".utf8), Data(#"{"format":"another","version":1}"#.utf8),
                           Data(#"{"format":"camera.argent.auto-decisions","version":1,"frames":7}"#.utf8)] {
            try unreadable.write(to: file)
            #expect(store.stored(for: roll) == .unreadable)
            #expect(try !store.save(record, for: roll))
            #expect(try Data(contentsOf: file) == unreadable)
        }
    }
}
