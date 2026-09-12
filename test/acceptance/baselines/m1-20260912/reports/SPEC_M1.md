# flutter_patcher v2 · M1 实现规范（rev3）

| | |
|---|---|
| 文档类型 | 实现规范（可直接开工的工作分解与接口契约） |
| 里程碑 | M1 · Android 字节码闭环 |
| 前置 | [`实现计划.md`](plan/实现计划.md)（设计与依据）、[`补丁包规范.md`](plan/补丁包规范.md)（格式契约） |
| 状态 | 新 artifacts 精简 Release 已构建发布（用户本次明确授权）；WP-2 本地实现待审；其他工作包未实施 |
| 最后更新 | 2026-09-08（rev3，WP-2 实现及验收边界澄清） |

**本文不重复设计依据，也不重复补丁包格式。** 设计为什么这样定看实现计划的编号（`R-*` 调研结论、`D-*` 决策、`C-*` 组件）；字节布局和一致性检查表看补丁包规范。本文只写"要写哪些代码、接口长什么样、怎么算做完"。


### WP-2 实施补充（2026-09-08）

- 本文件恢复为此前已经审核的 rev3 内容；恢复前的 rev2 工作副本保留于本地忽略目录 `.dart_tool/flutter_patcher/wp2/SPEC-before-WP2.md`。§11 的旧仓库和旧 Release 记录仅为历史。
- 按后续确认的实际布局，现有插件保持仓库根目录 `lib/`、`android/`、`pubspec.yaml`；只新增独立 `flutter_patcher_cli/`，不移动插件，也不修改插件依赖。§3.1 的运行时代码增量属于后续工作包。
- 用户本次明确批准 artifacts 仓库构建并发布精简 Release；这不授权推送 flutter_patcher 的任何分支、tag 或 Release。
- WP-2 的项目上下文检查与工具链验收分开，详见下文；没有 A1 真机闭环时不得声称完整 M1/A10 已通过。

## rev3 相对 rev2 的变更

修订基准：用户确认使用本地 `plan/SPEC_M1.md`，并批准同步受新决策影响的其他章节引用。仅对齐仓库路径、产物与发布约定；§11 保留历史构建事实，不作为当前目录或发布契约。

| # | 变更 | 影响章节 |
|---|---|---|
| 1 | 代码仓库仅插件/CLI；版本绑定源码统一迁入 flutter_patcher_artifacts | §1.3、§3.2 |
| 2 | 按用户 Flutter 版本解析单一支持表；不支持即报错，无用户编译兜底 | §1.3、WP-2 |
| 3 | 同一 flutter-<version> Release，独立 engine.manifest.json/tools.manifest.json | §4.6、WP-1、WP-1b |
| 4 | CI 编译一个工具 dill；bytecode 参数透传；两个生成器编进 dill，YAML 用户侧生成缓存 | §4.5、WP-1b、WP-2 |
| 5 | 引擎/工具 workflow 独立，publish 默认 false；只附加到用户预建 Release | WP-1、WP-1b |
| 6 | agent 禁止 push、tag、release，远端写操作由用户执行 | §9 第 0 条 |
| 7 | 经用户审核批准，同步旧路径、双 dill、发布 YAML 和旧 tag 引用；保留历史验收原文 | A9–A11、§0.2、§1.2、§2.2、§3.1、§4.4、WP-3、§7、§8、附录 |

M1.5 仅迁移已实现的 detect-shape、transform-overlay；其余四个分析命令按用户确认留给后续工作包。本规范列的是完整 M1 契约，不等于全部已实现。

## 历史：rev2 相对 2026-09-05 版的变更（已由 rev3 决策取代）

| # | 变更 | 影响章节 |
|---|---|---|
| 1 | 仓库拆成两个：`flutter_patcher`（插件 + CLI + kernel_tools）与 `flutter_patcher_engine`（引擎流水线）。旧版第 3 节与 WP-1 对仓库归属描述不一致，已统一 | §1.3、§3、WP-1 |
| 2 | 引擎产物与工具产物分成两条流水线、两份 manifest。kernel-tools dill、dart2bytecode dill、两份 yaml 不再随引擎构建发布 | WP-1、WP-1b、§4.6 |
| 3 | WP-1 补齐执行环境、depot_tools 固定、触发方式、tag 命名、首次构建量测任务 | WP-1 |
| 4 | M1 只交付 Linux 主机的 gen_snapshot；Windows/macOS 主机 gen_snapshot 明确移出 M1 | §0.2、WP-1 |
| 5 | 验收标准"sha256 逐字节相同"改为"manifest 可复现、产物以 manifest 哈希为准" | §0.1、WP-1 |
| 6 | 新增 agent 执行约定 | §9 |
| 7 | 新增错误码 `TOOLS_ARTIFACT_MISSING`、`ENGINE_MANIFEST_INVALID` | §6 |
| 8 | 工期估算按 rev2 调整；第 1 周内容改写 | §2.2、§8 |

---

## 0. M1 的定义与验收

**一句话**：Android 上，用 v2 工具链构建一个 release，把基线归档到仓库，**换一台机器**只凭指纹打出字节码补丁，推到设备冷启动生效；坏补丁两次冷启动内自愈。

M1 期间"机器"指 Linux 主机（含 WSL2）。见 §0.2。

### 0.1 验收清单（Definition of Done）

| # | 验收项 | 怎么验 |
|---|---|---|
| A1 | 端到端全流程跑通 | `build → 归档基线 → 换机 patch → publish 到 mock 服务 → 设备下载 → 重启生效 → 撤回 → 重启回退` |
| A2 | 故障样本库全部被校验层拦下 | 按补丁包规范四逐行生成，每行 ≥1 样本，CI 在真机/模拟器跑，**无 SIGABRT、应用存活** |
| A3 | 指纹不匹配的补丁拒绝加载 | 故障样本的一类 |
| A4 | 四道升档判定一次报全、都带源码位置 | 构造一个同时触发接口面/分配/继承面/资源形状的补丁，断言一次输出四类 |
| A5 | 宿主未保留的生成式构造引用在 `patch` 阶段报出；factory 按当前补丁引擎语义处理 | 用真实 generative/const/super/tear-off 用例验证类标识与源码位置；`Uint8List.fromList` 的 factory 引用不再作为 allocation 失败样本，仍须通过接口检查 |
| A6 | 资源覆盖层两档都生效 | 精简档走注入，整程序档走编译期替换 |
| A7 | 带自定义 binding 的应用装上引导后行为不变 | G2 的形状 3 |
| A8 | 基线未归档的 release 在 `build` 阶段失败 | 断开 store 后 `build` 必须非零退出 |
| A9 | `.so` 模式行为与 v1 完全一致 | 现有 `flutter_patcher/test/` 全绿 + 例程回归 |
| A10 | 引擎流水线可复现 | 同一 Flutter 版本、同一 `flutter_patcher_artifacts` commit 跑两次，两次 `engine.manifest.json` 除 `build_id`、`built_at`、各文件 `sha256` 外字段全等；两次产物都能通过 `doctor` 成对性检查并在真机上跑通 A1 |
| A11 | 工具流水线可复现 | 同一输入及源码/依赖路径下，两次产出的合并工具 dill 的 sha256 相同，tools.manifest.json 一致；不把用户侧缓存 YAML 作为发布产物验收 |

### 0.2 不在 M1 范围内

- iOS 任何部分（M3）
- **Windows 与 macOS 主机的 gen_snapshot**。它们必须分别在 Windows 与 Mac 机器上编，不能交叉编译。M1 的 `build` 只在 Linux 主机上可用；Windows 主机支持是 M1 之后、M2 之前的独立事项（另行规划，不属于本次 M1.5 整理阶段），届时只需在 `flutter_patcher_artifacts` 增加一个 Windows runner 与一条矩阵项，CLI 侧无改动
- `armeabi-v7a`、`x86_64` ABI（M1 只做 `arm64-v8a`，流水线以矩阵参数预留）
- `publish` 的服务端清单扩展与撤回流程（M2）；manifest 签名（M2，与补丁签名同批）
- 基线仓库的 `(flavor, versionCode, abi)` 索引与保留策略（M2）
- `.so` 路线接入基线仓库（M2 可选）
- 反向依赖闭包、跨版本自动学习（M5）

---

## 1. 需要先定的几件事

### 1.1 CLI 必须是独立包（D-21，已回写）

`flutter_patcher` 是 Flutter 插件包，它的 `dependencies` 会传染给每个使用它的 app。CLI 要依赖 `yaml`、`pointycastle` 一类重依赖，放进插件 pubspec 会让所有用户的 app 多背这些包。

```
flutter_patcher/            插件（运行时）。依赖保持现状，只加必要的
flutter_patcher_cli/        命令行。dart pub global activate flutter_patcher_cli
```

`bin/pack.dart`、`bin/mock_server.dart` 保留在插件包内不动（v1 用户仍在用 `dart run flutter_patcher:pack`），新 CLI 一律进 `flutter_patcher_cli`。

### 1.2 kernel 分析按 Flutter 版本发 kernel 快照（D-22，已回写）

`package:kernel` 的二进制格式与 SDK 版本绑定。CLI 要同时支持多个 Flutter 稳定版，就要同时用多个不兼容的 `kernel` 版本，一个 Dart 进程里做不到。

**决定**：全部 kernel 分析打成**按 Flutter 版本发布的 kernel 快照**，由我们的 CI 编译，用用户自己的同版本 `dart` 跑；分析命令、打过补丁的 dart2bytecode 和两个生成器合并到同一个 dill（D-5、§4.5）。

```
flutter_patcher_tools-<flutterVersion>.dill
  子命令：extract-surface | check-allocations | check-inherited
          detect-shape | transform-overlay | verify-structure
          bytecode | gen-protocol-interface | gen-platform-privates
```

CLI 通过子进程调用它；分析命令用 JSON 交换结果，bytecode 保留编译器参数、输出和退出语义，生成器将 YAML 写入用户缓存。**CLI 本体不依赖 `package:kernel`。**

### 1.3 两个仓库、两条独立流水线（rev3）

用户只需要知道自己的 Flutter 版本。CLI 从 `flutter --version --machine` 读取 `frameworkVersion`，按唯一支持表自动推导产物；不支持就明确报错退出，不提供用户自行编引擎或工具 dill 的路径。

| 仓库 | 内容 | Release tag |
|---|---|---|
| `flutter_patcher` | `flutter_patcher/` 插件、`flutter_patcher_cli/` 命令行与根文档 | 按插件/CLI 版本 `v2.x.y`，与 Flutter 版本无关 |
| `flutter_patcher_artifacts` | 引擎补丁/构建、kernel_tools、生成器、Dart 编译器补丁、唯一 supported_versions.txt | `flutter-<frameworkVersion>`，每个 Flutter 版本一个 Release |

引擎 workflow 在 self-hosted Linux 构建，工具 workflow 在 GitHub 托管 runner 构建；二者互不依赖，各自上传自己的文件和 manifest 到同一预建 Release。用户不参与工具编译。YAML 由 CLI 调用 CI 已编好的 dill，在用户自己的 Flutter SDK 输入上生成并缓存到 `~/.flutter_patcher/`。

发布清单为三个主要文件、一个暂保留的 embedding 透传和两份 manifest；详见 §4.6。embedding 是否可由 Google Maven 解析，留待 WP-5 实测后决定去留。


---

## 2. 工作分解

### 2.1 工作包与依赖

```
WP-1  引擎流水线 ──────┬───────────────────────────────┐
WP-1b 工具流水线 ──────┤                               │
                       │                               │
WP-2  CLI 骨架 ────────┼─→ WP-5 build 管线 ─→ WP-6 patch 管线 ─→ WP-9 故障样本与 CI
                       │        ↑                 ↑   ↑
WP-3  接口生成 ────────┘        │                 │   │
WP-4  基线仓库 ─────────────────┘─────────────────┘   │
WP-7  资源与字体 ─────────────────────────────────────┘
WP-8  运行时引导 ─────────────────────────────────────┘
```

WP-1/1b/2/3/4/8 可并行起步；WP-5 依赖 1+1b+2+3+4；WP-6 依赖 5+7；WP-9 最后收口。

### 2.2 工作包清单

| WP | 名称 | 产物 | 预估 |
|---|---|---|---|
| WP-1 | 引擎流水线 | `flutter_patcher_artifacts` 的引擎三个文件与 engine.manifest.json，附加到预建 `flutter-<ver>` Release（Linux 主机、arm64） | 5 天（含首次量测与 runner 搭建；实际以量测为准） |
| WP-1b | 工具流水线 | 同一预建 `flutter-<ver>` Release：一个合并工具 dill 与 tools.manifest.json | 2 天 |
| WP-2 | CLI 骨架与配置 | `flutter_patcher_cli` 包、平行 SDK 管理、`doctor` | 2 天 |
| WP-3 | 接口生成 | kernel-tools 的 `extract-surface`、协议集合、合并器 | 3 天 |
| WP-4 | 基线仓库 | 归档、寻址、侧车、本地缓存 | 2 天 |
| WP-5 | `build` 管线 | 引擎注入、引导入口生成、基线产出 | 3 天 |
| WP-6 | `patch` 管线 | 四道判定、两档编译、打包封装 | 4 天 |
| WP-7 | 资源与字体 | 形状检测、覆盖层变换、字体子集 | 3 天 |
| WP-8 | 运行时引导 | `PatchBootstrap`、原生 `bootPayload`、校验层 | 4 天 |
| WP-9 | 故障样本与 CI | 样本生成器、CI 真机跑批 | 2 天 |

合计约 30 人天，按全职计。§8 的周排期是全职假设，兼职按比例拉长。

---

## 3. 代码结构

### 3.1 `flutter_patcher` 仓库

```
flutter_patcher/                          插件包（现有）
  lib/
    flutter_patcher.dart                  ← 增量：baselineFingerprint
    src/
      patch_info.dart                     ← 增量：新字段进 toJson
      patcher_channel.dart                ← 增量：bootPayload
      bootstrap/
        patch_bootstrap.dart              新：PatchBootstrap.run
        raw_channel.dart                  新：不建 binding 的平台消息
        envelope.dart                     新：封装头解析与校验
        patch_archive.dart                新：STORED zip 只读解析
        patch_entry.dart                  新：入口元组校验
        overlay.dart                      新：patcherOverlayBundle / install
  android/src/main/kotlin/.../
    FlutterPatcherPlugin.kt               ← 增量：bootPayload
    BootPayload.kt                        新：解析待生效补丁并汇总状态

flutter_patcher_cli/                      新包
  bin/flutter_patcher.dart                多命令入口
  lib/src/
    commands/{build,patch,publish,keys,doctor}.dart
    sdk/parallel_sdk.dart                 平行 SDK 副本与两个文件替换
    sdk/engine_mirror.dart                Maven 镜像与 FLUTTER_STORAGE_BASE_URL
    sdk/artifacts.dart                    两份 manifest 的解析、下载、缓存、校验
    sdk/kernel_tools.dart                 kernel 快照子进程封装
    baseline/{store,fingerprint,sidecar}.dart
    iface/{merge,protocol_set,common_widgets}.dart
    pack/{archive,envelope,font_subset}.dart
    tier/decision.dart                    四道判定的汇总与报告
    diag/{codes,report}.dart

.github/workflows/
  test.yml                                插件/CLI 单测；工具测试在 artifacts 仓库
```

### 3.2 两个仓库的目标目录树

```text
flutter_patcher/
  flutter_patcher/                    插件
  flutter_patcher_cli/                CLI；M1.5 仅保留目录，尚未实现
  .github/workflows/test.yml
  docs/                              本地整理盘点与报告
  README*.md、CHANGELOG*.md 等根文档
  _to_artifacts/                     仅为迁移保留，待用户确认删除

flutter_patcher_artifacts/
  engine_patches/
  engine/
    scripts/
      resolve_engine.sh
      fetch_engine.sh
      build_android.sh
      package.sh
      verify_pair.sh
      build.sh、common.sh 等现有辅助脚本
    fixtures/pair/
    README.md                        环境要求与量测，未测填 TBD
  tools/
    kernel_tools/
      bin/main.dart                  单 dill 入口
      lib/
      test/fixtures/shapes/
    generators/
      gen_platform_privates.dart
      protocol_set/
    dart2bytecode_patches/
    release/
    locks/
    versions.json
    README.md
  supported_versions.txt
  DEPOT_TOOLS_REV
  .github/workflows/
    build-engine.yml
    build-tools.yml
    check-new-stable.yml
    test.yml
```

历史证据保留在 artifacts 的 `engine/measurements/`、`_legacy/`，不作为新版发布附件。

原型到产品的对应：

