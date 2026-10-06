import XCTest
import CoreGraphics
import UIKit
@testable import NuvioTV

/// BUG-87/88/89 (beta.18) — unit tests for `PinnedRowGeometry.plan`, the structural fit for the
/// pinned rows layout.
///
/// The tester's shape (Apple TV 4K, Poster Size **Large**, Hide Labels **ON**, No Zoom **ON**, Show
/// Hero **OFF** ⇒ FEAT-15's focus panel, `nuvioStyle` pinned layout) revealed a 535.3pt focusable
/// link frame resting inside a 523.3pt viewport. An over-tall frame has two legal rests — the
/// simulator top-anchors it, hardware bottom-anchors it ~75pt deeper — so the settle corrector and
/// the focus engine fought forever: titles that "keep trying to move back", a title glitch during
/// horizontal travel, and a second-to-last row that regressed after Medium → Large until restart.
///
/// These are pure-arithmetic tests on purpose. The plan is a value: no SwiftUI layout pass, no
/// hosting controller, nothing measured. What it CANNOT prove is where the focus engine actually
/// rests a frame that fits — that is the device pass.
final class PinnedRowGeometryTests: XCTestCase {

    // MARK: - The real Poster Size presets

    /// The three synced `widthDp` values the Appearance pane offers
    /// (`Settings/AppearanceSettingsPane.swift`, `PosterStyleControls.sizes`), run through
    /// `PosterStyle.init(from:)`'s own arithmetic: `width = dp * (Theme.Size.posterWidth / 126)`,
    /// `height = width * 1.5`. Derived rather than pasted so a change to `posterWidth` moves the
    /// tests with the app.
    private static func posterHeight(dp: CGFloat) -> CGFloat {
        dp * (Theme.Size.posterWidth / 126.0) * 1.5
    }
    private static let small = posterHeight(dp: 105)    // 275.0
    private static let medium = posterHeight(dp: 126)   // 330.0 == Theme.Size.posterHeight
    /// FEAT-39: 134dp, above the 335pt hero-compression gate, so it takes the Large dial.
    private static let mediumPlus = posterHeight(dp: 134) // 350.95…
    private static let large = posterHeight(dp: 154)    // 403.33…

    private static let allSizes: [(name: String, height: CGFloat)] = [
        ("Small", small), ("Medium", medium), ("Medium+", mediumPlus), ("Large", large),
    ]

    // MARK: - Focus modes

