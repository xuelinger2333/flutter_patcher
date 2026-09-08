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
 * 状态机（解耦版）：
 * 1. Application.attachBaseContext → [markBooting] 写 patch_loading=true（commit 同步）+ pid
 * 2. Dart 首帧 → [markBootSuccess] 立即清 patch_loading=false + crash_count=0；
 *    **保留** last_booting_pid 给下次冷启动的 ExitInfo 查询
 * 3. Dart 首帧 + verifyAfter 秒 → 卸载 Dart 错误钩子（仅 Dart 层动作，不触原生）
 *
 * 下次冷启动 [shouldLoadPatch] 综合判定：
 *
 * - **API 30+ 且有 pid 记录**：通过 [ActivityManager.getHistoricalProcessExitReasons]
 *   拿到精确死因。覆盖首帧前后所有崩溃。只有 [ApplicationExitInfo.REASON_CRASH]
 *   / [ApplicationExitInfo.REASON_CRASH_NATIVE] / [ApplicationExitInfo.REASON_ANR]
 *   / [ApplicationExitInfo.REASON_INITIALIZATION_FAILURE] 计入 crash_count；
 *   用户从最近任务划掉、系统 OOM 等不计入。
 * - **API < 30 或 ExitInfo 无记录**：退回到 patch_loading 兜底——
 *   patch_loading=true（首帧前死了）→ 视为崩溃；
 *   patch_loading=false（首帧后死的）→ 不计崩溃。
 *
 * API < 30 因此存在已知盲区：补丁加载首帧后才发生的 native crash / ANR 不会被
 * 检测（Dart 层异常仍由 verifyAfter 窗口内的 Dart 错误钩子捕获）。覆盖率约
 * 5–10% 的存量长尾设备，业务侧若无法接受可显式调高 `maxCrashCount`。
 *
 * 当 crash_count 累计 >= [PatcherConfig.maxCrashCount] 次，自动删除补丁并拒绝加载。
 */
internal class CrashGuard(private val context: Context) {

    companion object {
        private const val TAG = "FlutterPatcher/Guard"
    }

    private val sp = PatcherConfig.prefs(context)

    internal fun previousSessionCrashed(loading: Boolean, pid: Int): Boolean =
        classifyPreviousSession(loading, pid).isCrash

    /**
     * 启动开始时综合判断是否加载补丁。
     *
     * @param onTrip 当熔断器**本次**触发并丢弃补丁时调用，参数为触发时的真实
     *   crash_count（删除前）。供 [BootDiagnosticStore] / [BlacklistStore] 上报使用。
     */
    fun shouldLoadPatch(onTrip: ((crashCount: Int) -> Unit)? = null): Boolean {
        val threshold = PatcherConfig.maxCrashCount(context)
        val patchLoading = sp.getBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
        val lastPid = sp.getInt(PatcherConfig.KEY_LAST_BOOTING_PID, -1)

        val verdict = classifyPreviousSession(patchLoading, lastPid)
        if (verdict.isCrash) {
            val count = recordCrashAndMaybeTrip(verdict.reasonName, onTrip)
            if (count >= threshold) return false
        } else if (patchLoading || lastPid > 0) {
            // 非崩溃但状态未清：清掉以免下次冷启动重复处理同一会话
            sp.edit()
                .putBoolean(PatcherConfig.KEY_PATCH_LOADING, false)
                .remove(PatcherConfig.KEY_LAST_BOOTING_PID)
                .commit()
            Log.i(TAG, "previous session ended without crash (${verdict.reasonName})")
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

    /**
     * Dart 首帧渲染完成：补丁可信，立即清 patch_loading + crash_count。
     *
     * 注意：故意 **不清** [PatcherConfig.KEY_LAST_BOOTING_PID]。下次冷启动
     * [shouldLoadPatch] 仍可用这个 pid 查 [ApplicationExitInfo]，从而捕捉首帧
     * 后才发生的 native crash / ANR —— 那一刻 patch_loading 已清，不能再作为
     * 崩溃信号。pid 在 [shouldLoadPatch] 处理完一次会话后清除。
     */
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
            .remove(PatcherConfig.KEY_LAST_BOOTING_PID)
            .apply()
    }

    /**
     * 综合 [patchLoading] 与 [lastPid] 判定上次会话是否崩溃。
     *
     * - API 30+ 且有 pid 记录 → 优先用 [ApplicationExitInfo] 精确分类。覆盖首帧
     *   前后所有崩溃；用户主动关闭 / 系统 OOM 等不计崩溃。
     * - API < 30 或 ExitInfo 拿不到记录 → 退回到 [patchLoading] 兜底信号。
     *   patchLoading=true（首帧前死了）→ 崩溃；patchLoading=false（首帧后死的，
     *   或本就没启动过）→ 非崩溃。
     */
    private fun classifyPreviousSession(patchLoading: Boolean, lastPid: Int): ExitVerdict {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && lastPid > 0) {
            val record = queryExitInfo(lastPid)
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
            // ExitInfo 队列已被新进程挤出（罕见）：退回到 patchLoading 兜底
        }

        return if (patchLoading) {
            ExitVerdict(true, "NO_FIRST_FRAME")
        } else {
            ExitVerdict(false, "NO_RECORD")
        }
    }

    private fun queryExitInfo(pid: Int): ApplicationExitInfo? {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        return try {
            am?.getHistoricalProcessExitReasons(context.packageName, pid, 1)?.firstOrNull()
        } catch (e: Throwable) {
            Log.w(TAG, "getHistoricalProcessExitReasons failed", e)
            null
        }
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
