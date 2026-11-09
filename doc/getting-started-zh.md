<!-- ========================================== -->
<!-- doc/getting-started-zh.md (简体中文)        -->
<!-- ========================================== -->

# 快速上手

[English](getting-started.md) | **简体中文**

**目标**：给一个 Flutter App 接入 `flutter_patcher`，改一行界面文字，在 Android 手机上冷启动后看到这处变化。全程在本机完成，不需要服务器、密钥，也不需要 `flutter_patcher.yaml`。首次约 15 分钟，其中几分钟用于下载引擎。

iOS 的差异见文末，命令的全部参数见 [CLI 参考](cli-zh.md)。

## 开始之前

| 需要 | 检查方法 |
|---|---|
| Linux x64、Windows x64 或 Apple Silicon Mac，已安装 Git | `git --version` |
| Flutter 3.47.0 – 3.47.9，在 `PATH` 中 | `flutter --version` |
| 一台 Android 9 及以上、`arm64-v8a` 的手机，已开启 USB 调试 | `adb devices` 列出这台手机 |
| 一个 Flutter 项目，`pubspec.yaml` 的 `version` 带构建号，例如 `1.0.0+1` | `flutter create` 新建的项目默认如此 |
| 首次运行时能访问 GitHub | 引擎和工具从这里下载，之后使用本机缓存 |

## 第 1 步：接入插件

**目标**：App 能检查并安装补丁。

**操作**：

1. 在项目根目录执行：

   ```bash
   flutter pub add flutter_patcher
   dart run flutter_patcher doctor
   ```

2. 把 `lib/main.dart` 中的 `main()` 换成下面的代码，并加上 `checkForPatch()`。App 每次启动都会检查一次更新：

   ```dart
   import 'package:flutter/material.dart';
   import 'package:flutter_patcher/flutter_patcher.dart';

   Future<void> main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await FlutterPatcher.init();
     runApp(const MyApp());
     checkForPatch();
   }

   Future<void> checkForPatch() async {
     try {
       final check = await FlutterPatcher.checkUpdate();
       if (!check.hasUpdate) return;
       final result = await FlutterPatcher.applyPatch(check.patch!);
       debugPrint('applyPatch: $result');
     } on PatcherException catch (e) {
       debugPrint('checkUpdate failed: $e');
     }
   }
   ```

   `checkUpdate()` 请求 `<url>/<文件名>`，只读取前 146 字节（文件头），据此判断这个文件对本 App 是否是新的。`<url>` 是 `build` 写进 App 的地址：`flutter_patcher.yaml` 中的 `url`；没有配置时为 `http://127.0.0.1:8686`，也就是第 4 步中 `serve` 提供补丁的地址。显式传入效果相同：`checkUpdate(url: 'http://127.0.0.1:8686')`。

**验证**：

- `doctor` 最后一行以 `Toolchain ready.` 开头。首次运行会下载引擎，需要几分钟。
- `flutter analyze` 输出 `No issues found!`。

`doctor` 失败时，按输出中的错误码查[错误码与排障](troubleshooting-zh.md)。