    /// BUG-87/89 (rc10): `plan` is MODE-DEPENDENT — `topReachFloor(lift:)` has to hold the focus
    /// lift, so the top reach and the compression differ between the zoom modes. Every call below
    /// therefore passes an EXPLICIT mode: the `FocusModeFlags.current` default reads
    /// `UserDefaults`, which would make this suite depend on whatever the last test (or the
    /// developer's simulator) left in the two Appearance keys.
    ///
    /// `noZoom` is the mode every pre-rc10 expectation in this file was written against (lift 0), so
    /// it is what the shared helpers use; the numbers moved anyway, because the floor gained the
    /// belt's `fadeIntrusionArm` (64 → 66).
    private static let noZoom = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false)
    /// The DEFAULT Appearance state, and the one the defect was filmed in: lift 20 ⇒ floor 86.
    private static let zoomOn = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false)
    /// rc12 BUG-87 follow-up: No Zoom with the default-OFF reach-hold A/B switched ON
    /// (`AboutSettingsPane`'s "No Zoom Row Reach (A/B)" row). `reachHoldsLiftEffective` is true here
    /// (both `reachHoldsLift` and `noZoom` are true), so `plan`'s `floorLift` spends the SAME 86
    /// floor `zoomOn` does — see `testNoZoomWithTheReachHoldTakesTheZoomOnFloor`.
    private static let noZoomHolding = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false,
                                                                     reachHoldsLift: true)

    // MARK: - Title metrics

    /// rc10 (Codex P2): `plan` is FONT-dependent as well as mode-dependent — the top reach's floor
    /// reserves room for one `Theme.Font.sectionTitle` line, and its default is the ACTIVE family's
    /// measured metric. Every call below therefore passes an EXPLICIT `titleHeight`, for the same
    /// reason every call passes an explicit `mode`: otherwise this suite's arithmetic would follow
    /// whatever font family the host simulator last applied.
    ///
    /// The SYSTEM font's number, which every expectation in this file was written against.
    private static let systemTitle = PinnedRowGeometry.measuredTitleHeight   // 38
    /// FEAT-31's Open Sans at the same text style, from the bundled faces' own vertical metrics:
    /// `(ascender 2189 + |descender| 600) / 2048 upem = 1.3618 em` × the 31pt `.callout` base
    /// ⇒ ≈42.2. All three bundled faces share those metrics, so the weight does not move it.
    private static let openSansTitle: CGFloat = 42.2

    /// Every flag combination, as the app can actually produce them, in No Zoom.
    ///
    /// `mode` defaults to plain `noZoom` so every pre-rc12 call site is unchanged; rc12 callers pass
    /// `noZoomHolding` to run the identical cross product through the reach-hold A/B. The label gets
    /// an appended `" hold=1"` only when the mode is holding, so a failure message says which of the
    /// two regimes it came from without changing any pre-existing label string.
    private static func crossProduct(mode: PinnedRowTitle.FocusModeFlags = noZoom) -> [(name: String, plan: PinnedRowGeometry.Plan)] {
        var out: [(name: String, plan: PinnedRowGeometry.Plan)] = []
        for (name, height) in allSizes {
            for captions in [false, true] {
                for cta in [false, true] {
                    for landscape in [false, true] {
                        let label = "\(name) captions=\(captions) showsCTA=\(cta) landscape=\(landscape)"
                            + (mode.reachHoldsLift ? " hold=1" : "")
                        let plan = PinnedRowGeometry.plan(posterHeight: height,
                                                          captionVisible: captions,
                                                          showsCTA: cta,
                                                          landscapeRows: landscape,
                                                          mode: mode,
                                                          titleHeight: systemTitle)
                        out.append((name: label, plan: plan))
                    }
                }
            }
        }
        return out
    }

    private let epsilon: CGFloat = 0.001

    // MARK: - The bit-identical guarantee

    /// Wave 10's promise, kept: Small and Medium compute a ZERO compression at every flag
    /// combination, so their layout is bit-identical to what shipped.
    ///
    ///     Small   24 + 88 + 275.0 + 8 = 395.0  →  under 455
    ///     Medium  24 + 88 + 330.0 + 8 = 450.0  →  under 455 (5pt spare)
    ///
    /// This is the scope decision the plan documents: Medium is the DEFAULT Poster Size with
    /// captions ON, its recorded band table shows zero corrections, and keying its compression to
    /// the link frame would compress the default configuration's hero by ~82pt to fix a rest nobody
    /// has reported. The fix applies to the sizes that were already compressing.
    /// rc12: run against both No Zoom regimes (`noZoom` and the reach-hold A/B's `noZoomHolding`) —
    /// Small/Medium never spend a compression at all (`legacyCompression` gates before the floor is
    /// ever read), so the hold changes nothing here and the loop is a parity check, not new
    /// coverage.
    func testSmallAndMediumSpendNothingAtEveryFlagCombination() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            // FEAT-39: "Medium " (with the trailing space from the label's own " captions=..."
            // suffix) deliberately excludes "Medium+" — that size is above the hero-compression gate
            // and takes the Large dial, so it is NOT bit-identical to what shipped.
            for (label, plan) in Self.crossProduct(mode: mode) where label.hasPrefix("Small") || label.hasPrefix("Medium ") {
                XCTAssertEqual(plan.compression, 0, accuracy: epsilon, label)
                XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon, label)
                XCTAssertEqual(plan.viewport, Theme.Size.heroPinnedRowsViewportBudget, accuracy: epsilon, label)
            }
        }
    }

    /// Landscape catalog rows are 203pt tall (`Theme.Size.landscapeHeight`) — 323 against the 455
    /// budget with the band and cushion — so nothing is ever spent for them, at any Poster Size, in
    /// either No Zoom regime (rc12).
    func testLandscapeRowsSpendNothingAtEverySize() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            for (label, plan) in Self.crossProduct(mode: mode) where label.contains("landscape=true") {
                XCTAssertEqual(plan.compression, 0, accuracy: epsilon, label)
                XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon, label)
                XCTAssertTrue(plan.fits, label)
            }
        }
    }

    // MARK: - Floors and bounds

    /// No dial may leave its legal range, ever — including for a synced `widthDp` past Large, which
    /// `PosterStyle.init(from:)` accepts without clamping and is therefore an ordinary payload here.
    /// The top reach in particular is only ever LOWERED (reach 100 kills focus resolution outright).
    /// rc12: run against both No Zoom regimes — the reach-hold A/B only ever RAISES the floor, so the
    /// `topReachFloor(lift: 0, …)` lower bound below stays a valid (looser) bound for `noZoomHolding`
    /// too; it is not re-derived per mode.
    func testFloorsAreNeverBreached() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            var cases = Self.crossProduct(mode: mode)
            for captions in [false, true] {
                for cta in [false, true] {
                    let oversized = PinnedRowGeometry.plan(posterHeight: Self.posterHeight(dp: 200),
                                                           captionVisible: captions,
                                                           showsCTA: cta,
                                                           landscapeRows: false,
                                                           mode: mode,
                                                           titleHeight: Self.systemTitle)
                    cases.append((name: "Oversized captions=\(captions) showsCTA=\(cta)", plan: oversized))
                }
            }
            for (label, plan) in cases {
                XCTAssertLessThanOrEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad + epsilon, label)
                XCTAssertGreaterThanOrEqual(plan.topReach,
                                            PinnedRowGeometry.topReachFloor(lift: 0,
                                                                            titleHeight: Self.systemTitle)
                                                - epsilon, label)
                XCTAssertLessThanOrEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach + epsilon, label)
                XCTAssertGreaterThanOrEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor - epsilon, label)
                XCTAssertGreaterThanOrEqual(plan.compression, 0, label)
                XCTAssertLessThanOrEqual(plan.compression,
                                         PinnedRowGeometry.elasticGive(showsCTA: label.contains("showsCTA=true")) + epsilon,
                                         label)
            }
        }
    }

    /// The invariant the whole fix exists for: wherever the plan claims a fit, the frame the focus
    /// engine reveals really is inside the viewport it has to rest in — and `restRange` is exactly
    /// the room left over, i.e. the width of the set of legal rests. rc12: both No Zoom regimes.
    func testFitsMeansTheLinkFrameIsInsideTheViewport() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            for (label, plan) in Self.crossProduct(mode: mode) {
                XCTAssertEqual(plan.viewport,
                               Theme.Size.heroPinnedRowsViewportBudget + plan.compression,
                               accuracy: epsilon, label)
                if plan.fits {
                    XCTAssertLessThanOrEqual(plan.linkFrame, plan.viewport + epsilon, label)
                    XCTAssertEqual(plan.restRange, plan.viewport - plan.linkFrame, accuracy: epsilon, label)
                } else {
                    XCTAssertGreaterThan(plan.linkFrame, plan.viewport, label)
                    XCTAssertEqual(plan.restRange, 0, accuracy: epsilon, label)
                }
            }
        }
    }

    // MARK: - The tester's shape

    /// Large + Hide Labels ON + FEAT-15 focus panel — the configuration BUG-87/88/89 were filmed
    /// in — in **No Zoom**. It must FIT, and it must fit with both reaches on their floors.
    ///
    /// rc2 (2026-09-06) reordered the dials so the reach CUSHIONS are spent before the hero
    /// compression: they exist to absorb rest error, and a frame that fits has no rest error, while
    /// every point of compression is description the viewer loses.
    ///
    ///     demand      24 + 88 + 403.33 + 0 + 44 + 8 − 455      = 112.33   (formula unchanged)
    ///     (a) bottom  44 → 24 (bottomReachFloor)                 −20  ⇒ 92.33 left
    ///     (b) top     88 → 66 (topReachFloor(lift: 0))           −22  ⇒ 70.33 left
    ///     (c) hero    min(70.33, panel give 142)                = 70.33  ⇒ 0 left
    ///     viewport    455 + 70.33                              = 525.33
    ///     linkFrame   66 + 403.33 + 0 + 24                      = 493.33
    ///     restRange                                            = 32  (Spacing.lg + cushion)
    ///
    /// ## Why this no longer equals Wave 10's own compression (rc10, BUG-87/89)
    ///
    /// rc4's version of this test asserted `compression == PinnedRowTitle.pinnedHeroCompression`
    /// (68.33) — "it fits at the number beta.17 already shipped" — which held only because the top
    /// reach floored at a flat 64. That flat floor was derived against the TITLE alone and ignored
    /// the focus lift, which is the whole of BUG-87/89: with zoom on, `staticClearance` 2 minus the
    /// 20pt lift is −18, and `Clearances`' `max(…, 0)` reported that permanent overlap as 0. The
    /// floor is derived and lift-aware now (`title floor 62 + lift + fadeIntrusionArm 4`), so it is
    /// 66 here and 2pt of the reach's give goes unspent — the compression takes 70.33 instead, and
    /// this shape is 2pt past the `HeroSlotGive` tier-3 gate, so the panel's synopsis is 2 lines
    /// rather than 3. That is the documented price of the clearance (see
    /// `PinnedRowGeometry.topReachFloor(lift:)`), not a drift to be tuned away here.
    func testStevensShapeFitsOnTheReachCushionsWithNoZoom() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 70.333, accuracy: 0.01)
        // 2pt MORE than Wave 10's own Large number, and exactly the 2pt the lift-aware floor keeps.
        XCTAssertEqual(plan.compression
                        - PinnedRowTitle.pinnedHeroCompression(rowArtworkHeight: Self.large),
                       2, accuracy: 0.01)
        XCTAssertEqual(plan.topReach,
                       PinnedRowGeometry.topReachFloor(lift: 0, titleHeight: Self.systemTitle),
                       accuracy: epsilon)
        XCTAssertEqual(plan.topReach, 66, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 525.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 493.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
        XCTAssertEqual(plan.regimeKey, "L403c0p1r0z1t38")
    }

    /// The same shape in the DEFAULT Appearance state (zoom on), which is where BUG-87/89 actually
    /// lived. The floor holds the 20pt lift, so only 2pt of the top reach's give is spendable and
    /// the compression takes the other 22.
    ///
    ///     (b) top     88 → 86 (topReachFloor(lift: 20))          −2   ⇒ 90.33 left
    ///     (c) hero    min(90.33, panel give 142)                = 90.33
    ///     viewport    455 + 90.33                              = 545.33
    ///     linkFrame   86 + 403.33 + 0 + 24                      = 513.33
    ///
    /// Reach 86 is back inside the proven 72-88 corridor, which is what retires rc4's unanswered
    /// "is 64 safe on hardware?" question rather than doubling it.
    func testStevensShapeWithZoomOnPaysTheLiftOutOfCompression() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.zoomOn,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.topReach,
                       PinnedRowGeometry.topReachFloor(lift: Theme.Size.heroPinnedRowFocusLiftAllowance,
                                                       titleHeight: Self.systemTitle),
                       accuracy: epsilon)
        XCTAssertEqual(plan.topReach, 86, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.compression, 90.333, accuracy: 0.01)
        XCTAssertEqual(plan.viewport, 545.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 513.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
        XCTAssertEqual(plan.regimeKey, "L403c0p1r0z0t38")
    }

    /// FEAT-39: Medium+ (134dp → 350.952… pt) sits above the 335pt hero-compression gate, so it
    /// takes the Large dial exactly the way Large does — `topReachFloor` and `bottomReachFloor` are
    /// artwork-height-independent (lift + title only), so both reaches land on the SAME 86/66/24
    /// numbers as Large. Only the compression differs, because Medium+'s artwork demands
    /// ~52.4pt less than Large's:
    ///
    ///     demand         350.952380952 − 291                          = 59.952380952
    ///     (a) bottom     44 → 24 (bottomReachFloor)            −20    ⇒ 39.952380952 left
    ///     (b) top        88 → 86 (topReachFloor(lift: 20))     −2     ⇒ 37.952380952 left   (zoom on)
    ///                     88 → 66 (topReachFloor(lift: 0))     −22    ⇒ 17.952380952 left   (no zoom)
    ///     (c) hero       min(left, panel give 142)             = left (unclamped either way)
    ///
    /// The rough numbers in the FEAT-39 spec (compression 38/18, viewport 493, linkFrame 461) were
    /// hand-rounded; the exact arithmetic above is what `plan(...)` actually returns, asserted here
    /// to three decimals. `restRange` still nets to exactly 32 (`Spacing.lg + settledCushion`) by the
    /// same construction that gives Large's Stevens shape 32 — the repeating decimals in viewport
    /// and linkFrame cancel.
    func testMediumPlusTakesTheLargeDialWithThreeSystemLines() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.mediumPlus, captionVisible: false,
                                          showsCTA: false, landscapeRows: false,
                                          mode: Self.zoomOn, titleHeight: 38)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.topReach, 86, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, 24, accuracy: epsilon)
        XCTAssertEqual(plan.compression, 37.952, accuracy: 0.01)
        XCTAssertEqual(plan.viewport, 492.952, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 460.952, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, 32, accuracy: epsilon)
        XCTAssertEqual(plan.regimeKey, "P351c0p1r0z0t38")

        let noZoom = PinnedRowGeometry.plan(posterHeight: Self.mediumPlus, captionVisible: false,
                                            showsCTA: false, landscapeRows: false,
                                            mode: Self.noZoom, titleHeight: 38)
        XCTAssertEqual(noZoom.topReach, 66, accuracy: epsilon)
        XCTAssertEqual(noZoom.compression, 17.952, accuracy: 0.01)
    }

    /// The set of legal rests must be narrower than the legibility band `PinnedRowSettle` corrects
    /// into, or the engine could still park somewhere the corrector wants to move — which is the
    /// bouncing the tester reported.
    ///
    /// The band, from `PinnedRowSettle`'s `bandLow`/`bandHigh` in BrowseComponents (~L2674-2677 at the
    /// time of writing; grep the symbols, the line numbers drift) with the row's own geometry,
    /// at the rc10 No-Zoom reach of 66 (the plan spends both reaches to their floors here):
    ///
    ///     clearance = max((Spacing.lg 24 + reach 66) − (titleInset 48 + title 38), 0) = 4
    ///     bandLow   = −clearance.focused = −4        (No Zoom ⇒ zero lift ⇒ focused == atRest)
    ///     lockup    = 24 + 66 + 403.33               = 493.33
    ///     bandHigh  = min(48, 48 + 525.33 − 493.33 − 8) = min(48, 72) = 48
    ///     width     = 52
    ///
    /// against `restRange` = 32, so the invariant still holds. The band is still much narrower than
    /// the pre-rc2 74 (it narrowed at the clearance end when the reach floor was first spent), but
    /// the 4pt it now keeps is `PinnedRowTitle.fadeIntrusionArm` by construction rather than the 2pt
    /// of arithmetic margin rc4 left — see `PinnedRowGeometry.topReachFloor(lift:)`.
    func testStevensShapeRestRangeIsNarrowerThanTheLegibilityBand() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        // No Zoom on Focus ⇒ `focusLiftAllowance` is 0, so the focused clearance is the static one.
        let clearance = PinnedRowTitle.staticClearance(titleHeight: PinnedRowGeometry.measuredTitleHeight,
                                                       cardTopReach: plan.topReach)
        let lockupExtent = Theme.Spacing.lg + plan.topReach + Self.large  // Hide Labels ⇒ no caption
        let bandLow = -clearance
        let bandHigh = min(Theme.Size.heroPinnedRowTitleInset,
                           Theme.Size.heroPinnedRowTitleInset + plan.viewport - lockupExtent
                               - Theme.Size.heroPinnedRowsSettledCushion)
        let bandWidth = bandHigh - bandLow
        XCTAssertEqual(clearance, 4, accuracy: epsilon)
        XCTAssertEqual(bandWidth, 52, accuracy: epsilon)
        XCTAssertLessThanOrEqual(plan.restRange, bandWidth)
    }

    /// BUG-87/89: the same shape as the test above, in BOTH zoom modes.
    ///
    /// The test above only ever asked the No-Zoom question, where the lift is 0 — so the rc4 reach
    /// floor passed it with a 2pt clearance while the DEFAULT Appearance state (zoom on) had a
    /// NEGATIVE one: `focused = max(2 − 20, 0)` clamped an 18pt permanent overlap to zero, the
    /// corrector's `bandLow` became 0, and the engine's own 32pt of rest freedom sat almost entirely
    /// outside the band. The three things this asserts are the three that broke:
    ///   1. the reach holds the title AND the lift, with the belt's arm edge to spare;
    ///   2. the clamp is therefore inert (`focused == focusedRaw`), i.e. nothing is being hidden;
    ///   3. the band is wider than the set of rests the engine may choose — the premise
    ///      `PinnedRowSettle`'s `UNEXPECTED-WITH-FIT` line asserts and could not rely on.
    func testLargeTopReachHoldsTheFocusLiftInBothZoomModes() {
        for noZoom in [false, true] {
            let label = "noZoom=\(noZoom)"
            let mode = PinnedRowTitle.FocusModeFlags(noZoom: noZoom, accentRing: false)
            let expectedLift: CGFloat = noZoom ? 0 : Theme.Size.heroPinnedRowFocusLiftAllowance
            let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                              captionVisible: false,
                                              showsCTA: false,
                                              landscapeRows: false,
                                              mode: mode,
                                              titleHeight: Self.systemTitle)
            XCTAssertTrue(plan.fits, label)
            XCTAssertEqual(plan.topReach,
                           PinnedRowGeometry.topReachFloor(lift: expectedLift,
                                                           titleHeight: Self.systemTitle),
                           accuracy: epsilon, label)

            let clearance = PinnedRowTitle.clearances(titleHeight: PinnedRowGeometry.measuredTitleHeight,
                                                      cardTopReach: plan.topReach,
                                                      artworkHeight: Self.large,
                                                      captionVisible: false,
                                                      treatment: .cardTreatment,
                                                      mode: mode)
            XCTAssertEqual(clearance.lift, expectedLift, accuracy: epsilon, label)
            // (1) and (2): the band holds title + lift with the belt's arm to spare, so the clamp
            // never bites and `focusedRaw` is not hiding a deficit behind a clean 0.
            XCTAssertGreaterThanOrEqual(clearance.focusedRaw,
                                        PinnedRowTitle.fadeIntrusionArm - epsilon, label)
            XCTAssertEqual(clearance.focused, clearance.focusedRaw, accuracy: epsilon, label)

            // (3) mirrors `PinnedRowSettle.settlePlan`'s band math — grep `bandLow`/`bandHigh` there.
            let lockupExtent = Theme.Spacing.lg + plan.topReach + Self.large  // Hide Labels ⇒ no caption
            let bandLow = -clearance.focused
            let bandHigh = min(Theme.Size.heroPinnedRowTitleInset,
                               Theme.Size.heroPinnedRowTitleInset + plan.viewport - lockupExtent
                                   - Theme.Size.heroPinnedRowsSettledCushion)
            XCTAssertLessThanOrEqual(plan.restRange, bandHigh - bandLow, label)
        }
    }

    /// The floor's contract as a function, independent of any one Poster Size: whatever lift it is
    /// handed, the reach it returns leaves the settled title clear of the FOCUSED card's artwork by
    /// at least the belt's arm — at the SYSTEM font's title height, which is the height it is handed
    /// here. Skipped where the cap binds — the floor may never exceed `heroPinnedRowTopPad`, because
    /// reach 100 kills focus resolution outright, so a lift larger than 22 is simply not coverable
    /// and the cap is the right answer rather than a raised reach. The same cap is what a TALLER
    /// title runs into, with the same consequence — see the Open Sans test below.
    func testTopReachFloorNeverLeavesTheLiftUncovered() {
        for lift in [0, 10, Theme.Size.heroPinnedRowFocusLiftAllowance, 30] as [CGFloat] {
            let reach = PinnedRowGeometry.topReachFloor(lift: lift, titleHeight: Self.systemTitle)
            XCTAssertLessThanOrEqual(reach, Theme.Size.heroPinnedRowTopPad + epsilon, "lift=\(lift)")
            guard reach < Theme.Size.heroPinnedRowTopPad else { continue }
            let atRest = PinnedRowTitle.staticClearance(titleHeight: PinnedRowGeometry.measuredTitleHeight,
                                                        cardTopReach: reach)
            XCTAssertGreaterThanOrEqual(atRest - lift,
                                        PinnedRowTitle.fadeIntrusionArm - epsilon, "lift=\(lift)")
        }
    }

    /// FEAT-31's **Open Sans**, at the shape BUG-87/89 was filmed in (Large + Hide Labels + FEAT-15
    /// panel) and in the DEFAULT Appearance state (zoom on) — the rc10 Codex P2 case.
    ///
    /// Open Sans's `sectionTitle` line is ≈42.2pt against the system font's 38, and the floor used to
    /// reserve the 38 while `PinnedRowTitle`'s clearance is measured from what is actually DRAWN. The
    /// 4.2pt gap is more than the entire margin the floor keeps:
    ///
    ///     floor     48 + 42.2 − 24 + 20 + 4 = 90.2  →  CAPPED at heroPinnedRowTopPad 88
    ///     (b) top   88 → 88                          −0   ⇒ 92.33 left for the hero
    ///     viewport  455 + 92.33                     = 547.33
    ///     linkFrame 88 + 403.33 + 0 + 24            = 515.33   ⇒ fits, restRange 32
    ///     atRest    (24 + 88) − (48 + 42.2)         = 21.8
    ///     focused   21.8 − 20                       = 1.8      ⇒ POSITIVE, so no stand-down
    ///
    /// Asserted in the order things broke: with the stale 38 the same shape floors at 86 and
    /// `focusedRaw` is −0.2, which is `PinnedRowSettle`'s `LIFT-DEFICIT` stand-down — for the whole
    /// session, on a font the app ships; with the live metric the CAP binds instead, the clearance is
    /// non-negative, the frame still fits, and the corrector keeps its rest.
    ///
    /// The 1.8 is stated rather than smoothed over: it is under `fadeIntrusionArm`, so at the cap the
    /// belt's arm margin is NOT guaranteed and the belt may fade a title that is technically clear.
    /// Documented at `PinnedRowGeometry.topReachFloor(lift:titleHeight:)` — the only alternative is a
    /// reach past 88, which kills focus resolution outright.
    func testOpenSansTitleTakesTheReachCapWithoutStandingTheCorrectorDown() {
        let lift = Theme.Size.heroPinnedRowFocusLiftAllowance

        // The defect: the system font's 38 leaves an Open Sans title a NEGATIVE focused clearance,
        // which is exactly the geometry the derived floor exists to make impossible.
        let staleFloor = PinnedRowGeometry.topReachFloor(lift: lift, titleHeight: Self.systemTitle)
        XCTAssertEqual(staleFloor, 86, accuracy: epsilon)
        let stale = PinnedRowTitle.clearances(titleHeight: Self.openSansTitle,
                                              cardTopReach: staleFloor,
                                              artworkHeight: Self.large,
                                              captionVisible: false,
                                              treatment: .cardTreatment,
                                              mode: Self.zoomOn)
        XCTAssertLessThan(stale.focusedRaw, 0,
                          "the stale 38pt floor must be shown to reproduce the LIFT-DEFICIT deficit")

        // The fix: the floor wants 90.2 for this title and takes the 88 cap.
        XCTAssertEqual(PinnedRowGeometry.topReachFloor(lift: lift, titleHeight: Self.openSansTitle),
                       Theme.Size.heroPinnedRowTopPad, accuracy: epsilon)
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.zoomOn,
                                          titleHeight: Self.openSansTitle)
        XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.compression, 92.333, accuracy: 0.01)
        XCTAssertLessThan(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: false))
        XCTAssertEqual(plan.viewport, 547.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 515.333, accuracy: 0.01)
        // The product question this test was asked to answer: the extra 2pt of compression does NOT
        // cost the fit — the panel's give is 142 and 92.33 of it is enough.
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.restRange,
                       Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)

        let clearance = PinnedRowTitle.clearances(titleHeight: Self.openSansTitle,
                                                  cardTopReach: plan.topReach,
                                                  artworkHeight: Self.large,
                                                  captionVisible: false,
                                                  treatment: .cardTreatment,
                                                  mode: Self.zoomOn)
        XCTAssertEqual(clearance.atRest, 21.8, accuracy: 0.01)
        XCTAssertEqual(clearance.focusedRaw, 1.8, accuracy: 0.01)
        // No stand-down: `settlePlan`'s LIFT-DEFICIT branch is `focusedRaw < 0`, and the clamp is
        // inert, so nothing is hiding a deficit behind a clean 0 either.
        XCTAssertGreaterThanOrEqual(clearance.focusedRaw, 0)
        XCTAssertEqual(clearance.focused, clearance.focusedRaw, accuracy: epsilon)
        // …but short of the belt's arm, which is the documented price of sitting on the cap.
        XCTAssertLessThan(clearance.focusedRaw, PinnedRowTitle.fadeIntrusionArm)

        // And the set of rests the engine may choose is still inside the corrector's band, so the
        // `UNEXPECTED-WITH-FIT` premise holds for this font too.
        let lockupExtent = Theme.Spacing.lg + plan.topReach + Self.large  // Hide Labels ⇒ no caption
        let bandLow = -clearance.focused
        let bandHigh = min(Theme.Size.heroPinnedRowTitleInset,
                           Theme.Size.heroPinnedRowTitleInset + plan.viewport - lockupExtent
                               - Theme.Size.heroPinnedRowsSettledCushion)
        XCTAssertLessThanOrEqual(plan.restRange, bandHigh - bandLow)
    }

    /// The live metric the shipping floor DEFAULTS to has to describe the token it claims to. A
    /// tolerance rather than an equality on purpose: this runs against whatever font family the test
    /// host currently has applied (`Theme.Font.apply` is process-global — `AppFontResolverTests`
    /// moves it), and a future tvOS could move the system `.callout` line by a point without anything
    /// being wrong. What would be wrong is a metric far from BOTH shipping values, which means the
    /// token mapping or the measurement drifted — and the floor would then reserve the wrong band.
    func testTheDefaultTitleMetricIsOneOfTheShippingTitleHeights() {
        let live = Theme.Font.sectionTitleLineHeight
        XCTAssertGreaterThan(live, 0)
        XCTAssertEqual(live, Self.systemTitle, accuracy: 6,
                       "live sectionTitle metric \(live) is far from both shipping heights"
                        + " (\(Self.systemTitle) system / \(Self.openSansTitle) Open Sans)")
    }

    /// The same Poster Size with the CAROUSEL hero, which has only 70pt of elastic give where the
    /// panel has 142, in No Zoom. The reaches are still spent first, but as of rc10's lift-aware
    /// floor the leftover (70.33) is 0.33pt MORE than the carousel can give, so its 70pt cap binds
    /// and this regime stops being an exact twin of the panel's plan:
    ///
    ///     demand 112.33 → bottom 44→24 (−20) → top 88→66 (−22) → compression min(70.33, 70) = 70
    ///     viewport  455 + 70                 = 525
    ///     linkFrame 66 + 403.33 + 0 + 24     = 493.33
    ///     restRange                          = 31.67   (0.33 short of Spacing.lg + cushion)
    ///
    /// It still FITS with room to spare, which is what matters — the 0.33 comes off the settled
    /// cushion, not off the frame. rc4's version of this test read 68.33 / 523.33 / 491.33 / 32 at
    /// the flat reach floor of 64.
    func testLargeHideLabelsWithCarouselHeroSpendsBothReachesThenTheRemainder() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: true,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 70, accuracy: 0.01)
        // The carousel's cap is what binds here, not the leftover demand.
        XCTAssertEqual(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: true), accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.topReach,
                       PinnedRowGeometry.topReachFloor(lift: 0, titleHeight: Self.systemTitle),
                       accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 525, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 493.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, 31.667, accuracy: 0.01)
        XCTAssertLessThan(plan.restRange,
                          Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion)
    }

    /// Large + captions + carousel hero is unsatisfiable by design: ~155.8pt of demand against 44pt
    /// of reach give and 70pt of elastic give — 114 against 156, in either spend order. Under the
    /// rc10 order the reaches floor at 24/66 (No Zoom) and 113.83 is left over, which the carousel's
    /// 70pt cap cannot cover. The plan must NOT pretend — it reports `fits == false` and hands back
    /// TODAY'S numbers verbatim (compression 68.33, reaches 88/44), so the visibility belt owns the
    /// residue in exactly the regime that shipped in beta.17. The fallback is mode-INDEPENDENT: with
    /// zoom on the reach floors at 86 and 133.83 is left over, still far past 70.
    func testLargeWithCaptionsAndCarouselHeroFallsBackToTodaysNumbers() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: true,
                                          showsCTA: true,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        XCTAssertFalse(plan.fits)
        XCTAssertEqual(plan.compression,
                       PinnedRowTitle.pinnedHeroCompression(rowArtworkHeight: Self.large),
                       accuracy: epsilon)
        XCTAssertEqual(plan.compression, 68.333, accuracy: 0.01)
        XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 523.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 578.833, accuracy: 0.01)
    }

    /// Large + captions in the FEAT-15 panel IS satisfiable, in No Zoom: both reaches go to their
    /// floors and the panel's 142pt of give covers the 113.83 that is left, short of its own cap.
    ///
    ///     demand    24 + 88 + 403.33 + 43.5 + 44 + 8 − 455 = 155.83
    ///     (a) bottom 44 → 24                                −20  ⇒ 135.83
    ///     (b) top    88 → 66 (topReachFloor(lift: 0))        −22  ⇒ 113.83
    ///     (c) hero   min(113.83, 142)                      = 113.83, 28.17 of give unspent
    ///     viewport  455 + 113.83                           = 568.83
    ///     linkFrame 66 + 403.33 + 43.5 + 24                = 536.83
    ///     restRange                                        = 32
    ///
    /// rc4's version of this test read 111.83 / 566.83 / 534.83 at the flat reach floor of 64. The
    /// panel's synopsis was already at one line in this regime and stays there (`HeroSlotGive`
    /// tiers: 36 + 32 + 43.83), so nothing regresses for it.
    func testLargeWithCaptionsInPanelModeFitsAfterBothReachesFloor() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: true,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 113.833, accuracy: 0.01)
        XCTAssertLessThan(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: false))
        XCTAssertEqual(plan.topReach,
                       PinnedRowGeometry.topReachFloor(lift: 0, titleHeight: Self.systemTitle),
                       accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 568.833, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 536.833, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
    }

    // MARK: - The spend order itself

    /// The rc2 order, stated as an invariant rather than as a number: the reaches are spent BEFORE
    /// the compression, so any plan that ends up compressing at all must already have both reaches
    /// on their floors. (The demand always exceeds the 44pt of reach give wherever the scope gate
    /// is open at all: `demand == legacyRawDemand + captionChrome + 44`.)
    ///
    /// The mirror clause covers the two paths that spend nothing: the closed gate (Small, Medium,
    /// landscape) and the unsatisfiable fallback both hand back the shipped reaches untouched.
    func testCompressionIsOnlySpentAfterBothReachesAreOnTheirFloors() {
        for (label, plan) in Self.crossProduct() {
            if plan.fits, plan.compression > 0 {
                XCTAssertEqual(plan.topReach,
                               PinnedRowGeometry.topReachFloor(lift: 0,
                                                               titleHeight: Self.systemTitle),
                               accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon, label)
            } else {
                XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon, label)
            }
        }
    }

    // MARK: - Give, purity, identity

    /// The panel's give is the carousel's plus the CTA slot it absorbed — the arithmetic that made
    /// the tester's shape satisfiable at all, and the number `HomeHeroForeground.synopsisSlotGive`
    /// has to be able to actually spend.
    func testElasticGiveMatchesTheHeroFormOnScreen() {
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: true),
                       Theme.Size.heroPinnedCompressionCap, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: true), 70, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: false), 142, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: false)
                        - PinnedRowGeometry.elasticGive(showsCTA: true),
                       Theme.Size.heroButtonSlotHeight + Theme.Spacing.md, accuracy: epsilon)
    }

    /// A pure function: the plan depends on its inputs and on nothing else (no live layout, no
    /// per-row or per-focus state). This is what lets `onChange(of: pinnedPlan.regimeKey)` be the
    /// only re-reveal trigger.
    func testPlanIsPure() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            for (label, plan) in Self.crossProduct(mode: mode) {
                let again = PinnedRowGeometry.plan(posterHeight: planHeight(for: label),
                                                   captionVisible: label.contains("captions=true"),
                                                   showsCTA: label.contains("showsCTA=true"),
                                                   landscapeRows: label.contains("landscape=true"),
                                                   mode: mode,
                                                   titleHeight: Self.systemTitle)
                XCTAssertEqual(plan, again, label)
            }
        }
    }

    /// One key per regime, and a different key for every other regime — the `onChange` contract.
    ///
    /// rc10 added the trailing `z` component, because the plan is mode-dependent now: the SAME
    /// (size × captions × hero form × row shape) tuple produces different reaches in the two zoom
    /// modes, so they must not share a key (`PinnedRowSettle.regimeFits` and its log-once sets are
    /// keyed on this string). `accentRing` is deliberately NOT encoded — since BUG-93 both zoom-on
    /// treatments lift by the same amount, so a ring flip produces an identical plan.
    /// rc12: the reach-hold A/B's `noZoomHolding` regime must not collide with plain `noZoom`
    /// either — combined, the two 32-entry cross products (`allSizes` × captions × CTA × landscape)
    /// must yield 64 distinct keys, and the holding regime's Medium key must be the plain key with
    /// `h1` appended (see `regimeKey`'s doc for why `h1` is conditional).
    func testRegimeKeysAreDistinctAcrossTheCrossProduct() {
        let keys = Self.crossProduct().map { $0.plan.regimeKey }
            + Self.crossProduct(mode: Self.noZoomHolding).map { $0.plan.regimeKey }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(keys).count, 64)
        XCTAssertEqual(PinnedRowGeometry.plan(posterHeight: Self.medium,
                                              captionVisible: true,
                                              showsCTA: true,
                                              landscapeRows: false,
                                              mode: Self.noZoom,
                                              titleHeight: Self.systemTitle).regimeKey,
                       "M330c1p0r0z1t38")
        XCTAssertEqual(PinnedRowGeometry.plan(posterHeight: Self.medium,
                                              captionVisible: true,
                                              showsCTA: true,
                                              landscapeRows: false,
                                              mode: Self.zoomOn,
                                              titleHeight: Self.systemTitle).regimeKey,
                       "M330c1p0r0z0t38")
        XCTAssertEqual(PinnedRowGeometry.plan(posterHeight: Self.medium,
                                              captionVisible: true,
                                              showsCTA: true,
                                              landscapeRows: false,
                                              mode: Self.noZoomHolding,
                                              titleHeight: Self.systemTitle).regimeKey,
                       "M330c1p0r0z1t38h1")
        // The ring is not part of the key, because it is not part of the plan.
        XCTAssertEqual(PinnedRowGeometry.regimeKey(posterHeight: Self.medium,
                                                   captionVisible: true,
                                                   showsCTA: true,
                                                   landscapeRows: false,
                                                   mode: .init(noZoom: false, accentRing: true),
                                                   titleHeight: Self.systemTitle),
                       "M330c1p0r0z0t38")
        // Two title metrics at the SAME (size × captions × hero form × row shape × mode) tuple must
        // not share a key either (rc10 Codex P2 fix 4) — a font switch (System ↔ Open Sans) must not
        // inherit the previous geometry's disarm/verify-failure state.
        XCTAssertNotEqual(PinnedRowGeometry.regimeKey(posterHeight: Self.medium,
                                                      captionVisible: true,
                                                      showsCTA: true,
                                                      landscapeRows: false,
                                                      mode: Self.noZoom,
                                                      titleHeight: Self.systemTitle),
                          PinnedRowGeometry.regimeKey(posterHeight: Self.medium,
                                                      captionVisible: true,
                                                      showsCTA: true,
                                                      landscapeRows: false,
                                                      mode: Self.noZoom,
                                                      titleHeight: Self.openSansTitle))
    }

    // MARK: - rc12: the No Zoom reach-hold A/B (BUG-87 follow-up)

    /// The headline claim: with the hold ON, No Zoom's Large carousel spends EXACTLY the zoom-on
    /// floor (86, not 66) — compare against
    /// `testLargeHideLabelsWithCarouselHeroSpendsBothReachesThenTheRemainder`'s plain-`noZoom`
    /// numbers (topReach 66, same compression/viewport because the carousel's 70pt cap binds
    /// either way — only `linkFrame`/`restRange` move, by exactly the 20pt the floor gained).
    func testNoZoomWithTheReachHoldTakesTheZoomOnFloor() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: true,
                                          landscapeRows: false,
                                          mode: Self.noZoomHolding,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.topReach, 86, accuracy: epsilon)
        XCTAssertEqual(plan.compression, 70, accuracy: 0.01)
        XCTAssertEqual(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: true), accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 525, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 513.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, 11.667, accuracy: 0.01)
        XCTAssertEqual(plan.regimeKey, "L403c0p0r0z1t38h1")
    }

    /// THE rationale pin for why the flag is routed through the reach floor and never through
    /// `focusLiftAllowance`: at the same Large carousel shape as the test above, the hold leaves
    /// `PinnedRowTitle.clearances`' `lift` at 0 (nothing scales in No Zoom, hold or not) and instead
    /// widens the band by raising `atRest`/`focused`/`focusedRaw` together — the exact opposite of
    /// charging a lift, which would have moved `focused` DOWN and left `bandLow` unchanged at −4.
    ///
    ///     hold ON   cardTopReach 86 → atRest = focused = focusedRaw = 24 → bandLow = −24
    ///     hold OFF  cardTopReach 66 → atRest = focused = focusedRaw = 4  → bandLow = −4
    ///
    /// Steven's sim reading (`margin=-22`) sits OUTSIDE the OFF band (−22 < −4, the belt's fade
    /// condition, matching the reported bounce) and INSIDE the ON band (−24 ≤ −22 ≤ 48, `bandHigh`
    /// unchanged because the carousel cap already binds `viewport` the same way in both regimes —
    /// see the test above).
    func testTheReachHoldWidensTheBandInsteadOfChargingLift() {
        let steadyMargin: CGFloat = -22
        let bandHigh: CGFloat = 48

        for (mode, expectedClearance, expectedBandLow, marginInBand) in [
            (Self.noZoomHolding, CGFloat(24), CGFloat(-24), true),
            (Self.noZoom, CGFloat(4), CGFloat(-4), false),
        ] {
            let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                              captionVisible: false,
                                              showsCTA: true,
                                              landscapeRows: false,
                                              mode: mode,
                                              titleHeight: Self.systemTitle)
            let clearance = PinnedRowTitle.clearances(titleHeight: Self.systemTitle,
                                                      cardTopReach: plan.topReach,
                                                      artworkHeight: Self.large,
                                                      captionVisible: false,
                                                      treatment: .cardTreatment,
                                                      mode: mode)
            let label = "hold=\(mode.reachHoldsLift)"
            XCTAssertEqual(clearance.lift, 0, accuracy: epsilon, label)
            XCTAssertEqual(clearance.atRest, expectedClearance, accuracy: epsilon, label)
            XCTAssertEqual(clearance.focused, expectedClearance, accuracy: epsilon, label)
            XCTAssertEqual(clearance.focusedRaw, expectedClearance, accuracy: epsilon, label)

            let bandLow = -clearance.focused
            XCTAssertEqual(bandLow, expectedBandLow, accuracy: epsilon, label)
            let inBand = steadyMargin >= bandLow && steadyMargin <= bandHigh
            XCTAssertEqual(inBand, marginInBand, label)
        }
    }

    /// The hold is inert with zoom on — `reachHoldsLiftEffective` requires `noZoom` too, so a
    /// `FocusModeFlags` that somehow carried both `reachHoldsLift: true` and `noZoom: false` (never
    /// produced by any shipping reader — both `@AppStorage` sites AND `PinnedRowTitle.current` gate
    /// on the same two keys) must plan identically to plain `zoomOn`.
    func testTheReachHoldIsInertWithZoomOn() {
        let zoomOnHolding = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false,
                                                          reachHoldsLift: true)
        XCTAssertFalse(zoomOnHolding.reachHoldsLiftEffective)
        for (name, height) in Self.allSizes {
            for captions in [false, true] {
                for cta in [false, true] {
                    let label = "\(name) captions=\(captions) showsCTA=\(cta)"
                    let plan = PinnedRowGeometry.plan(posterHeight: height, captionVisible: captions,
                                                      showsCTA: cta, landscapeRows: false,
                                                      mode: zoomOnHolding, titleHeight: Self.systemTitle)
                    let plainZoomOn = PinnedRowGeometry.plan(posterHeight: height, captionVisible: captions,
                                                             showsCTA: cta, landscapeRows: false,
                                                             mode: Self.zoomOn, titleHeight: Self.systemTitle)
                    XCTAssertEqual(plan, plainZoomOn, label)
                    XCTAssertEqual(plan.regimeKey, plainZoomOn.regimeKey, label)
                }
            }
        }
    }

    // MARK: - BUG-87/89 (rc11): the last-row link-frame floor

    /// BUG-87/89 (rc11, hardened by Codex r1 on rc11): the last row's label floor is the LARGER of the plan's own
    /// link frame and `viewport − Spacing.lg` — not `linkFrame` alone. The carousel case here is
    /// where the two coincide (its `restRange`, 12.67, is under `Spacing.lg`), so a uniform row
    /// needs no extra and a short-tile collection row gets exactly the difference, unchanged from
    /// rc11. The panel case below is where they DON'T coincide (`restRange` 32 > `Spacing.lg`), which
    /// is exactly the shape Finding 1 closes: `linkFrame` alone would have permitted a rest above the
    /// band.
    func testLastRowLinkFrameFloorTakesTheLargerOfLinkFrameAndTheBandCeiling() {
        let carousel = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: false,
                                              showsCTA: true, landscapeRows: false,
                                              mode: Self.zoomOn, titleHeight: 37)
        XCTAssertTrue(carousel.fits)
        // `linkFrame` (512.33) already exceeds `viewport − lg` (525 − 24 = 501): the `max` picks
        // `linkFrame`, exactly rc11's behavior.
        XCTAssertGreaterThan(carousel.linkFrame, carousel.viewport - Theme.Spacing.lg)
        XCTAssertEqual(PinnedRowGeometry.lastRowLinkFrameFloor(plan: carousel), carousel.linkFrame,
                       accuracy: 0.01)
        // A uniform poster row's own label IS the plan's link frame — nothing to add.
        XCTAssertEqual(PinnedRowGeometry.lastRowBottomReachExtra(plan: carousel, labelFrame: carousel.linkFrame),
                       0, accuracy: 0.01)
        // The tester's last row: hidden-title SQUARE folder tiles, whose artwork is `style.width`
        // (FolderTile.artworkHeight), not `style.height`.
        let squareTile = Theme.Size.posterWidth / 126.0 * 154.0          // 268.88…
        let carouselTileLabel = carousel.topReach + squareTile + carousel.bottomReach   // 377.89
        XCTAssertEqual(PinnedRowGeometry.lastRowBottomReachExtra(plan: carousel, labelFrame: carouselTileLabel),
                       134.44, accuracy: 0.5)
        // The point of the number: the shaped label leaves the engine only the rest interval every
        // other row in this regime already settles inside.
        let shelfTopPad = Theme.Spacing.lg
        let deepestRowTop = carousel.viewport - shelfTopPad - carousel.linkFrame
        let deepestMargin = deepestRowTop + Theme.Size.heroPinnedRowTitleInset
        XCTAssertLessThanOrEqual(deepestMargin, Theme.Size.heroPinnedRowTitleInset)   // ≤ bandHigh
        XCTAssertGreaterThanOrEqual(deepestMargin, -4)                                // ≥ bandLow

        // The panel case Finding 1 is about: hero-OFF (FEAT-15, showsCTA: false) at Large, systemTitle
        // (38 ⇒ topReachFloor 86, the canonical zoom-on number). Its `restRange` (32) is bigger than
        // `Spacing.lg` (24), so the ceiling — not `linkFrame` — is the binding term.
        let panel = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: false,
                                           showsCTA: false, landscapeRows: false,
                                           mode: Self.zoomOn, titleHeight: Self.systemTitle)
        XCTAssertTrue(panel.fits)
        XCTAssertGreaterThan(panel.restRange, Theme.Spacing.lg)
        let panelFloor = PinnedRowGeometry.lastRowLinkFrameFloor(plan: panel)
        // floor == viewport − lg (the ceiling), strictly greater than linkFrame alone.
        XCTAssertEqual(panelFloor, panel.viewport - Theme.Spacing.lg, accuracy: 0.01)
        XCTAssertGreaterThan(panelFloor, panel.linkFrame)
        // …and by construction that ceiling makes the margin range exactly [24, 48]: the band's full
        // width, no more.
        XCTAssertEqual(Theme.Spacing.lg + panel.viewport - panelFloor, 48, accuracy: 0.01)
        // The frame still fits: floor + lg <= viewport.
        XCTAssertLessThanOrEqual(panelFloor + Theme.Spacing.lg, panel.viewport + 0.01)
        // Same square-tile arithmetic as the carousel case above, now against the ceiling-derived
        // floor rather than `linkFrame` — the number is bigger because the floor is.
        let panelTileLabel = panel.topReach + squareTile + panel.bottomReach
        let panelExtra = PinnedRowGeometry.lastRowBottomReachExtra(plan: panel, labelFrame: panelTileLabel)
        XCTAssertEqual(panelExtra, panelFloor - panelTileLabel, accuracy: 0.01)
        XCTAssertEqual(panelExtra, 142.44, accuracy: 0.5)
    }

    /// Finding 1 (P2): the floor confines EVERY fitting regime to the band `[24, 48]` in margin
    /// terms — not just the two cases spelled out above. Sweeps every Poster Size the app can
    /// actually produce, both caption states, both hero forms, both zoom modes and both title
    /// metrics (System vs FEAT-31's Open Sans) — 4 × 2 × 2 × 2 × 2 = 64 regimes.
    func testLastRowFloorConfinesEveryFittingRegimeToTheBand() {
        for (name, height) in Self.allSizes {
            for captionVisible in [false, true] {
                for showsCTA in [false, true] {
                    for mode in [Self.zoomOn, Self.noZoom] {
                        for titleHeight in [Self.systemTitle, Self.openSansTitle] {
                            let label = "\(name) captions=\(captionVisible) showsCTA=\(showsCTA)"
                                + " noZoom=\(mode.noZoom) title=\(titleHeight)"
                            let plan = PinnedRowGeometry.plan(posterHeight: height,
                                                              captionVisible: captionVisible,
                                                              showsCTA: showsCTA,
                                                              landscapeRows: false,
                                                              mode: mode,
                                                              titleHeight: titleHeight)
                            let floor = PinnedRowGeometry.lastRowLinkFrameFloor(plan: plan)
                            guard plan.fits else {
                                XCTAssertEqual(floor, 0, accuracy: epsilon, label)
                                continue
                            }
                            // The floored label must fit the viewport (floor ≤ viewport); it may exceed
                            // viewport − shelfTopPad when the regime's own link frame already does (Small + captions:
                            // 450.5 in 455), in which case the engine's tolerated interval is [−24, viewport − 24 − floor],
                            // non-empty as long as floor ≤ viewport, and its margin ceiling 24 + viewport − floor is
                            // still checked below.
                            XCTAssertLessThanOrEqual(floor, plan.viewport + 0.01, label)
                            // The max margin the floor permits never exceeds the band's own upper
                            // edge (48) — the whole point of taking the ceiling over `linkFrame`
                            // alone.
                            XCTAssertLessThanOrEqual(Theme.Spacing.lg + plan.viewport - floor,
                                                     Theme.Size.heroPinnedRowTitleInset + 0.01, label)
                            // The min margin (24, i.e. rowTop == −shelfTopPad) is trivially inside
                            // the band's lower edge with the corrector's ±2 tolerance to spare.
                            XCTAssertGreaterThanOrEqual(Theme.Spacing.lg, -4, label)
                        }
                    }
                }
            }
        }
    }

    /// The floor never manufactures an over-tall frame: `!fits` regimes opt out.
    func testLastRowLinkFrameFloorIsZeroWhenTheRegimeDoesNotFit() {
        // Large + captions + carousel is the documented unsatisfiable regime (fits == false) — see
        // `testLargeWithCaptionsAndCarouselHeroFallsBackToTodaysNumbers` above (No Zoom); the header's
        // trade note documents the fallback as mode-independent, so zoom-on is unsatisfiable too.
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: true,
                                          showsCTA: true, landscapeRows: false,
                                          mode: Self.zoomOn, titleHeight: 38)
        XCTAssertFalse(plan.fits)
        XCTAssertEqual(PinnedRowGeometry.lastRowLinkFrameFloor(plan: plan), 0, accuracy: epsilon)
    }

    // MARK: - BUG-87/89 (rc11, governance-checked by Codex r2 on rc11): the last-row exemption's own predicate

    /// `PinnedRowSettle.lastRowExemptionApplies` (Codex r2 P2) — a floor that EXISTS is not enough;
    /// it must also GOVERN the focused label, i.e. the label's natural lockup extent must not exceed
    /// the floored frame. Three shapes:
    ///
    ///  (a) no floor at all (every non-last row, and a last row outside pinned mode) — never exempt.
    ///  (b) a uniform SQUARE folder tile inside the carousel regime whose floor is its own
    ///      `linkFrame` — the floor is sized for exactly this tile's shape, so it governs.
    ///  (c) the rc11 Codex-r2 finding: a PORTRAIT folder inside a LANDSCAPE-ROWS regime. The row's floor
    ///      is calibrated to the regime's own (landscape) `linkFrame`, but this doc's own note on
    ///      `PinnedRowGeometry.plan(landscapeRows:)` says a portrait folder in that mode still
    ///      presents `posterHeight`-tall tiles — taller than the floor was ever sized for — so the
    ///      floor does not govern and the exemption must not fire.
    func testLastRowExemptionAppliesOnlyWhenTheFloorGovernsTheLabel() {
        // (a) No floor published (0 — the field's default, and every row but Home's last while
        // pinned mode is even active) — never exempt, whatever the label's own extent is.
        XCTAssertFalse(PinnedRowSettle.lastRowExemptionApplies(lockupExtent: 100, linkFrameFloor: 0))

        // (b) The carousel regime from `testLastRowLinkFrameFloorTakesTheLargerOfLinkFrameAndTheBandCeiling`
        // above: its floor IS `plan.linkFrame` (512.33), sized for this same Large artwork. A
        // hidden-title SQUARE folder tile's own lockup extent — `lg + topReach + squareTile`, the
        // same `Measurement.lockupExtent`/`CollectionRowView.focusedTileLockupExtent` shape, with no
        // caption term because the title is hidden — sits well under it, so the floor governs.
        let carousel = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: false,
                                              showsCTA: true, landscapeRows: false,
                                              mode: Self.zoomOn, titleHeight: 37)
        let carouselFloor = PinnedRowGeometry.lastRowLinkFrameFloor(plan: carousel)
        let squareTile = Theme.Size.posterWidth / 126.0 * 154.0   // 268.88…, FolderTile.artworkHeight
        let squareLockupExtent = Theme.Spacing.lg + carousel.topReach + squareTile
        XCTAssertTrue(PinnedRowSettle.lastRowExemptionApplies(lockupExtent: squareLockupExtent,
                                                              linkFrameFloor: carouselFloor))

        // (c) The rc11 Codex-r2 regression: Large + Landscape Rows + No Zoom, hero-off panel shape
        // (`showsCTA: false`), captions off. `landscapeRows: true` sizes the floor off the 203pt
        // landscape artwork (floor 431 — `max(linkFrame 335, viewport-lg 431)`), but a collection
        // row's folder that keeps its PORTRAIT shape (`FolderTile.artworkHeight`, per `plan`'s own
        // doc comment on `landscapeRows`) still stands `posterHeight` (403.33) tall. That lockup
        // extent — `lg + topReach + posterHeight`, again no caption term (hidden title) — overshoots
        // the floor by far more than rounding, so the exemption must not apply.
        let landscapeRowsPlan = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: false,
                                                       showsCTA: false, landscapeRows: true,
                                                       mode: Self.noZoom, titleHeight: Self.systemTitle)
        let landscapeFloor = PinnedRowGeometry.lastRowLinkFrameFloor(plan: landscapeRowsPlan)
        let portraitFolderLockupExtent = Theme.Spacing.lg + landscapeRowsPlan.topReach + Self.large
        XCTAssertFalse(PinnedRowSettle.lastRowExemptionApplies(lockupExtent: portraitFolderLockupExtent,
                                                               linkFrameFloor: landscapeFloor))
        // Sanity-check the finding's own numbers rather than trusting the predicate alone: the
        // portrait tile's lockup extent clears the floor by (well) more than a rounding slop.
        XCTAssertGreaterThan(portraitFolderLockupExtent, Theme.Spacing.lg + landscapeFloor + 0.5)
    }

    private func planHeight(for label: String) -> CGFloat {
        if label.hasPrefix("Small") { return Self.small }
        // FEAT-39: "Medium+" must be checked before the "Medium" prefix it itself starts with.
        if label.hasPrefix("Medium+") { return Self.mediumPlus }
        if label.hasPrefix("Medium") { return Self.medium }
        return Self.large
    }
}

