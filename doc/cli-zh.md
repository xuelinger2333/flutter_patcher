# CLI 参考

[English](cli.md) | **简体中文**

CLI 随插件一起发布。在依赖了 `flutter_patcher` 的项目目录中运行：

```bash
dart run flutter_patcher <命令> [选项]
```

本文逐一列出命令和选项。完整的上手流程见[快速上手](getting-started-zh.md)，上线相关的做法见[生产部署](production-playbook-zh.md)。

## 常见工作流

以下命令都在项目根目录运行。各命令的选项见后文。

### 通过 USB 在手机上试一处改动

```bash
dart run flutter_patcher patch android
dart run flutter_patcher serve          # 保持运行；每次改动后再执行一次 patch
```

**验证**：`serve` 输出 `Offering patch <序号> (<文件名>, unsigned)`（或 `signed`），App 应用补丁后输出 `A device downloaded <文件名>`。`serve` 只是调试工具，见 [serve](#serve)。

### 自己把补丁文件交给 App

```bash
dart run flutter_patcher patch android
```

**验证**：输出的 JSON 中 `file` 是补丁文件的路径，例如 `.dart_tool/flutter_patcher/patches/<目录>/7-default-production-arm64-v8a.fptc`。用任何方式把这个文件交给 App，再传给 `FlutterPatcher.applyPatchBytes` 或 `applyPatchFile`，见 [API 参考](api-reference-zh.md)。`file` 为 `null` 表示宿主开启了签名而本机没有补丁私钥：在本机 `keys import` 私钥后重新 patch，或在有私钥的机器上运行 `publish --patch <输出目录>`。

自行分发只需要 `build` 和 `patch`。使用内置下载器时，把文件放在 `<url>/<文件名>`；该服务需要满足的条件见[存储要求](#存储要求)。

### 向生产环境发布补丁

`publish` 是可选的：它把文件写入存储（`file://` 或 `s3://`），按发布时间编号，并防止用旧文件替换新文件。

```bash
dart run flutter_patcher patch android
dart run flutter_patcher publish        # 先预览，确认后发布
```

**验证**：`publish` 输出 `"status":"published"`，以及写入存储的 `file` 和 `seq`。存储的配置见[生产部署](production-playbook-zh.md)。

### 在 CI 中发布

```bash
export FLUTTER_PATCHER_KEYS="<secret：keys export --base64 的输出>"
dart run flutter_patcher patch android
dart run flutter_patcher publish --yes
```

**验证**：同上，且 `"signed":true`；在任务中运行 `keys status`，输出 `"private_key":"FLUTTER_PATCHER_KEYS"`。不签名的宿主不需要这个 secret。

### 撤回补丁，或回到之前的补丁

```bash
dart run flutter_patcher patch android --withdraw                                   # 回到安装包自带的版本；像补丁一样分发它的文件
dart run flutter_patcher publish --withdraw                                         # 同上，写入存储
dart run flutter_patcher publish --patch .dart_tool/flutter_patcher/patches/<目录>   # 回到之前的某个补丁
```

**验证**：第一条输出 `"status":"withdrawal_created"` 和它的 `file`；第二条输出 `"action":"withdraw"`；第三条输出的 `seq` 大于问题补丁的序号。重新上传旧的 `.fptc` 文件不会生效：设备只接受更大的 `seq`。

### 为更早的线上版本打补丁

```bash
git checkout <该版本的标签>
# 修改代码
dart run flutter_patcher patch android --version-code <它的构建号>
dart run flutter_patcher publish
```

**验证**：`patch` 输出 `"status":"patch_created"`，`file` 的文件名以 `<它的构建号>-` 开头。

### 在 Linux 或 Windows 上生成 iOS 补丁

```bash
dart run flutter_patcher patch ios --baseline-store s3://my-bucket/baselines
```

`flutter_patcher.yaml` 中的 `baseline_store` 已经指向 `build ios` 使用的存储时，不需要 `--baseline-store`。

**验证**：`patch` 输出 `"status":"patch_created"`，其中 `"abi":"ios-arm64"`。

## 通用约定

- **项目目录**：默认是当前目录，可用 `--project` 指定。
- **输出**：成功时向标准输出打印一行 JSON；`serve` 例外（状态信息打印到标准错误），`doctor` 例外（打印检查清单，加 `--json` 时为 JSON）。失败时，`build`、`patch`、`baseline` 向标准错误打印一行包含 `code` 和 `message` 的 JSON，其他命令打印 `CODE: message`。失败的退出码为 `2`；`doctor` 检查不通过时为 `1`。错误码的含义见[错误码与排障](troubleshooting-zh.md)。
- **警告**：以 `WARNING: <代码>: <说明>` 的形式打印到标准错误，不影响命令成功。
- **Flutter SDK**（`build`、`patch`、`doctor`）：默认使用 `PATH` 中的 Flutter，可用 `--flutter-sdk <路径>` 指定。
- **离线**（`build`、`patch`、`doctor`）：`--offline` 只使用本机已校验过的缓存，不访问网络；`patch --offline` 也只从本机缓存读取基线。
- **缓存**（`build`、`patch`、`doctor`）：`--cache-dir <目录>` 使用另一个缓存目录，它必须位于 `~/.flutter_patcher` 或项目的 `.dart_tool/flutter_patcher` 之下。Windows 上缓存路径最多 80 个字符；`~/.flutter_patcher` 超过这个长度时，请选择项目 `.dart_tool/flutter_patcher` 下的目录。
- `-h` / `--help` 显示命令自带的帮助，`--version` 显示 CLI 版本。

## 1.1 中删除的内容

| 删除 | 替代 |
|---|---|
| `trust sign`、`trust publish` | 无需替代：不再有 root 和 publisher 密钥 |
| `publish --production --request <文件>` | 直接在存储中删除或替换 `.fptc` 文件 |
| `keys init --role root\|publisher`、`keys import --rotate` | 无需替代：补丁密钥是唯一的密钥 |

现在使用它们会以未知命令或未知选项失败（`USAGE_ERROR`）。

## 补丁文件

`patch` 和 `publish` 只写一种文件：FPTC v1，`serve` 按原样提供它。同一个宿主的文件名始终相同：`<version_code>-<flavor>-<channel>-<abi>.fptc`，例如 `7-default-production-arm64-v8a.fptc`；App 中对应 `PatchTarget.fileName`。

| 偏移 | 字节数 | 字段 |
|---|---|---|
| 0 | 4 | 魔数 `FPTC`（`0x46505443`） |
| 4 | 2 | 版本 `1` |
| 6 | 32 | 宿主构建的指纹 |
| 38 | 4 | 序号 `seq`，uint32，至少为 1 |
| 42 | 8 | payload 长度 L |
| 50 | 32 | payload 的 SHA-256 |
| 82 | 64 | Ed25519 签名，签名内容为第 0–81 字节后接 payload；不签名时为 64 个 0 |
| 146 | L | payload：补丁 ZIP。L = 0 表示撤回 |

- 文件最大 320 MiB，长度必须正好是 146 + L 字节。
- `seq` 是封装文件时的 Unix 秒数，可用 `--seq` 指定。设备只安装 `seq` 大于该宿主已接受的所有 `seq` 的文件，见 [API 参考](api-reference-zh.md)。
- 带补丁密钥构建的宿主只接受该密钥签名的文件；不签名的宿主签名和不签名的文件都接受。

## 项目配置 `flutter_patcher.yaml`

所有字段都是可选的，文件里没有任何机密。文件不存在时，`keys init` 会按模板生成它。

| 字段 | 含义 | 默认值 |
|---|---|---|
| `url` | `build` 写进 App 的地址；`checkUpdate()` 不传 `url` 时从这里下载 `<url>/<fileName>`。设备只接受 HTTPS，或指向设备本机的 HTTP | `http://127.0.0.1:8686`，即 `serve` 提供补丁的地址；`build` 会警告 `URL_LOCAL` |
| `store` | 发布存储，`publish` 把补丁文件写到这里。支持 `file://` 和 `s3://` | `.flutter_patcher/updates/`（项目内） |
| `baseline_store` | 基线存储，`build` 写入、`patch` 读取。支持 `file://`、`s3://` 和 HTTPS | `.flutter_patcher/baselines/`（项目内） |
| `trust` | `patch`：项目补丁密钥的 base64 公钥。设置期间构建的宿主只接受它签名的文件。由 `keys init` 和 `keys import` 写入。flutter_patcher 1.0 写入的 `root`、`publisher` 允许保留，不再使用 | 不设置：宿主接受不签名的文件 |
| `signing` | `command`：用一个外部程序签名，代替本机密钥库，见[私钥从哪里来](#私钥从哪里来) | 本机密钥库 |

出现未知字段、格式不对的值，或 `trust` 中没有有效的 `patch`，都会报 `CONFIG_INVALID`。各类存储的要求见[存储要求](#存储要求)。

## 目录一览

| 路径 | 内容 | 是否需要备份 |
|---|---|---|
| `flutter_patcher.yaml` | 配置和项目的公钥 | 可选；`keys import` 会重新写入公钥 |
| `~/.flutter_patcher/keys/<ID>/keys.json` | 本机保存的补丁私钥（密钥库） | **是**，用 `keys export --out <文件>`；私钥丢失后，已上线的宿主无法更换 |
| `.flutter_patcher/baselines/` | 默认的基线存储 | **是**，或改用持久存储：宿主的每个补丁都需要它的基线 |
| `.flutter_patcher/updates/` | 默认的发布存储 | 否 |
| `.dart_tool/flutter_patcher/releases/` | `build` 的输出 | 否 |
| `.dart_tool/flutter_patcher/patches/` | `patch` 的输出；`serve` 提供每个宿主最新的一个 | 否 |
| `~/.flutter_patcher/`（`keys/` 除外） | 下载的引擎和工具、准备好的 Flutter SDK 副本、基线缓存 | 否，可以重新下载 |

## keys

签名是可选的。每个项目最多有一对 Ed25519 密钥，即补丁密钥。公钥保存在 `flutter_patcher.yaml`（`trust.patch`）中，私钥从不放在项目里。`build` 不需要私钥；宿主带补丁密钥时，`patch` 和 `publish` 会签名。

### keys init

```bash
dart run flutter_patcher keys init
```

生成补丁密钥：私钥保存到本机密钥库 `~/.flutter_patcher/keys/<ID>/keys.json`（POSIX 上文件权限 600、目录 700；Windows 上只有当前用户可读），公钥写入 `flutter_patcher.yaml` 的 `trust.patch`。此后构建的宿主只接受它签名的文件；之前构建的宿主仍然不签名。

- `flutter_patcher.yaml` 已经有补丁密钥，或项目中还有 `flutter_patcher_keys/` 目录时拒绝执行，报 `KEYS_ALREADY_CONFIGURED`。在另一台机器上请用 `keys import`。
- 只输出公钥，不输出私钥。请用 `keys export --out <文件>` 备份私钥。
- `--out <文件>` 只把新密钥写到这个新文件，不改动密钥库和项目。`--role patch` 可以和 `--out` 一起使用，它是唯一的角色。

### keys export 与 keys import

```bash
dart run flutter_patcher keys export --out <文件>      # 备份，或带到另一台机器
dart run flutter_patcher keys import <文件>
dart run flutter_patcher keys export --base64          # 一行文本，用作 CI 的 secret
```

| 选项 | 说明 |
|---|---|
| `export --out <文件>` | 把本机保存的该项目补丁私钥写到一个新文件（POSIX 上权限 600） |
| `export --base64` | 改为输出一行 base64，用于 `FLUTTER_PATCHER_KEYS` |
| `export --without-root` | 为兼容 1.0 的脚本而保留，不起作用 |
| `import <文件>` | 把密钥包加入本机密钥库；`-` 表示从标准输入读取；传入目录时按 1.0 之前的 `flutter_patcher_keys/` 结构读取（`<目录>/patch/private-key.base64`） |

- `export` 只读取本机密钥库，并要求 `flutter_patcher.yaml` 中有 `trust.patch`（否则报 `KEYS_NOT_CONFIGURED`）。
- `import` 只接受 `flutter_patcher.yaml` 中记录的那把密钥，否则报 `KEYS_MISMATCH`；项目还没有补丁密钥时，会把公钥写入 `flutter_patcher.yaml`，此后构建的宿主开启签名。
- flutter_patcher 1.0 写出的密钥包（含 root、publisher、patch 三把密钥）可以直接导入和签名，只使用其中的补丁密钥。不含补丁密钥的密钥包报 `KEYS_BUNDLE_INVALID`。

### keys status

```bash
dart run flutter_patcher keys status
```

输出 `config`（配置文件路径）、`public_key`（`trust.patch`，没有时为 `null`）和 `private_key`：私钥的来源，取值为 `--key-file`、`FLUTTER_PATCHER_KEYS`、`signing.command`、`key store`（本机密钥库）或 `none`。`<来源> (other key)` 表示该来源中是另一把密钥；输出错误码表示该来源无法读取。`--key-file <文件>` 会把这个密钥包也算进去。不会进行签名。

### 私钥从哪里来

`patch` 和 `publish` 按以下顺序查找补丁私钥，使用第一个存在的来源：

1. `--key-file <文件>`（仅 `publish`）：一个密钥包文件；
2. 环境变量 `FLUTTER_PATCHER_KEYS`：`keys export --base64` 输出的密钥包；
3. `flutter_patcher.yaml` 中的 `signing.command`；
4. 本机密钥库，按公钥查找密钥包，1.0 的目录也能找到。

如果这个来源中的密钥不是宿主的 `trust.patch`，命令直接报 `KEYS_MISMATCH`，不会尝试下一个来源。所有来源都不存在时，`patch` 仍然成功但不生成文件（`"file":null`），`publish` 报 `KEYS_NOT_FOUND`。

`signing.command` 让持有密钥的服务来签名，例如 KMS、HashiCorp Vault 或密码管理器，私钥不会出现在执行命令的机器上：

```yaml
signing:
  command: my-signer --key "fp-$FLUTTER_PATCHER_SIGN_ROLE"
```

命令在系统 shell 中运行（`sh`；Windows 上是 `cmd`，变量写作 `%FLUTTER_PATCHER_SIGN_ROLE%`），环境中设置 `FLUTTER_PATCHER_SIGN_ROLE=patch` 和 `FLUTTER_PATCHER_SIGN_PUBLIC_KEY`，不包含 `FLUTTER_PATCHER_KEYS`。它从标准输入读取待签名的字节，把 64 字节的 Ed25519 签名以 base64 输出到标准输出，限时 60 秒。每个签名都会先校验再使用。签名服务必须使用纯 Ed25519（不是 Ed25519ph），HashiCorp Vault transit 和 Google Cloud KMS 的 `EC_SIGN_ED25519` 密钥都符合。

## build

构建宿主安装包，并把这个版本的基线保存到基线存储。不需要私钥。

```bash
dart run flutter_patcher build android
dart run flutter_patcher build ios        # 仅限 Apple Silicon Mac
```

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--strategy bytecode\|so` | 补丁策略，仅 Android 可选，见[工作原理](architecture-zh.md) | `bytecode` |
| `--flavor <名称>` | Flutter flavor | 不使用 flavor（记为 `default`） |
| `--channel <名称>` | 渠道，写入宿主策略和补丁文件名 | `production` |
| `--version-code <数字>` | 版本号 | `pubspec.yaml` 中 `version` 的构建号 |
| `--application-id <包名>` | 工程中没有声明、或声明了多个包名，无法自动识别时指定 | 从 Gradle 或 Xcode 工程读取 |
| `--target <文件>` | 入口文件 | `lib/main.dart` |
| `--out <目录>` | 输出目录，必须是新目录 | `.dart_tool/flutter_patcher/releases/<时间戳>/` |
| `--export-method <方式>` | 仅 iOS，传给 `flutter build ipa`。`development` 可安装到已注册的测试设备；`app-store` 需要发布证书 | `app-store` |
| `--baseline-store <URI>` | 把基线保存到这里，而不是 `flutter_patcher.yaml` 中的 `baseline_store` | 取自 `flutter_patcher.yaml` |
| `--host-policy <文件>` | 高级：使用自己编写的宿主策略，而不是根据项目自动生成，见下文 | |

- 构建在项目的一份隔离副本中进行，不会修改你的源码和 Flutter SDK。
- 输出目录中有 `app-release.apk` 或 `app-release.ipa`，这就是要上架的安装包。
- 同一 flavor 和版本号重复构建：内容相同则沿用已有基线；内容不同则报 `BASELINE_RELEASE_CONFLICT`，请提升版本号。
- `flutter_patcher.yaml` 中没有 `trust.patch` 时，会打印 `WARNING: UNSIGNED`：任何能把文件交给 App 的一方都能在 App 中执行代码。要开启签名，运行 `keys init` 后重新构建；宿主的补丁密钥在构建时就已确定。
- `flutter_patcher.yaml` 中没有 `url` 时，会打印 `WARNING: URL_LOCAL`：不传 `url` 的 `checkUpdate()` 检查的是 `serve` 的本机地址。
- 基线存储为项目内的默认位置、且没有指定 `--baseline-store` 时，会打印 `WARNING: BASELINE_STORE_LOCAL`。
- Dart 源码含 CRLF 换行时会打印 `WARNING: CRLF_DART_SOURCES`，原因见[错误码与排障](troubleshooting-zh.md)。

**宿主策略文件**（`--host-policy`）：一个值全为字符串的 JSON 对象，字段恰好为 `schema`（`"2"`）、`strategy`（`bytecode` 或 `so`；iOS 只能是 `bytecode`）、`abi`（`arm64-v8a` 或 `ios-arm64`）、`application_id`、`version_code`、`flavor`、`channel` 和 `fptc_key`（补丁公钥的 base64，不签名的宿主为 `-`）。也接受 flutter_patcher 1.0 的策略（`"schema":"1"`）：保留其 `fptc_key`，丢弃 `root_key` 和 `keys`。其他内容报 `BUILD_CONFIG_INVALID`；`--flavor` 或 `--version-code` 与策略不一致时也报这个错误。

## patch

将当前源码与一个已构建版本的基线对比，生成补丁，并封装成该宿主的补丁文件。加 `--withdraw` 时改为写出该宿主的撤回文件。

```bash
dart run flutter_patcher patch android
dart run flutter_patcher patch ios
dart run flutter_patcher patch android --withdraw
```

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--version-code <数字>` | 为哪个版本生成补丁 | `pubspec.yaml` 中 `version` 的构建号 |
| `--flavor <名称>` | 该版本的 flavor | `default` |
| `--withdraw` | 不生成补丁，改为写出该宿主的撤回文件：应用它的设备删除补丁，下次冷启动起运行安装包自带的版本。只需要基线，不做任何编译 | |
| `--assets <资源键>` | 只覆盖指定的资源（可重复） | 自动选出有变化的资源 |
| `--target <文件>` | 入口文件 | `lib/main.dart` |
| `--out <目录>` | 输出目录，必须是新目录 | `.dart_tool/flutter_patcher/patches/<时间戳>/` |
| `--baseline-store <URI>` | 从这里读取基线，而不是 `flutter_patcher.yaml` 中的 `baseline_store` | 取自 `flutter_patcher.yaml` |

- 策略、渠道和补丁密钥都从基线读取。
- 输出目录中有 `patch.draft`（封装前的补丁）、`patch.json`（报告）和补丁文件 `<version_code>-<flavor>-<channel>-<abi>.fptc`。报告中的 `changed` 列出改动的内容，`warnings` 列出需要注意的问题，`patch_key` 是宿主的补丁公钥或 `-`。
- 输出的 JSON 还包含 `file`（补丁文件的完整路径）、`seq`（封装时的 Unix 秒数）、`sealed_at`（该时间的 UTC 表示）和 `signed`。
- 使用 `--withdraw` 时，输出目录中有 `patch.json`（`"status":"withdrawal_created"`）和同名的撤回文件 `<version_code>-<flavor>-<channel>-<abi>.fptc`；输出的 JSON 同样包含 `file`、`seq` 和 `signed`。
- 宿主开启了签名、而本机没有任何来源提供私钥时：`patch` 仍然成功，`"file":null` 并附带 `notice`。在本机 `keys import` 私钥后重新 patch，或在有私钥的机器上运行 `publish --patch <输出目录>`。
- `patch` 不写发布存储；只有 `publish` 写。
- 基线属于用 flutter_patcher 1.0 构建的宿主时报 `PATCH_BASELINE_INCOMPATIBLE`：请用 flutter_patcher 1.0.0+1 为该宿主打补丁。
- 不能热更的改动会导致命令失败，规则见[工作原理](architecture-zh.md)。
- 修好 bug 后再生成补丁，**不要修改 `pubspec.yaml` 的构建号**，否则 `patch` 会去找一个不存在的版本；或者用 `--version-code` 明确指定。

## publish

可选的发布命令。用发布时编号的 `seq` 重新封装一个 `patch` 输出，因此文件按发布的先后排序，再以 `<fileName>.fptc` 写入发布存储；只有新文件更新时才替换存储中已有的文件。

签名和不签名的宿主走同一个流程，是否签名由宿主的基线决定。签名的宿主需要从 `--key-file`、`FLUTTER_PATCHER_KEYS`、`signing.command` 或密钥库取得私钥（见[私钥从哪里来](#私钥从哪里来)）；取不到时，`publish` 在写入任何内容之前报 `KEYS_NOT_FOUND`。

```bash
dart run flutter_patcher publish
```

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--patch <目录>` | 要发布的 `patch` 输出目录 | `.dart_tool/flutter_patcher/patches/` 下最新的输出 |
| `--withdraw` | 改为写入该输出所属宿主的撤回文件：应用它的设备删除补丁，下次冷启动起运行安装包自带的版本。`patch --withdraw` 的输出不加此选项也按撤回发布 | |
| `--yes`, `-y` | 不询问，直接发布 | 先预览再询问；非交互环境下只预览 |
| `--seq <数字>` | 文件的序号，范围 1–4294967295，必须大于存储中现有文件的 `seq` | 当前 Unix 秒数 |
| `--key-file <文件>` | 优先使用这个密钥包签名 | |
| `--receipt <文件>` | 把发布结果另存为 JSON 文件 | |
| `--project <目录>` | 项目目录 | 当前目录 |

结果包含 `action`（`publish` 或 `withdraw`）、`file`、`store`、`signed`、`seq` 和 `status`：

| `status` | 情况 |
|---|---|
| `already_published` | 存储中已经是该宿主的同一份草稿（使用 `--withdraw` 时：已经是撤回文件）。不写入任何内容；`seq` 为存储中的序号 |
| `preview` | 没有 `--yes` 且没有终端可以询问，或回答不是 `y`。不写入任何内容，退出码为 `0` |
| `published` | 已写入文件 |

- 存储中同名文件的 `seq` 不小于新序号时报 `PUBLISH_SEQUENCE_CONFLICT`：检查本机时钟，或用 `--seq` 指定一个大于存储中序号的值。
- 读取之后、写入之前存储中的文件被改动时报 `PUBLISH_CONFLICT`；重新运行 `publish` 即可。
- 存储中还没有该宿主的文件时，也可以 `--withdraw`。
- 要回到之前的补丁，用 `--patch` 重新发布它的输出：会得到一个新的、更大的 `seq`。
- 发布存储是 `file://` 且填了 `url` 时，发布后会提示把文件上传到哪里：在 `<url>/<fileName>` 能访问到它之前，设备什么也看不到。
- 只有结果为 `published` 时才写 `--receipt`。该文件必须不存在，否则 `publish` 一开始就报 `PUBLISH_CONFIG_INVALID`。
- 发布存储为 S3 时需要已配置好的 AWS CLI。

## serve

开发用的调试工具。它按原样提供 `patch` 为每个宿主写出的最新文件，补丁或撤回文件都可以。

```bash
dart run flutter_patcher serve
```

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--port <端口>` | 本机端口，也是 `adb reverse` 映射到手机上的端口。未填 `url` 构建的 App 检查 `8686`，可用 `adb reverse tcp:8686 tcp:<端口>` 转过去 | `8686` |
| `--project <目录>` | 项目目录 | 当前目录 |

- 对每个宿主，提供 `.dart_tool/flutter_patcher/patches/` 下它最新一个输出中的文件；用 `patch --out` 写到别处的输出不会提供。`serve` 运行期间，每次新的 `patch` 约 2 秒内生效。
- 不发布、不写发布存储、不重新编号、不签名，`flutter_patcher.yaml` 中的 `store` 是什么都能用。设备像校验其他文件一样校验这些文件。
- 某个宿主的最新输出变化时，打印 `Offering patch <序号> (<文件名>, signed|unsigned)` 或 `Offering a withdrawal of <文件名> (signed|unsigned, <序号>)`。
- 某个宿主的最新输出没有文件时（签名的宿主，而本机没有它的私钥），打印 `Not offering <文件名>: ...`，不为该宿主提供任何文件，也不会退回提供更早的文件。请 `keys import` 后重新 patch。
- 只监听 `127.0.0.1`，只提供 `GET /<fileName>.fptc`；带 `Range: bytes=0-<n>` 的请求返回 `206`，其他请求一律 `404`。
- 每 2 秒检查一次已连接的 Android 设备，并对新设备执行 `adb reverse`。
- iOS 设备访问不到电脑的 `127.0.0.1`：请通过 HTTPS 暴露该端口（例如 `cloudflared tunnel --url http://127.0.0.1:8686`），并把这个地址传给 `checkUpdate(url: …)`。
- 按 Ctrl+C 停止。

## doctor

检查工具链是否就绪；首次运行时下载并准备所需的产物。

```bash
dart run flutter_patcher doctor
```

| 选项 | 说明 |
|---|---|
| `--json` | 以 JSON 输出详细报告 |
| `--project <目录>` | 同时检查项目 Dart 源码的换行符，并报告补丁私钥的来源 |
| `--baseline-store <URI>` | 检查基线存储是否可以访问（写权限在构建时才检查） |
| `--version-code <数字>` `--flavor <名称>` | 与 `--baseline-store` 一起使用，检查该版本的基线是否完整 |
| `--apk <文件>` | 检查一个 APK 中的引擎是否与当前 Flutter 版本匹配 |

退出码：`0` 通过，`1` 检查失败，`2` 参数错误。`doctor` 不检查设备，也不检查更新流程。

## 存储要求

### 基线存储

| 类型 | 要求 |
|---|---|
| `s3://` | 需要安装并配置 AWS CLI。查询不存在的对象时必须返回 `NoSuchKey`（404），因此除读写权限外还需要 `s3:ListBucket`，否则报 `BASELINE_STORE_UNREACHABLE`。S3 兼容服务（如 Cloudflare R2）需设置 `FLUTTER_PATCHER_S3_ENDPOINT` |
| HTTPS | 根地址对 `HEAD` 返回 `200`；支持 `GET`；支持带 `If-None-Match: *` 的 `PUT`（创建成功返回 `201`，已存在返回 `412`），不存在的对象返回 `404`。访问令牌通过 `FLUTTER_PATCHER_BASELINE_TOKEN` 传入 |
| `file://` | 本地目录或网络挂载盘 |

基线只追加、不覆盖，多台构建机可以共享同一个基线存储。

### 发布存储

| 类型 | 要求 |
|---|---|
| `s3://` | 需要支持条件写入（`put-object --if-match`、`--if-none-match`）的 AWS CLI，以及该前缀下读取和写入对象的权限，外加 `s3:ListBucket`：没有它时，不存在的文件会被当作拒绝访问，`publish` 报 `PUBLISH_STORE_UNAVAILABLE`。路径必须是存储桶下的专用前缀，每段只含字母、数字、`_` 和 `-`，例如 `s3://my-bucket/my-app` |
| `file://` | 本地目录或网络挂载盘 |

只有 `publish` 使用发布存储。它的根目录下每个宿主一个文件：`<version_code>-<flavor>-<channel>-<abi>.fptc`；`file://` 存储中还有 `.publish.lock`，不需要对外提供。flutter_patcher 1.0 写入的内容（`manifests/`、`objects/`、`catalog.json`）既不读取也不改动，继续为 1.0 宿主服务。

`checkUpdate` 下载所用的 HTTPS 服务或 CDN（无论文件是 `publish` 还是你自己放上去的）：

- 对 `GET <url>/<fileName>` 返回该文件（`200`，或针对请求范围的 `206`；不要求支持范围请求），没有文件时返回 `404`；其他状态码都会让 `checkUpdate` 抛出异常，例如私有 S3 和 R2 存储桶对不存在的对象返回的 `403`；
- 直接返回内容，不使用 `3xx` 重定向，客户端不跟随重定向；
- 返回的 `Content-Length` 等于文件大小，或使用 `Content-Encoding: gzip` 压缩；
- 在 2 分钟内传完整个文件，中途不能有 15 秒没有数据；
- 文件被替换后要及时提供新文件：缓存更新之后，设备才能看到新补丁或撤回。

## 高级命令

一般不需要使用以下命令。

| 命令 | 用途 |
|---|---|
| `baseline --action fetch\|verify\|release` | 下载、校验或查询基线存储中的基线，用于排查问题 |

## 环境变量

| 变量 | 用途 |
|---|---|
| `FLUTTER_PATCHER_KEYS` | 用于签名的密钥包（`keys export --base64` 的输出），通常是 CI 的 secret |
| `FLUTTER_PATCHER_SIGN_ROLE`、`FLUTTER_PATCHER_SIGN_PUBLIC_KEY` | 为 `signing.command` 设置：固定为 `patch`，以及要签名的公钥 |
| `FLUTTER_PATCHER_S3_ENDPOINT` | S3 兼容服务的 HTTPS 地址，例如 Cloudflare R2。AWS S3 不需要设置 |
| `FLUTTER_PATCHER_BASELINE_TOKEN` | HTTPS 基线存储的访问令牌，以 `Authorization: Bearer` 头发送 |
| AWS CLI 的标准变量和配置 | S3 的凭据和区域，例如 `AWS_PROFILE`、`AWS_REGION` |
