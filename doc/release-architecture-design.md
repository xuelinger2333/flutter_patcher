# 1.0 发布架构：分层产物与零配置工作流

状态：设计已确认，未实施。第 7 节标明哪些必须在 1.0 发布前完成。

## 1. 目标

1. 已上线的宿主永远可以继续打补丁：产物发布后不再修改，打补丁使用宿主
   构建时的那一套产物。
2. 只在真正的依赖变化时重建：插件发版不碰引擎；新 Flutter 版本只构建这一个
   版本；编译工具按 Dart 版本发布。
3. 插件与引擎之间有显式、带版本号的接口，不匹配在构建期报错，而非运行时失败。
4. 开发者接入时什么都不用写：`keys init`、`build`、`patch`、`publish` 四条
   命令即可走完，Android 与 iOS 一致；定制能力以可选参数和高级文件提供。

## 2. 现状与问题

一个 Flutter 版本对应一个 release（`flutter-<version>`），引擎、各主机
gen_snapshot、tools dill 放在一起，一起构建，发现问题时删除旧文件再上传。

- 基线记录引擎 `build_id`，打补丁时要求与 release 中的一致
  （`lib/src/cli/patch/libapp.dart`，`PATCH_BASELINE_INCOMPATIBLE`）。原地替换
  release 会让已上线的 SO 宿主无法再打补丁；bytecode 宿主也会拿到与其引擎
  不一定兼容的新 tools。
- 只改引擎扩展补丁也要重建 gen_snapshot、iOS 引擎和 tools。
- tools 只依赖 Dart SDK，却按 Flutter 版本发布：20 个 stable 版本只对应
  10 个 Dart SDK。
- CLI 只检查补丁记录"存在且格式正确"，不检查引擎提供的是不是插件所需的能力。
- SO 宿主运行 Flutter 自带的 `libapp.so`，却因 fingerprint 包含引擎
  `build_id` 而同样只能用于有自建引擎的版本。
- 开发者手写 11 个字段的规范化 policy JSON（键排序、单行、全字符串）和约 25
  个字段的发布请求 JSON，其中绝大部分可从构建产物、密钥目录和发布存储推出。

## 3. 分层产物

### 3.1 三层及其依赖

| 层 | 内容 | 依赖 | 重建条件 |
|---|---|---|---|
| engine | `libflutter-arm64_v8a-release.jar`、`flutter_embedding_release.jar`、`Flutter.xcframework.zip` | Flutter 引擎源码、VM 层补丁、扩展层补丁 | 新 Flutter 版本；`engine_api` 或 `vm` 代数变化 |
| snapshot | `gen_snapshot-<host>`（linux-x64、windows-x64、darwin-arm64）、`gen_snapshot_ios-darwin-arm64` | Flutter 引擎源码、VM 层补丁 | 新 Flutter 版本；`vm` 代数变化 |
| tools | `flutter_patcher_tools.dill` | Dart SDK、`tools/` 源码与 dart2bytecode 补丁 | Dart SDK 版本；`tools` 代数变化 |

补丁按层归属：

- VM 层（`engine_patches/*.patch` 与主机专用补丁）：字节码解释器构建参数、
  `bytecode_reader.cc` 修复、Windows `FATAL1` 修复。影响 libflutter 与 gen_snapshot。
- 扩展层（`engine_patches/flutter/*.patch`）：资源覆盖、后台入口重定向。只改
  运行时代码，不影响 gen_snapshot。
- 工具层（`tools/dart2bytecode_patches`）：只进入 tools dill。

### 3.2 代数与身份

每层有一个整数代数，在 artifacts 仓库中随该层补丁或构建参数的任何语义变化
递增：`vm`、`engine_api`、`tools`。代数是兼容性声明，`build_id`（UUID v4）
是一次具体构建的身份。

- engine 身份：`(flutter_version, vm, engine_api, build_id)`
- snapshot 身份：`(flutter_version, vm, build_id)`
- tools 身份：`(dart_version, tools, build_id)`

