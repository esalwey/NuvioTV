import SwiftUI
import UIKit
import SharedCore

/// Pinned-hero card reach (UX-7 extension, device round 4 of the pinned pass, 2026-08-03).
///
/// On tvOS there is no free momentum scrolling — Siri Remote swipes drive the FOCUS engine and
/// every vertical rest comes from its scroll-to-reveal, which aligns to the focused CARD's
/// frame. Real hardware rests that reveal systematically short (the BUG-30 residual class), so
/// in Home's pinned-hero mode — where the rows viewport hard-clips at the hero boundary — any
/// content ABOVE the focused card's frame (the row's section title, the top band) can end up
/// cut. Rounds 2–3 proved padding OUTSIDE the card frame can never fix this: the reveal simply
/// doesn't include it.
///
/// The fix: rows extend each focusable card's frame UPWARD by this many transparent points
/// (inside the button label, compensated by the row's paddings so nothing moves visually). The
/// reveal target then physically includes the title band — the engine cannot rest a row with
/// its title or art cut. 0 (the default) everywhere except Home's pinned mode, where HomeView
/// sets `Theme.Size.heroPinnedRowTopPad`; at 0 every consuming expression collapses to the
/// original layout, keeping classic byte-identical.
private struct RowCardTopReachKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Downward twin of `rowCardTopReach` (device round 5): scrolling DOWN, the reveal rests short
/// in the mirror direction — the focused card's frame BOTTOM (caption included) lands below the
/// fold and the art's bottom edge is cut. Extending the frame downward by this many transparent
/// points absorbs that shortfall the same way the top reach absorbs the upward one.
private struct RowCardBottomReachKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// BUG-87/89 (rc11): a MINIMUM height for the focusable card label, in points, applied inside the
/// label after the two reaches. 0 (the default) everywhere except Home's LAST pinned row.
///
/// tvOS scrolls to reveal the focused LABEL frame and nothing else, so the set of rests the engine
/// will tolerate for a row is exactly
///
///     rowTop ∈ [−shelfTopPad, viewport − shelfTopPad − labelFrameHeight]
///
/// — a SHORT label (the mixed-shape collection row's square/landscape folder tiles, whose artwork is
/// `style.width`, not `style.height`) widens that set by the difference and lets a Down step park the
/// row ~134pt deep with its title far below the band. No correction can hold: the deep rest is legal,
/// so the engine re-reveals straight back to it (`pullback=1`, three rounds, `pullBackDisarmed`).
/// Floor the label at `PinnedRowGeometry.lastRowLinkFrameFloor(plan:)` — the LARGER of the regime's
/// own `Plan.linkFrame` and `viewport − Theme.Spacing.lg` — and the last row's rest interval is
/// confined to `[24, 48]` in margin terms: the band's full width and no more, which is inside the
/// band by construction wherever `plan.fits`. `linkFrame` alone is NOT enough (rc11 → rc11 (Codex r1) fix): a
/// regime whose own `restRange` runs past 24 (the hero-OFF panel at Large/Medium+ carries 32; Small
/// without captions carries 72) would otherwise let the last row rest with margin up to `24 +
/// restRange`, past the band's 48 upper edge.
///
/// Transparent padding below the caption: it changes no artwork, no caption, no ring, and no
/// `focusedLockupExtent` (CollectionsUI) — only the rectangle the focus engine reveals.
private struct RowCardLinkFrameFloorKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Home's "Trailer Location: Hero" mode: the focused title's trailer plays in the PINNED HERO
/// backdrop (which already follows focus), so the focused poster must NOT morph into an inline
/// trailer tile — two surfaces cannot share the single player slot, and the hero is the one the
/// user asked for. Set by `HomeView.rowsScroll` from `heroFocusTrailerMode` — settings plus
/// hero-surface existence, which moves at most once per Home lifetime (see that property's doc
/// for why anything churnier would be the BUG-19 identity class).
///
/// Defaults to false so Search — and any other `CatalogRowView` host — keeps the inline morph
/// exactly as it is today, without opting in to anything.
private struct TrailerPlaysInHeroKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rowCardTopReach: CGFloat {
        get { self[RowCardTopReachKey.self] }
        set { self[RowCardTopReachKey.self] = newValue }
    }
    var rowCardBottomReach: CGFloat {
        get { self[RowCardBottomReachKey.self] }
        set { self[RowCardBottomReachKey.self] = newValue }
    }
    var rowCardLinkFrameFloor: CGFloat {
        get { self[RowCardLinkFrameFloorKey.self] }
        set { self[RowCardLinkFrameFloorKey.self] = newValue }
    }
    var trailerPlaysInHero: Bool {
        get { self[TrailerPlaysInHeroKey.self] }
        set { self[TrailerPlaysInHeroKey.self] = newValue }
    }
}

// MARK: - Home geometry probes (BUG-30 / BUG-37)

/// Runtime knob shared by every Home geometry probe — all of them log with the `[HomeScrollProbe]`
/// prefix, so one device walk produces one greppable stream:
///
///     defaults write com.nuvio.media.NuvioTV debug.homeScrollProbe -bool YES
///
/// Read ONCE at launch: a disabled probe costs a single Bool for the whole session, because every
/// probe is a modifier that simply isn't attached when this is false (see `pinnedRowTitleTracking`
/// here and `HomeScrollProbeModifier` in HomeView).
///
/// Deliberately NOT `#if DEBUG`, matching the existing BUG-30 probe it now backs: there is no
/// automated input path to the physical Apple TV, so every device pass is a manual walk that may
/// well be a release-configuration sideload, and the console is the only diagnostic that comes
/// back (same precedent as `ProfilesViewModel.select(_:)`).
enum HomeGeometryProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.homeScrollProbe")
}

// MARK: - Pinned row title tracking (BUG-37)

/// Keeps a PINNED row's overlaid section title inside the rows viewport at every rest position the
/// DEVICE produces, not just the exact ones the simulator produces.
///
/// Why round 8's compromise wasn't enough. The title is overlaid `heroPinnedRowTitleInset` (48)
/// below the SHELF's top; the focusable card frame the engine's scroll-to-reveal aligns starts
/// `Spacing.lg` (24) below that same shelf top, inside the shelf's own padding. So the static
/// margin between "the engine rested the card frame's top at the viewport edge" and "the title's
/// top" is 48 − 24 = 24pt — round 8 read the inset against the shelf and recorded it as ~48. The
/// device's measured rest error is 40–67pt short (`[HomeScrollProbe]`, 1,603 samples, 2026-08-02:
/// rest y=-90 vs true top -157), so the title clears on the sim and is cut on hardware.
///
/// Why NOT card-anchoring the title (moving it inside the button's label), which is the obvious
/// "it moves with the card" fix. It buys nothing here: the shelf never scrolls vertically, so the
/// title and the cards are already rigid with respect to each other — re-anchoring changes which
/// edge the inset is measured from, not the geometry. The band above the art is 96pt whichever
/// anchor you pick, the title is ~40pt, so the best static margin either way is ~32pt, still under
/// the envelope. And it would spend the structural invariants rounds 5–7 paid for: label content
/// has to be compensated by paddings that stay POSITIVE (negative compensation put focusable
/// frames outside their `.focusSection()` and froze directional resolution), a per-card overlay
/// would draw the title once per card, and any extra band means a reach above 72 — the sim
/// bisected 100 as where focus resolution dies.
///
/// What happens instead: the title stays exactly where round 8 put it at a true rest, and slides
/// DOWN by however much the viewport's top edge has eaten into it, clamped to
/// `heroPinnedRowTitleMaxSlide`. BUG-61 (beta.12) changed the HOW, not the WHAT: the slide is now
/// measured via `onGeometryChange` and applied as an eased offset (see `PinnedRowTitleTracking`)
/// instead of a draw-time `visualEffect`, because the draw-time recompute snapped the title in one
/// frame whenever a focus-driven reveal shifted layout discretely. The `@State` this introduces is
/// change-gated and confined to the title's own subtree — rows resting clear of the clip edge
/// measure a constant 0 and write nothing, so the BUG-19 no-identity-churn rule still holds. At
/// 0pt of rest error nothing moves and the look is byte-identical to beta.10; across the whole
/// 0–67pt envelope the title parks against the clip edge instead of disappearing behind it; past
/// the clamp (a row scrolled well above the focused one) it releases and scrolls away like any
/// other content, i.e. it behaves as a sticky header for exactly as long as its row is on screen.
///
/// Contract note for `CollectionRowView` (CollectionsUI.swift, same overlay pattern via the same
/// environment values): the contract is UNCHANGED — the title is still an overlay on the shelf at
/// the same inset — so that row keeps working untouched, it simply keeps the round-8 behavior. The
/// follow-up is one line: add `.pinnedRowTitleTracking(rowKey: collection.id)` to its overlaid
/// `Text` immediately before the existing `.padding(.top, Theme.Size.heroPinnedRowTitleInset)`.
enum PinnedRowTitle {
    /// Name Home attaches to its rows ScrollView (`rowsScroll`) purely as a resolution fallback
    /// for `visibleBounds` below. Also the name `CollectionRowView`'s follow-up inherits for free.
    nonisolated static let rowsScrollSpace = "home_rows_scroll"

    /// The rows viewport's rect, converted into the TITLE's local space — so `minY > 0` reads
    /// directly as "the viewport's top edge is this far BELOW the title's top", i.e. exactly this
    /// much of the title is currently clipped away.
    ///
    /// Primary lookup is the enclosing VERTICAL scroll view (the row's own shelf is horizontal, so
    /// the axis filter skips it). The named fallback covers the case where that filter doesn't
    /// resolve through the nested shelf: a miss on both is fail-safe (no slide = exactly today's
    /// behavior) but silent, so the probe logs nothing for titles — which is itself the signal
    /// that the lookup, not the geometry, is what needs looking at.
    nonisolated static func visibleBounds(_ proxy: GeometryProxy) -> CGRect? {
        proxy.bounds(of: .scrollView(axis: .vertical)) ?? proxy.bounds(of: .named(rowsScrollSpace))
    }

    /// BUG-53/BUG-60 device calibration (beta.12): the whole cluster's remaining dial — how far a
    /// title may ride over its row's artwork — is a function of the DEVICE's rest error, which the
    /// sim cannot reproduce (sim rests park the title clear of the art; the 40–67pt device error
    /// parks it 8–35pt onto it, and under the focused card's system lift). Rather than shipping a
    /// blind constant into the most regression-prone surface, the clamp is overridable at runtime.
    /// Simulator:
    ///
    ///     xcrun simctl spawn <udid> defaults write com.nuvio.media.NuvioTV debug.pinnedTitleMaxSlide -float 40
    ///
    /// Physical Apple TV (Codex gate 1: `defaults write` on the Mac never reaches the device's
    /// sandbox) — pass it as a LAUNCH ARGUMENT; `UserDefaults.standard` consults the argument
    /// domain (`-key value` argv pairs) before every other domain, so this same read picks it up:
    ///
    ///     xcrun devicectl device process launch --terminate-existing --device <udid> \
    ///         com.nuvio.media.NuvioTV -debug.pinnedTitleMaxSlide 40
    ///
    /// so the manual device pass can bisect the visible trade (title clipping at the top vs title
    /// riding over art) live, without rebuild cycles. Unset/0 = the shipped constant. Read once at
    /// launch, same as every other probe knob.
    nonisolated static let maxSlideOverride: CGFloat? = {
        let v = UserDefaults.standard.double(forKey: "debug.pinnedTitleMaxSlide")
        return v > 0 ? CGFloat(v) : nil
    }()

    /// The slide cap resolved for ONE row, in that row's own units.
    ///
    /// Wave 4 item 6 (tester report `docs/steven-batch-plan-2026-08-29.md`, "the section title
    /// slides down over the cards", worst on his Streaming Services collection folder tiles): the
    /// cap used to be the bare `heroPinnedRowTitleMaxSlide` (72) — a fixed number with no knowledge
    /// of the card it rides over. The slide is not what the viewer judges, though; the INTRUSION is
    /// — how far the title's bottom edge ends up past the artwork's top edge:
    ///
    ///     clearance = artworkTop − (titleInset + titleHeight)
    ///               = (Spacing.lg + reach) − (48 + ~38)
    ///               = (24 + 88) − 86  ≈  26pt          // static gap, title bottom → art top
    ///     intrusion = slide − clearance                //  = 46pt at the old fixed 72 cap
    ///
    /// and 46pt is 16.7% of a Small poster's 275pt art, 22.7% of a 203pt landscape card, and 25.1%
    /// of a Small square/landscape FOLDER TILE (183pt — `FolderTile.artworkHeight` takes the height
    /// of those shapes from `style.width`, correctly: they are a true square / true 16:9 of the
    /// row's width, so they are simply SHORTER than a poster). On a folder tile that slice lands on
    /// a centred wordmark rather than a poster's usually-empty top margin. Full arithmetic table in
    /// `Theme.Size.heroPinnedRowTitleArtIntrusionFraction`.
    ///
    /// So the cap becomes proportional to the artwork it rides over:
    ///
    ///     cap = min(heroPinnedRowTitleMaxSlide,
    ///               clearance + artworkHeight × heroPinnedRowTitleArtIntrusionFraction)
    ///
    /// i.e. the intrusion is capped at 9% of the row's art while the proven 72pt absolute still
    /// bounds everything (a very tall row can never buy a bigger slide than the focus band was ever
    /// shown to tolerate). Because the cap is `clearance + budget` it can never fall BELOW the
    /// clearance a settled rest needs — the deterministic beta.12 rest (title bottom exactly at the
    /// art top) is byte-identical at every Poster Size; only deeply-clipped rows give up slide.
    ///
    /// `titleHeight` comes from the title's own proxy rather than a constant, so Bold Text and
    /// larger type shrink the clearance term the same way they shrink the real gap. `artworkHeight`
    /// is nil for a call site that cannot size itself confidently — then only the absolute cap
    /// applies, i.e. exactly the pre-Wave-4 behavior. `cardTopReach` is the row's reach band; the
    /// `Spacing.lg` half of `artworkTop` is the shelf's own vertical padding, which every pinned
    /// row shares (CatalogRowView / UpcomingRow / Continue Watching `.padding(.vertical, .lg)`,
    /// CollectionRowView `.padding(.top, .lg)` in pinned mode).
    ///
    /// `maxSlideOverride` deliberately BYPASSES the proportional term: that knob exists so a manual
    /// device pass can bisect the visible trade live, and a clamp that silently overrode it would
    /// make the knob a no-op at every value above the proportional cap.
    ///
    /// PROBE-ONLY as of Codex 2026-08-29 P1: `slide()` no longer clamps with this value — binding
    /// a sub-absolute cap clips the title at deep rests (visibility beats bounded intrusion). The
    /// probe still reports it as `cap=` so hardware passes can quantify per-row intrusion.
    nonisolated static func maxSlide(titleHeight: CGFloat,
                                     artworkHeight: CGFloat?,
                                     cardTopReach: CGFloat) -> CGFloat {
        if let override = maxSlideOverride { return override }
        let absolute = Theme.Size.heroPinnedRowTitleMaxSlide
        guard let artworkHeight, artworkHeight > 0 else { return absolute }
        let intrusionBudget = artworkHeight * Theme.Size.heroPinnedRowTitleArtIntrusionFraction
        return min(absolute, staticClearance(titleHeight: titleHeight, cardTopReach: cardTopReach) + intrusionBudget)
    }

    /// How far the title's BOTTOM edge sits above the artwork's TOP edge at a true rest (slide 0)
    /// — the free travel a slide has before it starts painting on the card:
    ///
    ///     clearance = artworkTop − titleBottom
    ///               = (Spacing.lg + reach) − (titleInset + titleHeight)
    ///               = (24 + 88) − (48 + ~38)  ≈  26pt
    ///
    /// and therefore `intrusion = slide − clearance` exactly. Factored out of `maxSlide` (which has
    /// computed it inline since Wave 4) so the settle re-reveal targets the SAME number rather than
    /// a second, drifting copy of the arithmetic — Codex r1 P1: gating the correction on raw
    /// `margin < 0` fired on a `margin=-25 net=0` rest whose title was still fully clear of the
    /// art, and would have nudged ordinary Medium/Small rests (`margin=-40 slide=40 net=0`).
    ///
    /// `titleHeight` is the title's own MEASURED height, not a constant, so Bold Text and larger
    /// type shrink this the same way they shrink the real gap.
    ///
    /// This is the AT-REST number. What the viewer judges is the FOCUSED card's clearance — see
    /// `Clearances` — because the card the title rides over is the one the system lift has raised.
    nonisolated static func staticClearance(titleHeight: CGFloat, cardTopReach: CGFloat) -> CGFloat {
        let artworkTop = Theme.Spacing.lg + cardTopReach
        return max(artworkTop - (Theme.Size.heroPinnedRowTitleInset + titleHeight), 0)
    }

    /// One row's two clearances. Both are "title bottom → artwork top at slide 0"; they differ by
    /// which card is being measured against (Codex r4 P1).
    ///
    ///     atRest     = (Spacing.lg + reach) − (titleInset + titleHeight)   ≈ 26pt
    ///     focused    = max(atRest − lift, 0)
    ///     focusedRaw = atRest − lift                                       (BUG-87/89, unclamped)
    ///
    /// The focus treatment raises the FOCUSED card's artwork while the title stays put, so the
    /// card the title actually rides over has that much less room than the row's resting geometry
    /// suggests. Every version before r4 targeted `atRest`, which meant the corrected fixpoint
    /// still left the focused card's artwork under the title — a passing gate alongside the
    /// tester's reported overlap. The correction budget and the visibility belt both work in
    /// `focused` now; `atRest` survives as the probe's pre-lift reading, as the clearance an
    /// UNFOCUSED row is judged by (nothing has raised its cards — Codex r7 P2), and as the term
    /// `maxSlide`'s (probe-only) proportional cap has always used.
    // `nonisolated`: same @Sendable-transform requirement as `Reading` below.
    nonisolated struct Clearances: Equatable, Sendable {
        var atRest: CGFloat
        var focused: CGFloat
        /// What was subtracted — `focusLiftAllowance` for the ACTIVE focus mode. Carried so the
        /// settle log can name it: `focused` alone hides the magnitude once the clamp bites.
        var lift: CGFloat
        /// BUG-87/89: `focused` is CLAMPED at 0 because both consumers — the corrector's `bandLow`
        /// and the belt's `intrusion` — are written in "how much slide is free" units, where a
        /// negative free travel is meaningless. That clamp is also how an 18pt PERMANENT overlap at
        /// Large read as a clean 0 for a whole release. This is the unclamped value: negative means
        /// the focused card's artwork sits that far OVER the settled title's bottom at every rest,
        /// which no correction can fix. Reported on every settle line as `clearanceLiftRaw=`, and
        /// `PinnedRowGeometry.topReachFloor(lift:titleHeight:)` is where it is kept non-negative —
        /// against the ACTIVE font's title metric as of rc10, which is what stopped Open Sans from
        /// reproducing the exact deficit that floor exists to remove.
        var focusedRaw: CGFloat
    }

    /// Which focus treatment a ROW's cards actually wear. Since BUG-108 every pinned row's cards
    /// resolve through `CardFocusMode` — the collection folder row's `FolderTile` now carries
    /// `CardArtworkFocusLift` too (`PlainLabelRing.lift`) — so there is only the one case left; kept
    /// as an enum rather than collapsed away because `focusLiftAllowance`'s and
    /// `pinnedRowTitleTracking`'s signatures still take a `treatment:` and a future row shape may
    /// need a second case again.
    // `nonisolated`: same @Sendable-transform requirement as `Reading` below.
    nonisolated enum RowCardTreatment: Equatable, Sendable {
        /// Cards that go through `CardFocusTreatment` (or, for `FolderTile`/`CastCard`,
        /// `CardArtworkFocusLift` directly via `PlainLabelRing.lift`), so their lift follows
        /// `CardFocusMode.resolve` in all three modes: `PosterCard` (catalog rows, PosterCard.swift
        /// ~L604), `LandscapeCard` (Continue Watching, Upcoming — PosterCard.swift ~L766), and the
        /// collection folder-tile row (`CollectionsUI.swift`) since BUG-108.
        case cardTreatment
    }

    /// The two Appearance settings `CardFocusMode.resolve` branches on, carried as a value so the
    /// lift computation can be driven by a REACTIVE read rather than by whatever the defaults
    /// happened to say the last time geometry moved (Codex r10 P2).
    ///
    /// The staleness this closes: flipping "No Zoom on Focus" or the accent ring in Settings and
    /// coming back to Home changes no geometry — Home is alive in the tab view and its rows have
    /// not moved — so the title's `onGeometryChange` transform need never run again, and the
    /// clearance published to `PinnedRowSettle` would keep describing the PREVIOUS mode
    /// indefinitely: wrong correction target, wrong fade threshold, until something happened to
    /// scroll. `PinnedRowTitleTracking` reads both keys as `@AppStorage` and republishes on change;
    /// see `current` for what the remaining bare reads are for.
    // `nonisolated`: same @Sendable-transform requirement as `Reading` below.
    nonisolated struct FocusModeFlags: Equatable, Sendable {
        var noZoom: Bool
        var accentRing: Bool
        /// BUG-87 rc12 follow-up: a default-OFF Christian-side A/B (`AboutSettingsPane`'s "No Zoom
        /// Row Reach (A/B)" row, backing key `PinnedRowTitle.noZoomReachHoldsLiftKey`). Defaulted so
        /// every existing memberwise call site keeps compiling unchanged. See
        /// `reachHoldsLiftEffective` for the gate and `PinnedRowGeometry.plan`'s `floorLift` for
        /// where this actually spends — never through `focusLiftAllowance` below.
        var reachHoldsLift: Bool = false

        /// Inert unless `noZoom` is also true, exactly like `accentRing`'s inertness with zoom on:
        /// the hold only means something when No Zoom's own treatment is the reason the reach floor
        /// would otherwise reserve zero room for a lift.
        nonisolated var reachHoldsLiftEffective: Bool { reachHoldsLift && noZoom }

        /// Live snapshot for call sites with no SwiftUI context to observe from. This is the
        /// DEFAULT, not the primary path: every call that matters — `reading` from the tracking
        /// modifier, and the probe — is handed explicit `@AppStorage`-backed flags, and it is the
        /// modifier-side republish that keeps `PinnedRowSettle.clearances` coherent with them.
        nonisolated static var current: FocusModeFlags {
            FocusModeFlags(noZoom: UserDefaults.standard.bool(forKey: "no_zoom_on_focus"),
                           accentRing: UserDefaults.standard.bool(forKey: "accent_focus_ring"),
                           reachHoldsLift: UserDefaults.standard.bool(forKey: noZoomReachHoldsLiftKey))
        }
    }

    /// Backing key for the rc12 No Zoom reach-hold A/B (`FocusModeFlags.reachHoldsLift`,
    /// `AboutSettingsPane`'s "No Zoom Row Reach (A/B)" toggle, `PinnedRowTitleTracking`'s
    /// `@AppStorage`).
    nonisolated static let noZoomReachHoldsLiftKey = "debug.pinnedNoZoomReachHoldsLift"

    /// Launch-latched twin of the `@AppStorage` reads, resolved via `bool(forKey:)` rather than
    /// `@AppStorage<Bool>` because the latter does not coerce a UI test's argument-domain "YES" the
    /// way `bool(forKey:)` does — same precedent as `AboutSettingsPane`'s
    /// `collectionFrameProbe || CollectionFocusFrameProbe.enabled`. Every SwiftUI reader ORs this in
    /// alongside its own `@AppStorage` read so a UI test's launch argument and a live Settings flip
    /// both work.
    nonisolated static var reachHoldsLiftKnob: Bool {
        UserDefaults.standard.bool(forKey: noZoomReachHoldsLiftKey)
    }

    /// How far the ACTIVE focus treatment raises a focused card's artwork.
    ///
    /// Two values, not three (BUG-93, Wave F agent A). `CardFocusMode.resolve` still has three
    /// branches, but only one of them lifts by a different amount, and it is the zero one:
    ///
    ///  - **still** (`no_zoom_on_focus` on, either ring state) — Wave 7 made this genuinely zero
    ///    lift: a custom `ButtonStyle` that never receives the system hover effect, and a treatment
    ///    that draws a border and a shadow and scales nothing. Charging 20pt here fabricated 20pt
    ///    of intrusion out of nothing: every rest was over-corrected by 20pt and titles that were
    ///    perfectly clear could be faded out by the belt.
    ///  - **systemLift** (both off) — the native hover effect on the artwork container, measured at
    ///    `heroPinnedRowFocusLiftAllowance` (test44, 2026-08-25).
    ///  - **manualScale** (ring on, zoom on) — the SAME rise, by construction as of BUG-93.
    ///
    /// The manual branch used to derive its rise from a fixed lockup SCALE (1.12), which made ring
    /// mode charge ~16pt at Small, ~20 at Medium and ~27 at Large against a clip budget that had
    /// reserved 20 everywhere — the "posters cut off at the top" half of BUG-93. PosterCard now
    /// holds the RISE as the constant (`cardFocusLiftRise`, which IS
    /// `Theme.Size.heroPinnedRowFocusLiftAllowance`) and derives the per-card scale from it
    /// (`cardLiftScale(artworkHeight:)`), so both zoom modes raise the artwork's top edge by
    /// exactly 20pt at every Poster Size and this function has nothing left to branch on. The two
    /// sides cannot drift: they are literally the same constant, and test49 measures the ring-mode
    /// rise against it on the sim.
    ///
    /// `mode` is read at MEASUREMENT time from the plain `UserDefaults` key the treatments use as
    /// `@AppStorage`, not latched at launch: "No Zoom on Focus" is a live Appearance toggle. A
    /// settings change therefore takes effect on the row's next reading pass rather than instantly
    /// — the same frame the cards themselves re-render in, so nothing can be seen mid-flip.
    ///
    /// `artworkHeight`, `captionVisible` and `treatment` no longer participate. They are kept in
    /// the signature deliberately rather than removed: every caller already threads them (they are
    /// the same values `maxSlide` and `clearances` need), the ring's rise was height-dependent as
    /// recently as beta.17, and a future treatment that is height-dependent again should not have
    /// to be re-threaded through four call sites to say so.
    ///
    /// `mode.reachHoldsLift` (BUG-87 rc12 follow-up) never reaches this function, on purpose: this
    /// still returns 0 in No Zoom whether or not the hold is on. The hold's job is to reserve ROOM
    /// in the reach for a lift that still-mode genuinely never produces — charging that lift here
    /// too would raise `lift` AND the reach floor for the same 20pt, leaving `bandLow` at −4
    /// (`focused = atRest − lift`) exactly as before the hold existed: the Wave 7 / BUG-93
    /// fabricated-intrusion bug, reintroduced. `PinnedRowGeometry.plan`'s `floorLift` is the one and
    /// only place `reachHoldsLiftEffective` is read.
    nonisolated static func focusLiftAllowance(artworkHeight: CGFloat?,
                                               captionVisible: Bool,
                                               treatment: RowCardTreatment,
                                               mode: FocusModeFlags = .current) -> CGFloat {
        // No-zoom wins over the ring everywhere, checked first exactly as `CardFocusMode.resolve`
        // does. Card treatments get `.still` (nothing scales); folder tiles get
        // `cardFocusButtonStyle`'s `StillCardButtonStyle` + `focusEffectDisabled`, which likewise
        // cannot lift. Every other combination — system lift, ring, and (since BUG-108) the folder
        // tile's own manual scale — rises by the one measured constant.
        mode.noZoom ? 0 : Theme.Size.heroPinnedRowFocusLiftAllowance
    }

    /// Vertical chrome a poster lockup carries BELOW its artwork: `Theme.Spacing.md` (16,
    /// `PosterCard`'s artwork↔caption gap) plus one `Theme.Font.cardTitle` caption line (≈27.5 as
    /// rendered). ≈43.5pt, which is exactly the residue in the 2026-08-30 measurement of the
    /// focusable link frame — `artworkHeight + 175.5` = topReach (88) + lockup + bottomReach (44)
    /// ⇒ lockup = artworkHeight + 43.5.
    ///
    /// No longer feeds any lift arithmetic (BUG-93 moved the focus scale onto the artwork
    /// container, so nothing scales the lockup any more). It survives as the LOCKUP EXTENT every
    /// pinned-row height calculation needs — `HomeView.pinnedLastRowHeight` (BUG-89's trailing
    /// inset) sizes the last row with it, and the settle corrector's band reads the same extent off
    /// the measured row frame. A constant rather than a live type metric for the same reason as
    /// before: it is used to size a BAND, never to lay out the caption itself, and mixed-shape
    /// collection rows (whose tiles use `Spacing.sm` and a per-folder `hideTitle`) are approximated
    /// by the same number.
    nonisolated static let cardLockupCaptionChrome: CGFloat = 43.5

    nonisolated static func clearances(titleHeight: CGFloat,
                                       cardTopReach: CGFloat,
                                       artworkHeight: CGFloat?,
                                       captionVisible: Bool,
                                       treatment: RowCardTreatment,
                                       mode: FocusModeFlags = .current) -> Clearances {
        let atRest = staticClearance(titleHeight: titleHeight, cardTopReach: cardTopReach)
        let lift = focusLiftAllowance(artworkHeight: artworkHeight,
                                      captionVisible: captionVisible,
                                      treatment: treatment,
                                      mode: mode)
        return Clearances(atRest: atRest,
                          focused: max(atRest - lift, 0),
                          lift: lift,
                          focusedRaw: atRest - lift)
    }

    /// How far the title must ride DOWN to stay fully inside the rows viewport, clamped.
    /// `proxy` must be the TITLE's own geometry (local origin = the title's top-left, `size` = the
    /// title's own rendered size). The defaults reproduce the pre-Wave-4 clamp exactly, so any call
    /// site that cannot state its artwork height keeps today's behavior.
    nonisolated static func slide(_ proxy: GeometryProxy,
                                  artworkHeight: CGFloat? = nil,
                                  cardTopReach: CGFloat = Theme.Size.heroPinnedRowTopPad) -> CGFloat {
        slideMeasurement(proxy, artworkHeight: artworkHeight, cardTopReach: cardTopReach) ?? 0
    }

    /// Optional-returning twin of `slide` (Wave 4 item 6, `docs/steven-batch-plan-2026-08-29.md`):
    /// `slide()` collapses "couldn't measure" (no enclosing scroll view resolved yet — e.g. mid a
    /// mixed-shape row's lazy relayout) and "measured, and the true slide is 0" into the same `0`
    /// return, which is correct for `slide()`'s two callers — the pre-seed draw-time branch (no
    /// prior state to hold, so 0 is the right default) and the probe (a blank measurement is
    /// already dropped by its own `guard`). It is NOT correct for `PinnedRowTitleTracking`'s
    /// `onGeometryChange`: that call site persists whatever it's handed into `@State`, so a
    /// transient nil read there un-parks a title that was correctly slid — a snap-then-flash the
    /// tester's scroll-right-then-up repro would see as the title jumping onto the clip edge and
    /// back. This variant lets that one caller tell the two cases apart and hold the previous
    /// value on nil instead of overwriting it with a false 0.
    /// The `captionVisible`/`rowIsFocused` defaults are deliberately not threaded here: `slide`
    /// depends on neither (it is `min(max(visible.minY, 0), cap)`), and those two only steer the
    /// belt's clearance choice. This wrapper's callers want the offset, nothing else.
    nonisolated static func slideMeasurement(_ proxy: GeometryProxy,
                                             artworkHeight: CGFloat? = nil,
                                             cardTopReach: CGFloat = Theme.Size.heroPinnedRowTopPad) -> CGFloat? {
        reading(proxy, artworkHeight: artworkHeight, cardTopReach: cardTopReach)?.slide
    }