| 原型 | 去处 |
|---|---|
| `temp/extract_referenced_surface.dart` | `flutter_patcher_artifacts/tools/kernel_tools` `extract-surface` |
| `temp/e2_resolve_hints.dart` | `flutter_patcher_cli` 的定点迭代循环 |
| `temp/allocated_classes.dart` | `flutter_patcher_cli` 的 trace 解析（不需要 kernel） |
| `temp/check_allocations.dart` | `flutter_patcher_artifacts/tools/kernel_tools` `check-allocations` |
| `temp/f6/f6_detect.dart` | `flutter_patcher_artifacts/tools/kernel_tools` `detect-shape` |
| `temp/f6/f6_transform.dart` | `flutter_patcher_artifacts/tools/kernel_tools` `transform-overlay` |
| `temp/gen_platform_privates.dart` | `flutter_patcher_artifacts/tools/generators/`，由 WP-1b 调用 |
| 服务器上手工编引擎的命令 | `flutter_patcher_artifacts/engine/scripts/*.sh` |


---

## 4. 接口契约

### 4.1 Dart 公开 API 增量

只加两处，其余签名不动（D-20）：

```dart
class FlutterPatcher {
  /// 本次构建绑定的基线指纹（小写 hex，64 字符）。字节码模式下由构建期
  /// 烧入；.so 模式返回 null。供上报与服务端下发前核对。
  static String? get baselineFingerprint;
}

class PatchBootstrap {
  /// 生成的入口调用。加载补丁模块（或决定不加载），随后调用 [original]。
  /// 绝不调用 FlutterPatcher.init —— 见实现计划 5.5（三）。
  static Future<void> run({required Future<void> Function() original});
}
```

**`loaderFieldCandidates` / `loaderFallbackHeuristic` 在字节码模式下失效**，签名不动，dartdoc 写明。

### 4.2 `PatchInfo` 增量

`toJson()` 是写死的字段列表，新字段必须显式加进去，否则到不了原生（实现计划 5.5（二））：

```dart
/// 字节码载荷地址。v1 客户端不读这个字段，因此 patchUrl 必须永远保持
/// v1 语义，指向一个 v1 能装的载荷。
final String? bytecodeUrl;
final String? bytecodeMd5;
/// 装得下这个补丁的最低插件版本。v2 客户端自己跳过。
final String? minPluginVersion;
/// 'so' | 'bytecode'
final String? strategy;
/// 基线指纹，客户端与烧入值比对后才下载。
final String? fingerprint;
```

### 4.3 原生新增方法：`bootPayload`

`FlutterPatcherPlugin` 增加一个方法，Dart 侧在 binding 建立前用裸平台消息调用。

**入参**：无。

**返回**（`Map<String, Object?>`，缺省值即"没有可用补丁"）：

```
{
  "path":          String?  // 待生效补丁的绝对路径，无则 null
  "seq":           int      // 补丁序号，无则 0
  "fingerprint":   String?  // 落盘时记录的指纹，供 Dart 侧提前比对
  "crashCount":    int      // 当前崩溃回路计数
  "pendingMarker": bool     // 上次启动写了「尝试加载」且未清除
  "blacklisted":   bool     // 该补丁在本地黑名单里
  "reason":        String?  // 上面任一为真时的机器可读原因
}
```

**约束**：

- 必须返回**已经过 md5、签名、versionCode、黑名单、崩溃回路**那套现有闸门的补丁路径。Dart 侧仍按补丁包规范二重验封装，指纹常量只有 Dart 侧有。
- 路径来自 `PatchManager` 的 `filesDir/<PATCH_DIR>`。**不要复用 `cacheDir`**，那个返回的是 `context.cacheDir`，是 `applyPatchBytes` 的 staging 目录。
- 处理器必须同步完成（读几个文件），不要在里面做 IO 等待。

### 4.4 CLI 命令

```
flutter_patcher build android
    [--flavor <f>] [--baseline-store <uri>] [--strategy so|bytecode]
    [--engine-artifacts <uri>] [--tools-artifacts <uri>] [--verbose]

flutter_patcher patch android
    --fingerprint <hex> | --baseline <dir>
    [--strategy so|bytecode] [--seq <n>] [--baseline-store <uri>]
    [--assets <key>[,<key>...]] [--out <dir>] [--force-tier lean|whole]

flutter_patcher publish   ... (M1 只做本地 mock 对接)
flutter_patcher keys init [--out <dir>]
flutter_patcher doctor
```

`--engine-artifacts` / `--tools-artifacts` 缺省指向同一 flutter_patcher_artifacts 仓库的 flutter-<version> Release，分别读取 engine.manifest.json 与 tools.manifest.json；用户无需配置这些来源；`--force-tier` 只供排查用，正式流程由判定决定档位。

### 4.5 单工具 dill 子命令

分析命令统一约定：**结果走 stdout 的一行 JSON，诊断走 stderr，退出码 0=成功、1=分析失败、2=用法错误。**

| 子命令 | 入参 | 输出 JSON |
|---|---|---|
| `extract-surface` | `--dill --own <pkgs> --out-iface --out-trim-iface` | `{members, types, extendable, overridable, barrels}` 计数 |
| `check-allocations` | `--dill --own --allocated <trace.json>` | `{violations:[{class, member, file, line, col}]}` |
| `check-inherited` | `--dill --own --iface --compiler-interface` | `{violations:[{code, message, file, line, column, col}]}`；message 为宿主库/类/缺失成员，每个成员一条 |
| `detect-shape` | `--dill --own --exclude <substr>` | `{verdict, injectionPoints:[...], bypasses:[...]}` |
| `transform-overlay` | `--dill --own --out --helper-lib --helper-fn` | `{wrapped:<n>}` |
| `verify-structure` | `--bytecode --expect-prefix --forbid-prefix` | `{ok, counts}` |

`detect-shape` 的 `verdict` 取值：`INJECTABLE` / `INJECTABLE_HOLE` / `UPGRADE`。

调用方式：`dart flutter_patcher_tools-<ver>.dill <子命令> ...`，dill 只能由我们的 CI 编译。

| 新增子命令 | 入参 | 输出 |
|---|---|---|
| `bytecode` | dart2bytecode 的全部参数原样透传 | 完整保留上游编译器输出和退出语义 |
| `gen-protocol-interface` | `--dill <来自用户 SDK 的 linked-flutter.dill> --out <yaml>` | YAML 写指定缓存文件；stdout 为生成计数 JSON |
| `gen-platform-privates` | `--platform <用户 SDK 的 platform_strong.dill> --out <yaml>` | YAML 写指定缓存文件；stdout 为生成统计 |

协议源定义由 artifacts/tools/generators/protocol_set 维护并内嵌进 dill；CLI 无需额外下载定义文件。CLI 获取 linked Flutter kernel 输入的编排、缓存失效判定属于 WP-2，本阶段没有实现。生成失败须报错，不能退回下载旧发布 YAML。

### 4.6 两份 manifest

CLI 从 `flutter --version --machine` 取 `frameworkVersion`、`engineRevision` 与 Dart 版本，查 artifacts 的唯一支持表；版本不支持即报错退出。以下两个文件位于同一个预建 Release：

```text
https://github.com/<owner>/flutter_patcher_artifacts/releases/download/flutter-<frameworkVersion>/engine.manifest.json
https://github.com/<owner>/flutter_patcher_artifacts/releases/download/flutter-<frameworkVersion>/tools.manifest.json
```

两份 JSON 的 `schema` 均为整数 1；下列字段均必需，除特别说明外不接受 null。数字、哈希来自各自构建的实测，不填写伪造示例值。

**engine.manifest.json schema**：

| 字段 | 类型与约束 |
|---|---|
| schema | integer，值为 1 |
| flutter_version | 稳定版 x.y.z 字符串 |
| engine_commit、engine_stamp、builder_repo_commit、depot_tools_rev | 40 位小写 hex；builder 指 artifacts commit |
| build_id | UUID v4；统一绑定本次引擎、gen_snapshot 和透传 embedding，不是 ELF linker build ID |
| built_at | UTC 时间 YYYY-MM-DDTHH:MM:SSZ |
| patches | 非空数组；元素为 file、sha256；按补丁文件名排序，无重复 |
| verify | snapshot=passed；device=passed 或 skipped；只有无设备允许 skipped/no_android_device，否则 device_reason 为 null |
| files | 恰好以下三个互异角色 |

| role | name | 额外字段 |
|---|---|---|
| engine | libflutter-arm64_v8a-release.jar | abi=arm64-v8a；maven 坐标；contents 数组记录 lib/arm64-v8a/libflutter.so 的 name/size/sha256 |
| gen_snapshot | gen_snapshot-linux-x64 | host_os=linux，host_arch=x64 |
| embedding | flutter_embedding_release.jar | maven 坐标；原样透传，WP-5 后再决定去留 |

每个 file 都有 `role`、`name`、正整数 `size`（字节）、64 位小写 hex `sha256`。Maven 坐标分别为 `io.flutter:arm64_v8a_release:1.0.0-<engine_stamp>` 和 `io.flutter:flutter_embedding_release:1.0.0-<engine_stamp>`。WP-5 校验 APK 中 SO 时使用 contents 中的 SO 哈希。构建日志单独保留为证据，不作为新版 Release 附件。

**tools.manifest.json schema**：

| 字段 | 类型与约束 |
|---|---|
| schema | integer，值为 1 |
| flutter_version、dart_version | x.y.z 字符串 |
| engine_commit、builder_repo_commit、dart_sdk_commit | 40 位小写 hex；builder 指 artifacts commit |
| patches | Dart 工具补丁列表，元素为 file、sha256 |
| files | 恰好一个条目：role=tools，name=flutter_patcher_tools-<flutter_version>.dill，正整数 size、64 位 hex sha256 |

工具 manifest 不含 YAML、不含单独 dart2bytecode 条目，也不复用引擎 build_id。两条 workflow 的 builder commit 可以不同；每份 manifest 独立记录自己的来源。

**校验规则**：两份 engine_commit 必须相等且等于本机 engineRevision；版本、宿主、必需角色与文件名必须匹配；下载文件逐个校验 size 和 SHA-256；缺文件报 ENGINE_ARTIFACT_MISSING / TOOLS_ARTIFACT_MISSING，manifest 字段缺失或未知 schema 报 ENGINE_MANIFEST_INVALID。下载缓存位于 `~/.flutter_patcher/artifacts/<frameworkVersion>/{engine,tools}/`；用户侧 YAML 缓存也必须位于 `~/.flutter_patcher/`，由 doctor 通过生成器创建，不通过 Release 下载。

manifest 本身 M1 不签名，只依赖 HTTPS。M2 与补丁签名同批加 manifest.sig。


---

## 5. 逐工作包规范

### WP-1 · 引擎流水线（`flutter_patcher_artifacts`）

**产出**：`supported_versions.txt` 里每个 Flutter 稳定版共用一个 GitHub Release，tag `flutter-<flutterVersion>`，附件：

```
libflutter-arm64_v8a-release.jar        io.flutter:arm64_v8a_release:1.0.0-<stamp> 坐标的 jar
flutter_embedding_release.jar           原样透传
gen_snapshot-linux-x64                  M1 只有这一个主机
engine.manifest.json                    §4.6
```

**执行环境**：

- self-hosted runner，Linux x86_64，注册到 `flutter_patcher_artifacts` 仓库，label `engine-builder`。M1 用现有的那台 Linux 服务器（它已经能编引擎）。
- 环境要求写进 `engine/README.md`：磁盘、内存、首次 `gclient sync` 时长、增量构建时长。实际量测见引擎仓库 `engine/README.md` 与本文 §10。
- workflow 用 `concurrency` 保证同一 runner 上引擎构建串行。
- 引擎 checkout 放在 runner 的持久目录（如 `/srv/engine`），不放 workspace，跨次复用，只切 commit 与 `gclient sync`，避免每次重拉几十 GB。

**固定项**：

- depot_tools 固定到 `DEPOT_TOOLS_REV`，脚本 checkout 到该 commit 并 `export DEPOT_TOOLS_UPDATE=0`。升级 depot_tools 是一次显式的 PR。
- `engine_patches/*.patch` 的 sha256 进 manifest。
- 构建参数固定在 `build_android.sh` 内，不接受 workflow 输入覆盖，唯一的矩阵变量是 Flutter 版本与 ABI。

**流水线步骤**（照实现计划 C-1，每步带断言，任一断言失败即整个 job 失败，不允许兜底）：

1. `resolve_engine.sh <flutterVersion>`：clone 或复用 `flutter/flutter` 到指定 tag，读 `bin/internal/engine.version` → commit；同时读 `bin/cache/engine.stamp` 若存在，否则由 commit 推导。断言 commit 是 40 位 hex。
2. `fetch_engine.sh <commit>`：depot_tools 在 `DEPOT_TOOLS_REV`；`git checkout --detach <commit>`；`gclient sync -D --no-history`。断言 `git rev-parse HEAD` 等于 commit。
3. `git apply --check engine_patches/*.patch` 再 `git apply`。**失败即中止**，这是版本漂移保护，不允许 `--3way`。
4. `gn --android --android-cpu arm64 --runtime-mode release --no-prebuilt-dart-sdk --dart-dynamic-modules`。
5. 断言 `out/android_release_arm64/args.gn` 含 `dart_dynamic_modules = true`。
6. `ninja -C out/android_release_arm64` 只构建以下目标（不构建 `host_release` 整体）：`flutter/shell/platform/android:android_jar`（或对应产出 libflutter.so 与 embedding jar 的目标）与 `flutter/lib/snapshot:generate_snapshot_bin` 所依赖的 `clang_x64/gen_snapshot`。目标名以首次构建时 `gn ls` 的实际结果为准，写死进脚本。
7. 断言三个文件存在：`libflutter.so`、`flutter_embedding_release.jar`、`clang_x64/gen_snapshot`；断言 `gen_snapshot --version` 能执行。
8. `package.sh`：按 Maven 坐标打 jar；生成 `build_id`（uuid v4）；算每个文件 sha256；写 manifest；压缩日志。
9. `verify_pair.sh`：用产出的 gen_snapshot 对一个最小 kernel 做一次 `--snapshot_kind=app-aot-elf`，用产出的 libflutter.so 在模拟器或真机上装一个最小 app 加载该 snapshot（有真机时做，无真机时此步标记 `skipped` 写进 manifest 的 `verify` 字段，不算失败）。
10. 仅在 `inputs.publish == true` 时上传引擎三个文件与 engine.manifest.json 到用户预建的 flutter-<ver> Release；不存在即失败并提示用户先手工创建；附件重名即失败，不覆盖、不新建 tag、不创建 Release、不改变 draft 状态。日志保留为构建证据，不在 Release 清单中。

**触发**：

- `workflow_dispatch`，输入 `flutter_version`（必填）、`abi`（缺省 `arm64-v8a`）与 `publish`（boolean，默认 false）。所有上传步骤都使用 `if: ${{ inputs.publish == true }}`。
- `check-new-stable.yml`：每天一次拉 `https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json`，取 `current_release.stable` 对应版本，若不在 `supported_versions.txt` 里则开一个 issue（M1 只开 issue，不自动构建；自动构建等 M1 稳定后再开）。

**成对性**：`libflutter.so` 与 `gen_snapshot` 必须同 `build_id`（CON-3）。`doctor` 与 `build` 后校验各查一次。

**首次构建任务 T-1**（WP-1 的第一件事，在写 workflow 之前做）：在服务器上手工按步骤 1–8 跑一遍并计时，记录：`gclient sync` 时长与磁盘占用、`ninja` 时长与并行数、`out/` 目录大小、峰值内存、三个产物的大小。填进 `engine/README.md` 与本文 §10。之后再把这些命令原样搬进 `engine/scripts/`。

**验收**：A10；`doctor` 能从 Release 下载并通过成对性检查；README 里的量测数字非空。

### WP-1b · 工具流水线（flutter_patcher_artifacts，build-tools.yml）

**产出**：附加到用户预建的 `flutter-<flutterVersion>` Release，仅两个附件：

```text
flutter_patcher_tools-<ver>.dill
tools.manifest.json
```

**环境**：GitHub 托管 ubuntu-latest；使用本仓唯一 supported_versions.txt 和版本 pin；与引擎 workflow 互不依赖。CI 安装对应 stock Flutter，CI 编工具 dill；不在用户机器编工具。

**步骤**：

1. `flutter --version --machine` 取 frameworkVersion、engineRevision、dartSdkVersion，断言与矩阵和 pin 相符。
2. CI shallow clone 固定 Dart tag/commit 的源码；校验并应用 tools/dart2bytecode_patches 补丁；独立受管源码目录中准备 SDK 包依赖 overrides 与锁文件，不能改用户 SDK。
3. 编译 `tools/kernel_tools/bin/main.dart` 为 `flutter_patcher_tools-<ver>.dill`。同一入口包含已实现分析命令与 bytecode 子命令，后者调用打过补丁的 dart2bytecode，参数原样透传；不再单独编译第二份发布 dill。
4. 将协议生成器和其源定义编进 dill 的 gen-protocol-interface 子命令。CLI 在用户机器从用户自己的 Flutter SDK 准备 linked kernel 输入，调用已编译 dill 生成 YAML，并缓存到 `~/.flutter_patcher/`；不发布 YAML。
5. 将平台私有接口生成器编进 gen-platform-privates 子命令。CLI 传入用户 SDK 的 platform_strong.dill，在用户机器生成并缓存 YAML；不发布 YAML。
6. CI 对合并快照执行九样本 detect-shape、变换与 bytecode 冒烟；生成器可生成工作目录中的临时 YAML 用于验证，但不放进发布目录。两轮快照和 tools manifest 比较作为新版 A11 的工具部分验收。
7. 写只有一个 dill 条目的 tools.manifest.json。publish 默认 false；所有上传步骤加 `if: ${{ inputs.publish == true }}`；只向用户预建的 flutter-<ver> Release 上传这两个文件。不存在或附件重名立即失败，不创建 tag/Release，不公开 draft。

