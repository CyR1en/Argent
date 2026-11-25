import AppKit
import ArgentRoll
import SwiftUI

/// First-launch welcome and setup flow inside the workspace: welcomes the user, lets them pick a live theme and
/// appearance mode, adjust core workspace/develop/update preferences, and optionally start downloading the smart mask
/// models in the background (with full licence terms shown before download).
struct OnboardingView: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool
    @State private var cardFrame: CGRect?
    @State private var chosenLicence = 0

    nonisolated private static let space = "OnboardingWorkspace"

    var body: some View {
        let onboarding = model.onboarding
        let settings = AppearanceSettings.shared
        ZStack {
            Graphite.workspace
            if settings.showsOpenRollBackdrop, contrast != .increased {
                OpenRollBackdrop(column: cardFrame, heroZone: nil, hero: .ready, reduceMotion: reduceMotion)
                    .accessibilityHidden(true)
            }
            // Empty space around the card moves the window, as on the Rolls page.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            card(onboarding: onboarding, settings: settings)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { cardFrame = $0 }
                .padding(Graphite.Metric.l)
        }
        .coordinateSpace(.named(Self.space))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            if onboarding.step == .maskModels && onboarding.showsMaskModelLicences {
                onboarding.showsMaskModelLicences = false
            } else {
                onboarding.complete()
            }
            return .handled
        }
        .accessibilityAction(.escape) {
            if onboarding.step == .maskModels && onboarding.showsMaskModelLicences {
                onboarding.showsMaskModelLicences = false
            } else {
                onboarding.complete()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Argent")
        .accessibilityAddTraits(.isModal)
    }

    private func card(onboarding: OnboardingController, settings: AppearanceSettings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stepBar(onboarding)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 16)

            SectionDivider()

            ViewThatFits(in: .vertical) {
                stepContent(onboarding: onboarding, settings: settings)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                ScrollView {
                    stepContent(onboarding: onboarding, settings: settings)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .animation(reduceMotion ? nil : Graphite.Motion.surface, value: onboarding.step)

            SectionDivider()

            footer(onboarding)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .frame(maxWidth: 720)
        .graphiteCard(cornerRadius: 18)
    }

    // MARK: - Step bar

    private func stepBar(_ onboarding: OnboardingController) -> some View {
        HStack(spacing: Graphite.Metric.s) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases) { item in
                    StepChip(step: item, current: onboarding.step) {
                        onboarding.goTo(item)
                    }
                }
            }
            Spacer(minLength: Graphite.Metric.s)
            if onboarding.step != .maskModels {
                Button("Skip") { onboarding.complete() }
                    .buttonStyle(.graphite(.quiet, size: .small))
                    .help("Skip setup and go straight to Argent. You can change any setting later in Settings.")
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder private func stepContent(onboarding: OnboardingController, settings: AppearanceSettings) -> some View {
        let slideEdge: Edge = onboarding.navigationDirection >= 0 ? .trailing : .leading
        let removeEdge: Edge = onboarding.navigationDirection >= 0 ? .leading : .trailing
        let transition: AnyTransition = reduceMotion
            ? .identity
            : .asymmetric(
                insertion: .move(edge: slideEdge).combined(with: .opacity),
                removal: .move(edge: removeEdge).combined(with: .opacity)
            )
        Group {
            switch onboarding.step {
            case .welcome:
                welcomeStep
            case .appearance:
                appearanceStep(settings: settings)
            case .preferences:
                preferencesStep(settings: settings)
            case .maskModels:
                maskModelsStep(onboarding: onboarding)
            }
        }
        .id(onboarding.step)
        .transition(transition)
    }

    // MARK: Step 1 — Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            appMark
                .padding(.bottom, 16)

            Text("Welcome to Argent")
                .font(DisplayFace.font(size: 30, face: "Medium"))
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)

            Text("A digital roll. A film finish.")
                .font(Graphite.Typeface.sectionTitle)
                .foregroundStyle(Graphite.secondaryText)
                .padding(.top, 6)

            Text("Native film development for Sony RAW files, built around the roll. Set your look, preferences and optional smart mask models before you begin.")
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
                .padding(.top, 10)

            HStack(alignment: .top, spacing: Graphite.Metric.m) {
                WelcomePillar(
                    symbol: "film.stack",
                    title: "Work by the roll",
                    bodyText: "Import a camera card or open an existing folder of ARW files. Your originals are never modified."
                )
                WelcomePillar(
                    symbol: "square.3.layers.3d",
                    title: "Modelled stocks",
                    bodyText: "14 colour negative and print stocks with automatic roll exposure and lab balance."
                )
                WelcomePillar(
                    symbol: "slider.horizontal.3",
                    title: "Refine and develop",
                    bodyText: "Fine-tune Light, Curves, Lens and smart Masks, then develop to JPEG, HEIC or 16-bit TIFF."
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var appMark: some View {
        if let icon = NSApp?.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .shadow(color: Graphite.shadow.opacity(0.6), radius: 10, y: 4)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "film.stack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Graphite.text)
                .frame(width: 68, height: 68)
                .background(Graphite.ink(SettingsAppearance.tileRestInk), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    // MARK: Step 2 — Appearance

    private func appearanceStep(settings: AppearanceSettings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeading(
                title: "Choose your look",
                subtitle: "Pick a mode and theme. The window updates live, while your photograph surround stays neutral."
            )
            SettingsAppearance(settings: settings, pictures: [], compact: true)
                .padding(.top, 16)
        }
    }

    // MARK: Step 3 — Preferences

    private func preferencesStep(settings: AppearanceSettings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeading(
                title: "Set your preferences",
                subtitle: "Changes save automatically and are always available in Settings."
            )
            OnboardingPreferencesContent(
                settings: settings,
                developMemory: model.developMemory,
                updates: model.updates
            )
            .padding(.top, 16)
        }
    }

    // MARK: Step 4 — Mask models

    private func maskModelsStep(onboarding: OnboardingController) -> some View {
        let download = model.maskModels
        let installState = model.maskModelsInstallState
        return VStack(alignment: .leading, spacing: 0) {
            stepHeading(
                title: "Smart mask models",
                subtitle: "Optional one-time download (\(download.sizeWords)) for Sky, Subject and Background masks. Person masks work with macOS Vision right away."
            )
            .padding(.bottom, 14)

            if onboarding.showsMaskModelLicences {
                licencesViewer
            } else if case .running(let step) = download.phase {
                runningDownloadCard(download: download, step: step)
            } else if installState.isInstalled || download.phase == .done {
                installedCard(state: installState == .bundled ? .bundled : .downloaded, download: download)
            } else if case .unavailable(let why) = installState {
                unavailableCard(reason: why)
            } else {
                downloadOfferContent(download: download)
            }
        }
    }

    private func runningDownloadCard(download: MaskModelsDownload, step: MaskModelPack.Step) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: Graphite.Metric.s) {
                Text(verbatim: MaskModelsSettingsCard.stepTitle(step, sizeWords: download.sizeWords))
                    .font(Graphite.Typeface.sectionTitle)
                    .foregroundStyle(Graphite.text)
                if case .downloading(let fraction) = step {
                    Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(Graphite.Typeface.label.monospacedDigit())
                        .foregroundStyle(Graphite.secondaryText)
                }
                Spacer(minLength: 0)
                Button("Stop Download") { download.cancel() }
                    .buttonStyle(.graphite(.secondary, size: .small))
            }
            switch step {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Graphite.text)
            case .checking, .unpacking, .done:
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Graphite.text)
            }
            Text("Downloading in the background. You can finish setup now and monitor progress anytime in Settings.")
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Graphite.ink(SettingsAppearance.tileRestInk), in: RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous)
                .strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
        }
    }

    private func installedCard(state: MaskModelsInstallState, download: MaskModelsDownload) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Graphite.text)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Graphite.Metric.s) {
                    Text(state == .bundled ? "Mask models included in this build" : "Mask models installed")
                        .font(Graphite.Typeface.sectionTitle)
                        .foregroundStyle(Graphite.text)
                    Pill(text: "Ready")
                }
                Text(state == .bundled
                     ? "Sky, Subject, Person and Background smart masks are ready to use."
                     : "Sky, Subject, Person and Background smart masks are ready (\(download.installedSizeWords) on disk). Manage them anytime in Settings.")
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Graphite.ink(SettingsAppearance.tileRestInk), in: RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous)
                .strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
        }
    }

    private func unavailableCard(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mask models unavailable")
                .font(Graphite.Typeface.sectionTitle)
                .foregroundStyle(Graphite.text)
            Text(verbatim: reason)
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Graphite.ink(SettingsAppearance.tileRestInk), in: RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous)
                .strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
        }
    }

    private func downloadOfferContent(download: MaskModelsDownload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: MaskModelsDownload.intro)
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MaskModelsDownload.models.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { SectionDivider() }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: item.name)
                                .font(Graphite.Typeface.body.weight(.semibold))
                                .foregroundStyle(Graphite.text)
                            Text(verbatim: item.role)
                                .font(Graphite.Typeface.small)
                                .foregroundStyle(Graphite.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(verbatim: item.terms)
                            .font(Graphite.Typeface.caption)
                            .foregroundStyle(Graphite.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
            .background(Graphite.ink(SettingsAppearance.tileRestInk), in: RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous)
                    .strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
            }

            Text(verbatim: MaskModelsDownload.notCommercial)
                .font(Graphite.Typeface.small.weight(.semibold))
                .foregroundStyle(Graphite.text)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let why) = download.phase {
                Text(verbatim: why)
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("Downloads in the background while you use Argent. Monitor or manage models anytime in Settings › Mask models.",
                  systemImage: "arrow.down.circle")
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var licencesViewer: some View {
        let all = MaskModelsDownload.texts
        return VStack(alignment: .leading, spacing: 10) {
            if all.isEmpty {
                Text("This build of Argent does not carry the licence texts. They come with the models.")
                    .font(Graphite.Typeface.body)
                    .foregroundStyle(Graphite.secondaryText)
            } else {
                Picker("Licence", selection: $chosenLicence) {
                    ForEach(all.indices, id: \.self) { index in
                        Text(verbatim: all[index].name).tag(index)
                    }
                }
                .labelsHidden()
                ScrollView {
                    Text(verbatim: all[min(chosenLicence, all.count - 1)].text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Graphite.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(chosenLicence)
                .frame(minHeight: 140, maxHeight: 290)
                .padding(12)
                .background(Graphite.ink(SettingsAppearance.tileRestInk), in: RoundedRectangle(cornerRadius: Graphite.Metric.s, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Graphite.Metric.s, style: .continuous)
                        .strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
                }
            }
        }
    }

    // MARK: - Footer

    private func footer(_ onboarding: OnboardingController) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                footerLeading(onboarding)
                Spacer(minLength: 10)
                footerTrailing(onboarding)
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    footerLeading(onboarding)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    footerTrailing(onboarding)
                }
            }
        }
    }

    @ViewBuilder private func footerLeading(_ onboarding: OnboardingController) -> some View {
        switch onboarding.step {
        case .welcome:
            Text("You can revisit this anytime from Help › Welcome to Argent.")
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.tertiaryText)
                .lineLimit(1)
        case .appearance, .preferences:
            Button("Back") { onboarding.goBack() }
                .buttonStyle(.graphite(.secondary))
                .fixedSize()
        case .maskModels:
            HStack(spacing: 10) {
                Button("Back") { onboarding.goBack() }
                    .buttonStyle(.graphite(.secondary))
                    .fixedSize()
                Button(onboarding.showsMaskModelLicences ? "Summary" : "Read the licences") {
                    onboarding.showsMaskModelLicences.toggle()
                }
                .buttonStyle(.graphite(.secondary))
                .fixedSize()
            }
        }
    }

    @ViewBuilder private func footerTrailing(_ onboarding: OnboardingController) -> some View {
        switch onboarding.step {
        case .welcome:
            Button("Get Started") { onboarding.advance() }
                .buttonStyle(.graphite(.primary))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
        case .appearance, .preferences:
            Button("Continue") { onboarding.advance() }
                .buttonStyle(.graphite(.primary))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
        case .maskModels:
            maskModelsFooterActions(onboarding)
        }
    }

    @ViewBuilder private func maskModelsFooterActions(_ onboarding: OnboardingController) -> some View {
        let download = model.maskModels
        let installState = model.maskModelsInstallState
        if download.isRunning {
            Button("Continue in Background") { onboarding.complete() }
                .buttonStyle(.graphite(.primary))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
        } else if installState.isInstalled || download.phase == .done || installState != .notInstalled {
            Button("Start Using Argent") { onboarding.complete() }
                .buttonStyle(.graphite(.primary))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
        } else {
            HStack(spacing: 10) {
                Button("Not now") { onboarding.complete() }
                    .buttonStyle(.graphite(.secondary))
                    .fixedSize()
                    .help("Finish setup without downloading. You can download mask models anytime in Settings.")
                Button(download.phase == .idle
                       ? "Agree and Download (\(download.sizeWords))"
                       : "Try Again") {
                    model.downloadMaskModelsAndFinishOnboarding()
                }
                .buttonStyle(.graphite(.primary))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .help("Agree to the model licences, start downloading in the background, and open Argent")
            }
        }
    }

    private func stepHeading(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(Graphite.Typeface.panelTitle)
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: subtitle)
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Supporting Views

