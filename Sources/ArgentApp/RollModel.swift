import ArgentCore
import ArgentRoll
import AppKit
import Foundation
import Observation
import os

/// The open roll and everything the window shows about it.
@MainActor @Observable
final class RollModel {
    private(set) var roll: Roll? { didSet { noteSelectionFlag() } }
    private(set) var isScanning = false
    /// One line when a drop or an open did not give a roll: under the empty state, or in the
    /// bar over the roll when one is open.
    var message: String?
    /// The frames selected on the sheet and their lead (`MultiSelection`, RollModel+Selection): one after a click or an
    /// arrow, several after a Command-click, a Shift-click, a Shift-arrow or Select All. What a frame's menu, Flag, Paste
    /// Adjustments, Develop, Move to Roll and Remove from Roll act on. Another lead opens fitted.
    private(set) var picked = MultiSelection<Frame.ID>() {
        didSet {
            if picked.lead != oldValue.lead {
                if case .frame = halationAdjusting { suspendHalationAdjusting(writing: true) }
                curveGraphFocusRequest = nil
                if inspectorNavigation.destination != nil { inspectorNavigation.clearDestination() }
                if frameZoom != FrameZoom() { frameZoom = FrameZoom() }
                maskEditor.reset()
                // A selection painted on one frame is never another's.
                if remove.frame != nil { removeTabHidden() }
            }
            noteSelectionFlag()
        }
    }
    /// The frame the keys and the frame view act on: the one last clicked or moved to, the lead of the frames selected.
    /// Setting it leaves that frame alone selected, so only the sheet's own extending of the selection selects several.
    var selection: Frame.ID? {
        get { picked.lead }
        set { changeSelection { $0.selectAlone(newValue) } }
    }
    /// The frames selected, the lead among them.
    var selected: Set<Frame.ID> { picked.items }

    /// Changes the frames selected as `change` says. Written only when it differs, so setting the selection to what it
    /// is redraws nothing; its facts for the menu bar are noted either way, as a set of `selection` always noted them.
    func changeSelection(_ change: (inout MultiSelection<Frame.ID>) -> Void) {
        var next = picked
        change(&next)
        if next != picked { picked = next } else { noteSelectionFlag() }
    }
    /// The frame the selection was on when the filter left the sheet empty, so it comes back near there.
    @ObservationIgnored var selectionAnchor: Frame.ID?
    /// Which frames the sheet shows and Develop develops (RollModel+Flags): every frame whenever a roll
    /// opens, since it is the window's and never kept.
    var flagFilter = FlagFilter.all { didSet { if flagFilter != oldValue { shownFramesChanged() } } }
    /// The roll's flagged frames, by file, each with the raw it was flagged as (`FlagRecord.Entry`).
    var flagged: [URL: FlagRecord.Entry] = [:] { didSet { noteSelectionFlag() } }
    /// Whether a frame is selected, its raw known and flagged, for Frame > Flag; changed only when one
    /// of them does, so the menu bar is not rebuilt at each arrow press on the sheet.
    var selectionFlag = SelectionFlag()
    /// Kept flags no frame of the roll matches now, such as another card's at the same path: saved
    /// with the roll's own.
    @ObservationIgnored var otherFlags: [FlagRecord.Entry] = []
    /// The roll's flags file is one this build cannot read, or a later build's: flags change for the
    /// session and are not saved.
    @ObservationIgnored var areFlagsUnsaved = false
    /// Where each roll's flags are kept, and the latest write of them.
    @ObservationIgnored let flagStore: FlagStore
    @ObservationIgnored var flagSave: Task<Void, Never>?
    /// Index into `Metrics.thumbnailWidths`.
    private(set) var sizeStep = 1 { didSet { if sizeStep != oldValue { sizeStepChanged = CACurrentMediaTime() } } }
    /// When the size step last changed: the sheet's cells glide to their new size for a moment after (`SheetGrid`), and a
    /// cell's film made for that size waits for the glide's end (`FrameCell`).
    @ObservationIgnored private(set) var sizeStepChanged: CFTimeInterval = 0
    /// The 18 percent gray proofing surround, from the View menu.
    var graySurround = false
    var isImporting = false
    /// Where the open panel starts: a card the app may not list, or the system's choice.
    var importDirectory: URL?
    var isDropTargeted = false
    /// Index into `stockNames`, in library order; Portra 400 is the default.
    var stockIndex = 0 { didSet { settingsChanged() } }
    /// The roll's Rated at and Lab balance: box speed and Auto for a new roll, as its recipes
    /// left them for a roll developed before.
    var controls = RollControls() { didSet { settingsChanged() } }
    /// Each frame's auto-development measurement, keyed by file, as it arrives from its sheet
    /// decode; a frame's settings include it.
    private(set) var analyses: [URL: ExposureAnalysis] = [:] { didSet { refreshAims() } }
    /// Frames whose measurement failed for good, by the version of the raw that failed: they print
    /// at `PrintAim()` and count as measured, so one unreadable frame cannot keep the roll from
    /// settling (RollModel+Auto).
    var measurementFailures: [URL: MeasurementFailure] = [:]
    /// Each measured frame's sequence descriptor, from the same sheet decode as its measurement, for
    /// a method that matches frames by them; not observed, and not kept past the roll.
    @ObservationIgnored var descriptors: [URL: SequenceDescriptor] = [:]
    /// Each measured frame's print aim, what its settings follow: the roll's settled decision, and
    /// until the roll settles each frame's own (RollModel+Auto).
    var printAims: [URL: PrintAim] = [:]
    /// The roll's last settled Auto decision, and whether it is for the roll as it is now: every
    /// frame measured or failed, nothing changed since (RollModel+Auto).
    var autoDecision: AutoDecisions.Decision?
    var isBalanced = false
    /// The settled decision's aims, less those of frames whose raw has changed since.
    @ObservationIgnored var decidedAims: [URL: PrintAim] = [:]
    /// Resolving the roll's snapshot off the main actor, and what invalidates it: any change of
    /// the decision's inputs counts one more.
    @ObservationIgnored var balanceTask: Task<Void, Never>?
    @ObservationIgnored var balanceGeneration: UInt64 = 0
    /// Where settled decisions are kept, and the latest write of one.
    @ObservationIgnored let decisions: AutoDecisionStore
    @ObservationIgnored var decisionSave: Task<Void, Never>?
    /// A develop is waiting for the roll's settled decision; its status row says so.
    var isDevelopBalancing = false
    /// The output and stocks captured for the running develop, independent of later selection changes.
    var runningDevelopSummary = ""
    /// Measures a frame in place of the previews, for tests that choose what each measurement comes
    /// to and when it arrives; and what a settled decision and a develop's jobs were, for tests.
    @ObservationIgnored var measureFrame: ((Frame) async -> FilmPreviews.MeasurementOutcome)?
    @ObservationIgnored var observeAutoDecision: ((AutoDecisions.Decision) -> Void)?
    @ObservationIgnored var observeDevelopJobs: (([RollDeveloper.Job]) -> Void)?
    /// Asks what to do about adjustments that could not be saved before the roll goes, as another roll
    /// opens or the app quits: the alert, or a test's own answer.
    @ObservationIgnored var askAboutUnsavedAdjustments: @MainActor (UnsavedAdjustments) -> UnsavedAdjustments.Answer = UnsavedAdjustments.alert
    /// Asks whether to quit while frames' adjustments cannot be saved at all, a mask's seed missing (`maskSeedUnsaved`): the alert,
    /// or a test's own answer.
    @ObservationIgnored var askAboutUnsavableAdjustments: @MainActor (UnsavableAdjustments) -> UnsavableAdjustments.Answer = UnsavableAdjustments.alert
    /// The version of each frame's raw its measurement in `analyses` was made from or checked
    /// against, so a raw written over or replaced while the roll is open is measured again.
    @ObservationIgnored private(set) var measuredFrom: [URL: SourceStamp] = [:]
    /// Versions paired with the headers on screen; preview task identities observe them.
    private(set) var sourceVersions: [URL: SourceStamp] = [:] { didSet { noteSelectionFlag() } }
    @ObservationIgnored private var seenSources: [URL: SourceStamp] = [:]
    @ObservationIgnored private var sourceRefreshTask: Task<Void, Never>?
    /// Measures the whole roll in the background, so roll smoothing sees every frame.
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    /// Frames with their own Rated at or Lab balance, set from the frame view, keyed by file. A paste and its Undo write every
    /// frame's at once (`RollModel+Clipboard`), since each write saves the roll's choices again.
    var overrides: [URL: FrameControls] = [:] { didSet { settingsChanged() } }

