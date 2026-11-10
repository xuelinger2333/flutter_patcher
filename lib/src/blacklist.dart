import 'package:flutter/foundation.dart';

/// A patch blacklisted on this device after its starts failed.
///
/// For example:
/// ```dart
/// final entries = await FlutterPatcher.blacklist;
/// for (final e in entries) {
///   debugPrint('blacklisted ${e.version} reason=${e.reason}');
/// }
/// ```
@immutable
class BlacklistEntry {
  /// The patch: `<host fingerprint>:<sequence>:<patch SHA-256>`.
  final String version;

  /// Why it was blacklisted, as a string so newer reasons stay readable.
  /// Currently always `BOOT_CRASH`: its starts failed `maxCrashCount` times,
  /// or its code threw after it started.
  final String reason;

  /// When it was blacklisted.
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
