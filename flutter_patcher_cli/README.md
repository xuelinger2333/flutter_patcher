# flutter_patcher_cli

`publish` 默认是本地 mock；`publish --production` 是显式生产发布入口，
预览/条件提交、S3/R2、签名撤回与保留清理见
[生产发布说明](docs/production-publish.md)。
宿主信任策略、`trust` 命令和设备端签名清单见[认证更新说明](docs/authenticated-updates.md)。

本包负责为当前 Flutter 版本准备补丁工具链和新宿主的动态接口。运行时插件仍在仓库根目录；CLI 是独立 Dart 包，不依赖 `package:kernel`，不改变插件依赖。当前支持 `doctor`、`interface`、`baseline`、字节码 `build` / `patch`、`publish`、`trust` 和 `keys init`；完整选项以 `--help` 为准。

支持的构建主机为 Linux x64（含 x64 WSL2）和 Windows x64，目标 Android arm64。需要已初始化的 stock Flutter SDK、Git、PATH 中的 zstd 和首次下载所需的网络。Windows 上缓存路径不能超过 80 个字符。macOS 等其他主机会明确报错；不支持的 Flutter 版本不会转入自行编译流程。

```bash
cd flutter_patcher_cli
dart pub get --enforce-lockfile
dart run bin/flutter_patcher.dart doctor --json
# 多 SDK 环境可显式选择：
dart run bin/flutter_patcher.dart doctor --flutter-sdk /path/to/flutter --json
# 首次成功后可离线检查：
dart run bin/flutter_patcher.dart doctor --offline --json
```

也可用 `dart pub global activate --source path .` 安装本地版本，再运行 `flutter_patcher doctor`。入口 Dart 运行 CLI，所选 Flutter SDK 内的 Dart 运行下载的工具 dill。本包暂不发布到 pub.dev。

## 初始化正式签名密钥

在支持的构建主机上运行；密钥由内置 Ed25519 实现生成，不需要 OpenSSL 或 Flutter SDK，也不访问网络。

```bash
flutter_patcher keys init
# 或为另一个应用选择全新的目录：
flutter_patcher keys init --out "$HOME/.flutter_patcher/keys/my-app"
```

不指定 `--out` 时，默认目录为 `~/.flutter_patcher/keys`。生成
`private-key.base64`（32 字节 Ed25519 seed 的 Base64）和
`public-key.base64`（32 字节公钥的 Base64）。POSIX 上目录权限为 700，私钥为 600；
Windows 上目录 ACL 只授予当前用户。私钥不打印到终端，也不写入临时 DER 文件。
输出的一行 JSON 只有文件路径、格式和公钥 SHA256 指纹。目录内 `.gitignore` 排除私钥文件。

已有文件、目录或符号链接一律拒绝覆盖；重复运行不会轮换或覆盖旧密钥。
私钥文件不加密，请妥善备份并限制访问，不要把它随 APK 或源码分发。
同一宿主的后续补丁必须继续使用匹配的私钥；另生成一对密钥不会给旧宿主换钥。

将输出路径直接传给现有流程：宿主构建使用 `--public-key`，补丁使用
`--private-key`。以下目录和序号需替换为实际项目值：

```bash
flutter_patcher build android --strategy bytecode --project /path/to/app \
  --public-key "$HOME/.flutter_patcher/keys/public-key.base64" \
  --baseline-store file:///path/to/baselines --version-code 1 --out /path/to/new-release

flutter_patcher patch android --strategy bytecode --project /path/to/app \
  --private-key "$HOME/.flutter_patcher/keys/private-key.base64" \
  --baseline-store file:///path/to/baselines \
  --seq 1 --version-code 1 --out /path/to/new-patch
```

补丁按 `--flavor`（省略时为 `default`）和 `--version-code` 找到已归档的发布，
指纹由该发布决定。`--fingerprint` 可选：给出时必须与发布一致，否则报
`BASELINE_FINGERPRINT_MISMATCH`；只有没有发布绑定的旧基线才需要用它按指纹查找。
以前只传 `--fingerprint` 的脚本：若该 flavor/versionCode 已有发布，指纹必须与之一致；
旧基线按指纹找到的补丁不绑定发布（无签名 `target`）。

