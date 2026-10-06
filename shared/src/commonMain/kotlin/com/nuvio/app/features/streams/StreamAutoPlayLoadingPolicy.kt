package com.nuvio.app.features.streams

/// Upstream 58864ec1 (#1825): a stream fan-out counts as "loaded" for auto-play once every group inside
/// the configured [StreamAutoPlaySource] scope has finished — an out-of-scope source still loading must
/// neither delay nor be picked. Public (upstream `internal`) because tvOS's `NextEpisodeAutoPlay` runs
/// its own up-next selection in Swift against the same rule through SharedCore.
fun List<AddonStreamGroup>.areAutoPlaySourcesLoaded(
    source: StreamAutoPlaySource,
    installedAddonIds: Set<String>,
): Boolean = none { group ->
    group.isLoading && when (source) {
        StreamAutoPlaySource.ALL_SOURCES -> true
        StreamAutoPlaySource.INSTALLED_ADDONS_ONLY -> group.addonId in installedAddonIds
        StreamAutoPlaySource.ENABLED_PLUGINS_ONLY -> group.addonId !in installedAddonIds
    }
}
