import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI

/// The roll's Develop page, in the workspace (the rail's Develop, Command-D): the frames a develop covers
/// in the contact sheet's own grid, under its filter row, which is which frames develop. Each frame is
/// shown as it will be written, in the colour space chosen beside it, and marked with what came of it in
/// the develop running or the last one (`RollModel.developMarks`). Where the files go, as what, and the
/// Develop button are in the panel beside the workspace (`DevelopPanel`), where Adjust's inspector stands
/// in the frame view. A double click or Return opens a frame on the roll, to change it before it develops.
struct DevelopPage: View {
    let roll: Roll
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The notices' height at the top: the grid starts under them.
    @State private var noticesHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: ContactSheet.Spacing.pageTop)
                SheetFilterBar()
                    // Over the grid, whose faded edge runs under the row's foot.
                    .zIndex(1)
                // Room for the notices floating under the filter row, so they never cover a frame.
                Color.clear.frame(height: noticesHeight > 0.5 ? noticesHeight + Graphite.Metric.s : 0)
                ContactSheet(roll: roll, marks: model.developMarks, name: "Frames to develop")
                    .padding(.top, -ContactSheet.Spacing.topOverlap)
            }
            // The proofing surround is the photographs' surround.
            .background(model.graySurround ? Palette.gray18 : Color.clear)
            NoticeStack(height: $noticesHeight)
                .padding(.top, ContactSheet.Spacing.pageTop)
        }
        .animation(reduceMotion ? nil : (model.offeredCard != nil ? Graphite.Motion.arrive : Motion.stateChange), value: model.offeredCard)
        .animation(reduceMotion ? nil : (model.message != nil ? Graphite.Motion.arrive : Motion.stateChange), value: model.message)
        .animation(reduceMotion ? nil : Motion.stateChange, value: noticesHeight)
    }
}

