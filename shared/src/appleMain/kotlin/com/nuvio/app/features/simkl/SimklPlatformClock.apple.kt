package com.nuvio.app.features.simkl

import platform.Foundation.NSDate
import platform.Foundation.timeIntervalSince1970

internal actual object SimklPlatformClock {
    actual fun nowEpochMs(): Long = (NSDate().timeIntervalSince1970 * 1000.0).toLong()
}
