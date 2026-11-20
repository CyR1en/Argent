import AppKit
import ArgentCore
import ArgentRoll
import Foundation

/// Where Import makes a roll's folder: in ~/Pictures/Argent, or in a folder chosen in the import's panel.
enum ImportDestination: Hashable, Codable {
    case pictures
    case folder(URL)
}

/// How the last import was made, kept for the next: whether it culled and how, and where it made its roll. Changed
/// on the import's own panel (`ImportPanel`), never in Settings.
struct ImportSettings: Equatable, Codable {
    var cull = CullSettings()
    var destination = ImportDestination.pictures
    /// Whether Import leaves frames it judges you would skip at the source; off, every frame is to import.
    var isCulling = true

    static let key = "importSettings"
}

extension ImportSettings {
    /// Stored values lie over the defaults, so a setting saved before a field existed keeps its other values.
    init(defaults: UserDefaults) {
        self = Self()
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any]
        else { return }
        var merged = base.merging(stored) { $1 }
        if let baseCull = base["cull"] as? [String: Any], let storedCull = stored["cull"] as? [String: Any] {
            merged["cull"] = baseCull.merging(storedCull) { $1 }
        }
        if let data = try? JSONSerialization.data(withJSONObject: merged),
           let settings = try? JSONDecoder().decode(Self.self, from: data) {
            self = settings
        }
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

enum SoftFocusChoice: String, CaseIterable {
    case strict, normal, loose

    var title: String { rawValue.capitalized }

    var thresholds: (softFocusBelow: Double, eyesClosedBelow: Double) {
        switch self {
        case .strict: (0.30, 0.34)
        case .normal: (0.26, 0.30)
        case .loose: (0.20, 0.24)
        }
    }

    init?(_ cull: CullSettings) {
        guard let choice = Self.allCases.first(where: { $0.thresholds == (cull.softFocusBelow, cull.eyesClosedBelow) })
        else { return nil }
        self = choice
    }

    func apply(to cull: inout CullSettings) {
        (cull.softFocusBelow, cull.eyesClosedBelow) = thresholds
    }
}

enum SameMomentChoice: String, CaseIterable {
    case narrow, normal, wide

    var title: String { rawValue.capitalized }

    var within: Double {
        switch self {
        case .narrow: 0.15
        case .normal: 0.25
        case .wide: 0.35
        }
    }

    init?(_ cull: CullSettings) {
        guard let choice = Self.allCases.first(where: { $0.within == cull.sameMomentWithin }) else { return nil }
        self = choice
    }
}

/// The a7 IV's continuous drive leaves 0.1 to 0.33 s between frames, and a second press of the shutter 0.5 s or more.
enum BurstGapChoice: String, CaseIterable {
    case short, normal, long

    var seconds: TimeInterval {
        switch self {
        case .short: 0.2
        case .normal: 0.35
        case .long: 0.6
        }
    }

    var title: String { "\(seconds.formatted(.number.precision(.fractionLength(1...2)))) s" }

    init?(_ cull: CullSettings) {
        guard let choice = Self.allCases.first(where: { $0.seconds == cull.burstGap }) else { return nil }
        self = choice
    }
}

extension RollModel {
    func chooseImportDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder Import makes its rolls in"
        if case .folder(let folder) = importSettings.destination {
            panel.directoryURL = folder
        } else {
            // The sandbox's home is the container; the Pictures entitlement grants the real one.
            let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
            panel.directoryURL = URL(fileURLWithPath: home).appendingPathComponent("Pictures", isDirectory: true)
        }
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            MainActor.assumeIsolated { self.setImportDestination(.folder(folder)) }
        }
    }

    /// A chosen folder keeps a security-scoped bookmark, as a develop destination does, since the panel's grant ends
    /// when the app quits.
    func setImportDestination(_ destination: ImportDestination) {
        if case .folder(let folder) = destination { rememberDestination(folder) }
        importSettings.destination = destination
    }

    /// The import panel's Reset to defaults: the cull as it first was, on. Where rolls are made stays.
    func resetImportCull() {
        importSettings.cull = CullSettings()
        importSettings.isCulling = true
    }

    var isImportCullDefault: Bool { importSettings.cull == CullSettings() && importSettings.isCulling }
}

