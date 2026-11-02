package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.content.SharedPreferences
import android.os.Process
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.UUID
import org.json.JSONObject

/**
 * Durable state of signed FPTC candidates for one strategy: content-addressed
 * files, the active candidate, the boot attempt, crash counts, blacklist and
 * sequence high-water marks. Only the active candidate keeps its files
 * ([owned] names them), as on iOS. Callers serialize access.
 */
internal class CandidateStore(
    private val context: Context,
    private val strategy: String,
    private val owned: (JSONObject) -> Set<String> = { emptySet() },
) {
    private val prefs = context.getSharedPreferences("flutter_patcher_$strategy", Context.MODE_PRIVATE)
    private val directory = File(context.filesDir, "flutter_patcher_$strategy")

    init {
        dropRestoredState()
    }

    /**
     * Auto Backup restores shared_prefs and files/ but never noBackupFilesDir,
     * where the authorization state lives, so a restored candidate (reinstall,
     * new device) would fail its authorization check and be blacklisted. A
     * marker beside that state ties candidate state to this installation;
     * state from another one is dropped, as on a fresh install. iOS excludes
     * its whole store from backup instead.
     */
    private fun dropRestoredState() {
        val marker = File(context.noBackupFilesDir, "flutter_patcher_install_$strategy")
        val local = marker.takeIf { it.isFile }?.readText()
        val recorded = prefs.getString("install", null)
        if (recorded != null && recorded == local) return
        // State written before this marker existed has no record and is kept.
        if (recorded != null) {
            commit(prefs.edit().clear())
            directory.deleteRecursively()
        }
        val id = local ?: UUID.randomUUID().toString().also {
            marker.parentFile?.mkdirs()
            marker.writeText(it)
        }
        commit(prefs.edit().putString("install", id))
    }

    fun active(): JSONObject? = prefs.getString("active", null)?.let { JSONObject(it) }
    fun id(meta: JSONObject) = "${meta.getString("fingerprint")}:${meta.getLong("seq")}:${meta.getString("sha256")}"
    /** Where the [CandidateFormat] keeps candidates' files. */
    val root: File get() = directory

    /** Settles the attempt left by the previous process; a crash counts as a failure. */
    fun recoverAttempt() {
        val prior = prefs.getString("attempt_meta", null) ?: return
        val meta = JSONObject(prior)
        if (CrashGuard(context).previousSessionCrashed(prefs.getBoolean("loading", false),
                prefs.getInt("pid", -1))) recordFailure(meta, "Previous process crashed")
        clearAttempt()
    }

    /** The active, non-blacklisted candidate of this host build; a stale one is dropped. */
    fun activeFor(fingerprint: String): JSONObject? {
        val meta = active() ?: return null
        if (meta.getString("fingerprint") != fingerprint || meta.getLong("versionCode") != PatcherConfig.currentVersionCode(context)) {
            commit(prefs.edit().remove("active"))
            diagnostic(BootDiagnosticStore.DROPPED_VERSION_CODE_MISMATCH, "Host identity changed")
            return null
        }
        return if (prefs.getBoolean("bad:${id(meta)}", false)) null else meta
    }

    fun candidate(fingerprint: String, seq: Long, sha256: String, version: String, authorization: String?): JSONObject =
        JSONObject().put("fingerprint", fingerprint).put("seq", seq).put("sha256", sha256)
            .put("version", version).put("versionCode", PatcherConfig.currentVersionCode(context))
            .apply { if (authorization != null) put("authorization", authorization) }

    fun isBlacklisted(meta: JSONObject) = prefs.getBoolean("bad:${id(meta)}", false)

    fun requireNewer(meta: JSONObject) {
        val old = active()
        require((old != null && id(old) == id(meta)) ||
            meta.getLong("seq") > prefs.getLong("high:${meta.getString("fingerprint")}", 0)) {
            "Patch sequence must exceed accepted high-water mark"
        }
    }

    /** Makes [meta] active; its files are already in [root]. */
    fun save(meta: JSONObject) {
        requireNewer(meta)
        val fingerprint = meta.getString("fingerprint")
        commit(prefs.edit().putString("active", meta.toString())
            .putLong("high:$fingerprint", maxOf(meta.getLong("seq"), prefs.getLong("high:$fingerprint", 0))))
    }

    fun markLoading(meta: JSONObject) = commit(prefs.edit().putString("attempt_meta", meta.toString())
        .putBoolean("loading", true).putInt("pid", Process.myPid()))
    fun markSuccess(meta: JSONObject) = commit(prefs.edit().putBoolean("loading", false).putInt("crashes:${id(meta)}", 0))
    fun clearAttempt() = commit(clearingAttempt(prefs.edit()))
    /** Keeps high-water marks and blacklist. */
    fun clearActive() = commit(clearingAttempt(prefs.edit().remove("active")))

    fun recordFailure(meta: JSONObject, message: String, quarantine: Boolean = false, increment: Boolean = true) {
        val id = id(meta)
        val count = prefs.getInt("crashes:$id", 0) + if (increment) 1 else 0
        val tripped = quarantine || count >= PatcherConfig.maxCrashCount(context)
        val edit = prefs.edit().putInt("crashes:$id", count)
        // Counting and consuming the old attempt are one durable write.
        if (prefs.getString("attempt_meta", null)?.let { id(JSONObject(it)) } == id) clearingAttempt(edit)
        if (tripped) {
            edit.putBoolean("bad:$id", true)
            if (active()?.let { id(it) } == id) edit.remove("active")
        }
        commit(edit)
        diagnostic(if (tripped) BootDiagnosticStore.DROPPED_CIRCUIT_BREAKER else "${strategy.uppercase()}_BOOT_FAILED", message, meta, count)
    }

    fun diagnostic(status: String, message: String, meta: JSONObject? = null, count: Int = 0) {
        BootDiagnosticStore.record(context, status, patchVersion = meta?.optString("version"),
            appVersionCode = PatcherConfig.currentVersionCode(context), crashCount = count, message = message)
    }

    fun noPatch() = BootDiagnosticStore.recordNoPatch(context, PatcherConfig.currentVersionCode(context))

    fun blacklist(): List<Map<String, Any?>> = prefs.all.filter { it.key.startsWith("bad:") && it.value == true }
        .map { mapOf("version" to it.key.removePrefix("bad:"), "md5" to "", "reason" to "BOOT_CRASH", "strategy" to strategy) }

    fun clearBlacklist() {
        val edit = prefs.edit()
        prefs.all.keys.filter { it.startsWith("bad:") || it.startsWith("crashes:") }.forEach { edit.remove(it) }
        commit(edit)
    }

    private fun clearingAttempt(edit: SharedPreferences.Editor) =
        edit.remove("attempt_meta").remove("pid").putBoolean("loading", false)
    private fun commit(edit: SharedPreferences.Editor) {
        val before = active()?.let { id(it) }
        check(edit.commit()) { "Cannot commit $strategy state" }
        // One candidate per host: whatever stops being active loses its files.
        // A running patch already holds its code and bytes.
        if (active()?.let { id(it) } != before) prune()
    }

    private fun prune() {
        val keep = active()?.let(owned) ?: emptySet()
        directory.listFiles()?.filter { it.name !in keep }?.forEach { it.deleteRecursively() }
    }

    companion object {
        /** InputStream.readNBytes needs API 33; this bounded read works from API 24. */
        fun readBounded(stream: InputStream, limit: Int = PatchEnvelope.MAX_BYTES, what: String = "Patch"): ByteArray = stream.use {
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(65536)
            while (true) {
                val count = it.read(buffer)
                if (count < 0) break
                require(out.size().toLong() + count <= limit) { "$what too large" }
                out.write(buffer, 0, count)
            }
            out.toByteArray()
        }

        /** [file] in one exact-size array; a file that changes length while read is rejected. */
        fun readBounded(file: File, limit: Int = PatchEnvelope.MAX_BYTES): ByteArray = file.inputStream().use {
            val size = file.length()
            require(size <= limit) { "Patch too large" }
            val bytes = ByteArray(size.toInt())
            var read = 0
            while (read < bytes.size) {
                val count = it.read(bytes, read, bytes.size - read)
                require(count > 0) { "Patch changed while read" }
                read += count
            }
            require(it.read() < 0) { "Patch changed while read" }
            bytes
        }
    }
}