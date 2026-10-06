package com.nuvio.app.features.watchprogress

import kotlin.math.abs

/*
 * CW legacy diagnosis (REMAINING_FIX #1): the Continue Watching report of Settings > About.
 *
 * The reporter runs the app from Windows, with no Mac console, so what the row was built from has
 * to be readable in a photo of the TV. One snapshot, top to bottom:
 * - the header lines: the profile ids, the active source and the delta state, then the local and
 *   dirty counts, the writes that went to another profile than the loaded one (`xprof`), the
 *   learned series ids (`map`), the warm-up's lookups (`wu`) and the undated server rows (`fut`);
 * - one `card` line per in-progress card of the row, most recent first:
 *   `card <id> [id=tt…] [markers] S1E5 d=-12m <source> "<title>"` — the markers right after the
 *   id and the title last, cut to [ContinueWatchingDiagnosticsMaxTitleLength], so a narrow screen
 *   never cuts a marker;
 * - one `seed` line per series an Up Next card is resolved from, ending with what its last
 *   resolution gave (`up=S1E6` for a card, `up=none`, `up=fail`, `up=?` if never resolved yet);
 * - the rows behind every card, and behind every other series with an in-progress row: at most
 *   [ContinueWatchingDiagnosticsMaxRowsPerSeries] per series, newest first.
 *
 * Markers:
 * - `FUTURE`: dated more than a minute ahead of this Apple TV's clock. Such a row outranks every
 *   real one of its series. A server row more than 10 minutes ahead is undated on arrival
 *   (REMAINING_FIX #3): it then shows `d=t0`, sorts last within its series, and the header's
 *   `fut=` counts those rows.
 * - `ALIAS?`: another card, or another series of the list, has the same title under another id
 *   the row does not group with this one. The same show is then stored twice (`tmdb:…` and
 *   `tt…`) and makes two cards.
 * - `id=tt…`: the IMDb id the row groups this series under (REMAINING_FIX #2), when it is not the
 *   stored id. `MERGED`: another stored id of the series is grouped into this card; its rows
 *   follow the card's.
 */

/** A row dated more than this ahead of the clock is flagged `FUTURE`. */
internal const val ContinueWatchingDiagnosticsFutureToleranceSeconds = 60L
internal const val ContinueWatchingDiagnosticsMaxRowsPerSeries = 6
internal const val ContinueWatchingDiagnosticsMaxLines = 120
internal const val ContinueWatchingDiagnosticsMaxTitleLength = 20

/**
 * The report's lines. [entries] are what the row is built from (the active source's entries),
 * [dirtyKeys] the local keys not yet acknowledged by the server, [rowEntries] the in-progress cards
 * as Home shows them and [nextUpSeeds] the series of its Up Next cards, with the last resolution
 * of each by dismiss key ([nextUpOutcomes], `ContinueWatchingNextUp.resolutionOutcomes`).
 * [canonicalSeriesId] is the row's series grouping ([ContinueWatchingSeriesIdentity]). Pure:
 * [nowEpochMs] is the clock every age is measured against.
 */
