package com.flutter_patcher.flutter_patcher

import android.util.Log

/**
 * bsdiff 原生模块桥。
 *
 * 只负责「把差分文件合成到新文件」，对 MD5 / 签名 / APK 路径一无所知——那些由
 * [PatchManager] 负责。
 *
 * 若 cpp/third_party/bsdiff + cpp/third_party/bzip2 未放源码（默认情况），
 * libflutter_patcher_bsdiff.so 里 [nativeApplyPatch] 会返回 [ERR_NOT_BUILT]，
 * [isAvailable] 返回 false，Kotlin 侧会拒绝 mode=bsdiff 的补丁。
 */
internal object BsDiffBridge {

    private const val TAG = "FlutterPatcher/Bs"

    /** 与 bsdiff_jni.h 对齐 */
    const val OK = 0
    const val ERR_NOT_BUILT = -1
    const val ERR_IO = -2
    const val ERR_FORMAT = -3
    const val ERR_DECOMPRESS = -4
    const val ERR_OOM = -5

    private val loadError: Throwable?

    init {
        loadError = try {
            System.loadLibrary("flutter_patcher_bsdiff")
            null
        } catch (e: Throwable) {
            Log.w(TAG, "libflutter_patcher_bsdiff.so not loadable: ${e.message}")
            e
        }
    }

    /**
     * 当前是否可用。返回 false 时说明：
     *  - .so 文件缺失（某些 ABI 未编）
     *  - 或 .so 里是 stub（未集成 upstream bsdiff + bzip2 源码）
     */
    fun isAvailable(): Boolean {
        if (loadError != null) return false
        // 试跑一次极小 probe 判断是否 stub
        return try {
            nativeProbe() == 1
        } catch (_: UnsatisfiedLinkError) {
            false
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * 合成：对 [oldPath] 应用 [patchPath]，写到 [newPath]。
     * @return 0 成功；负数见 ERR_*
     */
    fun applyPatch(oldPath: String, newPath: String, patchPath: String): Int {
        if (loadError != null) return ERR_NOT_BUILT
        return try {
            nativeApplyPatch(oldPath, newPath, patchPath)
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "native symbol missing", e)
            ERR_NOT_BUILT
        }
    }

    // JNI
    @JvmStatic
    private external fun nativeApplyPatch(
        oldPath: String,
        newPath: String,
        patchPath: String
    ): Int

    /** 返回 1 表示真实实现；0 表示 stub（用于 [isAvailable] 判断）。*/
    @JvmStatic
    private external fun nativeProbe(): Int
}
