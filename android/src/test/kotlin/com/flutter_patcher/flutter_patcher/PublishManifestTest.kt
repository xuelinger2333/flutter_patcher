package com.flutter_patcher.flutter_patcher

import java.io.File
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertTrue

class PublishManifestTest {
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    @Test fun sharedVectors() {
        val file = System.getenv("WP21_VECTORS")?.let { File(it) }
            ?: File(projectRoot(), "test/protocol/manifest-v1.json")
        val vectors = JSONArray(file.readText())
        for (i in 0 until vectors.length()) {
            val row = vectors.getJSONObject(i)
            val name = row.getString("name")
            try {
                val payload = Base64.getDecoder().decode(row.getString("payload"))
                if (row.getBoolean("parse_valid")) {
                    assertEquals(row.getString("signing_hex"), PublishManifest.signingBytes(payload)
                        .joinToString("") { "%02x".format(it) }, name)
                } else assertFails(name) { PublishManifest.parse(payload) }
                val s = row.getJSONObject("state")
                val state = PublishManifest.State(s.optLong("revision"), s.optString("manifestHash"),
                    s.optLong("highSeq"), s.optString("patchHash"), s.optLong("withdrawnThrough"))
                val target = row.getJSONObject("scope")
                fun verify() = PublishManifest.verify(row.getString("wire"),
                    mapOf("release" to hex(row.getString("public_key"))),
                    target.keys().asSequence().associateWith { target.getString(it) },
                    row.getString("plugin_version"), state)
                if (row.getBoolean("verify_valid")) {
                    val decision = verify()
                    assertEquals(row.getString("action"), decision.action, name)
                    assertTrue(decision.next.withdrawnThrough >= state.withdrawnThrough, name)
                    assertTrue(decision.next.highSeq >= state.highSeq, name)
                    assertEquals(decision.fields.getValue("revision").toLong(), decision.next.revision, name)
                    if (decision.action == "withdraw") assertTrue(decision.next.withdrawnThrough >=
                        decision.fields.getValue("withdraw_through_seq").toLong(), name)
                    else assertEquals(decision.fields["sha256"], decision.next.patchHash, name)
                } else assertFails(name) { verify() }
            } catch (e: Throwable) { throw AssertionError("Vector: $name", e) }
        }
    }
    private fun projectRoot(): File {
        var path = File(System.getProperty("user.dir")).absoluteFile
        while (!File(path, "test/protocol/manifest-v1.json").isFile) {
            path = path.parentFile ?: error("Set WP21_VECTORS to shared vectors")
        }
        return path
    }
}
