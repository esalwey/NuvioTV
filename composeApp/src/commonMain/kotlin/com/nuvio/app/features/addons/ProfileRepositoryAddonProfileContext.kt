package com.nuvio.app.features.addons

import com.nuvio.app.features.profiles.ProfileRepository

/**
 * Bridges composeApp's [ProfileRepository] to the shared [AddonProfileContext] seam, so the
 * migrated [AddonRepository] reads the phone app's real active-profile state without importing
 * `ProfileRepository` directly (which would re-introduce the dependency cycle the seam exists to
 * break). Install once at startup via [install]. Mirrors `core.build.AppFeaturePolicyAdapter`.
 */
object ProfileRepositoryAddonProfileContext : AddonProfileContext {
    override val activeProfileId: Int
        get() = ProfileRepository.activeProfileId
    override val activeProfileIndex: Int?
        get() = ProfileRepository.state.value.activeProfile?.profileIndex
    override val usesPrimaryAddons: Boolean
        get() = ProfileRepository.state.value.activeProfile?.usesPrimaryAddons == true

    /** Register this adapter as the process-wide addon profile context. Idempotent. */
    fun install() {
        AddonProfileProvider.context = this
    }
}
