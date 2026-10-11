package com.nuvio.app.features.debrid

/**
 * One selectable value of a rule list (resolution, quality, tag, ...). [id] is the Kotlin enum
 * name, stable across releases; [label] is the technical English label ("BluRay REMUX", "HDR10+").
 */
data class DebridChoice(
    val id: String,
    val label: String,
)

/**
 * Native-UI facade over [DebridStreamPreferences] / the legacy stream filter fields.
 *
 * The Apple TV settings screens only deal in strings, ints and lists so they never have to build
 * the 30-field preferences data class or spell Kotlin enum cases. Everything routes through
 * [DebridSettingsRepository], so persistence and the profile sync blob are unchanged.
 *
 * Reads are pure functions of a [DebridStreamPreferences] snapshot (unit-tested in commonTest);
 * the `set*` functions read the repository snapshot, apply one change and store it back.
 */
object DebridStreamSettingsEditor {

    // region rule lists (preferred / required / excluded)

    private enum class RuleMode(val id: String) {
        PREFERRED("preferred"),
        REQUIRED("required"),
        EXCLUDED("excluded"),
        ;

        companion object {
            fun from(id: String): RuleMode? = entries.firstOrNull { it.id == id }
        }
    }

    private class RuleSpec<T : Any>(
        val id: String,
        val all: List<T>,
        val idOf: (T) -> String,
        val labelOf: (T) -> String,
        val read: (DebridStreamPreferences, RuleMode) -> List<T>,
        val write: (DebridStreamPreferences, RuleMode, List<T>) -> DebridStreamPreferences,
        /** Preferred lists fall back to the default order when emptied; languages have none. */
        val preferredFallback: List<T>?,
    ) {
        fun choices(): List<DebridChoice> = all.map { DebridChoice(idOf(it), labelOf(it)) }

        fun selection(preferences: DebridStreamPreferences, mode: RuleMode): List<String> =
            read(preferences, mode).map(idOf)

        fun withSelection(
            preferences: DebridStreamPreferences,
            mode: RuleMode,
            ids: List<String>,
        ): DebridStreamPreferences {
            // Canonical order, whatever order the UI sent: "preferred" is "selected first, in
            // the default order" (the wording of the setting).
            var selected = all.filter { idOf(it) in ids }
            if (mode == RuleMode.PREFERRED && selected.isEmpty()) {
                selected = preferredFallback.orEmpty()
            }
            return write(preferences, mode, selected)
        }
    }

