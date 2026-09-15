package com.flutter_patcher.flutter_patcher

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Base64

/** Pure protocol verification. The caller must persist decisions atomically and
 * recheck authorization at install time; this module performs no side effects. */
internal object PublishManifest {
    private const val domain = "flutter_patcher.manifest.v1\n"
    val scopeKeys = setOf("application_id", "channel", "flavor", "version_code", "abi", "fingerprint", "strategy")
    private val common = scopeKeys + setOf("schema", "key_id", "revision", "minPluginVersion", "action")
    data class State(val revision: Long = 0, val manifestHash: String = "",
        val highSeq: Long = 0, val patchHash: String = "", val withdrawnThrough: Long = 0)
    data class Decision(val action: String, val fields: Map<String, String>, val next: State)

    private fun decode(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()
    internal fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }
    internal fun canonical(fields: Map<String, String>) = fields.toSortedMap().entries
        .joinToString(",", "{", "}") { "\"${it.key}\":\"${it.value}\"" }
    internal fun strings(text: String): Map<String, String> {
        val json = JSONObject(text)
        return json.keys().asSequence().associateWith { key ->
            val value = json.get(key)
            require(value is String) { "String fields required" }
            value
        }
    }
    fun parse(bytes: ByteArray): Map<String, String> {
        require(bytes.size <= 16384) { "Manifest too large" }
        val text = decode(bytes)
        val f = strings(text)
        val publish = f["action"] == "publish"
        require(f.keys == common + if (publish) setOf("patch_seq", "sha256", "size", "url")
            else setOf("withdraw_through_seq")) { "Unexpected fields" }
        require(f["schema"] == "1" && (publish || f["action"] == "withdraw")) { "Schema/action" }
        require(f.values.all { v -> v.length <= 2048 && v.all { it.code in 33..126 && it != '"' && it != '\\' } }) { "ASCII values" }
        fun matches(key: String, pattern: String) = Regex(pattern).matches(f.getValue(key))
        for (key in listOf("key_id", "channel", "flavor"))
            require(matches(key, "[A-Za-z0-9_-]{1,64}")) { key }
        require(matches("application_id", "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")) { "Application" }
        require(f["abi"] == "arm64-v8a" && f["strategy"] in setOf("bytecode", "so")) { "ABI/strategy" }
        require(matches("fingerprint", "[0-9a-f]{64}") || (f["strategy"] == "so" && f["fingerprint"] == "-")) { "Fingerprint" }
        version(f.getValue("minPluginVersion"))
        fun number(key: String, max: Long) {
            require(matches(key, "[1-9][0-9]{0,15}") && f.getValue(key).toLong() <= max) { key }
        }
        number("version_code", 2100000000)
        number("revision", 9007199254740991)
        number(if (publish) "patch_seq" else "withdraw_through_seq", 4294967295)
        if (publish) {
            number("size", 320L * 1024 * 1024)
            require(matches("sha256", "[0-9a-f]{64}")) { "SHA256" }
            require(matches("url", "https://[a-z0-9]+(?:[.-][a-z0-9]+)*(?::[1-9][0-9]{0,4})?(?:/(?:[A-Za-z0-9._~!${'$'}&'()*+,;=:@/?-]|%[0-9A-F]{2})*)?")) { "URL syntax" }
            val uri = java.net.URI(f.getValue("url"))
            require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.port <= 65535 && uri.rawUserInfo == null && uri.rawFragment == null) { "HTTPS URL required" }
        }
        require(text == canonical(f)) { "Noncanonical manifest" }
        return f.toMap()
    }
    fun signingBytes(bytes: ByteArray): ByteArray {
        parse(bytes)
        return domain.toByteArray(Charsets.UTF_8) + bytes
    }
    private fun version(value: String): List<Int> {
        require(Regex("(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})").matches(value)) { "Plugin version" }
        return value.split('.').map { it.toInt() }
    }
    private fun compatible(actual: String, minimum: String): Boolean {
        val a = version(actual); val b = version(minimum)
        for (i in 0..2) if (a[i] != b[i]) return a[i] > b[i]
        return true
    }

    /** trustedKeys and scope must come from host configuration, never this envelope.
     * State belongs to exactly this scope. No decision authenticates payload bytes. */
    fun verify(wire: String, trustedKeys: Map<String, ByteArray>, scope: Map<String, String>,
        pluginVersion: String, state: State): Decision {
        require(wire.length <= 24000 && scope.keys == scopeKeys) { "Envelope/scope" }
        val envelope = strings(wire)
        require(envelope.keys == setOf("payload", "signature")) { "Envelope fields" }
        val decoder = Base64.getDecoder(); val encoder = Base64.getEncoder()
        val bytes = decoder.decode(envelope.getValue("payload"))
        val sig = decoder.decode(envelope.getValue("signature"))
        require(sig.size == 64 && bytes.isNotEmpty()) { "Envelope size" }
        require(wire == "{\"payload\":\"${encoder.encodeToString(bytes)}\",\"signature\":\"${encoder.encodeToString(sig)}\"}") { "Noncanonical envelope" }
        val f = parse(bytes)
        val key = trustedKeys[f.getValue("key_id")] ?: error("Unknown key")
        require(Ed25519Verifier.verify(key, sig, domain.toByteArray(Charsets.UTF_8) + bytes)) { "Manifest signature" }
        require(scope.all { (k, v) -> f[k] == v }) { "Wrong target" }
        require(compatible(pluginVersion, f.getValue("minPluginVersion"))) { "Plugin too old" }
        val revision = f.getValue("revision").toLong()
        val digest = hash(bytes)
        require(revision >= state.revision) { "Stale manifest" }
        if (revision == state.revision) {
            require(digest == state.manifestHash) { "Revision conflict" }
            // Idempotent authorization, not a signal to reinstall or skip a failed download.
            return Decision(f.getValue("action"), f, state)
        }
        if (f["action"] == "withdraw") {
            val floor = maxOf(state.withdrawnThrough, f.getValue("withdraw_through_seq").toLong())
            return Decision("withdraw", f, state.copy(revision = revision, manifestHash = digest,
                highSeq = maxOf(state.highSeq, floor), withdrawnThrough = floor))
        }
        val seq = f.getValue("patch_seq").toLong()
        val patchHash = f.getValue("sha256")
        require(seq > state.withdrawnThrough && (seq > state.highSeq ||
            (seq == state.highSeq && patchHash == state.patchHash))) { "Patch sequence conflict" }
        return Decision("publish", f, state.copy(revision = revision, manifestHash = digest,
            highSeq = seq, patchHash = patchHash))
    }
}
