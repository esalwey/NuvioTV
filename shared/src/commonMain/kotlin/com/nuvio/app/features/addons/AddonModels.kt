package com.nuvio.app.features.addons

import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

data class AddonManifest(
    val id: String,
    val name: String,
    val description: String,
    val version: String,
    val logoUrl: String? = null,
    val resources: List<AddonResource>,
    val types: List<String>,
    val idPrefixes: List<String> = emptyList(),
    val catalogs: List<AddonCatalog> = emptyList(),
    val behaviorHints: AddonBehaviorHints = AddonBehaviorHints(),
    val transportUrl: String,
)

data class AddonResource(
    val name: String,
    val types: List<String>,
    val idPrefixes: List<String> = emptyList(),
)

data class AddonCatalog(
    val type: String,
    val id: String,
    val name: String,
    val extra: List<AddonExtraProperty> = emptyList(),
)

data class AddonExtraProperty(
    val name: String,
    val isRequired: Boolean = false,
    val options: List<String> = emptyList(),
    val optionsLimit: Int? = null,
)

data class AddonBehaviorHints(
    val configurable: Boolean = false,
    val configurationRequired: Boolean = false,
    val adult: Boolean = false,
    val p2p: Boolean = false,
)

data class ManagedAddon(
    val manifestUrl: String,
    val manifest: AddonManifest? = null,
    val userSetName: String? = null,
    val enabled: Boolean = true,
    val isRefreshing: Boolean = false,
    val errorMessage: String? = null,
) {
    val isActive: Boolean
        get() = enabled && manifest != null

    val displayTitle: String
        get() = userSetName?.takeIf { it.isNotBlank() && it != manifest?.name }
            ?: manifest?.name
            ?: manifestUrl.substringBefore("?").substringAfterLast("/").ifBlank {
                resourceString("Addon", StringKey.generic_addon)
            }
}

data class AddonsUiState(
    val addons: List<ManagedAddon> = emptyList(),
    /**
     * Codex branch review round 9: false on the repository's INITIAL state, i.e. before
     * `AddonRepository.initialize()` has read the profile's local add-on list (or a server pull has
     * applied one). Consumers that watch `uiState` attach before bootstrap runs and therefore see
     * that initial state first; without this flag an empty, nothing-pending emission is
     * indistinguishable from the settled "this profile genuinely has no enabled add-on" state, and
     * tvOS's Home read it as terminal and opened its rows gate on every cold launch.
     *
     * Carried ON the state rather than read from `AddonRepository.initializedState` on the side so
     * the decision is made from ONE consistent snapshot: the repository sets its mirror flow after
     * the emission, so a snapshot read can observe a settled list with the flag still false.
     *
     * Defaulted so every other construction site (composeApp included) is unaffected.
     */
    val isInitialized: Boolean = false,
)

data class AddonOverview(
    val totalAddons: Int,
    val activeAddons: Int,
    val totalCatalogs: Int,
)

fun List<ManagedAddon>.toOverview(): AddonOverview =
    AddonOverview(
        totalAddons = size,
        activeAddons = count { it.isActive },
        totalCatalogs = filter { it.enabled }.sumOf { it.manifest?.catalogs?.size ?: 0 },
    )

fun List<ManagedAddon>.enabledAddons(): List<ManagedAddon> =
    filter { it.enabled }

// Upstream 085e8dc6 (#1819): the three predicates behind "delayed addon content states". Public
// (upstream has them `internal`) because tvOS's HomeViewModel/SearchViewModel consume them through
// the SharedCore framework, exactly like `enabledAddons` above.

/// An enabled addon whose manifest fetch is still in flight. While true, "no active addons" is not
/// yet a fact — Search/Discover/Home publish a loading state instead of a false empty state.
fun List<ManagedAddon>.hasPendingEnabledManifests(): Boolean =
    any { addon -> addon.enabled && addon.isRefreshing }

/// Enabled addons exist, none has a manifest yet, and at least one is still fetching.
fun List<ManagedAddon>.isWaitingForFirstEnabledManifest(): Boolean {
    val enabledAddons = enabledAddons()
    return enabledAddons.isNotEmpty() &&
        enabledAddons.none { addon -> addon.manifest != null } &&
        enabledAddons.any { addon -> addon.isRefreshing }
}

/// First non-blank manifest-load error among enabled addons that still have no manifest (a stale
/// refresh error on an addon whose manifest IS loaded is ignored).
fun List<ManagedAddon>.firstEnabledManifestError(): String? =
    asSequence()
        .filter { addon -> addon.enabled && addon.manifest == null }
        .mapNotNull { addon -> addon.errorMessage?.takeIf(String::isNotBlank) }
        .firstOrNull()

sealed interface AddAddonResult {
    data class Success(val manifest: AddonManifest) : AddAddonResult
    data class Error(val message: String) : AddAddonResult
}
