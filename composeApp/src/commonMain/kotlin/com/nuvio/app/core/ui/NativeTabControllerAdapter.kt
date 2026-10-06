package com.nuvio.app.core.ui

/** Installs [NativeTabBridge] behind the shared [NativeTabController] seam. Call [install] at startup. */
object NativeTabControllerAdapter {
    fun install() {
        NativeTabControllerProvider.controller = object : NativeTabController {
            override fun publishAccentColor(hexColor: String) = NativeTabBridge.publishAccentColor(hexColor)
            override fun publishLiquidGlassEnabled(enabled: Boolean) = NativeTabBridge.publishLiquidGlassEnabled(enabled)
        }
    }
}
