# API 参考

[English](api-reference.md) | **简体中文**

本文列出 App 中使用的 Dart API：`FlutterPatcher` 的静态成员，以及它们接收和返回的类型。

- 插件只在 Android 和 iOS 上工作。在其他平台上，调用不做任何事，并在第一次调用时打印一条警告：查询类接口返回空值，`checkUpdate` 返回没有更新，`applyPatch`、`applyPatchBytes`、`applyPatchFile` 返回 `unknown`，`patchTarget` 和 `inspectPatch` 抛出 `PatcherException`。
- 只有用 `flutter_patcher build` 构建的宿主才能接收补丁，见[工作原理](architecture-zh.md)。

```dart
import 'package:flutter_patcher/flutter_patcher.dart';
```

## 常见任务

### 检查并安装更新

**目标**：`url` 上有更新的补丁文件时下载并安装，并处理每一种结果。

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

Future<void> updateIfAvailable() async {
  final PatchCheckResult check;
  try {
    check = await FlutterPatcher.checkUpdate();
  } on PatcherException catch (e) {
    debugPrint('checkUpdate failed: $e'); // 网络错误、HTTP 错误，或没有地址
    return;
  }
  if (!check.hasUpdate) return;

  final result = await FlutterPatcher.applyPatch(
    check.patch!,
    onProgress: (p) => debugPrint('$p'),
  );
  if (result.ok) return; // 下次冷启动起运行

  switch (result.error) {
    case PatchApplyError.network || PatchApplyError.ioError:
      break; // 临时问题：稍后再检查
    case PatchApplyError.blacklisted:
      break; // 这个补丁曾在本机启动失败；等待修复后的补丁
    default:
      debugPrint('patch rejected: ${result.error?.name} ${result.message}');
  }
}
```

**验证**：`result.ok` 为 `true`，`await FlutterPatcher.currentVersion` 返回该文件的 `seq`。

### 安装自己获取的补丁文件

见[自己获取补丁文件](#自己获取补丁文件)。

### 显示正在运行的补丁

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

Future<void> showRunningPatch() async {
  final diag = await FlutterPatcher.lastBootDiagnostic; // 本次启动的情况
  final installed = await FlutterPatcher.currentVersion; // 下次冷启动起运行
  debugPrint('running: ${diag?.status.name} ${diag?.patchVersion}; installed: $installed');
}
```

`lastBootDiagnostic` 描述本次启动，`currentVersion` 描述已安装的补丁。从安装成功到下次冷启动之前，两者不同。

### 上报异常启动

见[崩溃保护](crash-protection-zh.md)。

## 初始化

### `init`

```dart
static Future<void> init({
  int maxCrashCount = 1,
  Duration verifyAfter = const Duration(seconds: 5),
})
```

在 `main()` 中 `runApp()` 之前调用；重复调用不起作用。它配置崩溃保护，并在首帧之后的 `verifyAfter` 时间内继续把未捕获的 Dart 错误计为启动失败。启动本身在首帧时由原生代码确认。

| 参数 | 说明 |
|---|---|
| `maxCrashCount` | 连续多少次启动失败后回滚补丁并拉黑 |
| `verifyAfter` | 首帧之后多长时间内，未捕获的 Dart 错误仍计为启动失败（只计算在前台的时间） |

详细行为见[崩溃保护](crash-protection-zh.md)。`init` 还接受 `loaderFieldCandidates` 和 `loaderFallbackHeuristic`，用于适配 Flutter 内部实现的变化，请保持默认值。

## 设备接受哪些文件

