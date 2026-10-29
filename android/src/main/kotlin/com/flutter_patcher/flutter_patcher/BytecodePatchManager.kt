package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.os.Build
import android.util.Base64
import java.util.UUID
import org.json.JSONObject

/** Separate files/preferences from legacy SO installation. All commits are serialized. */
internal class BytecodePatchManager(private val context: Context) {
    companion object {
        private val lock = Any()
        private var processClaimed = false
    }
    private val store = CandidateStore(context, "bytecode")
    private val host by lazy { HostTrustConfig.load(context) }
    // An SO host has no bytecode updates; its policy never authorizes this manager.
    private val authenticated by lazy { host?.takeIf { it.strategy == "bytecode" }?.let { AuthenticatedUpdates(context, it) } }
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

    fun bootPayload(fp: String, publicKey: String): Map<String, Any?>? {
      val lockRequested = System.nanoTime()
      return synchronized(lock) {
        val profileStart = System.nanoTime()
        fun elapsedUs() = (System.nanoTime() - profileStart) / 1000
        // Bytecode runs only on a host whose policy authorizes it.
        val host = host ?: error("Bytecode requires a host policy")
        require(host.strategy == "bytecode") { "Host strategy is not bytecode" }
        HostTrustConfig.requireOwner(context)
        require(fp == host.scope["fingerprint"] &&
            Base64.decode(publicKey, Base64.DEFAULT).contentEquals(host.fptcKey)) { "Bootstrap differs from immutable host" }
        val policyUs = elapsedUs() // [PROFILE] Includes lazy APK policy loading.
        if (fingerprint != null || processClaimed) return@synchronized null
        processClaimed = true
        require(Regex("[0-9a-f]{64}").matches(fp)) { "Invalid host fingerprint" }
        val raw = Base64.decode(publicKey, Base64.DEFAULT)
        require(raw.size == 32) { "Invalid host public key" }
        fingerprint = fp
        key = raw
        if (Build.VERSION.SDK_INT < 28) {
            store.diagnostic("BYTECODE_UNSUPPORTED", "Bytecode verification requires Android API 28")
            return@synchronized null
        }
        store.recoverAttempt()
        val meta = store.activeFor(fp) ?: run { store.noPatch(); return@synchronized null }
        try {
            val authorizationStartUs = elapsedUs()
            authenticated?.checkBoot(meta)
            val preparedUs = elapsedUs()
            val bytes = CandidateStore.readBounded(store.file(meta).inputStream())
            val readUs = elapsedUs()
            val seq = BytecodeEnvelope.verify(bytes, fp, raw)
            val verifiedUs = elapsedUs()
            require(seq == meta.getLong("seq") && BytecodeEnvelope.digest(bytes) == meta.getString("sha256")) { "Stored candidate changed" }
            val digestUs = elapsedUs()
            offered = UUID.randomUUID().toString()
            attempt = BytecodeAttempt(offered!!)
            offeredMeta = meta
            // This exact local snapshot passed verification above. Never reopen
            // the path or mutate the array after handing it to the codec.
            mapOf("transportVersion" to 1, "envelopeBytes" to bytes, "attempt" to offered,
                "profile_us" to mapOf("lock_wait" to (profileStart - lockRequested) / 1000,
                    "prepare" to preparedUs, "read" to readUs - preparedUs,
                    "host_policy" to policyUs,
                    "candidate_recovery" to authorizationStartUs - policyUs,
                    "authorization" to preparedUs - authorizationStartUs,
                    "envelope_verify" to verifiedUs - readUs, "file_digest" to digestUs - verifiedUs,
                    "total" to elapsedUs()))
        } catch (error: Exception) {
            store.recordFailure(meta, error.message ?: "Candidate rejected")
            null
        }
      }
    }

    fun markBooting(token: String?): Boolean = synchronized(lock) {
        if (token == null || token != offered || attempt?.running == true || attempt?.failed == true) return@synchronized false
        val meta = offeredMeta ?: return@synchronized false
        try { authenticated?.checkBoot(meta) } catch (_: Exception) { return@synchronized false }
        // A rollback or a newly installed candidate invalidates a prepared offer.
        if (store.active()?.let { store.id(it) } != store.id(meta)) return@synchronized false
        store.markLoading(meta)
        val started = attempt?.start(token) == true
        if (started) frameToken = token
        started
    }

    fun success(token: String?) = synchronized(lock) {
        // Untokened legacy init/first-frame reports cannot settle a v2 attempt.
        if (token == null || attempt?.succeed(token) != true) return@synchronized
        val meta = offeredMeta ?: return@synchronized
        store.markSuccess(meta)
        store.diagnostic(BootDiagnosticStore.PATCHED, "Bytecode first frame", meta)
    }

