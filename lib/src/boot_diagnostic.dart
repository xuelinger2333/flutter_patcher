import 'package:flutter/foundation.dart';

/// Last cold-start patch loading decision.
///
/// Apply-time failures are reported by `PatchApplyError`. After a patch is
/// installed, the next cold start can still drop it because of version mismatch,
/// md5/signature failure, crash rollback, or loader hook failure. This enum
/// exposes those native decisions to Dart for monitoring.
enum PatchBootStatus {
  /// No local patch is installed or loaded.
  noPatch,

  /// This cold start loaded the patch.
  patched,

  /// The patch target versionCode does not match the installed APK.
  droppedVersionCodeMismatch,

  /// Cold-start validation found that local `libapp_patch.so` no longer
  /// matches metadata.
  droppedMd5Mismatch,

  /// Cold-start signature validation failed.
  droppedSignatureInvalid,

  /// Metadata or required patch artifacts are missing or corrupt on disk.
  ///
  /// For asset patches, the on-disk asset bundle the install step produced
  /// is missing or unreadable — typically caused by the patch directory
  /// being partially wiped between install and boot.
  droppedMetaCorrupted,

  /// Crash protection tripped after consecutive early boot failures.
  droppedCircuitBreaker,

  /// Loader injection failed; this launch used the APK built-in version.
  hookInstallFailed,

  /// The device cannot perform mandatory bytecode signature verification.
  bytecodeUnsupported,

  /// A bytecode startup failed but has not yet reached the crash threshold.
  bytecodeBootFailed,

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
    case 'DROPPED_MD5_MISMATCH':
      return PatchBootStatus.droppedMd5Mismatch;
    case 'DROPPED_SIGNATURE_INVALID':
      return PatchBootStatus.droppedSignatureInvalid;
    case 'DROPPED_META_CORRUPTED':
      return PatchBootStatus.droppedMetaCorrupted;
    case 'DROPPED_CIRCUIT_BREAKER':
      return PatchBootStatus.droppedCircuitBreaker;
    case 'HOOK_INSTALL_FAILED':
      return PatchBootStatus.hookInstallFailed;
    case 'BYTECODE_UNSUPPORTED':
      return PatchBootStatus.bytecodeUnsupported;
    case 'BYTECODE_BOOT_FAILED':
      return PatchBootStatus.bytecodeBootFailed;
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

  /// Current host APK versionCode.
  final int? appVersionCode;

  /// Crash count when the circuit breaker tripped.
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
  String toString() => 'PatchBootDiagnostic(${status.name}'
      '${patchVersion != null ? ', v=$patchVersion' : ''}'
      '${patchTargetVersionCode != null ? ', patchVc=$patchTargetVersionCode' : ''}'
      '${appVersionCode != null ? ', appVc=$appVersionCode' : ''}'
      '${crashCount != null ? ', crashes=$crashCount' : ''}'
      '${message != null ? ', msg=$message' : ''})';
}