    /// One title's tracked state: the eased slide, this row's static clearance, and the visibility
    /// belt's two hysteresis edges.
    ///
    /// Why the belt's condition is carried as two BOOLs rather than the raw `margin` they are
    /// derived from (load-bearing — `PinnedRowTitleTracking`'s cost note depends on it):
    /// `onGeometryChange` fires whenever its observed value CHANGES, and a row resting clear of the
    /// clip edge measures `slide == 0`, `hideCandidate == false`, `showAgain == true` at EVERY
    /// scroll position. Carrying `margin` itself would instead fire the observer once per frame for
    /// every visible row — exactly the per-frame churn the BUG-19/BUG-41 rule forbids. The settle
    /// re-reveal, which does need the raw numbers, measures the ROW instead
    /// (`pinnedRowSettleTracking`) and only while that row holds focus.
    // `nonisolated`: consumed inside `onGeometryChange`'s @Sendable transform — under the
    // project's default-MainActor isolation the synthesized Equatable conformance would
    // otherwise be actor-isolated and unable to satisfy the Sendable type parameter.
    nonisolated struct Reading: Equatable, Sendable {
        var slide: CGFloat
        /// This row's two clearances (`Clearances`), published onward to the settle re-reveal,
        /// which needs them to target artwork intrusion rather than raw margin but has only the
        /// ROW's frame to measure — the title's rendered height lives here. Constant for a given
        /// row and type size, so carrying them adds no `onGeometryChange` fires.
        var clearances: Clearances
        /// ARM edge of the belt's hysteresis: this title is in a state a viewer would call broken
        /// — clipped past the slide cap (`net < 0`), or riding more than `fadeIntrusionArm` onto
        /// the FOCUSED card's artwork — AND still on screen to be seen doing it.
        var hideCandidate: Bool
        /// RECOVER edge: fully inside the viewport AND clear of the focused card's artwork.
        /// Strictly stronger than `!hideCandidate`; the band between the two is where the belt
        /// holds whatever it has, so a rest sitting exactly at the corrected fixpoint
        /// (`liftedIntrusion == 0`) can never flicker.
        var showAgain: Bool
        /// How far the title's bottom currently sits past THIS row's artwork top, judged against
        /// the clearance its own cards are actually in (lifted while focused, at rest otherwise).
        /// Carried for the belt's probe lines; it is an affine function of `slide`, which is
        /// already here, so it adds no `onGeometryChange` fires of its own.
        var intrusion: CGFloat
    }

    /// A `Reading` stamped with the tracking modifier's `remeasureTick` (Wave W5, BUG-87).
    ///
    /// Why the observer's value type is this and not `Reading` itself. `onGeometryChange` fires its
    /// action only when the transform's OUTPUT changes, and the two cases Wave W5 has to force a
    /// re-derivation in are exactly the two where the output does NOT change on its own:
    ///
    ///  - the FIRST-READING GRACE. A title that publishes its very first `Reading` off a layout
    ///    that is not final yet used to arm the belt on the spot; on an untouched cold-launch Home
    ///    nothing re-fires geometry afterwards, so the hide became permanent and only a relaunch
    ///    brought the title back — the tester's build-117 "the row title disappeared entirely"
    ///    (BUG-87). The grace defers the arm and bumps the tick 0.5s later; if the layout HAS
    ///    settled the fresh reading differs anyway, and if it has not, the tick is what still gets
    ///    the action to run so a genuinely broken title arms (0.5s late) rather than never.
    ///  - the RECOVERY WATCHDOG. A faded title only comes back through `showAgain`, which needs a
    ///    measurement. A title hidden on a stale layout produces none, so it stayed hidden forever.
    ///
    /// The tick is carried in the OBSERVER's value rather than in `Reading` so nothing downstream
    /// of `Reading` (`republishForModeChange`, `standDownFastPath`, `PinnedRowTitleProbe`,
    /// `noteClearances`) has to know it exists, and so `Reading`'s equality keeps meaning "the same
    /// measured geometry". A tick-only fire is byte-identical work to a no-op measurement: the
    /// slide does not change, `updateFade` finds `previous?.hideCandidate == true` and declines to
    /// re-arm, and `noteClearances` sees an unchanged value and returns.
    // `nonisolated`: same @Sendable-transform requirement as `Reading` above.
    nonisolated struct TickedReading: Equatable, Sendable {
        var tick: Int
        var reading: Reading
    }

    /// The two geometry inputs a `Reading` is computed from, cached by `PinnedRowTitleTracking` so
    /// a mode change can recompute one WITHOUT a new geometry pass (Codex r10 P2).
    // `nonisolated`: same @Sendable-transform requirement as `Reading` above.
    nonisolated struct TitleGeometry: Equatable, Sendable {
        /// The rows viewport's top edge in the title's own space — `+` means that much of the
        /// title is currently clipped away.
        var visibleMinY: CGFloat
        /// The title's own rendered height.
        var titleHeight: CGFloat
    }

    /// `slideMeasurement`'s full form. `nil` means "couldn't measure" (see `slideMeasurement`'s
    /// doc for why that must never be collapsed into a measured 0).
    nonisolated static func reading(_ proxy: GeometryProxy,
                                    artworkHeight: CGFloat? = nil,
                                    cardTopReach: CGFloat = Theme.Size.heroPinnedRowTopPad,
                                    captionVisible: Bool = true,
                                    rowIsFocused: Bool = false,
                                    treatment: RowCardTreatment = .cardTreatment,
                                    mode: FocusModeFlags = .current) -> Reading? {
        guard let visible = visibleBounds(proxy) else { return nil }
        return reading(geometry: TitleGeometry(visibleMinY: visible.minY,
                                               titleHeight: proxy.size.height),
                       artworkHeight: artworkHeight,
                       cardTopReach: cardTopReach,
                       captionVisible: captionVisible,
                       rowIsFocused: rowIsFocused,
                       treatment: treatment,
                       mode: mode)
    }

    /// The pure core, split out of the proxy form so the tracking modifier can re-derive a Reading
    /// from CACHED geometry when only the focus mode changed — a Settings toggle moves nothing, so
    /// there may be no next geometry pass to recompute in (Codex r10 P2).
    nonisolated static func reading(geometry: TitleGeometry,
                                    artworkHeight: CGFloat?,
                                    cardTopReach: CGFloat,
                                    captionVisible: Bool,
                                    rowIsFocused: Bool,
                                    treatment: RowCardTreatment,
                                    mode: FocusModeFlags) -> Reading {
        let visibleMinY = geometry.visibleMinY
        let titleHeight = geometry.titleHeight
        // The BINDING cap stays the absolute one (Codex 2026-08-29 P1): any cap below the rest's
        // real minY trades intrusion for CLIPPING — the title parks partially off-screen, the
        // original BUG-37 complaint class — and a settled rest deep enough to intrude is itself
        // the bug (a stale reveal after a mixed-shape row's lazy relayout; see the scroll-repro
        // trace in docs/steven-batch-plan-2026-08-29.md). Visibility wins; the proportional cap
        // below (`maxSlide`) stays PROBE-ONLY so device passes can read how far each rest
        // actually intruded per row and size until the settle-level fix removes the deep rests.
        let cap = maxSlideOverride ?? Theme.Size.heroPinnedRowTitleMaxSlide
        let slide = min(max(visibleMinY, 0), cap)
        // `net = margin + slide = −visibleMinY + slide`, so `overshoot = −net` and `net < 0` ⇔
        // the rest ate more than the cap can give back.
        let overshoot = visibleMinY - slide
        // Keeps the belt scoped to titles the viewer can still SEE: a row scrolled well above the
        // focused one is also past the cap (and saturated, so its intrusion reads as the full
        // 46pt), but it is simply scrolling away as designed (see this enum's header) and must not
        // arm anything. The title's own rendered band is `[slide, slide + height]` in local units,
        // so it is still on screen exactly while the viewport's top edge is above its bottom.
        let stillOnScreen = visibleMinY < titleHeight + slide
        let clearances = clearances(titleHeight: titleHeight,
                                    cardTopReach: cardTopReach,
                                    artworkHeight: artworkHeight,
                                    captionVisible: captionVisible,
                                    treatment: treatment,
                                    mode: mode)
        // Codex r2 P2-3: `net < 0` alone under-covers the belt. When the corrector is disarmed,
        // exhausted, or bottom-blocked, an INTRUSION-ONLY rest leaves a fully opaque title sitting
        // on the artwork — `net` is fine, the picture is not. The arm edge therefore takes either
        // failure.
        //
        // Codex r4 P1: and the intrusion is measured against the FOCUSED card
        // (`clearances.focused`), not the row's resting geometry. The title rides over the card
        // that has focus, which the focus treatment has raised, so the pre-lift number was
        // systematically optimistic — a belt that recovered at pre-lift zero would happily leave
        // the focused card's artwork under the title.
        //
        // Codex r7 P2: but ONLY the focused row's cards are raised. An unfocused row's artwork
        // sits at its resting top, so judging it by the lifted clearance invents an intrusion that
        // does not exist — an 11pt slide on an unfocused row would read as 5pt intruded when it is
        // actually 15pt CLEAR, and the belt could fade a title nothing was wrong with. Each row is
        // judged by the geometry its own cards are actually in.
        //
        // Hysteresis (arm above `fadeIntrusionArm`, recover only at `intrusion ≤ 0`) is what keeps
        // a rest parked exactly at the corrected fixpoint — where `slide == clearances.focused`,
        // i.e. intrusion 0 for the focused row — from sitting on the boundary and flickering.
        let effectiveClearance = rowIsFocused ? clearances.focused : clearances.atRest
        let intrusion = slide - effectiveClearance
        return Reading(slide: slide,
                       clearances: clearances,
                       hideCandidate: stillOnScreen && (overshoot > 1 || intrusion > fadeIntrusionArm),
                       showAgain: overshoot <= 0 && intrusion <= 0,
                       intrusion: intrusion)
    }

    /// How far the pinned hero must yield, in points, so the focused row FITS at the canonical
    /// rest for the current Poster Size (Wave 10).
    ///
    /// The structural problem this closes, device-verified: at Large the focused row needs the
    /// title band (`Spacing.lg` + `heroPinnedRowTopPad` = 112) plus 403pt of artwork below the
    /// pinned clip edge — ~515pt — and the pinned rows viewport is 455 in BOTH sim and device
    /// probes. Every rest was therefore forced to choose between cutting the poster's top and
    /// hiding the title; Waves 8/9 could only pick the least-bad option, never satisfy both. The
    /// hero yields exactly the shortfall and the choice disappears.
    ///
    /// STATIC, keyed to `PosterStyle` alone. It changes when the user changes Poster Size and at
    /// no other time — deliberately not per row, per focus, or per rest. A hero that resized as
    /// you moved between rows of different heights ("breathing") was the rejected design: it makes
    /// the clip edge a moving target, which is what the reveal regime is least able to cope with,
    /// and the tester's actual request was the opposite — rows landing in the SAME place every
    /// time.
    ///
    /// Small and Medium compute to exactly 0, so their layout is bit-identical to Wave 9 — see the
    /// arithmetic table on `Theme.Size.heroPinnedRowsSettledCushion`.
    nonisolated static func pinnedHeroCompression(rowArtworkHeight: CGFloat) -> CGFloat {
        guard !heroCompressionDisabledByKnob else { return 0 }
        let requiredRowExtent = Theme.Spacing.lg
            + Theme.Size.heroPinnedRowTopPad
            + rowArtworkHeight
            + Theme.Size.heroPinnedRowsSettledCushion
        let raw = max(requiredRowExtent - Theme.Size.heroPinnedRowsViewportBudget, 0)
        let capped = min(raw, Theme.Size.heroPinnedCompressionCap)
        if raw > capped, cappedCompressionLogged != rowArtworkHeight {
            cappedCompressionLogged = rowArtworkHeight
            // Loud on purpose: past the cap the geometry is again unsatisfiable and the belt is
            // back in play, which is exactly the state a device pass needs to know it is looking at.
            NSLog("[HomeScrollProbe] hero %@",
                  "compression CAPPED want=\(Int(raw.rounded())) cap=\(Int(Theme.Size.heroPinnedCompressionCap))"
                    + " artwork=\(Int(rowArtworkHeight.rounded())) — rows still short, belt remains in play")
        }
        return capped
    }

    nonisolated(unsafe) private static var cappedCompressionLogged: CGFloat?

    /// `defaults write com.nuvio.media.NuvioTV debug.pinnedHeroCompressionOff -bool YES`, or as a
    /// launch argument on device/CI. Forces `pinnedHeroCompression` to 0 at every Poster Size,
    /// restoring the pre-Wave-10 geometry: the pinned rows viewport drops back to ~455 and a Large
    /// focused row no longer fits below the clip edge.
    ///
    /// It exists for ONE reason — to keep the visibility belt's gate honest. Wave 10 fixed the
    /// shortfall the belt was built for, which also deleted the belt's only reachable repro: with
    /// the compression in place the 2026-09-01 run measured `vh=524` and every down→up park settled
    /// healthy at `margin≈+22`, even with the corrector disarmed. A safety net whose failure mode
    /// has become unreachable is a safety net nobody can test, and it still has to work — for
    /// Poster Sizes past the compression cap, for mixed-shape extremes, and for whatever the next
    /// device geometry turns out to be. Turning the compression off reproduces the exact historical
    /// shortfall the belt was designed against, which makes test48 honest archaeology rather than a
    /// synthetic construction.
    ///
    /// Read once at launch like every other probe knob, and release-inert unless it is passed.
    nonisolated static let heroCompressionDisabledByKnob =
        UserDefaults.standard.bool(forKey: "debug.pinnedHeroCompressionOff")

    /// Verification for the constant `heroPinnedRowsViewportBudget` rests on: the live rows
    /// viewport should be exactly `budget + compression`. Logged once per distinct disagreement so
    /// a drifted platform metric shows up in a device log instead of silently mis-sizing the hero.
    nonisolated static func verifyViewportBudget(liveViewport: CGFloat, compression: CGFloat) {
        guard HomeGeometryProbe.enabled else { return }
        let expected = Theme.Size.heroPinnedRowsViewportBudget + compression
        // Positive confirmation for device passes (FEAT-30 spike onward): one line per distinct
        // live viewport, so a log with no MISMATCH line is "matched", not "never measured".
        let liveKey = liveViewport.rounded()
        if viewportLiveLogged != liveKey {
            viewportLiveLogged = liveKey
            NSLog("[HomeScrollProbe] hero %@",
                  "viewport live=\(Int(liveKey)) expected=\(Int(expected.rounded()))")
        }
        guard abs(liveViewport - expected) > 4 else { return }
        let key = (liveViewport / 2).rounded()
        guard viewportBudgetMismatchLogged != key else { return }
        viewportBudgetMismatchLogged = key
        NSLog("[HomeScrollProbe] hero %@",
              "viewport BUDGET MISMATCH live=\(Int(liveViewport.rounded())) expected=\(Int(expected.rounded()))"
                + " (budget \(Int(Theme.Size.heroPinnedRowsViewportBudget)) + compression \(Int(compression.rounded())))")
    }

    nonisolated(unsafe) private static var viewportBudgetMismatchLogged: CGFloat?
    nonisolated(unsafe) private static var viewportLiveLogged: CGFloat?

    /// Arm threshold for the visibility belt's intrusion half — how far a title may ride onto its
    /// row's artwork (as that row's own cards are actually sitting: lifted if it holds focus, at
    /// rest otherwise) before "a missing title beats a title on the art" applies. Small, but above
    /// the rounding noise around the corrected fixpoint (intrusion 0), which is the rest the belt
    /// must never fire on.
    nonisolated static let fadeIntrusionArm: CGFloat = 4

    /// Signed clearance between the title's top and the viewport's top edge BEFORE sliding —
    /// negative means the rest fell short far enough to cut the title (BUG-37 reproducing).
    /// Probe-only.
    nonisolated static func rawMargin(_ proxy: GeometryProxy) -> CGFloat? {
        visibleBounds(proxy).map { -$0.minY }
    }
}

extension View {
    /// Applies the BUG-37 slide, plus (knob on) the measurement the manual device pass needs.
    /// Attach to the TITLE TEXT ITSELF, BEFORE its `.padding(.top,)` — the modifier reads the
    /// text's own frame, so padding applied first would shift what it measures.
    ///
    /// `artworkHeight` is the row's RESTING artwork height (art only — the caption slot is below
    /// the art and irrelevant to an intrusion measured at its top edge), which is what makes the
    /// slide clamp proportional to the card instead of a fixed 72pt against a scaled one — see
    /// `PinnedRowTitle.maxSlide`. Rows whose cards are a single known shape can state it directly
    /// (`CatalogRowView`); a mixed-shape row states its SHORTEST card (`CollectionRowView`), which
    /// is the tile the clamp must protect. Leaving it nil is the documented opt-out for a call site
    /// that cannot size itself confidently: the absolute cap alone then applies, exactly as before
    /// this parameter existed (`UpcomingRow`, Home's Continue Watching — both fixed-height
    /// `LandscapeCard` shelves whose height the focus-engine regime pins, so sizing them is a
    /// separate, device-gated call).
    ///
    /// `isFocused` is whether one of THIS row's cards holds focus — the same signal
    /// `pinnedRowSettleTracking` takes, and required for the same reason: only a focused row's
    /// cards are raised by the focus treatment, so only a focused row is judged against the lifted
    /// clearance (Codex r7 P2). Deliberately NOT part of the style gate's remount key: focus
    /// changes constantly, and discarding the title's `slide`/`faded` state on every D-pad step
    /// would reintroduce the snap this modifier exists to remove.
    ///
    /// `treatment` is which focus treatment this row's CARDS wear, and it defaults to (and, since
    /// BUG-108, is) the only case — `PosterCard`/`LandscapeCard`, and now the collection folder-tile
    /// row too, all of which genuinely follow `CardFocusMode.resolve`. Before BUG-108 the folder row
    /// passed a since-removed `.plainBorderless` because `FolderTile` kept the native `.borderless`
    /// lift in ring mode; giving it `CardArtworkFocusLift` (`PlainLabelRing.lift`) put it on the same
    /// footing as every other pinned row's cards, so the one-case enum in
    /// `PinnedRowTitle.RowCardTreatment` covers it too (Codex r9 P2 named the split this closes).
    func pinnedRowTitleTracking(rowKey: String,
                                artworkHeight: CGFloat? = nil,
                                isFocused: Bool,
                                treatment: PinnedRowTitle.RowCardTreatment = .cardTreatment) -> some View {
        modifier(PinnedRowTitleTrackingStyleGate(rowKey: rowKey,
                                                 artworkHeight: artworkHeight,
                                                 isFocused: isFocused,
                                                 treatment: treatment))
    }
}

/// P-3 (beta.15): `PinnedRowTitleTracking`'s `slide`/`hasSeeded` `@State` is seeded from the row's
/// geometry and then only *updates* after the next `onGeometryChange` pass. A Poster Style change
/// (width/height, landscape toggle, caption visibility) re-lays out every row's cards in the same
/// frame the state is still holding the PRE-change offset, so the title renders on top of the
/// artwork for one frame and then heals over 0.22s — the tester-reported flash, prior form
/// BUG-60/61. This thin wrapper reads `PosterStyle` and gives the inner modifier a fresh `.id()`
/// whenever the geometry-relevant fields change, so SwiftUI discards `slide`/`hasSeeded` instead
/// of carrying them across the relayout: the very first frame after a style change then takes
/// `PinnedRowTitleTracking`'s own pre-seed, draw-time branch (see its comment — correct by
/// construction), so there is no stale offset to heal away from and no flash to see.
///
/// `styleKey` deliberately covers only `width`, `height`, `landscapeCatalogRows`, and `showTitle`
/// — the fields that change a row's CARD FRAMES (width/height, landscape aspect) or a card's total
/// height (the caption line `showTitle` adds/removes), all of which move where the row's content —
/// and therefore the clip edge the title tracks — sits. `cornerRadius` is excluded on purpose: it
/// only changes the background shape's corner, never any dimension that affects layout, so keying
/// on it would discard state (losing the eased-slide animation) on changes that don't need it.
private struct PinnedRowTitleTrackingStyleGate: ViewModifier {
    let rowKey: String
    /// The row's resting artwork height, or nil (absolute cap only) — see `pinnedRowTitleTracking`.
    let artworkHeight: CGFloat?
    /// Whether one of this row's cards holds focus — see `pinnedRowTitleTracking`. Passed straight
    /// through and deliberately kept OUT of `styleKey`: it changes on every D-pad step, and
    /// remounting the title there would discard the slide/fade state this gate exists to protect.
    let isFocused: Bool
    /// Which focus treatment this row's cards wear — see `pinnedRowTitleTracking`. A per-call-site
    /// constant, so it never needs to join the remount key.
    let treatment: PinnedRowTitle.RowCardTreatment
    @Environment(\.posterStyle) private var style

    /// `art…` joins the key because it is what the Wave 4 clamp is computed from: for every call
    /// site today it is DERIVED from the style fields already keyed here (so it adds no remounts in
    /// practice), but a mixed-shape row can also change it on its own — a synced collection edit
    /// that swaps a poster folder for a square one changes the row's shortest tile without touching
    /// Poster Style — and the seeded offset must not outlive the clamp it was measured under.
    /// Wave 4 item 4 (device round, `docs/steven-batch-plan-2026-08-29.md`): `rowKey` joins the
    /// identity too. Every pinned title used to share one gate id (this struct's own type
    /// identity), which is fine inside a `ForEach` scoped by element identity but not between
    /// CONDITIONAL SIBLINGS — `ContinueWatchingRow` and `UpcomingRow` sit as `if`/conditional
    /// branches in Home's `LazyVStack`, and when one appears or disappears SwiftUI can re-match
    /// the surviving branch's subtree onto the other's old identity, migrating one row's seeded
    /// `slide`/`hasSeeded` state onto a title that was never actually mid-slide. Folding `rowKey`
    /// into the id scopes the reset to the row it actually belongs to.
    private var styleKey: String {
        "\(rowKey)-\(style.width)x\(style.height)-land\(style.landscapeCatalogRows)-title\(style.showTitle)-art\(artworkHeight ?? -1)"
    }

    func body(content: Content) -> some View {
        content
            // `captionVisible` comes from the same `PosterStyle` already keyed above, so it can
            // never change without a remount — it feeds `maxSlide`'s proportional cap, and is
            // still threaded to `focusLiftAllowance` although BUG-93 made that lift flat.
            .modifier(PinnedRowTitleTracking(rowKey: rowKey,
                                             artworkHeight: artworkHeight,
                                             captionVisible: style.showTitle,
                                             isFocused: isFocused,
                                             treatment: treatment))
            .id(styleKey)
    }
}

private struct PinnedRowTitleTracking: ViewModifier {
    let rowKey: String
    /// Wave 4 item 6: the row's resting artwork height, feeding the proportional slide clamp
    /// (`PinnedRowTitle.maxSlide`). nil = absolute cap only, i.e. the pre-Wave-4 behavior.
    let artworkHeight: CGFloat?
    /// Whether this row's cards carry a caption line — the rest of the lockup the manual-scale
    /// focus treatment scales along with the artwork. Style-derived, so constant between remounts.
    let captionVisible: Bool
    /// Whether one of this row's cards holds focus, i.e. whether its artwork is currently RAISED
    /// by the focus treatment. Decides which clearance the belt judges this row against — see
    /// `PinnedRowTitle.reading` (Codex r7 P2).
    let isFocused: Bool
    /// Which focus treatment this row's cards wear, deciding HOW MUCH that raise is — see
    /// `PinnedRowTitle.RowCardTreatment` (Codex r9 P2).
    let treatment: PinnedRowTitle.RowCardTreatment
    /// The reach band this row's cards extend upward through — the other half of "where the
    /// artwork's top edge is" (art top = `Spacing.lg` shelf padding + reach). Read from the
    /// environment rather than assumed to be `heroPinnedRowTopPad` so the clamp stays correct if a
    /// host ever runs a different reach; the title only renders at all when this is > 0.
    @Environment(\.rowCardTopReach) private var cardTopReach

    /// BUG-61 (beta.12): the original `visualEffect` recomputed the slide at draw time with no
    /// transaction of its own, so a focus-driven reveal — whose layout shift lands in ONE frame —
    /// snapped the title to its new offset while everything around it eased (measured: ~33pt in
    /// 60ms; the probe recorded 10–13 distinct offsets per walk). The slide target is now
    /// measured via `onGeometryChange` into local state and applied through an explicit eased
    /// transaction, so the title moves on the same kind of curve as the content it tracks.
    ///
    /// Cost note (the BUG-19/BUG-41 rule this must not break): `onGeometryChange` fires only when
    /// the measured value CHANGES, and rows resting clear of the clip edge measure a constant 0 —
    /// so per-frame state writes are confined to the one row actually crossing the edge during a
    /// scroll, and the invalidation is this modifier's tiny subtree (the title Text), not the row.
    @State private var slide: CGFloat = 0
    /// First measurement seeds the offset directly — a row that mounts mid-scroll with a nonzero
    /// slide must start there, not visibly settle into it.
    @State private var hasSeeded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Visibility belt (2026-08-30, rc1 tester report + sim repro `margin=-86..-100 slide=72
    /// net=-14..-28 cap=64 intr=46`): the LAST line of defence, after the settle re-reveal
    /// (`PinnedRowSettle`) has had its go. If a rest still leaves the title CLIPPED (`net < 0`) or
    /// still riding more than `PinnedRowTitle.fadeIntrusionArm` onto the FOCUSED card's artwork, a
    /// missing title beats a title on the art, so it fades out entirely and comes back the moment
    /// the geometry recovers. Both failures count (Codex r2 P2-3): when the corrector is disarmed,
    /// exhausted, or bottom-blocked, an intrusion-only rest is fine by `net` and still has title
    /// painted on the poster. The intrusion is the LIFTED one (Codex r4 P1) — measured against the
    /// card the system focus lift has raised, which is the card the title actually rides over.
    ///
    /// Deliberately NOT a slide/cap change: the binding cap stays 72 and every rest that leaves the
    /// title clear of the artwork renders byte-identically to today (`faded` never leaves `false`
    /// there, and `.opacity(1)` is a no-op) — including the deterministic beta.12 rest, which parks
    /// at `intrusion == 0`, below the arm threshold. This is wired at the shared tracking layer, so
    /// all four pinned rows — catalog, Continue Watching, Upcoming, collections — inherit it from
    /// their existing one-line `pinnedRowTitleTracking` call.
    @State private var faded = false
    /// Cancellation token for the delayed hide (see `updateFade`). Bumped when the belt's arm state
    /// TRANSITIONS and on each re-arm of the deferred check, never once per measurement.
    @State private var fadeToken = 0
    /// When this title last STOPPED being acceptable — set on the transition out of `showAgain`,
    /// cleared on the transition back into it, deliberately NOT reset by re-arming. The ceiling
    /// (`fadeMaxDefer`) therefore measures the whole episode, so a title that keeps flickering in
    /// and out of the arm band while the page churns still fades on schedule.
    @State private var fadeArmedAt: Date?
    /// Token for this title's stand-down subscription, so teardown clears only its own — see
    /// `PinnedRowSettle.observeStandDown`. Written once on appear.
    @State private var standDownObserverID = 0

    // ── Wave W5 (BUG-87: the title that vanished on a cold launch and only came back on relaunch) ──
    //
    // The belt's two one-way doors, closed. Both are timer-driven and both work by forcing the
    // `Reading` observer to re-derive from a FRESH geometry pass — see `PinnedRowTitle.TickedReading`
    // for why the tick has to live in the observer's value rather than in `Reading`.
    //
    // Cost note (the BUG-19/41 rule these must not break): `remeasureTick` is written only by the
    // two timers below — never per frame, never from a geometry callback — and it is deliberately
    // NOT read by the `TitleGeometry` observer's transform, whose whole job is to stay cheap enough
    // to run on every scroll frame for every visible row. `sawFirstReading`/`graceHold` are written
    // only on belt state TRANSITIONS, the same budget `fadeToken` already runs on.
    /// Bumped to force the `Reading` transform to re-run and the action to fire even when the
    /// measured geometry is byte-identical to last time.
    @State private var remeasureTick = 0
    /// Cancellation token for the first-reading grace timer AND the watchdog chain's bumps.
    @State private var remeasureToken = 0
    /// Cancellation token for the recovery watchdog chain specifically, so an un-fade kills it
    /// without disturbing a grace bump that may be in flight.
    @State private var watchdogToken = 0
    /// Whether this title has ever published a `Reading` in THIS visit. The first one may not arm.
    @State private var sawFirstReading = false
    /// Set when the first reading WOULD have armed and was held by the grace instead, so the
    /// second reading arms even though `previous?.hideCandidate` is already true (the belt's arming
    /// is transition-driven; without this the deferred arm would be swallowed by its own deferral).
    @State private var graceHold = false
    /// Whether the recompute currently being processed came from the recovery watchdog, so an
    /// un-fade caused by it can be logged as such. Scratch, valid only across one recompute.
    @State private var remeasureFromWatchdog = false

    /// Longer than `PinnedRowSettle.settleDelay + nudgeDuration` on purpose: this is what gives the
    /// settle re-reveal first refusal at every rest. The corrector decides at 0.25s and its scroll
    /// lands by ~0.5s; the correction is itself motion, which defers this check further; and a
    /// corrected rest then measures `showAgain` and un-fades immediately. The belt therefore only
    /// ever fires on rests the re-reveal could not fix — a bounded correction, a disarmed or
    /// exhausted mechanism, or a row the focus engine keeps pinned.
    private static let fadeDelay: TimeInterval = 0.7
    /// Floor on the deferred check's re-arm interval while the page is still moving, so a long
    /// scroll costs a handful of trivial main-queue hops rather than one per frame.
    private static let fadeRecheckFloor: TimeInterval = 0.1
    /// TERMINAL ceiling on how long the belt may be deferred by motion (Wave 9(a)). Once a title
    /// has been continuously unacceptable for this long it fades whatever the page is doing.
    ///
    /// This is what makes the belt genuinely terminal, and the device pass is why it has to be.
    /// The rest-gate alone is a liveness hazard: the corrector's own correction stamps motion by
    /// design (so it keeps first refusal), and on an unsatisfiable rest it can keep re-firing
    /// against a reveal that pulls the row straight back — motion forever, fade never. The device
    /// log shows exactly that steady state (`net=-27`, `intr=45`, title on the poster for seconds).
    ///
    /// Chosen over the narrower "stop counting the corrector's OWN scrolls as motion": attribution
    /// only covers the half of the loop we issue. The focus engine's counter-reveal is real motion
    /// from anyone's point of view, and it was the other half. A ceiling covers both by
    /// construction and needs no attribution at all.
    ///
    /// 2.5s is comfortably longer than a correction plus its settle (0.25 + 0.25, twice over, plus
    /// the 0.7s gate) so a rest that IS fixable is always fixed first, and short enough that the
    /// tester never sees the "title painted on the poster for many seconds" the device video shows.
    ///
    /// **Worst case, stated honestly (Codex Wave 9 r2): `fadeMaxDefer + fadeRecheckFloor` — 2.6s.**
    /// This is a ceiling on when the next CHECK may run, not a timer that fires on its own, so the
    /// bound is the ceiling plus one wake-up interval. `scheduleFadeCheck` now sleeps the SMALLER
    /// of the motion remainder and the ceiling remainder, which is what keeps that second term at
    /// the floor; before it slept the motion remainder unconditionally and a title armed at 2.4s
    /// still waited another 0.7s, making the real bound 3.2s while this comment claimed 2.5s.
    private static let fadeMaxDefer: TimeInterval = 2.5

    /// Wave W5 (BUG-87). How long a title's FIRST reading is held before it may arm the belt.
    ///
    /// The tester's build-117 report: on his first launch of the build the row title disappeared
    /// entirely and a relaunch fixed it. The mechanism is in `updateFade`'s arm path — a title's
    /// very first `Reading` (`previous == nil`) arms immediately when it is a `hideCandidate`, by
    /// design, so a title that mounts already-clipped does not wait for a transition that already
    /// happened. What that design assumed is that the first reading describes a FINAL layout. On a
    /// cold launch it does not: rows realize lazily, the hero publishes its height, the catalog
    /// fan-out lands, and a title measured in the middle of that can read as deeply clipped for one
    /// pass. It then fades 0.7s later — and on an untouched Home nothing re-fires geometry, so
    /// there is no `showAgain` to bring it back. Permanent, until the process restarts.
    ///
    /// The fix is a grace, not a threshold change: the first reading records and schedules one
    /// re-derivation, and only the SECOND reading may arm. A title that is genuinely broken loses
    /// this much time and no more — 0.5s, comfortably inside `fadeDelay` (0.7), so the worst case
    /// a viewer can see is the same "title on the artwork briefly, then hidden" as before with an
    /// extra half second on it, and the `fadeMaxDefer` ceiling is measured from the first
    /// unacceptable reading either way, so the terminal bound is unchanged.
    private static let firstReadingGrace: TimeInterval = 0.5
    /// Wave W5. Cadence of the recovery watchdog's re-derivations while the title is hidden.
    ///
    /// Recovery is measurement-driven (`showAgain`), and the whole BUG-87 failure is a title hidden
    /// on a layout that then finishes settling with nothing left to fire a measurement. One bump a
    /// second re-derives from live geometry and un-fades through the ordinary path if the rest is
    /// now fine — no new recovery logic, just a heartbeat for the existing one.
    private static let watchdogInterval: TimeInterval = 1
    /// …and its bound. Five ticks is five seconds of re-checking after a fade, which covers a cold
    /// launch's remaining settling with room to spare; past that the geometry is what it is and a
    /// title still hidden is hidden because the rest is genuinely bad, not because nothing looked
    /// again. Bounded rather than perpetual on purpose: an unbounded 1Hz state write on every
    /// hidden title is exactly the ambient churn the BUG-19/41 rule exists to forbid, and any real
    /// change after that window produces a geometry pass of its own.
    private static let watchdogMaxTicks = 5

