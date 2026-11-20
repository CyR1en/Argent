import ArgentRoll
import Foundation

/// What the Rolls page and the roll's notices say, read from the model's own state: a drop or a read
/// under way, why the last open gave no roll, and the raws the open roll left out. Nothing here reads
/// a file; the library is `RollModel+Library`'s.
extension RollModel {
    /// What the Rolls page answers: a drop about to land, a roll being read, or the page at rest. The
    /// backdrop answers it too (`OpenRollBackdrop`).
    enum OpenRollHero: Equatable {
        case dropTargeted, reading, ready
    }

    /// A drop over the window outranks a read under way, which outranks the page at rest: the
    /// page always answers what the pointer is doing first.
    var openRollHero: OpenRollHero {
        if isDropTargeted { return .dropTargeted }
        if isScanning { return .reading }
        return .ready
    }

    /// The line under a message on the page, when no roll is open: every message then is about a
    /// folder, a card or files that gave no roll, and the page's own button and drop are the way on.
    var openRollMessageHint: String? {
        guard message != nil, roll == nil else { return nil }
        return "Choose another folder, or drop one here."
    }

    // MARK: Notices over the roll

    /// A message over the open roll, such as a roll that could not be opened while this one is.
    var rollNoticeMessage: String? {
        roll == nil ? nil : message
    }

    /// "2 raw files could not be read", while the open roll left raws out and their notice has not
    /// been closed for that same list of files. Unlike the old issues bar it leaves the last
    /// develop's failures to the develop's own dock.
    var unreadableNotice: String? {
        guard let unreadable = roll?.unreadable, !unreadable.isEmpty, unreadable != dismissedUnreadable else { return nil }
        return unreadable.count == 1 ? "1 raw file could not be read" : "\(unreadable.count) raw files could not be read"
    }

    /// Closes the notice for the raws left out now; it shows again if the list changes, as when
    /// another roll opens, but not when this one is read again unchanged.
    func dismissUnreadableNotice() {
        dismissedUnreadable = roll?.unreadable
    }

    /// Opening a card where it is (File > Open Card) stops a develop, so it waits for one.
    var canOpenOfferedCard: Bool { offeredCard != nil && !isDeveloping }

    static func framesText(_ count: Int) -> String {
        count == 1 ? "1 frame" : "\(count) frames"
    }

    /// The same in a menu's title: "3 Frames".
    static func framesTitle(_ count: Int) -> String {
        count == 1 ? "1 Frame" : "\(count) Frames"
    }
}

#if DEBUG
extension RollModel {
    /// The states `ARGENT_DEBUG_OPEN_ROLL` asks for and not yet applied.
    private static var pendingOpenRollDebug: Set<String>? = ProcessInfo.processInfo.environment["ARGENT_DEBUG_OPEN_ROLL"]
        .map { Set($0.split(separator: ",").map(String.init)) }

    /// Debug builds only: `ARGENT_DEBUG_OPEN_ROLL=card,drop,read,page` offers a made-up card ("Card
    /// Untitled, 214 frames"), holds the window as if a drop were over it, holds it as if a roll were
    /// being read, and once a roll is open shows the Rolls page over it, so screenshots can show
    /// the states that need a camera card, a drag from Finder, a slow card or a click in the rail,
    /// which the drive hook cannot give. Each once.
    func applyOpenRollDebugStates() {
        guard var pending = Self.pendingOpenRollDebug, !pending.isEmpty else { return }
        if pending.remove("card") != nil {
            cards.append(Card(volume: URL(fileURLWithPath: "/Volumes/UNTITLED", isDirectory: true), name: "Untitled", rawCount: 214))
        }
        if pending.remove("drop") != nil { isDropTargeted = true }
        if pending.remove("read") != nil { holdReadingForDebug() }
        if roll != nil, pending.remove("page") != nil { showWorkspacePage(.rolls) }
        Self.pendingOpenRollDebug = pending
    }
}
#endif