struct ImportedFrames: Equatable {
    let count: Int
    let folder: URL
}

struct ImportStop: Equatable {
    let failure: String?
    let imported: ImportedFrames?

    @MainActor var text: String {
        let kept = imported.map { imported in
            "\(RollModel.framesText(imported.count)) \(imported.count == 1 ? "is" : "are") in \(imported.folder.lastPathComponent) already, "
                + "and Import copies only the rest"
        }
        return [failure, kept].compactMap { $0 }.joined(separator: ". ")
    }
}

typealias CopyKeepers = @Sendable ([URL], URL, @Sendable (URL, KeeperCopy.Outcome) async -> Void) async throws -> [KeeperCopy.Outcome]

enum ImportSession: Equatable {
    case idle
    case scanning(card: Card, done: Int, of: Int)
    case reviewing(ImportReview)
    case copying(ImportReview, folder: URL, done: Int, of: Int)
    case finished(card: Card, folder: URL, new: Int, of: Int)
    case failed(card: Card, message: String, imported: ImportedFrames? = nil)

    var card: Card? {
        switch self {
        case .idle: nil
        case .scanning(let card, _, _), .finished(let card, _, _, _), .failed(let card, _, _): card
        case .reviewing(let review), .copying(let review, _, _, _): review.card
        }
    }

    var isOpeningItsRoll: Bool {
        if case .finished = self { true } else { false }
    }

    /// The frames are being copied, or have just been: the import goes on behind the Rolls page.
    var isCopying: Bool {
        switch self {
        case .copying, .finished: true
        default: false
        }
    }
}

struct ImportFrame: Identifiable, Equatable {
    let id: String
    let frame: Frame?

    var name: String { Self.name(id) }

