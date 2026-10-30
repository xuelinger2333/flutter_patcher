package com.flutter_patcher.flutter_patcher

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import android.util.Log

/**
 * Classifies how the process of a patched boot attempt ended.
 *
 * - API 30+ with a recorded pid: [ApplicationExitInfo] gives the exact reason.
 *   Only CRASH, CRASH_NATIVE, ANR and INITIALIZATION_FAILURE count; a swipe
 *   from recents, OOM or a deliberate exit() does not.
 * - API < 30, or no exit record: a process that died before its first frame
 *   (still `loading`) counts as a crash. A native crash or ANR after the first
 *   frame is therefore not detected there; Dart errors are reported separately.
 */
internal class CrashGuard(private val context: Context) {

    companion object {
        private const val TAG = "FlutterPatcher/Guard"
    }

    fun previousSessionCrashed(loading: Boolean, pid: Int): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && pid > 0) {
            val record = queryExitInfo(pid)
            if (record != null) return when (record.reason) {
                ApplicationExitInfo.REASON_CRASH,
                ApplicationExitInfo.REASON_CRASH_NATIVE,
                ApplicationExitInfo.REASON_ANR,
                ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> true
                else -> false
            }
        }
        return loading
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun queryExitInfo(pid: Int): ApplicationExitInfo? {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        return try {
            am?.getHistoricalProcessExitReasons(context.packageName, pid, 1)?.firstOrNull()
        } catch (e: Throwable) {
            Log.w(TAG, "getHistoricalProcessExitReasons failed", e)
            null
        }
    }
}