**验收**：合并快照的重复构建与冒烟；doctor 能下载并调用工具 --help；YAML 本地生成/缓存由 WP-2 验收。M1.5 仅做重组与语法检查，历史双 dill 成功不能充当合并快照成功。

### WP-2 · CLI 骨架与配置

**目标**：用户选择已初始化的 stock Flutter SDK，CLI 从 `flutter --version --machine` 自动推导所需产物，完成 WP-5/WP-6 所需工具链准备。M1 主机仅 Linux x64（含 x64 WSL2），目标 Android arm64。

**归属**：新建代码仓库根目录 `flutter_patcher_cli/` 独立 Dart 包；生产依赖不含 `package:kernel`。生成器和编译工具源码继续留在 `flutter_patcher_artifacts`。现有插件源码、pubspec dependencies 和用户项目保持不变。

**入口**：`flutter_patcher doctor [--flutter-sdk <path>] [--offline] [--json]`。默认缓存 `~/.flutter_patcher/`；维护/测试可覆盖 artifacts Release 下载地址、支持表地址，缓存覆盖只允许在受管目录或当前项目 `.dart_tool/flutter_patcher/` 内。build/patch/publish/keys 不伪造成功，留待后续实现；本阶段密钥仅检查已提供的文件是否存在且非空。

1. 启动 Flutter 前核对现有 SDK 缓存戳，拒绝会触发原地更新的状态。读取 Flutter、Dart、framework 和 engine 身份，从 artifacts 唯一支持表检查版本；缓存未包含新版本时在线刷新一次。不支持立即报错，不提供用户自行编译路径。
2. 解析同一 `flutter-<version>` Release 的 `engine.manifest.json` 与 `tools.manifest.json`，严格校验 schema、版本、角色、大小、SHA-256 和实际二进制架构。工具 manifest 仅一个 `flutter_patcher_tools-<ver>.dill`。两条流水线的 builder commit 可以不同；引擎文件由 engine manifest 的 build_id 绑定。
3. 使用 `~/.flutter_patcher/flutter/<version>/` 平行 SDK，固定 framework commit。**先 stock precache，再准备引擎镜像**。副本替换 gen_snapshot；引擎 jar 和 embedding jar/POM 放入本地 Maven 镜像。不可把替换 stock flutter.jar 当作 APK 注入已完成，真正构建接线留给 WP-5。
4. CI 编好的单 dill 使用所选 SDK 的 Dart 执行；工具与 bytecode 子命令冒烟必须成功。两份 YAML 不下载：CLI 在隔离缓存中用用户 SDK 的 Flutter 源码编译探针 kernel，调用 gen-protocol-interface、gen-platform-privates 生成缓存。这里只编译探针，不编译工具 dill。
5. YAML 输入键包含 Flutter/Dart/engine/framework 身份、相关 SDK 源码/pubspec、platform dill、frontend 和工具 dill 哈希；缺失或损坏重生成，输入变化换键。产物分阶段写入，通过校验后原子进入缓存；损坏内容移至隔离路径，离线缺失或损坏产物明确失败。进程锁避免并发修改同一缓存。
6. doctor 实际调用下载的 gen_snapshot 编译最小 arm64 AOT ELF；可以对显式 `--apk` 的 arm64 SO 做 manifest 哈希验证，但这不代表真机执行或完整 A1。

**上下文检查**：未提供密钥、基线仓库、基线目录、versionCode/flavor 或 APK 时，相应项为 `not_run`。显式提供后失败必须返回非零；本阶段仅密钥文件存在性、仓库可达性、基线必需文件存在性、file store 侧车指纹字段检查，完整归档/指纹绑定留给 WP-4。成功返回 `toolchain_ready`，不是“全部 M1 检查通过”；`all_checks_complete: false`，设备 A1 保持 `not_run`。

**验收基准**：

- 独立包 analyze、单元/本地 HTTP 测试通过，覆盖错版本、错误 manifest/哈希、缺失附件、半下载不可复用、损坏缓存恢复、不支持版本、支持表刷新、YAML 输入变化与损坏重生成。
- Linux x64 从实际公开精简 Release 冷启动成功；断网环境复验成功且下载请求为零；使用实际下载的 dill 生成 YAML、gen_snapshot 生成 AOT ELF。
- 所选 SDK 前后文件清单及 SHA-256 相同；插件运行时、原生代码和 pubspec 无差异。
- 本地 path 安装后入口可用；原生 Windows/Mac 明确 HOST_UNSUPPORTED；缺失显式密钥等错误不能变成成功。设备、真实 APK 构建注入和完整基线验收独立留待后续工作包。

实现说明与实测证据：`flutter_patcher_cli/README.md`、`flutter_patcher_cli/docs/WP2-acceptance.md`。本地分支完成后停下审核，不自动推送代码仓库。

### WP-3 · 接口生成

**四档并集**（D-6）：已引用面 ∪ 协议集合 ∪ 常用控件集合 ∪ dart:core。

**产出两份同源派生的接口**（D-8）：`dynamic_interface.yaml`（进构建）与 `trim_interface.yaml`（只给裁剪用，不进构建、无体积代价）。

**提取器五条实现细节必须照做**（C-8），任一条漏掉都会以难懂的方式失败：

1. 成员键名：只有 `Procedure` 的 getter/setter 加 `get:`/`set:`，字段/方法/操作符/构造函数用裸名
2. 跳过私有名成员与私有类容器
3. **常量反查表**（`Constant → Field`）
4. 枚举额外给类级 `callable`（D-9）
5. 同时产出裁剪专用接口

**定点迭代**：提取 → 合并 → `dart2bytecode --validate` → 解析 `list X as Y` 提示 → 补进接口 → 重来。名字解析限定在**模块 import 到的库并穿透一层 re-export**。设上限（建议 5 轮）避免死循环。

**整程序档另需**：`platform_privates-<ver>.yaml`（CLI 调用 CI 编好的工具 dill 的 gen-platform-privates 子命令，从用户 SDK 生成并缓存；不从 Release 下载）、`dynamically-callable` 一节（`dart:core` 的 `num`/`int`/`double`/`Enum`，**不能列 `Object`**，D-10）、`--allow-dynamic-calls-in-dynamic-modules` 与 6 个放行 selector。


**WP-3 实施接口（2026-09-08，本地代码待审）**：

- 版本绑定实现位于 artifacts 的 `tools/kernel_tools/lib/src/`；新增 `extract-surface`、`merge-interface`、`resolve-interface-hints`、`trim-interface`。SDK trimmer 使用固定 Dart 版本的 frontend/vm 源码并编进同一 CI dill；不让用户编译工具。
- CLI 新增高级入口 `flutter_patcher interface --dill <未注解的 app.dill> --module <模块源文件> --packages <模块 package_config.json> --own <包列表> [--mode lean|whole] [--out <新目录>] [--max-rounds 1..5]`。默认输出在项目 `.dart_tool/flutter_patcher/interfaces/`。SDK/产物/支持表复用 WP-2 的自动解析，插件不改。
- 输出 `dynamic_interface.yaml`、`trim_interface.yaml`、`interface.manifest.json`；编译日志、每轮 YAML、临时索引及验证字节码保留用于诊断，不能作为已验收可发布补丁。只有验证通过才将临时目录提交到输出路径；旧基线和输入不改。
- 两份接口使用单一规范化集合模型：排序、去重、展开列表、保留类级与空名构造函数的语义差别。裁剪接口不会重复定义 callable 键。协议复用用户 SDK 缓存；常用控件和平台策略编进工具 dill。
- 无 main 的模块用缓存中的临时 import 入口生成索引；实际字节码验证针对原模块。提示候选限制为实际导入声明及 facade 的导出声明，遵循 show/hide，只有 dart:core 隐式可见；不得因导出了 Matrix4 就把同库 Colors 作为候选。剩余歧义、无候选、无进展或轮次用尽必须失败。
- 精简档先以 trim_interface 裁剪 app/platform kernel，再向 bytecode 传 --import-dill 与裁剪 platform；整程序档使用完整平台公开接口、平台私有条目、限定动态调用及选择子，不导入宿主框架 kernel。验证命名空间固定为 wp3_validation。
- `doctor --refresh-tools` 在线重新获取并完整校验工具后切换缓存；失败保留旧缓存，禁止与 --offline 同用。新 dill 缺失时不得使用源码编译兜底。WP-3 还检查缓存索引哈希，缺失/损坏则从 SDK 重建。
- 新工具分析命令成功 stdout 单行 JSON，诊断 stderr，退出码 0/1/2；bytecode 仍保持上游语义。CLI 成功状态 interface_validated，仅声明接口与编译器验证通过；host_build_verified/device_verified 为 false，完整宿主构建和真机闭环留待后续工作包。
- 验收：提取规则、常量/枚举/继承/私有过滤、barrel、导出同名歧义、合并确定性；实际精简档裁剪与整程序档编译；CLI 收敛/无进展/上限/旧工具拒绝/输出保护；WP-2 doctor 和缓存回归。CI build-tools 已接入结构测试和单 dill 集成测试，公开工具替换需另行审核，不能以源码执行结果声称新版 CI dill 已验收。

### WP-4 · 基线仓库

**寻址**：内容寻址，键是指纹。

```
指纹 = sha256(app.dill 内容哈希 ‖ engine commit ‖ 接口 yaml 哈希 ‖ Flutter 版本)
```

**基线内容**：`app.dill`、platform dill 的路径与哈希、`dynamic_interface.yaml`、`interface_detailed.json`、`package_config.json`、每个源文件哈希、engine commit、Flutter 版本、引擎 `build_id`、**allocate-finalized 类集合**、`libapp.so`。

**归档**：打 `baseline-<fingerprint>.tar.zst`，put 到 `--baseline-store`（`file://` / `s3://` / `https://`）。**归档失败即构建失败**，不允许静默通过。

**侧车**：`release-<flavor>-<versionCode>-<abi>.json`，记指纹、Flutter 版本、engine commit、`build_id`、`libapp.so` 的 sha256。

**本地缓存**：`~/.flutter_patcher/baselines/<fingerprint>/`，命中不拉取。

一份基线量级约 68 MB 未压缩（demo 数据），写进文档。

### WP-5 · `build` 管线

按实现计划 C-2 的八步实现。M1 需要特别注意的三条：

- **引擎注入靠 `FLUTTER_STORAGE_BASE_URL=file://<mirror>`**，不动用户项目任何文件（R-10）。每次构建前清 `caches/modules-2/files-2.1/io.flutter` 与 `caches/modules-2/metadata-*/descriptors/io.flutter`，我们的 jar 与 stock 同坐标，缓存命中就会拿到 stock。
- **构建后断言** APK 里 `lib/<abi>/libflutter.so` 的 sha256 等于引擎 manifest 值。这一条把"坐标漂移 → 静默拿到 stock 引擎 → 装机 SIGABRT"整类问题堵死。
- **基线单独编一次**，`--no-aot --no-tfa --no-link-platform`，**不裁剪**（E5）。不要用 `.dart_tool/flutter_build/<hash>/app.dill`。

**引导入口生成**（`.dart_tool/flutter_patcher/main.dart`，用 `--target` 指向）：

```dart
import 'package:flutter_patcher/flutter_patcher.dart';
import 'package:<app>/main.dart' as app;

const String _fingerprint = '<64 hex>';   // 构建期烧入
const String _publicKey = '<base64>';     // 构建期烧入

Future<void> main() => PatchBootstrap.run(original: app.main);
```

`--target` 指向 `.dart_tool` 下的文件已在 G2 中实测可用。

**allocate-finalized 集合**：加 `--extra-gen-snapshot-options=--trace-precompiler-to=<trace.json>`，解析事件流里指向 `"C"` 类记录的裸 entity id（E8）。demo 上 1.66 MB trace、2,528 个类，构建时间无可测增量。

### WP-6 · `patch` 管线

十步照实现计划 C-2。M1 的核心是**第 5 步的四道判定**。

**判定必须一次报全**，不是遇到一个就走。四者都读第 4 步的 kernel（保留 source-positions），都必须带文件/行/列：

| 判定 | 来源 | 触发升档 |
|---|---|---|
| 接口面 | 工具 dill 内 compile-patch 调用固定 CFE 的 dynamic-interface validator | 是 |
| 分配检查 | `check-allocations` vs 基线的 allocate-finalized 集合 | 是 |
| 继承成员面 | `check-inherited` | 是 |
| 资源覆盖层形状 | `detect-shape`，仅当补丁携带资源时 | `INJECTABLE_HOLE` / `UPGRADE` 时是 |

**报告格式**（示例）：

```
补丁超出精简档，已自动升整程序档。原因：
  接口面      3 处
    lib/pages/detail.dart:42:7   Slider 未在 release 的接口内
    ...
  宿主不能分配 1 处
    lib/util/io.dart:15:22       dart:io::ProcessException（generative）
  继承成员缺失 1 处
    lib/asset.dart:8:7           PatchAssetBundle 缺 loadStructuredBinaryData
  资源覆盖层  1 处
    lib/main.dart:12:19          直接使用 rootBundle，精简档覆盖不到
后果：框架将以解释模式运行，启动、滚动和内存占用可能退化；本次应用的具体指标 TBD。
```

**整程序档下分配检查仍然要跑**，模块绑的 `dart:*` 还在宿主里。模块自带的框架成员无需宿主接口，但 `dart:*` 接口限制仍须满足；失败即拒绝，不扩张已发布宿主接口。

**模块入口生成**（`.dart_tool/flutter_patcher/patch_entry.dart`，作为 dart2bytecode 的模块根）：

```dart
@pragma('vm:entry-point')        // TFA 的根，缺了树摇会摇掉入口本身
@pragma('dyn-module:entry-point')
Object? dynamicModuleEntrypoint() => <Object?>[
      1, <seq>, '<fingerprint>', '<tier>', _patchedMain, _installAssets,
    ];
```

三个常量必须是**编译期字面量**，自检读 dart2bytecode 之前那份 kernel 断言，**不在 bytecode 产物上做字符串扫描**。

**输出**：补丁文件 + `patch.json`（平台、策略、指纹、序号、哈希、最低应用 build 号）。

### WP-7 · 资源与字体

**字体**（两档均交）：扫描补丁引用的**全部** `IconData` 常量码点（不是新增的那些），用 `font-subset` 切子集。同 family 名注册是覆盖不是合并，只带新码点会让原本正常的图标消失。

**资源，整程序档**：模块自带框架副本，编译期把 `rootBundle` 换成覆盖版本，不依赖业务代码形状。

**资源，精简档**：`transform-overlay` 把每个注入点的第 0 个实参包一层

```
runApp(X) → runApp(DefaultAssetBundle(bundle: patcherOverlayBundle(), child: X))
```

实现要点（F6 实测）：

- `DefaultAssetBundle` 在 `package:flutter/src/widgets/basic.dart`，**不在** `asset_bundle.dart`
- `writeComponentToBinary` 是**异步**的，不 await 会写出空文件
- 检测器**必须跟常量图**：`launch(runApp)` 被 CFE 折叠成 `StaticTearOffConstant`，只看 AST 节点看不见
- 检测器**必须排除插件自己的生成代码**，否则覆盖层辅助函数里的 `_overlay ?? rootBundle` 会被误报
- 多注入点全部包（条件分支两处 `runApp` 实测两处都要包）

**用户可见规则写进文档**：`rootBundle` 与 `DefaultAssetBundle.of(context)` 在精简档下不等价，前者永远读安装包。`Image.asset` 一类框架 API 本来就走后者。

### WP-8 · 运行时引导

**六步**照实现计划 C-3。M1 必须照做的硬约束：

1. **绝不 `ensureInitialized()`**（D-19）。用 `ui.PlatformDispatcher.instance.sendPlatformMessage` + `const StandardMethodCodec()`。G2 实测：发完消息 binding 仍不存在，应用自己的自定义 binding 照常赢得 `WidgetsBinding.instance`；反例下 debug 抛断言、release 静默双初始化。
2. **超时 3 秒**，超时当作没有补丁走原 main。超时只兜"原生处理器卡住"，通道或方法不存在会**立刻**返回 `notImplemented`，不会挂死。
3. **绝不调用 `FlutterPatcher.init()`**（实现计划 5.5（三））。`init()` 在 `_inited` 为真时直接 return，bootstrap 先调一次会让用户自己那句 `init(publicKeyBase64: ...)` 静默失效。
4. 校验顺序按补丁包规范二**固定不可重排**：长度 → magic → format_version → 指纹 → payload_sha256 → 验签 → 字节码 magic。未验签的 `payload_len` 不能用来分配缓冲区。
5. 加载失败调 `PatcherChannel.reportDartBootError`，那条通道已做 crash_count +1 → 黑名单 → 删补丁，**不新增原生方法**。
6. 所有失败路径不抛异常，只记录并回退。