同一 engine 与 snapshot 必须来自同一 `vm` 代数和同一引擎源码；清单中继续记录
`engine_commit`、`depot_tools_rev`、补丁文件与摘要，用于溯源。

### 3.3 Release 命名

每次构建产生一个新的 GitHub release，发布后不再增删文件：

```
engine-<flutter>-a<engine_api>-v<vm>-<build_id 前 8 位>     例 engine-3.47.2-a1-v1-63b8646d
snapshot-<flutter>-v<vm>-<build_id 前 8 位>                例 snapshot-3.47.2-v1-0b85cdaf
tools-<dart>-t<tools>-<build_id 前 8 位>                   例 tools-3.13.2-t4-aa97c879
```

release 内文件名不带版本号（与现在相同），清单分别为 `engine.manifest.json`
（schema 3）、`snapshot.manifest.json`（schema 1）、`tools.manifest.json`
（schema 2）。iOS 引擎并入 engine release，iOS gen_snapshot 并入 snapshot
release，不再有独立的 `engine-ios.manifest.json`。

上传脚本保留"已存在即拒绝"，并拒绝向已有文件的 release 追加，从而保证不可变。

### 3.4 索引

artifacts 仓库根目录的 `index.json` 是 CLI 唯一的入口，取代
`supported_versions.txt`。它由发布 workflow 在上传完成后以提交方式追加，
从不删除或改写已有记录：

```json
{
  "schema": 1,
  "flutter": {
    "3.47.2": {
      "dart": "3.13.2",
      "current": {"engine": "engine-3.47.2-a1-v1-63b8646d",
                  "snapshot": "snapshot-3.47.2-v1-0b85cdaf",
                  "tools": "tools-3.13.2-t4-aa97c879"},
      "history": ["engine-3.47.2-a1-v1-...", "snapshot-3.47.2-v1-...", "tools-3.13.2-t3-..."]
    }
  },
  "patch_tools": {"tools-3.13.2-t3-...": ["tools-3.13.2-t4-aa97c879"]}
}
```

- `current`：构建新宿主时使用的组合。
- `history`：该版本发布过的全部 release，供旧基线下载。
- `patch_tools`：可选的兼容声明，"用旧 tools 构建的宿主可用新 tools 打补丁"。
  只在维护者验证过字节码与旧引擎兼容后添加；没有声明时一律使用基线记录的那一套。

CLI 从 GitHub raw 地址读取固定分支上的 `index.json`；`--artifacts-url` 保留为
维护者和测试覆盖项。

### 3.5 基线与选择规则

`build` 把实际使用的三个 release tag 及其清单摘要写入基线
（compile 与 release receipt 新增 `artifacts` 字段）。`patch` 的规则：

1. 读取基线中的 `artifacts`，下载这三个 release，按记录的清单摘要校验。
2. tools 若在 `patch_tools` 中有兼容的更新版本，使用最新的那个；否则使用记录的。
3. engine 与 snapshot 永远使用记录的那一套；打补丁不需要 libflutter，只需要
   gen_snapshot（SO）和 tools（bytecode）。
4. 本机缓存按 release tag 存放在 `~/.flutter_patcher/artifacts/<tag>/`，命中即
   不下载。

## 4. 引擎扩展接口

### 4.1 构建期

engine 清单记录 `engine_api` 和该代数提供的能力列表：

```json
"engine_api": 1,
"capabilities": ["asset_overlay", "isolate_entry"]
```

CLI 内置"插件功能 → 所需能力"的表。`build` 选用 `current` 组合并检查能力满足
插件需求；`patch` 检查补丁实际用到的能力（例如改了资源需要 `asset_overlay`），
不满足时以 `PATCH_ENGINE_CAPABILITY` 报出具体能力与重建宿主的建议。取代现在
"release 列出某补丁文件即视为支持"的判断。

### 4.2 运行时

插件通过 `flutter_patcher/engine` 平台消息查询引擎支持的 `engine_api` 与能力。
未打补丁的引擎把消息转给 embedder，后者回复空，即"无扩展能力"。插件据此只启用
可用功能：缺 `asset_overlay` 时不安装补丁资源，并在诊断中记录；缺
`isolate_entry` 时后台引擎按原样运行。不因能力缺失崩溃。现有资源与入口两个
平台消息保留不变，作为 `engine_api: 1` 的定义。

