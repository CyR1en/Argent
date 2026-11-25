import ArgentCore
import ArgentRoll
import Foundation
import SwiftUI

/// The mask models' download: shown from a Sky, Subject or Background tile while its models are not here, it says what they are and under which terms,
/// and downloads them only when the user agrees (`MaskModelPack`). The models are not Argent's and not under its licence: the screen is where their
/// terms are shown, as the licences ask and the owner chose (2026-11-20; Sky's model with them since 2026-11-24).
@MainActor @Observable
final class MaskModelsDownload {
    enum Phase: Equatable {
        case idle
        case running(MaskModelPack.Step)
        case failed(String)
        case done
    }

    private(set) var isShown = false
    private(set) var phase: Phase = .idle
    /// Whether the licence texts are open in place of the summary.
    var showsTexts = false
    let pack: MaskModelPack
    /// Where it installs; a test gives its own.
    @ObservationIgnored var folder: () -> URL = { MaskModelPack.installedFolder }
    /// Awaited before a download creates its staging folder, so the launch sweep never deletes it.
    @ObservationIgnored var beforeStart: @MainActor () async -> Void = {}
    /// Told once the models are in place, so the tiles ask again.
    @ObservationIgnored var onInstalled: () -> Void = {}
    /// Performs the install; tests replace this to drive state without network or disk I/O.
    @ObservationIgnored var installer: @Sendable (MaskModelPack, URL, @escaping @Sendable (MaskModelPack.Step) -> Void) async throws -> Void = { pack, folder, step in
        try await pack.install(into: folder, step: step)
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The newest install's task, kept after Stop until it has returned: a new install waits for it, so two never share the
    /// Models folder (each sweeps the other's staging folder), and Quit waits for it to clean up.
    @ObservationIgnored private var draining: Task<Void, Never>?
    @ObservationIgnored private(set) var generation: UInt64 = 0

    init(pack: MaskModelPack = .current) {
        self.pack = pack
    }

    var isRunning: Bool { if case .running = phase { true } else { false } }

    func show() {
        showsTexts = false
        isShown = true
    }

    /// Closes the screen; a download under way goes on, and an already-seen finished or failed state resets to idle.
    func close() {
        let wasShown = isShown
        isShown = false
        if wasShown, !isRunning { phase = .idle }
    }

    func start() {
        guard !isRunning else { return }
        generation &+= 1
        let run = generation
        phase = .running(.downloading(0))
        let pack = pack, folder = folder(), installer = installer, beforeStart = beforeStart, previous = draining
        // The download holds the object while it runs: it is the app model's, which outlives it.
        let started = Task {
            await previous?.value
            await beforeStart()
            guard !Task.isCancelled, run == generation else { return }
            do {
                try await installer(pack, folder) { step in
                    Task { @MainActor in self.advance(to: step, run: run) }
                }
                finish(.done, run: run)
            } catch is CancellationError {
                finish(.idle, run: run)
            } catch {
                finish(.failed(String(describing: error)), run: run)
            }
        }
        task = started
        draining = started
    }

    func cancel() {
        guard isRunning else { return }
        generation &+= 1
        let running = task
        task = nil
        phase = .idle
        running?.cancel()
    }

    /// Cancels the download on quit, a running one or one already stopped and still cleaning up, and waits at most `limit`
    /// for its staging folder to go; what is left then the next launch sweeps.
    func cancelForQuit(limit: Duration = .seconds(1)) async {
        guard let running = draining else { return }
        cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { await running.value; once.resume() }
            Task { try? await Task.sleep(for: limit); once.resume() }
        }
    }

