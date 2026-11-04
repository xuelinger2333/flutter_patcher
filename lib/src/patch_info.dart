/// An available update, as returned by `FlutterPatcher.checkUpdate`.
///
/// Pass it unchanged to `FlutterPatcher.applyPatch`: it carries the signed
/// manifest that native code authenticates. A hand-built [PatchInfo] has no
/// manifest and is rejected.
class PatchInfo {
  /// Patch sequence of the publication, or `withdraw`.
  final String version;

  /// Update-check data; `signed_manifest` holds the exact signed wire.
  final Map<String, dynamic> raw;

  const PatchInfo({required this.version, this.raw = const {}});

  @override
  String toString() => 'PatchInfo(version=$version)';
}

/// Stages emitted while applying a patch.
enum PatchApplyPhase {
  /// Payload download. [PatchApplyProgress.bytesReceived] and
  /// [PatchApplyProgress.totalBytes] are meaningful in this phase.
  downloading,

  /// Payload SHA-256 and signature verification.
  verifying,

  /// Package parsing, asset installation, and transaction commit.
  finalizing,
}

PatchApplyPhase _parsePhase(String? s) {
  switch (s) {
    case 'downloading':
      return PatchApplyPhase.downloading;
    case 'verifying':
      return PatchApplyPhase.verifying;
    case 'finalizing':
      return PatchApplyPhase.finalizing;
    default:
      return PatchApplyPhase.downloading;
  }
}

/// Progress event emitted by `FlutterPatcher.applyProgress`.
class PatchApplyProgress {
  final PatchApplyPhase phase;

  /// Meaningful only when [phase] is [PatchApplyPhase.downloading].
  final int bytesReceived;

  /// The signed patch size. Meaningful only when [phase] is
  /// [PatchApplyPhase.downloading].
  final int totalBytes;

  const PatchApplyProgress({
    required this.phase,
    this.bytesReceived = 0,
    this.totalBytes = 0,
  });

  /// Download progress from 0.0 to 1.0, or null when unknown/not downloading.
  double? get fraction {
    if (phase != PatchApplyPhase.downloading) return null;
    if (totalBytes <= 0) return null;
    return (bytesReceived / totalBytes).clamp(0.0, 1.0).toDouble();
  }

  factory PatchApplyProgress.fromNative(Object? native) {
    if (native is! Map) {
      return const PatchApplyProgress(phase: PatchApplyPhase.downloading);
    }
    final map = Map<String, dynamic>.from(native);
    return PatchApplyProgress(
      phase: _parsePhase(map['phase'] as String?),
      bytesReceived: (map['received'] as num?)?.toInt() ?? 0,
      totalBytes: (map['total'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() {
    if (phase != PatchApplyPhase.downloading) {
      return 'PatchApplyProgress(${phase.name})';
    }
    final f = fraction;
    final pct = f != null ? '${(f * 100).toStringAsFixed(1)}%' : '?';
    return 'PatchApplyProgress(downloading, $bytesReceived/$totalBytes, $pct)';
  }
}

/// Classified failure reason for `FlutterPatcher.applyPatch`.
enum PatchApplyError {
  /// Not a [PatchInfo] from `checkUpdate`, a patch whose sequence or hash
  /// differs from its manifest, or a sequence this device already installed.
  invalidArgs,

  /// The payload is in the local bad-patch blacklist after a failed start.
  blacklisted,

  /// The payload download failed; retrying later may succeed.
  network,

  /// The patch envelope signature did not verify with the host policy key.
  signatureInvalid,

  /// Filesystem, disk space, copy, fsync, or rename failure.
  ioError,

  /// Unclassified native/channel error.
  unknown,
}

PatchApplyError _parseApplyError(String? code) {
  switch (code) {
    case 'INVALID_ARGS':
      return PatchApplyError.invalidArgs;
    case 'BLACKLISTED':
      return PatchApplyError.blacklisted;
    case 'NETWORK':
      return PatchApplyError.network;
    case 'SIGNATURE_INVALID':
      return PatchApplyError.signatureInvalid;
    case 'IO_ERROR':
      return PatchApplyError.ioError;
    default:
      return PatchApplyError.unknown;
  }
}

/// Structured result returned by `FlutterPatcher.applyPatch`.
class PatchApplyResult {
  /// Whether the patch was installed successfully.
  ///
  /// Reapplying the same already-installed patch is also considered success.
  final bool ok;

  /// Failure category. Null when [ok] is true.
  final PatchApplyError? error;

  /// Developer-facing failure description. Do not show directly to users.
  final String? message;

  const PatchApplyResult._({required this.ok, this.error, this.message});

  factory PatchApplyResult.success() => const PatchApplyResult._(ok: true);

  factory PatchApplyResult.failure(PatchApplyError error, [String? message]) =>
      PatchApplyResult._(ok: false, error: error, message: message);

  /// Deserializes the native MethodChannel result.
  factory PatchApplyResult.fromNative(Object? native) {
    if (native is! Map) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'invalid native result: $native',
      );
    }
    final map = Map<String, dynamic>.from(native);
    if (map['ok'] == true) return PatchApplyResult.success();
    return PatchApplyResult.failure(
      _parseApplyError(map['error'] as String?),
      map['message'] as String?,
    );
  }

  @override
  String toString() => ok
      ? 'PatchApplyResult(ok)'
      : 'PatchApplyResult(error=${error?.name}, message=$message)';
}

/// Result returned by `FlutterPatcher.checkUpdate`.
class PatchCheckResult {
  /// Whether there is an update to apply: a new patch or a withdrawal.
  final bool hasUpdate;

  /// Patch metadata. Null when [hasUpdate] is false.
  final PatchInfo? patch;

  const PatchCheckResult({required this.hasUpdate, this.patch});

  factory PatchCheckResult.none() =>
      const PatchCheckResult(hasUpdate: false, patch: null);
}
