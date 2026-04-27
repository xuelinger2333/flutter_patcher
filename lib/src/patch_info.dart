/// 补丁打包方式。
enum PatchMode {
  /// 全量 libapp.so 下载，直接替换。
  full,

  /// 差分包，需要在端侧与基础 libapp.so 合成。要求插件开启 native bsdiff
  /// 模块（见 README 的 bsdiff 集成指南）。
  bsdiff,
}

PatchMode _parseMode(Object? raw) {
  final s = (raw is String ? raw : '').toLowerCase();
  if (s == 'bsdiff' || s == 'diff' || s == 'delta') return PatchMode.bsdiff;
  return PatchMode.full;
}

/// 补丁元信息 —— 插件真正需要的最小字段集。
///
/// 这是一个纯值对象，**不绑定任何后端协议**。无论你的更新来源是 HTTP JSON、
/// gRPC、Firebase Remote Config、甚至硬编码常量，只要能拼出这几个字段就可以
/// 交给 [FlutterPatcher.applyPatch]。
///
/// ## 必填
/// - [version]：任意字符串，客户端用来判等（已是当前版本则跳过）
/// - [patchUrl]：补丁文件 HTTPS 下载地址
/// - [md5]：补丁文件本身的 MD5（**小写 hex**，32 字符）
///
/// ## 强烈推荐
/// - [targetVersionCode]：补丁针对的宿主 APK versionCode；保证 APK 升级后旧补丁
///   自动失效
///
/// ## 可选
/// - [signature]：Ed25519 签名，见 README
/// - [mode] / [targetMd5]：bsdiff 差分模式相关
class PatchInfo {
  /// 补丁版本号，例如 "1.0.1-h1"。
  final String version;

  /// 补丁文件下载地址（HTTP/HTTPS）。
  /// - mode=full   → 完整 libapp.so
  /// - mode=bsdiff → bsdiff 差分文件
  final String patchUrl;

  /// 补丁文件本身的 MD5（小写 hex）。用于下载完整性校验。
  /// 对 bsdiff 模式，这是 **差分文件** 的 MD5，不是合成后 .so 的 MD5。
  final String md5;

  /// 对 MD5 hex 做 Ed25519 签名后 Base64 编码的字符串。
  /// 空字符串表示不做签名校验，仅依赖 MD5 + 传输层安全。
  final String signature;

  /// 补丁构建时绑定的宿主 APK `versionCode`（Android 的 `PackageInfo.versionCode` /
  /// `longVersionCode`）。用于 **启动时强校验**：宿主 APK 升级后旧补丁会在下次
  /// 冷启动被自动丢弃，避免加载与当前引擎/Dart kernel 不匹配的 .so 导致崩溃。
  ///
  /// - 推荐显式填写（该补丁针对的 APK versionCode）
  /// - 为 null 时，原生侧会在 `applyPatch` 当下抓取当时的宿主 APK versionCode 写入
  ///   meta，作为兜底；宿主升级后一样会被识别为 mismatch
  final int? targetVersionCode;

  /// 补丁模式，默认 [PatchMode.full]。
  final PatchMode mode;

  /// bsdiff 模式下，**合成后** libapp.so 的预期 MD5。
  /// full 模式可留空。
  final String targetMd5;

  /// 原始 JSON，保留未来扩展字段（如果你是用 [PatchInfo.fromJson] 构造的）。
  /// 直接构造不会用到。
  final Map<String, dynamic> raw;

  const PatchInfo({
    required this.version,
    required this.patchUrl,
    required this.md5,
    this.signature = '',
    this.targetVersionCode,
    this.mode = PatchMode.full,
    this.targetMd5 = '',
    this.raw = const {},
  });

