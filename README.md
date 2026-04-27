# flutter_patcher

[![Platform](https://img.shields.io/badge/platform-Android_only-brightgreen)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-beta-orange)]()

Android 端 Flutter 热更新插件。下发补丁 `libapp.so`，下次冷启动自动生效，崩溃自动回滚。

> **项目状态：Beta / 个人维护。** 已在作者自有项目中生产使用。0.x 阶段 API 可能调整，请固定版本号使用。欢迎 issue 和 PR，响应周期约 1–2 周。

---

## 这个插件适合你吗？

flutter_patcher 是一个自托管的 Android 端 Flutter 热更新 SDK。
补丁存在你自己的服务器上，不依赖任何第三方云服务。

**适合的场景：**

- 项目只需要 Android 热更新（或 iOS 走正常发版即可接受）
- 补丁数据不能出境，需要满足国内合规要求
- 希望后端协议完全自主控制，不绑定特定供应商
- 团队愿意自己搭建补丁分发服务（一个静态文件托管即可）

**不适合的场景：**

- 需要 Android + iOS 双端热更新
- 不想自己搭建任何后端基础设施
- 需要商业级 SLA 和专职团队支持

> 如果你需要双端支持或托管式服务，可以了解
> [Shorebird](https://shorebird.dev)（Flutter 官方推荐的社区方案）。

---

## 5 分钟体验

不需要服务器、CDN 或任何后端配置，克隆仓库直接体验完整热更新流程：

```bash
git clone https://github.com/user/flutter_patcher.git
cd flutter_patcher/example
flutter build apk --release && flutter install
```

1. 打开 App，看到**蓝色**按钮
2. 点击 **Apply patch**
3. 从最近任务划掉并重新打开 → 按钮变**红色**（补丁生效）
4. 点击 **Rollback** → 重启 → 恢复蓝色

Example 内置了一份预编译的红色主题补丁，`Apply patch` 读取 asset 字节并调用 `applyPatchBytes`，整套流程在设备上闭环，无需网络。

---

## 接入步骤

### 1. 添加依赖

```yaml
dependencies:
  flutter_patcher:
    path: ../flutter_patcher  # 也可使用 git 或 pub 源
```

### 2. 初始化

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}
```

### 3. 应用补丁

两种入口，按你字节流的来源选：

**字节已在内存**（asset / 自定义网络栈 / isolate）：

```dart
final bytes = await loadPatchFromYourSource();
final result = await FlutterPatcher.applyPatchBytes(bytes, version: '1.0.0-h1');
```

**服务端下发协议 / HTTP 拉取：**

```dart
final result = await FlutterPatcher.applyPatch(PatchInfo(
  version: '1.0.0-h1',
  patchUrl: 'https://cdn.example.com/libapp.so',
  md5: '0123456789abcdef0123456789abcdef',
));
```

`applyPatchBytes` 内部自动算 MD5、处理临时文件，无需引入 `crypto` / `path_provider` / `dart:io`。`applyPatch` 的 `targetVersionCode` 不传时自动绑定当前 APK versionCode。

补丁在**下次冷启动**时生效，不是调用后立即生效。

### 4. 构建补丁

```bash
# 修改 Dart 代码后重新构建 release APK
flutter build apk --release

# 从 APK 中提取补丁
dart run flutter_patcher:pack \
    --apk build/app/outputs/flutter-apk/app-release.apk \
    --version 1.0.0-h1 \
    --target-version-code 100
```

产出 `dist/libapp.so` + `dist/manifest.json`，上传至你的 CDN 即可。`--target-version-code` 必须与用户设备上已安装的基准 APK 的 `versionCode` 一致。

服务端协议、签名规范、bsdiff、自动初始化关闭等进阶配置见 [docs/architecture.md](docs/architecture.md)。

### 5. 回滚

```dart
await FlutterPatcher.rollback();
// 下次冷启动恢复 APK 内置版本。手动 rollback 不会入黑名单。
```

---

## 崩溃保护

补丁加载失败时用户最多看到一次白屏，下次冷启动自动回滚到 APK 内置版本，并将该补丁加入本地黑名单防止循环下载。默认 fail-fast：失败 1 次即丢弃。verified 判定要求首帧渲染 + 前台存活 5 秒；Android 11+ 通过 `ApplicationExitInfo` 区分真崩溃和用户主动关闭，不误伤用户操作。常用配置：`maxCrashCount`（熔断阈值，默认 1）、`verifyAfter`（存活时长，默认 5 秒）。完整设计、诊断接口和错误码处理见 [docs/crash-guard.md](docs/crash-guard.md)。

---

## 能改什么、不能改什么

本插件只替换 Dart 编译产物 `libapp.so`，能力边界非常明确：

**可以热更：** 任意 Dart 代码 —— Widget、业务逻辑、状态管理、路由、字符串常量、纯 Dart 三方包升级（native 侧无变化）。

**不能热更（必须发版）：** 原生代码（Kotlin / Java / C++）、AndroidManifest 变更、Android 资源文件、Flutter assets（图片/字体/JSON）、Flutter Engine 升级、新增 native plugin。

**需谨慎评估：** 混淆配置变更（符号映射不一致可能导致崩溃栈不可读）、多 ABI / 多 flavor（服务端需按 ABI × flavor × versionCode 三维分发）、破坏性 Dart API 变更（回滚后持久化数据可能与旧代码不兼容）。

---

## 补丁发布检查清单

发布补丁前逐条确认：

- [ ] 只修改了 `lib/` 下的 Dart 源码
- [ ] `pubspec.yaml` 的 dependencies / assets 无变化
- [ ] `android/` 目录无变化（无原生代码改动、无 manifest 改动）
- [ ] Flutter SDK 大版本未升级
- [ ] `--target-version-code` 与目标宿主 APK 的 versionCode 一致

**上线前测试 SOP（建议在真机上跑完整套）：**

- [ ] 补丁加载成功 → 冷启动后 UI 符合预期
- [ ] 手动 rollback → 冷启动后恢复到 APK 内置版本
- [ ] 安装一个"故意 crash 的补丁" → 冷启动后自动回滚、黑名单写入
- [ ] 升级 APK versionCode → 冷启动后旧补丁自动丢弃
- [ ] `lastBootDiagnostic` 各状态的上报数据正确

任一条不满足，走正常发版。

---

## FAQ

**Q: 补丁和基准 APK 的 Flutter 版本必须一致吗？**

A: 是的。`libapp.so` 与 Flutter Engine / Dart kernel 深度绑定，不同 Flutter 版本的 Engine 无法加载对方的 `libapp.so`。如果升级了 Flutter SDK，必须重新发版。

**Q: 用户跳过了中间版本的补丁，直接收到最新补丁会怎样？**

A: 每个补丁都是完整的 `libapp.so`，不依赖之前的补丁。用户从任何版本跳到最新补丁都正常工作。

**Q: 开发期间怎么快速验证，不想每次上传 CDN？**

A: 用 `file://` scheme 直读设备本地路径，或者用仓库自带的 mock server：

```bash
dart run flutter_patcher:pack --apk path/to/app-release.apk --version dev-1 --target-version-code 1
dart run example/tools/mock_server.dart dist 8080
# 客户端 patchUrl 填 http://<你电脑IP>:8080/libapp.so
```

**Q: 多个 ABI 怎么处理？**

A: 服务端需按 ABI 分发不同的 `libapp.so`。客户端可通过 `await FlutterPatcher.deviceAbi` 获取当前设备 ABI，拼进 check-update 请求中。

**Q: 跟 Tinker / 微信热修能共存吗？**

A: 可以。flutter_patcher 只替换 Flutter 的 `libapp.so`，Tinker 替换 Android 原生的 dex / so / 资源，两者作用范围不重叠。

**Q: 需要修改 ProGuard / R8 配置吗？**

A: 不需要。插件的反射操作都在 Flutter Engine 的非混淆类上，不受宿主混淆影响。

**Q: 补丁能撤回吗？**

A: 客户端侧调用 `FlutterPatcher.rollback()` 即可。服务端侧停止下发该版本补丁（从 check-update 接口移除），已安装的用户不受影响直到下次冷启动拉新配置。

**Q: 如果你不再维护这个项目，我的项目会受影响吗？**

A: 不会。插件是纯 SDK，不依赖任何在线服务。即使停止维护，已集成的代码继续工作，只是无法适配未来的 Flutter 版本。你可以 fork 仓库自行维护。如果停止维护，会在 README 顶部标注并给出 fork 建议。

---

## 文档

- [docs/crash-guard.md](docs/crash-guard.md) — 崩溃保护机制完整设计（fail-fast、verified 三层判定、黑名单、诊断接口、错误码处理）
- [docs/architecture.md](docs/architecture.md) — 技术内幕（工作原理、服务端协议、versionCode 绑定、反射兼容、签名规范、pack CLI、进阶配置、性能与支持范围）

---

## 贡献

欢迎 issue 和 PR。提交前请确保：

- `flutter analyze` 无 warning
- `flutter test` 全部通过
- 如涉及原生代码变更，在真机上跑过完整的补丁加载 + 回滚流程

---

## License

MIT
