package com.nuvio.app.features.home

import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.collection.Collection
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.collection.catalogRouteKey
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import co.touchlab.kermit.Logger
import kotlinx.atomicfu.atomic
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

data class HomeCatalogSettingsItem(
    val key: String,
    val defaultTitle: String,
    val addonName: String,
    val customTitle: String = "",
    val enabled: Boolean = true,
    val heroSourceEnabled: Boolean = true,
    val order: Int = 0,
    val isCollection: Boolean = false,
    val collectionId: String? = null,
    val isPinnedToTop: Boolean = false,
) {
    val displayTitle: String
        get() = customTitle.ifBlank { defaultTitle }
}

data class HomeCatalogSettingsUiState(
    val heroEnabled: Boolean = true,
    val showCatalogType: Boolean = true,
    val hideUnreleasedContent: Boolean = false,
    val hideCatalogUnderline: Boolean = false,
    /** UX-8: hide the whole Discover section on the Search screen (tvOS-authored, shared-namespace synced). */
    val hideDiscover: Boolean = false,
    val items: List<HomeCatalogSettingsItem> = emptyList(),
) {
    val signature: String
        get() = buildString {
            append(heroEnabled)
            append('|')
            append(showCatalogType)
            append('|')
            append(hideUnreleasedContent)
            append('|')
            append(hideCatalogUnderline)
            append('|')
            append(hideDiscover)
            append('|')
            append(
                items.joinToString(separator = "|") { item ->
                    "${item.key}:${item.order}:${item.enabled}:${item.heroSourceEnabled}:${item.customTitle}"
                }
            )
        }
}

data class HomeCatalogPreference(
    val customTitle: String,
    val enabled: Boolean,
    val heroSourceEnabled: Boolean,
    val order: Int,
)

data class HomeCatalogSettingsSnapshot(
    val heroEnabled: Boolean,
    val showCatalogType: Boolean,
    val hideUnreleasedContent: Boolean,
    val hideCatalogUnderline: Boolean,
    val hideDiscover: Boolean,
    val preferences: Map<String, HomeCatalogPreference>,
)

@Serializable
private data class StoredHomeCatalogPreference(
    val key: String,
    val customTitle: String = "",
    val enabled: Boolean = true,
    val heroSourceEnabled: Boolean = true,
    val order: Int = 0,
    /**
     * The owning addon's sync id, stamped at write time from the definition that produced this
     * entry ("" for collections and for records written before 2026-08-30). The drift-refill in
     * [HomeCatalogSettingsRepository.normalizePreferences] needs "is this orphaned key's addon
     * still present?", and the key alone cannot answer that: keys are "<addonId>:<type>:<catalogId>"
     * where BOTH the addon id and the catalog id may contain ':', so every prefix heuristic has a
     * collision (Codex 2026-08-30 rounds 3-4: loaded "foo" vs loading "foo:movie"). Exact id
     * comparison against the current definition set is unambiguous; "" fails closed (never counts
     * as a vanished selection). Local storage only — the sync payload has its own addon_id field.
     */
    val addonId: String = "",
)

@Serializable
private data class StoredHomeCatalogSettingsPayload(
    val heroEnabled: Boolean = true,
    val showCatalogType: Boolean = true,
    val hideUnreleasedContent: Boolean = false,
    val hideCatalogUnderline: Boolean = false,
    val hideDiscover: Boolean = false,
    val items: List<StoredHomeCatalogPreference> = emptyList(),
)

object HomeCatalogSettingsRepository {
    const val HERO_SOURCE_SELECTION_LIMIT = 2

    private val log = Logger.withTag("HomeCatalogSettingsRepository")

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val _uiState = MutableStateFlow(HomeCatalogSettingsUiState())
    val uiState: StateFlow<HomeCatalogSettingsUiState> = _uiState.asStateFlow()

    private var hasLoaded = false
    private var definitions: List<HomeCatalogDefinition> = emptyList()
    private var collectionDefinitions: List<CollectionCatalogDefinition> = emptyList()

    /**
     * Digest of the collection CONTENTS behind [collectionDefinitions]; see
     * [collectionsHeroContentSignature]. [HomeCatalogSettingsUiState.signature] deliberately covers
     * only what Home Rows shows (keys, order, enabled, hero flags, custom titles), so a collection
     * that keeps its id and its preferences while its folders change is invisible to it. That is
     * exactly the input `HomeRepository.ensureCollectionHeroFallback` keys its request on, so
     * [syncCollections] compares this alongside the ui signature. Internal, not private, so the
     * drift test can prove a content-only change moves it while the ui signature does not.
     */
    internal var collectionContentSignature: String = ""
        private set
    // Serializes every read-modify-write of the preferences map (CollectionRepository's
    // mutationLock precedent): the atomic reference makes reads safe, but two concurrent
    // whole-map reassignments (a sync pull vs a user reorder) would otherwise drop one side's
    // change wholesale. Reentrant — normalizePreferences() runs under callers' locks too.
    private val preferencesMutationLock = SynchronizedObject()
    private val preferencesRef = atomic<Map<String, StoredHomeCatalogPreference>>(emptyMap())
    private var preferences: Map<String, StoredHomeCatalogPreference>
        get() = preferencesRef.value
        set(value) {
            preferencesRef.value = value
        }
    private var heroEnabled = true

