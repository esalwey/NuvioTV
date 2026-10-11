package com.nuvio.app.features.shuffle

import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlin.random.Random

/**
 * Series "Shuffle": a random episode, unwatched ones first. Once every released episode is
 * watched the pool widens to all of them, so the action never goes dead on a finished series.
 * The pick history lives in memory per series, so successive presses walk through the episodes
 * without repeating before the whole pool has been shown.
 */
object EpisodeShuffle {
    private const val MaxSessions = 64

    private val lock = SynchronizedObject()
    private val sessions = linkedMapOf<String, RandomEpisodePicker>()

    /** Number of episodes a shuffle can draw from (all released main-season episodes). */
    fun count(videos: List<MetaVideo>): Int =
        RandomEpisodePicker("", videos, emptySet()).count(includeWatched = true)

    /**
     * Picks the next episode to play. [watchedKeys] are the watched episodes as `"season:episode"`.
     * Null only when the series has no released main-season episode.
     */
    fun pick(contentId: String, videos: List<MetaVideo>, watchedKeys: Set<String>): MetaVideo? =
        pick(contentId, videos, parseEpisodeKeys(watchedKeys), Random.Default, CurrentDateProvider.todayIsoDate())

    internal fun pick(
        contentId: String,
        videos: List<MetaVideo>,
        watched: Set<Pair<Int, Int>>,
        random: Random,
        todayIsoDate: String,
    ): MetaVideo? = synchronized(lock) {
        pickFrom(contentId, includeWatched = false, videos, watched, random, todayIsoDate)
            ?: pickFrom(contentId, includeWatched = true, videos, watched, random, todayIsoDate)
    }

    fun clear() = synchronized(lock) { sessions.clear() }

    private fun pickFrom(
        contentId: String,
        includeWatched: Boolean,
        videos: List<MetaVideo>,
        watched: Set<Pair<Int, Int>>,
        random: Random,
        todayIsoDate: String,
    ): MetaVideo? {
        val key = "$contentId|$includeWatched"
        val previous = sessions.remove(key)
        val picker = RandomEpisodePicker(contentId, videos, watched, random, todayIsoDate)
        picker.inheritHistoryFrom(previous)
        sessions[key] = picker
        while (sessions.size > MaxSessions) sessions.remove(sessions.keys.first())
        return picker.pick(includeWatched)
    }
}

internal fun parseEpisodeKeys(keys: Set<String>): Set<Pair<Int, Int>> = keys.mapNotNull { key ->
    val parts = key.split(':')
    val season = parts.getOrNull(0)?.toIntOrNull() ?: return@mapNotNull null
    val episode = parts.getOrNull(1)?.toIntOrNull() ?: return@mapNotNull null
    season to episode
}.toSet()
