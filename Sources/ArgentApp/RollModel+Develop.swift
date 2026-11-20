import AppKit
import ArgentCore
import ArgentRoll
import Foundation
import os
import UserNotifications

/// Where a develop stands, for the Develop button.
enum DevelopPhase: Equatable {
    case idle
    /// Frames finished so far, with a file or failed.
    case developing(DevelopProgress)
    /// Finished with files; the button offers Reveal in Finder until a setting changes.
    case done
}

/// The choices and raw versions captured by a develop, compared with the roll when it finishes,
/// and the settled Auto decision it printed at, so Reveal in Finder gives way once the aims move.
/// Frames' own choices and raws are those of the frames developed (`frames`), the frames shown or
/// those a Resume went on with: a change to a frame the develop left out, or another filter, leaves
/// its Reveal in Finder.
struct DevelopInputs: Equatable {
    let stockIndex: Int
    let controls: RollControls
    let overrides: [URL: FrameControls]
    let output: OutputSettings
    let manualEdits: [URL: ManualEdit]
    let sources: [URL: SourceStamp]
    /// The revision of the roll's settled decision; `nil` while the roll is not settled.
    var autoRevision: String?

    @MainActor init(_ model: RollModel, frames: [URL]? = nil) {
        let developed = Set(frames ?? model.shownFrames.map(\.url))
        stockIndex = model.stockIndex
        controls = model.controls
        overrides = model.overrides.filter { developed.contains($0.key) }
        output = model.output
        manualEdits = model.manualEdits.filter { developed.contains($0.key) }
        sources = model.sourceVersions.filter { developed.contains($0.key) }
        autoRevision = model.isBalanced ? model.autoDecision?.revision : nil
    }
}

/// A frame's mark on the Develop page (`RollModel.developMarks`): a develop of this session has its file,
/// which nothing has changed since, or the last develop could not write it.
enum DevelopMark: Equatable, Sendable {
    case developed
    case failed
}

/// What a frame's file was developed from and into, as its develop's `DevelopInputs` had them: while
/// the roll and the frame still say the same, a develop would find the file and skip the frame, and the
/// Develop page checks it.
struct DevelopedFrame: Equatable {
    var destination: URL
    var stockIndex: Int
    var controls: RollControls
    /// The output choices, with the frame's own grain where it has one, as its develop recorded them (`RollDeveloper.output`).
    var output: OutputSettings
    var autoRevision: String?
    var own: FrameControls?
    var edit: ManualEdit?
    var source: SourceStamp?

    init(_ inputs: DevelopInputs, frame raw: URL, destination: URL) {
        self.destination = destination
        stockIndex = inputs.stockIndex
        controls = inputs.controls
        output = inputs.output.grain(inputs.overrides[raw]?.grain)
        autoRevision = inputs.autoRevision
        own = inputs.overrides[raw]
        edit = inputs.manualEdits[raw]
        source = inputs.sources[raw]
    }
}

extension OutputSettings {
    /// These choices with a frame's own grain, `own`, in place of the roll's; as they are without one.
    func grain(_ own: Grain?) -> OutputSettings {
        var settings = self
        settings.grain = own ?? grain
        return settings
    }
}

extension DevelopReport {
    /// The file this develop has for the frame at `raw`, or `nil` where it has none or cannot say: its files are its
    /// frames' in roll order less those that failed, but a stopped develop does not record which frames it reached.
    /// Failed raws are gathered once because this is asked at each change of the selection.
    func file(for raw: URL) -> URL? {
        guard stopped == 0, raws.count == total else { return nil }
        let failed = Set(failures.map(\.frame.url))
        let written = raws.filter { !failed.contains($0) }
        guard written.count == files.count, let index = written.firstIndex(of: raw) else { return nil }
        return files[index]
    }
}

extension RollModel {
    private static let developLog = Logger(subsystem: "camera.argent.Argent", category: "develop")
    private static let outputKey = "outputSettings"
    /// The reason a develop's activity gives the system, as `pmset -g assertions` lists it.
    static let developActivityReason = "Developing a roll"

