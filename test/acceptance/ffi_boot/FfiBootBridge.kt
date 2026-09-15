package com.flutter_patcher.flutter_patcher

import android.util.Log
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer

/** Experimental transport only, compiled into a disposable source copy. */
internal class FfiBootBridge(private val manager: BytecodePatchManager) {
    private external fun nativeRegister()
    init {
        val started=System.nanoTime()
        System.loadLibrary("wp24_boot")
        nativeRegister()
        Log.i("flutter","WP24_BRIDGE_INIT_US: ${(System.nanoTime()-started)/1000}")
    }
    fun execute(bytes: ByteArray): ByteArray {
        val codec=StandardMethodCodec.INSTANCE
        val response=try {
            val call=codec.decodeMethodCall(ByteBuffer.wrap(bytes))
            val value=when(call.method) {
                // Test-only cancellation barrier, never included in production.
                "wp24_delay" -> {Thread.sleep(600); null}
                "bootPayload" -> {
                    manager.announceBootstrap()
                    manager.bootPayload(call.argument<String>("fingerprint") ?: "",
                        call.argument<String>("publicKeyBase64") ?: "")
                }
                "markBooting" -> manager.markBooting(call.argument<String>("attempt"))
                else -> error("Unsupported experimental operation")
            }
            codec.encodeSuccessEnvelope(value)
        } catch(_: Exception) {codec.encodeErrorEnvelope("BYTECODE_REJECTED","Bridge operation rejected",null)}
        response.flip()
        return ByteArray(response.remaining()).also {response.get(it)}
    }
}
