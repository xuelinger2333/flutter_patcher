# 快速上手

[English](getting-started.md) | **简体中文**

> 修改 Flutter App 中的一行文字，不重新安装 App，让这处改动以补丁的形式出现在 Android 手机上。

全程只用你的电脑和一台通过 USB 连接的手机，所以不需要服务器，也不需要签名密钥。大约需要 15 分钟，其中几分钟用于首次下载引擎。使用 iPhone 时，见[iOS 的不同之处](#ios-的不同之处)。

## 开始之前

| 需要 | 检查方法 |
|---|---|
| Linux x64、Windows x64 或 Apple Silicon Mac，已安装 Git | `git --version` |
| Flutter 3.47.0 到 3.47.9，在 `PATH` 中 | `flutter --version` |
| 一台 Android 9 或更新版本、`arm64-v8a` 的手机，已开启 USB 调试 | `adb devices` 列出这台手机 |
| 一个 Flutter 项目，`pubspec.yaml` 的 `version` 带构建号，例如 `1.0.0+1` | `flutter create` 新建的项目默认如此 |
| 首次运行时能访问 GitHub | 引擎和工具从这里下载一次 |

## 第 1 步：添加依赖

```bash
flutter pub add flutter_patcher:1.1.1
dart run flutter_patcher init
dart run flutter_patcher doctor
```

`doctor` 最后一行以 `Toolchain ready.` 开头即可。失败时按错误码查[排障](troubleshooting-zh.md)。

然后修改 `lib/main.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init(); // 需在 runApp 之前调用
  runApp(const MyApp());
  checkForPatch();
}

Future<void> checkForPatch() async {
  try {
    final check = await FlutterPatcher.checkUpdate(); // 默认地址 127.0.0.1:8686
    if (!check.hasUpdate) return;
    final result = await FlutterPatcher.applyPatch(check.patch!); // 下次冷启动生效
    debugPrint('applyPatch: $result');
  } on PatcherException catch (e) {
    debugPrint('checkUpdate failed: $e');
  }
}
```

用 `flutter run` 启动的 App 不接收补丁，`checkUpdate` 在其中返回没有更新，所以日常开发不需要改动这段代码。

## 第 2 步：构建并安装

```bash
dart run flutter_patcher build android
adb install <app>   # build 输出中 "app" 字段的路径
```

输出中会有 `UNSIGNED` 和 `BASELINE_STORE_LOCAL` 两条警告，本地试用可以忽略，上线前见[生产部署](production-playbook-zh.md)。

## 第 3 步：修改代码，生成补丁

在 `lib/main.dart` 中改一处界面上能看到的文字，然后运行：

```bash
dart run flutter_patcher patch android
```

输出 `"status":"patch_created"` 即成功。

> 不要修改 `pubspec.yaml` 中的 `version`，否则会以 `BASELINE_NOT_FOUND` 失败。

## 第 4 步：在手机上运行补丁

保持手机通过 USB 连接，另开一个终端运行并保持：

```bash
dart run flutter_patcher serve
```

从最近任务中关闭 App 再打开，重复两次：第一次下载补丁，第二次运行补丁。界面显示第 3 步的修改即成功。

之后每次改代码，保持 `serve` 运行，重新执行 `patch android`，再开关 App 两次。

没有生效？见[排障](troubleshooting-zh.md#checkupdate-始终找不到更新)。撤回补丁见[补丁下发回滚](production-playbook-zh.md#补丁下发回滚)。

## iOS 的不同之处

| 环节 | 与 Android 的区别 |
|---|---|
| 构建 | `build ios` 只能在 Apple Silicon Mac 上运行，并需要先在 Xcode 中配置好签名（Team 和 Bundle ID）。装到自己的手机上时加 `--export-method development`，因为默认的 `app-store` 需要发布证书。产物是 `app-release.ipa` |
| 代码签名 | 在 Mac 桌面会话的终端中运行 `build ios`。通过 SSH 或在 CI 中运行时，先解锁钥匙串，否则签名以 `errSecInternalComponent` 失败 |
| 安装 | 例如在 Xcode 的 Devices and Simulators 窗口中添加 ipa。用免费开发者账号签名时，先在手机的“设置 → 通用 → VPN 与设备管理”中信任该开发者 |
| 生成补丁 | `patch ios` 可在能读到 `build ios` 所存基线的 Mac、Linux 或 Windows 电脑上运行。文件名形如 `1-ios-arm64.fptc` |
| 下发补丁 | iPhone 访问不到电脑的 `127.0.0.1`，而 `checkUpdate` 只对设备本机允许明文 HTTP。用隧道把 `serve` 暴露为 HTTPS 地址，例如 `cloudflared tunnel --url http://127.0.0.1:8686`，再传入该地址：`checkUpdate(url: 'https://…')` |

## 下一步

- 补丁能改什么、不能改什么，以及补丁为什么在冷启动后生效：[工作原理](architecture-zh.md)
- 发布一个能接收补丁的 App：[生产部署](production-playbook-zh.md)
- 补丁导致启动失败时会发生什么：[崩溃保护](crash-protection-zh.md)
