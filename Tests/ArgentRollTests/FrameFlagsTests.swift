import ArgentCore
import Foundation
import Testing
@testable import ArgentRoll

/// A roll's flags on disk (`FlagRecord`, `FlagStore`): kept a roll each in the library and read back
/// whole; a raw counts as flagged only while its name, size and capture time are the flagged raw's;
/// entries no frame matches stay through a save; a file this build cannot read is left byte for byte.
@Suite struct FrameFlagsTests {
    /// To the millisecond, as the a7 IV writes SubSecTimeOriginal.
    private static let start = Date(timeIntervalSince1970: 1_792_000_000.125)

    private static func quadraticRecord(_ entries: [FlagRecord.Entry]) -> FlagRecord {
        var kept: [FlagRecord.Entry] = []
        for entry in entries where !kept.contains(where: entry.matches) { kept.append(entry) }
        var record = FlagRecord(frames: [])
        record.frames = kept.sorted {
            ($0.fileName, $0.captureMilliseconds ?? .min, $0.byteCount) < ($1.fileName, $1.captureMilliseconds ?? .min, $1.byteCount)
        }
        return record
    }

    @Test func dedupKeepsTheFirstExactRepresentativeAndSortsIdentities() {
        let first = Self.entry("DSC00001.ARW", bytes: 10, at: 0.0001)
        let collision = Self.entry("DSC00001.ARW", bytes: 10, at: 0.0004)
        let nextMillisecond = Self.entry("DSC00001.ARW", bytes: 10, at: 0.0006)
        let undated = Self.entry("DSC00001.ARW", bytes: 10, at: nil)
        let larger = Self.entry("DSC00001.ARW", bytes: 11, at: 0.0001)
        let last = Self.entry("DSC00002.ARW", bytes: 1, at: nil)
        #expect(first != collision && first.matches(collision))
        #expect(!first.matches(nextMillisecond))
        #expect(FlagRecord(frames: [last, first, nextMillisecond, larger, undated, collision, undated]).frames
                == [undated, first, larger, nextMillisecond, last])
        #expect(FlagRecord(frames: [collision, first]).frames == [collision])
        #expect(FlagRecord(frames: []).frames.isEmpty)
    }

    @Test func encodedBytesMatchTheQuadraticReference() throws {
        var state: UInt64 = 0xCAFE
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(bound))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for count in [0, 1, 10, 100, 1000] {
            var entries: [FlagRecord.Entry] = []
            for _ in 0..<count {
                let name = ["DSC00001.ARW", "DSC00002.ARW", "é.ARW", "e\u{301}.ARW"][next(4)]
                entries.append(Self.entry(name, bytes: next(4), at: next(5) == 0 ? nil : Double(next(20) - 10) / 10000))
                if next(3) == 0 { entries.append(entries[next(entries.count)]) }
            }
            #expect(try encoder.encode(FlagRecord(frames: entries)) == encoder.encode(Self.quadraticRecord(entries)))
        }
    }

    private static func frame(_ name: String, at seconds: Double?, folder: String = "/flags/Roll") -> Frame {
        Frame(id: 0, url: URL(fileURLWithPath: folder).appendingPathComponent(name),
              info: ARWFrameInfo(captureDate: seconds.map { start.addingTimeInterval($0) }))
    }

    private static func entry(_ name: String, bytes: Int, at seconds: Double?) -> FlagRecord.Entry {
        FlagRecord.Entry(fileName: name, byteCount: bytes, captureDate: seconds.map { start.addingTimeInterval($0) })
    }

    private static func withLibrary(_ body: (FlagStore, URL) throws -> Void) rethrows {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("argent-flags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        try body(FlagStore(library: library), library)
    }

    @Test func theStoreKeepsARollsFlagsAndReadsThemBack() throws {
        try Self.withLibrary { store, library throws in
            let roll = URL(fileURLWithPath: "/Volumes/Card/DCIM/100MSDCF")
            #expect(store.stored(for: roll) == FlagStore.Stored.none && store.record(for: roll) == nil)
            let file = store.file(for: roll)
            #expect(file.deletingLastPathComponent() == library.appendingPathComponent("Flags/v1", isDirectory: true))
            #expect(file.lastPathComponent.count == 64 + 5 && file.pathExtension == "json")

            let record = FlagRecord(frames: [Self.entry("DSC00003.ARW", bytes: 30, at: 20.5), Self.entry("DSC00001.ARW", bytes: 10, at: 0),
                                             Self.entry("DSC00002.ARW", bytes: 20, at: nil)])
            // One entry a raw, in file name order.
            #expect(record.frames.map(\.fileName) == ["DSC00001.ARW", "DSC00002.ARW", "DSC00003.ARW"])
            #expect(FlagRecord(frames: record.frames + record.frames) == record)
            #expect(try store.save(record, for: roll))
            #expect(store.record(for: roll) == record)
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("\"format\" : \"camera.argent.flags\"") && text.contains("\"version\" : 1"))
            #expect(text.contains("\"fileName\" : \"DSC00002.ARW\""))

            // Read back, each entry still matches the raw it was written for, to the millisecond.
            let kept = try #require(store.record(for: roll))
            for (written, read) in zip(record.frames, kept.frames) { #expect(read.matches(written)) }
            // Unflagging every frame keeps an empty list, not the old one.
            #expect(try store.save(FlagRecord(frames: []), for: roll))
            #expect(store.record(for: roll)?.frames.isEmpty == true)
        }
    }

    @Test func twoRollsAreKeptApart() throws {
        try Self.withLibrary { store, _ throws in
            let first = URL(fileURLWithPath: "/flags/Roll A"), second = URL(fileURLWithPath: "/flags/Roll B")
            #expect(store.file(for: first) != store.file(for: second))
            let one = FlagRecord(frames: [Self.entry("DSC00001.ARW", bytes: 10, at: 0)])
            let other = FlagRecord(frames: [Self.entry("DSC00009.ARW", bytes: 90, at: 80)])
            #expect(try store.save(one, for: first))
            #expect(store.stored(for: second) == FlagStore.Stored.none)
            #expect(try store.save(other, for: second))
            #expect(store.record(for: first) == one && store.record(for: second) == other)
            // Another spelling of the same folder is the same roll.
            #expect(store.file(for: URL(fileURLWithPath: "/flags/./Roll A")) == store.file(for: first))
        }
    }

    /// A raw is flagged only while its name, size and capture time are those it was flagged with: not
    /// once replaced by other bytes under its name, nor renamed, nor on another card at the same path.
    @Test func onlyTheFlaggedRawReadsAsFlagged() {
        let flagged = Self.frame("DSC00001.ARW", at: 0), undated = Self.frame("DSC00002.ARW", at: nil)
        let record = FlagRecord(frames: [FlagRecord.Entry(flagged, byteCount: 10), FlagRecord.Entry(undated, byteCount: 20)])
        let same = record.matched(to: [flagged.url: FlagRecord.Entry(flagged, byteCount: 10),
                                       undated.url: FlagRecord.Entry(undated, byteCount: 20)])
        #expect(Set(same.flagged.keys) == [flagged.url, undated.url] && same.unmatched.isEmpty)

        // Other bytes under the same name: another size, or the same size taken at another time.
        let resized = FlagRecord.Entry(fileName: "DSC00001.ARW", byteCount: 11, captureDate: Self.start)
        let retaken = FlagRecord.Entry(fileName: "DSC00001.ARW", byteCount: 10, captureDate: Self.start.addingTimeInterval(0.001))
        // The same raw under another name.
        let renamed = FlagRecord.Entry(fileName: "DSC00001 copy.ARW", byteCount: 10, captureDate: Self.start)
        // Another card mounted at the same path, numbering from DSC00001 again.
        let otherCard = Self.frame("DSC00001.ARW", at: 86_400, folder: "/Volumes/Untitled/DCIM/100MSDCF")
        // A date where none was flagged, and none where one was.
        let dated = FlagRecord.Entry(fileName: "DSC00002.ARW", byteCount: 20, captureDate: Self.start)
        let undatedNow = FlagRecord.Entry(fileName: "DSC00001.ARW", byteCount: 10, captureDate: nil)
        for identity in [resized, retaken, renamed, FlagRecord.Entry(otherCard, byteCount: 10), dated, undatedNow] {
            let url = URL(fileURLWithPath: "/flags/Roll").appendingPathComponent(identity.fileName)
            let result = record.matched(to: [url: identity])
            #expect(result.flagged.isEmpty, "\(identity)")
            #expect(result.unmatched == record.frames, "\(identity)")
        }
    }

    /// Entries no frame of the roll matches now, such as another card's at the same path, stay in the
    /// file when the roll's own flags are saved.
    @Test func entriesNoFrameMatchesAreKeptThroughASave() throws {
        try Self.withLibrary { store, _ throws in
            let roll = URL(fileURLWithPath: "/Volumes/Untitled")
            let otherCards = [Self.entry("DSC00001.ARW", bytes: 10, at: -86_400), Self.entry("DSC00002.ARW", bytes: 20, at: -86_390)]
            #expect(try store.save(FlagRecord(frames: otherCards), for: roll))

            // This card's DSC00001 is another raw; its DSC00003 is flagged now.
            let mine = Self.frame("DSC00001.ARW", at: 0), third = Self.frame("DSC00003.ARW", at: 20)
            let kept = try #require(store.record(for: roll))
            let identities = [mine.url: FlagRecord.Entry(mine, byteCount: 10), third.url: FlagRecord.Entry(third, byteCount: 30)]
            let matched = kept.matched(to: identities)
            #expect(matched.flagged.isEmpty && matched.unmatched == otherCards)
            let saved = FlagRecord(frames: matched.unmatched + [FlagRecord.Entry(third, byteCount: 30)])
            #expect(try store.save(saved, for: roll))

            let read = try #require(store.record(for: roll))
            #expect(read.frames.count == 3)
            #expect(Set(read.matched(to: identities).flagged.keys) == [third.url])
            for entry in otherCards { #expect(read.frames.contains(where: entry.matches)) }
        }
    }

    @Test func aFileThisBuildCannotReadIsLeftByteForByte() throws {
        try Self.withLibrary { store, _ throws in
            let roll = URL(fileURLWithPath: "/flags/Roll")
            let record = FlagRecord(frames: [Self.entry("DSC00001.ARW", bytes: 10, at: 0)])
            #expect(try store.save(record, for: roll))
            let file = store.file(for: roll)

            // A later layout is preserved, read as none and never written over.
            var future = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            future["version"] = FlagRecord.currentVersion + 1
            let futureBytes = try JSONSerialization.data(withJSONObject: future)
            try futureBytes.write(to: file)
            #expect(store.stored(for: roll) == .future(FlagRecord.currentVersion + 1) && store.record(for: roll) == nil)
            #expect(try !store.save(record, for: roll))
            #expect(try Data(contentsOf: file) == futureBytes)

            // So is a file this build cannot read.
            for unreadable in [Data("not json".utf8), Data(#"{"format":"another","version":1,"frames":[]}"#.utf8),
                               Data(#"{"format":"camera.argent.flags","version":1,"frames":7}"#.utf8),
                               Data(#"{"format":"camera.argent.flags","version":0,"frames":[]}"#.utf8)] {
                try unreadable.write(to: file)
                #expect(store.stored(for: roll) == .unreadable)
                #expect(try !store.save(record, for: roll))
                #expect(try Data(contentsOf: file) == unreadable)
            }
        }
    }

    /// Only a missing file is a roll without flags: one there that cannot be read, such as a file at
    /// mode 000, may hold flags, so it is never written over.
    @Test func aFileThatCannotBeReadIsNotNoFlags() throws {
        try Self.withLibrary { store, _ throws in
            let roll = URL(fileURLWithPath: "/flags/Roll")
            // No file, and no folder for it yet.
            #expect(store.stored(for: roll) == FlagStore.Stored.none)
            let record = FlagRecord(frames: [Self.entry("DSC00001.ARW", bytes: 10, at: 0)])
            #expect(try store.save(record, for: roll))
            let file = store.file(for: roll), bytes = try Data(contentsOf: file)

            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            #expect(store.stored(for: roll) == .unreadable && store.record(for: roll) == nil)
            #expect(try !store.save(FlagRecord(frames: []), for: roll))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect(try Data(contentsOf: file) == bytes && store.record(for: roll) == record)
        }
    }
}