/// rc2 (2026-09-06) — `PinnedRowGeometry.HeroSlotGive`, the split of one `compression` across the
/// pinned hero's two elastic slots. Extracted out of `HomeHeroForeground` so this arithmetic is
/// asserted rather than reasoned about; the view's `synopsisSlotGive` / `logoSlotGive` are thin
/// wrappers over it.
///
/// The tester's objection was about LINES OF DESCRIPTION, and the line count is a floor division.
///
/// 2026-09-10: `HomeHeroForeground.synopsisLineLimit` no longer assumes a 36pt line — it measures
/// `Theme.Font.bodyLineHeight` (the actual `UIFont` line height of the resolved body face/size),
/// with a 1pt tolerance so a slot that is short of a whole line by less than that still gets it
/// (the text `Text` sits in a fixed-height frame, so a small overhang is clipped, never seen). The
/// helper below mirrors that exactly. So the tests assert the slot height AND the line count it
/// implies — the second is the thing the tester actually sees.
final class PinnedRowGeometryHeroSlotGiveTests: XCTestCase {

    private let epsilon: CGFloat = 0.001

    // MARK: - Body line metrics (Codex P3 fix 4)
    //
    // `lineLimit(slotHeight:)` used to read the live `Theme.Font.bodyLineHeight`, which follows
    // whatever font family the host has applied (System by default, Open Sans under FEAT-31's
    // `-ui_font openSans` launch argument, persisted across runs). A suite that asserts a fixed
    // line count has to pin the metric it measures against, exactly like `systemTitle`/
    // `openSansTitle` above pin the title metric — so every caller below passes an EXPLICIT
    // `lineHeight` instead of letting the helper read the live value.

