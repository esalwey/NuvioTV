package com.nuvio.app.core.poster

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * What the UI needs: the pattern and the keys of the screens it applies to. [enabledScreenKeys] is
 * a plain list so the Swift side reads it without bridging a set of enum values.
 */
data class CustomPosterUiState(
    val pattern: String = "",
    val enabledScreenKeys: List<String> = CustomPosterScreen.entries.map(CustomPosterScreen::key),
)

/**
 * The user's custom poster URL pattern with its per-screen switches, kept per profile and synced
 * through the profile settings blob (`custom_poster_url_pattern`, `custom_poster_enabled_screens`).
 * The artwork itself is rewritten by the UI at draw time: see
 * [CustomPosterUrlResolver.resolveForTitle].
 */
object CustomPosterUrlRepository {
    private val _uiState = MutableStateFlow(CustomPosterUiState())
    val uiState: StateFlow<CustomPosterUiState> = _uiState.asStateFlow()

    private var hasLoaded = false

    fun ensureLoaded() {
        if (hasLoaded) return
        loadFromDisk()
    }

    fun onProfileChanged() {
        loadFromDisk()
    }

    fun clearLocalState() {
        hasLoaded = false
        _uiState.value = CustomPosterUiState()
    }

    fun setPattern(pattern: String) {
        ensureLoaded()
        val trimmed = pattern.trim()
        if (_uiState.value.pattern == trimmed) return
        _uiState.value = _uiState.value.copy(pattern = trimmed)
        CustomPosterUrlStorage.savePattern(trimmed.ifBlank { null })
    }

    fun clearPattern() {
        setPattern("")
    }

    fun setScreenEnabled(screen: CustomPosterScreen, enabled: Boolean) {
        ensureLoaded()
        val current = enabledScreens()
        val updated = if (enabled) current + screen else current - screen
        if (updated == current) return
        _uiState.value = _uiState.value.copy(enabledScreenKeys = orderedKeys(updated))
        CustomPosterUrlStorage.saveEnabledScreens(CustomPosterScreen.toStoredString(updated))
    }

    /** [setScreenEnabled] by stored key, for callers that do not hold the enum (the Swift settings). */
    fun setScreenKeyEnabled(key: String, enabled: Boolean) {
        val screen = CustomPosterScreen.entries.firstOrNull { it.key == key } ?: return
        setScreenEnabled(screen, enabled)
    }

    /** Replaces the pattern and the screens in one step, as the phone setup page sends them. */
    fun apply(pattern: String, screenKeys: List<String>) {
        ensureLoaded()
        val screens = CustomPosterScreen.entries.filter { it.key in screenKeys }.toSet()
        val trimmed = pattern.trim()
        val next = CustomPosterUiState(pattern = trimmed, enabledScreenKeys = orderedKeys(screens))
        if (_uiState.value == next) return
        _uiState.value = next
        CustomPosterUrlStorage.savePattern(trimmed.ifBlank { null })
        CustomPosterUrlStorage.saveEnabledScreens(CustomPosterScreen.toStoredString(screens))
    }

    fun patternForScreen(screen: CustomPosterScreen): String {
        ensureLoaded()
        return if (screen in enabledScreens()) _uiState.value.pattern else ""
    }

    fun isScreenEnabled(screen: CustomPosterScreen): Boolean {
        ensureLoaded()
        return screen in enabledScreens()
    }

    private fun enabledScreens(): Set<CustomPosterScreen> =
        CustomPosterScreen.entries.filter { it.key in _uiState.value.enabledScreenKeys }.toSet()

    private fun orderedKeys(screens: Set<CustomPosterScreen>): List<String> =
        CustomPosterScreen.entries.filter { it in screens }.map(CustomPosterScreen::key)

    private fun loadFromDisk() {
        hasLoaded = true
        val screens = CustomPosterScreen.fromStoredString(CustomPosterUrlStorage.loadEnabledScreens())
        _uiState.value = CustomPosterUiState(
            pattern = CustomPosterUrlStorage.loadPattern().orEmpty().trim(),
            enabledScreenKeys = orderedKeys(screens),
        )
    }
}
