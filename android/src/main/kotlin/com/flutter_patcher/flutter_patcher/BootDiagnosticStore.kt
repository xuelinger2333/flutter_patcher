package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * 上次冷启动时补丁加载结果的持久化存储。
 *
 * 现状：补丁能否生效取决于 `CrashGuard` / `PatchManager.getValidPatchPath` /
 * `LoaderHook.install` 三处决策，事件只写 logcat。线上业务只能事后通过
 * [PatchManager.currentVersion] 间接推测"补丁是不是又没了"，监控/告警接不上。
 *
 * 本对象在每次冷启动时把"补丁的加载结果 + 上下文"一次性覆写到
 * SharedPreferences，Dart 侧通过 `FlutterPatcher.lastBootDiagnostic` 查询。
 *
 * # 写入时机
 * - [FlutterPatcherApplication.attachPatcher] 三个出口（patched / hookFailed / noPatch / unknown）
 * - [PatchManager.getValidPatchPath] 通过传入的 onDrop 闭包写入（versionCode/md5/sig/meta）
 * - [CrashGuard.shouldLoadPatch] 通过传入的 onDrop 闭包写入（circuit breaker）
 *
 * # 跨边界约定
 * status 用大写 SCREAMING_SNAKE 字符串而非 int，保证 Kotlin / Dart 两侧可读性 +
 * 未来扩展不破坏序列化兼容。Dart 侧用 [PatchBootStatus] 枚举映射。
 */
internal object BootDiagnosticStore {

    private const val TAG = "FlutterPatcher/Diag"

    /** SharedPreferences key（沿用 PatcherConfig.PREFS_NAME 文件，与现有键无冲突）。*/
    private const val KEY_LAST_BOOT_DIAG = "last_boot_diagnostic"

    // ---- status 常量（与 Dart 侧 PatchBootStatus 一一对应）----

    /** 未安装补丁，使用 APK 内置 libapp.so。属于正常状态。*/
    const val NO_PATCH = "NO_PATCH"

    /** 补丁加载成功，本次启动按补丁运行。*/
    const val PATCHED = "PATCHED"

    /** 补丁被丢弃：targetVersionCode 与当前 APK versionCode 不匹配。*/
    const val DROPPED_VERSION_CODE_MISMATCH = "DROPPED_VERSION_CODE_MISMATCH"

    /** 补丁被丢弃：本地 .so 文件 md5 与 meta.effectiveMd5 不一致。*/
    const val DROPPED_MD5_MISMATCH = "DROPPED_MD5_MISMATCH"

    /** 补丁被丢弃：Ed25519 签名校验失败 / 严格模式下 API < 33。*/
    const val DROPPED_SIGNATURE_INVALID = "DROPPED_SIGNATURE_INVALID"

    /** 补丁被丢弃：meta.json 损坏或缺关键字段（effectiveMd5 等）。*/
    const val DROPPED_META_CORRUPTED = "DROPPED_META_CORRUPTED"

    /** 补丁被丢弃：连续启动失败累计 >= maxCrashCount，熔断器触发。*/
    const val DROPPED_CIRCUIT_BREAKER = "DROPPED_CIRCUIT_BREAKER"

    /** 补丁文件保留，但反射替换 FlutterLoader 失败，本次启动用了内置 .so。*/
    const val HOOK_INSTALL_FAILED = "HOOK_INSTALL_FAILED"

    /** attachPatcher 阶段抛出未分类异常。*/
    const val UNKNOWN = "UNKNOWN"

    // ---- 字段 key（写入 / 读取共用）----

    private const val FIELD_STATUS = "status"
    private const val FIELD_PATCH_VERSION = "patchVersion"
    private const val FIELD_PATCH_TARGET_VC = "patchTargetVersionCode"
    private const val FIELD_APP_VC = "appVersionCode"
    private const val FIELD_CRASH_COUNT = "crashCount"
    private const val FIELD_ATTEMPTED_LOADER_FIELDS = "attemptedLoaderFields"
    private const val FIELD_MESSAGE = "message"
    private const val FIELD_RECORDED_AT = "recordedAt"

