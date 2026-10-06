package com.nuvio.app.core.storage

import platform.Foundation.NSUserDefaults
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Covers the migration contract every PayloadFileStore-backed store relies on: values written by
 * pre-migration builds through NSUserDefaults must drain into the file store on first read, and
 * the legacy defaults key must disappear on every save/remove so the plist shrinks back.
 */
class PayloadFileStoreTest {
    private val subdirectory = "PayloadFileStoreTest"
    private val key = "payload_file_store_test_key"

    private val defaults get() = NSUserDefaults.standardUserDefaults

    @AfterTest
    fun tearDown() {
        PayloadFileStore.deleteAll(subdirectory)
        defaults.removeObjectForKey(key)
    }

    @Test
    fun loadReturnsNullWhenNothingStored() {
        assertNull(PayloadFileStore.load(subdirectory, key))
    }

    @Test
    fun saveThenLoadRoundTrips() {
        PayloadFileStore.save(subdirectory, key, """{"value":1}""")
        assertEquals("""{"value":1}""", PayloadFileStore.load(subdirectory, key))

        PayloadFileStore.save(subdirectory, key, """{"value":2}""")
        assertEquals("""{"value":2}""", PayloadFileStore.load(subdirectory, key))
    }

    @Test
    fun loadDrainsLegacyDefaultsValueAndRemovesKey() {
        defaults.setObject("legacy-payload", forKey = key)

        assertEquals("legacy-payload", PayloadFileStore.load(subdirectory, key))
        assertNull(defaults.stringForKey(key), "legacy defaults key should be removed after drain")
        // Second read must come from the file store.
        assertEquals("legacy-payload", PayloadFileStore.load(subdirectory, key))
    }

    @Test
    fun fileValueWinsOverLegacyDefaultsValue() {
        PayloadFileStore.save(subdirectory, key, "file-payload")
        defaults.setObject("legacy-payload", forKey = key)

        assertEquals("file-payload", PayloadFileStore.load(subdirectory, key))
    }

    @Test
    fun saveRemovesLegacyDefaultsKey() {
        defaults.setObject("legacy-payload", forKey = key)

        PayloadFileStore.save(subdirectory, key, "new-payload")
        assertNull(defaults.stringForKey(key), "save must drop the legacy defaults key")
        assertEquals("new-payload", PayloadFileStore.load(subdirectory, key))
    }

    @Test
    fun removeDeletesFileAndLegacyKey() {
        defaults.setObject("legacy-payload", forKey = key)
        PayloadFileStore.save(subdirectory, key, "payload")

        PayloadFileStore.remove(subdirectory, key)
        assertNull(defaults.stringForKey(key))
        assertNull(PayloadFileStore.load(subdirectory, key))
    }

    @Test
    fun deleteAllRemovesEveryKeyInTheSubdirectory() {
        PayloadFileStore.save(subdirectory, "${key}_1", "one")
        PayloadFileStore.save(subdirectory, "${key}_2", "two")

        PayloadFileStore.deleteAll(subdirectory)
        assertNull(PayloadFileStore.load(subdirectory, "${key}_1"))
        assertNull(PayloadFileStore.load(subdirectory, "${key}_2"))
    }
}
