package com.nuvio.app.features.collection

import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

object CollectionRepository {
    private val log = Logger.withTag("CollectionRepository")
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    // Serializes every read-map-assign mutation of _collections/rawCollectionsJson plus its
    // persist(): a remote pull (applyFromRemote, sync dispatcher) interleaving with a UI-driven
    // updateCollection could otherwise re-assign a stale snapshot — e.g. resurrect a collection
    // the pull just removed — and then persist and push the resurrection. Reentrant, so locked
    // mutators may call ensureLoaded()/initialize(). (Codex round 5.)
    private val mutationLock = SynchronizedObject()

    private val _collections = MutableStateFlow<List<Collection>>(emptyList())
    val collections: StateFlow<List<Collection>> = _collections.asStateFlow()
    private val _localChangeEvents = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    internal val localChangeEvents: SharedFlow<Unit> = _localChangeEvents.asSharedFlow()
    private var rawCollectionsJson: JsonElement = JsonArray(emptyList())

    private var hasLoaded = false

    fun initialize(): Unit = synchronized(mutationLock) {
        if (hasLoaded) return
        hasLoaded = true
        val payload = CollectionStorage.loadPayload()
        if (payload.isNullOrBlank()) return

        runCatching {
            val parsed = json.parseToJsonElement(payload)
            rawCollectionsJson = parsed
            val decoded = json.decodeFromJsonElement<List<Collection>>(parsed)
            val normalized = normalizeCollections(decoded, source = "local storage")
            _collections.value = CollectionMobileSettingsRepository.applyToCollections(normalized)
            if (normalized.size != decoded.size) {
                persist(sync = false)
            }
        }.onFailure { e ->
            log.e(e) { "Failed to load collections from storage" }
        }
    }

    fun onProfileChanged(): Unit = synchronized(mutationLock) {
        hasLoaded = false
        _collections.value = emptyList()
        rawCollectionsJson = JsonArray(emptyList())
    }

    fun clearLocalState(): Unit = synchronized(mutationLock) {
        hasLoaded = false
        _collections.value = emptyList()
        rawCollectionsJson = JsonArray(emptyList())
    }

    fun getCollection(id: String): Collection? =
        _collections.value.find { it.id == id }

    fun addCollection(collection: Collection): Unit = synchronized(mutationLock) {
        ensureLoaded()
        val decorated = CollectionMobileSettingsRepository.applyToCollection(collection)
        _collections.value = _collections.value.upsertCollectionById(decorated)
        persist()
    }

    /**
     * Returns false when the update did not land: the collection no longer exists (a sync pull
     * removed it mid-edit — the map would otherwise silently change nothing and report success),
     * or the payload did not durably persist (in-memory state is still updated in that case).
     */
    fun updateCollection(collection: Collection): Boolean = synchronized(mutationLock) {
        ensureLoaded()
        val decorated = CollectionMobileSettingsRepository.applyToCollection(collection)
        var found = false
        _collections.value = _collections.value.deduplicatedById().map {
            if (it.id == collection.id) {
                found = true
                decorated
            } else {
                it
            }
        }
        if (!found) {
            log.w { "updateCollection — ${collection.id} no longer exists; edit dropped" }
            return false
        }
        persist()
    }

    fun removeCollection(collectionId: String): Unit = synchronized(mutationLock) {
        ensureLoaded()
        _collections.value = _collections.value.filter { it.id != collectionId }
        persist()
    }

    fun setCollections(collections: List<Collection>): Unit = synchronized(mutationLock) {
        ensureLoaded()
        val normalized = normalizeCollections(collections, source = "setCollections")
        _collections.value = CollectionMobileSettingsRepository.applyToCollections(normalized)
        persist()
    }

    fun moveUp(index: Int) {
        moveByIndex(index, index - 1)
    }

    fun moveDown(index: Int) {
        moveByIndex(index, index + 1)
    }

    fun moveByIndex(fromIndex: Int, toIndex: Int): Unit = synchronized(mutationLock) {
        ensureLoaded()
        val list = _collections.value.toMutableList()
        if (fromIndex == toIndex) return
        if (fromIndex !in list.indices || toIndex !in list.indices) return
        val item = list.removeAt(fromIndex)
        list.add(toIndex, item)
        _collections.value = list
        persist()
    }

    fun exportToJson(): String = synchronized(mutationLock) {
        ensureLoaded()
        mergedCollectionsJson().toString()
    }

    fun importFromJson(jsonString: String): Result<List<Collection>> = synchronized(mutationLock) {
        runCatching {
            val validation = validateJson(jsonString)
            if (!validation.valid) {
                throw IllegalArgumentException(validation.error.orEmpty())
            }
            // Fork: same idiom as upstream 8b43fd89 applied to the import path.
            val parsed = json.parseToJsonElement(jsonString)
            rawCollectionsJson = parsed
            val imported = json.decodeFromJsonElement<List<Collection>>(parsed).deduplicatedById()
            _collections.value = CollectionMobileSettingsRepository.applyToCollections(imported)
            persist()
            imported
        }
    }

