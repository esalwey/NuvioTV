package com.nuvio.app.features.shuffle

import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.details.filterUnavailableFutureSeasons
import com.nuvio.app.features.details.isReleasedBy
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import kotlin.random.Random

/**
 * Picks a random released main-season episode of one series. Every candidate is shown once before
 * any repeats, and the first pick of a new cycle never repeats the last pick of the previous one.
 * Specials (season 0), unreleased episodes and episodes without ids are never candidates.
 */
internal class RandomEpisodePicker(
    private val contentId: String,
    videos: List<MetaVideo>,
    watchedEpisodes: Set<Pair<Int, Int>>,
    private val random: Random = Random.Default,
    todayIsoDate: String = CurrentDateProvider.todayIsoDate(),
) {
    private val episodes = videos
        .filter { (it.season ?: 0) > 0 && it.episode != null }
        .filterUnavailableFutureSeasons(todayIsoDate)
        .filter { it.isReleasedBy(todayIsoDate) }
        .filter { it.id.isNotBlank() && (it.episode ?: 0) > 0 }
        .distinctBy { it.season to it.episode }
        .distinctBy { it.id }
    private val unwatchedEpisodes = episodes.filterNot { (it.season to it.episode) in watchedEpisodes }
    private val shownIds = mutableSetOf<String>()
    private var lastPickedId: String? = null

    fun count(includeWatched: Boolean): Int = candidates(includeWatched).size

    /** Carries the picks already made over to a picker built from refreshed metadata. */
    fun inheritHistoryFrom(previous: RandomEpisodePicker?) {
        if (previous == null || previous.contentId != contentId) return
        shownIds.addAll(previous.shownIds)
        lastPickedId = previous.lastPickedId
    }

    fun pick(includeWatched: Boolean): MetaVideo? {
        val candidates = candidates(includeWatched)
        if (candidates.isEmpty()) return null
        val unseen = candidates.filterNot { it.id in shownIds }
        val pool = unseen.ifEmpty {
            shownIds.removeAll(candidates.map { it.id }.toSet())
            candidates.filterNot { it.id == lastPickedId }.ifEmpty { candidates }
        }
        return pool.random(random).also {
            shownIds.add(it.id)
            lastPickedId = it.id
        }
    }

    private fun candidates(includeWatched: Boolean): List<MetaVideo> =
        if (includeWatched) episodes else unwatchedEpisodes
}