  /// 便捷工厂：用内置 [FlutterPatcher.checkUpdate] 默认协议解析 JSON。
  ///
  /// 自己拉取的 JSON 结构不一样？**直接用构造函数就行**，不必走这里。
  ///
  /// 兼容的字段名：
  /// - `patchUrl` / `patch_url`
  /// - `targetVersionCode` / `target_version_code`
  /// - `targetMd5` / `target_md5`
  /// - `mode` / `patchMode`
  ///
  /// 未识别的字段会被保留在 [raw] 里不影响解析。
  factory PatchInfo.fromJson(Map<String, dynamic> json) {
    final rawVc = json['targetVersionCode'] ?? json['target_version_code'];
    final int? parsedVc = rawVc is num
        ? rawVc.toInt()
        : (rawVc is String && rawVc.isNotEmpty ? int.tryParse(rawVc) : null);
    return PatchInfo(
      version: (json['version'] ?? '') as String,
      patchUrl: (json['patchUrl'] ?? json['patch_url'] ?? '') as String,
      md5: (json['md5'] ?? '') as String,
      signature: (json['signature'] ?? '') as String,
      targetVersionCode: parsedVc,
      mode: _parseMode(json['mode'] ?? json['patchMode']),
      targetMd5: (json['targetMd5'] ?? json['target_md5'] ?? '') as String,
      raw: Map<String, dynamic>.from(json),
    );
  }

  /// 序列化成传给原生侧 MethodChannel 的 Map。只含插件实际需要的字段。
  Map<String, dynamic> toJson() => {
        'version': version,
        'patchUrl': patchUrl,
        'md5': md5,
        'signature': signature,
        if (targetVersionCode != null) 'targetVersionCode': targetVersionCode,
        'mode': mode.name,
        'targetMd5': targetMd5,
      };

  @override
  String toString() => 'PatchInfo('
      'version=$version, mode=${mode.name}, url=$patchUrl, '
      'md5=$md5, sig=${signature.isEmpty ? 'none' : '***'})';
}

/// [FlutterPatcher.applyPatch] 的阶段。
enum PatchApplyPhase {
  /// 下载中。[PatchApplyProgress.bytesReceived] / [PatchApplyProgress.totalBytes] 有意义。
  downloading,

  /// 下载完成，正在做 MD5 + 签名校验。
  verifying,

  /// bsdiff 模式合成 .so 中（full 模式不会进入此阶段）。
  bsdiffMerging,

  /// 原子 rename + 写 meta.json。
  finalizing,
}

PatchApplyPhase _parsePhase(String? s) {
  switch (s) {
    case 'downloading':
      return PatchApplyPhase.downloading;
    case 'verifying':
      return PatchApplyPhase.verifying;
    case 'bsdiff_merging':
      return PatchApplyPhase.bsdiffMerging;
    case 'finalizing':
      return PatchApplyPhase.finalizing;
    default:
      return PatchApplyPhase.downloading;
  }
}

/// [FlutterPatcher.applyProgress] 发射的进度事件。
class PatchApplyProgress {
  final PatchApplyPhase phase;

  /// 仅 [phase] == [PatchApplyPhase.downloading] 时有意义。
  final int bytesReceived;

  /// 仅 [phase] == [PatchApplyPhase.downloading] 时有意义。服务端未发
  /// `Content-Length` 时为 `-1`。
  final int totalBytes;

  const PatchApplyProgress({
    required this.phase,
    this.bytesReceived = 0,
    this.totalBytes = 0,
  });

  /// 0.0 ~ 1.0 的下载进度。非下载阶段或 [totalBytes] 未知时返回 null。
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

/// [FlutterPatcher.applyPatch] 的失败原因分类。
///
/// 调用方可据此决定不同处理：是自动重试、告警服务端、还是提示用户。
enum PatchApplyError {
  /// 服务端下发的 JSON 缺 version / patchUrl / md5 等必填字段，或 bsdiff 模式没传 targetMd5。
  /// → 告警服务端，无法自动恢复。
  invalidArgs,

  /// (version, md5) 在本地黑名单中（曾导致启动崩溃 / md5 不匹配 / 签名不通过）。
  /// → **告警服务端立即下架该补丁**；不要自动重试。如需调试覆盖，调用
  /// [FlutterPatcher.clearBlacklist]。
  blacklisted,

  /// 服务端下发了 bsdiff 模式的补丁，但当前宿主未编译 bsdiff native 模块。
  /// → 告警服务端，针对此客户端切回 full 模式。
  bsdiffDisabled,

  /// 下载失败（重试 N 次后依然失败）。
  /// → 稍后重试，通常网络环境变化后自动恢复。
  network,

