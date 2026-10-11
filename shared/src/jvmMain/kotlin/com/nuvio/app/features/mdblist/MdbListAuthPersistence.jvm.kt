package com.nuvio.app.features.mdblist

// JVM actual for the :shared jvm test target. Same key layout as the androidMain actual, with
// JvmSharedPreferences standing in for android.content.SharedPreferences.

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey
import com.nuvio.app.core.storage.jvmSharedPreferences

actual object PlatformMdbListAuthPersistence : MdbListAuthPersistence {
    private const val preferencesName = "nuvio_mdblist_auth"
    private const val payloadKey = "mdblist_auth_payload"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual override fun read(profileId: Int): String? =
        preferences?.getString(ProfileScopedKey.of(payloadKey, profileId), null)

    actual override fun write(profileId: Int, value: String?) {
        val editor = preferences?.edit() ?: return
        val key = ProfileScopedKey.of(payloadKey, profileId)
        if (value == null) editor.remove(key) else editor.putString(key, value)
        editor.apply()
    }

    actual override fun clear() {
        preferences?.edit()?.clear()?.apply()
    }
}
