/// Minimum metadata needed to install a patch.
///
/// `PatchInfo` is intentionally backend-agnostic. Your update data can come
/// from HTTP JSON, gRPC, remote config, or hard-coded test data; as long as you
/// can provide these fields, the patch can be passed to
/// `FlutterPatcher.applyPatch`.
class PatchInfo {
  /// Patch identifier, for example `1.0.1-h1`.
  final String version;

  /// Patch payload URL.
  ///
  /// For a lib-only patch this points to `libapp.so`. For an asset patch this
  /// points to `patch.zip`.
  final String patchUrl;

  /// `bytecode` installs a signed FPTC envelope; null preserves legacy behavior.
  final String? strategy;
  final String? sha256;
  final String? fingerprint;
  final int? patchSeq;

  /// MD5 of the patch payload, lower-case hex.
  ///
  /// For a lib-only patch this is the MD5 of `libapp.so`. For an asset patch
  /// this is the MD5 of `patch.zip`. An empty string skips payload MD5
  /// verification and also skips signature verification.
  final String md5;

  /// Base64 Ed25519 signature over the [md5] hex string.
  ///
  /// Empty disables signature verification. When [md5] is empty this field is
  /// ignored because there is no signed message.
  final String signature;

  /// Host APK `versionCode` this patch targets.
  ///
  /// On cold start, a patch whose target versionCode no longer matches the
  /// installed APK is dropped automatically. If null, native code binds the
  /// patch to the current app versionCode during `applyPatch`.
  final int? targetVersionCode;

  /// Original JSON fields preserved by [PatchInfo.fromJson].
  ///
  /// Direct construction does not use this field.
  final Map<String, dynamic> raw;

  const PatchInfo({
    required this.version,
    required this.patchUrl,
    this.strategy,
    this.sha256,
    this.fingerprint,
    this.patchSeq,
    this.md5 = '',
    this.signature = '',
    this.targetVersionCode,
    this.raw = const {},
  });

  /// Parses the minimal built-in check-update protocol.
  ///
  /// If your server response has a different shape, construct [PatchInfo]
  /// directly. Compatible field names:
  ///
  /// - `patchUrl` / `patch_url`
  /// - `targetVersionCode` / `target_version_code`
  factory PatchInfo.fromJson(Map<String, dynamic> json) {
    final rawVc = json['targetVersionCode'] ?? json['target_version_code'];
    final int? parsedVc = rawVc is num
        ? rawVc.toInt()
        : (rawVc is String && rawVc.isNotEmpty ? int.tryParse(rawVc) : null);
    return PatchInfo(
      version: (json['version'] ?? '') as String,
      patchUrl: (json['patchUrl'] ?? json['patch_url'] ?? '') as String,
      strategy: json['strategy'] as String?,
      sha256: json['sha256'] as String?,
      fingerprint: json['fingerprint'] as String?,
      patchSeq: json['patch_seq'] as int?,
      md5: (json['md5'] ?? '') as String,
      signature: (json['signature'] ?? '') as String,
      targetVersionCode: parsedVc,
      raw: Map<String, dynamic>.from(json),
    );
  }

  /// Serializes this patch for the native MethodChannel call.
  Map<String, dynamic> toJson() => {
        'version': version,
        'patchUrl': patchUrl,
        if (strategy != null) 'strategy': strategy,
        if (sha256 != null) 'sha256': sha256,
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (patchSeq != null) 'patch_seq': patchSeq,
        if (md5.isNotEmpty) 'md5': md5,
        'signature': signature,
        if (targetVersionCode != null) 'targetVersionCode': targetVersionCode,
      };

  @override
  String toString() => 'PatchInfo('
      'version=$version, url=$patchUrl, '
      'md5=${md5.isEmpty ? 'none' : md5}, '
      'sig=${signature.isEmpty ? 'none' : '***'})';
}

/// Stages emitted while applying a patch.
enum PatchApplyPhase {
  /// Payload download. [PatchApplyProgress.bytesReceived] and
  /// [PatchApplyProgress.totalBytes] are meaningful in this phase.
  downloading,

  /// Payload MD5 / signature verification.
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

  /// Meaningful only when [phase] is [PatchApplyPhase.downloading].
  ///
  /// `-1` means the server did not provide `Content-Length`.
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
  /// Missing version/URL, invalid MD5 format, unsupported mode, or target
  /// version mismatch.
  invalidArgs,

  /// The same `(version, md5)` payload is in the local bad-patch blacklist.
  blacklisted,

  /// Download failed after retries.
  network,

  /// Payload, lib, or overlay asset MD5 did not match expected metadata.
  md5Mismatch,

  /// Ed25519 verification failed, or strict mode rejected a signed patch on an
  /// Android version below the API 33 signature-policy minimum.
  signatureInvalid,

  /// The patch package has no `libapp.so` for the current device ABI.
  unsupportedAbi,

  /// Invalid asset package: bad zip/schema/manifest, unsafe path, missing asset
  /// entry, or unsupported asset mode/op.
  assetPackageInvalid,

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
    case 'MD5_MISMATCH':
      return PatchApplyError.md5Mismatch;
    case 'SIGNATURE_INVALID':
      return PatchApplyError.signatureInvalid;
    case 'UNSUPPORTED_ABI':
      return PatchApplyError.unsupportedAbi;
    case 'ASSET_PACKAGE_INVALID':
      return PatchApplyError.assetPackageInvalid;
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
  /// Whether a new patch is available.
  final bool hasUpdate;

  /// Patch metadata. Null when [hasUpdate] is false.
  final PatchInfo? patch;

  const PatchCheckResult({required this.hasUpdate, this.patch});

  factory PatchCheckResult.none() =>
      const PatchCheckResult(hasUpdate: false, patch: null);

  factory PatchCheckResult.fromJson(Map<String, dynamic> json) {
    final hasUpdate = json['hasUpdate'] == true || json['has_update'] == true;
    if (!hasUpdate) return PatchCheckResult.none();
    final patchJson = json['patch'];
    final patchMap = patchJson is Map ? patchJson : json;
    return PatchCheckResult(
      hasUpdate: true,
      patch: PatchInfo.fromJson(Map<String, dynamic>.from(patchMap)),
    );
  }
}
