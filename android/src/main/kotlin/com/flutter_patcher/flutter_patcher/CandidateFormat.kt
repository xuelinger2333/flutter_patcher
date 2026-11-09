package com.flutter_patcher.flutter_patcher

import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import org.json.JSONObject

/**
 * What differs between strategies: how a verified envelope is kept on disk
 * and what a boot hands to the Dart bootstrap. Everything else a candidate
 * goes through (verification, sequence, blacklist, boot attempts, rollback,
 * cleanup) lives once, in [PatchHost].
 */
internal interface CandidateFormat {
    /** The host policy strategy this format serves. */
    val strategy: String

    /** True when the engine loads the patch's code before Dart runs (SO). */
    val loadsBeforeEngine: Boolean

    /** Persists the verified [envelope] of [meta] under [root]; may add fields to [meta]. */
    fun install(root: File, meta: JSONObject, envelope: ByteArray, seq: Long)

    /** Entries of [root] that belong to [meta]; [PatchHost] removes the rest. */
    fun owned(meta: JSONObject): Set<String>

    /** The checked code to load before the engine starts, when [loadsBeforeEngine]. */
    fun code(root: File, meta: JSONObject): File?

    /** Offer fields for the Dart bootstrap, read and checked off the main thread. */
    fun offer(root: File, meta: JSONObject, host: HostTrustConfig): Map<String, Any?>

    companion object {
        fun of(strategy: String): CandidateFormat = if (strategy == "so") LibappFormat else BytecodeFormat

        /** Writes [bytes] durably, then renames them into [file]. */
        fun writeSynced(file: File, bytes: ByteArray) {
            val pending = File(file.parentFile, UUID.randomUUID().toString() + ".pending")
            try {
                FileOutputStream(pending).use { it.write(bytes); it.fd.sync() }
                check(pending.renameTo(file)) { "Cannot commit ${file.name}" }
            } finally {
                pending.delete()
            }
        }
    }
}

/**
 * The envelope itself, re-verified at every boot, archive included; Dart
 * loads its module.
 */
internal object BytecodeFormat : CandidateFormat {
    override val strategy = "bytecode"
    override val loadsBeforeEngine = false
    private fun name(meta: JSONObject) = meta.getString("sha256") + ".fptc"

    /**
     * A verified envelope's header pins its payload by digest, so the digest
     * of the header kept at install pins the whole installed file without
     * hashing it again. Older candidates compare the file's.
     */
    private fun header(bytes: ByteArray) = PatchEnvelope.digest(bytes, 0, PatchEnvelope.HEADER)
    private fun identifies(bytes: ByteArray, meta: JSONObject) = meta.optString("header_sha256").let {
        if (it.isEmpty()) PatchEnvelope.digest(bytes) == meta.getString("sha256") else it == header(bytes)
    }

    override fun install(root: File, meta: JSONObject, envelope: ByteArray, seq: Long) {
        CandidateFormat.writeSynced(File(root, name(meta)), envelope)
        meta.put("header_sha256", header(envelope))
    }

    override fun owned(meta: JSONObject) = setOf(name(meta))
    override fun code(root: File, meta: JSONObject): File? = null

    override fun offer(root: File, meta: JSONObject, host: HostTrustConfig): Map<String, Any?> {
        val started = System.nanoTime()
        val bytes = CandidateStore.readBounded(File(root, name(meta)))
        val read = System.nanoTime()
        val seq = PatchEnvelope.verify(bytes, meta.getString("fingerprint"), host.fptcKey).seq
        require(seq == meta.getLong("seq") && identifies(bytes, meta)) { "Stored candidate changed" }
        val verified = System.nanoTime()
        // The bootstrap reads the same ranges and skips only the CRCs and
        // digests checked here; see parseAuthenticatedPatchBytes.
        val entries = PatchArchive.readBytecode(bytes, meta.getString("fingerprint"), seq).entries
            .mapValues { (_, entry) -> listOf(entry.offset, entry.length) }
        // This exact local snapshot passed verification above. Never reopen
        // the path or mutate the array after handing it to the codec.
        return mapOf("envelopeBytes" to bytes, "entries" to entries, "profile_us" to mapOf(
            "read" to (read - started) / 1000, "envelope_verify" to (verified - read) / 1000,
            "archive" to (System.nanoTime() - verified) / 1000))
    }
}

/**
 * The envelope's archive unpacked once, at install, into a directory named
 * by its digest. Each boot checks the files against digests recorded then:
 * the libapp.so before the engine maps it, each resource as it is offered.
 */
internal object LibappFormat : CandidateFormat {
    override val strategy = "so"
    override val loadsBeforeEngine = true
    private fun dir(root: File, meta: JSONObject) = File(root, meta.getString("sha256"))

    override fun install(root: File, meta: JSONObject, envelope: ByteArray, seq: Long) {
        val archive = PatchArchive.readLibapp(envelope.copyOfRange(PatchEnvelope.HEADER, envelope.size),
            meta.getString("fingerprint"), seq)
        val dir = dir(root, meta)
        // Same digest: the same verified content is already there.
        if (!dir.isDirectory) {
            val pending = File(root, UUID.randomUUID().toString() + ".pending")
            try {
                for ((path, entry) in archive.entries) {
                    val file = File(pending, path)
                    check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs()) { "Cannot create ${file.parent}" }
                    FileOutputStream(file).use { it.write(entry.source, entry.offset, entry.length); it.fd.sync() }
                }
                check(pending.renameTo(dir)) { "Cannot commit SO candidate" }
            } finally {
                pending.deleteRecursively()
            }
        }
        meta.put("manifest_sha256", PatchEnvelope.digest(archive.manifest))
    }

    override fun owned(meta: JSONObject) = setOf(meta.getString("sha256"))

    private fun manifest(root: File, meta: JSONObject): JSONObject {
        val bytes = File(dir(root, meta), "patch_manifest.json").readBytes()
        require(PatchEnvelope.digest(bytes) == meta.getString("manifest_sha256")) { "Unpacked manifest changed" }
        return JSONObject(bytes.toString(Charsets.UTF_8))
    }

    override fun code(root: File, meta: JSONObject): File {
        val code = manifest(root, meta).getJSONObject("code")
        val libapp = File(dir(root, meta), PatchArchive.CODE)
        // What the engine maps must be what the envelope signed.
        require(libapp.length() == code.getLong("length") &&
            PatchEnvelope.digest(libapp.readBytes()) == code.getString("sha256")) { "Unpacked libapp.so changed" }
        return libapp
    }

    override fun offer(root: File, meta: JSONObject, host: HostTrustConfig): Map<String, Any?> {
        val manifest = manifest(root, meta)
        fun read(row: JSONObject): ByteArray {
            val bytes = File(dir(root, meta), row.getString("path")).readBytes()
            require(PatchEnvelope.digest(bytes) == row.getString("sha256")) { "Unpacked resource changed" }
            return bytes
        }
        return mapOf("kind" to "libapp",
            "assets" to PatchArchive.rows(manifest.getJSONArray("assets")).associate { it.getString("key") to read(it) },
            "fonts" to PatchArchive.rows(manifest.getJSONArray("fonts")).groupBy({ it.getString("family") }, { read(it) }))
    }
}