import Foundation

// Live measurements of the NATIVE (AVPlayer) engine, fed by the remux worker, the loopback HLS server
// and the AVPlayer access log, so the owner can confirm on a device WHY a very large 4K file does or
// does not play smoothly (hidden Developer pane > Native Playback, and the Stream Info tab while the
// Developer pane is unlocked). Everything here is lock-guarded plain data: any thread may write, the
// UI only ever reads a snapshot, nothing blocks.
//
// How to read it:
//  - "x realtime" = media seconds produced per wall second by the remux, throttle waits excluded. Below
//    1.0 the remux cannot keep up and AVPlayer will starve; a 4K remux wants comfortably above 1.5.
//  - "late serves" = segment requests AVPlayer had to wait for (the remux was not ahead of the player).
//  - "timestamp fixups" must stay at 0 on a healthy file: it counts decode timestamps the segmenter had
//    to repair (reorder depth beyond its window), the kind of defect that draws as frames jumping back.
//  - dropped frames / stalls / indicated + observed bitrate come from AVPlayerItem.accessLog().
//  - "APAC audio" (spatial audio, TrueHD Atmos / DTS:X): conversion speed in x realtime since the latest
//    start or seek (below about 1.2 the audio cannot keep up and playback stalls), restarts (each seek the
//    audio converter had to restart), failures of the converter and fallbacks to the standard audio.
nonisolated final class NativePlaybackMetrics: @unchecked Sendable {
    static let shared = NativePlaybackMetrics()

    private let lock = NSLock()

    // Remux production.
    private var segmentsProduced = 0
    private var lastSegment = 0
    private var lastProduceSec = 0.0
    private var lastMediaSec = 0.0
    private var lastSegmentBytes = 0
    private var worstRealtime = Double.infinity
    private var totalProduceSec = 0.0
    private var totalMediaSec = 0.0
    private var totalBytes: Int64 = 0
    private var aheadSegments = 0
    private var aheadLimit = 0
    private var throttleEpisodes = 0
    private var prunedSegments = 0
    private var onDiskSegments = 0
    private var timestampFixups = 0
    private var ptsRaised = 0
    private var maxCompositionMs = 0.0
    private var readRecoveries = 0
    private var footprintMB = 0

    // Loopback server.
    private var served = 0
    private var servedBytes: Int64 = 0
    private var lateServes = 0
    private var maxServeWaitSec = 0.0
    private var serveTimeouts = 0

    // AVPlayer.
    private var indicatedBps = 0.0
    private var observedBps = 0.0
    private var droppedFrames = 0
    private var accessLogStalls = 0
    private var downloadOverdue = 0
    private var playbackStalls = 0
    private var lastStallNote = ""

    // Spatial audio (APAC conversion of TrueHD Atmos / DTS:X).
    private var spatialRenditions = 0
    private var spatialStartupSec = 0.0
    private var spatialSpeedNow = 0.0
    private var spatialSpeedWorst = Double.infinity
    private var spatialRunSegments = 0
    private var spatialCacheBytes = 0
    private var spatialRestarts = 0
    private var spatialFailures = 0
    private var spatialLastFailure = ""
    private var spatialFallbacks = 0
    private var spatialLastFallback = ""

    private init() {}

    /// A new playback session starts: forget the previous one's numbers.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        segmentsProduced = 0; lastSegment = 0; lastProduceSec = 0; lastMediaSec = 0; lastSegmentBytes = 0
        worstRealtime = .infinity; totalProduceSec = 0; totalMediaSec = 0; totalBytes = 0
        aheadSegments = 0; aheadLimit = 0; throttleEpisodes = 0; prunedSegments = 0; onDiskSegments = 0
        timestampFixups = 0; ptsRaised = 0; maxCompositionMs = 0; readRecoveries = 0; footprintMB = 0
        served = 0; servedBytes = 0; lateServes = 0; maxServeWaitSec = 0; serveTimeouts = 0
        indicatedBps = 0; observedBps = 0; droppedFrames = 0; accessLogStalls = 0; downloadOverdue = 0
        playbackStalls = 0; lastStallNote = ""
        spatialRenditions = 0; spatialStartupSec = 0; spatialSpeedNow = 0; spatialSpeedWorst = .infinity
        spatialRunSegments = 0; spatialCacheBytes = 0; spatialRestarts = 0; spatialFailures = 0
        spatialLastFailure = ""; spatialFallbacks = 0; spatialLastFallback = ""
    }

    // MARK: Writers

    /// One segment finished by the remux: its media length, the wall time it took, and its size on disk.
    func recordSegment(number: Int, mediaSec: Double, produceSec: Double, bytes: Int, footprintMB: Int) {
        lock.lock(); defer { lock.unlock() }
        segmentsProduced += 1
        lastSegment = number
        lastProduceSec = produceSec
        lastMediaSec = mediaSec
        lastSegmentBytes = bytes
        totalProduceSec += produceSec
        totalMediaSec += mediaSec
        totalBytes += Int64(bytes)
        if produceSec > 0.001, mediaSec > 0 { worstRealtime = min(worstRealtime, mediaSec / produceSec) }
        self.footprintMB = footprintMB
    }

    /// Where production stands against the player: segments ahead of the playhead, the pacing limit,
    /// and how many segment files exist on disk right now.
    func recordPacing(ahead: Int, limit: Int, onDisk: Int) {
        lock.lock(); defer { lock.unlock() }
        aheadSegments = ahead; aheadLimit = limit; onDiskSegments = onDisk
    }

    func noteThrottleEpisode() { lock.lock(); throttleEpisodes += 1; lock.unlock() }
    func notePruned(_ count: Int) { lock.lock(); prunedSegments += count; lock.unlock() }
    func noteReadRecovery() { lock.lock(); readRecoveries += 1; lock.unlock() }

    /// Timestamp repairs the segmenter made (deltas), and the largest pts-dts gap it wrote.
    func recordTimestamps(fixups: Int, ptsRaised raised: Int, maxCompositionSec: Double) {
        lock.lock(); defer { lock.unlock() }
        timestampFixups += fixups
        ptsRaised += raised
        maxCompositionMs = max(maxCompositionMs, maxCompositionSec * 1000)
    }

    /// A segment/init file went out to AVPlayer; `waitSec` is how long the request waited for the remux.
    func recordServe(bytes: Int, waitSec: Double) {
        lock.lock(); defer { lock.unlock() }
        served += 1
        servedBytes += Int64(bytes)
        if waitSec > 0.25 { lateServes += 1 }
        maxServeWaitSec = max(maxServeWaitSec, waitSec)
    }

    func noteServeTimeout() { lock.lock(); serveTimeouts += 1; lock.unlock() }

    /// Totals read from the item's access log (summed over its events).
    func recordPlayer(indicatedBps: Double, observedBps: Double, dropped: Int, stalls: Int, overdue: Int) {
        lock.lock(); defer { lock.unlock() }
        self.indicatedBps = indicatedBps
        self.observedBps = observedBps
        droppedFrames = dropped
        accessLogStalls = stalls
        downloadOverdue = overdue
    }

    /// `AVPlayerItemPlaybackStalled` fired.
    func notePlaybackStall(note: String) {
        lock.lock(); defer { lock.unlock() }
        playbackStalls += 1
        lastStallNote = note
    }

    // MARK: Spatial audio writers

    /// The spatial audio session is up: how many renditions it serves and how long the first segment of
    /// the track the viewer started on took (the extra start-up the viewer waits for).
    func noteSpatialStart(renditions: Int, startupSec: Double) {
        lock.lock(); defer { lock.unlock() }
        spatialRenditions = renditions
        spatialStartupSec = startupSec
    }

    /// Conversion speed of the engine's current run (multiples of real time), how many segments the run
    /// has produced, and the converted audio held in memory. The worst speed ignores a run's first
    /// segments, which carry the start-up cost.
    func recordSpatialSpeed(_ speed: Double, segmentsInRun: Int, cachedBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        spatialSpeedNow = speed
        spatialRunSegments = segmentsInRun
        spatialCacheBytes = cachedBytes
        if segmentsInRun >= 4 { spatialSpeedWorst = min(spatialSpeedWorst, speed) }
    }

    func noteSpatialRestart() { lock.lock(); spatialRestarts += 1; lock.unlock() }

    func noteSpatialFailure(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        spatialFailures += 1
        spatialLastFailure = String(message.prefix(160))
    }

    /// A spatial rendition was given up for the standard audio (conversion failed or was too slow).
    func noteSpatialFallback(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        spatialFallbacks += 1
        spatialLastFallback = String(reason.prefix(160))
    }

    // MARK: Readers

    /// The latest conversion speed and the segments it was measured over, for the playback health check.
    var spatialSpeed: (speed: Double, segments: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard spatialRunSegments > 0 else { return nil }
        return (spatialSpeedNow, spatialRunSegments)
    }

    var droppedVideoFrames: Int { lock.lock(); defer { lock.unlock() }; return droppedFrames }

    /// Short summaries for the Stream Info tab (two columns wide, so one line each).
    func infoRows() -> [(label: String, value: String)] {
        lock.lock(); defer { lock.unlock() }
        guard segmentsProduced > 0 || served > 0 || indicatedBps > 0 else { return [] }
        var rows: [(label: String, value: String)] = []
        if segmentsProduced > 0 {
            let avg = totalProduceSec > 0 ? totalMediaSec / totalProduceSec : 0
            let worst = worstRealtime.isFinite ? worstRealtime : avg
            rows.append((label: "Remux",
                         value: String(format: "seg %d \u{00B7} %.1fx realtime (worst %.1fx) \u{00B7} %d MB/seg \u{00B7} ahead %d/%d",
                                       lastSegment, avg, worst, lastSegmentBytes / 1_048_576, aheadSegments, aheadLimit)))
        }
        if spatialRenditions > 0 {
            var apac = spatialRunSegments > 0 ? String(format: "%.1fx realtime", spatialSpeedNow) : "starting"
            apac += " \u{00B7} \(spatialFailures) failures"
            if spatialFallbacks > 0 { apac += " \u{00B7} \(spatialFallbacks) fallbacks" }
            rows.append((label: "APAC audio", value: apac))
        }
        var player: [String] = []
        if observedBps > 0 { player.append(String(format: "observed %.0f Mb/s", observedBps / 1_000_000)) }
        player.append("dropped \(droppedFrames)")
        player.append("stalls \(accessLogStalls + playbackStalls)")
        if lateServes > 0 { player.append("late \(lateServes)") }
        rows.append((label: "Playback", value: player.joined(separator: " \u{00B7} ")))
        return rows
    }

    /// Full text dump for the Developer pane.
    func lines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard segmentsProduced > 0 || served > 0 || indicatedBps > 0 else { return [] }
        let avgRT = totalProduceSec > 0 ? totalMediaSec / totalProduceSec : 0
        let worst = worstRealtime.isFinite ? worstRealtime : avgRT
        let bytesPerSec = totalProduceSec > 0 ? Double(totalBytes) / totalProduceSec : 0
        var out: [String] = [
            String(format: "segments produced   %d (last #%d: %.1fs of media in %.1fs, %d MB)",
                   segmentsProduced, lastSegment, lastMediaSec, lastProduceSec, lastSegmentBytes / 1_048_576),
            String(format: "remux speed         %.2fx realtime avg, %.2fx worst, %.1f MB/s written",
                   avgRT, worst, bytesPerSec / 1_048_576),
            "paced production    \(aheadSegments) ahead of the player (limit \(aheadLimit)), \(throttleEpisodes) pauses, \(onDiskSegments) on disk, \(prunedSegments) pruned",
            "process footprint   \(footprintMB) MB",
            "timestamp fixups    \(timestampFixups) dts, \(ptsRaised) pts raised, max pts-dts \(Int(maxCompositionMs)) ms",
            "source recoveries   \(readRecoveries)",
            String(format: "served to AVPlayer  %d files, %.0f MB, %d late (max wait %.2fs), %d timeouts",
                   served, Double(servedBytes) / 1_048_576, lateServes, maxServeWaitSec, serveTimeouts),
            String(format: "AVPlayer bitrate     indicated %.1f Mb/s, observed %.1f Mb/s",
                   indicatedBps / 1_000_000, observedBps / 1_000_000),
            "AVPlayer frames     \(droppedFrames) dropped, \(accessLogStalls) stalls (access log), \(playbackStalls) stall events, \(downloadOverdue) overdue",
        ]
        if spatialRenditions > 0 || spatialFailures > 0 || spatialFallbacks > 0 {
            let worst = spatialSpeedWorst.isFinite ? String(format: "%.2fx", spatialSpeedWorst) : "-"
            out.append(String(format: "APAC conversion     %.2fx realtime, worst %@ (run: %d segs, started in %.1fs)",
                              spatialSpeedNow, worst, spatialRunSegments, spatialStartupSec))
            out.append("APAC audio          \(spatialRenditions) renditions, \(spatialCacheBytes / 1_048_576) MB cached, \(spatialRestarts) restarts")
            out.append("APAC failures       \(spatialFailures), \(spatialFallbacks) fallbacks to standard audio"
                       + (spatialLastFailure.isEmpty ? "" : " (last: \(spatialLastFailure))"))
            if !spatialLastFallback.isEmpty { out.append("APAC fallback       \(spatialLastFallback)") }
        }
        if !lastStallNote.isEmpty { out.append("last stall           \(lastStallNote)") }
        return out
    }
}
