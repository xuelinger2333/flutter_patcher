## 0.1.1+1

### Fixed

- README 安装片段中的版本号修正为 `^0.1.1`（仅文档，不影响代码）。
- CHANGELOG 翻译为英文以满足 pub.dev pana 的 ASCII 检查；中文版保留为
  `CHANGELOG-zh.md`。

## 0.1.1

### Changed

- **`PatchInfo.md5` 改为可选字段**。空字符串表示调用方明确选择跳过下载完整性
  校验，仅靠 HTTPS 防篡改。空 md5 时签名校验也会一并跳过（Ed25519 输入即
  md5 hex）。`toJson` 在 md5 为空时不输出 `md5` 键。
- **`validatePatchArgs`**：md5 空串现在合法；非空时仍强制 32 位 hex。
- **黑名单**：调用方未下发 md5 时，下载前置黑名单检查退化为仅 version 维度
  （新增 `BlacklistStore.containsByVersion`）。入黑时仍写入下载后实际计算的
  md5 作为条目记录。
- **meta.json 写入**：`effectiveMd5` 始终使用下载后实际计算的 md5（之前为
  下发 md5）。
- **依赖约束放宽**：Dart SDK 约束从 `^3.10.7` 放宽为 `>=3.0.0 <4.0.0`，
  运行时依赖改为下限 + 宽上限；`archive` 允许 3.x 和 4.x，以减少宿主项目
  依赖冲突。

## 0.1.0

首次公开发布（Android-only beta）。

### 核心能力

- **冷启动热更新**：在 `Application.attachBaseContext` 早于 Dart 引擎反射
  替换 `FlutterLoader.findAppBundlePath`，实现 `libapp.so` 整包替换。
- **签名校验**：内置 Ed25519（X.509 SubjectPublicKeyInfo）+ MD5 双重校验，
  支持 `strictSignature` 严格模式防止低版本设备降级绕过。
- **崩溃熔断 / 自动回滚**：基于 `ApplicationExitInfo` 的 `REASON_CRASH`
  计数 + Dart 层 `PlatformDispatcher.onError` 钩子，达到 `maxCrashCount`
  （默认 1，fail-fast）后自动删补丁、入黑名单、回退 APK 内置版本。
- **首帧 verify 清熔断**：补丁加载后，前台连续存活 `verifyAfter`
  （默认 5s）才视为 verified 并清零熔断计数。
- **本地黑名单**：自动入黑名单的补丁不会再次安装，避免反复崩溃。可通过
  `FlutterPatcher.blacklist` / `clearBlacklist` 查询/清空。
- **进度事件流**：`FlutterPatcher.applyProgress` 暴露 `downloading` /
  `verifying` / `finalizing` 阶段事件。
- **CLI 打包工具**：`dart run flutter_patcher:pack` 从 release APK 提取
  `libapp.so` 并生成补丁 manifest。

### 已知限制

- **仅 Android**。iOS / Web / 桌面平台调用所有 API 为 no-op（首次调用打印
  warning）。
- **Ed25519 严格模式需 Android API 33+**。低于 API 33 的设备在
  `strictSignature: true`（默认）时会拒绝带签名的补丁。
- **仅支持 full 模式补丁**。差分补丁能力未随 0.1.0 发布，避免暴露未验证路径。
- 不支持 Dart AOT 之外的代码热更新（不替换 `flutter_assets`、
  `isolate_snapshot_data` 等）。

### 文档

- 仓库 README：使用场景、5 分钟 demo、接入步骤
- `doc/architecture.md`：原生 + Dart 双层架构与启动时序
- `doc/api-reference.md`：完整 API 参考
- `doc/crash-protection.md`：熔断器与回滚策略说明
