package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import org.json.JSONArray

/**
 * 热更新运行时配置读写，统一走 SharedPreferences。
 *
 * 由 Dart 侧在 FlutterPatcher.init() 时下发；信任材料（公钥、应用身份、渠道）
 * 只来自构建时写入 APK 的宿主策略，不经过这里。
 */
internal object PatcherConfig {

    const val PREFS_NAME = "flutter_patcher_prefs"

    // ---- Config keys ----
    private const val KEY_MAX_CRASH = "max_crash_count"
    private const val KEY_LOADER_FIELDS = "loader_field_candidates"
    private const val KEY_LOADER_HEURISTIC = "loader_fallback_heuristic"

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
     * 默认 1：补丁启动失败 1 次即立刻丢弃 + 入黑名单（fail-fast）。
     *
     * 设计依据：补丁加载后崩溃是明确"补丁有问题"信号，不应该再赌一次让用户多崩
     * 一次。需要容忍更多次失败时显式传 `FlutterPatcher.init(maxCrashCount: 2)`。
     */
    const val DEFAULT_MAX_CRASH = 1
    const val DEFAULT_LOADER_HEURISTIC = false

    fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    internal fun encodeLoaderFieldCandidates(fields: List<String>): String {
        val normalized = fields
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
        return JSONArray(normalized).toString()
    }

    internal fun decodeLoaderFieldCandidates(raw: Any?): List<String> {
        return when (raw) {
            is String -> try {
                val arr = JSONArray(raw)
                List(arr.length()) { arr.optString(it) }
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .distinct()
            } catch (_: Exception) {
                emptyList()
            }
            else -> emptyList()
        }
    }

    fun saveConfig(
        context: Context,
        maxCrashCount: Int,
        loaderFieldCandidates: List<String>,
        loaderFallbackHeuristic: Boolean
    ) {
        prefs(context).edit()
            .putInt(KEY_MAX_CRASH, maxCrashCount.coerceAtLeast(1))
            .putString(KEY_LOADER_FIELDS, encodeLoaderFieldCandidates(loaderFieldCandidates))
            .putBoolean(KEY_LOADER_HEURISTIC, loaderFallbackHeuristic)
            .apply()
    }

    fun maxCrashCount(context: Context): Int =
        prefs(context).getInt(KEY_MAX_CRASH, DEFAULT_MAX_CRASH)

    fun loaderFieldCandidates(context: Context): List<String> =
        decodeLoaderFieldCandidates(prefs(context).all[KEY_LOADER_FIELDS])

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
