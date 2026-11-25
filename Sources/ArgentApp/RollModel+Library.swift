import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import os

/// A removable drive the Import roll sheet offers: a disk without a camera card's DCIM folder, whose folder of raws is
/// chosen in the open panel.
struct ImportDrive: Identifiable, Equatable {
    let volume: URL
    let name: String

    var id: URL { volume }
}

/// What the last import came to, on the Rolls page: where its frames went, how many, how many were left at the
/// source, and the source's volume when it can be ejected.
struct ImportNotice: Equatable {
    let roll: UUID?
    let folder: URL
    let copied: Int
    let left: Int
    let source: String
    let isFolder: Bool
    /// The source's volume, when it is a card or a removable drive: the notice offers to eject it.
    let ejectable: URL?

    /// The ejectable volume's name, as Finder shows it.
    var ejectName: String? {
        ejectable.map { (try? $0.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? $0.lastPathComponent }
    }

    @MainActor var text: String {
        let into = "\(RollModel.framesText(copied)) imported into \(folder.lastPathComponent)"
        guard left > 0 else { return into }
        return into + " · \(left) left \(isFolder ? "in the folder" : "on the card")"
    }
}

/// The Rolls page's library (docs/M2-shell.md, section 23): every folder Argent imported into or was given as a roll,
/// kept as `BookmarkStore` keeps it, with a few of each roll's frames as its covers. A roll opened by any way, the
/// page, a drop, Command-O or File > Open Recent, joins it, except a card opened where it is, which comes and goes.
/// Removing a roll forgets it; its folder and files stay where they are.
extension RollModel {
    private static let libraryLog = Logger(subsystem: "camera.argent.Argent", category: "library")

    /// The library's rolls, newest first by their date (the first frame's, or when they were added), named as
    /// `filter` asks, case and diacritics aside; all of them for an empty filter.
    func libraryRolls(matching filter: String = "", oldestFirst: Bool = false) -> [BookmarkStore.LibraryRoll] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let matched = needle.isEmpty ? library
            : library.filter { $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        // Rolls of one date, as a card imported twice in a day, list the one added last first.
        return matched.sorted { $0.date == $1.date ? $0.added > $1.added : oldestFirst ? $0.date < $1.date : $0.date > $1.date }
    }

    /// The library roll open now, if the roll open now is one.
    var openLibraryRoll: BookmarkStore.LibraryRoll? {
        guard let path = roll?.folder.canonicalPath else { return nil }
        return library.first { $0.path == path }
    }

    /// Frames across the library, as each roll last counted them.
    var libraryFrameCount: Int { library.reduce(0) { $0 + ($1.frameCount ?? 0) } }

    // MARK: Opening

    /// A click on a roll of the page: back to it when it is the roll open now, otherwise it opens. One that cannot be
    /// reached says so, and the page marks it.
    func openLibraryRoll(id: UUID) {
        guard let entry = bookmarks.roll(id: id) else { return }
        if entry.path == roll?.folder.canonicalPath {
            showRoll()
            return
        }
        guard let folder = bookmarks.resolve(entry) else {
            message = Self.unavailableText(entry)
            unavailableRolls.insert(id)
            return
        }
        unavailableRolls.remove(id)
        library = bookmarks.rolls
        Task { await open(folder) }
    }

    /// "Titos is on “T7 Shield”, which is not connected", or "Titos is not available".
    static func unavailableText(_ roll: BookmarkStore.LibraryRoll) -> String {
        if let volume = roll.volume { return "\(roll.name) is on \u{201C}\(volume)\u{201D}, which is not connected" }
        return "\(roll.name) is not available"
    }

