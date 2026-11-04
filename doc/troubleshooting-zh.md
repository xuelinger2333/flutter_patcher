<!-- ========================================== -->
<!-- doc/troubleshooting-zh.md (简体中文)       -->
<!-- ========================================== -->

# 错误码与排障

[English](troubleshooting.md) | **简体中文**

CLI 执行失败时会在标准错误输出错误码 `code` 与原因说明 `message`：`build`、`patch`、`baseline` 输出一行 JSON，其他命令输出 `CODE: message`。例如：

```json
{"command":"patch","status":"failed","code":"PATCH_NATIVE_CHANGE","message":"Native plugin/build hook changed: camera"}
```

`message` 字段通常会直接指出具体原因。本文先列出高频排障场景，再按模块提供全量错误码速查表。客户端（设备端）的排障方式见文末。

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

### `PATCH_BASELINE_INCOMPATIBLE`：Flutter 版本不一致

生成补丁所使用的 Flutter SDK 版本必须与构建基线安装包时**完全一致**。请切换至对应版本的 Flutter，或通过 `--flutter-sdk` 指定路径。

### `BASELINE_STORE_UNREACHABLE`：存储明明可访问却报错

基线存储在查询不存在的对象时，必须返回 `404`（S3 对应 `NoSuchKey`）。在 AWS S3 或兼容存储中，若 IAM 角色缺少 `s3:ListBucket` 权限，访问不存在的对象会返回 `403 Forbidden`（部分 CDN 也有类似行为），从而触发此错误。请为凭据补充 `s3:ListBucket` 权限（报错信息中会指明具体受阻的对象名称）。

### `PUBLISH_BUSY` 或 `PUBLISH_COMMIT_UNKNOWN`：发布中断被锁定

上一次 `publish` 在提交阶段因断网或进程强杀而中断。为防止发布存储进入不一致状态，系统会自动锁定存储。**请勿手动删除存储中的任何文件**。在同一个项目中再次运行 `publish`（或 `serve`）即可：它会用保存在 `.dart_tool/flutter_patcher/publish-pending.json` 中的请求自动续上中断的发布，完成后存储才接受新的操作。如果用的是请求文件（`--production --request`），请再次运行同一个文件。

### `HOST_UNSUPPORTED`：当前主机不支持该操作

- **构建 Android 基线包（`build android`）**：需 Linux x64、Windows x64 或 Apple Silicon Mac。
- **构建 iOS 基线包（`build ios`）**：需 Apple Silicon Mac。
- **生成补丁（`patch android` / `patch ios`）**：以上三种主机均可运行。

### 客户端调用 `checkUpdate` 始终检测不到更新

- 检查传入的 URL 是否为发布存储的**根地址**（切勿直接传入 `manifests/` 下的具体文件路径）。
- 检查该 HTTPS 地址是否直接返回响应（客户端不支持 `3xx` 重定向）。
- 确认补丁是否确实针对当前设备安装的构建号（`versionCode`）生成；若用户已升级新版本 App，需为新版本单独生成并发布补丁。
- 确认该补丁是否已在当前设备上安装过（已安装的补丁不会重复触发更新，可通过 `currentVersion` 查看已安装的补丁版本）。

---

## 错误码速查表

