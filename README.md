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

## 能改什么、不能改什么

本插件只替换 Dart 编译产物 `libapp.so`，能力边界非常明确：

**可以热更：** 任意 Dart 代码 —— Widget、业务逻辑、状态管理、路由、字符串常量、纯 Dart 三方包升级（native 侧无变化）。

**不能热更（必须发版）：** 原生代码（Kotlin / Java / C++）、AndroidManifest 变更、Android 资源文件、Flutter assets（图片/字体/JSON）、Flutter Engine 升级、新增 native plugin。

**需谨慎评估：** 混淆配置变更（符号映射不一致可能导致崩溃栈不可读）、多 ABI / 多 flavor（服务端需按 ABI × flavor × versionCode 三维分发）、破坏性 Dart API 变更（回滚后持久化数据可能与旧代码不兼容）。

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

## 工作原理

整套系统涉及三个角色：

```
  你的开发机                   你的服务端                  用户设备
 ─────────────              ─────────────              ─────────────
 修改 Dart 代码               存储 + 分发                 下载 + 校验
       │                         │                         │
 flutter build apk            上传补丁                  applyPatch()
       │                    libapp.so + meta               │
 pack 工具提取                    │                    写入本地 + 落盘
 libapp.so + meta ──────→   CDN / 对象存储 ──────→    下次冷启动加载
                                                          │
                                                     启动成功 → 清熔断
                                                     启动失败 → 自动回滚
```

**用户设备冷启动时：** 插件在 `Application.attachBaseContext` 阶段完成熔断检查 → 补丁校验（versionCode + MD5 + 可选签名） → 反射替换 FlutterLoader → 引导 Engine 加载补丁 `.so`。首帧渲染 + 前台存活 5 秒后标记为 verified，清除熔断计数。

