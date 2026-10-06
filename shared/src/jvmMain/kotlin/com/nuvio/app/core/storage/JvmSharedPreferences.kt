package com.nuvio.app.core.storage

import java.io.File
import java.nio.file.Files
import java.util.Properties
import java.util.concurrent.ConcurrentHashMap

/**
 * JVM-only (beta.14 Wave 4 / `:shared` jvm target, see `docs/issue-triage-plan-2026-08-21.md`
 * §6.1). Minimal analogue of Android's `SharedPreferences`, backed by a `Properties` file under
 * a per-process temp directory — real persistence (not just an in-memory map), no
 * `android.content` dependency. Shaped 1:1 with the Android API surface so the androidMain
 * actuals (which are already plain-JVM-adaptable per file) port to jvmMain with only the
 * `Context`/`initialize()` plumbing removed.
 *
 * Not a production storage layer — this backs unit tests only. tvOS/Android ship their own
 * actuals (NSUserDefaults+PayloadFileStore / SharedPreferences respectively); this target only
 * runs `commonTest`.
 */
class JvmSharedPreferences internal constructor(name: String) {
    private val file: File = File(JvmPreferencesRoot.directory, "$name.properties")
    private val props = Properties()
    private val lock = Any()

    init {
        synchronized(lock) {
            if (file.exists()) {
                file.inputStream().use { props.load(it) }
            }
        }
    }

    fun contains(key: String): Boolean = synchronized(lock) { props.containsKey(key) }

    fun getString(key: String, default: String?): String? =
        synchronized(lock) { if (props.containsKey(key)) props.getProperty(key) else default }

    fun getBoolean(key: String, default: Boolean): Boolean =
        synchronized(lock) { props.getProperty(key)?.toBooleanStrictOrNull() ?: default }

    fun getInt(key: String, default: Int): Int =
        synchronized(lock) { props.getProperty(key)?.toIntOrNull() ?: default }

    fun getFloat(key: String, default: Float): Float =
        synchronized(lock) { props.getProperty(key)?.toFloatOrNull() ?: default }

    fun getStringSet(key: String, default: Set<String>?): Set<String>? =
        synchronized(lock) {
            val raw = props.getProperty(key) ?: return default
            if (raw.isEmpty()) emptySet() else raw.split(SetSeparator).toSet()
        }

    fun edit(): Editor = Editor()

    inner class Editor {
        private val pending = LinkedHashMap<String, String?>() // null value = remove

        fun putString(key: String, value: String?): Editor = apply { pending[key] = value }
        fun putBoolean(key: String, value: Boolean): Editor = apply { pending[key] = value.toString() }
        fun putInt(key: String, value: Int): Editor = apply { pending[key] = value.toString() }
        fun putFloat(key: String, value: Float): Editor = apply { pending[key] = value.toString() }
        fun putStringSet(key: String, value: Set<String>): Editor =
            apply { pending[key] = value.joinToString(SetSeparator) }
        fun remove(key: String): Editor = apply { pending[key] = null }
        fun clear(): Editor = apply {
            synchronized(lock) { props.stringPropertyNames() }.forEach { pending[it] = null }
        }

        /** Matches SharedPreferences.Editor.apply() — persists, reports nothing. */
        fun apply() {
            commit()
        }

        /** Matches SharedPreferences.Editor.commit() — persists synchronously, reports success. */
        fun commit(): Boolean = synchronized(lock) {
            pending.forEach { (key, value) ->
                if (value == null) props.remove(key) else props.setProperty(key, value)
            }
            pending.clear()
            runCatching {
                file.parentFile?.mkdirs()
                file.outputStream().use { props.store(it, null) }
            }.isSuccess
        }
    }

    private companion object {
        // U+0001 (SOH) never appears in real preference values, so it is safe as a set separator.
        const val SetSeparator = "\u0001"
    }
}

internal object JvmPreferencesRoot {
    /** One temp directory per test JVM process — isolates runs, never touches the real home dir. */
    val directory: File by lazy {
        Files.createTempDirectory("nuvio-shared-jvm-test").toFile().apply { mkdirs() }
    }
}

private object JvmPreferencesCache {
    private val cache = ConcurrentHashMap<String, JvmSharedPreferences>()
    fun get(name: String): JvmSharedPreferences = cache.getOrPut(name) { JvmSharedPreferences(name) }
}

fun jvmSharedPreferences(name: String): JvmSharedPreferences = JvmPreferencesCache.get(name)
