import Foundation

public struct PresetStore: Sendable {
    public static let fileExtension = "argentpreset"

    public enum StoreError: Error, LocalizedError, Equatable {
        case invalidPreset(String)
        case alreadyExists(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPreset(let reason): "Invalid look preset: \(reason)"
            case .alreadyExists(let name): "A copy of “\(name)” is already in the preset library."
            }
        }
    }

    public struct LoadResult: Sendable {
        public var presets: [UserPreset] = []
        public var issues: [String] = []
    }

    public let folder: URL

    public static var defaultFolder: URL {
        ApplicationSupport.folder.appendingPathComponent("Presets", isDirectory: true)
    }

    public init(folder: URL) { self.folder = folder }

    private func file(for id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension(Self.fileExtension)
    }

    public func load(id: UUID) throws -> UserPreset {
        let preset = try Self.read(from: file(for: id))
        guard preset.id == id else { throw StoreError.invalidPreset("The file name does not match its ID.") }
        return preset
    }

    public func loadAll() throws -> LoadResult {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch CocoaError.fileReadNoSuchFile {
            return LoadResult()
        }
        var result = LoadResult()
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == Self.fileExtension {
            do {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), file(for: id).lastPathComponent == url.lastPathComponent else {
                    throw StoreError.invalidPreset("The file name must be its UUID.")
                }
                result.presets.append(try load(id: id))
            } catch {
                result.issues.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        result.presets.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        return result
    }

    @discardableResult
    public func save(_ preset: UserPreset) throws -> URL {
        let data = try Self.data(for: preset)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = file(for: preset.id)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: file(for: id))
    }

    @discardableResult
    public func importPreset(from url: URL) throws -> UserPreset {
        let preset = try Self.read(from: url)
        guard !FileManager.default.fileExists(atPath: file(for: preset.id).path) else {
            throw StoreError.alreadyExists(preset.name)
        }
        try save(preset)
        return preset
    }

    public func exportPreset(id: UUID, to url: URL) throws {
        try Self.data(for: load(id: id)).write(to: url, options: .atomic)
    }

    private static func read(from url: URL) throws -> UserPreset {
        let decoder = JSONDecoder()
        let preset: UserPreset
        do {
            preset = try decoder.decode(UserPreset.self, from: Data(contentsOf: url))
        } catch let DecodingError.dataCorrupted(context) {
            throw StoreError.invalidPreset(context.debugDescription)
        }
        try validate(preset)
        return preset
    }

    private static func data(for preset: UserPreset) throws -> Data {
        try validate(preset)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(preset)
    }

    private static func validate(_ preset: UserPreset) throws {
        guard preset.version == UserPreset.currentVersion else { throw StoreError.invalidPreset("Unsupported preset version \(preset.version).") }
        guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidPreset("A name is required.") }
        guard !preset.includedParts.isEmpty, preset.includedParts.isSubset(of: .all) else { throw StoreError.invalidPreset("Invalid included parts.") }
        if let color = preset.canisterColor, color.count != 3 || !color.allSatisfy({ (0...1).contains($0) }) {
            throw StoreError.invalidPreset("The tag color must contain three RGB values from 0 to 1.")
        }
        if let halation = preset.halation, !OutputSettings.halationRange.contains(halation) {
            throw StoreError.invalidPreset("Halation is out of range.")
        }
    }
}