    /**
     * BUG-86 hero-off rows (beta.18): sim/device-diagnostics knob that makes THIS PROCESS read as a
     * "Show Hero" OFF profile without touching a byte of persisted or synced state.
     *
     * Set from tvOS's `-debug.homeHeroOff YES` launch argument (see `HomeHeroOffArgs`,
     * `HomeHeroCommit.swift`, honored only alongside `-debug.homeHeroProbe`). Deliberately NOT
     * [setHeroEnabled] `false`: that persists into the profile payload and pushes on the next sync,
     * so a diagnostic run would turn the hero off on the tester's real account and on every other
     * device it syncs to.
     *
     * Read by [snapshot] (the gate's own input) and by [publish] (the local UI state tvOS's
     * `HeroSettingsModel` watches, which is what actually activates the FEAT-15 focus panel), and
     * by NEITHER [persist] nor the sync payload — that asymmetry is the whole point.
     *
     * Plain `var`, no lock: written once from the main thread before the pipeline starts and never
     * again, and false in every build that has not been launched with the argument.
     */
    var debugForceHeroOff: Boolean = false

    /** [heroEnabled] as every LOCAL reader must see it. See [debugForceHeroOff]. */
    private val effectiveHeroEnabled: Boolean
        get() = heroEnabled && !debugForceHeroOff

    private var showCatalogType = true
    private var hideUnreleasedContent = false
    private var hideCatalogUnderline = false
    private var hideDiscover = false

    fun onProfileChanged() {
        hasLoaded = false
        synchronized(preferencesMutationLock) { preferences = emptyMap() }
        heroEnabled = true
        showCatalogType = true
        hideUnreleasedContent = false
        hideCatalogUnderline = false
        hideDiscover = false
        definitions = emptyList()
        collectionDefinitions = emptyList()
        collectionContentSignature = ""
        _uiState.value = HomeCatalogSettingsUiState()
    }

    fun clearLocalState() {
        hasLoaded = false
        definitions = emptyList()
        collectionDefinitions = emptyList()
        collectionContentSignature = ""
        synchronized(preferencesMutationLock) { preferences = emptyMap() }
        heroEnabled = true
        showCatalogType = true
        hideUnreleasedContent = false
        hideCatalogUnderline = false
        hideDiscover = false
        _uiState.value = HomeCatalogSettingsUiState()
    }

    fun syncCatalogs(addons: List<ManagedAddon>) {
        ensureLoaded()
        val incomingDefinitions = buildHomeCatalogDefinitions(addons)
        if (!shouldReplaceCatalogDefinitions(definitions.size, incomingDefinitions.size)) {
            // Deliberate tradeoff (Codex 2026-08-29, declined twice): yes, this also rejects the
            // one LEGITIMATE empty — the user removing/disabling their last addon mid-session,
            // whose dead rows then linger in Home Rows. But `definitions` is session-scoped
            // in-memory state: the very next launch starts empty and shows the true empty state,
            // while ACCEPTING empties here reopens the blank-pane clobber this guard exists for
            // (no caller can distinguish "last addon removed" from "manifests not fetched yet"
            // without new cross-layer plumbing). Stale-for-a-session beats blank-forever; profile
            // switches and wipes clear through onProfileChanged()/clearLocalState() as before.
            log.w { "syncCatalogs() — ignored an empty definition set; keeping ${definitions.size} known catalogs (transient addon emission must not blank Home Rows)" }
            return
        }
        definitions = incomingDefinitions
        collectionDefinitions = buildCollectionDefinitions(CollectionRepository.collections.value)
        if (definitions.isEmpty() && collectionDefinitions.isEmpty()) {
            publish()
            return
        }
        normalizePreferences()
        enforcePinnedCollectionsAtTop()
        publish()
        persist()
    }

    fun syncCollections(collections: List<Collection>) {
        ensureLoaded()
        // Same H3 no-op suppression as applyFromRemote(): a re-emission of the same collection set
        // (a sync pull that changes nothing, a redundant CollectionRepository fan-out) must not
        // re-trigger applyCurrentSettings()'s Home rebuild.
        //
        // Codex round 1 P2: the ui signature alone is too coarse a no-op test HERE. It carries the
        // collection's key, order, enabled and custom title, none of which move when a collection
        // keeps its id and its preferences while its FOLDERS change: renamed, reordered, a source
        // repointed, a hero backdrop or title logo swapped. Those are precisely the fields
        // `HomeRepository.ensureCollectionHeroFallback` builds its request key from, so suppressing
        // the fan-out on a content-only change left the previous collection-derived hero cached
        // until some unrelated refresh happened to re-key it. The contents digest is compared
        // alongside, and deliberately kept OUT of HomeCatalogSettingsUiState.signature: that
        // signature is row identity for the Home Rows settings screen and for
        // `HomeRepository.applyCurrentSettings`'s own idempotency key, and folder internals are not
        // part of either.
        val signatureBefore = _uiState.value.signature
        val contentSignatureBefore = collectionContentSignature
        collectionDefinitions = buildCollectionDefinitions(collections)
        collectionContentSignature = collectionsHeroContentSignature(collections)
        normalizePreferences()
        enforcePinnedCollectionsAtTop()
        publish()
        persist()
        if (_uiState.value.signature != signatureBefore ||
            collectionContentSignature != contentSignatureBefore
        ) {
            HomeRepository.applyCurrentSettings()
        }
    }

