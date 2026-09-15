package com.flutter_patcher.flutter_patcher

import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodCodec
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.json.JSONObject

/** [PROFILE] Monotonic spans; encoding always delegates to StandardMethodCodec. */
internal class BootChannelProfiler {
    internal class Trace(val begin: Long, val decoded: Long, val method: String, val request: String?) {
        var submitted = 0L
        var worker = 0L
        var operationDone = 0L
        var reply = 0L
        var encodeBegin = 0L
        var encodeEnd = 0L
        var workerCpuBegin = 0L
        var workerCpuEnd = 0L
    }
    private val incoming = ThreadLocal<Trace>()
    private val outgoing = ThreadLocal<Trace>()
    val codec: MethodCodec = object : MethodCodec by StandardMethodCodec.INSTANCE {
        override fun decodeMethodCall(message: ByteBuffer): MethodCall {
            val begin = System.nanoTime()
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(message)
            if (call.method == "bootPayload" || call.method == "markBooting") {
                incoming.set(Trace(begin, System.nanoTime(), call.method,
                    (call.argument<Any?>("profileRequest") ?: call.argument<Any?>("request"))
                        .let { it as? String }?.take(96)))
            }
            return call
        }
        override fun encodeSuccessEnvelope(result: Any?): ByteBuffer {
            val trace = outgoing.get()
            if (trace != null) trace.encodeBegin = System.nanoTime()
            val bytes = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(result)
            if (trace != null) trace.encodeEnd = System.nanoTime()
            return bytes
        }
        override fun encodeErrorEnvelope(code: String, message: String?, details: Any?): ByteBuffer {
            val trace = outgoing.get()
            if (trace != null) trace.encodeBegin = System.nanoTime()
            val bytes = StandardMethodCodec.INSTANCE.encodeErrorEnvelope(code, message, details)
            if (trace != null) trace.encodeEnd = System.nanoTime()
            return bytes
        }
    }
    fun take(): Trace? = incoming.get().also { incoming.remove() }
    fun beginReply(trace: Trace) { outgoing.set(trace) }
    fun endReply(trace: Trace) {
        val end = System.nanoTime()
        outgoing.remove()
        fun at(value: Long) = (value - trace.begin) / 1000
        val encoded = (trace.encodeEnd - trace.encodeBegin) / 1000
        // Subtract nested encoding from the surrounding reply span.
        Log.i("flutter", "BYTECODE_CHANNEL_TIMING: " + JSONObject(mapOf(
            "schema" to 2, "method" to trace.method, "request" to trace.request,
            "worker_cpu_us" to (trace.workerCpuEnd - trace.workerCpuBegin) / 1000,
            "decode_us" to at(trace.decoded),
            "handler_us" to at(trace.submitted) - at(trace.decoded),
            "worker_queue_us" to at(trace.worker) - at(trace.submitted),
            "operation_us" to at(trace.operationDone) - at(trace.worker),
            "main_queue_us" to at(trace.reply) - at(trace.operationDone),
            "encode_us" to encoded,
            "reply_send_us" to at(end) - at(trace.reply) - encoded,
            "total_us" to at(end)
        )).toString())
    }
}
