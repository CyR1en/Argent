import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI
import UniformTypeIdentifiers

struct PresetLibrarySheet: View {
    let model: RollModel
    let frames: [Frame]
    let store: PresetStore
    let managing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [UserPreset] = []
    @State private var selection: UUID?
    @State private var error: String?
    @State private var issues: [String] = []
    @State private var confirmsDelete = false
    @State private var showsStocks: Bool
    @State private var stockSelection: String?
    @State private var confirmsStockDelete = false

    init(model: RollModel, frames: [Frame], store: PresetStore, selection: UUID?, managing: Bool) {
        self.model = model
        self.frames = frames
        self.store = store
        self.managing = managing
        _selection = State(initialValue: selection)
        _showsStocks = State(initialValue: managing)
    }

    private var selected: UserPreset? { presets.first { $0.id == selection } }
    private var unavailableReason: String? { selected.flatMap(model.presetUnavailableReason) }
    private var canApply: Bool {
        selected != nil && unavailableReason == nil && model.canApplyLookPreset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(managing ? "Custom Stocks & Presets" : "Look Presets").font(.title2)
            if managing {
                Picker("Library", selection: $showsStocks) {
                    Text("Custom Stocks").tag(true)
                    Text("Presets").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if showsStocks { stockLibrary } else { presetLibrary }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { reload() }
    }

    private var presetLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(presets, selection: $selection) { preset in
                HStack {
                    FilmCanister(stockID: nil, canisterColor: preset.tagTint)
                    Text(preset.name)
                }
                .tag(preset.id)
            }
            .frame(minHeight: 180)
            .overlay {
                if presets.isEmpty { Text("No look presets").foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            if let unavailableReason { Text(unavailableReason).foregroundStyle(.secondary) }
            if !issues.isEmpty {
                DisclosureGroup("Could not read \(issues.count) preset files") {
                    Text(issues.joined(separator: "\n")).textSelection(.enabled)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Import…") { importPreset() }
                Button("Export…") {
                    guard let selected else { return }
                    error = nil
                    model.choosePresetExport(selected) { error = $0.localizedDescription }
                }
                .disabled(selected == nil)
                Button("Delete…") { confirmsDelete = true }.disabled(selected == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Spacer()
                Button("Apply to Entire Roll") {
                    if let selected, model.applyPresetToRoll(selected) != nil { dismiss() }
                }
                .disabled(!canApply || model.roll?.frames.isEmpty != false)
                Button(frames.count > 1 ? "Apply to Selected Frames" : "Apply to Frame") {
                    if let selected, model.applyPreset(selected, to: frames, batch: frames.count > 1) != nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || frames.isEmpty)
            }
        }
        .confirmationDialog("Delete this preset?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Preset", role: .destructive) {
                guard let selected else { return }
                do {
                    try store.delete(id: selected.id)
                    reload()
                } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Frames already developed with this preset keep their adjustments.")
        }
    }

    private var stockLibrary: some View {
        let stocks = model.installedStocks.filter(\.isUserStock)
        let stock = stocks.first { $0.id == stockSelection }
        return VStack(alignment: .leading, spacing: 12) {
            List(stocks, id: \.id, selection: $stockSelection) { stock in
                HStack {
                    FilmCanister(stockID: stock.id, canisterColor: stock.canisterColor)
                    Text(stock.displayName)
                }
                .tag(stock.id)
            }
            .frame(minHeight: 180)
            .overlay {
                if stocks.isEmpty { Text("No custom stocks").foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Edit…") {
                    guard let stock else { return }
                    do { model.presetPresentation = .builder(try model.stockRecipe(for: stock)) }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(stock?.hasSpec != true)
                Button("Export…") { if let stock { model.chooseStockExport(stock) } }.disabled(stock == nil)
                Button("Delete…") { confirmsStockDelete = true }.disabled(stock == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .confirmationDialog("Delete this custom stock?", isPresented: $confirmsStockDelete, titleVisibility: .visible,
                            presenting: stock) { stock in
            Button("Delete \(stock.displayName)", role: .destructive) { model.deleteCustomStock(stock) }
        } message: { _ in
            Text("Rolls and presets that use this stock will need it reinstalled or a different stock selected.")
        }
    }

    private func reload(select id: UUID? = nil) {
        do {
            let result = try store.loadAll()
            presets = result.presets
            model.lookPresets = presets
            issues = result.issues
            let wanted = id ?? selection
            selection = presets.first { $0.id == wanted }?.id ?? presets.first?.id
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.argentPreset]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let imported = try store.importPreset(from: url)
                reload(select: imported.id)
            } catch { self.error = error.localizedDescription }
        }
    }
}
