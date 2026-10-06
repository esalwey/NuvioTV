import Foundation
import SharedCore

// Engine-agnostic playback models shared by every player engine (libmpv today; the native
// AVPlayer path added in later phases). Extracted from MPVPlayerView.swift in Phase 0 of the
// hybrid-player work so both engines — and the router/prober — depend on one set of types.
// See docs/tvos-hybrid-player-plan.md.

/// UserDefaults keys for device-local player tuning (Settings > Playback). Device-specific
/// hardware knobs, deliberately NOT synced.
enum PlayerTuning {
    static let bufferMBKey = "player.bufferMB"
    static let readaheadSecKey = "player.readaheadSec"
    static let matchFrameRateKey = "player.matchFrameRate"
    /// Opt into mpv's `gpu-next` (libplacebo) video output for better HDR tone-mapping. Device-only
    /// (never applied on the simulator, where libplacebo's vo asserts). Applies to the next playback.
    static let enhancedRendererKey = "player.enhancedRenderer"
    /// Route Dolby Vision / native-friendly files to the AVPlayer engine for true DV output.
    /// ON by default since beta.13 (registered in NuvioTVApp.init; docs/tvos-native-player-info-panel-plan.md);
    /// gates all engine routing.
    static let nativeDVKey = "player.nativeDolbyVision"
    /// Sub-setting of the native-DV beta: keep DV Profile 7 FEL files on mpv instead of converting
    /// them to 8.1 (the conversion discards FEL enhancement data; MEL converts losslessly and is
    /// unaffected by this preference).
    static let dvP7FelMpvKey = "player.dvP7FelPreferMpv"
    /// Up Next (Settings → Playback → Next Episode) — device-local on purpose, see
    /// `UpNextPreferences` for the sync policy. Absent keys read as the tvOS defaults.
    /// Automatic next episode (default ON).
    static let upNextAutoplayKey = "player.upNext.autoplay"
    /// Show the card when the credits start, when their timing is known (default ON).
    static let upNextUseCreditsKey = "player.upNext.useCredits"
    /// Countdown length in seconds (5/10/15, default 5).
    static let upNextCountdownKey = "player.upNext.countdownSec"
    /// "Before the End" lead in seconds (15/30/45/60). Absent = the profile's synced threshold, else 30.
    static let upNextSecondsBeforeEndKey = "player.upNext.secondsBeforeEnd"
    /// "Still watching?" gate after unattended episodes (default ON).
    static let upNextStillWatchingKey = "player.upNext.askStillWatching"
    /// PLY-A12: how long the engine router waits on the stream probe before it gives up and plays
    /// on mpv. Back to 4 s (build 138 feedback, "video loading is buggy"): 2.5 s did not cover a
    /// debrid redirect plus TLS plus the Matroska header on a cold link, so Dolby Vision files fell
    /// back to mpv (no true DV) for no reason. The loading view's spinner shows from 2 s either way.
    static let probeTimeoutSec: Double = 4
}