    static func name(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

enum ImportFilter: String, CaseIterable {
    case all
    case toImport = "import"
    case left

    var title: String { title(isFolder: false) }

    func title(isFolder: Bool) -> String {
        switch self {
        case .all: "All"
        case .toImport: "To import"
        case .left: isFolder ? "Left in the folder" : "Left on the card"
        }
    }
}

enum ImportBadge: Equatable {
    case changedToImport
    case changedToLeft(place: String)
    case reason(CullReason)

    var text: String {
        switch self {
        case .changedToImport: "To import"
        case .changedToLeft(let place): "Left \(place)"
        case .reason(.failed): "Failed frame"
        case .reason(.softFocus): "Soft focus"
        case .reason(.eyesClosed): "Eyes closed"
        case .reason(.sameMoment(let keeper)): "Same moment as \(ImportFrame.name(keeper))"
        }
    }

    var symbol: String {
        switch self {
        case .changedToImport: "arrow.down.to.line"
        case .changedToLeft: "sdcard"
        case .reason(.failed): "exclamationmark.circle"
        case .reason(.softFocus): "circle.dotted"
        case .reason(.eyesClosed): "eye.slash"
        case .reason(.sameMoment): "square.on.square"
        }
    }
}

struct ImportReview: Equatable {
    let card: Card
    let frames: [ImportFrame]
    private let inputs: [CullInput]
    private(set) var verdicts: [ImportFrame.ID: CullVerdict] = [:]
    private(set) var overrides: [ImportFrame.ID: Bool] = [:]
    private(set) var filter = ImportFilter.all
    private(set) var shown: [ImportFrame]
    /// The frames selected and their lead, by the rules the contact sheet shares (`MultiSelection`): one after an arrow
    /// or a plain click, several after a Command-click, a Shift-click, a Shift-arrow or Select All. A click on one of
    /// several, Space and their menu send them all one way.
    private var picked = MultiSelection<ImportFrame.ID>()
    /// The frame the arrows move from, the lead of the frames selected. Setting it leaves that frame alone selected.
    var selection: ImportFrame.ID? {
        get { picked.lead }
        set { picked.selectAlone(newValue) }
    }
    /// The frames selected, the lead among them.
    var selected: Set<ImportFrame.ID> { picked.items }
    var stop: ImportStop?
    /// The frames come from a folder chosen in the panel, not a card.
    var isFolder = false
    /// The roll's name, and its folder's: the first frame's day on the camera's clock until changed.
    var name: String

    init(card: Card, frames inputs: [CullInput], headers: [Frame], settings: CullSettings, culling: Bool = true, isFolder: Bool = false) {
        let byPath = Dictionary(headers.map { (Self.path(of: $0.url, on: card), $0) }) { first, _ in first }
        self.card = card
        frames = inputs.map { ImportFrame(id: $0.path, frame: byPath[$0.path]) }
        self.inputs = inputs
        self.isFolder = isFolder
        shown = frames
        name = Self.defaultName(firstCapture: inputs.compactMap(\.captureDate).min())
        judge(with: settings, culling: culling)
    }

    /// The first frame's day on the camera's clock, "2026-11-14"; today's without one.
    static func defaultName(firstCapture: Date?) -> String {
        // The camera's clock is recorded as if it were UTC.
        firstCapture.map { $0.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!).year().month().day()) }
            ?? Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    /// The name as a folder takes it (`folderName(_:)`); the default when nothing is left.
    var folderName: String {
        let named = Self.folderName(name)
        return named.isEmpty ? Self.defaultName(firstCapture: firstCaptureDate) : named
    }

    /// A roll's name as a folder takes it, for an import's roll and for Move to Roll > New Roll…: no slash or colon, no
    /// leading dot, trimmed; empty when nothing is left.
    static func folderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.drop { $0 == "." })
    }

    /// Where frames not imported stay: "on the card", or "in the folder".
    var leftPlace: String { isFolder ? "in the folder" : "on the card" }

    static func path(of url: URL, on card: Card) -> String {
        let root = URL(fileURLWithPath: card.volume.canonicalPath).pathComponents.count
        return URL(fileURLWithPath: url.canonicalPath).pathComponents.dropFirst(root).joined(separator: "/")
    }

    func isKept(_ id: ImportFrame.ID) -> Bool { overrides[id] ?? verdicts[id]?.keep ?? true }

    func isChanged(_ id: ImportFrame.ID) -> Bool { isKept(id) != verdicts[id]?.keep ?? true }

    func badge(_ id: ImportFrame.ID) -> ImportBadge? {
        if isChanged(id) { return isKept(id) ? .changedToImport : .changedToLeft(place: leftPlace) }
        return verdicts[id]?.reason.map(ImportBadge.reason)
    }

    var importCount: Int { frames.count { isKept($0.id) } }

    func count(_ filter: ImportFilter) -> Int {
        switch filter {
        case .all: frames.count
        case .toImport: importCount
        case .left: frames.count - importCount
        }
    }

    var summary: String {
        count(.left) == 0 ? "All \(importCount) to import" : "\(importCount) to import, \(count(.left)) left \(leftPlace)"
    }

    var keepers: [ImportFrame] { frames.filter { isKept($0.id) } }

    var firstCaptureDate: Date? { inputs.compactMap(\.captureDate).min() }

    /// The earliest capture time among the frames to import, the roll's date.
    var firstKeptCaptureDate: Date? {
        let kept = Set(keepers.map(\.id))
        return inputs.filter { kept.contains($0.path) }.compactMap(\.captureDate).min()
    }

    var clash: String? {
        var names = Set<String>()
        return keepers.first { !names.insert($0.name.lowercased()).inserted }?.name
    }

    static func clashText(_ name: String) -> String { "Two frames to import are named \(name): leave one out" }

    var canCopy: Bool { importCount > 0 && clash == nil }

    mutating func toggle(_ id: ImportFrame.ID) {
        overrides[id] = !isKept(id)
        selection = id
    }

    // MARK: Several frames

    func isSelected(_ id: ImportFrame.ID) -> Bool { selected.contains(id) }

    /// The frames shown, by path, in their order: what a range runs over.
    private var shownIDs: [ImportFrame.ID] { shown.map(\.id) }

    /// The frames selected, in the order shown.
    var selectedFrames: [ImportFrame.ID] { picked.ordered(in: shownIDs) }

    /// The frames a menu opened on `id` acts on: the several selected when it is one of them, else it alone.
    func framesActedOn(from id: ImportFrame.ID) -> [ImportFrame.ID] { picked.acted(on: id, in: shownIDs) }

    /// A click on a frame. Plain, it sends the frame the other way, and with it the frames selected when it is one of
    /// several, which then all go where it goes; with Command the frame joins the frames selected or leaves them, and
    /// with Shift every frame shown from where the range starts to it is selected, neither changing where a frame goes.
    mutating func click(_ id: ImportFrame.ID, _ click: SelectionClick) {
        switch click {
        case .alone:
            guard selected.count > 1, selected.contains(id) else { return toggle(id) }
            setKept(!isKept(id), for: selected)
            picked.lead(with: id)
        case .toggle:
            picked.toggle(id, in: shownIDs)
        case .range:
            picked.selectRange(to: id, in: shownIDs)
        }
    }

    /// Sends `frames` to import, or leaves them at the source.
    mutating func setKept(_ kept: Bool, for frames: some Sequence<ImportFrame.ID>) {
        for id in frames { overrides[id] = kept }
    }

    /// Space: the frame selected the other way, or the several selected all the way the lead goes.
    mutating func toggleSelected() {
        guard let lead = selection else { return }
        guard selected.count > 1 else { return toggle(lead) }
        setKept(!isKept(lead), for: selected)
    }

    /// Command-A: every frame shown.
    mutating func selectAll() {
        picked.selectAll(in: shownIDs)
    }

    mutating func show(_ filter: ImportFilter) {
        self.filter = filter
        shown = frames.filter { frame in
            switch filter {
            case .all: true
            case .toImport: isKept(frame.id)
            case .left: !isKept(frame.id)
            }
        }
        if let selection, !shown.contains(where: { $0.id == selection }) {
            self.selection = nil
        } else {
            // The frames selected that the filter leaves out leave the selection; the lead stays.
            picked.keep(in: shownIDs)
        }
    }

    /// Judges every frame with `settings`; without `culling`, every frame is to import and has no reason. The
    /// photographer's own changes stay.
    mutating func judge(with settings: CullSettings, culling: Bool = true) {
        guard culling else {
            verdicts = [:]
            return
        }
        verdicts = Dictionary(Cull.verdicts(inputs, settings: settings).map { ($0.path, $0) }) { first, _ in first }
    }

    /// An arrow: the selection `offset` frames on among those shown; with Shift (`extending`), every frame from where
    /// the range starts to the frame reached.
    mutating func moveSelection(by offset: Int, extending: Bool = false) {
        guard !shown.isEmpty else { return }
        guard let selection, let index = shown.firstIndex(where: { $0.id == selection }) else {
            self.selection = shown.first?.id
            return
        }
        select(shown[min(max(0, index + offset), shown.count - 1)].id, extending: extending)
    }

    mutating func selectEnd(last: Bool, extending: Bool = false) {
        guard let target = last ? shown.last?.id : shown.first?.id else { return }
        select(target, extending: extending)
    }

    private mutating func select(_ target: ImportFrame.ID, extending: Bool) {
        guard extending, selection != nil else {
            selection = target
            return
        }
        picked.selectRange(to: target, in: shownIDs)
    }
}

