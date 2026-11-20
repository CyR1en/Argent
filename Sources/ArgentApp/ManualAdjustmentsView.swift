import ArgentCore
import ArgentRoll
import SwiftUI

/// The Adjust inspector's five tabs (`RollModel.adjustTab`). Masks is a tab and not a rail item: one
/// inspector, with one Start from, save line and Compare, and a second door would lead to the same panel.
/// Remove is the fifth (docs/remove-plan.md), for the same reason.
enum AdjustInspectorTab: String, CaseIterable, Sendable {
    case light, curve, masks, lens, remove

    /// Whether the strip has its fifth segment: the one switch that takes Remove out of the interface again.
    static let showsRemove = true
    /// The tabs the strip shows, in its order.
    static var allCases: [AdjustInspectorTab] { [.light, .curve, .masks, .lens] + (showsRemove ? [.remove] : []) }

    /// Where the tab is kept across launches.
    static let storageKey = "adjustInspectorTab"
    /// The Bool that kept it while there were two: true for Curve.
    static let legacyCurvesKey = "manualInspectorCurves"

    /// The tab last shown. The first read after the third tab came takes the old Bool's answer and
    /// moves it to the new key, so the old key is read once.
    static func stored(in defaults: UserDefaults = .standard) -> AdjustInspectorTab {
        if let raw = defaults.string(forKey: storageKey) {
            let tab = AdjustInspectorTab(rawValue: raw) ?? .light
            return tab == .remove && !showsRemove ? .light : tab
        }
        guard defaults.object(forKey: legacyCurvesKey) != nil else { return .light }
        let tab: AdjustInspectorTab = defaults.bool(forKey: legacyCurvesKey) ? .curve : .light
        defaults.set(tab.rawValue, forKey: storageKey)
        defaults.removeObject(forKey: legacyCurvesKey)
        return tab
    }
}

