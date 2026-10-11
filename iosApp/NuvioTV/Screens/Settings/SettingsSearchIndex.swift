import Foundation

/// One searchable setting: where it lives and the words that should find it.
///
/// The index below is maintained by hand next to the panes, the same way the mobile app's
/// `SettingsSearch.kt` is. `section` is the pane's own section title (the exact string the pane
/// passes to `SettingsSection`), which is also the scroll anchor Settings jumps to.
struct SettingsSearchEntry: Identifiable, Equatable {
    let id: String
    /// The row's title as the pane shows it (already localised).
    let title: String
    let category: SettingsCategory
    /// Section title inside the pane, or nil when the entry is the whole pane.
    let section: String?
    /// Extra search terms that are not in the title (synonyms, provider names). Matched in
    /// English and in the app language; never shown.
    let keywords: [String]
    /// Hidden until the Developer pane is unlocked (`DeveloperMode`).
    var developerOnly = false

    /// "Appearance \u{203A} Theme" - the line under the title in a result row.
    var location: String {
        guard let section, !section.isEmpty, section != category.title else { return category.title }
        return "\(category.title) \u{203A} \(section)"
    }
}

/// Scroll anchors shared by `SettingsSection` (which tags its header) and the search jump.
enum SettingsSearchAnchor {
    static func id(for sectionTitle: String) -> String { "settings.section.\(sectionTitle)" }
}

enum SettingsSearchIndex {

    // MARK: - Matching (pure)

    /// Entries matching `query`, best first. Every whitespace-separated word of the query must
    /// appear somewhere in the entry's title, location or keywords, ignoring case and diacritics.
    /// Ranking: title starts with the query, then title contains it, then the rest, each group in
    /// index order so the result is stable.
    static func search(
        _ query: String,
        in entries: [SettingsSearchEntry],
        developerUnlocked: Bool,
        locale: Locale = .current
    ) -> [SettingsSearchEntry] {
        let words = fold(query, locale: locale)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return [] }
        let whole = words.joined(separator: " ")

