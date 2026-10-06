import SwiftUI

/// BUG-96 (beta.18): the detail page's rows had no resting place. The page is a plain vertical
/// `ScrollView`, each row is a title above a horizontal shelf of cards, and the cards are the only
/// focusable frames — so a vertical focus move scrolled by exactly the minimum tvOS needed to reveal
/// the focused card, and wherever that left the top edge was incidental. The tester's photos: the
/// film's Saga row focused, and the "Guide parental" header two rows up cut in half under the top
/// edge. Official Nuvio's Compose TV list pivots the focused row to a fixed viewport fraction, so
/// headers above scroll off whole.
///
/// The fix anchors the FOCUSED ROW to a fixed top inset. The first shipped version (build 121,
/// `46ab30f0`) let the engine's own reveal run to completion, then slid the row to its rest after
/// a fixed `settleDelay` — which is exactly a land-then-nudge, and rc5 (u/mrStevenx3) caught it:
/// one Down press visibly scrolled in two steps on every movie. The fix BLENDS instead of
/// following: on a focused-row change, `DetailView` arms a flag and waits for the very first
/// scroll-geometry frame that shows the engine has actually started moving the page, then issues
/// the anchor's own animated `scrollTo(y:)` immediately — so the engine's reveal and the anchor
/// move run as one continuous motion instead of two. A short fallback timer
/// (`blendFallbackDelay`) covers the case where the focused card was already fully visible and the
/// engine never moves the page at all (nothing to blend with, so the anchor just fires on its
/// own). There is nothing here for the two to fight over once blended — no pinned header, no
/// compression, and every row is far shorter than the viewport, so the engine's rest is unique and
/// ours simply supersedes it.
///
/// BUG-99 (rc6, u/mrStevenx3): the blend fix made one Down press one motion, but the row still
/// rested at `screenRest` every time — so the FIRST Down off the header pushed the title,
/// synopsis, buttons and meta fully off screen to reveal one row. Official Nuvio's Down instead
/// reveals the next section at the BOTTOM of the screen, description still visible — the engine's
/// own minimal reveal, which tvOS was already doing before this fix ever anchored anything.
/// Christian's decision (2026-09-08): stop overriding that minimal reveal on Down by default. Up
/// keeps anchoring unconditionally, exactly as it did before BUG-99 — going back up the page still
/// wants the destination row pinned, not wherever the engine's own reveal happens to leave it.
/// Down only anchors when the engine's reveal would otherwise leave the row's header straddling
/// (at or under) the `topScrimHeight` scrim near the top edge — i.e. when leaving it alone would
/// reproduce the ORIGINAL BUG-96 photo (a header cut in half under the top edge), not the two-step
/// motion BUG-96's blend fix already solved. `Direction`/`decision` below is the pure rule; the
/// `DetailView.onChange(of: focusedRow)` handler decides which direction a focus change was and
/// applies it — see that handler's own doc comment for the two different task shapes this produces.
enum DetailRowAnchor {
    /// Where a focused row's TOP rests, in points from the scroll view's top edge. Room for the
    /// row above's bottom padding to have scrolled away whole, and for the focused row's title to
    /// sit clear of the top edge with a cushion under the dim ramp's first steps.
    static let topInset: CGFloat = 72

    /// Fallback only: fires the anchor pass on its own if the engine's reveal never moves the page
    /// (BUG-96 blend regression fix — the prior `settleDelay`, a fixed wait for the reveal to
    /// FINISH before sliding, was deleted; a wait that long is exactly the two-step motion the fix
    /// removes). Short because it only covers the "nothing to blend with" case — the focused card
    /// was already fully visible, so there is no engine motion to catch and start with.
    static let blendFallbackDelay: TimeInterval = 0.05

    /// The named coordinate space on the scroll content (the padded VStack), so row tops can be read
    /// as content offsets.
    static let contentSpace = "detailContent"

    /// The content offset that rests a row whose top is at `rowTop` (content coordinates) at
    /// `topInset` below the viewport's top: `rowTop − topInset`, never negative. The scroll view
    /// clamps the far end itself. This is the same mechanism Home's settle corrector uses
    /// (`ScrollPosition.scrollTo(y:)`); `ScrollViewProxy.scrollTo(id, anchor:)` is ignored by the
    /// focus-driven vertical scroll on this runtime (first fixture runs: nothing ever moved).
    static func targetOffset(rowTop: CGFloat, topInset: CGFloat = topInset) -> CGFloat {
        max(rowTop - topInset, 0)
    }