测试使用的公开 RFC 8032 测试密钥不能用于正式宿主。

## 基线存储

`build android` 把基线拆成两个对象写入 `--baseline-store`，只创建、不覆盖：

```text
compile-<fingerprint>.tar.zst                 编译对象：app.dill、接口、compiler_interface、
                                              allocate_finalized、source_hashes、
                                              host_policy?、framework_partition?、compile_receipt
release-<flavor>-<versionCode>-arm64-v8a.tar.zst
                                              发布对象：libapp.so、package_config.json、
                                              release_receipt（application_id、public_key、
                                              resources、package_inputs、build_id）
apk-<apk_sha256>.json                         APK 证明：apk_sha256、build_host、CRLF 列表
```

编译对象由指纹决定，同一 Dart 源码构建的多个发布共享它；发布对象按 manifest 摘要引用
编译对象。`apk_sha256`、`build_host`、`crlf_dart_sources` 每次重建都可能不同，
不参与任何身份比较，只写入 `build.json` 和 APK 证明对象。

重建规则：

- 同一 flavor/versionCode 重建，除上述易变证据外全部一致：成功，`release_status` 为
  `existing`，不重写对象，只为新 APK 写一份证明。
- 同一 flavor/versionCode 但内容不同（libapp.so、公钥、资源、依赖等）：
  `BASELINE_RELEASE_CONFLICT`，提示不同字段；请提升 versionCode。
- 仅原生改动的新 versionCode：复用同一编译对象，新增一个发布对象。
- 同一指纹但编译类文件不同：`BASELINE_CONTENT_CONFLICT`，不写发布对象。
- 该槽位已有旧格式侧车 `release-<flavor>-<versionCode>-arm64-v8a.json`：按旧基线的拆分视图比较，
  等价则 `existing_legacy` 且不写入，否则 `BASELINE_RELEASE_CONFLICT`。旧侧车与新发布对象
  并存且不一致时，读取报 `BASELINE_RELEASE_AMBIGUOUS`。

保存时还检查 build receipt 的 versionCode 与归档的发布一致；有宿主策略时，策略中的
application_id、version_code、flavor、abi、fptc_key 必须与发布一致。

旧格式（`baseline-<fingerprint>.tar.zst` + 侧车，schema 1–4）仍可被 patch、publish、doctor
和 `baseline` 读取；只写新格式。旧版 CLI 读不到新对象，CI 与开发机需同步升级；自建 HTTPS
store 若有对象名白名单，需放行 `compile-*`、`release-*.tar.zst` 和 `apk-*.json`。
同一指纹的旧 `baseline-<fingerprint>.tar.zst` 与新 `compile-<fingerprint>.tar.zst` 可以并存。
旧侧车无法读取（指向缺失或损坏的旧基线）时，不阻止解析同槽位的新发布对象，结果中给出
`warnings`；旧侧车与新发布对象等价时按旧格式解析，生产发布保持旧的身份结构。

store 必须把不存在的对象报告为 HTTP 404 或 S3 `NoSuchKey`：保存与解析靠"对象不存在"
决定读写什么。把缺失对象报告为 403/AccessDenied 的 store（如没有 `s3:ListBucket` 的 S3
角色、部分 CDN）会以 `BASELINE_STORE_UNREACHABLE` 失败，错误信息给出对象名。

缓存目录 `~/.flutter_patcher/baselines` 被所有项目和 store 共用。联网时发布对象总以
store 为准：缓存只在与 store 中对象一致时使用，否则隔离为 `.invalid-*` 后重新下载；
身份（flavor/versionCode/ABI，大小写敏感）不符的缓存同样隔离。离线时直接信任上次校验过的缓存。
APK 证明对象只是证据：已存在但内容不同（如同一 APK 在另一主机上重建）时报告
`existing_differs`，写入失败报告 `failed`，都不会使构建失败。

