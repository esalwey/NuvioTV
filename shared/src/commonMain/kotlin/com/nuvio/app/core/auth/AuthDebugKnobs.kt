package com.nuvio.app.core.auth

import kotlin.time.Duration

/**
 * Debug-build-only stall injection for the session-restore watchdog: when set, the session-status
 * collector is delayed by this long, so the root gate behaves exactly as if the auth library never
 * left its Initializing state (the boot-hang class of 2026-08-05). Returns null in release builds
 * and when the knob is unset.
 *
 * Apple: `defaults write <bundle-id> debug.authRestoreStallSeconds -int 30`
 */
internal expect fun debugSessionRestoreStall(): Duration?