    fun validateJson(jsonString: String): ValidationResult {
        if (jsonString.isBlank()) {
            return ValidationResult(
                valid = false,
                error = resourceString("JSON is empty.", StringKey.collections_import_error_empty_json),
            )
        }
        return try {
            val collections = json.decodeFromString<List<Collection>>(jsonString)
            validateImportModel(collections)?.let { error ->
                return ValidationResult(valid = false, error = error.localizedMessage())
            }
            ValidationResult(
                valid = true,
                collectionCount = collections.size,
                folderCount = collections.sumOf { it.folders.size },
            )
        } catch (e: Exception) {
            ValidationResult(
                valid = false,
                error = resourceString("Invalid JSON: ${e.message.orEmpty()}", StringKey.collections_import_error_invalid_json, e.message.orEmpty()),
            )
        }
    }

    @OptIn(ExperimentalUuidApi::class)
    fun generateId(): String = Uuid.random().toString()

    fun getAvailableCatalogs(): List<AvailableCatalog> {
        val addons = AddonRepository.uiState.value.addons.enabledAddons()
        return addons.mapNotNull { addon ->
            val manifest = addon.manifest ?: return@mapNotNull null
            addon to manifest
        }.flatMap { (addon, manifest) ->
            manifest.catalogs
                .filter { catalog -> catalog.extra.none { it.isRequired && it.name != "genre" } }
                .map { catalog ->
                    val genreExtra = catalog.extra.firstOrNull { it.name == "genre" }
                    AvailableCatalog(
                        addonId = manifest.id,
                        addonName = addon.displayTitle,
                        type = catalog.type,
                        catalogId = catalog.id,
                        catalogName = catalog.name,
                        genreOptions = genreExtra?.options.orEmpty(),
                        genreRequired = genreExtra?.isRequired == true,
                    )
                }
        }
    }

