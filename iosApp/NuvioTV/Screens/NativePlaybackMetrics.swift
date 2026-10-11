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

    // MARK: Readers

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
        if !lastStallNote.isEmpty { out.append("last stall           \(lastStallNote)") }
        return out
    }
}
