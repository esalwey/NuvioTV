package com.nuvio.app.features.details

fun selectHeroTrailer(trailers: List<MetaTrailer>): MetaTrailer? =
    selectHeroTrailer(trailers, preferredLanguage = null)

/**
 * BUG-63/BUG-67: same selection, with the Metadata Language as the DOMINANT tier when a
 * preference is set. BUG-63's first cut ranked language BELOW the official/type tiers, which
 * regressed the moment the widened fetch put English official trailers into the candidate set:
 * an official English Trailer outranked a French Teaser/Featurette, so titles that used to play
 * French played English ("72 Hours", "Drop Game" — the beta.13 review). Pre-BUG-63, a French
 * Metadata Language fetched ONLY French videos and picked the best-tier among them — language
 * dominance reproduces that preference exactly, while the widened fetch keeps the English
 * fallback for titles with no localized video at all. Still a preference, never a filter.
 *
 * Deliberately an OVERLOAD rather than a default parameter: Kotlin/Native exports no default
 * arguments, so a default would rename the Objective-C selector the tvOS app already calls
 * (`HeroTrailerSelectorKt.selectHeroTrailer(trailers:)` in `DetailViewModel.swift` /
 * `InlineTrailerCard.swift`). `preferredLanguage` accepts either a bare code (`fr`) or a TMDB
 * locale (`fr-FR`, `pt-BR`).
 */
fun selectHeroTrailer(trailers: List<MetaTrailer>, preferredLanguage: String?): MetaTrailer? =
    rankHeroTrailers(trailers, preferredLanguage).firstOrNull()

/**
 * BUG-101: the full ranking `selectHeroTrailer` picks its head from, best first. A dead/blocked
 * top pick (e.g. a TMDB-listed French trailer whose YouTube id no longer resolves) used to be a
 * dead end — `selectHeroTrailer` only ever offered ONE candidate, so both tvOS callers
 * (`DetailViewModel.resolveTrailerIfNeeded`, `InlineTrailerCardModel.resolve`) gave up entirely
 * once extraction failed, even when a perfectly playable English trailer (merged into the
 * candidate list by `fetchTmdbVideos`'s preferred-language + en-US fetch) sat right behind it.
 * Exposing the ranked list lets both callers fall through to the next candidate instead of
 * failing soft to "no trailer" — same filter, same dedup, same comparator as `selectHeroTrailer`,
 * just not collapsed to a single result.
 */
fun rankHeroTrailers(trailers: List<MetaTrailer>, preferredLanguage: String?): List<MetaTrailer> {
    return trailers
        .asSequence()
        .filter { it.isPlayableYouTubeTrailerCandidate() }
        .distinctBy { it.key }
        .sortedWith(
            compareBy<MetaTrailer>(
                { it.metadataLanguagePriority(preferredLanguage) },
                { it.heroTrailerPriority() },
                { it.publishedAt.orEmpty() },
                { it.size ?: 0 },
                { it.name },
            ).reversed(),
        )
        .toList()
}

/**
 * BUG-67 rank, shared with the Trailers & Extras category ordering in `TmdbMetadataService`:
 * exact locale > base language > English > untagged > anything else. The en-before-untagged
 * fallback is BUG-63's shipped, tested order, deliberately kept; what BUG-67 changes is only
 * WHERE this rank sits (dominant, above the official/type tiers). No preference (the
 * one-argument overload) → constant, so the legacy ordering is preserved byte-identical.
 */
fun MetaTrailer.metadataLanguagePriority(preferredLanguage: String?): Int {
    val preferredFull = preferredLanguage?.trim()?.lowercase()?.takeIf { it.isNotBlank() } ?: return 0
    val preferredBase = preferredFull.substringBefore("-")
    val tag = language?.trim()?.lowercase()?.takeIf { it.isNotBlank() }
    val tagBase = tag?.substringBefore("-")
    return when {
        tag == preferredFull -> 5
        tagBase == preferredBase -> 4
        tagBase == "en" -> 3
        tag == null -> 2
        else -> 0
    }
}

fun MetaTrailer.youtubePlaybackUrl(): String =
    key.takeIf { it.startsWith("http://") || it.startsWith("https://") }
        ?: "https://www.youtube.com/watch?v=$key"

private fun MetaTrailer.isPlayableYouTubeTrailerCandidate(): Boolean =
    key.isNotBlank() && site.equals("YouTube", ignoreCase = true)

private fun MetaTrailer.heroTrailerPriority(): Int {
    val isSeriesTrailer = seasonNumber != null
    val isTrailerType = type.equals("Trailer", ignoreCase = true)
    return when {
        !isSeriesTrailer && isTrailerType && official -> 70
        !isSeriesTrailer && isTrailerType -> 60
        !isSeriesTrailer && official -> 50
        !isSeriesTrailer -> 40
        isTrailerType && official -> 30
        isTrailerType -> 20
        official -> 10
        else -> 0
    }
}
