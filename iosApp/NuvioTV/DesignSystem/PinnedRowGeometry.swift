import Foundation
import CoreGraphics

/// BUG-87 (beta.18): structural fit for the PINNED rows layout.
///
/// One place that answers "how tall is the thing the focus engine reveals, and does it fit in the
/// viewport it has to rest inside" — and, when it does not, which of the three dials the layout
/// owns should be spent to make it fit.
///
/// ## The defect this closes
///
/// Every tvOS scroll is reveal-driven: the focus engine scrolls so that the focused card's LINK
/// FRAME is on screen. In pinned mode that frame is not the artwork — the reach bands live INSIDE
/// the `Button`/`NavigationLink` label (`BrowseComponents`, `CatalogRowView`'s `.padding(.top,
/// cardTopReach)` / `.padding(.bottom, cardBottomReach)`), so the revealed extent is
///
///     linkFrame = topReach + artwork + captionChrome + bottomReach
///
/// Wave 10's hero compression, however, was sized against a DIFFERENT quantity — `Spacing.lg +
/// topReach + artwork + cushion` — which charges neither the caption nor the downward reach. At
/// Poster Size = Large with Hide Labels ON that is a 535.3pt frame against a 523.3pt viewport: 12pt
/// over, and 55.5pt over with captions. An over-tall frame has TWO legal rests (the simulator
/// top-anchors it, hardware bottom-anchors it ~75pt deeper), the settle corrector chases whichever
/// one it did not get, and the tester sees row titles that "keep trying to move back" (BUG-87), a
/// title glitch during horizontal travel (BUG-88), and a second-to-last row that regresses after a
/// Medium → Large switch until the app is restarted (BUG-89).
///
/// Christian approved the structural fix: make the frame FIT, so the engine has exactly one rest
/// and the corrector has nothing to correct.
///
/// ## What gets spent, and in what order
///
/// Three dials, each a pure `min`. The REACHES are spent first, down to their floors, and the hero
/// compression takes only what is left:
///
///  1. **The downward reach** (`heroPinnedRowBottomReach` 44 → `bottomReachFloor` 24, 20pt of
///     give). It covers the mirror-direction rest error and has no content to protect below it, so
///     it is the cheapest dial in the file.
///  2. **The upward reach** (`heroPinnedRowTopPad` 88 → `topReachFloor(lift:titleHeight:)`, 22pt of
///     give with No Zoom on and 2pt with either zoom mode in the system font). It is never RAISED
///     here, only lowered, and never below the floor: `heroPinnedRowTitleInset` (48) + the ACTIVE
///     font's measured title line (38 system, ≈42.2 Open Sans) − `Spacing.lg` (24) holds the TITLE,
///     and the floor adds the focus lift and the belt's `fadeIntrusionArm` on top of it — see
///     `topReachFloor(lift:titleHeight:)` and the rc10 note below.
///  3. **Hero compression**, for whatever demand the two reaches could not cover, bounded by what
///     the pinned hero's internals can actually yield
///     (`Theme.Size.heroPinnedCompressionCap(showsCTA:)`).
///
/// ### Why this order (rc2 tester feedback, 2026-09-06)
///
/// The first cut of this file spent compression FIRST, on the reasoning that the hero's elastic
/// slots cost nothing structural while the reaches are the app's most regression-prone dials. At
/// the tester's shape that produced a 112.33pt compression, and the FEAT-15 focus panel spends
/// compression out of its synopsis slot first: 144 − min(112.33, 108) = 36pt of slot (the last
/// 4.33 came out of the logo), one line of description where beta.17 showed three. He filmed it and objected — "one line is not enough". Christian's
/// decision: keep the three lines, spend the two reach cushions instead. Both cushions exist to
/// absorb REST ERROR, and the whole point of this file is that a frame which fits has exactly one
/// rest and therefore no error to absorb; the compression's cost, by contrast, is content the
/// viewer reads. Spending the reaches first drops the tester's compression to 68.33 — Wave 10's own
/// Large number, the one beta.17 shipped and he never complained about — and the panel is back to
/// three lines.
///
/// ### The trade this order makes — rc4's open question, ANSWERED (rc10, BUG-87/89)
///
/// rc4 shipped a flat `topReachFloor` of 64 and this header said so plainly: it sat BELOW the
/// long-proven 72, it left the settled title a **2pt** static clearance rather than BUG-53's 26, and
/// with No Zoom OFF "there is [a lift], and nothing here proves the outcome". The tester's rc8 Row
/// Settle pane proved it, and the outcome was bad: at Large with zoom on, `staticClearance` 2 minus
/// the 20pt lift is **−18** — the focused card's artwork permanently 18pt over the settled title's
/// bottom — and `PinnedRowTitle.Clearances`' `max(…, 0)` reported it as a clean **0**. That single
/// clamp is why the defect read as a scroll problem for a whole release: `PinnedRowSettle`'s
/// `bandLow` became 0, which excluded the hardware's own bottom-anchored rest (≈ −31) by ~30pt, so
/// nearly every visit fired a correction (`UNEXPECTED-WITH-FIT`, nudges −12/−94/+27) that could only
/// swap one out-of-band rest for another; the belt, measuring intrusion against the same 0, faded
/// the titles it could not help (`clearanceLift=0` on every belt line of that pane).
///
/// Christian's decision: **take the clearance.** The floor is now derived, MODE-AWARE and
/// FONT-AWARE — `topReachFloor(lift:titleHeight:)` = title inset 48 + the active font's measured
/// title line − `Spacing.lg` 24 + the active lift + the belt's `fadeIntrusionArm` (4) — which in the
/// system font is 66 with No Zoom on and **86** with either zoom mode. 86 is back INSIDE the proven
/// 72-88 corridor, so rc4's "is 64 safe?" question is retired rather than doubled, and the settled
/// focused title clears the artwork by 4pt (one arm width) in BOTH modes by construction instead of
/// by luck.
///
/// The font term is the rc10 Codex P2 half of the same defect: the floor reserved a hard-coded 38pt
/// title while the clearance it protects is measured live, so FEAT-31's Open Sans (≈42.2pt at the
/// same text style) reproduced the negative `focusedRaw` the derived floor exists to remove — and the
/// `LIFT-DEFICIT` stand-down with it. Open Sans + zoom on now wants 90.2 and takes the 88 cap, which
/// leaves 1.8pt of clearance: positive, so the corrector keeps working, but inside the belt's arm
/// band. See `topReachFloor(lift:titleHeight:)` for that trade and for where the stand-down is still
/// the right answer (titles past ≈44pt, i.e. accessibility text sizes).
///
/// The price is paid in hero compression: at Large + Hide Labels + panel it goes 68.33 → **90.33**
/// with zoom on (70.33 with No Zoom), which takes the panel's synopsis from 3 lines to 2 in both
/// modes. That cost is real and is documented at `topReachFloor(lift:)`; the dial to move if the
/// third line has to come back is `heroPinnedFrameSlack` or `HeroSlotGive`'s tier-3 gate, never this
/// floor. Two things the device pass still owns, both narrower than rc4's: that focus never
/// hesitates at reach 86/66 (both inside the corridor, so this is a sanity check), and that the hero
/// at the deeper compression still reads acceptably.
///
/// ## Unsatisfiable by design
///
/// Large + captions + carousel hero demands ~155.8pt against 44pt of reach give and an elastic give
/// of ~70 — 114 against 156. That case CANNOT be made to fit and is not pretended otherwise: the
/// plan reports `fits == false`, returns TODAY'S numbers verbatim (Wave 10's compression, reach
/// 88/44) so the belt regime is bit-identical to beta.17, and logs once per regime. A too-tall row
/// costs a hidden row title, never a broken hero — the same handoff contract `PinnedRowSettle` and
/// the visibility belt have always had.
///
/// ## Scope gate — Small and Medium are untouched
///
/// The plan spends NOTHING at a Poster Size whose row already fits Wave 10's own extent rule, i.e.
/// wherever `PinnedRowTitle.pinnedHeroCompression` computes 0 today: Small (395), Medium (450) and
/// landscape catalog rows (323), all under the 455 budget, at EVERY flag combination. That is a
/// deliberate scope decision, not an oversight — Medium is the default Poster Size with captions
/// ON, its device/sim band table records zero corrections, and keying its compression to the link
/// frame would silently compress the default configuration's hero by ~82pt to fix a rest nobody has
/// reported. The structural fix applies to the sizes that were ALREADY compressing, which is
/// exactly the population that reports the bug.
///
/// The gate reads through `PinnedRowTitle.pinnedHeroCompression`, so `-debug.pinnedHeroCompressionOff`
/// (test48's historical-geometry knob) keeps working unchanged: with the knob set the legacy
/// compression is 0 everywhere, the gate stays shut, and every plan returns the pre-Wave-10 reaches
/// and viewport.
enum PinnedRowGeometry {

