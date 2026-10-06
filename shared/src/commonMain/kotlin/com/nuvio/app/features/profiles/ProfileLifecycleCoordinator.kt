package com.nuvio.app.features.profiles

/**
 * Seam that lets the shared (UI-free) [ProfileRepository] fan out profile-lifecycle events
 * to the ~24 feature repositories — most of which still live in composeApp — without
 * ProfileRepository importing them (which would re-introduce the god-object dependency knot
 * and block its move to :shared).
 *
 * composeApp installs an adapter at startup that holds the exact, ordered fan-out. A target
 * with no adapter installed (e.g. tvOS today) gets the no-op default.
 */
interface ProfileLifecycleCoordinator {
    /** Active profile switched to [profileIndex] — refresh every profile-scoped repository. */
    fun onProfileSelected(profileIndex: Int)

    /** Cached profiles were loaded from disk before any network pull. */
    fun onProfilesCached()
}

object ProfileLifecycleProvider {
    var coordinator: ProfileLifecycleCoordinator = object : ProfileLifecycleCoordinator {
        override fun onProfileSelected(profileIndex: Int) {}
        override fun onProfilesCached() {}
    }
}