/// Everything the player needs to render a stream and record watch progress for it.
struct PlaybackContext: Identifiable {
    let url: URL
    let title: String
    let contentType: String      // "movie" / "series"
    let parentMetaId: String
    let videoId: String
    let season: Int?
    let episode: Int?
    let poster: String?
    let background: String?
    let providerName: String?
    let providerAddonId: String?
    let streamTitle: String?
    let streamSubtitle: String?
    let externalSubtitles: [SubtitleFile]
    /// Binge group of the playing stream (steers next-episode auto-select toward the same release).
    var bingeGroup: String? = nil
    /// All episodes of the parent series (empty for movies) — enables next-episode autoplay.
    var episodes: [MetaVideo] = []
    /// Title/episode synopsis for the native player's Info tab header (nil when the launch path
    /// has no meta at hand — the header simply omits it).
    var synopsis: String? = nil
    /// 16:9 episode still for the native player's Info tab header. Kept apart from `poster`,
    /// which stays the catalog/series poster (the progress recorder persists `poster` as the
    /// parent artwork — a still must never leak into it). nil → the header shows `poster`.
    var episodeStill: String? = nil
    /// Catalog metadata for the player's Info tab chip row (year · runtime · rating · genres). nil
    /// when the launch path has no meta at hand — the chips simply omit them.
    var meta: PlaybackMeta? = nil
    /// Declared file size of the playing stream (addon `behaviorHints.videoSize`), for the Info chips.
    var fileSizeBytes: Int64? = nil
    /// Sanitized HTTP request headers the addon declared for this stream
    /// (`behaviorHints.proxyHeaders.request` via shared `sanitizePlaybackHeaders` — Referer /
    /// User-Agent a scraper CDN requires; GitHub issue #2 "Some video no stream"). Empty for the
    /// overwhelming majority of streams. Consumed by BOTH engines: mpv (`http-header-fields`)
    /// and the native path's FFmpeg source opens (MediaProbe + RemuxSession `headers` option).
    var requestHeaders: [String: String] = [:]
    /// Where to start instead of the saved progress — an in-player source switch picks up where the
    /// previous source was (upstream c69b643a6, "resume restored player from current position"):
    /// the saved position is up to a tick stale, and an entry already counted as completed near the
    /// end would restart the episode from 0. nil = the saved progress decides.
    var startPositionSec: Double? = nil
    /// PLY-A13 Start Over: play from 0:00 and ignore the saved progress. The saved entry is not
    /// cleared up front: playback's own progress ticks replace it. `startPositionSec` (an engine
    /// hand-over, a source switch) still wins.
    var resumeFromStart: Bool = false
    /// CW-1: the parent title the watch-progress record (and the Trakt scrobble) is filed under —
    /// the SERIES name for an episode, while `title` is the "S1E3 · Pilot" label the picker and the
    /// player header show. nil = `title` (movies, launch paths without the series name).
    var seriesTitle: String? = nil
    /// CW-1: the episode's own name, recorded as the progress entry's `episodeTitle`.
    var episodeTitle: String? = nil
    /// CW-1: the title's logo, recorded with the progress entry (Continue Watching hero).
    var logo: String? = nil

    /// PLY-A13: this context, played from the beginning (the Start Over action of the Detail page
    /// and of Continue Watching).
    func startingOver() -> PlaybackContext {
        var copy = self
        copy.resumeFromStart = true
        copy.startPositionSec = nil
        return copy
    }

    /// The title watch progress and Trakt are told about (see `seriesTitle`).
    var progressTitle: String {
        guard let seriesTitle, !seriesTitle.isEmpty else { return title }
        return seriesTitle
    }

    // Headers join the identity (Codex 2026-08-20 round 3): two sources for the same episode can
    // share a URL but require different headers; StreamPickerView rebuilds the player and
    // PlayerScreen re-keys its probe on this id, so header changes must re-key too or a stale
    // controller keeps the old headers and an auth-gated stream 403s. The joins use ASCII unit /
    // record separators, which `sanitizePlaybackHeaders` guarantees can never appear in a key or
    // value (it rejects all control characters), so the fingerprint is unambiguous — a plain
    // "&"/"=" join could collide on values containing those characters (Codex round 4).
    var id: String {
        let headerFingerprint = requestHeaders.isEmpty
            ? ""
            : "|" + requestHeaders
                .sorted { $0.key < $1.key }
                .map { "\($0.key)\u{1F}\($0.value)" }
                .joined(separator: "\u{1E}")
        return "\(videoId)|\(url.absoluteString)\(headerFingerprint)"
    }
}

/// CW-1: titles for the launch paths that start from a watch-progress record (Continue Watching,
/// the Top Shelf) instead of from the title's metadata.
enum ProgressRecordTitles {
    /// Builds before CW-1 recorded an episode's picker label ("S1E3 · Pilot") as the SERIES title of
    /// its progress entry. True when `title` is such a label for this episode. The label comes from
    /// the "S%lldE%lld · %@" key, which Spanish renders with a "T".
    static func isEpisodeLabel(_ title: String, season: Int?, episode: Int?) -> Bool {
        guard let season, let episode else { return false }
        for letter in ["S", "T"] {
            let code = "\(letter)\(season)E\(episode)"
            if title == code || title.hasPrefix(code + " \u{00B7} ") { return true }
        }
        return false
    }

    /// The recorded title when it names the series; nil when it is empty or a legacy episode label.
    static func seriesTitle(_ title: String, season: Int?, episode: Int?) -> String? {
        if title.isEmpty || isEpisodeLabel(title, season: season, episode: episode) { return nil }
        return title
    }

