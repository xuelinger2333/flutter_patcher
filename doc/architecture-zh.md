# 架构

[English](architecture.md) | **简体中文**

本文介绍 `flutter_patcher` 的工作原理、自托管服务端协议，以及少数进阶配置。

如果你只想快速接入，请先阅读 API 文档。本文更适合以下场景：

- 你想理解补丁为什么能在下次冷启动生效
- 你需要自托管补丁检查与分发服务
- 你需要评估安全、兼容性与商店合规风险
- 你的 Android 工程有特殊启动流程，例如提前预热 `FlutterEngine`

相关文档：

- 公开 API、pack CLI 参数、性能与兼容范围见 [API Reference](api-reference-zh.md)
- 崩溃保护、自动回滚与黑名单机制见 [Crash protection](crash-protection-zh.md)

---

## 工作原理

### 概览

`flutter_patcher` 的补丁流程涉及三个角色：开发机、服务端和用户设备。

```text
  开发机                      服务端                       用户设备
─────────────              ─────────────              ─────────────
 修改 Dart / 资源              存储 + 分发                  下载 + 校验
      │                          │                           │
 flutter build apk             上传载荷                   applyPatch()
      │                 libapp.so 或 patch.zip                │
 pack 提取载荷                      │                    原子落盘
      │                          │                           │
      └──────────────→     CDN / 对象存储      ───────────→   下次冷启动加载
                                                             │
                                                       成功 → 继续使用补丁
                                                       失败 → 自动回滚
```

自 0.1.3 起，producer 永远输出 `patch.zip`（纯 Dart 的补丁就是一个没有 `assets` 块的 `patch.zip`）。设备端为了兼容 0.1.0–0.1.2 时代发出去的裸 `libapp.so` 仍保留一条静默的 legacy 路径，但新补丁应统一为 `patch.zip`。补丁不会在当前进程内立即替换代码，下次冷启动时才生效。

---

### 补丁生命周期

用户设备上，补丁会经历以下生命周期：

```text
applyPatch（安装阶段）
  ↓
下载 patch.zip → 校验整包 MD5 + 签名
  ↓
解压 lib/<abi>/libapp.so 到 staging；如果带资源，再
  拷贝 APK 的 flutter_assets/ → 逐 path overlay → 合并资源表
  → 把结果打成私有 flutter_assets.apk
  ↓
原子提交：把 staging 的产物 rename 进 current/
  ↓
…等待下次冷启动…
  ↓
冷启动：校验 current/（versionCode + 磁盘上 libapp.so 的 MD5）
  ↓
LoaderHook 把 Flutter 指向补丁 libapp.so
  （若有资源，再指向 flutter_assets.apk）
  ↓
启动成功：继续使用补丁
启动失败：下次冷启动自动回滚
```

重活（完整性校验、资源 overlay 合成、资源表合并、私有归档打包）都发生在 `applyPatch` 内部，并且在调用返回前已经原子提交到 `current/`。冷启动只重新校验磁盘上的产物并装好 loader hook，**不会**重新打开 ZIP 或重跑 overlay 合并。

