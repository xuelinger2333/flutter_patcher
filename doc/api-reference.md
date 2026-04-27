# API 参考

> `package:flutter_patcher/flutter_patcher.dart` 的完整公开 API。
> 所有操作通过 `FlutterPatcher` 静态类调用。非 Android 平台一律 no-op（首次调用打印 warning，返回安全默认值，不抛异常）。

---

## 初始化

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MFkwEwYH...==',   // Ed25519 公钥，空字符串跳过签名校验
  maxCrashCount: 1,                    // 连续崩溃几次后熔断，默认 1（fail-fast）
  strictSignature: true,               // API < 33 遇到带签名补丁时：true 拒绝，false 跳过验签
  loaderFieldCandidates: ['flutterLoader'],  // FlutterInjector 内 loader 字段名候选
  loaderFallbackHeuristic: false,      // 候选名都失败后是否启发式扫描兜底
  verifyAfter: const Duration(seconds: 5),   // 前台存活多久算 verified
);
```

必须在 `runApp()` 之前调用。内部完成：读取本地补丁元数据、启动熔断器、注册 verified 判定钩子。重复调用幂等。

大多数项目只需要 `init()` 无参调用，参数按需覆盖即可。

---

## 检查更新

如果你使用插件内置的 check-update 协议（JSON 格式见 [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html)），可以用 `checkUpdate`：

```dart
try {
  final check = await FlutterPatcher.checkUpdate(
    'https://api.example.com/patch/check',
    headers: {'Authorization': 'Bearer $token'},
    timeout: const Duration(seconds: 10),
  );
  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
} on PatcherException catch (e) {
  // 网络失败或 JSON 解析错误
  log.warning('check update failed: ${e.message}');
}
```

**`PatchCheckResult`** 字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `hasUpdate` | `bool` | 是否有新补丁 |
| `patch` | `PatchInfo?` | 新补丁信息，`hasUpdate == false` 时为 null |

如果你用自己的协议，跳过 `checkUpdate`，直接构造 `PatchInfo` 传给 `applyPatch`。

---

## 应用补丁

### 方式一：给 URL，插件下载（推荐）

```dart
final result = await FlutterPatcher.applyPatch(
  PatchInfo(
    version: '1.0.0-h1',
    patchUrl: 'https://cdn.example.com/libapp.so',
    md5: '0123456789abcdef0123456789abcdef',
    // 可选字段
    signature: '',           // Ed25519 签名，空字符串跳过
    targetVersionCode: 100,  // null 时自动绑定当前 APK versionCode
    mode: PatchMode.full,    // 或 PatchMode.bsdiff
    targetMd5: '',           // bsdiff 模式必填：合成后 .so 的预期 MD5
  ),
  onProgress: (p) {
    print('${p.phase.name}: ${p.fraction ?? "..."}');
  },
);
```

### 方式二：字节已在内存

```dart
final result = await FlutterPatcher.applyPatchBytes(
  bytes,
  version: '1.0.0-h1',
  signature: '',         // 可选
  targetVersionCode: 100, // 可选
  onProgress: (p) => print(p.phase.name),
);
```

内部自动算 MD5、处理临时文件，再走 `applyPatch` 主流程。

### 结果处理

两个方法都返回 **`PatchApplyResult`**：

```dart
if (result.ok) {
  // 补丁已落盘，下次冷启动生效
  showRestartHint();
} else {
  switch (result.error!) {
    case PatchApplyError.blacklisted:
      // 该补丁曾导致崩溃，通知服务端下架
      break;
    case PatchApplyError.network:
    case PatchApplyError.ioError:
      // 可重试（建议指数退避，最多 3 次）
      break;
    case PatchApplyError.md5Mismatch:
      // CDN 脏数据或服务端 MD5 计算错误
      break;
    case PatchApplyError.signatureInvalid:
      // 可能被篡改，上报安全事件
      break;
    default:
      log.warning('patch: ${result.error?.name} / ${result.message}');
  }
}
```

`result.message` 是给开发者看的诊断描述，不要直接展示给用户。同版本补丁重复调用幂等返回 `ok=true`。

### 全部错误码

| 错误码 | 含义 | 建议处理 |
|---|---|---|
| `invalidArgs` | 缺必填字段或格式错误 | 告警服务端 |
| `blacklisted` | (version, md5) 命中本地黑名单 | 告警服务端下架，不重试 |
| `network` | 下载失败 | 稍后重试 |
| `md5Mismatch` | 下载文件 MD5 与传入值不符 | 检查 CDN / 服务端 |
| `signatureInvalid` | Ed25519 签名失败 | 上报安全事件，不重试 |
| `ioError` | 磁盘满 / 权限 / rename 失败 | 稍后重试 |
| `bsdiffDisabled` | 收到 bsdiff 补丁但未编译 native 模块 | 切回 full 模式（bsdiff 配置见 [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html)） |
| `bsdiffApplyFailed` | bsdiff 合成失败 | 检查 APK 版本是否匹配 |
| `targetMd5Mismatch` | 合成后 .so 的 MD5 与 `targetMd5` 不符 | 同上 |
| `unknown` | 未分类异常 | 查看 `result.message` |

### 进度监听

除了 `onProgress` 回调，也可以通过全局广播流监听：

```dart
FlutterPatcher.applyProgress.listen((p) {
  // p.phase: downloading / verifying / bsdiffMerging / finalizing
  // p.bytesReceived / p.totalBytes: 仅 downloading 阶段有意义
  // p.fraction: 0.0~1.0 的下载进度，非下载阶段或 totalBytes 未知时返回 null
});
```

---

## 回滚

```dart
await FlutterPatcher.rollback();
```

删除当前补丁，下次冷启动回到 APK 内置版本。手动回滚不入黑名单。

---

## 主动上报启动成功

```dart
await FlutterPatcher.reportBootSuccess();
```

通常由 `init()` 在 verified 后自动调用，不需要手动干预。仅在你需要更严格的判定时机（比如业务首页渲染完成才算成功）才显式调用。

---

## 查询状态

```dart
// 当前 APK 的 versionCode（API 28+ 用 longVersionCode）
final int? code = await FlutterPatcher.appVersionCode;

