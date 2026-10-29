# 更新日志

[English](CHANGELOG.md) | **简体中文**

## 未发布

### Changed

- 最低支持的 Flutter 版本提高到 3.32.0（Dart 3.8.0），`.so` 与字节码两条
  流程使用同一下限。Flutter 3.32 是第一个在引擎构建中提供 Dart 动态模块的
  版本，字节码流程依赖这项能力。更旧的 Flutter SDK 现在会在 `pub get` 时
  被拒绝，而不是等到 Android 构建阶段才失败。

### Removed

- `dart run flutter_patcher:pack` 与 `bin/mock_server.dart` 移入 CLI，成为
  `flutter_patcher pack` 与 `flutter_patcher mock-server`，参数不变。插件不再依赖
  `archive` 与 `args`，运行时依赖只剩 `plugin_platform_interface` 与 `crypto`。
- 移除 `build android` 与 `patch android` 的实验选项 `--framework-reuse`。它为
  宿主保留的接口使 `libapp.so` 增大约 4.5 MiB，超出 1.5 MiB 的预算，因此从未成为
  默认行为。用它构建的基线（schema 4）现在会以 `BASELINE_SCHEMA_UNSUPPORTED` 被
  拒绝，需要重新构建宿主。其他基线及其指纹不受影响。

## 0.1.4

### Fixed

- 修复宿主 App 启用 AGP 9 内置 Kotlin 时 Android 构建失败的问题，报错为
  `Failed to apply plugin 'kotlin-android'`，随后是
  `project ':flutter_patcher' does not specify compileSdk`。用 Flutter
  3.44 新建或迁移过来的项目会带上 AGP 9，因而受影响。
  `android/build.gradle` 现在会判断宿主是否真的启用了内置 Kotlin，只在
  确实存在对应 DSL 的一侧应用 Kotlin Gradle Plugin 及 jvmTarget 配置：
  应用了 KGP 时用 `kotlinOptions`，内置 Kotlin 下用
  `kotlin { compilerOptions }`。

  判据是内置 Kotlin 是否生效，而不是 AGP 主版本号。AGP 9 宿主若用
  `android.builtInKotlin=false` 关掉内置 Kotlin（Flutter 3.44 模板生成的
  就是这个默认值），插件仍需自带 KGP，与 AGP 8 宿主完全一致，走的还是
  原来那条路径。

  本次改动仅影响构建期，不改变任何运行时行为。补丁完全兼容：为 0.1.3
  产出的 payload 在 0.1.4 上安装与启动的行为完全一致，无需重新打包。

- 最低支持的 Flutter 与 AGP 版本没有变化。AGP 8 宿主的构建与此前完全相同。

### Known issues

- AGP 9 宿主下 Flutter 仍会打印 `WARNING: Your app uses the following
  plugins that apply Kotlin Gradle Plugin (KGP): flutter_patcher`。Flutter
  Gradle Plugin 靠文本匹配 `android/build.gradle` 来判断，看不到那行
  `apply plugin` 已经被条件包住。该警告可以忽略，并且这行字面量必须保留：
  Flutter Gradle Plugin 一旦在某个插件里匹配不到 KGP 声明，就会自己给该
  插件应用 `kotlin-android`，在内置 Kotlin 下会直接构建失败。
- Flutter 3.44 自带的 Gradle plugin 不支持 `android.newDsl=true`，会在任何
  插件被求值之前就应用失败。请保持模板默认的 `android.newDsl=false`。

## 0.1.3

### Added

- 新增 Android 冷启动 Flutter 资源热更新。资源（图片、字体、JSON，凡是
  `Image.asset(...)` 或 `rootBundle.load(...)` 能拿到的内容）可以和 Dart
  代码一起通过同一个 `patch.zip` 打包热更。
- `dart run flutter_patcher:pack` 新增 `--assets`。可以内联传入
  （`--assets a,b`），也可以用 `@` 前缀指向 UTF-8 文本文件
  （`--assets @patch-assets.txt`，每行一个 path，`#` 开头为注释）；内联与
  `@file` 可在同一个参数里混用。每个 path 都必须先在新 APK 的
  `pubspec.yaml` `assets:` 下登记 —— `--assets` 只是告诉 `pack`：从这些
  已编入 APK 的资源里挑哪些放进 `patch.zip`。运行时在**安装阶段**把它们
  overlay 到 APK 的 Flutter 资源 bundle 之上。

### Changed

- `dart run flutter_patcher:pack` 现在恒定输出 `dist/patch.zip` +
  `dist/manifest.json`（外层 `schemaVersion: 2`、`payload: patch.zip`），
  无论是否传 `--assets`。纯 Dart 补丁的 `patch.zip` 内仅含 `manifest.json` +
  `lib/<abi>/libapp.so`，内部 manifest 不包含 `assets` 块。原先的裸 `.so`
  输出形态已下线。
- Android runtime 识别 ZIP payload、安装 overlay asset package、生成私有
  `flutter_assets.apk`，并在带资源时通过 patched `FlutterJNI` AssetManager
  启动 Flutter；纯 Dart 的 `patch.zip` 会跳过资源 overlay，安装时表现与纯
  代码补丁一致。
- `mock_server --dist` 读取 `manifest.payload`，按声明分发对应文件。

### 兼容性

- 0.1.0–0.1.2 时代产出的裸 `.so` 补丁仍能在 0.1.3 设备上安装（runtime 保留
  了一条不在文档中暴露的 legacy 安装路径）；但 pack CLI 不再生成该格式。
  在 0.1.3+ 宿主 APK 上发布的新补丁应统一为 `patch.zip`。

## 0.1.2

### Added

- 新增 `dart run flutter_patcher:mock_server`，用于本地测试
  `checkUpdate -> applyPatch` 流程。

### Changed

- 改进 README 顶部结构，增加 TL;DR、适合 / 不适合场景、商店政策提醒和本地
  mock server 说明。
- 更新 pub.dev package description 和 topics。
- 新增 GitHub social preview 图片：`doc/social-preview.png`。

## 0.1.1+1

### Fixed

- 修正 README 安装片段中的版本号为 `^0.1.1`。
- 将英文 CHANGELOG 作为 pub.dev 展示版本，中文版本保留为 `CHANGELOG-zh.md`。

## 0.1.1

### Changed

- `PatchInfo.md5` 改为可选。空字符串表示跳过下载完整性校验，并同时跳过签名校验。
- `validatePatchArgs` 接受空 md5；非空 md5 仍要求 32 位 hex。
- 黑名单在未下发 md5 时可按 version 维度做下载前检查；入黑名单时仍记录实际 md5。
- `meta.json` 的 `effectiveMd5` 始终使用下载后实际计算的 md5。
- 放宽 Dart SDK 与运行时依赖约束，减少宿主项目依赖冲突。

## 0.1.0

首次公开发布，Android-only beta。

### Added

- 冷启动热更新：在 Android 启动早期加载补丁 `libapp.so`。
- MD5 + 可选 Ed25519 签名校验。
- 崩溃熔断 / 自动回滚 / 本地黑名单。
- `FlutterPatcher.applyProgress` 进度事件流。
- `dart run flutter_patcher:pack` 打包工具。

### Known limitations

- 仅 Android。
- 严格 Ed25519 模式需要 Android API 33+。
- 仅支持完整补丁，不支持二进制差分。
