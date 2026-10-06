import SwiftUI

/// BUG-92 (beta.18 follow-up): the tester's original report ("inline trailer on the GIGN card sits
/// offset — dark band between the [ring] and the video") was fixed by `InlineTrailerTileGeometry`
/// concentering the video inside the reserved ring band. A second report on the SAME bug number
/// followed: with **No Zoom ON** (`CardFocusButtonStyle` swaps to `StillCardButtonStyle` +
/// `.focusEffectDisabled(true)` — zero system lift, see `PosterCard.swift`), accent ring OFF, Card
/// Depth ON, the inline trailer spills past the poster's edge — but *only on the FIRST (left-most)
/// card of a row*.
///
/// Root cause: every catalog row's horizontal `ScrollView` carries `.scrollClipDisabled()`
/// (`BrowseComponents.swift` ~L3107) so a focused card's own lift/reach/ring bleed is never
/// clipped — by design: that bleed is meant to land OVER the focused card's left neighbour, which
/// is invisible because the neighbour is already there, drawn on top. The first card in a row has
/// no left neighbour. Its bleed lands on the empty overscan margin outside the row's own content
/// instead — nothing hides it there, which is exactly the "spills past the edge" the tester saw.
/// (`.shadow(...)` outside the tile's `.clipShape`, sub-pixel rounding in
/// `InlineTrailerTileGeometry.inner`, and the expanding tile's rightward growth were all
/// investigated as the source of the bleed itself; none of them are what makes it VISIBLE only on
/// card #1 — `.scrollClipDisabled()` is.)
///
/// `RowLeadingEdgeClip` clips ONLY the row's leading edge. Every other side is left ~2000pt open so
/// this can never accidentally reach into something BUG-92 was never about: a card's vertical lift,
/// the row's own top/bottom reach-band padding, or the inline-trailer morph's RIGHTWARD tile growth
/// (UX-4a). It composes with `.scrollClipDisabled()` as a single `.clipShape` on the row's
/// CONTENT — never on the `ScrollView` itself, which would silently undo
/// `.scrollClipDisabled()`'s whole effect for every other card in the row.
///
/// ## How BrowseComponents should attach this (NOT done here — a different wave owns that file)
///
/// Attach the clip to the `LazyHStack` — the `ScrollView`'s CONTENT — right where
/// `.scrollClipDisabled()` already lives, in `CatalogRowView.body` (`BrowseComponents.swift`
/// ~L3044-3107):
///
/// ```swift
/// LazyHStack(spacing: Theme.Spacing.rowGap) {
///     // ... ForEach(section.items) { ... }, the trailing "See All" card ...
/// }
/// .padding(.vertical, Theme.Spacing.lg)          // unchanged, already there
/// .clipShape(RowLeadingEdgeClip(allowance: leadingEdgeAllowance))   // NEW — attach here
/// .scrollClipDisabled()                          // unchanged, already there
/// ```
///
/// `leadingEdgeAllowance` needs two AppStorage reads `CatalogRowView` doesn't have yet
/// (`PosterCard.swift`'s own copies, same keys):
///
/// ```swift
/// @AppStorage("accent_focus_ring") private var accentFocusRing = false
/// @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
///
/// private var leadingEdgeAllowance: CGFloat {
///     let posterWidth = posterStyle.landscapeCatalogRows ? Theme.Size.landscapeWidth : posterStyle.width
///     // No lift at all in No Zoom mode (`CardFocusMode.still`) — only the ring can bleed there.
///     // Otherwise this is `PosterCard.swift`'s own `cardLiftScale(artworkHeight:)` formula
///     // inlined — that function is `private` to PosterCard.swift, so this recomputes it from the
///     // SAME public constant (`Theme.Size.heroPinnedRowFocusLiftAllowance`) rather than exposing
///     // a new cross-file symbol for one call site. If `cardLiftScale` is ever made internal,
///     // prefer calling it directly instead of keeping two copies of this formula in sync by hand.
///     let liftScale = noZoomOnFocus ? 1 : 1 + 2 * Theme.Size.heroPinnedRowFocusLiftAllowance / rowArtworkHeight
///     // Mirrors PosterCard.swift's `ringInset(accentFocusRing:noZoomOnFocus:)` — either ring
///     // reserves the same band.
///     let ring: CGFloat = (accentFocusRing || noZoomOnFocus) ? ringWidth : 0
///     return RowLeadingEdgeClip.allowance(posterWidth: posterWidth, liftScale: liftScale, ringWidth: ring)
/// }
/// ```
///
/// (`rowArtworkHeight` and `posterStyle` are both already properties of `CatalogRowView`;
/// `ringWidth` is `PosterCard.swift`'s top-level constant, already visible module-wide.)
struct RowLeadingEdgeClip: Shape {
    /// How far past the row's leading (left) edge a focused first card may bleed before being cut
    /// off. 0 clips flush to the row's own leading edge — the right answer for a row with no lift
    /// and no ring (nothing ever bleeds).
    var allowance: CGFloat

