# flutter_patcher

[English](README.md) | **简体中文**

当前开发版 CLI 默认使用 bytecode：补丁自动优先 lean，必要时检查 whole；
Android bootstrap 自动优先可用 FFI。应用保留自己的 Binding，通常无需选择
standard/custom。SO 仍走现有 v1 流程。详见[默认路径与回退规则](doc/default-paths.md)。

[![pub package](https://img.shields.io/pub/v/flutter_patcher.svg)](https://pub.dev/packages/flutter_patcher)
[![Platform](https://img.shields.io/badge/platform-Android-brightgreen)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

开源、自托管的 Flutter Android **热更新（Code Push）** 插件。
无需发版、无需第三方云服务，通过 OTA 方式将 Dart 代码和资源补丁推送到已安装的 App。

如果你用过 [Shorebird](https://shorebird.dev/)、[CodePush](https://learn.microsoft.com/en-us/appcenter/distribution/codepush/) 或 [Expo EAS Update](https://docs.expo.dev/eas-update/introduction/) —— flutter_patcher 将相同的 OTA 更新模式带到 Flutter Android，完全自托管、MIT 协议。

![功能演示：应用补丁、冷启动生效和回滚](doc/feature-presentation.gif)

---

## 横向对比

|                | flutter_patcher          | Shorebird                     | CodePush (React Native)       |
|----------------|--------------------------|-------------------------------|-------------------------------|
| 框架           | Flutter                  | Flutter                       | React Native                  |
| 平台           | Android                  | Android + iOS                 | Android + iOS（2025 年已退役）|
| 托管方式       | 你自己的服务器 / CDN      | Shorebird 云端                 | AppCenter 云端（已废弃）       |
| 更新范围       | Dart 代码 + 资源          | Dart 代码（引擎级 diff）       | JS bundle                     |
| 生效时机       | 下次冷启动                | 下次重启                       | 下次重启                       |
| 费用           | 免费（MIT）               | 免费额度 + 付费方案             | —                             |
| 可自托管       | 是 — 完全自控             | 云端托管                       | —                             |

**选 Shorebird**：如果你需要 iOS 支持或完全托管的服务。
**选 flutter_patcher**：如果你需要在自己控制的基础设施上进行 OTA 更新 —— 企业应用、区域分发或非 Play 渠道。

> Google Play 和部分应用商店限制运行时下载可执行代码。flutter_patcher 面向自控分发、企业 / 内部应用或明确允许此行为的渠道。上线前请确认你的分发渠道政策。

---

## 功能特性

- **OTA 热更新** — 下次冷启动时替换 Dart AOT 产物 `libapp.so` 和 Flutter 资源
- **自托管** — 补丁放在你的 CDN / 对象存储 / 内部服务器，零供应商锁定
- **完整性校验** — MD5 + 可选 Ed25519 签名（Android 13+）
- **崩溃回滚** — 启动失败自动回滚，问题补丁进入黑名单不会重复加载
- **配套工具** — `pack` 打包 CLI、运行时诊断、本地 mock server 和示例 App

---

## 5 分钟体验

不需要服务器。克隆仓库即可体验完整的 补丁 → 重启 → 回滚 流程：

```bash
git clone https://github.com/xuelinger2333/flutter_patcher.git
cd flutter_patcher/example
flutter build apk --release
flutter install
```

1. 打开 App，显示原始 `assets/patch_demo.png`
2. 点击 **Apply patch**
3. 从最近任务划掉并重新打开 App
4. 图片已更换 — 资源补丁生效
5. 点击 **Rollback** → 重启 → 恢复原图

示例内置了预编译的 `patch.zip`，全程离线运行。

如需测试 HTTP 流程，参见 [本地 mock server 指南](doc/getting-started-zh.md#本地-mock-server)。

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 平台 | Android only |
| Dart SDK | `>=3.0.0 <4.0.0` |
| Flutter | `>=3.3.0`；loader hook 已验证 3.19 ~ 3.44 |
| Android `minSdk` | 24 |
| Android `compileSdk` | 36 |
| ABI | `armeabi-v7a` / `arm64-v8a` / `x86_64` |
| NDK | 27.0.12077973+ |
| AGP | 8.11.1+（含 AGP 9.x） |
| Kotlin | 2.2.20+（或 AGP 9 内置 Kotlin） |
| Java / JVM | 17 |

在 iOS、macOS、Windows、Linux 和 Web 上，所有 API 可以安全调用，但不执行热更新逻辑；首次调用时打印一条"不支持当前平台"的日志。

---

## 快速开始

### 1. 安装

```yaml
dependencies:
  flutter_patcher: ^0.1.4
```

或使用 Git 依赖：

```yaml
dependencies:
  flutter_patcher:
    git:
      url: https://github.com/xuelinger2333/flutter_patcher.git
```

### 2. 初始化

在 `runApp()` 之前调用：

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}
```

### 3. 构建补丁

重新构建 release APK 后，运行 `pack`：

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.0-h1 \
  --target-version-code 100
```

包含资源（0.1.3 起），追加 `--assets`：

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.1 \
  --target-version-code 100 \
  --assets assets/hero.png,assets/strings/zh.json
```

- `--version`：补丁版本号（任意字符串）。
- `--target-version-code`：**用户设备上已安装的基准 APK** 的 `versionCode`。
- `--assets`：要打进 `patch.zip` 的资源路径，每个都必须在新 APK 的 `pubspec.yaml` 中登记。

产出：`dist/patch.zip` + `dist/manifest.json`。将 `patch.zip` 上传到 CDN，让更新接口返回指向它的 `PatchInfo`。

`--assets @file` 等进阶用法见 [API 参考](doc/api-reference-zh.md#资源补丁)。

### 4. 应用补丁

```dart
final result = await FlutterPatcher.applyPatch(
  PatchInfo(
    version: 'fix-1',
    patchUrl: 'https://your-cdn.com/v100/patch.zip',
    md5: '0123456789abcdef0123456789abcdef',
    targetVersionCode: 100,
  ),
);

if (result.ok) {
  // 补丁需要冷启动后生效
}
```

如果你自行管理下载，可以使用 `applyPatchBytes`：

```dart
final bytes = await loadPatchFromYourSource();
final result = await FlutterPatcher.applyPatchBytes(
  bytes,
  version: '1.0.0-h1',
  targetVersionCode: 100,
);
```

### 5. 回滚

```dart
await FlutterPatcher.rollback();
```

删除当前补丁，下次冷启动恢复 APK 内置版本。

---

## 工作原理

```text
下载补丁
  ↓
校验 MD5 / 签名（如有），然后校验 versionCode
  ↓
写入本地补丁目录
  ↓
下次冷启动 → 加载补丁 libapp.so + 资源 overlay
  ↓
启动成功 → 继续使用补丁
启动失败 → 自动回滚 + 加入黑名单
```

补丁在**下次冷启动**生效，不会立即替换当前进程中的代码。

---

## 能改什么

| 可以热更 | 不能热更 |
|---|---|
| `lib/` 下的任何 Dart 代码：widget、逻辑、路由、常量 | 原生代码（Kotlin / Java / C++）、`AndroidManifest.xml`、APK `res/` |
| 纯 Dart 三方包升级（native 侧不变） | Flutter Engine 升级 |
| Flutter 资源文件（`pubspec.yaml` 中登记 + `--assets` 列出） | 新增或修改 native plugin |
| 现有 `Image.asset()` / `rootBundle.load()` 自动读到新字节 | 删除 base APK 中已有的资源 |
|  | `pubspec.yaml` 字体注册变更 |

边界情况（ProGuard/R8、多 ABI/flavor、状态迁移）见 [API 参考](doc/api-reference-zh.md#能改什么不能改什么)。

---

## 安全保障

### 崩溃保护

插件默认 fail-fast：补丁导致启动失败时自动回滚，并将问题版本加入黑名单。可通过 `maxCrashCount`（默认 1）和 `verifyAfter`（默认 5s）调整。

完整设计和 Android 版本差异：[崩溃保护文档](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html)。

### 完整性与签名

- 强烈建议下发 **MD5**；仅在快速测试时省略
- **Ed25519 签名**校验支持 Android 13+（API 33）
- 补丁与宿主 APK `versionCode` 强绑定，APK 升级后旧补丁自动失效
- 始终通过 HTTPS 下载；私钥只放在服务端

详情：[架构设计 → 安全](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html)。

---

## 生产环境建议

- **灰度发布**（1% → 5% → 20% → 50% → 100%），每阶段观察 crash 率
- **上报诊断** — 将 `FlutterPatcher.lastBootDiagnostic` 发送到你的数据平台
- **准备紧急下架** — 停止从更新接口返回问题补丁；已触发崩溃保护的设备已在本地回滚

详细的诊断上报代码和发布记录模板见 [生产环境实践手册](doc/production-playbook-zh.md)。

---

## 常见问题

**补丁和基准 APK 的 Flutter 版本必须一致吗？**
是的。`libapp.so` 与 Flutter Engine 深度绑定，升级 SDK 后必须重新发版。

**补丁为什么不是立即生效？**
`libapp.so` 被当前进程加载后无法安全替换。补丁先落盘，下次冷启动时加载。

**为什么要绑定 `targetVersionCode`？**
防止 APK 升级后加载旧补丁，也防止服务端误下发给不兼容版本。

更多问题：[完整 FAQ](doc/faq-zh.md)

---

## 文档

在线版（pub.dev，英文）：

- [API Reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html) — 初始化、检查更新、应用补丁、回滚、诊断、错误码、CLI 参数
- [Crash Protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html) — 自动回滚、黑名单、Android 版本差异
- [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html) — 工作原理、服务端协议、签名、进阶配置

仓库内中文文档：

- [快速上手](doc/getting-started-zh.md) — mock server、多 ABI 配置、分步指引
- [API 参考](doc/api-reference-zh.md) — 初始化、检查更新、应用补丁、回滚、诊断、错误码和 CLI 参数
- [崩溃保护](doc/crash-protection-zh.md) — 崩溃保护、自动回滚、黑名单、Android 版本差异和诊断状态
- [架构设计](doc/architecture-zh.md) — 工作原理、自托管服务端协议、签名和进阶配置
- [生产环境实践手册](doc/production-playbook-zh.md) — 灰度发布、诊断上报、紧急下架
- [常见问题](doc/faq-zh.md) — 版本绑定、冷启动生效、商店政策等高频疑问

English: [README.md](README.md)

---

## 谁在使用？

如果你在生产环境使用了 flutter_patcher，欢迎 [提 issue](https://github.com/xuelinger2333/flutter_patcher/issues) 告诉我们你的用法 —— 我们很乐意在此展示。

---

## 贡献

欢迎 issue 和 PR。

提交前请确保：

- `flutter analyze` 无 warning
- `flutter test` 全部通过
- 如涉及原生代码变更，在真机上跑过完整的补丁加载和回滚流程

---

## 许可证

MIT