    /// Everything the pinned rows layout needs to agree on for ONE (Poster Size × caption × hero
    /// form × row shape) regime. Every field is derived; nothing here is a literal.
    nonisolated struct Plan: Equatable, Sendable {
        /// How far the pinned hero yields to the rows below it (`HomeHeroForeground.compression`).
        var compression: CGFloat
        /// The upward reach each row card's focusable label carries (`\.rowCardTopReach`).
        var topReach: CGFloat
        /// The downward reach each row card's focusable label carries (`\.rowCardBottomReach`).
        var bottomReach: CGFloat
        /// The pinned rows viewport this plan produces: `budget + compression`.
        var viewport: CGFloat
        /// The extent the focus engine actually reveals for a focused card in this regime.
        var linkFrame: CGFloat
        /// Whether that extent fits inside the viewport — i.e. whether the engine has ONE rest.
        var fits: Bool
        /// How much room the viewport has left over once the link frame is inside it. This is the
        /// width of the set of legal rests: 0 means a single rest, and it is bounded above by
        /// `Spacing.lg + heroPinnedRowsSettledCushion` (32) whenever the full demand was spent.
        var restRange: CGFloat
        /// Short stable identity for this regime, e.g. `L403c0p1r0z1t38` — Large, no captions, panel
        /// hero, portrait rows, No Zoom on. Used as the `onChange` key that re-reveals the rows
        /// after a Poster Size switch (BUG-89) and as the log-once key below.
        var regimeKey: String
    }

