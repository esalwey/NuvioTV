import SharedCore
import SwiftUI

/// The standard portrait poster lockup used across catalog rows, search results, and "more like
/// this".
///
/// HIG revamp (see docs/design/hig-hybrid-contract.md): focus motion is the SYSTEM's job by
/// default. Use this view as the label of a `Button`/`NavigationLink` with
/// `.buttonStyle(.borderless)` — on tvOS the borderless style gives the lockup the native focus
/// treatment (lift, real Siri-Remote-tracking parallax, specular highlight, shadow).
///
/// BUG-36 (beta.10 regression, tester verdict): focus used to "zoom only the inside of the
/// artwork" (the lift landed inside BUG-31's `.clipped()` layer, so the tile's own edge never
/// moved) and the focused title could disappear behind the lifted artwork. BUG-36's fix hung the
/// treatment off the WHOLE card; BUG-54 then found the system effect draws its standing platter at
/// the attached view's bounds — a visible border around artwork + caption on every card — so the
/// default mode's effect is back on the artwork container with structural guards for both BUG-36
/// symptoms. See `CardFocusTreatment`, `CardArtworkFocusLift` and `CardCaptionFocusDrop`.
///
/// ```swift
/// NavigationLink(value: route) { PosterCard(title: item.name, imageURL: item.poster) }
///     .buttonStyle(.borderless)
///     .posterButtonShape()   // BUG-25: without this the system radius overrides Corners
/// ```
/// BUG-25 (beta.8 regression): the borderless button style rounds its label artwork with a
/// SYSTEM corner radius, silently overriding the card's own `clipShape` — which is driven by
/// the user's Poster Style → Corners setting. `buttonBorderShape` is the supported lever for
/// the lockup's radius, so every card button attaches this modifier to make Corners visible
/// again (Square/Rounded/Round all rendered identically without it).
struct PosterButtonShape: ViewModifier {
    @Environment(\.posterStyle) private var style

    func body(content: Content) -> some View {
        content.buttonBorderShape(.roundedRectangle(radius: style.cornerRadius))
    }
}

extension View {
    /// Follow the user's Poster Style corner radius on a borderless card button — see
    /// [PosterButtonShape].
    func posterButtonShape() -> some View { modifier(PosterButtonShape()) }
}

/// Publishes an accessibility identifier for a card sub-rect so a UI test can read its FRAME.
/// DEBUG-only AND armed only by `-debug.cardGeometryProbe YES`, for two independent reasons.
///
/// **Why an overlay and not `.accessibilityElement` on the content itself.** The first version
/// attached the element to the artwork directly and the harness read back 215pt of width where the
/// layout box is 212: an image accessibility frame follows the image's own drawn extent, and
/// `CachedAsyncImage` is `.fill`, so `.clipped()` crops the picture without shrinking what it
/// reports. A `Color.clear` overlay has no content of its own, so its frame is exactly the box it
/// is attached to. Never publish geometry from a view that has intrinsic content.
///
/// **Why the launch-argument gate.** A SwiftUI `Button` whose label contains explicit accessibility
/// elements reports the UNION of those elements as its own frame, not its layout frame - measured,
/// not assumed: with the ids always on, a still-mode poster button reported (390.5, 633, 215, 369.5)
/// where its layout frame is (388, 629, 220, 373.5), losing the pinned rows' reach padding and the
/// `ringInset` band. test32/test44/test46 all measure against `focusedButton(app).frame`, so an
/// always-on probe would silently move the baseline of three shipping gates to buy one new one.
/// Armed, every card also publishes `poster_card` at its OUTER frame, which restores the union to
/// the card box and hands test50 an exact card rect to compare the rail against.
///
/// Read once, from the argument domain, at first use: it is a launch knob, never a live setting.
///
/// Introduced for BUG-91's gate (test50), which has to compare the card-depth rail's rect against
/// the artwork's. A luma check cannot do that job: the rail is a 1-2pt white hairline whose own
/// width and opacity are user settings, drawn over arbitrary poster art, and "is the rail 4pt
/// outside the picture" is exactly the sub-band distinction the edge finder in test44/test46
/// already has to hedge around. Geometry from the app's own layout is the honest oracle here, as
/// `debug_pinned` is for the pinned-title corrector.
struct DebugAXIdentifier: ViewModifier {
    let identifier: String

    init(_ identifier: String) { self.identifier = identifier }

    #if DEBUG
    /// `-debug.cardGeometryProbe YES` lands in NSArgumentDomain, which outranks everything else,
    /// so no fixture state can arm this by accident.
    static let armed = UserDefaults.standard.bool(forKey: "debug.cardGeometryProbe")
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if Self.armed {
            content.overlay {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier(identifier)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// 2026-08-30 no-zoom investigation: still mode's press feedback, deliberately minimal — see
/// `CardFocusButtonStyle` below for why this exists instead of relying on `.focusEffectDisabled`.
/// Mirrors `FocusLook.pressScale`/`FocusLook.pressAnim` in FlatControlStyles.swift (that enum is
/// file-private there, so the values are duplicated here rather than shared — same numbers, same
/// "press only, no focus treatment" contract `ChipButtonStyle` already applies).
private enum StillButtonLook {
    static let pressScale: CGFloat = 0.97
    static let pressAnim = Animation.easeOut(duration: 0.12)
}

/// Still mode's `ButtonStyle`, used instead of `.borderless` — see `CardFocusButtonStyle`. Draws
/// nothing but the label itself plus the standard press-down feedback: no lift, no platter, no
/// specular highlight, because a custom `ButtonStyle` never gets a system focus effect to
/// suppress in the first place. Still mode's own focus indicator (the neutral/accent ring drawn
/// by `CardFocusTreatment`/`TileFocusLift`/the site-owned rings elsewhere) is what marks focus.
private struct StillCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? StillButtonLook.pressScale : 1)
            .animation(StillButtonLook.pressAnim, value: configuration.isPressed)
    }
}

/// BUG-93 (u/mrStevenx3, beta.17: with the ring on "the posters are cut off and the titles get a
/// border around them"). Ring mode's `ButtonStyle`, byte-for-byte the same body as
/// `StillCardButtonStyle` above but a separate type so the two branches can never be accidentally
/// merged and so a future press/focus tweak to one is a deliberate decision about the other.
///
/// Why ring mode needs its own style at all: the zoom-on branch of `CardFocusButtonStyle` used to
/// be a bare `.borderless` in BOTH zoom modes, and in `.manualScale` (ring on) nothing in the card
/// declares a hover effect - `CardArtworkFocusLift` skipped that mode entirely. `.borderless` then
/// fell back to its own default focus treatment at the LABEL's bounds, i.e. artwork PLUS caption
/// (`posterButtonShape` only fixes the radius, not the extent), which is exactly the BUG-54
/// platter/outline symptom: a border drawn around the titles. On top of that the system treatment
/// compounded with ring mode's own manual scale, so a focused poster grew by roughly the product
/// of the two and got clipped at the pinned rows' clip edge - the "cut off" half of the report.
/// A custom `ButtonStyle` can never receive the system treatment in the first place (the same
/// argument `StillCardButtonStyle` above rests on), so ring mode gets the manual lift and nothing
/// else. Cards whose label owns no treatment of its own keep the native `.borderless` by passing
/// `lift: .plain` - see `CardButtonLift`.
private struct RingCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? StillButtonLook.pressScale : 1)
            .animation(StillButtonLook.pressAnim, value: configuration.isPressed)
    }
}

/// Which lift a card button's LABEL provides for itself, and therefore whether ring mode may take
/// the system treatment away from it (BUG-93).
///
/// - `.card` - the label goes through `CardArtworkFocusLift`, so in ring mode it draws its own
///   scale and shadow and must NOT also wear `.borderless`'s treatment: `PosterCard`,
///   `LandscapeCard`, `SagaCard`, and — since BUG-108 — `FolderTile` (CollectionsUI) and `CastCard`
///   (DetailView). Those last two draw their ring INSIDE their own artwork frame
///   (`PlainLabelRing`), and rc9 device photos showed the native `.borderless` lift raising the
///   artwork while the ring stayed at base geometry — the FEAT-14 graveyard's third entry verbatim,
///   on the two labels that had been left on that lift. They now own the lift too
///   (`PlainLabelRing.lift`), so ring and picture are one SwiftUI layer on every card class.
/// - `.plain` - the label owns no manual treatment: the four `TileFocusLift` tiles
///   (`TrailerThumbCard`, `SeeAllCard`, `SeasonPosterCard`, `EpisodeThumbCard`). Their zoom-on
///   branch is a system hover effect, and an overlay under one of those is known to render beneath
///   the lifted artwork on hardware, so they draw NO ring with zoom on and keep the bare
///   `.borderless` in every zoom-on state. Giving them the `.manualScale` architecture is the
///   remaining follow-up (BUG-104).
enum CardButtonLift {
    case card
    case plain
}