/// The Develop page's panel, a glass column beside the workspace as the Adjust inspector is: what a
/// develop covers and through what; the folder its files go to, the roll's own once chosen; the format,
/// quality, colour space and grain they are written with, kept for every roll (`RollModel.output`); and
/// at its foot where a develop stands and the one button for its next action (`DevelopPrimary`): Develop
/// the frames shown, Stop while one runs, Resume, Develop again, Reveal in Finder. The choices are a
/// develop's when it starts, so they wait while one runs.
struct DevelopPanel: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Above the heading: the workspace's content edge, as the Adjust inspector's is.
    private static let top = Graphite.Metric.edge

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                        .padding(.bottom, 16)
                    SectionDivider()
                    Group {
                        saveTo
                            .padding(.vertical, 14)
                        SectionDivider()
                        options
                            .padding(.vertical, 18)
                    }
                    .disabled(model.isDeveloping)
                }
                .padding(.horizontal, Graphite.Metric.inspectorPadding)
                .padding(.top, Self.top)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            // The status and the button stay at the panel's foot, in reach in a short window.
            footer
                .padding(.horizontal, Graphite.Metric.inspectorPadding)
                .padding(.bottom, Graphite.Metric.inspectorPadding)
        }
        .frame(width: Graphite.Metric.inspectorPanelWidth)
        .graphiteFloating(cornerRadius: Graphite.Metric.workspaceRadius, besideWorkspace: true)
        .foregroundStyle(Graphite.text)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Develop")
        .animation(reduceMotion ? nil : Motion.stateChange, value: model.developStatus)
    }

    // MARK: Heading

    private var heading: some View {
        HStack(alignment: .top, spacing: Graphite.Metric.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Develop")
                    .font(Graphite.Typeface.panelTitle)
                    .foregroundStyle(Graphite.text)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: DevelopStatusText.summary(model, frames: model.framesToDevelop()))
                    .font(Graphite.Typeface.body)
                    .foregroundStyle(Graphite.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Graphite.Metric.s)
            CloseButton(help: "Close Develop") { model.closeDevelopPage() }
                // Escape anywhere on the page, as a panel's close does; an open pop-up takes it first.
                .keyboardShortcut(.cancelAction)
                .padding(.top, 1)
        }
    }

    // MARK: Save to

    @ViewBuilder private var saveTo: some View {
        @Bindable var model = model
        DevelopFolderField(choice: $model.developFolder, isDeveloping: model.isDeveloping) { [roll = model.roll?.folder] folder in
            if model.roll?.folder == roll { model.chooseDestination(folder) }
        }
    }

    // MARK: Output

    private var options: some View {
        @Bindable var model = model
        return DevelopOutputRows(output: $model.output)
    }

    // MARK: Status and button

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionDivider()
            status
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            SectionDivider()
            DevelopPageButton()
                .padding(.top, 16)
        }
    }

    /// Where a develop stands. Its first line is one line whatever the state, so the spinner of a develop under way
    /// gives way in place to the check of one that finished, which is drawn on, and the words change under it; what
    /// follows the line is the state's own.
    private var status: some View {
        let status = model.developStatus
        let isDeveloping = if case .developing = status { true } else { false }
        return VStack(alignment: .leading, spacing: isDeveloping ? 6 : 5) {
            HStack(alignment: .top, spacing: Graphite.Metric.s) {
                StatusLabel(symbol: Self.symbol(status), text: status.map(statusTitle) ?? "Original RAW files are preserved",
                            isBusy: isDeveloping, emphasis: status != nil)
                    .help(status == nil ? "Raw files are never changed; each frame's recipe is saved beside its raw." : "")
                if case .stopped = status { closeIssues } else if case .failed = status { closeIssues }
            }
            switch status {
            case nil:
                EmptyView()
            case .developing(let progress, _)?:
                developing(progress)
            case .complete(let report)?:
                counts(.complete(report), report: report)
                destinationText(report.destination)
            case .stopped(let report)?:
                unfinished(.stopped(report), report: report)
            case .failed(let report)?:
                unfinished(.failed(report), report: report)
            }
        }
    }

    /// The status line's symbol: the check of a develop that finished, which a develop under way keeps under its
    /// spinner so that it is the one drawn on when the spinner goes.
    private static func symbol(_ status: DevelopStatus?) -> String {
        switch status {
        case nil: "lock"
        case .developing?, .complete?: "checkmark.circle"
        case .stopped(let report)?, .failed(let report)?: report.wasStopped ? "stop.circle" : "exclamationmark.triangle"
        }
    }

    /// The line's words: a develop under way says whether it is still balancing the roll.
    private func statusTitle(_ status: DevelopStatus) -> String {
        if case .developing(let progress, _) = status {
            return DevelopStatusText.title(.developing(progress, balancing: model.isDevelopBalancing))
        }
        return DevelopStatusText.title(status)
    }

    /// Hands the button back to Develop with the frames shown.
    @ViewBuilder private var closeIssues: some View {
        Spacer(minLength: 0)
        CloseButton(help: "Hide this until the next develop finishes") { model.areIssuesDismissed = true }
    }

    @ViewBuilder private func developing(_ progress: DevelopProgress) -> some View {
        let state = DevelopStatus.developing(progress, balancing: model.isDevelopBalancing)
        // The count rolls from one frame to the next.
        Text(verbatim: DevelopStatusText.counts(state))
            .font(Graphite.Typeface.label.monospacedDigit())
            .foregroundStyle(Graphite.secondaryText)
            .lineLimit(1)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : Graphite.Motion.quick, value: DevelopStatusText.counts(state))
        ProgressView(value: progress.fraction)
            .progressViewStyle(DevelopBarStyle())
            .accessibilityLabel("Develop progress")
            .accessibilityValue(progress.label)
        // "JPEG · Display P3 · Portra 400": what the develop writes, and through what.
        Text(verbatim: model.runningDevelopSummary)
            .font(Graphite.Typeface.small)
            .foregroundStyle(Graphite.secondaryText)
            .lineLimit(1)
    }

    /// A develop that stopped or left frames behind: what happened, why, the frames' own reasons in
    /// Details, and a close beside its first line, which hands the button back to Develop with the frames shown.
    @ViewBuilder private func unfinished(_ state: DevelopStatus, report: DevelopReport) -> some View {
        counts(state, report: report)
        if let detail = DevelopStatusText.detail(state) {
            Text(verbatim: detail)
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(detail)
        }
        DevelopDetailsButton()
            // The quiet button's own inset, so its title starts on the lines above it.
            .padding(.leading, -8)
    }

    private func counts(_ state: DevelopStatus, report: DevelopReport) -> some View {
        Text(verbatim: DevelopStatusText.counts(state))
            .font(Graphite.Typeface.label.monospacedDigit())
            .foregroundStyle(Graphite.secondaryText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(report.countsLine)
    }

    private func destinationText(_ destination: URL) -> some View {
        Text(verbatim: DevelopStatusText.folder(destination))
            .font(Graphite.Typeface.small)
            .foregroundStyle(Graphite.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(destination.path)
            .accessibilityLabel("Destination, \(DevelopStatusText.folder(destination))")
    }
}

/// Destination controls shared by the Develop panel and Quick Develop. Choose selects the parent folder.
struct DevelopFolderField: View {
    @Binding var choice: DevelopFolder
    private var folder: URL { choice.base }
    /// A develop is under way: the folder is looked for again when it ends, since a develop makes it.
    var isDeveloping = false
    let choose: (URL) -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    /// Whether the folder shown is there yet; asked off the main thread, since it may be on a slow volume.
    @State private var folderExists = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.actionRadius, style: .continuous)
        let parent = DevelopStatusText.abbreviated(folder.deletingLastPathComponent())
        VStack(alignment: .leading, spacing: Graphite.Metric.s) {
            Text("Save to")
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .accessibilityHidden(true)
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Graphite.secondaryText)
                    .accessibilityHidden(true)
                Text(verbatim: DevelopStatusText.folder(folder))
                    .font(Graphite.Typeface.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(shape.fill(Graphite.ink(0.05)))
            .overlay { shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1) }
            .help(folder.path)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Save to \(folder.lastPathComponent), in \(parent)" + (folderExists ? "" : ", a new folder"))
            HStack(spacing: Graphite.Metric.s) {
                Text(verbatim: folderExists ? parent : "New folder")
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folderExists ? folder.path : "A develop makes this folder")
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Button("Choose…") { chooseFolder() }
                    .buttonStyle(.graphite(.secondary, size: .small))
                    .fixedSize()
                    .help("Choose another folder for this roll's developed files")
            }
            Toggle("Save in a subfolder", isOn: $choice.usesSubfolder)
                .toggleStyle(.checkbox)
                .font(Graphite.Typeface.label)
            if choice.usesSubfolder {
                TextField("Subfolder name", text: $choice.subfolderName)
                    .textFieldStyle(.roundedBorder)
                    .font(Graphite.Typeface.body)
                    .accessibilityLabel("Subfolder name")
                if choice.destination == nil {
                    Text("Enter a single folder name.")
                        .font(Graphite.Typeface.small)
                        .foregroundStyle(Graphite.secondaryText)
                }
            }
        }
        .task(id: FolderCheck(folder: folder, phase: isDeveloping)) {
            let exists = await Task.detached { [folder] in FileManager.default.fileExists(atPath: folder.path) }.value
            if !Task.isCancelled { folderExists = exists }
        }
    }

    /// The folder is looked for again when another is chosen and when a develop, which makes it, ends.
    private struct FolderCheck: Equatable {
        var folder: URL
        var phase: Bool
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where the developed files go"
        panel.directoryURL = folder.deletingLastPathComponent()
        panel.begin { response in
            if response == .OK, let url = panel.url { choose(url) }
        }
    }
}

