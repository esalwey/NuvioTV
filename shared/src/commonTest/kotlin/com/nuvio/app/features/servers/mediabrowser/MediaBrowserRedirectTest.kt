package com.nuvio.app.features.servers.mediabrowser

import com.nuvio.app.features.servers.jellyfin.JellyfinProvider
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals

class MediaBrowserRedirectTest {
    private val authResponse = """{"User": {"Id": "u1", "Name": "viewer"}, "AccessToken": "tok", "ServerId": "srv"}"""
    private val infoResponse = """{"ServerName": "Den", "Version": "10.10.7", "Id": "srv"}"""

    /** Android reports the 3xx itself: sign-in must continue against the address the Location points at. */
    @Test
    fun followsAnHttpToHttpsRedirectReportedByThePlatform() = runBlocking<Unit> {
        val requests = mutableListOf<String>()
        val transport = object : MediaBrowserTransport {
            override suspend fun send(request: MediaBrowserRequest): ApiResponse {
                requests += request.url
                return when (request.url) {
                    "http://den.local/System/Info/Public" ->
                        ApiResponse(301, "", location = "https://den.local/System/Info/Public")
                    "https://den.local/System/Info/Public" -> ApiResponse(200, infoResponse, null)
                    "https://den.local/Users/AuthenticateByName" -> ApiResponse(200, authResponse, null)
                    else -> error("Unexpected ${request.url}")
                }
            }
        }

        val signIn = JellyfinProvider(transport).signIn("den.local", "viewer", "pw")

        assertEquals("https://den.local", signIn.address)
        assertEquals(
            listOf(
                "http://den.local/System/Info/Public",
                "https://den.local/System/Info/Public",
                "https://den.local/Users/AuthenticateByName",
            ),
            requests,
        )
    }

    /** Apple's HTTP stack follows redirects on its own and only reports where the request landed. */
    @Test
    fun adoptsTheAddressAPlatformFollowedRedirectLandedOn() = runBlocking<Unit> {
        val transport = object : MediaBrowserTransport {
            override suspend fun send(request: MediaBrowserRequest): ApiResponse = when {
                request.url.endsWith("/System/Info/Public") ->
                    ApiResponse(200, infoResponse, null, finalUrl = "https://den.local/System/Info/Public")
                request.url.endsWith("/Users/AuthenticateByName") -> ApiResponse(200, authResponse, null)
                else -> error("Unexpected ${request.url}")
            }
        }

        val signIn = JellyfinProvider(transport).signIn("http://den.local:8096", "viewer", "pw")

        assertEquals("https://den.local", signIn.address)
    }

    @Test
    fun mapsTransportFailuresToUnreachable() = runBlocking<Unit> {
        val transport = object : MediaBrowserTransport {
            override suspend fun send(request: MediaBrowserRequest): ApiResponse = throw RuntimeException("offline")
        }

        val failure = runCatching { JellyfinProvider(transport).signIn("den.local", "viewer", "pw") }.exceptionOrNull()

        assertEquals(
            com.nuvio.app.features.servers.ServerFailure.UNREACHABLE,
            (failure as com.nuvio.app.features.servers.ServerException).failure,
        )
    }

    @Test
    fun mapsAnHtmlAnswerToAFailureInsteadOfCrashing() = runBlocking<Unit> {
        val transport = object : MediaBrowserTransport {
            override suspend fun send(request: MediaBrowserRequest): ApiResponse = ApiResponse(200, "<html>login</html>", null)
        }

        val failure = runCatching { JellyfinProvider(transport).signIn("den.local", "viewer", "pw") }.exceptionOrNull()

        assertEquals(
            com.nuvio.app.features.servers.ServerFailure.FAILED,
            (failure as com.nuvio.app.features.servers.ServerException).failure,
        )
    }
}
