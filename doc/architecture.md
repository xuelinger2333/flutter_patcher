# 技术架构

> 内部工作原理与技术细节。正常接入 flutter_patcher 不需要理解这些内容；本文档面向需要排查问题、扩展功能或评估安全模型的开发者。

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

**用户设备冷启动时：** 插件在 `Application.attachBaseContext` 阶段完成熔断检查 → 补丁校验（versionCode + MD5 + 可选签名）→ 反射替换 `FlutterLoader` → 引导 Engine 加载补丁 `.so`。首帧渲染 + 前台存活 5 秒后标记为 verified，清除熔断计数。

**补丁出问题时：** 用户最多经历一次白屏。下次冷启动插件检测到上次启动失败，自动回滚到 APK 内置版本，并将该补丁加入本地黑名单防止循环下载。完整流程见 [Crash guard](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-guard-topic.html)。

---

## 服务端集成

flutter_patcher 不绑定任何特定后端。你需要实现的最小协议如下。

### check-update 接口

客户端定期请求，服务端返回是否有新补丁：

```http
GET /api/patch/check?app_version_code=100&abi=arm64-v8a&current_patch=1.0.0-h1
```

无可用补丁：

```json
{ "has_update": false }
```

有可用补丁：

```json
{
  "has_update": true,
  "version": "1.0.0-h2",
  "patch_url": "https://cdn.example.com/patches/arm64-v8a/libapp.so",
  "md5": "0123456789abcdef0123456789abcdef",
  "target_version_code": 100
}
```

### 补丁文件托管

任何能提供 HTTP GET 下载的服务即可——CDN、对象存储、nginx 静态目录都行。

### 多 ABI 分发

服务端需按 ABI 分发不同的 `libapp.so`。客户端可通过 `await FlutterPatcher.deviceAbi` 获取当前设备 ABI，拼进 check-update 请求中。

### 推荐功能

- **崩溃上报：** 接收客户端 `droppedCircuitBreaker` 事件，同一补丁短时间收到 N 次回滚事件后自动停止下发。
- **灰度发布：** 1% → 5% → 20% → 100% 分阶段放量。
- **紧急下架：** 从 check-update 返回中移除该版本即可。

> 仓库 `example/tools/mock_server.dart` 提供了一个本地 mock server，可用于开发联调。

---

## versionCode 强绑定

`applyPatch` 落盘时将 `targetVersionCode` 写入 `patch_meta.json`。每次冷启动在反射替换之前比对，不匹配则删除补丁。

即使服务端未下发 `targetVersionCode`，APK 升级后也会自动清除旧补丁——因为 `pack` 工具会在生成补丁时记录基准 APK 的 versionCode，客户端比对宿主 APK 的 `PackageInfo.versionCode` 不一致就丢弃。

这是为什么 `pack --target-version-code` 是必填参数。

---

## 反射兼容矩阵

| Flutter 版本 | `FlutterInjector` 字段 | `ensureInitializationComplete` 签名 |
|---|---|---|
| 3.19.x ~ 3.38.x | `flutterLoader` | `(Context, @Nullable String[])` |

Flutter 大版本升级后如反射字段名变更，可临时适配：

```dart
await FlutterPatcher.init(loaderFieldCandidates: ['newFieldName', 'flutterLoader']);
```

升级后请检查 logcat 中 `FlutterPatcher/Hook` 标签的输出确认注入成功。

---

## 签名规范

Ed25519 签名提供独立于 HTTPS 的完整性校验，防止 CDN 篡改。

### 算法与编码

- **算法：** Ed25519
- **公钥格式：** X.509 SubjectPublicKeyInfo DER → Base64
- **签名消息体：** MD5 hex 字符串（32 字节 UTF-8）
- **签名编码：** Base64

### 生成密钥对

```bash
# 开发机执行一次
openssl genpkey -algorithm ed25519 -out patch_sk.pem
openssl pkey -in patch_sk.pem -pubout -outform DER | base64 -w0
# 输出类似 MCowBQYDK2VwAyEA...
```

### 服务端签名

```bash
# 消息体 = MD5 hex 字符串的 UTF-8 字节
printf "%s" "0123456789abcdef0123456789abcdef" | \
  openssl pkeyutl -sign -inkey patch_sk.pem -rawin | base64 -w0
```

### 客户端配置

```dart
await FlutterPatcher.init(publicKeyBase64: 'MCowBQYDK2VwAyEA...');
```

### 兼容性

JDK 原生 Ed25519 需要 Android 13+（API 33）。低版本设备默认拒绝带签名补丁（`strictSignature: true`）。

```dart
// 允许低版本设备降级为仅 MD5 + HTTPS 校验
await FlutterPatcher.init(
  publicKeyBase64: '...',
  strictSignature: false,
);
```

---

## pack CLI 完整参数

```bash
dart run flutter_patcher:pack \
    --apk build/app/outputs/flutter-apk/app-release.apk \
    --version 1.0.0-h1 \
    --target-version-code 100
```

| 参数 | 说明 |
|---|---|
| `--apk <path>` | 必填，release APK 路径 |
| `--version <string>` | 必填，补丁版本标识 |
| `--target-version-code <int>` | 必填，宿主 APK versionCode |
| `--abi <string>` | 可选，不传时按 `arm64-v8a` > `armeabi-v7a` > `x86_64` 优先取 |
| `--out <dir>` | 可选，默认 `dist/` |

产出：

```
dist/
├── libapp.so          # 补丁内容，上传到 CDN
└── manifest.json      # 元数据（version、md5、target_version_code、abi）
```

---

## 进阶配置

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

### 查询当前补丁版本

```dart
final version = await FlutterPatcher.currentVersion; // null = 无补丁
```

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

## 已知限制

- **iOS 不支持：** Apple 政策禁止下载可执行代码
- **Flutter Engine 升级即作废：** 大版本升级后所有旧补丁必须重新生成
- **反射依赖 Flutter 私有 API：** Flutter 大改 loader 架构时可能需要适配
- **合规风险：** 动态下发可执行代码在部分应用商店类目（面向未成年人、金融、医疗等）存在政策限制，接入前请评估目标市场要求