/// BUG-64 (the real one, survived multiple betas): `.buttonStyle(.borderless)`'s system focus
/// effect — lift + real Siri-Remote-tracking parallax + specular highlight + shadow — moves the
/// WHOLE button label (artwork + caption) and was never gated by "No Zoom on Focus"
/// (`no_zoom_on_focus`). The setting only ever suppressed this file's own hover/scale treatments
/// (`CardFocusTreatment`, `CardArtworkFocusLift`), so no-zoom users still watched every card rise
/// and zoom on focus. Card call sites use this in place of a bare `.buttonStyle(.borderless)`.
/// docs/steven-batch-plan-2026-08-29.md Wave 4 item 4.
///
/// 2026-08-30 no-zoom investigation: a beta tester STILL saw the lift after this shipped.
/// `.focusEffectDisabled()` only turns the system effect off and draws no replacement of its own
/// — whether it actually suppresses `.borderless`'s lift on tvOS 26 HARDWARE was never proven (the
/// specced rise test was never written, see `test46StillModeRiseIsZero`), and the report says it
/// doesn't. A custom `ButtonStyle` can never receive the system lift in the first place — this
/// app's own custom styles (e.g. `ChipButtonStyle` in FlatControlStyles.swift) provably get no
/// system lift — so still mode now swaps to `StillCardButtonStyle` instead of trying to suppress
/// `.borderless`'s. A focusable element must never end up with no visible focus indication at all,
/// so this still swaps treatments rather than merely removing one: still mode's own indicator
/// (`TileFocusLift`'s border/highlight via `CardFocusTreatment.still`) is unchanged and continues
/// to mark focus. `.focusEffectDisabled(true)` is kept on the still branch too, belt-and-braces,
/// in case any other system chrome still consults it — it costs nothing now that the style itself
/// can't lift.
///
/// BUG-93 (beta.17): the zoom-on branch is no longer unconditionally `.borderless`. Ring mode
/// (`accent_focus_ring` on, zoom on) draws its own lift in `CardArtworkFocusLift`, so a card whose
/// label carries that treatment now gets `RingCardButtonStyle` - see that type for why the bare
/// `.borderless` was both bordering the titles and compounding with the manual scale. Default mode
/// (both settings off) is still exactly the bare `.borderless` it always was, and so is every
/// `lift: .plain` call site in every zoom-on state.
/// BUG-108: the three-way branch `CardFocusButtonStyle.body` installs, as a pure value function.
///
/// Extracted for one reason: the invariant that broke in rc9 is a RELATION between two files —
/// "the cell where this modifier takes the system lift away must be the cell where the label draws
/// its own" — and that relation is unit-testable without a device only if both sides are pure. See
/// `PlainLabelRingTests.testRingModeGivesPlainLabelsTheirOwnLift`.
enum CardButtonStyleKind: Equatable {
    case still
    case ring
    case borderless

    static func resolve(noZoomOnFocus: Bool, accentFocusRing: Bool, lift: CardButtonLift) -> CardButtonStyleKind {
        if noZoomOnFocus { return .still }
        if accentFocusRing, lift == .card { return .ring }
        return .borderless
    }
}

struct CardFocusButtonStyle: ViewModifier {
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    /// BUG-93: read here as well as in the cards themselves, and with the same independent
    /// `@AppStorage` read for the same reason - the modifier has to resolve the same three-way
    /// branch `CardFocusMode.resolve` does, without a prop-drilling pass through 20 call sites.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// Whether this button's label supplies its own ring-mode lift - see `CardButtonLift`.
    let lift: CardButtonLift

    func body(content: Content) -> some View {
        switch CardButtonStyleKind.resolve(noZoomOnFocus: noZoomOnFocus,
                                          accentFocusRing: accentFocusRing,
                                          lift: lift) {
        case .still:
            content
                .buttonStyle(StillCardButtonStyle())
                .focusEffectDisabled(true)
        case .ring:
            content
                .buttonStyle(RingCardButtonStyle())
                .focusEffectDisabled(true)
        case .borderless:
            content
                .buttonStyle(.borderless)
        }
    }
}

extension View {
    /// Card buttons' replacement for a bare `.buttonStyle(.borderless)` — see
    /// [CardFocusButtonStyle] for why the swap is needed.
    ///
    /// Labels with NO still-mode focus treatment of their own (FolderTile, CastCard) draw a
    /// no-zoom still ring INSIDE the label, on their artwork surface, fed by the SITE's own
    /// FocusState (Codex 2026-08-29 rounds 3-5: a modifier-installed `.focused` binding collides
    /// with site bindings like `focusedFolderId`, and an outer-bounds ring here would wrap reach
    /// padding + caption instead of the artwork — the label owns its geometry, so it owns the
    /// ring).
    ///
    /// BUG-93: `lift` defaults to `.card`, so the sites whose label IS a `PosterCard`/
    /// `LandscapeCard` stay untouched. Pass `.plain` at the six sites whose label draws no
    /// treatment of its own (see `CardButtonLift`).
    func cardFocusButtonStyle(lift: CardButtonLift = .card) -> some View {
        modifier(CardFocusButtonStyle(lift: lift))
    }
}

/// FEAT-14 accent focus ring (final architecture — the third and last one, 2026-08-02): the ring
/// is a `.strokeBorder` drawn INSIDE the artwork's own `RoundedRectangle`, identical to the
/// inline-trailer surface's ring in `InlineTrailerCard` — same shape, same color, same 4pt width,
/// same "paints inside my own clipped bounds" contract. What changed in this final pass is the
/// hover treatment around it: when the ring is on, the card no longer uses the system
/// `.hoverEffect(.highlight)` at all. Instead it applies a manual `.scaleEffect` (see
/// `CardFocusTreatment` below) so the ring and the artwork scale up together as one layer, drawn
/// by SwiftUI in a single pass rather than composited by the system lift.
///
/// Why the swap is necessary (framebuffer-verified on tvOS 26 hardware, 2026-08-02): the system
/// `.hoverEffect(.highlight)` composites the artwork into its own lifted/scaled layer, and
/// SwiftUI shape overlays living in the same subtree do NOT get pulled into that layer — they
/// stay at base geometry. So no matter where the ring overlay sits relative to `.hoverEffect`,
/// the artwork's lifted/scaled copy ends up covering it, and device photos showed red corner arcs
/// of the ring peeking out from under the lifted artwork — a hardware compositor behavior the
/// Simulator does not reproduce. The inline-trailer ring never hit this because that surface
/// doesn't use `.hoverEffect` in the first place; ring mode now borrows that surface's approach
/// (a manual, SwiftUI-owned lift) instead of trying to make the system lift cooperate.
///
/// Graveyard (do not resurrect):
/// - Outside overpaint — a stroke drawn outside the artwork's own clip bounds: got clipped by the
///   row/lockup's layout bounds, cutting off the outer edge of the ring.
/// - Outside flush ring — `.padding(-ringOffset)` plus a transparent `ringMargin` grown around the
///   label to keep the overpaint inside the button's layout bounds so the hardware lockup
///   wouldn't clip it. Survived the clip problem, but device photos under the hover lift's shadow
///   showed the ring reading as a detached glow/halo behind the poster, not a border on it.
/// - Inside `strokeBorder` under the SYSTEM hover lift — geometrically the cleanest of the three
///   (same shape, same clip, "scales with the card as one unit" on paper), except on hardware the
///   system lift doesn't actually pull the overlay into its lifted layer, so the artwork's scaled
///   copy covers the ring at the corners. This is the failure the manual-scale swap above fixes.
///
/// BUG-93 (beta.17) completes the swap this comment always described. Until then the *scale* had
/// moved off the system lift but a system focus layer was still being drawn underneath it: ring
/// mode's buttons kept the bare `.buttonStyle(.borderless)`, whose own default treatment paints at
/// the button LABEL's bounds (artwork + caption) and compounds with the manual scale. Ring mode now
/// uses `RingCardButtonStyle`, a custom style that can receive no system treatment at all, and the
/// manual scale sits on the artwork container next to the ring (`CardArtworkFocusLift`). So the
/// invariant this file has claimed since 2026-08-02 is finally literally true: in ring mode the ring
/// and the artwork are one SwiftUI layer and **no system focus layer is involved**.
// Internal, not private: FolderTile and CastCard draw their own no-zoom still rings with the
// same width/colour so still-mode focus reads identically on every card class (Codex 2026-08-29).
let ringWidth: CGFloat = 4      // thicker for 10-foot visibility

