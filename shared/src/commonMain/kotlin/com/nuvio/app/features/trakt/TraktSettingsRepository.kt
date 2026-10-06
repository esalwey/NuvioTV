package com.nuvio.app.features.trakt

import com.nuvio.app.features.library.LibrarySourceMode
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.simkl.DEFAULT_SIMKL_ANIME_ID_PREFERENCE
import com.nuvio.app.features.simkl.SimklAnimeIdPreference
import com.nuvio.app.features.tracking.TrackingSourceSelection
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

const val TRAKT_CONTINUE_WATCHING_DAYS_CAP_ALL = 0
const val TRAKT_DEFAULT_CONTINUE_WATCHING_DAYS_CAP = 60
const val TRAKT_MIN_CONTINUE_WATCHING_DAYS_CAP = 7
const val TRAKT_MAX_CONTINUE_WATCHING_DAYS_CAP = 365

val TraktContinueWatchingDaysOptions: List<Int> = listOf(
    14,
    30,
    TRAKT_DEFAULT_CONTINUE_WATCHING_DAYS_CAP,
    90,
    180,
    TRAKT_MAX_CONTINUE_WATCHING_DAYS_CAP,
    TRAKT_CONTINUE_WATCHING_DAYS_CAP_ALL,
)

// The watch-progress source enum now lives in `features/tracking` (provider-neutral). These
// aliases/delegates keep every existing `com.nuvio.app.features.trakt.*` import — shared code,
// composeApp screens, and the composeApp test suite — compiling unchanged.
typealias WatchProgressSource = com.nuvio.app.features.tracking.WatchProgressSource

val DEFAULT_WATCH_PROGRESS_SOURCE: WatchProgressSource =
    com.nuvio.app.features.tracking.DEFAULT_WATCH_PROGRESS_SOURCE
val DEFAULT_LIBRARY_SOURCE_MODE: LibrarySourceMode =
    com.nuvio.app.features.tracking.DEFAULT_LIBRARY_SOURCE_MODE

fun librarySourceModeFromStorage(value: String?): LibrarySourceMode =
    com.nuvio.app.features.tracking.librarySourceModeFromStorage(value)

@Serializable
enum class MoreLikeThisSourcePreference {
    TRAKT,
    TMDB;

    companion object {
        fun fromStorage(value: String?): MoreLikeThisSourcePreference =
            entries.firstOrNull { it.name == value } ?: DEFAULT_MORE_LIKE_THIS_SOURCE
    }
}

val DEFAULT_MORE_LIKE_THIS_SOURCE: MoreLikeThisSourcePreference = MoreLikeThisSourcePreference.TRAKT

data class TraktSettingsUiState(
    val watchProgressSource: WatchProgressSource = DEFAULT_WATCH_PROGRESS_SOURCE,
    val continueWatchingDaysCap: Int = TRAKT_DEFAULT_CONTINUE_WATCHING_DAYS_CAP,
    val librarySourceMode: LibrarySourceMode = DEFAULT_LIBRARY_SOURCE_MODE,
    val moreLikeThisSource: MoreLikeThisSourcePreference = DEFAULT_MORE_LIKE_THIS_SOURCE,
    val simklAnimeIdPreference: SimklAnimeIdPreference = DEFAULT_SIMKL_ANIME_ID_PREFERENCE,
)

@Serializable
private data class StoredTraktSettings(
    val watchProgressSource: String? = null,
    val continueWatchingDaysCap: Int = TRAKT_DEFAULT_CONTINUE_WATCHING_DAYS_CAP,
    val librarySourceMode: String? = null,
    val moreLikeThisSource: String? = null,
    val simklAnimeIdPreference: String? = null,
)

object TraktSettingsRepository {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val _uiState = MutableStateFlow(TraktSettingsUiState())

    // BUG-75: session-scoped, per-profile record of *user* edits to the three synced
    // tracking-source fields. TrackingSourceSettingsSyncService reads it to tell a real edit
    // apart from a profile-switch reload or a remote apply, both of which also emit through
    // uiState — keyed by profile so one profile's edit can never lend provenance to another
    // profile's reload emission. The count and the edit's resulting selection live in ONE atomic
    // value: updated separately, a concurrent pull could observe the bumped count with the
    // previous selection and reconcile the new edit against a value that was never pushed. The
    // selection is kept because the ordered sync's ProfileSettings step can overwrite live state
    // with an older platform blob after the edit — pushing "current selection" for an
    // unreconciled edit would push the stale platform value. Only ever read count-guarded.
    internal data class UserTrackingEdit(
        val count: Int,
        val selection: TrackingSourceSelection,
    )

