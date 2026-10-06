import Foundation
import QuartzCore
import UIKit

/// FEAT-33 (Wave 1, agent C): release-safe frame-timing diagnostics for the Home collection
/// (folder) row's focus-step animation — a tester reports our row animating at what looks like
/// 30 fps against official Nuvio's 60 fps, but his only evidence is his own 30 fps screen
/// recording, which can't distinguish "we render at 30" from "his capture samples at 30". This
/// probe measures the real per-vsync frame timing on device instead of guessing from a video.
///
/// Same house pattern as `TrailerZoomProbe`/`HomeHeroProbe`/`StreamProbe`: testers run release
/// sideloads with no `defaults write` access, so the gate is a single `UserDefaults` key
/// (`debug.collectionFrameProbe`) that both a console knob AND the About pane's toggle read —
/// unlike `TrailerZoomProbe`, which has a separate console-only gate (`TrailerProbe.enabled`)
/// layered on top of its About toggle, this probe has exactly one key serving both routes, so
/// there is nothing to dual-gate here.
///
/// A frame-rate measurement is itself hostile to naive instrumentation: logging every vsync would
/// add exactly the kind of main-thread work whose absence the probe is trying to verify. So the
/// `CADisplayLink` sampler below (`CollectionFocusFrameSampler`) collects silently for a short
/// window and emits ONE summary line per window — see that type's doc comment.
///
/// KNOWN CONTAMINATION — a device frame-rate run must have both of these OFF, or their own
/// logging/branching work pollutes the measurement:
///   - `debug.collectionCoverProbe` (`CollectionCoverProbe`, this file's sibling in
///     `CollectionsUI.swift`) — NSLogs from `FolderTile.body` on every tile render.
///   - `debug.homeScrollProbe` (`HomeGeometryProbe`, `BrowseComponents.swift`) — NSLogs in the
///     Home settle path.
enum CollectionFocusFrameProbe {
    /// Live read, not launch-latched: the About pane's toggle must take effect in the same
    /// session it's flipped in — the capture protocol is "turn on, focus across the row a few
    /// times, come back and photograph", no relaunch in between.
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug.collectionFrameProbe") }

    static let maxLines = 40

    private static let lock = NSLock()
    /// nonisolated(unsafe), matching `TrailerZoomProbe`/`HomeHeroProbe`: the accessors below are
    /// nonisolated and this storage is protected by the NSLock above, so it must be nonisolated
    /// too under this project's default MainActor isolation.
    nonisolated(unsafe) private static var _lines: [String] = []
    private static let t0 = Date()

