import Combine
import QuartzCore
import SwiftUI
import SharedCore

/// BUG-41 (beta.18): pure timing math behind `ScrollDimModel.isScrolling` — deliberately split out
/// of the model so the debounce/hysteresis arithmetic can be exercised in
/// `DetailScrollProbeTests` with fabricated timestamps instead of a real `Task.sleep`/clock.
/// `now`/`lastChange` are any monotonic seconds source; `ScrollDimModel` below feeds it
/// `CACurrentMediaTime()`, matching `HitchCounter`'s `CADisplayLink` timestamps elsewhere in this
/// file.
enum ScrollingLatch {
    /// The ask: "cleared after ~150ms of no further scroll-geometry change."
    nonisolated static let defaultIdle: TimeInterval = 0.15

    /// True while `now` is still inside `idle` seconds of the last recorded change — i.e. a clear
    /// timer armed at `lastChange + idle` has not fired yet. A brand-new change (`now ==
    /// lastChange`) is always scrolling; a change exactly (or more than) `idle` seconds old is
    /// idle — closed lower bound, open upper bound, so a change that lands exactly on the boundary
    /// counts as idle rather than re-arming forever.
    ///
    /// `nonisolated` (matching `DetailScrollProbe.enabled`/`DetailScrollAB.leg` elsewhere in this
    /// file): a pure function of its arguments with no actor-isolated state to protect, so it can
    /// be called from any isolation domain — including `DetailScrollProbeTests`, synchronously,
    /// with no `await`/`@MainActor` ceremony.
    nonisolated static func isScrolling(now: TimeInterval, lastChange: TimeInterval, idle: TimeInterval = defaultIdle) -> Bool {
        now - lastChange < idle
    }
}

/// BUG-41: isolates UX-6's scroll-driven dim value from `DetailView`'s own `@State` so writing it
/// every scroll-geometry frame doesn't invalidate (and re-evaluate) the entire detail page body —
/// see `DetailView.dimModel` and `ScrollDimOverlay` below, its sole observer.
private final class ScrollDimModel: ObservableObject {
    @Published var value: Double = 0

    /// BUG-41 (beta.18): debounced "the user is actively scrolling right now" flag — true the
    /// instant a scroll-geometry change is observed, false again ~150ms after the last one
    /// (`ScrollingLatch.defaultIdle`). Lives here, not a plain `@State` on `DetailView`, for the
    /// same reason `value` does: writing it every scroll frame must invalidate only the small
    /// views that actually read it (the chip glass/flat swap — see `DetailView.chipGlassFlat`),
    /// not the whole `DetailView.body`.
    @Published var isScrolling: Bool = false
    /// BUG-96 diagnostic: the last anchor decision (`row=… h=… vh=… k=…`), surfaced on the
    /// `debug_ux6` probe so a UI leg can read it off the accessibility tree (the tvOS 27 runtime
    /// never reports focus, and simulator NSLog lines do not reach the host's unified log here).
    @Published var anchorNote: String = "-"
    /// BUG-96 diagnostic: live scroll geometry (`off= inset= vis= content=`), probe-gated.
    @Published var scrollGeoNote: String = "-"
    /// BUG-96: live scroll geometry for the anchor — plain fields, NOT published: they are written
    /// on every scroll frame and must not invalidate anything (the BUG-41 rule).
    var contentInsetTop: CGFloat = 0
    var lastContentOffset: CGFloat = 0
    /// BUG-96 diagnostic sample (plain field); published into `scrollGeoNote` by the anchor pass.
    var geometrySample: String = "-"
    /// BUG-96 blend: armed with the just-focused row the instant `focusedRow` changes, and the
    /// content offset captured at that moment — disarmed (`nil`) the first time the scroll-geometry
    /// handler sees the engine's own reveal actually move the page, which is also the instant the
    /// anchor pass fires. Plain fields, not published: read/written on the per-frame geometry path.
    /// BUG-99: only ever armed on an UP focus change now — a Down change leaves this `nil`, so the
    /// blend trigger in the scroll-geometry handler below is inert for the whole visit; Down has
    /// its own settle-check task instead (see `DetailView.onChange(of: focusedRow)`).
    var awaitingRevealRow: DetailRowID?
    var awaitingRevealStartOffset: CGFloat = 0
    /// BUG-96 oracle: timestamped content-offset samples for the current focus visit, capped at
    /// ~600 and reset on every `focusedRow` change — feeds `DetailScrollMotion.segments` for the
    /// `moves=` count appended to `geometrySample`. Timestamped (not just the raw offset) because
    /// `onScrollGeometryChange` delivers CHANGES only — a genuine pause between motions can produce
    /// no samples at all, so the split has to be time-based, not a run of stationary samples (see
    /// `DetailScrollMotion`). Plain field for the same reason as `geometrySample` itself; only ever
    /// grown when `DetailScrollProbe.enabled`.
    var motionSamples: [MotionSample] = []

    /// `CACurrentMediaTime()` at the last `noteScrollChange` call — what `ScrollingLatch` measures
    /// the debounce window against.
    private var lastChangeTime: TimeInterval = 0
    /// The pending "flip back to false" timer. Cancelled and replaced on every new change so a
    /// change inside the 150ms window extends the latch instead of racing a stale clear.
    private var clearTask: Task<Void, Never>?

    /// Called from `DetailView`'s scroll-geometry tracking on every offset change (item 1/3 of the
    /// BUG-41 beta.18 fix). Marks scrolling active immediately and (re)arms a clear after `idle`
    /// seconds.
    func noteScrollChange(idle: TimeInterval = ScrollingLatch.defaultIdle) {
        let now = CACurrentMediaTime()
        lastChangeTime = now
        if !isScrolling { isScrolling = true }
        // One clear task per scroll, not one per frame: `onScrollGeometryChange` fires on every
        // frame the page moves, and cancelling + recreating a Task 60 times a second is exactly the
        // per-frame allocation this fix exists to remove. The task re-checks the latch on every
        // wake and retires itself only once the page has genuinely gone idle.
        guard clearTask == nil else { return }
        clearTask = Task { [weak self] in
            var sleepFor = idle
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(sleepFor, 0.005) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let done: Bool = await MainActor.run {
                    guard let self else { return true }
                    let now = CACurrentMediaTime()
                    if ScrollingLatch.isScrolling(now: now, lastChange: self.lastChangeTime, idle: idle) {
                        // Codex beta.18 r3 (P2): sleep only for what is LEFT of the window measured
                        // from the newest change, so the flag clears ~150 ms after the last frame
                        // moved rather than up to a full extra interval later.
                        sleepFor = idle - (now - self.lastChangeTime)
                        return false
                    }
                    self.isScrolling = false
                    self.clearTask = nil
                    return true
                }
                if done { return }
            }
        }
    }

    /// `DetailView.onDisappear` — cancels any pending clear so the `Task` doesn't outlive the view
    /// (harmless either way, since nothing reads `isScrolling` once the view is gone, but tidy and
    /// stops the closure retaining `self` past the visit for no reason).
    func cancelScrollLatch() {
        clearTask?.cancel()
        clearTask = nil
        // Codex beta.18 r1 (P2): the @StateObject survives a push/cover, so a page that disappears
        // inside the 150 ms window (opening the full-screen trailer, navigating away) must not come
        // back with the chips stuck flat — clear the flag with the only task that would have.
        if isScrolling { isScrolling = false }
    }
}

/// The UX-6 dim overlay + its DEBUG diagnostic Text, as `ScrollDimModel`'s only observer (BUG-41).
/// Kept as a standalone child view so SwiftUI only re-renders THIS small view when `model.value`
/// changes, instead of the whole `DetailView.body` the way writing a `@State` on DetailView did.
/// Honesty note (2026-08-05 sim measurement): the @State variant did NOT measurably re-eval body
/// per scroll frame on the sim's D-pad walk — this isolation is invalidation hygiene, not a
/// confirmed fix for BUG-41's reported choppiness, which needs a real-swipe device before/after
/// (the `[BUG41]` probe below is there for exactly that).
/// BUG-96 (beta.18): the fixed top scrim above the anchored row — see `DetailRowAnchor.topScrimHeight`.
/// Observes the dim model itself so `DetailView.body` keeps not re-rendering per dim step (BUG-41).
private struct DetailTopScrim: View {
    @ObservedObject var model: ScrollDimModel

    var body: some View {
        LinearGradient(colors: [Color.black.opacity(0.96), Color.black.opacity(0.6), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: DetailRowAnchor.topScrimHeight)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .opacity(model.value > 0.001 ? 1 : 0)
            .animation(.linear(duration: 0.12), value: model.value > 0.001)
    }
}

private struct ScrollDimOverlay: View {
    @ObservedObject var model: ScrollDimModel
    /// BUG-41: whether the live `AVPlayerLayer` hero trailer is currently mounted underneath this
    /// overlay (`DetailView.trailerLayerVisible`). While it is, the trailer itself is already
    /// re-rendering every frame, so `.animation`'s Core-Animation-server interpolation between the
    /// 0.05 dim steps is pure extra resampling work over a surface that's changing anyway — skip it
    /// and step flat. Once the trailer is gone (scrolled past, or never resolved for this title),
    /// the dim is the only thing moving on screen again, so the smoothing earns its keep back.
    let trailerActive: Bool
    /// BUG-41 diagnostic (item 6): whether the top-block chips are rendering flat material instead
    /// of `.glassEffect` right now (`DetailScrollAB.glassDisabled` OR a live trailer, mirroring
    /// `detailChipBackground`'s own condition) — folded into `debug_ux6` alongside `trailer=`/`ab=`
    /// so a UI test can read all four BUG-41 A/B signals off one accessibility node.
    let glassFlat: Bool
    /// The FEAT-32 trailer cover composes its own copy of this overlay; that copy must not carry
    /// the `debug_ux6` probe, or the page has two matching elements while the cover is up
    /// (test17 "Multiple matching elements found").
    var showsProbe: Bool = true

    var body: some View {
        ZStack {
            // UX-6: darkens the whole backdrop/poster/trailer stack (trailer keeps playing
            // underneath) as the description scrolls down — the scrim above stays untouched.
            // P-2c: `.animation` interpolates between the (now coarser, 0.05-step) quantized
            // values in Core Animation's render server rather than SwiftUI stepping the opacity
            // directly — see the quantization comment on `DetailView`'s `.onScrollGeometryChange`
            // for the full 0.01→0.05 reasoning this pairs with. BUG-41: that smoothing is skipped
            // (nil animation = a flat step) while a trailer is actively mounted — see `trailerActive`.
            Color.black.opacity(model.value).ignoresSafeArea().allowsHitTesting(false)
                .animation(trailerActive ? nil : .linear(duration: 0.12), value: model.value)
            #if DEBUG
            // UX-6/BUG-41 diagnostic (invisible, harness-readable): the live darkening value plus
            // the three A/B signals a UITest needs to attribute choppiness — append-only, `dark=`
            // stays first so pre-existing reads of this token keep working. `scrolling=` (beta.18,
            // BUG-41 item 3) is the newest token, appended last for the same reason.
            if showsProbe {
            Text("debug_ux6 dark=\(Int(model.value * 1000)) trailer=\(trailerActive ? 1 : 0) glass=\(glassFlat ? 1 : 0) ab=\(DetailScrollAB.leg) scrolling=\(model.isScrolling ? 1 : 0) anchor=\(model.anchorNote) geo=\(model.scrollGeoNote)")
                .font(.system(size: 8))
                .opacity(0.011)
                .accessibilityIdentifier("debug_ux6")
            }
            #endif
        }
    }
}

/// Runtime knob for DetailView's scroll-diagnostic probes (the BUG-41 body-eval counter and the
/// UX-6 raw scroll-offset log), following the exact house pattern of `HomeGeometryProbe`
/// (`BrowseComponents.swift:76-78`) and `TrailerProbe` (`TrailerDebugProbes.swift:25-26`):
///
///     defaults write com.nuvio.media.NuvioTV debug.detailScrollProbe -bool YES
///
/// Deliberately NOT `#if DEBUG` — house rule recorded on `TrailerProbe`'s doc comment: testers run
/// release sideloads, there is no automated input path to the physical Apple TV, and the console
/// (`log show`) is the only diagnostic that comes back from a device pass. A probe gated behind
/// `#if DEBUG` never runs on the builds that actually reproduce BUG-41.
enum DetailScrollProbe {
    /// BUG-41: a LIVE read (not launch-latched) so the About > Trailer Diagnostics pane's toggle for
    /// this key (F-C's picker) can flip probing on/off without a relaunch — matches
    /// `DetailScrollAB.leg` below.
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug.detailScrollProbe") }
}

/// BUG-41 item 6: a device-side hitch counter for one Detail visit, armed only while
/// `DetailScrollProbe.enabled`. `CADisplayLink` fires on every vsync (~60 Hz on Apple TV); any gap
/// over 25ms between consecutive ticks (roughly 1.5 frames) is counted as a hitch. Summarized once,
/// on `DetailView`'s `.onDisappear`, rather than logged per-frame — an NSLog on every vsync would
/// itself be exactly the kind of main-thread work this probe exists to detect.
private final class HitchCounter: NSObject, ObservableObject {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var hitchCount = 0
    private var frameCount = 0
    private var maxGapMs: Double = 0

    func start() {
        guard DetailScrollProbe.enabled, displayLink == nil else { return }
        hitchCount = 0
        frameCount = 0
        maxGapMs = 0
        lastTimestamp = nil
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopAndLog() {
        guard displayLink != nil else { return }
        displayLink?.invalidate()
        displayLink = nil
        NSLog("[BUG41] hitches=%d frames=%d maxGap=%.1fms", hitchCount, frameCount, maxGapMs)
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameCount += 1
        if let last = lastTimestamp {
            let gapMs = (link.timestamp - last) * 1000
            if gapMs > 25 { hitchCount += 1 }
            if gapMs > maxGapMs { maxGapMs = gapMs }
        }
        lastTimestamp = link.timestamp
    }

    deinit { displayLink?.invalidate() }
}

/// `debug.detailScrollAB` (Int, LIVE read — not launch-latched, so About's picker, F-C's, can flip
/// legs without a relaunch): a five-leg on-device A/B knob that settles BUG-41's attribution
/// question — is the reported scroll choppiness the UX-6 dim overlay, the Liquid Glass chips in the
/// top block, the action-row button styles/container, or some combination — that the simulator has
/// never been able to answer on its own (BUG-41 history: sim never reproduced the choppiness). One
/// build, five device legs:
///
///     defaults write com.nuvio.media.NuvioTV debug.detailScrollAB -int 1
///
///   - 0: shipping behavior (dim + glass), the default.
///   - 1: dim disabled — the `.onScrollGeometryChange` `of:` closure that feeds `dimModel` always
///     returns 0, so the UX-6 overlay never darkens past its first frame.
///   - 2: glass off in the top block — `metaChip` and the parental-guide chips fall back to a
///     plain translucent capsule fill instead of `.glassEffect`. `actionRow`'s
///     `.glass`/`.glassProminent` BUTTON styles are left alone — button styles are a different
///     swap from the chip backgrounds this leg targets.
///   - 3: both 1 and 2.
///   - 4: leg 3, plus `actionRow`'s buttons swap `.glass`/`.glassProminent` for
///     `.bordered`/`.borderedProminent` and its `GlassEffectContainer` becomes a plain `HStack` —
///     the one piece of glass legs 2/3 deliberately left alone.
enum DetailScrollAB {
    nonisolated static var leg: Int { UserDefaults.standard.integer(forKey: "debug.detailScrollAB") }
    nonisolated static var dimDisabled: Bool { leg == 1 || leg == 3 || leg == 4 }
    nonisolated static var glassDisabled: Bool { leg == 2 || leg == 3 || leg == 4 }
    /// Leg 4 only — see the doc list above.
    nonisolated static var buttonGlassDisabled: Bool { leg == 4 }
}

/// Full detail screen for a single title, fed by the shared `MetaDetailsRepository`.
/// Constructed from a `MetaPreview` (the card the user focused), then enriched in place as the
/// repository resolves full metadata.
struct DetailView: View {
    let preview: MetaPreview

