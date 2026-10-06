package com.nuvio.app.core.ui

/**
 * Compose-free seam for showing a transient toast message. The phone app's
 * `NuvioToastController` lives in a Compose-heavy file (core/ui/Components.kt) and can't move
 * to :shared, so shared code (e.g. LibraryRepository) routes through this provider instead.
 * Targets with no adapter installed (tvOS today) get the no-op default.
 */
fun interface ToastController {
    fun show(message: String)
}

object ToastControllerProvider {
    var controller: ToastController = ToastController { }
}