    /// Where the focused row's TOP rests on SCREEN, in points from the top edge. Content scrolls
    /// under the scroll view's top content inset (157 pt on the fixture: safe area plus the page
    /// chrome's reservation), and nothing covers it, so the rest is set in screen terms.
    static let screenRest: CGFloat = 108

    /// The strip above the rest shows the previous row's tail (its chips, captions, or the bottom
    /// of a header — fixture step 3: the "Parental Guide" header half under the edge). A fixed top
    /// scrim fades that strip to black once the page has scrolled, the same way the dim ramp
    /// treats the backdrop, so cut content reads as scrolled away; the rest sits just under it.
    static let topScrimHeight: CGFloat = 96

    /// `ScrollPosition.scrollTo(y:)` takes CONTENT coordinates and lands the content offset at
    /// `y − contentInsets.top` (fixture probe: `y=890` → `off=733` with `inset=157`). The row's
    /// screen top is then `rowTop − offset`, so for a rest at `screenRest`:
    /// `y = rowTop + contentInsetTop − screenRest`, never negative.
    static func scrollTarget(rowTop: CGFloat, contentInsetTop: CGFloat, screenRest: CGFloat = screenRest) -> CGFloat {
        max(rowTop + contentInsetTop - screenRest, 0)
    }

    /// The content offset that target produces, for the verify pass.
    static func expectedOffset(scrollTarget y: CGFloat, contentInsetTop: CGFloat) -> CGFloat {
        y - contentInsetTop
    }

    /// A rest further than this from the expected offset gets ONE re-issue: the focused card's
    /// thumbnails can finish loading after the settle, and the engine re-reveals the resized card
    /// (fixture step 6: 286 pt short). One retry, never a loop — the Home bounce class.
    static let verifyTolerance: CGFloat = 24
    static let verifyDelay: TimeInterval = 0.45

    /// BUG-99 (rc6): the DOWN-only settle wait. Down no longer blends or arms a fallback — it just
    /// lets the engine's own minimal reveal run, waits for it to have settled, then straddle-checks
    /// the result once. Long enough that the engine's reveal (which, unlike the blend path, nothing
    /// here is racing to catch mid-flight) has actually finished moving the page before the check
    /// reads `dimModel.lastContentOffset`.
    static let settleCheckDelay: TimeInterval = 0.35

    /// BUG-99: which way focus moved — the deciding factor for whether a focus change anchors at
    /// all. See `DetailRowAnchor`'s doc comment and `decision(direction:screenTop:screenRest:)`.
    enum Direction {
        case up, down
    }

    /// The outcome of `decision(direction:screenTop:screenRest:)`: `.anchor` runs the usual
    /// `anchorPass`; `.free` leaves whatever position the focus engine's own reveal already
    /// settled on alone.
    enum Decision: Equatable {
        case anchor, free
    }