// 当前已生效或已就绪的补丁版本，无补丁返回 null
final String? ver = await FlutterPatcher.currentVersion;

// 当前设备 ABI，用于拼进 check-update 请求
final String abi = await FlutterPatcher.deviceAbi;
```

---

## 上次启动诊断

每次冷启动后，原生侧会记录补丁加载结果。通过 `lastBootDiagnostic` 读取并上报：

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;
if (diag != null && !diag.isHealthy) {
  analytics.report('patch_dropped', {
    'status': diag.status.name,       // 见下表
    'patch_version': diag.patchVersion,
    'crash_count': diag.crashCount,
    'message': diag.message,
  });
}
```

**`PatchBootDiagnostic`** 字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `status` | `PatchBootStatus` | 结果分类，见下表 |
| `recordedAt` | `DateTime` | 这条诊断对应的冷启动时间 |
| `patchVersion` | `String?` | 涉及的补丁版本（meta 损坏时可能为 null） |
| `patchTargetVersionCode` | `int?` | versionCode 不匹配时：补丁声明的 target |
| `appVersionCode` | `int?` | 当前 APK 的 versionCode |
| `crashCount` | `int?` | 熔断触发时的累计崩溃次数 |
| `attemptedLoaderFields` | `List<String>?` | `hookInstallFailed` 时尝试过的字段名 |
| `message` | `String?` | 给开发者看的诊断描述 |
| `isHealthy` | `bool` | `patched` 或 `noPatch` 时为 true |

**`PatchBootStatus` 取值：**

