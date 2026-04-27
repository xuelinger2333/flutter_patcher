package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * 已知"装上就出事"的补丁本地黑名单。
 *
 * # 为什么需要
 * 没有黑名单时，若服务端持续下发同一个有问题的补丁：
 * 客户端下载 → 校验通过 → 装上 → 启动崩溃 → 自动回滚 → 下次又收到 → 死循环。
 * 黑名单把"已经验证过的坏补丁"记下来，再次下发直接拒，连流量都不浪费。
 *
 * # 双键设计 (version, md5)
 * - 只用 `version`：开发者修了 bug 后用同样 version 重发会被无脑拒绝
 * - 只用 `md5`：可读性差，debug 时不知道是哪个补丁
 * - 用 (version, md5) 同时作为复合键：不同 md5 视作"修了再试"，允许下载
 *
 * # 持久性
 * **不**因 APK 版本升级清空。否则线上事故时若服务端配置忘下架，升 APK 后又
 * 能下到坏补丁。除非用户主动调 [clear]，黑名单条目永久保留。
 *
 * # 容量
 * FIFO 上限 [MAX_ENTRIES]=50，超出按时间淘汰最老条目。极端情况下避免无限增长。
 */
internal object BlacklistStore {

    private const val TAG = "FlutterPatcher/Blacklist"

    /** SharedPreferences key（沿用 PatcherConfig.PREFS_NAME 文件，与现有键无冲突）。*/
    private const val KEY_BLACKLIST = "patch_blacklist"

    /** 黑名单条目数上限，达到后 FIFO 淘汰最早入黑的条目。*/
    const val MAX_ENTRIES = 50

    // ---- 入黑原因常量（与 BootDiagnosticStore 命名风格保持一致）----

    const val REASON_BOOT_CRASH = "BOOT_CRASH"
    const val REASON_MD5_MISMATCH = "MD5_MISMATCH"
    const val REASON_SIGNATURE_INVALID = "SIGNATURE_INVALID"
    const val REASON_META_CORRUPTED = "META_CORRUPTED"

    // ---- 字段 key ----

    private const val FIELD_VERSION = "version"
    private const val FIELD_MD5 = "md5"
    private const val FIELD_REASON = "reason"
    private const val FIELD_BLACKLISTED_AT = "blacklistedAt"

    /**
     * 把 (version, md5) 加入黑名单。重复 add 会更新 reason + 时间戳，不会出现重复条目。
     * version 或 md5 为空字符串则忽略（防御性，不进黑名单）。
     */
    @Synchronized
    fun add(context: Context, version: String, md5: String, reason: String) {
        if (version.isEmpty() || md5.isEmpty()) {
            Log.w(TAG, "skip blacklist entry: version='$version' md5='$md5'")
            return
        }
        val arr = readArray(context)
        // 找到旧条目并删除（按双键），再追加到末尾，达到"重复 add 时刷新位置 + 元数据"的语义
        val md5Lower = md5.lowercase()
        val filtered = JSONArray()
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val v = obj.optString(FIELD_VERSION)
            val m = obj.optString(FIELD_MD5)
            if (v == version && m == md5Lower) continue
            filtered.put(obj)
        }
        filtered.put(JSONObject().apply {
            put(FIELD_VERSION, version)
            put(FIELD_MD5, md5Lower)
            put(FIELD_REASON, reason)
            put(FIELD_BLACKLISTED_AT, System.currentTimeMillis())
        })
        // FIFO 淘汰：超过上限就丢最老的
        val capped = if (filtered.length() > MAX_ENTRIES) {
            val drop = filtered.length() - MAX_ENTRIES
            val sliced = JSONArray()
            for (i in drop until filtered.length()) sliced.put(filtered.opt(i))
            sliced
        } else {
            filtered
        }
        PatcherConfig.prefs(context).edit()
            .putString(KEY_BLACKLIST, capped.toString())
            .commit()
        Log.w(TAG, "blacklisted version=$version md5=$md5Lower reason=$reason (${capped.length()}/$MAX_ENTRIES)")
    }

    /** 命中 (version, md5) 双键则返回 true。md5 大小写不敏感比较。*/
    fun contains(context: Context, version: String, md5: String): Boolean {
        if (version.isEmpty() || md5.isEmpty()) return false
        val arr = readArray(context)
        val md5Lower = md5.lowercase()
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            if (obj.optString(FIELD_VERSION) == version &&
                obj.optString(FIELD_MD5).equals(md5Lower, ignoreCase = true)
            ) {
                return true
            }
        }
        return false
    }

    /** 全部黑名单条目（旧→新顺序）。供 Dart 业务侧查询展示用。*/
    fun entries(context: Context): List<Map<String, Any?>> {
        val arr = readArray(context)
        return List(arr.length()) { i ->
            val obj = arr.optJSONObject(i)
            mapOf(
                FIELD_VERSION to obj?.optString(FIELD_VERSION),
                FIELD_MD5 to obj?.optString(FIELD_MD5),
                FIELD_REASON to obj?.optString(FIELD_REASON),
                FIELD_BLACKLISTED_AT to (obj?.optLong(FIELD_BLACKLISTED_AT) ?: 0L),
            )
        }
    }

    /** 清空整个黑名单。慎用：通常只在调试时调用。*/
    fun clear(context: Context) {
        PatcherConfig.prefs(context).edit().remove(KEY_BLACKLIST).commit()
        Log.w(TAG, "blacklist cleared")
    }

    private fun readArray(context: Context): JSONArray {
        val raw = PatcherConfig.prefs(context).getString(KEY_BLACKLIST, null) ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (e: Exception) {
            Log.w(TAG, "blacklist json corrupt, resetting", e)
            JSONArray()
        }
    }
}
