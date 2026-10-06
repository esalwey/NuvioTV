import XCTest
@testable import NuvioTV

/// Unit tests for `PinnedRowSettleProbe`'s head-preserving ring buffer (beta.18-rc2, BUG-89) — the
/// persisted `debug.pinnedRowSettleProbe.lines` buffer the About pane renders for a device-pass
/// photo. Mirrors `HomeHeroProbeBufferTests` exactly, because the buffer is the same mechanism with
/// its own key and its own head/tail sizing: the first `headMaxLines` lines are frozen forever and
/// only a `tailMaxLines` window rolls after that, with a single elision-count marker once eviction
/// has actually started.
///
/// `PinnedRowSettleProbe.log(_:)` is NOT gated by `PinnedRowSettleProbe.enabled` internally — every
/// call site (`BrowseComponents.swift`, `HomeView.swift`) wraps its own call in
/// `if PinnedRowSettleProbe.enabled { … }`, but `log` itself always appends. So this test drives
/// the real buffer directly via `@testable import` without touching the `debug.pinnedRowSettleProbe`
/// default at all — which is read once into a `static let` at first access anyway, so flipping it
/// after the fact would do nothing.
///
/// Same caveat as the hero buffer's test: `headLines`/`tailLines`/`elidedTailCount` are
/// process-global statics with no reset hook (by design — "fresh statics for this process" starts
/// clean each real launch). Within one xctest run all test methods share that process, so this file
/// assumes it is the only thing in the target that calls `PinnedRowSettleProbe.log`; a zero-padded,
/// uniquely-prefixed marker per call keeps the assertions robust to any accidental prior appends
/// rather than assuming the buffer starts empty.
final class PinnedRowSettleProbeBufferTests: XCTestCase {