### 4.3 演进规则

- 新增能力：`engine_api` 加一，追加构建所有支持的版本；旧代数的 release 保留。
- 能力只增不减。删除或改变语义需要新的能力名。
- 插件的新功能若不需要新能力，不得要求新的 `engine_api`。

## 5. 零配置工作流

### 5.1 命令

```
dart run flutter_patcher keys init
dart run flutter_patcher build android        # 或 build ios（在 Mac 上）
dart run flutter_patcher patch android        # 或 patch ios
dart run flutter_patcher publish
```

### 5.2 `keys init`

一次生成 root、publisher、patch 三对密钥到 `flutter_patcher_keys/`（项目根），
写入 `.gitignore` 排除私钥，并输出备份提示。已存在时拒绝覆盖。`--out` 保留。

### 5.3 项目配置 `flutter_patcher.yaml`

只放推不出来的东西：设备从哪里下载、补丁和基线存在哪里。`keys init` 生成带注释
的模板：

```yaml
# 设备下载补丁的 HTTPS 地址前缀；publish 上传后的文件以此对外提供。
public_url: https://cdn.example.com/patches
# 补丁、清单的上传位置：file://、s3:// 或 HTTPS 存储。
store: s3://my-bucket/patches
# 基线存放位置；默认 .flutter_patcher/baselines（需随项目备份）。
# baseline_store: s3://my-bucket/baselines
```

缺少 `public_url` 或 `store` 时，`publish` 报错并指出要填的那一行；`build` 与
`patch` 不需要它们。

### 5.4 `build`：自动生成 host policy

policy 不再手写。`build` 先用 Flutter 构建，再从产物与密钥目录得出全部字段：

| 字段 | Android | iOS |
|---|---|---|
| `application_id` | APK 包名（aapt） | IPA `CFBundleIdentifier` |
| `version_code` | APK versionCode | `CFBundleVersion` |
| `abi` | `arm64-v8a` | `ios-arm64` |
| `flavor` | `--flavor`，默认 `default` | 同左 |
| `channel` | `--channel`，默认 `production` | 同左 |
| `strategy` | `--strategy`，默认 `bytecode` | iOS 仅 `bytecode` |
| `root_key`、`keys`、`fptc_key` | `flutter_patcher_keys/` 中的公钥；`keys` 为 `release:<publisher>` | 同左 |
| `schema` | `1` | `1` |

生成的 policy 以现有规范化格式写入输出目录和基线，原生侧格式不变。
`--version-code` 删除：版本号以 pubspec `version` 的构建号为准，由 Flutter 写入产物。
`--host-policy` 改为可选的高级入口（多发布者密钥、轮换后的信任结构等），
读入时由 CLI 规范化，不再要求手工排序和压缩。

iOS 仍需在 Mac 上执行，签名沿用 Xcode 工程设置，`--export-method` 保留。

### 5.5 `patch`：序号自动推进

`--seq` 改为可选。默认取"基线存储中该宿主已生成的最大序号 + 1"，
基线存储记录每次 `patch` 的序号；显式给出时只用于核对必须更大。
`--previous-seq` 删除。策略、渠道、flavor 一律从基线读取，`patch` 不提供这些选项。

### 5.6 `publish`：请求文件不再手写

默认发布最近一次 `patch` 的输出（`--patch <dir>` 可指定），其余全部自动得出：

| 现请求字段 | 来源 |
|---|---|
| `fields` 中的 scope 与 `fingerprint`、`strategy`、`patch_seq` | 补丁输出中的基线绑定 |
| `revision`、`expected_revision` | 发布存储中的当前 catalog |
| `operation`、`created_at` | 随机生成、当前时间 |
| `minPluginVersion` | 当前插件版本 |
| `private_key`、`public_key` | `flutter_patcher_keys/publisher/` |
| `store`、`public_base_url`、`baseline_store` | `flutter_patcher.yaml` |

