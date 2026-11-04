import 'package:flutter/foundation.dart';

/// Last cold-start patch loading decision.
///
/// Apply-time failures are reported by `PatchApplyError`. After a patch is
/// installed, the next cold start can still drop it because the app was
/// upgraded, its starts failed, or the loader hook did not install. This enum
/// exposes those native decisions to Dart for monitoring.
enum PatchBootStatus {
  /// No local patch is installed or loaded.
  noPatch,

  /// This cold start loaded the patch.
  patched,

  /// The installed app is not the build the patch was made for (it was
  /// upgraded), so the patch was dropped.
  droppedVersionCodeMismatch,

  /// Crash protection tripped after consecutive early boot failures.
  droppedCircuitBreaker,

  /// Loader injection failed; this launch used the APK built-in version.
  hookInstallFailed,

  /// A bytecode startup failed but has not yet reached the crash threshold.
  bytecodeBootFailed,

  /// An SO startup failed but has not yet reached the crash threshold.
  soBootFailed,

  /// Unclassified startup failure.
  unknown,
}

PatchBootStatus _parseStatus(String? raw) {
  switch (raw) {
    case 'NO_PATCH':
      return PatchBootStatus.noPatch;
    case 'PATCHED':
      return PatchBootStatus.patched;
    case 'DROPPED_VERSION_CODE_MISMATCH':
      return PatchBootStatus.droppedVersionCodeMismatch;
    case 'DROPPED_CIRCUIT_BREAKER':
      return PatchBootStatus.droppedCircuitBreaker;
    case 'HOOK_INSTALL_FAILED':
      return PatchBootStatus.hookInstallFailed;
    case 'BYTECODE_BOOT_FAILED':
      return PatchBootStatus.bytecodeBootFailed;
    case 'SO_BOOT_FAILED':
      return PatchBootStatus.soBootFailed;
    default:
      return PatchBootStatus.unknown;
  }
}

/// Structured diagnostic for the last cold-start patch decision.
@immutable
class PatchBootDiagnostic {
  /// Cold-start patch loading result.
  final PatchBootStatus status;

  /// Patch version involved in the decision.
  ///
  /// For dropped patches this is the dropped version when metadata is readable.
  final String? patchVersion;

  /// Patch target versionCode, mainly used for version mismatch diagnostics.
  final int? patchTargetVersionCode;

  /// The installed app's build number: Android versionCode, iOS CFBundleVersion.
  final int? appVersionCode;

  /// Failed starts counted for the patch, for a failed start or a tripped circuit breaker.
  final int? crashCount;

  /// FlutterInjector loader field candidates attempted when hook install failed.
  final List<String>? attemptedLoaderFields;

  /// Time when this diagnostic was recorded.
  final DateTime recordedAt;

  /// Developer-facing diagnostic message. Do not show directly to end users.
  final String? message;

  const PatchBootDiagnostic({
    required this.status,
    required this.recordedAt,
    this.patchVersion,
    this.patchTargetVersionCode,
    this.appVersionCode,
    this.crashCount,
    this.attemptedLoaderFields,
    this.message,
  });

  /// Whether the last boot state is normal for business monitoring.
  bool get isHealthy =>
      status == PatchBootStatus.patched || status == PatchBootStatus.noPatch;

  /// Deserializes the native MethodChannel map.
  factory PatchBootDiagnostic.fromNative(Map<dynamic, dynamic> raw) {
    final map = Map<String, dynamic>.from(raw);
    final fields = map['attemptedLoaderFields'];
    return PatchBootDiagnostic(
      status: _parseStatus(map['status'] as String?),
      patchVersion: map['patchVersion'] as String?,
      patchTargetVersionCode: (map['patchTargetVersionCode'] as num?)?.toInt(),
      appVersionCode: (map['appVersionCode'] as num?)?.toInt(),
      crashCount: (map['crashCount'] as num?)?.toInt(),
      attemptedLoaderFields: fields is List
          ? List<String>.from(fields.map((e) => e?.toString() ?? ''))
          : null,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(
        ((map['recordedAt'] as num?) ?? 0).toInt(),
      ),
      message: map['message'] as String?,
    );
  }

  @override
  String toString() =>
      'PatchBootDiagnostic(${status.name}'
      '${patchVersion != null ? ', v=$patchVersion' : ''}'
      '${patchTargetVersionCode != null ? ', patchVc=$patchTargetVersionCode' : ''}'
      '${appVersionCode != null ? ', appVc=$appVersionCode' : ''}'
      '${crashCount != null ? ', crashes=$crashCount' : ''}'
      '${message != null ? ', msg=$message' : ''})';
}