    /// Not `@EnvironmentObject`: DetailView can be reached outside the tab shell entirely (a Top
    /// Shelf deep link presents it inside `DeepLinkTitleView`'s own standalone `NavigationStack`,
    /// with no tab bar at all), where an `@EnvironmentObject` would crash for want of an ancestor
    /// that injected one. The custom environment key falls back to a harmless, unconnected default
    /// instance in that case — `pushImmersive`/`popImmersive` still balance correctly, they just
    /// don't affect anything since there's no tab bar to hide.
    @Environment(\.tabBarVisibility) private var tabBarVisibility

    @StateObject private var model: DetailViewModel
    @State private var showStreams = false
    @State private var seriesPlay: SeriesPlayRoute?
    /// Trakt comment ids the user has expanded (reveals spoilers / full text).
    @State private var expandedComments: Set<Int64> = []

    /// Tester ask: auto full-screen the hero trailer a few seconds after opening a title.
    /// F2 / decision D5: opt-in only. The default autoplay is the muted in-place background
    /// trailer (`detail_trailer_background`); the page never goes full screen unless the user
    /// turned this on, and any focus move or Reduce Motion cancels it. AppearanceSettingsPane
    /// reads the same key and must use the same `false` default.
    @AppStorage("detail_trailer_autoplay") private var trailerAutoplayEnabled: Bool = false
    /// Tester ask: keep the poster visible on the right, backdrop-style, behind the description.
    @AppStorage("detail_poster_backdrop") private var posterBackdropEnabled: Bool = true
    /// UX-4b (tester ask): the muted trailer looping behind the description previously had no
    /// switch at all — only auto-play did. Off = detail pages stay on the still artwork; the
    /// explicit "Watch Trailer" button and auto-play (if enabled) still work.
    @AppStorage("detail_trailer_background") private var backgroundTrailerEnabled: Bool = true
    /// FEAT-8: how long the muted background trailer plays before fading back to the still
    /// backdrop. 0 = play forever (previous, still-default behavior). Mirrors
    /// AppearanceSettingsPane's "Trailer Duration" chip row (same @AppStorage key).
    @AppStorage("detail_trailer_duration") private var trailerDurationSeconds: Int = 0
    /// FEAT-9: render the five detail action buttons (Play, Watch Trailer, Mark Watched, Add to
    /// Library) as icon-only pills. Mirrors AppearanceSettingsPane's "Icon-Only Detail Buttons"
    /// toggle (same @AppStorage key).
    @AppStorage("detail_action_icons_only") private var actionIconsOnly = false
    /// FEAT-11: whether a full-screen trailer should start with sound instead of muted. Mirrors
    /// PlaybackSettingsPane's "Trailer Sound by Default" toggle (same @AppStorage key) — read here
    /// only to restore the shared `HeroTrailerAudioState` back to this default once a full-screen
    /// trailer is dismissed (see the `.fullScreenCover(item: $model.trailerPlayback` below).
    @AppStorage("trailer_audio_default_on") private var trailerAudioDefaultOn = false

    /// FEAT-8: true once `trailerDurationSeconds` has elapsed for the current background trailer —
    /// fades the background player back out to the still backdrop without ever touching
    /// `model.trailerVideoURL` (that still gates the "Watch Trailer" button). Reset per detail visit.
    @State private var backgroundTrailerStopped = false
    @State private var trailerDurationTask: Task<Void, Never>?

    /// UX-6: 0...0.85 darkening applied over the whole backdrop/poster/trailer stack as the user
    /// scrolls the description down, computed once inside `.onScrollGeometryChange`'s `of:` so it
    /// stops firing once fully saturated. BUG-41: lives in `ScrollDimModel` (a tiny
    /// `ObservableObject`), not a plain `@State` on `DetailView` — see that type's doc comment for
    /// why the indirection matters for scroll smoothness.
    @StateObject private var dimModel = ScrollDimModel()

    /// BUG-41: hysteresis latch on `dimModel.value` — true once it reaches 0.80, false again once
    /// it drops below 0.55 (scrolling back up). Gates the hero-trailer `AVPlayerLayer` mount at
    /// `trailerLayerVisible` below: at 0.80 of a ramp that saturates at 0.85 the trailer is
    /// effectively invisible, so tearing it down stops it (and the glass chips re-sampling it) from
    /// doing real GPU work for nothing; the reveal gate already handles the "no restart glitch on
    /// remount" problem this reintroduces (`TrailerHeroPlayer`'s own attach/reveal machinery).
    ///
    /// Codex r3 (P2): the thresholds were 0.5 / 0.3. That dismounted a MOVING trailer and swapped
    /// in the static backdrop while the scrim was only ~59% of the way to its ceiling, so the swap
    /// was plainly visible, and remounting at 0.3 restarted it just as visibly. The BUG-41 saving
    /// was never "stop at half dim", it was "stop once nobody can see it", which 0.80 delivers with
    /// the same GPU relief. 0.80 and 0.55 are 5 quantization steps apart (the ramp is quantized to
    /// 0.05), comfortably past the 4-step minimum, so a scroll parked on the boundary cannot flap.
    /// A gap between the two thresholds (not one shared value) is what avoids that flapping, and it
    /// is deliberately NOT derived inline from `dimModel.value` on every read, which would
    /// re-evaluate `body` on every 0.05 step instead of only the two times this actually flips.
    @State private var trailerDimmedOut = false

    /// BUG-41 item 6 device diagnostic — see `HitchCounter`'s doc comment.
    @StateObject private var hitchCounter = HitchCounter()

    /// One-shot per detail visit — never re-fires after the auto-played trailer is dismissed.
    @State private var didAutoPlayTrailer = false
    /// Set the moment the user swipes/moves focus at all (see `onMoveCommand` below); cancels the
    /// pending auto-play so it never yanks focus away from someone who's already exploring the page.
    @State private var userInteracted = false
    @State private var autoPlayTrailerTask: Task<Void, Never>?
    /// True only while the CURRENT `trailerPlayback` presentation was kicked off by the auto-play
    /// timer (not the explicit "Watch Trailer" button or a "Trailers & Extras" row item) — gates the
    /// "Press Back to exit" hint so it only shows for the surprise entry, not a deliberate tap.
    @State private var trailerPlaybackIsAutoPlay = false
    /// FEAT-32: the bridge between this page and the full-screen trailer (see `TrailerBridge.swift`).
    /// `model.trailerPlayback` is the REQUEST (set by Watch Trailer, auto-play and the extras row,
    /// and what the rest of this view gates on); `presentedTrailer` is what the cover shows, and it
    /// is set only once the leaving choreography has run. Tearing the two apart is the whole change:
    /// nothing else about the request path moved.
    @State private var bridgePhase: TrailerBridgePhase = .idle
    @State private var presentedTrailer: TrailerPlaybackItem?
    @State private var bridgeTask: Task<Void, Never>?
    /// True from the moment the cover is handed an item until its `onDismiss`. Decides who settles
    /// the return: `onDismiss` when a cover was up (so the enlarged still is what its dismissal
    /// reveals), the request's own withdrawal otherwise.
    @State private var bridgeCoverPresented = false
    /// `debug_bridge` probe: every phase the bridge passed through this visit, e.g.
    /// `idle>leaving>playing>returning>idle`. test51 reads it after the settle.
    @State private var bridgeTrace = TrailerBridgePhase.idle.label
    /// Which cast card holds focus — feeds `cardFocusButtonStyle(stillFocused:)`'s generic
    /// still ring in no-zoom mode (CastCard has no border treatment of its own; Codex
    /// 2026-08-29 rounds 3-4).
    @FocusState private var focusedCastIndex: Int?
    /// BUG-111: which company/studio chip holds focus — mirrors `focusedCastIndex` exactly.
    /// `CompanyChip` has no border treatment of its own either, so it reads this same row-owned
    /// `FocusState` for its `stillFocused`/ring/lift truth instead of installing a second
    /// `.focused` binding of its own (the same collision `focusedFolderId` avoids — see
    /// `cardFocusButtonStyle`'s doc comment).
    @FocusState private var focusedCompanyIndex: Int?
    /// BUG-108: read here only to order the focused cast avatar above its neighbours — see
    /// `liftedCastZIndex`. The avatar's own treatments read the same keys inside `CastCard`.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    @AppStorage("accent_focus_ring") private var accentFocusRing = false

    /// BUG-108: ring mode's lift is SwiftUI's own scale, so the raised avatar's platter+shadow can
    /// draw under its unfocused neighbours. On the `LazyHStack`'s child, not inside the label.
    private func liftedCastZIndex(_ index: Int) -> Double {
        let raises = CardFocusMode.resolve(accentFocusRing: accentFocusRing,
                                           noZoomOnFocus: noZoomOnFocus).raisesFocusedCard
        return raises && focusedCastIndex == index ? 1 : 0
    }
    /// BUG-111: `liftedCastZIndex`'s twin for the company/studio row.
    private func liftedCompanyZIndex(_ index: Int) -> Double {
        let raises = CardFocusMode.resolve(accentFocusRing: accentFocusRing,
                                           noZoomOnFocus: noZoomOnFocus).raisesFocusedCard
        return raises && focusedCompanyIndex == index ? 1 : 0
    }
    /// BUG-96 (beta.18): which detail row focus is inside, if any — see `DetailRowAnchor`.
    /// Codex P2 review finding (BUG-99 follow-up, round 2): `.comments` is now a TRACKED row
    /// (`commentsSection` carries `.detailRowAnchored(.comments, …)` below) like every other row
    /// past the top block, so this reports `.comments` — never nil — while focus is inside it. A
    /// round-1 fix added a separate `lastKnownRow` state field to tell "focus is nil because it's
    /// in the top block" apart from "focus is nil because it's in Comments"; tracking Comments here
    /// retires that field entirely — `onChange(of: focusedRow)`'s own `old` parameter is already
    /// the row that lost focus, real or nil, with no separate bookkeeping needed.
    @FocusState private var focusedRow: DetailRowID?
    /// BUG-96 (Codex r1 P2): the anchor scroll is not animated under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The round action buttons' glyph frame, scaled with Larger Text so the symbol never
    /// outgrows a fixed 44pt square at accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var roundActionIconSide: CGFloat = 44
    /// BUG-96: each row's top in the scroll content's coordinate space (layout-only changes).
    @State private var detailRowOffsets: [DetailRowID: CGFloat] = [:]
    /// BUG-96: the vertical scroll view's position, driven the way Home's corrector drives its rows.
    @State private var detailScrollPosition = ScrollPosition()
    /// BUG-96: the pending anchor move; a newer focus change cancels the previous one.
    @State private var detailAnchorTask: Task<Void, Never>?
    /// BUG-96: which row the last anchor pass rested, and where. A later layout change that moves
    /// the focused row (cast photos landing, a parental-guide row inserting above) shifts that
    /// row's top away from here, and the focus engine re-reveals the moved card;
    /// `.onChange(of: detailRowOffsets)` re-anchors once on that signal — a layout-settled
    /// trigger, never a polling loop. Codex P2 review finding (BUG-99 follow-up): ownership is now
    /// per ROW, not just a top — the old bare `CGFloat?` compared the new focused row's top against
    /// whatever the PREVIOUS row's anchor pass had left here, so a relayout within 350 ms of a
    /// focus change could anchor a row that was deliberately left `.free`. Cleared at the top of
    /// `.onChange(of: focusedRow)` on every change; set only by `anchorPass`, for the row it
    /// anchored. The relayout pass below only fires when `lastAnchored?.row == focusedRow`.
    @State private var lastAnchored: (row: DetailRowID, top: CGFloat)?

    /// F1: which action-row button holds focus. Drives `.defaultFocus(.play)` (the primary button
    /// takes focus when the page opens, so a cold Select never lands on Mark Watched) and F2's
    /// "any focus move cancels the pending trailer autoplay".
    @FocusState private var focusedAction: DetailActionFocus?
    /// F1: a series-level Mark Watched / Unmark asks first (it marks or clears every episode).
    @State private var confirmingSeriesWatched = false
    /// F1: Play stays focusable when no source can stream the title; a press explains why.
    @State private var showingPlaybackUnavailable = false

    init(preview: MetaPreview) {
        self.preview = preview
        _model = StateObject(wrappedValue: DetailViewModel(preview: preview))
    }

    /// BUG-41 measurement probe: counts `DetailView.body` evaluations so the main session can
    /// compare before/after this fix. Logs every 10th eval (not every single one) to stay cheap
    /// while still grep-able: `log show --predicate 'eventMessage contains "BUG41"'`. Gated by
    /// `DetailScrollProbe.enabled` rather than `#if DEBUG` — see that enum's doc comment: testers
    /// run release sideloads, so a compile-time gate would stop measuring on exactly the builds
    /// that reproduce the reported choppiness.
    static var bodyEvalCount = 0
    static func logBodyEval() {
        guard DetailScrollProbe.enabled else { return }
        bodyEvalCount += 1
        if bodyEvalCount % 10 == 0 {
            NSLog("[BUG41] detailBodyEval=%d", bodyEvalCount)
        }
    }

