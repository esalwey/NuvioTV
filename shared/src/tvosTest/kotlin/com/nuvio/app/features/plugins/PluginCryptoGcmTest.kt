package com.nuvio.app.features.plugins

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith

/**
 * Known-answer AES-GCM vectors from the McGrew–Viega GCM spec (the set NIST republishes),
 * proving the CommonCrypto one-shot path interoperates with WebCrypto/CryptoJS peers:
 * ciphertext||tag layout, 96-bit IV, empty AAD, 128-bit tag. The tamper cases pin down that
 * decrypt actually enforces the tag — the previous streaming-SPI implementation both ignored
 * the IV and skipped tag verification, so every vector here would have failed.
 */
class PluginCryptoGcmTest {

    // GCM spec test case 3: AES-128, 96-bit IV, 64-byte plaintext, no AAD.
    private val tc3Key = pluginHexToByteArray("feffe9928665731c6d6a8f9467308308")
    private val tc3Iv = pluginHexToByteArray("cafebabefacedbaddecaf888")
    private val tc3Plain = pluginHexToByteArray(
        "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" +
            "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255",
    )
    private val tc3Cipher = pluginHexToByteArray(
        "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e" +
            "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985",
    )
    private val tc3Tag = pluginHexToByteArray("4d5c2af327cd64a62cf35abd2ba6fab4")

    @Test
    fun aes128EncryptMatchesKnownAnswer() {
        assertContentEquals(tc3Cipher + tc3Tag, pluginAesEncrypt("AES-GCM", tc3Key, tc3Iv, tc3Plain))
    }

    @Test
    fun aes128DecryptMatchesKnownAnswer() {
        assertContentEquals(tc3Plain, pluginAesDecrypt("AES-GCM", tc3Key, tc3Iv, tc3Cipher + tc3Tag))
    }

    @Test
    fun aes256KnownAnswerRoundTrip() {
        // GCM spec test case 14: AES-256, all-zero key/IV, 16 zero bytes of plaintext.
        val key = ByteArray(32)
        val iv = ByteArray(12)
        val plain = ByteArray(16)
        val expected = pluginHexToByteArray("cea7403d4d606b6e074ec5d3baf39d18") +
            pluginHexToByteArray("d0d1c8a799996bf0265b98b5d48ab919")
        assertContentEquals(expected, pluginAesEncrypt("AES-256-GCM", key, iv, plain))
        assertContentEquals(plain, pluginAesDecrypt("AES-256-GCM", key, iv, expected))
    }

    @Test
    fun emptyPlaintextProducesTagOnlyOutput() {
        // GCM spec test case 1: AES-128, all-zero key/IV, empty plaintext -> tag only.
        val key = ByteArray(16)
        val iv = ByteArray(12)
        val expectedTag = pluginHexToByteArray("58e2fccefa7e3061367f1d57a4e7455a")
        assertContentEquals(expectedTag, pluginAesEncrypt("AES-GCM", key, iv, ByteArray(0)))
        assertContentEquals(ByteArray(0), pluginAesDecrypt("AES-GCM", key, iv, expectedTag))
    }

    @Test
    fun tamperedTagFailsAuthentication() {
        val tampered = tc3Cipher + tc3Tag
        tampered[tampered.size - 1] = (tampered.last().toInt() xor 0x01).toByte()
        assertFailsWith<IllegalStateException> {
            pluginAesDecrypt("AES-GCM", tc3Key, tc3Iv, tampered)
        }
    }

    @Test
    fun tamperedCiphertextFailsAuthentication() {
        val tampered = tc3Cipher + tc3Tag
        tampered[0] = (tampered[0].toInt() xor 0x01).toByte()
        assertFailsWith<IllegalStateException> {
            pluginAesDecrypt("AES-GCM", tc3Key, tc3Iv, tampered)
        }
    }

    @Test
    fun inputShorterThanTagIsRejected() {
        assertFailsWith<IllegalArgumentException> {
            pluginAesDecrypt("AES-GCM", tc3Key, tc3Iv, ByteArray(15))
        }
    }

    @Test
    fun randomMaterialRoundTrips() {
        val key = pluginGetRandomValues(32)
        val iv = pluginGetRandomValues(12)
        val plain = pluginGetRandomValues(133)
        val sealed = pluginAesEncrypt("aes-256-gcm", key, iv, plain)
        assertContentEquals(plain, pluginAesDecrypt("aes-256-gcm", key, iv, sealed))
    }
}
