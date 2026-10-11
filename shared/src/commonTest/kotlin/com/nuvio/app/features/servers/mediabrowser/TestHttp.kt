package com.nuvio.app.features.servers.mediabrowser

import io.ktor.http.Url

/** What a provider sent, in the shape the assertions read (path, query parameters, headers, JSON body). */
internal class RecordedRequest(raw: MediaBrowserRequest) {
    val method = raw.method
    val url: Url = Url(raw.url)
    val headers: Map<String, String> = raw.headers
    val text: String = raw.body.orEmpty()
}

/**
 * Recording [MediaBrowserTransport] for the provider tests: every request is kept and answered with
 * a 200 and whatever [responder] returns. Stands in for upstream's Ktor MockEngine.
 */
internal class TestHttp(
    private val responder: (RecordedRequest) -> String = { error("Unexpected request ${it.url}") },
) : MediaBrowserTransport {
    val requests = mutableListOf<RecordedRequest>()

    override suspend fun send(request: MediaBrowserRequest): ApiResponse {
        val recorded = RecordedRequest(request)
        requests += recorded
        return ApiResponse(status = 200, body = responder(recorded), location = null, finalUrl = request.url)
    }
}
