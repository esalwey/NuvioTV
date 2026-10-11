package com.nuvio.app.features.plugins

/** One stream a tested provider returned, reduced to what a person reads in the report. */
data class PluginTestStream(
    val title: String,
    /** "1080p · 2.1 GB · torrent", whichever of those the provider gave; empty when none. */
    val detail: String,
)

/**
 * What a provider did when run on a fixed sample (Settings → Content Sources → a provider's Test
 * action): the sample, how long it took, how many streams came back, the first few, and the steps in
 * order. Parity: Android TV `PluginManager.testScraper` / `TestDiagnostics`.
 */
data class PluginTestReport(
    val scraperName: String,
    /** "Movie · TMDB 603" or "Series · TMDB 603 · S1E1". */
    val sample: String,
    val elapsedMs: Long,
    val streamCount: Int,
    /** The first [PLUGIN_TEST_PREVIEW_COUNT] streams. */
    val streams: List<PluginTestStream>,
    val steps: List<String>,
    /** Why the run failed (an exception, the 60 s limit); null when the provider answered. */
    val error: String?,
) {
    val succeeded: Boolean get() = error == null
}

const val PLUGIN_TEST_PREVIEW_COUNT = 5

/** The sample every provider is tested on: The Matrix (movie) or, for series-only providers, S1E1. */
const val PLUGIN_TEST_TMDB_ID = "603"

fun buildPluginTestReport(
    scraperName: String,
    mediaType: String,
    season: Int?,
    episode: Int?,
    elapsedMs: Long,
    outcome: Result<List<PluginRuntimeResult>>,
): PluginTestReport {
    val isMovie = normalizePluginType(mediaType) == "movie"
    val sample = buildString {
        append(if (isMovie) "Movie" else "Series")
        append(" \u00B7 TMDB ").append(PLUGIN_TEST_TMDB_ID)
        if (!isMovie && season != null && episode != null) append(" \u00B7 S").append(season).append('E').append(episode)
    }
    val steps = mutableListOf("Provider: $scraperName", "Sample: $sample")
    val results = outcome.getOrNull()
    if (results == null) {
        val reason = outcome.exceptionOrNull()?.let { error ->
            val message = error.message?.trim().orEmpty()
            if (message.isEmpty()) error::class.simpleName.orEmpty().ifEmpty { "Unknown error" } else message
        } ?: "Unknown error"
        steps += "Failed after ${formatElapsed(elapsedMs)}: $reason"
        return PluginTestReport(scraperName, sample, elapsedMs, 0, emptyList(), steps, reason)
    }
    steps += when (results.size) {
        0 -> "Answered in ${formatElapsed(elapsedMs)} with no streams"
        1 -> "Answered in ${formatElapsed(elapsedMs)} with 1 stream"
        else -> "Answered in ${formatElapsed(elapsedMs)} with ${results.size} streams"
    }
    val streams = results.take(PLUGIN_TEST_PREVIEW_COUNT).map { result ->
        PluginTestStream(
            title = (result.title.ifBlank { result.name.orEmpty() }).ifBlank { "Untitled" },
            detail = listOfNotNull(
                result.quality?.takeIf { it.isNotBlank() },
                result.size?.takeIf { it.isNotBlank() },
                result.type?.takeIf { it.isNotBlank() },
            ).joinToString(" \u00B7 "),
        )
    }
    return PluginTestReport(scraperName, sample, elapsedMs, results.size, streams, steps, null)
}

internal fun formatElapsed(elapsedMs: Long): String {
    val ms = elapsedMs.coerceAtLeast(0)
    if (ms < 1_000) return "$ms ms"
    val tenths = (ms + 50) / 100
    return "${tenths / 10}.${tenths % 10} s"
}