    fun snapshot(): HomeCatalogSettingsSnapshot {
        ensureLoaded()
        return HomeCatalogSettingsSnapshot(
            heroEnabled = effectiveHeroEnabled,
            showCatalogType = showCatalogType,
            hideUnreleasedContent = hideUnreleasedContent,
            hideCatalogUnderline = hideCatalogUnderline,
            hideDiscover = hideDiscover,
            preferences = preferences.mapValues { (_, value) ->
                HomeCatalogPreference(
                    customTitle = value.customTitle,
                    enabled = value.enabled,
                    heroSourceEnabled = value.heroSourceEnabled,
                    order = value.order,
                )
            },
        )
    }

    /**
     * The set of catalog keys currently selected as hero sources, from PERSISTED state alone.
     * Deliberately safe to call BEFORE [syncCatalogs] has run this session — it only reads
     * [preferences] (loaded via [ensureLoaded], which touches storage but never `definitions`) — so
     * a caller like K1's hero-commit gate can ask "which catalogs is the hero waiting on" before
     * the addon fan-in that populates [definitions] has completed.
     *
     * Primary: every stored preference with `heroSourceEnabled == true`, excluding `collection_`
     * keys (collections are never hero sources). This deliberately INCLUDES a key whose owning
     * addon's manifest is still loading — the caller needs "this key is selected but not yet
     * resolvable", not "this key doesn't exist".
     *
     * Fallback (NO catalog preference is stored at all: a fresh profile, or one that has never had
     * a hero selection): the first [HERO_SOURCE_SELECTION_LIMIT] catalog [definitions] known so far,
     * in display order, mirroring the default [normalizePreferences] would assign once it runs.
     * Returns empty when [definitions] are not known yet either; the caller is then expected to
     * wait for a subsequent [syncCatalogs] before deciding sources are "ready".
     *
     * An ALL-OFF selection (catalog preferences are stored and every one of them says
     * `heroSourceEnabled = false`) is NOT the fallback case and returns the empty set: the user
     * turned every hero source off, so answering with the first two definitions would tell K1's
     * gate to wait on catalogs that the hero pool excludes by construction. Callers that need to
     * tell an all-off selection apart from a not-yet-known one ask
     * [heroSourceSelectionIsAllOff].
     */
    fun heroSourceKeys(): Set<String> {
        ensureLoaded()
        val catalogPreferences = catalogPreferenceValues()
        val persisted = catalogPreferences
            .asSequence()
            .filter { it.heroSourceEnabled }
            .mapTo(linkedSetOf()) { it.key }
        if (persisted.isNotEmpty()) return persisted
        if (catalogPreferences.isNotEmpty()) return emptySet()
        return definitions.take(HERO_SOURCE_SELECTION_LIMIT).mapTo(linkedSetOf()) { it.key }
    }

    /**
     * True when this profile has stored catalog preferences and NONE of them is a hero source: the
     * deliberate all-off selection [normalizePreferences]'s drift-refill is careful never to
     * overwrite. K1's hero-commit gate needs it because an empty [heroSourceKeys] is otherwise
     * ambiguous: it also means "no selection is known yet", and those two want opposite answers
     * (release now vs. keep waiting).
     */
    fun heroSourceSelectionIsAllOff(): Boolean {
        ensureLoaded()
        val catalogPreferences = catalogPreferenceValues()
        return catalogPreferences.isNotEmpty() && catalogPreferences.none { it.heroSourceEnabled }
    }

    /** Stored preferences for CATALOGS only: collections are never hero sources (see `publish`). */
    private fun catalogPreferenceValues(): List<StoredHomeCatalogPreference> =
        preferences.values.filter { !it.key.startsWith("collection_") }

    fun setHeroEnabled(enabled: Boolean) {
        ensureLoaded()
        heroEnabled = enabled
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
    }

