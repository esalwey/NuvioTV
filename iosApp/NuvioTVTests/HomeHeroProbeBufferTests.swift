import XCTest
@testable import NuvioTV

/// Unit tests for `HomeHeroProbe`'s head-preserving ring buffer (`HomeView.swift`, beta.15 H-1A) —
/// the persisted `debug.homeHeroProbe.lines` buffer the About pane renders for a device-pass photo.
/// The buffer freezes the first `headMaxLines` lines forever and only rolls a `tailMaxLines` window
/// after that, with a single elision-count marker line once eviction has actually started.
///
/// `HomeHeroProbe.log(_:)` is NOT gated by `HomeHeroProbe.enabled` internally — every call site in
/// `HomeView.swift` wraps its own call in `if HomeHeroProbe.enabled { … }`, but `log` itself always
/// appends. That means this test can drive the real buffer directly via `@testable import` without
/// touching the `debug.homeHeroProbe` UserDefaults key at all (which is read once into a `static
/// let` at first access anyway — flipping it after the fact wouldn't do anything, the "once-only"
/// caveat the task called out).
///
/// Caveat this test relies on: `headLines`/`tailLines`/`elidedTailCount` are process-global statics
/// with no reset hook (by design — "fresh statics for this process" starts clean each real launch).
/// Within one xctest run all test methods share that process, so this file assumes it is the only
/// thing in the target that calls `HomeHeroProbe.log`; a zero-padded, uniquely-prefixed marker
/// string per call keeps assertions robust to any accidental prior appends rather than assuming the
/// buffer starts empty.
final class HomeHeroProbeBufferTests: XCTestCase {

    func testHeadPreservedTailRolledWithElisionMarker() {
        // Baseline: whatever's already in the persisted buffer before this test drives more lines
        // through it (see the process-global caveat above) — not asserted on, just recorded so the
        // "how many new lines did we contribute" math is self-contained.
        let totalLines = 200
        let head = HomeHeroProbe.headMaxLines   // 24 (Wave H raised this 16 -> 24)
        let tail = HomeHeroProbe.tailMaxLines   // 32
        XCTAssertEqual(head, 24, "test assumes the documented head size; update the math above if this constant changes")
        XCTAssertEqual(tail, 32, "test assumes the documented tail size; update the math above if this constant changes")

        for i in 1...totalLines {
            HomeHeroProbe.log(String(format: "hhpbt-probe-line-%04d", i))
        }

        guard let display = UserDefaults.standard.stringArray(forKey: HomeHeroProbe.linesKey) else {
            XCTFail("expected \(HomeHeroProbe.linesKey) to be populated after HomeHeroProbe.log calls")
            return
        }

        // head + 1 marker + tail, once eviction has begun (it has: 200 lines fed against a
        // 24+32 = 56-line displayed capacity).
        XCTAssertEqual(display.count, head + 1 + tail, "unexpected displayed line count: \(display.count)")

        // First `head` entries are the FIRST `head` lines ever logged (frozen, never evicted) —
        // each stamped "<Nms> hhpbt-probe-line-NNNN", so a suffix match on the zero-padded,
        // fixed-width marker is unambiguous (no digit-count collisions).
        for idx in 0..<head {
            let expectedSuffix = String(format: "hhpbt-probe-line-%04d", idx + 1)
            XCTAssertTrue(
                display[idx].hasSuffix(expectedSuffix),
                "head[\(idx)] = \(display[idx]) does not end with \(expectedSuffix)"
            )
        }

        // Elision marker sits between head and tail. Its count reflects everything logged past
        // head+tail capacity: 200 - 24 - 32 = 144 (assuming this test owns the whole process's
        // worth of HomeHeroProbe.log calls — see the caveat above).
        let expectedElided = totalLines - head - tail
        let markerIndex = head
        XCTAssertTrue(
            display[markerIndex].contains("\(expectedElided) lines elided"),
            "marker line = \(display[markerIndex]), expected an elided count of \(expectedElided)"
        )

        // Last `tail` entries are the LAST `tail` lines logged: 200-32+1 = 169 through 200.
        let tailStart = totalLines - tail + 1
        for offset in 0..<tail {
            let displayIdx = head + 1 + offset
            let expectedSuffix = String(format: "hhpbt-probe-line-%04d", tailStart + offset)
            XCTAssertTrue(
                display[displayIdx].hasSuffix(expectedSuffix),
                "tail[\(offset)] = \(display[displayIdx]) does not end with \(expectedSuffix)"
            )
        }
    }
}
