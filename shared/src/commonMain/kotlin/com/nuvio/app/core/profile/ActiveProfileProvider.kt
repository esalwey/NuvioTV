package com.nuvio.app.core.profile

import kotlin.concurrent.Volatile

/**
 * Compose-free seam giving the shared data layer the active profile id without importing
 * `features.profiles.ProfileRepository` (a top-of-graph god-object that would re-introduce a
 * dependency cycle). Mirrors the established `core.i18n.LocalizedStrings` /
 * `core.build.FeaturePolicyProvider` / `features.addons.AddonProfileProvider` injection pattern.
 *
 * The phone app installs a provider backed by `ProfileRepository` at startup; tvOS leaves the
 * default (single primary profile, id 1).
 */
fun interface ActiveProfileIdProvider {
    fun activeProfileId(): Int
}

object ActiveProfileProvider {
    @Volatile
    var provider: ActiveProfileIdProvider = ActiveProfileIdProvider { 1 }

    /** Current active profile id (profile index), via the installed provider. */
    val activeProfileId: Int get() = provider.activeProfileId()
}
