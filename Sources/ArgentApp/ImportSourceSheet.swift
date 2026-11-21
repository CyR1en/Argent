import ArgentRoll
import SwiftUI

/// Import roll's sheet over the Rolls page: where a roll's frames come from. A card is chosen and Continue reads it; a
/// removable drive, or Import from a folder…, opens the panel to choose a folder of raws, which is read as a card is;
/// Add an existing folder… opens a folder where it is, nothing copied. Escape, Cancel or a click beside it closes it.
struct ImportSourceSheet: View {
    @Environment(RollModel.self) private var model
    @State private var chosen: Card.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import a roll")
                .font(Graphite.Typeface.panelTitle)
                .foregroundStyle(Graphite.text)
                .accessibilityAddTraits(.isHeader)
            Text("Argent copies the frames into a new roll folder and keeps it on the Rolls page. Nothing on the source is changed.")
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            SourceSection(title: "Cards and drives")
            if model.cards.isEmpty && model.drives.isEmpty {
                Text("No card or removable drive is connected")
                    .font(Graphite.Typeface.body)
                    .foregroundStyle(Graphite.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            ForEach(model.cards) { card in
                SourceRow(symbol: "sdcard", title: card.name, detail: cardDetail(card), isChosen: chosen == card.id,
                          trailing: .choice) {
                    chosen = card.id
                }
                .disabled(card.rawCount == nil)
                .help(card.rawCount == nil ? RollModel.mayNotReadText(card.name) : "Import the card's frames")
            }
            ForEach(model.drives) { drive in
                SourceRow(symbol: "externaldrive", title: drive.name, detail: "Choose a folder of ARW files on it", trailing: .more) {
                    model.chooseImportFolder(at: drive.volume)
                }
            }
            SourceSection(title: "Folders")
            SourceRow(symbol: "folder", title: "Import from a folder…", detail: "Copies its ARW files into a new roll", trailing: .more) {
                model.chooseImportFolder()
            }
            SourceRow(symbol: "folder.badge.plus", title: "Add an existing folder…",
                      detail: "Keeps the folder where it is and adds it as a roll. Nothing is copied.", trailing: .key("\u{2318}O")) {
                model.chooseExistingFolder()
            }
            HStack(spacing: Graphite.Metric.s) {
                Text("You can also drop a folder or a card on the window.")
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { model.isImportSourceShown = false }
                    .buttonStyle(.graphite(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    if let card = model.cards.first(where: { $0.id == chosen }) { model.startImport(card) }
                }
                .buttonStyle(.graphite(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(model.cards.first { $0.id == chosen }.map { !model.canImport($0) } ?? true)
                .help("Read the chosen card's frames, then choose the ones to import")
            }
            .padding(.top, 22)
        }
        .padding(24)
        .frame(width: 540)
        .graphiteCard(cornerRadius: 18)
        .onAppear {
            chosen = model.initialImportCard?.id
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Import a roll")
        .accessibilityAddTraits(.isModal)
    }

    private func cardDetail(_ card: Card) -> String {
        guard let count = card.rawCount else { return "Its folders could not be read" }
        let imported = model.importedCards.contains(card.volume.canonicalPath)
        return RollModel.framesText(count) + (imported ? " · imported since it was inserted" : "")
    }
}

private struct SourceSection: View {
    let title: String

    var body: some View {
        Text(verbatim: title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Graphite.tertiaryText)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One source: its symbol, name and what choosing it does, and at its end a choice, a way on, or its key.
private struct SourceRow: View {
    enum Trailing: Equatable {
        case choice
        case more
        case key(String)
    }

    let symbol: String
    let title: String
    let detail: String
    var isChosen = false
    let trailing: Trailing
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .light))
                    .frame(width: 38, height: 38)
                    .background(Graphite.ink(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: detail)
                        .font(Graphite.Typeface.small.monospacedDigit())
                        .foregroundStyle(Graphite.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                switch trailing {
                case .choice:
                    Circle()
                        .strokeBorder(isChosen ? Graphite.text : Graphite.ink(0.35), lineWidth: isChosen ? 5 : 1.5)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                case .more:
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Graphite.tertiaryText)
                        .accessibilityHidden(true)
                case .key(let key):
                    Text(verbatim: key)
                        .font(Graphite.Typeface.caption)
                        .foregroundStyle(Graphite.tertiaryText)
                }
            }
            .foregroundStyle(Graphite.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                shape.fill(Graphite.ink(isChosen ? 0.09 : isHovered && isEnabled ? 0.06 : 0.03))
            }
            .overlay {
                shape.strokeBorder(isChosen ? Graphite.ink(0.55) : Graphite.ink(0.1), lineWidth: isChosen ? 1.5 : 0.5)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .padding(.bottom, 6)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityHint(detail)
    }
}