private struct StepChip: View {
    let step: OnboardingStep
    let current: OnboardingStep
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var isActive: Bool { step == current }
    private var isDone: Bool { step.rawValue < current.rawValue }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.segmentRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    if isActive {
                        Circle()
                            .fill(Graphite.primaryBottom)
                            .frame(width: 18, height: 18)
                    } else {
                        Circle()
                            .strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
                            .frame(width: 18, height: 18)
                    }
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Graphite.secondaryText)
                    } else {
                        Text(verbatim: "\(step.rawValue + 1)")
                            .font(Graphite.Typeface.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(isActive ? Graphite.onPrimary : Graphite.secondaryText)
                    }
                }
                .accessibilityHidden(true)

                Text(verbatim: step.title)
                    .font(isActive ? Graphite.Typeface.chipTitle : Graphite.Typeface.small)
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Graphite.text : isHovered ? Graphite.text : Graphite.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                shape.fill(Graphite.ink(isActive ? SettingsAppearance.tileRestInk : isHovered ? SettingsAppearance.tileHoverInk : 0))
            }
            .overlay {
                if isActive {
                    shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Step \(step.rawValue + 1): \(step.title)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct WelcomePillar: View {
    let symbol: String
    let title: String
    let bodyText: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Graphite.text)
                .frame(width: 34, height: 34)
                .background(Graphite.ink(Pill.fillInk), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            Text(verbatim: title)
                .font(Graphite.Typeface.chipTitle)
                .foregroundStyle(Graphite.text)

            Text(verbatim: bodyText)
                .font(Graphite.Typeface.small)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Graphite.ink(SettingsAppearance.tileRestInk)))
        .overlay {
            shape.strokeBorder(contrast == .increased ? Graphite.strongBorder : Graphite.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingPreferencesContent: View {
    @Bindable var settings: AppearanceSettings
    let developMemory: DevelopMemorySettings
    let updates: UpdateController
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let allowsAmbient = contrast != .increased
        let ambientActive = settings.showsAmbientSurround && allowsAmbient
        let allowsBackdrop = contrast != .increased
        let showsSurround = Binding(get: { settings.showsAmbientSurround }, set: { settings.setShowsAmbientSurround($0) })
        let memoryChoice = Binding(get: { developMemory.choice }, set: { developMemory.setChoice($0) })
        let defaultAmount = DevelopMemoryCard.amount(developMemory.defaultTarget)
        let channel = Binding(get: { updates.channel }, set: { updates.setChannel($0) })
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.m, style: .continuous)
        let border = contrast == .increased ? Graphite.strongBorder : Graphite.border

        VStack(alignment: .leading, spacing: Graphite.Metric.m) {
            // Frame view live preview + Ambient Surround
            SplitCardLayout(leadingFraction: 0.30) {
                FrameSurroundSpecimen(
                    picture: nil,
                    palette: settings.palette,
                    ambient: ambientActive,
                    intensity: settings.ambientSurroundIntensity,
                    showsShadow: ambientActive && settings.showsAmbientSurroundShadow
                )
                .overlay(alignment: .trailing) { Graphite.hairline.frame(width: 1) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Frame surround",
                        note: contrast == .increased
                            ? "Increase Contrast keeps the surround neutral"
                            : settings.showsAmbientSurround ? "Diffuses colors from the open frame" : "Flat neutral gray in every theme"
                    ) {
                        GraphiteSegmented(
                            selection: showsSurround,
                            segments: [
                                .init(value: true, title: "Ambient"),
                                .init(value: false, title: "Neutral"),
                            ],
                            size: .regular,
                            fillsWidth: true
                        )
                        .frame(width: 176)
                        .disabled(!allowsAmbient)
                        .accessibilityLabel("Frame surround")
                    }
                    SectionDivider()
                    SettingsRow(title: "Edge shadow", note: "A soft grounding shadow under the frame") {
                        InspectorSwitch(
                            title: "Ambient edge shadow",
                            isOn: settings.showsAmbientSurroundShadow,
                            help: "Adds a soft grounding shadow outside the photograph's crisp edge while Ambient is on"
                        ) {
                            settings.setShowsAmbientSurroundShadow(!settings.showsAmbientSurroundShadow)
                        }
                        .disabled(!ambientActive)
                    }
                }
            }
            .background(shape.fill(Graphite.ink(SettingsAppearance.tileRestInk)))
            .clipShape(shape)
            .overlay { shape.strokeBorder(border, lineWidth: 1) }

            // Workspace, Develop & Updates
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Window shell transparency",
                    note: reduceTransparency
                        ? "Reduce Transparency is on, so the shell is opaque"
                        : "How much desktop frost shows around the workspace",
                    labelWidth: 270
                ) {
                    SettingsPercentField(
                        title: "Window shell transparency",
                        value: $settings.shellTransparency,
                        range: AppearanceSettings.transparencyRange
                    )
                    .disabled(reduceTransparency)
                }
                SectionDivider()
                SettingsRow(
                    title: "Rolls backdrop",
                    note: allowsBackdrop
                        ? "Film grain drifts gently behind the Rolls page"
                        : "Increase Contrast hides the backdrop"
                ) {
                    InspectorSwitch(
                        title: "Rolls backdrop",
                        isOn: settings.showsOpenRollBackdrop,
                        help: "Shows drifting grain behind the Rolls page"
                    ) {
                        settings.setShowsOpenRollBackdrop(!settings.showsOpenRollBackdrop)
                    }
                    .disabled(!allowsBackdrop)
                }
                SectionDivider()
                SettingsRow(
                    title: "Memory while developing",
                    note: developMemory.hasExtraChoices
                        ? DevelopMemoryCard.enabledNote(default: defaultAmount)
                        : DevelopMemoryCard.disabledNote
                ) {
                    GraphiteSegmented(
                        selection: memoryChoice,
                        segments: developMemory.offeredChoices.map { choice in
                            .init(value: choice, title: choice == .default ? defaultAmount : choice.title)
                        },
                        size: .regular,
                        fillsWidth: true
                    )
                    .frame(width: max(84, CGFloat(developMemory.offeredChoices.count) * 68))
                    .disabled(!developMemory.hasExtraChoices)
                    .accessibilityLabel("Memory while developing")
                }
                SectionDivider()
                SettingsRow(title: "Update channel", note: updates.channelNote) {
                    GraphiteSegmented(
                        selection: channel,
                        segments: UpdateChannel.allCases.map { item in
                            .init(value: item, title: item.title, help: item.note)
                        },
                        size: .regular,
                        fillsWidth: true
                    )
                    .frame(width: 176)
                    .accessibilityLabel("Update channel")
                }
            }
            .background(shape.fill(Graphite.ink(SettingsAppearance.tileRestInk)))
            .clipShape(shape)
            .overlay { shape.strokeBorder(border, lineWidth: 1) }
        }
    }
}
