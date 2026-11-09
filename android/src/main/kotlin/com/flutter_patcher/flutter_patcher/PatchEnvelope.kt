package com.flutter_patcher.flutter_patcher

import java.nio.ByteBuffer
import java.security.MessageDigest

/**
 * FPTC v1, the whole patch file: never allocate from the unauthenticated
 * payload length. A file with no payload is a withdrawal.
 */
internal object PatchEnvelope {
    const val MAX_BYTES = 320 * 1024 * 1024
    /** Header fields and Ed25519 signature before the payload. */
    const val HEADER = 146

    /** What a header claims, before anything is verified. */
    data class Header(val fingerprint: String, val seq: Long, val length: Long) {
        val withdrawal: Boolean get() = length == 0L
    }

    fun digest(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size): String = MessageDigest.getInstance("SHA-256")
        .apply { update(bytes, offset, length) }.digest().joinToString("") { "%02x".format(it) }

    /** Reads the first [HEADER] bytes of [bytes]: magic, version and a nonzero sequence. */
    fun header(bytes: ByteArray): Header {
        require(bytes.size >= HEADER) { "Envelope size" }
        val header = ByteBuffer.wrap(bytes)
        require(header.getInt(0) == 0x46505443) { "Envelope magic" }
        require(header.getShort(4).toInt() == 1) { "Envelope version" }
        val seq = header.getInt(38).toLong() and 0xffffffffL
        require(seq > 0) { "Patch sequence" }
        val length = header.getLong(42)
        require(length in 0..(MAX_BYTES - HEADER).toLong()) { "Envelope length" }
        return Header(bytes.copyOfRange(6, 38).joinToString("") { "%02x".format(it) }, seq, length)
    }

    /**
     * The whole file of [fingerprint]'s host: its header, length and digest,
     * and when the host trusts [rawKey], the Ed25519 signature over the
     * header followed by the payload. Returns its header.
     */
    fun verify(bytes: ByteArray, fingerprint: String, rawKey: ByteArray?): Header {
        require(bytes.size in HEADER..MAX_BYTES) { "Envelope size" }
        val header = header(bytes)
        require(header.length == bytes.size.toLong() - HEADER) { "Envelope length" }
        require(header.fingerprint == fingerprint) { "Envelope fingerprint" }
        val hash = MessageDigest.getInstance("SHA-256").apply { update(bytes, HEADER, bytes.size - HEADER) }.digest()
        require(MessageDigest.isEqual(hash, bytes.copyOfRange(50, 82))) { "Envelope hash" }
        if (rawKey != null) {
            require(rawKey.size == 32) { "Raw Ed25519 public key required" }
            // Pure Ed25519 signs the header followed by the ZIP, not Ed25519ph or its hash.
            // Both parts are hashed in place; never mutate the input.
            val valid = Ed25519Verifier.verify(rawKey, bytes.copyOfRange(82, HEADER)) {
                it.update(bytes, 0, 82)
                it.update(bytes, HEADER, bytes.size - HEADER)
            }
            require(valid) { "Envelope signature" }
        }
        return header
    }
}
