# 错误码与排障

[English](troubleshooting.md) | **简体中文**

> 找到命令输出的错误码或警告，确认原因并修复；或者查明设备为什么不安装、不运行补丁。

某个命令失败或给出了警告，或者补丁没有出现在设备上。在本页搜索你看到的错误码或原文。常见问题排在前面，每条都有原样输出、原因和修复方法；全部错误码见[全部错误码](#全部错误码)。设备上的问题通过 Dart API 而不是 CLI 错误码报告，见[设备端](#设备端)。

| 症状 | 条目 |
|---|---|
| `build` 失败或给出警告 | [`BASELINE_RELEASE_CONFLICT`](#baseline_release_conflict) · [`HOST_UNSUPPORTED`](#host_unsupported) · [`PUB_LOCKFILE_MISMATCH`](#pub_lockfile_mismatch) · [`WARNING: UNSIGNED`](#warning-unsigned) · [`WARNING: BASELINE_STORE_LOCAL`](#warning-baseline_store_local) |
| `patch` 失败或没有写出文件 | [所有文件都显示有改动](#所有文件都显示有改动) · [`BASELINE_NOT_FOUND`](#baseline_not_found) · [`PATCH_BASELINE_INCOMPATIBLE`](#patch_baseline_incompatible) · [`BASELINE_STORE_UNREACHABLE`](#baseline_store_unreachable) · [`patch` 成功但没有文件](#patch-成功但没有文件) |
| `publish` 或 `serve` 失败 | [`PUBLISH_SEQUENCE_CONFLICT`](#publish_sequence_conflict) · [`KEYS_NOT_FOUND`](#keys_not_found) · [`SERVE_PORT_BUSY`](#serve_port_busy) |
| 设备拿不到补丁或不运行补丁 | [`checkUpdate` 始终找不到更新](#checkupdate-始终找不到更新) · [补丁已安装但没有运行](#补丁已安装但没有运行) |

## 错误的输出格式

| 命令 | stderr 输出 | 退出码 |
|---|---|---|
| `build`、`patch`、`baseline` | 一行包含 `code` 和 `message` 的 JSON | `2` |
| 其他命令 | `CODE: message` | `2` |
| `doctor` 的某项检查未通过 | `CODE: message` | `1` |
| 任何命令的警告 | `WARNING: <CODE>: <text>` | 不变 |

```json
{"command":"patch","status":"failed","code":"PATCH_NATIVE_CHANGE","message":"Native plugin/build hook changed: camera"}
```

`message` 指出涉及的文件、包或配置项。脚本中按 `code` 判断结果，不要匹配 `message`：报错文字会随版本变化，错误码不会。

## 常见问题

### 所有文件都显示有改动

```json
{"command":"patch","status":"failed","code":"PATCH_NATIVE_CHANGE","message":"Application native files differ from the release only in line endings (CRLF/LF): …. Check out the sources with the line endings the host was built from (git core.autocrlf), then patch again."}
```

**怎么确认**：你只改了一行 Dart，而 `patch` 输出的 `changed` 列出了所有文件，或者 `patch` 以上面的 `message` 失败。

**原因**：源文件与基线逐字节对比。Git for Windows 默认把换行符转换成 `CRLF`，所以在 Windows 上检出的代码，每个文件都与在 Linux 或 macOS 上用 `LF` 构建的宿主不同。

**修复**：

1. 在 `.gitattributes` 中加入 `* text=auto eol=lf`，或者把 git 的 `core.autocrlf` 设为构建宿主的机器所用的值。
2. 重新检出源码。
3. 重新运行 `patch`。

### `BASELINE_NOT_FOUND`

```json
{"command":"patch","status":"failed","code":"BASELINE_NOT_FOUND","message":"No archived release-…; check --flavor/--version-code, or pass --fingerprint for a legacy baseline."}
```

**怎么确认**：`message` 中给出了 `patch` 查找的版本，由 flavor、构建号和 ABI 组成。

**原因**：`patch` 按 flavor 和构建号查找基线，构建号默认是 `pubspec.yaml` 中 `+` 之后的数字。要么这一组合从未构建过，要么本机读取的基线存储不是 `build` 写入的那一个。

**修复**：按顺序检查：

1. `pubspec.yaml` 中的构建号是线上版本的构建号；不是时传 `--version-code <n>`。
2. `--flavor` 与 `build` 时使用的 flavor 一致。
3. `flutter_patcher.yaml` 中的 `baseline_store`，或 `--baseline-store`，指向 `build` 使用的存储。

基线已被删除时，这个构建无法再打补丁：发布新的商店版本。

### `BASELINE_RELEASE_CONFLICT`

```json
{"command":"build","status":"failed","code":"BASELINE_RELEASE_CONFLICT","message":"release-… is already archived with different content: …; bump versionCode."}
```

**怎么确认**：你用相同的 flavor 和构建号再次运行了 `build`，而且代码或依赖与上次构建不同。

**原因**：一个版本只有一份基线。内容相同的重复构建沿用已有基线；内容不同时被拒绝，因为替换基线会让已经发出去的 App 匹配不上自己的基线。

**修复**：

1. 该构建已上线时，提升 `pubspec.yaml` 中的构建号，或传 `--version-code`，然后重新构建。
2. 该构建从未发布时，从基线存储中删除 `message` 指出的对象（`release-<flavor>-<version_code>-<abi>.tar.gz`），然后重新构建。

### `PATCH_BASELINE_INCOMPATIBLE`

```json
{"command":"patch","status":"failed","code":"PATCH_BASELINE_INCOMPATIBLE","message":"This host was built with flutter_patcher 1.0; patch and publish for it with flutter_patcher 1.0.0+1."}
```

**怎么确认**：`message` 属于下表中的某一种情况。

**原因**：当前的 flutter_patcher，或所选的 Flutter SDK，不能为这个宿主打补丁。

**修复**：按 `message` 处理：

| `message` | 修复 |
|---|---|
| `This host was built with flutter_patcher 1.0; …` | 用 flutter_patcher 1.0.0+1 为该宿主生成、发布和撤回补丁；见[从 1.0 升级](upgrading-zh.md) |
| `SDK differs from baseline`，或 `SDK or engine build differs from the release` | 补丁必须用构建该版本的 Flutter 生成。切换到那个版本，或传 `--flutter-sdk <path>` |
| 以 `rebuild host` 结尾，或以 `Rebuild this bytecode host` 开头 | 宿主缺少当前版本需要的记录。构建并发布新的宿主 |
| 来自 `publish`：`… is not a patch output of this flutter_patcher; patch again.` | `--patch` 指向的目录是 flutter_patcher 1.0 写出的。重新运行 `patch` |

### `BASELINE_STORE_UNREACHABLE`

```json
{"command":"patch","status":"failed","code":"BASELINE_STORE_UNREACHABLE","message":"Cannot tell whether … exists: … The store must report a missing object as HTTP 404 or S3 NoSuchKey (an S3 role needs s3:ListBucket)."}
```

**怎么确认**：用同一份凭据能访问存储，例如对一个存在的对象运行 `aws s3 ls` 成功，而 `message` 以 `Cannot tell whether` 开头。

**原因**：对不存在的对象，存储必须返回 `404`（S3 上为 `NoSuchKey`）。没有 `s3:ListBucket` 的角色得到的是 `403`，部分 CDN 也是如此，所以 flutter_patcher 无法区分“基线不存在”和“请求被拒绝”。

**修复**：

1. 给该角色授予存储桶的 `s3:ListBucket`。
2. 重新运行命令。

这个错误码下的其他 `message` 指出的是网络或凭据问题；各类存储的要求见[基线存储](cli-zh.md#基线存储)。

### `patch` 成功但没有文件

```json
{"command":"patch","status":"patch_created","file":null,"notice":"This host accepts only files signed by its patch key, which this machine does not have: `flutter_patcher keys import` it here and patch again, or run `flutter_patcher publish --patch` with this output where it is.", …}
```

**怎么确认**：`patch` 以 `0` 退出，输出中的 `file` 为 `null`。

**原因**：宿主已签名，而本机的所有来源都没有它的私钥，所以 `patch` 只写出了草稿。

**修复**：任选其一：

1. 在本机运行 `keys import <bundle>`，然后重新运行 `patch`。
2. 在有密钥的机器上运行 `publish --patch <output>`。

`keys status` 显示会用哪个来源签名；见[私钥从哪里来](cli-zh.md#私钥从哪里来)。

### `PUBLISH_SEQUENCE_CONFLICT`

```text
PUBLISH_SEQUENCE_CONFLICT: The store holds 7-arm64-v8a.fptc numbered …, which devices may have taken already; this one would be …. Check this computer's clock, or publish with --seq ….
```

**怎么确认**：`message` 中的第一个数字大于或等于第二个。

**原因**：文件的序号是封装时的 Unix 秒。存储中的文件是由时钟偏快的电脑发布的，或者发布时传了大于当前时间的 `--seq`。已经拿到它的设备只安装序号更大的文件。

**修复**：

1. 校准本机时钟，重新运行 `publish`。
2. 存储中的序号仍然更大时，用 `message` 建议的 `--seq` 发布。

### `KEYS_NOT_FOUND`

```text
KEYS_NOT_FOUND: No private key for patch key … in …. Run `flutter_patcher keys import`, set FLUTTER_PATCHER_KEYS or configure signing.command.
```

**怎么确认**：`publish` 在写入任何内容之前失败，`keys status` 输出 `"private_key":"none"`。

**原因**：宿主已签名，而 `message` 列出的来源都没有它的私钥。

**修复**：任选其一：

1. 在有密钥的机器上运行 `keys export --out <file>`，再在本机运行 `keys import <bundle>`。
2. 在 CI 中设置 `FLUTTER_PATCHER_KEYS`；见[CI 中的密钥](advanced-zh.md#ci-中的密钥)。

密钥的所有副本都丢失时，用它构建的宿主不再接受新的补丁文件：见[3. 开启签名](production-playbook-zh.md#3-开启签名)。

### `HOST_UNSUPPORTED`

```json
{"command":"build","status":"failed","code":"HOST_UNSUPPORTED","message":"build ios requires macOS with Xcode; patch ios runs on every host."}
```

**怎么确认**：`message` 给出了检测到的电脑类型，或者说明 `build ios` 需要 macOS。

**原因**：该命令不能在这个操作系统或 CPU 上运行。

**修复**：在受支持的电脑上运行：

| 命令 | 支持的电脑 |
|---|---|
| `build android` | Linux x64、Windows x64、Apple Silicon Mac |
| `build ios` | Apple Silicon Mac |
| `patch android`、`patch ios` | 以上任意一种 |

### `PUB_LOCKFILE_MISMATCH`

```json
{"command":"build","status":"failed","code":"PUB_LOCKFILE_MISMATCH","message":"pubspec.lock does not match pubspec.yaml or this shell's package host (https://pub.dev). Run `flutter pub get` in the project from this shell, then try again."}
```

**怎么确认**：`message` 中给出了当前终端的包源地址。

**原因**：`pubspec.lock` 与 `pubspec.yaml` 不一致，或者它是用另一个包源解析的，例如只在某一个终端中设置了 `PUB_HOSTED_URL` 镜像。

**修复**：

1. 在用来构建的终端中，在项目里运行 `flutter pub get`。
2. 重新运行命令。

### `SERVE_PORT_BUSY`

```text
SERVE_PORT_BUSY: Port 8686 is in use on this computer; choose another with --port.
```

**怎么确认**：`serve` 立即退出。

**原因**：另一个程序（通常是之前启动的 `serve`）正在监听这个端口。

**修复**：

1. 停止那个程序，或运行 `serve --port <port>`。
2. 换了端口时，把手机的 `8686` 映射过去：`adb reverse tcp:8686 tcp:<port>`，因为构建时没有 `url` 的 App 检查的是 `8686`。

### `WARNING: UNSIGNED`

```text
WARNING: UNSIGNED: this host accepts patch files that are not signed, so whoever can hand the app a file can run code in it. To sign, set trust.enabled to true in flutter_patcher.yaml (run `flutter_patcher init` first if it names no key) and build again.
```

**怎么确认**：`flutter_patcher.yaml` 中没有补丁密钥，或 `trust.enabled` 为 `false`。

**原因**：签名处于关闭状态，`init` 生成的项目默认如此。

**修复**：

1. `flutter_patcher.yaml` 中没有 `trust.patch` 时，运行 `dart run flutter_patcher init`。
2. 在 `flutter_patcher.yaml` 中设置 `trust.enabled: true`。
3. 重新构建。

**忽略会怎样**：App 安装本构建的任何完整补丁文件。已发布的宿主无法更改这一点，所以要得到签名宿主，只能发布新的商店版本。

### `WARNING: BASELINE_STORE_LOCAL`

```text
WARNING: BASELINE_STORE_LOCAL: this host's baseline is kept only in …; every patch of the host needs it, so set baseline_store in flutter_patcher.yaml to a durable store.
```

**怎么确认**：`flutter_patcher.yaml` 中没有 `baseline_store`，`build` 也没有带 `--baseline-store`。

**原因**：基线只保存在项目的 `.flutter_patcher/baselines/` 中。

**修复**：设置 `baseline_store`；见[2. 保管基线](production-playbook-zh.md#2-保管基线)。

**忽略会怎样**：这个目录丢失后，这个构建无法再打补丁，`patch` 以 `BASELINE_NOT_FOUND` 失败。

### `checkUpdate` 始终找不到更新

**怎么确认**：`checkUpdate()` 返回 `hasUpdate: false`，或者 `serve` 输出 `A device checked for updates`，但始终没有 `A device downloaded`。

**原因**：设备请求 `<url>/<fileName>`，并且只接受属于自己这个构建、序号大于它已接受的所有文件的文件。

**修复**：按顺序检查：

1. 文件名：把 `(await FlutterPatcher.patchTarget).fileName` 与你提供的文件名对比，把 `url` 与文件所在的地址对比。调用中没有 `url` 时，App 使用构建时 `flutter_patcher.yaml` 中的 `url`，所以修改后要重新构建。
2. 上传：存储为 `file://` 时，`publish` 只写入本机。每次 `publish` 之后，把文件上传到 `<url>/<fileName>`。
3. 序号：文件的序号必须大于 `patchTarget.acceptedSeq`。重新上传的旧文件不满足这一点；重新运行 `patch` 或 `publish`。
4. 构建：文件必须属于已安装的构建（`patchTarget.versionCode`、`flavor`、`channel`、`abi`、`fingerprint`）。用户升级 App 之后，为新的构建生成补丁。
5. 服务器：必须通过 HTTPS 应答，不使用 `3xx` 重定向，没有文件时返回 `404`，并且 `.fptc` 文件的缓存时间不能长；见[下载服务器](cli-zh.md#下载服务器)。

要查看设备如何判断一个文件，把它的前 146 字节传给 `FlutterPatcher.inspectPatch`：`reason` 说明它为什么不算新文件。

### 补丁已安装但没有运行

**怎么确认**：`applyPatch` 返回 `ok: true`，冷启动之后 App 仍然是旧的行为。

**原因**：补丁在启动时失败并被停用，或者 App 已升级。

**修复**：

1. 读取 `FlutterPatcher.lastBootDiagnostic`：`status` 说明补丁为什么被跳过或回滚。
2. 按[启动诊断](crash-protection-zh.md#启动诊断)中对应的 `status` 处理。

## 全部错误码

### 环境和工具链

| 错误码 | 出现条件 | 处理方法 |
|---|---|---|
| `FLUTTER_NOT_FOUND` | `PATH` 中没有 `flutter` | 把 Flutter 加入 `PATH`，或传 `--flutter-sdk` |
| `FLUTTER_VERSION_INVALID` | 读不到 Flutter 版本 | 运行 `flutter --version` 检查 SDK |
| `SDK_NOT_READY` | 所选的 Flutter SDK 未初始化，或缓存不完整 | 运行一次 `flutter doctor` 后重试 |
| `SDK_PREPARE_FAILED` | flutter_patcher 用于构建的 Flutter SDK 副本无法准备 | 检查网络和磁盘空间后重试 |
| `ENGINE_ARTIFACT_MISSING` | 这个 Flutter 版本没有对应的 flutter_patcher 引擎，或无法下载 | 使用 Flutter 3.47.0 到 3.47.9；检查网络 |
| `ENGINE_ARTIFACT_MISMATCH`<br>`ARTIFACT_HASH_MISMATCH`<br>`ARTIFACT_INVALID`<br>`ENGINE_MANIFEST_INVALID`<br>`TOOLS_ARTIFACT_MISSING`<br>`TOOLS_VERSION_UNSUPPORTED`<br>`YAML_CACHE_INVALID`<br>`YAML_GENERATION_FAILED`<br>`EMBEDDING_POM_UNAVAILABLE` | 下载的引擎或工具文件不完整，或校验和不符 | 检查网络后重试；损坏的缓存条目会被隔离并重新下载 |
| `CACHE_INVALID` | 命令使用的某个路径（缓存、项目、存储、密钥、输出或 receipt）是符号链接，或经过符号链接 | 使用真实路径 |
| `HOST_UNSUPPORTED` | 该命令不能在这个操作系统或 CPU 上运行 | 见 [`HOST_UNSUPPORTED`](#host_unsupported) |
| `ANDROID_SDK_MISSING` | 找不到 Android SDK 或其 `build-tools` | 设置 `ANDROID_HOME`，或运行 `flutter config --android-sdk` |
| `JAVA_HOME_INVALID` | `JAVA_HOME` 没有指向 JDK | 修正 `JAVA_HOME` |
| `XCODE_MISSING` | 没有安装 Xcode 或 iOS 平台 | 安装 Xcode，并在 Xcode 设置中安装 iOS 平台 |
| `DISK_FULL` | 磁盘已满 | 释放空间后重试 |
| `PUB_LOCKFILE_MISMATCH` | `pubspec.lock` 与 `pubspec.yaml` 或包源不一致 | 见 [`PUB_LOCKFILE_MISMATCH`](#pub_lockfile_mismatch) |
| `TOOL_FAILED` | 某个构建工具以错误退出 | 阅读 `message` 中该工具输出的末尾 |
| `CONFIG_INVALID` | `flutter_patcher.yaml` 无效（未知的配置项、类型错误的值、没有有效 `patch` 的 `trust`），选项无效，或没有设置 `HOME`/`USERPROFILE` | 按 `message` 指出的内容修正 |
| `USAGE_ERROR` | 命令行有误，包括使用了 1.1 中删除的命令或选项 | 用 `--help` 运行该命令；见[1.1 中删除的内容](cli-zh.md#11-中删除的内容) |
| `DOCTOR_FAILED` | `doctor` 遇到意外错误 | 阅读 `message` |
| `INTERFACE_INPUT_MISSING`<br>`INTERFACE_GENERATION_FAILED`<br>`INTERFACE_INDEX_FAILED`<br>`INTERFACE_VALIDATION_FAILED`<br>`INTERFACE_NOT_CONVERGED`<br>`INTERFACE_NO_PROGRESS` | 维护者命令 `interface` 失败 | 仅维护者使用；阅读 `message` |

### 密钥和签名

| 错误码 | 出现条件 | 处理方法 |
|---|---|---|
| `KEYS_NOT_CONFIGURED` | 在没有 `trust.patch` 的项目中运行 `keys export` | 运行 `init`，或 `keys import` 项目的密钥包 |
| `KEYS_NOT_FOUND` | 为签名宿主运行 `publish`，而所有来源都没有私钥；`--key-file` 或 `keys import` 的文件不存在；本机密钥库中没有密钥时运行 `keys export` | 见 [`KEYS_NOT_FOUND`](#keys_not_found) |
| `KEYS_MISMATCH` | 第一个密钥来源中的密钥不是宿主的密钥；`keys import` 的密钥不是 `flutter_patcher.yaml` 指定的那一把 | 使用项目的密钥。宿主只接受构建时的密钥，所以换新密钥需要新的宿主 |
| `KEYS_ALREADY_CONFIGURED` | 在没有补丁密钥、且仍有 1.0 之前的 `flutter_patcher_keys/` 目录的项目中运行 `init` | 运行 `keys import flutter_patcher_keys`，因为已发布的宿主只接受这把密钥 |
| `KEYS_BUNDLE_INVALID` | 文件不是密钥包，或其中没有补丁密钥；或 `~/.flutter_patcher/keys/` 中 `message` 指出的文件已损坏 | 使用 `keys export` 写出的文件 |
| `SIGNER_COMMAND_FAILED` | `signing.command` 无法启动、以非零退出、超过 60 秒、没有输出 base64 的 64 字节签名，或用了另一把密钥 | 用相同的环境变量手动运行该命令；见[用 KMS 或签名服务签名](advanced-zh.md#用-kms-或签名服务签名) |
| `KEYS_OUTPUT_EXISTS`<br>`KEYS_OUTPUT_UNAVAILABLE` | 输出文件已存在，或无法创建密钥库目录 | 换一个新文件；检查 `~/.flutter_patcher/keys` 的权限 |
| `KEYS_PERMISSIONS_FAILED` | 无法把私钥文件限制为仅当前用户可读 | 使用支持文件权限的文件系统 |
| `KEYS_IO_ERROR` | 密钥无法读取或写入 | 检查目录权限后重试 |

### `build`

| 错误码 | 出现条件 | 处理方法 |
|---|---|---|
| `BUILD_CONFIG_INVALID` | `pubspec.yaml` 中没有 `+` 构建号、application id 不唯一、`--host-policy` 文件无效、`--flavor` 或 `--version-code` 与该策略不一致、编译期变量或 `--` 之后的选项不被接受，或输出目录已存在 | 按 `message` 指出的内容修正，例如 `version: 1.0.0+1`、`--application-id`、新的 `--out` |
| `BUILD_PROJECT_INVALID` | 不支持的项目结构，例如源码包中有符号链接 | 按 `message` 的说明调整项目 |
| `BUILD_BOOTSTRAP_UNAVAILABLE` | 项目没有依赖 `flutter_patcher` | 运行 `flutter pub add flutter_patcher` |
| `BUILD_INPUT_CHANGED` | 构建过程中源文件发生了变化 | 重新构建，期间不要修改文件 |
| `BUILD_STEP_FAILED` | 某个 Flutter 构建步骤失败 | 阅读 `message` 中的日志末尾和日志目录 |
| `BUILD_APK_INVALID`<br>`BUILD_IPA_INVALID`<br>`ENGINE_INJECTION_FAILED` | 构建出的 App 未通过校验，例如 application id 或构建号与宿主策略不同 | iOS 上检查代码签名和 `--export-method`；使用 `--host-policy` 时检查 `application_id` 和 `version_code` |
| `BASELINE_RELEASE_CONFLICT` | 这个构建号已有内容不同的基线 | 见 [`BASELINE_RELEASE_CONFLICT`](#baseline_release_conflict) |
| `BASELINE_CONTENT_CONFLICT` | 相同的源码产生了不同的构建输出 | 提交 issue |
| `BUILD_FAILED` | 意外错误 | 阅读 `message` |

### 基线存储

| 错误码 | 出现条件 | 处理方法 |
|---|---|---|
| `BASELINE_NOT_FOUND` | 存储中没有该版本的基线 | 见 [`BASELINE_NOT_FOUND`](#baseline_not_found) |
| `BASELINE_STORE_UNREACHABLE` | 存储无法访问、拒绝凭据，或对不存在的对象返回 `403` | 见 [`BASELINE_STORE_UNREACHABLE`](#baseline_store_unreachable) |
| `BASELINE_STORE_PROTOCOL` | 存储不支持“不存在才创建”的写入 | 见[基线存储](cli-zh.md#基线存储) |
| `BASELINE_INVALID` | 基线已损坏 | 用副本恢复该对象；没有副本时发布新的商店版本 |
| `BASELINE_FINGERPRINT_MISMATCH` | 基线不属于所请求的版本 | 检查 `--version-code`、`--flavor` 和 Flutter 版本 |
| `BASELINE_ARTIFACTS_MISSING`<br>`BASELINE_SCHEMA_UNSUPPORTED`<br>`BASELINE_NOT_RELEASE` | 基线由更早的、不兼容的 flutter_patcher 写出 | 构建并发布新的宿主 |
| `BASELINE_RELEASE_AMBIGUOUS` | 同一版本的旧格式记录与当前格式记录不一致 | 删除 `message` 指出的那一个 |
| `BASELINE_OPERATION_FAILED` | 意外错误 | 阅读 `message` |

### `patch`：补丁无法携带的改动

每一项被拒绝的原因见[能更新什么](architecture-zh.md#能更新什么)。

| 错误码 | 出现条件 | 处理方法 |
|---|---|---|
| `PATCH_NATIVE_CHANGE` | 原生代码、原生插件或构建钩子有改动，或新增了原生依赖。使用与宿主不同版本的 flutter_patcher 也算这类改动 | 还原原生改动，或发布商店版本；用构建宿主时的 flutter_patcher 版本打补丁。没有改动原生代码时，见[所有文件都显示有改动](#所有文件都显示有改动) |
| `PATCH_PINNED_PACKAGE_CHANGED` | 某个必须保持基线版本的包（它含有原生代码，或被原生代码依赖）改了版本 | 按 `message` 的提示，在 `dependency_overrides` 中把它固定回基线版本 |
| `PATCH_FFI_UNSUPPORTED` | 补丁携带的代码通过 `dart:ffi` 调用原生函数；补丁携带的是整个包，而不只是改动的那几行 | 把 FFI 调用移到保留在宿主中的包里（例如插件），或发布商店版本 |
| `PATCH_UNSAFE` | 字节码兼容性检查未通过 | 阅读 `message` 中列出的违规项 |
| `PATCH_DYNAMIC_ICON` | 代码在运行时构造非 `const` 的 `IconData` | 使用 `const IconData(...)` 或 `Icons.*` |
| `PATCH_ASSET_DELETE_UNSUPPORTED` | 删除了 App 的某个资源 | 恢复该资源，或发布商店版本 |
| `PATCH_ENGINE_UNSUPPORTED` | 宿主的引擎不能安装补丁资源 | 构建并发布新的宿主 |
| `PATCH_NO_CHANGES` | 与基线相比没有任何改动 | 保存你的修改；确认目标版本 |

### `patch`：警告

补丁已生成，但其中一部分不是在所有地方都生效。

| 警告 | 出现条件 | 忽略会怎样 |
|---|---|---|
| `PATCH_NATIVE_ASSET_READER` | 原生代码读取了这个补丁改动的资源 | 原生代码读到的仍是安装包中的原始资源 |
| `PATCH_BACKGROUND_ENTRY` | 某个入口运行在独立的 Flutter 引擎中，例如后台任务 | 该入口运行安装包中的原始代码和资源 |
| `PATCH_RESOURCE_SIZE` | 补丁中的资源合计超过 16 MB | 它们在进程存活期间一直占用内存 |

### `patch`：其他错误

| 错误码 | 出现条件 | 处理方法 |
|---|---|---|
| `PATCH_BASELINE_INCOMPATIBLE` | 当前的 flutter_patcher 或 Flutter 版本不能为该宿主打补丁 | 见 [`PATCH_BASELINE_INCOMPATIBLE`](#patch_baseline_incompatible) |
| `PATCH_TARGET_MISMATCH` | 入口文件与宿主的不同 | 传入 `build` 时使用的 `--target` |
| `PATCH_BUILD_INPUTS_MISMATCH` | `--target` 不是宿主的入口文件，或宿主构建时 `pubspec.yaml` 中没有 `version` 而现在有 | 去掉 `--target`；去掉 `version`，或发布新的宿主 |
| `PATCH_DEFINE_UNREAD` | 没有 Dart 源码用 `fromEnvironment` 或 `hasEnvironment` 读取 `patch` 传入的编译期变量 | 检查变量名 |
| `PATCH_DRAFT_INVALID` | 输出目录中没有有效的 `patch.draft` | 传入当前版本 `patch` 的输出，或重新运行 `patch` |
| `PATCH_CONFIG_INVALID` | 选项无效，或输出目录已存在 | 按 `message` 指出的内容修正 |
| `PATCH_COMPILE_FAILED` | Dart 编译失败 | 先确认 `flutter build` 能成功 |
| `PATCH_SOURCE_INVALID`<br>`PACKAGE_INPUT_INVALID` | 不支持的源码包结构，例如符号链接 | 按 `message` 的说明调整结构 |
| `PATCH_ASSET_INVALID`<br>`FONT_SUBSET_FAILED` | 某个资源或图标字体无法处理 | 修复 `message` 指出的文件 |
| `PATCH_TOOL_FAILED` | 编译或对比工具失败 | 阅读 `message` 中的工具输出 |
| `PATCH_PACKAGE_INVALID` | 补丁无法打包 | 提交 issue |
| `PATCH_FAILED` | 意外错误 | 阅读 `message` |

### `publish` 和 `serve`

| 错误码 | 出现条件 | 处理方法 |
|---|---|---|
| `PUBLISH_CONFIG_INVALID` | 没有可发布的补丁输出、有多余的参数、`--receipt` 文件已存在，或 `store` 地址带有凭据、查询参数或片段 | 先运行 `patch` 或传 `--patch`；换一个新的 receipt 文件；修正 `store` |
| `PUBLISH_SEQUENCE_CONFLICT` | 存储中文件的序号大于或等于新序号，或 `--seq` 不在 1 到 4294967295 之间 | 见 [`PUBLISH_SEQUENCE_CONFLICT`](#publish_sequence_conflict) |
| `PUBLISH_CONFLICT` | 存储中的文件在读取和写入之间发生了变化，例如另一次 `publish` | 重新运行 `publish` |
| `PUBLISH_STORE_UNAVAILABLE` | 没有 AWS CLI 或它运行失败、存储不支持条件写入，或角色没有 `s3:ListBucket` | 见[发布存储](cli-zh.md#发布存储) |
| `PUBLISH_STORE_INVALID` | `s3://` 存储不是存储桶根目录之下由字母、数字、`_` 和 `-` 组成的前缀；或存储中以该宿主文件名命名的文件不是补丁文件，或超过 320 MiB | 修正 `store`；删除 `message` 指出的文件 |
| `PUBLISH_FAILED` | 意外错误 | 检查存储并阅读 `message` |
| `SERVE_PORT_BUSY` | 端口被占用 | 见 [`SERVE_PORT_BUSY`](#serve_port_busy) |

### 其他警告

| 警告 | 出现条件 | 忽略会怎样 |
|---|---|---|
| `UNSIGNED`、`BASELINE_STORE_LOCAL` | `build` 时缺少对应的配置 | 见[常见问题](#常见问题)中的条目 |
| `ARTIFACT_CHECK_SKIPPED` | 无法下载制品索引 | 命令使用缓存的索引继续运行 |

## 仅 flutter_patcher 1.0

flutter_patcher 1.1.0 或更新版本不会输出这些错误码。它们来自 flutter_patcher 1.0.0+1，用 1.0.0 构建的宿主用该版本打补丁；见[从 1.0 升级](upgrading-zh.md)。

| 错误码 | 出现条件 | 处理方法（使用 1.0.0+1） |
|---|---|---|
| `PUBLISH_BUSY`<br>`PUBLISH_COMMIT_UNKNOWN`<br>`PUBLISH_UPLOAD_FAILED`<br>`PUBLISH_DELETE_UNKNOWN` | 之前的发布或清理被中断 | 在同一个项目中重新运行 `publish`，或同一个请求文件；它从 `.dart_tool/flutter_patcher/publish-pending.json` 继续 |
| `PUBLISH_URL_UNREACHABLE`<br>`PUBLISH_URL_INVALID` | `publish` 读不到 `url` 上该版本的清单 | 修正 `url` 或网络；尚未发布任何内容的版本，该地址必须返回 `404` |
| `PUBLISH_CATALOG_INVALID`<br>`PUBLISH_CATALOG_FULL` | `catalog.json` 已损坏、属于另一个 application id，或达到 8 MiB | 每个 App 使用独立的存储路径，不要手动修改其中的文件 |
| `PUBLISH_MANIFEST_CONFLICT` | 重写 `manifests/<hash>.json` 时它一直在变化 | 重新运行 `publish` |
| `PUBLISH_RETENTION_STALE`<br>`PUBLISH_OBJECT_CHANGED` | 清理计划已过期 | 重新运行 dry run |
| `PUBLISH_TARGET_MISMATCH` | 补丁不属于该版本 | 为该版本重新生成补丁 |
| `PUBLISH_PATCH_INVALID` | 补丁包已损坏或超过 320 MB | 减少资源后重新生成补丁 |
| `PUBLISH_SIGNATURE_INVALID` | 签名无法用基线中的补丁密钥或 `--root-public` 验证 | 用构建宿主时的密钥发布 |
| `TRUST_CONFIG_INVALID`<br>`TRUST_INVALID`<br>`TRUST_REPLAY`<br>`TRUST_SCOPE_CONFLICT`<br>`TRUST_CONFLICT`<br>`TRUST_OUTPUT_EXISTS`<br>`TRUST_FAILED` | `trust sign` 或 `trust publish` 失败 | 按 `message` 处理；`TRUST_REPLAY` 时把 `revision` 提高到已发布的值之上 |

## 设备端

设备通过 Dart API 报告问题，而不是通过上面的错误码。

| 症状 | 从哪里查 |
|---|---|
| 补丁没有安装 | `applyPatch`、`applyPatchBytes` 和 `applyPatchFile` 返回 `PatchApplyError`；每个值见 [`PatchApplyError`](api-reference-zh.md#patchapplyerror)，文件必须满足的规则见[设备接受哪些文件](api-reference-zh.md#设备接受哪些文件) |
| 找不到更新 | 见 [`checkUpdate` 始终找不到更新](#checkupdate-始终找不到更新) |
| 补丁已安装但没有运行 | 见[补丁已安装但没有运行](#补丁已安装但没有运行) |
| 原生层的校验和加载细节 | 在 Android 的 `logcat` 或 Xcode 控制台中按 `FlutterPatcher` 过滤 |
