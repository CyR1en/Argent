import AppKit
import ArgentRoll
import SwiftUI

@main
struct ArgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = RollModel()

    init() {
        #if DEBUG
        Automation.noteAppMade()
        #endif
        // Run from `swift run` without a bundle, the binary would start as a background tool.
        NSApplication.shared.setActivationPolicy(.regular)
        DisplayFace.register()
        AppearanceSettings.shared.followSystemAppearance()
    }

    var body: some Scene {
        // Read here so that a change rebuilds the menus; see `MenuState`. The stored copy, which changes
        // only when a menu does: anything else this body reads rebuilds the window's root view.
        scenes(menus: model.menus)
    }

    @SceneBuilder private func scenes(menus: MenuState) -> some Scene {
        Window("Argent", id: "main") {
            ContentView()
                .environment(model)
                // Wide enough for the rail, the title strip's actions and the docks' controls; tall
                // enough for the strip, a row of the sheet and the dock.
                .frame(minWidth: 800, minHeight: 560)
                .onAppear { delegate.attach(model) }
        }
        .defaultSize(width: 1280, height: 860)
        // The title strip runs under a transparent title bar, the window's buttons on its line
        // (`WindowChrome`).
        .windowStyle(.hiddenTitleBar)
        .commands { ArgentCommands(model: model, state: menus) }

        // The About window: the app, its version and what the stocks are built from.
        Window("About Argent", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

    }
}

/// Folders handed over by Finder or the Dock (Open With, a drop on the Dock icon, `open -a`).
/// Launch Services passes them with a sandbox extension, as a drop on the window does.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: RollModel?
    private var pending: [URL] = []

    @MainActor func attach(_ model: RollModel) {
        guard self.model == nil else { return }
        self.model = model
        model.watchCards()
        model.updates.start(for: model)
        // Once, at launch, before any undo history or download exists: any unfinished Subject models' staging folder
        // (`SubjectModelPack.sweepStaging`), the smart masks' seeds no edit names any more (`MaskRasterStore.sweep`),
        // and the removals' patches likewise.
        Task {
            await model.sweepSubjectModelStaging()
            await model.sweepMaskSeeds()
            await model.sweepPatches()
        }
        #if DEBUG
        Automation.start(model: model)
        #endif
        if !pending.isEmpty {
            model.open(pending)
            pending = []
        }
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.isQuitting = true
        Task {
            await model.finishWritesForQuit()
            let quits = await model.saveAdjustmentsForQuit()
            // The model Remove holds goes with the app: a helper left to itself would outlive the app that started it. Nothing is
            // made here: a session that removed nothing has no queue. Cancel any Subject models download so its staging folder cleans up.
            if quits {
                await model.subjectModels.cancelForQuit()
                await model.removalRuns.steps?.developWillStart()
            }
            sender.reply(toApplicationShouldTerminate: quits)
        }
        return .terminateLater
    }

    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        #if DEBUG
        Automation.noteOpen()
        #endif
        if let model { model.open(urls) } else { pending += urls }
    }
}