    /// The app and its version, recorded in each developed file and recipe.
    static var software: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return "Argent \(version)"
    }

    static func savedOutput() -> OutputSettings {
        var output = UserDefaults.standard.data(forKey: outputKey).flatMap { try? JSONDecoder().decode(OutputSettings.self, from: $0) }
            ?? OutputSettings()
        // Every develop is full size since 2026-10-29, whatever size was saved before.
        output.size = .full
        return output
    }

    func saveOutput() {
        if let data = try? JSONEncoder().encode(output) { UserDefaults.standard.set(data, forKey: Self.outputKey) }
    }

    /// A finished develop's Reveal in Finder gives way to Develop when anything that changes
    /// a frame changes.
    func settingsChanged() {
        if developPhase == .done { developPhase = .idle }
        if manualRestoreTask != nil, !isApplyingRestoredChoices { manualChoicesChangedDuringRestore = true }
        saveManualChoices()
        autoControlsChanged()
    }

    var developRollName: String {
        let folderName = roll?.name ?? ""
        guard let name = openLibraryRoll?.name, name != folderName else { return folderName }
        let suggested = ImportReview.folderName(name)
        return suggested.isEmpty ? folderName : suggested
    }

    var developFolder: DevelopFolder {
        get {
            chosenDevelopFolder ?? DevelopFolder(base: Self.argentDeveloped, usesSubfolder: true, rollName: developRollName)
        }
        set {
            if developPhase == .done, newValue.destination != developDestination { developPhase = .idle }
            chosenDevelopFolder = newValue
        }
    }

    /// The user's own home folder: the sandbox's is the container.
    static var userHome: URL {
        URL(fileURLWithPath: getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory())
    }

    /// ~/Pictures/Argent, where Import makes a roll's folder: the Pictures entitlement grants it.
    static var argentPictures: URL {
        userHome.appendingPathComponent("Pictures/Argent", isDirectory: true)
    }

    /// ~/Argent/Developed, where a roll's developed files go, in a folder of its name, until another is chosen for it
    /// (`developFolder`): apart from the rolls' raws, and reached through the entitlements' exception for ~/Argent.
    static let argentDeveloped = userHome.appendingPathComponent("Argent/Developed", isDirectory: true)

    /// Whether a develop can start now, whatever frames it is to cover: Resume's need not be shown.
    var canStartDevelop: Bool {
        roll != nil && films != nil && !isDeveloping && !isScanning && !isQuitting && !isRestoringManual && frameMove == nil
    }

    /// Develop: a develop can start, and the sheet shows frames for it.
    var canDevelop: Bool { canStartDevelop && developDestination != nil && !shownFrames.isEmpty }

    /// The frames a develop starting now covers, in capture order: the roll's frames among `raws`, the
    /// frames a stopped develop had that Resume goes on with, else the frames the sheet shows.
    func framesToDevelop(_ raws: [URL]? = nil) -> [Frame] {
        guard let raws else { return shownFrames }
        let wanted = Set(raws)
        return roll?.frames.filter { wanted.contains($0.url) } ?? []
    }

    var developDestination: URL? { developFolder.destination }

    /// Choose changes the parent while keeping the subfolder setting.
    func chooseDestination(_ folder: URL) {
        developFolder.base = folder
    }

    /// Roll > Develop and Command-D: from the roll or another page, the Develop page, where what a develop
    /// writes and where it goes are in sight; on the page, its button while that starts a develop. A develop
    /// under way is stopped by Stop Developing and its files are shown by Reveal, never by this key pressed
    /// once more.
    func developCommand() {
        guard workspacePage == .develop else {
            showDevelopPage()
            return
        }
        guard canPerformDevelopPrimary else { return }
        switch developPrimary {
        case .develop, .developAgain, .resume: performDevelopPrimary()
        case .stop, .reveal: break
        }
    }

    /// The Develop page's button: the frames the page shows, into `developDestination`. Resume (`resuming`)
    /// goes on with the frames the stopped develop had, whatever the page shows now.
    func develop(resuming report: DevelopReport? = nil) { develop(frames: report?.raws) }

    /// Develops the roll's frames among `raws` (Resume's, or Develop This Frame's one), else the frames shown,
    /// into `developDestination`. A folder that cannot be made or written fails every frame with that reason,
    /// which the Develop page says beside its Choose….
    func develop(frames raws: [URL]?) {
        startDevelop(in: developFolder, frames: raws)
    }

    /// Develops straight into an explicitly supplied output folder.
    func startDevelop(to destination: URL) {
        startDevelop(in: DevelopFolder(base: destination, usesSubfolder: false, rollName: developRollName), frames: nil)
    }

    private func startDevelop(in folder: DevelopFolder, frames raws: [URL]?) {
        guard let destination = folder.destination, roll != nil, let films, currentStock != nil,
              !isScanning, !isQuitting, frameMove == nil, !isDeveloping else { return }
        let developing = framesToDevelop(raws).map(\.url)
        guard !developing.isEmpty else { return }
        if ProcessInfo.isRunningTests, folder.base == Self.argentDeveloped {
            fatalError("A test developed into ~/Argent/Developed: choose the roll a destination of its own first")
        }
        message = nil
        chosenDevelopFolder = folder
        if developer == nil {
            do {
                // The sheet's decoder choices, so each frame develops from the decoder its previews came from,
                // and its turns, so the previews' decodes never run beside the develop's frames.
                developer = try RollDeveloper(stocks: films.stocks, software: Self.software, library: recipeLibrary,
                                              decoderChoices: films.decoderChoices,
                                              decodeTurns: films.decodeTurns)
            } catch {
                Self.developLog.error("develop unavailable: \(String(describing: error), privacy: .public)")
                message = "Develop could not start: \(String(describing: error))"
                return
            }
        }
        guard let developer else { return }
        developPhase = .developing(DevelopProgress(total: developing.count))
        // The last develop's failures are what this one is retrying; its report replaces them.
        isIssueDetailsShown = false
        // The page's marks on these frames are this develop's from here: each starts with none and takes
        // its own as it ends. They come back as they were if the develop ends before it reaches a frame
        // (`abandon`), and a frame it is stopped before keeps the check it had (`noteDeveloped`).
        let outcomesBefore = developOutcomes, developedBefore = developedFrames
        developOutcomes = [:]
        for raw in developing { developedFrames[raw] = nil }
        /// The develop could not start: the window is as it was before it.
        func abandon() {
            developOutcomes = outcomesBefore
            developedFrames = developedBefore
            developPhase = .idle
            developTask = nil
        }
        // Work the user waits on: without an activity, App Nap throttles a develop once the app is
        // hidden; the mixed roll took 2.5 times as long (docs/manual-development-validation.md,
        // "App Nap and a develop in the background"). Held, and the Mac kept from idle sleep,
        // until the develop ends, however it ends.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: Self.developActivityReason)
        // Track the request before restoration or autosave waits, so Stop and opening another
        // roll cancel this request too. The model lives as long as the app, so it is held here.
        developTask = Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            // A selection under way on a frame it develops lands, and is saved, first: a develop never runs a model.
            await waitForSelections(on: developing)
            do { try await flushManualSaves() } catch {
                if !Task.isCancelled {
                    message = "Develop could not start because adjustments have not saved: \(error.localizedDescription)"
                }
                abandon()
                return
            }
            // Only the frames developed: a frame outside the develop does not hold it up.
            let wanted = Set(developing)
            await retryUnreadManualRecipes(self.roll?.frames.filter { wanted.contains($0.url) } ?? [])
            guard !Task.isCancelled, let roll = self.roll, let rollStock = currentStock?.id else {
                abandon()
                return
            }
            // Capture one acknowledged revision after flushing. Later edits remain live in
            // the inspector and are saved separately from this immutable export snapshot.
            forgetChangedSources()
            let rollFrames = self.roll?.frames ?? roll.frames
            let frames = rollFrames.filter { wanted.contains($0.url) }
            // A frame whose own stock is not installed fails with that reason, and its file stays as it is: it never develops
            // through the roll's stock in its place. Every other frame develops.
            let unavailable = Dictionary(frames.compactMap { frame in
                unavailableStockReason(for: frame).map { (frame.url, $0) }
            }, uniquingKeysWith: { first, _ in first })
            let developable = frames.filter { unavailable[$0.url] == nil }
            // Each frame through its own stock, or the roll's, with the digest of its tables the develop loaded.
            let stocks = Dictionary(developable.compactMap { frame in
                stock(for: frame).flatMap { stock in developer.digest(ofStock: stock.id).map { (frame.url, (stock, $0)) } }
            }, uniquingKeysWith: { first, _ in first })
            guard stocks.count == Set(developable.map(\.url)).count else {
                abandon()
                return
            }
            let frameSources = Dictionary(frames.compactMap { frame in
                sourceStamp(for: frame).map { (frame.url, $0) }
            }, uniquingKeysWith: { first, _ in first })
            var inputs = DevelopInputs(self, frames: frames.map(\.url))
            let controls = inputs.controls, overrides = inputs.overrides, output = inputs.output
            let edits = inputs.manualEdits, recipes = manualRecipes, revision = editRevision, lineage = editLineage
            let library = recipeLibrary, lineages = manualLineages
            // An issue with an edit stops the develop. A lost seed does not: that frame alone fails, with its reason, when the
            // developer finds the seed missing before its decode (`RollDeveloper.seedFailure`), and every other frame develops.
            if let blocked = frames.first(where: { adjustmentIssue(for: $0) != nil }), let issue = adjustmentIssue(for: blocked) {
                message = "Resolve \(blocked.name)’s adjustment issue before developing: \(issue)"
                abandon()
                return
            }
            // Every frame is printed as auto development measured it on the sheet; frames
            // never shown are measured first, from the same 960-pixel decode, and the roll's settled
            // decision is awaited, balanced now if it is not yet, so the files print what the sheet
            // settles on (docs/research/auto/sequence-consistency.md, stage 4). The whole roll's,
            // whichever frames develop: flags never change a print.
            isDevelopBalancing = !isBalanced
            await withTaskGroup(of: Void.self) { group in
                for frame in rollFrames where !self.isMeasured(frame) {
                    group.addTask { await self.analyze(frame, priority: .high) }
                }
            }
            let settled = Task.isCancelled ? nil : await settledDecision()
            isDevelopBalancing = false
            guard !Task.isCancelled else {
                self.finishDevelop(frames, frames.map { _ in .stopped }, folder: folder, destination: destination, inputs: inputs, before: developedBefore)
                return
            }
            guard let settled else {
                message = "Develop could not start because the roll could not be balanced"
                abandon()
                return
            }
            inputs.autoRevision = settled.revision
            // The model that removes objects is sent away first, and is gone before the develop's gate reads the footprint; its
            // runs wait for the develop and go on when it ends, however it ends.
            await self.removalsYieldToDevelop()
            defer { self.removalsResumeAfterDevelop() }
            self.trimForDevelop()
            let analyses = self.analyses, aims = settled.aims, autoRevision = settled.revision, sources = self.measuredFrom
            let jobs: [RollDeveloper.Job]
            do {
                jobs = try await Task.detached(priority: .userInitiated) {
                    try developable.map { frame in
                        guard let (stock, digest) = stocks[frame.url] else { throw CancellationError() }
                        let recipe = try Recipe.make(
                            frame: frame, byteCount: RecipeStore.byteCount(of: frame.url), stock: stock, stockDigest: digest,
                            roll: controls, own: overrides[frame.url] ?? FrameControls(), rollStock: rollStock, analysis: analyses[frame.url],
                            aim: aims[frame.url], grain: output.grain, sharpen: true,
                            previous: recipes[frame.url] ?? RecipeStore.checked(for: frame, library: library, check: .knownOnly)?.recipe,
                            manual: edits[frame.url], editRevision: revision, editLineage: recipes[frame.url]?.editLineage ?? lineages[frame.url] ?? lineage)
                        return RollDeveloper.Job(frame: frame, recipe: recipe, measuredFrom: sources[frame.url],
                                                 frameSource: frameSources[frame.url], autoRevision: autoRevision)
                    }
                }.value
                observeDevelopJobs?(jobs)
            } catch {
                message = "Develop could not resolve adjustments: \(error.localizedDescription)"
                abandon()
                return
            }
            let developed = jobs.map(\.frame.url)
            for frame in frames { if let reason = unavailable[frame.url] { frameDeveloped(frame.url, .failed(reason)) } }
            let made = await developer.develop(jobs, to: destination, output: output) { index, outcome in
                Task { @MainActor in self.frameDeveloped(developed.indices.contains(index) ? developed[index] : nil, outcome) }
            }
            let byFrame = Dictionary(zip(developed, made), uniquingKeysWith: { first, _ in first })
            let outcomes = frames.map { frame in unavailable[frame.url].map(RollDeveloper.Outcome.failed) ?? byFrame[frame.url] ?? .stopped }
            developer.trim()
            // The sheet's film passes, let go for the develop, ready again for a stock switch.
            Task.detached(priority: .utility) { try? films.prepareStocks() }
            await self.adoptDevelopedRecipes(frames, outcomes)
            self.finishDevelop(frames, outcomes, folder: folder, destination: destination, inputs: inputs, before: developedBefore)
        }
    }

    /// The recipes a develop's receipts went into become the session's: the next develop in it
    /// starts from them, so an output a frame's develop replaced is still the frame's own and
    /// skipped, not developed again under a number, and a frame that had no recipe before now
    /// has one later choices are saved to (`saveManualChoices`).
    func adoptDevelopedRecipes(_ frames: [Frame], _ outcomes: [RollDeveloper.Outcome]) async {
        let generation = manualGeneration
        for (frame, outcome) in zip(frames, outcomes) {
            guard case .developed = outcome, manualLoaded.contains(frame.url) else { continue }
            guard let recipe = try? await RecipeWriter.shared.load(for: frame, library: recipeLibrary), generation == manualGeneration else { continue }
            if manualRecipes[frame.url]?.editRevision ?? 0 <= recipe.editRevision ?? 0 { manualRecipes[frame.url] = recipe }
        }
    }

    /// Room for a develop's full-size textures: what the sheet can make again quickly goes.
    func trimForDevelop() {
        smartMasks.inference?.developWillStart()
        films?.trimForDevelop()
        thumbnails.removeFullSize()
    }

    private func frameDeveloped(_ raw: URL?, _ outcome: RollDeveloper.Outcome) {
        if case .developing(var progress) = developPhase {
            progress.record(outcome)
            developPhase = .developing(progress)
            if let raw { developOutcomes[raw] = outcome }
        }
    }

    private func finishDevelop(_ frames: [Frame], _ outcomes: [RollDeveloper.Outcome], folder: DevelopFolder, destination: URL, inputs: DevelopInputs,
                               before: [URL: DevelopedFrame]) {
        let report = DevelopReport(frames: frames, outcomes: outcomes, destination: destination)
        for failure in report.failures {
            Self.developLog.error("\(failure.fileName, privacy: .public): \(failure.reason, privacy: .public)")
        }
        noteDeveloped(frames, outcomes, destination: destination, inputs: inputs, before: before)
        recordDevelop(report, inputs: inputs)
        // A folder the sandbox reaches only through the panel's grant stays the roll's after a relaunch.
        if folder.usesSubfolder { rememberDestination(folder.base) }
        rememberDestination(destination, forRoll: roll?.folder, usesSubfolder: folder.usesSubfolder)
        if !report.wasStopped, !ProcessInfo.isRunningTests, !NSApp.isActive { notifyDeveloped(report) }
    }

    /// Keeps what came of each frame of a develop that has ended, for the Develop page's marks: a frame with a
    /// file, written now or found from the same recipe, is checked from what the develop was made from
    /// (`inputs`); one that failed has no file to check; one the develop was stopped before keeps the check it
    /// had (`before`), since its file from an earlier develop is still its develop.
    func noteDeveloped(_ frames: [Frame], _ outcomes: [RollDeveloper.Outcome], destination: URL, inputs: DevelopInputs,
                       before: [URL: DevelopedFrame] = [:]) {
        developOutcomes = Dictionary(zip(frames.map(\.url), outcomes), uniquingKeysWith: { first, _ in first })
        for (frame, outcome) in zip(frames, outcomes) {
            switch outcome {
            case .developed, .alreadyDeveloped:
                developedFrames[frame.url] = DevelopedFrame(inputs, frame: frame.url, destination: destination)
            case .failed: developedFrames[frame.url] = nil
            case .stopped: developedFrames[frame.url] = before[frame.url]
            }
        }
    }

    /// Applies the result to the window. Only a result whose settings and raws still match the
    /// roll offers Reveal in Finder in place of Develop.
    func recordDevelop(_ report: DevelopReport, inputs: DevelopInputs) {
        // A raw already written can change while the rest of the roll is developing, including
        // between the source watcher's last poll and this completion.
        forgetChangedSources()
        // The Develop page names the frames that failed, and marks each frame with what came of it.
        lastDevelop = report
        areIssuesDismissed = false
        // A stopped develop is resumed with Resume, and one that wrote nothing is tried again with
        // Develop; changed choices or raws of its own frames still need their own develop. Its own:
        // a Resume's frames need not be those shown, nor need a develop's once the filter changed.
        // A develop of one frame leaves other frames shown undeveloped, so the button stays Develop.
        developPhase = report.wasStopped || report.files.isEmpty || DevelopInputs(self, frames: report.raws) != inputs || isOneFrameOfSeveralShown(report)
            || isChosenOfSeveralShown(report) ? .idle : .done
        // A stopped develop of them is theirs still when Resume goes on with it.
        if !report.wasStopped { chosenDevelop = nil }
        developTask = nil
        // Source changes observed during a develop clear measurements without starting another
        // batch beside the export. Resume those measurements now, including frames off screen.
        if roll?.frames.contains(where: { !isMeasured($0) }) == true { analyzeRoll() }
    }

    /// A develop of one frame while the sheet shows others is Develop This Frame's; the other frames
    /// shown are not developed, so the button stays Develop.
    private func isOneFrameOfSeveralShown(_ report: DevelopReport) -> Bool {
        guard report.raws.count == 1, let raw = report.raws.first else { return false }
        return shownFrames.contains { $0.url != raw }
    }

    /// A develop of the frames selected (`developFrames`) while the sheet shows others too leaves those undeveloped, as
    /// Develop This Frame does, so the button stays Develop.
    private func isChosenOfSeveralShown(_ report: DevelopReport) -> Bool {
        guard let chosen = chosenDevelop, chosen == Set(report.raws) else { return false }
        return shownFrames.contains { !chosen.contains($0.url) }
    }

    /// The Develop page's mark on each frame, by file. A check on a frame a develop of this session has a file
    /// for, while a develop would still find that file and skip the frame: in the folder a develop goes to now,
    /// and from the stock, roll controls, output choices (with the frame's own grain) and settled Auto it was made
    /// from, with the frame's own controls, edit and raw unchanged. So another format or folder takes every check, an edit to one frame
    /// takes that frame's, and undoing either gives them back. The frames of a develop under way start with none
    /// and take theirs as each ends; a frame the last develop could not write is marked until the next one.
    var developMarks: [URL: DevelopMark] {
        var marks: [URL: DevelopMark] = [:]
        if !developedFrames.isEmpty, let folder = developDestination {
            let revision = isBalanced ? autoDecision?.revision : nil
            for (raw, made) in developedFrames
            where made.destination == folder && made.stockIndex == stockIndex && made.controls == controls
                && made.output == output.grain(overrides[raw]?.grain) && made.autoRevision == revision && made.own == overrides[raw]
                && made.edit == manualEdits[raw] && made.source == sourceVersions[raw] {
                marks[raw] = .developed
            }
        }
        if isDeveloping {
            for (raw, outcome) in developOutcomes {
                if outcome.file != nil { marks[raw] = .developed } else if case .failed = outcome { marks[raw] = .failed }
            }
        } else if let report = lastDevelop {
            for failure in report.failures { marks[failure.frame.url] = .failed }
        }
        return marks
    }

    /// The rail's Develop item away from its page: how far a develop under way is, for its ring.
    var developFraction: Double? {
        if case .developing(let progress) = developPhase { return progress.fraction }
        return nil
    }

    /// The rail's Develop item away from its page: a develop stopped or left frames behind, and its status
    /// on the page has not been closed.
    var developWantsAttention: Bool {
        !isDeveloping && !areIssuesDismissed && lastDevelop?.isUnfinished == true
    }

    /// Stops after the frames already decoding.
    func stopDevelop() {
        developTask?.cancel()
    }

    func revealDeveloped() {
        guard let summary = lastDevelop else { return }
        if summary.files.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([summary.destination])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(summary.files)
        }
    }

    /// The one notification the app sends: a develop finished while the window was in the
    /// background. Provisional, so it goes quietly to Notification Center without asking.
    private func notifyDeveloped(_ report: DevelopReport) {
        let center = UNUserNotificationCenter.current()
        let rollName = roll?.name ?? "The roll"
        let body = DevelopProgress(report).label
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .provisional])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = rollName
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
