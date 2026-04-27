import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpClient, HttpHeaders, Platform;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show EventChannel;
import 'package:flutter/widgets.dart';

import 'src/blacklist.dart';
import 'src/boot_diagnostic.dart';
import 'src/patch_info.dart';
import 'src/patcher_channel.dart';

export 'src/blacklist.dart';
export 'src/boot_diagnostic.dart';
export 'src/patch_info.dart';

/// Android libapp.so 热更新入口。
///
/// 对外只暴露 5 个静态方法/属性：
/// - [init]           启动时调用，执行崩溃检测 + 下发配置 + 首帧清熔断
/// - [checkUpdate]    向服务端发起补丁检查
/// - [applyPatch]     下载、验签、落盘（下次冷启动生效）
/// - [rollback]       手动删除当前补丁
/// - [currentVersion] 当前已生效的补丁版本号
///
/// 补丁的加载（反射替换 FlutterLoader）发生在原生 Application.attachBaseContext，
/// **早于** Dart 引擎启动；Dart 侧的 [init] 做：
///   1. 标记「启动中」（与原生 attachBaseContext 的标记互相兜底）
///   2. 下发配置到原生 SharedPreferences（公钥、熔断阈值、loader 字段候选名）
///   3. 注册首帧回调，渲染完毕后清零熔断计数
class FlutterPatcher {
  FlutterPatcher._();

  static bool _inited = false;
  static bool _bootReported = false;
  static bool _bootErrorReported = false;
  static bool _nonAndroidWarned = false;

  /// 非 Android 平台一次性 warning，避免跨平台项目静默看不出问题。
  /// 返回 true 表示"当前平台不支持，调用方应立即返回"。
  static bool _notAndroidGuard(String method) {
    if (Platform.isAndroid) return false;
    if (!_nonAndroidWarned) {
      _nonAndroidWarned = true;
      debugPrint(
        '[FlutterPatcher] WARNING: $method called on ${Platform.operatingSystem}. '
        'This plugin only supports Android; all calls are no-ops. '
        'See README > 已知限制与合规.',
      );
    }
    return true;
  }

  static const EventChannel _eventChannel =
      EventChannel('flutter_patcher/events');
  static Stream<PatchApplyProgress>? _progressStream;

  /// [applyPatch] 过程中的阶段 / 进度事件流（广播）。
  ///
  /// 在调用 [applyPatch] **之前** 订阅即可；一次调用期间会依次收到
  /// `downloading`（可能多次，带字节数）→ `verifying` → 可选 `bsdiff_merging`
  /// → `finalizing` 各阶段事件。非 Android 平台返回空流。
  ///
  /// ```dart
  /// final sub = FlutterPatcher.applyProgress.listen((p) {
  ///   switch (p.phase) {
  ///     case PatchApplyPhase.downloading:
  ///       setState(() => _progress = p.fraction ?? 0);
  ///       break;
  ///     case PatchApplyPhase.verifying:
  ///     case PatchApplyPhase.bsdiffMerging:
  ///     case PatchApplyPhase.finalizing:
  ///       // 可刷新"处理中..."UI
  ///       break;
  ///   }
  /// });
  /// final result = await FlutterPatcher.applyPatch(info);
  /// await sub.cancel();
  /// ```
  static Stream<PatchApplyProgress> get applyProgress {
    if (_notAndroidGuard('applyProgress')) return const Stream.empty();
    return _progressStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((raw) => PatchApplyProgress.fromNative(raw));
  }

