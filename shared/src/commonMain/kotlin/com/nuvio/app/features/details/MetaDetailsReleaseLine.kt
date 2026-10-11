package com.nuvio.app.features.details

import com.nuvio.app.core.format.extractReleaseYearForDisplay

private fun isTvSeriesType(type: String): Boolean =
    when (type.trim().lowercase()) {
        "series", "tv", "show", "tvshow" -> true
        else -> false
    }

private fun isEndedSeriesStatus(status: String?): Boolean {
    if (status.isNullOrBlank()) return false
    val s = status.trim().lowercase()
    if ("returning" in s || "in production" in s) return false
    return "ended" in s || "canceled" in s || "cancelled" in s
}

/**
 * Compact release line under the details hero: movies → year only; TV → "2025 -" or "2021 - 2028".
 */
fun formatMetaReleaseLineForDetails(meta: MetaDetails): String? {
    val raw = meta.releaseInfo?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    if (!isTvSeriesType(meta.type)) {
        return extractReleaseYearForDisplay(raw)?.toString()
    }
    val startYear = extractReleaseYearForDisplay(raw) ?: return raw
    val endYear = meta.lastAirDate?.let { extractReleaseYearForDisplay(it) }
    return when {
        isEndedSeriesStatus(meta.status) && endYear != null ->
            if (endYear == startYear) startYear.toString()
            else "$startYear - $endYear"
        isEndedSeriesStatus(meta.status) -> startYear.toString()
        else -> "$startYear -"
    }
}

private val isoDatePrefix = Regex("""^(\d{4})-(\d{2})-(\d{2})""")

/**
 * The calendar date at the start of an addon's `released` (e.g. `2010-07-16T00:00:00.000Z`) or a
 * TMDB `release_date`, as `yyyy-MM-dd`; null when the value carries no full date (a bare year,
 * a year range, blank). The time and offset are dropped on purpose: a release is a calendar day,
 * not an instant, so it must not shift with the viewer's time zone.
 */
fun normalizeIsoReleaseDate(raw: String?): String? {
    val match = isoDatePrefix.find(raw?.trim().orEmpty()) ?: return null
    val (year, month, day) = match.destructured
    if (year.toInt() < 1000) return null
    if (month.toInt() !in 1..12 || day.toInt() !in 1..31) return null
    return "$year-$month-$day"
}
