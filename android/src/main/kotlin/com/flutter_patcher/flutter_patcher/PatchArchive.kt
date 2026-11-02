package com.flutter_patcher.flutter_patcher

import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CharacterCodingException
import java.util.zip.CRC32
import java.util.zip.ZipInputStream
import org.json.JSONArray
import org.json.JSONObject

/**
 * The payload of a signed patch envelope: a ZIP whose `patch_manifest.json`
 * lists its code and resources with their digests. What the manifest must
 * vouch for is checked once, here, for both strategies; only reading the ZIP
 * differs. An SO payload is unpacked at install; a bytecode payload is
 * STORED and checked at every boot in the snapshot handed to Dart.
 */
internal class PatchArchive private constructor(
    val manifest: ByteArray,
    /** Archive path to every listed entry, code included. */
    val entries: Map<String, Entry>,
) {
    /** [length] bytes of [source] from [offset]; never copied unless asked. */
    class Entry(val source: ByteArray, val offset: Int, val length: Int) {
        fun bytes(): ByteArray = source.copyOfRange(offset, offset + length)
    }

    companion object {
        const val FORMAT = 2
        const val CODE = "libapp.so"
        const val MODULE = "module.bc"
        private const val MAX_ENTRIES = 4096
        private const val MAX_ENTRY = 64 * 1024 * 1024

        /** Reads a libapp payload the envelope of [fingerprint] and [seq] signed. */
        fun readLibapp(payload: ByteArray, fingerprint: String, seq: Long): PatchArchive {
            val files = LinkedHashMap<String, Entry>()
            ZipInputStream(ByteArrayInputStream(payload)).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    require(!entry.isDirectory && safePath(entry.name)) { "Archive path" }
                    require(files.size < MAX_ENTRIES && entry.name !in files) { "Archive entries" }
                    val bytes = CandidateStore.readBounded(NonClosing(zip), MAX_ENTRY, "Archive entry")
                    files[entry.name] = Entry(bytes, 0, bytes.size)
                }
            }
            return vouched(files, fingerprint, seq, "libapp", CODE)
        }

        /**
         * Reads the STORED payload of a verified bytecode [envelope] as
         * strictly as the Dart bootstrap does, so both select the same entry
         * ranges, and checks each entry's CRC and listed digest. Entries are
         * ranges of [envelope].
         */
        fun readBytecode(envelope: ByteArray, fingerprint: String, seq: Long): PatchArchive =
            vouched(stored(envelope, PatchEnvelope.HEADER), fingerprint, seq, "bytecode", MODULE)

        fun rows(array: JSONArray) = (0 until array.length()).map { array.getJSONObject(it) }

        /** The manifest of [files] lists exactly them, each with its length and digest. */
        private fun vouched(files: Map<String, Entry>, fingerprint: String, seq: Long, kind: String, code: String): PatchArchive {
            val manifest = files["patch_manifest.json"]?.bytes() ?: throw IllegalArgumentException("Archive manifest")
            val m = JSONObject(manifest.toString(Charsets.UTF_8))
            require(m.optInt("format_version") == FORMAT && m.optLong("patch_seq") == seq &&
                m.optString("fingerprint") == fingerprint) { "Manifest identity" }
            val listed = mutableSetOf("patch_manifest.json")
            fun check(row: JSONObject, prefix: String) {
                val path = row.getString("path")
                val entry = files[path]
                require(path.startsWith(prefix) && listed.add(path) && entry != null &&
                    row.getLong("length") == entry.length.toLong() &&
                    row.getString("sha256") == PatchEnvelope.digest(entry.source, entry.offset, entry.length)) { "Entry digest" }
            }
            val row = m.getJSONObject("code")
            require(row.getString("kind") == kind && row.getString("path") == code) { "Code kind" }
            check(row, code)
            rows(m.getJSONArray("assets")).forEach { check(it, "assets/") }
            rows(m.getJSONArray("fonts")).forEach { check(it, "fonts/") }
            require(listed == files.keys) { "Unlisted archive entries" }
            return PatchArchive(manifest, files)
        }

        /**
         * Entries of the STORED ZIP in [bytes] from [start], with the rules of
         * `readPatchArchive` in lib/src/bootstrap/patch_archive.dart: central
         * and local records agree; no extraction, ambiguous paths, data
         * descriptors, zip64 or trailing data.
         */
        private fun stored(bytes: ByteArray, start: Int): Map<String, Entry> {
            val size = bytes.size - start
            val view = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            fun range(p: Long, n: Long) = require(p >= 0 && n >= 0 && p + n <= size) { "ZIP bounds" }
            fun u16(p: Int): Int { range(p.toLong(), 2); return view.getShort(start + p).toInt() and 0xffff }
            fun u32(p: Int): Long { range(p.toLong(), 4); return view.getInt(start + p).toLong() and 0xffffffffL }
            fun name(p: Int, n: Int): String {
                range(p.toLong(), n.toLong())
                val s = try {
                    Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes, start + p, n)).toString()
                } catch (_: CharacterCodingException) { "" }
                require(safePath(s)) { "ZIP path" }
                return s
            }

            val end = size - 22
            require(u32(end) == 0x06054b50L && u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 20) == 0) {
                "ZIP end record"
            }
            val count = u16(end + 10)
            val central = u32(end + 16)
            require(count in 1..MAX_ENTRIES && u16(end + 8) == count && central + u32(end + 12) == end.toLong()) {
                "ZIP directory"
            }
            val files = LinkedHashMap<String, Entry>()
            var cp = central.toInt()
            var lp = 0
            repeat(count) {
                require(u32(cp) == 0x02014b50L && u32(lp) == 0x04034b50L) { "ZIP record" }
                val flags = u16(cp + 8)
                val n = u16(cp + 28)
                val length = u32(cp + 24)
                require(flags and 0x800.inv() == 0 && u16(cp + 10) == 0 && length == u32(cp + 20) &&
                    length <= MAX_ENTRY && u16(cp + 30) == 0 && u16(cp + 32) == 0 && u16(cp + 34) == 0 &&
                    u32(cp + 42) == lp.toLong()) { "ZIP unsupported entry" }
                val file = name(cp + 46, n)
                val attributes = u32(cp + 38)
                val mode = (attributes shr 16) and 0xf000
                require(mode == 0L || mode == 0x8000L) { "ZIP non-regular entry" }
                require(attributes and 0x10 == 0L && file !in files) { "ZIP duplicate/directory" }
                require(u16(lp + 6) == flags && u16(lp + 8) == 0 && u32(lp + 14) == u32(cp + 16) &&
                    u32(lp + 18) == length && u32(lp + 22) == length && u16(lp + 26) == n && u16(lp + 28) == 0 &&
                    name(lp + 30, n) == file) { "ZIP local/central mismatch" }
                val data = lp + 30 + n
                range(data.toLong(), length)
                require(data + length <= central) { "ZIP overlapping entry" }
                val crc = CRC32().apply { update(bytes, start + data, length.toInt()) }.value
                require(crc == u32(cp + 16)) { "ZIP CRC mismatch" }
                files[file] = Entry(bytes, start + data, length.toInt())
                lp = data + length.toInt()
                cp += 46 + n
            }
            require(lp.toLong() == central && cp == end) { "ZIP unlisted bytes" }
            return files
        }

        private fun safePath(path: String) = path.isNotEmpty() && !path.contains('\\') &&
            !path.contains(':') && !path.contains('\u0000') &&
            path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }
    }

    private class NonClosing(stream: java.io.InputStream) : java.io.FilterInputStream(stream) {
        override fun close() {}
    }
}