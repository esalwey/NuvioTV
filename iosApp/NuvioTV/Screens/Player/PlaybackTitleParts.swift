import Foundation
import SharedCore

/// A title's display bits — name, logo, backdrop and the movie facts line — read synchronously
/// (`MetaDetailsRepository.peek`, never a network fetch), so the stream picker's header and the
/// player chrome can show the SERIES name, logo and backdrop, which no `PlaybackContext` carries,
/// without widening the context or its construction sites (`background` stays nil there: the
/// progress recorder persists it).
///
/// Each record read here, or handed over by the picker's own fetches (`remember`), is also kept per
/// title, and `peek` falls back to that copy once the repository has let go of it. On the main path
/// it does exactly that under the player: presenting the picker's cover makes DetailView disappear,
/// and `DetailViewModel.stop()` runs `MetaDetailsRepository.clear()` — after the picker has read the
/// record, before the transport bar, the pause card, the Up Next card and the end screen look for it.
struct CachedTitleArt: Equatable {
    var name: String?
    var logo: String?
    var background: String?
    /// The picker's movie facts (year · runtime · IMDb rating), for launch paths that pass no
    /// `PlaybackMeta` (Home's Continue Watching, a Top Shelf resume). Display only.
    var year: String?
    var runtime: String?
    var rating: String?

    init(name: String? = nil, logo: String? = nil, background: String? = nil,
         year: String? = nil, runtime: String? = nil, rating: String? = nil) {
        self.name = Self.nonEmpty(name)
        self.logo = Self.nonEmpty(logo)
        self.background = Self.nonEmpty(background)
        self.year = Self.nonEmpty(year)
        self.runtime = Self.nonEmpty(runtime)
        self.rating = Self.nonEmpty(rating)
    }

    /// From a catalog record: the facts are the fields `PlaybackMeta(details:)` reads.
    init(details: MetaDetails) {
        // Kotlin `String?` reads widened explicitly, as everywhere in this target.
        let name: String? = details.name
        let logo: String? = details.logo
        let background: String? = details.background
        let year: String? = details.releaseInfo
        let runtime: String? = details.runtime
        let rating: String? = details.imdbRating
        self.init(name: name, logo: logo, background: background, year: year, runtime: runtime, rating: rating)
    }

    /// nil when this session never saw the record (a cold Continue Watching or Top Shelf launch,
    /// before the picker's fetch lands).
    static func peek(type: String, id: String) -> CachedTitleArt? {
        if let details = MetaDetailsRepository.shared.peek(type: type, id: id) {
            return remember(details, type: type, id: id)
        }
        return seen[seenKey(type: type, id: id)]
    }

    /// Keeps a fetched record's display bits for its title (see the type doc) and returns them. The
    /// picker's fetches come through here because their result may never reach the repository: one
    /// that started before Details' clear is dropped by the repository's generation check.
    @discardableResult
    static func remember(_ details: MetaDetails, type: String, id: String) -> CachedTitleArt {
        let art = CachedTitleArt(details: details)
        let key = seenKey(type: type, id: id)
        if seen[key] == nil, seen.count >= seenLimit { seen.removeAll() }
        seen[key] = art
        return art
    }

    /// Last record seen per title — a few strings each, main-actor state like the rest of this
    /// target; dropped wholesale past `seenLimit` titles rather than tracking recency.
    private static var seen: [String: CachedTitleArt] = [:]
    private static let seenLimit = 64

    private static func seenKey(type: String, id: String) -> String { "\(type)|\(id)" }

