import Foundation

/// BUG-89 / BUG-66 (beta.18-rc2, Steven's video): a release-safe, PHOTOGRAPHABLE record of what
/// Home's pinned-row settle machinery decided — the same evidence a `[HomeScrollProbe]` device log
/// carries, for a tester who has a sideload and a TV and no console.
///
/// Why a second probe rather than more lines in `HomeHeroProbe`. They answer different questions
/// and are captured under different protocols: the hero probe's contract is a COLD LAUNCH left
/// untouched for 90 seconds, and its head-preserving buffer freezes exactly that launch window.
/// The settle evidence is the opposite shape — it only exists once the tester WALKS the rows, and
/// the interesting lines are the ones produced minutes after launch. Mixing them would push one
/// out of the other's photo. So: same mechanism, own key, own buffer, own toggle
/// (`debug.pinnedRowSettleProbe`), and deliberately independent of `HomeGeometryProbe.enabled` so
/// a tester can capture rests without also turning the console firehose on.
///
/// Relationship to the existing `[HomeScrollProbe]` NSLogs: none. This type NEVER NSLogs. Every
/// call site keeps its own `HomeGeometryProbe.enabled`-gated NSLog exactly as it was — the console
/// contract and its tokens are unchanged — and simply mirrors the same text in here when this
/// probe is on. Routing the NSLog through this type instead would have doubled every line whenever
/// both knobs were set, and would have changed what a device console prints, which is the one
/// thing a diagnostics change must not do.
///
/// Head/tail sizing, against the capture protocol ("relaunch, walk down every row on Home and back
/// up, then photograph this pane"): a 6-row walk down and back is ~12 focus hops, each of which
/// resolves ONE settle decision, plus a launch `regime`/`plan` pair and a handful of belt events.
/// 12 frozen head lines hold the launch regime and the first few rests; the 28-line rolling tail
/// holds the end of the walk, which is where the last row's rest lives. 41 displayed lines total.
enum PinnedRowSettleProbe {

    /// Read ONCE at first access, like every other probe knob in this tree (`HomeHeroProbe`,
    /// `TrailerProbe`, `CollectionFocusAB`) — hence the "relaunch" in the About pane's subtitle.
    /// `UserDefaults.bool(forKey:)` also coerces the String "YES" an `-debug.pinnedRowSettleProbe
    /// YES` launch argument lands in the argument domain, so the harness can arm it without a
    /// `defaults write`.
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.pinnedRowSettleProbe")

    nonisolated static let t0 = Date()
    /// `nonisolated` for the same reason `HomeHeroProbe.sinceLaunchMs` is: the target defaults to
    /// MainActor isolation and `log` below is called from geometry callbacks and deferred settle
    /// work items. Pure `Date` math, safe from any executor.
    nonisolated static var sinceLaunchMs: Int { Int(Date().timeIntervalSince(t0) * 1000) }

    nonisolated static let linesKey = "debug.pinnedRowSettleProbe.lines"

    /// Frozen launch head — never evicted. Holds the regime/plan pair and the first rests.
    nonisolated static let headMaxLines = 12
    /// Rolling recent window. Holds the end of the walk, where the last row's rest lands.
    nonisolated static let tailMaxLines = 28

    nonisolated(unsafe) private static var headLines: [String] = []
    nonisolated(unsafe) private static var tailLines: [String] = []
    /// Lines dropped from the tail stream once `tailLines` is full. Stays 0 (no marker rendered)
    /// until eviction genuinely begins.
    nonisolated(unsafe) private static var elidedTailCount = 0
    nonisolated private static let bufferLock = NSLock()

    /// Appends `line`, stamped with its milliseconds-since-launch, to the persisted head-preserving
    /// ring buffer. Same shape as `HomeHeroProbe.log`, minus the NSLog (see the type doc).
    ///
    /// NOT gated by `enabled` internally — every call site wraps its own call in
    /// `if PinnedRowSettleProbe.enabled { … }`, which is what keeps the cost of an off probe to one
    /// static `Bool` read on paths that run per settle. The unit test drives this directly for the
    /// same reason `HomeHeroProbeBufferTests` can: `enabled` is a launch-latched `static let` that
    /// flipping a default after the fact could not affect anyway.
    ///
    /// Write-through to `UserDefaults` on every call, deliberately: the capture protocol is
    /// "relaunch, walk, photograph", and the app may be backgrounded or killed between the walk and
    /// the tester reaching Settings. The buffer is at most 41 short strings, so the write is cheap
    /// and bounded, exactly as it is for the hero probe.
    ///
    /// `headLines`/`tailLines` are fresh statics per process, so each launch starts the buffer
    /// clean without needing a reset flag — a relaunch is the reset.
    /// TEST ONLY (Codex rc5 r1, P3): clears the process-global buffer and its persisted mirror so
    /// `PinnedRowSettleProbeBufferTests` can assert an exact head/tail/elision shape regardless of
    /// what the hosting app logged before the test ran, and can run twice in one process. Never
    /// called from app code: the head is frozen by design for the tester's photo.
    nonisolated static func resetForTesting() {
        bufferLock.lock()
        headLines.removeAll()
        tailLines.removeAll()
        elidedTailCount = 0
        bufferLock.unlock()
        UserDefaults.standard.removeObject(forKey: linesKey)
    }

