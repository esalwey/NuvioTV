package com.nuvio.app.features.mdblist

import com.nuvio.app.features.addons.httpGetText
import com.nuvio.app.features.addons.httpPostJson
import io.ktor.http.encodeURLParameter
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * MDBList media endpoints that return every provider's rating (and the Rotten Tomatoes
 * certification keywords) for a title in one response, singly or for up to
 * [MdbListRatingsRepository]'s batch size of titles per request. A typed API key is sent as a
 * query parameter; the connected account goes through the authenticated MDBList API client.
 */
internal class MdbListRatingsClient(
    private val getText: suspend (String) -> String = { httpGetText(it) },
    private val postJson: suspend (String, String) -> String = { url, body -> httpPostJson(url, body) },
    private val accountGet: suspend (String, Map<String, String>, MdbListAuthScope) -> String =
        { path, query, scope -> MdbListTracker.api.get(path, query, scope).body },
    private val accountPost: suspend (String, String, MdbListAuthScope) -> String =
        { path, body, scope -> MdbListTracker.api.post(path, body, scope).body },
) {
    suspend fun getMedia(mediaType: String, imdbId: String, credential: MdbListRatingsCredential): String =
        when (credential) {
            is MdbListRatingsCredential.ApiKey ->
                getText("https://api.mdblist.com/imdb/$mediaType/$imdbId/?apikey=${credential.value.encodeURLParameter()}&append_to_response=keyword")
            is MdbListRatingsCredential.Account ->
                accountGet("/imdb/$mediaType/$imdbId/", mapOf("append_to_response" to "keyword"), credential.scope)
        }

    suspend fun getMediaBatch(mediaType: String, imdbIds: List<String>, credential: MdbListRatingsCredential): String {
        val body = buildJsonObject {
            put("ids", JsonArray(imdbIds.map(::JsonPrimitive)))
            put("append_to_response", buildJsonArray { add("keyword") })
        }.toString()
        return when (credential) {
            is MdbListRatingsCredential.ApiKey ->
                postJson("https://api.mdblist.com/imdb/$mediaType/?apikey=${credential.value.encodeURLParameter()}", body)
            is MdbListRatingsCredential.Account ->
                accountPost("/imdb/$mediaType/", body, credential.scope)
        }
    }
}
