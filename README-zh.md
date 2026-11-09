<!-- ========================================== -->
<!-- README-zh.md (简体中文)                     -->
<!-- ========================================== -->

# flutter_patcher

[![pub package](https://img.shields.io/pub/v/flutter_patcher.svg)](https://pub.dev/packages/flutter_patcher)
[![ci](https://github.com/xuelinger2333/flutter_patcher/actions/workflows/ci.yml/badge.svg)](https://github.com/xuelinger2333/flutter_patcher/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) | **简体中文**

**开源、自托管的 Flutter 热更新工具（支持 Android 与 iOS）。** 线上出了紧急 Bug，不用等商店审核，直接从你自己的服务器或 CDN 把修复推给用户。

## 特性

- **开源且自托管**：代码完全透明，不依赖第三方服务。一个补丁就是一个文件，可以从你掌控的任何服务器、CDN 或接口下发。
- **获取方式由你决定**：App 用任何方式拿到补丁文件（自家接口、CDN、推送、文件），交给插件即可；简单场景可直接用内置的下载器。
- **双端支持与跨平台出包**：同时支持 Android 和 iOS；生成补丁不挑主机（例如可在 Linux CI 上直接生成 iOS 补丁）。
- **代码与资源热更**：支持更新业务 Dart 代码、纯 Dart 依赖，以及图片、字体等静态资源。
- **构建期越界拦截**：若误改了原生代码或 FFI 等不支持热更的内容，CLI 生成补丁时会直接报错并说明原因，防止问题包流向线上。
- **启动异常自动回滚**：补丁若导致启动失败，自动退回安装包自带的基线版本。
- **校验与可选签名**：每个补丁文件在安装前都会在设备端校验目标构建与完整性；开启签名后，App 只接受用你的私钥签名的补丁。

## 支持版本与环境

| Flutter | Android | iOS |
|---|:---:|:---:|
| 3.47.0 – 3.47.9 | ✅ | ✅ |

| 环节 | 环境要求 |
|---|---|
| Android 设备 | Android 9（API 28）及以上，`arm64-v8a`；Android 7–8 上 App 按原包运行，不加载补丁 |
| iOS 设备 | iOS 13 及以上 |
| 构建 Android 基线包 | Linux x64、Windows x64 或 Apple Silicon Mac |
| 构建 iOS 基线包 | Apple Silicon Mac（需 Xcode） |
| 生成补丁（Patch） | 以上任一主机均可生成 Android 与 iOS 补丁 |

## 能更新什么

| 改动内容 | 支持 | 说明 |
|---|:---:|---|
| App 的 Dart 代码 | ✅ | 界面与业务逻辑 |
| 纯 Dart 依赖 | ✅ | 不含原生代码的包，如 `dio`、`intl` |
| 图片、字体等资源 | ✅ | 支持新增或修改；删除资源需发新版安装包 |
| 原生代码、插件、FFI 包 | ❌ | Kotlin/Swift/C++、平台插件，以及 `mmkv`、`isar` 等 |
| Flutter SDK 版本 | ❌ | 补丁必须使用与基线安装包相同的 Flutter 版本生成 |

## 快速开始

**1. 添加依赖并初始化**

```bash
flutter pub add flutter_patcher
```

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}

// 在合适的时机检查更新。不传 url 时使用 build 写进 App 的地址：
// flutter_patcher.yaml 中的 url，未配置时为开发阶段 serve 使用的
// http://127.0.0.1:8686。
final check = await FlutterPatcher.checkUpdate();
if (check.hasUpdate) {
  await FlutterPatcher.applyPatch(check.patch!);
}
```

**2. 构建安装包**

```bash
dart run flutter_patcher build android   # 或 build ios（需在 Apple Silicon Mac 上执行）
```

安装或上架 `build` 产出的安装包。`build` 同时记录这次构建的基线（Baseline），之后这次构建的补丁都基于它生成。

**3. 修复 Bug，生成补丁**

```bash
dart run flutter_patcher patch android   # 写出 <version_code>-<flavor>-<channel>-<abi>.fptc
dart run flutter_patcher serve           # 开发阶段：通过 USB 在 127.0.0.1:8686 提供补丁
```

补丁就是一个 `.fptc` 文件；`patch` 在 `file` 中输出它的路径。`serve` 只是开发阶段的调试工具。任何分发方式都可以：把文件放在 HTTPS 服务的 `<url>/<文件名>` 供 `checkUpdate` 使用，或者从你自己的服务器、CDN 或任何渠道拿到它，再交给插件：

```dart
await FlutterPatcher.applyPatchBytes(bytes);   // 或 FlutterPatcher.applyPatchFile(path)
```

`(await FlutterPatcher.patchTarget).fileName` 是这个宿主接收的文件名。要回到安装包自带的版本，`patch android --withdraw` 以同一个文件名写出撤回文件：应用它的设备重新运行安装包自带的版本。`publish` 把文件写入存储、按发布先后编号，是可选的。

起步不需要密钥，也不需要 `flutter_patcher.yaml`。签名是可选的，推荐开启：在要上线的那次构建之前执行 `dart run flutter_patcher keys init`。

完整步骤见[快速上手](doc/getting-started-zh.md)，上线见[生产部署](doc/production-playbook-zh.md)。

## 注意事项

- **生效时机**：补丁安装后在 App **下次冷启动**时生效。
- **保管基线**：一次构建的所有补丁都基于 `build` 记录的基线生成。请把 `baseline_store` 设为持久的存储；基线丢失后，这次构建就无法再打补丁。
- **不签名的宿主**：没有签名密钥时构建的 App 不校验补丁的来源，谁能把补丁文件交给它，谁就能在其中运行代码。内置下载器强制 HTTPS；App 自己获取文件时，传输安全由 App 负责，或者开启签名。
- **合规政策**：部分应用商店限制动态下载可执行代码，使用前请确认目标分发渠道的审核政策。

## 文档

| 文档 | 内容 |
|---|---|
| [快速上手](doc/getting-started-zh.md) | 从集成到第一个补丁生效的完整步骤 |
| [工作原理](doc/architecture-zh.md) | 宿主、基线、补丁策略与安全模型 |
| [CLI 参考](doc/cli-zh.md) | 命令行参数与 `flutter_patcher.yaml` 配置说明 |
| [API 参考](doc/api-reference-zh.md) | App 侧 Dart API 说明 |
| [生产部署](doc/production-playbook-zh.md) | 从本地跑通到上线：托管补丁文件、签名、撤回、回退、从 1.0 升级 |
| [进阶操作](doc/advanced-zh.md) | 不常用的配置与操作 |
| [崩溃保护](doc/crash-protection-zh.md) | 自动回滚、坏包黑名单与启动诊断 |
| [错误码与排障](doc/troubleshooting-zh.md) | 错误码速查与常见故障处理 |
| [常见问题](doc/faq-zh.md) | 版本对齐、冷启动机制与商店政策解答 |

## 参与贡献

欢迎提交 Issue 和 Pull Request。提交前请确保本地检查通过：

```bash
flutter pub get
flutter analyze
flutter test
```

修改原生代码时，请同时运行 [`test/acceptance`](test/acceptance/README.md) 中的真机测试。

## 许可证

[MIT](LICENSE)