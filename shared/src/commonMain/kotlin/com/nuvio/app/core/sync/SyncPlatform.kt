package com.nuvio.app.core.sync

import kotlin.concurrent.Volatile

const val MOBILE_SYNC_PLATFORM = "mobile"
const val TV_SYNC_PLATFORM = "tv"

/**
 * BUG-20: NuvioTV's own settings namespace. The generic "tv" scope is ALSO written by upstream's
 * Nuvio Android TV app, and the two clients have different settings schemas — each one's push is
 * a full-blob replace built from its own typed model, so every launch stripped the other app's
 * keys (Android lost `tmdb` enrichment flags and settings-appearance keys; NuvioTV got its card
 * depth / poster style reset by Android's schema-less blob). A namespace only this app writes
 * ends the fight outright; `p_platform` is a free-form namespace per the cloud API reference
 * (§Profile Settings), so no server change is needed.
 */
const val TVOS_SYNC_PLATFORM = "tvos"
internal const val HOME_CATALOG_SHARED_SYNC_PLATFORM = "home_catalog_shared"

/**
 * BUG-75: cross-platform namespace for the tracking source preferences (watch-progress source,
 * library source mode, continue-watching days cap). Those settings ride the platform-scoped
 * profile blob, so a Trakt→Simkl switch on mobile lands under "mobile" and never reaches the TV.
 * They describe the ACCOUNT's tracking backend, not a per-device look, so they get their own
 * shared namespace — same free-form `p_platform` precedent as [HOME_CATALOG_SHARED_SYNC_PLATFORM],
 * so no server change is needed.
 */
internal const val TRACKING_SOURCE_SHARED_SYNC_PLATFORM = "tracking_source_shared"

/**
 * Which `p_platform` value this client sends on the platform-scoped settings-blob RPCs
 * (`sync_pull_profile_settings_blob` / `sync_push_profile_settings_blob`). The Nuvio Cloud API
 * (docs/nuvio-cloud-api-reference.md §Profile Settings) scopes those blobs per platform, so the
 * phone and the TV keep separate settings server-side.
 *
 * Default is [MOBILE_SYNC_PLATFORM] (composeApp needs no install). The tvOS target sets
 * [TV_SYNC_PLATFORM] in `installTvOsSharedProviders()`. Mirrors the StringProvider /
 * FeaturePolicyProvider injection pattern.
 */
object SyncPlatformProvider {
    @Volatile
    var platform: String = MOBILE_SYNC_PLATFORM

    /**
     * Namespaces to read (never write) when [platform] has no settings blob yet — one-shot
     * migration seed. tvOS sets `["tv"]` so an existing install keeps its cloud settings the
     * first time it runs under the "tvos" namespace; after the seed is pushed to [platform],
     * the legacy scope is never touched again.
     */
    @Volatile
    var legacySettingsPlatforms: List<String> = emptyList()
}
