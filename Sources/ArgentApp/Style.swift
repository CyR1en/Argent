import AppKit
import os
import SwiftUI

/// What remains of the Darkroom palette beside the Graphite system (Graphite.swift): the proofing
/// surround, which is a measured gray rather than a style.
enum Palette {
    /// 18 percent reflectance, L* 50, for judging prints against a neutral surround.
    static let gray18 = Color(.sRGB, red: 0.467, green: 0.467, blue: 0.467)
}

enum Metrics {
    /// The narrowest cell at each contact-sheet size, chosen by pinch, the size slider or the
    /// View menu; cells grow from it to fill the width.
    static let thumbnailWidths: [CGFloat] = [120, 168, 240, 336]
    /// A picture's corners.
    static let cornerRadius: CGFloat = 3

    /// The pixel size a cell `width` points wide renders at: its pixels rounded up to a step
    /// of 64, so the sheet does not ask for new renders at every point of a live resize. The
    /// picture is drawn up to a step smaller than it was rendered, never larger.
    static func pixelSize(forWidth width: CGFloat, scale: CGFloat) -> Int {
        let pixels = Int((width * scale).rounded(.up))
        return max(64, (pixels + 63) / 64 * 64)
    }
}

enum Motion {
    static let stateChange = Animation.easeOut(duration: 0.2)
    /// A thumbnail's first film render replacing its embedded preview: the sheet coming up.
    static let filmArrives = Animation.easeOut(duration: 0.4)
}

/// The one display face, Hanken Grotesk (SIL Open Font License 1.1, its licence beside it),
/// used in exactly two places: stock names in the stock panel and the About window.
/// Everything else is SF Pro.
enum DisplayFace {
    static let family = "Hanken Grotesk"
    private static let log = Logger(subsystem: "camera.argent.Argent", category: "type")

    /// Registers the bundled face for this process; without it the two places fall back to SF Pro.
    static func register() {
        guard let url = Bundle.module.url(forResource: "HankenGrotesk-Variable", withExtension: "ttf",
                                          subdirectory: "Resources/Fonts")
        else {
            log.error("display face missing from the bundle")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            log.error("display face not registered: \(String(describing: error?.takeRetainedValue()), privacy: .public)")
        }
    }

    /// The face at `size` in one of its named weights, `face` being "Regular", "Medium" or
    /// "SemiBold"; SF Pro at the same weight if the face did not register.
    static func font(size: CGFloat, face: String = "Regular") -> Font {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .face: face])
        if let font = NSFont(descriptor: descriptor, size: size), font.familyName == family {
            return Font(font)
        }
        let weight: Font.Weight = face == "SemiBold" ? .semibold : face == "Medium" ? .medium : .regular
        return .system(size: size, weight: weight)
    }
}