    fun setShowCatalogType(enabled: Boolean) {
        ensureLoaded()
        if (showCatalogType == enabled) return
        showCatalogType = enabled
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun setHideUnreleasedContent(enabled: Boolean) {
        ensureLoaded()
        if (hideUnreleasedContent == enabled) return
        hideUnreleasedContent = enabled
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun setHideCatalogUnderline(enabled: Boolean) {
        ensureLoaded()
        if (hideCatalogUnderline == enabled) return
        hideCatalogUnderline = enabled
        publish()
        persist()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    /** UX-8: hide the entire Discover section on the Search screen. Per-profile, synced (shared namespace). */
    fun setHideDiscover(enabled: Boolean) {
        ensureLoaded()
        if (hideDiscover == enabled) return
        hideDiscover = enabled
        publish()
        persist()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun setHeroSourceEnabled(key: String, enabled: Boolean) {
        ensureLoaded()
        val current = preferences[key] ?: defaultPreferenceForMissingKey(key) ?: return
        val updated = when {
            current.heroSourceEnabled == enabled -> current
            !enabled -> current.copy(heroSourceEnabled = false)
            // Rejected at the limit: nothing changes, so the hero must not reshuffle either.
            selectedHeroSourceCount(excludingKey = key) >= HERO_SOURCE_SELECTION_LIMIT -> current
            else -> current.copy(heroSourceEnabled = true)
        }
        if (updated == current) return
        // BUG-42: an ACCEPTED explicit Hero Sources change is the one thing that redraws the hero.
        // Reset, store, and republish as one unit so no load-scope publish can interleave.
        HomeRepository.resetHeroSelectionAround {
            synchronized(preferencesMutationLock) { preferences = preferences + (key to updated) }
            publish()
            persist()
            HomeRepository.applyCurrentSettings()
            // Deliberately local-only (no HomeCatalogSettingsSyncService.triggerPush()) — same as
            // the pushRemote = false this used to pass.
        }
    }

    fun setEnabled(key: String, enabled: Boolean) {
        updatePreference(key) { preference ->
            preference.copy(enabled = enabled)
        }
    }

    fun setCustomTitle(key: String, title: String) {
        updatePreference(key) { preference ->
            preference.copy(customTitle = title)
        }
    }

    fun resetToDefaults() {
        ensureLoaded()
        HomeRepository.resetHeroSelectionAround { // BUG-42: atomic with the mutation + republish
            heroEnabled = true
            showCatalogType = true
            hideUnreleasedContent = false
            hideCatalogUnderline = false
            hideDiscover = false
            synchronized(preferencesMutationLock) { preferences = emptyMap() }
            normalizePreferences()
            publish()
            persist()
            HomeRepository.applyCurrentSettings()
        }
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun moveUp(key: String) {
        move(key = key, direction = -1)
    }

    fun moveDown(key: String) {
        move(key = key, direction = 1)
    }

    fun moveByIndex(fromIndex: Int, toIndex: Int) {
        ensureLoaded()
        val allKeys = allOrderedKeys()
        if (allKeys.isEmpty()) return
        if (fromIndex !in allKeys.indices || toIndex !in allKeys.indices) return
        if (fromIndex == toIndex) return
        val orderedKeys = allKeys.toMutableList()
        orderedKeys.add(toIndex, orderedKeys.removeAt(fromIndex))
        synchronized(preferencesMutationLock) {
            val updatedPreferences = preferences.toMutableMap()
            orderedKeys.forEachIndexed { index, itemKey ->
                val current = updatedPreferences[itemKey] ?: return@forEachIndexed
                updatedPreferences[itemKey] = current.copy(order = index)
            }
            preferences = updatedPreferences
        }
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    private fun ensureLoaded() {
        if (hasLoaded) return
        hasLoaded = true

        val payload = HomeCatalogSettingsStorage.loadPayload().orEmpty().trim()
        if (payload.isEmpty()) return

        val parsedPayload = runCatching {
            json.decodeFromString<StoredHomeCatalogSettingsPayload>(payload)
        }.getOrNull()

        if (parsedPayload != null) {
            heroEnabled = parsedPayload.heroEnabled
            showCatalogType = parsedPayload.showCatalogType
            hideUnreleasedContent = parsedPayload.hideUnreleasedContent
            hideCatalogUnderline = parsedPayload.hideCatalogUnderline
            hideDiscover = parsedPayload.hideDiscover
            synchronized(preferencesMutationLock) { preferences = parsedPayload.items.associateBy { it.key } }
            publish()
            return
        }

        val legacyItems = runCatching {
            json.decodeFromString<List<StoredHomeCatalogPreference>>(payload)
        }.getOrDefault(emptyList())

        synchronized(preferencesMutationLock) { preferences = legacyItems.associateBy { it.key } }
        publish()
    }

    private fun normalizePreferences() = synchronized(preferencesMutationLock) {
        val current = preferences
        data class UnifiedEntry(val key: String, val isCollection: Boolean, val addonId: String)
        val catalogEntries = definitions.map { UnifiedEntry(it.key, false, it.addonIdForSync()) }
        val collectionEntries = collectionDefinitions.map { UnifiedEntry(it.key, true, "") }
        val allEntries = catalogEntries + collectionEntries
        val knownKeys = allEntries.mapTo(linkedSetOf(), UnifiedEntry::key)
        var nextOrder = (current.values.maxOfOrNull(StoredHomeCatalogPreference::order) ?: -1) + 1

        val orderedEntries = allEntries.mapIndexed { defaultIndex, entry ->
            Triple(
                entry,
                current[entry.key]?.order ?: (nextOrder + defaultIndex),
                defaultIndex,
            )
        }.sortedWith(
            compareBy<Triple<UnifiedEntry, Int, Int>>(
                { it.second },
                { it.third },
            ),
        ).map { it.first }

        val normalized = current
            .filterKeys { it !in knownKeys }
            .toMutableMap()

        // Two-pass cap (Hole D fix, 2026-09-04): a single positional walk let a REORDERED payload
        // (e.g. applyFromRemote rewriting every `order`) place a new/defaulted-true entry ahead of
        // an explicitly-selected one, so the cap consumed its slot before the walk ever reached the
        // real selection — evicting it in favour of a key nobody chose. Pass 1 claims cap slots for
        // entries the STORED preference explicitly marks heroSourceEnabled=true, in their relative
        // order; only once those are seated does pass 2 fill any remaining slots from entries with
        // no stored preference at all (which default to true), also in relative order. An entry
        // with an explicit stored `false` is never selected by either pass — unchanged from before.
        val selectedKeys = linkedSetOf<String>()
        orderedEntries.asSequence()
            .filterNot { it.isCollection }
            .filter { current[it.key]?.heroSourceEnabled == true }
            .forEach { entry ->
                if (selectedKeys.size < HERO_SOURCE_SELECTION_LIMIT) selectedKeys += entry.key
            }
        orderedEntries.asSequence()
            .filterNot { it.isCollection }
            .filter { current[it.key] == null }
            .forEach { entry ->
                if (selectedKeys.size < HERO_SOURCE_SELECTION_LIMIT) selectedKeys += entry.key
            }

        orderedEntries.forEach { entry ->
            val stored = current[entry.key]
            val heroSourceEnabled = !entry.isCollection && entry.key in selectedKeys
            normalized[entry.key] = StoredHomeCatalogPreference(
                key = entry.key,
                customTitle = stored?.customTitle.orEmpty(),
                enabled = stored?.enabled ?: true,
                heroSourceEnabled = heroSourceEnabled,
                order = stored?.order ?: nextOrder++,
                addonId = entry.addonId,
            )
        }

        // Drift-refill (bug reproduced live 2026-08-29/30): the loop above only auto-enables an
        // entry that has NO stored preference at all (`stored?.heroSourceEnabled ?: true`). On a
        // long-lived profile every beyond-the-cap entry already carries a stored
        // heroSourceEnabled=false — normalize itself wrote it there on an earlier pass — so if the
        // two previously-selected keys ever drop out of `definitions`/`collectionDefinitions` (an
        // addon manifest reshuffled catalog ids, or the addon was removed), every SURVIVING entry
        // is "stored=false" and the loop lands on zero enabled. There is no future pass where any
        // of those keys would organically regain stored=true — the selection is stranded empty
        // forever, and hero trailer location silently degrades along with it.
        //
        // Distinguish that DRIFT (a selection stranded on vanished keys) from a user who
        // deliberately turned every hero source off on catalogs that are still here, AND from an
        // addon that simply has not loaded yet. A key only counts as VANISHED when all three hold:
        // its stored preference says heroSourceEnabled=true, it no longer resolves to any
        // definition, and its stamped `addonId` matches an addon in the current definition set —
        // an EXACT id comparison, never a key-prefix heuristic: addon ids and catalog ids may both
        // contain ':', so every prefix parse of a key has a collision (Codex rounds 3-4). Records
        // stamped "" (pre-2026-08-30, or collections) fail closed and never count as vanished.
        // That last clause is what makes this safe under
        // incremental manifest loading (Codex 2026-08-30 P1): on a cold start the callers feed
        // syncCatalogs() only the addons whose manifests are READY, so the selection's addon can
        // be legitimately absent for a while — its keys are then "not known" but must not be
        // treated as gone, or an unlucky manifest completion order would reassign (and, worse,
        // consume) a perfectly valid selection on an ordinary launch. The price: a selection held
        // by an addon that was genuinely REMOVED stays stranded at zero rather than refilled —
        // but the Settings rows are reachable and honest about "0 of 2 selected", so the user can
        // recover manually, and no data is ever destroyed by guessing wrong.
        val presentAddonIds = definitions.mapTo(mutableSetOf()) { it.addonIdForSync() }
        val vanishedSelectionKeys = current.keys.filter { key ->
            val pref = current.getValue(key)
            pref.heroSourceEnabled &&
                key !in knownKeys &&
                pref.addonId.isNotEmpty() &&
                pref.addonId in presentAddonIds
        }
        if (vanishedSelectionKeys.isNotEmpty()) {
            var refilled = 0
            if (selectedKeys.isEmpty() && orderedEntries.any { !it.isCollection }) {
                orderedEntries.forEach { entry ->
                    if (refilled >= HERO_SOURCE_SELECTION_LIMIT) return@forEach
                    if (entry.isCollection) return@forEach
                    val existing = normalized[entry.key] ?: return@forEach
                    if (existing.heroSourceEnabled) return@forEach
                    normalized[entry.key] = existing.copy(heroSourceEnabled = true)
                    refilled += 1
                }
            }
            // Consume the drift signal unconditionally once the keys are PROVABLY stale — their
            // addon answered this sync and no longer offers them (Codex 2026-08-30 P2: consuming
            // only inside the refill branch left the markers alive whenever a newly-added catalog
            // had already defaulted a slot to true, and a user's later deliberate all-off was then
            // misclassified as drift on the next pass). The entry itself stays in the map
            // (order/customTitle survive), it just no longer votes as a stranded selection; if the
            // same catalog id ever returns it re-enters the ordinary cap logic like any other
            // entry with a stored preference.
            vanishedSelectionKeys.forEach { key ->
                normalized[key]?.let { pref ->
                    normalized[key] = pref.copy(heroSourceEnabled = false)
                }
            }
            log.i {
                "normalizePreferences() — hero-source selection keys ${vanishedSelectionKeys.size} " +
                    "vanished from their (still-present) addon's catalogs; refilled $refilled " +
                    "entr${if (refilled == 1) "y" else "ies"} in display order and consumed the markers"
            }
        }

        preferences = normalized.toMap()
    }

    private fun publish() {
        val collectionMap = collectionDefinitions.associateBy { it.key }
        val catalogItems = definitions
            .map { definition ->
                val preference = preferences[definition.key]
                HomeCatalogSettingsItem(
                    key = definition.key,
                    defaultTitle = definition.defaultTitle,
                    addonName = definition.addonName,
                    customTitle = preference?.customTitle.orEmpty(),
                    enabled = preference?.enabled ?: true,
                    heroSourceEnabled = preference?.heroSourceEnabled ?: true,
                    // BUG-12: unknown keys sort to the BACK, matching allOrderedKeys() — the two
                    // orderings must agree or moveByIndex() applies UI indices to the wrong rows.
                    order = preference?.order ?: Int.MAX_VALUE,
                )
            }

        val collectionItems = collectionDefinitions.map { colDef ->
            val preference = preferences[colDef.key]
            HomeCatalogSettingsItem(
                key = colDef.key,
                defaultTitle = colDef.title,
                addonName = colDef.subtitle,
                customTitle = preference?.customTitle.orEmpty(),
                enabled = preference?.enabled ?: true,
                heroSourceEnabled = false,
                order = preference?.order ?: Int.MAX_VALUE, // BUG-12: keep in sync with allOrderedKeys()
                isCollection = true,
                collectionId = colDef.collectionId,
                isPinnedToTop = colDef.isPinnedToTop,
            )
        }

        val items = (catalogItems + collectionItems)
            .sortedBy { it.order }

        _uiState.value = HomeCatalogSettingsUiState(
            // Local UI state only — never persisted, never pushed — so the diagnostics knob applies
            // here too. Without it tvOS's `HeroSettingsModel` (HomeView.swift), which reads
            // `snapshot()` once and then follows THIS flow, would flip the hero back on at the
            // first publish and the FEAT-15 focus panel the knob exists to exercise would never
            // appear. See [debugForceHeroOff].
            heroEnabled = effectiveHeroEnabled,
            showCatalogType = showCatalogType,
            hideUnreleasedContent = hideUnreleasedContent,
            hideCatalogUnderline = hideCatalogUnderline,
            hideDiscover = hideDiscover,
            items = items,
        )
    }

    private fun persist() {
        HomeCatalogSettingsStorage.savePayload(
            json.encodeToString(
                StoredHomeCatalogSettingsPayload(
                    heroEnabled = heroEnabled,
                    showCatalogType = showCatalogType,
                    hideUnreleasedContent = hideUnreleasedContent,
                    hideCatalogUnderline = hideCatalogUnderline,
                    hideDiscover = hideDiscover,
                    items = preferences.values.sortedBy { it.order },
                ),
            ),
        )
    }

    private fun updatePreference(
        key: String,
        pushRemote: Boolean = true,
        transform: (StoredHomeCatalogPreference) -> StoredHomeCatalogPreference,
    ) {
        ensureLoaded()
        val current = preferences[key] ?: defaultPreferenceForMissingKey(key) ?: return
        val updated = transform(current)
        if (updated == current) return
        synchronized(preferencesMutationLock) { preferences = preferences + (key to updated) }
        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        if (pushRemote) {
            HomeCatalogSettingsSyncService.triggerPush()
        }
    }

    private fun selectedHeroSourceCount(excludingKey: String? = null): Int {
        val catalogKeys = definitions.mapTo(mutableSetOf()) { it.key }
        return preferences.count { (itemKey, preference) ->
            itemKey != excludingKey && itemKey in catalogKeys && preference.heroSourceEnabled
        }
    }

    private fun move(
        key: String,
        direction: Int,
    ) {
        ensureLoaded()
        val orderedKeys = allOrderedKeys().toMutableList()
        if (orderedKeys.isEmpty()) return

        val currentIndex = orderedKeys.indexOf(key)
        if (currentIndex == -1) return

        val targetIndex = currentIndex + direction
        if (targetIndex !in orderedKeys.indices) return

        val movingKey = orderedKeys.removeAt(currentIndex)
        orderedKeys.add(targetIndex, movingKey)

        synchronized(preferencesMutationLock) {
            val updatedPreferences = preferences.toMutableMap()
            orderedKeys.forEachIndexed { index, itemKey ->
                val current = updatedPreferences[itemKey] ?: return@forEachIndexed
                updatedPreferences[itemKey] = current.copy(order = index)
            }
            preferences = updatedPreferences
        }

        publish()
        persist()
        HomeRepository.applyCurrentSettings()
        HomeCatalogSettingsSyncService.triggerPush()
    }

    fun exportToSyncPayload(): SyncHomeCatalogPayload {
        ensureLoaded()
        val catalogDefinitionsByKey = definitions.associateBy { it.key }
        val collectionDefinitionsByKey = collectionDefinitions.associateBy { it.key }
        val items = preferences.values.sortedBy { it.order }.map { pref ->
            val catalogDefinition = catalogDefinitionsByKey[pref.key]
            val collectionDefinition = collectionDefinitionsByKey[pref.key]
            val isCollection = collectionDefinition != null || pref.key.startsWith("collection_")
            if (isCollection) {
                SyncCatalogItem(
                    addonId = "",
                    type = "",
                    catalogId = "",
                    enabled = pref.enabled,
                    order = pref.order,
                    customTitle = pref.customTitle,
                    isCollection = true,
                    collectionId = collectionDefinition?.collectionId ?: pref.key.removePrefix("collection_"),
                    key = pref.key,
                )
            } else {
                val legacyParts = pref.key.split(':', limit = 3)
                SyncCatalogItem(
                    addonId = catalogDefinition?.addonIdForSync() ?: legacyParts.getOrElse(0) { "" },
                    type = catalogDefinition?.type ?: legacyParts.getOrElse(1) { "" },
                    catalogId = catalogDefinition?.catalogId ?: legacyParts.getOrElse(2) { "" },
                    enabled = pref.enabled,
                    order = pref.order,
                    customTitle = pref.customTitle,
                    isCollection = false,
                    key = pref.key,
                )
            }
        }
        return SyncHomeCatalogPayload(
            showCatalogType = showCatalogType,
            hideUnreleasedContent = hideUnreleasedContent,
            hideCatalogUnderline = hideCatalogUnderline,
            hideDiscover = hideDiscover,
            items = items,
        )
    }

    fun applyFromRemote(payload: SyncHomeCatalogPayload) {
        ensureLoaded()
        // H3 no-op suppression: a cloud pull that resolves to an IDENTICAL published state must
        // still persist (the remote copy stays the source of truth for reconciliation) but must
        // NOT re-run applyCurrentSettings() — that fan-out is what rebuilds Home's rows/hero on
        // tvOS, and an unconditional call on every pull (even a byte-identical one) is the doubled
        // hero's H3 delivery vehicle (see the plan's "hero commit protocol").
        val signatureBefore = _uiState.value.signature
        showCatalogType = payload.showCatalogType
        hideUnreleasedContent = payload.hideUnreleasedContent
        hideCatalogUnderline = payload.hideCatalogUnderline
        hideDiscover = payload.hideDiscover
        if (payload.items.isNotEmpty()) {
            synchronized(preferencesMutationLock) {
            val existingHeroState = preferences.mapValues { it.value.heroSourceEnabled }
            // Hole D: an unknown-locally remote key (not in existingHeroState) defaults to
            // heroSourceEnabled=true only while the local selection still has room. Once it
            // already holds HERO_SOURCE_SELECTION_LIMIT explicit-true entries, defaulting one more
            // key to true here would hand the reorder-cap walk in normalizePreferences() an extra
            // "stored true" contender it must then evict something to make room for — silently
            // displacing a real selection on every remote payload that introduces an unfamiliar key.
            //
            // The room is a BUDGET, spent as it is handed out (Codex round 2): comparing every
            // unknown key against the same starting count admitted all of them whenever a single
            // slot was free, so a payload carrying three unfamiliar keys ordered ahead of the one
            // real selection wrote four stored-true entries for a cap of two, and the two-pass walk
            // below (which cannot tell a remote-defaulted true from a user's own) then seated the
            // two unknowns that sorted first and dropped the selection the user actually made.
            // With the running counter the total never exceeds the cap, so pass 1 seats every
            // stored-true entry there is and has nothing to choose between.
            //
            // The budget is measured against the CURRENT locals, some of which this same call is
            // about to drop: a local key the payload also carries is overwritten by the remote
            // entry below, and one it does not carry survives only if `preservedPreferences` keeps
            // it. Either way its stored `true` was already counted here, so the budget can be
            // smaller than the room the post-merge map actually has. That bias is deliberate and it
            // is the safe direction: undercounting only means FEWER unfamiliar remote keys are
            // defaulted to true, which costs an unknown catalog a hero slot it was never promised.
            // Overcounting would do the thing this whole block exists to prevent, handing
            // normalizePreferences() more stored-true contenders than the cap and evicting a
            // selection the user actually made. Recomputing against the survivors would mean
            // building the merged map twice (the survivor set depends on `remoteKeys`, which
            // depends on this very mapValues), for a payload shape that has no user-visible upside.
            var remainingHeroSlots =
                (HERO_SOURCE_SELECTION_LIMIT - existingHeroState.values.count { it }).coerceAtLeast(0)
            // associateBy first, so a payload that repeats a key spends at most one slot on it
            // (last item wins, as `associate` did before).
            val remotePreferences = payload.items.associateBy { it.preferenceKey() }.mapValues { (key, item) ->
                val localHeroState = existingHeroState[key]
                val heroSourceEnabled = when {
                    localHeroState != null -> localHeroState
                    remainingHeroSlots > 0 -> {
                        remainingHeroSlots -= 1
                        true
                    }
                    else -> false
                }
                StoredHomeCatalogPreference(
                    key = key,
                    customTitle = item.customTitle,
                    enabled = item.enabled,
                    heroSourceEnabled = heroSourceEnabled,
                    order = item.order,
                    // Owner stamp: PRESERVE the local one, never adopt the remote's (Codex
                    // 2026-08-30 round 5 P2). The remote `addon_id` can come from the exporter's
                    // legacy `split(':', limit = 3)` fallback, which mis-splits colon-containing
                    // addon ids ("foo:sub:movie:c1" → "foo") — adopting it would overwrite an
                    // exact local stamp with an ambiguous one and reopen the false-vanished
                    // consumption this field exists to prevent. Keys the local definition set
                    // knows are re-stamped exactly by the normalizePreferences() call right below;
                    // unknown keys keep their prior exact stamp or fail closed at "".
                    addonId = preferences[key]?.addonId.orEmpty(),
                )
            }
            val remoteKeys = remotePreferences.keys
            val knownKeys = knownPreferenceKeys()
            val preservedPreferences = preferences.filterKeys { key ->
                key !in remoteKeys && (key in knownKeys || key.requiresExplicitSyncKey())
            }
            preferences = preservedPreferences + remotePreferences
            normalizePreferences()
            }
        }
        hasLoaded = true
        publish()
        persist()
        if (_uiState.value.signature != signatureBefore) {
            HomeRepository.applyCurrentSettings()
        }
    }

    private fun allOrderedKeys(): List<String> {
        val catalogKeys = definitions.map { it.key }
        val collectionKeys = collectionDefinitions.map { it.key }
        return (catalogKeys + collectionKeys)
            .sortedBy { key -> preferences[key]?.order ?: Int.MAX_VALUE }
    }

    private fun enforcePinnedCollectionsAtTop() {
        // BUG-12: never rewrite the GLOBAL order while the catalog half of the key space is
        // unknown (syncCatalogs not yet called this session — e.g. a client that reaches Home
        // before Settings). Reindexing from collections alone assigns them order 0..n, colliding
        // with the catalog preferences' existing 0..n, and persist() then makes the scramble
        // permanent (and pushes it to the account on the next preference write).
        if (definitions.isEmpty()) return
        val orderedKeys = allOrderedKeys()
        if (orderedKeys.isEmpty()) return

        val pinnedCollectionKeys = collectionDefinitions
            .asSequence()
            .filter { it.isPinnedToTop }
            .map { it.key }
            .toSet()
        if (pinnedCollectionKeys.isEmpty()) return

        val pinnedKeys = orderedKeys.filter { it in pinnedCollectionKeys }
        if (pinnedKeys.isEmpty()) return

        val nonPinnedKeys = orderedKeys.filterNot { it in pinnedCollectionKeys }
        val reorderedKeys = pinnedKeys + nonPinnedKeys
        if (reorderedKeys == orderedKeys) return

        synchronized(preferencesMutationLock) {
            val updatedPreferences = preferences.toMutableMap()
            reorderedKeys.forEachIndexed { index, itemKey ->
                val current = updatedPreferences[itemKey] ?: return@forEachIndexed
                updatedPreferences[itemKey] = current.copy(order = index)
            }
            preferences = updatedPreferences
        }
    }

    private fun defaultPreferenceForMissingKey(key: String): StoredHomeCatalogPreference? {
        val isCollection = collectionDefinitions.any { it.key == key }
        val isCatalog = definitions.any { it.key == key }
        if (!isCollection && !isCatalog) return null

        return StoredHomeCatalogPreference(
            key = key,
            enabled = true,
            heroSourceEnabled = isCatalog &&
                selectedHeroSourceCount(excludingKey = key) < HERO_SOURCE_SELECTION_LIMIT,
            order = _uiState.value.items.firstOrNull { it.key == key }?.order
                ?: ((preferences.values.maxOfOrNull { it.order } ?: -1) + 1),
            addonId = definitions.firstOrNull { it.key == key }?.addonIdForSync().orEmpty(),
        )
    }

    private fun knownPreferenceKeys(): Set<String> =
        definitions.mapTo(mutableSetOf()) { it.key }.also { keys ->
            keys.addAll(collectionDefinitions.map { it.key })
        }

    private fun HomeCatalogDefinition.addonIdForSync(): String {
        val suffix = ":$type:$catalogId"
        return key.removeSuffix(suffix)
    }

    private fun SyncCatalogItem.preferenceKey(): String =
        key.ifBlank {
            if (isCollection) {
                "collection_$collectionId"
            } else {
                "$addonId:$type:$catalogId"
            }
        }

    private fun String.requiresExplicitSyncKey(): Boolean =
        !startsWith("collection_") && count { it == ':' } > 2
}

internal data class CollectionCatalogDefinition(
    val key: String,
    val collectionId: String,
    val title: String,
    val subtitle: String,
    val isPinnedToTop: Boolean,
)

// Fork: public (upstream: internal) — composeApp tests consume cross-module.
fun visibleCollectionsWithUniqueIds(collections: List<Collection>): List<Collection> =
    collections
        .filter { collection -> collection.folders.isNotEmpty() }
        .distinctBy(Collection::id)

internal fun buildCollectionDefinitions(collections: List<Collection>): List<CollectionCatalogDefinition> =
    visibleCollectionsWithUniqueIds(collections).map { collection ->
        CollectionCatalogDefinition(
            key = "collection_${collection.id}",
            collectionId = collection.id,
            title = collection.title,
            subtitle = resourceString("${collection.folders.size} folder(s)", StringKey.collections_folder_count, collection.folders.size),
            isPinnedToTop = collection.pinToTop,
        )
    }

/**
 * Stable digest of everything about a collection set that Home reads but
 * [HomeCatalogSettingsUiState.signature] does not carry: the folders themselves, in order, with the
 * hero-relevant art and the resolved sources behind each one.
 *
 * Scoped to the collections that actually reach Home ([visibleCollectionsWithUniqueIds]) so a
 * hidden or duplicate collection cannot make an inert edit look like a change. Field choice is
 * driven by `HomeRepository.collectionHeroRequestKey` (collection id and order, folder ids, each
 * folder's `resolvedSources` route keys) plus the art the folder hero paints from
 * (`heroBackdropUrl`, `titleLogoUrl`, `coverImageUrl`, `heroVideoUrl`) and the titles Home renders.
 * Preference-side fields (order, enabled, custom title) are left out on purpose: those already move
 * the ui signature, and duplicating them here would only add churn.
 */
internal fun collectionsHeroContentSignature(collections: List<Collection>): String =
    visibleCollectionsWithUniqueIds(collections).joinToString(separator = ";") { collection ->
        val folders = collection.folders.joinToString(separator = ",") { folder ->
            val sources = folder.resolvedSources.joinToString(separator = "+") { source ->
                source.catalogRouteKey()
            }
            "${folder.id}~${folder.title}~${folder.coverImageUrl.orEmpty()}" +
                "~${folder.heroBackdropUrl.orEmpty()}~${folder.titleLogoUrl.orEmpty()}" +
                "~${folder.heroVideoUrl.orEmpty()}~${folder.tileShape}~[$sources]"
        }
        "${collection.id}~${collection.title}~${collection.backdropImageUrl.orEmpty()}" +
            "~${collection.pinToTop}~{$folders}"
    }

/// Whether an incoming syncCatalogs() definition set may replace the current one. A transient
/// EMPTY set (an addon emission whose manifests haven't loaded yet, a removal pass, a
/// mid-bootstrap snapshot) must never wipe a non-empty set — profile switches and account wipes
/// clear definitions through onProfileChanged()/clearLocalState(), never through syncCatalogs().
internal fun shouldReplaceCatalogDefinitions(currentCount: Int, incomingCount: Int): Boolean =
    incomingCount > 0 || currentCount == 0