  /// 下载文件的 md5 与服务端下发的 md5 不匹配。
  /// → CDN 脏数据或服务端 md5 计算错误，检查后重试。
  md5Mismatch,

  /// Ed25519 签名验证失败，或 API < 33 且 strict 模式拒绝。
  /// → **可能被篡改**，不建议自动重试。
  signatureInvalid,

  /// native bsdiff 合成失败。通常是基础 libapp.so 与服务端预期不一致。
  /// → 检查 APK 版本和服务端差分生成逻辑。
  bsdiffApplyFailed,

  /// bsdiff 合成后的 .so md5 与 targetMd5 不符。同 [bsdiffApplyFailed] 的排查方向。
  targetMd5Mismatch,

  /// 磁盘 / 文件系统错误（磁盘满、权限、rename 失败）。
  /// → 稍后重试。
  ioError,

  /// 未被分类的异常 / 原生侧抛出的其他错误。
  /// → 上报到监控，看日志定位。
  unknown,
}

PatchApplyError _parseApplyError(String? code) {
  switch (code) {
    case 'INVALID_ARGS':
      return PatchApplyError.invalidArgs;
    case 'BLACKLISTED':
      return PatchApplyError.blacklisted;
    case 'BSDIFF_DISABLED':
      return PatchApplyError.bsdiffDisabled;
    case 'NETWORK':
      return PatchApplyError.network;
    case 'MD5_MISMATCH':
      return PatchApplyError.md5Mismatch;
    case 'SIGNATURE_INVALID':
      return PatchApplyError.signatureInvalid;
    case 'BSDIFF_APPLY_FAILED':
      return PatchApplyError.bsdiffApplyFailed;
    case 'TARGET_MD5_MISMATCH':
      return PatchApplyError.targetMd5Mismatch;
    case 'IO_ERROR':
      return PatchApplyError.ioError;
    default:
      return PatchApplyError.unknown;
  }
}

/// [FlutterPatcher.applyPatch] 的结构化返回值。
///
/// 用法：
/// ```dart
/// final r = await FlutterPatcher.applyPatch(info);
/// if (r.ok) {
///   // 补丁已就绪，下次冷启动生效
/// } else {
///   switch (r.error) {
///     case PatchApplyError.network: /* 稍后重试 */ break;
///     case PatchApplyError.signatureInvalid: /* 告警，不重试 */ break;
///     default: /* 记日志 */ break;
///   }
/// }
/// ```
class PatchApplyResult {
  /// 是否成功。已安装过相同 version 的补丁也算成功（幂等）。
  final bool ok;

  /// 失败原因分类。[ok] == true 时为 null。
  final PatchApplyError? error;

  /// 给开发者看的失败描述。可能为 null。不要直接展示给用户。
  final String? message;

  const PatchApplyResult._({required this.ok, this.error, this.message});

  factory PatchApplyResult.success() =>
      const PatchApplyResult._(ok: true);

  factory PatchApplyResult.failure(
    PatchApplyError error, [
    String? message,
  ]) =>
      PatchApplyResult._(ok: false, error: error, message: message);

  /// 从原生返回的 Map 反序列化。非预期结构一律归到 [PatchApplyError.unknown]。
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

/// [FlutterPatcher.checkUpdate] 的结果。
class PatchCheckResult {
  /// 是否有新补丁可用。
  final bool hasUpdate;

  /// 新补丁信息。`hasUpdate == false` 时为 null。
  final PatchInfo? patch;

  const PatchCheckResult({required this.hasUpdate, this.patch});

  factory PatchCheckResult.none() =>
      const PatchCheckResult(hasUpdate: false, patch: null);

  factory PatchCheckResult.fromJson(Map<String, dynamic> json) {
    final hasUpdate = json['hasUpdate'] == true;
    if (!hasUpdate) return PatchCheckResult.none();
    final patchJson = json['patch'];
    if (patchJson is! Map) return PatchCheckResult.none();
    return PatchCheckResult(
      hasUpdate: true,
      patch: PatchInfo.fromJson(Map<String, dynamic>.from(patchJson)),
    );
  }
}
