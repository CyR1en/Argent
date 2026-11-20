import AppKit
import Foundation
import Observation
import SwiftUI

/// Which of a theme's versions the window shows: the Mac's own appearance, or always one of the two.
enum ThemeMode: String, CaseIterable, Sendable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// The colours of one version of a theme, as sRGB values, which `Graphite` hands to every screen.
/// What the catalog leaves out is derived: the frame view's surround is a neutral gray, so no
/// theme's tint sits against a photograph, and the small steps of the workspace are mixed from it.
struct ThemePalette: Equatable, Sendable {
    /// The system's light surround, when a light theme names none: mid-light, never the sheet's
    /// white or cream beside a photograph.
    static let lightSurround: UInt32 = 0xc8c8c8

    var isDark: Bool
    var chrome: UInt32
    var workspace: UInt32
    var photoSurround: UInt32
    var well: UInt32
    var placeholder: UInt32
    var control: UInt32
    var text: UInt32
    var secondaryOpacity: Double
    var tertiaryOpacity: Double
    var selection: UInt32
    var primaryTop: UInt32
    var primaryBottom: UInt32
    var onPrimary: UInt32
    var floatingOpaque: UInt32

    init(isDark: Bool, chrome: UInt32, workspace: UInt32, photoSurround: UInt32? = nil, well: UInt32,
         placeholder: UInt32? = nil, control: UInt32? = nil, text: UInt32,
         secondaryOpacity: Double, tertiaryOpacity: Double, selection: UInt32? = nil,
         primaryTop: UInt32, primaryBottom: UInt32, onPrimary: UInt32, floatingOpaque: UInt32? = nil) {
        self.isDark = isDark
        self.chrome = chrome
        self.workspace = workspace
        self.photoSurround = photoSurround ?? (isDark ? Self.neutralGray(matching: workspace) : Self.lightSurround)
        self.well = well
        self.placeholder = placeholder ?? Self.mix(workspace, text, 0.06)
        self.control = control ?? Self.mix(workspace, text, 0.11)
        self.text = text
        self.secondaryOpacity = secondaryOpacity
        self.tertiaryOpacity = tertiaryOpacity
        self.selection = selection ?? primaryBottom
        self.primaryTop = primaryTop
        self.primaryBottom = primaryBottom
        self.onPrimary = onPrimary
        self.floatingOpaque = floatingOpaque ?? Self.mix(chrome, workspace, 0.25)
    }

    /// `a` moved toward `b` in sRGB. Amounts above one extend the tint to the edge of the gamut.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let from = Double((a >> shift) & 0xff), to = Double((b >> shift) & 0xff)
            return UInt32(min(255, max(0, (from + (to - from) * amount).rounded()))) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// Relative luminance (WCAG): what contrast is measured from.
    static func luminance(_ color: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((color >> shift) & 0xff) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }

    /// The gray as bright as `color`.
    static func neutralGray(matching color: UInt32) -> UInt32 {
        let y = luminance(color)
        let encoded = y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
        let level = UInt32((encoded * 255).rounded())
        return level << 16 | level << 8 | level
    }
}

/// One version of a theme, with the name its theme gives it ("Latte", "Dark Dimmed").
struct ThemeVersion: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let palette: ThemePalette
}

/// A theme: one light version, or none, and one or more dark versions, the first the default.
struct AppTheme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let light: ThemeVersion?
    let dark: [ThemeVersion]

    func darkVersion(id: String?) -> ThemeVersion {
        dark.first { $0.id == id } ?? dark[0]
    }
}

/// The app's themes. Graphite's dark version is the app's own design; Graphite Light and Middle gray
/// are Argent's, the gray after darktable's; the rest take their surfaces and text from the schemes'
/// published palettes, except where a value is moved so text reaches 4.5 to 1: see docs/M2-shell.md
/// section 16 for each change.
enum ThemeCatalog {
    private static func dark(_ id: String, _ title: String, chrome: UInt32, workspace: UInt32, surround: UInt32? = nil, well: UInt32,
                             text: UInt32, secondary: Double, tertiary: Double, selection: UInt32? = nil,
                             top: UInt32, bottom: UInt32, on: UInt32) -> ThemeVersion {
        ThemeVersion(id: id, title: title, palette: ThemePalette(
            isDark: true, chrome: chrome, workspace: workspace, photoSurround: surround, well: well, text: text,
            secondaryOpacity: secondary, tertiaryOpacity: tertiary, selection: selection,
            primaryTop: top, primaryBottom: bottom, onPrimary: on))
    }