    /// BUG-87/89 (rc11, hardened rc12): the minimum focusable-label height Home's LAST pinned row
    /// must carry so the focus engine cannot park it outside the legibility band — see
    /// `EnvironmentValues.rowCardLinkFrameFloor` for the reveal argument.
    ///
    /// The floor is the LARGER of the plan's own link frame and `viewport − Theme.Spacing.lg`, not
    /// `plan.linkFrame` alone (rc11's version). `plan.linkFrame` matches every OTHER row's revealed
    /// extent, so it looks like the right floor — but the engine tolerates any rest whose margin
    /// falls in `[24, 24 + restRange]`, and `restRange = viewport − linkFrame` can run past the
    /// band's own upper edge (48) whenever a regime's reach-spend left slack above 24pt: the
    /// hero-OFF panel at Large/Medium+ carries `restRange` 32 (max margin 56), and Small without
    /// captions carries 72 (max margin 96). Flooring at `linkFrame` alone permits the label to rest
    /// as high as that slack allows — legal for the engine, but the last row can then park with its
    /// title well above the band, and the rc11 exemption below (`lastRowShaped`) then suppresses the
    /// correction that would otherwise have pulled it back down.
    ///
    /// `viewport − Spacing.lg` closes that gap: it is the height that makes the label's OWN
    /// `restRange` exactly `Spacing.lg` (24), i.e. `margin ∈ [24, 24 + 24] = [24, 48]` — the band's
    /// full width and no more, so "fully revealed" forces `rowTop ∈ [−24, 0]` regardless of what the
    /// regime's own restRange was. Taking the max with `plan.linkFrame` keeps the rc11 guarantee for
    /// every regime where the plan's own frame already confines the rest that tightly (every
    /// carousel plan; every regime with `restRange <= Spacing.lg`) — the floor never goes SHORTER
    /// than the frame itself. The frame still fits the viewport by construction: `floor +
    /// Spacing.lg <= viewport` always holds, because `plan.linkFrame + Spacing.lg <= viewport +
    /// Spacing.lg` (trivial) and `(viewport − Spacing.lg) + Spacing.lg == viewport`.
    ///
    /// 0 when the regime does not fit — an over-tall frame already has two anchorings and raising a
    /// short row to match it would only add a third.
    nonisolated static func lastRowLinkFrameFloor(plan: Plan) -> CGFloat {
        guard plan.fits else { return 0 }
        return max(plan.linkFrame, plan.viewport - Theme.Spacing.lg)
    }

    /// How much transparent bottom padding `lastRowLinkFrameFloor` adds to a label whose natural
    /// height is `labelFrame` (= topReach + artwork + captionChrome + bottomReach for that CARD).
    /// Reporting/verification only — the layout applies the floor as a `minHeight`, which needs no
    /// per-card arithmetic. Uniform poster/landscape rows return 0 by construction: their label IS
    /// the plan's link frame.
    nonisolated static func lastRowBottomReachExtra(plan: Plan, labelFrame: CGFloat) -> CGFloat {
        max(lastRowLinkFrameFloor(plan: plan) - labelFrame, 0)
    }

    // MARK: - Floors

    /// Floor for the downward reach. It exists to absorb the mirror-direction rest error, and 24
    /// (`Theme.Spacing.lg`, the shelf's own bottom padding) is the point at which the focused
    /// card's caption still clears the fold without the reach's help.
    ///
    /// Spent FIRST as of the rc2 reordering, so every compressing Poster Size now runs at 24 rather
    /// than only the shapes that could not otherwise fit — see the header's trade note.
    nonisolated static let bottomReachFloor: CGFloat = Theme.Spacing.lg