/// Frame-only refinements in the Adjust panel beside the workspace.
struct ManualAdjustmentsView: View {
    let frame: Frame
    @Environment(RollModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var lens: (file: LensFile, hasProfile: Bool)?
    private var destination: InspectorDestination? { model.inspectorNavigation.destination }
    @State private var isCompact = false
    @State private var requestsFilterFocus = false

    var body: some View {
        let panel = RoundedRectangle(cornerRadius: Graphite.Metric.workspaceRadius, style: .continuous)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                heading
                InspectorHistogram(frame: frame, compact: isCompact)
                    .padding(.top, isCompact ? 6 : 11)
                AdjustFilterPicker(frame: frame, keyboardFocusRequested: $requestsFilterFocus)
                    .padding(.top, isCompact ? 6 : 11)
            }
            .padding(.horizontal, Graphite.Metric.adjustPadding)
            .padding(.top, isCompact ? 9 : 14)
            .padding(.bottom, isCompact ? 6 : 11)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 0) {
                        AdjustNotices(frame: frame)
                            .padding(.horizontal, Graphite.Metric.adjustPadding)
                        if model.inspectorNavigation.filter == .edited {
                            EditedAdjustmentsView(frame: frame, lensFile: lens?.file, hasLensProfile: lens?.hasProfile, drillIn: model.revealInspectorEdit)
                                .environment(\.editedInspectorFocus, EditedInspectorFocus(model: model, frame: frame.url) {
                                    requestsFilterFocus = true
                                })
                                .id(AdjustInspectorFilter.edited)
                        } else {
                            sections
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.openAdjustSection) { _, section in
                    if let destination, case .mask = destination {
                        reader.scrollTo(destination, anchor: .top)
                    } else if let removal = destination?.removal {
                        reader.scrollTo(removal, anchor: .center)
                    } else if let section {
                        reader.scrollTo(section, anchor: .top)
                    }
                }
                .onChange(of: model.inspectorNavigation.filter) { _, filter in
                    if filter == .edited { reader.scrollTo(filter, anchor: .top) }
                }
            }
            AdjustFooter(frame: frame)
        }
        .onGeometryChange(for: Bool.self) { $0.size.height < 680 } action: { isCompact = $0 }
        .environment(\.isCompactAdjustInspector, isCompact)
        .contentShape(Rectangle())
        .contextMenu(entries: { InspectorMenus.ground(of: model.openAdjustSection, frame: frame, model: model) })
        .frame(width: Graphite.Metric.inspectorPanelWidth)
        .background {
            panel.fill(Graphite.chrome)
                .overlay { panel.fill(Graphite.ink(Graphite.isDark ? 0.034 : 0.014)) }
        }
        .clipShape(panel)
        .contentShape(panel)
        .background {
            // Kept off the workspace across the gutter, where a zoomed frame can run to its edge.
            WorkspaceShadow(cornerRadius: Graphite.Metric.workspaceRadius, isDark: Graphite.isDark, fill: Graphite.chrome,
                            sparedLeadingGap: Graphite.Metric.inspectorGutter)
        }
        .overlay {
            if contrast == .increased {
                panel.strokeBorder(Graphite.strongBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.isOnGlass, true)
        .foregroundStyle(Graphite.text)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Adjustments for this frame")
        .task(id: FrameSourceRequest(frame: frame.url, source: model.sourceStamp(for: frame))) {
            await model.prepareManualAdjustments(for: frame)
        }
        .task(id: FrameSourceRequest(frame: frame.url, source: model.sourceStamp(for: frame))) {
            lens = nil
            guard let file = await model.films?.lensFile(for: frame), !Task.isCancelled else { return }
            let hasProfile = if case .file = LensResolver.availability(file).distortion { true } else { false }
            lens = (file, hasProfile)
        }
        .onDisappear { model.isComparingAuto = false; model.lightClipping = nil; model.histogramZone = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.isComparingAuto = false; model.lightClipping = nil }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Graphite.Metric.s) {
                Text("Adjust")
                    .font(Graphite.Typeface.panelTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Graphite.Metric.s)
                AdjustSaveLine(frame: frame)
                CloseButton(help: "Close Adjust") { model.isAdjustmentsShown = false }
                    .padding(.trailing, -6)
            }
            .frame(height: 24)
            AdjustStartingPoint(frame: frame)
        }
    }

    private var sections: some View {
        VStack(spacing: 0) {
            ForEach(AdjustInspectorTab.allCases, id: \.self) { section in
                VStack(spacing: 0) {
                    SectionDivider()
                    AdjustSectionHeader(frame: frame, section: section, hasLensProfile: lens?.hasProfile) {
                        model.toggleInspectorSection(section, for: frame)
                    }
                    .id(section)
                    if model.openAdjustSection == section {
                        editor(for: section)
                            .padding(.horizontal, Graphite.Metric.adjustPadding)
                            .padding(.top, 4)
                            .padding(.bottom, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder private func editor(for section: AdjustInspectorTab) -> some View {
        switch section {
        case .light: LightSection(frame: frame)
        case .curve:
            CurveEditorView(frame: frame, requestedChannel: destination?.channel).id(frame.url)
        case .masks: MasksInspector(frame: frame)
        case .lens: LensAdjustmentsView(frame: frame, file: lens?.file)
        case .remove: RemoveInspector(frame: frame, initialRemoval: destination?.removal)
        }
    }
}

// MARK: - The head's leaves

/// Edits save themselves (docs/manual-development.md, "Autosave"); the line beside the heading says where they stand. A
/// failure is said here in two words, and in full with its Retry among the notices under the heading.
private struct AdjustSaveLine: View {
    let frame: Frame
    @Environment(RollModel.self) private var model

    var body: some View {
        let status = model.adjustSaveStatus(for: frame)
        if case .failed(let message) = status {
            StatusLabel(symbol: "exclamationmark.triangle", text: "Not saved", isCompact: true)
                .help(message)
        } else {
            // One line for the three, so the spinner gives way to the check in place, which is drawn on as the save ends.
            let isSaving = status == .saving, isSaved = status == .saved
            StatusLabel(symbol: isSaved || isSaving ? "checkmark" : "circle",
                        text: isSaving ? "Saving…" : isSaved ? "Saved" : "No adjustments", isBusy: isSaving, isCompact: true)
                .help(isSaving ? "Saving adjustments"
                      : isSaved ? "This frame's adjustments are saved. They save automatically as you make them."
                      : "This frame shows Auto as it is. Adjustments save automatically as you make them.")
        }
    }
}

/// Where the frame's edits start: Auto, or the Original, the frame as shot at its Rated at through
/// the film, with none of Auto's corrections. Choosing the other clears Light, Curves and masks in one
/// undo step (docs/manual-development.md, "Starting from Original"), so it is a menu on the heading's second line and
/// not a switch a stray click can throw: the menu says what the choice costs before it is made. Only the choice not made can
/// be made, so the menu is disabled, as the sliders are, when that one cannot.
private struct AdjustStartingPoint: View {
    let frame: Frame
    @Environment(RollModel.self) private var model

    var body: some View {
        let isFromOriginal = model.startingPoint(for: frame) == .original
        HStack(spacing: 5) {
            Text("Starting from")
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .lineLimit(1)
                .accessibilityHidden(true)
            Menu {
                MenuEntries(make: { InspectorMenus.startingPoint(frame, model: model) })
            } label: {
                InspectorChipFace(text: isFromOriginal ? "Original" : "Auto")
            }
            .graphiteMenu()
            .disabled(!model.canChangeStartingPoint(frame))
            .help(isFromOriginal ? "This frame starts from the Original: as shot at its Rated at, with the film and none of Auto's corrections."
                  : "This frame starts from Auto's exposure and lab filtration.")
            .accessibilityLabel("This frame starts from")
            .accessibilityValue(isFromOriginal ? "Original" : "Auto")
        }
        .frame(height: 20)
    }
}

/// What keeps the frame from being refined, or what has changed under its pin: an issue and its
/// action, preparation, Auto having moved on, or a save that failed, with its Retry. Above the tools, on a light ground of
/// their own, and nothing at all while there is nothing to say. The Masks tab says what it waits for under its
/// tiles, which are what is waiting.
private struct AdjustNotices: View {
    let frame: Frame
    @Environment(RollModel.self) private var model
    @State private var isRetryingPreparation = false

    var body: some View {
        let issue = model.manualIssue(for: frame)
        let preparing = issue == nil && model.openAdjustSection != .masks ? model.adjustPreparation(for: frame) : nil
        let hasUpdatedAuto = model.hasUpdatedAuto(frame)
        let failure: String? = if case .failed(let message) = model.adjustSaveStatus(for: frame) { message } else { nil }
        if issue != nil || preparing != nil || hasUpdatedAuto || failure != nil {
            VStack(alignment: .leading, spacing: Graphite.Metric.s) {
                if let issue {
                    issueView(issue)
                } else if let preparing {
                    StatusLabel(symbol: "hourglass", text: preparing, isBusy: true, isCompact: true)
                }
                if hasUpdatedAuto {
                    line("arrow.triangle.2.circlepath", "Auto has updated. Reset to Current Auto rejoins it.")
                        .help("The current automatic result differs from this frame’s pinned starting point. Reset to Current Auto rejoins current Auto.")
                }
                if let failure {
                    line("exclamationmark.triangle", failure, color: Graphite.text)
                    Button("Retry") { model.retryManualSave() }
                        .help("Retry saving the adjustments that could not be saved")
                }
            }
            .buttonStyle(.graphite(.secondary, size: .small))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Graphite.Metric.actionRadius, style: .continuous).fill(Graphite.ink(0.05)))
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
        }
    }

    private func line(_ symbol: String, _ text: String, color: Color = Graphite.secondaryText) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Graphite.Typeface.small)
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func issueView(_ issue: String) -> some View {
        line("exclamationmark.triangle", issue)
        if model.manualPreparationErrors[frame.url] != nil {
            Button("Retry") {
                isRetryingPreparation = true
                Task {
                    await model.prepareManualAdjustments(for: frame)
                    isRetryingPreparation = false
                }
            }
            .disabled(isRetryingPreparation || model.isScanning || model.isQuitting || model.isRestoringManual)
            .help("Retry reading this RAW to prepare its automatic starting point and adjustments")
        } else if model.manualIssueRequiresReapply(for: frame) {
            Button("Reapply Adjustments") { model.reapplyManualAdjustments(for: frame) }
                .help("Attach the saved adjustment values to this replacement RAW using its current automatic result")
        } else if model.hasManualAdjustments(frame) {
            Button("Update Automatic Baseline") { model.updateAutomaticBaseline(for: frame) }
                .help(model.startingPoint(for: frame) == .original
                      ? "Keep the adjustment values and take the Original starting point again with the current rendering versions"
                      : "Keep the adjustment values and use the current automatic result and rendering versions as their starting point")
        }
    }
}

private struct LightSection: View {
    let frame: Frame
    @Environment(RollModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ManualAdjustments.Control.allCases, id: \.self) { control in
                LightAdjustmentRow(frame: frame, slider: .light(control))
                    .disabled(!model.canAdjust(frame))
                    .padding(.bottom, 10)
            }
            PresenceSection(frame: frame)
        }
    }
}

