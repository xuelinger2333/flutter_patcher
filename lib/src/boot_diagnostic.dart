import 'package:flutter/foundation.dart';

/// 上次冷启动时补丁的加载结果分类。
///
/// `applyPatch` 返回的 [PatchApplyError] 只覆盖"装的时候"失败。补丁装上之后，
/// 下次冷启动可能因 versionCode 不匹配、签名失败、熔断器触发、反射注入失败
/// 等原因被原生侧丢弃 —— 这些事件**仅写 logcat**，业务侧拿不到。
///
/// 本枚举与原生侧 [BootDiagnosticStore] 的字符串常量一一对应，结构化暴露给
/// Dart 业务做监控上报、用户提示。
enum PatchBootStatus {
  /// 当前未安装补丁，使用 APK 内置 libapp.so。属于正常状态。
  noPatch,

  /// 补丁加载成功，本次启动按补丁运行。
  patched,

  /// 补丁被丢弃：targetVersionCode 与当前 APK versionCode 不匹配。
  /// 典型原因：用户更新了 APK，旧补丁不再适用。**最常见**，通常无需告警。
  droppedVersionCodeMismatch,

  /// 补丁被丢弃：本地 .so 文件 md5 与 meta.effectiveMd5 不一致。
  /// 典型原因：磁盘损坏、外部进程篡改。
  droppedMd5Mismatch,

  /// 补丁被丢弃：Ed25519 签名校验失败 / 严格模式下 API < 33。
  /// **可能被篡改**，建议告警。
  droppedSignatureInvalid,

  /// 补丁被丢弃：meta.json 损坏或缺关键字段（effectiveMd5 等）。
  droppedMetaCorrupted,

  /// 补丁被丢弃：连续启动失败累计 >= maxCrashCount，熔断器触发。
  /// 典型原因：补丁本身有 bug 导致首帧前崩溃。**强告警**，应回滚版本定位崩溃。
  droppedCircuitBreaker,

  /// 补丁文件保留，但反射替换 FlutterLoader 失败，本次启动用了内置 .so。
  /// 典型原因：Flutter 大版本升级后字段名变更，需要传 loaderFieldCandidates。
  hookInstallFailed,

  /// attachPatcher 阶段抛出未分类异常。
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
    default:
      return PatchBootStatus.unknown;
  }
}

/// 上次冷启动补丁加载诊断的结构化结果。
///
/// 用法：
/// ```dart
/// final diag = await FlutterPatcher.lastBootDiagnostic;
/// if (diag != null && !diag.isHealthy) {
///   analytics.report('patch_dropped', {
///     'status': diag.status.name,
///     'patch_version': diag.patchVersion,
///     'patch_vc': diag.patchTargetVersionCode,
///     'app_vc': diag.appVersionCode,
///     'crash_count': diag.crashCount,
///   });
/// }
/// ```
@immutable
class PatchBootDiagnostic {
  /// 上次冷启动的加载结果分类。
  final PatchBootStatus status;

  /// 涉及的补丁版本。被丢弃时是被丢弃的版本，patched 时是当前生效的版本。
  /// 部分场景（meta 损坏、circuit 熔断）可能为 null。
  final String? patchVersion;

  /// versionCode mismatch 专用：补丁声明的 targetVersionCode。
  final int? patchTargetVersionCode;

  /// 当前宿主 APK 的 versionCode。
  final int? appVersionCode;

  /// 熔断器触发时：触发时的累计崩溃次数（删除前的真实值）。
  final int? crashCount;

  /// hookInstallFailed 专用：尝试过的 FlutterInjector 字段候选名。
  /// 用于定位 Flutter 升级后字段改名的问题。
  final List<String>? attemptedLoaderFields;

  /// 这条诊断对应的"上次冷启动"时间。
  final DateTime recordedAt;

  /// 给开发者看的描述。可能为 null。**不要直接展示给最终用户。**
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

  /// `true` 表示上次启动是预期内的健康状态（patched 或 noPatch）。
  /// 业务侧通常只需关心 `false` 的情况。
  bool get isHealthy =>
      status == PatchBootStatus.patched ||
      status == PatchBootStatus.noPatch;

  /// 从原生 MethodChannel 返回的 Map 反序列化。非预期结构归到 [PatchBootStatus.unknown]。
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
