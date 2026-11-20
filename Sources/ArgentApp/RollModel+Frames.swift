import AppKit
import ArgentRoll
import Foundation
import os

/// What Remove from Roll asks before it moves frames to the Trash: how many, the one frame's name, and the roll.
struct FrameRemoval: Equatable {
    let count: Int
    /// The frame's name, when it is one.
    let name: String?
    let roll: String

    var title: String {
        if let name, count == 1 { return "Move \(name) to the Trash?" }
        return "Move \(count) frames to the Trash?"
    }

    var detail: String {
        let them = count == 1 ? "Its RAW file leaves" : "Their RAW files leave"
        let adjustments = count == 1 ? "its adjustments" : "their adjustments"
        return "\(them) \u{201C}\(roll)\u{201D} with \(adjustments), and can be put back from the Trash in Finder. Developed files stay where they are."
    }

    /// The alert, over the app; whether Move to Trash was chosen.
    @MainActor static func alert(_ removal: FrameRemoval) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = removal.title
        alert.informativeText = removal.detail
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// A roll Move to Roll offers: one of the library's other than the roll open now.
struct MoveTarget: Equatable, Identifiable {
    let id: UUID
    let name: String
}

/// Frames leaving the roll open now (docs/M2-shell.md, section 25). A roll is a folder, so a frame leaves it when its
/// raw does: **Remove from Roll** moves the raws to the Trash, after asking, and **Move to Roll** moves them into another
/// roll's folder, or into a new roll made in the folder Import makes its rolls in. Each raw goes with its recipe and its
/// masks' seeds beside it (`FrameFiles`), so a frame moved arrives as it was left, its flag with it; developed files stay
/// where they were written. Nothing is written over: a roll that already holds a file of a frame's name keeps it, and
/// that frame stays. The files move away from the main actor; the roll on screen then lets the frames go
/// (`dropFrames`) without being read again, so the sheet keeps its place, its filter and its undo history.
///
/// Offered on the sheet and the Develop page's grid, never on a card opened where it is, which Argent does not change,
/// and not while a develop runs or the roll is opening.
extension RollModel {
    nonisolated private static let framesLog = Logger(subsystem: "camera.argent.Argent", category: "frames")

    /// Whether the open roll's frames may leave it at all: a folder, not a card opened where it is. Asked of the disk
    /// once a roll, since the menu bar reads it at each change of the selection.
    var rollAllowsChangingFrames: Bool { openRollFacts?.allows ?? false }

    private var openRollFacts: (folder: URL, allows: Bool, path: String)? {
        guard let folder = roll?.folder else { return nil }
        if let kept = changeableRoll, kept.folder == folder { return kept }
        let facts = (folder, Self.joinsLibrary(folder), folder.canonicalPath)
        changeableRoll = facts
        return facts
    }

    /// Whether `frames` can leave the roll now, to the Trash or to another roll: on the sheet, with no develop, open or
    /// move under way. While they go nothing else changes a frame either: no frame opens, no flag, paste or reset is
    /// taken and no develop starts, since a change to a frame whose files are on their way would be lost.
    func canChangeFrames(_ frames: [Frame]) -> Bool {
        guard !frames.isEmpty, !isFrameOpen, !isScanning, !isQuitting, !isDeveloping, !isRestoringManual, frameMove == nil else { return false }
        return rollAllowsChangingFrames
    }

    /// Why Move to Roll and Remove from Roll are off, for their help tags; `nil` while they are on.
    var changeFramesHelp: String? {
        if roll != nil, !rollAllowsChangingFrames { return "Argent never changes a card: import its frames into a roll first" }
        if isDeveloping { return "Frames can leave the roll when the develop is done" }
        if frameMove != nil { return "Frames are being moved" }
        return nil
    }

    /// The rolls Move to Roll offers: the library's, newest first as the Rolls page lists them, without the roll open now.
    var moveTargets: [MoveTarget] {
        let open = openRollFacts?.path
        return libraryRolls().filter { $0.path != open }.map { MoveTarget(id: $0.id, name: $0.name) }
    }

    // MARK: Remove from Roll

    /// Frame > Remove from Roll… on the frames selected. Its key, Command-Delete, pressed while a text field has the
    /// keys, the Develop page's Quality or a new roll's name, is the field's: the menu bar takes a key before the
    /// field does, so it is handed on, and no frame goes to the Trash for a line being cleared.
    func removeSelection(_ event: NSEvent?) {
        if let event, event.type == .keyDown, FrameKeys.givesRemoveToText(NSApp?.keyWindow?.firstResponder) { return }
        removeFromRoll(selectedFrames)
    }