private struct PresenceSection: View {
    let frame: Frame
    @Environment(RollModel.self) private var model

    var body: some View {
        InspectorGroup(title: "Presence", summary: summary,
                       isOpen: model.isInspectorPresenceExpanded, toggle: {
            model.endLightAdjusting(for: frame)
            model.isInspectorPresenceExpanded.toggle()
        }) {
            VStack(spacing: 10) {
                ForEach(Presence.Control.allCases, id: \.self) { control in
                    LightAdjustmentRow(frame: frame, slider: .presence(control))
                }
            }
            .disabled(!model.canAdjust(frame))
        }
        .contextMenu(entries: { [InspectorMenus.resetPresence(frame, model: model)] })
    }

    private var summary: String {
        let values = if let live = model.printedLight, live.frame == frame.url {
            live.values.presence
        } else {
            model.manualAdjustments(for: frame).presence
        }
        let active = Presence.Control.allCases.filter { values.value(for: $0) != 0 }
        guard let first = active.first else { return "No changes" }
        if active.count > 1 { return InspectorEdits.editCount(active.count) }
        let value = AdjustmentSliderSpec.light(.presence(first)).formatted(values.value(for: first))
        return "\(first.title) \(value)"
    }
}

// MARK: - The foot

/// Compare to the starting point, held, and Reset, a menu: the tab's own resets, then the return to the starting point
/// (`InspectorMenus.resetMenu`). Every tab's is the same button in the same place, and nothing waits behind Option.
///
/// The two share the column's 248 points, and the longer comparison, Compare to Original, is never cut: Reset's face is as
/// narrow as its word (`InspectorMenuFace`), which leaves Compare its symbol and its words with room over, and should the
/// words ever want more, the symbol goes before they are cut (`AdjustInspectorStateTests` holds the fit at both starting points).
struct AdjustFooter: View {
    let frame: Frame
    @Environment(RollModel.self) private var model

    private var origin: AutomaticBaseline.Origin { model.startingPoint(for: frame) }
    private var isFromOriginal: Bool { origin == .original }

    private var canCompare: Bool {
        model.hasManualAdjustments(frame) && model.canAdjust(frame) && model.isAutoComparisonReady
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionDivider()
            HStack(spacing: Graphite.Metric.s) {
                compareButton
                Menu {
                    MenuEntries(make: { InspectorMenus.resetMenu(of: model.openAdjustSection, frame: frame, model: model) })
                } label: {
                    InspectorMenuFace(title: "Reset")
                }
                .graphiteMenu()
                .help("Reset the open tool or return the frame to its starting point")
                .accessibilityLabel("Reset")
            }
            .padding(.horizontal, Graphite.Metric.adjustPadding)
            .padding(.top, 10)
            .padding(.bottom, Graphite.Metric.m)
        }
    }

    private var compareButton: some View {
        Button {
            // VoiceOver and a keyboard activation can toggle the comparison; the pointer
            // gesture below shows it only while held, including cancellation on release.
            model.isComparingAuto.toggle()
        } label: {
            let words = Text(verbatim: AdjustActionText.compare(from: origin))
                .font(Graphite.Typeface.label)
                .lineLimit(1)
            // With its symbol where both fit, and its words alone before a word of them is cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: "square.split.2x1")
                        .font(.system(size: 12, weight: .light))
                        .accessibilityHidden(true)
                    words.fixedSize()
                }
                words.fixedSize()
                words
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.graphite(.secondary, size: .small, isOn: model.isComparingAuto))
        .disabled(!canCompare)
        .highPriorityGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in model.isComparingAuto = true }
            .onEnded { _ in model.isComparingAuto = false },
            including: canCompare ? .all : .none)
        .help(isFromOriginal ? "Hold to show the Original starting point without the adjustments, with the current stock and roll controls. Hold Space to compare with neutral RAW instead."
              : "Hold to show the pinned automatic starting point without the adjustments, with the current stock and roll controls. Hold Space to compare with neutral RAW instead.")
        .accessibilityLabel(AdjustActionText.compare(from: origin))
        .accessibilityValue(model.isComparingAuto ? (isFromOriginal ? "Showing Original" : "Showing Auto") : "Showing adjusted frame")
        .accessibilityHint(isFromOriginal ? "Activate to toggle the Original starting point" : "Activate to toggle the pinned automatic starting point")
    }
}

