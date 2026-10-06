package com.nuvio.app.features.profiles

/**
 * Pure-Kotlin SHA-256 used for the offline PIN cache digest. Replaces the former
 * platform expect/actual (iOS CommonCrypto cinterop) so the same implementation
 * runs on every Apple/Android target — including tvOS, which doesn't link the
 * plugins cryptointerop cinterop. SHA-256 is deterministic, so digests written
 * by the old CommonCrypto path verify identically against this one.
 */
object ProfilePinCrypto {
    fun sha256Hex(value: String): String {
        val digest = sha256(value.encodeToByteArray())
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) {
            val v = b.toInt() and 0xFF
            sb.append("0123456789abcdef"[v ushr 4])
            sb.append("0123456789abcdef"[v and 0x0F])
        }
        return sb.toString()
    }

    private val K = intArrayOf(
        0x428a2f98L.toInt(), 0x71374491L.toInt(), 0xb5c0fbcfL.toInt(), 0xe9b5dba5L.toInt(),
        0x3956c25bL.toInt(), 0x59f111f1L.toInt(), 0x923f82a4L.toInt(), 0xab1c5ed5L.toInt(),
        0xd807aa98L.toInt(), 0x12835b01L.toInt(), 0x243185beL.toInt(), 0x550c7dc3L.toInt(),
        0x72be5d74L.toInt(), 0x80deb1feL.toInt(), 0x9bdc06a7L.toInt(), 0xc19bf174L.toInt(),
        0xe49b69c1L.toInt(), 0xefbe4786L.toInt(), 0x0fc19dc6L.toInt(), 0x240ca1ccL.toInt(),
        0x2de92c6fL.toInt(), 0x4a7484aaL.toInt(), 0x5cb0a9dcL.toInt(), 0x76f988daL.toInt(),
        0x983e5152L.toInt(), 0xa831c66dL.toInt(), 0xb00327c8L.toInt(), 0xbf597fc7L.toInt(),
        0xc6e00bf3L.toInt(), 0xd5a79147L.toInt(), 0x06ca6351L.toInt(), 0x14292967L.toInt(),
        0x27b70a85L.toInt(), 0x2e1b2138L.toInt(), 0x4d2c6dfcL.toInt(), 0x53380d13L.toInt(),
        0x650a7354L.toInt(), 0x766a0abbL.toInt(), 0x81c2c92eL.toInt(), 0x92722c85L.toInt(),
        0xa2bfe8a1L.toInt(), 0xa81a664bL.toInt(), 0xc24b8b70L.toInt(), 0xc76c51a3L.toInt(),
        0xd192e819L.toInt(), 0xd6990624L.toInt(), 0xf40e3585L.toInt(), 0x106aa070L.toInt(),
        0x19a4c116L.toInt(), 0x1e376c08L.toInt(), 0x2748774cL.toInt(), 0x34b0bcb5L.toInt(),
        0x391c0cb3L.toInt(), 0x4ed8aa4aL.toInt(), 0x5b9cca4fL.toInt(), 0x682e6ff3L.toInt(),
        0x748f82eeL.toInt(), 0x78a5636fL.toInt(), 0x84c87814L.toInt(), 0x8cc70208L.toInt(),
        0x90befffaL.toInt(), 0xa4506cebL.toInt(), 0xbef9a3f7L.toInt(), 0xc67178f2L.toInt(),
    )

    private fun sha256(message: ByteArray): ByteArray {
        var h0 = 0x6a09e667L.toInt()
        var h1 = 0xbb67ae85L.toInt()
        var h2 = 0x3c6ef372L.toInt()
        var h3 = 0xa54ff53aL.toInt()
        var h4 = 0x510e527fL.toInt()
        var h5 = 0x9b05688cL.toInt()
        var h6 = 0x1f83d9abL.toInt()
        var h7 = 0x5be0cd19L.toInt()

        // Padding
        val msgLenBits = message.size.toLong() * 8
        val withOne = message.size + 1
        val padLen = ((56 - withOne % 64) + 64) % 64
        val total = withOne + padLen + 8
        val padded = ByteArray(total)
        message.copyInto(padded)
        padded[message.size] = 0x80.toByte()
        for (i in 0 until 8) {
            padded[total - 1 - i] = (msgLenBits ushr (8 * i)).toByte()
        }

        val w = IntArray(64)
        var chunk = 0
        while (chunk < total) {
            for (i in 0 until 16) {
                val j = chunk + i * 4
                w[i] = ((padded[j].toInt() and 0xFF) shl 24) or
                    ((padded[j + 1].toInt() and 0xFF) shl 16) or
                    ((padded[j + 2].toInt() and 0xFF) shl 8) or
                    (padded[j + 3].toInt() and 0xFF)
            }
            for (i in 16 until 64) {
                val s0 = w[i - 15].rotateRight(7) xor w[i - 15].rotateRight(18) xor (w[i - 15] ushr 3)
                val s1 = w[i - 2].rotateRight(17) xor w[i - 2].rotateRight(19) xor (w[i - 2] ushr 10)
                w[i] = w[i - 16] + s0 + w[i - 7] + s1
            }

            var a = h0; var b = h1; var c = h2; var d = h3
            var e = h4; var f = h5; var g = h6; var h = h7

            for (i in 0 until 64) {
                val s1 = e.rotateRight(6) xor e.rotateRight(11) xor e.rotateRight(25)
                val ch = (e and f) xor (e.inv() and g)
                val temp1 = h + s1 + ch + K[i] + w[i]
                val s0 = a.rotateRight(2) xor a.rotateRight(13) xor a.rotateRight(22)
                val maj = (a and b) xor (a and c) xor (b and c)
                val temp2 = s0 + maj
                h = g; g = f; f = e; e = d + temp1
                d = c; c = b; b = a; a = temp1 + temp2
            }

            h0 += a; h1 += b; h2 += c; h3 += d
            h4 += e; h5 += f; h6 += g; h7 += h
            chunk += 64
        }

        val out = ByteArray(32)
        val hs = intArrayOf(h0, h1, h2, h3, h4, h5, h6, h7)
        for (i in 0 until 8) {
            out[i * 4] = (hs[i] ushr 24).toByte()
            out[i * 4 + 1] = (hs[i] ushr 16).toByte()
            out[i * 4 + 2] = (hs[i] ushr 8).toByte()
            out[i * 4 + 3] = hs[i].toByte()
        }
        return out
    }
}
