import XCTest

/// Pure-logic coverage for BUG-28 (stream-list badge chips rendering white-on-white on the White
/// accent theme) — see `StreamBadgeChipView.effectiveTextChipColors` in
/// `NuvioTV/DesignSystem/StreamBadges.swift`.
///
/// Deliberately does NOT launch `XCUIApplication` (unlike `NuvioTVUITests.swift`'s device-driving
/// suite) — these are plain, fast asserts against a decision function.
///
/// Why this file mirrors the production logic instead of importing it: `NuvioTVUITests` is a
/// genuine `com.apple.product-type.bundle.ui-testing` target (`TEST_TARGET_NAME = NuvioTV`, no
/// `BUNDLE_LOADER`/`TEST_HOST` in project.pbxproj). Unlike a hosted *unit* test bundle — which is
/// `dlopen`-ed into the app process via `BUNDLE_LOADER`, so `@testable import` both compiles and
/// links — a UI test bundle runs in its own `XCTRunner` process and only ever talks to the app
/// under test through the accessibility/XPC bridge. `@testable import NuvioTV` here would type-check
/// (the app module's interface is visible) but fail at LINK time the moment a symbol is actually
/// referenced, since nothing embeds the app's object code into this bundle. So this file keeps a
/// small, exact mirror of just the pure enums/function under test — no `SharedCore`/`ImageIO`/
/// `UIKit` dependencies, nothing that needs the app to actually run. If `NuvioTV` ever grows a real
/// (hosted) Unit Testing target, these cases should move there as genuine `@testable import` tests
/// against the real `StreamBadgeChipView.effectiveTextChipColors` instead of this mirror — and this
/// file should be deleted so the two can't drift.
///
/// Keep this in sync by hand with `StreamBadgeChipView.effectiveTextChipColors` /
/// `Theme.Palette.luminance(fromHexString:)` whenever that logic changes.
final class StreamBadgeColorTests: XCTestCase {

    // MARK: - Mirror of Theme.Palette.luminance(fromHexString:)

    private func luminance(fromHexString hexString: String) -> Double? {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 3 || s.count == 6 || s.count == 8,
              let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b: Double
        switch s.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15.0
            g = Double((value >> 4) & 0xF) / 15.0
            b = Double(value & 0xF) / 15.0
        case 6:
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
        default: // 8: AARRGGBB (BUG-43 — Android/Compose pack convention, matching mobile)
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
        }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - Mirror of StreamBadgeChipView's pure color-decision types

    private enum ChipFgSource: Equatable {
        case semantic
        case pack
        case computedOnBg
        case focusedFixed
    }

    private enum ChipBgSource: Equatable {
        case semantic
        case pack
        case focusedFixed
    }

    private struct ChipColorDecision: Equatable {
        var fg: ChipFgSource
        var bg: ChipBgSource
        var showBorder: Bool
    }

    private static let defaultBgHex = "242424"

    /// Mirror of `StreamBadgeChipView.semanticFgApproxHex` (BUG-43) — the literal hex
    /// `Theme.Palette.textPrimary` was hard-coded to before it became `Color.primary`, used here
    /// only to stand in for that semantic color's (un-measurable outside SwiftUI) luminance.
    private static let semanticFgApproxHex = "F5F7F8"

    // MARK: - Mirror of StreamBadgeChipView.effectiveTextChipColors

    private func effectiveTextChipColors(
        textColorHex: String,
        tagColorHex: String,
        isFocused: Bool
    ) -> ChipColorDecision {
        if isFocused {
            return ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false)
        }

        let packBgLum = luminance(fromHexString: tagColorHex)
        let bgSource: ChipBgSource = packBgLum != nil ? .pack : .semantic
        let effectiveBgLum = packBgLum ?? luminance(fromHexString: Self.defaultBgHex)!

        guard let fgLum = luminance(fromHexString: textColorHex) else {
            let assumedSemanticFgLum = luminance(fromHexString: Self.semanticFgApproxHex)!
            if abs(assumedSemanticFgLum - effectiveBgLum) < 0.3 {
                return ChipColorDecision(fg: .computedOnBg, bg: bgSource, showBorder: true)
            }
            return ChipColorDecision(fg: .semantic, bg: bgSource, showBorder: true)
        }

