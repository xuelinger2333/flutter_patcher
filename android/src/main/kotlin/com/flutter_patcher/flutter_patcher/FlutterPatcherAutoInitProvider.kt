package com.flutter_patcher.flutter_patcher

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.util.Log

/**
 * 自动初始化 ContentProvider —— 宿主无需改 Application 即可挂上补丁加载。
 *
 * # 生命周期
 * Android `ActivityThread.handleBindApplication` 的固定顺序：
 *
 * ```
 * Application.attachBaseContext()
 *   ↓
 * installContentProviders()  ← 本 provider.onCreate 在这里触发
 *   ↓
 * Application.onCreate()
 *   ↓
 * Activity lifecycle（FlutterActivity.onCreate → 首次 new FlutterEngine）
 * ```
 *
 * 插件反射替换 `FlutterInjector.flutterLoader` 只要求"早于第一次
 * `FlutterInjector.instance()` 真正被使用"，ContentProvider 这个时机足够。
 * 这是 Firebase / WorkManager / androidx.startup 都在用的自动初始化模式。
 *
 * # 边界：什么时候走不通
 * 宿主在自己 `Application.attachBaseContext` 里 **预热 FlutterEngine**（罕见，
 * 主要出现在大厂混合工程的冷启动优化）。此时 provider 还没轮到、Engine 已起来，
 * 反射来不及。这类工程应在宿主 Manifest 里关掉自动初始化，改为显式调用：
 *
 * ```xml
 * <provider
 *     android:name="com.flutter_patcher.flutter_patcher.FlutterPatcherAutoInitProvider"
 *     android:authorities="${applicationId}.flutter_patcher.autoinit"
 *     tools:node="remove" />
 * ```
 *
 * 然后在自己的 Application 里：
 *
 * ```kotlin
 * override fun attachBaseContext(base: Context) {
 *     super.attachBaseContext(base)
 *     FlutterPatcherApplication.attachPatcher(base)
 * }
 * ```
 */
class FlutterPatcherAutoInitProvider : ContentProvider() {

    companion object {
        private const val TAG = "FlutterPatcher/AutoInit"
    }

    override fun onCreate(): Boolean {
        val ctx = context ?: run {
            Log.w(TAG, "context is null, skip auto init")
            return false
        }
        Log.d(TAG, "auto init via ContentProvider.onCreate()")
        FlutterPatcherApplication.attachPatcher(ctx)
        return true
    }

    // ==================== no-op data surface ====================
    // 本 provider 不对外暴露任何数据；所有 CRUD 都返回空 / 0 即可。

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}
