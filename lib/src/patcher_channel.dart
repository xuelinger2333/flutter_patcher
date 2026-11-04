import 'package:flutter/services.dart';

/// 与原生层（Android / iOS）通信的 MethodChannel 常量 + 薄封装。
/// 方法、错误码和状态的契约见 test/contract/channel.json。
class PatcherChannel {
  PatcherChannel._();

  static const MethodChannel channel = MethodChannel('flutter_patcher');

  /// 保存 Dart 侧配置到原生（SharedPreferences），下次冷启动加载补丁时使用。
  /// 验签所需的信任材料只来自 APK 里的宿主策略。
  static Future<void> saveConfig({
    required int maxCrashCount,
    required List<String> loaderFieldCandidates,
    required bool loaderFallbackHeuristic,
  }) async {
    await channel.invokeMethod<void>('saveConfig', {
      'maxCrashCount': maxCrashCount,
      'loaderFieldCandidates': loaderFieldCandidates,
      'loaderFallbackHeuristic': loaderFallbackHeuristic,
    });
  }

  /// 引导阶段 Dart 层未捕获异常上报。原生侧把它当成一次启动失败：达到阈值则
  /// 熔断、回滚并拉黑当前补丁。
  ///
  /// 调用时机：仅在「verifyAfter 窗口内」（首帧渲染后到 verifyAfter 秒之间），
  /// 由 FlutterPatcher.init 安装的 PlatformDispatcher.onError / FlutterError.onError
  /// 钩子触发。窗口关闭后的业务异常不调本方法。
  static Future<void> reportDartBootError(String message) async {
    await channel.invokeMethod<void>('reportDartBootError', {
      'message': message,
    });
  }

  /// 删除当前补丁。
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

  /// 宿主构建号：Android versionCode（API 28+ 用 longVersionCode），iOS CFBundleVersion。
  /// 失败时原生侧返回 -1（INVALID_VERSION_CODE）。
  static Future<int?> appVersionCode() async {
    final v = await channel.invokeMethod<int>('appVersionCode');
    if (v == null || v < 0) return null;
    return v;
  }

  /// 当前设备首选 ABI，供服务端按 ABI 分发补丁。
  static Future<String?> deviceAbi() async {
    return channel.invokeMethod<String>('deviceAbi');
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
