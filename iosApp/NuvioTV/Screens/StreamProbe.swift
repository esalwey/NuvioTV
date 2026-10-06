import Foundation
import SharedCore

/// BUG-74: release-safe diagnostics for what a stream fetch was actually asked for, and what came
/// back.
///
/// Third of the house probes, after `HomeHeroProbe` and `TabBarProbe`, and deliberately not
/// `#if DEBUG` for the same reason as those two: the failures worth catching here only ever show up
/// on a tester's own hardware, with their own addons and their own catalogs. BUG-74 itself was
/// invisible for three weeks because the decisive fact — the id we sent the addons was `tmdb:…`
/// rather than `tt…` — existed only as a `log.d` in a build with no console attached.
///
/// Live in-memory, like `TabBarProbe` and unlike `HomeHeroProbe`: the capture protocol is "turn it
/// on, open the title that fails, press Play, go to Settings → About, photograph" — it never spans
/// a relaunch, so nothing here touches UserDefaults beyond reading its own switch.
///
/// The buffer is tail-rolling rather than head-preserving (`HomeHeroProbe`'s H-1A shape): a stream
/// open is a short, bounded burst of a dozen or so lines and it is the LAST one that matters, so
/// there is no launch head worth protecting here.
@MainActor
enum StreamProbe {
    /// Live read, not a launch-latched `static let`: this toggle must work in the session it is
    /// flipped in, since the tester is being walked through a reproduction there and then.
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug.streamProbe") }

    static let maxLines = 28

    private(set) static var lines: [String] = []
    private static let t0 = Date()

    /// Installs (or removes) the shared-side sink. Called when the toggle changes and once at
    /// startup, so a fetch running in Kotlin can report into this buffer without `shared` knowing
    /// anything about SwiftUI. Clearing the sink when off is what keeps the cost at one null check.
    nonisolated static func syncSink() {
        if enabled {
            StreamDiagnostics.shared.sink = { line in
                // Hop to the main actor: shared calls this from whatever dispatcher the fetch is
                // on, and `lines` is main-actor state the About pane renders from.
                Task { @MainActor in StreamProbe.record(line) }
            }
        } else {
            StreamDiagnostics.shared.sink = nil
            Task { @MainActor in StreamProbe.clear() }
        }
    }

    /// Records a line from the Swift side (the shared sink funnels through `record` too).
    static func log(_ line: String) {
        guard enabled else { return }
        record(line)
    }

    static func clear() { lines = [] }

    private static func record(_ line: String) {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        lines.append("\(ms)ms \(line)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}