    /// System body line height (`UIFont.preferredFont(forTextStyle: .body).lineHeight`) — the
    /// metric `HomeHeroForeground.synopsisLineLimit` measures when the host renders the System
    /// font, and the one every "3 lines" expectation in this file was written against.
    private static let systemBodyLine = UIFont.preferredFont(forTextStyle: .body).lineHeight

    /// FEAT-31's Open Sans body line height at the same text style, from the bundled face itself
    /// rather than a derived constant — the tester's configuration, where the SAME slot holds one
    /// fewer line than under the System font.
    private static func openSansBodyLine() -> CGFloat? {
        UIFont(name: "OpenSans-Regular", size: Theme.Font.baseSize(for: .body))?.lineHeight
    }

    /// Mirror of `HomeHeroForeground.synopsisSlotHeight`'s compact branch.
    private func slotHeight(showsCTA: Bool, synopsisGive: CGFloat) -> CGFloat {
        let slot = showsCTA ? Theme.Size.heroSynopsisSlotHeightPinned
                            : Theme.Size.heroSynopsisSlotHeightPinnedPanel
        return slot - synopsisGive
    }

    /// Mirror of `HomeHeroForeground.synopsisLineLimit`'s compact branch — measured, not assumed.
    /// `lineHeight` is an explicit parameter, not a live read, so a caller controls which font
    /// metric its expectation is arithmetic against (Codex P3 fix 4).
    private func lineLimit(slotHeight: CGFloat, lineHeight: CGFloat) -> Int {
        let lineTolerance: CGFloat = 1
        guard lineHeight > 0 else { return 1 }
        return max(1, Int(((slotHeight + lineTolerance) / lineHeight).rounded(.down)))
    }

