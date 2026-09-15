package com.flutter_patcher.flutter_patcher

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import kotlin.test.*

class BootChannelProfilerTest {
    private fun readable(buffer: ByteBuffer): ByteBuffer = buffer.apply { flip() }

    @Test fun preservesStandardCodecAndAssociatesTraceWithBootstrapCallsOnly() {
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

    @Test fun markTraceBoundsCorrelationWithoutChangingArguments() {
        val profiler = BootChannelProfiler()
        val args = mapOf("attempt" to "token", "profileRequest" to "x".repeat(120))
        val decoded = profiler.codec.decodeMethodCall(readable(
            StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall("markBooting", args))))
        assertEquals(args, decoded.arguments)
        val trace = assertNotNull(profiler.take())
        assertEquals("markBooting", trace.method)
        assertEquals("x".repeat(96), trace.request)
        assertNull(profiler.take())
    }

    @Test fun errorEnvelopeRemainsByteForByteStandardCodec() {
        fun bytes(buffer: ByteBuffer) = ByteArray(buffer.position()).also {
            readable(buffer).get(it)
        }
        val profiler = BootChannelProfiler()
        assertContentEquals(
            bytes(StandardMethodCodec.INSTANCE.encodeErrorEnvelope("rejected", "message", null)),
            bytes(profiler.codec.encodeErrorEnvelope("rejected", "message", null)))
    }

    @Test fun successEnvelopesRemainDecodableByStandardCodec() {
        val profiler = BootChannelProfiler()
        val value = mapOf("attempt" to "token", "profile_us" to mapOf("total" to 123L))
        val encoded = profiler.codec.encodeSuccessEnvelope(value)
        assertEquals(value, StandardMethodCodec.INSTANCE.decodeEnvelope(readable(encoded)))
    }

    @Test fun largeByteSnapshotDoesNotAliasOriginalAfterEncoding() {
        val original = ByteArray(2 * 1024 * 1024) { (it * 31).toByte() }
        val expected = original.copyOf()
        val profiler = BootChannelProfiler()
        val encoded = profiler.codec.encodeSuccessEnvelope(mapOf(
            "transportVersion" to 1, "attempt" to "token", "envelopeBytes" to original))
        original.fill(0)
        val decoded = StandardMethodCodec.INSTANCE.decodeEnvelope(readable(encoded)) as Map<*, *>
        assertEquals(1, decoded["transportVersion"])
        assertContentEquals(expected, decoded["envelopeBytes"] as ByteArray)
    }
}
