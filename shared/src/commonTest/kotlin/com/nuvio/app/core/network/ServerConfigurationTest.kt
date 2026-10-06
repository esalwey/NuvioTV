package com.nuvio.app.core.network

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ServerConfigurationTest {

    private fun configuration(
        backendUrl: String,
        isCustom: Boolean,
        tvLogin: Boolean = true,
    ) = ServerConfiguration(
        backendUrl = backendUrl,
        publishableKey = "key",
        capabilities = ServerCapabilities(emailPasswordAuth = true, tvLogin = tvLogin),
        isCustom = isCustom,
    )

    @Test
    fun officialServerUsesHostedTvLoginPage() {
        val official = configuration("https://api.nuvio.tv", isCustom = false)
        assertEquals(OFFICIAL_TV_LOGIN_WEB_BASE_URL, official.tvLoginWebBaseUrl)
        assertEquals("https://nuvio.tv/tv-login", official.tvLoginWebBaseUrl)
    }

    @Test
    fun customServerDerivesTvLoginPageFromBackend() {
        val custom = configuration("https://backend.example.com", isCustom = true)
        assertEquals("https://backend.example.com/tv-login", custom.tvLoginWebBaseUrl)

        val withPath = configuration("http://192.168.1.10:8000/supabase", isCustom = true)
        assertEquals("http://192.168.1.10:8000/supabase/tv-login", withPath.tvLoginWebBaseUrl)
    }

    @Test
    fun displayHostOmitsDefaultPortAndPath() {
        assertEquals("backend.example.com", configuration("https://backend.example.com/supabase", isCustom = true).displayHost)
        assertEquals("backend.example.com", configuration("https://backend.example.com:443", isCustom = true).displayHost)
        assertEquals("example.com", configuration("http://example.com:80", isCustom = true).displayHost)
    }

    @Test
    fun displayHostKeepsNonDefaultPort() {
        assertEquals("192.168.1.10:8000", configuration("http://192.168.1.10:8000", isCustom = true).displayHost)
        assertEquals("backend.example.com:8443", configuration("https://backend.example.com:8443/x", isCustom = true).displayHost)
    }

    @Test
    fun displayHostFallsBackToRawUrlWhenUnparsable() {
        assertEquals("not a url", configuration("not a url", isCustom = true).displayHost)
        assertEquals("", configuration("", isCustom = true).displayHost)
    }

    @Test
    fun isSecureReflectsScheme() {
        assertTrue(configuration("https://backend.example.com", isCustom = true).isSecure)
        assertTrue(configuration("HTTPS://backend.example.com", isCustom = true).isSecure)
        assertFalse(configuration("http://backend.example.com", isCustom = true).isSecure)
    }

    @Test
    fun officialConfigurationAdvertisesBothAuthCapabilities() {
        val official = officialConfiguration()
        assertFalse(official.isCustom)
        assertTrue(official.capabilities.emailPasswordAuth)
        assertTrue(official.capabilities.tvLogin)
        assertEquals(OFFICIAL_TV_LOGIN_WEB_BASE_URL, official.tvLoginWebBaseUrl)
    }

    @Test
    fun publicHostClassificationDistinguishesPrivateNetworks() {
        assertFalse(isPublicServerHost("http://localhost:8000"))
        assertFalse(isPublicServerHost("http://server.local"))
        assertFalse(isPublicServerHost("http://127.0.0.1"))
        assertFalse(isPublicServerHost("http://10.0.0.5"))
        assertFalse(isPublicServerHost("http://192.168.1.10:8000"))
        assertFalse(isPublicServerHost("http://172.16.0.1"))
        assertFalse(isPublicServerHost("http://172.20.0.5"))
        assertFalse(isPublicServerHost("http://172.31.255.254"))
        assertFalse(isPublicServerHost("http://169.254.1.1"))
        assertTrue(isPublicServerHost("http://172.15.0.1"))
        assertTrue(isPublicServerHost("http://172.32.0.1"))
        assertTrue(isPublicServerHost("https://backend.example.com"))
        assertTrue(isPublicServerHost("https://8.8.8.8"))
    }

    @Test
    fun publicHostFlagOnConfigurationMatchesHelper() {
        assertFalse(configuration("http://192.168.1.10:8000", isCustom = true).isPublicHost)
        assertTrue(configuration("https://backend.example.com", isCustom = true).isPublicHost)
    }
}
