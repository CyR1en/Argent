import AppKit
import ArgentRoll
import Foundation
import os

/// Shows files in Finder; tests replace it so no test opens a Finder window.
@MainActor enum FinderReveal {
    static var show: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
}

/// Where rolls come from and go: a card offered when it is inserted, File > Open Recent, and
/// the develop destination kept across launches. All three rest on what the sandbox allows;
/// see docs/M2-shell.md, section 6.
extension RollModel {
    private static let placesLog = Logger(subsystem: "camera.argent.Argent", category: "places")

    // MARK: Cards

    /// Offers the cards already mounted, then each one mounted later, and withdraws an offer
    /// when its card is ejected. Reading a card's DCIM folder needs the app's /Volumes
    /// exception; detection alone would not.
    func watchCards() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let mounted = center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.volumeMounted(volume) }
        }
        let unmounted = center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.volumeUnmounted(volume) }
        }
        volumeObservers = [mounted, unmounted]
        refreshLibraryAvailability()
        Task {
            let found = await Task.detached(priority: .utility) { CardScanner.mountedCards() }.value
            for card in found { offer(card, announce: false) }
        }
    }

    private func volumeMounted(_ volume: URL) {
        refreshLibraryAvailability()
        Task {
            let card = await Task.detached(priority: .userInitiated) {
                CardScanner.isCardLike(volume) ? CardScanner.card(on: volume) : nil
            }.value
            if let card { offer(card, announce: true) }
        }
    }

    private func volumeUnmounted(_ volume: URL) {
        refreshLibraryAvailability()
        let path = volume.canonicalPath
        cards.removeAll { $0.volume.canonicalPath == path }
        importCardRemoved(volume)
        // Ejected and inserted again, a card turned down or imported is offered again.
        dismissedCards.remove(path)
        importedCards.remove(path)
    }

    func offer(_ card: Card, announce: Bool) {
        let path = card.volume.canonicalPath
        // The roll open now, or a card turned down, is not offered again until it is reinserted.
        guard roll?.folder.canonicalPath != path, !dismissedCards.contains(path) else { return }
        cards.removeAll { $0.volume.canonicalPath == path }
        cards.append(card)
        Self.placesLog.info("card \(card.name, privacy: .public) offered, \(card.rawCount.map(String.init) ?? "unknown", privacy: .public) raw files")
        if announce {
            // The offer is quiet on screen; VoiceOver users hear it arrive.
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: Self.offerText(card), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    /// "Card Untitled, 214 frames", or "Card Untitled" when its folders could not be counted.
    static func offerText(_ card: Card) -> String {
        guard let count = card.rawCount else { return "Card \(card.name)" }
        return "Card \(card.name), \(count == 1 ? "1 frame" : "\(count) frames")"
    }

    /// The card the offer shows: the newest one not imported since it was inserted.
    var offeredCard: Card? { cards.last { !importedCards.contains($0.volume.canonicalPath) } }

    var latestCard: Card? { cards.last }

    /// macOS may have refused to let the app read a card (docs/research/camera.md, section 4).
    static func mayNotReadText(_ name: String) -> String {
        "Argent may not read \(name): drop it on the window, or allow removable volumes in Privacy & Security"
    }

    func importHelp(_ card: Card) -> String {
        if card.rawCount == nil { return Self.mayNotReadText(card.name) }
        if isDeveloping { return "Import the card when the develop is done" }
        if importSession != .idle { return "Import the card when this import is done" }
        return "Read the card's frames, then choose the ones to import. Shift-Command-I."
    }

    /// A card the app could list opens as a roll; one it could not opens the panel at the card,
    /// where choosing it is the user's own act and needs no consent from macOS.
    func openCard(_ card: Card) {
        cards.removeAll { $0.id == card.id }
        guard card.rawCount != nil else {
            importDirectory = card.volume
            isImporting = true
            return
        }
        Task { await open(card.volume) }
    }

    /// Not now: the offer goes until the card is ejected and inserted again.
    func dismissCard(_ card: Card) {
        cards.removeAll { $0.id == card.id }
        dismissedCards.insert(card.volume.canonicalPath)
    }

    // MARK: Recents

    /// Called once a roll has opened, while the app can still reach its folder: it heads File > Open Recent and joins
    /// the library (`noteInLibrary`).
    func noteRecent(_ roll: Roll) {
        if !bookmarks.noteOpened(roll.folder, name: roll.name) {
            Self.placesLog.error("no bookmark for \(roll.folder.path, privacy: .public)")
        }
        recents = bookmarks.recents
        noteInLibrary(roll)
        let path = roll.folder.canonicalPath
        cards.removeAll { $0.volume.canonicalPath == path }
    }

    func openRecent(path: String) {
        guard let recent = bookmarks.recents.first(where: { $0.path == path }) else { return }
        guard let folder = bookmarks.resolve(recent) else {
            closeImport()
            message = "\(recent.name) is not available"
            return
        }
        recents = bookmarks.recents
        Task { await open(folder) }
    }

    func clearRecents() {
        bookmarks.clearRecents()
        recents = []
    }

    /// Takes a roll off File > Open Recent, which follows `recents` through `MenuState`. Its folder is not touched, and it
    /// comes back when the roll is opened again.
    func removeRecent(path: String) {
        bookmarks.removeRecent(path: path)
        recents = bookmarks.recents
    }

    // MARK: Destinations

    func restoredDevelopFolder(_ folder: URL?, for roll: Roll) -> DevelopFolder? {
        guard let folder else {
            releaseDestination()
            return nil
        }
        let recordedParent = folder.deletingLastPathComponent()
        // Older recipes record only the final path. The former default was already a child of ~/Argent/Developed.
        let nested = bookmarks.usedSubfolder(folder, forRoll: roll.folder) ?? (recordedParent.standardizedFileURL == Self.argentDeveloped)
        let parent = nested ? bookmarks.destination(atPath: recordedParent.path) ?? recordedParent : nil
        let resolved = bookmarks.destination(atPath: folder.path, in: parent)
        if var parent {
            // The child can move independently. Keep the parent's grant when it still covers the child.
            if let currentParent = resolved?.deletingLastPathComponent(), currentParent.canonicalPath != parent.canonicalPath {
                parent = currentParent
            }
            if let base = reachableDestination(parent) {
                return DevelopFolder(base: base, usesSubfolder: true, rollName: developRollName,
                                     customSubfolderName: (resolved ?? folder).lastPathComponent)
            }
        }
        guard let base = reachableDestination(resolved ?? folder) else { return nil }
        return DevelopFolder(base: base, usesSubfolder: false, rollName: developRollName)
    }

    private func reachableDestination(_ folder: URL) -> URL? {
        releaseDestination()
        if folder.startAccessingSecurityScopedResource() { accessedDestination = folder }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            releaseDestination()
            return nil
        }
        return folder
    }

    func releaseDestination() {
        accessedDestination?.stopAccessingSecurityScopedResource()
        accessedDestination = nil
    }

    /// Keeps the way back into a folder the roll has just developed to.
    func rememberDestination(_ folder: URL, forRoll roll: URL? = nil, usesSubfolder: Bool = false) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if !bookmarks.rememberDestination(folder, forRoll: roll, usesSubfolder: usesSubfolder) {
            Self.placesLog.error("no bookmark for destination \(folder.path, privacy: .public)")
        }
    }
}