    /// The band above the artwork must hold the TITLE *and* whatever the focus treatment raises the
    /// focused card's artwork by. If it does not, the settled title lands on the picture by
    /// `lift − staticClearance` at EVERY rest, and no scroll correction can undo it: a scroll moves
    /// title and artwork together, so only `slide` changes their relationship and at a clean rest
    /// `slide` is already 0.
    ///
    /// BUG-87/89 (rc4 → rc10): the flat 64 was derived against the title ALONE
    /// (`titleInset 48 + measuredTitleHeight 38 − Spacing.lg 24 = 62`, plus 2pt of margin) and
    /// treated the lift as somebody else's problem. With zoom on it is 20pt, so at Large — the one
    /// Poster Size that spends this dial — the focused card's artwork ended up 18pt ABOVE the
    /// settled title's bottom, and `PinnedRowTitle.Clearances`' `max(…, 0)` reported that as ZERO.
    /// Everything downstream then misread it: `PinnedRowSettle`'s `bandLow` became 0, excluding the
    /// hardware's own bottom-anchored rest by ~30pt (the tester's repeated `UNEXPECTED-WITH-FIT`
    /// nudges), and the belt measured intrusion against 0 and faded the titles it could not help
    /// (`clearanceLift=0` on every belt line of the rc4 pane).
    ///
    /// So the floor is DERIVED and MODE-AWARE. `lift` is `PinnedRowTitle.focusLiftAllowance`'s own
    /// number for the active Appearance settings — 20 in both zoom-on modes, 0 with No Zoom on — and
    /// `fadeIntrusionArm` (4) is the belt's own arm edge, so a settled focused title sits OUTSIDE
    /// the arm band by construction rather than one rounding error inside it:
    ///
    ///     No Zoom on             62 + 0  + 4 = 66   (22 of the reach's 24pt of give still spent)
    ///     zoom on                62 + 20 + 4 = 86   (2pt of give; the remaining 22 goes to compression)
    ///     No Zoom + hold (rc12)  62 + 20 + 4 = 86   (default-OFF A/B — see below)
    ///
    /// ### rc12: the No Zoom reach-hold A/B (BUG-87 follow-up)
    ///
    /// Steven's rc10/rc11 sim walks in No Zoom park every row's rest 2pt outside the belt's arm band
    /// (`margin=-22` against `bandLo=-4`), the corrector nudges, two pullbacks disarm it, and the
    /// title fades — the exact symptom the zoom-on floor above was built to remove, just 2pt short of
    /// the band rather than 18. There is no hardware evidence either way: the tester runs zoom on, so
    /// no device walk has ever exercised No Zoom's reach. Rather than change the No Zoom default on
    /// simulator-only evidence, `PinnedRowTitle.FocusModeFlags.reachHoldsLift` (default OFF,
    /// `AboutSettingsPane`'s "No Zoom Row Reach (A/B)" row) lets `PinnedRowGeometry.plan` spend the
    /// SAME 86 floor in No Zoom as zoom-on — widening the band rather than charging a lift nothing
    /// produces (see `floorLift` in `plan` and `FocusModeFlags.reachHoldsLiftEffective`'s doc for why
    /// this is not routed through `focusLiftAllowance`). OFF is byte-identical to today; ON costs the
    /// Large hero-off panel one synopsis line, same as zoom-on already does (see the next section).
    /// Christian A/Bs it on hardware with the Row Settle pane; rc13 either promotes it to the No Zoom
    /// default or deletes it.
    ///
    /// ### What this costs the panel's synopsis — read before re-tuning
    ///
    /// The design note for this change claimed the No-Zoom floor kept the rc2 reorder's 3-line
    /// synopsis intact. It does NOT, and the margin is absurd: at Large + Hide Labels + panel the
    /// compression goes 68.33 → 70.33, `HeroSlotGive` tiers 1+2 cover 68, `heroPinnedFrameSlack` is
    /// 2, and the 0.33 left over opens tier 3 — synopsis slot 144 − 36.33 = 107.67, and
    /// `floor(107.67 / 36)` is **2**. That is exactly the boundary
    /// `testPanelAtStevensCompressionKeepsThreeSynopsisLines` was written to guard, crossed by a
    /// third of a point. Zoom on spends 22 more and lands at 2 lines outright (slot 87.67), and the
    /// rc12 reach-hold costs No Zoom the identical 2 lines when it is switched on. So both zoom
    /// modes, and No Zoom with the hold ON, now show a 2-line description where rc4 showed 3; plain
    /// No Zoom (hold OFF, the shipping default) is unaffected — Medium and below never reach this
    /// floor at all. Christian's decision was to take the clearance knowing the hero pays for it; if
    /// the third line has to come back, the dial to move is `heroPinnedFrameSlack` or the tier-3 gate
    /// in `HeroSlotGive`, NOT this floor — lowering the floor again reinstates the permanent
    /// title-on-artwork overlap this whole change removes.
    ///
    /// Capped at `heroPinnedRowTopPad`: this dial only ever moves DOWN (reach 100 kills focus
    /// resolution outright). 86 also lands INSIDE the proven 72-88 corridor, so the rc4 header's
    /// unanswered hardware questions about reach 64 are retired rather than doubled.
    ///
    /// ### `titleHeight` is the ACTIVE FONT's metric, not a constant (rc10 Codex P2)
    ///
    /// The first cut of this floor hard-coded 38 — the system font's `sectionTitle` line as measured
    /// on the FA87 fixture — while the clearance it is supposed to reserve room for
    /// (`PinnedRowTitle.staticClearance`) is computed from the title's LIVE measured height. Under
    /// FEAT-31's Open Sans the two disagree by ≈4pt (42.2 against 38), which is the entire margin
    /// this floor keeps, so at Large with zoom on the derived reach of 86 left
    /// `atRest = (24 + 86) − (48 + 42.2) = 19.8`, `focusedRaw = −0.2` — negative, i.e. the corrector's
    /// `LIFT-DEFICIT` stand-down, permanently, for the session, on a font the app ships. The default
    /// is therefore `Theme.Font.sectionTitleLineHeight`, measured from the face the token actually
    /// resolves to. A DEFAULT ARGUMENT rather than a read inside the body, so the unit suite can pin
    /// a fixed height and assert numbers instead of following whatever family the host has applied —
    /// which is also why that metric is the one `Theme.Font` member declared `nonisolated(unsafe)`:
    /// a nonisolated function's default value expression may not touch main-actor state.
    ///
    /// ### At the 88 cap the belt's arm is no longer guaranteed — by design
    ///
    /// Open Sans + zoom on wants `48 + 42.2 − 24 + 20 + 4 = 90.2` and gets the cap, 88. The settled
    /// focused title then clears the artwork by `24 + 88 − 48 − 42.2 − 20 = 1.8`: still POSITIVE, so
    /// the geometry is legible and the corrector keeps working (`focusedRaw >= 0`, no stand-down, and
    /// the band the corrector aims into is simply 2.2pt narrower at its low edge), but under
    /// `fadeIntrusionArm`, so the belt may arm on a rest that is technically clear. That is the right
    /// trade at the cap: the alternative is a reach past 88, which kills focus resolution outright.
    /// A title taller than ≈44pt (accessibility text sizes, in either font) pushes `focusedRaw`
    /// negative even at the cap, and that IS the stand-down's job — see the `LIFT-DEFICIT` branch in
    /// `PinnedRowSettle.settlePlan`.
    nonisolated static func topReachFloor(lift: CGFloat,
                                          titleHeight: CGFloat = Theme.Font.sectionTitleLineHeight) -> CGFloat {
        let titleFloor = Theme.Size.heroPinnedRowTitleInset + titleHeight - Theme.Spacing.lg
        return min(Theme.Size.heroPinnedRowTopPad, titleFloor + lift + PinnedRowTitle.fadeIntrusionArm)
    }