extension RollModel {
    func canImport(_ card: Card) -> Bool { card.rawCount != nil && !isDeveloping && importSession == .idle }

    func startImport(_ card: Card) {
        guard canImport(card) else { return }
        cards.removeAll { $0.id == card.id }
        beginImport(card, isFolder: false)
    }

    /// Imports the folder chosen in the panel as a card is imported: its frames are read and reviewed, then copied into
    /// a new roll. Its frames stay in it.
    func startImport(folder: URL) {
        guard !isDeveloping, importSession == .idle else { return }
        beginImport(Card(volume: folder, name: folder.lastPathComponent, rawCount: nil), isFolder: true)
    }

    private func beginImport(_ card: Card, isFolder: Bool) {
        isImportSourceShown = false
        importNotice = nil
        importsFolder = isFolder
        maskEditor.reset()
        if requestedPage == .settings { requestedPage = .roll }
        importRun += 1
        let run = importRun
        importSession = .scanning(card: card, done: 0, of: card.rawCount ?? 0)
        let (counts, counter) = AsyncStream.makeStream(of: (done: Int, total: Int).self, bufferingPolicy: .bufferingNewest(1))
        importTask = Task { [weak self] in
            let shown = Task { for await count in counts { self?.importScanned(count.done, of: count.total, run: run) } }
            async let headers = RollScanner.scan(card.volume)
            let result: Result<CardCull, Error>
            do {
                result = .success(try await CardCull.run(folder: card.volume) { counter.yield(($0, $1)) })
            } catch {
                result = .failure(error)
            }
            counter.finish()
            await shown.value
            let frames = await headers.frames
            self?.importScanEnded(result, headers: frames, run: run)
        }
    }

