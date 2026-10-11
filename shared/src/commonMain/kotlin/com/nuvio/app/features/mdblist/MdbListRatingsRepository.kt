package com.nuvio.app.features.mdblist

import co.touchlab.kermit.Logger
import com.nuvio.app.features.details.MetaExternalRating
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Ratings for a title, one MDBList request per title instead of one per provider. Requests made
 * within [BATCH_WINDOW_MS] of each other (a detail page and the rows opened beside it) share a
 * single batched call, the response is cached for every provider, and a title already in flight
 * is joined rather than asked for again. A failed call is not cached, so the next open retries.
 */
internal class MdbListRatingsRepository(
    private val client: MdbListRatingsClient = MdbListRatingsClient(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private data class RequestKey(
        val mediaType: String,
        val imdbId: String,
        val apiKey: String,
    ) {
        // The key is a secret: never let a stray log line print it.
        override fun toString(): String = "RequestKey($mediaType, $imdbId)"
    }

    private val log = Logger.withTag("MdbListRatings")
    private val lock = SynchronizedObject()
    private val cache = mutableMapOf<RequestKey, List<MetaExternalRating>>()
    private val inFlight = mutableMapOf<RequestKey, CompletableDeferred<List<MetaExternalRating>>>()
    private val pending = mutableMapOf<RequestKey, CompletableDeferred<List<MetaExternalRating>>>()
    private var batchScheduled = false

    suspend fun getRatings(
        mediaType: String,
        imdbId: String,
        apiKey: String,
        providers: List<String>,
    ): List<MetaExternalRating> {
        if (providers.isEmpty()) return emptyList()
        val key = RequestKey(mediaType, imdbId, apiKey)
        val deferred = synchronized(lock) {
            cache[key]?.let { return selectRatings(it, providers) }
            inFlight[key] ?: CompletableDeferred<List<MetaExternalRating>>().also { created ->
                inFlight[key] = created
                pending[key] = created
                if (!batchScheduled) {
                    batchScheduled = true
                    scope.launch {
                        delay(BATCH_WINDOW_MS)
                        flushPending()
                    }
                }
            }
        }
        return selectRatings(deferred.await(), providers)
    }

    fun clearCache() {
        synchronized(lock) {
            cache.clear()
            pending.clear()
            // Settings changed under a request: release its waiters with nothing rather than
            // cancel them (they run inside the detail load), and never cache the late answer.
            inFlight.values.forEach { it.complete(emptyList()) }
            inFlight.clear()
        }
    }

    private suspend fun flushPending() {
        val requests = synchronized(lock) {
            batchScheduled = false
            pending.toList().also { pending.clear() }
        }
        requests.groupBy { (key, _) -> key.mediaType to key.apiKey }.values.forEach { group ->
            group.chunked(MAX_BATCH_SIZE).forEach { fetchBatch(it) }
        }
    }

    private suspend fun fetchBatch(requests: List<Pair<RequestKey, CompletableDeferred<List<MetaExternalRating>>>>) {
        val batch = synchronized(lock) { requests.filter { (key, deferred) -> inFlight[key] === deferred } }
        val first = batch.firstOrNull()?.first ?: return
        try {
            val ratings = if (batch.size == 1) {
                mapOf(first.imdbId to parseMdbListRatings(client.getMedia(first.mediaType, first.imdbId, first.apiKey)))
            } else {
                parseMdbListRatingsBatch(client.getMediaBatch(first.mediaType, batch.map { it.first.imdbId }, first.apiKey))
            }
            synchronized(lock) {
                batch.forEach { (key, deferred) ->
                    if (inFlight[key] === deferred) {
                        val result = ratings[key.imdbId].orEmpty()
                        cache[key] = result
                        inFlight.remove(key)
                        deferred.complete(result)
                    }
                }
            }
        } catch (error: Throwable) {
            if (error !is CancellationException) log.w { "MDBList ratings request failed for ${batch.size} items" }
            synchronized(lock) {
                batch.forEach { (key, deferred) ->
                    if (inFlight[key] === deferred) inFlight.remove(key)
                    if (error is CancellationException) deferred.completeExceptionally(error)
                    else deferred.complete(emptyList())
                }
            }
        }
    }

    private fun selectRatings(ratings: List<MetaExternalRating>, providers: List<String>): List<MetaExternalRating> =
        providers.mapNotNull { provider -> ratings.firstOrNull { it.source == provider } }

    private companion object {
        const val MAX_BATCH_SIZE = 200
        const val BATCH_WINDOW_MS = 50L
    }
}