    /// The two Appearance settings the lift allowance branches on, as REACTIVE inputs (Codex r10
    /// P2). `@AppStorage` rather than the bare `UserDefaults` reads the computation used to do on
    /// its own: those only ran when a geometry pass happened to run, so toggling either setting
    /// and returning to a Home that had not scrolled left `PinnedRowSettle.clearances` describing
    /// the previous mode indefinitely — a correction aimed at the wrong target and a belt judging
    /// against the wrong threshold, until something moved.
    ///
    /// A change re-evaluates this modifier's body (no remount — deliberately NOT part of the style
    /// gate's `styleKey`, for the same reason `isFocused` is not: a toggle must not discard
    /// `slide`/`faded` and snap the title). `onChange` below then recomputes from cached geometry
    /// and republishes, which is what actually restores coherence — a body re-evaluation alone is
    /// not guaranteed to re-run the geometry transform.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// BUG-87 rc12 follow-up A/B (`AboutSettingsPane`'s "No Zoom Row Reach" toggle). OR'd with
    /// `PinnedRowTitle.reachHoldsLiftKnob` in `focusMode` below — see that static's doc for why the
    /// bare `@AppStorage` read alone would miss a UI test's launch argument.
    @AppStorage(PinnedRowTitle.noZoomReachHoldsLiftKey) private var noZoomReachHoldsLift = false

    /// Last geometry this title measured plus its live focus state, so an out-of-band trigger — a
    /// focus-mode change, or the corrector's stand-down — can re-derive a full `Reading` with no
    /// new geometry pass. A reference box, not `@State`: the geometry is written on every
    /// measurement, and a state write there would invalidate per frame. See `TitleTrackingCache`
    /// for why `isFocused` has to live in it too.
    @State private var tracking = TitleTrackingCache()

    private var focusMode: PinnedRowTitle.FocusModeFlags {
        PinnedRowTitle.FocusModeFlags(noZoom: noZoomOnFocus,
                                      accentRing: accentFocusRing,
                                      reachHoldsLift: noZoomReachHoldsLift || PinnedRowTitle.reachHoldsLiftKnob)
    }

    func body(content: Content) -> some View {
        // Hoisted to locals so the geometry closures below capture two plain CGFloats instead of
        // this (view-isolated) modifier — the same rule the probe already follows for `rowKey`.
        let clampArtworkHeight = artworkHeight
        let clampReach = cardTopReach
        let clampCaption = captionVisible
        let rowFocused = isFocused
        let rowTreatment = treatment
        let liftMode = focusMode
        // Wave W5: hoisted like every other closure input so the `of:` transform captures a plain
        // Int rather than this (view-isolated) modifier. Reading it HERE is also what makes a bump
        // re-run the transform at all — the closure is rebuilt with the new value on the body
        // re-evaluation the bump causes.
        let tick = remeasureTick
        return content
            // Belt: render-time only (opacity changes no geometry), so the measurement feeding it
            // cannot be perturbed by it — the same invariant `visualEffect` buys for the slide.
            .opacity(faded ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: faded)
            // ALL offsetting stays inside `visualEffect` (Codex gate 1, round 2): a plain
            // `.offset` participates in the coordinate conversions the geometry observer below
            // uses, so measuring a view shifted by the state it feeds is a feedback loop that
            // settles half-clipped (measured clip = true clip − applied slide). `visualEffect`
            // applies at render time and is invisible to geometry — the original design's whole
            // point — and its effects are animatable, so the eased `slide` state still
            // interpolates inside the `withAnimation` transaction below.
            //
            // Pre-seed branch: `onGeometryChange` only reports AFTER the first geometry pass, so
            // a title mounting already-clipped would render one frame at offset 0 and then snap.
            // Until the first measurement lands, the draw-time computation carries the offset;
            // the seed stores the same value into `slide`, so the handoff renders no change.
            .visualEffect { effect, proxy in
                effect.offset(y: hasSeeded
                    ? slide
                    : PinnedRowTitle.slide(proxy, artworkHeight: clampArtworkHeight, cardTopReach: clampReach))
            }
            // Codex r10 P2: caches the raw geometry a `Reading` is derived from, so a focus-mode
            // toggle — which moves nothing and so may never produce another geometry pass — can
            // still recompute one. Deliberately a SEPARATE observer: `visibleMinY` changes every
            // frame during a scroll, and folding it into the `Reading` above would make that
            // observer fire per frame for every visible row, which is exactly the churn its own
            // doc forbids. This action only writes two CGFloats into a reference box — no SwiftUI
            // invalidation, no state.
            .onGeometryChange(for: PinnedRowTitle.TitleGeometry?.self, of: { proxy in
                guard let visible = PinnedRowTitle.visibleBounds(proxy) else { return nil }
                return PinnedRowTitle.TitleGeometry(visibleMinY: visible.minY,
                                                    titleHeight: proxy.size.height)
            }, action: { newValue in
                if let newValue { tracking.geometry = newValue }
            })
            // Wave W5: the value type is `TickedReading?`, not `Reading?` — see that type's doc for
            // why a tick has to ride along. The `TitleGeometry` observer ABOVE deliberately does
            // not read `tick`: it runs on every scroll frame for every visible row, and adding a
            // per-bump identity to it would spend the churn budget the BUG-19/41 rule protects.
            .onGeometryChange(for: PinnedRowTitle.TickedReading?.self, of: { proxy in
                guard let reading = PinnedRowTitle.reading(proxy,
                                                           artworkHeight: clampArtworkHeight,
                                                           cardTopReach: clampReach,
                                                           captionVisible: clampCaption,
                                                           rowIsFocused: rowFocused,
                                                           treatment: rowTreatment,
                                                           mode: liftMode) else { return nil }
                return PinnedRowTitle.TickedReading(tick: tick, reading: reading)
            }, action: { oldTicked, newTicked in
                // Wave 4 item 6: a nil reading is "couldn't measure" (the enclosing scroll view
                // hasn't resolved this pass — e.g. a mixed-shape row's lazy relayout mid-settle),
                // never "measured 0". Assigning 0 here would un-park a correctly-slid title for a
                // frame and then heal back — the clipped-title flash class. Hold `slide` at
                // whatever it already is and wait for the next real measurement.
                //
                // This must NOT touch `hasSeeded`: if a nil precedes the very first real
                // measurement, that measurement is still the FIRST one this modifier has ever
                // seen and must still take the seed branch below (store directly, no animation) —
                // skipping the whole action on nil, rather than only skipping the assignment,
                // is what keeps that guarantee for free.
                guard let newTicked else { return }
                // Unwrapped once here so every line below reads exactly as it did before Wave W5
                // wrapped the observer's value — the tick is plumbing, not a measurement.
                let oldValue = oldTicked?.reading
                let newValue = newTicked.reading
                // Seeding must be recorded even when the first measurement equals the initial 0 —
                // otherwise the first REAL change would take the unanimated seed path and snap,
                // which is the exact defect this modifier exists to remove.
                let isFirst = !hasSeeded
                if isFirst || reduceMotion {
                    // Store BEFORE flipping `hasSeeded` so the frame that switches paths already
                    // carries the measured value in `slide`.
                    slide = newValue.slide
                    hasSeeded = true
                } else if slide != newValue.slide {
                    withAnimation(.easeOut(duration: 0.22)) { slide = newValue.slide }
                }
                updateFade(previous: oldValue, current: newValue)
                // Hand this row's measured clearances to the settle re-reveal, which sizes its
                // correction against the FOCUSED card's artwork intrusion (`slide − focused`) and
                // can only measure the row, not the title inside it. Keyed by row, constant per
                // row, and a plain static write — no SwiftUI invalidation. A row that has never
                // published one is never corrected (see `PinnedRowSettle.settlePlan`), which is
                // the fail-safe reading: no measured title means no title to protect.
                PinnedRowSettle.noteClearances(rowKey: rowKey, clearances: newValue.clearances)
            })
            // Codex r10 P2: the settings toggle that moves nothing. A body re-evaluation alone is
            // not enough — it does not guarantee the geometry transform re-runs — so recompute the
            // Reading from cached geometry and push BOTH halves through: the belt's verdict (the
            // fade threshold moved) and the row's clearance (the corrector's target moved).
            .onChange(of: liftMode) { _, newMode in
                republishForModeChange(newMode)
            }
            // Codex Wave 9 r1: this title's belt state dies with the view. A faded title that is
            // evicted (lazy recycling, leaving Home, a theme `.id()` swap) never passes back
            // through `showAgain`, so nothing else would ever drop its key — see
            // `PinnedRowSettle.clearBeltFaded` for what that stranded. Bumping `fadeToken` in the
            // same breath kills any pending deferred fade check: that chain re-arms itself while
            // the page is moving, so without this it could keep waking up for seconds after the
            // row it belongs to has gone.
            // Wave 9b: subscribe to the corrector's stand-down for THIS row, so an unfixable rest
            // is handed over the instant it is declared rather than after the belt's timers.
            .onAppear {
                // Seed the live mirror before the observer can ever fire, so a stand-down that
                // arrives before the first focus change still judges against the right clearance.
                tracking.isFocused = isFocused
                standDownObserverID = PinnedRowSettle.observeStandDown(rowKey: rowKey) {
                    standDownFastPath()
                }
            }
            // Keeps the mirror current for the escaping observer above — `onChange` rather than a
            // write in `body` so this stays a side-effect-free render, matching how `liftMode` is
            // handled. See `TitleTrackingCache` for why the closure cannot read `isFocused`
            // directly (Codex Wave 9b r1).
            .onChange(of: isFocused) { _, focused in
                tracking.isFocused = focused
            }
            // Wave W5 (BUG-87): the recovery watchdog's lifetime, in one place. A hidden title
            // heartbeats a bounded re-derivation so it can find its way back through `showAgain`
            // even when nothing else will ever produce a measurement for it; an un-fade — by any
            // path, including the watchdog's own — kills the chain. Driven from `onChange` rather
            // than from the four sites that write `faded` so the two can never disagree.
            .onChange(of: faded) { _, isFaded in
                if isFaded {
                    startRecoveryWatchdog()
                } else {
                    watchdogToken &+= 1
                }
            }
            .onDisappear {
                PinnedRowSettle.stopObservingStandDown(rowKey: rowKey, token: standDownObserverID)
                fadeToken &+= 1
                // Wave W5: the same argument `fadeToken` gets here applies to both Wave W5 timers —
                // a grace bump or a watchdog tick that outlives its row is a state write against a
                // view that has gone. `sawFirstReading`/`graceHold` reset with them because the
                // grace is a per-VISIT judgment for exactly the reason `faded` below is: a title
                // coming back to a Home that has just been rebuilt is measuring a fresh layout and
                // deserves the same first-reading caution as the very first time.
                remeasureToken &+= 1
                watchdogToken &+= 1
                sawFirstReading = false
                graceHold = false
                remeasureFromWatchdog = false
                PinnedRowSettle.clearBeltFaded(rowKey: rowKey)
                // Codex Wave 9 r3: reset the LOCAL verdict too, not just the shared key. A
                // retained subtree — leaving Home without destruction — comes back with its
                // `@State` intact, so clearing only the shared set left a title still invisible
                // while every settle line reported `beltFaded=0`: an invisible title with a probe
                // swearing it was visible, and no way for the harness or a device log to tell.
                //
                // Hiding is a per-VISIT verdict, not a property of the row. It is only ever
                // justified by a rest that is on screen right now, and this row is leaving; if the
                // same bad geometry is still there when it returns, the first measurement arms the
                // belt again and it re-fires on its own schedule. Recovery is coherent in both
                // directions: the view comes back visible with the set empty, and its next genuine
                // fade computes `changed == true` and republishes `beltFaded=1`.
                faded = false
                fadeArmedAt = nil
            }
            .modifier(PinnedRowTitleProbe(rowKey: rowKey,
                                          artworkHeight: artworkHeight,
                                          cardTopReach: cardTopReach,
                                          captionVisible: captionVisible,
                                          treatment: treatment,
                                          mode: liftMode,
                                          enabled: HomeGeometryProbe.enabled))
    }

    /// Re-derives this title's `Reading` under a new focus mode, from the geometry last measured,
    /// and republishes everything downstream of it.
    ///
    /// `previous: nil` into `updateFade` is correct rather than convenient: a mode change is not a
    /// continuation of the previous arm state, it is a fresh verdict — if the new mode puts the
    /// title in the arm band it should arm now, and if it clears it, it should un-fade now.
    ///
    /// `noteClearances` is the other half, and it does more than store: a clearance that actually
    /// changed re-arms the corrector through the same backstop the late-clearance path uses, so a
    /// mode change that moves the correction target gets acted on instead of waiting for the next
    /// scroll (which, on a Home the user has just come back to, may never come).
    private func republishForModeChange(_ mode: PinnedRowTitle.FocusModeFlags) {
        // `isFocused` is read directly here, not through the box: this runs from `onChange`, i.e.
        // in a fresh body context where `self` is the current render.
        guard let geometry = tracking.geometry else { return }
        let reading = PinnedRowTitle.reading(geometry: geometry,
                                             artworkHeight: artworkHeight,
                                             cardTopReach: cardTopReach,
                                             captionVisible: captionVisible,
                                             rowIsFocused: isFocused,
                                             treatment: treatment,
                                             mode: mode)
        updateFade(previous: nil, current: reading)
        PinnedRowSettle.noteClearances(rowKey: rowKey, clearances: reading.clearances)
    }

    /// Visibility belt state machine. Two asymmetric halves, on purpose:
    ///
    ///  - RECOVERY is immediate and unconditional. The instant a measurement says the title is back
    ///    inside its budget (`showAgain`) the fade is cancelled and the title returns — a title
    ///    that had to wait to come back would read as a bug of its own.
    ///  - HIDING is deferred until the page is genuinely at REST in the bad state, and the settle
    ///    re-reveal always gets first refusal at that rest (see `fadeDelay`).
    ///
    /// Codex r2 P2-1: rest here means the SCROLL is still, not "no new measurement arrived". Those
    /// came apart once the slide saturates at the cap — `Reading` then goes byte-identical frame to
    /// frame, `onGeometryChange` stops firing, and a slow swipe that stayed in the belt's band for
    /// longer than `fadeDelay` would fade a title while the page was visibly moving. The deferred
    /// check therefore consults `PinnedRowSettle.secondsSinceMotion()` — the scroll's own
    /// last-move stamp — and re-arms instead of firing whenever the page has moved recently.
    ///
    /// Cost: arming is TRANSITION-driven (`previous` vs `current`), so a title crossing the clip
    /// edge schedules one deferred check, not one per frame, and `fadeToken` is written only on
    /// those transitions. The `stillOnScreen` term in `PinnedRowTitle.reading` confines the whole
    /// mechanism to titles still on screen — at most the one or two rows straddling the clip edge,
    /// never the whole stack above it.
    private func updateFade(previous: PinnedRowTitle.Reading?, current: PinnedRowTitle.Reading) {
        // Wave W5 (BUG-87): "has this title ever published a reading in this visit?", which is a
        // different question from `previous == nil` — a mode-change or watchdog republish passes
        // `previous: nil` deliberately (a fresh verdict, not a continuation) and must not be
        // mistaken for a first reading. Recorded before any early return so a title whose first
        // reading is perfectly healthy still spends its "first", and a LATER genuine arm is not
        // delayed by a grace it no longer needs.
        let isFirstReading = !sawFirstReading
        if isFirstReading { sawFirstReading = true }
        // Consumed here, whatever this recompute turns out to say, so the flag can never leak into
        // an unrelated later reading.
        let fromWatchdog = remeasureFromWatchdog
        if fromWatchdog { remeasureFromWatchdog = false }
        if current.showAgain {
            fadeArmedAt = nil
            graceHold = false
            if faded {
                fadeToken &+= 1          // cancels any pending hide
                faded = false
                // Wave W5: name the watchdog when it is the thing that got the title back. This is
                // the ONLY way a device log or the harness can tell "the layout settled and a
                // normal geometry pass recovered it" from "nothing was ever going to fire again and
                // the heartbeat found it" — which is the whole BUG-87 failure mode, and the line a
                // future regression would stop printing.
                beltLog(fromWatchdog ? "watchdog recover" : "recover", current)
                PinnedRowSettle.noteBeltFaded(rowKey: rowKey, faded: false)
            } else if previous?.hideCandidate == true {
                fadeToken &+= 1
            }
            return
        }
        // Not acceptable any more. Stamp WHEN that started, once per episode — the terminal ceiling
        // is measured from here, not from the latest arm, so a title flickering between the arm
        // band and the hysteresis band cannot defer itself indefinitely.
        if fadeArmedAt == nil { fadeArmedAt = Date() }
        guard current.hideCandidate else {
            // The hysteresis band between the two edges: hold whatever state we have, but drop a
            // pending hide — this title is no longer in a state worth hiding for.
            if previous?.hideCandidate == true { fadeToken &+= 1 }
            // Wave W5: and drop the grace hold with it. The title left the arm band, so the next
            // entry into it is an ordinary transition and arms on its own.
            graceHold = false
            return
        }
        guard !faded else { return }
        // Wave W5 (BUG-87) — the FIRST-READING GRACE. A title's very first reading of a visit may
        // not arm, however bad it looks: on a cold launch it is routinely measured mid-fan-out, and
        // the hide that follows is unrecoverable because an untouched Home fires no further
        // geometry (see `firstReadingGrace`). Record, hold, and force one re-derivation; the second
        // reading decides for real.
        if isFirstReading {
            graceHold = true
            beltLog("grace", current)
            scheduleFirstReadingRemeasure()
            return
        }
        // Already armed by an earlier transition (or already hidden) — the standing deferred check
        // owns it from here. `graceHold` is the one exception, and it has to be: the grace above
        // already saw `hideCandidate`, so the deferred reading arrives with
        // `previous?.hideCandidate == true` and the transition test alone would swallow the arm the
        // grace deferred. (`previous == nil` still takes the arm path for every other caller — a
        // mode-change republish is a fresh verdict and arms immediately if it warrants one.)
        guard graceHold || previous?.hideCandidate != true else { return }
        graceHold = false
        beltLog("arm", current)
        scheduleFadeCheck(after: Self.fadeDelay)
    }

    /// Wave W5 (BUG-87). Forces one re-derivation of this title's `Reading` after the grace, so the
    /// SECOND reading — the one that may actually arm the belt — is taken off a settled layout.
    ///
    /// Two mechanisms, deliberately both, because they fail in different places:
    ///  - `remeasureTick` re-runs the `of:` transform against a LIVE `GeometryProxy`, which is the
    ///    reading we actually want. It depends on SwiftUI re-evaluating the transform on a state
    ///    change, which it does, but it is not a documented guarantee.
    ///  - the cached-geometry republish is the same path `republishForModeChange` already uses and
    ///    needs no geometry pass at all. It re-derives from whatever the `TitleGeometry` observer
    ///    last saw — which, on a cold launch, IS the settled layout, because settling is a geometry
    ///    change and that observer fires on every one of them.
    ///
    /// Running both cannot double-arm: whichever gets there first clears `graceHold` and the other
    /// finds `previous?.hideCandidate == true` and declines. And `scheduleFadeCheck` bumps
    /// `fadeToken`, so even a genuine double would leave exactly one live deferred check.
    private func scheduleFirstReadingRemeasure() {
        remeasureToken &+= 1
        let token = remeasureToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstReadingGrace) {
            guard token == remeasureToken, !faded else { return }
            remeasure(fromWatchdog: false)
        }
    }

    /// Wave W5 (BUG-87). The recovery heartbeat for a hidden title — see `watchdogInterval` /
    /// `watchdogMaxTicks`. Started and stopped by the `onChange(of: faded)` in `body`, so there is
    /// exactly one authority on when it runs.
    private func startRecoveryWatchdog() {
        watchdogToken &+= 1
        scheduleWatchdogTick(token: watchdogToken, remaining: Self.watchdogMaxTicks)
    }

    private func scheduleWatchdogTick(token: Int, remaining: Int) {
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogInterval) {
            // Un-faded (by this chain or any other), or superseded by a newer chain — either way
            // this tick is stale. `faded` is the load-bearing half: the watchdog exists only to
            // un-hide, so it must never run against a visible title.
            guard token == watchdogToken, faded else { return }
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] belt %@",
                      "watchdog tick row=\(rowKey) remaining=\(remaining - 1)")
            }
            remeasure(fromWatchdog: true)
            scheduleWatchdogTick(token: token, remaining: remaining - 1)
        }
    }

    /// The shared body of both Wave W5 timers: force a live re-derivation, and republish from
    /// cached geometry as the belt-and-braces path (see `scheduleFirstReadingRemeasure`).
    ///
    /// `previous: nil` into `updateFade` matches `republishForModeChange`'s reasoning exactly — this
    /// is a fresh verdict rather than a continuation of an arm state, which is precisely what both
    /// callers want (arm now if it still warrants it, un-fade now if it does not).
    private func remeasure(fromWatchdog: Bool) {
        remeasureFromWatchdog = fromWatchdog
        remeasureTick &+= 1
        guard let geometry = tracking.geometry else { return }
        let reading = PinnedRowTitle.reading(geometry: geometry,
                                             artworkHeight: artworkHeight,
                                             cardTopReach: cardTopReach,
                                             captionVisible: captionVisible,
                                             rowIsFocused: tracking.isFocused,
                                             treatment: treatment,
                                             mode: focusMode)
        updateFade(previous: nil, current: reading)
        PinnedRowSettle.noteClearances(rowKey: rowKey, clearances: reading.clearances)
    }

    /// Fires the hide once the scroll has been still for `fadeDelay` — or once the title has been
    /// unacceptable for `fadeMaxDefer` regardless of motion, whichever comes first.
    ///
    /// Terminates three ways over: every re-arm waits at least `fadeRecheckFloor`, the chain dies
    /// the moment the title leaves the arm band (`updateFade` bumps `fadeToken`) or the hide lands,
    /// and the ceiling bounds the whole episode even if the page never goes still. That last one is
    /// Wave 9(a): without it the corrector and the belt could livelock, and on hardware they did.
    ///
    /// The re-arm delay is bounded by BOTH remainders (Codex Wave 9 r2) so the ceiling is not
    /// overshot by a whole `fadeDelay` — see `fadeMaxDefer` for the arithmetic and the honest
    /// `fadeMaxDefer + fadeRecheckFloor` worst case.
    private func scheduleFadeCheck(after delay: TimeInterval) {
        fadeToken &+= 1
        let token = fadeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Superseded by a newer transition, or something already faded this title — either way
            // this scheduled check is stale.
            guard token == fadeToken, !faded else { return }
            let sinceMotion = PinnedRowSettle.secondsSinceMotion()
            let armedFor = fadeArmedAt.map { Date().timeIntervalSince($0) } ?? 0
            if sinceMotion < Self.fadeDelay, armedFor < Self.fadeMaxDefer {
                if HomeGeometryProbe.enabled {
                    NSLog("[HomeScrollProbe] belt %@",
                          "defer row=\(rowKey) sinceMotion=\(Int(sinceMotion * 1000))ms armedFor=\(Int(armedFor * 1000))ms")
                }
                // Codex Wave 9 r2: the next wake-up is bounded by BOTH remainders. Sleeping the
                // full motion remainder alone could overshoot the ceiling by up to `fadeDelay` —
                // at `armedFor = 2.4` the old form still slept 0.7s and fired at ~3.1s, so the
                // "terminal" bound was 3.2s in practice, not 2.5s. Taking the smaller of the two
                // means the chain wakes when the ceiling expires if that comes first; the floor
                // still bounds the wake-up rate, so it terminates exactly as before.
                let motionRemainder = Self.fadeDelay - sinceMotion
                let ceilingRemainder = Self.fadeMaxDefer - armedFor
                scheduleFadeCheck(after: max(min(motionRemainder, ceilingRemainder),
                                             Self.fadeRecheckFloor))
                return
            }
            // BUG-89 (rc2): the ORDINARY fire is the one belt event that does not go through
            // `beltLog` (it has no `Reading` to hand it — the timer fires off the clock, not off a
            // measurement), and it is the event the tester's Large case turns on: "the title
            // disappears on the first horizontal move and never returns". Mirrored here on the same
            // terms as `beltLog`'s — independent knob, NSLog and its tokens untouched. The
            // `defer` line above is deliberately NOT mirrored: one deferral chain can wake several
            // times per episode, which is exactly the per-frame volume this buffer must not carry.
            if PinnedRowSettleProbe.enabled {
                let margin = tracking.geometry.map { "\(Int((-$0.visibleMinY).rounded()))" } ?? "?"
                PinnedRowSettleProbe.log(
                    "belt fire row=\(rowKey) margin=\(margin)"
                        + " reason=\(armedFor >= Self.fadeMaxDefer ? "ceiling" : "rest")"
                        + " armedFor=\(Int(armedFor * 1000))ms")
            }
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] belt %@",
                      "fire row=\(rowKey) sinceMotion=\(Int(sinceMotion * 1000))ms armedFor=\(Int(armedFor * 1000))ms"
                        + " ceiling=\(armedFor >= Self.fadeMaxDefer ? 1 : 0)"
                        + " reason=\(armedFor >= Self.fadeMaxDefer ? "ceiling" : "rest")")
            }
            faded = true
            PinnedRowSettle.noteBeltFaded(rowKey: rowKey,
                                          faded: true,
                                          reason: armedFor >= Self.fadeMaxDefer ? "ceiling" : "rest")
        }
    }

    /// Wave 9b: the corrector has declared this rest unfixable, so hide NOW rather than waiting out
    /// `fadeDelay` (and possibly the ceiling behind it).
    ///
    /// The ~1-2s of title-on-the-posters the device video shows is exactly that wait. It is the
    /// right behaviour for a rest nothing has judged yet — a flash-hide on a rest a correction is
    /// about to fix would be its own defect — but once `standDown` has fired there is no such
    /// correction: it is only reached from a debounced settle, on the branches that have already
    /// concluded the rest cannot be improved. So the motion/rest gating stays on the ORDINARY path
    /// and only an explicit stand-down short-circuits it; the ceiling stays as the terminal backstop
    /// for episodes that never reach a stand-down at all (a disarmed corrector, a row whose
    /// clearance never published, a belt armed while the corrector is idle).
    ///
    /// Everything else about the belt is unchanged: still animated (the `.animation` on `faded`),
    /// still a per-visit verdict cleared on `onDisappear`, and recovery still immediate and
    /// unconditional the moment a measurement says `showAgain`.
    private func standDownFastPath() {
        guard !faded else { return }
        // Re-derive from the geometry last measured — the same cached-geometry path
        // `republishForModeChange` uses, and necessary for the same reason: a settled rest produces
        // no new geometry pass to piggyback on.
        guard let geometry = tracking.geometry else { return }
        // `tracking.isFocused`, NOT the captured `isFocused` (Codex Wave 9b r1): this closure was
        // installed at `onAppear` and froze that render's plain `let`s. A row that mounted
        // unfocused and gained focus later would otherwise be judged against the AT-REST clearance,
        // which in the lift-bearing focus modes is ~20pt more generous — enough to reject a
        // genuinely unacceptable focused title and leave it on the artwork.
        let reading = PinnedRowTitle.reading(geometry: geometry,
                                             artworkHeight: artworkHeight,
                                             cardTopReach: cardTopReach,
                                             captionVisible: captionVisible,
                                             rowIsFocused: tracking.isFocused,
                                             treatment: treatment,
                                             mode: focusMode)
        // Only hide what is actually unacceptable. A stand-down on a rest whose title is fine (or
        // fully clipped off the top, where `stillOnScreen` stands the belt down) changes nothing.
        guard reading.hideCandidate else { return }
        fadeToken &+= 1                       // cancel the pending deferred check; this pre-empts it
        if fadeArmedAt == nil { fadeArmedAt = Date() }
        beltLog("fire reason=standdown", reading)
        faded = true
        PinnedRowSettle.noteBeltFaded(rowKey: rowKey, faded: true, reason: "standdown")
    }

    /// One greppable `[HomeScrollProbe] belt …` line per state change. The belt used to log
    /// NOTHING, which is why the device pass could see the title painted on the artwork and not
    /// tell whether the belt had never armed, was deferring forever, or had fired and been undone.
    private func beltLog(_ event: String, _ reading: PinnedRowTitle.Reading) {
        // BUG-89 (rc2): the belt's state changes are the other half of the tester's report — at
        // Large his row title is visible on landing, disappears on the first horizontal move and
        // never comes back, which is a belt `arm` → `fire` with no `recover`, and nothing in the
        // settle lines says so. Mirrored into the photographable buffer INDEPENDENTLY of
        // `HomeGeometryProbe.enabled`, so the two knobs stay separable; the NSLog below and every
        // one of its tokens are untouched.
        //
        // `margin=` is derived here rather than carried on `Reading` (which deliberately holds
        // BOOLs plus `slide`/`intrusion`, so the observer does not fire per frame — see its doc):
        // `margin == -visibleMinY`, read from the same cached `TitleGeometry` the belt's own
        // recompute paths (`remeasure`, `standDownFastPath`) use. `margin=?` when nothing has been
        // cached yet, which is the honest reading and never a fabricated 0.
        if PinnedRowSettleProbe.enabled {
            let margin = tracking.geometry.map { "\(Int((-$0.visibleMinY).rounded()))" } ?? "?"
            PinnedRowSettleProbe.log(
                "belt \(event) row=\(rowKey) margin=\(margin)"
                    + " slide=\(Int(reading.slide.rounded()))"
                    + " intr=\(Int(reading.intrusion.rounded()))"
                    + " clearanceLift=\(Int(reading.clearances.focused.rounded()))")
        }
        guard HomeGeometryProbe.enabled else { return }
        NSLog("[HomeScrollProbe] belt %@",
              "\(event) row=\(rowKey) slide=\(Int(reading.slide.rounded()))"
                + " intr=\(Int(reading.intrusion.rounded()))"
                + " clearance=\(Int(reading.clearances.atRest.rounded()))"
                + " clearanceLift=\(Int(reading.clearances.focused.rounded()))")
    }
}

