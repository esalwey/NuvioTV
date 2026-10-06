package com.nuvio.app.features.details

/**
 * Pure helpers extracted from [MetaDetailsRepository] for BUG-7 regression coverage.
 *
 * BUG-7: the tvOS detail page hung forever because the addon-returned meta id (tt…) differed
 * from the preview id (tmdb:…), and stale-publish guards ended up comparing against the wrong
 * id. The fix threads a `requestKey` built from the ORIGINAL type/id through every
 * [MetaDetailsUiState] publish, and guards every publish against `activeRequestKey`.
 *
 * These helpers isolate the pure, testable pieces of that logic — requestKey construction,
 * tmdb-prefixed id detection/parsing, and the stale-publish equality check — so they can be
 * regression-tested without spinning up the full repository object (which depends on
 * TmdbService/AddonRepository/coroutine scopes/etc.). [MetaDetailsRepository] delegates to
 * these instead of re-implementing the logic inline.
 */
internal object MetaRequestResolution {

    /**
     * Builds the requestKey used to correlate a `load()` call with its eventual publish. Always
     * derived from the ORIGINAL type/id the caller asked for — never the remapped meta-lookup id
     * — so a mid-flight id remap (e.g. `tmdb:123` -> resolved `tt...`) can't desync the
     * stale-publish guard from the request the UI is actually waiting on.
     */
    fun requestKey(type: String, id: String): String = "$type:$id"

    /**
     * Parses a `tmdb:<id>` (case-insensitive prefix) form and returns the numeric TMDB id, or
     * null if [itemId] isn't a valid tmdb-prefixed id — wrong/missing prefix, blank id portion,
     * or a non-numeric id portion (e.g. `tmdb:`, `tt123`, `tmdb:abc`).
     */
    fun parseTmdbId(itemId: String): Int? =
        itemId
            .takeIf { it.startsWith("tmdb:", ignoreCase = true) }
            ?.substringAfter(':')
            ?.substringBefore(':')
            ?.toIntOrNull()

    /** True when [itemId] requires a tmdb -> addon-lookup-id remap before hitting meta addons. */
    fun needsRemap(itemId: String): Boolean = parseTmdbId(itemId) != null

    /**
     * Stale-publish guard: is [ownRequestKey] still the repository's active request? A publish
     * must be dropped whenever a newer `load()` call has taken over the shared repository (i.e.
     * [activeRequestKey] no longer matches the request that produced this result).
     */
    fun isActiveRequest(activeRequestKey: String?, ownRequestKey: String): Boolean =
        activeRequestKey == ownRequestKey
}