    private static func light(_ title: String, chrome: UInt32, workspace: UInt32, surround: UInt32? = nil, well: UInt32,
                              text: UInt32, secondary: Double, tertiary: Double, selection: UInt32? = nil,
                              top: UInt32, bottom: UInt32, on: UInt32) -> ThemeVersion {
        ThemeVersion(id: "light", title: title, palette: ThemePalette(
            isDark: false, chrome: chrome, workspace: workspace, photoSurround: surround, well: well, text: text,
            secondaryOpacity: secondary, tertiaryOpacity: tertiary, selection: selection,
            primaryTop: top, primaryBottom: bottom, onPrimary: on))
    }

    static let themes: [AppTheme] = [
        AppTheme(
            id: "graphite", name: "Graphite",
            light: light("Light", chrome: 0xd2d4d6, workspace: 0xdfe1e3, well: 0xcfd1d3, text: 0x1d1f21,
                         secondary: 0.78, tertiary: 0.72, top: 0x45484b, bottom: 0x2f3133, on: 0xf2f2f0),
            dark: [ThemeVersion(id: "dark", title: "Dark", palette: ThemePalette(
                isDark: true, chrome: 0x2f3133, workspace: 0x373a3c, photoSurround: 0x2a2c2e, well: 0x2c2f31,
                placeholder: 0x3e4143, control: 0x45484a, text: 0xf2f2f0, secondaryOpacity: 0.68, tertiaryOpacity: 0.58,
                selection: 0xf4f3ef, primaryTop: 0xe2e4e6, primaryBottom: 0xc3c6c9, onPrimary: 0x1d1f21,
                floatingOpaque: 0x323436))]),
        AppTheme(
            id: "middle-gray", name: "Middle gray",
            light: light("Light", chrome: 0xa3a3a3, workspace: 0xb0b0b0, surround: 0x777777, well: 0x9a9a9a, text: 0x141414,
                         secondary: 0.86, tertiary: 0.80, top: 0x3a3a3a, bottom: 0x262626, on: 0xf1f1f1),
            dark: [dark("dark", "Dark", chrome: 0x525252, workspace: 0x5e5e5e, surround: 0x777777, well: 0x474747, text: 0xf1f1f1,
                        secondary: 0.94, tertiary: 0.84, selection: 0xf1f1f1, top: 0xe2e2e2, bottom: 0xd4d4d4, on: 0x262626)]),
        AppTheme(
            id: "gruvbox", name: "Gruvbox",
            light: light("Light", chrome: 0xf2e5bc, workspace: 0xfbf1c7, well: 0xebdbb2, text: 0x3c3836,
                         secondary: 0.86, tertiary: 0.76, top: 0xb8460f, bottom: 0xaf3a03, on: 0xfbf1c7),
            dark: [dark("dark", "Dark", chrome: 0x1d2021, workspace: 0x282828, well: 0x1d2021, text: 0xebdbb2,
                        secondary: 0.78, tertiary: 0.64, top: 0xfbc850, bottom: 0xfabd2f, on: 0x282828)]),
        AppTheme(
            id: "github", name: "GitHub",
            light: light("Light", chrome: 0xf6f8fa, workspace: 0xffffff, well: 0xeaeef2, text: 0x1f2328,
                         secondary: 0.80, tertiary: 0.72, top: 0x1a73dc, bottom: 0x0969da, on: 0xffffff),
            dark: [dark("dark-dimmed", "Dark Dimmed", chrome: 0x1c2128, workspace: 0x22272e, well: 0x1c2128, text: 0xcdd9e5,
                        secondary: 0.80, tertiary: 0.70, top: 0x6fabf7, bottom: 0x539bf5, on: 0x1c2128),
                   dark("dark", "Dark", chrome: 0x010409, workspace: 0x0d1117, well: 0x161b22, text: 0xe6edf3,
                        secondary: 0.76, tertiary: 0.64, top: 0x5299f8, bottom: 0x2f81f7, on: 0x0d1117)]),
        AppTheme(
            id: "one-dark-pro", name: "One Dark Pro",
            light: light("One Light", chrome: 0xeaeaeb, workspace: 0xfafafa, well: 0xe5e5e6, text: 0x383a42,
                         secondary: 0.86, tertiary: 0.78, top: 0x366be4, bottom: 0x2d65dc, on: 0xffffff),
            dark: [dark("one-dark", "One Dark", chrome: 0x21252b, workspace: 0x282c34, well: 0x21252b, text: 0xabb2bf,
                        secondary: 0.92, tertiary: 0.82, top: 0x7abcf2, bottom: 0x61afef, on: 0x21252b)]),
        AppTheme(
            id: "tokyo-night", name: "Tokyo Night",
            light: light("Day", chrome: 0xd0d5e3, workspace: 0xe1e2e7, well: 0xd0d5e3, text: 0x243f85,
                         secondary: 0.92, tertiary: 0.86, top: 0x2c70da, bottom: 0x2569d4, on: 0xffffff),
            dark: [dark("night", "Night", chrome: 0x16161e, workspace: 0x1a1b26, well: 0x16161e, text: 0xc0caf5,
                        secondary: 0.80, tertiary: 0.66, top: 0x8fb1f8, bottom: 0x7aa2f7, on: 0x16161e),
                   dark("storm", "Storm", chrome: 0x1f2335, workspace: 0x24283b, well: 0x1f2335, text: 0xc0caf5,
                        secondary: 0.82, tertiary: 0.72, top: 0x8fb1f8, bottom: 0x7aa2f7, on: 0x1f2335),
                   dark("moon", "Moon", chrome: 0x1e2030, workspace: 0x222436, well: 0x1e2030, text: 0xc8d3f5,
                        secondary: 0.80, tertiary: 0.70, top: 0x95b7ff, bottom: 0x82aaff, on: 0x1e2030)]),
        AppTheme(
            id: "dracula", name: "Dracula",
            light: light("Alucard", chrome: 0xf4efdc, workspace: 0xfffbeb, well: 0xefe9d3, text: 0x1f1f1f,
                         secondary: 0.78, tertiary: 0.70, top: 0x7059ce, bottom: 0x644ac9, on: 0xffffff),
            dark: [dark("dracula", "Dracula", chrome: 0x21222c, workspace: 0x282a36, well: 0x191a21, text: 0xf8f8f2,
                        secondary: 0.72, tertiary: 0.60, top: 0xc8a4fa, bottom: 0xbd93f9, on: 0x21222c)]),
        AppTheme(
            id: "nord", name: "Nord",
            light: nil,
            dark: [dark("dark", "Dark only", chrome: 0x2e3440, workspace: 0x3b4252, well: 0x2e3440, text: 0xeceff4,
                        secondary: 0.78, tertiary: 0.68, top: 0x9bcad8, bottom: 0x88c0d0, on: 0x2e3440)]),
        AppTheme(
            id: "catppuccin", name: "Catppuccin",
            light: light("Latte", chrome: 0xe6e9ef, workspace: 0xeff1f5, well: 0xdce0e8, text: 0x4c4f69,
                         secondary: 0.94, tertiary: 0.86, selection: 0x6577f5, top: 0x8797fd, bottom: 0x7287fd, on: 0x11111b),
            dark: [dark("mocha", "Mocha", chrome: 0x181825, workspace: 0x1e1e2e, well: 0x11111b, text: 0xcdd6f4,
                        secondary: 0.80, tertiary: 0.66, top: 0xc0c8fe, bottom: 0xb4befe, on: 0x11111b),
                   dark("macchiato", "Macchiato", chrome: 0x1e2030, workspace: 0x24273a, well: 0x181926, text: 0xcad3f5,
                        secondary: 0.80, tertiary: 0.70, top: 0xc3c8f9, bottom: 0xb7bdf8, on: 0x181926),
                   dark("frappe", "Frappé", chrome: 0x292c3c, workspace: 0x303446, well: 0x232634, text: 0xc6d0f5,
                        secondary: 0.84, tertiary: 0.76, top: 0xc5c6f3, bottom: 0xbabbf1, on: 0x232634)]),
    ]