/// `[HomeScrollProbe] title row=… margin=… slide=… net=… cap=… intr=… intrLifted=… vh=…`, so a
/// single manual up-walk
/// MEASURES BUG-37 instead of eyeballing it, per row:
///  - `margin` — title top vs the viewport's top edge BEFORE the slide. Negative is round 8's
///    failure reproducing, and its magnitude is that rest's share of the 0–67pt envelope.
///  - `slide`  — how far this fix moved the title (0 at a true rest).
///  - `net`    — what the viewer actually sees. A negative `net` means the rest exceeded the row's
///    resolved cap. Before Wave 4 that read "the clamp needs raising"; now it is also the EXPECTED
///    reading for a deeply-clipped row, because the cap deliberately stops short of covering the
///    whole envelope rather than push the title further onto the art (see `PinnedRowTitle.maxSlide`).
///    What must still hold at a SETTLED rest is `net ≥ 0` — that is the regression to watch.
///  - `cap`    — the row's resolved clamp (Wave 4): `clearance + 9% of the artwork`, absolute-capped.
///  - `intr`   — how far the title's bottom edge is currently past the artwork's top edge, i.e. the
///    number the tester actually complained about. `≤ 0` means it is clear of the art; the design
///    budget is `artworkHeight × heroPinnedRowTitleArtIntrusionFraction`. PRE-LIFT: measured
///    against the card's RESTING artwork top.
///  - `intrLifted` / `lift` (2026-08-30) — the same number for the FOCUSED card, i.e. `intr` plus
///    the ACTIVE focus mode's lift, and that lift itself. The focus treatment raises the focused
///    card's artwork while the title stays where it is, so every device log this probe produced
///    before under-reported the intrusion on the one card the viewer is looking at (the rc1 line
///    `intr=46` was really 66 on the focused card). `lift` is 0 under "No Zoom on Focus", the
///    pixel-measured `heroPinnedRowFocusLiftAllowance` by default, and scale-derived in ring mode
///    — see `PinnedRowTitle.focusLiftAllowance`. Reported alongside so a log can be read without
///    also knowing the tester's Appearance settings.
///  - `vh`     — the rows viewport's height, the denominator every rest position is computed
///    against. Carried so a creep trace can be ATTRIBUTED rather than guessed at: a `margin` that
///    drifts at rest while `vh` holds AND `[HomeScrollProbe] pinned-hero y=…` holds means content
///    ABOVE the row is growing; a drifting `y` means the scroll offset itself never converged; a
///    drifting `vh` means the pinned hero (not the rows) is the mover.
/// Not attached at all when the knob is off, so disabled builds evaluate none of it.
private struct PinnedRowTitleProbe: ViewModifier {
    let rowKey: String
    let artworkHeight: CGFloat?
    let cardTopReach: CGFloat
    let captionVisible: Bool
    let treatment: PinnedRowTitle.RowCardTreatment
    /// Reactive focus-mode flags, so `lift=` reports the mode that is live RIGHT NOW rather than
    /// whatever the defaults said the last time geometry moved (Codex r10 P2).
    let mode: PinnedRowTitle.FocusModeFlags
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            // Captured by value so the geometry closure holds a plain String and two CGFloats
            // rather than this (view-isolated) modifier.
            let key = rowKey
            let clampArtworkHeight = artworkHeight
            let clampReach = cardTopReach
            let clampCaption = captionVisible
            let clampTreatment = treatment
            let clampMode = mode
            content.onGeometryChange(for: String.self, of: { proxy in
                guard let margin = PinnedRowTitle.rawMargin(proxy) else { return "" }
                let slide = PinnedRowTitle.slide(proxy, artworkHeight: clampArtworkHeight, cardTopReach: clampReach)
                let cap = PinnedRowTitle.maxSlide(titleHeight: proxy.size.height,
                                                  artworkHeight: clampArtworkHeight,
                                                  cardTopReach: clampReach)
                // Title bottom vs artwork top, in the same shelf-relative units the clamp uses.
                let intrusion = (Theme.Size.heroPinnedRowTitleInset + proxy.size.height + slide)
                    - (Theme.Spacing.lg + clampReach)
                // …and the same thing on the FOCUSED card, whose artwork the ACTIVE focus
                // treatment has already raised (Codex r7 P1: 0 in still mode, the measured ~20pt
                // system-lift constant by default, half the scale delta over the lockup in ring
                // mode). `lift=` is reported alongside so a device log can tell which mode
                // produced the reading without also having to know the tester's settings.
                let lift = PinnedRowTitle.focusLiftAllowance(artworkHeight: clampArtworkHeight,
                                                             captionVisible: clampCaption,
                                                             treatment: clampTreatment,
                                                             mode: clampMode)
                let intrusionLifted = intrusion + lift
                let viewportHeight = PinnedRowTitle.visibleBounds(proxy)?.height ?? 0
                return "row=\(key) margin=\(probeBucket(margin)) slide=\(probeBucket(slide)) net=\(probeBucket(margin + slide)) cap=\(probeBucket(cap)) intr=\(probeBucket(intrusion)) intrLifted=\(probeBucket(intrusionLifted)) lift=\(probeBucket(lift)) vh=\(probeBucket(viewportHeight))"
            }, action: { _, value in
                guard !value.isEmpty else { return }
                NSLog("[HomeScrollProbe] title %@", value)
            })
        } else {
            content
        }
    }
}

/// 2pt buckets. `onGeometryChange` only fires when its value CHANGES, so quantizing turns a
/// per-frame scroll animation into a handful of lines per row per hop while staying an order of
/// magnitude finer than the 40–67pt envelope being measured.
private nonisolated func probeBucket(_ value: CGFloat) -> Int {
    Int((value / 2).rounded()) * 2
}

// MARK: - Pinned row SETTLE RE-REVEAL (rc1 tester report, sim-reproduced 2026-08-30)

/// Corrects the one rest the BUG-37 slide provably cannot cover: a SETTLED pinned rest whose title
/// is still clipped after the slide has saturated.
///
/// The measurement that specified this, on the FA87 sim fixture at Poster Size = **Large**
/// (2026-08-30): a focused poster row at a settled rest logs
/// `[HomeScrollProbe] title row=…recs_series_for_you margin=-86..-100 slide=72 net=-14..-28
/// cap=64 intr=46`. The row's top parks ~90–100pt UNDER the pinned clip edge, the slide saturates
/// at the absolute 72 cap, and `net` goes NEGATIVE — violating the invariant the probe's own doc
/// names as the regression to watch (`net ≥ 0` at a settled rest). At Medium the frame fits and
/// none of it fires, which is exactly the tester's "only at Large".
///
/// Why the fix has to move the SCROLL and not the title. The focusable link frame at Large is
/// `artworkHeight + 175.5` = 578.8pt; the reveal regime documented at `PosterCard.swift` (~L730)
/// parks frames of that class UNDER the clip edge instead of centring them. Once the rest is
/// 90pt short, every render-time dial is already spent: the slide is at its cap, and raising the
/// cap trades a title on the artwork for a title cut off screen (Codex 2026-08-29 P1 settled
/// that trade the other way). The row is simply in the wrong place, so the row is what moves.
/// `954d62a9` deferred exactly this ("settle re-reveal"); this is that deferred work.
///
/// **Wave G (BUG-87, beta.18) replaced the target and added two brakes.** The tester's beta.17
/// report — "the row titles are constantly trying to move back" — is this corrector, unbounded.
/// What was wrong, precisely:
///
///  - Wave 10 aimed at a POINT (`margin == 0`, the "canonical rest"). That held on the simulator
///    because the sim's focus engine TOP-anchors an over-tall link frame and rests at +22, so one
///    contraction finished the job. Hardware BOTTOM-anchors the same frame on an up-walk: the
///    recorded device rest is `margin=-99` at `vh=455`, which is `vh − H + 24` to within a point.
///    The two anchorings sit ~55pt apart and NO point target with a ±4 dead zone can hold both.
///  - The 2-nudge budget counted CONSECUTIVE FAILURES and `deficit == 0` refunded it. A landed
///    correction produces exactly `deficit == 0`, so the budget handed itself back every time it
///    was successfully spent. The loop then needed nothing exotic: correct → land → refund → the
///    engine re-reveals the frame to its own anchoring → motion → arm → correct, forever. The
///    session self-disarm could never accumulate against it either, because a focus change nils
///    `pendingVerification` and any reflow VOIDs it.
///  - The belt could not mask it: at the corrected rest the title is fine, so it shows again. The
///    user therefore sees the title MOVE rather than disappear, which is the report verbatim.
///  - Independently, `protectedBottom` ignored the shelf's own 24pt bottom padding, so every
///    downward correction at Large stopped ~11.5pt short and stood down on `bound` — the
///    "almost, give up, the engine moves it, almost…" cadence.
///  - And a MOTIONLESS geometry pass still armed a settle whenever nothing was armed, so lazy row
///    realization on a row-heavy Home fired corrections with no scroll behind them at all.
///
/// The mechanism now, and why it terminates:
///
///  1. **It only ever runs from a settled rest, and only after real motion.** `noteScroll` arms a
///     single debounce and now REQUIRES motion to arm at all; a real scroll (motion beyond
///     `driftTolerance`, or a path length beyond `motionWindowDisplacement`) re-arms it, so
///     nothing fires while the page moves and nothing fires when the page has not moved. The four
///     backstops that legitimately arm without motion (`invalidateEpoch`, `noteClearances`,
///     `noteBeltFaded`, and `setCovered(false)`'s uncover) call `rearm(source:)` directly and are
///     unaffected; `armSrc=` on the settle line names which one did. Every one of them hands its
///     token to the registered `scheduler` — arming without scheduling leaves a settle nobody will
///     ever run, which is the class of bug Codex r6 found on the clearance path and rc10 found on
///     the uncover path.
///  2. **The target is a legibility BAND, not a point.** Both edges come from the row's own
///     geometry:
///
///         bandLow  = −clearance.focused
///         bandHigh = min(heroPinnedRowTitleInset,
///                        heroPinnedRowTitleInset + vh − lockupExtent − settledCushion)
///
///     `bandLow` is BUG-84's edge — the title's bottom exactly on the FOCUSED card's artwork top,
///     with the focus lift already subtracted into `clearance.focused`. `bandHigh` is the title's
///     own inset (past it the previous row starts showing under the fold, BUG-89's contrast) met
///     with "the focused card's lockup still finishes inside the viewport with the cushion under
///     it". `inBand` carries ±2 of slack, the probe's own quantization. Outside the band the
///     correction aims one dead zone INSIDE the nearer edge, never past the midpoint, so a landed
///     rest cannot sit on a boundary and re-trigger on noise; inside it, `err` and `deficit` are 0
///     and nothing happens. An EMPTY band (`bandHigh < bandLow`) is unsatisfiable geometry:
///     `standDown(reason: "unsatisfiable")`, `unsat=1`, and the belt owns it.
///
///     Verified numbers, uniform poster rows, No Zoom (`clearance.focused = 26`,
///     `lockupExtent = lg 24 + topReach 88 + artwork + captionChrome 43.5`):
///
///         Size     artwork   lockupExtent   vh       band           engine rest      corrections
///         Small    275.0     430.5          455      [−26, 48  ]    +24 … +28.5      0
///         Medium   330.0     485.5          455      [−26,  9.5]    −26.5            0
///         Large    403.3     558.8          523.3    [−26,  4.5]    sim +24          1 × 23.5
///         Large    403.3     558.8          523.3    [−26,  4.5]    device −31.5     1 × 9.5
///
///     Medium+ 351: takes the Large dial (FEAT-39) — not separately measured above.
///
///     Large's corrected rests are Wave 10's to the point (+24 → 0.5; BUG-84 still holds because
///     the whole band is at or above `bandLow`), while Medium and Small stop being dragged to 0.
///     That is the one intended visual change: their titles now sit fully visible with a taller
///     dark band above them. A device parked 75pt deeper than the sim (−53) takes one 31pt nudge
///     to −22 and is then in band.
///  3. **A single correction is still a contraction onto its target.** Computed from the LIVE
///     sample at fire time, never from the stale measurement that armed the settle;
///     `magnitude = min(deficit, headroom, cap)`, where every bound can only SHORTEN it, never
///     invert its sign or extend it past the target. `headroom` is direction-specific and bounded
///     by REAL limits: downward by `protectedBottom` (the focused card's lockup must stay in the
///     viewport — which as of Wave G subtracts the shelf's `Spacing.lg` bottom padding as well as
///     the transparent reach band, making it exact rather than 24pt pessimistic), upward by the
///     remaining scroll range (Codex Wave 10 r2 — an unbounded upward correction on the last row
///     would ask to scroll past the end, `scrollTo` would clamp it silently, and two such MISSes
///     would set the session-wide disarm).
///  4. **A WALL-CLOCK budget that success cannot refund.** At most `maxCorrectionsPerWindow` (2)
///     corrections per row per `correctionWindow` (8s), counted from when each FIRED. This is the
///     brake the consecutive-failure counter could not be: the loop's corrections all succeed.
///     `standDown(reason: "budget")`, `budget=1`. `consecutiveNudges` survives only as the `n=`
///     field and nothing branches on it.
///  5. **A PULL-BACK detector, scoped per WALK DIRECTION (BUG-112 Item B).** Each correction
///     records the margin it was fired FROM. If the next settle for the same row lands within
///     `pullBackTolerance` of that margin inside two seconds, the correction achieved nothing and
///     repeating it would achieve nothing either: log `PULLBACK`, `standDown(reason: "pullback")`
///     so the belt hides the title within ~0.25s, and report `pullback=1` (the running total is
///     the line's own `pull=` field, `pullBack.total` across every direction). Two pull-backs in
///     one WALK DIRECTION disarm that direction, with a loud `DISARMED-PULLBACK` line, and the
///     corrector falls back to the belt for it — but a settle that then reverses direction
///     RE-ARMS: the brake belongs to the direction that fought the corrections, not to the
///     session, because BUG-112's rest asymmetry (rows parked ~100pt deeper walking UP than DOWN
///     on hardware) means the down-walk's pull-backs say nothing about the up-walk's corrections.
///     See `PullBackLedger`. The ACTION sits after the in-band branch, so a rest that landed
///     inside the band is never scored as a fight.
///
///     Worst case on a device that fights: one 0.5s nudge-and-return per row for two rows, then
///     static. Before Wave G: unbounded.
///  6. **At most one correction in flight** (`nudgeDeadline`), and **focus changes abandon it**. A
///     new focused row replaces the measurement, ends the epoch and clears `lastCorrection`; focus
///     leaving the rows clears it outright, so a correction planned for one row can never land on
///     another. That includes TOKENS already scheduled: `invalidateEpoch` bumps `generation`, so a
///     debounce armed for the old row cannot fire against the new row's not-yet-settled
///     measurement, and it re-arms a fresh settle so the new row gets its own full `settleDelay`
///     (Codex r3 P2-2). The tracked focus covers a catalog row's trailing See All tile too, which
///     is part of the row and needs the same correction (Codex r3 P2-1). The per-row WINDOW BUDGET
///     deliberately does NOT reset on a focus change: it is keyed by row and its whole purpose is
///     to outlive the epoch churn that refunded the old counter.
///  7. **It self-disarms if it is ever wrong.** Each correction records where it asked the scroll
///     view to land; the next settle checks. Two misses and the whole mechanism switches off for
///     the session with a loud log line, leaving beta.15 behavior plus the belt. Only a correction
///     whose own epoch is still current can testify: a focus change voids the outstanding
///     verification (`invalidateEpoch`), and a content reflow between fire and check voids it too
///     — otherwise a D-pad move or a lazy row realization would be counted as evidence against the
///     scroll API and two of them would disarm the session (Codex r1 P2, both seen in a sim run).
///
/// Two earlier targets are recorded because both were wrong in instructive ways: gating on raw
/// `margin` was Codex r1 P1 (it fired on already-clean `margin=-25 net=0` rests), and gating on
/// PRE-LIFT intrusion was Codex r4 P1 (its fixpoint still left the focused card's artwork ~20pt
/// under the title). The band subsumes both — every margin in it clears the FOCUSED card's
/// artwork by construction.
///
/// **The handoff, and why it cannot livelock (Wave 9(a), device pass on the Living Room ATV).**
/// Some rests are simply UNSATISFIABLE: hardware parks rows deeper than the simulator does
/// (tab-bar occlusion, the BUG-66 family — device `margin=-99 rowB=480` against sim `-25 / 404` at
/// the same `vh=455`), and a Large focusable frame taller than the effective viewport cannot be
/// made to show its title band AND its card at once. No amount of correcting fixes that; the
/// visibility belt (`PinnedRowTitleTracking`) is the terminal fallback, and the corrector's job is
/// to get out of its way.
///
/// It did not, at first, and the failure is worth keeping because it was a genuine LIVELOCK rather
/// than a wrong number. The device trace ran `nudge=19 bound=19 n=1`, then `n=2`, then handed its
/// budget straight back and started over — because a transient unmeasurable geometry pass (lazy
/// row realization, `contentH` climbing 17449→20650 across the walk) used to `clear` the focused
/// row, which ends the epoch and resets `consecutiveNudges`. Each re-fired correction animated for
/// 0.25s and stamped `lastMotionAt`; the reveal pulled the rest back to the same `margin=-99`; and
/// the belt's rest-gate never saw its 0.7s of stillness, so a title sat on the artwork for as long
/// as the tester watched. The disarm that should have noticed corrections weren't landing was
/// itself neutralized — the same content growth VOIDed every verification, so no MISS was counted.
///
/// Three changes closed it, and each is sufficient on its own for a different reason:
///   - `MeasurementReport.unmeasured` HOLDS instead of clearing, so the stand-down sticks. This is
///     the root cause; the rest are belt and braces.
///   - `standDown` records the handoff in the log, so the trace shows the corrector yielding — and,
///     as of Wave 9b, PERFORMS it: it notifies that row's belt directly, which hides the title
///     immediately instead of leaving it to time out. Device frame analysis (2026-08-31) showed the
///     Wave 9 fix working but with the timers visible — ~1-2s of title painted across the posters
///     at every deep rest before it vanished. That wait is right for a rest nothing has judged yet
///     and pure latency for one the corrector has just given up on, and `standDown` is only ever
///     reached from a debounced settle on a branch that has already concluded the rest cannot be
///     improved, so an immediate hide cannot pre-empt a correction that would have fixed it.
///   - `PinnedRowTitleTracking.fadeMaxDefer` bounds the belt's motion deferral absolutely. This is
///     the liveness guarantee: the belt fires within `fadeMaxDefer + fadeRecheckFloor` (2.6s) of
///     the title becoming unacceptable NO MATTER what the corrector, the focus engine, or lazy
///     layout are doing, so no future interaction between them can starve it again. The extra
///     `fadeRecheckFloor` is real and deliberate — the ceiling gates a scheduled CHECK rather than
///     firing a timer of its own, so the bound is the ceiling plus one wake-up interval.
///
/// Wave G adds the fourth: the budget and the pull-back detector both stand down, so a device that
/// fights corrections reaches the belt in two attempts instead of never.
///
/// The creep this also disposes of. The same sim trace shows `margin` drifting ~2pt per probe
/// tick at "rest" (−86 → −100 over ~600ms with no input), i.e. the rest never actually settles.
/// That drift is NOT produced by anything in this file: the slide is saturated at the cap, so
/// `PinnedRowTitleTracking` writes no state and its `visualEffect` is invisible to geometry by
/// construction (Codex gate 1, round 2) — there is no title-side feedback loop left to break. What
/// remains are three EXTERNAL movers, and the probe now carries the fields that tell them apart
/// (`vh=` here, `y=` on the `[HomeScrollProbe] pinned-hero` line): a scroll animation that never
/// converged (`y` drifts), content above the row still relaying out (`y` and `vh` hold, `margin`
/// drifts), or the pinned hero itself resizing (`vh` drifts — ruled out by reading, the header is
/// a fixed `heroCarouselHeightPinned` frame). Whichever it is, the drift is made HARMLESS here
/// rather than chased: `noteScroll` treats a sub-`driftTolerance` STEP as stillness, so a crawl
/// still produces exactly one settle instead of re-arming the debounce forever, and the correction
/// is computed from the LIVE measurement at fire time, not from the stale one that armed it. A
/// creep that outlives the correction is bounded three ways now: the band is 30pt wide at Large
/// and 74 at Small, so ordinary drift never leaves it; the wall-clock budget caps what a drifting
/// rest can cost; and a motionless pass no longer arms anything at all.
///
/// **The settle line** (`[HomeScrollProbe] settle …`, mirrored into the DEBUG `debug_pinned` AX
/// probe the UI tests read). Append-only by contract — test47/test48/test58/test61/test63 parse
/// it — and every field is `key=value`, order not significant to any of those parsers (they all
/// scan for an exact key; none reads this line positionally). That said, the order below is the
/// ACTUAL order the code emits, kept accurate deliberately (see the placement rule after the
/// block) so this comment can be trusted as a map of the real line rather than an aspirational one:
///
///     row= margin= net= vh= rowB= protB= y= inset= beltFaded= beltFadeReason=
///     rowH= last= lastRowShaped= prevHidden= corrN= pull= pbDisarm= seq= armSrc= regime= fits=
///     dir= rearm=
///     clearance= clearanceLift= clearanceLiftRaw= lift= intr= intrLifted= err= deficit=
///     bandLo= bandHi= inBand=
///     [ nudge= bound= roomUp= n= | nudge=0 <outcome> ]
///
/// where `<outcome>` is one of `clearance=?`, `budget=1`, `unsat=1`, `pull=N`, `disarmed=1`,
/// `knobDisarm=1`, `inflight=1`, `pullback=1`, `endOfContent=1 room=`, `bound=`, `room=`, or
/// nothing at all for a rest that is in band. `seq` is a monotonic settle counter (an idle sample whose `seq` climbs
/// with nobody touching the remote is BUG-87 reproducing); `armSrc ∈ scroll|epoch|clearance|belt|
/// retry|external` names what armed it; `corrN` is this row's corrections inside the window. The
/// clearance-dependent trio (`bandLo`/`bandHi`/`inBand`) is absent on a `clearance=?` line for the
/// same reason `deficit=` is — the band cannot be computed before the row's title has measured
/// itself.
///
/// Wave W5 (BUG-89) appended `regime=` and `fits=`: which geometry regime this rest was measured
/// under (Home's `plan.regimeKey`, `-` when no host has published one) and whether that regime's
/// frame fits the rows viewport. A correction fired while `fits=1` also appends the bare token
/// `UNEXPECTED-WITH-FIT` and writes a loud line of its own — with a fitting frame both band edges
/// are satisfiable by construction, so a correction there is a device-anchoring surprise rather
/// than routine work.
///
/// **Where a new field goes.** BUG-112 (Item B) appended `dir=` and `rearm=` right after `fits=` —
/// not at the very end of the line, and that placement is deliberate, not a shortcut. A NEW field
/// describing this rest's WALK (which row, what offset, what geometry regime, and now which
/// direction) belongs with that group, inserted right after `fits=`, before the clearance block;
/// nothing existing moves. The clearance/band fields and the bracketed `<outcome>` tail stay LAST
/// on purpose and are never where a new field lands: they are the branch-specific fields that
/// identify what THIS PARTICULAR settle's plan resolved to — whether a correction fired, why one
/// didn't, how far short it landed (`disarmed=1`, `lastRowShaped=1 room=`, `pullback=1`, …) — and
/// several call sites and every UI test that reads this line treat it as a suffix (tailing the
/// fields after `inBand=`, reading whichever `<outcome>` token is present last). Splitting that
/// tail with an unrelated field would make "the last thing on the line" stop meaning "how this
/// settle resolved."
///
/// Storage is plain static rather than `@State` for the same reason `HomeScrollProbeRest`'s is:
/// every writer is a SwiftUI geometry callback on the main thread, and a state write here would
/// invalidate Home on every scroll frame — the corrector must not perturb the geometry it reads.
enum PinnedRowSettle {
    /// The focused pinned row's frame, in the rows viewport's own coordinates.
    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated struct Measurement: Equatable, Sendable {
        /// Which row's cards hold focus. Doubles as the epoch key for the oscillation guard.
        var rowKey: String
        /// The row's top edge relative to the viewport's top edge (negative = above the clip edge).
        var rowTop: CGFloat
        var rowHeight: CGFloat
        var viewportHeight: CGFloat
        /// Distance from the row's TOP edge to the FOCUSED card's lockup BOTTOM, for rows that can
        /// state it more precisely than their own frame does (Codex r11 P2-2).
        ///
        /// nil — every uniform-card row (catalog, Continue Watching, Upcoming) — means the row's
        /// own bottom already IS the focused card's lockup bottom plus the transparent chrome, so
        /// `protectedBottom` derives it exactly as before.
        ///
        /// The one row that needs this is the MIXED-SHAPE collection row. Its height comes from
        /// `shelfMinHeight`, i.e. the TALLEST folder tile, while its `LazyHStack` is top-aligned in
        /// pinned mode — so a focused square or landscape tile ends far above the row's bottom
        /// edge. Bounding that correction by the row's bottom reported no room at all and refused a
        /// correction the focused tile could have absorbed completely, leaving the belt to hide a
        /// title that never needed hiding. Note the approximation runs the WRONG way if inverted:
        /// bounding a tall focused tile by a short one's extent would push real artwork off the
        /// fold, which is why this is the focused tile's own extent and not the row's shortest.
        var focusedLockupExtent: CGFloat?

        /// Whether this row is the LAST one in Home's pinned rows list (BUG-89). Published through
        /// `EnvironmentValues.pinnedRowIsLast`, which `HomeView` sets on the `ForEach(model.rows)`
        /// content; false for every non-Home host. Diagnostic here rather than behavioural — the
        /// `endOfContent` branch stays the honest fallback, because "the scroll range is spent" is
        /// a property of the SCROLL VIEW and remains true (or not) whatever the row's ordinal says.
        /// What this buys is the ability to read a `nudge=0 endOfContent=1` line and know whether
        /// it came from the exempt row or from a mid-list row whose range had unexpectedly run out,
        /// which the corrector alone could never tell apart. See `PinnedRowEnvironment.swift`.
        var isLastRow: Bool = false

        /// BUG-87/89 (rc11), carrying the VALUE rather than a Bool since Codex r2 on rc11: the
        /// `rowCardLinkFrameFloor` this row's cards are carrying — i.e. the label-height floor the
        /// FRAME SHAPING applies, or 0 where shaping is inactive. Read from the same environment the
        /// cards read, so it cannot disagree with what is actually laid out.
        ///
        /// A bare Bool only said a floor EXISTED, not that it GOVERNS the focused label — see
        /// `PinnedRowSettle.lastRowExemptionApplies(lockupExtent:linkFrameFloor:)`, which needs the
        /// actual number to compare against `lockupExtent`.
        var linkFrameFloor: CGFloat = 0

        /// Whether the frame-shaping floor is active at all (`linkFrameFloor > 0`) — kept for the
        /// settle report line, whose `lastRowShaped=` field predates the value-carrying fix and is
        /// parsed by device traces as a 0/1 flag, not a magnitude.
        var lastRowShaped: Bool { linkFrameFloor > 0 }

        /// The title's top vs the viewport's top edge — the probe's `margin`, reproduced from the
        /// ROW's frame. The pinned title is an overlay at the shelf's top-leading corner inset by
        /// `heroPinnedRowTitleInset` (see `CatalogRowView`'s overlay and its three twins), and the
        /// row's VStack has no other child in pinned mode, so row top + inset IS title top.
        var margin: CGFloat { rowTop + Theme.Size.heroPinnedRowTitleInset }
        var rowBottom: CGFloat { rowTop + rowHeight }

        /// The lowest point that must stay inside the viewport for a correction to be safe: the
        /// focused card's lockup bottom. Everything below it in the row's frame is transparent —
        /// the downward reach band, and (for the row's own bottom padding) shelf chrome — and may
        /// leave the viewport without hiding any artwork.
        /// BUG-87, second defect: this used to subtract the downward reach band ALONE, and every
        /// uniform-card pinned shelf carries `.padding(.vertical, Theme.Spacing.lg)` OUTSIDE that
        /// band as well — `CatalogRowView`'s shelf (BrowseComponents, the `LazyHStack` under the
        /// pinned title), Home's Continue Watching shelf (`HomeView`), and `UpcomingRow`. So the
        /// row's frame overstated the focused card's lockup bottom by a full 24pt, every downward
        /// correction at Large stopped ~11.5pt short of what the geometry actually allowed, and the
        /// settle logged `bound=` and stood down on a rest it could have finished — the "almost,
        /// give up, the engine moves it, almost…" cadence in the tester's video.
        ///
        /// The corrected arithmetic is exact rather than approximate. At Large:
        /// `rowHeight = lg(24) + topReach(88) + artwork(403.3) + captionChrome(43.5) +
        /// bottomReach(44) + lg(24) = 626.8`, and `rowBottom − 44 − 24 − rowTop = 558.8`, which is
        /// `24 + 88 + 403.3 + 43.5` — the lockup's bottom to the point.
        ///
        /// The mixed-shape collection row still overrides with `focusedLockupExtent`, which it
        /// measures directly and which already accounts for its own (asymmetric, `.top`-only)
        /// padding — see `focusedLockupExtent` and `CollectionsUI.swift`.
        ///
        /// MUST ship with the band target and the correction budget below. On its own it hands the
        /// old point-target corrector ~24pt MORE room to chase an unreachable margin 0 with, which
        /// makes the loop worse rather than better.
        var protectedBottom: CGFloat {
            if let focusedLockupExtent { return rowTop + focusedLockupExtent }
            return rowBottom - Theme.Size.heroPinnedRowBottomReach - Theme.Spacing.lg
        }

        /// The focused card's lockup bottom measured from the ROW's top edge — the row-intrinsic
        /// height the band target is sized against, independent of where the row is currently
        /// parked. `protectedBottom` is the same quantity in viewport coordinates.
        var lockupExtent: CGFloat { protectedBottom - rowTop }
    }

    /// BUG-87/89 (rc11, Codex r2): the last-row exemption may fire only when the label floor actually
    /// GOVERNS the focused label — i.e. the label's natural lockup extent is no taller than the floored
    /// frame. A collection row in Landscape Rows mode can hold a PORTRAIT folder whose natural label
    /// (535 at Large) exceeds both the plan's landscape link frame and the floor (431): its reveal is
    /// then bounded by its own height, the frame can clip at the top-anchored rest, and the ordinary
    /// upward correction is the right answer. `lockupExtent` is the focused card's measured lockup
    /// (`Measurement.lockupExtent`, top of the row to the bottom of the focused card's caption);
    /// `linkFrameFloor` is `rowCardLinkFrameFloor`.
    ///
    /// `lockupExtent` is `Theme.Spacing.lg + topReach + artwork + captionChrome` — see
    /// `Measurement.protectedBottom`/`lockupExtent` for the uniform-row derivation and
    /// `CollectionRowView.focusedTileLockupExtent` (CollectionsUI.swift) for the mixed-shape one; BOTH
    /// start from the shelf's top `Spacing.lg` pad, so `lockupExtent` already carries it. `linkFrameFloor`,
    /// by contrast, is the floor `rowCardLinkFrameFloor` applies to the card's LABEL — the region
    /// INSIDE that same `lg` pad — so it is compared against `lockupExtent` only after adding the pad
    /// back: `lockupExtent <= lg + linkFrameFloor`. (`lockupExtent` deliberately excludes the trailing
    /// `rowCardBottomReach` below the caption — `protectedBottom`'s own header calls that band
    /// transparent and free to leave the viewport without hiding anything, so it plays no part in
    /// whether the floor governs the VISIBLE label either.) `0.5` absorbs point-rounding in the two
    /// independent derivations without opening the door to a real 1pt+ overshoot.
    nonisolated static func lastRowExemptionApplies(lockupExtent: CGFloat, linkFrameFloor: CGFloat) -> Bool {
        linkFrameFloor > 0 && lockupExtent <= Theme.Spacing.lg + linkFrameFloor + 0.5
    }

    /// The correction `settlePlan` applies, as a pure function of the four quantities that bound
    /// it. Extracted so the bound cases are unit-testable (BUG-112: on the tester's up-walk the
    /// deficit EXCEEDS `bottomRoom`, and what matters is that the shortened correction still
    /// FIRES — a correction cut by `bound` is still a correction, is still recorded in
    /// `correctionsFired`/`lastCorrection`, and is still what the pull-back detector judges).
    ///
    /// `bounded` is diagnostic only: the caller reports `bound=`/`roomUp=` exactly as before.
    nonisolated static func plannedCorrection(error: CGFloat,
                                              deficit: CGFloat,
                                              bottomRoom: CGFloat,
                                              scrollRoomUp: CGFloat)
    -> (magnitude: CGFloat, correction: CGFloat, bounded: Bool) {
        let headroom = error > 0 ? scrollRoomUp : max(bottomRoom, 0)
        let magnitude = min(deficit, headroom, Theme.Size.heroPinnedRowSettleMaxNudge)
        return (magnitude, error < 0 ? magnitude : -magnitude, magnitude < deficit)
    }

    /// What one pinned row's settle tracker saw this geometry pass (Wave 9(a)).
    ///
    /// `unmeasured` exists because collapsing it into `inactive` cost the belt its whole reason to
    /// exist on hardware: a device walk realizes lazy rows continuously (`contentH` 17449→20650
    /// across one walk), every such pass can leave the enclosing scroll view unresolved for a
    /// frame, and each of those frames used to `clear` the focused row — which ends the correction
    /// epoch and hands the corrector a FRESH nudge budget on the very next measurement. The
    /// corrector then re-fired a bound-clamped nudge forever, and each 0.25s animation stamped
    /// motion, so the belt's rest-gate never saw its `fadeDelay` of stillness. Holding on
    /// `unmeasured` is what lets the stand-down actually stick.
    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated enum MeasurementReport: Equatable, Sendable {
        case measured(Measurement)
        /// Focused, but this pass could not resolve the enclosing scroll view — hold.
        case unmeasured
        /// Nothing in this row holds focus (or it is a classic-mode row) — clear.
        case inactive
    }

    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated struct ScrollSample: Equatable, Sendable {
        var offsetY: CGFloat
        var insetTop: CGFloat
        /// Carried so a correction's verification can be VOIDED (rather than counted as a miss)
        /// when the content itself reflowed between firing and checking — see `settlePlan`.
        var contentHeight: CGFloat
        /// The rows viewport's own height, for the Wave 10 budget verification.
        var viewportHeight: CGFloat
    }

    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated struct Plan {
        /// One greppable line for the probe / the harness oracle. Always produced, correction or
        /// not — "settled clean" is as diagnostic as "settled short".
        var report: String
        /// The scroll offset to animate to, or nil when this rest needs no correction.
        var targetY: CGFloat?
        /// Set when this settle could not be resolved and must be re-checked after this many
        /// seconds instead of dropped: a still-animating correction SWALLOWED it (Codex r2 P2-2),
        /// a focus change re-armed a fresh epoch under it (Codex r3 P2-2), or the row's title had
        /// not published its clearance yet (Codex r5 P2-1). All three are otherwise lost forever:
        /// the page is stationary by then, so no further scroll geometry event will ever arm
        /// another one. Bounded by the caller's hop budget
        /// (`PinnedRowSettleRevealModifier.maxSettleHops`).
        var retryAfter: TimeInterval? = nil
    }

