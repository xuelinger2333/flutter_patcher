package com.flutter_patcher.flutter_patcher

import java.nio.ByteBuffer
import java.security.MessageDigest

/** FPTC v1: never allocate from the unauthenticated payload length. */
internal object BytecodeEnvelope {
    const val MAX_BYTES = 320 * 1024 * 1024
    fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }

    fun verify(bytes: ByteArray, fingerprint: String, rawKey: ByteArray): Long {
        require(bytes.size in 146..MAX_BYTES) { "Envelope size" }
        val header = ByteBuffer.wrap(bytes)
        require(header.getLong(42) == bytes.size.toLong() - 146) { "Envelope length" }
        require(header.getInt(0) == 0x46505443) { "Envelope magic" }
        require(header.getShort(4).toInt() == 1) { "Envelope version" }
        require(bytes.copyOfRange(6, 38).joinToString("") { "%02x".format(it) } == fingerprint) {
            "Envelope fingerprint"
        }
        val hash = MessageDigest.getInstance("SHA-256").apply { update(bytes, 146, bytes.size - 146) }.digest()
        require(MessageDigest.isEqual(hash, bytes.copyOfRange(50, 82))) { "Envelope hash" }
        require(rawKey.size == 32) { "Raw Ed25519 public key required" }
        // Pure Ed25519 signs the header followed by the ZIP, not Ed25519ph or its hash.
        // One exact-size buffer, bounded above before allocation; never mutate the input.
        val message = ByteArray(bytes.size - 64)
        bytes.copyInto(message, 0, 0, 82)
        bytes.copyInto(message, 82, 146)
        val valid = Ed25519Verifier.verify(rawKey, bytes.copyOfRange(82, 146), message)
        require(valid) { "Envelope signature" }
        return (header.getInt(38).toLong() and 0xffffffffL).also { require(it > 0) { "Patch sequence" } }
    }
}
