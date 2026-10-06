package com.nuvio.app.core.storage

import com.nuvio.app.core.profile.ActiveProfileProvider


object ProfileScopedKey {
    fun of(baseKey: String): String = "${baseKey}_${ActiveProfileProvider.activeProfileId}"
    fun of(baseKey: String, profileId: Int): String = "${baseKey}_$profileId"
}