    private func importScanned(_ done: Int, of total: Int, run: Int) {
        guard run == importRun, case .scanning(let card, _, _) = importSession else { return }
        importSession = .scanning(card: card, done: done, of: total)
    }

    private func importScanEnded(_ result: Result<CardCull, Error>, headers: [Frame], run: Int) {
        guard run == importRun, case .scanning(let card, _, _) = importSession else { return }
        switch result {
        case .success(let cull):
            if importsFolder, cull.frames.isEmpty {
                // A folder without raws gives no import, as it gives no roll (`open`).
                importSession = .idle
                importsFolder = false
                requestedPage = .rolls
                message = RollIssues.noFramesLine(folderName: card.name, unreadable: [])
                return
            }
            importSession = .reviewing(ImportReview(card: card, frames: cull.frames, headers: headers, settings: importSettings.cull,
                                                    culling: importSettings.isCulling, isFolder: importsFolder))
        case .failure(let error) where error is CancellationError:
            importSession = .idle
        case .failure(let error):
            importSession = .failed(card: card, message: failureText(error, card: card))
        }
    }

    private func failureText(_ error: Error, card: Card) -> String {
        if !FileManager.default.fileExists(atPath: card.volume.path) { return Self.removedText(card, isFolder: importsFolder) }
        if importsFolder {
            if case .unreadable? = error as? CardCull.Failure { return "Argent may not read \(card.name)" }
            return "Argent could not read \(card.name)"
        }
        if case .unreadable? = error as? CardCull.Failure { return Self.mayNotReadText(card.name) }
        return "Argent could not read \(card.name)"
    }

    /// Close on the review: the import ends and the card is offered again. A copy under way goes on behind the Rolls
    /// page, and only its own Cancel stops it.
    func closeImport() {
        guard let card = importSession.card, !importSession.isCopying else { return }
        endImportScan()
        importSession = .idle
        importThumbnails.removeAll()
        if !importsFolder, FileManager.default.fileExists(atPath: card.volume.path) { offer(card, announce: false) }
    }

    func importCardRemoved(_ volume: URL) {
        guard let card = importSession.card, !importSession.isOpeningItsRoll,
              card.volume.canonicalPath == volume.canonicalPath || card.volume.canonicalPath.hasPrefix(volume.canonicalPath + "/")
        else { return }
        if case .copying = importSession { return cancelCopy() }
        let imported: ImportedFrames? = if case .reviewing(let review) = importSession { review.stop?.imported } else { nil }
        endImportScan()
        importSession = .failed(card: card, message: Self.removedText(card, isFolder: importsFolder), imported: imported)
    }

    func cancelCopy() {
        guard case .copying = importSession else { return }
        importTask?.cancel()
    }

    /// Import N frames: the frames to import are copied into the roll's folder behind the Rolls page, where the new
    /// roll shows them arriving; the review comes back if the copy stops.
    func startCopy() {
        guard case .reviewing(let review) = importSession, review.canCopy else { return }
        let card = review.card, parent = importParent(), folder = parent.appendingPathComponent(review.folderName, isDirectory: true)
        guard folder.canonicalPath != card.volume.canonicalPath else {
            reviewImport { $0.stop = ImportStop(failure: "\(review.folderName) is the folder the frames are in: name the roll otherwise", imported: nil) }
            return
        }
        let raws = review.keepers.map { card.volume.appendingPathComponent($0.id) }
        importRun += 1
        let run = importRun, copy = importsFolder && !Self.isOnCard(card.volume) ? folderKeeperCopy : keeperCopy
        let cardRoot = FolderIdentity(card.volume)
        importSession = .copying(review, folder: folder, done: 0, of: raws.count)
        requestedPage = .rolls
        importThumbnails.removeAll()
        readImportCovers(RollCoverStore.spread(raws.count, RollCoverStore.count).map { raws[$0] }, run: run)
        let (outcomes, reporter) = AsyncStream.makeStream(of: KeeperCopy.Outcome.self)
        importTask = Task { [weak self] in
            // The scope is the chosen folder's, through its bookmark; a folder named inside it carries none of its own.
            let accessing = parent.startAccessingSecurityScopedResource()
            defer { if accessing { parent.stopAccessingSecurityScopedResource() } }
            let counted = Task {
                var done = 0
                for await outcome in outcomes where outcome.isInFolder {
                    done += 1
                    self?.importCopied(done, run: run)
                }
                return done
            }
            let result: Result<[KeeperCopy.Outcome], Error>
            do {
                result = .success(try await copy(raws, folder) { _, outcome in reporter.yield(outcome) })
            } catch {
                result = .failure(error)
            }
            reporter.finish()
            let inFolder = await counted.value
            guard let self, run == importRun, case .copying(let review, _, _, let total) = importSession else { return }
            switch result {
            case .success(let outcomes):
                await importCopyFinished(review, to: folder, new: outcomes.count(where: \.isCopied), of: total, run: run)
            case .failure(let error):
                importCopyStopped(review, by: error, inFolder: inFolder, folder: folder, cardRoot: cardRoot)
            }
        }
    }

