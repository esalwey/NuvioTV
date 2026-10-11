import XCTest
@testable import NuvioTV

/// The Detail hero's status badge, credit line and full release date are plain-string rules, so
/// they are checked without a view. Assertions avoid the localized wording where they can.
@MainActor
final class DetailHeroMetaTests: XCTestCase {

    func testReleasedAndBlankStatusesGetNoBadge() {
        XCTAssertNil(DetailHeroMeta.statusLabel(nil))
        XCTAssertNil(DetailHeroMeta.statusLabel("  "))
        XCTAssertNil(DetailHeroMeta.statusLabel("Released"))
        XCTAssertNil(DetailHeroMeta.statusLabel(" released "))
    }

    func testKnownStatusesGetABadgeAndUnknownOnesShowAsGiven() {
        for status in ["Ended", "Returning Series", "Continuing", "Canceled", "Cancelled", "In Production", "Post Production", "Planned", "Rumored", "Current"] {
            XCTAssertNotNil(DetailHeroMeta.statusLabel(status), status)
        }
        XCTAssertEqual(DetailHeroMeta.statusLabel("Pilot"), "Pilot")
    }

    func testCreditLineKeepsTwoNamesAndFallsBackToWriters() {
        let directed = DetailHeroMeta.creditLine(directors: ["A", "B", "C"], writers: ["W"], isSeries: false)
        XCTAssertNotNil(directed)
        XCTAssertTrue(directed?.contains("A, B") ?? false)
        XCTAssertFalse(directed?.contains("C") ?? true)
        XCTAssertFalse(directed?.contains("W") ?? true)

        let written = DetailHeroMeta.creditLine(directors: [], writers: ["W"], isSeries: false)
        XCTAssertTrue(written?.contains("W") ?? false)

        XCTAssertNil(DetailHeroMeta.creditLine(directors: [" "], writers: [], isSeries: true))
    }

    func testSeriesAndMovieCreditsReadDifferently() {
        XCTAssertNotEqual(
            DetailHeroMeta.creditLine(directors: ["A"], writers: [], isSeries: true),
            DetailHeroMeta.creditLine(directors: ["A"], writers: [], isSeries: false)
        )
    }

    func testFullReleaseDateIsACalendarDayInTheViewersLocale() {
        let formatted = DetailHeroMeta.fullReleaseDate("2010-07-16")
        XCTAssertNotNil(formatted)
        XCTAssertTrue(formatted?.contains("2010") ?? false)
        XCTAssertTrue(formatted?.contains("16") ?? false)
        XCTAssertEqual(DetailHeroMeta.fullReleaseDate("2010-07-16"), DetailHeroMeta.fullReleaseDate("2010-07-16T23:59:00Z"))
    }

    func testFullReleaseDateRejectsAnythingButAFullDate() {
        XCTAssertNil(DetailHeroMeta.fullReleaseDate(nil))
        XCTAssertNil(DetailHeroMeta.fullReleaseDate("2010"))
        XCTAssertNil(DetailHeroMeta.fullReleaseDate("2008-2013"))
        XCTAssertNil(DetailHeroMeta.fullReleaseDate("2010-13-40"))
    }
}
