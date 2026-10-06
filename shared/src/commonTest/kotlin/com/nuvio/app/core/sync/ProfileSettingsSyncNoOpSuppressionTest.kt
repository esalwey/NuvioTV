package com.nuvio.app.core.sync

import co.touchlab.kermit.Logger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * H-1B-i: [applyFeatureUnlessUnchanged] is the shared no-op suppression the theme/poster/card-depth
 * blocks in `ProfileSettingsSync.applyRemoteBlob()` route through. `applyRemoteBlob()` itself isn't
 * exercised here — it needs a live remote pull (Supabase RPC + ProfileRepository state) to reach,
 * which is heavy scaffolding for what is really a pure comparison — so this tests the helper
 * directly: identical payloads must skip both `apply` and `notifyChanged`, and anything that
 * differs at the raw serialized level (including a payload that merely has a different shape, not
 * just different values) must still run both, exactly like today.
 */
class ProfileSettingsSyncNoOpSuppressionTest {
    private val log = Logger.withTag("ProfileSettingsSyncNoOpSuppressionTest")

    @Test
    fun `identical JsonObject payloads skip apply and notify`() {
        val current = buildJsonObject { put("selected_theme", JsonPrimitive("crimson")) }
        val incoming = buildJsonObject { put("selected_theme", JsonPrimitive("crimson")) }
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "theme_settings",
            current = current,
            incoming = incoming,
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertFalse(applied, "apply() must not run for a byte-identical payload")
        assertFalse(notified, "notifyChanged() must not fan out for a byte-identical payload")
    }

    @Test
    fun `different JsonObject payloads still apply and notify`() {
        val current = buildJsonObject { put("selected_theme", JsonPrimitive("crimson")) }
        val incoming = buildJsonObject { put("selected_theme", JsonPrimitive("ocean")) }
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "theme_settings",
            current = current,
            incoming = incoming,
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertTrue(applied, "a genuinely different remote payload must still apply")
        assertTrue(notified, "a genuinely different remote payload must still fan out")
    }

    /**
     * A payload that only has a DIFFERENT SHAPE (extra/missing key), not different values on the
     * shared keys, must still read as "changed" — this is the guard against comparing
     * decoded/parsed fields instead of the raw exported representation. A writing client on a
     * different schema (e.g. one that doesn't model `nav_bar_style`) must never be mistaken for a
     * no-op.
     */
    @Test
    fun `payloads that differ only in shape still apply and notify`() {
        val current = buildJsonObject { put("selected_theme", JsonPrimitive("crimson")) }
        val incoming = buildJsonObject {
            put("selected_theme", JsonPrimitive("crimson"))
            put("nav_bar_style", JsonPrimitive("floating"))
        }
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "theme_settings",
            current = current,
            incoming = incoming,
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertTrue(applied, "a schema difference must never read as unchanged")
        assertTrue(notified, "a schema difference must never read as unchanged")
    }

    @Test
    fun `identical string payloads skip apply and notify`() {
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "poster_card_style_settings_payload",
            current = "v2:rounded",
            incoming = "v2:rounded",
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertFalse(applied)
        assertFalse(notified)
    }

    @Test
    fun `different string payloads still apply and notify`() {
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "card_depth_style_settings_payload",
            current = "v1:flat",
            incoming = "v1:elevated",
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertTrue(applied)
        assertTrue(notified)
    }

    @Test
    fun `identical Boolean payloads skip apply and notify`() {
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "notifications_settings",
            current = true,
            incoming = true,
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertFalse(applied)
        assertFalse(notified)
    }

    @Test
    fun `different Boolean payloads still apply and notify`() {
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "notifications_settings",
            current = false,
            incoming = true,
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertTrue(applied)
        assertTrue(notified)
    }

    @Test
    fun `forceApply bypasses the comparison and always applies even for identical payloads`() {
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "player_settings",
            current = "same",
            incoming = "same",
            forceApply = true,
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertTrue(applied, "forceApply=true must apply even when current == incoming")
        assertTrue(notified, "forceApply=true must notify even when current == incoming")
    }

    /**
     * The shape the four credential-bearing feature blocks in `applyRemoteBlob()` actually use:
     * [current]/[incoming] are the CREDENTIAL-STRIPPED payloads (a raw compare would rarely
     * suppress, since one side usually already lacks the credential the other carries), and
     * `forceApply` is driven by whether the RAW incoming payload still carries a credential — the
     * one-time legacy-blob migration import (`preservingLocalProfileCredentials`) must still run
     * even when the stripped settings themselves are unchanged.
     */
    @Test
    fun `credential-bearing feature force-applies when the incoming payload still carries a credential even if the stripped settings match`() {
        val current = buildJsonObject { put("mode", JsonPrimitive("auto")) }
        val incomingWithCredential = buildJsonObject {
            put("mode", JsonPrimitive("auto"))
            put("tmdb_api_key", JsonPrimitive("secret-key"))
        }
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "tmdb_settings",
            current = withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, current),
            incoming = withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, incomingWithCredential),
            forceApply = incomingWithCredential != withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, incomingWithCredential),
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertTrue(applied, "a payload that still carries a credential must apply even when the stripped settings match")
        assertTrue(notified)
    }

    @Test
    fun `credential-bearing feature skips when stripped settings match and neither side carries a credential`() {
        val current = buildJsonObject { put("mode", JsonPrimitive("auto")) }
        val incoming = buildJsonObject { put("mode", JsonPrimitive("auto")) }
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "tmdb_settings",
            current = withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, current),
            incoming = withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, incoming),
            forceApply = incoming != withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, incoming),
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertFalse(applied, "unchanged stripped settings with no credential in the incoming payload must skip")
        assertFalse(notified)
    }

    @Test
    fun `trimmed string payloads that differ only in whitespace skip apply and notify`() {
        var applied = false
        var notified = false

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "meta_screen_settings_payload",
            current = "v1:default".trim(),
            incoming = "  v1:default  ".trim(),
            apply = { applied = true },
            notifyChanged = { notified = true },
        )

        assertFalse(applied, "the four string-payload blocks compare TRIMMED — pure whitespace must never read as changed")
        assertFalse(notified)
    }

    @Test
    fun `apply and notify each run exactly once for a changed payload`() {
        var applyCount = 0
        var notifyCount = 0

        applyFeatureUnlessUnchanged(
            log = log,
            featureName = "theme_settings",
            current = "a",
            incoming = "b",
            apply = { applyCount++ },
            notifyChanged = { notifyCount++ },
        )

        assertEquals(1, applyCount)
        assertEquals(1, notifyCount)
    }
}