    func path(in rect: CGRect) -> Path {
        // Wide open on every side except leading. 2000pt is comfortably past anything a focus
        // lift, a ring, a reach band, or the inline-trailer morph's rightward growth could ever
        // bleed by — it exists purely so this shape can never accidentally clip a direction
        // BUG-92 was never about, not because any of those bleeds are expected to approach it.
        let overscan: CGFloat = 2000
        let clipped = CGRect(
            x: rect.minX - allowance,
            y: rect.minY - overscan,
            width: rect.width + allowance + overscan * 2,
            height: rect.height + overscan * 2
        )
        return Path(clipped)
    }

    /// The bleed a focused card's lift + ring can put outside its own layout frame, in points —
    /// what `allowance` above should be set to for a given row.
    ///
    /// - `posterWidth`: the row's card width at rest (`PosterStyle.width`, or
    ///   `Theme.Size.landscapeWidth` for landscape rows) — what the lift scales ABOUT THE CENTRE
    ///   of, so half of the width growth bleeds left and half right.
    /// - `liftScale`: the scale factor a focused card's artwork is drawn at. `1.0` means no lift
    ///   bleed at all (No Zoom's `CardFocusMode.still`, which scales nothing) — only `ringWidth`
    ///   then contributes. A zoom-on row should pass the same per-artwork-height scale
    ///   `PosterCard.swift`'s `cardLiftScale(artworkHeight:)` computes (both `.systemLift` and
    ///   `.manualScale` are calibrated to the identical `Theme.Size.heroPinnedRowFocusLiftAllowance`
    ///   rise, so one formula covers both — see the attachment snippet above for why this file
    ///   recomputes it instead of calling that `private` function directly).
    /// - `ringWidth`: the reserved ring band in points, `0` when neither focus ring is active —
    ///   pass `PosterCard.swift`'s top-level `ringWidth` constant (4pt) when `accent_focus_ring` or
    ///   `no_zoom_on_focus`'s still ring is on, mirroring that file's own `ringInset(...)`.
    ///
    /// `ceil`, not a bare half-width: a fractional point of uncovered bleed is exactly the "thin
    /// dark sliver" shape BUG-92 is about, and over-provisioning the clip by rounding UP costs
    /// nothing a 10-foot viewer would ever notice.
    /// The focused card's drop shadow (`PosterCard` `.shadow(radius: 22, y: 10)` in every style,
    /// including the No Zoom `.still` style; `InlineTrailerCard`'s tile shadow is the same 22 when
    /// no ring band is active). Codex beta.18 r2 (P2): the allowance used to cover only the lift
    /// bleed and the ring, so the first card's shadow was sliced into a hard vertical edge on
    /// every row. The shadow is a blur, so its visible extent is its radius.
    static let cardShadowRadius: CGFloat = 22

    static func allowance(posterWidth: CGFloat, liftScale: CGFloat, ringWidth: CGFloat,
                          shadowRadius: CGFloat = cardShadowRadius) -> CGFloat {
        ceil(posterWidth * (liftScale - 1) / 2) + ringWidth + shadowRadius
    }
}
