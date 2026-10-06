import Combine
import SwiftUI

/// Shared visibility state for the floating glass tab bar's immersive-push signal, plus the
/// FEAT-25 "is Home frontmost" signal below.
///
/// T2 (beta.14 regression fix — retired a signal this class used to combine): this class used to
/// also own `scrolledAway`, a SINGLE shared slot fed by whichever tab root last called
/// `setScrolled(_:)`, folded together with `detailDepth` into one `hidden` bit. That was wrong
/// for two reasons: a single shared slot across four independently-scrolling tabs is
/// last-writer-wins (tab B's scroll position could overwrite tab A's), and `ContentView`'s
/// tab-switch reset (`setScrolled(false)`) could race under the latch and desync `hidden` from
/// the actually-selected tab's real position. It was also long dead for the bar's OWN
/// presentation — round 4 (below, `immersiveHidden`) already stopped the toolbar from reading
/// `hidden` at all. The only real consumer was `isScrolledDown` (BUG-27's Menu-to-top signal),
/// and that was already correctly served by `TabBarScrollAutoHide`'s own per-tab
/// `@State private var hidesBar` — one latch per tab root, not one shared across all four.
/// `scrolledAway`/`setScrolled(_:)`/`hidden` are gone; the per-tab `@State` latch is the real
/// state and always was.
///
/// `detailDepth`: count of "immersive" pushed screens (currently just `DetailView`) stacked on
/// top of the active tab's `NavigationStack`. A depth counter rather than a `Bool` because
/// Detail → More Like This → Detail nests — the bar should only reappear once every pushed
/// immersive screen has been popped, not after the first one.
///
/// Owned as a single instance in `MainTabView` (see that property's own doc comment for why T3
/// made it `@State` rather than `@StateObject`) and read/written by descendants via
/// `@Environment(\.tabBarVisibility)` — a custom environment key (not `@EnvironmentObject`) so
/// views that can be presented *outside* the tab shell (e.g. `DetailView` reached through
/// `DeepLinkTitleView`'s own standalone `NavigationStack`, pushed from a Top Shelf deep link with
/// no tab bar in play at all) fall back to a harmless unconnected default instance instead of
/// crashing for a missing environment object.
@MainActor
final class TabBarVisibility: ObservableObject {
    private var detailDepth = 0 {
        didSet { recompute() }
    }

    /// Called from an immersive pushed screen's `.onAppear` (currently `DetailView`).
    func pushImmersive() {
        detailDepth += 1
    }

    /// Called from the same screen's `.onDisappear`. An unmatched call (shouldn't happen, but
    /// SwiftUI view lifecycle edge cases are never fully guaranteed) is a full no-op: the early
    /// return both keeps the depth from going negative (which would take two pops to recover) and
    /// keeps the probe from logging a push/pop cycle that never occurred — the cycle counter
    /// exists to diagnose BUG-66, so a phantom count is worse than none (Codex beta.14 r4).
    func popImmersive() {
        guard detailDepth > 0 else { return }
        detailDepth -= 1
        TabBarProbe.recordPop(depthAfter: detailDepth)
    }

    /// BUG-30/66/62 diagnostics only — read-only surface of the depth `immersiveHidden` is
    /// computed from, for the About pane's live tab-bar readout.
    var immersiveDepth: Int { detailDepth }

    /// FEAT-25 (device pass 2026-08-21): whether the HOME tab's root content is the frontmost
    /// surface — false while another tab is selected or an immersive screen is pushed over it.
    /// Exists because neither event fires `onDisappear` on Home's subtree (each tab keeps its
    /// NavigationStack alive across a switch, and a push keeps the stack root mounted), so the
    /// hero's autoplaying trailer kept making sound under Detail pages and in Settings. Published
    /// so `HomeHeroBackdrop` can subscribe imperatively (`onReceive`) — the covered subtree is
    /// still hierarchy-resident (that's the bug) but may not re-render while hidden, so a
    /// render-driven gate could defer teardown exactly when it matters.
    @Published private(set) var homeSurfaceCovered = false