    /// Frame refinements, kept separately from the untouched automatic measurements.
    var manualEdits: [URL: ManualEdit] = [:]
    var heldManualEdits: [URL: ManualEdit] = [:]
    var manualErrors: [URL: String] = [:]
    var manualPreparationErrors: [URL: String] = [:]
    /// The smart masks' seeds a frame's edit names that were found damaged when its recipe was read (`verifyMaskSeeds`).
    var maskSeedDamage: [URL: Set<RasterID>] = [:]
    /// Every seed an undo or redo step of this session names, so a sweep run while the session lasts keeps them; emptied with
    /// the undo history (`clearManualSession`).
    @ObservationIgnored var undoSeeds: Set<RasterID> = []
    /// Every removal's patch an undo or redo step of this session names, kept as the seeds are (`sweepPatches`).
    @ObservationIgnored var undoPatches: Set<PatchID> = []
    /// Frames whose latest save the writer refused because their edit names a seed that is nowhere: the edit stays here, unsaved,
    /// and the frame's own issue says why. Not a failure of the session's saves, so no other frame's save or develop waits on it;
    /// saved again by the next save of the frame, Retry, and the flush before a develop or a quit (`saveManualFrame`).
    var maskSeedUnsaved: Set<URL> = []
    var manualReadySources: [URL: SourceDigests.Verified] = [:]
    var visibleAutomatic: [URL: VisibleAutomatic] = [:]
    var manualRecipes: [URL: Recipe] = [:]
    /// Each frame's own edit lineage, kept while a changed RAW holds its edit, so its saves go on
    /// with it rather than with the roll's.
    var manualLineages: [URL: String] = [:]
    var manualLoaded: Set<URL> = []
    var editRevision: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    var isRestoringManual = false
    var isQuitting = false
    /// Sparkle 2 over-the-air updater; inactive until `AppDelegate.attach(_:)` starts it in eligible builds.
    let updates = UpdateController()
    var editLineage = UUID().uuidString
    var manualSaveMessage: String?
    var manualSaveFailed = false
    var manualSaveFailures: [URL: ManualSaveFailure] = [:]
    var isComparingAuto = false
    var isAutoComparisonReady = false
    /// Lightroom's clipping view over the frame view's film, while Option is held as a Light slider
    /// moves (`AdjustmentSliderControl.onClipping`). A view only: never saved, never rendered.
    var lightClipping: LightClipping?
    /// The Light control whose tonal range the inspector's histogram lights: the one whose row the pointer is over, or whose
    /// range of the histogram it is over or dragging (`InspectorHistogram`). Only the histogram reads it.
    var histogramZone: ManualAdjustments.Control?
    var curveHistogram: CurveHistogram?
    var curveHistogramFrame: URL?
    /// The film the frame view shows, measured for the Adjust inspector's histogram, and whose it is.
    var frameHistogram: FrameHistogram?
    var frameHistogramFrame: URL?
    var isAdjustmentsShown = UserDefaults.standard.bool(forKey: "manualInspectorShown") {
        didSet {
            UserDefaults.standard.set(isAdjustmentsShown, forKey: "manualInspectorShown")
            if !isAdjustmentsShown {
                if inspectorNavigation.destination != nil { inspectorNavigation.clearDestination() }
                endInspectorInteraction()
                maskEditor.reset()
                if remove.frame != nil { removeTabHidden() }
            }
        }
    }
    var inspectorNavigation = AdjustInspectorNavigation(preferredSection: .stored()) {
        didSet {
            if inspectorNavigation.preferredSection != oldValue.preferredSection {
                UserDefaults.standard.set(inspectorNavigation.preferredSection.rawValue, forKey: AdjustInspectorTab.storageKey)
            }
            guard openAdjustSection != oldValue.openSection else { return }
            histogramZone = nil
            lightClipping = nil
            curveGraphFocusRequest = nil
            maskEditor.reset()
            if oldValue.openSection == .remove, remove.frame != nil { removeTabHidden() }
        }
    }
    var openAdjustSection: AdjustInspectorTab? { inspectorNavigation.openSection }
    /// The preferred section and the entry point used by the existing menu commands and drive hook.
    var adjustTab: AdjustInspectorTab {
        get { inspectorNavigation.preferredSection }
        set { inspectorNavigation.open(newValue) }
    }
    var isInspectorPresenceExpanded = false
    var isInspectorDefringeExpanded = false
    /// The masks tool's interface state: its own object, so its changes reach only what reads them.
    let maskEditor = MaskEditor()
    /// Smart masks' selections under way and what they came to (`RollModel+SmartMasks`).
    let smartMasks = SmartMasks()
    /// The mask models' licence screen and download (`MaskModelsSheet`).
    let maskModels = MaskModelsDownload()
    /// The Remove tab's state that is not in the frame's edit (`RemoveState.swift`).
    let remove = RemoveSession()
    /// Remove's steps, its runs under way and what its patches say of themselves (`RollModel+Remove`).
    let removalRuns = RemovalRuns()
    /// View > Curve Adjustments asks the curve graph to take keyboard focus once it shows.
    var curveGraphFocusRequest: CurveGraphFocusRequest?
    /// The page the rail asked the workspace for (RollModel+Workspace): the roll, its Develop page, the
    /// Rolls page or Settings. A roll opening shows the roll.
    var requestedPage = WorkspacePage.roll {
        didSet { if requestedPage != oldValue, workspacePage != .roll { endInspectorInteraction() } }
    }
    /// The Develop page was opened from the frame view, which closing the page goes back to.
    @ObservationIgnored var developPageReturnsToFrame = false
    /// The stock panel over the bottom of the workspace, in place of its dock (Stock in the rail).
    var isStockPanelShown = false
    /// The frame view's split comparison: the neutral raw left of a divider the pointer moves,
    /// film right of it, in one picture so the two keep one geometry, zoom and pan.
    var isSplitComparing = false
    /// Where the split comparison's divider stands, as a fraction of the frame view's width.
    var splitPosition: CGFloat = 0.5
    /// What Copy Adjustments last took (RollModel+Clipboard): the app's own, kept until another copy or the app
    /// quits, and not the system pasteboard's.
    var adjustmentsClipboard: AdjustmentsClipboard?
    /// The line a copy or a paste leaves at the workspace's top for a moment, and what takes it away.
    var clipboardNotice: ClipboardNotice?
    @ObservationIgnored var clipboardNoticeTask: Task<Void, Never>?
    /// The notice is being reached for, with the pointer on it or its Details open, so a line that takes its place
    /// stays until it is let go.
    @ObservationIgnored var isClipboardNoticeHeld = false
    /// The paste waiting for its frames to be ready, and what it came to; a paste asked for meanwhile waits for it.
    @ObservationIgnored var pasteTask: Task<PasteReport?, Never>?
    /// Watches the undo manager while the notice offers a paste's Undo: any later step, an undo or a redo takes the offer away.
    @ObservationIgnored var pasteUndoWatch: (any NSObjectProtocol)?
    /// The window's undo manager, where manual edits and flags (RollModel+Flags) register their Undo.
    @ObservationIgnored var manualUndoManager: UndoManager?
    @ObservationIgnored var manualGestures: [URL: ManualUndoState] = [:]
    @ObservationIgnored var manualSaveTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored var manualRestoreTask: Task<Void, Never>?
    @ObservationIgnored var manualGeneration = UUID()
    @ObservationIgnored var manualChoicesChangedDuringRestore = false
    @ObservationIgnored var isApplyingRestoredChoices = false

