package com.flutter_patcher.flutter_patcher

import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
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
    ): ByteArray {
        val code = byteArrayOf(1, 2, 3)
        val asset = byteArrayOf(4)
        val font = byteArrayOf(5)
        val manifest = JSONObject()
            .put("format_version", PatchArchive.FORMAT).put("patch_seq", 7).put("fingerprint", fp)
            .put("code", row("libapp.so", code).put("kind", kind)
                .apply { if (badDigest) put("sha256", "0".repeat(64)) })
            .put("assets", JSONArray().put(row("assets/a.svg", asset).put("key", "a.svg")))
            .put("fonts", JSONArray().put(row("fonts/f.otf", font).put("family", "F")))
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, bytes) in mapOf(
                "patch_manifest.json" to manifest.toString().toByteArray(),
                "libapp.so" to code, "assets/a.svg" to asset, "fonts/f.otf" to font,
            ) + extra) {
                zip.putNextEntry(ZipEntry(name)); zip.write(bytes); zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    @Test
    fun readsEveryListedEntry() {
        val read = PatchArchive.readLibapp(archive(), fp, 7)
        assertEquals(setOf("patch_manifest.json", "libapp.so", "assets/a.svg", "fonts/f.otf"), read.entries.keys)
        assertContentEquals(byteArrayOf(1, 2, 3), read.entries.getValue("libapp.so"))
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