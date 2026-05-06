# 架构

本文介绍 `flutter_patcher` 的工作原理、自托管服务端协议，以及少数进阶配置。

如果你只想快速接入，请先阅读 API 文档。本文更适合以下场景：

- 你想理解补丁为什么能在下次冷启动生效
- 你需要自托管补丁检查与分发服务
- 你需要评估安全、兼容性与商店合规风险
- 你的 Android 工程有特殊启动流程，例如提前预热 `FlutterEngine`

相关文档：

- 公开 API、pack CLI 参数、性能与兼容范围见 [API Reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html)
- 崩溃保护、自动回滚与黑名单机制见 [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html)

---

## 工作原理

### 概览

`flutter_patcher` 的补丁流程涉及三个角色：开发机、服务端和用户设备。

```text
  开发机                      服务端                       用户设备
─────────────              ─────────────              ─────────────
 修改 Dart 代码               存储 + 分发                  下载 + 校验
      │                          │                           │
 flutter build apk             上传补丁                   applyPatch()
      │                    libapp.so + manifest              │
 pack 提取补丁                      │                    写入本地
      │                          │                           │
      └──────────────→     CDN / 对象存储      ───────────→   下次冷启动加载
                                                             │
                                                       成功 → 继续使用补丁
                                                       失败 → 自动回滚
```

基本流程如下：

1. 修改 Dart 代码后重新构建 release APK。
2. 使用 `flutter_patcher:pack` 从 APK 中提取补丁文件和元数据。
3. 将补丁文件上传到 CDN 或对象存储。
4. 客户端检查更新，下载并校验补丁。
5. 补丁落盘后，在下一次冷启动时生效。

补丁不会在当前进程内立即替换代码。  
如果需要提醒用户重启，可以在 `applyPatch` 成功后展示提示。

---

### 补丁生命周期

用户设备上，补丁会经历以下生命周期：

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

冷启动时，插件会先检查补丁是否仍然适用于当前 APK，再进行加载。  
如果补丁无效、损坏、版本不匹配，或命中本地黑名单，插件会丢弃该补丁并回到 APK 内置版本。

崩溃保护的完整判定流程、Android 版本差异和黑名单行为见 [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html)。

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
完整机制见 [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html)。

---

## 自托管

`flutter_patcher` 不绑定任何特定后端。你可以使用自己的服务端、CDN 或对象存储来分发补丁。

客户端侧只需要拿到一个 `PatchInfo`，然后调用 `applyPatch` 即可。  
如果你使用插件内置的 check-update 协议，可以按下面的格式实现接口。

---

### 检查更新协议

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
3. 每次发布补丁时，服务端对补丁 MD5 进行签名。
4. 客户端下载补丁后，先校验 MD5，再校验签名。

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

在不支持原生 Ed25519 的 Android 低版本设备上，如果收到带签名的补丁，插件会拒绝加载，而不是静默跳过验签。

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

---

### 推荐的后端实践

#### 1. 灰度发布

建议按比例逐步放量：

```text
1% → 5% → 20% → 50% → 100%
```

每个阶段观察崩溃率、启动失败率和关键业务指标，再继续扩大范围。

#### 2. 崩溃上报联动

客户端应上报 `lastBootDiagnostic` 中的异常状态。  
其中，补丁自动回滚和熔断相关事件的具体含义见 [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html)。

如果同一补丁在短时间内多次触发回滚，服务端应自动停止下发。

#### 3. 紧急下架

紧急下架不需要删除用户本地补丁。

只要服务端停止在 check-update 接口中返回该补丁，新用户就不会继续下载。  
已经触发崩溃保护的设备，会在本地回滚并拒绝再次加载同一个问题补丁。

#### 4. 保留补丁发布记录

建议服务端记录每个补丁的：

- 补丁版本
- 目标 APK `versionCode`
- ABI
- MD5
- 签名
- 发布时间
- 灰度比例
- 当前状态：灰度中、全量、已下架

这些信息有助于排查线上问题。

---

### 本地 mock server

仓库中的 `example/tools/mock_server.dart` 提供了一个本地 mock server，可用于开发联调。

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

### bsdiff 差分补丁

默认情况下，`flutter_patcher` 使用 full 模式补丁，也就是完整下发 `libapp.so`。

如果你希望显著减小补丁体积，可以启用 `bsdiff` 差分补丁。启用后，补丁体积通常可以从数 MB 降至数十 KB，但需要额外集成 native `bspatch` 模块。

使用 bsdiff 时，服务端需要下发：

```json
{
  "mode": "bsdiff",
  "patch_url": "https://cdn.example.com/patches/arm64-v8a/app.patch",
  "md5": "DIFF_FILE_MD5",
  "target_md5": "MERGED_LIBAPP_SO_MD5",
  "target_version_code": 100
}
```

其中：

| 字段 | 说明 |
|---|---|
| `md5` | 差分补丁文件的 MD5 |
| `target_md5` | 合成后的完整 `libapp.so` 的 MD5 |
| `target_version_code` | 差分补丁适用的宿主 APK `versionCode` |

如果未启用 native bsdiff 模块，却收到了 bsdiff 补丁，客户端会返回 `bsdiffDisabled`。

---

### Flutter 兼容性

`flutter_patcher` 需要在 Android 启动早期引导 Flutter Engine 加载补丁 `.so`。

当前 pubspec 允许 Flutter `>=3.3.0`；loader hook 已验证 Flutter `3.19 ~ 3.38`。如果未来 Flutter 修改了 loader 内部结构，可能需要通过 `loaderFieldCandidates` 临时指定字段名：

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

动态下发可执行代码在部分应用商店或业务类目中可能存在限制。

接入前请评估目标市场和应用场景，尤其是：

- 面向未成年人的应用
- 金融、医疗、政务等强监管场景
- 对代码动态更新有明确限制的应用商店

`flutter_patcher` 提供技术能力，但不替代你的合规评估。
