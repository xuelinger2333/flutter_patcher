package com.flutter_patcher.flutter_patcher

import android.app.Application
import android.content.Context
import android.os.Build
import java.util.Base64
import java.util.zip.ZipFile
import org.json.JSONObject

/** Read the installed APK, not a mutable Dart config or a patched asset overlay. */
internal class HostTrustConfig internal constructor(val scope: Map<String, String>,
    val fptcKey: ByteArray, val root: ByteArray, val initialKeys: Map<String, ByteArray>,
    val policyHash: String) {
    companion object {
        const val ASSET = "assets/flutter_patcher/host-trust.json"
        fun load(context: Context): HostTrustConfig? = ZipFile(context.applicationInfo.sourceDir).use { apk ->
            val entry = apk.getEntry(ASSET) ?: return@use null
            require(entry.size in 1..24000) { "Host policy size" }
            val wrapper = JSONObject(apk.getInputStream(entry).use {
                val bytes = it.readNBytes(24001)
                require(bytes.size <= 24000) { "Host policy size" }
                bytes.toString(Charsets.UTF_8)
            })
            val text = wrapper.getString("policy")
            val policy = PublishManifest.strings(text)
            require(text == PublishManifest.canonical(policy)) { "Host policy canonical form" }
            val expected = (PublishManifest.scopeKeys - "fingerprint") + setOf("schema", "fptc_key", "root_key", "keys")
            require(policy.keys == expected && policy["schema"] == "1" && policy["strategy"] == "bytecode") { "Host policy fields" }
            val hash = PublishManifest.hash(text.toByteArray(Charsets.UTF_8))
            require(hash == wrapper.getString("policy_sha256")) { "Host policy hash" }
            val scope = PublishManifest.scopeKeys.associateWith { name ->
                if (name == "fingerprint") wrapper.getString(name) else policy.getValue(name)
            }
            PublishManifest.parse(PublishManifest.canonical(scope + mapOf(
                "schema" to "1", "key_id" to "root", "revision" to "1",
                "minPluginVersion" to "0.0.0", "action" to "withdraw", "withdraw_through_seq" to "1"
            )).toByteArray(Charsets.UTF_8))
            require(scope["application_id"] == context.packageName &&
                scope["version_code"] == PatcherConfig.currentVersionCode(context).toString() &&
                Build.SUPPORTED_ABIS.firstOrNull() == scope["abi"]) { "Host policy target" }
            fun key(name: String): ByteArray {
                val value = policy.getValue(name)
                val bytes = Base64.getDecoder().decode(value)
                require(bytes.size == 32 && Base64.getEncoder().encodeToString(bytes) == value) { "Host key encoding" }
                return bytes
            }
            HostTrustConfig(scope, key("fptc_key"), key("root_key"), TrustUpdate.keys(policy.getValue("keys")), hash)
        }
        fun requireOwner(context: Context) {
            require(Build.VERSION.SDK_INT >= 33 && Application.getProcessName() == context.packageName) {
                "Authenticated updates require the default application process on API 33+"
            }
        }
    }
}
