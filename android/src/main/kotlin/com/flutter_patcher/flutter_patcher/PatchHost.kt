package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Base64
import java.io.File
import java.util.UUID
import org.json.JSONObject

/** Reports apply progress: `downloading`, `verifying`, `finalizing`. */
internal typealias ProgressCallback = (phase: String, received: Long, total: Long) -> Unit

/**
 * The patch side of an authenticated host, whichever its strategy: every
 * rule a candidate is held to lives here once, and [format] only decides how
 * a verified envelope is kept and what a boot offers. The store keeps only
 * the active candidate's files. All state changes are serialized; one
 * instance serves a process (see [of]).
 *
 * A boot is one attempt bound to a token. [select] picks the active,
 * authorized candidate once per process; [bootPayload] offers it to the Dart
 * bootstrap, [markBooting] starts it, and the first frame ([success]) or a
 * Dart failure ([error]) settles it. A crash leaves it to the next start.
 * A background engine's isolate gets the same code ([backgroundPayload])
 * outside any attempt.
 */
internal class PatchHost private constructor(
    private val context: Context,
    private val host: HostTrustConfig,
    private val format: CandidateFormat,
) {
    companion object {
        private val hosts = HashMap<String, PatchHost>()

        /** The process's host for [host]'s strategy: Application and plugin share it. */
        fun of(context: Context, host: HostTrustConfig): PatchHost {
            val format = CandidateFormat.of(host.strategy)
            return synchronized(hosts) {
                hosts.getOrPut("${context.filesDir.path}:${format.strategy}") { PatchHost(context, host, format) }
            }
        }
    }

    private class Attempt(val meta: JSONObject, val code: File?) {
        val boot = BootAttempt(UUID.randomUUID().toString())
        var offered = false
    }

    private val lock = Any()
    private val auth = AuthenticatedUpdates(context, host)
    private val store = CandidateStore(context, format.strategy, format::owned)
    private val fingerprint = host.scope.getValue("fingerprint")
    private val label = if (format.strategy == "so") "SO" else "Bytecode"
    private var claimed = false
    private var attempt: Attempt? = null

    /** The started attempt the next first frame settles, if any. */
    @Volatile var frameToken: String? = null
        private set

    /** Whether this start runs a patch whose first frame is still to come. */
    val awaitingFirstFrame: Boolean get() = synchronized(lock) { attempt?.boot?.unsettled == true }

    /** Code to load before the engine starts (SO); null to run the app as built. */
    fun bootCode(): File? = synchronized(lock) {
        select()?.also { store.markLoading(it.meta) }?.code
    }

    /** The loader hook did not install: nothing ran, so this is not a failure. */
    fun cancel() = synchronized(lock) {
        if (attempt != null) store.clearAttempt()
        attempt = null
    }

    /** The offer for this process, once; null runs the app as built. */
    fun bootPayload(fp: String, publicKey: String): Map<String, Any?>? = synchronized(lock) {
        requireBootstrap(fp, publicKey)
        // Code the engine loads first was chosen before it started.
        val boot = (if (format.loadsBeforeEngine) attempt else select())
            ?.takeIf { !it.offered } ?: return@synchronized null
        boot.offered = true
        try {
            mapOf("transportVersion" to 1, "attempt" to boot.boot.token) +
                format.offer(store.root, boot.meta, host)
        } catch (error: Exception) {
            // Code already loaded runs regardless; the next start must not.
            store.recordFailure(boot.meta, error.message ?: "Candidate rejected", quarantine = boot.code != null)
            attempt = null
            null
        }
    }

    /**
     * The offer for an isolate a background engine starts, for any number of
     * engines, starting no attempt and changing no boot state: the code this
     * process booted, so one process never runs two versions; a failed boot
     * runs as built. Before this process boots, and only for code that loads
     * after the engine, the active, authorized candidate. Null runs the entry
     * point as built.
     */
    fun backgroundPayload(fp: String, publicKey: String): Map<String, Any?>? = synchronized(lock) {
        requireBootstrap(fp, publicKey)
        val meta = if (claimed || format.loadsBeforeEngine) attempt?.takeIf { !it.boot.failed }?.meta
            else store.activeFor(fingerprint)?.takeIf {
                try { auth.checkBoot(it); true } catch (_: Exception) { false }
            }
        meta ?: return@synchronized null
        try {
            mapOf("transportVersion" to 1) + format.offer(store.root, meta, host)
        } catch (error: Exception) {
            // The candidate is the app isolate's to judge; this engine runs as built.
            android.util.Log.w("FlutterPatcher", "Background payload rejected: ${error.message}")
            null
        }
    }

    fun markBooting(token: String?): Boolean = synchronized(lock) {
        val boot = attempt ?: return@synchronized false
        if (token != boot.boot.token || !boot.offered || boot.boot.running || boot.boot.failed) return@synchronized false
        if (boot.code == null) {
            // A rollback or a newly installed candidate invalidates a prepared offer.
            try { auth.checkBoot(boot.meta) } catch (_: Exception) { return@synchronized false }
            if (store.active()?.let { store.id(it) } != store.id(boot.meta)) return@synchronized false
            store.markLoading(boot.meta)
        }
        boot.boot.start(token).also { if (it) frameToken = token }
    }

    fun success(token: String?) = synchronized(lock) {
        // Untokened legacy init/first-frame reports cannot settle an attempt.
        val boot = attempt ?: return@synchronized
        if (!boot.boot.succeed(token)) return@synchronized
        store.markSuccess(boot.meta)
        store.diagnostic(BootDiagnosticStore.PATCHED, "$label first frame", boot.meta)
    }

    fun error(token: String?, message: String?, quarantine: Boolean = false) = synchronized(lock) {
        val boot = attempt ?: return@synchronized
        if (token == null || token != boot.boot.token) return@synchronized
        if (!boot.boot.fail(token)) {
            // init() and bootstrap may report the same error in either order.
            // A later fatal report escalates disposition, never the crash count.
            if (quarantine && boot.boot.failed) store.recordFailure(boot.meta, message ?: "Unsafe startup", true, false)
            return@synchronized
        }
        frameToken = null
        store.recordFailure(boot.meta, message ?: "Dart boot failure", quarantine)
        store.clearAttempt()
    }

    /** Applies [wire] with the payload Dart downloaded to [payload]; a withdrawal has none. */
    fun applyManifest(wire: String, payload: String?, progress: ProgressCallback): Map<String, Any?> {
        val decision = synchronized(lock) { auth.verify(wire) }
        if (decision.action == "withdraw") {
            synchronized(lock) { auth.accept(wire); invalidateUnauthorized() }
            return mapOf("action" to "withdraw", "ok" to true)
        }
        // Accept only an intact payload, so a failed download stays retryable.
        val bytes = AuthenticatedUpdates.payload(decision.fields, requireNotNull(payload) { "Payload required" })
        return synchronized(lock) {
            auth.accept(wire)
            install(auth.checkCommit(wire).fields, bytes, wire, progress).toMap() + mapOf("action" to "publish")
        }
    }

    fun inspect(wire: String): Map<String, Any?> = synchronized(lock) { auth.inspect(wire) }

    fun updateTrust(wire: String) = synchronized(lock) {
        auth.updateTrust(wire)
        invalidateUnauthorized()
    }

    fun rollback() = synchronized(lock) {
        HostTrustConfig.requireOwner(context)
        store.clearActive()
        attempt = null
        frameToken = null
    }

    fun currentVersion(): String? = synchronized(lock) { store.active()?.optString("version") }
    fun blacklist(): List<Map<String, Any?>> = synchronized(lock) { store.blacklist() }
    fun clearBlacklist() = synchronized(lock) {
        HostTrustConfig.requireOwner(context)
        store.clearBlacklist()
    }

    private fun requireBootstrap(fp: String, publicKey: String) =
        require(fp == fingerprint && Base64.decode(publicKey, Base64.DEFAULT).contentEquals(host.fptcKey)) {
            "Bootstrap differs from immutable host"
        }

    /** This process's attempt: the active, authorized candidate, checked; once. */
    private fun select(): Attempt? {
        if (claimed) return null
        claimed = true
        HostTrustConfig.requireOwner(context)
        store.recoverAttempt()
        val meta = store.activeFor(fingerprint) ?: run {
            store.noPatch()
            return null
        }
        return try {
            auth.checkBoot(meta)
            Attempt(meta, format.code(store.root, meta)).also { attempt = it }
        } catch (error: Exception) {
            store.recordFailure(meta, error.message ?: "Candidate rejected")
            null
        }
    }

    private fun invalidateUnauthorized() {
        val candidate = store.active() ?: return
        val authorized = try { auth.checkBoot(candidate); true } catch (_: Exception) { false }
        if (!authorized) rollback()
    }

    /** Installs downloaded [bytes] that the signed manifest [wire] authorizes. */
    private fun install(fields: Map<String, String>, bytes: ByteArray, wire: String, progress: ProgressCallback): ApplyResult {
        progress("verifying", bytes.size.toLong(), bytes.size.toLong())
        val seq = try { PatchEnvelope.verify(bytes, fingerprint, host.fptcKey) }
            catch (e: Exception) { return ApplyResult.failure(ApplyErrorCode.SIGNATURE_INVALID, e.message) }
        return try {
            val hash = PatchEnvelope.digest(bytes)
            require(fields["sha256"] == hash && fields["patch_seq"]?.toLong() == seq) { "Manifest differs from payload" }
            val meta = store.candidate(fingerprint, seq, hash, fields.getValue("patch_seq"), wire)
            if (store.isBlacklisted(meta)) return ApplyResult.failure(ApplyErrorCode.BLACKLISTED, "$label candidate is blacklisted")
            store.requireNewer(meta)
            progress("finalizing", bytes.size.toLong(), bytes.size.toLong())
            check(store.root.isDirectory || store.root.mkdirs()) { "Cannot create ${store.root.name}" }
            format.install(store.root, meta, bytes, seq)
            store.save(meta)
            ApplyResult.SUCCESS
        } catch (e: java.io.IOException) { ApplyResult.failure(ApplyErrorCode.IO_ERROR, e.message) }
          catch (e: Exception) { ApplyResult.failure(ApplyErrorCode.INVALID_ARGS, e.message) }
    }
}