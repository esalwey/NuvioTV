package com.nuvio.app.core.build

// TrailerPlaybackMode now lives in :shared (com.nuvio.app.core.build, same package) so the
// shared FeaturePolicy seam can expose it; this expect/actual flavor object stays in composeApp.
expect object AppFeaturePolicy {
    val pluginsEnabled: Boolean
    val supportersContributorsPageEnabled: Boolean
    val accountDeletionEnabled: Boolean
    val personalMediaAddonCopyEnabled: Boolean
    val p2pEnabled: Boolean
    val trailerPlaybackMode: TrailerPlaybackMode
    val heroTrailerPlaybackSupported: Boolean
    val inAppUpdaterEnabled: Boolean
    val imdbRatingLogoEnabled: Boolean
    val customServerConnectionsEnabled: Boolean
}
