package com.flutter_patcher.flutter_patcher

import android.content.Context
import java.net.HttpURLConnection
import java.net.URI
import org.json.JSONObject

/** Authorization transactions; caller holds the bytecode monitor except download. */
internal class AuthenticatedUpdates(context: Context, val host: HostTrustConfig) {
    private val store = ManifestStateStore(context, host)
    init { HostTrustConfig.requireOwner(context) }

    fun accept(wire: String): PublishManifest.Decision {
        val state = store.read()
        val decision = PublishManifest.verify(wire, store.keys(state), host.scope,
            BuildConfig.PATCHER_VERSION, state.manifest)
        store.write(state.copy(manifest = decision.next))
        return decision
    }
    fun updateTrust(wire: String) {
        val state = store.read()
        val update = TrustUpdate.verify(wire, host.root, host.scope, state.trustRevision, state.trustHash)
        store.write(state.copy(trustWire = wire, trustRevision = update.revision, trustHash = update.hash))
    }
    fun checkCommit(wire: String): PublishManifest.Decision {
        val state = store.read()
        val decision = PublishManifest.verify(wire, store.keys(state), host.scope,
            BuildConfig.PATCHER_VERSION, state.manifest)
        require(decision.action == "publish" && decision.next == state.manifest &&
            decision.fields.getValue("patch_seq").toLong() > state.manifest.withdrawnThrough) { "Authorization superseded" }
        return decision
    }
    fun checkBoot(meta: JSONObject) {
        val state = store.read()
        val decision = PublishManifest.verify(meta.getString("authorization"), store.keys(state), host.scope,
            BuildConfig.PATCHER_VERSION, PublishManifest.State())
        require(decision.action == "publish" && decision.next.revision <= state.manifest.revision &&
            decision.next.highSeq <= state.manifest.highSeq &&
            (decision.next.revision != state.manifest.revision || decision.next.manifestHash == state.manifest.manifestHash) &&
            decision.fields.getValue("patch_seq").toLong() > state.manifest.withdrawnThrough &&
            decision.fields.getValue("patch_seq").toLong() == meta.getLong("seq") &&
            decision.fields["sha256"] == meta.getString("sha256")) { "Candidate authorization withdrawn" }
    }

    companion object {
        /** No ambient credentials, redirects, unbounded bodies, or URL diagnostics. */
        fun download(fields: Map<String, String>): ByteArray {
            val expected = fields.getValue("size").toInt()
            val uri = URI(fields.getValue("url"))
            require(uri.scheme == "https" && uri.rawUserInfo == null && uri.rawFragment == null) { "HTTPS required" }
            val connection = uri.toURL().openConnection() as HttpURLConnection
            val started = System.nanoTime()
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 15000
                connection.readTimeout = 15000
                require(connection.responseCode == 200) { "Download HTTP status rejected" }
                require(connection.contentLengthLong == -1L || connection.contentLengthLong == expected.toLong()) { "Download length" }
                val out = java.io.ByteArrayOutputStream(minOf(expected, 65536))
                connection.inputStream.use { stream ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        require(System.nanoTime() - started < 120_000_000_000L) { "Download deadline" }
                        val count = stream.read(buffer)
                        if (count < 0) break
                        require(out.size().toLong() + count <= expected) { "Download size" }
                        out.write(buffer, 0, count)
                    }
                }
                val bytes = out.toByteArray()
                require(bytes.size == expected && BytecodeEnvelope.digest(bytes) == fields["sha256"]) { "Download digest/size" }
                return bytes
            } finally { connection.disconnect() }
        }
    }
}
