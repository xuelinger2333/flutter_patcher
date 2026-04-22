package com.flutter_patcher.flutter_patcher

/**
 * [PatchManager.applyPatch] 的结构化返回值。
 *
 * 通过 MethodChannel 以 `Map<String, Any?>` 形式序列化到 Dart 侧，由
 * `PatchApplyResult.fromNative()` 反解。
 *
 * 错误码与使用建议见 [ApplyErrorCode]。
 */
internal data class ApplyResult(
    val ok: Boolean,
    val errorCode: String? = null,
    val message: String? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "ok" to ok,
        "error" to errorCode,
        "message" to message
    )

    companion object {
        val SUCCESS = ApplyResult(ok = true)

        fun failure(code: String, message: String? = null): ApplyResult =
            ApplyResult(ok = false, errorCode = code, message = message)
    }
}

/**
 * applyPatch 可能的失败原因。调用方（Dart 业务层）按需要做不同处理：
 *
 * - [INVALID_ARGS]：服务端下发的 JSON 缺字段 → 告警服务端
 * - [BSDIFF_DISABLED]：本宿主未编译 bsdiff native 模块 → 服务端停止对此客户端下发 bsdiff
 * - [NETWORK]：下载失败（重试后依然失败）→ 稍后重试
 * - [MD5_MISMATCH]：下载文件 md5 不匹配 → CDN 脏数据或服务端 md5 算错，检查后重试
 * - [SIGNATURE_INVALID]：Ed25519 验签失败（或 strict 模式下 API < 33 直接拒绝）→
 *   可能被篡改，**不建议**自动重试
 * - [BSDIFF_APPLY_FAILED]：native bsdiff 合成失败 → 通常是基础 libapp.so 与服务端
 *   预期不匹配，检查 APK 版本和 diff 生成逻辑
 * - [TARGET_MD5_MISMATCH]：bsdiff 合成后的 .so md5 与 targetMd5 不符 → 同上
 * - [IO_ERROR]：磁盘 / 文件系统错误（磁盘满、权限）→ 稍后重试
 * - [UNKNOWN]：未被分类的异常 → 上报到监控，看日志定位
 */
internal object ApplyErrorCode {
    const val INVALID_ARGS = "INVALID_ARGS"
    const val BSDIFF_DISABLED = "BSDIFF_DISABLED"
    const val NETWORK = "NETWORK"
    const val MD5_MISMATCH = "MD5_MISMATCH"
    const val SIGNATURE_INVALID = "SIGNATURE_INVALID"
    const val BSDIFF_APPLY_FAILED = "BSDIFF_APPLY_FAILED"
    const val TARGET_MD5_MISMATCH = "TARGET_MD5_MISMATCH"
    const val IO_ERROR = "IO_ERROR"
    const val UNKNOWN = "UNKNOWN"
}
