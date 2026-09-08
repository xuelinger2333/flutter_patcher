package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.os.Build
import android.os.Process
import android.util.Base64
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.UUID
import org.json.JSONObject

/** Separate files/preferences from legacy SO installation. All commits are serialized. */
internal class BytecodePatchManager(private val context: Context) {
    companion object {
        private val lock = Any()
        private var processClaimed = false
    }
    private val prefs = context.getSharedPreferences("flutter_patcher_bytecode", Context.MODE_PRIVATE)
    private val directory = File(context.filesDir, "flutter_patcher_bytecode")
    @Volatile var bootstrapped = false
        private set
    private var fingerprint: String? = null
    private var key: ByteArray? = null
    private var offered: String? = null
    private var attempt: BytecodeAttempt? = null
    private var offeredMeta: JSONObject? = null
    @Volatile var frameToken: String? = null
        private set

    fun announceBootstrap() { bootstrapped = true }

    fun bootPayload(fp: String, publicKey: String): Map<String, Any?>? = synchronized(lock) {
        if (fingerprint != null || processClaimed) return@synchronized null
        processClaimed = true
        require(Regex("[0-9a-f]{64}").matches(fp)) { "Invalid host fingerprint" }
        val raw = Base64.decode(publicKey, Base64.DEFAULT)
        require(raw.size == 32) { "Invalid host public key" }
        fingerprint = fp
        key = raw
        if (Build.VERSION.SDK_INT < 33) {
            diagnostic("BYTECODE_UNSUPPORTED", "Bytecode verification requires Android API 33")
            return@synchronized null
        }
        val prior = prefs.getString("attempt_meta", null)
        if (prior != null) {
            val meta = JSONObject(prior)
            if (CrashGuard(context).previousSessionCrashed(prefs.getBoolean("loading", false),
                    prefs.getInt("pid", -1))) recordFailure(meta, "Previous process crashed")
            commit(prefs.edit().remove("attempt_meta").remove("pid").putBoolean("loading", false))
        }
        val meta = active() ?: return@synchronized null
        if (meta.getString("fingerprint") != fp || meta.getLong("versionCode") != PatcherConfig.currentVersionCode(context)) {
            commit(prefs.edit().remove("active"))
            diagnostic(BootDiagnosticStore.DROPPED_VERSION_CODE_MISMATCH, "Host identity changed")
            return@synchronized null
        }
        if (prefs.getBoolean("bad:${id(meta)}", false)) return@synchronized null
        try {
            val file = File(directory, meta.getString("sha256") + ".fptc")
            val bytes = readBounded(file.inputStream())
            val seq = BytecodeEnvelope.verify(bytes, fp, raw)
            require(seq == meta.getLong("seq") && BytecodeEnvelope.digest(bytes) == meta.getString("sha256")) { "Stored candidate changed" }
            offered = UUID.randomUUID().toString()
            attempt = BytecodeAttempt(offered!!)
            offeredMeta = meta
            mapOf("path" to file.absolutePath, "sha256" to meta.getString("sha256"), "attempt" to offered)
        } catch (error: Exception) {
            recordFailure(meta, error.message ?: "Candidate rejected")
            null
        }
    }

    fun markBooting(token: String?): Boolean = synchronized(lock) {
        if (token == null || token != offered || attempt?.running == true || attempt?.failed == true) return@synchronized false
        val meta = offeredMeta ?: return@synchronized false
        // A rollback or a newly installed candidate invalidates a prepared offer.
        if (active()?.let { id(it) } != id(meta)) return@synchronized false
        commit(prefs.edit().putString("attempt_meta", meta.toString())
            .putBoolean("loading", true).putInt("pid", Process.myPid()))
        val started = attempt?.start(token) == true
        if (started) frameToken = token
        started
    }

