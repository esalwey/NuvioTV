package com.nuvio.app.features.simkl

import com.nuvio.app.features.watchprogress.TrackerOptimisticProgressTtlMs
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watchprogress.shouldReplaceProgressSnapshotEntry
import com.nuvio.app.features.watchprogress.trackerSnapshotConfirmsOptimisticProgress

/**
 * CW sync (REMAINING_FIX #3): local playback rows laid over the Simkl progress projection, so Home
 * follows local playback at once when Simkl is the Watch Progress Source — Trakt's
 * `putOptimisticProgress` / `mergeWithActiveOptimistic` / `reconcileOptimisticProgress`, for Simkl.
 *
 * With Simkl as the source, Continue Watching is the Simkl snapshot alone (Simkl can represent every
 * id, so no local row gets through), and that snapshot only moves when a scrobble commits or a
 * network refresh lands. Every local progress write therefore lands here too
 * (`SimklTrackingProgressProvider.applyOptimisticProgress`):
 * - a row lives [ttlMs] past its last write, and longer while [hold] says so (a scrobble stop in
 *   flight, or one that failed — `SimklMutationRepository.scrobble`); a delivered stop ends its
 *   hold again ([release]);
 * - it is keyed by episode (content id, season, episode — the content id was normalized to Simkl's
 *   canonical id when the row was written), not by progress key: Simkl's rows carry session keys
 *   (`simkl-playback:<id>`), the local ones `<id>_s<n>e<n>`;
 * - on read ([merge]) it replaces the snapshot row of the same episode when it is the newer one
 *   (`shouldReplaceProgressSnapshotEntry`, the rule every snapshot merge uses), taking that row's
 *   progress key so a removal from Continue Watching still deletes the Simkl session;
 * - on every new snapshot ([reconcile]) a row the snapshot confirms goes away
 *   (`trackerSnapshotConfirmsOptimisticProgress`, Trakt's rule), as does an expired one.
 *
 * A completed row is never confirmed by the progress projection — Simkl drops the session and marks
 * the episode watched — so it simply expires; while it lives it is the series' newest row, which is
 * what Continue Watching needs to move past it.
 *
 * Rows belong to the profile that wrote them: another profile reads the bare snapshot, and its first
 * write drops them. Not thread-safe — `SimklProgressRepository` makes every call under its
 * publication lock.
 */
