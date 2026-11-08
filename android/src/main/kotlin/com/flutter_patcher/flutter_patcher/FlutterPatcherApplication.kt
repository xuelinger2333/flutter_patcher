package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Log
import java.io.File
import io.flutter.app.FlutterApplication

/**
 * Host Application, or call [attachPatcher] from your own Application's
 * attachBaseContext (after super).
 *
 * Only an SO host built with a host policy swaps `libapp.so` here, before the
 * engine starts: [PatchHost.bootCode] settles the previous attempt, checks the
 * active candidate's unpacked files and arms a new attempt,
 * then [LoaderHook] points FlutterLoader at it. Its resources reach the engine
 * from the generated Dart entry. A bytecode host loads its patch from Dart; a
 * host without a policy runs the original app.
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
            // 0.1.x kept SO patches here; nothing reads them any more.
            File(context.filesDir, "flutter_patcher").takeIf { it.exists() }?.deleteRecursively()
            attachResult = try {
                val host = HostTrustConfig.load(context)
                host?.strategy == "so" && bootSo(context, PatchHost.of(context, host))
            } catch (e: Exception) {
                Log.e(TAG, "attachPatcher failed, fallback to built-in", e)
                BootDiagnosticStore.record(context = context, status = BootDiagnosticStore.UNKNOWN,
                    appVersionCode = PatcherConfig.currentVersionCode(context),
                    message = e.message ?: e.javaClass.simpleName)
                false
            }
            return attachResult
        }

        private fun bootSo(context: Context, so: PatchHost): Boolean {
            val libapp = so.bootCode() ?: return false
            val attempted = mutableListOf<String>()
            val ok = LoaderHook.install(context, libapp.path, attempted)
            if (!ok) {
                so.cancel()
                BootDiagnosticStore.record(context = context, status = BootDiagnosticStore.HOOK_INSTALL_FAILED,
                    appVersionCode = PatcherConfig.currentVersionCode(context),
                    attemptedLoaderFields = attempted,
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