extension AdjustInspectorTab {
    /// The tab's word on the strip.
    var title: String {
        switch self {
        case .light: "Light"
        case .curve: "Curve"
        case .masks: "Masks"
        case .lens: "Lens"
        case .remove: "Remove"
        }
    }

    /// What VoiceOver says for its segment.
    var accessibilityLabel: String {
        switch self {
        case .light: "Light adjustments"
        case .curve: "Curve adjustments"
        case .masks: "Mask adjustments"
        case .lens: "Lens adjustments"
        case .remove: "Remove objects"
        }
    }

    /// Its help tag: what the tab holds, and its keys.
    var help: String {
        switch self {
        case .light: "Exposure, Contrast, Highlights, Shadows, Whites, Blacks and Presence (⌥⌘1)"
        case .curve: "Tone, Red, Green and Blue curves (⌥⌘2)"
        case .masks: "Change one part of this frame (\(MaskKeys.masksTab.chord?.symbols ?? ""), \(MaskKeys.masksTabView.chord?.symbols ?? ""))"
        case .lens: "Lens corrections (⌥⌘4)"
        case .remove: "Remove an object from this frame (\(Self.removeKey.symbols))"
        }
    }

    /// The Remove tab's key, as its help tag says it. The key itself is the menus'.
    static let removeKey = KeyChord("q")

    /// Its symbol on the strip, over its word.
    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .curve: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .masks: "circle.dashed"
        case .lens: "camera.aperture"
        case .remove: "eraser"
        }
    }
}

enum ManualAdjustmentNumberInput {
    enum Result: Equatable { case value(Float), invalid, superseded }

    static func resolve(_ text: String, control: ManualAdjustments.Control,
                        startingAt: ManualAdjustments?, current: ManualAdjustments,
                        locale: Locale = .current) -> Result {
        resolve(text, spec: .light(control), startingAt: startingAt, current: current, locale: locale)
    }

    /// `startingAt` is the row's snapshot when the entry began, `current` the snapshot now.
    static func resolve<Snapshot: Equatable>(_ text: String, spec: AdjustmentSliderSpec,
                                             startingAt: Snapshot?, current: Snapshot,
                                             locale: Locale = .current) -> Result {
        // A field may still own focus when Reset, Undo or a source refresh replaces its edit.
        // Even an unchanged control belongs to the old entry if another adjustment changed.
        guard let startingAt, startingAt == current else { return .superseded }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decimal = locale.decimalSeparator ?? "."
        let normalized = decimal == "." ? text : text.replacingOccurrences(of: decimal, with: ".")
        guard let parsed = Float(normalized), parsed.isFinite, spec.range.contains(parsed) else { return .invalid }
        return .value(spec.snapped(parsed))
    }
}

/// The sizes of an inspector row: its name and its value on one line, and its track under them, running the column's width.
/// Beside its name, as the row was until 2026-11-17, a track had what the name's column and the value's left it, 106 of the
/// column's 240 points; under them it has all 248, and so more than twice the travel for the same hand, at the row's old pitch
/// of 40 points (the line, the track and the room between two rows).
enum AdjustRowMetric {
    /// The row's first line, its name and its value.
    static let line: CGFloat = 18
    /// The track under it: the knob's 11 points and the ruler under the track.
    static let track: CGFloat = 16
    /// Between a row's name and its reset arrow, and the arrow's own width.
    static let nameGap: CGFloat = 1
    static let resetArrow: CGFloat = 12
    /// Wide enough for the longest value any row shows ("+5.00", 36.2 pt in the row's digits) inside the field's 4 pt padding a side: at 42 a
    /// two-decimal Exposure was truncated to "+0....".
    static let value: CGFloat = 46
    /// The least room between a name's reset arrow and the value.
    static let spacing: CGFloat = 6
    /// A range's two values, each wide enough for "100" inside the field's padding, and "to" between them.
    static let rangeValue: CGFloat = 34
    static let rangeWord: CGFloat = 16
    /// Between two rows; between two pairs of a tab's rows, which reads them as pairs; and over a group's heading.
    static let rowSpacing: CGFloat = 6
    static let pairSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 16
}

/// A value at the end of an inspector row: plain text until hovered or focused, then a field.
struct AdjustValueFieldStyle: ViewModifier {
    var isFocused: Bool
    var isHovered: Bool
    var isZero: Bool

