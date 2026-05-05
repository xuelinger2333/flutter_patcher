package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Dart ↔ Android 的 MethodChannel 处理器。
 *
 * Channel 名：
 * - MethodChannel `flutter_patcher` —— RPC（saveConfig / applyPatch / ...）
 * - EventChannel  `flutter_patcher/events` —— applyPatch 过程的阶段 / 进度事件
 *
 * MethodChannel 方法：
 * - saveConfig(publicKeyBase64, maxCrashCount, strictSignature,
 *              loaderFieldCandidates, loaderFallbackHeuristic)
 * - markBooting()               — Dart init 最开头调用，补写一次「启动中」
 * - reportBootSuccess()         — Dart 首帧渲染时调用，清熔断
 * - reportDartBootError(Map)    — 引导阶段 Dart 未捕获异常上报，等同一次真崩溃
 * - applyPatch(Map) -> Map{ok, error, message}
 * - rollback()
 * - currentVersion() -> String?
 * - lastBootDiagnostic() -> Map? — 上次冷启动补丁加载诊断（见 BootDiagnosticStore）
 * - cacheDir() -> String — 插件可写的临时目录，供 Dart applyPatchBytes 内部 staging 使用
 * - appVersionCode() -> Long — 当前宿主 APK versionCode，A3 便捷查询
 * - deviceAbi() -> String — 当前设备首选 ABI，用于服务端按 ABI 分发补丁
 * - blacklist() -> List<Map> — 已知"装上就出事"的补丁本地黑名单
 * - clearBlacklist() — 清空黑名单（仅调试 / 显式恢复用）
 */
class FlutterPatcherPlugin :
    FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "FlutterPatcher/Plugin"
        private const val CHANNEL = "flutter_patcher"
        private const val EVENT_CHANNEL = "flutter_patcher/events"
    }

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var appContext: Context
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)
    }

    // ==================== EventChannel ====================

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emitProgress(phase: String, received: Long, total: Long) {
        val sink = eventSink ?: return
        val event = mapOf(
            "phase" to phase,
            "received" to received,
            "total" to total
        )
        main.post { sink.success(event) }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "saveConfig" -> handleSaveConfig(call, result)
            "markBooting" -> {
                CrashGuard(appContext).markBooting()
                result.success(null)
            }
            "reportBootSuccess" -> {
                CrashGuard(appContext).markBootSuccess()
                result.success(null)
            }
            "reportDartBootError" -> handleReportDartBootError(call, result)
            "applyPatch" -> handleApplyPatch(call, result)
            "rollback" -> handleRollback(result)
            "currentVersion" -> handleCurrentVersion(result)
            "lastBootDiagnostic" -> handleLastBootDiagnostic(result)
            "cacheDir" -> result.success(appContext.cacheDir.absolutePath)
            "appVersionCode" -> result.success(PatcherConfig.currentVersionCode(appContext))
            "deviceAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull().orEmpty())
            "blacklist" -> result.success(BlacklistStore.entries(appContext))
            "clearBlacklist" -> {
                BlacklistStore.clear(appContext)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    // ==================== handlers ====================

    private fun handleSaveConfig(call: MethodCall, result: Result) {
        val pk = call.argument<String>("publicKeyBase64") ?: ""
        val max = call.argument<Int>("maxCrashCount") ?: PatcherConfig.DEFAULT_MAX_CRASH
        val strict = call.argument<Boolean>("strictSignature") ?: PatcherConfig.DEFAULT_STRICT_SIG
        val fields = call.argument<List<String>>("loaderFieldCandidates") ?: emptyList()
        val heuristic = call.argument<Boolean>("loaderFallbackHeuristic")
            ?: PatcherConfig.DEFAULT_LOADER_HEURISTIC
        PatcherConfig.saveConfig(appContext, pk, max, strict, fields, heuristic)
        result.success(null)
    }

    private fun handleApplyPatch(call: MethodCall, result: Result) {
        @Suppress("UNCHECKED_CAST")
        val args = call.arguments as? Map<String, Any?>
        if (args == null) {
            result.error("INVALID_ARGS", "applyPatch expects a Map", null)
            return
        }
        Thread {
            val progress: ProgressCallback = { phase, received, total ->
                emitProgress(phase, received, total)
            }
            val applyResult = try {
                PatchManager(appContext, progress).applyPatch(args)
            } catch (e: Exception) {
                Log.e(TAG, "applyPatch error", e)
                ApplyResult.failure(ApplyErrorCode.UNKNOWN, e.message ?: e.javaClass.simpleName)
            }
            main.post { result.success(applyResult.toMap()) }
        }.start()
    }

    private fun handleRollback(result: Result) {
        Thread {
            try {
                PatchManager(appContext).rollback()
            } catch (e: Exception) {
                Log.e(TAG, "rollback error", e)
            }
            main.post { result.success(null) }
        }.start()
    }

    private fun handleCurrentVersion(result: Result) {
        val v = PatchManager(appContext).currentVersion()
        result.success(if (v.isEmpty()) null else v)
    }

    private fun handleLastBootDiagnostic(result: Result) {
        // null 表示从未 record 过（首次安装 / pm clear 后第一次启动且尚未到首帧）
        result.success(BootDiagnosticStore.read(appContext))
    }

    /**
     * Dart 侧 PlatformDispatcher.onError / FlutterError.onError 在「verifyAfter 窗口内」
     * 抓到的未捕获异常 ⇒ 等同 ApplicationExitInfo.REASON_CRASH 处理：crash_count += 1，
     * 达阈值则 onTrip 回调里走完整的"加黑名单 + 记诊断 + 删补丁"链路。
     *
     * 与 attachPatcher 里 shouldLoadPatch 的 onTrip 逻辑保持一致，让用户在 DiagCard
     * 上看到 status=DROPPED_CIRCUIT_BREAKER 而不是上一次的 status=PATCHED 残影。
     */
    private fun handleReportDartBootError(call: MethodCall, result: Result) {
        val message = call.argument<String>("message")
        val patchManager = PatchManager(appContext)
        val crashedMeta = patchManager.currentMeta()
        val appVc = PatcherConfig.currentVersionCode(appContext)

        CrashGuard(appContext).reportDartBootError(message) { crashCount ->
            if (crashedMeta != null) {
                BlacklistStore.add(
                    appContext,
                    crashedMeta.first,
                    crashedMeta.second,
                    BlacklistStore.REASON_BOOT_CRASH,
                )
            }
            BootDiagnosticStore.record(
                context = appContext,
                status = BootDiagnosticStore.DROPPED_CIRCUIT_BREAKER,
                patchVersion = crashedMeta?.first,
                appVersionCode = appVc,
                crashCount = crashCount,
                message = if (crashedMeta != null)
                    "$crashCount Dart boot failure(s); blacklisted (version=${crashedMeta.first}); ${message ?: ""}"
                else
                    "$crashCount Dart boot failure(s); ${message ?: ""}",
            )
        }
        result.success(null)
    }
}
