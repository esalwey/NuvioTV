import XCTest
@testable import NuvioTV

/// Unit tests for `PlayerAudioLanguagePlan` (`Screens/Player/PlayerAudioLanguagePlan.swift`) — the
/// pure mpv `alang`/force-track decision logic backing upstream 4f79bfe0's proactive audio-language
/// preference. Covers the priority-order walk over `trackToForce` and the comma-join in
/// `alangValue`. No mpv/UIKit dependency, so these run as plain XCTest against the real app target
/// via `@testable import NuvioTV`, matching `SubtitleVTTShiftTests`.
final class PlayerAudioLanguagePlanTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTracks(_ tracks: (id: Int, lang: String, selected: Bool)...) -> [(id: Int, lang: String, title: String, selected: Bool)] {
        tracks.map { (id: $0.id, lang: $0.lang, title: "", selected: $0.selected) }
    }

    private func makeTitledTracks(
        _ tracks: (id: Int, lang: String, title: String, selected: Bool)...
    ) -> [(id: Int, lang: String, title: String, selected: Bool)] {
        tracks
    }

    // MARK: - alangValue

    func testAlangValueJoinsTargetsInOrder() {
        XCTAssertEqual(PlayerAudioLanguagePlan.alangValue(targets: ["ja", "en"]), "ja,en")
        XCTAssertEqual(PlayerAudioLanguagePlan.alangValue(targets: []), "")
    }

    // MARK: - trackToForce

    func testEmptyTargetsForcesNothing() {
        let tracks = makeTracks((id: 1, lang: "en", selected: false))
        XCTAssertNil(PlayerAudioLanguagePlan.trackToForce(targets: [], tracks: tracks))
    }

    func testNoMatchingTrackLeavesDefault() {
        let tracks = makeTracks(
            (id: 1, lang: "en", selected: true),
            (id: 2, lang: "fr", selected: false)
        )
        XCTAssertNil(PlayerAudioLanguagePlan.trackToForce(targets: ["ja"], tracks: tracks))
    }

    func testAlreadySelectedMatchDoesNotRepoke() {
        let tracks = makeTracks(
            (id: 1, lang: "en", selected: false),
            (id: 2, lang: "ja", selected: true)
        )
        XCTAssertNil(PlayerAudioLanguagePlan.trackToForce(targets: ["ja"], tracks: tracks))
    }

    func testUnselectedMatchIsForced() {
        let tracks = makeTracks(
            (id: 1, lang: "en", selected: true),
            (id: 2, lang: "ja", selected: false),
            (id: 3, lang: "ja", selected: false)
        )
        XCTAssertEqual(PlayerAudioLanguagePlan.trackToForce(targets: ["ja"], tracks: tracks), 2)
    }

    func testSecondaryTargetOnlyWhenPrimaryHasNoHit() {
        let noPrimaryHit = makeTracks(
            (id: 1, lang: "en", selected: true),
            (id: 2, lang: "de", selected: false)
        )
        XCTAssertEqual(PlayerAudioLanguagePlan.trackToForce(targets: ["ja", "de"], tracks: noPrimaryHit), 2)

        // Primary target wins even though the secondary target's track is already selected —
        // the walk stops at the first target with any match, it never looks past it.
        let primaryHitButUnselected = makeTracks(
            (id: 1, lang: "ja", selected: false),
            (id: 2, lang: "de", selected: true)
        )
        XCTAssertEqual(PlayerAudioLanguagePlan.trackToForce(targets: ["ja", "de"], tracks: primaryHitButUnselected), 1)
    }

    func testIso6392TrackMatchesIso6391Target() {
        // "eng"/"jpn" are ISO-639-2 codes; `languageMatchesPreference` normalizes both to
        // ISO-639-1 ("en"/"ja") via `LanguageCodeAliases` before comparing.
        let tracks = makeTracks(
            (id: 1, lang: "eng", selected: true),
            (id: 2, lang: "jpn", selected: false)
        )
        XCTAssertEqual(PlayerAudioLanguagePlan.trackToForce(targets: ["ja"], tracks: tracks), 2)
    }

    func testRegionalTrackMatchesBaseTarget() {
        // "pt-BR" normalizes to "pt-br"; matching against target "pt" falls through to the
        // primary-subtag comparison ("pt" == "pt") since the full codes differ.
        let tracks = makeTracks(
            (id: 1, lang: "en", selected: true),
            (id: 2, lang: "pt-BR", selected: false)
        )
        XCTAssertEqual(PlayerAudioLanguagePlan.trackToForce(targets: ["pt"], tracks: tracks), 2)
    }

    // MARK: - LANG-10: variants and titles

    func testFrenchTargetPrefersTheFranceDub() {
        let tracks = makeTitledTracks(
            (id: 1, lang: "fre", title: "VFQ", selected: true),
            (id: 2, lang: "fre", title: "VFF", selected: false)
        )
        XCTAssertEqual(PlayerAudioLanguagePlan.trackToForce(targets: ["fr"], tracks: tracks), 2)
    }

    func testQuebecTargetPrefersTheQuebecDub() {
        let tracks = makeTitledTracks(
            (id: 1, lang: "fre", title: "VFF", selected: true),
            (id: 2, lang: "fre", title: "VFQ", selected: false)
        )
        XCTAssertEqual(PlayerAudioLanguagePlan.trackToForce(targets: ["fr-CA"], tracks: tracks), 2)
    }

    func testSelectedExactVariantIsLeftAlone() {
        let tracks = makeTitledTracks(
            (id: 1, lang: "fre", title: "VFF", selected: true),
            (id: 2, lang: "fre", title: "VFQ", selected: false)
        )
        XCTAssertNil(PlayerAudioLanguagePlan.trackToForce(targets: ["fr"], tracks: tracks))
    }

    func testUntaggedTrackMatchesByNativeTitle() {
        let tracks = makeTitledTracks(
            (id: 1, lang: "", title: "English", selected: true),
            (id: 2, lang: "und", title: "Español", selected: false)
        )
        XCTAssertEqual(PlayerAudioLanguagePlan.trackToForce(targets: ["es"], tracks: tracks), 2)
    }

    func testTaggedTrackIsNotOverriddenByItsTitle() {
        let tracks = makeTitledTracks(
            (id: 1, lang: "eng", title: "Français", selected: true),
            (id: 2, lang: "ger", title: "Deutsch", selected: false)
        )
        XCTAssertNil(PlayerAudioLanguagePlan.trackToForce(targets: ["fr"], tracks: tracks))
    }

    func testAppleTvFranceTargetPrefersTheFranceDub() {
        // An Apple TV in French (France) yields "fr-fr" before "fr".
        let tracks = makeTitledTracks(
            (id: 1, lang: "fre", title: "VFQ", selected: true),
            (id: 2, lang: "fre", title: "VFF", selected: false)
        )
        XCTAssertEqual(PlayerAudioLanguagePlan.trackToForce(targets: ["fr-fr", "fr"], tracks: tracks), 2)
    }

    func testAlangValueAddsTheBaseOfARegionalTarget() {
        XCTAssertEqual(PlayerAudioLanguagePlan.alangValue(targets: ["fr-ca", "fr", "en"]), "fr-ca,fr,en")
        XCTAssertEqual(PlayerAudioLanguagePlan.alangValue(targets: ["fr-ca", "en"]), "fr-ca,fr,en")
    }

    func testTrackLanguageTagCarriesTheTitleVariant() {
        XCTAssertEqual(TrackLabelFormatter.trackLanguageTag(language: "fre", title: "VFQ"), "fr-CA")
        XCTAssertEqual(TrackLabelFormatter.trackLanguageTag(language: "fre", title: "French (Canada)"), "fr-CA")
        XCTAssertEqual(TrackLabelFormatter.trackLanguageTag(language: "fre", title: "VFF"), "fr")
        XCTAssertEqual(TrackLabelFormatter.trackLanguageTag(language: "fr-FR", title: nil), "fr-FR")
        XCTAssertEqual(TrackLabelFormatter.trackLanguageTag(language: nil, title: "VFQ"), "fr-CA")
        XCTAssertEqual(TrackLabelFormatter.trackLanguageTag(language: "eng", title: "VFQ"), "en")
    }

    func testReleaseTag() {
        XCTAssertEqual(TrackLabelFormatter.releaseTag("VFQ 5.1"), "VFQ")
        XCTAssertEqual(TrackLabelFormatter.releaseTag("French TrueFrench"), "TrueFrench")
        XCTAssertEqual(TrackLabelFormatter.releaseTag("VF VFF"), "VFF")
        XCTAssertNil(TrackLabelFormatter.releaseTag("VFX breakdown"))
        XCTAssertNil(TrackLabelFormatter.releaseTag(nil))
    }

    // MARK: - TrackLabelFormatter (contract C3)

    func testNormalizedTagIsBcp47() {
        XCTAssertEqual(TrackLabelFormatter.normalizedTag("fre"), "fr")
        XCTAssertEqual(TrackLabelFormatter.normalizedTag("ger"), "de")
        XCTAssertEqual(TrackLabelFormatter.normalizedTag("pt-br"), "pt-BR")
        XCTAssertEqual(TrackLabelFormatter.normalizedTag("es-419"), "es-419")
        XCTAssertEqual(TrackLabelFormatter.normalizedTag("VFQ"), "fr-CA")
        XCTAssertNil(TrackLabelFormatter.normalizedTag("und"))
        XCTAssertNil(TrackLabelFormatter.normalizedTag(""))
        XCTAssertNil(TrackLabelFormatter.normalizedTag(nil))
        XCTAssertNil(TrackLabelFormatter.normalizedTag("Commentary"))
    }

    func testLanguageNameIsNeverARawCode() {
        let name = TrackLabelFormatter.languageName("fre")
        XCTAssertNotNil(name)
        XCTAssertNotEqual(name?.lowercased(), "fre")
        XCTAssertNotEqual(name?.lowercased(), "fr")
        XCTAssertNil(TrackLabelFormatter.languageName("und"))
    }

    func testAudioDetail() {
        XCTAssertEqual(TrackLabelFormatter.audioDetail(codec: "eac3", channels: 6, atmos: false), "Dolby Digital+ 5.1")
        XCTAssertEqual(TrackLabelFormatter.audioDetail(codec: "truehd", channels: 8, atmos: true), "Dolby Atmos")
        XCTAssertEqual(TrackLabelFormatter.audioDetail(codec: "ac3", channels: 6, atmos: false), "Dolby Digital 5.1")
        XCTAssertNil(TrackLabelFormatter.audioDetail(codec: nil, channels: nil, atmos: false))
    }

    func testSubtitleDetail() {
        XCTAssertNil(TrackLabelFormatter.subtitleDetail(forced: false, sdh: false))
        XCTAssertNotNil(TrackLabelFormatter.subtitleDetail(forced: true, sdh: false))
        XCTAssertEqual(TrackLabelFormatter.subtitleDetail(forced: false, sdh: false, codec: "subrip"), "SRT")
    }

    func testTitleDescriptorDropsRepeats() {
        XCTAssertNil(TrackLabelFormatter.titleDescriptor("English", language: "eng"))
        XCTAssertNil(TrackLabelFormatter.titleDescriptor("SDH", language: "eng"))
        XCTAssertEqual(TrackLabelFormatter.titleDescriptor("Commentary", language: "eng"), "Commentary")
    }
}
