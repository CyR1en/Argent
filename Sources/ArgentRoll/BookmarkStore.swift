import Foundation

/// The rolls opened lately, the rolls of the library and the folders rolls develop to, kept as
/// security-scoped bookmarks so the sandbox lets the app back into them after a relaunch: File > Open
/// Recent, the Rolls page, and a destination outside ~/Argent and ~/Pictures confirmed once per roll staying confirmed.
///
/// A small JSON file under Application Support. The spec put recents and caches in SQLite;
/// recents are ten entries and destinations one per folder, read once at launch and written
/// whole on change, and the preview cache is files whose names are their keys, so nothing
/// here needs a query or a migration (docs/M2-shell.md, section 6).
public final class BookmarkStore {
    /// One roll in File > Open Recent.
    public struct Recent: Sendable, Equatable, Codable, Identifiable {
        /// Where the roll was when it was last opened; also its identity in the list.
        public var path: String
        /// The folder's name, or the card's.
        public var name: String
        public var bookmark: Data
        public var opened: Date

        public var id: String { path }
    }

    /// One roll of the library, the Rolls page's: a folder Argent imported a card or a folder into, or one
    /// added where it is. Removing it from the library forgets it and leaves its folder as it is.
    public struct LibraryRoll: Sendable, Equatable, Codable, Identifiable {
        /// How the roll came into the library.
        public enum Origin: String, Sendable, Codable {
            /// Its frames were copied into its folder by Import.
            case imported
            /// Its folder was added as it is, nothing copied.
            case inPlace
        }

        /// Stable across renames and moves; the roll's covers are kept under it.
        public var id: UUID
        /// Where the folder was when last reached.
        public var path: String
        /// The name the page shows, the folder's unless renamed.
        public var name: String
        public var bookmark: Data
        public var origin: Origin
        /// The card or folder Import copied the frames from.
        public var source: String?
        /// The volume the folder is on, when it is not the startup disk, so a roll out of reach can say where it is.
        public var volume: String?
        public var added: Date
        public var opened: Date?
        /// The first frame's capture time, the roll's date; `nil` until the roll's raws are read.
        public var firstCapture: Date?
        /// The raws the roll held when last read.
        public var frameCount: Int?

        /// The roll's date on the page: its first frame's, or when it was added.
        public var date: Date { firstCapture ?? added }
    }

    private struct Contents: Codable {
        var version = 1
        var recents: [Recent] = []
        /// Destination folders, least recently remembered first.
        var destinations: [Destination] = []
        /// The library, in the order the rolls were added; `nil` in a file written before it, whose recents
        /// then become its first rolls.
        var rolls: [LibraryRoll]?
    }

    private struct Destination: Codable {
        /// The folder's path, as a recipe records it.
        var path: String
        /// The current path can also be requested by Import after the folder moves.
        var resolvedPath: String?
        var bookmark: Data
        /// Whether each roll used its subfolder option when it last developed here.
        var usesSubfolderByRoll: [String: Bool]?
    }

    /// The most File > Open Recent shows, as AppKit's default does.
    public static let keptRecents = 10
    /// Destinations kept; the oldest go first. Far more than anyone develops to.
    public static let keptDestinations = 200

    public let file: URL
    private let creation: URL.BookmarkCreationOptions
    private let resolution: URL.BookmarkResolutionOptions
    private var contents: Contents

