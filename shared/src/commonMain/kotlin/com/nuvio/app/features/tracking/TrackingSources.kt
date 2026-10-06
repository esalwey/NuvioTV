package com.nuvio.app.features.tracking

import com.nuvio.app.features.library.LibrarySourceMode
import kotlinx.serialization.Serializable

/**
 * Which backend owns "continue watching" / watched history for the active profile.
 *
 * Entry names and order match upstream (`TRAKT, SIMKL, NUVIO_SYNC`) so persisted preferences
 * round-trip identically — [fromStorage] and the `@Serializable` encoding are both name-based.
 */
@Serializable
enum class WatchProgressSource {
    TRAKT,
    SIMKL,
    NUVIO_SYNC;

    val providerId: TrackingProviderId?
        get() = when (this) {
            TRAKT -> TrackingProviderId.TRAKT
            SIMKL -> TrackingProviderId.SIMKL
            NUVIO_SYNC -> null
        }

    companion object {
        fun fromStorage(value: String?): WatchProgressSource =
            entries.firstOrNull { it.name == value } ?: DEFAULT_WATCH_PROGRESS_SOURCE
    }
}

val DEFAULT_WATCH_PROGRESS_SOURCE: WatchProgressSource = WatchProgressSource.TRAKT
val DEFAULT_LIBRARY_SOURCE_MODE: LibrarySourceMode = LibrarySourceMode.TRAKT

fun librarySourceModeFromStorage(value: String?): LibrarySourceMode =
    LibrarySourceMode.entries.firstOrNull { it.name == value } ?: DEFAULT_LIBRARY_SOURCE_MODE

val LibrarySourceMode.providerId: TrackingProviderId?
    get() = when (this) {
        LibrarySourceMode.LOCAL -> null
        LibrarySourceMode.TRAKT -> TrackingProviderId.TRAKT
        LibrarySourceMode.SIMKL -> TrackingProviderId.SIMKL
    }

fun effectiveWatchProgressSource(
    requestedSource: WatchProgressSource,
    isProviderAuthenticated: (TrackingProviderId) -> Boolean,
): WatchProgressSource {
    val providerId = requestedSource.providerId ?: return WatchProgressSource.NUVIO_SYNC
    return requestedSource.takeIf { isProviderAuthenticated(providerId) }
        ?: WatchProgressSource.NUVIO_SYNC
}

fun effectiveLibrarySourceMode(
    requestedSource: LibrarySourceMode,
    isProviderAuthenticated: (TrackingProviderId) -> Boolean,
): LibrarySourceMode {
    val providerId = requestedSource.providerId ?: return LibrarySourceMode.LOCAL
    return requestedSource.takeIf { isProviderAuthenticated(providerId) }
        ?: LibrarySourceMode.LOCAL
}
