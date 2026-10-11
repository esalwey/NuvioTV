package com.nuvio.app.features.mdblist

import android.content.Context
import android.content.SharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object PlatformMdbListAuthPersistence : MdbListAuthPersistence {
    private const val preferencesName = "nuvio_mdblist_auth"
    private const val payloadKey = "mdblist_auth_payload"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.applicationContext.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

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
