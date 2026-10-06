package com.nuvio.app.core.auth

// JVM actual (beta.14 Wave 4, docs/issue-triage-plan-2026-08-21.md §6.1). No android.os.Build
// or platform.UIKit here — reports the JVM/OS the test runs on instead of a real device.
internal actual fun currentDeviceClientMetadata(): DeviceClientMetadata {
    val osName = System.getProperty("os.name") ?: "JVM"
    val osVersion = System.getProperty("os.version") ?: ""
    return DeviceClientMetadata(
        deviceName = formatDeviceName(
            manufacturer = "",
            model = "$osName $osVersion".trim(),
            fallback = "JVM test host",
        ),
        platform = "JVM $osVersion",
    )
}
