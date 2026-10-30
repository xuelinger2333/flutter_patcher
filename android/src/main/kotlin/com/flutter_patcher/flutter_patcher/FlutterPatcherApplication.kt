package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Log
import io.flutter.app.FlutterApplication

/**
 * Host Application, or call [attachPatcher] from your own Application's
 * attachBaseContext (after super).
 *
 * Only an SO host built with a host policy swaps `libapp.so` here, before the
 * engine starts: [SoPatchManager.boot] settles the previous attempt, checks the
 * active candidate's authorization and arms a new attempt, then [LoaderHook]
 * points FlutterLoader at it. A bytecode host loads its patch from Dart; a host
 * without a policy runs the original app.
 */
open class FlutterPatcherApplication : FlutterApplication() {

    companion object {
        private const val TAG = "FlutterPatcher/App"

        @Volatile
        private var attachAttempted = false

        @Volatile
        private var attachResult = false

        /** Returns whether a patch was injected; runs once per process. */
        @JvmStatic
        @Synchronized
        fun attachPatcher(context: Context): Boolean {
            if (attachAttempted) {
                Log.d(TAG, "attachPatcher already ran in this process, result=$attachResult")
                return attachResult
            }
            attachAttempted = true
            attachResult = try {
                val host = HostTrustConfig.load(context)
                host?.strategy == "so" && bootSo(context, SoPatchManager(context, host))
            } catch (e: Exception) {
                Log.e(TAG, "attachPatcher failed, fallback to built-in", e)
                BootDiagnosticStore.record(context = context, status = BootDiagnosticStore.UNKNOWN,
                    appVersionCode = PatcherConfig.currentVersionCode(context),
                    message = e.message ?: e.javaClass.simpleName)
                false
            }
            return attachResult
        }

        private fun bootSo(context: Context, so: SoPatchManager): Boolean {
            val patch = so.boot() ?: return false
            val ok = LoaderHook.install(context, patch.soPath, patch.assetsBundlePath, patch.assetsArchivePath, mutableListOf())
            if (!ok) {
                SoPatchManager.cancel(context)
                BootDiagnosticStore.record(context = context, status = BootDiagnosticStore.HOOK_INSTALL_FAILED,
                    appVersionCode = PatcherConfig.currentVersionCode(context),
                    message = "FlutterLoader reflection failed; patch retained")
            }
            return ok
        }
    }

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        attachPatcher(this)
    }
}