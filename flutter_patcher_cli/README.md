# flutter_patcher_cli · WP-2 / WP-3

本包负责为当前 Flutter 版本准备补丁工具链和新宿主的动态接口。运行时插件仍在仓库根目录；CLI 是独立 Dart 包，不依赖 `package:kernel`，不改变插件依赖。当前实现 `doctor` 和高级接口准备命令 `interface`；`build`、`patch`、`publish`、`keys` 明确返回未实现。

M1 支持 Linux x64（含 x64 WSL2），目标 Android arm64。需要已初始化的 stock Flutter SDK、Git 和首次下载所需的网络。原生 Windows/macOS 会明确报错；不支持的 Flutter 版本不会转入自行编译流程。

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

## 自动准备的内容

1. 读取 `flutter --version --machine`，核对 SDK 的缓存状态、Flutter/Dart/engine 身份和 artifacts 仓库唯一支持表。
2. 从 `flutter_patcher_artifacts` 的 `flutter-<version>` Release 获取两份 manifest、引擎 jar、Linux gen_snapshot、embedding jar 和单个工具 dill。检查 schema、版本、角色、大小、SHA-256、二进制架构及 jar 内部 SO。两条独立流水线允许不同 builder commit。
3. clone 精确匹配的 Flutter framework commit 到平行 SDK，先执行 stock `precache --android`，再替换该副本的 gen_snapshot，并准备含 jar/POM 的本地 Maven 镜像。APK 构建如何接入镜像属于 WP-5。
4. 调用 CI 编好的 dill，检查工具入口和 `bytecode` 子命令；用所选 SDK 的 Flutter 源码编译一个隔离的探针 kernel，生成协议和平台私有 YAML。这里编译的是探针，工具 dill 始终直接下载。
5. 用匹配的 frontend 和下载的 gen_snapshot 实际编译最小 arm64 AOT ELF，验证编译器链可调用。

默认缓存：

```text
~/.flutter_patcher/
  support/                           支持表（按来源隔离）
  artifacts/<version>/{engine,tools}/ 已校验的 Release 附件
  flutter/<version>/                 平行 SDK
  mirrors/<version>/<build_id>/      本地 Maven 文件布局
  yaml/<version>/<input-hash>/       YAML、输入/输出哈希及隔离探针
  pub-cache/                         隔离 Dart 包缓存
  verification/                      最小 AOT 冒烟结果
  doctor.lock                        进程间互斥锁
```

`--cache-dir` 只允许位于 `~/.flutter_patcher/` 或当前目录的 `.dart_tool/flutter_patcher/` 下。下载先写临时路径，全部验证后才进入可复用缓存；损坏缓存保留为 `.invalid-*` 后重新获取。未完成的 `.pending-*` 不会被当作成功产物。正常复用不下载；缓存支持表不含新版本时，在线刷新一次。离线缺失或损坏产物会失败。

YAML 缓存键包含版本、engine/framework commit、所用 Flutter 源文件、pubspec、平台 dill、frontend 和工具 dill 的哈希。输入变化换缓存；缺失或损坏 YAML 自动重生成，离线生成还要求探针依赖已缓存。不会编辑所选 Flutter SDK 或用户项目源码。过期 SDK 在启动 Flutter 前被拒绝，以避免触发 Flutter 自身更新。

## doctor 的边界

退出码：`0` 工具链及显式提供的检查通过；`1` 诊断失败；`2` 参数错误或未实现命令。JSON 中 `status: toolchain_ready` 仅表示 WP-2 工具链就绪。缺少项目上下文会显示 `not_run`；`all_checks_complete` 保持 `false`，不代表完整 M1/A1 已验收。

| 可选参数 | 本阶段实际检查 |
|---|---|
| `--public-key`、`--private-key` | 两文件存在且非空，不验证密码学格式或签名 |
| `--baseline-store` | `file://` 目录可读，或 HTTPS HEAD 成功；不实现归档读写 |
| `--baseline` | 解包目录中四个必需文件存在；完整基线身份校验留给 WP-4 |
| `--version-code`、`--flavor` 与 file store | 对应侧车存在且含合法指纹字段；不宣称已验证内容绑定 |
| `--apk` | ZIP 内 `lib/arm64-v8a/libflutter.so` 大小/哈希匹配 manifest；不安装或运行 APK |

`--artifacts-url`、`--supported-versions-url` 是维护/测试用覆盖项，普通用户只需选择 Flutter SDK。下载允许 HTTPS，HTTP 仅允许 loopback 测试服务。错误报告不会提供自行编译引擎的路径。

## WP-3 接口准备

这是后续 build/patch 管线的接口准备能力和维护入口，不修改已发布基线。
需要含 WP-3 子命令的 CI 工具 dill；当前公开 WP-2 工具缺少这些命令时会明确报错。
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

测试使用本地 HTTP 和合成二进制，覆盖 manifest 错配、校验失败、下载中断、缓存恢复、支持表刷新、YAML 输入变化和命令错误。真实 Release/SDK 验收见 [WP2-acceptance.md](docs/WP2-acceptance.md)。
