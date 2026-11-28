import AppKit
import ArgentRoll
import SwiftUI
import UniformTypeIdentifiers

struct PresetLibrarySheet: View {
    let model: RollModel
    let frames: [Frame]
    let store: PresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [UserPreset] = []
    @State private var selection: UUID?
    @State private var error: String?
    @State private var issues: [String] = []
    @State private var confirmsDelete = false

    private var selected: UserPreset? { presets.first { $0.id == selection } }
    private var unavailableReason: String? { selected.flatMap(model.presetUnavailableReason) }
    private var canApply: Bool {
        selected != nil && unavailableReason == nil && !model.isScanning && !model.isQuitting
            && !model.isRestoringManual && model.frameMove == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Look Presets").font(.title2)
            List(presets, selection: $selection) { preset in
                HStack {
                    if let rgb = preset.canisterColor, rgb.count == 3 {
                        Circle().fill(Color(red: Double(rgb[0]), green: Double(rgb[1]), blue: Double(rgb[2])))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    }
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
                Button("Export…") { if let selected { exportPreset(selected) } }.disabled(selected == nil)
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
        .padding(24)
        .frame(width: 500)
        .onAppear { reload() }
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

    private func reload(select id: UUID? = nil) {
        do {
            let result = try store.loadAll()
            presets = result.presets
            issues = result.issues
            let wanted = id ?? selection
            selection = presets.first { $0.id == wanted }?.id ?? presets.first?.id
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private var presetType: UTType {
        UTType(filenameExtension: PresetStore.fileExtension, conformingTo: .json) ?? .json
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [presetType]
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

    private func exportPreset(_ preset: UserPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [presetType]
        panel.nameFieldStringValue = preset.name.replacingOccurrences(of: "/", with: "-") + "." + PresetStore.fileExtension
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                try store.exportPreset(id: preset.id, to: url)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