/// BUG-64 (beta.13, u/mrStevenx3 on beta.12): with the ring ON "the film ends up hidden behind
/// the border" — an inside `strokeBorder` paints its whole 4 pt on top of the artwork, and in ring
/// mode nothing lifts the picture out from under it (manual scale moves ring and art together;
/// No Zoom moves nothing). Fix: whenever the ring setting is ON, the artwork is drawn INSET by
/// `ringWidth` inside the same card frame, focused or not, so the stroke lands in a reserved band
/// around the picture instead of over it. Static rather than focus-animated on purpose — a
/// focus-time inset would shrink the picture at the moment it should feel lifted, and an
/// always-reserved band costs 4 pt of artwork nobody notices at 10 feet. The card frame, its
/// clip, the depth overlay and the ring itself all keep the OUTER geometry, so BUG-36's "ring
/// scales with the card as one layer" contract and the graveyard above are untouched.
/// 2026-08-30 no-zoom investigation: still mode's own neutral ring (`CardFocusTreatment.still`,
/// drawn whenever `no_zoom_on_focus` is on and the accent ring isn't already drawing) was hitting
/// the exact BUG-64 overpaint the accent ring was fixed for above — this function only ever
/// reserved the band for the ACCENT ring, so a no-zoom user with the accent ring off got a
/// `strokeBorder` painted straight over the poster's outer edge (the tester's "cuts off the
/// posters"). Reserve the identical band whenever EITHER ring is going to draw. Still
/// static/settings-driven, not focus-time, for the same reason the original BUG-64 fix gives: an
/// always-reserved band costs 4pt of artwork nobody notices at 10 feet, while a focus-time inset
/// would shrink the picture at the moment it should read as marked.
private func ringInset(accentFocusRing: Bool, noZoomOnFocus: Bool) -> CGFloat {
    (accentFocusRing || noZoomOnFocus) ? ringWidth : 0
}

/// BUG-102 (u/mrStevenx3, rc8, 2026-09-10: "when you disable No Zoom on Focus, the focus ring
/// doesn't work in the collections"): the ring verdict for labels that draw their focus ring
/// INSIDE their own artwork frame because they own no treatment of their own — `FolderTile`
/// (CollectionsUI.swift) and `CastCard` (DetailView.swift). Until rc9 both only knew the no-zoom
/// STILL ring (`stillHighlight`), so with zoom on and the accent ring on they drew nothing while
/// every `PosterCard`/`LandscapeCard`/`SagaCard` around them wore the accent ring.
///
/// Same precedence as `CardFocusMode.resolve` + the ring overlays in this file: the accent ring
/// wins whenever the setting is on (in still mode too — `.still(ringed: true)` suppresses the
/// neutral highlight for the same reason), the neutral still ring is the no-zoom fallback, and
/// nothing draws in the default mode. The reserved band follows `ringInset`: a label that may
/// ever draw a ring keeps its 4 pt margin in every focus state, never popping it in on focus.
///
/// BUG-108 (rc10): the lift IS changed. rc9 kept the native `.borderless` lift under these two
/// labels and the device showed the artwork rising out of its ring, so they now draw their own
/// `.manualScale` lift (`lift(accentFocusRing:noZoomOnFocus:)`) inside `RingCardButtonStyle`, the
/// same architecture every `PosterCard` uses. The pinned collection row's clearance math is
/// unaffected: `PinnedRowTitle.focusLiftAllowance` charges the same 20 pt in both zoom-on modes
/// whatever the treatment. The four `TileFocusLift` tiles are still NOT covered (their zoom-on
/// branch is a hover effect) — BUG-104.
enum PlainLabelRing: Equatable {
    case accent
    case still

    /// Which ring a focused plain label draws, or nil for none.
    static func resolve(accentFocusRing: Bool, noZoomOnFocus: Bool, focused: Bool) -> PlainLabelRing? {
        guard focused else { return nil }
        if accentFocusRing { return .accent }
        return noZoomOnFocus ? .still : nil
    }

    /// Whether the label reserves the `ringWidth` band around its artwork — `ringInset`'s rule.
    static func reservesBand(accentFocusRing: Bool, noZoomOnFocus: Bool) -> Bool {
        accentFocusRing || noZoomOnFocus
    }

    /// BUG-108: which lift a plain-label card draws for ITSELF, now that ring mode takes the native
    /// `.borderless` lift away from it (`CardButtonLift.card`). Shared by `FolderTile` and
    /// `CastCard` so the two cannot drift, and sited next to `resolve` because it must branch on
    /// the same two settings in the same precedence.
    ///
    /// `.manualScale` in ring mode ONLY. Both other modes map to `.still`, which is
    /// `CardArtworkFocusLift`'s NO-OP branch — deliberately not `.systemLift`: these labels sit
    /// inside a `.borderless` button in the default mode, so the button already lifts the whole
    /// label (caption included), and `.systemLift` would hang a SECOND `.hoverEffect(.highlight)`
    /// inside that lift. `.still(ringed:)` carries the accent flag only so the value reads
    /// truthfully in a log or a test; `CardArtworkFocusLift` and `CardCaptionFocusDrop` both ignore
    /// the payload.
    static func lift(accentFocusRing: Bool, noZoomOnFocus: Bool) -> CardFocusMode {
        (accentFocusRing && !noZoomOnFocus) ? .manualScale : .still(ringed: accentFocusRing)
    }

    /// BUG-111 (rc12, u/mrStevenx3: the detail page's STUDIO chip "zooms in on the poster instead
    /// of the description" — `CompanyChip` was the only card-like site left on a bare
    /// `.buttonStyle(.borderless)`, so ring mode never reached it and No Zoom didn't either). The
    /// chip joins this same architecture, but it is far shorter than `FolderTile`'s tile or
    /// `CastCard`'s 140pt avatar — a 52pt capsule — and `cardLiftScale` derives its scale from the
    /// flat `cardFocusLiftRise` (20pt) every OTHER card class shares. Applying that unmodified to
    /// a 52pt capsule would grow it to `1 + 2×20/52 ≈ 1.77`, more than doubling its footprint in a
    /// 16pt row gap. So a small label gets its OWN, height-PROPORTIONAL rise instead of the flat
    /// constant: `height × 0.12 / 2`. That proportionality is exactly what makes the DERIVED scale
    /// (fed back through `cardLiftScale`) a CONSTANT `1.12` for every height below the point where
    /// this formula would itself exceed 20pt — the "ceiling" `smallLabelScaleCeiling` names.
    /// `smallLabelRise` is the value actually threaded through `CardArtworkFocusLift.rise`;
    /// `smallLabelScaleCeiling` documents what that rise resolves to as a scale and is what the
    /// unit tests assert against directly. This is a DIFFERENT number from BUG-64's abandoned
    /// "hold the scale at 1.12 for every card" attempt above (`cardFocusLiftRise`'s doc comment) —
    /// that one was wrong precisely because it clamped the CARD constant globally; this one is
    /// scoped to labels short enough that the proportional rise never reaches the card rise at all.
    static let smallLabelScaleCeiling: CGFloat = 1.12

    /// See `smallLabelScaleCeiling`. Saturates at `cardFocusLiftRise` (the flat 20pt rise every
    /// other card class uses) once a label is tall enough that the proportional formula would
    /// exceed it — at that point the small-label treatment IS the ordinary card treatment, so
    /// there is no discontinuity, only the ceiling the sibling constant names above. Returns 0 for
    /// a degenerate (zero or negative) height, matching `cardLiftScale`'s own guard.
    static func smallLabelRise(height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return min(cardFocusLiftRise, height * (smallLabelScaleCeiling - 1) / 2)
    }

    var color: Color {
        switch self {
        case .accent: return Theme.Palette.focusRingColor
        case .still: return stillHighlight
        }
    }

    /// BUG-111 review finding 1 (P2, rc12): `stillHighlight` is an 85%-opacity WHITE ring — the
    /// right neutral cue on every OTHER plain-label card, because those sit on dark artwork
    /// (`FolderTile`'s backdrop, `CastCard`'s photo). `CompanyChip`'s "artwork" is itself a
    /// `Color.white.opacity(0.92)` capsule, so stroking `stillHighlight` there goes from 92%
    /// white to 98.8% white — no lift in that mode, nothing else changes, and the chip's only
    /// still-mode focus cue is functionally invisible. Contrast, not stroke width, is the
    /// still-mode cue everywhere this pattern is used, so a WHITE-surfaced label needs the
    /// OPPOSITE neutral instead.
    ///
    /// A parameter on a static color lookup rather than a third `PlainLabelRing` case (which
    /// would ripple through `resolve`/`lift`/`reservesBand`'s precedence tables for a value
    /// that's purely cosmetic) or an `onLightSurface` field on `resolve` (which would force
    /// `FolderTile`/`CastCard`'s call sites to pass a value they don't need). Defaults to
    /// `false` so every existing call site is untouched; `CompanyChip` is the only caller that
    /// passes `true`. The accent ring (`ring.color` in ring mode) is unaffected either way.
    static func stillColor(onLightSurface: Bool = false) -> Color {
        onLightSurface ? Color.black.opacity(0.75) : stillHighlight
    }
}