  /// 启动时调用。幂等。
  ///
  /// - [publicKeyBase64] X.509 SubjectPublicKeyInfo（DER）Base64 编码的 Ed25519
  ///   公钥。为空时跳过签名校验，仅靠 MD5 + HTTPS 防篡改。
  /// - [maxCrashCount]   熔断器容忍的连续启动失败次数，默认 **1（fail-fast）**。
  ///   补丁加载后崩溃是明确"补丁有问题"信号，1 次崩溃即丢弃 + 入黑名单。
  ///   如需保留 0.0.x 时代的"崩 2 次才回滚"行为，显式传 `maxCrashCount: 2`。
  /// - [strictSignature] Ed25519 验签严格模式，默认 **true**（推荐）。
  ///   Android JDK 在 API 33+ 才支持 Ed25519；低版本设备遇到带签名的补丁时：
  ///   - `true`：拒绝加载（防止攻击者通过降级到低版本设备绕过签名）
  ///   - `false`：跳过签名校验，仅保留 MD5 + HTTPS 防护（不推荐，除非确定
  ///     支持设备范围主要在 API 33 以下且接受此风险）
  /// - [loaderFieldCandidates] `FlutterInjector` 内部字段名候选列表。默认
  ///   `['flutterLoader']` 覆盖 Flutter 3.19 ~ 3.38。未来新版 Flutter 改名时，
  ///   **不升级本库** 的前提下通过传入新名字即可适配。
  /// - [loaderFallbackHeuristic] 当 [loaderFieldCandidates] 和类型匹配都失败后，
  ///   是否启用启发式扫描"第一个非 static、非 ExecutorService 的实例字段"作为
  ///   最后兜底。默认 **false**（安全）：宁可退回 APK 内置 .so，也不瞎设字段
  ///   导致不可预测的崩溃。只有你明确知道要这么做（比如适配新 Flutter 私有
  ///   API 调研过程中）才应打开。
  /// - [verifyAfter] 首帧渲染后再观察多久"前台连续存活、无 crash"才算 verified
  ///   并清熔断。默认 5 秒：覆盖首屏 + 一两次用户交互。
  ///   - 越短：verified 越早，但漏掉首屏点击 crash 的概率越大
  ///   - 越长：保护更严，但中途 crash 仍触发熔断的概率也越大
  ///   注：计时只在 [AppLifecycleState.resumed] 状态累计；后台时挂起避免误清。
  ///
  /// 约定：
  /// - 调用者应在 `main()` 里、`runApp()` 之前 `await` 本方法
  /// - 本方法 **不会** 重新加载 libapp.so —— 运行时切换发生在下次冷启动
  static Future<void> init({
    String publicKeyBase64 = '',
    int maxCrashCount = 1,
    bool strictSignature = true,
    List<String> loaderFieldCandidates = const ['flutterLoader'],
    bool loaderFallbackHeuristic = false,
    Duration verifyAfter = const Duration(seconds: 5),
  }) async {
    if (_notAndroidGuard('init')) return;
    if (_inited) return;
    _inited = true;
    _verifyAfter = verifyAfter;

    // 1. 最开头标记「启动中」。与原生 attachBaseContext 内的标记互相兜底。
    //    如果 Dart init 之前就崩（原生阶段），原生标记生效；
    //    如果 runApp 之后但首帧前崩，Dart 标记生效。
    try {
      await PatcherChannel.markBooting();
    } catch (e, s) {
      _log('markBooting failed: $e', s);
    }

    // 1.5. 安装 Dart 层未捕获异常钩子，覆盖 ApplicationExitInfo 看不到的"白屏"
    //      场景：补丁里 main()/build()/异步链 throw 被 framework 接住，进程不死，
    //      首帧不触发，操作系统记录的 ExitReason 是用户主动关。
    _installBootErrorCatchers();

    // 2. 下发配置（给 **下次** 冷启动的原生验签用）
    try {
      await PatcherChannel.saveConfig(
        publicKeyBase64: publicKeyBase64,
        maxCrashCount: maxCrashCount,
        strictSignature: strictSignature,
        loaderFieldCandidates: loaderFieldCandidates,
        loaderFallbackHeuristic: loaderFallbackHeuristic,
      );
    } catch (e, s) {
      _log('saveConfig failed: $e', s);
    }

    // 3. 首帧 + 前台存活 verifyAfter 后清熔断
    _BootVerifier.start();
  }

  /// 主动重置熔断计数（通常由 [init] 在首帧后自动触发）。
  /// 暴露为 public，以防调用方希望在「业务首页渲染完」这一更严格的时机再清零。
  static Future<void> reportBootSuccess() async {
    if (_notAndroidGuard('reportBootSuccess')) return;
    if (_bootReported) return;
    _bootReported = true;
    try {
      await PatcherChannel.reportBootSuccess();
    } catch (e, s) {
      _log('reportBootSuccess failed: $e', s);
    }
  }