/// What the menus show that changes while the app runs. SwiftUI does not rebuild the menu
/// bar when an observed model changes under it (seen on macOS 27: the Frame menu kept its
/// closed-frame items after the frame view opened), so the App's body reads this from the
/// model and hands it to the commands, and the menus follow.
struct MenuState: Equatable {
    var hasRoll = false
    /// The frame the frame view shows, while it is open.
    var openFrame: Frame?
    var frameIsOverridden = false
    var canResetManual = false
    var canSetDistortion = false
    var isDistortionOn = false
    var canResetLens = false
    /// Frame > Reset to Original: the open frame can start from its Original (`canStartFromOriginal`).
    var canResetToOriginal = false
    /// Frame > Open Frame: a frame is selected, or the sheet shows one to open.
    var canOpenFrame = false
    /// Frame > Flag or Unflag, for the frame selected on the sheet or open in the frame view.
    var canFlag = false
    var isFlagged = false
    /// View > Show: a roll is open.
    var canShow = false
    var flagFilter = FlagFilter.all
    /// The ISO speeds in the Rated at items follow the stock.
    var stockIndex = 0
    var canGrow = false
    var canShrink = false
    var canDevelop = false
    var isDeveloping = false
    /// Roll > Rebalance Roll, once the roll has settled.
    var canRebalance = false
    var canReveal = false
    /// The rail's tools and pages, so their menu items' checks follow them.
    var isStockPanelShown = false
    var isSplitComparing = false
    var page = WorkspacePage.roll
    /// The roll's frames are in sight as a grid or one frame, on the roll or its Develop page: the commands
    /// for the selected frame and for which frames show act there, and nowhere a frame is out of sight.
    var showsFrames: Bool { page == .roll || page == .develop }
    /// File > Open Recent.
    var recents: [RecentItem] = []
    var card: String?
    var canImportCard = false
    /// File > Import Roll…: no import or develop under way.
    var canImportRoll = true
    /// The Mask menu (`MaskKeys`): a frame is open to mask, and the tool in hand. Whether the frame is
    /// ready (`RollModel.canAdjust`) is for an item to ask when it is chosen: read here, it would rebuild
    /// the menu bar with each render's bookkeeping.
    var canMask = false
    var armedMaskTool: MaskEditor.Tool?
    var hasSelectedMask = false
    var hasMasks = false
    /// The Adjust inspector shows its Masks tab on the open frame, where pins are (Mask > Show Pins).
    var isMasksTabShown = false
    /// The selected component, for Mask > Set Component.
    var selectedComponent: Int?
    /// What the selected smart mask's row offers now, for the Mask menu's items of the same.
    var selectedSmartActions: [SmartRowStatus.Action] = []
    /// Remove (`RemoveKeys`): whether this build's inspector has the tab, whether it is showing on the open frame, whether its
    /// selection can be removed and whether the frame has a run to stop. The last two change as a selection is made and a run
    /// begins or ends, never at a stroke's points (`RemovalRuns.canRemove`).
    var showsRemoveTab = false
    var isRemoveTabShown = false
    var canRemoveObject = false
    var canCancelRemoval = false
    /// Edit's Copy and Paste Adjustments and the Frame menu's files, for the frame open in the frame view or selected on the sheet.
    /// They come from `SelectionFlag`, not the selection, so an arrow press on the sheet changes them only where the next frame
    /// differs: from a frame with an edit to one without, Copy Adjustments turns off, as Flag's title turns between a flagged
    /// frame and one that is not.
    var canCopyAdjustments = false
    var canPasteAdjustments = false
    /// Paste Only's parts that can be pasted on the frame; the submenu itself follows `canPasteAdjustments`.
    var pasteOnlyParts: AdjustmentParts = []
    /// The batch paste on the frames the sheet shows, whose title follows the filter (`RollModel.pasteToShownTitle`).
    var canPasteToShown = false
    var pasteToShownTitle = "Paste to All Frames"
    var canDevelopFrame = false
    var canShowRAW = false
    var canShowDevelopedFile = false
    /// More than one frame is selected on the sheet: Flag, Paste Adjustments, Develop and the Finder items are for them
    /// all, and say so. Not how many, so a Shift-arrow that adds a frame leaves the menu bar as it is.
    var isSeveralSelected = false
    /// Frame > Move to Roll and Remove from Roll…: the frames selected can leave the roll (`RollModel.canChangeFrames`).
    var canChangeFrames = false
    /// Frame > Move to Roll's rolls: the library's other than the roll open now.
    var moveTargets: [MoveTarget] = []
    /// The quick develop dialog is up over the roll (`RollModel.isAskingToDevelop`): what would act on the roll, its frames or
    /// the selection under it is disabled, so no key does what the dialog does not show. It changes as the dialog comes and
    /// goes, not at a choice made in it. What leaves the roll's page, Develop…, Settings, another roll, stays: the dialog goes.
    var isAskingToDevelop = false
    /// The Subject models' licence and download screen is up over the workspace (`SubjectModelsDownload.isShown`):
    /// as `isAskingToDevelop`, keys and menus leave the roll and frame under it alone.
    var isShowingSubjectModels = false
    /// Either modal sheet is up over the workspace.
    var isSheetShown: Bool { isAskingToDevelop || isShowingSubjectModels }
    /// Argent > Check for Updates…: Sparkle updater started and is idle enough to check now.
    var canCheckForUpdates = false
    /// The commands for the roll, its frames and the selection act: on the roll's page, with no dialog over it.
    var actsOnRoll: Bool { page == .roll && !isSheetShown }
    /// As `showsFrames`, with no dialog over the roll.
    var actsOnFrames: Bool { showsFrames && !isSheetShown }

