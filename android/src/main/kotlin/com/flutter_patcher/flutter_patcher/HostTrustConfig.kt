package com.flutter_patcher.flutter_patcher

import android.annotation.SuppressLint
import android.app.Application
import android.content.Context
import android.os.Build
import java.security.MessageDigest
import java.util.Base64
import java.util.zip.ZipFile
import org.json.JSONObject

/**
 * The host policy `build` packed into the installed APK, not a mutable Dart
 * config or a patched asset overlay: which build this is and the patch key
 * it trusts, if any ([fptcKey] null: patch files are not signed).
 */
internal class HostTrustConfig internal constructor(val scope: Map<String, String>,
    val fptcKey: ByteArray?, val policyHash: String, val url: String? = null) {
    val strategy: String get() = scope.getValue("strategy")
    val fingerprint: String get() = scope.getValue("fingerprint")

    companion object {
        const val ASSET = "assets/flutter_patcher/host-trust.json"
        val scopeKeys = setOf("application_id", "channel", "flavor", "version_code", "abi", "fingerprint", "strategy")
        private val policyKeys = scopeKeys - "fingerprint" + setOf("schema", "fptc_key")

        fun load(context: Context): HostTrustConfig? = ZipFile(context.applicationInfo.sourceDir).use { apk ->
            val entry = apk.getEntry(ASSET) ?: return@use null
            // Fail closed: a patchable host below API 28 runs its original app.
            check(Build.VERSION.SDK_INT >= 28) { "Patchable host requires Android API 28+" }
            require(entry.size in 1..24000) { "Host policy size" }
            val host = parse(CandidateStore.readBounded(apk.getInputStream(entry), 24000, "Host policy")
                .toString(Charsets.UTF_8))
            require(host.scope["application_id"] == context.packageName &&
                host.scope["version_code"] == PatcherConfig.currentVersionCode(context).toString() &&
                Build.SUPPORTED_ABIS.firstOrNull() == host.scope["abi"]) { "Host policy target" }
            host
        }

        /** The packed host trust [text]: policy schema 2, its digest, fingerprint and optional url. */
        @SuppressLint("NewApi") // java.util.Base64 (API 26) runs only after the API 28 check.
        fun parse(text: String): HostTrustConfig {
            val wrapper = JSONObject(text)
            val policyText = wrapper.getString("policy")
            val json = JSONObject(policyText)
            val policy = json.keys().asSequence().associateWith { key ->
                json.get(key).also { require(it is String) { "Host policy strings" } } as String
            }
            require(policyText == canonical(policy)) { "Host policy canonical form" }
            require(policy.keys == policyKeys && policy["schema"] == "2") { "Host policy fields" }
            val hash = MessageDigest.getInstance("SHA-256").digest(policyText.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            require(hash == wrapper.getString("policy_sha256")) { "Host policy hash" }
            val scope = scopeKeys.associateWith { if (it == "fingerprint") wrapper.getString(it) else policy.getValue(it) }
            fun matches(key: String, pattern: String) = Regex(pattern).matches(scope.getValue(key))
            require(matches("fingerprint", "[0-9a-f]{64}")) { "Fingerprint" }
            require(matches("application_id", "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")) { "Application" }
            require(matches("channel", "[A-Za-z0-9_-]{1,64}") && matches("flavor", "[A-Za-z0-9_-]{1,64}")) { "Channel/flavor" }
            require(matches("version_code", "[1-9][0-9]{0,9}") &&
                scope.getValue("version_code").toLong() <= 2100000000) { "Version code" }
            require(scope["abi"] == "arm64-v8a" && scope["strategy"] in setOf("bytecode", "so")) { "ABI/strategy" }
            val key = policy.getValue("fptc_key").takeIf { it != "-" }?.let {
                Base64.getDecoder().decode(it).also { bytes ->
                    require(bytes.size == 32 && Base64.getEncoder().encodeToString(bytes) == it) { "Host key encoding" }
                }
            }
            // Where `build` was told devices download patches; outside the policy and its hash.
            val url = if (wrapper.has("url")) wrapper.getString("url") else null
            require(url == null || url.startsWith("https://") || url.startsWith("http://")) { "Host URL" }
            return HostTrustConfig(scope, key, hash, url)
        }

        private fun canonical(fields: Map<String, String>) = fields.toSortedMap().entries
            .joinToString(",", "{", "}") { "\"${it.key}\":\"${it.value}\"" }

        fun requireOwner(context: Context) {
            require(Build.VERSION.SDK_INT >= 28 && Application.getProcessName() == context.packageName) {
                "Patches are managed by the default application process on API 28+"
            }
        }
    }
}
