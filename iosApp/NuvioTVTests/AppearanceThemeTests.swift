import XCTest
@testable import NuvioTV

/// Pure-logic coverage for the Appearance work: the theme key -> accent/focus table (including the
/// Custom theme's `CUSTOM:<accent>:<focus>` key), the custom-colour HSB maths, and the app-language
/// option list.
final class AppearanceThemeTests: XCTestCase {

    // MARK: - Theme.Palette.themeColors(forKey:)

    func testExistingThemesKeepTheirColours() {
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "CRIMSON").accent, 0xE53935)
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "CRIMSON").focus, 0xFF5252)
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "WHITE").focus, 0xFFFFFF)
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "OCEAN").accent, 0x1E88E5)
    }

    func testNewThemesResolve() {
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "GOLD").accent, 0xE8A91C)
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "GOLD").focus, 0xFFD45C)
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "JADE").focus, 0x7BF08D)
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "ROSE_GOLD").focus, 0xFFB37A)
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "ARCTIC_BLUE").focus, 0x4DE3FF)
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "GRAPHITE").focus, 0xF3F5F7)
    }

    func testEveryThemeHasADistinctAccentAndFocus() {
        let keys = ["CRIMSON", "OCEAN", "VIOLET", "EMERALD", "AMBER", "ROSE", "WHITE",
                    "GOLD", "JADE", "ROSE_GOLD", "ARCTIC_BLUE", "GRAPHITE"]
        let accents = Set(keys.map { Theme.Palette.themeColors(forKey: $0).accent })
        XCTAssertEqual(accents.count, keys.count)
    }

    func testCustomKeyCarriesItsOwnPair() {
        let colors = Theme.Palette.themeColors(forKey: "CUSTOM:2255AA:4F7FD6")
        XCTAssertEqual(colors.accent, 0x2255AA)
        XCTAssertEqual(colors.focus, 0x4F7FD6)
    }

    func testMalformedCustomKeyFallsBackToDefaultCustom() {
        for key in ["CUSTOM:", "CUSTOM:12345:ABCDEF", "CUSTOM:ZZZZZZ:ABCDEF", "CUSTOM:112233"] {
            XCTAssertEqual(Theme.Palette.themeColors(forKey: key).accent, 0xEC70A9, key)
        }
    }

    func testUnknownThemeFallsBackToCrimson() {
        XCTAssertEqual(Theme.Palette.themeColors(forKey: "NOT_A_THEME").accent, 0xE53935)
    }

    func testDarkContentOnLightAccents() {
        XCTAssertTrue(Theme.Palette.prefersDarkContent(forKey: "GOLD", accentHex: 0xE8A91C))
        XCTAssertTrue(Theme.Palette.prefersDarkContent(forKey: "GRAPHITE", accentHex: 0xAAB2BE))
        XCTAssertFalse(Theme.Palette.prefersDarkContent(forKey: "OCEAN", accentHex: 0x1E88E5))
        XCTAssertTrue(Theme.Palette.prefersDarkContent(forKey: "CUSTOM:FFEE88:FFFFFF", accentHex: 0xFFEE88))
        XCTAssertFalse(Theme.Palette.prefersDarkContent(forKey: "CUSTOM:101830:303860", accentHex: 0x101830))
    }

    // MARK: - CustomAccentColor

    func testParseAcceptsHashAndCase() {
        XCTAssertEqual(CustomAccentColor.parse(hex: "#1e88e5"), 0x1E88E5)
        XCTAssertEqual(CustomAccentColor.parse(hex: " 1E88E5 "), 0x1E88E5)
    }

    func testParseRejectsMalformed() {
        XCTAssertNil(CustomAccentColor.parse(hex: ""))
        XCTAssertNil(CustomAccentColor.parse(hex: "#12345"))
        XCTAssertNil(CustomAccentColor.parse(hex: "#GGGGGG"))
        XCTAssertNil(CustomAccentColor.parse(hex: "#1234567"))
    }

    func testHexStringPadsAndUppercases() {
        XCTAssertEqual(CustomAccentColor.hexString(0x000FA0), "#000FA0")
    }

    func testPrimariesRoundTripThroughHSB() {
        XCTAssertEqual(CustomAccentColor.hsb(fromRGB: 0xFF0000), .init(hue: 0, saturation: 100, brightness: 100))
        XCTAssertEqual(CustomAccentColor.hsb(fromRGB: 0x00FF00), .init(hue: 120, saturation: 100, brightness: 100))
        XCTAssertEqual(CustomAccentColor.hsb(fromRGB: 0x0000FF), .init(hue: 240, saturation: 100, brightness: 100))
        XCTAssertEqual(CustomAccentColor.rgb(from: .init(hue: 0, saturation: 100, brightness: 100)), 0xFF0000)
        XCTAssertEqual(CustomAccentColor.rgb(from: .init(hue: 120, saturation: 100, brightness: 100)), 0x00FF00)
        XCTAssertEqual(CustomAccentColor.rgb(from: .init(hue: 240, saturation: 100, brightness: 100)), 0x0000FF)
    }

    func testGreysHaveNoSaturation() {
        let grey = CustomAccentColor.hsb(fromRGB: 0x808080)
        XCTAssertEqual(grey.saturation, 0)
        XCTAssertEqual(grey.brightness, 50)
        XCTAssertEqual(CustomAccentColor.rgb(from: .init(hue: 0, saturation: 0, brightness: 100)), 0xFFFFFF)
    }

    /// Whole-number HSB loses a fraction of a step; converting back must land within a few levels
    /// per channel of the original, never on a different colour.
    func testHSBRoundTripStaysCloseForPresets() {
        func channels(_ rgb: UInt32) -> [Int] {
            [Int((rgb >> 16) & 0xFF), Int((rgb >> 8) & 0xFF), Int(rgb & 0xFF)]
        }
        for preset in CustomAccentColor.presets {
            let back = CustomAccentColor.rgb(from: CustomAccentColor.hsb(fromRGB: preset))
            for (a, b) in zip(channels(preset), channels(back)) {
                XCTAssertLessThanOrEqual(abs(a - b), 6, CustomAccentColor.hexString(preset))
            }
        }
    }

    func testSnapPicksTheNearestStep() {
        XCTAssertEqual(CustomAccentColor.snap(14, to: CustomAccentColor.hueSteps), 10)
        XCTAssertEqual(CustomAccentColor.snap(16, to: CustomAccentColor.hueSteps), 20)
        XCTAssertEqual(CustomAccentColor.snap(3, to: CustomAccentColor.brightnessSteps), 10)
        let snapped = CustomAccentColor.snappedHSB(fromRGB: 0x1E88E5)
        XCTAssertTrue(CustomAccentColor.hueSteps.contains(snapped.hue))
        XCTAssertTrue(CustomAccentColor.saturationSteps.contains(snapped.saturation))
        XCTAssertTrue(CustomAccentColor.brightnessSteps.contains(snapped.brightness))
    }

    // MARK: - AppLanguageSupport

    func testShippedCodesDropBaseAndDuplicates() {
        XCTAssertEqual(
            AppLanguageSupport.shippedCodes(localizations: ["en", "Base", "fr", "FR", "de"]),
            ["en", "fr", "de"]
        )
    }

    func testOptionsStartWithDeviceDefaultAndKeepTheCurrentValue() {
        let options = AppLanguageSupport.options(including: "pl", shipped: ["fr", "en"])
        XCTAssertEqual(options.first, AppLanguageSupport.deviceCode)
        XCTAssertTrue(options.contains("fr"))
        XCTAssertTrue(options.contains("en"))
        XCTAssertTrue(options.contains("pl"))
    }

    func testOptionsDoNotDuplicateTheCurrentValue() {
        let options = AppLanguageSupport.options(including: "FR", shipped: ["fr", "en"])
        XCTAssertEqual(options.count, 3)
    }

    func testLanguagesAreNamedInThemselves() {
        XCTAssertEqual(AppLanguageSupport.displayName(forCode: "fr"), "Fran\u{00E7}ais")
        XCTAssertEqual(AppLanguageSupport.displayName(forCode: "de"), "Deutsch")
    }
}