/// Format, Quality, Color space and Grain, each a label beside its control: the Develop page's panel binds them to the
/// choices kept for every roll (`RollModel.output`), and the quick develop dialog to its own until Develop is pressed.
struct DevelopOutputRows: View {
    @Binding var output: OutputSettings
    /// The quick develop dialog's frames' own grain (`RollModel.quickDevelopGrain`): one frame's, shown in place of the roll's
    /// and not changed here, and a line under the row on what it reaches.
    var ownGrain: QuickDevelopGrain? = nil

    /// A row's label, beside its control.
    private static let labelWidth: CGFloat = 84

    var body: some View {
        VStack(spacing: Graphite.Metric.m) {
            row("Preset") {
                HStack(spacing: Graphite.Metric.xs) {
                    Button("Instagram") { output = output.applyingInstagramPreset(.instagramFeed) }
                        .buttonStyle(.graphite(output.size == .instagramFeed && output.isInstagramPreset ? .primary : .secondary, size: .small))
                        .help("One-click sRGB JPEG at 1080 px long edge (quality 90) for Instagram")
                    Button("1350 px") { output = output.applyingInstagramPreset(.instagramPortrait) }
                        .buttonStyle(.graphite(output.size == .instagramPortrait && output.isInstagramPreset ? .primary : .secondary, size: .small))
                        .help("One-click sRGB JPEG at 1350 px long edge (quality 90) for vertical Instagram posts; preserves camera aspect ratio")
                }
            }
            row("Format") { OutputPicker.format($output) }
            row("Quality") { QualityControl(output: $output) }
            row("Size") { OutputPicker.size($output) }
            row("Color space") { OutputPicker.space($output) }
            if let own = ownGrain?.own {
                row("Grain") {
                    OutputPicker.grain(.constant(output.grain(own)))
                        .disabled(true)
                        .help(ownGrain?.note ?? "")
                }
            } else {
                row("Grain") { OutputPicker.grain($output) }
            }
            if let note = ownGrain?.note {
                Text(verbatim: note)
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.labelWidth)
            }
        }
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(Graphite.Typeface.label)
                .foregroundStyle(Graphite.text)
                .frame(width: Self.labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            control()
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: Graphite.Metric.controlHeight)
    }
}