        if abs(fgLum - effectiveBgLum) < 0.3 {
            return ChipColorDecision(fg: .computedOnBg, bg: bgSource, showBorder: true)
        }
        return ChipColorDecision(fg: .pack, bg: bgSource, showBorder: true)
    }

    // MARK: - Focused: always ignores the pack

    /// The reporter's case: a pack whose `textColor`/`tagColor` are both near-white. Focused, the
    /// row's platter is already near-white, so BOTH pack hexes must be discarded outright.
    func testWhiteOnWhitePack_focused_ignoresPackEntirely() {
        let decision = effectiveTextChipColors(textColorHex: "FFFFFF", tagColorHex: "F5F5F5", isFocused: true)
        XCTAssertEqual(decision, ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false))
    }

    func testDarkOnDarkPack_focused_ignoresPackEntirely() {
        let decision = effectiveTextChipColors(textColorHex: "1A1A1A", tagColorHex: "0D0D0D", isFocused: true)
        XCTAssertEqual(decision, ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false))
    }

    func testMissingHexes_focused_ignoresPackEntirely() {
        let decision = effectiveTextChipColors(textColorHex: "", tagColorHex: "", isFocused: true)
        XCTAssertEqual(decision, ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false))
    }

    // MARK: - Unfocused: contrast guard on a too-close pack pair

    /// BUG-28 reproduction: near-white fg on near-white bg, unfocused. The guard must kick in and
    /// swap the foreground for a computed pick rather than trusting the pack's illegible pair.
    func testWhiteOnWhitePack_unfocused_appliesContrastGuard() {
        let decision = effectiveTextChipColors(textColorHex: "FFFFFF", tagColorHex: "F5F5F5", isFocused: false)
        XCTAssertEqual(decision.fg, .computedOnBg)
        XCTAssertEqual(decision.bg, .pack)
        XCTAssertTrue(decision.showBorder)
    }

    /// Symmetric case: near-black fg on near-black bg should trip the same guard (dark-on-dark is
    /// just as illegible as white-on-white).
    func testDarkOnDarkPack_unfocused_appliesContrastGuard() {
        let decision = effectiveTextChipColors(textColorHex: "1A1A1A", tagColorHex: "0D0D0D", isFocused: false)
        XCTAssertEqual(decision.fg, .computedOnBg)
        XCTAssertEqual(decision.bg, .pack)
        XCTAssertTrue(decision.showBorder)
    }

    // MARK: - Unfocused: well-contrasted pack keeps its own colors

    func testWellContrastedPack_unfocused_keepsPackColors() {
        let decision = effectiveTextChipColors(textColorHex: "FFFFFF", tagColorHex: "1A1A1A", isFocused: false)
        XCTAssertEqual(decision.fg, .pack)
        XCTAssertEqual(decision.bg, .pack)
        XCTAssertTrue(decision.showBorder)
    }

    // MARK: - Unfocused: defaults when the pack supplies no colors

    func testMissingHexes_unfocused_usesSemanticDefaults() {
        let decision = effectiveTextChipColors(textColorHex: "", tagColorHex: "", isFocused: false)
        XCTAssertEqual(decision.fg, .semantic)
        XCTAssertEqual(decision.bg, .semantic)
        XCTAssertTrue(decision.showBorder)
    }

    /// Missing `tagColor` alone: the guard should compare against the semantic default background
    /// luminance (0x242424, dark) rather than crashing or silently ignoring the guard.
    func testMissingTagColorOnly_unfocused_guardsAgainstSemanticDefaultBg() {
        // White text against the (missing → semantic dark default) background: well-contrasted,
        // so the pack's own text color should still be used.
        let decision = effectiveTextChipColors(textColorHex: "FFFFFF", tagColorHex: "", isFocused: false)
        XCTAssertEqual(decision.fg, .pack)
        XCTAssertEqual(decision.bg, .semantic)
        XCTAssertTrue(decision.showBorder)
    }

    // MARK: - BUG-43: `tagColor` present but `textColor` missing (the language-badge case)

    /// BUG-43 reproduction: mobile never renders a text chip (`StreamBadgeChip.kt` only draws
    /// `imageURL`), so a badge pack commonly ships `tagColor` alone — nothing on mobile ever
    /// needed `textColor`. A tester's language badge hit exactly this: a light `tagColor`
    /// (flag-style fill) with `textColor` blank. Before the fix, the missing-`textColor` branch
    /// skipped the contrast guard entirely and always used the semantic foreground
    /// (`Theme.Palette.textPrimary` / `Color.primary`, near-white in this app's pinned dark
    /// scheme) — pairing near-white text with a near-white pack background, reading as a stray
    /// light-theme badge next to correctly-dark siblings. The guard must now catch this the same
    /// way it catches an explicit too-close `textColor`/`tagColor` pair.
    func testMissingTextColor_lightTagColor_unfocused_appliesContrastGuard() {
        let decision = effectiveTextChipColors(textColorHex: "", tagColorHex: "F5F5F5", isFocused: false)
        XCTAssertEqual(decision.fg, .computedOnBg)
        XCTAssertEqual(decision.bg, .pack)
        XCTAssertTrue(decision.showBorder)
    }

    /// Symmetric guard direction: a near-black `tagColor` alone is just as illegible against a
    /// near-white semantic default as a near-white one — the guard is a luminance-distance check,
    /// not a "light bg only" special case.
    func testMissingTextColor_darkTagColor_unfocused_appliesContrastGuard() {
        let decision = effectiveTextChipColors(textColorHex: "", tagColorHex: "0D0D0D", isFocused: false)
        // A near-black background is already far from near-white semantic text (that's the
        // ordinary, correct case) — the guard should NOT trip here, unlike the light-bg case above.
        XCTAssertEqual(decision.fg, .semantic)
        XCTAssertEqual(decision.bg, .pack)
        XCTAssertTrue(decision.showBorder)
    }

    /// Regression pin: a `tagColor` in the app's own dark-surface range (mid-dark, not
    /// pale/light) must keep today's semantic-foreground behavior — the BUG-43 guard should only
    /// swap in a computed pick for genuinely light backgrounds, not overcorrect on ordinary dark
    /// pack fills.
    func testMissingTextColor_midDarkTagColor_unfocused_keepsSemanticForeground() {
        let decision = effectiveTextChipColors(textColorHex: "", tagColorHex: "242424", isFocused: false)
        XCTAssertEqual(decision.fg, .semantic)
        XCTAssertEqual(decision.bg, .pack)
        XCTAssertTrue(decision.showBorder)
    }

    /// FOCUSED still ignores the pack entirely even when only `tagColor` is set (mirrors
    /// `testMissingHexes_focused_ignoresPackEntirely`, but with a light `tagColor` present) — the
    /// focus platter is near-white regardless of what the guard above would have picked.
    func testMissingTextColor_lightTagColor_focused_ignoresPackEntirely() {
        let decision = effectiveTextChipColors(textColorHex: "", tagColorHex: "F5F5F5", isFocused: true)
        XCTAssertEqual(decision, ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false))
    }

    // MARK: - BUG-43 (beta.12): 8-digit hex is AARRGGBB, matching mobile's pack convention

    /// `#FF1A1A1A` is an OPAQUE NEAR-BLACK in the Android/Compose convention every pack is
    /// authored in (`StreamBadgeChip.kt`: `8 -> hex` as AARRGGBB). The old RRGGBBAA read scored
    /// its luminance from the wrong channels (alpha counted as red, blue dropped), which fed the
    /// contrast guards garbage — the mechanism behind BUG-43's "shipped fix didn't take."
    func testEightDigitHex_readsAsArgb_opaqueDarkScoresDark() {
        let lum = luminance(fromHexString: "#FF1A1A1A")
        XCTAssertNotNil(lum)
        XCTAssertLessThan(lum!, 0.15, "an opaque dark ARGB color must score dark")
    }

    /// Symmetric pin: `#FFF5F5F5` (opaque near-white in ARGB) must score light, so the
    /// missing-`textColor` guard trips exactly as it does for the 6-digit "F5F5F5".
    func testEightDigitHex_readsAsArgb_opaqueLightScoresLight() {
        let lum = luminance(fromHexString: "#FFF5F5F5")
        XCTAssertNotNil(lum)
        XCTAssertGreaterThan(lum!, 0.85, "an opaque light ARGB color must score light")
    }

    /// End-to-end through the decision function: an 8-digit opaque LIGHT pack fill with no
    /// `textColor` must take the computed-dark-text branch, same as its 6-digit twin.
    func testEightDigitLightTagColor_unfocused_appliesContrastGuard() {
        let decision = effectiveTextChipColors(textColorHex: "", tagColorHex: "#FFF5F5F5", isFocused: false)
        XCTAssertEqual(decision.fg, .computedOnBg)
        XCTAssertEqual(decision.bg, .pack)
    }
}