`checkUpdate` 只是一个内置的下载器。App 也可以用任何其他方式拿到补丁文件，自己安装，见[自己获取补丁文件](#自己获取补丁文件)。

## 第 2 步：构建并安装 App

**目标**：手机上装好一个能接收补丁的 App。

**操作**：

```bash
dart run flutter_patcher build android
adb install <output>/app-release.apk
```

`<output>` 是 `build` 输出的 JSON 中 `output` 字段的目录。

**验证**：

- `build` 输出的最后一行是一行简短的 JSON 摘要，含 `"status":"build_archived"`；`app` 是要安装的 APK，位于 `.dart_tool/flutter_patcher/releases/<时间戳>/`，`report` 是旁边的完整构建报告。
- 同时会出现三条警告，试用阶段都属正常：
  - `WARNING: UNSIGNED`：这个 App 接受未签名的补丁文件。签名是可选的，见[生产部署：开启签名](production-playbook-zh.md#3-可选开启签名)。
  - `WARNING: URL_LOCAL`：App 检查的是 `serve` 的本机地址。
  - `WARNING: BASELINE_STORE_LOCAL`：这次构建的每个补丁都要用到的基线，只保存在项目的 `.flutter_patcher/baselines/` 中。
- 手机上能打开这个 App。

## 第 3 步：修改代码并生成补丁

**目标**：得到一个包含你的修改的补丁文件。

**操作**：

1. 在 `lib/main.dart` 中改一处界面上看得到的文字，例如标题。**不要改 `pubspec.yaml` 中的 `version`**：补丁靠它找到第 2 步的构建。
2. 执行：

   ```bash
   dart run flutter_patcher patch android
   ```

**验证**：输出的 JSON 含 `"status":"patch_created"`，`changed` 中列出 `package:<你的包名>/main.dart`，`file` 是补丁文件，例如 `.dart_tool/flutter_patcher/patches/<时间戳>/1-arm64-v8a.fptc`。文件名是 `<version_code>-<abi>.fptc`，flavor 或渠道不是默认值时还包含两者（见[补丁文件](cli-zh.md#补丁文件)）；`seq` 是它的序号，即生成时的 Unix 秒数。

如果改动包含补丁无法携带的内容（例如原生代码），命令会失败并给出错误码，例如 `PATCH_NATIVE_CHANGE`，见[错误码与排障](troubleshooting-zh.md)。

## 第 4 步：把补丁发到手机

**目标**：手机下载并安装补丁。

**前提**：手机通过 USB 连着这台电脑。

**操作**：

1. 另开一个终端，在项目根目录执行下面的命令，并保持运行：

   ```bash
   dart run flutter_patcher serve
   ```

   `serve` 在 `http://127.0.0.1:8686` 按原样提供 `patch` 最新写出的文件，并用 `adb reverse` 把这个端口映射到手机上。它只是调试工具：不发布、不编号、不签名。

2. 在手机上打开 App；如果已经打开，先从最近任务中划掉再重新打开。App 启动时会执行 `checkForPatch()`。

**验证**：

- `serve` 的终端在启动说明之后依次输出：

  ```text
  Android device <serial> reaches this computer at 127.0.0.1:8686
  Offering patch <seq> (1-arm64-v8a.fptc, unsigned)
  A device checked for updates
  A device downloaded 1-arm64-v8a.fptc
  ```

- `adb logcat -s flutter` 中出现 `applyPatch: PatchApplyResult(ok)`。

## 第 5 步：冷启动，看到变化

**目标**：运行补丁。

**操作**：从最近任务中划掉 App，再重新打开。

**验证**：界面上显示第 3 步改过的文字。

之后每次修改代码：保持 `serve` 运行，执行 `patch android`，再重复第 4、5 步。`serve` 约 2 秒内发现新文件，每次输出的 `Offering patch <seq> ...` 序号都更大；设备只安装序号高于它此前接受过的所有文件的补丁。

## 回到安装包自带的版本

```bash
dart run flutter_patcher patch android --withdraw
```

这条命令以同一个文件名写出第 2 步那次构建的撤回文件；它只需要基线，不做任何编译。`serve` 输出 `Offering a withdrawal of <文件名> ...`。打开 App 让它应用撤回，再冷启动：App 重新运行安装包自带的版本。`FlutterPatcher.rollback()` 的效果相同，但只作用于这一台手机。

## 自行分发

自己分发补丁只需要 `build` 和 `patch`；`serve` 只用于开发。把 `patch` 写出的文件放在任何地方，例如你自己的服务器、CDN 或其他渠道，然后二选一：

- 由内置下载器获取：`checkUpdate(url: …)`，或在 `build` 之前于 `flutter_patcher.yaml` 中设置 `url` 后调用 `checkUpdate()`。文件必须位于 `<url>/<文件名>`，文件名即 `(await FlutterPatcher.patchTarget).fileName`。地址必须是 HTTPS，指向设备本机（`127.0.0.1`、`[::1]`、`localhost`）时除外；`404` 表示没有更新；不跟随重定向；不要求支持范围请求；
- 或者自己获取，再交给 `applyPatchBytes` / `applyPatchFile`，见下文。

`patch` 输出 `"file":null` 时，表示宿主开启了签名而本机没有它的补丁私钥：执行 `keys import` 后重新 patch。

### 自己获取补丁文件

插件不一定要负责下载。App 从自家接口、推送消息、文件选择或自身资源中拿到补丁文件后，把字节交给 `applyPatchBytes`（或把路径交给 `applyPatchFile`）即可。`patchTarget` 说明这次构建需要哪个文件。下面是一个使用 `http` 包的示例：

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_patcher/flutter_patcher.dart';
import 'package:http/http.dart' as http;

Future<void> fetchPatch() async {
  final target = await FlutterPatcher.patchTarget;
  // 由你的服务端选文件：依据 target.fileName（或 versionCode、flavor、
  // channel、abi）以及 target.acceptedSeq，即这个 App 最近接受的序号。
  final response = await http.get(
    Uri.parse(
      'https://api.example.com/patches/${target.fileName}'
      '?after=${target.acceptedSeq}',
    ),
  );
  if (response.statusCode != 200) return;
  final result = await FlutterPatcher.applyPatchBytes(response.bodyBytes);
  debugPrint('applyPatchBytes: $result');
}
```

文件就是 `patch` 或 `publish` 写出的 `.fptc`。无论通过什么方式送达，设备都按同样的规则校验。全部 API 见 [API 参考](api-reference-zh.md)。

## iOS 的不同之处

| 环节 | 与 Android 的区别 |
|---|---|
| 构建 | `build ios` 只能在 Apple Silicon Mac 上运行，需要先在 Xcode 中配置好签名（Team 和 Bundle ID）。装到自己的手机上测试时加 `--export-method development`；默认的 `app-store` 需要发布证书。产物是输出目录中的 `app-release.ipa` |
| 代码签名 | 在 Mac 的桌面终端中运行 `build ios`。通过 SSH 或在 CI 中运行时，需要先解锁钥匙串，否则签名失败并报 `errSecInternalComponent` |
| 安装 | 例如在 Xcode 的 Devices and Simulators 窗口中添加 ipa。用免费开发者账号签名时，先在手机的“设置 → 通用 → VPN 与设备管理”中信任该开发者 |
| 生成补丁 | `patch ios` 可在 Mac、Linux 或 Windows 上运行，只要这台电脑能读到 `build ios` 保存的基线。文件名形如 `1-ios-arm64.fptc` |
| 下发补丁 | iPhone 访问不到电脑的 `127.0.0.1`，而 `checkUpdate` 只对 `127.0.0.1`/`localhost` 允许明文 HTTP。可以用隧道把 `serve` 暴露为 HTTPS 地址，例如 `cloudflared tunnel --url http://127.0.0.1:8686`，再把得到的地址传给 `checkUpdate(url: 'https://…')`；也可以用其他方式把 `.fptc` 送到手机上，[自己安装](#自己获取补丁文件) |

## 下一步

- 补丁能改什么、不能改什么：[工作原理](architecture-zh.md)
- 托管补丁文件、签名、撤回与回退：[生产部署](production-playbook-zh.md)
- 补丁导致启动失败时会发生什么：[崩溃保护](crash-protection-zh.md)
