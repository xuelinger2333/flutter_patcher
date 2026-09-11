# API 参考

[English](api-reference.md) | **简体中文**

`flutter_patcher` 的公开 API 都通过 `FlutterPatcher` 静态类调用。

目前插件仅在 Android 平台执行补丁逻辑。
在 iOS、Web、macOS、Windows、Linux 等非 Android 平台调用这些 API 时，不会执行补丁操作，也不会抛出异常；插件会在首次调用时打印 warning，并返回安全默认值。

---

## 初始化

在 `runApp()` 之前调用：

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterPatcher.init();

  runApp(const MyApp());
}
```

大多数项目无需传参。`init()` 会准备补丁加载、崩溃保护和启动状态记录。重复调用是安全的。

如需开启签名校验、调整熔断阈值或兼容特殊 Flutter 版本，可以覆盖默认参数：

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MFkwEwYH...==',
  maxCrashCount: 1,
  strictSignature: true,
  loaderFieldCandidates: ['flutterLoader'],
  loaderFallbackHeuristic: false,
  verifyAfter: const Duration(seconds: 5),
);
```

| 参数                        | 说明                         |
| ------------------------- | -------------------------- |
| `publicKeyBase64`         | Ed25519 公钥。`PatchInfo.signature` 为空时跳过签名校验；补丁带签名但未配置公钥会拒绝应用 |
| `maxCrashCount`           | 连续崩溃多少次后熔断补丁，默认 `1`        |
| `strictSignature`         | 按既有兼容策略，API < 33 遇到带签名补丁时是否拒绝应用；API ≥ 33 时该开关无影响，始终使用插件内置的 Ed25519 实现验签 |
| `loaderFieldCandidates`   | FlutterLoader 字段名候选，一般无需修改 |
| `loaderFallbackHeuristic` | 候选字段失败后是否启用兜底扫描            |
| `verifyAfter`             | 启动后用于判断补丁稳定的保护窗口           |

---

## 检查更新（可选）

> 插件提供一个可选的最小 check-update JSON 协议，主要用于快速接入、示例和本地联调。生产环境如果已有自己的更新、灰度或鉴权协议，建议直接解析业务响应并构造 `PatchInfo`，跳过本节。

如果你使用插件内置的 check-update 协议，可以直接调用 `checkUpdate`：

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
  log.warning('check update failed: ${e.message}');
}
```

`checkUpdate` 返回 `PatchCheckResult`：

| 字段          | 类型           | 说明                |
| ----------- | ------------ | ----------------- |
| `hasUpdate` | `bool`       | 是否有可用补丁           |
| `patch`     | `PatchInfo?` | 补丁信息。无更新时为 `null` |

如果你的服务端已有自己的更新协议，可以跳过 `checkUpdate`，直接构造 `PatchInfo` 后调用 `applyPatch`。

---

## 应用补丁

补丁有两种应用方式：

* `applyPatch`：传入补丁 URL，由插件负责下载，推荐大多数场景使用。
* `applyPatchBytes`：传入内存中的补丁字节，适合自定义下载、asset 加载或 isolate 场景。

补丁应用成功后，会在 **下次冷启动** 生效；不会在当前进程内立即替换代码。

### 方式一：插件下载补丁

```dart
final result = await FlutterPatcher.applyPatch(
  PatchInfo(
    version: '1.0.0-h1',
    patchUrl: 'https://cdn.example.com/libapp.so',
    md5: '0123456789abcdef0123456789abcdef',
    targetVersionCode: 100,
  ),
  onProgress: (p) {
    print('${p.phase.name}: ${p.fraction ?? "..."}');
  },
);

if (result.ok) {
  showRestartHint();
}
```

`targetVersionCode` 表示补丁适用的宿主 APK `versionCode`，不是补丁版本号。
例如线上 APK 的 `versionCode` 是 `100`，那么面向这个 APK 的补丁也应填写 `targetVersionCode: 100`。

如果线上同时存在多个 APK 版本，需要为不同 `versionCode` 分别构建和下发补丁。

### 方式二：传入补丁字节

```dart
final bytes = await loadPatchFromYourSource();

