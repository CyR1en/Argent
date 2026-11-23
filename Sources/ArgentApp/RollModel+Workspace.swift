import ArgentRoll
import Foundation

struct CurveGraphFocusRequest: Equatable {
    let frame: URL
    private let id = UUID()

    init(frame: URL) { self.frame = frame }
}

/// What fills the workspace beside the rail.
enum WorkspacePage: Equatable, Sendable {
    /// The open roll: its contact sheet or one frame.
    case roll
    /// The open roll's frames to develop in a grid, with where and as what they are written in the panel
    /// beside it, and the Develop button at the panel's foot.
    case develop
    /// The library's rolls, Import roll, and an import's copy under way.
    case rolls
    /// Appearance and develop memory settings.
    case settings
    /// A card or a folder being read, its frames reviewed, or an import that failed.
    case importReview
}

/// The rail's navigation (AppRail): which page the workspace shows, and the two views and two
/// tools of a roll, and its Develop page. The views and tools are the model's own state (`isFrameOpen`,
/// `isStockPanelShown`, `isAdjustmentsShown`), so the menus, the keys and the rail stay one.
extension RollModel {
    /// The page the workspace shows: an import's review over every page but Settings, its copy on the Rolls page, and
    /// without a roll, Rolls in place of the roll and of its Develop page.
    var workspacePage: WorkspacePage {
        if requestedPage != .settings, importSession != .idle {
            guard importSession.isCopying else { return .importReview }
            // The copy goes on behind the Rolls page, or behind the roll open now when it is asked for.
            if requestedPage == .roll || requestedPage == .develop, roll != nil { return requestedPage }
            return .rolls
        }
        return (requestedPage == .roll || requestedPage == .develop) && roll == nil ? .rolls : requestedPage
    }

    var isStockShelfVisible: Bool {
        workspacePage == .roll && isStockPanelShown && !stockNames.isEmpty
    }

    var adjustInspectorFrame: Frame? {
        workspacePage == .roll && isAdjustmentsShown ? shownFrame : nil
    }

    func showWorkspacePage(_ page: WorkspacePage) {
        setPage(page)
    }

    /// Asks for `page`. Leaving the Rolls page for a roll still open lets go of the line about an
    /// open that failed there: the page has shown it, and over the roll it would only cover frames. The Import roll
    /// sheet goes with its page.
    private func setPage(_ page: WorkspacePage) {
        if requestedPage == .rolls, page != .rolls, roll != nil, !isScanning { message = nil }
        if page != .rolls { isImportSourceShown = false }
        // Another page leaves the frame view and its inspector behind, and a mask tool with them.
        if page != .roll { maskEditor.reset() }
        // The Develop page's Details popover goes with its page, and the quick develop dialog with the roll.
        if page != .develop { isIssueDetailsShown = false }
        if page != .roll { quickDevelop = nil }
        // The Subject models' screen is the workspace's; a download under way goes on.
        if page != requestedPage { subjectModels.close() }
        requestedPage = page
    }

    /// Opens the Adjust inspector on `tab`: View > Light, Curve and Mask Adjustments, for a keyboard
    /// that Tab cannot take to the inspector's own buttons. A gesture under way ends first, so it is one
    /// undo step on the tab it began on.
    func showInspector(tab: AdjustInspectorTab) {
        showInspector { $0.open(tab) }
    }

    func revealInspectorEdit(_ item: InspectorDestination) {
        showInspector { $0.reveal(item) }
        if case .mask(let id) = item {
            maskEditor.selection = MaskEditor.Selection(mask: id, component: nil)
        }
    }

    private func showInspector(_ navigate: (inout AdjustInspectorNavigation) -> Void) {
        if let frame = shownFrame { endLightAdjusting(for: frame) }
        navigate(&inspectorNavigation)
        isAdjustmentsShown = true
        if openAdjustSection == .curve, let frame = adjustInspectorFrame {
            curveGraphFocusRequest = CurveGraphFocusRequest(frame: frame.url)
        } else {
            curveGraphFocusRequest = nil
        }
    }

    /// The graph takes focus after AppKit attaches it. Navigation or a newer command can revoke the request before then.
    func pendingCurveGraphFocus(for frame: Frame) -> (() -> Bool)? {
        guard let request = curveGraphFocusRequest, request.frame == frame.url else { return nil }
        return {
            guard self.curveGraphFocusRequest == request, self.adjustInspectorFrame?.url == frame.url,
                  self.openAdjustSection == .curve, self.canAdjust(frame) else { return false }
            self.curveGraphFocusRequest = nil
            return true
        }
    }

    /// Rail > Roll: the contact sheet.
    func showRoll() {
        setPage(.roll)
        if isFrameOpen { closeFrame() }
    }

    /// Rail > Frame: the selected frame, or the first shown.
    func showFrame() {
        setPage(.roll)
        if !isFrameOpen { openFrame() }
    }

    /// Rail > Develop: the roll's Develop page, and from it back to the roll as it was left.
    func toggleDevelopPage() {
        if requestedPage == .develop { closeDevelopPage() } else { showDevelopPage() }
    }

    /// The roll's Develop page. Its grid is the roll's frames as the sheet has them, so an open frame is
    /// closed under it, and comes back when the page is closed (`closeDevelopPage`).
    func showDevelopPage() {
        guard requestedPage != .develop else { return }
        // From Settings over the page, the way back is the one the page was first opened with.
        if requestedPage == .roll { developPageReturnsToFrame = isFrameOpen }
        if isFrameOpen { closeFrame() }
        setPage(.develop)
    }

    /// The Develop page's close button, Escape and the rail's Develop on it: back to the roll, in the frame
    /// view if the page was opened from it, on the frame selected now.
    func closeDevelopPage() {
        guard requestedPage == .develop else { return }
        setPage(.roll)
        if developPageReturnsToFrame { openFrame() }
        developPageReturnsToFrame = false
    }

    /// Rail > Stock: the stock panel over the bottom of the workspace, on the roll.
    func toggleStockPanel() {
        if requestedPage != .roll || roll == nil {
            setPage(.roll)
            isStockPanelShown = true
        } else {
            isStockPanelShown.toggle()
        }
    }

    /// Rail > Adjust: the frame's inspector beside the workspace; from the sheet it opens the
    /// selected frame with it.
    func toggleAdjust() {
        let wasElsewhere = requestedPage != .roll
        setPage(.roll)
        if !isFrameOpen {
            openFrame()
            isAdjustmentsShown = true
        } else if wasElsewhere {
            isAdjustmentsShown = true
        } else {
            if let frame = shownFrame { endManualGesture(for: frame) }
            isAdjustmentsShown.toggle()
        }
    }
}
