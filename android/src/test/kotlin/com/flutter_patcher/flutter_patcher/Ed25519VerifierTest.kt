package com.flutter_patcher.flutter_patcher

import java.security.KeyPairGenerator
import java.security.Signature
import kotlin.test.*

class Ed25519VerifierTest {
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun rfc8032EmptyMessageAndMalformedInputs() {
        val key = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        val sig = hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        assertTrue(Ed25519Verifier.verify(key, sig, byteArrayOf()))
        assertFalse(Ed25519Verifier.verify(key, sig, byteArrayOf(1)))
        for (offset in listOf(0, 31, 32, 63)) {
            val bad = sig.clone(); bad[offset] = (bad[offset].toInt() xor 1).toByte()
            assertFalse(Ed25519Verifier.verify(key, bad, byteArrayOf()))
        }
        for (length in listOf(0, 31, 33))
            assertFalse(Ed25519Verifier.verify(key.copyOf(length), sig, byteArrayOf()))
        for (length in listOf(0, 63, 65))
            assertFalse(Ed25519Verifier.verify(key, sig.copyOf(length), byteArrayOf()))
        // Identity public key, identity R and zero S must never authenticate a message.
        val identity = ByteArray(32).also { it[0] = 1 }
        val forgery = ByteArray(64).also { it[0] = 1 }
        assertFalse(Ed25519Verifier.verify(identity, forgery, byteArrayOf()))
        assertFalse(Ed25519Verifier.verify(ByteArray(32), forgery, byteArrayOf()))
    }

    @Test fun interoperatesWithJdkAndRejectsWrongKeyAndSpki() {
        val pair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val message = "0123456789abcdef0123456789abcdef".toByteArray()
        val sig = Signature.getInstance("Ed25519").apply { initSign(pair.private); update(message) }.sign()
        val raw = Ed25519Verifier.rawPublicKey(pair.public.encoded)
        assertTrue(Ed25519Verifier.verify(raw, sig, message))
        val other = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        assertFalse(Ed25519Verifier.verify(Ed25519Verifier.rawPublicKey(other.public.encoded), sig, message))
        for (bad in listOf(pair.public.encoded.copyOf(43), pair.public.encoded + byteArrayOf(0),
                pair.public.encoded.also { it[8] = 0x71 })) {
            assertFailsWith<IllegalArgumentException> { Ed25519Verifier.rawPublicKey(bad) }
        }
    }
}