    /// BUG-112 (Item B) — the pull-back brake, per WALK DIRECTION.
    ///
    /// The brake this replaces (`pullBacks` / `pullBackDisarmed`) was SESSION-wide: two pull-backs
    /// anywhere and corrections were off until the next regime change. That is right about the
    /// DEVICE ("an engine that fights corrections fights all of them") and wrong about this defect.
    /// BUG-112's rest asymmetry is direction-bound — the tester's Row Settle pane shows the same
    /// rows resting `margin≈-8` walking DOWN and `-102…-108` walking back UP, and the FA87
    /// simulator shows the same shape at 22pt — so the corrections the up-walk needs are spent, and
    /// disarmed, by the down-walk that precedes them (`pull=2 pbDisarm=1` by row 3 on the sim).
    ///
    /// Direction comes from the only signal the corrector has: the sign of the scroll offset delta
    /// between two settles on DIFFERENT rows. `Measurement` carries no index (see its `rowKey`
    /// doc), but a row hop moves the offset by a row height — hundreds of points — while a
    /// correction is bounded by `bottomRoom` (≈93 at the tester's regime) and drift by
    /// `driftTolerance`. `minHopDelta` sits well above both and well below any real hop.
    ///
    /// A value type on purpose: every branch here is unit-testable without a hosting controller,
    /// which is what `settlePlan`'s own `nonisolated(unsafe) private static` state has never been
    /// (see `PinnedRowSettleDirectionTests`).
    nonisolated struct PullBackLedger: Equatable, Sendable {
        /// +1 walking DOWN the page (offset increasing), −1 UP, 0 not yet known.
        private(set) var direction = 0
        private(set) var down = 0
        private(set) var up = 0
        /// Pull-backs recorded before any direction was known. They still count toward the hard
        /// stop, but the first KNOWN direction starts with a clean per-direction count — an early
        /// pull-back with no direction attached must not silently kill the session.
        private(set) var unknown = 0
        /// How many times a direction change has RELEASED the brake. Reported as `rearm=`.
        private(set) var rearms = 0
        private(set) var lastRowKey: String?
        private(set) var lastOffsetY: CGFloat = 0

        /// Below this, an offset change between two rows is not a walk step (a correction is
        /// bounded by `bottomRoom`; drift by `driftTolerance` = 4).
        static let minHopDelta: CGFloat = 24

        /// `noteSettle`'s outcome. Two independent facts, not one — see the Codex finding this
        /// type closes: a walk can reverse (`changed`) while the LEDGER itself was never disarmed
        /// (`released == false`, e.g. an early pull-back split across `unknown` and one known
        /// direction, neither of which alone reaches `maxPullBacksPerSession`). Collapsing both
        /// into one Bool made `changed`-without-`released` invisible to every caller, including the
        /// settle-line's verify-miss latch, which needs `changed` alone: on hardware a pull-back and
        /// a verification MISS are the same event seen twice (see `settlePlan`'s call site), so the
        /// latch has evidence of a genuine reversal even when the ledger's OWN count never crossed
        /// its budget.
        nonisolated struct SettleResult: Equatable, Sendable {
            /// The walk changed direction to a new KNOWN direction (a real hop, not a re-settle on
            /// the same row and not a sub-`minHopDelta` step). True whether or not the ledger was
            /// disarmed before this settle.
            var changed: Bool
            /// `changed` was true AND it released a disarmed ledger — i.e. `rearms` was
            /// incremented. Only ever true when `changed` is; the ledger's own `disarmed` flag went
            /// from true to false as a direct result of this settle.
            var released: Bool

            static let none = SettleResult(changed: false, released: false)
        }

        var total: Int { down + up + unknown }

        /// Pull-backs recorded for the CURRENT direction.
        var count: Int {
            switch direction {
            case 1: return down
            case -1: return up
            default: return unknown
            }
        }

        /// The oscillation bound a plain reset would lose: a user who reverses repeatedly
        /// accumulates in both ledgers, and at twice the per-direction budget the corrector is off
        /// for the session whatever the direction does.
        var hardDisarmed: Bool { total >= 2 * PinnedRowSettle.maxPullBacksPerSession }

        var disarmed: Bool { hardDisarmed || count >= PinnedRowSettle.maxPullBacksPerSession }

        /// Records this settle's row and offset. `changed` is true whenever the walk turned to a
        /// new KNOWN direction — regardless of whether the ledger itself was disarmed — because that
        /// alone is evidence the caller can act on (see `SettleResult`). `released` is the narrower,
        /// original signal: a flip that also took the ledger from disarmed to armed, which is what
        /// `rearms` counts.
        mutating func noteSettle(rowKey: String, offsetY: CGFloat) -> SettleResult {
            defer { lastRowKey = rowKey; lastOffsetY = offsetY }
            guard let lastRowKey, lastRowKey != rowKey else { return .none }
            let delta = offsetY - lastOffsetY
            guard abs(delta) >= Self.minHopDelta else { return .none }
            let newDirection = delta > 0 ? 1 : -1
            guard newDirection != direction else { return .none }
            let wasDisarmed = disarmed
            direction = newDirection
            let released = wasDisarmed && !disarmed
            if released { rearms += 1 }
            return SettleResult(changed: true, released: released)
        }

        mutating func notePullBack() {
            switch direction {
            case 1: down += 1
            case -1: up += 1
            default: unknown += 1
            }
        }

        /// A regime change invalidates every measurement the counts were gathered under, including
        /// the hop the direction was derived from.
        mutating func resetAll() { self = PullBackLedger() }

        /// A host teardown invalidates the HOP (a new host's first offset is not comparable with
        /// the old one's) but not the device evidence — same reasoning `resetHostScopedState`
        /// already applies to `pullBacks`/`disarmed`.
        mutating func forgetHop() { lastRowKey = nil; lastOffsetY = 0 }
    }

    /// What one fired correction promised, so the next settle can check it landed.
    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated struct Verification: Sendable {
        var expectedY: CGFloat
        /// Content height at fire time. A reflow between fire and check moves every row under the
        /// scroll view, so the landed offset is no longer evidence about the SCROLL API — void
        /// rather than blame it (Codex r1 P2: a sim run logged exactly this, expected=909
        /// landed=941, as row realization reflowed content).
        var contentHeight: CGFloat
    }

    // `nonisolated` on every constant below, for the same reason the types above carry it: they
    // are read from this enum's `nonisolated` measurement/plan methods, which under the project's
    // default-MainActor isolation cannot see MainActor-isolated statics.
    /// How long the geometry must hold still before a rest counts as settled. Short enough that
    /// the correction reads as part of the settle rather than a delayed jump.
    nonisolated static let settleDelay: TimeInterval = 0.25
    nonisolated static let nudgeDuration: TimeInterval = 0.25
    /// A per-sample STEP at or below this is treated as stillness — see the creep paragraph in the
    /// header and `noteScroll`. 4pt sits an order of magnitude above the measured crawl
    /// (~0.4pt/frame) and an order of magnitude below a real reveal's per-frame travel, so it can
    /// neither swallow a real scroll nor be fooled by the drift.
    nonisolated static let driftTolerance: CGFloat = 4
    /// Sliding window for the CUMULATIVE motion test, and the path length within it that counts as
    /// motion — see the two-test explanation in `noteScroll` for the arithmetic that places 18pt
    /// (≈60pt/s) between the measured creep and a slow swipe's deceleration tail.
    nonisolated static let motionWindowSeconds: TimeInterval = 0.3
    nonisolated static let motionWindowDisplacement: CGFloat = 18
    /// WALL-CLOCK correction budget, per row (BUG-87). At most `maxCorrectionsPerWindow`
    /// corrections may be fired for one row inside `correctionWindow`, counted from when each was
    /// fired and never refunded by a good rest in between.
    ///
    /// This replaces `maxConsecutiveNudges`, which counted CONSECUTIVE failures and was refunded
    /// on every `deficit == 0` — and a landed correction produces exactly that, so the budget
    /// handed itself straight back on every successful nudge. The device loop needed nothing more
    /// exotic than that: correct → land → refund → the focus engine re-reveals the frame back to
    /// its own rest → motion → arm → correct, forever. A wall-clock window cannot be refunded by
    /// its own success, so the loop is bounded whatever the engine does.
    ///
    /// 8 seconds and 2 corrections is deliberately generous for legitimate use (a user walking
    /// rows gets a fresh row key, and a row re-entered after 8s of reading is a new situation) and
    /// tight enough that the worst case the tester can see is two nudges and then a static row
    /// that the belt owns.
    nonisolated static let correctionWindow: TimeInterval = 8
    nonisolated static let maxCorrectionsPerWindow = 2
    /// How close a landed rest must be to the margin a correction was fired FROM before that
    /// counts as the focus engine pulling the row back where it was — the other half of the loop.
    /// Reuses the dead zone: inside it, the row is indistinguishable from where it started, so the
    /// correction achieved nothing and repeating it would achieve nothing either.
    nonisolated static let pullBackTolerance: CGFloat = Theme.Size.heroPinnedRowSettleDeadZone
    /// Two pull-backs in one session and the corrector switches off entirely. A device that fights
    /// corrections fights all of them; carrying on would spend the rest of the session animating
    /// rows back and forth for nothing.
    nonisolated static let maxPullBacksPerSession = 2
    /// `defaults write com.nuvio.media.NuvioTV debug.pinnedSettleDisarm -bool YES`, or as a launch
    /// argument on device/CI. Turns the corrector off so a deep park stays uncorrected — the only
    /// way to reach unsatisfiable geometry now that the hero compression removes it at Large. Read
    /// once at launch, same as every other probe knob, and release-inert unless passed.
    nonisolated static let disarmedByKnob = UserDefaults.standard.bool(forKey: "debug.pinnedSettleDisarm")
    /// How far a landed correction may miss its requested offset before it counts as a miss. Wide
    /// enough to absorb a concurrent focus-driven adjustment, narrow enough to catch a scroll API
    /// that turned out to interpret the target in a different coordinate space than assumed.
    nonisolated private static let verifyTolerance: CGFloat = 24
    nonisolated private static let maxVerifyFailures = 2

    nonisolated(unsafe) private static var latest: Measurement?
    nonisolated(unsafe) private static var sample: ScrollSample?
    nonisolated(unsafe) private static var generation = 0
    nonisolated(unsafe) private static var armed = false
    nonisolated(unsafe) private static var consecutiveNudges = 0
    nonisolated(unsafe) private static var nudgeDeadline: Date?
    /// When the rows scroll view last actually MOVED. Read by the visibility belt — see
    /// `secondsSinceMotion`.
    nonisolated(unsafe) private static var lastMotionAt: Date?
    /// Per-callback displacements inside the last `motionWindowSeconds`, for the cumulative motion
    /// test in `noteScroll`. Bounded by the callback rate times the window — ~20 entries at 60Hz.
    nonisolated(unsafe) private static var motionWindow: [(at: Date, delta: CGFloat)] = []
    nonisolated(unsafe) private static var pendingVerification: Verification?
    nonisolated(unsafe) private static var verifyFailures = 0
    nonisolated(unsafe) private static var disarmed = false
    /// When each row last FIRED a correction, pruned to `correctionWindow` on every read. Bounded
    /// by (pinned rows ever focused) x `maxCorrectionsPerWindow` — a handful of `Date`s.
    nonisolated(unsafe) private static var correctionsFired: [String: [Date]] = [:]
    /// The most recent correction, and the margin it was fired FROM. The next settle compares its
    /// own margin against this to detect the focus engine pulling the row straight back — see the
    /// pull-back paragraph in the header. Cleared by `invalidateEpoch` (a different row's rest can
    /// never be evidence about this one) but NOT by a good rest, which is the whole point.
    nonisolated(unsafe) private static var lastCorrection: (rowKey: String, fromMargin: CGFloat, at: Date)?
    /// Session totals, not host-scoped: a device that pulls corrections back does it everywhere.
    /// BUG-112 (Item B) scopes the brake itself per WALK DIRECTION rather than dropping the
    /// session-wide framing entirely — see `PullBackLedger`.
    /// The margin the pull-back currently being reported was measured against — carried between
    /// the detection (which runs with the verification, so the settle line can report accurate
    /// counters) and the action below the in-band branch. Scratch storage, valid only within one
    /// `settlePlan` call.
    nonisolated(unsafe) private static var pullBackFrom: CGFloat = 0
    /// BUG-112 (Item B): the pull-back brake, now per WALK DIRECTION — see `PullBackLedger`.
    nonisolated(unsafe) private static var pullBack = PullBackLedger()
    /// Monotonic settle counter, reported as `seq=` so a harness sampling `debug_pinned` over an
    /// idle window can tell "the same settle line, still the last word" from "the corrector keeps
    /// resolving settles" without inferring it from timing. Never reset.
    nonisolated(unsafe) private static var settleSeq = 0
    /// What armed the settle currently being resolved — `scroll|epoch|clearance|belt|uncover|retry`,
    /// reported as `armSrc=`. A row that keeps producing settle lines with nothing touching the
    /// remote is the BUG-87 signature, and this names which backstop is doing it.
    nonisolated(unsafe) private static var armSource = "scroll"
    /// One-shot latch for the "a motionless sample no longer arms" probe line, so a stationary
    /// page that keeps emitting geometry callbacks writes one line and not one per frame.
    nonisolated(unsafe) private static var stillIgnoredLogged = false
    /// Set by `invalidateEpoch`, consumed by the first superseded `settlePlan` call: "a fresh
    /// settle is armed for a new row and nothing is scheduled to resolve it — please re-check".
    nonisolated(unsafe) private static var epochRearmPending = false
    /// The row whose last settle had to decline for a missing clearance (Codex r5 P2-1). Cleared
    /// the moment that row's clearance lands or its epoch ends; while set, `noteClearances` knows
    /// there is a rest waiting on it.
    nonisolated(unsafe) private static var clearanceLatePending: String?
    /// The row the corrector has most recently declared unsatisfiable — see `standDown`. Deduping
    /// key for that log line only; nothing branches on it.
    nonisolated(unsafe) private static var standDownRow: String?
    /// Rows whose title the visibility belt currently has hidden — see `noteBeltFaded`. Bounded by
    /// the number of pinned rows; membership is published by each title's own belt state.
    nonisolated(unsafe) private static var beltFadedRows: Set<String> = []
    /// Why each faded row faded — `standdown` / `rest` / `ceiling`. Diagnostic only: it puts
    /// `beltFadeReason=` on the settle line so a device log (and test48) can tell the Wave 9b fast
    /// path apart from the timer paths without inferring it from timing.
    nonisolated(unsafe) private static var beltFadeReasons: [String: String] = [:]
    /// Per-row "the corrector gave this rest up" observers — see `observeStandDown`. Keyed by row
    /// and token-scoped so a remount cannot unregister its own replacement. Registrations are tied
    /// to view lifetime, not host lifetime, so `resetHostScopedState` deliberately leaves them
    /// alone: a live title must stay reachable across a host swap, and a re-appearing one
    /// overwrites its own key.
    nonisolated(unsafe) private static var standDownObservers: [String: (token: Int, notify: @MainActor () -> Void)] = [:]
    nonisolated(unsafe) private static var standDownObserverSeq = 0
    /// Wave W5 (BUG-89). The GEOMETRY REGIME the corrector's session-wide state was accumulated
    /// under — see `noteRegimeChange`. Published by Home (`plan.regimeKey`), reported as `regime=`.
    nonisolated(unsafe) private static var regimeKey: String?
    /// Whether the CURRENT regime's frame fits the rows viewport, reported as `fits=`. Diagnostic:
    /// nothing branches on it, but a correction fired while it is true is a surprise worth a loud
    /// line (see the `UNEXPECTED-WITH-FIT` branch in `settlePlan`).
    nonisolated(unsafe) private static var regimeFits = false

    /// The reveal modifier's deferred-settle scheduler, installed by whichever pinned rows
    /// ScrollView is mounted (Codex r6).
    ///
    /// Why this exists at all: `rearm()` only arms a settle — something still has to RESOLVE it,
    /// and resolving means applying a scroll correction, which only the modifier can do (it owns
    /// the `ScrollPosition`). Every other re-arm in this file happens inside a block the modifier
    /// itself scheduled, so it can re-schedule from there. The late-clearance backstop cannot: it
    /// runs in a TITLE's geometry callback, with the page stationary and the hop chain already
    /// spent, so without this hook its `rearm()` armed a settle that nothing would ever run and
    /// the row stayed uncorrected.
    ///
    /// One slot is correct because there is exactly one pinned-mode rows ScrollView: pinned mode
    /// is a single container in `HomeView.body`, and Search/other `CatalogRowView` hosts never arm
    /// the corrector (`settleReveal` is false, and their rows carry `rowCardTopReach == 0`). The
    /// one moment two can be alive at once is a theme `.id()` swap, where SwiftUI inserts the
    /// incoming subtree before removing the outgoing one — hence the generation-scoped
    /// unregistration below, so the outgoing view's teardown cannot clear the incoming view's
    /// registration, and the probe-logged warning on overwrite so a genuinely unexpected second
    /// host shows up in a device log instead of silently double-firing.
    ///
    /// Wave W5 (BUG-89): the closure takes a DELAY as well as a token. Every pre-existing caller
    /// passes `settleDelay` and is byte-identical; `noteRegimeChange` passes 0, because a poster-size
    /// change is the one arming source that must be resolved DURING the layout change it belongs to
    /// rather than a quarter second after it — a correction that lands late is the visible "oops"
    /// snap the tester filmed, and one that lands inside the size change's own animation is not
    /// separable from it.
    nonisolated(unsafe) private static var scheduler: (@MainActor (Int, TimeInterval) -> Void)?
    nonisolated(unsafe) private static var schedulerGeneration = 0
    /// Per-row clearances, published by that row's title (`PinnedRowTitle.Reading`). Bounded by
    /// the number of pinned rows Home has ever mounted — a handful of entries, each written only
    /// when the title's measured height actually changes.
    nonisolated(unsafe) private static var clearances: [String: PinnedRowTitle.Clearances] = [:]

    /// Publishes the FOCUSED row's geometry. Called from `pinnedRowSettleTracking`, main thread.
    nonisolated static func report(_ measurement: Measurement) {
        // A different row taking focus is a fresh epoch: the oscillation guard counts CONSECUTIVE
        // failed corrections on one row, never a session total.
        // Note the ordering: `invalidateEpoch` may schedule a settle, but that settle resolves a
        // full `settleDelay` later — long after the assignment below — so it always sees the NEW
        // row's measurement, which is the one it is meant to judge.
        if latest?.rowKey != measurement.rowKey { invalidateEpoch(rowGainedFocus: true) }
        latest = measurement
    }

    /// Focus left this row (or the row left pinned mode). Scoped by key so a stale clear from a
    /// row that lost focus AFTER another gained it can't wipe the live measurement.
    nonisolated static func clear(rowKey: String) {
        guard latest?.rowKey == rowKey else { return }
        latest = nil
        invalidateEpoch(rowGainedFocus: false)
    }

    /// Publishes whether a row's title is currently hidden by the visibility belt (Wave 9(a)).
    ///
    /// Two jobs, both diagnostic. It puts `beltFaded=` on the settle line, which is what makes the
    /// handoff observable at all — from a device log or from the harness's `debug_pinned` oracle,
    /// neither of which can see an `NSLog` or a zero-opacity view. And because the belt fires long
    /// after the settle that gave up on the rest, it re-arms one settle so a fresh line actually
    /// carries the new state; without that the last report would forever predate the fade.
    ///
    /// Same guards as the other backstops: only on a real change, only when nothing else is armed
    /// (so the paths cannot stale each other's tokens), and a clean stand-down with no scheduler.
    /// The re-armed settle cannot restart the corrector — a belt fire means the rest was already
    /// declared unsatisfiable, so `deficit` is 0 or the bound is spent and it declines again.
    nonisolated static func noteBeltFaded(rowKey: String, faded: Bool, reason: String = "-") {
        let changed = faded ? beltFadedRows.insert(rowKey).inserted : (beltFadedRows.remove(rowKey) != nil)
        if faded { beltFadeReasons[rowKey] = reason } else { beltFadeReasons.removeValue(forKey: rowKey) }
        guard changed, !armed, let scheduler else { return }
        let token = rearm(source: "belt")
        MainActor.assumeIsolated { scheduler(token, settleDelay) }
    }

    /// Drops a row's belt state because its title VIEW is going away — lazy eviction, leaving Home,
    /// a theme `.id()` swap (Codex Wave 9 r1).
    ///
    /// Separate from `noteBeltFaded(rowKey:faded: false)` on purpose, in both directions. It must
    /// not re-arm a settle: the row is being torn down, so there is nothing left to correct and
    /// nothing that should schedule work against it. And it must not be skipped: a faded title
    /// that disappears never passes back through `showAgain`, so without this its key outlived it.
    /// A recreated title then starts `faded == false` while every settle line still reported
    /// `beltFaded=1`, AND its next genuine fade computed `changed == false` — so the diagnostic
    /// settle was never re-armed and the stale `1` was the last word. test48 could have passed on
    /// state from a view that no longer existed. Removing the key here restores the invariant that
    /// `changed` tracks a live title, so the re-arm fires again after recreation.
    nonisolated static func clearBeltFaded(rowKey: String) {
        beltFadedRows.remove(rowKey)
        beltFadeReasons.removeValue(forKey: rowKey)
    }

