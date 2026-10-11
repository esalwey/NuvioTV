package com.nuvio.app.features.servers

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.alloc
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.refTo
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.value
import platform.CoreFoundation.*
import platform.Foundation.NSUserDefaults
import platform.Security.*

/**
 * Keychain-backed [ServerStorage] for iOS and tvOS (the connection list and the Jellyfin / Emby
 * access tokens). Ported from upstream's iosMain actual.
 *
 * Fork: a sideloaded or ad-hoc signed build can lack the keychain entitlement
 * (`errSecMissingEntitlement`), which would make every server sign-in fail. Whenever the Keychain
 * refuses a read or a write, the value goes to / comes from NSUserDefaults under [FALLBACK_PREFIX]
 * instead, so the feature degrades to the storage every other tvOS credential already uses rather
 * than breaking. A value that does reach the Keychain removes its fallback copy.
 */
@OptIn(ExperimentalForeignApi::class)
actual object ServerStorage {
    private const val SERVICE = "com.nuvio.media.servers"
    private const val FALLBACK_PREFIX = "media_server_storage."

    actual fun read(key: String): String? {
        val secure = try {
            keychainRead(key)
        } catch (_: Throwable) {
            null
        }
        return secure ?: NSUserDefaults.standardUserDefaults.stringForKey(FALLBACK_PREFIX + key)
    }

    actual fun write(key: String, value: String?) {
        val defaults = NSUserDefaults.standardUserDefaults
        if (value == null) {
            val deleted = runCatching { keychainWrite(key, null) }
            defaults.removeObjectForKey(FALLBACK_PREFIX + key)
            deleted.getOrThrow()
            return
        }
        try {
            keychainWrite(key, value)
            defaults.removeObjectForKey(FALLBACK_PREFIX + key)
        } catch (_: Throwable) {
            defaults.setObject(value, forKey = FALLBACK_PREFIX + key)
        }
    }

    actual fun clear() {
        val defaults = NSUserDefaults.standardUserDefaults
        for (name in defaults.dictionaryRepresentation().keys) {
            val key = name as? String ?: continue
            if (key.startsWith(FALLBACK_PREFIX)) defaults.removeObjectForKey(key)
        }
        query(null) { checkDelete(SecItemDelete(it)) }
    }

    private fun keychainRead(key: String): String? = query(key) { query ->
        CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue)
        CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne)
        memScoped {
            val result = alloc<CFTypeRefVar>()
            val status = SecItemCopyMatching(query, result.ptr)
            if (status == errSecItemNotFound) return@memScoped null
            check(status == errSecSuccess) { "Unable to read server credentials (OSStatus $status)" }
            val data: CFDataRef = result.value?.reinterpret() ?: return@memScoped null
            try {
                val bytes = CFDataGetBytePtr(data) ?: return@memScoped null
                ByteArray(CFDataGetLength(data).toInt()) { bytes[it].toByte() }.decodeToString()
            } finally {
                CFRelease(data)
            }
        }
    }

    private fun keychainWrite(key: String, value: String?) = query(key) { query ->
        if (value == null) {
            checkDelete(SecItemDelete(query))
        } else {
            val bytes = value.encodeToByteArray().toUByteArray()
            require(bytes.isNotEmpty())
            val data = CFDataCreate(null, bytes.refTo(0), bytes.size.toLong())
                ?: error("Unable to encode server credentials")
            val attributes = dictionary()
            try {
                CFDictionarySetValue(attributes, kSecValueData, data)
                val update = SecItemUpdate(query, attributes)
                if (update == errSecItemNotFound) {
                    CFDictionarySetValue(query, kSecValueData, data)
                    CFDictionarySetValue(query, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
                    val added = SecItemAdd(query, null)
                    check(added == errSecSuccess) { "Unable to save server credentials (OSStatus $added)" }
                } else {
                    check(update == errSecSuccess) { "Unable to update server credentials (OSStatus $update)" }
                }
            } finally {
                CFRelease(attributes)
                CFRelease(data)
            }
        }
    }

    private fun checkDelete(status: Int) {
        check(status == errSecSuccess || status == errSecItemNotFound) { "Unable to clear server credentials (OSStatus $status)" }
    }

    private fun dictionary(): CFMutableDictionaryRef =
        CFDictionaryCreateMutable(null, 0L, kCFTypeDictionaryKeyCallBacks.ptr, kCFTypeDictionaryValueCallBacks.ptr)
            ?: error("Unable to create credential query")

    private inline fun <T> query(key: String?, block: (CFMutableDictionaryRef) -> T): T {
        val service = CFStringCreateWithCString(null, SERVICE, kCFStringEncodingUTF8)
            ?: error("Unable to encode credential service")
        val account = key?.let { CFStringCreateWithCString(null, it, kCFStringEncodingUTF8) }
        val query = dictionary()
        try {
            CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword)
            CFDictionarySetValue(query, kSecAttrService, service)
            account?.let { CFDictionarySetValue(query, kSecAttrAccount, it) }
            return block(query)
        } finally {
            CFRelease(query)
            account?.let { CFRelease(it) }
            CFRelease(service)
        }
    }
}