    /// Where a develop stands; see RollModel+Develop. While a develop runs the previews' decodes take
    /// turns with its frames and the frame view's decode is not refined (`FilmPreviews.isDevelopRunning`).
    var developPhase: DevelopPhase = .idle {
        didSet { films?.isDevelopRunning = isDeveloping }
    }
    /// What the last develop of this roll did, for Reveal in Finder, the subtitle and the
    /// Develop page's status; kept until the next develop finishes or another roll opens.
    var lastDevelop: DevelopReport?
    /// The frames this session's develops have a file for, by file, each with what it was developed from
    /// (`DevelopedFrame`): the Develop page's checks (`developMarks`), kept from one develop to the next,
    /// so a develop of the flagged frames and then of the others leaves every frame checked.
    var developedFrames: [URL: DevelopedFrame] = [:]
    /// What has come of each frame of the develop running, or came of the last one's, by file: the
    /// Develop page's marks on a running develop's frames. A frame it has not reached has none.
    var developOutcomes: [URL: RollDeveloper.Outcome] = [:]
    /// A stopped or failed develop's status was closed on the Develop page, which hands its button back
    /// to Develop; it comes back when a develop finishes or a roll opens.
    var areIssuesDismissed = false
    /// The open roll's unreadable raws as they were when their notice was closed (RollModel+OpenRoll).
    var dismissedUnreadable: [URL]?
    /// The Develop page's details, the frames not developed and the raws not read.
    var isIssueDetailsShown = false
    /// The folder selected for this roll, or restored from its last develop.
    var chosenDevelopFolder: DevelopFolder?
    /// The quick develop dialog over the roll, while it is up (RollModel+QuickDevelop): the frames a menu's Develop was
    /// asked for, with the folder and the output choices as the dialog has them, which are the roll's and every roll's
    /// only once its Develop is pressed.
    var quickDevelop: QuickDevelop? {
        didSet {
            let isUp = quickDevelop != nil
            if isUp != isAskingToDevelop { isAskingToDevelop = isUp }
        }
    }
    /// The quick develop dialog is up: set only as it comes and goes, never at a choice made in it, so the menu bar,
    /// which disables on it what would act on the roll under the dialog, is not asked again at each (`MenuState`).
    private(set) var isAskingToDevelop = false
    /// A modal sheet is up over the workspace (Quick Develop or the mask models' licence screen): keys and menus leave
    /// the roll and frame under it alone.
    var isSheetShown: Bool { isAskingToDevelop || maskModels.isShown }
    /// The launch sweep removing any orphaned `.install-*` folders beside the downloaded models, awaited before a download starts.
    @ObservationIgnored var maskModelStagingSweep: Task<Void, Never>?
    var importSettings = ImportSettings(defaults: .standard) {
        didSet {
            importSettings.save(to: .standard)
            importSettingsChanged(from: oldValue)
        }
    }
    /// An import that takes the workspace from the roll takes the quick develop dialog with it. A copy goes on behind
    /// the roll when the roll is asked for (`workspacePage`), and sets the session at each frame copied: the dialog stays.
    var importSession = ImportSession.idle {
        didSet {
            if workspacePage != .roll {
                endInspectorInteraction()
                if quickDevelop != nil { quickDevelop = nil }
            }
        }
    }
    /// The import under way reads a folder chosen in the open panel rather than a card: its frames are "left in the
    /// folder", and its roll may be made on the folder's disk.
    var importsFolder = false
    @ObservationIgnored var importTask: Task<Void, Never>?
    @ObservationIgnored var importRun = 0
    @ObservationIgnored let importThumbnails = ThumbnailLoader(costLimit: 128 << 20, largeCostLimit: 0)
    @ObservationIgnored var keeperCopy: CopyKeepers = { try await KeeperCopy.run($0, to: $1, progress: $2) }
    /// The copy for an import from a folder, whose roll may be made on the folder's own disk.
    @ObservationIgnored var folderKeeperCopy: CopyKeepers = { try await KeeperCopy.run($0, to: $1, allowsRawsVolume: true, progress: $2) }
    /// Format, quality, colour space and grain, kept as the defaults for every roll.
    var output = RollModel.savedOutput() {
        didSet {
            saveOutput()
            // Quality is the file's alone, in no recipe's settings or Auto's controls: a drag of its
            // slider only turns Reveal back into Develop, without saving each frame's choices again.
            var others = output
            others.quality = oldValue.quality
            if others == oldValue {
                if developPhase == .done { developPhase = .idle }
            } else {
                settingsChanged()
            }
        }
    }
    /// Frames are on their way out of the roll, to the Trash or to another roll, and what the notice says of it
    /// (RollModel+Frames): nothing else that changes the roll's frames starts meanwhile.
    var frameMove: String?
    @ObservationIgnored var frameMoveTask: Task<Void, Never>?
    /// The frames whose files are on their way, by file: none is saved meanwhile (`saveManualFrame`), since its recipe
    /// would be written beside a raw that has gone.
    @ObservationIgnored var movingFrames: Set<URL> = []
    /// Whether the open roll's frames may leave it, and its folder's path as the library names it, asked of the disk once
    /// a roll (`rollAllowsChangingFrames`, `moveTargets`).
    @ObservationIgnored var changeableRoll: (folder: URL, allows: Bool, path: String)?
    /// Asks before frames go to the Trash, and asks a new roll's name: the alerts, or a test's own answers.
    @ObservationIgnored var askAboutRemovingFrames: @MainActor (FrameRemoval) -> Bool = FrameRemoval.alert
    @ObservationIgnored var askForNewRollName: @MainActor (String) -> String? = RollModel.askNewRollName
    /// Moves raws to the Trash with their recipes: the system's Trash, or a test's own folder.
    @ObservationIgnored var trashFrames: @Sendable ([URL]) -> [FrameFiles.Outcome] = { FrameFiles.trash($0) }
    /// The frames a develop of the frames selected was asked for (`developFrames`), until it ends.
    @ObservationIgnored var chosenDevelop: Set<URL>?
    /// The user's develop memory choice, read when each develop starts.
    @ObservationIgnored let developMemory: DevelopMemorySettings
    @ObservationIgnored var developer: RollDeveloper?
    @ObservationIgnored var developTask: Task<Void, Never>?
    /// The frame view is showing the selected frame, in place of the contact sheet.
    private(set) var isFrameOpen = false {
        didSet {
            if !isFrameOpen {
                endInspectorInteraction()
                if inspectorNavigation.destination != nil { inspectorNavigation.clearDestination() }
                maskEditor.reset()
                if remove.frame != nil { removeTabHidden() }
                if isSheetScrolledSinceClose { isSheetScrolledSinceClose = false }
            }
        }
    }
    /// The roll's contact sheet, while it is up: the frame view grows from the selected frame's well there, and asks it
    /// where that is (`FrameHero`).
    @ObservationIgnored weak var sheetGrid: SheetGridController?
    /// The sheet has been scrolled since the frame was closed, by hand or by the keys to a frame out of its view. The
    /// frame view on its way out goes to where its cell was as the frame was closed, and is there until it has left the
    /// window: over a sheet scrolled from under it, it is not drawn (`FrameHero`).
    private(set) var isSheetScrolledSinceClose = false
    /// When the selection last moved in the frame view, for the picture's short fade to the next frame, which a held arrow
    /// key does without (`FramePicture`).
    @ObservationIgnored var lastFrameStep: CFTimeInterval = 0
    /// What the frame view last showed and of which frame, while it is open, for the next frame to fade in over.
    @ObservationIgnored var framePictureShown: (frame: URL, image: CGImage)?
    /// The frame view's context-aware ambient surround, kept outside observation so slider drags
    /// and zoom gestures update the Metal backdrop directly without relayouting the workspace.
    @ObservationIgnored let frameSurround = FrameSurroundController()
    /// Space is held in the frame view: show the neutral raw instead of film.
    var isComparing = false
    /// The frame view is showing the neutral raw now, which it can only once the raw is decoded.
    var isNeutralShown = false
    /// Where the frame view puts its frame, while it is open; the stock panel takes its
    /// pictures of that frame from the frame view's decode, so the two share one.
    @ObservationIgnored var frameLayout: FrameLayout?
    /// How far the frame view is zoomed into its frame, and where (View > Zoom In, pinch).
    var frameZoom = FrameZoom()
    /// What the frame view's zoom works within, while it is open.
    @ObservationIgnored var frameZoomRoom: FrameZoom.Room?
    /// The direction of the last move through the roll in the frame view, +1 or -1, so the
    /// next frame that way is decoded ahead.
    private(set) var travel = 1
    /// The stocks' names in library order, empty when no stock could be loaded.
    @ObservationIgnored let stockDigests: [String]
    let stockNames: [String]
    /// Each stock's line naming the film it models ("After Kodak Portra 400: ..."), in the same
    /// order and of the same length. It is the help tag of the stock panel's tile and of
    /// the Stock menu's item, and the end of the chip's VoiceOver hint.
    let stockAfterLines: [String?]

    @ObservationIgnored let thumbnails = ThumbnailLoader()
    /// The pixel sizes the contact sheet's and the stock panel's cells have asked thumbnails at,
    /// so the frame view can open on the largest one already in memory.
    @ObservationIgnored var cellPixelSizes: Set<Int> = []
    /// Film renders of the roll; `nil` without stocks, and then the sheet shows previews only.
    @ObservationIgnored let films: FilmPreviews?
    @ObservationIgnored private var accessedFolder: URL?
    /// The newest open under way, until it installs its roll or finds none.
    @ObservationIgnored private var opening: OpenRequest?

    /// Cards on offer, oldest first; see RollModel+Places.
    var cards: [Card] = []
    /// Cards imported, by volume path, until they are ejected.
    var importedCards: Set<String> = []
    /// Cards turned down, by volume path, until they are ejected.
    @ObservationIgnored var dismissedCards: Set<String> = []
    @ObservationIgnored var volumeObservers: [NSObjectProtocol] = []
    /// File > Open Recent, most recent first.
    var recents: [BookmarkStore.Recent] = []
    @ObservationIgnored let bookmarks: BookmarkStore
    /// The Rolls page's rolls, as `bookmarks` keeps them (RollModel+Library).
    var library: [BookmarkStore.LibraryRoll] = []
    /// Each library roll's covers, by its id, once read; a roll with none has an empty list.
    var rollCovers: [UUID: [CGImage]] = [:]
    /// Library rolls whose folders could not be reached when last checked.
    var unavailableRolls: Set<UUID> = []
    @ObservationIgnored var libraryAvailabilityTask: Task<Void, Never>?
    /// The rolls whose covers are being read from their folders, so none is read twice at once.
    @ObservationIgnored var coverReads: Set<UUID> = []
    @ObservationIgnored var pendingCoverScans: [() -> Void] = []
    @ObservationIgnored var activeCoverScans = 0
    @ObservationIgnored var libraryCoverPreparation: Task<[Task<Void, Never>], Never>?
    @ObservationIgnored var libraryCoverReader: @Sendable (URL) -> RollCoverStore.Read? = { RollCoverStore.read($0) }
    /// Where each library roll's covers are kept: Caches', or a test's own beside its preview cache.
    @ObservationIgnored let coverStore: RollCoverStore
    /// The Rolls page's Import roll sheet, where a card, a drive or a folder is chosen.
    var isImportSourceShown = false
    /// The removable drives without a camera card's folders, which the Import roll sheet offers to choose a folder on.
    var drives: [ImportDrive] = []
    /// What the last import came to, on the Rolls page until closed or another import begins.
    var importNotice: ImportNotice?
    /// The covers of the frames an import is copying, read from its source as the copy begins.
    var importCovers: [CGImage] = []
    /// The library roll being renamed on the Rolls page.
    var renamingRoll: UUID?
    /// Where the recipe writer keeps the working recipes: Application Support's, or a test's own.
    @ObservationIgnored let recipeLibrary: URL
    /// A destination reached through its bookmark, accessed while its roll is open.
    @ObservationIgnored var accessedDestination: URL?

    private static let log = Logger(subsystem: "camera.argent.Argent", category: "stocks")

