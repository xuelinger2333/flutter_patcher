package com.flutter_patcher.flutter_patcher

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import kotlin.test.*

class BootChannelProfilerTest {
    private fun readable(buffer: ByteBuffer): ByteBuffer = buffer.apply { flip() }

    @Test fun preservesStandardCodecAndAssociatesTraceWithBootCallOnly() {
        val profiler = BootChannelProfiler()
        val args = mapOf("fingerprint" to "ab".repeat(32), "publicKeyBase64" to "key")
        val encoded = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall("bootPayload", args))
        val decoded = profiler.codec.decodeMethodCall(readable(encoded))
        assertEquals("bootPayload", decoded.method)
        assertEquals(args, decoded.arguments)
        val trace = assertNotNull(profiler.take())
        assertTrue(trace.decoded >= trace.begin)
        assertNull(profiler.take())
        profiler.codec.decodeMethodCall(readable(StandardMethodCodec.INSTANCE.encodeMethodCall(
            MethodCall("currentVersion", null))))
        assertNull(profiler.take())
    }

    @Test fun successEnvelopesRemainDecodableByStandardCodec() {
        val profiler = BootChannelProfiler()
        val value = mapOf("attempt" to "token", "profile_us" to mapOf("total" to 123L))
        val encoded = profiler.codec.encodeSuccessEnvelope(value)
        assertEquals(value, StandardMethodCodec.INSTANCE.decodeEnvelope(readable(encoded)))
    }
}
