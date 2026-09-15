package com.flutter_patcher.flutter_patcher

import java.util.Base64

/** A complete root-authorized key set. Publishing keys cannot sign this document. */
internal object TrustUpdate {
    const val DOMAIN = "flutter_patcher.trust.v1\n"
    data class Decision(val revision: Long, val hash: String, val keys: Map<String, ByteArray>)

    fun keys(value: String): Map<String, ByteArray> {
        if (value == "-") return emptyMap()
        val rows = value.split(',')
        require(rows.size in 1..32 && rows == rows.sorted()) { "Key set order/size" }
        val result = linkedMapOf<String, ByteArray>()
        for (row in rows) {
            val pair = row.split(':')
            require(pair.size == 2 && Regex("[A-Za-z0-9_-]{1,64}").matches(pair[0])) { "Key identifier" }
            val bytes = Base64.getDecoder().decode(pair[1])
            require(bytes.size == 32 && Base64.getEncoder().encodeToString(bytes) == pair[1]) { "Key encoding" }
            require(result.put(pair[0], bytes) == null) { "Duplicate key" }
        }
        return result
    }

    fun verify(wire: String, root: ByteArray, scope: Map<String, String>,
        revision: Long, previousHash: String): Decision {
        require(wire.length <= 24000 && scope.keys == PublishManifest.scopeKeys) { "Trust envelope/scope" }
        val envelope = PublishManifest.strings(wire)
        require(envelope.keys == setOf("payload", "signature")) { "Trust envelope fields" }
        val bytes = Base64.getDecoder().decode(envelope.getValue("payload"))
        val signature = Base64.getDecoder().decode(envelope.getValue("signature"))
        require(bytes.size in 1..16384 && signature.size == 64) { "Trust envelope size" }
        val encoder = Base64.getEncoder()
        require(wire == "{\"payload\":\"${encoder.encodeToString(bytes)}\",\"signature\":\"${encoder.encodeToString(signature)}\"}") { "Trust envelope canonical form" }
        // ASCII validation also excludes malformed UTF-8 and JSON escape aliases.
        require(bytes.all { it.toInt() in 32..126 }) { "Trust ASCII" }
        val text = bytes.toString(Charsets.US_ASCII)
        val fields = PublishManifest.strings(text)
        require(fields.keys == scope.keys + setOf("schema", "revision", "keys")) { "Trust fields" }
        require(fields.values.all { v -> v.all { it.code in 33..126 && it != '"' && it != '\\' } }) { "Trust values" }
        require(text == PublishManifest.canonical(fields) && fields["schema"] == "1") { "Trust canonical/schema" }
        require(scope.all { (key, value) -> fields[key] == value }) { "Trust target" }
        val value = fields.getValue("revision")
        require(Regex("[1-9][0-9]{0,15}").matches(value)) { "Trust revision" }
        val next = value.toLong()
        require(next <= 9007199254740991 && next >= revision) { "Stale trust revision" }
        val digest = PublishManifest.hash(bytes)
        require(next != revision || digest == previousHash) { "Trust revision conflict" }
        val keys = keys(fields.getValue("keys"))
        require(Ed25519Verifier.verify(root, signature, DOMAIN.toByteArray(Charsets.US_ASCII) + bytes)) { "Trust signature" }
        return Decision(next, digest, keys)
    }
}
