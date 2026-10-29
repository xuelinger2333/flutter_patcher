package com.flutter_patcher.flutter_patcher

import android.content.Context
import java.io.File
import org.json.JSONObject

/**
 * Authenticated SO host: a signed FPTC envelope carrying a v2 patch.zip is
 * verified, materialized by [PatchManager] and loaded by [LoaderHook] on the
 * next cold start. Candidate state lives in a [CandidateStore].
 */
internal class SoPatchManager(private val context: Context, private val host: HostTrustConfig) {
    companion object {
        private val lock = Any()
        /** Candidate armed by [boot] in this process, settled by [success] or [error]. */
        private var attempt: JSONObject? = null
        private const val HEADER = 146

        /** The loader hook did not install: nothing ran, so this is not a failure. */
        fun cancel(context: Context) = synchronized(lock) {
            if (attempt != null) CandidateStore(context, "so").clearAttempt()
            attempt = null
        }

        fun success(context: Context) = synchronized(lock) {
            val meta = attempt ?: return@synchronized
            CandidateStore(context, "so").apply {
                markSuccess(meta)
                diagnostic(BootDiagnosticStore.PATCHED, "SO first frame", meta)
            }
            attempt = null
        }

        /** Returns false when no SO attempt is armed, leaving the report to the legacy guard. */
        fun error(context: Context, message: String?): Boolean = synchronized(lock) {
            val meta = attempt ?: return@synchronized false
            val store = CandidateStore(context, "so")
            store.recordFailure(meta, message ?: "Dart boot failure")
            if (store.active() == null) PatchManager(context).rollback()
            attempt = null
            true
        }
    }
    init { require(host.strategy == "so") { "Host strategy is not so" } }
    private val auth = AuthenticatedUpdates(context, host)
    private val store = CandidateStore(context, "so")
    private val fingerprint = host.scope.getValue("fingerprint")

    fun applyManifest(wire: String, progress: ProgressCallback): Map<String, Any?> {
        val decision = synchronized(lock) { auth.verify(wire) }
        if (decision.action == "withdraw") {
            synchronized(lock) { auth.accept(wire); invalidateUnauthorized() }
            return mapOf("action" to "withdraw", "ok" to true)
        }
        progress("downloading", 0, decision.fields.getValue("size").toLong())
        // Accept only an intact payload, so a failed download stays retryable.
        val bytes = AuthenticatedUpdates.download(decision.fields)
        return synchronized(lock) {
            auth.accept(wire)
            install(bytes, auth.checkCommit(wire).fields, wire, progress).toMap() + mapOf("action" to "publish")
        }
    }

    fun inspect(wire: String) = synchronized(lock) { auth.inspect(wire) }

    fun updateTrust(wire: String) = synchronized(lock) {
        auth.updateTrust(wire)
        invalidateUnauthorized()
    }

    /** The patch to load now, or null to run the original app. */
    fun boot(): ValidPatch? = synchronized(lock) {
        HostTrustConfig.requireOwner(context)
        store.recoverAttempt()
        val patches = PatchManager(context)
        val meta = store.activeFor(fingerprint)
        if (meta == null) {
            store.noPatch()
            if (patches.candidate() != null) patches.rollback()
            return@synchronized null
        }
        try {
            auth.checkBoot(meta)
            require(patches.candidate() == store.id(meta)) { "Materialized patch differs from candidate" }
            val patch = patches.getValidPatch() ?: error("Materialized patch is invalid")
            store.markLoading(meta)
            attempt = meta
            patch
        } catch (error: Exception) {
            store.recordFailure(meta, error.message ?: "Candidate rejected")
            if (store.active() == null) patches.rollback()
            null
        }
    }


    fun rollback() = synchronized(lock) {
        HostTrustConfig.requireOwner(context)
        store.clearActive()
        PatchManager(context).rollback()
        attempt = null
    }

    fun blacklist() = synchronized(lock) { store.blacklist() }
    fun clearBlacklist() = synchronized(lock) {
        HostTrustConfig.requireOwner(context)
        store.clearBlacklist()
    }

    private fun invalidateUnauthorized() {
        val candidate = store.active() ?: return
        val authorized = try { auth.checkBoot(candidate); true } catch (_: Exception) { false }
        if (!authorized) rollback()
    }

    private fun install(bytes: ByteArray, fields: Map<String, String>, wire: String, progress: ProgressCallback): ApplyResult {
        progress("verifying", bytes.size.toLong(), bytes.size.toLong())
        val seq = try { BytecodeEnvelope.verify(bytes, fingerprint, host.fptcKey) }
            catch (e: Exception) { return ApplyResult.failure(ApplyErrorCode.SIGNATURE_INVALID, e.message) }
        return try {
            require(seq == fields.getValue("patch_seq").toLong()) { "Metadata sequence mismatch" }
            val meta = store.candidate(fingerprint, seq, BytecodeEnvelope.digest(bytes), fields.getValue("patch_seq"), wire)
            if (store.isBlacklisted(meta)) return ApplyResult.failure(ApplyErrorCode.BLACKLISTED, "SO candidate is blacklisted")
            store.requireNewer(meta)
            progress("finalizing", bytes.size.toLong(), bytes.size.toLong())
            // The envelope signs the package bytes; materialize exactly those.
            val payload = File(context.cacheDir, "so-${meta.getString("sha256")}.zip")
            try {
                payload.writeBytes(bytes.copyOfRange(HEADER, bytes.size))
                val result = PatchManager(context).installVerified(payload, meta.getString("version"), store.id(meta))
                if (!result.ok) return result
            } finally { payload.delete() }
            store.save(meta, null)
            ApplyResult.SUCCESS
        } catch (e: java.io.IOException) { ApplyResult.failure(ApplyErrorCode.IO_ERROR, e.message) }
          catch (e: Exception) { ApplyResult.failure(ApplyErrorCode.INVALID_ARGS, e.message) }
    }
}