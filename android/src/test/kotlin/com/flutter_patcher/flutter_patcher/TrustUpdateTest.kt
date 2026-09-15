package com.flutter_patcher.flutter_patcher

import java.security.KeyPairGenerator
import java.security.Signature
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertTrue

class TrustUpdateTest {
    private val root = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
    private val public = root.public.encoded.takeLast(32).toByteArray()
    private val scope = mapOf("application_id" to "com.example.test", "channel" to "stable",
        "flavor" to "default", "version_code" to "1", "abi" to "arm64-v8a",
        "fingerprint" to "a".repeat(64), "strategy" to "bytecode")
    private fun wire(revision: String = "1", keys: String = "-", target: Map<String, String> = scope,
        domain: String = TrustUpdate.DOMAIN): String {
        val bytes = PublishManifest.canonical(target + mapOf("schema" to "1", "revision" to revision, "keys" to keys)).toByteArray()
        val signer = Signature.getInstance("Ed25519")
        signer.initSign(root.private); signer.update(domain.toByteArray() + bytes)
        val b64 = Base64.getEncoder()
        return "{\"payload\":\"${b64.encodeToString(bytes)}\",\"signature\":\"${b64.encodeToString(signer.sign())}\"}"
    }
    @Test fun rootAuthorizedLifecycleAndReplay() {
        val key = Base64.getEncoder().encodeToString(public)
        val first = wire(keys = "first:$key,next:$key")
        val accepted = TrustUpdate.verify(first, public, scope, 0, "")
        assertEquals(setOf("first", "next"), accepted.keys.keys)
        assertEquals(accepted.hash, TrustUpdate.verify(first, public, scope, 1, accepted.hash).hash)
        val removed = TrustUpdate.verify(wire("2", "next:$key"), public, scope, 1, accepted.hash)
        assertEquals(setOf("next"), removed.keys.keys)
        assertFails { TrustUpdate.verify(first, public, scope, 2, removed.hash) }
        assertFails { TrustUpdate.verify(wire(), public, scope, 1, accepted.hash) }
        assertTrue(TrustUpdate.verify(wire("3"), public, scope, 2, removed.hash).keys.isEmpty())
    }
    @Test fun domainRootTargetAndCanonicalForm() {
        val other = KeyPairGenerator.getInstance("Ed25519").generateKeyPair().public.encoded.takeLast(32).toByteArray()
        assertFails { TrustUpdate.verify(wire(), other, scope, 0, "") }
        assertFails { TrustUpdate.verify(wire(domain = "flutter_patcher.manifest.v1\n"), public, scope, 0, "") }
        assertFails { TrustUpdate.verify(wire(target = scope + ("channel" to "beta")), public, scope, 0, "") }
        assertFails { TrustUpdate.verify(wire() + "\n", public, scope, 0, "") }
        assertFails { TrustUpdate.verify(wire("01"), public, scope, 0, "") }
        assertFails { TrustUpdate.verify(wire("9007199254740992"), public, scope, 0, "") }
    }
    @Test fun boundedKeySet() {
        val key = Base64.getEncoder().encodeToString(public)
        assertFails { TrustUpdate.keys("z:$key,a:$key") }
        assertFails { TrustUpdate.keys("a:$key,a:$key") }
        assertFails { TrustUpdate.keys("a:bad") }
        assertFails { TrustUpdate.keys((1..33).map { "k${it.toString().padStart(2, '0')}:$key" }.joinToString(",")) }
    }
}
