import Foundation

/// Launch-time hygiene for the remux segment cache (`Caches/nuvio-remux/`). Every playback writes
/// its fMP4 output into a per-session UUID subdirectory that `NativePlaybackCoordinator.stop()`
/// removes on normal exit — but a jetsam kill, a crash, or a `-debug.keepRemuxOutput 1` run leaves
/// the directory behind, and a single remux-bitrate session can be several GB. The sweep removes
/// every session directory not registered as live, once per launch, on a utility queue — never on
/// the remux worker's hot path.
///
/// This supersedes the plan's ~2 GB LRU cap (docs/tvos-hybrid-player-plan.md): session output is
/// ephemeral and never reused across playbacks, so there is nothing to LRU — a full orphan sweep
/// is strictly stronger. The LIVE session's output stays unbounded while it plays (segments are
/// retained so backward seeks inside the produced range never re-remux); capping that would need
/// live eviction + JIT re-production, recorded as an open question in the plan doc.
nonisolated enum RemuxCacheJanitor {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var liveDirs = Set<String>()

    /// Mark a session directory as belonging to a live `RemuxSession` (called from its init, which
    /// runs strictly before the worker creates the directory on disk — so a directory the sweep
    /// enumerates either predates this launch or is already registered).
    static func registerLive(_ dir: URL) {
        lock.lock(); liveDirs.insert(dir.standardizedFileURL.path); lock.unlock()
    }

    /// Forget a session directory once its cleanup ran.
    static func unregisterLive(_ dir: URL) {
        lock.lock(); liveDirs.remove(dir.standardizedFileURL.path); lock.unlock()
    }

    /// Remove every orphaned session directory. Called once from `NuvioTVApp.init`. Skipped when
    /// this run was launched with `-debug.keepRemuxOutput 1`, so output kept for inspection
    /// (devicectl copy + ffprobe) survives relaunches under the same scheme.
    static func sweepAtLaunch() {
        guard !UserDefaults.standard.bool(forKey: "debug.keepRemuxOutput") else {
            print("[RemuxJanitor] debug.keepRemuxOutput set — skipping orphan sweep")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            // No cache root yet (fresh install / never played via the native path) — nothing to do.
            guard let entries = try? fm.contentsOfDirectory(
                at: RemuxSession.cacheRoot, includingPropertiesForKeys: nil) else { return }
            // Snapshot AFTER enumerating: any session whose dir made it into `entries` mid-launch
            // (the smoke test starts one from NuvioTVApp.init) registered before its mkdir ran.
            lock.lock(); let live = liveDirs; lock.unlock()
            var removed = 0
            var reclaimed: Int64 = 0
            for dir in entries where !live.contains(dir.standardizedFileURL.path) {
                reclaimed += directorySize(dir)
                do { try fm.removeItem(at: dir); removed += 1 } catch {
                    print("[RemuxJanitor] failed to remove \(dir.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if removed > 0 {
                print("[RemuxJanitor] removed \(removed) orphaned session dir(s), reclaimed \(reclaimed / 1_048_576) MB")
            }
        }
    }

    private static func directorySize(_ dir: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