    static func theme(id: String?) -> AppTheme {
        themes.first { $0.id == id } ?? themes[0]
    }
}

private func color(_ hex: UInt32, _ opacity: Double = 1) -> Color {
    Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
          blue: Double(hex & 0xff) / 255, opacity: opacity)
}

/// The tint over the sidebar material, shared by the main window and its Mode previews.
struct WindowShellStyle {
    enum SaturationControl { case available, neutral, transparent }

    let tint: UInt32
    let opacity: Double
    let saturationControl: SaturationControl
    var overlay: Color { color(tint, opacity) }

    init(palette: ThemePalette, transparency: Double, saturation: Double, reduceTransparency: Bool) {
        opacity = reduceTransparency ? 1 : 1 - transparency
        let chrome = palette.chrome
        let red = chrome >> 16, green = chrome >> 8 & 255, blue = chrome & 255
        // A channel spread under 2% includes Graphite's cool gray. Keep that slight cast as designed.
        let neutral = max(red, green, blue) - min(red, green, blue) <= 5
        tint = neutral ? chrome : ThemePalette.mix(ThemePalette.neutralGray(matching: chrome), chrome, saturation)
        if neutral {
            saturationControl = .neutral
        } else {
            saturationControl = opacity == 0 ? .transparent : .available
        }
    }
}

