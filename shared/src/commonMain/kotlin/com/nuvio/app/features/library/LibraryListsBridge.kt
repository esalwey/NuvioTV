package com.nuvio.app.features.library

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.tracking.LibraryListPrivacy
import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingLibraryTabKind
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.providerId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.launch

/**
 * What the "manage lists" screen needs about the library being shown: the user's own lists in the
 * provider's order and what the provider lets them do with those.
 */
data class LibraryListManagementInfo(
    val source: LibrarySourceMode,
    val providerName: String,
    val lists: List<TrackingLibraryTab>,
    val privacyOptions: List<LibraryListPrivacy>,
    val supportsDescription: Boolean,
    val supportsReordering: Boolean,
)

/** Swift-facing entry point of library list management (see [LibraryListManagementController]). */
object LibraryListsBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("LibraryListsBridge"))
    private val mutableInfo = MutableStateFlow<LibraryListManagementInfo?>(null)

    /** Null while the active library has no user-managed lists (the local library, Simkl). */
    val managementInfo: StateFlow<LibraryListManagementInfo?> = mutableInfo.asStateFlow()

    init {
        scope.launch {
            ensureTrackingProvidersRegistered()
            val triggers: List<Flow<Unit>> = buildList {
                add(LibraryRepository.uiState.map { })
                add(TrackingProviderRegistry.connectedProviderIds.map { })
                TrackingProviderRegistry.libraryProviders().forEach { provider -> add(provider.changes) }
            }
            merge(*triggers.toTypedArray())
                .onStart { emit(Unit) }
                .collect { mutableInfo.value = currentInfo() }
        }
    }

    /** A controller bound to the active library; one per screen that edits lists. */
    fun makeController(): LibraryListManagementController =
        LibraryListManagementController(LibraryRepository::listManagementContext, LibraryRepository::listManager)

    /** Persists [orderedKeys], the complete new order of the user's own lists. */
    @Throws(Throwable::class)
    suspend fun reorder(orderedKeys: List<String>) {
        val context = checkNotNull(LibraryRepository.listManagementContext()) { "This library has no lists to reorder" }
        LibraryRepository.listManager(context).reorderLists(orderedKeys)
    }

    private fun currentInfo(): LibraryListManagementInfo? {
        val context = LibraryRepository.listManagementContext() ?: return null
        val providerId = context.source.providerId ?: return null
        val provider = TrackingProviderRegistry.libraryProvider(providerId) ?: return null
        val manager = provider.listManager ?: return null
        return LibraryListManagementInfo(
            source = context.source,
            providerName = trackingProviderDisplayName(providerId),
            lists = provider.snapshot().tabs.filter { tab -> tab.kind == TrackingLibraryTabKind.PERSONAL },
            privacyOptions = manager.capabilities.privacyOptions,
            supportsDescription = manager.capabilities.supportsDescription,
            supportsReordering = manager.capabilities.supportsReordering,
        )
    }
}
