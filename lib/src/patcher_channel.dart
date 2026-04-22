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
}
