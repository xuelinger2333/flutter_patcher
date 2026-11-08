package com.flutter_patcher.flutter_patcher

/**
 * 安装补丁文件（PatchHost.apply）的结构化返回值。
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
 * - [INVALID_ARGS]：序号不大于已接受的序号（旧补丁或旧撤回）→ 用草稿重新发布以取得新序号
 * - [BLACKLISTED]：该补丁曾导致启动失败，已在本地黑名单 → 撤回补丁或发布修复
 * - [NETWORK]：下载失败（由 Dart 侧报告）→ 稍后重试
 * - [SIGNATURE_INVALID]：文件不属于本宿主、内容不完整或签名无效 → 可能被篡改，**不建议**自动重试
 * - [IO_ERROR]：磁盘 / 文件系统错误（磁盘满、权限）→ 稍后重试
 * - [UNKNOWN]：未被分类的异常 → 上报到监控，看日志定位
 */
internal object ApplyErrorCode {
    const val INVALID_ARGS = "INVALID_ARGS"
    const val BLACKLISTED = "BLACKLISTED"
    const val NETWORK = "NETWORK"
    const val SIGNATURE_INVALID = "SIGNATURE_INVALID"
    const val IO_ERROR = "IO_ERROR"
    const val UNKNOWN = "UNKNOWN"
}
