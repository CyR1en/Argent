import ArgentRoll
import SwiftUI
import UniformTypeIdentifiers

/// The one window, in the Graphite Immersive layout: a title strip across the top with the
/// window's buttons, what the workspace shows and the view's actions; under it the rail set into a
/// narrow leading column, one inset rounded workspace beside it, and beyond the workspace one panel
/// in its own column, so its controls never cover a photograph: in the frame view with Adjust on, the
/// frame's inspector, and on the Develop page, where the files go, as what, and the Develop button.
///
/// The workspace shows the page the rail asks for (`RollModel.workspacePage`): Rolls,
/// Settings, an import's review, the roll, as its contact sheet or one frame, or the roll's Develop page. Over the roll
/// float any notices at the top and at the bottom one dock, by context: the frame view's filmstrip or
/// the sheet's whole-roll controls, or the stock panel in place of either while it is open.
struct ContentView: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.undoManager) private var undoManager
    /// Whether the dock shows Auto's state, which the title strip then leaves out.
    @State private var dockShowsAuto = false
    /// The row under the title strip, in the window: the rail, the workspace and the panel beside it.
    @State private var row = CGRect.zero

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TitleStrip(dockShowsAuto: dockShowsAuto)
                // First for clicks: a scroll view beside it, the inspector's, runs up under the window's
                // title bar, its clip hiding that part but not stopping it from taking them.
                .zIndex(1)
            HStack(spacing: 0) {
                AppRail()
                    // Over the workspace's drop shadow, as the title strip is, so its lenses stay crisp on the chrome.
                    .zIndex(1)
                workspace
                    .padding(.bottom, Graphite.Metric.workspaceInset)
                    .padding(.trailing, showsInspector || showsDevelopPanel || showsImportPanel ? 0 : Graphite.Metric.workspaceInset)
                if showsInspector, let frame = model.adjustInspectorFrame {
                    // The Adjust panel sits clear of the workspace and the window's edge, its top and foot
                    // level with the workspace's.
                    ManualAdjustmentsView(frame: frame)
                        .id(frame.url)
                        .padding(.horizontal, Graphite.Metric.inspectorGutter)
                        .padding(.bottom, Graphite.Metric.workspaceInset)
                        .frame(width: Graphite.Metric.inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showsDevelopPanel {
                    // The Develop page's panel, in the inspector's column.
                    DevelopPanel()
                        .padding(.horizontal, Graphite.Metric.inspectorGutter)
                        .padding(.bottom, Graphite.Metric.workspaceInset)
                        .frame(width: Graphite.Metric.inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showsImportPanel, case .reviewing(let review) = model.importSession {
                    // An import's roll and its cull, in the inspector's column beside its frames.
                    ImportPanel(review: review)
                        .padding(.horizontal, Graphite.Metric.inspectorGutter)
                        .padding(.bottom, Graphite.Metric.workspaceInset)
                        .frame(width: Graphite.Metric.inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { row = $0 }
        }
        .onPreferenceChange(ShowsAutoStatus.self) { [binding = $dockShowsAuto] shows in
            binding.wrappedValue = shows
        }
        // A panel comes in from the window's edge as the workspace makes room for it, and goes the same way.
        .animation(reduceMotion ? nil : Graphite.Motion.surface, value: showsInspector)
        .animation(reduceMotion ? nil : Graphite.Motion.surface, value: showsDevelopPanel)
        .animation(reduceMotion ? nil : Graphite.Motion.surface, value: showsImportPanel)
        .background {
            WindowShellBackground(space: model.output.space)
        }
        .ignoresSafeArea()
        .foregroundStyle(Graphite.text)
        // The chosen theme's scheme: menus, sheets and pop-ups follow the window.
        .preferredColorScheme(AppearanceSettings.shared.colorScheme)
        .containerBackground(.clear, for: .window)
        .navigationTitle("Argent")
        .onAppear { model.manualUndoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.manualUndoManager = manager }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
        } isTargeted: { model.isDropTargeted = $0 }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.folder]) { result in
            model.importDirectory = nil
            switch result {
            case .success(let folder):
                Task { await model.open(folder) }
            case .failure(let error):
                let failure = error as NSError
                if failure.domain != NSCocoaErrorDomain || failure.code != CocoaError.userCancelled.rawValue {
                    model.message = "Could not open the selected folder: \(error.localizedDescription)"
                }
            }
        }
        .fileDialogDefaultDirectory(model.importDirectory)
        .sheet(item: $model.presetPresentation) { presentation in
            switch presentation {
            case .save(let frame):
                SavePresetSheet(model: model, frame: frame, store: model.presetStore)
            case .library(let frames, let selection, let managing):
                PresetLibrarySheet(model: model, frames: frames, store: model.presetStore, selection: selection, managing: managing)
            case .builder(let presentation):
                if let store = model.userStockStore { StockBuilderSheet(model: model, store: store, presentation: presentation) }
            }
        }
        .sheet(item: $model.stockImportSource) { source in
            if let store = model.userStockStore {
                ImportStockSheet(model: model, source: source, store: store, frame: model.shownFrame ?? model.selectedFrame)
            }
        }
        .sheet(item: $model.stockBuilder) { presentation in
            if let store = model.userStockStore { StockBuilderSheet(model: model, store: store, presentation: presentation) }
        }
    }

    /// The Develop page's panel shows with its page.
    private var showsDevelopPanel: Bool {
        !model.onboarding.isPresented && model.workspacePage == .develop && model.roll != nil
    }

    /// An import's panel shows while its frames are reviewed.
    private var showsImportPanel: Bool {
        guard !model.onboarding.isPresented, model.workspacePage == .importReview, case .reviewing = model.importSession else { return false }
        return true
    }

    /// The frame's inspector shows in the frame view with Adjust on.
    private var showsInspector: Bool {
        !model.onboarding.isPresented && model.adjustInspectorFrame != nil
    }

    /// Where the workspace is in the window with no panel beside it: the room the contact sheet has, which the frame
    /// view beside its inspector does not.
    private var sheetRoom: CGRect {
        CGRect(x: row.minX + Graphite.Metric.railWidth, y: row.minY,
               width: max(0, row.width - Graphite.Metric.railWidth - Graphite.Metric.workspaceInset),
               height: max(0, row.height - Graphite.Metric.workspaceInset))
    }

    private var workspace: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.workspaceRadius, style: .continuous)
        return ZStack {
            Graphite.workspace
            switch model.workspacePage {
            case .settings:
                SettingsPage()
            case .rolls:
                RollsPage()
            case .importReview:
                ImportReviewPage()
            case .roll:
                if let roll = model.roll {
                    RollWorkspace(roll: roll, sheetRoom: sheetRoom)
                }
            case .develop:
                if let roll = model.roll {
                    DevelopPage(roll: roll)
                }
            }
            // Over the roll, its sheet or one frame: what a menu's Develop This Frame asks before it develops.
            if model.workspacePage == .roll {
                QuickDevelopLayer()
            }
            // The mask models' licences and download, asked for by a Sky, Subject or Background tile or Settings.
            if model.maskModels.isShown {
                Color.black.opacity(0.3)
                    .contentShape(Rectangle())
                    .onTapGesture { model.maskModels.close() }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                MaskModelsSheet()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            // First-launch welcome and setup flow (or reopened via Help › Welcome to Argent…).
            if model.onboarding.isPresented {
                OnboardingView()
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(reduceMotion ? nil : Graphite.Motion.panel, value: model.maskModels.isShown)
        .animation(reduceMotion ? nil : Graphite.Motion.panel, value: model.onboarding.isPresented)
        .clipShape(shape)
        // Clicks too: a clip hides what runs past the workspace (a zoomed photograph, the frame view's
        // drag and taps) but would still let it take clicks over the title strip and the rail.
        .contentShape(shape)
        .background {
            WorkspaceShadow(isDark: Graphite.isDark, fill: Graphite.workspace)
        }
        .overlay {
            if model.isDropTargeted {
                shape
                    .strokeBorder(Graphite.selection.opacity(0.7), lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if contrast == .increased {
                shape
                    .strokeBorder(Graphite.strongBorder, lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : Graphite.Motion.panel, value: model.workspacePage)
    }
}

/// The roll in the workspace: its contact sheet or one frame, the top bar and notices over it, and
/// one dock at the bottom.
///
/// Opening a frame grows its thumbnail into the frame view, and closing it shrinks the picture back to where the sheet
/// will show it (`FrameHero`); the sheet and the surround fade under it. The bottom bar stays anchored as the stock shelf opens above it.
private struct RollWorkspace: View {
    let roll: Roll
    /// Where the contact sheet's workspace is in the window: this one, with no panel beside it.
    let sheetRoom: CGRect
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    /// The notices' height at the top: the contact sheet starts under them.
    @State private var noticesHeight: CGFloat = 0
    /// The pictures' top left in the window, measured here, outside the frame view's way in and out, which moves what
    /// the frame view would measure of itself.
    @State private var origin: CGPoint?
    /// The visible workspace bounds, handed to the ambient surround so its perimeter falloff aligns
    /// with the workspace even while trailing overscan extends under a moving inspector.
    @State private var workspaceSize: CGSize = .zero
    private static let sheetTop = ContactSheet.Spacing.pageTop

    var body: some View {
        ZStack(alignment: .top) {
            // In a stack of their own, so that the sheet's going and the frame's coming are inside what the spring moves:
            // put on the choice between them, it would move neither.
            ZStack { pictures }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    origin = rect.origin
                    workspaceSize = rect.size
                }
                .animation(reduceMotion ? nil : Graphite.Motion.hero, value: model.isFrameOpen)
            NoticeStack(height: $noticesHeight)
                .padding(.top, model.isFrameOpen ? Graphite.Metric.edge : Self.sheetTop)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                WorkspaceDock()
            }
        }
        .animation(reduceMotion ? nil : (model.offeredCard != nil ? Graphite.Motion.arrive : Motion.stateChange), value: model.offeredCard)
        .animation(reduceMotion ? nil : (model.message != nil ? Graphite.Motion.arrive : Motion.stateChange), value: model.message)
        .animation(reduceMotion ? nil : Motion.stateChange, value: noticesHeight)
    }

    /// The room the notices take under the sheet's filter row, so they never cover a frame.
    private var noticesRoom: CGFloat { noticesHeight > 0.5 ? noticesHeight + Graphite.Metric.s : 0 }

    /// The frame view's way in and out: from the selected frame's well where the sheet shows it now, and back to
    /// where the sheet will show it. The sheet that comes back is another, scrolled to the frame, in a workspace that
    /// may have changed, so where the frame was opened from is not where it goes back to. A frame closed before the
    /// sheet it was opened from has gone gets that one back, which goes to the frame as well (`ContactSheet`).
    private var hero: FrameHero {
        guard let selection = model.selection, let frame = model.selectedFrame else { return FrameHero(isPortrait: false) }
        let shown = model.shownFrames
        return FrameHero(
            from: FrameHero.Well(inWindow: model.sheetGrid?.wellInWindow(of: selection)),
            to: FrameHero.Well(index: shown.firstIndex { $0.id == selection }, count: shown.count,
                               cell: Metrics.thumbnailWidths[model.sizeStep],
                               sheetTop: Self.sheetTop + SheetFilterBar.height + noticesRoom - ContactSheet.Spacing.topOverlap,
                               sheetBottom: Graphite.Metric.dockTop, room: sheetRoom),
            isPortrait: frame.info.isPortrait)
    }

    @ViewBuilder private var pictures: some View {
        if model.isFrameOpen, let frame = model.selectedFrame {
            // The surround fades; the frame over it grows from its thumbnail.
            // Both over the sheet on the way back too, where the sheet is the later of the two to come.
            Color.clear
                // Past the trailing edge, which the workspace clips: with the inspector coming or going the workspace is
                // on its way to another width, and the sheet would show beside a surround as wide as the frame view.
                .overlay(alignment: .topLeading) {
                    frameSurroundLayer
                        .padding(.trailing, -Graphite.Metric.inspectorWidth)
                        .allowsHitTesting(false)
                }
                .transition(.opacity)
                .zIndex(1)
            FrameView(roll: roll, frame: frame, origin: origin)
                .padding(.bottom, Graphite.Metric.dockBand)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(hero)
                .zIndex(2)
        } else {
            VStack(spacing: 0) {
                Color.clear.frame(height: Self.sheetTop)
                SheetFilterBar()
                    // Over the sheet, whose faded edge runs under the row's foot.
                    .zIndex(1)
                // Room for the notices floating under the filter row, so they never cover a frame.
                Color.clear.frame(height: noticesRoom)
                ContactSheet(roll: roll, isRollSheet: true)
                    .padding(.top, -ContactSheet.Spacing.topOverlap)
            }
            // To the dock's top edge, where the sheet's pictures fade out.
            .padding(.bottom, Graphite.Metric.dockTop)
            // The proofing surround is the photographs' surround.
            .background(model.graySurround ? Palette.gray18 : Color.clear)
            .transition(.opacity)
        }
    }

    /// 18% Gray Surround always wins for proofing; otherwise Ambient Surround renders unless turned
    /// off in Settings or macOS Increase Contrast is active.
    @ViewBuilder private var frameSurroundLayer: some View {
        let appearance = AppearanceSettings.shared
        if model.graySurround {
            Palette.gray18
        } else if appearance.showsAmbientSurround, contrast != .increased {
            FrameSurroundView(
                controller: model.frameSurround,
                workspaceSize: workspaceSize,
                palette: appearance.palette,
                outputSpace: model.output.space,
                intensity: appearance.ambientSurroundIntensity,
                reduceMotion: reduceMotion,
                fallbackImage: model.framePictureShown
            )
            .accessibilityHidden(true)
        } else {
            Graphite.photoSurround
        }
    }
}

/// The frame view on its way from the contact sheet and back: scaled and moved so that its picture lies on the selected
/// frame's well there, at the size of the thumbnail, and at rest when open. A transition's two ends, between which the
/// workspace's spring moves it (`Graphite.Motion.hero`). It comes `from` the well the sheet shows and goes back `to` the
/// well the sheet will show, which are not the same place; with no well, a frame whose cell is out of the sheet's view
/// on the way in or one the sheet will not show on the way back, it fades.
struct FrameHero: Transition {
    /// The selected frame's well on the sheet: where the sheet has it now, or what says where a sheet coming back will
    /// put it.
    struct Well: Equatable, Sendable {
        /// In the window's content, from its top left: the sheet is up and shows the well.
        var inWindow: CGRect?
        /// The frame's place among the `count` the sheet will show.
        var index: Int?
        var count = 0
        /// The narrowest cell at the sheet's size (`Metrics.thumbnailWidths`).
        var cell: CGFloat = Metrics.thumbnailWidths[0]
        /// From the workspace's top to the sheet's scroll view, and from that view's foot to the workspace's.
        var sheetTop: CGFloat = 0
        var sheetBottom: CGFloat = 0
        /// The sheet's workspace in the window: as wide as it is with no panel beside it, which is not the frame view's
        /// width beside its inspector.
        var room = CGRect.zero

        /// The well in the window's content: where the sheet has it, or where a sheet coming back will put it.
        var rect: CGRect? {
            if let inWindow { return inWindow }
            guard let index, count > 0, room.width > 0 else { return nil }
            let geometry = SheetGeometry(width: room.width, targetCell: cell)
            let viewport = max(0, room.height - sheetTop - sheetBottom)
            return geometry.wellRevealed(ofItem: index, count: count, viewport: viewport)
                .offsetBy(dx: room.minX, dy: room.minY + sheetTop)
        }
    }

    var from = Well()
    var to = Well()
    let isPortrait: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let well = phase == .willAppear ? from : to, isPortrait = isPortrait, isOpen = phase.isIdentity
        content
            .visualEffect { view, proxy in
                let size = proxy.size, origin = proxy.frame(in: .global).origin
                let move = isOpen ? nil : well.rect.map {
                    Self.move(to: $0.offsetBy(dx: -origin.x, dy: -origin.y), in: size, isPortrait: isPortrait)
                }
                return view
                    .scaleEffect(move?.scale ?? 1, anchor: .topLeading)
                    .offset(move?.offset ?? .zero)
                    .opacity(isOpen || move != nil ? 1 : 0)
            }
            // On its way out it takes no clicks: they are for the sheet coming back under it.
            .allowsHitTesting(phase != .didDisappear)
            .modifier(LeftByItsCell(isLeaving: phase == .didDisappear))
    }

    /// A frame view on its way out is not drawn once the sheet has been scrolled: it goes to where its cell was as the
    /// frame was closed and is there until it has left the window, and the cell has gone from under it. The cell shows
    /// the frame.
    private struct LeftByItsCell: ViewModifier {
        @Environment(RollModel.self) private var model
        let isLeaving: Bool

        func body(content: Content) -> some View {
            content.opacity(isLeaving && model.isSheetScrolledSinceClose ? 0 : 1)
        }
    }

    /// The scale, about the frame view's top left, and the offset that put the fitted picture of a frame view `size`
    /// large on the picture in `well`, in the frame view's own points: upright in the middle of the well for a portrait
    /// frame, as `FrameCell` draws it. The frame view fits its picture in its room above the dock's band (`FrameLayout`).
    nonisolated static func move(to well: CGRect, in size: CGSize, isPortrait: Bool) -> (scale: CGFloat, offset: CGSize) {
        let area = CGSize(width: size.width, height: max(0, size.height - Graphite.Metric.dockBand))
        let long = isPortrait ? min(area.height, area.width * 1.5) : min(area.width, area.height * 1.5)
        let picture = isPortrait ? CGSize(width: long * 2 / 3, height: long) : CGSize(width: long, height: long * 2 / 3)
        guard picture.width > 0, well.width > 0 else { return (1, .zero) }
        let from = CGPoint(x: (area.width - picture.width) / 2, y: (area.height - picture.height) / 2)
        let thumbnail = isPortrait ? CGSize(width: well.height * 2 / 3, height: well.height) : well.size
        let to = CGPoint(x: well.midX - thumbnail.width / 2, y: well.midY - thumbnail.height / 2)
        let scale = thumbnail.width / picture.width
        return (scale, CGSize(width: to.x - scale * from.x, height: to.y - scale * from.y))
    }
}
