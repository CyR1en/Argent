import ArgentCore
import Foundation

extension UserStockStore {
    public enum ArchiveError: LocalizedError {
        case invalidPackage
        case tooLarge
        case zipFailed

        public var errorDescription: String? {
            switch self {
            case .invalidPackage: "The package must contain one stock.json and its stock files in a single folder."
            case .tooLarge: "The stock package is too large."
            case .zipFailed: "The stock ZIP could not be read or written."
            }
        }
    }

    /// A ZIP with a stock at its root (or in one enclosing folder), or an unpacked stock folder.
    public func importStock(from source: URL, excluding reservedIDs: Set<String> = []) throws -> Stock {
        try Self.withStaging { staging in
            let contents = staging.appendingPathComponent("stock", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: contents, withIntermediateDirectories: false)
            let resource = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if resource.isDirectory == true {
                try Self.stageFolder(source, in: contents)
            } else {
                guard resource.isRegularFile == true else { throw ArchiveError.invalidPackage }
                guard let size = resource.fileSize, size <= Self.packageLimit else { throw ArchiveError.tooLarge }
                let zip = staging.appendingPathComponent("stock.zip")
                try fm.copyItem(at: source, to: zip)
                try Self.unpack(zip, into: contents)
            }

            let specURL = contents.appendingPathComponent(Stock.specFileName)
            let spec = fm.fileExists(atPath: specURL.path) ? try Data(contentsOf: specURL) : nil
            let loaded = try Stock.load(from: contents, origin: spec == nil ? .userImported : .userBuilt)
            guard RollControls.RatedAt.allCases.allSatisfy({ rating in
                let iso = (loaded.boxSpeed * exp2(-Float(rating.stops))).rounded()
                return Int(exactly: iso).map { $0 > 0 } == true
            }) else { throw StockError.badValue("boxSpeed is outside the supported range for Rated At") }
            let directories = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            let usedIDs = Set((directories + Array(reservedIDs) + loadAll().stocks.map(\.id)).map { $0.lowercased() })
            let id = Self.isValidUserStockID(loaded.id) && loaded.id.utf8.count <= 240 && !usedIDs.contains(loaded.id.lowercased())
                ? loaded.id : Self.makeID(from: String(loaded.displayName.prefix(100)), existingIDs: usedIDs)
            let stock = Stock(id: id, displayName: loaded.displayName, modelledFilm: loaded.modelledFilm,
                              status: loaded.status, boxSpeed: loaded.boxSpeed, densityRange: loaded.densityRange,
                              exposurePerUnit: loaded.exposurePerUnit, negative: loaded.negative, print: loaded.print,
                              grain: loaded.grain, halation: loaded.halation, modelledPrint: loaded.modelledPrint,
                              origin: loaded.origin, canisterColor: loaded.canisterColor, characterLine: loaded.characterLine,
                              hasSpec: loaded.hasSpec, monochromeGrain: loaded.monochromeGrain,
                              scenePresence: loaded.scenePresence, scenePresenceReference: loaded.scenePresenceReference)
            let installed = try install(stock, specData: spec)
            return try Stock.load(from: installed, origin: stock.origin)
        }
    }

    /// Exports a portable ZIP, keeping any builder spec alongside the compiled stock.
    public func exportStock(id: String, to destination: URL) throws {
        let source = try stockDirectory(for: id)
        guard FileManager.default.fileExists(atPath: source.path) else { throw UserStockStoreError.notFound(id) }
        let stock = try Stock.load(from: source)
        let spec = specData(for: id)
        try Self.withStaging { staging in
            let contents = staging.appendingPathComponent("stock", isDirectory: true)
            try stock.write(to: contents)
            var entries = [Stock.manifestName, "negative.lut3d", "print.lut3d"]
            if let spec {
                try spec.write(to: contents.appendingPathComponent(Stock.specFileName))
                entries.append(Stock.specFileName)
            }
            let zip = staging.appendingPathComponent("stock.zip")
            _ = try Self.runZipTool("zip", ["-q", "-X", zip.path] + entries, workingDirectory: contents, limit: 4096)
            try Data(contentsOf: zip).write(to: destination, options: .atomic)
        }
    }

    private static let packageLimit = 256 << 20
    private static let fileLimit = 128 << 20

    private static func isStockFile(_ name: String) -> Bool {
        name == Stock.manifestName || name == Stock.specFileName
            || name.lowercased().hasSuffix(".lut3d") || name.lowercased().hasSuffix(".cube")
    }

    private static func withStaging<T>(_ action: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("argent-stock-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        return try action(staging)
    }

    private static func stageFolder(_ folder: URL, in contents: URL) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        var remaining = packageLimit
        for file in files where isStockFile(file.lastPathComponent) {
            let resource = try file.resourceValues(forKeys: keys)
            guard resource.isRegularFile == true, resource.isSymbolicLink != true else { throw ArchiveError.invalidPackage }
            guard let size = resource.fileSize, size <= min(fileLimit, remaining) else { throw ArchiveError.tooLarge }
            remaining -= size
            try FileManager.default.copyItem(at: file, to: contents.appendingPathComponent(file.lastPathComponent))
        }
    }

    private static func unpack(_ zip: URL, into contents: URL) throws {
        let listing = try runZipTool("unzip", ["-Z1", zip.path], limit: 64 << 10)
        guard let text = String(data: listing, encoding: .utf8) else { throw ArchiveError.invalidPackage }
        let entries = text.split(separator: "\n").map(String.init).filter {
            !$0.hasPrefix("__MACOSX/") && !$0.hasSuffix("/")
        }
        let manifests = entries.filter { $0.split(separator: "/").last == Substring(Stock.manifestName) }
        guard manifests.count == 1, let manifest = manifests.first else { throw ArchiveError.invalidPackage }
        let prefix = String(manifest.dropLast(Stock.manifestName.count))
        guard prefix.isEmpty || prefix.dropLast().contains("/") == false else { throw ArchiveError.invalidPackage }

        // Stream named members only; the ZIP never controls a filesystem extraction path.
        var names = Set<String>()
        var remaining = packageLimit
        for path in entries where path.hasPrefix(prefix) {
            let name = String(path.dropFirst(prefix.count))
            guard !name.contains("/"), isStockFile(name) else { continue }
            guard names.insert(name.lowercased()).inserted, path.split(separator: "/").allSatisfy({ part in
                !part.hasPrefix("-") && part != "." && part != ".."
                    && part.rangeOfCharacter(from: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "*?[]\\"))) == nil
            }), !path.hasPrefix("/") else { throw ArchiveError.invalidPackage }
            let data = try runZipTool("unzip", ["-p", zip.path, path], limit: min(fileLimit, remaining))
            remaining -= data.count
            try data.write(to: contents.appendingPathComponent(name))
        }
    }

    private static func runZipTool(_ tool: String, _ arguments: [String], workingDirectory: URL? = nil,
                                   limit: Int) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment.filter {
            !["ZIP", "ZIPOPT", "UNZIP", "UNZIPOPT", "ZIPINFO", "ZIPINFOOPT"].contains($0.key)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading
        var data = Data()
        do {
            while let chunk = try output.read(upToCount: 64 << 10), !chunk.isEmpty {
                guard chunk.count <= limit - data.count else { throw ArchiveError.tooLarge }
                data.append(chunk)
            }
        } catch {
            try? output.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ArchiveError.zipFailed }
        return data
    }
}