    struct RecentItem: Equatable {
        var path: String
        var name: String
    }
}

extension FlagFilter {
    /// View > Show's key, with Control and Command.
    var key: KeyEquivalent {
        switch self {
        case .all: "0"
        case .flagged: "1"
        case .unflagged: "2"
        }
    }
}

struct ArgentCommands: Commands {
    let model: RollModel
    let state: MenuState
    @Environment(\.openWindow) private var openWindow

    /// Rebalance Roll brings the roll forward first, from the Open roll or Settings page, so its
    /// progress is seen; the commands for what the roll's views show are disabled there instead
    /// (`MenuState.page`), so no key changes the roll out of sight.
    private func onRoll(_ action: () -> Void) {
        model.showWorkspacePage(.roll)
        action()
    }

    @ViewBuilder private func ratedAtItems(frame: Bool) -> some View {
        let box = (frame ? model.shownStock : model.currentStock)?.boxSpeed ?? 0
        ForEach(RollControls.RatedAt.allCases, id: \.self) { position in
            Text(verbatim: RollControlsView.ratedAtItem(position, boxSpeed: box)).tag(position)
        }
    }

    @ViewBuilder private var labBalanceItems: some View {
        ForEach(RollControls.LabBalance.allCases, id: \.self) { balance in
            Text(balance.title).tag(balance)
        }
    }