    /// Codex P2 review finding (BUG-99 follow-up), round 2: the round-1 fix distinguished "focus
    /// came back from the unanchored Comments section" from "focus came from the top block" with a
    /// `contentOffset`-vs-`lastKnownTop` heuristic, because `focusedRow` went nil in BOTH places —
    /// Comments had no focus tracking of its own. That heuristic broke whenever Comments was
    /// reachable without scrolling the page past the last row's own rest (`lastKnownTop == newTop`
    /// straddling the settle check the same way BUG-99's original straddle case did): resting
    /// short of it read as "still above", so a genuine Up out of Comments misread as Down and the
    /// header the Up path exists to anchor never got anchored.
    ///
    /// The actual fix is structural, not a better heuristic: `commentsSection` now carries
    /// `.detailRowAnchored(.comments, …)` the same as every other row below the top block (see its
    /// call site in `DetailView`), so `focusedRow` reports `.comments` — never nil — while focus is
    /// inside it, and `DetailView.detailRowOffsets[.comments]` holds its real top like any other
    /// row. `focusedRow == nil` now happens ONLY in the unanchored top block (hero, synopsis,
    /// actions), so the ambiguity this heuristic existed to resolve is gone: `old == nil` is
    /// unambiguously "first entry from the top block", full stop. (Comments is still never
    /// anchored or straddle-checked itself — `DetailView.onChange(of: focusedRow)` bails out for
    /// `row == .comments` before calling this function at all.)
    ///
    /// Pure direction rule, `DetailRowAnchorTests`-covered. `old` is the row that just lost focus
    /// (`DetailView`'s own `onChange(of: focusedRow)` `old` parameter — no separate "last known
    /// row" state is needed any more, since a real `old` is available whenever there is one to
    /// have). `oldTop`/`newTop` are row tops in content-space coordinates
    /// (`DetailView.detailRowOffsets`); `oldTop` is `offsets[old]` and can be nil even when `old`
    /// itself is not, if that row's very first `onGeometryChange` callback has not landed yet.
    ///
    /// `old == nil`: the top block — Down. `old` present with `oldTop` known: the ordinary
    /// top-vs-top comparison — a lower content offset is Down. `old` present but `oldTop` missing:
    /// falls back on which row `old` was — `.comments` reads Up (it sits below every anchored row,
    /// so leaving it can only be Up), anything else reads Down (the original default for a row
    /// whose top dropped out of the map).
    static func direction(old: DetailRowID?, oldTop: CGFloat?, newTop: CGFloat) -> Direction {
        guard let old else { return .down }
        guard let oldTop else { return old == .comments ? .up : .down }
        return newTop > oldTop ? .down : .up
    }

    /// Pure decision table (`DetailRowAnchorTests`). Up is unconditional — always `.anchor`,
    /// matching Up's behaviour before BUG-99 exactly. Down is conditional: `.anchor` only when
    /// `screenTop` (the row's current on-screen top) sits ABOVE `screenRest` — a smaller y, closer
    /// to the top edge, meaning the header would rest under/near the `topScrimHeight` scrim, the
    /// straddle case BUG-96 exists to fix. `.free` otherwise (at or below `screenRest`, screenRest
    /// itself included — a row already resting at or past its own target rest needs no rescuing),
    /// leaving the engine's own minimal reveal in place (BUG-99).
    static func decision(direction: Direction, screenTop: CGFloat, screenRest: CGFloat = screenRest) -> Decision {
        switch direction {
        case .up:
            return .anchor
        case .down:
            return screenTop < screenRest ? .anchor : .free
        }
    }

    /// `scrollTo(_:anchor:)` aligns the row's anchor POINT with the scroll view's same anchor point:
    /// `row.minY + k·rowHeight == viewport.minY + k·viewportHeight`. Solving for the row's top to
    /// land at `topInset`: `k = topInset / (viewportHeight − rowHeight)`. Clamped to the unit range;
    /// a row taller than the remaining viewport can only be top-aligned.
    static func anchor(rowHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat = topInset) -> UnitPoint {
        let room = viewportHeight - rowHeight
        guard room > 0 else { return .top }
        let k = topInset / room
        return UnitPoint(x: 0, y: min(max(k, 0), 1))
    }
}

/// The rows the anchor tracks. `topBlock` (hero, synopsis, actions) is deliberately absent: focus
/// there means "the page is at the top", and anchoring it would scroll the backdrop away.
/// `.comments` IS tracked (`commentsSection` carries `.detailRowAnchored(.comments, …)`, Codex P2
/// BUG-99 follow-up round 2) but is never itself anchored — `DetailView.onChange(of: focusedRow)`
/// bails out for it before any anchor decision runs. It needs tracking only so `direction(old:…)`
/// can see a real top for it instead of the `nil` that made it indistinguishable from the top
/// block.
enum DetailRowID: Hashable {
    case logos, parental, episodes, cast, collection, trailers, moreLikeThis, comments
}

/// One `onScrollGeometryChange` callback's content offset, timestamped at the moment it fired.
struct MotionSample {
    let time: TimeInterval
    let offset: CGFloat

    init(time: TimeInterval, offset: CGFloat) {
        self.time = time
        self.offset = offset
    }
}

