package com.nuvio.app.features.details

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MetaReleaseDateTest {
    @Test
    fun keepsTheCalendarDayAndDropsTimeAndOffset() {
        assertEquals("2010-07-16", normalizeIsoReleaseDate("2010-07-16T00:00:00.000Z"))
        assertEquals("2010-07-16", normalizeIsoReleaseDate(" 2010-07-16 "))
        assertEquals("1999-12-31", normalizeIsoReleaseDate("1999-12-31T23:30:00-05:00"))
    }

    @Test
    fun valuesWithoutAFullDateAreRejected() {
        assertNull(normalizeIsoReleaseDate(null))
        assertNull(normalizeIsoReleaseDate(""))
        assertNull(normalizeIsoReleaseDate("2010"))
        assertNull(normalizeIsoReleaseDate("2008-2013"))
        assertNull(normalizeIsoReleaseDate("2010-13-01"))
        assertNull(normalizeIsoReleaseDate("2010-07-00"))
    }

    @Test
    fun parserReadsTheAddonReleasedField() {
        val meta = MetaDetailsParser.parse(
            """{"meta":{"id":"tt1375666","type":"movie","name":"Inception","releaseInfo":"2010","released":"2010-07-16T00:00:00.000Z"}}""",
        )

        assertEquals("2010", meta.releaseInfo)
        assertEquals("2010-07-16", meta.releaseDate)
    }
}
