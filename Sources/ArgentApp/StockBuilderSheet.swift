import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI

struct StockBuilderSheet: View {
    let model: RollModel
    let store: UserStockStore
    let presentation: StockBuilderPresentation

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var spec: CustomStockSpec
    @State private var before: CGImage?
    @State private var after: CGImage?
    @State private var previewMessage: String?
    @State private var saveError: String?
    @State private var saving = false
    @State private var split = 0.5
    @State private var zoom = 1.0
    @State private var channel = ToneCurves.Channel.tone
    @State private var point = 0

    init(model: RollModel, store: UserStockStore, presentation: StockBuilderPresentation) {
        self.model = model
        self.store = store
        self.presentation = presentation
        _name = State(initialValue: presentation.name)
        _spec = State(initialValue: presentation.spec)
    }

    private var stocks: [Stock] { model.films?.stocks ?? [] }
    private var base: Stock? {
        guard case .derived(let id) = spec.base else { return nil }
        return stocks.first { $0.id == id }
    }
    private var missingBase: Bool {
        if case .derived = spec.base { return base == nil }
        return false
    }
    private var isMonochrome: Bool { spec.base == .monochrome || base?.monochrome != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(presentation.stockID == nil ? "Custom Stock Builder" : "Edit Custom Stock").font(.title2)
            HStack(alignment: .top, spacing: 20) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Form {
                    foundation
                    tone
                    color
                    physical
                    identity
                }
                .formStyle(.grouped)
                .frame(width: 335)
            }
            .disabled(saving)
            if let saveError { Text(saveError).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Reset") {
                    name = presentation.name
                    spec = presentation.spec
                    point = 0
                }
                .disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(presentation.stockID == nil ? "Save Stock" : "Save Changes", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || trimmedName.isEmpty || missingBase)
            }
        }
        .padding(22)
        .frame(width: 872, height: 660)
        .interactiveDismissDisabled(saving)
        .task(id: model.output.space) { await renderBefore() }
        .task(id: PreviewKey(spec: spec, space: model.output.space)) { await renderAfter(spec, in: model.output.space) }
    }

    private struct PreviewKey: Equatable {
        let spec: CustomStockSpec
        let space: OutputSpace
    }

    private var preview: some View {
        VStack {
            GeometryReader { geometry in
                let width = geometry.size.width * zoom
                let height = geometry.size.height * zoom
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        if let after {
                            canvas(after).accessibilityLabel("After")
                            if let before {
                                canvas(before)
                                    .mask(alignment: .leading) { Rectangle().frame(width: width * split) }
                                    .accessibilityLabel("Before")
                                Rectangle().fill(.white).frame(width: 1, height: height)
                                    .position(x: width * split, y: height / 2)
                                    .accessibilityHidden(true)
                            }
                        } else if let previewMessage {
                            Text(previewMessage).foregroundStyle(.secondary).padding()
                        } else if presentation.frame == nil {
                            Text("Open or select a frame to see a live preview.").foregroundStyle(.secondary).padding()
                        } else {
                            ProgressView("Preparing preview")
                        }
                    }
                    .frame(width: width, height: height)
                }
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("Before")
                Slider(value: $split, in: 0...1) { Text("Compare divider") }.labelsHidden()
                Text("After")
            }
            .disabled(before == nil || after == nil)
            Slider(value: $zoom, in: 1...3) { Text("Zoom") }
                .disabled(after == nil)
            if let previewMessage, after != nil { Text(previewMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func canvas(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var foundation: some View {
        Section("Foundation") {
            Picker("Base", selection: Binding(get: { spec.base }, set: changeBase)) {
                Text("Neutral").tag(CustomStockSpec.Base.neutral)
                Text("Monochrome").tag(CustomStockSpec.Base.monochrome)
                ForEach(stocks.filter { $0.id != presentation.stockID && (!$0.isUserStock || $0.id == base?.id) }, id: \.id) { stock in
                    Text(stock.displayName).tag(CustomStockSpec.Base.derived(stockID: stock.id))
                }
                if case .derived(let id) = spec.base, missingBase { Text("Missing: \(id)").tag(spec.base) }
            }
            .disabled(spec.frameLook != nil)
            if spec.frameLook != nil {
                Text("Baked from the frame’s global look. Masks, lens corrections and local Auto tone aren’t included. Highlights and Shadows use a per-pixel approximation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Box Speed (ISO 50–3200)", value: $spec.boxSpeed, format: .number.grouping(.never))
        }
    }

    private func changeBase(_ choice: CustomStockSpec.Base) {
        guard choice != spec.base else { return }
        spec.base = choice
        let foundation = base.map(CustomStockSpec.init(derivedFrom:)) ?? .init(base: choice)
        spec.boxSpeed = foundation.boxSpeed
        spec.grain = foundation.grain
        spec.halation = foundation.halation
        spec.monochromeMixer = nil
        spec.paperTone = nil
    }

    private var tone: some View {
        Section("Tone") {
            slider("Contrast", $spec.contrast, 0.25...4)
            slider("Shadow Toe", $spec.shadowToe, 0...1)
            slider("Highlight Shoulder", $spec.highlightShoulder, 0...1)
            DisclosureGroup("Tone Curves") {
                Picker("Channel", selection: $channel) {
                    ForEach(ToneCurves.Channel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                let curves = spec.toneCurve ?? .identity
                CurveGraph(curve: Binding(get: { (spec.toneCurve ?? .identity).curve(for: channel) },
                                         set: { spec.toneCurve = try? (spec.toneCurve ?? .identity).setting(channel, to: $0) }),
                           selectedPoint: $point, channel: $channel, version: curves.version,
                           pointMode: true, histogram: [], onEditingChanged: { _ in })
                    .frame(height: 200)
                Button("Clear Curves") { spec.toneCurve = nil; point = 0 }
            }
        }
    }

    private var color: some View {
        Section("Color") {
            slider("Warmth", $spec.warmth, -1...1)
            slider("Tint", $spec.tint, -1...1)
            slider("Saturation", $spec.saturation, 0...2)
            slider("Vibrance", $spec.vibrance, -1...1)
            DisclosureGroup("Split Tone") {
                tint("Shadows", $spec.splitTone.shadows)
                tint("Midtones", $spec.splitTone.midtones)
                tint("Highlights", $spec.splitTone.highlights)
            }
            DisclosureGroup("Six-Hue Color") {
                ForEach(CustomStockSpec.Hue.allCases, id: \.self) { hue in
                    let shift = Binding(get: { spec.colorShift[hue] ?? .init() }, set: { spec.colorShift[hue] = $0 })
                    slider("\(hue.rawValue.capitalized) Hue", shift.hue, -60...60)
                    slider("\(hue.rawValue.capitalized) Saturation", shift.saturation, -1...1)
                }
            }
            if isMonochrome {
                DisclosureGroup("Monochrome Mixer & Paper") {
                    ForEach(0..<3) { i in
                        let label = ["Red", "Green", "Blue"][i]
                        slider("\(label) Mix", component($spec.monochromeMixer, i, default: SIMD3(0.2627, 0.6780, 0.0593)), 0...1)
                        slider("\(label) Paper", component($spec.paperTone, i, default: SIMD3(repeating: 1)), 0...2)
                    }
                }
            }
        }
    }

    private var physical: some View {
        Section("Grain & Halation") {
            Picker("Grain", selection: $spec.grain.preset) {
                ForEach(CustomStockSpec.Grain.Preset.allCases.filter { $0 != .inherited || base?.grain != nil }, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }
            if spec.grain.preset != .none {
                slider("Strength", $spec.grain.strength, 0...2)
                slider("Shadow Bias", $spec.grain.shadowBias, -1...1)
            }
            Toggle("Halation", isOn: $spec.halation.enabled)
            if spec.halation.enabled {
                slider("Strength", $spec.halation.strength, 0...0.08)
                slider("Green Share", $spec.halation.greenShare, 0...1)
                slider("Radius (µm)", $spec.halation.radiusMicrometres, 60...350)
            }
        }
    }

    private var identity: some View {
        Section("Identity") {
            TextField("Name", text: $name)
            TextField("Description", text: $spec.characterLine)
            ColorPicker("Canister Color", selection: Binding(get: {
                let c = spec.canisterColor
                guard c.count == 3 else { return .accentColor }
                return Color(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
            }, set: {
                if let c = NSColor($0).usingColorSpace(.sRGB) {
                    spec.canisterColor = [c.redComponent, c.greenComponent, c.blueComponent].map { Float(min(max($0, 0), 1)) }
                }
            }), supportsOpacity: false)
        }
    }

    private func tint(_ label: String, _ value: Binding<CustomStockSpec.Tint>) -> some View {
        Group {
            slider("\(label) Hue", value.hue, 0...360)
            slider("\(label) Strength", value.strength, 0...1)
        }
    }

    private func slider(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        Slider(value: value, in: range) { Text(label) }
    }

    private func component(_ color: Binding<SIMD3<Float>?>, _ index: Int, default fallback: SIMD3<Float>) -> Binding<Float> {
        Binding(get: { (color.wrappedValue ?? fallback)[index] }, set: { value in
            var changed = color.wrappedValue ?? fallback
            changed[index] = value
            color.wrappedValue = changed
        })
    }

    private func renderBefore() async {
        guard let frame = presentation.frame, let films = model.films else { return }
        let index = model.stockIndex(for: frame)
        before = await films.film(frame, stock: index, settings: model.settings(for: frame, stock: index),
                                  space: model.output.space, maxPixelSize: 800, priority: .high)
    }

    private func renderAfter(_ recipe: CustomStockSpec, in space: OutputSpace) async {
        guard let frame = presentation.frame, let films = model.films else { return }
        let base = self.base
        do {
            try await Task.sleep(for: .milliseconds(75))
            let compile = Task.detached(priority: .userInitiated) {
                try CustomStockCompiler.compile(recipe, id: "user-builder-preview", name: "Stock Builder Preview",
                                                base: base, size: CustomStockCompiler.previewSize)
            }
            let stock = try await withTaskCancellationHandler { try await compile.value } onCancel: { compile.cancel() }
            try Task.checkCancellation()
            let geometry = ManualAdjustments.identity.settingLens(model.lensSettings(for: frame))
            let settings = DevelopSettings(grain: stock.grain == nil ? 0 : 1, grainSeed: frame.grainSeed,
                                          halation: stock.halation != nil, sharpen: true,
                                          manual: try .init(adjustments: geometry.withoutRemovals, referenceStops: 0))
            let image = try await films.uninstalledStockPreview(frame, stock: stock, settings: settings, space: space)
            try Task.checkCancellation()
            after = image
            previewMessage = image == nil ? "Could not render this frame." : nil
        } catch {
            guard !Task.isCancelled else { return }
            previewMessage = "Preview unavailable: \(error)"
        }
    }

    private func save() {
        guard !saving else { return }
        let name = trimmedName
        let recipe = spec
        let base = self.base
        let store = self.store
        let existing = presentation.stockID
        let reserved = Set(stocks.map(\.id))
        saving = true
        saveError = nil
        Task {
            defer { saving = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let label = String(name.prefix(100)) + "-" + UUID().uuidString.prefix(8)
                    let id = existing ?? UserStockStore.makeID(from: label, existingIDs: reserved)
                    let stock = try CustomStockCompiler.compile(recipe, id: id, name: name, base: base)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                    let data = try encoder.encode(recipe)
                    if existing != nil { try store.save(stock, specData: data) }
                    else { try store.install(stock, specData: data) }
                }.value
                model.reloadUserStocks()
                model.message = "Saved \(name)"
                dismiss()
            } catch {
                saveError = "Could not save the stock: \(error)"
            }
        }
    }
}
