package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipFile

/**
 * 补丁应用过程的阶段 / 进度回调。
 *
 * - `phase`：见 [Phase]
 * - `received` / `total`：仅 `phase=downloading` 时有意义；`total=-1` 表示
 *   服务端未返回 Content-Length
 */
internal typealias ProgressCallback = (phase: String, received: Long, total: Long) -> Unit

internal object Phase {
    const val DOWNLOADING = "downloading"
    const val VERIFYING = "verifying"
    const val BSDIFF_MERGING = "bsdiff_merging"
    const val FINALIZING = "finalizing"
}

/**
 * 补丁生命周期管理：下载、验签、（可选）bsdiff 合成、落盘、回滚、查询路径。
 *
 * 所有外部输入（URL、md5、signature、版本号、mode、targetMd5）都从入参读取，
 * 不依赖任何硬编码配置。
 *
 * [progress] 可选，用于把各阶段 / 下载进度同步到 UI（由 Plugin 经 EventChannel
 * 送到 Dart 侧）。
 */
internal class PatchManager(
    private val context: Context,
    private val progress: ProgressCallback? = null
) {

    companion object {
        private const val TAG = "FlutterPatcher/Mgr"

        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val READ_TIMEOUT_MS = 30_000
        private const val MAX_RETRIES = 3

        private const val MODE_FULL = "full"
        private const val MODE_BSDIFF = "bsdiff"

        /** 下载进度节流，避免频繁跨线程发事件淹没 UI。 */
        private const val PROGRESS_EMIT_INTERVAL_MS = 200L
    }

    private val patchDir = File(context.filesDir, PatcherConfig.PATCH_DIR)
    private val patchFile = File(patchDir, PatcherConfig.PATCH_FILENAME)
    private val metaFile = File(patchDir, PatcherConfig.META_FILENAME)

    // ==================== 启动路径 ====================

    fun getValidPatchPath(): String? {
        if (!patchFile.exists() || !metaFile.exists()) return null

        val meta = readMeta() ?: return null

        // versionCode 兼容性校验：宿主 APK 升级 / 安装时包名冲突场景下，旧补丁
        // 与当前 Flutter engine & Dart kernel 可能不兼容，直接丢弃避免启动崩溃。
        // 没有字段的旧 meta（-1 sentinel）同样视为不可信，安全丢弃。
        val patchVc = meta.optLong(
            PatcherConfig.META_KEY_TARGET_VERSION_CODE,
            PatcherConfig.INVALID_VERSION_CODE
        )
        val currentVc = PatcherConfig.currentVersionCode(context)
        if (patchVc == PatcherConfig.INVALID_VERSION_CODE ||
            currentVc == PatcherConfig.INVALID_VERSION_CODE ||
            patchVc != currentVc
        ) {
            Log.w(TAG, "versionCode mismatch: patch=$patchVc current=$currentVc, drop patch")
            deletePatch()
            return null
        }

        // 落盘时已把「合成后」的 md5 写入 meta.effectiveMd5
        val expectedMd5 = meta.optString("effectiveMd5", "")
        val signature = meta.optString("signature", "")
        val publicKey = PatcherConfig.publicKey(context)
        val strictSignature = PatcherConfig.strictSignature(context)

        if (expectedMd5.isEmpty()) {
            Log.e(TAG, "meta.effectiveMd5 missing, drop patch")
            deletePatch()
            return null
        }
        if (!SignatureVerifier.verify(patchFile, expectedMd5, signature, publicKey, strictSignature)) {
            Log.e(TAG, "verify failed, drop patch")
            deletePatch()
            return null
        }
        if (!patchFile.canRead()) patchFile.setReadable(true, false)
        return patchFile.absolutePath
    }

    fun currentVersion(): String = readMeta()?.optString("version", "") ?: ""

    // ==================== 安装 ====================

    fun applyPatch(info: Map<String, Any?>): ApplyResult {
        val version = (info["version"] as? String).orEmpty()
        val url = (info["patchUrl"] as? String).orEmpty()
        val md5 = (info["md5"] as? String).orEmpty()
        val signature = (info["signature"] as? String).orEmpty()
        val mode = ((info["mode"] as? String) ?: MODE_FULL).lowercase()
        val targetMd5 = (info["targetMd5"] as? String).orEmpty()

        if (version.isEmpty() || url.isEmpty() || md5.isEmpty()) {
            Log.w(TAG, "applyPatch: missing version/url/md5")
            return ApplyResult.failure(
                ApplyErrorCode.INVALID_ARGS,
                "missing version/url/md5"
            )
        }
        if (mode == MODE_BSDIFF && targetMd5.isEmpty()) {
            Log.w(TAG, "bsdiff mode requires targetMd5")
            return ApplyResult.failure(
                ApplyErrorCode.INVALID_ARGS,
                "bsdiff mode requires targetMd5"
            )
        }
        if (mode == MODE_BSDIFF && !BsDiffBridge.isAvailable()) {
            Log.w(TAG, "bsdiff module not built, rejecting diff patch (see README)")
            return ApplyResult.failure(
                ApplyErrorCode.BSDIFF_DISABLED,
                "bsdiff native module not built; integrate upstream sources per README"
            )
        }
        if (version == currentVersion()) {
            Log.d(TAG, "patch $version already installed")
            return ApplyResult.SUCCESS
        }

        patchDir.mkdirs()
        val downloaded = File(patchDir, "temp_download.bin")
        var lastNetworkError: String? = null

        for (attempt in 1..MAX_RETRIES) {
            try {
                progress?.invoke(Phase.DOWNLOADING, 0L, -1L)
                downloadTo(url, downloaded) { received, total ->
                    progress?.invoke(Phase.DOWNLOADING, received, total)
                }
                Log.d(TAG, "download ok: ${downloaded.length()} bytes (attempt=$attempt)")

                // Step 1: MD5（区分于签名错误，给出独立错误码）
                progress?.invoke(Phase.VERIFYING, 0L, 0L)
                val actualMd5 = SignatureVerifier.md5(downloaded)
                if (!actualMd5.equals(md5, ignoreCase = true)) {
                    Log.e(TAG, "md5 mismatch: expected=$md5 actual=$actualMd5")
                    downloaded.delete()
                    return ApplyResult.failure(
                        ApplyErrorCode.MD5_MISMATCH,
                        "expected=$md5 actual=$actualMd5"
                    )
                }

                // Step 2: signature
                val publicKey = PatcherConfig.publicKey(context)
                val strictSignature = PatcherConfig.strictSignature(context)
                if (!SignatureVerifier.verifySignatureOnly(
                        actualMd5.lowercase(), signature, publicKey, strictSignature
                    )
                ) {
                    Log.e(TAG, "signature verify failed")
                    downloaded.delete()
                    return ApplyResult.failure(
                        ApplyErrorCode.SIGNATURE_INVALID,
                        "ed25519 signature verify failed"
                    )
                }

                val finalSo: File
                val effectiveMd5: String

                if (mode == MODE_BSDIFF) {
                    progress?.invoke(Phase.BSDIFF_MERGING, 0L, 0L)
                    val baseSo = extractBaseLibappSo() ?: run {
                        Log.e(TAG, "cannot extract base libapp.so from APK")
                        downloaded.delete()
                        return ApplyResult.failure(
                            ApplyErrorCode.IO_ERROR,
                            "cannot extract base libapp.so from APK"
                        )
                    }
                    val merged = File(patchDir, "temp_merged.so")
                    val rc = BsDiffBridge.applyPatch(
                        oldPath = baseSo.absolutePath,
                        newPath = merged.absolutePath,
                        patchPath = downloaded.absolutePath
                    )
                    baseSo.delete()
                    downloaded.delete()

                    if (rc != BsDiffBridge.OK) {
                        Log.e(TAG, "bsdiff apply failed rc=$rc")
                        merged.delete()
                        return ApplyResult.failure(
                            ApplyErrorCode.BSDIFF_APPLY_FAILED,
                            "native bsdiff rc=$rc"
                        )
                    }
                    val mergedMd5 = SignatureVerifier.md5(merged)
                    if (!mergedMd5.equals(targetMd5, ignoreCase = true)) {
                        Log.e(TAG, "merged md5 mismatch: expected=$targetMd5 actual=$mergedMd5")
                        merged.delete()
                        return ApplyResult.failure(
                            ApplyErrorCode.TARGET_MD5_MISMATCH,
                            "expected=$targetMd5 actual=$mergedMd5"
                        )
                    }
                    finalSo = merged
                    effectiveMd5 = mergedMd5
                } else {
                    finalSo = downloaded
                    effectiveMd5 = md5
                }

                progress?.invoke(Phase.FINALIZING, 0L, 0L)
                if (!finalSo.renameTo(patchFile)) {
                    Log.e(TAG, "rename failed")
                    finalSo.delete()
                    return ApplyResult.failure(
                        ApplyErrorCode.IO_ERROR,
                        "rename to ${patchFile.absolutePath} failed"
                    )
                }

                // targetVersionCode：优先取服务端下发；否则以当下宿主 APK 的
                // versionCode 兜底写入。启动时会强校验此字段 == 当前 APK versionCode。
                val serverTargetVc = (info["targetVersionCode"] as? Number)?.toLong()
                val targetVersionCode = serverTargetVc ?: PatcherConfig.currentVersionCode(context)

                val meta = JSONObject().apply {
                    put("version", version)
                    put("mode", mode)
                    put("downloadMd5", md5)
                    put("effectiveMd5", effectiveMd5)
                    put("signature", signature)
                    put(PatcherConfig.META_KEY_TARGET_VERSION_CODE, targetVersionCode)
                    put("installed_at", System.currentTimeMillis())
                }
                metaFile.writeText(meta.toString())

                CrashGuard(context).reset()

                Log.d(TAG, "patch $version ready, takes effect on next cold start")
                return ApplyResult.SUCCESS
            } catch (e: Exception) {
                Log.w(TAG, "attempt=$attempt failed: ${e.message}")
                lastNetworkError = e.message
                downloaded.delete()
                if (attempt < MAX_RETRIES) {
                    val backoff = 2000L * (1L shl (attempt - 1))
                    try {
                        Thread.sleep(backoff)
                    } catch (_: InterruptedException) {
                        return ApplyResult.failure(
                            ApplyErrorCode.NETWORK,
                            "interrupted during backoff"
                        )
                    }
                }
            }
        }
        return ApplyResult.failure(
            ApplyErrorCode.NETWORK,
            "download failed after $MAX_RETRIES attempts: $lastNetworkError"
        )
    }

    // ==================== 回滚 ====================

    fun rollback() {
        deletePatch()
        CrashGuard(context).reset()
        Log.d(TAG, "rolled back to built-in version")
    }

    // ==================== 内部 ====================

    /**
     * GET [url] 流式写入 [dest]，可选 [onBytes] 接收字节级进度。
     *
     * 用 JDK 自带 `HttpURLConnection`（Android minSdk 24+ 保证可用），避免与
     * 宿主工程引入的 okhttp 版本冲突。不做跨协议（HTTP<->HTTPS）重定向：
     * 生产环境下补丁 URL 建议直接给 HTTPS。
     */
    private fun downloadTo(
        url: String,
        dest: File,
        onBytes: ((received: Long, total: Long) -> Unit)? = null
    ) {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = CONNECT_TIMEOUT_MS
            conn.readTimeout = READ_TIMEOUT_MS
            conn.requestMethod = "GET"
            // 同协议重定向默认打开；跨协议重定向 JDK 不自动处理，通常也不需要
            val code = conn.responseCode
            if (code !in 200..299) throw RuntimeException("HTTP $code")

            val total = conn.contentLengthLong   // -1 表示服务端未发 Content-Length
            var received = 0L
            var lastEmit = 0L

            conn.inputStream.use { input ->
                dest.outputStream().use { output ->
                    val buf = ByteArray(8192)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        output.write(buf, 0, n)
                        received += n
                        if (onBytes != null) {
                            val now = SystemClock.uptimeMillis()
                            if (now - lastEmit >= PROGRESS_EMIT_INTERVAL_MS) {
                                onBytes(received, total)
                                lastEmit = now
                            }
                        }
                    }
                    output.fd.sync()
                }
            }
            // 结尾再发一次，保证 UI 能刷到 100%
            onBytes?.invoke(received, total)
        } finally {
            conn.disconnect()
        }
    }

    /**
     * 从当前 APK 里抽出 `lib/<abi>/libapp.so` 到临时文件，供 bsdiff 合成用。
     * ABI 优先 Build.SUPPORTED_ABIS 首位（设备首选）。
     * 调用方负责删除返回的文件。
     */
    private fun extractBaseLibappSo(): File? {
        val apkPath = context.applicationInfo.sourceDir ?: return null
        val abis = Build.SUPPORTED_ABIS ?: arrayOf("arm64-v8a")

        return try {
            ZipFile(apkPath).use { zip ->
                for (abi in abis) {
                    val entry = zip.getEntry("lib/$abi/libapp.so") ?: continue
                    val dest = File(patchDir, "base_libapp_$abi.so")
                    zip.getInputStream(entry).use { input ->
                        dest.outputStream().use { output ->
                            input.copyTo(output, bufferSize = 8192)
                        }
                    }
                    Log.d(TAG, "extracted base libapp.so for $abi (${dest.length()} bytes)")
                    return dest
                }
                Log.e(TAG, "no libapp.so found in APK for abis=${abis.toList()}")
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "extract base libapp.so failed", e)
            null
        }
    }

    private fun deletePatch() {
        if (patchDir.exists()) patchDir.deleteRecursively()
    }

    private fun readMeta(): JSONObject? {
        if (!metaFile.exists()) return null
        return try {
            JSONObject(metaFile.readText())
        } catch (_: Exception) {
            null
        }
    }
}
