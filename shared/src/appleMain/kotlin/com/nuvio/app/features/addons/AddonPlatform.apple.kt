package com.nuvio.app.features.addons

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.accept
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.isSuccess
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.cancel
import io.ktor.utils.io.exhausted
import io.ktor.utils.io.readRemaining
import kotlinx.io.readByteArray
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import platform.Foundation.NSUserDefaults

actual object AddonStorage {
    private const val addonUrlsKey = "installed_manifest_urls"
    private const val addonEnabledStatesKey = "installed_manifest_enabled_states"
    private const val addonListKnownKey = "installed_manifest_list_known"

    actual fun loadInstalledAddonUrls(profileId: Int): List<String> =
        NSUserDefaults.standardUserDefaults
            .stringForKey("${addonUrlsKey}_$profileId")
            .orEmpty()
            .lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toList()

    actual fun loadAddonListKnown(profileId: Int): Boolean? {
        val defaults = NSUserDefaults.standardUserDefaults
        val key = "${addonListKnownKey}_$profileId"
        return if (defaults.objectForKey(key) != null) defaults.boolForKey(key) else null
    }

    actual fun saveAddonListKnown(profileId: Int, known: Boolean) {
        NSUserDefaults.standardUserDefaults.setBool(known, forKey = "${addonListKnownKey}_$profileId")
    }

    actual fun saveInstalledAddonUrls(profileId: Int, urls: List<String>) {
        NSUserDefaults.standardUserDefaults.setObject(
            urls.joinToString(separator = "\n"),
            forKey = "${addonUrlsKey}_$profileId",
        )
    }

    actual fun loadAddonEnabledStates(profileId: Int): Map<String, Boolean> =
        NSUserDefaults.standardUserDefaults
            .stringForKey("${addonEnabledStatesKey}_$profileId")
            .orEmpty()
            .lineSequence()
            .mapNotNull(::parseEnabledStateLine)
            .toMap()

    actual fun saveAddonEnabledStates(profileId: Int, states: Map<String, Boolean>) {
        val payload = states.entries.joinToString(separator = "\n") { (url, enabled) ->
            "$url\t$enabled"
        }
        NSUserDefaults.standardUserDefaults.setObject(
            payload,
            forKey = "${addonEnabledStatesKey}_$profileId",
        )
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

private val addonHttpClient = HttpClient(Darwin) {
    install(HttpTimeout) {
        requestTimeoutMillis = 60_000
        connectTimeoutMillis = 60_000
        socketTimeoutMillis = 60_000
    }
    expectSuccess = false
}

actual suspend fun httpGetText(url: String): String =
    addonHttpClient
        .get(url) {
            accept(ContentType.Application.Json)
        }
        .let { response ->
            val payload = response.bodyAsText()
            if (!response.status.isSuccess()) {
                error(resourceString("Request failed with HTTP ${response.status.value}", StringKey.network_request_failed_http, response.status.value))
            }
            if (payload.isBlank()) {
                throw IllegalStateException(resourceString("Empty response body", StringKey.network_empty_response_body))
            }
            payload
        }

actual suspend fun httpPostJson(url: String, body: String): String =
    addonHttpClient
        .post(url) {
            accept(ContentType.Application.Json)
            header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            setBody(body)
        }
        .let { response ->
            val payload = response.bodyAsText()
            if (!response.status.isSuccess()) {
                error(resourceString("Request failed with HTTP ${response.status.value}", StringKey.network_request_failed_http, response.status.value))
            }
            if (payload.isBlank()) {
                throw IllegalStateException(resourceString("Empty response body", StringKey.network_empty_response_body))
            }
            payload
        }

actual suspend fun httpGetTextWithHeaders(
    url: String,
    headers: Map<String, String>,
): String =
    addonHttpClient
        .get(url) {
            accept(ContentType.Application.Json)
            headers.forEach { (key, value) ->
                header(key, value)
            }
        }
        .let { response ->
            val payload = response.bodyAsText()
            if (!response.status.isSuccess()) {
                error(resourceString("Request failed with HTTP ${response.status.value}", StringKey.network_request_failed_http, response.status.value))
            }
            if (payload.isBlank()) {
                throw IllegalStateException(resourceString("Empty response body", StringKey.network_empty_response_body))
            }
            payload
        }

actual suspend fun httpPostJsonWithHeaders(
    url: String,
    body: String,
    headers: Map<String, String>,
): String =
    addonHttpClient
        .post(url) {
            accept(ContentType.Application.Json)
            header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            headers.forEach { (key, value) ->
                header(key, value)
            }
            setBody(body)
        }
        .let { response ->
            val payload = response.bodyAsText()
            if (!response.status.isSuccess()) {
                error(resourceString("Request failed with HTTP ${response.status.value}", StringKey.network_request_failed_http, response.status.value))
            }
            if (payload.isBlank()) {
                throw IllegalStateException(resourceString("Empty response body", StringKey.network_empty_response_body))
            }
            payload
        }

actual suspend fun httpRequestRaw(
    method: String,
    url: String,
    headers: Map<String, String>,
    body: String,
    followRedirects: Boolean,
    maxResponseBodyBytes: Int,
    bodyBytes: ByteArray?,
): RawHttpResponse =
    addonHttpClient
        .prepareRequest {
            url(url)
            this.method = HttpMethod.parse(method.uppercase())
            headers.forEach { (key, value) ->
                header(key, value)
            }
            if (this.method == HttpMethod.Post || this.method == HttpMethod.Put || this.method == HttpMethod.Patch) {
                val requestBytes = bodyBytes
                if (requestBytes != null) setBody(requestBytes) else setBody(body)
            }
        }
        .execute { response ->
            val limited = readResponseBodyLimited(response.bodyAsChannel(), maxResponseBodyBytes)
            RawHttpResponse(
                status = response.status.value,
                statusText = response.status.description,
                url = response.call.request.url.toString(),
                body = limited.text,
                headers = response.headers.entries().associate { (name, values) ->
                    name.lowercase() to values.joinToString(",")
                },
                bodyBytes = limited.bytes,
            )
        }

// Mirrors the Android actual's readResponseBodyLimited: stream at most maxBytes and mark
// truncation, so an untrusted endpoint (server discovery runs pre-trust) cannot make the client
// buffer an unbounded body. prepareRequest/execute keeps Ktor from saving the full body; UTF-8
// decode (every caller consumes JSON/text).
private suspend fun readResponseBodyLimited(channel: ByteReadChannel, maxBytes: Int): LimitedResponseBody {
    val bytes = channel.readRemaining(maxBytes.coerceAtLeast(0).toLong()).readByteArray()
    val truncated = !channel.exhausted()
    if (truncated) channel.cancel(null)
    val decoded = bytes.decodeToString()
    return LimitedResponseBody(
        text = if (truncated) "$decoded\n...[truncated]" else decoded,
        bytes = bytes,
    )
}

/** Upstream 12621c654: the raw bytes are kept next to the decoded text for binary consumers. */
private class LimitedResponseBody(val text: String, val bytes: ByteArray)