    private val specs: List<RuleSpec<*>> = listOf(
        RuleSpec(
            id = "resolution",
            all = DebridStreamResolution.defaultOrder,
            idOf = { it.name },
            labelOf = { it.label },
            read = { p, m ->
                when (m) {
                    RuleMode.PREFERRED -> p.preferredResolutions
                    RuleMode.REQUIRED -> p.requiredResolutions
                    RuleMode.EXCLUDED -> p.excludedResolutions
                }
            },
            write = { p, m, v ->
                when (m) {
                    RuleMode.PREFERRED -> p.copy(preferredResolutions = v)
                    RuleMode.REQUIRED -> p.copy(requiredResolutions = v)
                    RuleMode.EXCLUDED -> p.copy(excludedResolutions = v)
                }
            },
            preferredFallback = DebridStreamResolution.defaultOrder,
        ),
        RuleSpec(
            id = "quality",
            all = DebridStreamQuality.defaultOrder,
            idOf = { it.name },
            labelOf = { it.label },
            read = { p, m ->
                when (m) {
                    RuleMode.PREFERRED -> p.preferredQualities
                    RuleMode.REQUIRED -> p.requiredQualities
                    RuleMode.EXCLUDED -> p.excludedQualities
                }
            },
            write = { p, m, v ->
                when (m) {
                    RuleMode.PREFERRED -> p.copy(preferredQualities = v)
                    RuleMode.REQUIRED -> p.copy(requiredQualities = v)
                    RuleMode.EXCLUDED -> p.copy(excludedQualities = v)
                }
            },
            preferredFallback = DebridStreamQuality.defaultOrder,
        ),
        RuleSpec(
            id = "visual_tag",
            all = DebridStreamVisualTag.defaultOrder,
            idOf = { it.name },
            labelOf = { it.label },
            read = { p, m ->
                when (m) {
                    RuleMode.PREFERRED -> p.preferredVisualTags
                    RuleMode.REQUIRED -> p.requiredVisualTags
                    RuleMode.EXCLUDED -> p.excludedVisualTags
                }
            },
            write = { p, m, v ->
                when (m) {
                    RuleMode.PREFERRED -> p.copy(preferredVisualTags = v)
                    RuleMode.REQUIRED -> p.copy(requiredVisualTags = v)
                    RuleMode.EXCLUDED -> p.copy(excludedVisualTags = v)
                }
            },
            preferredFallback = DebridStreamVisualTag.defaultOrder,
        ),
        RuleSpec(
            id = "audio_tag",
            all = DebridStreamAudioTag.defaultOrder,
            idOf = { it.name },
            labelOf = { it.label },
            read = { p, m ->
                when (m) {
                    RuleMode.PREFERRED -> p.preferredAudioTags
                    RuleMode.REQUIRED -> p.requiredAudioTags
                    RuleMode.EXCLUDED -> p.excludedAudioTags
                }
            },
            write = { p, m, v ->
                when (m) {
                    RuleMode.PREFERRED -> p.copy(preferredAudioTags = v)
                    RuleMode.REQUIRED -> p.copy(requiredAudioTags = v)
                    RuleMode.EXCLUDED -> p.copy(excludedAudioTags = v)
                }
            },
            preferredFallback = DebridStreamAudioTag.defaultOrder,
        ),
        RuleSpec(
            id = "audio_channel",
            all = DebridStreamAudioChannel.defaultOrder,
            idOf = { it.name },
            labelOf = { it.label },
            read = { p, m ->
                when (m) {
                    RuleMode.PREFERRED -> p.preferredAudioChannels
                    RuleMode.REQUIRED -> p.requiredAudioChannels
                    RuleMode.EXCLUDED -> p.excludedAudioChannels
                }
            },
            write = { p, m, v ->
                when (m) {
                    RuleMode.PREFERRED -> p.copy(preferredAudioChannels = v)
                    RuleMode.REQUIRED -> p.copy(requiredAudioChannels = v)
                    RuleMode.EXCLUDED -> p.copy(excludedAudioChannels = v)
                }
            },
            preferredFallback = DebridStreamAudioChannel.defaultOrder,
        ),
        RuleSpec(
            id = "encode",
            all = DebridStreamEncode.defaultOrder,
            idOf = { it.name },
            labelOf = { it.label },
            read = { p, m ->
                when (m) {
                    RuleMode.PREFERRED -> p.preferredEncodes
                    RuleMode.REQUIRED -> p.requiredEncodes
                    RuleMode.EXCLUDED -> p.excludedEncodes
                }
            },
            write = { p, m, v ->
                when (m) {
                    RuleMode.PREFERRED -> p.copy(preferredEncodes = v)
                    RuleMode.REQUIRED -> p.copy(requiredEncodes = v)
                    RuleMode.EXCLUDED -> p.copy(excludedEncodes = v)
                }
            },
            preferredFallback = DebridStreamEncode.defaultOrder,
        ),
        RuleSpec(
            id = "language",
            all = DebridStreamLanguage.entries.toList(),
            idOf = { it.name },
            labelOf = { it.label },
            read = { p, m ->
                when (m) {
                    RuleMode.PREFERRED -> p.preferredLanguages
                    RuleMode.REQUIRED -> p.requiredLanguages
                    RuleMode.EXCLUDED -> p.excludedLanguages
                }
            },
            write = { p, m, v ->
                when (m) {
                    RuleMode.PREFERRED -> p.copy(preferredLanguages = v)
                    RuleMode.REQUIRED -> p.copy(requiredLanguages = v)
                    RuleMode.EXCLUDED -> p.copy(excludedLanguages = v)
                }
            },
            preferredFallback = null,
        ),
    )

