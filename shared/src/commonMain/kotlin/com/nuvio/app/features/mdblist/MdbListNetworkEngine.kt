package com.nuvio.app.features.mdblist

import com.nuvio.app.features.addons.httpRequestRaw
import io.ktor.http.URLBuilder
import io.ktor.http.URLProtocol
import io.ktor.http.Url
import io.ktor.http.encodedPath
import io.ktor.http.formUrlEncode
import io.ktor.utils.io.errors.IOException
import kotlinx.coroutines.CancellationException

private const val MDBLIST_RESPONSE_MAX_BYTES = 16 * 1024 * 1024

/**
 * Sends MDBList requests through the app's shared HTTP stack ([httpRequestRaw]: Darwin on Apple,
 * OkHttp on Android). Every failure that is not a response is reported as an [IOException], which
 * is what [MdbListHttpClient] retries.
 */
internal class MdbListNetworkEngine(
    private val configuration: MdbListConfiguration,
) : MdbListHttpEngine {
    override suspend fun execute(request: MdbListHttpRequest): MdbListHttpResponse {
        val hasBody = request.method == MdbListHttpMethod.POST || request.method == MdbListHttpMethod.PUT
        val headers = buildMap {
            put("Accept", "application/json")
            put("User-Agent", "Nuvio/${configuration.appVersion}")
            request.accessToken?.let { put("Authorization", "Bearer $it") }
            if (hasBody) {
                put("Content-Type", if (request.form == null) "application/json" else "application/x-www-form-urlencoded")
            }
        }
        val body = if (hasBody) request.form?.toList()?.formUrlEncode() ?: request.body else ""
        val response = try {
            httpRequestRaw(
                method = request.method.name,
                url = mdbListRequestUrl(configuration, request),
                headers = headers,
                body = body,
                followRedirects = false,
                maxResponseBodyBytes = MDBLIST_RESPONSE_MAX_BYTES,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: IOException) {
            throw error
        } catch (error: Exception) {
            throw IOException("MDBList request failed")
        }
        return MdbListHttpResponse(response.status, response.body, response.headers)
    }
}

internal fun mdbListRequestUrl(configuration: MdbListConfiguration, request: MdbListHttpRequest): String {
    require(request.path.startsWith('/') && !request.path.startsWith("//"))
    require(request.path.none { it == '?' || it == '#' || it == '\\' })
    val base = Url(configuration.baseUrl)
    require(base.protocol == URLProtocol.HTTPS || base.host in setOf("localhost", "127.0.0.1", "::1"))
    require(base.user.isNullOrEmpty() && base.password.isNullOrEmpty())
    return URLBuilder(base).apply {
        encodedPath = request.path
        parameters.clear()
        fragment = ""
        request.query.forEach { (key, value) -> parameters.append(key, value) }
    }.buildString()
}
