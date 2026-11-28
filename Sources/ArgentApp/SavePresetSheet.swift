import AppKit
import ArgentRoll
import SwiftUI

struct SavePresetSheet: View {
    let model: RollModel
    let frame: Frame
    let store: PresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parts = PresetParts.all
    @State private var hasColor = false
    @State private var color = Color.accentColor
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Look as Preset").font(.title2)
            TextField("Name", text: $name)
            HStack {
                Toggle("Tag color", isOn: $hasColor)
                if hasColor { ColorPicker("Tag color", selection: $color, supportsOpacity: false).labelsHidden() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Include").font(.headline)
                part("Base Stock", .stock)
                part("Film Settings", .filmControls)
                part("Light", .light)
                part("Presence", .presence)
                part("Curves", .curves)
            }
            Text("Masks, removals and lens corrections are not saved.").foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || parts.isEmpty || !model.canSavePreset(from: frame))
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func part(_ title: String, _ part: PresetParts) -> some View {
        Toggle(title, isOn: Binding(get: { parts.contains(part) }, set: { included in
            if included { parts.insert(part) } else { parts.remove(part) }
        }))
    }

    private func save() {
        guard model.canSavePreset(from: frame) else { return }
        let rgb = hasColor ? NSColor(color).usingColorSpace(.sRGB).map {
            [$0.redComponent, $0.greenComponent, $0.blueComponent].map { Float(min(max($0, 0), 1)) }
        } : nil
        do {
            try store.save(model.makePreset(from: frame, name: trimmedName, includedParts: parts, canisterColor: rgb))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