    private fun spec(categoryId: String): RuleSpec<*>? = specs.firstOrNull { it.id == categoryId }

    /** Rule categories in display order: resolution, quality, visual_tag, audio_tag, audio_channel, encode, language. */
    fun ruleCategoryIds(): List<String> = specs.map { it.id }

    /** Every value a category can hold, in the default (canonical) order. */
    fun ruleOptions(categoryId: String): List<DebridChoice> = spec(categoryId)?.choices().orEmpty()

    /** Ids currently stored for [categoryId] in [modeId] ("preferred", "required" or "excluded"). */
    fun ruleSelection(
        preferences: DebridStreamPreferences,
        categoryId: String,
        modeId: String,
    ): List<String> {
        val spec = spec(categoryId) ?: return emptyList()
        val mode = RuleMode.from(modeId) ?: return emptyList()
        return spec.selection(preferences, mode)
    }

    /** [preferences] with the ids of one list replaced (canonical order, preferred never empty). */
    fun withRuleSelection(
        preferences: DebridStreamPreferences,
        categoryId: String,
        modeId: String,
        ids: List<String>,
    ): DebridStreamPreferences {
        val spec = spec(categoryId) ?: return preferences
        val mode = RuleMode.from(modeId) ?: return preferences
        return spec.withSelection(preferences, mode, ids).normalized()
    }

    fun setRuleSelection(categoryId: String, modeId: String, ids: List<String>) {
        val current = DebridSettingsRepository.snapshot().streamPreferences
        DebridSettingsRepository.setStreamPreferences(withRuleSelection(current, categoryId, modeId, ids))
    }

    /** Required ("required") or excluded ("excluded") release groups, as typed by the user. */
    fun releaseGroups(preferences: DebridStreamPreferences, modeId: String): List<String> =
        when (RuleMode.from(modeId)) {
            RuleMode.REQUIRED -> preferences.requiredReleaseGroups
            RuleMode.EXCLUDED -> preferences.excludedReleaseGroups
            else -> emptyList()
        }

    fun withReleaseGroups(
        preferences: DebridStreamPreferences,
        modeId: String,
        groups: List<String>,
    ): DebridStreamPreferences =
        when (RuleMode.from(modeId)) {
            RuleMode.REQUIRED -> preferences.copy(requiredReleaseGroups = groups)
            RuleMode.EXCLUDED -> preferences.copy(excludedReleaseGroups = groups)
            else -> preferences
        }.normalized()

    fun setReleaseGroups(modeId: String, groups: List<String>) {
        val current = DebridSettingsRepository.snapshot().streamPreferences
        DebridSettingsRepository.setStreamPreferences(withReleaseGroups(current, modeId, groups))
    }

    // endregion

    // region sort profile

    fun sortProfileIds(): List<String> = SortProfile.entries.map { it.name }

    fun sortProfileId(preferences: DebridStreamPreferences): String = sortProfileFor(preferences.sortCriteria).name

    fun withSortProfile(preferences: DebridStreamPreferences, profileId: String): DebridStreamPreferences {
        val profile = SortProfile.entries.firstOrNull { it.name == profileId } ?: return preferences
        return preferences.copy(sortCriteria = sortCriteriaFor(profile)).normalized()
    }

    fun setSortProfile(profileId: String) {
        val current = DebridSettingsRepository.snapshot().streamPreferences
        DebridSettingsRepository.setStreamPreferences(withSortProfile(current, profileId))
    }

    private enum class SortProfile {
        ORIGINAL,
        BEST_QUALITY,
        LARGEST,
        SMALLEST,
        AUDIO,
        LANGUAGE,
    }