    /// Remove from Roll: asks, then moves the frames' raws to the Trash with their recipes.
    func removeFromRoll(_ frames: [Frame]) {
        guard canChangeFrames(frames), let roll else { return }
        let removal = FrameRemoval(count: frames.count, name: frames.count == 1 ? frames[0].name : nil, roll: roll.name)
        guard askAboutRemovingFrames(removal) else { return }
        let trash = trashFrames
        relocate(frames, saying: "Moving \(Self.framesText(frames.count)) to the Trash…", scope: nil) { urls in
            FrameMoveResult(outcomes: trash(urls))
        } finished: { [weak self] moved, result in
            self?.framesLeft(moved, of: frames, from: roll.folder, result: result, to: "the Trash", symbol: "trash")
        }
    }

    // MARK: Move to Roll

    /// Move to Roll > a roll: the frames' raws into that roll's folder, with their recipes and their flags.
    func moveFrames(_ frames: [Frame], toRoll id: UUID) {
        guard canChangeFrames(frames), let roll, let entry = bookmarks.roll(id: id), entry.path != roll.folder.canonicalPath else { return }
        guard let folder = bookmarks.resolve(entry) else {
            message = Self.unavailableText(entry)
            unavailableRolls.insert(id)
            return
        }
        library = bookmarks.rolls
        move(frames, into: folder, scope: folder, named: entry.name, makingFolder: false) { [weak self] in
            self?.noteFramesArrived(in: id)
            return id
        }
    }

    /// Move to Roll > New Roll…: asks for the roll's name, then moves the frames into a new roll of that name.
    func moveFramesToNewRoll(_ frames: [Frame]) {
        guard canChangeFrames(frames) else { return }
        guard let name = askForNewRollName(Self.newRollName(for: frames)) else { return }
        moveFrames(frames, toNewRollNamed: name)
    }

    /// The name a new roll of `frames` starts with: their first frame's day on the camera's clock, as an import's does.
    static func newRollName(for frames: [Frame]) -> String {
        ImportReview.defaultName(firstCapture: frames.compactMap(\.info.captureDate).min())
    }

    /// The frames into a new roll called `name`, its folder made in the folder Import makes its rolls in
    /// (`importParent`). A name already a folder there is refused, as an import's is not: a move never joins a folder
    /// Argent does not know to be a roll. Asked here for a line that says so at once, with the chosen folder's access
    /// held, without which a folder there reads as absent; and asked again as the folder is made (`move`), which makes
    /// it only if it is not there, so a folder that was there is never joined nor removed.
    func moveFrames(_ frames: [Frame], toNewRollNamed name: String) {
        guard canChangeFrames(frames), let roll else { return }
        let cleaned = ImportReview.folderName(name)
        guard !cleaned.isEmpty else { return }
        let parent = importParent(), folder = parent.appendingPathComponent(cleaned, isDirectory: true)
        let accessing = parent.startAccessingSecurityScopedResource()
        let isThere = FileManager.default.fileExists(atPath: folder.path)
        if accessing { parent.stopAccessingSecurityScopedResource() }
        guard folder.canonicalPath != roll.folder.canonicalPath, !isThere else {
            message = Self.alreadyThereText(folder)
            return
        }
        let source = roll.name, first = frames.compactMap(\.info.captureDate).min()
        move(frames, into: folder, scope: parent, named: cleaned, makingFolder: true) { [weak self] in
            guard let self, let entry = bookmarks.addRoll(folder, name: cleaned, origin: .imported, source: source) else { return nil }
            bookmarks.updateRoll(id: entry.id) { $0.firstCapture = $0.firstCapture ?? first }
            noteFramesArrived(in: entry.id)
            return entry.id
        }
    }

    /// "~/Pictures/Argent/Tokyo is already there: give the new roll another name".
    static func alreadyThereText(_ folder: URL) -> String {
        "\(DevelopStatusText.abbreviated(folder)) is already there: give the new roll another name"
    }

