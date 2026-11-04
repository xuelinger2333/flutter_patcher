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

- **开源且自托管**：代码完全透明，不依赖第三方服务，补丁放在你自己的服务器或 CDN 上即可下发。
- **双端支持与跨平台出包**：同时支持 Android 和 iOS；生成补丁不挑主机（例如可在 Linux CI 上直接生成 iOS 补丁）。
- **代码与资源热更**：支持更新业务 Dart 代码、纯 Dart 依赖，以及图片、字体等静态资源。
- **构建期越界拦截**：若误改了原生代码或 FFI 等不支持热更的内容，CLI 生成补丁时会直接报错并说明原因，防止问题包流向线上。
- **启动异常自动回滚**：补丁若导致启动失败，自动退回安装包自带的基线版本。
- **私钥签名校验**：补丁使用你自己的密钥签名，设备端验签通过后才加载。

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

// 在合适的时机检查更新，url 为发布存储对外访问的根地址
final check = await FlutterPatcher.checkUpdate(url);
if (check.hasUpdate) {
  await FlutterPatcher.applyPatch(check.patch!);
}
```

**2. 生成密钥，构建基线安装包**

```bash
dart run flutter_patcher keys init       # 只需执行一次：生成密钥，并请提交 flutter_patcher.yaml
dart run flutter_patcher build android   # 或 build ios（需在 Apple Silicon Mac 上执行）
```

使用 `build` 产出的安装包上架。该命令会记录当前版本的基线（Baseline），后续补丁均基于此基线生成。

**3. 修复 Bug，生成并发布补丁**

```bash
dart run flutter_patcher patch android   # 与基线对比，生成差异补丁
dart run flutter_patcher publish         # 签名并上传至存储服务
```

> **本地联调技巧**：开发调试时可运行 `dart run flutter_patcher serve`，手机连上 USB 后访问 `http://127.0.0.1:8686` 即可拉取补丁，无需提前搭建服务器。

完整步骤见[快速上手](doc/getting-started-zh.md)。

## 注意事项

- **生效时机**：补丁下载后在 App **下次冷启动**时生效。
- **备份密钥与基线**：私钥保存在项目之外，请用 `keys export` 备份。私钥丢失将无法再为已上线版本发布补丁；基线丢失将无法再为对应版本生成差分补丁。
- **合规政策**：部分应用商店限制动态下载可执行代码，使用前请确认目标分发渠道的审核政策。

## 文档

| 文档 | 内容 |
|---|---|
| [快速上手](doc/getting-started-zh.md) | 从集成到第一个补丁生效的完整步骤 |
| [工作原理](doc/architecture-zh.md) | 宿主、基线、补丁策略与安全模型 |
| [CLI 参考](doc/cli-zh.md) | 命令行参数与 `flutter_patcher.yaml` 配置说明 |
| [API 参考](doc/api-reference-zh.md) | App 侧 Dart API 说明 |
| [生产部署](doc/production-playbook-zh.md) | 存储配置、发布流程、灰度发布与补丁撤回 |
| [进阶操作](doc/advanced-zh.md) | 轮换发布密钥与清理历史补丁 |
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