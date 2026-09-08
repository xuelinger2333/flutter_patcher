package com.flutter_patcher.flutter_patcher

/** Token-bound, idempotent startup settlement. A first frame never undoes failure. */
internal class BytecodeAttempt(val token: String) {
    var running = false
        private set
    var failed = false
        private set
    private var succeeded = false
    fun start(received: String?): Boolean {
        if (received != token || running || failed) return false
        running = true
        return true
    }
    fun succeed(received: String?): Boolean {
        if (received != token || !running || failed || succeeded) return false
        succeeded = true
        return true
    }
    fun fail(received: String?): Boolean {
        if (received != token || failed) return false
        failed = true
        return true
    }
}
