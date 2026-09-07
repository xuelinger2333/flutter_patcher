# flutter_patcher_cli · WP-2

本包负责为当前 Flutter 版本准备补丁工具链。运行时插件仍在仓库根目录；CLI 是独立 Dart 包，不依赖 `package:kernel`，不改变插件依赖。当前实现 `doctor`；`build`、`patch`、`publish`、`keys` 明确返回未实现。

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

## 验证

```bash
dart analyze
dart test
```

测试使用本地 HTTP 和合成二进制，覆盖 manifest 错配、校验失败、下载中断、缓存恢复、支持表刷新、YAML 输入变化和命令错误。真实 Release/SDK 验收见 [WP2-acceptance.md](docs/WP2-acceptance.md)。