    var body: some View {
        // BUG-41 measurement probe, gated at runtime by `DetailScrollProbe.enabled` (see above).
        let _ = Self.logBodyEval()
        ZStack(alignment: .topLeading) {
            backdropImage
                // FEAT-32: the still lands enlarged when the trailer cover goes and settles to 1.
                .scaleEffect(TrailerBridgeChoreography.backdropScale(bridgePhase))
                .animation(TrailerBridgeChoreography.backdropAnimation(to: bridgePhase), value: bridgePhase)
            if showPosterBackdrop {
                posterBackdropLayer
                    .transition(.opacity)
            }
            // Tear the trailer's libmpv instance down while the stream player (also libmpv) is open,
            // so two GPU/Vulkan contexts never render at once; it resumes when the player dismisses.
            // Also pause it while a full-screen trailer plays (no doubled decode/audio). BUG-41: also
            // torn down once `trailerDimmedOut` — it's fully hidden under the UX-6 scrim by then, so
            // there's no visible loss, only GPU/decode work saved (and one fewer surface for the
            // glass chips above to re-sample every frame).
            if trailerLayerVisible, let trailer = model.trailerVideoURL {
                // UX-9: the zoom that hides the letterbox bars baked into our YouTube encodes is
                // measured per stream and applied to the player layer itself now
                // (`TrailerLetterboxProbe`, floor `TrailerHeroPlayer.parityZoom`) — no
                // `.scaleEffect` here any more. Full-screen and already ignoring the safe area, so
                // the overscale just pushes the bars past the screen edges — the screen bounds
                // themselves do the clipping. The failure report is ignored: Detail has one hero
                // trailer and no negative cache to scope (that's the inline card's problem).
                TrailerHeroPlayer(urlString: trailer, onFailure: { _ in model.trailerFailed() },
                                  zoomKey: model.trailerZoomKey, videoId: model.trailerVideoId)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            scrimOverlay(posterBackdropVisible: showPosterBackdrop)
            // UX-6/BUG-41: the dim overlay + its debug Text live in `ScrollDimOverlay`, the sole
            // observer of `dimModel` — see that type's doc comment for why.
            ScrollDimOverlay(model: dimModel, trailerActive: trailerLayerVisible, glassFlat: chipGlassFlat)
            // FEAT-32: the hero dims to black under the fading chrome before the cover presents, so
            // the trailer cuts in from black. Cleared with no animation on return (hard cut to the
            // still, as in Nuvio), the settle above does the rest.
            Color.black
                .opacity(TrailerBridgeChoreography.blackout(bridgePhase))
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(TrailerBridgeChoreography.blackoutAnimation(to: bridgePhase), value: bridgePhase)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg + Theme.Spacing.sm) {
                    topBlock
                    // Grouped to stay under ViewBuilder's 10-subview ceiling. BUG-96: every row
                    // below the top block is anchored — see `DetailRowAnchor`.
                    Group {
                        companyLogosRow
                            .detailRowAnchored(.logos, focusedRow: $focusedRow, offsets: $detailRowOffsets)
                        parentalGuideSection
                            .detailRowAnchored(.parental, focusedRow: $focusedRow, offsets: $detailRowOffsets)
                    }
                    if let meta = model.meta, EpisodesSection.isSeriesLike(meta) {
                        EpisodesSection(
                            meta: meta,
                            episodeRatings: model.episodeRatings,
                            watchedEpisodeKeys: model.watchedEpisodeKeys,
                            episodeProgress: model.episodeProgress,
                            preferredSeason: model.seriesAction?.seasonNumber?.value,
                            preferredEpisode: model.seriesAction?.episodeNumber?.value,
                            episodeRatingsVisibility: model.episodeRatingsVisibility,
                            showOverallRatings: model.showOverallRatings,
                            onToggleWatched: { model.toggleEpisodeWatched($0) }
                        )
                        // A discrete focus region: vertical D-pad moves must land here instead of
                        // geometrically skipping from the info/network chips down to the cast row.
                        .focusSection()
                        .detailRowAnchored(.episodes, focusedRow: $focusedRow, offsets: $detailRowOffsets)
                    }
                    Group {
                        castRow
                            .detailRowAnchored(.cast, focusedRow: $focusedRow, offsets: $detailRowOffsets)
                        collectionRow
                            .detailRowAnchored(.collection, focusedRow: $focusedRow, offsets: $detailRowOffsets)
                        trailersRow
                            .detailRowAnchored(.trailers, focusedRow: $focusedRow, offsets: $detailRowOffsets)
                        moreLikeThisRow
                            .detailRowAnchored(.moreLikeThis, focusedRow: $focusedRow, offsets: $detailRowOffsets)
                        // Codex P2 review finding (BUG-99 follow-up, round 2): TRACKED but never
                        // ANCHORED. Round-1 left this section out of `detailRowAnchored` entirely —
                        // "a vertical list of expandable cards whose focus moves never change
                        // `focusedRow`" — which was true only because nothing here reported focus
                        // in the first place; that left `focusedRow` nil both here and in the top
                        // block, indistinguishable to `DetailRowAnchor.direction`. Tracking this
                        // section resolves that ambiguity structurally (see `DetailRowID`'s and
                        // `direction`'s doc comments); it still must never anchor — a pending
                        // correction could scroll back to the section top under a later comment —
                        // so `DetailView.onChange(of: focusedRow)` bails out for `row == .comments`
                        // before any anchor decision runs.
                        commentsSection
                            .detailRowAnchored(.comments, focusedRow: $focusedRow, offsets: $detailRowOffsets)
                    }
                    // VIS-08: the facts grid closes the page, below every focusable row.
                    infoSection
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: DetailRowAnchor.contentSpace)
            }
            .scrollPosition($detailScrollPosition)
            // BUG-96: fades whatever of the previous row sits above the anchored rest.
            .overlay(alignment: .top) { DetailTopScrim(model: dimModel) }
            // BUG-96/BUG-99: a focus change is decided by DIRECTION first — see
            // `DetailRowAnchor.Direction`/`decision` and that type's doc comment for the tester
            // reports behind the split. UP always anchors the focused row's top at
            // `DetailRowAnchor.topInset`, exactly as every row did before BUG-99: rc5
            // (u/mrStevenx3) reported the first shipped design waited for the engine's own reveal
            // to FINISH, then slid the row to rest — a visible two-step move on every press. The
            // fix BLENDS: arm a flag here, remember the offset the page is at right now, and let
            // the scroll-geometry handler below fire the anchor pass the instant it sees the
            // engine actually start moving the page, so the two read as one motion, with a short
            // fallback timer for the case where the engine never moves the page at all (the
            // focused card was already fully visible).
            //
            // DOWN does not blend or anchor by default any more (rc6, BUG-99): once the blend fix
            // made one Down press one motion, the row still rested at the anchor every time, which
            // pushed the title, synopsis, buttons and meta fully off screen on the very FIRST Down
            // off the header — official Nuvio's Down instead reveals the next section at the
            // BOTTOM of the screen, description still visible (the engine's own minimal reveal).
            // Christian's call 2026-09-08: keep that minimal reveal on Down, and only pull the row
            // up to `screenRest` when it would otherwise leave the header straddling the top scrim
            // — the ORIGINAL BUG-96 photo, not the two-step motion the blend fix already solved.
            .onChange(of: focusedRow) { old, row in
                dimModel.motionSamples.removeAll(keepingCapacity: true)
                // Codex P2 review finding (BUG-99 follow-up): ownership of the last anchor pass is
                // cleared on EVERY focus change, whichever direction it turns out to be — a stale
                // `lastAnchored` from the row that just lost focus must never let the relayout pass
                // below anchor the newly-focused row on its behalf.
                lastAnchored = nil
                guard let row else {
                    detailAnchorTask?.cancel()
                    detailAnchorTask = nil
                    dimModel.awaitingRevealRow = nil
                    if DetailScrollProbe.enabled { dimModel.anchorNote = "none" }
                    return
                }
                detailAnchorTask?.cancel()
                // Codex P2 review finding (BUG-99 follow-up, round 2): Comments is now a TRACKED
                // row (`commentsSection` carries `.detailRowAnchored(.comments, …)` above) but must
                // still never anchor or straddle-check — bail out here, before `DetailRowAnchor
                // .direction` runs at all, exactly like the `guard let row else` branch above does
                // for the top block.
                guard row != .comments else {
                    dimModel.awaitingRevealRow = nil
                    if DetailScrollProbe.enabled { dimModel.anchorNote = "comments free" }
                    return
                }
                // `focusedRow` now reports `.comments` (never nil) while focus is inside it, so
                // `old == nil` unambiguously means "first entry from the top block" — see
                // `DetailRowAnchor.direction`'s doc comment for why the old
                // `contentOffset`/`lastKnownTop` heuristic this replaced was wrong.
                let direction = DetailRowAnchor.direction(
                    old: old,
                    oldTop: old.flatMap { detailRowOffsets[$0] },
                    newTop: detailRowOffsets[row] ?? 0
                )
                switch direction {
                case .up:
                    dimModel.awaitingRevealRow = row
                    dimModel.awaitingRevealStartOffset = dimModel.lastContentOffset
                    detailAnchorTask = Task { @MainActor in
                        // Fallback only: if the scroll-geometry handler hasn't already disarmed by
                        // the time this fires, the engine never moved the page — fire the pass
                        // ourselves.
                        try? await Task.sleep(nanoseconds: UInt64(DetailRowAnchor.blendFallbackDelay * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        if dimModel.awaitingRevealRow == row {
                            dimModel.awaitingRevealRow = nil
                            guard anchorPass(row, note: "blend-fallback") else { return }
                        }
                        // Whether the geometry handler blended in already or the fallback just
                        // fired: one verify pass. A card whose thumbnails land after the settle
                        // makes the engine re-reveal it and undo the rest. Re-issue once, never
                        // loop.
                        try? await Task.sleep(nanoseconds: UInt64(DetailRowAnchor.verifyDelay * 1_000_000_000))
                        _ = anchorPass(row, note: "re-issued", onlyIfDrifted: true)
                        // Publish the geometry sample once, AT REST, for the probe (never per
                        // frame).
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if !Task.isCancelled, DetailScrollProbe.enabled { dimModel.scrollGeoNote = dimModel.geometrySample }
                    }
                case .down:
                    // BUG-99: no blend arm, no fallback pass, no verify pass — leave the engine's
                    // own reveal running unmodified. One task waits for it to settle, then
                    // straddle-checks the result and anchors only if the header needs rescuing.
                    dimModel.awaitingRevealRow = nil
                    detailAnchorTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(DetailRowAnchor.settleCheckDelay * 1_000_000_000))
                        guard !Task.isCancelled, focusedRow == row, bridgePhase == .idle,
                              let rowTop = detailRowOffsets[row] else { return }
                        // The row's on-screen top is `rowTop − contentOffset` on this runtime: the
                        // anchor's own `scrollTo(y: rowTop + inset − rest)` lands at `y − inset`,
                        // i.e. `contentOffset == rowTop − rest` at rest, which is also the
                        // `(top − off) − 108` residual the UI test reads. No inset term here — with
                        // it the check would overshoot by the inset (157 pt on the fixture) and a
                        // header sitting under the scrim would read as free.
                        let screenTop = rowTop - dimModel.lastContentOffset
                        switch DetailRowAnchor.decision(direction: .down, screenTop: screenTop) {
                        case .anchor:
                            _ = anchorPass(row, note: "down-straddle")
                        case .free:
                            // A free row is not this pass's rest — a later layout change under it
                            // must not pull it up to the anchor either. `lastAnchored` is already
                            // nil (cleared at the top of this handler and never set by this branch,
                            // since `anchorPass` was not called), so the relayout pass below's
                            // `lastAnchored?.row == focusedRow` guard already excludes this row (see
                            // `.onChange(of: detailRowOffsets)` below).
                            if DetailScrollProbe.enabled {
                                // `top=` stays in CONTENT space like `anchorPass`'s note: the UI test derives the
                                // on-screen rest as `(top − off) − 108`. `screen=` is the settled on-screen top.
                                dimModel.anchorNote = String(format: "%@ top=%.0f screen=%.0f free", String(describing: row), rowTop, screenTop)
                            }
                        }
                        // Publish the geometry sample once, AT REST, for the probe (never per
                        // frame) — same as the Up path, so the UI test still gets a sample per
                        // step regardless of direction.
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if !Task.isCancelled, DetailScrollProbe.enabled { dimModel.scrollGeoNote = dimModel.geometrySample }
                    }
                }
            }
            // Codex BUG-96 r1 (P2): a correction must not land on a page that is leaving or
            // under the trailer cover's 0.6 s leave transition.
            .onChange(of: bridgePhase) { _, phase in
                if phase != .idle {
                    detailAnchorTask?.cancel(); detailAnchorTask = nil
                    dimModel.awaitingRevealRow = nil
                }
            }
            .onDisappear {
                detailAnchorTask?.cancel(); detailAnchorTask = nil
                dimModel.awaitingRevealRow = nil
            }
            // BUG-96 (fixture step 5): late layout under the focused row moved it 470 pt after the
            // pass and the engine re-revealed the card. Re-anchor once per layout change, debounced.
            // Codex P2 review finding (BUG-99 follow-up): gated on `lastAnchored?.row ==
            // focusedRow`, not just `lastAnchored != nil` — the old bare `CGFloat?` compared the
            // newly-focused row's top against whatever the PREVIOUS row's anchor pass had left
            // there, so a relayout within 350 ms of a focus change (`lastAnchoredRowTop` still
            // held the old row's rest) could anchor a row that was deliberately left `.free`. Per
            // row ownership fixes that: a free row's later layout shift never gets pulled up into
            // an anchor it was deliberately left without, and a stale prior row's rest can never be
            // mistaken for the current row's.
            .onChange(of: detailRowOffsets) { _, offsets in
                guard let row = focusedRow, bridgePhase == .idle,
                      let top = offsets[row], let last = lastAnchored, last.row == row,
                      abs(top - last.top) > DetailRowAnchor.verifyTolerance else { return }
                detailAnchorTask?.cancel()
                detailAnchorTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard anchorPass(row, note: "relayout") else { return }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if !Task.isCancelled, DetailScrollProbe.enabled { dimModel.scrollGeoNote = dimModel.geometrySample }
                }
            }
            // FEAT-32: the chrome fades out ahead of the dim on the way in, and waits for the
            // backdrop settle on the way back.
            .opacity(TrailerBridgeChoreography.chromeOpacity(bridgePhase))
            .animation(TrailerBridgeChoreography.chromeAnimation(to: bridgePhase), value: bridgePhase)
            // Off the accessibility tree while invisible, so test51's "chrome is back" check reads
            // visibility, not mere existence (the tvOS 27 runtime never reports focus).
            .accessibilityHidden(bridgePhase != .idle)
            // UX-6: final darkening value computed here (not in `action:`) so saturated scrolling
            // stops firing state updates once fully dark.
            .onScrollGeometryChange(for: Double.self, of: { geo in
                // P-2b (BUG-41 attribution knob): leg 1/3 disables the dim outright by pinning
                // this closure's result to a constant, so `action:` fires once with 0 and never
                // again — see `DetailScrollAB`'s doc comment.
                guard !DetailScrollAB.dimDisabled else { return 0 }
                // 0 → 0.85 over the first ~400pt of scroll. Device pass (2026-08-01): the
                // original 0.35 ceiling was invisible over a bright playing trailer on a real
                // TV — the reporter's ask (and upstream's cinematic mode) is a near-black dim
                // once the description scrolls up. Sim-verified via debug_ux6 (test17).
                let raw = min(max((geo.contentOffset.y - geo.contentInsets.top) / 400.0, 0), 1) * 0.85
                // BUG-41: quantized to the nearest 0.05 (was 0.01) — `onScrollGeometryChange`
                // only calls `action:` when the mapped value actually *changes*, so coarsening the
                // step cuts the write rate from ~85 possible values over the 400pt ramp down to
                // ~17, roughly 5x fewer SwiftUI invalidations. P-2c (device revival, 2026-08-23):
                // 0.01 alone was fine-grained enough to read as smooth without help, but 0.05 alone
                // visibly steps — paired with `ScrollDimOverlay`'s
                // `.animation(.linear(duration: 0.12), value:)` below, which interpolates between
                // steps in Core Animation's render server instead of SwiftUI stepping the opacity
                // directly, 0.05 reads as smooth again while writing far less.
                return (raw * 20).rounded() / 20
            }, action: { _, newValue in
                dimModel.value = newValue
            })
            // UX-6 device-verify probe: raw offset/inset so `log show` proves whether tvOS
            // focus-scrolling moves this ScrollView's contentOffset at all. Gated by
            // `DetailScrollProbe.enabled` (not `#if DEBUG` — see that enum's doc comment). The
            // `of:` closure collapses to a constant when disabled so `action:` only fires once
            // (on the first geometry read) instead of on every scroll frame.
            .onScrollGeometryChange(for: String.self, of: { geo in
                guard DetailScrollProbe.enabled else { return "" }
                return "y=\(Int(geo.contentOffset.y)) inset=\(Int(geo.contentInsets.top))"
            }, action: { _, v in
                guard DetailScrollProbe.enabled else { return }
                NSLog("[UX6] %@", v)
            })
            // BUG-41 (beta.18, item 1): feeds `dimModel.isScrolling`. Deliberately its OWN tracker
            // over raw `contentOffset.y` rather than piggybacking on the dim-ramp closure above —
            // that closure quantizes to 0.05 steps and can go a full second without its `action:`
            // firing once the ramp saturates at 0.85 deep in a long description, and it collapses
            // to a constant 0 outright under `DetailScrollAB` legs 1/3. Raw offset changes on
            // (essentially) every scroll frame regardless of ramp state or A/B leg, so "is the user
            // actively scrolling" tracks real scroll motion instead of the dim value's own
            // throttling.
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }, action: { _, geo in
                // BUG-96: the anchor's live terms, written per frame into plain (non-published)
                // fields — no invalidation. The probe note is the diagnostic mirror.
                dimModel.contentInsetTop = geo.contentInsets.top
                dimModel.lastContentOffset = geo.contentOffset.y
                // Codex BUG-96 r1 (P3): the diagnostic string is SAMPLED here into a plain field and
                // published only from the anchor pass, so the probe never invalidates the page per
                // frame and cannot contaminate its own hitch measurements.
                if DetailScrollProbe.enabled {
                    // BUG-96 oracle: append this frame's timestamped offset and re-derive the
                    // motion-segment count so `moves=` in the probe always reflects every sample
                    // taken since the last focus change, not just the ones seen before the last
                    // publish. Timestamped with `CACurrentMediaTime()` (matches `HitchCounter`
                    // elsewhere in this file) because the split is time-based — see
                    // `DetailScrollMotion`.
                    if dimModel.motionSamples.count < 600 {
                        dimModel.motionSamples.append(MotionSample(time: CACurrentMediaTime(), offset: geo.contentOffset.y))
                    }
                    let moves = DetailScrollMotion.segments(dimModel.motionSamples)
                    dimModel.geometrySample = String(format: "off=%.0f inset=%.0f vis=%.0f content=%.0f moves=%d", geo.contentOffset.y, geo.contentInsets.top, geo.bounds.height, geo.contentSize.height, moves)
                }
                // BUG-96 blend: the instant the engine's own reveal actually moves the page, fire
                // the anchor pass right here instead of waiting for the reveal to finish — the two
                // motions then read as one. `anchorPass` re-checks `focusedRow`/`bridgePhase` itself,
                // so a stale `row` captured just before a newer focus change is harmless.
                // BUG-99: `awaitingRevealRow` is only ever armed on an UP focus change now — see
                // `onChange(of: focusedRow)` above — so this block is inert for the whole duration
                // of a Down-focused visit, which has its own settle-check task instead.
                if let row = dimModel.awaitingRevealRow,
                   abs(geo.contentOffset.y - dimModel.awaitingRevealStartOffset) >= DetailScrollMotion.stationaryThreshold {
                    dimModel.awaitingRevealRow = nil
                    _ = anchorPass(row, note: "blend")
                }
            })
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }, action: { _, _ in
                dimModel.noteScrollChange()
            })
            // BUG-41: hysteresis latch driving `trailerLayerVisible` — see `trailerDimmedOut`'s doc
            // comment. Wired on the outer ZStack (not inside `ScrollDimOverlay`) since it needs to
            // reach the trailer-mount `if` above, not just the overlay's own opacity.
            .onReceive(dimModel.$value) { newValue in
                // Codex r3 (P2): 0.80 / 0.55, not 0.5 / 0.3 — the trailer stays mounted for as
                // long as it is visibly exposed. See `trailerDimmedOut`'s doc comment.
                if newValue >= 0.80 {
                    if !trailerDimmedOut { trailerDimmedOut = true }
                } else if newValue < 0.55 {
                    if trailerDimmedOut { trailerDimmedOut = false }
                }
            }
            // FEAT-32: the title fades in bottom-left with the Back hint while the page leaves; the
            // player draws its own copy for the first seconds of playback. rc2 (u/mrStevenx3): the
            // logo, not plain text, and `placedBottomLeading()` is the shared placement that keeps
            // this copy and the player's in the same rect at the hand-over. The scale removed in
            // rc2/rc5 is back as of 2026-09-08 (his 09-07 ask, "the logo growing while the page
            // fades to dark") — description-side only, the cover-side copy below still never scales.
            TrailerBridgeCaption(title: model.trailerPlayback?.title ?? title, logoURL: logoUrl)
                .placedBottomLeading()
                .opacity(TrailerBridgeChoreography.captionOpacity(bridgePhase))
                .scaleEffect(TrailerBridgeChoreography.captionScale(bridgePhase), anchor: .bottomLeading)
                .animation(TrailerBridgeChoreography.captionAnimation(to: bridgePhase), value: bridgePhase)
                .accessibilityHidden(TrailerBridgeChoreography.captionOpacity(bridgePhase) == 0)
            #if DEBUG
            // FEAT-32 diagnostic (invisible, harness-readable): the phases this visit's bridge went
            // through, so test51 can prove the choreography ran rather than that the cover came
            // and went. Same shape as `debug_trailers`.
            Text("debug_bridge trace=\(bridgeTrace)")
                .font(.system(size: 8))
                .opacity(0.011)
                .accessibilityIdentifier("debug_bridge")
            #endif
        }
        // FEAT-8: combined into one Bool so the fade also triggers when the trailer-duration timer
        // stops the background player (a `withAnimation(.easeInOut(duration: 1.5))` at the call site
        // overrides this ambient 0.8s for that specific change — see `stopBackgroundTrailer()`).
        .animation(.easeInOut(duration: 0.8), value: model.trailerVideoURL != nil && !backgroundTrailerStopped)
        // UX-12 removed the on-screen speaker indicator (FEAT-11's default-audio setting makes it
        // redundant); the Siri Remote's play/pause button remains the mute/unmute control.
        .onPlayPauseCommand {
            if isTrailerActive {
                HeroTrailerAudioState.shared.toggleMuted()
            } else if focusedRow == nil, bridgePhase == .idle, !showStreams, seriesPlay == nil {
                // F14: with no trailer to mute, Play/Pause does what the TV app does on a product
                // page: it runs the primary Play action. Only from the top block (a row below,
                // e.g. an episode or More Like This poster, is not the title the button plays).
                performPrimaryPlay()
            }
        }
        // Any D-pad swipe means the user is actively navigating the page rather than just reading
        // the description — treat it as "started interacting" and cancel the pending auto-play.
        // This only adds an observer alongside the focus engine's own directional handling (like
        // `onPlayPauseCommand` above), so ordinary focus movement between buttons/rows is unaffected.
        .onMoveCommand { _ in userInteracted = true }
        .onAppear {
            model.start()
            // FEAT-8: one-shot per screen visit — a prior visit's expiry must not carry over.
            backgroundTrailerStopped = false
            cancelTrailerDurationTask()
            // BUG-41 item 6: no-op unless `DetailScrollProbe.enabled` (checked inside `start()`).
            hitchCounter.start()
        }
        .onDisappear {
            model.stop()
            cancelAutoPlayTrailer()
            cancelTrailerDurationTask()
            // BUG-41 item 6: logs the visit's `[BUG41] hitches=… frames=… maxGap=…` summary; no-op
            // if `start()` never armed the display link.
            hitchCounter.stopAndLog()
            // BUG-41 (beta.18, item 1): cancels any pending "flip isScrolling back to false" timer
            // so it doesn't fire against a model nobody's reading once this visit's over.
            dimModel.cancelScrollLatch()
        }
        .onChange(of: model.trailerVideoURL) { _, newValue in
            if newValue != nil {
                scheduleAutoPlayTrailerIfNeeded()
                scheduleTrailerDurationTimerIfNeeded()
            }
        }
        .onChange(of: showStreams) { _, isShowing in
            if isShowing {
                cancelAutoPlayTrailer()
                withdrawTrailerBridgeIfLeaving()
            }
        }
        .onChange(of: seriesPlay?.id) { _, routeId in
            if routeId != nil {
                cancelAutoPlayTrailer()
                withdrawTrailerBridgeIfLeaving()
            }
        }
        .onChange(of: userInteracted) { _, interacted in
            if interacted { cancelAutoPlayTrailer() }
        }
        // F2: `onMoveCommand` alone misses the moves the focus engine consumes (Down from the
        // action row into Episodes moves focus without delivering a move command), so ANY focus
        // change counts as interaction too. The first landing (nil → Play, the default focus) is
        // not a move and is ignored.
        .onChange(of: focusedAction) { old, new in
            if old != nil, old != new { userInteracted = true }
        }
        .onChange(of: focusedRow) { _, _ in
            userInteracted = true
        }
        // F1: Play takes focus when the page opens (spec §6.2), never Mark Watched.
        .defaultFocus($focusedAction, .play)
        // F1: series-level Mark Watched / Unmark touches every released episode, so it asks first.
        .alert(seriesWatchedCopy.title, isPresented: $confirmingSeriesWatched) {
            Button(seriesWatchedCopy.confirm, role: .destructive) {
                model.toggleWatched()
            }
            Button(Self.cancelCopy, role: .cancel) {}
        } message: {
            Text(seriesWatchedCopy.message)
        }
        // F1: Play stays focusable when no source can stream the title; pressing it explains why.
        .alert(Self.playbackUnavailableTitle, isPresented: $showingPlaybackUnavailable) {
            Button(Self.okCopy, role: .cancel) {}
        } message: {
            Text(playbackUnavailableMessage)
        }
        .fullScreenCover(isPresented: $showStreams) {
            // CW-1: the backdrop (never the poster fallback `backgroundUrl` ends on) and the logo
            // are recorded with the progress entry for Continue Watching and its hero.
            StreamPickerView(type: preview.type, videoId: streamVideoId, title: title,
                             poster: posterUrl, synopsis: overview, meta: playbackMeta,
                             background: model.meta?.background ?? preview.banner, logo: logoUrl)
        }
        .fullScreenCover(item: $seriesPlay) { route in
            StreamPickerView(
                type: route.meta.type,
                videoId: route.action.videoId,
                title: route.pickerTitle,
                parentMetaId: route.meta.id,
                season: route.action.seasonNumber?.value,
                episode: route.action.episodeNumber?.value,
                episodes: route.meta.videos,
                poster: route.meta.poster,
                episodeStill: route.episodeStill,
                synopsis: route.synopsis,
                meta: playbackMeta,
                // CW-1: progress is filed under the series, with the episode's own name beside it.
                seriesTitle: route.meta.name,
                episodeTitle: route.episodeName,
                background: route.meta.background,
                logo: route.meta.logo
            )
        }
        // FEAT-32: presented from `presentedTrailer`, which `beginTrailerBridge` sets after the
        // leaving choreography. Dismissal (Back) writes nil back to the request so every
        // `trailerPlayback == nil` gate in this view reads as before.
        .fullScreenCover(item: Binding(
            get: { presentedTrailer },
            set: { newValue in
                if newValue == nil {
                    TrailerZoomProbe.log("bridge cover-binding nil")
                    // Back on the cover. Move to the return values in THIS update so the cover's
                    // dismissal animation reveals the enlarged still, then withdraw the request;
                    // `onDismiss` settles once the cover is gone.
                    endTrailerBridge()
                }
                presentedTrailer = newValue
                if newValue == nil { model.trailerPlayback = nil }
            }
        ), onDismiss: {
            // FEAT-11: returning from ANY full-screen trailer (the hero "Watch Trailer" button
            // above, or a "Trailers & Extras" row item) to the muted background loop — restore the
            // shared audio preference back to the user's configured default (it seeds `isMuted`
            // from this same shared state on re-attach; see
            // `TrailerHeroPlayerView.Coordinator.attach`) so the sound the user just heard doesn't
            // unconditionally carry over into the background player once it reappears.
            HeroTrailerAudioState.shared.setMuted(value: !trailerAudioDefaultOn)
            trailerPlaybackIsAutoPlay = false
            // FEAT-32: the cover is gone, the still is showing enlarged: settle it.
            TrailerZoomProbe.log("bridge onDismiss")
            bridgeCoverPresented = false
            settleTrailerBridge()
        }) { item in
            // UX-9: the player scales itself past fill (parityZoom) to crop baked-in letterbox
            // bars; end-of-playback dismisses back to Detail rather than resting on a black
            // frame, since the controls-free surface has no replay affordance.
            // C3: `item.zoomKey`, not `model.trailerZoomKey` — the hero button/autoplay items carry
            // the canonical title key (same stream as the hero loop), row-clip items carry their
            // own per-trailer-id key (see `TrailerPlaybackItem.zoomKey`).
            ZStack {
                // FEAT-32: the cover's own copy of the enlarged still, under the player. When the
                // dismissal starts the player surface is blanked and THIS is what the system
                // crossfades over the description, which is showing the same image at the same
                // scale: a seamless hard cut without making the cover transparent. (A clear
                // presentation background was tried first: it keeps the presenting view alive
                // under the cover, and one Menu press then both dismissed the cover and popped the
                // detail page, test51 run of 2026-09-05 18:15.)
                backdropImage
                    .scaleEffect(TrailerBridgeChoreography.returnScale)
                // Codex round 3 (P2): composed exactly as the description composes it underneath
                // (scrim, then the scroll dim at its current value; the poster layer is held for
                // the whole bridge), or the crossfade runs between a raw and a darkened frame.
                scrimOverlay(posterBackdropVisible: false)
                ScrollDimOverlay(model: dimModel, trailerActive: false, glassFlat: chipGlassFlat, showsProbe: false)
                FullScreenTrailerPlayer(urlString: item.url, onPlaybackEnded: {
                    model.trailerPlayback = nil
                }, zoomKey: item.zoomKey, videoId: item.videoId, onWillDismiss: {
                    // FEAT-32: the system dismissal has begun (Back). SwiftUI only reports it once
                    // it has ENDED (cover binding nil, `onDismiss` and the player teardown all
                    // land in the same millisecond), so this is the one moment to drop the black
                    // and land the enlarged still before the cover reveals the description.
                    TrailerZoomProbe.log("bridge cover-will-disappear")
                    NotificationCenter.default.post(name: .trailerBridgeCoverWillDismiss, object: nil)
                    endTrailerBridge()
                })
            }
                .ignoresSafeArea()
                // FEAT-32: title (logo) + Back hint, bottom-left, for a beat after playback starts.
                // The auto-play entry keeps its longer dwell (BUG-18: a 4 s hint was reported as
                // "doesn't stay on the screen" on TVs that blank at playback start). rc2
                // (u/mrStevenx3): placed through `placedBottomLeading()`, the same helper the
                // description's copy uses, so the two coincide exactly during the hand-over instead
                // of showing ~30 px apart for a couple of frames. The alignment lives in the helper,
                // hence the plain `.overlay`.
                .overlay {
                    TrailerBridgeCaption(title: item.title,
                                         logoURL: logoUrl,
                                         dwell: trailerPlaybackIsAutoPlay ? 6 : TrailerBridgeChoreography.captionDwell)
                        .placedBottomLeading()
                }
        }
        .onChange(of: model.trailerPlayback?.id) { _, newId in
            if newId != nil, let item = model.trailerPlayback {
                beginTrailerBridge(item)
            } else {
                endTrailerBridge()
            }
        }
        // Detail is an "immersive" screen: the floating tab bar hides for as long as one is on
        // screen, at any nesting depth (Detail → More Like This → Detail pushes are common, hence
        // a depth counter on the shared TabBarVisibility rather than a plain flag here).
        .onAppear { tabBarVisibility.pushImmersive() }
        .onDisappear {
            tabBarVisibility.popImmersive()
            bridgeTask?.cancel()
            bridgeTask = nil
        }
    }

    // MARK: - FEAT-32: trailer bridge

    /// The request just landed: run the leaving choreography, then present the cover if the request
    /// still stands. A second request mid-flight (a different trailer id) restarts the timer.
    private func beginTrailerBridge(_ item: TrailerPlaybackItem) {
        bridgeTask?.cancel()
        setBridgePhase(TrailerBridgeChoreography.next(bridgePhase, .trailerRequested))
        bridgeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(TrailerBridgeChoreography.leaveDuration))
            guard !Task.isCancelled, model.trailerPlayback?.id == item.id else { return }
            // Codex round 1 (P2): the chrome is only invisible during the leave, not disabled
            // (disabling the focused button can strand tvOS focus, BUG-47's class), so Select can
            // still open the stream picker underneath. Never stack the trailer cover on top of
            // it: withdraw the request instead, which returns the page under the picker.
            guard !showStreams, seriesPlay == nil else {
                model.trailerPlayback = nil
                return
            }
            setBridgePhase(TrailerBridgeChoreography.next(bridgePhase, .leaveFinished))
            bridgeCoverPresented = true
            presentedTrailer = item
        }
    }

    private func setBridgePhase(_ phase: TrailerBridgePhase) {
        guard phase != bridgePhase else { return }
        bridgePhase = phase
        bridgeTrace += ">" + phase.label
        TrailerZoomProbe.log("bridge phase=\(phase.label)")
    }

    /// The request was withdrawn: playback ended, Back was pressed on the cover, or the trailer
    /// went away before the cover presented. The return values apply with NO animation so the
    /// cover's dismissal reveals the enlarged still; `settleTrailerBridge` then animates it home.
    /// Idempotent: the Back path calls it from the cover binding first and again from the
    /// request's `onChange`.
    private func endTrailerBridge() {
        bridgeTask?.cancel()
        bridgeTask = nil
        guard bridgePhase != .idle else { return }
        setBridgePhase(TrailerBridgeChoreography.next(bridgePhase, .trailerEnded))
        if bridgeCoverPresented {
            // `onDismiss` settles once the cover is actually gone.
            presentedTrailer = nil
        } else {
            // Codex round 2 (P3): no cover means no `onDismiss`, which is where this marker is
            // normally cleared; left set, the next manual trailer would keep auto-play's longer
            // caption dwell.
            trailerPlaybackIsAutoPlay = false
            settleTrailerBridge()
        }
    }

    /// Codex round 1 (P2): a stream-picker cover opened while the bridge was leaving (the buttons
    /// stay focusable under the fading chrome). Withdraw the trailer request so the two covers
    /// never stack; the request's `onChange` returns the page.
    private func withdrawTrailerBridgeIfLeaving() {
        guard bridgePhase == .leaving else { return }
        model.trailerPlayback = nil
    }

    private func settleTrailerBridge() {
        guard bridgePhase == .returning else { return }
        setBridgePhase(TrailerBridgeChoreography.next(bridgePhase, .settle))
    }

    // MARK: - F1/F14: primary Play slot

    /// What the always-present primary button shows and does right now.
    private enum PrimaryPlayState {
        /// Movie (or a title not yet known to be a series): opens the stream picker.
        case movie
        /// Series with a resolved Resume / Play SxEy action.
        case series(meta: MetaDetails, action: SeriesPrimaryAction)
        /// Series whose details (and so its episode action) are still loading: the slot is held,
        /// focusable, and a press does nothing yet.
        case loading
        /// Nothing can be played: no source can stream it, or a loaded series has no episode.
        case unavailable
    }

    private var primaryPlayState: PrimaryPlayState {
        guard model.isPlaybackAvailable else { return .unavailable }
        guard isSeries else { return .movie }
        if let action = model.seriesAction, let meta = model.meta {
            return .series(meta: meta, action: action)
        }
        return (model.meta == nil || model.isLoading) ? .loading : .unavailable
    }

    /// F1/F14: the one entry point for the primary button and the remote's Play/Pause.
    private func performPrimaryPlay() {
        switch primaryPlayState {
        case .movie:
            showStreams = true
        case .series(let meta, let action):
            seriesPlay = SeriesPlayRoute(meta: meta, action: action)
        case .loading:
            break
        case .unavailable:
            showingPlaybackUnavailable = true
        }
    }

    /// F1: the Mark Watched button. A series marks or clears every episode, so it confirms first.
    private func requestToggleWatched() {
        // Before the details resolve, a non-movie preview (anime, "tv", …) may still be a series
        // that `togglePosterWatched` marks episode by episode, so it asks too.
        if isSeries || (model.meta == nil && preview.type != "movie") {
            confirmingSeriesWatched = true
        } else {
            model.toggleWatched()
        }
    }

    private var seriesWatchedCopy: (title: String, confirm: String, message: String) {
        if model.isWatched {
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

    private static var cancelCopy: String {
        String(localized: "detail.seriesWatched.cancel", defaultValue: "Cancel",
               comment: "Cancel button of the series watched confirmation")
    }

    private static var okCopy: String {
        String(localized: "detail.playbackUnavailable.ok", defaultValue: "OK",
               comment: "Dismiss button of the playback unavailable alert")
    }

    private static var playbackUnavailableTitle: String {
        String(localized: "detail.playbackUnavailable.title", defaultValue: "Playback unavailable",
               comment: "Alert title when no installed source can stream the title")
    }

    private var playbackUnavailableMessage: String {
        // A loaded series with no episode to start (nothing released yet) is a different reason
        // from "no source can stream it" (upstream 972109f9's check).
        if model.isPlaybackAvailable {
            return String(localized: "detail.playbackUnavailable.noEpisode",
                          defaultValue: "No episode of this series is available to play yet.",
                          comment: "Alert message when a series has no released episode to play")
        }
        return String(localized: "detail.playbackUnavailable.message",
               defaultValue: "None of your add-ons or plugins can stream this title. Install or enable a stream add-on, then try again.",
               comment: "Alert message when no installed source can stream the title")
    }

    // MARK: - Derived values (prefer enriched meta, fall back to the preview card)

    private var isSeries: Bool {
        if let meta = model.meta { return EpisodesSection.isSeriesLike(meta) }
        return preview.type == "series"
    }
    private var title: String { model.meta?.name ?? preview.name }
    // Kotlin `description` collides with NSObject.description, so KMP exposes it as `description_`.
    private var overview: String? { model.meta?.description_ ?? preview.description_ }
    private var genres: [String] { model.meta?.genres ?? preview.genres }
    private var backgroundUrl: String? { model.meta?.background ?? preview.banner ?? preview.poster }
    private var logoUrl: String? { model.meta?.logo ?? preview.logo }
    /// Poster art for the right-hand backdrop layer — independent of `backgroundUrl`'s
    /// banner/backdrop preference (tester ask: mirror mobile's "poster stays on the right" layout).
    private var posterUrl: String? { model.meta?.poster ?? preview.poster }

    /// BUG-74: the id a STREAM request must use — the resolved meta's canonical id whenever we
    /// have it, never the catalog preview's. This is the one derived value where the two genuinely
    /// disagree, and it is why it took three weeks and a DM to find.
    ///
    /// Every TMDB-backed surface (collection folders, search, More Like This) hands this screen a
    /// `preview.id` of the form `tmdb:<n>`. `MetaDetailsRepository.resolveMetaLookupId` remaps that
    /// to `tt…` for the META fetch *only*: the addon's canonical id comes back on `meta.id` while
    /// `preview.id` stays `tmdb:` — the divergence `DetailViewModel` already documents where it
    /// explains why the stale-publish guard must not match on `meta.id`. Stream addons declare
    /// `idPrefixes: ["tt"]`, so shipping a `tmdb:` id into `StreamsRepository` filters out every
    /// one of them (`NoCompatibleAddons`) and the user gets no streams at all — on a detail page
    /// that rendered perfectly, which is exactly what hid this.
    ///
    /// The preview fallback still earns its place: Play can be pressed before the meta resolves.
    /// That window is covered by `StreamsRepository`'s own tmdb→imdb retry, not here — this
    /// property must stay a pure read so it can't stall the cover's presentation.
    private var streamVideoId: String { model.meta?.id ?? preview.id }

    /// Same gate the muted background hero player (and its mute button/play-pause toggle) use.
    /// FEAT-8: also false once the trailer-duration timer has stopped the background player, so the
    /// mute button hides and the poster-backdrop layer (below) reclaims the area it faded into.
    /// F2 / spec §1.15: never under Reduce Motion (the still backdrop stays).
    private var isTrailerActive: Bool {
        backgroundTrailerEnabled && model.trailerVideoURL != nil && !showStreams
            && model.trailerPlayback == nil && !backgroundTrailerStopped && !reduceMotion
    }

    /// BUG-41: `isTrailerActive` plus the scroll-dim hysteresis latch — whether the hero-trailer
    /// `AVPlayerLayer` should actually be mounted right now. The single source of truth for both the
    /// trailer's own `if` in `body` and the `trailerActive` flag `ScrollDimOverlay` uses to decide
    /// whether to animate or step (see `trailerDimmedOut`'s doc comment for the "why tear it down"
    /// reasoning).
    private var trailerLayerVisible: Bool { isTrailerActive && !trailerDimmedOut }

    /// BUG-41 leg 2/3/4 + "flatten while a trailer plays" (item 4) + "flatten while scrolling"
    /// (beta.18, item 2): whether the top-block chips (`metaChip`, parental-guide) should render
    /// flat translucent material instead of `.glassEffect`. Mirrors `detailChipBackground`'s own
    /// condition (the only other reader — see `Self.chipGlassFlat` below); also folded into the
    /// `debug_ux6` diagnostic's `glass=` token.
    ///
    /// Deliberately NOT unified with `actionRow`'s `GlassEffectContainer`/button-style swap
    /// (`DetailScrollAB.buttonGlassDisabled`, leg 4 only): that enum's own doc comment records it
    /// as an intentionally SEPARATE knob so legs 2/3 can isolate "chips only" from leg 4's "chips +
    /// buttons" for the A/B attribution question BUG-41 is still mid-answering on-device. Folding
    /// `dimModel.isScrolling` in here would silently make ordinary (leg 0) scrolling flatten the
    /// action row too, widening that experiment's scope as a side effect of this fix.
    /// BUG-96: one anchor pass. Codex r1 (P2): geometry is read HERE, at fire time — the row's
    /// content-space top and the live top inset — never captured before the wait (a parental-guide
    /// row inserting asynchronously moves every row below it). Gated on the page being visible and
    /// the trailer bridge idle; honours Reduce Motion (no animated translation). Returns false when
    /// the pass was skipped for good.
    @discardableResult
    private func anchorPass(_ row: DetailRowID, note: String, onlyIfDrifted: Bool = false) -> Bool {
        // Codex BUG-96 r2 (P2): the sleeps swallow cancellation (`try?`), so the pass itself must
        // refuse to run once cancelled (disappear, bridge leaving idle, a newer focus change).
        guard !Task.isCancelled, focusedRow == row, bridgePhase == .idle, let rowTop = detailRowOffsets[row] else { return false }
        let inset = dimModel.contentInsetTop
        let target = DetailRowAnchor.scrollTarget(rowTop: rowTop, contentInsetTop: inset)
        let expected = DetailRowAnchor.expectedOffset(scrollTarget: target, contentInsetTop: inset)
        if onlyIfDrifted, abs(dimModel.lastContentOffset - expected) <= DetailRowAnchor.verifyTolerance { return true }
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { detailScrollPosition.scrollTo(y: target) }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { detailScrollPosition.scrollTo(y: target) }
        }
        lastAnchored = (row, rowTop)
        if DetailScrollProbe.enabled {
            dimModel.anchorNote = String(format: "%@ top=%.0f y=%.0f %@", String(describing: row), rowTop, target, note)
        }
        return true
    }

    private var chipGlassFlat: Bool {
        Self.chipGlassFlat(trailerActive: isTrailerActive, scrolling: dimModel.isScrolling, glassDisabled: DetailScrollAB.glassDisabled)
    }

    /// Pure truth table backing `chipGlassFlat` above, extracted so `DetailScrollProbeTests` can
    /// exhaustively cover all 8 combinations without standing up a `DetailView`/`DetailViewModel`.
    /// `nonisolated` for the same reason as `ScrollingLatch.isScrolling`: no instance/actor state
    /// involved, so tests can call it directly with no `@MainActor` hop.
    nonisolated static func chipGlassFlat(trailerActive: Bool, scrolling: Bool, glassDisabled: Bool) -> Bool {
        trailerActive || scrolling || glassDisabled
    }

    /// The poster-backdrop layer only earns its keep when it would show something the plain
    /// backdrop doesn't already — skip when they're the same URL (`backgroundUrl` already falls
    /// back to poster art itself) — and only while the hero trailer isn't occupying that same area.
    private var showPosterBackdrop: Bool {
        // FEAT-32: `!isTrailerActive` is also true for the whole full-screen trailer bridge (the
        // request pauses the background loop), which used to mount this layer unseen under the
        // opaque cover. The cover is transparent on its way out now, so the layer would show
        // through the reveal as a second artwork fading over the settling still. Idle only.
        posterBackdropEnabled && posterUrl != nil && posterUrl != backgroundUrl && !isTrailerActive
            && bridgePhase == .idle
    }

    // MARK: - Sections

    private var backdropImage: some View {
        GeometryReader { geo in
            CachedAsyncImage(string: backgroundUrl)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .ignoresSafeArea()
        // Purely decorative full-bleed background — the title/overview text drawn over it
        // already carries the same information for VoiceOver.
        .accessibilityHidden(true)
    }

    /// The poster pinned to the right 40% of the screen, behind the description (tester ask, mirrors
    /// mobile's Detail layout). Its own leading edge fades to transparent so it blends into the plain
    /// backdrop underneath instead of showing a hard seam.
    private var posterBackdropLayer: some View {
        GeometryReader { geo in
            CachedAsyncImage(string: posterUrl)
                .frame(width: geo.size.width * 0.4, height: geo.size.height, alignment: .trailing)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.3),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .ignoresSafeArea()
        // Same reasoning as backdropImage — decorative right-edge poster art, not a control.
        .accessibilityHidden(true)
    }

    /// Gradient scrims for text legibility, drawn over the backdrop (and the trailer, when present).
    /// `posterBackdropVisible` softens the trailing (right-edge) stop so the poster-backdrop layer
    /// behind it (pinned to the right 40%) reads through instead of going nearly opaque black; the
    /// leading 0.95 stop (left-text readability invariant) and the bottom vertical gradient are
    /// unchanged either way.
    private func scrimOverlay(posterBackdropVisible: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    .black.opacity(0.95),
                    .black.opacity(0.4),
                    .black.opacity(posterBackdropVisible ? 0.45 : 0.85)
                ],
                startPoint: .leading, endPoint: .trailing
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.9)],
                startPoint: .center, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// VIS-08 (spec §6.2): how far down the page the title block starts, so the top ~40% of the
    /// backdrop shows above it the way the Apple TV app's product page does (the block's top lands
    /// near y = 420 with the 60 pt scroll padding and the 60 pt top safe area).
    private static let headerTopInset: CGFloat = 300

    /// VIS-08 (spec §6.2): the product-page block, in Apple TV app order: logo or title, one
    /// plain metadata line, the synopsis, then the button row (Play first, with default focus).
    /// The full genre list and the label/value facts moved to the information grid at the bottom
    /// of the page (`infoSection`).
    private var topBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            metaLine
            if let overview, !overview.isEmpty {
                // AES-10: four lines, with a More / Less button only when it overflows.
                DetailOverview(text: overview, maxWidth: 880)
            }
            actionRow
                .padding(.top, Theme.Spacing.sm)
        }
        .padding(.top, Self.headerTopInset)
        .focusSection()
    }

    @ViewBuilder
    private var header: some View {
        if let logoUrl, !logoUrl.isEmpty {
            // BUG-41: CachedAsyncImage over the raw AsyncImage — main-thread, uncached decodes on
            // every scroll-triggered re-render were one of the choppiness suspects. The failure
            // builder keeps the title-text fallback a plain AsyncImage gave on a bad logo URL; the
            // shimmer-during-load is the one deliberate visual delta from before (see report).
            CachedAsyncImage(string: logoUrl, contentMode: .fit, failure: {
                Text(title).font(Theme.Font.hero).foregroundStyle(Theme.Palette.textPrimary)
            })
            .frame(maxWidth: 600, maxHeight: 180, alignment: .leading)
            .accessibilityLabel(Text(verbatim: title))
        } else {
            Text(title).font(Theme.Font.hero).foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    /// Title facts handed to the player for its Info tab chips (same sources as `metaLine`).
    private var playbackMeta: PlaybackMeta {
        let rating: String? = model.meta?.imdbRating ?? preview.imdbRating
        return PlaybackMeta(
            year: { let s: String? = model.meta?.releaseInfo ?? preview.releaseInfo; return (s ?? "").isEmpty ? nil : s }(),
            runtime: { let s: String? = model.meta?.runtime; return (s ?? "").isEmpty ? nil : s }(),
            // SET-2: Overall Ratings off also keeps the rating chip out of the player's Info tab.
            imdbRating: model.showOverallRatings && !(rating ?? "").isEmpty ? rating : nil,
            ageRating: { let s: String? = model.meta?.ageRating; return (s ?? "").isEmpty ? nil : s }(),
            genres: genres
        )
    }

    /// VIS-08: year · up to two genres · runtime as one plain Callout line in `.secondary` (no
    /// chips, no glass), then the rating and the age-rating badge. The badge is the TV app's
    /// monochrome outlined capsule.
    private var metaFacts: [String] {
        var parts: [String] = []
        let year: String? = model.meta?.releaseInfo ?? preview.releaseInfo
        if let year, !year.isEmpty { parts.append(year) }
        parts.append(contentsOf: genres.prefix(2))
        let runtime: String? = model.meta?.runtime
        if let runtime, !runtime.isEmpty { parts.append(runtime) }
        return parts
    }

    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.md) {
            let facts = metaFacts
            if !facts.isEmpty {
                Text(verbatim: facts.joined(separator: " \u{00B7} "))
                    .lineLimit(1)
            }
            // SET-2: Settings → Appearance → Ratings → Overall Ratings.
            if model.showOverallRatings, let rating = model.meta?.imdbRating ?? preview.imdbRating, !rating.isEmpty {
                HStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Theme.Palette.star)
                        .accessibilityHidden(true)
                    Text(verbatim: rating)
                }
                .accessibilityElement(children: .combine)
            }
            if let age = model.meta?.ageRating, !age.isEmpty {
                Text(verbatim: age)
                    .font(Theme.Font.caption.weight(.bold))
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .strokeBorder(Theme.Palette.textSecondary, lineWidth: 1)
                    }
            }
            if model.isLoading { ProgressView() }
        }
        .font(Theme.Font.sectionTitle.weight(.regular))
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    /// The parental-guide chips' capsule. VIS-08 / spec gap 14: content gets no glass, so this is
    /// always the flat translucent fill the BUG-41 scroll legs used to swap in (the leg switch is
    /// moot now and `chipGlassFlat` only feeds the debug overlay).
    private func detailChipBackground(@ViewBuilder _ content: () -> some View) -> some View {
        content().background(Color.white.opacity(0.12), in: .capsule)
    }

    /// VIS-08 (spec §5.5): a large Play / Resume primary (first, wider, default focus), a text Trailer
    /// button, then round icon buttons for the library and watched toggles. All system button
    /// styles: no `GlassEffectContainer`, no glass, and no accent tint (the accent is reserved for
    /// progress and selection marks). Toggle state is shown by the symbol, never by colour alone.
    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.lg) {
            // F1: ONE primary button, always first and always present — movie, series loading,
            // series Resume/Play SxEy, or unavailable. It used to be two branches and, for a
            // series, absent until the details resolved, so a cold open put focus on Mark Watched
            // and an immediate Select marked the whole series watched. A single Button keeps its
            // identity (and focus) across those states. Never `.disabled`: a disabled button is
            // not focusable, which pushed focus onto the next button again (upstream 972109f9's
            // greyed-out Play); an unavailable press shows an explanation instead.
            Button {
                performPrimaryPlay()
            } label: {
                primaryActionLabel
                    .frame(minWidth: actionIconsOnly ? nil : 320)
            }
            // Spec §3.2: the white platter + black label is the FOCUSED look only. A solid white
            // resting Play made two white platters show whenever focus sat on another action, so
            // Play uses the system bordered style like its neighbours and stays the primary by
            // being first, wider and the default focus.
            .buttonStyle(.bordered)
            .focused($focusedAction, equals: .play)

            if model.trailerVideoURL != nil {
                // Explicit, focusable "watch it full screen" entry point (tester request — the
                // background hero loop is muted and deliberately NON-focusable). It hands the
                // already-resolved hero trailer to the same `trailerPlayback` full-screen-cover
                // machinery the "Trailers & Extras" row uses below.
                Button {
                    if let trailer = model.trailerVideoURL {
                        // C3: same video as the Detail hero background loop — the canonical
                        // title key is correct here (see `TrailerPlaybackItem.zoomKey`).
                        model.trailerPlayback = TrailerPlaybackItem(
                            id: "hero-trailer", url: trailer, title: title, zoomKey: model.trailerZoomKey,
                            videoId: model.trailerVideoId
                        )
                    }
                } label: {
                    actionLabel(
                        verbatim: String(localized: "detail.action.trailer", defaultValue: "Trailer",
                                         comment: "Detail page button that plays the title's trailer full screen"),
                        systemImage: "play.rectangle"
                    )
                        .font(Theme.Font.body)
                }
                .buttonStyle(.bordered)
                .focused($focusedAction, equals: .trailer)
            }

            Button {
                model.toggleLibrary()
            } label: {
                roundActionIcon(model.isSaved ? "checkmark" : "plus")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text(model.isSaved ? LocalizedStringKey("In Library") : LocalizedStringKey("Add to Library")))
            .focused($focusedAction, equals: .library)

            Button {
                requestToggleWatched()
            } label: {
                roundActionIcon(model.isWatched ? "eye.fill" : "eye")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text(model.isWatched ? LocalizedStringKey("Watched") : LocalizedStringKey("Mark Watched")))
            .focused($focusedAction, equals: .watched)
        }
        // BUG-44: no `.focusSection()` of its own — folded into `topBlock`'s single top-of-page
        // section so the section boundary can't fragment vertical navigation.
    }

    /// A round icon button's glyph, square so `.buttonBorderShape(.circle)` draws a true circle.
    private func roundActionIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(Theme.Font.body.weight(.semibold))
            .frame(width: roundActionIconSide, height: roundActionIconSide)
    }

    /// FEAT-9: the underlying `Label` for one action-row button — icon + text normally, icon-only
    /// (with the title preserved for VoiceOver) when `actionIconsOnly` is on. A localization key:
    /// FEAT-9 took the titles as plain `String`s, which `Label` shows verbatim, so the whole row
    /// ("Play", "Mark Watched", "Add to Library"…) stayed English on a French Apple TV.
    @ViewBuilder
    private func actionLabel(_ titleKey: LocalizedStringKey, systemImage: String) -> some View {
        let label = Label(titleKey, systemImage: systemImage)
        if actionIconsOnly {
            label.labelStyle(.iconOnly).accessibilityLabel(Text(titleKey))
        } else {
            label
        }
    }

    /// The primary Play button's label: "Play", or the series action's already-localized label —
    /// "Playback unavailable" instead once no configured source can stream it (upstream 972109f9).
    /// F1: while a series is still loading the slot already shows "Play" (dimmed), so the button
    /// keeps its place and width and the label only swaps once the episode action resolves.
    /// The system bordered style supplies the label colour for the resting and focused states.
    @ViewBuilder
    private var primaryActionLabel: some View {
        Group {
            switch primaryPlayState {
            case .unavailable:
                actionLabel("Playback unavailable", systemImage: "play.slash")
            case .series(_, let action):
                actionLabel(verbatim: action.label, systemImage: "play.fill")
            case .loading:
                actionLabel("Play", systemImage: "play.fill")
                    .opacity(0.6)
            case .movie:
                actionLabel("Play", systemImage: "play.fill")
            }
        }
        .font(Theme.Font.body.weight(.semibold))
    }

    /// `actionLabel` for a title that is already localized (the shared series action's
    /// "Resume S1E2" / "Next Up • S1E3").
    @ViewBuilder
    private func actionLabel(verbatim title: String, systemImage: String) -> some View {
        let label = Label(title, systemImage: systemImage)
        if actionIconsOnly {
            label.labelStyle(.iconOnly).accessibilityLabel(Text(verbatim: title))
        } else {
            label
        }
    }

    @ViewBuilder
    private var castRow: some View {
        let cast = model.meta?.cast ?? []
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Cast")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.lg) {
                        ForEach(Array(cast.enumerated()), id: \.offset) { index, person in
                            // Cast members carry a TMDB id only when TMDB enrichment is on; make those
                            // tappable to a person page, leave the rest as plain (non-focusable) cards.
                            if let personId = person.tmdbId?.value {
                                NavigationLink(value: PersonRoute(id: personId, name: person.name)) {
                                    // stillFocused: CastCard draws its own no-zoom still ring on
                                    // the avatar circle (Codex 2026-08-29 rounds 3-5) — focus
                                    // truth from the row's FocusState, not a second binding.
                                    CastCard(person: person, stillFocused: focusedCastIndex == index)
                                }
                                // Card-like navigation element: joins the no-zoom sweep so the
                                // setting stills every card on the page, not most (Codex 2026-08-29).
                                // BUG-108: same as FolderTile — the avatar owns its ring-mode lift now,
                                // so ring mode must take the native lift away (`.card`, the default).
                                // No `.posterButtonShape()` here on purpose: it sets a rounded-RECT
                                // border shape that only a system button style consumes, and the
                                // avatar is a circle.
                                .cardFocusButtonStyle()
                                .focused($focusedCastIndex, equals: index)
                                .zIndex(liftedCastZIndex(index))
                            } else {
                                CastCard(person: person)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    @ViewBuilder
    private var moreLikeThisRow: some View {
        let items = model.meta?.moreLikeThis ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("More Like This")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.lg) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink(value: TitleRoute(preview: item)) {
                                PosterCard(
                                    title: item.name,
                                    imageURL: item.poster,
                                    width: Theme.Size.miniPosterWidth,
                                    height: Theme.Size.miniPosterHeight
                                )
                            }
                            .cardFocusButtonStyle()
                            .posterButtonShape()
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // MARK: - Info section (director / writers / studios / networks / country / etc.)

    /// VIS-08 (spec §6.2): the information grid at the bottom of the page, the Apple TV product
    /// page's "Information" block. Three columns (560 pt each on the HIG grid), a Caption label
    /// over a Body value. Only populated fields are shown — director/writer/country come from the
    /// add-on; studios, networks, awards, language, status and external ratings fill in when TMDB
    /// enrichment is on. Not focusable: the last row's reveal brings it on screen.
    @ViewBuilder
    private var infoSection: some View {
        let rows = infoRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(String(localized: "detail.info.title", defaultValue: "Information",
                            comment: "Heading of the facts grid at the bottom of a title's detail page"))
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .topLeading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3),
                    alignment: .leading,
                    spacing: Theme.Spacing.lg
                ) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(row.label)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Text(row.value)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.top, Theme.Spacing.lg)
        }
    }

    private var infoRows: [InfoRow] {
        guard let meta = model.meta else { return [] }
        var rows: [InfoRow] = []
        func add(_ label: String, _ value: String) {
            if !value.isEmpty { rows.append(InfoRow(label: label, value: value)) }
        }
        // VIS-08: the meta line shows two genres at most; the full list lives here.
        add(String(localized: "Genres"), genres.joined(separator: ", "))
        add(String(localized: "Director"), meta.director.joined(separator: ", "))
        add(String(localized: "Writers"), meta.writer.joined(separator: ", "))
        add(String(localized: "Studios"), meta.productionCompanies.map { $0.name }.joined(separator: ", "))
        add(String(localized: "Network"), meta.networks.map { $0.name }.joined(separator: ", "))
        // Bare Kotlin `String?` reads can bridge as non-optional in this framework — widen before use.
        let country: String? = meta.country;   add(String(localized: "Country"), country ?? "")
        let language: String? = meta.language;  add(String(localized: "Language"), language ?? "")
        let status: String? = meta.status;      add(String(localized: "Status"), status ?? "")
        let awards: String? = meta.awards;      add(String(localized: "Awards"), awards ?? "")
        let ratings = meta.externalRatings
        if !ratings.isEmpty {
            add(String(localized: "Ratings"), ratings.map { "\($0.source) \(formatRating($0.value))" }.joined(separator: "   "))
        }
        return rows
    }

    private func formatRating(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    // MARK: - Collection row ("Part of the X Collection")

    /// The title's collection (e.g. sequels/prequels) as a saga row. TMDB-backed via
    /// `collectionItems` — stays hidden until TMDB enrichment is on.
    ///
    /// FEAT-34 (2026-09-08, Christian's decision, tester photo
    /// `docs/research/steven-beta18-photos/2026-09-08-official-nuvio-saga-row-landscape.jpg`):
    /// official Nuvio renders this row as 16:9 backdrop cards with the franchise's title-logo
    /// composited bottom-leading and film name + year captioned underneath, not the portrait
    /// `PosterCard` this row used before (see the superseded rc2 note below). `SagaCard`
    /// (`DesignSystem/SagaCard.swift`) is the dedicated card for this — it always shows its
    /// caption regardless of Hide Labels, same as the row's prior `showTitle: true` override, so
    /// the rc2 fix below carries forward unchanged.
    ///
    /// rc2 (u/mrStevenx3, 2026-09-06): "saga/franchise titles missing in the description — only
    /// images". He runs Hide Labels ON, and a row of bare sequel artwork says nothing about which
    /// film is which. On the description page this row is informational — like the Cast row,
    /// whose names always show — so it opts out of the setting.
    @ViewBuilder
    private var collectionRow: some View {
        let items = model.meta?.collectionItems ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(collectionTitle)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    // BUG-106: the ring-mode lift grows a 16:9 card ≈71 pt in width, so `lg` (24)
                    // put the raised card onto its neighbour — see `landscapeLiftRowGap`.
                    LazyHStack(spacing: Theme.Spacing.landscapeLiftRowGap) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink(value: TitleRoute(preview: item)) {
                                SagaCard(item: item)
                            }
                            .cardFocusButtonStyle()
                            .posterButtonShape()
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    private var collectionTitle: String {
        let name: String? = model.meta?.collectionName
        if let name, !name.isEmpty { return name }
        return String(localized: "Collection")
    }

    // MARK: - Company logos (studios & networks with TMDB logo art)

    /// Logo strip for the production companies/networks that carry TMDB logo art (the info rows
    /// above already list all of them by name). White chips keep the mostly-dark logos readable.
    /// Chips with a TMDB id push the studio/network browse page (`EntityRoute`).
    @ViewBuilder
    private var companyLogosRow: some View {
        let companies = companyLogos
        if !companies.isEmpty {
            // BUG-111: row spacing stays `Spacing.md` (16pt), unchanged — the widest chip is 180pt
            // of content plus `Spacing.md` (16pt) padding on each side (`CompanyChip`'s own
            // `.frame(maxWidth: 180)` + `.padding(.horizontal, Spacing.md)`) = 212pt, and its
            // ring-mode growth per side is `212 × 0.12 / 2 = 12.7pt` — inside the 16pt gap with
            // room to spare, so a lifted widest chip never touches its row neighbour.
            HStack(spacing: Theme.Spacing.md) {
                ForEach(Array(companies.enumerated()), id: \.offset) { index, entry in
                    if let tmdbId = entry.company.tmdbId?.value {
                        NavigationLink(value: EntityRoute(
                            id: tmdbId,
                            name: entry.company.name,
                            isNetwork: entry.isNetwork,
                            sourceType: model.meta?.type ?? preview.type
                        )) {
                            // stillFocused: CompanyChip draws its own ring/lift off the row's
                            // FocusState, same rule as CastCard above (Codex 2026-08-29
                            // rounds 3-5) — focus truth from the row, not a second binding.
                            companyChip(entry.company, stillFocused: focusedCompanyIndex == index)
                        }
                        // BUG-111: this used to be deliberately NOT cardFocusButtonStyle() (Codex
                        // 2026-08-29 P1) — the chip had no isFocused-dependent treatment of its
                        // own, so disabling the system effect in no-zoom mode would have left
                        // remote focus on this link with NO visible indication at all. The chip
                        // now owns a treatment in every non-default mode (`CompanyChip`'s ring +
                        // `.manualScale` lift), so it joins the same sweep `CastCard`/`FolderTile`
                        // already made — No Zoom now reaches this row too, and ring mode's manual
                        // lift replaces the native `.borderless` lift here exactly as it does for
                        // those two (the default `lift: .card`; see `CardButtonLift`).
                        .cardFocusButtonStyle()
                        .focused($focusedCompanyIndex, equals: index)
                        .zIndex(liftedCompanyZIndex(index))
                    } else {
                        companyChip(entry.company)
                    }
                }
            }
            .focusSection()
        }
    }

    private func companyChip(_ company: MetaCompany, stillFocused: Bool = false) -> some View {
        CompanyChip(company: company, stillFocused: stillFocused)
    }

    private var companyLogos: [(company: MetaCompany, isNetwork: Bool)] {
        guard let meta = model.meta else { return [] }
        var seen = Set<String>()
        let tagged = meta.productionCompanies.map { (company: $0, isNetwork: false) }
            + meta.networks.map { (company: $0, isNetwork: true) }
        return tagged.filter { entry in
            let logo: String? = entry.company.logo
            guard let logo, !logo.isEmpty, !seen.contains(entry.company.name) else { return false }
            seen.insert(entry.company.name)
            return true
        }
        .prefix(6).map { $0 }
    }

    // MARK: - Parental guide (IMDb parents-guide severities)

    @ViewBuilder
    private var parentalGuideSection: some View {
        let warnings = model.parentalWarnings
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Parental Guide")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        detailChipBackground {
                            HStack(spacing: Theme.Spacing.xs) {
                                Circle()
                                    .fill(severityColor(warning.severity))
                                    .frame(width: 12, height: 12)
                                Text(warning.label)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text(warning.severity)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .font(Theme.Font.caption)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                        }
                    }
                }
            }
        }
    }

    /// Severity strings come back as the labels we supplied (`parentalGuideLabels`).
    private func severityColor(_ severity: String) -> Color {
        switch severity {
        case "Severe": return .red
        case "Moderate": return .orange
        default: return .yellow
        }
    }

    // MARK: - Trailers & extras

    @ViewBuilder
    private var trailersRow: some View {
        let trailers = model.meta?.trailers ?? []
        if !trailers.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Trailers & Extras")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Spacing.rowGap) {
                        ForEach(Array(trailers.prefix(10).enumerated()), id: \.element.id) { _, trailer in
                            Button {
                                model.playTrailer(trailer)
                            } label: {
                                TrailerThumbCard(trailer: trailer, isResolving: model.resolvingTrailerId == trailer.id)
                            }
                            // BUG-93: TrailerThumbCard has no manual treatment - keep the native lift in ring mode.
                            .cardFocusButtonStyle(lift: .plain)
                            .posterButtonShape() // BUG-32: honor the Corners setting
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
                #if DEBUG
                // UX-10 diagnostic (invisible, harness-readable): rendered trailer count vs. how
                // many resolved a YouTube thumbnail, so a UITest can prove the shelf switched from
                // text rows to thumbnail cards without depending on pixel comparison.
                let rendered = Array(trailers.prefix(10))
                Text("debug_trailers n=\(rendered.count) thumbs=\(rendered.filter { $0.thumbnailURLString != nil }.count)")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_trailers")
                #endif
            }
            .focusSection()
        }
    }

    // MARK: - Trakt community comments

    @ViewBuilder
    private var commentsSection: some View {
        let comments = model.comments
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Comments")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(Array(comments.prefix(8).enumerated()), id: \.element.id) { _, comment in
                        commentCard(comment)
                    }
                }
                Text("From Trakt")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .focusSection()
        }
    }

    /// One comment as a focusable card. Pressing reveals spoilers / expands long text.
    private func commentCard(_ comment: TraktCommentReview) -> some View {
        let expanded = expandedComments.contains(comment.id)
        let hidesForSpoiler = (comment.spoiler || comment.hasSpoilerContent) && !expanded
        return Button {
            if expanded {
                expandedComments.remove(comment.id)
            } else {
                expandedComments.insert(comment.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.md) {
                    Text(comment.authorDisplayName)
                        .font(Theme.Font.meta)
                        .rowTextColor()
                    if let rating = comment.rating?.value {
                        HStack(spacing: 2) {
                            // BUG-50: the star's fixed gold (Theme.Palette.star) isn't a
                            // semantic color the row's colorScheme flip can fix, and reads as
                            // washed-out on the near-white focused platter. `rowAccentTint`
                            // preserves the gold at rest (active: false, inactiveColor: star)
                            // while forcing the platter-safe color on focus, same shape as
                            // BUG-22's row-icon fix.
                            Image(systemName: "star.fill")
                                .rowAccentTint(false, inactiveColor: Theme.Palette.star)
                            Text("\(rating)/10")
                        }
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                    }
                    if let date = commentDate(comment) {
                        Text(date)
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
                    }
                    if comment.review {
                        Text("Review")
                            .font(Theme.Font.caption)
                            .rowAccentTint()
                    }
                    Spacer(minLength: 0)
                    if comment.likes > 0 {
                        Label("\(comment.likes)", systemImage: "heart.fill")
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
                    }
                }
                if hidesForSpoiler {
                    Label("Contains spoilers \u{2014} press to reveal", systemImage: "eye.slash")
                        .font(Theme.Font.body)
                        .rowTextColor(secondary: true)
                } else {
                    Text(comment.comment)
                        .font(Theme.Font.body)
                        .rowTextColor()
                        .lineLimit(expanded ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.settingsRow)
    }

    private func commentDate(_ comment: TraktCommentReview) -> String? {
        let raw: String? = comment.createdAt
        guard let raw, raw.count >= 10 else { return nil }
        return String(raw.prefix(10))
    }

    // MARK: - Auto-play hero trailer

    /// (Re)starts the ~4s countdown once `model.trailerVideoURL` resolves. Every cancellation
    /// condition is re-checked once the timer actually fires, since a lot can change in 4 seconds.
    private func scheduleAutoPlayTrailerIfNeeded() {
        // F2: opt-in only (`detail_trailer_autoplay`, default off per D5) and never under Reduce
        // Motion; `userInteracted` now also flips on any focus change (see `focusedAction`).
        guard trailerAutoplayEnabled, !reduceMotion, !didAutoPlayTrailer, !userInteracted,
              !showStreams, seriesPlay == nil, model.trailerPlayback == nil else { return }
        autoPlayTrailerTask?.cancel()
        autoPlayTrailerTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { fireAutoPlayTrailer() }
        }
    }

    private func fireAutoPlayTrailer() {
        guard trailerAutoplayEnabled, !reduceMotion, !didAutoPlayTrailer, !userInteracted,
              !showStreams, seriesPlay == nil, model.trailerPlayback == nil,
              let trailer = model.trailerVideoURL else { return }
        didAutoPlayTrailer = true
        trailerPlaybackIsAutoPlay = true
        // The exact same assignment the "Watch Trailer" button makes (see the action row above) —
        // reuses its whole `fullScreenCover` path (background-player teardown, the
        // mute-reset-on-dismiss dance) for free. Neither this nor the button touches
        // `HeroTrailerAudioState`: `FullScreenTrailerPlayer` is a brand-new `AVPlayer` instance that
        // is never muted, so both entries already play with sound without any extra unmuting.
        // C3: same video as the Detail hero background loop — the canonical title key is correct
        // here (see `TrailerPlaybackItem.zoomKey`).
        model.trailerPlayback = TrailerPlaybackItem(
            id: "hero-trailer", url: trailer, title: title, zoomKey: model.trailerZoomKey,
            videoId: model.trailerVideoId
        )
    }

    private func cancelAutoPlayTrailer() {
        autoPlayTrailerTask?.cancel()
        autoPlayTrailerTask = nil
    }

    // MARK: - FEAT-8: background-trailer duration

    /// One-shot per detail visit — starts the configured countdown once the background trailer
    /// becomes active (mirrors `scheduleAutoPlayTrailerIfNeeded`'s shape). `trailerDurationSeconds
    /// == 0` means "play forever" (the original behavior), so nothing is scheduled.
    private func scheduleTrailerDurationTimerIfNeeded() {
        guard trailerDurationSeconds > 0, !backgroundTrailerStopped else { return }
        trailerDurationTask?.cancel()
        let seconds = trailerDurationSeconds
        trailerDurationTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { stopBackgroundTrailer() }
        }
    }

    /// Fades the background trailer back to the still backdrop. Deliberately slower than the
    /// ordinary 0.8s crossfade — the slow 1.5s fade back to the still artwork IS the "smoother
    /// return to backdrop" this feature asks for. Never touches `model.trailerVideoURL`: that still
    /// gates the "Watch Trailer" button, so the trailer stays one tap away after it stops.
    private func stopBackgroundTrailer() {
        withAnimation(.easeInOut(duration: 1.5)) {
            backgroundTrailerStopped = true
        }
    }

    private func cancelTrailerDurationTask() {
        trailerDurationTask?.cancel()
        trailerDurationTask = nil
    }

    /// "Press Back to exit the trailer" — shown only for the auto-play entry (not the explicit
    /// "Watch Trailer" button or a "Trailers & Extras" item), fading out on its own after ~4s.

}

