package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.tracking.WatchProgressSource
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

/**
 * Identity of a metadata-resolution group.
 *
 * Fork note: upstream keys on `parentMetaType.ifBlank { contentType }`. The fork keeps the
 * shipped `(parentMetaId, contentType)` pairing so the exact same `MetaDetailsRepository.fetch`
 * calls are made as before this refactor.
 */
data class WatchProgressMetadataKey(
    val metaId: String,
    val metaType: String,
)

fun WatchProgressEntry.metadataKey(): WatchProgressMetadataKey = WatchProgressMetadataKey(
    metaId = parentMetaId,
    metaType = contentType,
)

/**
 * Metadata overlay applied on top of a *provider-owned* progress projection.
 *
 * Provider snapshots are read-only from the application's point of view, so enrichment results
 * cannot be written back into local storage the way they are for the Nuvio Sync source. The
 * overlay caches resolved [MetaDetails] per source and re-applies them on every read instead.
 */
class ProviderProgressMetadataOverlay {
    private val lock = SynchronizedObject()
    private var source: WatchProgressSource? = null
    private val metadataByKey = mutableMapOf<WatchProgressMetadataKey, MetaDetails>()

    fun clear() {
        synchronized(lock) {
            source = null
            metadataByKey.clear()
        }
    }

    fun put(
        source: WatchProgressSource,
        key: WatchProgressMetadataKey,
        metadata: MetaDetails,
    ): Boolean = synchronized(lock) {
        if (this.source != source) {
            this.source = source
            metadataByKey.clear()
        }
        val previous = metadataByKey.put(key, metadata)
        previous != metadata
    }

    fun project(
        source: WatchProgressSource,
        entries: Collection<WatchProgressEntry>,
    ): List<WatchProgressEntry> {
        val metadata = synchronized(lock) {
            if (this.source == source) metadataByKey.toMap() else emptyMap()
        }
        if (metadata.isEmpty()) return entries.toList()
        return entries.map { entry ->
            metadata[entry.metadataKey()]
                ?.let { meta -> enrichWatchProgressEntry(current = entry, meta = meta) }
                ?: entry
        }
    }
}
