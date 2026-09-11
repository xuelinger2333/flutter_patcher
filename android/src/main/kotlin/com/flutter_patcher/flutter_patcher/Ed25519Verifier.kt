package com.flutter_patcher.flutter_patcher

import java.math.BigInteger
import java.security.MessageDigest

/**
 * Verification-only Ed25519 (RFC 8032 sections 5.1.3 and 5.1.7).
 * Uses platform integer arithmetic and SHA-512, never an Ed25519 JCA provider.
 * Arithmetic is variable-time: all inputs are public. Do not reuse for signing.
 * Require canonical encodings and a nonidentity prime-order public key,
 * preserving the previous validatePublicKeyFull policy.
 */
internal object Ed25519Verifier {
    private val zero = BigInteger.ZERO
    private val one = BigInteger.ONE
    private val two = BigInteger.valueOf(2)
    private val p = one.shiftLeft(255).subtract(BigInteger.valueOf(19))
    private val order = one.shiftLeft(252).add(BigInteger("27742317777372353535851937790883648493"))
    private val d = BigInteger.valueOf(-121665).multiply(BigInteger.valueOf(121666).modInverse(p)).mod(p)
    private val sqrtMinusOne = two.modPow(p.subtract(one).divide(BigInteger.valueOf(4)), p)
    private val sqrtExponent = p.add(BigInteger.valueOf(3)).divide(BigInteger.valueOf(8))
    private val identity = Point(zero, one, one, zero)
    private val base = decode(ByteArray(32) { 0x66 }.also { it[0] = 0x58 })!!

    // RFC 8410: id-Ed25519, absent parameters, 32-byte BIT STRING.
    private val spkiPrefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
        0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)

    fun rawPublicKey(spki: ByteArray): ByteArray {
        require(spki.size == spkiPrefix.size + 32 &&
            spki.copyOfRange(0, spkiPrefix.size).contentEquals(spkiPrefix)) {
            "Invalid Ed25519 SubjectPublicKeyInfo"
        }
        return spki.copyOfRange(spkiPrefix.size, spki.size)
    }

    fun verify(publicKey: ByteArray, signature: ByteArray, message: ByteArray): Boolean {
        if (publicKey.size != 32 || signature.size != 64) return false
        val s = littleEndian(signature.copyOfRange(32, 64))
        if (s >= order) return false
        val a = decode(publicKey) ?: return false
        if (a.same(identity) || !multiply(a, order).same(identity)) return false
        val encodedR = signature.copyOfRange(0, 32)
        val r = decode(encodedR) ?: return false
        val hash = MessageDigest.getInstance("SHA-512").apply {
            update(encodedR)
            update(publicKey)
            update(message)
        }.digest()
        val k = littleEndian(hash).mod(order)
        // Strict (uncofactored) equation [S]B = R + [k]A.
        return multiply(base, s).same(add(r, multiply(a, k)))
    }

    private fun littleEndian(bytes: ByteArray) = BigInteger(1, bytes.reversedArray())

    private fun decode(encoded: ByteArray): Point? {
        val bytes = encoded.clone()
        val sign = bytes[31].toInt() and 0x80 != 0
        bytes[31] = (bytes[31].toInt() and 0x7f).toByte()
        val y = littleEndian(bytes)
        if (y >= p) return null
        val yy = y.multiply(y).mod(p)
        val denominator = d.multiply(yy).add(one).mod(p)
        if (denominator == zero) return null
        val xx = yy.subtract(one).multiply(denominator.modInverse(p)).mod(p)
        var x = xx.modPow(sqrtExponent, p)
        if (x.multiply(x).mod(p) != xx) x = x.multiply(sqrtMinusOne).mod(p)
        if (x.multiply(x).mod(p) != xx || x == zero && sign) return null
        if (x.testBit(0) != sign) x = p.subtract(x)
        return Point(x, y, one, x.multiply(y).mod(p))
    }

    // Extended Edwards coordinates: x=X/Z, y=Y/Z, XY=ZT.
    private class Point(val x: BigInteger, val y: BigInteger, val z: BigInteger, val t: BigInteger) {
        fun same(other: Point) = x.multiply(other.z).subtract(other.x.multiply(z)).mod(p) == zero &&
            y.multiply(other.z).subtract(other.y.multiply(z)).mod(p) == zero
    }

    // Complete addition for a=-1, also valid for doubling and identity.
    // https://www.rfc-editor.org/rfc/rfc8032#section-5.1.4
    private fun add(left: Point, right: Point): Point {
        val a = left.y.subtract(left.x).multiply(right.y.subtract(right.x)).mod(p)
        val b = left.y.add(left.x).multiply(right.y.add(right.x)).mod(p)
        val c = two.multiply(d).multiply(left.t).multiply(right.t).mod(p)
        val dd = two.multiply(left.z).multiply(right.z).mod(p)
        val e = b.subtract(a)
        val f = dd.subtract(c)
        val g = dd.add(c)
        val h = b.add(a)
        return Point(e.multiply(f).mod(p), g.multiply(h).mod(p),
            f.multiply(g).mod(p), e.multiply(h).mod(p))
    }

    private fun multiply(point: Point, scalar: BigInteger): Point {
        var result = identity
        var current = point
        for (bit in 0 until scalar.bitLength()) {
            if (scalar.testBit(bit)) result = add(result, current)
            current = add(current, current)
        }
        return result
    }
}
