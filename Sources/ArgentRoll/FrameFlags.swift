import ArgentCore
import CryptoKit
import Foundation

/// A roll's flagged frames as kept on disk (`FlagStore`): only the flagged ones, each by the raw it
/// was flagged as, its file name, size and capture time. A raw replaced by other bytes under the same
/// name, or renamed, reads as unflagged, and so does another card's raw at the same path. A flag never
/// changes a print: it only chooses what the sheet shows and Develop develops.
public struct FlagRecord: Sendable, Equatable, Codable {
    public static let formatName = "camera.argent.flags"
    /// The file's layout; a later one is preserved, never read or written over.
    public static let currentVersion = 1

    public var format = FlagRecord.formatName
    public var version = FlagRecord.currentVersion
    /// The flagged raws, one entry a raw, in file name order. Entries no frame of the roll matches now
    /// are kept: they may be another card's, mounted at the same path.
    public var frames: [Entry]

    /// A flagged raw: its file name, its size in bytes and its capture time, all three matched.
    public struct Entry: Sendable, Equatable, Codable {
        public var fileName: String
        public var byteCount: Int
        public var captureDate: Date?

        public init(fileName: String, byteCount: Int, captureDate: Date?) {
            self.fileName = fileName
            self.byteCount = byteCount
            self.captureDate = captureDate
        }

        /// `frame`'s raw, `byteCount` bytes long.
        public init(_ frame: Frame, byteCount: Int) {
            self.init(fileName: frame.url.lastPathComponent, byteCount: byteCount, captureDate: frame.info.captureDate)
        }

        /// The capture time in milliseconds since 1970, as far as the camera writes it.
        var captureMilliseconds: Int64? { captureDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } }

        /// Whether `other` is the same raw: the same name and size, and the same capture time to the
        /// millisecond, or neither with one.
        public func matches(_ other: Entry) -> Bool {
            fileName == other.fileName && byteCount == other.byteCount && captureMilliseconds == other.captureMilliseconds
        }
    }

    /// The record of `frames`, one entry a raw, in file name order.
    public init(frames: [Entry]) {
        struct Identity: Hashable {
            let fileName: String
            let byteCount: Int
            let captureMilliseconds: Int64?
        }
        var seen: Set<Identity> = []
        var kept: [Entry] = []
        for entry in frames {
            let identity = Identity(fileName: entry.fileName, byteCount: entry.byteCount, captureMilliseconds: entry.captureMilliseconds)
            if seen.insert(identity).inserted { kept.append(entry) }
        }
        self.frames = kept.sorted {
            ($0.fileName, $0.captureMilliseconds ?? .min, $0.byteCount) < ($1.fileName, $1.captureMilliseconds ?? .min, $1.byteCount)
        }
    }

    /// Which frames the record flags, given the raw each frame's file is now (`identities`), with the
    /// entry each matches; and the entries no frame matches, which a save keeps.
    public func matched(to identities: [URL: Entry]) -> (flagged: [URL: Entry], unmatched: [Entry]) {
        let byName = Dictionary(grouping: frames, by: \.fileName)
        var flagged: [URL: Entry] = [:]
        var matchedNames: [String: [Entry]] = [:]
        for (url, identity) in identities {
            guard let entry = byName[identity.fileName]?.first(where: { $0.matches(identity) }) else { continue }
            flagged[url] = entry
            matchedNames[entry.fileName, default: []].append(entry)
        }
        let unmatched = frames.filter { entry in !(matchedNames[entry.fileName] ?? []).contains(where: entry.matches) }
        return (flagged, unmatched)
    }
}

/// Where each roll's flags are kept (`FlagRecord`): one JSON file a roll in the recipe library,
/// `Flags/v1/<SHA-256 of the roll folder's canonical path>.json`, written whole and atomically with
/// sorted keys, as `AutoDecisionStore` keeps a roll's settled decision. Not beside the raws: a card
/// may be locked, and a flag is the owner's choice of frames, not a frame's development. A file this
/// build cannot read, or one a later build wrote, is left as it is: read as none, and never written
/// over. Only a missing file is a roll without flags.
public struct FlagStore: Sendable {
    /// What is kept for a roll.
    public enum Stored: Sendable, Equatable {
        /// No file: the roll has no flags.
        case none
        case record(FlagRecord)
        /// Not flags this build can read: another format, damaged, or a file it may not read.
        case unreadable
        /// Flags in a later layout than `FlagRecord.currentVersion`.
        case future(Int)
    }

    /// The recipe library the flags are kept in; tests give their own.
    public let library: URL

    public init(library: URL = RecipeStore.defaultLibrary) {
        self.library = library
    }

    public var folder: URL { library.appendingPathComponent("Flags/v1", isDirectory: true) }

    /// The file kept for the roll at `roll`, a folder or a card.
    public func file(for roll: URL) -> URL {
        let name = SHA256.hash(data: Data(roll.canonicalPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name).appendingPathExtension("json")
    }

    public func stored(for roll: URL) -> Stored {
        let data: Data
        do {
            data = try Data(contentsOf: file(for: roll))
        } catch CocoaError.fileReadNoSuchFile {
            return .none
        } catch {
            // There but not readable, such as a file at mode 000: kept, as a damaged one is.
            return .unreadable
        }
        struct Header: Decodable { var format: String; var version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == FlagRecord.formatName
        else { return .unreadable }
        guard header.version <= FlagRecord.currentVersion else { return .future(header.version) }
        guard let record = try? JSONDecoder().decode(FlagRecord.self, from: data), record.version >= 1 else { return .unreadable }
        return .record(record)
    }

    /// The flags kept for `roll`, when there are some this build can read.
    public func record(for roll: URL) -> FlagRecord? {
        if case .record(let record) = stored(for: roll) { return record }
        return nil
    }

    /// Keeps `record` as `roll`'s, in place of the one there, unless the file there is one this build
    /// cannot read or a later build wrote, which stays: `false` then.
    @discardableResult
    public func save(_ record: FlagRecord, for roll: URL) throws -> Bool {
        switch stored(for: roll) {
        case .unreadable, .future: return false
        case .none, .record: break
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file(for: roll), options: .atomic)
        return true
    }
}