    private var homeTabSelected = true {
        didSet { recomputeHomeCovered() }
    }
    /// ContentView's app-root deep-link cover (Top Shelf) — presented over the whole shell, so
    /// it covers Home without touching tab selection or push depth (Codex beta.14 r8).
    private var rootCoverActive = false {
        didSet { recomputeHomeCovered() }
    }

    /// MainTabView reports selection changes here (Home is tab value 0).
    func setHomeTabSelected(_ selected: Bool) {
        guard homeTabSelected != selected else { return }
        homeTabSelected = selected
    }

    /// MainTabView forwards ContentView's deep-link cover presence here.
    func setRootCoverActive(_ active: Bool) {
        guard rootCoverActive != active else { return }
        rootCoverActive = active
    }

    private func recomputeHomeCovered() {
        let covered = !homeTabSelected || detailDepth > 0 || rootCoverActive
        if homeSurfaceCovered != covered { homeSurfaceCovered = covered }
    }

    /// T3: also drives `immersiveHidden` now — see that property's doc comment for why the write
    /// is guarded to an actual 0↔>0 crossing rather than reassigning on every `detailDepth`
    /// change.
    private func recompute() {
        let hidden = detailDepth > 0
        if immersiveHidden != hidden { immersiveHidden = hidden }
        recomputeHomeCovered()
    }

    /// Device pass round 4 (2026-08-02): the toolbar drives off THIS, not the retired `hidden`.
    /// Toggling `.toolbarVisibility(.hidden)` on scroll and re-showing it later left the system
    /// bar frozen mid-slide on real hardware — clipped at the top until focus moved within it —
    /// through three rounds of transition fixes (.automatic→.visible, dropping the custom
    /// animation). The cure is structural: never toggle visibility for scrolling at all; the
    /// tvOS 26 system bar already minimizes/expands natively as content scrolls (`.automatic`),
    /// so there is no hidden→shown transition left to get stuck. Only the immersive detail push
    /// still force-hides. T2: the retired `hidden`/`scrolledAway` were never read by bar
    /// presentation anyway (that's what made them safe to retire) — `isScrolledDown`, computed
    /// per-tab in `TabBarScrollAutoHide`, remains the BUG-27 Menu-to-top signal, unrelated to bar
    /// presentation.
    ///
    /// T3 (beta.14 regression fix): `@Published`, not computed, and written from `recompute()`
    /// ONLY on an actual 0↔>0 crossing — never reassigned to the same value it already held.
    /// This is what makes `tabBarImmersiveHide()` below narrow: it subscribes to
    /// `$immersiveHidden` specifically, so a redundant same-value write (which `@Published` would
    /// still broadcast — it doesn't dedupe) would otherwise re-resolve `.toolbarVisibility` for
    /// no reason. Before T3 this was a plain computed property read fresh by a modifier that took
    /// the whole `TabBarVisibility` object as a parameter — which meant the modifier's owning
    /// view (`MainTabView`, via `@StateObject`) re-evaluated on EVERY `@Published` change on the
    /// object, including unrelated ones like `homeSurfaceCovered`, and `.toolbarVisibility` got
    /// re-resolved along with it. That's the exact mechanism rounds 1–3 fought blind: the bar
    /// froze mid-slide because its resolved preference kept changing identity underneath an
    /// in-flight system transition, on every tab switch. See `tabBarImmersiveHide()` and
    /// `MainTabView.tabBarVisibility` for the other two pieces of this fix.
    @Published private(set) var immersiveHidden: Bool = false
}

private struct TabBarVisibilityKey: EnvironmentKey {
    static let defaultValue = TabBarVisibility()
}

extension EnvironmentValues {
    var tabBarVisibility: TabBarVisibility {
        get { self[TabBarVisibilityKey.self] }
        set { self[TabBarVisibilityKey.self] = newValue }
    }
}