    func testHeadPreservedTailRolledWithElisionMarker() {
        PinnedRowSettleProbe.resetForTesting()   // Codex rc5 r1 (P3): a pristine buffer, every run
        let totalLines = 200
        let head = PinnedRowSettleProbe.headMaxLines   // 12
        let tail = PinnedRowSettleProbe.tailMaxLines   // 28
        XCTAssertEqual(head, 12, "test assumes the documented head size; update the math below if this constant changes")
        XCTAssertEqual(tail, 28, "test assumes the documented tail size; update the math below if this constant changes")
        // The capture protocol's whole budget: a 6-row walk down and back up must fit inside the
        // displayed window without eliding anything (see the probe's sizing note).
        XCTAssertEqual(head + tail, 40, "displayed capacity is the ~40-line volume cap the emit sites are budgeted against")

        for i in 1...totalLines {
            PinnedRowSettleProbe.log(String(format: "prsbt-probe-line-%04d", i))
        }

        guard let display = UserDefaults.standard.stringArray(forKey: PinnedRowSettleProbe.linesKey) else {
            XCTFail("expected \(PinnedRowSettleProbe.linesKey) to be populated after PinnedRowSettleProbe.log calls")
            return
        }

        // head + 1 marker + tail, once eviction has begun (it has: 200 lines fed against a
        // 12 + 28 = 40-line displayed capacity).
        XCTAssertEqual(display.count, head + 1 + tail, "unexpected displayed line count: \(display.count)")

        // First `head` entries are the FIRST `head` lines ever logged (frozen, never evicted) —
        // each stamped "<N>ms prsbt-probe-line-NNNN", so a suffix match on the zero-padded,
        // fixed-width marker is unambiguous (no digit-count collisions).
        for idx in 0..<head {
            let expectedSuffix = String(format: "prsbt-probe-line-%04d", idx + 1)
            XCTAssertTrue(
                display[idx].hasSuffix(expectedSuffix),
                "head[\(idx)] = \(display[idx]) does not end with \(expectedSuffix)"
            )
        }

        // Elision marker sits between head and tail. Its count reflects everything logged past
        // head + tail capacity: 200 - 12 - 28 = 160 (assuming this test owns the whole process's
        // worth of `PinnedRowSettleProbe.log` calls — see the caveat above).
        let expectedElided = totalLines - head - tail
        XCTAssertTrue(
            display[head].contains("\(expectedElided) lines elided"),
            "marker line = \(display[head]), expected an elided count of \(expectedElided)"
        )

        // Last `tail` entries are the LAST `tail` lines logged: 200-28+1 = 173 through 200.
        let tailStart = totalLines - tail + 1
        for offset in 0..<tail {
            let displayIdx = head + 1 + offset
            let expectedSuffix = String(format: "prsbt-probe-line-%04d", tailStart + offset)
            XCTAssertTrue(
                display[displayIdx].hasSuffix(expectedSuffix),
                "tail[\(offset)] = \(display[displayIdx]) does not end with \(expectedSuffix)"
            )
        }

        // Every line carries the `<N>ms ` launch stamp the pane's reader dates the walk by.
        for line in display where !line.contains("lines elided") {
            XCTAssertNotNil(
                line.range(of: #"^\d+ms "#, options: .regularExpression),
                "line is missing its sinceLaunch stamp: \(line)"
            )
        }
    }

    /// BUG-100 (rc6): `PinnedRowSettleProbe.displayOrder(_:)` is the pure reordering
    /// `AboutSettingsPane` renders instead of the persisted chronological order, because the
    /// pane's List row clips to its own height and cannot be scrolled — only the reordered
    /// function's OUTPUT order is ever photographable. This test drives the pure function
    /// directly with hand-built arrays; it does not touch the shared process-global buffer
    /// `testHeadPreservedTailRolledWithElisionMarker` above exercises, so it needs no
    /// `resetForTesting()` call and cannot interfere with that test either way.
    func testDisplayOrderPutsNewestTailFirstAndHeadLast() {
        // Case 1 (marker present): the real `PinnedRowSettleProbe.log` shape once eviction has
        // begun — head, one elision marker, tail. Newest-first end to end: the result starts
        // with the very last persisted line (the newest tail entry) and ends with `head[0]`,
        // the oldest line ever logged (the launch `regime`/`plan` pair), pushed to the bottom.
        let head = (1...12).map { "h\($0)ms regime/plan line \($0)" }
        let marker = "\u{2026} 5 lines elided \u{2026}"
        let tail = (1...28).map { "t\($0)ms settle line \($0)" }
        let persistedWithMarker = head + [marker] + tail
        let displayedWithMarker = PinnedRowSettleProbe.displayOrder(persistedWithMarker)

        XCTAssertEqual(displayedWithMarker.count, persistedWithMarker.count, "reordering must not drop or duplicate lines")
        XCTAssertEqual(displayedWithMarker.first, tail.last, "expected the newest persisted line at the top")
        XCTAssertEqual(displayedWithMarker.last, head.first, "expected head[0], the oldest launch line, at the bottom")
        XCTAssertEqual(Array(displayedWithMarker.prefix(tail.count)), Array(tail.reversed()), "the reversed tail must lead")
        XCTAssertEqual(displayedWithMarker[tail.count], marker, "the elision marker sits right after the reversed tail")
        XCTAssertEqual(Array(displayedWithMarker.suffix(head.count)), Array(head.reversed()), "the reversed head must trail")

        // Case 2 (no marker, at or under `headMaxLines`): the buffer hasn't started evicting yet,
        // so there is no tail to prioritize over the head — but review finding 8 (09-09) points
        // out the pane's "Newest first" caption still applies to an all-head buffer, so a short
        // 7-12 line buffer is reversed too rather than returned in persisted (oldest-first) order.
        XCTAssertEqual(PinnedRowSettleProbe.headMaxLines, 12, "test assumes the documented head size; update the math below if this constant changes")
        let smallBuffer = (1...12).map { "s\($0)ms early line \($0)" }
        XCTAssertEqual(PinnedRowSettleProbe.displayOrder(smallBuffer), Array(smallBuffer.reversed()), "a short, still-all-head buffer must still read newest first")

        // Case 3 (no marker, over `headMaxLines`): 15 raw lines with no elision marker yet — the
        // fallback `headMaxLines`-based split still applies, so the 3 trailing lines are the
        // tail and come first, reversed.
        let fifteen = (1...15).map { "l\($0)" }
        let displayedFifteen = PinnedRowSettleProbe.displayOrder(fifteen)
        XCTAssertEqual(Array(displayedFifteen.prefix(3)), ["l15", "l14", "l13"], "the 3 tail lines must lead, reversed")
        XCTAssertEqual(displayedFifteen.count, fifteen.count, "reordering must not drop or duplicate lines")
    }

    /// BUG-102 (rc7): `PinnedRowSettleProbe.displayPages(_:linesPerPage:)` is the pure chunking
    /// `AboutSettingsPane` renders one List row per page from, because even newest-first ordering
    /// (`displayOrder`, tested above) still clips to ~3 photographable lines in one List row. This
    /// drives the pure function directly with hand-built arrays — it never touches the shared
    /// process-global buffer, so it needs no `resetForTesting()` and cannot interfere with the
    /// other tests in this file either way.
    func testDisplayPagesChunksNewestFirstOrderPreservingPageOrder() {
        // 41 lines is the documented full buffer volume (12 head + 1 marker + 28 tail): at the
        // default 5 lines per page that is 8 full pages plus a 1-line remainder — 9 pages total.
        let head = (1...12).map { "h\($0)ms regime/plan line \($0)" }
        let marker = "\u{2026} 1 lines elided \u{2026}"
        let tail = (1...28).map { "t\($0)ms settle line \($0)" }
        let fortyOne = head + [marker] + tail
        XCTAssertEqual(fortyOne.count, 41, "test assumes the documented 41-line full-buffer shape")

        let pages = PinnedRowSettleProbe.displayPages(fortyOne)
        XCTAssertEqual(pages.count, 9, "41 lines at 5 per page must chunk into 8 full pages + 1 remainder page")
        for page in pages.dropLast() {
            XCTAssertEqual(page.count, 5, "every page but the last must be full")
        }
        XCTAssertEqual(pages.last?.count, 1, "the last page must hold the 1-line remainder")

        // Order preserved end to end: concatenating every page back together must reproduce
        // `displayOrder`'s own newest-first output exactly, and page 1 must start with the same
        // newest line `displayOrder` puts first (the newest tail entry).
        let flattened = pages.flatMap { $0 }
        let expectedOrder = PinnedRowSettleProbe.displayOrder(fortyOne)
        XCTAssertEqual(flattened, expectedOrder, "paging must not reorder, drop, or duplicate lines")
        XCTAssertEqual(pages.first?.first, tail.last, "page 1 must start with the newest persisted line")

        // Empty buffer: no pages, not one empty page — the caller's own `!isEmpty` gate is what
        // decides whether the block renders at all, so this must not produce a phantom page.
        XCTAssertEqual(PinnedRowSettleProbe.displayPages([]), [], "an empty buffer must produce no pages")

        // Exactly 5 lines (one page's worth): a single page holding all 5, still newest first.
        let five = (1...5).map { "f\($0)" }
        let fivePages = PinnedRowSettleProbe.displayPages(five)
        XCTAssertEqual(fivePages.count, 1, "5 lines at 5 per page must produce exactly 1 page")
        XCTAssertEqual(fivePages.first, Array(five.reversed()), "the single page must hold every line, newest first")
    }

    /// CW legacy #1: `PinnedRowSettleProbe.pages(_:linesPerPage:)` is `displayPages` without the
    /// newest-first reordering — the Continue Watching diagnostics are one snapshot whose header
    /// must stay first on page 1. Pure, like the test above.
    func testPagesChunksInTheGivenOrder() {
        let twelve = (1...12).map { "c\($0)" }

        let pages = PinnedRowSettleProbe.pages(twelve)

        XCTAssertEqual(pages, [Array(twelve[0..<5]), Array(twelve[5..<10]), Array(twelve[10..<12])])
        XCTAssertEqual(PinnedRowSettleProbe.pages([]), [], "no lines must produce no pages")
        XCTAssertEqual(PinnedRowSettleProbe.pages(twelve, linesPerPage: 0), [], "a zero page size must not trap")
        XCTAssertEqual(PinnedRowSettleProbe.displayPages(twelve).flatMap { $0 }, PinnedRowSettleProbe.displayOrder(twelve))
    }
}
