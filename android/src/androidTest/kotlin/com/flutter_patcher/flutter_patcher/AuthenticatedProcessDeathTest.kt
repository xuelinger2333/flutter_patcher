package com.flutter_patcher.flutter_patcher

import android.content.ContextWrapper
import android.os.Process
import android.os.Bundle
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import java.io.File
import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Run twice with the same run_id: phase=withdraw-kill, then phase=recover.
 * The first instrumentation process intentionally dies after durable withdrawal. */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 33)
class AuthenticatedProcessDeathTest {
    @Test fun withdrawalCommitBoundary() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue("Dedicated two-process acceptance driver required", args.containsKey("phase"))
        val run = args.getString("run_id") ?: error("run_id required")
        require(Regex("[a-f0-9]{32}").matches(run))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = object : ContextWrapper(instrumentation.targetContext) {
            override fun getNoBackupFilesDir() = File(super.getNoBackupFilesDir(), "auth-death-$run")
                .also { check(it.isDirectory || it.mkdirs()) }
        }
        val fixture = JSONObject(instrumentation.context.assets.open("auth-state.json").bufferedReader().use { it.readText() })
        val scope = fixture.getJSONObject("scope").let { j -> j.keys().asSequence().associateWith { j.getString(it) } }
        val key = Base64.getDecoder().decode(fixture.getString("public"))
        val host = HostTrustConfig(scope, key, key, mapOf("release" to key), "c".repeat(64))
        val manager = AuthenticatedUpdates(context, host)
        when (args.getString("phase")) {
            "withdraw-kill" -> {
                manager.accept(fixture.getString("publish"))
                manager.accept(fixture.getString("withdraw"))
                instrumentation.sendStatus(0, Bundle().apply { putString("boundary", "withdrawal_durable") })
                Process.killProcess(Process.myPid())
                error("Process kill returned")
            }
            "recover" -> {
                val state = ManifestStateStore(context, host).read()
                assertEquals(7L, state.manifest.withdrawnThrough)
                var rejected = false
                try { manager.checkBoot(JSONObject().put("authorization", fixture.getString("publish"))
                    .put("seq", 7).put("sha256", "b".repeat(64))) }
                catch (_: Exception) { rejected = true }
                assertTrue("Candidate resurrected after process death", rejected)
            }
            else -> error("Unknown process death phase")
        }
    }
}
