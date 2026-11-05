<!-- ========================================== -->
<!-- doc/getting-started-zh.md (简体中文)        -->
<!-- ========================================== -->

# 快速上手

[English](getting-started.md) | **简体中文**

本文将从零开始走通一次完整的热更新闭环：为 Android App 接入 `flutter_patcher`，修改一行界面文字，并在手机冷启动后看到更新生效。全程在本机完成，无需搭建服务器（iOS 的差异说明见文末）。

完整的命令参数请参考 [CLI 参考](cli-zh.md)，底层机制请参考[工作原理](architecture-zh.md)。

## 环境准备

- **构建主机**：Linux x64、Windows x64 或 Apple Silicon Mac
- **Flutter**：3.47.0 – 3.47.9（已加入系统 `PATH`）
- **Git**：已安装并在 `PATH` 中可用
- **测试真机**：一台 `arm64-v8a` 架构的 Android 手机（Android 9 及以上），已开启 USB 调试且 `adb devices` 可正常识别
- **网络环境**：首次运行需联网。CLI 会从 GitHub 下载与当前 Flutter 版本匹配的定制引擎和编译工具链，后续运行将直接使用本机缓存

## 1. 接入 SDK

添加依赖：

```bash
flutter pub add flutter_patcher
```

然后在项目根目录下检查环境：

```bash
dart run flutter_patcher doctor
```

输出的最后一行以 `Toolchain ready.` 开头，即表示环境就绪。若检查失败，请根据输出的错误码查阅[错误码与排障](troubleshooting-zh.md)。

在 `main()` 中调用初始化，并在业务合适的时机（如点击按钮或首页加载时）检查并应用更新：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}

Future<void> checkForPatch() async {
  final check = await FlutterPatcher.checkUpdate('http://127.0.0.1:8686');
  if (!check.hasUpdate) return;
  final result = await FlutterPatcher.applyPatch(check.patch!);
  debugPrint('applyPatch: $result'); // 返回 ok 时，补丁将在下次冷启动生效
}
```

- `http://127.0.0.1:8686` 是第 5 步本地调试服务 `serve` 提供的地址，正式上线时请替换为你自己的 HTTPS 地址（见[生产部署](production-playbook-zh.md)）。
- Release 包检查更新需要网络权限。`flutter create` 只为 debug 和 profile 构建声明了该权限，请在 `android/app/src/main/AndroidManifest.xml` 中添加 `<uses-permission android:name="android.permission.INTERNET"/>`。
- 请确认 `pubspec.yaml` 中的版本号包含构建号（例如 `version: 1.0.0+1`）。`+` 后面的构建号对应 Android 的 `versionCode`，补丁依赖它精准匹配线上的基线版本。

## 2. 初始化密钥

```bash
dart run flutter_patcher keys init
```

每个项目只需执行一次。请把它生成的 `flutter_patcher.yaml` 提交到 git；上线前请备份密钥，见[生产部署：机器与 CI 上的密钥](production-playbook-zh.md#机器与-ci-上的密钥)。

## 3. 构建基线安装包

```bash
dart run flutter_patcher build android
```

`build` 会使用 `flutter_patcher` 的定制引擎构建 Release 安装包，并自动保存当前版本的基线快照（Baseline）。首次运行需下载引擎产物并初始化工具链，耗时较长。

构建完成后，终端末尾会输出一行 JSON，其中 `output` 字段指向产物目录（默认位于 `.dart_tool/flutter_patcher/releases/` 下）。该目录下的 `app-release.apk` 即为可上架的基线安装包。将其安装到手机：

```bash
adb install <output>/app-release.apk
```

打开 App，确认初始版本运行正常。

> **提示**：终端输出的 `WARNING: BASELINE_STORE_LOCAL` 表示基线目前仅保存在本地项目目录中。本地试用可直接忽略；正式上线前请参考[生产部署](production-playbook-zh.md)将其配置到持久化存储。

## 4. 修改代码，生成补丁

随意修改一处界面文字，**注意不要修改 `pubspec.yaml` 中的版本号**，然后运行：

```bash
dart run flutter_patcher patch android
```

`patch` 命令会自动读取第 3 步保存的基线，对比代码差异并生成补丁包。生成成功时，输出 JSON 的 `status` 为 `patch_created`，`changed` 字段会列出具体的变更内容。

如果包含了不支持热更的改动（例如修改了原生代码），命令会直接报错拦截并输出对应的错误码与原因，详见[错误码与排障](troubleshooting-zh.md)。

## 5. 下发补丁到手机

保持手机通过 USB 连接电脑，运行本地调试服务：

```bash
dart run flutter_patcher serve
```

`serve` 启动后会自动完成三件事：
1. 将最新生成的补丁发布到本地存储目录（`.flutter_patcher/updates/`）；
2. 在本机 `127.0.0.1:8686` 启动 HTTP 下载服务；
3. 对已连接的 Android 设备执行 `adb reverse`，将手机端对 `127.0.0.1:8686` 的请求转发至电脑。

保持 `serve` 进程运行，在手机 App 上触发 `checkForPatch()`。此时 `serve` 终端会依次打印 `A device checked for updates` 和 `A device downloaded the patch`，App 日志打印 `applyPatch: PatchApplyResult(ok)`。

## 6. 冷启动验证

彻底杀掉 App 进程（从系统最近任务列表中划掉），重新打开 App，即可看到修改后的界面文字。

如果在保持 `serve` 运行的状态下再次修改代码并执行 `patch android`，`serve` 会自动发布新补丁（新补丁的序号更大）。App 端只需再次触发检查更新并冷启动即可生效，无需手动管理版本号。

## iOS 的不同之处

- **构建基线包**：需在 Apple Silicon Mac 上运行 `build ios`，证书与签名直接沿用 Xcode 工程配置；构建产物为输出目录下的 `app-release.ipa`。
- **跨平台生成补丁**：`patch ios` 可在 Mac、Linux 或 Windows 任一主机上运行，只需确保当前机器能读取到 `build ios` 保存的基线即可（跨机器共享基线见[生产部署](production-playbook-zh.md)）。
- **本地真机联调**：iOS 设备无法像 Android 一样通过 `adb reverse` 直接访问电脑的 `127.0.0.1`。运行 `serve` 时终端会给出提示：请使用内网穿透工具（如 `cloudflared tunnel --url http://127.0.0.1:8686`）将其暴露为公网 HTTPS 地址，再将该地址传入 `checkUpdate`。

## 下一步

- 了解补丁生效机制与热更边界：[工作原理](architecture-zh.md)
- 配置云存储、CDN 与灰度发布：[生产部署](production-playbook-zh.md)
- 了解坏包隔离与自动回滚机制：[崩溃保护](crash-protection-zh.md)