final result = await FlutterPatcher.applyPatchBytes(
  bytes,
  version: '1.0.0-h1',
  targetVersionCode: 100,
  onProgress: (p) => print(p.phase.name),
);
```

`applyPatchBytes` 会自动计算 MD5、处理临时文件，然后复用 `applyPatch` 的主流程。

---

## 处理应用结果

`applyPatch` 和 `applyPatchBytes` 都返回 `PatchApplyResult`。

```dart
if (result.ok) {
  // 补丁已保存，下次冷启动生效
  showRestartHint();
} else {
  switch (result.error!) {
    case PatchApplyError.blacklisted:
      // 该补丁曾导致崩溃，不应继续下发
      break;

    case PatchApplyError.network:
    case PatchApplyError.ioError:
      // 可稍后重试
      break;

    case PatchApplyError.md5Mismatch:
      // CDN 文件或服务端 MD5 可能不一致
      break;

    case PatchApplyError.signatureInvalid:
      // 补丁签名无效，应上报安全事件
      break;

    default:
      log.warning('patch failed: ${result.error?.name} / ${result.message}');
  }
}
```

`result.message` 面向开发者排查问题，不建议直接展示给用户。

同一个补丁重复应用是安全的；如果补丁已经存在，会返回 `ok = true`。

---

## 错误码

| 错误码                 | 含义                              | 建议处理                 |
| ------------------- | ------------------------------- | -------------------- |
| `invalidArgs`       | 参数缺失或格式错误                       | 检查服务端下发内容            |
| `blacklisted`       | 补丁命中本地黑名单                       | 停止下发该补丁              |
| `network`           | 下载失败                            | 稍后重试                 |
| `md5Mismatch`       | 下载文件 MD5 不匹配（仅在下发了 md5 时才会触发） | 检查 CDN 或服务端 MD5      |
| `signatureInvalid`  | 签名校验失败                          | 上报安全事件，不重试           |
| `unsupportedAbi`    | `patch.zip` 不包含当前设备 ABI 的 `libapp.so` | 按 ABI 分发不同 ZIP，或在服务端按 ABI 过滤 |
| `assetPackageInvalid` | `patch.zip` 内容损坏或过期：schema 不支持、ZIP 路径不安全、引用的覆盖文件不在 ZIP 内、读不到基准 APK 的 Flutter 资源表、未知 op 等 | 用相同 Flutter 工具链重建 release APK，再用当前 `pack` CLI 重新打包；详见 [资源补丁](#资源补丁) |
| `ioError`           | 文件写入、rename 或权限失败               | 稍后重试                 |
| `unknown`           | 未分类异常                           | 查看 `result.message`  |

---

## 监听进度

除了 `onProgress`，也可以监听全局广播流：

```dart
FlutterPatcher.applyProgress.listen((p) {
  print('${p.phase.name}: ${p.fraction}');
});
```

| 字段              | 说明                                                          |
| --------------- | ----------------------------------------------------------- |
| `phase`         | 当前阶段：`downloading`、`verifying`、`finalizing` |
| `bytesReceived` | 已下载字节数，仅下载阶段有意义                                             |
| `totalBytes`    | 总字节数，服务端未返回时为 `-1`                                           |
| `fraction`      | 下载进度，范围 `0.0 ~ 1.0`；未知时为 `null`                             |

---

## 回滚补丁

```dart
await FlutterPatcher.rollback();
```

回滚会删除当前补丁。下次冷启动时，应用会回到 APK 内置版本。

手动回滚不会把补丁加入黑名单。

---

## 主动确认启动成功

```dart
await FlutterPatcher.reportBootSuccess();
```

通常不需要手动调用。`init()` 会在首帧渲染后自动确认本次启动成功。

只有当你希望在首帧之前用自定义逻辑确认补丁可用时，才需要显式调用：

```dart
await runLightweightSelfCheck();
await FlutterPatcher.reportBootSuccess();
```

首帧之后再次调用是 no-op。

---

## 查询状态

```dart
final int? code = await FlutterPatcher.appVersionCode;
final String? version = await FlutterPatcher.currentVersion;
final String abi = await FlutterPatcher.deviceAbi;
```

| API              | 说明                                                  |
| ---------------- | --------------------------------------------------- |
| `appVersionCode` | 当前 APK 的 `versionCode`。API 28+ 使用 `longVersionCode` |
| `currentVersion` | 磁盘上当前已就绪的补丁版本（来自 `meta.json`）。`applyPatch` 成功后立即可读到新版本，但需冷启动后 Flutter Engine 才会加载生效；无补丁时为 `null` |
| `deviceAbi`      | 当前设备 ABI，可用于 check-update 请求                        |

---

## 启动诊断

每次冷启动后，原生侧会记录一次补丁加载结果。可以通过 `lastBootDiagnostic` 读取并上报：

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;

if (diag != null && !diag.isHealthy) {
  analytics.report('patch_dropped', {
    'status': diag.status.name,
    'patch_version': diag.patchVersion,
    'crash_count': diag.crashCount,
    'message': diag.message,
  });
}
```

