package com.nuvio.app.features.plugins

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PluginRepositoryInputTest {

    @Test
    fun shortCodesAreBareWords() {
        assertTrue(PluginRepositoryInput.isShortCode("cspr"))
        assertTrue(PluginRepositoryInput.isShortCode("  0094 "))
        assertTrue(PluginRepositoryInput.isShortCode("mega-repo_2"))
    }

    @Test
    fun urlsAndDomainsAreNotShortCodes() {
        assertFalse(PluginRepositoryInput.isShortCode(""))
        assertFalse(PluginRepositoryInput.isShortCode("   "))
        assertFalse(PluginRepositoryInput.isShortCode("https://example.com/manifest.json"))
        assertFalse(PluginRepositoryInput.isShortCode("example.com"))
        assertFalse(PluginRepositoryInput.isShortCode("raw.githubusercontent.com/a/b"))
        assertFalse(PluginRepositoryInput.isShortCode("user/repo"))
        assertFalse(PluginRepositoryInput.isShortCode("two words"))
    }

    @Test
    fun shortCodeUrlTrimsTheCode() {
        assertEquals("https://cutt.ly/cspr", PluginRepositoryInput.shortCodeUrl(" cspr "))
    }

    @Test
    fun redirectLocationBecomesAnHttpsRepositoryUrl() {
        assertEquals(
            "https://raw.githubusercontent.com/a/b/main/manifest.json",
            PluginRepositoryInput.repositoryUrlFromRedirect("http://raw.githubusercontent.com/a/b/main/manifest.json"),
        )
        assertEquals(
            "https://example.com/repo",
            PluginRepositoryInput.repositoryUrlFromRedirect("example.com/repo"),
        )
        assertEquals(
            "https://example.com/repo",
            PluginRepositoryInput.repositoryUrlFromRedirect(" https://example.com/repo "),
        )
    }

    @Test
    fun redirectLocationThatIsNotARepositoryIsRefused() {
        assertNull(PluginRepositoryInput.repositoryUrlFromRedirect(null))
        assertNull(PluginRepositoryInput.repositoryUrlFromRedirect("  "))
        assertNull(PluginRepositoryInput.repositoryUrlFromRedirect("ftp://example.com/x"))
        assertNull(PluginRepositoryInput.repositoryUrlFromRedirect("https://cutt.ly/404"))
        assertNull(PluginRepositoryInput.repositoryUrlFromRedirect("https://www.cutt.ly/x"))
    }
}
