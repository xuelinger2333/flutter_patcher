package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Log
import io.flutter.app.FlutterApplication

/**
 * 宿主 App 需在 AndroidManifest.xml 中使用这个 Application（或在自己的 Application
 * 里调 [attachPatcher]）。
 *
 * 启动流程：
 * 1. attachBaseContext
 *    → CrashGuard.shouldLoadPatch() 熔断检查
 *    → PatchManager.getValidPatchPath() 磁盘补丁验签
 *    → LoaderHook.install() 反射替换 FlutterLoader
 *    → CrashGuard.markBooting() 标记「启动中」
 * 2. Dart 首帧 → MethodChannel("flutter_patcher#reportBootSuccess")
 *    → CrashGuard.markBootSuccess() 重置计数
 *
 * 中间 **不做** 原生层弱确认 —— Dart 首帧之前任何崩溃都计入熔断，
 * 这样 Dart 启动后立刻抛异常的场景也会被正确回滚。
 *
 * 用户如果已经有自己的 Application 基类，直接把 [attachPatcher] 搬过去即可，
 * 不需要继承本类。
 */
open class FlutterPatcherApplication : FlutterApplication() {

    companion object {
        private const val TAG = "FlutterPatcher/App"

        /**
         * 在 Application.attachBaseContext(base) 中、super 调用之后调用。
         * 返回补丁是否成功注入。
         */
        @JvmStatic
        fun attachPatcher(context: Context): Boolean {
            return try {
                val guard = CrashGuard(context)
                if (!guard.shouldLoadPatch()) {
                    Log.w(TAG, "circuit breaker tripped, skip patch")
                    return false
                }

                val path = PatchManager(context).getValidPatchPath()
                if (path == null) {
                    Log.d(TAG, "no usable patch, boot with built-in libapp.so")
                    return false
                }

                // 标记「启动中」——必须 commit 同步写入，确保进程崩溃前状态已持久化
                guard.markBooting()

                val ok = LoaderHook.install(context, path)
                if (!ok) {
                    // 注入失败：本次启动根本没换 libapp.so，不视为一次崩溃
                    guard.reset()
                }
                ok
            } catch (e: Exception) {
                Log.e(TAG, "attachPatcher failed, fallback to built-in", e)
                CrashGuard(context).reset()
                false
            }
        }
    }

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        attachPatcher(base)
    }
}