    /// Whether the field draws its own text. A row whose value is drawn over it as text (`AdjustValueTextStyle`) leaves it clear
    /// until the field takes the keyboard.
    var showsText = true
    var width = AdjustRowMetric.value
    var font = Graphite.Typeface.number
    var height = AdjustRowMetric.line

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(font)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(!showsText ? AnyShapeStyle(Color.clear) : AnyShapeStyle(isZero && !isFocused ? Graphite.tertiaryText : Graphite.text))
            .padding(.horizontal, 4)
            .frame(height: height)
            .background(shape.fill(isFocused ? Graphite.control : isHovered ? Graphite.hoverFill : .clear))
            .overlay { shape.strokeBorder(Graphite.selection.opacity(isFocused ? 0.7 : 0), lineWidth: 1) }
            .frame(width: width)
    }
}

/// The value as `AdjustValueFieldStyle` draws its field's text, for a value shown as text over the field.
struct AdjustValueTextStyle: ViewModifier {
    var isZero: Bool
    var font = Graphite.Typeface.number

    func body(content: Content) -> some View {
        content
            .font(font)
            // A value at its default steps back, so the ones that moved are what a column of numbers shows.
            .foregroundStyle(isZero ? Graphite.tertiaryText : Graphite.text)
            .lineLimit(1)
            .padding(.horizontal, 4)
    }
}

/// Which of the values that come to a row from elsewhere its knob glides to and its number counts to: one that comes by
/// itself, a reset, an undo or a paste, which is seen to move them. A gradient's handle dragged on the photograph sends
/// its rows a run of values, each within `Graphite.Motion.runGap` of the last, and those are shown as they come: gliding
/// and counting to each, the rows trailed the handle and drew at every display frame beside the photograph, which lost a
/// fifth of the drag's refreshes (measured, Roll workflow section 24).
@MainActor
final class ValueArrivals {
    private var last: (value: Float, glides: Bool)?
    private var lastFromElsewhere: CFTimeInterval?
    private let now: () -> CFTimeInterval

    /// `now` is the clock, in seconds; a test gives its own.
    init(now: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.now = now
    }

    /// Whether the row glides and counts to `value`: it came from elsewhere, not from the row's own slider or scrub
    /// (`isOwn`), by itself and not as one of a run, and is not the first the row shows. Asked again about the same
    /// value it answers the same, so the row may ask each time it is drawn.
    func glides(to value: Float, isOwn: Bool) -> Bool {
        if let last, last.value == value { return last.glides }
        var glides = false
        if !isOwn {
            let time = now()
            let isInRun = lastFromElsewhere.map { time - $0 < Graphite.Motion.runGap } ?? false
            lastFromElsewhere = time
            glides = last != nil && !isInRun
        }
        last = (value, glides)
        return glides
    }
}

/// One of the Light tab's eleven, Light's six or Presence's five: the row below, bound to the frame's own values. Its gesture's
/// steps go to the print alone, the edit taking them once as it ends (`RollModel.moveLight`), as a mask's rows do; the row shows its
/// own steps meanwhile. A Presence row's menu also offers Reset Presence, which has no button.
struct LightAdjustmentRow: View {
    let frame: Frame
    let slider: ManualAdjustments.Slider
    @Environment(RollModel.self) private var model

    var body: some View {
        let gesture = model.lightGestureGeneration
        ManualAdjustmentRow(spec: .light(slider), help: slider.adjustmentHelp,
                            value: Binding(get: { model.manualAdjustments(for: frame).value(for: slider) },
                                           // A step the slider queued before the model replaced its gesture, landing before the row
                                           // is drawn again with the new one, is the old gesture's.
                                           set: { if model.lightGestureGeneration == gesture { model.moveLight(slider, to: $0, for: frame) } }),
                            snapshot: model.manualAdjustments(for: frame),
                            gesture: gesture,
                            beginGesture: { model.beginLightAdjusting(for: frame) },
                            endGesture: { model.endLightAdjusting(for: frame) },
                            groupReset: groupReset,
                            layout: slider == .light(.exposure) ? .exposure : .row)
            // One of Light's six lights its tonal range on the histogram while the pointer is over its row. The row does not
            // read the zone, so lighting it runs the histogram alone.
            .onHover { isOver in
                guard case .light(let control) = slider else { return }
                if isOver {
                    model.histogramZone = control
                } else if model.histogramZone == control {
                    model.histogramZone = nil
                }
            }
    }

    private var groupReset: (@MainActor () -> MenuEntry)? {
        guard case .presence = slider else { return nil }
        return { [model, frame] in InspectorMenus.resetPresence(frame, model: model) }
    }
}

/// How an inspector slider's row is laid out.
enum ManualAdjustmentRowLayout: Equatable, Sendable {
    /// Its name and its value on a line, its track under them.
    case row, exposure
    /// One end of a range, laid with the other over a name and a track that their row draws (`LensHueRow`): no name of its
    /// own, and on the track its knob alone. The low end's value stands before the high end's, which comes last on the line
    /// after "to".
    case rangeLow, rangeHigh
}

/// A whole row answers the pointer where it has nothing drawn, so its hover holds between its name and its value. A range's
/// end does not: it lies over the other end and their name, which must be reached through where it is empty.
private struct RowHitShape: ViewModifier {
    let isWhole: Bool

    func body(content: Content) -> some View {
        if isWhole { content.contentShape(Rectangle()) } else { content }
    }
}

