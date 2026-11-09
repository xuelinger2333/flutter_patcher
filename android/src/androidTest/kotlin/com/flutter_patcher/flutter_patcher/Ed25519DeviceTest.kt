package com.flutter_patcher.flutter_patcher

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import java.nio.ByteBuffer
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Runs production verification on Android, not a desktop JCA substitute. */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 33)
class Ed25519DeviceTest {
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private val key = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
    private val fingerprint = "ab".repeat(32)

    private fun envelope(): ByteArray {
        val payload = byteArrayOf(1, 2, 3, 4)
        val header = ByteBuffer.allocate(82).putInt(0x46505443).putShort(1)
            .put(ByteArray(32) { 0xab.toByte() }).putInt(7).putLong(4)
            .put(MessageDigest.getInstance("SHA-256").digest(payload)).array()
        // OpenSSL-generated fixture also used by PatchEnvelopeTest (public RFC8032 seed).
        val sig = hex("3d0df6da5e5a032899403ba3e00b815bc5ea1779f5ecbdf652cc70cb5aa572a02cd54f7fce63795cac5ee096eb49bb6dcfb8fd1bd52f603d75709b41313f9c01")
        return header + sig + payload
    }

    @Test fun authenticEnvelopePassesRepeatedlyWithoutMutatingBytes() {
        val bytes = envelope(); val original = bytes.clone()
        assertEquals(7L, PatchEnvelope.verify(bytes, fingerprint, key).seq)
        assertEquals(7L, PatchEnvelope.verify(bytes, fingerprint, key).seq)
        assertArrayEquals(original, bytes)
    }

    @Test fun wrongKeyAndTamperedEnvelopeAreRejected() {
        val wrongKey = hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
        try {
            PatchEnvelope.verify(envelope(), fingerprint, wrongKey)
            fail("Wrong signing key accepted")
        } catch (e: IllegalArgumentException) { assertEquals("Envelope signature", e.message) }
        for (offset in listOf(0, 4, 6, 38, 42, 50, 82, 145, 146)) {
            val bytes = envelope(); bytes[offset] = (bytes[offset].toInt() xor 1).toByte()
            try {
                PatchEnvelope.verify(bytes, fingerprint, key)
                fail("Tampered byte $offset accepted")
            } catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun invalidKeyAndSignatureEncodingsNeverAuthenticate() {
        val identity = ByteArray(32).also { it[0] = 1 }
        val forgery = ByteArray(64).also { it[0] = 1 }
        assertFalse(Ed25519Verifier.verify(identity, forgery, byteArrayOf()))
        assertFalse(Ed25519Verifier.verify(ByteArray(32), forgery, byteArrayOf()))
        assertFalse(Ed25519Verifier.verify(key.copyOf(31), forgery, byteArrayOf()))
        assertFalse(Ed25519Verifier.verify(key, forgery.copyOf(63), byteArrayOf()))
    }

}
