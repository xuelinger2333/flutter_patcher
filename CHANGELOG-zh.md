# 更新日志

[English](CHANGELOG.md) | **简体中文**

## 1.1.0

1.1.0 让补丁变成一个文件。`patch` 为每个宿主写出一个文件，例如 `1-arm64-v8a.fptc`；App 用任何方式拿到
这个文件交给插件，插件校验后安装，下次冷启动生效。签名变为可选，插件也不再自行获取任何内容：`checkUpdate`
和 `applyPatch` 保留为可选的下载器。自行分发只需要 `build` 和 `patch`；`serve` 是开发辅助工具，`publish`
是可选的发布命令。已上线的 1.0.0 宿主不受影响，见下文"从 1.0 升级"。

### Removed

以下删除对用到它们的代码和脚本是不兼容的改动，是在次版本中有意为之：它们所属的签名清单协议已被移除，
没有可以对应的新接口。用到它们的 Dart 代码会编译失败；CLI 会报未知命令或未知参数。

- Dart：`SignedManifest`、`SignedUpdateResult`、`FlutterPatcher.fetchSignedManifest`、`applySignedManifest`
  和 `updatePublicationTrust`。请改用 `applyPatchBytes` 或 `applyPatchFile` 处理补丁文件，或使用
  `checkUpdate` 和 `applyPatch`。
- CLI：`trust sign` 和 `trust publish`（不再需要）；`publish --production --request`（清理时直接删除存储中
  的文件）；`keys import --rotate`；`keys init --role`；`keys export --without-root`。
- 清单协议的错误码：`PUBLISH_BUSY`、`PUBLISH_CATALOG_FULL`、`PUBLISH_CATALOG_INVALID`、
  `PUBLISH_COMMIT_UNKNOWN`、`PUBLISH_DELETE_UNKNOWN`、`PUBLISH_MANIFEST_CONFLICT`、`PUBLISH_OBJECT_CHANGED`、
  `PUBLISH_PATCH_INVALID`、`PUBLISH_RETENTION_STALE`、`PUBLISH_TARGET_MISMATCH`、`PUBLISH_UPLOAD_FAILED`、
  `PUBLISH_URL_INVALID`、`PUBLISH_URL_UNREACHABLE`，以及所有 `TRUST_*`。

### Changed

- **用补丁文件代替签名清单。** 补丁文件（FPTC v1）由 146 字节的文件头（魔数、版本、宿主指纹、序号、
  payload 长度、payload 的 SHA-256、Ed25519 签名或全 0）和其后的补丁 ZIP 组成；没有 payload 的文件是撤回。
  设备只安装正好属于本宿主、内容完整、宿主有公钥时由它签名、且序号大于所有已接受文件的文件；每次冷启动
  还会再次检查已安装的补丁。见[工作原理](doc/architecture-zh.md)。
- **签名变为可选。** `build` 不需要密钥：`flutter_patcher.yaml` 中没有 `trust.patch` 时，构建不签名的宿主
  并打印 `WARNING: UNSIGNED`。宿主保持构建时的模式。不签名宿主接受本构建的任何文件，能把文件交给 App
  的一方就能在 App 中执行代码；内置下载器只接受 HTTPS，以及指向设备本机的明文 HTTP。
- 宿主策略改为 schema 2：`application_id`、`version_code`、`flavor`、`channel`、`abi`、`strategy` 和
  `fptc_key`（补丁公钥；不签名的宿主为 `-`）。
- 补丁文件在 flavor 和渠道为默认的 `default`、`production` 时命名为 `<version_code>-<abi>.fptc`，例如
  `1-arm64-v8a.fptc`；否则为 `<version_code>-<flavor>-<channel>-<abi>.fptc`，例如
  `3-paid-beta-arm64-v8a.fptc`。flavor 和渠道只含字母、数字和 `_`，因此不同宿主的文件名不会相同；`build`
  拒绝其他字符。