    /// Publishes one row's clearances — see `PinnedRowTitle.Clearances`.
    ///
    /// Codex r5 P2-1, second half: if a settle already declined for this row because the
    /// measurement had not arrived, the arrival itself has to be able to restart the mechanism —
    /// the page may be perfectly stationary by now, so no scroll event is coming. The re-check
    /// scheduled by that declining plan normally gets there first (the title publishes on its
    /// first geometry pass, well inside `settleDelay`); this covers the case where it did not, or
    /// where the caller's hop budget ran out. Re-arming only while nothing is `armed` keeps the
    /// two paths from staling each other's tokens and burning a hop for nothing.
    ///
    /// Codex r6: and the re-arm must be SCHEDULED, not just armed. `rearm()` alone left a settle
    /// nobody would ever run — the hop chain is spent and no scroll event is coming — so the row
    /// stayed uncorrected anyway. The token goes to the reveal modifier's own scheduler (see
    /// `scheduler`), which resolves it exactly the way every other deferred settle is resolved.
    ///
    /// `MainActor.assumeIsolated`: every writer in this enum is a SwiftUI geometry callback on the
    /// main thread — the same premise `nonisolated(unsafe)` already rests on throughout — and the
    /// scheduler closure touches the modifier's `@State`, so it is MainActor-isolated. This
    /// asserts that premise rather than hiding it behind a hop that would break the "one settle in
    /// flight" bookkeeping.
    nonisolated static func noteClearances(rowKey: String, clearances newValue: PinnedRowTitle.Clearances) {
        let wasLate = clearanceLatePending == rowKey && clearances[rowKey] == nil
        // Codex r10 P2: a clearance that actually CHANGED is the other reason to restart. The one
        // way it moves without geometry moving is a focus-mode toggle in Settings, which shifts
        // the correction target under a Home that may never scroll again on its own. Cheap to test
        // for: during a scroll this value is constant, so the comparison is false on every frame
        // and only a real mode/type/style change reaches the re-arm below.
        let changed = clearances[rowKey] != newValue
        clearances[rowKey] = newValue
        guard wasLate || changed else { return }
        if wasLate { clearanceLatePending = nil }
        guard !armed else { return }
        guard let scheduler else {
            // No pinned rows ScrollView has registered one — the corrector is not running in this
            // configuration at all, so there is nothing to resolve. Left un-armed deliberately.
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "clearance no-scheduler row=\(rowKey)")
            }
            return
        }
        let token = rearm(source: "clearance")
        if HomeGeometryProbe.enabled {
            NSLog("[HomeScrollProbe] settle %@",
                  "\(wasLate ? "clearance-late" : "clearance-changed") rearm row=\(rowKey)")
        }
        MainActor.assumeIsolated { scheduler(token, settleDelay) }
    }

    /// Wave W5 (BUG-89). The corrector's session-wide brakes describe a GEOMETRY REGIME, and this
    /// says when that regime has been replaced.
    ///
    /// The tester's beta.17 report, verbatim: after switching Poster Size from Medium to Large in
    /// Settings, the second-to-last row's regression comes back and stays back until the app is
    /// restarted — and the correction, when it does eventually happen, is visible as an "oops" snap
    /// rather than part of the size change.
    ///
    /// Both halves are this function's absence. `disarmed`, `verifyFailures`, `pullBacks`,
    /// `pullBackDisarmed`, `correctionsFired` and `lastCorrection` are session-wide
    /// `nonisolated(unsafe) static var`s that nothing resets short of process start —
    /// `resetHostScopedState` deliberately keeps them, on the grounds that they "describe the
    /// DEVICE, not the host". That grounds is right about a HOST swap and wrong about a REGIME
    /// change: a pull-back or a MISS recorded at Medium is evidence about Medium's rests, not
    /// Large's, and once two of them have accumulated the corrector is dead for a geometry it has
    /// never actually been tried against. What is left is the belt, whose only tool is to hide the
    /// title — which is precisely "the regression returns until restart".
    ///
    /// And the resolution delay is the snap. Every other arming source resolves a `settleDelay`
    /// (0.25s) later, which is right when the arming event is a scroll that has to stop moving
    /// first. A poster-size change is not that: the layout is being rewritten right now, and a
    /// correction folded into that rewrite is invisible while the same correction a quarter second
    /// afterwards is a discrete jump on a settled screen. Hence `retryAfter: 0` through the
    /// scheduler (which Wave W5 gave a delay parameter for exactly this caller).
    ///
    /// The FIRST call of a session just records: there is no previous regime for the accumulated
    /// state to be wrong about, and resetting on the way in would only throw away a clean slate.
    ///
    /// Deliberately NOT touched: `MeasurementReport.unmeasured`'s HOLD (Wave 9(a)'s root-cause fix —
    /// clearing there is what livelocked the corrector against the belt on hardware) and the
    /// pull-back detector itself. And the dead zone is NOT widened: Wave G settled that it is a
    /// GATE on how far inside the band a correction aims, never a subtrahend on the correction.
    ///
    /// Called by `HomeView` from `.onChange(of: plan.regimeKey)` — the signature is fixed by that
    /// call site.
    @MainActor static func noteRegimeChange(key: String, fits: Bool) {
        let previous = regimeKey
        regimeKey = key
        regimeFits = fits
        // BUG-89 (rc2): mirrored into the photographable buffer BEFORE the first-call guard below,
        // so the LAUNCH regime — the one `.onChange(initial: true)` registers and the one every
        // later settle line is measured under — is in the frozen head of a tester's capture. The
        // `[HomeScrollProbe] REGIME-CHANGE` NSLog further down is unchanged and still only fires on
        // an actual change. Diagnostics only; no behaviour depends on this branch.
        if PinnedRowSettleProbe.enabled {
            PinnedRowSettleProbe.log("regime \(key) fits=\(fits ? 1 : 0) from=\(previous ?? "-")")
        }
        // First call of the session: record and stop. Nothing has accumulated yet.
        guard let previous, previous != key else { return }
        // The brakes, released — every one of them is evidence gathered under `previous`.
        disarmed = false
        verifyFailures = 0
        pullBack.resetAll()
        pullBackFrom = 0
        correctionsFired.removeAll()
        lastCorrection = nil
        // Siblings: an outstanding verification promises an offset measured under the OLD layout
        // (landing it would be judged against content that no longer exists — a false MISS, and two
        // of those are the session disarm this function just cleared), an in-flight window belongs
        // to a correction the size change has already invalidated, and the epoch counters/latches
        // are per-situation rather than per-device.
        pendingVerification = nil
        nudgeDeadline = nil
        consecutiveNudges = 0
        standDownRow = nil
        clearanceLatePending = nil
        // Loud and unconditional (not `HomeGeometryProbe.enabled`-gated): this is a once-per-setting-
        // change line, it is the thing a device log needs to prove the reset happened at all, and the
        // corrector's other terminal lines (DISARMED, DISARMED-PULLBACK, MISS, VOID) are unguarded
        // for the same reason.
        // Codex beta.18 r4 (P2): the previous regime's measurements are stale by definition — a
        // zero-delay settle that reads them would compute a scroll target from the OLD row frame,
        // the exact post-switch snap this path exists to remove. Drop them; `MeasurementReport.
        // unmeasured` then HOLDS until the new geometry publishes, and the settle runs on that.
        latest = nil
        sample = nil
        NSLog("[HomeScrollProbe] REGIME-CHANGE from=\(previous) to=\(key) fits=\(fits ? 1 : 0)")
        guard let scheduler else { return }
        let token = rearm(source: "regime")
        // 0, not `settleDelay` — see the doc above. Already on the main actor here (this is called
        // from a SwiftUI `onChange`), so no `assumeIsolated` is needed.
        scheduler(token, 0)
    }

    /// BUG-112 (Item A): Home moved the rows scroll itself — the Up-fallback reveal — so everything
    /// the corrector is holding about the CURRENT rest describes a position that no longer exists.
    ///
    /// Three pieces have to go, each for a reason this file already documents elsewhere:
    /// an outstanding VERIFICATION would be judged against an offset WE moved (a false MISS, and
    /// two of those set the session-wide disarm); `lastCorrection` would let the pull-back
    /// detector read our own scroll as the engine fighting a correction; and the in-flight NUDGE
    /// window belongs to a correction this scroll has already invalidated. The hop is forgotten
    /// too — a programmatic jump is not a walk step and must not be read as a direction.
    ///
    /// Then one fresh settle, `settleDelay` out, so the new rest is judged on its own interval.
    /// `@MainActor` for the same reason `noteRegimeChange` is: the only caller is a SwiftUI handler.
    @MainActor static func noteExternalScroll(reason: String) {
        pendingVerification = nil
        nudgeDeadline = nil
        lastCorrection = nil
        pullBack.forgetHop()
        if HomeGeometryProbe.enabled {
            NSLog("[HomeScrollProbe] settle %@", "external-scroll reason=\(reason)")
        }
        guard let scheduler else { return }
        scheduler(rearm(source: "external"), settleDelay)
    }

    /// Ends the current correction epoch: a different row has focus, so neither the oscillation
    /// counter nor an outstanding verification belongs to the situation any more.
    ///
    /// Codex r1 P2: `pendingVerification` used to survive a focus change, so a D-pad move issued
    /// between a correction firing and the next settle was measured against an offset the focus
    /// engine had legitimately moved away from — counted as a MISS. Two quick moves could then
    /// disarm the whole mechanism for the session. Only a correction whose own rest is still the
    /// one being looked at can testify about whether the scroll API landed where it was asked to.
    /// `rowGainedFocus` distinguishes the two callers, which want opposite things from the fresh
    /// settle this arms: `report` is a NEW row taking focus and is about to store its measurement,
    /// so the settle has something to judge; `clear` is focus leaving the rows, where there is
    /// nothing to correct and an armed settle would just be a phantom.
    nonisolated private static func invalidateEpoch(rowGainedFocus: Bool) {
        consecutiveNudges = 0
        pendingVerification = nil
        // Codex r2 P2-2: the in-flight window belonged to the OLD row's correction. Left standing,
        // it swallows the new row's very first settle — which is the one settle that matters,
        // because by then the scroll is stationary and no further geometry event will arm another.
        nudgeDeadline = nil
        // The waiting rest belonged to the OLD row; the new row will raise its own if it needs to.
        clearanceLatePending = nil
        // Same for the stand-down dedup: a focus change is a fresh judgment, and re-entering a row
        // later must be able to re-notify its belt (Wave 9b).
        standDownRow = nil
        // The pull-back detector's evidence belongs to the row that was focused. A different row's
        // rest can never testify about whether THIS one was pulled back, and leaving it standing
        // would let an ordinary D-pad move to a row that happens to rest near the old row's
        // pre-correction margin read as the engine fighting us. The per-row WINDOW BUDGET
        // (`correctionsFired`) deliberately survives: it is keyed by row and its whole purpose is
        // to outlive the epoch churn that refunded the old consecutive-nudge counter.
        lastCorrection = nil
        // Codex r3 P2-2: stale every token scheduled for the OLD row. Resetting the correction
        // state alone left `generation` untouched, so a token armed before the focus change could
        // fire inside the NEW row's debounce window and compute a correction from a measurement
        // that has not settled yet — the new row must get its own full `settleDelay`, not inherit
        // the tail of the old row's. `rearm()` both stales the old tokens and arms that fresh
        // settle.
        let hadPendingBlock = armed
        let token = rearm(source: "epoch")
        guard !hadPendingBlock else {
            // A deferred block is still out there. It will find its token stale and pick the fresh
            // epoch up itself (`settlePlan`'s superseded branch) — routing this through the
            // scheduler as well would only stale the token it is about to be handed.
            epochRearmPending = true
            return
        }
        // Codex r8 P2-2: nothing is pending, so nobody would ever run the settle we just armed.
        // That is the focus change that does not move the scroll — a horizontal hop onto a row
        // whose rest is already wrong — which used to go completely unevaluated. Same routing, and
        // the same stand-down, as the late-clearance backstop: the epoch change happens inside a
        // ROW's geometry callback, which has no scroll position and so cannot resolve anything.
        guard rowGainedFocus else {
            // Focus left the rows entirely; there is no measurement to judge and no correction to
            // make. Don't leave a phantom armed settle behind.
            armed = false
            return
        }
        guard let scheduler else {
            armed = false
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "epoch no-scheduler")
            }
            return
        }
        MainActor.assumeIsolated { scheduler(token, settleDelay) }
    }

    /// Records a scroll sample and returns a settle token to schedule against — or nil when a
    /// debounce is already armed and the motion since arming is within `driftTolerance` (the creep
    /// case), so a crawling rest arms exactly ONE timer instead of one per frame.
    nonisolated static func noteScroll(_ newSample: ScrollSample) -> Int? {
        let previous = sample?.offsetY
        sample = newSample
        let now = Date()
        let step: CGFloat? = previous.map { abs(newSample.offsetY - $0) }

        // Motion is classified by TWO independent tests, OR'd — deliberately not merged, because
        // they discriminate different things and a single threshold cannot do both jobs.
        //
        //  1. PER-SAMPLE step (`driftTolerance`, 4pt). The fast path: one big jump is obviously
        //     motion and must re-arm on the spot without waiting for a window to fill. This is
        //     also the test that keeps the LAZY-REALIZATION CREEP reading as stillness — measured
        //     at ~0.4pt/frame (14pt over 600ms), an order of magnitude under the threshold. If the
        //     creep ever re-armed the debounce, the settle would never fire at all and this whole
        //     mechanism would silently stop existing.
        //
        //  2. CUMULATIVE displacement over `motionWindowSeconds` (Codex r11 P2-1). A deceleration
        //     tail moving 2–4pt per callback passes test 1 (4 is not > 4) yet is unmistakably
        //     motion: at 60Hz that is 120–240pt/s. Sustained slow motion could therefore hold
        //     below the per-sample threshold for longer than `settleDelay`, letting a correction
        //     fire at 250ms and the belt fade at 700ms while the page was visibly moving. Path
        //     length over a short window is a velocity, which is the quantity that actually
        //     separates the two regimes:
        //
        //         creep          ~23pt/s  →   ~7pt per 300ms window   (still)
        //         slow-swipe tail 120pt/s →  ~36pt per 300ms window   (motion)
        //
        //     `motionWindowDisplacement` (18pt ≈ 60pt/s) sits between them with ~2.5x of margin on
        //     each side. Erring HIGH is the safe direction: too high merely lets a very slow tail
        //     read as a rest (cosmetic — the plan is computed from the live sample, and the next
        //     real move re-arms), while too low resurrects the never-fires bug.
        motionWindow.removeAll { now.timeIntervalSince($0.at) > motionWindowSeconds }
        if let step { motionWindow.append((at: now, delta: step)) }
        let windowed = motionWindow.reduce(CGFloat(0)) { $0 + $1.delta }
        let isMove = step.map { $0 > driftTolerance || windowed > motionWindowDisplacement } ?? true

        // Stamped on every real move, including the corrector's OWN animated scroll — which is how
        // the visibility belt gets its "is the page actually still?" signal, and how the corrector
        // keeps first refusal at every rest (Codex r2 P2-1; see `secondsSinceMotion`).
        if isMove { lastMotionAt = now }
        if armed, !isMove { return nil }
        // BUG-87, the amplifier. A MOTIONLESS sample used to arm a settle whenever nothing was
        // already armed — so on a row-heavy Home every lazy row realization (`contentSize` grows,
        // `contentOffset` does not) armed a correction with no scroll and no focus change behind
        // it, and each correction it fired stamped motion, which produced more geometry callbacks.
        // Corrections must be a response to the page MOVING; the three backstops that legitimately
        // arm without motion (`invalidateEpoch`, `noteClearances`, `noteBeltFaded`) call `rearm`
        // directly and are untouched by this.
        //
        // The first sample of a host's life still arms: `isMove` is `true` when there is no
        // previous offset to difference against, which is what gives a page that has never
        // scrolled its one initial settle.
        guard isMove else {
            if HomeGeometryProbe.enabled, !stillIgnoredLogged {
                stillIgnoredLogged = true
                NSLog("[HomeScrollProbe] settle %@",
                      "still-ignored — a motionless geometry pass no longer arms a correction (further occurrences not logged)")
            }
            return nil
        }
        generation &+= 1
        armed = true
        armSource = "scroll"
        return generation
    }

    /// Installs the deferred-settle scheduler — see `scheduler`. Returns a generation id the
    /// caller passes back to `hostDidDisappear` so a teardown can only ever clear its OWN
    /// registration, never a newer one that has already replaced it.
    nonisolated static func registerScheduler(replacing previousID: Int,
                                              _ schedule: @escaping @MainActor (Int, TimeInterval) -> Void) -> Int {
        // "A DIFFERENT host is taking over", not merely "a registration exists": a host whose
        // `onAppear` runs again without an intervening teardown passes its own live id back and is
        // a continuation, whose measurements are still its own.
        if scheduler != nil, previousID != schedulerGeneration {
            // Not fatal — a theme `.id()` swap legitimately overlaps two hosts for one update, and
            // the newer one is the right winner. Logged so a genuinely unexpected second pinned
            // rows ScrollView shows up in a device log instead of silently taking over.
            NSLog("[HomeScrollProbe] settle %@",
                  "scheduler REREGISTERED — a second pinned rows ScrollView installed one; the newer host wins")
            // Codex r11 round 2: the measurement cleanup has to happen HERE, not only in
            // `hostDidDisappear`. In the swap ordering this file already guards against elsewhere,
            // the INCOMING host registers first — bumping `schedulerGeneration` — so the outgoing
            // host's later `hostDidDisappear` fails its generation guard and returns without
            // clearing anything. The new host would then pair its first scroll sample with the old
            // host's `latest` row frame and could correct a row nothing has focused. The
            // replacement point is the unambiguous boundary: state from a host that is being
            // replaced can never be valid for the one replacing it.
            resetHostScopedState()
        }
        schedulerGeneration &+= 1
        scheduler = schedule
        return schedulerGeneration
    }

    /// Everything the corrector holds that belongs to ONE pinned rows ScrollView. Shared by the
    /// teardown path (`hostDidDisappear`) and the takeover path (`registerScheduler`), because a
    /// swap can deliver either one and only one of them.
    ///
    /// `clearances` deliberately survives: it is keyed by rowKey, not by host, and each row
    /// republishes on its first measurement anyway. Dropping it would only manufacture
    /// `clearance=?` declines on the way back in.
    nonisolated private static func resetHostScopedState() {
        pendingVerification = nil
        nudgeDeadline = nil
        armed = false
        epochRearmPending = false
        clearanceLatePending = nil
        consecutiveNudges = 0
        latest = nil
        sample = nil
        lastMotionAt = nil
        motionWindow.removeAll()
        standDownRow = nil
        lastCorrection = nil
        // Host-scoped, unlike the epoch case: every row key belonged to the outgoing host's rows
        // and each of them is being torn down. The session-wide `pullBack` ledger's per-direction
        // COUNTS stay, for the same reason `disarmed` does — they describe the DEVICE, not the
        // host. But its HOP (`lastRowKey`/`lastOffsetY`) must go: a recreated host's first offset
        // is not comparable with the outgoing host's, so a surviving hop would misread the new
        // host's first sample as a real (or spuriously absent) direction change.
        pullBack.forgetHop()
        correctionsFired.removeAll()
        beltFadeReasons.removeAll()
        // Belt state is host-scoped diagnostic state like everything else here: it describes titles
        // that belonged to the OUTGOING host's rows, and every one of them is being torn down with
        // it. A surviving key would make the incoming host's settle lines report `beltFaded=1` for
        // a freshly-mounted, un-faded title — and, worse, suppress the re-arm on its next real fade
        // (see `clearBeltFaded`). Each row republishes its own state on its first measurement.
        beltFadedRows.removeAll()
        // Stale every token handed out under the previous host, so nothing scheduled before the
        // handover can resolve against the new one's state.
        generation &+= 1
    }

    /// Tears the corrector's shared state down when its host goes away — but only if `id` is still
    /// the live registration. During a theme `.id()` swap SwiftUI inserts the incoming subtree
    /// BEFORE removing the outgoing one, so the outgoing view's `onDisappear` runs after the
    /// incoming view's `onAppear`; an unscoped teardown there would disable the corrector for the
    /// rest of the session and void a verification the INCOMING host is legitimately waiting on.
    ///
    /// Codex r8 P2-1: `pendingVerification` in particular must go. A correction whose host is
    /// leaving will never be judged fairly — whatever offset the view holds when it comes back is
    /// the product of focus restoration, not of the scroll API — and two false MISSes disarm the
    /// mechanism for the whole session. Everything else here is hygiene: no host means nothing can
    /// resolve an armed settle, so leaving one armed would be a phantom.
    /// Codex r11 P2-3: the MEASUREMENTS are host-scoped and must go too. A recreated pinned host
    /// publishes its first scroll sample before anything in it has taken focus, and `settlePlan`
    /// pairs whatever `sample` it is given with whatever `latest` it still holds — so a surviving
    /// row frame from the previous host would be combined with the new host's offset and could fire
    /// a correction for a row that is not even focused. `sample` goes with it so the first sample
    /// after recreation is treated as a first sample (motion, no step to compare), and the motion
    /// window with it so a stale path length cannot make a fresh page look busy. All of that lives
    /// in `resetHostScopedState`, which the takeover path calls too — this generation guard means
    /// this function alone cannot be relied on to run.
    nonisolated static func hostDidDisappear(_ id: Int) {
        guard id == schedulerGeneration else { return }
        scheduler = nil
        resetHostScopedState()
    }

    /// Re-arms a settle without a scroll event, returning a token to schedule against, and stales
    /// every token already scheduled. Callers: the in-flight retry (Codex r2 P2-2), the epoch
    /// re-check (Codex r3 P2-2), and `invalidateEpoch` itself. All three exist because the page is
    /// already stationary at those moments, so no further geometry event will ever arm another.
    nonisolated static func rearm(source: String) -> Int {
        generation &+= 1
        armed = true
        armSource = source
        return generation
    }

    /// BUG-109: whether Home is currently COVERED by a pushed screen (folder page, Detail). A
    /// correction that lands while covered scrolls a view the user cannot see, and native focus
    /// restoration on the pop then resolves by geometry to whatever row now sits at the remembered
    /// rect — the tester's "exiting a collection moves me back to the row above". Home's root gets
    /// no `onDisappear` on a push (its own doc says so), so the host's teardown cancel never runs
    /// for this case; this flag is the push-scoped equivalent. Set by HomeView from its
    /// `NavigationPath` (via `setCovered`); read by `rejectCoveredSettle`, which the settle host
    /// calls BEFORE it plans anything — not just before it applies a target (Codex rc10 P2).
    // `nonisolated(unsafe)`: mutable static, same as every other piece of shared state in this
    // enum (`armed`, `generation`, …) — read and written off the main actor's static-isolation
    // guarantees by design, per the header note on those.
    nonisolated(unsafe) static var hostCovered = false

    /// One-shot latch for the covered-skip probe line, cleared on every cover transition below, so
    /// one push writes ONE line instead of one per settle that happens to resolve while covered.
    /// Same discipline as `stillIgnoredLogged`: the device pass needs to see that the branch fired,
    /// not how many times.
    nonisolated(unsafe) private static var coveredSkipLogged = false

    /// Publishes the cover transition. Both directions do real work.
    ///
    /// **Covering** (Codex rc10 P2, Finding 2): a correction in flight when the push happens can
    /// never be judged — whatever offset the rows hold when Home comes back is the product of
    /// native focus restoration, not of the scroll API — and two false MISSes disarm the corrector
    /// for the session. That is the same argument `hostDidDisappear` makes for a host that is
    /// leaving, and a push is the case `onDisappear` never sees. So an epoch invalidation runs
    /// here: it drops `pendingVerification`, the in-flight `nudgeDeadline`, the pull-back evidence
    /// and the per-row latches, stales every token already scheduled, and (because focus has left
    /// the rows) leaves nothing armed.
    ///
    /// **Uncovering** (Codex rc10 P2, Finding 1): the rest the user comes back to is likewise the
    /// product of focus restoration rather than of a scroll the corrector chose, so it has to be
    /// judged fresh. `rearm()` alone was not enough — it bumped `generation` (invalidating the
    /// pending work item) and set `armed = true` with NOTHING scheduled to resolve the token, so a
    /// stationary pop left the corrector permanently "armed" with no block behind it: the three
    /// other backstops all guard on `!armed` and so declined to re-arm, and a motionless geometry
    /// pass no longer arms at all (see `noteScroll`). Correction stalled until the user scrolled
    /// for real. The token goes to the registered scheduler, exactly like every other backstop.
    ///
    /// `epochRearmPending` is cleared on the way IN deliberately: it means "a pending block should
    /// ask for one re-check", and while covered there is nothing to re-check — the uncover above
    /// schedules the fresh settle instead.
    nonisolated static func setCovered(_ covered: Bool) {
        guard covered != hostCovered else { return }
        hostCovered = covered
        coveredSkipLogged = false
        guard !covered else {
            invalidateEpoch(rowGainedFocus: false)
            epochRearmPending = false
            return
        }
        guard let scheduler else {
            // No pinned rows ScrollView has registered one — nothing can resolve a settle in this
            // configuration, so leave `armed` FALSE rather than stranding a phantom (same
            // stand-down as `invalidateEpoch`'s and `noteClearances`' no-scheduler branches).
            armed = false
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "uncover no-scheduler")
            }
            return
        }
        let token = rearm(source: "uncover")
        // `MainActor.assumeIsolated` for the same reason `noteClearances` does it: this is called
        // from HomeView's `NavigationPath` observation on the main thread, and the scheduler closure
        // touches the settle host's `@State`.
        MainActor.assumeIsolated { scheduler(token, settleDelay) }
    }

    /// BUG-109 / Codex rc10 P2 (Finding 2): rejects a deferred settle that has resolved while Home
    /// is COVERED — and rejects it BEFORE `settlePlan` runs.
    ///
    /// The rc9 guard sat downstream of the planning call and only dropped the `targetY`. By then
    /// `settlePlan` had already recorded `pendingVerification`, `nudgeDeadline`, this row's entry in
    /// `correctionsFired` and `lastCorrection` for a scroll that was then never applied: the skipped
    /// correction still spent the 8s per-row budget, and the verification it left behind was later
    /// judged against movement that never happened — a false MISS, or a false PULLBACK, either of
    /// which can disarm the mechanism for the session. Nothing after this point is stateful, so the
    /// cheapest correct fix is to never plan at all.
    ///
    /// Identity comes from the latest measurement rather than from a plan (there is none yet), which
    /// is the one thing the line loses; `row=` is still the token a reader of the photo starts from.
    nonisolated static func rejectCoveredSettle() -> Bool {
        guard hostCovered else { return false }
        guard !coveredSkipLogged else { return true }
        coveredSkipLogged = true
        let row = latest?.rowKey ?? "-"
        if PinnedRowSettleProbe.enabled {
            PinnedRowSettleProbe.log("settle row=\(row) covered=1 skipped=1")
        }
        // Unguarded NSLog, like the corrector's other terminal lines: a push that would have
        // scrolled the covered Home is exactly what the Row Settle pane device pass looks for.
        NSLog("[HomeScrollProbe] settle covered=1 skipped=1 row=%@", row)
        return true
    }

    /// How long the rows scroll view has been still, in seconds — `.greatestFiniteMagnitude` when
    /// it has never moved this session (a title clipped at mount with no scrolling is at rest by
    /// any reading, and must still be allowed to fade).
    ///
    /// Exists for the visibility belt. The belt's own `onGeometryChange` cannot answer this: once
    /// a title saturates at the slide cap its `Reading` is byte-identical frame to frame, the
    /// observer stops firing, and a slow swipe that stays in the belt's band for longer than
    /// `fadeDelay` would let the hide timer expire MID-SCROLL — hiding a title while the page is
    /// visibly moving, which is not what "a settled rest still leaves it on the artwork" means.
    /// Motion is a property of the SCROLL, so it is measured here where the scroll is observed.
    nonisolated static func secondsSinceMotion() -> TimeInterval {
        guard let lastMotionAt else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(lastMotionAt)
    }

    /// Resolves a settle. Returns nil when this token was superseded (the page moved again), which
    /// is the "abandon the nudge if a new focus change or scroll starts" rule.
    nonisolated static func settlePlan(token: Int) -> Plan? {
        guard armed, let sample else { return nil }
        guard token == generation else {
            // Superseded. A supersede from a scroll event needs nothing — that event scheduled its
            // own resolution. A supersede from an EPOCH change does: it happened inside a row's
            // geometry callback, which cannot schedule anything (Codex r3 P2-2). Hand the caller
            // one re-check, a full debounce out, so the new row settles on its own interval.
            guard epochRearmPending else { return nil }
            epochRearmPending = false
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "epoch-rearm row=\(latest?.rowKey ?? "-")")
            }
            // Empty report: this is control flow, not a measured rest. Reporting it would put a
            // line with no `margin=` into the harness oracle (`debug_pinned`) between two real
            // ones — see the caller's `report.isEmpty` skip.
            return Plan(report: "", targetY: nil, retryAfter: settleDelay)
        }
        armed = false
        settleSeq &+= 1

        // BUG-112 (Item B): which way the walk is going, and whether that just released the
        // pull-back brake. Derived from the offset delta across a ROW HOP — see `PullBackLedger`.
        // Placed before the verification block so a release can also clear the verify-miss latch
        // the OTHER direction's corrections produced (see below).
        //
        // Codex P2: gating the verify-miss release on `released` (the LEDGER's own disarm→armed
        // transition) left it unreachable for a split pull-back — one recorded while direction was
        // still `unknown` plus one recorded walking down gives `unknown=1 down=1 total=2`, so
        // neither per-direction count ever reaches `maxPullBacksPerSession` and the ledger itself
        // is never `disarmed` — while the two verification MISSes those same pull-backs produced on
        // hardware DID set the (separate, static) verify-miss latch. `released` stays false in that
        // case, `noteSettle` never fires, and the latch is stuck for the rest of the session. The
        // fix reads `changed` instead: any settle that turns the walk to a new KNOWN direction is
        // evidence a reversal happened, whether or not the ledger's own count crossed its budget.
        let directionResult: PullBackLedger.SettleResult
        if let rowKey = latest?.rowKey {
            directionResult = pullBack.noteSettle(rowKey: rowKey, offsetY: sample.offsetY)
        } else {
            directionResult = .none
        }
        if directionResult.changed {
            // The verify-miss latch is released too, and ONLY because the pull-back ledger has
            // evidence (`pullBack.total > 0`): on hardware a pull-back and a MISS are the SAME
            // event seen twice — the engine returns the row to its own rest, so the landed offset
            // differs from the requested one by the whole correction (well past `verifyTolerance`),
            // and the next settle both counts a MISS and detects the pull-back. That is therefore
            // the evidence that the latch is the engine fighting a direction rather than the scroll
            // API being broken; a session that disarmed with NO pull-backs is a genuine
            // coordinate-space failure and stays off. Independent of `directionResult.released` —
            // the ledger's own count can still be under budget (the split-pull-back case above) while
            // this evidence holds. Cost of a wrong release is bounded: two more MISSes re-latch it,
            // i.e. at most two extra ≤`bound` nudges per reversal, each visible as a `MISS` line.
            if pullBack.total > 0 {
                disarmed = false
                verifyFailures = 0
            }
            NSLog("[HomeScrollProbe] settle REARM-DIRECTION dir=\(pullBack.direction)"
                    + " row=\(latest?.rowKey ?? "-") pull=\(pullBack.total)"
                    + " rearm=\(pullBack.rearms) released=\(directionResult.released ? 1 : 0)"
                    + " y=\(Int(sample.offsetY.rounded()))"
                    + " — the walk reversed; the pull-back brake belongs to the other direction")
        }

        // Verify the PREVIOUS correction before planning another one.
        if let verification = pendingVerification {
            pendingVerification = nil
            let expected = verification.expectedY
            let error = sample.offsetY - expected
            // A reflow between fire and check (lazy row realization, an image landing, a row's
            // shelf regrowing) moves the content under the scroll view, so the landed offset says
            // nothing about the scroll API. Void rather than count it — Codex r1 P2.
            if abs(sample.contentHeight - verification.contentHeight) > 1 {
                NSLog("[HomeScrollProbe] settle %@",
                      "VOID expected=\(Int(expected.rounded())) landed=\(Int(sample.offsetY.rounded()))"
                        + " contentH=\(Int(verification.contentHeight.rounded()))→\(Int(sample.contentHeight.rounded()))")
            } else if abs(error) > verifyTolerance {
                verifyFailures += 1
                // %@ with an interpolated Swift String rather than %d varargs — the house NSLog
                // convention everywhere in this tree.
                NSLog("[HomeScrollProbe] settle %@",
                      "MISS expected=\(Int(expected.rounded())) landed=\(Int(sample.offsetY.rounded()))"
                        + " error=\(Int(error.rounded())) failures=\(verifyFailures)")
                if verifyFailures >= maxVerifyFailures {
                    disarmed = true
                    NSLog("[HomeScrollProbe] settle DISARMED — corrections are not landing where they were asked to; falling back to slide + fade only")
                }
            } else {
                verifyFailures = 0
            }
        }

        guard let m = latest else {
            // BUG-112 (Item B), Codex P3: `dir=`/`rearm=` belong on every settle line, this one
            // included — a reader tailing the probe across a focus-loss gap (a pop, a covered
            // Home) should not see the walk-direction fields vanish and reappear. Same placement
            // rule as the focused BASE line: right after `fits=`.
            return Plan(report: "row=- state=nofocus y=\(Int(sample.offsetY.rounded()))"
                            + " seq=\(settleSeq) armSrc=\(armSource)"
                            + " regime=\(regimeKey ?? "-") fits=\(regimeFits ? 1 : 0)"
                            + " dir=\(pullBack.direction) rearm=\(pullBack.rearms)",
                        targetY: nil)
        }

        // ── The pull-back detector (BUG-87, second brake) ────────────────────────────────────
        // Detected HERE, immediately after the verification block, because it is evidence about
        // the same thing: what happened to the LAST correction. The corrector's contraction
        // argument only ever bounded what IT does; it said nothing about what the focus engine does
        // next. On hardware the engine re-reveals the focused link frame after a correction moves
        // it and lands the row back where it started — and the old budget, refunded on every landed
        // correction, had nothing to notice that with. So: a rest within `pullBackTolerance` of the
        // margin the last correction was fired FROM, inside two seconds, means that correction
        // achieved nothing and repeating it would achieve nothing either.
        //
        // The counters move here so the settle line carries ONE authoritative `pull=`/`pbDisarm=`
        // (a second copy appended on the branch below would be a duplicate key for the harness
        // oracle); the ACTION — log, stand down, decline — happens after the in-band branch, so a
        // rest that landed inside the band is never treated as a fight. Mutating on a rest that
        // then turns out to be in band is harmless and nearly unreachable: a correction only ever
        // fires from an OUT-of-band margin, so a landing within 4pt of it can only be in band
        // through the ±2 membership slack, and `standDownFastPath` re-checks the title's own
        // acceptability before hiding anything.
        var pulledBack = false
        if let last = lastCorrection,
           last.rowKey == m.rowKey,
           abs(m.margin - last.fromMargin) <= pullBackTolerance,
           Date().timeIntervalSince(last.at) < 2 {
            pulledBack = true
            pullBackFrom = last.fromMargin
            lastCorrection = nil
            pullBack.notePullBack()
        }

        let cap = maxSlideCapForReport
        let slide = min(max(-m.margin, 0), cap)
        let net = m.margin + slide
        var line = "row=\(m.rowKey) margin=\(Int(m.margin.rounded())) net=\(Int(net.rounded()))"
            // `protB` is what the correction is actually bounded by; on a mixed-shape row it sits
            // well above `rowB` (Codex r11 P2-2), and the gap between them is the room the old
            // row-bottom bound was throwing away.
            + " vh=\(Int(m.viewportHeight.rounded())) rowB=\(Int(m.rowBottom.rounded()))"
            + " protB=\(Int(m.protectedBottom.rounded()))"
            + " y=\(Int(sample.offsetY.rounded())) inset=\(Int(sample.insetTop.rounded()))"
            // Wave 9(a): the handoff, observable. `beltFaded=1` on a `nudge=0` line is the whole
            // contract working — the corrector gave the rest up and the belt took it.
            + " beltFaded=\(beltFadedRows.contains(m.rowKey) ? 1 : 0)"
            + " beltFadeReason=\(beltFadeReasons[m.rowKey] ?? "-")"
            // BUG-87 diagnostic set. `rowH`/`last`/`prevHidden` describe the row; `corrN`/`pull`/
            // `pbDisarm` describe the two new brakes; `seq`/`armSrc` describe THIS settle — which
            // is what makes an idle sample of `debug_pinned` readable at all: an unchanging `seq`
            // means the corrector is quiet, and a climbing one with nobody touching the remote is
            // the loop reproducing. `prevHidden` is the BUG-89 question ("does the row above this
            // one still show under the fold?") answered from the only geometry the corrector has:
            // a row parked at the clip edge hides everything above it.
            + " rowH=\(Int(m.rowHeight.rounded()))"
            + " last=\(m.isLastRow ? 1 : 0)"
            // BUG-87/89 (rc11): whether the frame-shaping floor was actually active on this row —
            // see `EnvironmentValues.rowCardLinkFrameFloor` and the `settlePlan` exemption below.
            + " lastRowShaped=\(m.lastRowShaped ? 1 : 0)"
            + " prevHidden=\(m.rowTop <= 2 ? 1 : 0)"
            + " corrN=\(correctionsInWindow(m.rowKey))"
            + " pull=\(pullBack.total)"
            + " pbDisarm=\(pullBack.disarmed ? 1 : 0)"
            + " seq=\(settleSeq) armSrc=\(armSource)"
            // Wave W5 (BUG-89): which GEOMETRY REGIME this rest was measured under, and whether
            // that regime's frame fits the rows viewport — see `noteRegimeChange`. Appended at the
            // END of the field list, so test47/test48's `key=value` parsers are untouched.
            // `regime=-` means no host has published one: a non-Home `CatalogRowView`, or a build
            // whose HomeView predates the call site.
            + " regime=\(regimeKey ?? "-") fits=\(regimeFits ? 1 : 0)"
            // BUG-112 (Item B), appended at the END of the field list (the append-only contract in
            // this type's header — test47/48/58/61/63 parse `key=value`, order not significant):
            // which direction the walk is going in (+1 down, −1 up, 0 not yet known) and how many
            // times a reversal has released the pull-back brake this session.
            + " dir=\(pullBack.direction)"
            + " rearm=\(pullBack.rearms)"

        // The correction target is a legibility BAND, not a point (Wave G, BUG-87). Both edges are
        // real constraints that the row's own geometry supplies, and every margin between them is
        // an acceptable rest that the corrector must leave alone:
        //
        //     bandLow  = −clearance.focused
        //     bandHigh = min(heroPinnedRowTitleInset, 48 + vh − lockupExtent − settledCushion)
        //
        // `bandLow` is the BUG-84 edge: at that margin the title's bottom sits exactly on the
        // FOCUSED card's artwork top (the lift is already subtracted into `clearance.focused`), so
        // one point lower and the title is painting on the picture. `bandHigh` is two constraints
        // met at once — the title may not fall further than its own inset below the clip edge
        // (past that the previous row's cards start showing under the fold, BUG-89's contrast), and
        // the focused card's lockup must still finish inside the viewport with the settled cushion
        // under it, which is what `vh − lockupExtent` measures.
        //
        // Why this replaces Wave 10's canonical `margin == 0`. That point target held on the sim
        // by luck: the sim's focus engine TOP-anchors an over-tall link frame and rests at +22, so
        // one contraction to 0 finished the job. Hardware BOTTOM-anchors the same frame on an
        // up-walk (the recorded device `margin=-99` at `vh=455` is `vh − H + 24` to within a point),
        // so its rest is ~55pt on the other side of the target — and no point target with a ±4 dead
        // zone can hold both anchorings. The corrector chased 0 from below, the engine re-revealed
        // the frame back to its own anchoring, and the `deficit == 0` refund handed the budget back
        // on every landed correction. A band whose edges come from the geometry is satisfiable
        // under BOTH anchorings, which is what makes the loop stop existing rather than be braked.
        //
        // Verified numbers (uniform poster rows, No Zoom, `clearance.focused = 26`,
        // `lockupExtent = lg + topReach + artwork + captionChrome`):
        //
        //     Size     vh      lockupExtent   band            engine rest        result
        //     Large    523.3   558.8          [-26,   4.5]    sim +24 / dev -31.5   one nudge 23.5 / 9.5
        //     Medium   455     485.5          [-26,   9.5]    -26.5 (inside slack)  0 nudges
        //     Small    455     430.5          [-26,  48  ]    +24 … +28.5           0 nudges
        //
        // — i.e. Wave 10's Large rests are preserved to the point (a rest pulled from +24 lands at
        // bandHigh − deadZone = 0.5, and BUG-84's "title never on the artwork" still holds because
        // the whole band is above `bandLow`), while Medium and Small stop being dragged to 0 at all.
        // That is the one intended visual change: their titles now sit fully visible with a taller
        // dark band above them instead of being pulled up to the clip edge.
        //
        // No published clearances means this row's title has never measured itself (it isn't
        // mounted, or pinned mode isn't on) — fail safe and correct nothing.
        guard let clearance = clearances[m.rowKey] else {
            // Codex r5 P2-1: this is NOT a clean rest — it is a rest we could not judge yet,
            // because the row's title has not published its measurement. Treating it as closed
            // lost the rest entirely: `armed` was already false, and if `noteClearances` then
            // landed with the scroll stationary, nothing would ever re-schedule and the row stayed
            // uncorrected (with the belt free to hide its title instead). Ask for a re-check
            // instead — the title publishes on its first geometry pass, so a `settleDelay` of
            // grace is generous — and record the row so a clearance arriving after the hop budget
            // runs out can still re-arm (see `noteClearances`).
            consecutiveNudges = 0
            clearanceLatePending = m.rowKey
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "clearance-late row=\(m.rowKey)")
            }
            return Plan(report: line + " nudge=0 clearance=?",
                        targetY: nil,
                        retryAfter: settleDelay)
        }
        clearanceLatePending = nil
        // BUG-87/89: a NEGATIVE unclamped focused clearance is not a bad rest, it is bad GEOMETRY.
        // The band above the artwork is too short to hold the title AND the focus lift, so the
        // focused card's picture is under the title at every margin, and a correction can only
        // trade one out-of-band rest for another (it did help — 49.5pt of real overlap down to
        // 18 — which is why it kept firing, and why the clamp then reported the result as a clean
        // 0). Stand down instead: the belt owns an unfixable rest. Same dedup discipline as
        // `standDown`'s own log — loud, but once per row.
        //
        // When this can still fire, now that `topReachFloor(lift:titleHeight:)` holds the lift
        // against the ACTIVE font's title metric (rc10 Codex P2): only where the floor hits its 88pt
        // cap AND the title is taller than ≈44pt, i.e. `24 + 88 − 48 − titleHeight − lift < 0` with
        // the reach already at the ceiling that keeps focus resolution working. That is accessibility
        // text sizes, in either font family — geometry no reach can cover — so reaching this branch
        // there is the intended handoff rather than a floor bug. It is NOT reachable from an ordinary
        // font choice any more: Open Sans at the cap leaves 1.8pt, which is short of the belt's arm
        // but non-negative, so the corrector keeps its rest. (The `deficit=` line below still names
        // the reach floor, because that is the right first suspect whenever it fires at a NORMAL
        // type size.)
        //
        // A deficit smaller than the belt's own arm band (`PinnedRowTitle.fadeIntrusionArm`, 4pt) is
        // absorbed by the belt's hysteresis rather than treated as unfixable geometry: `topReachFloor`
        // reserves the FONT metric of the title, but the clearance here is judged against the LIVE
        // rendered title height (`PinnedRowTitle.reading`'s `titleHeight`), and a fallback face (CJK,
        // Thai, Arabic collection/addon names) can measure a few points taller than its font metric —
        // enough to make `focusedRaw` slightly negative (e.g. −1.4) without the row actually being
        // unfixable. Only a genuine over-band deficit (the rc4 18pt case, accessibility sizes) should
        // disarm the corrector.
        if clearance.focusedRaw < -PinnedRowTitle.fadeIntrusionArm {
            let firstTime = standDownRow != m.rowKey
            standDown(rowKey: m.rowKey, reason: "lift-deficit")
            if firstTime {
                NSLog("[HomeScrollProbe] settle %@",
                      "LIFT-DEFICIT row=\(m.rowKey) regime=\(regimeKey ?? "-")"
                        + " clearance=\(Int(clearance.atRest.rounded()))"
                        + " lift=\(Int(clearance.lift.rounded()))"
                        + " deficit=\(Int(clearance.focusedRaw.rounded()))"
                        + " — the row's top band cannot hold the title AND the focus lift; no scroll"
                        + " can fix it, so the reach floor is the bug (PinnedRowGeometry.topReachFloor)")
            }
            return Plan(report: line
                        + " clearance=\(Int(clearance.atRest.rounded())) clearanceLift=0"
                        + " clearanceLiftRaw=\(Int(clearance.focusedRaw.rounded()))"
                        + " nudge=0 standDown=lift-deficit",
                        targetY: nil)
        }
        let liftedIntrusion = slide - clearance.focused
        // ── The band ─────────────────────────────────────────────────────────────────────────
        // See the block comment above for what each edge means and why a band replaced Wave 10's
        // point target. `deadZone` is a GATE here in exactly the sense it always was: it never
        // shortens a correction, it decides how far INSIDE the band a correction aims so a landed
        // rest cannot sit on the boundary and re-trigger on sub-point noise.
        let bandLow = -clearance.focused
        let bandHigh = min(Theme.Size.heroPinnedRowTitleInset,
                           Theme.Size.heroPinnedRowTitleInset + m.viewportHeight - m.lockupExtent
                               - Theme.Size.heroPinnedRowsSettledCushion)
        // ±2 of slack on the membership test, not on the target: it is the probe's own 2pt
        // quantization, so a rest reported as sitting exactly on an edge is treated as inside it.
        let inBand = m.margin >= bandLow - 2 && m.margin <= bandHigh + 2
        let bandMid = (bandLow + bandHigh) / 2
        // Aim one dead zone inside the nearer edge, but never past the middle — on a band narrower
        // than two dead zones the inset from one edge would overshoot the other, and the midpoint
        // is the only point that is inside both.
        let bandTarget = m.margin < bandLow
            ? min(bandLow + Theme.Size.heroPinnedRowSettleDeadZone, bandMid)
            : max(bandHigh - Theme.Size.heroPinnedRowSettleDeadZone, bandMid)
        // `err` keeps its spelling and its sign convention (signed distance to what we are aiming
        // at), and reads 0 inside the band because there is nothing to aim at. `deficit` likewise
        // keeps its name — every device log written so far greps for it.
        let error = inBand ? 0 : m.margin - bandTarget
        let deficit = inBand ? 0 : abs(m.margin - bandTarget)
        // `lift=` is reported separately from the two clearances because `focused` clamps at 0:
        // once the active treatment's lift exceeds the static clearance, the difference between
        // the two clearances stops telling you the magnitude. In still mode this reads
        // `lift=0 clearanceLift=26` — the whole point of Codex r7 P1.
        line += " clearance=\(Int(clearance.atRest.rounded()))"
            + " clearanceLift=\(Int(clearance.focused.rounded()))"
            + " clearanceLiftRaw=\(Int(clearance.focusedRaw.rounded()))"
            + " lift=\(Int(clearance.lift.rounded()))"
            + " intr=\(Int((slide - clearance.atRest).rounded()))"
            + " intrLifted=\(Int(liftedIntrusion.rounded()))"
            + " err=\(Int(error.rounded()))"
            + " deficit=\(Int(deficit.rounded()))"
            + " bandLo=\(Int(bandLow.rounded()))"
            + " bandHi=\(Int(bandHigh.rounded()))"
            + " inBand=\(inBand ? 1 : 0)"

        // A rest inside the band needs nothing. The epoch closes for the `n=` counter's sake, but
        // note what does NOT happen here any more: the per-row WINDOW BUDGET is not refunded. That
        // refund was the loop — a landed correction produces exactly this branch, so the budget
        // handed itself back every time it was spent successfully.
        guard deficit > 0 else {
            consecutiveNudges = 0
            // This rest is fine, so the row is no longer given up on. Releasing the dedup here is
            // what lets the Wave 9b fast path fire AGAIN if the row later lands on another
            // unfixable rest — without it `standDown` would notify once per row per host and every
            // later episode would fall back to the belt's timers.
            if standDownRow == m.rowKey { standDownRow = nil }
            return Plan(report: line + " nudge=0", targetY: nil)
        }
        // The pull-back detected above (the counters already moved, so `pull=`/`pbDisarm=` on this
        // line are current). Hand the rest to the belt at once — the title is what is at stake, and
        // hiding it is the terminal fallback the belt exists for — and after
        // `maxPullBacksPerSession` stop correcting altogether.
        if pulledBack {
            NSLog("[HomeScrollProbe] settle %@",
                  "PULLBACK row=\(m.rowKey) from=\(Int(pullBackFrom.rounded()))"
                    + " landed=\(Int(m.margin.rounded())) count=\(pullBack.total)")
            standDown(rowKey: m.rowKey, reason: "pullback")
            if pullBack.disarmed {
                NSLog("[HomeScrollProbe] settle DISARMED-PULLBACK — the focus engine returns rows to its own rest after every correction; corrections are off for this session, belt only")
            }
            return Plan(report: line + " nudge=0 pullback=1", targetY: nil)
        }
        guard !disarmed else { return Plan(report: line + " nudge=0 disarmed=1", targetY: nil) }
        // Same terminal outcome as `disarmed`, different cause — `pbDisarm=1` on the line is what
        // tells the two apart, so the existing `disarmed=1` spelling is kept for both.
        guard !pullBack.disarmed else { return Plan(report: line + " nudge=0 disarmed=1", targetY: nil) }
        // Wave 10 gate knob: with the hero compression in place an unsatisfiable rest is no longer
        // reachable at Large by walking, so test48's premise needs a way to put one back. Disarming
        // the corrector leaves a deep park uncorrected, which is exactly the geometry the belt's
        // rest/ceiling paths exist for. Read once at launch like every other probe knob, and inert
        // unless it is passed.
        //
        // Deliberately NO `standDown` here, and the distinction is the whole point of the knob.
        // A stand-down means "the corrector engaged, tried, and gave up", and it hands the rest to
        // the belt immediately through the Wave 9b observer — which is why the first version of
        // this branch made the gate report `beltFadeReason=standdown` and never exercised what it
        // was written for. The knob simulates a corrector that NEVER ENGAGES AT ALL, so there is no
        // handoff to make: the belt has to find the rest on its own clocks (`fadeDelay`, then the
        // `fadeMaxDefer` ceiling), and covering those two timer paths is the coverage this leg
        // exists to provide. No notification, and no `standDownRow` latch either — latching would
        // suppress a genuine stand-down later in the same session.
        guard !disarmedByKnob else {
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@",
                      "knob-disarmed row=\(m.rowKey) — corrector never engages; belt owns this rest on its own clocks")
            }
            return Plan(report: line + " nudge=0 knobDisarm=1", targetY: nil)
        }
        // A correction is still animating — never stack a second one on top of it. Ask for one
        // re-check just past the deadline rather than dropping this rest (Codex r2 P2-2).
        if let deadline = nudgeDeadline, Date() < deadline {
            return Plan(report: line + " nudge=0 inflight=1",
                        targetY: nil,
                        retryAfter: max(deadline.timeIntervalSinceNow, 0) + 0.05)
        }
        // An EMPTY band: `bandHigh < bandLow`, i.e. the focused card's lockup is so much taller
        // than the viewport that there is no margin at which the title clears the artwork AND the
        // card finishes inside the fold. That is the unsatisfiable geometry the visibility belt
        // exists for, and no correction can improve it — hand it over rather than spend the budget
        // discovering that twice.
        //
        // Placed AFTER the `debug.pinnedSettleDisarm` guard on purpose: that knob's whole job is to
        // simulate a corrector that never engages, so test48 leg A's premise needs it to keep
        // returning `knobDisarm=1` on exactly the deep parks this branch would otherwise claim.
        guard bandHigh >= bandLow else {
            standDown(rowKey: m.rowKey, reason: "unsatisfiable")
            return Plan(report: line + " nudge=0 unsat=1", targetY: nil)
        }
        // ── The wall-clock budget (BUG-87, first brake) ───────────────────────────────────────
        // Replaces `consecutiveNudges < maxConsecutiveNudges`. See `correctionWindow` for why a
        // consecutive-failure counter could never brake this loop: the loop's corrections all
        // SUCCEED, and success refunded the counter. `consecutiveNudges` survives only as the `n=`
        // field, which reads as "how many attempts in this epoch" and nothing branches on.
        let fired = correctionsInWindow(m.rowKey)
        guard fired < maxCorrectionsPerWindow else {
            standDown(rowKey: m.rowKey, reason: "budget")
            return Plan(report: line + " nudge=0 budget=1", targetY: nil)
        }

        // How far the content may move DOWN before the FOCUSED card's own lockup starts leaving
        // the viewport — see `Measurement.protectedBottom`, which is the row's bottom minus its
        // transparent chrome for a uniform-card row, and the focused tile's own extent for the
        // mixed-shape collection row (Codex r11 P2-2). It bounds DOWNWARD corrections only: moving
        // the row UP can never push its bottom past the fold.
        let bottomRoom = m.viewportHeight - m.protectedBottom
        // …and its upward twin: how much SCROLL RANGE is left above the current offset. An upward
        // correction raises `contentOffset.y`, and the last row in the list sits at (or near) the
        // maximum, so a short final row settling with a positive margin could ask to scroll past
        // the end. `scrollTo` clamps that silently, the correction lands short of where it said it
        // would, and the verification counts a MISS — two of which set the SESSION-WIDE disarm and
        // kill corrections for every row (Codex Wave 10 r2). Bounding it here is the mirror of what
        // `protectedBottom` does for the downward direction.
        //
        // Conservative by construction: any bottom content inset would make the real maximum
        // larger, so under-allowing is the safe side of the estimate.
        let maxOffsetY = max(sample.contentHeight - sample.viewportHeight, 0)
        let scrollRoomUp = max(maxOffsetY - sample.offsetY, 0)
        // A row at the bottom of the content legitimately CANNOT reach the band — there is no
        // scroll left to give. That is the best rest the geometry allows, not a failure, so it
        // closes the epoch like any other healthy rest rather than standing down: the title is
        // fully visible (a margin above the band is neither clipping nor intrusion), so there is
        // nothing for the belt to own either.
        //
        // BUG-89 note: this is the LAST ROW's normal outcome, and it stays the honest fallback
        // rather than being keyed off `m.isLastRow`. "The scroll range is spent" is a property of
        // the scroll view, and it can be true for a mid-list row (a short content height, a pending
        // lazy realization) and false for the last one (`HomeView.rowsInsets` now sizes a trailing
        // inset from the last row's own height, so the range usually IS there). `last=` and
        // `prevHidden=` on the line say which case a device log is looking at.
        if error > 0, scrollRoomUp <= Theme.Size.heroPinnedRowSettleDeadZone {
            consecutiveNudges = 0
            if standDownRow == m.rowKey { standDownRow = nil }
            return Plan(report: line + " nudge=0 endOfContent=1 room=\(Int(scrollRoomUp.rounded()))",
                        targetY: nil)
        }
        // BUG-87/89 (rc11, floor hardened by Codex r1 on rc11, governance-checked by Codex r2 on rc11 — Codex r2 P2): the
        // exemption `PinnedRowEnvironment.swift` has promised since BUG-89. With the frame shaped
        // (`rowCardLinkFrameFloor` == `PinnedRowGeometry.lastRowLinkFrameFloor(plan:)`, the LARGER of
        // `plan.linkFrame` and `viewport − Spacing.lg`), the engine's own reveal constraint already
        // confines this row to `margin ∈ [24, 48]` — the band's own upper edge, not `24 + restRange`
        // — so a rest ABOVE the band here means the shaping did not take — and a correction is
        // exactly the wrong answer: the deep rest is legal for the engine, which re-reveals straight
        // back to it (the rc10 `pullback=1` ×3 → `pullBackDisarmed` trace). Log it and let the belt
        // judge the title.
        //
        // That guarantee only holds while the floor actually GOVERNS this focused label — a floor
        // that EXISTS is not enough. A mixed-shape collection row in Landscape Rows mode can hold a
        // PORTRAIT folder whose own natural label is taller than the regime's (landscape-shaped)
        // floor; the label's `.frame(minHeight:)` then sizes to its own taller content instead of the
        // floor, the `margin ∈ [24, 48]` promise is void for it, and — the rc11 (Codex r2) device finding — a
        // top-anchored rest clips the artwork with `error > 0` and real scroll range to spend. Taller
        // labels keep the normal correction path below rather than being waved through here.
        // `lastRowExemptionApplies` is the governance check; see its own doc for the arithmetic.
        //
        // Strictly a GUARD, not the fix: when the shaping is in force AND governs this branch is
        // unreachable (`deficit == 0` returns above). It earns its place in the regime where the
        // floor is 0 — `!plan.fits`, or a Poster Size whose last row is already the plan's shape —
        // and now also where the floor exists but a taller-than-floor label makes it moot.
        //
        // Upward only. `error < 0` means the row is parked ABOVE the band (title clipped), which the
        // reveal constraint cannot produce and which the downward correction is still the right
        // answer for if something else ever does.
        if error > 0, m.isLastRow,
           PinnedRowSettle.lastRowExemptionApplies(lockupExtent: m.lockupExtent,
                                                   linkFrameFloor: m.linkFrameFloor) {
            consecutiveNudges = 0
            if standDownRow == m.rowKey { standDownRow = nil }
            return Plan(report: line + " nudge=0 lastRowShaped=1 room=\(Int(scrollRoomUp.rounded()))",
                        targetY: nil)
        }
        // Magnitude first, then the sign of the correction we actually apply. Unbounded, this is
        // the FULL distance to the target, so a correction lands ON it; `min` can only ever
        // SHORTEN that, never invert or extend it — which is what makes this a contraction (see
        // the anti-oscillation contract in the header). Extracted to `plannedCorrection` (BUG-112
        // Item B) so the bound cases are unit-testable; behaviour here is unchanged.
        let planned = PinnedRowSettle.plannedCorrection(error: error, deficit: deficit,
                                                        bottomRoom: bottomRoom,
                                                        scrollRoomUp: scrollRoomUp)
        let magnitude = planned.magnitude
        // Positive = move content DOWN (raise `margin`); negative = move content UP (lower it).
        let correction = planned.correction
        guard magnitude >= 2 else {
            // Reachable in BOTH directions now that the upward branch is bounded too, and the two
            // mean opposite things, so they must not share an outcome:
            //
            //  - DOWNWARD (`error < 0`): the row is clipped and `bottomRoom` has nothing left to
            //    give — the row is too tall for this viewport to show its title band and its card
            //    at once. That is the unsatisfiable geometry the visibility belt exists for, so
            //    hand it over.
            //  - UPWARD (`error > 0`): the row is merely parked a little low with under 2pt of
            //    usable scroll left. The title is fully visible — a positive margin is neither
            //    clipping nor intrusion — so there is nothing for the belt to own. Treat it as the
            //    clean rest it is and close the epoch, exactly like the end-of-content case above.
            if error < 0 {
                standDown(rowKey: m.rowKey, reason: "bound")
                return Plan(report: line + " nudge=0 bound=\(Int(bottomRoom.rounded()))", targetY: nil)
            }
            consecutiveNudges = 0
            if standDownRow == m.rowKey { standDownRow = nil }
            return Plan(report: line + " nudge=0 room=\(Int(scrollRoomUp.rounded()))", targetY: nil)
        }

        // Content-space vs offset-space: in Home's PINNED mode the rows ScrollView sits inside the
        // VStack under the hero header and carries `contentInsets.top == 0` (BUG-66 rig, 2026-08-27
        // — "pinned inset=0 vs classic 157"), so `contentOffset.y` and the probe's inset-corrected
        // `residual` are the same number and a relative correction is exact under either reading
        // of `ScrollPosition.scrollTo(y:)`. `inset=` is logged on every line, and the verification
        // above disarms the mechanism if that ever stops being true on hardware.
        let target = max(sample.offsetY - correction, -sample.insetTop)
        consecutiveNudges += 1
        nudgeDeadline = Date().addingTimeInterval(nudgeDuration + 0.2)
        pendingVerification = Verification(expectedY: target, contentHeight: sample.contentHeight)
        // Spend the wall-clock budget, and record the margin this correction is leaving so the
        // next settle can tell "it landed and stayed" from "the engine put it straight back".
        let firedAt = Date()
        correctionsFired[m.rowKey, default: []].append(firedAt)
        lastCorrection = (rowKey: m.rowKey, fromMargin: m.margin, at: firedAt)
        // `nudge` stays signed in the log: positive moved the row DOWN toward the clip edge,
        // negative pulled it UP. A device trace can read the direction straight off the line.
        line += " nudge=\(Int((sample.offsetY - target).rounded())) bound=\(Int(bottomRoom.rounded()))"
            // BUG-87/89 (rc11): `bound=` is the DOWNWARD bound; an upward nudge is bounded by
            // `scrollRoomUp`. Printing both makes "the correction was cut short by range" separable
            // from "the correction landed and the engine put the row back" (`pullback=`).
            + " roomUp=\(Int(scrollRoomUp.rounded()))"
            + " n=\(consecutiveNudges)"
        // Wave W5 (BUG-89): a correction fired while the regime FITS is a surprise worth a line of
        // its own. A fitting frame is one the rows viewport can show whole, and both band edges are
        // then satisfiable by construction — the focus engine's own rest should already be inside
        // the band and the corrector should have nothing to do. If it does have something to do,
        // the interesting quantity is not this correction but the ANCHORING that produced the rest:
        // hardware bottom-anchors an over-tall frame where the simulator top-anchors it (the Wave G
        // header's ~55pt spread), and a fitting frame that still rests out of band means a third
        // anchoring nobody has measured. Loud and ungated, like the corrector's other surprises
        // (MISS, VOID, DISARMED), and mirrored onto the settle line so the harness sees it too.
        if regimeFits {
            let corrN = correctionsInWindow(m.rowKey)
            line += " UNEXPECTED-WITH-FIT"
            NSLog("[HomeScrollProbe] settle %@",
                  "UNEXPECTED-WITH-FIT row=\(m.rowKey) regime=\(regimeKey ?? "-")"
                    + " corrN=\(corrN) margin=\(Int(m.margin.rounded()))"
                    + " bandLo=\(Int(bandLow.rounded())) bandHi=\(Int(bandHigh.rounded()))"
                    + " vh=\(Int(m.viewportHeight.rounded())) lockup=\(Int(m.lockupExtent.rounded()))"
                    + " — the regime reports a fitting frame, so this rest should already have been in band"
                    + " — fits constrains the FRAME, not the band; read clearanceLiftRaw and bandLo first")
        }
        if HomeGeometryProbe.enabled { NSLog("[HomeScrollProbe] settle %@", line) }
        return Plan(report: line, targetY: target)
    }

    /// How many corrections this row has fired inside `correctionWindow`, pruning the record as it
    /// reads it. The pruning is the only maintenance `correctionsFired` gets, which is enough: a
    /// row that stops being corrected stops being asked about, and its stale `Date`s are bounded by
    /// `maxCorrectionsPerWindow` per row.
    nonisolated private static func correctionsInWindow(_ rowKey: String) -> Int {
        guard var fired = correctionsFired[rowKey] else { return 0 }
        let cutoff = Date().addingTimeInterval(-correctionWindow)
        fired.removeAll { $0 < cutoff }
        if fired.isEmpty {
            correctionsFired.removeValue(forKey: rowKey)
        } else {
            correctionsFired[rowKey] = fired
        }
        return fired.count
    }

    /// Declares that the corrector has given this rest up and the visibility belt now owns it.
    ///
    /// Two jobs, with deliberately different lifetimes. The LOG line is deduped per row, so a
    /// stationary rest writes one line and not one per settle — that is what lets a device pass
    /// distinguish "the corrector never tried" from "the corrector tried, could not, and handed
    /// over", the exact question the hardware trace could not answer (Wave 9(a)). The
    /// NOTIFICATION fires every time, because it is functional rather than diagnostic (Wave 9b).
    nonisolated private static func standDown(rowKey: String, reason: String) {
        // The LOG is deduped; the NOTIFICATION is not (Codex Wave 9b r2). Latching both behind one
        // flag meant a stand-down that did not result in a hide — a fully-clipped title, or one
        // whose geometry had not been cached yet — still consumed the row's single notification,
        // and a later partially-visible unfixable rest on the same still-focused row fell back to
        // the belt's timers. That is exactly the visible beat the fast path exists to remove.
        //
        // Notifying every time is safe because `standDownFastPath` is IDEMPOTENT: it returns
        // immediately when the title is already faded, and otherwise re-derives the reading and
        // re-checks `hideCandidate`, so a repeat on a rest that does not warrant hiding does
        // nothing at all. The cost of a redundant notification is a dictionary lookup and an
        // early-returning closure call, once per settle at most.
        if standDownRow != rowKey {
            standDownRow = rowKey
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "standdown row=\(rowKey) reason=\(reason) — belt owns this rest")
            }
        }
        // Wave 9b: hand the rest over IMMEDIATELY rather than leaving the belt to time out.
        //
        // Device video frame analysis (2026-08-31) confirmed Wave 9 works but showed the seam:
        // at every deep rest the title painted across the posters for ~1-2s before the belt hid
        // it. That beat is the belt's own rest-gate — correct for a rest nobody has judged yet,
        // pure latency for one the corrector has just declared unfixable. This notification
        // collapses it.
        //
        // It cannot race a correction that would have made the title acceptable, and the reason is
        // structural rather than a matter of timing: `standDown` is only ever reached from inside
        // `settlePlan`, which runs from a DEBOUNCED SETTLE, and only on the two branches that have
        // already concluded this rest cannot be improved — the nudge budget is spent, or the bound
        // leaves less than 2pt to give. There is no pending correction at that moment by
        // construction, so there is nothing for an immediate hide to pre-empt.
        if let observer = standDownObservers[rowKey] {
            MainActor.assumeIsolated { observer.notify() }
        }
    }

    /// Registers a title's "the corrector gave this rest up" callback, returning a token the caller
    /// passes back to `stopObservingStandDown`. Token-scoped for the same reason the scheduler slot
    /// is: a `.id()` remount inserts the incoming title before removing the outgoing one, so an
    /// unscoped removal would unregister the live observer.
    nonisolated static func observeStandDown(rowKey: String,
                                             _ notify: @escaping @MainActor () -> Void) -> Int {
        standDownObserverSeq &+= 1
        standDownObservers[rowKey] = (token: standDownObserverSeq, notify: notify)
        return standDownObserverSeq
    }

    nonisolated static func stopObservingStandDown(rowKey: String, token: Int) {
        guard standDownObservers[rowKey]?.token == token else { return }
        standDownObservers.removeValue(forKey: rowKey)
    }

    /// The cap `net` is reported against — the same one `PinnedRowTitle.reading` binds with, so
    /// the settle line and the title line can never disagree about what "net" means.
    nonisolated private static var maxSlideCapForReport: CGFloat {
        PinnedRowTitle.maxSlideOverride ?? Theme.Size.heroPinnedRowTitleMaxSlide
    }
}

