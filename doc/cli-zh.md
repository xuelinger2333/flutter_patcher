# CLI 参考

[English](cli.md) | **简体中文**

CLI 随插件一起发布。在依赖了 `flutter_patcher` 的项目目录中运行：

```bash
dart run flutter_patcher <命令> [选项]
```

本文逐一列出命令和选项。完整的上手流程见[快速上手](getting-started-zh.md)，上线相关的做法见[生产部署](production-playbook-zh.md)。

## 通用约定

- **项目目录**：默认是当前目录，可用 `--project` 指定（`keys init` 除外，它总是使用当前目录）。
- **输出**：成功时向标准输出打印一行 JSON；`serve` 例外（状态信息打印到标准错误），`doctor` 例外（打印检查清单，加 `--json` 时为 JSON）。失败时，`build`、`patch`、`baseline` 向标准错误打印一行包含 `code` 和 `message` 的 JSON，其他命令打印 `CODE: message`。失败的退出码为 `2`；`doctor` 检查不通过时为 `1`。错误码的含义见[错误码与排障](troubleshooting-zh.md)。
- **警告**：以 `WARNING: <代码>: <说明>` 的形式打印到标准错误，不影响命令成功。
- **Flutter SDK**（`build`、`patch`、`doctor`）：默认使用 `PATH` 中的 Flutter，可用 `--flutter-sdk <路径>` 指定。
- **离线**（`build`、`patch`、`doctor`）：`--offline` 只使用本机已校验过的缓存，不访问网络；`patch --offline` 也只从本机缓存读取基线。
- **缓存**（`build`、`patch`、`doctor`）：`--cache-dir <目录>` 使用另一个缓存目录，它必须位于 `~/.flutter_patcher` 或项目的 `.dart_tool/flutter_patcher` 之下。Windows 上缓存路径最多 80 个字符；`~/.flutter_patcher` 超过这个长度时，请选择项目 `.dart_tool/flutter_patcher` 下的目录。
- `-h` / `--help` 显示命令自带的帮助，`--version` 显示 CLI 版本。

## 项目配置 `flutter_patcher.yaml`

所有字段都是可选的，不写时使用默认值。`keys init` 会生成一份全部注释掉的模板。

| 字段 | 含义 | 默认值 |
|---|---|---|
| `store` | 发布存储，`publish` 把补丁和清单写到这里。支持 `file://` 和 `s3://` | `.flutter_patcher/updates/`（项目内） |
| `baseline_store` | 基线存储，`build` 写入、`patch` 和 `publish` 读取。支持 `file://`、`s3://` 和 HTTPS | `.flutter_patcher/baselines/`（项目内） |
| `keys` | 密钥目录，相对于本文件 | `flutter_patcher_keys` |

