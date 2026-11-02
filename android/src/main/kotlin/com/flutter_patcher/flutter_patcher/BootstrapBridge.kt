package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer

/** The boot offer of [host], or null; a rejected offer runs the app as built. */
internal fun bootPayload(context: Context, host: PatchHost?, fingerprint: String, publicKey: String): Map<String, Any?>? =
    try {
        host?.bootPayload(fingerprint, publicKey)
    } catch (error: Exception) {
        BootDiagnosticStore.record(context, BootDiagnosticStore.UNKNOWN,
            message = "Boot payload rejected: ${error.message}")
        null
    }

/** Optional per-process fast path; multiple engine registrations disable it. */
internal class BootstrapBridge(private val context: Context, private val host: () -> PatchHost?) {
    private external fun nativeRegister()
    private external fun nativeUnregister()
    private var loaded = false

    init {
        val started = System.nanoTime()
        try {
            System.loadLibrary("patcher_boot")
            nativeRegister()
            loaded = true
            Log.i("flutter", "BYTECODE_BRIDGE_INIT_US: ${(System.nanoTime() - started) / 1000}")
        } catch (_: LinkageError) {
            // Missing/unsupported native library leaves the standard channel usable.
            Log.i("flutter", "BYTECODE_BRIDGE_UNAVAILABLE")
        }
    }

    fun close() {
        if (loaded) {
            nativeUnregister()
            loaded = false
        }
    }

    /**
     * Answers one request: the codec envelope's length, the envelope, then
     * an offer's `envelopeBytes` unencoded, so the largest value is copied
     * once here and never grows a codec buffer (see BOOTSTRAP_FFI.md).
     */
    fun execute(bytes: ByteArray): ByteArray {
        val started = System.nanoTime()
        val codec = StandardMethodCodec.INSTANCE
        var envelope: ByteArray? = null
        val response = try {
            val call = codec.decodeMethodCall(ByteBuffer.wrap(bytes))
            val decoded = System.nanoTime()
            val value = when (call.method) {
                "bootPayload" -> bootPayload(context, host(), call.argument<String>("fingerprint") ?: "",
                    call.argument<String>("publicKeyBase64") ?: "")
                "backgroundPayload" -> host()?.backgroundPayload(call.argument<String>("fingerprint") ?: "",
                    call.argument<String>("publicKeyBase64") ?: "")
                "markBooting" -> host()?.markBooting(call.argument<String>("attempt")) ?: false
                else -> error("Unsupported bootstrap operation")
            }
            @Suppress("UNCHECKED_CAST") val offer = value as? Map<String, Any?>
            envelope = offer?.get("envelopeBytes") as? ByteArray
            codec.encodeSuccessEnvelope(if (offer == null) value else offer - "envelopeBytes" + ("bridge_us" to mapOf(
                "decode" to (decoded - started) / 1000, "dispatch" to (System.nanoTime() - decoded) / 1000)))
        } catch (error: Exception) {
            envelope = null
            codec.encodeErrorEnvelope("BYTECODE_REJECTED", error.message, null)
        }
        response.flip()
        val tail = envelope ?: ByteArray(0)
        return ByteArray(4 + response.remaining() + tail.size).also {
            ByteBuffer.wrap(it).putInt(response.remaining()).put(response).put(tail)
        }
    }
}