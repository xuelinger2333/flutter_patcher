package com.flutter_patcher.flutter_patcher

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Process
import android.util.Log
import java.io.File

/**
 * 熔断器：防止补丁导致启动崩溃时无限重启。
 *
 * 状态机：
 * 1. Application.attachBaseContext → [markBooting] 写 patch_loading=true（commit 同步）+ pid
 * 2. Dart 首帧 → [markBootSuccess] 写 patch_loading=false + crash_count=0
 *
 * 下次冷启动若发现 patch_loading=true，按 Android 版本走两套策略：
 *
 * - **API 30+**：通过 [ActivityManager.getHistoricalProcessExitReasons] 拿到精确死因。
 *   只有 [ApplicationExitInfo.REASON_CRASH] / [ApplicationExitInfo.REASON_CRASH_NATIVE]
 *   / [ApplicationExitInfo.REASON_ANR] / [ApplicationExitInfo.REASON_INITIALIZATION_FAILURE]
 *   计入 crash_count；用户从最近任务划掉、系统 OOM 等不计入。
 * - **API < 30**：朴素策略——`patch_loading=true` 即视为崩溃。没有 ApplicationExitInfo，
 *   不再做时间窗启发式（fail-fast，理由：长尾设备上 5–10% 的不准确不值得引入复杂度）。
 *   业务侧若想宽容点，可显式 `FlutterPatcher.init(maxCrashCount: 2)`。
 *
 * 当 crash_count 累计 >= [PatcherConfig.maxCrashCount] 次，自动删除补丁并拒绝加载。
 */
internal class CrashGuard(private val context: Context) {

    companion object {
        private const val TAG = "FlutterPatcher/Guard"
    }

    private val sp = PatcherConfig.prefs(context)

    /**
     * 启动开始时综合判断是否加载补丁。
     *
     * @param onTrip 当熔断器**本次**触发并丢弃补丁时调用，参数为触发时的真实
     *   crash_count（删除前）。供 [BootDiagnosticStore] / [BlacklistStore] 上报使用。
     */
    fun shouldLoadPatch(onTrip: ((crashCount: Int) -> Unit)? = null): Boolean {
        val threshold = PatcherConfig.maxCrashCount(context)

        if (sp.getBoolean(PatcherConfig.KEY_PATCH_LOADING, false)) {
            val verdict = classifyPreviousExit()
            if (verdict.isCrash) {
                val count = recordCrashAndMaybeTrip(verdict.reasonName, onTrip)
                if (count >= threshold) return false
            } else {
                // 非崩溃退出（API 30+ ExitInfo 判定为用户主动关 / 系统 OOM 等）：清标记，不动 crash_count。
                sp.edit().putBoolean(PatcherConfig.KEY_PATCH_LOADING, false).commit()
                Log.i(TAG, "previous boot ended without crash (${verdict.reasonName}), not counting")
            }
        }

        return sp.getInt(PatcherConfig.KEY_CRASH_COUNT, 0) < threshold
    }

    /**
     * 由 Dart 侧通过 MethodChannel 调用：上报一次"补丁加载阶段 Dart 层未捕获异常"。
     *
     * 这种崩溃不算系统层 [ApplicationExitInfo.REASON_CRASH] —— PlatformDispatcher
     * 把异常吞了，进程没死，下次冷启动 ExitInfo 看到的是 USER_REQUESTED 之类的非
     * 崩溃原因。所以需要 Dart 主动汇报，语义等同于一次真崩溃：crash_count += 1，
     * 达到阈值则熔断 + 删补丁 + 黑名单。
     *
     * @param message 异常字符串（透传给日志 / 诊断展示，不做任何业务逻辑判断）
     * @param onTrip  与 [shouldLoadPatch] 同款：触发熔断时调用，上报黑名单 / 诊断
     */
    fun reportDartBootError(message: String?, onTrip: ((crashCount: Int) -> Unit)? = null) {
        recordCrashAndMaybeTrip(message ?: "no msg", onTrip)
    }