    /**
     * BUG-38 (tvOS beta.13 diagnostics): for every folder in the raw synced payload, the JSON keys
     * that this build's [CollectionFolder] does NOT read (`ignoreUnknownKeys = true` drops them
     * silently — a cover/backdrop/logo written by another client under a different spelling is
     * exactly what looks like "my covers don't show"). Keyed `"<collectionId>|<folderId>"` (folder
     * ids are unique per collection, not globally); folders with no unknown keys are omitted. Read
     * by tvOS's `[CollectionCover]` probe.
     */
    fun unknownFolderKeysFromRawPayload(): Map<String, List<String>> {
        val known = CollectionFolder.serializer().descriptor.let { d -> (0 until d.elementsCount).map(d::getElementName).toSet() }
        val result = mutableMapOf<String, List<String>>()
        val collections = rawCollectionsJson as? JsonArray ?: return result
        for (collection in collections) {
            val collectionObj = collection as? kotlinx.serialization.json.JsonObject ?: continue
            val collectionId = (collectionObj["id"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: continue
            val folders = collectionObj["folders"] as? JsonArray ?: continue
            for (folder in folders) {
                val obj = folder as? kotlinx.serialization.json.JsonObject ?: continue
                val id = (obj["id"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: continue
                val unknown = obj.keys.filter { it !in known }.sorted()
                if (unknown.isNotEmpty()) result["$collectionId|$id"] = unknown
            }
        }
        return result
    }

    internal fun applyFromRemote(collections: List<Collection>, rawJson: JsonElement): Unit = synchronized(mutationLock) {
        rawCollectionsJson = rawJson
        val normalized = normalizeCollections(collections, source = "remote sync")
        _collections.value = CollectionMobileSettingsRepository.applyToCollections(normalized)
        persist(sync = false)
    }

    internal fun onMobileSettingsChanged(): Unit = synchronized(mutationLock) {
        if (!hasLoaded) return
        _collections.value = CollectionMobileSettingsRepository.applyToCollections(
            _collections.value.deduplicatedById(),
        )
    }

    private fun normalizeCollections(collections: List<Collection>, source: String): List<Collection> {
        val normalized = collections.deduplicatedById()
        if (normalized.size != collections.size) {
            log.w {
                "Dropped ${collections.size - normalized.size} duplicate collection IDs from $source"
            }
        }
        return normalized
    }

    private fun ensureLoaded() {
        if (!hasLoaded) initialize()
    }

    /** Test seam: lets tests force a storage-write failure without a platform hook. */
    internal var payloadWriter: (String) -> Boolean = { CollectionStorage.savePayload(it) }

    /** Returns false when the payload did not durably persist (logged; in-memory state is kept). */
    private fun persist(sync: Boolean = true): Boolean =
        runCatching {
            val saved = payloadWriter(mergedCollectionsJson().toString())
            if (!saved) log.e { "Failed to persist collections — storage write did not land" }
            if (saved && sync) {
                _localChangeEvents.tryEmit(Unit)
            }
            saved
        }.getOrElse { e ->
            log.e(e) { "Failed to persist collections" }
            false
        }

    private fun mergedCollectionsJson(): JsonArray =
        CollectionJsonPreserver.merge(json, rawCollectionsJson, _collections.value).also {
            rawCollectionsJson = it
        }
}

// Fork: public (upstream: internal) — composeApp CollectionRepositoryTest consumes cross-module.
fun List<Collection>.deduplicatedById(): List<Collection> {
    if (size < 2) return this

    val collectionsById = linkedMapOf<String, Collection>()
    forEach { collection ->
        collectionsById[collection.id] = collection
    }
    return if (collectionsById.size == size) this else collectionsById.values.toList()
}

// Fork: public (upstream: internal) — composeApp CollectionRepositoryTest consumes cross-module.
fun List<Collection>.upsertCollectionById(collection: Collection): List<Collection> {
    val normalized = deduplicatedById()
    val existingIndex = normalized.indexOfFirst { existing -> existing.id == collection.id }
    if (existingIndex == -1) return normalized + collection

    return normalized.toMutableList().apply {
        this[existingIndex] = collection
    }
}

sealed interface CollectionImportModelError {
    data class BlankCollectionId(val collectionIndex: Int) : CollectionImportModelError
    data class DuplicateCollectionId(val collectionId: String) : CollectionImportModelError
    data class BlankCollectionTitle(val collectionId: String) : CollectionImportModelError
    data class BlankFolderId(val folderIndex: Int, val collectionTitle: String) : CollectionImportModelError
    data class DuplicateFolderId(val folderId: String, val collectionTitle: String) : CollectionImportModelError
    data class BlankFolderTitle(val folderId: String, val collectionTitle: String) : CollectionImportModelError
    data class InvalidTraktListId(val sourceIndex: Int, val folderTitle: String) : CollectionImportModelError
    data class BlankSourceFields(val sourceIndex: Int, val folderTitle: String) : CollectionImportModelError
}

fun validateImportModel(collections: List<Collection>): CollectionImportModelError? {
    val collectionIds = mutableSetOf<String>()
    collections.forEachIndexed { ci, c ->
        if (c.id.isBlank()) {
            return CollectionImportModelError.BlankCollectionId(ci + 1)
        }
        if (!collectionIds.add(c.id)) {
            return CollectionImportModelError.DuplicateCollectionId(c.id)
        }
        if (c.title.isBlank()) {
            return CollectionImportModelError.BlankCollectionTitle(c.id)
        }

        val folderIds = mutableSetOf<String>()
        c.folders.forEachIndexed { fi, f ->
            if (f.id.isBlank()) {
                return CollectionImportModelError.BlankFolderId(fi + 1, c.title)
            }
            if (!folderIds.add(f.id)) {
                return CollectionImportModelError.DuplicateFolderId(f.id, c.title)
            }
            if (f.title.isBlank()) {
                return CollectionImportModelError.BlankFolderTitle(f.id, c.title)
            }
            f.resolvedSources.forEachIndexed { si, s ->
                if (s.hasInvalidTraktListId()) {
                    return CollectionImportModelError.InvalidTraktListId(si + 1, f.title)
                }

                val invalidAddon = !s.isTmdb && !s.isTrakt &&
                    (s.addonId.isNullOrBlank() || s.type.isNullOrBlank() || s.catalogId.isNullOrBlank())
                val invalidTmdb = s.isTmdb &&
                    s.tmdbSourceType.isNullOrBlank()
                if (invalidAddon || invalidTmdb) {
                    return CollectionImportModelError.BlankSourceFields(si + 1, f.title)
                }
            }
        }
    }
    return null
}

private fun CollectionImportModelError.localizedMessage(): String =
    runBlocking {
        when (this@localizedMessage) {
            is CollectionImportModelError.BlankCollectionId ->
                resourceString("Collection ${collectionIndex} has blank id.", StringKey.collections_import_error_collection_blank_id, collectionIndex)
            is CollectionImportModelError.DuplicateCollectionId ->
                resourceString("Collection id '${collectionId}' is used more than once.", StringKey.collections_import_error_collection_duplicate_id, collectionId)
            is CollectionImportModelError.BlankCollectionTitle ->
                resourceString("Collection '${collectionId}' has blank title.", StringKey.collections_import_error_collection_blank_title, collectionId)
            is CollectionImportModelError.BlankFolderId ->
                resourceString("Folder ${folderIndex} in '${collectionTitle}' has blank id.", StringKey.collections_import_error_folder_blank_id, folderIndex, collectionTitle)
            is CollectionImportModelError.DuplicateFolderId ->
                resourceString("Folder id '${folderId}' is used more than once in '${collectionTitle}'.", StringKey.collections_import_error_folder_duplicate_id, folderId, collectionTitle)
            is CollectionImportModelError.BlankFolderTitle ->
                resourceString("Folder '${folderId}' in '${collectionTitle}' has blank title.", StringKey.collections_import_error_folder_blank_title, folderId, collectionTitle)
            is CollectionImportModelError.InvalidTraktListId ->
                resourceString("Source ${sourceIndex} in folder '${folderTitle}' is missing a Trakt list ID.", StringKey.collections_import_error_trakt_list_id, sourceIndex, folderTitle)
            is CollectionImportModelError.BlankSourceFields ->
                resourceString("Source ${sourceIndex} in folder '${folderTitle}' has blank fields.", StringKey.collections_import_error_source_blank_fields, sourceIndex, folderTitle)
        }
    }