    fun success(token: String?) = synchronized(lock) {
        // Untokened legacy init/first-frame reports cannot settle a v2 attempt.
        if (token == null || attempt?.succeed(token) != true) return@synchronized
        val meta = offeredMeta ?: return@synchronized
        commit(prefs.edit().putBoolean("loading", false).putInt("crashes:${id(meta)}", 0))
        diagnostic(BootDiagnosticStore.PATCHED, "Bytecode first frame", meta)
    }

    fun firstFrame(token: String) = synchronized(lock) { success(token) }

    fun error(token: String?, message: String?, quarantine: Boolean = false) = synchronized(lock) {
        if (token == null || token != offered) return@synchronized
        if (attempt?.fail(token) != true) {
            // init() and bootstrap may report the same error in either order.
            // A later fatal report escalates disposition, never the crash count.
            if (quarantine && attempt?.failed == true) {
                offeredMeta?.let { recordFailure(it, message ?: "Unsafe startup", true, false) }
            }
            return@synchronized
        }
        frameToken = null
        offeredMeta?.let { recordFailure(it, message ?: "Dart boot failure", quarantine) }
        commit(prefs.edit().remove("attempt_meta").remove("pid").putBoolean("loading", false))
    }

    fun apply(args: Map<String, Any?>, progress: ProgressCallback): ApplyResult = synchronized(lock) {
        if (Build.VERSION.SDK_INT < 33 || fingerprint == null || key == null)
            return@synchronized ApplyResult.failure(ApplyErrorCode.SIGNATURE_INVALID, "A bootstrapped Android API 33+ host is required")
        try {
            val version = args["version"] as? String ?: ""
            val url = args["patchUrl"] as? String ?: ""
            require(version.isNotEmpty() && url.isNotEmpty()) { "Version and URL required" }
            val vc = PatcherConfig.currentVersionCode(context)
            require(args["targetVersionCode"] == null || (args["targetVersionCode"] as Number).toLong() == vc) { "Target version mismatch" }
            progress("downloading", 0, -1)
            val uri = URI(url)
            val bytes = if (uri.scheme == "file") {
                val file = File(uri).canonicalFile
                require(file.toPath().startsWith(context.cacheDir.canonicalFile.toPath())) { "Staged file must be in application cache" }
                readBounded(file.inputStream())
            } else {
                require(uri.scheme == "https" || uri.scheme == "http") { "Unsupported URL" }
                val connection = uri.toURL().openConnection() as HttpURLConnection
                try {
                    connection.connectTimeout = 15000
                    connection.readTimeout = 30000
                    require(connection.responseCode in 200..299) { "HTTP ${connection.responseCode}" }
                    readBounded(connection.inputStream)
                } finally { connection.disconnect() }
            }
            progress("verifying", bytes.size.toLong(), bytes.size.toLong())
            val seq: Long
            try { seq = BytecodeEnvelope.verify(bytes, fingerprint!!, key!!) }
            catch (e: Exception) { return@synchronized ApplyResult.failure(ApplyErrorCode.SIGNATURE_INVALID, e.message) }
            val hash = BytecodeEnvelope.digest(bytes)
            require(args["sha256"] == null || args["sha256"] == hash) { "Transport SHA256 mismatch" }
            require(args["fingerprint"] == null || args["fingerprint"] == fingerprint) { "Metadata fingerprint mismatch" }
            require(args["patch_seq"] == null || (args["patch_seq"] as Number).toLong() == seq) { "Metadata sequence mismatch" }
            val meta = JSONObject().put("fingerprint", fingerprint).put("seq", seq)
                .put("sha256", hash).put("version", version).put("versionCode", vc)
            if (prefs.getBoolean("bad:${id(meta)}", false))
                return@synchronized ApplyResult.failure(ApplyErrorCode.BLACKLISTED, "Bytecode candidate is blacklisted")
            val old = active()
            val repeated = old != null && id(old) == id(meta)
            require(repeated || seq > prefs.getLong("high:$fingerprint", 0)) { "Patch sequence must exceed accepted high-water mark" }
            progress("finalizing", bytes.size.toLong(), bytes.size.toLong())
            check(directory.isDirectory || directory.mkdirs()) { "Cannot create bytecode directory" }
            val temporary = File(directory, UUID.randomUUID().toString() + ".pending")
            FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
            val target = File(directory, "$hash.fptc")
            check(temporary.renameTo(target)) { "Cannot commit bytecode file" }
            commit(prefs.edit().putString("active", meta.toString())
                .putLong("high:$fingerprint", maxOf(seq, prefs.getLong("high:$fingerprint", 0))))
            ApplyResult.SUCCESS
        } catch (e: java.io.IOException) { ApplyResult.failure(ApplyErrorCode.IO_ERROR, e.message) }
          catch (e: Exception) { ApplyResult.failure(ApplyErrorCode.INVALID_ARGS, e.message) }
    }

