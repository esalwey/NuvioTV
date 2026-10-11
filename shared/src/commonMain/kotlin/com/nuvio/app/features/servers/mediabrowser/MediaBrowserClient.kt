package com.nuvio.app.features.servers.mediabrowser

import com.nuvio.app.core.build.AppVersionConfig
import com.nuvio.app.core.sync.SyncClientIdentity
import com.nuvio.app.features.addons.httpRequestRaw
import com.nuvio.app.features.servers.ServerException
import com.nuvio.app.features.servers.ServerFailure
import io.ktor.http.HttpMethod
import io.ktor.http.URLBuilder
import io.ktor.http.URLProtocol
import io.ktor.http.Url
import io.ktor.http.encodeURLPathPart
import io.ktor.http.encodedPath
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.json.Json

/**
 * The one HTTP seam of the Jellyfin / Emby clients. Fork: upstream hands a Ktor `HttpClient` to the
 * providers; :shared only ships the platform `httpRequestRaw` (and no Ktor mock engine), so the
 * clients talk to this interface instead and the tests plug a recording fake in.
 */
internal interface MediaBrowserTransport {
    suspend fun send(request: MediaBrowserRequest): ApiResponse
}

internal class MediaBrowserRequest(
    val method: HttpMethod,
    val url: String,
    val headers: Map<String, String>,
    val body: String?,
    val followRedirects: Boolean,
) {
    override fun toString(): String = "MediaBrowserRequest(${method.value} $url)"
}

/** Production transport: the platform HTTP stack shared with add-on fetches (Darwin / OkHttp / JDK). */
internal object PlatformMediaBrowserTransport : MediaBrowserTransport {
    override suspend fun send(request: MediaBrowserRequest): ApiResponse {
        val response = httpRequestRaw(
            method = request.method.value,
            url = request.url,
            headers = request.headers,
            body = request.body.orEmpty(),
            followRedirects = request.followRedirects,
            maxResponseBodyBytes = MAX_RESPONSE_BYTES,
        )
        return ApiResponse(
            status = response.status,
            body = response.body,
            location = response.headers["location"],
            finalUrl = response.url.takeIf { it.isNotBlank() },
        )
    }

    private const val MAX_RESPONSE_BYTES = 8 * 1024 * 1024
}

internal class MediaBrowserClient(
    private val authorizationHeader: String,
    private val transport: MediaBrowserTransport,
) {
    val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }

    val deviceId: String
        get() = SyncClientIdentity.currentClientId()

    suspend fun <T> get(
        baseUrl: String,
        path: String,
        deserializer: DeserializationStrategy<T>,
        token: String? = null,
        query: Map<String, String?> = emptyMap(),
    ): T = decode(deserializer, execute(HttpMethod.Get, baseUrl, path, token, query).body)

    /** A 2xx answer that is not the JSON we asked for (a proxy login page, a truncated body) is a failure, not a crash. */
    fun <T> decode(deserializer: DeserializationStrategy<T>, body: String): T = try {
        json.decodeFromString(deserializer, body)
    } catch (error: CancellationException) {
        throw error
    } catch (_: Exception) {
        throw ServerException(ServerFailure.FAILED)
    }

    suspend fun execute(
        method: HttpMethod,
        baseUrl: String,
        path: String,
        token: String?,
        query: Map<String, String?> = emptyMap(),
        body: String? = null,
        allowRedirect: Boolean = false,
    ): ApiResponse {
        val headers = buildMap {
            put("Accept", "application/json")
            put(authorizationHeader, authorizationValue(token))
            if (body != null) put("Content-Type", "application/json")
        }
        val request = MediaBrowserRequest(
            method = method,
            url = buildUrl(baseUrl, path, query),
            headers = headers,
            body = body,
            followRedirects = !allowRedirect,
        )
        val response = try {
            withTimeoutOrNull(REQUEST_TIMEOUT_MS) { transport.send(request) }
        } catch (error: CancellationException) {
            throw error
        } catch (error: ServerException) {
            throw error
        } catch (_: Exception) {
            throw ServerException(ServerFailure.UNREACHABLE)
        } ?: throw ServerException(ServerFailure.UNREACHABLE)
        if (allowRedirect && response.status in 300..399) return response
        throwForStatus(response.status)
        return response
    }

    fun authorizationValue(token: String?): String = buildString {
        append("MediaBrowser Client=\"Nuvio\", Device=\"")
        append(DEVICE_NAME.headerValue())
        append("\", DeviceId=\"")
        append(deviceId.headerValue())
        append("\", Version=\"")
        append(AppVersionConfig.VERSION_NAME.headerValue())
        append('"')
        if (token != null) {
            append(", Token=\"")
            append(token.headerValue())
            append('"')
        }
    }

    private fun throwForStatus(status: Int) {
        val failure = when {
            status in 200..299 -> return
            status == 401 -> ServerFailure.AUTH_REQUIRED
            status == 403 -> ServerFailure.FORBIDDEN
            status == 404 -> ServerFailure.NOT_FOUND
            status in 500..599 -> ServerFailure.UNREACHABLE
            else -> ServerFailure.FAILED
        }
        throw ServerException(failure, "HTTP $status")
    }

    private companion object {
        const val REQUEST_TIMEOUT_MS = 30_000L

        // Fork: shown in the server's device list. :shared has no `getPlatform()`; this is the
        // tvOS app's own device name.
        const val DEVICE_NAME = "Apple TV"
    }
}

internal class ApiResponse(
    val status: Int,
    val body: String,
    val location: String?,
    /** Where the response actually came from after the platform followed redirects, when known. */
    val finalUrl: String? = null,
) {
    override fun toString(): String = "ApiResponse(status=$status)"
}

internal fun buildUrl(baseUrl: String, path: String, query: Map<String, String?> = emptyMap()): String {
    require(path.startsWith('/'))
    val base = Url(baseUrl)
    require(base.protocol == URLProtocol.HTTP || base.protocol == URLProtocol.HTTPS)
    return URLBuilder(base).apply {
        encodedPath = base.encodedPath.trimEnd('/') + path
        parameters.clear()
        fragment = ""
        query.forEach { (key, value) -> if (value != null) parameters.append(key, value) }
    }.buildString()
}

internal fun pathSegment(value: String): String = value.encodeURLPathPart()

internal fun normalizeServerAddress(input: String, apiPath: String = ""): String? {
    var value = input.trim().trimEnd('/')
    if (value.isEmpty()) return null
    if (!value.contains("://")) value = "http://$value"
    val url = runCatching { Url(value) }.getOrNull() ?: return null
    if (url.protocol != URLProtocol.HTTP && url.protocol != URLProtocol.HTTPS) return null
    if (url.host.isBlank() || !url.user.isNullOrEmpty() || !url.password.isNullOrEmpty()) return null
    val path = url.encodedPath.trimEnd('/')
        .removeSuffix("/web/index.html")
        .removeSuffix("/web")
        .trimEnd('/')
        .let { if (apiPath.isNotEmpty() && it.endsWith(apiPath, ignoreCase = true)) it.dropLast(apiPath.length) else it }
    return URLBuilder(url).apply {
        encodedPath = path
        parameters.clear()
        fragment = ""
    }.buildString().trimEnd('/')
}

private fun String.headerValue(): String = filter { it != '"' && it != '\r' && it != '\n' }
