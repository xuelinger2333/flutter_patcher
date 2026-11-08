<!-- ========================================== -->
<!-- doc/troubleshooting-zh.md (简体中文)       -->
<!-- ========================================== -->

# 错误码与排障

[English](troubleshooting.md) | **简体中文**

CLI 执行失败时会在标准错误输出错误码 `code` 与原因说明 `message`：`build`、`patch`、`baseline` 输出一行 JSON，其他命令输出 `CODE: message`。例如：

```json
{"command":"patch","status":"failed","code":"PATCH_NATIVE_CHANGE","message":"Native plugin/build hook changed: camera"}
```

`message` 字段通常会直接指出具体原因。本文先列出高频排障场景，再按模块列出 flutter_patcher 1.1 可能报出的全部错误码，以及只有 flutter_patcher 1.0 才会报出的错误码。设备端的排障方式见文末。

## 常见问题

### 只改了一行 Dart 代码，却提示“所有文件都被修改”或报 `PATCH_NATIVE_CHANGE`

**原因**：基线对比按字节比对源码。Windows 下 Git 默认会将换行符转换为 `CRLF`；若构建基线包与生成补丁时检出的换行符格式不一致，所有源码及原生文件都会被判定为已发生变更（`build` 和 `doctor --project` 检测到 `CRLF` 时也会输出警告）。

**解决方法**：在 Git 仓库根目录的 `.gitattributes` 中添加 `* text=auto eol=lf`，重新检出代码，确保构建基线与生成补丁均统一使用 `LF` 换行符。

### `BASELINE_NOT_FOUND`：找不到基线

`patch` 命令通过 `flavor` 和构建号（默认取自 `pubspec.yaml` 中 `+` 后面的数字）查找对应基线。请依次排查：

- 修复 Bug 时是否误改了 `pubspec.yaml` 中的版本号？请改回线上版本的值，或通过 `--version-code` 显式指定。
- `--flavor` 参数是否与构建基线时一致？
- 当前机器配置的 `baseline_store` 地址是否与构建基线时一致？

### `BASELINE_RELEASE_CONFLICT`：拒绝重复构建同版本基线

基线存储中已存在同一版本号但内容不同的基线快照，`build` 为保护线上版本会拒绝覆盖。
- 若该版本**已上线**，请递增 `pubspec.yaml` 中的版本号后再构建。
- 若该版本**从未发布**且确认废弃，可手动从基线存储中删除对应的 `release-<flavor>-<版本号>-<abi>` 文件后重试。

### `PATCH_BASELINE_INCOMPATIBLE`：当前 flutter_patcher 无法为该宿主打补丁

`message` 会说明是哪种情况：

- **宿主由 flutter_patcher 1.0 构建**（`This host was built with flutter_patcher 1.0`）：请用 flutter_patcher 1.0.0+1 为该宿主打补丁、发布和撤回。之后用 1.1 构建的宿主再用 1.1 打补丁。
- **Flutter 版本不一致**：生成补丁所使用的 Flutter SDK 版本必须与构建该版本时**完全一致**。请切换到对应版本，或通过 `--flutter-sdk` 指定。
- **基线缺少记录**（`rebuild host`）：该宿主早于当前版本所需的记录，请构建并发布新的宿主。
- **来自 `publish`**（`is not a patch output of this flutter_patcher`）：`--patch` 目录是 flutter_patcher 1.0 写出的，请重新运行 `patch`。

### `BASELINE_STORE_UNREACHABLE`：存储明明可访问却报错

基线存储在查询不存在的对象时，必须返回 `404`（S3 对应 `NoSuchKey`）。在 AWS S3 或兼容存储中，若 IAM 角色缺少 `s3:ListBucket` 权限，访问不存在的对象会返回 `403 Forbidden`（部分 CDN 也有类似行为），从而触发此错误。请为凭据补充 `s3:ListBucket` 权限（报错信息中会指明具体受阻的对象名称）。

### `PUBLISH_SEQUENCE_CONFLICT`：存储中的文件更新

