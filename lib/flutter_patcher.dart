import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpHeaders, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show EventChannel;
import 'package:flutter/widgets.dart';

import 'src/patch_info.dart';
import 'src/patcher_channel.dart';

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
  /// - [maxCrashCount]   熔断器容忍的连续启动失败次数，默认 2。
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
  ///
  /// 约定：
  /// - 调用者应在 `main()` 里、`runApp()` 之前 `await` 本方法
  /// - 本方法 **不会** 重新加载 libapp.so —— 运行时切换发生在下次冷启动
  static Future<void> init({
    String publicKeyBase64 = '',
    int maxCrashCount = 2,
    bool strictSignature = true,
    List<String> loaderFieldCandidates = const ['flutterLoader'],
    bool loaderFallbackHeuristic = false,
  }) async {
    if (_notAndroidGuard('init')) return;
    if (_inited) return;
    _inited = true;

    // 1. 最开头标记「启动中」。与原生 attachBaseContext 内的标记互相兜底。
    //    如果 Dart init 之前就崩（原生阶段），原生标记生效；
    //    如果 runApp 之后但首帧前崩，Dart 标记生效。
    try {
      await PatcherChannel.markBooting();
    } catch (e, s) {
      _log('markBooting failed: $e', s);
    }

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

    // 3. 首帧后清熔断
    _scheduleBootSuccessReport();
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
  static Future<PatchApplyResult> applyPatch(PatchInfo patchInfo) async {
    if (_notAndroidGuard('applyPatch')) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'not supported on ${Platform.operatingSystem}',
      );
    }
    try {
      final native = await PatcherChannel.applyPatch(patchInfo.toJson());
      return PatchApplyResult.fromNative(native);
    } catch (e, s) {
      _log('applyPatch failed: $e', s);
      return PatchApplyResult.failure(PatchApplyError.unknown, e.toString());
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

  // ==================== 内部 ====================

  static void _scheduleBootSuccessReport() {
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      reportBootSuccess();
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
