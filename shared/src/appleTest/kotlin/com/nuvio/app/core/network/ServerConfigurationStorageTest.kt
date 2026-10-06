package com.nuvio.app.core.network

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import platform.Foundation.NSUserDefaults

class ServerConfigurationStorageTest {
    private val configKey = "server_custom_config"

    @AfterTest
    fun cleanup() {
        ServerConfigurationStorage.useOfficial()
    }

    private fun customConfiguration() = ServerConfiguration(
        backendUrl = "https://media.example.org",
        publishableKey = "sb_publishable_test",
        capabilities = ServerCapabilities(emailPasswordAuth = false, tvLogin = true),
        isCustom = true,
        discoveryUrl = "https://media.example.org/.well-known/nuvio",
    )

    @Test
    fun roundTripsACustomConfiguration() {
        assertTrue(ServerConfigurationStorage.saveCustom(customConfiguration()))

        val loaded = ServerConfigurationStorage.loadCustom()
        assertEquals(customConfiguration(), loaded)
    }

    @Test
    fun useOfficialRemovesTheRecord() {
        assertTrue(ServerConfigurationStorage.saveCustom(customConfiguration()))
        assertTrue(ServerConfigurationStorage.useOfficial())
        assertNull(ServerConfigurationStorage.loadCustom())
    }

    @Test
    fun rejectsAnUnsupportedSchemaVersion() {
        NSUserDefaults.standardUserDefaults.setObject(
            """{"version":99,"backendUrl":"https://evil.example.org","publishableKey":"k","emailPasswordAuth":true,"tvLogin":true}""",
            forKey = configKey,
        )
        assertNull(ServerConfigurationStorage.loadCustom())
    }

    @Test
    fun rejectsARecordWithoutAVersion() {
        NSUserDefaults.standardUserDefaults.setObject(
            """{"backendUrl":"https://media.example.org","publishableKey":"k","emailPasswordAuth":true,"tvLogin":true}""",
            forKey = configKey,
        )
        assertNull(ServerConfigurationStorage.loadCustom())
    }

    @Test
    fun rejectsGarbageAndBlankFields() {
        NSUserDefaults.standardUserDefaults.setObject("not json", forKey = configKey)
        assertNull(ServerConfigurationStorage.loadCustom())

        NSUserDefaults.standardUserDefaults.setObject(
            """{"version":1,"backendUrl":"  ","publishableKey":"k","emailPasswordAuth":true,"tvLogin":true}""",
            forKey = configKey,
        )
        assertNull(ServerConfigurationStorage.loadCustom())

        // Neither auth capability advertised — invalid on every platform.
        NSUserDefaults.standardUserDefaults.setObject(
            """{"version":1,"backendUrl":"https://media.example.org","publishableKey":"k","emailPasswordAuth":false,"tvLogin":false}""",
            forKey = configKey,
        )
        assertNull(ServerConfigurationStorage.loadCustom())
    }
}
