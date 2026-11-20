import ArgentRoll
import SwiftUI

/// The command bar's roll center. The parent supplies the glass and the stock/settings actions.
struct RollDock: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            RollDockLine(compact: false, showsStatus: true)
            RollDockLine(compact: false, showsStatus: false)
            RollDockLine(compact: true, showsStatus: false)
            RollDockLine(compact: true, showsStatus: false, showsGrain: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Whole roll")
    }
}

private struct RollDockLine: View {
    let compact: Bool
    let showsStatus: Bool
    var showsGrain = true
    @Environment(RollModel.self) private var model

    var body: some View {
        HStack(spacing: compact ? 6 : 18) {
            RollDockField(title: "Rated at", value: ratedAtFace, selection: ratedAt, compact: compact,
                          spokenValue: ratedAtDescription) {
                ForEach(RollControls.RatedAt.allCases, id: \.self) { position in
                    Text(verbatim: RollControlsView.ratedAtItem(position, boxSpeed: boxSpeed)).tag(position)
                }
            }
            .disabled(model.roll == nil)
            .help("The roll's Rated at: \(ratedAtDescription). Every frame without its own develops at it.")

            RollDockField(title: "Lab balance", value: model.controls.labBalance.title,
                          selection: labBalance, compact: compact) {
                ForEach(RollControls.LabBalance.allCases, id: \.self) { balance in
                    Text(balance.title).tag(balance)
                }
            }
            .disabled(model.roll == nil)
            .help("The roll's Lab balance. Every frame without its own prints with it.")

            if showsGrain {
                RollDockField(title: "Grain", value: model.output.grain.title, selection: grain, compact: compact) {
                    ForEach(OutputSettings.Grain.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("Grain in every frame of the roll and every develop, as on the Develop page")
            }

            if showsStatus, let status = AutoStatusLabel.text(model) {
                Spacer(minLength: 0)
                Label(status, systemImage: model.isBalanced ? "checkmark.circle" : "ellipsis.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Graphite.secondaryText)
                    .fixedSize()
                    .preference(key: ShowsAutoStatus.self, value: true)
                    .help(model.isBalanced ? "Auto has settled the roll's exposure and lab balance."
                          : "Auto is measuring the frames and balancing the roll.")
            }
        }
    }

    private var boxSpeed: Float { model.currentStock?.boxSpeed ?? 0 }
    private var ratedAtFace: String { RollControlsView.ratedAtFace(model.controls.ratedAt, boxSpeed: boxSpeed) }
    private var ratedAtDescription: String { RollControlsView.ratedAtItem(model.controls.ratedAt, boxSpeed: boxSpeed) }
    private var ratedAt: Binding<RollControls.RatedAt> {
        Binding(get: { model.controls.ratedAt }, set: { model.controls.ratedAt = $0 })
    }
    private var labBalance: Binding<RollControls.LabBalance> {
        Binding(get: { model.controls.labBalance }, set: { model.controls.labBalance = $0 })
    }
    private var grain: Binding<OutputSettings.Grain> {
        Binding(get: { model.output.grain }, set: { model.output.grain = $0 })
    }
}

/// A two-line face backed by a native picker menu, including its checked value and keyboard access.
private struct RollDockField<Value: Hashable, Items: View>: View {
    let title: String
    let value: String
    let selection: Binding<Value>
    let compact: Bool
    var spokenValue: String? = nil
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            Picker(title, selection: selection, content: items)
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: compact ? 8 : 9, weight: .semibold))
                    .foregroundStyle(Graphite.secondaryText)
                HStack(spacing: 5) {
                    Text(verbatim: value)
                        .font(.system(size: compact ? 11 : 13, weight: .medium))
                        .monospacedDigit()
                    if !compact {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Graphite.secondaryText)
                    }
                }
                .foregroundStyle(Graphite.text)
            }
            .lineLimit(1)
            .padding(.horizontal, 2)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .graphiteMenu()
        .accessibilityRepresentation {
            Picker(title, selection: selection, content: items)
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue((spokenValue ?? value) + ", whole roll")
        }
    }
}