        var scored: [(entry: SettingsSearchEntry, rank: Int, order: Int)] = []
        for (order, entry) in entries.enumerated() {
            if entry.developerOnly && !developerUnlocked { continue }
            let title = fold(entry.title, locale: locale)
            let haystack = ([title, fold(entry.location, locale: locale)]
                + entry.keywords.map { fold($0, locale: locale) })
                .joined(separator: " ")
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            let rank: Int
            if title.hasPrefix(whole) {
                rank = 0
            } else if title.contains(whole) {
                rank = 1
            } else if words.allSatisfy({ title.contains($0) }) {
                rank = 2
            } else {
                rank = 3
            }
            scored.append((entry, rank, order))
        }
        return scored
            .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .map(\.entry)
    }

    static func fold(_ text: String, locale: Locale = .current) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    // MARK: - The index

    /// Built on demand so every title resolves in the language the app is running in.
    static var entries: [SettingsSearchEntry] { makeEntries() }

    private static func makeEntries() -> [SettingsSearchEntry] {
        var list: [SettingsSearchEntry] = []
        func add(
            _ category: SettingsCategory,
            _ section: String?,
            _ id: String,
            _ title: String,
            _ keywords: [String] = [],
            developerOnly: Bool = false
        ) {
            list.append(SettingsSearchEntry(
                id: "\(category.rawValue).\(id)",
                title: title,
                category: category,
                section: section,
                keywords: keywords,
                developerOnly: developerOnly
            ))
        }

        // MARK: Account & Services
        let account = String(localized: "Account")
        add(.accountServices, account, "signIn", String(localized: "Sign In to Nuvio"),
            ["login", "log in", "account", "sync", "cloud"])
        add(.accountServices, account, "signOut", String(localized: "Sign Out"),
            ["logout", "log out", "account", "guest"])
        add(.accountServices, account, "syncCode", String(localized: "Sync Code"),
            ["link", "device", "pin", "pair", "account-less"])
        let server = String(localized: "Server")
        add(.accountServices, server, "server", String(localized: "Server"),
            ["self-hosted", "self hosted", "backend", "supabase", "official", "api.nuvio.tv"])
        let trakt = String(localized: "Trakt")
        add(.accountServices, trakt, "trakt", String(localized: "Trakt"),
            ["scrobble", "history", "watchlist", "connect", "sync"])
        add(.accountServices, trakt, "traktWindow", String(localized: "Continue Watching Window"),
            ["trakt", "days", "history"])
        add(.accountServices, trakt, "traktComments", String(localized: "Comments"),
            ["trakt", "reviews"])
        let simkl = String(localized: "Simkl")
        add(.accountServices, simkl, "simkl", String(localized: "Simkl"),
            ["scrobble", "history", "connect", "anime"])
        add(.accountServices, simkl, "animeId", String(localized: "Anime ID Preference"),
            ["simkl", "mal", "myanimelist", "kitsu", "imdb"])
        let details = String(localized: "Details & Continue Watching")
        add(.accountServices, details, "moreLikeThis", String(localized: "More Like This Source"),
            ["recommendations", "similar", "suggestions"])
        add(.accountServices, details, "unairedNextUp", String(localized: "Show Unaired Next Up"),
            ["next episode", "upcoming"])
        let debrid = String(localized: "Debrid")
        add(.accountServices, debrid, "debrid", String(localized: "Resolve Streams with Debrid"),
            ["real-debrid", "realdebrid", "alldebrid", "premiumize", "torbox", "torrent", "cached", "api key"])
        add(.accountServices, debrid, "debridResolver", String(localized: "Preferred resolver"),
            ["debrid", "provider"])

        // MARK: Playback
        let playback = String(localized: "Playback")
        add(.playback, playback, "skipIntro",
            String(localized: "settings.skipIntro.title", defaultValue: "Skip Intro",
                   comment: "Playback settings toggle that shows a Skip button during intros and outros"),
            ["outro", "recap", "credits", "skip button"])
        add(.playback, playback, "matchFrameRate", String(localized: "Match Content Frame Rate"),
            ["match content", "refresh rate", "hdr", "dynamic range", "24p", "display mode"])
        add(.playback, playback, "gpuNext", String(localized: "Enhanced Video Renderer"),
            ["gpu-next", "libplacebo", "tone mapping", "mpv", "renderer"])
        add(.playback, playback, "nativePlayer", String(localized: "Native player (Dolby Vision & HDR)"),
            ["avplayer", "dolby vision", "hdr10", "dv", "mkv", "engine"])
        add(.playback, playback, "trailerSound", String(localized: "Trailer Sound by Default"),
            ["mute", "audio", "trailers"])
        add(.playback, playback, "buffer", String(localized: "Streaming Buffer"),
            ["cache", "memory", "buffering", "stutter"])
        add(.playback, playback, "readahead", String(localized: "Network Readahead"),
            ["cache", "buffering", "seconds"])
        add(.playback, playback, "defaultPlayer", String(localized: "Default Player"),
            ["external player", "infuse", "vlc", "outplayer", "built-in"])
        let nextEpisode = String(localized: "Next Episode")
        add(.playback, nextEpisode, "autoplayNext", String(localized: "Autoplay Next Episode"),
            ["up next", "binge", "countdown", "continue"])
        add(.playback, nextEpisode, "upNextCredits", String(localized: "Start at the Credits When Known"),
            ["up next", "credits"])
        add(.playback, nextEpisode, "upNextThreshold", String(localized: "Before the End"),
            ["up next", "timing", "threshold"])
        add(.playback, nextEpisode, "upNextCountdown", String(localized: "Countdown"),
            ["up next", "seconds"])
        add(.playback, nextEpisode, "stillWatching", String(localized: "Ask \u{201C}Still Watching?\u{201D}"),
            ["are you still watching", "inactivity", "binge"])
        let nextStream = String(localized: "Next Episode Stream")
        add(.playback, nextStream, "streamSelection", String(localized: "Stream Selection"),
            ["autoplay", "first stream", "regex", "source"])
        add(.playback, nextStream, "sourceScope", String(localized: "Source Scope"),
            ["autoplay", "addons", "plugins"])
        add(.playback, nextStream, "regexPattern", String(localized: "Regex Pattern"),
            ["autoplay", "filter", "stream"])
        let subtitles = String(localized: "Subtitles")
        add(.playback, subtitles, "subtitleStyle", String(localized: "Subtitle Appearance"),
            ["size", "color", "colour", "text", "font", "background", "captions", "style"])
        add(.playback, subtitles, "subtitlePosition",
            String(localized: "settings.subtitles.position", defaultValue: "Subtitle Position",
                   comment: "Playback settings picker: how high subtitles sit on screen"),
            ["offset", "height", "captions"])
        add(.playback, subtitles, "subtitleBold", String(localized: "Bold"),
            ["subtitle", "font", "weight"])
        add(.playback, subtitles, "subtitleOutline", String(localized: "Outline"),
            ["subtitle", "readability"])
        add(.playback, subtitles, "subtitleSdh", String(localized: "Strip SDH Subtitles"),
            ["subtitle", "hearing impaired", "sound descriptions", "cc"])
        let languages = String(localized: "Audio & Subtitle Language")
        add(.playback, languages, "audioLanguage", String(localized: "Audio"),
            ["language", "preferred", "dub", "track"])
        add(.playback, languages, "secondaryAudio",
            String(localized: "settings.language.secondaryAudio", defaultValue: "Secondary Audio",
                   comment: "Playback settings picker: audio language used when the preferred one is missing"),
            ["language", "fallback", "track"])
        add(.playback, languages, "subtitleLanguage", String(localized: "Subtitles"),
            ["language", "preferred", "track", "captions"])
        add(.playback, languages, "secondarySubtitles",
            String(localized: "settings.language.secondarySubtitles", defaultValue: "Secondary Subtitles",
                   comment: "Playback settings picker: subtitle language used when the preferred one is missing"),
            ["language", "fallback", "track"])
        add(.playback, languages, "forcedOnly",
            String(localized: "settings.subtitles.forcedOnly", defaultValue: "Forced Subtitles Only",
                   comment: "Playback settings toggle: when the audio is in the subtitle language, show only forced subtitles"),
            ["foreign dialogue", "signs"])
        add(.playback, languages, "preferredOnly",
            String(localized: "settings.subtitles.preferredOnly", defaultValue: "Show Only Preferred Languages",
                   comment: "Playback settings toggle: hide add-on subtitles in other languages"),
            ["addon subtitles", "filter"])
        let recommendations = String(localized: "settings.streams.section", defaultValue: "Stream Recommendations",
                                     comment: "Playback settings section: how the source picker ranks streams")
        add(.playback, recommendations, "recommend",
            String(localized: "settings.streams.enabled", defaultValue: "Recommend Streams",
                   comment: "Playback settings toggle: rank streams and mark the recommended one"),
            ["rank", "sort", "best stream", "source picker"])
        add(.playback, recommendations, "preferredAudio",
            String(localized: "settings.streams.audio", defaultValue: "Preferred Audio",
                   comment: "Playback settings picker: the audio language/version streams are ranked for"),
            ["vff", "vfq", "dub", "french", "language"])
        add(.playback, recommendations, "alsoAcceptable",
            String(localized: "settings.streams.fallback", defaultValue: "Also Acceptable",
                   comment: "Playback settings picker: audio language accepted when the preferred one is missing"),
            ["fallback", "language"])
        add(.playback, recommendations, "vostfr",
            String(localized: "settings.streams.subtitled", defaultValue: "Original Version with Subtitles",
                   comment: "Playback settings toggle: accept original audio + subtitles (VOSTFR)"),
            ["vost", "vostfr", "original audio"])
        add(.playback, recommendations, "maxResolution",
            String(localized: "settings.streams.maxResolution", defaultValue: "Maximum Resolution",
                   comment: "Playback settings picker: streams above this resolution are not recommended"),
            ["4k", "1080p", "2160p", "quality"])
        add(.playback, recommendations, "hdrRanking",
            String(localized: "settings.streams.hdr", defaultValue: "HDR & Dolby Vision",
                   comment: "Playback settings picker: how HDR streams are ranked"),
            ["hdr10", "dv", "dolby"])
        add(.playback, recommendations, "maxSize",
            String(localized: "settings.streams.maxSize", defaultValue: "Maximum Size",
                   comment: "Playback settings picker: streams larger than this are not recommended"),
            ["gb", "file size", "bandwidth"])
        add(.playback, recommendations, "preferCached",
            String(localized: "settings.streams.cached", defaultValue: "Prefer Cached Streams",
                   comment: "Playback settings toggle: rank debrid-cached (instant) streams first"),
            ["debrid", "instant"])
        add(.playback, recommendations, "avoidCam",
            String(localized: "settings.streams.lowQuality", defaultValue: "Avoid CAM and TS",
                   comment: "Playback settings toggle: never recommend releases filmed in a cinema"),
            ["cam", "telesync", "cinema", "screener"])

        // MARK: Appearance
        let theme = String(localized: "Theme")
        add(.appearance, theme, "theme", String(localized: "Theme"),
            ["accent", "color", "colour", "crimson", "ocean", "violet", "emerald", "amber", "rose", "white",
             "gold", "jade", "rose gold", "arctic blue", "graphite", "dark"])
        add(.appearance, theme, "customColor", String(localized: "Custom Color"),
            ["accent", "hex", "hue", "own color", "custom theme", "picker"])
        add(.appearance, theme, "settingsStyle", String(localized: "Settings Style"),
            ["minimal", "sidebar", "icons"])
        add(.appearance, theme, "typeface", String(localized: "Typeface"),
            ["font", "open sans", "text"])
        let language = String(localized: "Language")
        add(.appearance, language, "appLanguage", String(localized: "App Language"),
            ["language", "locale", "translation", "francais", "deutsch", "espanol", "italiano", "device"])
        let poster = String(localized: "Poster Style")
        add(.appearance, poster, "posterSize", String(localized: "Size"),
            ["poster", "cards", "small", "large"])
        add(.appearance, poster, "posterCorners", String(localized: "Corners"),
            ["poster", "round", "square", "radius"])
        add(.appearance, poster, "hideTitles", String(localized: "Hide Titles"),
            ["poster", "labels"])
        add(.appearance, poster, "landscapeRows", String(localized: "Landscape Rows"),
            ["wide", "16:9", "cards", "home", "search"])
        add(.appearance, poster, "hideHeroArtwork", String(localized: "Hide Hero Artwork While Browsing"),
            ["hero", "backdrop", "focus"])
        add(.appearance, poster, "trailerAutoplay", String(localized: "Auto-Play Trailer on Detail"),
            ["trailer", "full screen", "autoplay"])
        add(.appearance, poster, "trailerBackground", String(localized: "Background Trailer on Detail"),
            ["trailer", "muted", "detail"])
        add(.appearance, poster, "trailerDuration", String(localized: "Trailer Duration"),
            ["trailer", "seconds", "loop"])
        add(.appearance, poster, "posterBackdrop", String(localized: "Poster in Detail Background"),
            ["detail", "artwork"])
        add(.appearance, poster, "iconOnlyButtons", String(localized: "Icon-Only Detail Buttons"),
            ["detail", "buttons", "labels"])
        let ratings = String(localized: "Ratings")
        add(.appearance, ratings, "overallRatings", String(localized: "Overall Ratings"),
            ["rating visibility", "imdb", "tmdb", "score", "mdblist", "hide ratings"])
        add(.appearance, ratings, "episodeRatings", String(localized: "Episode Ratings"),
            ["rating visibility", "score", "hide ratings", "spoiler"])
        let focus = String(localized: "settings.appearance.focusEffects.title", defaultValue: "Advanced Focus Effects",
                           comment: "Appearance settings section grouping the optional focus ring and no-zoom effects")
        add(.appearance, focus, "accentFocusRing", String(localized: "Accent Focus Ring"),
            ["focus", "highlight", "ring", "border"])
        add(.appearance, focus, "noZoom", String(localized: "No Zoom on Focus"),
            ["focus", "motion", "scale", "reduce motion"])
        add(.appearance, focus, "posterTitlesAlways",
            String(localized: "settings.appearance.posterTitlesAlwaysVisible", defaultValue: "Always Show Poster Titles",
                   comment: "Appearance toggle: show titles under every poster, not only the focused one"),
            ["poster", "labels", "captions"])
        add(.appearance, String(localized: "Card Depth"), "cardDepth", String(localized: "Card Depth"),
            ["edge", "sheen", "highlight", "gloss", "3d"])
        let badges = String(localized: "Stream Badges")
        add(.appearance, badges, "fileSizeBadges", String(localized: "File Size Badges"),
            ["stream", "gb", "chip"])
        add(.appearance, badges, "addonLogo", String(localized: "Show Add-on Logo"),
            ["stream", "addon", "icon"])
        add(.appearance, badges, "badgesAboveTitle", String(localized: "Badges Above Title"),
            ["stream", "chips", "layout"])
        add(.appearance, badges, "importBadgePack", String(localized: "Import Badge Pack"),
            ["stream badges", "pack", "custom badges"])

        // MARK: Home Screen
        let homeRows = String(localized: "Home Rows")
        add(.homeScreen, homeRows, "upcoming", String(localized: "Upcoming Episodes"),
            ["calendar", "next up", "new episodes"])
        add(.homeScreen, homeRows, "showHero", String(localized: "Show Hero"),
            ["featured", "banner", "top"])
        add(.homeScreen, homeRows, "nuvioHero", String(localized: "Nuvio-Style Hero"),
            ["hero", "layout"])
        add(.homeScreen, homeRows, "heroSources", String(localized: "Hero Sources"),
            ["hero", "catalogs", "featured"])
        add(.homeScreen, homeRows, "trailersOnFocus", String(localized: "Trailers on Focus"),
            ["hero", "preview", "autoplay"])
        add(.homeScreen, homeRows, "heroTrailer", String(localized: "Autoplay Hero Trailer"),
            ["hero", "trailer"])
        add(.homeScreen, homeRows, "catalogType", String(localized: "Show Catalog Type in Titles"),
            ["movie", "series", "row titles"])
        add(.homeScreen, homeRows, "catalogs", String(localized: "Catalogs"),
            ["rows", "order", "reorder", "hide", "show", "home rows"])
        add(.homeScreen, homeRows, "trailerLocation", String(localized: "Trailer Location"),
            ["hero", "poster", "trailer"])
        add(.homeScreen, homeRows, "refreshAddons", String(localized: "Refresh Add-ons"),
            ["catalogs", "reload", "update"])

        // MARK: Content Sources
        let tmdb = String(localized: "Metadata (TMDB)")
        add(.contentSources, tmdb, "tmdb", String(localized: "TMDB Enrichment"),
            ["metadata", "api key", "artwork", "cast", "themoviedb"])
        add(.contentSources, tmdb, "metadataLanguage", String(localized: "Metadata Language"),
            ["tmdb", "language", "titles", "descriptions"])
        add(.contentSources, tmdb, "enrichmentGroups", String(localized: "Enrichment Groups"),
            ["tmdb", "artwork", "cast", "episodes", "trailers", "collections"])
        let mdblist = String(localized: "Ratings (MDBList)")
        add(.contentSources, mdblist, "mdblist", String(localized: "MDBList Ratings"),
            ["rating", "imdb", "rotten tomatoes", "metacritic", "letterboxd", "api key", "scores"])
        add(.contentSources, mdblist, "ratingsProviders", String(localized: "Ratings Providers"),
            ["mdblist", "scores", "order", "rating visibility"])
        let library = String(localized: "Library & Watch Progress")
        add(.contentSources, library, "librarySource", String(localized: "Library Source"),
            ["trakt", "simkl", "nuvio", "watchlist"])
        add(.contentSources, library, "watchProgressSource", String(localized: "Watch Progress Source"),
            ["trakt", "simkl", "nuvio", "continue watching", "history"])
        let searchSources = String(localized: "Search Sources")
        add(.contentSources, searchSources, "searchSources", String(localized: "Search Sources"),
            ["catalogs", "search", "addons"])
        add(.contentSources, searchSources, "hideDiscover", String(localized: "Hide Discover"),
            ["search", "browse"])
        add(.contentSources, searchSources, "recentSearches", String(localized: "Recent Searches"),
            ["search", "history"])
        let plugins = String(localized: "Plugins")
        add(.contentSources, plugins, "plugins", String(localized: "Enable Plugins"),
            ["providers", "scrapers", "repository", "streams"])
        add(.contentSources, plugins, "refreshPlugins", String(localized: "Refresh Plugins"),
            ["providers", "repository", "update"])

        // MARK: Add-ons
        add(.addons, nil, "addons", String(localized: "Add-ons"),
            ["install", "manifest", "stremio", "catalogs", "streams", "url"])

        // MARK: Advanced
        add(.advanced, String(localized: "Startup"), "rememberProfile", String(localized: "Remember Last Profile"),
            ["profiles", "whos watching", "startup", "launch"])
        add(.advanced, String(localized: "Cache"), "clearCache", String(localized: "Clear Continue Watching Cache"),
            ["reset", "history", "stuck"])
        add(.advanced, String(localized: "Remote Setup"), "remoteSetup", String(localized: "Start Remote Setup"),
            ["browser", "phone", "web page", "configure", "keyboard", "type"])

        // MARK: About
        let about = String(localized: "About")
        add(.about, about, "version", String(localized: "Version"),
            ["build", "number", "developer mode"])
        add(.about, about, "licenses", String(localized: "Licenses & Attributions"),
            ["open source", "credits", "legal"])
        add(.about, about, "updates", String(localized: "Updates"),
            ["update available", "new version", "release"])
        add(.about, about, "sourceCode",
            String(localized: "settings.about.sourceCode", defaultValue: "Source Code",
                   comment: "About pane row title; the value is the public repository address"),
            ["github", "repository", "open source"])

        // MARK: Developer (hidden until unlocked)
        let developer = String(localized: "settings.developer.title", defaultValue: "Developer",
                               comment: "Settings category and section title for the hidden developer and diagnostics pane")
        add(.developer, developer, "developer", developer,
            ["diagnostics", "debug", "probe", "logs", "commit"], developerOnly: true)
        add(.developer, String(localized: "settings.developer.fallbacks.title", defaultValue: "Fallbacks",
                               comment: "Developer settings section with switches that bring back the previous app-drawn controls"),
            "fallbacks",
            String(localized: "settings.developer.searchLegacyField", defaultValue: "Plain Search Field",
                   comment: "Developer switch: replace the system search field with a plain text field"),
            ["legacy", "keyboard", "pin pad"], developerOnly: true)

        return list
    }
}
