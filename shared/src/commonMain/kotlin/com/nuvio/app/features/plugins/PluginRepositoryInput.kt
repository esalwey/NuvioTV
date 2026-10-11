package com.nuvio.app.features.plugins

/**
 * Typing a plugin repository on a TV remote is painful, so a repository can also be named by a short
 * code ("cspr", "0094") that cutt.ly redirects to its manifest URL. Parity: Android TV
 * `PluginManager.isShortCode` / `resolveShortCode`. The redirect itself is a network call and is
 * made by the platform layer; this holds the rules around it.
 */
object PluginRepositoryInput {
    private const val SHORT_CODE_HOST = "https://cutt.ly/"

    /**
     * True when [input] is a short code rather than a URL or a domain: no scheme, no path, no dot,
     * only letters, digits, hyphens and underscores.
     */
    fun isShortCode(input: String): Boolean {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return false
        if (trimmed.contains("://")) return false
        if (trimmed.contains('/') || trimmed.contains('.')) return false
        return trimmed.all { it.isLetterOrDigit() || it == '-' || it == '_' }
    }

    /** The address whose redirect names the repository for [code]. */
    fun shortCodeUrl(code: String): String = SHORT_CODE_HOST + code.trim()

    /**
     * The repository address a redirect named, or null when it is not one. Only web addresses
     * count: `http` is upgraded to `https`, a scheme-less location gets `https://`, anything else
     * (the shortener's own landing page excluded) is refused.
     */
    fun repositoryUrlFromRedirect(location: String?): String? {
        val trimmed = location?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        val withScheme = when {
            trimmed.startsWith("https://", ignoreCase = true) -> trimmed
            trimmed.startsWith("http://", ignoreCase = true) -> "https://" + trimmed.substring("http://".length)
            trimmed.contains("://") -> return null
            else -> "https://$trimmed"
        }
        val host = withScheme.substringAfter("://").substringBefore('/').substringBefore('?').lowercase()
        if (host.isEmpty() || host == "cutt.ly" || host.endsWith(".cutt.ly")) return null
        return withScheme
    }
}