    /// The SYSTEM font's `Theme.Font.sectionTitle` line as rendered on the FA87 fixture — the number
    /// this floor was originally derived against, and every arithmetic expectation in
    /// `PinnedRowGeometryTests` with it.
    ///
    /// No longer read by any shipping path (`topReachFloor` takes the live metric — see above). It
    /// survives as the tests' fixed reference, so the unit suite asserts numbers rather than
    /// whatever font family the host simulator happens to be running.
    nonisolated static let measuredTitleHeight: CGFloat = 38

    // MARK: - Give

    /// Everything the pinned hero can yield in the form it is currently rendering.
    ///
    /// Carousel (`showsCTA == true`): logo 32 + synopsis 36 + frame slack 2 = 70, exactly Wave 10's
    /// `heroPinnedCompressionCap`. Focus panel (FEAT-15, `showsCTA == false`): the synopsis slot has
    /// already absorbed the CTA slot and the gap above it (144 against 72 — see
    /// `HomeHeroForeground.synopsisSlotHeight`), so its give against the same one-line floor is 108
    /// and the total is 142.
    nonisolated static func elasticGive(showsCTA: Bool) -> CGFloat {
        Theme.Size.heroPinnedCompressionCap(showsCTA: showsCTA)
    }

    // MARK: - How the hero spends it

    /// How a given `compression` is divided between the pinned hero's two elastic slots.
    ///
    /// Extracted out of `HomeHeroForeground` (whose `synopsisSlotGive` / `logoSlotGive` are now thin
    /// wrappers) purely so the arithmetic is unit-testable: it is a value function over three
    /// booleans-and-a-number with no view, no environment and no measurement in it.
    ///
    /// ## The three tiers (rc2, 2026-09-06)
    ///
    /// FEAT-15's focus panel folds the CTA slot into its synopsis slot — 144pt against the
    /// carousel's 72 (`Theme.Size.heroSynopsisSlotHeightPinnedPanel`) — and
    /// `HomeHeroForeground.synopsisLineLimit` is `floor(slotHeight / 36)`. Spending the panel's
    /// whole 108pt of synopsis give before touching the logo meant the tester's 68.33pt compression
    /// came entirely out of the description: slot 75.67 ⇒ **2 lines**, where beta.17's Wave 10 split
    /// (synopsis 36 + logo 32) left 108 ⇒ **3**. He objected to the one-line version at the old
    /// 112.33 compression, and 2 is still a regression against what he had.
    ///
    /// So the panel spends in three tiers, and the first two are exactly the carousel's:
    ///
    ///  1. `heroSynopsisSlotPinnedGive` (36) — the synopsis give BOTH forms have.
    ///  2. `heroLogoSlotPinnedGive` (32) — the logo, down to its 78pt floor.
    ///  3. Only then the extra the panel absorbed from the CTA (108 − 36 = 72), and only for the
    ///     part of the compression that exceeds tiers 1+2 by more than the hero frame's own
    ///     `heroPinnedFrameSlack` (2pt of frame that holds no content).
    ///
    /// That slack term is what makes the tester's shape land on 3 lines rather than 2: at 68.33 the
    /// first two tiers give 68 and the leftover 0.33 is frame slack, not content, so tier 3 stays
    /// shut and the synopsis slot is a clean 108. Without it, 0.33pt of tier-3 spend would take the
    /// slot to 107.67 and `floor(107.67 / 36)` is 2.
    ///
    /// ## Invariants
    ///
    ///  - **Nothing hard-clips**: `total >= compression - heroPinnedFrameSlack` for every
    ///    compression up to that form's `elasticGive`. Tier 3 is defined as the excess PAST the
    ///    slack, so in the region where it is open the total is exactly `compression - slack`.
    ///  - **Floors hold**: synopsis give ≤ `slot - heroSynopsisSlotHeightPinnedFloor`, logo give ≤
    ///    `heroLogoSlotPinnedGive`, for title heroes.
    ///  - **The carousel is bit-identical** to what shipped: its tier-3 ceiling is
    ///    `72 - 36 - 36 == 0`, so the function reduces to the old two-step `min`.
    ///  - **Folder heroes are bit-identical** to FEAT-29: `folderHero` keeps its own rule (the whole
    ///    synopsis slot has a genuine 0 floor because a folder preview carries no description, and
    ///    the logo takes an unbounded remainder), untouched by the tiers above.
    nonisolated enum HeroSlotGive {

        /// What each slot yields. Both are subtracted from the slot's pinned height by the view.
        struct Split: Equatable, Sendable {
            var synopsis: CGFloat
            var logo: CGFloat
            /// What the CONTENT gave up, against which the frame shrank by `compression`.
            var total: CGFloat { synopsis + logo }
        }

        /// - Parameters:
        ///   - compression: `PinnedRowGeometry.Plan.compression`, i.e. how much shorter the hero's
        ///     frame is being made. 0 outside pinned mode.
        ///   - showsCTA: the carousel form (true) or FEAT-15's focus panel (false).
        ///   - folderHero: `HomeView.isCollectionHero(item)` — a collection folder's preview, which
        ///     has no description and no meta line to protect (FEAT-29).
        static func split(compression: CGFloat,
                          showsCTA: Bool,
                          folderHero: Bool) -> Split {
            guard compression > 0 else { return Split(synopsis: 0, logo: 0) }
            let slot = showsCTA ? Theme.Size.heroSynopsisSlotHeightPinned
                                : Theme.Size.heroSynopsisSlotHeightPinnedPanel

            // FEAT-29, unchanged: a folder hero's synopsis slot is empty, so all of it is give and
            // the logo takes whatever is left over with no ceiling of its own.
            guard !folderHero else {
                let synopsis = min(compression, slot)
                return Split(synopsis: synopsis, logo: max(compression - synopsis, 0))
            }

            // Tier 1 — the synopsis give both hero forms have.
            let firstSynopsis = min(compression, Theme.Size.heroSynopsisSlotPinnedGive)
            // Tier 2 — the logo, down to its floor.
            let logo = min(max(compression - firstSynopsis, 0), Theme.Size.heroLogoSlotPinnedGive)
            // Tier 3 — the CTA slot the panel absorbed, past the frame's own slack. 0 for the
            // carousel, whose synopsis give IS its whole give above the floor.
            let panelExtra = max(slot
                                 - Theme.Size.heroSynopsisSlotHeightPinnedFloor
                                 - Theme.Size.heroSynopsisSlotPinnedGive, 0)
            let beyond = max(compression - firstSynopsis - logo - Theme.Size.heroPinnedFrameSlack, 0)
            return Split(synopsis: firstSynopsis + min(beyond, panelExtra), logo: logo)
        }
    }