extension View {
    /// Publishes a PINNED row's own frame to the settle re-reveal while (and only while) one of
    /// its cards holds focus. Attach to the row's outer view, after `.focusSection()`.
    ///
    /// Attached unconditionally by all four pinned rows and gated INSIDE the geometry closure
    /// rather than by an `if` around the modifier: a conditional modifier around a whole row would
    /// re-identify that row's subtree every time focus entered or left it — poster pipelines torn
    /// down and rebuilt per D-pad step, the BUG-19 class. When the row is unfocused (or classic
    /// mode, where `rowCardTopReach` is 0) the closure returns nil constantly and nothing fires.
    ///
    /// `focusedLockupExtent` is for MIXED-SHAPE rows only — the distance from the row's top edge to
    /// the focused card's lockup bottom, when the row's own frame overstates it. Uniform-card rows
    /// leave it nil and keep exactly today's bound; see `PinnedRowSettle.Measurement`.
    func pinnedRowSettleTracking(rowKey: String,
                                 isFocused: Bool,
                                 focusedLockupExtent: CGFloat? = nil) -> some View {
        modifier(PinnedRowSettleTracking(rowKey: rowKey,
                                         isFocused: isFocused,
                                         focusedLockupExtent: focusedLockupExtent))
    }
}

private struct PinnedRowSettleTracking: ViewModifier {
    let rowKey: String
    let isFocused: Bool
    /// See `pinnedRowSettleTracking`. Constant per focused card, so it adds no observer fires.
    let focusedLockupExtent: CGFloat?
    /// Pinned mode is the only mode with an overlaid title to protect; 0 = classic, inert.
    @Environment(\.rowCardTopReach) private var cardTopReach
    /// BUG-89: whether this is Home's LAST pinned row — see `PinnedRowEnvironment.swift`. Read
    /// here rather than threaded through `pinnedRowSettleTracking(rowKey:isFocused:)` so the four
    /// row types that attach that modifier need no signature change and every non-Home host keeps
    /// the `false` default for free.
    @Environment(\.pinnedRowIsLast) private var isLastRow
    /// BUG-87/89 (rc11), carrying the VALUE since Codex r2 on rc11 — see
    /// `EnvironmentValues.rowCardLinkFrameFloor` and `PinnedRowSettle.Measurement.linkFrameFloor`.
    @Environment(\.rowCardLinkFrameFloor) private var linkFrameFloor

    func body(content: Content) -> some View {
        // Captured by value so the geometry closure holds a plain String and a Bool rather than
        // this (view-isolated) modifier — the same rule the title probe already follows.
        let key = rowKey
        let active = isFocused && cardTopReach > 0
        let lockupExtent = focusedLockupExtent
        let isLast = isLastRow
        let floor = linkFrameFloor
        // Wave 9(a): THREE states, not two. Collapsing "this row is not focused" and "the enclosing
        // scroll view didn't resolve this pass" into one `nil` is what livelocked the corrector
        // against the belt on hardware — see `PinnedRowSettle.clear` and the device trace in the
        // header. It is the same distinction Wave 4 item 6 already had to draw for the TITLE's own
        // measurement (`slideMeasurement` vs `slide`): an unmeasurable pass must HOLD, never clear.
        return content.onGeometryChange(for: PinnedRowSettle.MeasurementReport.self, of: { proxy in
            guard active else { return .inactive }
            guard let visible = PinnedRowTitle.visibleBounds(proxy) else { return .unmeasured }
            // `visible` is the rows viewport expressed in THIS ROW's local space, so `-minY` is
            // the row's top edge measured from the viewport's top edge — the same quantity, and
            // the same sign convention, as `PinnedRowTitle.rawMargin`.
            return .measured(PinnedRowSettle.Measurement(rowKey: key,
                                                         rowTop: -visible.minY,
                                                         rowHeight: proxy.size.height,
                                                         viewportHeight: visible.height,
                                                         focusedLockupExtent: lockupExtent,
                                                         isLastRow: isLast,
                                                         linkFrameFloor: floor))
        }, action: { newValue in
            switch newValue {
            case .measured(let measurement):
                PinnedRowSettle.report(measurement)
            case .unmeasured:
                // Hold. This row still holds focus and its last measurement is still the best
                // description of it; clearing here would end the correction epoch and hand the
                // corrector a fresh nudge budget for a rest it has already given up on.
                break
            case .inactive:
                PinnedRowSettle.clear(rowKey: key)
            }
        })
    }
}

/// Home's half of the settle re-reveal: watches the rows ScrollView's geometry, and when a rest
/// settles with the focused row's title clipped, animates the scroll down by exactly the shortfall
/// `PinnedRowSettle` computed. Only the rows ScrollView moves — the pinned hero is a sibling above
/// it in the VStack split and is untouched, by construction.
///
/// `enabled` is a per-call-site CONSTANT (see `HomeView.rowsScroll(pinned:settleReveal:)`), which
/// is what makes the `if` here safe: it resolves once per hero-container mode, never per scroll
/// frame and never at the `heroItems` empty→loaded boundary, so it can't re-identify the rows.
struct PinnedRowSettleRevealModifier: ViewModifier {
    let enabled: Bool
    /// Wave 10: the hero compression currently in effect, purely so this modifier — which already
    /// observes the rows scroll geometry, and is only enabled in the pinned container — can verify
    /// the constant the compression is sized against. Changes no behaviour.
    var compression: CGFloat = 0
    /// DEBUG-only sink for the harness oracle (`debug_pinned`); nil in release, where nothing is
    /// written anywhere and the whole path is a static-storage update plus one scroll request.
    var onSettle: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition()
    /// Generation id of this host's scheduler registration, so teardown clears only its own —
    /// see `PinnedRowSettle.hostDidDisappear`. Written once on appear.
    @State private var schedulerID = 0
    /// The one deferred settle currently in flight (Codex r8 P2-1). Held in a reference box rather
    /// than as a `@State` value on purpose: `scheduleSettle` runs once per scroll frame during a
    /// reveal, and a `@State` write there would invalidate this modifier every frame — the exact
    /// churn `PinnedRowSettle`'s static storage exists to avoid. The box's identity is stable
    /// across body re-evaluations, so mutating `item` reaches the live work item either way.
    @State private var settleWork = SettleWorkBox()

    func body(content: Content) -> some View {
        if enabled {
            content
                .scrollPosition($position)
                .onScrollGeometryChange(for: PinnedRowSettle.ScrollSample.self, of: { geo in
                    PinnedRowSettle.ScrollSample(offsetY: geo.contentOffset.y,
                                                 insetTop: geo.contentInsets.top,
                                                 contentHeight: geo.contentSize.height,
                                                 viewportHeight: geo.containerSize.height)
                }, action: { _, sample in
                    // Wave 10: the compression is sized against a MEASURED constant
                    // (`heroPinnedRowsViewportBudget`) rather than the live viewport, because
                    // feeding the live value back would make the hero's height depend on the
                    // height it produced. This is the guard on that assumption — it changes no
                    // layout, it just says so in the log if the platform's rows viewport ever
                    // stops matching `budget + compression`.
                    PinnedRowTitle.verifyViewportBudget(liveViewport: sample.viewportHeight,
                                                        compression: compression)
                    // nil = a debounce is already armed and this sample is within the creep
                    // tolerance of it, so there is nothing to schedule (see `noteScroll`).
                    guard let token = PinnedRowSettle.noteScroll(sample) else { return }
                    scheduleSettle(token: token,
                                   after: PinnedRowSettle.settleDelay,
                                   hops: Self.maxSettleHops)
                })
                // Codex r6: the late-clearance backstop arms a settle from a TITLE's geometry
                // callback, which has no scroll position and so cannot resolve it. Hand the
                // coordinator this host's scheduler so that path lands in exactly the same
                // deferred resolution every other settle uses — a fresh hop budget, since it
                // starts a new chain rather than continuing a spent one.
                .onAppear {
                    // `replacing:` is this host's own live id (0 before it has ever registered), so
                    // the coordinator can tell a re-`onAppear` from the SAME host apart from a
                    // different host taking over — only the latter invalidates the measurements.
                    // Wave W5: the coordinator picks the delay. Every backstop that existed before
                    // passes `settleDelay` and is unchanged; `noteRegimeChange` passes 0 so a
                    // poster-size change is corrected inside its own layout change.
                    schedulerID = PinnedRowSettle.registerScheduler(replacing: schedulerID) { token, delay in
                        scheduleSettle(token: token,
                                       after: delay,
                                       hops: Self.maxSettleHops)
                    }
                }
                // Codex r8 P2-1: a settle scheduled just before Home goes away would otherwise run
                // against a hidden view — `position.scrollTo(y:)` shifting the position the user
                // comes back to, and a verification nothing can land counting a false MISS toward
                // the session disarm. Cancelling the work item is unconditional (it is this
                // instance's own state, so it can never reach another host's); the SHARED teardown
                // is generation-scoped, because during a theme `.id()` swap this runs after the
                // incoming host's `onAppear`.
                //
                // Known limit, stated rather than implied: Home's own doc records that neither a
                // Detail push nor a tab switch fires `onDisappear` on its root, so this covers
                // teardown rather than every way the rows can stop being visible. BUG-109 showed a
                // correction that lands during a push is NOT bounded by the pop's focus engine —
                // `position.scrollTo(y:)` fires against the covered scroll view and native focus
                // restoration on the pop then resolves by geometry to whatever row now sits at the
                // remembered rect, not the row the user actually left. `PinnedRowSettle.hostCovered`
                // (set by HomeView from its `NavigationPath`) now gates the whole evaluation, in
                // `scheduleSettle` below — ahead of the planning call, so a skipped settle spends no
                // correction state either (Codex rc10 P2); this `onDisappear` teardown stays
                // as the belt-and-suspenders path for whatever DOES tear the host down.
                .onDisappear {
                    settleWork.item?.cancel()
                    settleWork.item = nil
                    PinnedRowSettle.hostDidDisappear(schedulerID)
                }
        } else {
            content
        }
    }

