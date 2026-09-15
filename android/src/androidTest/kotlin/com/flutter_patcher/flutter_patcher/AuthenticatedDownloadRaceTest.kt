package com.flutter_patcher.flutter_patcher

import android.content.ContextWrapper
import android.content.pm.ApplicationInfo
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLStreamHandler
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Run this class in its own instrumentation process. Only its HTTPS transport is
 * controlled; authorization, lock boundaries, FPTC checks and storage are real. */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 33)
class AuthenticatedDownloadRaceTest {
    private class Transfer(val bytes: ByteArray, val expectedReaders: Int = 1) {
        val entered = CountDownLatch(expectedReaders)
        val release = CountDownLatch(1)
        fun awaitReaders() = assertTrue("Download did not reach the read boundary", entered.await(10, TimeUnit.SECONDS))
    }

    @Test fun withdrawalsSupersessionRetriesAndRevocationDuringDownload() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val fixture = JSONObject(instrumentation.context.assets.open("auth-races.json").bufferedReader().use { it.readText() })
        val base = instrumentation.targetContext
        val root = File(base.cacheDir, "auth-races-${UUID.randomUUID()}").also { check(it.mkdirs()) }
        val apk = File(root, "host.zip")
        ZipOutputStream(apk.outputStream()).use {
            it.putNextEntry(ZipEntry(HostTrustConfig.ASSET))
            it.write(fixture.getJSONObject("policy").toString().toByteArray())
            it.closeEntry()
        }
        val context = object : ContextWrapper(base) {
            override fun getApplicationInfo() = ApplicationInfo(base.applicationInfo).also { it.sourceDir = apk.path }
            override fun getFilesDir() = File(root, "files").also { it.mkdirs() }
            override fun getNoBackupFilesDir() = File(root, "no-backup").also { it.mkdirs() }
            override fun getSharedPreferences(name: String, mode: Int) = base.getSharedPreferences(root.name + name, mode)
        }
        val transfers = ConcurrentHashMap<String, Transfer>()
        URL.setURLStreamHandlerFactory { protocol ->
            if (protocol != "https") null else object : URLStreamHandler() {
                override fun openConnection(url: URL): HttpURLConnection {
                    require(url.host == "race.test")
                    val transfer = transfers.getValue(url.path)
                    return object : HttpURLConnection(url) {
                        override fun connect() {}
                        override fun disconnect() {}
                        override fun usingProxy() = false
                        override fun getResponseCode() = 200
                        override fun getContentLengthLong() = transfer.bytes.size.toLong()
                        override fun getInputStream(): ByteArrayInputStream {
                            transfer.entered.countDown()
                            check(transfer.release.await(15, TimeUnit.SECONDS)) { "Test read barrier timed out" }
                            return ByteArrayInputStream(transfer.bytes)
                        }
                    }
                }
            }
        }
        val executor = Executors.newFixedThreadPool(3)
        val manager = BytecodePatchManager(context)
        manager.bootPayload(fixture.getString("fingerprint"), fixture.getString("public"))
        fun transfer(seq: Int, readers: Int = 1) = Transfer(Base64.getDecoder().decode(fixture.getString("bytes$seq")), readers)
            .also { transfers["/$seq"] = it }
        fun apply(seq: Int) = executor.submit<Boolean> {
            try { manager.applyManifest(fixture.getString("publish$seq")) { _, _, _ -> }["ok"] == true }
            catch (_: Exception) { false }
        }
        try {
            val first = transfer(7)
            val stale = apply(7)
            first.awaitReaders()
            val withdrawal = executor.submit<Boolean> {
                manager.applyManifest(fixture.getString("withdraw")) { _, _, _ -> }["ok"] == true
            }
            assertTrue("Withdrawal blocked behind download", withdrawal.get(5, TimeUnit.SECONDS))
            first.release.countDown()
            assertFalse("Withdrawn download committed", stale.get(5, TimeUnit.SECONDS))
            assertNull(manager.currentVersion())

            val retry = transfer(8, 2)
            val retryA = apply(8)
            val retryB = apply(8)
            retry.awaitReaders()
            retry.release.countDown()
            assertTrue(retryA.get(5, TimeUnit.SECONDS))
            assertTrue(retryB.get(5, TimeUnit.SECONDS))
            assertEquals("8", manager.currentVersion())

            val slow = transfer(9)
            val older = apply(9)
            slow.awaitReaders()
            transfer(10).release.countDown()
            assertTrue("New download blocked behind old download", apply(10).get(5, TimeUnit.SECONDS))
            slow.release.countDown()
            assertFalse("Old download replaced newer candidate", older.get(5, TimeUnit.SECONDS))
            assertEquals("10", manager.currentVersion())

            val revoked = transfer(11)
            val pending = apply(11)
            revoked.awaitReaders()
            executor.submit { manager.updateTrust(fixture.getString("revoke")) }.get(5, TimeUnit.SECONDS)
            revoked.release.countDown()
            assertFalse("Revoked publisher committed in-flight bytes", pending.get(5, TimeUnit.SECONDS))
            assertNull("Revoked installed candidate survived", manager.currentVersion())
        } finally {
            transfers.values.forEach { it.release.countDown() }
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }
}