    var body: some Commands {
        // The About window rather than AppKit's panel, which could not carry the notices.
        CommandGroup(replacing: .appInfo) {
            Button("About Argent") { openWindow(id: AboutView.windowID) }
            Divider()
            Button("Check for Updates…") { model.updates.checkForUpdates() }
                .disabled(!state.canCheckForUpdates)
        }
        // Settings is a page of the main window (the rail's Settings), not a window of its own.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                // The page is the main window's: bring the window back if it was closed.
                openWindow(id: "main")
                model.showWorkspacePage(.settings)
            }
            .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            // Import Roll… copies a card's or a folder's frames into a new roll; Add Existing Folder… keeps a folder
            // where it is. Both rolls join the Rolls page.
            Button("Import Roll…") { model.showImportSource() }
                .keyboardShortcut("i")
                .disabled(!state.canImportRoll)
            Button("Add Existing Folder…") { model.chooseExistingFolder() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(state.recents, id: \.path) { recent in
                    Button(recent.name) { model.openRecent(path: recent.path) }
                        .help(recent.path)
                }
                Divider()
                Button("Clear Menu") { model.clearRecents() }
                    .disabled(state.recents.isEmpty)
            }
            // One item whose title names the card: the menu bar does not follow items that
            // come and go.
            Button(state.card.map { "Open Card \u{201C}\($0)\u{201D}" } ?? "Open Card") {
                if let card = model.latestCard { model.openCard(card) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(state.card == nil)
            Button(state.card.map { "Import Card \u{201C}\($0)\u{201D}" } ?? "Import Card") {
                if let card = model.latestCard { model.startImport(card) }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!state.canImportCard)
        }
        // Copy and Paste Adjustments (docs/manual-development.md), after the system's Paste, on the frame open in the frame view or
        // selected on the sheet; the batch on the frames the sheet shows. Their chords are Pages' Copy Style and Paste Style, which
        // no other item binds (`ClipboardKeys`, ClipboardKeyTests); the clipboard is the app's own, so Command-C in a field is
        // untouched. Always the same items, disabled or retitled through `MenuState`.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Adjustments") { model.selectedFrame.map(model.copyAdjustments) }
                .keyboardShortcut(ClipboardKeys.copy.shortcut)
                .disabled(!state.canCopyAdjustments || !state.actsOnRoll)
            // On the frames selected: one frame, or several as one undo step.
            Button(state.isSeveralSelected ? "Paste Adjustments to Selected Frames" : "Paste Adjustments") {
                model.pasteAdjustments(to: model.selectedFrames)
            }
                .keyboardShortcut(ClipboardKeys.paste.shortcut)
                .disabled(!state.canPasteAdjustments || !state.actsOnRoll)
            Submenu("Paste Only", isEnabled: state.canPasteAdjustments && state.actsOnRoll) {
                ForEach(AdjustmentParts.each, id: \.self) { part in
                    Button(part.title) { model.pasteAdjustments(to: model.selectedFrames, parts: part) }
                        .disabled(!state.pasteOnlyParts.contains(part) || !state.actsOnRoll)
                }
            }
            Button(state.pasteToShownTitle) { model.pasteAdjustmentsToShownFrames() }
                .keyboardShortcut(ClipboardKeys.pasteToShown.shortcut)
                .disabled(!state.canPasteToShown || !state.actsOnRoll)
        }
        CommandMenu("Stock") {
            Toggle("Stock Panel", isOn: Binding(get: { model.isStockPanelShown && model.workspacePage == .roll },
                                                set: { if $0 != (model.isStockPanelShown && model.workspacePage == .roll) { model.toggleStockPanel() } }))
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!state.hasRoll || model.stockNames.isEmpty || state.isSheetShown)
            Divider()
            // The number keys switch stocks, in library order; a tenth stock and later have no key. With the brush in hand they are
            // Flow's (Mask > Flow), and these stand aside; a key that beats the menu's refresh still does what the live tool says.
            ForEach(model.stockNames.indices, id: \.self) { index in
                Toggle(model.stockNames[index], isOn: Binding(get: { model.shownStockIndex == index },
                                                              set: { isOn in
                                                                  // A key can beat the menu's refresh: under a sheet
                                                                  // the live model says a digit is no stock's.
                                                                  if model.isSheetShown { return }
                                                                  if model.maskEditor.tool == .brush {
                                                                      if index < 9 { model.digitPressed(index + 1) }
                                                                  } else if isOn {
                                                                      model.selectStock(index)
                                                                  }
                                                              }))
                    .keyboardShortcut(StockChooserButton.key(for: index))
                    .disabled(!state.actsOnRoll || state.armedMaskTool == .brush)
                    // The film it models, as on the stock panel's tile.
                    .help(model.stockAfterLines[index] ?? "")
            }
        }
        CommandMenu("Roll") {
            Picker("Rated At", selection: Binding(get: { model.controls.ratedAt }, set: { model.controls.ratedAt = $0 })) {
                ratedAtItems(frame: false)
            }
            .disabled(!state.actsOnRoll)
            Picker("Lab Balance", selection: Binding(get: { model.controls.labBalance }, set: { model.controls.labBalance = $0 })) {
                labBalanceItems
            }
            .disabled(!state.actsOnRoll)
            // Every frame's and develop's, as in the stock panel, the sheet's dock and the Develop page.
            Picker("Grain", selection: Binding(get: { model.output.grain }, set: { model.output.grain = $0 })) {
                ForEach(OutputSettings.Grain.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            // The dialog has a Grain of its own, which its Develop makes this one.
            .disabled(state.isSheetShown)
            // Always there, disabled while the roll is balancing: the menu bar does not follow items
            // that come and go.
            Button("Rebalance Roll") { onRoll { model.rebalanceRoll() } }
                .disabled(!state.canRebalance || state.isSheetShown)
            Divider()
            // The Develop page from anywhere, and on it its button (`developCommand`).
            Button(state.page == .develop ? "Develop" : "Develop…") { model.developCommand() }
                .keyboardShortcut("d")
                .disabled(!state.hasRoll || state.page == .importReview || state.page == .develop && !state.canDevelop)
            Button("Stop Developing") { model.stopDevelop() }
                .keyboardShortcut(".")
                .disabled(!state.isDeveloping)
            Button("Reveal Developed Files in Finder") { model.revealDeveloped() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.canReveal)
        }
        // The frame view, and the selected frame's own Rated at and Lab balance, which the
        // spec sets from the frame view only.
        CommandMenu("Frame") {
            Button("Open Frame") { model.openFrame() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!state.canOpenFrame || !state.actsOnFrames)
            Button("Back to Contact Sheet") { model.closeFrame() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(state.openFrame == nil || !state.actsOnRoll)
            Divider()
            // One item whose title follows the frame, on the sheet and in the frame view. Plain F, as the
            // number keys switch stocks: a focused text field takes the key first, and so does the
            // curve graph, which keeps F as it keeps its own keys (CurveGraphView.keyDown). A key held
            // down flags once (`flagSelection`). A key can beat the menu's refresh, so under the quick develop dialog
            // the live model, not this item's state, keeps F from the frames under it.
            Button((state.isFlagged ? "Unflag" : "Flag") + (state.isSeveralSelected ? " Selected Frames" : "")) {
                if !model.isSheetShown { model.flagSelection(NSApp.currentEvent) }
            }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!state.canFlag || !state.actsOnFrames)
            Divider()
            // Always the same items, disabled on the sheet: the menu bar does not follow a
            // branch that swaps items once it is built. The bindings find the frame when used.
            Picker("Rated At", selection: Binding(get: { model.shownFrame.map { model.controls(for: $0).ratedAt } ?? model.controls.ratedAt },
                                                  set: { value in model.shownFrame.map { model.setRatedAt(value, for: $0) } })) {
                ratedAtItems(frame: true)
            }
            .disabled(state.openFrame == nil || !state.actsOnRoll)
            Picker("Lab Balance", selection: Binding(get: { model.shownFrame.map { model.controls(for: $0).labBalance } ?? model.controls.labBalance },
                                                     set: { value in model.shownFrame.map { model.setLabBalance(value, for: $0) } })) {
                labBalanceItems
            }
            .disabled(state.openFrame == nil || !state.actsOnRoll)
            Button("Reset to Current Auto") { model.shownFrame.map { model.resetManualAdjustments(for: $0) } }
                .disabled(!state.canResetManual || !state.actsOnRoll)
            // The frame as shot, with none of Auto's corrections (docs/manual-development.md, "Starting
            // from Original").
            Button("Reset to Original") { model.shownFrame.map { model.startFromOriginal(for: $0, actionName: "Reset to Original") } }
                .disabled(!state.canResetToOriginal || !state.actsOnRoll)
            Toggle("Distortion", isOn: Binding(get: { state.isDistortionOn }, set: { value in
                model.shownFrame.map { model.setDistortion(value, for: $0) }
            }))
            .disabled(!state.canSetDistortion || !state.actsOnRoll)
            Button("Reset Lens") { model.shownFrame.map { InspectorMenus.resetLens($0, model: model).choose() } }
                .disabled(!state.canResetLens || !state.actsOnRoll)
            Divider()
            // Remove's tab, Return and Escape (`RemoveKeys`), once the inspector has the tab.
            RemoveMenuItems(model: model, state: state)
            Button("Same as Roll") { model.shownFrame.map(model.clearOverrides) }
                .disabled(!state.frameIsOverridden || !state.actsOnRoll)
            Divider()
            // The frame's own develop and its files, on the sheet, in the frame view and on the Develop page, as its
            // context menu has them (`FrameMenu.files`). Disabled away from them, so no key develops a frame out of sight.
            // With several frames selected on the sheet, theirs. On the roll it asks where and as what first, in the
            // quick develop dialog, so its title ends in an ellipsis there; on the Develop page it develops at once.
            Button((state.isSeveralSelected ? "Develop Selected Frames" : "Develop This Frame") + (state.page == .develop ? "" : "…")) {
                model.developSelection()
            }
                .disabled(!state.canDevelopFrame || !state.actsOnFrames)
            Button(state.isSeveralSelected ? "Show RAWs in Finder" : "Show RAW in Finder") { model.showSelectionInFinder() }
                .disabled(!state.canShowRAW || !state.showsFrames)
            Button(state.isSeveralSelected ? "Show Developed Files in Finder" : "Show Developed File in Finder") {
                model.showSelectionDevelopedInFinder()
            }
                .disabled(!state.canShowDevelopedFile || !state.showsFrames)
            Divider()
            // The frames selected on the sheet leave the roll, for another roll or for the Trash (RollModel+Frames), as
            // their context menu has it (`FrameMenu.roll`).
            Menu("Move to Roll") {
                ForEach(state.moveTargets) { target in
                    Button(target.name) { model.moveFrames(model.selectedFrames, toRoll: target.id) }
                }
                Divider()
                Button("New Roll…") { model.moveFramesToNewRoll(model.selectedFrames) }
            }
            .disabled(!state.canChangeFrames || !state.actsOnFrames)
            // Command-Delete is a text field's own key, to delete back to the start of its line, and the menu bar takes
            // a key before the field does: pressed while a field has the keys, it is given to the field (`removeSelection`).
            Button("Remove from Roll…") { model.removeSelection(NSApp.currentEvent) }
                .keyboardShortcut(FrameKeys.remove.shortcut)
                .disabled(!state.canChangeFrames || !state.actsOnFrames)
        }
        CommandMenu("Mask") { MaskMenuItems(model: model, state: state) }
        CommandGroup(after: .toolbar) {
            // Which frames the sheet shows and Develop develops, as the filter above the sheet chooses.
            Picker("Show", selection: Binding(get: { model.flagFilter }, set: { model.showFrames($0) })) {
                ForEach(FlagFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                        .keyboardShortcut(filter.key, modifiers: [.control, .command])
                }
            }
            .disabled(!state.canShow || !state.actsOnFrames)
            Divider()
            // The thumbnails' size on the sheet and the zoom in the frame view, as a pinch changes each; not under the Subject models' screen,
            // which covers them.
            Button(state.openFrame == nil ? "Larger Thumbnails" : "Zoom In") {
                if model.isFrameOpen { model.zoomFrame(.zoomIn) } else { model.changeSize(by: 1) }
            }
            .keyboardShortcut("+")
            .disabled(state.openFrame == nil && !state.canGrow || !state.showsFrames || state.isShowingSubjectModels)
            Button(state.openFrame == nil ? "Smaller Thumbnails" : "Zoom Out") {
                if model.isFrameOpen { model.zoomFrame(.zoomOut) } else { model.changeSize(by: -1) }
            }
            .keyboardShortcut("-")
            .disabled(state.openFrame == nil && !state.canShrink || !state.showsFrames || state.isShowingSubjectModels)
            Button("Actual Size") { model.zoomFrame(.actualSize) }
                .keyboardShortcut("0")
                .disabled(state.openFrame == nil || state.page != .roll || state.isShowingSubjectModels)
            Button("Zoom to Fit") { model.zoomFrame(.fit) }
                .keyboardShortcut("9")
                .disabled(state.openFrame == nil || state.page != .roll || state.isShowingSubjectModels)
            Divider()
            // The split comparison of the neutral raw and film, the frame view's Compare.
            Toggle("Split Compare", isOn: Binding(get: { model.isSplitComparing }, set: { model.isSplitComparing = $0 }))
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(state.openFrame == nil || state.page != .roll || state.isShowingSubjectModels)
            // The inspector edits the open frame, and its curve graph takes the keys: not under the dialog.
            Toggle("Adjustments", isOn: Binding(get: { model.isAdjustmentsShown }, set: { model.isAdjustmentsShown = $0 }))
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(state.openFrame == nil || !state.actsOnRoll)
            // The inspector's four tabs, for a keyboard that Tab cannot take to its buttons.
            Button("Light Adjustments") { model.showInspector(tab: .light) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(state.openFrame == nil || !state.actsOnRoll)
            Button("Curve Adjustments") { model.showInspector(tab: .curve) }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(state.openFrame == nil || !state.actsOnRoll)
            MaskKeys.masksTabView.menuItem(model: model, state: state)
            Button("Lens Adjustments") { model.showInspector(tab: .lens) }
                .keyboardShortcut("4", modifiers: [.command, .option])
                .disabled(state.openFrame == nil || !state.actsOnRoll)
            if state.showsRemoveTab { RemoveKeys.tabView.menuItem(model: model, state: state) }
            Toggle("Gray Surround", isOn: Binding(get: { model.graySurround }, set: { model.graySurround = $0 }))
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
        }
    }
}
