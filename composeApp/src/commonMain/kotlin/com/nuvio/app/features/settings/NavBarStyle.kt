package com.nuvio.app.features.settings

import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.settings_nav_bar_style_adaptive
import nuvio.composeapp.generated.resources.settings_nav_bar_style_classic
import nuvio.composeapp.generated.resources.settings_nav_bar_style_compact
import nuvio.composeapp.generated.resources.settings_nav_bar_style_expanded
import org.jetbrains.compose.resources.StringResource

// Fork split: the NavBarStyle enum itself lives in :shared (see the note there); this file keeps
// upstream's compose-resources labels as an extension.
val NavBarStyle.labelRes: StringResource
    get() = when (this) {
        NavBarStyle.ADAPTIVE -> Res.string.settings_nav_bar_style_adaptive
        NavBarStyle.EXPANDED -> Res.string.settings_nav_bar_style_expanded
        NavBarStyle.COMPACT -> Res.string.settings_nav_bar_style_compact
        NavBarStyle.CLASSIC -> Res.string.settings_nav_bar_style_classic
    }