  /// 便捷 HTTP 更新检查 —— **可选工具**，不是核心 API。
  ///
  /// 本插件不绑定任何后端协议。推荐的姿势是：你自己用任何方式拉到补丁元信息，
  /// 直接 `new PatchInfo(...)` 传给 [applyPatch]。只有在你愿意让后端按约定
  /// 协议返回时，才用这个方法省掉 HTTP 样板。
  ///
  /// 约定响应（有更新）：
  /// ```json
  /// {
  ///   "hasUpdate": true,
  ///   "patch": {
  ///     "version": "1.0.1-h1",
  ///     "patchUrl": "https://.../libapp.so",
  ///     "md5": "<32 hex>",
  ///     "targetVersionCode": 100,
  ///     "signature": "<base64 ed25519 sig of md5 hex>",
  ///     "mode": "full",
  ///     "targetMd5": ""
  ///   }
  /// }
  /// ```
  /// 无更新：`{"hasUpdate": false}`。
  static Future<PatchCheckResult> checkUpdate(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_notAndroidGuard('checkUpdate')) {
      return PatchCheckResult.none();
    }

    final uri = Uri.parse(url);
    final client = HttpClient();
    client.connectionTimeout = timeout;
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      headers?.forEach(req.headers.set);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw PatcherException('HTTP ${resp.statusCode}');
      }
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw PatcherException('Invalid JSON: expected object');
      }
      return PatchCheckResult.fromJson(Map<String, dynamic>.from(decoded));
    } on PatcherException {
      rethrow;
    } catch (e, s) {
      _log('checkUpdate failed: $e', s);
      throw PatcherException(e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// 下载并安装指定补丁。
  ///
  /// 全流程（Android 原生侧实现）：
  /// 1. HTTP 下载到临时文件（指数退避重试）
  /// 2. MD5 校验
  /// 3. Ed25519 签名校验（[PatchInfo.signature] 非空且配置了公钥时）
  /// 4. 如果 [PatchInfo.mode] = bsdiff → 从 APK 提取基础 libapp.so，与下载的
  ///    差分文件合成新 .so，比对 [PatchInfo.targetMd5]
  /// 5. 原子 rename 到补丁目录
  /// 6. 写入 meta.json，标记「下次冷启动生效」
  ///
  /// 返回 [PatchApplyResult]：`ok=true` 表示补丁已就绪；否则 [PatchApplyResult.error]
  /// 给出失败分类，见 [PatchApplyError]。本次调用 **不会** 立即切换运行时的
  /// libapp.so —— 必须冷启动才能生效。
  ///
  /// 幂等：传入已安装过的相同 [PatchInfo.version] 会直接返回 `ok=true`，不会重复下载。
  ///
  /// [onProgress] 是 [applyProgress] 的便捷形态：传入回调后内部自动订阅广播流，
  /// 完成时自动取消。需要细粒度生命周期控制（比如多次复用同一订阅）的高级
  /// 场景仍可直接用 [applyProgress]，两者可共存。
  static Future<PatchApplyResult> applyPatch(
    PatchInfo patchInfo, {
    void Function(PatchApplyProgress)? onProgress,
  }) async {
    if (_notAndroidGuard('applyPatch')) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'not supported on ${Platform.operatingSystem}',
      );
    }
    StreamSubscription<PatchApplyProgress>? sub;
    if (onProgress != null) {
      sub = applyProgress.listen(onProgress);
    }
    try {
      final native = await PatcherChannel.applyPatch(patchInfo.toJson());
      return PatchApplyResult.fromNative(native);
    } catch (e, s) {
      _log('applyPatch failed: $e', s);
      return PatchApplyResult.failure(PatchApplyError.unknown, e.toString());
    } finally {
      await sub?.cancel();
    }
  }

  static String? _cachedStagingDir;

  /// In-memory bytes 形态的便捷入口，省去用户侧 staging + path_provider + crypto。
  ///
  /// 适用场景：
  /// - 从 asset 读出来的预置补丁（rootBundle.load）
  /// - 自定义网络栈 / isolate 拿到的字节流
  /// - 任何"已经把 .so 抓到 Uint8List"的情况
  ///
  /// 内部流程：
  /// 1. 写到原生 cacheDir 的临时文件（避免 MethodChannel 传 MB 级字节数组撞 Binder 限制）
  /// 2. 自动算 md5（用户无需引 crypto 包）
  /// 3. 复用 [applyPatch] 主流程（file:// → 校验 → 落盘）
  /// 4. 不论成败都清理 staging 文件
  ///
  /// HTTP / 服务端下发协议场景仍用 [applyPatch] + [PatchInfo]。
  ///
  /// [signature] 可选：Ed25519 签名（base64）。空字符串跳过签名校验。
  /// [targetVersionCode] 可选：不传则原生侧自动绑定到当前 APK versionCode。
  static Future<PatchApplyResult> applyPatchBytes(
    Uint8List bytes, {
    required String version,
    String signature = '',
    int? targetVersionCode,
    void Function(PatchApplyProgress)? onProgress,
  }) async {
    if (_notAndroidGuard('applyPatchBytes')) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'not supported on ${Platform.operatingSystem}',
      );
    }
    final dir = _cachedStagingDir ??= (await PatcherChannel.cacheDir()) ?? '';
    if (dir.isEmpty) {
      return PatchApplyResult.failure(
        PatchApplyError.ioError,
        'native cacheDir unavailable',
      );
    }
    final staged = File(
      '$dir/flutter_patcher_staged_${DateTime.now().microsecondsSinceEpoch}.so',
    );
    try {
      await staged.writeAsBytes(bytes, flush: true);
      final md5Hex = crypto.md5.convert(bytes).toString();
      return await applyPatch(
        PatchInfo(
          version: version,
          patchUrl: 'file://${staged.path}',
          md5: md5Hex,
          signature: signature,
          targetVersionCode: targetVersionCode,
        ),
        onProgress: onProgress,
      );
    } catch (e, s) {
      _log('applyPatchBytes failed: $e', s);
      return PatchApplyResult.failure(PatchApplyError.unknown, e.toString());
    } finally {
      try {
        if (await staged.exists()) await staged.delete();
      } catch (_) {
        // staging 文件清理失败不阻塞主流程；下次 staging 用新时间戳避免冲突。
      }
    }
  }

  /// 手动回滚：删除补丁文件 + 重置 meta。下次冷启动回到 APK 内置版本。
  static Future<void> rollback() async {
    if (_notAndroidGuard('rollback')) return;
    try {
      await PatcherChannel.rollback();
    } catch (e, s) {
      _log('rollback failed: $e', s);
    }
  }

  /// 当前宿主 APK 的 versionCode（API 28+ 用 longVersionCode）。
  ///
  /// 用途：组装 [PatchInfo.targetVersionCode] 时不必让用户去引 `package_info_plus`。
  /// - 同 versionCode 场景（最常见）：完全可以不传 targetVersionCode，原生侧
  ///   会在 `applyPatch` 当下自动绑定到这个值
  /// - 跨 versionCode 场景（你想让某补丁绑定到尚未发布的 APK）：用本 getter
  ///   读出当前值后做差量，自己拼 [PatchInfo]
  ///
  /// 失败 / 非 Android 平台返回 null。
  static Future<int?> get appVersionCode async {
    if (_notAndroidGuard('appVersionCode')) return null;
    try {
      return await PatcherChannel.appVersionCode();
    } catch (_) {
      return null;
    }
  }

  /// 当前已生效/已就绪的补丁版本号，无补丁返回 null。
  static Future<String?> get currentVersion async {
    if (_notAndroidGuard('currentVersion')) return null;
    try {
      final v = await PatcherChannel.currentVersion();
      if (v == null || v.isEmpty) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// 已知"装上就出事"的补丁本地黑名单（按入黑时间从旧到新排序）。
  ///
  /// 自动入黑名单的触发条件：
  /// - 补丁加载后启动失败到达 [maxCrashCount]（默认 1，fail-fast）
  /// - 本地 .so 的 md5 校验失败（文件损坏 / 篡改）
  /// - Ed25519 签名校验失败（可能被篡改 / 严格模式 API < 33）
  ///
  /// 命中黑名单的 (version, md5)：
  /// - 再次调用 [applyPatch] / [applyPatchBytes] 直接返回 [PatchApplyError.blacklisted]
  /// - 即使服务端持续下发同一份，客户端也不下载，连流量都不浪费
  /// - 黑名单跨 APK 升级保留，仅 [clearBlacklist] / `pm clear` 可清空
  ///
  /// 业务侧通常用法：将本列表上报到监控，结合 [PatchBootDiagnostic] 一并定位。
  ///
  /// 非 Android 平台 / 失败时返回空列表。
  static Future<List<BlacklistEntry>> get blacklist async {
    if (_notAndroidGuard('blacklist')) return const [];
    try {
      final raw = await PatcherChannel.blacklist();
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((m) => BlacklistEntry.fromNative(m))
          .toList(growable: false);
    } catch (e, s) {
      _log('blacklist failed: $e', s);
      return const [];
    }
  }

  /// 清空整个黑名单。**慎用**：通常只在以下场景调用：
  /// - 单元测试 / 真机调试时希望让某 (version, md5) 重新可装
  /// - 业务上线后确认服务端已修复，给设备一次"再试一次"的机会
  ///
  /// 不接受按条目精准移除：黑名单条目数量上限 50（见 [BlacklistStore.MAX_ENTRIES]），
  /// 全量清空成本极低；按条移除反而易给上层"我能选择性放行某个有问题补丁"的错觉。
  static Future<void> clearBlacklist() async {
    if (_notAndroidGuard('clearBlacklist')) return;
    try {
      await PatcherChannel.clearBlacklist();
    } catch (e, s) {
      _log('clearBlacklist failed: $e', s);
    }
  }

  /// 上次冷启动时补丁的加载诊断结果。
  ///
  /// `applyPatch` 返回的 [PatchApplyResult] 只覆盖"装的时候"失败。补丁装上之后，
  /// 下次冷启动可能因 versionCode 不匹配、签名失败、熔断器触发、反射注入失败
  /// 等原因被原生侧丢弃 —— 这些事件原本仅写 logcat，业务侧拿不到。本 API 把
  /// 这些事件结构化暴露给 Dart，用于监控上报和用户提示。
  ///
  /// - 返回 `null`：宿主从未冷启动经过本插件（首次安装 / `pm clear` 后）
  /// - 返回 [PatchBootDiagnostic]：本字段在每次冷启动 attachBaseContext 时被原生侧
  ///   覆写。Dart 业务可在 [init] 之后立即查询，反映的是**上次**冷启动结果，
  ///   而非本次。
  ///
  /// ```dart
  /// final diag = await FlutterPatcher.lastBootDiagnostic;
  /// if (diag != null && !diag.isHealthy) {
  ///   analytics.report('patch_dropped', {
  ///     'status': diag.status.name,
  ///     'patch_version': diag.patchVersion,
  ///     'patch_vc': diag.patchTargetVersionCode,
  ///     'app_vc': diag.appVersionCode,
  ///     'crash_count': diag.crashCount,
  ///   });
  /// }
  /// ```
  static Future<PatchBootDiagnostic?> get lastBootDiagnostic async {
    if (_notAndroidGuard('lastBootDiagnostic')) return null;
    try {
      final raw = await PatcherChannel.lastBootDiagnostic();
      if (raw == null) return null;
      return PatchBootDiagnostic.fromNative(raw);
    } catch (e, s) {
      _log('lastBootDiagnostic failed: $e', s);
      return null;
    }
  }

  // ==================== 内部 ====================

  /// [_BootVerifier] 用：覆盖默认 5 秒，由 [init] 写入。
  static Duration _verifyAfter = const Duration(seconds: 5);

  /// 装 PlatformDispatcher.onError + FlutterError.onError 双钩子，把"未 verified
  /// 窗口内"的 Dart 未捕获异常上报给原生熔断器（语义等同于 ApplicationExitInfo
  /// REASON_CRASH，弥补 framework 把异常吞掉、进程不死的检测盲区）。
  ///
  /// 钩子在 [_bootReported]（即 _BootVerifier verified）之前一次性生效，verified
  /// 之后回退到调用前的原 handler，业务异常照常走宿主自有的错误处理。
  static void _installBootErrorCatchers() {
    final priorPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _maybeReportBootError(error, stack);
      // 还回原 handler；没有就按 Flutter 默认未处理（false → 让 framework 走默认 print）
      return priorPlatformHandler?.call(error, stack) ?? false;
    };

    final priorFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _maybeReportBootError(details.exception, details.stack);
      // framework 错误：交回原 handler（默认会把红屏 / dump stack）
      (priorFlutterHandler ?? FlutterError.presentError).call(details);
    };
  }

  /// "未 verified 窗口"内一次性上报。verified 之后或已上报过都直接 no-op。
  static void _maybeReportBootError(Object error, StackTrace? stack) {
    if (_bootReported) return;
    if (_bootErrorReported) return;
    _bootErrorReported = true;
    final msg = error.toString();
    _log('boot-phase Dart error captured: $msg', stack);
    PatcherChannel.reportDartBootError(msg).catchError((e) {
      _log('reportDartBootError channel call failed: $e');
    });
  }

  static void _log(String msg, [StackTrace? stack]) {
    if (kDebugMode) {
      debugPrint('[FlutterPatcher] $msg');
    }
  }
}

