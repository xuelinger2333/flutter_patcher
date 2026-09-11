# 已验签字节直传：安全设计与测量方案

日期：2026-09-11。状态：设计审查；尚未修改产品协议或执行新实验。

## 决策与范围

建议将 Android bootPayload 返回的路径证明改为已验签字节快照。
先删除 Dart 为跨文件重读建立绑定而做的两轮 SHA，保留现有归档一致性
检查。不得通过删除拒绝条件或修改故障用例的预期来达到性能预算。
whole 200 ms、lean 85 ms 仍按各十次启动全部满足来判断；尚无新性能结果。

这里涉及内部 Dart/native 启动协议变更，必须由同一次源码重建生成宿主
APK、补丁和 corpus，不支持新 Dart 协议搭配旧 Android 插件。
whole 的框架复用仍在 M1.5 之后；custom 矩阵和 keys init 不在本变更中实现。

## 现有三个摘要并非同一目的

| Dart 检查 | 当前目的 | 字节直传后的处理 |
| --- | --- | --- |
| 完整 FPTC SHA256 | 将重新按路径读取的文件绑定到 native 验签结果 | 删除；不再重新打开文件 |
| payload SHA256 | 复核 envelope 中的 payload 摘要 | 删除重复计算；native 已对同一快照检查 |
| manifest entry SHA256 | 核对模块、资源内容与清单声明一致 | 保留；签名不蕴含清单自洽 |
| ZIP CRC | 核对条目内容与 ZIP 声明一致 | 保留；同样不由签名推出 |

依据：BytecodeEnvelope.verify 验证 payload SHA 和 Ed25519，签名覆盖
头部前 82 字节及完整 ZIP。corpus.py 的 asset-hash、zip-crc 均在引入
清单摘要/CRC 错误后重新计算外层摘要并签名，仍须被归档层拒绝。
这两项不是攻击者能够修改已签名字节的证据，而是当前格式契约明确拒绝
签发端生成的自相矛盾包。SPEC_M1 第 990–991 行附近分别规定外层绑定
与内层一致性，两者不能混为一条安全检查。

## 推荐协议

建议首版返回完整已验签 FPTC 字节快照，而非仅 ZIP payload；146 字节
额外成本可以忽略，保留头部让 Dart 继续直接比对 fingerprint、seq 等
身份字段，避免新建一份容易与字节脱节的身份元数据协议。

响应概念结构为 transportVersion、attempt、envelopeBytes 和 profile。
envelopeBytes 在 Android 为 ByteArray，在 Dart 为 Uint8List，使用
StandardMethodCodec 原生字节数组编码，禁止 Base64/整数列表展开。

1. Android 有界读取候选文件一次，使用同一个局部 ByteArray 完成长度、
   magic、版本、fingerprint、payload SHA、Ed25519 和持久候选身份检查。
2. 全部成功后才创建 offer；返回该数组，禁止验签后再次按路径读取。
   数组不存入可变全局缓存，不提供给其他可写调用，不在提交响应后修改。
   channel 编码与跨运行时复制保持快照值，不承诺零拷贝。
3. Dart 只接受已知协议版本、非空 attempt 和 Uint8List；保持总长限制、
   envelope 字段检查及归档解析限制。未知版本或旧 path/sha256 响应关闭
   补丁路径，回原应用，不降级到路径模式。
4. 快照只由 bootstrap 持有，解析为子视图；完成所有检查前不交给模块、
   资产安装器或用户回调。生产入口与供离线文件验证的函数明确分开，
   禁止给通用文件校验函数增加容易误用的 skipVerification 开关。
5. markBooting 的 attempt、active 候选一致性和持久崩溃保护保持原样。
   回滚/新候选使旧 offer 失效；通道超时不执行晚到模块，不重试领取。

## 信任假设与攻击面

- 信任打包进宿主的 native 插件、公钥和启动代码。Method channel 不是
  向任意外部应用开放的身份认证服务；同进程恶意 native 代码、root 或
  可改写进程内存的攻击者不属于原模型，新协议不能解决它们。
- 文件在读取期间被改写：最终内存快照必须同时通过验签和持久候选
  digest 比对。混合读或被替换的内容不得绕过验证；native 完整文件
  digest 仍用于候选身份，不因删除 Dart digest 而删除。
- 验证后路径被替换/删除：不影响已持有字节；不得再使用路径构造模块。
- 重放/跨宿主包：保留安装序号高水位、fingerprint、versionCode、黑名单
  与 attempt 状态机。传字节本身不替代这些约束。
