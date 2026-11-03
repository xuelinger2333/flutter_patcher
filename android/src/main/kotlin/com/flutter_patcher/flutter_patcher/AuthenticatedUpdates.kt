package com.flutter_patcher.flutter_patcher

import android.content.Context
import java.io.File
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
    /** Verifies [wire] against the accepted state without persisting it. */
    fun verify(wire: String): PublishManifest.Decision {
        val state = store.read()
        return PublishManifest.verify(wire, store.keys(state), host.scope, BuildConfig.PATCHER_VERSION, state.manifest)
    }
    /** Verifies [wire] without persisting it; `fresh` when accepting it would change state. */
    fun inspect(wire: String): Map<String, Any?> {
        val state = store.read()
        val decision = PublishManifest.verify(wire, store.keys(state), host.scope,
            BuildConfig.PATCHER_VERSION, state.manifest)
        return mapOf("action" to decision.action, "fresh" to (decision.next != state.manifest),
            "patch_seq" to decision.fields["patch_seq"])
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
        /** The payload Dart downloaded to [path]: the signed size and digest, then deleted. */
        fun payload(fields: Map<String, String>, path: String): ByteArray {
            val file = File(path)
            try {
                val expected = fields.getValue("size").toLong()
                require(file.isFile && file.length() == expected) { "Payload size" }
                val bytes = file.readBytes()
                require(bytes.size.toLong() == expected && PatchEnvelope.digest(bytes) == fields["sha256"]) { "Payload digest/size" }
                return bytes
            } finally { file.delete() }
        }
    }
}