存储中该宿主文件的 `seq` 不小于 `publish` 将要写入的序号。文件的 `seq` 是封装时的 Unix 秒数，所以这表示上一次是由一台时钟比本机快的电脑发布的，或者之前用过 `--seq`。请校正本机时钟，或使用 `message` 中建议的 `--seq` 发布。已经拿到那个更新文件的设备，只接受序号比它更大的文件。

### `patch` 成功但 `"file":null`

宿主带补丁密钥（`trust.patch`）构建，而本机没有任何来源提供它的私钥。草稿已在输出目录中。请在有私钥的机器上运行 `publish --patch <输出目录>`，或用 `keys import <密钥包>` 把私钥带到本机后运行 `publish`。`keys status` 会显示私钥将从哪里来。

### `HOST_UNSUPPORTED`：当前主机不支持该操作

- **构建 Android 基线包（`build android`）**：需 Linux x64、Windows x64 或 Apple Silicon Mac。
- **构建 iOS 基线包（`build ios`）**：需 Apple Silicon Mac。
- **生成补丁（`patch android` / `patch ios`）**：以上三种主机均可运行。

### 客户端调用 `checkUpdate` 始终检测不到更新

- `checkUpdate` 请求的是 `<url>/<fileName>`：把 `FlutterPatcher.patchTarget.fileName` 与存储中的文件名对比，把 `url` 与文件实际所在的地址对比。调用时没有传 `url` 时，用的是构建时 `flutter_patcher.yaml` 中的 `url`（修改后需重新构建）。
- 填了 `url` 时，设备读取的不是 `file://` 发布存储本身：每次 `publish` 后请把文件上传到 `<url>/<fileName>`。
- 文件必须比 `patchTarget.acceptedSeq` 新。时钟偏慢的电脑封装的文件、重新上传的旧文件都不算新；请重新 `publish`（必要时用大于 `acceptedSeq` 的 `--seq`）。
- 文件必须属于设备上安装的构建（`patchTarget.versionCode`、`flavor`、`channel`、`abi`、`fingerprint`）。用户从应用商店升级 App 后，需要为新构建单独生成并发布补丁。
- CDN 可能仍在返回之前的文件；请缩短 `.fptc` 文件的缓存时间。
- 该地址必须通过 HTTPS 直接返回内容，不使用 `3xx` 重定向，文件不存在时返回 `404`。
- 想知道设备如何看待这个文件，可以自己取它的前 146 字节传给 `FlutterPatcher.inspectPatch`：`reason` 会说明它为什么不是新的。

---

## 错误码速查表

