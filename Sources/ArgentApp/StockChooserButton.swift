import ArgentCore
import SwiftUI

/// Opens the film samples on the dock. The cartridge and name follow the roll's stock, or in the frame
/// view the open frame's, marked when it is the frame's own.
struct StockChooserButton: View {
    let isExpanded: Bool
    let action: () -> Void
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frame = model.shownFrame
        let isOwn = frame.map(model.hasOwnStock) ?? false
        Button(action: action) {
            HStack(spacing: 6) {
                FilmCanister(stockID: model.shownStock?.id, canisterColor: model.shownStock?.canisterColor)
                Text(verbatim: model.shownStockName ?? "No stock")
                    .font(DisplayFace.font(size: 13, face: "SemiBold"))
                    .lineLimit(1)
                    // Reserve the longest bundled name so auditioning stock keeps the adjacent controls still.
                    .frame(width: 80, alignment: .leading)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .foregroundStyle(isExpanded ? Graphite.dockAccent : Graphite.secondaryText)
            }
            .frame(height: 32)
        }
        .buttonStyle(.graphite(.secondary, size: .small, isOn: isExpanded))
        .modifier(FrameOverrideIndicator(isOwn: isOwn))
        .disabled(model.stockNames.isEmpty)
        .animation(reduceMotion ? nil : Graphite.Motion.quick, value: isExpanded)
        .help(Self.help(stockCount: model.builtInStockIndices.count, isFrame: frame != nil, isOwn: isOwn, roll: model.stockName))
        .accessibilityLabel(frame == nil ? "Choose film stock" : "Choose film stock for this frame")
        .accessibilityValue((model.shownStockName ?? "None") + RollControlsView.ownership(ControlsScope(frame: frame), isOwn: isOwn)
                            + (isExpanded ? ", expanded" : ", collapsed"))
        .accessibilityHint(isExpanded ? "Close the stock chooser."
                           : frame == nil ? "Choose a stock for the whole roll." : "Choose a stock for this frame only.")
    }

    /// The stock's number key, as the Stock menu has it: the first nine stocks, in library order.
    static func key(for index: Int) -> KeyboardShortcut? {
        guard (0..<9).contains(index) else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
    }

    /// "The film stock for the whole roll: every frame develops through it. Keys 1 to 6." In the frame view,
    /// the open frame's: "This frame's own film stock. The roll's is Portra 400. Keys 1 to 6."
    static func help(stockCount: Int, isFrame: Bool = false, isOwn: Bool = false, roll: String? = nil) -> String {
        let keys = min(stockCount, 9)
        let line = !isFrame ? "The film stock for the whole roll: every frame without its own develops through it."
            : isOwn ? "This frame's own film stock." + (roll.map { " The roll's is \($0)." } ?? "")
            : "This frame's film stock, the same as the roll's. Choosing another gives the frame its own."
        switch keys {
        case 0: return line
        case 1: return line + " Key 1."
        default: return line + " Keys 1 to \(keys)."
        }
    }
}

struct FilmCanister: View {
    let stockID: String?
    var canisterColor: Stock.CanisterColor? = nil

    private var label: Color {
        if let canisterColor {
            return Color(red: Double(canisterColor.red), green: Double(canisterColor.green), blue: Double(canisterColor.blue))
        }
        return switch stockID {
        case "argent-neutral": Color(white: 0.62)
        case "kodak-portra-160": Color(red: 0.73, green: 0.75, blue: 0.54)
        case "kodak-portra-800": Color(red: 0.80, green: 0.63, blue: 0.52)
        case "kodak-gold-200": Color(red: 0.90, green: 0.70, blue: 0.36)
        case "kodak-ultramax-400": Color(red: 0.53, green: 0.65, blue: 0.73)
        case "kodak-ektar-100": Color(red: 0.74, green: 0.52, blue: 0.52)
        case "fujifilm-superia-400", "fujifilm-pro-400h", "fujifilm-c200": Color(red: 0.51, green: 0.69, blue: 0.55)
        case "kodak-portra-160-natural": Color(red: 0.69, green: 0.65, blue: 0.54)
        case "kodak-colorplus-200": Color(red: 0.89, green: 0.62, blue: 0.31)
        case "kodak-vision3-500t": Color(red: 0.47, green: 0.66, blue: 0.78)
        case "kodak-vision3-500t-cinema": Color(red: 0.44, green: 0.55, blue: 0.70)
        case "cinestill-800t": Color(red: 0.73, green: 0.42, blue: 0.46)
        default: Color(red: 0.85, green: 0.72, blue: 0.48)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        VStack(spacing: 0) {
            Color(white: 0.50).frame(height: 2)
            Color(white: 0.18).frame(height: 3)
            label.overlay(alignment: .trailing) {
                VStack(spacing: 2) {
                    Rectangle()
                    Rectangle()
                }
                .foregroundStyle(.black.opacity(0.44))
                .frame(width: 4, height: 4)
            }
            Color(white: 0.20).frame(height: 2)
            Color(white: 0.48).frame(height: 2)
        }
        .overlay {
            LinearGradient(colors: [.black.opacity(0.23), .clear, .white.opacity(0.19), .black.opacity(0.28)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .frame(width: 13, height: 19)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.black.opacity(0.25), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}
