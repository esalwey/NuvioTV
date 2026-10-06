package com.nuvio.app.core.tracking

import com.nuvio.app.features.simkl.SimklAuthRepository
import com.nuvio.app.features.simkl.SimklLibraryRepository
import com.nuvio.app.features.simkl.SimklMutationRepository
import com.nuvio.app.features.simkl.SimklProgressRepository
import com.nuvio.app.features.simkl.SimklSyncRepository
import com.nuvio.app.features.simkl.SimklTrackingLibraryProvider
import com.nuvio.app.features.simkl.SimklTrackingProgressProvider
import com.nuvio.app.features.simkl.SimklWatchedSyncAdapter
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.trakt.TraktAuthRepository
import com.nuvio.app.features.trakt.TraktScrobbleRepository
import com.nuvio.app.features.trakt.TraktTrackingLibraryProvider
import com.nuvio.app.features.trakt.TraktTrackingProgressProvider
import com.nuvio.app.features.watching.sync.TraktWatchedSyncAdapter

/**
 * Registers every tracking provider this build ships into [TrackingProviderRegistry].
 *
 * Idempotent: the registry stores by provider id and the `object` touches below only force the
 * Kotlin object initializers (which self-register auth/profile-store/mutation ports) to run once.
 *
 * Mirrors upstream's bootstrap one-for-one: Trakt and Simkl. The Simkl property touches are the
 * upstream idiom for forcing the initializers — `SimklSyncRepository.state` runs
 * `TrackingProviderRegistry.registerProfileStore(this)`, `SimklMutationRepository.ensureRegistered()`
 * runs the list-writer / history-writer / scrobbler registrations, and `SimklAuthRepository.descriptor`
 * runs `TrackingProviderRegistry.register(this)`.
 */
fun ensureTrackingProvidersRegistered() {
    TraktAuthRepository.descriptor
    TraktScrobbleRepository.ensureRegistered()
    SimklAuthRepository.descriptor
    SimklSyncRepository.state
    SimklLibraryRepository.uiState
    SimklProgressRepository.uiState
    SimklMutationRepository.ensureRegistered()
    TrackingProviderRegistry.registerLibraryProvider(TraktTrackingLibraryProvider)
    TrackingProviderRegistry.registerLibraryProvider(SimklTrackingLibraryProvider)
    TrackingProviderRegistry.registerWatchedProvider(TraktWatchedSyncAdapter)
    TrackingProviderRegistry.registerWatchedProvider(SimklWatchedSyncAdapter)
    TrackingProviderRegistry.registerProgressProvider(TraktTrackingProgressProvider)
    TrackingProviderRegistry.registerProgressProvider(SimklTrackingProgressProvider)
}