internal class SimklOptimisticProgressOverlay(
    private val ttlMs: Long = TrackerOptimisticProgressTtlMs,
) {
    private data class EpisodeKey(val contentId: String, val season: Int?, val episode: Int?)

    private data class Held(val progress: WatchProgressEntry, val expiresAtMs: Long)

    private var ownerProfileId: Int? = null
    private var held: Map<EpisodeKey, Held> = emptyMap()

    val isEmpty: Boolean
        get() = held.isEmpty()

    /**
     * Records a local write. True when the rows changed (the caller republishes). A newer write of
     * an episode never shortens that episode's hold: a flush after a failed stop (the app going to
     * the background on the end screen) must not bring the stale snapshot back 3 minutes later.
     */
    fun put(profileId: Int, entry: WatchProgressEntry, nowEpochMs: Long): Boolean {
        if (ownerProfileId != profileId) {
            ownerProfileId = profileId
            held = emptyMap()
        }
        val candidate = entry.normalizedCompletion()
        val key = candidate.episodeKey() ?: return false
        val active = held.filterValues { row -> row.expiresAtMs > nowEpochMs }.toMutableMap()
        val pruned = active.size != held.size
        val existing = active[key]
        val replaced = existing == null ||
            shouldReplaceProgressSnapshotEntry(existing = existing.progress, candidate = candidate)
        if (replaced) {
            active[key] = Held(
                progress = candidate,
                expiresAtMs = maxOf(nowEpochMs + ttlMs, existing?.expiresAtMs ?: 0L),
            )
        }
        held = active
        return replaced || pruned
    }

    /** [snapshotEntries] with the live rows laid over them, newest first. */
    fun merge(
        profileId: Int,
        snapshotEntries: List<WatchProgressEntry>,
        nowEpochMs: Long,
    ): List<WatchProgressEntry> {
        if (held.isEmpty() || ownerProfileId != profileId) return snapshotEntries
        prune(nowEpochMs)
        if (held.isEmpty()) return snapshotEntries

        val merged = ArrayList<WatchProgressEntry>(snapshotEntries.size + held.size)
        val remoteByKey = LinkedHashMap<EpisodeKey, WatchProgressEntry>()
        snapshotEntries.forEach { remote ->
            val key = remote.episodeKey()
            if (key == null || key !in held) {
                merged += remote
                return@forEach
            }
            val existing = remoteByKey[key]
            if (existing == null || shouldReplaceProgressSnapshotEntry(existing = existing, candidate = remote)) {
                remoteByKey[key] = remote
            }
        }
        held.forEach { (key, row) ->
            val optimistic = row.progress
            val remote = remoteByKey[key]
            merged += when {
                remote == null -> optimistic
                shouldReplaceProgressSnapshotEntry(existing = remote, candidate = optimistic) ->
                    optimistic.copy(progressKey = remote.progressKey ?: optimistic.progressKey)
                else -> remote
            }
        }
        return merged.sortedByDescending(WatchProgressEntry::lastUpdatedEpochMs)
    }

    /** Drops the rows [snapshotEntries] confirms, and the expired ones. True when any went. */
    fun reconcile(snapshotEntries: List<WatchProgressEntry>, nowEpochMs: Long): Boolean {
        if (held.isEmpty()) return false
        val remoteByKey = snapshotEntries.groupBy { remote -> remote.episodeKey() }
        val kept = held.filter { (key, row) ->
            row.expiresAtMs > nowEpochMs &&
                remoteByKey[key].orEmpty().none { remote ->
                    trackerSnapshotConfirmsOptimisticProgress(remote = remote, optimistic = row.progress)
                }
        }
        val changed = kept.size != held.size
        held = kept
        return changed
    }

    /**
     * Keeps the live rows of [contentIds] until at least [untilEpochMs] (never shortens a hold).
     * Returns how many rows it holds.
     */
    fun hold(profileId: Int, contentIds: Collection<String>, untilEpochMs: Long, nowEpochMs: Long): Int {
        if (held.isEmpty() || ownerProfileId != profileId) return 0
        val ids = contentIds.mapNotNullTo(mutableSetOf()) { id -> id.trim().takeIf(String::isNotEmpty) }
        if (ids.isEmpty()) return 0
        var count = 0
        held = held.mapValues { (key, row) ->
            if (key.contentId in ids && row.expiresAtMs > nowEpochMs) {
                count += 1
                row.copy(expiresAtMs = maxOf(row.expiresAtMs, untilEpochMs))
            } else {
                row
            }
        }
        return count
    }

    /**
     * A stop was delivered, so the in-flight hold that [hold] set up to [heldUntilEpochMs] is no
     * longer needed. The rows of [contentIds] held past [untilEpochMs], up to that deadline, are
     * brought back to [untilEpochMs]. Rows due to expire sooner are left alone, and so are rows held
     * longer (a failed stop's 24 h). Returns how many rows it released.
     */
    fun release(profileId: Int, contentIds: Collection<String>, untilEpochMs: Long, heldUntilEpochMs: Long): Int {
        if (held.isEmpty() || ownerProfileId != profileId) return 0
        val ids = contentIds.mapNotNullTo(mutableSetOf()) { id -> id.trim().takeIf(String::isNotEmpty) }
        if (ids.isEmpty()) return 0
        var count = 0
        held = held.mapValues { (key, row) ->
            if (key.contentId in ids && row.expiresAtMs > untilEpochMs && row.expiresAtMs <= heldUntilEpochMs) {
                count += 1
                row.copy(expiresAtMs = untilEpochMs)
            } else {
                row
            }
        }
        return count
    }

    /** Drops the rows of the same episodes as [entries] (a removal from Continue Watching). */
    fun removeEpisodes(entries: Collection<WatchProgressEntry>): Boolean {
        val keys = entries.mapNotNullTo(mutableSetOf()) { entry -> entry.episodeKey() }
        return removeWhere { key, _ -> key in keys }
    }

    /** Drops the rows of [videoIds] (a removal by playback id). */
    fun removeVideoIds(videoIds: Collection<String>): Boolean {
        val ids = videoIds.toSet()
        return removeWhere { _, row -> row.progress.videoId in ids }
    }

    fun clear(): Boolean {
        val changed = held.isNotEmpty()
        held = emptyMap()
        ownerProfileId = null
        return changed
    }

    private fun prune(nowEpochMs: Long) {
        if (held.values.any { row -> row.expiresAtMs <= nowEpochMs }) {
            held = held.filterValues { row -> row.expiresAtMs > nowEpochMs }
        }
    }

    private fun removeWhere(predicate: (EpisodeKey, Held) -> Boolean): Boolean {
        if (held.isEmpty()) return false
        val kept = held.filterNot { (key, row) -> predicate(key, row) }
        val changed = kept.size != held.size
        held = kept
        return changed
    }

    private fun WatchProgressEntry.episodeKey(): EpisodeKey? {
        val contentId = parentMetaId.trim().takeIf(String::isNotEmpty) ?: return null
        return EpisodeKey(contentId = contentId, season = seasonNumber, episode = episodeNumber)
    }
}
