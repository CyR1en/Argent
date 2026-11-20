import ArgentRoll
import SwiftUI

/// Over the open roll, the offer of a card just inserted: Not now until it is inserted again, Import,
/// or Open, which waits for a develop to finish since opening a roll stops one. Not a dialog: it takes
/// no focus and goes when the card is ejected or turned down. The card's name shortens in the
/// middle, so its count stays.
struct CardOfferNotice: View {
    let card: Card
    @Environment(RollModel.self) private var model

    var body: some View {
        Notice(symbol: "sdcard", text: RollModel.offerText(card), truncation: .middle) {
            Button("Not now") { model.dismissCard(card) }
                .buttonStyle(.graphite(.quiet, size: .small))
                .help("Hide this until the card is inserted again")
            Button("Import") { model.startImport(card) }
                .buttonStyle(.graphite(.secondary, size: .small))
                .disabled(!model.canImport(card))
                .help(model.importHelp(card))
            Button("Open") { model.openCard(card) }
                .buttonStyle(.graphite(.secondary, size: .small))
                .disabled(!model.canOpenOfferedCard)
                .help(model.isDeveloping ? "Open the card when the develop is done" : "Open the card as a roll. Shift-Command-O.")
        }
    }
}

/// Over the open roll, a line about a roll that could not be opened while this one is, or another
/// message for it, with a close.
struct MessageNotice: View {
    let message: String
    @Environment(RollModel.self) private var model

    var body: some View {
        Notice(symbol: "info.circle", text: message) {
            CloseButton(help: "Hide this message") { model.message = nil }
        }
    }
}
