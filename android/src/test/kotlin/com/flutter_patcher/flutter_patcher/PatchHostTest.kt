package com.flutter_patcher.flutter_patcher

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The device rules for FPTC v1 patch files, against a real
 * Context. A new [PatchHost] on the same Context is the next process.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PatchHostTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val noProgress: ProgressCallback = { _, _, _ -> }
    private val signer = TestPatches.keyPair()
    private val unsigned = TestPatches.host(null)
    private val signed = TestPatches.host(TestPatches.raw(signer))

    private fun process(host: HostTrustConfig = unsigned) = PatchHost(context, host, BytecodeFormat)
    private fun PatchHost.apply(bytes: ByteArray) = apply(bytes, noProgress)
    private fun Map<String, Any?>.ok() = this["ok"] == true
    private fun publicKey(host: HostTrustConfig) =
        host.fptcKey?.let { Base64.getEncoder().encodeToString(it) } ?: "-"
    private fun PatchHost.boots(host: HostTrustConfig = unsigned) = bootPayload(TestPatches.FP, publicKey(host))

    @Test fun anUnsignedHostInstallsANewerPatchForTheNextColdStart() {
        val host = process()
        assertNull(host.boots())
        val result = host.apply(TestPatches.patch(10))
        assertTrue(result.toString(), result.ok())
        assertEquals("publish", result["action"])
        assertEquals("10", host.currentVersion())
        assertEquals(10L, host.target()["acceptedSeq"])
        assertNotNull(process().boots())
    }

    @Test fun aSignedHostAcceptsOnlyFilesSignedByItsKey() {
        val host = process(signed)
        assertEquals("SIGNATURE_INVALID", host.apply(TestPatches.patch(10))["error"])
        assertEquals("SIGNATURE_INVALID", host.apply(TestPatches.patch(10, TestPatches.keyPair()))["error"])
        assertTrue(host.apply(TestPatches.patch(10, signer)).ok())
        assertNotNull(process(signed).boots(signed))
    }

    @Test fun anUnsignedHostAlsoAcceptsASignedFile() {
        assertTrue(process().apply(TestPatches.patch(10, signer)).ok())
    }

    @Test fun anotherHostsFileIsRejected() {
        val file = TestPatches.file(TestPatches.archive(10), 10, fingerprint = "cd".repeat(32))
        assertEquals("SIGNATURE_INVALID", process().apply(file)["error"])
    }

    @Test fun theActivePatchAgainChangesNothing() {
        val host = process()
        assertTrue(host.apply(TestPatches.patch(10)).ok())
        assertTrue(host.apply(TestPatches.patch(10)).ok())
        assertEquals("10", host.currentVersion())
    }

    @Test fun anOlderOrEqualSequenceIsRejected() {
        val host = process()
        assertTrue(host.apply(TestPatches.patch(10)).ok())
        assertEquals("INVALID_ARGS", host.apply(TestPatches.patch(9))["error"])
        // Same sequence, other content.
        assertEquals("INVALID_ARGS", host.apply(TestPatches.file(TestPatches.archive(11), 10))["error"])
        assertEquals("10", host.currentVersion())
    }

    @Test fun aWithdrawalDropsThePatchAndRaisesTheFloor() {
        val host = process()
        assertTrue(host.apply(TestPatches.patch(10)).ok())
        val result = host.apply(TestPatches.withdrawal(20))
        assertTrue(result.toString(), result.ok())
        assertEquals("withdraw", result["action"])
        assertNull(host.currentVersion())
        assertEquals(20L, host.target()["acceptedSeq"])
        assertNull(process().boots())
        assertEquals("INVALID_ARGS", host.apply(TestPatches.patch(15))["error"])
        assertEquals("INVALID_ARGS", host.apply(TestPatches.withdrawal(20))["error"])
        assertTrue(host.apply(TestPatches.patch(21)).ok())
    }

    @Test fun aSignedHostNeedsASignedWithdrawal() {
        val host = process(signed)
        assertTrue(host.apply(TestPatches.patch(10, signer)).ok())
        assertEquals("SIGNATURE_INVALID", host.apply(TestPatches.withdrawal(20))["error"])
        assertEquals("10", host.currentVersion())
        assertTrue(host.apply(TestPatches.withdrawal(20, signer)).ok())
        assertNull(host.currentVersion())
    }

    @Test fun aLocalRollbackKeepsTheFloorAndBlacklistsNothing() {
        val host = process()
        assertTrue(host.apply(TestPatches.patch(10)).ok())
        host.rollback()
        assertNull(host.currentVersion())
        assertTrue(host.blacklist().isEmpty())
        assertEquals("INVALID_ARGS", host.apply(TestPatches.patch(10))["error"])
        assertTrue(host.apply(TestPatches.patch(11)).ok())
    }

    @Test fun aPatchThatFailedItsBootIsBlacklisted() {
        assertTrue(process().apply(TestPatches.patch(10)).ok())
        val boot = process()
        val token = boot.boots()!!["attempt"] as String
        assertTrue(boot.markBooting(token))
        boot.error(token, "boom", quarantine = true)
        assertNull(process().boots())
        assertEquals(1, boot.blacklist().size)
        assertEquals("BLACKLISTED", process().apply(TestPatches.patch(10))["error"])
    }

    @Test fun aWithdrawalInvalidatesAnOfferThatHasNotStarted() {
        assertTrue(process().apply(TestPatches.patch(10)).ok())
        val boot = process()
        val token = boot.boots()!!["attempt"] as String
        boot.apply(TestPatches.withdrawal(20))
        assertFalse(boot.markBooting(token))
    }

    @Test fun inspectingAHeaderTellsWhetherTheFileIsNew() {
        val host = process()
        val header = TestPatches.patch(10).copyOf(PatchEnvelope.HEADER)
        assertEquals(mapOf("fresh" to true, "action" to "publish", "seq" to 10L, "reason" to null), host.inspect(header))
        assertTrue(host.apply(TestPatches.patch(10)).ok())
        val old = host.inspect(header)
        assertEquals(false, old["fresh"])
        assertNotNull(old["reason"])
        assertEquals("withdraw", host.inspect(TestPatches.withdrawal(11))["action"])
        assertEquals(true, host.inspect(TestPatches.withdrawal(11))["fresh"])
        val other = TestPatches.file(ByteArray(0), 30, fingerprint = "cd".repeat(32))
        assertEquals(false, host.inspect(other)["fresh"])
        assertEquals(false, host.inspect(ByteArray(10))["fresh"])
    }

    @Test fun theTargetNamesTheHostAndWhetherItIsSigned() {
        assertEquals(false, process().target()["signed"])
        assertEquals(true, process(signed).target()["signed"])
        assertEquals(0L, process().target()["acceptedSeq"])
        assertEquals(unsigned.scope, process().target()["scope"])
    }

    @Test fun theBootstrapMustNameTheHostsKey() {
        assertTrue(process().apply(TestPatches.patch(10)).ok())
        val other = Base64.getEncoder().encodeToString(ByteArray(32))
        val error = runCatching { process().bootPayload(TestPatches.FP, other) }.exceptionOrNull()
        assertTrue(error is IllegalArgumentException)
        assertNotNull(process().bootPayload(TestPatches.FP, "-"))
    }

    @Test fun signedManifestStateLeftBy10IsRemoved() {
        val legacy = File(context.noBackupFilesDir, "flutter_patcher_auth/${TestPatches.FP}").apply { mkdirs() }
        File(legacy, "state.json").writeText("{}")
        process()
        assertFalse(File(context.noBackupFilesDir, "flutter_patcher_auth").exists())
    }

    @Test fun aFileIsReadFromItsPathAndLeftThere() {
        val file = File(context.cacheDir, "patch.fptc").apply { writeBytes(TestPatches.patch(10)) }
        assertTrue(process().applyFile(file.path, noProgress).ok())
        assertTrue(file.exists())
    }
}
