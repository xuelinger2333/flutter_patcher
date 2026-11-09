package com.flutter_patcher.flutter_patcher

import java.security.MessageDigest
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import org.json.JSONObject

/** Host policy schema 2. */
class HostTrustConfigTest {
    private val key = Base64.getEncoder().encodeToString(ByteArray(32) { 3 })
    private val fields = mapOf("schema" to "2", "strategy" to "bytecode", "abi" to "arm64-v8a",
        "application_id" to "com.example.app", "version_code" to "7", "flavor" to "default",
        "channel" to "production", "fptc_key" to key)

    private fun canonical(policy: Map<String, String>) = policy.toSortedMap().entries
        .joinToString(",", "{", "}") { "\"${it.key}\":\"${it.value}\"" }
    private fun sha(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
        .joinToString("") { "%02x".format(it) }

    private fun trust(policy: Map<String, String> = fields, text: String = canonical(policy),
        fingerprint: String = "ab".repeat(32), url: String? = null) = JSONObject()
        .put("policy", text).put("policy_sha256", sha(text)).put("fingerprint", fingerprint)
        .apply { if (url != null) put("url", url) }.toString()

    @Test fun aSignedHostTrustsItsPatchKey() {
        val host = HostTrustConfig.parse(trust(url = "https://cdn.example.com/p"))
        assertContentEquals(ByteArray(32) { 3 }, host.fptcKey)
        assertEquals("ab".repeat(32), host.fingerprint)
        assertEquals("bytecode", host.strategy)
        assertEquals("7", host.scope["version_code"])
        assertEquals("https://cdn.example.com/p", host.url)
    }

    @Test fun anUnsignedHostTrustsNoKey() {
        val host = HostTrustConfig.parse(trust(fields + ("fptc_key" to "-")))
        assertNull(host.fptcKey)
        assertNull(host.url)
    }

    @Test fun onlySchema2WithExactlyItsFieldsIsAccepted() {
        val schema1 = fields - "fptc_key" + mapOf("schema" to "1", "fptc_key" to key, "root_key" to key,
            "keys" to "release:$key")
        val rejected = listOf(
            schema1,
            fields + ("schema" to "3"),
            fields - "channel",
            fields + ("extra" to "x"),
            fields + ("fptc_key" to "AAAA"),
            fields + ("abi" to "x86_64"),
            fields + ("strategy" to "jit"),
            fields + ("version_code" to "07"),
            fields + ("version_code" to "2100000001"),
            fields + ("flavor" to "a b"),
            fields + ("flavor" to "a-b"),
            fields + ("channel" to "b-c"),
            fields + ("application_id" to "example"),
        )
        for (policy in rejected) {
            assertFailsWith<Exception>(policy.toString()) { HostTrustConfig.parse(trust(policy)) }
        }
    }

    @Test fun thePolicyMustBeCanonicalAndMatchItsDigest() {
        assertFailsWith<Exception> { HostTrustConfig.parse(trust(text = canonical(fields) + " ")) }
        val tampered = JSONObject(trust()).put("policy_sha256", "0".repeat(64)).toString()
        assertFailsWith<Exception> { HostTrustConfig.parse(tampered) }
        assertFailsWith<Exception> { HostTrustConfig.parse(trust(fingerprint = "AB".repeat(32))) }
        assertFailsWith<Exception> { HostTrustConfig.parse(trust(url = "ftp://example.com")) }
    }
}