补丁绑定到一个发布：`patch_manifest.json` 的签名 `target` 记录 flavor、versionCode、ABI
和发布 manifest 摘要，`publish --production` 拒绝发往其他发布（`PUBLISH_TARGET_MISMATCH`）；
没有 `target` 的补丁只能发布到旧格式发布。设备按指纹记录补丁序号，因此共享指纹的发布
共用一个序号空间：生产发布要求新序号大于同指纹其他发布已发布的最大序号
（`PUBLISH_SEQUENCE_CONFLICT`）。

`baseline` 子命令：`--action save` 只写新格式，schema 1 输入报 `BASELINE_SCHEMA_UNSUPPORTED`；
`fetch --fingerprint` 优先取编译对象，没有时回退旧基线；`release` 解析两种格式；
`verify --baseline DIR` 按目录中的 manifest（`baseline`/`compile`/`release.manifest.json`）分派。

## 自动准备的内容

1. 读取 `flutter --version --machine`，核对 SDK 的缓存状态、Flutter/Dart/engine 身份和 artifacts 仓库唯一支持表。
2. 从 `flutter_patcher_artifacts` 的 `flutter-<version>` Release 获取两份 manifest、引擎 jar、当前构建主机的 gen_snapshot、embedding jar 和单个工具 dill。检查 schema、版本、角色、大小、SHA-256、二进制架构及 jar 内部 SO。两条独立流水线允许不同 builder commit。
3. clone 精确匹配的 Flutter framework commit 到平行 SDK，先执行 stock `precache --android`，再替换该副本的 gen_snapshot，并准备含 jar/POM 的本地 Maven 镜像；`build` 通过 `FLUTTER_STORAGE_BASE_URL` 让 APK 构建使用该镜像。
4. 调用 CI 编好的 dill，检查工具入口和 `bytecode` 子命令；用所选 SDK 的 Flutter 源码编译一个隔离的探针 kernel，生成协议和平台私有 YAML。这里编译的是探针，工具 dill 始终直接下载。
5. 用匹配的 frontend 和下载的 gen_snapshot 实际编译最小 arm64 AOT ELF，验证编译器链可调用。

默认缓存：

```text
~/.flutter_patcher/
  support/                           支持表（按来源隔离）
  artifacts/<version>/engine/<os>-<arch>/ 已校验的引擎附件（按构建主机分目录）
  artifacts/<version>/tools/         已校验的工具附件
  flutter/<version>/                 平行 SDK
  mirrors/<version>/<build_id>/      本地 Maven 文件布局
  baselines/compile/<fingerprint>/   已校验的编译对象
  baselines/release/<flavor>-<versionCode>-arm64-v8a/ 已校验的发布对象
  baselines/<fingerprint>/           旧格式基线
  yaml/<version>/<input-hash>/       YAML、输入/输出哈希及隔离探针
  pub-cache/                         隔离 Dart 包缓存
  verification/                      最小 AOT 冒烟结果
  doctor.lock                        进程间互斥锁
```

`--cache-dir` 只允许位于 `~/.flutter_patcher/` 或当前目录的 `.dart_tool/flutter_patcher/` 下。下载先写临时路径，全部验证后才进入可复用缓存；损坏缓存保留为 `.invalid-*` 后重新获取。未完成的 `.pending-*` 不会被当作成功产物。正常复用不下载；缓存支持表不含新版本时，在线刷新一次。离线缺失或损坏产物会失败。

YAML 缓存键包含版本、engine/framework commit、所用 Flutter 源文件、pubspec、平台 dill、frontend 和工具 dill 的哈希。输入变化换缓存；缺失或损坏 YAML 自动重生成，离线生成还要求探针依赖已缓存。不会编辑所选 Flutter SDK 或用户项目源码。过期 SDK 在启动 Flutter 前被拒绝，以避免触发 Flutter 自身更新。

## doctor 的边界

退出码：`0` 工具链及显式提供的检查通过；`1` 诊断失败；`2` 参数错误。JSON 中 `status: toolchain_ready` 仅表示工具链就绪。缺少项目上下文会显示 `not_run`；设备执行和更新流程不由 doctor 检查（`device` 项始终为 `not_run`），因此 `all_checks_complete` 始终为 `false`。

