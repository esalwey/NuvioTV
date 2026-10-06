package com.nuvio.app.features.tmdb

import kotlin.test.Test
import kotlin.test.assertEquals

/** BUG-63: the `include_video_language` list sent with every `/videos` request. */
class TmdbVideoLanguageTest {

    @Test
    fun regionalLanguageExpandsToBaseThenRegionThenEnglishThenUntagged() {
        assertEquals("fr,fr-FR,en,null", includeVideoLanguages("fr-FR"))
        assertEquals("pt,pt-BR,en,null", includeVideoLanguages("pt-BR"))
    }

    @Test
    fun englishCollapsesDuplicates() {
        assertEquals("en,en-US,null", includeVideoLanguages("en-US"))
        assertEquals("en,null", includeVideoLanguages("en"))
    }

    @Test
    fun bareLanguageHasNoRegionEntry() {
        assertEquals("de,en,null", includeVideoLanguages("de"))
    }
}
