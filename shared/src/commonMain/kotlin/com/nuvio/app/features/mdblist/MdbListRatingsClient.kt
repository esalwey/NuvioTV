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
 * [MdbListRatingsRepository]'s batch size of titles per request.
 */
internal class MdbListRatingsClient(
    private val getText: suspend (String) -> String = { httpGetText(it) },
    private val postJson: suspend (String, String) -> String = { url, body -> httpPostJson(url, body) },
) {
    suspend fun getMedia(mediaType: String, imdbId: String, apiKey: String): String =
        getText("https://api.mdblist.com/imdb/$mediaType/$imdbId/?apikey=${apiKey.encodeURLParameter()}&append_to_response=keyword")

    suspend fun getMediaBatch(mediaType: String, imdbIds: List<String>, apiKey: String): String {
        val body = buildJsonObject {
            put("ids", JsonArray(imdbIds.map(::JsonPrimitive)))
            put("append_to_response", buildJsonArray { add("keyword") })
        }.toString()
        return postJson("https://api.mdblist.com/imdb/$mediaType/?apikey=${apiKey.encodeURLParameter()}", body)
    }
}
