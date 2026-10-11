package com.nuvio.app.core.poster

/**
 * Persistence for the custom poster URL pattern and the comma-joined keys of the screens it applies
 * to ([CustomPosterScreen.toStoredString]). Both are profile scoped. A null screens value means
 * "never chosen", which reads as every screen enabled.
 */
expect object CustomPosterUrlStorage {
    fun loadPattern(): String?
    fun savePattern(pattern: String?)
    fun loadEnabledScreens(): String?
    fun saveEnabledScreens(keys: String?)
}
