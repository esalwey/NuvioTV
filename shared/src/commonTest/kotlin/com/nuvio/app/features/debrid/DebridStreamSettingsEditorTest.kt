package com.nuvio.app.features.debrid

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DebridStreamSettingsEditorTest {
    private val defaults = DebridStreamPreferences()

    @Test
    fun `rule categories expose every enum value in canonical order`() {
        assertEquals(
            listOf("resolution", "quality", "visual_tag", "audio_tag", "audio_channel", "encode", "language"),
            DebridStreamSettingsEditor.ruleCategoryIds(),
        )
        assertEquals(
            DebridStreamResolution.defaultOrder.map { it.name },
            DebridStreamSettingsEditor.ruleOptions("resolution").map { it.id },
        )
        assertEquals(
            DebridStreamLanguage.entries.map { it.name },
            DebridStreamSettingsEditor.ruleOptions("language").map { it.id },
        )
        assertTrue(DebridStreamSettingsEditor.ruleOptions("nope").isEmpty())
    }

    @Test
    fun `selection round trips and is stored in canonical order`() {
        val updated = DebridStreamSettingsEditor.withRuleSelection(
            preferences = defaults,
            categoryId = "resolution",
            modeId = "required",
            ids = listOf("P720", "P2160"),
        )

        assertEquals(listOf(DebridStreamResolution.P2160, DebridStreamResolution.P720), updated.requiredResolutions)
        assertEquals(
            listOf("P2160", "P720"),
            DebridStreamSettingsEditor.ruleSelection(updated, "resolution", "required"),
        )
        // The other lists are untouched.
        assertEquals(defaults.excludedResolutions, updated.excludedResolutions)
        assertEquals(defaults.preferredResolutions, updated.preferredResolutions)
    }

    @Test
    fun `emptying a preferred list restores the default order but not a required one`() {
        val preferred = DebridStreamSettingsEditor.withRuleSelection(defaults, "quality", "preferred", emptyList())
        assertEquals(DebridStreamQuality.defaultOrder, preferred.preferredQualities)

        val required = DebridStreamSettingsEditor.withRuleSelection(
            defaults.copy(requiredQualities = listOf(DebridStreamQuality.WEB_DL)),
            "quality",
            "required",
            emptyList(),
        )
        assertTrue(required.requiredQualities.isEmpty())
    }

    @Test
    fun `preferred languages may be emptied`() {
        val withPreferred = DebridStreamSettingsEditor.withRuleSelection(defaults, "language", "preferred", listOf("FR", "EN"))
        assertEquals(listOf(DebridStreamLanguage.EN, DebridStreamLanguage.FR), withPreferred.preferredLanguages)

        val cleared = DebridStreamSettingsEditor.withRuleSelection(withPreferred, "language", "preferred", emptyList())
        assertTrue(cleared.preferredLanguages.isEmpty())
    }

    @Test
    fun `unknown category or mode leaves preferences alone`() {
        assertEquals(defaults, DebridStreamSettingsEditor.withRuleSelection(defaults, "nope", "required", listOf("X")))
        assertEquals(defaults, DebridStreamSettingsEditor.withRuleSelection(defaults, "encode", "nope", listOf("AV1")))
        assertTrue(DebridStreamSettingsEditor.ruleSelection(defaults, "nope", "required").isEmpty())
    }

    @Test
    fun `release groups are trimmed and deduplicated`() {
        val updated = DebridStreamSettingsEditor.withReleaseGroups(
            preferences = defaults,
            modeId = "excluded",
            groups = listOf(" YIFY ", "YIFY", "", "RARBG"),
        )

        assertEquals(listOf("YIFY", "RARBG"), DebridStreamSettingsEditor.releaseGroups(updated, "excluded"))
        assertTrue(DebridStreamSettingsEditor.releaseGroups(updated, "required").isEmpty())
        assertTrue(DebridStreamSettingsEditor.releaseGroups(updated, "preferred").isEmpty())
    }

    @Test
    fun `sort profiles round trip`() {
        assertEquals("ORIGINAL", DebridStreamSettingsEditor.sortProfileId(defaults))
        for (id in DebridStreamSettingsEditor.sortProfileIds()) {
            val updated = DebridStreamSettingsEditor.withSortProfile(defaults, id)
            assertEquals(id, DebridStreamSettingsEditor.sortProfileId(updated))
        }
        assertEquals(
            DebridStreamSortCriterion.defaultOrder,
            DebridStreamSettingsEditor.withSortProfile(defaults, "BEST_QUALITY").sortCriteria,
        )
    }

    @Test
    fun `dolby vision and hdr filters read back from the rule lists`() {
        assertEquals("ANY", DebridStreamSettingsEditor.dolbyVisionFilterId(defaults))
        assertEquals("ANY", DebridStreamSettingsEditor.hdrFilterId(defaults))

        val noDv = defaults.copy(
            excludedVisualTags = listOf(DebridStreamVisualTag.DV, DebridStreamVisualTag.DV_ONLY, DebridStreamVisualTag.HDR_DV),
        )
        assertEquals("EXCLUDE", DebridStreamSettingsEditor.dolbyVisionFilterId(noDv))
        assertEquals("ANY", DebridStreamSettingsEditor.hdrFilterId(noDv))

        val onlyHdr = defaults.copy(
            requiredVisualTags = listOf(
                DebridStreamVisualTag.HDR,
                DebridStreamVisualTag.HDR10,
                DebridStreamVisualTag.HDR10_PLUS,
                DebridStreamVisualTag.HLG,
                DebridStreamVisualTag.HDR_ONLY,
                DebridStreamVisualTag.HDR_DV,
            ),
        )
        assertEquals("ONLY", DebridStreamSettingsEditor.hdrFilterId(onlyHdr))
        assertEquals("ANY", DebridStreamSettingsEditor.dolbyVisionFilterId(onlyHdr))
    }

    @Test
    fun `codec and minimum quality read back from the rule lists`() {
        assertEquals("ANY", DebridStreamSettingsEditor.codecFilterId(defaults))
        assertEquals("HEVC", DebridStreamSettingsEditor.codecFilterId(defaults.copy(requiredEncodes = listOf(DebridStreamEncode.HEVC))))
        assertEquals("H264", DebridStreamSettingsEditor.codecFilterId(defaults.copy(requiredEncodes = listOf(DebridStreamEncode.AVC))))
        assertEquals(
            DebridStreamSettingsEditor.CUSTOM,
            DebridStreamSettingsEditor.codecFilterId(
                defaults.copy(requiredEncodes = listOf(DebridStreamEncode.HEVC, DebridStreamEncode.AV1)),
            ),
        )

        assertEquals("ANY", DebridStreamSettingsEditor.minimumQualityId(defaults))
        // "Any" as the repository stores it (every known resolution) is still "Any".
        assertEquals(
            "ANY",
            DebridStreamSettingsEditor.minimumQualityId(
                defaults.copy(requiredResolutions = resolutionsForMinimumQuality(DebridStreamMinimumQuality.ANY)),
            ),
        )
        assertEquals(
            "P1080",
            DebridStreamSettingsEditor.minimumQualityId(
                defaults.copy(requiredResolutions = resolutionsForMinimumQuality(DebridStreamMinimumQuality.P1080)),
            ),
        )
        assertEquals(
            DebridStreamSettingsEditor.CUSTOM,
            DebridStreamSettingsEditor.minimumQualityId(defaults.copy(requiredResolutions = listOf(DebridStreamResolution.P576))),
        )
    }

    @Test
    fun `template kind distinguishes original default and custom`() {
        val default = DebridStreamSettingsEditor.defaultNameTemplate()
        assertEquals("original", DebridStreamSettingsEditor.templateKind("", default))
        assertEquals("original", DebridStreamSettingsEditor.templateKind("   ", default))
        assertEquals("default", DebridStreamSettingsEditor.templateKind(default, default))
        assertEquals("custom", DebridStreamSettingsEditor.templateKind("{stream.title}", default))
        // The shipped description template is blank, which reads as the original text.
        assertEquals(
            "original",
            DebridStreamSettingsEditor.templateKind(
                DebridStreamSettingsEditor.defaultDescriptionTemplate(),
                DebridStreamSettingsEditor.defaultDescriptionTemplate(),
            ),
        )
    }

    @Test
    fun `template preview renders the shipped name template and a multi line description`() {
        assertEquals(
            "2160p TB Instant",
            DebridStreamSettingsEditor.previewName(DebridStreamSettingsEditor.defaultNameTemplate()),
        )
        assertEquals(
            "Dune: Part Two (2024)\nHDR10 | DV",
            DebridStreamSettingsEditor.previewDescription(
                "{stream.title} ({stream.year})\n\n{stream.visualTags::join(' | ')}\n   \n",
            ),
        )
        assertEquals("", DebridStreamSettingsEditor.previewDescription(""))
    }

    @Test
    fun `template variables include the documented placeholders`() {
        val variables = DebridStreamSettingsEditor.templateVariables()
        assertTrue("stream.resolution" in variables)
        assertTrue("service.shortName" in variables)
        assertTrue("addon.name" in variables)
    }
}