    fun firstFrame(token: String) = synchronized(lock) { success(token) }

    fun error(token: String?, message: String?, quarantine: Boolean = false) = synchronized(lock) {
        if (token == null || token != offered) return@synchronized
        if (attempt?.fail(token) != true) {
            // init() and bootstrap may report the same error in either order.
            // A later fatal report escalates disposition, never the crash count.
            if (quarantine && attempt?.failed == true) {
                offeredMeta?.let { store.recordFailure(it, message ?: "Unsafe startup", true, false) }
            }
            return@synchronized
        }
        frameToken = null
        offeredMeta?.let { store.recordFailure(it, message ?: "Dart boot failure", quarantine) }
        store.clearAttempt()
    }


    fun applyManifest(wire: String, progress: ProgressCallback): Map<String, Any?> {
        val auth = authenticated ?: error("Host has no authenticated policy")
        val decision = synchronized(lock) { auth.verify(wire) }
        if (decision.action == "withdraw") {
            synchronized(lock) { auth.accept(wire); invalidateUnauthorized(auth) }
            return mapOf("action" to "withdraw", "ok" to true)
        }
        progress("downloading", 0, decision.fields.getValue("size").toLong())
        // Accept only an intact payload, so a failed download stays retryable.
        val bytes = AuthenticatedUpdates.download(decision.fields)
        return synchronized(lock) {
            auth.accept(wire)
            val fields = auth.checkCommit(wire).fields
            val result = install(fields, bytes, wire, progress)
            result.toMap() + mapOf("action" to "publish")
        }
    }

    fun inspect(wire: String) = synchronized(lock) {
        (authenticated ?: error("Host has no authenticated policy")).inspect(wire)
    }

    fun updateTrust(wire: String) = synchronized(lock) {
        val auth = authenticated ?: error("Host has no authenticated policy")
        auth.updateTrust(wire)
        invalidateUnauthorized(auth)
    }

    private fun invalidateUnauthorized(auth: AuthenticatedUpdates) {
        val candidate = store.active() ?: return
        val authorized = try { auth.checkBoot(candidate); true } catch (_: Exception) { false }
        if (!authorized) rollback()
    }

    /** Installs downloaded [bytes] that the signed manifest [wire] authorizes. */
    private fun install(fields: Map<String, String>, bytes: ByteArray, wire: String,
        progress: ProgressCallback): ApplyResult = synchronized(lock) {
        if (Build.VERSION.SDK_INT < 28 || fingerprint == null || key == null)
            return@synchronized ApplyResult.failure(ApplyErrorCode.SIGNATURE_INVALID, "A bootstrapped Android API 28+ host is required")
        try {
            progress("verifying", bytes.size.toLong(), bytes.size.toLong())
            val seq: Long
            try { seq = BytecodeEnvelope.verify(bytes, fingerprint!!, key!!) }
            catch (e: Exception) { return@synchronized ApplyResult.failure(ApplyErrorCode.SIGNATURE_INVALID, e.message) }
            val hash = BytecodeEnvelope.digest(bytes)
            require(fields["sha256"] == hash && fields["patch_seq"]?.toLong() == seq) { "Manifest differs from payload" }
            val meta = store.candidate(fingerprint!!, seq, hash, fields.getValue("patch_seq"), wire)
            if (store.isBlacklisted(meta))
                return@synchronized ApplyResult.failure(ApplyErrorCode.BLACKLISTED, "Bytecode candidate is blacklisted")
            store.requireNewer(meta)
            progress("finalizing", bytes.size.toLong(), bytes.size.toLong())
            store.save(meta, bytes)
            ApplyResult.SUCCESS
        } catch (e: java.io.IOException) { ApplyResult.failure(ApplyErrorCode.IO_ERROR, e.message) }
          catch (e: Exception) { ApplyResult.failure(ApplyErrorCode.INVALID_ARGS, e.message) }
    }

    fun rollback() = synchronized(lock) {
        if (host != null) HostTrustConfig.requireOwner(context)
        store.clearActive()
        offered = null
        attempt = null
        frameToken = null
    }
    fun currentVersion(): String? = synchronized(lock) { store.active()?.optString("version") }
    fun blacklist(): List<Map<String, Any?>> = synchronized(lock) { store.blacklist() }
    fun clearBlacklist() = synchronized(lock) {
        if (host != null) HostTrustConfig.requireOwner(context)
        store.clearBlacklist()
    }
}