**zip 解析必须是插件自带的只读实现**，不引入 `package:archive` 到运行时：只允许 STORED，不允许 zip64/加密/目录条目/`..`/绝对路径/重名，条目数 ≤ 4096，单条目 ≤ 64 MiB。

**性能预算（2026-09-11 决策）**：lean 主路径 **85 ms**，whole 作为同一认证基线内的兼容性兜底 **200 ms**。两者均测 BootRunner 开始到进入 patched main 之前的绝对墙钟时间，不混用 am start 总时长增量；每档 10 次冷启动全部不超预算才算性能通过，功能矩阵独立判定。200 ms 是目标，不代表当前 whole 已达标。whole 不允许绕过指纹、Flutter/引擎版本、签名和接口限制，不保证任意补丁都能发布。原生调度开销继续细分；复用宿主 Flutter 框架的 host interface 扩展排到 M1.5 之后，不进当前里程碑。决策及未测运行时性能边界见 doc/bootstrap-performance-budget.md。

### WP-9 · 故障样本与 CI

**样本按补丁包规范四的检查表逐行生成**，每行 ≥1 个样本。至少覆盖：随机字节、截断（头中间/payload 中间）、空文件、`magic` 改一位、`format_version` 改成 0 和 255、指纹改一位、`patch_seq` 回退、`payload_len` 大于/小于实际、签名改一位、payload 改一字节而签名不变、zip 用 DEFLATE、zip 含 `../x`、zip 多一个未列条目、`module.bc` 头部截断、asset 的 sha256 不符、PatchEntry 少一个下标、下标 4 不是函数。

**CI**：每次在 Android 真机/模拟器跑一遍，断言全部被拦下且**应用存活**（无 SIGABRT）。规范改一条就补一批样本。

**其他 CI 项**：体积回归（空应用基线，`libapp.so` 增量超阈值报警）、引擎产物成对性、跨版本回归（每个进支持表的 Flutter 版本跑完整链路 + G2 的裸平台消息探针）。

---

## 6. 错误码

沿用 v1 的 `SCREAMING_SNAKE` 约定。CLI 错误进 stderr 并以非零退出，运行时错误进 `BootDiagnosticStore`。

### 6.1 CLI（`flutter_patcher_cli`）

| 码 | 含义 |
|---|---|
| `HOST_UNSUPPORTED` | 当前主机 OS 无对应 gen_snapshot（M1 下 Windows/macOS 会报这个） |
| `ENGINE_ARTIFACT_MISSING` | 引擎产物不在或版本不支持 |
| `TOOLS_ARTIFACT_MISSING` | 工具产物不在或版本不支持 |
| `ENGINE_MANIFEST_INVALID` | 任一 manifest 字段缺失、schema 不认识、两份 `engine_commit` 不一致或与本机不一致 |
| `ENGINE_ARTIFACT_MISMATCH` | `libflutter.so` 与 `gen_snapshot` 的 `build_id` 不一致 |
| `ENGINE_INJECTION_FAILED` | 构建后 APK 里的 `libflutter.so` sha256 不符 |
| `BASELINE_STORE_UNREACHABLE` | 基线仓库不可达 |
| `BASELINE_ARCHIVE_FAILED` | 归档失败（**构建失败**） |
| `BASELINE_NOT_FOUND` | 按指纹取不到基线 |
| `BASELINE_FINGERPRINT_MISMATCH` | 补丁源码与基线不匹配 |
| `IFACE_FIXPOINT_EXCEEDED` | 定点迭代超过上限 |
| `PATCH_NO_CHANGES` | 源码哈希无变化 |
| `PATCH_STRUCTURE_INVALID` | URI 前缀检查不通过 |
| `PATCH_ENTRY_INVALID` | 入口元组常量与本次补丁不一致 |
| `PATCH_TOO_SMALL` | 低于空补丁阈值 |
| `FONT_SUBSET_FAILED` | `font-subset` 失败 |
| `TIER_UPGRADED` | **不是错误**，退出码 0，仅作为报告标记 |

### 6.2 运行时新增

| 码 | 含义 |
|---|---|
| `BOOT_PAYLOAD_TIMEOUT` | `bootPayload` 3 秒未回 |
| `ENVELOPE_INVALID` | 封装头任一步校验失败（细分原因进 detail） |
| `ARCHIVE_INVALID` | zip 违反约束或条目哈希不符 |
| `MODULE_ENTRY_INVALID` | 入口元组形状或类型不符 |
| `MODULE_LOAD_FAILED` | `loadDynamicModule` 抛出 |
| `FINGERPRINT_MISMATCH` | 补丁指纹与烧入值不符 |

---

## 7. 测试规范

| 层 | 范围 | 位置 |
|---|---|---|
| 单元 | 封装头编解码、zip 只读解析、入口元组校验、指纹计算、trace 解析、错误码映射、两份 manifest 解析与校验 | `flutter_patcher/test/`、`flutter_patcher_cli/test/` |
| kernel-tools | 九个形状样本的判定与变换（F6 的样本进仓库当固定用例） | `flutter_patcher_artifacts/tools/kernel_tools/test/` |
| 流水线 | 引擎脚本的每条断言各有一个失败样本（错 commit、patch 不适用、args.gn 缺开关）能让 job 非零退出 | `flutter_patcher_artifacts/engine/scripts/test/` |
| 集成 | `build` → 基线 → `patch` 的产物断言（不上设备） | `flutter_patcher_cli/test/integration/` |
| 真机 | 故障样本库、四道判定、资源两档、自定义 binding、裸平台消息 | CI 真机任务 |
| 回归 | v1 `.so` 模式的现有 `flutter_patcher/test/` 全绿 | 现有 |

**F6 的九个形状样本（`temp/f6/shapes/`）要从 temp 移进 `flutter_patcher_artifacts/tools/kernel_tools/test/fixtures/`**，作为检测器的固定回归用例。

---

## 8. 开工顺序建议（全职假设）

| 周 | 内容 |
|---|---|
| 第 1 周 | T-1 手工量测 → `flutter_patcher_artifacts` 仓库、runner、脚本、手动触发 workflow，用户预建 `flutter-<ver>` Release，WP-1 与 WP-1b 分别构建和校验各自附件；是否开启上传由用户决定；WP-8 的原生 `bootPayload` |
| 第 2 周 | WP-2、WP-3、WP-4、WP-8 的 Dart 引导与校验层 |
| 第 3 周 | WP-5、WP-6 的四道判定、WP-7 |
| 第 4 周 | WP-6 收口、WP-9、端到端与验收 |

**第 1 周结束前必须拿到的三个中间结论**：引擎流水线能从 workflow 出成对产物且 `doctor` 能下载校验通过；工具流水线能出 dill 且冒烟通过；`bootPayload` 在真机上能被裸平台消息拿到（G2 已验证机制，这里验的是真实实现）。

---

## 9. agent 执行约定

本文由 AI agent 直接执行时遵守以下约定。

0. **禁止 push、tag、release。** agent 不执行 git push、git tag、Release 创建/上传/删除或其他等价远端写操作；这些动作只能由用户执行。workflow 上传逻辑仅供用户显式触发，本阶段禁止触发。

1. **断言失败就停。** 任何一步的断言不满足，停下来报告，不要改断言、不要加 fallback、不要用 `--3way`、`--force`、`|| true` 一类方式绕过。断言存在的意义就是让漂移暴露。
2. **数字不编。** §10 的量测表、README 的环境要求，只填实际测得的值。没测到就留 `TBD`，不要估。
3. **不动用户侧文件。** CLI 与流水线不修改用户项目内任何文件，也不修改用户的 Flutter SDK；所有可写路径只有 `~/.flutter_patcher/`、项目的 `.dart_tool/flutter_patcher/`、`--out`。
4. **不新增依赖到插件包。** `flutter_patcher/pubspec.yaml` 的 `dependencies` 除本文明确列出的外不增加。
5. **原型代码搬迁时不重写逻辑。** `temp/` 下的原型迁入产品目录时先原样迁入并让测试通过，再做重构，两步分开提交。
6. **设计决策不在实现中改。** 遇到实现计划的 `D-*` 决策与本文冲突，或者觉得某条决策不合理，停下来提出，不要就地改掉。
7. **提交粒度。** 一个工作包内按 §5 的小节切提交；每个提交信息第一行写 `WP-<n>: <做了什么>`。
8. **每个工作包完成时写一段验收记录**，附到本文 §11，写明验收项编号、验证命令、结果。

---

## 10. 量测记录（T-1 后填）

| 项 | 值 |
|---|---|
| runner 硬件（CPU 核数 / 内存 / 磁盘） | Linux x64，8 线程 / 16,773,283,840 B 内存 / 539,792,977,920 B 文件系统 |
| 首次 `gclient sync` 时长 | 3 分 39.05 秒；新 checkout，未清除机器既有下载缓存 |
| 引擎 checkout + 依赖磁盘占用 | 编译前 `du -sb` 表观大小 25,496,146,396 B；非文件系统实际分配块数 |
| `ninja` 时长（并行数 = ?） | 16 分 23.40 秒，`-j8`；完整干净输出目录构建 |
| `out/android_release_arm64/` 大小 | `du -sb` 表观大小 1,367,324,021 B |
| 构建峰值内存 | 8,387,522,560 B；独立 cgroup v2 `memory.peak`，含该组计费的页缓存 |
| `libflutter.so` / embedding jar / gen_snapshot 大小 | 11,908,208 / 1,584,072 / 6,295,056 B；SO 为 stripped 发布版本 |
| 增量构建（换 commit）时长 | Flutter 3.47.1 engine → 3.47.2：依赖同步 28.45 秒；构建阶段 6 分 15.91 秒（含 GN、断言与 Ninja `-j8`，复用输出目录）；旧版本基准准备时间另记，不计入 |
| WP-1b 单个版本 job 时长 | Flutter 3.47.2，GitHub 托管 Ubuntu：构建与发布 job 3 分 11 秒；其中双轮编译、九样本、A11 与编译器冒烟步骤 2 分 02 秒（Actions 时间戳，含两轮，非单次 dart compile 时间） |

---

## 11. 验收记录

（按 §9 第 8 条追加）

### WP-1 · T-1（2026-09-07，中间验收）

- 正式代码来源：本地 `D:\DevProjects\flutter_patcher_engine`，同步至 `https://github.com/xuelinger2333/flutter_patcher_engine` 及专用 Linux 构建目录；未复用远端实验二进制。
- 输入：Flutter `3.47.2`，engine `a804b261645ef8c13eb3d5c44a5c2fb0340c5539`，depot_tools `8be1125f74ccca1e2a0823d6f92bcec92f0fd65b`；仅 E8 补丁。
- 验证：`git apply --check`、GN 动态模块开关、`ninja -C out/android_release_arm64 -j8 flutter/shell/platform/android:android_jar clang_x64/gen_snapshot`、`gen_snapshot --version` 均通过；完整编译退出码 0。
- 打包与成对检查：`python3 scripts/artifacts.py validate <release> --publishable` 通过；最小 kernel → `--snapshot_kind=app-aot-elf` 通过；设备结果 `skipped/no_android_device`。
- 原始证据：引擎仓库 `measurements/T1-2026-09-07/`（time、manifest、源码身份、GN 目标、完整压缩日志）。首次 SSH 中断的半成品未计为完成，另建干净输出后重新量测。
- A10 仍待重复构建检查及后续 WP-2 doctor / A1 集成验收；本记录不宣称完整 A10 已通过。WP-1b 及其余工作包未实现。

### WP-1 · 流水线与发布验收（2026-09-07）