- `publish` 是可选的发布命令。它用发布时编号的序号重新封装补丁输出，把 `<fileName>` 写在存储的根目录下
  （`file://`，默认 `.flutter_patcher/updates`，或 `s3://`）。只有序号更大时才替换那里的文件（否则报
  `PUBLISH_SEQUENCE_CONFLICT`）；同一个补丁报 `already_published`；发布过程中文件被改动时报
  `PUBLISH_CONFLICT`；非交互环境下没有 `--yes` 时只预览。签名和不签名的宿主走同一个流程，是否签名由宿主
  决定；签名宿主取不到私钥时，在写入任何内容之前报 `KEYS_NOT_FOUND`。`publish --withdraw` 写入撤回文件，
  发布 `patch --withdraw` 的输出也是如此。`publish` 不再读取 `url`。
- `serve` 只是开发调试工具。它在 `127.0.0.1:8686`（USB 连接的 Android 设备通过 `adb reverse`）按原样提供
  `patch` 为每个宿主写出的最新文件，补丁或撤回文件都可以，并在约 2 秒内发现每次新的 `patch`。它不再发布、
  不写存储、不重新编号、不签名，`flutter_patcher.yaml` 中的 `store` 是什么都能用。某个宿主的最新输出没有
  文件时（签名的宿主，而本机没有它的私钥），它会说明原因，不为该宿主提供任何文件；请 `keys import` 后重新
  patch。
- `checkUpdate()` 只读取 `<url>/<fileName>` 的前 146 字节（`Range` 请求）；那里没有文件（404）即为没有
  更新。既没有传入也没有构建时写入的 `url` 时，抛出 `PatcherException`。
- 序号改为 Unix 秒：文件以封装时的时间编号。`currentVersion`、`PatchInfo.version`、
  `PatchBootDiagnostic.patchVersion` 以及 `BlacklistEntry.version` 中的序号显示这样的数字，而不再是
  1、2、3……；在界面上显示它们的 App 会显示新的数字。
- `flutter_patcher.yaml` 的 `trust` 只读取 `patch`；1.0 写在那里的 `root` 和 `publisher` 公钥被忽略。
- 只有一把密钥：补丁密钥。`keys init`、`export`、`import`、`status` 只处理它；1.0 的密钥包和密钥库目录
  仍然可用，只使用其中的补丁密钥。`signing.command` 总是以 `FLUTTER_PATCHER_SIGN_ROLE=patch` 签名。
- 安全：在签名宿主上安装恶意补丁，现在只需要补丁私钥。1.0 需要补丁和 publisher 两把私钥，但两者在同一个
  密钥包中、由同一条命令使用。补丁私钥丢失或泄露时，用它构建的宿主需要发布新版本，与 1.0 的补丁私钥相同；
  没有密钥轮换。
- `build` 和 `doctor --project` 不再因 Dart 源码使用 CRLF 换行而警告（`CRLF_DART_SOURCES`）。换行方式只在打补丁时的检出与构建宿主时不同才有影响；这时 `PATCH_NATIVE_CHANGE` 会说明原生文件只是换行不同，并列出这些文件。
- 设备第一次作为 1.1 宿主启动时，删除 1.0 保存的签名清单状态（Android 的
  `noBackupFilesDir/flutter_patcher_auth/`，iOS 插件目录下的 `auth/`）。
- Android 插件自行声明网络权限（新建 Flutter 项目的 release 构建没有它），使用 `checkUpdate` 时 App 不必再手动添加。
- `build` 只输出一行简短摘要：`app`（要安装的 APK 或 IPA）、`application_id`、`version_code`、`strategy`、`signed`、`fingerprint` 和 `report`（App 旁边 `build.json` 中的完整报告）。

### Added

- `FlutterPatcher.patchTarget`：本宿主安装的文件名，它的版本号、flavor、渠道、ABI、策略和指纹，是否签名，
  以及已接受的最大序号，供由服务端挑选文件的 App 使用。
- `FlutterPatcher.inspectPatch(header)`：根据文件的前 146 字节判断它对本宿主是否是新的。
- `FlutterPatcher.applyPatchBytes(bytes)` 和 `applyPatchFile(path)`：安装 App 以任何方式拿到的补丁文件，
  或应用撤回。
