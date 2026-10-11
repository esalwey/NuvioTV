import XCTest
@testable import NuvioTV

/// The Subtitle List setting: how the Subtitles menu groups its rows (mpv: section headers) and how
/// the native player's renditions are ordered to match.
@MainActor
final class SubtitleOrganizationTests: XCTestCase {

    private func option(_ id: String, language: String?, addon: String? = nil,
                        group: PlayerPanelOption.Group = .addon,
                        selected: Bool = false) -> PlayerPanelOption {
        PlayerPanelOption(id: id, title: id, language: language, addonName: addon, group: group, isSelected: selected)
    }

    private var off: PlayerPanelOption {
        PlayerPanelOption(id: "off", title: "Off", group: .off, isSelected: false)
    }

    /// Off, two tracks of the file, then add-on subtitles from two add-ons.
    private var menu: [PlayerPanelOption] {
        [
            off,
            option("e-fr", language: "fr", group: .embedded),
            option("e-en", language: "en", group: .embedded),
            option("a-en", language: "en", addon: "OpenSubtitles"),
            option("b-fr", language: "fr", addon: "Subdl"),
            option("a-pt", language: "pt-BR", addon: "OpenSubtitles"),
            option("a-xx", language: nil, addon: "OpenSubtitles"),
            option("b-es", language: "es", addon: "Subdl"),
        ]
    }

    private func ids(_ sections: [PlayerSubtitleSection]) -> [String] { sections.map(\.id) }
    private func rows(_ section: PlayerSubtitleSection) -> [String] { section.options.map(\.id) }

    // MARK: - Setting

    func testTheStoredChoiceDefaultsToUngrouped() {
        UserDefaults.standard.removeObject(forKey: SubtitleOrganization.storageKey)
        XCTAssertEqual(SubtitleOrganization.current, .ungrouped)
        UserDefaults.standard.set("garbage", forKey: SubtitleOrganization.storageKey)
        XCTAssertEqual(SubtitleOrganization.current, .ungrouped)
        UserDefaults.standard.set(SubtitleOrganization.byAddon.rawValue, forKey: SubtitleOrganization.storageKey)
        XCTAssertEqual(SubtitleOrganization.current, .byAddon)
        UserDefaults.standard.removeObject(forKey: SubtitleOrganization.storageKey)
    }

    // MARK: - Sections

    func testUngroupedIsOneSectionWithoutAHeader() {
        let sections = SubtitleOrganizer.sections(menu, organization: .ungrouped)
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
        XCTAssertEqual(rows(sections[0]), menu.map(\.id))
        XCTAssertTrue(SubtitleOrganizer.sections([], organization: .ungrouped).isEmpty)
    }

    func testByLanguageGroupsEveryRowUnderItsLanguage() {
        let sections = SubtitleOrganizer.sections(menu, organization: .byLanguage)
        XCTAssertEqual(ids(sections), ["off", "language:fr", "language:en", "language:pt-br", "language:es", "language:"])
        XCTAssertNil(sections[0].title)
        XCTAssertEqual(rows(sections[1]), ["e-fr", "b-fr"])
        XCTAssertEqual(rows(sections[2]), ["e-en", "a-en"])
        XCTAssertEqual(rows(sections[3]), ["a-pt"])
        XCTAssertEqual(rows(sections[5]), ["a-xx"])
        XCTAssertNotNil(sections[1].title)
        XCTAssertNotNil(sections[5].title)
    }

    func testByLanguageListsThePreferredLanguagesFirst() {
        // Spanish, then English, wanted; the rest equal and in order of appearance.
        let wanted = ["es", "en"]
        let sections = SubtitleOrganizer.sections(menu, organization: .byLanguage) { language in
            guard let language else { return wanted.count }
            return wanted.firstIndex(of: language.lowercased()) ?? wanted.count
        }
        XCTAssertEqual(ids(sections), ["off", "language:es", "language:en", "language:fr", "language:pt-br", "language:"])
    }

    func testByAddonKeepsTheFilesOwnTracksTogetherThenOneSectionPerAddon() {
        let sections = SubtitleOrganizer.sections(menu, organization: .byAddon)
        XCTAssertEqual(ids(sections), ["off", "builtin", "addon:OpenSubtitles", "addon:Subdl"])
        XCTAssertEqual(rows(sections[1]), ["e-fr", "e-en"])
        XCTAssertEqual(rows(sections[2]), ["a-en", "a-pt", "a-xx"])
        XCTAssertEqual(rows(sections[3]), ["b-fr", "b-es"])
        XCTAssertEqual(sections[2].title, "OpenSubtitles")
    }

    func testAnAddonRowWithoutAnAddonNameGetsTheGenericHeader() {
        let sections = SubtitleOrganizer.sections([off, option("x", language: "en", addon: nil)], organization: .byAddon)
        XCTAssertEqual(ids(sections), ["off", "addon:"])
        XCTAssertNotNil(sections[1].title)
    }

    func testTheSelectedRowStaysMarkedInItsSection() {
        var options = menu
        options[3] = option("a-en", language: "en", addon: "OpenSubtitles", selected: true)
        let sections = SubtitleOrganizer.sections(options, organization: .byLanguage)
        XCTAssertEqual(sections.flatMap(\.options).filter(\.isSelected).map(\.id), ["a-en"])
    }

    // MARK: - Ordering for the native player

    private struct Item: Equatable {
        let id: String
        let language: String?
        let addon: String?
    }

    private let items = [
        Item(id: "1", language: "en", addon: "A"),
        Item(id: "2", language: "fr", addon: "B"),
        Item(id: "3", language: "en", addon: "B"),
        Item(id: "4", language: "pt-BR", addon: "A"),
        Item(id: "5", language: "fr", addon: "A"),
    ]

    private func arranged(_ organization: SubtitleOrganization) -> [String] {
        SubtitleOrganizer.arranged(items, organization: organization, language: { $0.language }, addon: { $0.addon })
            .map(\.id)
    }

    func testUngroupedKeepsTheOrder() {
        XCTAssertEqual(arranged(.ungrouped), ["1", "2", "3", "4", "5"])
    }

    func testByLanguageGroupsInOrderOfFirstAppearance() {
        XCTAssertEqual(arranged(.byLanguage), ["1", "3", "2", "5", "4"])
    }

    func testByAddonGroupsInOrderOfFirstAppearance() {
        XCTAssertEqual(arranged(.byAddon), ["1", "4", "5", "2", "3"])
    }

    func testRegionVariantsOfOneLanguageStaySeparateButCaseDoesNotMatter() {
        let mixed = [
            Item(id: "1", language: "pt-br", addon: nil),
            Item(id: "2", language: "pt", addon: nil),
            Item(id: "3", language: "pt-BR", addon: nil),
        ]
        let order = SubtitleOrganizer.arranged(mixed, organization: .byLanguage, language: { $0.language },
                                               addon: { $0.addon }).map(\.id)
        XCTAssertEqual(order, ["1", "3", "2"])
    }
}
