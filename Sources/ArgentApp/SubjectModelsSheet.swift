import ArgentCore
import ArgentRoll
import Foundation
import SwiftUI

/// The Subject models' download: shown from a Subject or Background tile while the models are not here, it says what they are and under which terms,
/// and downloads them only when the user agrees (`SubjectModelPack`). The models are not Argent's and not under its licence: the screen is where their
/// terms are shown, as the licences ask and the owner chose (2026-11-20).
@MainActor @Observable
final class SubjectModelsDownload {
    enum Phase: Equatable {
        case idle
        case running(SubjectModelPack.Step)
        case failed(String)
        case done
    }

    private(set) var isShown = false
    private(set) var phase: Phase = .idle
    /// Whether the licence texts are open in place of the summary.
    var showsTexts = false
    let pack: SubjectModelPack
    /// Where it installs; a test gives its own.
    @ObservationIgnored var folder: () -> URL = { SubjectModelPack.installedFolder }
    /// Told once the models are in place, so the tiles ask again.
    @ObservationIgnored var onInstalled: () -> Void = {}
    @ObservationIgnored private var task: Task<Void, Never>?

    init(pack: SubjectModelPack = .current) {
        self.pack = pack
    }

    var isRunning: Bool { if case .running = phase { true } else { false } }

    func show() {
        if phase == .done || { if case .failed = phase { true } else { false } }() { phase = .idle }
        showsTexts = false
        isShown = true
    }

    /// Closes the screen; a download under way goes on, and its tile shows nothing new until it is done.
    func close() { isShown = false }

    func start() {
        guard !isRunning else { return }
        phase = .running(.downloading(0))
        let pack = pack, folder = folder()
        // The download holds the object while it runs: it is the app model's, which outlives it.
        task = Task {
            do {
                try await pack.install(into: folder) { step in
                    Task { @MainActor in self.advance(to: step) }
                }
                finish(.done)
            } catch is CancellationError {
                finish(.idle)
            } catch {
                finish(.failed(String(describing: error)))
            }
        }
    }

    func cancel() { task?.cancel() }

    /// A step, kept only when it changes what the screen shows: the download's fraction moves by half a percent at least.
    private func advance(to step: SubjectModelPack.Step) {
        guard case .running(let now) = phase else { return }
        if case .downloading(let old) = now, case .downloading(let new) = step, new - old < 0.005, new < 1 { return }
        phase = .running(step)
    }

    private func finish(_ phase: Phase) {
        task = nil
        self.phase = phase
        if phase == .done { onInstalled() }
    }

    // MARK: Words

    static let title = "Subject models"
    static let intro = """
        Subject and Background find the subject with three models made by others. Argent downloads them once, from Argent's releases on GitHub. \
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
              terms: "MIT licence, © 2024 S3OD Team. Built with DINOv3: fine-tuned from Meta's DINOv3, and distributed under the DINOv3 License."),
        Model(name: "EoMT (DINOv3-L, ADE20K)", role: "Checks for a scene with no subject.",
              terms: "MIT licence, © 2025 Mobile Perception Systems Lab, TU/e. Built with DINOv3, under the DINOv3 License. Trained on ADE20K, whose images are for non-commercial research and education."),
        Model(name: "ViTMatte-S (Composition-1k)", role: "Draws soft edges in low light.",
              terms: "MIT licence, © 2023 Hust Vision Lab. Trained on Adobe's Deep Image Matting dataset: for non-commercial use only, and never to be sold. Ning Xu, Brian Price, Scott Cohen and Thomas Huang. Deep Image Matting. CVPR 2017."),
    ]

    static let notCommercial = "Use them for non-commercial purposes only. The full texts are installed beside the models."

    var sizeWords: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: pack.bytes)
    }

    /// The licence texts the app carries (`Contents/Resources/Model Licences`, copied by `scripts/build-app.sh` from `scripts/models/licences`), in reading order.
    static var texts: [(name: String, text: String)] {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Model Licences", isDirectory: true) else { return [] }
        let order = ["DINOv3-LICENSE.md", "S3OD-LICENSE-MIT.txt", "EoMT-LICENSE-MIT.txt", "ViTMatte-LICENSE-MIT.txt", "ADE20K-terms.txt", "README.md"]
        return order.compactMap { name in
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
        }
    }
}

/// The screen itself, over the workspace as Import's sheet is over the Rolls page.
struct SubjectModelsSheet: View {
    @Environment(RollModel.self) private var model
    @State private var chosenText = 0

    var body: some View {
        let download = model.subjectModels
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: SubjectModelsDownload.title)
                .font(Graphite.Typeface.panelTitle)
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)
            if download.showsTexts {
                texts
            } else {
                summary(download)
            }
            footer(download)
                .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 560)
        .graphiteCard(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SubjectModelsDownload.title)
        .accessibilityAddTraits(.isModal)
    }

    private func summary(_ download: SubjectModelsDownload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: SubjectModelsDownload.intro)
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(SubjectModelsDownload.models) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: item.name).font(Graphite.Typeface.body.weight(.semibold)).foregroundStyle(Graphite.text)
                        Text(verbatim: item.role).font(Graphite.Typeface.small).foregroundStyle(Graphite.secondaryText)
                    }
                    Text(verbatim: item.terms)
                        .font(Graphite.Typeface.small)
                        .foregroundStyle(Graphite.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Text(verbatim: SubjectModelsDownload.notCommercial)
                .font(Graphite.Typeface.small.weight(.semibold))
                .foregroundStyle(Graphite.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var texts: some View {
        let all = SubjectModelsDownload.texts
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
                .frame(height: 320)
            }
        }
        .padding(.top, 10)
    }

    @ViewBuilder private func footer(_ download: SubjectModelsDownload) -> some View {
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
                Text("The Subject models are installed. Subject and Background are ready.")
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.text)
            case .idle:
                EmptyView()
            }
            HStack(spacing: 10) {
                Button(download.showsTexts ? "Summary" : "Read the licences") { download.showsTexts.toggle() }
                    .buttonStyle(.graphite(.secondary))
                Spacer()
                switch download.phase {
                case .running:
                    Button("Close") { download.close() }
                        .buttonStyle(.graphite(.secondary))
                        .help("The download goes on")
                    Button("Stop Download") { download.cancel() }
                        .buttonStyle(.graphite(.secondary))
                case .done:
                    Button("Done") { download.close() }
                        .buttonStyle(.graphite(.primary))
                        .keyboardShortcut(.defaultAction)
                case .idle, .failed:
                    Button("Cancel") { download.close() }
                        .buttonStyle(.graphite(.secondary))
                        .keyboardShortcut(.cancelAction)
                    Button(download.phase == .idle ? "Agree and Download (\(download.sizeWords))" : "Try Again") { download.start() }
                        .buttonStyle(.graphite(.primary))
                        .keyboardShortcut(.defaultAction)
                        .help("Download the three models and install them for Argent only")
                }
            }
        }
    }
}
