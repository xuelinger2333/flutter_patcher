package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.AtomicFile
import android.system.Os
import android.system.OsConstants
import java.io.File
import org.json.JSONObject

/** Called only under the owning BytecodePatchManager monitor, in the main process.
 * Missing state after initialization and corrupted state both fail closed. */
internal class ManifestStateStore(context: Context, private val host: HostTrustConfig) {
    data class State(val manifest: PublishManifest.State = PublishManifest.State(),
        val trustWire: String = "", val trustRevision: Long = 0, val trustHash: String = "")
    private val directory = File(context.noBackupFilesDir, "flutter_patcher_auth/${host.scope.getValue("fingerprint")}")
    private val file = AtomicFile(File(directory, "state.json"))
    private val initialized = File(directory, "initialized")

    fun read(): State {
        if (!directory.exists()) check(directory.mkdirs()) { "Cannot create authorization directory" }
        if (!initialized.exists()) {
            // Commit initial state first. A kill before marker creation may only
            // repeat initialization if no accepted authorization exists yet.
            if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) write(State())
            check(initialized.createNewFile()) { "Cannot initialize authorization state" }
            java.io.FileOutputStream(initialized, true).use { it.fd.sync() }
            syncDirectory()
        }
        val bytes = file.openRead().use { it.readNBytes(65537) }
        require(bytes.size <= 65536) { "Authorization state too large" }
        val outer = JSONObject(bytes.toString(Charsets.UTF_8))
        val text = outer.getString("state")
        require(outer.getString("sha256") == PublishManifest.hash(text.toByteArray(Charsets.UTF_8))) { "Authorization state corrupt" }
        val data = JSONObject(text)
        require(data.getInt("schema") == 1 && data.getString("policy") == host.policyHash) { "Authorization state identity" }
        val state = State(PublishManifest.State(data.getLong("revision"), data.getString("manifestHash"),
            data.getLong("highSeq"), data.getString("patchHash"), data.getLong("withdrawnThrough")),
            data.getString("trustWire"), data.getLong("trustRevision"), data.getString("trustHash"))
        require(state.manifest.revision >= 0 && state.manifest.highSeq >= state.manifest.withdrawnThrough &&
            state.manifest.withdrawnThrough >= 0 && state.trustRevision >= 0) { "Authorization state ranges" }
        keys(state) // Persisted trust data is never accepted without root re-verification.
        return state
    }

    fun keys(state: State): Map<String, ByteArray> {
        if (state.trustRevision == 0L) {
            require(state.trustWire.isEmpty() && state.trustHash.isEmpty()) { "Trust state corrupt" }
            return host.initialKeys
        }
        val trust = TrustUpdate.verify(state.trustWire, host.root, host.scope, state.trustRevision, state.trustHash)
        require(trust.revision == state.trustRevision && trust.hash == state.trustHash) { "Trust state mismatch" }
        return trust.keys
    }

    fun write(state: State) {
        val m = state.manifest
        val text = JSONObject().put("schema", 1).put("policy", host.policyHash)
            .put("revision", m.revision).put("manifestHash", m.manifestHash)
            .put("highSeq", m.highSeq).put("patchHash", m.patchHash).put("withdrawnThrough", m.withdrawnThrough)
            .put("trustWire", state.trustWire).put("trustRevision", state.trustRevision).put("trustHash", state.trustHash).toString()
        val bytes = JSONObject().put("state", text)
            .put("sha256", PublishManifest.hash(text.toByteArray(Charsets.UTF_8))).toString().toByteArray(Charsets.UTF_8)
        val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream); syncDirectory() }
        catch (error: Throwable) { file.failWrite(stream); throw error }
    }

    private fun syncDirectory() {
        val descriptor = Os.open(directory.absolutePath, OsConstants.O_RDONLY, 0)
        try { Os.fsync(descriptor) } finally { Os.close(descriptor) }
    }
}