出现未知字段或非字符串的值会报 `CONFIG_INVALID`。存储的配置方法见[生产部署](production-playbook-zh.md#配置存储)，各类型的要求见[存储要求](#存储要求)。

## 目录一览

| 路径 | 内容 | 是否需要备份 |
|---|---|---|
| `flutter_patcher_keys/` | 三对密钥 | **是**，私钥不要提交到 git |
| `.flutter_patcher/baselines/` | 默认的基线存储 | **是**，或改用持久存储 |
| `.flutter_patcher/updates/` | 默认的发布存储 | 视情况 |
| `.dart_tool/flutter_patcher/releases/` | `build` 的输出 | 否 |
| `.dart_tool/flutter_patcher/patches/` | `patch` 的输出 | 否 |
| `~/.flutter_patcher/` | 下载的引擎和工具、准备好的 Flutter SDK 副本、基线缓存 | 否，可以重新下载 |

## keys init

生成三对 Ed25519 密钥（`root`、`publisher`、`patch`），用途见[工作原理](architecture-zh.md#安全模型)。

```bash
dart run flutter_patcher keys init
```

| 选项 | 说明 |
|---|---|
| `--out <目录>` | 写到另一个新目录，而不是项目的 `flutter_patcher_keys/` |

- 输出一行 JSON，包含密钥文件路径和公钥指纹，不含私钥。
- 目标已存在时拒绝执行，不会覆盖或轮换已有密钥。
- 在 POSIX 系统上，密钥目录权限为 700、私钥文件为 600；在 Windows 上，目录只授权给当前用户。
- 使用默认目录、且项目中还没有 `flutter_patcher.yaml` 时，会顺带生成配置模板。

## build

构建宿主安装包，并把这个版本的基线保存到基线存储。

```bash
dart run flutter_patcher build android
dart run flutter_patcher build ios        # 仅限 Apple Silicon Mac
```

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--strategy bytecode\|so` | 补丁策略，仅 Android 可选，见[工作原理](architecture-zh.md#两种补丁策略) | `bytecode` |
| `--flavor <名称>` | Flutter flavor | 不使用 flavor（记为 `default`） |
| `--channel <名称>` | 发布渠道，写入宿主策略，补丁只能发往同一渠道 | `production` |
| `--version-code <数字>` | 版本号 | `pubspec.yaml` 中 `version` 的构建号 |
| `--application-id <包名>` | 工程中没有声明、或声明了多个包名，无法自动识别时指定 | 从 Gradle 或 Xcode 工程读取 |
| `--target <文件>` | 入口文件 | `lib/main.dart` |
| `--out <目录>` | 输出目录，必须是新目录 | `.dart_tool/flutter_patcher/releases/<时间戳>/` |
| `--export-method <方式>` | 仅 iOS，传给 `flutter build ipa` | `app-store` |
| `--baseline-store <URI>` | 把基线保存到这里，而不是 `flutter_patcher.yaml` 中的 `baseline_store` | 取自 `flutter_patcher.yaml` |
| `--host-policy <文件>` | 高级：使用自己编写的宿主策略，而不是根据项目自动生成 | |

- 构建在项目的一份隔离副本中进行，不会修改你的源码和 Flutter SDK。
- 输出目录中有 `app-release.apk` 或 `app-release.ipa`，这就是要上架的安装包。
- 同一 flavor 和版本号重复构建：内容相同则沿用已有基线；内容不同则报 `BASELINE_RELEASE_CONFLICT`，请提升版本号。
- 基线存储为项目内的默认位置、且没有指定 `--baseline-store` 时，会打印 `WARNING: BASELINE_STORE_LOCAL`。
- Dart 源码含 CRLF 换行时会打印 `WARNING: CRLF_DART_SOURCES`，原因见[错误码与排障](troubleshooting-zh.md)。

## patch

将当前源码与一个已构建版本的基线对比，生成补丁。

```bash
dart run flutter_patcher patch android
dart run flutter_patcher patch ios
```

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--version-code <数字>` | 为哪个版本生成补丁 | `pubspec.yaml` 中 `version` 的构建号 |
| `--flavor <名称>` | 该版本的 flavor | `default` |
| `--seq <数字>` | 补丁序号，必须大于该版本已发布过的序号 | 发布存储中已有的最大序号 + 1 |
| `--assets <资源键>` | 只覆盖指定的资源（可重复） | 自动选出有变化的资源 |
| `--target <文件>` | 入口文件 | `lib/main.dart` |
| `--out <目录>` | 输出目录，必须是新目录 | `.dart_tool/flutter_patcher/patches/<时间戳>/` |
| `--baseline-store <URI>` | 从这里读取基线，而不是 `flutter_patcher.yaml` 中的 `baseline_store` | 取自 `flutter_patcher.yaml` |

- 策略、渠道等都从基线读取，不需要再次指定。
- 输出目录中有 `patch.fptc`（补丁）和 `patch.json`（报告）。报告中的 `changed` 列出改动的内容，`warnings` 列出需要注意的问题。
- 不能热更的改动会导致命令失败，规则见[工作原理](architecture-zh.md#能更新什么)。
- 修好 bug 后再生成补丁，**不要修改 `pubspec.yaml` 的构建号**，否则 `patch` 会去找一个不存在的版本；或者用 `--version-code` 明确指定。

## publish

签名并把补丁发布到发布存储。

```bash
dart run flutter_patcher publish
```

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--patch <目录>` | 要发布的 `patch` 输出目录 | 最近一次 `patch` 的输出 |
| `--withdraw` | 改为撤回该补丁所属版本已发布的补丁，见[生产部署](production-playbook-zh.md#撤回补丁) | |
| `--through <序号>` | 与 `--withdraw` 一起使用：撤回到这个序号为止 | 已发布的最大序号 |
| `--yes`, `-y` | 不询问，直接发布 | 先预览再询问；非交互环境下只预览 |
| `--receipt <文件>` | 把发布结果另存为 JSON 文件（必须是新文件） | |
| `--production --request <文件>` | 高级：执行手写的发布或清理请求文件，见[进阶操作](advanced-zh.md#清理历史补丁) | |

- 没有 `--yes`、又没有终端可以询问时，只预览：不会发布任何内容，退出码仍为 `0`。
- 发布前会再次校验：补丁确实是为该版本生成的，序号没有冲突，存储中的内容自上次读取后没有被别人改动。
- 提交期间，本次发布的请求保存在 `.dart_tool/flutter_patcher/publish-pending.json`。如果提交中途停止，存储在这次发布完成之前不接受其他操作，因此项目中下一次运行 `publish`（或 `serve`）时会先自动续上它。
- 发布存储为 S3 时需要已配置好的 AWS CLI。

## serve

开发用的补丁服务。

```bash
dart run flutter_patcher serve
```

| 选项 | 说明 | 默认值 |
|---|---|---|
| `--port <端口>` | 本机端口，也是 `adb reverse` 映射到手机上的端口 | `8686` |

- 每当出现新的 `patch` 输出，自动发布到项目的发布存储，不需要手动运行 `publish`。
- 只监听 `127.0.0.1`，只提供清单和补丁文件。
- 每 2 秒检查一次已连接的 Android 设备，并对新设备执行 `adb reverse`。
- 只支持 `file://` 发布存储；如果 `flutter_patcher.yaml` 配置了 `s3://`，开发时请先注释掉。
- 按 Ctrl+C 停止。

## doctor

检查工具链是否就绪；首次运行时下载并准备所需的产物。

```bash
dart run flutter_patcher doctor
```

| 选项 | 说明 |
|---|---|
| `--json` | 以 JSON 输出详细报告 |
| `--project <目录>` | 同时检查项目 Dart 源码的换行符 |
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
| `s3://` | 需要支持条件写入（`--if-match`、`--if-none-match`）的 AWS CLI；除读写和 `s3:ListBucket` 外，清理历史补丁还需要 `s3:DeleteObject`。路径必须是存储桶下的专用前缀，每段只含字母、数字、`_` 和 `-`，例如 `s3://my-bucket/my-app` |
| `file://` | 本地目录或网络挂载盘 |

`patch` 需要读取发布存储来确定补丁序号，因此执行 `patch` 的机器也需要发布存储的读取权限。

发布存储的内容：

| 路径 | 内容 | 是否需要对外访问 |
|---|---|:---:|
| `manifests/<哈希>.json` | 各版本当前生效的签名清单 | 是 |
| `objects/<操作 ID>/<哈希>.fptc` | 补丁文件，写入后不再改变 | 是 |
| `catalog.json` | CLI 使用的发布记录 | 否，建议在 CDN 上屏蔽 |

对外提供访问的 HTTPS 服务或 CDN：

- 直接返回内容，不使用 `3xx` 重定向，客户端不跟随重定向；
- `manifests/` 使用很短的缓存时间（如 `max-age=60`）或 `no-cache`，`objects/` 可以长期缓存（如 `max-age=31536000, immutable`）；
- 可以开启 gzip，客户端支持 `Content-Encoding: gzip`；
- 清单文件最大 24,000 字节，补丁文件需要在 2 分钟内下载完成。
## 高级命令

一般不需要使用以下命令。

| 命令 | 用途 |
|---|---|
| `trust sign` / `trust publish` | 用 root 密钥签名并发布新的 publisher 公钥集合，用于轮换或吊销 publisher 密钥，见[进阶操作](advanced-zh.md#轮换发布密钥) |
| `baseline --action fetch\|verify\|release` | 下载、校验或查询基线存储中的基线，用于排查问题 |

## 环境变量

| 变量 | 用途 |
|---|---|
| `FLUTTER_PATCHER_S3_ENDPOINT` | S3 兼容服务的 HTTPS 地址，例如 Cloudflare R2。AWS S3 不需要设置 |
| `FLUTTER_PATCHER_BASELINE_TOKEN` | HTTPS 基线存储的访问令牌，以 `Authorization: Bearer` 头发送 |
| AWS CLI 的标准变量和配置 | S3 的凭据和区域，例如 `AWS_PROFILE`、`AWS_REGION` |
