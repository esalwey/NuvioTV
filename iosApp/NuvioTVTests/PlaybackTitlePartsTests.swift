import XCTest
import SharedCore
@testable import NuvioTV

/// Unit tests for `PlaybackTitleParts` (`Screens/Player/PlaybackTitleParts.swift`) — how the stream
/// picker header, the mpv transport bar / pause card and the end screen name what's playing
/// (AES-3/8/9): series, episode code and episode name, never the same fact twice. The episode list
/// is left empty so the launch-title parsing is what's exercised; codes are built with the same
/// localized helper, so the assertions hold in any test locale.
@MainActor
final class PlaybackTitlePartsTests: XCTestCase {

    /// Computed, not stored: a stored initializer would run in XCTestCase's nonisolated init.
    private var code: String { PlaybackTitleParts.episodeCode(season: 1, episode: 4) }

    func testMovieIsItsLaunchTitleAlone() {
        let parts = PlaybackTitleParts(launchTitle: "Dune", season: nil, episode: nil,
                                       seriesName: "ignored", episodes: [])
        XCTAssertFalse(parts.isEpisode)
        XCTAssertEqual(parts.heading, "Dune")
        XCTAssertNil(parts.detail)
        XCTAssertNil(parts.episodeLine)
    }

    func testEpisodeWithSeriesHeadsWithTheSeries() {
        let parts = PlaybackTitleParts(launchTitle: "S1E4 \u{00B7} Pilot", season: 1, episode: 4,
                                       seriesName: "Breaking Bad", episodes: [])
        XCTAssertEqual(parts.heading, "Breaking Bad")
        XCTAssertEqual(parts.detail, "\(code) \u{00B7} Pilot")
        XCTAssertEqual(parts.episodeLine, "Pilot")
    }

    func testEpisodeWithoutSeriesHeadsWithItsName() {
        let parts = PlaybackTitleParts(launchTitle: "S1E4 \u{00B7} Pilot", season: 1, episode: 4,
                                       seriesName: nil, episodes: [])
        XCTAssertEqual(parts.heading, "Pilot")
        XCTAssertEqual(parts.detail, code)
    }

    func testBareCodeTitleIsNotRepeated() {
        let parts = PlaybackTitleParts(launchTitle: "S1E4", season: 1, episode: 4,
                                       seriesName: nil, episodes: [])
        XCTAssertEqual(parts.heading, "S1E4")
        XCTAssertNil(parts.detail)
        XCTAssertNil(parts.episodeLine)
    }

    func testSeriesNameLaunchTitleKeepsTheCode() {
        // Continue Watching entries can carry the series name as their title.
        let parts = PlaybackTitleParts(launchTitle: "Breaking Bad", season: 1, episode: 4,
                                       seriesName: nil, episodes: [])
        XCTAssertEqual(parts.heading, "Breaking Bad")
        XCTAssertEqual(parts.detail, code)
        XCTAssertEqual(parts.episodeLine, "Breaking Bad")
    }

    func testPrefixMustBeTheExactEpisodeCode() {
        // Episode 4's prefix must not eat episode 40's title.
        let parts = PlaybackTitleParts(launchTitle: "S1E40 \u{00B7} Finale", season: 1, episode: 4,
                                       seriesName: "Show", episodes: [])
        XCTAssertNil(parts.episodeName)
        XCTAssertEqual(parts.detail, code)
    }

    func testBlankSeriesNameCountsAsMissing() {
        let parts = PlaybackTitleParts(launchTitle: "S1E4 \u{00B7} Pilot", season: 1, episode: 4,
                                       seriesName: "  ", episodes: [])
        XCTAssertNil(parts.series)
        XCTAssertEqual(parts.heading, "Pilot")
    }
}
