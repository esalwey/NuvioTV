package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals

// Fork guard: :shared's AvailableLanguageOptionCodes must mirror composeApp's
// AvailableLanguageOptions (see PlayerLanguageOptionCodes.kt).
class PlayerLanguageOptionsParityTest {
    @Test
    fun sharedCodesMatchComposeOptions() {
        assertEquals(AvailableLanguageOptions.map { it.code }, AvailableLanguageOptionCodes)
    }
}
