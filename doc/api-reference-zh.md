# API 参考

[English](api-reference.md) | **简体中文**

本文列出 App 中使用的 Dart API，全部是 `FlutterPatcher` 的静态成员。

- 插件只在 Android 和 iOS 上工作。在其他平台上，调用不做任何事，并在第一次调用时打印一条警告：查询类接口返回空值，`checkUpdate` 返回没有更新，`applyPatch` 返回 `unknown`。`fetchSignedManifest`、`applySignedManifest`、`updatePublicationTrust` 没有平台保护，会直接失败。
- 只有用 `flutter_patcher build` 构建的宿主才能接收补丁，见[工作原理](architecture-zh.md#宿主能接收补丁的安装包)。

```dart
import 'package:flutter_patcher/flutter_patcher.dart';
```

## 常见任务

### 检查并安装更新

**目标**：有新补丁时安装它，并处理每一种结果。

```dart
Future<void> updateIfAvailable(String url) async {
  final PatchCheckResult check;
  try {
    check = await FlutterPatcher.checkUpdate(url);
  } on PatcherException catch (e) {
    debugPrint('checkUpdate failed: $e'); // 网络错误，或清单校验失败
    return;
  }
  if (!check.hasUpdate) return;

  final result = await FlutterPatcher.applyPatch(
    check.patch!,
    onProgress: (p) => showProgress(p.fraction), // 不在下载阶段时为 null
  );
  if (result.ok) return; // 下次冷启动起运行

  switch (result.error) {
    case PatchApplyError.network || PatchApplyError.ioError:
      scheduleRetry(); // 临时问题；稍后用同一个 check.patch 再调用 applyPatch
    case PatchApplyError.blacklisted:
      break; // 这个补丁曾在本机启动失败；等待修复后的补丁
    default:
      report('patch_apply', {'error': result.error?.name, 'message': result.message});
  }
}
```

- 网络出错或清单校验失败时，`checkUpdate` 抛出 `PatcherException`。`applyPatch` 不抛异常，结果都在返回值里。
- 补丁从下次冷启动起运行。

**验证**：`result.ok` 为 `true`，`await FlutterPatcher.currentVersion` 返回该补丁的序号。

### 显示正在运行的补丁

```dart
Future<void> showRunningPatch() async {
  final diag = await FlutterPatcher.lastBootDiagnostic; // 本次启动的情况
  final installed = await FlutterPatcher.currentVersion; // 下次冷启动起运行
  debugPrint('running: ${diag?.status.name} ${diag?.patchVersion}; installed: $installed');
}
```

`lastBootDiagnostic` 描述本次启动，`currentVersion` 描述已安装的补丁。在 `applyPatch` 成功之后、下次冷启动之前，两者不同。

### 上报不健康的启动

见[崩溃保护：启动诊断](crash-protection-zh.md#启动诊断)。

### 通过自己的接口分发清单

见[自行分发清单](#自行分发清单)。

## 初始化

### `init`

```dart
static Future<void> init({
  int maxCrashCount = 1,
  Duration verifyAfter = const Duration(seconds: 5),
})
```

在 `main()` 中、`runApp()` 之前调用，重复调用没有影响。它配置崩溃保护，并在首帧之后的 `verifyAfter` 时间内继续把 Dart 未捕获异常计为启动失败。本次启动是否成功由原生代码在首帧时确认。

| 参数 | 说明 |
|---|---|
| `maxCrashCount` | 同一个补丁连续启动失败多少次后被回滚并拉黑 |
| `verifyAfter` | 首帧之后继续把 Dart 未捕获异常视为启动失败的时长（只计算 App 在前台的时间） |

这两个参数的具体作用见[崩溃保护](crash-protection-zh.md)。`init` 还有两个参数 `loaderFieldCandidates`、`loaderFallbackHeuristic`，用于适配 Flutter 内部实现的变化，请保持默认值。

## 检查和安装更新

### `checkUpdate`

```dart
static Future<PatchCheckResult> checkUpdate(
  String url, {
  Duration timeout = const Duration(seconds: 10),
})
```

`url` 是发布存储对外提供访问的根地址，例如 `https://cdn.example.com/my-app`，开发时是 `serve` 提供的 `http://127.0.0.1:8686`。插件会读取该地址下属于本宿主的清单，并在原生代码中校验。

- 只有接受这份清单会改变设备状态时，`hasUpdate` 才为 `true`：有序号更大的新补丁，或者有新的撤回。已经安装过的补丁不算更新。
- `applyPatch` 一旦下载完补丁，设备就已接受这份清单，即使随后安装失败，`checkUpdate` 也不会再报告它。要重试，请用同一个 `PatchInfo` 再次调用 `applyPatch`。
- 还没有发布任何内容时，存储返回 404，`checkUpdate` 返回 `hasUpdate: false`。其他错误状态码都会抛出异常，所以对不存在的文件返回 403 的存储（私有的 S3、R2 存储桶常见这种情况）需要改为返回 404。
- 地址必须是 HTTPS；唯一的例外是本机地址 `http://127.0.0.1`、`http://[::1]`、`http://localhost`，供 `serve` 使用。地址中不能带用户名、密码或 `#` 片段，也不跟随重定向。超过 24,000 字节的清单会被拒绝。
- 网络错误、清单校验失败、宿主不是用 `flutter_patcher build` 构建等情况会抛出 `PatcherException`。

**`PatchCheckResult`**

| 字段 | 说明 |
|---|---|
| `hasUpdate` | 是否有可安装的更新 |
| `patch` | 更新的内容，原样传给 `applyPatch`。`patch.version` 是补丁序号，撤回时为 `withdraw` |

### `applyPatch`

```dart
static Future<PatchApplyResult> applyPatch(
  PatchInfo patchInfo, {
  void Function(PatchApplyProgress)? onProgress,
})
```

下载并安装 `checkUpdate` 返回的更新。原生代码会再次校验清单，然后校验补丁的哈希、签名、所属宿主和序号，全部通过后原子提交。**补丁在下次冷启动时生效**，当前进程继续运行原来的代码。如果更新是一次撤回，则删除已安装的补丁。

下载有自己的时间限制，不受 `checkUpdate` 的 `timeout` 影响：15 秒没有收到数据，或总共超过 2 分钟，下载就会失败。

这个方法不会抛出异常，结果都放在返回值里。

**`PatchApplyResult`**

| 字段 | 说明 |
|---|---|
| `ok` | 是否安装成功；重复安装同一个补丁也算成功 |
| `error` | 失败原因，类型为 `PatchApplyError` |
| `message` | 给开发者看的说明，不要直接展示给用户 |

**`PatchApplyError`**

| 值 | 含义 | 建议 |
|---|---|---|
| `network` | 补丁下载失败 | 稍后重试 |
| `ioError` | 磁盘或文件系统错误，例如空间不足 | 稍后用同一个 `PatchInfo` 重试 |
| `signatureInvalid` | 补丁签名校验失败；iOS 上 App 没有通过 flutter_patcher 生成的入口启动时也会返回 | 不要重试，检查发布流程、存储内容和构建方式 |
| `blacklisted` | 这个补丁曾导致启动失败，已在本机被拉黑 | 发布修复后的新补丁 |
| `invalidArgs` | 传入的不是 `checkUpdate` 返回的结果；补丁的序号或哈希与清单不一致；或本机已经安装过该序号（例如 `rollback` 之后） | 检查调用方式和发布流程 |
| `unknown` | 其他错误，包括清单校验失败、补丁的大小或哈希与清单不一致、插件版本低于清单要求 | 上报 `message` |


### 进度

`onProgress` 和 `applyProgress` 流会收到 `PatchApplyProgress`：

| 字段 | 说明 |
|---|---|
| `phase` | `downloading`、`verifying`、`finalizing` |
| `bytesReceived` / `totalBytes` | 只在 `downloading` 阶段有意义 |
| `fraction` | 下载进度 0.0–1.0，未知时为 `null` |

`applyProgress` 是广播流，需要在调用 `applyPatch` 之前订阅。

## 查询状态

| API | 说明 |
|---|---|
| `currentVersion` | 磁盘上已安装补丁的序号，没有时为 `null`。`applyPatch` 成功后立即更新，但补丁要到下次冷启动才运行 |
| `lastBootDiagnostic` | 最近一次冷启动时补丁的加载结果，见[崩溃保护](crash-protection-zh.md#启动诊断) |
| `blacklist` | 本机被拉黑的补丁列表 |
| `appVersionCode` | 宿主的版本号：Android 的 versionCode，iOS 的 CFBundleVersion |
| `deviceAbi` | 设备的首选 ABI：Android 上是 `Build.SUPPORTED_ABIS` 的第一项（例如 `arm64-v8a`），iOS 上是 `ios-arm64` |

## 手动操作

| API | 说明 |
|---|---|
| `rollback()` | 删除已安装的补丁，下次冷启动运行安装包自带的版本。不会拉黑该补丁，但设备已经接受过它的序号，无法再次安装它；请发布一个序号更大的补丁 |
| `clearBlacklist()` | 清空本机黑名单，用于测试或确认问题已排除之后 |

## 自行分发清单

如果你不想让 App 直接访问发布存储（例如要先经过自己的接口鉴权），可以自己取得清单和补丁，再交给插件校验和安装：

```dart
// 1. 取得清单：publish 结果中 manifest 字段给出的文件（manifests/<哈希>.json），内容必须原样保留
final manifest = await FlutterPatcher.fetchSignedManifest(manifestUrl);
// 或者：SignedManifest.parse(从你的接口拿到的原始字符串)

// 2. 交给插件：提供补丁所在存储的根地址，或者直接提供补丁的字节
final result = await FlutterPatcher.applySignedManifest(
  manifest,
  baseUrl: storeUrl,      // 二选一
  // payload: patchBytes,
);
// result.action 是 'publish' 或 'withdraw'，result.result 是 PatchApplyResult
```

清单的签名覆盖它的完整原文，任何改写（包括重新格式化 JSON）都会导致校验失败。

与 `applyPatch` 不同，这两个方法会抛出异常：`fetchSignedManifest` 在该地址还没有发布内容时抛出 `FormatException`；`applySignedManifest` 在既没有 `baseUrl` 也没有 `payload` 时抛出 `ArgumentError`，原生代码拒绝清单时抛出 `PlatformException`。

`updatePublicationTrust(SignedManifest)` 用于在设备上应用 root 签名的信任更新，配合 `trust` 命令使用，见[进阶操作](advanced-zh.md#轮换发布密钥)。
