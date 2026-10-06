package com.nuvio.app.features.player

/**
 * JVM actual (beta.14 Wave 4, docs/issue-triage-plan-2026-08-21.md §6.1). Android launches an
 * Intent and apple opens URL-scheme players (Infuse, VLC, …) via `UIApplication`; a JVM test
 * host has no OS shell to hand a URL/intent to. commonTest does not exercise this expect (no
 * test file references `ExternalPlayerPlatform`), so this is an honest "nothing is available"
 * implementation rather than a throwing stub: no players, every open attempt reports
 * NotConfigured instead of pretending to launch something.
 */
actual object ExternalPlayerPlatform {
    actual fun defaultPlayerId(): String? = null

    actual fun availablePlayers(): List<ExternalPlayerApp> = emptyList()

    actual fun open(
        request: ExternalPlayerPlaybackRequest,
        playerId: String?,
    ): ExternalPlayerOpenResult = ExternalPlayerOpenResult.NotConfigured

    actual fun buildIntent(
        request: ExternalPlayerPlaybackRequest,
        playerId: String?,
    ): ExternalPlayerIntentResult = ExternalPlayerIntentResult.NotConfigured
}
