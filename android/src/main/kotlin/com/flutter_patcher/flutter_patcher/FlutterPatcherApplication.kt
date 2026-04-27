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
 *    → CrashGuard.shouldLoadPatch() 熔断检查（API 30+ 走 ApplicationExitInfo
 *      精确识别上次进程是真崩溃还是被用户/系统结束；API < 30 走朴素策略：
 *      patch_loading=true 即视为一次崩溃）
 *    → PatchManager.getValidPatchPath() 磁盘补丁验签
 *    → LoaderHook.install() 反射替换 FlutterLoader
 *    → CrashGuard.markBooting() 标记「启动中」并记录 pid（API 30+ 用于 ExitInfo 查询）
 * 2. Dart 首帧 → MethodChannel("flutter_patcher#reportBootSuccess")
 *    → CrashGuard.markBootSuccess() 重置计数
 *
 * API 30+ 上，用户主动从最近任务划掉 / OOM kill / 强停等「非崩溃退出」不计入
 * crash_count，只有真崩溃（CRASH / CRASH_NATIVE / ANR / INITIALIZATION_FAILURE）
 * 才会触发熔断。API < 30 没有这层分类，对长尾设备做 fail-fast 取舍。
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
            // 本次启动是否已往 BootDiagnosticStore 写过精准 status。
            // 用于在收尾阶段判断要不要兜底成 NO_PATCH（避免覆盖更精准的 reason）。
            var diagRecorded = false
            val appVc = PatcherConfig.currentVersionCode(context)

            return try {
                // 在熔断/校验丢弃前预读 (version, md5)，等会儿入黑名单要用。
                // 即便文件后续被删，这里捕获的字符串仍有效。
                val patchManager = PatchManager(context)
                val crashedMeta = patchManager.currentMeta()

                val guard = CrashGuard(context)
                val canLoad = guard.shouldLoadPatch { crashCount ->
                    // 熔断触发 ⇒ 这个补丁连续没活到 verified，加入黑名单防止重试。
                    if (crashedMeta != null) {
                        BlacklistStore.add(
                            context,
                            crashedMeta.first,
                            crashedMeta.second,
                            BlacklistStore.REASON_BOOT_CRASH,
                        )
                    }
                    BootDiagnosticStore.record(
                        context = context,
                        status = BootDiagnosticStore.DROPPED_CIRCUIT_BREAKER,
                        patchVersion = crashedMeta?.first,
                        appVersionCode = appVc,
                        crashCount = crashCount,
                        message = if (crashedMeta != null)
                            "$crashCount boot failure(s); blacklisted (version=${crashedMeta.first})"
                        else
                            "$crashCount boot failure(s)",
                    )
                    diagRecorded = true
                }
                if (!canLoad) {
                    Log.w(TAG, "circuit breaker tripped, skip patch")
                    return false
                }

                val path = patchManager.getValidPatchPath { status, version, extras ->
                    // md5 / signature 失败 = 强烈"补丁有问题"信号，连带入黑名单。
                    // meta_corrupted / version_code_mismatch 不入黑名单（前者 key 不全，后者
                    // 属于正常 APK 升级而非补丁本身有问题）。
                    val effectiveMd5 = extras["effectiveMd5"] as? String
                    val blacklistReason = when (status) {
                        BootDiagnosticStore.DROPPED_MD5_MISMATCH ->
                            BlacklistStore.REASON_MD5_MISMATCH
                        BootDiagnosticStore.DROPPED_SIGNATURE_INVALID ->
                            BlacklistStore.REASON_SIGNATURE_INVALID
                        else -> null
                    }
                    if (blacklistReason != null && version != null && !effectiveMd5.isNullOrEmpty()) {
                        BlacklistStore.add(context, version, effectiveMd5, blacklistReason)
                    }

                    BootDiagnosticStore.record(
                        context = context,
                        status = status,
                        patchVersion = version,
                        patchTargetVersionCode = extras["patchTargetVersionCode"] as? Long,
                        appVersionCode = (extras["appVersionCode"] as? Long) ?: appVc,
                        message = extras["message"] as? String,
                    )
                    diagRecorded = true
                }
                if (path == null) {
                    Log.d(TAG, "no usable patch, boot with built-in libapp.so")
                    if (!diagRecorded) {
                        // DROPPED_* 是用户最关心的"上次为啥被丢弃"信息，不应被这次
                        // 无信息量的 NO_PATCH 覆盖。典型场景：上一次冷启动里 Dart 错误
                        // 钩子把补丁判崩 + record(DROPPED_CIRCUIT_BREAKER) + 删补丁，
                        // 但进程没死、UI 没建出来；用户划掉重开后这一次进入本分支，
                        // 写 NO_PATCH 会让 DiagCard 看不到 trip 信息。
                        // 后续装上新补丁时，line 127 会写 PATCHED 自然覆盖，sticky 自动解除。
                        val existing = BootDiagnosticStore.read(context)
                        val existingStatus = existing?.get("status") as? String
                        val shouldPreserve = existingStatus != null &&
                            existingStatus.startsWith("DROPPED_")
                        if (!shouldPreserve) {
                            BootDiagnosticStore.record(
                                context = context,
                                status = BootDiagnosticStore.NO_PATCH,
                                appVersionCode = appVc,
                            )
                        } else {
                            Log.d(TAG, "preserved existing $existingStatus over NO_PATCH")
                        }
                    }
                    return false
                }

                // 走到这里说明补丁已通过校验。预先取版本号，方便后面 record。
                val patchVersion = patchManager.currentVersion().ifEmpty { null }

                // 标记「启动中」——必须 commit 同步写入，确保进程崩溃前状态已持久化
                guard.markBooting()

                val attemptedFields = mutableListOf<String>()
                val ok = LoaderHook.install(context, path, attemptedFields)
                if (ok) {
                    BootDiagnosticStore.record(
                        context = context,
                        status = BootDiagnosticStore.PATCHED,
                        patchVersion = patchVersion,
                        appVersionCode = appVc,
                    )
                } else {
                    // 注入失败：本次启动根本没换 libapp.so，不视为一次崩溃
                    guard.reset()
                    BootDiagnosticStore.record(
                        context = context,
                        status = BootDiagnosticStore.HOOK_INSTALL_FAILED,
                        patchVersion = patchVersion,
                        appVersionCode = appVc,
                        attemptedLoaderFields = attemptedFields.toList(),
                        message = "FlutterLoader reflection failed; patch retained",
                    )
                }
                ok
            } catch (e: Exception) {
                Log.e(TAG, "attachPatcher failed, fallback to built-in", e)
                CrashGuard(context).reset()
                BootDiagnosticStore.record(
                    context = context,
                    status = BootDiagnosticStore.UNKNOWN,
                    appVersionCode = appVc,
                    message = e.message ?: e.javaClass.simpleName,
                )
                false
            }
        }
    }

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        attachPatcher(base)
    }
}
