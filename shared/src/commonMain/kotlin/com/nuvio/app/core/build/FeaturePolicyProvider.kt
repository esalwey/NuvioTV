package com.nuvio.app.core.build

import kotlin.concurrent.Volatile

/**
 * How trailers play. Lives in :shared (same `com.nuvio.app.core.build` package) so the [FeaturePolicy]
 * seam can expose it; composeApp's flavor `AppFeaturePolicy` returns one of these values.
 */
enum class TrailerPlaybackMode {
    IN_APP,
    EXTERNAL,
}

/**
 * UI-free seam for the phone app's build-flavor feature flags, read by the migrated data layer.
 *
 * composeApp installs a real implementation (`AppFeaturePolicyAdapter`, which delegates to the
 * flavor-specific `expect object AppFeaturePolicy`) at startup via `FeaturePolicyProvider.policy = …`.
 * Frontends that don't install one (e.g. the tvOS app) fall back to [DefaultFeaturePolicy].
 */
interface FeaturePolicy {
    val pluginsEnabled: Boolean
    val supportersContributorsPageEnabled: Boolean
    val accountDeletionEnabled: Boolean
    val personalMediaAddonCopyEnabled: Boolean
    val p2pEnabled: Boolean
    val trailerPlaybackMode: TrailerPlaybackMode
    val heroTrailerPlaybackSupported: Boolean
    val inAppUpdaterEnabled: Boolean
    val imdbRatingLogoEnabled: Boolean

    /**
     * Whether the user may point the app at a self-hosted backend (`/.well-known/nuvio` discovery,
     * see `core.network.ServerConfigurationRepository`). tvOS flips it on in
     * `installTvOsSharedProviders`; composeApp feeds it from the flavor `AppFeaturePolicy` via
     * `AppFeaturePolicyAdapter` (full flavors true, store flavors false — mirrors upstream).
     */
    val customServerConnectionsEnabled: Boolean
}

/**
 * Conservative defaults used until a frontend installs its own policy. The tvOS app relies on these:
 * addon/debrid streams (no local plugins or P2P), no in-app updater/trailer/store-only features.
 */
object DefaultFeaturePolicy : FeaturePolicy {
    override val pluginsEnabled: Boolean = false
    override val supportersContributorsPageEnabled: Boolean = false
    override val accountDeletionEnabled: Boolean = false
    override val personalMediaAddonCopyEnabled: Boolean = false
    override val p2pEnabled: Boolean = false
    override val trailerPlaybackMode: TrailerPlaybackMode = TrailerPlaybackMode.EXTERNAL
    override val heroTrailerPlaybackSupported: Boolean = false
    override val inAppUpdaterEnabled: Boolean = false
    override val imdbRatingLogoEnabled: Boolean = false
    override val customServerConnectionsEnabled: Boolean = false
}

/** Process-wide holder for the active [FeaturePolicy]; defaults to [DefaultFeaturePolicy]. */
object FeaturePolicyProvider {
    @Volatile
    var policy: FeaturePolicy = DefaultFeaturePolicy
}
