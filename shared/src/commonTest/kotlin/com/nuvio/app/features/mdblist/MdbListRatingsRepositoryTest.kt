package com.nuvio.app.features.mdblist

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MdbListRatingsRepositoryTest {
    private val requests = mutableListOf<Pair<String, String?>>()
    private val providers = MdbListMetadataService.PROVIDER_PRIORITY_ORDER
    private var respond: (String?) -> String = { body ->
        if (body == null) media("tt1") else batch(requestIds(body))
    }
    private val client = MdbListRatingsClient(
        getText = { url -> requests += url to null; respond(null) },
        postJson = { url, body -> requests += url to body; respond(body) },
    )

    private val key = MdbListRatingsCredential.ApiKey("key")

    private fun repository() = MdbListRatingsRepository(client)

    @Test
    fun oneTitleUsesOneSingleRequestForEveryProviderAndKeepsCertification() = runBlocking {
        val ratings = repository().getRatings("movie", "tt1", key, providers)

        assertEquals(listOf("imdb", "tomatoes", "audience"), ratings.map { it.source })
        assertEquals(listOf("tomatoes"), ratings.filter { it.isCertified }.map { it.source })
        assertEquals(1, requests.size)
        assertEquals(
            "https://api.mdblist.com/imdb/movie/tt1/?apikey=key&append_to_response=keyword",
            requests.single().first,
        )
    }

    @Test
    fun changingProvidersReadsTheCachedResponseInTheRequestedOrder() = runBlocking {
        val repository = repository()

        assertEquals(listOf("imdb"), repository.getRatings("movie", "tt1", key, listOf("imdb")).map { it.source })
        val reordered = repository.getRatings("movie", "tt1", key, listOf("audience", "imdb"))

        assertEquals(listOf("audience", "imdb"), reordered.map { it.source })
        assertEquals(1, requests.size)
    }

    @Test
    fun concurrentRequestsForTheSameTitleShareOneLookup() = runBlocking {
        val repository = repository()
        val imdb = async(start = CoroutineStart.UNDISPATCHED) { repository.getRatings("movie", "tt1", key, listOf("imdb")) }
        val tomatoes = async(start = CoroutineStart.UNDISPATCHED) { repository.getRatings("movie", "tt1", key, listOf("tomatoes")) }

        assertEquals("imdb", imdb.await().single().source)
        assertEquals("tomatoes", tomatoes.await().single().source)
        assertEquals(1, requests.size)
    }

    @Test
    fun nearbyTitlesAreBatchedAndMatchedByIdNotByResponseOrder() = runBlocking {
        respond = { batch(listOf("tt2", "tt1")) }
        val repository = repository()
        val results = listOf("tt1", "tt2").map { id ->
            async(start = CoroutineStart.UNDISPATCHED) { id to repository.getRatings("movie", id, key, listOf("imdb")).single().value }
        }.awaitAll().toMap()

        assertEquals(1.0, results.getValue("tt1"))
        assertEquals(2.0, results.getValue("tt2"))
        assertEquals(1, requests.size)
        assertEquals(listOf("tt1", "tt2"), requestIds(requireNotNull(requests.single().second)))
    }

    @Test
    fun batchesRespectTheTwoHundredTitleLimit() = runBlocking {
        val repository = repository()
        val all = (1..405).map { index ->
            async(start = CoroutineStart.UNDISPATCHED) { repository.getRatings("movie", "tt$index", key, listOf("imdb")) }
        }.awaitAll()

        assertTrue(all.all { it.size == 1 })
        val sizes = requests.map { requestIds(requireNotNull(it.second)).size }
        assertEquals(listOf(200, 200, 5), sizes)
    }

    @Test
    fun differentMediaTypesUseSeparateBatches() = runBlocking {
        val repository = repository()
        listOf("movie", "show").flatMap { type ->
            listOf("tt1", "tt2").map { id -> async(start = CoroutineStart.UNDISPATCHED) { repository.getRatings(type, id, key, listOf("imdb")) } }
        }.awaitAll()

        assertEquals(
            listOf("https://api.mdblist.com/imdb/movie/?apikey=key", "https://api.mdblist.com/imdb/show/?apikey=key"),
            requests.map { it.first }.sorted(),
        )
    }

    @Test
    fun failedResponsesAreNotCachedSoTheNextOpenRetries() = runBlocking {
        val repository = repository()
        respond = { throw IllegalStateException("Unavailable") }
        assertTrue(repository.getRatings("movie", "tt1", key, providers).isEmpty())
        respond = { "invalid json" }
        assertTrue(repository.getRatings("movie", "tt1", key, providers).isEmpty())
        respond = { media("tt1") }

        assertEquals(3, repository.getRatings("movie", "tt1", key, providers).size)
        assertEquals(3, requests.size)
    }

    @Test
    fun clearingTheCacheForgetsStoredRatings() = runBlocking {
        val repository = repository()
        repository.getRatings("movie", "tt1", key, providers)
        repository.clearCache()
        repository.getRatings("movie", "tt1", key, providers)

        assertEquals(2, requests.size)
    }

    private fun media(id: String, imdb: Int = 1): String =
        """{"imdb_id":"$id","ratings":[
            {"source":"imdb","value":$imdb.0},
            {"source":"tomatoes","value":88},
            {"source":"popcorn","value":91}
        ],"keywords":[{"name":"certified-fresh"}]}"""

    private fun batch(ids: List<String>): String =
        ids.joinToString(prefix = "[", postfix = "]") { id ->
            media(id, imdb = id.removePrefix("tt").toInt() % 10)
        }

    private fun requestIds(body: String): List<String> =
        Json.parseToJsonElement(body).jsonObject.getValue("ids").jsonArray.map { it.jsonPrimitive.content }
}
