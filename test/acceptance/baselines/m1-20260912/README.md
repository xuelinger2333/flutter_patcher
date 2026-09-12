# M1 冻结基线 · 2026-09-12

本地 annotated tag：`m1-baseline-20260912`。tag 指向包含本目录的提交，
其父提交 `a91bee9` 是冻结前的代码状态。基线记录随 Git 保存，不依赖工作区
中的忽略目录。此 tag 冻结实现和已有证据，不代表所有 M1 门槛或发布审批通过。

## 固定的对照结果

| 项目 | 已记录状态 |
| --- | --- |
| standard 故障矩阵 | 31/31；仪器测试 4/4 |
| custom 故障矩阵 | 31/31；仪器测试 4/4；两份控制实际均 whole |
| keys init | Linux CLI 87 passed、0 failed、2 skipped；新增 keys 用例无跳过 |
| 隔离基线迁移 | 同机隔离 Linux 环境；断网生成补丁；真机 2/2 闭环通过 |
| 文字字体 | standard lean/whole、custom whole/whole 共 4/4 自动闭环通过；人工视觉最终确认未写入 |
| bootstrap | lean 均值 65.3 ms；whole 均值 205.9 ms，未满足 200 ms，不改写为通过 |
| 空应用体积 | libapp 增量 9,109,504 bytes；用户接受增量、保留 .so 可选模式；具体 gate 阈值尚未写入 |
| A10 | 两份引擎各自完整闭环仍未关闭，不以普通矩阵或隔离迁移替代 |

`reports/` 是原报告的逐字节快照，包括被 Git 忽略的 SPEC；其中历史计划与
待办按原文保留。上表说明冻结时的汇总状态，不推断额外审核已通过。
`records/` 保存最终 JSON、源码身份、时序与关键日志。不同测试的源码快照
和引擎身份在各自收据中；不能说所有记录都来自同一份源码。

## 哈希与本地产物归档

`manifest.json` 列出每份记录及产物的大小、SHA256、原始位置。
记录通过 .gitattributes 禁止文本换行转换，以保证换机 checkout 后哈希一致。
大型产物不进入 Git，归档在：

`D:/DevProjects/flutter_patcher_baselines/m1-20260912/acceptance-artifacts.tar`

包括匹配 APK/corpus 的构建输出、构建源码快照、隔离补丁、字体三阶段图片、
空应用 APK 对照和相关收据。字体图仅选审核页引用的原图；不包含那张被通知
遮挡的回退图。原始实验目录和失败记录未删除。

验证记录及完整归档（Windows 若 python 为 Store 别名，请使用已配置的实际 Python）：

```powershell
python test/acceptance/baselines/m1-20260912/verify.py --archive D:/DevProjects/flutter_patcher_baselines/m1-20260912/acceptance-artifacts.tar
```

本地另存 `repository.bundle`，包含此 tag 可达的 Git 历史；`backup-receipt.json`
位于相同外部目录，记录 tag、commit、bundle 与产物归档哈希。
这些是同一台电脑的本地副本，不声称已有异机备份。未推送、未创建远端 Release。

## 随时回到基线

优先新建工作树，保留当前修改，不需要 reset --hard：

```powershell
git worktree add --detach ../flutter_patcher-m1 m1-baseline-20260912
```

若原仓库不可用，可从本地 bundle 恢复：

```powershell
git clone D:/DevProjects/flutter_patcher_baselines/m1-20260912/repository.bundle ../flutter_patcher-m1-restored
git -C ../flutter_patcher-m1-restored switch --detach m1-baseline-20260912
```

重构时以 tag 为代码比较起点，以这里的匹配 APK/corpus 和收据为行为对照物。
使用归档中的标准或 custom inputs 重跑现有 run_matrix.py；必须输出新目录，
不可覆盖基线记录。新代码回归应通过 rebuild_regression.py 重建匹配产物，
不能将旧基线 corpus 冒充新产品源码的验收。字体用例另以 capture-rollback
保存三阶段图。任何新结果单独存档，不移动或重打本 tag。