    // MARK: - The plan

    /// Resolves one regime. Pure: the same inputs always produce an equal `Plan` (the probe log
    /// below is fire-once-per-regime and has no effect on the value).
    ///
    /// - Parameters:
    ///   - posterHeight: `PosterStyle.height` — the tallest artwork a PORTRAIT pinned row presents.
    ///   - captionVisible: `PosterStyle.showTitle` (Hide Labels OFF).
    ///   - showsCTA: whether the pinned hero renders its CTA, i.e. the carousel form. False is
    ///     FEAT-15's focus panel, which has a larger synopsis slot and therefore more give.
    ///   - landscapeRows: `PosterStyle.landscapeCatalogRows`. Landscape catalog rows are 203pt tall,
    ///     so nothing needs to be spent for them. NOTE: a collection row whose folders keep the
    ///     portrait shape still presents `posterHeight`-tall tiles in this mode
    ///     (`FolderTile.artworkHeight`), and such a row is over-tall here exactly as it is at Medium
    ///     today — the belt owns it. Compressing a hero by ~112pt for a page whose catalog rows are
    ///     203pt tall would be the worse trade.
    ///   - mode: the two Appearance flags `PinnedRowTitle.focusLiftAllowance` branches on. The plan
    ///     is MODE-DEPENDENT as of BUG-87/89 rc10 — the top reach's floor has to hold the focus lift
    ///     — so a caller inside SwiftUI must pass `@AppStorage`-backed flags rather than let the
    ///     `.current` default latch whatever the defaults said last (the Codex r10 P2 staleness
    ///     class, closed for `PinnedRowTitleTracking` and closed here the same way).
    ///   - titleHeight: the rendered height of ONE `Theme.Font.sectionTitle` line, which the top
    ///     reach's floor has to reserve room for. Defaults to the ACTIVE font family's measured
    ///     metric (`Theme.Font.sectionTitleLineHeight`) — the plan is font-dependent for the same
    ///     reason it is mode-dependent, and a hard-coded 38 stood the corrector down under Open Sans
    ///     (see `topReachFloor(lift:titleHeight:)`). Tests pass a fixed number so their arithmetic
    ///     does not depend on the host's font.
    ///
    ///     `regimeKey` also takes this parameter and encodes it (rc10 Codex P2 fix 4): the plan has
    ///     been title-metric-dependent since fix 3 above, so two title metrics must not share a
    ///     regime — see `regimeKey`'s doc comment for why the previous "the remount already resets
    ///     everything" argument did not hold.
    nonisolated static func plan(posterHeight: CGFloat,
                                 captionVisible: Bool,
                                 showsCTA: Bool,
                                 landscapeRows: Bool,
                                 mode: PinnedRowTitle.FocusModeFlags = .current,
                                 titleHeight: CGFloat = Theme.Font.sectionTitleLineHeight) -> Plan {
        let artwork = landscapeRows ? Theme.Size.landscapeHeight : posterHeight
        let captionChrome = captionVisible ? PinnedRowTitle.cardLockupCaptionChrome : 0
        let baseTopReach = Theme.Size.heroPinnedRowTopPad
        let baseBottomReach = Theme.Size.heroPinnedRowBottomReach
        let budget = Theme.Size.heroPinnedRowsViewportBudget
        let key = regimeKey(posterHeight: posterHeight,
                            captionVisible: captionVisible,
                            showsCTA: showsCTA,
                            landscapeRows: landscapeRows,
                            mode: mode,
                            titleHeight: titleHeight)

        // BUG-87/89: the top reach's floor depends on the lift the band has to hold, read from the
        // same flags `PinnedRowTitle.focusLiftAllowance` reads. `.cardTreatment` because every
        // pinned row's cards go through `CardFocusTreatment`/`CardArtworkFocusLift` (BUG-108 brought
        // the collection folder row in too).
        let lift = PinnedRowTitle.focusLiftAllowance(artworkHeight: artwork,
                                                    captionVisible: captionVisible,
                                                    treatment: .cardTreatment,
                                                    mode: mode)
        // rc12 BUG-87 follow-up: the reach-hold A/B spends the SAME floor No Zoom would have if
        // zoom were on (`Theme.Size.heroPinnedRowFocusLiftAllowance`, the one clamp shared with
        // `focusLiftAllowance`'s zoom-on branches), never routed through `lift` itself — `lift` stays
        // 0 in No Zoom (nothing scales) and only the FLOOR widens to reserve the band that would
        // otherwise be missing. See `FocusModeFlags.reachHoldsLiftEffective` and the rc12 note on
        // `topReachFloor` above for why charging both would fabricate zero band instead of a wider
        // one.
        let floorLift = mode.reachHoldsLiftEffective
            ? max(lift, Theme.Size.heroPinnedRowFocusLiftAllowance)
            : lift
        let topFloor = topReachFloor(lift: floorLift, titleHeight: titleHeight)

        // Wave 10's number for this artwork, and the scope gate in one read: it is 0 at exactly the
        // Poster Sizes whose rows already fit the pre-BUG-87 extent rule, and 0 everywhere when
        // `debug.pinnedHeroCompressionOff` is set.
        let legacyCompression = PinnedRowTitle.pinnedHeroCompression(rowArtworkHeight: artwork)

        func settled(compression: CGFloat, topReach: CGFloat, bottomReach: CGFloat) -> Plan {
            let viewport = budget + compression
            let linkFrame = topReach + artwork + captionChrome + bottomReach
            return Plan(compression: compression,
                        topReach: topReach,
                        bottomReach: bottomReach,
                        viewport: viewport,
                        linkFrame: linkFrame,
                        fits: linkFrame <= viewport,
                        restRange: max(viewport - linkFrame, 0),
                        regimeKey: key)
        }

        // Today's geometry, unchanged — the `!fits` contract and the closed-gate answer.
        let unchanged = settled(compression: legacyCompression,
                                topReach: baseTopReach,
                                bottomReach: baseBottomReach)

        guard legacyCompression > 0 else {
            noteIfShort(unchanged)
            return unchanged
        }

        // The demand, keyed to the LINK frame — the extent the engine actually reveals — plus the
        // shelf's own top padding above it and the settled cushion below, which together are what
        // make a canonical rest sit fully inside the viewport rather than flush to its edges. The
        // formula is unchanged by the rc2 reordering; only the order the three dials pay it in is.
        // Each step below is a pure `min` against a real give; none can raise a dial.
        let demand = Theme.Spacing.lg
            + baseTopReach
            + artwork
            + captionChrome
            + baseBottomReach
            + Theme.Size.heroPinnedRowsSettledCushion
            - budget
        var short = max(demand, 0)

        // (a) The downward reach first — the cheapest dial, 20pt of give.
        let bottomSpend = min(short, baseBottomReach - bottomReachFloor)
        let bottomReach = baseBottomReach - bottomSpend
        short -= bottomSpend

        // (b) The upward reach next, down to its derived, LIFT-AWARE floor — 22pt of give with No
        //     Zoom on, 2pt with either zoom mode, because the band it leaves behind has to hold the
        //     title AND the focus lift (BUG-87/89).
        let topSpend = min(short, baseTopReach - topFloor)
        let topReach = baseTopReach - topSpend
        short -= topSpend

        // (c) Hero compression LAST, for the remainder — every point of it is description the
        //     viewer loses (the panel's synopsis slot is where it comes from), which is exactly the
        //     rc2 complaint this order answers.
        let compression = min(short, elasticGive(showsCTA: showsCTA))

        let plan = settled(compression: compression, topReach: topReach, bottomReach: bottomReach)
        guard plan.fits else {
            // Unsatisfiable: hand back today's numbers so the belt regime is exactly what shipped,
            // and say so once.
            noteIfShort(unchanged)
            return unchanged
        }
        return plan
    }

