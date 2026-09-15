package com.flutter_patcher.flutter_patcher

import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import java.io.File
import java.util.Base64
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Actual Android AtomicFile/state recovery, independent of a desktop mock. */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 33)
class AuthenticatedStateDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val fixture = JSONObject(instrumentation.context.assets.open("auth-state.json").bufferedReader().use { it.readText() })
    private val context = object : ContextWrapper(instrumentation.targetContext) {
        private val root = File(super.getNoBackupFilesDir(), "auth-test-${UUID.randomUUID()}")
        override fun getNoBackupFilesDir() = root.also { check(it.isDirectory || it.mkdirs()) }
    }
    private val scope = fixture.getJSONObject("scope").let { json -> json.keys().asSequence().associateWith { json.getString(it) } }
    private val key = Base64.getDecoder().decode(fixture.getString("public"))
    private val host = HostTrustConfig(scope, key, key, mapOf("release" to key), "c".repeat(64))
    private fun manager() = AuthenticatedUpdates(context, host)
    private fun candidate() = JSONObject().put("authorization", fixture.getString("publish"))
        .put("seq", 7).put("sha256", "b".repeat(64))
    private fun rejected(action: () -> Unit) {
        var failed = false
        try { action() } catch (_: Exception) { failed = true }
        assertTrue("Expected fail-closed rejection", failed)
    }
    @Test fun withdrawalSurvivesRestartBeforeCandidateCleanup() {
        manager().accept(fixture.getString("publish"))
        manager().checkBoot(candidate())
        manager().accept(fixture.getString("withdraw"))
        rejected { manager().checkBoot(candidate()) }
        rejected { manager().checkCommit(fixture.getString("publish")) }
        rejected { manager().accept(fixture.getString("publish")) }
    }
    @Test fun newestAuthorizationWinsWhileOldCandidateCanStillBoot() {
        manager().accept(fixture.getString("publish"))
        manager().accept(fixture.getString("newer"))
        manager().checkBoot(candidate())
        rejected { manager().checkCommit(fixture.getString("publish")) }
        assertEquals("8", manager().checkCommit(fixture.getString("newer")).fields["patch_seq"])
    }
    @Test fun rootRevocationPersistsAndOnlyRootCanRestore() {
        manager().accept(fixture.getString("publish"))
        manager().updateTrust(fixture.getString("revoke"))
        rejected { manager().checkBoot(candidate()) }
        rejected { manager().accept(fixture.getString("publish")) }
        rejected { manager().updateTrust(fixture.getString("publish")) }
        manager().updateTrust(fixture.getString("restore"))
        manager().checkBoot(candidate())
        rejected { manager().updateTrust(fixture.getString("revoke")) }
    }
    @Test fun corruptAndMissingStateNeverResetWatermarks() {
        manager().accept(fixture.getString("publish"))
        val state = File(context.noBackupFilesDir, "flutter_patcher_auth/${scope.getValue("fingerprint")}/state.json")
        state.writeText("{}")
        rejected { manager().checkBoot(candidate()) }
        rejected { manager().accept(fixture.getString("publish")) }
        check(state.delete())
        rejected { manager().accept(fixture.getString("publish")) }
    }
    @Test fun sameManifestCanRetryWithoutAdvancingOrResettingState() {
        val wire = fixture.getString("publish")
        val first = manager().accept(wire)
        assertEquals(first.next, manager().accept(wire).next)
        assertEquals(first.next, manager().checkCommit(wire).next)
    }
    @Test fun unfinishedAtomicWriteCannotReplaceCommittedRevocation() {
        manager().accept(fixture.getString("publish"))
        manager().accept(fixture.getString("withdraw"))
        val pending = File(context.noBackupFilesDir, "flutter_patcher_auth/${scope.getValue("fingerprint")}/state.json.new")
        pending.writeText("incomplete replacement")
        rejected { manager().checkBoot(candidate()) }
        rejected { manager().checkCommit(fixture.getString("publish")) }
    }
    @Test fun independentPublisherRequiresRootAuthorizationAndSurvivesOldKeyRetirement() {
        assertFalse(key.contentEquals(Base64.getDecoder().decode(fixture.getString("publisher_public"))))
        manager().accept(fixture.getString("publish"))
        rejected { manager().accept(fixture.getString("next_publish")) }
        manager().updateTrust(fixture.getString("add_publisher"))
        manager().accept(fixture.getString("next_publish"))
        val next = JSONObject().put("authorization", fixture.getString("next_publish"))
            .put("seq", 8).put("sha256", "d".repeat(64))
        manager().checkBoot(candidate())
        manager().checkBoot(next)
        manager().updateTrust(fixture.getString("retire_release"))
        rejected { manager().checkBoot(candidate()) }
        rejected { manager().updateTrust(fixture.getString("add_publisher")) }
        manager().checkBoot(next)
        manager().checkCommit(fixture.getString("next_publish"))
    }
}