### 1. 环境与工具链

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `FLUTTER_NOT_FOUND` | 系统 `PATH` 中找不到 Flutter | 将 Flutter 加入 `PATH`，或使用 `--flutter-sdk` 指定路径 |
| `FLUTTER_VERSION_INVALID` | 无法读取 Flutter 版本信息 | 运行 `flutter --version` 确认 SDK 完整性 |
| `SDK_NOT_READY` | 所选 Flutter SDK 未完成初始化或缓存残缺 | 先运行一次 `flutter doctor`，完成后重试 |
| `SDK_PREPARE_FAILED` | 准备内部 Flutter SDK 副本失败 | 检查网络连接与磁盘空间后重试；若持续失败请提交 Issue |
| `ENGINE_ARTIFACT_MISSING` | 当前 Flutter 版本无可用定制引擎或缺失文件 | 切换至[支持的 Flutter 版本](../README-zh.md#支持版本与环境) |
| `ENGINE_ARTIFACT_MISMATCH`<br>`ARTIFACT_HASH_MISMATCH`<br>`ARTIFACT_INVALID`<br>`ENGINE_MANIFEST_INVALID`<br>`TOOLS_ARTIFACT_MISSING`<br>`TOOLS_VERSION_UNSUPPORTED`<br>`YAML_CACHE_INVALID`<br>`YAML_GENERATION_FAILED`<br>`EMBEDDING_POM_UNAVAILABLE` | 下载的引擎或编译工具链残缺、哈希校验失败 | 检查网络后直接重试；损坏的本地缓存会被自动隔离并重新下载 |
| `CACHE_INVALID` | 命令用到的路径（缓存、项目、存储、密钥、补丁输出或回执文件）本身是符号链接，或经过符号链接 | 改用真实路径，不要经过符号链接 |
| `HOST_UNSUPPORTED` | 当前操作系统或 CPU 架构不支持该命令 | 参见上文 [常见问题：`HOST_UNSUPPORTED`](#host_unsupported当前主机不支持该操作) |
| `ANDROID_SDK_MISSING` | 找不到 Android SDK 或 `build-tools` | 设置环境变量 `ANDROID_HOME`，或运行 `flutter config --android-sdk` |
| `JAVA_HOME_INVALID` | `JAVA_HOME` 指向的目录中无有效 Java 环境 | 修正 `JAVA_HOME` 环境变量 |
| `XCODE_MISSING` | 未安装 Xcode 或缺失 iOS 平台组件 | 安装 Xcode，并在 Xcode 设置中下载 iOS 平台支持组件 |
| `DISK_FULL` | 磁盘剩余空间不足 | 清理磁盘空间后重试 |
| `TOOL_FAILED` | 内部调用的外部构建工具执行失败 | 查看 `message` 中附带的工具标准错误输出末尾日志 |
| `CONFIG_INVALID` | `flutter_patcher.yaml` 配置项或命令行参数无效 | 根据错误提示修正配置或参数 |
| `USAGE_ERROR` | 命令调用语法错误 | 添加 `--help` 查看正确用法 |
| `DOCTOR_FAILED` | `doctor` 检查遇到未预期异常 | 查看 `message` 详情 |

### 2. 密钥管理（`keys`）

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `KEYS_NOT_CONFIGURED` | `flutter_patcher.yaml` 中没有 `trust` 公钥 | 为项目运行一次 `keys init`，或用 `keys import` 导入它的密钥包 |
| `KEYS_NOT_FOUND` | 找不到 `publish` 或 `trust sign` 需要的私钥 | 运行 `keys import <文件>`、设置 `FLUTTER_PATCHER_KEYS` 或配置 `signing.command`；`keys status` 可查看本机有哪些私钥 |
| `KEYS_MISMATCH` | 私钥与 `flutter_patcher.yaml` 记录的不一致，或该版本是用另一套密钥构建的 | 使用项目原有的密钥。已有上线宿主的项目，切勿重新生成密钥 |
| `KEYS_ALREADY_CONFIGURED` | 在已有密钥的项目中运行了 `keys init` | 用 `keys import` 把已有密钥带到本机 |
| `KEYS_BUNDLE_INVALID` | 文件不是密钥包 | 使用 `keys export` 导出的文件 |
| `SIGNER_COMMAND_FAILED` | `signing.command` 执行失败、超时或没有输出有效签名 | 手动运行该命令排查；确认签名服务中的密钥是 Ed25519 |
| `KEYS_OUTPUT_EXISTS`<br>`KEYS_OUTPUT_UNAVAILABLE` | 输出文件已存在，或无法创建密钥库目录 | 换一个新文件；检查 `~/.flutter_patcher/keys` 的权限 |
| `KEYS_PERMISSIONS_FAILED` | 无法收紧私钥文件的文件系统访问权限 | 检查当前文件系统是否支持标准权限控制 |
| `KEYS_CRYPTO_FAILED`<br>`KEYS_IO_ERROR` | 密钥对生成或写入失败 | 检查目录读写权限后重试 |

### 3. 构建基线（`build`）

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `BUILD_CONFIG_INVALID` | 构建配置缺失或无效（如 `pubspec.yaml` 缺少 `+` 构建号、无法解析包名） | 按提示补全（例如 `version: 1.0.0+1` 或传入 `--application-id`） |
| `BUILD_PROJECT_INVALID` | 项目目录结构不受支持（如源码含符号链接，或存在与 `build` 仅大小写不同的同名目录） | 按提示调整项目目录结构 |
| `BUILD_BOOTSTRAP_UNAVAILABLE` | 项目尚未添加 `flutter_patcher` 依赖 | 运行 `flutter pub add flutter_patcher` |
| `BUILD_INPUT_CHANGED` | 构建过程中检测到源码文件被修改 | 构建期间请勿编辑项目文件，重新运行构建 |
| `BUILD_STEP_FAILED` | 底层 Flutter 编译步骤失败 | 查看 `message` 附带的末尾日志及日志目录路径 |
| `BUILD_APK_INVALID`<br>`BUILD_IPA_INVALID`<br>`ENGINE_INJECTION_FAILED` | 产出的安装包结构异常或引擎注入失败 | iOS 请检查签名配置与 `--export-method`；其他情况请提交 Issue |
| `BASELINE_RELEASE_CONFLICT` | 该构建号已存在内容不同的基线记录 | 参见上文 [常见问题：`BASELINE_RELEASE_CONFLICT`](#baseline_release_conflict拒绝重复构建同版本基线) |
| `BASELINE_CONTENT_CONFLICT` | 相同源码编译出了不一致的产物哈希 | 请提交 Issue |
| `BUILD_FAILED` | 未预期的构建异常 | 查看 `message` 详情 |

### 4. 基线存储

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `BASELINE_NOT_FOUND` | 找不到目标版本的基线快照 | 参见上文 [常见问题：`BASELINE_NOT_FOUND`](#baseline_not_found找不到基线) |
| `BASELINE_STORE_UNREACHABLE` | 无法连接或无权限访问基线存储 | 检查网络、凭据与 `s3:ListBucket` 权限，参见上文说明 |
| `BASELINE_STORE_PROTOCOL` | 存储服务端不支持“仅在对象不存在时写入”的原子语义 | 参见 [CLI 参考：存储要求](cli-zh.md#存储要求) |
| `BASELINE_INVALID` | 基线快照文件损坏 | 从备份中恢复基线存储文件 |
| `BASELINE_FINGERPRINT_MISMATCH` | 基线指纹与当前请求的版本参数不匹配 | 核对 `--version-code`、`--flavor` 及 Flutter SDK 版本 |
| `BASELINE_ARTIFACTS_MISSING`<br>`BASELINE_SCHEMA_UNSUPPORTED`<br>`BASELINE_NOT_RELEASE` | 基线由不兼容的旧版 `flutter_patcher` 生成 | 使用当前版本的 `flutter_patcher` 重新构建并发布新基线版本 |
| `BASELINE_RELEASE_AMBIGUOUS` | 同一版本的旧格式记录与当前格式的发布对象内容不一致 | 根据错误提示删除其中指明的一份 |
| `BASELINE_OPERATION_FAILED` | 基线读写遇到未预期错误 | 查看 `message` 详情 |

### 5. 生成补丁（`patch`）

**越界修改拦截错误码**（包含不支持热更的改动时直接阻断）：

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `PATCH_NATIVE_CHANGE` | 修改了原生代码、原生插件、构建脚本，或新增了原生依赖 | 撤销原生层改动，或直接发布新版本安装包（若未改原生代码，请排查上文提到的 `CRLF` 换行符问题） |
| `PATCH_PINNED_PACKAGE_CHANGED` | 包含原生能力（或被原生包依赖）的锁定包版本发生了变化 | 按错误提示在 `dependency_overrides` 中将其锁定回构建基线时的版本 |
| `PATCH_FFI_UNSUPPORTED` | 新增或修改的代码中包含了通过 `dart:ffi` 调用原生函数的逻辑 | 将 FFI 调用保留在未修改的基线代码中，或发布新版本安装包 |
| `PATCH_UNSAFE` | 字节码安全性与兼容性检查未通过 | 查看 `message` 列出的具体违规原因及工作目录日志 |
| `PATCH_DYNAMIC_ICON` | 代码中在运行时动态构造了非 `const` 的 `IconData` | 改为使用静态常量图标（`const IconData(...)` 或内置 `Icons.*`） |
| `PATCH_ASSET_DELETE_UNSUPPORTED` | 删除了基线中已有的 Asset 资源文件 | 恢复被删资源文件，或发布新版本安装包 |
| `PATCH_ENGINE_UNSUPPORTED` | 基线包搭载的旧版引擎不支持资源热更 | 重新构建并发布新版基线安装包 |
| `PATCH_NO_CHANGES` | 与基线相比未检测到任何有效变更 | 确认代码修改已保存，且对比的目标基线版本正确 |

**编译期警告**（补丁可正常生成，但需评估运行时影响）：

| 警告码 | 含义 |
|---|---|
| `PATCH_NATIVE_ASSET_READER` | 检测到原生代码直接读取了被热更修改的资源；原生层仍会读到安装包内自带的旧资源 |
| `PATCH_BACKGROUND_ENTRY` | 存在运行于独立 Flutter 引擎的入口函数（如后台 Isolate 任务），该入口可能会继续执行旧代码或读取旧资源 |
| `PATCH_RESOURCE_SIZE` | 补丁中包含的资源总大小超过 16 MB，这些资源在 App 进程存活期间会常驻内存 |

**其他 `patch` 错误码**：

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `PATCH_BASELINE_INCOMPATIBLE` | 当前 Flutter 版本与基线不一致，或基线由不兼容的旧版工具构建 | 参见上文 [常见问题：`PATCH_BASELINE_INCOMPATIBLE`](#patch_baseline_incompatibleflutter-版本不一致) |
| `PATCH_TARGET_MISMATCH` | 入口文件与构建基线时不一致 | 通过 `--target` 指定与构建基线时相同的入口文件 |
| `PATCH_DRAFT_INVALID` | 传给 `publish` 的目录中没有有效的 `patch.draft` | 传入当前版本 flutter_patcher 的 `patch` 输出 |
| `PATCH_CONFIG_INVALID` | 参数无效（如序号、flavor、指纹或 `--target`），或输出目录已存在 | 按提示修正 |
| `PATCH_COMPILE_FAILED` | Dart 代码编译失败 | 先运行标准 `flutter build` 确认代码本身无编译错误 |
| `PATCH_SOURCE_INVALID`<br>`PACKAGE_INPUT_INVALID` | 源码目录结构不受支持（如包含符号链接） | 按提示移除符号链接或调整结构 |
| `PATCH_ASSET_INVALID`<br>`FONT_SUBSET_FAILED` | 静态资源格式异常或字体子集化（Font Tree-shaking）失败 | 按提示检查并修复对应资源文件 |
| `PATCH_TOOL_FAILED` | 内部差分或编译工具执行失败 | 查看 `message` 中的错误输出与工作目录日志 |
| `PATCH_PACKAGE_INVALID`<br>`PATCH_SIGN_FAILED` | 补丁打包或签名过程失败 | 请提交 Issue |
| `PATCH_FAILED` | 未预期的补丁生成异常 | 查看 `message` 详情 |

### 6. 发布与本地调试（`publish`、`serve`）

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `PUBLISH_CONFIG_INVALID` | 参数或请求文件无效（如尚未生成可发布的补丁、无可撤回的补丁，或 `--through` 越界） | 先运行 `patch` 生成补丁，或按提示修正参数 |
| `PUBLISH_TARGET_MISMATCH` | 待发布的补丁与目标基线版本不匹配 | 重新为目标版本生成补丁 |
| `PUBLISH_SEQUENCE_CONFLICT`<br>`PUBLISH_CONFLICT` | 补丁比该版本已发布或已撤回的最新补丁更旧，或生成补丁的机器时钟超前；也可能是发布期间存储被并发修改 | 重新运行 `patch`（如果是时钟问题，先校准时钟），再执行 `publish` |
| `PUBLISH_BUSY`<br>`PUBLISH_COMMIT_UNKNOWN`<br>`PUBLISH_UPLOAD_FAILED`<br>`PUBLISH_DELETE_UNKNOWN` | 上一次发布或清理操作异常中断 | 在同一个项目中再次运行 `publish`，或再次运行同一个请求文件，即可恢复，参见上文说明 |
| `PUBLISH_STORE_UNAVAILABLE` | 无法访问发布存储，或存储端不支持条件写入 | 检查 AWS CLI 版本、访问凭据及 `FLUTTER_PATCHER_S3_ENDPOINT` 环境变量 |
| `PUBLISH_STORE_INVALID` | 存储地址无效（S3 前缀必须位于存储桶根目录之下，且只能包含字母、数字、`_` 和 `-`），或对象超出大小限制 | 按提示修正 `store` 配置 |
| `PUBLISH_CATALOG_INVALID` | 存储中的 `catalog.json` 已损坏，或属于另一个 App | 确保每个 App 独占独立的发布存储路径，切勿手动修改存储桶内的文件 |
| `PUBLISH_MANIFEST_CONFLICT` | `publish` 改写 `manifests/<哈希>.json` 期间该文件不断变化 | 再次运行 `publish` 改写它 |
| `PUBLISH_CATALOG_FULL` | 发布历史记录（`catalog.json`）达到 8 MiB 的容量上限 | 清理不会缩小它，当前版本也无法归档；请提交 Issue |
| `PUBLISH_PATCH_INVALID` | 补丁文件损坏或体积超限（上限为 320 MB） | 缩减资源体积并重新生成补丁 |
| `PATCH_SIGN_FAILED` | 补丁签名未通过自检 | 用 `keys status` 检查 patch 私钥的来源 |
| `PUBLISH_SIGNATURE_INVALID` | 签名校验失败：`publish` 时补丁与基线中的 `patch` 公钥不匹配，`trust publish` 时信任文件与 `--root-public` 不匹配 | 用构建宿主时的那套密钥发布，或检查 `root` 密钥 |
| `PUBLISH_RETENTION_STALE`<br>`PUBLISH_OBJECT_CHANGED` | 预生成的清理计划（Cleanup Plan）已过期 | 重新执行 Dry Run 生成最新的清理计划 |
| `PUBLISH_FAILED` | 未预期的发布异常 | 查看 `message` 详情 |
| `SERVE_CONFIG_INVALID` | `serve` 仅支持本地文件存储（`file://`） | 本地联调时请先注释掉 `flutter_patcher.yaml` 中的远端 `store` 配置 |

### 7. 信任列表更新（`trust`）

| 错误码 | 含义 | 处理方法 |
|---|---|---|
| `TRUST_CONFIG_INVALID` | 缺少必填命令参数 | 按提示补全参数 |
| `TRUST_INVALID` | 信任文件的大小、字段或规范格式无效 | 用 `trust sign` 重新签名，不要手动修改 |
| `TRUST_REPLAY` | `revision` 版本号未递增 | 将 `fields.json` 中的 `revision` 调大（必须大于历史已发布值） |
| `TRUST_SCOPE_CONFLICT` | 目标存储路径下已存放了另一个基线版本的信任文件 | 为每个基线版本（Scope）分配独立的信任文件存储路径 |
| `TRUST_CONFLICT` | 信任存储发生并发写入冲突 | 重新拉取最新状态后再执行发布 |
| `TRUST_OUTPUT_EXISTS` | 本地输出文件已存在 | 指定新的 `--out` 文件名 |
| `TRUST_FAILED` | 未预期的信任操作异常，包括 `fields.json` 格式错误 | 检查 `fields.json` 与密钥文件后重试 |

### 8. 其他警告

以下警告以 `WARNING: <代码>: <说明>` 的形式打印，不影响命令成功：

| 警告码 | 含义 |
|---|---|
| `BASELINE_STORE_LOCAL` | `build` 只把基线保存在项目目录中；请把 `baseline_store` 配置到持久存储（见[生产部署](production-playbook-zh.md#配置存储)） |
| `CRLF_DART_SOURCES` | `build` 发现 Dart 源码使用 `CRLF` 换行；生成补丁时必须使用换行一致的检出（见上文） |
| `ARTIFACT_CHECK_SKIPPED` | 无法下载产物索引，使用了本机缓存的索引 |

---

## 客户端（设备端）排障

客户端 SDK 运行时不复用上述 CLI 错误码，可通过以下三处定位问题：

1. **安装阶段失败**：`applyPatch` 返回 `PatchApplyError` 枚举，具体各枚举值的含义与处理方式见 [API 参考：`applyPatch`](api-reference-zh.md#applypatch)。
2. **冷启动后补丁未生效**：读取 `FlutterPatcher.lastBootDiagnostic` 查看启动加载状态或回滚原因，字段说明见[崩溃保护：启动诊断](crash-protection-zh.md#启动诊断)。
3. **开发期控制台日志**：真机调试时，可在 Android `logcat` 或 iOS Xcode Console 中过滤关键字 `FlutterPatcher`，查看底层引擎输出的详细加载与验签日志。