安装阶段的校验顺序（见 [PatchManager.kt:303-446](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/PatchManager.kt#L303-L446)）：整包 MD5 → Ed25519 签名 → `versionCode` 匹配（对照内层 package manifest）→ ZIP 内逐文件完整性。签名只在 `md5` 存在时才校验（签名的明文就是 md5 十六进制串）。

冷启动时，插件会重新校验磁盘上的产物是否仍属于当前 APK（`versionCode` 与存储的 MD5），再进行加载。
如果补丁无效、损坏、版本不匹配，或命中本地黑名单，插件会丢弃该补丁并回到 APK 内置版本。

崩溃保护的完整判定流程、Android 版本差异和黑名单行为见 [Crash protection](crash-protection-zh.md)。

---

### VersionCode 绑定

每个补丁都绑定到一个宿主 APK 的 `versionCode`。

冷启动时，如果当前 APK 的 `versionCode` 与补丁声明的 `targetVersionCode` 不一致，插件会自动丢弃该补丁。

这可以避免以下问题：

- 用户升级 APK 后继续加载旧补丁
- 服务端把面向旧 APK 的补丁误下发给新 APK
- 不同线上版本共用同一个不兼容补丁

因此，构建补丁时必须明确指定基准 APK 的 `versionCode`：

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.0-h1 \
  --target-version-code 100
```

这里的 `--target-version-code 100` 表示：

> 这个补丁只适用于用户设备上已安装的 `versionCode = 100` 的 APK。

如果线上同时存在多个 `versionCode`，请分别为每个基准版本构建和下发对应补丁。

---

### 崩溃安全

`flutter_patcher` 默认采用 fail-fast 策略。  
当补丁导致启动失败或首屏阶段出现严重 Dart 异常时，插件会在下次冷启动回到 APK 内置版本，并避免反复加载同一个问题补丁。

生产环境仍建议配合服务端监控和灰度发布。  
完整机制见 [Crash protection](crash-protection-zh.md)。

---

### 载荷 v2（`patch.zip`）

0.1.3+ 的 `pack` CLI 恒定输出 `patch.zip`（`schemaVersion: 2`）。0.1.0–0.1.2 时代构建的裸 `libapp.so` 仍能被设备端兼容加载，但已没有任何 producer 会再生成它 —— 新补丁请假定一律是 `patch.zip`。

`patch.zip` 内部结构：

```text
manifest.json          # schemaVersion 2；lib 映射 + 可选 assets 块
manifest_patch.json    # 资源表差量操作（只有打了资源时才存在）
lib/<abi>/libapp.so    # 补丁后的 Dart 代码（总是存在）
assets/<asset-path>    # 每个 path 一条（含分辨率变体）
```

纯 Dart 的 `patch.zip` 只包含内层 `manifest.json` 与 `lib/<abi>/libapp.so`；运行时检测到没有 `assets` 块就完全跳过资源合成。完整 schema 与校验规则见 [API 参考 → 资源补丁](api-reference-zh.md#资源补丁)。

---

### 原子安装

补丁安装是崩溃安全的。安装路径（[PatchManager.kt:482-615](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/PatchManager.kt#L482-L615)，`finalizePatch` 在 [L622-767](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/PatchManager.kt#L622-L767)）先把所有产物写到副本目录，再用一连串 rename 提交：

```text
staging/      ← 解压 libapp.so；合成 flutter_assets/ + flutter_assets.apk
   ↓ 按产物各 rename 一次（so / meta / 资源目录 / 资源 apk）
pending/      ← 短命中间态，仅在 finalizePatch 内部存在
   ↓ rename（真正的提交）— 提交前先放下 install marker
current/      ← 下次冷启动加载的就是这个；上一份移到 previous/
   ↓ finalizePatch 末尾
previous/     ← 在同一次提交中被清理
```

`pending/` **不是**"等首次启动成功"的中间态 —— 它只是 `finalizePatch` 里 rename 的临时目标。`applyPatch` 调用一旦成功返回，`current/` 就已经提升完成，`previous/` 也已清理。"首次启动成功"那道门槛是 **崩溃熔断**（见 [Crash protection](crash-protection-zh.md)）—— 上一次启动触发熔断时，下次启动会删除 `current/`；这是独立于落盘事务的另一套机制。

掉电或进程被杀可能留下 `pending/` 或 `previous/` 以及一个 install marker；下次启动 `recoverInterruptedInstall`（[PatchManager.kt:1146-1172](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/PatchManager.kt#L1146-L1172)）会自动协调：要么回滚到 `previous/`，要么丢弃半装态。

---

### 资源 overlay 合成（安装阶段）

补丁带资源覆盖时，插件会在安装阶段产出一份自包含、可被 Flutter 直接读取的资源 bundle。流程（[PatchManager.kt:482-615](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/PatchManager.kt#L482-L615)、[L848-983](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/PatchManager.kt#L848-L983)）：

1. 把基准 APK 的 `assets/flutter_assets/*` 拷到 staging 目录。
2. 按内层 manifest 列出的 path，逐条用 `patch.zip` 里的字节覆盖。
3. 用 `StandardMessageCodec` 解码基准资源表，应用 `manifest_patch.json` 的每条 `upsert`（替换或插入 variants 列表），再重新编码。
4. 对照内层 manifest 校验逐文件 MD5。
5. 把 staging 目录树重新打成一个私有 `flutter_assets.apk`，与补丁 `libapp.so` 同目录存放。

冷启动不做以上任何一步。它只遍历 `current/`，确认 `libapp.so` + `flutter_assets.apk`（若存在）仍与存储的 MD5 一致，然后交给 loader hook：

[`LoaderHook`](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/LoaderHook.kt) 劫持 `FlutterLoader.findAppBundlePath` 指向补丁 `libapp.so`，并在带资源时安装 patched `FlutterJNI` AssetManager 打开私有 `flutter_assets.apk`。未被补丁覆盖的 path 仍走 APK fallback。

`Image.asset(...)`、`rootBundle.load(...)` 以及字体查找都会自动走重定向后的 bundle —— 业务代码无需改动。

---

### 下载重试策略

下载失败时，运行时最多重试 **3 次**，指数退避约 2s / 4s / 8s（见 [PatchManager.kt:355-405](../android/src/main/kotlin/com/flutter_patcher/flutter_patcher/PatchManager.kt#L355-L405)）。最终失败时 apply 结果是 `network`。服务端可以依赖这一行为，不再额外加客户端重试层；若需要自定义抖动或上下限，可以在 `applyPatch` 外面再包一层退避循环。

---

### ABI 回退

`libapp.so` 不跨 ABI 通用。pack CLI 的 `--abi` 控制补丁里携带哪一个：

* `patch.zip` 只携带 **一个** `lib/<abi>/libapp.so`。插件按 `Build.SUPPORTED_ABIS` 的优先级读取，并接受第一个匹配项；不匹配时返回 `unsupportedAbi`。
* （Legacy：0.1.0–0.1.2 时代的裸 `.so` 载荷每包一个 ABI，服务端按 `deviceAbi` 选 URL。设备端兼容路径仍接受这种格式。）

设备端不做 ABI 之间的自动 fallback —— 选择正确的 artifact 是服务端的责任。

---

### `file://` URL 支持

`PatchInfo.patchUrl` 除了 `http(s)://` 之外，还支持 `file://` 协议。插件直接读本地文件（不走网络），按照远程载荷的完整流程校验 MD5 / 签名后落盘。这支持两种典型场景：

* **预置补丁** —— 把 `patch.zip` 打进 `assets/`，先 copy 到 cache 目录，再用 `file://` URL 调用 `applyPatch`。example 工程用 `applyPatchBytes` 演示了等价做法（连 copy 都省掉）。
* **本地 mock-server 联调** —— 把 `patchUrl` 指向 `file://` 即可绕过 HTTP；单测和离线 CI 都用得上。

---

## 自托管

`flutter_patcher` 不绑定任何特定后端。你可以使用自己的服务端、CDN 或对象存储来分发补丁。

客户端侧只需要拿到一个 `PatchInfo`，然后调用 `applyPatch` 即可。

---

### 检查更新协议（可选）

> 插件提供一个可选的最小 check-update JSON 协议，主要用于快速接入、示例和本地联调。生产环境如果已有自己的更新、灰度或鉴权协议，建议直接解析业务响应并构造 `PatchInfo`，无需遵循本节格式。下面给出的是该最小协议的参考实现。

客户端可以定期请求服务端检查是否有新补丁。

示例请求：

```http
GET /api/patch/check?app_version_code=100&abi=arm64-v8a&current_patch=1.0.0-h1
```

建议包含以下参数：

| 参数 | 说明 |
|---|---|
| `app_version_code` | 当前 APK 的 `versionCode` |
| `abi` | 当前设备 ABI，例如 `arm64-v8a` |
| `current_patch` | 当前补丁版本。无补丁时可以为空 |

无可用补丁时返回：

```json
{
  "has_update": false
}
```

有可用补丁时返回：

```json
{
  "has_update": true,
  "version": "1.0.0-h2",
  "patch_url": "https://cdn.example.com/patches/arm64-v8a/libapp.so",
  "md5": "0123456789abcdef0123456789abcdef",
  "target_version_code": 100
}
```

字段名同时支持 `snake_case`（上面示例）和 `camelCase`（`patchUrl`、`targetVersionCode`、`hasUpdate`）。服务端可以保留自己的命名风格 —— 参见 [PatchInfo.fromJson](../lib/src/patch_info.dart#L58)。

如果启用签名校验，可以额外下发 `signature`：

```json
{
  "has_update": true,
  "version": "1.0.0-h2",
  "patch_url": "https://cdn.example.com/patches/arm64-v8a/libapp.so",
  "md5": "0123456789abcdef0123456789abcdef",
  "target_version_code": 100,
  "signature": "BASE64_SIGNATURE"
}
```

---

### 托管补丁文件

补丁文件只需要能通过 HTTP GET 下载即可。

常见选择包括：

- CDN
- 对象存储
- nginx 静态目录
- 你自己的文件服务

建议开启 HTTPS，并确保服务端返回正确的文件内容和缓存策略。

---

### ABI 路由

Android 上不同 ABI 的 `libapp.so` 不可混用。

服务端需要按 ABI 下发对应补丁：

```text
patches/
├── arm64-v8a/
│   └── libapp.so
├── armeabi-v7a/
│   └── libapp.so
└── x86_64/
    └── libapp.so
```

客户端可以通过 `FlutterPatcher.deviceAbi` 获取当前设备 ABI：

```dart
final abi = await FlutterPatcher.deviceAbi;
```

然后将 ABI 放入 check-update 请求，由服务端返回匹配的补丁地址。

---

### 补丁签名

`flutter_patcher` 支持 Ed25519 签名校验。

签名用于在 HTTPS 之外提供额外完整性保护，防止 CDN 或中间链路返回被篡改的补丁。

基本方式：

1. 客户端在 `FlutterPatcher.init()` 中配置公钥。
2. 服务端持有私钥。
3. 启用签名校验的补丁发布时，服务端对补丁 MD5 进行签名。
4. 客户端下载补丁后，先校验 MD5，再校验签名。若省略 `md5`，这两项校验会按设计一并跳过。

客户端配置公钥：

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MCowBQYDK2VwAyEA...',
);
```

生成密钥对：

```bash
openssl genpkey -algorithm ed25519 -out patch_sk.pem
openssl pkey -in patch_sk.pem -pubout -outform DER | base64 -w0
```

其中：

- `patch_sk.pem` 是私钥，应只保存在服务端或构建环境
- 命令输出的 Base64 字符串是公钥，用于配置到客户端

对补丁 MD5 签名：

```bash
printf "%s" "0123456789abcdef0123456789abcdef" | \
  openssl pkeyutl -sign -inkey patch_sk.pem -rawin | base64 -w0
```

签名结果填入 check-update 响应的 `signature` 字段。

---

### strictSignature

`strictSignature` 默认为 `true`。

按既有兼容策略，在 Android API < 33 的设备上，如果收到带签名的补丁，插件会拒绝加载，而不是静默跳过验签。API ≥ 33 时该开关无影响，始终使用插件内置的 Ed25519 实现验签，不依赖系统 KeyFactory 是否支持外部公钥。实现与格式说明见 [签名验证](signature-verification.md)。

这样可以避免“配置了签名，但部分设备实际没有校验”的安全误判。

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MCowBQYDK2VwAyEA...',
  strictSignature: true,
);
```

如果你明确接受低版本设备仅依赖 MD5 + HTTPS，可以设置：

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MCowBQYDK2VwAyEA...',
  strictSignature: false,
);
```

#### 完全省略 MD5（可选）

若服务端协议不下发 md5（仅靠 HTTPS 做完整性保护），可让 `PatchInfo.md5` 留空：

```dart
PatchInfo(version: 'fix-1', patchUrl: 'https://...', targetVersionCode: 100);
```

此时下载完整性校验与签名校验**全部跳过**（Ed25519 签名输入即 md5 hex，无 md5 即无签名输入）。要保留签名校验，必须同时下发 md5。原生侧仍会在下载完成后计算实际 md5 写入 `meta.effectiveMd5`，作为运行时稳定键供启动校验和黑名单使用。

---

### 推荐的后端实践

- **灰度发布。** 典型放量节奏 `1% → 5% → 20% → 50% → 100%`；每个阶段观察崩溃率、启动失败率与关键业务指标后再继续。
- **打通 `lastBootDiagnostic` 上报。** 上报异常状态（见 [Crash protection](crash-protection-zh.md)）；若同一补丁短时间内多次触发回滚，服务端应自动停止下发。
- **紧急下架走服务端。** 在 check-update 接口里停下该补丁即可 —— 新用户不再下载，已触发崩溃保护的设备会本地回滚并拒绝再次加载。不需要远程删除指令。
- **保留发布记录。** 每个补丁记录：`version`、`targetVersionCode`、ABI、MD5 / 签名（如下发）、发布时间、灰度比例、生命周期状态（灰度中 / 全量 / 已下架）。线上排障靠的就是这些。

---

### 本地 mock server

仓库中的 `dart run flutter_patcher:mock_server` 提供了一个本地 mock server，可用于开发联调。

它会通过 HTTP 暴露本地 `libapp.so` 和 `manifest.json`，仅用于开发环境，不会被打包进 release apk，也不应在生产中使用。

```bash
dart run flutter_patcher:mock_server --dist dist
```

你可以先用 mock server 跑通完整流程，再接入自己的服务端。

---

## 进阶配置

大多数项目不需要本节配置。  
只有当你的工程有特殊启动流程、需要优化补丁体积，或遇到 Flutter 版本兼容问题时，才需要阅读本节。

---

### 手动初始化 Android

默认情况下，插件会通过 Android 自动初始化机制尽早安装补丁加载逻辑。

如果你的工程在 `Application.attachBaseContext` 中提前预热了 `FlutterEngine`，自动初始化可能晚于 Engine 创建，导致补丁来不及生效。此时可以关闭自动初始化，并手动调用初始化入口。

在 `AndroidManifest.xml` 中移除自动初始化 provider：

```xml
<provider
    android:name="com.flutter_patcher.flutter_patcher.FlutterPatcherAutoInitProvider"
    android:authorities="${applicationId}.flutter_patcher.autoinit"
    tools:node="remove" />
```

在自定义 `Application` 中手动初始化：

```kotlin
class MyApp : FlutterApplication() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        FlutterPatcherApplication.attachPatcher(base)
    }
}
```

只有在你确认工程提前创建了 `FlutterEngine` 时，才需要这样配置。

---

### Flutter 兼容性

`flutter_patcher` 需要在 Android 启动早期引导 Flutter Engine 加载补丁 `.so`。

当前 pubspec 允许 Flutter `>=3.3.0`；loader hook 已验证 Flutter `3.19 ~ 3.44`。如果未来 Flutter 修改了 loader 内部结构，可能需要通过 `loaderFieldCandidates` 临时指定字段名：

```dart
await FlutterPatcher.init(
  loaderFieldCandidates: ['newFieldName', 'flutterLoader'],
);
```

升级 Flutter 大版本后，建议检查 logcat 中 `FlutterPatcher/Hook` 标签的输出，确认补丁注入成功。

---

## 限制

### 仅支持 Android

`flutter_patcher` 仅支持 Android。

iOS 不支持动态下发可执行代码。Web、macOS、Windows、Linux 等平台调用 API 时会 no-op，不会执行补丁逻辑。

---

### APK 或 Flutter Engine 升级会使旧补丁失效

补丁与宿主 APK 的 `versionCode` 强绑定。  
APK 升级后，旧补丁会自动失效。

如果升级 Flutter Engine、Flutter SDK 或构建配置，也应重新生成补丁，不要复用旧补丁。

---

### 依赖 Flutter 内部实现细节

插件需要在 Android 启动早期影响 Flutter 加载 `libapp.so` 的过程，因此依赖 Flutter Android embedding 的部分内部实现。

当 Flutter 大版本修改 loader 架构时，可能需要插件适配。  
建议在升级 Flutter 后进行真机验证，确认补丁可以正常加载、回滚和上报诊断。

---

### 应用商店政策与合规风险

动态下发可执行代码在部分应用商店和强监管类目（金融、医疗、政务、面向未成年人的应用等）中受限。README TL;DR 已覆盖基本原则；插件只提供技术能力，不替代你自己的合规评估。
