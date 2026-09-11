package com.flutter_patcher.flutter_patcher

import org.bouncycastle.math.ec.rfc8032.Ed25519

/** External-key verification independent of Android's Keystore/JCA provider selection. */
internal object Ed25519Verifier {
    // RFC 8410 SubjectPublicKeyInfo: id-Ed25519, absent parameters, 32-byte BIT STRING.
    private val spkiPrefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
        0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)

    fun rawPublicKey(spki: ByteArray): ByteArray {
        require(spki.size == spkiPrefix.size + Ed25519.PUBLIC_KEY_SIZE &&
            spki.copyOfRange(0, spkiPrefix.size).contentEquals(spkiPrefix)) {
            "Invalid Ed25519 SubjectPublicKeyInfo"
        }
        return spki.copyOfRange(spkiPrefix.size, spki.size)
    }

    fun verify(publicKey: ByteArray, signature: ByteArray, message: ByteArray): Boolean {
        if (publicKey.size != Ed25519.PUBLIC_KEY_SIZE || signature.size != Ed25519.SIGNATURE_SIZE)
            return false
        // Reject invalid and small-order keys, including identity-point forgeries.
        if (!Ed25519.validatePublicKeyFull(publicKey, 0)) return false
        return Ed25519.verify(signature, 0, publicKey, 0, message, 0, message.size)
    }
}
