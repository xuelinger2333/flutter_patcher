package com.flutter_patcher.flutter_patcher

import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream
import org.json.JSONArray
import org.json.JSONObject

/**
 * The payload of a signed patch envelope: a ZIP whose `patch_manifest.json`
 * lists its code and resources with their digests. The Dart bootstrap reads
 * bytecode payloads; this reads those whose code is an SO host's libapp.so.
 */
internal class PatchArchive private constructor(
    val manifest: ByteArray,
    /** Archive path to bytes of every listed entry, code included. */
    val entries: Map<String, ByteArray>,
) {
    companion object {
        const val FORMAT = 2
        const val CODE = "libapp.so"
        private const val MAX_ENTRIES = 4096
        private const val MAX_ENTRY = 64 * 1024 * 1024

        /** Reads a libapp payload the envelope of [fingerprint] and [seq] signed. */
        fun readLibapp(payload: ByteArray, fingerprint: String, seq: Long): PatchArchive {
            val files = LinkedHashMap<String, ByteArray>()
            ZipInputStream(ByteArrayInputStream(payload)).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    require(!entry.isDirectory && safePath(entry.name)) { "Archive path" }
                    require(files.size < MAX_ENTRIES && entry.name !in files) { "Archive entries" }
                    files[entry.name] = CandidateStore.readBounded(NonClosing(zip), MAX_ENTRY, "Archive entry")
                }
            }
            val manifest = files["patch_manifest.json"] ?: throw IllegalArgumentException("Archive manifest")
            val m = JSONObject(manifest.toString(Charsets.UTF_8))
            require(m.optInt("format_version") == FORMAT && m.optLong("patch_seq") == seq &&
                m.optString("fingerprint") == fingerprint) { "Manifest identity" }
            val listed = mutableSetOf("patch_manifest.json")
            fun check(row: JSONObject, prefix: String) {
                val path = row.getString("path")
                val bytes = files[path]
                require(path.startsWith(prefix) && listed.add(path) && bytes != null &&
                    row.getLong("length") == bytes.size.toLong() &&
                    row.getString("sha256") == PatchEnvelope.digest(bytes)) { "Entry digest" }
            }
            val code = m.getJSONObject("code")
            require(code.getString("kind") == "libapp" && code.getString("path") == CODE) { "Code kind" }
            check(code, CODE)
            rows(m.getJSONArray("assets")).forEach { check(it, "assets/") }
            rows(m.getJSONArray("fonts")).forEach { check(it, "fonts/") }
            require(listed == files.keys) { "Unlisted archive entries" }
            return PatchArchive(manifest, files)
        }

        fun rows(array: JSONArray) = (0 until array.length()).map { array.getJSONObject(it) }

        private fun safePath(path: String) = path.isNotEmpty() && !path.contains('\\') &&
            !path.contains(':') && !path.contains('\u0000') &&
            path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }
    }

    private class NonClosing(stream: java.io.InputStream) : java.io.FilterInputStream(stream) {
        override fun close() {}
    }
}