import SwiftUI
import UIKit

/// BUG-66 (u/mrStevenx3, open since beta.13): on his Apple TV the system tab bar never minimizes
/// when Home scrolls; the simulator's does. `.tabBarMinimizeBehavior` is unavailable on tvOS and
/// nothing in the app has ever captured the bar's actual state on hardware — the existing
/// `TabBarProbe` (`TabBarVisibility.swift`, the About pane's "Tab Bar Diagnostics" toggle) only
/// ever read a scroll-view's own offset/inset, which tracks the HYSTERESIS this app applies, not
/// whether the SYSTEM bar itself visually minimized. This probe records the bar's own GEOMETRY
/// over time — read straight off the live `UITabBar`, the way `SidebarOverlay`'s
/// `HiddenTabBarFocusBlocker` locates it — so a photo of the About pane answers, for the first
/// time, whether the bar ever minimizes on the device and what Home's scroll state was when it
/// did or did not. Diagnostics only: it installs nothing that changes layout or focus.
///
/// Deliberately its own type, key, and toggle rather than folding into `TabBarProbe` above:
/// that probe's contract is a live in-memory counter snapshot with no persistence (see its own
/// doc comment — "nothing here touches UserDefaults"), while this one needs the exact
/// `PinnedRowSettleProbe` head-preserving persisted-buffer shape (armed at launch, survives a
/// backgrounding between the walk and reaching Settings, paged for the same clipped-`List`-row
/// reason BUG-100/102 fixed there). Mixing the two shapes into one type would have meant either
/// persisting the live counters (a contract `TabBarProbe`'s own doc comment explicitly says it
/// does not have) or losing this probe's relaunch-survivable buffer.
///
/// NAMING NOTE (implementer's judgment call, 2026-09-10): the About pane already has a toggle
/// titled "Tab Bar Diagnostics" bound to the persisted key `debug.tabBarProbe` (driving
/// `TabBarProbe` above), and `Localizable.xcstrings` already carries fr/de/es/it/vi translations
/// for that exact string. This probe therefore uses a distinct toggle title ("Tab Bar Geometry
/// Diagnostics") and a distinct persisted key (`debug.tabBarStateProbe`) so the two features never
/// collide — same About pane, two different rows, two different photographable protocols.
///
/// Line format (one per sample, newest first in the pane once paged the way
/// `PinnedRowSettleProbe.displayPages` already does):
///     minY=<pt> h=<pt> alpha=<0.00-1.00> hidden=<0/1> state=<expanded|minimized|partial|unknown>
///     scrolledDown=<0/1> mode=<classic|sidebar> reason=<arm|tick|down|up>
/// `t=<ms since arm>` is realized as the standard `<N>ms ` prefix `log(_:)` stamps on every line —
/// the same convention `PinnedRowSettleProbe.log` uses (its own call sites never repeat the
/// timestamp again inline either) — rather than a duplicated inline field.
///
/// `state` is derived against the TOP edge — this app's tab bar sits at the top of the screen, not
/// the bottom, so "minimized" here means the bar has moved UP out of view, not down. `expanded`:
/// the bar's frame (converted to window coordinates) is fully on screen at the top (`minY >= -1`
/// and `maxY > 0`), visible (`alpha > 0.5`) and not hidden. `minimized`: the bar has moved up out
/// of view or collapsed (`maxY <= h * 0.5`, or `alpha < 0.05`, or `isHidden`). `unknown`: no
/// `UITabBar` was found for this sample (see the `NOT-FOUND` line below) or this is a sample taken
/// before the bar has ever reported a nonzero frame. Anything else is `partial` — a bar mid
/// transition. `scrolledDown`/`mode` are
/// fed in by `TabBarVisibility.swift`'s `TabBarScrollAutoHide` on a real hysteresis crossing (see
/// `noteScrollState` below) and held for every sample taken after that until the next crossing.
/// `mode` can only distinguish `sidebar`/`classic` at that call site (`SidebarChrome.isEnabled()`)
/// — there is no separate "pinned" tab-bar concept reachable from there, so the spec's third value
/// is never emitted; this is a deliberate simplification, not an oversight. Samples on every
/// scroll-state crossing and every 2 s otherwise.
enum TabBarStateProbe {

    /// Read ONCE at first access, like every other launch-latched probe knob in this tree
    /// (`HomeHeroProbe`, `PinnedRowSettleProbe`, `TrailerProbe`, `CollectionFocusAB`) — hence the
    /// "relaunch" language in the About pane's subtitle. `UserDefaults.bool(forKey:)` also coerces
    /// the String "YES" a `-debug.tabBarStateProbe YES` launch argument lands in the argument
    /// domain, so the harness can arm it without a `defaults write`.
    ///
    /// VIS-01: also requires the hidden Developer pane to be unlocked (`DeveloperMode.isUnlocked`),
    /// so a public build never arms the sampler, even with a stale `debug.tabBarStateProbe` left
    /// over from an earlier tester build. The harness passes `-developer.unlocked YES` alongside
    /// the probe argument (same argument-domain coercion as above).
    nonisolated static let enabled = DeveloperMode.isUnlocked
        && UserDefaults.standard.bool(forKey: "debug.tabBarStateProbe")

