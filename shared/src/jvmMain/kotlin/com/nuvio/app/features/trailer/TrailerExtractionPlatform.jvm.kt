package com.nuvio.app.features.trailer

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

/**
 * JVM actual (beta.14 Wave 4, docs/issue-triage-plan-2026-08-21.md §6.1). Not exercised by
 * commonTest (no test file references `TrailerExtractionPlatform`). Implemented for real with
 * plain `java.net.HttpURLConnection` rather than OkHttp (matches the AddonPlatform.jvm.kt
 * approach) — same request/response shape as the android actual, but the googlevideo mirror-race
 * probing is simplified to a single reachability check since nothing here needs the full
 * multi-candidate race to be exercised under test.
 */
internal actual fun trailerDebugLog(message: String) {
    println("[TrailerExtract] $message")
}

internal actual object TrailerExtractionPlatform {
    actual val defaultHeaders: Map<String, String> = mapOf(
        "accept-language" to "en-US,en;q=0.9",
        "user-agent" to
            "Mozilla/5.0 (Linux; Android 12; Android TV) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
    )

    actual suspend fun performRequest(
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String?,
        timeoutMillis: Long,
    ): TrailerRequestResponse = withContext(Dispatchers.IO) {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method.uppercase().let {
                if (it in setOf("GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS")) it else "GET"
            }
            connection.connectTimeout = timeoutMillis.toInt()
            connection.readTimeout = timeoutMillis.toInt()
            connection.instanceFollowRedirects = true
            buildHeaders(headers).forEach { (name, value) -> connection.setRequestProperty(name, value) }

            if (connection.requestMethod in setOf("POST", "PUT")) {
                connection.doOutput = true
                val bytes = (body ?: "").toByteArray(Charsets.UTF_8)
                connection.outputStream.use { it.write(bytes) }
            }

            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) }.orEmpty()
            TrailerRequestResponse(
                ok = status in 200..299,
                status = status,
                statusText = connection.responseMessage.orEmpty(),
                url = connection.url.toString(),
                body = text,
            )
        } finally {
            connection.disconnect()
        }
    }

    actual suspend fun buildPlaybackSource(
        bestManifest: ManifestCandidate?,
        bestProgressive: StreamCandidate?,
        bestVideo: StreamCandidate?,
        bestAudio: StreamCandidate?,
        bestAvcVideo: StreamCandidate?,
        bestM4aAudio: StreamCandidate?,
    ): TrailerPlaybackSource? = withContext(Dispatchers.IO) {
        val bestCombinedIsManifest = bestManifest != null &&
            (bestProgressive == null || bestManifest.height > bestProgressive.height)

        val combinedUrl = if (bestCombinedIsManifest) {
            bestManifest?.selectedVariantUrl
        } else {
            bestProgressive?.url
        }

        val separatedVideoUrl = bestVideo?.url?.let { if (isUrlReachable(it)) it else null }
        val combinedCandidateUrl = combinedUrl?.let { if (isUrlReachable(it)) it else null }
        val videoUrl = separatedVideoUrl ?: combinedCandidateUrl ?: return@withContext null
        val audioUrl = if (!separatedVideoUrl.isNullOrBlank()) {
            bestAudio?.url?.let { if (isUrlReachable(it)) it else null }
        } else {
            null
        }

        TrailerPlaybackSource(videoUrl = videoUrl, audioUrl = audioUrl)
    }

    private fun isUrlReachable(url: String): Boolean = runCatching {
        val connection = URI(url).toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = 2_000
            connection.readTimeout = 2_000
            connection.setRequestProperty("Range", "bytes=0-0")
            buildHeaders(defaultHeaders).forEach { (name, value) -> connection.setRequestProperty(name, value) }
            connection.responseCode in 200..299
        } finally {
            connection.disconnect()
        }
    }.getOrDefault(false)

    private fun buildHeaders(source: Map<String, String>): Map<String, String> {
        val headers = LinkedHashMap<String, String>()
        source.forEach { (name, value) ->
            if (!name.equals("Accept-Encoding", ignoreCase = true)) {
                headers[name] = value
            }
        }
        if (headers.keys.none { it.equals("User-Agent", ignoreCase = true) }) {
            headers["User-Agent"] = defaultHeaders.getValue("user-agent")
        }
        return headers
    }
}