    /// `securityScoped` is false only for tests run outside the sandbox.
    public init(file: URL = BookmarkStore.defaultFile, securityScoped: Bool = true) {
        self.file = file
        creation = securityScoped ? [.withSecurityScope] : []
        resolution = securityScoped ? [.withSecurityScope] : []
        let decoded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) }
        contents = decoded ?? Contents()
        if contents.rolls == nil {
            // The rolls opened before the library are its first rolls, added where they are.
            // A card opened as a roll is a whole volume, which comes and goes: it is not kept as a roll.
            contents.rolls = contents.recents.reversed().filter { !Self.isVolumeRoot($0.path) }.map { recent in
                LibraryRoll(id: UUID(), path: recent.path, name: recent.name, bookmark: recent.bookmark, origin: .inPlace,
                            source: nil, volume: Self.volumeName(ofPath: recent.path), added: recent.opened, opened: recent.opened,
                            firstCapture: nil, frameCount: nil)
            }
            if decoded != nil { save() }
        }
        // Older subfolder choices used the roll's path. Its library ID follows it when Finder moves it.
        for index in contents.destinations.indices {
            guard var choices = contents.destinations[index].usesSubfolderByRoll else { continue }
            for (path, nested) in choices where path.hasPrefix("/") {
                guard let roll = rolls.first(where: { $0.path == path }) else { continue }
                choices[roll.id.uuidString] = choices[roll.id.uuidString] ?? nested
                choices.removeValue(forKey: path)
            }
            contents.destinations[index].usesSubfolderByRoll = choices
        }
    }

    /// Application Support/Argent/Bookmarks.json, inside the app's container when sandboxed; a test
    /// process may not use it (`ApplicationSupport`).
    public static var defaultFile: URL {
        ApplicationSupport.folder.appendingPathComponent("Bookmarks.json")
    }

    // MARK: Recents

    /// Most recent first.
    public var recents: [Recent] { contents.recents }

    /// Puts `folder` at the top of the recents. Call it while the app can reach the folder,
    /// since a security-scoped bookmark can only be made then. Returns whether it was kept.
    @discardableResult
    public func noteOpened(_ folder: URL, name: String? = nil, at date: Date = Date()) -> Bool {
        guard let bookmark = try? folder.bookmarkData(options: creation, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return false }
        let path = folder.canonicalPath
        contents.recents.removeAll { $0.path == path }
        contents.recents.insert(Recent(path: path, name: name ?? folder.lastPathComponent, bookmark: bookmark, opened: date),
                                at: 0)
        if contents.recents.count > Self.keptRecents { contents.recents.removeLast(contents.recents.count - Self.keptRecents) }
        save()
        return true
    }

    /// The recent roll's folder, or `nil` when it is gone or its volume is not mounted. The
    /// caller starts and stops access to it. A bookmark the system calls stale is made again.
    public func resolve(_ recent: Recent) -> URL? {
        guard let url = resolve(recent.bookmark) else { return nil }
        if url.isStale {
            let accessing = url.url.startAccessingSecurityScopedResource()
            defer { if accessing { url.url.stopAccessingSecurityScopedResource() } }
            if let index = contents.recents.firstIndex(where: { $0.path == recent.path }),
               let fresh = try? url.url.bookmarkData(options: creation, includingResourceValuesForKeys: nil, relativeTo: nil) {
                contents.recents[index].bookmark = fresh
                contents.recents[index].path = url.url.canonicalPath
                save()
            }
        }
        return url.url
    }

    public func clearRecents() {
        contents.recents.removeAll()
        save()
    }

    /// Takes the roll at `path` off the recents, by either spelling of its path, and keeps the others in their order. Its
    /// folder is not touched. Returns whether one was there to take.
    @discardableResult
    public func removeRecent(path: String) -> Bool {
        let key = path.canonicalPath
        let count = contents.recents.count
        contents.recents.removeAll { $0.path == path || $0.path == key }
        guard contents.recents.count != count else { return false }
        save()
        return true
    }

    // MARK: Library

    /// The library's rolls, in the order they were added.
    public var rolls: [LibraryRoll] { contents.rolls ?? [] }

    public func roll(id: UUID) -> LibraryRoll? { rolls.first { $0.id == id } }

    /// The roll whose folder is at `path`, by either spelling of it.
    public func roll(atPath path: String) -> LibraryRoll? {
        let key = path.canonicalPath
        return rolls.first { $0.path == path || $0.path == key }
    }

    /// Adds `folder` to the library, or finds it there already: a roll added again keeps its id, its name and its
    /// covers, takes a fresh bookmark, and becomes `imported` when Import has copied into it. Call it while the app can
    /// reach the folder. Returns the roll, or `nil` when no bookmark could be made.
    @discardableResult
    public func addRoll(_ folder: URL, name: String? = nil, origin: LibraryRoll.Origin, source: String? = nil,
                        at date: Date = Date()) -> LibraryRoll? {
        guard let bookmark = try? folder.bookmarkData(options: creation, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        let path = folder.canonicalPath
        var rolls = contents.rolls ?? []
        // A folder opened directly after a Finder move still belongs to the same library roll.
        if let index = rolls.firstIndex(where: { $0.path == path })
            ?? rolls.firstIndex(where: { resolve($0.bookmark, options: .withoutMounting)?.url.canonicalPath == path }) {
            rolls[index].path = path
            rolls[index].volume = Self.volumeName(ofPath: path)
            rolls[index].bookmark = bookmark
            if origin == .imported {
                rolls[index].origin = .imported
                rolls[index].source = source ?? rolls[index].source
            }
            contents.rolls = rolls
            save()
            return rolls[index]
        }
        let roll = LibraryRoll(id: UUID(), path: path, name: name ?? folder.lastPathComponent, bookmark: bookmark, origin: origin,
                               source: source, volume: Self.volumeName(ofPath: path), added: date, opened: nil,
                               firstCapture: nil, frameCount: nil)
        rolls.append(roll)
        contents.rolls = rolls
        save()
        return roll
    }

    /// Changes the roll `id` as `change` says, and keeps it. Returns the roll as changed, or `nil` when it is not in the
    /// library. Its id stays.
    @discardableResult
    public func updateRoll(id: UUID, _ change: (inout LibraryRoll) -> Void) -> LibraryRoll? {
        guard var rolls = contents.rolls, let index = rolls.firstIndex(where: { $0.id == id }) else { return nil }
        change(&rolls[index])
        rolls[index].id = id
        contents.rolls = rolls
        save()
        return rolls[index]
    }

    /// Forgets the roll `id`; its folder and its files are not touched. Returns whether it was there.
    @discardableResult
    public func removeRoll(id: UUID) -> Bool {
        guard var rolls = contents.rolls, let index = rolls.firstIndex(where: { $0.id == id }) else { return false }
        rolls.remove(at: index)
        contents.rolls = rolls
        save()
        return true
    }

    /// Which saved rolls cannot be reached now, without mounting their volumes or changing their bookmarks.
    public nonisolated(nonsending) func unavailableRolls(in rolls: [LibraryRoll]) async -> Set<UUID> {
        let options = resolution.union([.withoutUI, .withoutMounting])
        let probe = Task.detached(priority: .utility) {
            var unavailable: Set<UUID> = []
            for roll in rolls {
                if Task.isCancelled { break }
                if !Self.canReadFolder(roll.bookmark, options: options) { unavailable.insert(roll.id) }
            }
            return unavailable
        }
        return await withTaskCancellationHandler {
            await probe.value
        } onCancel: {
            probe.cancel()
        }
    }

    private static func canReadFolder(_ bookmark: Data, options: URL.BookmarkResolutionOptions) -> Bool {
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: options,
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        let files = FileManager.default
        return files.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && files.isReadableFile(atPath: folder.path) && files.isExecutableFile(atPath: folder.path)
    }

    /// The roll's folder, or `nil` when it is gone or its volume is not mounted. The caller starts and stops access to
    /// it. A bookmark the system calls stale is made again, and the roll takes the folder's path now.
    public func resolve(_ roll: LibraryRoll) -> URL? {
        guard let url = resolve(roll.bookmark) else { return nil }
        if url.isStale || roll.path != url.url.canonicalPath {
            let accessing = url.url.startAccessingSecurityScopedResource()
            defer { if accessing { url.url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.url.bookmarkData(options: creation, includingResourceValuesForKeys: nil, relativeTo: nil) {
                updateRoll(id: roll.id) {
                    $0.bookmark = fresh
                    $0.path = url.url.canonicalPath
                    $0.volume = Self.volumeName(ofPath: $0.path)
                }
            }
        }
        return url.url
    }

    /// Whether `path` is a mounted volume's root under /Volumes, as a card opened as a roll is.
    public static func isVolumeRoot(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.count == 3 && components[1] == "Volumes"
    }

    /// The name of the volume at `path`'s root when it is not the startup disk: "T7 Shield" for
    /// /Volumes/T7 Shield/Rolls/Titos.
    static func volumeName(ofPath path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return nil }
        return components[2]
    }

    // MARK: Destinations

    /// Keeps a way back into `folder`, a roll's develop destination. Call it while the app
    /// can reach the folder.
    @discardableResult
    public func rememberDestination(_ folder: URL, forRoll roll: URL? = nil, usesSubfolder: Bool = false) -> Bool {
        guard let bookmark = try? folder.bookmarkData(options: creation, includingResourceValuesForKeys: [.fileIdentifierKey], relativeTo: nil)
        else { return false }
        let path = folder.canonicalPath
        var choices = contents.destinations.last { $0.path == path }?.usesSubfolderByRoll ?? [:]
        if let roll { choices[subfolderChoiceKey(for: roll)] = usesSubfolder }
        contents.destinations.removeAll { $0.path == path }
        contents.destinations.append(Destination(path: path, bookmark: bookmark, usesSubfolderByRoll: choices.isEmpty ? nil : choices))
        if contents.destinations.count > Self.keptDestinations {
            contents.destinations.removeFirst(contents.destinations.count - Self.keptDestinations)
        }
        save()
        return true
    }

    public func usedSubfolder(_ folder: URL, forRoll roll: URL) -> Bool? {
        let path = folder.canonicalPath
        return contents.destinations.last { $0.path == path }?.usesSubfolderByRoll?[subfolderChoiceKey(for: roll)]
    }

    private func subfolderChoiceKey(for folder: URL) -> String {
        let path = folder.canonicalPath
        return rolls.first { $0.path == path }?.id.uuidString ?? path
    }

    /// The destination folder last remembered at `path`, resolved; `nil` if there is none or
    /// it cannot be found. The caller starts and stops access to it.
    public func destination(atPath path: String, in parent: URL? = nil) -> URL? {
        let key = path.canonicalPath
        guard let index = contents.destinations.lastIndex(where: { $0.path == key })
                ?? contents.destinations.lastIndex(where: { $0.resolvedPath == key }) else { return nil }
        let kept = contents.destinations[index]
        guard let resolved = resolve(kept.bookmark) else { return nil }
        var folder = resolved.url
        if resolved.isStale {
            let accessingParent = parent?.startAccessingSecurityScopedResource() == true
            defer { if accessingParent { parent?.stopAccessingSecurityScopedResource() } }
            let target = parent.flatMap { renamedChild(in: $0, resolved: resolved.url, bookmark: kept.bookmark) } ?? resolved.url
            let accessing = target.startAccessingSecurityScopedResource()
            defer { if accessing { target.stopAccessingSecurityScopedResource() } }
            folder = target
            if let fresh = try? target.bookmarkData(options: creation, includingResourceValuesForKeys: [.fileIdentifierKey], relativeTo: nil) {
                contents.destinations[index].bookmark = fresh
                // A child found by listing its parent needs its own scoped URL for the caller.
                if target != resolved.url { folder = resolve(fresh)?.url ?? target }
            }
        }
        let current = folder.canonicalPath
        let movedTo = current == kept.path ? nil : current
        if resolved.isStale || kept.resolvedPath != movedTo {
            // The recipe still names the original path on subsequent opens.
            contents.destinations[index].resolvedPath = movedTo
            save()
        }
        return folder
    }

    /// macOS can resolve a stale bookmark to a new directory at the old path. Look for the original in the granted parent.
    private func renamedChild(in parent: URL, resolved: URL, bookmark: Data) -> URL? {
        let keys: Set<URLResourceKey> = [.fileIdentifierKey, .volumeUUIDStringKey]
        guard resolved.deletingLastPathComponent().canonicalPath == parent.canonicalPath,
              let original = URL.resourceValues(forKeys: keys, fromBookmarkData: bookmark),
              let id = original.fileIdentifier, let current = try? resolved.resourceValues(forKeys: keys),
              current.fileIdentifier != id, current.volumeUUIDString == original.volumeUUIDString else { return nil }
        let childKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileIdentifierKey]
        let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(childKeys))
        return children?.first { child in
            let values = try? child.resourceValues(forKeys: childKeys)
            return values?.isDirectory == true && values?.fileIdentifier == id
        }
    }

    // MARK: Storage

    private func resolve(_ bookmark: Data, options: URL.BookmarkResolutionOptions = []) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: resolution.union(.withoutUI).union(options),
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, stale)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(contents).write(to: file, options: .atomic)
        } catch {
            // Recents are a convenience; a failed write costs a relaunch's worth of them.
        }
    }
}