- 交付：本地独立仓库 `D:\DevProjects\flutter_patcher_engine`、GitHub 同名仓库、`gpu` 上专用缓存与已启用的 `engine-builder` runner 服务。正式源码先在本地提交，再同步；服务器可由仓库和 `docs/runner.md` 重建。
- 首份 Release：[engine-3.47.2](https://github.com/xuelinger2333/flutter_patcher_engine/releases/tag/engine-3.47.2)，[手动构建及发布 workflow](https://github.com/xuelinger2333/flutter_patcher_engine/actions/runs/34092945313) 成功。支持表仅 `3.47.2`，Linux x64 → Android arm64-v8a。五个附件均重新下载并校验 GitHub SHA-256；`python3 scripts/artifacts.py validate <downloaded-release> --publishable` 通过。
- A10 中本工作包的重复构建检查：同一 builder commit `db12b3da388256906f8866b74a2d9dedfb9917c7` 下，两次 build ID 分别为 `469e10a2-6aa3-4099-8142-f27e4b3bff0e`、`3e272ad1-0765-41cd-98da-059525837db5`。`python3 scripts/artifacts.py compare <first> <release>` 通过，三个主要产物 SHA-256 全部相同；证据位于引擎仓库 `measurements/repeatability-2026-09-07/`。
- 自动检查：`python3 -m unittest discover -s scripts/test -v` 共 41 项在 Windows 本地与 GitHub Linux 通过；各 shell 脚本 `bash -n`、actionlint 1.7.12 通过。每日 stable 检查 workflow 的手动运行通过，仅开跟踪 issue，不触发引擎构建。
- 跨 commit 量测：先构建 3.47.1 engine `5d531788691ec3404cac0cee66ead4007b177363`，再切回正式 `a804b261645ef8c13eb3d5c44a5c2fb0340c5539`；四阶段退出码均 0，源码与补丁恢复断言、打包及最小 AOT 编译均通过。结果见 §10；原始脚本、time、身份、manifest、完整压缩日志见引擎仓库 `measurements/incremental-2026-09-07/`。3.47.1 仅用于量测，未加入支持表或发布。
- 成对性：最小 kernel → 自编 `gen_snapshot --snapshot_kind=app-aot-elf` 通过。设备 `skipped/no_android_device`；已连接但 offline/unauthorized 的设备会报错，不能冒充无设备。后续 helper commit `baf219f10ed432ea8ebeeb48ca7ea74b7edc1fe8` 调整验证临时目录，并经真实 Linux smoke 验证；未变更 Release 的原 builder commit。
- 完整 A10 尚未通过：WP-2 `doctor` 下载/成对检查及 A1 应用更新流程须随其工作包另验，设备运行分支本次也没有实际验收。主仓库插件与其他工作包代码未改动。

---

### WP-1b · 工具流水线验收（2026-09-07）

以下为撤回发布前的历史构建记录，不代表用户验收通过或当前存在公开工具 Release。当前审核状态见本节末尾。

- 源码与范围：`flutter_patcher` 的 `kernel_tools/`、`tools/`、`supported_versions.txt`、`.github/workflows/tools-release.yml`。原型迁入 `a45eba2`，样本导入修复 `10314a0`，发布构建 commit `dc326fad2bccaccc2d608c63f0d3a570c64ec367`；插件 `pubspec.yaml` 与原生/运行时代码未改动，WP-2 及其他工作包未实施。
- 输入：stock Flutter `3.47.2`、Dart `3.13.2` tag 指向 `60a57cd42d64dc03e9f07aa60a2e250755c1ef28`，engine `a804b261645ef8c13eb3d5c44a5c2fb0340c5539`。两仓支持表同步检查通过；工具补丁经过 `git apply --check` 后应用，第三方 Dart 包锁文件用 `--enforce-lockfile` 校验。
- 历史发布：`tools-3.47.2` Release/tag 已按用户要求删除；此前[托管发布 workflow](https://github.com/xuelinger2333/flutter_patcher/actions/runs/34100568067) 成功，五个附件齐全；发布前核对 GitHub 上传 digest，发布后五个附件重新下载核对 SHA-256，`python3 tools/release/tools_artifacts.py validate <downloaded>` 通过。
- **A11 通过**：同一源码及依赖路径下独立编译两轮，kernel-tools、dart2bytecode、两份 YAML 及 manifest 逐字节比较一致。记录不宣称不同绝对构建路径之间的二进制哈希一致。[前置托管 CI](https://github.com/xuelinger2333/flutter_patcher/actions/runs/34100551767) 与正式发布 job 均完成该检查。
- 测试：21 项 Python 契约测试、9 项检测器结构测试通过；两轮编译后的 kernel-tools 均通过 F6 九样本的固定 verdict、注入点与绕过数量断言。第 7 个样本为 `INJECTABLE_HOLE`，第 9 个为 `UPGRADE`。第 4/7 个样本的快照变换、读回和绕过判定保持检查通过；无 `main` 模块使用补丁编译器 `--aot-only`、`--tfa` 均产出字节码。actionlint 通过。
- 接口生成：固定 Flutter 协议层 174 个类条目全部在选定 Flutter kernel 中解析通过；平台私有接口保留原型遍历逻辑。公开 kernel-tools 入口目前为迁入的 `detect-shape` 和 `transform-overlay`；其他 §4.5 分析命令随对应后续工作包实现，未伪造占位成功结果。
- 下载调用验证：从公开 Release 下载到独立目录后，直接用同版本 stock Dart 运行两个 `.dill --help` 成功，无 `--packages`；工具 manifest 与公开 engine manifest 的 `engine_commit` 一致。WP-2 `doctor` 本体尚未实现，因此这里不宣称已完成 doctor 子命令集成验收。
- 证据与量测：本地忽略目录 `.dart_tool/flutter_patcher/wp1b/review-documents/` 保留原工具说明与 `measurements/` 附件；不再作为受 Git 跟踪的交付文档。单版本 job 实测见 §10。

### WP-1b · 用户审核与本地问题（2026-09-07）

- 发布边界：未经用户审核与明确批准，不推送 `flutter_patcher` 发布主分支，不创建 tag/Release；测试分支的远端推送也须先提交用户审核。先前误推已撤回，主分支恢复至 `f98a977047aecc22248b18b55a4f0e27f61ebf11`。本次审核期间不提交、不推送。
- 文档边界：本次将 `README.md`、`README-zh.md` 恢复至上述发布基线，移出新增的 `tools/README.md` 与 `tools/measurements/WP1b-2026-09-07/`。后续说明仅更新 Git 忽略的本 SPEC；不更改其他 README/文档。相对本地旧 HEAD 显示的 README 修改和文档删除是本次撤回动作。
- 实测本地分析：使用现有 Dart 3.10.7 执行 `dart analyze --format machine .`，退出码 3，共 359 ERROR、52 WARNING、31 INFO。ERROR 分布为 `kernel_tools/` 105、`tools/` 12、`temp/` 242；本次结果在其余目录未发现 ERROR。原始输出保存在 `.dart_tool/flutter_patcher/wp1b/analyze-review.txt`。
- 新增工具的分析问题：`kernel_tools` 本地缺少独立 package_config 与固定 Dart SDK 源码依赖映射，出现 `package:kernel` 及包内自身导入找不到、随后类型未定义的级联错误；其 SDK 约束为 `>=3.13.0`，当前 Dart 3.10.7 不满足。两个 `tools/` Dart 生成器也缺少编辑器可使用的包上下文。现有构建脚本在独立构建目录准备依赖，并通过 `--packages` 运行生成器，因此历史构建成功没有覆盖本地编辑器环境。此项交付缺口尚未修复；不得以隐藏分析错误代替正确配置，也不向插件 pubspec 增加 kernel 依赖。
- `temp` 清理判断：正式跟踪的构建/运行源码未发现依赖仓库 `temp/` 的路径；但本地分析确实扫描了它，原型中缺失 kernel、实验应用包及相对文件造成报错。`extract_referenced_surface.dart`、`e2_resolve_hints.dart`、`allocated_classes.dart`、`check_allocations.dart` 仍是 §4 原型迁移表中后续工作包的来源，尚未全部迁入正式目录。可在完整备份并校验后移出仓库；不应直接销毁唯一原型。本次保留 temp，且即使移除它也仍有新增工具的 117 个 ERROR 需要处理。

---

## 附录 · 与设计文档的差异

本规范累计提出三条决策，需在实现计划的决策记录中体现：

- **D-21**：CLI 拆成独立包 `flutter_patcher_cli`，避免重依赖传染给用户 app。（已回写）
- **D-22**：kernel 分析按 Flutter 版本发 kernel 快照，与 `dart2bytecode` 同一交付方式；CLI 本体不依赖 `package:kernel`。（已回写）
- **D-23（rev3）**：flutter_patcher 仅放插件/CLI；flutter_patcher_artifacts 集中版本绑定源码。两条独立 workflow 向用户预建的 flutter-<version> Release 附加各自文件及 engine.manifest.json/tools.manifest.json。工具由 CI 编为单 dill，YAML 由 CLI 在用户机器生成缓存。实现计划中的旧 D-23 仍是历史设计记录，本次只修订本 SPEC。

其余全部沿用实现计划与补丁包规范，未作改动。

### WP-3 · CI 检验（2026-09-08）

- 用户批准检验后，代码推送至 flutter_patcher/dev（9713049）及 flutter_patcher_artifacts 默认分支 m1.5-restructure（da2a15a），不再按工作包创建开发分支。flutter_patcher/main 未改。
- GitHub 托管工具 CI：https://github.com/xuelinger2333/flutter_patcher_artifacts/actions/runs/34218093910 ，success。固定 Flutter 3.47.2；单 dill 独立编译两轮，A11 的 dill 哈希与 tools manifest 一致性检查通过。
- CI 中 9 组接口结构检查、9 组 detect_shape 结构回归通过；九样本快照、变换及 bytecode 冒烟通过；interface_smoke 对 CI 编译的 dill 执行精简档裁剪/导入及整程序档编译、重复合并一致性检查，全部通过。构建脚本实测耗时 162.63 秒。
- 独立 Pipeline tests：https://github.com/xuelinger2333/flutter_patcher_artifacts/actions/runs/34218093978 ，success。CLI 本次再次 analyze 无问题，Windows 44 项测试通过。
- publish=false；Release 上传与 Actions 附件保存步骤均 skipped。原六个公开 Release 附件未改，公开 dill 仍为 WP-2 版本。本次 CI dill 的具体大小、哈希及各档轮次未输出到留存日志，记 TBD，不沿用源码执行的数字。
- 原始 Actions 日志：.dart_tool/flutter_patcher/wp3/ci-34218093910.log（本地忽略目录）。本记录仅证明工具 CI 与上述接口检验通过；未执行新版公开 Release 下载到 CLI 的完整集成，未执行宿主 APK/真机/A1 验收。公开工具发布需单独批准。

### WP-4 · 实施契约（2026-09-08，按用户批准方案）

归属：flutter_patcher/dev 的 flutter_patcher_cli/lib/src/baseline/；版本绑定的详细接口输出在 artifacts 默认分支 tools/kernel_tools。用户应用基线不进入 artifacts Release。WP-4 提供保存/读取能力，WP-5 负责生产真实发布输入，WP-6 负责使用恢复后的基线；不提前声明 A8 的 build 集成或 A1 真机完成。

1. 指纹 v1 编码固定为 UTF-8：`flutter-patcher-baseline-v1\n<app.dill sha256>\n<engine commit>\n<dynamic_interface.yaml sha256>\n<Flutter x.y.z>\n`，对上述字节计算 SHA-256。哈希/commit 为小写 hex；不包含路径或时间。域前缀是格式版本，不增加参与身份计算的构建字段。
2. 基线归档固定包含 app.dill、dynamic_interface.yaml、interface_detailed.json、package_config.json、source_hashes.json、allocate_finalized.json、libapp.so、baseline.manifest.json。仅常规文件，无目录/链接/扩展 tar 条目；拒绝缺失、重复、未知条目、越界路径、非法 checksum、截断与超限解压。M1 主机要求 Linux x64，使用系统 zstd；默认压缩/解压上限 1 GiB，JSON 上限 64 MiB。这些是配置限制，不是产物实测大小。
3. baseline.manifest.json schema=1，字段：fingerprint、flutter_version、engine_commit、build_id、platform、files。platform={path,sha256}，path 固定为 SDK 内 `bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill`；files 为七个载荷文件名到 {sha256,size} 的映射。manifest 不自包含自己的哈希。schema、指纹、文件哈希/大小及详细接口绑定必须重新计算校验。
4. source_hashes.json={schema:1,files:{package:<包>/<相对路径>:<sha256>}}，不接受构建机绝对路径；allocate_finalized.json={schema:1,classes:[<dart:/package:库 URI>::<类名>]}，类标识无重复。实际 trace 采集/解析接入 WP-5；不从空值伪造成功。原 package_config.json 保留用于追溯，不直接作为换机编译配置；WP-6 用当前用户项目解析出的配置做兼容检查。不改写归档 app.dill 中的 URI。
5. merge-interface 增加 --out-details 和 --details-in。JSON schema=1、interface_sha256、entries；每条包含 section、library、可选 class/member、sources、location。sources 是 referenced/protocol/defaults/compiler-hint/platform-privates 的集合；location 为逻辑库 URI、line、column，无法定位为 null。它和 YAML 来自同一规范化集合，保存跨轮来源、排序去重。CLI interface 输出并记录 interface_detailed.json 的哈希。旧工具缺少此能力时明确报错，不在用户端编工具。
6. file:// 指向预先存在的目录；用进程内串行化和跨进程文件锁、临时文件及 rename 实现不可覆盖提交。HTTPS 服务契约：根地址 HEAD 返回 200；GET 对象返回 200/404；带 If-None-Match:* 的 PUT 原子创建成功返回 201，已存在返回 412。不跟随重定向、不接受带凭据/query/fragment 的 store URL。FLUTTER_PATCHER_BASELINE_TOKEN 只用于 Authorization: Bearer，不进日志/归档。不支持条件 PUT 的服务显式失败，不降级覆盖。
7. s3:// 使用 AWS CLI 的标准凭据链，必须支持 s3api put-object --if-none-match。可选 FLUTTER_PATCHER_S3_ENDPOINT 用于兼容服务；不将凭据放到命令参数，不把 AWS 原始错误输出到用户日志。S3 缺失、不可达、条件冲突明确处理。单元/集成测试使用隔离 S3 模拟服务及测试凭据，不等于生产 AWS 账号验收。
8. 归档先成功上传并读回校验，才提交 release-<flavor>-<versionCode>-<abi>.json；侧车 schema=1，记录 fingerprint、flutter_version、engine_commit、build_id、libapp_sha256。默认无 flavor 用 default，M1 abi=arm64-v8a。归档和侧车均不可覆盖；相同内容幂等成功，不同内容报 BASELINE_CONTENT_CONFLICT。同指纹的 build_id/libapp.so 等内容不同也拒绝，并列出差异字段；不改变指纹公式制造循环依赖。
9. 缓存为 ~/.flutter_patcher/baselines/<fingerprint>/；有效缓存命中不拉取。失败 staging 和损坏缓存保留供诊断，损坏缓存隔离后可重新获取。完整验证成功才原子提交缓存。SDK 不匹配不是缓存损坏，不应隔离有效缓存。manifest 哈希用于完整性校验，不宣称具有数字签名认证；签名仍属 M2。
10. 内部服务接口供后续 build/patch 调用。新增高级调试入口 `flutter_patcher baseline --action save|fetch|verify|release`；save 需要 --baseline、--metadata、--baseline-store、--version-code；fetch 需要 --fingerprint，允许 --offline 使用已验证缓存；verify 需要 --baseline；release 检查 --flavor/--version-code 与基线绑定。成功/失败均输出结构化 JSON，失败非零退出。metadata 输入为 schema/flutter_version/engine_commit/build_id/platform，由 WP-5 生成，正常用户无需手填引擎版本。
11. doctor 的显式 baseline 检查升级为文件/清单/指纹/接口详情/SDK platform/引擎 build_id 完整绑定；侧车检查支持全部 store 类型，并实际取回/验证基线。未提供上下文仍标 not_run，不把 doctor 就绪当作 M1 全部验收通过。

历史“约 68 MB”只代表旧 demo，当前真实 WP-5 基线体积为 TBD。独立归档测试使用明确标识的合同测试样本，不把样本的占位 kernel/ELF 当成已构建应用；真实宿主构建和跨机 patch 闭环在 WP-5/WP-6 验收。

### WP-4 · 本地实现验收（2026-09-08）

- CLI Windows：analyze 无问题；53 项通过、11 项 Linux/zstd/S3 环境相关跳过。Linux x64 / Dart 3.13.2：analyze 无问题；63 项通过、1 项非 Linux 主机用例跳过。包含真实 zstd、file store、HTTP 合同服务、真实 AWS CLI + 隔离 Moto S3 服务，以及 CLI save/fetch/offline/失败退出入口验证。
- 同指纹不同 libapp.so、同侧车不同绑定不会覆盖；损坏缓存隔离并恢复；有效缓存零重复读取；错误 SDK 不隔离有效缓存；tar 链接/路径穿越/重复条目/截断/超限均失败。固定指纹向量与 Python 独立计算一致。
- 工具源码 analyze 无问题；10 组接口结构用例通过。真实 Flutter 3.47.2 样本仍为 lean 2 轮（133977 B）、whole 1 轮（8832525 B）；详细 JSON 重复生成字节一致、绑定 YAML 哈希，并通过 CLI validateDetails。此为源码入口开发验证，不是新 CI dill 验收。
- 既有工具流水线 Python 契约测试 23 项通过。新详细接口检查已接入现有 build-tools 的接口 smoke；未运行本次新版 CI，未编译本地工具 dill，未发布 Release。
- 新 CLI 执行 unshare -n doctor --offline：toolchain_ready，network_requests=0。显式提供只有旧四个文件的残缺基线：baseline_files=failed、BASELINE_INVALID、非零退出。
- 选定 stock SDK 的 17572 个常规文件集合与逐文件 SHA-256 全部保持原样。服务器隔离开发目录 /root/.flutter_patcher/wp4-development；CLI/tools 源码及测试文件 SHA-256 与本地逐一核对一致。
- 本地证据：.dart_tool/flutter_patcher/wp4/{windows-tests.txt,cli-linux.txt,tools-test.txt,doctor-regression.json,doctor-invalid-baseline.json,receipt.json,final-checks.log}。未更改插件运行时代码、插件 pubspec、根 README、引擎代码或 workflow；说明只追加到本地忽略 SPEC。
- 公开旧工具 dill 与 tools.manifest.json 已在前一轮按用户要求删除。本次没有 GitHub push/tag/Release 操作；新版工具 CI/发布仍待审核。真实 AWS 账号/生产 HTTPS 服务未测；模拟服务验证不能替代具体生产部署验收。
- A8 的实际 build 失败传播待 WP-5 接入；真实未裁剪基线、libapp.so、trace 类集合的生产及换机 patch/A1 留待 WP-5/6/9。真实应用基线体积仍为 TBD。

WP-4 本地提交：flutter_patcher/dev = 0785a55；flutter_patcher_artifacts/m1.5-restructure = 70e899e。每仓一个提交，未推送。save 显式选择 SDK 时在上传前检查 platform/engine，回归通过。

### WP-5 实现与验收记录（2026-09-08，本地待审核）

归属：flutter_patcher/dev 的 flutter_patcher_cli/lib/src/build/；artifacts 默认分支 tools/kernel_tools 和 tools/release/build_tools.py。插件与根目录文档、用户项目、stock SDK 不改。本轮无 push/tag/Release/CI 触发，服务器仅在 ~/.flutter_patcher/wp5-development 隔离验证。

接口与边界：
1. CLI `build android --strategy bytecode --public-key <raw-base64-Ed25519-public-key-file> --baseline-store <URI>`，支持 --flutter-sdk、--project、--target（lib/ 下入口）、--flavor、--version-code、--out。M1 仅 Linux x64 / Android arm64。默认 strategy=so 明确拒绝进入 v2 bytecode 管线，v1 API 保持原状。
2. WP-2 验证版本与两份 manifest，使用受管平行 SDK。复制应用与递归 path dependencies（含 pubspec_overrides.yaml）到独立构建目录，pub get/Gradle/入口改写仅作用于副本。Gradle 使用工具专用缓存；io.flutter 缓存以 rename 退役并保留诊断，不删除用户缓存。
3. 分离未注解 linked 分析 kernel 与最终 annotated、未裁剪、app-only app.dill。当前固定 frontend_server 普通写出路径即使收到 --no-link-platform 仍链接平台；改由工具 dill 内的 compile-baseline 子命令调用固定 Dart SDK package:vm/kernel_front_end.dart 的 runCompiler，使用 --no-aot --no-tfa --no-link-platform。inspect-build 断言无 dart: 平台库、解析 package roots 并输出可移植源码哈希。用户端只执行 CI dill，无源码编译兜底。
4. extract-surface、gen-protocol-interface、merge-interface 生产最终 YAML；先对归档 app.dill/最终 YAML/Flutter/engine 计算 WP-4 fingerprint，再生成 bootstrap，避免指纹自包含循环。实际宿主编译 dump 留为 compiler_interface.json；interface_detailed.json 保持 WP-4 来源追踪语义，二者不可替代。
5. WP-8 待实现的明确接口：PatchBootstrap.run(original: app.main, fingerprint: _fingerprint, publicKeyBase64: _publicKey)。正式 build 缺失插件/bootstrap 时失败 BUILD_BOOTSTRAP_UNAVAILABLE；不生成空壳运行时。内部测试 harness 可 pipelineValidationOnly，CLI 不暴露该开关；输出 validation.apk、runtime_bootstrap=false，doctor/release 校验明确拒绝其为正式 release。
6. Flutter build 注入最终 YAML、compiler dump、precompiler trace；APK 检查真实 versionCode、applicationId、唯一 arm64 libapp.so，且 libflutter.so 哈希必须等于 engine manifest。trace 按固定 VM 实体表/事件语义解析，拒绝截断、非法引用与空类集合。
7. 基线 manifest schema 2 在 WP-4 七个 payload 基础上加入 compiler_interface.json、build_receipt.json，保留 schema 1 读取兼容。收据绑定 fingerprint、接口哈希、libapp 哈希、APK 哈希、runtime_bootstrap；归档上传及 sidecar 绑定成功后才返回 build 成功并创建最终输出目录。失败保留工作区、阶段日志和 failure.json。
8. 实测修复：WP-2 空 embedding POM 缺少 AndroidX 传递依赖，真实 Kotlin 构建报 LifecycleOwner 缺失；现在从官方 Flutter storage 读取该 engine 坐标的原始 POM，保留依赖并缓存哈希，离线缺失/损坏明确失败。Google Maven 同版本 POM HTTP 404，官方 storage POM 可读取。本阶段继续保留 embedding jar 透传，不新增公开附件。
9. CI 构建工具脚本增加 trace 解析测试，以及用最终 CI dill compile-baseline + inspect-build 的 app-only 冒烟。新增辅助子命令不改变 Release 的精简文件集合。本轮该 CI 冒烟未触发，不能宣称新的工具 dill 已发布或 CI 验收完成。

实测（不把内部 validation APK 当 A1/正式 release）：
- Windows CLI 完整首轮：57 passed / 11 skipped；随后新增 POM 缓存测试及 schema 2 archive 检查，相关 5 项全部通过；analyze 无问题。
- Linux CLI 最终：68 passed / 1 skipped，含真实 zstd 和隔离 S3 模拟服务；工具新增 trace 语义及 6 个非法流检查通过，接口结构 10 项通过，修改工具代码 analyze 无问题；工具 Python 流水线 23 项通过。
- 真实 validation APK：19,121,046 bytes；applicationId=com.example.wp5_fixture，versionCode=1；APK SHA256=3883d1dec5f4ec8f5ac8ef349690f9950129fa7704c68560cb5570b0da7f0b08。Gradle 日志时长 40.6s（仅该阶段，不代表全管线耗时）。
- 独立 app.dill=43,330,792 bytes；734 个非平台库、773 个源码文件；libapp.so=6,685,576 bytes；trace=1,412,655 bytes，解析 2,111 个 allocated 类；compiler_interface.json=256,992 bytes。
- 基线 archive=15,026,445 bytes；fingerprint=f3c10fd9b7afcda545489cf05697101692259e1c6092ef48546172dbd8b443f6；archive SHA256=e154b55f32bc94c0817b51d751b7c063e7e8bb00ef631103dfa742a36c1acdb7。
- 成功工作区：/root/.flutter_patcher/wp5-development/cache/builds/run.pending-371059-1788876631111921；输出 /root/.flutter_patcher/wp5-development/validation-1788876631104285。证据保留 build-4.log、measurements.json、receipt.json。
- A8 关键接线：第二次真实 APK 后注入 store.put 故障，archive 阶段抛 BASELINE_STORE_UNREACHABLE；failure-store 空、成功输出目录总数仍为 1。证据 failure-build.log、failure-verification.json。正式 build 另实测 BUILD_BOOTSTRAP_UNAVAILABLE。完整正式 CLI/A1 需 WP-8 和 CI 新工具产物，尚未宣称完成。
- stock SDK 17,572 个普通文件的完整清单及 SHA256 与 WP-3 保存清单一致。未修改 SDK，未修改用户工程或插件 dependencies。

审核后后续条件：用户决定何时同步/触发 artifacts CI 构建新工具 dill；WP-8 实现上述 bootstrap API 后再执行正式宿主构建与真机验收。当前原始工具 Release 缺失不会走本机编译兜底，而是明确失败。

本地提交：flutter_patcher/dev f9b87a5；flutter_patcher_artifacts/m1.5-restructure 59dcd0e。两仓 git status 干净；SPEC 按既定规则位于忽略的 plan/，不强制 git add。
验证命令：CLI `dart analyze`、`dart test --reporter expanded`（Linux 通过 wp5-development/run-linux.py 启动隔离 S3 测试服务）；artifacts `python -m unittest discover -s tools/release/test`、`dart test/build_inspection_test.dart`、`dart test/interface_test.dart`。真实构建由 wp5-development/build-harness.dart 调用生产 BuildPipeline，WP5_FAIL_STORE=1 注入归档故障、WP5_FORMAL=1 检查缺失 bootstrap。`dart bin/flutter_patcher.dart baseline --action release --baseline-store file:///root/.flutter_patcher/wp5-development/store --cache-dir /root/.flutter_patcher/wp5-development/release-check --flavor default --version-code 1` 实际 exit 1 / BASELINE_NOT_RELEASE，确认 validation 产物不能作为正式 release 使用。本机 wp5/compare.py 比较服务器 receipt 中源码 SHA256 与本地文件，无差异。

### WP-6 · 实施契约与开发验收（2026-09-09，本地待审核）

归属：flutter_patcher/dev 的 flutter_patcher_cli/lib/src/patch/；artifacts/m1.5-restructure 的 tools/kernel_tools 与 tools/release。仅本地提交；服务器 ~/.flutter_patcher/wp6-development 是隔离开发验证目录。本轮没有 push、tag、Release 操作或 CI 触发，不改插件 dependencies、根 README、用户项目或 stock SDK。

实施契约：
1. CLI `patch android --strategy bytecode --fingerprint <sha256> --seq <n> --version-code <host-code> --private-key <base64-seed-file> --baseline-store <URI>`；支持 project/target/out、previous-seq、offline 及 SDK/cache 选项。M1 主机 Linux x64、目标 Android arm64。默认 so 不进入 v2 管线；用户只运行 CI 产出的工具 dill，缺失/旧工具明确失败，无用户本机编工具方案。
2. 按 fingerprint 恢复不可变基线，重新校验文件、指纹、platform、Flutter/engine、正式 bootstrap 标记及目标 versionCode。签名公钥必须匹配 build receipt。只允许内部 harness 使用 validationOnly，CLI 无绕过开关；对应输出为 validation.fptc，状态 patch_pipeline_validated，明确 device_verified=false、release_baseline_verified=false。
3. WP-5 build receipt 新增 package_inputs：逐包版本、规范化 pubspec 哈希、native 标记、原生目录/hook 文件哈希。用于区分 Dart 依赖升级和必须重发宿主的原生变更；应用原生代码变化、新原生插件或插件/hook 变化均拒绝。已有正式基线若缺此来源信息，须重建宿主，不推测兼容。该 WP-5 小范围接线是 WP-6 安全判定的前置数据。
4. 在隔离副本执行受管 Flutter pub get --enforce-lockfile，offline 时禁止联网解析；比较基线源码哈希、包集合及来源信息。应用包与新纯 Dart 包别名为 patch.<seq>.<name>；既有宿主包在 lean 复用。仅改写 import/export/part 的 package URI，不改运行时字符串。转义/插值 URI 显式拒绝；编译后再次拒绝指回原应用包的依赖。原工程与基线完成后再次校验。
5. compile-patch 用固定 Dart SDK 的 CFE 构建带源码位置的同一 Kernel，一次收集接口、分配、继承成员和条件资源形状结果。普通语法错误为 compile_failed，不误当升档。CFE 隐式 super() 无 offset 时，仅在同 Kernel 唯一匹配到声明时补定位并标注 location_kind；不伪造位置。
6. 分配检查覆盖 generative 调用、super/redirect initializer、constructor tear-off、嵌套常量图；按补丁 VM 语义不将 factory 引用当 generative 分配。继承检查结合基线 YAML 语义与真实 compiler_interface.json 的 callable 集合，检查可跨库访问的公共继承成员；不把私有继承成员误报为可调用公共面。分析可输出完整 linked 的 <tier>-analysis.dill，供独立 check-allocations/check-inherited 重放；它不是模块发布产物。
7. lean 不满足、既有纯 Dart 依赖变化或资源形状要求时自动尝试 whole。whole 仅使用基线中 dart:* 接口，不执行 WP-3 的接口扩张。TFA 前在内存中保留外部 platform 的类/成员，满足字节码生成器的 intrinsic 查找；这是编译保活，不扩张宿主接口，不把平台编入模块。TFA 后重新检查分配和入口；仍不安全则 PATCH_UNSAFE，保留两档证据。
8. 自动生成带双 pragma 的 dynamicModuleEntrypoint 和六槽 literal List。校验固定 SDK 将 List literal 降低成 _GrowableList._literal6 的实际 Kernel 形态与版本/seq/fingerprint/tier。生成 bytecode 后使用真实解析器核对库 URI、模块入口、无 source positions；不用字符串扫描冒充结构检查。
9. WP-7 未完成前，声明 assets/fonts 的项目或补丁中的 IconData 常量不得进入最终打包，返回 PATCH_RESOURCES_UNAVAILABLE；若更早检查失败则先返回该明确失败。未变更 Dart/依赖的输入返回 PATCH_NO_CHANGES。资源和字体不被静默丢弃，不宣称资源补丁已完成。
10. module.bc 与 patch_manifest.json 组成 STORED ZIP；FPTC 头 146 bytes，Ed25519 签名覆盖头前 82 bytes 和 ZIP。OpenSSL 私钥 DER 仅走 stdin，不落盘；签后立即用派生公钥验证。输出 patch.fptc + patch.json，记录最低宿主 build、序号、tier、哈希、检查证据。已有输出拒绝覆盖，失败保留隔离工作区与阶段日志。previous-seq 可约束生产序号，设备端防回滚仍由 WP-8 实现。

实测记录：
- Windows CLI：analyze 无问题，62 passed / 12 skipped。Linux CLI：73 passed / 1 skipped，包含真实 OpenSSL 签名、错误公钥及篡改拒绝、zstd 和隔离 S3 服务回归。
- 修改的工具源码及分配测试 analyze 无问题；生成式构造/常量图/factory/源码位置测试通过。Python 工具流水线契约测试 23 项通过。
- WP-5 真实 validation 基线上的生产 PatchPipeline：lean module.bc 4,541 bytes；validation.fptc 5,325 bytes，SHA256=cb27e3a530064021e2c1e251a093721cd3d3b9e59d9b8fc81c1b29b7ef00506d。四检为空，两个模块库均为 package:patch.1.wp5_fixture/，独立结构检查 forbidden=0、source_positions=0；独立 allocation/inherited 检查均为空。
- 上述基线 fingerprint=f3c10fd9b7afcda545489cf05697101692259e1c6092ef48546172dbd8b443f6；最新验证工作区 run.pending-377737-1788884952142103，输出 validation-1788884952136026。此基线 runtime_bootstrap=false，仅证明补丁构建与封装路径，不是正式宿主或真机验收。
- 共享 CI 冒烟函数通过源码入口实跑：显式小型宿主接口合同下，lean 719 bytes、whole 720 bytes，均实际解码通过；错误入口 seq 非零退出且无产物。联合故障样本一次返回 interface 12 条、allocation 4 条、inherited 11 条、资源 INJECTABLE_HOLE，均带对应源码位置。该小型 whole 冒烟不等于完整 Flutter whole 应用真机通过。
- 真实旧基线上的 collection 变更触发 whole 后，因既有 dart:* 接口不足而 PATCH_UNSAFE，未扩张接口或输出成功补丁。正式模式使用 validation 基线返回 BASELINE_NOT_RELEASE；无变更输入返回 PATCH_NO_CHANGES。
- 固定 stock SDK 17,572 个常规文件的集合与逐文件 SHA256 全部保持原样。服务器 CLI/kernel_tools 源码、测试及 pubspec 与本地 SHA256 核对无差异。本地证据 .dart_tool/flutter_patcher/wp6/{windows-tests.txt,receipt.json,final-checks.json,final-checks.log}；完整实验日志保留于服务器 wp6-development。

验收边界：build-tools 已接入上述字节码/四检冒烟，但本轮未运行 CI 生成新版工具 dill、未发布新版工具。WP-7 资源字体、WP-8 bootstrap/设备验证、正式宿主到补丁的 A1 闭环仍待对应工作包；不能将本轮源码执行的内部 validation 结果视为 M1 完整验收。性能、完整 Flutter whole 成功与真机指标 TBD。

WP-6 本地提交：flutter_patcher/dev cfa0cc8；flutter_patcher_artifacts/m1.5-restructure d387e44。SPEC 位于忽略目录，不强制加入 Git。

### WP-7 · 实施契约与开发验收（2026-09-09，本地待审核）

本节按用户批准的 WP-7 方案补充旧规范。插件实际位于仓库根 lib/、android/，不搬目录。代码归属：flutter_patcher/dev 的 lib/src/bootstrap/{overlay,fonts}.dart、flutter_patcher_cli/lib/src/patch/；artifacts/m1.5-restructure 的 kernel_tools、release/resource_smoke.dart 和 dart2bytecode_patches。说明只写本地忽略 SPEC；本轮不 push/tag/Release，不触发 CI，不改插件 dependencies。

1. 资源来源是隔离副本执行受管 Flutter `build bundle --release --no-pub --target-platform android-arm64` 的真实 bundle，不能从 pubspec 猜测图片变体/包资源。patch --assets 支持逗号分隔或重复选项；省略时自动选择变更资源。保留原始资源键与 packages/<pkg>/ 前缀，不随模块 URI 改名。指定键必须是 AssetManifest 中的逻辑资源键，连同所有图片变体一起携带。
2. WP-5 收据新增 resources={schema:1,files:{key:{sha256,length}},manifest:{...}}，数据从实际 APK 的 assets/flutter_assets/ 读取。已有正式基线缺少资源来源信息时要求重建宿主。资源单独变更参与 patch 判定，不再只比较 Dart 哈希。只有源码、依赖和资源均未变更才 PATCH_NO_CHANGES。
3. 解析 Flutter AssetManifest.bin 的受限 StandardMessageCodec 数据类型，拒绝截断、额外字节、重复键和过深/过大集合。选择资源后合并基线清单与选中资源的当前条目，避免未选中的新资源误入清单。删除逻辑资源或已有变体返回 PATCH_ASSET_DELETE_UNSUPPORTED；不把缺失当成删除操作。
4. 插件 overlay 是模块辅助源码来源。CLI 从当前 flutter_patcher 依赖复制到模块的保留文件 __patch_overlay.dart；用户占用此文件名时拒绝覆盖。辅助类及状态属于模块，lean 继承宿主框架类型，whole 随模块框架一起编译，避免两套 AssetBundle 类型混用。安装复制输入字节，读取优先补丁、未命中回退安装包；支持 load/loadBuffer、字符串/结构化缓存，重装清空缓存。
5. lean 对全部有效 runApp/runWidget 注入点包装 DefaultAssetBundle；生成 helper 不参与业务形状检测。helper 源码中的 patcherWrap 使变换引入的同一 constructor/helper 引用提前进入 CFE 校验，变换后运行 allocation/inherited 检查并核对注入数量。不能满足宿主条件时尝试 whole，不扩张宿主接口。
6. whole 在内存 Kernel 中把框架 rootBundle 原始 initializer 包入 patcherWholeBundle(original)，保留真正的 PlatformAssetBundle 回退而非递归调用自身。覆盖层引用稳定资源表，因此 rootBundle 在安装前初始化也能在安装后看到新字节。whole 的 TFA 生成库 dart:mixin_deduplication 归入 package:patch.<seq>.__vm/mixin_deduplication.dart，检查名字冲突；其他异常 URI 仍拒绝。
7. 两档携带资源时，PatchEntry 第六槽均为 `void Function(Map<String, Uint8List>)` 的安装函数；无资源时为 null。此条覆盖旧补丁包规范中 whole 第六槽恒 null 的陈述：编译期替换不等于资源字节会自动进入模块。WP-8 负责验签/归档检查后传入已验证字节，在进入 patched main 前等待字体加载。WP-7 不增加 bootstrap、不调用 ensureInitialized 或 FlutterPatcher.init。
8. Kernel 常量图输出全部 IconData 的 codePoint/fontFamily/fontPackage/fontFamilyFallback；非 const IconData 明确拒绝。固定 SDK 的 Icon 使用 inherit:false；fontFamily=null 的系统符号继续走系统字体，不误报缺少 bundled font。显式 fallback 对应的 bundled 字体完整保留。
9. 对 SDK 专用 MaterialIcons face，按本档全部引用码点分组调用同版本 font-subset，失败/缺失/空输出均拒绝。自定义与包字体可能同时用于普通 Text，保守完整携带，不根据 IconData 集合误裁剪文本字形；其 family（含包前缀）保持原样。完整携带是安全策略，不宣称这些字体已裁剪。FontLoader 按 family 一次加入所有 face 再 await load，交由 WP-8 在 patched main 前调用。
10. 资源与字体写入既有 STORED ZIP；manifest 逐项记录 path、length、sha256，字体另含 family、subset，裁剪字体包含 codepoints 数量。fonts 路径以 family/face 的哈希命名，避免 family 成为路径；assets 路径严格为 assets/<key>。拒绝非法路径、重名、未列条目、键/路径或哈希不符。生产上限：总原始载荷 256 MiB、单条目 64 MiB、ZIP 条目数 4096；这些是限制值，不是体积实测。FPTC 签名覆盖所有新条目。
11. 固定 dart2bytecode 写出器对 FFI native 函数合法写 null nativeName，而读取器强制 ObjectHandle 非空导致完整 whole 结构检查失败。新增 0002-nullable-ffi-native-name.patch 只修正读取器的 nullable 类型，保持原字节码协议和严格结构检查。原 SDK 与原 Dart 源码均未修改；开发验证使用 wp7-development/dart2bytecode 副本，CI 构建按现有脚本应用补丁。
12. 真实测试发现 path dependency 副本的 pubspec 已改路径，但 lockfile 未跟随。BuildWorkspace 现在仅重定位副本锁文件中的 path description，保持版本与其他锁定字段不变，继续 enforce-lockfile；原项目不动。这是 WP-7 插件辅助代码接入所需的既有隔离构建修复。

实测：
- 插件 Windows 全量 30 项通过，包含真实裁剪字体交给 FontLoader、load/loadBuffer、回退、复制字节、安装前创建 whole bundle、重复安装清缓存。CLI Windows 全量 66 passed / 12 skipped；Linux 全量 77 passed / 1 skipped。后续字体 system fallback 与资源/封装相关用例复核通过；analyze 最终单独核对。
- 工具分配/常量图/源码位置测试通过；Python 流水线契约测试 23 项通过。共享 resource_smoke 已接入 build-tools，使用源码工具入口实跑两档成功；本轮没有 CI 编译/发布新版工具 dill。
- 共享编译冒烟使用显式声明的测试宿主合同（包括 platform 私有项），不是修改真实发布基线。lean 字节码 5,930 bytes、2 个模块库、2 个注入点；whole 2,012,908 bytes、450 个模块库、rootBundle initializer 替换成功。两者均通过真实字节码解析，入口存在、无源位置、模块 URI 符合前缀。
- lean MaterialIcons 子集：2 个码点（58136、984413），1,204 bytes；独立解析 OTF cmap 验证两个码点均存在，Flutter FontLoader 实际加载成功。子集 SHA256=901944d011f1fb3931c48ef24c1148a2aa4a7897484d128dbb716b8495587e31。
- lean 模块、上述字体与一项资源组成的签名包：8,533 bytes；SHA256=8c5d5640658b180be639c65114fbea33691aefdee8e884dce36204ab3ed291ea。真实 OpenSSL 签名并验证成功。
- whole 扫描到 5 个 MaterialIcons 码点及 1 个系统字体符号；实跑 MaterialIcons 裁剪为 1,400 bytes，SHA256=81c58db381722a6a324b952389688ca19d1aafd92459a3eedaaac0a5b463482b；packages/cupertino_icons/CupertinoIcons 保留完整字体 257,628 bytes。
- 真实 validation APK：19,154,214 bytes，资源收据记录 8 个文件。指纹 131a9dce0c203429b77850f9b0b0aa68fdb2d551176b51d3039e52b51ee6c2e4。隔离 store 未预建时归档明确失败；补齐 store 后用生产 BaselineRepository 保存并恢复已有真实基线，不重造 APK，也不把原失败 build 宣称为成功输出。
- 在该真实基线上只新增资源，实际进入资源检查及自动升档；因宿主未保留所需接口而 PATCH_UNSAFE，未输出成功补丁。该案例证明资源独立变更与安全拒绝接线，不能充当资源补丁端到端成功。
- 服务器验证目录 ~/.flutter_patcher/wp7-development。SDK 17,572 个常规文件清单与逐文件 SHA256 保持原样；工具/CLI 源码与本地按 receipt 核对。证据归入本地忽略 .dart_tool/flutter_patcher/wp7/，包括 measurements.json、whole-fonts.json、receipt.json、windows-final.txt、plugin-tests.txt。

验收边界：WP-7 的资源/字体准备、Kernel 变换、读取与封装已做开发验证；真实宿主到设备冷启动的 A6/A1 尚未完成。WP-8 必须把所需运行时/覆盖层能力保留进正式宿主，接入本文安装函数和字体加载时序，再用该正式基线验证两档真机生效与自定义 binding。真实设备内存、启动性能及最终补丁大小 TBD。本轮保留全部失败实验与原路径，不执行清理或远端发布。

WP-7 本地提交：flutter_patcher/dev bc57ba4；flutter_patcher_artifacts/m1.5-restructure 0de7f88。两仓 Git 工作区干净；CLI 与修改的工具源码 analyze 无问题，源码 SHA256 核对无差异。SPEC 保持 Git 忽略，不强制加入。上述 256 MiB 限制具体为模块与资源原始字节合计，不含清单自身。

### 10.5 WP-8 实施口径（本轮审核）

1. 代码归属不变：flutter_patcher/dev 放插件原生/Dart 引导和 CLI 构建接线；artifacts 的现有分支放版本相关的宿主接口保留逻辑。本轮只在本地提交，不 push、tag、发布或触发 CI；GPU 的工作限于独立 wp8-development 验收沙箱。
2. 新增 PatchBootstrap.run(original, fingerprint, publicKeyBase64, loadModule)。CLI 在隔离构建工作区生成 SDK 白名单包 dynamic_modules，以 loadModule 回调调用 dart:_internal.loadDynamicModule。临时 package_config 同时用于 build/patch；不修改用户 pubspec、插件 dependencies 或用户 SDK。无指纹的稳定分析入口先生成基线，再把最终指纹烧入 APK 入口，避免指纹自引用。
3. bootstrap 用 PlatformDispatcher.sendPlatformMessage 和 StandardMethodCodec 发送 bootPayload，3 秒超时或缺少处理器即走原 main；迟到的 offer 不会调用模块加载。不得 ensureInitialized 或 FlutterPatcher.init。原应用/模块自己的 binding 仍负责初始化。
4. bytecode 使用独立 filesDir/flutter_patcher_bytecode 和 SharedPreferences；不复用 v1 SO 元数据。applyPatch / applyPatchBytes 显式 strategy=bytecode 才进入此路径，PatchInfo 可携带 sha256、fingerprint、patch_seq。字节码严格要求 Android API 33+ 的系统 Ed25519，低版本拒绝安装/加载，原应用照常运行；插件整体 minSdk 不变。v1 的 strictSignature=false 不能放宽 v2 验签。
5. 原生按实际读取上限限制内存，不按未验证 payload_len 分配；依次验证长度、FPTC magic、版本、指纹、payload SHA256、Ed25519。签名覆盖前 82 bytes 和 payload，签名自身位于 82..146；使用宿主嵌入的 raw32 公钥验签。bootPayload 使用 native-bytes-v1 返回 transportVersion=1、同一已验签内存快照 envelopeBytes 和随机 attempt；Dart 不再按路径重读，不重复计算完整文件或 payload SHA256。native 仍检查完整文件摘要与持久候选身份一致。Dart 只接受该版本及 Uint8List，继续检查 envelope 字段、ZIP 和清单一致性；旧路径协议拒绝并回原应用，不降级。
6. ZIP 读取器由插件实现，只读 STORED，检查本地头与中央目录一致、CRC、边界、重复条目、路径、普通文件类型和条目数量；禁止描述符、zip64、加密、目录及额外未列条目。清单与封装头、模块/资源长度和 SHA256 一致后，检查固定 SDK 的 DBC3 magic。入口必须恰为六槽，整数/字符串类型、版本、seq、指纹、tier、无参 main 和安装函数逐项检查。
7. 当前已接受的相同 fp/seq/SHA256 可重复冷启动与幂等安装；新候选 seq 必须严格超过按指纹分组的持久 high-water mark。rollback、熔断和 clearBlacklist 均不降低该水位。被隔离候选移除活动指针，原始候选文件保留且不可再选中；本阶段不做旧文件清理。
8. markBooting 用 attempt 显式握手，offer 本身不启动模块尝试。首帧由 Android FlutterRenderer 回报并绑定事件发生时的 attempt，避免 whole 档 Flutter binding 与宿主 binding 分离的问题。旧 init 的无 token 成功回报不能清 v2 状态；用户 init 的 Dart 错误回报只能绑定当前有效 attempt。重复失败只计一次，失败后的原应用首帧不能清失败记录；持久失败计数与消费上次 attempt 同一次 commit。
9. 入口验证后安装认证资源，等待字体加载，再调 patched main。进入 main 前且未开始字体注册的失败可以调用原 main 一次。字体开始注册后可能已有不可撤销的全局变化；此时以及 patched main 已开始后的失败，禁止同 isolate 再启动原 main，隔离候选，下一次冷启动走原应用。后到的严重失败可升级隔离状态但不重复计数。普通前置失败沿用 maxCrashCount；系统退出原因复用 CrashGuard 分类。bootstrap 的 Dart 错误观察在 main 返回后保留 5 秒，再停止，且不覆盖用户后来安装的错误钩子。
10. 正式宿主接口在构建阶段保留 bootstrap/overlay 的真实依赖、AssetBundle/CachingAssetBundle 构造与继承方法、whole 所需平台公共/私有接口及类。补丁端仍只使用冻结的基线，不能为了通过校验临时扩大接口。工具 CI 必须使用本轮 artifacts 源码构建新 dill 后才能交付公开 CLI 链路；本轮源码 harness 不是用户端本地编译方案。
11. 进入 patched main 前超过本档预算（lean 85 ms、whole 200 ms）记录 BYTECODE_BOOT_SLOW，并包含 tier 和 budget_us。真机耗时、峰值内存、两档界面和资源实际生效、Android API 33 系统 Provider、进程终止后的持久状态回放仍需设备验收，当前为 TBD；WP-9 完整故障矩阵不在本轮冒烟结果中冒充完成。

WP-8 最终验收记录：

- 本地提交：flutter_patcher/dev `c7f8964`；flutter_patcher_artifacts/m1.5-restructure `0b2ca17`。两仓 Git 工作区干净，SPEC 继续忽略。没有 push、tag、release、CI dispatch；没有修改根 README、pubspec dependencies 或清理旧目录。
- GPU 最终证据：`/root/.flutter_patcher/wp8-development/` 的 `build-final9.log`、`final9-patch-lean.log`、`final9-patch-whole.log`、`native-final9.log`、`plugin-final9.log`、`measurements.json`、`source-verification.json`。对应记录已复制到本机 `.dart_tool/flutter_patcher/wp8/`。此前沙箱包解析曾误指 WP-7，自引用已纠正；旧构建保留，不计作最终 WP-8 验收。
- 固定 Flutter 3.47.2 / Dart 3.13.2：正式构建 `runtime_bootstrap=true`，基线指纹 `6abc932c175ef7670755ea542e6fd048ca5ce6dbb06bc0e84db3ede11fbae437`，接口 SHA256 `b07848b6ba830fb0d89e47c32c66edaade6b22f29c7318a2019880d6db1b5cf1`。APK 实测 **24,987,116 bytes**，SHA256 `7af5d69d611477095ea3ef0756a0d799bc35e616f632407b3cc0a3b728246e48`。APK 位于 `validation-1788890308420214/app-release.apk`；此目录沿用旧 harness 前缀，实际产物和 receipt 均为正式构建，不是 validation.apk。
- 文本与资源改动保留 lean：FPTC **266,485 bytes**，module.bc **6,851 bytes**，SHA256 `1a94f71b7cbcc59c23af7129b37889470b75f20ff7db35e0bca0057c9632f647`。增加纯 Dart 依赖自动 whole：FPTC **2,376,493 bytes**，module.bc **2,115,305 bytes**，SHA256 `53ec0754186b8882061be622848774baf0b723063b94a22117f1b0d8fe8d6d99`。两者检查均通过，均携带变更资源和所需字体，签名由 OpenSSL 复核；最终插件只读读取器验证通过，修改签名字节但保留旧完整文件凭证时均拒绝。
- Linux JIT 单次归档验读量测为 lean **89,212 μs**、whole **288,767 μs**，仅用于记录开发环境开销，不是 Android AOT 冷启动成绩，也不能据此宣布 70–85 ms 预算达成。设备端预算仍待验收。
- 最终插件测试 **42 passed**（含真实 subset FontLoader、裸平台消息后应用自定义 binding、超时迟到不加载、入口类型拒绝、异步失败后不继续 main、失败不被首帧覆盖）。Android JVM 测试 **25 passed**，含 OpenSSL/RFC 8032 公钥互操作、头/payload/签名篡改、attempt 幂等与既有 v1 回归。CLI Linux **78 passed / 1 skipped**；Windows **67 passed / 12 skipped**。工具 Python **23 passed**；接口结构 **10 cases**、allocation/常量/factory 与 build-inspection 非法 trace 组通过。CLI analyze 无问题；插件 analyze 无 error/warning，有 info 级风格提示。
- 本地与 GPU 的 **25 个变更源码文件 SHA256 全部一致**，工具自身 package root 明确指向本轮 wp8-development。原始 Flutter SDK 快照的 **17,572 个既有文件 SHA256 全部一致**。
- `adb devices -l`（本机）和 GPU `adb devices` 都没有设备。本轮不能宣称 A1/A6 真机闭环、API 33 系统 Provider、杀进程后的实际熔断/回滚或启动性能验收完成；新版工具 dill 也没有构建发布到 GitHub。下一步先审核本地提交，再安排设备与 CI 产物验收，不自动进入 WP-9。

### 10.6 WP-9 · 实施与验收口径（2026-09-09）

本轮经用户批准实施全部 WP-9。代码、离线集成和设备验收分别记录；缺少设备、独立主机、人工字体审查或体积阈值时，不把整个 M1 标为通过。

1. 代码仓沿用 `dev`，新增 `test/acceptance/`、Android JVM 故障库消费者与 `.github/workflows/test.yml`；artifacts 仓增加 `tools/release/fault_modules.py`，由现有 build-tools 使用 CI 编译的单 dill 编译故障入口，并补齐引擎前置断言的失败用例。故障模块、测试密钥、APK 和故障包不进入 artifacts Release。
2. `corpus.py` 从真实 lean/whole 补丁派生封装、归档、入口与持久状态样本。归档/入口样本重新计算封装哈希并用专用测试密钥签名；必须先通过原生外层验签，再到达目标拒绝层。编译模块的 fingerprint、seq、tier 及文件大小/哈希必须与控制补丁匹配，拒绝拿不同基线或序号的错误入口冒充槽位校验。除了 SPEC 最低清单，还覆盖重复 ZIP 条目、CRC、加密标记、符号链接、条目数量与单条目大小限制、相等序号重放和更低序号。
3. 错误入口包含缺槽、槽 4 非函数、main 抛错、main 挂起。挂起样本在设备上用 Android `am crash` 终止实际应用进程，再次启动并检查两次冷启动内的隔离；不把 force-stop 当作崩溃。有效补丁必须能加载，活动相同补丁必须能幂等安装，撤回后高水位不得降低，隔离后的原候选必须被拒绝。
4. 新增 `publish --out <本地目录> --patch <FPTC> --version-code 1`、`publish --action serve --out <目录> [--port 8765]`、`publish --action withdraw --out <目录>`。仅实现 M1 本地 mock，服务绑定 IPv4 loopback。按 SHA256 保存不可变 payload，原子替换 current.json；设备负责真实信任校验，staging 的结构/哈希检查不等于验签。撤回字段由专用验收应用显式调用现有 rollback API，不扩展 M2 生产服务端协议，不改旧 `bin/mock_server.dart`。
5. `integration.py` 分为独立的 build/patch 阶段，正式 CLI 构建、归档、恢复和生成补丁。两端记录代码 commit、Flutter/Dart/engine 身份与 machine-id；同一机器不同缓存目录只算隔离缓存开发验证，不算 A1 换机。普通 binding 应覆盖 lean 与新增纯 Dart 依赖后的 whole；自定义 binding 继承面不足时按既有四检自动升 whole，不能把这一场景宣称为 lean。资源从 DefaultAssetBundle 读取；补丁分别更改文本、资源及 MaterialIcons 字形。
6. whole 回归暴露插件只读归档校验器的动态 JSON `[]` 调用不被工具接受。修复为通过原校验后显式转换到 Map/List，保持原拒绝条件，不扩大 dynamically-callable 白名单、不放宽四检。BootRunner 增加 `BYTECODE_BOOT_TIMING`，记录 bootPayload、验读、握手/模块加载、资源与入口校验及进入 patched main 前总时间；原 85 ms 告警保留。
7. `device.py` 仅允许重置专用 `com.example.wp9_acceptance`。有效控制走实际新 CLI mock 服务，故障包走只读故障服务；通过生产 API 安装并跨进程冷启动。保存逐项安装结果、界面状态、当前进程计时、logcat、Android exit-info 及修改前后截图；任一错误拦截层不符、无首帧、原生崩溃、失去自定义 binding 或错误候选再次获准安装即失败。API 33 以下的明确拒绝单独记为 compatibility scope，不能替代完整 arm64/API 33+ 矩阵。`legacy.py` 对普通 SDK APK 检查原 v1 SO 下载/启动/撤回；FontLoader 单元验证与截图人工确认分别记录。
8. 设备每种有效控制重复冷启动采样；Android am start TotalTime 与 bootstrap 分段微秒数据分开，不把前者或 Linux JIT 时间当作 bootstrap 成绩。`empty_size.py` 额外构建仅 `SizedBox.shrink()` 的匹配空应用对照；带 HTTP 验收控制器的应用大小不作为空应用预算。`size_gate.py` 未给审核过的阈值时返回非零并记录 not_run；CI 明确提示阈值待审，超已定阈值失败。
9. CI 从 artifacts 的 supported_versions.txt 派生版本矩阵，artifacts commit 必须由 `WP9_ARTIFACTS_COMMIT` 固定。hosted 快速层包含插件、CLI、真实 zstd/隔离 S3、原生 JVM、Python 与 workflow 结构检查。专用 Linux `wp9-build`、`wp9-device` runner 分别执行两阶段，并要求独立 machine-id；绑定矩阵为 standard/custom。设备任务仅受信任 dev push（显式开启 `WP9_DEVICE_CI`）或手动 full_acceptance；PR 只进入 hosted 层。用户须配置受保护的 `wp9-acceptance` environment 与 runner 访问规则。所有 Release/tag/push 保持禁止，本轮不触发 GitHub CI 或发布。
10. runner 通过 `WP9_RUNNER_CONFIG` 指向本机配置，示例在 `test/acceptance/runner-config.example.json`。两端需可达相同基线仓库与共享 evidence 路径；serial 为已授权 arm64/API 33+ 设备，lower_api_serial 可供额外兼容性检查，size_threshold_bytes 在实测后审核。每次 run/version/binding 使用独立目录与基线前缀，保留历史输入与失败证据。测试工程限制 Gradle 堆/worker 并禁用 daemon，防止独立缓存累积大堆；这些是测试配置，不是峰值内存量测，也不改变用户工程。
11. `repeat_pair.py` 单独验 A10：两个独立 build_id、已有引擎 comparator、各自 doctor 成对检查、相应 APK 哈希、完整设备故障库及独立主机证据全部吻合才能通过。普通设备 CI 的 scope.json 不自动宣称 A10 或完整 M1 完成。

本轮最终实测记录待验证命令结束后填写。早期目录和失败日志全部保留：源码传输排除规则曾漏掉 CLI 的 build 源码；控制样例曾在 runApp 前读 rootBundle 导致升档；自定义 binding 构建曾被内核 OOM 终止。修正后以新的独立目录重跑，不把旧失败构建或不同身份的错误入口计入最终验收。

补充待确认：§4.4 列出的 `keys init` 仍是显式未实现入口，本轮批准的 WP-9 计划只补本地 mock 发布，没有增加生产密钥管理。验收应用使用公开 RFC 8032 测试密钥；该用例不能替代生产密钥初始化功能，也不能据此宣称 §4.4 的所有 CLI 命令已经交付。

已完成的最终工具验证：artifacts commit `8c8b772946e4fe06df4e6dd69fb5649df319db9f`，执行现有 `tools/release/build_tools.py`，A11 两轮快照/manifest 一致与全部工具冒烟通过，耗时 **274.57 秒**。单 dill **37,308,048 bytes**，SHA256 `a69fa91a912698645afe1542bfcabe541b92e58ca5ca511f79a38496a638e078`。证据为 GPU `wp9-development/tools-sealed.log`、`tools-sealed-work/verification.json`、`tools-sealed-output/tools.manifest.json`；后两份已复制至本机 `.dart_tool/flutter_patcher/wp9/`。这是本地执行相同构建入口的验证，不是一次已触发的 GitHub Actions 或公开 Release 发布。

续跑记录：最终验收用例代码提交为 `7b3f451`。曾尝试在 lean 中新增 `Icons.settings` getter、随后直接写 `IconData` 构造函数，两者均被基线动态接口拒绝并自动升 whole；没有放宽生产检查。最终 lean 保留已有图标并重新打包其字体子集，whole 使用新增 `Icons.favorite` 字形。前者不宣称验证了 lean 新增 SDK getter/构造函数；新增字形覆盖在 whole。失败证据分别保留在 `sealed-standard-patch` 与 `resumed-standard-patch`，最终续跑使用独立 `verified-*` 目录。

WP-9 续跑已确认结果（2026-09-09；非完整验收）：
- 代码仓 `dev` 提交 `7b3f451`；artifacts 提交 `e12c2cf`。当前 Codex worktree 为 detached HEAD，指向同一代码提交；未创建新的开发分支。两个原始本地仓库均干净，未 push/tag/Release。
- 普通 binding 的正式 build、归档、独立缓存恢复、lean/whole patch、mock 暂存与撤回命令均通过。基线指纹 `14fd96f7f8aa38d0cdffde2544090a279a1f700e92bc03f086d75d70899eab07`；同机验证 `independent_machine=false`，不计 A1 换机。
- lean 补丁 11,402 bytes，SHA256 `d6eed0d0f2351da7273696de5d4724bf955307043151d91cce9cb73582934339`；whole 补丁 2,163,869 bytes，SHA256 `cba5f1dfe31dd57f973ac5f9e472d3c809e0aa2299f0d6baf406b10e4a40881a`。
- 真实控制补丁生成故障库共 31 个样本。Dart 归档/入口保护检查 18 项通过，Android JVM 任务 BUILD SUCCESSFUL；本轮未取回最终 XML 计数，不填写未经核对的数量。设备实际加载与故障进程恢复未验证。
- 故障模块最初使用完整基线接口导致编译器查找未加载的 Flutter Animation 类失败。artifacts `e12c2cf` 改为只取原接口中的 dart: 条目，不增加权限；修正后的四个故障模块编译、corpus、Dart 和 JVM 消费全部通过。失败目录 `verified-standard-modules` 保留，成功目录为 `verified-standard-modules2`，不要混用旧 .exit。
- artifacts 最新源码的本地工具 Python 测试 23 项通过。`tools-final` 全构建复验已启动；此前 `tools-sealed` 的 A11 结果只归属于 `8c8b772`，不可直接写成 e12c2cf 的结果。
- 自定义 binding、空应用体积、最终插件/CLI 回归、SDK 最终哈希复查由 GPU `verified_continue.py` 顺序执行，记录在 `verified-continue.log`、`verified-*.exit`、`verified.done`。工具最终复验为 `tools_final.py`，日志 `tools-final.log`。续接时 SSH 多次 banner exchange 超时，无法确认这些后台任务的最终状态，均记为结果待取回；不要重复启动或覆盖现有目录。
- 仍缺 Android arm64/API33+ 设备、独立第二 Linux 主机、字体人工审查与空应用体积阈值。A10 两次引擎构建对应的设备闭环、完整 M1 验收尚未完成。

SSH 恢复后最终取证（2026-09-09，替代上文“结果待取回”状态）：
- `verified.done` 已生成。standard/custom 的 build、patch、modules2、corpus、Dart 和 JVM 阶段退出码均为 0。每组故障库 31 个样本，Dart 各 18 项通过，JVM 各 26 项通过（0 failures/errors/skipped）。插件 41 passed / 1 skipped；Linux CLI 81 passed / 1 skipped。
- 自定义 binding 两次补丁按预期均为 whole：seq7 为 2,162,150 bytes，SHA256 `7b40ab8991193b8bd8ac535f1ca41bbfaf577ef5784e2e9d655a912d282cb6b1`；seq8 为 2,163,065 bytes，SHA256 `43607004866ef5caf789398b604d58e40d7b2757cfac92c815db6e226e75d1bc`。这不是 custom lean 已通过。
- 真正空应用 libapp.so：普通 1,508,232 bytes，patcher 10,617,736 bytes，增量 9,109,504 bytes。尚未设审核阈值，size gate 为 not_run（测量已做，预算判定未做）。
- SDK 17,572 个常规文件逐一 SHA256 检查，无差异。
- 最新 artifacts `e12c2cfd5746610f936054030129737dcebb22ae` 完整工具构建 A11 及冒烟通过，耗时 277.73 秒，dill 37,307,328 bytes，SHA256 `448fd8e8d3bfe52c875a98838a4abc0a022f9256332cc6a0c7deefbbd73753f9`。其哈希不同于应用集成使用的 `8c8b772` dill；此次仅证明最新构建入口/A11/工具冒烟通过，不把旧 dill 的 APK 集成结果冒充成最新 dill 的完整集成验收。正式发布前仍须用选定最终 Release 字节跑设备链路。
- 完整取证汇总与日志已归档到本地 `.dart_tool/flutter_patcher/wp9/verified-summary.json`、`wp9-evidence-final.tar.gz`。旧失败记录保留，汇总将 modules2 成功与旧 modules 失败分开。
- 本轮离线验证已结束；未触发 GitHub CI、push、tag 或 Release。真机、独立第二主机、字体视觉审核、体积预算及完整 A10/M1 验收仍未完成。

### 10.7 固定最终工具产物的离线集成（2026-09-10）

已补齐 §10.6 中“最新 dill 未跑应用集成”的缺口。代码提交固定为 `7b3f451be80889f11744d73ff4effb2547bb64cf`，artifacts 固定为 `e12c2cfd5746610f936054030129737dcebb22ae`；工具文件 37,307,328 bytes，SHA256 `448fd8e8d3bfe52c875a98838a4abc0a022f9256332cc6a0c7deefbbd73753f9`。四个 build/patch 缓存的 tools.manifest.json 均与固定输入逐字段一致。

- GPU `wp9-development/pinned-*` 使用新目录，standard/custom 两组的 build、patch、故障模块、故障库、Dart 检查、JVM 测试均退出 0，`pinned.done` 已生成。
- standard 正常生成 lean/whole；custom 第一份按接口边界自动升 whole，第二份亦为 whole，不宣称 custom lean 验收通过。每组故障库 31 个样本，JVM 各 26 tests、0 failures/errors/skipped；Dart 检查各 18 项通过。
- SDK 17,572 个常规文件 SHA256 复查无差异。两组 independent_machine 均为 false，仍不计独立第二主机验收。
- 本轮只重跑受工具产物变化影响的构建/补丁/故障库集成；未重复此前已通过的插件/CLI 常规回归和空应用体积测量。此前体积记录仍绑定此前测量的输入，不冒充本轮固定产物的体积成绩。
- 本地证据：`.dart_tool/flutter_patcher/wp9/pinned-summary.json`、`pinned-evidence.tar.gz`，包括固定 manifest、基线指纹、各补丁实测大小及 SHA256、阶段退出码、故障库与测试日志。
- 未 push/tag/Release、未触发 GitHub workflow、未改变 SDK 或用户工程。本轮未改产品代码。

剩余：最终产物的 Android arm64/API33+ 设备闭环和故障实际加载、独立第二 Linux 主机、A10 两次引擎与设备配套验收、字体视觉检查和性能/体积预算审核。`keys init` 仍为未实现入口。上述事项未完成前不标记完整 M1 达标。

### 10.8 首轮 Android 真机验收（2026-09-10，发现发布阻断）

用户连接荣耀 MEY-AN00（Android 16 / API 36、arm64-v8a），授权安装专用验收应用。使用 §10.7 的固定 APK/补丁/故障库，两个 APK 与构建收据及 62 个样本大小/哈希全部核对通过；未修改产品源码或发布。

- 普通 binding 的 lean/whole，以及 custom 的两份 whole 控制补丁，均在原生 Ed25519 公钥导入阶段失败。设备 KeyFactory 的 Ed25519 provider 是 AndroidKeyStore，其 generatePublic 不接受当前 X509EncodedKeySpec 外部公钥导入方式。同一补丁在桌面 SunEC 中验签成功。API >=33 不能保证当前验签实现可用；此项为发布阻断，必须修复并重新构建匹配基线后再验设备链路。
- 两组共 22 个前置损坏样本通过：长度、截断、magic、版本、指纹和 payload hash。普通组为已完成 3 项加独立复测 8 项，自定义组 11 项一次通过；不宣称完整 31 项矩阵通过。4 个有效控制失败，其余 36 个依赖验签/安装的样本标记 blocked，而非“已正确拒绝”。
- 旧 SO 路线实际 original→下载更新→冷启动 so→撤回→冷启动 original 全流程通过（不带签名，因此不证明旧签名路径可用）。
- 普通组连续运行出现三次首帧超时，独立重跑剩余 8 项均成功。根因尚未确认，保留全部日志；不把该超时直接归因于截断包或厂商清理。安装权限中断在用户确认继续后恢复，旧失败证据保留。
- 没有成功字节码加载，资源/字体实际生效、故障恢复及补丁性能仍未验收。未做第二 Linux 主机、A10 或完整 M1。
- 计划与报告：`plan/DEVICE_TEST_PLAN_2026-09-10.md`、`plan/DEVICE_TEST_REPORT_2026-09-10.md`。逐项结果及原始证据位于 `.dart_tool/flutter_patcher/wp9/device-20260910/device-summary.json` 与同目录下各次运行。测试结束时原应用可用、无活动补丁；ADB 临时端口映射和设备诊断探针文件已清理。

### 10.9 Ed25519 兼容性修复与真机闭环（2026-09-10 至 09-11）

用户批准修复 §10.8 的签名阻断。Android 两条签名路径改用固定 `bcprov-jdk18on:1.85.2` 的轻量 Ed25519 实现，避免 AndroidKeyStore 外部公钥导入限制；不注册全局 Provider。FPTC 签名覆盖范围、旧 SO 的 MD5 文本/SPKI 格式、API 33 下限和 strictSignature 策略不变。此前关于依赖“系统 Ed25519 Provider”的实现描述由本节取代。

- 基线代码 `7b3f451be80889f11744d73ff4effb2547bb64cf` 加本轮未提交改动，六个 Android 变更文件与构建端 SHA256 收据一致。最终工具仍固定为 §10.7 的 dill；不以基线 HEAD 冒充修复后源码提交。
- JVM 同一套 28 tests 在 pinned-standard/custom 两份故障库下均无失败。荣耀 API36 真机仪器测试 4/4 通过，覆盖有效签名、重复验签、错误公钥、畸形/小阶公钥、篡改拒绝及旧 SO 验签。
- 新建隔离目录重建 standard/custom APK 和匹配补丁，四个阶段均退出 0。standard lean/whole、custom 两份实际 whole 均完成 HTTP 下载、验签、冷启动代码和资源生效、撤回恢复原应用；custom binding 保留。两组篡改签名均返回 signatureInvalid / Envelope signature。每组功能冒烟 3/3 通过；custom 文件名 valid-lean 不代表其 tier 是 lean。
- 两次 standard 完整设备批量验收仍为 failed：lean 控制与各 10+10 启动采样完成，whole 阶段采样中断。日志有厂商 CrashClean 杀进程证据；单独功能冒烟不取代性能或完整故障矩阵。lean 两轮 bootstrap 约 46–73 ms、55–71 ms；whole 不完整日志约 318–470 ms，超 85 ms 告警线，需继续优化与稳定采样。
- 标准 APK 增加 1,262,855 bytes（约 1.26 MB），主要为密码库资源；验签需要额外的 FPTC 大小减 64 字节缓冲区，最大补丁内存和体积预算仍待审核。API33 边界及更多厂商设备、完整故障恢复、独立第二 Linux 主机、A10、字体审核仍未完成，keys init 仍缺失；不标完整 M1 或发布就绪。
- SDK 17,572 个已有文件 SHA256 无差异。全部原始失败证据保留；详见 `plan/ED25519_FIX_REPORT_2026-09-10.md` 和 `.dart_tool/flutter_patcher/ed25519-fix/`。收尾无活动补丁，原应用首帧正常，临时映射和新增仪器测试包已清理。未提交、push、tag、Release 或触发 CI。


### 2026-09-11 M1 收口范围与性能冻结

按用户决定停止本轮性能优化：standard lean 平均 65.3 ms、whole 205.9 ms 的实测保留，whole 的 200 ms 检查未通过，不改预算或改写历史结果。Dart CRC 与 entry SHA 保留；其独立契约与 FFI 一并留到 M1.5 设计。当前收口工作为 custom 完整 31 项矩阵及 keys init。

keys init 实现范围：Linux x64/WSL2，OpenSSL 生成 Ed25519，输出 raw32 seed/public Base64，默认 ~/.flutter_patcher/keys，也可 --out 指定新目录。目录 700、私钥 600，拒绝覆盖与符号链接；stdout 只含元数据。生成结果直接供 build --public-key 与 patch --private-key 使用。实际验收状态以本轮收口报告为准。
