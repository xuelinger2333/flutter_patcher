package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.renderer.FlutterRenderer
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
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
 * - saveConfig(maxCrashCount, loaderFieldCandidates, loaderFallbackHeuristic)
 * - bootPayload / markBooting   — 生成的入口取本次启动的补丁并开始启动尝试
 * - backgroundPayload           — 后台引擎的 isolate 取同一份补丁，不开始启动尝试
 * - reportBootSuccess()         — 首帧确认本次补丁启动成功（原生首帧监听也会确认）
 * - reportDartBootError(Map)    — 引导阶段 Dart 未捕获异常上报，等同一次真崩溃
 * - checkSignedManifest / applySignedManifest / updatePublicationTrust — 签名清单
 * - rollback()
 * - currentVersion() -> String?
 * - lastBootDiagnostic() -> Map? — 上次冷启动补丁加载诊断（见 BootDiagnosticStore）
 * - appVersionCode() -> Long — 当前宿主 APK versionCode
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
    // The host's patch side; null without a policy. Loaded off the main
    // thread on first use (it reads the APK).
    private val hostLoader = lazy<PatchHost?> {
        HostTrustConfig.load(appContext)?.let { PatchHost.of(appContext, it) }
    }
    private val host by hostLoader
    private var bootstrapBridge: BootstrapBridge? = null
    private val bootProfiler = BootChannelProfiler()
    private var renderer: FlutterRenderer? = null
    private val firstFrame = object : FlutterUiDisplayListener {
        override fun onFlutterUiDisplayed() {
            // Only a loaded host can have started an attempt.
            if (!hostLoader.isInitialized()) return
            val patches = host ?: return
            val token = patches.frameToken ?: return
            Thread {
                try { patches.success(token) }
                catch (error: Exception) { Log.w(TAG, "Cannot persist first frame", error) }
            }.start()
        }
        override fun onFlutterUiNoLongerDisplayed() {}
    }
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        bootstrapBridge = BootstrapBridge(appContext) { host }
        renderer = binding.textureRegistry as? FlutterRenderer
        renderer?.addIsDisplayingFlutterUiListener(firstFrame)
        channel = MethodChannel(binding.binaryMessenger, CHANNEL, bootProfiler.codec)
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
        val trace = bootProfiler.take()
        when (call.method) {
            "bootPayload" -> hostCall(result, trace) {
                bootPayload(appContext, host, call.argument<String>("fingerprint") ?: "",
                    call.argument<String>("publicKeyBase64") ?: "")
            }
            "backgroundPayload" -> hostCall(result) {
                host?.backgroundPayload(call.argument<String>("fingerprint") ?: "",
                    call.argument<String>("publicKeyBase64") ?: "")
            }
            "saveConfig" -> handleSaveConfig(call, result)
            // A legacy call without a token starts and settles nothing.
            "markBooting" -> hostCall(result, trace) { host?.markBooting(call.argument<String>("attempt")) ?: false }
            "reportBootSuccess" -> hostCall(result) { host?.success(call.argument<String>("attempt")); null }
            "reportDartBootError" -> hostCall(result) {
                // A user's init() owns its FlutterError hook and reports
                // without a token; bind it to the started attempt.
                val patches = host
                patches?.error(call.argument<String>("attempt") ?: patches.frameToken,
                    call.argument<String>("message"), call.argument<Boolean>("quarantine") == true)
                null
            }
            "applySignedManifest" -> authenticatedCall(result) {
                authenticated().applyManifest(call.argument<String>("wire") ?: "", ::emitProgress)
            }
            "hostStrategy" -> hostCall(result) { HostTrustConfig.load(appContext)?.strategy }
            "checkSignedManifest" -> authenticatedCall(result) {
                authenticated().inspect(call.argument<String>("wire") ?: "")
            }
            "updatePublicationTrust" -> authenticatedCall(result) {
                authenticated().updateTrust(call.argument<String>("wire") ?: "")
                mapOf("ok" to true)
            }
            "rollback" -> handleRollback(result)
            "currentVersion" -> hostCall(result) { host?.currentVersion() }
            "lastBootDiagnostic" -> handleLastBootDiagnostic(result)
            "appVersionCode" -> result.success(PatcherConfig.currentVersionCode(appContext))
            "deviceAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull().orEmpty())
            "blacklist" -> hostCall(result) { host?.blacklist() ?: emptyList<Map<String, Any?>>() }
            "clearBlacklist" -> hostCall(result) { host?.clearBlacklist(); null }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        bootstrapBridge?.close()
        bootstrapBridge = null
        renderer?.removeIsDisplayingFlutterUiListener(firstFrame)
        renderer = null
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    // ==================== handlers ====================

    private fun authenticated(): PatchHost = host ?: error("Host has no authenticated policy")

    private fun authenticatedCall(result: Result, operation: () -> Any?) {
        Thread {
            try {
                val value = operation()
                main.post { result.success(value) }
            } catch (_: java.io.IOException) {
                // Network exception messages may contain credential-bearing URLs.
                main.post { result.error("AUTH_UPDATE_IO", "Authenticated update I/O failed", null) }
            } catch (_: Exception) {
                main.post { result.error("AUTH_UPDATE_REJECTED", "Authenticated update rejected", null) }
            }
        }.start()
    }

    private fun hostCall(result: Result, trace: BootChannelProfiler.Trace? = null, operation: () -> Any?) {
        if (trace != null) trace.submitted = System.nanoTime()
        Thread {
            if (trace != null) {
                trace.worker = System.nanoTime()
                trace.workerCpuBegin = android.os.Debug.threadCpuTimeNanos()
            }
            try {
                val value = operation()
                if (trace != null) {
                    trace.operationDone = System.nanoTime()
                    trace.workerCpuEnd = android.os.Debug.threadCpuTimeNanos()
                }
                main.post {
                    if (trace != null) {
                        trace.reply = System.nanoTime()
                        bootProfiler.beginReply(trace)
                    }
                    try { result.success(value) }
                    finally { if (trace != null) bootProfiler.endReply(trace) }
                }
            } catch (error: Exception) {
                if (trace != null) {
                    trace.operationDone = System.nanoTime()
                    trace.workerCpuEnd = android.os.Debug.threadCpuTimeNanos()
                }
                main.post {
                    if (trace != null) {
                        trace.reply = System.nanoTime()
                        bootProfiler.beginReply(trace)
                    }
                    try { result.error("BYTECODE_REJECTED", error.message, null) }
                    finally { if (trace != null) bootProfiler.endReply(trace) }
                }
            }
        }.start()
    }

    private fun handleSaveConfig(call: MethodCall, result: Result) {
        val max = call.argument<Int>("maxCrashCount") ?: PatcherConfig.DEFAULT_MAX_CRASH
        val fields = call.argument<List<String>>("loaderFieldCandidates") ?: emptyList()
        val heuristic = call.argument<Boolean>("loaderFallbackHeuristic")
            ?: PatcherConfig.DEFAULT_LOADER_HEURISTIC
        PatcherConfig.saveConfig(appContext, max, fields, heuristic)
        result.success(null)
    }

    private fun handleRollback(result: Result) {
        Thread {
            try {
                host?.rollback()
            } catch (e: Exception) {
                Log.e(TAG, "rollback error", e)
                main.post { result.error("ROLLBACK_FAILED", "Could not persist rollback", null) }
                return@Thread
            }
            main.post { result.success(null) }
        }.start()
    }


    private fun handleLastBootDiagnostic(result: Result) {
        // null 表示从未 record 过（首次安装 / pm clear 后第一次启动且尚未到首帧）
        result.success(BootDiagnosticStore.read(appContext))
    }

}
