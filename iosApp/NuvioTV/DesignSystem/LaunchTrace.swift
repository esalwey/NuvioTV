import Foundation
import os

/// BUG-26 diagnostic: lightweight cold-start telemetry. The tester reports beta.8 takes "much
/// longer to reload all the movies and artwork" than beta.7 on a cold launch — this attributes
/// the wall-clock between the two things that could be slow (rows arriving from the KMP fetch
/// layer vs artwork loading) and, for artwork, between memory hits / disk-cache hits / real
/// network fetches — the tracker's prime suspect being "something now invalidates the artwork
/// disk cache, so every cold start re-downloads everything".
///
/// DEBUG-only by construction: every call site is `#if DEBUG`-gated, so release builds carry
/// none of it. Output goes to BOTH `print` (visible on a `--console` launch / sim console) and
/// os_log at notice level (visible in `log show` without --info), prefixed `[LaunchTrace]` for
/// grepping.
enum LaunchTrace {
    /// Process-relative zero point — first touch of this type. `NuvioTVApp.init` touches it
    /// first, so all elapsed values read as "ms since app init".
    static let t0 = Date()

    private static let logger = Logger(subsystem: "com.nuvio.media.NuvioTV", category: "LaunchTrace")
    private static let lock = NSLock()

    // Artwork counters (guarded by `lock`; artwork completions land from multiple tasks).
    private static var artTotal = 0
    private static var artMemoryHits = 0
    private static var artDiskHits = 0
    private static var artNetwork = 0
    private static var artFailed = 0
    /// Totals at which a summary line is emitted — enough resolution to see the curve without
    /// one line per poster.
    private static let summaryThresholds: Set<Int> = [1, 10, 25, 50, 100, 200, 400]

    private static var elapsedMs: Int { Int(Date().timeIntervalSince(t0) * 1000) }

    /// One named milestone (app init, home appear, first rows, ...).
    static func mark(_ name: String) {
        let line = "[LaunchTrace] +\(elapsedMs)ms \(name)"
        print(line)
        logger.notice("\(line, privacy: .public)")
    }

    enum ArtworkSource: String {
        case memory
        case disk
        case network
        case failed
    }

    /// One artwork load completion, classified by where the bytes came from. Emits a summary
    /// at the thresholds above.
    static func artwork(_ source: ArtworkSource) {
        lock.lock()
        artTotal += 1
        switch source {
        case .memory: artMemoryHits += 1
        case .disk: artDiskHits += 1
        case .network: artNetwork += 1
        case .failed: artFailed += 1
        }
        let total = artTotal
        let summary = "mem=\(artMemoryHits) disk=\(artDiskHits) net=\(artNetwork) fail=\(artFailed)"
        lock.unlock()

        if summaryThresholds.contains(total) {
            mark("artwork #\(total): \(summary)")
        }
    }
}