/// An inspector slider's row: its name, the slider and its value, whatever the value belongs to; the
/// Light tab's eleven (`LightAdjustmentRow`) and a selected mask's Amount and six are the same row, with
/// its keys, scrubbing, double-click reset and Option clipping view. A right-click on its name, its slider
/// or its value offers that reset by the row's name (`InspectorMenus.sliderRow`), then its group's reset if it is given one; the
/// value keeps its field's own text menu while it is typed in.
/// The slider streams valid values during a drag, then commits one complete edit gesture.
/// Its numeric field rejects invalid input instead of silently clamping a photographer's entry.
///
/// `snapshot` is whatever the value is part of: a typed entry belongs to the snapshot it began on, and
/// is dropped if that has changed by the time it commits (`ManualAdjustmentNumberInput`). It is `Sendable`, a value, so the
/// row's `==`, which SwiftUI calls off the main actor, may compare it. Disable the row with `.disabled`.
struct ManualAdjustmentRow<Snapshot: Equatable & Sendable>: View {
    let spec: AdjustmentSliderSpec
    /// What the control does, which its help tags and VoiceOver's hint begin with.
    let help: String
    @Binding var value: Float
    let snapshot: Snapshot
    /// Which of the value's owner's gestures a drag is in: the owner counts another when it ends one under the row while the pointer
    /// may still be down (a reset, a paste, an undo; `RollModel.lightGestureGeneration`). The row then shows the value it is given,
    /// not the old gesture's steps, and its slider and value drop what they queued and go on from it. A row whose owner never does
    /// leaves it at 0.
    let gesture: Int
    /// One edit gesture, and one undo step: a drag from press to release, or a typed value or reset,
    /// which are set between the two.
    let beginGesture: () -> Void
    let endGesture: () -> Void
    /// The reset of the row's group, under its own in its menu, made as the menu opens.
    let groupReset: (@MainActor () -> MenuEntry)?
    let menuSwitch: (@MainActor () -> MenuEntry)?
    /// How the row is laid out (`ManualAdjustmentRowLayout`).
    let layout: ManualAdjustmentRowLayout
    /// Where inside the spec's range the value may stand just now, when that is less than the range: one end of a range
    /// stops short of the other. The knob, a scrub and a typed value all stop there.
    let limits: ClosedRange<Float>?
    /// `value` as it was when the row was made: what the row shows, and what `==` compares. The body reads this rather than the
    /// binding, so a row is not run again by the model's observation for a write that leaves its value as it was; its parent, which
    /// reads the model, makes it again with the new value.
    private let shown: Float
    /// The newest value of a gesture under way, ahead of `shown` until it ends: a mask's rows write the print alone while they move
    /// (`RollModel.moveMaskValue`), so nothing makes the row again before the release, and the row shows its own steps meanwhile.
    /// Kept with the `gesture` it was made in, so a step of one the owner has since replaced is not shown.
    @State private var live: Live?
    private struct Live: Equatable {
        var value: Float
        var gesture: Int
    }
    @Environment(RollModel.self) private var model
    @FocusState private var numberFocused: Bool
    @FocusState private var resetFocused: Bool
    @State private var number = ""
    @State private var numberSnapshot: Snapshot?
    @State private var validationMessage: String?
    @State private var isDragging = false
    @State private var isHovered = false
    @State private var sliderFocused = false
    /// The value the row last set by its own slider or scrub. A value that is not that one came from elsewhere, a reset, an
    /// undo, a paste or a typed entry: the knob glides to it and the number counts to it, where its own steps are shown at once.
    @State private var written: Float?
    /// When a value last came from elsewhere, which says whether the next is glided to or shown as it comes.
    @State private var arrivals = ValueArrivals()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    init(spec: AdjustmentSliderSpec, help: String, value: Binding<Float>, snapshot: Snapshot, gesture: Int = 0,
         beginGesture: @escaping () -> Void, endGesture: @escaping () -> Void, groupReset: (@MainActor () -> MenuEntry)? = nil, menuSwitch: (@MainActor () -> MenuEntry)? = nil,
         layout: ManualAdjustmentRowLayout = .row, limits: ClosedRange<Float>? = nil) {
        self.spec = spec
        self.help = help
        _value = value
        self.snapshot = snapshot
        self.gesture = gesture
        self.beginGesture = beginGesture
        self.endGesture = endGesture
        self.groupReset = groupReset
        self.menuSwitch = menuSwitch
        self.layout = layout
        self.limits = limits
        shown = value.wrappedValue
    }

