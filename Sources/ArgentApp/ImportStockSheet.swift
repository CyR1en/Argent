import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI

struct ImportStockSheet: View {
    let model: RollModel
    let source: StockImportSource
    let store: UserStockStore
    let frame: Frame?

    @Environment(\.dismiss) private var dismiss
    @State private var cube: LUT3D?
    @State private var name: String
    @State private var inputSpace = CubeImporter.InputSpace.displaySRGB
    @State private var grain = CubeImporter.Grain.none
    @State private var halation = HalationChoice.none
    @State private var strength: Float = 0.035
    @State private var greenShare: Float = 0.25
    @State private var radius: Float = 150
    @State private var boxSpeed = 400
    @State private var color = Color(red: 0.29, green: 0.49, blue: 0.55)
    @State private var isWorking = false
    @State private var error: String?
    @State private var previewError: String?
    @State private var preview: CGImage?

    init(model: RollModel, source: StockImportSource, store: UserStockStore, frame: Frame?) {
        self.model = model
        self.source = source
        self.store = store
        self.frame = frame
        _name = State(initialValue: source.url.deletingPathExtension().lastPathComponent)
    }

    private enum HalationChoice: String, CaseIterable {
        case none, subtle, strong, custom
    }

    private struct PreviewRequest: Equatable {
        let cubeLoaded: Bool
        let options: CubeImporter.Options
        let space: OutputSpace
    }

    private var options: CubeImporter.Options {
        let profile: CubeImporter.Halation = switch halation {
        case .none: .none
        case .subtle: .subtle
        case .strong: .strong
        case .custom: .custom(.init(strength: strength, greenShare: greenShare, radiusMicrometres: radius))
        }
        return .init(inputSpace: inputSpace, grain: grain, halation: profile, boxSpeed: Float(boxSpeed))
    }

    private var previewRequest: PreviewRequest {
        .init(cubeLoaded: cube != nil, options: options, space: model.output.space)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(source.isCube ? "Import LUT as Stock" : "Import Custom Stock").font(.title2)
            Text(verbatim: source.url.lastPathComponent).foregroundStyle(.secondary)
            if source.isCube {
                HStack(alignment: .top, spacing: 16) {
                    previewPane
                    controls
                }
                .disabled(isWorking)
            } else {
                Text("Install this stock so it’s available in the stock shelf. Existing stocks won’t be replaced.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = model.presetDocumentImportError {
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Import Stock", action: install).keyboardShortcut(.defaultAction)
                    .disabled(isWorking || (source.isCube && (cube == nil || trimmedName.isEmpty || !(50...3200).contains(boxSpeed))))
            }
        }
        .padding(24)
        .frame(width: source.isCube ? 730 : 480)
        .interactiveDismissDisabled(isWorking)
        .task { if source.isCube { await loadCube() } }
        .task(id: previewRequest) { await updatePreview(previewRequest) }
    }

    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable().scaledToFit()
                    .accessibilityLabel("Imported stock preview")
            } else if let previewError {
                Text(previewError).foregroundStyle(.secondary).padding()
            } else if frame == nil {
                Text("Open or select a frame to see a preview.").foregroundStyle(.secondary).padding()
            } else if cube == nil && error != nil {
                Text("Preview unavailable").foregroundStyle(.secondary)
            } else {
                ProgressView("Preparing preview")
            }
        }
        .frame(width: 330, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        Form {
            TextField("Name", text: $name)
            ColorPicker("Canister Color", selection: $color, supportsOpacity: false)
            Picker("Input Space", selection: $inputSpace) {
                Text("Display sRGB / Rec. 709").tag(CubeImporter.InputSpace.displaySRGB)
                Text("Sony S-Log3 / S-Gamut3.Cine").tag(CubeImporter.InputSpace.sonySLog3)
                Text("Argent Raw Print").tag(CubeImporter.InputSpace.rawPrint)
            }
            Picker("Grain", selection: $grain) {
                ForEach(CubeImporter.Grain.allCases, id: \.self) { preset in
                    Text(preset == .highSpeed ? "High-Speed" : preset.rawValue.capitalized).tag(preset)
                }
            }
            Picker("Halation", selection: $halation) {
                ForEach(HalationChoice.allCases, id: \.self) { choice in
                    Text(choice.rawValue.capitalized).tag(choice)
                }
            }
            if halation == .custom {
                Slider(value: $strength, in: 0...0.08) { Text("Strength") }
                Slider(value: $greenShare, in: 0...1) { Text("Green Share") }
                Slider(value: $radius, in: 60...350) { Text("Radius (µm)") }
            }
            TextField("Box Speed (ISO 50–3200)", value: $boxSpeed, format: .number.grouping(.never))
        }
        .frame(maxWidth: .infinity)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func loadCube() async {
        let url = source.url
        do {
            let parsed = try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128 << 20 else {
                    throw UserStockStore.ArchiveError.tooLarge
                }
                return try LUT3D.parseCube(String(contentsOf: url, encoding: .utf8))
            }.value
            guard !Task.isCancelled else { return }
            cube = parsed
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Could not read the LUT: \(error)"
        }
    }

    private func updatePreview(_ request: PreviewRequest) async {
        guard let frame, let cube else { return }
        guard let films = model.films else {
            previewError = "The film renderer is unavailable."
            return
        }
        previewError = nil
        do {
            try await Task.sleep(for: .milliseconds(120))
            let stock = try await Task.detached(priority: .userInitiated) {
                try CubeImporter.bake(cube, id: "user-import-preview", name: "LUT Preview", options: request.options)
            }.value
            try Task.checkCancellation()
            let image = try await films.importPreview(frame, stock: stock, space: request.space)
            guard !Task.isCancelled else { return }
            preview = image
            if image == nil { previewError = "Could not render this frame." }
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
            previewError = "Could not render this frame: \(error)"
        }
    }

    private func install() {
        guard !isWorking, !source.isCube || (cube != nil && !trimmedName.isEmpty && (50...3200).contains(boxSpeed)) else { return }
        let store = self.store
        let url = source.url
        let cube = self.cube
        let isCube = source.isCube
        let name = trimmedName
        var options = self.options
        if let rgb = NSColor(color).usingColorSpace(.sRGB) {
            func component(_ value: CGFloat) -> Float { Float(min(max(value, 0), 1)) }
            options.canisterColor = .init(red: component(rgb.redComponent), green: component(rgb.greenComponent),
                                          blue: component(rgb.blueComponent))
        }
        let importOptions = options
        let reservedIDs = Set(model.films?.stocks.map(\.id) ?? [])
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let stock = try await Task.detached(priority: .userInitiated) {
                    if isCube, let cube {
                        let label = String(name.prefix(100)) + "-" + UUID().uuidString.prefix(8)
                        let id = UserStockStore.makeID(from: label, existingIDs: reservedIDs)
                        let stock = try CubeImporter.bake(cube, id: id, name: name, options: importOptions)
                        try store.install(stock)
                        return stock
                    }
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    return try store.importStock(from: url, excluding: reservedIDs)
                }.value
                model.reloadUserStocks()
                model.message = ["Imported \(stock.displayName)", model.presetDocumentImportError]
                    .compactMap { $0 }.joined(separator: "\n")
                dismiss()
            } catch {
                self.error = "Could not import the stock: \(error)"
            }
        }
    }
}
