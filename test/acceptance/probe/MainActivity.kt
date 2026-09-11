package com.example.wp9_acceptance

import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Test-only, separate APK. No patch manager, offers or persistent state writes. */
class MainActivity : FlutterActivity() {
    override fun getInitialRoute(): String = intent.getStringExtra("probe_mode") ?: "empty"

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val profiler = BootChannelProfiler()
        val main = Handler(Looper.getMainLooper())
        MethodChannel(engine.dartExecutor.binaryMessenger, "wp9_probe", profiler.codec)
            .setMethodCallHandler { call, result ->
                val trace = profiler.take()!!
                val mode = call.argument<String>("mode")!!
                val request = call.argument<String>("request")!!
                trace.submitted = System.nanoTime()
                Thread {
                    trace.worker = System.nanoTime()
                    try {
                        require(mode in listOf("empty", "bytes", "verified"))
                        val bytes = if (mode == "empty") ByteArray(0)
                            else assets.open("probe.fptc").use { it.readBytes() }
                        if (mode == "verified") {
                            val config = JSONObject(assets.open("probe.json").bufferedReader().use { it.readText() })
                            BytecodeEnvelope.verify(bytes, config.getString("fingerprint"),
                                Base64.decode(config.getString("public_key"), Base64.DEFAULT))
                            require(BytecodeEnvelope.digest(bytes) == config.getString("sha256"))
                        }
                        val value = mapOf("request" to request, "envelopeBytes" to bytes)
                        trace.operationDone = System.nanoTime()
                        main.post {
                            trace.reply = System.nanoTime()
                            profiler.beginReply(trace)
                            try { result.success(value) }
                            finally { profiler.endReply(trace) }
                        }
                    } catch (error: Exception) {
                        main.post { result.error("PROBE_FAILED", error.toString(), null) }
                    }
                }.start()
            }
    }
}
