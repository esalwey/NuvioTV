import XCTest
import SwiftUI
@testable import NuvioTV

/// BUG-102 (rc9, 2026-09-10): the ring verdict for labels that draw their own ring inside the
/// artwork frame (`FolderTile`, `CastCard`). The tester's report was the zoom-on + accent-ring-on
/// cell drawing nothing; every other cell must keep what it did before.
final class PlainLabelRingTests: XCTestCase {
    func testUnfocusedDrawsNothingInEveryMode() {
        for accent in [false, true] {
            for noZoom in [false, true] {
                XCTAssertNil(PlainLabelRing.resolve(accentFocusRing: accent, noZoomOnFocus: noZoom, focused: false),
                             "accent=\(accent) noZoom=\(noZoom)")
            }
        }
    }

    func testDefaultModeDrawsNothingWhenFocused() {
        XCTAssertNil(PlainLabelRing.resolve(accentFocusRing: false, noZoomOnFocus: false, focused: true))
    }

    func testZoomOnAccentRingOnDrawsAccent() {
        // The BUG-102 cell.
        XCTAssertEqual(PlainLabelRing.resolve(accentFocusRing: true, noZoomOnFocus: false, focused: true), .accent)
    }

    func testStillModeWithoutAccentDrawsNeutralStillRing() {
        XCTAssertEqual(PlainLabelRing.resolve(accentFocusRing: false, noZoomOnFocus: true, focused: true), .still)
    }

    func testStillModeWithAccentDrawsAccent() {
        // Mirrors `CardFocusMode.still(ringed: true)`: the accent ring replaces the neutral one.
        XCTAssertEqual(PlainLabelRing.resolve(accentFocusRing: true, noZoomOnFocus: true, focused: true), .accent)
    }

    func testBandReservedWheneverEitherSettingIsOn() {
        XCTAssertFalse(PlainLabelRing.reservesBand(accentFocusRing: false, noZoomOnFocus: false))
        XCTAssertTrue(PlainLabelRing.reservesBand(accentFocusRing: true, noZoomOnFocus: false))
        XCTAssertTrue(PlainLabelRing.reservesBand(accentFocusRing: false, noZoomOnFocus: true))
        XCTAssertTrue(PlainLabelRing.reservesBand(accentFocusRing: true, noZoomOnFocus: true))
    }

    /// BUG-108's invariant, and the whole reason `CardButtonStyleKind` and `PlainLabelRing.lift`
    /// are pure functions: the cell where `cardFocusButtonStyle` installs `RingCardButtonStyle`
    /// (a custom style, which can receive NO system lift) is exactly the cell where a plain label
    /// must draw `.manualScale` for itself. Break either side and the focused tile has no lift at
    /// all, or — the rc9 photo — the artwork lifts and the ring stays behind.
    func testRingModeGivesPlainLabelsTheirOwnLift() {
        for accent in [false, true] {
            for noZoom in [false, true] {
                let kind = CardButtonStyleKind.resolve(noZoomOnFocus: noZoom,
                                                      accentFocusRing: accent,
                                                      lift: .card)
                let lift = PlainLabelRing.lift(accentFocusRing: accent, noZoomOnFocus: noZoom)
                switch kind {
                case .ring:
                    XCTAssertEqual(lift, .manualScale, "accent=\(accent) noZoom=\(noZoom)")
                case .still, .borderless:
                    XCTAssertEqual(lift, .still(ringed: accent), "accent=\(accent) noZoom=\(noZoom)")
                }
            }
        }
    }

    /// `.systemLift` would hang a SECOND `.hoverEffect(.highlight)` inside the native button lift
    /// these labels still wear in the default mode — the one way to make the default render differ.
    func testPlainLabelNeverAsksForTheSystemHoverEffect() {
        for accent in [false, true] {
            for noZoom in [false, true] {
                XCTAssertNotEqual(PlainLabelRing.lift(accentFocusRing: accent, noZoomOnFocus: noZoom),
                                  .systemLift, "accent=\(accent) noZoom=\(noZoom)")
            }
        }
    }

    /// The four `TileFocusLift` tiles are NOT in scope (BUG-104): taking the native lift off them
    /// today would leave them with no focus motion at all.
    func testTileFocusLiftTilesKeepTheNativeLiftInRingMode() {
        XCTAssertEqual(CardButtonStyleKind.resolve(noZoomOnFocus: false,
                                                   accentFocusRing: true,
                                                   lift: .plain), .borderless)
    }

    /// Default mode is byte-identical for every label class — the BUG-93/BUG-108 regression gate.
    func testDefaultModeIsBareBorderlessForEveryLabelClass() {
        for lift in [CardButtonLift.card, .plain] {
            XCTAssertEqual(CardButtonStyleKind.resolve(noZoomOnFocus: false,
                                                       accentFocusRing: false,
                                                       lift: lift), .borderless)
        }
    }

