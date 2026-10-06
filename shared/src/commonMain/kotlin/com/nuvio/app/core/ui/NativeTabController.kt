package com.nuvio.app.core.ui

import kotlin.concurrent.Volatile

/**
 * Compose-free seam for publishing theme-driven state to the native (iOS) tab bar. The real
 * implementation (NativeTabBridge, which wraps platform `expect` funs) lives in composeApp.
 * Default is a no-op so a target with no adapter installed (e.g. tvOS today) still works.
 */
interface NativeTabController {
    fun publishAccentColor(hexColor: String)
    fun publishLiquidGlassEnabled(enabled: Boolean)
}

/** Process-wide holder for the active [NativeTabController]. composeApp installs the real one. */
object NativeTabControllerProvider {
    @Volatile
    var controller: NativeTabController = NoOpNativeTabController
}

private object NoOpNativeTabController : NativeTabController {
    override fun publishAccentColor(hexColor: String) {}
    override fun publishLiquidGlassEnabled(enabled: Boolean) {}
}