    /// `decisions` keeps each roll's settled Auto decision and `flagStore` its flags; tests give their
    /// own, outside Application Support. `previewCache` keeps the sheet's decodes on disk and
    /// `digestsFile` the raws' SHA-256, both in Caches; tests give a folder of their own and no file,
    /// as `SourceDigests.shared` is the whole process's and a test's file would be every test's.
    init(bookmarks: BookmarkStore = BookmarkStore(), stocksDirectory: URL? = nil, decisions: AutoDecisionStore = AutoDecisionStore(),
         flagStore: FlagStore = FlagStore(), recipeLibrary: URL = RecipeStore.defaultLibrary,
         previewCache: URL = LinearDiskCache.defaultFolder, digestsFile: URL? = SourceDigests.defaultFile,
         developMemory: DevelopMemorySettings = .shared) {
        self.bookmarks = bookmarks
        coverStore = RollCoverStore(folder: previewCache.deletingLastPathComponent().appendingPathComponent("Roll Covers", isDirectory: true))
        self.decisions = decisions
        self.flagStore = flagStore
        self.recipeLibrary = recipeLibrary
        self.developMemory = developMemory
        let directory = stocksDirectory ?? Self.stocksDirectory()
        let library = directory.map(StockLibrary.load(from:))
        for failure in library?.failures ?? [] {
            Self.log.error("stock \(failure.folder, privacy: .public) not loaded: \(failure.reason, privacy: .public)")
        }
        let stocks = library?.stocks ?? []
        var films: FilmPreviews?
        do {
            // The removals' pixels come from the library, as the masks' seeds do below.
            films = stocks.isEmpty ? nil : try FilmPreviews(stocks: stocks, diskCache: LinearDiskCache(folder: previewCache),
                                                             patches: PatchStore(library: recipeLibrary).source(),
                                                             learnedDecodeTile: developMemory.resolvedLearnedDecodeTile())
            // The raws' SHA-256 kept across launches, so an unchanged roll is not read whole again; without
            // a file, in memory only.
            if let digestsFile { SourceDigests.shared.persist(to: digestsFile) }
        } catch {
            Self.log.error("film previews unavailable: \(String(describing: error), privacy: .public)")
        }
        if stocks.isEmpty { Self.log.error("no stocks found; the sheet shows embedded previews only") }
        // Smart masks' seeds for the frame view, the sheet and the strip: the library's, each checked against its name as it loads, as
        // a develop's lane checks the seeds it holds (`RollDeveloper`). One loader for the session: the overlay and the pins read
        // through it too (below), so a seed's PNG is read, checked and kept once for the three.
        let maskSeeds = StoredMaskSeeds(store: MaskRasterStore(library: recipeLibrary))
        films?.maskSeeds = maskSeeds
        self.films = films
        self.stockDigests = stocks.map(\.digest)
        self.stockNames = films?.stocks.map(\.displayName) ?? []
        self.stockIndex = films?.stocks.firstIndex(where: { $0.id == "kodak-portra-400" }) ?? 0
        self.stockAfterLines = films?.stocks.map(\.afterLine) ?? []
        recents = bookmarks.recents
        self.library = bookmarks.rolls
        maskEditor.model = self
        smartMasks.makeInference = { [weak self] in self?.makeMaskInference() }
        let modelsFolder = downloadedModelsFolder
        maskModels.folder = { modelsFolder }
        maskModels.beforeStart = { [weak self] in await self?.maskModelStagingSweep?.value }
        maskModels.onInstalled = { [weak self] in self?.smartMasks.modelsChanged() }
        removalRuns.makeSteps = { [weak self] in self?.makeRemovalSteps() }
        (maskEditor.overlay.field as? MaskSeedCoverage)?.seeds = maskSeeds
        (maskEditor.overlay.field as? MaskSeedCoverage)?.refined = films
        // The pins' points are found on the seeds as stored, from the same library.
        maskEditor.pinSeeds.load = { try? maskSeeds.seed(for: $0) }
        if let films {
            developMemory.onChoiceChange { [weak self, weak films] in
                guard let self, let films else { return false }
                films.learnedDecodeTile = self.developMemory.resolvedLearnedDecodeTile()
                return true
            }
        }
        followSelectionFlag()
        followMenuState()
    }