/// BUG-96 oracle: counts how many separate *motions* a run of timestamped content-offset samples
/// shows, where "one motion" is the whole point of the blend fix — the engine's reveal and the
/// anchor pass are meant to read as a single continuous move, not the old land-then-nudge (two
/// motions). Pure and stateless so `DetailRowAnchorTests` can drive it with fabricated sample
/// arrays instead of a live `ScrollView`.
///
/// Codex P2 (rc5 follow-up): the original design split segments on a RUN of consecutive
/// near-stationary SAMPLES, which assumed the callback keeps delivering samples while the page
/// sits still. It does not — `onScrollGeometryChange` fires only on a CHANGE to the observed
/// value, so a genuine pause between the engine's reveal and the anchor correction (exactly the
/// land-then-nudge regression this oracle exists to catch) can produce zero samples in the gap,
/// and the fabricated plateau arrays the old unit tests fed in never occur from the real callback.
/// The split is therefore TIME-based, not sample-count-based: a new segment starts when the gap
/// since the last moving sample is long enough that a real pause, not a dropped frame, must have
/// happened.
enum DetailScrollMotion {
    /// The per-sample threshold below which two consecutive offsets count as "the page did not
    /// move" rather than genuine (if slow) motion — matches the sub-pixel jitter a `ScrollView`
    /// can report even at rest.
    static let stationaryThreshold: CGFloat = 0.5

    /// How long a gap since the last MOVING sample has to be before a new sample starts a new
    /// segment instead of continuing the current one. ~3 frames at 30 fps — comfortably above a
    /// single dropped callback (the callback fires on change only, so one skipped frame under
    /// continuous motion must not read as a pause) and well under the old fixed `settleDelay`
    /// (0.35 s) this oracle was built to catch a regression back to.
    static let pauseToSplit: TimeInterval = 0.10

    /// A "segment" is a run of samples whose |Δoffset| from the last MOVING sample is at or above
    /// `stationaryThreshold`, broken only when the time since that last moving sample reaches
    /// `pauseToSplit` — a shorter gap (including no gap at all, since the callback may simply not
    /// fire while the page is genuinely at rest) does not split one continuous motion into two.
    /// A sample that is itself sub-threshold (jitter) never starts or extends a segment and is
    /// ignored for gap timing. `moves=1` at rest on the `debug_ux6` probe means the engine's
    /// reveal and the anchor pass blended into one visible motion; `moves=2` means the
    /// land-then-nudge regression is back.
    static func segments(_ samples: [MotionSample]) -> Int {
        guard samples.count > 1 else { return 0 }
        var count = 0
        var lastMovingTime: TimeInterval?
        var lastOffset = samples[0].offset
        for i in 1..<samples.count {
            let sample = samples[i]
            let delta = abs(sample.offset - lastOffset)
            lastOffset = sample.offset
            guard delta >= stationaryThreshold else { continue }
            if let last = lastMovingTime, sample.time - last < pauseToSplit {
                // Continues the current segment.
            } else {
                count += 1
            }
            lastMovingTime = sample.time
        }
        return count
    }
}

/// Attach to each detail row at its call site: gives it a scroll id, reports whether focus is
/// inside it, and measures its height (rarely changing, so no per-frame invalidation — the BUG-41
/// rule) for the anchor math.
struct DetailRowAnchored: ViewModifier {
    let id: DetailRowID
    let focusedRow: FocusState<DetailRowID?>.Binding
    /// Each row's top, in the scroll CONTENT's own coordinate space (`DetailRowAnchor.contentSpace`):
    /// content coordinates do not move as the page scrolls, so this changes only on layout.
    let offsets: Binding<[DetailRowID: CGFloat]>

    func body(content: Content) -> some View {
        content
            .id(id)
            .focused(focusedRow, equals: id)
            .onGeometryChange(for: CGFloat.self,
                              of: { $0.frame(in: .named(DetailRowAnchor.contentSpace)).minY },
                              action: { top in
                if offsets.wrappedValue[id] != top { offsets.wrappedValue[id] = top }
            })
    }
}

extension View {
    func detailRowAnchored(_ id: DetailRowID,
                           focusedRow: FocusState<DetailRowID?>.Binding,
                           offsets: Binding<[DetailRowID: CGFloat]>) -> some View {
        modifier(DetailRowAnchored(id: id, focusedRow: focusedRow, offsets: offsets))
    }
}
