package com.flutter_patcher.flutter_patcher

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import org.json.JSONArray
import org.json.JSONObject

class PatchArchiveTest {
    private val fp = "ab".repeat(32)

    private fun row(path: String, bytes: ByteArray) = JSONObject()
        .put("path", path).put("length", bytes.size).put("sha256", PatchEnvelope.digest(bytes))

    private fun archive(
        kind: String = "libapp",
        extra: Map<String, ByteArray> = emptyMap(),
        badDigest: Boolean = false,
        stored: Boolean = false,
    ): ByteArray {
        val path = if (kind == "bytecode") PatchArchive.MODULE else PatchArchive.CODE
        val code = byteArrayOf(1, 2, 3)
        val asset = byteArrayOf(4)
        val font = byteArrayOf(5)
        val manifest = JSONObject()
            .put("format_version", PatchArchive.FORMAT).put("patch_seq", 7).put("fingerprint", fp)
            .put("code", row(path, code).put("kind", kind)
                .apply { if (badDigest) put("sha256", "0".repeat(64)) })
            .put("assets", JSONArray().put(row("assets/a.svg", asset).put("key", "a.svg")))
            .put("fonts", JSONArray().put(row("fonts/f.otf", font).put("family", "F")))
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, bytes) in mapOf(
                "patch_manifest.json" to manifest.toString().toByteArray(),
                path to code, "assets/a.svg" to asset, "fonts/f.otf" to font,
            ) + extra) {
                zip.putNextEntry(ZipEntry(name).apply {
                    // As the CLI writes a bytecode payload: no compression, no data descriptor.
                    if (stored) {
                        method = ZipEntry.STORED
                        size = bytes.size.toLong()
                        compressedSize = size
                        crc = CRC32().apply { update(bytes) }.value
                    }
                })
                zip.write(bytes); zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    /** [payload] behind an envelope header; [PatchArchive] reads only the payload. */
    private fun envelope(payload: ByteArray) = ByteArray(PatchEnvelope.HEADER) + payload

    @Test
    fun readsEveryListedEntry() {
        val read = PatchArchive.readLibapp(archive(), fp, 7)
        assertEquals(setOf("patch_manifest.json", "libapp.so", "assets/a.svg", "fonts/f.otf"), read.entries.keys)
        assertContentEquals(byteArrayOf(1, 2, 3), read.entries.getValue("libapp.so").bytes())
    }

    @Test
    fun readsBytecodeEntriesAsRangesOfTheEnvelope() {
        val bytes = envelope(archive(kind = "bytecode", stored = true))
        val read = PatchArchive.readBytecode(bytes, fp, 7)
        assertEquals(setOf("patch_manifest.json", "module.bc", "assets/a.svg", "fonts/f.otf"), read.entries.keys)
        assertContentEquals(byteArrayOf(1, 2, 3), read.entries.getValue("module.bc").bytes())
        assertTrue(read.entries.values.all { it.source === bytes && it.offset >= PatchEnvelope.HEADER })
    }

    @Test
    fun bytecodeRejectsWhatTheBootstrapRejects() {
        fun reason(bytes: ByteArray) =
            assertFailsWith<IllegalArgumentException> { PatchArchive.readBytecode(bytes, fp, 7) }.message
        assertEquals("ZIP unsupported entry", reason(envelope(archive(kind = "bytecode"))))
        assertEquals("Entry digest", reason(envelope(archive(kind = "bytecode", stored = true, badDigest = true))))
        assertEquals("Code kind", reason(envelope(archive(stored = true))))
        assertEquals("Unlisted archive entries", reason(envelope(archive(kind = "bytecode", stored = true,
            extra = mapOf("assets/x" to byteArrayOf(9))))))
        assertEquals("ZIP path", reason(envelope(archive(kind = "bytecode", stored = true,
            extra = mapOf("../x" to byteArrayOf(9))))))
        assertEquals("Manifest identity", assertFailsWith<IllegalArgumentException> {
            PatchArchive.readBytecode(envelope(archive(kind = "bytecode", stored = true)), fp, 8)
        }.message)
        val bytes = envelope(archive(kind = "bytecode", stored = true))
        val module = PatchArchive.readBytecode(bytes, fp, 7).entries.getValue("module.bc")
        bytes[module.offset] = (bytes[module.offset] + 1).toByte()
        assertEquals("ZIP CRC mismatch", reason(bytes))
    }

    @Test
    fun rejectsWhatTheManifestDoesNotVouchFor() {
        assertFailsWith<IllegalArgumentException> { PatchArchive.readLibapp(archive(kind = "bytecode"), fp, 7) }
        assertFailsWith<IllegalArgumentException> { PatchArchive.readLibapp(archive(badDigest = true), fp, 7) }
        assertFailsWith<IllegalArgumentException> {
            PatchArchive.readLibapp(archive(extra = mapOf("assets/x" to byteArrayOf(9))), fp, 7)
        }
        assertFailsWith<IllegalArgumentException> {
            PatchArchive.readLibapp(archive(extra = mapOf("../x" to byteArrayOf(9))), fp, 7)
        }
        assertFailsWith<IllegalArgumentException> { PatchArchive.readLibapp(archive(), fp, 8) }
        assertFailsWith<IllegalArgumentException> { PatchArchive.readLibapp(archive(), "cd".repeat(32), 7) }
    }
}