    /**
     * 增计 crash_count、清 patch_loading、必要时触发熔断 + 删补丁。供
     * [shouldLoadPatch] 与 [reportDartBootError] 共用，统一日志格式。
     *
     * @param reason  错误原因（ExitInfo reason name / Dart 异常 toString），仅用于日志
     * @return 累加后的 crash_count（删补丁前的真实值）
     */
    private fun recordCrashAndMaybeTrip(
        reason: String,
        onTrip: ((crashCount: Int) -> Unit)?,
    ): Int {
        val threshold = PatcherConfig.maxCrashCount(context)
        val count = sp.getInt(PatcherConfig.KEY_CRASH_COUNT, 0) + 1
        sp.edit()
            .putInt(PatcherConfig.KEY_CRASH_COUNT, count)
            .putBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
            .commit()
        Log.w(TAG, "patch boot failure recorded ($reason), crash_count=$count")
        if (count >= threshold) {
            Log.w(TAG, "circuit tripped! $count consecutive failures, dropping patch")
            onTrip?.invoke(count)
            deletePatchFiles()
        }
        return count
    }

    /** 在 Application.attachBaseContext 内调用。commit 同步写入，确保进程崩溃前状态已持久化。 */
    fun markBooting() {
        sp.edit()
            .putBoolean(PatcherConfig.KEY_PATCH_LOADING, true)
            .putInt(PatcherConfig.KEY_LAST_BOOTING_PID, Process.myPid())
            .commit()
    }

    /** Dart 首帧渲染完成：真正的「补丁加载成功」。重置计数，清启动元数据。 */
    fun markBootSuccess() {
        sp.edit()
            .putBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
            .putInt(PatcherConfig.KEY_CRASH_COUNT, 0)
            .remove(PatcherConfig.KEY_LAST_BOOTING_PID)
            .commit()
    }

    /** 清零所有熔断状态（配合补丁安装/回滚调用）。 */
    fun reset() {
        sp.edit()
            .putBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
            .putInt(PatcherConfig.KEY_CRASH_COUNT, 0)
            .remove(PatcherConfig.KEY_LAST_BOOTING_PID)
            .apply()
    }

    /**
     * 解析上次「booting」进程的死亡原因。
     *
     * - API 30+ 走 ApplicationExitInfo 精确分类
     * - API < 30 或 ExitInfo 查不到记录 → 朴素策略：直接判定为崩溃
     */
    private fun classifyPreviousExit(): ExitVerdict {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val lastPid = sp.getInt(PatcherConfig.KEY_LAST_BOOTING_PID, -1)
            if (lastPid > 0) {
                val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                val record = try {
                    am?.getHistoricalProcessExitReasons(context.packageName, lastPid, 1)
                        ?.firstOrNull()
                } catch (e: Throwable) {
                    Log.w(TAG, "getHistoricalProcessExitReasons failed", e)
                    null
                }
                if (record != null) {
                    val isCrash = when (record.reason) {
                        ApplicationExitInfo.REASON_CRASH,
                        ApplicationExitInfo.REASON_CRASH_NATIVE,
                        ApplicationExitInfo.REASON_ANR,
                        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> true
                        else -> false
                    }
                    return ExitVerdict(isCrash, reasonNameApi30(record.reason))
                }
            }
        }

        // API < 30 或 ExitInfo 无记录：朴素策略，patch_loading=true 即视为崩溃。
        return ExitVerdict(true, "NO_FIRST_FRAME")
    }

    private fun deletePatchFiles() {
        val dir = File(context.filesDir, PatcherConfig.PATCH_DIR)
        if (dir.exists()) dir.deleteRecursively()
        sp.edit()
            .putInt(PatcherConfig.KEY_CRASH_COUNT, 0)
            .putBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
            .remove(PatcherConfig.KEY_LAST_BOOTING_PID)
            .commit()
    }

    private data class ExitVerdict(val isCrash: Boolean, val reasonName: String)
}

/** 把 [ApplicationExitInfo] reason 整数翻成可读名，仅在 API 30+ 调用。 */
private fun reasonNameApi30(reason: Int): String = when (reason) {
    ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
    ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
    ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
    ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
    ApplicationExitInfo.REASON_CRASH -> "CRASH"
    ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
    ApplicationExitInfo.REASON_ANR -> "ANR"
    ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
    ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
    ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
    ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
    ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
    ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
    ApplicationExitInfo.REASON_OTHER -> "OTHER"
    else -> "REASON_$reason"
}