无论通过哪个 API 交给插件，安装都经过同一套原生校验。文件格式见 [CLI 参考：补丁文件](cli-zh.md#补丁文件)。

| 文件 | 结果 |
|---|---|
| 长度、魔数、版本、宿主指纹或 payload 摘要不对；或在签名宿主上缺少签名、签名无效 | 拒绝：`signatureInvalid` |
| `seq` 大于 `acceptedSeq` 的补丁 | 安装，`acceptedSeq` 变为它的 `seq`；下次冷启动起运行 |
| 再次安装已安装的那个补丁文件 | 成功，不改变任何状态 |
| 其他 `seq` 不大于 `acceptedSeq` 的补丁 | 拒绝：`invalidArgs` |
| 已被拉黑的补丁 | 拒绝：`blacklisted` |
| `seq` 大于 `acceptedSeq` 的撤回 | 删除已安装的补丁，`acceptedSeq` 变为它的 `seq`。当前进程继续运行，下次冷启动起运行安装包自带的版本 |
| `seq` 不大于 `acceptedSeq` 的撤回 | 拒绝：`invalidArgs` |

- `acceptedSeq` 按宿主构建分别记录。App 的新构建（新的指纹）从 0 开始，并丢弃上一个构建的补丁。
- 不签名的宿主忽略签名区，也接受签过名的文件。
- `rollback()` 删除已安装的补丁，但保留 `acceptedSeq`，所以同一个文件不能再次安装；请重新执行 `patch`，或重新发布该输出（`publish --patch <目录>`），取得新的 `seq`。
- 每次冷启动加载前，都会重新校验已安装的文件。

## 补丁文件

### `patchTarget`

```dart
static Future<PatchTarget> get patchTarget
```

本宿主的身份。自己获取补丁文件的 App 把这些值发给服务端，由服务端选出文件。App 不是用 flutter_patcher 构建时抛出 `PatcherException`。

**`PatchTarget`**

| 成员 | 说明 |
|---|---|
| `fileName` | CLI 为本宿主生成的补丁文件名：flavor 和渠道为默认的 `default`、`production` 时是 `<version_code>-<abi>.fptc`，否则是 `<version_code>-<flavor>-<channel>-<abi>.fptc`，例如 `1-arm64-v8a.fptc`、`3-paid-beta-arm64-v8a.fptc`。flavor 和渠道只含字母、数字和 `_`，因此不同宿主的文件名不会相同 |
| `versionCode`、`flavor`、`channel`、`abi`、`strategy` | 构建信息，即 `build` 写入宿主策略的值 |
| `fingerprint` | 宿主构建的指纹；其他指纹的文件会被拒绝 |
| `signed` | 宿主是否只接受其补丁密钥签名的文件 |
| `acceptedSeq` | 本宿主接受过的最大 `seq`（补丁或撤回），从未接受过时为 `0`。只有序号大于它的文件才能安装 |
| `scope` | 以上全部内容组成的 map，另含 `application_id` |

### `inspectPatch`

```dart
static Future<PatchInspection> inspectPatch(List<int> header)
```

根据文件的前 146 字节（多出的部分忽略）判断安装它是否会改变本宿主，可以在下载其余部分之前调用。它只检查魔数、版本、指纹和 `seq`；安装时仍会校验整个文件。App 不是用 flutter_patcher 构建时抛出 `PlatformException`。

**`PatchInspection`**

| 字段 | 说明 |
|---|---|
| `fresh` | 文件头属于本宿主且 `seq` 大于 `acceptedSeq` 时为 `true` |
| `action` | 补丁为 `publish`，撤回为 `withdraw`；传入的不是补丁文件头时为 `null` |
| `seq` | 文件的序号；传入的不是补丁文件头时为 `null` |
| `reason` | 不是 `fresh` 的原因，例如 `Patch file of another host`、`Not newer than the accepted patch` |

### `applyPatchBytes`

```dart
static Future<PatchApplyResult> applyPatchBytes(List<int> bytes)
```

按[设备接受哪些文件](#设备接受哪些文件)中的规则安装补丁文件 `bytes`，或执行它所表示的撤回。字节先写入一个临时文件交给原生校验，完成后删除。不抛异常，结果都在返回值里。

### `applyPatchFile`

```dart
static Future<PatchApplyResult> applyPatchFile(String path)
```

与 `applyPatchBytes` 相同，参数是设备上的文件。不会删除该文件。路径无法读取时返回 `ioError`。

## 内置下载器

`checkUpdate` 和 `applyPatch` 从放置了 CLI 所生成文件的 URL 下载本宿主的文件。App 自己获取文件时不需要它们。

### `checkUpdate`

```dart
static Future<PatchCheckResult> checkUpdate({
  String? url,
  Duration timeout = const Duration(seconds: 10),
})
```

发送带 `Range: bytes=0-145` 的 `GET <url>/<fileName>`，读取前 146 字节，再用 `inspectPatch` 判断。

- 不传 `url` 时，使用 `build` 写入 App 的地址：`flutter_patcher.yaml` 中的 `url`；未设置时为 `serve` 提供补丁的 `http://127.0.0.1:8686`。要检查其他地址时传入 `url`，例如 iPhone 访问 `serve` 用的 HTTPS 隧道。
- 只有文件是 `fresh` 时 `hasUpdate` 才为 `true`：本宿主更新的补丁，或更新的撤回。
- `404` 表示没有更新。`200`、`206`、`404` 以外的状态码都会抛出异常，所以对不存在的文件返回 `403` 的存储（私有 S3 和 R2 存储桶常常如此）必须改为返回 `404`。
- 地址必须是 HTTPS；例外是 `serve` 使用的设备本机地址 `http://127.0.0.1`、`http://[::1]`、`http://localhost`。地址中不能有用户名、密码或 `#` 片段，不跟随重定向。
- `timeout` 限制连接和读取文件头的时间。
- 以下情况抛出 `PatcherException`：App 不是用 flutter_patcher 构建；没有传 `url` 且 App 中没有地址；请求失败，包括响应不足 146 字节。

**`PatchCheckResult`**

| 字段 | 说明 |
|---|---|
| `hasUpdate` | 是否有可应用的更新 |
| `patch` | 更新内容，原样传给 `applyPatch`。`patch.version` 是它的 `seq`（字符串）；`patch.raw` 包含 `url`、`size`、`seq` 和 `action`（`publish` 或 `withdraw`） |

### `applyPatch`

```dart
static Future<PatchApplyResult> applyPatch(
  PatchInfo patchInfo, {
  void Function(PatchApplyProgress)? onProgress,
})
```

把 `checkUpdate` 找到的文件下载到临时文件，按 `applyPatchFile` 的方式安装，完成后删除临时文件。**补丁在下次冷启动时生效**，当前进程继续运行原来的代码。撤回则删除已安装的补丁。

- 下载要求状态码 `200`，且大小正好等于文件头声明的大小（未压缩的响应中 `Content-Length` 与之不同即失败）。15 秒没有数据或总共超过 2 分钟即失败，与 `checkUpdate` 的 `timeout` 无关。所有下载失败都返回 `network`，稍后重新 `checkUpdate` 即可。
- 传入的 `PatchInfo` 不是 `checkUpdate` 返回的，返回 `invalidArgs`。
- 不抛异常，结果都在返回值里。

## 返回值

**`PatchApplyResult`**，由 `applyPatch`、`applyPatchBytes` 和 `applyPatchFile` 返回：

| 字段 | 说明 |
|---|---|
| `ok` | 是否已安装文件或已执行撤回；再次安装已安装的文件也算成功 |
| `error` | 失败原因，`PatchApplyError` |
| `message` | 给开发者看的说明，不要直接展示给用户 |

**`PatchApplyError`**

| 取值 | 含义 | 处理方式 |
|---|---|---|
| `invalidArgs` | 文件的 `seq` 不大于 `acceptedSeq`：旧的补丁或撤回，或 `rollback` 之后的同一个补丁。用 `applyPatch` 时，也可能是传入的 `PatchInfo` 不是 `checkUpdate` 返回的 | 重新执行 `patch`，或重新发布该补丁输出（`publish --patch <目录>`），取得新的 `seq` |
| `blacklisted` | 这个补丁曾导致启动失败，已在本机拉黑 | 发布修复后的补丁 |
| `network` | `applyPatch` 下载文件失败 | 稍后重试 |
| `signatureInvalid` | 不是本宿主的文件（其他构建、flavor、渠道或 ABI）、文件损坏或不完整，或不是宿主补丁密钥签名的 | 不要重试；下发本构建 `patchTarget.fileName` 对应、由其密钥签名的文件 |
| `ioError` | 无法读取文件，或磁盘、文件系统出错，例如空间不足 | 稍后重试 |
| `unknown` | 其他情况：平台不支持、App 不是用 flutter_patcher 构建、宿主在安装时拒绝了补丁内容 | 上报 `message` |

### 进度

`onProgress` 和 `applyProgress` 流接收 `PatchApplyProgress`：

| 字段 | 说明 |
|---|---|
| `phase` | `downloading`（仅 `applyPatch`）、`verifying`、`finalizing` |
| `bytesReceived` / `totalBytes` | 只在 `downloading` 阶段有意义 |
| `fraction` | 下载进度，0.0 到 1.0；未知时为 `null` |

`applyProgress` 是广播流，请在安装之前订阅。`applyPatchBytes` 和 `applyPatchFile` 的 `verifying`、`finalizing` 也会出现在其中。

## 状态查询

| API | 说明 |
|---|---|
| `currentVersion` | 已安装补丁的 `seq`，十进制字符串（封装时的 Unix 秒数）；没有补丁时为 `null`。安装成功后立即变化，但补丁要到下次冷启动才运行 |
| `lastBootDiagnostic` | 最近一次冷启动对补丁的处理结果，见[崩溃保护](crash-protection-zh.md) |
| `blacklist` | 本机已拉黑的补丁；`BlacklistEntry.version` 为 `<指纹>:<seq>:<SHA-256>` |
| `appVersionCode` | 宿主的版本号：Android 的 versionCode，iOS 的 CFBundleVersion |
| `deviceAbi` | 设备的主 ABI：Android 上是 `Build.SUPPORTED_ABIS` 的第一项（如 `arm64-v8a`），iOS 上是 `ios-arm64` |

## 手动操作

| API | 说明 |
|---|---|
| `rollback()` | 删除已安装的补丁，下次冷启动起运行安装包自带的版本。不拉黑该补丁，但保留 `acceptedSeq`，所以该文件不能再次安装 |
| `clearBlacklist()` | 清空本机的黑名单，用于测试，或在确认问题已排除之后 |

## 自己获取补丁文件

插件不负责获取补丁。App 用任何方式拿到文件都可以：自家接口、CDN、推送、随版本内嵌的文件、用户选择的文件。文件必须是 CLI 为本宿主构建生成的那个，即 `patch` 输出目录或发布存储中的 `<fileName>`。

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

/// 向自己的服务端请求本宿主的补丁文件并安装。
Future<void> updateFromMyServer() async {
  final target = await FlutterPatcher.patchTarget;
  final uri = Uri.https('api.example.com', '/patches', {
    'file': target.fileName,
    'fingerprint': target.fingerprint,
    'after': '${target.acceptedSeq}',
  });
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode == HttpStatus.noContent) return; // 没有更新的文件
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final bytes = await consolidateHttpClientResponseBytes(response);
    final result = await FlutterPatcher.applyPatchBytes(bytes);
    if (!result.ok) {
      debugPrint('patch rejected: ${result.error?.name} ${result.message}');
    }
  } finally {
    client.close();
  }
}
```

- 服务端按 `fileName` 选出文件（同一个文件名可能对应多个构建时，再加上 `fingerprint`）；哪些用户拿到哪个文件由服务端决定。
- 只有 `seq` 大于 `acceptedSeq` 的文件才会被安装；服务端可以不发送其他文件，App 也可以先用 `inspectPatch` 检查前 146 字节。
- 不签名的宿主上，任何能把文件交给 App 的一方都能在 App 中执行代码，传输安全需要你自己保证。签名的宿主会拒绝不是其补丁密钥签名的文件，无论文件来自哪里。

## 1.1 中删除的内容

`SignedManifest`、`SignedUpdateResult`、`fetchSignedManifest`、`applySignedManifest`、`updatePublicationTrust` 已删除，使用它们的代码无法编译。自己获取的文件请用 `applyPatchBytes` 或 `applyPatchFile`；从 URL 下载请用 `checkUpdate` 和 `applyPatch`。