- `patch` 同时把补丁文件写入输出目录，并输出 `file`（完整路径）、`seq` 和 `signed`。签名宿主而本机没有私钥
  时，`file` 为 null，由 `publish` 封装，或 `keys import` 私钥后重新 patch。
- `patch android|ios --withdraw` 以同一个文件名写出该宿主的撤回文件：应用它的设备删除补丁，运行安装包自带的
  版本。它只需要基线，不做任何编译。
- `publish --seq <n>` 指定文件序号；默认为当前的 Unix 时间（秒），并且必须大于存储中现有文件的序号。
- `serve` 支持 `checkUpdate` 发出的 `Range` 请求。

### 从 1.0 升级

- 已上线的 1.0.0 宿主继续用 1.0.0+1 打补丁：它们的补丁用 flutter_patcher 1.0.0+1 生成、发布和撤回。
  在 1.1 上为 1.0 的基线运行 `patch` 会报 `PATCH_BASELINE_INCOMPATIBLE`。
- 项目照常可用：命令、`flutter_patcher.yaml` 和密钥库都不需要改动。下一次 `build` 起构建的是 1.1 宿主，
  用现有的补丁密钥签名。
- 存储中 1.0 的文件（`manifests/`、`objects/`、`catalog.json`）1.1 不读不写，继续为 1.0 宿主服务；1.1
  的文件与它们并列放在存储根目录下。1.0 未完成的发布（`.dart_tool/flutter_patcher/publish-pending.json`）
  1.1 不处理，请用 1.0.0+1 完成。
- 替换对已删除 API 的调用：App 自行获取的文件用 `applyPatchBytes` 或 `applyPatchFile`，放在 URL 下的文件
  用 `checkUpdate` 和 `applyPatch`。

## 1.0.0+1

### Fixed

- pub.dev 上的 1.0.0 包漏掉了 `lib/src/cli/build/`，导致命令行工具无法运行，pub.dev 的静态分析也失败。
  1.0.0+1 包含全部源码文件，其他没有变化；请使用 1.0.0+1 代替已撤回的 1.0.0。

## 1.0.0

1.0.0 围绕签名更新和四条命令的工作流重建了 flutter_patcher。使用 0.1.x 的 App
需要重新构建并发布一次；0.1.x 的补丁和 `pack` 工具不能用于 1.0.0 的宿主。见
[快速上手](doc/getting-started-zh.md)。

### Added

- **支持 iOS。** 在 Apple Silicon Mac 上用 `build ios` 构建 iOS 宿主；`patch ios`
  可在 Linux、Windows 或 macOS 上运行。
- **字节码补丁**：Android 的默认策略、iOS 唯一的策略。补丁只包含改动的代码，由引擎
  内置的解释器执行，未改动的代码仍以机器码运行。纯 Dart 依赖和资源也可以更新。
  `build android --strategy so` 保留 0.1.x 替换 `libapp.so` 的方式，并同样使用签名更新。
- **命令行工具随本包发布**：`dart run flutter_patcher <命令>`，版本始终等于 App 解析到的
  插件版本。在项目中，常规流程不需要任何参数：
  - `keys init` 生成 root、publisher、patch 三对密钥：私钥保存在用户的密钥库中，公钥写入
    `flutter_patcher.yaml`；`keys export`、`keys import`、`keys status`
    用于迁移和查看密钥；
  - `build android|ios` 构建宿主并归档基线，宿主策略（包名、版本号、密钥等）自动生成，
    并写入设备下载补丁的地址 `url`；
  - `patch android|ios` 与线上版本的基线对比，生成未签名的补丁，并拒绝补丁无法携带的
    改动（原生代码、FFI、删除资源等），给出原因。它不需要私钥，也不访问发布存储；补丁
    序号由 `publish` 分配，同一版本依次为 1、2、3……，也可用 `--seq` 指定；
  - `publish` 编号前先读取 `url` 上该版本的清单，本地记录丢失后序号也能接着往上走；预览后
    签名并把补丁写入发布存储；`publish --withdraw` 撤回该版本已发布的全部补丁；提交过程中被
    中断的发布会在下次运行时自动续上；
  - `serve` 在开发时自动发布新补丁，并提供给 USB 连接的 Android 设备；
  - `doctor` 检查工具链。