`PatchBootDiagnostic` 字段：

| 字段                       | 类型                | 说明                              |
| ------------------------ | ----------------- | ------------------------------- |
| `status`                 | `PatchBootStatus` | 启动结果                            |
| `recordedAt`             | `DateTime`        | 诊断记录时间                          |
| `patchVersion`           | `String?`         | 涉及的补丁版本                         |
| `patchTargetVersionCode` | `int?`            | 补丁声明的目标 `versionCode`           |
| `appVersionCode`         | `int?`            | 当前 APK 的 `versionCode`          |
| `crashCount`             | `int?`            | 当前累计崩溃次数                        |
| `attemptedLoaderFields`  | `List<String>?`   | hook 失败时尝试过的字段名                 |
| `message`                | `String?`         | 开发者诊断信息                         |
| `isHealthy`              | `bool`            | `patched` 或 `noPatch` 时为 `true` |

`PatchBootStatus` 取值：

| 值                            | 含义                    | 建议处理                                   |
| ---------------------------- | --------------------- | -------------------------------------- |
| `patched`                    | 补丁加载成功                | 正常                                     |
| `noPatch`                    | 无补丁，使用 APK 内置版本       | 正常                                     |
| `droppedVersionCodeMismatch` | APK 已升级，旧补丁失效         | 通常无需告警                                 |
| `droppedCircuitBreaker`      | 补丁导致连续崩溃，已熔断          | 强告警，停止下发该补丁                            |
| `droppedSignatureInvalid`    | 签名校验失败                | 告警，检查补丁来源                              |
| `droppedMd5Mismatch`         | 本地文件与记录的 MD5 不一致      | 上报并排查                                  |
| `droppedMetaCorrupted`       | 补丁元数据损坏               | 上报并排查                                  |
| `hookInstallFailed`          | FlutterLoader hook 失败 | 检查 Flutter 版本或 `loaderFieldCandidates` |
| `unknown`                    | 未分类异常                 | 查看 `message`                           |

调试时可以参考 `example/lib/diag_card.dart`，在真机上直接查看诊断结果。

---

## 黑名单

当某个补丁导致启动崩溃或校验失败时，插件会将其加入本地黑名单，避免反复应用同一个问题补丁。

```dart
final entries = await FlutterPatcher.blacklist;

for (final e in entries) {
  print('${e.version} / ${e.md5} / ${e.reason} / ${e.blacklistedAt}');
}
```

调试时可以清空黑名单：

```dart
await FlutterPatcher.clearBlacklist();
```

`BlacklistEntry` 字段：

| 字段              | 类型         | 说明     |
| --------------- | ---------- | ------ |
| `version`       | `String`   | 补丁版本   |
| `md5`           | `String`   | 补丁文件 MD5 |
| `reason`        | `String`   | 入黑原因   |
| `blacklistedAt` | `DateTime` | 入黑时间   |

常见 `reason`：

| 值                   | 说明       |
| ------------------- | -------- |
| `BOOT_CRASH`        | 补丁导致启动崩溃 |
| `MD5_MISMATCH`      | MD5 校验失败 |
| `SIGNATURE_INVALID` | 签名校验失败   |

---

## PatchInfo

