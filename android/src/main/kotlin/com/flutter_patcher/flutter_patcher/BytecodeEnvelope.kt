package com.flutter_patcher.flutter_patcher

import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

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
        val prefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)
        val key = KeyFactory.getInstance("Ed25519").generatePublic(X509EncodedKeySpec(prefix + rawKey))
        val verifier = Signature.getInstance("Ed25519")
        verifier.initVerify(key)
        verifier.update(bytes, 0, 82)
        verifier.update(bytes, 146, bytes.size - 146)
        val valid = try { verifier.verify(bytes.copyOfRange(82, 146)) }
            catch (_: java.security.SignatureException) { false }
        require(valid) { "Envelope signature" }
        return (header.getInt(38).toLong() and 0xffffffffL).also { require(it > 0) { "Patch sequence" } }
    }
}