/// How far a focused card's artwork TOP edge rises, in points, in either zoom-on mode.
///
/// BUG-64 measured this (test44, tvOS 26.5 sim, 2026-08-25: the focused artwork's top edge rises
/// 20.0pt on a 330pt artwork) and then stored it as a SCALE - 1.12 - which quietly re-introduced
/// the error it was fixing at every other poster size. The system `.hoverEffect(.highlight)` rise
/// is a CONSTANT, not a proportion: `Theme.Size.heroPinnedRowFocusLiftAllowance` documents the same
/// ~20pt measured at Medium AND at Large. Holding the scale fixed instead made ring mode rise
/// 16.1pt at Small, 19.7 at Medium and 24.2 at Large - under- and over-shooting the mode it is
/// supposed to be indistinguishable from, and at Large charging the pinned rows' clip budget ~27pt
/// where `Theme.Size` had reserved 20 (BUG-93's "cut off" half).
///
/// So the constant is the RISE and the scale is derived from it per card. Single source of truth
/// with the geometry side: this IS `Theme.Size.heroPinnedRowFocusLiftAllowance`, so
/// `PinnedRowTitle.focusLiftAllowance` (BrowseComponents) and the card cannot drift apart - both
/// zoom modes are 20pt, still mode is 0.
///
/// Used in BOTH directions, which is why the correction reaches further than the ring:
///  - `CardArtworkFocusLift.manualScale` - ring mode's stand-in for the system lift;
///  - `CardCaptionFocusDrop` - how far the caption follows the lift's bottom edge, now the same
///    20pt in both zoom modes because the artwork container is what scales in both.
///
/// Sim-derived; a device pass should confirm it before it is treated as settled.
private let cardFocusLiftRise: CGFloat = Theme.Size.heroPinnedRowFocusLiftAllowance

/// The uniform scale that raises an `artworkHeight`-tall artwork's top edge by exactly `rise`
/// when applied about its centre (the bottom edge drops by the same amount, which is what
/// `CardCaptionFocusDrop` pays out to the caption). Large 403.3pt → 1.0992, Medium 330 → 1.1212,
/// Small 274.5 → 1.1457, all at the default `rise`.
///
/// BUG-111: `rise` used to be hardcoded to `cardFocusLiftRise` — every card class rises the same
/// flat 20pt. It is now a parameter, defaulted to that same constant so every existing call site
/// (poster/landscape/saga cards, `FolderTile`, `CastCard`) is unaffected, so `CompanyChip` can
/// pass `PlainLabelRing.smallLabelRise(height:)` instead — see that function for why a 52pt
/// capsule cannot share the flat rise every taller card class uses.
private func cardLiftScale(artworkHeight: CGFloat, rise: CGFloat = cardFocusLiftRise) -> CGFloat {
    guard artworkHeight > 0 else { return 1 }
    return 1 + 2 * rise / artworkHeight
}

/// BUG-36: the ARTWORK's rounded rect, expressed in the WHOLE CARD's coordinate space.
///
/// The focus treatment moved from the artwork container up to the card lockup (artwork + caption)
/// so the whole card travels as one object. Everything that treatment draws still has to be shaped
/// like the *artwork*, though — a hover platter, highlight border or shadow that swallowed the
/// caption slot too would read as a grey slab behind the title. Every card in this file lays its
/// artwork out at the top of a leading-aligned `VStack` whose width the caption matches, so the
/// artwork is always `rect` cut down to `artworkHeight`.
///
/// `InsettableShape` so the still-mode highlight can use `strokeBorder` — same "paints strictly
/// inside my own bounds" contract as the accent ring (see the FEAT-14 note above; an outside
/// stroke gets clipped by the row's layout bounds).
struct CardArtworkShape: Shape, InsettableShape {
    var artworkHeight: CGFloat
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let height = min(artworkHeight, rect.height)
        let artwork = CGRect(
            x: rect.minX + inset,
            y: rect.minY + inset,
            width: max(rect.width - inset * 2, 0),
            height: max(height - inset * 2, 0)
        )
        return RoundedRectangle(cornerRadius: max(cornerRadius - inset, 0)).path(in: artwork)
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// Which focus treatment a card wears. Resolved from two independent Appearance settings so the
/// three-way branch lives in exactly one place instead of being re-derived at every card.
///
/// - `.systemLift` — default (ring OFF, zoom ON): the native tvOS lockup treatment,
///   `.contentShape(.hoverEffect, …)` + `.hoverEffect(.highlight)`.
/// - `.manualScale` — ring ON, zoom ON: no `.hoverEffect` at all, a SwiftUI `.scaleEffect` stands
///   in for it (FEAT-14 — the system lift leaves shape overlays like the ring behind at base
///   geometry, so ring mode has to own the lift).
/// - `.still` — BUG-36's "No Zoom on Focus" (`no_zoom_on_focus`), either ring state: no scale of
///   any kind, focus is drawn as a highlight border plus a shadow.
enum CardFocusMode: Equatable {
    case systemLift
    case manualScale
    /// `ringed` = the accent focus ring is already drawing on the artwork, so still mode must not
    /// paint its own neutral highlight border on top of it.
    case still(ringed: Bool)

    static func resolve(accentFocusRing: Bool, noZoomOnFocus: Bool) -> CardFocusMode {
        if noZoomOnFocus { return .still(ringed: accentFocusRing) }
        return accentFocusRing ? .manualScale : .systemLift
    }

    /// Every treatment SwiftUI draws itself needs an explicit `zIndex` to sit above its row
    /// neighbours — only the system lift raises the focused card implicitly (it composites into
    /// its own layer). See the `zIndex` call sites below.
    var raisesFocusedCard: Bool {
        if case .systemLift = self { return false }
        return true
    }
}

/// BUG-36 / FEAT-14: the card's focus treatment, attached to the WHOLE card lockup (the `VStack`
/// of artwork + caption) by both `PosterCard` and `LandscapeCard` so the branch isn't duplicated
/// at each call site.
///
/// **Where this is attached is the fix.** Pre-BUG-36 it hung off the artwork container, one level
/// below the caption — and BUG-31 had just added a `.clipped()` inside that container. The lift
/// then landed on the clipped image rather than on the tile: artwork zoomed *inside* a frozen
/// edge, and the growing artwork could cover the title underneath it (tester verdict). Moving the
/// treatment to the lockup makes the artwork, its `.clipped()` edge and the caption one object:
/// in every mode the caption travels with the artwork instead of being an unmoving thing the
/// artwork can grow over, so **the focused title can no longer be hidden in any mode**.
///
/// The clip stays where BUG-31 put it — directly on the image's own frame — because that is all it
/// was ever for: cropping the artwork's (and the UX-9 trailer overscale's) own overflow inside the
/// tile. It is now strictly interior to whatever scales, so it crops instead of capturing the lift.
///
/// What scales, per mode:
/// - `.systemLift` — handled at the ARTWORK, not here (BUG-54): the system effect's standing
///   platter follows the attached view's bounds, so lockup attachment drew a platter around
///   artwork + caption on every card. See `CardArtworkFocusLift` / `CardCaptionFocusDrop` for
///   how BUG-36's symptoms stay fixed under artwork attachment.
/// - `.manualScale` - handled at the ARTWORK too (BUG-93), for the same reason `.systemLift` is:
///   the scale belongs on the container the ring overlay lives in, so ring and picture are one
///   layer, and the caption then follows via `CardCaptionFocusDrop` in both zoom modes instead of
///   riding inside the scale in one of them. Reduce Motion is honored explicitly there (the system
///   lift respects it automatically, a manual `.scaleEffect` does not) by skipping the animation
///   and snapping straight to the focused/unfocused scale - the ring still has to reach its scaled
///   geometry to stay aligned with the artwork, so scale itself is kept, not skipped.
/// - `.still` — nothing scales, ever. Focus reads as a border plus a drop shadow on the artwork
///   shape: the accent ring when the user has it on, otherwise a neutral white border of the same
///   weight, so ring-on and ring-off still modes are the same geometry in two colors and a
///   ring-off user is never left with an unmarked focused card. Reduce Motion skips the fade.
struct CardFocusTreatment: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: CardFocusMode
    let isFocused: Bool
    /// Height of the card's artwork — the caption is whatever sits below it. Drives
    /// `CardArtworkShape`, so pass the same value the artwork's `.frame(height:)` uses.
    let artworkHeight: CGFloat
    let cornerRadius: CGFloat

    private var artworkShape: CardArtworkShape {
        CardArtworkShape(artworkHeight: artworkHeight, cornerRadius: cornerRadius)
    }

