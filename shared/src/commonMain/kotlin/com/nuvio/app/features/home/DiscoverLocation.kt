package com.nuvio.app.features.home

/** Where the Discover browser lives. */
enum class DiscoverLocation {
    /** Not shown anywhere. */
    OFF,

    /** Below the search field, on the Search screen (the default). */
    IN_SEARCH,

    /** Its own item in the sidebar. */
    IN_SIDEBAR,
}

/**
 * Maps the two stored switches to a location. [hideDiscover] is the older "hide Discover in Search"
 * switch that every client understands; [inSidebar] tells a sidebar Discover from an off one and
 * only counts while Discover is hidden in Search, so a client that predates the sidebar item
 * turning Discover back on in Search wins over a stale sidebar flag.
 */
fun discoverLocationOf(hideDiscover: Boolean, inSidebar: Boolean): DiscoverLocation = when {
    !hideDiscover -> DiscoverLocation.IN_SEARCH
    inSidebar -> DiscoverLocation.IN_SIDEBAR
    else -> DiscoverLocation.OFF
}