    /// The only cross-file coupling: the pinned row's clip budget charges the same constant the
    /// folder tile's manual scale rises by, at every folder shape.
    func testFolderRowLiftAllowanceIsTheConstantForEveryShape() {
        let mode = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: true)
        for height in [CGFloat(330), 220, 391] { // poster, square, landscape at Medium
            XCTAssertEqual(PinnedRowTitle.focusLiftAllowance(artworkHeight: height,
                                                              captionVisible: true,
                                                              treatment: .cardTreatment,
                                                              mode: mode),
                           Theme.Size.heroPinnedRowFocusLiftAllowance)
        }
    }

    // MARK: - BUG-111: CompanyChip's small-label rise

    /// `CompanyChip`'s own capsule (52pt, `CompanyChipMetrics.capsuleHeight`) is the reason
    /// `smallLabelRise`/`smallLabelScaleCeiling` exist — the flat 20pt every other card class
    /// rises by would almost double it (`1 + 2×20/52 ≈ 1.77`). Asserts the actual rise this chip
    /// gets AND that plugging it back into the derived-scale formula (`cardLiftScale`'s formula —
    /// that function is `private` to `PosterCard.swift`, so the formula is reproduced here rather
    /// than called) reproduces the named ceiling.
    func testSmallLabelRiseHoldsTheScaleCeilingOnTheStudioChip() {
        let height = CompanyChipMetrics.capsuleHeight
        let rise = PlainLabelRing.smallLabelRise(height: height)
        XCTAssertEqual(rise, 3.12, accuracy: 0.01)
        let derivedScale = 1 + 2 * rise / height
        XCTAssertEqual(derivedScale, PlainLabelRing.smallLabelScaleCeiling, accuracy: 0.001)
    }

    /// Monotonic, never negative, and capped at `cardFocusLiftRise` (20pt — the flat rise every
    /// OTHER card class uses): a small label never rises MORE than a full-size card, only up to
    /// the same ceiling once it is tall enough. `0` at a degenerate height matches
    /// `cardLiftScale`'s own guard.
    func testSmallLabelRiseSaturatesAtTheCardConstant() {
        XCTAssertEqual(PlainLabelRing.smallLabelRise(height: 0), 0)
        XCTAssertEqual(PlainLabelRing.smallLabelRise(height: -10), 0)
        let heights: [CGFloat] = [1, 10, 52, 100, 200, 333.3, 403.3, 1000]
        var previous: CGFloat = 0
        for height in heights {
            let rise = PlainLabelRing.smallLabelRise(height: height)
            XCTAssertLessThanOrEqual(rise, 20, "height=\(height)")
            XCTAssertGreaterThanOrEqual(rise, previous, "not monotonic at height=\(height)")
            previous = rise
        }
        XCTAssertEqual(PlainLabelRing.smallLabelRise(height: 403.3), 20, accuracy: 0.01)
        XCTAssertEqual(PlainLabelRing.smallLabelRise(height: 1000), 20, accuracy: 0.01)
    }

    /// BUG-111: the widest studio chip is 212pt (180pt content + `Theme.Spacing.md` padding on
    /// each side — `CompanyChip`'s own `.frame(maxWidth: 180)` + `.padding(.horizontal:)`), and
    /// its ring-mode growth per side must stay under the row's own `Spacing.md` (16pt) gap or a
    /// lifted chip would touch its neighbour — the same clearance argument BUG-106 made for the
    /// saga row's ring-mode lift.
    func testGrownStudioChipStaysInsideTheRowGap() {
        let widestChip: CGFloat = 212
        let growthPerSide = widestChip * (PlainLabelRing.smallLabelScaleCeiling - 1) / 2
        XCTAssertEqual(growthPerSide, 12.72, accuracy: 0.01)
        XCTAssertLessThan(growthPerSide, Theme.Spacing.md)
    }

    /// BUG-111: `CompanyChip` deliberately reserves no `ringInset`-style band (unlike
    /// `FolderTile`/`CastCard`) because its own padding already clears `ringWidth` on every edge —
    /// this is the arithmetic that claim rests on, plus the capsule/radius pair the lift geometry
    /// keys off.
    func testStudioChipBandIsWhiteFillerNotArtwork() {
        XCTAssertGreaterThanOrEqual(min(Theme.Spacing.xs, Theme.Spacing.md), ringWidth)
        XCTAssertEqual(CompanyChipMetrics.capsuleHeight, 52)
        XCTAssertEqual(CompanyChipMetrics.platterCornerRadius, 26)
    }

    // MARK: - BUG-111 review finding 1: still-mode ring contrast on a white-surfaced label

    /// Default surface (`FolderTile`'s backdrop, `CastCard`'s photo — both dark): unchanged from
    /// `stillHighlight`, both with the parameter omitted and passed explicitly `false`.
    func testStillColorDefaultsToStillHighlightOnDarkSurfaces() {
        XCTAssertEqual(PlainLabelRing.stillColor(), stillHighlight)
        XCTAssertEqual(PlainLabelRing.stillColor(onLightSurface: false), stillHighlight)
    }

    /// `CompanyChip`'s capsule is a `Color.white.opacity(0.92)` fill — `stillHighlight`'s 85%
    /// white would go unnoticed on top of it (92% → 98.8% white, no other change). The
    /// light-surface branch must be a genuinely different, dark colour so contrast — not stroke
    /// width — still reads as the focus cue in still mode on this one label.
    func testStillColorIsADarkNeutralOnALightSurface() {
        let lightColor = PlainLabelRing.stillColor(onLightSurface: true)
        XCTAssertNotEqual(lightColor, stillHighlight)
        XCTAssertEqual(lightColor, Color.black.opacity(0.75))
    }

    /// The accent ring is untouched by the surface flag — `stillColor` only ever governs the
    /// neutral `.still` case; `PlainLabelRing.accent.color` still resolves to the theme's focus
    /// ring colour regardless of what surface a caller says it's drawing on.
    func testRingModeIsUnaffectedByTheSurfaceFlag() {
        XCTAssertEqual(PlainLabelRing.accent.color, Theme.Palette.focusRingColor)
    }
}
