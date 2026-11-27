import ArgentCore
import ArgentRoll
import SwiftUI

// MARK: - Output choices

/// The output choices in the Develop page's panel (`DevelopPanel`), bound to the settings kept for every
/// roll (`RollModel.output`).
@MainActor enum OutputPicker {
    static func format(_ output: Binding<OutputSettings>) -> some View {
        OutputMenu(title: "Format", selection: output.format, options: OutputSettings.Format.allCases, name: \.title,
                   help: "The developed files' format: JPEG and HEIC at the quality chosen, or uncompressed 16-bit TIFF")
    }

    static func space(_ output: Binding<OutputSettings>) -> some View {
        OutputMenu(title: "Color space", selection: output.space, options: OutputSpace.allCases, name: \.title,
                   help: "The color space the developed files are written in, its profile embedded. Previews show the film in it too")
    }

    static func size(_ output: Binding<OutputSettings>) -> some View {
        OutputMenu(title: "Size", selection: output.size, options: OutputSettings.Size.pickerOptions, name: \.title,
                   help: "Full camera resolution, or Instagram-sized long edge (1080 px or 1350 px, preserving camera aspect ratio)")
    }

    /// Grain: its two choices side by side, the stock panel's and the Roll menu's own.
    static func grain(_ output: Binding<OutputSettings>) -> some View {
        GraphiteSegmented(selection: output.grain,
                          segments: OutputSettings.Grain.allCases.map { .init(value: $0, title: $0.title, help: grainHelp) },
                          size: .regular, fillsWidth: true)
            .accessibilityLabel("Grain")
    }

    static let grainHelp = "Natural develops the stock's film grain into the files; Off leaves it out"
}

/// A pop-up of one output choice: the value on a matte face as wide as offered, its choices with
/// the current one checked.
struct OutputMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let name: (Value) -> String
    let help: String

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(name($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MenuFace(text: name(selection), minWidth: 96)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // A menu drawn by its own label loses its accessibility label (macOS 27), so VoiceOver
        // gets the system's pop-up for the same choice: its name, its value and its choices.
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(name($0)).tag($0) }
            }
            .pickerStyle(.menu)
            // A picker standing in for a menu drops its title as its label unless given it again.
            .accessibilityLabel(title)
        }
        .help(help)
        .frame(maxWidth: .infinity)
    }
}

/// JPEG and HEIC quality, 0 to 100 as Lightroom's: its number, which can be typed, and a slider, in one
/// field. Dimmed for the uncompressed TIFF, whose number reads "–".
struct QualityControl: View {
    @Binding var output: OutputSettings
    /// Dimmed with the panel's other choices while they wait for a develop to end.
    @Environment(\.isEnabled) private var isEnabled
    /// The number being typed in. The page opens with nothing typed in: AppKit would give the
    /// field its first focus and select "92" in the system's highlight, the only colour on the
    /// page, where the keyboard belongs to the grid.
    @FocusState private var isTyping: Bool

    var body: some View {
        SliderField(valueWidth: 42) {
            number
        } slider: {
            slider
        }
        .disabled(!output.format.hasQuality)
        .opacity(output.format.hasQuality && isEnabled ? 1 : 0.42)
    }

    private var quality: Binding<Double> {
        Binding(get: { Double(output.quality) }, set: { value in
            let rounded = Int(value.rounded())
            if rounded != output.quality { output.quality = rounded }
        })
    }

    private var typed: Binding<Int> {
        let range = OutputSettings.qualityRange
        return Binding(get: { output.quality }, set: { value in
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            if clamped != output.quality { output.quality = clamped }
        })
    }

    // No step, which would draw a tick for each of the 101 values; the binding rounds instead.
    // No help tag either: on macOS 27 a slider's help, or its accessibility hint, becomes its
    // accessibility role description, so VoiceOver read the tag where it says "slider". The tag
    // is the number's.
    private var slider: some View {
        let range = OutputSettings.qualityRange
        return Slider(value: quality, in: Double(range.lowerBound)...Double(range.upperBound))
            .controlSize(.small)
            .tint(Graphite.text)
            .accessibilityLabel("Quality")
            .accessibilityValue(output.format.hasQuality ? "\(output.quality)" : "None, TIFF is uncompressed")
    }

    @ViewBuilder private var number: some View {
        Group {
            if output.format.hasQuality {
                TextField("Quality", value: typed, format: IntegerFormatStyle<Int>().grouping(.never))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($isTyping)
                    .task {
                        // After the window has made the field its first responder.
                        await Task.yield()
                        isTyping = false
                    }
                    .accessibilityLabel("Quality number")
            } else {
                Text(verbatim: "–").accessibilityHidden(true)
            }
        }
        .font(Graphite.Typeface.number)
        .foregroundStyle(Graphite.text)
        .help(output.format.hasQuality ? "Higher keeps more detail in larger files; 92 is Argent's default. Type a number from 0 to 100."
                                       : "TIFF is uncompressed and has no quality")
    }
}
