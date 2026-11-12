# CLI 参考

[English](cli.md) | **简体中文**

> 查阅 flutter_patcher 的每个命令：什么时候用、怎么用、输出什么，以及出错时怎么处理。

本页是参考：首次上手的流程见[快速上手](getting-started-zh.md)，上线见[生产部署](production-playbook-zh.md)。所有命令都在项目根目录这样运行：

```bash
dart run flutter_patcher <command> [options]
```

| 命令 | 作用 |
|---|---|
| [`init`](#init) | 为项目做一次性准备：生成 `flutter_patcher.yaml` 和补丁密钥，签名默认关闭 |
| [`build`](#build) | 构建要发布的 App，并记录它的基线 |
| [`patch`](#patch) | 为已发布的构建生成补丁文件；加 `--withdraw` 时生成撤回文件 |
| [`publish`](#publish) | 可选：把补丁文件写入存储，并按发布时间编号 |
| [`serve`](#serve) | 仅用于开发：向连接本机的手机提供最新的补丁文件 |
| [`keys`](#keys) | 把补丁密钥迁移到其他电脑和 CI |
| [`doctor`](#doctor) | 检查并准备工具链 |

每个命令先给出用法，再列出选项、输出和错误码。

## init

初始化项目。添加 `flutter_patcher` 依赖后运行一次。

```bash
dart run flutter_patcher init
```

`init` 是幂等的：已有的文件和密钥保持不变。它做三件事：

1. **生成 `flutter_patcher.yaml`**。文件中的配置项都处于注释状态，即全部使用默认值；见[项目配置](#项目配置flutter_patcheryaml)。
2. **生成项目的补丁密钥，签名默认关闭**。私钥保存在本机的密钥库 `~/.flutter_patcher/keys/<id>/keys.json` 中，仅当前用户可读；公钥写入 `trust.patch`，同时写入 `trust.enabled: false`。一个宿主只接受一把密钥，所以 `flutter_patcher.yaml` 中已有密钥时（例如在项目的另一份检出中），不再生成。
3. **检查 `build` 会拒绝的配置**：`version` 没有构建号，或 Android、iOS 项目中的 application id 不是正好一个，此时给出警告。

构建上线版本之前，按[生产部署](production-playbook-zh.md)开启签名、设置 `baseline_store`，并用 `keys export --out <file>` 备份私钥。

**选项**

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--project <dir>` | App 的根目录，其中必须有 `pubspec.yaml` | 当前目录 |

**输出**：stdout 输出一行 JSON。

| 字段 | 值 |
|---|---|
| `command`、`status` | `init`、`initialized` |
| `config`、`config_created` | `flutter_patcher.yaml` 的路径，以及它是否由这次 `init` 创建 |
| `public_key` | 项目的补丁公钥 |
| `key_store` | 新私钥的保存位置；只在这次生成了密钥时出现 |
| `private_key` | `patch` 和 `publish` 会从哪里取得私钥，与 `keys status` 的报告相同；本机没有私钥时为 `none` |
| `signing` | `trust.enabled` 的值 |
| `notice` | 下一步要做什么：打开签名，或在本机 `keys import` 私钥 |

警告以 `WARNING: <CODE>: <text>` 的形式输出到 stderr，代码与 `build` 失败时的相同，例如 `WARNING: BUILD_CONFIG_INVALID`。有警告时仍以 `0` 退出。

**错误**：以 `2` 退出，stderr 输出 `CODE: message`。

| 代码 | 出现条件 | 消除方法 |
|---|---|---|
| `CONFIG_INVALID` | 项目目录中没有 `pubspec.yaml`，或 `flutter_patcher.yaml` 无效 | 在 App 的根目录运行，或按 `message` 指出的内容修正 |
| `KEYS_ALREADY_CONFIGURED` | 项目没有补丁密钥，且仍有 1.0 之前的 `flutter_patcher_keys/` 目录 | 运行 `keys import flutter_patcher_keys`，因为已发布的宿主只接受这把密钥 |

## build

构建要发布到商店的 App（宿主），并把它的基线保存到基线存储。只有 release 构建能接收补丁，所以 `build` 只构建 release 模式。

```bash
dart run flutter_patcher build android
dart run flutter_patcher build ios       # 只能在 Apple Silicon Mac 上运行
dart run flutter_patcher build android --dart-define=API_URL=https://api.example.com
dart run flutter_patcher build android -- --android-project-arg=store=play
```

**常用选项**

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--flavor <name>` | Flutter flavor；1 到 64 个字母、数字和 `_` | 无 flavor，记录为 `default` |
| `--version-code <n>` | 构建号 | `pubspec.yaml` 中 `version` 的 `+` 之后的数字 |
| `--dart-define <KEY=VALUE>`、`-D` | 编译期变量，Dart 代码用 `String.fromEnvironment` 等读取；可重复 | 无 |
| `--dart-define-from-file <file>` | 从 JSON 或 `.env` 文件读取编译期变量；可重复，后面的文件覆盖前面的，`--dart-define` 覆盖文件 | 无 |
| `--baseline-store <uri>` | 把基线保存到这里 | `flutter_patcher.yaml` 中的 `baseline_store` |

**其他选项**

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--strategy bytecode\|so` | 补丁策略，仅 Android；见[两种补丁策略](architecture-zh.md#两种补丁策略) | `bytecode` |
| `--channel <name>` | 渠道，是宿主身份和补丁文件名的一部分；1 到 64 个字母、数字和 `_` | `production` |
| `--application-id <id>` | application id（iOS 为 bundle id） | 从 Gradle 或 Xcode 项目读取；项目中有多个时必须传入 |
| `--target <file>` | 入口文件 | `lib/main.dart` |
| `--out <dir>` | 输出目录；必须不存在，这样一次构建不会覆盖另一次 | `.dart_tool/flutter_patcher/releases/<timestamp>/` |
| `--export-method <method>` | 仅 iOS，传给 `flutter build ipa`：`app-store`、`ad-hoc`、`development` 或 `enterprise` | `app-store` |
| `--host-policy <file>` | 自己写的宿主策略；见[自定义宿主策略](advanced-zh.md#自定义宿主策略) | 根据项目生成 |
| `-- <options>` | `--` 之后的选项传给 `flutter build`；只接受[下面列出的选项](#编译期变量和-flutter-build-选项) | 无 |

**输出**：输出目录中有 `app-release.apk` 或 `app-release.ipa`，以及完整报告 `build.json`。stdout 输出一行 JSON：

| 字段 | 值 |
|---|---|
| `command`、`status` | `build`、`build_archived` |
| `app` | 要提交到商店的 APK 或 IPA 的路径 |
| `application_id`、`version_code`、`strategy` | 宿主的身份 |
| `signed` | 宿主只接受用项目补丁密钥签名的文件时为 `true` |
| `fingerprint` | 这个宿主构建的指纹 |
| `report` | `build.json` 的路径 |

**警告**：输出到 stderr，构建照常完成。

| 代码 | 出现条件 | 消除方法 |
|---|---|---|
| `UNSIGNED` | `flutter_patcher.yaml` 中没有补丁密钥，或 `trust.enabled` 为 `false` | 设置 `trust.enabled: true`（没有密钥时先运行 `init`），然后重新构建 |
| `BASELINE_STORE_LOCAL` | 基线只保存在项目的 `.flutter_patcher/baselines/` 中 | 设置 `baseline_store`，或传 `--baseline-store` |

**错误**：以 `2` 退出，stderr 输出 JSON 错误。

| 代码 | 出现条件 | 消除方法 |
|---|---|---|
| `BASELINE_RELEASE_CONFLICT` | 相同的 flavor 和构建号之前构建过，且内容不同 | 提升构建号，因为一个版本只有一份基线；内容相同时沿用已有基线 |
| `BUILD_CONFIG_INVALID` | `pubspec.yaml` 中没有构建号、application id 不唯一、选项无效、编译期变量或 `--` 之后的选项不被接受，或 `--out` 已存在 | 按 `message` 指出的内容修正 |
| `HOST_UNSUPPORTED` | 在 Mac 以外的电脑上运行 `build ios` | 在 Apple Silicon Mac 上构建 |

### 编译期变量和 `flutter build` 选项

日常开发仍然使用 `flutter run` 和 `flutter build`。构建宿主时，把同样的 `--dart-define` 和 `--dart-define-from-file` 传给 `build`。

- 变量名和值以明文保存在基线中，该宿主的每个补丁都用它们编译。补丁中如何修改它们，见[补丁中的编译期变量](#补丁中的编译期变量)。
- `build` 按 `flutter build` 的方式自己设置以下变量，并保存在基线中：`FLUTTER_APP_FLAVOR`（`--flavor`）、`FLUTTER_BUILD_NAME`（`version` 的 `+` 之前的部分）、`FLUTTER_BUILD_NUMBER`（构建号）、`FLUTTER_VERSION`、`FLUTTER_CHANNEL`、`FLUTTER_GIT_URL`、`FLUTTER_FRAMEWORK_REVISION`、`FLUTTER_ENGINE_REVISION`、`FLUTTER_DART_VERSION`、`FLUTTER_ENABLED_FEATURE_FLAGS`。传入这些名字或以 `dart.` 开头的变量会报 `BUILD_CONFIG_INVALID`。
- 宿主和它的补丁都在关闭 Flutter 功能开关 `windowing` 和 `accessibility_evaluations` 的情况下构建，与 `flutter config` 中的设置无关。
- `--` 之后只接受以下选项，其他选项报 `BUILD_CONFIG_INVALID`。它们保存在基线中，SO 策略的补丁重新构建时也使用它们。

| 选项 | `build android` | `build ios` |
|---|---|---|
| `--android-project-arg <key=value>`（`-P`） | ✓ | |
| `--android-project-cache-dir <dir>` | ✓ | |
| `--[no-]android-gradle-daemon` | ✓ | |
| `--[no-]android-skip-build-dependency-validation` | ✓ | |
| `--ignore-deprecation` | ✓ | |
| `--performance-measurement-file <file>` | ✓ | ✓ |
| `--[no-]fatal-warnings` | ✓ | ✓ |
| `--verbose`（`-v`） | ✓ | ✓ |

`flutter build ipa` 不支持前五个选项，所以 `build ios` 只接受后三个。

## patch

把当前源码与某个已发布宿主的基线对比，写出该宿主的补丁文件。加 `--withdraw` 时改为写出该宿主的撤回文件，不编译任何内容。

```bash
dart run flutter_patcher patch android
dart run flutter_patcher patch ios                  # 可在任何受支持的电脑上运行
dart run flutter_patcher patch android --withdraw
dart run flutter_patcher patch android --dart-define=API_URL=https://api2.example.com
```

### 目标宿主

`patch` 用构建号和 flavor 找到宿主的基线：

- 构建号：默认为 `pubspec.yaml` 中 `version` 的构建号；用 `--version-code` 指定。
- flavor：默认为 `default`；用 `--flavor` 指定。

以下内容沿用宿主构建时的值，`patch` 不能更改，所以没有对应的选项，也不接受 `--`：策略、渠道、补丁密钥、`build` 自动设置的 `FLUTTER_*` 变量，以及 `flutter build` 选项。例如修改 `pubspec.yaml` 的 `version` 后，补丁中的 `FLUTTER_BUILD_NAME` 不变。

**选项**

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--version-code <n>` | 要打补丁的版本 | `pubspec.yaml` 中 `version` 的 `+` 之后的数字 |
| `--flavor <name>` | 该版本的 flavor | `default` |
| `--withdraw` | 写出撤回文件。不能与 `--target`、`--assets` 或编译期变量同时使用（`USAGE_ERROR`） | 关闭 |
| `--dart-define <KEY=VALUE>`、`-D` | 本补丁修改或新增的编译期变量；可重复 | 宿主构建时的变量 |
| `--dart-define-from-file <file>` | 同上，从 JSON 或 `.env` 文件读取 | 宿主构建时的变量 |
| `--assets <key>` | 只覆盖这些资源 key；可重复 | 所有改动过的资源 |
| `--target <file>` | 入口文件；必须与 `build` 使用的相同 | 宿主的入口文件 |
| `--out <dir>` | 输出目录；必须不存在 | `.dart_tool/flutter_patcher/patches/<timestamp>/` |
| `--baseline-store <uri>` | 从这里读取基线 | `flutter_patcher.yaml` 中的 `baseline_store` |

### 补丁中的编译期变量

- 传入的变量是本补丁修改或新增的；没有传入的变量保持宿主构建时的值。不能删除变量。
- 每个补丁都从宿主构建时的值出发，与之前的补丁无关：要保留上一个补丁改过的值，再传一次。
- 变量的改动是补丁的一部分：补丁被撤回、被 `rollback` 删除或被另一个补丁取代之后，它改动的值随之失效。
- 必须有 Dart 源码用 `fromEnvironment` 或 `hasEnvironment` 读取传入的变量，否则报 `PATCH_DEFINE_UNREAD`。只改变量、不改源码也能生成补丁。

### 输出

输出目录中有补丁文件（命名规则见[补丁文件](#补丁文件)）、报告 `patch.json`，以及封装之前的补丁 `patch.draft`（`--withdraw` 时没有）。stdout 输出一行 JSON，最常用的是 `file`：

| 字段 | 值 |
|---|---|
| `command`、`status` | `patch`；`patch_created` 或 `withdrawal_created` |
| `file` | 补丁文件的完整路径，下发的就是这个文件。宿主已签名而本机没有它的私钥时为 `null`，此时 `notice` 说明该怎么做 |
| `output` | 输出目录 |
| `seq`、`sealed_at` | 文件的序号，即封装时的 Unix 秒；以及对应的 UTC 时间 |
| `signed` | 文件是否已签名 |
| `patch_key` | 宿主的补丁公钥；不签名宿主为 `-` |
| `platform`、`abi`、`strategy`、`fingerprint`、`scope` | 文件所属的宿主 |
| `changed`、`warnings` | 仅补丁：改动了什么，以及需要留意什么 |
| `defines` | 仅当补丁修改或新增了编译期变量：`changed` 和 `added` 列出变量名 |

> **注意**：签名宿主在本机没有私钥时，`patch` 仍以 `0` 退出，只是 `"file":null`。脚本中要检查 `file`，或在 CI 中设置 `FLUTTER_PATCHER_KEYS`。

**警告**：补丁照常生成，但运行时有以下限制，见[能更新什么](architecture-zh.md#能更新什么)：`PATCH_NATIVE_ASSET_READER`（原生代码读到的仍是原资源）、`PATCH_BACKGROUND_ENTRY`（后台入口运行原代码）、`PATCH_RESOURCE_SIZE`（补丁资源常驻内存）。

**错误**：以 `2` 退出，stderr 输出 JSON 错误；改动被拒绝时附带 `details`。

| 代码 | 出现条件 | 消除方法 |
|---|---|---|
| `BASELINE_NOT_FOUND` | 这个 flavor 和构建号没有基线 | 传入线上版本的 `--version-code` 和 `--flavor`，并让 `baseline_store` 指向 `build` 使用的存储 |
| `PATCH_NO_CHANGES` | 与基线相比没有任何改动 | 保存你的修改；确认目标版本 |
| `PATCH_NATIVE_CHANGE` 等拒绝改动的错误码 | 补丁无法携带这处改动；见[能更新什么](architecture-zh.md#能更新什么) | 还原这部分改动，或发布商店版本 |
| `PATCH_DEFINE_UNREAD` | 没有 Dart 源码读取传入的编译期变量 | 检查变量名 |
| `PATCH_BUILD_INPUTS_MISMATCH` | `--target` 不是宿主的入口文件，或宿主构建时 `pubspec.yaml` 中没有 `version` 而现在有 | 去掉 `--target`；去掉 `version`，或发布新的宿主 |
| `PATCH_BASELINE_INCOMPATIBLE` | 宿主是用 flutter_patcher 1.0 或另一个 Flutter 版本构建的 | 1.0 的宿主用 flutter_patcher 1.0.0+1 打补丁；用 `--flutter-sdk` 指定宿主构建时的 Flutter |

## publish

可选。把 `patch` 的输出写入发布存储（`store`）。自行下发补丁文件时不需要它。

```bash
dart run flutter_patcher publish                     # 先预览，询问后写入
dart run flutter_patcher publish --yes               # 不询问，直接写入
dart run flutter_patcher publish --withdraw          # 写入撤回文件
dart run flutter_patcher publish --patch <dir>       # 发布指定的 patch 输出，例如回到之前的补丁
```

**序号**：`publish` 用发布时间重新封装文件，序号按发布顺序递增，所以重新发布的旧补丁也会被设备安装。存储中文件的序号大于或等于新序号时，`publish` 不替换它。

**选项**

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--yes`、`-y` | 不询问，直接发布 | 有终端时询问；没有终端时只预览 |
| `--patch <dir>` | 要发布的 `patch` 输出。该输出已被删除时，检出当时的代码重新运行 `patch` | `.dart_tool/flutter_patcher/patches/` 下最新的输出 |
| `--withdraw` | 改为写入该输出所属宿主的撤回文件。`patch --withdraw` 的输出不加此选项也按撤回文件发布 | 关闭 |
| `--seq <n>` | 文件的序号，1 到 4294967295；必须大于存储中文件的序号 | 当前的 Unix 秒 |
| `--key-file <file>` | 用这个密钥包签名，优先于其他来源；见[私钥从哪里来](#私钥从哪里来) | |
| `--receipt <file>` | 同时把结果写入这个 JSON 文件；文件必须不存在。只在 `published` 时写入 | |

确认提示 `Publish <fileName> as <seq> to <store>? [y/N]` 输出到 stderr。`file://` 存储中的文件要上传到 `<url>/<fileName>` 之后，设备才能下载。

**输出**：stdout 输出一行 JSON，包含 `command`（`publish`）、`action`（`publish` 或 `withdraw`）、`file`（文件名）、`store`、`signed`、`seq` 和 `status`。以下三种 `status` 都以 `0` 退出，所以脚本中要检查 `status`：

| `status` | 含义 | 是否写入 |
|---|---|---|
| `published` | 文件已在存储中 | 是 |
| `already_published` | 存储中已有该宿主的这个补丁（`--withdraw` 时为撤回文件）；`seq` 是存储中的序号 | 否 |
| `preview` | 没有 `--yes`，并且没有终端可以询问，或回答不是 `y` | 否 |

**错误**：以 `2` 退出，stderr 输出 `CODE: message`，不写入任何内容。

| 代码 | 出现条件 | 消除方法 |
|---|---|---|
| `KEYS_NOT_FOUND` | 宿主已签名，而所有来源都没有它的私钥 | 见[私钥从哪里来](#私钥从哪里来) |
| `PUBLISH_SEQUENCE_CONFLICT` | 存储中文件的序号大于或等于新序号，或 `--seq` 超出范围 | 校准本机时钟，或传入 `message` 建议的 `--seq` |
| `PUBLISH_CONFLICT` | 存储中的文件在读取和写入之间发生了变化 | 重新运行 `publish` |
| `PUBLISH_CONFIG_INVALID` | 没有补丁输出、`--receipt` 文件已存在，或 `store` 带有凭据 | 先运行 `patch` 或传 `--patch`；换一个新的 receipt 文件 |
| `PUBLISH_STORE_UNAVAILABLE` | 没有 AWS CLI，或它运行失败 | 见[发布存储](#发布存储) |

## serve

仅用于开发。向连接本机的手机提供 `patch` 为每个宿主写出的最新文件（补丁或撤回文件），按原样提供，不签名、不编号，也不写入任何存储。

```bash
dart run flutter_patcher serve
```

- **Android**：每 2 秒为新连接的设备运行一次 `adb reverse`，手机上的 App 就能访问本机。构建时没有设置 `url` 的 App 默认访问 `http://127.0.0.1:8686`。
- **iPhone**：访问不到这台电脑的 `127.0.0.1`，要把端口暴露为 HTTPS 地址，例如 `cloudflared tunnel --url http://127.0.0.1:8686`，再把该地址传给 `checkUpdate(url: …)`。
- **提供哪些文件**：`.dart_tool/flutter_patcher/patches/` 下每个宿主最新输出中的文件，约 2 秒内发现新的 `patch` 输出。用 `patch --out` 写到其他位置的输出不会被提供。
- **访问范围**：只监听 `127.0.0.1`，只应答 `GET /<fileName>`，`Range` 请求以 `206` 应答；其余一律 `404`。

**选项**

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--port <port>` | 本机端口，也是 `adb reverse` 在 Android 设备上映射的端口。没有设置 `url` 的 App 访问 `8686`，所以换端口时还要运行 `adb reverse tcp:8686 tcp:<port>` | `8686` |

**输出**：stdout 不输出。状态行输出到 stderr：

| 输出行 | 含义 |
|---|---|
| `Android device <serial> reaches this computer at 127.0.0.1:<port>` | 已为该设备设置 `adb reverse` |
| `Offering patch <seq> (<fileName>, signed\|unsigned)` | 某个宿主的最新输出是补丁 |
| `Offering a withdrawal of <fileName> (signed\|unsigned, <seq>)…` | 某个宿主的最新输出是撤回文件 |
| `Not offering <fileName>: …` | 宿主已签名而本机没有它的密钥，所以最新输出中没有文件。此时不为该宿主提供任何文件，包括更早的文件。运行 `keys import` 后重新 `patch` |
| `A device checked for updates` | 有设备读取了文件头 |
| `A device downloaded <fileName>` | 有设备读取了整个文件 |

**错误**：无法启动时以 `2` 退出。端口被占用时报 `SERVE_PORT_BUSY`（用 `--port` 换一个端口）；`--port` 无效时报 `USAGE_ERROR`。

## keys

迁移和查看项目的补丁密钥，即 [`init`](#init) 生成的那对 Ed25519 密钥。私钥保存在项目之外，所以换电脑或在 CI 中签名时，要用 `keys` 把它带过去。为什么要签名见[安全模型](architecture-zh.md#安全模型)。

```bash
dart run flutter_patcher keys export --out <file>   # 把密钥写入文件，用于另一台机器
dart run flutter_patcher keys export --base64       # 把密钥输出为一行，用于 CI secret
dart run flutter_patcher keys import <file>         # 把密钥加入本机的密钥库
dart run flutter_patcher keys status                # 显示私钥会从哪里取得
```

**子命令和选项**

| 子命令和选项 | 说明 |
|---|---|
| `export --out <file>` | 把本机保存的项目密钥写入一个新文件 |
| `export --base64` | 把它输出为一行 base64，即 `FLUTTER_PATCHER_KEYS` 的值 |
| `import <file>` | 把密钥包加入本机密钥库。`-` 表示从 stdin 读取；目录表示读取 1.0 之前的 `flutter_patcher_keys/` 布局。项目没有补丁密钥时，同时写入 `trust.patch` 和 `trust.enabled: false` |
| `status` | 显示公钥，以及签名时会使用哪个来源的私钥 |
| `status --key-file <file>` | 同时把这个密钥包作为第一个来源考虑 |

在 CI 中不需要 `import`：设置 `FLUTTER_PATCHER_KEYS` 即可，见[CI 中的密钥](advanced-zh.md#ci-中的密钥)。

**输出**：stdout 输出一行 JSON，其中 `command` 为 `keys export`、`keys import` 或 `keys status`。`export --base64` 例外，只输出那一行 base64。除 `export` 外，任何命令都不输出私钥。

| 子命令 | 字段 |
|---|---|
| `export --out` | `status`（`keys_exported`）、`file` |
| `import` | `status`（`keys_imported`）、`key_store`、`public_key`；写入了 `trust.patch` 时还有 `config` |
| `status` | `config`；`public_key`（`trust.patch`，或 `null`）；`private_key`：会用来签名的来源（`--key-file`、`FLUTTER_PATCHER_KEYS`、`signing.command`、`key store`）或 `none`。`<source> (other key)` 表示该来源中是另一把密钥；错误码表示该来源无法读取 |

**错误**：以 `2` 退出，stderr 输出 `CODE: message`。

| 代码 | 出现条件 | 消除方法 |
|---|---|---|
| `KEYS_NOT_CONFIGURED` | 在没有 `trust.patch` 的项目中运行 `export` | 运行 `init`，或 `keys import` 项目的密钥包 |
| `KEYS_NOT_FOUND` | 本机密钥库中没有该密钥时运行 `export`，或 `import` 的文件不存在 | 在有密钥的机器上运行 |
| `KEYS_MISMATCH` | `import` 的密钥不是 `flutter_patcher.yaml` 指定的那一把 | 使用项目的密钥包 |
| `KEYS_OUTPUT_EXISTS` | `--out` 指向已存在的文件 | 换一个新文件 |
| `KEYS_BUNDLE_INVALID` | 文件不是密钥包，或其中没有补丁密钥 | 使用 `keys export` 写出的文件 |

### 私钥从哪里来

`patch` 和 `publish` 按以下顺序查找私钥，用第一个存在的来源签名：

1. `--key-file <file>`（仅 `publish`）：密钥包文件；
2. 环境变量 `FLUTTER_PATCHER_KEYS`：内容为 `keys export --base64` 的输出；
3. `flutter_patcher.yaml` 中的 `signing.command`：KMS 或其他签名服务，见[用 KMS 或签名服务签名](advanced-zh.md#用-kms-或签名服务签名)；
4. 本机的密钥库，包括 flutter_patcher 1.0 写出的密钥目录。

| 情况 | 结果 |
|---|---|
| 第一个存在的来源中的密钥不是宿主的密钥 | `KEYS_MISMATCH`。不再尝试下一个来源，这样错误的 secret 会被报告，而不是被掩盖 |
| `signing.command` 失败、超时或用了另一把密钥 | `SIGNER_COMMAND_FAILED` |
| 没有任何来源 | `patch` 以 `0` 退出且 `"file":null`；`publish` 以 `KEYS_NOT_FOUND` 失败 |

## doctor

检查工具链是否就绪。首次运行时下载并准备与你的 Flutter 版本对应的引擎和工具，需要几分钟；之后运行很快。

```bash
dart run flutter_patcher doctor
dart run flutter_patcher doctor --project . --baseline-store s3://my-bucket/baselines --version-code 7
```

默认只检查工具链。加下列选项时，同时检查对应的内容：

| 选项 | 同时检查 |
|---|---|
| `--project <dir>` | 项目的私钥来源；在 Mac 上还检查 `ios/Runner/Info.plist` 中的 `CFBundleVersion` 是否为 `$(FLUTTER_BUILD_NUMBER)` 或正整数 |
| `--baseline-store <uri>` | 基线存储是否可访问。写入权限由 `build` 检查 |
| `--version-code <n>`、`--flavor <name>` | 与 `--baseline-store` 一起使用：该版本的基线是否完整 |
| `--apk <file>` | 该 APK 中的引擎是否与所选 Flutter 版本一致 |
| `--json` | 不改变检查内容：输出一份 JSON 报告，而不是检查清单 |

**输出**：stdout 每项检查输出一行 `[passed|warning|not_run|failed] <id>: <message>`，最后是 `Toolchain ready. …` 或 `Doctor failed.`。加 `--json` 时输出一个 JSON 对象：

| 字段 | 值 |
|---|---|
| `command`、`status` | `doctor`；`toolchain_ready` 或 `failed` |
| `checks` | 每项检查一个对象：`id`、`status`（`passed`、`warning`、`not_run` 或 `failed`）、`message`；未通过的检查还有 `code` |
| `host`、`sdk`、`engine_build_id` | 被检查的电脑、Flutter SDK 和引擎 |
| `network_requests`、`elapsed_ms` | 本次运行的开销 |

**退出码**：`0` 已运行的检查全部通过；`1` 有检查未通过，stderr 输出 `CODE: message`；`2` 参数错误。加 `--offline` 时只使用本机缓存，缺少必需的下载内容时失败。

## 在脚本和 CI 中使用

### 输出和退出码

所有命令遵循同一套约定：结果写到 stdout，警告和进度写到 stderr。脚本中按 `code` 判断结果，不要匹配 `message`：报错文字会随版本变化，错误码不会。全部错误码见[错误码与排障](troubleshooting-zh.md)。

| 情况 | stdout | stderr | 退出码 |
|---|---|---|---|
| 成功 | 一行 JSON。例外：`serve` 不输出，`doctor` 不加 `--json` 时输出检查清单，`keys export --base64` 输出密钥包 | 警告和进度 | `0` |
| `build`、`patch` 或 `baseline` 失败 | 无 | 一行 JSON，包含 `command`、`status`（`failed`）、`code` 和 `message`；改动被拒绝时 `patch` 附带 `details` | `2` |
| 其他命令失败 | 无 | `CODE: message` | `2` |
| `doctor` 的某项检查未通过 | 检查清单，或 JSON 报告 | `CODE: message` | `1` |
| 命令或选项不存在 | 无 | `USAGE_ERROR: message` | `2` |

警告以 `WARNING: <CODE>: <text>` 的形式输出到 stderr，不改变退出码。

### 各命令共用的选项

| 选项 | 命令 | 说明 | 默认值 |
|---|---|---|---|
| `--project <dir>` | `baseline` 以外的所有命令 | 项目目录 | 当前目录 |
| `--flutter-sdk <path>` | `build`、`patch`、`doctor` | 使用的 Flutter SDK | `PATH` 中的 Flutter |
| `--offline` | `build`、`patch`、`doctor` | 只使用本机已校验的缓存，不访问网络；`patch --offline` 也只从本机缓存读取基线 | 关闭 |
| `--cache-dir <dir>` | `build`、`patch`、`doctor` | 缓存目录，必须位于 `~/.flutter_patcher` 或项目的 `.dart_tool/flutter_patcher` 之下 | `~/.flutter_patcher` |
| `-h`、`--help` | 所有命令 | 输出该命令的选项 | |
| `--version` | 顶层 | 输出 `flutter_patcher <version>` | |

在 Windows 上，缓存路径最多 80 个字符，因为更深的构建目录会超过 Windows 的路径长度限制。`~/.flutter_patcher` 超过这个长度时，传一个位于项目 `.dart_tool/flutter_patcher` 之下的 `--cache-dir`。

## 参考资料

### 项目配置：`flutter_patcher.yaml`

所有配置项都是可选的，也都不是机密，可以提交到代码库。`init` 生成这个文件，其中的配置项全部注释掉；在没有这个文件的项目中，`keys import` 也会创建它。

| 配置项 | 含义 | 默认值 |
|---|---|---|
| `trust.enabled` | `true`：此后构建的宿主是签名宿主，只接受用 `trust.patch` 签名的文件。有密钥而没有 `enabled` 的文件（flutter_patcher 1.0 写出的格式）按 `true` 处理 | `false`，即 `init` 写入的值；`build` 给出警告 `UNSIGNED` |
| `trust.patch` | 项目补丁密钥的 base64 公钥，由 `init` 写入。不要手动修改，因为已发布的宿主只接受构建时的那把密钥。flutter_patcher 1.0 写入的 `root` 和 `publisher` 被忽略 | 运行 `init` 之前不存在 |
| `baseline_store` | 基线存储，由 `build` 写入、`patch` 读取：`file://`、`s3://` 或 HTTPS | 项目中的 `.flutter_patcher/baselines/`；`build` 给出警告 `BASELINE_STORE_LOCAL` |
| `url` | `checkUpdate()` 的默认地址。`build` 把它写入 App，不带 `url` 的 `checkUpdate()` 从 `<url>/<fileName>` 下载。`https://` 地址，或指向 `127.0.0.1`、`localhost`、`::1` 的 `http://` 地址 | `http://127.0.0.1:8686`，即 `serve` 提供补丁的地址 |
| `store` | 发布存储，`publish` 写入的位置：`file://` 或 `s3://` | 项目中的 `.flutter_patcher/updates/` |
| `signing.command` | 负责签名的外部程序；见[私钥从哪里来](#私钥从哪里来) | 未设置 |

未知的配置项、类型错误的值，或没有有效 `patch` 的 `trust`，以 `CONFIG_INVALID` 失败。

### 补丁文件

`patch` 和 `publish` 写出的是同一种文件：FPTC v1。补丁文件和撤回文件的格式相同，文件名也相同。

**文件名**：同一个宿主的所有文件同名，所以新的补丁或撤回文件会替换之前的文件。在设备上，`PatchTarget.fileName` 给出这个文件名。

| 宿主 | 文件名 | 示例 |
|---|---|---|
| 默认的 flavor 和渠道（`default`、`production`） | `<version_code>-<abi>.fptc` | `7-arm64-v8a.fptc` |
| 其他 flavor 或渠道 | `<version_code>-<flavor>-<channel>-<abi>.fptc` | `7-paid-beta-arm64-v8a.fptc` |

设备安装哪些文件，见[设备接受哪些文件](api-reference-zh.md#设备接受哪些文件)。

**文件格式**：文件长度正好是 146 + L 字节，最大 320 MiB。

| 偏移 | 字节数 | 字段 |
|---|---|---|
| 0 | 4 | 魔数 `FPTC`（`0x46505443`） |
| 4 | 2 | 版本 `1` |
| 6 | 32 | 宿主构建的指纹 |
| 38 | 4 | 序号 `seq`，uint32，最小为 1；封装文件时的 Unix 秒，或 `publish --seq` 的值 |
| 42 | 8 | payload 长度 L |
| 50 | 32 | payload 的 SHA-256 |
| 82 | 64 | 对第 0–81 字节加 payload 的 Ed25519 签名；不签名时为 64 个 0 字节 |
| 146 | L | payload：补丁 ZIP。L = 0 表示撤回文件 |

### 目录

| 路径 | 内容 | 丢失后 |
|---|---|---|
| `~/.flutter_patcher/keys/<id>/keys.json` | 本机保存的补丁私钥，即密钥库 | 用这把密钥构建的宿主不再接受新的补丁文件，除非还有另一份副本（`keys export --out <file>`） |
| `.flutter_patcher/baselines/` | 默认的基线存储 | 其中保存了基线的构建无法再打补丁 |
| `flutter_patcher.yaml` | 配置和项目的公钥 | `keys import` 会重新写入公钥 |
| `.flutter_patcher/updates/` | 默认的发布存储 | 重新运行 `publish` |
| `.dart_tool/flutter_patcher/patches/` | `patch` 的输出；`serve` 提供每个宿主最新的文件 | 重新运行 `patch` |
| `.dart_tool/flutter_patcher/releases/` | `build` 的输出 | 没有影响：基线在基线存储中 |
| `~/.flutter_patcher/`（`keys/` 除外） | 下载的引擎和工具、准备好的 Flutter SDK 副本、基线缓存 | 会重新下载 |

### 存储要求

#### 基线存储

基线只增加、不替换，所以多台构建机可以共用一个基线存储。

| 类型 | 要求 |
|---|---|
| `s3://` | 已安装并配置好的 AWS CLI。角色需要读写权限和 `s3:ListBucket`：缺少它时，不存在的对象返回 `403` 而不是 `NoSuchKey`，访问以 `BASELINE_STORE_UNREACHABLE` 失败。Cloudflare R2 等兼容 S3 的服务需要设置 `FLUTTER_PATCHER_S3_ENDPOINT` |
| HTTPS | 根路径对 `HEAD` 返回 `200`；支持 `GET`；带 `If-None-Match: *` 的 `PUT` 在创建时返回 `201`，对象已存在时返回 `412`；不存在的对象返回 `404`。访问令牌放在 `FLUTTER_PATCHER_BASELINE_TOKEN` 中 |
| `file://` | 本地目录或网络挂载 |

#### 发布存储

存储的根目录下每个宿主一个文件，命名规则见[补丁文件](#补丁文件)。`file://` 存储中还有 `.publish.lock`，不需要上传或对外提供。

| 类型 | 要求 |
|---|---|
| `s3://` | 支持条件写入（`put-object --if-match` 和 `--if-none-match`）的 AWS CLI，对该前缀下对象的读写权限，以及 `s3:ListBucket`：缺少它时，不存在的文件被读成拒绝访问，`publish` 以 `PUBLISH_STORE_UNAVAILABLE` 失败。地址是存储桶下的一个专用前缀，例如 `s3://my-bucket/my-app`；见[发布到 S3](advanced-zh.md#发布到-s3) |
| `file://` | 本地目录或网络挂载 |

#### 下载服务器

`checkUpdate` 下载所用的 HTTPS 服务器或 CDN，无论文件是由 `publish` 还是由你放上去的，都必须满足：

- 对 `GET <url>/<fileName>` 返回文件（`200`，或对所请求的范围返回 `206`；是否支持范围请求可选），没有文件时返回 `404`。其他任何状态码都会让 `checkUpdate` 抛出异常，包括私有 S3 和 R2 存储桶对不存在的对象返回的 `403`；
- 直接返回内容，因为客户端不跟随 `3xx` 重定向；
- 发送与文件大小相等的 `Content-Length`，或用 `Content-Encoding: gzip` 压缩；
- 在 2 分钟内传完整个文件，中途停顿不超过 15 秒；
- 及时提供被替换后的文件：同一个宿主的所有文件同名，只有缓存开始提供新文件后，设备才能收到新的补丁或撤回文件。

### 环境变量

| 变量 | 用途 |
|---|---|
| `FLUTTER_PATCHER_KEYS` | 用于签名的密钥包（`keys export --base64` 的输出），通常是 CI secret |
| `FLUTTER_PATCHER_S3_ENDPOINT` | Cloudflare R2 等兼容 S3 的服务的 HTTPS 端点 |
| `FLUTTER_PATCHER_BASELINE_TOKEN` | HTTPS 基线存储的访问令牌，以 `Authorization: Bearer` 发送 |
| AWS CLI 的标准变量和配置 | S3 的凭据和区域，例如 `AWS_PROFILE`、`AWS_REGION` |
| `FLUTTER_PATCHER_SIGN_ROLE`、`FLUTTER_PATCHER_SIGN_PUBLIC_KEY` | 不需要自己设置：CLI 调用 `signing.command` 时设置为 `patch` 和要为之签名的公钥 |

### 高级命令

| 命令 | 用途 |
|---|---|
| `baseline --action fetch\|verify\|release` | 下载、校验或查询基线存储中的基线，用于排查问题 |

### 1.1 中删除的内容

在 flutter_patcher 1.1.0 或更新版本中，以下命令和选项以未知命令或未知选项失败（`USAGE_ERROR`）。它们在 flutter_patcher 1.0.0+1 中仍然可用，用 1.0.0 构建的宿主用该版本打补丁。

| 删除 | 替代 |
|---|---|
| `trust sign`、`trust publish` | 无：补丁密钥是唯一的密钥 |
| `publish --production --request <file>` | 自行在存储中删除或替换 `.fptc` 文件 |
| `keys init` | `init`，它同时生成 `flutter_patcher.yaml`；签名用 `trust.enabled` 打开 |
| `keys init --role`、`keys export --without-root`、`keys import --rotate` | 无：补丁密钥是唯一的密钥 |