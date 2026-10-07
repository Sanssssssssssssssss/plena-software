# 日志与结果

本目录保存已同步到仓库的日志。另一台计算机上的项目最终成绩及材料同步情况见 [项目结果](../docs/RESULTS.md)。

先看 [2026-10-04 验证汇总](../docs/VALIDATION.md)，再按下表查看原始记录。

| 目录 | 内容 |
|---|---|
| [repository-validation-2026-10-04/fresh-clone](repository-validation-2026-10-04/fresh-clone) | 全新克隆中的数学 reference、26 项编译检查、3 项研究检查、小型 A/B 与计时记录；本机复测章节的数字取自这里 |
| [repository-validation-2026-10-04/local](repository-validation-2026-10-04/local) | 独立仓库整理过程中的本地检查，保留其执行版本 |
| [history-2026-10-04](history-2026-10-04) | 仓库拆分前的归档，含上游产物与初次本机检查，也保留早期硬件日志 |

[tiny-trace-ab.json](repository-validation-2026-10-04/fresh-clone/tiny-trace-ab.json) 保存 v5/R1/R4 的指令数与工作量对照；[cpu-receipt.json](repository-validation-2026-10-04/fresh-clone/cpu-receipt.json) 记录主机检查耗时。主机耗时和指令数均不能直接当作目标 NPU 延迟。

[复测 manifest](repository-validation-2026-10-04/manifest.json) 与[历史 manifest](history-2026-10-04/manifest.json)用于核对已保存文件。自己运行脚本产生的新结果写入根目录 `runs/`。

论文中的单层加速、DSE 和系统成绩从[结果核对](../docs/RESULTS.md)查起。硬件独立仓库的复测日志见[硬件日志目录](https://github.com/Sanssssssssssssssss/plena-hardware/tree/main/evidence)。
