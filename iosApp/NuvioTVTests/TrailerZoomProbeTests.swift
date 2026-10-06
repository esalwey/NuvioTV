import XCTest
@testable import NuvioTV

/// BUG-81/Wave F item C: unit coverage for `TrailerZoomProbe`'s tail-rolling ring buffer — the
/// release-safe About > Trailer Diagnostics readout. Mirrors `HomeHeroProbeBufferTests`'s shape,
/// but `TrailerZoomProbe` is tail-rolling (like `StreamProbe`), not head-preserving (like
/// `HomeHeroProbe`): there is no launch head worth protecting for a single trailer dwell, so the
/// buffer just keeps the most recent `maxLines` lines.
///
/// `TrailerZoomProbe.log(_:)` gates the in-memory buffer on `TrailerZoomProbe.enabled`
/// (`debug.trailerDiagnostics`) — unlike `HomeHeroProbe.log`, which always appends regardless of
/// its own toggle. That means these tests DO need the toggle on to see anything land, and they
/// restore whatever was there before so this file doesn't leak state into other tests in the same
/// process.
final class TrailerZoomProbeTests: XCTestCase {
    private let key = "debug.trailerDiagnostics"
    private var previousValue: Bool = false

    override func setUp() {
        super.setUp()
        previousValue = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        TrailerZoomProbe.clear()
    }

    override func tearDown() {
        TrailerZoomProbe.clear()
        UserDefaults.standard.set(previousValue, forKey: key)
        super.tearDown()
    }

    func testDisabledKeyRecordsNothing() {
        UserDefaults.standard.set(false, forKey: key)
        TrailerZoomProbe.log("should-not-appear")
        XCTAssertTrue(TrailerZoomProbe.lines.isEmpty, "log() must be a no-op while debug.trailerDiagnostics is off")
    }

    func testSixtyLinesInKeepsNewest40() {
        XCTAssertEqual(TrailerZoomProbe.maxLines, 40)

        for i in 1...60 {
            TrailerZoomProbe.log(String(format: "tzpt-line-%04d", i))
        }

        let lines = TrailerZoomProbe.lines
        XCTAssertEqual(lines.count, 40, "buffer must cap at maxLines")

        // Oldest 20 (1...20) rolled off; the kept window is 21...60, newest last.
        XCTAssertTrue(lines.first?.hasSuffix("tzpt-line-0021") ?? false, "first kept line should be #21: \(lines.first ?? "-")")
        XCTAssertTrue(lines.last?.hasSuffix("tzpt-line-0060") ?? false, "last kept line should be #60 (newest): \(lines.last ?? "-")")

        // Ordering is oldest-to-newest throughout the kept window.
        for idx in 0..<lines.count {
            let expectedSuffix = String(format: "tzpt-line-%04d", idx + 21)
            XCTAssertTrue(lines[idx].hasSuffix(expectedSuffix), "lines[\(idx)] = \(lines[idx]) does not end with \(expectedSuffix)")
        }
    }

    func testEachLineCarriesAMillisecondTimestampPrefix() {
        TrailerZoomProbe.log("tzpt-timestamp-check")
        guard let line = TrailerZoomProbe.lines.last else {
            XCTFail("expected at least one line")
            return
        }
        XCTAssertTrue(line.hasSuffix("ms tzpt-timestamp-check"), "line should be stamped '<N>ms <text>': \(line)")
    }

    func testClearEmptiesTheBuffer() {
        TrailerZoomProbe.log("tzpt-before-clear")
        XCTAssertFalse(TrailerZoomProbe.lines.isEmpty)
        TrailerZoomProbe.clear()
        XCTAssertTrue(TrailerZoomProbe.lines.isEmpty)
    }

    // MARK: - BUG-94 (beta.18): TrailerSurfaceZoomPolicy

    /// The full surface must play uncropped at zoom 1.0 UNCONDITIONALLY — a matching cached entry
    /// (what the hero loop or a prior full-screen play left behind under this title's `zoomKey`)
    /// must not change the answer. `cached: nil` and `cached: <a real entry>` are asserted
    /// side-by-side so this can never regress into "only when the cache happens to be cold".
    func testFullSurfaceAlwaysPlaysAtOneWithoutCachedEntry() {
        let decision = TrailerSurfaceZoomPolicy.decide(surface: "full", cached: nil)
        XCTAssertEqual(decision.zoom, 1.0)
        XCTAssertEqual(decision.gravity, .resizeAspect)
        XCTAssertFalse(decision.measure, "the full surface must never arm the sampling ladder")
        XCTAssertFalse(decision.persist, "the full surface must never write TrailerZoomCache")
    }

    func testFullSurfaceAlwaysPlaysAtOneWithMatchingCachedEntry() {
        // A plausible entry the hero loop (or an earlier full-screen play, pre-BUG-94) could have
        // left under this title's zoomKey — the exact shape `TrailerLetterboxProbe.start()` used to
        // apply immediately on a token match.
        let cached = TrailerZoomCache.Entry(zoom: 1.343, token: "yt:rNZ0xKaCdus", at: Date().timeIntervalSince1970, verifyMisses: nil)
        let decision = TrailerSurfaceZoomPolicy.decide(surface: "full", cached: cached)
        XCTAssertEqual(decision.zoom, 1.0, "a cached crop must never leak into the full surface's zoom")
        XCTAssertEqual(decision.gravity, .resizeAspect)
        XCTAssertFalse(decision.measure)
        XCTAssertFalse(decision.persist)
    }

    /// `hero` and `inline` keep today's ladder — the policy hands back the floor/fill contract the
    /// existing sampling code already implements, and neither `cached` value nor which of the two
    /// surface names is passed should change `measure`/`persist`/`gravity`.
    func testHeroAndInlinePolicyUnchanged() {
        let cachedEntry = TrailerZoomCache.Entry(zoom: 1.2, token: "yt:abc", at: Date().timeIntervalSince1970, verifyMisses: nil)
        let cachedOptions: [TrailerZoomCache.Entry?] = [nil, cachedEntry]
        for surface in ["hero", "inline"] {
            for cached in cachedOptions {
                let decision = TrailerSurfaceZoomPolicy.decide(surface: surface, cached: cached)
                XCTAssertTrue(decision.measure, "\(surface) must keep measuring")
                XCTAssertTrue(decision.persist, "\(surface) must keep persisting")
                XCTAssertEqual(decision.gravity, .resizeAspectFill, "\(surface) must keep filling")
                XCTAssertEqual(decision.zoom, TrailerHeroPlayer.parityZoom, "\(surface)'s floor is unchanged")
            }
        }
    }

    /// Narrower restatement of `testFullSurfaceAlwaysPlaysAtOneWithoutCachedEntry` naming the exact
    /// invariant `TrailerLetterboxProbe.start()`'s early return depends on: `measure == false` is
    /// what stops the full surface from ever attaching a video output or arming the tick timer.
    func testFullSurfaceNeverMeasures() {
        XCTAssertFalse(TrailerSurfaceZoomPolicy.decide(surface: "full", cached: nil).measure)
        let cached = TrailerZoomCache.Entry(zoom: 1.45, token: "repack:deadbeef", at: Date().timeIntervalSince1970, verifyMisses: 2)
        XCTAssertFalse(TrailerSurfaceZoomPolicy.decide(surface: "full", cached: cached).measure)
    }
}
