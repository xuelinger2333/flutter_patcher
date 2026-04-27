import 'package:flutter/services.dart';

/// 与 Android 原生层通信的 MethodChannel 常量 + 薄封装。
class PatcherChannel {
  PatcherChannel._();

  static const MethodChannel channel = MethodChannel('flutter_patcher');

  /// 保存 Dart 侧配置到原生（SharedPreferences）。原生下次冷启动在
  /// Application.attachBaseContext 时读取这份配置做验签与加载。
  static Future<void> saveConfig({
    required String publicKeyBase64,
    required int maxCrashCount,
    required bool strictSignature,
    required List<String> loaderFieldCandidates,
    required bool loaderFallbackHeuristic,
  }) async {
    await channel.invokeMethod<void>('saveConfig', {
      'publicKeyBase64': publicKeyBase64,
      'maxCrashCount': maxCrashCount,
      'strictSignature': strictSignature,
      'loaderFieldCandidates': loaderFieldCandidates,
      'loaderFallbackHeuristic': loaderFallbackHeuristic,
    });
  }

  /// Dart init 最开头调用：标记「启动中」（与原生 attachBaseContext 的标记互相兜底）。
  static Future<void> markBooting() async {
    await channel.invokeMethod<void>('markBooting');
  }

  /// Dart 首帧完成 → 重置熔断计数。
  static Future<void> reportBootSuccess() async {
    await channel.invokeMethod<void>('reportBootSuccess');
  }

  /// 引导阶段 Dart 层未捕获异常上报。原生侧把它当成等同于 ApplicationExitInfo
  /// 的 REASON_CRASH 处理：crash_count += 1，达到阈值则熔断 + 删补丁 + 黑名单。
  ///
  /// 调用时机：仅在「未 verified」窗口（首帧 + verifyAfter 秒之前），由
  /// FlutterPatcher.init 安装的 PlatformDispatcher.onError / FlutterError.onError
  /// 钩子触发。verified 之后的业务异常不调本方法。
  static Future<void> reportDartBootError(String message) async {
    await channel.invokeMethod<void>('reportDartBootError', {
      'message': message,
    });
  }

  /// 下载 + 验签 + 落盘（原子替换）。成功后下次冷启动自动生效。
  ///
  /// 原生侧返回 `Map{ok, error, message}`，由调用方用
  /// `PatchApplyResult.fromNative` 反序列化。
  static Future<Object?> applyPatch(Map<String, dynamic> patch) async {
    return channel.invokeMethod<Object?>('applyPatch', patch);
  }

  /// 删除当前补丁 + 重置熔断标志位。
  static Future<void> rollback() async {
    await channel.invokeMethod<void>('rollback');
  }

  /// 当前已安装补丁版本（未安装返回 null / 空串）。
  static Future<String?> currentVersion() async {
    return channel.invokeMethod<String>('currentVersion');
  }

  /// 上次冷启动时补丁加载的诊断结果。
  ///
  /// 原生侧返回 `Map?`（详情见 BootDiagnosticStore），由调用方用
  /// `PatchBootDiagnostic.fromNative` 反序列化；`null` 表示从未 record 过。
  static Future<Map<dynamic, dynamic>?> lastBootDiagnostic() async {
    return channel.invokeMethod<Map<dynamic, dynamic>?>('lastBootDiagnostic');
  }

  /// 插件可写的缓存目录绝对路径，供 `applyPatchBytes` 内部 staging 用。
  /// 与现有 `PatchManager.patchDir` 隔离（一个是临时 staging，一个是终态补丁）。
  static Future<String?> cacheDir() async {
    return channel.invokeMethod<String>('cacheDir');
  }

  /// 当前宿主 APK 的 versionCode（API 28+ 用 longVersionCode）。
  /// 失败时原生侧返回 -1（INVALID_VERSION_CODE）。
  static Future<int?> appVersionCode() async {
    final v = await channel.invokeMethod<int>('appVersionCode');
    if (v == null || v < 0) return null;
    return v;
  }

  /// 已知"装上就出事"的补丁本地黑名单。原生侧返回 List<Map>，由调用方
  /// 用 `BlacklistEntry.fromNative` 反序列化。
  static Future<List<dynamic>?> blacklist() async {
    return channel.invokeMethod<List<dynamic>>('blacklist');
  }

  /// 清空黑名单。慎用：通常只在调试时调用。
  static Future<void> clearBlacklist() async {
    await channel.invokeMethod<void>('clearBlacklist');
  }
}
