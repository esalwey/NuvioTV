package com.nuvio.app.core.storage

import android.content.Context
import com.nuvio.app.core.account.AccountDataStores

/**
 * Android half of the account-data wipe: a whole-file `clear()` of every SharedPreferences file
 * that holds account data.
 *
 * The file list comes from `core.account.AccountDataStores` — the same registry the two Apple
 * cleaners read — so this can no longer drift behind them. (It had: `nuvio_tmdb_settings` was
 * missing from the hand-maintained list, so the TMDB key survived sign-out on Android too; the
 * Apple-side leak fixed in 1debbe1f was not Apple-only after all.) Adding a persisted store means
 * adding a line to `AccountDataStores.all`, NOT editing this file.
 */
internal actual object PlatformLocalAccountDataCleaner {

    private var appContext: Context? = null

    fun initialize(context: Context) {
        appContext = context.applicationContext
    }

    actual fun wipe() {
        val context = appContext ?: return
        AccountDataStores.androidPreferenceNames().forEach { name ->
            context.getSharedPreferences(name, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .apply()
        }
    }
}
