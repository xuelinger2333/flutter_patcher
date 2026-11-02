package com.flutter_patcher.flutter_patcher

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import org.json.JSONArray
import org.json.JSONObject

/**
 * The contract every [CandidateFormat] keeps, so [PatchHost] can treat them
 * alike. A new format joins [formats] and must pass unchanged.
 */
class CandidateFormatContractTest {
    private val formats = listOf(BytecodeFormat, LibappFormat)
    private val fp = "ab".repeat(32)
    private val pair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
    private val host = HostTrustConfig(mapOf("fingerprint" to fp, "strategy" to "so"),
        pair.public.encoded.takeLast(32).toByteArray(), ByteArray(32), emptyMap(), "0".repeat(64))

    private fun row(path: String, bytes: ByteArray) = JSONObject()
        .put("path", path).put("length", bytes.size).put("sha256", PatchEnvelope.digest(bytes))

    /** A signed envelope of a format 2 archive, as the CLI writes it. */
    private fun envelope(): ByteArray {
        val code = ByteArray(64) { it.toByte() }
        val asset = byteArrayOf(4)
        val font = byteArrayOf(5)
        val manifest = JSONObject()
            .put("format_version", PatchArchive.FORMAT).put("patch_seq", 7).put("fingerprint", fp)
            .put("code", row("libapp.so", code).put("kind", "libapp"))
            .put("assets", JSONArray().put(row("assets/a", asset).put("key", "a")))
            .put("fonts", JSONArray().put(row("fonts/f.otf", font).put("family", "F")))
        val zip = ByteArrayOutputStream().also { out ->
            ZipOutputStream(out).use { z ->
                for ((name, bytes) in mapOf("patch_manifest.json" to manifest.toString().toByteArray(),
                    "libapp.so" to code, "assets/a" to asset, "fonts/f.otf" to font)) {
                    z.putNextEntry(ZipEntry(name)); z.write(bytes); z.closeEntry()
                }
            }
        }.toByteArray()
        val header = ByteBuffer.allocate(82).putInt(0x46505443).putShort(1)
            .put(ByteArray(32) { 0xab.toByte() }).putInt(7).putLong(zip.size.toLong())
            .put(MessageDigest.getInstance("SHA-256").digest(zip)).array()
        val signature = Signature.getInstance("Ed25519").apply {
            initSign(pair.private); update(header); update(zip)
        }.sign()
        return header + signature + zip
    }

    @Test
    fun everyFormatKeepsOnlyWhatItOwnsAndOffersOnlyWhatWasSigned() {
        val bytes = envelope()
        for (format in formats) {
            val root = Files.createTempDirectory("format-${format.strategy}").toFile()
            try {
                File(root, "older").mkdir()
                val meta = JSONObject().put("fingerprint", fp).put("seq", 7L)
                    .put("sha256", PatchEnvelope.digest(bytes))
                format.install(root, meta, bytes, 7)
                val owned = format.owned(meta)
                assertEquals(owned + "older", root.list()!!.toSet(), format.strategy)
                assertEquals(format.loadsBeforeEngine, format.code(root, meta) != null, format.strategy)
                assertTrue(format.offer(root, meta, host).isNotEmpty(), format.strategy)
                // Any change to a kept file is caught before it is loaded or offered.
                val files = owned.flatMap { File(root, it).walk().filter(File::isFile).toList() }
                assertTrue(files.isNotEmpty(), format.strategy)
                for (file in files) {
                    val original = file.readBytes()
                    file.writeBytes(original.copyOf().also { it[it.size - 1] = (it.last().toInt() xor 1).toByte() })
                    assertFailsWith<Exception>("${format.strategy}: ${file.name}") {
                        format.code(root, meta)
                        format.offer(root, meta, host)
                    }
                    file.writeBytes(original)
                }
            } finally {
                root.deleteRecursively()
            }
        }
    }
}