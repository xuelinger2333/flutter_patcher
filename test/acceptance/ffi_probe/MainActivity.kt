package com.example.wp24_probe

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Independent test APK: both transports read the same asset via this function. */
class MainActivity : FlutterActivity() {
    private external fun registerProvider()
    fun readPayload(size: Int): ByteArray {
        require(size in 0..16*1024*1024)
        return if (size == 0) ByteArray(0) else assets.open("payload-$size.bin").use { it.readBytes() }
    }
    override fun getInitialRoute(): String = intent.getStringExtra("probe_mode") ?: "channel:0"
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val init = System.nanoTime()
        System.loadLibrary("wp24_transport")
        registerProvider()
        val initUs = (System.nanoTime()-init)/1000
        val main = Handler(Looper.getMainLooper())
        MethodChannel(engine.dartExecutor.binaryMessenger, "wp24_probe").setMethodCallHandler { call, result ->
            if (call.method == "info") { result.success(mapOf("init_us" to initUs)); return@setMethodCallHandler }
            if (call.method != "bytes") { result.notImplemented(); return@setMethodCallHandler }
            val submitted = System.nanoTime()
            Thread {
                val begin = System.nanoTime()
                try {
                    val bytes = readPayload(call.argument<Int>("size")!!)
                    val done = System.nanoTime()
                    main.post { result.success(mapOf("bytes" to bytes,
                        "worker_queue_us" to (begin-submitted)/1000,
                        "read_us" to (done-begin)/1000,
                        "main_queue_us" to (System.nanoTime()-done)/1000)) }
                } catch (_: Exception) { main.post { result.error("READ_FAILED", "Probe read failed", null) } }
            }.start()
        }
    }
}