    func body(content: Content) -> some View {
        switch mode {
        case .systemLift:
            // BUG-54: nothing happens at the lockup level in this mode anymore. The system hover
            // effect draws its standing platter at the BOUNDS of the view it's attached to — the
            // custom `CardArtworkShape` passed to `.contentShape(.hoverEffect, …)` here did not
            // constrain it (device + sim, 2026-08-08) — so hanging the effect off the lockup put a
            // visible platter around artwork AND caption on every card, focused or not. The effect
            // now lives on the artwork container (`CardArtworkFocusLift`), whose bounds are the
            // artwork, and the caption follows the lift via `CardCaptionFocusDrop`.
            content
        case .manualScale:
            // BUG-93: nothing happens at the lockup level in this mode either, for the same
            // reason `.systemLift` does nothing here. The scale and its drop shadow moved DOWN to
            // the artwork container (`CardArtworkFocusLift`), which is where the ring overlay
            // already lives - so the two are one SwiftUI layer, exactly as FEAT-14's final
            // architecture note above promises, and the caption is outside the scale in BOTH zoom
            // modes rather than inside it in one and outside it in the other. That symmetry is
            // what lets `CardCaptionFocusDrop` pay the identical 20pt in both, and what lets
            // `PinnedRowTitle.focusLiftAllowance` charge one constant instead of a scale derived
            // off the lockup's height.
            content
        case let .still(ringed):
            content
                // Behind the (opaque) artwork, so only the spill reads. Same weight as the inline
                // trailer surface's shadow, which is the other card face that never scales.
                .background {
                    if isFocused {
                        artworkShape
                            .fill(Color.black)
                            .shadow(color: .black.opacity(0.6), radius: 22, y: 10)
                    }
                }
                .overlay {
                    if isFocused && !ringed {
                        artworkShape.strokeBorder(stillHighlight, lineWidth: ringWidth)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Still mode's ring-less focus border. Deliberately NOT the accent color — the accent ring is
/// its own opt-in setting, and a user who left it off shouldn't get one by turning zoom off.
/// Near-white at partial opacity reads as the system's own highlight edge at 10 feet without
/// impersonating the ring. File-scope (was `CardFocusTreatment`-private) so `TileFocusLift`
/// draws the identical edge.
let stillHighlight = Color.white.opacity(0.85)  // shared with FolderTile/CastCard's no-zoom rings

/// BUG-31 (beta.12 device pass): "No Zoom on Focus" only ever reached the content cards —
/// utility tiles that keep the whole-tile system lift (the See All tile, episode cards, the
/// detail-page trailer thumbnail) applied `.hoverEffect(.highlight)` unconditionally, so with
/// the toggle ON every poster went still while these kept zooming. This is their still-aware
/// stand-in: zoom ON keeps the system treatment these tiles always had (with the highlight
/// geometry pinned to the tile's own corner radius, the BUG-31/BUG-25 contract); zoom OFF
/// draws still mode's neutral border + shadow (same color/weight/timing as
/// `CardFocusTreatment`'s `.still`) on the tile's own rounded rect, and nothing scales.
/// Utility tiles never wear the accent ring (see `SeeAllCard`'s header note), so the border
/// here is always the neutral one.
struct TileFocusLift: ViewModifier {
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cornerRadius: CGFloat
    /// 2026-08-30 no-zoom investigation: `content`'s own fixed size, needed to reserve the still
    /// ring's band the way `ringInset` reserves it for PosterCard/LandscapeCard — but this
    /// modifier's public signature (`tileFocusLift(cornerRadius:)`) is used across several files
    /// this fix isn't scoped to touch, so it can't just take the size as a second parameter the
    /// way that would normally be done. Every call site already gives `content` a fixed `.frame`
    /// before attaching this modifier, so instead it's read back with a `.background`
    /// `GeometryReader` — `.background` never influences what a view reports for ITS OWN layout,
    /// so this measurement is purely observational, never a second source of truth for size.
    @State private var measuredSize: CGSize = .zero

    func body(content: Content) -> some View {
        if noZoomOnFocus {
            let shape = RoundedRectangle(cornerRadius: cornerRadius)
            // 2026-08-30 no-zoom investigation: the still ring used to `strokeBorder` straight
            // over `content`'s own outer edge — the same BUG-64 overpaint PosterCard's accent ring
            // was fixed for, just never ported to these utility tiles. `content` arrives
            // pre-sized, so it can't be redrawn smaller the way PosterCard redraws its own artwork
            // frame; instead it's shrunk in place with a static (never focus-linked — same
            // "always reserved, never pops" contract as `ringInset`) `.scaleEffect`, computed
            // per-axis from `measuredSize` so a fixed `ringWidth` margin lands on every edge
            // regardless of the tile's aspect ratio. Before the very first layout pass measures a
            // size, the guards below fall back to no shrink (1) rather than collapsing to zero.
            // `.scaleEffect` is a paint-only transform — it doesn't change what `content` reports
            // for layout — so the `.overlay` below still measures against the tile's TRUE,
            // unscaled bounds, and the ring lands exactly in the vacated margin instead of on top
            // of the artwork.
            let scaleX = measuredSize.width > 0
                ? max(0, measuredSize.width - 2 * ringWidth) / measuredSize.width : 1
            let scaleY = measuredSize.height > 0
                ? max(0, measuredSize.height - 2 * ringWidth) / measuredSize.height : 1
            content
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { measuredSize = geo.size }
                            .onChange(of: geo.size) { _, newSize in measuredSize = newSize }
                    }
                }
                .scaleEffect(x: scaleX, y: scaleY)
                // Behind the (opaque) tile face, so only the spill reads — same weight as
                // `.still`'s shadow.
                .background {
                    if isFocused {
                        shape
                            .fill(Color.black)
                            .shadow(color: .black.opacity(0.6), radius: 22, y: 10)
                    }
                }
                .overlay {
                    if isFocused {
                        shape.strokeBorder(stillHighlight, lineWidth: ringWidth)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        } else {
            content
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius))
                .hoverEffect(.highlight)
        }
    }
}

extension View {
    /// See `TileFocusLift`.
    func tileFocusLift(cornerRadius: CGFloat) -> some View {
        modifier(TileFocusLift(cornerRadius: cornerRadius))
    }
}

/// BUG-54 (beta.11 device regression, found by Christian): the system focus treatment, back on the
/// ARTWORK container — where beta.10 had it — instead of the whole lockup.
///
/// BUG-36 moved `.hoverEffect(.highlight)` up to the lockup so the caption would travel with the
/// lift, trusting `.contentShape(.hoverEffect, CardArtworkShape)` to keep the drawn treatment
/// artwork-shaped. It doesn't: the effect's standing platter follows the attached view's BOUNDS
/// (the custom shape is ignored for it), so every card grew a visible platter/outline wrapping
/// poster *and* title — at rest, not just focused (device video + tvOS 26.5 sim, 2026-08-08).
/// Attaching the effect to the artwork container makes bounds == artwork again, and the opaque
/// poster hides the platter exactly as it did in beta.10.
///
/// BUG-36's two symptoms stay structurally fixed without the lockup attachment:
/// - Frozen tile edge ("zoom only the inside of the artwork"): the `.compositingGroup()` flattens
///   the clipped artwork (image, `.clipped()`, corner clip, depth overlay) into a single layer
///   BEFORE the hover effect sees it, so the lift can only transform the whole flattened tile —
///   there is no interior hierarchy left for it to land on. beta.10 lacked this, and on hardware
///   the lift reached the image inside the clip while the tile edge stood still.
/// - Caption hidden under the lifted artwork: the caption no longer stands still — see
///   `CardCaptionFocusDrop` below.
///
/// BUG-93 (beta.17) gave this modifier the OTHER zoom-on mode as well, which is why it is no longer
/// called `CardArtworkSystemLift`. Ring mode's manual scale used to live one level up, on the whole
/// lockup (`CardFocusTreatment.manualScale`); it now sits here, on the same artwork container the
/// system effect uses and directly outside the ring overlay, so:
///  - the ring and the picture scale as ONE SwiftUI layer (FEAT-14's stated contract, see the
///    graveyard at the top of this file - a scale applied above the ring's own overlay cannot
///    leave it behind the way the system compositor's lifted layer did);
///  - the artwork's top edge rises by the SAME `cardFocusLiftRise` in both zoom modes, so the
///    caption's drop and `PinnedRowTitle.focusLiftAllowance`'s clip budget are one number;
///  - the caption is outside the scaled box in both modes rather than inside it in one.
/// Still mode keeps its whole-lockup treatment in `CardFocusTreatment` (it draws artwork-shaped
/// visuals itself and produces no platter, and it scales nothing at all).
struct CardArtworkFocusLift: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: CardFocusMode
    let isFocused: Bool
    /// Height of the artwork this modifier is attached to - the scale is derived from it so the
    /// rise is `cardFocusLiftRise` at every Poster Size. Pass the same value the container's own
    /// `.frame(height:)` uses.
    let artworkHeight: CGFloat
    let cornerRadius: CGFloat
    /// BUG-111: the rise `.manualScale` derives its scale from, defaulted to nil so the five
    /// existing memberwise call sites (poster/landscape/saga cards, `FolderTile`, `CastCard`, all
    /// of which end their initializer at `cornerRadius:`) stay byte-identical and keep getting the
    /// flat `cardFocusLiftRise` every one of them was built around. Appended LAST, as a defaulted
    /// `var` rather than inserted before `cornerRadius:`, for exactly that reason — a required or
    /// reordered parameter would force every one of those five call sites to change for a rise
    /// only `CompanyChip` needs. Only `CompanyChip` passes a value
    /// (`PlainLabelRing.smallLabelRise(height:)`) — see that function for why a 52pt capsule
    /// cannot share the 20pt flat rise every taller card class uses.
    var rise: CGFloat? = nil

    func body(content: Content) -> some View {
        switch mode {
        case .systemLift:
            content
                .compositingGroup()
                // BUG-31/BUG-25: pin the highlight's geometry to the card's own Corners radius so
                // the lift can't fall back to a system rect that extends past the artwork.
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius))
                .hoverEffect(.highlight)
        case .manualScale:
            content
                // BUG-64: the system lift is not just a scale — it carries a platter and a drop
                // shadow, so a ring card that only scaled read as a flat mechanical zoom next to
                // the native lift's sense of depth. Same fill+shadow still mode uses, so all three
                // treatments share one depth cue. A plain `RoundedRectangle` rather than
                // `CardArtworkShape`: down here the attached view's bounds ARE the artwork, so
                // there is no caption slot to carve out of the shape.
                .background {
                    if isFocused {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Color.black)
                            .shadow(color: .black.opacity(0.6), radius: 22, y: 10)
                    }
                }
                // BUG-111: `rise ?? cardFocusLiftRise` — nil (every pre-existing call site) keeps
                // the flat 20pt every other card class always rose by; `CompanyChip` is the first
                // caller to supply its own.
                .scaleEffect(isFocused ? cardLiftScale(artworkHeight: artworkHeight, rise: rise ?? cardFocusLiftRise) : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        case .still:
            content
        }
    }
}