- 已签名的恶意归档：保留路径、数量、大小、重叠、重复、类型、manifest
  和入口六槽检查。签名授予来源信任，不授予解析器无限资源使用权。
- 内存：现有上限 320 MiB 不能证明 channel 复制这一大小可承受。需要
  量化 native 数组、codec 缓冲、Dart 响应和子视图的生命周期与峰值。
  2.17 MB 控制包成功不能被描述为已验证 320 MiB。若必须增加传输上限，
  应明确为兼容性变更并写入 SPEC，不能静默降低或以 OOM 作为限流策略。
- 字节数组可变：安全论证依赖校验至加载之间只有可信 bootstrap 使用
  快照；不可对外宣称 Uint8List 天然不可变或签名能检测内存任意改写。

## 性能收益的边界

当前 whole 均值 252.63 ms，entry SHA 为 22.66 ms，三类 SHA 共 68.19 ms。
删除两轮可省约 45.53 ms，加上省去 Dart 文件重读，再减去大响应的额外
编码、复制、解码成本。不能据此保证低于 200 ms，更不能把 68 ms 全扣掉。

若第一步仍超预算，下一步候选是将剩余的条目一致性验证在 native 针对
同一快照完成，再将可信结构化结果传给 Dart。这是单独的解析器边界设计，
需要证明两个解析器选择的条目/区间一致、复用全部归档拒绝案例；不能只
附上一份未经校验的 manifest 或盲信 native 返回的成功标志来跳过检查。
它与把三份 SHA 全搬到 Kotlin 有区别：前两份冗余已删除，第三份契约保留。
本阶段不引入 FFI，也不承诺 Android MessageDigest 在该手机必然硬件加速。

## 首帧后通道实验

现有 bootPayload 在 fingerprint 已设置或 processClaimed 为真时立即返回
null。第二次直接调用仅测短路，既不读文件、验签，也不返回大数组。
不得清除 processClaimed、制造第二个 attempt 或修改产品状态机来测量。

先在专用验收构建中加入隔离的探针，生产构建不包含实验处理器：

- 使用与产品相同的 StandardMethodCodec、worker/main reply 路径和时间戳。
- 分别测空响应、与实际响应等长的字节快照、只读验证同一固定候选后返回
  字节三种工作负载；完整验证探针不修改 active、attempt、崩溃计数或首帧 token。
- 在 bootstrap 阶段与首帧后固定延迟的稳定阶段配对测量，各十次进程冷启；
  阶段内避免并发请求。记录 PID、阶段、字节数、请求 ID，避免依赖最近一条
  bootPayload 日志拼接；探针轮次与正式性能验收轮次分开。
- 比较 Dart 往返减 Java decode-to-reply 的残余，不能拿含验签的总往返
  直接要求降到几毫秒。验证结果/字节一致性检查放在计时之外。
- 首帧后下降只能支持“与启动阶段有关”，不能证明 Surface 初始化、
  platform 线程或 engine 某个方向是唯一原因；不下降也不能证明插件有错。
  若仍需归因，再做匹配构建模式的 engine/system trace。FFI 是否值得做，
  要同时考虑线程亲和、JNI、异步 I/O 和新桥接成本，不能由此实验直接决定。

Android total-start 的 226 ms 是 whole 对原应用的差值；253−65 是 whole
对 lean 的 bootstrap 差值。参照组和统计量不同，不能据此证明 bootstrap
之外不存在其他启动开销，需要成对端到端观测才可作这种排除。

## 实现后的验收

1. 新增验证后改路径仍只加载原快照、旧协议拒绝、错误响应类型、过期
   attempt、晚到响应不加载的定向测试；验证 ByteArray/Uint8List codec 往返。
2. 保留离线文件校验路径的完整安全检查，31 项 corpus 的内容和拒绝预期
   不放宽，尤其签名有效的 asset-hash 与 zip-crc。
3. 从同一源码重建 APK、lean/whole 补丁、corpus；JVM、Dart 检查及真机
   仪器 4/4、故障矩阵 31/31。适配 profile schema，区分已删除计时与漏采样。
4. 真机按既有 3 秒节奏采集 lean/whole 各十次正式启动，分别报告预算、
   codec/复制耗时和内存样本。保留失败记录；不改手机配置，不用模拟器。
5. whole 全部进入 200 ms 后结束这条性能线；否则报告差额再选择下一步，
   不把未测量的 native 条目解析迁移暗中扩大成当前方案。