    /// Chain budget for `scheduleSettle`. Three hops covers the three ways a settle asks to be
    /// re-checked instead of resolved — an in-flight correction swallowing it (Codex r2 P2-2), a
    /// focus change re-arming a fresh epoch under it (Codex r3 P2-2), and a clearance that has not
    /// been published yet (Codex r5 P2-1) — while making the recursion terminate by construction
    /// rather than by argument. Each re-check is a `Plan` with no correction attached, so the
    /// worst case is three trivial main-queue hops before the mechanism gives up on one rest and
    /// waits for the next geometry event (or, for the clearance case, for `noteClearances` to
    /// re-arm it).
    private static let maxSettleHops = 3

    /// Resolves one settle after `delay`, applies whatever it decided, and re-arms once for the
    /// plans that ask for a re-check. Each re-check spends one hop, so the chain is bounded at
    /// `maxSettleHops` regardless of what the coordinator returns.
    ///
    /// Exactly ONE deferred block is ever pending: scheduling cancels whatever was already out
    /// there. That is not just bookkeeping for `onDisappear` — during a reveal `noteScroll` hands
    /// out a token per frame, and every earlier block is stale by construction (its token no longer
    /// matches `generation`), so cancelling them replaces a burst of no-op main-queue wakeups with
    /// a single live one. The retry path re-enters here from inside the running item; cancelling an
    /// already-executing `DispatchWorkItem` is a no-op, so the new item simply takes its place.
    private func scheduleSettle(token: Int, after delay: TimeInterval, hops: Int) {
        settleWork.item?.cancel()
        let work = DispatchWorkItem {
            // BUG-109: never scroll a covered Home — and never PLAN for one either. A pushed folder
            // page (or Detail) clears focus from this row, and applying a correction while the rows
            // scroll view is hidden behind that push moves a scroll position the user cannot see;
            // native focus restoration on the pop then resolves by geometry to whatever row now sits
            // at the remembered rect, which is what read as "leaving a collection moves me back to
            // the row above".
            //
            // Codex rc10 P2: this check is FIRST, above `settlePlan`, because `settlePlan` is
            // stateful — it records a verification, a nudge window, a per-row correction stamp and
            // `lastCorrection` — and cancelling the work item afterwards undid none of that. A
            // skipped scroll therefore spent the correction budget and left a verification to be
            // judged against movement that never happened. `PinnedRowSettle.setCovered(false)`
            // re-arms AND schedules a fresh settle once the pop restores focus, so nothing is lost
            // by declining here.
            if PinnedRowSettle.rejectCoveredSettle() {
                settleWork.item?.cancel()
                settleWork.item = nil
                return
            }
            guard let plan = PinnedRowSettle.settlePlan(token: token) else { return }
            // Control-flow plans carry no measurement and must not reach the harness oracle.
            if !plan.report.isEmpty { onSettle?(plan.report) }
            // BUG-89 (rc2): the ONE place every settle DECISION passes through — exactly one line
            // per resolved settle epoch step, whatever branch produced it, carrying the same
            // `row= margin= … nudge=…` text `settlePlan` builds and (on the correction branch)
            // NSLogs verbatim. Mirroring here rather than at the dozen `return Plan(…)` sites is
            // what keeps the volume to one line per decision instead of one per measurement, and
            // what guarantees the pane shows the `nudge=0 endOfContent=1 room=…` last-row lines
            // that never reach the console at all (only the correction branch NSLogs).
            //
            // `margin=` is the filter, for both reasons that matter: it drops the control-flow
            // reports (already dropped above) and the `state=nofocus` one, and it is the token a
            // reader of the photo starts from. `.truncationMode(.middle)` in the About pane keeps
            // the head (`row= margin= net= vh=`) and the tail (`nudge=… endOfContent=… room=…`),
            // which is the whole diagnosis.
            if PinnedRowSettleProbe.enabled, plan.report.contains("margin=") {
                PinnedRowSettleProbe.log("settle " + plan.report)
            }
            if let target = plan.targetY {
                if reduceMotion {
                    position.scrollTo(y: target)
                } else {
                    withAnimation(.easeOut(duration: PinnedRowSettle.nudgeDuration)) {
                        position.scrollTo(y: target)
                    }
                }
                return
            }
            if hops > 0, let retry = plan.retryAfter {
                scheduleSettle(token: PinnedRowSettle.rearm(source: "retry"), after: retry, hops: hops - 1)
            }
        }
        settleWork.item = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Reference box for the reveal modifier's single in-flight deferred settle — see
/// `PinnedRowSettleRevealModifier.settleWork` for why this is a class rather than a plain `@State`
/// value.
private final class SettleWorkBox {
    var item: DispatchWorkItem?
}

/// Reference box for the inputs a pinned title's OUT-OF-BAND recomputes need — see
/// `PinnedRowTitleTracking.tracking` for why this is a class rather than plain `@State` (the
/// geometry is written on every measurement; a state write there would invalidate per frame).
///
/// Codex Wave 9b r1: it carries `isFocused` as well as the geometry, because the stand-down
/// observer is an ESCAPING closure installed once at `onAppear`. Closures capture the view struct
/// by value, so every plain `let` on the modifier is frozen at capture time. `@State` and
/// `@AppStorage` reads still resolve live through their storage boxes, and the other `let`s
/// (`rowKey`, `artworkHeight`, `captionVisible`, `treatment`) cannot change without the style
/// gate's `.id()` remounting the whole modifier — which re-runs `onAppear` and re-installs the
/// closure. `isFocused` is the one input that changes freely WITHIN a mount, on every D-pad step,
/// so it is the one that has to be read through a stable reference.
private final class TitleTrackingCache {
    var geometry: PinnedRowTitle.TitleGeometry?
    /// Live mirror of the row's focus state — see the class note. Drives which clearance the fast
    /// path judges by, which in the lift-bearing focus modes is a ~20pt difference.
    var isFocused = false
}

/// Swift-side navigation value. Kotlin data classes don't conform to Swift `Hashable`, so we wrap the
/// `MetaPreview` and hash on its stable identity (type + id) while still carrying all its fields for
/// the destination's initial render. Shared by Home, Search, and detail "more like this".
struct TitleRoute: Hashable {
    let preview: MetaPreview

    static func == (lhs: TitleRoute, rhs: TitleRoute) -> Bool {
        lhs.preview.id == rhs.preview.id && lhs.preview.type == rhs.preview.type
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(preview.id)
        hasher.combine(preview.type)
    }
}

/// Navigation value for the full-grid "See All" screen. `CatalogTarget` is a Kotlin sealed interface
/// and can't be a `NavigationStack` value directly, so we wrap it — hashing on the section's stable
/// `key` while carrying the title + target for the destination (same approach as `TitleRoute`).
struct CatalogRoute: Hashable {
    let key: String
    let title: String
    let target: any CatalogTarget

    init(section: HomeCatalogSection) {
        self.key = section.key
        self.title = section.title
        self.target = section.target
    }

    static func == (lhs: CatalogRoute, rhs: CatalogRoute) -> Bool { lhs.key == rhs.key }

    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Navigation value for a cast/crew member's detail page (TMDB person id + name for the initial
/// render). Only produced when a `MetaPerson` has a `tmdbId`. Hashes on the id.
struct PersonRoute: Hashable {
    let id: Int
    let name: String

    static func == (lhs: PersonRoute, rhs: PersonRoute) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Navigation value for a studio/network browse page (TMDB discover-by-company/network). Only
/// produced when a `MetaCompany` has a `tmdbId`. `isNetwork` picks the TMDB entity kind (networks
/// come from `meta.networks`, studios from `meta.productionCompanies`); `sourceType` is the origin
/// title's type ("movie"/"series"), which orders the rails. Hashes on kind + id.
struct EntityRoute: Hashable {
    let id: Int
    let name: String
    let isNetwork: Bool
    let sourceType: String

    static func == (lhs: EntityRoute, rhs: EntityRoute) -> Bool {
        lhs.id == rhs.id && lhs.isNetwork == rhs.isNetwork
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isNetwork)
    }
}

/// One horizontal catalog (e.g. "Popular Movies", or a search-result group) as a focus-scrollable row
/// of poster cards.
///
/// By default each card is a `NavigationLink` to the title's detail screen (used on Home). Pass
/// `onSelect` to instead handle taps manually — Search uses this to dismiss the keyboard before
/// navigating.
struct CatalogRowView: View {
    /// BUG-13: the Home fetch trims each row to `HOME_CATALOG_PREVIEW_FETCH_LIMIT` items
    /// (HomeRepository.kt) while `availableItemCount` keeps the addon's real first-page count. Rows
    /// built that way must pass this limit so the "See All" gate can spot a truncated catalog.
    static let homePreviewLimit = 18

    let section: HomeCatalogSection
    /// Number of items the producing repository kept for this row, or `nil` when the row already
    /// renders everything it fetched (Search) — then only `hasMore` can open the full grid.
    var previewLimit: Int? = nil
    var onSelect: ((MetaPreview) -> Void)? = nil
    /// UX-7: reports the focused card's item (or nil) so Home can drive the hero from it.
    /// Defaulted and appended last — Search's call site (`CatalogRowView(section:)`) and Home's
    /// (`section:previewLimit:`) both compile unchanged. Gating and backdrop prefetch live in
    /// the callback (HomeView.reportRowFocus), not here.
    var onItemFocusChange: ((MetaPreview?) -> Void)? = nil

    /// Inline trailer previews on focus dwell (see `InlineTrailerCard`). Device-local on purpose —
    /// whether a living-room Apple TV should autoplay trailers is a per-device call, not a synced
    /// account preference. Off by default (opt-in); Settings → Home Screen owns the toggle UI.
    @AppStorage("inline_trailers_enabled") private var inlineTrailersEnabled = false

    /// Sentinel `focusedItemId` value for the trailing See All tile (Codex r3 P2-1). A leading NUL
    /// makes it unrepresentable as an addon/TMDB catalog id, so it can never collide with a real
    /// item and none of the binding's other consumers can accidentally match it.
    private static let seeAllFocusKey = "\u{0}see-all"

    /// Which card holds focus. Needed here (rather than inside the card) because tvOS delivers
    /// remote commands to the *focused view chain* — the `Button`/`NavigationLink` below, never its
    /// label — so the play/pause mute toggle has to be attached at this level and gated on "this is
    /// the focused item, and it is the one playing".
    @FocusState private var focusedItemId: String?

    /// Which card currently owns the single inline `AVPlayer`, published by the shared coordinator.
    @ObservedObject private var trailerCoordinator = InlineTrailerCoordinator.shared

    /// BUG-29: an inline-trailer expansion widens its card in place without moving focus, so tvOS's
    /// automatic focus-driven scroll never fires — the row has to scroll itself, and Reduce Motion
    /// governs whether that scroll animates (see `expansionChanged(for:expanded:proxy:)`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// tvOS Accessibility ▸ Motion ▸ Auto-Play Video Previews. When the user has turned previews off
    /// system-wide, the row must render exactly as it did before this feature existed.
    /// The third term is Home's "Trailer Location: Hero" mode (`trailerPlaysInHero`): the trailer
    /// still plays, just in the hero backdrop, so this row must leave its posters alone.
    private var inlineTrailersActive: Bool {
        let active = inlineTrailersEnabled && UIAccessibility.isVideoAutoplayEnabled && !trailerPlaysInHero
        // BUG-55: both gates default OFF, and a fresh container silently resets the toggle — a
        // no-trailers session must say WHY in the log, once per state change, not per render.
        // Hero-location suppression is NOT threaded through this probe: its dedupe is one global
        // tuple, and `trailerPlaysInHero` differs per host (Home true, Search false), so routing
        // it through would flip-flop the "once per state change" contract on every Home↔Search
        // render alternation. HomeView logs its own `[TrailerPipeline] trailerLocation` line on
        // mode changes instead, so a log pull still can't mistake BY-DESIGN suppression for a
        // broken gate.
        InlineTrailerGateProbe.report(enabled: inlineTrailersEnabled, autoplay: UIAccessibility.isVideoAutoplayEnabled)
        return active
    }

    /// BUG-13: an addon whose manifest declares no `skip` extra always reports `hasMore == false`,
    /// even when its single response carried far more titles than the row kept — gating on `hasMore`
    /// alone made those catalogs a dead end. Mirrors composeApp's Home gate, which uses the same
    /// shared `canOpenCatalog(previewLimit:)` (HomeModels.kt: availableItemCount > previewLimit || hasMore).
    private var canOpenFullCatalog: Bool {
        guard let previewLimit else { return section.hasMore }
        return section.canOpenCatalog(previewLimit: Int32(previewLimit))
    }

    /// Pinned-hero card reach (UX-7 extension, device rounds 4–5) — see `rowCardTopReach` /
    /// `rowCardBottomReach` for the mechanism. 0 (no-op) everywhere except Home's pinned mode.
    @Environment(\.rowCardTopReach) private var cardTopReach
    @Environment(\.rowCardBottomReach) private var cardBottomReach
    /// BUG-87/89 (rc11): see `EnvironmentValues.rowCardLinkFrameFloor`. 0 for every row but Home's
    /// last.
    @Environment(\.rowCardLinkFrameFloor) private var cardLinkFrameFloor

    /// Wave 4 item 6: the RESTING artwork height of this row's cards, handed to the pinned title's
    /// slide clamp so the title's intrusion is a fraction of the card rather than a fixed 46pt of
    /// whatever size the user picked (see `PinnedRowTitle.maxSlide`).
    ///
    /// Mirrors `InlineTrailerCard.artworkHeight`, which is the same expression and — deliberately —
    /// CONSTANT across the inline-trailer morph ("the height never changes so the row never
    /// breathes vertically"), so one number describes the row in both states. The caption slot
    /// (`style.showTitle`) is excluded: it sits BELOW the art and cannot be intruded on from above.
    @Environment(\.posterStyle) private var posterStyle
    private var rowArtworkHeight: CGFloat {
        posterStyle.landscapeCatalogRows ? Theme.Size.landscapeHeight : posterStyle.height
    }

    /// Home's "Trailer Location: Hero" mode — see `trailerPlaysInHero`. False (no-op) everywhere
    /// except Home in that mode, so Search and every other host keeps the inline morph.
    @Environment(\.trailerPlaysInHero) private var trailerPlaysInHero

    /// H3 hardening (BUG-47): the previous version fired-and-forgot a detached `Task` per
    /// expansion. A rapid re-focus while one was still mid-flight (the 450ms deferred correction
    /// pass) left it running loose against a `proxy`/row that could already be torn down by a pop —
    /// scrolling into a `ScrollViewReader` whose `ScrollView` no longer exists. Tracking the task
    /// lets a new expansion supersede the old one and lets `.onDisappear` cancel it outright.
    @State private var expansionScrollTask: Task<Void, Never>?

    // ── BUG-92: the first card's bleed, clipped at the row's leading edge ────────────────────────
    //
    // The two Appearance settings the bleed's width depends on, as REACTIVE inputs (the same
    // `@AppStorage` pair, under the same keys, that `PinnedRowTitleTracking` and `PosterCard` read —
    // a bare `UserDefaults` read here would recompute the allowance only when something else
    // happened to re-render the row, so toggling either setting would leave the clip sized for the
    // previous mode indefinitely).
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    /// How far past the row's leading edge a focused FIRST card may bleed — the width of the clip
    /// `RowLeadingEdgeClip` opens for it. See that type's header for the whole BUG-92 argument;
    /// this is the attachment it documents and deliberately did not make itself.
    private var leadingEdgeAllowance: CGFloat {
        // Codex beta.18 r4 (P2): the widest thing the first card can be is the EXPANDED inline trailer
        // tile (`posterStyle.height * 16/9` for a portrait card, see InlineTrailerCard's tile
        // geometry), and the focus lift scales that whole label — size the bleed off the maximum,
        // not the resting poster width, or the first playing trailer gets a hard clipped edge.
        let restingWidth = posterStyle.landscapeCatalogRows ? Theme.Size.landscapeWidth : posterStyle.width
        let posterWidth = max(restingWidth, rowArtworkHeight * 16 / 9)
        // No lift at all in No Zoom mode (`CardFocusMode.still` — `PosterCard.swift` swaps in
        // `StillCardButtonStyle` + `.focusEffectDisabled(true)`, which scales nothing), so only the
        // ring can bleed there. Otherwise this recomputes `PosterCard.swift`'s own
        // `cardLiftScale(artworkHeight:)` from the SAME public constant, because that function is
        // `private` to that file and one call site does not justify a new cross-file symbol. If it
        // is ever made internal, call it instead of keeping two copies of the formula in step.
        let liftScale = noZoomOnFocus ? 1 : 1 + 2 * Theme.Size.heroPinnedRowFocusLiftAllowance / rowArtworkHeight
        // Mirrors `PosterCard.swift`'s `ringInset(accentFocusRing:noZoomOnFocus:)` — either ring
        // reserves the same band, and neither reserves anything when both are off.
        let ring: CGFloat = (accentFocusRing || noZoomOnFocus) ? ringWidth : 0
        return RowLeadingEdgeClip.allowance(posterWidth: posterWidth,
                                            liftScale: liftScale,
                                            ringWidth: ring)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Classic keeps the title as a plain sibling above the shelf. PINNED mode instead
            // overlays the title INSIDE the shelf's top reach band (below) so the focused
            // cards' frames — which the focus engine's scroll-to-reveal aligns — physically
            // contain the title's region. Earlier attempts reached the card frames upward
            // with NEGATIVE compensating paddings; once the reach exceeded the row's own
            // bounds the focused item sat outside its .focusSection() geometry and the
            // engine's directional resolution FROZE outright (sim-reproduced, device rounds
            // 5–7). All-positive paddings keep every frame inside the row.
            //
            // The "See All" affordance is a trailing CARD inside the shelf (device round 5,
            // Christian's call): the old header pill was a focusable stop BETWEEN rows, so
            // vertical focus travel could land on it and reveals would align its tiny frame —
            // degenerate rest positions (sliver rows, floating pill, art cut at the fold).
            if cardTopReach == 0 {
                Text(section.title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.rowGap) {
                        ForEach(section.items, id: \.id) { item in
                            Group {
                                if let onSelect {
                                    Button { onSelect(item) } label: {
                                        card(for: item, proxy: proxy)
                                            .padding(.top, cardTopReach)
                                            .padding(.bottom, cardBottomReach)
                                            // BUG-87/89 (rc11): transparent floor on the REVEALED
                                            // frame — 0 for every row but Home's last. `.top` so the
                                            // artwork and caption do not move a point.
                                            .frame(minHeight: cardLinkFrameFloor > 0 ? cardLinkFrameFloor : nil,
                                                   alignment: .top)
                                    }
                                        .cardFocusButtonStyle()
                                        .posterButtonShape()
                                } else {
                                    NavigationLink(value: TitleRoute(preview: item)) {
                                        card(for: item, proxy: proxy)
                                            .padding(.top, cardTopReach)
                                            .padding(.bottom, cardBottomReach)
                                            // BUG-87/89 (rc11): transparent floor on the REVEALED
                                            // frame — 0 for every row but Home's last. `.top` so the
                                            // artwork and caption do not move a point.
                                            .frame(minHeight: cardLinkFrameFloor > 0 ? cardLinkFrameFloor : nil,
                                                   alignment: .top)
                                    }
                                    .cardFocusButtonStyle()
                                    .posterButtonShape()
                                }
                            }
                            .focused($focusedItemId, equals: item.id)
                            // F13: the shared long-press menu (library, watched). Same order as
                            // the Continue Watching row: after `.focused`, so the binding still
                            // names the button itself.
                            .posterContextMenu(item)
                            // Mirrors Detail's hero trailer: the card's mute glyph isn't reachable by
                            // the focus engine, so play/pause is the toggle. Nil unless *this* focused
                            // card is the one playing — an unconditional handler would swallow
                            // play/pause from everything else that wants it (Home's hero).
                            .onPlayPauseCommand(perform: muteToggle(for: item))
                            .id(item.id)
                        }

                        // Trailing "See All" card (see the header comment). Same gate as the
                        // pill had; same route.
                        if canOpenFullCatalog {
                            NavigationLink(value: CatalogRoute(section: section)) {
                                SeeAllCard()
                                    .padding(.top, cardTopReach)
                                    .padding(.bottom, cardBottomReach)
                                    // BUG-87/89 (rc11): transparent floor on the REVEALED frame — 0
                                    // for every row but Home's last. `.top` so the artwork and
                                    // caption do not move a point.
                                    .frame(minHeight: cardLinkFrameFloor > 0 ? cardLinkFrameFloor : nil,
                                           alignment: .top)
                            }
                            // BUG-93: SeeAllCard uses tileFocusLift, not CardFocusTreatment - keep the native lift in ring mode.
                            .cardFocusButtonStyle(lift: .plain)
                            .posterButtonShape()
                            // Codex r3 P2-1: the See All tile is part of THIS row, so the settle
                            // re-reveal has to count it as the row holding focus — otherwise
                            // focusing it cleared `focusedItemId`, the row stopped publishing its
                            // frame, and a Large rest reached with See All focused got no
                            // correction (title left on the artwork, or belt-hidden).
                            //
                            // Bound into the row's EXISTING `focusedItemId` under a sentinel rather
                            // than added as a second `@FocusState`: the sentinel can never equal a
                            // catalog item's id, so every other consumer of this binding is
                            // byte-identical. `onChange` still resolves it to no item and reports
                            // `nil` to the hero (exactly what focusing See All did before), and
                            // `muteToggle(for:)` still never matches it. Only the settle
                            // tracker's `focusedItemId != nil` test changes meaning.
                            .focused($focusedItemId, equals: Self.seeAllFocusKey)
                        }
                    }
                    // ALWAYS positive — the reach lives inside the buttons' labels, the row's
                    // frame contains it whole, and nothing pokes outside the focus section.
                    .padding(.vertical, Theme.Spacing.lg)
                    // BUG-92: clip ONLY the leading edge, and only by what a focused card's lift +
                    // ring can legitimately put outside its own frame. `.scrollClipDisabled()`
                    // below exists so a focused card's bleed can land over its LEFT NEIGHBOUR,
                    // which hides it; card #1 has no neighbour, so its bleed lands on the empty
                    // overscan margin where nothing hides it — the "trailer spills past the edge"
                    // the tester reported, on the first card of every row.
                    //
                    // On the CONTENT, never on the `ScrollView`: a `clipShape` on the scroll view
                    // itself would re-clip in the viewport's space and undo the one thing
                    // `.scrollClipDisabled()` is here for. Every other side of the shape is left
                    // ~2000pt open, so this can never reach a direction BUG-92 was not about — a
                    // card's vertical lift, the row's reach band, or the inline trailer's rightward
                    // morph (UX-4a). See `RowLeadingEdgeClip`.
                    .clipShape(RowLeadingEdgeClip(allowance: leadingEdgeAllowance))
                }
                .scrollClipDisabled()
                // Pinned: the title floats over the (transparent) reach band at the shelf's
                // top-leading corner — visually where it always was, but INSIDE the region
                // the focused cards' frames cover, so every reveal shows it.
                //
                // BUG-37: "inside the region the frames cover" is necessary but not sufficient on
                // hardware — a rest that falls 40–67pt short leaves the top of that region above
                // the viewport's clip edge, title included. `pinnedRowTitleTracking` rides the
                // title down to the clip edge for exactly that shortfall (render-time only; no
                // layout, no state, no identity). See its doc comment for why the band cannot
                // simply be widened and why card-anchoring the title buys nothing.
                .overlay(alignment: .topLeading) {
                    if cardTopReach > 0 {
                        Text(section.title)
                            .font(Theme.Font.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            // Legibility for the slid state only: at a short rest the title parks
                            // against the clip edge and can overlap the top of the artwork. Over
                            // the flat background of a true rest this is invisible.
                            .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                            .pinnedRowTitleTracking(rowKey: section.key,
                                                    artworkHeight: rowArtworkHeight,
                                                    isFocused: focusedItemId != nil)
                            .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .focusSection()
        // Settle re-reveal (2026-08-30): publishes this row's frame while it holds focus, so a
        // rest that parks its title under the pinned clip edge can be corrected once the scroll
        // settles. Inert in classic mode and while unfocused — see `pinnedRowSettleTracking`.
        // `focusedItemId != nil` covers the trailing See All tile too, via `seeAllFocusKey` —
        // that tile is part of this row and its rests need the same correction (Codex r3 P2-1).
        .pinnedRowSettleTracking(rowKey: section.key, isFocused: focusedItemId != nil)
        // BUG-112 (Item A): Home's Up fallback may ask this row to take focus. Inert in Search /
        // Library / the catalog grid — only HomeView publishes `pinnedRowFocusRequest`.
        .pinnedRowUpFallbackTarget(rowKey: section.key,
                                   firstId: section.items.first?.id,
                                   focus: $focusedItemId)
        .onChange(of: focusedItemId) { _, newId in
            onItemFocusChange?(newId.flatMap { id in section.items.first { $0.id == id } })
        }
        // H3: the row (and its ScrollViewReader) can disappear mid-flight — a pop while the
        // deferred 450ms correction pass is still pending. Cancel rather than let it fire against
        // a torn-down proxy.
        .onDisappear { expansionScrollTask?.cancel() }
    }

    /// Portrait poster by default; a 16:9 landscape card when the user enables landscape catalog
    /// rows — both rendered by `InlineTrailerCard`, which also grows the muted trailer preview once
    /// focus rests on the card. With inline trailers off it is a straight pass-through to the same
    /// two cards, so the row is unchanged.
    private func card(for item: MetaPreview, proxy: ScrollViewProxy) -> some View {
        InlineTrailerCard(item: item, enabled: inlineTrailersActive) { expanded in
            expansionChanged(itemId: item.id, expanded: expanded, proxy: proxy)
        }
    }

    /// BUG-29: an inline-trailer expansion morphs the focused card wider **to the right** in place —
    /// focus never moves (it's still the same button), so tvOS never issues its usual focus-driven
    /// scroll, and a card near a row's trailing edge grows straight off the visible strip. Ask the
    /// `ScrollView` to bring the card back into view ourselves whenever it expands; a `nil` anchor
    /// asks for the *minimal* scroll needed, so a card that already fits doesn't jump. Collapsing
    /// needs no help — the row only ever overflows while a card is wide, never while it's back to
    /// poster width.
    ///
    /// Deferred by one runloop hop so the scroll targets the tile's *expanded* geometry: `expanded`
    /// flips the instant the morph starts (`InlineTrailerCardModel.setPhase`), not when it finishes,
    /// so scrolling in the same tick would still measure the old, narrower frame. The morph itself
    /// runs 0.35s (`InlineTrailerCardModel.morphAnimation`), so the deferred scroll still lands well
    /// inside it and the two animate together visually.
    private func expansionChanged(itemId: String, expanded: Bool, proxy: ScrollViewProxy) {
        guard expanded else { return }
        // Device finding (BUG-29 round 2): a nil-anchor scrollTo at morph START is a no-op —
        // the tile's pre-growth frame is still fully visible at that moment, so "minimal
        // scroll" resolves to nothing and the tile then grows off the trailing edge anyway.
        // Two-part fix: the LAST item deterministically needs its trailing edge pinned to the
        // viewport (no geometry read needed), and every other item gets a correction pass
        // AFTER the 0.35s morph settles, when scrollTo finally sees the expanded frame.
        let anchor: UnitPoint? = itemId == section.items.last?.id ? .trailing : nil
        // H3: supersede any still-pending correction pass from a previous expansion rather than
        // letting both race the same proxy.
        expansionScrollTask?.cancel()
        if CatalogGridProbe.enabled { CatalogGridProbe.log("expansionChanged fire item=\(itemId)") }
        expansionScrollTask = Task { @MainActor in
            scrollToExpanded(itemId, anchor: anchor, proxy: proxy)
            try? await Task.sleep(nanoseconds: 450_000_000)
            // H3: the row may have disappeared (or a newer expansion may have superseded this
            // task) during the sleep — bail instead of scrolling a proxy that could be gone.
            guard !Task.isCancelled else {
                if CatalogGridProbe.enabled { CatalogGridProbe.log("expansionChanged cancelled skip item=\(itemId)") }
                return
            }
            scrollToExpanded(itemId, anchor: anchor, proxy: proxy)
        }
    }

    private func scrollToExpanded(_ itemId: String, anchor: UnitPoint?, proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(itemId, anchor: anchor)
        } else {
            withAnimation(InlineTrailerCardModel.morphAnimation) {
                proxy.scrollTo(itemId, anchor: anchor)
            }
        }
    }

    /// Play/pause handler for `item`'s focusable button, or `nil` when this card isn't the focused,
    /// currently-playing one — `.onPlayPauseCommand(perform: nil)` leaves the command to whoever
    /// else is listening instead of consuming it.
    private func muteToggle(for item: MetaPreview) -> (() -> Void)? {
        guard focusedItemId == item.id,
              trailerCoordinator.playingKey == TrailerResolutionCache.key(type: item.type, id: item.id)
        else { return nil }
        return { HeroTrailerAudioState.shared.toggleMuted() }
    }
}

/// The trailing "See All" tile at the end of a catalog row (device round 5 of the pinned-hero
/// pass — replaces the focusable header pill; see CatalogRowView's header comment for why).
/// Shaped like the row's RESTING cards — portrait per the user's Poster Style, or 16:9 landscape
/// when landscape catalog rows are on — so the shelf reads as one continuous strip and vertical
/// focus travel always lands on card-sized frames. When captions are visible, an empty caption
/// slot keeps the tile's art aligned with its neighbors' art. Standard system lift via
/// `tileFocusLift` (BUG-31: it goes still with "No Zoom on Focus", which this tile used to
/// ignore — the row's posters froze while See All kept zooming); in FEAT-14 ring mode the tile
/// deliberately keeps the system treatment — the accent ring marks CONTENT cards, and a
/// utility tile reads fine without it.
struct SeeAllCard: View {
    @Environment(\.posterStyle) private var style

    private var tileWidth: CGFloat {
        style.landscapeCatalogRows ? Theme.Size.landscapeWidth : style.width
    }
    private var tileHeight: CGFloat {
        style.landscapeCatalogRows ? Theme.Size.landscapeHeight : style.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(spacing: Theme.Spacing.sm) {
                // Gap 7: a text style, not a fixed point size, so the glyph grows with Larger Text.
                Image(systemName: "chevron.right.circle.fill")
                    .font(Theme.Font.headline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("See All")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .frame(width: tileWidth, height: tileHeight)
            .background(
                Theme.Palette.surfaceElevated,
                in: RoundedRectangle(cornerRadius: style.cornerRadius)
            )
            .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: .posters)
            .tileFocusLift(cornerRadius: style.cornerRadius)

            if style.showTitle {
                // Empty caption slot: neighbors are art + caption, so without this the
                // LazyHStack's center alignment would float the tile relative to their art.
                Text(verbatim: " ")
                    .font(Theme.Font.cardTitle)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }
}

/// A single poster tile, now backed by the shared `PosterCard` design-system component
/// (cached artwork, shimmer, brand focus ring, focus-aware title).
struct PosterCardView: View {
    let item: MetaPreview

    var body: some View {
        PosterCard(title: item.name, imageURL: item.poster)
    }
}
