package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.watching.domain.isSeriesLikeWatchingContentType
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * CW alias fix (REMAINING_FIX #2): the IMDb id Continue Watching groups a series under, for
 * display only.
 *
 * The same show can be stored under two ids. The details page and its episode list write under
 * the resolved meta id, and `tmdb:` only becomes `tt…` when a TMDB key is set and the lookup
 * answers in time. So one launch writes `tmdb:1396_s1e1`, a later one `tt0903747_s1e5`. Grouped
 * by the raw id, those are two series: two cards that look the same, and the one not launched
 * never moves.
 *
 * This map only changes how the row groups and deduplicates. No stored `parentMetaId` or progress
 * key is ever rewritten: the server, the other devices and the details page keep seeing the ids
 * that were written, and a card still launches under its own id.
 *
 * Only `tmdb:` ids are grouped ([isTmdbSeriesAliasId]): that is the lookup the aliases come from.
 * Other id families are left alone — an anime database, for one, files each season as its own
 * entry and names the same IMDb series for all of them, and grouping those would fold distinct
 * cards into one (and make "Remove" take them all).
 *
 * Fed from series metadata, never from the network itself ([canonical] is a map read): the
 * repository's metadata enrichment, the Up Next resolution, and a warm-up of the row's `tmdb:`
 * series cards (`WatchProgressRepository.continueWatchingRow`). [version] moves on every change,
 * so the repository republishes and Home rebuilds its row. The map describes metadata, not a
 * profile: it lives for the process and is only forgotten on sign-out ([clear]).
 */
object ContinueWatchingSeriesIdentity {
    /**
     * [confirmed]: the meta that named [canonicalId] was the IMDb id's own — the repository turned
     * the TMDB id into it through TMDB, the conversion the details page stores progress under —
     * rather than an add-on's `imdb_id` claim about a `tmdb:` meta.
     */
    private data class Alias(val canonicalId: String, val confirmed: Boolean)

    private val lock = SynchronizedObject()
    private val aliasById = mutableMapOf<String, Alias>()
    private val _version = MutableStateFlow(0L)

    /** Bumped whenever [canonical] may answer differently. */
    val version: StateFlow<Long> = _version.asStateFlow()

    /**
     * Learns the IMDb id of the series [meta] describes, fetched for [requestedId]: the addon's
     * `imdb_id` when it is one, else the meta id when it is one. The `tmdb:` ids among
     * [requestedId] and the meta id then group under it. Nothing but a series is learned. True
     * when the grouping changed (a mapping that only becomes confirmed changes no grouping).
     */
    fun record(requestedId: String, meta: MetaDetails): Boolean {
        if (!meta.type.isSeriesLikeWatchingContentType()) return false
        val metaId = meta.id.trim()
        val canonicalId = listOfNotNull(meta.imdbId, meta.id)
            .map(String::trim)
            .firstOrNull(String::isImdbSeriesId)
            ?: return false
        val confirmed = metaId == canonicalId
        val aliases = listOf(requestedId, meta.id)
            .map(String::trim)
            .filter(String::isTmdbSeriesAliasId)
            .distinct()
        if (aliases.isEmpty()) return false
        val changed = synchronized(lock) {
            var changed = false
            aliases.forEach { alias ->
                val existing = aliasById[alias]
                val next = when {
                    existing == null -> Alias(canonicalId, confirmed)
                    existing.canonicalId == canonicalId -> existing.copy(confirmed = existing.confirmed || confirmed)
                    // Another IMDb id for the same TMDB id: a confirmed answer replaces an add-on's
                    // claim, never the reverse.
                    confirmed || !existing.confirmed -> Alias(canonicalId, confirmed)
                    else -> existing
                }
                if (next != existing) {
                    aliasById[alias] = next
                    if (existing?.canonicalId != next.canonicalId) changed = true
                }
            }
            changed
        }
        if (changed) _version.update { value -> value + 1L }
        return changed
    }

    /** The id [id]'s series is grouped under: its IMDb id once learned, else [id] itself, trimmed. */
    fun canonical(id: String): String {
        val trimmed = id.trim()
        return synchronized(lock) { aliasById[trimmed]?.canonicalId } ?: trimmed
    }

    /**
     * True when [id] needs no lookup: it is not a `tmdb:` id (an IMDb id is canonical already, and
     * no other id is ever grouped), or its IMDb id is known.
     */
    fun isResolved(id: String): Boolean {
        val trimmed = id.trim()
        return !trimmed.isTmdbSeriesAliasId() || synchronized(lock) { trimmed in aliasById }
    }

    /**
     * False only for a `tmdb:` id whose IMDb id an add-on's `imdb_id` named without the TMDB
     * conversion confirming it ([Alias.confirmed]). "Remove from Continue Watching" takes such an
     * alias only when its rows carry the card's title (`continueWatchingSeriesContentIds`).
     */
    fun isConfirmed(id: String): Boolean {
        val trimmed = id.trim()
        return synchronized(lock) { aliasById[trimmed]?.confirmed } ?: true
    }

    /** How many ids group under another one (the diagnostics' `map=`). */
    fun aliasCount(): Int = synchronized(lock) { aliasById.size }

    /**
     * Sign-out: another account learns its own. Silent on purpose: the caller resets the published
     * state right after, and a [version] bump here would have the repository publish from another
     * thread while its entries are being cleared.
     */
    fun clear() {
        synchronized(lock) { aliasById.clear() }
    }
}

private fun String.isImdbSeriesId(): Boolean =
    length > 2 && startsWith("tt") && substring(2).all(Char::isDigit)

/**
 * The ids [ContinueWatchingSeriesIdentity] groups under an IMDb id: TMDB ids (`tmdb:1396`,
 * `tmdb:tv:1396`) — what the details page stores progress under when its TMDB lookup did not turn
 * the id into a `tt…` one.
 */
internal fun String.isTmdbSeriesAliasId(): Boolean =
    length > "tmdb:".length && startsWith("tmdb:", ignoreCase = true)

/** A series row for Continue Watching's grouping (the same test as `continueWatchingProgressEntries`). */
internal fun WatchProgressEntry.isContinueWatchingSeries(): Boolean =
    parentMetaType.isSeriesLikeWatchingContentType() || isEpisode

/**
 * The key Continue Watching groups [this] entry's title under: the canonical id of a series
 * ([ContinueWatchingSeriesIdentity]), the trimmed id of anything else — a `tmdb:` movie id and a
 * `tmdb:` series id of the same number are different titles.
 */
internal fun WatchProgressEntry.continueWatchingSeriesKey(canonicalSeriesId: (String) -> String): String =
    if (isContinueWatchingSeries()) canonicalSeriesId(parentMetaId) else parentMetaId.trim()

/**
 * The identity of [entry]'s Continue Watching CARD, for the tvOS row (F9): the series key of
 * [continueWatchingSeriesKey] behind a kind prefix, so a series keeps one card identity while the
 * row swaps its episode (E3 in progress → the E4 Up Next card), and a `tmdb:` movie never shares
 * a key with the `tmdb:` series of the same number. Display only, like the rest of this file: no
 * stored id changes. Public because Swift cannot see the internal helpers.
 */
fun continueWatchingCardKey(entry: WatchProgressEntry): String {
    val kind = if (entry.isContinueWatchingSeries()) "series" else "title"
    return "$kind:" + entry.continueWatchingSeriesKey(ContinueWatchingSeriesIdentity::canonical)
}

/**
 * The title two ids of one show are recognised by (the diagnostics' `ALIAS?`, the removal's check
 * of an unconfirmed alias): trimmed and lowercased. None while the row only carries its id as a
 * title (rows pulled before their metadata resolved).
 */
internal fun WatchProgressEntry.continueWatchingTitleKey(): String? =
    title.trim().lowercase().takeIf { key ->
        key.isNotEmpty() && !key.equals(parentMetaId.trim(), ignoreCase = true)
    }

/** How many series one profile load's warm-up looks up at most (REMAINING_FIX #2). */
internal const val ContinueWatchingSeriesIdentityWarmUpLimit = 30

/** How many times the warm-up tries one series whose meta could not be fetched, per profile load. */
internal const val ContinueWatchingSeriesIdentityWarmUpAttempts = 3

/** How long a series whose meta could not be fetched waits before the warm-up tries it again. */
internal const val ContinueWatchingSeriesIdentityWarmUpRetryDelayMs = 2 * 60_000L

/**
 * CW alias fix (REMAINING_FIX #2): the series whose meta the row's warm-up fetches to learn their
 * IMDb id, most recent first. An alias only shows as a card of its own, so the candidates are the
 * series cards of the row ([rowEntries]) stored under a `tmdb:` id whose IMDb id is not known yet
 * ([isResolved]), each with the metadata key the repository's enrichment uses for it (so both
 * share [MetaDetailsRepository]'s cache). How many are looked up is [SeriesIdentityWarmUpBudget]'s
 * call. The other alias shape, an Up Next seed, is learned when its card is resolved.
 */
internal fun selectSeriesIdentityWarmUpKeys(
    rowEntries: Collection<WatchProgressEntry>,
    isResolved: (String) -> Boolean,
): List<WatchProgressMetadataKey> = rowEntries
    .filter(WatchProgressEntry::isContinueWatchingSeries)
    .sortedByDescending(WatchProgressEntry::lastUpdatedEpochMs)
    .distinctBy { entry -> entry.parentMetaId.trim() }
    .filter { entry ->
        val id = entry.parentMetaId.trim()
        id.isTmdbSeriesAliasId() && !isMalformedNextUpSeedContentId(id) && !isResolved(id)
    }
    .map(WatchProgressEntry::metadataKey)

/** The series ids one [SeriesIdentityWarmUpBudget.claim] handed out, and the budget's generation then. */
internal data class SeriesIdentityWarmUpClaim(
    val generation: Long,
    val ids: List<String>,
)

/**
 * CW alias fix (review): what the row's warm-up may look up in one profile load. The row is
 * rebuilt on every playback tick and every publish, so the bound is per load, not per build: at
 * most [maxIds] distinct series, each tried at most [maxAttemptsPerId] times — a lookup that
 * fetched nothing (offline, add-ons not ready yet) is tried again by a build [retryDelayMs] later.
 * [reset] on every profile load and sign-out; a lookup still in flight then reports into nothing.
 */
internal class SeriesIdentityWarmUpBudget(
    private val maxIds: Int = ContinueWatchingSeriesIdentityWarmUpLimit,
    private val maxAttemptsPerId: Int = ContinueWatchingSeriesIdentityWarmUpAttempts,
    private val retryDelayMs: Long = ContinueWatchingSeriesIdentityWarmUpRetryDelayMs,
) {
    private class Lookup(var attempts: Int, var blockedUntilEpochMs: Long)

    private val lock = SynchronizedObject()
    private val lookupsById = mutableMapOf<String, Lookup>()
    private var generation = 0L

    /**
     * The ids of [candidates] (most wanted first) to look up now: new ones while the budget lasts,
     * and failed ones whose retry is due. Each claimed id is in flight until [finish].
     */
    fun claim(candidates: List<String>, nowEpochMs: Long): SeriesIdentityWarmUpClaim = synchronized(lock) {
        val claimed = mutableListOf<String>()
        candidates.map(String::trim).filter(String::isNotEmpty).distinct().forEach { id ->
            val lookup = lookupsById[id]
            if (lookup == null) {
                if (lookupsById.size < maxIds) {
                    lookupsById[id] = Lookup(attempts = 1, blockedUntilEpochMs = Long.MAX_VALUE)
                    claimed += id
                }
            } else if (lookup.blockedUntilEpochMs <= nowEpochMs && lookup.attempts < maxAttemptsPerId) {
                lookup.attempts += 1
                lookup.blockedUntilEpochMs = Long.MAX_VALUE
                claimed += id
            }
        }
        SeriesIdentityWarmUpClaim(generation = generation, ids = claimed)
    }

    /**
     * The lookup of [id], claimed in [generation], is over: [fetched] means the meta came back
     * (whether or not it named an IMDb id), and the id is done for this load. Otherwise it may be
     * tried again [retryDelayMs] from [nowEpochMs], while attempts remain.
     */
    fun finish(generation: Long, id: String, fetched: Boolean, nowEpochMs: Long) {
        synchronized(lock) {
            if (generation != this.generation) return
            val lookup = lookupsById[id.trim()] ?: return
            lookup.blockedUntilEpochMs = if (fetched || lookup.attempts >= maxAttemptsPerId) {
                Long.MAX_VALUE
            } else {
                nowEpochMs + retryDelayMs
            }
        }
    }

    fun isCurrent(generation: Long): Boolean = synchronized(lock) { generation == this.generation }

    /** Distinct series claimed this load (the diagnostics' `wu=`). */
    fun claimedCount(): Int = synchronized(lock) { lookupsById.size }

    fun reset() {
        synchronized(lock) {
            generation += 1L
            lookupsById.clear()
        }
    }
}

/**
 * CW alias fix: every stored id Continue Watching shows under [card] — the card's own id
 * (trimmed) first, then, for a series, the other ids of [entries] with the same canonical id, as
 * stored. What "Remove from Continue Watching" removes, so no alias card is left behind.
 *
 * The removal deletes on the account too, so an alias whose mapping an add-on's `imdb_id` alone
 * named ([isConfirmedAlias] false for it or the card's id) joins only when one of its rows carries
 * a title of the card's ([continueWatchingTitleKey]): a wrong `imdb_id` groups two shows on the
 * row, and must not have one's progress deleted with the other's. Such an alias is reported to
 * [onAliasLeftOut] instead; it shows as a card of its own again, removable in turn.
 */
internal fun continueWatchingSeriesContentIds(
    entries: Collection<WatchProgressEntry>,
    card: WatchProgressEntry,
    canonicalSeriesId: (String) -> String,
    isConfirmedAlias: (String) -> Boolean = { true },
    onAliasLeftOut: (String) -> Unit = {},
): List<String> {
    val requested = card.parentMetaId.trim()
    if (requested.isEmpty()) return emptyList()
    if (!card.isContinueWatchingSeries()) return listOf(requested)
    val target = canonicalSeriesId(requested)
    val seriesEntries = entries.filter(WatchProgressEntry::isContinueWatchingSeries)
    val aliases = seriesEntries
        .map(WatchProgressEntry::parentMetaId)
        .filter { id -> id.trim() != requested && canonicalSeriesId(id) == target }
        .distinct()
    if (aliases.isEmpty()) return listOf(requested)
    val cardTitles = (seriesEntries.filter { entry -> entry.parentMetaId.trim() == requested } + card)
        .mapNotNullTo(mutableSetOf()) { entry -> entry.continueWatchingTitleKey() }
    val (kept, leftOut) = aliases.partition { alias ->
        (isConfirmedAlias(alias) && isConfirmedAlias(requested)) ||
            seriesEntries.any { entry ->
                entry.parentMetaId == alias && entry.continueWatchingTitleKey()?.let { it in cardTitles } == true
            }
    }
    leftOut.forEach(onAliasLeftOut)
    return listOf(requested) + kept
}