    var body: some View {
        // The knob glides and the number counts to a value from elsewhere that comes by itself.
        let glides = !reduceMotion && arrivals.glides(to: current, isOwn: isOwnValue)
        let isExposure = layout == .exposure
        let isWholeRow = layout == .row || isExposure
        let card = RoundedRectangle(cornerRadius: 8)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if isWholeRow {
                    HStack(spacing: AdjustRowMetric.nameGap) {
                        Text(spec.title)
                            .font(isExposure ? Graphite.Typeface.label.weight(.semibold) : Graphite.Typeface.label)
                            .foregroundStyle(Graphite.text)
                            .lineLimit(1)
                            .fixedSize()
                            // As in Lightroom, double-clicking the name resets the control, as its knob does.
                            .onTapGesture(count: 2, perform: reset)
                        resetButton
                    }
                    .contentShape(Rectangle())
                    // The slider and the value are AppKit's and give the same table from `menu(for:)`.
                    .contextMenu(entries: menuEntries)
                }
                Spacer(minLength: AdjustRowMetric.spacing)
                if layout == .rangeHigh {
                    Text("to")
                        .font(Graphite.Typeface.small)
                        .foregroundStyle(Graphite.secondaryText)
                        .frame(width: AdjustRowMetric.rangeWord)
                        .accessibilityHidden(true)
                }
                valueField(counts: glides)
                    // The figures, not the field's padding, end where the track does; a range's first stands clear of
                    // "to" and its second.
                    .padding(.trailing, layout == .rangeLow ? AdjustRowMetric.rangeValue + AdjustRowMetric.rangeWord - 4 : -4)
                if isExposure {
                    Text("EV")
                        .font(Graphite.Typeface.caption)
                        .foregroundStyle(Graphite.secondaryText)
                        .padding(.leading, 6)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: isExposure ? 25 : AdjustRowMetric.line)
            AdjustmentSlider(value: Binding(get: { liveValue ?? value }, set: write), spec: spec, gesture: gesture,
                             glides: glides,
                             onEditingChanged: dragChanged, onReset: reset,
                             onFocusChanged: { sliderFocused = $0 }, onClipping: showClipping,
                             isClippingShown: model.lightClipping != nil, menu: menuEntries,
                             showsRuler: isHovered || isDragging || sliderFocused, showsEVScale: isExposure, limits: limits)
                .frame(height: isExposure ? 23 : AdjustRowMetric.track)
                .help(spec.sliderHelp(help))
            if isExposure {
                HStack {
                    Text("−5")
                    Spacer()
                    Text("0")
                    Spacer()
                    Text("+5")
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Graphite.secondaryText)
                .padding(.horizontal, 5)
                .accessibilityHidden(true)
            }
            if let validationMessage {
                Text(verbatim: validationMessage)
                    .font(Graphite.Typeface.caption)
                    .foregroundStyle(Graphite.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(isExposure ? 11 : 0)
        .background {
            if isExposure {
                card.fill(Graphite.ink(0.045))
                    .overlay { card.strokeBorder(Graphite.border, lineWidth: 1) }
            }
        }
        .modifier(RowHitShape(isWhole: isWholeRow))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isHovered)
        .onAppear { number = spec.formatted(value) }
        // A value from elsewhere: the next of the row's own is its own again.
        .onChange(of: shown) { _, new in
            if written != nil, written != new { written = nil }
        }
        .onChange(of: snapshot) { _, updated in
            if numberFocused, updated != numberSnapshot { numberFocused = false }
            // The field's own text is written when it takes the keyboard (`numberFocused`), not at each step of a drag: rewriting an
            // AppKit text field 30 times a second cost a mask slider's drag about a twelfth of the main thread (measured, G).
            if !numberFocused { validationMessage = nil }
        }
        .onChange(of: numberFocused) { _, focused in
            if focused {
                number = spec.formatted(value)
                numberSnapshot = snapshot
                validationMessage = nil
            } else {
                commitNumber()
                numberSnapshot = nil
            }
        }
        .onDisappear {
            if numberFocused { commitNumber() }
            if isDragging { isDragging = false; endGesture(); live = nil }
        }
    }

    /// The row's reset: what a double-click on its name or its knob, its reset button, its slider's accessibility action and its
    /// menu do. One gesture, and one undo step, unless it is already there.
    private func reset() {
        numberFocused = false
        setValue(spec.defaultValue)
    }

    /// The row's context menu, made as it opens: its reset, disabled at its default, then its group's; each disabled while the row is
    /// disabled and during its own gesture (a right-click cannot come in a drag's own event loop, but nothing here should depend on that).
    private func menuEntries() -> [MenuEntry] {
        MenuEntry.sections([menuSwitch.map { [$0()] } ?? [], InspectorMenus.sliderRow(title: spec.title, isChanged: current != spec.defaultValue, isEnabled: isEnabled && !isDragging, reset: reset,
                                 group: groupReset?())])
    }

    /// Per-control reset, shown on hover or focus while the control is off its default.
    private var resetButton: some View {
        let isChanged = shown != spec.defaultValue
        return Button(action: reset) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 9, weight: .medium))
                .frame(width: AdjustRowMetric.resetArrow, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Graphite.secondaryText)
        .focused($resetFocused)
        .disabled(!isChanged)
        .opacity(isChanged && (isHovered || numberFocused || sliderFocused || resetFocused) ? 1 : 0)
        .accessibilityHidden(!isChanged)
        .help("Reset \(spec.title.lowercased()). You can also double-click its name or its slider.")
        .accessibilityLabel("Reset \(spec.title.lowercased())")
    }

    /// The newest value of the gesture under way, if the owner has not replaced it.
    private var liveValue: Float? { live.flatMap { $0.gesture == gesture ? $0.value : nil } }

    /// What the row shows: the gesture's newest value while one moves, else the value it was made with.
    private var current: Float { liveValue ?? shown }

    /// Whether what the row shows is what its own slider or scrub last set.
    private var isOwnValue: Bool { isDragging || written == current }

    /// The value: drawn as text, which follows every step of a drag, until the field takes the keyboard and holds what is typed.
    /// A value come from elsewhere by itself is counted to (`counts`), as the knob glides there.
    private func valueField(counts: Bool) -> some View {
        let isExposure = layout == .exposure
        let font = isExposure ? Font.system(size: 20, design: .monospaced) : Graphite.Typeface.number
        return TextField(spec.title, text: $number)
            .modifier(AdjustValueFieldStyle(isFocused: numberFocused, isHovered: isHovered, isZero: current == spec.defaultValue,
                                            showsText: numberFocused,
                                            width: isExposure ? 72 : layout == .row ? AdjustRowMetric.value : AdjustRowMetric.rangeValue,
                                            font: font, height: isExposure ? 25 : AdjustRowMetric.line))
            .overlay(alignment: .trailing) {
                if !numberFocused {
                    // Counts to a value from elsewhere, as the knob glides there; the row's own steps, and a run from
                    // elsewhere, are shown at once.
                    Animated(value: CGFloat(current)) { counted in
                        // Each figure on the way is put up whole: a fade from one to the next would blur them all.
                        Text(verbatim: spec.formatted(spec.snapped(Float(counted))))
                            .modifier(AdjustValueTextStyle(isZero: current == spec.defaultValue, font: font))
                            .transaction { $0.animation = nil }
                    }
                    .animation(counts ? Graphite.Motion.value : nil, value: current)
                    .accessibilityHidden(true)
                }
            }
            .overlay {
                if !numberFocused {
                    ValueScrubber(spec: spec, value: current, gesture: gesture, onEditingChanged: dragChanged,
                                  onScrub: write, onClick: { numberFocused = true }, onClipping: showClipping, menu: menuEntries)
                        .help(spec.entryHelp(help) + " Drag left or right over the value to change it, Shift in larger steps.")
                }
            }
            .focused($numberFocused)
            .onSubmit { commitNumber(); numberFocused = false }
            .accessibilityLabel("\(spec.title) value")
            .accessibilityValue(spec.spoken(current))
            .accessibilityHint(validationMessage ?? spec.entryHelp(help))
            .help(spec.entryHelp(help))
    }

    /// A drag of the slider or over the value: one edit gesture, and one undo step, from press to release.
    private func dragChanged(_ editing: Bool) {
        if editing {
            if numberFocused { commitNumber(); numberFocused = false }
            isDragging = true
            beginGesture()
        } else {
            isDragging = false
            endGesture()
            live = nil
        }
    }

    /// `asked` inside `limits`, where the row has them.
    private func limited(_ asked: Float) -> Float {
        limits.map { min($0.upperBound, max($0.lowerBound, asked)) } ?? asked
    }

    /// A step of the slider or the scrub: shown at once by the row, and written through the binding. Held to the row's
    /// limits here, since a scrub counts along the spec's whole range: unheld, a range's end scrubbed past the other showed a
    /// number the value never took, and its knob stood beyond the other's until the gesture ended.
    private func write(_ asked: Float) {
        let newValue = limited(asked)
        let step = Live(value: newValue, gesture: gesture)
        if isDragging, live != step { live = step }
        if written != newValue { written = newValue }
        value = newValue
    }

    private func showClipping(_ on: Bool) {
        model.lightClipping = on ? spec.clipping : nil
    }

    private func commitNumber() {
        switch ManualAdjustmentNumberInput.resolve(number, spec: spec, startingAt: numberSnapshot, current: snapshot) {
        case .value(let stepped):
            setValue(stepped)
        case .invalid:
            validationMessage = spec.entryLimits
        case .superseded:
            number = spec.formatted(value)
            validationMessage = nil
        }
    }

    private func setValue(_ asked: Float) {
        let newValue = limited(asked)
        if newValue != value {
            beginGesture()
            value = newValue
            endGesture()
        }
        number = spec.formatted(newValue)
        validationMessage = nil
    }
}

