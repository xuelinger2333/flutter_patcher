package com.flutter_patcher.flutter_patcher

import java.io.File
import java.util.Base64
import org.json.JSONObject
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assumptions.assumeTrue
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class BytecodeCorpusTest {
    @Test fun independentOpenSslCorpusReachesTheExpectedLayer() {
        val root = System.getenv("FLUTTER_PATCHER_TEST_CORPUS")
        assumeTrue(root != null, "FLUTTER_PATCHER_TEST_CORPUS is required for the corpus integration job")
        val suite = JSONObject(File(root!!, "corpus.json").readText())
        val key = Base64.getDecoder().decode(suite.getString("public_key"))
        val cases = suite.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val row = cases.getJSONObject(i)
            val bytes = File(root, row.getString("file")).readBytes()
            assertEquals(row.getString("sha256"), BytecodeEnvelope.digest(bytes), row.getString("id"))
            if (row.getString("layer") == "envelope") {
                val error = assertFailsWith<IllegalArgumentException>(row.getString("id")) {
                    BytecodeEnvelope.verify(bytes, suite.getString("fingerprint"), key)
                }
                assertEquals(row.getString("reason"), error.message, row.getString("id"))
            } else {
                // A valid outer signature is mandatory for deeper-layer cases.
                BytecodeEnvelope.verify(bytes, suite.getString("fingerprint"), key)
            }
        }
    }
}
