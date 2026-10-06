package com.nuvio.app.core.i18n

// UI-free localization helpers. Each helper carries its English text inline as the fallback
// and resolves through the installed [StringProvider] (see StringProvider.kt). This file used
// to live in composeApp and call Compose Resources directly; it now lives in :shared so the
// migrated data layer can use it, with no Compose dependency. The phone app installs a
// Compose-Resources-backed provider so its bundled locales still apply; tvOS uses the English
// fallbacks below.

fun localizedMediaTypeLabel(type: String): String {
    val fallback = type.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
    return when (type.trim().lowercase()) {
        "movie" -> resourceString("Movies", StringKey.media_movies)
        "series" -> resourceString("Series", StringKey.media_series)
        "anime" -> resourceString("Anime", StringKey.media_anime)
        "channel" -> resourceString("Channels", StringKey.media_channels)
        "tv" -> resourceString("TV", StringKey.media_tv)
        else -> fallback
    }
}

fun localizedMovieTypeLabel(): String = resourceString("Movie", StringKey.media_movie)

fun localizedSeasonEpisodeCode(seasonNumber: Int?, episodeNumber: Int?): String? =
    when {
        seasonNumber != null && episodeNumber != null ->
            resourceString(
                "S${seasonNumber}E${episodeNumber}",
                StringKey.compose_player_episode_code_full,
                seasonNumber,
                episodeNumber,
            )
        episodeNumber != null ->
            resourceString(
                "E${episodeNumber}",
                StringKey.compose_player_episode_code_episode_only,
                episodeNumber,
            )
        else -> null
    }

fun localizedPlayLabel(seasonNumber: Int?, episodeNumber: Int?): String {
    val episodeCode = localizedSeasonEpisodeCode(seasonNumber, episodeNumber)
    return if (episodeCode != null) {
        resourceString("Play $episodeCode", StringKey.action_play_episode, episodeCode)
    } else {
        resourceString("Play", StringKey.action_play)
    }
}

fun localizedResumeLabel(seasonNumber: Int?, episodeNumber: Int?): String {
    val episodeCode = localizedSeasonEpisodeCode(seasonNumber, episodeNumber)
    return if (episodeCode != null) {
        resourceString("Resume $episodeCode", StringKey.action_resume_episode, episodeCode)
    } else {
        resourceString("Resume", StringKey.action_resume)
    }
}

fun localizedUpNextLabel(seasonNumber: Int?, episodeNumber: Int?): String =
    if (seasonNumber != null && episodeNumber != null) {
        resourceString(
            "Next Up • S${seasonNumber}E${episodeNumber}",
            StringKey.continue_watching_up_next_episode,
            seasonNumber,
            episodeNumber,
        )
    } else {
        resourceString("Next Up", StringKey.continue_watching_up_next)
    }

fun localizedMonthName(month: Int): String =
    when (month) {
        1 -> resourceString("January", StringKey.date_month_january)
        2 -> resourceString("February", StringKey.date_month_february)
        3 -> resourceString("March", StringKey.date_month_march)
        4 -> resourceString("April", StringKey.date_month_april)
        5 -> resourceString("May", StringKey.date_month_may)
        6 -> resourceString("June", StringKey.date_month_june)
        7 -> resourceString("July", StringKey.date_month_july)
        8 -> resourceString("August", StringKey.date_month_august)
        9 -> resourceString("September", StringKey.date_month_september)
        10 -> resourceString("October", StringKey.date_month_october)
        11 -> resourceString("November", StringKey.date_month_november)
        12 -> resourceString("December", StringKey.date_month_december)
        else -> month.toString()
    }

fun localizedShortMonthName(month: Int): String =
    when (month) {
        1 -> resourceString("Jan", StringKey.date_month_short_jan)
        2 -> resourceString("Feb", StringKey.date_month_short_feb)
        3 -> resourceString("Mar", StringKey.date_month_short_mar)
        4 -> resourceString("Apr", StringKey.date_month_short_apr)
        5 -> resourceString("May", StringKey.date_month_short_may)
        6 -> resourceString("Jun", StringKey.date_month_short_jun)
        7 -> resourceString("Jul", StringKey.date_month_short_jul)
        8 -> resourceString("Aug", StringKey.date_month_short_aug)
        9 -> resourceString("Sep", StringKey.date_month_short_sep)
        10 -> resourceString("Oct", StringKey.date_month_short_oct)
        11 -> resourceString("Nov", StringKey.date_month_short_nov)
        12 -> resourceString("Dec", StringKey.date_month_short_dec)
        else -> month.toString()
    }

fun localizedNoSubtitleLinesFound(): String =
    resourceString("No subtitle lines found", StringKey.compose_player_no_subtitle_lines_found)

fun localizedSubtitleLinesLoadError(): String =
    resourceString("Unable to load subtitle lines", StringKey.compose_player_subtitle_lines_load_error)

fun localizedBadgeImportFailed(): String =
    resourceString("Badge import failed.", StringKey.settings_stream_badge_import_failed)

fun localizedBadgeEnterUrl(): String =
    resourceString("Enter a badge JSON URL.", StringKey.settings_stream_badge_enter_url)

fun localizedBadgeUrlSchemeInvalid(): String =
    resourceString(
        "Badge URL must start with http:// or https://.",
        StringKey.settings_stream_badge_url_scheme_invalid,
    )

fun localizedBadgeImportLimit(limit: Int): String =
    resourceString(
        "You can import up to $limit badge URLs.",
        StringKey.settings_stream_badge_import_limit,
        limit,
    )

fun localizedP2pUnknownTorrentError(): String =
    resourceString("Unknown torrent error", StringKey.p2p_error_unknown)

fun localizedByteUnit(unit: String): String =
    when (unit) {
        "GB" -> resourceString("GB", StringKey.unit_bytes_gb)
        "MB" -> resourceString("MB", StringKey.unit_bytes_mb)
        "KB" -> resourceString("KB", StringKey.unit_bytes_kb)
        else -> resourceString("B", StringKey.unit_bytes_b)
    }
