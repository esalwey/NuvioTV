package com.nuvio.app.features.servers

// JVM actual for shared/src/jvmMain (the `:shared:jvmTest` target; neither app ships it). Plain
// process memory: tests never need the secrets to outlive the test run, and there is no OS secret
// store to talk to.

import java.util.concurrent.ConcurrentHashMap

actual object ServerStorage {
    private val values = ConcurrentHashMap<String, String>()

    actual fun read(key: String): String? = values[key]

    actual fun write(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
    }

    actual fun clear() {
        values.clear()
    }
}