    /// A step for `run`, kept only when it belongs to the active run, moves forward monotonically, and changes what the screen shows.
    func advance(to step: MaskModelPack.Step, run: UInt64) {
        guard run == generation, case .running(let now) = phase else { return }
        let next: MaskModelPack.Step
        switch step {
        case .downloading(let fraction):
            guard fraction.isFinite else { return }
            next = .downloading(min(max(fraction, 0), 1))
        case .checking, .unpacking, .done:
            next = step
        }
        let nowRank = Self.rank(of: now), nextRank = Self.rank(of: next)
        guard nextRank >= nowRank else { return }
        if nextRank == nowRank {
            guard case .downloading(let old) = now, case .downloading(let new) = next,
                  new > old, new - old >= 0.005 || new >= 1 else { return }
        }
        phase = .running(next)
    }

    private static func rank(of step: MaskModelPack.Step) -> Int {
        switch step {
        case .downloading: 0
        case .checking: 1
        case .unpacking: 2
        case .done: 3
        }
    }

    private func finish(_ next: Phase, run: UInt64) {
        guard run == generation else { return }
        task = nil
        phase = next
        if next == .done { onInstalled() }
    }

    // MARK: Words

    static let title = "Mask models"
    static let intro = """
        Sky, Subject and Background find what they mask with four models made by others. Argent downloads them once, from Argent's releases on GitHub. \
        They are not part of Argent and not under its licence: by downloading them you accept the terms below.
        """

    struct Model: Identifiable {
        var id: String { name }
        var name: String
        var role: String
        var terms: String
    }

    static let models: [Model] = [
        Model(name: "S3OD-sod", role: "Finds the subject.",
              terms: "MIT licence, © 2024 S3OD Team. Built with DINOv3: fine-tuned from Meta's DINOv3, and distributed under the DINOv3 License. Trained partly on images made with FLUX.1 Krea-dev, under its non-commercial licence."),
        Model(name: "EoMT (DINOv3-L, ADE20K)", role: "Checks for a scene with no subject, and for sky reflected in water.",
              terms: "MIT licence, © 2025 Mobile Perception Systems Lab, TU/e. Built with DINOv3, under the DINOv3 License. Trained on ADE20K, whose images are for non-commercial research and education."),
        Model(name: "ViTMatte-S (Composition-1k)", role: "Draws soft edges in low light.",
              terms: "MIT licence, © 2023 Hust Vision Lab. Trained on Adobe's Deep Image Matting dataset: for non-commercial use only, and never to be sold. Ning Xu, Brian Price, Scott Cohen and Thomas Huang. Deep Image Matting. CVPR 2017."),
        Model(name: "Depth Anything 3 Mono-Large", role: "Finds the sky.",
              terms: "Apache License 2.0, © 2025 The Depth Anything 3 Team. Converted by Argent to run on this Mac."),
    ]

    /// The download's condition as a whole: the first three models' terms ask it, and DA3's Apache-2.0 does not.
    static let notCommercial = "Use them for non-commercial purposes only. The full texts are installed beside the models."

    var sizeWords: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: pack.bytes)
    }

    /// The bundled licence texts, in `scripts/models/mask-licences.txt` order (`scripts/build-app.sh` copies both).
    static let texts: [(name: String, text: String)] = {
        guard let resources = Bundle.main.resourceURL else { return [] }
        return MaskModelLicences.texts(in: resources)
    }()
}

/// Resumes a continuation once, whichever of its callers comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}

/// The screen itself, over the workspace as Quick Develop is over the roll.
struct MaskModelsSheet: View {
    @Environment(RollModel.self) private var model
    @State private var chosenText = 0
    /// The sheet has the keys while it is up, so none reaches the contact sheet or frame under it.
    @FocusState private var focused: Bool

