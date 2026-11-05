<!-- ========================================== -->
<!-- doc/getting-started-zh.md (简体中文)        -->
<!-- ========================================== -->

# 快速上手

[English](getting-started.md) | **简体中文**

**目标**：给一个 Flutter App 接入 `flutter_patcher`，改一行界面文字，在 Android 手机上冷启动后看到这处变化。全程在本机完成，不需要服务器。首次约 15 分钟，其中几分钟用于下载引擎。

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
       final check = await FlutterPatcher.checkUpdate('http://127.0.0.1:8686');
       if (!check.hasUpdate) return;
       final result = await FlutterPatcher.applyPatch(check.patch!);
       debugPrint('applyPatch: $result');
     } on PatcherException catch (e) {
       debugPrint('checkUpdate failed: $e');
     }
   }
   ```

   `http://127.0.0.1:8686` 是第 5 步 `serve` 提供的本机地址；上线时换成你自己的 HTTPS 地址，见[生产部署](production-playbook-zh.md)。

3. 在 `android/app/src/main/AndroidManifest.xml` 的 `<manifest>` 下加入网络权限。`flutter create` 只给 debug 和 profile 包声明了它：

   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   ```

**验证**：

- `doctor` 的最后一行以 `Toolchain ready.` 开头。首次运行要下载引擎，需要几分钟。
- `flutter analyze` 输出 `No issues found!`。

`doctor` 失败时，按输出中的错误码查[错误码与排障](troubleshooting-zh.md)。

## 第 2 步：生成密钥

**目标**：生成给补丁签名的密钥。每个项目只需一次。

**操作**：

```bash
dart run flutter_patcher keys init
```

**验证**：输出中有 `"status":"keys_created"`，项目根目录出现 `flutter_patcher.yaml`。

密钥的保存与备份见[生产部署：备份密钥](production-playbook-zh.md#第-1-步备份密钥)。

## 第 3 步：构建并安装 App

**目标**：得到能接收补丁的安装包，并装到手机上。

**操作**：

```bash
dart run flutter_patcher build android
adb install <output>/app-release.apk
```

`<output>` 是 `build` 输出的 JSON 中 `output` 字段的目录。

**验证**：

- `build` 输出的最后一行 JSON 中有 `"status":"build_archived"`；`output` 指向 `.dart_tool/flutter_patcher/releases/<时间戳>/`，其中有 `app-release.apk`。
- 同时出现一行 `WARNING: BASELINE_STORE_LOCAL`。表示基线只保存在项目里，这是正常的；上线前请看[生产部署：保管好这两个目录](production-playbook-zh.md#保管好这两个目录)。
- App 在手机上能正常打开。

## 第 4 步：修改代码，生成补丁

**目标**：得到包含这次改动的补丁。

**操作**：

1. 修改 `lib/main.dart` 中一处界面上看得见的文字，例如标题。**不要修改 `pubspec.yaml` 的 `version`**，补丁按它找到第 3 步的版本。
2. 执行：

   ```bash
   dart run flutter_patcher patch android
   ```

**验证**：输出 JSON 中有 `"status":"patch_created"`，`changed` 中列出 `package:<你的包名>/main.dart`；`.dart_tool/flutter_patcher/patches/<时间戳>/` 下有 `patch.draft` 和 `patch.json`。

改动了补丁不能包含的内容（例如原生代码）时，命令失败并给出错误码，例如 `PATCH_NATIVE_CHANGE`，见[错误码与排障](troubleshooting-zh.md)。

## 第 5 步：把补丁发到手机

**目标**：手机下载并安装补丁。

**前置条件**：手机通过 USB 连着这台电脑。

**操作**：

1. 另开一个终端，在项目根目录执行，并保持它运行：

   ```bash
   dart run flutter_patcher serve
   ```

2. 在手机上打开 App；如果已经开着，从最近任务中划掉后重新打开。App 启动时会执行 `checkForPatch()`。

**验证**：

- `serve` 的终端依次输出：

  ```text
  Android device <设备号> reaches this computer at 127.0.0.1:8686
  Offering patch 1 (versionCode 1 arm64-v8a)
  A device checked for updates
  A device downloaded the patch
  ```

- `adb logcat -s flutter` 中出现 `applyPatch: PatchApplyResult(ok)`。

## 第 6 步：冷启动，看到变化

**目标**：运行补丁。

**操作**：从最近任务中划掉 App，再重新打开。

**验证**：界面上显示第 4 步改过的文字。

之后每次修改代码：保持 `serve` 运行，执行 `patch android`，再重复第 5、6 步。`serve` 会输出 `Offering patch 2 ...`，序号依次递增。

## iOS 的不同之处

| 环节 | 与 Android 的区别 |
|---|---|
| 构建 | `build ios` 只能在 Apple Silicon Mac 上运行，需要先在 Xcode 中配置好签名（Team 和 Bundle ID）。装到自己的手机上测试时加 `--export-method development`；默认的 `app-store` 需要发布证书。产物是输出目录中的 `app-release.ipa` |
| 签名 | 在 Mac 的桌面终端中运行 `build ios`。通过 SSH 或在 CI 中运行时，需要先解锁钥匙串，否则签名失败并报 `errSecInternalComponent` |
| 安装 | 例如在 Xcode 的 Devices and Simulators 窗口中添加 ipa。用免费开发者账号签名时，先在手机的“设置 → 通用 → VPN 与设备管理”中信任该开发者 |
| 生成补丁 | `patch ios` 可在 Mac、Linux 或 Windows 上运行，只要这台电脑能读到 `build ios` 保存的基线 |
| 下发补丁 | iPhone 访问不到电脑的 `127.0.0.1`，而 `checkUpdate` 要求 HTTPS。用隧道把 `serve` 暴露为 HTTPS 地址，例如 `cloudflared tunnel --url http://127.0.0.1:8686`，再把得到的地址传给 `checkUpdate` |

## 下一步

- 补丁能改什么、不能改什么：[工作原理](architecture-zh.md#能更新什么)
- 配置存储、发布与撤回：[生产部署](production-playbook-zh.md)
- 补丁导致启动失败时会发生什么：[崩溃保护](crash-protection-zh.md)