    /// The alert that asks a new roll's name, `suggested` in its field; `nil` when it is cancelled or left empty.
    static func askNewRollName(_ suggested: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "New Roll"
        alert.informativeText = "The frames move into a new roll of this name, in the folder Import makes its rolls in."
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func move(_ frames: [Frame], into folder: URL, scope: URL, named name: String, makingFolder: Bool,
                      arrived: @escaping @MainActor () -> UUID?) {
        guard let source = roll?.folder else { return }
        // A flag is the roll's own record, kept by its folder: the frames' go to the roll they move to.
        let flags = Dictionary(uniqueKeysWithValues: frames.compactMap { frame in flagged[frame.url].map { (frame.url, $0) } })
        let store = flagStore, alreadyThere = Self.alreadyThereText(folder)
        // The scope is the roll's own folder's, or for a new roll the folder it is made in, through its bookmark: held
        // until the new roll has joined the library, whose bookmark is made while its folder can be reached.
        relocate(frames, saying: "Moving \(Self.framesText(frames.count)) to \(name)…", scope: scope) { urls in
            if makingFolder {
                // The folder is made only if it is not there: one that is there is another roll's, or not a roll at
                // all, and is neither joined nor, should no frame arrive, removed.
                do {
                    try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                } catch CocoaError.fileWriteFileExists {
                    return FrameMoveResult(outcomes: urls.map { _ in .failed(alreadyThere) })
                } catch {
                    return FrameMoveResult(outcomes: urls.map { _ in .failed(error.localizedDescription) })
                }
            }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                return FrameMoveResult(outcomes: urls.map { _ in .failed("\(name) could not be reached") })
            }
            let outcomes = FrameFiles.move(urls, into: folder)
            let carried = zip(urls, outcomes).filter { $0.1.isMoved && flags[$0.0] != nil }.map(\.0)
            var flagsNotCarried: FrameMoveResult.FlagsNotCarried?
            if !carried.isEmpty {
                // A flags file this build cannot read is left as it is, and the frames arrive unflagged (`FlagStore.save`).
                let kept = store.record(for: folder)?.frames ?? []
                do {
                    if try !store.save(FlagRecord(frames: kept + carried.compactMap { flags[$0] }), for: folder) {
                        flagsNotCarried = .init(frames: carried, why: Self.flagsLeftText(name))
                    }
                } catch {
                    Self.framesLog.error("flags not carried to \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    flagsNotCarried = .init(frames: carried, why: error.localizedDescription)
                }
            }
            // A new roll none of whose frames arrived is not left behind: the folder made above, still empty. `rmdir`
            // removes nothing that holds a file.
            if makingFolder, !outcomes.contains(where: \.isMoved) { rmdir(folder.path) }
            return FrameMoveResult(outcomes: outcomes, flagsNotCarried: flagsNotCarried)
        } finished: { [weak self] moved, result in
            // The roll they arrived in joins the library, or is counted again there.
            if !moved.isEmpty { _ = arrived() }
            self?.framesLeft(moved, of: frames, from: source, result: result, to: name, symbol: "folder")
        }
    }

    // MARK: The move

    /// What a move's work came to, a frame's outcome for each raw in the order asked.
    struct FrameMoveResult: Sendable {
        /// Frames whose raws moved but whose flags the roll they went to could not keep, and why.
        struct FlagsNotCarried: Sendable {
            var frames: [URL]
            var why: String
        }

        var outcomes: [FrameFiles.Outcome]
        var flagsNotCarried: FlagsNotCarried?
    }

    /// Why frames arrive unflagged in the roll `name`, whose flags file this build cannot read and leaves as it is.
    nonisolated static func flagsLeftText(_ name: String) -> String {
        "\(name)’s flags file is not one this version of Argent can read, and was left as it is"
    }

    /// Moves `frames`' files with `work`, away from the main actor, and then takes those that moved out of the roll
    /// on screen. Their adjustments are saved first, so the recipes that go with the raws are as the frames were left; a
    /// save that fails stops the move before any file has gone. `scope` is the folder whose access the move needs,
    /// held from before the files move until `finished` has run.
    private func relocate(_ frames: [Frame], saying line: String, scope: URL?, work: @escaping @Sendable ([URL]) -> FrameMoveResult,
                          finished: @escaping @MainActor (Set<URL>, FrameMoveResult) -> Void) {
        guard let folder = roll?.folder else { return }
        let urls = frames.map(\.url)
        frameMove = line
        showClipboardNotice(ClipboardNotice(kind: .working, text: line))
        frameMoveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                frameMove = nil
                frameMoveTask = nil
                movingFrames = []
            }
            // A press or a gesture open on a frame ends as its own step, and every save under way lands, before its recipe goes.
            do {
                try await flushManualSaves()
            } catch {
                showClipboardNotice(ClipboardNotice(kind: .failed, text: "The frames stay: their adjustments could not be saved (\(error.localizedDescription))"))
                return
            }
            guard roll?.folder == folder, !isDeveloping, !isScanning else {
                dismissClipboardNotice()
                return
            }
            // Saved, and from here not saved again until they have gone (`saveManualFrame`).
            movingFrames = Set(urls)
            let accessing = scope?.startAccessingSecurityScopedResource() ?? false
            defer { if accessing { scope?.stopAccessingSecurityScopedResource() } }
            let result = await Task.detached(priority: .userInitiated) { work(urls) }.value
            let moved = Set(zip(urls, result.outcomes).filter { $0.1.isMoved }.map(\.0))
            // Another roll opened meanwhile: the files went where they were sent, and this roll is not on screen to change.
            if roll?.folder == folder { dropFrames(moved) }
            finished(moved, result)
        }
    }

