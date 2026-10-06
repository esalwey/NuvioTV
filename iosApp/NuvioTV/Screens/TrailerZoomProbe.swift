import Foundation

/// BUG-81/Wave F item C: release-safe diagnostics for the trailer letterbox-zoom pipeline
/// (`TrailerHeroPlayerView.swift`), following the exact house pattern of `StreamProbe`
/// (`StreamProbe.swift`) and `HomeHeroProbe`.
///
/// `debug.trailerProbe` (the console-only knob, `TrailerDebugProbes.swift`) can't be set on a
/// tester's release sideload — no `defaults write` access — so BUG-81's own investigation stalled
/// on "we can't see what his device measured." This buffer is a SECOND, independent gate
/// (`debug.trailerDiagnostics`, the About > Trailer Diagnostics toggle) that a tester CAN flip from
/// inside the app, with a live 1 Hz readout the same pane already renders for Stream/Tab Bar
/// diagnostics.
///
/// Every `[TrailerZoom]` NSLog call site in `TrailerHeroPlayerView.swift` funnels through
/// `log(_:)` — the console stream stays byte-identical to before this type existed (an NSLog fires
/// exactly when `TrailerProbe.enabled` would have logged it), and the buffer is populated
/// independently whenever the About toggle is on, whether or not the console knob is.
///
/// NSLock-guarded rather than `@MainActor`, matching `TrailerZoomCache`/`TrailerPipelineCounters`
/// in this same file: the trailer pipeline's own call sites fire from `Timer` callbacks,
/// `UIView.layoutSubviews`, and `deinit` — none of them statically main-actor-isolated — plus
/// `TrailerZoomCache.loadIfNeeded()`'s three sites, which run under THAT type's own separate lock.
/// A `@MainActor`-isolated design (the `StreamProbe` shape) works there because its one caller is
/// already an `@MainActor` view model; this probe has no single safe caller to lean on, so it earns
/// its own lock instead of assuming one.
///
/// Tail-rolling like `StreamProbe` (not head-preserving like `HomeHeroProbe`): a trailer's zoom
/// history over one dwell is short and it's the LAST lines (the verdict) that matter for a photo.
enum TrailerZoomProbe {
    /// Live read, not launch-latched: the About pane's toggle must work in the session it's
    /// flipped in, since the capture protocol is "turn on, open the zoomed title, let it play,
    /// come back and photograph" — no relaunch in between.
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug.trailerDiagnostics") }

    static let maxLines = 40

    private static let lock = NSLock()
    /// nonisolated(unsafe), matching HomeHeroProbe (HomeView.swift): the accessors below are
    /// nonisolated, and this storage is protected by the NSLock above, so it must be nonisolated
    /// too under any default actor isolation.
    nonisolated(unsafe) private static var _lines: [String] = []
    private static let t0 = Date()

    /// Snapshot for readers (the About pane's 1 Hz `TimelineView`) — safe from any thread.
    nonisolated static var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }

    /// The one entry point every `[TrailerZoom]` call site in `TrailerHeroPlayerView.swift` funnels
    /// through — no caller-side `if TrailerProbe.enabled` guard any more; this owns both gates.
    /// Callable from any thread.
    nonisolated static func log(_ line: String) {
        if TrailerProbe.enabled {
            NSLog("[TrailerZoom] %@", line)
        }
        guard enabled else { return }
        lock.lock()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        _lines.append("\(ms)ms \(line)")
        if _lines.count > maxLines { _lines.removeFirst(_lines.count - maxLines) }
        lock.unlock()
    }

    nonisolated static func clear() {
        lock.lock(); defer { lock.unlock() }
        _lines = []
    }
}
