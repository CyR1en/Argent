import Foundation
import SwiftUI
import Testing
@testable import ArgentApp

/// The theme catalog and what the owner's Mode and theme come to: every palette readable, the choice
/// kept across launches, and a theme without a light version staying dark.
@MainActor @Suite struct ThemeTests {
    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let x = ThemePalette.luminance(a), y = ThemePalette.luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `color` at `opacity` over `ground`, as the window composites it.
    private static func over(_ color: UInt32, _ opacity: Double, _ ground: UInt32) -> UInt32 {
        ThemePalette.mix(ground, color, opacity)
    }

    private static var allVersions: [(String, ThemeVersion)] {
        ThemeCatalog.themes.flatMap { theme in
            (theme.light.map { [$0] } ?? []).map { ("\(theme.name) \($0.title)", $0) }
                + theme.dark.map { ("\(theme.name) \($0.title)", $0) }
        }
    }

    private static func defaults() -> UserDefaults { ScratchDefaults() }

    /// The Masks tab's tiles on the inspector: the theme's text on a tile at rest, hovered and pressed; and a tile that cannot be
    /// used, dimmed so it reads as such (no fill, a dashed edge, the tertiary text), whose words still read at 4.5 to 1, where a
    /// button dimmed by opacity would not. And dimmed it is: its words are fainter than a live tile's, and it has no fill.
    @Test func everyPaletteKeepsAMaskTilesWordsReadable() {
        #expect(MaskTileStyle.disabledInk < MaskTileStyle.restInk)
        for (name, version) in Self.allVersions {
            let palette = version.palette
            let ink: UInt32 = palette.isDark ? 0xffffff : 0x000000
            for ground in [palette.workspace, palette.chrome] {
                for fill in [MaskTileStyle.restInk, MaskTileStyle.hoverInk, MaskTileStyle.pressedInk] {
                    let tile = Self.over(ink, fill, ground)
                    #expect(Self.contrast(palette.text, tile) >= 4.5, "\(name) tile text at \(fill)")
                }
                let live = Self.over(ink, MaskTileStyle.restInk, ground), dimmed = Self.over(ink, MaskTileStyle.disabledInk, ground)
                let words = Self.over(palette.text, palette.tertiaryOpacity, dimmed)
                #expect(Self.contrast(words, dimmed) >= 4.5, "\(name) disabled tile")
                #expect(Self.contrast(words, dimmed) < Self.contrast(palette.text, live), "\(name) disabled tile is dimmer")
            }
        }
    }

    /// The mask list and the panel on the inspector: a row's name and what it does at rest and hovered, a
    /// mask that is off, and a component's. The hover is `Graphite.hoverFill`'s ink.
    @Test func everyPaletteKeepsAMaskRowsWordsReadable() {
        for (name, version) in Self.allVersions {
            let palette = version.palette
            let ink: UInt32 = palette.isDark ? 0xffffff : 0x000000
            for ground in [palette.workspace, palette.chrome] {
                for fill in [0, 0.06] {
                    let row = Self.over(ink, fill, ground)
                    #expect(Self.contrast(palette.text, row) >= 4.5, "\(name) row name at \(fill)")
                    #expect(Self.contrast(Self.over(palette.text, palette.secondaryOpacity, row), row) >= 4.5, "\(name) row summary at \(fill)")
                }
                // The panel's words on the glass, and the Add mask button, which is the tile's ink.
                let panel = Self.over(ink, MaskTileStyle.restInk, ground)
                #expect(Self.contrast(palette.text, panel) >= 4.5, "\(name) panel")
            }
        }
    }

    /// The selection ring, a 2-point line that alone says which row or tile is chosen: 3 to 1 against what it sits on in every theme
    /// (WCAG's non-text contrast). Catppuccin Latte's lavender gave 2.6 to 2.8 until R moved it (`docs/M2-shell.md` section 16).
    @Test func everyPalettesSelectionRingReads() {
        for (name, version) in Self.allVersions {
            let palette = version.palette
            for ground in [palette.workspace, palette.chrome] {
                #expect(Self.contrast(palette.selection, ground) >= 3, "\(name) selection ring")
            }
        }
    }

