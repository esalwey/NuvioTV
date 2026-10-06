import XCTest

/// Pure-logic coverage for FEAT-14 (opt-in accent-colored focus ring on artwork cards) — see
/// `Theme.Palette.focusRingHex(accentFocusHex:)` in `NuvioTV/DesignSystem/Theme.swift`.
///
/// Deliberately does NOT launch `XCUIApplication` (unlike `NuvioTVUITests.swift`'s device-driving
/// suite) — these are plain, fast asserts against a decision function, following the same
/// hand-mirrored-function convention as `StreamBadgeColorTests.swift` (see that file's header for
/// why: `NuvioTVUITests` is a genuine UI-testing target with no `BUNDLE_LOADER`/`TEST_HOST`, so
/// `@testable import NuvioTV` type-checks but fails at link time — nothing embeds the app's object
/// code into this bundle). This file keeps a small, exact mirror of just the pure functions under
/// test instead.
///
/// Keep this in sync by hand with `Theme.Palette.focusRingHex(accentFocusHex:)` whenever that
/// logic changes.
///
/// BUG-40 (beta feedback): `focusRingHex` used to route near-white hexes through a fixed dark
/// fallback via a luminance threshold (mirroring BUG-28's `onColor(forFillHex:)`), so the White
/// theme's focus ring rendered grey instead of white. That fallback existed for platter-contrast
/// reasons that don't apply to the ring — see `Theme.swift`'s doc comment on `focusRingHex` for
/// why — so the function is now the identity function and this suite was rewritten to match.
final class AccentFocusRingTests: XCTestCase {

    // MARK: - Mirror of Theme.Palette.focusRingHex(accentFocusHex:)

    private func focusRingHex(accentFocusHex: String) -> String {
        accentFocusHex
    }

    // MARK: - The seven themes' accentFocus hexes (Theme.swift:37-49's applyTheme table)

    private static let crimsonFocusHex = "FF5252"
    private static let oceanFocusHex = "42A5F5"
    private static let violetFocusHex = "AB47BC"
    private static let emeraldFocusHex = "66BB6A"
    private static let amberFocusHex = "FFA726"
    private static let roseFocusHex = "EC407A"
    private static let whiteFocusHex = "FFFFFF"

    // MARK: - Every theme's ring keeps the theme's own accent color, including White

    func testCrimsonFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.crimsonFocusHex), Self.crimsonFocusHex)
    }

    func testOceanFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.oceanFocusHex), Self.oceanFocusHex)
    }

    func testVioletFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.violetFocusHex), Self.violetFocusHex)
    }

    func testEmeraldFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.emeraldFocusHex), Self.emeraldFocusHex)
    }

    func testAmberFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.amberFocusHex), Self.amberFocusHex)
    }

    func testRoseFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.roseFocusHex), Self.roseFocusHex)
    }

    /// BUG-40: the White theme's near-white accentFocus (0xFFFFFF) used to fall back to a fixed
    /// dark ring hex ("1A1A1A") — a beta tester reported this as a grey ring after explicitly
    /// picking white. It now maps to itself like every other theme, so the ring renders white.
    func testWhiteFocusHex_mapsToItself() {
        XCTAssertEqual(focusRingHex(accentFocusHex: Self.whiteFocusHex), Self.whiteFocusHex)
    }

    // MARK: - Determinism

    func testFocusRingHex_isDeterministic() {
        for hex in [Self.crimsonFocusHex, Self.oceanFocusHex, Self.violetFocusHex,
                    Self.emeraldFocusHex, Self.amberFocusHex, Self.roseFocusHex, Self.whiteFocusHex] {
            XCTAssertEqual(focusRingHex(accentFocusHex: hex), focusRingHex(accentFocusHex: hex))
        }
    }

    // MARK: - Arbitrary/malformed/missing input all pass through unchanged (identity function)

    func testArbitraryGrayHex_returnsInputUnchanged() {
        XCTAssertEqual(focusRingHex(accentFocusHex: "BFBFBF"), "BFBFBF")
        XCTAssertEqual(focusRingHex(accentFocusHex: "C0C0C0"), "C0C0C0")
        XCTAssertEqual(focusRingHex(accentFocusHex: "808080"), "808080")
    }

    func testMalformedHex_returnsInputUnchanged() {
        XCTAssertEqual(focusRingHex(accentFocusHex: "not-a-hex"), "not-a-hex")
    }

    func testEmptyHex_returnsInputUnchanged() {
        XCTAssertEqual(focusRingHex(accentFocusHex: ""), "")
    }
}
