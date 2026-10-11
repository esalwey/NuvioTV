import XCTest
@testable import NuvioTV

/// Pure-logic coverage for Settings search: matching (case, diacritics, multi-word), ranking,
/// Developer gating and the integrity of the hand-maintained index.
final class SettingsSearchIndexTests: XCTestCase {

    private let locale = Locale(identifier: "en_US")

    private func entry(
        _ id: String,
        _ title: String,
        _ category: SettingsCategory = .appearance,
        section: String? = nil,
        keywords: [String] = [],
        developerOnly: Bool = false
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: id, title: title, category: category, section: section,
            keywords: keywords, developerOnly: developerOnly
        )
    }

    private func titles(_ query: String, in entries: [SettingsSearchEntry], developer: Bool = false) -> [String] {
        SettingsSearchIndex.search(query, in: entries, developerUnlocked: developer, locale: locale).map(\.title)
    }

    // MARK: - Matching

    func testEmptyQueryFindsNothing() {
        let entries = [entry("a", "Theme")]
        XCTAssertTrue(titles("", in: entries).isEmpty)
        XCTAssertTrue(titles("   ", in: entries).isEmpty)
    }

    func testMatchIgnoresCaseAndDiacritics() {
        let entries = [entry("a", "Cr\u{00E9}dits")]
        XCTAssertEqual(titles("credits", in: entries), ["Cr\u{00E9}dits"])
        XCTAssertEqual(titles("CR\u{00C9}DITS", in: entries), ["Cr\u{00E9}dits"])
    }

    func testEveryWordMustMatchSomewhere() {
        let entries = [
            entry("a", "Skip Intro", .playback, keywords: ["outro"]),
            entry("b", "Show Hero", .homeScreen),
        ]
        XCTAssertEqual(titles("skip outro", in: entries), ["Skip Intro"])
        XCTAssertTrue(titles("skip hero", in: entries).isEmpty)
    }

    func testKeywordsAndLocationAreSearched() {
        let entries = [entry("a", "MDBList Ratings", .contentSources, section: "Ratings (MDBList)", keywords: ["rotten tomatoes"])]
        XCTAssertEqual(titles("rotten", in: entries), ["MDBList Ratings"])
        XCTAssertEqual(titles("content sources", in: entries), ["MDBList Ratings"])
    }

    // MARK: - Ranking

    func testTitlePrefixBeatsContainsBeatsKeyword() {
        let entries = [
            entry("kw", "Ratings Providers", keywords: ["theme"]),
            entry("contains", "Custom Theme Color"),
            entry("prefix", "Theme"),
        ]
        XCTAssertEqual(titles("theme", in: entries), ["Theme", "Custom Theme Color", "Ratings Providers"])
    }

    func testEqualRankKeepsIndexOrder() {
        let entries = [entry("1", "Audio Delay"), entry("2", "Audio Boost"), entry("3", "Audio Output")]
        XCTAssertEqual(titles("audio", in: entries), ["Audio Delay", "Audio Boost", "Audio Output"])
    }

    // MARK: - Developer gating

    func testDeveloperEntriesNeedTheUnlock() {
        let entries = [
            entry("a", "Plain Search Field", .developer, developerOnly: true),
            entry("b", "Plain Text", .appearance),
        ]
        XCTAssertEqual(titles("plain", in: entries, developer: false), ["Plain Text"])
        XCTAssertEqual(titles("plain", in: entries, developer: true).count, 2)
    }

    // MARK: - Location line

    func testLocationShowsSectionUnlessItRepeatsTheCategory() {
        let nested = entry("a", "Theme", .appearance, section: "Theme")
        XCTAssertEqual(nested.location, "\(SettingsCategory.appearance.title) \u{203A} Theme")
        let top = entry("b", "Playback", .playback, section: SettingsCategory.playback.title)
        XCTAssertEqual(top.location, SettingsCategory.playback.title)
        let none = entry("c", "Add-ons", .addons)
        XCTAssertEqual(none.location, SettingsCategory.addons.title)
    }

    // MARK: - Index integrity

    func testIndexIdsAreUnique() {
        let ids = SettingsSearchIndex.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testIndexCoversTheRowsTheGapReportNames() {
        let entries = SettingsSearchIndex.entries
        let all = SettingsSearchIndex.search("mdblist", in: entries, developerUnlocked: false)
        XCTAssertFalse(all.isEmpty)
        XCTAssertFalse(SettingsSearchIndex.search("rating visibility", in: entries, developerUnlocked: false).isEmpty)
        XCTAssertFalse(SettingsSearchIndex.search("theme", in: entries, developerUnlocked: false).isEmpty)
        XCTAssertFalse(SettingsSearchIndex.search("language", in: entries, developerUnlocked: false).isEmpty)
        XCTAssertFalse(SettingsSearchIndex.search("trakt", in: entries, developerUnlocked: false).isEmpty)
    }

    func testDeveloperEntriesAreAllFlaggedAndOnlyDeveloperEntriesAre() {
        for entry in SettingsSearchIndex.entries {
            XCTAssertEqual(entry.developerOnly, entry.category == .developer, entry.id)
        }
    }

    func testEveryEntryHasATitle() {
        for entry in SettingsSearchIndex.entries {
            XCTAssertFalse(entry.title.isEmpty, entry.id)
        }
    }
}