默认先预览再提交：不带 `--commit` 时只打印将要发布的内容；`--production`
不再需要。撤回补丁使用 `publish --withdraw`。`--request` 保留为高级入口。

## 6. SO 宿主与自建引擎解耦（1.0 之后）

只改代码的 SO 补丁不需要自建引擎：宿主由 Flutter 自带工具链构建，插件的
`LoaderHook` 加载补丁中的 `libapp.so`。目标是：

- SO 宿主允许使用 Flutter 官方引擎，支持 3.44 起所有 stable 版本，不需要任何 artifacts。
- 资源补丁要求宿主引擎具备 `asset_overlay`，否则 `patch` 拒绝含资源变化的补丁。
- fingerprint 以 Flutter 版本、引擎提交和官方引擎文件摘要代替自建引擎 `build_id`。

实施前需单独论证：fingerprint 改变后，补丁与宿主的绑定强度不下降，官方引擎
文件摘要的获取途径可信，以及跨 flavor、跨 ABI 不会误配。

## 7. 分期

### 1.0 发布前

1. artifacts：分层构建与 release 命名（3.1–3.3）、`index.json` 与追加式发布（3.4）、
   engine 清单的 `engine_api` 与 `capabilities`（4.1）、iOS 产物并入。
2. CLI：按索引选择产物、基线记录 `artifacts`、按基线下载与缓存（3.5）、能力检查（4.1）。
3. 插件：运行时能力查询与按能力降级（4.2）。
4. 工作流：`keys init`、`flutter_patcher.yaml`、自动 policy、自动序号、简化
   `publish`（5.2–5.6）。
5. 产物：按新格式发布 3.47.2 的 engine、snapshot、tools。现有 `flutter-3.47.2`
   release 删除，因为 1.0 之前没有用户依赖它。
6. 文档：getting-started、CLI 参考、迁移指南（0.1.4 与开发期用户）重写。

### 1.0 之后

1. 扩展支持版本：先 3.47.0–3.47.9，再按补丁移植结果做 3.44.x。
2. SO 与自建引擎解耦（第 6 节）。
3. 把 VM 层的两个修复提交给上游；重新启用"Check new Flutter stable"。

## 8. 迁移

- 0.1.4 用户：其宿主只接受 v1 补丁，继续用 0.1.4 的 `pack` 维护；升级到 1.0 需重建
  宿主并发布新 app。迁移指南给出 API 替换和服务端过渡期双接口的做法。
- 开发期用户（含 jdapp 试用）：基线没有 `artifacts` 字段。`patch` 遇到这类基线时
  报 `BASELINE_ARTIFACTS_MISSING`，提示用 1.0 重建宿主；不做推断式兼容，避免
  用错产物生成补丁。

## 9. 验收

- 不可变：对已存在的 release 再次发布被拒绝；`index.json` 只出现追加。
- 旧宿主：用 `current` 构建宿主 A，发布新的 tools 与 engine 后，A 仍能在干净机器上
  按基线下载原产物并打出可启动的补丁（荣耀手机、iPhone 各一次）。
- 能力：用缺 `asset_overlay` 的引擎构建的宿主，`patch` 含资源变化时在构建期被拒；
  运行时能力查询为空时补丁代码照常生效、资源不安装、无崩溃。
- 零配置：新项目只执行第 5.1 节四条命令，不写任何 JSON，Android 与 iOS 各完成一次
  从接入到补丁生效。
- 回归：现有 `flutter test`、Android 单元测试、artifacts 单元测试和 31 项故障语料不放宽。

## 10. 待定

- `index.json` 的托管：仓库内文件经 raw 地址读取，或单独的 `index` release 资产。
  前者便于审阅历史，后者不受分支保护规则影响。
- `patch_tools` 兼容声明的验证标准：需要定义"字节码与旧引擎兼容"的自动检查。
- 基线存储默认放在项目内是否足够安全：丢失基线意味着该宿主无法再打补丁，
  默认值可能应改为强制配置。