    /// The bundle's baked stocks, or `ARGENT_STOCKS` for a build run outside the bundle.
    private static func stocksDirectory() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Stocks"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return ProcessInfo.processInfo.environment["ARGENT_STOCKS"].map { URL(fileURLWithPath: $0) }
    }

    /// The roll's stock's name.
    var stockName: String? { stockNames[safe: stockIndex] }

    /// The dock's stock picker, the stock panel and the Stock menu: in the frame view the open frame's own stock, which
    /// choosing the roll's makes follow the roll again; on the sheet the whole roll's.
    func selectStock(_ index: Int) {
        guard stockNames.indices.contains(index) else { return }
        if let frame = shownFrame { setStock(index, for: frame) } else { stockIndex = index }
    }

    /// The roll's stock, when stocks loaded.
    var currentStock: Stock? { films?.stocks[safe: stockIndex] }

    /// The stock the dock, the stock panel and the Stock menu show: the open frame's, else the roll's.
    var shownStockIndex: Int { shownFrame.map(stockIndex(for:)) ?? stockIndex }
    var shownStock: Stock? { films?.stocks[safe: shownStockIndex] }
    var shownStockName: String? { stockNames[safe: shownStockIndex] }

    /// The stock `frame` develops through, in library order: its own, or the roll's.
    func stockIndex(for frame: Frame) -> Int { stockIndex(own: overrides[frame.url]) }

    /// The stock a frame with `own` controls develops through: its own while the library has it, else the roll's.
    func stockIndex(own: FrameControls?) -> Int {
        guard let id = own?.stock, let index = films?.stocks.firstIndex(where: { $0.id == id }) else { return stockIndex }
        return index
    }

    func stock(for frame: Frame) -> Stock? { films?.stocks[safe: stockIndex(for: frame)] }

    /// Why `frame` cannot develop: its own stock is one the library does not have. The frame shows through the roll's stock
    /// meanwhile, but a develop fails it rather than write its file through the roll's. `nil` while it has none of its own, or
    /// its own is installed.
    func unavailableStockReason(for frame: Frame) -> String? {
        guard let id = overrides[frame.url]?.stock, let films, !films.stocks.contains(where: { $0.id == id }) else { return nil }
        let recorded = manualRecipes[frame.url]?.stock
        let name = recorded?.id == id ? recorded?.displayName ?? id : id
        return "\(frame.name): its own stock, \(name), is not installed; choose another stock for it, or make it follow the roll"
    }

    func stockName(for frame: Frame) -> String? { stockNames[safe: stockIndex(for: frame)] }

    /// The stock `frames` develop through where they all share one, a frame's own included; else, or for none, the roll's.
    func sharedStockIndex(of frames: [Frame]) -> Int {
        let stocks = Set(frames.map(stockIndex(for:)))
        return stocks.count == 1 ? stocks.first ?? stockIndex : stockIndex
    }

    /// The grain `frame` develops with: its own, or the roll's (the Develop page's).
    func grain(for frame: Frame) -> OutputSettings.Grain { overrides[frame.url]?.grain ?? output.grain }

    /// Whether `frame` develops through a stock of its own rather than the roll's.
    func hasOwnStock(_ frame: Frame) -> Bool { overrides[frame.url]?.stock != nil }

    /// Gives `frame` its own stock, by index in library order; `nil` or the roll's makes it follow the roll.
    func setStock(_ index: Int?, for frame: Frame) {
        var own = frameControls(frame)
        own.setStock(index.flatMap { films?.stocks[safe: $0]?.id }, roll: currentStock?.id)
        overrides[frame.url] = own.isEmpty ? nil : own
    }

    /// Gives `frame` its own grain; `nil` or the roll's makes it follow the roll.
    func setGrain(_ grain: OutputSettings.Grain?, for frame: Frame) {
        var own = frameControls(frame)
        own.setGrain(grain, roll: output.grain)
        overrides[frame.url] = own.isEmpty ? nil : own
    }

    /// The Halation `frame` develops with, 0 to 200: its own, or the roll's (`OutputSettings.halation`).
    func halation(for frame: Frame) -> Int { overrides[frame.url]?.halation ?? output.halation }

    /// Gives `frame` its own Halation; `nil` or the roll's makes it follow the roll.
    func setHalation(_ halation: Int?, for frame: Frame) {
        var own = frameControls(frame)
        own.setHalation(halation, roll: output.halation)
        overrides[frame.url] = own.isEmpty ? nil : own
    }

    // MARK: The Halation row's gesture

    /// Whose Halation its row moves: the roll's, or a frame's own.
    enum HalationTarget: Equatable {
        case roll
        case frame(URL)
    }

    /// Halation as its row's gesture has moved it, until the gesture ends. A write to the roll's or to a frame's saves every
    /// frame's choices (`settingsChanged`), so a gesture's steps are kept here and written once (`endHalationAdjusting`), as a
    /// Light row's are (`printedLight`). The frame view's print follows its frame's meanwhile (`printSettings`); the sheet, the
    /// strip and the stock panel take the value as the gesture ends.
    struct PrintedHalation: Equatable {
        let target: HalationTarget
        var value: Int
    }

    private(set) var printedHalation: PrintedHalation?
    /// Whose Halation row's gesture is open, from `beginHalationAdjusting` to its end.
    @ObservationIgnored private(set) var halationAdjusting: HalationTarget?

    /// The Halation row's gesture began, on `frame`'s own or for `nil` the roll's: its steps go to the print alone
    /// (`moveHalation`). One left open is written first.
    func beginHalationAdjusting(for frame: Frame?) {
        suspendHalationAdjusting(writing: true)
        halationAdjusting = frame.map { .frame($0.url) } ?? .roll
    }

    /// Halation from its row: `frame`'s own, or for `nil` the roll's. Inside the row's gesture, to the print alone
    /// (`printedHalation`); outside one, written at once. A drag's last write is held back a moment and can come after its
    /// gesture has ended (`AdjustmentSlider.Coordinator`): kept then, it would stay, with no gesture left to end it.
    func moveHalation(_ value: Int, for frame: Frame?) {
        let range = OutputSettings.halationRange, target = frame.map { HalationTarget.frame($0.url) } ?? .roll
        let value = min(max(value, range.lowerBound), range.upperBound)
        guard halationAdjusting == target else {
            writeHalation(value, to: target)
            return
        }
        let moved = PrintedHalation(target: target, value: value)
        if printedHalation != moved { printedHalation = moved }
    }

    /// The Halation row's gesture ended: the frame or the roll takes what it moved to, in one write, and none where it moved
    /// nothing.
    func endHalationAdjusting() { suspendHalationAdjusting(writing: true) }

    /// Ends the Halation row's gesture, if one is open, before a write that replaces what it moves or as its session ends: its
    /// steps written first (`writing`), so the write after them wins, or let go unwritten.
    func suspendHalationAdjusting(writing: Bool) {
        let moved = printedHalation
        halationAdjusting = nil
        if moved != nil { printedHalation = nil }
        if writing, let moved { writeHalation(moved.value, to: moved.target) }
    }

    /// Writes Halation to the roll or to a frame, and only where that changes what is there. A frame given the roll's value
    /// follows the roll again (`FrameControls.setHalation`), also one whose own stood at that value already.
    private func writeHalation(_ value: Int, to target: HalationTarget) {
        switch target {
        case .roll:
            if output.halation != value { output.halation = value }
        case .frame(let url):
            guard let frame = roll?.frames.first(where: { $0.url == url }) else { return }
            var own = frameControls(frame)
            own.setHalation(value, roll: output.halation)
            if own != frameControls(frame) { overrides[url] = own.isEmpty ? nil : own }
        }
    }

    /// What `frame` develops with: the roll's controls with the frame's own on top.
    func controls(for frame: Frame) -> RollControls { overrides[frame.url]?.applied(to: controls) ?? controls }

    /// The frame's own controls; empty when it follows the roll.
    func frameControls(_ frame: Frame) -> FrameControls { overrides[frame.url] ?? FrameControls() }

    func isOverridden(_ frame: Frame) -> Bool { overrides[frame.url] != nil }

    func hasFrameEdits(_ frame: Frame) -> Bool { isOverridden(frame) || hasManualAdjustments(frame) }

    /// Gives `frame` its own Rated at; `nil` or the roll's value makes it follow the roll.
    func setRatedAt(_ ratedAt: RollControls.RatedAt?, for frame: Frame) {
        var own = frameControls(frame)
        own.setRatedAt(ratedAt, roll: controls)
        overrides[frame.url] = own.isEmpty ? nil : own
    }

    /// Gives `frame` its own Lab balance; `nil` or the roll's value makes it follow the roll.
    func setLabBalance(_ labBalance: RollControls.LabBalance?, for frame: Frame) {
        var own = frameControls(frame)
        own.setLabBalance(labBalance, roll: controls)
        overrides[frame.url] = own.isEmpty ? nil : own
    }

    func setRestoredFrameControls(_ own: FrameControls, url: URL) { overrides[url] = own.isEmpty ? nil : own }

    /// Makes `frame` follow the roll in every control: stock, Rated at, Lab balance, grain and halation.
    func clearOverrides(for frame: Frame) {
        // A Halation gesture open on the frame is let go, so its end does not give the frame its own again.
        if halationAdjusting == .frame(frame.url) { suspendHalationAdjusting(writing: false) }
        overrides[frame.url] = nil
    }

    /// What the render graph gets for `frame` through `stock`.
    func settings(for frame: Frame, stock: Int) -> DevelopSettings {
        settings(for: frame, stock: stock, manual: manualEdits[frame.url])
    }

    /// What the frame view prints `frame` with: its settings, with a moving gradient's shape as the press last
    /// flushed it, and a moving mask row's values, in place of the edit's (`printedEdit`), so the print follows a
    /// drag the edit takes only on its release. Everywhere else, the sheet, the strip and the stock panel included, the edit's.
    /// So too the Halation its row's gesture has moved the frame's to (`printedHalation`), on a stock that has halation.
    func printSettings(for frame: Frame, stock: Int) -> DevelopSettings {
        var settings = settings(for: frame, stock: stock, manual: printedEdit(for: frame))
        if let moved = printedHalation, moved.target == .frame(frame.url), settings.halation {
            settings.halationAmount = OutputSettings.halationAmount(moved.value)
        }
        return settings
    }

    /// The frame's edit as the frame view prints it: with `printedLight` in place while a Light row moves, `MaskEditor.printed`
    /// while a press moves a gradient of this frame or a brush paints it, and `MaskEditor.printedValues` while a mask's row moves,
    /// else the edit itself.
    func printedEdit(for frame: Frame) -> ManualEdit? {
        let light = printedLight.flatMap { $0.frame == frame.url ? $0.values : nil }
        let shape = maskEditor.printed.flatMap { $0.frame == frame.url ? $0 : nil }
        let values = maskEditor.printedValues.flatMap { $0.frame == frame.url ? $0 : nil }
        guard light != nil || shape != nil || values != nil, var edit = manualEdits[frame.url] else { return manualEdits[frame.url] }
        if let light { edit.adjustments = edit.adjustments.setting(.sliders, from: light) }
        var set = edit.adjustments.masks
        if let shape, var mask = set.masks.first(where: { $0.id == shape.mask }), mask.components.indices.contains(shape.component) {
            mask.components[shape.component].shape = shape.shape
            if let replaced = try? set.replacing(mask) { set = replaced }
        }
        if let values, var mask = set.masks.first(where: { $0.id == values.mask }) {
            mask.amount = values.amount
            mask.adjustments = values.adjustments
            mask.balance = values.balance
            if let replaced = try? set.replacing(mask) { set = replaced }
        }
        if set != edit.adjustments.masks { edit.adjustments = edit.adjustments.settingMasks(set) }
        return edit == manualEdits[frame.url] ? manualEdits[frame.url] : edit
    }

    // MARK: A Light row's gesture

    /// The frame's Light-tab values, Light's six and Presence's five, as the print takes them while a row's gesture moves them (a
    /// slider's drag, a scrub of its number, a key's step, a typed value), or nothing. The frame view's print follows them; the edit,
    /// and everything that reads it (the inspector, its save line and Reset, the menus, the sheet and the strip, the stock panel),
    /// takes them once as the gesture ends (`endLightAdjusting`), as a mask's row does (`MaskEditor.printedValues`). Written to the
    /// edit at each step, the Light tab and the inspector ran and laid out 30 times a second (J).
    struct PrintedLight: Equatable {
        let frame: URL
        var values: ManualAdjustments
    }

    private(set) var printedLight: PrintedLight?
    /// The frame whose Light row's gesture is open, from `beginLightAdjusting` to `endLightAdjusting`.
    @ObservationIgnored private(set) var lightAdjusting: URL?
    /// Advances each time the model ends the Light row's gesture under the row, whose pointer may still be down: a reset or a paste
    /// writes over it, an undo or a redo takes it back (`suspendLightAdjusting`). The row's slider and value hold a drag's newest
    /// steps ahead of the edit; a new generation tells them those steps were the old gesture's, so they drop them, show the edit,
    /// and the drag goes on from there (`ManualAdjustmentRow.gesture`).
    private(set) var lightGestureGeneration = 0

    private func endInspectorInteraction() {
        if let url = lightAdjusting, let frame = selectedFrame, frame.url == url { endLightAdjusting(for: frame) }
        histogramZone = nil
        curveGraphFocusRequest = nil
    }

    /// A Light row's gesture began: one edit gesture, and one undo step, whose steps go to the print (`moveLight`).
    func beginLightAdjusting(for frame: Frame) {
        beginManualGesture(for: frame)
        lightAdjusting = frame.url
    }

    /// A Light-tab slider from its row, one of Light's six or Presence's five. Inside the row's gesture, on a frame with an edit,
    /// to the print alone (`printedLight`). A frame's first edit is written at once, as a first edit always is: it pins the
    /// automatic result on screen (`AutomaticBaseline`), which the rest of the gesture's steps then print from. Outside a
    /// gesture, to the edit.
    func moveLight(_ slider: ManualAdjustments.Slider, to value: Float, for frame: Frame) {
        guard lightAdjusting == frame.url, let edit = manualEdits[frame.url] else {
            if let values = try? manualAdjustments(for: frame).setting(slider, to: value) { setManualAdjustments(values, for: frame) }
            return
        }
        let current = printedLight.flatMap { $0.frame == frame.url ? $0.values : nil } ?? edit.adjustments
        guard canAdjust(frame), let values = try? current.setting(slider, to: value) else { return }
        let moved = PrintedLight(frame: frame.url, values: values)
        if printedLight != moved { printedLight = moved }
    }

    /// The Light row's gesture ended: the edit takes what the print took (`endManualGesture` writes it first), then the one step.
    func endLightAdjusting(for frame: Frame) {
        if lightAdjusting == frame.url { lightAdjusting = nil }
        endManualGesture(for: frame)
    }

    /// Ends the Light row's gesture open on one of these frames before a write that replaces it, returning its frame's URL or nil when
    /// none was open. A reset or a paste writes what the gesture printed first, so the write neither lands inside it nor is taken
    /// back by its end; an undo or a redo lets it go unwritten (`writing: false`), since a step registered during one would be taken
    /// for its Redo.
    func suspendLightAdjusting(on frames: Set<URL>, writing: Bool = true) -> URL? {
        guard let url = lightAdjusting, frames.contains(url), let frame = roll?.frames.first(where: { $0.url == url }) else { return nil }
        lightAdjusting = nil
        if writing { endManualGesture(for: frame) } else { cancelManualGesture(for: frame) }
        lightGestureGeneration += 1
        return url
    }

    /// Opens a Light row's gesture again on the frame `suspendLightAdjusting` ended one on because the slider is still held, so the
    /// rest of its drag becomes one step of its own after the write.
    func resumeLightAdjusting(on url: URL?) {
        guard let url, let frame = roll?.frames.first(where: { $0.url == url }), canAdjust(frame) else { return }
        beginLightAdjusting(for: frame)
    }

    /// Writes what the print took of `frame`'s Light-tab values to the edit, Light's six and Presence's five over the edit as it is
    /// now (a smart mask may have landed meanwhile), and lets the print go in the same turn, so the film on screen is the edit's and
    /// no render starts for it. A gesture's end does this before its step, however the gesture ends; a cancelled gesture lets the
    /// print go unwritten.
    func takePrintedLight(for frame: Frame, writing: Bool) {
        guard let printed = printedLight, printed.frame == frame.url else { return }
        if writing { setManualAdjustments(manualAdjustments(for: frame).setting(.sliders, from: printed.values), for: frame) }
        printedLight = nil
    }

    private func settings(for frame: Frame, stock: Int, manual: ManualEdit?) -> DevelopSettings {
        guard let films, films.stocks.indices.contains(stock) else { return DevelopSettings() }
        let selectedStock = films.stocks[stock]
        do {
            return try DevelopmentResolver.resolve(stock: selectedStock, stockDigest: stockDigests[stock],
                controls: controls(for: frame), aim: printAim(for: frame), manual: Self.printable(manual),
                grain: grain(for: frame).amount, halation: OutputSettings.halationAmount(halation(for: frame)),
                grainSeed: frame.grainSeed, sharpen: true)
        } catch {
            // Keep the last recorded rendering available while the inspector asks for an
            // explicit baseline update. Export rejects this unresolved recipe.
            if let render = manualRecipes[frame.url]?.render { return render.settings }
        }
        var settings = controls(for: frame).settings(for: selectedStock, aim: printAim(for: frame))
        settings.grain = grain(for: frame).amount
        settings.grainSeed = frame.grainSeed
        // As the resolver has them: a stock without halation takes none of the control.
        settings.halation = selectedStock.halation != nil
        settings.halationAmount = settings.halation ? OutputSettings.halationAmount(halation(for: frame)) : 1
        settings.sharpen = true
        return settings
    }

    /// Where the frame's print is aimed (RollModel+Auto); neutral before it is measured, and for a
    /// frame whose measurement failed. One aim a frame whichever stock prints it, so the stock
    /// stock panel's tiles share it: every method so far reads the measurements alone
    /// (`AutoDecisions.readsStock`). A method that reads the stock would need an aim for each stock
    /// the stock panel shows, resolved through the frame's own controls, and `visibleAutomatic` and an
    /// `AutomaticBaseline` would pin the one of the stock in use.
    func printAim(for frame: Frame) -> PrintAim { printAims[frame.url] ?? PrintAim() }

    /// Measures every frame of the roll at low priority, in capture order, behind whatever
    /// the window is asking for, so the roll settles while it is looked at.
    func analyzeRoll() {
        let previous = analysisTask
        previous?.cancel()
        guard let roll, films != nil else { return }
        let frames = roll.frames.filter { !isMeasured($0) }
        analysisTask = Task {
            if let previous { await previous.value }
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for frame in frames { group.addTask { await self.analyze(frame, priority: .low) } }
            }
        }
    }

    /// The frame's auto-development measurement, once made.
    func analysis(for frame: Frame) -> ExposureAnalysis? { analyses[frame.url] }

    /// Measures the frame from its sheet decode, decoding it if need be, whichever view asks, and
    /// records what that came to: its measurement, or its failure; nothing for a request given up on.
    func analyze(_ frame: Frame, priority: Operation.QueuePriority = .normal) async {
        guard !isMeasured(frame), let films else { return }
        let outcome = if let measureFrame { await measureFrame(frame) } else { await films.measure(frame, priority: priority) }
        switch outcome {
        case .measured(let measured, let descriptor): record(measured, descriptor: descriptor, for: frame)
        case .failed(let source): recordFailure(at: source, for: frame)
        case .stopped: break
        }
    }

    /// Records `measured` as the frame's measurement, with the descriptor made from the same decode,
    /// if it is of the frame's raw as it is now; one of a raw since changed is dropped, to be
    /// measured again.
    func record(_ measured: FrameMeasurement, descriptor: SequenceDescriptor? = nil, for frame: Frame) {
        guard let roll, let index = roll.frames.firstIndex(where: { $0.url == frame.url }),
              SourceStamp.of(frame.url) == measured.source else { return }
        let sourceChanged = sourceVersions[frame.url] != measured.source
        if sourceChanged {
            guard let header = FrameHeaders.shared.current(frame, matching: measured.source) else { return }
            holdManualForChangedSource(frame.url)
            var frames = roll.frames
            frames[index] = Frame(id: frames[index].id, url: frame.url, info: header.frame.info)
            self.roll = Roll(folder: roll.folder, frames: frames, unreadable: roll.unreadable)
            sourceVersions[frame.url] = header.source
            seenSources[frame.url] = header.source
            refreshFlags([frame.url])
            forgetDecision(for: frame.url)
            analyses[frame.url] = nil
        }
        guard analyses[frame.url] == nil else { return }
        measuredFrom[frame.url] = measured.source
        if let descriptor { descriptors[frame.url] = descriptor }
        // A measurement from a recipe stands in for a failure to decode the raw now.
        if measurementFailures[frame.url] != nil { measurementFailures[frame.url] = nil }
        analyses[frame.url] = measured.analysis
        measurementArrived(for: frame.url)
        if sourceChanged { settingsChanged() }
    }

    /// Records `restored`, the measurement the frame's recipes give of its raw as it is now, checked
    /// against it, in place of any other of the same version, one this session's decode made first
    /// included: the roll's decision then rests on the recipe's whichever arrived first
    /// (RollModel+Auto). The descriptor from that version's decode stays.
    func recordRestored(_ restored: FrameMeasurement, for frame: Frame) {
        guard let current = analyses[frame.url] else {
            record(restored, for: frame)
            return
        }
        guard current != restored.analysis, measuredFrom[frame.url] == restored.source,
              SourceStamp.of(frame.url) == restored.source else { return }
        analyses[frame.url] = restored.analysis
        measurementArrived(for: frame.url)
    }

    /// Refreshes replaced raws' headers and drops their old measurements. Frame positions and
    /// selection stay on the same files until reopening scans the roll in capture order again.
    @discardableResult
    func forgetChangedSources() -> Bool {
        guard let roll else { return false }
        var frames = roll.frames, versions = sourceVersions, seen = seenSources
        var changed = Set<URL>()
        for (index, frame) in frames.enumerated() {
            let source = SourceStamp.of(frame.url)
            guard source != seen[frame.url] else { continue }
            changed.insert(frame.url)
            seen[frame.url] = source
            if let header = FrameHeaders.shared.current(frame, matching: source) {
                frames[index] = header.frame
                versions[frame.url] = header.source
                seen[frame.url] = header.source
            } else {
                // An unreadable replacement has no trustworthy header or measurement.
                versions[frame.url] = nil
            }
        }
        for url in analyses.keys where measuredFrom[url] == nil || measuredFrom[url] != seen[url] {
            changed.insert(url)
        }
        for (url, failure) in measurementFailures where failure.source != seen[url] { changed.insert(url) }
        guard !changed.isEmpty else { return false }
        var kept = analyses
        for url in changed {
            holdManualForChangedSource(url)
            kept[url] = nil
            measuredFrom[url] = nil
            forgetDecision(for: url)
        }
        self.roll = Roll(folder: roll.folder, frames: frames, unreadable: roll.unreadable)
        sourceVersions = versions
        seenSources = seen
        refreshFlags(changed)
        analyses = kept
        // Removing files from a settled roll preserves the surviving prints. Replacements,
        // returning files, and changes before the first decision still resolve a new snapshot.
        let onlyRemoved = changed.allSatisfy { seen[$0] == nil }
        if !onlyRemoved || !preserveDecisionAfterRemoving(changed) { unsettle() }
        settingsChanged()
        return true
    }

    /// Takes the frames at `urls` out of the roll on screen, once their raws have left its folder (RollModel+Frames): the
    /// frames left keep their capture order and are numbered again from 0, everything kept for the frames gone goes with
    /// them, and the selection moves to the frame shown after them, else the one before, unless the lead is not one of
    /// them. The roll's settled decision stands for the frames left, as it does when a raw is removed behind the app
    /// (`forgetChangedSources`).
    func dropFrames(_ urls: Set<URL>) {
        guard let roll, roll.frames.contains(where: { urls.contains($0.url) }) else { return }
        // The dialog's frames may be among those going.
        quickDevelop = nil
        if isFrameOpen { closeFrame() }
        let lead = selectedFrame, shown = shownFrames.filter { !urls.contains($0.url) }
        // A lead that stays, as one whose name was taken where the others went, is still the lead.
        let next = lead.flatMap { lead in
            urls.contains(lead.url) ? shown.first { $0.id > lead.id } ?? shown.last { $0.id < lead.id } : lead
        }
        let frames = roll.frames.filter { !urls.contains($0.url) }.enumerated().map { Frame(id: $0.offset, url: $0.element.url, info: $0.element.info) }
        let numbers = Dictionary(uniqueKeysWithValues: frames.map { ($0.url, $0.id) })
        // The decision as it stands for the frames left, asked while the roll still holds them all.
        let kept = preserveDecisionAfterRemoving(urls, dropping: true)
        var analyses = analyses, versions = sourceVersions, flags = flagged
        for url in urls {
            analyses[url] = nil
            versions[url] = nil
            flags[url] = nil
            measuredFrom[url] = nil
            seenSources[url] = nil
            forgetDecision(for: url)
            forgetManual(url)
            developedFrames[url] = nil
            developOutcomes[url] = nil
        }
        selectionAnchor = selectionAnchor.flatMap { anchor in roll.frames.indices.contains(anchor) ? numbers[roll.frames[anchor].url] : nil }
        self.roll = Roll(folder: roll.folder, frames: frames, unreadable: roll.unreadable)
        sourceVersions = versions
        if flags != flagged {
            flagged = flags
            saveFlags()
        }
        self.analyses = analyses
        selection = next.flatMap { numbers[$0.url] }
        // The frames' own Rated at and Lab balance went with their recipes; one write, since each saves the roll's choices.
        let own = overrides.filter { !urls.contains($0.key) }
        if own.count != overrides.count { overrides = own }
        if !kept { unsettle() }
        if developPhase == .done { developPhase = .idle }
    }

    /// The stamp paired with `frame`'s displayed header, also used by a develop's snapshot.
    func sourceStamp(for frame: Frame) -> SourceStamp? { sourceVersions[frame.url] }

    /// One stat-only scan at a time, off the main actor. Changed headers are small reads;
    /// unchanged versions use the shared header cache and never reread the raw header.
    private func watchSources() {
        sourceRefreshTask?.cancel()
        sourceRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, let roll = self.roll else { return }
                let urls = roll.frames.map(\.url), seen = self.seenSources
                let changed = await Task.detached(priority: .utility) {
                    urls.contains { SourceStamp.of($0) != seen[$0] }
                }.value
                guard !Task.isCancelled else { return }
                // Raws on their way to another roll or the Trash are not raws removed behind the app: the move takes
                // them out of the roll itself (`dropFrames`), and until it has, their flags stay theirs to carry.
                guard self.frameMove == nil else { continue }
                if changed, self.forgetChangedSources(), !self.isDeveloping { self.analyzeRoll() }
            }
        }
    }

    var selectedFrame: Frame? {
        guard let roll, let selection else { return nil }
        return roll.frames.indices.contains(selection) ? roll.frames[selection] : nil
    }

    /// Reads `folder` as a roll. A folder the sandbox reached through a drop or the open panel
    /// is security scoped; access is held until the next roll replaces it.
    ///
    /// The roll on screen stays, with its folder's access, until the new one is installed, in one
    /// step with no wait in it. An open asked for after this one supersedes it: this one then
    /// stops where it is, gives back its folder's access and changes nothing, whichever finishes
    /// first. No raw is read whole here: a recipe's measurement comes back only for a raw whose
    /// version `SourceDigests` already knows to be the recipe's, and the other frames are measured
    /// again from their decodes.
    func open(_ folder: URL) async {
        closeImport()
        let request = OpenRequest()
        opening?.supersede()
        opening = request
        isScanning = true
        message = nil
        let accessing = folder.startAccessingSecurityScopedResource()
        /// Whether this open is still the newest; when it is not, it gives back its access.
        func isCurrent() -> Bool {
            guard opening === request else {
                if accessing { folder.stopAccessingSecurityScopedResource() }
                return false
            }
            return true
        }
        let opened = await Task.detached(priority: .userInitiated) {
            let scanned = await RollScanner.scan(folder)
            var sources: [URL: SourceStamp] = [:]
            var seen: [URL: SourceStamp] = [:]
            let frames = scanned.frames.map { frame in
                seen[frame.url] = SourceStamp.of(frame.url)
                guard let header = FrameHeaders.shared.current(frame) else { return frame }
                sources[frame.url] = header.source
                seen[frame.url] = header.source
                return header.frame
            }
            return (roll: Roll(folder: scanned.folder, frames: frames, unreadable: scanned.unreadable), sources: sources, seen: seen)
        }.value
        let roll = opened.roll
        guard isCurrent() else { return }
        guard !roll.frames.isEmpty else {
            // A folder that cannot be listed is not empty: macOS may have refused to let the app
            // read a card (docs/research/camera.md, section 4).
            let listable = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
            if accessing { folder.stopAccessingSecurityScopedResource() }
            opening = nil
            isScanning = false
            message = listable ? RollIssues.noFramesLine(folderName: folder.lastPathComponent, unreadable: roll.unreadable)
                : Self.mayNotReadText(folder.lastPathComponent)
            return
        }
        // A develop of the roll open now stops after its frames in flight, and finishes,
        // before the roll and its folders' access go: its frames still read the old raws and
        // write the old destination, and its result belongs to the old roll. None starts while
        // an open is under way (`isScanning`).
        while let running = developTask {
            running.cancel()
            await running.value
            guard isCurrent() else { return }
            if developTask == running { developTask = nil }
        }
        var discarded = false
        saving: while true {
            do {
                try await flushManualSaves()
                break saving
            } catch {
                guard isCurrent() else { return }
                message = "Could not save adjustments before opening another roll: \(error.localizedDescription)"
                switch askAboutUnsavedAdjustments(UnsavedAdjustments(error: error, keep: "Keep Current Roll Open",
                                                                     discard: "Open Without Saving")) {
                case .retry: retryManualSave()
                case .discard:
                    if let currentRoll = self.roll { await RecipeWriter.shared.discardPending(for: currentRoll.frames, library: recipeLibrary) }
                    discarded = true
                    break saving
                case .keep:
                    if accessing { folder.stopAccessingSecurityScopedResource() }
                    opening = nil
                    isScanning = false
                    return
                }
            }
        }
        // A frame a mask's missing seed holds back cannot be saved by any retry, and its edit would go with this roll's session:
        // asked first, as a quit asks, unless Open Without Saving has just let the unsaved adjustments go.
        guard isCurrent() else { return }
        if !discarded, !maskSeedUnsaved.isEmpty,
           askAboutUnsavableAdjustments(UnsavableAdjustments(frames: maskSeedUnsaved.count, proceed: "Open Anyway",
                                                             removals: isUnsavedForMissingPatches)) == .cancel {
            if accessing { folder.stopAccessingSecurityScopedResource() }
            opening = nil
            isScanning = false
            return
        }
        // A roll developed before opens as its recipes left it, read after any develop of it
        // above has written them. Only what `SourceDigests` already knows of each raw is used.
        let frames = roll.frames, rollFolder = roll.folder, decisions = self.decisions, library = recipeLibrary
        let flagStore = self.flagStore, sources = opened.sources
        // A decision of this roll still being written is read as written, not as it was before; so are
        // its flags.
        await decisionSave?.value
        await flagSave?.value
        let (restored, kept, flags) = await Task.detached(priority: .userInitiated) {
            let restored = RestoredRoll(frames: frames, checked: RecipeStore.checked(for: frames, library: library, check: .knownOnly,
                                                                                     stopped: { request.isSuperseded }))
            // The decision the roll settled on before, with its raws as they are now to tell whether it holds.
            let kept = decisions.record(for: rollFolder).map { record in
                (record, Dictionary(uniqueKeysWithValues: frames.map { ($0.url, AutoDecisions.Identity($0, stamp: SourceStamp.of($0.url))) }))
            }
            return (restored, kept, flagStore.stored(for: rollFolder))
        }.value
        guard isCurrent() else { return }
        // Each frame's raw as a flag names it, its size the version its header was read from; a frame
        // whose header was not read has none (`flagIdentity`).
        let identities = Dictionary(uniqueKeysWithValues: frames.compactMap { frame in
            sources[frame.url].map { (frame.url, FlagRecord.Entry(frame, byteCount: Int($0.size))) }
        })
        install(roll, restored: restored, kept: kept, flags: (flags, identities), sources: opened.sources, seen: opened.seen,
                accessed: accessing ? folder : nil)
    }

    /// Replaces the roll on screen with `roll`, as `restored` from its recipes, and its folder's
    /// access with `accessed`'s: all at once, so nothing shows one roll with the other's settings.
    /// A decision `kept` for the roll, its raws as their identities are now, settles it at once if
    /// it still holds. The roll's `flags`, as stored, are matched to its raws as they are now, and it
    /// opens showing every frame.
    private func install(_ roll: Roll, restored: RestoredRoll, kept: (AutoDecisions.Record, [URL: AutoDecisions.Identity])?,
                         flags: (FlagStore.Stored, [URL: FlagRecord.Entry]), sources: [URL: SourceStamp], seen: [URL: SourceStamp],
                         accessed: URL?) {
        opening = nil
        clearManualSession()
        // Each start is matched by one stop, also when the same folder opens again.
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = accessed
        analysisTask?.cancel()
        resetAuto()
        thumbnails.removeAll()
        cellPixelSizes = []
        films?.removeAll()
        if let id = restored.stockID, let index = films?.stocks.firstIndex(where: { $0.id == id }) { stockIndex = index }
        controls = restored.controls ?? RollControls()
        overrides = restored.overrides
        // A frame developed before is printed as it was measured then.
        for frame in roll.frames {
            if let analysis = restored.analyses[frame.url], let source = restored.sources[frame.url] {
                films?.seedAnalysis(analysis, for: frame, source: source)
            }
        }
        developPhase = .idle
        lastDevelop = nil
        developedFrames = [:]
        developOutcomes = [:]
        quickDevelop = nil
        areIssuesDismissed = false
        isIssueDetailsShown = false
        isFrameOpen = false
        frameSurround.reset()
        isComparing = false
        isSplitComparing = false
        requestedPage = .roll
        isImportSourceShown = false
        // A roll opens fitted even when its first frame has the same selection id as the last roll's.
        frameZoom = FrameZoom()
        frameZoomRoom = nil
        message = nil
        flagFilter = .all
        selectionAnchor = nil
        // The roll before its measurements, so its aims (`printAims`) are this roll's frames'.
        self.roll = roll
        sourceVersions = sources
        seenSources = seen
        restoreFlags(flags.0, identities: flags.1)
        measuredFrom = restored.sources
        analyses = restored.analyses
        if let (record, identities) = kept { restoreDecision(record, identities: identities) }
        selection = roll.frames.first?.id
        isScanning = false
        noteRecent(roll)
        chosenDevelopFolder = restoredDevelopFolder(restored.destination, for: roll)
        analyzeRoll()
        watchSources()
        restoreManualSession(roll)
        // A frame the kept decision printed at the fallback that its recipe measures now is not
        // measured again, but is a new input all the same; the roll balances once the restore is done.
        for url in autoDecision?.failed ?? [] where analyses[url] != nil { measurementArrived(for: url) }
    }

    /// A roll is a folder or a card; loose files are refused rather than guessed at, because
    /// the sandbox grants the files and not the folder around them. Returns whether a folder
    /// was taken.
    @discardableResult
    func open(_ urls: [URL]) -> Bool {
        guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        else {
            closeImport()
            message = "Drop a folder or a card, not single files"
            return false
        }
        Task { await open(folder) }
        return true
    }

    func canChangeSize(by delta: Int) -> Bool {
        Metrics.thumbnailWidths.indices.contains(sizeStep + delta)
    }

    func changeSize(by delta: Int) {
        guard canChangeSize(by: delta) else { return }
        sizeStep += delta
    }

    /// Moves the selection by `offset` of the frames the sheet shows, clamped to them; from an open
    /// frame the filter leaves out, to the shown frames after or before it in capture order, and
    /// nowhere when there are none that way.
    func moveSelection(by offset: Int) {
        guard let target = shownFrame(from: selection, by: offset) else { return }
        selection = target
        if offset != 0 { travel = offset > 0 ? 1 : -1 }
    }

    /// Home and End: the first or the last frame the sheet shows.
    func moveSelection(toLast last: Bool) {
        let shown = shownFrames
        guard let target = last ? shown.last : shown.first else { return }
        selection = target.id
        travel = last ? 1 : -1
    }

    /// The issues bar's line: raws left out of the roll and frames the last develop could not
    /// write; `nil` while a develop is retrying them, and when there are none.
    var issuesLine: String? {
        guard let roll, !isDeveloping else { return nil }
        return RollIssues.line(unreadable: roll.unreadable.count, report: lastDevelop)
    }

    var isDeveloping: Bool {
        if case .developing = developPhase { return true }
        return false
    }

    /// The frame the frame view shows, while it is open.
    var shownFrame: Frame? { isFrameOpen ? selectedFrame : nil }

    /// `menuState` as the App's body reads it: a stored copy, set only when the menus would change
    /// (`followMenuState`). Reading `menuState` there observed the edit itself, so each write of a slider's
    /// or a handle's drag re-evaluated the App's body, and SwiftUI then rebuilt the window's root view and
    /// sized the whole window again: most of the main thread during a handle drag (measured, T9).
    private(set) var menus = MenuState()

    /// Keeps `menus` equal to `menuState`: read once with observation, and again a turn after anything
    /// it read changes, since observation tells of a change before it is made.
    func followMenuState() {
        let state = withObservationTracking { menuState } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followMenuState() }
        }
        if state != menus { menus = state }
    }

    /// What the menu bar shows; reading it observes everything in it. On the sheet that is not the
    /// selection itself, only what Frame > Flag, Copy and Paste Adjustments and the frame's files need of it
    /// (`selectionFlag`), so an arrow press between two frames alike in those changes nothing here.
    var menuState: MenuState {
        let open = shownFrame, selected = selectionFlag
        let developing = isDeveloping
        return MenuState(hasRoll: roll != nil, openFrame: open, frameIsOverridden: open.map(isOverridden) ?? false,
                         canResetManual: open.map(canResetManual) == true,
                         canSetDistortion: open.map(canSetDistortion) == true,
                         // The edit's own value, not the print's: the menus take a row's gesture once, as it ends.
                         isDistortionOn: open.map { manualAdjustments(for: $0).lens.distortion.isOn } ?? false,
                         canResetLens: open.map { InspectorMenus.canReset(.lens, $0, model: self) } == true,
                         canResetToOriginal: open.map(canStartFromOriginal) == true,
                         canOpenFrame: canOpenFrame,
                         canFlag: selected.isKnown && canChangeFlags, isFlagged: selected.isFlagged,
                         canShow: canChangeFilter, flagFilter: flagFilter,
                         stockIndex: shownStockIndex, canGrow: canChangeSize(by: 1), canShrink: canChangeSize(by: -1),
                         canDevelop: canDevelop, isDeveloping: developing,
                         canRebalance: canRebalance,
                         canReveal: !(lastDevelop?.files.isEmpty ?? true),
                         isStockPanelShown: isStockPanelShown, isSplitComparing: isSplitComparing, page: workspacePage,
                         recents: recents.map { MenuState.RecentItem(path: $0.path, name: $0.name) },
                         card: developing ? nil : latestCard.map(\.name), canImportCard: latestCard.map(canImport) == true,
                         canImportRoll: canShowImportSource,
                         canMask: open != nil, armedMaskTool: maskEditor.tool, hasSelectedMask: maskEditor.selection != nil,
                         hasMasks: open.map { !masks(for: $0).isEmpty } == true,
                         isMasksTabShown: open != nil && openAdjustSection == .masks && isAdjustmentsShown,
                         selectedComponent: maskEditor.selection?.component,
                         selectedSmartActions: open.flatMap { frame in selectedMask(for: frame).flatMap { smartStatus(of: $0, for: frame)?.actions } } ?? [],
                         showsRemoveTab: removalRuns.showsTab, isRemoveTabShown: isRemoveTabShown,
                         canRemoveObject: open != nil && remove.frame == open?.url && removalRuns.canRemove,
                         canCancelRemoval: open.map { removalRuns.busyFrames.contains($0.url) } == true,
                         canCopyAdjustments: selected.canCopy, canPasteAdjustments: selected.canPaste, pasteOnlyParts: selected.pasteOnly,
                         canPasteToShown: canPasteToShownFrames, pasteToShownTitle: pasteToShownTitle,
                         canDevelopFrame: selected.canDevelopFrame, canShowRAW: selected.isSelected,
                         canShowDevelopedFile: selected.hasDevelopedFile,
                         isSeveralSelected: selected.isSeveral, canChangeFrames: selected.canChangeFrames,
                         moveTargets: moveTargets, isAskingToDevelop: isAskingToDevelop,
                         isShowingMaskModels: maskModels.isShown,
                         canCheckForUpdates: updates.canCheckForUpdates)
    }

    /// Frame > Open Frame and the rail's Frame: on the sheet, a frame selected or one shown
    /// to open.
    var canOpenFrame: Bool { roll != nil && !isFrameOpen && frameMove == nil && (selectionFlag.isSelected || !shownFrames.isEmpty) }

    /// Before the app quits: a develop stops after its frames in flight, and the roll's settled
    /// decision and its flags are written, so the next open finds them.
    func finishWritesForQuit() async {
        stopDevelop()
        if let task = developTask { await task.value }
        // Frames on their way out of the roll arrive first.
        if let task = frameMoveTask { await task.value }
        await decisionSave?.value
        await flagSave?.value
    }

    /// Before the app quits, after `finishWritesForQuit`: saves the adjustments not saved yet, asking what
    /// to do while they cannot be (`askAboutUnsavedAdjustments`). Retry saves them again, Keep Open keeps
    /// the app and its roll open, and Quit Without Saving quits without them. Then, since a frame a mask's
    /// missing seed holds back cannot be saved by any retry and its edit would end with the app, asks once
    /// more (`askAboutUnsavableAdjustments`): Cancel keeps the app open, Quit Anyway quits without them. An
    /// edit is never lost without being asked. Whether the app may quit.
    func saveAdjustmentsForQuit() async -> Bool {
        while true {
            do {
                try await flushManualSaves()
                guard !maskSeedUnsaved.isEmpty else { return true }
                switch askAboutUnsavableAdjustments(UnsavableAdjustments(frames: maskSeedUnsaved.count, proceed: "Quit Anyway",
                                                                         removals: isUnsavedForMissingPatches)) {
                case .proceed: return true
                case .cancel:
                    isQuitting = false
                    return false
                }
            } catch {
                manualSaveMessage = "Could not save adjustments: \(error.localizedDescription)"
                manualSaveFailed = true
                switch askAboutUnsavedAdjustments(UnsavedAdjustments(error: error, keep: "Keep Open",
                                                                     discard: "Quit Without Saving")) {
                case .retry: retryManualSave()
                case .discard: return true
                case .keep:
                    isQuitting = false
                    return false
                }
            }
        }
    }

    /// The selected frame at the size of the window, in place of the contact sheet; the first frame
    /// shown when none is selected.
    func openFrame() {
        // Not while frames are leaving the roll: the frame opened might be one of them, and its edits would be lost.
        guard let roll, !roll.frames.isEmpty, frameMove == nil else { return }
        if selection == nil { selection = shownFrames.first?.id }
        guard selection != nil else { return }
        // The rail's Frame swaps the view under the quick develop dialog, which is for the view it was asked from.
        if quickDevelop != nil { quickDevelop = nil }
        travel = 1
        // The frame view shows one frame, and its keys and menus act on it alone.
        if selected.count > 1 { collapseSelection() }
        isFrameOpen = true
        // From the Develop page's grid the frame opens on the roll, where the frame view is.
        if requestedPage == .develop { requestedPage = .roll }
    }

    /// The roll's sheet was scrolled, by hand or by the keys, and not put on its frame (`SheetGridController`).
    func sheetScrolled() {
        if !isFrameOpen, !isSheetScrolledSinceClose { isSheetScrolledSinceClose = true }
    }

    /// Back to the contact sheet, on the frame that was open, or the nearest frame shown when the
    /// filter leaves it out. The quick develop dialog was asked from the frame view, and goes with it.
    func closeFrame() {
        if quickDevelop != nil { quickDevelop = nil }
        isFrameOpen = false
        keepSelectionShown(nearest: true)
        isComparing = false
        isSplitComparing = false
        isComparingAuto = false
        isNeutralShown = false
        lightClipping = nil
        frameLayout = nil
        frameZoom = FrameZoom()
        frameZoomRoom = nil
    }
}

/// One open of a roll, superseded by the next: what it reads off the main actor stops then.
final class OpenRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var superseded = false

    func supersede() { lock.withLock { superseded = true } }
    var isSuperseded: Bool { lock.withLock { superseded } }
}

#if DEBUG
extension RollModel {
    /// Debug builds only: the window held as if a roll were being read, for `ARGENT_DEBUG_OPEN_ROLL=read`;
    /// the next open ends it.
    func holdReadingForDebug() { isScanning = true }
}
#endif