/// Applies the detail-push-driven tab-bar auto-hide to one tab's root content. Formerly
/// `ContentView.tabBarAutoHide(_ vis: TabBarVisibility)`, a `private extension View` that took
/// the shared instance as a parameter — T3 (beta.14 regression fix) moved it here as a
/// no-argument modifier instead:
///
/// Reading `tabBarVisibility` via `@Environment` INSIDE this modifier (rather than as a
/// parameter) is what makes each `Tab` closure in `MainTabView` a constant, prunable view value —
/// a parameter of object identity forced the closure to be re-evaluated whenever the object's
/// identity was seen as changing inputs upstream. Combined with `MainTabView` reading
/// `$immersiveHidden` through a narrow `onReceive` rather than the whole object through
/// `@StateObject`, `.toolbarVisibility` can now only re-resolve on an actual `immersiveHidden`
/// publish — i.e. a Detail push/pop — never as a side effect of a tab switch. See
/// `MainTabView.tabBarVisibility`'s own doc comment for the other half of this fix.
private struct TabBarImmersiveHideModifier: ViewModifier {
    @Environment(\.tabBarVisibility) private var vis
    @State private var immersive = false

    /// VIS-16 (D1): the shell is now a system `.sidebarAdaptable` TabView, so the FEAT-30
    /// "sidebar mode" term (and its `-debug.sidebarSpike` alias) that forced the bar hidden for the
    /// whole session is gone. Tab roots resolve `.automatic`, and only an immersive push hides the
    /// tab chrome, exactly as before.
    func body(content: Content) -> some View {
        content
            // Round 4 (see TabBarVisibility.immersiveHidden): scroll no longer toggles bar
            // visibility at all — `.automatic` lets the tvOS 26 system bar do its native
            // minimize/expand as content scrolls, and only the immersive detail push
            // force-hides. Rounds 1–3 proved any hidden→shown reshow can freeze mid-slide
            // on hardware (clipped at the top until focus re-entered the bar), so the fix
            // is to not have a reshow.
            .toolbarVisibility(immersive ? .hidden : .automatic, for: .tabBar)
            // T3: use the PAYLOAD from `onReceive`, not the property — `@Published` emits on
            // willSet, same house rule as HomeView.swift's hero-trailer sync (~L1762-1768:
            // "`@Published` emits on willSet, so use the payload, not the property"). A
            // `@Published` publisher replays its current value to a new subscriber, so no
            // `onAppear` seed is needed here.
            .onReceive(vis.$immersiveHidden) { immersive = $0 }
    }
}

extension View {
    /// Attach to a tab root's content to drive the floating tab bar's immersive-push auto-hide.
    /// No-argument by design (see `TabBarImmersiveHideModifier`'s doc comment) — reads the shared
    /// instance from the environment rather than taking it as a parameter.
    func tabBarImmersiveHide() -> some View {
        modifier(TabBarImmersiveHideModifier())
    }
}

/// One `.onScrollGeometryChange` sample, carried as a small `Equatable` struct rather than a
/// single pre-combined `CGFloat`. Two reasons: the BUG-30/66/62 diagnostics pane needs `y` and
/// `i` separately to be interpretable (see `TabBarProbe.ScrollState`), and observing the inset
/// (not just the offset) means this callback also fires on the system bar's own minimize/expand
/// transitions — timestamping exactly the BUG-66 moment the bar's resolved visibility changes.
/// Hysteresis is unaffected by those extra fires: `residual` is inset-invariant at rest, so a
/// same-position re-fire from a bar transition never crosses either arm on its own.
private struct TabBarScrollSample: Equatable {
    var offsetY: CGFloat
    var insetTop: CGFloat
    /// T1 sign fix: 0 at a scroll view's true top, matching the in-tree formula this residual
    /// was always supposed to share (`HomeView.swift`'s probe, ~L1276: `contentOffset.y +
    /// contentInsets.top`). The OLD formula here (`offset.y - insets.top`) was a sign error —
    /// at the true top `contentOffset.y == -contentInsets.top`, so the old expression evaluated
    /// to −2×insetTop instead of 0, and every threshold below it was tuned against that wrong
    /// number.
    var residual: CGFloat { offsetY + insetTop }
}

