package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterJNI
import io.flutter.embedding.engine.loader.FlutterLoader
import java.lang.reflect.Field
import java.lang.reflect.Modifier
import java.util.concurrent.ExecutorService

/**
 * 通过反射把 FlutterInjector 内部持有的 FlutterLoader 替换为自定义实现。
 *
 * # 为什么是最脆弱的部分
 * Flutter Engine 每个大版本都可能改内部字段名 / 改 FlutterLoader 的方法签名。
 * 本类采用「候选字段名 + 类型启发式 + Dart 侧可覆盖」三层保护：
 *
 * ## 已验证字段名（按 Flutter 版本）
 * | Flutter 版本 | FlutterInjector 字段 | ensureInitializationComplete 签名         |
 * |-------------|----------------------|-------------------------------------------|
 * | 3.19.x      | `flutterLoader`      | (Context, @Nullable String[])             |
 * | 3.22.x      | `flutterLoader`      | (Context, @Nullable String[])             |
 * | 3.24.x      | `flutterLoader`      | (Context, @Nullable String[])             |
 * | 3.27.x      | `flutterLoader`      | (Context, @Nullable String[])             |
 * | 3.29.x      | `flutterLoader`      | (Context, @Nullable String[])             |
 * | 3.32.x      | `flutterLoader`      | (Context, @Nullable String[])             |
 * | 3.35.x      | `flutterLoader`      | (Context, @Nullable String[])             |
 * | 3.38.x      | `flutterLoader`      | (Context, @Nullable String[])             |
 *
 * 超出此范围（比如未来 Flutter 4.x）请先通过 `FlutterPatcher.init(loaderFieldCandidates: [...])`
 * 下发新的字段名，再升级本库。
 *
 * 必须 **早于** 任何 Flutter 引擎初始化（即 FlutterActivity/FlutterFragment 创建
 * 之前）调用，最佳时机是 Application.attachBaseContext。
 */
internal object LoaderHook {

    private const val TAG = "FlutterPatcher/Hook"

    /** 默认候选字段名。多字段是为了抵御 Flutter 未来改名。 */
    private val DEFAULT_CANDIDATES = listOf("flutterLoader")