    /// `L403c0p1r0z1t38` — size tag + rounded artwork height, captions, panel (i.e. `!showsCTA`),
    /// landscape rows, (BUG-87/89 rc10) the zoom mode, and (rc10 Codex P2 fix 4) the rounded title
    /// metric. Stable across renders for one regime and different for every other, which is all
    /// `onChange` and the log-once key need it to be.
    ///
    /// `z` is not cosmetic: the plan is MODE-DEPENDENT (`topReachFloor(lift:)` holds the focus lift,
    /// so the two zoom modes produce different reaches and a different compression at the same
    /// Poster Size), so two modes must not share a regime key. `PinnedRowSettle.regimeFits` and its
    /// log-once sets are keyed on this string — letting a No-Zoom key describe a zoom-on plan would
    /// hand the corrector the wrong `fits` and suppress the first line of the mode it actually
    /// switched into.
    ///
    /// `t` is the same reasoning applied to the title metric. `plan(...)` has been title-metric-
    /// dependent since Codex r1 fix 3 (`topReachFloor(lift:titleHeight:)` reserves room for the
    /// ACTIVE font's measured title line, not a hard-coded constant), but this key did not encode it
    /// until now — so System and Open Sans, which measure `sectionTitle` at 38 and ≈42.2
    /// respectively, produced DIFFERENT reaches/compressions under the SAME key. A prior version of
    /// this doc comment argued that was safe because the family can only change via Settings
    /// (FEAT-31), which remounts the whole tree by `.id()` — but the remount does not reset the
    /// corrector's regime-scoped state (`PinnedRowSettle.resetHostScopedState()` deliberately
    /// preserves `disarmed`/`verifyFailures`/`pullBackDisarmed` across an UNCHANGED key, and
    /// `noteRegimeChange()` returns early for one), so a font switch inherited whatever
    /// disarm/verify-failure state the previous geometry had left behind. Two title metrics must not
    /// share a regime, exactly like the two zoom modes above.
    ///
    /// Only `noZoom` is encoded, not `accentRing`: since BUG-93 both zoom-on treatments raise the
    /// artwork by the same `heroPinnedRowFocusLiftAllowance`, so a ring flip produces an IDENTICAL
    /// plan and keying on it would churn the `onChange` re-reveal for nothing. If a future treatment
    /// makes the ring's rise differ again, this key gains an `a` component in the same breath.
    ///
    /// `h1` (rc12, BUG-87 follow-up) is appended ONLY when `mode.reachHoldsLiftEffective` is true —
    /// i.e. only in No Zoom, and only with the About pane's reach-hold A/B switched on — for the
    /// same reason `z` and `t` are encoded: the flag changes `plan`'s floor (see `floorLift` above),
    /// so a key that did not distinguish the two would hand the corrector a `fits`/regime-scoped
    /// disarm state computed for the OTHER floor. Conditional rather than an always-present `h0`/`h1`
    /// pair so that with the flag OFF (the shipping default) every key, test literal, fixture parser
    /// and photo contract already written against this string stays byte-for-byte unchanged — `h`
    /// only ever appears when it means something, and `a` stays reserved for `accentRing` above.
    nonisolated static func regimeKey(posterHeight: CGFloat,
                                      captionVisible: Bool,
                                      showsCTA: Bool,
                                      landscapeRows: Bool,
                                      mode: PinnedRowTitle.FocusModeFlags = .current,
                                      titleHeight: CGFloat = Theme.Font.sectionTitleLineHeight) -> String {
        let rounded = Int(posterHeight.rounded())
        let small = Int((Theme.Size.posterHeight * PosterSizePreset.smallScale).rounded())
        let medium = Int(Theme.Size.posterHeight.rounded())
        // FEAT-39: Medium+ (134dp) sits between Medium and Large but shares Large's dial (both are
        // above the 335pt hero-compression gate), so it gets its own tag rather than falling into
        // `X` — `PinnedRowSettle`'s log-once sets must not conflate it with an arbitrary synced width.
        let mediumPlus = Int((Theme.Size.posterHeight * PosterSizePreset.mediumPlusScale).rounded())
        let large = Int((Theme.Size.posterHeight * PosterSizePreset.largeScale).rounded())
        let tag: String
        if rounded == small {
            tag = "S"
        } else if rounded == medium {
            tag = "M"
        } else if rounded == mediumPlus {
            tag = "P"
        } else if rounded == large {
            tag = "L"
        } else {
            tag = "X"
        }
        return "\(tag)\(rounded)c\(captionVisible ? 1 : 0)p\(showsCTA ? 0 : 1)r\(landscapeRows ? 1 : 0)"
            + "z\(mode.noZoom ? 1 : 0)t\(Int(titleHeight.rounded()))"
            + (mode.reachHoldsLiftEffective ? "h1" : "")
    }