/// BUG-54 companion: in both zoom-on modes the caption sits OUTSIDE the view that lifts, so the
/// lift no longer moves it. Instead of standing still under the lifted artwork (BUG-36's second
/// symptom), the focused caption slides down by the lift's bottom expansion, which keeps the
/// artwork↔title gap visually constant and matches the native TV-app caption behavior. `.offset`
/// is render-only, so row layout never reflows.
///
/// BUG-93: this is now `cardFocusLiftRise` flat rather than half a scale delta, and it applies to
/// `.manualScale` too. The system lift's bottom edge drops by a constant, and ring mode's own
/// scale is derived from that same constant (`cardLiftScale`) and now lives on the artwork
/// container rather than the lockup - so both modes expand the artwork downward by exactly
/// `cardFocusLiftRise` and the caption pays the same amount in each. Still mode returns 0: it
/// never moves anything.
struct CardCaptionFocusDrop: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: CardFocusMode
    let isFocused: Bool
    /// Kept in the signature although the drop no longer depends on it - the call sites all pass
    /// the artwork height, and a future treatment that IS height-dependent should not have to
    /// re-thread it through every card. Unused deliberately, not by accident.
    let artworkHeight: CGFloat

    private var drop: CGFloat {
        guard isFocused else { return 0 }
        switch mode {
        case .systemLift, .manualScale: return cardFocusLiftRise
        case .still: return 0
        }
    }

    func body(content: Content) -> some View {
        content
            .offset(y: drop)
            // Reduce Motion: snap, don't animate — same contract as CardFocusTreatment.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: drop)
    }
}

/// FEAT-14: the ring's draw color, factored out of the two call sites below so they can't drift
/// apart — and so `InlineTrailerCard`'s inline-trailer surface can draw the identical color.
/// Device finding (2026-08-02): when a focused poster dwell-morphs into the inline trailer, the
/// landscape surface had no ring of its own, so the accent ring visibly vanished the instant the
/// morph fired. Pure extraction of the pre-existing `hex → focusRingHex → Color` derivation —
/// same fallback to `accentFocus` on a bad/empty hex — so this refactor changes no on-screen
/// behavior at either PosterCard call site.
extension Theme.Palette {
    static var focusRingColor: Color {
        Color(hexString: focusRingHex(accentFocusHex: accentFocusHex)) ?? accentFocus
    }
}

