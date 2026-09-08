package com.flutter_patcher.flutter_patcher

import java.nio.ByteBuffer
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class BytecodeEnvelopeTest {
    @Test fun verifiesOpenSslEnvelopeWithRawRfc8032PublicKey() {
        fun hex(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val payload = byteArrayOf(1, 2, 3, 4)
        val header = ByteBuffer.allocate(82).putInt(0x46505443).putShort(1)
            .put(ByteArray(32) { 0xab.toByte() }).putInt(7).putLong(4)
            .put(MessageDigest.getInstance("SHA-256").digest(payload)).array()
        // openssl pkeyutl -sign -rawin; public RFC 8032 test seed, not a production key.
        val signature = hex("3d0df6da5e5a032899403ba3e00b815bc5ea1779f5ecbdf652cc70cb5aa572a02cd54f7fce63795cac5ee096eb49bb6dcfb8fd1bd52f603d75709b41313f9c01")
        val key = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        assertEquals(7L, BytecodeEnvelope.verify(header + signature + payload, "ab".repeat(32), key))
    }
    @Test fun signsExactHeaderAndPayloadAndRejectsTampering() {
        val key = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val raw = key.public.encoded.takeLast(32).toByteArray()
        val payload = byteArrayOf(1, 2, 3, 4)
        val header = ByteBuffer.allocate(82).putInt(0x46505443).putShort(1)
            .put(ByteArray(32) { 0xab.toByte() }).putInt(7).putLong(payload.size.toLong())
            .put(MessageDigest.getInstance("SHA-256").digest(payload)).array()
        val sig = Signature.getInstance("Ed25519").apply {
            initSign(key.private); update(header); update(payload)
        }.sign()
        val bytes = header + sig + payload
        assertEquals(7L, BytecodeEnvelope.verify(bytes, "ab".repeat(32), raw))
        for (offset in listOf(0, 4, 6, 38, 42, 50, 82, 146)) {
            val damaged = bytes.clone()
            damaged[offset] = (damaged[offset].toInt() xor 1).toByte()
            assertFailsWith<IllegalArgumentException> { BytecodeEnvelope.verify(damaged, "ab".repeat(32), raw) }
        }
        assertFailsWith<IllegalArgumentException> { BytecodeEnvelope.verify(bytes.copyOf(145), "ab".repeat(32), raw) }
    }
}
