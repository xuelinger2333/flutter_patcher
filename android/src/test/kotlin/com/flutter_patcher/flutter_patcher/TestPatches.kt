package com.flutter_patcher.flutter_patcher

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.json.JSONArray
import org.json.JSONObject

/** Patch files assembled from the FPTC v1 format, as plan/1.1-direct-patching.md §4.2 defines it. */
internal object TestPatches {
    const val FP = "abababababababababababababababababababababababababababababababab"

    fun keyPair(): KeyPair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
    fun raw(pair: KeyPair): ByteArray = pair.public.encoded.takeLast(32).toByteArray()

    fun host(key: ByteArray?, strategy: String = "bytecode") = HostTrustConfig(
        mapOf("application_id" to "com.example.app", "channel" to "production", "flavor" to "default",
            "version_code" to "7", "abi" to "arm64-v8a", "fingerprint" to FP, "strategy" to strategy),
        key, "0".repeat(64))

    private fun row(path: String, bytes: ByteArray) = JSONObject()
        .put("path", path).put("length", bytes.size).put("sha256", PatchEnvelope.digest(bytes))

    /** A format 2 patch archive of [kind] whose manifest carries [seq]. */
    fun archive(seq: Long, kind: String = "bytecode", fingerprint: String = FP): ByteArray {
        val path = if (kind == "libapp") PatchArchive.CODE else PatchArchive.MODULE
        val code = ByteArray(64) { (it + seq).toByte() }
        val asset = byteArrayOf(4)
        val font = byteArrayOf(5)
        val manifest = JSONObject()
            .put("format_version", PatchArchive.FORMAT).put("patch_seq", seq).put("fingerprint", fingerprint)
            .put("code", row(path, code).put("kind", kind))
            .put("assets", JSONArray().put(row("assets/a", asset).put("key", "a")))
            .put("fonts", JSONArray().put(row("fonts/f.otf", font).put("family", "F")))
        return ByteArrayOutputStream().also { out ->
            ZipOutputStream(out).use { z ->
                for ((name, bytes) in mapOf("patch_manifest.json" to manifest.toString().toByteArray(),
                    path to code, "assets/a" to asset, "fonts/f.otf" to font)) {
                    z.putNextEntry(ZipEntry(name).apply {
                        method = ZipEntry.STORED
                        size = bytes.size.toLong()
                        compressedSize = size
                        crc = CRC32().apply { update(bytes) }.value
                    })
                    z.write(bytes); z.closeEntry()
                }
            }
        }.toByteArray()
    }

    /** An FPTC v1 file of [payload]; signed by [key], or with a zero signature. */
    fun file(payload: ByteArray, seq: Long, key: KeyPair? = null, fingerprint: String = FP): ByteArray {
        val header = ByteBuffer.allocate(82).putInt(0x46505443).putShort(1)
            .put(fingerprint.chunked(2).map { it.toInt(16).toByte() }.toByteArray())
            .putInt(seq.toInt()).putLong(payload.size.toLong())
            .put(MessageDigest.getInstance("SHA-256").digest(payload)).array()
        val signature = key?.let {
            Signature.getInstance("Ed25519").apply { initSign(it.private); update(header); update(payload) }.sign()
        } ?: ByteArray(64)
        return header + signature + payload
    }

    fun patch(seq: Long, key: KeyPair? = null, kind: String = "bytecode") = file(archive(seq, kind), seq, key)
    fun withdrawal(seq: Long, key: KeyPair? = null) = file(ByteArray(0), seq, key)
}