    /// Whether `url` is on a mounted camera card, a volume with a DCIM folder of raws: an import from a folder there still
    /// never writes to the card.
    static func isOnCard(_ url: URL) -> Bool {
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return CardScanner.isCardLike(volume) && CardScanner.card(on: volume) != nil
    }

    /// The roll's folder: the review's name in the folder Import makes its rolls in.
    func importFolder(for review: ImportReview) -> URL {
        importParent().appendingPathComponent(review.folderName, isDirectory: true)
    }

    /// The folder Import makes its rolls in: ~/Pictures/Argent, or the folder chosen, reached through its bookmark once
    /// the panel's grant has ended with the app.
    func importParent() -> URL {
        switch importSettings.destination {
        case .pictures:
            return Self.argentPictures
        case .folder(let folder):
            if FileManager.default.isWritableFile(atPath: folder.path) { return folder }
            guard let found = bookmarks.destination(atPath: folder.path) else { return folder }
            // The bookmark follows a folder renamed or moved since it was chosen.
            if found.canonicalPath != folder.canonicalPath { importSettings.destination = .folder(found) }
            return found
        }
    }

    static func picturesFolder(for review: ImportReview) -> URL {
        argentPictures.appendingPathComponent(review.folderName, isDirectory: true)
    }

    /// The covers of the frames being copied, from their sources' previews, for the new roll's strip on the Rolls page.
    private func readImportCovers(_ raws: [URL], run: Int) {
        importCovers = []
        Task {
            let covers = await Task.detached(priority: .utility) {
                raws.compactMap { raw -> CGImage? in
                    guard let info = try? ARWFrameInfo.read(from: raw), let preview = info.preview else { return nil }
                    return try? EmbeddedJPEG.image(at: preview, in: raw, maxPixelSize: RollCoverStore.pixelSize, orientation: info.orientation)
                }
            }.value
            guard run == importRun else { return }
            importCovers = covers
        }
    }

    private func importCopied(_ done: Int, run: Int) {
        guard run == importRun, case .copying(let review, let folder, _, let total) = importSession else { return }
        importSession = .copying(review, folder: folder, done: done, of: total)
    }

    /// The copy is done, while the roll's folder is still reached: it joins the library as imported, with the covers
    /// read as it began, and the Rolls page says what came of it, offering to open it and to eject the source.
    private func importCopyFinished(_ review: ImportReview, to folder: URL, new: Int, of total: Int, run: Int) async {
        let card = review.card
        importSession = .finished(card: card, folder: folder, new: new, of: total)
        importThumbnails.removeAll()
        let entry = bookmarks.addRoll(folder, name: review.folderName, origin: .imported, source: card.name)
        if let entry {
            // Counted away from the main actor: the folder may be on a slow drive.
            let frames = await Task.detached(priority: .userInitiated) { RollScanner.rawFiles(in: folder).count }.value
            bookmarks.updateRoll(id: entry.id) {
                $0.frameCount = frames
                $0.firstCapture = $0.firstCapture ?? review.firstKeptCaptureDate ?? review.firstCaptureDate
            }
            let covers = importCovers
            if !covers.isEmpty {
                invalidateLibraryCovers(entry.id)
                rollCovers[entry.id] = covers
                let store = coverStore, id = entry.id
                let generation = store.beginRead(for: id)
                Task.detached(priority: .utility) { store.keep(covers, for: id, generation: generation) }
            }
            unavailableRolls.remove(entry.id)
        }
        library = bookmarks.rolls
        guard run == importRun else { return }
        importNotice = ImportNotice(roll: entry?.id, folder: folder, copied: total, left: review.count(.left), source: card.name,
                                    isFolder: importsFolder, ejectable: Self.ejectableVolume(of: card.volume))
        importSession = .idle
        importCovers = []
        if !importsFolder {
            importedCards.insert(card.volume.canonicalPath)
            if FileManager.default.fileExists(atPath: card.volume.path) { offer(card, announce: false) }
        }
        importsFolder = false
    }