struct PosterCard: View {
    let title: String
    let imageURL: String?
    /// Explicit sizes override the environment style (used by the small "more like this" / credit
    /// rails); leave nil to follow the user's Poster Style setting.
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var showTitle: Bool? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    /// FEAT-14: opt-in accent focus ring, default OFF. Read independently (same UserDefaults key
    /// as `AppearanceSettingsPane`'s toggle) rather than threaded through props, so every card
    /// picks up the setting without a prop-drilling pass through every call site. When OFF the
    /// `if` below emits no overlay at all — no extra view/layer exists in the tree, keeping the
    /// OFF render byte-identical to pre-FEAT-14.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// BUG-36: opt-in "No Zoom on Focus", default OFF. Same independent-read pattern (and the same
    /// UserDefaults key) as `AppearanceSettingsPane`'s toggle, so every card site inherits it
    /// without a prop-drilling pass. OFF resolves to the same two treatments as before.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    /// Gap 13: titles are revealed on focus by default (HIG Lockups › Posters). See
    /// `PosterTitleReveal` for the opt-out key.
    @AppStorage(PosterTitleReveal.alwaysVisibleKey) private var titlesAlwaysVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var resolvedWidth: CGFloat { width ?? style.width }
    private var resolvedHeight: CGFloat { height ?? style.height }
    private var titleVisible: Bool { showTitle ?? style.showTitle }
    private var focusMode: CardFocusMode {
        .resolve(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    var body: some View {
        let inset = ringInset(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus) // BUG-64 / 2026-08-30 no-zoom investigation
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { // UX-5: artwork↔title gap increased to match LandscapeCard and expandedTile
            CachedAsyncImage(string: imageURL)
                .frame(width: resolvedWidth - 2 * inset, height: resolvedHeight - 2 * inset)
                // BUG-31: CachedAsyncImage is `.fill` with no clip of its own, and this frame is
                // always exactly 2:3 — so off-ratio artwork overflows it and the hover lift copies
                // the overflow too, drawing a ghost-doubled subject. Clip inside the frame first.
                // BUG-36: this clip must stay HERE, on the image's own frame, and nothing but the
                // artwork's overflow may depend on it — while the focus treatment hung off this
                // same container the lift landed inside the clip and zoomed the picture within a
                // frozen tile edge. The treatment now sits on the whole card (below), leaving the
                // clip purely as a crop.
                .clipped()
                // BUG-64: the inner corner nests inside the ring's outer corner (concentric radii).
                .clipShape(RoundedRectangle(cornerRadius: max(0, style.cornerRadius - inset)))
                // BUG-91 gate (test50): the INSET artwork's own box, published to the harness so
                // the depth rail's frame can be compared against the picture's rather than against
                // a luma guess. DEBUG-only and identifier-only - no label, no traits, no hit
                // testing change - so it cannot alter what the card reads as at 10 feet or in a
                // Release build.
                .modifier(DebugAXIdentifier("poster_artwork"))
                // BUG-36: the card-depth overlay stays anchored to the ARTWORK's frame — its edge
                // coverage mask measures 0…1 down *this* box (see `CardDepthStyle.coverageMask`),
                // so hoisting it to the lockup would stretch "Top" across the caption slot too.
                // BUG-91 (u/mrStevenx3, beta.17: "an empty band between the picture and the card's
                // frame on the top and left of every card"): it now hangs off the INSET artwork,
                // i.e. before the outer re-frame below, with the same inset radius the clip uses.
                // With No Zoom (or the ring) on, `ringInset` reserves a 4pt band and the artwork is
                // drawn smaller than the card; attached after the re-frame the depth rail traced
                // the OUTER rect, so the rail floated 4pt off the picture on every edge of every
                // card, focused or not. Attached here it traces the picture. Concentric with the
                // clip by construction (same `max(0, r - inset)`), and with `inset == 0` - ring off
                // and zoom on, the default - the two attachment points are the same box, so the
                // default render is byte-identical. The coverage mask's denominator becomes the
                // inset artwork's height, which changes no fraction: the mask is relative.
                // Do NOT collapse the band on focus (Wave 7 rationale in `ringInset` above).
                .nuvioCardDepth(RoundedRectangle(cornerRadius: max(0, style.cornerRadius - inset)),
                                surface: .posters)
                .frame(width: resolvedWidth, height: resolvedHeight)
                // BUG-91 gate (test50): the card's OUTER box, the thing the rail has to sit exactly
                // `ringInset` inside of. Armed only under `-debug.cardGeometryProbe YES`; see
                // `DebugAXIdentifier` for why the probe has to publish this rect as well as the
                // rail's.
                .modifier(DebugAXIdentifier("poster_card"))
                // FEAT-14 (final): the ring is drawn on the artwork, inside its own clip bounds —
                // same inside-strokeBorder treatment as the trailer surface's ring in
                // `InlineTrailerCard`. See the file-level comment above for why this replaced the
                // earlier outside-flush-ring geometry. It rides whatever the whole-card focus
                // treatment below does, because it is part of that card.
                .overlay {
                    if accentFocusRing && isFocused {
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .strokeBorder(Theme.Palette.focusRingColor, lineWidth: ringWidth)
                    }
                }
                // BUG-54: in systemLift mode the hover effect hangs HERE, on the artwork container,
                // so its standing platter (drawn at the attached view's bounds) stays hidden behind
                // the opaque poster instead of wrapping the caption too. BUG-93: ring mode's manual
                // scale hangs here too, outside the ring overlay above so the two move together.
                // No-op in still mode.
                .modifier(CardArtworkFocusLift(
                    mode: focusMode,
                    isFocused: isFocused,
                    artworkHeight: resolvedHeight,
                    cornerRadius: style.cornerRadius
                ))

            if titleVisible {
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: resolvedWidth, alignment: .leading)
                    // Gap 13: hidden until focus, but the slot stays in the layout (opacity, not
                    // removal), so rows never change height and the pinned-row geometry, which
                    // charges `cardLockupCaptionChrome` whenever captions are on, is unchanged.
                    // VoiceOver still reads the title.
                    .opacity(PosterTitleReveal.isShown(focused: isFocused, alwaysVisible: titlesAlwaysVisible) ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
                    // BUG-54: the caption follows the system lift's bottom edge — see
                    // `CardCaptionFocusDrop`.
                    .modifier(CardCaptionFocusDrop(
                        mode: focusMode, isFocused: isFocused, artworkHeight: resolvedHeight
                    ))
            }
        }
        // BUG-36: the focus treatment belongs to the WHOLE card — artwork, ring and caption lift
        // (or, in still mode, stay put) as one object. `artworkHeight` keeps everything the
        // treatment draws shaped like the artwork rather than the lockup. See
        // `CardFocusTreatment` for what scales in each mode.
        .modifier(CardFocusTreatment(
            mode: focusMode,
            isFocused: isFocused,
            artworkHeight: resolvedHeight,
            cornerRadius: style.cornerRadius
        ))
        // FEAT-14/BUG-36: a treatment SwiftUI draws itself (ring mode's manual scale, still mode's
        // shadow) isn't lifted into a separate compositor layer the way the system hover effect is,
        // so without an explicit zIndex a focused card can render underneath its unfocused row
        // neighbors instead of above them. The system lift raises the focused card above its
        // siblings implicitly; this is the explicit equivalent, and it stays scoped to the modes
        // that need it so the default (system-lift) path's stacking is completely untouched.
        .zIndex(focusMode.raisesFocusedCard && isFocused ? 1 : 0)
    }
}

/// Landscape (16:9) lockup used for the Continue Watching row: artwork with a progress bar and a
/// title that brightens on focus. Same system focus language as `PosterCard` — use with
/// `.buttonStyle(.borderless)`.
struct LandscapeCard: View {
    let title: String
    let imageURL: String?
    /// 0...1 watched fraction; pass nil to hide the progress bar.
    var progress: Double? = nil
    var width: CGFloat = Theme.Size.landscapeWidth
    var height: CGFloat = Theme.Size.landscapeHeight
    var showTitle: Bool? = nil
    /// Card-depth surface this landscape card belongs to — Continue Watching by default; catalog rows
    /// rendered in landscape mode pass `.posters` so the depth toggles map to the right setting.
    var depthSurface: CardDepthSurface = .continueWatching
    /// Upcoming row: optional second caption line under the title (the show's year). Dims like
    /// the title's unfocused state and rides the same caption focus drop.
    var subtitle: String? = nil
    /// Upcoming/Continue Watching: optional `S02E05` badge drawn bottom-leading on the artwork.
    var overlayLeading: String? = nil
    /// Upcoming row: optional `TODAY` / `IN 4 DAYS` pill drawn bottom-trailing on the artwork.
    var overlayTrailing: String? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    /// FEAT-14: opt-in accent focus ring, default OFF — see `PosterCard`'s copy of this property
    /// for the full rationale (same UserDefaults key, same byte-identical-when-OFF guarantee).
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// BUG-36: opt-in "No Zoom on Focus", default OFF — see `PosterCard`'s copy of this property
    /// for the full rationale (same UserDefaults key, same independent read).
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    private var titleVisible: Bool { showTitle ?? style.showTitle }
    private var focusMode: CardFocusMode {
        .resolve(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    var body: some View {
        let inset = ringInset(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus) // BUG-64 / 2026-08-30 no-zoom investigation
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { // UX-5: artwork↔title gap increased to match PosterCard and expandedTile
            ZStack(alignment: .bottom) {
                CachedAsyncImage(string: imageURL)
                    .frame(width: width - 2 * inset, height: height - 2 * inset)
                    // BUG-31: same fill-overflow → hover-lift ghosting as PosterCard; artwork whose
                    // ratio isn't 16:9 spills out of this fixed frame unless clipped here.
                    // BUG-36: and like PosterCard, this clip stays on the image's own frame so it
                    // crops the artwork instead of capturing the card's focus treatment.
                    .clipped()
                    // BUG-64: inner corner nests inside the ring's outer corner.
                    .clipShape(RoundedRectangle(cornerRadius: max(0, style.cornerRadius - inset)))
                    // BUG-36: depth (and its coverage mask) stays anchored to the artwork frame.
                    // BUG-91: and to the INSET artwork's frame, before the outer re-frame below -
                    // see `PosterCard`'s copy of this comment for the full rationale (same empty
                    // band, same fix, same byte-identical default when `inset == 0`).
                    .nuvioCardDepth(RoundedRectangle(cornerRadius: max(0, style.cornerRadius - inset)),
                                    surface: depthSurface)
                    .frame(width: width, height: height)
                    // BUG-91 gate: same outer-box marker as PosterCard's, so an armed probe run
                    // leaves the landscape cards' button frames unperturbed too.
                    .modifier(DebugAXIdentifier("landscape_card"))

                if overlayLeading != nil || overlayTrailing != nil {
                    // Upcoming/CW artwork badges: sit above the progress bar (when present) and
                    // inside the BUG-64 ring band, exactly like the bar itself. Static text —
                    // never focusable, never hit-testable.
                    HStack(alignment: .bottom, spacing: Theme.Spacing.xs) {
                        if let overlayLeading {
                            CardEpisodeCodeBadge(text: overlayLeading)
                        }
                        Spacer(minLength: 0)
                        if let overlayTrailing {
                            CardAirDatePill(text: overlayTrailing)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm + inset)
                    // VIS-17: above the inset progress capsule when there is one.
                    .padding(.bottom, (progress != nil
                                       ? CardProgressStrip.edgeInset + CardProgressStrip.height + Theme.Spacing.xs
                                       : Theme.Spacing.sm) + inset)
                    .allowsHitTesting(false)
                }

                if let progress {
                    // VIS-17: an inset capsule (spec §5.1) rather than a flush bar along the
                    // artwork's bottom edge. BUG-64: still inside the reserved ring band.
                    CardProgressStrip(progress: progress)
                        .padding(.horizontal, CardProgressStrip.edgeInset + inset)
                        .padding(.bottom, CardProgressStrip.edgeInset + inset)
                }
            }
            .frame(width: width, height: height)
            // FEAT-14 (final) — see PosterCard's copy of this overlay for the full rationale. The
            // ring is drawn on the artwork/progress-bar group, using the same inside-strokeBorder
            // treatment as the trailer surface's ring in `InlineTrailerCard`, and rides whatever
            // the whole-card focus treatment does.
            .overlay {
                if accentFocusRing && isFocused {
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(Theme.Palette.focusRingColor, lineWidth: ringWidth)
                }
            }
            // BUG-54: systemLift hover lives on the artwork/progress-bar group — bounds == artwork,
            // platter hidden behind it. BUG-93: ring mode's manual scale lives here too. See
            // `PosterCard`'s copy and `CardArtworkFocusLift`.
            .modifier(CardArtworkFocusLift(
                mode: focusMode,
                isFocused: isFocused,
                artworkHeight: height,
                cornerRadius: style.cornerRadius
            ))

            if titleVisible {
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The subtitle is an OVERLAY hanging below the title, not a second layout
                    // line, so the card — and with it the focusable frame of the button/link
                    // wrapping it — keeps exactly the single-caption height. Measured on the
                    // pinned-hero Home (sim, 2026-08-19, `debug.homeScrollProbe`): the focus
                    // engine's scroll-to-reveal CENTERS a 378.5pt link frame (rest top +68 in
                    // the rows viewport) but parks a 408pt one at −(viewport − H)/2 = −53.5,
                    // under the clip edge, so the pinned "Upcoming" title slid onto the art and
                    // under the focused card's lift (Christian's device photo). Poster cards
                    // (505.5) sit at −5 by the same formula, which is why only this row showed
                    // it. The line draws into the shelf's own 24pt bottom padding / pinned
                    // bottom reach, so nothing below is disturbed.
                    .overlay(alignment: .topLeading) {
                        if let subtitle, !subtitle.isEmpty {
                            // A hidden twin of the title spaces the overlay: same font, same
                            // single line, same proposal width → the subtitle lands exactly one
                            // caption line below, and the stack may exceed the title's height.
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(Theme.Font.cardTitle)
                                    .lineLimit(1)
                                    .hidden()
                                Text(subtitle)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .lineLimit(1)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: width, alignment: .leading)
                    // BUG-54: caption follows the lift — see `CardCaptionFocusDrop`.
                    .modifier(CardCaptionFocusDrop(
                        mode: focusMode, isFocused: isFocused, artworkHeight: height
                    ))
            }
        }
        // BUG-36: whole-card focus treatment — artwork, progress bar, ring and caption move (or
        // hold still) as one object. See `PosterCard`'s copy for the full rationale.
        .modifier(CardFocusTreatment(
            mode: focusMode,
            isFocused: isFocused,
            artworkHeight: height,
            cornerRadius: style.cornerRadius
        ))
        // FEAT-14/BUG-36: see `PosterCard`'s copy of this zIndex for the full rationale — the
        // SwiftUI-drawn treatments need an explicit zIndex to draw above row neighbors the way the
        // system lift does implicitly; the default path's stacking is untouched.
        .zIndex(focusMode.raisesFocusedCard && isFocused ? 1 : 0)
    }
}

/// VIS-17: the watched-progress capsule drawn on landscape artwork (Continue Watching, Upcoming),
/// per design spec §5.1: 6pt tall, inset 10pt from the bottom and the sides, a translucent white
/// track and an accent fill. The accent is allowed here: progress is one of the three places the
/// spec keeps the brand colour. Decorative for VoiceOver (the card's title carries the meaning).
struct CardProgressStrip: View {
    let progress: Double

    static let height: CGFloat = 6
    static let edgeInset: CGFloat = 10

    private var fraction: CGFloat { CGFloat(min(max(progress, 0), 1)) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                if fraction > 0 {
                    Capsule()
                        .fill(Theme.Palette.progress)
                        // Never narrower than its own height, so a few seconds watched still
                        // reads as a dot rather than vanishing into the capsule's round end.
                        .frame(width: max(Self.height, geo.size.width * fraction))
                }
            }
        }
        .frame(height: Self.height)
        // Keeps the track legible over bright artwork without a scrim on the whole card.
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}

/// `S02E05` badge drawn on landscape-card artwork (Upcoming + Continue Watching rows).
///
/// VIS-17: a `.thick` material capsule (spec §5.1: badges on art are Caption 2 bold on a thick
/// material, never glass). The scheme is pinned dark so the material always resolves to its dark
/// variant behind the fixed-white text, whatever the host does to `colorScheme` (BUG-28 class:
/// the foreground is deliberately not semantic). Reduce Transparency makes the material opaque
/// on its own.
struct CardEpisodeCodeBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Theme.Surface.panel, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

/// `TODAY` / `TOMORROW` / `IN 4 DAYS` pill drawn on Upcoming-row artwork. Same material capsule
/// as `CardEpisodeCodeBadge` (VIS-17).
struct CardAirDatePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Theme.Surface.panel, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

/// Gap 13: poster titles are hidden until the poster takes focus (HIG Lockups › Posters: "an
/// optional title and subtitle, which are hidden until the poster comes into focus"). The synced
/// Hide Labels preference still removes captions entirely. `alwaysVisibleKey` is a device-local
/// opt-out for people who prefer every title on screen; the Appearance pane owns its toggle.
enum PosterTitleReveal {
    static let alwaysVisibleKey = "poster_titles_always_visible"

    static func isShown(focused: Bool, alwaysVisible: Bool) -> Bool {
        alwaysVisible || focused
    }
}

// MARK: - F13: shared poster context menu

/// F13 / design spec §5.6: the long-press menu every title poster shares — library membership and
/// watched state, the two actions that apply to a title without opening it. Attach it to the
/// poster's `Button`/`NavigationLink` with `.posterContextMenu(item)`.
///
/// A series (any non-movie type, which `togglePosterWatched` may mark episode by episode) asks for
/// confirmation first, exactly like the Detail page's Mark Watched button, because the change
/// touches every released episode.
struct PosterContextMenu: ViewModifier {
    let preview: MetaPreview
    @State private var confirmingSeriesWatched = false
    @State private var seriesWasWatched = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                PosterContextMenuItems(preview: preview) { wasWatched in
                    seriesWasWatched = wasWatched
                    confirmingSeriesWatched = true
                }
            }
            .alert(copy.title, isPresented: $confirmingSeriesWatched) {
                Button(copy.confirm, role: .destructive) {
                    PosterContextActions.toggleWatched(preview)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(copy.message)
            }
    }

    /// Same keys and English as `DetailView.seriesWatchedCopy`, so the catalog carries one string.
    private var copy: (title: String, confirm: String, message: String) {
        if seriesWasWatched {
            return (
                String(localized: "detail.seriesWatched.unmark.title", defaultValue: "Mark all episodes as unwatched?",
                       comment: "Confirmation title before clearing the watched state of every episode of a series"),
                String(localized: "detail.seriesWatched.unmark.confirm", defaultValue: "Mark Unwatched",
                       comment: "Confirm button: clear the watched state of every episode of a series"),
                String(localized: "detail.seriesWatched.unmark.message",
                       defaultValue: "Watch history and progress for every episode of this series will be cleared.",
                       comment: "Confirmation message before clearing the watched state of a whole series")
            )
        }
        return (
            String(localized: "detail.seriesWatched.mark.title", defaultValue: "Mark all episodes as watched?",
                   comment: "Confirmation title before marking every released episode of a series as watched"),
            String(localized: "detail.seriesWatched.mark.confirm", defaultValue: "Mark Watched",
                   comment: "Confirm button: mark every released episode of a series as watched"),
            String(localized: "detail.seriesWatched.mark.message",
                   defaultValue: "Every released episode of this series will be marked as watched.",
                   comment: "Confirmation message before marking a whole series as watched")
        )
    }
}

/// The menu's rows. A separate view so the repository reads run when the menu is built, and so
/// each opening reflects the current library and watched state.
private struct PosterContextMenuItems: View {
    let preview: MetaPreview
    let confirmSeries: (_ wasWatched: Bool) -> Void

    var body: some View {
        let saved = PosterContextActions.isSaved(preview)
        let watched = PosterContextActions.isWatched(preview)

        Button {
            PosterContextActions.toggleLibrary(preview)
        } label: {
            if saved {
                Label("Remove from Library", systemImage: "minus.circle")
            } else {
                Label("Add to Library", systemImage: "plus.circle")
            }
        }

        Button {
            if PosterContextActions.isSeriesLike(preview) {
                confirmSeries(watched)
            } else {
                PosterContextActions.toggleWatched(preview)
            }
        } label: {
            if watched {
                Label("Mark Unwatched", systemImage: "eye.slash")
            } else {
                Label("Mark Watched", systemImage: "checkmark.circle")
            }
        }
    }
}

/// The shared repository calls behind the poster menu. Same calls the Detail page makes for a
/// catalog preview (`DetailViewModel.toggleLibrary` / `toggleWatched` before the meta loads).
enum PosterContextActions {
    static func isSaved(_ preview: MetaPreview) -> Bool {
        LibraryRepository.shared.isSaved(id: preview.id, type: preview.type)
    }

    static func isWatched(_ preview: MetaPreview) -> Bool {
        WatchedRepository.shared.isWatched(id: preview.id, type: preview.type, season: nil, episode: nil)
            || WatchedRepository.shared.isFullyWatchedSeries(id: preview.id, type: preview.type)
    }

    /// Mirrors `DetailView.requestToggleWatched`: anything that is not a movie may be a series.
    static func isSeriesLike(_ preview: MetaPreview) -> Bool {
        preview.type != "movie"
    }

    static func toggleLibrary(_ preview: MetaPreview) {
        LibraryRepository.shared.toggleSaved(item: preview.toLibraryItem(savedAtEpochMs: 0))
    }

    /// `togglePosterWatched` fetches a series' details itself and marks its released episodes;
    /// a movie toggles its own mark.
    static func toggleWatched(_ preview: MetaPreview) {
        WatchingActions.shared.togglePosterWatched(preview: preview) { _ in }
    }
}

extension View {
    /// F13: attach the shared poster long-press menu — see `PosterContextMenu`.
    func posterContextMenu(_ preview: MetaPreview) -> some View {
        modifier(PosterContextMenu(preview: preview))
    }
}
