package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log

/**
 * 热更新运行时配置读写，统一走 SharedPreferences。
 *
 * 所有键值由 Dart 侧在 FlutterPatcher.init() 时下发，**不在** 库里硬编码任何
 * 业务相关默认值（服务端 URL、公钥、渠道等）。
 */
internal object PatcherConfig {

    const val PREFS_NAME = "flutter_patcher_prefs"

    // ---- Config keys ----
    private const val KEY_PUBLIC_KEY = "public_key_base64"
    private const val KEY_MAX_CRASH = "max_crash_count"
    private const val KEY_STRICT_SIG = "strict_signature"
    private const val KEY_LOADER_FIELDS = "loader_field_candidates"
    private const val KEY_LOADER_HEURISTIC = "loader_fallback_heuristic"

    // ---- Runtime state keys (CrashGuard / PatchManager) ----
    const val KEY_CRASH_COUNT = "crash_count"
    const val KEY_PATCH_LOADING = "patch_loading"

    /** PID written at [com.flutter_patcher.flutter_patcher.CrashGuard.markBooting]; consumed
     *  next cold start to look up `ActivityManager.getHistoricalProcessExitReasons` (API 30+).
     *  Unused on API < 30 — that path uses the naive "patch_loading=true ⇒ crash" rule. */
    const val KEY_LAST_BOOTING_PID = "last_booting_pid"

    // ---- File layout ----
    const val PATCH_DIR = "flutter_patcher"
    const val PATCH_FILENAME = "libapp_patch.so"
    const val META_FILENAME = "patch_meta.json"

    // ---- Meta JSON keys ----
    const val META_KEY_TARGET_VERSION_CODE = "targetVersionCode"

    // ---- Sentinels ----
    const val INVALID_VERSION_CODE = -1L

    // ---- Defaults ----
    /**
     * 默认 1：补丁连续启动失败 1 次即立刻丢弃 + 入黑名单（fail-fast）。
     *
     * 设计依据：补丁加载后崩溃是明确"补丁有问题"信号，不应该再赌一次让用户多崩
     * 一次。0.1 之前默认是 2，行为是"崩 2 次才回滚"，已确认对用户体验更糟。
     * 业务侧若想保留旧行为，显式传 `FlutterPatcher.init(maxCrashCount: 2)`。
     */
    const val DEFAULT_MAX_CRASH = 1
    const val DEFAULT_STRICT_SIG = true
    const val DEFAULT_LOADER_HEURISTIC = false

    fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun saveConfig(
        context: Context,
        publicKeyBase64: String,
        maxCrashCount: Int,
        strictSignature: Boolean,
        loaderFieldCandidates: List<String>,
        loaderFallbackHeuristic: Boolean
    ) {
        prefs(context).edit()
            .putString(KEY_PUBLIC_KEY, publicKeyBase64)
            .putInt(KEY_MAX_CRASH, maxCrashCount.coerceAtLeast(1))
            .putBoolean(KEY_STRICT_SIG, strictSignature)
            .putStringSet(KEY_LOADER_FIELDS, loaderFieldCandidates.toSet())
            .putBoolean(KEY_LOADER_HEURISTIC, loaderFallbackHeuristic)
            .apply()
    }

    fun publicKey(context: Context): String =
        prefs(context).getString(KEY_PUBLIC_KEY, "") ?: ""

    fun maxCrashCount(context: Context): Int =
        prefs(context).getInt(KEY_MAX_CRASH, DEFAULT_MAX_CRASH)

    fun strictSignature(context: Context): Boolean =
        prefs(context).getBoolean(KEY_STRICT_SIG, DEFAULT_STRICT_SIG)

    fun loaderFieldCandidates(context: Context): List<String> =
        prefs(context).getStringSet(KEY_LOADER_FIELDS, null)?.toList() ?: emptyList()

    fun loaderFallbackHeuristic(context: Context): Boolean =
        prefs(context).getBoolean(KEY_LOADER_HEURISTIC, DEFAULT_LOADER_HEURISTIC)

    /**
     * 读取当前宿主 APK 的 versionCode（API 28+ 用 longVersionCode，以下降级）。
     * 查询自身包名不应失败，失败时返回 [INVALID_VERSION_CODE] 作为兜底。
     */
    fun currentVersionCode(context: Context): Long {
        return try {
            val pi = context.packageManager.getPackageInfo(context.packageName, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pi.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                pi.versionCode.toLong()
            }
        } catch (e: PackageManager.NameNotFoundException) {
            Log.e("FlutterPatcher/Config", "own package not found", e)
            INVALID_VERSION_CODE
        }
    }
}