extension ManualAdjustments.Control {
    var adjustmentHelp: String {
        switch self {
        case .exposure: "Change scene exposure entering the film, in EV. +1 EV doubles the light; Rated at remains independent."
        case .contrast: "Separate or soften dark and light print tones around the midtones."
        case .highlights: "Brighten or compress upper tonal detail before the film is developed."
        case .shadows: "Lift or deepen lower tonal detail before the film is developed."
        case .whites: "Raise or lower the brightest print tones."
        case .blacks: "Lift the darkest print tones for a softer black, or deepen them."
        }
    }
}

extension Presence.Control {
    var adjustmentHelp: String {
        switch self {
        case .texture: "Bring out or smooth fine detail before the film is developed."
        case .clarity: "Strengthen or soften local contrast before the film is developed."
        case .dehaze: "Clear or add atmospheric haze in the scene's light, before Exposure."
        case .vibrance: "Intensify muted print colours more than vivid ones, sparing skin tones, or mute them."
        case .saturation: "Intensify or mute every print colour alike; at −100 the print is grey."
        }
    }
}

extension ManualAdjustments.Slider {
    var adjustmentHelp: String {
        switch self {
        case .light(let control): control.adjustmentHelp
        case .presence(let control): control.adjustmentHelp
        case .lens(let control):
            switch control {
            case .distortion: "Adjust the amount of distortion correction."
            case .vignette: "Brighten or darken the corners before the film is developed."
            case .vignetteMidpoint: "Set how far the vignetting reaches toward the centre."
            case .purpleAmount: "Remove purple fringes along edges; higher amounts reach farther from clean colour."
            case .purpleHueLow: "Set the low end of the purple fringe hues; it stops 10 below the high end."
            case .purpleHueHigh: "Set the high end of the purple fringe hues; it stops 10 above the low end."
            case .greenAmount: "Remove green fringes along edges; higher amounts reach farther from clean colour."
            case .greenHueLow: "Set the low end of the green fringe hues; it stops 10 below the high end."
            case .greenHueHigh: "Set the high end of the green fringe hues; it stops 10 above the low end."
            }
        }
    }
}

/// A row compared by what it shows: its control, its value, its snapshot and its gesture (the gestures' closures do the same thing for
/// the same control). With `.equatable()` a write elsewhere that leaves these as they were runs no body (G: six rows were about 0.35 s of
/// every 8).
extension ManualAdjustmentRow: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.spec == b.spec && a.shown == b.shown && a.snapshot == b.snapshot && a.gesture == b.gesture && a.help == b.help
            && a.layout == b.layout && a.limits == b.limits
    }
}