    /**
     * 用带补丁路径的自定义 FlutterLoader 替换默认实现。
     *
     * @param context        用于读 PatcherConfig 中的 Dart 侧覆盖配置
     * @param patchSoPath    补丁 libapp.so 的绝对路径
     * @param attemptedFields 可选 out 参数：调用前传入空 MutableList，方法返回后
     *   会包含本次按顺序尝试过的字段候选名（无论成功失败）。供
     *   [BootDiagnosticStore.HOOK_INSTALL_FAILED] 上报使用。
     * @return 是否成功注入
     */
    fun install(
        context: Context,
        patchSoPath: String,
        patchAssetsPath: String? = null,
        patchAssetsArchivePath: String? = null,
        attemptedFields: MutableList<String>? = null,
    ): Boolean {
        return try {
            val injector = FlutterInjector.instance()
            if (!patchAssetsArchivePath.isNullOrEmpty() && !patchAssetsPath.isNullOrEmpty()) {
                if (!verifyAssetArchiveReadable(context, patchAssetsArchivePath, patchAssetsPath)) {
                    throw IllegalStateException(
                        "AssetManager.addAssetPath failed: $patchAssetsArchivePath"
                    )
                }
                installPatchedFlutterJniFactory(
                    injector,
                    context,
                    patchAssetsArchivePath,
                    patchAssetsPath
                )
            }
            val candidates = buildCandidates(context)
            attemptedFields?.addAll(candidates)
            val heuristic = PatcherConfig.loaderFallbackHeuristic(context)
            val field = findLoaderField(injector.javaClass, candidates, heuristic)
                ?: throw IllegalStateException(
                    "FlutterInjector has no FlutterLoader field (tried: $candidates, " +
                        "heuristic=$heuristic). Flutter API may have changed; pass " +
                        "loaderFieldCandidates to FlutterPatcher.init."
                )
            field.isAccessible = true

            val patched = PatchedFlutterLoader(patchSoPath, patchAssetsPath)
            field.set(injector, patched)

            Log.d(TAG, "FlutterLoader patched via field '${field.name}' -> $patchSoPath")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "install failed", e)
            false
        }
    }

    private fun verifyAssetArchiveReadable(
        context: Context,
        path: String,
        bundlePath: String
    ): Boolean {
        return try {
            val packageContext = context.createPackageContext(context.packageName, 0)
            addAssetPathTo(packageContext, path, bundlePath, verifyManifest = true)
        } catch (e: Throwable) {
            Log.e(TAG, "createPackageContext asset patch failed", e)
            false
        }
    }

    private fun installPatchedFlutterJniFactory(
        injector: FlutterInjector,
        context: Context,
        archivePath: String,
        bundlePath: String
    ) {
        val field = injector.javaClass.getDeclaredField("flutterJniFactory")
        field.isAccessible = true
        field.set(
            injector,
            PatchedFlutterJniFactory(context.applicationContext, archivePath, bundlePath)
        )
        Log.d(TAG, "FlutterJNI factory patched for asset bundle=$bundlePath")
    }

    private class PatchedFlutterJniFactory(
        private val context: Context,
        private val archivePath: String,
        private val bundlePath: String
    ) : FlutterJNI.Factory() {
        override fun provideFlutterJNI(): FlutterJNI {
            return PatchedFlutterJNI(context, archivePath, bundlePath)
        }
    }

    private class PatchedFlutterJNI(
        private val context: Context,
        private val archivePath: String,
        private val bundlePath: String
    ) : FlutterJNI() {
        override fun runBundleAndSnapshotFromLibrary(
            bundlePath: String,
            entrypointFunctionName: String?,
            pathToEntrypointFunction: String?,
            assetManager: android.content.res.AssetManager,
            entrypointArgs: MutableList<String>?,
            engineId: Long
        ) {
            try {
                val packageContext = context.createPackageContext(context.packageName, 0)
                if (addAssetPathTo(packageContext, archivePath, this.bundlePath)) {
                    super.runBundleAndSnapshotFromLibrary(
                        this.bundlePath,
                        entrypointFunctionName,
                        pathToEntrypointFunction,
                        packageContext.assets,
                        entrypointArgs,
                        engineId
                    )
                    return
                }
            } catch (e: Throwable) {
                Log.e(TAG, "patched FlutterJNI asset setup failed", e)
            }
            super.runBundleAndSnapshotFromLibrary(
                bundlePath,
                entrypointFunctionName,
                pathToEntrypointFunction,
                assetManager,
                entrypointArgs,
                engineId
            )
        }
    }

    private fun addAssetPathTo(
        context: Context,
        path: String,
        bundlePath: String?,
        verifyManifest: Boolean = false
    ): Boolean {
        val method = context.assets.javaClass.getMethod("addAssetPath", String::class.java)
        val cookie = method.invoke(context.assets, path) as? Int ?: 0
        if (cookie == 0) {
            Log.e(TAG, "AssetManager rejected asset archive: $path")
            return false
        }
        if (verifyManifest && !bundlePath.isNullOrEmpty()) {
            val manifestPath = "${bundlePath.trimEnd('/')}/AssetManifest.bin"
            try {
                context.assets.open(manifestPath).use { input ->
                    input.read()
                }
            } catch (e: Throwable) {
                Log.e(TAG, "AssetManager self-check failed for $manifestPath", e)
                return false
            }
        }
        return true
    }

    private fun buildCandidates(context: Context): List<String> {
        val override = PatcherConfig.loaderFieldCandidates(context)
        return if (override.isNotEmpty()) override + DEFAULT_CANDIDATES.filter { it !in override }
        else DEFAULT_CANDIDATES
    }

    /**
     * 定位 FlutterLoader 字段：
     * 1. 按候选名精确匹配（安全）
     * 2. 按类型精确匹配：字段类型是 FlutterLoader 或其子类（安全）
     * 3. 启发式回退：首个非 static、非 ExecutorService 的实例字段（**可能命错字段**）
     *
     * Layer 3 默认关闭：宁可退回内置 .so，也不要瞎设字段导致不可预测的崩溃。
     * 通过 FlutterPatcher.init(loaderFallbackHeuristic: true) 显式启用。
     */
    private fun findLoaderField(
        clazz: Class<*>,
        candidates: List<String>,
        heuristic: Boolean
    ): Field? {
        for (name in candidates) {
            try {
                return clazz.getDeclaredField(name)
            } catch (_: NoSuchFieldException) {
                // continue
            }
        }
        Log.w(TAG, "no exact-name match, falling back to type-based detection")

        clazz.declaredFields
            .firstOrNull { FlutterLoader::class.java.isAssignableFrom(it.type) }
            ?.let { return it }

        if (!heuristic) {
            Log.w(TAG, "type-based match failed; heuristic disabled, giving up")
            return null
        }
        Log.w(TAG, "type-based match failed; using heuristic (may pick wrong field)")
        return clazz.declaredFields.firstOrNull {
            !Modifier.isStatic(it.modifiers) &&
                it.type != ExecutorService::class.java
        }
    }
}

internal fun patchedAssetLookupKey(patchAssetsPath: String, asset: String): String {
    return "${patchAssetsPath.trimEnd('/')}/${asset.trimStart('/')}"
}

internal fun patchedPackageAssetLookupKey(
    patchAssetsPath: String,
    asset: String,
    packageName: String
): String {
    return patchedAssetLookupKey(patchAssetsPath, "packages/$packageName/$asset")
}

/**
 * 自定义 FlutterLoader：通过 `--aot-shared-library-name` 参数让 Flutter Engine
 * 从补丁路径加载 libapp.so，替代 APK 内置版本。
 *
 * `--aot-shared-library-name=<path>` 从 Flutter 1.x 开始一直稳定存在，跨大版本兼容。
 */
internal class PatchedFlutterLoader(
    private val patchSoPath: String,
    private val patchAssetsPath: String? = null,
) : FlutterLoader() {

    companion object {
        private const val TAG = "FlutterPatcher/Loader"
    }

    override fun ensureInitializationComplete(context: Context, args: Array<String>?) {
        val patched = (args ?: emptyArray()).toMutableList()
        patched.add("--aot-shared-library-name=$patchSoPath")
        if (!patchAssetsPath.isNullOrEmpty()) {
            patched.add("--flutter-assets-dir=$patchAssetsPath")
        }
        Log.d(TAG, "load patch: so=$patchSoPath assets=${patchAssetsPath ?: "<built-in>"}")
        super.ensureInitializationComplete(context, patched.toTypedArray())
    }

    override fun findAppBundlePath(): String {
        return patchAssetsPath ?: super.findAppBundlePath()
    }

    override fun getLookupKeyForAsset(asset: String): String {
        return patchAssetsPath?.let { patchedAssetLookupKey(it, asset) }
            ?: super.getLookupKeyForAsset(asset)
    }

    override fun getLookupKeyForAsset(asset: String, packageName: String): String {
        return patchAssetsPath?.let { patchedPackageAssetLookupKey(it, asset, packageName) }
            ?: super.getLookupKeyForAsset(asset, packageName)
    }
}
