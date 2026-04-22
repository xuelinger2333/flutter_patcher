package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Log
import java.io.File

/**
 * 熔断器：防止补丁导致启动崩溃时无限重启。
 *
 * 极简两阶段（用户反馈定稿）：
 * 1. Application.attachBaseContext → [markBooting] 写 patch_loading=true（commit 同步）
 * 2. Dart 首帧 → [markBootSuccess] 写 patch_loading=false + crash_count=0
 *
 * 只要 Dart 首帧没到（不管是原生崩溃、Dart 引擎崩溃、还是 runApp 之后 UI 抛异常），
 * 下次冷启动都会视为一次失败启动：crash_count += 1，当累计 >= [threshold] 次，
 * 自动删除补丁并拒绝加载。默认 threshold=2 —— 「用户不会给你三次机会」。
 */
internal class CrashGuard(private val context: Context) {

    companion object {
        private const val TAG = "FlutterPatcher/Guard"
    }

    private val sp = PatcherConfig.prefs(context)

    /** 启动开始时（Application.attachBaseContext / Dart init）综合判断是否加载补丁。 */
    fun shouldLoadPatch(): Boolean {
        val threshold = PatcherConfig.maxCrashCount(context)

        // 上次被标记为「启动中」但没走到「启动成功」→ 视为崩溃
        if (sp.getBoolean(PatcherConfig.KEY_PATCH_LOADING, false)) {
            val count = sp.getInt(PatcherConfig.KEY_CRASH_COUNT, 0) + 1
            sp.edit()
                .putInt(PatcherConfig.KEY_CRASH_COUNT, count)
                .putBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
                .commit()
            Log.w(TAG, "previous boot crashed, crash_count=$count")

            if (count >= threshold) {
                Log.w(TAG, "circuit tripped! $count consecutive crashes, dropping patch")
                deletePatchFiles()
                return false
            }
        }

        return sp.getInt(PatcherConfig.KEY_CRASH_COUNT, 0) < threshold
    }

    /** 在 Application.attachBaseContext 内（以及 Dart init 最开头）调用。commit 同步写入。 */
    fun markBooting() {
        sp.edit().putBoolean(PatcherConfig.KEY_PATCH_LOADING, true).commit()
    }

    /** Dart 首帧渲染完成：真正的「补丁加载成功」。重置计数。 */
    fun markBootSuccess() {
        sp.edit()
            .putBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
            .putInt(PatcherConfig.KEY_CRASH_COUNT, 0)
            .commit()
    }

    /** 清零所有熔断状态（配合补丁安装/回滚调用）。 */
    fun reset() {
        sp.edit()
            .putBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
            .putInt(PatcherConfig.KEY_CRASH_COUNT, 0)
            .apply()
    }

    private fun deletePatchFiles() {
        val dir = File(context.filesDir, PatcherConfig.PATCH_DIR)
        if (dir.exists()) dir.deleteRecursively()
        sp.edit()
            .putInt(PatcherConfig.KEY_CRASH_COUNT, 0)
            .putBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
            .commit()
    }
}
