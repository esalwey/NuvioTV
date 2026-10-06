package com.nuvio.app.core.ui

/**
 * Feeds the shared [ToastController] seam from this app's Compose-backed NuvioToastController.
 * Installed at App() startup.
 */
object ToastControllerAdapter : ToastController {
    override fun show(message: String) {
        NuvioToastController.show(message)
    }

    fun install() {
        ToastControllerProvider.controller = this
    }
}