### 1. 环境与工具链

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `FLUTTER_NOT_FOUND` | 系统 `PATH` 中找不到 Flutter | 将 Flutter 加入 `PATH`，或使用 `--flutter-sdk` 指定路径 |
| `FLUTTER_VERSION_INVALID` | 无法读取 Flutter 版本信息 | 运行 `flutter --version` 确认 SDK 完整性 |
| `SDK_NOT_READY` | 所选 Flutter SDK 未完成初始化或缓存残缺 | 先运行一次 `flutter doctor`，完成后重试 |
| `SDK_PREPARE_FAILED` | 准备内部 Flutter SDK 副本失败 | 检查网络连接与磁盘空间后重试；若持续失败请提交 Issue |
| `ENGINE_ARTIFACT_MISSING` | 当前 Flutter 版本无可用定制引擎或缺失文件 | 切换至支持的 Flutter 版本，见 [README](../README-zh.md) |
| `ENGINE_ARTIFACT_MISMATCH`<br>`ARTIFACT_HASH_MISMATCH`<br>`ARTIFACT_INVALID`<br>`ENGINE_MANIFEST_INVALID`<br>`TOOLS_ARTIFACT_MISSING`<br>`TOOLS_VERSION_UNSUPPORTED`<br>`YAML_CACHE_INVALID`<br>`YAML_GENERATION_FAILED`<br>`EMBEDDING_POM_UNAVAILABLE` | 下载的引擎或编译工具链残缺、哈希校验失败 | 检查网络后直接重试；损坏的本地缓存会被自动隔离并重新下载 |
| `CACHE_INVALID` | 命令用到的路径（缓存、项目、存储、密钥、补丁输出或回执文件）本身是符号链接，或经过符号链接 | 改用真实路径，不要经过符号链接 |
| `HOST_UNSUPPORTED` | 当前操作系统或 CPU 架构不支持该命令 | 参见上文 [常见问题：`HOST_UNSUPPORTED`](#host_unsupported当前主机不支持该操作) |
| `ANDROID_SDK_MISSING` | 找不到 Android SDK 或 `build-tools` | 设置环境变量 `ANDROID_HOME`，或运行 `flutter config --android-sdk` |
| `JAVA_HOME_INVALID` | `JAVA_HOME` 未指向有效的 JDK | 修正 `JAVA_HOME` 环境变量 |
| `XCODE_MISSING` | 未安装 Xcode 或 iOS 平台组件 | 安装 Xcode，并在 Xcode 设置中下载 iOS 平台组件 |
| `DISK_FULL` | 磁盘空间不足 | 清理磁盘空间后重试 |
| `PUB_LOCKFILE_MISMATCH` | `pubspec.lock` 与 `pubspec.yaml` 不一致，或是用另一个包源解析的（例如一个终端设置了 `PUB_HOSTED_URL` 镜像，另一个没有） | 在执行构建的终端中，于项目目录运行 `flutter pub get` 后重试 |
| `TOOL_FAILED` | 底层构建工具执行失败 | 查看 `message` 中附带的工具输出末尾 |
| `CONFIG_INVALID` | `flutter_patcher.yaml` 无效（未知字段、值的格式不对、`trust` 中没有有效的 `patch` 公钥）、CLI 参数无效，或没有设置 `HOME`/`USERPROFILE` | 按 `message` 修正配置或参数 |
| `USAGE_ERROR` | 命令用法错误，包括 1.1 中删除的命令和选项（`trust`、`publish --production`/`--request`、`keys import --rotate`、`keys init --role root\|publisher`） | 加 `--help` 查看正确用法；见 [CLI 参考：1.1 中删除的内容](cli-zh.md#11-中删除的内容) |
| `DOCTOR_FAILED` | `doctor` 遇到意外错误 | 查看 `message` |
| `INTERFACE_INPUT_MISSING`<br>`INTERFACE_GENERATION_FAILED`<br>`INTERFACE_INDEX_FAILED`<br>`INTERFACE_VALIDATION_FAILED`<br>`INTERFACE_NOT_CONVERGED`<br>`INTERFACE_NO_PROGRESS` | 维护者命令 `interface` 未能生成或校验宿主接口 | 只有适配新 Flutter 版本的维护者会运行它；查看 `message` |

### 2. 密钥与签名（`keys`、`patch`、`publish`、`serve`）

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `KEYS_NOT_CONFIGURED` | 在 `flutter_patcher.yaml` 没有 `trust.patch` 的项目中运行 `keys export` | 运行 `keys init`，或 `keys import` 项目的密钥包 |
| `KEYS_NOT_FOUND` | 签名宿主的文件必须签名，但没有任何来源提供私钥（`publish`、`serve`）；`--key-file` 或 `keys import` 指定的文件不存在；或 `keys export` 在本机密钥库中找不到密钥 | 运行 `keys import <文件>`、设置 `FLUTTER_PATCHER_KEYS` 或配置 `signing.command`；`keys status` 会显示本机有什么 |
| `KEYS_MISMATCH` | 第一个密钥来源中的密钥不是宿主的 `trust.patch`；`keys import` 的密钥不是 `flutter_patcher.yaml` 记录的那把；或已保存密钥的签名校验不通过 | 使用项目自己的密钥。宿主只接受构建时的那把密钥；换新密钥需要新的宿主 |
| `KEYS_ALREADY_CONFIGURED` | 项目已有补丁密钥，或项目中还有 `flutter_patcher_keys/` 目录时运行 `keys init` | 用 `keys import <密钥包>` 把现有密钥带到本机；旧目录用 `keys import flutter_patcher_keys` |
| `KEYS_BUNDLE_INVALID` | 文件不是密钥包、不含补丁密钥，或目录中没有 `patch/private-key.base64`；`~/.flutter_patcher/keys/` 中的文件损坏时也会报此错误（`message` 中给出文件名） | 使用 `keys export` 写出的文件，或含补丁密钥的 1.0 密钥包 |
| `SIGNER_COMMAND_FAILED` | `signing.command` 无法启动、以非 0 退出、超过 60 秒、没有输出 base64 编码的 64 字节签名，或用了另一把密钥签名 | 用相同的环境手动运行该命令；确认服务中的密钥是纯 Ed25519，且就是补丁密钥 |
| `PATCH_SIGN_FAILED` | 封装时签名自检失败 | 用 `keys status` 检查补丁私钥的来源 |
| `KEYS_OUTPUT_EXISTS`<br>`KEYS_OUTPUT_UNAVAILABLE` | 输出文件已存在，或无法创建密钥库目录 | 换一个新文件；检查 `~/.flutter_patcher/keys` 的权限 |
| `KEYS_PERMISSIONS_FAILED` | 无法限制私钥文件的权限 | 确认文件系统支持标准的权限属性 |
| `KEYS_IO_ERROR` | 读写密钥失败 | 检查目录权限后重试 |

### 3. 构建基线（`build`）

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `BUILD_CONFIG_INVALID` | 构建配置无效：`pubspec.yaml` 中没有 `+` 构建号、无法确定唯一的包名、`--host-policy` 文件无效（既不是 schema 2，也不是 1.0 的 schema 1 策略）、`--flavor` 或 `--version-code` 与该策略不一致，或输出目录已存在 | 按 `message` 补充或修正（例如 `version: 1.0.0+1`、`--application-id`、新的 `--out`） |
| `BUILD_PROJECT_INVALID` | 不支持的项目结构（例如源码包中有符号链接，或目录名与 `build` 仅大小写不同） | 按 `message` 调整项目结构 |
| `BUILD_BOOTSTRAP_UNAVAILABLE` | 项目没有依赖 `flutter_patcher` | 运行 `flutter pub add flutter_patcher` |
| `BUILD_INPUT_CHANGED` | 构建过程中源码被修改 | 构建期间不要修改文件，重新运行命令 |
| `BUILD_STEP_FAILED` | 底层 Flutter 构建步骤失败 | 查看 `message` 中的日志末尾和日志目录 |
| `BUILD_APK_INVALID`<br>`BUILD_IPA_INVALID`<br>`ENGINE_INJECTION_FAILED` | 生成的安装包校验失败，或引擎注入失败 | iOS 上检查代码签名和 `--export-method`；其他情况请提交 Issue |
| `BASELINE_RELEASE_CONFLICT` | 该构建号已存在内容不同的基线记录 | 参见上文 [常见问题：`BASELINE_RELEASE_CONFLICT`](#baseline_release_conflict拒绝重复构建同版本基线) |
| `BASELINE_CONTENT_CONFLICT` | 相同的源码输入产生了不一致的构建结果 | 请提交 Issue |
| `BUILD_FAILED` | 未预期的构建失败 | 查看 `message` |

### 4. 基线存储

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `BASELINE_NOT_FOUND` | 找不到目标版本的基线快照 | 参见上文 [常见问题：`BASELINE_NOT_FOUND`](#baseline_not_found找不到基线) |
| `BASELINE_STORE_UNREACHABLE` | 无法访问基线存储或鉴权失败 | 检查网络、凭据和 `s3:ListBucket` 权限（见上文） |
| `BASELINE_STORE_PROTOCOL` | 存储不支持“不存在才创建”的条件写入 | 见 [CLI 参考：存储要求](cli-zh.md#存储要求) |
| `BASELINE_INVALID` | 基线快照已损坏 | 从备份恢复该基线对象 |
| `BASELINE_FINGERPRINT_MISMATCH` | 基线指纹与请求的版本参数不一致 | 检查 `--version-code`、`--flavor` 和 Flutter SDK 版本 |
| `BASELINE_ARTIFACTS_MISSING`<br>`BASELINE_SCHEMA_UNSUPPORTED`<br>`BASELINE_NOT_RELEASE` | 基线由不兼容的旧版 `flutter_patcher` 生成 | 用当前版本的 `flutter_patcher` 重新构建并发布新的基线版本 |
| `BASELINE_RELEASE_AMBIGUOUS` | 同一版本的旧格式记录与当前的版本对象不一致 | 删除 `message` 中指明的那一个 |
| `BASELINE_OPERATION_FAILED` | 基线存储发生意外错误 | 查看 `message` |

### 5. 生成补丁（`patch`）

**安全检查拦截**（阻止不支持的改动被打进补丁）：

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `PATCH_NATIVE_CHANGE` | 原生代码、原生插件或构建钩子被修改，或新增了原生依赖。与构建宿主时不同的 flutter_patcher 版本也算在内 | 撤销原生改动或发布完整的新版本；用构建宿主时的 flutter_patcher 版本打补丁。（如果没有改过原生代码，请检查上文的 `CRLF` 换行问题） |
| `PATCH_PINNED_PACKAGE_CHANGED` | 一个被锁定在基线版本的依赖包（因为它包含原生代码或被原生代码依赖）版本变了 | 按 `message` 的提示，在 `dependency_overrides` 中把它固定回基线版本 |
| `PATCH_FFI_UNSUPPORTED` | 修改后的 Dart 代码通过 `dart:ffi` 调用原生函数 | 把 FFI 调用留在未修改的基线代码中，或发布完整的新版本 |
| `PATCH_UNSAFE` | 字节码兼容性校验失败 | 查看 `message` 中列出的具体问题和工作目录日志 |
| `PATCH_DYNAMIC_ICON` | 代码在运行时动态构造非 `const` 的 `IconData` | 改用编译期常量图标（`const IconData(...)` 或 `Icons.*`） |
| `PATCH_ASSET_DELETE_UNSUPPORTED` | 删除了安装包中已有的资源 | 恢复该资源文件，或发布完整的新版本 |
| `PATCH_ENGINE_UNSUPPORTED` | 基线安装包的引擎不支持资源补丁 | 用当前版本重新构建并发布新的基线版本 |
| `PATCH_NO_CHANGES` | 与基线相比没有有效改动 | 确认改动已保存，并且对比的是预期的基线版本 |

**补丁警告**（补丁生成成功，但请留意运行时行为）：

| 警告码 | 含义 |
|---|---|
| `PATCH_NATIVE_ASSET_READER` | 原生代码读取了本补丁修改过的资源；原生代码看到的仍是基线安装包中的原始资源 |
| `PATCH_BACKGROUND_ENTRY` | 某个入口函数运行在独立的 Flutter 引擎上（例如后台 isolate 任务），可能继续执行基线代码或资源 |
| `PATCH_RESOURCE_SIZE` | 补丁中的资源总计超过 16 MB，会在 App 进程的整个生命周期内常驻内存 |

**其他 `patch` 错误**：

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `PATCH_BASELINE_INCOMPATIBLE` | 宿主由 flutter_patcher 1.0 构建、使用了另一个 Flutter 版本，或缺少当前版本所需的记录；由 `publish` 报出时，是 flutter_patcher 1.0 的补丁输出 | 见上文常见问题中的 `PATCH_BASELINE_INCOMPATIBLE` |
| `PATCH_TARGET_MISMATCH` | 入口文件与构建基线时不同 | 使用构建时相同的 `--target` |
| `PATCH_DRAFT_INVALID` | `patch` 或 `publish` 在输出目录中找不到有效的 `patch.draft` | 传入当前版本 `patch` 的输出目录，或重新运行 `patch` |
| `PATCH_CONFIG_INVALID` | 选项无效，例如 flavor、构建号或 `--target`，或输出目录已存在 | 按 `message` 修正 |
| `PATCH_COMPILE_FAILED` | Dart 编译失败 | 先确认普通的 `flutter build` 能成功 |
| `PATCH_SOURCE_INVALID`<br>`PACKAGE_INPUT_INVALID` | 不支持的源码包结构（例如含符号链接） | 按 `message` 去掉符号链接或调整结构 |
| `PATCH_ASSET_INVALID`<br>`FONT_SUBSET_FAILED` | 资源处理或图标字体裁剪失败 | 按 `message` 修正有问题的资源或字体文件 |
| `PATCH_TOOL_FAILED` | 内部编译或对比工具失败 | 查看 `message` 中的工具输出和工作目录 |
| `PATCH_PACKAGE_INVALID` | 打包补丁失败 | 请提交 Issue |
| `PATCH_FAILED` | 未预期的补丁生成失败 | 查看 `message` |

### 6. 发布与本地服务（`publish`、`serve`）

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `PUBLISH_CONFIG_INVALID` | 没有可发布的补丁输出（`.dart_tool/flutter_patcher/patches/` 下没有，也没有 `--patch`）、多余的参数、`--receipt` 文件已存在，或 `store` 地址中带有凭据、查询参数或片段 | 先运行 `patch` 或传入 `--patch`；换一个新的回执文件；修正 `store` |
| `PUBLISH_SEQUENCE_CONFLICT` | 存储中该宿主文件的 `seq` 不小于新序号，或 `--seq` 不是 1–4294967295 之间的数字 | 见上文常见问题中的 `PUBLISH_SEQUENCE_CONFLICT` |
| `PUBLISH_CONFLICT` | 在 `publish` 读取之后、写入之前，存储中的文件被改动，例如有人同时在发布 | 重新运行 `publish` |
| `PUBLISH_STORE_UNAVAILABLE` | AWS CLI 不存在或执行失败、存储不支持条件写入，或角色缺少 `s3:ListBucket`（此时不存在的文件会被当作拒绝访问） | 检查 AWS CLI 版本、凭据、权限和 `FLUTTER_PATCHER_S3_ENDPOINT` |
| `PUBLISH_STORE_INVALID` | `s3://` 存储地址无效（S3 前缀必须位于存储桶根目录之下，且只含字母、数字、`_` 和 `-`）、存储中的文件超过 320 MiB，或 S3 响应中没有 ETag | 按 `message` 修正 `store`；替换过大的文件 |
| `PUBLISH_FAILED` | 未预期的发布失败，包括存储中与该宿主同名的文件不是 FPTC v1 文件 | 删除或替换存储中的那个文件；其他情况检查存储并查看 `message` |
| `SERVE_CONFIG_INVALID` | `serve` 只支持 `file://` 发布存储 | 本地开发时去掉 `flutter_patcher.yaml` 中的远端 `store` |
| `SERVE_PORT_BUSY` | 另一个程序占用了 `serve` 使用的端口 | 停止该程序，或运行 `serve --port <端口>`，并用 `adb reverse tcp:8686 tcp:<端口>` 把手机的 `8686` 映射过去 |

发布某个输出失败时 `serve` 不会退出：它打印 `Not offered: <错误码>: <说明>`（错误码为上表之一），并继续提供存储中已有的文件。

### 7. 警告

以下警告以 `WARNING: <代码>: <说明>` 的形式打印，不影响命令成功：

| 警告码 | 含义 |
|---|---|
| `UNSIGNED` | `build` 构建了不带补丁密钥的宿主：它接受不签名的文件，任何能把文件交给 App 的一方都能在 App 中执行代码。要开启签名，运行 `keys init` 后重新构建 |
| `URL_LOCAL` | `flutter_patcher.yaml` 中没有 `url`，不传 `url` 的 `checkUpdate()` 检查的是 `serve` 的本机地址。构建上架版本前请填写 `url`，除非 App 自己获取补丁文件 |
| `BASELINE_STORE_LOCAL` | `build` 只把基线保存在项目的 `.flutter_patcher/` 中。请备份这个文件夹，或配置 `baseline_store`；该宿主的每个补丁都需要它 |
| `CRLF_DART_SOURCES` | `build` 发现 Dart 源码使用 `CRLF` 换行；生成补丁时必须使用换行一致的检出（见上文） |
| `ARTIFACT_CHECK_SKIPPED` | 无法下载产物索引，使用了本机缓存的索引 |

---

## 仅 flutter_patcher 1.0

flutter_patcher 1.1 不会报出以下错误码。它们来自 flutter_patcher 1.0.0+1 为 1.0.0 宿主工作时，这类宿主使用签名清单、`catalog.json` 和信任更新。请继续用 1.0.0+1 处理这些宿主；1.1 不读取也不改动 1.0 留在存储中的内容（`manifests/`、`objects/`、`catalog.json`）和 `.dart_tool/flutter_patcher/publish-pending.json`。

| 错误码 | 含义 | 处理方法（使用 1.0.0+1） |
|---|---|---|
| `PUBLISH_BUSY`<br>`PUBLISH_COMMIT_UNKNOWN`<br>`PUBLISH_UPLOAD_FAILED`<br>`PUBLISH_DELETE_UNKNOWN` | 之前一次 1.0 的发布或清理被中断 | 在同一项目中用 1.0.0+1 再次运行 `publish`（或同一个请求文件），它会从 `publish-pending.json` 续上。不要手动删除存储中的文件 |
| `PUBLISH_URL_UNREACHABLE`<br>`PUBLISH_URL_INVALID` | 1.0 的 `publish` 无法读取 `url` 上该版本的清单，或读到的不是清单 | 修正 `url` 或网络；还没有发布过的版本，该地址必须返回 `404` |
| `PUBLISH_CATALOG_INVALID`<br>`PUBLISH_CATALOG_FULL` | `catalog.json` 损坏、属于另一个包名，或达到 8 MiB | 每个 App 使用专用的存储路径；不要手动修改存储；目录已满请提交 Issue |
| `PUBLISH_MANIFEST_CONFLICT` | 1.0 重写 `manifests/<哈希>.json` 时它一直在变化 | 重新运行 `publish` |
| `PUBLISH_RETENTION_STALE`<br>`PUBLISH_OBJECT_CHANGED` | 1.0 的清理计划已过期 | 重新预演，生成新的清理计划 |
| `PUBLISH_TARGET_MISMATCH` | 补丁不属于该版本 | 为该版本重新生成补丁 |
| `PUBLISH_PATCH_INVALID` | 补丁包损坏或超过 320 MB | 重新生成补丁，减少其中的资源 |
| `PUBLISH_SIGNATURE_INVALID` | 签名与基线的 patch 公钥或 `--root-public` 校验不通过 | 使用构建宿主时的那套密钥发布 |
| `TRUST_CONFIG_INVALID`<br>`TRUST_INVALID`<br>`TRUST_REPLAY`<br>`TRUST_SCOPE_CONFLICT`<br>`TRUST_CONFLICT`<br>`TRUST_OUTPUT_EXISTS`<br>`TRUST_FAILED` | 1.0 的 `trust sign` 或 `trust publish` 失败 | 按 `message` 处理；`TRUST_REPLAY` 需要把 `revision` 增加到大于已发布的值 |

---

## 客户端（设备端）排障

设备端不使用上述 CLI 错误码，可通过以下方式定位问题：

1. **安装失败**：`applyPatch`、`applyPatchBytes`、`applyPatchFile` 返回 `PatchApplyError`，各取值的含义以及文件需要满足的规则见 [API 参考](api-reference-zh.md)。`invalidArgs` 表示文件不比 `patchTarget.acceptedSeq` 新；`signatureInvalid` 表示它不是本构建的文件、已损坏，或不是宿主补丁密钥签名的。
2. **检测不到更新**：把文件的前 146 字节传给 `FlutterPatcher.inspectPatch`，查看 `reason`；另见上文关于 `checkUpdate` 的排查。
3. **冷启动后补丁未生效**：读取 `FlutterPatcher.lastBootDiagnostic` 查看运行时跳过或回滚补丁的原因，见[崩溃保护](crash-protection-zh.md)。
4. **开发期控制台日志**：真机调试时，可在 Android `logcat` 或 iOS Xcode Console 中过滤关键字 `FlutterPatcher`，查看原生校验与加载日志。
