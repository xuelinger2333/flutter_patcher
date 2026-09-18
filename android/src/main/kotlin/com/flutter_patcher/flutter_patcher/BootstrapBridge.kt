package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer

/** Optional per-process fast path; multiple engine registrations disable it. */
internal class BootstrapBridge(private val context: Context, private val manager: BytecodePatchManager) {
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

    fun execute(bytes: ByteArray): ByteArray {
        val codec = StandardMethodCodec.INSTANCE
        val response = try {
            val call = codec.decodeMethodCall(ByteBuffer.wrap(bytes))
            val value = when (call.method) {
                "bootPayload" -> {
                    manager.announceBootstrap()
                    try {
                        manager.bootPayload(call.argument<String>("fingerprint") ?: "",
                            call.argument<String>("publicKeyBase64") ?: "")
                    } catch (error: Exception) {
                        BootDiagnosticStore.record(context, BootDiagnosticStore.UNKNOWN,
                            message = "Bytecode boot payload rejected: ${error.message}")
                        null
                    }
                }
                "markBooting" -> manager.markBooting(call.argument<String>("attempt"))
                else -> error("Unsupported bootstrap operation")
            }
            codec.encodeSuccessEnvelope(value)
        } catch (error: Exception) {
            codec.encodeErrorEnvelope("BYTECODE_REJECTED", error.message, null)
        }
        response.flip()
        return ByteArray(response.remaining()).also { response.get(it) }
    }
}
