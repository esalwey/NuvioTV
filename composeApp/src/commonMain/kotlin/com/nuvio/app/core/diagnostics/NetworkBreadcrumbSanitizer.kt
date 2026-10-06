package com.nuvio.app.core.diagnostics

/**
 * Sanitizes URL paths before they are attached to diagnostics breadcrumbs.
 *
 * Addon and debrid playback URLs routinely embed signed identifiers or API
 * tokens as path segments (not just query parameters), so stripping the query
 * string is not enough — and character shape alone cannot distinguish a route
 * word from an all-letter credential. Sanitization is therefore default-deny:
 * only segments on an explicit route-word allowlist (plus version and short
 * numeric segments) survive; everything else becomes [REDACTED].
 */
object NetworkBreadcrumbSanitizer {

    // Unreserved URI characters only, so Sentry's URI parser keeps the
    // breadcrumb url field on redacted paths.
    const val REDACTED: String = "-redacted-"

    fun sanitizePath(encodedPath: String): String {
        if (encodedPath.isEmpty() || encodedPath == "/") return encodedPath
        val sanitized = encodedPath
            .split('/')
            .filter { it.isNotEmpty() }
            .joinToString("/") { segment -> if (isSafeSegment(segment)) segment else REDACTED }
        val trailingSlash = if (encodedPath.endsWith("/")) "/" else ""
        return "/$sanitized$trailingSlash"
    }

    private fun isSafeSegment(segment: String): Boolean {
        if (segment.all { it.isDigit() }) return segment.length <= MAX_SAFE_NUMERIC_LENGTH
        if (VERSION_SEGMENT.matches(segment)) return true
        return segment.lowercase() in SAFE_ROUTE_WORDS
    }

    // Route vocabulary seen in our own APIs, Stremio-style addons, and debrid
    // services. Anything not listed here is treated as an identifier.
    private val SAFE_ROUTE_WORDS = setOf(
        "addon",
        "api",
        "catalog",
        "configure",
        "d",
        "dl",
        "download",
        "downloads",
        "files",
        "health",
        "info",
        "manifest.json",
        "meta",
        "movie",
        "ping",
        "playback",
        "proxy",
        "rest",
        "series",
        "stream",
        "streams",
        "subtitle",
        "subtitles",
        "torrents",
        "unrestrict",
        "user",
    )
    private val VERSION_SEGMENT = Regex("v\\d{1,4}")
    private const val MAX_SAFE_NUMERIC_LENGTH = 10
}