    private fun sortProfileFor(criteria: List<DebridStreamSortCriterion>): SortProfile {
        val normalized = criteria.map { it.key to it.direction }
        val bestQuality = DebridStreamSortCriterion.defaultOrder.map { it.key to it.direction }
        val legacyQuality = listOf(
            DebridStreamSortKey.RESOLUTION to DebridStreamSortDirection.DESC,
            DebridStreamSortKey.QUALITY to DebridStreamSortDirection.DESC,
            DebridStreamSortKey.SIZE to DebridStreamSortDirection.DESC,
        )
        return when {
            normalized.isEmpty() -> SortProfile.ORIGINAL
            normalized == bestQuality || normalized == legacyQuality -> SortProfile.BEST_QUALITY
            normalized == listOf(DebridStreamSortKey.SIZE to DebridStreamSortDirection.DESC) -> SortProfile.LARGEST
            normalized == listOf(DebridStreamSortKey.SIZE to DebridStreamSortDirection.ASC) -> SortProfile.SMALLEST
            normalized.take(2) == listOf(
                DebridStreamSortKey.AUDIO_TAG to DebridStreamSortDirection.DESC,
                DebridStreamSortKey.AUDIO_CHANNEL to DebridStreamSortDirection.DESC,
            ) -> SortProfile.AUDIO
            normalized.firstOrNull() == DebridStreamSortKey.LANGUAGE to DebridStreamSortDirection.DESC -> SortProfile.LANGUAGE
            else -> SortProfile.BEST_QUALITY
        }
    }

    private fun sortCriteriaFor(profile: SortProfile): List<DebridStreamSortCriterion> =
        when (profile) {
            SortProfile.ORIGINAL -> DebridStreamSortCriterion.originalOrder
            SortProfile.BEST_QUALITY -> DebridStreamSortCriterion.defaultOrder
            SortProfile.LARGEST -> listOf(DebridStreamSortCriterion(DebridStreamSortKey.SIZE, DebridStreamSortDirection.DESC))
            SortProfile.SMALLEST -> listOf(DebridStreamSortCriterion(DebridStreamSortKey.SIZE, DebridStreamSortDirection.ASC))
            SortProfile.AUDIO -> listOf(
                DebridStreamSortCriterion(DebridStreamSortKey.AUDIO_TAG, DebridStreamSortDirection.DESC),
                DebridStreamSortCriterion(DebridStreamSortKey.AUDIO_CHANNEL, DebridStreamSortDirection.DESC),
                DebridStreamSortCriterion(DebridStreamSortKey.RESOLUTION, DebridStreamSortDirection.DESC),
                DebridStreamSortCriterion(DebridStreamSortKey.QUALITY, DebridStreamSortDirection.DESC),
                DebridStreamSortCriterion(DebridStreamSortKey.SIZE, DebridStreamSortDirection.DESC),
            )
            SortProfile.LANGUAGE -> listOf(
                DebridStreamSortCriterion(DebridStreamSortKey.LANGUAGE, DebridStreamSortDirection.DESC),
                DebridStreamSortCriterion(DebridStreamSortKey.RESOLUTION, DebridStreamSortDirection.DESC),
                DebridStreamSortCriterion(DebridStreamSortKey.QUALITY, DebridStreamSortDirection.DESC),
                DebridStreamSortCriterion(DebridStreamSortKey.SIZE, DebridStreamSortDirection.DESC),
            )
        }

    // endregion

    // region limits

    fun setMaxResults(value: Int) {
        DebridSettingsRepository.setStreamMaxResults(value)
    }

    fun setMaxPerResolution(value: Int) {
        val current = DebridSettingsRepository.snapshot().streamPreferences
        DebridSettingsRepository.setStreamPreferences(current.copy(maxPerResolution = value))
    }

    fun setMaxPerQuality(value: Int) {
        val current = DebridSettingsRepository.snapshot().streamPreferences
        DebridSettingsRepository.setStreamPreferences(current.copy(maxPerQuality = value))
    }

    /** [minGb] / [maxGb] of 0 mean "no bound". */
    fun setSizeRange(minGb: Int, maxGb: Int) {
        val current = DebridSettingsRepository.snapshot().streamPreferences
        DebridSettingsRepository.setStreamPreferences(current.copy(sizeMinGb = minGb, sizeMaxGb = maxGb))
    }

    // endregion