/// The button at the foot of the Develop page's panel: the one next action of a develop
/// (`DevelopPrimary`), as wide as the panel. "Develop 24" develops the frames shown; while the roll
/// develops it reads Stop, plainly, and stops it after the frames in progress; "Resume" goes on with a
/// stopped develop's frames, "Develop again" retries frames that failed, and "Reveal in Finder" shows a
/// finished develop's files. The status over it says the rest.
struct DevelopPageButton: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        let primary = model.developPrimary
        let stops = if case .stop = primary { true } else { false }
        let help = primary.help(filtered: model.flagFilter != .all)
        Button(action: model.performDevelopPrimary) {
            // A count in the title rolls ("Develop 24" to "Develop 23"); another action's title comes on a short fade.
            RollingText(text: stops ? "Stop" : primary.title)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PanelActionButtonStyle(isPrimary: !stops))
        .disabled(!model.canPerformDevelopPrimary)
        .help(help)
        .accessibilityLabel(primary.accessibilityLabel)
        .accessibilityValue(primary.accessibilityValue)
        // An empty hint would replace the help tag VoiceOver reads; say the help instead.
        .accessibilityHint(primary.accessibilityHint.isEmpty ? help : primary.accessibilityHint)
    }
}

/// A panel's one action, drawn on its glass: the primary colour lit from above, since glass is not
/// stacked on glass and an inactive window's glass would drop a tint, or plain as a secondary action
/// is there. It answers hover and press and dims when disabled.
private struct PanelActionButtonStyle: ButtonStyle {
    var isPrimary = true