/// Plugin-wide exception. Wraps network/parsing errors from [FlutterPatcher.checkUpdate].
class PatcherException implements Exception {
  final String message;
  PatcherException(this.message);
  @override
  String toString() => 'PatcherException: $message';
}

/// 三层 boot 成功判定：Engine 加载 + 首帧渲染 + 前台连续存活 [FlutterPatcher._verifyAfter]。
///
/// # 为什么三层都要
/// 仅"首帧渲染"作为 verified 依据，会漏掉"首屏点一下立刻 crash"的场景 ——
/// 那种 crash 之前已 markBootSuccess，下次冷启动 patch_loading=false，熔断不会
/// 触发，用户陷入"装着坏补丁的 app 持续 crash"的循环。
///
/// 三层判定全过才算真 verified：
/// 1. Engine 加载成功（reflection 替换 + libapp.so dlopen） — 由 LoaderHook 保证
/// 2. 首帧渲染完成（[WidgetsBinding.addPostFrameCallback] 第一次回调）
/// 3. App 在 [AppLifecycleState.resumed] 状态连续存活 N 秒不 crash
///
/// 只在 resumed 时累计：避免用户启动后立刻 home 出去，Dart isolate 被挂起期间
/// 的"无 crash"被错误计入存活时间。
class _BootVerifier with WidgetsBindingObserver {
  static _BootVerifier? _instance;