    private func importCopyStopped(_ review: ImportReview, by error: Error, inFolder: Int, folder: URL, cardRoot: FolderIdentity?) {
        let card = review.card, imported = inFolder > 0 ? ImportedFrames(count: inFolder, folder: folder) : nil
        let root = FolderIdentity(card.volume)
        guard root != nil, root == cardRoot else {
            importSession = .failed(card: card, message: Self.removedText(card, isFolder: importsFolder), imported: imported)
            return
        }
        let failure = error is CancellationError ? nil : Self.copyStopText(error, card: card, folder: folder)
        var review = review
        review.stop = failure == nil && imported == nil ? nil : ImportStop(failure: failure, imported: imported)
        importSession = .reviewing(review)
    }

    private static func copyStopText(_ error: Error, card: Card, folder: URL) -> String {
        let place = DevelopStatusText.abbreviated(folder)
        var frame: String?
        var failure = error as? KeeperCopy.Failure
        if let stopped = error as? KeeperCopy.Stopped {
            if case .conflict = stopped.outcome {
                return "\(place) already holds a different \(stopped.raw.lastPathComponent): move it away, then import again"
            }
            frame = ImportFrame.name(stopped.raw.lastPathComponent)
            if case .failed(let stoppedBy) = stopped.outcome { failure = stoppedBy }
        }
        switch failure {
        case .unreadable: return "Argent could not read \(frame.map { "\($0) on " } ?? "")\(card.name)"
        case .changedWhileRead: return "\(frame ?? "A frame") changed on \(card.name) while Argent copied it: import again"
        case .readBackMismatch: return "The copy of \(frame ?? "a frame") in \(place) does not match the frame on \(card.name): import again"
        case .unwritable(let reason): return "Argent could not write to \(place): \(reason)"
        case .folderOnCard: return "Argent never writes to the card: choose another folder in Copy to"
        case .sameName(let name): return ImportReview.clashText(ImportFrame.name(name))
        case nil: return "Argent could not copy the frames to \(place)"
        }
    }

    private func endImportScan() {
        importRun += 1
        importTask?.cancel()
        importTask = nil
    }

    static func removedText(_ card: Card, isFolder: Bool = false) -> String {
        isFolder ? "\(card.name) was removed" : "Card \(card.name) was removed"
    }

    func reviewImport(_ change: (inout ImportReview) -> Void) {
        guard case .reviewing(var review) = importSession else { return }
        change(&review)
        importSession = .reviewing(review)
    }

    func importSettingsChanged(from old: ImportSettings) {
        guard importSettings.cull != old.cull || importSettings.isCulling != old.isCulling else { return }
        reviewImport { $0.judge(with: importSettings.cull, culling: importSettings.isCulling) }
    }
}

/// A folder as `stat` finds it. A card pulled from its reader leaves its mount point another folder, or none, as its reads
/// fail, before macOS reports the unmount.
struct FolderIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(_ folder: URL) {
        var info = stat()
        guard stat(folder.path, &info) == 0 else { return nil }
        (device, inode) = (info.st_dev, info.st_ino)
    }
}

private extension KeeperCopy.Outcome {
    var isInFolder: Bool {
        switch self {
        case .copied, .alreadyThere: true
        case .conflict, .failed: false
        }
    }

    var isCopied: Bool {
        if case .copied = self { true } else { false }
    }
}
