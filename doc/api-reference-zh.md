# API 参考

[English](api-reference.md) | **简体中文**

`FlutterPatcher` 的全部静态成员，以及它们接收和返回的类型。

这些接口只在用 `dart run flutter_patcher build` 构建的 Android 或 iOS App（下称宿主）上工作，因为 `build` 会把设备校验补丁所需的信息写进 App；其他情况见[平台支持](#平台支持)。宿主如何加载补丁见[工作原理](architecture-zh.md)，生成补丁文件的命令见 [CLI 参考](cli-zh.md)。

```dart
import 'package:flutter_patcher/flutter_patcher.dart';
```

## 总览

| 成员 | 说明 |
|---|---|
| [`init`](#init) | 配置崩溃保护，在 `runApp()` 之前调用 |
| [`isAvailable`](#isavailable) | 本 App 能否接收补丁 |
| [`checkUpdate`](#checkupdate) | 检查某个 URL 上是否有本宿主更新的补丁文件 |
| [`applyPatch`](#applypatch) | 下载并安装 `checkUpdate` 找到的文件 |
| [`patchTarget`](#patchtarget) | 本宿主的标识，自定义下发时发给服务端 |
| [`inspectPatch`](#inspectpatch) | 根据文件头判断安装某个文件是否会改变本宿主 |
| [`applyPatchBytes`](#applypatchbytes) | 安装 App 自行获取的补丁文件（字节） |
| [`applyPatchFile`](#applypatchfile) | 安装 App 自行获取的补丁文件（设备上的路径） |
| [`applyProgress`](#applyprogress) | 每次安装的进度 |
| [`currentVersion`](#currentversion) | 已安装补丁的 `seq` |
| [`lastBootDiagnostic`](#lastbootdiagnostic) | 最近一次冷启动对补丁的处理结果 |
| [`blacklist`](#blacklist) | 本机已拉黑的补丁 |
| [`appVersionCode`](#appversioncode) | 宿主的构建号 |
| [`deviceAbi`](#deviceabi) | 设备的主 ABI |
| [`rollback`](#rollback) | 删除本机已安装的补丁 |
| [`clearBlacklist`](#clearblacklist) | 清空本机的黑名单 |

`patchTarget`、`inspectPatch`、`applyPatchBytes` 和 `applyPatchFile` 需要 flutter_patcher 1.1.0 或更新版本，`isAvailable` 需要 1.1.1 或更新版本。用 flutter_patcher 1.0.0 构建的宿主用 flutter_patcher 1.0.0+1 打补丁，见[从 1.0 升级](upgrading-zh.md)。

## 方法与属性

### `init`

```dart
static Future<void> init({
  int maxCrashCount = 1,
  List<String> loaderFieldCandidates = const ['flutterLoader'],
  bool loaderFallbackHeuristic = false,
  Duration verifyAfter = const Duration(seconds: 5),
})
```

配置崩溃保护。

| 参数 | 说明 |
|---|---|
| `maxCrashCount` | 一个补丁连续启动失败多少次后被停用并拉黑。补丁代码开始运行之后抛出的 Dart 异常不计次数，补丁立即停用，见[失败之后](crash-protection-zh.md#失败之后)。小于 1 的值按 1 处理 |
| `verifyAfter` | 首帧之后多长时间内，未捕获的 Dart 异常仍计为启动失败。只计算 App 在前台的时间 |
| `loaderFieldCandidates`、`loaderFallbackHeuristic` | 仅用于 Android SO 宿主：插件定位 Flutter 加载器的方式。除非适配新的 Flutter 版本，否则保持默认值 |

**行为**

- 在 `main()` 中、`runApp()` 之前调用，这样它的错误钩子在首帧之前就已装好。之后的调用不起作用。
- 原生层在首帧时将本次启动标记为成功；`init` 在此后的 `verifyAfter` 内继续上报未捕获的 Dart 异常。哪些情况算启动失败、失败后如何处理，见[崩溃保护](crash-protection-zh.md)。

**异常**：无。

### `isAvailable`

```dart
static Future<bool> get isAvailable
```

本 App 能否接收补丁：运行在 Android 或 iOS 上，并且是用 `dart run flutter_patcher build` 构建的。用 `flutter run` 启动或用 `flutter build` 构建的 App 返回 `false`。

**异常**：无。

### `checkUpdate`

```dart
static Future<PatchCheckResult> checkUpdate({
  String? url,
  Duration timeout = const Duration(seconds: 10),
})
```

检查 `url` 上是否有本宿主更新的补丁文件。

| 参数 | 说明 | 默认值 |
|---|---|---|
| `url` | 检查的地址 | `build` 写入 App 的地址，即 `flutter_patcher.yaml` 中的 `url`；未设置时为 `http://127.0.0.1:8686`，即 `serve` 提供补丁的地址 |
| `timeout` | 连接和读取文件头的时间上限 | 10 秒 |

**返回值**：[`PatchCheckResult`](#patchcheckresult)。有更新时把其中的 `patch` 原样传给 [`applyPatch`](#applypatch)。

**行为**

- 发送带 `Range: bytes=0-145` 的 `GET <url>/<fileName>`，其中 `<fileName>` 是 [`patchTarget.fileName`](#patchtarget)，读取前 146 字节，并按 [`inspectPatch`](#inspectpatch) 的规则判断。
- 只有文件是 `fresh` 时 `hasUpdate` 才为 `true`：本宿主更新的补丁，或更新的撤回。
- [`isAvailable`](#isavailable) 为 `false` 时不发送请求，返回没有更新。
- `404` 表示没有更新。`200`、`206`、`404` 以外的状态码都会抛出异常，所以服务器对不存在的文件必须返回 `404`；完整要求见 [CLI 参考：下载服务器](cli-zh.md#下载服务器)。
- 地址必须是 HTTPS，因为不签名宿主会安装本构建的任何完整文件，在传输中被替换的文件就会在 App 中运行。只有指向设备本机的 `http://127.0.0.1`、`http://[::1]`、`http://localhost` 允许 HTTP，`serve` 通过 `adb reverse` 从这里被访问。
- 不跟随重定向，地址中也不能包含用户名、密码或 `#` 片段，所以响应无法把下载引向别处。

**异常**：以下情况抛出 [`PatcherException`](#patcherexception)：没有传入 `url` 且 App 中没有地址；请求失败，包括响应不足 146 字节。

### `applyPatch`

```dart
static Future<PatchApplyResult> applyPatch(
  PatchInfo patchInfo, {
  void Function(PatchApplyProgress)? onProgress,
})
```

下载 `checkUpdate` 找到的文件，并按 [`applyPatchFile`](#applypatchfile) 的方式安装。

| 参数 | 说明 |
|---|---|
| `patchInfo` | `checkUpdate` 返回的 [`PatchInfo`](#patchinfo) |
| `onProgress` | 接收本次调用的 [`PatchApplyProgress`](#patchapplyprogress) |

**返回值**：[`PatchApplyResult`](#patchapplyresult)。

**行为**

- 补丁在下次冷启动时生效，因为当前进程保持原来的代码；撤回则删除已安装的补丁。
- 下载要求状态码为 `200`，且大小与文件头声明的完全一致，所以未压缩的响应中 `Content-Length` 与之不同即失败。
- 15 秒没有收到数据或总计超过 2 分钟即失败，与 `checkUpdate` 的 `timeout` 无关。所有下载失败都返回 `network`。
- 传入的 `PatchInfo` 缺少 `checkUpdate` 设置的 `url` 和 `size` 时，返回 `invalidArgs`。

**异常**：无，所有结果都在返回值中。

```dart
final check = await FlutterPatcher.checkUpdate();
if (check.hasUpdate) {
  final result = await FlutterPatcher.applyPatch(check.patch!);
  if (!result.ok) debugPrint('${result.error?.name}: ${result.message}');
}
```

### `patchTarget`

```dart
static Future<PatchTarget> get patchTarget
```

标识本宿主。自行获取补丁文件的 App 把这些值发送给服务端，由服务端选择文件，见[由自家服务端自定义下发](advanced-zh.md#由自家服务端自定义下发)。

**返回值**：[`PatchTarget`](#patchtarget-1)。

**异常**：App 不是用 flutter_patcher 构建时抛出 [`PatcherException`](#patcherexception)。

### `inspectPatch`

```dart
static Future<PatchInspection> inspectPatch(List<int> header)
```

根据文件的前 146 字节判断安装它是否会改变本宿主，这样 App 可以不下载宿主会拒绝的文件。

| 参数 | 说明 |
|---|---|
| `header` | 文件的前 146 字节；超出的部分被忽略 |

**返回值**：[`PatchInspection`](#patchinspection)。

**行为**

- 只检查魔数、版本、指纹和 `seq`，所以安装时仍会校验整个文件。

**异常**：App 不是用 flutter_patcher 构建时抛出 [`PatcherException`](#patcherexception)。

### `applyPatchBytes`

```dart
static Future<PatchApplyResult> applyPatchBytes(List<int> bytes)
```

安装补丁文件 `bytes`，或执行它所表示的撤回。

| 参数 | 说明 |
|---|---|
| `bytes` | CLI 为本宿主构建生成的完整文件：`patch` 输出中的 `file`，或发布存储中的 `<fileName>` |

**返回值**：[`PatchApplyResult`](#patchapplyresult)。

**行为**

- 按[设备接受哪些文件](#设备接受哪些文件)中的规则安装，下次冷启动生效。

**异常**：无，所有结果都在返回值中。

### `applyPatchFile`

```dart
static Future<PatchApplyResult> applyPatchFile(String path)
```

与 [`applyPatchBytes`](#applypatchbytes) 相同，参数是设备上的文件路径。

| 参数 | 说明 |
|---|---|
| `path` | 设备上补丁文件的路径 |

**返回值**：[`PatchApplyResult`](#patchapplyresult)。

**行为**

- 该文件保留在原处。
- 路径无法读取时返回 `ioError`。

**异常**：无，所有结果都在返回值中。

### `applyProgress`

```dart
static Stream<PatchApplyProgress> get applyProgress
```

包含每次安装进度的广播流。

**返回值**：[`PatchApplyProgress`](#patchapplyprogress) 的流。

**行为**

- 包含 `applyPatch` 的全部阶段，以及 `applyPatchBytes` 和 `applyPatchFile` 的 `verifying`、`finalizing`。
- 在安装之前订阅，因为广播流不会重放订阅之前的事件。

**异常**：无。

### `currentVersion`

```dart
static Future<String?> get currentVersion
```

已安装补丁的 `seq`（十进制字符串）；没有补丁时为 `null`。

**行为**

- 安装成功后立即变化，而补丁从下次冷启动起运行，所以在此之前它与 `lastBootDiagnostic` 描述的不是同一个补丁。

**异常**：无；读取失败时返回 `null`。

### `lastBootDiagnostic`

```dart
static Future<PatchBootDiagnostic?> get lastBootDiagnostic
```

最近一次冷启动对补丁的处理结果；没有记录时为 `null`。

**返回值**：[`PatchBootDiagnostic`](#patchbootdiagnostic)。

**行为**

- 本次启动加载了补丁时，结果在首帧时记录；在此之前读取，会等到首帧后返回本次启动的结果。

**异常**：无；读取失败时返回 `null`。

```dart
final diag = await FlutterPatcher.lastBootDiagnostic; // 本次启动运行的补丁
final installed = await FlutterPatcher.currentVersion; // 下次冷启动运行的补丁
debugPrint('running: ${diag?.status.name} ${diag?.patchVersion}; installed: $installed');
```

### `blacklist`

```dart
static Future<List<BlacklistEntry>> get blacklist
```

本机已拉黑的补丁。

**返回值**：[`BlacklistEntry`](#blacklistentry) 的列表；没有时为空列表。

**异常**：无；读取失败时返回空列表。

### `appVersionCode`

```dart
static Future<int?> get appVersionCode
```

宿主的构建号：Android 的 versionCode，iOS 的 CFBundleVersion。

**异常**：无；无法读取时返回 `null`。

### `deviceAbi`

```dart
static Future<String> get deviceAbi
```

设备的主 ABI：Android 上是 `Build.SUPPORTED_ABIS` 的第一项，例如 `arm64-v8a`；iOS 上是 `ios-arm64`。

**异常**：无；无法读取时返回 `''`。

### `rollback`

```dart
static Future<void> rollback()
```

删除本机已安装的补丁，下次冷启动起运行安装包自带的版本。

**行为**

- 该补丁不会被拉黑。
- `acceptedSeq` 保持不变，所以之后只有 `seq` 更大的文件才能安装。

**异常**：无。

### `clearBlacklist`

```dart
static Future<void> clearBlacklist()
```

清空本机的黑名单，并将所有补丁的失败次数归零。

**异常**：无。

## 类型

### `PatchCheckResult`

由 [`checkUpdate`](#checkupdate) 返回。

| 字段 | 类型 | 说明 |
|---|---|---|
| `hasUpdate` | `bool` | 是否有可应用的更新：更新的补丁或撤回 |
| `patch` | `PatchInfo?` | 更新内容；没有更新时为 `null` |

### `PatchInfo`

`checkUpdate` 找到的文件。原样传给 [`applyPatch`](#applypatch)，因为自行构造的 `PatchInfo` 缺少下载所需的字段，会返回 `invalidArgs`。

| 字段 | 类型 | 说明 |
|---|---|---|
| `version` | `String` | 文件的 `seq`（字符串） |
| `raw` | `Map<String, dynamic>` | `url`、`size`、`seq` 和 `action`（`publish` 或 `withdraw`） |

### `PatchApplyResult`

由 [`applyPatch`](#applypatch)、[`applyPatchBytes`](#applypatchbytes) 和 [`applyPatchFile`](#applypatchfile) 返回。

| 字段 | 类型 | 说明 |
|---|---|---|
| `ok` | `bool` | 是否已安装文件或已执行撤回；再次安装已安装的文件也算成功 |
| `error` | `PatchApplyError?` | 失败原因；`ok` 为 `true` 时为 `null` |
| `message` | `String?` | 供开发者查看的说明，不是写给用户看的 |

### `PatchApplyError`

| 取值 | 含义 | 处理方式 |
|---|---|---|
| `invalidArgs` | 文件的 `seq` 不大于 `acceptedSeq`：旧的补丁或撤回，或 `rollback()` 之后的同一个补丁。使用 `applyPatch` 时，还包括传入的 `PatchInfo` 不是 `checkUpdate` 返回的 | 下发 `seq` 更大的文件：重新执行 `patch`，或执行 `publish --patch <目录>` |
| `blacklisted` | 该补丁曾导致启动失败，已在本机拉黑 | 下发修复后的补丁 |
| `network` | `applyPatch` 下载文件失败 | 稍后重试 |
| `signatureInvalid` | 不是本宿主的文件（其他构建、flavor、渠道或 ABI）、文件损坏或不完整、超过 320 MiB，或不是宿主补丁密钥签名的 | 不要重试，因为同一个文件会以同样的方式失败；下发本构建 `patchTarget.fileName` 对应、由其密钥签名的文件 |
| `ioError` | 无法读取文件，或磁盘、文件系统出错，例如空间不足 | 稍后重试 |
| `unknown` | 其他情况：平台不支持、App 不是用 flutter_patcher 构建、宿主在安装时拒绝了补丁内容 | 上报 `message` |

```dart
switch (result.error) {
  case PatchApplyError.network || PatchApplyError.ioError:
    break; // 临时问题，稍后再检查
  case PatchApplyError.blacklisted:
    break; // 该补丁曾在本机启动失败，等待修复后的补丁
  default:
    debugPrint('patch rejected: ${result.error?.name} ${result.message}');
}
```

### `PatchApplyProgress`

由 [`applyPatch`](#applypatch) 的 `onProgress` 和 [`applyProgress`](#applyprogress) 发出。

| 字段 | 类型 | 说明 |
|---|---|---|
| `phase` | `PatchApplyPhase` | 当前阶段 |
| `bytesReceived`、`totalBytes` | `int` | 只在 `downloading` 阶段有意义 |
| `fraction` | `double?` | 下载进度，0.0 到 1.0；不在 `downloading` 阶段或大小未知时为 `null` |

### `PatchApplyPhase`

| 取值 | 含义 |
|---|---|
| `downloading` | 下载文件，仅 `applyPatch` 有 |
| `verifying` | 校验 payload 摘要和签名 |
| `finalizing` | 解析补丁、安装资源并提交 |

### `PatchTarget`

由 [`patchTarget`](#patchtarget) 返回。

| 成员 | 类型 | 说明 |
|---|---|---|
| `fileName` | `String` | 本宿主的补丁文件名：flavor 和渠道为默认值时是 `<version_code>-<abi>.fptc`，否则是 `<version_code>-<flavor>-<channel>-<abi>.fptc`。见[补丁文件](cli-zh.md#补丁文件) |
| `versionCode`、`flavor`、`channel`、`abi` | `String` | 构建信息，即 `build` 记录的值 |
| `strategy` | `String` | `so` 或 `bytecode` |
| `fingerprint` | `String` | 宿主构建的指纹；其他指纹的文件会被拒绝 |
| `signed` | `bool` | 宿主是否只接受其补丁密钥签名的文件。构建宿主时确定 |
| `acceptedSeq` | `int` | 本宿主接受过的最大 `seq`（补丁或撤回），从未接受过时为 `0`。只有序号大于它的文件才能安装 |
| `scope` | `Map<String, String>` | `application_id`、`version_code`、`flavor`、`channel`、`abi`、`strategy` 和 `fingerprint` |

### `PatchInspection`

由 [`inspectPatch`](#inspectpatch) 返回。

| 字段 | 类型 | 说明 |
|---|---|---|
| `fresh` | `bool` | 文件头属于本宿主且 `seq` 大于 `acceptedSeq` 时为 `true` |
| `action` | `String?` | 补丁为 `publish`，撤回为 `withdraw`；传入的不是补丁文件头时为 `null` |
| `seq` | `int?` | 文件的序号；传入的不是补丁文件头时为 `null` |
| `reason` | `String?` | 文件不是 `fresh` 的原因：`Patch file of another host`、`Not newer than the accepted patch`，或传入的不是补丁文件头时的解析错误 |

### `PatcherException`

由 [`checkUpdate`](#checkupdate)、[`patchTarget`](#patchtarget) 和 [`inspectPatch`](#inspectpatch) 抛出。

| 字段 | 类型 | 说明 |
|---|---|---|
| `message` | `String` | 原因 |

### `PatchBootDiagnostic`

由 [`lastBootDiagnostic`](#lastbootdiagnostic) 返回。字段和每个 `status` 的含义见[崩溃保护：启动诊断](crash-protection-zh.md#启动诊断)。

### `BlacklistEntry`

由 [`blacklist`](#blacklist) 返回。字段见[崩溃保护：黑名单](crash-protection-zh.md#黑名单)。

## 设备接受哪些文件

无论通过哪个 API 交给插件，安装都经过同一套原生校验，所以下发渠道决定不了运行什么。文件格式见 [CLI 参考：补丁文件](cli-zh.md#补丁文件)。

| 文件 | 结果 |
|---|---|
| 超过 320 MiB；长度、魔数、版本、宿主指纹或 payload 摘要不对；或在签名宿主上缺少签名、签名无效 | 拒绝：`signatureInvalid` |
| 已被拉黑的补丁 | 拒绝：`blacklisted` |
| `seq` 大于 `acceptedSeq` 的补丁 | 安装，`acceptedSeq` 变为它的 `seq`；下次冷启动起运行 |
| 再次安装已安装的那个补丁文件 | 成功，不改变任何状态 |
| 其他 `seq` 不大于 `acceptedSeq` 的补丁 | 拒绝：`invalidArgs` |
| `seq` 大于 `acceptedSeq` 的撤回 | 删除已安装的补丁，`acceptedSeq` 变为它的 `seq`。当前进程继续运行原来的代码，下次冷启动起运行安装包自带的版本 |
| `seq` 不大于 `acceptedSeq` 的撤回 | 拒绝：`invalidArgs` |

`acceptedSeq` 按宿主构建分别记录，所以 App 的新构建（新的指纹）从 0 开始，上一个构建的补丁不再运行。

## 平台支持

插件只在 Android 和 iOS 上工作。在其他平台上，每个调用都不执行任何操作，并在首次调用时打印一条警告：

| 接口 | 在其他平台上 |
|---|---|
| `init`、`rollback`、`clearBlacklist` | 什么都不做 |
| `isAvailable` | `false` |
| `checkUpdate` | 返回没有更新 |
| `applyPatch`、`applyPatchBytes`、`applyPatchFile` | 返回 `unknown` |
| `patchTarget`、`inspectPatch` | 抛出 `PatcherException` |
| `applyProgress` | 空流 |
| `currentVersion`、`lastBootDiagnostic`、`appVersionCode` | `null` |
| `deviceAbi` | `''` |
| `blacklist` | 空列表 |

在 Android 和 iOS 上，不是用 `dart run flutter_patcher build` 构建的 App 不接收补丁：`isAvailable` 为 `false`，`checkUpdate` 返回没有更新，`patchTarget` 和 `inspectPatch` 抛出 `PatcherException`，`applyPatch`、`applyPatchBytes` 和 `applyPatchFile` 返回 `unknown`。