/// Reports a tab root's main scroll view position via hysteresis so the bar doesn't flicker right
/// at one boundary. `hidesBar` mirrors the last state actually reported, so `isScrolledDown` only
/// changes on a real crossing — not once per scroll tick.
///
/// T2: this used to also forward crossings to the shared `TabBarVisibility` via `setScrolled(_:)`
/// — retired along with that method (see the class doc comment): a single shared slot fed by
/// whichever tab last fired is wrong when four tabs scroll independently, and nothing besides
/// `isScrolledDown` ever needed the crossing anyway. This modifier is now purely local per-tab
/// state.
private struct TabBarScrollAutoHide: ViewModifier {
    @State private var hidesBar = false
    /// BUG-30/66/62: which tab root this is, for the About-pane diagnostics readout.
    let tab: String
    /// Optional mirror of `hidesBar` for the attaching screen's own use (BUG-27: Home keys its
    /// Menu-to-top shortcut off the same hysteresis the bar uses, so the two never disagree).
    var isScrolledDown: Binding<Bool>?

    /// T1: hysteresis arms restated in the corrected (sign-fixed) residual frame. Under the OLD
    /// mis-signed `offset.y - insets.top` formula, the literal thresholds (60 / 8) worked out to
    /// EFFECTIVE arms that were inset-dependent — the same literals meant different things
    /// depending on whether the system bar was expanded or minimized at the moment of the fire:
    ///   expanded bar (insetTop≈157): hide fired past residual>374, show fired below residual<322
    ///   minimized bar (insetTop≈76):  hide fired past residual>212, show fired below residual<160
    /// (derived by adding 2×insetTop to each old literal — the sign error's exact offset).
    /// `hideArm` = 300 sits between the two historical hide points, so it engages after roughly
    /// one row scrolled — the same felt behavior as today. `showArm` = 160 is the historical
    /// MINIMIZED-bar show point, chosen over the expanded-bar one because it is also comfortably
    /// above both the documented 59–67pt rest-short-of-top (HomeView.swift ~L794-806, BUG-30) and
    /// the pinned hero's headroom — LOAD-BEARING: if the show arm sat below that rest-short
    /// residual, `isScrolledDown` would stay latched even at the visual top, and BUG-27's
    /// Menu-to-top handler (HomeView.swift ~L559-608) would never disarm — Menu could never exit
    /// the app from Home. If a device pass finds 160 too eager, the conservative fallback pair is
    /// the expanded-bar values above (374 / 322), which reproduce today's shipped behavior
    /// byte-for-byte.
    private static let hideArm: CGFloat = 300
    private static let showArm: CGFloat = 160

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: TabBarScrollSample.self, of: { geo in
            TabBarScrollSample(offsetY: geo.contentOffset.y, insetTop: geo.contentInsets.top)
        }, action: { _, sample in
            TabBarProbe.recordScrollFire(tab: tab, offsetY: sample.offsetY, insetTop: sample.insetTop)
            let residual = sample.residual
            var crossedHysteresis = false
            if !hidesBar, residual > Self.hideArm {
                hidesBar = true
                isScrolledDown?.wrappedValue = true
                crossedHysteresis = true
            } else if hidesBar, residual < Self.showArm {
                hidesBar = false
                isScrolledDown?.wrappedValue = false
                crossedHysteresis = true
            }
            // BUG-66 evidence probe (2026-09-10): `TabBarStateProbe` samples the SYSTEM tab bar's
            // own geometry on a real hysteresis crossing, not per scroll-geometry tick (this
            // closure fires many times a second while scrolling — see `TabBarProbe`'s own doc
            // comment on why ITS readout is a counter snapshot, not a per-fire log). One call
            // site, gated by the probe's own toggle so an off probe costs nothing beyond the
            // `Bool` read.
            if crossedHysteresis, TabBarStateProbe.enabled {
                TabBarStateProbe.noteScrollState(isScrolledDown: hidesBar, mode: "system")
            }
        })
    }
}

