# flutter_patcher

[![Platform](https://img.shields.io/badge/platform-Android_only-brightgreen)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-beta-orange)]()

Android 端 Flutter 热更新插件。  
通过下发补丁 `libapp.so`，让 Dart 代码变更在下次冷启动时生效，并在补丁启动失败时自动回滚。

> 当前项目处于 beta 阶段，建议先在内部测试、灰度环境和非核心业务中验证后再用于生产。

---

## 功能特性

- Android 端 Flutter Dart 代码热更新
- 补丁在下次冷启动生效，不侵入当前运行进程
- 自托管补丁分发，不绑定第三方云服务
- 支持 `applyPatch` URL 下载和 `applyPatchBytes` 字节应用
- 每个补丁与宿主 APK `versionCode` 强绑定，避免 APK 升级后误加载旧补丁
- MD5 校验与可选 Ed25519 签名校验
- 启动失败自动回滚，本地黑名单防止重复加载同一个坏补丁
- 提供 `pack` CLI 从 release APK 中提取补丁
- 支持 full 补丁，可选 bsdiff 差分补丁
- 提供启动诊断、黑名单查询和示例 App

---

## 目录

- [这个插件适合你吗？](#这个插件适合你吗)
- [环境要求](#环境要求)
- [5 分钟体验](#5-分钟体验)
- [安装](#安装)
- [快速开始](#快速开始)
- [补丁生命周期](#补丁生命周期)
- [崩溃保护](#崩溃保护)
- [能改什么、不能改什么](#能改什么不能改什么)
- [补丁发布检查清单](#补丁发布检查清单)
- [安全](#安全)
- [生产环境建议](#生产环境建议)
- [常见问题](#常见问题)
- [文档](#文档)

---

## 这个插件适合你吗？

`flutter_patcher` 是一个自托管的 Android 端 Flutter 热更新 SDK。  
补丁存放在你自己的服务器、CDN 或对象存储上，不依赖任何第三方云服务。

### 适合的场景

- 项目只需要 Android 热更新，或 iOS 可以接受正常发版
- 补丁数据需要自托管，后端协议需要完全自主控制
- 团队可以自行搭建补丁分发服务
- 希望在小范围灰度中快速修复 Dart 层问题
- 可以接受“补丁下次冷启动生效”，不要求当前进程内立即生效

### 不适合的场景

- 需要 Android + iOS 双端热更新
- 不想维护任何补丁分发基础设施
- 需要商业级 SLA、控制台、审计和专职支持
- 需要更新 native 代码、Android 资源、assets 或 Flutter Engine
- 应用商店或业务合规要求禁止动态下发可执行代码

如果你需要 Android + iOS 双端热更新，或希望使用托管式服务，可以评估 Shorebird 等方案。

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 平台 | Android only |
| Android minSdk | 24 |
| Flutter | 3.19 ~ 3.38 |
| ABI | `armeabi-v7a` / `arm64-v8a` / `x86_64` |
| NDK | 27.0.12077973+ |
| AGP | 8.11.1+ |
| Kotlin | 2.2.20+ |
| Java / JVM | 17 |

非 Android 平台调用 API 时会 no-op：不会执行补丁逻辑，不会抛异常，首次调用会打印 warning。

---

## 5 分钟体验

不需要服务器、CDN 或任何后端配置，克隆仓库即可体验完整热更新流程：

```bash
git clone https://github.com/user/flutter_patcher.git
cd flutter_patcher/example
flutter build apk --release
flutter install
```

体验步骤：

1. 打开 App，看到**蓝色**按钮
2. 点击 **Apply patch**
3. 从最近任务划掉并重新打开 App
4. 按钮变成**红色**，表示补丁生效
5. 点击 **Rollback**
6. 再次重启后恢复蓝色

Example 内置了一份预编译的红色主题补丁。  
`Apply patch` 会读取 asset 字节并调用 `applyPatchBytes`，整个流程不走网络。

---

## 安装

```yaml
dependencies:
  flutter_patcher: ^0.1.0
```
或使用 Git 依赖：

```yaml
dependencies:
  flutter_patcher:
    git:
      url: https://github.com/user/flutter_patcher.git
```

---

## 快速开始

### 1. 初始化

在 `runApp()` 之前调用：

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterPatcher.init();

  runApp(const MyApp());
}
```

大多数项目使用默认配置即可。

如果需要调整崩溃保护参数，可以显式传入：

```dart
await FlutterPatcher.init(
  maxCrashCount: 1,
  verifyAfter: const Duration(seconds: 5),
);
```

### 2. 检查更新并应用补丁

如果你使用插件内置的 check-update 协议，可以直接调用 `checkUpdate`：

```dart
Future<void> checkAndApplyPatch() async {
  try {
    final check = await FlutterPatcher.checkUpdate(
      'https://api.example.com/patch/check',
      timeout: const Duration(seconds: 10),
    );

    if (!check.hasUpdate) return;

    final result = await FlutterPatcher.applyPatch(check.patch!);

    if (result.ok) {
      showRestartHint();
    } else {
      debugPrint('patch failed: ${result.error} / ${result.message}');
    }
  } on PatcherException catch (e) {
    debugPrint('check update failed: ${e.message}');
  }
}
```

如果你已经有自己的更新协议，也可以跳过 `checkUpdate`，直接构造 `PatchInfo`：

```dart
final result = await FlutterPatcher.applyPatch(
  PatchInfo(
    version: '1.0.0-h1',
    patchUrl: 'https://cdn.example.com/libapp.so',
    md5: '0123456789abcdef0123456789abcdef',
    targetVersionCode: 100,
  ),
);
```

### 3. 从内存字节应用补丁

如果你已有自己的下载逻辑，或者补丁来自 asset / isolate，可以使用 `applyPatchBytes`：

```dart
final bytes = await loadPatchFromYourSource();

final result = await FlutterPatcher.applyPatchBytes(
  bytes,
  version: '1.0.0-h1',
  targetVersionCode: 100,
);
```

`applyPatchBytes` 会自动计算 MD5、处理临时文件，然后复用补丁应用流程。

### 4. 构建补丁

每个补丁都必须绑定到一个基准 APK。  
`--target-version-code` 用来声明该补丁适用于哪个已安装 APK 的 `versionCode`。

请注意：`--target-version-code` 不是补丁版本号，也不是补丁 APK 的版本号，而是用户设备上已安装的“基准 APK”的 `versionCode`。

例如，线上 APK 的 `versionCode` 是 `100`。现在你要为这个版本构建热修补丁 `1.0.0-h1`，则应填写：

```bash
# 修改 Dart 代码后重新构建 release APK
flutter build apk --release

# 从新 APK 中提取补丁，目标基准版本为 versionCode = 100
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.0-h1 \
  --target-version-code 100
```

产出：

```text
dist/
├── libapp.so
└── manifest.json
```

将 `libapp.so` 和 `manifest.json` 上传到你的 CDN 或对象存储即可。

服务端协议、签名规范、bsdiff、自动初始化关闭等进阶配置见 [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html)。

### 5. 回滚补丁

```dart
await FlutterPatcher.rollback();
```

回滚会删除当前补丁。下次冷启动时，应用会回到 APK 内置版本。

手动 `rollback()` 不会把补丁加入黑名单。

---

## 补丁生命周期

```text
下载补丁
  ↓
校验 MD5 / 签名 / versionCode
  ↓
写入本地补丁目录
  ↓
等待下次冷启动
  ↓
冷启动时加载补丁 libapp.so
  ↓
启动成功：继续使用补丁
启动失败：自动回滚
```

补丁应用成功后，会在**下次冷启动**生效，不会立即替换当前进程中的代码。

如果需要引导用户重启，可以在 `applyPatch` 成功后弹窗提示。

---

## 崩溃保护

`flutter_patcher` 默认采用 fail-fast 策略。  
当补丁导致启动失败，或首屏阶段出现严重 Dart 异常时，插件会在下次冷启动自动回滚到 APK 内置版本，并将问题补丁加入本地黑名单，尽量避免同一个坏补丁被反复加载。

常用配置项：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `maxCrashCount` | `1` | 连续失败多少次后熔断补丁 |
| `verifyAfter` | `5 seconds` | 首帧后 Dart 错误钩子继续监听的窗口 |

Android 11+ 可以通过 `ApplicationExitInfo` 更准确地区分崩溃、ANR、用户主动关闭和系统回收。  
Android 10 及以下识别能力有限，建议结合线上崩溃监控和服务端下架策略。

完整设计、Android 版本差异、黑名单和诊断状态见 [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html)。

---

## 能改什么、不能改什么

本插件只替换 Dart 编译产物 `libapp.so`。

### 可以热更

- `lib/` 下的 Dart 代码
- Widget 和页面逻辑
- 业务逻辑
- 状态管理
- 路由逻辑
- 字符串常量
- 纯 Dart 三方包升级，前提是 native 侧无变化

### 不能热更

以下变更必须走正常发版：

- Kotlin / Java / C++ 等原生代码
- AndroidManifest 变更
- Android 资源文件
- Flutter assets，例如图片、字体、JSON
- Flutter Engine 升级
- 新增或修改 native plugin

### 需谨慎评估

- 混淆配置变更：符号映射不一致可能导致崩溃栈不可读
- 多 ABI / 多 flavor：服务端需按 `ABI × flavor × versionCode` 分发
- 破坏性 Dart API 变更：回滚后持久化数据可能与旧代码不兼容
- 数据库 schema 或本地缓存格式变更：需要保证新旧代码都能安全读取

---

## 补丁发布检查清单

发布补丁前逐条确认：

- [ ] 只修改了 `lib/` 下的 Dart 源码
- [ ] `pubspec.yaml` 的 dependencies 无 native 侧变化
- [ ] `pubspec.yaml` 的 assets 无变化
- [ ] `android/` 目录无变化
- [ ] Flutter SDK / Flutter Engine 未升级
- [ ] `--target-version-code` 与目标宿主 APK 的 `versionCode` 一致
- [ ] 已按 ABI 生成对应补丁
- [ ] 已在真机上验证补丁加载和回滚
- [ ] 已配置灰度、监控和紧急下架方案

任一条不满足，建议走正常发版。

---

## 安全

`flutter_patcher` 提供基础完整性校验和可选签名机制。

- 每个补丁都会校验 MD5。
- 可选 Ed25519 签名校验。
- 私钥只应保存在服务端或构建环境中，不应进入客户端仓库。
- 补丁与宿主 APK `versionCode` 强绑定，APK 升级后旧补丁自动失效。
- 建议始终通过 HTTPS 下载补丁。
- 建议服务端记录补丁版本、MD5、签名、目标 `versionCode` 和发布时间。

签名生成、`strictSignature` 行为和服务端协议见 [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html)。

---

## 生产环境建议

### 1. 灰度发布

不要直接 100% 下发补丁。建议逐步放量：

```text
1% → 5% → 20% → 50% → 100%
```

每个阶段观察 crash 率、启动失败率和关键业务指标。

### 2. 上报启动诊断

建议上报 `lastBootDiagnostic`：

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

如果同一补丁短时间内多次触发 `droppedCircuitBreaker`，服务端应自动停止下发。

### 3. 保留发布记录

建议为每个补丁记录：

- 补丁版本
- 目标 APK `versionCode`
- ABI
- flavor
- MD5
- 签名
- 发布时间
- 灰度比例
- 当前状态：灰度中、全量、已下架

### 4. 准备紧急下架

紧急下架只需要从 check-update 接口中移除该补丁版本。  
已经触发崩溃保护的设备会在本地回滚，并拒绝再次应用同一份问题补丁。

---

## 常见问题

### Q: 补丁和基准 APK 的 Flutter 版本必须一致吗？

A: 是的。`libapp.so` 与 Flutter Engine / Dart 运行时深度绑定，不同 Flutter 版本的 Engine 无法安全加载对方的 `libapp.so`。如果升级了 Flutter SDK 或 Flutter Engine，必须重新发版。

### Q: 用户跳过了中间版本的补丁，直接收到最新补丁会怎样？

A: full 模式下，每个补丁都是完整的 `libapp.so`，不依赖之前的补丁。用户可以从无补丁或旧补丁直接跳到最新补丁。

如果使用 bsdiff，需要确保差分补丁的基准版本与设备当前 APK 匹配。

### Q: 开发期间怎么快速验证，不想每次上传 CDN？

A: 可以使用 `file://` scheme 读取设备本地路径，或者使用仓库自带的 mock server：

```bash
dart run flutter_patcher:pack \
  --apk path/to/app-release.apk \
  --version dev-1 \
  --target-version-code 1

dart run example/tools/mock_server.dart dist 8080
```

客户端 `patchUrl` 填：

```text
http://<你的电脑 IP>:8080/libapp.so
```

### Q: 多个 ABI 怎么处理？

A: 服务端需按 ABI 分发不同的 `libapp.so`。客户端可通过 `FlutterPatcher.deviceAbi` 获取当前设备 ABI，并将其带入 check-update 请求。

### Q: 多 flavor 怎么处理？

A: 建议服务端按 `flavor × ABI × versionCode` 维度管理补丁。不同 flavor 的配置、包名、资源和业务逻辑可能不同，不建议混用补丁。

### Q: 需要修改 ProGuard / R8 配置吗？

A: 通常不需要。插件的反射操作针对 Flutter Engine 的非混淆类，不受宿主业务混淆影响。

### Q: 补丁能撤回吗？

A: 可以。客户端侧调用 `FlutterPatcher.rollback()` 会删除当前补丁。服务端侧停止在 check-update 接口中返回该版本补丁，即可阻止新用户继续下载。

### Q: 补丁为什么不是立即生效？

A: `libapp.so` 已经被当前进程加载后，无法安全地在运行时替换。为了保证稳定性，补丁会先落盘，并在下一次冷启动时加载。

### Q: 为什么要绑定 `targetVersionCode`？

A: 补丁只适用于构建它时对应的基准 APK。绑定 `targetVersionCode` 可以避免 APK 升级后继续加载旧补丁，也可以避免服务端误把补丁下发给不兼容版本。

---

## 文档

- [API reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html) — 初始化、检查更新、应用补丁、回滚、诊断、错误码和 CLI 参数
- [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html) — 崩溃保护、自动回滚、黑名单、Android 版本差异和诊断状态
- [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html) — 工作原理、自托管服务端协议、签名、bsdiff 和进阶配置

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