/// Pure-logic coverage for BUG-49 (`CollectionsUI.swift`'s `TabChipLabel` painting near-white
/// `textPrimary` text on its own near-white focus platter when a chip was focused-but-unselected)
/// — see `TabChipLabel.body`'s `foregroundStyle` decision in
/// `NuvioTV/Screens/CollectionsUI.swift`.
///
/// Same mirror-not-import approach as `StreamBadgeColorTests` above (this is a UI test bundle,
/// not a hosted unit test target — see that class's doc comment for why `@testable import`
/// doesn't work here). `TabChipLabel`'s decision is a plain 3-way branch with no `Color` math
/// involved, so it mirrors exactly instead of approximating hex luminance like the badge tests
/// above do.
///
/// Keep this in sync by hand with `TabChipLabel.body`'s `foregroundStyle` branch whenever that
/// logic changes.
final class TabChipContrastTests: XCTestCase {

    /// Mirror of `ChipButtonStyle.ChipBody.labelColor` — the single decision `TabChip` now
    /// delegates to via `.chip(selected:)` (BUG-49 review round 1 removed the label-owned copy,
    /// whose capsule also covered the focus platter).
    private enum ChipLabelColor: Equatable {
        /// `FocusLook.onPlatter` — always wins while focused.
        case onFocusPlatter
        /// `Theme.Palette.accentText` — selected, at rest (label on the accent fill).
        case accentText
        /// `Theme.Palette.textPrimary` — unselected, at rest.
        case textPrimary
    }