    // region one-tap filters (Dolby Vision, HDR, codec, minimum quality)
    //
    // Ids are the enum names of DebridStreamFeatureFilter ("ANY", "EXCLUDE", "ONLY"),
    // DebridStreamCodecFilter ("ANY", "H264", "HEVC", "AV1") and DebridStreamMinimumQuality
    // ("ANY", "P720", "P1080", "P2160"). Codec and minimum quality read back "CUSTOM" when the
    // rule lists were edited to something these shortcuts cannot express. The current state is
    // always derived from the rule lists, because those are what the filter actually applies.

    // The pure DV / HDR tags. HDR+DV belongs to both families and is deliberately left out of
    // the read-back so switching one filter back to "Any" does not make the other one look off.
    private val dolbyVisionCoreTags = listOf(DebridStreamVisualTag.DV, DebridStreamVisualTag.DV_ONLY)
    private val hdrCoreTags = listOf(
        DebridStreamVisualTag.HDR,
        DebridStreamVisualTag.HDR10,
        DebridStreamVisualTag.HDR10_PLUS,
        DebridStreamVisualTag.HLG,
        DebridStreamVisualTag.HDR_ONLY,
    )

    private fun featureFilterId(preferences: DebridStreamPreferences, tags: List<DebridStreamVisualTag>): String =
        when {
            preferences.requiredVisualTags.containsAll(tags) -> DebridStreamFeatureFilter.ONLY.name
            preferences.excludedVisualTags.containsAll(tags) -> DebridStreamFeatureFilter.EXCLUDE.name
            else -> DebridStreamFeatureFilter.ANY.name
        }

    fun dolbyVisionFilterId(preferences: DebridStreamPreferences): String =
        featureFilterId(preferences, dolbyVisionCoreTags)

    fun hdrFilterId(preferences: DebridStreamPreferences): String =
        featureFilterId(preferences, hdrCoreTags)

    fun codecFilterId(preferences: DebridStreamPreferences): String {
        val required = preferences.requiredEncodes
        return when {
            required.isEmpty() -> DebridStreamCodecFilter.ANY.name
            required == listOf(DebridStreamEncode.AVC) -> DebridStreamCodecFilter.H264.name
            required == listOf(DebridStreamEncode.HEVC) -> DebridStreamCodecFilter.HEVC.name
            required == listOf(DebridStreamEncode.AV1) -> DebridStreamCodecFilter.AV1.name
            else -> CUSTOM
        }
    }

    fun minimumQualityId(preferences: DebridStreamPreferences): String {
        val required = preferences.requiredResolutions
        // The repository stores "Any" as every known resolution (UNKNOWN left out); both that and
        // an empty list mean no minimum.
        if (required.isEmpty() || required == resolutionsForMinimumQuality(DebridStreamMinimumQuality.ANY)) {
            return DebridStreamMinimumQuality.ANY.name
        }
        val match = DebridStreamMinimumQuality.entries.firstOrNull {
            it != DebridStreamMinimumQuality.ANY && required == resolutionsForMinimumQuality(it)
        }
        return match?.name ?: CUSTOM
    }

    fun setDolbyVisionFilter(id: String) {
        val value = DebridStreamFeatureFilter.entries.firstOrNull { it.name == id } ?: return
        if (dolbyVisionFilterId(DebridSettingsRepository.snapshot().streamPreferences) == id) return
        DebridSettingsRepository.setStreamDolbyVisionFilter(value)
    }

    fun setHdrFilter(id: String) {
        val value = DebridStreamFeatureFilter.entries.firstOrNull { it.name == id } ?: return
        if (hdrFilterId(DebridSettingsRepository.snapshot().streamPreferences) == id) return
        DebridSettingsRepository.setStreamHdrFilter(value)
    }

    fun setCodecFilter(id: String) {
        val value = DebridStreamCodecFilter.entries.firstOrNull { it.name == id } ?: return
        if (codecFilterId(DebridSettingsRepository.snapshot().streamPreferences) == id) return
        DebridSettingsRepository.setStreamCodecFilter(value)
    }