    /// Add, Subtract and Intersect, and the panel's checks, that cannot be used: the tile's treatment, words in the tertiary text on the
    /// glass at 4.5 to 1, where the 0.42 opacity they had came to 1.9 to 3.6 by calculation, and 1.6 on screen in Middle gray Dark, as `.plain` dimmed them again.
    @Test func everyPaletteKeepsADisabledMaskControlsWordsReadable() {
        for (name, version) in Self.allVersions {
            let palette = version.palette
            for ground in [palette.workspace, palette.chrome] {
                #expect(Self.contrast(Self.over(palette.text, palette.tertiaryOpacity, ground), ground) >= 4.5, "\(name) disabled mask control")
            }
        }
    }

    @Test func everyPaletteKeepsSettingsTilesAndPillsReadable() {
        for (name, version) in Self.allVersions {
            let palette = version.palette
            let ink: UInt32 = palette.isDark ? 0xffffff : 0x000000
            let pill = Self.over(ink, Pill.fillInk, palette.workspace)
            #expect(Self.contrast(palette.text, pill) >= 4.5, "\(name) pill")
            for fill in [SettingsAppearance.tileRestInk, SettingsAppearance.tileHoverInk] {
                let tile = Self.over(ink, fill, palette.workspace)
                #expect(Self.contrast(palette.text, tile) >= 4.5, "\(name) theme tile text at \(fill)")
                #expect(Self.contrast(Self.over(palette.text, palette.secondaryOpacity, tile), tile) >= 4.5,
                        "\(name) theme tile secondary at \(fill)")
                let badge = Self.over(ink, SettingsAppearance.tileBadgeInk, tile)
                #expect(Self.contrast(palette.text, badge) >= 4.5, "\(name) theme tile badge at \(fill)")
            }
        }
    }

    @Test func everyPaletteKeepsItsTextReadable() {
        #expect(Self.allVersions.count == 22)
        for (name, version) in Self.allVersions {
            let palette = version.palette
            let ink: UInt32 = palette.isDark ? 0xffffff : 0x000000
            let card = Self.over(ink, 0.05, palette.workspace)
            for ground in [palette.workspace, palette.chrome] {
                #expect(Self.contrast(palette.text, ground) >= 4.5, "\(name) text")
                #expect(Self.contrast(Self.over(palette.text, palette.secondaryOpacity, ground), ground) >= 4.5, "\(name) secondary")
                #expect(Self.contrast(Self.over(palette.text, palette.tertiaryOpacity, ground), ground) >= 4.5, "\(name) tertiary")
            }
            #expect(Self.contrast(Self.over(palette.text, palette.secondaryOpacity, card), card) >= 4.5, "\(name) secondary on a card")
            #expect(Self.contrast(palette.onPrimary, palette.primaryTop) >= 4.5, "\(name) on the primary's top")
            #expect(Self.contrast(palette.onPrimary, palette.primaryBottom) >= 4.5, "\(name) on the primary's foot")
            // The flag badge: its flag on the selection colour, a mark rather than text.
            #expect(Self.contrast(palette.onPrimary, palette.selection) >= 3, "\(name) flag")
        }
    }

    /// A floating surface (the dock, a notice, a tag) can sit over a photograph as bright or as dark as one gets, as the dock does over a
    /// zoomed frame. Through `.ultraThinMaterial`, measured on screen over white and black (dark #21201E to #B6B4B3, light #6F6C6B to
    /// #F5F5F3) and bounded here with headroom for display differences, its tint keeps text and secondary text at 4.5 to 1 in every
    /// theme, as does the solid fill Reduce Transparency gives it. The 0.38 it had came to 3.4 and 2.4 to 1 in Graphite Dark over white.
    @Test func floatingSurfaceTextReadsOverBrightAndDarkPhotographs() {
        for (name, version) in Self.allVersions {
            let palette = version.palette
            let backdrops: [UInt32] = palette.isDark ? [0x1a1a1a, 0xc0c0c0] : [0x606060, 0xfafafa]
            let tint = FloatingSurface.tintOpacity(isCard: false, isDark: palette.isDark)
            for ground in backdrops.map({ Self.over(palette.floatingOpaque, tint, $0) }) + [palette.floatingOpaque] {
                #expect(Self.contrast(palette.text, ground) >= 4.5, "\(name) floating text")
                #expect(Self.contrast(Self.over(palette.text, palette.secondaryOpacity, ground), ground) >= 4.5,
                        "\(name) floating secondary")
            }
        }
    }

    @Test func aPhotographsSurroundIsNeutralExceptGraphitesOwn() {
        for (name, version) in Self.allVersions where name != "Graphite Dark" {
            let surround = version.palette.photoSurround
            let red = surround >> 16 & 0xff, green = surround >> 8 & 0xff, blue = surround & 0xff
            #expect(red == green && green == blue, "\(name)")
        }
    }

    @Test func idsAreUniqueWithinTheCatalogAndATheme() {
        #expect(Set(ThemeCatalog.themes.map(\.id)).count == ThemeCatalog.themes.count)
        for theme in ThemeCatalog.themes {
            #expect(Set(theme.dark.map(\.id)).count == theme.dark.count, "\(theme.name)")
        }
    }

    @Test func aFirstLaunchIsGraphiteAndDarkAsTheAppHasAlwaysBeen() {
        let settings = AppearanceSettings(defaults: Self.defaults(), systemIsDark: false)
        #expect(settings.mode == .dark)
        #expect(settings.themeID == "graphite")
        let palette = settings.palette
        #expect(palette.isDark)
        #expect(palette.chrome == 0x2f3133 && palette.workspace == 0x373a3c && palette.photoSurround == 0x2a2c2e)
        #expect(palette.well == 0x2c2f31 && palette.placeholder == 0x3e4143 && palette.control == 0x45484a)
        #expect(palette.text == 0xf2f2f0 && palette.selection == 0xf4f3ef && palette.floatingOpaque == 0x323436)
        #expect(palette.primaryTop == 0xe2e4e6 && palette.primaryBottom == 0xc3c6c9 && palette.onPrimary == 0x1d1f21)
    }

    @Test func modeChoosesTheVersionAndSystemFollowsTheMac() {
        let settings = AppearanceSettings(defaults: Self.defaults(), systemIsDark: true)
        settings.selectTheme("catppuccin")
        #expect(settings.palette.workspace == 0x1e1e2e)
        settings.setMode(.light)
        #expect(settings.palette.workspace == 0xeff1f5)
        #expect(settings.colorScheme == .light)
        settings.setMode(.system)
        #expect(settings.palette.workspace == 0x1e1e2e)
        settings.setSystemIsDark(false)
        #expect(settings.palette.workspace == 0xeff1f5)
        settings.setSystemIsDark(true)
        #expect(settings.colorScheme == .dark)
    }

    @Test func aThemeWithoutALightVersionStaysDarkAndSaysSo() {
        let settings = AppearanceSettings(defaults: Self.defaults(), systemIsDark: false)
        settings.selectTheme("nord")
        #expect(!settings.staysDarkForWantOfLight)
        settings.setMode(.light)
        #expect(settings.palette.isDark)
        #expect(settings.colorScheme == .dark)
        #expect(settings.staysDarkForWantOfLight)
        // The Mac's own appearance still reads as light under it.
        settings.setMode(.system)
        #expect(settings.staysDarkForWantOfLight)
        settings.setSystemIsDark(true)
        #expect(!settings.staysDarkForWantOfLight)
        settings.setSystemIsDark(false)
        settings.selectTheme("graphite")
        #expect(!settings.staysDarkForWantOfLight)
        #expect(!settings.palette.isDark)
    }

    @Test func aDarkVersionSelectsItsThemeAndLeavesTheLightVersionAlone() {
        let settings = AppearanceSettings(defaults: Self.defaults(), systemIsDark: true)
        settings.selectDarkVersion("frappe", of: "catppuccin")
        #expect(settings.themeID == "catppuccin")
        #expect(settings.palette.workspace == 0x303446)
        settings.setMode(.light)
        #expect(settings.palette.workspace == 0xeff1f5)
        // Each theme keeps its own.
        settings.selectDarkVersion("storm", of: "tokyo-night")
        settings.setMode(.dark)
        #expect(settings.palette.workspace == 0x24283b)
        settings.selectTheme("catppuccin")
        #expect(settings.palette.workspace == 0x303446)
    }

    @Test func theChoiceIsKeptAcrossLaunches() {
        let defaults = Self.defaults()
        let first = AppearanceSettings(defaults: defaults, systemIsDark: true)
        first.setMode(.dark)
        first.selectDarkVersion("moon", of: "tokyo-night")
        let second = AppearanceSettings(defaults: defaults, systemIsDark: true)
        #expect(second.mode == .dark)
        #expect(second.themeID == "tokyo-night")
        #expect(second.palette.workspace == 0x222436)
        second.setMode(.light)
        let third = AppearanceSettings(defaults: defaults, systemIsDark: true)
        #expect(third.mode == .light)
        #expect(third.palette.workspace == 0xe1e2e7)
    }

    @Test func shellPreferencesSurviveThemeChangesAndRelaunch() {
        let defaults = Self.defaults()
        let settings = AppearanceSettings(defaults: defaults)
        #expect(settings.shellIsAtDefaults)
        #expect(settings.shellTransparency == 0.82)
        #expect(settings.shellTintSaturation == 1)
        #expect(settings.keepsTransparencyWhenInactive)
        settings.shellTransparency = 0
        #expect(!settings.shellIsAtDefaults)
        settings.shellTintSaturation = 1.75
        settings.keepsTransparencyWhenInactive = false
        settings.selectTheme("tokyo-night")

        let next = AppearanceSettings(defaults: defaults)
        #expect(next.shellTransparency == 0)
        #expect(next.shellTintSaturation == 1.75)
        #expect(!next.keepsTransparencyWhenInactive)
        #expect(next.themeID == "tokyo-night")
        next.shellTransparency = 0.82
        #expect(!next.shellIsAtDefaults)

        next.shellTransparency = 0.5
        next.ambientSurroundIntensity = 0.42
        next.resetShell()
        #expect(next.shellIsAtDefaults)
        let reset = AppearanceSettings(defaults: defaults)
        #expect(reset.shellIsAtDefaults)
        #expect(reset.shellTransparency == 0.82)
        #expect(reset.shellTintSaturation == 1)
        #expect(reset.keepsTransparencyWhenInactive)
        #expect(reset.ambientSurroundIntensity == 0.42)
        #expect(reset.themeID == "tokyo-night")
    }

    /// The reset button lights for each shell setting on its own: one moved off its default, the other two left at theirs.
    @Test func eachShellSettingAloneTakesTheShellOffItsDefaults() {
        let settings = AppearanceSettings(defaults: Self.defaults())
        let changes: [(String, (AppearanceSettings) -> Void)] = [
            ("transparency", { $0.shellTransparency = 0 }),
            ("tint saturation", { $0.shellTintSaturation = 1.75 }),
            ("transparency when inactive", { $0.keepsTransparencyWhenInactive = false }),
        ]
        for (name, change) in changes {
            #expect(settings.shellIsAtDefaults, "\(name)")
            change(settings)
            #expect(!settings.shellIsAtDefaults, "\(name)")
            settings.resetShell()
        }
        #expect(settings.shellIsAtDefaults)
    }

    @Test func shellTextReadsOverTheFrostAcrossThemesAndSliderRanges() {
        // Bound the sidebar material measured over black and white, with headroom for display differences.
        for (name, version) in Self.allVersions {
            let palette = version.palette, colors = GraphiteColors(palette)
            let backdrops: [UInt32] = palette.isDark ? [0x202022, 0x707073] : [0xa8a8a9, 0xeeeeef]
            let inks = [colors.ink, colors.shellSecondaryText].map { $0.resolve(in: EnvironmentValues()) }
            for saturation in [0.0, 1, 2] {
                for transparency in [0.0, 0.5, 0.82, 1] {
                    let shell = WindowShellStyle(palette: palette, transparency: transparency,
                                                 saturation: saturation, reduceTransparency: false)
                    for backdrop in backdrops {
                        let ground = Self.over(shell.tint, shell.opacity, backdrop)
                        for ink in inks {
                            let rgb = UInt32((ink.red * 255).rounded()) << 16 | UInt32((ink.green * 255).rounded()) << 8
                                | UInt32((ink.blue * 255).rounded())
                            #expect(Self.contrast(Self.over(rgb, Double(ink.opacity), ground), ground) >= 4.5, "\(name) shell")
                        }
                    }
                }
            }
        }
    }

    @Test func saturationIsAvailableOnlyForVisibleChromaticTint() {
        let settings = AppearanceSettings(defaults: Self.defaults())
        for theme in ["graphite", "middle-gray"] {
            settings.selectTheme(theme)
            settings.shellTintSaturation = 2
            let neutral = settings.shellStyle(reduceTransparency: false)
            #expect(neutral.saturationControl == .neutral)
            #expect(neutral.tint == settings.palette.chrome)
        }
        settings.selectTheme("tokyo-night")
        settings.shellTransparency = 1
        let frost = settings.shellStyle(reduceTransparency: false)
        #expect(frost.opacity == 0 && frost.saturationControl == .transparent)
        let solid = settings.shellStyle(reduceTransparency: true)
        #expect(solid.opacity == 1 && solid.saturationControl == .available)
        #expect(solid.tint != settings.palette.chrome)
        #expect(settings.shellTransparency == 1)
        settings.shellTransparency = 0
        settings.shellTintSaturation = 1
        #expect(settings.shellStyle(reduceTransparency: false).tint == settings.palette.chrome)
        settings.shellTintSaturation = 0
        #expect(settings.shellStyle(reduceTransparency: false).tint == ThemePalette.neutralGray(matching: settings.palette.chrome))
    }

    @Test func shellPreferencesRejectInvalidOrBooleanValues() {
        let defaults = Self.defaults()
        for value: Any in [true, false, "0.5", -0.1, 3.0, Double.nan] as [Any] {
            defaults.set(value, forKey: "appearanceShellTransparency")
            defaults.set(value, forKey: "appearanceShellTintSaturation")
            let settings = AppearanceSettings(defaults: defaults)
            #expect(settings.shellTransparency == 0.82 && settings.shellTintSaturation == 1)
        }
        defaults.set(0.998, forKey: "appearanceShellTransparency")
        defaults.set(0, forKey: "appearanceShellTintSaturation")
        let settings = AppearanceSettings(defaults: defaults)
        #expect(settings.shellTransparency == 1 && settings.shellTintSaturation == 0)
    }

    @Test func whatIsNoLongerKnownFallsBackRatherThanFailing() {
        let defaults = Self.defaults()
        defaults.set("sepia", forKey: "appearanceMode")
        defaults.set("gone", forKey: "appearanceTheme")
        defaults.set(["catppuccin": "gone"], forKey: "appearanceDarkVersions")
        let settings = AppearanceSettings(defaults: defaults, systemIsDark: true)
        #expect(settings.mode == .dark)
        #expect(settings.themeID == "graphite")
        settings.selectTheme("catppuccin")
        #expect(settings.palette.workspace == 0x1e1e2e)
    }

    @Test func theOpenRollBackdropIsOnUntilTurnedOffAndStaysAsChosen() {
        let defaults = Self.defaults()
        let first = AppearanceSettings(defaults: defaults, systemIsDark: true)
        #expect(first.showsOpenRollBackdrop)
        first.setShowsOpenRollBackdrop(false)
        let second = AppearanceSettings(defaults: defaults, systemIsDark: true)
        #expect(!second.showsOpenRollBackdrop)
        second.setShowsOpenRollBackdrop(true)
        let third = AppearanceSettings(defaults: defaults, systemIsDark: true)
        #expect(third.showsOpenRollBackdrop)
    }

    @Test func aBackdropValueOfTheWrongTypeFallsBackToOn() {
        let defaults = Self.defaults()
        defaults.set("off", forKey: "appearanceOpenRollBackdrop")
        #expect(AppearanceSettings(defaults: defaults, systemIsDark: true).showsOpenRollBackdrop)
    }

    @Test func ambientSurroundPreferencesSurviveThemeChangesAndRelaunch() {
        let defaults = Self.defaults()
        let first = AppearanceSettings(defaults: defaults, systemIsDark: true)
        #expect(first.frameSurroundIsAtDefaults)
        #expect(first.showsAmbientSurround)
        #expect(first.ambientSurroundIntensity == AppearanceSettings.defaultAmbientSurroundIntensity)
        #expect(first.showsAmbientSurroundShadow)

        first.setShowsAmbientSurround(false)
        #expect(!first.frameSurroundIsAtDefaults)
        first.ambientSurroundIntensity = 0.42
        first.setShowsAmbientSurroundShadow(false)
        first.selectTheme("tokyo-night")

        let second = AppearanceSettings(defaults: defaults, systemIsDark: true)
        #expect(!second.showsAmbientSurround)
        #expect(second.ambientSurroundIntensity == 0.42)
        #expect(!second.showsAmbientSurroundShadow)
        #expect(second.themeID == "tokyo-night")

        second.setShowsAmbientSurround(true)
        second.setShowsAmbientSurroundShadow(true)
        #expect(!second.frameSurroundIsAtDefaults)
        second.ambientSurroundIntensity = AppearanceSettings.defaultAmbientSurroundIntensity
        second.setShowsAmbientSurroundShadow(false)
        #expect(!second.frameSurroundIsAtDefaults)

        second.setShowsAmbientSurround(false)
        second.ambientSurroundIntensity = 0.42
        second.shellTransparency = 0.5
        second.resetFrameSurround()
        #expect(second.frameSurroundIsAtDefaults)
        let reset = AppearanceSettings(defaults: defaults, systemIsDark: true)
        #expect(reset.frameSurroundIsAtDefaults)
        #expect(reset.showsAmbientSurround)
        #expect(reset.ambientSurroundIntensity == 0.68)
        #expect(reset.showsAmbientSurroundShadow)
        #expect(reset.shellTransparency == 0.5)
        #expect(reset.themeID == "tokyo-night")
    }

    @Test func ambientSurroundPreferencesRejectInvalidOrWrongTypeValues() {
        let defaults = Self.defaults()
        for value: Any in [true, false, "0.5", -0.2, 1.5, Double.nan] as [Any] {
            defaults.set(value, forKey: "appearanceAmbientSurroundIntensity")
            let settings = AppearanceSettings(defaults: defaults)
            #expect(settings.ambientSurroundIntensity == AppearanceSettings.defaultAmbientSurroundIntensity)
        }
        for value: Any in ["off", 0.5, 2] as [Any] {
            defaults.set(value, forKey: "appearanceAmbientSurround")
            defaults.set(value, forKey: "appearanceAmbientSurroundShadow")
            let settings = AppearanceSettings(defaults: defaults)
            #expect(settings.showsAmbientSurround && settings.showsAmbientSurroundShadow)
        }
        defaults.set(0.996, forKey: "appearanceAmbientSurroundIntensity")
        #expect(AppearanceSettings(defaults: defaults).ambientSurroundIntensity == 1)

        // Programmatic non-finite assignments must not recurse infinitely or corrupt saved values.
        let settings = AppearanceSettings(defaults: defaults)
        settings.ambientSurroundIntensity = 0.55
        settings.ambientSurroundIntensity = .nan
        settings.ambientSurroundIntensity = .infinity
        settings.ambientSurroundIntensity = -.infinity
        #expect(settings.ambientSurroundIntensity == 0.55)
    }

    @Test func frameSurroundSpecimenLoadsBundledReferencePhotograph() throws {
        let image = try #require(FrameSurroundSpecimen.standIn)
        #expect(image.width == 512)
        #expect(image.height == 768)
    }
}
