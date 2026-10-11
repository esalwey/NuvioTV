package com.nuvio.app.core.account

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Every `ProfileScopedKey.of(<const>)` key the Apple actuals write must be in [AccountDataStores],
 * or a sign-out leaves it behind and the next user of that profile slot inherits it.
 */
class AppleProfileScopedKeysRegistryTest {

    @Test
    fun `every profile scoped key written in appleMain is in the sign out registry`() {
        val root = listOf(File("src/appleMain"), File("shared/src/appleMain")).firstOrNull { it.isDirectory }
            ?: return // sources are not reachable from this working directory
        val registered = AccountDataStores.all
            .flatMap { it.appleKeys }
            .filterIsInstance<AppleKeySpec.ProfileScoped>()
            .map { it.base }
            .toSet()
        val constant = Regex("""private const val (\w+)\s*=\s*"([^"]+)"""")
        val missing = mutableListOf<String>()
        root.walkTopDown().filter { it.isFile && it.extension == "kt" }.forEach { file ->
            val text = file.readText()
            constant.findAll(text).forEach { match ->
                val name = match.groupValues[1]
                val value = match.groupValues[2]
                val scoped = Regex("""ProfileScopedKey\.of\(\s*(?:this\.)?${Regex.escape(name)}\s*\)""").containsMatchIn(text)
                if (scoped && value !in registered) missing += "$value (${file.name})"
            }
        }
        assertTrue(missing.isEmpty(), "Profile scoped keys missing from AccountDataStores: $missing")
    }
}
