package com.nuvio.app.features.trakt

import com.nuvio.app.features.details.MetaDetails
import kotlinx.coroutines.CancellationException

/**
 * Swift-safe wrapper around [TraktCommentsRepository.getCommentsPage].
 *
 * Kotlin suspend functions exported to Swift TERMINATE THE PROCESS when they throw anything
 * outside their `@Throws` list (only `CancellationException` is implicit). `getCommentsPage`
 * throws `IllegalStateException` on HTTP errors — mobile's Compose caller catches it, but on
 * tvOS the throw crossed the completion-handler bridge and killed the app (hit 2026-07-07 on
 * the movie Detail page: "Failed to load Trakt comments (401)" after Trakt credential sync
 * connected the TV).
 *
 * Failures collapse to `null`; the comments section simply stays hidden. Any OTHER throwing
 * suspend function that Swift calls directly needs the same treatment.
 */
object TraktCommentsSwiftBridge {
    suspend fun pageOrNull(
        meta: MetaDetails,
        page: Int,
        forceRefresh: Boolean,
    ): TraktCommentsPage? = try {
        TraktCommentsRepository.getCommentsPage(meta = meta, page = page, forceRefresh = forceRefresh)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }
}