    nonisolated static func log(_ line: String) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let stamped = "\(sinceLaunchMs)ms \(line)"
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

    /// BUG-100 (rc6, Steven's tester photo): the About pane renders this buffer inside a native
    /// `List` row, which clips to the row's own height and cannot be scrolled — only the first
    /// ~6 lines were ever photographable. Those 6 lines are always the frozen launch head (the
    /// `regime`/`plan` pair and the first couple of rests), never the tail, which is exactly
    /// where a walk's LATER row settles live — the evidence the pane exists to capture was
    /// permanently below the fold. Decision (Christian, 09-08): render newest first, so the
    /// photographable top of the pane shows what the tester just did, not what happened at
    /// launch three minutes earlier.
    ///
    /// Pure and stateless: takes whatever `linesKey` currently holds, in the PERSISTED,
    /// chronological order `log(_:)` writes (frozen head, one elision marker once the tail has
    /// started rolling, then the rolling tail, oldest to newest) and returns a VIEW order for
    /// `AboutSettingsPane` to render. The persisted order itself is untouched by this function —
    /// `log(_:)` and the harness's `settle_probe_blob` overlay both still read/write the
    /// chronological order, which is load-bearing for `PinnedRowSettleProbeBufferTests` and for
    /// any device-log cross-reference a tester's report makes against `[HomeScrollProbe]` lines.
    ///
    /// Reordering, split at the elision marker (a line containing "lines elided"):
    /// - With a marker: everything before it is `head`, everything after is `tail`. The result is
    ///   `tail.reversed() + [marker] + head.reversed()` — the whole array reads newest-first end
    ///   to end. The most recent tail line (the walk's last settle) lands first, at the top of
    ///   the visible fold; the very first line ever logged (the launch `regime`/`plan` pair) lands
    ///   last, at the bottom, past where the clipped row is scrolled anyway.
    /// - Without a marker (the buffer hasn't started evicting yet — an early-in-the-walk photo,
    ///   or any caller feeding this function a raw unmarked array): there is no tail to
    ///   prioritize over the head, but the pane's caption still promises "Newest first" — so even
    ///   a short, still-all-head buffer (7-12 lines, no marker) is reversed newest-first rather
    ///   than left in persisted (oldest-first) order. Decision (Christian, 09-09, review finding
    ///   8): a tester photographing mid-walk, before eviction has ever started, should still see
    ///   their most recent settle at the top, not buried under the launch `regime`/`plan` pair. If
    ///   the input is at or under `headMaxLines`, just reverse it whole. Otherwise split it exactly
    ///   as `log(_:)` would (first `headMaxLines` lines are head, the rest is tail) and apply the
    ///   same newest-first reordering.
    nonisolated static func displayOrder(_ persisted: [String]) -> [String] {
        if let markerIndex = persisted.firstIndex(where: { $0.contains("lines elided") }) {
            let head = Array(persisted[..<markerIndex])
            let marker = persisted[markerIndex]
            let tail = Array(persisted[(markerIndex + 1)...])
            return Array(tail.reversed()) + [marker] + Array(head.reversed())
        }
        guard persisted.count > headMaxLines else { return Array(persisted.reversed()) }
        let head = Array(persisted.prefix(headMaxLines))
        let tail = Array(persisted.suffix(from: headMaxLines))
        return Array(tail.reversed()) + Array(head.reversed())
    }

    /// BUG-102 (rc7, Steven's tester photo): newest-first (`displayOrder` above) fixed WHICH lines
    /// land at the top, but not how many are ever visible — the List row still clips after about
    /// three lines once the "Newest first" caption takes one, so the 28-line rolling tail stayed
    /// unphotographable in one shot. Decision (Christian, 09-09): stop trying to fit the whole
    /// buffer in one clipped block. Instead PAGE it — `AboutSettingsPane` renders one List row PER
    /// PAGE, a few lines each, so the tester scrolls the About LIST itself (native, focus-driven
    /// scrolling that isn't clipped) and photographs one page at a time.
    ///
    /// Pure: chunks `displayOrder(persisted)` — already newest-first — into `linesPerPage`-line
    /// pages, in order. Page 1 therefore starts with the newest persisted line, same as
    /// `displayOrder`'s own head; the last page is shorter whenever the count doesn't divide
    /// evenly; an empty buffer produces zero pages, not one empty page, so the caller's
    /// `!rowSettleProbeLines.isEmpty` gate stays the only thing deciding whether the block renders
    /// at all.
    nonisolated static func displayPages(_ persisted: [String], linesPerPage: Int = 5) -> [[String]] {
        pages(displayOrder(persisted), linesPerPage: linesPerPage)
    }

    /// The chunking half of `displayPages`, without its newest-first reordering: `lines` cut into
    /// `linesPerPage`-line pages, in the given order. For a readout that is one snapshot rather
    /// than a log, whose header must stay on page 1 — the Continue Watching diagnostics
    /// (`ContinueWatchingDiagnosticsRows`). An empty input makes zero pages.
    nonisolated static func pages(_ lines: [String], linesPerPage: Int = 5) -> [[String]] {
        guard !lines.isEmpty, linesPerPage > 0 else { return [] }
        return stride(from: 0, to: lines.count, by: linesPerPage).map {
            Array(lines[$0..<Swift.min($0 + linesPerPage, lines.count)])
        }
    }
}
