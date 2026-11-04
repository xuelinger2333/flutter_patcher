import 'package:flutter/foundation.dart';

/// 本地补丁黑名单条目，与原生侧 `CandidateStore.blacklist()` 返回的结构一一对应。
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
  /// 入黑补丁的标识：`<宿主指纹>:<补丁序号>:<补丁 SHA-256>`。
  final String version;

  /// 入黑原因（原生常量，跨边界用字符串而非 enum 保留前向兼容）。
  /// 当前只有 `BOOT_CRASH`：启动失败次数达到 `maxCrashCount`，触发熔断。
  final String reason;

  /// 入黑时间。
  final DateTime blacklistedAt;

  const BlacklistEntry({
    required this.version,
    required this.reason,
    required this.blacklistedAt,
  });

  factory BlacklistEntry.fromNative(Map<dynamic, dynamic> raw) {
    final map = Map<String, dynamic>.from(raw);
    return BlacklistEntry(
      version: (map['version'] as String?) ?? '',
      reason: (map['reason'] as String?) ?? '',
      blacklistedAt: DateTime.fromMillisecondsSinceEpoch(
        ((map['blacklistedAt'] as num?) ?? 0).toInt(),
      ),
    );
  }

  @override
  String toString() =>
      'BlacklistEntry(version=$version, reason=$reason, at=$blacklistedAt)';
}