- **签名更新。** 设备只安装用你的密钥签名、正好对应其包名、版本号、flavor、渠道和
  ABI、且序号大于已接受序号的补丁；撤回同样需要签名。存储和 CDN 不需要被信任。
  root 密钥可以在不发新版的情况下更换 publisher 密钥（`trust sign`、`trust publish`、
  `updatePublicationTrust`）。
- **私钥不在项目中。** `publish`、`serve` 和 `trust sign` 依次从 `--key-file`、环境变量
  `FLUTTER_PATCHER_KEYS`（CI 的 secret）、外部签名命令 `signing.command`（KMS 或签名服务）
  和密钥库获取每把私钥，并与项目的公钥核对。
- `applySignedManifest` 和 `fetchSignedManifest`（以及 `SignedManifest`、`SignedUpdateResult`），
  供自行分发清单和补丁的 App 使用。
- `PatchBootStatus.bytecodeBootFailed` 和 `soBootFailed`：启动失败但尚未达到熔断阈值。
- 引擎和工具来自不可变的产物 release，并记录在每个基线中，已上线的 App 始终可以用
  构建时的那一套继续打补丁。

### Changed

- 需要 Flutter 3.47.0（Dart 3.13.0）及以上，支持 Flutter 3.47.0 – 3.47.9。
- `checkUpdate()` 检查 `build` 从 `flutter_patcher.yaml` 写进 App 的 `url`（没填时是 `serve`
  提供补丁的 `http://127.0.0.1:8686`）；`checkUpdate(url: ...)` 检查别的地址。它在那里校验
  签名清单。把它返回的 `PatchInfo` 原样传给 `applyPatch`。
- Android 插件不再自行应用 Kotlin Gradle 插件：在 AGP 9 上由 AGP 内置的 Kotlin 编译，
  在 AGP 8 上使用 App 自己的 Kotlin 插件。两种情况下 Kotlin 都以 JVM 17 为目标。
- 补丁只在 Android 9（API 28）及以上、App 的主进程中生效；Android 7–8 上 App 按原包运行。
- 只通过 HTTPS 获取更新，开发时允许设备本机回环地址的 HTTP；不跟随重定向。
- `lastBootDiagnostic` 返回本次启动的记录：在带补丁的启动首帧之前调用时会等待首帧，最多 10 秒。
- `BlacklistEntry.version` 以 `<宿主指纹>:<序号>:<补丁 SHA-256>` 标识补丁。

### Removed

- 0.1.x 的更新流程：`dart run flutter_patcher:pack` 与 mock server；`applyPatchBytes`；
  `init` 与 `checkUpdate` 的 `publicKeyBase64`、`strictSignature`、`headers` 参数；
  `PatchInfo.patchUrl`、`md5`、`signature`、`targetVersionCode`、`fromJson`、`toJson`；
  `PatchCheckResult.fromJson` 与 JSON 更新检查协议。未用 `flutter_patcher build` 构建的
  App 只运行原始代码，在其上调用 `checkUpdate` 会抛出 `PatcherException`。
- 1.0.0 宿主不会报告的取值：`PatchApplyError.md5Mismatch`、`unsupportedAbi`、
  `assetPackageInvalid`；`PatchBootStatus.droppedSignatureInvalid`、`droppedMd5Mismatch`、
  `droppedMetaCorrupted`；`BlacklistEntry.md5`。黑名单条目的 `reason` 始终是 `BOOT_CRASH`。
- `FlutterPatcher.reportBootSuccess()`：插件在首帧时由原生代码确认启动成功。

### 从 0.1.x 迁移

1. 把 Flutter 升级到 3.47，依赖改为 `flutter_patcher: ^1.0.0`。
2. 运行 `dart run flutter_patcher keys init`，并用 `keys export --out <文件>` 备份私钥。
3. 用 `dart run flutter_patcher build android` 构建 App 并发布。
4. 在 `flutter_patcher.yaml` 中把 `url` 设为发布存储对外提供访问的地址，调用 `checkUpdate()`
   （见[生产部署](doc/production-playbook-zh.md)），之后用 `patch` 和 `publish` 发布补丁。

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
