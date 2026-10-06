package com.nuvio.app.core.auth

import com.nuvio.app.core.build.AppBuildConfig
import platform.Foundation.NSUserDefaults
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

internal actual fun debugSessionRestoreStall(): Duration? {
    if (!AppBuildConfig.IS_DEBUG_BUILD) return null
    val seconds = NSUserDefaults.standardUserDefaults.integerForKey("debug.authRestoreStallSeconds")
    return if (seconds > 0) seconds.seconds else null
}