extension View {
    /// VIS-16 (D1): retired. The FEAT-30 overlay used this to turn Menu at a tab root into a
    /// sidebar reveal; the system `.sidebarAdaptable` TabView now does that by itself, so the
    /// modifier is an identity kept only so call sites outside the navigation-shell batch keep
    /// compiling until they drop it. Do not add new call sites.
    func sidebarMenuReveal() -> some View { self }

    /// Attach to a tab root's main (vertical) `ScrollView` so its position drives the floating tab
    /// bar's scroll-driven auto-hide. Screens that don't meaningfully scroll (Settings, Profile)
    /// should not attach this. `tab` names the tab root for the BUG-30/66/62 diagnostics readout
    /// (e.g. "Home", "Search"). Pass `isScrolledDown` to also receive the same hysteresis-filtered
    /// signal locally (crossings only, never per scroll tick).
    func reportsScrollToTabBar(tab: String, isScrolledDown: Binding<Bool>? = nil) -> some View {
        modifier(TabBarScrollAutoHide(tab: tab, isScrolledDown: isScrolledDown))
    }
}

/// BUG-30/66/62 (beta.14): release-safe diagnostics for the tvOS 26 system tab bar's scroll-edge
/// state. Same house pattern as `HomeHeroProbe` (deliberately not `#if DEBUG` — this bar has only
/// ever been seen stuck on a device pass, never in sim) but the readout is a live counter
/// snapshot rather than an event log: `.onScrollGeometryChange` can fire many times a second while
/// scrolling, and a line per fire would spam both the console and whatever ring buffer held it.
/// Everything here is in-memory only for the running process — the BUG-30/66 protocol (walk Home
/// down/up, then run Detail push/pop cycles, then check Settings → About) never spans a
/// relaunch — so nothing here touches UserDefaults or feeds back into the bar's own state.
@MainActor
enum TabBarProbe {
    /// Live read, not the other probes' latched `static let`: those pair with a relaunch-based
    /// capture protocol, while this toggle must take effect in the same session it is flipped in.
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug.tabBarProbe") }

    /// Stable display order for the About pane — dictionary iteration order isn't.
    static let tabNames = ["Home", "Search", "Library", "Add-ons"]

    struct ScrollState {
        var fireCount = 0
        var lastFireMs = 0
        /// T1: `y`/`i` kept separate (not just the combined residual) so the About-pane readout
        /// can show all three — a tester's photo of `y=… i=… r=…` is what lets a device pass
        /// distinguish "the bar never fired" from "it fired but the residual math is wrong".
        var lastOffsetY: CGFloat = 0
        var lastInsetTop: CGFloat = 0
        var lastResidual: CGFloat = 0
    }

    private(set) static var scrollStates: [String: ScrollState] = [:]
    /// Counts full push→pop round trips (depth back to 0), not raw push/pop calls — the BUG-30/66
    /// hypothesis is stated in terms of "N push/pop cycles", not a raw event tally.
    private(set) static var pushPopCycles = 0

    static func recordScrollFire(tab: String, offsetY: CGFloat, insetTop: CGFloat) {
        guard enabled else { return }
        var state = scrollStates[tab, default: ScrollState()]
        state.fireCount += 1
        state.lastFireMs = HomeHeroProbe.sinceLaunchMs
        state.lastOffsetY = offsetY
        state.lastInsetTop = insetTop
        state.lastResidual = offsetY + insetTop
        scrollStates[tab] = state
    }

    static func recordPop(depthAfter: Int) {
        guard enabled, depthAfter == 0 else { return }
        pushPopCycles += 1
    }
}