  Duration _foregroundElapsed = Duration.zero;
  DateTime? _resumedAt;
  Timer? _timer;
  bool _verified = false;

  /// 等首帧后启动 verifier。多次调用幂等。
  static void start() {
    if (_instance != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _instance ??= _BootVerifier().._begin();
    });
  }

  void _begin() {
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    // 首帧渲染时通常已在 resumed；保险起见显式判一下当前 state
    final state = binding.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      _resumedAt = DateTime.now();
      _scheduleCheck();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_verified) return;
    if (state == AppLifecycleState.resumed) {
      _resumedAt = DateTime.now();
      _scheduleCheck();
    } else {
      // 进后台 → 冻结已累计的前台时间，停掉计时器
      if (_resumedAt != null) {
        _foregroundElapsed += DateTime.now().difference(_resumedAt!);
        _resumedAt = null;
      }
      _timer?.cancel();
    }
  }

  void _scheduleCheck() {
    final remaining = FlutterPatcher._verifyAfter - _foregroundElapsed;
    _timer?.cancel();
    if (remaining <= Duration.zero) {
      _markVerified();
      return;
    }
    _timer = Timer(remaining, _markVerified);
  }

  void _markVerified() {
    if (_verified) return;
    _verified = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    FlutterPatcher.reportBootSuccess();
  }
}