    nonisolated static let linesKey = "debug.tabBarStateProbe.lines"

    /// Frozen arm-time head — never evicted. Holds the first few samples (arm + the earliest
    /// crossings). Same sizing as `PinnedRowSettleProbe`: a 6-row walk down and back is a small,
    /// bounded number of crossings plus the 2 s ticks in between, so 12 head / 28 tail (40 total)
    /// covers the same capture protocol shape ("walk down every row and back up").
    nonisolated static let headMaxLines = 12
    /// Rolling recent window. Holds the end of the walk, where the tester's most recent action is.
    nonisolated static let tailMaxLines = 28

    nonisolated(unsafe) private static var headLines: [String] = []
    nonisolated(unsafe) private static var tailLines: [String] = []
    /// Lines dropped from the tail stream once `tailLines` is full. Stays 0 (no marker rendered)
    /// until eviction genuinely begins. Same shape as `PinnedRowSettleProbe.elidedTailCount`.
    nonisolated(unsafe) private static var elidedTailCount = 0
    nonisolated private static let bufferLock = NSLock()

    /// Set once by `arm(in:)`; every stamped line's `<N>ms` prefix is ms since THIS, not process
    /// launch — the spec's line format calls for "ms since arm", and arming can lag launch by a
    /// SwiftUI render pass or two.
    nonisolated(unsafe) private static var armStart: Date?
    /// Weak so the probe can never keep the app's root window alive — the type doc's explicit
    /// requirement.
    nonisolated(unsafe) private static weak var armedWindow: UIWindow?
    nonisolated(unsafe) private static var timer: Timer?
    /// Held across samples between crossings, per the line-format doc above.
    nonisolated(unsafe) private static var lastScrolledDown = false
    nonisolated(unsafe) private static var lastMode = "unknown"

    nonisolated private static var sinceArmMs: Int {
        guard let armStart else { return 0 }
        return Int(Date().timeIntervalSince(armStart) * 1000)
    }

    /// TEST ONLY, mirrors `PinnedRowSettleProbe.resetForTesting()`: clears the process-global
    /// buffer and its persisted mirror. Never called from app code — the head is frozen by design
    /// for the tester's photo. Does not touch `armStart`/`armedWindow`/`timer`: a test exercising
    /// the buffer shape has no window to arm against and only needs `log`/`lines`.
    nonisolated static func resetForTesting() {
        bufferLock.lock()
        headLines.removeAll()
        tailLines.removeAll()
        elidedTailCount = 0
        bufferLock.unlock()
        UserDefaults.standard.removeObject(forKey: linesKey)
    }

