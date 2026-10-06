package com.nuvio.app.features.profiles

import kotlin.test.Test
import kotlin.test.assertEquals

class ProfilePinCryptoTest {
    @Test
    fun sha256_matches_known_answer_vectors() {
        // Standard SHA-256 known-answer vectors. Must match CommonCrypto output
        // so PIN digests cached by the prior iOS/Android impl still verify.
        assertEquals(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ProfilePinCrypto.sha256Hex(""),
        )
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ProfilePinCrypto.sha256Hex("abc"),
        )
        assertEquals(
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            ProfilePinCrypto.sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        )
    }

    @Test
    fun hashProfilePin_is_stable() {
        val salt = "deadbeefcafef00d"
        val a = hashProfilePin(profileIndex = 2, salt = salt, pin = "1234")
        val b = hashProfilePin(profileIndex = 2, salt = salt, pin = "1234")
        assertEquals(a, b)
    }
}
