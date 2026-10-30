package com.flutter_patcher.flutter_patcher

import android.content.Context
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import java.io.File
import io.flutter.plugin.common.StandardMessageCodec
import org.json.JSONArray
import org.json.JSONObject
import org.mockito.Mockito

class PatchManagerTest {
    @Test
    fun isZipPayloadDetectsZipMagic() {
        val zip = File.createTempFile("flutter_patcher", ".zip")
        val so = File.createTempFile("flutter_patcher", ".so")
        try {
            zip.writeBytes(byteArrayOf(0x50, 0x4b, 0x03, 0x04, 0x00))
            so.writeBytes(byteArrayOf(0x7f, 0x45, 0x4c, 0x46))

            assertTrue(PatchManager.isZipPayload(zip))
            assertFalse(PatchManager.isZipPayload(so))
        } finally {
            zip.delete()
            so.delete()
        }
    }

    @Test
    fun isDartOnlyAssetsTreatsMissingOrEmptyFilesAsDartOnly() {
        // null block → Dart-only patch.zip (pack omits the assets key entirely)
        assertTrue(PatchManager.isDartOnlyAssets(null))
        // present but no files key
        assertTrue(PatchManager.isDartOnlyAssets(JSONObject()))
        // present with empty files array
        assertTrue(
            PatchManager.isDartOnlyAssets(
                JSONObject().put("files", JSONArray())
            )
        )
        // present with at least one overlay file → real asset patch
        assertFalse(
            PatchManager.isDartOnlyAssets(
                JSONObject().put(
                    "files",
                    JSONArray().put(JSONObject().put("path", "hero.png"))
                )
            )
        )
    }

    @Test
    fun selectPackageAbiUsesDevicePriorityOrder() {
        val lib = org.json.JSONObject()
            .put("armeabi-v7a", org.json.JSONObject().put("path", "lib/armeabi-v7a/libapp.so"))
            .put("arm64-v8a", org.json.JSONObject().put("path", "lib/arm64-v8a/libapp.so"))

        assertEquals(
            "arm64-v8a",
            PatchManager.selectPackageAbi(lib, arrayOf("arm64-v8a", "armeabi-v7a"))
        )
        assertNull(PatchManager.selectPackageAbi(lib, arrayOf("x86_64")))
    }

    @Test
    fun codecBufferToByteArrayRewindsEncodedManifest() {
        val manifest = linkedMapOf(
            "assets/patch_demo.png" to listOf(mapOf("asset" to "assets/patch_demo.png"))
        )
        val encoded = StandardMessageCodec.INSTANCE.encodeMessage(manifest)!!
        val bytes = codecBufferToByteArray(encoded)

        assertTrue(bytes.isNotEmpty())
        assertEquals(
            manifest,
            StandardMessageCodec.INSTANCE.decodeMessage(java.nio.ByteBuffer.wrap(bytes))
        )
    }

    @Test
    fun isSafeZipPathRejectsTraversal() {
        assertTrue(PatchManager.isSafeZipPath("assets/images/hero.png"))
        assertFalse(PatchManager.isSafeZipPath("../hero.png"))
        assertFalse(PatchManager.isSafeZipPath("assets/../hero.png"))
        assertFalse(PatchManager.isSafeZipPath("/assets/hero.png"))
    }

    @Test
    fun recoverInterruptedInstallRestoresPreviousArtifacts() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val patchDir = File(root, PatcherConfig.PATCH_DIR).apply { mkdirs() }

