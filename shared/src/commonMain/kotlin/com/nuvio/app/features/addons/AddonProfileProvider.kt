package com.nuvio.app.features.addons

import kotlin.concurrent.Volatile

/**
 * Compose-free seam decoupling [AddonRepository] from the `features.profiles.ProfileRepository`
 * god-object (which transitively imports nearly every repository, including this one — a cycle).
 *
 * The addon layer only needs three primitives about the active profile, so it reads them through
 * this holder instead of importing `ProfileRepository` directly. The phone app installs an adapter
 * backed by `ProfileRepository` at startup; tvOS can install its own (or leave the default, which
 * behaves as "single primary profile").
 *
 * Mirrors the established [com.nuvio.app.core.i18n.LocalizedStrings] /
 * `core.build.FeaturePolicyProvider` injection pattern.
 */
interface AddonProfileContext {
    /** Active profile id (profile index). Defaults to the primary profile (1). */
    val activeProfileId: Int

    /** Active profile's index, or `null` when no profile is selected. */
    val activeProfileIndex: Int?

    /** Whether the active profile is configured to use the primary profile's addons. */
    val usesPrimaryAddons: Boolean
}

/** Default context: a single primary profile, no secondary-profile addon sharing. */
object DefaultAddonProfileContext : AddonProfileContext {
    override val activeProfileId: Int = 1
    override val activeProfileIndex: Int? = 1
    override val usesPrimaryAddons: Boolean = false
}

/** Process-wide holder for the active [AddonProfileContext]. */
object AddonProfileProvider {
    @Volatile
    var context: AddonProfileContext = DefaultAddonProfileContext
}