    // MARK: - rc12: fixtures for the moved reach-hold synopsis tests below (private in
    // `PinnedRowGeometryTests`, so restated here rather than reached across the type boundary).

    private static func posterHeight(dp: CGFloat) -> CGFloat {
        dp * (Theme.Size.posterWidth / 126.0) * 1.5
    }
    /// FEAT-39: 134dp, above the 335pt hero-compression gate, so it takes the Large dial.
    private static let mediumPlus = posterHeight(dp: 134) // 350.95…
    private static let large = posterHeight(dp: 154)    // 403.33…

    private static let noZoom = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false)
    private static let zoomOn = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false)
    /// rc12 BUG-87 follow-up: No Zoom with the default-OFF reach-hold A/B switched ON.
    private static let noZoomHolding = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false,
                                                                     reachHoldsLift: true)

    /// The SYSTEM font's number, which every expectation in this file was written against.
    private static let systemTitle = PinnedRowGeometry.measuredTitleHeight   // 38

    // MARK: - rc12: the No Zoom reach-hold A/B synopsis cost (BUG-87 follow-up)

    /// What turning the hold on costs: the Large hero-off panel's synopsis drops from 3 lines to 2,
    /// the SAME cost zoom-on already pays (`testPanelAtRc10NoZoomCompressionStillHasThreeLinesUnderTheSystemFont`
    /// is the OFF twin at compression 70.333 → 3 lines). The 30–36pt guard pins the System body
    /// metric's plausible range so a future font change fails loudly here instead of silently
    /// flipping which side of the 36pt-per-line assumption this shape lands on.
    func testNoZoomReachHoldCostsTheHeroOffPanelOneSynopsisLine() {
        XCTAssertGreaterThan(Self.systemBodyLine, 30)
        XCTAssertLessThan(Self.systemBodyLine, 36)

        let holding = PinnedRowGeometry.plan(posterHeight: Self.large,
                                             captionVisible: false,
                                             showsCTA: false,
                                             landscapeRows: false,
                                             mode: Self.noZoomHolding,
                                             titleHeight: Self.systemTitle)
        XCTAssertEqual(holding.compression, 90.333, accuracy: 0.01)
        let holdingSplit = PinnedRowGeometry.HeroSlotGive.split(compression: holding.compression,
                                                                showsCTA: false, folderHero: false)
        let holdingSlot = slotHeight(showsCTA: false, synopsisGive: holdingSplit.synopsis)
        XCTAssertEqual(holdingSlot, 87.667, accuracy: 0.01)
        XCTAssertEqual(lineLimit(slotHeight: holdingSlot, lineHeight: Self.systemBodyLine), 2)

        let off = PinnedRowGeometry.plan(posterHeight: Self.large,
                                         captionVisible: false,
                                         showsCTA: false,
                                         landscapeRows: false,
                                         mode: Self.noZoom,
                                         titleHeight: Self.systemTitle)
        XCTAssertEqual(off.compression, 70.333, accuracy: 0.01)
        let offSplit = PinnedRowGeometry.HeroSlotGive.split(compression: off.compression,
                                                            showsCTA: false, folderHero: false)
        let offSlot = slotHeight(showsCTA: false, synopsisGive: offSplit.synopsis)
        XCTAssertEqual(offSlot, 107.667, accuracy: 0.01)
        XCTAssertEqual(lineLimit(slotHeight: offSlot, lineHeight: Self.systemBodyLine), 3)
    }

    /// Medium+ is unaffected by the hold: it already takes the Large dial's floor with zoom on
    /// (`testMediumPlusTakesTheLargeDialWithThreeSystemLines`), and the hold converges No Zoom to
    /// EXACTLY that same floor/compression — not merely to the same line count. The panel's synopsis
    /// stays at 3 lines under the System font (`testMediumPlusPanelKeepsThreeSynopsisLines` already
    /// covers that compression value), so there is nothing new to cost here.
    func testMediumPlusKeepsThreeSynopsisLinesWithTheReachHold() {
        let holding = PinnedRowGeometry.plan(posterHeight: Self.mediumPlus, captionVisible: false,
                                             showsCTA: false, landscapeRows: false,
                                             mode: Self.noZoomHolding, titleHeight: 38)
        XCTAssertEqual(holding.topReach, 86, accuracy: epsilon)
        XCTAssertEqual(holding.compression, 37.952, accuracy: 0.01)

        let zoomOn = PinnedRowGeometry.plan(posterHeight: Self.mediumPlus, captionVisible: false,
                                            showsCTA: false, landscapeRows: false,
                                            mode: Self.zoomOn, titleHeight: 38)
        XCTAssertEqual(holding.compression, zoomOn.compression, accuracy: epsilon)
        XCTAssertEqual(holding.regimeKey, zoomOn.regimeKey.replacingOccurrences(of: "z0", with: "z1") + "h1")

        let split = PinnedRowGeometry.HeroSlotGive.split(compression: holding.compression,
                                                         showsCTA: false, folderHero: false)
        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemBodyLine), 3)
    }

    // MARK: - The three tiers

    /// The whole point of the rc2 change, at the tester's shape.
    ///
    ///     compression 68.33  (PinnedRowGeometry.plan, Large + Hide Labels + panel)
    ///     tier 1  synopsis   min(68.33, heroSynopsisSlotPinnedGive 36)          = 36
    ///     tier 2  logo       min(32.33, heroLogoSlotPinnedGive 32)              = 32
    ///     tier 3  synopsis   max(68.33 − 36 − 32 − slack 2, 0) = 0              = 0
    ///     ⇒ synopsis slot 144 − 36 = 108   ⇒ floor(108/36) = 3 lines
    ///
    /// The 0.33 that tiers 1+2 do not cover is the hero frame's own `heroPinnedFrameSlack` — 2pt of
    /// frame that holds no content — which is why tier 3 stays shut. Spending it would take the
    /// slot to 107.67 and `floor(107.67/36)` is 2, i.e. the regression this test exists to catch.
    func testPanelAtStevensCompressionKeepsThreeSynopsisLines() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 68.333,
                                                         showsCTA: false,
                                                         folderHero: false)
        XCTAssertEqual(split.synopsis, Theme.Size.heroSynopsisSlotPinnedGive, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 36, accuracy: epsilon)
        XCTAssertEqual(split.logo, Theme.Size.heroLogoSlotPinnedGive, accuracy: epsilon)
        XCTAssertEqual(split.logo, 32, accuracy: epsilon)

        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 108, accuracy: epsilon)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemBodyLine), 3)

        // The logo slot lands exactly on its floor, as it did in Wave 10.
        XCTAssertEqual(Theme.Size.heroLogoSlotHeightPinned - split.logo,
                       Theme.Size.heroLogoSlotHeightPinnedFloor, accuracy: epsilon)
    }

    /// FEAT-39: Medium+'s own compression at the tester's zoom-on panel shape
    /// (`PinnedRowGeometryTests.testMediumPlusTakesTheLargeDialWithThreeSystemLines`, 37.952 — the
    /// spec's hand-rounded "38" is close enough that either number lands in the SAME tier). 37.952
    /// is comfortably inside tier 1 alone (< the 36 cap plus the logo's 32 give), so the synopsis
    /// give is capped at exactly 36, same as Large's Stevens shape, and the slot nets to the SAME
    /// 108pt → 3 lines under the System font, 2 under Open Sans.
    func testMediumPlusPanelKeepsThreeSynopsisLines() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 37.952,
                                                         showsCTA: false,
                                                         folderHero: false)
        XCTAssertEqual(split.synopsis, Theme.Size.heroSynopsisSlotPinnedGive, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 36, accuracy: epsilon)

        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 108, accuracy: epsilon)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemBodyLine), 3)
        if let openSansLine = Self.openSansBodyLine() {
            XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: openSansLine), 2)
        }
    }

    /// rc10: the No-Zoom Large panel lands at compression 70.33 (the lift-aware floor), which the
    /// tier-3 gate turns into a 107.67 pt slot — a whole visible line short under the OLD 36 pt
    /// assumption, three lines under the measured system line height.
    func testPanelAtRc10NoZoomCompressionStillHasThreeLinesUnderTheSystemFont() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 70.333, showsCTA: false, folderHero: false)
        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 107.667, accuracy: 0.01)
        // System body line height on tvOS is ~35 pt; assert the measurement, not a literal.
        XCTAssertLessThan(Self.systemBodyLine, 36)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemBodyLine), 3)
    }

    /// The tester's case: Open Sans body renders taller than the 36 pt the slot math assumed, so
    /// the SAME 108 pt slot holds two lines, not three. This is the measurement, not a fix.
    func testOpenSansBodyLineIsTallerThanTheAssumedSlotLine() throws {
        guard let openSansLine = Self.openSansBodyLine() else {
            throw XCTSkip("Open Sans is not bundled in the unit-test host")
        }
        XCTAssertGreaterThan(openSansLine, 36)
        XCTAssertEqual(lineLimit(slotHeight: 108, lineHeight: openSansLine), 2)
    }

    /// Tier 3 opens only past tiers 1+2 plus the frame slack, and then it is the panel's own extra.
    ///
    ///     compression 111.83  (Large + captions + panel)
    ///     tier 1  36, tier 2  32, tier 3  min(111.83 − 68 − 2, 72) = 41.83
    ///     ⇒ synopsis give 77.83, slot 144 − 77.83 = 66.17  ⇒ 1 line
    ///
    /// One line is what this shape produced before the reordering too (its old compression, 142,
    /// drained the slot to 36), so nothing regresses for it — the panel simply cannot show three
    /// lines and absorb a 43.5pt caption row at Large.
    func testPanelPastTheSlackOpensTheThirdTier() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 111.833,
                                                         showsCTA: false,
                                                         folderHero: false)
        XCTAssertEqual(split.logo, Theme.Size.heroLogoSlotPinnedGive, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 77.833, accuracy: 0.01)
        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 66.167, accuracy: 0.01)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemBodyLine), 1)
    }

    /// Tier 1 alone, below the logo's turn: a small compression comes entirely out of the synopsis
    /// in BOTH forms, exactly as it always has.
    func testSmallCompressionsSpendOnlyTheSharedSynopsisGive() {
        for showsCTA in [false, true] {
            let split = PinnedRowGeometry.HeroSlotGive.split(compression: 20,
                                                             showsCTA: showsCTA,
                                                             folderHero: false)
            XCTAssertEqual(split.synopsis, 20, accuracy: epsilon, "showsCTA=\(showsCTA)")
            XCTAssertEqual(split.logo, 0, accuracy: epsilon, "showsCTA=\(showsCTA)")
        }
    }

    /// Zero in, zero out — the non-pinned call sites (`compact == false`) always pass 0.
    func testZeroCompressionSpendsNothing() {
        for showsCTA in [false, true] {
            for folder in [false, true] {
                let split = PinnedRowGeometry.HeroSlotGive.split(compression: 0,
                                                                 showsCTA: showsCTA,
                                                                 folderHero: folder)
                XCTAssertEqual(split.total, 0, accuracy: epsilon)
            }
        }
    }

    // MARK: - What must not have changed

    /// The CAROUSEL form is bit-identical to the shipped two-step split at every compression it can
    /// be handed: its tier-3 ceiling is `72 − 36 − 36 == 0`, so the third tier can never open.
    func testCarouselSplitIsUnchangedAcrossItsWholeRange() {
        var c: CGFloat = 0
        while c <= PinnedRowGeometry.elasticGive(showsCTA: true) + 0.5 {
            let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                             showsCTA: true,
                                                             folderHero: false)
            // The pre-rc2 formula, inlined.
            let legacySynopsis = c > 0
                ? min(c, Theme.Size.heroSynopsisSlotHeightPinned - Theme.Size.heroSynopsisSlotHeightPinnedFloor)
                : 0
            let legacyLogo = c > 0
                ? min(max(c - legacySynopsis, 0), Theme.Size.heroLogoSlotPinnedGive)
                : 0
            XCTAssertEqual(split.synopsis, legacySynopsis, accuracy: epsilon, "compression=\(c)")
            XCTAssertEqual(split.logo, legacyLogo, accuracy: epsilon, "compression=\(c)")
            c += 0.25
        }
    }

    /// FEAT-29's collection-folder rule is untouched: the whole synopsis slot is give (a folder
    /// preview carries no description, so the slot has a genuine 0 floor) and the logo takes an
    /// unbounded remainder. At Large + panel that is synopsis 68.33, logo 0 — the wordmark keeps
    /// its full 110pt slot, which is the regression FEAT-29 closed.
    func testFolderHeroSplitIsUnchanged() {
        for showsCTA in [false, true] {
            let slot = showsCTA ? Theme.Size.heroSynopsisSlotHeightPinned
                                : Theme.Size.heroSynopsisSlotHeightPinnedPanel
            var c: CGFloat = 0
            while c <= PinnedRowGeometry.elasticGive(showsCTA: showsCTA) + 0.5 {
                let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                                 showsCTA: showsCTA,
                                                                 folderHero: true)
                let legacySynopsis = c > 0 ? min(c, slot) : 0
                XCTAssertEqual(split.synopsis, legacySynopsis, accuracy: epsilon,
                               "showsCTA=\(showsCTA) compression=\(c)")
                XCTAssertEqual(split.logo, max(c - legacySynopsis, 0), accuracy: epsilon,
                               "showsCTA=\(showsCTA) compression=\(c)")
                c += 0.25
            }
        }
    }

    // MARK: - Invariants

    /// Nothing hard-clips. The hero's FRAME shrinks by `compression`; its CONTENT shrinks by
    /// `split.total`, and the frame carries `heroPinnedFrameSlack` (2pt) that holds no content — so
    /// the content must give up at least `compression − slack` everywhere up to that form's cap, or
    /// the slots overflow into the rows below. This is the property
    /// `Theme.Size.heroPinnedCompressionCap` exists to protect.
    func testContentGiveAlwaysCoversTheFrameShrinkMinusItsSlack() {
        for showsCTA in [false, true] {
            for folder in [false, true] {
                var c: CGFloat = 0
                while c <= PinnedRowGeometry.elasticGive(showsCTA: showsCTA) + epsilon {
                    let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                                     showsCTA: showsCTA,
                                                                     folderHero: folder)
                    XCTAssertGreaterThanOrEqual(split.total + epsilon,
                                                c - Theme.Size.heroPinnedFrameSlack,
                                                "showsCTA=\(showsCTA) folder=\(folder) compression=\(c)")
                    c += 0.25
                }
            }
        }
    }

    /// Both slot floors hold for a TITLE hero at every compression up to the cap: the logo never
    /// goes below `heroLogoSlotHeightPinnedFloor` (78) and the synopsis never below
    /// `heroSynopsisSlotHeightPinnedFloor` (36), which is one readable line.
    func testTitleHeroSlotFloorsHold() {
        for showsCTA in [false, true] {
            var c: CGFloat = 0
            while c <= PinnedRowGeometry.elasticGive(showsCTA: showsCTA) + epsilon {
                let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                                 showsCTA: showsCTA,
                                                                 folderHero: false)
                let label = "showsCTA=\(showsCTA) compression=\(c)"
                XCTAssertGreaterThanOrEqual(Theme.Size.heroLogoSlotHeightPinned - split.logo + epsilon,
                                            Theme.Size.heroLogoSlotHeightPinnedFloor, label)
                XCTAssertGreaterThanOrEqual(slotHeight(showsCTA: showsCTA, synopsisGive: split.synopsis) + epsilon,
                                            Theme.Size.heroSynopsisSlotHeightPinnedFloor, label)
                XCTAssertGreaterThanOrEqual(split.synopsis, 0, label)
                XCTAssertGreaterThanOrEqual(split.logo, 0, label)
                c += 0.25
            }
        }
    }

    /// Monotone in the compression: a bigger frame shrink never gives a slot MORE room back. A
    /// non-monotone split would make the synopsis line count jump around as the synced Poster Size
    /// changes, which is the class of bug the tiers could plausibly have introduced.
    func testSplitIsMonotoneInCompression() {
        for showsCTA in [false, true] {
            for folder in [false, true] {
                var c: CGFloat = 0
                var previous = PinnedRowGeometry.HeroSlotGive.split(compression: 0,
                                                                    showsCTA: showsCTA,
                                                                    folderHero: folder)
                while c <= PinnedRowGeometry.elasticGive(showsCTA: showsCTA) + epsilon {
                    let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                                     showsCTA: showsCTA,
                                                                     folderHero: folder)
                    let label = "showsCTA=\(showsCTA) folder=\(folder) compression=\(c)"
                    XCTAssertGreaterThanOrEqual(split.synopsis + epsilon, previous.synopsis, label)
                    XCTAssertGreaterThanOrEqual(split.logo + epsilon, previous.logo, label)
                    previous = split
                    c += 0.25
                }
            }
        }
    }
}