    private val userTrackingEdits = atomic(mapOf<Int, UserTrackingEdit>())

    /** Read the record ONCE and use its paired count+selection — two separate reads can pair a
     *  newer count with an older selection and reconcile an edit that was never pushed. */
    internal fun lastUserTrackingEdit(profileId: Int): UserTrackingEdit? =
        userTrackingEdits.value[profileId]
    internal fun userTrackingEditCount(profileId: Int): Int = lastUserTrackingEdit(profileId)?.count ?: 0

    private fun recordUserTrackingEdit(next: TraktSettingsUiState) {
        // Attribution deliberately follows the ACTIVE profile — persist() below writes to the
        // active profile's storage, so provenance must track where the write actually lands.
        val profileId = ProfileRepository.activeProfileId
        val selection = TrackingSourceSelection(
            watchProgressSource = next.watchProgressSource,
            librarySourceMode = next.librarySourceMode,
            continueWatchingDaysCap = next.continueWatchingDaysCap,
        )
        userTrackingEdits.value = userTrackingEdits.value.let {
            it + (profileId to UserTrackingEdit(count = (it[profileId]?.count ?: 0) + 1, selection = selection))
        }
    }
    val uiState: StateFlow<TraktSettingsUiState> = _uiState.asStateFlow()

    private var hasLoaded = false

    fun ensureLoaded() {
        if (hasLoaded) return
        loadFromDisk()
    }

    fun onProfileChanged() {
        loadFromDisk()
    }

    fun clearLocalState() {
        hasLoaded = false
        _uiState.value = TraktSettingsUiState()
        // Account-scoped: profile ids repeat across accounts, and a count surviving the wipe
        // would read as a user edit for the next account's same-numbered profile.
        userTrackingEdits.value = emptyMap()
    }

    // `profileId` is unused since the pending-change outbox was removed (BUG-75: the shared sync
    // namespace publishes the choice instead); the parameter stays for the existing call sites.
    internal fun setWatchProgressSource(
        source: WatchProgressSource,
        @Suppress("UNUSED_PARAMETER") profileId: Int = ProfileRepository.activeProfileId,
    ) {
        ensureLoaded()
        if (_uiState.value.watchProgressSource == source) return
        val nextState = _uiState.value.copy(watchProgressSource = source)
        recordUserTrackingEdit(nextState)
        persist(nextState)
        _uiState.value = nextState
    }

    /**
     * BUG-75: applies the tracking source selection pulled from the shared sync namespace. Writes
     * nothing else — no outbox, no push — so the pull can never echo back as a local edit.
     */
    internal fun applyFromRemoteSync(
        watchProgressSource: WatchProgressSource?,
        librarySourceMode: LibrarySourceMode?,
        continueWatchingDaysCap: Int?,
    ) {
        ensureLoaded()
        val current = _uiState.value
        val nextState = current.copy(
            watchProgressSource = watchProgressSource ?: current.watchProgressSource,
            librarySourceMode = librarySourceMode ?: current.librarySourceMode,
            continueWatchingDaysCap = continueWatchingDaysCap
                ?.let { normalizeTraktContinueWatchingDaysCap(it) }
                ?: current.continueWatchingDaysCap,
        )
        if (nextState == current) return
        persist(nextState)
        _uiState.value = nextState
    }

    fun setContinueWatchingDaysCap(days: Int) {
        ensureLoaded()
        val normalized = normalizeTraktContinueWatchingDaysCap(days)
        if (_uiState.value.continueWatchingDaysCap == normalized) return
        val nextState = _uiState.value.copy(continueWatchingDaysCap = normalized)
        recordUserTrackingEdit(nextState)
        _uiState.value = nextState
        persist()
    }

    fun setLibrarySourceMode(mode: LibrarySourceMode) {
        ensureLoaded()
        if (_uiState.value.librarySourceMode == mode) return
        val nextState = _uiState.value.copy(librarySourceMode = mode)
        recordUserTrackingEdit(nextState)
        _uiState.value = nextState
        persist()
    }

    fun setMoreLikeThisSource(source: MoreLikeThisSourcePreference) {
        ensureLoaded()
        if (_uiState.value.moreLikeThisSource == source) return
        _uiState.value = _uiState.value.copy(moreLikeThisSource = source)
        persist()
    }