**补丁出问题时：** 用户最多经历一次白屏。下次冷启动插件检测到上次启动失败，自动回滚到 APK 内置版本，并将该补丁加入本地黑名单防止循环下载。详见 [崩溃保护机制](#崩溃保护机制)。

---

## 接入指南

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

产出 `dist/libapp.so` + `dist/manifest.json`，上传至你的 CDN 即可。

`--target-version-code` 必须与用户设备上已安装的基准 APK 的 `versionCode` 一致。

### 5. 回滚

```dart
await FlutterPatcher.rollback();
// 下次冷启动恢复 APK 内置版本。手动 rollback 不会入黑名单。
```

---

## 你的服务端需要做什么

flutter_patcher 不绑定任何特定后端。你需要实现的最小协议：

**一个 check-update 接口**，客户端定期请求，服务端返回是否有新补丁：

```json
// GET /api/patch/check?app_version_code=100&abi=arm64-v8a&current_patch=1.0.0-h1
// 无可用补丁时返回：
{ "has_update": false }

// 有可用补丁时返回：
{
  "has_update": true,
  "version": "1.0.0-h2",
  "patch_url": "https://cdn.example.com/patches/arm64-v8a/libapp.so",
  "md5": "0123456789abcdef0123456789abcdef",
  "target_version_code": 100
}
```

**一个补丁文件托管**，任何能提供 HTTP GET 下载的服务即可（CDN / 对象存储 / nginx 静态目录）。

**可选但推荐：** 接收客户端崩溃上报，同一补丁短时间收到 N 次回滚事件后自动停止下发（手动下架也行）。

> 仓库 `example/tools/mock_server.dart` 提供了一个本地 mock server，可用于开发联调。

---

## 崩溃保护机制

这是用 flutter_patcher 最需要理解的部分。

**对用户的影响：** 补丁有问题时，用户最多看到一次白屏（app 闪退）。下次打开 app 自动恢复正常。不会出现反复崩溃、需要卸载重装的情况。

**默认行为（fail-fast）：** 补丁加载后启动失败 1 次即丢弃 + 入黑名单。不给"再试一次"的机会，因为生产环境里坏补丁不会第二次变好。

**verified 三层判定：** 补丁加载后必须满足三个条件才算 verified —— ① 反射注入成功 ② 首帧渲染完成 ③ App 在前台连续存活 5 秒不 crash。只在 `AppLifecycleState.resumed` 累计，用户启动后按 Home 不会被错误地 verify。

**真崩溃 vs 用户主动关闭：** Android 11+（API 30+）调用 `ActivityManager.getHistoricalProcessExitReasons` 精确区分 —— 用户从最近任务划掉、OOM、强停都不会扣补丁的命数。Android 10 及以下（占比约 5–10%）没有这个 API，走朴素策略：未完成首帧即视为一次失败。

**Dart 层白屏兜底：** 补丁最常见的故障形态不是进程崩溃，而是 Dart 层 throw 被 framework 接住、进程不死但白屏。插件在未 verified 窗口内安装 `PlatformDispatcher.onError` 和 `FlutterError.onError` 钩子，首个未捕获错误等同一次崩溃，触发熔断。verified 之后恢复原 handler，业务异常不影响补丁。

**黑名单：** 被自动回滚的补丁以 `(version, md5)` 双键写入本地黑名单。下次拉到同一份补丁时直接拒绝，不浪费流量。开发者修了 bug 后用同样 version 重发（md5 必然不同），允许下载。黑名单 FIFO 上限 50 条，跨 APK 升级保留。

```dart
// 调整熔断阈值（默认 1，fail-fast）
await FlutterPatcher.init(maxCrashCount: 1);

// 调整 verified 存活时长（默认 5 秒）
await FlutterPatcher.init(verifyAfter: const Duration(seconds: 5));

// 查看黑名单
final entries = await FlutterPatcher.blacklist;

// 清空黑名单（仅调试用）
await FlutterPatcher.clearBlacklist();
```

---

## 诊断与可观测性

补丁装上之后，冷启动阶段仍可能因 versionCode 不匹配、签名失败、熔断触发等被原生侧丢弃。这些事件通过 `lastBootDiagnostic` 结构化暴露到 Dart：

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;
if (diag != null && !diag.isHealthy) {
  analytics.report('patch_dropped', {
    'status': diag.status.name,
    'patch_version': diag.patchVersion,
    'crash_count': diag.crashCount,
  });
}
```

| status | 含义 | 处理建议 |
|---|---|---|
| `patched` | 补丁加载成功 | 无需处理 |
| `noPatch` | 无补丁，使用 APK 内置版本 | 无需处理 |
| `droppedVersionCodeMismatch` | APK 升级后旧补丁失效 | 正常流程，重新拉取最新补丁 |
| `droppedCircuitBreaker` | 连续启动失败达熔断阈值 | **强告警**：补丁有 bug，通知服务端下架 |
| `droppedSignatureInvalid` | 签名校验失败 | **强告警**：可能被篡改 |
| `droppedMd5Mismatch` | 本地文件 MD5 不一致 | 上报：磁盘损坏或篡改 |
| `droppedMetaCorrupted` | 元数据损坏 | 上报 |
| `hookInstallFailed` | 反射替换失败 | 跟进 Flutter 版本适配 |

`example/lib/diag_card.dart` 将全套字段做成了一张可视化卡片，真机调试时直接看屏幕即可。

---

## 错误处理

`applyPatch` / `applyPatchBytes` 返回 `PatchApplyResult`：

```dart
final r = await FlutterPatcher.applyPatch(info);
if (!r.ok) {
  switch (r.error!) {
    case PatchApplyError.network:
    case PatchApplyError.ioError:
      // 可重试（建议指数退避，最多 3 次）
      break;
    case PatchApplyError.blacklisted:
      // 该补丁曾导致崩溃，通知服务端下架，不重试
      break;
    case PatchApplyError.signatureInvalid:
      // 可能被篡改，上报安全事件，不重试
      reportSecurityEvent(r.message);
      break;
    case PatchApplyError.md5Mismatch:
      // CDN 脏数据或服务端 MD5 错算，检查后重试
      break;
    default:
      log.warning('patch: ${r.error?.name} / ${r.message}');
  }
}
```

完整错误码：`invalidArgs`、`blacklisted`、`bsdiffDisabled`、`network`、`md5Mismatch`、`signatureInvalid`、`bsdiffApplyFailed`、`targetMd5Mismatch`、`ioError`、`unknown`。

> 同版本补丁重复调用 `applyPatch` 幂等返回 `ok=true`。versionCode 不匹配在下次冷启动检测，不在此处报错。

---

## 进阶配置

### 签名校验

Ed25519 签名提供独立于 HTTPS 的完整性校验，防止 CDN 篡改。

```bash
# 生成密钥对（开发机执行一次）
openssl genpkey -algorithm ed25519 -out patch_sk.pem
openssl pkey -in patch_sk.pem -pubout -outform DER | base64 -w0
# 输出类似 MCowBQYDK2VwAyEA...

# 服务端对补丁签名（消息体 = MD5 hex 字符串的 UTF-8 字节）
printf "%s" "0123456789abcdef0123456789abcdef" | \
  openssl pkeyutl -sign -inkey patch_sk.pem -rawin | base64 -w0
```

```dart
await FlutterPatcher.init(publicKeyBase64: 'MCowBQYDK2VwAyEA...');
```

JDK 原生 Ed25519 需要 Android 13+（API 33）。低版本设备默认拒绝带签名补丁（`strictSignature: true`）。设置 `strictSignature: false` 允许低版本设备降级为仅 MD5 + HTTPS 校验。

### 关闭自动初始化

仅在一种情形需要：**你在 `Application.attachBaseContext` 里预热了 `FlutterEngine`**（常见于大厂混合工程的冷启动优化）。此时自动初始化的 ContentProvider 比 Engine 创建晚，反射来不及。

```xml
<!-- AndroidManifest.xml -->
<provider
    android:name="com.flutter_patcher.flutter_patcher.FlutterPatcherAutoInitProvider"
    android:authorities="${applicationId}.flutter_patcher.autoinit"
    tools:node="remove" />
```

```kotlin
class MyApp : FlutterApplication() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        FlutterPatcherApplication.attachPatcher(base)
    }
}
```

### 启用 bsdiff 差分

默认关闭。启用后补丁包体积从数 MB 降至数十 KB。需要手动集成 C 源码，约 10 分钟。

详细步骤：将 [bsdiff-4.3](https://www.daemonology.net/bsdiff/) 的 `bspatch.c` 和 [bzip2-1.0.x](https://sourceware.org/pub/bzip2/) 源码放入 `android/src/main/cpp/third_party/`，将 `bspatch.c` 的 `main` 改为 `flutter_patcher_bspatch(old, new, patch)` 签名，重新构建。服务端用 `bsdiff` 命令生成差分包，下发时设 `mode: "bsdiff"` 并附上合成目标的 MD5。

### 下载进度

```dart
final sub = FlutterPatcher.applyProgress.listen((p) {
  if (p.phase == PatchApplyPhase.downloading) {
    setState(() => _progress = p.fraction ?? 0);
  }
});
final result = await FlutterPatcher.applyPatch(info);
await sub.cancel();
```

也可用 `onProgress` 回调代替 Stream 订阅：

```dart
final result = await FlutterPatcher.applyPatch(info, onProgress: (p) => ...);
```

### Flutter 大版本升级适配

当前覆盖 Flutter 3.19 ~ 3.38。升级后如反射字段名变更，可临时适配：

```dart
await FlutterPatcher.init(loaderFieldCandidates: ['newFieldName', 'flutterLoader']);
```

升级后请检查 logcat 中 `FlutterPatcher/Hook` 标签的输出确认注入成功。

### 查询当前补丁版本

```dart
final version = await FlutterPatcher.currentVersion; // null = 无补丁
```

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

## 性能影响

| 指标 | 影响 |
|---|---|
| APK 体积增量 | 约 80–120 KB（插件 native 代码 + Kotlin） |
| 启动耗时增量 | 约 5–15 ms（反射替换 + SharedPreferences commit，profile 模式实测） |
| 运行时内存 | 无额外占用（补丁加载后与原始 libapp.so 行为一致） |
| 补丁文件大小 | 全量替换与原 libapp.so 同等大小（通常 5–15 MB）；启用 bsdiff 后降至数十 KB |

> 以上数据基于 Pixel 6 / Flutter 3.24 测量，不同设备和 Flutter 版本可能有差异。

---

## 支持范围

| 维度 | 要求 |
|---|---|
| 平台 | 仅 Android |
| Android minSdk | 24（Android 7.0） |
| Flutter | 3.19 ~ 3.38 |
| ABI | `armeabi-v7a` / `arm64-v8a` / `x86_64` |
| NDK | 27.0.12077973+ |
| AGP | 8.11.1+ |
| Kotlin | 2.2.20+ |
| Java / JVM | 17 |

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

## 技术细节

> 以下内容为内部工作原理，正常接入无需阅读。

### versionCode 强绑定

`applyPatch` 落盘时将 `targetVersionCode` 写入 `patch_meta.json`。每次冷启动在反射替换之前比对，不匹配则删除补丁。即使服务端未下发 `targetVersionCode`，APK 升级后也会自动清除旧补丁。

### 熔断器实现

| 时机 | 行为 |
|---|---|
| `Application.attachBaseContext` | 写入 `patch_loading=true` + pid（同步 `commit`） |
| Dart `FlutterPatcher.init()` | 再写一次 `patch_loading=true`（兜底） |
| 首帧渲染 + 前台存活 N 秒 | `patch_loading=false`，`crash_count=0` |
| 下次冷启动发现 `patch_loading==true` | API 30+ 查 `ApplicationExitInfo` 区分真崩溃；API < 30 直接计一次失败 |
| `crash_count >= maxCrashCount` | 删除补丁 + 入黑名单，回退 APK 内置版本 |

Logcat tag `FlutterPatcher/Guard` 输出所有崩溃判定日志。

### 反射兼容矩阵

| Flutter 版本 | `FlutterInjector` 字段 | `ensureInitializationComplete` 签名 |
|---|---|---|
| 3.19.x ~ 3.38.x | `flutterLoader` | `(Context, @Nullable String[])` |

### 签名消息体规范

算法 Ed25519，公钥格式 X.509 SubjectPublicKeyInfo DER → Base64，签名消息体为 MD5 hex 字符串（32 字节 UTF-8）。

### pack CLI 完整参数

| 参数 | 说明 |
|---|---|
| `--apk <path>` | 必填，release APK 路径 |
| `--version <string>` | 必填，补丁版本标识 |
| `--target-version-code <int>` | 必填，宿主 APK versionCode |
| `--abi <string>` | 可选，不传时按 arm64-v8a > armeabi-v7a > x86_64 优先取 |
| `--out <dir>` | 可选，默认 `dist/` |

---

## 已知限制

- **iOS 不支持：** Apple 政策禁止下载可执行代码
- **Flutter Engine 升级即作废：** 大版本升级后所有旧补丁必须重新生成
- **反射依赖 Flutter 私有 API：** Flutter 大改 loader 架构时可能需要适配
- **合规风险：** 动态下发可执行代码在部分应用商店类目（面向未成年人、金融、医疗等）存在政策限制，接入前请评估目标市场要求

---

## 贡献

欢迎 issue 和 PR。提交前请确保：

- `flutter analyze` 无 warning
- `flutter test` 全部通过
- 如涉及原生代码变更，在真机上跑过完整的补丁加载 + 回滚流程

---

## License

MIT