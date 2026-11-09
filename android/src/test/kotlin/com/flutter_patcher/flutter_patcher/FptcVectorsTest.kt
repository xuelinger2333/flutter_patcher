package com.flutter_patcher.flutter_patcher

import java.io.File
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import org.json.JSONObject

/** test/protocol/fptc-v1.json: the files every verifier must accept or reject alike. */
class FptcVectorsTest {
    private val vectors = JSONObject((System.getenv("FLUTTER_PATCHER_FPTC_VECTORS")?.let { File(it) }
        ?: File(projectRoot(), "test/protocol/fptc-v1.json")).readText())

    @Test fun everyVectorIsAcceptedOrRejectedAsTheFormatSays() {
        val files = vectors.getJSONArray("files")
        for (i in 0 until files.length()) {
            val row = files.getJSONObject(i)
            val name = row.getString("name")
            val bytes = Base64.getDecoder().decode(row.getString("file"))
            val key = if (row.isNull("host_key")) null else Base64.getDecoder().decode(row.getString("host_key"))
            if (row.getBoolean("valid")) {
                val header = PatchEnvelope.verify(bytes, row.getString("fingerprint"), key)
                assertEquals(row.getLong("seq"), header.seq, name)
                assertEquals(row.getString("action") == "withdraw", header.withdrawal, name)
            } else {
                assertFailsWith<IllegalArgumentException>(name) {
                    PatchEnvelope.verify(bytes, row.getString("fingerprint"), key)
                }
            }
        }
    }

    @Test fun aHeaderIsReadFromItsFirst146Bytes() {
        val bytes = TestPatches.patch(9)
        val header = PatchEnvelope.header(bytes.copyOf(PatchEnvelope.HEADER))
        assertEquals(TestPatches.FP, header.fingerprint)
        assertEquals(9L, header.seq)
        assertEquals(bytes.size.toLong() - PatchEnvelope.HEADER, header.length)
        assertFailsWith<IllegalArgumentException> { PatchEnvelope.header(bytes.copyOf(145)) }
    }

    private fun projectRoot(): File {
        var path = File(System.getProperty("user.dir")).absoluteFile
        while (!File(path, "test/protocol/fptc-v1.json").isFile) {
            path = path.parentFile ?: error("Set FLUTTER_PATCHER_FPTC_VECTORS to the shared vectors")
        }
        return path
    }
}
