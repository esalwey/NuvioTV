import SwiftUI

/// BUG-112 (Item A) — the row half of Home's "the focus engine could not move Up" fallback.
///
/// On hardware, with the pinned hero and the rows resting ~100pt deeper on an up-walk than on the
/// way down (see `PinnedRowSettle`'s header and BUG-112), row 1 ends entirely above the rows
/// viewport and tvOS refuses to focus it: the Up press resolves to no candidate, the engine
/// consumes nothing, and SwiftUI hands the move to the focused view chain — where `HomeView`'s
/// `.onMoveCommand` now reveals and focuses the previous row itself. This file carries the two
/// pieces that cannot live in `HomeView`: the request value the rows observe, and the one-line
/// modifier each row applies to its OWN `@FocusState`.
///
/// Why the row's own FocusState and not a Home-owned one applied to the cards: a second
/// `.focused` binding on a card collides with the row's (CollectionsUI.swift's `stillFocused`
/// comment records the device rounds that established this), and a Home-side `.focusScope` +
/// `resetFocus` would declare a new focus container over the rows — the change class that broke
/// test54's row walk when the shell scope was declared in both chrome modes (ContentView.swift).
///
/// Inert outside Home: nothing but `HomeView` ever writes `pinnedRowFocusRequest`, its default
/// carries `rowKey == nil`, and `onChange` on a value that never changes costs a comparison per
/// environment publish. Search's and Library's `CatalogRowView`s are untouched.
nonisolated struct PinnedRowFocusRequest: Equatable, Sendable {
    /// The row that should take focus. `nil` (the default everywhere) matches no row.
    var rowKey: String?
    /// Bumped on every request, so two consecutive requests for the SAME row are two distinct
    /// values and the rows' `onChange` fires for both (the retry rungs depend on this).
    var generation: Int

    static let none = PinnedRowFocusRequest(rowKey: nil, generation: 0)
}

private struct PinnedRowFocusRequestKey: EnvironmentKey {
    static let defaultValue = PinnedRowFocusRequest.none
}

extension EnvironmentValues {
    var pinnedRowFocusRequest: PinnedRowFocusRequest {
        get { self[PinnedRowFocusRequestKey.self] }
        set { self[PinnedRowFocusRequestKey.self] = newValue }
    }
}

/// BUG-112 review fix (F3) — row OWNERSHIP, reported separately from hero-preview availability.
///
/// `HomeView.reportRowFocus` used to be the only writer of `focusedRowKey`, and it only claimed
/// the row when the focused item produced a non-nil hero preview — so landing on a row's "See
/// All" tile (or a folder with no configured backdrop/logo, both of which report `item == nil`)
/// never claimed the row, and the fallback's idea of "who has focus" went stale the moment a user
/// stopped there. This closure fires straight off the row's own `@FocusState` binding instead —
/// the same binding `pinnedRowUpFallbackTarget` already writes to land a fallback — so ownership
/// can never disagree with what is actually focused. A plain struct wrapper (not a bare closure)
/// keeps the environment value's type simple and gives it a name reviewers can trace.
struct PinnedRowFocusOwnership {
    let report: (_ rowKey: String, _ owns: Bool) -> Void
}

private struct PinnedRowFocusOwnershipKey: EnvironmentKey {
    static let defaultValue = PinnedRowFocusOwnership { _, _ in }
}

extension EnvironmentValues {
    var pinnedRowFocusOwnership: PinnedRowFocusOwnership {
        get { self[PinnedRowFocusOwnershipKey.self] }
        set { self[PinnedRowFocusOwnershipKey.self] = newValue }
    }
}

/// Applies a matching focus request to the row's own focus binding, and reports this row's
/// ownership of focus (F3) as it changes. `firstId` is the row's FIRST rendered card — the
/// leftmost stop, which is where a reveal-then-focus should land; the engine re-reveals the row
/// around it exactly as it would for a user-driven hop.
///
/// `focus.wrappedValue == nil` is the anti-theft guard: a request that arrives while this row
/// ALREADY holds focus (a late retry rung whose earlier rung landed) must not yank the user off
/// whichever card they are on.
private struct PinnedRowUpFallbackTarget: ViewModifier {
    let rowKey: String
    let firstId: String?
    let focus: FocusState<String?>.Binding
    @Environment(\.pinnedRowFocusRequest) private var request
    @Environment(\.pinnedRowFocusOwnership) private var ownership

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, new in
                applyIfMatching(new)
            }
            .onChange(of: focus.wrappedValue != nil) { _, owns in
                ownership.report(rowKey, owns)
            }
            // F5: `onChange(of:)` with the default `initial: false` only fires on a value change
            // AFTER this row is already observing it — a row the `LazyVStack` culls and later
            // remounts (scrolled back into view by the fallback's own reveal rung) receives the
            // CURRENT request as its initial environment value and silently drops it. Re-apply a
            // still-active matching request on mount so a late-mounting row is not stranded.
            .onAppear {
                applyIfMatching(request)
            }
    }

    private func applyIfMatching(_ request: PinnedRowFocusRequest) {
        guard request.rowKey == rowKey, let firstId, focus.wrappedValue == nil else { return }
        focus.wrappedValue = firstId
    }
}

extension View {
    /// One line per pinned row. See `PinnedRowUpFallbackTarget`.
    func pinnedRowUpFallbackTarget(rowKey: String,
                                   firstId: String?,
                                   focus: FocusState<String?>.Binding) -> some View {
        modifier(PinnedRowUpFallbackTarget(rowKey: rowKey, firstId: firstId, focus: focus))
    }
}

/// DEBUG-only launch knob. The shipped trigger — an Up press the focus engine did not consume —
/// is unreachable on the simulator, whose engine always resolves the move (test63/test64 both
/// walk Up into a fully off-screen row 1 successfully). So the knob does NOT change what an Up
/// press does; it arms a PROXY TRIGGER (Play/Pause) that runs the identical fallback body, which
/// is the only sim-provable path to the action ladder. See `HomeView.forcedUpFallbackTrigger`.
///
/// Read once at launch, exactly like `HomeGeometryProbe.enabled` / `PinnedRowSettleProbe.enabled`
/// — `UserDefaults.bool(forKey:)` also coerces the "YES" an `-debug.homeUpFallbackForce YES`
/// launch argument lands in the argument domain, so the harness can arm it without a
/// `defaults write`.
///
/// BUG-112 review fix (F6): `#if DEBUG`-gated. `UserDefaults.bool(forKey:)` reads a preference in
/// EVERY build, DEBUG or Release — nothing about that call is itself DEBUG-only — so an
/// unguarded `forced` would let anyone who can write `debug.homeUpFallbackForce` into the app's
/// defaults domain arm the proxy trigger in a shipped Release build. `forced` hardcodes `false`
/// there instead, so `HomeView.forcedUpFallbackTrigger`'s modifier is always disabled in Release
/// regardless of what is in `UserDefaults`.
enum HomeUpFallbackKnobs {
    #if DEBUG
    nonisolated static let forced = UserDefaults.standard.bool(forKey: "debug.homeUpFallbackForce")
    #else
    nonisolated static let forced = false
    #endif
}