    fun rollback() = synchronized(lock) {
        // Keep high-water marks and blacklist across explicit rollback.
        commit(prefs.edit().remove("active").remove("attempt_meta").remove("pid").putBoolean("loading", false))
        offered = null
        attempt = null
        frameToken = null
    }
    fun currentVersion(): String? = synchronized(lock) { active()?.optString("version") }
    fun blacklist(): List<Map<String, Any?>> = synchronized(lock) {
        prefs.all.filter { it.key.startsWith("bad:") && it.value == true }
            .map { mapOf("version" to it.key.removePrefix("bad:"), "md5" to "", "reason" to "BOOT_CRASH", "strategy" to "bytecode") }
    }
    fun clearBlacklist() = synchronized(lock) {
        val edit = prefs.edit()
        prefs.all.keys.filter { it.startsWith("bad:") || it.startsWith("crashes:") }.forEach { edit.remove(it) }
        commit(edit)
    }
    private fun active(): JSONObject? = prefs.getString("active", null)?.let { JSONObject(it) }
    private fun id(meta: JSONObject) = "${meta.getString("fingerprint")}:${meta.getLong("seq")}:${meta.getString("sha256")}"
    private fun recordFailure(meta: JSONObject, message: String, quarantine: Boolean = false, increment: Boolean = true) {
        val id = id(meta)
        val count = prefs.getInt("crashes:$id", 0) + if (increment) 1 else 0
        val tripped = quarantine || count >= PatcherConfig.maxCrashCount(context)
        val edit = prefs.edit().putInt("crashes:$id", count)
        if (prefs.getString("attempt_meta", null)?.let { id(JSONObject(it)) } == id) {
            // Counting and consuming the old attempt are one durable write.
            edit.remove("attempt_meta").remove("pid").putBoolean("loading", false)
        }
        if (tripped) {
            edit.putBoolean("bad:$id", true)
            if (active()?.let { id(it) } == id) edit.remove("active")
        }
        commit(edit)
        diagnostic(if (tripped) BootDiagnosticStore.DROPPED_CIRCUIT_BREAKER else "BYTECODE_BOOT_FAILED", message, meta, count)
    }
    private fun diagnostic(status: String, message: String, meta: JSONObject? = null, count: Int = 0) {
        BootDiagnosticStore.record(context, status, patchVersion = meta?.optString("version"),
            appVersionCode = PatcherConfig.currentVersionCode(context), crashCount = count, message = message)
    }
    private fun commit(edit: android.content.SharedPreferences.Editor) { check(edit.commit()) { "Cannot commit bytecode state" } }
    private fun readBounded(stream: InputStream): ByteArray = stream.use {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(65536)
        while (true) {
            val count = it.read(buffer)
            if (count < 0) break
            require(out.size().toLong() + count <= BytecodeEnvelope.MAX_BYTES) { "Patch too large" }
            out.write(buffer, 0, count)
        }
        out.toByteArray()
    }
}