internal fun buildContinueWatchingDiagnosticLines(
    header: List<String>,
    entries: Collection<WatchProgressEntry>,
    dirtyKeys: Set<String>,
    rowEntries: List<WatchProgressEntry>,
    nowEpochMs: Long,
    nextUpSeeds: List<ContinueWatchingNextUpSeed> = emptyList(),
    nextUpOutcomes: Map<String, String> = emptyMap(),
    canonicalSeriesId: (String) -> String = { id -> id.trim() },
    maxRowsPerSeries: Int = ContinueWatchingDiagnosticsMaxRowsPerSeries,
    maxLines: Int = ContinueWatchingDiagnosticsMaxLines,
): List<String> {
    val lines = header.toMutableList()
    val groups: Map<String, List<WatchProgressEntry>> = entries.groupBy { entry -> entry.parentMetaId.trim() }
    val titlesByGroup: Map<String, Set<String>> = groups.mapValues { (_, rows) ->
        rows.mapNotNullTo(linkedSetOf()) { row -> row.continueWatchingTitleKey() }
    }
    val seriesGroupIds: Set<String> = groups
        .filterValues { rows -> rows.any(WatchProgressEntry::isContinueWatchingSeries) }
        .keys
    val cardIds = rowEntries.mapTo(linkedSetOf()) { card -> card.parentMetaId.trim() }

    // The other stored ids of [card]'s series, grouped into its card: MERGED.
    fun mergedIds(card: WatchProgressEntry): List<String> {
        if (!card.isContinueWatchingSeries()) return emptyList()
        val id = card.parentMetaId.trim()
        val canonical = canonicalSeriesId(id)
        return seriesGroupIds.filter { groupId -> groupId != id && canonicalSeriesId(groupId) == canonical }
    }

    // The other ids stored under the same title as [card] and not grouped with it: ALIAS? suspects.
    fun sameTitleOtherIds(card: WatchProgressEntry): List<String> {
        val id = card.parentMetaId.trim()
        val title = card.continueWatchingTitleKey() ?: return emptyList()
        val merged = mergedIds(card).toSet()
        val fromCards = rowEntries
            .filter { other -> other.parentMetaId.trim() != id && other.continueWatchingTitleKey() == title }
            .map { other -> other.parentMetaId.trim() }
        val fromGroups = titlesByGroup
            .filter { (groupId, titles) -> groupId != id && title in titles }
            .keys
        return (fromCards + fromGroups).distinct().filterNot { other -> other in merged }
    }

    fun StringBuilder.appendSeriesId(id: String, isSeries: Boolean) {
        append(id)
        val canonical = if (isSeries) canonicalSeriesId(id) else id
        if (canonical != id) append(" id=").append(canonical)
    }

    if (rowEntries.isEmpty()) lines += "no in-progress card"
    rowEntries.forEach { card ->
        lines += buildString {
            append("card ").appendSeriesId(card.parentMetaId.trim(), card.isContinueWatchingSeries())
            if (card.isDiagnosticFuture(nowEpochMs)) append(" FUTURE")
            if (sameTitleOtherIds(card).isNotEmpty()) append(" ALIAS?")
            if (mergedIds(card).isNotEmpty()) append(" MERGED")
            append(' ').append(card.diagnosticEpisodeLabel())
            append(" d=").append(diagnosticAge(card.lastUpdatedEpochMs, nowEpochMs))
            append(' ').append(card.source)
            append(" \"").append(card.title.trim().diagnosticTitle()).append('"')
        }
    }

    nextUpSeeds.forEach { seed ->
        lines += buildString {
            append("seed ").appendSeriesId(seed.contentId.trim(), isSeries = true)
            if (isDiagnosticFuture(seed.markedAtEpochMs, nowEpochMs)) append(" FUTURE")
            append(" S").append(seed.seasonNumber).append('E').append(seed.episodeNumber)
            append(" d=").append(diagnosticAge(seed.markedAtEpochMs, nowEpochMs))
            append(" up=").append(nextUpOutcomes[seed.dismissKey] ?: "?")
        }
    }

    // The series behind every card first (the card's own, the ids merged into it, then its
    // suspects), then every other series with an in-progress row, most recent first.
    val printedGroups = linkedSetOf<String>()
    rowEntries.forEach { card ->
        printedGroups += card.parentMetaId.trim()
        printedGroups += mergedIds(card)
        printedGroups += sameTitleOtherIds(card)
    }
    groups
        .filter { (groupId, rows) ->
            groupId !in printedGroups && rows.any(WatchProgressEntry::shouldTreatAsInProgressForContinueWatching)
        }
        .entries
        .sortedByDescending { (_, rows) -> rows.maxOf(WatchProgressEntry::lastUpdatedEpochMs) }
        .forEach { (groupId, _) -> printedGroups += groupId }

    printedGroups.forEach { groupId ->
        val rows = groups[groupId].orEmpty().sortedWith(watchProgressEntryFreshnessComparator.reversed())
        if (rows.isEmpty()) {
            if (groupId in cardIds) lines += "row $groupId (no stored row)"
            return@forEach
        }
        rows.take(maxRowsPerSeries.coerceAtLeast(0)).forEach { row ->
            lines += row.diagnosticRowLine(groupId = groupId, dirtyKeys = dirtyKeys, nowEpochMs = nowEpochMs)
        }
        val hidden = rows.size - maxRowsPerSeries.coerceAtLeast(0)
        if (hidden > 0) lines += "row $groupId +$hidden older"
    }

    if (maxLines <= 0 || lines.size <= maxLines) return lines
    val kept = (maxLines - 1).coerceAtLeast(0)
    return lines.take(kept) + "… ${lines.size - kept} more lines not shown"
}