    var body: some View {
        let download = model.maskModels
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: MaskModelsDownload.title)
                .font(Graphite.Typeface.panelTitle)
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)
            if download.showsTexts {
                texts
            } else {
                ViewThatFits(in: .vertical) {
                    summary(download)
                    ScrollView { summary(download) }
                        .scrollBounceBehavior(.basedOnSize)
                }
            }
            footer(download)
                .padding(.top, 20)
        }
        .padding(24)
        .frame(maxWidth: 560)
        .graphiteCard(cornerRadius: 18)
        .padding(Graphite.Metric.l)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            download.close()
            return .handled
        }
        .accessibilityAction(.escape) { download.close() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MaskModelsDownload.title)
        .accessibilityAddTraits(.isModal)
    }

    private func summary(_ download: MaskModelsDownload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: MaskModelsDownload.intro)
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(MaskModelsDownload.models) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: item.name)
                            .font(Graphite.Typeface.body.weight(.semibold))
                            .foregroundStyle(Graphite.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: item.role)
                            .font(Graphite.Typeface.small)
                            .foregroundStyle(Graphite.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: item.terms)
                        .font(Graphite.Typeface.small)
                        .foregroundStyle(Graphite.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Text(verbatim: MaskModelsDownload.notCommercial)
                .font(Graphite.Typeface.small.weight(.semibold))
                .foregroundStyle(Graphite.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var texts: some View {
        let all = MaskModelsDownload.texts
        return VStack(alignment: .leading, spacing: 10) {
            if all.isEmpty {
                Text("This build of Argent does not carry the licence texts. They come with the models.")
                    .font(Graphite.Typeface.body)
                    .foregroundStyle(Graphite.secondaryText)
            } else {
                Picker("Licence", selection: $chosenText) {
                    ForEach(all.indices, id: \.self) { index in Text(verbatim: all[index].name).tag(index) }
                }
                .labelsHidden()
                ScrollView {
                    Text(verbatim: all[min(chosenText, all.count - 1)].text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Graphite.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Another licence starts at its top.
                .id(chosenText)
                .frame(minHeight: 120, maxHeight: 320)
            }
        }
        .padding(.top, 10)
    }

    @ViewBuilder private func footer(_ download: MaskModelsDownload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch download.phase {
            case .running(let step):
                switch step {
                case .downloading(let fraction):
                    ProgressView(value: fraction) { Text("Downloading \(download.sizeWords)…").font(Graphite.Typeface.small) }
                case .checking:
                    ProgressView { Text("Checking the download…").font(Graphite.Typeface.small) }
                case .unpacking, .done:
                    ProgressView { Text("Installing…").font(Graphite.Typeface.small) }
                }
            case .failed(let why):
                Text(verbatim: why)
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.text)
                    .fixedSize(horizontal: false, vertical: true)
            case .done:
                Text("The mask models are installed. Sky, Subject and Background are ready.")
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.text)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    licencesButton(download)
                    Spacer(minLength: 10)
                    actionButtons(download)
                }
                VStack(alignment: .trailing, spacing: 8) {
                    HStack {
                        licencesButton(download)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        actionButtons(download)
                    }
                }
            }
        }
    }

    private func licencesButton(_ download: MaskModelsDownload) -> some View {
        Button(download.showsTexts ? "Summary" : "Read the licences") { download.showsTexts.toggle() }
            .buttonStyle(.graphite(.secondary))
            .fixedSize()
    }

    @ViewBuilder private func actionButtons(_ download: MaskModelsDownload) -> some View {
        switch download.phase {
        case .running:
            Button("Close") { download.close() }
                .buttonStyle(.graphite(.secondary))
                .keyboardShortcut(.cancelAction)
                .fixedSize()
                .help("The download goes on")
            Button("Stop Download") { download.cancel() }
                .buttonStyle(.graphite(.secondary))
                .fixedSize()
        case .done:
            Button("Done") { download.close() }
                .buttonStyle(.graphite(.primary))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .background {
                    // Escape also closes the completed screen even when focus is outside the card.
                    Button("Close") { download.close() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .focusable(false)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        case .idle, .failed:
            Button("Cancel") { download.close() }
                .buttonStyle(.graphite(.secondary))
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            Button(download.phase == .idle ? "Agree and Download (\(download.sizeWords))" : "Try Again") { download.start() }
                .buttonStyle(.graphite(.primary))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .help("Download the four models and install them for Argent only")
        }
    }
}