    /// Whether a roll in `folder` belongs in the library: not a card opened where it is, a whole removable volume that
    /// comes and goes.
    static func joinsLibrary(_ folder: URL) -> Bool {
        let isVolume = (try? folder.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
        return !(isVolume && CardScanner.isCardLike(folder)) && !BookmarkStore.isVolumeRoot(folder.canonicalPath)
    }

    /// Called once a roll has opened, while the app can still reach its folder: it joins the library, or is found
    /// there, with when it was opened, how many frames it has and its first frame's time; and it gets covers if it has
    /// none yet.
    func noteInLibrary(_ roll: Roll) {
        guard Self.joinsLibrary(roll.folder) else { return }
        guard let entry = bookmarks.addRoll(roll.folder, origin: .inPlace) else {
            Self.libraryLog.error("no bookmark for roll \(roll.folder.path, privacy: .public)")
            return
        }
        let first = roll.frames.compactMap(\.info.captureDate).min()
        bookmarks.updateRoll(id: entry.id) {
            $0.opened = Date()
            $0.frameCount = roll.frames.count
            $0.firstCapture = first ?? $0.firstCapture
        }
        unavailableRolls.remove(entry.id)
        library = bookmarks.rolls
        guard rollCovers[entry.id]?.isEmpty ?? true, !coverReads.contains(entry.id) else { return }
        // Covers kept before are shown as they are; a roll without any has them read from its frames' previews.
        let id = entry.id, store = coverStore
        coverReads.insert(id)
        let generation = store.beginRead(for: id)
        let picked = RollCoverStore.spread(roll.frames.count, RollCoverStore.count).map { roll.frames[$0] }
        Task {
            let kept = await Task.detached(priority: .utility) { store.covers(for: id) }.value
            guard store.isCurrent(generation, for: id) else { return }
            coverReads.remove(id)
            guard kept.isEmpty else {
                rollCovers[id] = kept
                return
            }
            readCovers(for: id) {
                picked.compactMap { frame in
                    frame.info.preview.flatMap {
                        try? EmbeddedJPEG.image(at: $0, in: frame.url, maxPixelSize: RollCoverStore.pixelSize, orientation: frame.info.orientation)
                    }
                }
            }
        }
    }

    // MARK: Availability

    func refreshLibraryAvailability() {
        libraryAvailabilityTask?.cancel()
        let entries = library
        guard !entries.isEmpty else { return }
        libraryAvailabilityTask = Task { [weak self, bookmarks] in
            let unavailable = await bookmarks.unavailableRolls(in: entries)
            guard !Task.isCancelled, let self else { return }
            let checked = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.bookmark) })
            let current = Set(library.filter { checked[$0.id] == $0.bookmark }.map(\.id))
            let recovered = unavailableRolls.intersection(current).subtracting(unavailable)
            let updated = unavailableRolls.subtracting(current).union(unavailable.intersection(current))
            if updated != unavailableRolls { unavailableRolls = updated }
            if let message, library.contains(where: { recovered.contains($0.id) && Self.unavailableText($0) == message }) {
                self.message = nil
            }
            for id in recovered where rollCovers[id]?.isEmpty == true { rollCovers[id] = nil }
            if !recovered.isEmpty { loadLibraryCovers() }
        }
    }

    // MARK: Covers

    /// The page shows the library: each roll's covers are read from the cover store, and a roll with none kept, as one
    /// carried over from the recents, has them read from its folder if it can be reached.
    @discardableResult
    func loadLibraryCovers(oldestFirst: Bool = false) -> Task<Void, Never> {
        let store = coverStore
        let entries = libraryRolls(oldestFirst: oldestFirst).filter { rollCovers[$0.id] == nil && !coverReads.contains($0.id) }
        let reads = entries.map { entry in
            coverReads.insert(entry.id)
            let id = entry.id, generation = store.beginRead(for: entry.id)
            let read = Task {
                let kept = await Task.detached(priority: .utility) { store.covers(for: id) }.value
                guard store.isCurrent(generation, for: id) else { return false }
                coverReads.remove(id)
                if !kept.isEmpty || rollCovers[id] == nil { rollCovers[id] = kept }
                return kept.isEmpty
            }
            return (id, generation, read)
        }
        let load = Task {
            var scans: [Task<Void, Never>] = []
            for (id, generation, cacheRead) in reads {
                let needsScan = await cacheRead.value
                guard store.isCurrent(generation, for: id) else { continue }
                if needsScan, !unavailableRolls.contains(id), let scan = readFolderCovers(id) {
                    scans.append(scan)
                }
            }
            return scans
        }
        libraryCoverPreparation = load
        return Task { for scan in await load.value { await scan.value } }
    }

    /// Reads the covers of the roll `id` from its folder, through its bookmark, with its frame count and first frame's
    /// time.
    private func readFolderCovers(_ id: UUID) -> Task<Void, Never>? {
        guard let entry = bookmarks.roll(id: id), !coverReads.contains(id),
              let folder = bookmarks.resolve(entry) else { return nil }
        coverReads.insert(id)
        let store = coverStore
        let generation = store.beginRead(for: id), reader = libraryCoverReader
        let scan = queueCoverScan {
            guard store.isCurrent(generation, for: id) else { return nil }
            return await Task.detached(priority: .utility) { () -> RollCoverStore.Read? in
                let accessing = folder.startAccessingSecurityScopedResource()
                defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
                guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
                guard store.isCurrent(generation, for: id) else { return nil }
                return reader(folder)
            }.value
        }
        return Task {
            let read = await scan.value
            if let read, !read.covers.isEmpty {
                await Task.detached(priority: .utility) { store.keep(read.covers, for: id, generation: generation) }.value
            }
            guard store.isCurrent(generation, for: id) else { return }
            coverReads.remove(id)
            guard let read else { return }
            rollCovers[id] = read.covers
            bookmarks.updateRoll(id: id) {
                $0.frameCount = read.frameCount
                $0.firstCapture = $0.firstCapture ?? read.firstCapture
            }
            library = bookmarks.rolls
        }
    }

    /// Six header/preview walks overlap I/O without scaling with the library; persistence does not hold a scan slot.
    static let coverScanLimit = 6

    @discardableResult
    private func queueCoverScan(_ operation: @escaping @MainActor () async -> RollCoverStore.Read?) -> Task<RollCoverStore.Read?, Never> {
        let (finished, signal) = AsyncStream<RollCoverStore.Read?>.makeStream()
        pendingCoverScans.append {
            Task {
                let read = await operation()
                self.activeCoverScans -= 1
                signal.yield(read)
                signal.finish()
                self.startCoverScans()
            }
        }
        startCoverScans()
        return Task {
            for await read in finished { return read }
            return nil
        }
    }

    private func startCoverScans() {
        while activeCoverScans < Self.coverScanLimit, !pendingCoverScans.isEmpty {
            activeCoverScans += 1
            pendingCoverScans.removeFirst()()
        }
    }

    /// Reads covers with `make` away from the main actor, keeps them and shows them.
    @discardableResult
    func readCovers(for id: UUID, _ make: @escaping @Sendable () -> [CGImage]) -> Task<Void, Never>? {
        guard !coverReads.contains(id) else { return nil }
        coverReads.insert(id)
        let store = coverStore
        let generation = store.beginRead(for: id)
        return Task {
            let covers = await Task.detached(priority: .utility) {
                let covers = make()
                if !covers.isEmpty { store.keep(covers, for: id, generation: generation) }
                return covers
            }.value
            guard store.isCurrent(generation, for: id) else { return }
            coverReads.remove(id)
            rollCovers[id] = covers
        }
    }

    // MARK: Changing the library

    /// Rename… on a roll's menu: the name the page shows. The folder keeps its own; an empty name changes nothing.
    func renameLibraryRoll(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingRoll = nil
        guard !trimmed.isEmpty else { return }
        bookmarks.updateRoll(id: id) { $0.name = trimmed }
        library = bookmarks.rolls
        if openLibraryRoll?.id == id {
            let suggested = developRollName
            if chosenDevelopFolder != nil { developFolder.rollName = suggested }
            quickDevelop?.folder.rollName = suggested
        }
    }

    /// Remove from Rolls: Argent forgets the roll, here and in File > Open Recent. Its folder and files stay where they
    /// are, and it comes back when the folder is opened or imported into again. The roll open now stays open.
    func removeLibraryRoll(id: UUID) {
        guard let entry = bookmarks.roll(id: id) else { return }
        bookmarks.removeRoll(id: id)
        bookmarks.removeRecent(path: entry.path)
        invalidateLibraryCovers(id)
        unavailableRolls.remove(id)
        library = bookmarks.rolls
        recents = bookmarks.recents
        if importNotice?.roll == id { importNotice = nil }
    }

    func invalidateLibraryCovers(_ id: UUID) {
        coverStore.remove(id)
        coverReads.remove(id)
        rollCovers[id] = nil
    }

    /// Show in Finder on a roll's menu: its folder, selected in its parent, through its bookmark's access.
    func showLibraryRollInFinder(id: UUID) {
        guard let entry = bookmarks.roll(id: id) else { return }
        guard let folder = bookmarks.resolve(entry) else {
            message = Self.unavailableText(entry)
            unavailableRolls.insert(id)
            return
        }
        library = bookmarks.rolls
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            message = Self.unavailableText(entry)
            unavailableRolls.insert(id)
            return
        }
        unavailableRolls.remove(id)
        FinderReveal.show([folder])
    }

    // MARK: Import roll

    /// How far an import's copy is, for the rail's Rolls away from its page; `nil` with none under way.
    var importFraction: Double? {
        guard case .copying(_, _, let done, let total) = importSession, total > 0 else { return nil }
        return Double(done) / Double(total)
    }

    /// File > Import Roll… and the page's Import roll: the sheet that chooses a card, a drive or a folder, over the
    /// Rolls page. An import under way, a develop, or onboarding waits.
    func showImportSource() {
        guard canShowImportSource, !onboarding.isPresented else { return }
        showWorkspacePage(.rolls)
        refreshDrives()
        isImportSourceShown = true
    }

    /// An import waits for a develop, and for the import under way.
    var canShowImportSource: Bool { !isDeveloping && importSession == .idle }

    var importSourceHelp: String {
        if isDeveloping { return "Import a roll when the develop is done" }
        if importSession != .idle { return "Import another roll when this import is done" }
        return "Copy a card's or a folder's frames into a new roll. Command-I."
    }

    /// The removable drives mounted now that hold no camera card's DCIM folder: a card is offered as one.
    func refreshDrives() {
        let cards = Set(cards.map { $0.volume.canonicalPath })
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        drives = volumes.filter { CardScanner.isCardLike($0) && !cards.contains($0.canonicalPath) && CardScanner.card(on: $0) == nil }.map { volume in
            ImportDrive(volume: volume, name: (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
                            ?? volume.lastPathComponent)
        }
    }

    /// Import from a folder…, or a drive's row: the open panel, at `directory` if given; the folder chosen is read
    /// and its frames reviewed, then copied into a new roll.
    func chooseImportFolder(at directory: URL? = nil) {
        isImportSourceShown = false
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a folder of ARW files to import as a roll"
        panel.directoryURL = directory
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            MainActor.assumeIsolated { self.startImport(folder: folder) }
        }
    }

    /// Add an existing folder…: the open panel (Command-O); the folder chosen opens as a roll where it is and joins
    /// the library.
    func chooseExistingFolder() {
        isImportSourceShown = false
        isImporting = true
    }

    /// The notice's Open roll: the roll imported, or, when it is the roll open now, that roll read again with the frames
    /// just copied into it. Reading it again stops a develop, so it waits for one.
    func openImportedRoll() {
        guard let id = importNotice?.roll, let entry = bookmarks.roll(id: id) else { return }
        guard entry.path == roll?.folder.canonicalPath else {
            importNotice = nil
            openLibraryRoll(id: id)
            return
        }
        guard !isDeveloping else { return }
        importNotice = nil
        guard let folder = bookmarks.resolve(entry) else {
            message = Self.unavailableText(entry)
            unavailableRolls.insert(id)
            return
        }
        Task { await open(folder) }
    }

    /// The notice is about the roll open now, whose Open roll reads it again.
    var importNoticeIsOpenRoll: Bool { importNotice?.roll != nil && importNotice?.roll == openLibraryRoll?.id }

    /// The notice's Eject: the source's volume is unmounted and ejected; nothing on it is changed. A volume that will
    /// not eject says why.
    func ejectImportSource() {
        guard let volume = importNotice?.ejectable else { return }
        let name = importNotice?.ejectName ?? volume.lastPathComponent
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                message = "Could not eject \(name): \(failure)"
            } else if importNotice?.ejectable == volume {
                importNotice = nil
            }
        }
    }

    /// The volume `url` is on, when it is a card or a removable drive Argent may offer to eject.
    static func ejectableVolume(of url: URL) -> URL? {
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume, CardScanner.isCardLike(volume) else { return nil }
        return volume
    }
}