`PatchInfo` 描述一个可应用的补丁。

```dart
final patch = PatchInfo(
  version: '1.0.0-h1',
  patchUrl: 'https://cdn.example.com/libapp.so',
  md5: '0123456789abcdef0123456789abcdef',
  targetVersionCode: 100,
);
```

也可以从服务端 JSON 构造：

```dart
final patch = PatchInfo.fromJson(json);
final map = patch.toJson();
```

`fromJson` 同时兼容驼峰和下划线字段名，未知字段会保留在 `raw` 中。

| 字段                  | 类型                     | 必填        | 说明                        |
| ------------------- | ---------------------- | --------- | ------------------------- |
| `version`           | `String`               | 是         | 补丁版本标识，自定义字符串             |
| `patchUrl`          | `String`               | 是         | 补丁下载地址                    |
| `md5`               | `String`               | 否         | 补丁文件 MD5，小写 32 位 hex；为空字符串时跳过 MD5 校验（同时签名校验也会一并跳过） |
| `signature`         | `String`               | 否         | Ed25519 签名，Base64。为空时跳过验签。仅在 `md5` 非空时生效 |
| `targetVersionCode` | `int?`                 | 推荐        | 补丁适用的宿主 APK `versionCode` |
| `raw`               | `Map<String, dynamic>` | 否         | `fromJson` 保留的原始字段        |

---

## 异常行为

只有 `checkUpdate` 会抛出 `PatcherException`，通常表示网络失败或响应 JSON 无法解析。

其他 API 不抛异常，而是通过返回值报告结果。

```dart
try {
  final check = await FlutterPatcher.checkUpdate(url);
} on PatcherException catch (e) {
  log.warning(e.message);
}
```

---

## pack CLI

`flutter_patcher:pack` 用于从 release APK 中提取 `libapp.so`（并可选地提取 Flutter 资源覆盖），生成补丁元数据。

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.0-h1 \
  --target-version-code 100
```

| 参数                            | 说明                                                       |
| ----------------------------- | -------------------------------------------------------- |
| `--apk <path>`                | 必填，release APK 路径                                        |
| `--version <string>`          | 必填，补丁版本标识                                                |
| `--target-version-code <int>` | 必填，补丁适用的宿主 APK `versionCode`                             |
| `--abi <string>`              | 可选，默认按 `arm64-v8a`、`armeabi-v7a`、`x86_64` 顺序选择           |
| `--assets <KEY[,KEY...]>`     | 可选，要覆盖的 Flutter 资源 key 列表，逗号分隔。也可写成 `@path/to/list.txt` 从 UTF-8 文本文件读取（每行一个 key，`#` 开头为注释）；内联与 `@file` 可混用，如 `--assets @list.txt,assets/extra.png`。详见 [资源补丁](#资源补丁) |
| `--out <dir>`                 | 可选，输出目录，默认 `dist/`                                       |

`--target-version-code` 绑定的是用户设备上已安装的基准 APK。

例如：

* 线上 APK 的 `versionCode` 是 `100`
* 你要为该版本发布补丁 `1.0.0-h1`
* 那么 `--target-version-code` 应填写 `100`

如果 APK 升级到新的 `versionCode`，旧补丁会自动失效。
如果线上同时存在多个 `versionCode`，请分别为每个基准版本构建补丁。

构建产物（恒为 `schemaVersion: 2`，`payload: patch.zip`）：

```text
dist/
├── patch.zip
└── manifest.json
```

