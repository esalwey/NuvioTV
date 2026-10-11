import Foundation

// How the Subtitles menu lists its rows (Settings > Playback > Subtitle List). A title that carries
// dozens of add-on subtitles reads better grouped: by language, or by the add-on that offered them.
// The setting is this Apple TV's own (the phone has none), and both engines follow it:
//  - the mpv player's Subtitles menu gets section headers (`PlayerSubtitleSection`);
//  - the native player's system popover has no headers to give, so there the order of the
//    renditions follows the grouping (`SubtitleOrganizer.arranged`).

/// Grouping of the Subtitles menu.
enum SubtitleOrganization: String, CaseIterable, Identifiable, Hashable {
    /// One flat list: Off, the file's tracks, then the add-on subtitles in rank order (the default).
    case ungrouped = "none"
    /// One section per language, the viewer's preferred languages first.
    case byLanguage
    /// The file's own tracks, then one section per add-on.
    case byAddon

    /// UserDefaults key, device-local like the other player tuning keys.
    static let storageKey = "player.subtitles.organization"

    var id: String { rawValue }

    /// The stored choice; absent or unknown reads as `.ungrouped`.
    static var current: SubtitleOrganization {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SubtitleOrganization.init(rawValue:)) ?? .ungrouped
    }

    var title: String {
        switch self {
        case .ungrouped:
            return String(localized: "settings.subtitleList.none", defaultValue: "Not Grouped",
                          comment: "Subtitle List option: one flat list of subtitles.")
        case .byLanguage:
            return String(localized: "settings.subtitleList.byLanguage", defaultValue: "By Language",
                          comment: "Subtitle List option: subtitles grouped under a header per language.")
        case .byAddon:
            return String(localized: "settings.subtitleList.byAddon", defaultValue: "By Add-on",
                          comment: "Subtitle List option: subtitles grouped under a header per add-on.")
        }
    }

    var detail: String {
        switch self {
        case .ungrouped:
            return String(localized: "settings.subtitleList.none.detail",
                          defaultValue: "The Subtitles menu lists the file's subtitles, then those from add-ons, best match first.",
                          comment: "Explanation of the Not Grouped subtitle list.")
        case .byLanguage:
            return String(localized: "settings.subtitleList.byLanguage.detail",
                          defaultValue: "The Subtitles menu groups subtitles under their language, your preferred languages first.",
                          comment: "Explanation of the By Language subtitle list.")
        case .byAddon:
            return String(localized: "settings.subtitleList.byAddon.detail",
                          defaultValue: "The Subtitles menu lists the file's subtitles, then one group per add-on.",
                          comment: "Explanation of the By Add-on subtitle list.")
        }
    }
}

/// One block of the Subtitles menu: a header (nil for the block that has none) over its rows.
struct PlayerSubtitleSection: Identifiable, Equatable {
    let id: String
    let title: String?
    let options: [PlayerPanelOption]
}

enum SubtitleOrganizer {
    /// Groups `items` by `key`, groups in order of their first item, items in their order; the
    /// order of a group is `rank` first (lower first), first appearance after. Items without a key
    /// share the last group.
    static func grouped<T>(_ items: [T], key: (T) -> String?, rank: (String?) -> Int = { _ in 0 })
        -> [(key: String?, items: [T])] {
        var order: [String] = []
        var buckets: [String: [T]] = [:]
        var unkeyed: [T] = []
        for item in items {
            if let k = key(item), !k.isEmpty {
                if buckets[k] == nil { order.append(k) }
                buckets[k, default: []].append(item)
            } else {
                unkeyed.append(item)
            }
        }
        let ranked = order.enumerated()
            .sorted { lhs, rhs in
                let l = rank(lhs.element), r = rank(rhs.element)
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map { $0.element }
        var groups: [(key: String?, items: [T])] = ranked.map { k in (key: k, items: buckets[k] ?? []) }
        if !unkeyed.isEmpty { groups.append((key: nil, items: unkeyed)) }
        return groups
    }

    /// `items` in the order the organization lists them: unchanged for `.ungrouped`, grouped
    /// (stably) otherwise. For engines that can only order rows.
    static func arranged<T>(_ items: [T], organization: SubtitleOrganization,
                            language: (T) -> String?, addon: (T) -> String?) -> [T] {
        switch organization {
        case .ungrouped:
            return items
        case .byLanguage:
            return grouped(items, key: { normalizedLanguageKey(language($0)) }).flatMap { $0.items }
        case .byAddon:
            return grouped(items, key: { addon($0).flatMap(trimmed) }).flatMap { $0.items }
        }
    }

    /// The menu's blocks for `options` (Off first, in a block of its own without a header).
    /// `languageRank` orders the language groups (lower first; the viewer's preferred languages
    /// first, the rest equal and so in order of appearance).
    static func sections(_ options: [PlayerPanelOption], organization: SubtitleOrganization,
                         languageRank: (String?) -> Int = { _ in 0 }) -> [PlayerSubtitleSection] {
        guard organization != .ungrouped else {
            return options.isEmpty ? [] : [PlayerSubtitleSection(id: "all", title: nil, options: options)]
        }
        let off = options.filter { $0.group == .off }
        let rows = options.filter { $0.group != .off }
        var sections: [PlayerSubtitleSection] = []
        if !off.isEmpty { sections.append(PlayerSubtitleSection(id: "off", title: nil, options: off)) }
        switch organization {
        case .ungrouped:
            break
        case .byLanguage:
            for group in grouped(rows, key: { normalizedLanguageKey($0.language) }, rank: languageRank) {
                sections.append(PlayerSubtitleSection(
                    id: "language:\(group.key ?? "")",
                    title: group.key.flatMap { TrackLabelFormatter.languageName($0) } ?? otherTitle,
                    options: group.items))
            }
        case .byAddon:
            let builtIn = rows.filter { $0.group != .addon }
            if !builtIn.isEmpty {
                sections.append(PlayerSubtitleSection(id: "builtin", title: builtInTitle, options: builtIn))
            }
            let addonRows = rows.filter { $0.group == .addon }
            for group in grouped(addonRows, key: { $0.addonName.flatMap(trimmed) }) {
                sections.append(PlayerSubtitleSection(
                    id: "addon:\(group.key ?? "")",
                    title: group.key ?? addonsTitle,
                    options: group.items))
            }
        }
        return sections
    }

    // MARK: - Helpers

    /// "pt-br" and "pt-BR" are one language; rows with no usable language have no key.
    static func normalizedLanguageKey(_ language: String?) -> String? {
        guard let tag = TrackLabelFormatter.normalizedTag(language) else { return nil }
        return tag.lowercased()
    }

    private static func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static var otherTitle: String {
        String(localized: "player.subtitles.otherLanguage", defaultValue: "Other",
               comment: "Subtitles menu group header for subtitles whose language is unknown.")
    }

    private static var builtInTitle: String {
        String(localized: "player.subtitles.builtIn", defaultValue: "In the File",
               comment: "Subtitles menu group header for the subtitles that come with the video file itself.")
    }

    private static var addonsTitle: String {
        String(localized: "player.subtitles.addons", defaultValue: "Add-ons",
               comment: "Subtitles menu group header for add-on subtitles whose add-on is unknown.")
    }
}