            File(patchDir, "installing").writeText("installing")
            File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").writeText("old-so")
            File(patchDir, "${PatcherConfig.META_FILENAME}.previous").writeText("old-meta")
            File(patchDir, "flutter_assets.previous").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("old-assets")
            }
            File(patchDir, PatcherConfig.PATCH_FILENAME).writeText("new-so")
            File(patchDir, PatcherConfig.META_FILENAME).writeText("new-meta")
            File(patchDir, "flutter_assets").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("new-assets")
            }
            File(patchDir, "${PatcherConfig.PATCH_FILENAME}.pending").writeText("pending-so")

            invokePrivate(manager, "recoverInterruptedInstall")

            assertEquals("old-so", File(patchDir, PatcherConfig.PATCH_FILENAME).readText())
            assertEquals("old-meta", File(patchDir, PatcherConfig.META_FILENAME).readText())
            assertEquals(
                "old-assets",
                File(patchDir, "flutter_assets/AssetManifest.bin").readText()
            )
            assertFalse(File(patchDir, "installing").exists())
            assertFalse(File(patchDir, "${PatcherConfig.PATCH_FILENAME}.pending").exists())
            assertFalse(File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun recoverInterruptedInstallWithPartialPreviousKeepsUnbackedCurrentMeta() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val patchDir = File(root, PatcherConfig.PATCH_DIR).apply { mkdirs() }

            File(patchDir, "installing").writeText("installing")
            File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").writeText("old-so")
            File(patchDir, PatcherConfig.META_FILENAME).writeText("old-meta")

            invokePrivate(manager, "recoverInterruptedInstall")

            assertEquals("old-so", File(patchDir, PatcherConfig.PATCH_FILENAME).readText())
            assertEquals("old-meta", File(patchDir, PatcherConfig.META_FILENAME).readText())
            assertFalse(File(patchDir, "installing").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rollbackPreparedCommitRestoresPreviousPatchWhenNewPatchWasPromoted() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val patchDir = File(root, PatcherConfig.PATCH_DIR).apply { mkdirs() }

            File(patchDir, PatcherConfig.PATCH_FILENAME).writeText("new-so")
            File(patchDir, PatcherConfig.META_FILENAME).writeText("new-meta")
            File(patchDir, "flutter_assets").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("new-assets")
            }
            File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").writeText("old-so")
            File(patchDir, "${PatcherConfig.META_FILENAME}.previous").writeText("old-meta")
            File(patchDir, "flutter_assets.previous").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("old-assets")
            }

            invokePrivate(
                manager,
                "rollbackPreparedCommit",
                true,
                true,
                true,
                false,
                true,
                true,
                true,
                false,
            )

            assertEquals("old-so", File(patchDir, PatcherConfig.PATCH_FILENAME).readText())
            assertEquals("old-meta", File(patchDir, PatcherConfig.META_FILENAME).readText())
            assertEquals(
                "old-assets",
                File(patchDir, "flutter_assets/AssetManifest.bin").readText()
            )
            assertFalse(File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").exists())
            assertFalse(File(patchDir, "flutter_assets.previous").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun installPackagePatchReturnsAssetPackageInvalidForMalformedZip() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val malformed = File(root, "patch.zip")
            malformed.writeBytes(byteArrayOf(0x50, 0x4b, 0x03, 0x04, 0x00))

            val result = invokePrivate(
                manager,
                "installPackagePatch",
                malformed,
                "1.0.0-h1",
                "0123456789abcdef0123456789abcdef",
                100L,
                "candidate",
            ) as ApplyResult

            assertFalse(result.ok)
            assertEquals(ApplyErrorCode.ASSET_PACKAGE_INVALID, result.errorCode)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun finalizePatchCodeOnlySuccessRemovesOldAssetsOnlyAfterCommit() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val patchDir = File(root, PatcherConfig.PATCH_DIR).apply { mkdirs() }
            File(patchDir, PatcherConfig.PATCH_FILENAME).writeText("old-so")
            File(patchDir, PatcherConfig.META_FILENAME).writeText(
                JSONObject().put("version", "old").toString()
            )
            File(patchDir, "flutter_assets").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("old-assets")
            }
            File(patchDir, "flutter_assets.apk").writeText("old-asset-archive")

            val newSo = File(root, "new.so").apply { writeText("new-so") }
            val newMeta = JSONObject()
                .put("version", "new")
                .put("effectiveMd5", "0123456789abcdef0123456789abcdef")

            val result = invokePrivate(manager, "finalizePatch", newSo, null, null, newMeta)

            assertNull(result)
            assertEquals("new-so", File(patchDir, PatcherConfig.PATCH_FILENAME).readText())
            assertEquals("new", JSONObject(File(patchDir, PatcherConfig.META_FILENAME).readText())
                .getString("version"))
            assertFalse(File(patchDir, "flutter_assets").exists())
            assertFalse(File(patchDir, "flutter_assets.apk").exists())
            assertFalse(File(patchDir, "installing").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    private fun mockContext(filesDir: File): Context {
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        return context
    }

    private fun tempDir(): File =
        File(System.getProperty("java.io.tmpdir"), "flutter_patcher_test_${System.nanoTime()}")
            .apply { mkdirs() }

    private fun invokePrivate(target: Any, name: String, vararg args: Any?): Any? {
        val method = target.javaClass.declaredMethods.first {
            it.name == name && it.parameterTypes.size == args.size
        }
        method.isAccessible = true
        return method.invoke(target, *args)
    }
}