    /// Appends `line`, stamped with its milliseconds-since-arm, to the persisted head-preserving
    /// ring buffer. Identical shape to `PinnedRowSettleProbe.log` — see that function's doc
    /// comment for the write-through-on-every-call rationale (the capture protocol survives a
    /// backgrounding between the walk and reaching Settings).
    nonisolated static func log(_ line: String) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let stamped = "\(sinceArmMs)ms \(line)"
        if headLines.count < headMaxLines {
            headLines.append(stamped)
        } else {
            tailLines.append(stamped)
            if tailLines.count > tailMaxLines {
                tailLines.removeFirst()
                elidedTailCount += 1
            }
        }
        var display = headLines
        if elidedTailCount > 0 {
            display.append("\u{2026} \(elidedTailCount) lines elided \u{2026}")
        }
        display.append(contentsOf: tailLines)
        UserDefaults.standard.set(display, forKey: linesKey)
    }

    /// Persisted lines in the order `log(_:)` wrote them (chronological), for the About pane to
    /// read on `.onAppear` — exactly like `heroProbeLines`/`rowSettleProbeLines` there. Reordering
    /// into newest-first/paged form is `PinnedRowSettleProbe.displayOrder`/`displayPages`, reused
    /// as-is (see this type's own doc comment on why nothing needed duplicating).
    nonisolated static var lines: [String] {
        UserDefaults.standard.stringArray(forKey: linesKey) ?? []
    }

    /// Starts the 2 s sampling timer against `window`. Re-armable — a later call (e.g. the armer
    /// re-attaching to a new window) invalidates any existing timer first and replaces it, rather
    /// than being a no-op forever after the first arm. No-ops entirely when the probe is off, so an
    /// armer mounted unconditionally in the view tree costs nothing beyond the one `enabled` read.
    ///
    /// Must be called on the main thread — `Timer`/`RunLoop.main` and the `UIKit` walk in
    /// `sample(reason:)` both require it, matching every call site this is invoked from
    /// (`TabBarProbeArmer`'s `UIView.didMoveToWindow`, always on main).
    static func arm(in window: UIWindow?) {
        guard enabled, let window else { return }
        timer?.invalidate()
        armedWindow = window
        armStart = Date()
        sample(reason: "arm")
        let ticker = Timer(timeInterval: 2.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                TabBarStateProbe.sample(reason: "tick")
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    /// Invalidates and clears the sampling timer and the weak window reference, and logs the
    /// disarm so the pane's trace shows why sampling stopped instead of just trailing off. Called
    /// from `ArmerView.didMoveToWindow` when the armer leaves its window (e.g. torn down between
    /// tab switches) — without this the old timer kept firing against a window the armer no longer
    /// tracks until ARC happened to deinit it.
    static func disarm() {
        timer?.invalidate()
        timer = nil
        armedWindow = nil
        log("NOT-FOUND state=unknown reason=window-removed")
    }

    /// Fed by `TabBarVisibility.swift`'s `TabBarScrollAutoHide` on a real hysteresis crossing
    /// (never per scroll-geometry tick — see that call site's own comment). Records the new state
    /// for every sample taken from here on and immediately takes one, so the pane shows the bar's
    /// geometry AT the moment Home's scroll state actually changed, not just whatever the next 2 s
    /// tick happens to catch.
    static func noteScrollState(isScrolledDown: Bool, mode: String) {
        guard enabled else { return }
        lastScrolledDown = isScrolledDown
        lastMode = mode
        sample(reason: isScrolledDown ? "down" : "up")
    }

    /// Walks the armed window's controller tree for the first `UITabBar` (same recursive shape as
    /// `SidebarOverlay.HiddenTabBarFocusBlocker.findTabBarController` — children first, presented
    /// controller last), reads its frame in WINDOW coordinates, alpha, and `isHidden`, computes
    /// `minimized`, and logs one line. Logs a `NOT-FOUND` line instead of silently doing nothing
    /// when no `UITabBarController` is found (sidebar mode legitimately has none — the system bar
    /// is force-hidden and unfocusable there, see `HiddenTabBarFocusBlocker`), mirroring that
    /// type's own "say so instead of silently doing nothing" house rule.
    static func sample(reason: String) {
        guard enabled else { return }
        guard let window = armedWindow else {
            log("NOT-FOUND why=no-window state=unknown mode=\(lastMode) reason=\(reason)")
            return
        }
        guard let bar = findTabBar(in: window) else {
            log("NOT-FOUND why=no-tabbar state=unknown mode=\(lastMode) reason=\(reason)")
            return
        }
        let frameInWindow = bar.convert(bar.bounds, to: window)
        let minY = frameInWindow.minY
        let maxY = frameInWindow.maxY
        let h = frameInWindow.height
        let alpha = bar.alpha
        let state: String
        if h <= 0 {
            // No nonzero frame reported yet — too early to classify.
            state = "unknown"
        } else if minY >= -1 && maxY > 0 && alpha > 0.5 && !bar.isHidden {
            state = "expanded"
        } else if maxY <= h * 0.5 || alpha < 0.05 || bar.isHidden {
            state = "minimized"
        } else {
            state = "partial"
        }
        log(
            "minY=\(Int(minY.rounded())) h=\(Int(h.rounded())) "
                + "alpha=\(String(format: "%.2f", alpha)) hidden=\(bar.isHidden ? 1 : 0) "
                + "state=\(state) scrolledDown=\(lastScrolledDown ? 1 : 0) "
                + "mode=\(lastMode) reason=\(reason)"
        )
    }

    private static func findTabBar(in window: UIWindow) -> UITabBar? {
        guard let root = window.rootViewController else { return nil }
        return findTabBarController(from: root)?.tabBar
    }

    /// Children first, presented controllers last — identical precedence to
    /// `SidebarOverlay.HiddenTabBarFocusBlocker.findTabBarController`, duplicated here rather than
    /// shared because that one is `private` inside a `private final class` in a file this task is
    /// not allowed to touch.
    private static func findTabBarController(from controller: UIViewController) -> UITabBarController? {
        if let tab = controller as? UITabBarController { return tab }
        for child in controller.children {
            if let hit = findTabBarController(from: child) { return hit }
        }
        if let presented = controller.presentedViewController {
            return findTabBarController(from: presented)
        }
        return nil
    }
}

/// Zero-sized `UIViewRepresentable` that arms `TabBarStateProbe` once it lands in a window.
/// Mounted on `MainTabView`'s `TabView` in `ContentView.swift` — a host reachable without touching
/// `HomeView.swift`, which this task may not edit. `didMoveToWindow` can fire before the view is
/// fully attached to the responder chain on some SwiftUI/UIKit interleavings, hence the deferred
/// `DispatchQueue.main.async` before reading `window` again, matching the defensive pattern
/// `SidebarOverlay.HiddenTabBarFocusBlocker.BlockerView` uses for the same reason.
///
/// VIS-01: inert unless the Developer pane is unlocked — `TabBarStateProbe.enabled` folds in
/// `DeveloperMode.isUnlocked`, and `didMoveToWindow` returns before touching the probe otherwise.
struct TabBarProbeArmer: UIViewRepresentable {
    func makeUIView(context: Context) -> ArmerView { ArmerView() }
    func updateUIView(_ uiView: ArmerView, context: Context) {}

    final class ArmerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard TabBarStateProbe.enabled else { return }
            if window == nil {
                TabBarStateProbe.disarm()
                return
            }
            DispatchQueue.main.async { [weak self] in
                TabBarStateProbe.arm(in: self?.window)
            }
        }
    }
}