将两个文件上传 CDN，更新接口返回 `manifest.json` 即可，插件读取 `manifest.payload` 后下载 `patch.zip`。未传 `--assets` 时，`patch.zip` 内只含 `manifest.json` + `lib/<abi>/libapp.so`（内部 manifest 不包含 `assets` 块）；传了 `--assets` 时，额外内嵌 `manifest_patch.json` 和每个 key 的覆盖文件。详见 [资源补丁](#资源补丁)。

---

## 资源补丁

自 0.1.3 起，Flutter 资源（图片、字体、JSON 等）可以和 Dart 代码一起通过 v2 `patch.zip` 热更新。调用代码不需要改动 —— `Image.asset('assets/hero.png')`、`rootBundle.load('assets/strings/zh.json')` 等保持原样；下次冷启动时插件会在同样的 key 下覆盖新的字节。

### 工作流

1. 重新构建一个 release APK，其中包含改动后的资源（以及任何引用它们的 Dart 代码），并确保资源在 `pubspec.yaml` 中已声明。
2. 用 `--assets` 列出要覆盖的资源 key 进行打包：

   ```bash
   dart run flutter_patcher:pack \
     --apk path/to/patched-release.apk \
     --version 1.0.1 \
     --target-version-code 2 \
     --assets assets/hero.png,assets/strings/zh.json
   ```

   key 较多时，把 `--assets` 指向一个文本文件，前缀 `@`（每行一个 key，`#` 开头为注释），内联与 `@file` 可在同一个参数里混用：

   ```bash
   dart run flutter_patcher:pack \
     --apk path/to/patched-release.apk \
     --version 1.0.1 \
     --target-version-code 2 \
     --assets @patch-assets.txt,assets/last-minute.png
   ```

3. 将 `dist/patch.zip` 上传到 CDN。`dist/manifest.json` 是给**你自己的更新后端**看的旁路文件，里面有版本、MD5、目标 `versionCode`、以及载荷文件名（`payload: patch.zip`）。插件本身只看到你后端通过 `PatchInfo` 下发的内容 —— 请让 `PatchInfo.patchUrl` 指向你托管的 `patch.zip`。

### 载荷结构（`patch.zip`, v2）

```text
manifest.json          # 内层清单，schemaVersion 2（lib 映射 + 可选 assets 块）
manifest_patch.json    # 资源表差量操作（只有打了资源时才存在）
lib/<abi>/libapp.so    # 补丁后的 Dart 代码（始终存在）
assets/<asset-path>    # 覆盖字节，每个 path（及每个分辨率变体）一条
```

纯 Dart 的 `patch.zip`（未传 `--assets`）只包含第一项和第三项；内层 manifest 没有 `assets` 块，`manifest_patch.json` 也不存在。

外层 `manifest.json`（本地联调时由 `mock_server` 消费，生产环境由你的更新后端消费）携带 `schemaVersion`、`version`、`targetVersionCode`、`abi`、`payload: patch.zip` 和整包 MD5。内层 `manifest.json`（位于 ZIP 内部）列出 `libapp.so` 与每个覆盖文件的逐文件 MD5。插件只消费内层的；外层的不会单独进设备。

### `manifest_patch.json` schema

```json
{
  "schemaVersion": 1,
  "manifestFormat": "bin",
  "baseManifestSize": 322,
  "operations": [
    {
      "op": "upsert",
      "key": "assets/hero.png",
      "variants": [
        { "asset": "assets/hero.png" },
        { "asset": "assets/2.0x/hero.png" }
      ]
    }
  ]
}
```

| 字段         | 含义                                                       |
| ---------- | -------------------------------------------------------- |
| `op`       | 目前仅支持 `upsert`                                           |
| `key`      | 在 `pubspec.yaml` `assets:` 下登记的 Flutter 资源路径             |
| `variants` | 自动从补丁版 APK 的 Flutter 资源表中读取的分辨率变体（`1.0x`、`2.0x` 等）       |

**安装阶段**（不是冷启动）插件把这些 op 合并进 APK 的基准资源表，把合并后的资源表与覆盖文件一起写到补丁的私有目录，并打成一个私有 `flutter_assets.apk`。冷启动时 [`LoaderHook`](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/LoaderHook.kt) 安装一个 patched `FlutterLoader` + `FlutterJNI` AssetManager，把 Flutter 的资源读取重定向到补丁目录；补丁没动过的 path 仍走 APK fallback。

### 资源路径要求

* 传给 `--assets` 的每个 path 必须已在**补丁版 APK** 的 `pubspec.yaml` `assets:` 下登记。`pack` 会把 path 和 APK 的 Flutter 资源表对照；Flutter 没编进 APK 的 path 会报错。
* 可以通过补丁新增资源，前提是在 `pubspec.yaml` 中登记、构建包含该资源的新 release APK，再基于该 APK 打包。
* **不能删除** base APK 已有的资源 —— overlay 只能在已有 path 上替换字节。
* 设备端按 Flutter 标准方式解析变体；你不需要枚举每个 `2.0x/`、`3.0x/`，打包器会自动展开。

### ABI 处理

单个 `patch.zip` 只携带 **一个** ABI 的 `libapp.so`。不匹配时插件返回 `unsupportedAbi`。可选方案：

* 按 ABI 各打一份 ZIP（`--abi arm64-v8a`、`--abi armeabi-v7a`……），服务端根据 `deviceAbi` 路由；
* 如果应用只发 `arm64-v8a` 和 `armeabi-v7a`，可以接受按 ABI 分发的少量额外成本。

### 校验错误

安装阶段下列任一情况，插件返回 `assetPackageInvalid`：

* 内层 `schemaVersion` 未知
* 未识别的资源 `mode`（目前只支持 `overlay`）
* ZIP 条目路径不安全（绝对路径、含 `..`、含 NUL 字节）
* 基准 APK 缺少 overlay 需要合并的 Flutter 资源表（请用相同 Flutter 工具链重建 APK）
* 内层 manifest 中声明的覆盖文件不在 ZIP 内
* 内层 manifest 的逐文件 MD5 与实际字节不一致

### 安全

服务端下发响应里的整包 MD5 / 签名覆盖整个 `patch.zip`。内层逐文件 MD5 仅作为解包阶段的完整性校验，不是独立的安全面 —— 生产环境务必启用外层签名。

### 各阶段做了什么

`applyPatch` 阶段做所有重活，冷启动只校验和加载。具体：

**`applyPatch` 调用期间（安装阶段）：**

1. 把 `patch.zip` 下载到临时文件；校验整包 MD5 + Ed25519 签名（用 `PatchInfo` 中带的值）。
2. 打开 ZIP，校验内层 `schemaVersion` 与逐文件 MD5。
3. 把 `lib/<abi>/libapp.so` 解压到 staging。
4. 如果补丁带资源：把 APK 的 `flutter_assets/` 拷到 staging、按内层 manifest 列出的 path 逐个 overlay、把 overlay 操作合并进资源表、然后把结果打成一个私有 `flutter_assets.apk`。
5. 把 staging 的产物原子地提交到 `current/`（详见 [架构 → Atomic install](architecture-zh.md#atomic-install)）。

**下一次冷启动：**

1. 校验 `current/` 与宿主 APK 的 `versionCode` 匹配，且磁盘上的 `libapp.so` 仍然与 meta 中的 MD5 一致。
2. [`LoaderHook`](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/LoaderHook.kt) 安装 patched `FlutterLoader` + `FlutterJNI` AssetManager，把 Flutter 指向补丁的 `libapp.so` 与（若有资源）私有 `flutter_assets.apk`。

如果校验失败，或进程内的崩溃熔断触发，补丁会被丢弃，下次冷启动回退到 APK 内置版本。

---

## 性能与支持范围

### 性能影响

| 指标       | 影响                                |
| -------- | --------------------------------- |
| APK 体积增量 | 约 80–120 KB                       |
| 启动耗时增量   | 约 5–15 ms                         |
| 运行时内存    | 补丁加载后无额外常驻占用                      |
| 补丁文件大小   | 通常 5–15 MB                          |

> 以上数据基于 Pixel 6 / Flutter 3.24 测量。实际结果会受设备、Flutter 版本和构建配置影响。

### 支持范围

完整兼容性表格见 [环境要求](../README-zh.md#环境要求)。

非 Android 平台调用 API 时会 no-op：首次调用打印 warning，随后返回安全默认值，不抛异常。

---

## 版本兼容

* `0.x` 阶段 API 仍可能调整，建议在 `pubspec.yaml` 中固定版本号。
* `PatchBootStatus` 和黑名单 `reason` 保持前向兼容；新增值在旧版本 SDK 中会归为 `unknown`。
* `PatchInfo.fromJson` 兼容驼峰和下划线字段名，未知字段会保留在 `raw` 中，不影响解析。