    /// Blank addon values count as missing.
    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

/// How the stream picker and the player chrome name what's playing (AES-3/8/9): the series, the
/// episode code and the episode's own name kept apart, so no line repeats another. An episode's
/// launch title is usually "S1E4 · Name" (EpisodesSection, the Up Next hand-off) — the old pause card
/// printed exactly that right above "Season 1 · Episode 4", and never the series.
struct PlaybackTitleParts: Equatable {
    /// Series name — episodes only, when the shared meta cache has the record.
    let series: String?
    /// Localized episode code, "S1 · E4" ("S1 · É4" in French) — episodes only.
    let code: String?
    /// The episode's own name — episodes only, when known.
    let episodeName: String?
    /// The title the launch path carried: the movie's name; for an episode "S1E4 · Name", a bare
    /// "S1E4", or (some Continue Watching entries) the series name.
    let launchTitle: String
    /// The launch title is nothing but the verbatim code (Details' primary action with no name).
    let launchTitleIsBareCode: Bool

    init(launchTitle: String, season: Int?, episode: Int?, seriesName: String?, episodes: [MetaVideo]) {
        self.launchTitle = launchTitle
        guard let season, let episode else {
            series = nil
            code = nil
            episodeName = nil
            launchTitleIsBareCode = false
            return
        }
        series = CachedTitleArt.nonEmpty(seriesName)
        code = Self.episodeCode(season: season, episode: episode)
        let listed: String? = episodes.first { $0.season?.value == season && $0.episode?.value == episode }?.title
        episodeName = CachedTitleArt.nonEmpty(listed)
            ?? Self.name(afterCodeIn: launchTitle, season: season, episode: episode)
        launchTitleIsBareCode = launchTitle == "S\(season)E\(episode)"
    }

    /// The player's naming for its context: the series comes from the shared meta cache.
    init(context: PlaybackContext) {
        let art = context.season == nil ? nil : CachedTitleArt.peek(type: context.contentType, id: context.parentMetaId)
        self.init(launchTitle: context.title, season: context.season, episode: context.episode,
                  seriesName: art?.name, episodes: context.episodes)
    }

    var isEpisode: Bool { code != nil }

    /// The line that names the work: the series, or the movie. An episode whose series isn't known
    /// falls back to its own name, then to the launch title.
    var heading: String {
        guard isEpisode else { return launchTitle }
        return series ?? episodeName ?? launchTitle
    }

    /// The line under `heading`, episodes only: "S1 · E4 · Name" under the series, else the bare
    /// code (the heading already is the episode's name or the launch title) — nil when the heading
    /// is itself the code.
    var detail: String? {
        guard let code else { return nil }
        if series != nil, let episodeName { return "\(code) \u{00B7} \(episodeName)" }
        if series == nil, episodeName == nil, launchTitleIsBareCode { return nil }
        return code
    }

    /// The episode's own line where the series is shown on its own (the stream picker's header):
    /// its name, else — with no series to show — the launch title.
    var episodeLine: String? {
        guard isEpisode else { return nil }
        if let episodeName { return episodeName }
        return series == nil && !launchTitleIsBareCode ? launchTitle : nil
    }

    /// "S1 · E4" — the app's localized episode code (French "S1 · É4"), same key as the player's
    /// Info tab.
    static func episodeCode(season: Int, episode: Int) -> String {
        String(localized: "S\(season) · E\(episode)")
    }

    /// "Name" out of "S1E4 · Name", in the localized form EpisodesSection builds and the verbatim
    /// form of the Up Next hand-off (`NextEpisodeEngine.episodeTitle`).
    private static func name(afterCodeIn title: String, season: Int, episode: Int) -> String? {
        let marker = "\u{1F}"
        let localized = String(localized: "S\(season)E\(episode) \u{00B7} \(marker)")
        var prefixes: [String] = []
        if let range = localized.range(of: marker) {
            prefixes.append(String(localized[..<range.lowerBound]))
        }
        let verbatim = "S\(season)E\(episode) \u{00B7} "
        if !prefixes.contains(verbatim) { prefixes.append(verbatim) }
        for prefix in prefixes where title.hasPrefix(prefix) {
            return CachedTitleArt.nonEmpty(String(title.dropFirst(prefix.count)))
        }
        return nil
    }
}