| 值 | 含义 | 处置 |
|---|---|---|
| `patched` | 补丁加载成功 | 正常 |
| `noPatch` | 无补丁，使用内置版本 | 正常 |
| `droppedVersionCodeMismatch` | APK 升级后旧补丁失效 | 常见，通常无需告警 |
| `droppedCircuitBreaker` | 连续崩溃达熔断阈值 | **强告警**，通知服务端下架 |
| `droppedSignatureInvalid` | 签名校验失败 | **告警**，可能被篡改 |
| `droppedMd5Mismatch` | 本地 .so 与 meta 记录不一致 | 上报 |
| `droppedMetaCorrupted` | meta.json 损坏 | 上报 |
| `hookInstallFailed` | 反射替换 FlutterLoader 失败 | 需调整 `loaderFieldCandidates` |
| `unknown` | 未分类异常 | 查看 `message` |

`example/lib/diag_card.dart` 将这些字段做成了可视化卡片，真机调试时直接看屏幕即可。

---

## 黑名单

```dart
// 查看当前黑名单（按入黑时间从旧到新）
final entries = await FlutterPatcher.blacklist;
for (final e in entries) {
  print('${e.version} / ${e.md5} / ${e.reason} / ${e.blacklistedAt}');
}

// 清空黑名单（仅调试用）
await FlutterPatcher.clearBlacklist();
```

**`BlacklistEntry`** 字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `version` | `String` | 入黑补丁的 version |
| `md5` | `String` | 入黑补丁的 MD5（小写 hex） |
| `reason` | `String` | 入黑原因：`BOOT_CRASH` / `MD5_MISMATCH` / `SIGNATURE_INVALID` / `META_CORRUPTED` |
| `blacklistedAt` | `DateTime` | 入黑时间 |

黑名单机制的详细设计见 [Crash guard](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-guard-topic.html)。

---

## PatchInfo 构造

除了直接构造，`PatchInfo` 也支持从 JSON 反序列化（兼容驼峰和下划线命名）：

```dart
// 从服务端 JSON 构造
final patch = PatchInfo.fromJson(json);

// 序列化（传给原生 MethodChannel）
final map = patch.toJson();
```

**`PatchInfo`** 完整字段：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `version` | `String` | ✅ | 补丁版本号，自定义字符串 |
| `patchUrl` | `String` | ✅ | 下载地址 |
| `md5` | `String` | ✅ | 补丁文件的 MD5（小写 hex，32 字符）。bsdiff 模式下是差分文件的 MD5 |
| `signature` | `String` | | Ed25519 签名（Base64），空字符串跳过验签 |
| `targetVersionCode` | `int?` | 推荐 | 绑定的宿主 APK versionCode，null 时自动抓取 |
| `mode` | `PatchMode` | | `PatchMode.full`（默认）或 `PatchMode.bsdiff` |
| `targetMd5` | `String` | bsdiff 必填 | 合成后 .so 的预期 MD5 |
| `raw` | `Map<String, dynamic>` | | `fromJson` 时保留的原始 JSON |

**`PatchMode`** 取值：

| 值 | 说明 |
|---|---|
| `full` | 完整 `libapp.so`，直接替换（默认） |
| `bsdiff` | 差分包，端侧合成。需启用 native bsdiff 模块，否则报 `bsdiffDisabled` |

---

## 异常

只有 `checkUpdate` 会抛异常（网络失败或 JSON 解析错误），类型为 **`PatcherException`**，包含 `message` 字段。

其他所有 API 通过返回值报告结果，不抛异常。

---

## 版本兼容说明

- 0.x 阶段 API 可能调整，建议 `pubspec.yaml` 固定版本号
- `PatchBootStatus` 和黑名单 `reason` 的字符串保持前向兼容；新增值时旧版本 SDK 归到 `unknown`
- `PatchInfo.fromJson` 兼容驼峰与下划线命名，未识别字段保留在 `raw` 不影响解析