    /// Mirror of `ChipButtonStyle.ChipBody.labelColor`'s decision.
    private func chipLabelColor(isFocused: Bool, isSelected: Bool) -> ChipLabelColor {
        if isFocused { return .onFocusPlatter }
        return isSelected ? .accentText : .textPrimary
    }

    /// BUG-49 reproduction: a focused-but-unselected chip. Before the fix the label-owned color
    /// fell through to `textPrimary` (near-white) on the style's near-white focus platter.
    func testFocusedUnselected_usesFocusPlatterColor_notTextPrimary() {
        XCTAssertEqual(chipLabelColor(isFocused: true, isSelected: false), .onFocusPlatter)
    }

    /// Focus must win outright over selection too, not just over the unselected default —
    /// mirrors the "focus wins unconditionally" rule `RowAccentTint`/BUG-45 established.
    func testFocusedSelected_usesFocusPlatterColor_notAccentText() {
        XCTAssertEqual(chipLabelColor(isFocused: true, isSelected: true), .onFocusPlatter)
    }

    /// Unfocused + selected keeps the style's look (accent fill with its own contrast color) —
    /// the fix must not change any unfocused case.
    func testUnfocusedSelected_keepsAccentTextColor() {
        XCTAssertEqual(chipLabelColor(isFocused: false, isSelected: true), .accentText)
    }

    /// Unfocused + unselected keeps today's look too.
    func testUnfocusedUnselected_keepsTextPrimaryColor() {
        XCTAssertEqual(chipLabelColor(isFocused: false, isSelected: false), .textPrimary)
    }
}