    /// The frames that moved have left the roll on screen: the library's count and covers of the roll follow, and a line
    /// says what came of it, with the frames that stayed and why in its Details.
    private func framesLeft(_ moved: Set<URL>, of frames: [Frame], from folder: URL, result: FrameMoveResult, to place: String,
                            symbol: String) {
        // Another roll opened while the files moved: it is not the roll they left.
        let isOpen = roll?.folder == folder
        if isOpen, !moved.isEmpty { noteFramesLeft() }
        var stayed: [(name: String, why: String)] = []
        var incomplete = 0
        var companions: [ClipboardNotice.Detail] = []
        for (frame, outcome) in zip(frames, result.outcomes) {
            switch outcome {
            case .moved: break
            case .partiallyMoved(_, let failures):
                incomplete += 1
                companions += failures.map {
                    ClipboardNotice.Detail(title: $0.file.lastPathComponent,
                                           secondaryLines: ["Still in \(DevelopStatusText.abbreviated($0.file.deletingLastPathComponent()))", $0.message])
                }
            case .nameTaken: stayed.append((frame.name, "\(place) already holds a file of its name"))
            case .failed(let why): stayed.append((frame.name, why))
            }
        }
        var text: String
        if stayed.isEmpty {
            text = frames.count == 1 ? "\(frames[0].name) moved to \(place)" : "\(Self.framesText(moved.count)) moved to \(place)"
        } else if moved.isEmpty {
            text = frames.count == 1 ? "\(frames[0].name) stays: \(stayed[0].why)" : "No frame moved to \(place)"
        } else {
            text = "\(Self.framesText(moved.count)) moved to \(place) · \(stayed.count) stayed"
        }
        if incomplete > 0 {
            text += frames.count == 1 ? " · companions stayed behind" : " · \(incomplete) with companions left behind"
        }
        let unflagged = result.flagsNotCarried.map { lost in
            frames.filter { lost.frames.contains($0.url) }.map {
                ClipboardNotice.Detail(title: $0.name, secondaryLines: ["Arrived unflagged in \(place)", lost.why])
            }
        } ?? []
        if !unflagged.isEmpty {
            text += unflagged.count == 1 ? " · flag not carried" : " · \(unflagged.count) flags not carried"
        }
        let details = (frames.count > 1 ? stayed : []).map { "\($0.name): \($0.why)" }
        var heading = incomplete == 0 ? nil : stayed.isEmpty ? "Companions left behind" : "Frames and companions left behind"
        var hint: String?
        if !unflagged.isEmpty {
            let leftBehind = heading ?? (details.isEmpty ? nil : "Frames left behind")
            heading = leftBehind.map { "\($0), flags not carried" } ?? "Flags not carried"
            hint = leftBehind == nil ? "The flags not carried, and why" : "What was left behind or not carried, and why"
        }
        let isComplete = stayed.isEmpty && incomplete == 0 && unflagged.isEmpty
        showClipboardNotice(ClipboardNotice(kind: moved.isEmpty ? .failed : .done(symbol: isComplete ? symbol : "exclamationmark.triangle"),
                                            text: text,
                                            details: details,
                                            detailEntries: companions + unflagged,
                                            detailsHeading: heading,
                                            detailsHint: hint))
        // A move that left something behind keeps its notice and Details on screen, even when no raw remains.
        if isOpen, roll?.frames.isEmpty == true, incomplete == 0, unflagged.isEmpty { showWorkspacePage(.rolls) }
    }

    /// The open roll has fewer frames: the library's count of it follows, and its covers are read again from the frames
    /// left, since a cover may be of a frame that has gone.
    private func noteFramesLeft() {
        guard let roll, let entry = openLibraryRoll else { return }
        bookmarks.updateRoll(id: entry.id) { $0.frameCount = roll.frames.count }
        library = bookmarks.rolls
        invalidateLibraryCovers(entry.id)
        if !roll.frames.isEmpty { noteInLibrary(roll) } else { rollCovers[entry.id] = [] }
    }

    /// The roll `id` has more frames: its covers and its count are read again from its folder.
    private func noteFramesArrived(in id: UUID) {
        invalidateLibraryCovers(id)
        unavailableRolls.remove(id)
        library = bookmarks.rolls
        loadLibraryCovers()
    }
}