    /// The series name from the metadata cache, for a launch whose record held only a legacy label
    /// and whose own fetch has not landed (a stream picked at once, the next episode it chains to).
    /// nil when the title is not cached — the label is then kept, and repaired on a later resume.
    static func cachedSeriesName(type: String, id: String) -> String? {
        let name: String? = MetaDetailsRepository.shared.peek(type: type, id: id)?.name
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// The stream picker header: "S1E3 · Pilot" for an episode (the series name stands in for a
    /// missing episode name), the title itself for anything else.
    static func pickerTitle(title: String, season: Int?, episode: Int?, episodeTitle: String?) -> String {
        guard let season, let episode else { return title }
        if isEpisodeLabel(title, season: season, episode: episode) { return title }
        let name: String
        if let episodeTitle, !episodeTitle.isEmpty {
            name = episodeTitle
        } else {
            name = title
        }
        return String(localized: "S\(season)E\(episode) \u{00B7} \(name)")
    }
}

/// Title-level catalog facts shown as chips in the player's Info tab.
struct PlaybackMeta: Equatable {
    var year: String? = nil
    var runtime: String? = nil
    var imdbRating: String? = nil
    var ageRating: String? = nil
    var genres: [String] = []
    /// The title's original language (ISO 639-1) for the "Original" audio preference, resolved the
    /// same way upstream's `resolveLaunchContentLanguage` does (TMDB `original_language`, with the
    /// production country as a tie-break for pt/es/zh variants). nil when the launch path has no
    /// catalog record — the players then fall back to `MetaDetailsRepository.peek`.
    var originalLanguage: String? = nil

    /// From a full catalog record (Detail / episode shelf launch paths).
    init(details: MetaDetails) {
        func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }
        year = nonEmpty(details.releaseInfo)
        runtime = nonEmpty(details.runtime)
        imdbRating = nonEmpty(details.imdbRating)
        ageRating = nonEmpty(details.ageRating)
        genres = details.genres
        originalLanguage = PlayerLanguagePreferencesKt.resolveContentLanguage(
            language: details.language, country: details.country
        )
    }

    init(year: String? = nil, runtime: String? = nil, imdbRating: String? = nil,
         ageRating: String? = nil, genres: [String] = [], originalLanguage: String? = nil) {
        self.year = year; self.runtime = runtime; self.imdbRating = imdbRating
        self.ageRating = ageRating; self.genres = genres; self.originalLanguage = originalLanguage
    }
}

/// An external subtitle file to side-load into the player.
struct SubtitleFile {
    let url: String
    let language: String
    let name: String?
}

/// One selectable audio or subtitle track.
struct PlayerTrack: Identifiable, Equatable {
    let id: Int          // mpv track id; -1 means "off" (subtitles)
    let label: String
    let isSelected: Bool
}

/// A skippable segment (intro/recap/outro) resolved from `SkipIntroRepository`.
struct SkipSegment {
    let start: Double
    let end: Double
    let type: String
}

/// The currently-offered skip action (shown while playback is inside a `SkipSegment`).
struct SkipPrompt: Equatable {
    let label: String      // e.g. "Skip Intro"
    let targetSec: Double   // absolute seek target (segment end)
    /// The segment is the credits (outro/ED): skipping them can mean "next episode" (Up Next).
    var isCredits: Bool = false
}

/// Live stream diagnostics read from libmpv properties (shown by the Stream Info overlay).
struct StreamInfoSnapshot: Equatable {
    /// Router decision label ("Native · DV P8.1" / "mpv · audio truehd"). Diagnostic only in Phase 1.
    var engine = ""
    var videoCodec = ""
    var resolution = ""
    var fps = ""
    var hwdec = ""
    var videoBitrate = ""
    var audio = ""
    var cache = ""

    var rows: [(String, String)] {
        [(String(localized: "Engine"), engine), (String(localized: "Video"), videoCodec),
         (String(localized: "Resolution"), resolution), (String(localized: "Frame rate"), fps),
         (String(localized: "Hardware decode"), hwdec), (String(localized: "Video bitrate"), videoBitrate),
         (String(localized: "Audio"), audio), (String(localized: "Cache"), cache)].filter { !$0.1.isEmpty }
    }
}