| 可选参数 | 实际检查 |
|---|---|
| `--public-key`、`--private-key` | 两文件存在且非空，不验证密码学格式或签名 |
| `--baseline-store` | `file://` 目录存在、`s3://` bucket 可访问或 HTTPS HEAD 成功；写权限在保存时检查 |
| `--baseline` | 按目录中的 manifest 校验旧基线、编译对象或发布对象：文件一致、是 release 基线，且绑定所选 SDK/engine（编译对象不含 build_id） |
| `--version-code`、`--flavor` 与 `--baseline-store` | 解析该发布（新发布对象或旧侧车）并完整校验其基线，且匹配所选 engine 构建 |
| `--apk` | ZIP 内 `lib/arm64-v8a/libflutter.so` 大小/哈希匹配 manifest；不安装或运行 APK |
| `--project` | 项目 Dart 源码是否含 CRLF 换行；含有时给出 `warning`（`build` 也会警告并把文件列表写入 receipt） |

源码身份按字节比较、不做换行归一化：Windows 上 Git 默认 `core.autocrlf=true`，同一提交的 CRLF 与 LF 检出会得到不同指纹，补丁也必须从换行一致的检出构建，否则所有文件都视为改动、原生文件报 `PATCH_NATIVE_CHANGE`。跨主机协作时在 `.gitattributes` 加 `* text=auto eol=lf`。项目内与排除目录（`build`、`.dart_tool` 等）仅大小写不同的目录会被拒绝（`BUILD_PROJECT_INVALID`），因为不区分大小写的文件系统会把构建产物写进去。

`--artifacts-url`、`--supported-versions-url` 是维护/测试用覆盖项，普通用户只需选择 Flutter SDK。下载允许 HTTPS，HTTP 仅允许 loopback 测试服务。错误报告不会提供自行编译引擎的路径。

## 接口准备

`interface` 是为新宿主准备动态接口的维护入口，不修改已发布基线。
需要含接口准备子命令的 CI 工具 dill；缓存的工具缺少这些命令时报 `TOOLS_VERSION_UNSUPPORTED`。
源码实现不会自动覆盖现有 Release，审核后的新工具发布仍使用同一 Flutter 版本的单 dill。
工具发布更新后，执行 `flutter_patcher doctor --refresh-tools` 在线校验并替换工具缓存；
刷新失败保留原缓存，不刷新引擎。工具哈希变化会使 SDK YAML 缓存失效。

```bash
flutter_patcher interface \
  --dill /path/to/unannotated-app.dill \
  --module /path/to/module.dart \
  --packages /path/to/module/.dart_tool/package_config.json \
  --own my_app --mode lean --out /path/to/new-interface-output --json
```

`--out` 必须是新目录；省略时使用项目 `.dart_tool/flutter_patcher/interfaces/` 下的新子目录。
SDK、工具和协议缓存沿用 doctor 的自动版本选择。只读输入文件，所有轮次在临时目录完成，
验证成功后才提交输出。失败保留诊断，不把半成品当作可用接口。

- `dynamic_interface.yaml`：已引用面、协议、常用控件和 dart:core 的确定性并集。
- `trim_interface.yaml`：同源派生，额外保留自有库导入的 barrel；仅用于裁剪。
- `interface.manifest.json`：输入/输出与工具哈希、模式、轮次及校验结果。
- 每轮 YAML、编译日志、验证字节码及精简档的裁剪 kernel：用于诊断，不是可发布补丁。

精简档调用 CI 工具中的 SDK trimmer，然后通过 `--import-dill` 验证模块；整程序档编译框架副本，
使用完整平台接口、平台私有条目和限定的动态调用选择子。两档都只补全编译器明确要求的声明，
不全局模糊匹配同名类，无法解析/仍有歧义、无进展或超过 `--max-rounds`（上限 5）时失败。

没有 main 的模块通过临时入口生成索引，实际字节码编译仍针对原模块。
成功状态为 `interface_validated`，`host_build_verified` 和 `device_verified` 均为 false：
这不代表宿主 APK 已按该接口构建，也不代表补丁已经在设备上运行。

## 验证

```bash
dart analyze
dart test
```

测试使用本地 HTTP 和合成二进制，覆盖 manifest 错配、校验失败、下载中断、缓存恢复、支持表刷新、YAML 输入变化和命令错误。
