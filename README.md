# flutter_patcher

[![Platform](https://img.shields.io/badge/platform-Android-brightgreen)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Android `libapp.so` 热更新插件 —— 后端下发补丁，下次冷启动自动生效，崩溃自动回滚。

> **仅支持 Android。** iOS 因 App Store 政策禁止下载可执行代码，不在支持范围内。

---

## 目录

- [核心能力](#核心能力)
- [支持范围](#支持范围)
- [工作流程](#工作流程)
- [快速接入](#快速接入)
- [热更新能力边界](#热更新能力边界)
- [进阶配置](#进阶配置)
- [技术细节](#技术细节)
- [已知限制与合规](#已知限制与合规)

---

## 核心能力

| 能力 | 说明 |
|------|------|
| Dart 代码热修复 | 不发版即可修 Bug、改文案、改业务逻辑 |
| 零业务耦合 | 服务端地址、公钥、版本号均由宿主传入 |
| 崩溃熔断 | 连续启动失败自动回滚到 APK 内置版本 |
| 版本强绑定 | 宿主 APK 升级后旧补丁自动失效，无需额外处理 |
| 可选 bsdiff 差分 | 补丁包体积从数 MB 降至数十 KB |

---

## 支持范围

| 维度 | 要求 |
|------|------|
| 平台 | **仅 Android**（iOS 因 App Store 政策不支持） |
| Android minSdk | 24（Android 7.0） |
| Flutter | 3.19 ~ 3.38（依赖反射字段 `FlutterInjector.flutterLoader`） |
| ABI | `armeabi-v7a` / `arm64-v8a` / `x86_64` |
| NDK | 27.0.12077973+ |
| AGP | 8.11.1+ |
| Kotlin | 2.2.20+ |
| Java / JVM | 17 |

> 老项目接入可能需要把 AGP / Kotlin / NDK 升到上表对齐。未验证过的 Flutter 版本见 [Flutter 大版本升级适配](#flutter-大版本升级适配)。

---

## 工作流程

```
冷启动
  │
  ├─ 熔断器检查 → 连续失败次数是否超限？
  │                 ├─ 是 → 删除补丁，使用 APK 内置版本
  │                 └─ 否 ↓
  ├─ 补丁校验 → versionCode + MD5 + 签名（可选）
  ├─ 反射替换 FlutterLoader → 引导 Engine 加载补丁 .so
  └─ 标记「启动中」
          ↓
    Dart 引擎加载补丁 → 首帧渲染成功 → 清除熔断计数
```

---

## 快速接入

### 1. 添加依赖

```yaml
dependencies:
  flutter_patcher:
    path: ../flutter_patcher  # 也可使用 git 或 pub 源
```

### 2. 配置 AndroidManifest + Application

`android/app/src/main/AndroidManifest.xml` 里先声明网络权限：

```xml
<manifest>
  <uses-permission android:name="android.permission.INTERNET" />
  <application ...>
    ...
  </application>
</manifest>
```

然后根据你的项目情况二选一挂载补丁加载：

**方式 A｜没有自定义 Application**（默认 `flutter create` 项目通常是这种）：在 `<application>` 标签加一个 `android:name`：

```xml
<application
    android:name="com.flutter_patcher.flutter_patcher.FlutterPatcherApplication"
    ...>
```

**方式 B｜已有自定义 Application**（做了 Firebase / 埋点 / MMKV 初始化等）：**保留你自己的基类**，在 `attachBaseContext` 里加一行即可：

```kotlin
class MyApp : FlutterApplication() {   // 或 MultiDexApplication 等，保持你原来的基类
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        FlutterPatcherApplication.attachPatcher(base)   // ← 只需这一行
    }
}
```

Manifest 里保持你自己的 `android:name` 不变。两种方式行为完全等价。

### 3. 初始化

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}
```

### 4. 检查并应用补丁

用你自己的方式（Dio、gRPC、配置中心……）从后端拿到补丁信息，构造 `PatchInfo` 传入即可：

```dart
final result = await FlutterPatcher.applyPatch(PatchInfo(
  version: '1.0.1-h1',                                    // 补丁版本标识
  patchUrl: 'https://cdn.example.com/libapp.so',           // 下载地址
  md5: '0123456789abcdef0123456789abcdef',                 // 文件 MD5（小写 hex）
  targetVersionCode: 100,                                  // 目标宿主 APK versionCode
));

if (result.ok) {
  // 补丁已写入本地，下次冷启动生效
} else {
  debugPrint('apply failed: ${result.error?.name} ${result.message}');
}
```

插件不绑定任何后端协议——你的服务端返回什么格式都行，只要能提取出上面四个字段。

> 签名校验（`signature`）、差分更新（`mode` + `targetMd5`）等可选字段见 [进阶配置](#进阶配置)。


---

## 热更新能力边界

本插件**只替换 Dart 编译产物 `libapp.so`**，因此：

### ✅ 可以热更

- 任意 Dart 代码：Widget、业务逻辑、状态管理、路由、算法
- Dart 层的字符串、常量、字面量
- 纯 Dart 三方包升级（不引入新 native plugin）

### ❌ 不能热更（必须发版）

- AndroidManifest 变更（权限 / Activity / Service）
- Kotlin / Java / C++ 原生代码
- Android 资源（drawable / strings.xml / 主题）
- Flutter assets（字体、图片、JSON 等 `flutter_assets/` 内容）
- Flutter Engine 升级（Engine 变更后所有旧补丁作废）
- 新增 native plugin（新 `.so` 或新权限 APK 中不存在）

### ⚠️ 需谨慎评估

- **混淆配置变更**：符号表不匹配，功能正常但崩溃栈不可读
- **多 ABI / 多 flavor**：服务端需按 ABI × flavor × versionCode 三维切流，发错会崩
- **破坏性 Dart API 变更**：补丁回滚后旧持久化数据可能与新代码不兼容

### 发版前检查清单

发补丁前逐项确认：

- [ ] 只修改了 `lib/` 下的 Dart 源码
- [ ] `pubspec.yaml` 的 dependencies / assets 无变化
- [ ] `android/` / `ios/` 目录无变化
- [ ] Flutter SDK 大版本未升级
- [ ] `targetVersionCode` 与目标宿主 APK 一致

任一条不满足，走正常发版。

---

## 进阶配置

### 使用内置 checkUpdate（可选）

如果项目没有现成的后端接口，插件内置了一个最小的更新检查实现。后端按以下格式返回 JSON 即可直接使用：

```json
{
  "hasUpdate": true,
  "patch": {
    "version": "1.0.1-h1",
    "patchUrl": "https://cdn.example.com/libapp.so",
    "md5": "0123456789abcdef0123456789abcdef",
    "targetVersionCode": 100
  }
}
```

无可用更新时返回 `{"hasUpdate": false}`。

调用方式：

```dart
final check = await FlutterPatcher.checkUpdate('https://your.server/hotfix');
if (check.hasUpdate) {
  final result = await FlutterPatcher.applyPatch(check.patch!);
}
```

字段名同时兼容 snake_case（`patch_url`、`target_version_code` 等）。

> 这只是一个便捷工具。如果你的后端已有自己的接口格式，直接用 [快速接入 Step 4](#4-检查并应用补丁) 的方式构造 `PatchInfo` 更简单，不需要为本插件调整后端协议。
### 签名校验

Ed25519 签名提供纵深防御，防止 CDN 或中间人篡改补丁。

**① 生成密钥对（开发机执行一次）：**

```bash
# 生成私钥
openssl genpkey -algorithm ed25519 -out patch_sk.pem

# 导出公钥（X.509 SubjectPublicKeyInfo DER → Base64）
openssl pkey -in patch_sk.pem -pubout -outform DER | base64 -w0
# 输出类似 MCowBQYDK2VwAyEA...
```

**② 服务端对补丁签名：**

```bash
# 消息体 = md5 小写 hex 字符串的 UTF-8 字节（32 字节）
printf "%s" "0123456789abcdef0123456789abcdef" | \
  openssl pkeyutl -sign -inkey patch_sk.pem -rawin | base64 -w0
# 将输出填入 checkUpdate 响应的 signature 字段
```

**③ 客户端启用：**

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MCowBQYDK2VwAyEA...',
);
```

> **关于低版本设备：** JDK 原生 Ed25519 需要 Android 13+（API 33）。默认 `strictSignature: true`，低版本设备遇到带签名补丁时拒绝加载。若用户群以低版本为主且可接受降级，设置 `strictSignature: false` 使低版本设备仅靠 MD5 + HTTPS 防篡改。注意这会引入攻击面。

### 熔断阈值

默认连续 2 次启动失败即回滚。可调整：

```dart
await FlutterPatcher.init(maxCrashCount: 3);
```

### 手动回滚

```dart
await FlutterPatcher.rollback(); // 删除补丁 + 重置熔断，下次冷启动恢复 APK 内置版本
```

### 查询当前补丁版本

```dart
final version = await FlutterPatcher.currentVersion; // null 表示无补丁
```

### 启用 bsdiff 差分

默认关闭。启用后补丁包体积可从数 MB 降至数十 KB。

**① 下载 upstream 源码** 到 `android/src/main/cpp/third_party/`：

- [bsdiff-4.3](https://www.daemonology.net/bsdiff/)（`bspatch.c`）
- [bzip2-1.0.x](https://sourceware.org/pub/bzip2/)（全部 `.c` + `bzlib.h`）

目录结构：

```
android/src/main/cpp/third_party/
├── bsdiff/bspatch.c
└── bzip2/{blocksort,bzlib,compress,crctable,decompress,huffman,randtable}.c + bzlib.h
```

**② 修改 `bspatch.c`**，将 `main` 函数替换为：

```c
int flutter_patcher_bspatch(const char *old_path,
                            const char *new_path,
                            const char *patch_path) {
    // 原 main 内部逻辑，argv[1]/[2]/[3] 替换为三个参数
}
```

**③ 重新构建：**

```bash
flutter clean && flutter build apk
```

构建日志中出现 `building with upstream bsdiff + bzip2` 即成功。

**④ 服务端生成差分包：**

```bash
bsdiff libapp_v1.so libapp_v2.so patch.bsdiff
```

下发时设置 `mode: "bsdiff"`、`md5` 为 patch.bsdiff 的 MD5、`targetMd5` 为 libapp_v2.so 的 MD5。

### Flutter 大版本升级适配

本插件通过反射替换 `FlutterInjector.flutterLoader`，当前覆盖 **Flutter 3.19 ~ 3.38**。

如果升级后反射字段名变更，可在不升级插件的前提下临时适配：

```dart
await FlutterPatcher.init(
  loaderFieldCandidates: ['newFieldName', 'flutterLoader'],
);
```

升级后请冒烟验证：构建 release APK 并检查 logcat 是否有 `FlutterPatcher/Hook: FlutterLoader patched via field 'xxx'` 日志。若出现 `install failed` 或 `no exact-name match`，按上述方式传入新字段名。

> **关于启发式兜底**：当指定字段名和类型匹配都失败时，插件默认放弃 hook、回退到 APK 内置版本（比"随便命中一个字段导致崩溃"更安全）。调研新 Flutter 版本的字段名时可临时打开：
> ```dart
> await FlutterPatcher.init(loaderFallbackHeuristic: true);
> ```
> **生产环境不建议打开。**

### 下载 / 应用进度

想给用户展示"下载 40%"？订阅 `FlutterPatcher.applyProgress`（广播流），`applyPatch` 过程中会依次发射 `downloading`（多次，带字节数）→ `verifying` → 可选 `bsdiff_merging` → `finalizing`：

```dart
final sub = FlutterPatcher.applyProgress.listen((p) {
  switch (p.phase) {
    case PatchApplyPhase.downloading:
      setState(() => _progress = p.fraction ?? 0);  // fraction=null 说明服务端未返回 Content-Length
      break;
    case PatchApplyPhase.verifying:
    case PatchApplyPhase.bsdiffMerging:
    case PatchApplyPhase.finalizing:
      // 刷 "处理中..." UI
      break;
  }
});
final result = await FlutterPatcher.applyPatch(info);
await sub.cancel();
```

进度事件在 200ms 节流下发，避免 UI 抖动。`downloading` 阶段如果服务端没发 `Content-Length`，`totalBytes == -1`、`fraction == null`，这时只能展示"已下载 X bytes"而非百分比。

### 错误码与错误处理

`applyPatch` 返回 `PatchApplyResult`，失败时 `result.error` 给出分类。建议处理：

| 错误码 | 典型原因 | 建议处理 |
|---|---|---|
| `invalidArgs` | 服务端下发 JSON 缺字段 | 告警服务端，不重试 |
| `bsdiffDisabled` | 宿主未编译 bsdiff | 告警服务端对此客户端切回 full 模式 |
| `network` | 下载失败（已重试 3 次） | 稍后重试 |
| `md5Mismatch` | CDN 脏数据或服务端 md5 错算 | 排查后重试 |
| `signatureInvalid` | 签名验证不通过 | **可能被篡改，不要自动重试**，上报 |
| `bsdiffApplyFailed` | 基础 libapp.so 与服务端预期不符 | 检查 APK / diff 生成逻辑 |
| `targetMd5Mismatch` | 合成结果 md5 不对 | 同上 |
| `ioError` | 磁盘满 / 权限 / rename 失败 | 稍后重试 |
| `unknown` | 未分类异常 | 看 `result.message` + logcat |

```dart
final r = await FlutterPatcher.applyPatch(info);
if (!r.ok) {
  switch (r.error!) {
    case PatchApplyError.network:
    case PatchApplyError.ioError:
      // 静默重试
      break;
    case PatchApplyError.signatureInvalid:
      // 上报监控，不重试
      reportSecurityEvent(r.message);
      break;
    default:
      log.warning('patch apply: ${r.error?.name} / ${r.message}');
  }
}
```

---

## 技术细节

> 以下内容为内部工作原理，正常接入无需阅读，排查问题时参考。

### 启动失败熔断机制

| 时机 | 行为 |
|------|------|
| `Application.attachBaseContext` | 写入 `patch_loading=true`（同步 commit） |
| Dart `FlutterPatcher.init()` | 再写一次 `patch_loading=true`（兜底） |
| 首帧渲染成功 | `patch_loading=false`，`crash_count=0` |
| 下次冷启动发现 `patch_loading==true` | `crash_count += 1` |
| `crash_count >= maxCrashCount` | 删除补丁，回退 APK 内置版本 |

为什么没有"native 启动成功但 Dart 白屏"的中间态？因为这种场景用户体验等同崩溃，必须计入熔断。

### versionCode 强绑定机制

补丁 `.so` 与宿主 APK 的 Flutter Engine / Dart kernel 深度绑定，APK 升级后硬盘上的旧补丁与新 Engine 不兼容。

- **写入**：`applyPatch` 落盘时将 `targetVersionCode` 写入 `patch_meta.json`，优先用服务端下发值，否则取当前 APK 的 `longVersionCode`
- **校验**：每次冷启动 `attachBaseContext` 阶段，在反射替换 **之前** 比对，不匹配则删除补丁
- **兜底**：即使服务端未下发 `targetVersionCode`，APK 升级后下次冷启动也会自动清除旧补丁

### 反射兼容矩阵

| Flutter 版本 | `FlutterInjector` 字段 | `ensureInitializationComplete` 签名 |
|---|---|---|
| 3.19.x ~ 3.38.x | `flutterLoader` | `(Context, @Nullable String[])` |

`--aot-shared-library-name=<path>` 参数从 Flutter 1.x 起稳定存在，跨大版本兼容。

### 签名消息体规范

| 项目 | 规范 |
|------|------|
| 算法 | Ed25519 |
| 公钥格式 | X.509 SubjectPublicKeyInfo DER → Base64 |
| 签名消息体 | `md5` 字段值（小写 hex 字符串）的 UTF-8 字节，共 32 字节 |
| 签名输出 | Ed25519 签名 → Base64 |

---

## 已知限制与合规

- **iOS 不支持**：Apple 政策禁止下载可执行代码
- **ABI 范围**：`armeabi-v7a` / `arm64-v8a` / `x86_64`，服务端需按 ABI 切流
- **Flutter Engine 升级即作废**：大版本升级后所有旧补丁必须重新生成
- **反射依赖 Flutter 私有 API**：Flutter 4.x 如大改 loader 架构，本库可能需要适配
- **合规风险**：动态下发可执行代码在 Google Play 及各应用商店的部分类目（面向未成年人、金融、医疗等）存在政策限制，接入前请自行评估目标市场要求

---

## License

MIT
