package com.nuvio.app.core.network

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ServerDiscoveryPolicyTest {

    private fun document(
        version: Int = 1,
        service: String = "nuvio",
        selfHosted: Boolean = true,
        backendUrl: String = "https://backend.example.com/",
        publishableKey: String = "public-key",
        capabilities: String = """{ "email_password_auth": true, "tv_login": true }""",
    ): String = """
        {
          "version": $version,
          "service": "$service",
          "self_hosted": $selfHosted,
          "backend_url": "$backendUrl",
          "publishable_key": "$publishableKey",
          "capabilities": $capabilities
        }
    """.trimIndent()

    private fun parseFailure(
        document: String,
        requirement: ServerAuthRequirement = ServerAuthRequirement.EmailPassword,
    ): ServerDiscoveryFailure =
        assertFailsWith<ServerDiscoveryException> {
            ServerDiscoveryPolicy.parse("https://example.com/.well-known/nuvio", document, requirement)
        }.failure

    // ── discoveryUrl ──────────────────────────────────────────────────────────────────────────

    @Test
    fun discoveryUrlAddsSchemeAndKnownPath() {
        assertEquals(
            "https://backend.example.com/.well-known/nuvio",
            ServerDiscoveryPolicy.discoveryUrl("backend.example.com"),
        )
    }

    @Test
    fun discoveryUrlStripsTrailingSlashAndTrimsInput() {
        assertEquals(
            "https://backend.example.com/.well-known/nuvio",
            ServerDiscoveryPolicy.discoveryUrl("  https://backend.example.com/  "),
        )
    }

    @Test
    fun discoveryUrlPreservesBackendPathAndIsIdempotent() {
        assertEquals(
            "https://example.com/backend/.well-known/nuvio",
            ServerDiscoveryPolicy.discoveryUrl("https://example.com/backend/.well-known/nuvio"),
        )
        assertEquals(
            "https://example.com/backend/.well-known/nuvio",
            ServerDiscoveryPolicy.discoveryUrl("https://example.com/backend/"),
        )
    }

    @Test
    fun discoveryUrlKeepsNonDefaultPortAndHttp() {
        assertEquals(
            "http://192.168.1.10:8000/.well-known/nuvio",
            ServerDiscoveryPolicy.discoveryUrl("http://192.168.1.10:8000"),
        )
        assertEquals(
            "https://example.com/.well-known/nuvio",
            ServerDiscoveryPolicy.discoveryUrl("https://example.com:443"),
        )
    }

    @Test
    fun discoveryUrlRejectsUserInfoBlankAndNonHttp() {
        val withUserInfo = assertFailsWith<ServerDiscoveryException> {
            ServerDiscoveryPolicy.discoveryUrl("https://user:secret@example.com")
        }
        assertEquals(ServerDiscoveryFailure.InvalidUrl, withUserInfo.failure)

        val blank = assertFailsWith<ServerDiscoveryException> { ServerDiscoveryPolicy.discoveryUrl("   ") }
        assertEquals(ServerDiscoveryFailure.InvalidUrl, blank.failure)

        val ftp = assertFailsWith<ServerDiscoveryException> { ServerDiscoveryPolicy.discoveryUrl("ftp://example.com") }
        assertEquals(ServerDiscoveryFailure.InvalidUrl, ftp.failure)
    }

    // ── parse ─────────────────────────────────────────────────────────────────────────────────

    @Test
    fun parseAcceptsVersionOneDocument() {
        val configuration = ServerDiscoveryPolicy.parse(
            discoveryUrl = "https://example.com/.well-known/nuvio",
            document = document(),
        )

        assertEquals("https://backend.example.com", configuration.backendUrl)
        assertEquals("public-key", configuration.publishableKey)
        assertTrue(configuration.isCustom)
        assertTrue(configuration.capabilities.emailPasswordAuth)
        assertTrue(configuration.capabilities.tvLogin)
        assertEquals("https://example.com/.well-known/nuvio", configuration.discoveryUrl)
    }

    @Test
    fun parseIgnoresUnknownKeysAndKeepsBackendPath() {
        val configuration = ServerDiscoveryPolicy.parse(
            discoveryUrl = "https://example.com/.well-known/nuvio",
            document = """
                {
                  "version": 1,
                  "service": "Nuvio",
                  "self_hosted": true,
                  "backend_url": " https://example.com:8443/supabase/ ",
                  "publishable_key": " key ",
                  "capabilities": { "email_password_auth": true, "future": 1 },
                  "extra": "ignored"
                }
            """.trimIndent(),
        )
        assertEquals("https://example.com:8443/supabase", configuration.backendUrl)
        assertEquals("key", configuration.publishableKey)
        assertFalse(configuration.capabilities.tvLogin)
    }

    @Test
    fun parseRejectsUnsupportedVersion() {
        assertEquals(ServerDiscoveryFailure.UnsupportedVersion, parseFailure(document(version = 2)))
    }

    @Test
    fun parseRejectsWrongService() {
        assertEquals(ServerDiscoveryFailure.WrongService, parseFailure(document(service = "other")))
    }

    @Test
    fun parseRejectsNotSelfHosted() {
        assertEquals(ServerDiscoveryFailure.NotSelfHosted, parseFailure(document(selfHosted = false)))
    }

    @Test
    fun parseRejectsBlankPublishableKey() {
        assertEquals(ServerDiscoveryFailure.MissingConfiguration, parseFailure(document(publishableKey = "   ")))
    }

    @Test
    fun parseRejectsBackendWithQueryFragmentOrUserInfo() {
        assertEquals(
            ServerDiscoveryFailure.MissingConfiguration,
            parseFailure(document(backendUrl = "https://backend.example.com/?x=1")),
        )
        assertEquals(
            ServerDiscoveryFailure.MissingConfiguration,
            parseFailure(document(backendUrl = "https://backend.example.com/#frag")),
        )
        assertEquals(
            ServerDiscoveryFailure.MissingConfiguration,
            parseFailure(document(backendUrl = "https://user@backend.example.com")),
        )
    }

    @Test
    fun parseRejectsMalformedJson() {
        assertEquals(ServerDiscoveryFailure.InvalidDocument, parseFailure("{ not json"))
        assertEquals(ServerDiscoveryFailure.InvalidDocument, parseFailure("""{ "version": 1 }"""))
    }

    // ── auth requirement matrix ───────────────────────────────────────────────────────────────

    @Test
    fun emailPasswordRequirementRejectsTvLoginOnlyServer() {
        val tvLoginOnly = document(capabilities = """{ "email_password_auth": false, "tv_login": true }""")
        assertEquals(
            ServerDiscoveryFailure.UnsupportedAuthentication,
            parseFailure(tvLoginOnly, ServerAuthRequirement.EmailPassword),
        )
    }

    @Test
    fun emailPasswordOrTvLoginRequirementAcceptsTvLoginOnlyServer() {
        val tvLoginOnly = document(capabilities = """{ "email_password_auth": false, "tv_login": true }""")
        val configuration = ServerDiscoveryPolicy.parse(
            discoveryUrl = "https://example.com/.well-known/nuvio",
            document = tvLoginOnly,
            requirement = ServerAuthRequirement.EmailPasswordOrTvLogin,
        )
        assertFalse(configuration.capabilities.emailPasswordAuth)
        assertTrue(configuration.capabilities.tvLogin)
        assertEquals("https://backend.example.com/tv-login", configuration.tvLoginWebBaseUrl)
    }

    @Test
    fun bothRequirementsRejectServerWithNeitherCapability() {
        val neither = document(capabilities = "{}")
        assertEquals(
            ServerDiscoveryFailure.UnsupportedAuthentication,
            parseFailure(neither, ServerAuthRequirement.EmailPassword),
        )
        assertEquals(
            ServerDiscoveryFailure.UnsupportedAuthentication,
            parseFailure(neither, ServerAuthRequirement.EmailPasswordOrTvLogin),
        )
    }

    @Test
    fun emailPasswordOnlyServerSatisfiesBothRequirements() {
        val emailOnly = document(capabilities = """{ "email_password_auth": true }""")
        for (requirement in ServerAuthRequirement.entries) {
            val configuration = ServerDiscoveryPolicy.parse("https://example.com/.well-known/nuvio", emailOnly, requirement)
            assertTrue(configuration.capabilities.emailPasswordAuth)
            assertFalse(configuration.capabilities.tvLogin)
        }
    }

    // ── isOfficial ────────────────────────────────────────────────────────────────────────────

    @Test
    fun isOfficialMatchesCanonicalBackendByHostAndPort() {
        assertTrue(ServerDiscoveryPolicy.isOfficial("https://api.nuvio.tv/.well-known/nuvio"))
        assertTrue(ServerDiscoveryPolicy.isOfficial("https://API.NUVIO.TV"))
        assertFalse(ServerDiscoveryPolicy.isOfficial("https://api.nuvio.tv.example.com/.well-known/nuvio"))
        assertFalse(ServerDiscoveryPolicy.isOfficial("https://api.nuvio.tv:8443/.well-known/nuvio"))
        assertFalse(ServerDiscoveryPolicy.isOfficial("https://backend.example.com/.well-known/nuvio"))
    }
}
