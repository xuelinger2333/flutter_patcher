# M1 基线后第一轮代码清理

基线：`m1-baseline-20260912` / `ddbde27`。扫描版本控制中的 Dart、Kotlin、
Python、Java、Shell 文件，排除冻结验收目录、构建产物和外部工具仓库。
扫描覆盖路径、文件规模、重复代码片段、文件读写与哈希调用，再人工检查
CLI、Dart 引导与 Android 事务模块。不是逐行审计，也不证明没有其他问题。

## 规模与判断

清理前 120 个源码文件，共 17,999 行（含注释和空行）：

| 范围 | 行数 |
| --- | ---: |
| 测试与验收代码 | 6,337 |
| CLI 产品代码 | 5,131 |
| Android 产品代码 | 3,438 |
| Dart 插件产品代码 | 1,785 |
| bin 工具 | 883 |
| example | 425 |

最大的模块为 PatchManager.kt（1,233 行），其次为 pack.dart（533 行）、
FlutterPatcher 入口（484 行）、CLI SDK environment（450 行）。大文件本身
不是删除理由；事务与恢复步骤不能仅因相似就合并。注释中解释签名覆盖范围、
并发约束、崩溃恢复和拒绝条件的内容保留，未做全仓格式化或为减少行数删除文档。

## 已实施

1. doctor/build/patch/baseline 四个入口的缓存目录规则合并为 managedCache。
   保留受管目录、路径规范化及 CONFIG_INVALID 错误码；文案统一。各调用方
   的符号链接检查、创建目录、加锁顺序保持不变。辅助函数仅计算路径，不做 I/O。
2. build 后处理复用 verifyApk 返回的 Archive。引擎身份校验、唯一 arm64
   libapp 检查、资源清单与安全路径校验全部保留，APK 读取/ZIP 解析从三次
   变为一次。resources 收据随 verifyBuildApk 返回，不再在 pipeline 重读。
   resources 校验现在发生在 verify-apk 阶段，非法资源失败会更早暴露；
   错误码不变。完整 APK 与落盘 libapp 的哈希检查仍保留。
3. CLI AssetCodec 复用 ByteData 视图，避免每次数字读取创建新视图。
4. 修正 strictSignature 注释：API 33 是当前插件策略，不能解释为依赖系统
   Ed25519 Provider。运行时行为未变。

既有产品文件净减少 31 行；新增两个行为测试，覆盖目录边界以及同一 APK 的
引擎/libapp/资源收据和恶意输入拒绝。测试及文档不计作产品代码减量。

## 验证与性能边界

- Windows 定向测试 10/10；首次路径测试暴露混用分隔符，修正后全组重跑通过。
- Linux 全套 CLI：89 passed，0 failed，2 skipped。跳过未启用的真实 AWS CLI
  隔离 S3 集成，以及 Linux 不适用的 unsupported-host；新增测试全部运行。
- 两侧 CLI 静态分析通过。测试源码清单与当前 CLI 文件逐一匹配。
- 使用 M1 custom 真实 APK 在同一 Linux 上对比旧/新 verifyBuildApk + 资源
  收据，所有字段语义相等。错误引擎、额外 ABI、非法资源路径均有拒绝测试。
- 小规模顺序耗时样本（含 aapt、文件哈希等完整后处理）旧版 756.7/659.1/
  629.4/650.5 ms，新版 702.6/680.2/735.8/658.6 ms。没有证明耗时下降；
  只确认重复读取/解析减少。样本少、未交错，不用于宣称性能提升或回退归因。
- 未重建 APK、未重跑真机矩阵：本轮 Android 与 Dart 运行代码未改变，改动
  集中在 CLI 的缓存策略和构建后处理；没有声称新构建全链路或设备验证通过。

证据：`.dart_tool/flutter_patcher/cleanup-20260914/`；远端同名独立目录。
tests.log SHA256：`848ae1980d4ba361a1470ae6b48fa75aa44a0be53077d2dce77bc5b30cda7e5b`。
source.json SHA256：`de356a6944e806633fddf1a912cacef9f0d6aca409caed59cf0a5d351047c816`。
apk-comparison.json SHA256：`060ec766f70822aa09e53d4a99ff22320f46ef49d16c864df60dd3e1b01262b7`。

## 后续候选，不在本次强行合并

- PatchManager.kt：按下载、安装事务、启动恢复拆分值得考虑，但必须先固定
  状态机与锁的所有权，并用完整设备故障矩阵验证；避免只拆文件不降低复杂度。
- build/patch 命令的工具链准备仍有相似段落，校验顺序与离线契约不同；不以
  大量布尔参数引入统一流程。本轮仅提取确实相同的缓存路径规则。
- bin/pack.dart 与 CLI 补丁封装处理不同协议；不能当作同一实现删除。
- Dart 与 native 的重复校验可能是信任边界，不作为普通重复代码精简。
  CRC、entry SHA、签名实现、FFI、调度与 host interface 继续遵守此前冻结决定。
- 文字字体验收 app 与原矩阵 app 的控制器相似，但改成测试依赖包可能改变
  lean/whole 分档与基线身份，留到单独的测试工程整理。

M1 tag、冻结记录和已知未完成门槛未修改；未推送或发布。
