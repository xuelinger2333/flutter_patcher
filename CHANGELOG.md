## 0.1.0

首次公开发布（Android-only beta）。

### 核心能力

- **冷启动热更新**：在 `Application.attachBaseContext` 早于 Dart 引擎反射替换 `FlutterLoader.findAppBundlePath`，实现 `libapp.so` 整包替换。
- **签名校验**：内置 Ed25519（X.509 SubjectPublicKeyInfo）+ MD5 双重校验，支持 `strictSignature` 严格模式防止低版本设备降级绕过。
- **崩溃熔断 / 自动回滚**：基于 `ApplicationExitInfo` 的 `REASON_CRASH` 计数 + Dart 层 `PlatformDispatcher.onError` 钩子，达到 `maxCrashCount`（默认 1，fail-fast）后自动删补丁、入黑名单、回退 APK 内置版本。
- **首帧 verify 清熔断**：补丁加载后，前台连续存活 `verifyAfter`（默认 5s）才视为 verified 并清零熔断计数。
- **本地黑名单**：自动入黑名单的补丁不会再次安装，避免反复崩溃。可通过 `FlutterPatcher.blacklist` / `clearBlacklist` 查询/清空。
- **进度事件流**：`FlutterPatcher.applyProgress` 暴露 `downloading` / `verifying` / `bsdiff_merging` / `finalizing` 阶段事件。
- **bsdiff 增量补丁**：可选的 `mode: bsdiff` 模式支持差量分发，减少补丁包体积。
- **CLI 打包工具**：`dart run flutter_patcher:pack` 从两次构建的 `libapp.so` 生成签名补丁包。

### 已知限制

- **仅 Android**。iOS / Web / 桌面平台调用所有 API 为 no-op（首次调用打印 warning）。
- **Ed25519 严格模式需 Android API 33+**。低于 API 33 的设备在 `strictSignature: true`（默认）时会拒绝带签名的补丁。
- 不支持 Dart AOT 之外的代码热更新（不替换 `flutter_assets`、`isolate_snapshot_data` 等）。

### 文档

- 仓库 README：使用场景、5 分钟 demo、接入步骤
- `docs/architecture.md`：原生 + Dart 双层架构与启动时序
- `docs/api-reference.md`：完整 API 参考
- `docs/crash-guard.md`：熔断器与回滚策略说明
