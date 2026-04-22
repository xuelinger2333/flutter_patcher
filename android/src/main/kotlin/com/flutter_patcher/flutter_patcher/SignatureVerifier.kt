package com.flutter_patcher.flutter_patcher

import android.os.Build
import android.util.Base64
import android.util.Log
import java.io.File
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

/**
 * 补丁文件完整性与签名校验。
 *
 * 策略：
 * - MD5 校验：始终执行（来自 [com.flutter_patcher.flutter_patcher.PatchInfo.md5]）
 * - Ed25519 签名：
 *   - signature 为空 → 跳过（仅靠 MD5 + 传输层防篡改）
 *   - signature 非空 且 API >= 33 → 使用 JDK 原生 Ed25519 验签
 *   - signature 非空 且 API < 33：
 *     - strictSignature=true（默认安全） → **拒绝加载**，防止攻击者通过降级到低
 *       版本设备绕过签名校验
 *     - strictSignature=false → 跳过验签（调用方显式选择降级）
 *
 * 签名的消息体约定为 **MD5 小写 hex 字符串的 UTF-8 字节**，
 * 与 Dart 侧 PatchInfo.signature 含义保持一致。
 */
internal object SignatureVerifier {

    private const val TAG = "FlutterPatcher/Sig"

    /** 计算文件 MD5（小写 hex）。 */
    fun md5(file: File): String {
        val digest = MessageDigest.getInstance("MD5")
        file.inputStream().use { input ->
            val buf = ByteArray(8192)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * 仅校验 Ed25519 签名（调用方已确认 MD5 匹配）。
     *
     * - signature 为空 → 跳过返回 true
     * - signature 非空但 publicKey 未配置 → 拒绝
     * - API < 33 且 strictSignature=true → 拒绝（防止降级攻击）
     * - API < 33 且 strictSignature=false → 跳过返回 true
     * - API >= 33 → 真实 Ed25519 验签
     *
     * @param md5HexLower 已匹配并**小写化**的 md5 hex 字符串（作为签名消息体）
     */
    fun verifySignatureOnly(
        md5HexLower: String,
        signatureBase64: String,
        publicKeyBase64: String,
        strictSignature: Boolean = true
    ): Boolean {
        val sig = signatureBase64.trim()
        if (sig.isEmpty() || sig.equals("null", ignoreCase = true)) {
            Log.d(TAG, "signature empty, skip Ed25519 check")
            return true
        }
        if (publicKeyBase64.isEmpty()) {
            Log.w(TAG, "signature present but no public key configured, reject")
            return false
        }

        if (Build.VERSION.SDK_INT < 33) {
            if (strictSignature) {
                Log.e(
                    TAG,
                    "API ${Build.VERSION.SDK_INT} < 33, Ed25519 not supported; strict mode rejects. " +
                        "Pass strictSignature=false to FlutterPatcher.init to downgrade (NOT recommended)."
                )
                return false
            }
            Log.w(
                TAG,
                "API ${Build.VERSION.SDK_INT} < 33, Ed25519 not supported; strictSignature=false, skip"
            )
            return true
        }

        return try {
            verifyEd25519(md5HexLower, sig, publicKeyBase64)
        } catch (e: Exception) {
            Log.e(TAG, "Ed25519 verify failed", e)
            false
        }
    }

    /**
     * 完整校验：MD5 + 可选 Ed25519。
     *
     * @param file             已下载的补丁文件
     * @param expectedMd5      manifest 中的预期 MD5（小写 hex）
     * @param signatureBase64  manifest 中的 Ed25519 签名（Base64，允许为空）
     * @param publicKeyBase64  X.509 SubjectPublicKeyInfo 的 Base64 公钥（允许为空）
     * @param strictSignature  API < 33 是否拒绝签名校验（默认 true，安全）
     * @return 是否通过校验
     */
    fun verify(
        file: File,
        expectedMd5: String,
        signatureBase64: String,
        publicKeyBase64: String,
        strictSignature: Boolean = true
    ): Boolean {
        if (expectedMd5.isEmpty()) {
            Log.e(TAG, "expected md5 is empty, reject")
            return false
        }
        val actualMd5 = md5(file)
        if (!actualMd5.equals(expectedMd5, ignoreCase = true)) {
            Log.e(TAG, "md5 mismatch: expected=$expectedMd5, actual=$actualMd5")
            return false
        }
        return verifySignatureOnly(
            actualMd5.lowercase(),
            signatureBase64,
            publicKeyBase64,
            strictSignature
        )
    }

    private fun verifyEd25519(
        md5Hex: String,
        signatureBase64: String,
        publicKeyBase64: String
    ): Boolean {
        val pkBytes = Base64.decode(publicKeyBase64, Base64.NO_WRAP)
        val keySpec = X509EncodedKeySpec(pkBytes)
        val kf = KeyFactory.getInstance("Ed25519")
        val pk = kf.generatePublic(keySpec)

        val sig = Signature.getInstance("Ed25519")
        sig.initVerify(pk)
        sig.update(md5Hex.toByteArray(Charsets.UTF_8))

        val sigBytes = Base64.decode(signatureBase64, Base64.NO_WRAP)
        return sig.verify(sigBytes)
    }
}