    fun setMinimumQuality(id: String) {
        val value = DebridStreamMinimumQuality.entries.firstOrNull { it.name == id } ?: return
        if (minimumQualityId(DebridSettingsRepository.snapshot().streamPreferences) == id) return
        DebridSettingsRepository.setStreamMinimumQuality(value)
        if (value == DebridStreamMinimumQuality.ANY) {
            // The setter above keeps the legacy field in step but stores "Any" as every known
            // resolution, which would hide streams whose resolution is unknown. Clear the rule.
            val current = DebridSettingsRepository.snapshot().streamPreferences
            DebridSettingsRepository.setStreamPreferences(current.copy(requiredResolutions = emptyList()))
        }
    }

    // endregion

    // region name / description templates

    fun defaultNameTemplate(): String = DebridStreamFormatterDefaults.NAME_TEMPLATE

    fun defaultDescriptionTemplate(): String = DebridStreamFormatterDefaults.DESCRIPTION_TEMPLATE

    /**
     * How a stored template reads in a settings row: "original" (blank, results keep the add-on's
     * own text), "default" (the shipped template) or "custom". Same order of checks as the phone
     * settings page, so a blank default description reads "original".
     */
    fun templateKind(value: String, defaultValue: String): String {
        val trimmed = value.trim()
        return when {
            trimmed.isBlank() -> "original"
            trimmed == defaultValue.trim() -> "default"
            else -> "custom"
        }
    }

    /** Variable names a template can use, e.g. "stream.resolution", in the formatter's order. */
    fun templateVariables(): List<String> = TemplatePreview.values().keys.toList()

    /** The name column of a stream row for [template], rendered with sample data. */
    fun previewName(template: String): String = TemplatePreview.name(template)

    /** The description of a stream row for [template], rendered with sample data. */
    fun previewDescription(template: String): String = TemplatePreview.description(template)

    // endregion

    const val CUSTOM = "CUSTOM"
}

/** Sample data for the template editor's live preview; mirrors the keys of DebridStreamFormatter. */
internal object TemplatePreview {
    private val engine = DebridStreamTemplateEngine()

    fun values(): Map<String, Any?> = linkedMapOf(
        "stream.title" to "Dune: Part Two",
        "stream.year" to 2024,
        "stream.season" to null,
        "stream.episode" to null,
        "stream.seasons" to emptyList<Int>(),
        "stream.episodes" to emptyList<Int>(),
        "stream.seasonEpisode" to emptyList<String>(),
        "stream.formattedEpisodes" to "",
        "stream.formattedSeasons" to "",
        "stream.resolution" to "2160p",
        "stream.library" to false,
        "stream.quality" to "BluRay REMUX",
        "stream.visualTags" to listOf("HDR10", "DV"),
        "stream.audioTags" to listOf("Atmos", "TrueHD"),
        "stream.audioChannels" to listOf("7.1"),
        "stream.languages" to listOf("en"),
        "stream.languageEmojis" to listOf("GB"),
        "stream.size" to DebridTemplateBytes(58_000_000_000L),
        "stream.folderSize" to DebridTemplateBytes(58_000_000_000L),
        "stream.encode" to "HEVC",
        "stream.indexer" to "Torrentio",
        "stream.network" to null,
        "stream.releaseGroup" to "FraMeSToR",
        "stream.duration" to null,
        "stream.edition" to null,
        "stream.filename" to "Dune.Part.Two.2024.2160p.BluRay.REMUX.HEVC.mkv",
        "stream.regexMatched" to emptyList<String>(),
        "stream.rseMatched" to emptyList<String>(),
        "stream.type" to "Debrid",
        "service.cached" to true,
        "service.shortName" to "TB",
        "service.name" to "Torbox",
        "addon.name" to "Torrentio",
    )

    fun name(template: String): String =
        engine.render(template, values())
            .lineSequence()
            .joinToString(" ") { it.trim() }
            .replace(Regex("\\s+"), " ")
            .trim()

    fun description(template: String): String =
        engine.render(template, values())
            .lineSequence()
            .map { it.trim() }
            .filter { it.isNotBlank() }
            .joinToString("\n")
            .trim()
}
