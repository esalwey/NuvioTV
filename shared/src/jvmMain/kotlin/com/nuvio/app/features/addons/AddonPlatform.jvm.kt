package com.nuvio.app.features.addons

import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * JVM actual (beta.14 Wave 4, docs/issue-triage-plan-2026-08-21.md §6.1). Not exercised by
 * commonTest (no test file references `AddonStorage`/`httpGetText`/etc.), but implemented for
 * real rather than stubbed: [AddonStorage] mirrors androidMain's SharedPreferences-backed,
 * line-encoded layout (via [JvmSharedPreferences]); the http* functions use plain
 * `java.net.HttpURLConnection` — no OkHttp dependency needed for a target that only backs tests.
 */
actual object AddonStorage {
    private const val preferencesName = "nuvio_addons"
    private const val addonUrlsKey = "installed_manifest_urls"
    private const val addonEnabledStatesKey = "installed_manifest_enabled_states"
    private const val addonListKnownKey = "installed_manifest_list_known"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadInstalledAddonUrls(profileId: Int): List<String> =
        preferences
            ?.getString("${addonUrlsKey}_$profileId", null)
            .orEmpty()
            .lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toList()

    actual fun loadAddonListKnown(profileId: Int): Boolean? {
        val prefs = preferences ?: return null
        val key = "${addonListKnownKey}_$profileId"
        return if (prefs.contains(key)) prefs.getBoolean(key, false) else null
    }

    actual fun saveAddonListKnown(profileId: Int, known: Boolean) {
        preferences
            ?.edit()
            ?.putBoolean("${addonListKnownKey}_$profileId", known)
            ?.apply()
    }

    actual fun saveInstalledAddonUrls(profileId: Int, urls: List<String>) {
        preferences
            ?.edit()
            ?.putString("${addonUrlsKey}_$profileId", urls.joinToString(separator = "\n"))
            ?.apply()
    }

    actual fun loadAddonEnabledStates(profileId: Int): Map<String, Boolean> =
        preferences
            ?.getString("${addonEnabledStatesKey}_$profileId", null)
            .orEmpty()
            .lineSequence()
            .mapNotNull(::parseEnabledStateLine)
            .toMap()

    actual fun saveAddonEnabledStates(profileId: Int, states: Map<String, Boolean>) {
        val payload = states.entries.joinToString(separator = "\n") { (url, enabled) ->
            "$url\t$enabled"
        }
        preferences
            ?.edit()
            ?.putString("${addonEnabledStatesKey}_$profileId", payload)
            ?.apply()
    }
}

private fun parseEnabledStateLine(line: String): Pair<String, Boolean>? {
    val url = line.substringBefore("\t").trim().takeIf { it.isNotEmpty() } ?: return null
    val rawEnabled = line.substringAfter("\t", "true").trim().lowercase()
    val enabled = when (rawEnabled) {
        "false" -> false
        else -> true
    }
    return url to enabled
}

private fun requestAllowsBody(method: String): Boolean =
    when (method.uppercase()) {
        "POST", "PUT", "PATCH", "DELETE" -> true
        else -> false
    }

private fun Map<String, String>.withoutAcceptEncoding(): Map<String, String> =
    entries
        .filterNot { (key, _) -> key.equals("Accept-Encoding", ignoreCase = true) }
        .associate { (key, value) -> key to value }

private fun Map<String, String>.getHeaderIgnoreCase(name: String): String? =
    entries.firstOrNull { (key, _) -> key.equals(name, ignoreCase = true) }?.value

private fun readAtMostBytes(stream: InputStream, maxBytes: Int): Pair<ByteArray, Boolean> {
    val out = ByteArrayOutputStream(minOf(maxBytes.coerceAtLeast(0), 16 * 1024))
    val buffer = ByteArray(8 * 1024)
    var remaining = maxBytes.coerceAtLeast(0)
    while (remaining > 0) {
        val read = stream.read(buffer, 0, minOf(buffer.size, remaining))
        if (read <= 0) break
        out.write(buffer, 0, read)
        remaining -= read
    }
    val truncated = remaining == 0 && stream.read() != -1
    return out.toByteArray() to truncated
}