    fun setSimklAnimeIdPreference(preference: SimklAnimeIdPreference) {
        ensureLoaded()
        if (_uiState.value.simklAnimeIdPreference == preference) return
        _uiState.value = _uiState.value.copy(simklAnimeIdPreference = preference)
        persist()
        // The canonical-id choice feeds SimklProjections, so cached projections are now stale.
        com.nuvio.app.features.simkl.SimklSyncRepository.invalidateProjections()
    }

    private fun loadFromDisk() {
        hasLoaded = true

        val payload = TraktSettingsStorage.loadPayload().orEmpty().trim()
        if (payload.isEmpty()) {
            _uiState.value = TraktSettingsUiState()
            return
        }

        val stored = runCatching {
            json.decodeFromString<StoredTraktSettings>(payload)
        }.getOrNull()

        _uiState.value = if (stored != null) {
            TraktSettingsUiState(
                watchProgressSource = WatchProgressSource.fromStorage(stored.watchProgressSource),
                continueWatchingDaysCap = normalizeTraktContinueWatchingDaysCap(stored.continueWatchingDaysCap),
                librarySourceMode = librarySourceModeFromStorage(stored.librarySourceMode),
                moreLikeThisSource = MoreLikeThisSourcePreference.fromStorage(stored.moreLikeThisSource),
                simklAnimeIdPreference = SimklAnimeIdPreference.fromStorage(stored.simklAnimeIdPreference),
            )
        } else {
            TraktSettingsUiState()
        }
    }

    private fun persist(state: TraktSettingsUiState = _uiState.value) {
        TraktSettingsStorage.savePayload(
            json.encodeToString(
                StoredTraktSettings(
                    watchProgressSource = state.watchProgressSource.name,
                    continueWatchingDaysCap = state.continueWatchingDaysCap,
                    librarySourceMode = state.librarySourceMode.name,
                    moreLikeThisSource = state.moreLikeThisSource.name,
                    simklAnimeIdPreference = state.simklAnimeIdPreference.name,
                ),
            ),
        )
    }
}

fun normalizeTraktContinueWatchingDaysCap(days: Int): Int =
    if (days == TRAKT_CONTINUE_WATCHING_DAYS_CAP_ALL) {
        TRAKT_CONTINUE_WATCHING_DAYS_CAP_ALL
    } else {
        days.coerceIn(TRAKT_MIN_CONTINUE_WATCHING_DAYS_CAP, TRAKT_MAX_CONTINUE_WATCHING_DAYS_CAP)
    }

// ── Trakt-shaped source resolvers ────────────────────────────────────────────
// Kept as thin delegates over the provider-neutral `features/tracking` functions. The sync spine
// now calls the tracking versions; these remain because fork-only callers (composeApp screens,
// composeApp's WatchedModelsTest/HomeScreenTest, and `shouldUseTraktLibrary` below) still take the
// Trakt-shaped `isAuthenticated` boolean.

fun shouldUseTraktProgress(
    isAuthenticated: Boolean,
    source: WatchProgressSource,
): Boolean = effectiveWatchProgressSource(
    isTraktAuthenticated = isAuthenticated,
    requestedSource = source,
) == WatchProgressSource.TRAKT

fun effectiveWatchProgressSource(
    isTraktAuthenticated: Boolean,
    requestedSource: WatchProgressSource,
): WatchProgressSource = com.nuvio.app.features.tracking.effectiveWatchProgressSource(
    requestedSource = requestedSource,
    isProviderAuthenticated = { providerId ->
        providerId == com.nuvio.app.features.tracking.TrackingProviderId.TRAKT && isTraktAuthenticated
    },
)

fun effectiveLibrarySourceMode(
    isAuthenticated: Boolean,
    source: LibrarySourceMode,
): LibrarySourceMode = com.nuvio.app.features.tracking.effectiveLibrarySourceMode(
    requestedSource = source,
    isProviderAuthenticated = { providerId ->
        providerId == com.nuvio.app.features.tracking.TrackingProviderId.TRAKT && isAuthenticated
    },
)

fun shouldUseTraktLibrary(
    isAuthenticated: Boolean,
    source: LibrarySourceMode,
): Boolean = effectiveLibrarySourceMode(isAuthenticated, source) == LibrarySourceMode.TRAKT

fun shouldUseTraktMoreLikeThis(
    isAuthenticated: Boolean,
    source: MoreLikeThisSourcePreference,
): Boolean = isAuthenticated && source == MoreLikeThisSourcePreference.TRAKT
