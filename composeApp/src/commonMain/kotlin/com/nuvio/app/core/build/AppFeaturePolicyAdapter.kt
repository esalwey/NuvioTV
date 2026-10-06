package com.nuvio.app.core.build

/**
 * Bridges composeApp's flavor-specific [AppFeaturePolicy] (an `expect object` with actuals in
 * the iosFull/iosAppStore/androidFull/androidPlaystore/desktop source sets) to the shared
 * [FeaturePolicy] seam, so the migrated data layer reads the phone app's real flags. Install
 * once at startup via [install]. Using an adapter (rather than `AppFeaturePolicy : FeaturePolicy`)
 * keeps the five flavor `actual` files untouched.
 */
object AppFeaturePolicyAdapter : FeaturePolicy {
    override val pluginsEnabled: Boolean get() = AppFeaturePolicy.pluginsEnabled
    override val supportersContributorsPageEnabled: Boolean get() = AppFeaturePolicy.supportersContributorsPageEnabled
    override val accountDeletionEnabled: Boolean get() = AppFeaturePolicy.accountDeletionEnabled
    override val personalMediaAddonCopyEnabled: Boolean get() = AppFeaturePolicy.personalMediaAddonCopyEnabled
    override val p2pEnabled: Boolean get() = AppFeaturePolicy.p2pEnabled
    override val trailerPlaybackMode: TrailerPlaybackMode get() = AppFeaturePolicy.trailerPlaybackMode
    override val heroTrailerPlaybackSupported: Boolean get() = AppFeaturePolicy.heroTrailerPlaybackSupported
    override val inAppUpdaterEnabled: Boolean get() = AppFeaturePolicy.inAppUpdaterEnabled
    override val imdbRatingLogoEnabled: Boolean get() = AppFeaturePolicy.imdbRatingLogoEnabled
    override val customServerConnectionsEnabled: Boolean get() = AppFeaturePolicy.customServerConnectionsEnabled

    /** Register this adapter as the process-wide feature policy. Idempotent. */
    fun install() {
        FeaturePolicyProvider.policy = this
    }
}