    /**
     * 覆写一条诊断记录。
     *
     * 使用 commit 同步写入：本方法常在 attachBaseContext 阶段调用，若进程随后
     * 因补丁问题崩溃，commit 能保证下次启动 Dart 侧仍能查询到本次的诊断结果。
     */
    fun record(
        context: Context,
        status: String,
        patchVersion: String? = null,
        patchTargetVersionCode: Long? = null,
        appVersionCode: Long? = null,
        crashCount: Int? = null,
        attemptedLoaderFields: List<String>? = null,
        message: String? = null,
    ) {
        val json = JSONObject().apply {
            put(FIELD_STATUS, status)
            putOpt(FIELD_PATCH_VERSION, patchVersion)
            putOpt(FIELD_PATCH_TARGET_VC, patchTargetVersionCode)
            putOpt(FIELD_APP_VC, appVersionCode)
            putOpt(FIELD_CRASH_COUNT, crashCount)
            if (attemptedLoaderFields != null) {
                put(FIELD_ATTEMPTED_LOADER_FIELDS, JSONArray(attemptedLoaderFields))
            }
            putOpt(FIELD_MESSAGE, message)
            put(FIELD_RECORDED_AT, System.currentTimeMillis())
        }
        PatcherConfig.prefs(context).edit()
            .putString(KEY_LAST_BOOT_DIAG, json.toString())
            .commit()
        Log.d(TAG, "record status=$status patch=$patchVersion msg=$message")
    }

    /**
     * 读取最近一次 record。
     *
     * @return 诊断 Map，可直接交给 MethodChannel 发到 Dart 侧；
     *         null 表示从未 record 过（首次安装或 pm clear 后第一次启动且尚未到首帧）。
     */
    fun read(context: Context): Map<String, Any?>? {
        val raw = PatcherConfig.prefs(context).getString(KEY_LAST_BOOT_DIAG, null) ?: return null
        return try {
            val json = JSONObject(raw)
            val map = mutableMapOf<String, Any?>()
            map[FIELD_STATUS] = json.optString(FIELD_STATUS, UNKNOWN)
            map[FIELD_PATCH_VERSION] = json.optStringOrNull(FIELD_PATCH_VERSION)
            map[FIELD_PATCH_TARGET_VC] = json.optLongOrNull(FIELD_PATCH_TARGET_VC)
            map[FIELD_APP_VC] = json.optLongOrNull(FIELD_APP_VC)
            map[FIELD_CRASH_COUNT] = json.optIntOrNull(FIELD_CRASH_COUNT)
            map[FIELD_ATTEMPTED_LOADER_FIELDS] = json.optStringListOrNull(FIELD_ATTEMPTED_LOADER_FIELDS)
            map[FIELD_MESSAGE] = json.optStringOrNull(FIELD_MESSAGE)
            map[FIELD_RECORDED_AT] = json.optLong(FIELD_RECORDED_AT, 0L)
            map
        } catch (e: Exception) {
            Log.w(TAG, "read failed, raw=$raw", e)
            null
        }
    }

    // ---- 内部工具：JSONObject 缺字段时返回 null 而非 "" / 0 ----

    private fun JSONObject.optStringOrNull(key: String): String? =
        if (isNull(key) || !has(key)) null else optString(key, "").ifEmpty { null }

    private fun JSONObject.optLongOrNull(key: String): Long? =
        if (isNull(key) || !has(key)) null else optLong(key)

    private fun JSONObject.optIntOrNull(key: String): Int? =
        if (isNull(key) || !has(key)) null else optInt(key)

    private fun JSONObject.optStringListOrNull(key: String): List<String>? {
        if (isNull(key) || !has(key)) return null
        val arr = optJSONArray(key) ?: return null
        return List(arr.length()) { arr.optString(it) }
    }
}