/// F1: the Detail action-row buttons `DetailView.focusedAction` tracks.
private enum DetailActionFocus: Hashable {
    case play, trailer, watched, library
}

/// One label/value pair in the Detail info block. `id` is the label (unique within the block).
private struct InfoRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// Circular cast avatar + name/role. Platter-free: used inside a `.poster`-styled NavigationLink
/// when tappable, so it supplies its own focus visuals (ring + scale + shadow); rendered bare for
/// non-tappable cast, where `isFocused` simply never fires.
private struct CastCard: View {
    let person: MetaPerson
    /// Caller-supplied focus truth for the no-zoom still ring (Codex 2026-08-29 rounds 3-5):
    /// with the system focus effect disabled this card's only treatment was caption opacity, and
    /// the generic outer-bounds ring wrapped the whole lockup — the ring belongs on the avatar
    /// circle, whose geometry only this view knows.
    var stillFocused: Bool = false

    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    /// BUG-102 (rc9): same gap as `FolderTile` — the avatar only knew the no-zoom still ring, so
    /// with zoom on and the accent ring on it drew nothing. Resolved through `PlainLabelRing`.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reservesRingBand: Bool {
        PlainLabelRing.reservesBand(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    /// BUG-108: same architecture as `FolderTile` — ring mode takes the native `.borderless` lift
    /// away from this label, so the avatar lifts itself and carries its ring up with it.
    private var artworkLift: CardFocusMode {
        PlainLabelRing.lift(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            // BUG-41: CachedAsyncImage over the raw AsyncImage (cast rows re-decoded every photo on
            // every scroll-triggered re-render before this). `person.photo` empty/nil is guarded
            // outside the image (matching the old `URL(string: "")` == nil no-fetch behavior) so the
            // person glyph appears immediately rather than after a load attempt.
            Group {
                if let photo = person.photo, !photo.isEmpty {
                    CachedAsyncImage(string: photo, contentMode: .fill, failure: { CastCard.personFallback })
                } else {
                    CastCard.personFallback
                }
            }
            .frame(width: Theme.Size.castAvatar, height: Theme.Size.castAvatar)
            .clipShape(Circle())
            .nuvioCardDepth(Circle(), surface: .cast)
            // 2026-08-30 no-zoom investigation: same overpaint/fix as TileFocusLift/FolderTile —
            // the ring used to strokeBorder straight over the avatar's own true edge. Static,
            // never-focus-linked shrink (matches `ringInset`'s "always reserved, never pops"
            // contract) so the `.overlay` below measures the avatar's TRUE, unscaled bounds. A
            // single scalar is enough — the avatar is always a perfect circle/square.
            // BUG-102: band reserved whenever a ring may draw (`ringInset`'s rule), as FolderTile.
            .scaleEffect(reservesRingBand && Theme.Size.castAvatar > 0
                ? max(0, Theme.Size.castAvatar - 2 * ringWidth) / Theme.Size.castAvatar
                : 1)
            .overlay {
                if let ring = PlainLabelRing.resolve(accentFocusRing: accentFocusRing,
                                                     noZoomOnFocus: noZoomOnFocus,
                                                     focused: stillFocused) {
                    Circle().strokeBorder(ring.color, lineWidth: ringWidth)
                }
            }
            .modifier(CardArtworkFocusLift(
                mode: artworkLift,
                isFocused: stillFocused,
                artworkHeight: Theme.Size.castAvatar,
                // `CardArtworkFocusLift.manualScale` draws its platter as a
                // `RoundedRectangle(cornerRadius:)` at the attached view's bounds. The bounds here
                // are the avatar's 140×140 square, and a rounded rect of half that side IS that
                // square's inscribed circle — so the platter and its shadow follow the photo's own
                // edge instead of a square behind it. Derived from the constant, never literal 70.
                cornerRadius: Theme.Size.castAvatar / 2
            ))
            VStack(spacing: Theme.Spacing.xs) {
                Text(person.name)
                    .font(Theme.Font.caption)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textPrimary.opacity(0.9))
                    .lineLimit(1)
                    .frame(width: Theme.Size.castAvatar + 10)
                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(width: Theme.Size.castAvatar + 10)
                }
            }
            // BUG-108: the avatar grows downward by the same 20pt it rises, so name+role follow it
            // together — one modifier on the pair, so the two lines can never drift apart. 0 in
            // both other modes.
            .modifier(CardCaptionFocusDrop(mode: artworkLift, isFocused: stillFocused,
                                           artworkHeight: Theme.Size.castAvatar))
        }
        // BUG-108: gated on Reduce Motion now that this wraps a manual `.scaleEffect` — see
        // `CardArtworkFocusLift`, which passes a nil animation there and would be overridden here.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
    }

    /// BUG-41 failure/no-photo fallback — pulled out of `body` so both the "no `person.photo`"
    /// branch and `CachedAsyncImage`'s `failure:` builder render the identical glyph.
    @ViewBuilder
    private static var personFallback: some View {
        ZStack {
            Theme.Palette.surface
            Image(systemName: "person.fill")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

/// BUG-111: geometry constants `CompanyChip` derives its ring/lift geometry from, pulled out so
/// `PlainLabelRingTests` can assert the derived numbers directly against a named source of truth
/// instead of hand-deriving them from literals buried inside the view. `internal` (not `private`)
/// for exactly that reason — `@testable import` needs to reach it — but the values remain one
/// view's own implementation detail; nothing else in the app should reference these.
enum CompanyChipMetrics {
    /// The logo/name content's fixed height — `CompanyChip`'s pre-existing `.frame(height:)`.
    static let logoHeight: CGFloat = 36
    /// The capsule's true rendered height: the logo height plus the vertical padding on both
    /// edges (`Theme.Spacing.xs`, 8pt) `CompanyChip` already applies outside that frame. This, not
    /// `logoHeight`, is the artwork height the ring/lift geometry must key off — the ring traces
    /// the CAPSULE `CompanyChip.body` backgrounds itself with, not the logo image inside it.
    /// 36 + 2×8 = 52.
    static let capsuleHeight: CGFloat = logoHeight + 2 * Theme.Spacing.xs
    /// The chip's platter is a `Capsule()` — a rounded rect whose corner radius is exactly half
    /// its own height. 52 / 2 = 26.
    static let platterCornerRadius: CGFloat = capsuleHeight / 2
    /// BUG-111: this chip's own small-label rise — see `PlainLabelRing.smallLabelRise`, whose
    /// existence this chip is the reason for. ≈3.12pt at this capsule's 52pt height, which is
    /// exactly the height at which the derived scale (`cardLiftScale`) equals
    /// `PlainLabelRing.smallLabelScaleCeiling` (1.12).
    static let focusRise: CGFloat = PlainLabelRing.smallLabelRise(height: capsuleHeight)
}

/// Studio/network logo chip. Keeps the intentional white capsule (logo legibility); focus reads as
/// scale + the brand focus ring, platter-free like every other tile.
///
/// BUG-111 (rc12, u/mrStevenx3: focusing a studio chip "zooms in on the poster instead of the
/// description"): until this fix the chip was the ONLY card-like site left on a bare
/// `.buttonStyle(.borderless)` (see the 2026-08-29 comment this replaced at the row's call site) —
/// it drew no ring and no lift of its own, so `.borderless`'s system treatment always won, and
/// turning No Zoom on reached every other card on the page except this one. It now joins the same
/// `PlainLabelRing` architecture `FolderTile`/`CastCard` got in BUG-102/BUG-108, scaled down to
/// its own much shorter capsule via `CompanyChipMetrics`/`PlainLabelRing.smallLabelRise`.
private struct CompanyChip: View {
    let company: MetaCompany
    /// Caller-supplied focus truth — same rule as `CastCard.stillFocused` (Codex 2026-08-29
    /// rounds 3-5): the row owns one `FocusState` (`focusedCompanyIndex`), and this label draws
    /// its ring/lift off that instead of installing a second `.focused` binding that would
    /// collide with it.
    var stillFocused: Bool = false

    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    /// BUG-111: same gap BUG-102 closed for `FolderTile`/`CastCard` — resolved through
    /// `PlainLabelRing`, shared precedence.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// BUG-111: same architecture as `FolderTile`/`CastCard` — ring mode takes the native
    /// `.borderless` lift away from this label (`cardFocusButtonStyle`'s default `lift: .card`),
    /// so the chip must draw its own in that mode and stay a no-op in the other two.
    private var artworkLift: CardFocusMode {
        PlainLabelRing.lift(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    var body: some View {
        // BUG-41: CachedAsyncImage over the raw AsyncImage (company logos re-decoded on every
        // scroll-triggered re-render before this). `company.logo` empty/nil guarded outside the
        // image, matching the old `URL(string: "")` == nil no-fetch behavior.
        Group {
            if let logo = company.logo, !logo.isEmpty {
                CachedAsyncImage(string: logo, contentMode: .fit, failure: { CompanyChip.nameFallback(company.name) })
            } else {
                CompanyChip.nameFallback(company.name)
            }
        }
        .frame(height: CompanyChipMetrics.logoHeight)
        .frame(minWidth: 60, maxWidth: 180)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Color.white.opacity(0.92), in: Capsule())
        // BUG-111: deliberately NO band inset here, unlike `FolderTile`/`CastCard`'s `ringInset`
        // shrink. This chip's outer band is already white PADDING, not artwork: the vertical
        // margin is `Theme.Spacing.xs` (8pt) and the horizontal is `Theme.Spacing.md` (16pt),
        // both ≥ `ringWidth` (4pt), so the ring lands inside the capsule's own filler and never
        // overpaints the logo — the BUG-64 overpaint `ringInset` exists to avoid never had a
        // chance to happen here in the first place. Reserving a second band on top of that would
        // ALSO break capsule/ring concentricity: unlike the avatar's perfect circle, this capsule
        // is not square, so a per-axis shrink (the mechanism `FolderTile`/`CastCard` use) would
        // turn the shrunk capsule into a different aspect ratio than the platter it sits inside.
        .overlay {
            if let ring = PlainLabelRing.resolve(accentFocusRing: accentFocusRing,
                                                 noZoomOnFocus: noZoomOnFocus,
                                                 focused: stillFocused) {
                // BUG-111 review finding 1: this capsule is a WHITE surface
                // (`Color.white.opacity(0.92)` above) — the only one among the plain-label ring
                // sites (`FolderTile`, `CastCard` both sit on dark artwork), so the still-mode
                // ring needs the light-surface neutral, not `stillHighlight`'s near-white. The
                // accent ring is unaffected — `ring.color` still drives it.
                Capsule().strokeBorder(
                    ring == .accent ? ring.color : PlainLabelRing.stillColor(onLightSurface: true),
                    lineWidth: ringWidth
                )
            }
        }
        .modifier(DebugAXIdentifier("company_artwork"))
        .modifier(CardArtworkFocusLift(
            mode: artworkLift,
            isFocused: stillFocused,
            // `CompanyChipMetrics.capsuleHeight`/`.platterCornerRadius`: the CAPSULE's true
            // rendered box, not the 36pt logo frame inside it — the same "measure the box the
            // ring traces" convention `FolderTile`/`CastCard` follow.
            artworkHeight: CompanyChipMetrics.capsuleHeight,
            cornerRadius: CompanyChipMetrics.platterCornerRadius,
            // BUG-111: the whole reason `CardArtworkFocusLift.rise` and
            // `PlainLabelRing.smallLabelRise` exist — the flat 20pt every other card class rises
            // by would more than double this 52pt capsule (`1 + 2×20/52 ≈ 1.77`) inside a 16pt
            // row gap; see `PlainLabelRing.smallLabelScaleCeiling`'s doc comment for the math.
            rise: CompanyChipMetrics.focusRise
        ))
        .modifier(DebugAXIdentifier("company_card"))
        // No `CardCaptionFocusDrop` — the chip has no caption slot below it to drop. No
        // `.posterButtonShape()` — that sets a rounded-RECT border shape only a system button
        // style consumes, and ring mode installs `RingCardButtonStyle`, a custom style that
        // receives no system treatment at all (same reasoning `CastCard`'s circular avatar rests
        // on, just applied to this capsule instead). No `.nuvioCardDepth` — the shared Kotlin
        // `NuvioCardDepthSurface` enum (mirrored here as `CardDepthSurface`) has no `.companies`
        // case, so there is nothing for this chip to opt into; the depth-rail contract is
        // untouched by this fix.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: stillFocused)
    }

    @ViewBuilder
    private static func nameFallback(_ name: String) -> some View {
        Text(name)
            .font(Theme.Font.caption)
            .foregroundStyle(.black)
    }
}

/// Identifiable wrapper so the series primary action can drive `.fullScreenCover(item:)`.
private struct SeriesPlayRoute: Identifiable {
    let meta: MetaDetails
    let action: SeriesPrimaryAction
    var id: String { action.videoId }

    /// The resolved episode (by season/episode number) — the Info header shows ITS still +
    /// overview, not the series poster/synopsis, matching the EpisodesSection launch path.
    private var episode: MetaVideo? {
        guard let s = action.seasonNumber?.value, let e = action.episodeNumber?.value else { return nil }
        return meta.videos.first { $0.season?.value == s && $0.episode?.value == e }
    }
    /// Episode still (action's, else the resolved episode's); blank addon values count as missing.
    var episodeStill: String? {
        let still: String? = action.episodeThumbnail
        if let still, !still.isEmpty { return still }
        let epStill: String? = episode?.thumbnail
        return (epStill ?? "").isEmpty ? nil : epStill
    }
    var synopsis: String? {
        let overview: String? = episode?.overview
        if let overview, !overview.isEmpty { return overview }
        let d: String? = meta.description_
        return d
    }
    /// The episode's own name (the action's, else the resolved episode's) — CW-1.
    var episodeName: String? {
        let name: String? = action.episodeTitle
        if let name, !name.isEmpty { return name }
        let fallback: String? = episode?.title
        return (fallback ?? "").isEmpty ? nil : fallback
    }

    /// "S1E1 · Pilot"-style picker title (falls back to the action label).
    var pickerTitle: String {
        if let s = action.seasonNumber?.value, let e = action.episodeNumber?.value {
            let name: String? = action.episodeTitle
            if let name, !name.isEmpty { return "S\(s)E\(e) \u{00B7} \(name)" }
            return "S\(s)E\(e)"
        }
        return action.label
    }
}