    /// Snapshot for readers (the About pane's 1 Hz `TimelineView`) — safe from any thread.
    nonisolated static var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }

    /// The one entry point `CollectionFocusFrameSampler` funnels its per-window summary through.
    /// Callable from any thread (in practice always the main thread, since the sampler is
    /// main-actor, but this stays consistent with the buffer's own thread-safety story).
    nonisolated static func log(_ line: String) {
        guard enabled else { return }
        NSLog("[CollectionFrameProbe] %@", line)
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

/// Measures real per-vsync frame timing across one focus step on a collection row, using a single
/// shared `CADisplayLink` (never one per row/tile — this class owns exactly one link for the
/// entire app, paused whenever no measurement window is open, so the probe itself costs nothing
/// while idle).
///
/// `arm(rowKey:gif:)` is called from `CollectionRowView`'s `.onChange(of: focusedFolderId)` right
/// after the existing `onFolderFocusChange` callback, so the 600 ms window covers the hero-commit
/// work that focus change triggers upstream, not just the tile's own `.animation`. It opens a
/// window, samples every vsync tick silently (no per-tick NSLog — see the type doc above), and on
/// close (600 ms later, or immediately if a new `arm` call supersedes it) emits exactly one
/// summary line into `CollectionFocusFrameProbe`'s buffer.
///
/// A "dropped" frame is a tick-to-tick gap over 1.5× the expected frame duration
/// (`CADisplayLink.duration`, which is 0 before the link has ticked at least once — in that case
/// fall back to `1 / UIScreen.main.maximumFramesPerSecond`, the same value ProMotion/60 Hz Apple
/// TV hardware would otherwise report through `duration` anyway).
@MainActor
final class CollectionFocusFrameSampler: NSObject {
    static let shared = CollectionFocusFrameSampler()

    /// How long each measurement window stays open once armed.
    private static let windowDuration: TimeInterval = 0.6

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var frameGapsMs: [Double] = []
    private var droppedCount = 0
    private var maxGapMs: Double = 0
    private var windowRowKey = ""
    private var windowGif = false
    private var sequence = 0
    private var closeWorkItem: DispatchWorkItem?

    private override init() { super.init() }

    /// Opens a new 600 ms measurement window for one focus step. If a window is already open
    /// (a focus step landed inside another one's 600 ms), that window is closed first — emitting
    /// its own (short) summary line — rather than silently discarded, so a rapid string of focus
    /// moves still produces one line per step instead of losing the earlier ones.
    func arm(rowKey: String, gif: Bool) {
        guard CollectionFocusFrameProbe.enabled else { return }
        if let link = displayLink, !link.isPaused {
            closeWindow()
        }

        sequence += 1
        windowRowKey = rowKey
        windowGif = gif
        // Codex r2: seed the clock NOW rather than on the first tick. The hero callback that
        // follows `arm()` runs synchronously on this same turn; if it stalls the main thread the
        // first display-link tick arrives late, and with a nil seed that whole interval — the
        // exact work this probe exists to measure — would be discarded instead of counted as a
        // dropped-frame gap. `CADisplayLink.timestamp` and `CACurrentMediaTime()` share a clock.
        lastTimestamp = CACurrentMediaTime()
        frameGapsMs = []
        droppedCount = 0
        maxGapMs = 0

        let link = displayLink ?? {
            let newLink = CADisplayLink(target: self, selector: #selector(tick))
            newLink.add(to: .main, forMode: .common)
            return newLink
        }()
        displayLink = link
        link.isPaused = false

        closeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.closeWindow() }
        closeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.windowDuration, execute: workItem)
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let last = lastTimestamp else { return }
        // The seed at `arm()` is `CACurrentMediaTime()` while `link.timestamp` is the LAST
        // displayed frame's time, so the first no-stall tick can read slightly negative. Discard
        // that seed artifact rather than record a 0 ms sample (which would inflate `frames=` and
        // bias p95); the `defer` above still re-bases the clock, and a genuine positive first gap
        // (a stall between `arm()` and the first tick) is still counted.
        let gapMs = (link.timestamp - last) * 1000
        guard gapMs >= 0 else { return }
        frameGapsMs.append(gapMs)
        if gapMs > maxGapMs { maxGapMs = gapMs }
        let expectedFrameMs = link.duration > 0
            ? link.duration * 1000
            : 1000.0 / Double(max(UIScreen.main.maximumFramesPerSecond, 1))
        if gapMs > expectedFrameMs * 1.5 { droppedCount += 1 }
    }

    /// Closes the current window (idempotent — a no-op if none is open, e.g. the probe was
    /// disabled mid-window or the work item already fired) and emits one summary line.
    /// Pauses the link rather than removing it: the next `arm` reuses it, matching the "never run
    /// the link while idle" rule without paying `CADisplayLink` setup/teardown cost every focus
    /// step on a row a tester is actively walking.
    private func closeWindow() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
        guard let link = displayLink, !link.isPaused else { return }
        link.isPaused = true

        let refreshHz = UIScreen.main.maximumFramesPerSecond
        let p95Ms = Self.percentile(frameGapsMs, 0.95)
        let line = String(
            format: "focus n=%d row=%@ frames=%d dropped=%d p95=%.1fms max=%.1fms refresh=%d gif=%d",
            sequence, windowRowKey, frameGapsMs.count, droppedCount, p95Ms, maxGapMs, refreshHz, windowGif ? 1 : 0
        )
        CollectionFocusFrameProbe.log(line)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[index]
    }
}

/// `debug.collectionFocusAB` (Int, launch-latched — read once, like the historical shape of these
/// on-device A/B knobs): the two-factor knob this frame-rate investigation tests against, once the
/// probe above tells us WHERE the frames are going.
///
///     defaults write com.nuvio.media.NuvioTV debug.collectionFocusAB -int 0
///
///   - 0: shipping behavior, the default.
///   - 1: defer the hero-commit work `onFolderFocusChange` triggers by `heroCommitDeferral`
///     (200 ms) — agent A's HomeView hook reads `deferHeroCommit`/`heroCommitDeferral`, not this
///     file; this type only exposes the knob and the constant.
///   - 2: `FolderTile` drops its own `.animation(.easeOut(duration: 0.15), value: isFocused)` —
///     see `CollectionsUI.swift`'s `FolderTile.body`, which reads `dropTileAnimation`.
///   - 3: both 1 and 2.
enum CollectionFocusAB {
    static let leg: Int = UserDefaults.standard.integer(forKey: "debug.collectionFocusAB")
    static var deferHeroCommit: Bool { leg == 1 || leg == 3 }
    static var dropTileAnimation: Bool { leg == 2 || leg == 3 }
    /// Agent A's HomeView hook reads this constant rather than hard-coding 0.2 at its own call
    /// site, so both halves of leg 1/3 stay in sync if this value ever changes.
    static let heroCommitDeferral: TimeInterval = 0.2
}