/// A palette as the colours views draw with, built once when the palette changes.
struct GraphiteColors {
    let isDark: Bool
    let chrome, workspace, photoSurround, well, placeholder, control: Color
    let text, secondaryText, tertiaryText, selection: Color
    let primaryTop, primaryBottom, onPrimary, floatingOpaque: Color
    /// White over a dark theme's surfaces, black over a light one's, for hairlines and light fills.
    let ink: Color
    var shellSecondaryText: Color { ink.opacity(0.96) }
    /// A surface's firm edge with Increase Contrast (`Graphite.strongBorder`).
    var strongBorder: Color { ink.opacity(0.42) }
    var proofBackdrop: Color { Color(white: isDark ? 0.17 : 0.85) }
    var proofHighlight: Color { .white }
    var proofBadgeShadow: Color { .black.opacity(0.6) }
    /// The chosen segment lifted on its track.
    let segmentThumb: Color

    init(_ palette: ThemePalette) {
        isDark = palette.isDark
        chrome = color(palette.chrome)
        workspace = color(palette.workspace)
        photoSurround = color(palette.photoSurround)
        well = color(palette.well)
        placeholder = color(palette.placeholder)
        control = color(palette.control)
        text = color(palette.text)
        secondaryText = color(palette.text, palette.secondaryOpacity)
        tertiaryText = color(palette.text, palette.tertiaryOpacity)
        selection = color(palette.selection)
        primaryTop = color(palette.primaryTop)
        primaryBottom = color(palette.primaryBottom)
        onPrimary = color(palette.onPrimary)
        floatingOpaque = color(palette.floatingOpaque)
        ink = palette.isDark ? .white : .black
        segmentThumb = palette.isDark ? Color.white.opacity(0.17) : Color.white.opacity(0.92)
    }
}

/// The owner's Mode and theme, kept across launches, and the palette they come to, and whether the
/// Open roll page shows its backdrop. `Graphite` reads
/// `colors` here, so any view that draws with a token follows a change without being told. The
/// windows ask for the matching scheme (`colorScheme`), so glass, menus and sheets go with them;
/// `NSApp.appearance` stays unset, so the app can always read the Mac's own appearance, even under
/// a theme that keeps to dark.
@MainActor @Observable final class AppearanceSettings {
    static let shared = AppearanceSettings(defaults: .standard)

    private static let modeKey = "appearanceMode", themeKey = "appearanceTheme", versionsKey = "appearanceDarkVersions",
                       backdropKey = "appearanceOpenRollBackdrop"
    private static let transparencyKey = "appearanceShellTransparency", saturationKey = "appearanceShellTintSaturation"
    private static let inactiveTransparencyKey = "appearanceShellKeepsTransparencyWhenInactive"
    private static let ambientSurroundKey = "appearanceAmbientSurround",
                       ambientIntensityKey = "appearanceAmbientSurroundIntensity",
                       ambientShadowKey = "appearanceAmbientSurroundShadow"
    static let transparencyRange = 0.0...1.0, tintSaturationRange = 0.0...2.0
    static let ambientSurroundIntensityRange = 0.0...1.0
    static let defaultAmbientSurroundIntensity = 0.68
    private static let defaultShowsAmbientSurround = true
    private static let defaultShowsAmbientSurroundShadow = true
    private static let defaultShellTransparency = 0.82
    private static let defaultKeepsTransparencyWhenInactive = true
    private static let defaultShellTintSaturation = 1.0