private fun WatchProgressEntry.diagnosticRowLine(
    groupId: String,
    dirtyKeys: Set<String>,
    nowEpochMs: Long,
): String {
    val key = resolvedProgressKey()
    val syntheticKey = buildWatchProgressKey(
        contentId = parentMetaId,
        seasonNumber = seasonNumber,
        episodeNumber = episodeNumber,
    )
    val syntheticVideoId = buildPlaybackVideoId(
        parentMetaId = parentMetaId,
        seasonNumber = seasonNumber,
        episodeNumber = episodeNumber,
    )
    return buildString {
        append("row ").append(groupId)
        // "syn": the synthetic form built from the id and the episode, the normal case.
        append(" k=").append(if (key == syntheticKey) "syn" else key)
        append(" v=").append(if (videoId == syntheticVideoId) "syn" else videoId)
        append(' ').append(diagnosticEpisodeLabel())
        append(" d=").append(diagnosticAge(lastUpdatedEpochMs, nowEpochMs))
        append(" done=").append(if (isEffectivelyCompleted) 1 else 0)
        append(" dirty=").append(if (key in dirtyKeys) 1 else 0)
        append(' ').append(lastPositionMs / 1000L).append('/').append(durationMs / 1000L).append('s')
        if (isDiagnosticFuture(nowEpochMs)) append(" FUTURE")
    }
}

/** A card's title as its line shows it: at most [ContinueWatchingDiagnosticsMaxTitleLength] characters. */
private fun String.diagnosticTitle(): String =
    if (length <= ContinueWatchingDiagnosticsMaxTitleLength) {
        this
    } else {
        take(ContinueWatchingDiagnosticsMaxTitleLength - 1).trimEnd() + "…"
    }

private fun WatchProgressEntry.diagnosticEpisodeLabel(): String =
    if (seasonNumber != null && episodeNumber != null) "S${seasonNumber}E$episodeNumber" else "-"

private fun WatchProgressEntry.isDiagnosticFuture(nowEpochMs: Long): Boolean =
    isDiagnosticFuture(lastUpdatedEpochMs, nowEpochMs)

private fun isDiagnosticFuture(epochMs: Long, nowEpochMs: Long): Boolean =
    epochMs > 0L && (epochMs - nowEpochMs) / 1000L > ContinueWatchingDiagnosticsFutureToleranceSeconds

/**
 * How far [epochMs] is from [nowEpochMs], signed (`+` ahead of the clock) in the largest unit that
 * reads at a glance: `-40s`, `-12m`, `-5h`, `-30d`, `+2h`. `t0` for a row with no date.
 */
internal fun diagnosticAge(epochMs: Long, nowEpochMs: Long): String {
    if (epochMs <= 0L) return "t0"
    val seconds = (epochMs - nowEpochMs) / 1000L
    val sign = when {
        seconds > 0L -> "+"
        seconds < 0L -> "-"
        else -> ""
    }
    val magnitude = abs(seconds)
    val body = when {
        magnitude < 120L -> "${magnitude}s"
        magnitude < 120L * 60L -> "${magnitude / 60L}m"
        magnitude < 48L * 3600L -> "${magnitude / 3600L}h"
        else -> "${magnitude / 86_400L}d"
    }
    return sign + body
}
