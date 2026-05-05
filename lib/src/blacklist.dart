import 'package:flutter/foundation.dart';

/// 本地补丁黑名单条目，与原生侧 `BlacklistStore` 的 JSON 结构一一对应。
///
/// 业务侧通常用法：
/// ```dart
/// final entries = await FlutterPatcher.blacklist;
/// for (final e in entries) {
///   debugPrint('blacklisted ${e.version} reason=${e.reason}');
/// }
/// ```
@immutable
class BlacklistEntry {
  /// 入黑补丁的 version（与 PatchInfo.version 对应）。
  final String version;

  /// 入黑补丁的 md5（小写 hex；bsdiff 模式下是差分文件 md5）。
  final String md5;

  /// 入黑原因分类（原生常量，跨边界用字符串而非 enum 保留前向兼容）。
  /// 当前可能值：
  /// - `BOOT_CRASH`：连续启动失败触发熔断
  /// - `MD5_MISMATCH`：本地文件 md5 校验失败
  /// - `SIGNATURE_INVALID`：Ed25519 签名校验失败
  final String reason;

  /// 入黑时间。
  final DateTime blacklistedAt;

  const BlacklistEntry({
    required this.version,
    required this.md5,
    required this.reason,
    required this.blacklistedAt,
  });

  factory BlacklistEntry.fromNative(Map<dynamic, dynamic> raw) {
    final map = Map<String, dynamic>.from(raw);
    return BlacklistEntry(
      version: (map['version'] as String?) ?? '',
      md5: (map['md5'] as String?) ?? '',
      reason: (map['reason'] as String?) ?? '',
      blacklistedAt: DateTime.fromMillisecondsSinceEpoch(
        ((map['blacklistedAt'] as num?) ?? 0).toInt(),
      ),
    );
  }

  @override
  String toString() =>
      'BlacklistEntry(version=$version, md5=$md5, reason=$reason, at=$blacklistedAt)';
}