    /// The four synced Poster Size presets, as RATIOS of the Medium default rather than as pixel
    /// literals — `PosterStyle.init(from:)` scales `widthDp` by `Theme.Size.posterWidth / 126`, so
    /// Small (105dp), Medium+ (134dp), and Large (154dp) are exactly these fractions of
    /// `Theme.Size.posterHeight` whatever that constant becomes. Only the regime key's cosmetic size
    /// tag reads them; no geometry is derived from them (a synced width outside the presets is an
    /// ordinary payload here and simply tags as `X`).
    nonisolated enum PosterSizePreset {
        static let smallScale: CGFloat = 105.0 / 126.0
        /// FEAT-39: 134dp, the mobile app's own "comfort" preset. Above the 335pt hero-compression
        /// gate, so it shares Large's dial rather than getting a geometry of its own.
        static let mediumPlusScale: CGFloat = 134.0 / 126.0
        static let largeScale: CGFloat = 154.0 / 126.0
    }

    // MARK: - Probe

    /// Fires once per regime when the link frame cannot be made to fit — the belt is back in play
    /// and a device pass needs to know it is looking at that state. Wording mirrors
    /// `PinnedRowTitle.pinnedHeroCompression`'s `compression CAPPED` line.
    nonisolated private static func noteIfShort(_ plan: Plan) {
        guard HomeGeometryProbe.enabled, !plan.fits else { return }
        guard !shortRegimesLogged.contains(plan.regimeKey) else { return }
        shortRegimesLogged.insert(plan.regimeKey)
        NSLog("[HomeScrollProbe] plan %@",
              "regime=\(plan.regimeKey) linkFrame=\(Int(plan.linkFrame.rounded()))"
                + " viewport=\(Int(plan.viewport.rounded())) fits=0 CAPPED"
                + " — rows still short, belt remains in play")
    }

    /// Same `nonisolated(unsafe)` log-once precedent as `PinnedRowTitle.cappedCompressionLogged`:
    /// probe-only bookkeeping, written from the layout pass that produced the line.
    nonisolated(unsafe) private static var shortRegimesLogged: Set<String> = []
}