    func makeBody(configuration: Configuration) -> some View {
        PanelActionButton(configuration: configuration, isPrimary: isPrimary)
    }
}

private struct PanelActionButton: View {
    let configuration: ButtonStyle.Configuration
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.actionRadius, style: .continuous)
        configuration.label
            .font(Graphite.Typeface.action)
            .lineLimit(1)
            .foregroundStyle(isPrimary ? Graphite.onPrimary : Graphite.text)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background {
                if isPrimary {
                    shape.fill(LinearGradient(colors: [Graphite.primaryTop, Graphite.primaryBottom], startPoint: .top, endPoint: .bottom))
                } else {
                    shape.fill(Graphite.ink(configuration.isPressed ? 0.13 : isHovered ? 0.09 : 0.05))
                }
            }
            .overlay {
                if isPrimary {
                    shape.fill(configuration.isPressed ? Color.black.opacity(0.10) : Color.white.opacity(isHovered ? 0.08 : 0))
                        .allowsHitTesting(false)
                } else {
                    shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { isHovered = $0 }
            .animation(Graphite.Motion.quick, value: isHovered)
            .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isPrimary)
            .pressSpring(configuration.isPressed, depth: 0.97)
    }
}

/// Details ⌄: the frames a develop did not finish and why, and the raws left out of the roll,
/// in a popover (`IssueDetails`).
struct DevelopDetailsButton: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        Button { model.isIssueDetailsShown.toggle() } label: {
            HStack(spacing: 6) {
                Text("Details")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .rotationEffect(.degrees(model.isIssueDetailsShown ? 180 : 0))
                    .animation(reduceMotion ? nil : Graphite.Motion.quick, value: model.isIssueDetailsShown)
                    .accessibilityHidden(true)
            }
            .font(Graphite.Typeface.body)
        }
        .buttonStyle(.graphite(.quiet, isOn: model.isIssueDetailsShown))
        .fixedSize()
        .help("The frames not developed and what went wrong")
        .accessibilityValue(model.isIssueDetailsShown ? "Shown" : "Hidden")
        .popover(isPresented: $model.isIssueDetailsShown, arrowEdge: .leading) {
            // The system's popover, on its own glass.
            IssueDetails()
        }
    }
}

/// A develop's bar: a thin track and the frames finished in the primary colour.
private struct DevelopBarStyle: ProgressViewStyle {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let fraction = min(max(configuration.fractionCompleted ?? 0, 0), 1)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Graphite.ink(contrast == .increased ? 0.32 : 0.16))
                Capsule().fill(Graphite.primaryTop)
                    .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 6 : 0))
            }
        }
        .frame(height: 5)
        .animation(reduceMotion ? nil : Motion.stateChange, value: fraction)
    }
}

/// A frame's mark on the Develop page's grid, at its picture's lower right: a check once the develop
/// has its file, on a dark disc so it reads on any picture, or an exclamation mark on the selection
/// colour where the develop could not write it. Plain fills, which an inactive window keeps.
struct DevelopMarkBadge: View {
    let mark: DevelopMark
    let side: CGFloat

    var body: some View {
        Image(systemName: mark == .developed ? "checkmark" : "exclamationmark")
            .font(.system(size: (side * 0.5).rounded(), weight: .bold))
            .foregroundStyle(mark == .developed ? Color.white : Graphite.onPrimary)
            .frame(width: side, height: side)
            .background {
                Circle().fill(mark == .developed ? Color.black.opacity(0.58) : Graphite.selection.opacity(0.96))
            }
            .overlay { Circle().strokeBorder(Color.white.opacity(mark == .developed ? 0.28 : 0), lineWidth: 1) }
            .shadow(color: Color.black.opacity(0.25), radius: 1.5, y: 0.5)
            .help(mark == .developed ? "This frame is developed" : "This frame was not developed")
            .accessibilityHidden(true)
    }
}