private fun openConnection(
    method: String,
    url: String,
    headers: Map<String, String>,
    body: String,
    followRedirects: Boolean,
    bodyBytes: ByteArray? = null,
): HttpURLConnection {
    val normalizedMethod = method.uppercase()
    val sanitizedHeaders = headers.withoutAcceptEncoding()
    val connection = URL(url).openConnection() as HttpURLConnection
    connection.requestMethod = normalizedMethod
    connection.instanceFollowRedirects = followRedirects
    connection.connectTimeout = 60_000
    connection.readTimeout = 60_000
    sanitizedHeaders.forEach { (key, value) -> connection.setRequestProperty(key, value) }

    if (requestAllowsBody(normalizedMethod)) {
        val contentType = sanitizedHeaders.getHeaderIgnoreCase("Content-Type")
            ?: if (normalizedMethod == "POST") "application/x-www-form-urlencoded" else "application/json"
        connection.setRequestProperty("Content-Type", contentType)
        connection.doOutput = true
        val bytes = bodyBytes ?: body.toByteArray(Charsets.UTF_8)
        connection.setFixedLengthStreamingMode(bytes.size)
        connection.outputStream.use { output: OutputStream -> output.write(bytes) }
    }
    return connection
}

private suspend fun executeTextRequest(
    method: String,
    url: String,
    headers: Map<String, String> = emptyMap(),
    body: String = "",
): String = withContext(Dispatchers.IO) {
    val connection = openConnection(method, url, headers, body, followRedirects = true)
    try {
        val status = connection.responseCode
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        val payload = stream?.use { it.readBytes().toString(Charsets.UTF_8) }.orEmpty()
        if (status !in 200..299) {
            error(resourceString("Request failed with HTTP $status", StringKey.network_request_failed_http, status))
        }
        if (payload.isBlank()) {
            throw IllegalStateException(resourceString("Empty response body", StringKey.network_empty_response_body))
        }
        payload
    } finally {
        connection.disconnect()
    }
}

actual suspend fun httpGetText(url: String): String =
    executeTextRequest(method = "GET", url = url, headers = mapOf("Accept" to "application/json"))

actual suspend fun httpPostJson(url: String, body: String): String =
    executeTextRequest(
        method = "POST",
        url = url,
        headers = mapOf("Accept" to "application/json", "Content-Type" to "application/json"),
        body = body,
    )

actual suspend fun httpGetTextWithHeaders(
    url: String,
    headers: Map<String, String>,
): String =
    executeTextRequest(method = "GET", url = url, headers = mapOf("Accept" to "application/json") + headers)

actual suspend fun httpPostJsonWithHeaders(
    url: String,
    body: String,
    headers: Map<String, String>,
): String =
    executeTextRequest(
        method = "POST",
        url = url,
        headers = mapOf("Accept" to "application/json", "Content-Type" to "application/json") + headers,
        body = body,
    )

actual suspend fun httpRequestRaw(
    method: String,
    url: String,
    headers: Map<String, String>,
    body: String,
    followRedirects: Boolean,
    maxResponseBodyBytes: Int,
    bodyBytes: ByteArray?,
): RawHttpResponse = withContext(Dispatchers.IO) {
    val connection = openConnection(method, url, headers, body, followRedirects, bodyBytes)
    try {
        val status = connection.responseCode
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        val (bytes, truncated) = stream?.use { readAtMostBytes(it, maxResponseBodyBytes) } ?: (ByteArray(0) to false)
        val text = String(bytes, Charsets.UTF_8)
        RawHttpResponse(
            status = status,
            statusText = connection.responseMessage.orEmpty(),
            url = connection.url.toString(),
            body = if (truncated) "$text\n...[truncated]" else text,
            headers = connection.headerFields
                .filterKeys { it != null }
                .mapKeys { (name, _) -> name!!.lowercase() }
                .mapValues { (_, values) -> values.joinToString(",") },
            bodyBytes = bytes,
        )
    } finally {
        connection.disconnect()
    }
}