    private(set) var mode: ThemeMode
    private(set) var themeID: String
    /// The dark version chosen for each theme that has several, by theme id.
    private(set) var darkVersionIDs: [String: String]
    /// The Mac's own appearance, whatever the window is asked for.
    private(set) var systemIsDark: Bool
    private(set) var palette: ThemePalette
    private(set) var colors: GraphiteColors
    /// The Open roll page shows its backdrop, the Latent image. Not part of the palette.
    private(set) var showsOpenRollBackdrop: Bool
    /// The frame view picks up diffused edge colours from the open photograph instead of a flat surround.
    private(set) var showsAmbientSurround: Bool
    /// How strongly the ambient surround tints the neutral base, 0 to 1.
    var ambientSurroundIntensity: Double {
        didSet {
            guard ambientSurroundIntensity.isFinite else {
                ambientSurroundIntensity = oldValue.isFinite ? oldValue : Self.defaultAmbientSurroundIntensity
                return
            }
            let clamped = min(max((ambientSurroundIntensity * 100).rounded() / 100, Self.ambientSurroundIntensityRange.lowerBound),
                              Self.ambientSurroundIntensityRange.upperBound)
            if clamped != ambientSurroundIntensity {
                ambientSurroundIntensity = clamped
                return
            }
            defaults.set(ambientSurroundIntensity, forKey: Self.ambientIntensityKey)
        }
    }
    /// Soft grounding shadow behind the crisp photo edge while Ambient Surround is on.
    private(set) var showsAmbientSurroundShadow: Bool
    var shellTransparency: Double {
        didSet { defaults.set(shellTransparency, forKey: Self.transparencyKey) }
    }
    var keepsTransparencyWhenInactive: Bool {
        didSet { defaults.set(keepsTransparencyWhenInactive, forKey: Self.inactiveTransparencyKey) }
    }
    var shellTintSaturation: Double {
        didSet { defaults.set(shellTintSaturation, forKey: Self.saturationKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var systemObservation: NSKeyValueObservation?

    /// First launch uses Graphite Dark, the Rolls backdrop, Ambient Surround and a lightly tinted frosted shell.
    init(defaults: UserDefaults, systemIsDark: Bool = true) {
        self.defaults = defaults
        self.systemIsDark = systemIsDark
        let mode = ThemeMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .dark
        let theme = ThemeCatalog.theme(id: defaults.string(forKey: Self.themeKey))
        let versions = defaults.dictionary(forKey: Self.versionsKey) as? [String: String] ?? [:]
        self.mode = mode
        themeID = theme.id
        darkVersionIDs = versions
        let palette = Self.palette(theme: theme, darkVersionID: versions[theme.id], mode: mode, systemIsDark: systemIsDark)
        self.palette = palette
        colors = GraphiteColors(palette)
        func savedBool(_ key: String, fallback: Bool) -> Bool {
            guard let number = defaults.object(forKey: key) as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
            return number.boolValue
        }
        showsOpenRollBackdrop = savedBool(Self.backdropKey, fallback: true)
        keepsTransparencyWhenInactive = savedBool(Self.inactiveTransparencyKey, fallback: Self.defaultKeepsTransparencyWhenInactive)
        showsAmbientSurround = savedBool(Self.ambientSurroundKey, fallback: Self.defaultShowsAmbientSurround)
        showsAmbientSurroundShadow = savedBool(Self.ambientShadowKey, fallback: Self.defaultShowsAmbientSurroundShadow)
        func saved(_ key: String, in range: ClosedRange<Double>, fallback: Double) -> Double {
            guard let number = defaults.object(forKey: key) as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), range.contains(number.doubleValue) else { return fallback }
            return (number.doubleValue * 100).rounded() / 100
        }
        ambientSurroundIntensity = saved(Self.ambientIntensityKey, in: Self.ambientSurroundIntensityRange,
                                         fallback: Self.defaultAmbientSurroundIntensity)
        shellTransparency = saved(Self.transparencyKey, in: Self.transparencyRange, fallback: Self.defaultShellTransparency)
        shellTintSaturation = saved(Self.saturationKey, in: Self.tintSaturationRange, fallback: Self.defaultShellTintSaturation)
    }

    /// What `mode` and the Mac come to in `theme`. A theme without a light version stays dark.
    static func palette(theme: AppTheme, darkVersionID: String?, mode: ThemeMode, systemIsDark: Bool) -> ThemePalette {
        let wantsLight = mode == .light || (mode == .system && !systemIsDark)
        if wantsLight, let light = theme.light { return light.palette }
        return theme.darkVersion(id: darkVersionID).palette
    }

    var theme: AppTheme { ThemeCatalog.theme(id: themeID) }

    func shellStyle(for preview: ThemePalette? = nil, reduceTransparency: Bool) -> WindowShellStyle {
        WindowShellStyle(palette: preview ?? palette, transparency: shellTransparency,
                         saturation: shellTintSaturation, reduceTransparency: reduceTransparency)
    }

    /// The scheme the windows ask for.
    var colorScheme: ColorScheme { palette.isDark ? .dark : .light }

    /// The theme has no light version, and the mode would otherwise show one.
    var staysDarkForWantOfLight: Bool {
        theme.light == nil && (mode == .light || (mode == .system && !systemIsDark))
    }

    func darkVersion(of theme: AppTheme) -> ThemeVersion {
        theme.darkVersion(id: darkVersionIDs[theme.id])
    }

    var shellIsAtDefaults: Bool {
        shellTransparency == Self.defaultShellTransparency && shellTintSaturation == Self.defaultShellTintSaturation
            && keepsTransparencyWhenInactive == Self.defaultKeepsTransparencyWhenInactive
    }

    func resetShell() {
        shellTransparency = Self.defaultShellTransparency
        keepsTransparencyWhenInactive = Self.defaultKeepsTransparencyWhenInactive
        shellTintSaturation = Self.defaultShellTintSaturation
    }

    var frameSurroundIsAtDefaults: Bool {
        showsAmbientSurround == Self.defaultShowsAmbientSurround
            && ambientSurroundIntensity == Self.defaultAmbientSurroundIntensity
            && showsAmbientSurroundShadow == Self.defaultShowsAmbientSurroundShadow
    }

    func resetFrameSurround() {
        setShowsAmbientSurround(Self.defaultShowsAmbientSurround)
        ambientSurroundIntensity = Self.defaultAmbientSurroundIntensity
        setShowsAmbientSurroundShadow(Self.defaultShowsAmbientSurroundShadow)
    }

    func setMode(_ mode: ThemeMode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        refresh()
    }

    func setShowsOpenRollBackdrop(_ shows: Bool) {
        showsOpenRollBackdrop = shows
        defaults.set(shows, forKey: Self.backdropKey)
    }

    func setShowsAmbientSurround(_ shows: Bool) {
        showsAmbientSurround = shows
        defaults.set(shows, forKey: Self.ambientSurroundKey)
    }

    func setShowsAmbientSurroundShadow(_ shows: Bool) {
        showsAmbientSurroundShadow = shows
        defaults.set(shows, forKey: Self.ambientShadowKey)
    }

    func selectTheme(_ id: String) {
        themeID = ThemeCatalog.theme(id: id).id
        defaults.set(themeID, forKey: Self.themeKey)
        refresh()
    }

    /// Chooses one of `theme`'s dark versions, which selects the theme too.
    func selectDarkVersion(_ versionID: String, of themeID: String) {
        darkVersionIDs[themeID] = versionID
        defaults.set(darkVersionIDs, forKey: Self.versionsKey)
        selectTheme(themeID)
    }

    func setSystemIsDark(_ isDark: Bool) {
        systemIsDark = isDark
        refresh()
    }

    /// Follows the Mac's appearance from here on. Called once as the app starts, when `NSApp` exists.
    func followSystemAppearance() {
        let application = NSApplication.shared
        setSystemIsDark(Self.isDark(application.effectiveAppearance))
        systemObservation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
            let isDark = MainActor.assumeIsolated { Self.isDark(application.effectiveAppearance) }
            Task { @MainActor in self?.setSystemIsDark(isDark) }
        }
    }

    private nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func refresh() {
        let next = Self.palette(theme: theme, darkVersionID: darkVersionIDs[themeID], mode: mode, systemIsDark: systemIsDark)
        guard next != palette else { return }
        palette = next
        colors = GraphiteColors(next)
    }
}
